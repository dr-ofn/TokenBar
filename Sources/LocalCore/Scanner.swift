import Foundation

/// A source that could not be read, named instead of silently shrinking the numbers.
public struct SourceIssue: Sendable, Equatable {
    public var source: String
    public var message: String
}

/// What one source contributed in a pass.
public struct SourceStat: Sendable {
    public var name: String
    public var filesRead = 0
    public var events = 0
}

public struct ScanResult: Sendable {
    public var issues: [SourceIssue] = []
    public var sources: [SourceStat] = []
    public var bytesRead: UInt64 = 0
    /// The tools whose data folder exists on this Mac, whether or not they logged anything yet.
    public var detected: [HarnessID] = []
    /// The detected tools that log no token counts here: named, never counted.
    public var notCountable: [HarnessID] = []

    public var events: Int { sources.reduce(0) { $0 + $1.events } }
}

/// One file about to be read. `limit` is its size when it was looked at: a reader stops
/// there, so what it returns matches the size stored for the file.
struct FileToRead {
    var path: String
    var offset: UInt64
    var limit: UInt64
    /// The file has been quiet long enough that an unterminated last line is complete.
    var settled: Bool

    /// The same file from its first byte, its unterminated last line included.
    var whole: FileToRead { FileToRead(path: path, offset: 0, limit: limit, settled: true) }
}

/// What one read of one file produced.
struct FileRead {
    var events: [UsageEvent]
    /// Stored as the file's next offset.
    var end: UInt64
    /// Written in the same transaction as the events and the offset.
    var meta: [String: String] = [:]
    /// Keys of rows deleted in that same transaction, before the events go in: rows the file now says differently
    /// (a figure that shrank), which the keep-the-larger rule of an upsert would otherwise leave standing.
    var retire: [String] = []
    /// Key prefixes whose rows that came from this very file are deleted in that same transaction, before the events
    /// go in: a file that is rewritten whole (Cline's `ui_messages.json`) is the one truth for its rows, so a row it no
    /// longer holds must not stay beside the rows that now hold its usage.
    var retirePrefixes: [String] = []
    /// Parts of the file that could not be read while the rest was: named as source issues next to the events.
    var issues: [String] = []
}

/// A set of files read one by one. `appendOnly` files resume from the byte they stopped at;
/// the others are read whole whenever they change, and dedup keys make that harmless.
struct FileSource {
    var name: String
    var appendOnly: Bool
    var files: () -> [String]
    var read: (FileToRead) throws -> FileRead
    /// Why a file cannot be read right now (a missing tool), or nil. Blocked files are left
    /// unrecorded, so they are read once the blocker is gone, and named once per pass.
    var blocker: ((String) -> String?)?
    /// Runs after the source's files, with how many of them changed this pass.
    var refresh: ((_ filesRead: Int) throws -> Void)?
    /// For a source whose files are databases that come as a pair (the `.db` and its `-wal`): the database a listed
    /// file belongs to. Such a database is read whole when its stamp (inode, size and mtime in nanoseconds, each file of
    /// the pair on its own) is not the one the last read saved, like opencode's: an mtime that went back (the clock set
    /// back, a backup put back) is a change too, which the `>=` rule of the plain files would not see.
    var database: ((String) -> String)?
}

/// Finds and reads every harness log under one home directory into the store.
public final class UsageScanner {
    /// A file modified less than this ago may still have an unterminated last line.
    private static let settleSeconds = 10.0
    private static let batchFiles = 200
    private static let batchEvents = 20_000

    let store: UsageStore
    let home: String
    let environment: [String: String]?
    /// How many times each file's lines were walked, by path. Lets a check see a double read.
    public private(set) var linePasses: [String: Int] = [:]
    /// Meta of files read in the batch that is not committed yet. A later file of the same batch
    /// (another transcript of one session) merges into it instead of into the stale saved copy.
    var pendingMeta: [String: String] = [:]
    /// Databases already read in this pass whose files come as a pair (Zed's `threads.db` and its `-wal`): the
    /// second file of the pair is recorded without a second read of the same database.
    var readThisPass: Set<String> = []
    /// The stamp of such a pair (the .db and the -wal, each by inode, size and mtime) taken before the pair was read.
    /// The second file of the pair is recorded as read only while the pair still looks like that: a write that came
    /// after the read and before the second file was looked at is not in what was read.
    var pairStamps: [String: String] = [:]
    /// For checks: called right after a database pair was read in this pass (the path of the .db), so a check can make
    /// the tool write at that very moment.
    public var afterPairRead: ((String) -> Void)?

    /// `environment` is what moves the tools' folders (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`...); by
    /// default the process's own, and only for the real home.
    public init(store: UsageStore, home: String = NSHomeDirectory(), environment: [String: String]? = nil) {
        self.store = store
        self.home = home
        self.environment = environment
    }

    /// Directories whose changes should wake a scan. They may not exist yet.
    public static func watchPaths(home: String = NSHomeDirectory(), environment: [String: String]? = nil) -> [String] {
        HarnessCatalog.load(home: home, environment: environment).watchPaths()
    }

    public func scan() -> ScanResult {
        // Read again every pass: the user's file may have changed since the last one.
        let catalog = HarnessCatalog.load(home: home, environment: environment)
        catalog.register()
        var result = ScanResult()
        result.issues += catalog.issues
        readThisPass = []
        pairStamps = [:]
        do { try store.repairZeroDates() } catch { result.issues.append(SourceIssue(source: "index", message: L10n.t("tarih onarımı: \(error)", "date repair: \(error)"))) }

        for descriptor in catalog.descriptors where descriptor.family != .opencodeSQLite && !descriptor.family.readsOwnDatabases && descriptor.family != .notCountable {
            scan(fileSource(descriptor, roots: catalog.rootPaths(of: descriptor)), &result)
        }

        var stat = SourceStat(name: "opencode")
        for descriptor in catalog.descriptors where descriptor.family == .opencodeSQLite {
            for db in openCodeDatabases(descriptor, roots: catalog.rootPaths(of: descriptor)) {
                do {
                    try readOpenCode(db: db, prefix: descriptor.keyPrefixes[0], &stat)
                } catch {
                    result.issues.append(SourceIssue(source: "opencode", message: "\(db): \(error)"))
                }
            }
        }
        result.sources.append(stat)
        scanG3(catalog, &result)
        result.detected = catalog.detected()
        result.notCountable = catalog.notCountable()

        store.compactIfNeeded()
        try? store.setMeta("lastScan", String(Date().timeIntervalSince1970))
        return result
    }

    private func scan(_ source: FileSource, _ result: inout ScanResult) {
        var progress = SourceStat(name: source.name)
        var problems: [String] = []
        var bytes: UInt64 = 0
        var pending: [UsageStore.FileUpdate] = []
        var pendingEvents = 0
        func flush() {
            do { try store.apply(pending) } catch { problems.append(String(describing: error)) }
            pending = []
            pendingEvents = 0
            pendingMeta = [:]
        }
        var blocked: [String: Int] = [:]
        guard let records = try? store.fileRecords() else {
            result.issues.append(SourceIssue(source: source.name, message: L10n.t("dosya kayıtları okunamadı", "the file records could not be read")))
            result.sources.append(progress)
            return
        }
        let now = Date().timeIntervalSince1970
        for path in source.files() {
            if let why = source.blocker?(path) {
                blocked[why, default: 0] += 1
                continue
            }
            guard let st = Self.fileInfo(path) else { continue }
            let inode = UInt64(st.st_ino), size = UInt64(st.st_size)
            let mtime = Self.modified(st)
            let old = records[path]
            let sameFile = old?.inode == inode
            if let database = source.database {
                // The pair is read once per pass; whether it changed is its stamp's word (the reader saves the stamp
                // it took before reading, so a write that came in while it read shows next pass).
                let db = database(path)
                if readThisPass.contains(db) { continue }
                let key = "dbstamp:" + db
                if (pendingMeta[key] ?? store.meta(key)) == pairStamp(db) { continue }
            } else if sameFile, let old, old.mtime >= mtime, old.size == size, old.offset >= size { continue }
            // A shrink, a new inode or a same-size rewrite starts over.
            let offset = source.appendOnly && sameFile && size > (old?.offset ?? 0) && source.database == nil ? old?.offset ?? 0 : 0
            let file = FileToRead(path: path, offset: offset, limit: size, settled: abs(now - mtime) > Self.settleSeconds)
            do {
                // Decoded lines are autoreleased: drain them file by file, or a first full
                // index keeps gigabytes alive until the pass ends.
                let read = try autoreleasepool { try source.read(file) }
                pending.append(UsageStore.FileUpdate(
                    record: UsageStore.FileRecord(path: path, inode: inode, size: size, mtime: mtime, offset: read.end),
                    events: read.events, meta: read.meta, retire: read.retire, retirePrefixes: read.retirePrefixes))
                problems += read.issues.map { "\(path): \($0)" }
                pendingMeta.merge(read.meta) { _, new in new }
                progress.filesRead += 1
                progress.events += read.events.count
                pendingEvents += read.events.count
                bytes += read.end > offset ? read.end - offset : 0
            } catch {
                problems.append("\(path): \(error)")
            }
            if pending.count >= Self.batchFiles || pendingEvents >= Self.batchEvents { flush() }
        }
        flush()
        for (why, count) in blocked.sorted(by: { $0.key < $1.key }) { problems.append("\(why) " + L10n.t("(\(count) dosya atlandı)", "(\(count) files skipped)")) }
        if let refresh = source.refresh {
            do { try refresh(progress.filesRead) } catch { problems.append(String(describing: error)) }
        }
        result.bytesRead += bytes
        result.issues += problems.map { SourceIssue(source: source.name, message: $0) }
        result.sources.append(progress)
    }

    /// Every file under `root` whose name passes `match`.
    func walk(_ root: String, _ match: (String) -> Bool) -> [String] {
        guard let names = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        for case let name as String in names where match((name as NSString).lastPathComponent) {
            out.append(root + "/" + name)
        }
        return out
    }

    /// Calls `body` for every complete line of `file`, up to its limit. Returns where the reading stopped.
    func readLines(_ file: FileToRead, _ body: (UnsafeRawBufferPointer) throws -> Void) throws -> UInt64 {
        linePasses[file.path, default: 0] += 1
        return try LineReader.forEachLine(path: file.path, from: file.offset, upTo: file.limit, consumeTrailingLine: file.settled) { line in
            try body(line)
            return true
        }.endOffset
    }

    static func fileInfo(_ path: String) -> Darwin.stat? {
        var st = Darwin.stat()
        return stat(path, &st) == 0 ? st : nil
    }

    static func modified(_ st: Darwin.stat) -> Double {
        Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }
}
