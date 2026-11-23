import Foundation
import SQLite3
import LocalCore

// Checks for the data and reader findings of the independent review of the 9.0.1 candidate (third batch).
// Called once from `main.swift`; every case builds a small home and scans it in this process.
//
//   2  a WAL database whose -wal cannot be copied is an issue, not a read of the .db alone
//   3  Antigravity: a -wal that grows after the pair was read in this pass is read again next pass
//   4  a row stored with ts 0 (9.0.0 could not read ISO dates) gets its date when it is read again
//   5  Codex: a 9.0.0 state without `unknownRows` restarts when the model turns up

private let fixNow = Date(timeIntervalSince1970: 1793970000)

private struct DataScan {
    var calls: Int
    var tokens: Int64
    var issues: [String]
    /// Calls inside the last 24 hours before `fixNow`.
    var dayCalls: Int
    /// Calls per provider/model.
    var models: [String: Int]
}

private func dataScan(_ dir: String, _ home: String, afterPairRead: ((String) -> Void)? = nil) throws -> DataScan {
    let store = try UsageStore(path: dir + "/usage.sqlite")
    let scanner = UsageScanner(store: store, home: home, environment: [:])
    scanner.afterPairRead = afterPairRead
    let result = scanner.scan()
    let report = try store.usageBook(now: fixNow).report(for: .all)
    var calls = 0
    var tokens: Int64 = 0
    var models: [String: Int] = [:]
    for stat in report.harnesses.flatMap(\.models) {
        calls += stat.calls
        tokens += stat.tokens
        models[stat.info.provider + "/" + stat.info.model, default: 0] += stat.calls
    }
    let day = try store.usageBook(now: fixNow).report(for: .day)
    let dayCalls = day.harnesses.reduce(0) { (sum: Int, harness: HarnessStat) -> Int in sum + harness.calls }
    return DataScan(calls: calls, tokens: tokens, issues: result.issues.map { (issue: SourceIssue) -> String in issue.message }, dayCalls: dayCalls, models: models)
}

private func dataHex(_ bytes: [UInt8]) -> String { bytes.map { (byte: UInt8) -> String in String(format: "%02x", byte) }.joined() }

private func agDataStep(_ idx: Int) -> String {
    let usage = protoInt(1, 1) + protoInt(2, 7) + protoInt(3, 4) + protoInt(4, 2) + protoInt(5, 1) + protoInt(9, 1)
    let meta = protoBytes(8, protoInt(1, 1793968800 + idx)) + protoBytes(9, usage)
    return "INSERT INTO steps VALUES(\(idx),15,X'\(dataHex(meta))');"
}

private func dataAge(_ path: String, seconds: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: path)
}

/// A live Antigravity database in WAL mode (never checkpointed past step 0) and the connection that keeps it open.
private final class LiveAntigravity {
    let conn: OpaquePointer
    let live: String
    init(dir: String, name: String = "live") throws {
        live = dir + "/" + name + ".db"
        var raw: OpaquePointer?
        guard sqlite3_open(live, &raw) == SQLITE_OK, let opened = raw else { throw NSError(domain: "sqlite", code: 1) }
        conn = opened
        let gen = protoBytes(1, protoInt(3, 1) + protoBytes(19, Array("gemini-3.8-flash".utf8)))
        try exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE gen_metadata(idx INTEGER, data BLOB); "
                 + "CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB); INSERT INTO gen_metadata VALUES(0,X'\(dataHex(gen))'); "
                 + agDataStep(0) + " PRAGMA wal_checkpoint(TRUNCATE); " + agDataStep(1))
    }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(conn, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: String(cString: sqlite3_errmsg(conn)), code: 2) }
    }
    /// Puts the files as the tool has them now into `db` (the .db, then the -wal).
    func copy(to db: String) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal"] {
            try? fm.removeItem(atPath: db + suffix)
            try fm.copyItem(atPath: live + suffix, toPath: db + suffix)
        }
    }
    deinit { sqlite3_close(conn) }
}

func fix901bDataChecks(tempDir: () throws -> String) throws {
    PriceBook.install(catalogs: .embedded)

    // MARK: 2  a pair that cannot be copied is named, and the file is read again once it can

    do {
        // The -wal is not readable: copying it fails with something other than "no such file".
        let dir = try tempDir(), h = dir + "/home"
        let db = h + "/.gemini/antigravity-cli/conversations/ag-denied.db"
        try FileManager.default.createDirectory(atPath: (db as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let tool = try LiveAntigravity(dir: dir)
        try tool.copy(to: db)
        try dataAge(db, seconds: 60)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: db + "-wal")
        let first = try dataScan(dir, h)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: db + "-wal")
        let second = try dataScan(dir, h)
        check("wal copy: an unreadable -wal counts nothing (not the .db alone: 0 calls)", first.calls == 0)
        check("wal copy: the failed copy is a named issue", first.issues.contains { (message: String) -> Bool in message.contains("kopyalanamadı") })
        check("wal copy: once the -wal can be copied the file is read whole (2 calls)", second.calls == 2)
    } catch { check("wal copy denied: \(error)", false) }

    // MARK: 3  a -wal that grows after the pair was read, before its own turn in the same pass

    do {
        // Several conversations: the order a folder is listed in is the file system's, and the loss needs the .db to
        // come before its -wal. Each conversation has its tool write one more step the moment its pair has been read.
        let dir = try tempDir(), h = dir + "/home"
        let folder = h + "/.gemini/antigravity-cli/conversations"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var tools: [String: LiveAntigravity] = [:]
        let names = (0..<8).map { (i: Int) -> String in "ag-race-\(i)" }
        for name in names {
            let tool = try LiveAntigravity(dir: dir, name: name)
            try tool.copy(to: folder + "/" + name + ".db")
            try dataAge(folder + "/" + name + ".db", seconds: 60)
            tools[folder + "/" + name + ".db"] = tool
        }
        var written: Set<String> = []
        let first = try dataScan(dir, h, afterPairRead: { (path: String) -> Void in
            guard !written.contains(path), let tool = tools[path] else { return }
            written.insert(path)
            // The tool writes one more step into its -wal at this very moment (the .db stays as it is).
            do {
                try tool.exec(agDataStep(2))
                try FileManager.default.removeItem(atPath: path + "-wal")
                try FileManager.default.copyItem(atPath: tool.live + "-wal", toPath: path + "-wal")
            } catch { check("antigravity race: the write itself: \(error)", false) }
        })
        let second = try dataScan(dir, h)
        let third = try dataScan(dir, h)
        check("antigravity race: every pair was read in the first pass (8 x 2 calls)", first.calls == 16)
        check("antigravity race: the calls written after the read are counted on the next pass (8 x 3 calls)", second.calls == 24)
        check("antigravity race: nothing is counted twice once the pairs are quiet (8 x 3 calls)", third.calls == 24)
    } catch { check("antigravity race: \(error)", false) }

    // MARK: 4  rows 9.0.0 wrote with the date 1970 get their date when 9.0.1 reads the files again

    do {
        let dir = try tempDir(), h = dir + "/home"
        let project = h + "/work/proj"
        try write(h + "/.local/share/crush/projects.json",
                  #"{"projects":[{"path":"\#(project)","data_dir":"\#(project)/.crush","last_accessed":"2026-11-06T10:00:00Z"}]}"#)
        try runSQL(project + "/.crush/crush.db", """
            CREATE TABLE sessions(id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0,
                prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0, cost REAL NOT NULL DEFAULT 0.0,
                updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL);
            CREATE TABLE messages(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, parts TEXT NOT NULL DEFAULT '[]',
                model TEXT, provider TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, finished_at INTEGER);
            INSERT INTO sessions VALUES('c1',NULL,'one',3,1500,300,0.5,'2026-11-06T12:40:00Z','2026-11-06T12:00:00Z');
            INSERT INTO messages VALUES('m1','c1','assistant','[]','gpt-6-luna','openai','2026-11-06T12:30:00Z','2026-11-06T12:30:00Z',NULL);
            """)
        try write(h + "/.claude/projects/p/a.jsonl",
                  #"{"type":"assistant","timestamp":"2026-11-06T12:10:00.000Z","sessionId":"s1","requestId":"r-1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":70,"output_tokens":3}}}"# + "\n")
        try dataAge(h + "/.claude/projects/p/a.jsonl", seconds: 600)
        let good = try dataScan(dir, h)
        // The index as 9.0.0 left it: every row dated 1970, no repair done yet; the files themselves unchanged.
        try runSQL(dir + "/usage.sqlite", "UPDATE events SET ts = 0; DELETE FROM meta WHERE k LIKE 'repair:%';")
        let broken = try UsageStore(path: dir + "/usage.sqlite")
        let brokenDay = try broken.usageBook(now: fixNow).report(for: .day).harnesses.reduce(0) { (sum: Int, harness: HarnessStat) -> Int in sum + harness.calls }
        let healed = try dataScan(dir, h)
        let again = try dataScan(dir, h)
        check("dates: the index made to look like 9.0.0's has no call in the last 24 hours", good.dayCalls == 2 && brokenDay == 0)
        check("dates: the next scan dates the rows again (2 calls in the last 24 hours)", healed.dayCalls == 2)
        check("dates: nothing is counted twice by that read (same calls and tokens)", healed.calls == good.calls && healed.tokens == good.tokens)
        check("dates: the repair happens once (a third scan reads nothing again)", again.dayCalls == 2 && again.calls == good.calls && again.tokens == good.tokens)
    } catch { check("zero dates: \(error)", false) }

    // MARK: 5  Codex: a read state 9.0.0 saved (no `unknownRows`) when the model turns up

    do {
        let dir = try tempDir(), h = dir + "/home"
        let path = h + "/.codex/sessions/2026/rollout-v900.jsonl"
        func cx(_ total: Int, _ time: String) -> String {
            #"{"type":"event_msg","timestamp":"\#(time)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total),"input_tokens":\#(total - 10),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10},"last_token_usage":{"input_tokens":\#(total - 10),"output_tokens":10}}}}"#
        }
        let head = #"{"type":"session_meta","payload":{"id":"cx-v900","model_provider":"openai","timestamp":"2026-11-06T09:00:00Z"}}"#
        try write(path, [head, cx(100, "2026-11-06T10:00:00Z")].joined(separator: "\n") + "\n")
        let first = try dataScan(dir, h)
        // The state as 9.0.0 saved it: the same fields, without the count of rows written as `unknown`.
        try runSQL(dir + "/usage.sqlite", "UPDATE meta SET v = json_remove(v, '$.unknownRows') WHERE k LIKE 'cx-state:%';")
        let store = try UsageStore(path: dir + "/usage.sqlite")
        let saved = store.meta("cx-state:" + path) ?? ""
        try append(path, [#"{"type":"turn_context","payload":{"model":"gpt-6-luna","cwd":"/x"}}"#, cx(300, "2026-11-06T10:01:00Z")].joined(separator: "\n") + "\n")
        let again = try dataScan(dir, h)
        let third = try dataScan(dir, h)
        check("codex 9.0.0 state: the state of the first read has no unknownRows (as 9.0.0 saved it)", first.models["openai/unknown"] == 1 && !saved.contains("unknownRows") && saved.contains("\"last\""))
        check("codex 9.0.0 state: the model named later reaches the call written before it (2 calls on it, no unknown row)",
              again.models["openai/gpt-6-luna"] == 2 && again.models["openai/unknown"] == nil)
        check("codex 9.0.0 state: nothing counted twice (2 calls, 300 tokens), and a further pass changes nothing",
              again.calls == 2 && again.tokens == 300 && third.calls == 2 && third.tokens == 300)
    } catch { check("codex 9.0.0 state: \(error)", false) }
}
