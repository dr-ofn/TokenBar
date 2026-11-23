import Foundation
import SQLite3

/// Persistent index of model calls and per-file scan progress.
///
/// Rows survive session-file deletion, so history keeps accumulating. A duplicate key
/// keeps its most complete counts (streamed lines can carry partial output counts).
public final class UsageStore {
    /// Bump on a breaking schema change; out-of-range versions are refused, never re-indexed.
    public static let schemaVersion = 21

    let db: SQLiteDB
    public let path: String

    public init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                               withIntermediateDirectories: true)
        db = try SQLiteDB(path: path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TokenBar/usage.sqlite").path
    }

    private static let eventFilesSQL =
        "CREATE TABLE IF NOT EXISTS event_files(key TEXT NOT NULL, file TEXT NOT NULL, PRIMARY KEY(key, file)) WITHOUT ROWID"

    /// A new file gets the schema. Anything else must already be this version: the index holds
    /// calls whose logs are gone, so a mismatch is an error, never a reason to rebuild.
    private func migrate() throws {
        let version = try db.userVersion()
        if version == Self.schemaVersion {
            // The table of who holds a key came after the schema number was set: an index made before it gets it here.
            try db.exec(Self.eventFilesSQL)
            return
        }
        guard version == 0, try !tableExists("events") else {
            throw StoreError(message: "Dizin şeması \(version), beklenen \(Self.schemaVersion): dokunulmadı (\(path))")
        }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS events(
            key TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            ts REAL NOT NULL,
            input INTEGER NOT NULL,
            cr INTEGER NOT NULL,
            cw INTEGER NOT NULL,
            output INTEGER NOT NULL,
            reasoning INTEGER NOT NULL,
            session TEXT NOT NULL,
            project TEXT,
            file TEXT NOT NULL,
            cw1h INTEGER NOT NULL DEFAULT 0
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS events_cover ON events(ts, model, provider, input, cr, cw, output, reasoning);
        \(Self.eventFilesSQL);
        CREATE TABLE IF NOT EXISTS files(
            path TEXT PRIMARY KEY,
            inode INTEGER NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            offset INTEGER NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;
        PRAGMA user_version = \(Self.schemaVersion);
        """)
    }

    private func tableExists(_ name: String) throws -> Bool {
        let st = try db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
        st.bind(1, name)
        return try st.step()
    }

    // MARK: files

    public struct FileRecord: Equatable, Sendable {
        public var path: String
        public var inode: UInt64
        public var size: UInt64
        public var mtime: Double
        public var offset: UInt64
    }

    public func fileRecords() throws -> [String: FileRecord] {
        let st = try db.prepare("SELECT path, inode, size, mtime, offset FROM files")
        var out: [String: FileRecord] = [:]
        while try st.step() {
            out[st.string(0) ?? ""] = FileRecord(path: st.string(0) ?? "", inode: UInt64(bitPattern: st.int(1)),
                                                size: UInt64(bitPattern: st.int(2)), mtime: st.double(3),
                                                offset: UInt64(bitPattern: st.int(4)))
        }
        return out
    }

    // MARK: writes

    /// A repeated key keeps its most complete counts. A task found in two places (the same id in two editors) is
    /// counted once. `event_files` says which files hold a key (a set: both copies hold it); the copy that is read
    /// again retires the keys it holds and writes what it holds now, and leaves the keys only the other copy holds.
    /// `events.file` is the last writer, kept for an index made before that table (and is how such a row is found).
    private static let moreComplete = ["input", "cr", "cw", "output", "reasoning", "cw1h", "provider"]
    /// A row written as `unknown` (the model was not named yet) takes the model a later read gives it, with the same counts or more.
    /// A later read without a model name never replaces a model the row already has.
    private static let modelUpdate = "model=CASE WHEN excluded.model <> 'unknown' AND (\(isMore) OR events.model = 'unknown') THEN excluded.model ELSE events.model END"
    /// A row stored with no date (9.0.0 wrote 1970 for the ISO text dates of Crush, Devin, Copilot Chat and Cline) takes the
    /// date a later read gives it; a date the row has is never replaced.
    private static let tsUpdate = "ts=CASE WHEN events.ts <= 0 AND excluded.ts > 0 THEN excluded.ts ELSE events.ts END"
    private static let isMore = "(excluded.input + excluded.cr + excluded.cw + excluded.output) > (events.input + events.cr + events.cw + events.output)"

    private func prepareUpsert() throws -> Statement {
        try db.prepare("""
        INSERT INTO events(key, provider, model, ts, input, cr, cw, output, reasoning, session, project, file, cw1h)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(key) DO UPDATE SET
            \(Self.moreComplete.map { "\($0)=CASE WHEN \(Self.isMore) THEN excluded.\($0) ELSE events.\($0) END" }.joined(separator: ", ")),
            \(Self.modelUpdate),
            \(Self.tsUpdate),
            file=excluded.file
        """)
    }

    private func upsert(_ e: UsageEvent, _ ins: Statement) throws {
        ins.reset()
        ins.bind(1, e.key)
        ins.bind(2, e.provider)
        ins.bind(3, e.model)
        ins.bind(4, e.timestamp)
        ins.bind(5, e.tokens.input)
        ins.bind(6, e.tokens.cacheRead)
        ins.bind(7, e.tokens.cacheWrite)
        ins.bind(8, e.tokens.output)
        ins.bind(9, e.tokens.reasoning)
        ins.bind(10, e.session)
        ins.bind(11, e.project)
        ins.bind(12, e.file)
        ins.bind(13, e.tokens.cacheWrite1h)
        try ins.step()
    }

    /// Inserts events of a source that is not a scannable file, keeping the more complete
    /// counts on a duplicate key.
    public func insertEvents(_ events: [UsageEvent]) throws {
        guard !events.isEmpty else { return }
        try db.transaction {
            let ins = try prepareUpsert()
            for e in events { try upsert(e, ins) }
        }
    }

    /// Replaces every row under a key prefix. For rows computed from others, which may shrink.
    public func replaceEvents(prefix: String, with events: [UsageEvent]) throws {
        try db.transaction {
            let del = try db.prepare("DELETE FROM events WHERE key >= ? AND key < ?")
            del.bind(1, prefix)
            del.bind(2, Self.upperBound(prefix))
            try del.step()
            try forgetOwners(prefix)
            let ins = try prepareUpsert()
            for e in events { try upsert(e, ins) }
        }
    }

    /// The first string above every string that starts with `prefix` (ASCII prefixes only).
    private static func upperBound(_ prefix: String) -> String {
        var bytes = Array(prefix.utf8)
        // An empty prefix means every key. UTF-8 never holds 0xFF, so the last byte can't overflow.
        guard let last = bytes.popLast() else { return "\u{10FFFF}" }
        bytes.append(last + 1)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Drops the ownership rows under a prefix whose event is gone.
    private func forgetOwners(_ prefix: String) throws {
        let st = try db.prepare("DELETE FROM event_files WHERE key >= ? AND key < ? AND NOT EXISTS "
                                + "(SELECT 1 FROM events e WHERE e.key = event_files.key)")
        st.bind(1, prefix)
        st.bind(2, Self.upperBound(prefix))
        try st.step()
    }

    public struct FileUpdate: Sendable {
        public var record: FileRecord
        public var events: [UsageEvent]
        public var meta: [String: String] = [:]
        /// Row keys deleted before the events are added.
        public var retire: [String] = []
        /// Key prefixes whose rows read from `record.path` are deleted before the events are added.
        public var retirePrefixes: [String] = []
    }

    /// Applies a scan pass in one transaction.
    public func apply(_ updates: [FileUpdate]) throws {
        guard !updates.isEmpty else { return }
        try db.transaction {
            let ins = try prepareUpsert()
            let file = try db.prepare("""
            INSERT INTO files(path, inode, size, mtime, offset) VALUES(?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET inode=excluded.inode, size=excluded.size,
                mtime=excluded.mtime, offset=excluded.offset
            """)
            let retire = try db.prepare("DELETE FROM events WHERE key = ?")
            let retireOwners = try db.prepare("DELETE FROM event_files WHERE key = ?")
            // The rows `file` holds: the ones it is named for, and the ones nobody is named for (an index made before
            // owners were kept). What another copy of the task alone holds stays.
            let retireFromFile = try db.prepare("""
            DELETE FROM events WHERE key >= ?1 AND key < ?2 AND (file = ?3
              OR key IN (SELECT key FROM event_files WHERE file = ?3 AND key >= ?1 AND key < ?2)
              OR (file = '' AND NOT EXISTS (SELECT 1 FROM event_files o WHERE o.key = events.key)))
            """)
            let hold = try db.prepare("INSERT OR IGNORE INTO event_files(key, file) VALUES(?,?)")
            let releaseOwn = try db.prepare("DELETE FROM event_files WHERE file = ?3 AND key >= ?1 AND key < ?2")
            for u in updates {
                for prefix in u.retirePrefixes {
                    retireFromFile.reset()
                    retireFromFile.bind(1, prefix)
                    retireFromFile.bind(2, Self.upperBound(prefix))
                    retireFromFile.bind(3, u.record.path)
                    try retireFromFile.step()
                    releaseOwn.reset()
                    releaseOwn.bind(1, prefix)
                    releaseOwn.bind(2, Self.upperBound(prefix))
                    releaseOwn.bind(3, u.record.path)
                    try releaseOwn.step()
                }
                for key in u.retire {
                    retire.reset()
                    retire.bind(1, key)
                    try retire.step()
                    retireOwners.reset()
                    retireOwners.bind(1, key)
                    try retireOwners.step()
                }
                for e in u.events { try upsert(e, ins) }
                if !u.retirePrefixes.isEmpty {
                    for e in u.events {
                        hold.reset()
                        hold.bind(1, e.key)
                        hold.bind(2, u.record.path)
                        try hold.step()
                    }
                }
                // Only now: a key this file wrote back has its row again, so the other copies keep their claim on it.
                for prefix in u.retirePrefixes { try forgetOwners(prefix) }
                file.reset()
                file.bind(1, u.record.path)
                file.bind(2, Int64(bitPattern: u.record.inode))
                file.bind(3, Int64(u.record.size))
                file.bind(4, u.record.mtime)
                file.bind(5, Int64(u.record.offset))
                try file.step()
                for (key, value) in u.meta { try setMeta(key, value) }
            }
        }
    }

    /// Once, for an index 9.0.0 made: rows dated 1970 (a tool's date that 9.0.0 could not read) get their date when
    /// the file or database they came from is read again, but a file whose stamp did not change is not read again. So
    /// the files those rows name are forgotten (their `files` record and database stamps), and the next scan reads them
    /// whole. The rows' keys are the same, so nothing is counted twice; the upsert only fills in the date.
    func repairZeroDates() throws {
        let flag = "repair:ts-zero-901"
        guard meta(flag) == nil else { return }
        try db.transaction {
            try db.exec("""
                DELETE FROM files WHERE path IN (SELECT DISTINCT file FROM events WHERE ts <= 0);
                DELETE FROM meta WHERE k IN (SELECT 'g3stamp:' || file FROM events WHERE ts <= 0
                                             UNION SELECT 'dbstamp:' || file FROM events WHERE ts <= 0
                                             UNION SELECT 'watermark:' || file FROM events WHERE ts <= 0);
                INSERT INTO meta(k, v) VALUES('\(flag)', '1') ON CONFLICT(k) DO UPDATE SET v = '1';
                """)
        }
    }

    /// Page statistics of the main database file (WAL already folded in).
    public func storageStats() throws -> (pages: Int, free: Int) {
        let pages = Int(try db.prepare("PRAGMA page_count").firstInt() ?? 0)
        let free = Int(try db.prepare("PRAGMA freelist_count").firstInt() ?? 0)
        return (pages: pages, free: free)
    }

    /// Reclaims pages left behind by resets and rewrites. Only acts when the free list
    /// is both large and a real share of the file, so normal scans never pay for a VACUUM.
    public func compactIfNeeded(freeRatio: Double = 0.25, minimumFreePages: Int = 4096) {
        guard let stats = try? storageStats(), stats.free >= minimumFreePages,
              Double(stats.free) >= Double(stats.pages) * freeRatio else { return }
        try? db.exec("VACUUM")
    }

    public func meta(_ key: String) -> String? {
        let st = try? db.prepare("SELECT v FROM meta WHERE k = ?")
        guard let st else { return nil }
        st.bind(1, key)
        return try? st.step() ? st.string(0) : nil
    }

    public func setMeta(_ key: String, _ value: String) throws {
        let st = try db.prepare("INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v")
        st.bind(1, key)
        st.bind(2, value)
        try st.step()
    }

    public func hasEvents(prefix: String) -> Bool {
        guard let st = try? db.prepare("SELECT 1 FROM events WHERE key >= ? AND key < ? LIMIT 1") else { return false }
        st.bind(1, prefix)
        st.bind(2, Self.upperBound(prefix))
        return (try? st.step()) ?? false
    }

    /// Meta rows whose key starts with `prefix`.
    public func metaRows(prefix: String) throws -> [(key: String, value: String)] {
        let st = try db.prepare("SELECT k, v FROM meta WHERE k >= ? AND k < ?")
        st.bind(1, prefix)
        st.bind(2, Self.upperBound(prefix))
        var out: [(key: String, value: String)] = []
        while try st.step() { out.append((st.string(0) ?? "", st.string(1) ?? "")) }
        return out
    }

    /// Per session and model, what the rows under `prefix` add up to. `excluding` is a
    /// prefix inside it whose rows don't count.
    public func sums(prefix: String, excluding: String) throws -> [SessionSum] {
        let st = try db.prepare("""
        SELECT session, model, MIN(provider), SUM(input), SUM(cr), SUM(cw), SUM(output), SUM(reasoning)
        FROM events WHERE key >= ? AND key < ? AND NOT (key >= ? AND key < ?)
        GROUP BY session, model
        """)
        st.bind(1, prefix)
        st.bind(2, Self.upperBound(prefix))
        st.bind(3, excluding)
        st.bind(4, Self.upperBound(excluding))
        var out: [SessionSum] = []
        while try st.step() {
            out.append(SessionSum(session: st.string(0) ?? "", model: st.string(1) ?? "", provider: st.string(2) ?? "",
                                  tokens: TokenCounts(input: st.int(3), cacheRead: st.int(4), cacheWrite: st.int(5),
                                                      output: st.int(6), reasoning: st.int(7))))
        }
        return out
    }

    public struct SessionSum: Sendable {
        public var session: String
        public var model: String
        public var provider: String
        public var tokens: TokenCounts
    }

    // MARK: reports

    /// Every call in the index, priced, in no particular order.
    public func usageBook(now: Date = Date()) throws -> UsageBook {
        let first = try db.prepare("SELECT MIN(ts) FROM events WHERE ts > 0")
        let earliest: Double? = try first.step() && !first.isNull(0) ? first.double(0) : nil
        let st = try db.prepare("""
        SELECT substr(key, 1, instr(key, ':') - 1), substr(key, instr(key, ':') + 1, 4) = 'adj:',
               provider, model, ts, input, cr, cw, output, reasoning, cw1h
        FROM events
        """)
        var builder = UsageBookBuilder(now: now.timeIntervalSince1970, earliest: earliest)
        while try st.step() {
            builder.add(prefix: st.string(0) ?? "", isAdjustment: st.int(1) != 0,
                        provider: st.string(2) ?? "", model: st.string(3) ?? "unknown", time: st.double(4),
                        tokens: TokenCounts(input: st.int(5), cacheRead: st.int(6), cacheWrite: st.int(7),
                                            output: st.int(8), reasoning: st.int(9), cacheWrite1h: st.int(10)))
        }
        return builder.book()
    }

    public func eventCount() throws -> Int {
        Int((try db.prepare("SELECT COUNT(*) FROM events").firstInt()) ?? 0)
    }

    public func reset() throws {
        try db.transaction {
            try db.exec("DELETE FROM events")
            try db.exec("DELETE FROM event_files")
            try db.exec("DELETE FROM files")
            try db.exec("DELETE FROM meta")
        }
    }
}
