import Foundation

/// One reader per harness: what its files hold, and how much of them to read.
extension UsageScanner {
    /// Transcript lines become events; each session's cumulative cost summary is merged
    /// into the copy saved under `cc-cost:<sessionId>`.
    func readClaude(_ file: FileToRead) throws -> FileRead {
        var events: [UsageEvent] = []
        var costs: [String: ClaudeCostState] = [:]
        let end = try readLines(file) { line in
            if line.indexOf("\"type\":\"cost-state\"", limit: 300) >= 0 {
                guard let o = J.object(line), let session = J.str(o["sessionId"]) else { return }
                var state = try costs[session] ?? storedCost(session)
                state.merge(object: o)
                costs[session] = state
            } else if line.contains("\"usage\""), line.contains("\"assistant\""), let o = J.object(line) {
                events += ClaudeParser.events(object: o, file: file.path)
            }
        }
        // Saved with the events and the offset, in the same transaction.
        var meta: [String: String] = [:]
        for (session, state) in costs {
            if let data = try? JSONEncoder().encode(state) {
                meta[Self.costPrefix + session] = String(decoding: data, as: UTF8.self)
            }
        }
        return FileRead(events: events, end: end, meta: meta)
    }

    static let costPrefix = "cc-cost:"

    /// The session's saved cost summary. A value that no longer decodes throws instead of
    /// being replaced: the runs it holds appear in no transcript, so they are irreplaceable.
    func storedCost(_ session: String) throws -> ClaudeCostState {
        guard let saved = pendingMeta[Self.costPrefix + session] ?? store.meta(Self.costPrefix + session) else { return ClaudeCostState() }
        return try JSONDecoder().decode(ClaudeCostState.self, from: Data(saved.utf8))
    }

    func readCodex(_ file: FileToRead) throws -> FileRead {
        let session = String((file.path as NSString).lastPathComponent.prefix { $0 != "." })
        let key = "cx-state:" + file.path
        if file.path.hasSuffix(".zst") {
            // Finished rollouts are compressed and never change: always whole, from a clean state.
            var parser = CodexParser(state: .init(), fallbackSession: session, file: file.path)
            do {
                try Zstd.forEachLine(path: file.path) { line in
                    parser.consume(line: line)
                    return true
                }
            } catch let failure as Zstd.Failure {
                // What was read before the limit counts (the totals are cumulative); the archive is named once and, being
                // recorded, is not unpacked again on every pass.
                guard case .tooLarge = failure else { throw failure }
                return FileRead(events: parser.events, end: file.limit, issues: [failure.localizedDescription])
            }
            // The offset is in the file's own units, its size on disk: not the decompressed length.
            return FileRead(events: parser.events, end: file.limit)
        }
        // Totals are cumulative: a resumed read without its saved state would count the
        // whole file again, so a read whose state is lost restarts from byte 0.
        var read = file
        var state = CodexParser.State()
        if file.offset > 0 {
            if let saved = store.meta(key), let decoded = try? JSONDecoder().decode(CodexParser.State.self, from: Data(saved.utf8)) {
                state = decoded
            } else {
                read.offset = 0
            }
        }
        var parser = CodexParser(state: state, fallbackSession: session, file: file.path)
        var end = try readLines(read) { parser.consume(line: $0) }
        if parser.needsRestart {
            // The model came after rows that were written as `unknown`: read the file again from its start, from a clean
            // state, so every call carries the model (the store gives the model to a row that had none).
            read.offset = 0
            parser = CodexParser(state: .init(), fallbackSession: session, file: file.path)
            end = try readLines(read) { parser.consume(line: $0) }
        }
        var out = FileRead(events: parser.events, end: end)
        // The state rides along with the events and offset: written ahead of them, a
        // failed commit would make the retried tail look like a counter reset.
        if let data = try? JSONEncoder().encode(parser.state) {
            out.meta[key] = String(decoding: data, as: UTF8.self)
        }
        return out
    }

    /// Runs are re-read whole and deduped by key, so the offset is ignored.
    func readOpenDesign(_ file: FileToRead, prefix: String) throws -> FileRead {
        let run = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var parser = OpenDesignParser(session: run, file: file.path, prefix: prefix)
        var events: [UsageEvent] = []
        _ = try readLines(file.whole) { line in
            if let e = parser.consume(line: line) { events.append(e) }
        }
        return FileRead(events: events, end: file.limit)
    }

    func readOmp(_ file: FileToRead) throws -> FileRead {
        var parser = SessionParser(sessionID: Self.ompSession(file.path), cwd: nil)
        var events: [UsageEvent] = []
        seedHeader(&parser, file.path)
        let end = try readLines(file) { line in
            if let e = parser.consume(line: line, filePath: file.path) { events.append(e) }
        }
        return FileRead(events: events, end: end)
    }

    /// `<cwd-slug>/<ts>_<uuid>.jsonl` or `<uuid>/<Name>.jsonl`: the id follows the last `_`.
    static func ompSession(_ path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return base.lastIndex(of: "_").map { String(base[base.index(after: $0)...]) } ?? base
    }

    /// The header line names the session and project, whether this read starts at the top of the file or past it; it is
    /// read here, by one rule (see `SessionParser.seedHeader`), and the lines that follow do not change it.
    func seedHeader(_ parser: inout SessionParser, _ path: String) {
        parser.seedHeader(path: path)
        parser.adoptsHeaderLines = false
    }

    /// `usage_record.jsonl` only feeds the adjustment pass, which reads it whole itself: this
    /// read only moves its offset to the end, without walking the file a second time.
    func readQwen(_ file: FileToRead) throws -> FileRead {
        if file.path.hasSuffix("usage_record.jsonl") { return FileRead(events: [], end: file.limit) }
        var events: [UsageEvent] = []
        let end = try readLines(file) { line in
            if let e = QwenParser.event(line: line, file: file.path) { events.append(e) }
        }
        return FileRead(events: events, end: end)
    }

    func readKimi(_ file: FileToRead) throws -> FileRead {
        // .../sessions/<wd>/<session>/agents/<agent>/wire.jsonl
        let parts = file.path.components(separatedBy: "/")
        let session = parts.count >= 4 ? parts[parts.count - 4] : file.path
        var parser = KimiParser(sessionID: session, file: file.path)
        _ = try readLines(file.whole) { parser.consume(line: $0) }
        return FileRead(events: parser.events, end: file.limit)
    }

    func readDevin(_ file: FileToRead) throws -> FileRead {
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let fallback = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return FileRead(events: DevinParser.events(data: data, fallbackSession: fallback, file: file.path), end: file.limit)
    }

    /// Antigravity's conversation databases are in WAL mode: a write may touch only `<id>.db-wal`, so that file is listed
    /// too and its change wakes the same read. The pair is read once per pass, from a copy that holds the `-wal`.
    func readAntigravity(_ file: FileToRead) throws -> FileRead {
        let path = file.path.hasSuffix("-wal") ? String(file.path.dropLast(4)) : file.path
        guard Self.fileInfo(path) != nil, !Self.isSpecialPath(path) else { return FileRead(events: [], end: file.limit) }
        if readThisPass.contains(path) { return FileRead(events: [], end: pairEnd(path, file.limit)) }
        let conversation = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let before = pairStamp(path)
        let events = try AntigravityReader.events(dbPath: path, conversation: conversation)
        readThisPass.insert(path)
        pairStamps[path] = before
        afterPairRead?(path)
        return FileRead(events: events, end: file.limit, meta: ["dbstamp:" + path: before])
    }

    /// The database a listed file belongs to: the file itself, or for `<id>.db-wal` the `<id>.db`.
    static func databasePath(_ file: String) -> String {
        file.hasSuffix("-wal") ? String(file.dropLast(4)) : file
    }

    /// The stamp of a database and its `-wal` together, each file on its own (a sum of two mtimes is the same for
    /// different pairs). The `-wal` is the one beside the real file when the database is a link.
    func pairStamp(_ path: String) -> String {
        (Self.fileInfo(path).map(Self.stamp) ?? "-") + "|" + (Self.fileInfo(ExternalDB.resolvedPath(path) + "-wal").map(Self.stamp) ?? "-")
    }

    /// Where the second file of a pair, already read in this pass, is recorded as read: its whole size when the pair is
    /// as it was when it was read, 0 (read again next pass) when a write came in between.
    func pairEnd(_ path: String, _ limit: UInt64) -> UInt64 {
        pairStamps[path] == pairStamp(path) ? limit : 0
    }
}
