import Foundation

/// Tools whose logs are JSON or JSONL sessions: Gemini CLI, Pi, GitHub Copilot CLI, Junie, Codebuff,
/// Mistral Vibe, Augment, and Qwen Code's newer chat files.
extension UsageScanner {
    func g1FileSource(_ d: HarnessDescriptor, roots: [String]) -> FileSource {
        func files(_ below: String, _ match: @escaping (String) -> Bool) -> () -> [String] {
            { roots.flatMap { self.walk($0 + below, match) } }
        }
        switch d.family {
        case .geminiChats:
            return FileSource(name: d.name, appendOnly: false,
                              files: { files("") { $0.hasSuffix(".json") || $0.hasSuffix(".jsonl") }().filter { $0.contains("/chats/") } },
                              read: readGemini)
        case .piJSONL:
            return FileSource(name: d.name, appendOnly: true, files: files("/sessions") { $0.hasSuffix(".jsonl") }, read: readPi)
        case .copilotEvents:
            return FileSource(name: d.name, appendOnly: false, files: files("/session-state") { $0 == "events.jsonl" }, read: readCopilot)
        case .junieEvents:
            return FileSource(name: d.name, appendOnly: true, files: files("/sessions") { $0 == "events.jsonl" }, read: readJunie)
        case .codebuffChats:
            return FileSource(name: d.name, appendOnly: false, files: files("/projects") { $0 == "chat-messages.json" }, read: readCodebuff)
        case .vibeSessions:
            return FileSource(name: d.name, appendOnly: false,
                              files: files("/logs/session") { $0 == "meta.json" || ($0.hasPrefix("session_") && $0.hasSuffix(".json")) },
                              read: readVibe)
        case .augmentSessions:
            return FileSource(name: d.name, appendOnly: false, files: files("/sessions") { $0.hasSuffix(".json") }, read: readAugment)
        case .qwenChats:
            return FileSource(name: d.name, appendOnly: true,
                              files: {
                                  roots.filter { !Self.qwenKeepsOwnAccounting($0) }
                                      .flatMap { self.walk($0 + "/projects") { $0.hasSuffix(".jsonl") } }
                                      .filter { $0.contains("/chats/") }
                              },
                              read: readQwenChat,
                              refresh: { _ in
                                  // Qwen's own usage files appeared after the chat rows were counted: they are
                                  // the same calls, so the chat rows go.
                                  if roots.contains(where: Self.qwenKeepsOwnAccounting), self.store.hasEvents(prefix: "qwenc:") {
                                      try self.store.replaceEvents(prefix: "qwenc:", with: [])
                                  }
                              })
        default:
            return FileSource(name: d.name, appendOnly: false, files: { [] }, read: { _ in FileRead(events: [], end: 0) })
        }
    }

    // MARK: Gemini CLI

    func readGemini(_ file: FileToRead) throws -> FileRead {
        let stem = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var parser = GeminiChatParser(fallbackSession: stem, file: file.path)
        if file.path.hasSuffix(".jsonl") {
            _ = try readLines(file.whole) { line in
                if let o = J.object(line) { parser.consume(object: o) }
            }
        } else {
            // A file that cannot be read is an issue, read again next pass; text that is not JSON counts nothing.
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            if let o = (J.parse(data)) as? [String: Any] { parser.consume(object: o) }
        }
        return FileRead(events: parser.events(), end: file.limit)
    }

    // MARK: Pi

    func readPi(_ file: FileToRead) throws -> FileRead {
        var parser = SessionParser(sessionID: Self.ompSession(file.path), cwd: nil, piFormat: true)
        var events: [UsageEvent] = []
        seedHeader(&parser, file.path)
        let end = try readLines(file) { line in
            if let e = parser.consume(line: line, filePath: file.path) { events.append(e) }
        }
        return FileRead(events: events, end: end)
    }

    // MARK: GitHub Copilot CLI

    func readCopilot(_ file: FileToRead) throws -> FileRead {
        let session = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var parser = CopilotParser(session: session, file: file.path)
        _ = try readLines(file.whole) { parser.consume(line: $0) }
        return FileRead(events: parser.events(), end: file.limit)
    }

    // MARK: Junie

    func readJunie(_ file: FileToRead) throws -> FileRead {
        let session = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let fallback = Self.fileInfo(file.path).map(Self.modified) ?? 0
        var events: [UsageEvent] = []
        let end = try readLines(file) { line in
            events += JunieParser.events(line: line, session: session, file: file.path, fallbackTime: fallback)
        }
        return FileRead(events: events, end: end)
    }

    // MARK: Codebuff

    func readCodebuff(_ file: FileToRead) throws -> FileRead {
        // .../<channel>/projects/<project>/chats/<chatId>/chat-messages.json
        let parts = file.path.components(separatedBy: "/")
        let n = parts.count
        let chat = n >= 2 ? parts[n - 2] : "", project = n >= 4 ? parts[n - 4] : "", channel = n >= 6 ? parts[n - 6] : ""
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let events = CodebuffParser.events(data: data, session: "\(channel)/\(project)/\(chat)", chatTime: CodebuffParser.chatTime(chat),
                                           fallbackTime: Self.fileInfo(file.path).map(Self.modified) ?? 0, file: file.path)
        return FileRead(events: events, end: file.limit)
    }

    // MARK: Mistral Vibe

    func readVibe(_ file: FileToRead) throws -> FileRead {
        let name = (file.path as NSString).lastPathComponent
        let fallback = name == "meta.json" ? ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            : (name as NSString).deletingPathExtension
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let events = VibeParser.events(data: data, fallbackSession: fallback,
                                       fallbackTime: Self.fileInfo(file.path).map(Self.modified) ?? 0, file: file.path)
        return FileRead(events: events, end: file.limit)
    }

    // MARK: Augment

    func readAugment(_ file: FileToRead) throws -> FileRead {
        let stem = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let events = AugmentParser.events(data: data, fallbackSession: stem,
                                          fallbackTime: Self.fileInfo(file.path).map(Self.modified) ?? 0, file: file.path)
        return FileRead(events: events, end: file.limit)
    }

    // MARK: Qwen Code chat files

    /// Qwen's own accounting (`usage/token-usage-*.jsonl`, `usage_record.jsonl`) already holds the calls
    /// the chat files show, so the chat files are read only where it is absent.
    static func qwenKeepsOwnAccounting(_ root: String) -> Bool {
        if fileInfo(root + "/usage_record.jsonl") != nil { return true }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root + "/usage") else { return false }
        return names.contains { $0.hasPrefix("token-usage-") && $0.hasSuffix(".jsonl") }
    }

    func readQwenChat(_ file: FileToRead) throws -> FileRead {
        let parts = file.path.components(separatedBy: "/")
        let n = parts.count
        let stem = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let session = "\(n >= 4 ? parts[n - 3] : "")-\(stem)"
        var events: [UsageEvent] = []
        let end = try readLines(file) { line in
            if let e = QwenChatParser.event(line: line, session: session, file: file.path) { events.append(e) }
        }
        return FileRead(events: events, end: end)
    }
}
