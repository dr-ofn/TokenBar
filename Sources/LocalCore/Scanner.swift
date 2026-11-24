import Foundation

/// A source that could not be read, named instead of silently shrinking the numbers.
public struct SourceIssue: Sendable, Equatable {
    public var source: String
    public var message: String

    public init(source: String, message: String) {
        self.source = source
        self.message = message
    }
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
    /// Folders found unreadable while the files of a source were listed (`walk`); the pass that listed them names them.
    var walkProblems: [String] = []
    /// Lines over `LineReader.maxLineBytes` that were skipped while a file was read (path: how many); named by the pass.
    var longLines: [String: Int] = [:]
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
        if let problem = PriceBook.aliasIssue { result.issues.append(SourceIssue(source: UserAliases.fileName, message: problem)) }
        readThisPass = []
        pairStamps = [:]
        walkProblems = []
        longLines = [:]
        do { try store.repairZeroDates() } catch { result.issues.append(SourceIssue(source: "index", message: L10n.t("tarih onarımı: \(error)", "date repair: \(error)"))) }

        for descriptor in catalog.descriptors where descriptor.family != .opencodeSQLite && !descriptor.family.readsOwnDatabases && descriptor.family != .notCountable {
            scan(fileSource(descriptor, roots: catalog.rootPaths(of: descriptor)), &result)
        }

        var stat = SourceStat(name: "opencode")
        for descriptor in catalog.descriptors where descriptor.family == .opencodeSQLite {
            let databases = openCodeDatabases(descriptor, roots: catalog.rootPaths(of: descriptor))
            result.issues += walkProblems.map { SourceIssue(source: Self.sourceName(descriptor), message: $0) }
            walkProblems = []
            for db in databases {
                do {
                    try readOpenCode(db: db, prefix: descriptor.keyPrefixes[0], &stat)
                } catch {
                    result.issues.append(SourceIssue(source: Self.sourceName(descriptor), message: "\(db): \(error)"))
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

    /// The name an issue of a source goes under, as on Windows: a second entry of a tool whose other entry has the same name
    /// (Kilo Code's CLI, Qwen Code's chats) carries its key prefix, `Kilo Code (kilo)`.
    static func sourceName(_ d: HarnessDescriptor) -> String {
        let prefix = d.keyPrefixes.first ?? ""
        return ["qwenc", "kilo", "kilocode"].contains(prefix) ? "\(d.name) (\(prefix))" : d.name
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
        let listed = source.files()
        problems += walkProblems
        walkProblems = []
        for path in listed {
            if let why = source.blocker?(path) {
                blocked[why, default: 0] += 1
                continue
            }
            // A FIFO named like a log would block the scan for good (a socket or a device is no log either): those are not opened.
            // A folder where a file should be still goes on to be read, and fails by name, as before.
            guard let st = Self.fileInfo(path), (st.st_mode & S_IFMT) == S_IFREG || (st.st_mode & S_IFMT) == S_IFDIR else { continue }
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
                longLines[path] = nil
                let read = try autoreleasepool { try source.read(file) }
                var longProblem: [String] = []
                if let n = longLines[path] {
                    longProblem = [L10n.t("\(n) satır 256 MiB'den uzun, atlandı", "\(n) line(s) over 256 MiB skipped")]
                }
                pending.append(UsageStore.FileUpdate(
                    record: UsageStore.FileRecord(path: path, inode: inode, size: size, mtime: mtime, offset: read.end),
                    events: read.events, meta: read.meta, retire: read.retire, retirePrefixes: read.retirePrefixes))
                problems += (read.issues + longProblem).map { "\(path): \($0)" }
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

    /// Every file under `root` whose name passes `match`. A folder under it that cannot be read is not skipped in silence:
    /// it is kept in `walkProblems` (the pass names it) and the files that can be read are still listed. A root that is
    /// not there is no problem; one that is there and cannot be read is.
    func walk(_ root: String, _ match: (String) -> Bool) -> [String] {
        // A root that cannot even be looked at (a parent without permission) is there, not missing: named, as on Windows.
        var rootInfo = Darwin.stat()
        if stat(root, &rootInfo) != 0 {
            // EPERM as well: macOS privacy protection (TCC) refuses with it where a plain permission says EACCES.
            if errno == EACCES || errno == EPERM {
                let problem = root + ": " + L10n.t("okunamıyor", "cannot be read")
                if !walkProblems.contains(problem) { walkProblems.append(problem) }
            }
            return []
        }
        // A root that is a file, not a folder, holds no logs and is no problem (as on Windows).
        if (rootInfo.st_mode & S_IFMT) != S_IFDIR { return [] }
        // Walked from its real path: a root that is itself a symbolic link (~/.claude/projects kept on another disk) is
        // followed, as before 9.0.5 and on Windows, and what the walk reports maps back to the root's own spelling.
        let realRoot: String = {
            guard let p = realpath(root, nil) else { return root }
            defer { free(p) }
            return String(cString: p)
        }()
        let rootURL = URL(fileURLWithPath: realRoot, isDirectory: true)
        var unreadable: [String] = []
        guard let names = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [], errorHandler: { (url: URL, error: Error) -> Bool in
            // Only a refusal of permission is named: a folder that went while the walk ran (ENOENT, ENOTDIR) is no problem.
            guard Self.isPermissionError(error) else { return true }
            unreadable.append(url.path)
            return true
        }) else { return [] }
        var out: [String] = []
        for case let url as URL in names {
            // The path under the root is the last `level` components: the enumerator may hand back the root resolved
            // (/var -> /private/var), so the root's own spelling is not a prefix of what it returns.
            let name = url.pathComponents.suffix(names.level).joined(separator: "/")
            if match((name as NSString).lastPathComponent) { out.append(root + "/" + name) }
        }
        if !unreadable.isEmpty, FileManager.default.fileExists(atPath: root) {
            // Named in the root's own spelling, whichever way the enumerator spells it (resolved or not).
            let resolved = rootURL.resolvingSymlinksInPath().path
            for found in unreadable {
                var path = found
                for base in [realRoot, resolved, rootURL.path] where found == base || found.hasPrefix(base + "/") {
                    path = root + found.dropFirst(base.count)
                    break
                }
                let problem = path + ": " + L10n.t("okunamıyor", "cannot be read")
                if !walkProblems.contains(problem) { walkProblems.append(problem) }
            }
        }
        return out
    }

    /// Calls `body` for every complete line of `file`, up to its limit. Returns where the reading stopped.
    func readLines(_ file: FileToRead, _ body: (UnsafeRawBufferPointer) throws -> Void) throws -> UInt64 {
        linePasses[file.path, default: 0] += 1
        let result = try LineReader.forEachLine(path: file.path, from: file.offset, upTo: file.limit, consumeTrailingLine: file.settled) { line in
            try body(line)
            return true
        }
        if result.skippedLines > 0 { longLines[file.path] = max(longLines[file.path] ?? 0, result.skippedLines) }
        return result.endOffset
    }

    static func fileInfo(_ path: String) -> Darwin.stat? {
        var st = Darwin.stat()
        return stat(path, &st) == 0 ? st : nil
    }

    /// A path that is a FIFO, socket or device, not a file the readers open (same rule as `LineReader`).
    static func isSpecialPath(_ path: String) -> Bool {
        guard let st = fileInfo(path) else { return false }
        let mode = st.st_mode & S_IFMT
        return [S_IFIFO, S_IFSOCK, S_IFCHR, S_IFBLK].contains(mode)
    }

    static func modified(_ st: Darwin.stat) -> Double {
        Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }
}
