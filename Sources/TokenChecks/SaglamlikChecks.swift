import Foundation
import SQLite3
import LocalCore

// Robustness checks: broken or hostile input must neither crash the reader nor count twice nor write into the
// folders of the tools it reads. Each case builds a small home, then scans it in a child process (a trap ends
// that process, not the run): `--probe saglam-scan DIR` scans DIR/home into DIR/usage.sqlite and prints what the
// index holds. A case that scans twice changes the files between the two runs. Called once from `main.swift`.

private let limit = TokenCounts.fieldLimit
private let maxInt = "9223372036854775807"
private let appSupport = "/Library/Application Support"
private let codeUser = appSupport + "/Code/User"
let clineTasks = codeUser + "/globalStorage/saoudrizwan.claude-dev/tasks"
let rooTasks = codeUser + "/globalStorage/rooveterinaryinc.roo-cline/tasks"

/// What a scan left in the index, as the probe prints it: `harness=tokens/calls ... cost=C issues=N`.
struct Scanned {
    var status: Int32 = -1
    var totals: [String: [Int64]] = [:]
    var cost = 0.0
    var issues = -1
    var raw = ""

    init(_ result: (status: Int32, out: String)) {
        status = result.status
        raw = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        for part in raw.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "cost" { cost = Double(pair[1]) ?? .nan } else if pair[0] == "issues" { issues = Int(pair[1]) ?? -1 } else {
                totals[pair[0]] = pair[1].split(separator: "/").compactMap { Int64($0) }
            }
        }
    }

    var ok: Bool { status == 0 && issues >= 0 }
    func total(_ harness: String) -> Int64? { totals[harness]?.first }
    func calls(_ harness: String) -> Int64? { totals[harness].flatMap { $0.count > 1 ? $0[1] : nil } }
}

func scan(_ dir: String) -> Scanned { Scanned(probe("saglam-scan", dir: dir)) }

/// The child process side of `scan`: one pass over DIR/home into DIR/usage.sqlite.
func saglamlikProbe(_ name: String, dir: String) -> String? {
    if name.hasPrefix("saglam-price") { return priceProbe(name, dir: dir) }
    guard name == "saglam-scan" else { return argonProbe(name, dir: dir) }
    guard let store = try? UsageStore(path: dir + "/usage.sqlite") else { return "store error" }
    // Rows of the index a case wants in place before the scan, as an older version of the app left them.
    if let seed = FileManager.default.contents(atPath: dir + "/meta.json"),
       let pairs = (try? JSONSerialization.jsonObject(with: seed)) as? [String: String] {
        for (key, value) in pairs { try? store.setMeta(key, value) }
    }
    let result = UsageScanner(store: store, home: dir + "/home", environment: [:]).scan()
    guard let report = try? store.usageBook(now: Date(timeIntervalSince1970: 1793970000)).report(for: .all) else { return "report error" }
    let parts = report.harnesses.sorted { $0.harness.rawValue < $1.harness.rawValue }
        .map { "\($0.harness.rawValue)=\($0.counts.total)/\($0.calls)" }
    return (parts + ["cost=\(report.harnesses.reduce(0.0) { $0 + $1.cost })", "issues=\(result.issues.count)"]).joined(separator: " ")
}

/// The price side: raw catalogue text in `dir`, answers as one line. A trap ends the child, not the run.
///   saglam-price-kept     dir/ll.json, dir/md.json -> the rows the index keeps, written out as JSON
///   saglam-price-cache    dir/cache/prices-*.json -> which of two models the local load prices
///   saglam-price-refresh  dir/feed/*.json served as the network, dir/cache stamped in the future -> one pass
private func priceProbe(_ name: String, dir: String) -> String {
    switch name {
    case "saglam-price-kept":
        guard let ll = FileManager.default.contents(atPath: dir + "/ll.json"), let md = FileManager.default.contents(atPath: dir + "/md.json") else { return "no input" }
        let kept = PriceTools.keptRows(litellm: ll, modelsdev: md)
        guard let data = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys]) else { return "not json" }
        return "litellm=\(kept["litellm"]?.keys.sorted().joined(separator: ",") ?? "-") modelsdev=\(kept["modelsdev"]?.keys.sorted().joined(separator: ",") ?? "-") bytes=\(data.count > 0)"
    case "saglam-price-cache":
        let feed = PriceFeed(PriceFeed.Config(cacheDirectory: URL(fileURLWithPath: dir + "/cache"), offline: true))
        PriceBook.install(catalogs: feed.loadLocal())
        return "bad=\(ModelPrice(model: "zz-bad-model").isPriced) good=\(ModelPrice(model: "zz-good-model").isPriced)"
    case "saglam-price-refresh":
        var config = PriceFeed.Config(cacheDirectory: URL(fileURLWithPath: dir + "/cache"), offline: false,
                                      fetcher: FilePriceFetcher(directory: URL(fileURLWithPath: dir + "/feed")))
        config.now = { Date(timeIntervalSince1970: 1793970000) }
        let report = PriceFeed(config).refreshBlocking()
        let written = (try? String(contentsOfFile: dir + "/cache/prices-litellm.json", encoding: .utf8)) ?? ""
        return "updated=\(report.updated.map(\.rawValue).sorted().joined(separator: ",")) fresh=\(report.fresh.map(\.rawValue).sorted().joined(separator: ",")) failed=\(report.failed.count) infinity=\(written.contains("nfinity") || written.contains("NaN"))"
    default:
        return "unknown price probe"
    }
}

/// A catalogue "network" in memory that counts its answers, each one slow enough for two passes to overlap.
private final class CountingFetcher: PriceFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var onFetch: (@Sendable () -> Void)?
    var fetched: Int { lock.withLock { count } }

    func fetch(_ source: PriceSource, etag: String?) async throws -> PriceFetchResponse {
        lock.withLock { count += 1 }
        onFetch?()
        try await Task.sleep(nanoseconds: 60_000_000)
        let text: String
        switch source {
        case .openrouter: text = #"{"data":[{"id":"vendor/zz-good-model","name":"Good","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}"#
        case .litellm: text = #"{"ok1":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"mode":"chat"}}"#
        case .modelsdev: text = #"{"prov":{"models":{"ok2":{"cost":{"input":1,"output":2}}}}}"#
        }
        return .ok(Data(text.utf8), etag: nil)
    }
}

private final class OfflineSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

func clineRow(_ text: String, ts: String = "1793968800000", model: String? = nil) -> String {
    let info = model.map { #","modelInfo":{"modelId":"\#($0)"}"# } ?? ""
    let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"type":"say","say":"api_req_started","ts":\#(ts),"text":"\#(escaped)"\#(info)}"#
}

func saglamlikChecks(tempDir: () throws -> String) throws {
    /// A fresh case folder with a `home` in it.
    func fresh() throws -> (dir: String, home: String) {
        let dir = try tempDir()
        try FileManager.default.createDirectory(atPath: dir + "/home", withIntermediateDirectories: true)
        return (dir, dir + "/home")
    }

    // MARK: numbers that do not fit

    do {
        let (dir, h) = try fresh()
        try write(h + clineTasks + "/t1/ui_messages.json", "[" + clineRow(#"{"tokensIn":5,"tokensOut":1}"#, model: "/") + "]")
        let r = scan(dir)
        check("cline: a model id of only slashes does not crash and counts", r.ok && r.total("cline") == 6 && r.calls("cline") == 1)
    } catch { check("saglamlik cline slash: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        try write(h + rooTasks + "/t1/ui_messages.json", "[" + clineRow(#"{"tokensIn":0,"cacheReads":\#(maxInt),"cacheWrites":\#(maxInt),"tokensOut":1,"apiProtocol":"openai"}"#) + "]")
        let r = scan(dir)
        check("roo: cache counts of Int64.max taken out of the prompt do not overflow", r.ok && r.total("roo-code") == 2 * limit + 1)
    } catch { check("saglamlik roo overflow: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let big = #"{"sessionId":"s","messages":[{"role":"assistant","id":"a","metrics":{"inputTokens":0,"cacheReadTokens":\#(maxInt),"cacheWriteTokens":\#(maxInt),"outputTokens":1}}]}"#
        try write(h + "/.cline/data/sessions/s1/s1.messages.json", big)
        let r = scan(dir)
        check("cline cli: input minus huge cache counts does not overflow", r.ok && r.total("cline") == 2 * limit + 1)
        let (dir2, h2) = try fresh()
        let negative = #"{"sessionId":"s","messages":[{"role":"assistant","id":"a","metrics":{"inputTokens":-10,"cacheReadTokens":\#(maxInt),"cacheWriteTokens":0,"outputTokens":1}}]}"#
        try write(h2 + "/.cline/data/sessions/s1/s1.messages.json", negative)
        let r2 = scan(dir2)
        check("cline cli: a negative prompt count with huge cache reads does not overflow", r2.ok && r2.total("cline") == limit + 1)
    } catch { check("saglamlik cline cli: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let thread = #"{"id":"T-x","messages":[{"role":"assistant","messageId":1,"usage":{"inputTokens":0,"outputTokens":0,"totalTokens":\#(maxInt),"cacheCreationInputTokens":\#(maxInt),"cacheReadInputTokens":\#(maxInt)}}]}"#
        try write(h + "/.local/share/amp/threads/T-x.json", thread)
        let r = scan(dir)
        check("amp: Int64.max totals and cache counts do not overflow the zero test", r.ok && r.total("amp") == 2 * limit && r.calls("amp") == 1)
    } catch { check("saglamlik amp: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let metrics = #"{"model_name":"gpt-6-luna","accumulated_token_usage":{"prompt_tokens":\#(maxInt),"completion_tokens":\#(maxInt),"cache_read_tokens":\#(maxInt),"cache_write_tokens":\#(maxInt)}}"#
        try write(h + "/.openhands/conversations/c1/base_state.json", #"{"stats":{"usage_to_metrics":{"agent":\#(metrics)}}}"#)
        let r = scan(dir)
        check("openhands: Int64.max usage does not overflow the zero test", r.ok && r.total("openhands") == 2 * limit)
    } catch { check("saglamlik openhands: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let message = #"{"role":"assistant","providerID":"openrouter","modelID":"gpt-6-luna","tokens":{"input":1,"output":\#(maxInt),"reasoning":1,"cache":{"read":0,"write":0}},"time":{"created":1793968800}}"#
        try runSQL(h + "/.local/share/opencode/opencode.db",
                   "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT); INSERT INTO message VALUES('m','s','\(message)',1);")
        let r = scan(dir)
        check("opencode: output of Int64.max plus reasoning does not overflow", r.ok && r.total("opencode") == 1 + limit)
    } catch { check("saglamlik opencode: \(error)", false) }

    // Times that are no Int64: a key or a date made of them must not trap.
    do {
        let (dir, h) = try fresh()
        try write(h + clineTasks + "/t1/ui_messages.json", "[" + clineRow(#"{"tokensIn":5,"tokensOut":1}"#, ts: "1e20", model: "m") + "]")
        let r = scan(dir)
        check("cline: a time of 1e20 does not crash and the call still counts", r.ok && r.total("cline") == 6)
    } catch { check("saglamlik cline time: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let line = #"{"kind":0,"v":{"requests":[{"promptTokens":5,"completionTokens":1,"timestamp":1e20,"modelId":"copilot/gpt-6-luna"}]}}"# + "\n"
        try write(h + codeUser + "/workspaceStorage/h/chatSessions/s.jsonl", line)
        let r = scan(dir)
        check("copilot chat: a time of 1e20 does not crash and the call still counts", r.ok && r.total("copilot-chat") == 6)
    } catch { check("saglamlik copilot chat time: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let line = #"{"type":"session.shutdown","timestamp":1e25,"data":{"modelMetrics":{"gpt-6-luna":{"usage":{"inputTokens":5,"outputTokens":1}}}}}"# + "\n"
        try write(h + "/.copilot/session-state/s/events.jsonl", line)
        let r = scan(dir)
        check("copilot cli: a time of 1e25 does not crash and the call still counts", r.ok && r.total("copilot-cli") == 6)
    } catch { check("saglamlik copilot cli time: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let line = #"{"type":"cost-state","sessionId":"s","startTime":1e23,"modelUsage":{"claude-opus-5-5":{"inputTokens":5,"outputTokens":1}}}"# + "\n"
        try write(h + "/.claude/projects/p/s.jsonl", line)
        let r = scan(dir)
        check("claude: a cost-state run time of 1e23 does not crash and the gap still counts", r.ok && r.total("claude-code") == 6)
    } catch { check("saglamlik claude start time: \(error)", false) }

    // Counts that cannot be priced as they stand.
    do {
        let (dir, h) = try fresh()
        let usage = #"{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":\#(maxInt),"cache_creation":{"ephemeral_1h_input_tokens":-1}}"#
        let line = #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"s","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","usage":\#(usage)}}"#
        try write(h + "/.claude/projects/p/s.jsonl", line + "\n")
        let r = scan(dir)
        check("claude: a huge cache write with a negative one-hour share is priced without overflow",
              r.ok && r.total("claude-code") == limit + 2 && r.cost.isFinite && r.cost > 0)
    } catch { check("saglamlik claude cache write: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let project = h + "/work/proj"
        try write(h + "/.local/share/crush/projects.json", #"{"projects":[{"path":"\#(project)","data_dir":"\#(project)/.crush","last_accessed":"2026-11-06T10:00:00Z"}]}"#)
        try runSQL(project + "/.crush/crush.db", """
        CREATE TABLE sessions(id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0,
            prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0, cost REAL NOT NULL DEFAULT 0.0,
            updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL);
        CREATE TABLE messages(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, parts TEXT NOT NULL DEFAULT '[]',
            model TEXT, provider TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, finished_at INTEGER);
        INSERT INTO sessions VALUES('c1',NULL,'one',3,100,-1000000,0.5,1793968800,1793968000);
        INSERT INTO messages VALUES('m1','c1','assistant','[]','gpt-6-luna','openai',1793968700,1793968700,NULL);
        """)
        let r = scan(dir)
        check("crush: a negative completion count is 0, not a negative cost", r.ok && r.total("crush") == 100 && r.cost >= 0)
    } catch { check("saglamlik crush negative: \(error)", false) }
    // MARK: catalogue rows that cannot be priced

    func priceDir(_ files: [String: String]) throws -> String {
        let dir = try tempDir()
        for (name, text) in files { try write(dir + "/" + name, text) }
        return dir
    }
    let goodLL = #""ok1":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"mode":"chat"}"#
    let goodMD = #""prov":{"models":{"ok2":{"cost":{"input":1,"output":2}}}}"#
    func kept(_ ll: String, _ md: String) throws -> (status: Int32, out: String) {
        probe("saglam-price-kept", dir: try priceDir(["ll.json": "{\(goodLL),\(ll)}", "md.json": "{\(goodMD),\(md)}"]))
    }
    let onlyGood = "litellm=ok1 modelsdev=prov/ok2 bytes=true"
    do {
        let k = try kept(#""bad":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"input_cost_per_token_above_9999999999999999k_tokens":2e-6}"#, #""p2":{"models":{}}"#)
        check("litellm: a tier threshold in thousands that overflows Int64 drops the row, no trap", k.status == 0 && k.out.contains(onlyGood))
        let m = try kept(#""bad":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6}"#, #""p3":{"models":{"m3":{"cost":{"input":1,"output":2,"tiers":[{"tier":{"type":"context","size":1e20},"input":3,"output":4}]}}}}"#)
        check("models.dev: a tier size beyond Int64 drops the row, no trap", m.status == 0 && m.out.contains("modelsdev=prov/ok2 "))
        let inf = try kept(#""bad":{"input_cost_per_token":1e305,"output_cost_per_token":2e-6,"mode":"chat"}"#, #""p3":{"models":{"m3":{"cost":{"input":1e305,"output":2}}}}"#)
        check("a price of 1e305 would be Infinity per million: the row is dropped and nothing non-finite is written", inf.status == 0 && inf.out.hasPrefix(onlyGood))
        let tier = try kept(#""bad":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6}"#, #""p3":{"models":{"m3":{"cost":{"input":1,"output":2,"tiers":[{"tier":{"type":"context","size":0},"input":-50,"output":-50}]}}}}"#)
        check("models.dev: a tier with a zero size and negative rates is no price", tier.status == 0 && tier.out.contains("modelsdev=prov/ok2 "))
        let sizeOnly = try kept(#""bad":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6}"#, #""p3":{"models":{"m3":{"cost":{"input":1,"output":2,"tiers":[{"tier":{"type":"context","size":0},"input":3,"output":4}]}}}}"#)
        check("models.dev: a tier of size zero is rejected even with sane rates", sizeOnly.status == 0 && sizeOnly.out.contains("modelsdev=prov/ok2 "))
        let router = try kept(#""bad":{"input_cost_per_token":-1e-6,"output_cost_per_token":2e-6}"#, #""p3":{"models":{"m3":{"cost":{"input":1,"output":2,"cache_read":-5}}}}"#)
        check("a negative base or cache rate drops the row", router.status == 0 && router.out.hasPrefix(onlyGood))
    } catch { check("saglamlik price rows: \(error)", false) }

    do {
        let row = { (tier: String) in #"{"schema":1,"source":"openrouter","fetched":1793900000,"rows":{"vendor/zz-bad-model":[1,2,0,0,0,[[\#(tier),3,4,0,0,0]]],"vendor/zz-good-model":[1,2,0,0,0]}}"# }
        for (label, tier) in [("1e20", "1e20"), ("zero", "0"), ("negative", "-5")] {
            let dir = try priceDir(["cache/prices-openrouter.json": row(tier)])
            let r = probe("saglam-price-cache", dir: dir)
            check("a cache file with a tier start of \(label) loads without a trap and the row is dropped", r.status == 0 && r.out.contains("bad=false good=true"))
        }
    } catch { check("saglamlik price cache: \(error)", false) }

    do {
        func openRouter(_ rows: String) -> String { #"{"data":[\#(rows)]}"# }
        let feed: [String: String] = [
            "feed/openrouter.json": openRouter(#"{"id":"vendor/zz-good-model","name":"Good","pricing":{"prompt":"0.000001","completion":"0.000002"}}"#),
            "feed/litellm.json": "{\(goodLL),\(#""bad":{"input_cost_per_token":1e305,"output_cost_per_token":2e-6,"mode":"chat"}"#)}",
            "feed/modelsdev.json": "{\(goodMD)}"]
        // The caches are stamped an hour ahead of the pass's clock: not fresh, so the pass asks (the feed is files).
        var files = feed
        for source in ["openrouter", "litellm", "modelsdev"] {
            files["cache/prices-\(source).json"] = #"{"schema":1,"source":"\#(source)","fetched":1793973600,"rows":{"vendor/zz-old":[1,2,0,0,0]}}"#
        }
        let r = probe("saglam-price-refresh", dir: try priceDir(files))
        check("a cache stamped in the future is stale, not fresh: the pass asks again",
              r.status == 0 && r.out.contains("updated=litellm,modelsdev,openrouter fresh= "))
        check("a catalogue row of 1e305 never reaches the cache file as Infinity", r.status == 0 && r.out.contains("infinity=false"))
    } catch { check("saglamlik price refresh: \(error)", false) }
    // MARK: Copilot Chat patches

    do {
        let (dir, h) = try fresh()
        let deep = #"{"kind":1,"k":["requests",0"# + String(repeating: #","result""#, count: 50_000) + #"],"v":1}"#
        let first = #"{"kind":0,"v":{"requests":[{"promptTokens":5,"completionTokens":1,"modelId":"copilot/gpt-6-luna"}]}}"#
        try write(h + codeUser + "/workspaceStorage/h/chatSessions/s.jsonl", first + "\n" + deep + "\n")
        let r = scan(dir)
        check("copilot chat: a patch path 50000 keys deep is skipped, no stack overflow", r.ok && r.total("copilot-chat") == 6)
    } catch { check("saglamlik copilot chat deep path: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        func request(_ prompt: Int, _ completion: Int, _ ts: Int) -> String {
            #"{"promptTokens":\#(prompt),"completionTokens":\#(completion),"timestamp":\#(ts),"modelId":"copilot/gpt-6-luna"}"#
        }
        let lines = [#"{"kind":0,"v":{"requests":[\#(request(100, 10, 1793968800000)),\#(request(200, 20, 1793968810000))]}}"#,
                     #"{"kind":0,"v":{"requests":[\#(request(0, 0, 1793968860000))]}}"#,
                     #"{"kind":1,"k":["requests",0,"promptTokens"],"v":500}"#, #"{"kind":1,"k":["requests",0,"completionTokens"],"v":50}"#]
        try write(h + codeUser + "/workspaceStorage/h/chatSessions/s.jsonl", lines.joined(separator: "\n") + "\n")
        let r = scan(dir)
        check("copilot chat: a second snapshot replaces the requests, so the patches name the right one",
              r.ok && r.total("copilot-chat") == 550 && r.calls("copilot-chat") == 1)
    } catch { check("saglamlik copilot chat snapshots: \(error)", false) }

    // MARK: counted twice

    do {
        let (dir, h) = try fresh()
        let chat = h + "/.config/manicode/projects/p/chats/c/chat-messages.json"
        func messages(_ output: Int) -> String { #"[{"variant":"ai","metadata":{"usage":{"input_tokens":100,"output_tokens":\#(output)}}}]"# }
        try write(chat, messages(10))
        let first = scan(dir)
        try write(chat, messages(200))
        let second = scan(dir)
        check("codebuff: a message without an id read half finished, then finished, counts once",
              first.ok && first.total("codebuff") == 110 && second.ok && second.total("codebuff") == 300 && second.calls("codebuff") == 1)
    } catch { check("saglamlik codebuff id-less: \(error)", false) }

    let zedSchema = "CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL, data BLOB NOT NULL, created_at TEXT);"
    func zedThread(_ requests: String, cumulative: Int) -> String {
        #"{"model":{"provider":"zed.dev","model":"claude-sonnet-4-5"},"request_token_usage":\#(requests),"cumulative_token_usage":{"input_tokens":\#(cumulative),"output_tokens":0}}"#
    }
    do {
        let (dir, h) = try fresh()
        let db = h + appSupport + "/Zed/threads/threads.db"
        try runSQL(db, zedSchema + "INSERT INTO threads VALUES('t','t','2026-11-06T10:00:00Z','json', CAST('\(zedThread("{}", cumulative: 1000))' AS BLOB), NULL);")
        let first = scan(dir)
        try runSQL(db, "UPDATE threads SET updated_at='2026-11-06T10:05:00Z', data=CAST('\(zedThread(#"{"m1":{"input_tokens":600}}"#, cumulative: 1000))' AS BLOB) WHERE id='t';")
        let second = scan(dir)
        check("zed: the adjustment row shrinks when the per-request counts catch up, nothing counted twice",
              first.ok && first.total("zed") == 1000 && second.ok && second.total("zed") == 1000 && second.calls("zed") == 1)
    } catch { check("saglamlik zed adjustment: \(error)", false) }

    // MARK: one bad record is one lost record

    do {
        let (dir, h) = try fresh()
        let db = h + appSupport + "/Zed/threads/threads.db"
        let good = zedThread(#"{"a":{"input_tokens":500}}"#, cumulative: 500)
        try runSQL(db, zedSchema
                   + "INSERT INTO threads VALUES('t1','t','2026-11-06T10:00:00Z','json', CAST('\(good)' AS BLOB), NULL);"
                   + "INSERT INTO threads VALUES('t2','t','2026-11-06T10:01:00Z','lz4', x'7878', NULL);")
        let r = scan(dir)
        check("zed: an unknown data_type is one named issue, the other threads still count", r.status == 0 && r.issues == 1 && r.total("zed") == 500)
    } catch { check("saglamlik zed unknown data type: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let thread = #"{"id":"s","messages":[{"id":"1","type":"gemini","model":"gemini-3.8-flash","tokens":{"input":5,"output":1}}]}"#
        let path = h + "/.gemini/tmp/p/chats/session-x.json"
        try write(path, thread)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        let first = scan(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        let second = scan(dir)
        check("gemini: a file that could not be read is an issue and is read again once it can be",
              first.ok && first.issues >= 1 && second.ok && second.total("gemini-cli") == 6)
    } catch { check("saglamlik gemini unreadable: \(error)", false) }
    // MARK: other tools' folders stay as they are

    /// A database in WAL mode as a tool that died would leave it: the `.db` and the `-wal`, no `-shm`, and the rows
    /// only in the `-wal` (the main file holds just the header page).
    func writeWALDatabase(_ path: String, _ sql: String) throws {
        let live = try tempDir() + "/live.db"
        var raw: OpaquePointer?
        guard sqlite3_open(live, &raw) == SQLITE_OK, let db = raw else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;" + sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 2) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: live, toPath: path)
        try FileManager.default.copyItem(atPath: live + "-wal", toPath: path + "-wal")
    }
    func scratchCopies() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("tokenbar-extdb-") })
    }

    do {
        let (dir, h) = try fresh()
        let folder = h + "/.local/share/opencode"
        let message = #"{"role":"assistant","providerID":"openrouter","modelID":"gpt-6-luna","tokens":{"input":7,"output":3,"cache":{"read":0,"write":0}},"time":{"created":1793968800}}"#
        try writeWALDatabase(folder + "/opencode.db",
                             "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT); INSERT INTO message VALUES('m','s','\(message)',1);")
        let before = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
        let copiesBefore = scratchCopies()
        let r = scan(dir)
        let after = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
        check("a WAL database is read, including the rows only the -wal holds", r.ok && r.total("opencode") == 10)
        check("reading a WAL database leaves no -shm (or anything else) in the tool's folder", before == ["opencode.db", "opencode.db-wal"] && after == before)
        check("the temporary copy of a WAL database is deleted again", scratchCopies().subtracting(copiesBefore).isEmpty)

        // A folder that cannot be written to (a read-only volume, a tool's protected folder) is read all the same.
        let (dir2, h2) = try fresh()
        let folder2 = h2 + "/.local/share/opencode"
        try writeWALDatabase(folder2 + "/opencode.db",
                             "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT); INSERT INTO message VALUES('m','s','\(message)',1);")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder2)
        let r2 = scan(dir2)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder2)
        check("a WAL database in a folder that cannot be written is still read", r2.ok && r2.total("opencode") == 10)
    } catch { check("saglamlik external db: \(error)", false) }

    do {
        let (dir, h) = try fresh()
        let folder = h + appSupport + "/Zed/threads"
        let thread = #"{"model":{"provider":"zed.dev","model":"m"},"request_token_usage":{"a":{"input_tokens":500}}}"#
        try writeWALDatabase(folder + "/threads.db", zedSchema + "INSERT INTO threads VALUES('t','t','2026-11-06T10:00:00Z','json', CAST('\(thread)' AS BLOB), NULL);")
        let before = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
        let r = scan(dir)
        let after = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
        check("zed: its WAL database is read and the folder is left as it was", r.ok && r.total("zed") == 500 && after == before && !after.contains("threads.db-shm"))
    } catch { check("saglamlik external db zed: \(error)", false) }
    // MARK: the price refresh

    do {
        let dir = try tempDir()
        let fetcher = CountingFetcher()
        var config = PriceFeed.Config(cacheDirectory: URL(fileURLWithPath: dir + "/cache"), offline: false, fetcher: fetcher)
        config.now = { Date(timeIntervalSince1970: 1793970000) }
        let feed = PriceFeed(config)
        // Two passes at once, as the refresh at launch and "Update prices" can be: the second must find the caches
        // the first wrote and ask nobody (three answers in all, not six).
        let done = DispatchGroup()
        for _ in 0..<2 {
            done.enter()
            Thread.detachNewThread { _ = feed.refreshBlocking(); done.leave() }
        }
        done.wait()
        check("two refresh passes at once ask each catalogue once", fetcher.fetched == 3)
    } catch { check("saglamlik refresh gate: \(error)", false) }

    do {
        let dir = try tempDir()
        let fetcher = CountingFetcher()
        let offline = OfflineSwitch()
        fetcher.onFetch = { offline.value = true }
        var config = PriceFeed.Config(cacheDirectory: URL(fileURLWithPath: dir + "/cache"), offline: false, fetcher: fetcher)
        config.shouldStop = { offline.value }
        let report = PriceFeed(config).refreshBlocking()
        check("going offline during a pass stops the remaining requests", fetcher.fetched == 1 && report.skipped.count == 2 && report.updated.count == 1)
    } catch { check("saglamlik refresh offline: \(error)", false) }

    do {
        // The setting is written on one thread and read on others.
        PriceBook.offline = false
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            if i % 2 == 0 { PriceBook.offline = (i % 4 == 0) } else { _ = PriceBook.isOffline }
        }
        PriceBook.offline = true
        let on = PriceBook.offline
        PriceBook.offline = false
        check("the offline setting reads back what was written", on && !PriceBook.offline)
    }
}
