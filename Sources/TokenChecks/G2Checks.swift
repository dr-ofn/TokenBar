import Foundation
import SQLite3
import LocalCore

// G2: editor extensions and IDEs (Cline, Roo Code, Kilo Code, Copilot Chat, Continue, Zed, and the
// tools found but never counted). The fixture rows are written into the fixture home, which
// check.sh then reads with the CLI and with scripts/oracle.py; the totals are worked out by hand.

private func json(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// A `ui_messages.json` row: `text` is itself a JSON string.
private func taskRow(_ ts: Int, _ payload: [String: Any], say: String = "api_req_started", info: [String: Any]? = nil) -> [String: Any] {
    var row: [String: Any] = ["ts": ts, "type": "say", "say": say, "text": json(payload)]
    if let info { row["modelInfo"] = info }
    return row
}

private func writeJSON(_ path: String, _ value: Any) throws { try write(path, json(value)) }

/// A Zed thread as the database holds it: zstd-compressed when this machine has zstd, else stored as plain JSON (the
/// same thread, the same totals; only the compressed way in is not exercised, and the run says so).
private func zedThread(_ bytes: String, in dir: String) throws -> (type: String, data: Data) {
    let path = dir + "/" + UUID().uuidString + ".json"
    try write(path, bytes)
    if zstdUsable, try zstdPack(path, keep: false) { return ("zstd", try Data(contentsOf: URL(fileURLWithPath: path + ".zst"))) }
    return ("json", Data(bytes.utf8))
}

private func insertThread(_ db: String, id: String, updated: String, created: String?, type: String, data: Data) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(db, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "sqlite", code: 1) }
    defer { sqlite3_close(handle) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "INSERT INTO threads(id, summary, updated_at, data_type, data, created_at) VALUES(?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK,
          let stmt else { throw NSError(domain: "sqlite", code: 2) }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
    sqlite3_bind_text(stmt, 2, "t", -1, sqliteTransient)
    sqlite3_bind_text(stmt, 3, updated, -1, sqliteTransient)
    sqlite3_bind_text(stmt, 4, type, -1, sqliteTransient)
    _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32(data.count), sqliteTransient) }
    if let created { sqlite3_bind_text(stmt, 6, created, -1, sqliteTransient) } else { sqlite3_bind_null(stmt, 6) }
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "sqlite", code: 3) }
}

private let appSupport = "/Library/Application Support"
private let cutoffMs = 1_762_041_600_000   // 2025-11-02T00:00:00Z
private let afterCutoff = 1_793_968_800_000 // 2026-11-06T10:00:00Z

/// The watch folders the catalog should add for these tools, written out by hand: the editors with
/// their three extensions (each with `tasks`, Cline also `sessions`), Cline's CLI, Kilo's
/// database folder, Copilot's four storage folders, Continue and Zed. The never-counted tools add none.
func g2WatchPathsWanted() -> [String] {
    let editors = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Kiro", "Positron", "Trae", "Antigravity"]
    var out: [String] = []
    for editor in editors {
        let storage = "Library/Application Support/\(editor)/User/globalStorage/"
        out += [storage + "saoudrizwan.claude-dev/tasks", storage + "saoudrizwan.claude-dev/sessions",
                storage + "rooveterinaryinc.roo-cline/tasks", storage + "kilocode.kilo-code/tasks"]
    }
    out += [".cline/data/tasks", ".cline/data/sessions", ".local/share/kilo", ".continue/dev_data",
            "Library/Application Support/Zed/threads"]
    for editor in ["Code", "Code - Insiders"] {
        out += ["Library/Application Support/\(editor)/User/workspaceStorage",
                "Library/Application Support/\(editor)/User/globalStorage/emptyWindowChatSessions"]
    }
    return out
}

func g2Probe(_ name: String, dir: String) -> String? {
    switch name {
    case "g2-zed-zstd-missing":
        // TOKENBAR_ZSTD=none comes from the parent: a Zed thread that is compressed cannot be read,
        // and that is one named issue, not a silent zero.
        do {
            let home = dir + "/home"
            let db = home + appSupport + "/Zed/threads/threads.db"
            try runSQL(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT, updated_at TEXT, data_type TEXT, data BLOB);")
            try runSQL(db, "INSERT INTO threads VALUES('plain','t','2026-11-06T10:00:00Z','json', CAST('{\"model\":{\"provider\":\"zed.dev\",\"model\":\"m\"},\"request_token_usage\":{\"a\":{\"input_tokens\":5}}}' AS BLOB));")
            let store = try UsageStore(path: dir + "/u.sqlite")
            let before = UsageScanner(store: store, home: home, environment: [:]).scan()
            try runSQL(db, "INSERT INTO threads VALUES('packed','t','2026-11-06T10:01:00Z','zstd', x'28b52ffd');")
            let after = UsageScanner(store: store, home: home, environment: [:]).scan().issues.filter { $0.source == "Zed" }
            // Left unrecorded, so the whole database is read again once zstd is there.
            let record = try store.fileRecords()[db]
            let recorded = record.map { $0.offset >= $0.size } ?? false
            return "plain=\(before.issues.filter { $0.source == "Zed" }.count) issues=\(after.count) message=\(after.first?.message ?? "-") events=\(try store.eventCount()) recorded=\(recorded)"
        } catch { return "probe error: \(error)" }
    default:
        return nil
    }
}

func g2Checks(home: String, tempDir: () throws -> String) throws {
    // MARK: fixture, written into the fixture home

    let code = home + appSupport + "/Code/User/globalStorage/"
    // Cline in VS Code: two calls with the four counts apart, a call still running (no counts), a malformed
    // text, a note, and the usage of messages a checkpoint restore dropped.
    let clineTask = code + "saoudrizwan.claude-dev/tasks/1793968700000"
    try writeJSON(clineTask + "/ui_messages.json", [
        ["ts": 1793968700000, "type": "say", "say": "text", "text": "hello"],
        ["ts": 1793968710000, "type": "say", "say": "text", "images": ["data:image/png;base64,AAAA", "x"],
         "text": "braces } ] \" \\ {\"say\":\"api_req_started\",\"tokensIn\":999999}"],
        taskRow(afterCutoff, ["request": "a", "tokensIn": 100, "tokensOut": 20, "cacheWrites": 10, "cacheReads": 30, "cost": 0.5]),
        taskRow(afterCutoff + 60_000, ["request": "b", "tokensIn": 50, "tokensOut": 5, "cacheWrites": 0, "cacheReads": 0, "cost": 0]),
        taskRow(afterCutoff + 120_000, ["request": "c"]),
        ["ts": afterCutoff + 130_000, "type": "say", "say": "api_req_started", "text": "not json"],
        taskRow(afterCutoff + 140_000, ["tokensIn": 7, "tokensOut": 3], say: "deleted_api_reqs"),
    ] as [Any])
    try writeJSON(clineTask + "/task_metadata.json", ["model_usage": [
        ["ts": afterCutoff - 1000, "model_id": "claude-sonnet-4-5", "model_provider_id": "anthropic", "mode": "act"]]])
    // The same task in Cursor (a copy the editors do not share): its calls are counted once.
    try FileManager.default.createDirectory(atPath: home + appSupport + "/Cursor/User/globalStorage/saoudrizwan.claude-dev/tasks",
                                            withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: clineTask, toPath: home + appSupport
                                     + "/Cursor/User/globalStorage/saoudrizwan.claude-dev/tasks/1793968700000")
    // Cline CLI: `inputTokens` holds the cache counts.
    try writeJSON(home + "/.cline/data/sessions/cs1/cs1.messages.json", ["sessionId": "cs1", "messages": [
        ["id": "u1", "role": "user", "ts": afterCutoff, "content": [["type": "text", "text": "hi"]]],
        ["id": "a1", "role": "assistant", "ts": afterCutoff, "modelInfo": ["id": "claude-sonnet-4-5", "provider": "anthropic"],
         "metrics": ["inputTokens": 1000, "outputTokens": 40, "cacheReadTokens": 600, "cacheWriteTokens": 100, "cost": 0.1]],
        ["id": "a2", "role": "assistant", "ts": afterCutoff + 5000, "metrics": ["inputTokens": 500, "outputTokens": 10]],
        ["id": "a3", "role": "assistant", "ts": afterCutoff + 6000],
    ] as [Any]])
    try writeJSON(home + "/.cline/data/sessions/cs1/cs1.json", ["session_id": "cs1", "provider": "anthropic", "model": "claude-sonnet-4-5"])

    // Roo Code (in Insiders): `tokensIn` holds the cache counts from November 2025, and before that
    // only on the OpenAI protocol. The model comes from the last <model> tag of the conversation.
    let roo = home + appSupport + "/Code - Insiders/User/globalStorage/rooveterinaryinc.roo-cline/tasks/roo-task-1"
    func rooPayload(_ tokensIn: Int, _ extra: [String: Any]) -> [String: Any] {
        var p: [String: Any] = ["tokensIn": tokensIn, "tokensOut": 10, "cacheReads": 600, "cacheWrites": 100, "cost": 0.1]
        p.merge(extra) { $1 }
        return p
    }
    try writeJSON(roo + "/ui_messages.json", [
        taskRow(afterCutoff, rooPayload(1000, ["apiProtocol": "anthropic"])),
        taskRow(1_730_000_000_000, rooPayload(300, ["apiProtocol": "anthropic"])),
        taskRow(1_730_000_001_000, rooPayload(1000, ["apiProtocol": "openai"])),
        taskRow(1_730_000_002_000, rooPayload(300, [:])),
    ] as [Any])
    try writeJSON(roo + "/api_conversation_history.json", [
        ["role": "user", "content": [["type": "text", "text": "<environment_details>\n<model>old-model</model>\n</environment_details>"]]],
        ["role": "user", "content": [["type": "text", "text": "<environment_details>\n<model>claude-sonnet-4-5</model>\n</environment_details>"]]],
    ] as [Any])
    // Kilo Code's task folders (VSCodium), the model in the message itself.
    try writeJSON(home + appSupport + "/VSCodium/User/globalStorage/kilocode.kilo-code/tasks/kilo-task-1/ui_messages.json", [
        taskRow(afterCutoff, ["tokensIn": 200, "tokensOut": 20, "cacheReads": 50, "cacheWrites": 0],
                info: ["providerId": "kilo", "modelId": "kilo-auto/frontier"]),
    ] as [Any])
    // Kilo Code 7 and its CLI: opencode's schema, `kilo.db` and one database per channel.
    func kiloDB(_ name: String, _ id: String, input: Int, output: Int, reasoning: Int, cacheRead: Int, cacheWrite: Int) throws {
        let path = home + "/.local/share/kilo/" + name
        try runSQL(path, "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT);")
        let row = json(["role": "assistant", "providerID": "kilo", "modelID": "anthropic/claude-sonnet-4",
                        "tokens": ["input": input, "output": output, "reasoning": reasoning, "cache": ["read": cacheRead, "write": cacheWrite]],
                        "time": ["created": 1793968800]] as [String: Any])
        let user = json(["role": "user", "tokens": ["input": 999, "output": 999]] as [String: Any])
        try runSQL(path, "INSERT INTO session VALUES('ks','/fixture'); INSERT INTO message VALUES('\(id)','ks','\(row)',1); INSERT INTO message VALUES('\(id)-u','ks','\(user)',2);")
    }
    try kiloDB("kilo.db", "k-1", input: 40, output: 6, reasoning: 2, cacheRead: 3, cacheWrite: 2)
    try kiloDB("kilo-canary.db", "k-2", input: 4, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0)

    // Copilot Chat: a session built from patches (a request still empty in the snapshot, filled in by
    // paths, one appended, a nested append that must not move the positions, another provider's request,
    // a request whose counts sit only under result.metadata), its stale copy from an empty window, an old .json session.
    let copilot = home + appSupport + "/Code/User/"
    let session = copilot + "workspaceStorage/abc123/chatSessions/sess-1.jsonl"
    let request0: [String: Any] = ["requestId": "r0", "timestamp": afterCutoff, "modelId": "copilot/gpt-6-luna", "message": ["text": "x"]]
    let request2: [String: Any] = ["timestamp": afterCutoff + 120_000, "modelId": "gpt-x", "promptTokens": 999, "completionTokens": 99]
    let request3: [String: Any] = ["timestamp": afterCutoff + 180_000, "modelId": "copilot/x",
                                   "result": ["metadata": ["promptTokens": 70, "outputTokens": 7, "resolvedModel": "m3"]]]
    let lines: [Any] = [
        ["kind": 0, "v": ["version": 3, "requests": [request0]]],
        ["kind": 1, "k": ["requests", 0, "promptTokens"], "v": 1200],
        ["kind": 1, "k": ["requests", 0, "completionTokens"], "v": 80],
        ["kind": 1, "k": ["requests", 0, "result"], "v": ["metadata": ["resolvedModel": "gpt-6-luna-2026"], "timings": ["t": 1]]],
        ["kind": 2, "k": ["requests", 0, "response"], "v": [["value": "text"]]],
        ["kind": 2, "k": ["requests"], "v": [["timestamp": afterCutoff + 60_000, "modelId": "copilot/auto", "promptTokens": 500, "completionTokens": 20], request2, request3]],
        ["kind": 1, "k": ["requests", 999_999, "promptTokens"], "v": 5],
        ["kind": 1, "k": ["requests", 1, "result", "metadata", "resolvedModel"], "v": "auto-resolved"],
    ]
    // Written as VS Code writes them (kind, k, v), which `json` would reorder: the patches the reader passes over
    // without decoding (a streamed response), and one it must apply (a count, set by path).
    let raw = [#"{"kind":1,"k":["requests",0,"response"],"v":[{"value":"streamed text } ] with \" brackets"}]}"#,
               #"{"kind":2,"k":["requests",1,"response"],"v":[{"value":"more"}]}"#,
               #"{"kind":1,"k":["requests",1,"completionTokens"],"v":25}"#,
               #"{"kind":1,"k":["requests",1,"followups"],"v":[]}"#]
    try write(session, (lines.map(json) + raw).joined(separator: "\n") + "\n")
    let stale: [Any] = [["kind": 0, "v": ["requests": [["timestamp": afterCutoff, "modelId": "copilot/gpt-6-luna", "promptTokens": 1200, "completionTokens": 40]]]]]
    try write(copilot + "globalStorage/emptyWindowChatSessions/sess-1.jsonl", stale.map(json).joined(separator: "\n") + "\n")
    try writeJSON(copilot + "globalStorage/emptyWindowChatSessions/old-1.json",
                  ["version": 3, "requests": [["timestamp": afterCutoff + 300_000, "modelId": "copilot/gpt-6-luna", "promptTokens": 30, "completionTokens": 3]]])

    // Continue: Continue's own counts; a repeated line is one call, and a line without a model is none.
    let continueLine = json(["timestamp": "2026-11-06T10:00:00.000Z", "model": "qwen3.8-flash-next", "provider": "ollama", "promptTokens": 120,
                             "generatedTokens": 30, "eventName": "tokensGenerated", "schema": "0.2.0", "userId": ""] as [String: Any])
    let second = json(["timestamp": "2026-11-06T10:00:05.000Z", "model": "gpt-6-luna", "provider": "openai", "promptTokens": 10, "generatedTokens": 5] as [String: Any])
    try write(home + "/.continue/dev_data/0.2.0/tokensGenerated.jsonl",
              [continueLine, continueLine, second, json(["promptTokens": 5, "generatedTokens": 5] as [String: Any]), "garbage"].joined(separator: "\n") + "\n")

    // Zed: a plain thread whose cumulative figure holds more than its requests, a compressed thread
    // with its requests, a compressed thread with none, and an imported one that is not Zed's own usage.
    let scratch = home + "/scratch/g2-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    let zedDB = home + appSupport + "/Zed/threads/threads.db"
    try runSQL(zedDB, "CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL, data BLOB NOT NULL, created_at TEXT);")
    func usage(_ input: Int, _ output: Int, _ cacheWrite: Int = 0, _ cacheRead: Int = 0) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "cache_creation_input_tokens": cacheWrite, "cache_read_input_tokens": cacheRead]
    }
    let t1: [String: Any] = ["model": ["provider": "zed.dev", "model": "claude-sonnet-4-5"],
                             "request_token_usage": ["m1": usage(100, 20, 10, 30), "m2": usage(50, 5)],
                             "cumulative_token_usage": usage(180, 25, 10, 30)]
    let t2: [String: Any] = ["model": ["provider": "openai-subscribed", "model": "gpt-6-luna"],
                             "request_token_usage": ["m1": usage(40, 8, 0, 2)], "cumulative_token_usage": usage(40, 8, 0, 2)]
    let t3: [String: Any] = ["model": ["provider": "zed.dev", "model": "claude-sonnet-4-5"], "request_token_usage": [String: Any](),
                             "cumulative_token_usage": usage(10, 2)]
    let t4: [String: Any] = ["model": ["provider": "zed.dev", "model": "claude-sonnet-4-5"], "imported": true,
                             "request_token_usage": ["m1": usage(777, 7)]]
    try insertThread(zedDB, id: "t1", updated: "2026-11-06T10:00:00.123456+00:00", created: "2026-11-06T09:00:00+00:00", type: "json", data: Data(json(t1).utf8))
    if !zstdUsable { skip("zed threads read through zstd (stored as plain JSON instead)", zstdWhy) }
    let packed2 = try zedThread(json(t2), in: scratch), packed3 = try zedThread(json(t3), in: scratch)
    try insertThread(zedDB, id: "t2", updated: "2026-11-06T10:01:00+00:00", created: nil, type: packed2.type, data: packed2.data)
    try insertThread(zedDB, id: "t3", updated: "2026-11-06T10:02:00+00:00", created: nil, type: packed3.type, data: packed3.data)
    try insertThread(zedDB, id: "t4", updated: "2026-11-06T10:03:00+00:00", created: nil, type: "json", data: Data(json(t4).utf8))

    // Found, never counted: a log line with token-looking numbers must stay uncounted.
    try write(home + "/.kiro/sessions/cli/k.jsonl", #"{"input_token_count":999999,"output_token_count":999999}"# + "\n")
    try FileManager.default.createDirectory(atPath: home + "/.codeium/windsurf", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: home + appSupport + "/Trae", withIntermediateDirectories: true)

    // MARK: totals by hand

    // Cline: 100+20+10+30 = 160; 50+5 = 55; the dropped messages 7+3 = 10; the CLI 300+40+600+100 = 1040 and 500+10 = 510.
    // Roo Code: every row is 300 fresh + 600 + 100 + 10 = 1010 once the cache counts are taken out of tokensIn; four rows.
    // Kilo Code: 150+50+20 = 220; kilo.db 40+3+2+(6+2) = 53; the canary 4+1 = 5.
    // Copilot Chat: 1200+80 = 1280; 500+25 (the count set by path) = 525; 70+7 = 77; the old session 30+3 = 33.
    // Continue: 120+30 = 150, 10+5 = 15. Zed: 160 + 55 + 30 (the gap) = 245; 40+8+2 = 50; the gap of t3 10+2 = 12.
    let hand: [HarnessID: (total: Int64, calls: Int)] = [
        .cline: (160 + 55 + 10 + 1040 + 510, 5), .rooCode: (4 * 1010, 4), .kiloCode: (220 + 53 + 5, 3),
        .copilotChat: (1280 + 525 + 77 + 33, 4), .continueDev: (165, 2), .zed: (245 + 50 + 12, 3),
    ]

    let dir = try tempDir()
    let store = try UsageStore(path: dir + "/g2.sqlite")
    let scanner = UsageScanner(store: store, home: home, environment: [:])
    let first = scanner.scan()
    let report = try store.usageBook(now: Date(timeIntervalSince1970: 1793970000)).report(for: .all)
    let seen = Dictionary(uniqueKeysWithValues: report.harnesses.map { ($0.harness, ($0.tokens, $0.calls)) })
    check("G2 scan reads every fixture without an issue", first.issues.isEmpty)
    for (id, want) in hand.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        check("G2 hand totals: \(id.rawValue)", seen[id]?.0 == want.total && seen[id]?.1 == want.calls)
    }
    check("G2 tools that are never counted add no row", Set(seen.keys).isDisjoint(with: [.kiro, .cursor, .windsurf, .trae]))
    check("a tool found but not countable is reported as such", first.notCountable.filter { [HarnessID.kiro, .cursor, .windsurf, .trae].contains($0) } == [.kiro, .cursor, .windsurf, .trae]
          && Set([HarnessID.kiro, .cursor, .windsurf, .trae]).isSubset(of: first.detected))
    check("a second scan adds nothing", scanner.scan().events == 0)

    // The same fixture through scripts/oracle.py, which shares no code with the scanner.
    if let oracle = g2OracleTotals(home: home) {
        let agree = hand.allSatisfy { id, want in oracle[id.rawValue]?.0 == want.total && oracle[id.rawValue]?.1 == want.calls }
        check("G2 oracle agrees with the hand totals", agree)
    } else {
        check("G2 oracle ran", false)
    }

    try g2EdgeChecks(tempDir: tempDir)
}

/// Per-harness (total, calls) from `scripts/oracle.py`, run over the fixture home.
private func g2OracleTotals(home: String) -> [String: (Int64, Int)]? {
    var folder = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    var script: String?
    for _ in 0..<6 {
        let candidate = folder.appendingPathComponent("scripts/oracle.py").path
        if FileManager.default.fileExists(atPath: candidate) { script = candidate; break }
        folder = folder.deletingLastPathComponent()
    }
    guard let script else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script, "all"]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let harnesses = root["harnesses"] as? [String: [String: Any]] else { return nil }
    return harnesses.mapValues { (($0["total"] as? NSNumber)?.int64Value ?? -1, ($0["calls"] as? NSNumber)?.intValue ?? -1) }
}

// MARK: edge cases, each in a home of its own

private func g2EdgeChecks(tempDir: () throws -> String) throws {
    func fresh() throws -> (home: String, store: UsageStore) {
        let dir = try tempDir()
        return (dir + "/home", try UsageStore(path: dir + "/u.sqlite"))
    }
    let now = Date(timeIntervalSince1970: 1793970000)
    func totals(_ store: UsageStore) -> [HarnessID: Int64] {
        guard let report = try? store.usageBook(now: now).report(for: .all) else { return [:] }
        return Dictionary(uniqueKeysWithValues: report.harnesses.map { ($0.harness, $0.tokens) })
    }
    func calls(_ store: UsageStore, _ id: HarnessID) -> Int {
        (try? store.usageBook(now: now).report(for: .all).harnesses.first { $0.harness == id }?.calls) ?? -1
    }

    // The Roo rule at its edge: the cut is 2025-11-02T00:00:00Z to the millisecond.
    do {
        let (h, s) = try fresh()
        let task = h + appSupport + "/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks/edge"
        func payload(_ ts: Int) -> [String: Any] {
            taskRow(ts, ["tokensIn": 700, "tokensOut": 0, "cacheReads": 600, "cacheWrites": 100])
        }
        // One millisecond before: net, 700+600+100; at the cut: whole, 0+600+100. A cache larger than tokensIn clamps to 0.
        try writeJSON(task + "/ui_messages.json", [payload(cutoffMs - 1), payload(cutoffMs),
                                                   taskRow(cutoffMs + 1000, ["tokensIn": 5, "tokensOut": 1, "cacheReads": 600, "cacheWrites": 100])] as [Any])
        _ = UsageScanner(store: s, home: h, environment: [:]).scan()
        check("Roo cache rule flips at the release cut", totals(s)[.rooCode] == 1400 + 700 + 701)
    }

    // Damaged and hostile files: named, never a crash, the healthy ones still count, a repaired file counts on the next pass.
    do {
        let (h, s) = try fresh()
        let tasks = h + appSupport + "/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/"
        try write(tasks + "broken/ui_messages.json", "[{\"ts\": 1, \"type\": \"say\"")
        try write(tasks + "empty/ui_messages.json", "")
        try write(tasks + "wrongshape/ui_messages.json", "{\"not\":\"an array\"}")
        try writeJSON(tasks + "huge/ui_messages.json", [taskRow(afterCutoff, ["tokensIn": 9_223_372_036_854_775_807, "tokensOut": 9_223_372_036_854_775_807, "cacheReads": -5])] as [Any])
        try writeJSON(tasks + "odd/ui_messages.json", [
            [1, 2, 3], "str", NSNull(), ["type": "say", "say": "api_req_started", "text": 42],
            ["type": "say", "say": "api_req_started", "text": "[1,2]", "ts": "x"],
            taskRow(afterCutoff, ["tokensIn": "12", "tokensOut": 1.9, "cacheReads": NSNull()]),
            taskRow(afterCutoff, ["tokensIn": 1, "tokensOut": 1]), taskRow(afterCutoff, ["tokensIn": 1, "tokensOut": 1]),
        ] as [Any])
        let scanner = UsageScanner(store: s, home: h, environment: [:])
        let result = scanner.scan()
        let issues = result.issues.filter { $0.source == "Cline" }
        let big = totals(s)[.cline] ?? 0
        check("damaged task files are named, healthy ones count", issues.count == 2
              && issues.contains { $0.message.contains("broken") } && issues.contains { $0.message.contains("wrongshape") } && big > 0)
        check("absurd counts saturate instead of trapping", big >= Int64.max / 4 * 2)
        // odd: tokensIn "12" is no number (0) and tokensOut 1.9 is 1, so one call of 1; the two equal rows share a ts and stay two calls.
        check("rows with one timestamp stay separate calls", calls(s, .cline) == 4)
        try write(tasks + "broken/ui_messages.json", json([taskRow(afterCutoff, ["tokensIn": 3, "tokensOut": 4])] as [Any]))
        let again = scanner.scan()
        check("a repaired file counts on the next pass", again.issues.filter { $0.source == "Cline" }.count == 1 && again.events == 1)
    }

    // A growing log: a new call is added once, the rest stay.
    do {
        let (h, s) = try fresh()
        let path = h + appSupport + "/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/grow/ui_messages.json"
        try writeJSON(path, [taskRow(afterCutoff, ["tokensIn": 10, "tokensOut": 1])] as [Any])
        let scanner = UsageScanner(store: s, home: h, environment: [:])
        _ = scanner.scan()
        try writeJSON(path, [taskRow(afterCutoff, ["tokensIn": 10, "tokensOut": 1]), taskRow(afterCutoff + 1000, ["tokensIn": 20, "tokensOut": 2])] as [Any])
        let grown = scanner.scan()
        check("a rewritten task file adds only its new call", grown.events == 2 && totals(s)[.cline] == 33)
    }

    // Copilot: nonsense patches do no harm and a huge index allocates nothing.
    do {
        let (h, s) = try fresh()
        let path = h + appSupport + "/Code/User/workspaceStorage/w/chatSessions/s.jsonl"
        let lines = ["{\"kind\":0,\"v\":{\"requests\":[1,null,\"x\",{\"timestamp\":5000000000000,\"modelId\":\"copilot/a\",\"promptTokens\":4,\"completionTokens\":6}]}}",
                     "{\"kind\":1,\"k\":[\"requests\",3,\"result\",\"metadata\"],\"v\":{\"resolvedModel\":\"r\"}}",
                     "{\"kind\":1,\"k\":[\"requests\",3000000000000000000,\"x\"],\"v\":1}", "{\"kind\":1,\"k\":[],\"v\":1}", "{\"kind\":1}", "{\"kind\":7}",
                     "{\"kind\":1,\"k\":[\"requests\",3,\"promptTokens\"],\"v\":\"text\"}", "[1,2]", "", "not json"]
        try write(path, lines.joined(separator: "\n") + "\n")
        let result = UsageScanner(store: s, home: h, environment: [:]).scan()
        // The string `promptTokens` is no number: it falls to the zero of J.int, the call keeps its 6 output tokens.
        check("Copilot nonsense patches are skipped", result.issues.isEmpty && totals(s)[.copilotChat] == 6)
    }

    // Moved folders: XDG_DATA_HOME moves Kilo, CONTINUE_GLOBAL_DIR moves Continue.
    do {
        let (h, s) = try fresh()
        let db = h + "/xdg/kilo/kilo.db"
        try runSQL(db, "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT);")
        try runSQL(db, "INSERT INTO message VALUES('x','s','{\"role\":\"assistant\",\"providerID\":\"kilo\",\"modelID\":\"m\",\"tokens\":{\"input\":9,\"output\":1,\"cache\":{\"read\":0,\"write\":0}}}',1);")
        try write(h + "/moved-continue/dev_data/0.2.0/tokensGenerated.jsonl", json(["model": "m", "promptTokens": 2, "generatedTokens": 1] as [String: Any]) + "\n")
        let env = ["XDG_DATA_HOME": h + "/xdg", "CONTINUE_GLOBAL_DIR": h + "/moved-continue"]
        let result = UsageScanner(store: s, home: h, environment: env).scan()
        let sum = totals(s)
        check("XDG_DATA_HOME moves Kilo and CONTINUE_GLOBAL_DIR moves Continue", result.issues.isEmpty && sum[.kiloCode] == 10 && sum[.continueDev] == 3
              && s.hasEvents(prefix: "kilo:x") && s.hasEvents(prefix: "continue:"))
    }

    // A tool folder alone is found and not counted; a Cline inside Cursor counts as Cline while Cursor itself does not.
    do {
        let (h, s) = try fresh()
        try FileManager.default.createDirectory(atPath: h + appSupport + "/Cursor", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: h + "/.cursor", withIntermediateDirectories: true)
        let result = UsageScanner(store: s, home: h, environment: [:]).scan()
        check("Cursor alone is found and not counted", result.notCountable == [.cursor] && result.detected == [.cursor] && result.events == 0)
        try writeJSON(h + appSupport + "/Cursor/User/globalStorage/saoudrizwan.claude-dev/tasks/c/ui_messages.json", [taskRow(afterCutoff, ["tokensIn": 4, "tokensOut": 1])] as [Any])
        let both = UsageScanner(store: s, home: h, environment: [:]).scan()
        check("a Cline inside Cursor counts as Cline", both.detected == [.cline, .cursor] && totals(s) == [.cline: 5])
    }

    // A task that moved from Cursor to Code (the same id): once Code's copy has the rows, Code retires them, so a
    // checkpoint restore there does not leave the older rows behind under the first file's name.
    do {
        let (h, s) = try fresh()
        let cursor = h + appSupport + "/Cursor/User/globalStorage/saoudrizwan.claude-dev/tasks/t1"
        let code = h + appSupport + "/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/t1"
        let calls: [Any] = [taskRow(afterCutoff, ["tokensIn": 100, "tokensOut": 0]), taskRow(afterCutoff + 60_000, ["tokensIn": 250, "tokensOut": 0])]
        try writeJSON(cursor + "/ui_messages.json", calls)
        _ = UsageScanner(store: s, home: h, environment: [:]).scan()
        check("a Cline task in Cursor counts", totals(s)[.cline] == 350)
        try FileManager.default.removeItem(atPath: cursor)
        try writeJSON(code + "/ui_messages.json", calls)
        _ = UsageScanner(store: s, home: h, environment: [:]).scan()
        check("the same task moved to Code is not counted twice", totals(s)[.cline] == 350)
        try writeJSON(code + "/ui_messages.json", [calls[0], taskRow(afterCutoff + 120_000, ["tokensIn": 250, "tokensOut": 0], say: "deleted_api_reqs")] as [Any])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: code + "/ui_messages.json")
        _ = UsageScanner(store: s, home: h, environment: [:]).scan()
        check("a checkpoint restore in the moved task replaces the rows the first file wrote", totals(s)[.cline] == 350)
    }

    // The same task id in two editors at once (copies the editors do not share): every case counts each call once,
    // whichever copy is read again, and a copy that alone holds a call keeps it.
    do {
        let editors: [String] = ["Code", "Cursor"]
        func taskFile(_ h: String, _ editor: String) -> String {
            h + appSupport + "/" + editor + "/User/globalStorage/saoudrizwan.claude-dev/tasks/t1/ui_messages.json"
        }
        func call(_ offset: Int, _ tokens: Int, say: String = "api_req_started") -> [String: Any] {
            taskRow(afterCutoff + offset, ["tokensIn": tokens, "tokensOut": 0], say: say)
        }
        var clock: TimeInterval = 100
        func touch(_ path: String) throws {
            clock += 100
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(clock)], ofItemAtPath: path)
        }
        func scanned(_ s: UsageStore, _ h: String) -> Int64 {
            _ = UsageScanner(store: s, home: h, environment: [:]).scan()
            return totals(s)[.cline] ?? -1
        }
        let both: [Any] = [call(0, 120), call(60_000, 250)]
        let restored: [Any] = [call(0, 120), call(120_000, 250, say: "deleted_api_reqs")]
        for restoredEditor in editors {
            let (h, s) = try fresh()
            for e in editors { try writeJSON(taskFile(h, e), both) }
            check("identical copies in two editors count once (\(restoredEditor) restored)", scanned(s, h) == 370)
            try writeJSON(taskFile(h, restoredEditor), restored)
            try touch(taskFile(h, restoredEditor))
            check("a restore in \(restoredEditor) of two identical copies does not double count", scanned(s, h) == 370)
        }
        do {
            let (h, s) = try fresh()
            try writeJSON(taskFile(h, "Code"), both)
            try writeJSON(taskFile(h, "Cursor"), both + [call(180_000, 500)])
            check("a copy with an extra call counts it", scanned(s, h) == 870)
            try touch(taskFile(h, "Code"))
            check("the copy without it, read again, does not cut it", scanned(s, h) == 870)
            try touch(taskFile(h, "Cursor"))
            check("the copy with it, read again, does not double count", scanned(s, h) == 870)
        }
        for extra in [true, false] {
            // one copy read again in the normal way (with a new call, or only touched) must not take the other copy's claim on
            // the calls they share: a restore there later still retires the old call
            let (h, s) = try fresh()
            for e in editors { try writeJSON(taskFile(h, e), both) }
            _ = scanned(s, h)
            try writeJSON(taskFile(h, "Code"), extra ? both + [call(180_000, 100)] : both)
            try touch(taskFile(h, "Code"))
            let reread: Int64 = extra ? 470 : 370
            check("a copy read again (extra call: \(extra)) keeps its total", scanned(s, h) == reread)
            try writeJSON(taskFile(h, "Cursor"), restored)
            try touch(taskFile(h, "Cursor"))
            check("a restore in the other copy afterwards retires the old call (extra call: \(extra))", scanned(s, h) == reread)
        }
        do {
            let (h, s) = try fresh()
            for e in editors { try writeJSON(taskFile(h, e), both) }
            _ = scanned(s, h)
            // an index made before owners were kept: the rows have no owner, then a restore must still retire them
            try runSQL(s.path, "UPDATE events SET file = ''; DELETE FROM event_files;")
            try writeJSON(taskFile(h, "Code"), restored)
            try touch(taskFile(h, "Code"))
            check("rows without an owner are retired by a restore", scanned(s, h) == 370)
        }
        do {
            let (h, s) = try fresh()
            for e in editors { try writeJSON(taskFile(h, e), both) }
            _ = scanned(s, h)
            try writeJSON(taskFile(h, "Code"), [call(0, 120)])
            try touch(taskFile(h, "Code"))
            check("a message rolled back in one of two copies is not counted twice", scanned(s, h) == 120)
            try writeJSON(taskFile(h, "Cursor"), [call(0, 120)])
            try touch(taskFile(h, "Cursor"))
            _ = scanned(s, h)
            check("no ownership row outlives its event",
                  (try? queryInt(s.path, "SELECT COUNT(*) FROM event_files WHERE key NOT IN (SELECT key FROM events)")) == 0)
        }
    }

    // Zed: an unreadable database is one named issue; a thread that changes is read again.
    do {
        let (h, s) = try fresh()
        try write(h + appSupport + "/Zed/threads/threads.db", "not sqlite")
        let result = UsageScanner(store: s, home: h, environment: [:]).scan()
        check("a Zed file that is not a database is a named issue", result.issues.contains { $0.source == "Zed" } && result.events == 0)
    }
    do {
        let (h, s) = try fresh()
        let db = h + appSupport + "/Zed/threads/threads.db"
        try runSQL(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL, data BLOB NOT NULL);")
        func body(_ requests: [String: Any]) -> String {
            json(["model": ["provider": "zed.dev", "model": "m"], "request_token_usage": requests] as [String: Any])
        }
        try runSQL(db, "INSERT INTO threads VALUES('a','t','2026-11-06T10:00:00Z','json', CAST('\(body(["r1": ["input_tokens": 5]]))' AS BLOB));")
        try runSQL(db, "INSERT INTO threads VALUES('b','t','2026-11-06T10:00:00Z','json', CAST('{broken' AS BLOB));")
        let scanner = UsageScanner(store: s, home: h, environment: [:])
        _ = scanner.scan()
        try runSQL(db, "UPDATE threads SET updated_at='2026-11-06T11:00:00Z', data=CAST('\(body(["r1": ["input_tokens": 5], "r2": ["input_tokens": 7]]))' AS BLOB) WHERE id='a';")
        _ = scanner.scan()
        check("a Zed thread that grew is read again, once", totals(s)[.zed] == 12)
        check("a thread with unreadable JSON adds nothing and is no crash", (try? s.eventCount()) == 2)
    }

    // Zed without zstd: the compressed thread is one named, open issue; what was read before it stays.
    do {
        let dir = try tempDir()
        let (status, out) = probe("g2-zed-zstd-missing", dir: dir, env: ["TOKENBAR_ZSTD": "none"])
        check("zstd missing is one named Zed issue", status == 0 && out.contains("plain=0 issues=1") && out.contains("brew install zstd") && out.contains("events=1"))
        check("a Zed database that waits for zstd is not marked read", out.contains("recorded=false"))
    }
}
