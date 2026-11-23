import Foundation
import SQLite3
import LocalCore

// Checks for the findings of the 9.0.1 review of 9.0.0 (counting and price correctness). Each block names its finding.
// Called once from `main.swift`; every case builds a small home and scans it in this process.
//
//   1  LineReader: a half-written last line is not consumed, whatever the file's age
//   2  oh-my-pi / Pi lines: spacing, the model of the message, the role of the message
//   3  Codex: a model named after the first token_count reaches the rows already written
//   4  the price cache keeps the rows a lookup can return by exact id
//   5  the hand-corrected table gives way to a live OpenRouter row
//   6  a cache price of 0 is a price; alias chains resolve
//   7  a tier without a cache price keeps the base row's
//   8  the price refresh repeats once a day while the app runs
//   9  a very long model name costs time in proportion to its length
//   10 a huge line in a .zst file is a named issue, not gigabytes of memory
//   11 Antigravity: the rows only a -wal holds
//   12 Crush and Devin: ISO-8601 text dates
//   13 tokenbar-cli takes --offline and --prices-now

private let fixNow = Date(timeIntervalSince1970: 1793970000)

/// What a home holds after one scan: per model (provider/model) calls and total tokens, and the issues the scan named.
private struct FixScan {
    var models: [String: (calls: Int, tokens: Int64)]
    var issues: [String]
    /// Calls inside the last 24 hours before `fixNow`.
    var dayCalls = 0
    var calls: Int { models.values.reduce(0) { (sum: Int, model: (calls: Int, tokens: Int64)) -> Int in sum + model.calls } }
    var tokens: Int64 { models.values.reduce(0) { (sum: Int64, model: (calls: Int, tokens: Int64)) -> Int64 in sum + model.tokens } }
}

private func scanHome(_ dir: String, _ home: String) throws -> FixScan {
    let store = try UsageStore(path: dir + "/usage.sqlite")
    let result = UsageScanner(store: store, home: home, environment: [:]).scan()
    let report = try store.usageBook(now: fixNow).report(for: .all)
    var models: [String: (calls: Int, tokens: Int64)] = [:]
    for stat in report.harnesses.flatMap(\.models) {
        let key = stat.info.provider + "/" + stat.info.model
        let old = models[key] ?? (0, 0)
        models[key] = (old.calls + stat.calls, old.tokens + stat.tokens)
    }
    let day = try store.usageBook(now: fixNow).report(for: .day)
    return FixScan(models: models, issues: result.issues.map { (issue: SourceIssue) -> String in issue.message }, dayCalls: day.harnesses.reduce(0) { (sum: Int, harness: HarnessStat) -> Int in sum + harness.calls })
}

private func hex(_ bytes: [UInt8]) -> String { bytes.map { (byte: UInt8) -> String in String(format: "%02x", byte) }.joined() }

/// An Antigravity step as the reader decodes it: model enum 1, input 7, output 4, cache write 2, cache read 1, thinking 1.
private func agStep(_ idx: Int) -> String {
    let usage = protoInt(1, 1) + protoInt(2, 7) + protoInt(3, 4) + protoInt(4, 2) + protoInt(5, 1) + protoInt(9, 1)
    let meta = protoBytes(8, protoInt(1, 1793968800 + idx)) + protoBytes(9, usage)
    return "INSERT INTO steps VALUES(\(idx),15,X'\(hex(meta))');"
}

private func age(_ path: String, seconds: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: path)
}

func fix901Checks(tempDir: () throws -> String) throws {
    PriceBook.install(catalogs: .embedded)

    // MARK: 1  a half-written last line is picked up whole on the next pass

    do {
        let dir = try tempDir(), h = dir + "/home"
        let path = h + "/.claude/projects/p/a.jsonl"
        func row(_ id: String, _ input: Int) -> String {
            #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"s1","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
        }
        let second = row("m2", 50)
        let cut = second.index(second.startIndex, offsetBy: 90)
        try write(path, row("m1", 100) + "\n" + String(second[..<cut]))
        try age(path, seconds: 120)                       // quiet for longer than the settle time: the line looks final
        let first = try scanHome(dir, h)
        try append(path, String(second[cut...]) + "\n")
        let again = try scanHome(dir, h)
        check("linereader: a quiet half line is not consumed (first pass sees one call)", first.calls == 1)
        check("linereader: the half line completed later is counted (2 calls, 150 tokens)", again.calls == 2 && again.tokens == 150)
    } catch { check("linereader half line: \(error)", false) }

    // MARK: 2  oh-my-pi / Pi

    do {
        let dir = try tempDir(), h = dir + "/home"
        let omp = h + "/.omp/agent/sessions/p/2026-11-06_s-spaced.jsonl"
        // A: JSON with spaces after the colons. B: an argument named "model" before the message's own. C: a nested
        // {"role":"toolResult"} inside an assistant message. D: the plain line. The last line is a real tool result.
        let a = #"{"timestamp": "2026-11-06T10:00:00Z", "message": {"role": "assistant", "provider": "anthropic", "model": "claude-sonnet-4-5", "usage": { "input": 300, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "responseId": "a-1"}}"#
        let b = #"{"timestamp":"2026-11-06T10:00:01Z","message":{"role":"assistant","content":[{"type":"toolCall","arguments":{"model":"gpt-4o"}}],"provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":400,"output":0},"responseId":"b-1"}}"#
        let c = #"{"timestamp":"2026-11-06T10:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","arguments":{"role":"toolResult"}}],"provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":850,"output":0},"responseId":"c-1"}}"#
        let d = #"{"timestamp":"2026-11-06T10:00:03Z","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":950,"output":0},"responseId":"d-1"}}"#
        let tool = #"{"timestamp":"2026-11-06T10:00:04Z","message": {"role": "toolResult", "usage": {"input": 7000, "output": 0}, "responseId": "t-1"}}"#
        try write(omp, [#"{"type":"session","id":"s-spaced","cwd":"/x"}"#, a, b, c, d, tool].joined(separator: "\n") + "\n")
        let r = try scanHome(dir, h)
        let sonnet = r.models["anthropic/claude-sonnet-4-5"]
        check("omp: spaced JSON, a content field named model and nested toolResult text count under the message's model (4 calls, 2500)",
              sonnet?.calls == 4 && sonnet?.tokens == 2500 && r.models.count == 1)
    } catch { check("omp lines: \(error)", false) }

    // MARK: 3  Codex: the model arrives after the first token_count

    do {
        let dir = try tempDir(), h = dir + "/home"
        let path = h + "/.codex/sessions/2026/rollout-late.jsonl"
        func cx(_ total: Int, _ time: String) -> String {
            #"{"type":"event_msg","timestamp":"\#(time)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total),"input_tokens":\#(total - 10),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10},"last_token_usage":{"input_tokens":\#(total - 10),"output_tokens":10}}}}"#
        }
        let head = #"{"type":"session_meta","payload":{"id":"cx-late","model_provider":"openai","timestamp":"2026-11-06T09:00:00Z"}}"#
        try write(path, [head, cx(100, "2026-11-06T10:00:00Z")].joined(separator: "\n") + "\n")
        let first = try scanHome(dir, h)
        try append(path, [#"{"type":"turn_context","payload":{"model":"gpt-6-luna","cwd":"/x"}}"#, cx(300, "2026-11-06T10:01:00Z")].joined(separator: "\n") + "\n")
        let again = try scanHome(dir, h)
        check("codex: before any model the first call is openai/unknown", first.models["openai/unknown"]?.calls == 1)
        check("codex: the model named later is given to the call written before it (no unknown row left)",
              again.models["openai/gpt-6-luna"]?.calls == 2 && again.models["openai/unknown"] == nil && again.tokens == 300)
        // A file read whole that names its model after the first call corrects itself: one walk, not two.
        let dir2 = try tempDir(), h2 = dir2 + "/home"
        let whole = h2 + "/.codex/sessions/2026/rollout-whole.jsonl"
        try write(whole, [head, cx(100, "2026-11-06T10:00:00Z"), #"{"type":"turn_context","payload":{"model":"gpt-6-luna","cwd":"/x"}}"#].joined(separator: "\n") + "\n")
        let store2 = try UsageStore(path: dir2 + "/usage.sqlite")
        let scanner2 = UsageScanner(store: store2, home: h2, environment: [:])
        _ = scanner2.scan()
        check("codex: a rollout that names its model late, read whole, is walked once", scanner2.linePasses[whole] == 1)
    } catch { check("codex late model: \(error)", false) }

    // A later read of the same call with more tokens but no model name keeps the model it already had.
    do {
        let dir = try tempDir()
        let store = try UsageStore(path: dir + "/usage.sqlite")
        let at: Double = fixNow.timeIntervalSince1970 - 3600
        func ev(_ model: String, _ input: Int64) -> UsageEvent {
            UsageEvent(key: "cc:msg-1:req-1", provider: "anthropic", model: model, timestamp: at,
                       tokens: TokenCounts(input: input), session: "s", file: dir + "/f.jsonl")
        }
        try store.insertEvents([ev("claude-opus-5-5", 100)])
        try store.insertEvents([ev("unknown", 150)])
        let stats = try store.usageBook(now: fixNow).report(for: .all).harnesses.flatMap(\.models)
        let names: [String] = stats.map { (stat: ModelStat) -> String in stat.info.model }
        let tokens: Int64 = stats.reduce(0) { (sum: Int64, stat: ModelStat) -> Int64 in sum + stat.tokens }
        check("store: a fuller row without a model name keeps the known model and takes the larger counts",
              names == ["claude-opus-5-5"] && tokens == 150)
    } catch { check("store known model: \(error)", false) }

    // MARK: 11  Antigravity: the rows only the -wal holds, and a -wal that grows under an unchanged .db

    do {
        let dir = try tempDir(), h = dir + "/home"
        let db = h + "/.gemini/antigravity-cli/conversations/ag-wal.db"
        try FileManager.default.createDirectory(atPath: (db as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let live = dir + "/live.db"
        var raw: OpaquePointer?
        guard sqlite3_open(live, &raw) == SQLITE_OK, let conn = raw else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(conn) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(conn, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: String(cString: sqlite3_errmsg(conn)), code: 2) }
        }
        let gen = protoBytes(1, protoInt(3, 1) + protoBytes(19, Array("gemini-3.8-flash".utf8)))
        try exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE gen_metadata(idx INTEGER, data BLOB); "
                 + "CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB); INSERT INTO gen_metadata VALUES(0,X'\(hex(gen))'); " + agStep(0)
                 + " PRAGMA wal_checkpoint(TRUNCATE); " + agStep(1))
        try FileManager.default.copyItem(atPath: live, toPath: db)
        try FileManager.default.copyItem(atPath: live + "-wal", toPath: db + "-wal")
        try age(db, seconds: 60)
        let first = try scanHome(dir, h)
        // The tool writes once more: only the -wal changes, the .db is as it was.
        try exec(agStep(2))
        try FileManager.default.removeItem(atPath: db + "-wal")
        try FileManager.default.copyItem(atPath: live + "-wal", toPath: db + "-wal")
        let second = try scanHome(dir, h)
        check("antigravity: a call that only the -wal holds is counted (2 calls)", first.calls == 2)
        check("antigravity: a -wal that grew under an unchanged .db is read again (3 calls)", second.calls == 3)
        check("antigravity: the tool's folder is as the tool left it (no -shm made)",
              !FileManager.default.fileExists(atPath: db + "-shm"))
    } catch { check("antigravity wal: \(error)", false) }

    // The same tool, closed cleanly: a WAL-mode database whose last connection checkpointed it, no -wal, no -shm.
    do {
        let dir = try tempDir(), h = dir + "/home"
        let db = h + "/.gemini/antigravity-cli/conversations/ag-closed.db"
        let gen = protoBytes(1, protoInt(3, 1) + protoBytes(19, Array("gemini-3.8-flash".utf8)))
        try runSQL(db, "PRAGMA journal_mode=WAL; CREATE TABLE gen_metadata(idx INTEGER, data BLOB); CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB); "
                   + "INSERT INTO gen_metadata VALUES(0,X'\(hex(gen))'); " + agStep(0) + agStep(1) + " PRAGMA wal_checkpoint(TRUNCATE);")
        // (what a tool that exited cleanly leaves: the files of the closed connection are gone)
        for leftover in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db + leftover) }
        let walLeft = FileManager.default.fileExists(atPath: db + "-wal")
        let r = try scanHome(dir, h)
        check("antigravity: a WAL database closed cleanly (no -wal beside it) is read as it is (2 calls, no issue)",
              !walLeft && r.calls == 2 && r.issues.isEmpty && !FileManager.default.fileExists(atPath: db + "-shm"))
    } catch { check("antigravity closed wal: \(error)", false) }

    // MARK: 12  Crush and Devin: ISO-8601 text dates

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
        try runSQL(h + "/.local/share/devin/cli/sessions.db", """
            CREATE TABLE sessions(id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL, model TEXT NOT NULL,
                agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL, title TEXT);
            CREATE TABLE message_nodes(row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, node_id INTEGER NOT NULL,
                parent_node_id INTEGER, chat_message TEXT NOT NULL, created_at INTEGER NOT NULL, metadata TEXT, UNIQUE(session_id, node_id));
            INSERT INTO sessions VALUES('de-iso','/work','local','adaptive','normal',1793968800,1793968900,NULL);
            INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('de-iso',1,
                '{"role":"assistant","metadata":{"request_id":"r1","generation_model":"swe-1-6-slow","metrics":{"input_tokens":100,"output_tokens":20}}}','2026-11-06 12:41:00');
            """)
        let r = try scanHome(dir, h)
        check("crush and devin: both calls are read from ISO text dates (2 calls)", r.calls == 2)
        check("crush and devin: ISO text dates are today, not 1970 (2 calls in the last 24 hours)", r.dayCalls == 2)
    } catch { check("crush devin iso dates: \(error)", false) }

    // MARK: 10  a small .zst that unpacks to one huge line

    if zstdUsable {
        do {
            let dir = try tempDir(), h = dir + "/home"
            let plain = h + "/.codex/archived_sessions/rollout-big.jsonl"
            // 96 MiB without a line break: far over what one line of a log can be, and a few KB once packed.
            try write(plain, String(repeating: "a", count: 96 << 20))
            _ = try zstdPack(plain, keep: false)
            let before = FileManager.default.fileExists(atPath: plain + ".zst")
            let r = try scanHome(dir, h)
            let again = try scanHome(dir, h)
            check("zst: the archive exists and is small", before && ((try? FileManager.default.attributesOfItem(atPath: plain + ".zst")[.size] as? Int) ?? Int.max) < (1 << 20))
            check("zst: a line past the limit is named as an issue, not unpacked into memory", r.issues.contains { $0.contains("rollout-big") && $0.contains("çok büyük") })
            check("zst: the same archive is not unpacked again on every pass", again.issues.isEmpty)
        } catch { check("zst huge line: \(error)", false) }
    } else {
        skip("zst: a huge line is an issue", zstdWhy)
    }

    // MARK: 13  tokenbar-cli: --offline and --prices-now

    do {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("tokenbar-cli").path
        if FileManager.default.isExecutableFile(atPath: binary) {
            let dir = try tempDir()
            func run(_ arguments: [String]) throws -> (Int32, String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments + ["--db", dir + "/cli.sqlite", "--home", dir + "/home", "--no-scan"]
                var env = ProcessInfo.processInfo.environment
                env["TOKENBAR_PRICES_PINNED"] = nil
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                try process.run()
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                return (process.terminationStatus, text)
            }
            try FileManager.default.createDirectory(atPath: dir + "/home", withIntermediateDirectories: true)
            let offline = try run(["--offline"])
            let now = try run(["--offline", "--prices-now"])
            let alias = try run(["--offline", "--refresh-prices"])
            check("cli: --offline is a flag", offline.0 == 0)
            check("cli: --prices-now is a flag (offline it asks nothing and says so)", now.0 == 0 && now.1.contains("skipped"))
            check("cli: --refresh-prices is the Windows spelling of it", alias.0 == 0)
        } else {
            skip("cli flags", "tokenbar-cli is not built")
        }
    } catch { check("cli flags: \(error)", false) }

    // MARK: 4  the price cache keeps what a lookup by exact id returns

    do {
        let openRouter = #"""
        {"data":[{"id":"acme/alpha-1","name":"Acme: Alpha 1","pricing":{"prompt":"0.000003","completion":"0.000015"}},
                 {"id":"acme/alpha-1:batch","name":"Acme: Alpha 1 (batch)","pricing":{"prompt":"0.0000015","completion":"0.0000075"}},
                 {"id":"acme/alpha-1:nitro","name":"Acme: Alpha 1 (nitro)","pricing":{"prompt":"0.000004","completion":"0.00002"}},
                 {"id":"acme/plain-9","name":"Acme: Plain 9","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}
        """#
        let liteLLM = #"""
        {"delta-4":{"mode":"chat","input_cost_per_token":1e-6,"output_cost_per_token":2e-6},
         "vertex_ai/delta-4@20250929":{"mode":"chat","input_cost_per_token":1.1e-6,"output_cost_per_token":2.2e-6},
         "gpt-fix-2024-05-13":{"mode":"chat","input_cost_per_token":5e-6,"output_cost_per_token":1.5e-5},
         "gpt-fix":{"mode":"chat","input_cost_per_token":2.5e-6,"output_cost_per_token":1e-5}}
        """#
        let raw: [PriceSource: Data] = [.openrouter: Data(openRouter.utf8), .litellm: Data(liteLLM.utf8)]
        let dir = URL(fileURLWithPath: try tempDir(), isDirectory: true)
        let fetcher = ScriptedFetcher()
        fetcher.script(.openrouter, .ok(openRouter, etag: "o1"))
        fetcher.script(.litellm, .ok(liteLLM, etag: "l1"))
        fetcher.script(.modelsdev, .fail)
        var config = PriceFeed.Config(cacheDirectory: dir, offline: false, fetcher: fetcher)
        config.ttl = 3600
        let feed = PriceFeed(config)
        _ = feed.refreshBlocking()
        let names = ["acme/alpha-1", "acme/alpha-1:batch", "acme/alpha-1:nitro", "acme/plain-9", "delta-4", "vertex_ai/delta-4@20250929",
                     "gpt-fix", "gpt-fix-2024-05-13"]
        func priced(_ catalogs: PriceCatalogs) -> [[Double]] {
            PriceBook.install(catalogs: catalogs)
            return names.map { name in
                let e = ModelPrice(model: name).entry
                return e.map { [$0.rates.input, $0.rates.output] } ?? []
            }
        }
        let fresh = priced(PriceCatalogs.fromRaw(raw))
        let cached = priced(feed.loadLocal())
        check("cache: the live catalogue prices the exact ids it lists (batch 1.5, vertex 1.1, dated 5.0)",
              fresh[1] == [1.5, 7.5] && fresh[2] == [4.0, 20.0] && fresh[5] == [1.1, 2.2] && fresh[7] == [5.0, 15.0])
        check("cache: written and read back, every name is priced as before", cached == fresh)
        // A cache that is only refreshed (304) keeps them too.
        let later = Clock(Date().addingTimeInterval(7200))
        var again = config
        again.now = { later.now }
        fetcher.script(.openrouter, .notModified)
        fetcher.script(.litellm, .notModified)
        _ = PriceFeed(again).refreshBlocking()
        check("cache: a 304 keeps them", priced(feed.loadLocal()) == fresh)
    } catch { check("cache exact ids: \(error)", false) }
    PriceBook.install(catalogs: .embedded)

    // MARK: 5  the hand-corrected table gives way to a live OpenRouter row

    do {
        let live = #"{"data":[{"id":"z-ai/glm-5.2","name":"Z.ai: GLM 5.2","pricing":{"prompt":"0.00000999","completion":"0.00001999"}}]}"#
        PriceBook.install(catalogs: PriceCatalogs.fromRaw([.openrouter: Data(live.utf8)]))
        let glm = ModelPrice(model: "glm-5.2").entry
        check("table: a model the live OpenRouter lists is priced by the live row", glm?.rates.input == 9.99 && glm?.rates.output == 19.99
              && glm?.source.contains("z-ai/glm-5.2") == true)
        let opus = ModelPrice(model: "claude-opus-5-5").entry
        check("table: a model the live catalogue does not list keeps the table price", opus?.rates.input == 4.0 && opus?.rates.output == 20.0)
        let near = ModelPrice(model: "crouton-alpha").entry
        check("table: a stand-in row (near) stays what the table says", near?.kind == .near)
        PriceBook.install(catalogs: .embedded)
        check("table: without a live catalogue (pinned, offline) the table prices glm-5.2", ModelPrice(model: "glm-5.2").entry?.kind == .openrouter)
    }

    // MARK: 6  a cache price of 0 is a price; alias chains resolve

    do {
        let file = #"""
        {"aliases":{"free-cache":{"input":10,"output":20,"cacheRead":0,"cacheWrite":0},
                    "no-cache":{"input":10,"output":20},
                    "chain-a":{"as":"chain-b"}, "chain-b":{"as":"chain-c"}, "chain-c":{"input":5,"output":10},
                    "loop-a":{"as":"loop-b"}, "loop-b":{"as":"loop-a"},
                    "chain-text":"chain-a"}}
        """#
        PriceBook.install(catalogs: .embedded, aliases: UserAliases(json: Data(file.utf8)))
        let million = TokenCounts(input: 0, cacheRead: 1_000_000, cacheWrite: 1_000_000, output: 0)
        check("alias: an explicit cacheRead 0 and cacheWrite 0 cost nothing", ModelPrice(model: "free-cache").cost(million) == 0)
        check("alias: a cache price left out falls to the input price", ModelPrice(model: "no-cache").cost(million) == 20)
        check("alias: a chain of {\"as\"} names resolves to the end of it", ModelPrice(model: "chain-a").entry?.rates.input == 5
              && ModelPrice(model: "chain-text").entry?.rates.output == 10)
        check("alias: a loop ends unpriced, not in a hang", ModelPrice(model: "loop-a").entry == nil)
        PriceBook.install(catalogs: .embedded)
    }

    // MARK: 7  a tier without a cache price keeps the base row's

    do {
        let openRouter = #"""
        {"data":[{"id":"acme/tier-1","name":"Acme: Tier 1","pricing":{"prompt":"0.000001","completion":"0.000004","input_cache_read":"0.0000001",
          "overrides":[{"min_prompt_tokens":200000,"prompt":"0.000002"}]}}]}
        """#
        let modelsDev = #"{"acme":{"models":{"tier-2":{"name":"Tier 2","cost":{"input":1,"output":4,"cache_read":0.1,"context_over_200k":{"input":2,"output":8}}}}}}"#
        PriceBook.install(catalogs: PriceCatalogs.fromRaw([.openrouter: Data(openRouter.utf8), .modelsdev: Data(modelsDev.utf8)]))
        // 250k cache-read tokens: a prompt over the tier start.
        let big = TokenCounts(input: 0, cacheRead: 250_000, cacheWrite: 0, output: 0)
        check("tiers: OpenRouter tier without cache fields keeps the base cache read price (0.025, not 0.5)", abs(ModelPrice(model: "acme/tier-1").cost(big) - 0.025) < 1e-9)
        check("tiers: models.dev tier without cache fields keeps the base cache read price", abs(ModelPrice(model: "acme/tier-2").cost(big) - 0.025) < 1e-9)
        PriceBook.install(catalogs: .embedded)
        let snapshot = (try? JSONSerialization.jsonObject(with: Data(PriceCatalogs.embeddedSnapshotText.utf8))) as? [String: Any] ?? [:]
        var lost: [String] = []
        for source in ["litellm", "modelsdev"] {
            for (id, any) in (snapshot[source] as? [String: [Any]]) ?? [:] {
                guard any.count > 5, let tiers = any[5] as? [[Any]], let baseRead = (any[2] as? NSNumber)?.doubleValue, baseRead > 0 else { continue }
                for t in tiers where t.count >= 6 && ((t[3] as? NSNumber)?.doubleValue ?? 0) == 0 { lost.append("\(source):\(id)") }
            }
        }
        check("tiers: no embedded tier lost the base row's cache read price", lost.isEmpty)
    }

    // MARK: 9  a very long model name costs time in proportion to its length

    do {
        let started = Date()
        _ = ModelPrice(model: String(repeating: "a-q4", count: 10_000))
        _ = ModelPrice(model: String(repeating: "(a)", count: 13_000))
        _ = ModelPrice(model: String(repeating: "x@", count: 20_000))
        check("names: 40k-character names are normalised in well under a second", Date().timeIntervalSince(started) < 1.0)
        check("names: a name over 256 characters is unpriced, one under it is not", ModelPrice(model: "claude-opus-5-5[" + String(repeating: "x", count: 300) + "]").entry == nil
              && ModelPrice(model: "claude-opus-5-5[" + String(repeating: "x", count: 100) + "]").entry != nil)
    }

    // MARK: 8  the price refresh repeats once a day while the app runs

    do {
        let dir = URL(fileURLWithPath: try tempDir(), isDirectory: true)
        let fetcher = ScriptedFetcher()
        let text = #"{"data":[{"id":"acme/daily-1","name":"Acme: Daily","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}"#
        fetcher.script(.openrouter, .ok(text, etag: nil))
        fetcher.script(.litellm, .fail)
        fetcher.script(.modelsdev, .fail)
        let clock = Clock(Date())
        var config = PriceFeed.Config(cacheDirectory: dir, offline: false, fetcher: fetcher)
        config.now = { clock.now }
        config.retryAfterFailure = 0
        let feed = PriceFeed(config)
        setenv("TOKENBAR_PRICES_PINNED", "0", 1)
        PriceBook.useHome(dir.path + "/home")
        func waitFor(_ asked: Int) -> Bool {
            for _ in 0..<100 {
                if fetcher.count(.openrouter) >= asked { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }
        PriceBook.startBackgroundRefresh(feed: feed)
        let first = waitFor(1)
        // The pass writes the cache once the answer is parsed: wait for the file, then the same day asks nothing.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("prices-openrouter.json").path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.2)
        // (a minute on: a cache stamped at this very instant can read back a hair in the future, and then is not fresh)
        clock.advance(60)
        PriceBook.startBackgroundRefresh(feed: feed)       // the same day: the cache is fresh, nothing is asked
        Thread.sleep(forTimeInterval: 0.3)
        let sameDay = fetcher.count(.openrouter)
        clock.advance(25 * 3600)
        PriceBook.startBackgroundRefresh(feed: feed)       // the next day, same process
        let nextDay = waitFor(2)
        setenv("TOKENBAR_PRICES_PINNED", "1", 1)
        check("refresh: the first start asks the network", first)
        check("refresh: a second start the same day asks nothing", sameDay == 1)
        check("refresh: a start a day later, in the same process, asks again", nextDay)
    } catch { check("refresh daily: \(error)", false) }
    PriceBook.install(catalogs: .embedded)

    PriceBook.install(catalogs: .embedded)
}
