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
            try Zstd.forEachLine(path: file.path) { line in
                parser.consume(line: line)
                return true
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
        let end = try readLines(read) { parser.consume(line: $0) }
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
        if file.offset > 0 { seedHeader(&parser, file.path) }
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

    /// A resumed read starts past the header line that names the session and project.
    func seedHeader(_ parser: inout SessionParser, _ path: String) {
        _ = try? LineReader.forEachLine(path: path, from: 0) { line in
            _ = parser.consume(line: line, filePath: path)
            return false
        }
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

    func readAntigravity(_ file: FileToRead) throws -> FileRead {
        let conversation = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return FileRead(events: try AntigravityReader.events(dbPath: file.path, conversation: conversation), end: file.limit)
    }
}
