import Foundation
import LocalCore

/// Group 1: Gemini CLI, Pi, GitHub Copilot CLI, Junie, Codebuff, Mistral Vibe, Augment, and Qwen Code's
/// chat files. Called once from `main.swift`, after its own checks, because it adds fixture files to the
/// fixture home: `check.sh` then holds the CLI to the oracle over them too.
enum G1 {
    /// Where the group's own watch folders are, so the closed-list check can tell them from the old ones.
    static func watchPaths(home h: String) -> Set<String> {
        [".gemini/tmp", ".pi/agent/sessions", ".copilot/session-state", ".junie/sessions", ".config/manicode/projects",
         ".config/manicode-dev/projects", ".config/manicode-staging/projects", ".vibe/logs/session", ".augment/sessions",
         ".config/claude/projects"]
            .reduce(into: Set<String>()) { $0.insert(h + "/" + $1) }
    }

    static let now = Date(timeIntervalSince1970: 1793970000)

    /// Per harness: (total tokens, calls) of everything the store holds.
    static func totals(_ store: UsageStore) -> [String: [Int64]] {
        guard let report = try? store.usageBook(now: now).report(for: .all) else { return [:] }
        return Dictionary(uniqueKeysWithValues: report.harnesses.map { ($0.harness.rawValue, [$0.counts.total, Int64($0.calls)]) })
    }

    static func jsonl(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }

    static func claudeLine(_ id: String, _ request: String, _ input: Int, _ read: Int, _ write: Int, _ output: Int) -> String {
        #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"xdg-s","cwd":"/x","requestId":"\#(request)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"output_tokens":\#(output)}}}"# + "\n"
    }

    // MARK: the fixture home

    /// Writes one sample of each tool, from the real schemas, with hand-calculated totals:
    /// gemini-cli 1370 (3 calls), pi 186 (3), copilot-cli 1961 (4), junie 214 (2), codebuff 416 (4),
    /// mistral-vibe 1155 (2), augment 200 (2).
    static func writeFixture(_ h: String) throws {
        // Gemini CLI. m1: prompt 1000 with 600 cached, tool 10, output 50 + thoughts 20 → 410 + 600 + 70 = 1080.
        // m2: 200 + 30 = 230. The `$patch`/`$rewindTo` lines and the checkpoint file carry nothing. The old
        // single-document format: 50 + (5 + 5) = 60.
        let gem = h + "/.gemini/tmp/proj1/chats/session-g1.jsonl"
        try write(gem, jsonl(
            #"{"sessionId":"gem-s","projectHash":"hash1","startTime":"2026-11-06T10:00:00.000Z","lastUpdated":"2026-11-06T10:00:00.000Z","kind":"main"}"#,
            #"{"id":"u1","timestamp":"2026-11-06T10:00:00.500Z","type":"user","content":[{"text":"hi"}]}"#,
            #"{"id":"m1","timestamp":"2026-11-06T10:00:01.000Z","type":"gemini","content":"a","model":"gemini-3.8-flash"}"#,
            #"{"id":"m1","timestamp":"2026-11-06T10:00:01.000Z","type":"gemini","content":"a","model":"gemini-3.8-flash","tokens":{"input":1000,"output":50,"cached":600,"thoughts":20,"tool":10,"total":1080}}"#,
            #"{"id":"m2","timestamp":"2026-11-06T10:00:02.000Z","type":"gemini","content":"b","model":"gemini-3.8-flash","tokens":{"input":200,"output":30,"cached":0,"thoughts":0,"tool":0,"total":230}}"#,
            #"{"$patch":{"id":"m1","tokens":{"input":99999}}}"#,
            #"{"$rewindTo":"m2"}"#,
            #"{"id":"m1","timestamp":"2026-11-06T10:00:01.000Z","type":"gemini","content":"a","model":"gemini-3.8-flash","tokens":{"input":1000,"output":50,"cached":600,"thoughts":20,"tool":10,"total":1080}}"#))
        try write(h + "/.gemini/tmp/proj1/checkpoint-x.json",
                  #"{"sessionId":"x","messages":[{"id":"c1","type":"gemini","model":"gemini-3.8-flash","tokens":{"input":777,"output":1}}]}"#)
        try write(h + "/.gemini/tmp/proj2/chats/session-old.json",
                  #"{"sessionId":"gem-old","projectHash":"hash2","startTime":"2026-11-06T10:05:00.000Z","lastUpdated":"2026-11-06T10:05:00.000Z","messages":[{"id":"o1","timestamp":"2026-11-06T10:05:00.000Z","type":"gemini","model":"gemini-3.8-flash","tokens":{"input":50,"output":5,"cached":0,"thoughts":5,"tool":0,"total":60}}]}"#)

        // Pi. e1: 100 + 20 + 10 + 40 = 170 (the same call, copied into a fork, counts once). e3 has no
        // responseId: 10, its copy in the fork the same. e5: 6. The tool result's usage is its subagent's.
        let piHead = #"{"type":"session","version":3,"id":"pi-session","timestamp":"2026-11-06T10:00:00.000Z","cwd":"/fixture"}"#
        let e1 = #"{"type":"message","id":"e1","timestamp":"2026-11-06T10:00:01.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-haiku-5-5","usage":{"input":100,"output":40,"cacheRead":20,"cacheWrite":10,"cacheWrite1h":4,"reasoning":15,"totalTokens":170,"cost":{"input":0.1,"output":0.2,"cacheRead":0,"cacheWrite":0,"total":0.3}},"responseId":"pi-r1","timestamp":1793968801000}}"#
        let e3 = #"{"type":"message","id":"e3","timestamp":"2026-11-06T10:00:03.000Z","message":{"role":"assistant","provider":"openai","model":"gpt-6-luna","usage":{"input":7,"output":3,"cacheRead":0,"cacheWrite":0,"totalTokens":10},"timestamp":1793968803000}}"#
        let e4 = #"{"type":"message","id":"e4","timestamp":"2026-11-06T10:00:04.000Z","message":{"role":"toolResult","details":{"usage":{"input":900,"output":900}}}}"#
        let e5 = #"{"type":"message","id":"e5","timestamp":"2026-11-06T10:00:05.000Z","message":{"role":"assistant","provider":"openai","model":"gpt-6-luna","usage":{"input":5,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":6},"responseId":"pi-r2","timestamp":1793968805000}}"#
        try write(h + "/.pi/agent/sessions/--fixture--/2026-11-06T10-00-00-000Z_pi-session.jsonl", jsonl(piHead, e1, e3, e4))
        try write(h + "/.pi/agent/sessions/--fixture--/2026-11-06T10-10-00-000Z_pi-fork.jsonl",
                  jsonl(piHead.replacingOccurrences(of: "pi-session", with: "pi-fork"), e1, e3, e5))

        // GitHub Copilot CLI. Session 1: a call with accounting (1000 prompt holding 700 read and 200 written →
        // 100 + 700 + 200 + 50 = 1050), one without (320); the shutdown repeats them and is not counted.
        // Session 2 is a fork: it copies the first call (same accounting) and adds one of its own (66).
        // Session "old" has only a shutdown: 50 + 400 + 50 + 25 = 525.
        let call1 = #"{"type":"session.usage_record","id":"EID","timestamp":"2026-11-06T10:00:10.000Z","data":{"usage":{"model":"claude-haiku-5-5","inputTokens":1000,"outputTokens":50,"cacheReadTokens":700,"cacheWriteTokens":200,"reasoningTokens":10,"accounting":{"sourceSessionId":"cop-s1","sequence":1},"apiCallId":"api1"}}}"#
        try write(h + "/.copilot/session-state/cop-s1/events.jsonl", jsonl(
            #"{"type":"session.start","id":"a0","timestamp":"2026-11-06T10:00:00.000Z","data":{"sessionId":"cop-s1"}}"#,
            call1.replacingOccurrences(of: "EID", with: "u1"),
            #"{"type":"session.usage_record","id":"u2","timestamp":"2026-11-06T10:00:20.000Z","data":{"usage":{"model":"gpt-6-luna","inputTokens":300,"outputTokens":20,"cacheReadTokens":0,"cacheWriteTokens":0}}}"#,
            #"{"type":"session.shutdown","id":"sd1","timestamp":"2026-11-06T10:01:00.000Z","data":{"modelMetrics":{"claude-haiku-5-5":{"requests":{"count":1},"usage":{"inputTokens":1000,"outputTokens":50,"cacheReadTokens":700,"cacheWriteTokens":200,"reasoningTokens":10}},"gpt-6-luna":{"requests":{"count":1},"usage":{"inputTokens":300,"outputTokens":20,"cacheReadTokens":0,"cacheWriteTokens":0}}}}}"#))
        try write(h + "/.copilot/session-state/cop-s2/events.jsonl", jsonl(
            call1.replacingOccurrences(of: "EID", with: "copied"),
            #"{"type":"session.usage_record","id":"n1","timestamp":"2026-11-06T10:02:00.000Z","data":{"usage":{"model":"claude-haiku-5-5","inputTokens":60,"outputTokens":6,"cacheReadTokens":0,"cacheWriteTokens":0,"accounting":{"sourceSessionId":"cop-s2","sequence":1}}}}"#))
        try write(h + "/.copilot/session-state/cop-old/events.jsonl", jsonl(
            #"{"type":"session.shutdown","id":"sd9","timestamp":"2026-11-06T10:03:00.000Z","data":{"modelMetrics":{"gpt-6-luna":{"requests":{"count":2},"usage":{"inputTokens":500,"outputTokens":25,"cacheReadTokens":400,"cacheWriteTokens":50,"reasoningTokens":5}}}}}"#))

        // Junie: one event with two model calls, 100 + 50 + 10 + 20 = 180 and 30 + 4 = 34, replayed once;
        // events of other kinds, even ones that name this kind in a field, count nothing.
        let junieEvent = #"{"timestampMs":1793968800000,"event":{"agentEvent":{"kind":"LlmResponseMetadataEvent","modelUsage":[{"model":"claude-haiku-5-5","provider":"Anthropic","inputTokens":100,"outputTokens":20,"cacheInputTokens":50,"cacheCreateTokens":10,"reasoningTokens":5,"cost":0.01},{"model":"gpt-6-luna","inputTokens":30,"outputTokens":4}]}}}"#
        try write(h + "/.junie/sessions/session-261106-100000/events.jsonl", jsonl(
            #"{"kind":"UserPromptEvent","timestampMs":1793968700000}"#, junieEvent, junieEvent,
            #"{"timestampMs":1793968900000,"event":{"agentEvent":{"kind":"AgentStateUpdatedEvent","note":"LlmResponseMetadataEvent","modelUsage":[{"model":"x","inputTokens":5000}]}}}"#))

        // Codebuff: cb-1 = 100 + 40 + 10 + 30 = 180; cb-2 (OpenAI style, 150 of the 200 prompt cached) =
        // 50 + 150 + 20 = 220; the id-less agent message = 10. The dev channel repeats cb-1 and adds 6.
        try write(h + "/.config/manicode/projects/fixture/chats/2026-11-06T10-00-00.000Z/chat-messages.json",
                  #"[{"id":"cb-user","variant":"user","content":"hi"},{"id":"cb-1","variant":"ai","timestamp":"2026-11-06T10:00:05.000Z","metadata":{"model":"claude-haiku-5-5","usage":{"input_tokens":100,"output_tokens":30,"cache_read_input_tokens":40,"cache_creation_input_tokens":10,"credits":3}}},"#
                  + #"{"id":"cb-2","variant":"ai","metadata":{"model":"gpt-6-luna","codebuff":{"usage":{"prompt_tokens":200,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":150}}}}},{"variant":"agent","metadata":{"usage":{"inputTokens":7,"outputTokens":3}}}]"#)
        try write(h + "/.config/manicode-dev/projects/fixture/chats/2026-11-06T11-00-00.000Z/chat-messages.json",
                  #"[{"id":"cb-1","variant":"ai","metadata":{"model":"claude-haiku-5-5","usage":{"input_tokens":100,"output_tokens":30,"cache_read_input_tokens":40,"cache_creation_input_tokens":10}}},{"id":"cbd-1","role":"assistant","metadata":{"model":"gpt-6-luna","usage":{"input_tokens":5,"output_tokens":1}}}]"#)

        // Mistral Vibe: 1000 prompt of which 600 cached + 100 completion = 1100; the 1.x flat file 50 + 5 = 55.
        try write(h + "/.vibe/logs/session/session_20261106_100000_abcd1234/meta.json",
                  #"{"session_id":"vibe-s1","start_time":"2026-11-06T10:00:00+00:00","end_time":"2026-11-06T10:30:00+00:00","stats":{"session_prompt_tokens":1000,"session_completion_tokens":100,"session_cached_tokens":600,"steps":3},"config":{"active_model":"","models":{"mistral-medium-latest":{"alias":"mistral-medium-latest"}}}}"#)
        try write(h + "/.vibe/logs/session/session_legacy.json",
                  #"{"metadata":{"session_id":"vibe-old","start_time":"2026-11-06T09:00:00Z","stats":{"session_prompt_tokens":50,"session_completion_tokens":5,"session_cached_tokens":0},"config":{"active_model":"devstral-small-latest"}}}"#)

        // Augment: turn 1 takes its last non-empty usage, 100 + 30 + 20 + 40 = 190; turn 2 is not completed;
        // turn 3 has no request id and takes the session's model: 8 + 2 = 10.
        try write(h + "/.augment/sessions/aug-s1.json",
                  #"{"sessionId":"aug-s1","agentState":{"modelId":"claude-haiku-5-5"},"chatHistory":[{"completed":true,"finishedAt":"2026-11-06T10:00:00.000Z","sequenceId":1,"exchange":{"request_id":"r1","model_id":"claude-opus-5-5","response_nodes":[{"token_usage":{"input_tokens":10,"output_tokens":5}},{"token_usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":30,"cache_creation_input_tokens":20}}]}},"#
                  + #"{"completed":false,"exchange":{"request_id":"r2","response_nodes":[{"token_usage":{"input_tokens":999,"output_tokens":999}}]}},{"completed":true,"finishedAt":"2026-11-06T10:01:00.000Z","sequenceId":3,"exchange":{"response_nodes":[{"token_usage":{"input_tokens":8,"output_tokens":2}}]}}]}"#)

        // Qwen Code chat files next to Qwen's own usage files: the same calls, so these count nothing.
        try write(h + "/.qwen/projects/-fixture/chats/q-chat.jsonl", jsonl(
            #"{"uuid":"qc1","type":"assistant","timestamp":"2026-11-06T10:00:00Z","sessionId":"q-s","model":"qwen3.8-flash-next","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":30,"totalTokenCount":130}}"#))
    }

    static let handTotals: [String: [Int64]] = ["gemini-cli": [1370, 3], "pi": [186, 3], "copilot-cli": [1961, 4], "junie": [214, 2],
                                                "codebuff": [416, 4], "mistral-vibe": [1155, 2], "augment": [200, 2]]

    // MARK: the checks

    static func run(home: String, scratch: () throws -> String) {
        // The catalog: names, prefixes, colours.
        let named: [(String, String, String)] = [("gem", "gemini-cli", "Gemini CLI"), ("pi", "pi", "Pi"), ("cop", "copilot-cli", "GitHub Copilot CLI"),
            ("jun", "junie", "Junie"), ("cbuf", "codebuff", "Codebuff"), ("vibe", "mistral-vibe", "Mistral Vibe"),
            ("aug", "augment", "Augment"), ("qwenc", "qwen-code", "Qwen Code")]
        let resolved = named.map { HarnessID(keyPrefix: Substring($0.0)) }
        check("g1 prefixes and names are in the catalog", zip(named, resolved).allSatisfy { $0.1?.rawValue == $0.0.1 && $0.1?.name == $0.0.2 })
        let builtinPrefixes = HarnessCatalog.builtin.flatMap(\.keyPrefixes)
        check("every key prefix belongs to one tool", Set(builtinPrefixes).count == builtinPrefixes.count)

        do {
            // The fixture home: hand totals per tool, a second scan adds nothing.
            try writeFixture(home)
            let dir = try scratch()
            let store = try UsageStore(path: dir + "/g1.sqlite")
            let scanner = UsageScanner(store: store, home: home)
            let first = scanner.scan()
            let t1 = totals(store)
            check("g1 sources read without issue", first.issues.isEmpty)
            check("g1 hand-calculated totals and calls", handTotals.allSatisfy { t1[$0.key] == $0.value })
            check("Qwen chat files beside Qwen's usage files count nothing", !store.hasEvents(prefix: "qwenc:"))
            check("a second scan adds no events", scanner.scan().events == 0 && (totals(store)) == t1)

            // Appended lines count once; a Gemini message rewritten with more tokens replaces its first copy.
            try append(home + "/.junie/sessions/session-261106-100000/events.jsonl",
                       #"{"timestampMs":1793969000000,"event":{"agentEvent":{"kind":"LlmResponseMetadataEvent","modelUsage":[{"model":"gpt-6-luna","inputTokens":3,"outputTokens":1}]}}}"# + "\n")
            try append(home + "/.pi/agent/sessions/--fixture--/2026-11-06T10-00-00-000Z_pi-session.jsonl",
                       #"{"type":"message","id":"e6","timestamp":"2026-11-06T10:00:06.000Z","message":{"role":"assistant","provider":"openai","model":"gpt-6-luna","usage":{"input":2,"output":1,"cacheRead":0,"cacheWrite":0},"responseId":"pi-r3","timestamp":1793968806000}}"# + "\n")
            try append(home + "/.gemini/tmp/proj1/chats/session-g1.jsonl",
                       #"{"id":"m2","timestamp":"2026-11-06T10:00:02.000Z","type":"gemini","content":"b","model":"gemini-3.8-flash","tokens":{"input":200,"output":40,"cached":0,"thoughts":0,"tool":0,"total":240}}"# + "\n")
            _ = scanner.scan()
            let t2 = totals(store)
            check("appended and rewritten records count their change once",
                  t2["junie"] == [218, 3] && t2["pi"] == [189, 4] && t2["gemini-cli"] == [1380, 3])

            // A Vibe session that grows is one row with its latest counts.
            try write(home + "/.vibe/logs/session/session_20261106_100000_abcd1234/meta.json",
                      #"{"session_id":"vibe-s1","start_time":"2026-11-06T10:00:00+00:00","end_time":"2026-11-06T11:30:00+00:00","stats":{"session_prompt_tokens":2000,"session_completion_tokens":250,"session_cached_tokens":1200},"config":{"active_model":"","models":{"mistral-medium-latest":{"alias":"mistral-medium-latest"}}}}"#)
            _ = scanner.scan()
            check("a growing Vibe session is counted at its latest size", totals(store)["mistral-vibe"] == [2250 + 55, 2])
            // Put the fixture back, so check.sh's CLI and oracle read the hand-calculated tree.
            try writeFixture(home)
            let fresh = try UsageStore(path: dir + "/g1-again.sqlite")
            _ = UsageScanner(store: fresh, home: home).scan()
            check("the fixture is back to its hand totals", handTotals.allSatisfy { totals(fresh)[$0.key] == $0.value })
        } catch { check("g1 fixture: \(error)", false) }

        // Where the tools' folders are moved by their own variables (the real home only; a scan is told).
        do {
            let dir = try scratch(), h = dir + "/home"
            let s = try UsageStore(path: dir + "/usage.sqlite")
            try write(dir + "/gem-home/.gemini/tmp/p/chats/session-1.jsonl", jsonl(
                #"{"sessionId":"env-g","projectHash":"h"}"#,
                #"{"id":"e1","type":"gemini","model":"gemini-3.8-flash","timestamp":"2026-11-06T10:00:00Z","tokens":{"input":10,"output":2,"cached":0,"thoughts":0,"tool":0}}"#))
            try write(dir + "/pi-agent/sessions/--x--/2026-11-06T10-00-00-000Z_pi-env.jsonl", jsonl(
                #"{"type":"session","id":"pi-env","cwd":"/x"}"#,
                #"{"type":"message","timestamp":"2026-11-06T10:00:00.000Z","message":{"role":"assistant","provider":"openai","model":"gpt-6-luna","usage":{"input":4,"output":1},"responseId":"env-r"}}"#))
            try write(dir + "/cop/session-state/env-s/events.jsonl", jsonl(
                #"{"type":"session.usage_record","id":"i1","timestamp":"2026-11-06T10:00:00Z","data":{"usage":{"model":"gpt-6-luna","inputTokens":8,"outputTokens":2}}}"#))
            try write(dir + "/vibe/logs/session/session_env/meta.json",
                      #"{"session_id":"env-v","stats":{"session_prompt_tokens":6,"session_completion_tokens":1,"session_cached_tokens":0},"end_time":"2026-11-06T10:00:00Z"}"#)
            let lone = #"[{"id":"cbe","variant":"ai","metadata":{"usage":{"input_tokens":3}}}]"#
            try write(dir + "/cb/projects/p/chats/c/chat-messages.json", lone)
            try write(h + "/.config/manicode/projects/p/chats/c/chat-messages.json", #"[{"id":"cbh","variant":"ai","metadata":{"usage":{"input_tokens":50}}}]"#)
            try write(dir + "/xdg/claude/projects/e/s.jsonl", claudeLine("ex1", "er1", 7, 0, 0, 1))
            try FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true)
            let scanner = UsageScanner(store: s, home: h, environment: ["XDG_CONFIG_HOME": dir + "/xdg", "CLAUDE_CONFIG_DIR": dir + "/xdg/claude",
                                                                      "GEMINI_CLI_HOME": dir + "/gem-home", "PI_CODING_AGENT_DIR": dir + "/pi-agent/",
                                                                      "COPILOT_HOME": dir + "/cop", "VIBE_HOME": dir + "/vibe",
                                                                      "CODEBUFF_DATA_DIR": dir + "/cb"])
            let result = scanner.scan()
            let t = totals(s)
            check("GEMINI_CLI_HOME, PI_CODING_AGENT_DIR, COPILOT_HOME and VIBE_HOME move the tools",
                  result.issues.isEmpty && t["gemini-cli"] == [12, 1] && t["pi"] == [5, 1] && t["copilot-cli"] == [10, 1] && t["mistral-vibe"] == [7, 1])
            check("CODEBUFF_DATA_DIR replaces the channel folders", t["codebuff"] == [3, 1])
            check("XDG_CONFIG_HOME and CLAUDE_CONFIG_DIR naming one folder read it once", t["claude-code"] == [8, 1] && scanner.linePasses[dir + "/xdg/claude/projects/e/s.jsonl"] == 1)
            check("a moved folder is detected", Set(result.detected).isSuperset(of: [.geminiCLI, .pi, .copilotCLI, .mistralVibe]))
        } catch { check("g1 environment: \(error)", false) }

        // Detection: Antigravity's folder under ~/.gemini does not make Gemini CLI "detected"; chats do.
        do {
            let dir = try scratch(), h = dir + "/home"
            let s = try UsageStore(path: dir + "/usage.sqlite")
            try FileManager.default.createDirectory(atPath: h + "/.gemini/antigravity-cli/conversations", withIntermediateDirectories: true)
            let scanner = UsageScanner(store: s, home: h, environment: [:])
            let before = scanner.scan().detected
            try FileManager.default.createDirectory(atPath: h + "/.gemini/tmp", withIntermediateDirectories: true)
            let after = scanner.scan().detected
            check("Antigravity's folder is not Gemini CLI", before == [.antigravity] && after == [.antigravity, .geminiCLI])
        } catch { check("g1 detection: \(error)", false) }

        // Qwen Code chat files: counted alone, dropped once Qwen's own usage files appear (same calls).
        do {
            let dir = try scratch(), h = dir + "/home"
            let s = try UsageStore(path: dir + "/usage.sqlite")
            let chat = h + "/.qwen/projects/-fixture/chats/qs.jsonl"
            // 130 = 60 + 40 + 30 (thoughts inside the candidates, the total says so); 75 = 50 + 25 (the
            // Gemini API adds the thoughts on top of the candidates).
            try write(chat, jsonl(
                #"{"uuid":"a1","type":"user","timestamp":"2026-11-06T10:00:00Z","sessionId":"qs"}"#,
                #"{"uuid":"a2","type":"assistant","timestamp":"2026-11-06T10:00:01Z","sessionId":"qs","model":"qwen3.8-flash-next","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":30,"thoughtsTokenCount":10,"cachedContentTokenCount":40,"totalTokenCount":130}}"#,
                #"{"uuid":"a3","type":"assistant","timestamp":"2026-11-06T10:00:02Z","sessionId":"qs","model":"qwen3.8-flash-next","usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":20,"thoughtsTokenCount":5,"cachedContentTokenCount":0,"totalTokenCount":75}}"#))
            let scanner = UsageScanner(store: s, home: h, environment: [:])
            _ = scanner.scan()
            let alone = totals(s)
            check("Qwen chat files count alone", alone["qwen-code"] == [205, 2])
            let report = try s.usageBook(now: now).report(for: .all)
            check("Qwen chat thoughts: inside the output when the total says so, on top otherwise",
                  report.harnesses.first?.counts.reasoning == 15 && report.harnesses.first?.counts.output == 30 + 25)
            _ = scanner.scan()
            check("Qwen chat rescan adds nothing", totals(s)["qwen-code"] == [205, 2])
            try write(h + "/.qwen/usage/token-usage-2026-11.jsonl", #"{"id":"q1","timestamp":"2026-11-06T10:00:01Z","sessionId":"qs","model":"qwen3.8-flash-next","authType":"qwen","inputTokens":100,"cachedTokens":40,"outputTokens":30,"thoughtsTokens":10}"# + "\n")
            _ = scanner.scan()
            check("Qwen's own usage files replace the chat rows", totals(s)["qwen-code"] == [130, 1] && !s.hasEvents(prefix: "qwenc:"))
            // And the chat file, still there and unchanged, is not read again.
            _ = scanner.scan()
            check("Qwen chat rows stay out while the usage files stay", !s.hasEvents(prefix: "qwenc:"))
        } catch { check("g1 qwen chats: \(error)", false) }

        // Awkward files: empty, cut off, the wrong types, huge, negative, Turkish letters in names.
        do {
            let dir = try scratch(), h = dir + "/home"
            let s = try UsageStore(path: dir + "/usage.sqlite")
            for path in ["/.gemini/tmp/p/chats/session-empty.jsonl", "/.pi/agent/sessions/x/_empty.jsonl", "/.copilot/session-state/e/events.jsonl",
                         "/.junie/sessions/e/events.jsonl", "/.vibe/logs/session/session_e/meta.json", "/.augment/sessions/e.json",
                         "/.config/manicode/projects/p/chats/c/chat-messages.json"] { try write(h + path, "") }
            try write(h + "/.gemini/tmp/p/chats/session-cut.jsonl", #"{"id":"a","type":"gemini","model":"m","tokens":{"input":5"# + "\n" + "[1,2,3]\n\"text\"\nnull\n")
            try write(h + "/.gemini/tmp/p/chats/session-types.jsonl", jsonl(
                #"{"id":"t1","type":"gemini","model":"m","tokens":{"input":"12","output":null,"cached":[1],"thoughts":true}}"#,
                #"{"id":5,"type":"gemini","tokens":{"input":50}}"#,
                #"{"id":"neg","type":"gemini","model":"m","tokens":{"input":-100,"output":-5,"cached":-9}}"#,
                // 9.2e18 does not fit a count: it is held at the field limit, and sums of it do not trap.
                #"{"id":"huge","type":"gemini","model":"m","tokens":{"input":9200000000000000000,"output":9200000000000000000,"cached":0,"thoughts":9200000000000000000,"tool":9200000000000000000}}"#))
            try write(h + "/.junie/sessions/ışık-çğö/events.jsonl", jsonl(
                #"{"timestampMs":"soon","event":{"agentEvent":{"kind":"LlmResponseMetadataEvent","modelUsage":[{"model":"m","inputTokens":-3,"outputTokens":4},"junk",{"inputTokens":9},{"model":"ünlü-模型","provider":"İstanbul","inputTokens":2}]}}}"#,
                #"{"event":{"agentEvent":{"kind":"LlmResponseMetadataEvent","modelUsage":"nope"}}}"#))
            try write(h + "/.copilot/session-state/türkçe-şş/events.jsonl", jsonl(
                #"{"type":"session.usage_record","data":{"usage":"SECRET"}}"#,
                #"{"type":"session.usage_record","id":"z","data":{"usage":{"model":"m","inputTokens":5,"cacheReadTokens":50,"cacheWriteTokens":50,"outputTokens":1}}}"#,
                #"{"type":"session.shutdown","data":{"modelMetrics":["x"]}}"#))
            try write(h + "/.vibe/logs/session/session_odd/meta.json", #"{"stats":{"session_prompt_tokens":"many","session_cached_tokens":5000,"session_completion_tokens":2}}"#)
            try write(h + "/.augment/sessions/odd.json", #"{"chatHistory":[{"completed":true,"exchange":{"response_nodes":[{"token_usage":"x"},null,{"token_usage":{"input_tokens":1}}]}},5,{"completed":"yes"}]}"#)
            try write(h + "/.config/manicode/projects/p/chats/not-a-time/chat-messages.json", #"{"not":"an array"}"#)
            try write(h + "/.config/manicode-staging/projects/p/chats/c2/chat-messages.json",
                      #"[null,{"variant":"ai","metadata":{"usage":{"input_tokens":3}}},{"variant":"ai","metadata":{"runState":{"sessionState":{"mainAgentState":{"messageHistory":[{"role":"assistant","providerOptions":{"usage":{"inputTokens":4,"outputTokens":2},"codebuff":{"model":"routed"}}},{"role":"user"}]}}}}}]"#)
            let result = UsageScanner(store: s, home: h, environment: [:]).scan()
            let t = totals(s)
            // gemini: strings and nulls are no counts, `true` is 1; negatives are 0; 9.2e18 is held at the field limit.
            let limit = TokenCounts.fieldLimit
            let geminiTotal = t["gemini-cli"]?[0] ?? -1
            check("awkward files raise no issue and no crash", result.issues.isEmpty)
            check("empty, cut-off and mistyped Gemini records count what is countable",
                  geminiTotal >= 1 && t["gemini-cli"]?[1] == 2 && geminiTotal > limit)
            check("junie: negative held at zero, junk entries skipped, Turkish names kept", t["junie"] == [4 + 2, 2])
            check("copilot: cache larger than the prompt leaves no negative input", t["copilot-cli"] == [100 + 1, 1])
            check("vibe: cached above a non-number prompt counts what is there", t["mistral-vibe"] == [5000 + 2, 1])
            check("augment: only the readable completed turn", t["augment"] == [1, 1])
            check("codebuff: not-an-array file and routed history", t["codebuff"] == [3 + 4 + 2, 2])
        } catch { check("g1 awkward files: \(error)", false) }

        // A file that cannot be read (no permission, or a folder named like the file) is one named issue; the rest still counts.
        do {
            let dir = try scratch(), h = dir + "/home"
            let s = try UsageStore(path: dir + "/usage.sqlite")
            let locked = h + "/.config/manicode/projects/p/chats/c/chat-messages.json"
            try write(locked, #"[{"id":"x","variant":"ai","metadata":{"usage":{"input_tokens":9}}}]"#)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
            try FileManager.default.createDirectory(atPath: h + "/.copilot/session-state/d/events.jsonl", withIntermediateDirectories: true)
            try write(h + "/.augment/sessions/ok.json", #"{"chatHistory":[{"completed":true,"exchange":{"request_id":"r","model_id":"claude-opus-5-5","response_nodes":[{"token_usage":{"input_tokens":6}}]}}]}"#)
            let result = UsageScanner(store: s, home: h, environment: [:]).scan()
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked)
            check("an unreadable file is a named issue and the other tools still count",
                  result.issues.contains { $0.source == "Codebuff" } && result.issues.contains { $0.source == "GitHub Copilot CLI" }
                  && totals(s)["augment"] == [6, 1] && totals(s)["codebuff"] == nil)
        } catch { check("g1 unreadable files: \(error)", false) }

        // The oracle, run over scratch homes with the tricky cases, agrees with the scanner.
        do {
            let dir = try scratch()
            let h = dir + "/home"
            try writeFixture(h)
            try write(h + "/.qwen/projects/-x/chats/s.jsonl", jsonl(
                #"{"uuid":"o1","type":"assistant","timestamp":"2026-11-06T10:00:01Z","sessionId":"qs","model":"qwen3.8-flash-next","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":30,"thoughtsTokenCount":10,"cachedContentTokenCount":40,"totalTokenCount":130}}"#))
            // Claude Code under the XDG folder, and a subagent transcript below the usual one: 20 + 5.
            try write(h + "/.config/claude/projects/xdg/x.jsonl", claudeLine("mx1", "rq1", 10, 5, 2, 3))
            try write(h + "/.claude/projects/p/s1/subagents/agent-1.jsonl", claudeLine("mx2", "rq2", 4, 0, 0, 1))
            let s = try UsageStore(path: dir + "/usage.sqlite")
            _ = UsageScanner(store: s, home: h, environment: [:]).scan()
            let swiftTotals = totals(s)
            check("Claude Code is read from ~/.config/claude and from subagent files", swiftTotals["claude-code"] == [25, 2])
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", root + "/scripts/oracle.py", "all"]
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = h
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let oracle = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let harnesses = oracle?["harnesses"] as? [String: [String: Any]] ?? [:]
            let agrees = swiftTotals.allSatisfy { name, value in
                (harnesses[name]?["total"] as? NSNumber)?.int64Value == value[0] && (harnesses[name]?["calls"] as? NSNumber)?.int64Value == value[1]
            }
            check("g1 scanner and oracle agree on a scratch home", process.terminationStatus == 0 && !swiftTotals.isEmpty && agrees)
        } catch { check("g1 oracle agreement: \(error)", false) }
    }
}
