import Foundation
import SQLite3
import LocalCore

// Crush, Goose, Factory Droid, Amp, OpenHands, the Devin CLI database, and the two tools that are
// only named (Warp, Amazon Q). The fixture home gets a static copy of each tool's files, as the
// tool writes them; the totals below are worked out by hand from those files.

/// What the closed catalog watched before G3, plus what the G3 tools add.
let g3WatchedPaths = [".local/share/crush", ".local/share/goose/sessions", "Library/Application Support/goose/sessions",
                      ".local/share/Block/goose/sessions", "Library/Application Support/Block/goose/sessions",
                      ".local/share/goose", ".factory/sessions", ".local/share/amp/threads", ".openhands/conversations"]

private let g3Harnesses: [HarnessID] = [.crush, .goose, .factoryDroid, .amp, .openHands]

private func g3Expect(_ name: String, _ got: Int64?, _ want: Int64) {
    check(name + " (\(got.map(String.init) ?? "-") == \(want))", got == want)
}

private func harnessTotal(_ report: UsageReport, _ id: HarnessID) -> Int64? {
    report.harnesses.first(where: { $0.harness == id })?.counts.total
}

private func harnessCalls(_ report: UsageReport, _ id: HarnessID) -> Int? {
    report.harnesses.first(where: { $0.harness == id })?.calls
}

private func g3UsageReport(_ store: UsageStore) throws -> UsageReport {
    try store.usageBook(now: Date()).report(for: .all)
}

// MARK: tool files

private func crushSessions(_ extra: String = "") -> String {
    """
    CREATE TABLE sessions(id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0,
        prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0, cost REAL NOT NULL DEFAULT 0.0,
        updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE messages(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, parts TEXT NOT NULL DEFAULT '[]',
        model TEXT, provider TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, finished_at INTEGER);
    \(extra)
    """
}

/// c1 holds two assistant messages, the later one names the model; c2 is a sub-agent session; c3 used nothing.
private func writeCrush(_ home: String, project: String? = nil, promptOfC1: Int = 1500, completionOfC1: Int = 300) throws {
    let project = project ?? home + "/work/proj"
    try write(home + "/.local/share/crush/projects.json",
              #"{"projects":[{"path":"\#(project)","data_dir":"\#(project)/.crush","last_accessed":"2026-11-06T10:00:00Z"}]}"#)
    try? FileManager.default.removeItem(atPath: project + "/.crush/crush.db")
    try runSQL(project + "/.crush/crush.db", crushSessions("""
    INSERT INTO sessions VALUES('c1',NULL,'one',3,\(promptOfC1),\(completionOfC1),0.5,1793968800,1793968000);
    INSERT INTO sessions VALUES('c2','c1','sub',1,300,50,0.1,1793968810,1793968100);
    INSERT INTO sessions VALUES('c3',NULL,'idle',0,0,0,0,1793968820,1793968200);
    INSERT INTO messages VALUES('m1','c1','assistant','[]','gpt-6-luna','openai',1793968700,1793968700,NULL);
    INSERT INTO messages VALUES('m2','c1','assistant','[]','claude-haiku-5-5','anthropic',1793968790,1793968790,NULL);
    INSERT INTO messages VALUES('m3','c1','user','[]','ignored-model','x',1793968795,1793968795,NULL);
    INSERT INTO messages VALUES('m4','c2','assistant','[]','gpt-6-luna','openai',1793968805,1793968805,NULL);
    """))
}

private func gooseSessions(_ extra: String = "") -> String {
    """
    CREATE TABLE sessions(id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', working_dir TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        total_tokens INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
        accumulated_total_tokens INTEGER, accumulated_input_tokens INTEGER, accumulated_output_tokens INTEGER,
        accumulated_cache_read_tokens INTEGER, accumulated_cache_write_tokens INTEGER, accumulated_cost REAL,
        provider_name TEXT, model_config_json TEXT);
    \(extra)
    """
}

/// g1 has running totals (input includes the cache), g2 only the latest call's counts, g3 nothing.
private func writeGoose(_ path: String, accumulatedInput: Int = 900) throws {
    try runSQL(path, gooseSessions("""
    INSERT INTO sessions VALUES('g1','one','/work/g','2026-11-06 10:00:00','2026-11-06 10:05:00',50,50,20,5,5,
        1100,\(accumulatedInput),100,300,100,0.2,'openai','{"model_name":"gpt-6-luna","context_limit":200000}');
    INSERT INTO sessions VALUES('g2','two','/work/g','2026-11-06 10:01:00','2026-11-06 10:06:00',50,40,10,NULL,NULL,
        NULL,NULL,NULL,NULL,NULL,NULL,'anthropic','{"model_name":"claude-haiku-5-5"}');
    INSERT INTO sessions VALUES('g3','three','/work/g','2026-11-06 10:02:00','2026-11-06 10:07:00',NULL,NULL,NULL,NULL,NULL,
        NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
    """))
}

private let droidOne = #"{"model":"custom:Claude-Haiku-5-5[Proxy]","providerLock":"anthropic","providerLockTimestamp":"2026-11-06T10:02:00.000Z","tokenUsage":{"inputTokens":100,"outputTokens":40,"cacheCreationTokens":10,"cacheReadTokens":50,"thinkingTokens":6}}"#
private let droidTwo = #"{"model":"gpt-6-luna","providerLockTimestamp":"2026-11-06T10:03:00.000Z","tokenUsage":{"inputTokens":20,"outputTokens":5}}"#
private let droidIdle = #"{"model":"gpt-6-luna","tokenUsage":{"inputTokens":0,"outputTokens":0}}"#

private func writeDroid(_ home: String) throws {
    try write(home + "/.factory/sessions/-work-proj/d1.settings.json", droidOne)
    try write(home + "/.factory/sessions/-work-proj/d2.settings.json", droidTwo)
    try write(home + "/.factory/sessions/-work-proj/d3.settings.json", droidIdle)
    // The transcript beside the settings carries no tokens and is not read.
    try write(home + "/.factory/sessions/-work-proj/d1.jsonl", #"{"type":"message","usage":{"inputTokens":99999}}"# + "\n")
}

/// The ledger gives the calls (cache counts come from the message each points at; the messages' own
/// input and output are the same calls and are not added); the second thread has no ledger.
private let ampLedger = #"{"id":"T-ledger","usageLedger":{"events":[{"id":"e1","timestamp":"2026-11-06T10:00:00.000Z","model":"claude-haiku-5-5","tokens":{"input":120,"output":34},"toMessageId":1},{"id":"e2","timestamp":"2026-11-06T10:01:00.000Z","model":"gpt-6-luna","tokens":{"total":1500},"toMessageId":2}]},"messages":[{"role":"user","content":"hi"},{"role":"assistant","messageId":1,"usage":{"inputTokens":9999,"outputTokens":9999,"cacheCreationInputTokens":50,"cacheReadInputTokens":700}},{"role":"assistant","messageId":2,"usage":{"cacheReadInputTokens":1200}}]}"#
private let ampMessages = #"{"id":"T-messages","messages":[{"role":"assistant","messageId":10,"timestamp":"2026-11-06T10:02:00.000Z","model":"gpt-6-luna","usage":{"inputTokens":10,"outputTokens":178,"cacheCreationInputTokens":986,"cacheReadInputTokens":11372}},{"role":"assistant","messageId":"m11","usage":{"model":"claude-haiku-5-5","totalTokens":345,"timestamp":"2026-11-06T10:03:00Z"}},{"role":"user","usage":{"inputTokens":5}}]}"#

private func writeAmp(_ home: String) throws {
    try write(home + "/.local/share/amp/threads/T-ledger.json", ampLedger)
    try write(home + "/.local/share/amp/threads/T-messages.json", ampMessages)
    // Not a thread file by name.
    try write(home + "/.local/share/amp/threads/notes.json", ampMessages.replacingOccurrences(of: "T-messages", with: "T-notes"))
}

private func openHandsState(agentPrompt: Int = 1000) -> String {
    #"""
    {"id":"conv1","execution_status":"idle","stats":{"usage_to_metrics":{
     "agent":{"model_name":"anthropic/claude-haiku-5-5","accumulated_cost":0.1,
       "accumulated_token_usage":{"model":"anthropic/claude-haiku-5-5","prompt_tokens":\#(agentPrompt),"completion_tokens":200,"cache_read_tokens":400,"cache_write_tokens":100,"reasoning_tokens":50},
       "costs":[{"model":"anthropic/claude-haiku-5-5","cost":0.1,"timestamp":1793968800.0}],
       "token_usages":[{"model":"anthropic/claude-haiku-5-5","prompt_tokens":99999,"completion_tokens":99999,"response_id":"r1"}]},
     "condenser":{"model_name":"gpt-6-luna","accumulated_token_usage":{"prompt_tokens":80,"completion_tokens":20},"costs":[{"cost":0.01,"timestamp":1793968900.0}]},
     "acp":{"model_name":"claude-haiku-5-5","accumulated_token_usage":{"prompt_tokens":10,"completion_tokens":5,"cache_read_tokens":30,"cache_write_tokens":0},"costs":[{"cost":0.01,"timestamp":1793969000.0}]},
     "listed":{"model_name":"gpt-6-luna","costs":[{"cost":0.01,"timestamp":1793969100.0}],"token_usages":[{"prompt_tokens":7,"completion_tokens":3},{"prompt_tokens":5,"completion_tokens":1}]}
    }}}
    """#
}

private func writeOpenHands(_ home: String) throws {
    try write(home + "/.openhands/conversations/conv1/base_state.json", openHandsState())
    // Event files beside the state hold no totals.
    try write(home + "/.openhands/conversations/conv1/events/event-00000.json", #"{"usage":{"prompt_tokens":123456}}"#)
}

private func devinSessionsSQL() -> String {
    """
    CREATE TABLE sessions(id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL, model TEXT NOT NULL,
        agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL, title TEXT);
    CREATE TABLE message_nodes(row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, node_id INTEGER NOT NULL,
        parent_node_id INTEGER, chat_message TEXT NOT NULL, created_at INTEGER NOT NULL, metadata TEXT, UNIQUE(session_id, node_id));
    INSERT INTO sessions VALUES('de-s','/work','local','adaptive','normal',1793968800,1793968900,NULL);
    INSERT INTO sessions VALUES('de-db','/work','local','adaptive','normal',1793968800,1793968900,NULL);
    INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('de-s',1,
        '{"role":"assistant","metadata":{"request_id":"x1","generation_model":"swe-1-6-slow","metrics":{"input_tokens":5000,"output_tokens":5000}}}',1793968800);
    INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('de-db',1,
        '{"role":"assistant","metadata":{"request_id":"r1","generation_model":"swe-1-6-slow","metrics":{"input_tokens":100,"output_tokens":20,"cache_read_tokens":50,"cache_creation_tokens":10}}}',1793968801);
    INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('de-db',2,
        '{"role":"assistant","metadata":{"request_id":"r1","generation_model":"swe-1-6-slow","metrics":{"input_tokens":100,"output_tokens":20,"cache_read_tokens":50,"cache_creation_tokens":10}}}',1793968802);
    INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('de-db',3,
        '{"role":"assistant","metadata":{"request_id":"r2","generation_model":"adaptive","metrics":{"input_tokens":30,"output_tokens":5}}}',1793968803);
    INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('de-db',4,
        '{"role":"user","metadata":{"metrics":{"input_tokens":777,"output_tokens":777}}}',1793968804);
    INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('de-db',5,
        '{"role":"assistant","metadata":{"request_id":"r3"}}',1793968805);
    INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('de-db',6,'not json at all',1793968806);
    """
}

private func writeDevinDatabase(_ home: String) throws {
    try runSQL(home + "/.local/share/devin/cli/sessions.db", devinSessionsSQL())
}

/// The named-only tools: a folder is all that is needed to see them.
private func writeNamedOnly(_ home: String, team: String = "2BBY89MBSN") throws {
    try write(home + "/Library/Application Support/amazon-q/data.sqlite3", "not read")
    try write(home + "/Library/Group Containers/\(team).dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite", "not read")
}

private func writeG3Fixture(_ home: String) throws {
    try writeCrush(home)
    try writeGoose(home + "/.local/share/goose/sessions/sessions.db")
    try writeDroid(home)
    try writeAmp(home)
    try writeOpenHands(home)
    // The transcript of `de-s` exists in the fixture already (Devin's own); only `de-db` is new.
    try writeDevinDatabase(home)
    try writeNamedOnly(home)
}

// MARK: checks

func runG3Checks(home: String) throws {
    try writeG3Fixture(home)
    func scratch() throws -> String {
        let dir = home + "/scratch/g3-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // Fixture totals, worked out by hand:
    //   Crush  c1 1500+300 + c2 300+50 = 2150 in 2 calls (the idle session counts nothing).
    //   Goose  g1 input 900 holds the cache (300+100): 500+300+100+100 = 1000; g2 40+10 = 50 -> 1050.
    //   Droid  d1 100+50+10+(40+6 thinking) = 206; d2 20+5 = 25; d3 none -> 231.
    //   Amp    e1 120+34+50+700 = 904; e2 total 1500 less cache 1200 is 300 input -> 1500; message 10
    //          10+178+986+11372 = 12546; m11 345 -> 904+1500+12546+345 = 15295 in 4 calls.
    //   OpenHands agent 1000 holds cache 500: 500+400+100+200 = 1200; condenser 100; acp (cache read
    //          above the prompt, so separate) 10+30+5 = 45; listed 7+5 + 3+1 = 16 -> 1361 in 4 calls.
    //   Devin sessions.db  de-db r1 100+50+10+20 = 180 (saved twice, once); r2 30+5 = 35 -> 215.
    let dir = try scratch()
    let store = try UsageStore(path: dir + "/usage.sqlite")
    let scanner = UsageScanner(store: store, home: home)
    let first = scanner.scan()
    check("G3 fixture reads without issues", first.issues.isEmpty)
    let all = try g3UsageReport(store)
    g3Expect("G3 Crush total", harnessTotal(all, .crush), 2150)
    g3Expect("G3 Goose total", harnessTotal(all, .goose), 1050)
    g3Expect("G3 Droid total", harnessTotal(all, .factoryDroid), 231)
    g3Expect("G3 Amp total", harnessTotal(all, .amp), 15295)
    g3Expect("G3 OpenHands total", harnessTotal(all, .openHands), 1361)
    check("G3 call counts", harnessCalls(all, .crush) == 2 && harnessCalls(all, .goose) == 2 && harnessCalls(all, .factoryDroid) == 2
          && harnessCalls(all, .amp) == 4 && harnessCalls(all, .openHands) == 4)
    // The ten tools the app had keep their totals; Devin gained the database's 215. Claude Code is 196, not the base's 356:
    // the base counted a claude-opus-5-5[1m] transcript row and its cost-state row twice (main.swift handTotals, same fix).
    let ten: [HarnessID: Int64] = [.claudeCode: 196, .codex: 331, .opencode: 73, .openDesign: 24, .ohMyPi: 19, .qwenCode: 24,
                                   .kimiCode: 30, .devin: 19 + 215, .antigravity: 14]
    check("G3 leaves the existing tools' totals alone", ten.allSatisfy { harnessTotal(all, $0.key) == $0.value })

    // What each field became: the model that was named last, the thinking share, the cache split.
    check("G3 Crush names the latest assistant model", all.model("crush|anthropic/claude-haiku-5-5")?.counts.total == 1800
          && all.model("crush|openai/gpt-6-luna")?.counts.total == 350)
    let droidModel = all.model("factory-droid|anthropic/claude-haiku-5-5")
    check("G3 Droid keeps thinking inside output and as the reasoning share", droidModel?.counts.output == 46 && droidModel?.counts.reasoning == 6
          && droidModel?.counts.cacheRead == 50 && droidModel?.counts.cacheWrite == 10)
    let gooseModel = all.model("goose|openai/gpt-6-luna")
    check("G3 Goose takes the cache out of the input", gooseModel?.counts.input == 500 && gooseModel?.counts.cacheRead == 300
          && gooseModel?.counts.cacheWrite == 100 && gooseModel?.counts.output == 100)
    check("G3 Amp reads a ledger thread from the ledger only", all.model("amp|amp/claude-haiku-5-5")?.counts.total == 904 + 345)
    check("G3 Devin database model falls back past adaptive", all.model("devin|devin/swe-1-6-slow")?.counts.total == 19 + 180)

    // A second pass over the same files adds nothing; a store built from scratch agrees.
    let second = scanner.scan()
    check("G3 unchanged scan adds no events", second.events == 0 && second.issues.isEmpty)
    let again = try UsageStore(path: dir + "/again.sqlite")
    _ = UsageScanner(store: again, home: home).scan()
    let countAgain = try again.eventCount(), countFirst = try store.eventCount()
    check("G3 rebuild gives the same totals", countAgain == countFirst)

    // The two tools that log no tokens are named and never counted.
    let namedOnly = Set(first.notCountable) == Set<HarnessID>([.warp, .amazonQ])
    let counted = all.harnesses.contains { $0.harness == .warp || $0.harness == .amazonQ }
    check("G3 named-only tools are detected and not countable",
          first.detected.contains(.warp) && first.detected.contains(.amazonQ) && namedOnly && !counted)
    do {
        let h = try scratch() + "/home"
        try write(h + "/Library/Group Containers/ABCDE12345.dev.other/x", "unrelated")
        let none = UsageScanner(store: try UsageStore(path: dir + "/n1.sqlite"), home: h).scan()
        check("G3 no Warp folder, nothing named", none.notCountable.isEmpty && !none.detected.contains(.warp))
        try writeNamedOnly(h, team: "ZZZZZ99999")
        let some = UsageScanner(store: try UsageStore(path: dir + "/n2.sqlite"), home: h).scan()
        check("G3 any team id finds Warp's group folder", some.notCountable.contains(.warp) && some.events == 0)
    } catch { check("G3 named-only scratch: \(error)", false) }

    // A rewritten cumulative file replaces the session's event: the total follows the file, nothing folds in twice.
    do {
        let h = try scratch() + "/home"
        try writeDroid(h)
        try writeAmp(h)
        try writeOpenHands(h)
        try writeCrush(h)
        try writeGoose(h + "/.local/share/goose/sessions/sessions.db")
        let s = try UsageStore(path: dir + "/rewrite.sqlite")
        let sc = UsageScanner(store: s, home: h)
        _ = sc.scan()
        let before = try s.eventCount()
        let t0 = try g3UsageReport(s)
        // Each tool's session grows: the totals follow the new files, and the event count does not move.
        try write(h + "/.factory/sessions/-work-proj/d1.settings.json", droidOne.replacingOccurrences(of: "\"inputTokens\":100", with: "\"inputTokens\":400"))
        try write(h + "/.local/share/amp/threads/T-messages.json", ampMessages.replacingOccurrences(of: "\"inputTokens\":10,", with: "\"inputTokens\":110,"))
        try write(h + "/.openhands/conversations/conv1/base_state.json", openHandsState(agentPrompt: 1300))
        try writeCrush(h, promptOfC1: 2500, completionOfC1: 400)
        try runSQL(h + "/.local/share/goose/sessions/sessions.db", "UPDATE sessions SET accumulated_input_tokens = 1900 WHERE id = 'g1';")
        let rescan = sc.scan()
        let t1 = try g3UsageReport(s)
        check("G3 rewrites read again without issues", rescan.issues.isEmpty && rescan.events > 0)
        g3Expect("G3 Droid rewrite replaces, not adds", harnessTotal(t1, .factoryDroid), 231 + 300)
        g3Expect("G3 Amp rewrite replaces, not adds", harnessTotal(t1, .amp), 15295 + 100)
        g3Expect("G3 OpenHands rewrite replaces, not adds", harnessTotal(t1, .openHands), 1361 + 300)
        g3Expect("G3 Crush rewrite replaces, not adds", harnessTotal(t1, .crush), 2150 + 1000 + 100)
        g3Expect("G3 Goose rewrite replaces, not adds", harnessTotal(t1, .goose), 1050 + 1000)
        let after = try s.eventCount()
        check("G3 rewrites add no rows", after == before && t0.callCount == t1.callCount)
        // A smaller value later (a Crush session summarised, a file reset) never lowers what was counted.
        try writeCrush(h, promptOfC1: 100, completionOfC1: 10)
        _ = sc.scan()
        let kept = try g3UsageReport(s)
        g3Expect("G3 Crush keeps the larger value after a smaller overwrite", harnessTotal(kept, .crush), 2150 + 1000 + 100)
        _ = sc.scan()
        let settled = try s.eventCount()
        check("G3 stable after rescan", settled == before)
    } catch { check("G3 rewrite checks: \(error)", false) }

    // Devin: the database counts only sessions without a transcript, and drops the ones that get one.
    do {
        let h = try scratch() + "/home"
        try writeDevinDatabase(h)
        let s = try UsageStore(path: dir + "/devin.sqlite")
        let sc = UsageScanner(store: s, home: h)
        _ = sc.scan()
        let alone = try g3UsageReport(s)
        g3Expect("G3 Devin database alone counts both sessions", harnessTotal(alone, .devin), 10_000 + 215)
        try write(h + "/.local/share/devin/cli/transcripts/de-db.json",
                  #"{"session_id":"de-db","agent":{"model_name":"swe-1-6-slow"},"steps":[{"step_id":1,"timestamp":"2026-11-06T10:00:00Z","metrics":{"prompt_tokens":15,"cached_tokens":5,"completion_tokens":4}}]}"#)
        _ = sc.scan()
        let one = try g3UsageReport(s)
        g3Expect("G3 a transcript that appears replaces the database rows of its session", harnessTotal(one, .devin), 10_000 + 19)
        try write(h + "/.local/share/devin/cli/transcripts/de-s.json",
                  #"{"session_id":"de-s","agent":{"model_name":"swe-1-6-slow"},"steps":[{"step_id":1,"timestamp":"2026-11-06T10:00:00Z","metrics":{"prompt_tokens":15,"cached_tokens":5,"completion_tokens":4}}]}"#)
        _ = sc.scan()
        let both = try g3UsageReport(s)
        g3Expect("G3 with both transcripts the database adds nothing", harnessTotal(both, .devin), 19 + 19)
        let events = sc.scan().events
        check("G3 Devin stable on rescan", events == 0)
    } catch { check("G3 devin checks: \(error)", false) }

    // The variables that move the tools (only for an explicit environment: a fixture ignores the real one).
    do {
        let h = try scratch() + "/home"
        let moved = h + "/moved"
        try write(moved + "/threads/T-ledger.json", ampLedger)
        try write(moved + "/threads/T-messages.json", ampMessages)
        try write(moved + "/.openhands/conversations/conv/base_state.json", openHandsState())
        try writeCrush(moved, project: moved + "/proj")
        try writeGoose(moved + "/goose-root/data/sessions/sessions.db")
        let env = ["AMP_DATA_DIR": moved, "OPENHANDS_CONVERSATIONS_DIR": moved + "/.openhands/conversations",
                   "CRUSH_GLOBAL_DATA": moved + "/.local/share/crush", "GOOSE_PATH_ROOT": moved + "/goose-root"]
        let s = try UsageStore(path: dir + "/env.sqlite")
        let moveResult = UsageScanner(store: s, home: h, environment: env).scan()
        check("G3 moved folders read without issues", moveResult.issues.isEmpty)
        let r = try g3UsageReport(s)
        g3Expect("G3 AMP_DATA_DIR", harnessTotal(r, .amp), 15295)
        g3Expect("G3 OPENHANDS_CONVERSATIONS_DIR", harnessTotal(r, .openHands), 1361)
        g3Expect("G3 CRUSH_GLOBAL_DATA", harnessTotal(r, .crush), 2150)
        g3Expect("G3 GOOSE_PATH_ROOT", harnessTotal(r, .goose), 1050)
        let plain = try UsageStore(path: dir + "/env2.sqlite")
        _ = UsageScanner(store: plain, home: h, environment: [:]).scan()
        let plainCount = try plain.eventCount()
        check("G3 without the variables the moved files are not found", plainCount == 0)
    } catch { check("G3 environment checks: \(error)", false) }

    // Hostile input: nothing traps, a bad file counts nothing, and a bad database is named without hiding the rest.
    do {
        let h = try scratch() + "/home"
        let bad = "'; DROP TABLE events; --"
        try write(h + "/.factory/sessions/p/truncated.settings.json", String(droidOne.dropLast(30)))
        try write(h + "/.factory/sessions/p/string.settings.json", #"{"model":"m","tokenUsage":"lots"}"#)
        try write(h + "/.factory/sessions/p/negative.settings.json", #"{"model":"m","tokenUsage":{"inputTokens":-5,"outputTokens":-1,"cacheReadTokens":-9}}"#)
        try write(h + "/.factory/sessions/p/huge.settings.json", #"{"model":"m","tokenUsage":{"inputTokens":1e30,"outputTokens":9223372036854775807,"thinkingTokens":9223372036854775807}}"#)
        try write(h + "/.factory/sessions/p/null.settings.json", "null")
        try write(h + "/.factory/sessions/p/türkçe şğüöç.settings.json", droidTwo.replacingOccurrences(of: "gpt-6-luna", with: "Çılgın-Model-ğ"))
        try write(h + "/.local/share/amp/threads/T-cut.json", String(ampLedger.dropLast(40)))
        try write(h + "/.local/share/amp/threads/T-types.json", #"{"id":5,"usageLedger":{"events":[7,"x",{"tokens":"many"},{"tokens":{"input":"12"}}]},"messages":"none"}"#)
        try write(h + "/.local/share/amp/threads/T-odd.json", ampMessages.replacingOccurrences(of: "T-messages", with: "T-ğ:'\\\"" + bad))
        try write(h + "/.openhands/conversations/c1/base_state.json", #"{"stats":{"usage_to_metrics":{"a":5,"b":{"accumulated_token_usage":[]},"c":{"model_name":3}}}}"#)
        try write(h + "/.openhands/conversations/c2/base_state.json", "{")
        try writeGoose(h + "/.local/share/goose/sessions/sessions.db")
        try runSQL(h + "/.local/share/goose/sessions/sessions.db", "INSERT INTO sessions(id,working_dir,accumulated_input_tokens,accumulated_output_tokens,model_config_json) VALUES('\(bad.replacingOccurrences(of: "'", with: "''"))','/x',70,0,'not json');")
        try write(h + "/Library/Application Support/goose/sessions/sessions.db", "this is not a database")
        try writeCrush(h, project: h + "/work/with ?#% odd & name")
        let s = try UsageStore(path: dir + "/hostile.sqlite")
        let result = UsageScanner(store: s, home: h).scan()
        let r = try g3UsageReport(s)
        check("G3 hostile input does not stop the scan", result.sources.contains { $0.name == "Amp" })
        // Of the Droid files only the Turkish-named one (25) and the one with huge counts hold anything.
        let droidTotal = harnessTotal(r, .factoryDroid) ?? 0
        check("G3 Droid keeps only what is countable and holds huge counts at the limit",
              droidTotal >= 25 + 1 && droidTotal < Int64.max && harnessCalls(r, .factoryDroid) == 2)
        g3Expect("G3 odd thread ids and broken threads", harnessTotal(r, .amp), 12891)
        g3Expect("G3 broken OpenHands states count nothing", harnessTotal(r, .openHands) ?? 0, 0)
        g3Expect("G3 Goose with an injection-looking id", harnessTotal(r, .goose), 1050 + 70)
        check("G3 the index survives the injection-looking id", (try? s.eventCount()) != nil
              && (try? queryInt(s.path, "SELECT COUNT(*) FROM events WHERE key LIKE 'goose:%DROP TABLE%'")) == 1)
        check("G3 a file that is no database is named as an issue", result.issues.contains { $0.source == "Goose" && $0.message.contains("sessions.db") })
        g3Expect("G3 Crush in a folder with odd characters", harnessTotal(r, .crush), 2150)
    } catch { check("G3 hostile checks: \(error)", false) }

    // A database without the tables is an issue, and the other tools still count.
    do {
        let h = try scratch() + "/home"
        try runSQL(h + "/work/p/.crush/crush.db", "CREATE TABLE unrelated(x);")
        try write(h + "/.local/share/crush/projects.json", #"{"projects":[{"path":"\#(h)/work/p","data_dir":"\#(h)/work/p/.crush"},{"path":"/gone","data_dir":"/gone/.crush"},{"data_dir":""},7]}"#)
        try writeDroid(h)
        let result = UsageScanner(store: try UsageStore(path: dir + "/notables.sqlite"), home: h).scan()
        check("G3 Crush database without tables is named, Droid still counts",
              result.issues.contains { $0.source == "Crush" } && result.sources.first { $0.name == "Factory Droid" }?.events == 2)
    } catch { check("G3 missing tables: \(error)", false) }

    // A file nobody may read is an issue of its own.
    do {
        let h = try scratch() + "/home"
        try writeDroid(h)
        let locked = h + "/.factory/sessions/-work-proj/d1.settings.json"
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        let result = UsageScanner(store: try UsageStore(path: dir + "/locked.sqlite"), home: h).scan()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked)
        check("G3 unreadable file is an issue, the others count", result.issues.contains { $0.message.contains("d1.settings.json") }
              && result.sources.first { $0.name == "Factory Droid" }?.events == 1)
    } catch { check("G3 unreadable file: \(error)", false) }

    // Watching: every new tool's folder, Crush's project folders, and not the named-only tools.
    do {
        let h = try scratch() + "/home"
        try writeCrush(h)
        try writeNamedOnly(h)
        let paths = Set(UsageScanner.watchPaths(home: h, environment: [:]))
        check("G3 watch paths", g3WatchedPaths.allSatisfy { paths.contains(h + "/" + $0) } && paths.contains(h + "/work/proj/.crush")
              && !paths.contains { $0.contains("amazon-q") || $0.contains("dev.warp") })
    } catch { check("G3 watch paths: \(error)", false) }

    check("G3 harness names", HarnessID.factoryDroid.name == "Factory Droid" && HarnessID.openHands.name == "OpenHands"
          && HarnessID.crush.name == "Crush" && HarnessID.goose.name == "Goose" && HarnessID.amp.name == "Amp")
    _ = g3Harnesses
}
