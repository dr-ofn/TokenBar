import Foundation

/// Turns a catalog entry into the files to read and the reader for them.
extension UsageScanner {
    func fileSource(_ d: HarnessDescriptor, roots: [String]) -> FileSource {
        let isJSONL: (String) -> Bool = { $0.hasSuffix(".jsonl") }
        let isRollout: (String) -> Bool = { $0.hasPrefix("rollout-") && ($0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.zst")) }
        let prefix = d.keyPrefixes.first ?? d.id.rawValue
        func under(_ below: String, _ match: @escaping (String) -> Bool) -> () -> [String] {
            { roots.flatMap { self.walk($0 + below, match) } }
        }
        switch d.family {
        case .anthropicJSONL:
            return FileSource(name: d.name, appendOnly: true, files: under("/projects", isJSONL), read: readClaude,
                              refresh: { filesRead in if filesRead > 0 { try self.updateClaudeAdjustments() } })
        case .codexRollout:
            return FileSource(name: d.name, appendOnly: true,
                              files: { roots.flatMap { self.walk($0 + "/sessions", isRollout) + self.walk($0 + "/archived_sessions", isRollout) } },
                              read: readCodex,
                              blocker: { $0.hasSuffix(".zst") && !Zstd.isAvailable ? Zstd.Failure.binaryMissing.localizedDescription : nil })
        case .openDesignEvents:
            return FileSource(name: d.name, appendOnly: false,
                              files: { roots.flatMap { self.walk($0) { $0 == "events.jsonl" } } },
                              read: { try self.readOpenDesign($0, prefix: prefix) })
        case .ompJSONL:
            return FileSource(name: d.name, appendOnly: true, files: under("/agent/sessions", isJSONL), read: readOmp)
        case .qwenUsage:
            return FileSource(name: d.name, appendOnly: true,
                              files: {
                                  roots.flatMap { self.walk($0 + "/usage") { $0.hasPrefix("token-usage-") && $0.hasSuffix(".jsonl") } }
                                      + roots.map { $0 + "/usage_record.jsonl" }
                              },
                              read: readQwen,
                              refresh: { filesRead in
                                  if filesRead > 0 || !self.store.hasEvents(prefix: "qwen:adj:") {
                                      try self.updateQwenAdjustments(records: roots.map { $0 + "/usage_record.jsonl" })
                                  }
                              })
        case .kimiWire:
            return FileSource(name: d.name, appendOnly: false, files: under("/sessions") { $0 == "wire.jsonl" }, read: readKimi)
        case .devinTranscripts:
            return FileSource(name: d.name, appendOnly: false, files: under("/cli/transcripts") { $0.hasSuffix(".json") }, read: readDevin)
        case .antigravitySQLite:
            return FileSource(name: d.name, appendOnly: false, files: under("/conversations") { $0.hasSuffix(".db") || $0.hasSuffix(".db-wal") },
                              read: readAntigravity, database: Self.databasePath)
        case .opencodeSQLite:
            // Read through `openCodeDatabases`, not as plain files.
            return FileSource(name: d.name, appendOnly: false, files: { [] }, read: { _ in FileRead(events: [], end: 0) })
        case .crushSQLite, .gooseSQLite:
            // Read through `scanG3` (databases found by a reader, or none at all).
            return FileSource(name: d.name, appendOnly: false, files: { [] }, read: { _ in FileRead(events: [], end: 0) })
        case .droidSettings:
            return FileSource(name: d.name, appendOnly: false,
                              files: { Self.unique(roots.flatMap { self.walk($0 + "/sessions") { $0.hasSuffix(".settings.json") } }) },
                              read: readDroid)
        case .ampThreads:
            return FileSource(name: d.name, appendOnly: false,
                              files: { Self.unique(roots.flatMap { self.walk($0 + "/threads") { $0.hasPrefix("T-") && $0.hasSuffix(".json") } }) },
                              read: readAmp)
        case .openhandsState:
            return FileSource(name: d.name, appendOnly: false, files: { Self.unique(roots.flatMap(self.openHandsStates)) }, read: readOpenHands)
        case .geminiChats, .piJSONL, .copilotEvents, .junieEvents, .codebuffChats, .vibeSessions, .augmentSessions, .qwenChats:
            return g1FileSource(d, roots: roots)
        case .clineTasks, .rooTasks, .copilotChat, .continueTokens, .zedThreads, .notCountable:
            return g2FileSource(d, roots: roots)
        }
    }

    /// The databases of an `opencode-sqlite` entry: a root that is a file is one; a folder holds
    /// `opencode.db`, and when the entry is recursive any `opencode*.db` at any depth. An entry of the built-in
    /// catalogue that is recursive keeps to the `data/opencode/` layout of a relocated XDG data home, as before.
    func openCodeDatabases(_ d: HarnessDescriptor, roots: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ path: String) { if seen.insert(path).inserted { out.append(path) } }
        for root in roots {
            var info = Darwin.stat()
            guard stat(root, &info) == 0 else {
                // EPERM as well: macOS privacy protection (TCC) refuses with it where a plain permission says EACCES.
                if errno == EACCES || errno == EPERM { Self.nameUnreadable(root, in: &walkProblems) }
                continue
            }
            let kind = info.st_mode & S_IFMT
            // A root that is a file is the database; a pipe, socket or device is never opened.
            if kind == S_IFREG { add(root); continue }
            guard kind == S_IFDIR else { continue }
            for name in Self.openCodeDatabaseNames(d, in: root, problems: &walkProblems) where !Self.isSpecialPath(root + "/" + name) {
                add(root + "/" + name)
            }
            guard d.recursive else { continue }
            for db in walk(root, { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }) where !Self.isSpecialPath(db) && (d.custom || db.contains("/data/opencode/")) { add(db) }
        }
        return out
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
