import Foundation
import SQLite3

/// Crush, Goose and Devin's `sessions.db` live in SQLite databases that are read whole whenever
/// they change (one row per session, so a read is small); Factory Droid, Amp and OpenHands keep
/// one JSON file per session or thread and go through the plain file sources.
extension UsageScanner {
    static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    // MARK: JSON files

    func readDroid(_ file: FileToRead) throws -> FileRead {
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let session = String((file.path as NSString).lastPathComponent.dropLast(".settings.json".count))
        let event = DroidParser.event(data: data, session: session, file: file.path,
                                      fallbackTime: Self.fileInfo(file.path).map(Self.modified) ?? 0)
        return FileRead(events: event.map { [$0] } ?? [], end: file.limit)
    }

    func readAmp(_ file: FileToRead) throws -> FileRead {
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let thread = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return FileRead(events: AmpParser.events(data: data, thread: thread, file: file.path,
                                                 fallbackTime: Self.fileInfo(file.path).map(Self.modified) ?? 0),
                        end: file.limit)
    }

    func readOpenHands(_ file: FileToRead) throws -> FileRead {
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let conversation = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return FileRead(events: OpenHandsParser.events(data: data, conversation: conversation, file: file.path,
                                                       fallbackTime: Self.fileInfo(file.path).map(Self.modified) ?? 0),
                        end: file.limit)
    }

    /// `<root>/<conversation>/base_state.json`, without walking every event file below them.
    func openHandsStates(_ root: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
            .map { root + "/" + $0 + "/base_state.json" }
            .filter { Self.fileInfo($0) != nil }
    }

    // MARK: databases

    /// Crush, Goose and the Devin CLI database, each read whole when it or its WAL changed.
    func scanG3(_ catalog: HarnessCatalog, _ result: inout ScanResult) {
        for d in catalog.descriptors {
            let roots = catalog.rootPaths(of: d)
            switch d.family {
            case .crushSQLite:
                var stat = SourceStat(name: d.name)
                for project in HarnessCatalog.crushProjects(roots: roots) {
                    readDatabase(project.db, source: d.name, &stat, &result) { db in
                        try self.loadCrush(db, file: project.db, project: project.path)
                    }
                }
                result.sources.append(stat)
            case .gooseSQLite:
                var stat = SourceStat(name: d.name)
                for path in gooseDatabases(roots) {
                    readDatabase(path, source: d.name, &stat, &result) { db in try self.loadGoose(db, file: path) }
                }
                result.sources.append(stat)
            case .devinTranscripts:
                var stat = SourceStat(name: d.name + " sessions.db")
                for root in roots {
                    let path = root + "/cli/sessions.db"
                    let covered = Set(((try? FileManager.default.contentsOfDirectory(atPath: root + "/cli/transcripts")) ?? [])
                        .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) })
                    // A transcript appearing or going changes what the database may add.
                    let salt = Self.fingerprint(covered.sorted().joined(separator: "\n"))
                    readDatabase(path, source: d.name, salt: salt, &stat, &result) { db in
                        try self.loadDevinSessions(db, file: path, covered: covered)
                    }
                }
                if stat.filesRead > 0 { result.sources.append(stat) }
            default:
                continue
            }
        }
    }

    /// Reads one database whole when it, or its WAL, is not the one seen last time. A failure
    /// is named as an issue and leaves the other databases alone.
    private func readDatabase(_ path: String, source: String, salt: String = "", _ stat: inout SourceStat,
                              _ result: inout ScanResult, load: (ExternalDB) throws -> [UsageEvent]) {
        guard let main = Self.fileInfo(path) else { return }
        // Each file on its own: a sum of two mtimes is the same for different pairs.
        let stamp = Self.stamp(main) + "|" + (Self.fileInfo(path + "-wal").map(Self.stamp) ?? "-") + (salt.isEmpty ? "" : "|" + salt)
        let key = "g3stamp:" + path
        if store.meta(key) == stamp { return }
        do {
            let events = try load(try ExternalDB(path: path, immutable: false))
            try store.insertEvents(events)
            try store.setMeta(key, stamp)
            stat.filesRead += 1
            stat.events += events.count
        } catch {
            result.issues.append(SourceIssue(source: source, message: "\(path): \(error)"))
        }
    }

    /// FNV-1a over the text, in hex.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func columns(_ db: ExternalDB, of table: String) throws -> Set<String> {
        var names = Set<String>()
        try db.query("PRAGMA table_info(\(table))") { st in
            if let name = ExternalDB.text(st, 1) { names.insert(name) }
        }
        return names
    }

    private static func optionalInt(_ st: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(st, column) == SQLITE_NULL ? nil : sqlite3_column_int64(st, column)
    }

    /// A column that holds Unix seconds or milliseconds, or text such as `2026-01-01 12:00:00`.
    private static func time(_ st: OpaquePointer, _ column: Int32) -> Double {
        guard let text = ExternalDB.text(st, column) else { return 0 }
        return Double(text).map { J.time($0) } ?? J.time(text)
    }

    // MARK: Crush

    func loadCrush(_ db: ExternalDB, file: String, project: String?) throws -> [UsageEvent] {
        let provider = try columns(db, of: "messages").contains("provider")
        func latest(_ column: String) -> String {
            """
            (SELECT m.\(column) FROM messages m WHERE m.session_id = s.id AND m.role = 'assistant'
             AND m.\(column) IS NOT NULL AND m.\(column) != '' ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1)
            """
        }
        let sql = """
        SELECT s.id, s.prompt_tokens, s.completion_tokens, s.updated_at, s.created_at, \(latest("model")),
               \(provider ? latest("provider") : "NULL")
        FROM sessions s WHERE s.prompt_tokens > 0 OR s.completion_tokens > 0
        """
        var events: [UsageEvent] = []
        try db.query(sql) { st in
            var stamp = Self.time(st, 3)
            if stamp <= 0 { stamp = Self.time(st, 4) }
            if let event = CrushParser.event(sessionID: ExternalDB.text(st, 0) ?? "", promptTokens: sqlite3_column_int64(st, 1),
                                             completionTokens: sqlite3_column_int64(st, 2), time: stamp,
                                             model: ExternalDB.text(st, 5), provider: ExternalDB.text(st, 6),
                                             project: project, file: file) {
                events.append(event)
            }
        }
        return events
    }

    // MARK: Goose

    /// Each root is a folder with `sessions.db` in it, or a Goose data root (`GOOSE_PATH_ROOT`,
    /// the default `~/.local/share/goose`) with it below `data/sessions` or `sessions`. A database
    /// reached by two roots (a symlink) is one.
    func gooseDatabases(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for root in roots {
            for path in [root, root + "/sessions.db", root + "/sessions/sessions.db", root + "/data/sessions/sessions.db"] {
                guard let info = Self.fileInfo(path), (info.st_mode & S_IFMT) == S_IFREG else { continue }
                if seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted { out.append(path) }
            }
        }
        return out
    }

    func loadGoose(_ db: ExternalDB, file: String) throws -> [UsageEvent] {
        let have = try columns(db, of: "sessions")
        func column(_ name: String) -> String { have.contains(name) ? "s." + name : "NULL" }
        let sql = """
        SELECT \(column("id")), \(column("model_config_json")), \(column("provider_name")), \(column("updated_at")),
               \(column("created_at")), \(column("accumulated_input_tokens")), \(column("accumulated_output_tokens")),
               \(column("accumulated_cache_read_tokens")), \(column("accumulated_cache_write_tokens")),
               \(column("input_tokens")), \(column("output_tokens")), \(column("cache_read_tokens")),
               \(column("cache_write_tokens")), \(column("working_dir"))
        FROM sessions s
        """
        var events: [UsageEvent] = []
        try db.query(sql) { st in
            // The running totals, or the latest call's counts for a session that has no totals.
            let accumulated = Self.optionalInt(st, 5) != nil || Self.optionalInt(st, 6) != nil
            let base: Int32 = accumulated ? 5 : 9
            var stamp = Self.time(st, 3)
            if stamp <= 0 { stamp = Self.time(st, 4) }
            let row = GooseParser.Row(id: ExternalDB.text(st, 0) ?? "", modelConfigJSON: ExternalDB.text(st, 1),
                                      provider: ExternalDB.text(st, 2), time: stamp,
                                      input: Self.optionalInt(st, base), output: Self.optionalInt(st, base + 1),
                                      cacheRead: Self.optionalInt(st, base + 2), cacheWrite: Self.optionalInt(st, base + 3),
                                      workingDir: ExternalDB.text(st, 13))
            if let event = GooseParser.event(row, file: file) { events.append(event) }
        }
        return events
    }

    // MARK: Devin CLI database

    /// The assistant requests of sessions that have no transcript. A session whose transcript has
    /// appeared since is dropped from the index's database rows, so it is not counted twice.
    func loadDevinSessions(_ db: ExternalDB, file: String, covered: Set<String>) throws -> [UsageEvent] {
        let role = "CASE WHEN json_valid(m.chat_message) THEN json_extract(m.chat_message, '$.role') END"
        func field(_ path: String) -> String { "json_extract(m.chat_message, '$.metadata.\(path)')" }
        let sql = """
        SELECT m.session_id, m.node_id, \(field("request_id")), \(field("metrics.input_tokens")),
               \(field("metrics.output_tokens")), \(field("metrics.cache_read_tokens")),
               \(field("metrics.cache_creation_tokens")), m.created_at, \(field("generation_model")),
               s.model, s.working_directory
        FROM message_nodes m JOIN sessions s ON s.id = m.session_id
        WHERE \(role) = 'assistant' AND \(field("metrics")) IS NOT NULL
        """
        var events: [UsageEvent] = []
        var dropped = Set<String>()
        try db.query(sql) { st in
            let session = ExternalDB.text(st, 0) ?? ""
            if covered.contains(session) { dropped.insert(session); return }
            let row = DevinDBParser.Row(session: session, node: sqlite3_column_int64(st, 1), requestID: ExternalDB.text(st, 2),
                                        input: sqlite3_column_int64(st, 3), output: sqlite3_column_int64(st, 4),
                                        cacheRead: sqlite3_column_int64(st, 5), cacheWrite: sqlite3_column_int64(st, 6),
                                        time: Self.time(st, 7),
                                        generationModel: ExternalDB.text(st, 8), sessionModel: ExternalDB.text(st, 9),
                                        workingDirectory: ExternalDB.text(st, 10))
            if let event = DevinDBParser.event(row, file: file) { events.append(event) }
        }
        for session in dropped.sorted() where store.hasEvents(prefix: "devin:\(session):db:") {
            try store.replaceEvents(prefix: "devin:\(session):db:", with: [])
        }
        return events
    }
}

extension HarnessCatalog {
    /// `*` stands for any run of characters inside one path component (`<team id>.dev.warp`). A
    /// pattern that matches nothing stays as written, so it is simply a root that does not exist.
    static func expandingGlobs(_ path: String) -> [String] {
        guard path.contains("*") else { return [path] }
        var current = ["/"]
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            var next: [String] = []
            for base in current {
                let join = { (name: String) in base == "/" ? "/" + name : base + "/" + name }
                if part.contains("*") {
                    for name in ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted()
                    where fnmatch(String(part), name, 0) == 0 { next.append(join(name)) }
                } else {
                    next.append(join(String(part)))
                }
            }
            current = next
        }
        let found = current.filter { FileManager.default.fileExists(atPath: $0) }
        return found.isEmpty ? [path] : found
    }

    /// The projects Crush lists in `projects.json` under each root, with their databases that exist.
    /// A database reached twice (two roots, a symlink) is one.
    static func crushProjects(roots: [String]) -> [(path: String?, db: String)] {
        var seen = Set<String>()
        var out: [(String?, String)] = []
        for root in roots {
            guard let data = FileManager.default.contents(atPath: root + "/projects.json"),
                  let object = (J.parse(data)) as? [String: Any],
                  let projects = object["projects"] as? [Any] else { continue }
            for case let project as [String: Any] in projects {
                guard let dir = J.str(project["data_dir"]) else { continue }
                let path = J.str(project["path"])
                let folder = dir.hasPrefix("/") ? dir : (path.map { $0 + "/" + dir } ?? dir)
                let db = folder + "/crush.db"
                guard FileManager.default.fileExists(atPath: db),
                      seen.insert(URL(fileURLWithPath: db).resolvingSymlinksInPath().path).inserted else { continue }
                out.append((path, db))
            }
        }
        return out
    }

    /// Crush's databases sit in the projects, not under its own folder: their folders are watched too.
    func crushWatchPaths() -> [String] {
        var out: [String] = []
        for d in descriptors where d.family == .crushSQLite {
            for project in Self.crushProjects(roots: rootPaths(of: d)) {
                let folder = (project.db as NSString).deletingLastPathComponent
                if !out.contains(folder) { out.append(folder) }
            }
        }
        return out
    }
}
