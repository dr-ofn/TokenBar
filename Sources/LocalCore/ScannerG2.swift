import Foundation

/// The readers of the editor extensions and IDEs: Cline, Roo Code, Kilo Code, Copilot Chat,
/// Continue and Zed. (Kilo version 7 is opencode's schema and goes through `ScannerOpenCode`.)
extension UsageScanner {
    func g2FileSource(_ d: HarnessDescriptor, roots: [String]) -> FileSource {
        let prefix = d.keyPrefixes.first ?? d.id.rawValue
        switch d.family {
        case .clineTasks, .rooTasks:
            let style: ClineTasksParser.Style = d.family == .clineTasks ? .cline : .roo
            return FileSource(name: d.name, appendOnly: false,
                              files: { roots.flatMap { Self.taskFiles($0, cli: style == .cline) } },
                              read: { try self.readClineTask($0, prefix: prefix, style: style) })
        case .copilotChat:
            return FileSource(name: d.name, appendOnly: false,
                              files: { roots.flatMap { Self.copilotFiles($0) } }, read: readCopilotChat)
        case .continueTokens:
            return FileSource(name: d.name, appendOnly: true,
                              files: { roots.map { $0 + "/dev_data/0.2.0/tokensGenerated.jsonl" } },
                              read: { try self.readContinue($0, prefix: prefix) })
        case .zedThreads:
            // Zed's database is in WAL mode: a write may only touch `threads.db-wal`, so that file's
            // change wakes the same read.
            return FileSource(name: d.name, appendOnly: false,
                              files: { roots.flatMap { [$0 + "/threads/threads.db", $0 + "/threads/threads.db-wal"] } },
                              read: readZed, database: Self.databasePath)
        default:
            // `notCountable` (and any family this file does not own): found, nothing to read.
            return FileSource(name: d.name, appendOnly: false, files: { [] }, read: { _ in FileRead(events: [], end: 0) })
        }
    }

    // MARK: places

    private static func entries(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    /// `<root>/tasks/<id>/ui_messages.json`, and for Cline's CLI `<root>/sessions/<id>/<id>.messages.json`.
    static func taskFiles(_ root: String, cli: Bool) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for id in entries(root + "/tasks") {
            let path = "\(root)/tasks/\(id)/ui_messages.json"
            if fm.fileExists(atPath: path) { out.append(path) }
        }
        if cli {
            for id in entries(root + "/sessions") {
                let path = "\(root)/sessions/\(id)/\(id).messages.json"
                if fm.fileExists(atPath: path) { out.append(path) }
            }
        }
        return out
    }

    /// A root is a `workspaceStorage` folder (sessions in `<hash>/chatSessions/`) or an
    /// `emptyWindowChatSessions` folder (sessions in it).
    static func copilotFiles(_ root: String) -> [String] {
        let isSession: (String) -> Bool = { $0.hasSuffix(".jsonl") || $0.hasSuffix(".json") }
        if (root as NSString).lastPathComponent == "emptyWindowChatSessions" {
            return entries(root).filter(isSession).map { root + "/" + $0 }
        }
        return entries(root).flatMap { hash in
            entries("\(root)/\(hash)/chatSessions").filter(isSession).map { "\(root)/\(hash)/chatSessions/\($0)" }
        }
    }

    /// The databases of a folder root: `opencode.db`, or for Kilo `kilo.db` and `kilo-<channel>.db`.
    static func openCodeDatabaseNames(_ d: HarnessDescriptor, in root: String) -> [String] {
        guard d.keyPrefixes.first == "kilo" else { return fileInfo(root + "/opencode.db") != nil ? ["opencode.db"] : [] }
        return entries(root).filter { $0 == "kilo.db" || ($0.hasPrefix("kilo-") && $0.hasSuffix(".db")) }
    }

    // MARK: Cline, Roo Code, Kilo Code

    func readClineTask(_ file: FileToRead, prefix: String, style: ClineTasksParser.Style) throws -> FileRead {
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let folder = (file.path as NSString).deletingLastPathComponent
        let taskID = (folder as NSString).lastPathComponent
        let modified = Self.fileInfo(file.path).map(Self.modified) ?? 0
        if file.path.hasSuffix(".messages.json") {
            let manifest = try? Data(contentsOf: URL(fileURLWithPath: "\(folder)/\(taskID).json"))
            return FileRead(events: try ClineTasksParser.cliEvents(data: data, manifest: manifest, sessionFallback: taskID,
                                                                  prefix: prefix, fallbackTime: modified, file: file.path),
                            end: file.limit)
        }
        let events = try ClineTasksParser.events(data: data, taskID: taskID, prefix: prefix, style: style, fallbackTime: modified,
                                                 hints: { Self.modelHints(folder) }, file: file.path)
        // The file is the whole truth of its task. Cline folds the usage of the messages a checkpoint restore drops into
        // a `deleted_api_reqs` row: the rows indexed from the dropped messages would count it a second time. So what
        // the index holds of this file is replaced by what the file holds now (an empty file, caught while the
        // extension rewrites it, is not a reading).
        return FileRead(events: events, end: file.limit, retirePrefixes: data.isEmpty ? [] : ["\(prefix):\(taskID):"])
    }

    /// Where a task names its model when the messages do not: Cline's `task_metadata.json`, else
    /// the last `<model>` tag in the conversation Roo and Kilo send.
    static func modelHints(_ folder: String) -> ClineTasksParser.ModelHints {
        var hints = ClineTasksParser.ModelHints()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: folder + "/task_metadata.json")),
           let root = (J.parse(data)) as? [String: Any] {
            for case let use as [String: Any] in (root["model_usage"] as? [Any]) ?? [] {
                guard let model = J.str(use["model_id"]) else { continue }
                let ts = J.double(use["ts"]) ?? 0
                hints.switches.append((ts: ts < 1e11 ? ts * 1000 : ts, model: model, provider: J.str(use["model_provider_id"])))
            }
        }
        if hints.switches.isEmpty,
           let history = try? Data(contentsOf: URL(fileURLWithPath: folder + "/api_conversation_history.json"), options: .mappedIfSafe) {
            let open = Data("<model>".utf8), close = Data("</model>".utf8)
            var end = history.endIndex
            // The last tag that has a closing partner; one cut off at the end of the file is skipped.
            while let tag = history.range(of: open, options: .backwards, in: history.startIndex..<end) {
                if let stop = history.range(of: close, in: tag.upperBound..<history.endIndex) {
                    let name = String(decoding: history[tag.upperBound..<stop.lowerBound], as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { hints.tagged = name; break }
                }
                end = tag.lowerBound
            }
        }
        return hints
    }

    // MARK: Copilot Chat

    func readCopilotChat(_ file: FileToRead) throws -> FileRead {
        let session = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var parser = CopilotChatParser()
        if file.path.hasSuffix(".jsonl") {
            _ = try readLines(file.whole) { parser.consume(line: $0) }
        } else {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            if !data.isEmpty { try parser.consume(document: data) }
        }
        return FileRead(events: parser.events(session: session, file: file.path), end: file.limit)
    }

    // MARK: Continue

    func readContinue(_ file: FileToRead, prefix: String) throws -> FileRead {
        var events: [UsageEvent] = []
        let end = try readLines(file) { line in
            if let e = ContinueParser.event(line: line, file: file.path, prefix: prefix) { events.append(e) }
        }
        return FileRead(events: events, end: end)
    }

    // MARK: Zed

    func readZed(_ file: FileToRead) throws -> FileRead {
        let path = file.path.hasSuffix("-wal") ? String(file.path.dropLast(4)) : file.path
        guard Self.fileInfo(path) != nil else { return FileRead(events: [], end: file.limit) }
        // `threads.db` and its `-wal` are two files of one database: when both changed, the first read covers both.
        if readThisPass.contains(path) { return FileRead(events: [], end: pairEnd(path, file.limit)) }
        let before = pairStamp(path)
        let db = try ExternalDB(path: path, immutable: false)
        var columns = Set<String>()
        try db.query("PRAGMA table_info(threads)") { row in
            if let name = ExternalDB.text(row, 1) { columns.insert(name) }
        }
        let created = columns.contains("created_at") ? "created_at" : "NULL"
        var events: [UsageEvent] = []
        var meta: [String: String] = [:]
        var retire: [String] = []
        // A thread that cannot be read costs that thread, not the file: the rest of the database counts.
        var problems: [String] = []
        func note(_ message: String) { if !problems.contains(message) { problems.append(message) } }
        // A compressed thread skipped for want of zstd: the file is left unrecorded below, so it is read again once
        // zstd is there (a thread already read keeps its stamp and is not read twice).
        var waitsForZstd = false
        try db.query("SELECT id, updated_at, \(created), data_type, data FROM threads") { row in
            guard let id = ExternalDB.text(row, 0) else { return }
            let updated = ExternalDB.text(row, 1)
            let data = ExternalDB.blob(row, 4)
            // A thread that has not changed since its last read has its rows in the index already.
            let stamp = "\(updated ?? "")|\(data.count)"
            let metaKey = "zed-thread:" + id
            if (pendingMeta[metaKey] ?? store.meta(metaKey)) == stamp { return }
            let type = (ExternalDB.text(row, 3) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let json: Data
            switch type {
            case "json": json = data
            case "zstd":
                do { json = try Self.unzstd(data) } catch {
                    // Without zstd every compressed thread fails alike: one line says so. Any other failure is the thread's own.
                    if !Zstd.isAvailable { waitsForZstd = true; note(Self.unzstdReason(error)) } else { note("\(id): " + Self.unzstdReason(error)) }
                    return
                }
            default:
                note(L10n.t("\(id): data_type \(type) bilinmiyor", "\(id): data_type \(type) is unknown"))
                return
            }
            // The thread's adjustment row is worked out again from this reading: the figure it holds can shrink when
            // the per-request counts catch up with the cumulative one, and the larger old row must not stay beside them.
            let thread = ZedParser.events(threadID: id, createdAt: ExternalDB.text(row, 2), updatedAt: updated, json: json, file: path)
            retire.append("zed:adj:" + id)
            events += thread
            meta[metaKey] = stamp
        }
        readThisPass.insert(path)
        pairStamps[path] = before
        let shown = problems.prefix(5).map { $0 } + (problems.count > 5 ? [L10n.t("(+\(problems.count - 5) iş parçacığı daha)", "(+\(problems.count - 5) more threads)")] : [])
        // The stamp is saved only when everything was read: a thread that waits for zstd keeps the database due.
        if !waitsForZstd { meta["dbstamp:" + path] = before }
        return FileRead(events: events, end: waitsForZstd ? 0 : file.limit, meta: meta, retire: retire, issues: shown)
    }

    /// Why a thread could not be unpacked, in the interface language and without the temporary file it was unpacked from.
    static func unzstdReason(_ error: Error) -> String {
        if let failure = error as? Zstd.Failure { return failure.summary }
        if let format = error as? EditorLogFormatError { return format.message }
        return L10n.t("açılamadı", "could not be unpacked")
    }

    /// Decompresses one zstd blob through the `zstd` the Codex archives already need.
    static func unzstd(_ blob: Data) throws -> Data {
        // Left unrecorded like a Codex archive: the whole database is read again once zstd is there.
        guard Zstd.isAvailable else {
            throw EditorLogFormatError(message: L10n.t("zstd yok: brew install zstd (Zed konuşmaları sıkıştırılmış, okunamıyor)", "zstd is missing: brew install zstd (Zed threads are compressed and cannot be read)"))
        }
        let path = NSTemporaryDirectory() + "tokenbar-zed-\(UUID().uuidString).zst"
        guard FileManager.default.createFile(atPath: path, contents: blob, attributes: [.posixPermissions: 0o600]) else {
            throw EditorLogFormatError(message: L10n.t("zstd için geçici dosya yazılamadı", "a temporary file for zstd could not be written"))
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        var out = Data()
        // A thread is one line of JSON: its size is the output's (what a Zed thread holds is far below this).
        do {
            try Zstd.forEachLine(path: path, maxLine: 256 << 20, maxOutput: 256 << 20) { line in
                out.append(contentsOf: line)
                // The thread is one line of JSON; a line break the decoder dropped is only whitespace to it.
                out.append(0x0A)
                return true
            }
        } catch let failure as Zstd.Failure {
            throw failure
        } catch {
            throw EditorLogFormatError(message: L10n.t("zstd çıktısı okunamadı", "the zstd output could not be read"))
        }
        return out
    }
}
