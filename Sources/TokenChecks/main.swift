import Foundation
import SQLite3
import LocalCore

/// Tools that live in a user's `custom-sources.json`, not in the library.
extension HarnessID {
    static let openDesign = HarnessID("open-design")
}
// Price checks run on the embedded snapshot and the hand-made tables only: never this Mac's cache or alias file.
setenv("TOKENBAR_PRICES_PINNED", "1", 1)
// The Turkish sentences below are the reference; the English readings are checked in l10nChecks().
setenv("TOKENBAR_LANG", "tr", 1)
if runPriceTool(CommandLine.arguments) { exit(0) }

var failures = 0
/// Checks that were not run (and why), listed once before the verdict. A skip is not a pass and not a failure.
var skipped: [String] = []
func skip(_ name: String, _ why: String) {
    skipped.append(name)
    print("SKIP \(name): \(why)")
}
/// The `zstd` that packs the fixtures: the first one on PATH, nil when there is none. The checks that need it are
/// skipped without it, and say so; the app itself works without zstd (it names the missing command once per scan).
let zstdPacker: String? = {
    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(directory)/zstd"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}()
/// The same, and the app must be able to find a zstd as well (`TOKENBAR_ZSTD=none` says it cannot): the checks that read
/// a packed fixture back need both.
let zstdUsable: Bool = zstdPacker != nil && ProcessInfo.processInfo.environment["TOKENBAR_ZSTD"].map { !($0.isEmpty || $0 == "none") } ?? true
/// Packs `path` into `path.zst` (and removes `path` when `keep` is false). False when there is no zstd or it failed.
@discardableResult func zstdPack(_ path: String, keep: Bool) throws -> Bool {
    guard let tool = zstdPacker else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = ["-q", "-f"] + (keep ? [] : ["--rm"]) + [path]
    try process.run(); process.waitUntilExit()
    return process.terminationStatus == 0
}
let zstdWhy = "zstd is not installed (brew install zstd); this check needs it"
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
func check(_ name: String, _ cond: @autoclosure () -> Bool) {
    if cond() { print("PASS \(name)") } else { failures += 1; fputs("FAIL \(name)\n", stderr) }
}
func write(_ path: String, _ contents: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}
/// A source added through `custom-sources.json`, as the file a user would write.
let customSourcesJSON = #"""
{"sources": [
  {"id": "open-design", "name": "Open Design", "family": "open-design-events",
   "paths": ["~/Library/Application Support/Open Design/namespaces/release-stable/data/runs"], "keyPrefix": "od", "hue": 325}
]}
"""#
func installCustomSources(_ home: String) throws {
    try write(home + "/.config/tokenbar/custom-sources.json", customSourcesJSON)
}
func append(_ path: String, _ contents: String) throws {
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(contents.utf8))
}
func runSQL(_ path: String, _ sql: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw NSError(domain: "sqlite", code: 1) }
    defer { sqlite3_close(db) }
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "sqlite error"
        if let error { sqlite3_free(error) }
        throw NSError(domain: message, code: 2)
    }
}
func protoVarint(_ n: Int) -> [UInt8] {
    var value = n, bytes: [UInt8] = []
    while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
    bytes.append(UInt8(value)); return bytes
}
func protoInt(_ field: Int, _ value: Int) -> [UInt8] { protoVarint(field << 3) + protoVarint(value) }
func protoBytes(_ field: Int, _ value: [UInt8]) -> [UInt8] {
    protoVarint((field << 3) | 2) + protoVarint(value.count) + value
}
func queryInt(_ path: String, _ sql: String) throws -> Int64 {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw NSError(domain: "sqlite", code: 1) }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw NSError(domain: "sqlite", code: 2) }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return sqlite3_column_int64(stmt, 0)
}
func relEqual(_ a: Double, _ b: Double) -> Bool {
    if a == b { return true }
    let m = max(abs(a), abs(b))
    guard m > 0 else { return true }
    return abs(a - b) <= 1e-9 * m
}
func eventForLine(_ line: String, parser: inout SessionParser) -> UsageEvent? {
    let bytes = Array(line.utf8)
    return bytes.withUnsafeBytes { parser.consume(line: $0, filePath: "t") }
}
func insertBlob(_ dbPath: String, _ table: String, _ idx: Int, _ type: Int?, _ bytes: [UInt8]) throws {
    var db: OpaquePointer?
    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { throw NSError(domain: "sqlite", code: 3) }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = type == nil ? "INSERT INTO \(table)(idx,data) VALUES(?,?)" : "INSERT INTO \(table)(idx,step_type,metadata) VALUES(?,?,?)"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw NSError(domain: "sqlite", code: 4) }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(idx))
    if let type {
        sqlite3_bind_int(stmt, 2, Int32(type))
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(bytes.count), sqliteTransient) }
    } else {
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(bytes.count), sqliteTransient) }
    }
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "sqlite", code: 5) }
}

// Child-process probes: a trap or a missing tool must fail one check, not end the whole run.
func probeEvent(_ key: String, _ model: String = "claude-opus-5-5") -> UsageEvent {
    UsageEvent(key: key, provider: "anthropic", model: model, timestamp: 1793968800,
               tokens: TokenCounts(input: 10, output: 5), session: "s", file: "f")
}
func runProbe(_ name: String, dir: String) throws {
    let now = Date(timeIntervalSince1970: 1793970000)
    switch name {
    case "total-overflow":
        let huge = TokenCounts(input: .max, cacheRead: .max, cacheWrite: .max, output: .max)
        var sum = huge
        sum += huge
        let negative = TokenCounts(input: -100, cacheRead: -1, cacheWrite: 0, output: 50)
        print("huge=\(huge.total > 0) sum=\(sum.total > 0) negative=\(negative.total)")
    case "empty-group":
        let store = try UsageStore(path: dir + "/u.sqlite")
        try store.insertEvents([probeEvent("cc:a")])
        var group = try store.usageBook(now: now).report(for: .all).groups[0]
        group.stats = []
        print("harness=\(group.mainHarness.rawValue)")
    case "tide-edges":
        let store = try UsageStore(path: dir + "/u.sqlite")
        try store.insertEvents([probeEvent("cc:a"), probeEvent("cx:b", "gpt-6-luna")])
        let report = try store.usageBook(now: now).report(for: .all)
        var single = report
        if var tide = single.tide {
            tide.count = 1
            tide.tokens = tide.tokens.mapValues { Array($0.prefix(1)) }
            tide.dollars = tide.dollars.mapValues { Array($0.prefix(1)) }
            single.tide = tide
        }
        func finite(_ l: TideLayout) -> Bool {
            let ys = l.bands.flatMap { [$0.tokenOuter, $0.tokenInner, $0.dollarInner, $0.dollarOuter].flatMap { $0 } }
            return l.xs.allSatisfy(\.isFinite) && ys.allSatisfy(\.isFinite)
        }
        print("one-bucket=\(TideLayout(report: single, width: 100, height: 50).map(finite) ?? false)")
        let flat = TideLayout(report: report, width: 0, height: 50)
        let points = flat.map { l in l.bands.flatMap { b in [b.tokenOuter, b.tokenInner, b.dollarInner, b.dollarOuter].flatMap { l.segments($0) } } } ?? []
        let coordinates = points.flatMap { [$0.control1.x, $0.control1.y, $0.control2.x, $0.control2.y, $0.end.x, $0.end.y] }
        print("zero-width=\((flat.map(finite) ?? false) && coordinates.allSatisfy(\.isFinite))")
        var none = report
        if var tide = none.tide {
            tide.count = 0
            tide.tokens = tide.tokens.mapValues { _ in [] }
            tide.dollars = tide.dollars.mapValues { _ in [] }
            none.tide = tide
        }
        print("no-bucket=\(TideLayout(report: none, width: 100, height: 50) == nil)")
    case "tide-bucket":
        let store = try UsageStore(path: dir + "/u.sqlite")
        try store.insertEvents([probeEvent("cc:a")])
        let report = try store.usageBook(now: now).report(for: .all)
        guard let layout = TideLayout(report: report, width: 100, height: 50), let flat = TideLayout(report: report, width: 0, height: 50) else {
            print("layout=nil"); return
        }
        let last = layout.xs.count - 1
        print("bucket=\(layout.bucket(atX: .nan) >= 0) \(layout.bucket(atX: .infinity) == last) \(layout.bucket(atX: -.infinity) == 0) \(flat.bucket(atX: 1e300) >= 0)")
    case "zstd-missing":
        let home = dir + "/home"
        let store = try UsageStore(path: dir + "/usage.sqlite")
        let head = #"{"type":"session_meta","payload":{"id":"cx-NAME","model_provider":"openai","timestamp":"2026-11-06T09:00:00Z"}}"# + "\n"
            + #"{"type":"turn_context","payload":{"model":"gpt-6-luna","cwd":"/fixture"}}"# + "\n"
        func rollout(_ name: String, _ total: Int) -> String {
            head.replacingOccurrences(of: "NAME", with: name)
                + #"{"type":"event_msg","timestamp":"2026-11-06T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total),"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":\#(total),"output_tokens":0}}}}"# + "\n"
        }
        try write(home + "/.codex/sessions/rollout-plain.jsonl", rollout("plain", 7))
        for i in 1...3 {
            let path = home + "/.codex/archived_sessions/rollout-z\(i).jsonl"
            try write(path, rollout("z\(i)", 100 + i))
            try zstdPack(path, keep: false)
        }
        let scanner = UsageScanner(store: store, home: home)
        let first = scanner.scan().issues.filter { $0.source == "Codex" }
        let second = scanner.scan().issues.filter { $0.source == "Codex" }
        print("first=\(first.count) second=\(second.count)")
        print("message=\(first.first?.message ?? "-")")
        print("recorded=\(try store.fileRecords().keys.filter { $0.hasSuffix(".zst") }.count)")
        print("events=\(try store.eventCount())")
    default:
        print(g2Probe(name, dir: dir) ?? saglamlikProbe(name, dir: dir) ?? fix902Probe(name, dir: dir) ?? fix904Probe(name, dir: dir) ?? fix905Probe(name, dir: dir) ?? fix906Probe(name, dir: dir) ?? fix907Probe(name, dir: dir) ?? "unknown probe")
    }
}
func probe(_ name: String, dir: String = "", env: [String: String] = [:]) -> (status: Int32, out: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--probe", name, dir]
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
// Before anything below wipes the fixture home.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--probe" {
    do { try runProbe(CommandLine.arguments[2], dir: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "") } catch {
        print("probe error: \(error)")
        exit(3)
    }
    exit(0)
}

do {
    // Beside the executable, so runs from different checkouts never share it. check.sh reads it.
    let home = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tokenbar-fixture").path
    try? FileManager.default.removeItem(atPath: home)
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    // Outside the harness folders, so added checks never change the fixture totals; the next run clears it.
    func tempDir() throws -> String {
        let dir = home + "/scratch/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
    try installCustomSources(home)
    let dbPath = home + "/usage.sqlite"
    let store = try UsageStore(path: dbPath)
    let scanner = UsageScanner(store: store, home: home)
    let ts = "2026-11-06T10:00:00.000Z"

    // Claude transcript rows, advisor pass, one-hour cache, and session accounting gap.
    let claude = home + "/.claude/projects/demo/session.jsonl"
    let c1 = #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"claude-s","cwd":"/fixture","requestId":"req1","message":{"id":"msg1","model":"claude-opus-5-5[1m]","usage":{"input_tokens":100,"cache_read_input_tokens":10,"cache_creation_input_tokens":20,"cache_creation":{"ephemeral_1h_input_tokens":7},"output_tokens":30,"iterations":[{"type":"advisor","model":"claude-haiku-5-5","input_tokens":4,"output_tokens":2}]}}}"#
    let c2 = #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"claude-s","cwd":"/fixture","requestId":"req1","message":{"id":"msg1","model":"claude-opus-5-5[1m]","usage":{"input_tokens":90,"output_tokens":20}}}"#
    let synthetic = #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"claude-s","requestId":"syn","message":{"id":"syn","model":"<synthetic>","usage":{"input_tokens":999,"output_tokens":999}}}"#
    let costState = #"{"type":"cost-state","sessionId":"claude-s","startTime":"2026-11-06T10:00:00.000Z","modelUsage":{"claude-opus-5-5[1m]":{"inputTokens":120,"cacheReadInputTokens":10,"cacheCreationInputTokens":25,"outputTokens":35}}}"#
    try write(claude, [c1,c2,synthetic,costState].joined(separator: "\n") + "\n")

    // Codex cumulative totals: repeat, delta and reset; the plain log is then appended and rescanned.
    let codex = home + "/.codex/sessions/2026/rollout-cx.jsonl"
    let codexHead = #"{"type":"session_meta","payload":{"id":"cx-s","model_provider":"openai","timestamp":"2026-11-06T09:00:00Z"}}"# + "\n"
      + #"{"type":"turn_context","payload":{"model":"gpt-6-luna","cwd":"/fixture"}}"# + "\n"
    func cx(_ total: Int, _ input: Int, _ output: Int, _ time: String) -> String {
        #"{"type":"event_msg","timestamp":"\#(time)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total),"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\#(output)},"last_token_usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}}"#
    }
    try write(codex, codexHead + cx(100,80,20,ts) + "\n" + cx(100,80,20,ts) + "\n" + cx(150,120,30,"2026-11-06T10:01:00Z") + "\n" + cx(40,30,10,"2026-11-06T10:02:00Z") + "\n")
    // Compressed finished rollout, independent session.
    let zst = home + "/.codex/archived_sessions/rollout-z.jsonl"
    try write(zst, codexHead.replacingOccurrences(of: "cx-s", with: "cx-z") + cx(11,9,2,ts) + "\n")
    if zstdPacker != nil { let packed = try zstdPack(zst, keep: true); check("zstd fixture compressed", packed) } else { skip("zstd fixture compressed", zstdWhy) }

    // Main opencode SQLite source.
    func makeOC(_ path: String, _ id: String, _ input: Int, _ output: Int, _ reasoning: Int) throws {
        try runSQL(path, "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT);")
        let json = #"{"role":"assistant","providerID":"openrouter","modelID":"gpt-6-luna","path":{"cwd":"/fixture"},"tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"cache":{"read":3,"write":2}},"time":{"created":1793968800}}"#
        try runSQL(path, "INSERT INTO session VALUES('s','/fixture'); INSERT INTO message VALUES('\(id)','s','\(json)',1793968800);")
    }
    let ocDB = home + "/.local/share/opencode/opencode.db"
    try makeOC(ocDB,"oc-1",50,8,2)

    let od = home + "/Library/Application Support/Open Design/namespaces/release-stable/data/runs/run-1/events.jsonl"
    try write(od, #"{"timestamp":"2026-11-06T10:00:00Z","data":{"type":"status","model":"claude-opus-5-5"}}"# + "\n" +
        #"{"timestamp":"2026-11-06T10:01:00Z","data":{"type":"request_usage","requestId":"od-1","usage":{"input_tokens":12,"cache_read_input_tokens":3,"cache_creation_input_tokens":4,"output_tokens":5}}}"# + "\n")

    let omp = home + "/.omp/agent/sessions/project/2026-11-06_session-omp.jsonl"
    let ompHead = #"{"type":"session","id":"omp-session","cwd":"/fixture"}"# + "\n"
    let ompCall = #"{"timestamp":"2026-11-06T10:00:00Z","message":{"provider":"anthropic","model":"claude-haiku-5-5","usage":{"input":8,"cacheRead":2,"cacheWrite":1,"output":4},"responseId":"omp-r1"}}"#
    let omitted = #"{"timestamp":"2026-11-06T10:00:00Z","role":"toolResult","type":"toolResult","details":{"usage":{"input":900,"output":900}}}"#
    try write(omp, ompHead + ompCall + "\n" + omitted + "\n")

    let qwenCall = home + "/.qwen/usage/token-usage-2026-11.jsonl"
    try write(qwenCall, #"{"id":"q1","timestamp":"2026-11-06T10:00:00Z","sessionId":"q-s","model":"qwen3.8-flash-next","authType":"qwen","inputTokens":10,"cachedTokens":3,"outputTokens":4,"thoughtsTokens":1}"# + "\n")
    let qwenRecord = home + "/.qwen/usage_record.jsonl"
    try write(qwenRecord, #"{"timestamp":"2026-11-06T10:01:00Z","sessionId":"q-s","models":{"qwen3.8-flash-next":{"totalTokens":25,"inputTokens":16,"cachedTokens":4,"outputTokens":8,"thoughtsTokens":2}}}"# + "\n")

    let kimi = home + "/.kimi-code/sessions/work/kimi-s/agents/a/wire.jsonl"
    try write(kimi, #"{"type":"llm.request","modelAlias":"openrouter/gpt-6-luna"}"# + "\n" +
        #"{"time":"2026-11-06T10:00:00Z","event":{"type":"step.end","messageId":"k1","usage":{"inputOther":20,"inputCacheRead":2,"inputCacheCreation":3,"output":5}}}"# + "\n")
    let devin = home + "/.local/share/devin/cli/transcripts/de-s.json"
    try write(devin, #"{"session_id":"de-s","agent":{"model_name":"swe-1-6-slow"},"steps":[{"step_id":1,"timestamp":"2026-11-06T10:00:00Z","metrics":{"prompt_tokens":15,"cached_tokens":5,"completion_tokens":4}}]}"#)

    // Minimal hand-encoded protobuf records following AntigravityReader's field paths.
    let ag = home + "/.gemini/antigravity-cli/conversations/ag-s.db"
    try runSQL(ag, "CREATE TABLE gen_metadata(idx INTEGER, data BLOB); CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB);")
    let gen = protoBytes(1, protoInt(3,1) + protoBytes(19, Array("gemini-3.8-flash".utf8)))
    let usage = protoInt(1,1) + protoInt(2,7) + protoInt(3,4) + protoInt(4,2) + protoInt(5,1) + protoInt(9,1)
    let stamp = protoBytes(8, protoInt(1,1793968800))
    let metadata = stamp + protoBytes(9,usage)
    try insertBlob(ag, "gen_metadata", 0, nil, gen); try insertBlob(ag, "steps", 0, 15, metadata)

    let scan1 = scanner.scan()
    check("all fixture sources read", scan1.issues.isEmpty && scan1.events > 0)
    let scan2 = scanner.scan()
    check("unchanged scan adds no events", scan2.events == 0)
    let initialCount = try store.eventCount()
    // Appended records exercise incremental state and stable oh-my-pi session seeding.
    try append(codex, cx(170,135,35,"2026-11-06T10:03:00Z") + "\n")
    try append(omp, #"{"timestamp":"2026-11-06T10:03:00Z","message":{"provider":"anthropic","model":"claude-haiku-5-5","usage":{"input":3,"output":1},"responseId":"omp-r2"}}"# + "\n")
    let scan3 = scanner.scan()
    check("plain Codex and oh-my-pi append reads", scan3.events == 2)
    let afterAppend = try store.eventCount()
    check("oh-my-pi keeps session id after resumed header", afterAppend == initialCount + 2)

    // OpenCode is fully re-read with stable row IDs; the new message adds exactly once.
    let beforeOC = try store.eventCount()
    let ocNew = #"{"role":"assistant","providerID":"openrouter","modelID":"gpt-6-luna","tokens":{"input":5,"output":2,"reasoning":1,"cache":{"read":0,"write":0}},"time":{"created":1793968801}}"#
    try runSQL(ocDB, "INSERT INTO message VALUES('oc-2','s','\(ocNew)',1793968801);")
    _ = scanner.scan()
    let afterOC = try store.eventCount()
    check("opencode rescan adds new message once", afterOC == beforeOC + 1)

    // Source failures are surfaced while all healthy source counters remain operational.
    let odEvents = od
    let odText = try String(contentsOfFile: odEvents, encoding: .utf8)
    try FileManager.default.removeItem(atPath: odEvents)
    try FileManager.default.createDirectory(atPath: odEvents, withIntermediateDirectories: true)
    let health = scanner.scan()
    let afterHealth = try store.eventCount()
    check("broken source reports issue and other sources count", health.issues.contains(where:{$0.source == "Open Design"})
          && afterHealth >= initialCount + 3)
    try FileManager.default.removeItem(atPath: odEvents)
    try write(odEvents, odText)

    check("ISO time parser", ISOTime.parse(ts) != nil && ISOTime.parse("broken") == nil)
    check("line reader counts complete lines", {
        let p = home + "/line-reader.txt"; try? write(p,"a\nb\n")
        let r = try? LineReader.forEachLine(path:p,from:0) { _ in true }
        return r?.endOffset == 4
    }())
    check("price normalization variants", PriceBook.normalize("Anthropic/CLAUDE-OPUS-5-5:FREE") == "claude-opus-5-5"
          && PriceBook.normalize("vendor/qwen3.8-flash-next-20261106") == "qwen3.8-flash-next")
    let opusPrice = ModelPrice(model:"claude-opus-5-5")
    let tierPrice = ModelPrice(model:"claude-haiku-5-5")
    check("pricing cache write one-hour and regular", abs(opusPrice.cost(TokenCounts(input:1_000_000,cacheWrite:10,cacheWrite1h:4))-4.000062) < 1e-9)
    check("pricing selects prompt tier", abs(tierPrice.cost(TokenCounts(input:100_000,output:100_000))-0.3) < 1e-9)
    check("free route pays the list price", ModelPrice(model:"claude-opus-5-5:free").cost(TokenCounts(input:1_000_000)) == 4
          && !ModelPrice(model:"never-listed-free").isPriced)
    check("no free row in the price table", ["big-pickle", "openrouter/free", "stealth/crouton-alpha", "glm-4.5-flash"]
          .allSatisfy { ModelPrice(model:$0).cost(TokenCounts(input:1_000_000, output:1_000_000)) > 0 })
    check("price table knows the session's own model", ModelPrice(model:"claude-fable-5-2").cost(TokenCounts(input:1_000_000)) > 0)
    check("localized money formatting", UsageText.money(3070.43) == "$3.070,43" && UsageText.money(0.001) == "<$0,01" && UsageText.money(0) == "$0")

    let now = Date(timeIntervalSince1970: 1793970000)
    let book = try store.usageBook(now:now)
    let all = book.report(for:.all), hour = book.report(for:.oneHour), day = book.report(for:.day)
    let handTotals: [HarnessID: Int64] = [.claudeCode:196,.codex:331,.opencode:73,.openDesign:24,.ohMyPi:19,
                                        .qwenCode:24,.kimiCode:30,.devin:19,.antigravity:14]
    let reportedTotals = Dictionary(uniqueKeysWithValues: all.harnesses.map { ($0.harness, $0.counts.total) })
    check("exact hand-calculated totals", all.counts.total == 730 && all.callCount == 16 && reportedTotals == handTotals)
    check("per-period totals", all.callCount > hour.callCount && hour.callCount > 0 && day.counts.total == all.counts.total)
    let claudeAdjustmentModel = all.model("claude-code|anthropic/claude-opus-5-5")
    check("harness and model totals", all.harnesses.contains(where:{$0.harness == .claudeCode})
          && all.model("claude-code|anthropic/claude-opus-5-5[1m]") == nil && claudeAdjustmentModel != nil)
    check("adjustment rows add tokens and cost without calls", all.callCount == 16
          && claudeAdjustmentModel?.calls == 1 && (claudeAdjustmentModel?.counts.total ?? 0) == 190
          && abs((claudeAdjustmentModel?.cost ?? 0) - 0.001328) < 1e-12)
    check("Claude adjustment key exists", store.hasEvents(prefix:"cc:adj:"))

    // A foreign schema version is an error, never a rebuild; history stays.
    do {
        let dir = try tempDir()
        let bad = dir + "/usage.sqlite"
        try runSQL(bad, "CREATE TABLE events(key TEXT PRIMARY KEY); INSERT INTO events VALUES('k'); PRAGMA user_version = 999;")
        var threw = false
        do { _ = try UsageStore(path: bad) } catch { threw = true }
        check("wrong user version throws", threw)
        let kept = (try? queryInt(bad, "SELECT COUNT(*) FROM events")) ?? -1
        let keptVersion = (try? queryInt(bad, "PRAGMA user_version")) ?? -1
        check("wrong user version keeps rows", kept == 1 && keptVersion == 999)
    } catch { check("wrong user version throws", false); check("wrong user version keeps rows", false) }

    // Negative file numbers are just bits; the index reads them back.
    do {
        let dir = try tempDir()
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try runSQL(s.path, "INSERT INTO files(path,inode,size,mtime,offset) VALUES('neg',1,-5,0.0,-7);")
        let rec = try s.fileRecords()["neg"]
        check("negative file row reads", rec != nil && rec!.size == UInt64(bitPattern: Int64(-5)) && rec!.offset == UInt64(bitPattern: Int64(-7)))
    } catch { check("negative file row reads", false) }

    // An adjustment row prices its tokens but never counts a call.
    do {
        let dir = try tempDir()
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let tokens = TokenCounts(input: 100, cacheRead: 10, output: 50)
        let want = ModelPrice(model: "gpt-6-luna").baseParts(tokens).total
        try s.insertEvents([UsageEvent(key: "devin:adj:t1", provider: "devin", model: "gpt-6-luna", timestamp: 1793968800, tokens: tokens, session: "s", file: "f", adjustment: true)])
        let rep = try s.usageBook(now: now).report(for: .all)
        let dev = rep.harnesses.first(where: { $0.harness == .devin })
        check("devin adj counts tokens and cost without call", rep.counts.total == tokens.total && relEqual(rep.cost, want) && rep.callCount == 0 && dev?.calls == 0)
    } catch { check("devin adj counts tokens and cost without call", false) }

    // One model under several table rows is one band, whatever name the log used.
    do {
        let dir = try tempDir()
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let tokens = TokenCounts(input: 100, output: 50)
        try s.insertEvents(["claude-opus-5-5", "claude-opus-5-5[1m]", "anthropic/claude-opus-5-5"].enumerated().map { i, model in
            UsageEvent(key: "oc:same-\(i)", provider: "p\(i)", model: model, timestamp: 1793968800, tokens: tokens, session: "s", file: "f")
        })
        PriceBook.install(catalogs: .embedded)
        defer { PriceBook.install(catalogs: .embedded) }
        let groups = try s.usageBook(now: now).report(for: .all).groups
        check("one model under several table rows is one band", groups.count == 1 && groups.first?.tokens == 3 * tokens.total)
    } catch { check("one model under several table rows is one band", false) }

    // Each step takes its own enum name even when the table order differs or a row is missing.
    do {
        let dir = try tempDir()
        let h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let sc = UsageScanner(store: s, home: h)
        let conv = h + "/.gemini/antigravity-cli/conversations"
        try FileManager.default.createDirectory(atPath: conv, withIntermediateDirectories: true)
        let dbp = conv + "/ag-t.db"
        try runSQL(dbp, "CREATE TABLE gen_metadata(idx INTEGER, data BLOB); CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB);")
        func genRow(_ e: Int, _ name: String) -> [UInt8] { protoBytes(1, protoInt(3, e) + protoBytes(19, Array(name.utf8))) }
        func stepMeta(_ e: Int, _ input: Int, _ output: Int) -> [UInt8] {
            protoBytes(8, protoInt(1, 1793968800)) + protoBytes(9, protoInt(1, e) + protoInt(2, input) + protoInt(3, output))
        }
        // Gen rows stored in reverse enum order on purpose.
        try insertBlob(dbp, "gen_metadata", 0, nil, genRow(2, "gemini-3.7-flash"))
        try insertBlob(dbp, "gen_metadata", 1, nil, genRow(1, "gemini-3.8-flash"))
        try insertBlob(dbp, "steps", 0, 15, stepMeta(1, 5, 3))
        try insertBlob(dbp, "steps", 1, 15, stepMeta(2, 10, 6))
        try insertBlob(dbp, "steps", 2, 15, stepMeta(99, 2, 1))
        let res = sc.scan()
        let rep = try s.usageBook(now: now).report(for: .all)
        let m1 = rep.model("antigravity|google-antigravity/gemini-3.8-flash")
        let m2 = rep.model("antigravity|google-antigravity/gemini-3.7-flash")
        let m3 = rep.model("antigravity|google-antigravity/antigravity-model-99")
        check("antigravity own enum names despite order", res.issues.isEmpty && m1?.counts.total == 8 && m2?.counts.total == 16)
        check("antigravity missing enum falls back", m3?.counts.total == 3)
    } catch { check("antigravity own enum names despite order", false); check("antigravity missing enum falls back", false) }

    // A count no call can reach means the fields moved: named, never a crash.
    do {
        let dir = try tempDir()
        let h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let dbp = h + "/.gemini/antigravity-cli/conversations/ag-big.db"
        try runSQL(dbp, "CREATE TABLE gen_metadata(idx INTEGER, data BLOB); CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB);")
        let huge = protoVarint(2 << 3) + [UInt8](repeating: 0xFF, count: 9) + [0x01]
        try insertBlob(dbp, "steps", 0, 15, protoBytes(8, protoInt(1, 1793968800)) + protoBytes(9, protoInt(1, 1) + huge))
        check("impossible antigravity count is named", UsageScanner(store: s, home: h).scan().issues.contains { $0.source == "Antigravity" })
    } catch { check("impossible antigravity count is named", false) }

    // One broken opencode database must not hide the others.
    do {
        let dir = try tempDir()
        let h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try write(HarnessCatalog.customSourcesPath(home: h), #"{"sources":[{"id":"mytool","name":"My Tool","family":"opencode-sqlite","paths":["~/.mytool/sessions"],"keyPrefix":"mt"}]}"#)
        try write(h + "/.local/share/opencode/opencode.db", "not sqlite")
        try makeOC(h + "/.mytool/sessions/a/data/opencode/opencode.db", "mt-alone", 6, 2, 1)
        let result = UsageScanner(store: s, home: h).scan()
        check("broken opencode database leaves the others read", result.issues.contains { $0.source == "opencode" } && s.hasEvents(prefix: "mt:mt-alone"))
    } catch { check("broken opencode database leaves the others read", false) }

    // A database that cannot be opened is an error. Its failed handle must close once:
    // run this binary under libgmalloc to see a second close.
    do {
        let dir = try tempDir()
        var threw = false
        do { _ = try UsageStore(path: dir) } catch { threw = true }
        check("unopenable index throws", threw)
        let h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try FileManager.default.createDirectory(atPath: h + "/.gemini/antigravity-cli/conversations/folder.db", withIntermediateDirectories: true)
        check("unopenable source is named", UsageScanner(store: s, home: h).scan().issues.contains { $0.source == "Antigravity" })
    } catch { check("unopenable source is named", false) }

    // Cost splits always add up to the cost.
    do {
        var ok = true
        for p in Period.allCases { let r = book.report(for: p); if !relEqual(r.parts.total, r.cost) { ok = false } }
        check("parts total equals cost", ok)
    }

    // When every timestamp sits inside the period, the tide carries the whole report.
    do {
        let dir = try tempDir()
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let t0 = 1793970000.0 - 60.0
        try s.insertEvents([
            UsageEvent(key: "cc:t1", provider: "anthropic", model: "claude-opus-5-5", timestamp: t0, tokens: TokenCounts(input: 10, output: 5), session: "s", file: "f"),
            UsageEvent(key: "cx:t2", provider: "openai", model: "gpt-6-luna", timestamp: t0, tokens: TokenCounts(input: 7, output: 3), session: "s", file: "f"),
        ])
        let b = try s.usageBook(now: Date(timeIntervalSince1970: 1793970000))
        var ok = true
        for p in Period.allCases {
            let r = b.report(for: p)
            let tt = (r.tide?.tokens.values.flatMap { $0 }.reduce(Int64(0), +)) ?? -1
            let dd = (r.tide?.dollars.values.flatMap { $0 }.reduce(0.0, +)) ?? -1
            if tt != r.counts.total || !relEqual(dd, r.cost) { ok = false }
        }
        check("tide sums equal report", ok)
    } catch { check("tide sums equal report", false) }

    // A reload must not cut the same calls into different buckets, or the peaks jump.
    do {
        let dir = try tempDir()
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let base = 1793970000.0
        try s.insertEvents((0..<60).map { i in
            UsageEvent(key: "cc:p\(i)", provider: "anthropic", model: "claude-opus-5-5", timestamp: base - 3600 - Double(i) * 977,
                       tokens: TokenCounts(input: 1000 + Int64(i * i) * 13, output: 7), session: "s", file: "f")
        })
        let peaks = try [base, base + 900].map { now in
            let week = try s.usageBook(now: Date(timeIntervalSince1970: now)).report(for: .week)
            return week.tide?.tokens.values.flatMap { $0 }.max() ?? -1
        }
        check("tide peak stays across reloads", peaks[0] == peaks[1] && peaks[0] > 0)
    } catch { check("tide peak stays across reloads: \(error)", false) }

    // Hand-written omp lines: no trap, slash split, escapes, late toolResult.
    var p = SessionParser(sessionID: "s")
    let long = String(repeating: "1234567890", count: 3)
    let truncLine = #"{"timestamp":"2026-11-0","message":{"provider":"a","model":"m","usage":{"input":\#(long),"output":1},"responseId":"trunc-1"}}"#
    let truncEvent = eventForLine(truncLine, parser: &p)
    check("sessionparser trunc and long count no trap", truncEvent != nil && truncEvent!.tokens.input == Int64.max / 4)
    var p2 = SessionParser(sessionID: "s")
    let slashLine = #"{"timestamp":"2026-11-06T10:00:00Z","message":{"model":"a/b/c","usage":{"input":5,"output":2},"responseId":"slash-1"}}"#
    let slashEvent = eventForLine(slashLine, parser: &p2)
    check("sessionparser slash provider split", slashEvent?.provider == "a" && slashEvent?.model == "b/c")
    var p3 = SessionParser(sessionID: "s1")
    let header = #"{"type":"session","id":"s1","cwd":"/tmp/caf\u00e9\/a\"b\\c"}"#
    _ = eventForLine(header, parser: &p3)
    check("sessionparser cwd escapes decoded", p3.currentCwd == "/tmp/caf\u{00E9}/a\"b\\c")
    var pLate = SessionParser(sessionID: "s")
    let base = #"{"timestamp":"2026-11-06T10:00:00Z","message":{"provider":"anthropic","model":"claude-haiku-5-5","usage":{"input":8,"output":4},"responseId":"pad-1"}}"#
    let pad = String(repeating: "x", count: 500)
    let late = base.dropLast() + #","pad":"\#(pad)","role":"toolResult"}"#
    let lateEvent = eventForLine(String(late), parser: &pLate)
    check("sessionparser late toolresult gives no event", lateEvent == nil && String(late).utf8.count > 400)

    // Morphing between pictures interpolates every edge.
    do {
        let d1 = try tempDir(), d2 = try tempDir()
        let s1 = try UsageStore(path: d1 + "/u.sqlite"), s2 = try UsageStore(path: d2 + "/u.sqlite")
        let t0 = 1793970000.0 - 60.0
        // Two harnesses with shares that swap: one ribbon alone fills the column in both pictures.
        func events(_ claude: Int64, _ codex: Int64) -> [UsageEvent] {
            [UsageEvent(key: "cc:a", provider: "anthropic", model: "claude-opus-5-5", timestamp: t0, tokens: TokenCounts(input: claude, output: 20), session: "s", file: "f"),
             UsageEvent(key: "cx:a", provider: "openai", model: "gpt-6-luna", timestamp: t0, tokens: TokenCounts(input: codex, output: 20), session: "s", file: "f")]
        }
        try s1.insertEvents(events(100, 300))
        try s2.insertEvents(events(300, 100))
        func picture(_ store: UsageStore) throws -> RibbonLayout {
            RibbonLayout(report: try store.usageBook(now: now).report(for: .all), width: 800, height: 600,
                         leftColumn: 100, rightColumn: 100, top: 20, bottomMargin: 20)
        }
        let old = try picture(s1), new = try picture(s2)
        func geo(_ r: RibbonLayout.Ribbon) -> [Double] { [r.leftTop, r.leftHeight, r.rightTop, r.rightHeight] + r.leftShares + r.rightShares }
        func same(_ a: RibbonLayout, _ b: RibbonLayout) -> Bool {
            a.ribbons.count == b.ribbons.count && b.ribbons.allSatisfy { r in
                a.ribbons.first { $0.id == r.id }.map { zip(geo($0), geo(r)).allSatisfy { abs($0 - $1) <= 1e-9 } } ?? false
            }
        }
        check("morph test pictures differ", !same(old, new))
        check("morphed progress one is new", same(new.morphed(from: old, progress: 1), new))
        check("morphed progress zero is old", same(new.morphed(from: old, progress: 0), old))
    } catch { check("morphed progress: \(error)", false) }

    // MARK: engine errors (hat A). Each check below failed on the base commit.

    // Cost-state meta is saved with the file's events and offset; a failed commit leaves none of it.
    func costLine(_ session: String, _ start: String, _ input: Int) -> String {
        #"{"type":"cost-state","sessionId":"\#(session)","startTime":"\#(start)","modelUsage":{"claude-opus-5-5":{"inputTokens":\#(input),"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"outputTokens":0}}}"#
    }
    do {
        let dir = try tempDir(), h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try write(h + "/.claude/projects/p/a.jsonl", costLine("sess-b", "2026-11-06T10:00:00.000Z", 10) + "\n")
        try runSQL(s.path, "CREATE TRIGGER refuse_files BEFORE INSERT ON files BEGIN SELECT RAISE(ABORT, 'refused'); END;")
        let refused = UsageScanner(store: s, home: h).scan()
        let leaked = try s.metaRows(prefix: "cc-cost:").count
        check("claude cost meta is written with the file update", !refused.issues.isEmpty && leaked == 0)
        try runSQL(s.path, "DROP TRIGGER refuse_files;")
        _ = UsageScanner(store: s, home: h).scan()
        check("claude cost meta lands once the commit works", (try? s.metaRows(prefix: "cc-cost:").count) == 1)
    } catch { check("claude cost meta is written with the file update: \(error)", false) }

    // Two files of one session in one batch: the second read must see the first one's cost state.
    do {
        let dir = try tempDir(), h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try write(h + "/.claude/projects/p/a.jsonl", costLine("sess-m", "2026-11-06T10:00:00.000Z", 10) + "\n")
        try write(h + "/.claude/projects/p/b.jsonl", costLine("sess-m", "2026-11-06T11:00:00.000Z", 20) + "\n")
        let result = UsageScanner(store: s, home: h).scan()
        let total = try s.usageBook(now: now).report(for: .all).counts.total
        check("claude cost state merges across files of one batch", result.issues.isEmpty && total == 30)
    } catch { check("claude cost state merges across files of one batch: \(error)", false) }

    // A compressed log's offset and byte count are in the file's own units: its size on disk.
    if !zstdUsable { skip("zst scan counts the compressed size", zstdWhy) } else { do {
        let dir = try tempDir(), h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let path = h + "/.codex/archived_sessions/rollout-big.jsonl"
        let rows = (1...300).map { cx($0 * 10, $0 * 8, $0 * 2, "2026-11-06T10:00:00Z") }
        try write(path, codexHead.replacingOccurrences(of: "cx-s", with: "cx-big") + rows.joined(separator: "\n") + "\n")
        try zstdPack(path, keep: false)
        let size = UInt64((try FileManager.default.attributesOfItem(atPath: path + ".zst")[.size] as? NSNumber)?.uint64Value ?? 0)
        let result = UsageScanner(store: s, home: h).scan()
        let record = try s.fileRecords()[path + ".zst"]
        check("zst scan counts the compressed size", size > 0 && result.bytesRead == size && record?.offset == size && record?.size == size)
        check("zst log is not read again", UsageScanner(store: s, home: h).scan().events == 0)
    } catch { check("zst scan counts the compressed size: \(error)", false) } }

    // usage_record.jsonl only feeds the adjustment pass: one walk per scan, not two.
    do {
        let dir = try tempDir(), h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let record = h + "/.qwen/usage_record.jsonl"
        try write(record, #"{"timestamp":"2026-11-06T10:01:00Z","sessionId":"q-x","models":{"m":{"totalTokens":9,"inputTokens":6,"cachedTokens":0,"outputTokens":3,"thoughtsTokens":0}}}"# + "\n")
        let scanner = UsageScanner(store: s, home: h)
        let result = scanner.scan()
        let total = try s.usageBook(now: now).report(for: .all).counts.total
        check("qwen usage_record is walked once per scan", scanner.linePasses[record] == 1 && result.issues.isEmpty && total == 9)
    } catch { check("qwen usage_record is walked once per scan: \(error)", false) }

    // opencode: the stamp keeps main and wal apart (equal sums of mtimes are not equal files).
    do {
        let dir = try tempDir(), h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let db = h + "/.local/share/opencode/opencode.db"
        try makeOC(db, "st-1", 5, 1, 0)
        func stamp(_ main: Int, _ wal: Int) throws {
            try write(db + "-wal", "")
            for (path, seconds) in [(db, main), (db + "-wal", wal)] {
                var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
                guard utimes(path, &times) == 0 else { throw NSError(domain: "utimes", code: Int(errno)) }
            }
        }
        try stamp(1_800_000_100, 1_800_000_200)
        let scanner = UsageScanner(store: s, home: h)
        _ = scanner.scan()
        let json = #"{"role":"assistant","providerID":"openrouter","modelID":"gpt-6-luna","tokens":{"input":5,"output":2,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1793968801}}"#
        try runSQL(db, "INSERT INTO message VALUES('st-2','s','\(json)',1793968801);")
        try stamp(1_800_000_200, 1_800_000_100)
        _ = scanner.scan()
        check("opencode stamp tells apart mtimes with the same sum", s.hasEvents(prefix: "oc:st-1") && s.hasEvents(prefix: "oc:st-2"))
    } catch { check("opencode stamp tells apart mtimes with the same sum: \(error)", false) }

    // A database path with URI-special characters still opens.
    do {
        let dir = try tempDir(), h = dir + "/odd?#%41 home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try makeOC(h + "/.local/share/opencode/opencode.db", "odd-1", 5, 1, 0)
        let result = UsageScanner(store: s, home: h).scan()
        check("opencode database path with ? # % opens", result.issues.isEmpty && s.hasEvents(prefix: "oc:odd-1"))
    } catch { check("opencode database path with ? # % opens: \(error)", false) }

    // Traps and layout edges, each in a child process.
    do {
        let overflow = probe("total-overflow")
        check("token total survives huge and negative counts", overflow.status == 0
              && overflow.out.contains("huge=true sum=true negative=50"))
        let dir = try tempDir()
        let empty = probe("empty-group", dir: dir)
        check("group without stats has a main harness", empty.status == 0 && empty.out.contains("harness="))
        let edges = probe("tide-edges", dir: try tempDir())
        check("tide with one bucket stays finite", edges.status == 0 && edges.out.contains("one-bucket=true"))
        check("tide at zero width stays finite", edges.status == 0 && edges.out.contains("zero-width=true"))
        check("tide without buckets draws nothing", edges.status == 0 && edges.out.contains("no-bucket=true"))
        let bucket = probe("tide-bucket", dir: try tempDir())
        check("tide bucket lookup survives NaN and infinity", bucket.status == 0 && bucket.out.contains("bucket=true true true true"))
    } catch { check("probe setup: \(error)", false) }

    // Without a zstd binary: one named issue per scan, the archives left for later, the rest still read.
    if zstdPacker == nil { skip("missing zstd is one named issue per scan", zstdWhy + " to pack the archives") } else { do {
        let missing = probe("zstd-missing", dir: try tempDir(), env: ["TOKENBAR_ZSTD": "none"])
        check("missing zstd is one named issue per scan", missing.status == 0 && missing.out.contains("first=1 second=1")
              && missing.out.contains("brew install zstd"))
        check("missing zstd leaves the archives unrecorded and the plain log read", missing.out.contains("recorded=0")
              && missing.out.contains("events=1"))
    } catch { check("missing zstd probe: \(error)", false) } }

    // Claude Code appends a context suffix (`[1m]`) to the model in transcripts and in cost-state:
    // both name one model, so the gap between them is the real gap and nothing counts twice.
    do {
        let dir = try tempDir(), h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try write(h + "/.claude/projects/demo/session.jsonl", [c1, c2, synthetic, costState].joined(separator: "\n") + "\n")
        let result = UsageScanner(store: s, home: h, environment: [:]).scan()
        let report = try s.usageBook(now: now).report(for: .all)
        let opus = report.model("claude-code|anthropic/claude-opus-5-5")
        check("claude [1m] suffix is stripped from the transcript model", result.issues.isEmpty && opus?.counts.total == 190
              && report.model("claude-code|anthropic/claude-opus-5-5[1m]") == nil)
        check("claude [1m] transcript rows and cost-state are not counted twice", report.counts.total == 196 && report.callCount == 2)
    } catch { check("claude [1m] suffix: \(error)", false) }

    // MARK: open harness catalog (hat A)

    // The ten names and prefixes of the closed enum survive; anything else comes from the user's custom-sources.json.
    do {
        let known: [(String, String, String)] = [("cc", "claude-code", "Claude Code"), ("cx", "codex", "Codex"), ("oc", "opencode", "opencode"),
            ("od", "open-design", "Open Design"), ("omp", "oh-my-pi", "oh-my-pi"),
            ("qwen", "qwen-code", "Qwen Code"), ("kimi", "kimi-code", "Kimi Code"), ("devin", "devin", "Devin"),
            ("ag", "antigravity", "Antigravity")]
        let resolved = known.map { prefix, _, _ in HarnessID(keyPrefix: Substring(prefix)) }
        check("catalog keeps every key prefix and name", zip(known, resolved).allSatisfy { $0.1?.rawValue == $0.0.1 && $0.1?.name == $0.0.2 })
        let stranger = HarnessID(keyPrefix: "zz-unlisted")
        check("a prefix nobody claims is still a harness", stranger?.rawValue == "zz-unlisted" && stranger?.name == "zz-unlisted"
              && HarnessID(keyPrefix: "") == nil)
        let hues: [(HarnessID, Double)] = [(.claudeCode, 21), (.codex, 158), (.opencode, 224), (.openDesign, 325), (.ohMyPi, 270),
                                           (.qwenCode, 195), (.kimiCode, 46), (.devin, 88), (.antigravity, 352)]
        check("known tools keep their colours", hues.allSatisfy { $0.0.hue == $0.1 })
        check("unknown tool gets a stable FNV-1a hue", HarnessID.stableHue("a") == 340 && HarnessID.stableHue("alpha") == 107
              && HarnessID.stableHue("beta") == 191 && HarnessID("neverlisted").hue == 172 && HarnessID("neverlisted").hue == HarnessID("neverlisted").hue)
        let strangerDir = try tempDir()
        let s = try UsageStore(path: strangerDir + "/usage.sqlite")
        try s.insertEvents([probeEvent("qq-stranger:1")])
        let report = try s.usageBook(now: now).report(for: .all)
        check("history under an unlisted prefix stays in the report", report.harnesses.map(\.harness.rawValue) == ["qq-stranger"] && report.counts.total == 15)
    } catch { check("catalog names: \(error)", false) }

    // The user's file: good entries join, bad ones are named and skipped, the file itself may be junk.
    do {
        let h = try tempDir()
        func catalog(_ json: String) throws -> HarnessCatalog {
            try write(HarnessCatalog.customSourcesPath(home: h), json)
            return HarnessCatalog.load(home: h, environment: [:])
        }
        let good = try catalog(#"{"sources":[{"id":"mytool","name":"My Tool","family":"open-design-events","paths":["~/m.jsonl"],"keyPrefix":"mt","hue":400}]}"#)
        check("custom source joins the catalog", good.issues.isEmpty && good.descriptors.count == HarnessCatalog.builtin.count + 1
              && good.descriptors.last?.name == "My Tool" && good.descriptors.last?.keyPrefixes == ["mt"] && good.descriptors.last?.hue == 40
              && good.rootPaths(of: good.descriptors.last!) == [h + "/m.jsonl"])
        let bad = try catalog(#"{"sources":[{"id":"a","family":"nope","paths":["/x"]},{"id":"b","family":"open-design-events","paths":["/x"],"keyPrefix":"cc"},"#
                              + #"{"id":"c","family":"anthropic-jsonl","paths":["/x"],"keyPrefix":"xx"},{"id":"d","family":"open-design-events","paths":[]},"#
                              + #"{"id":"e","family":"open-design-events","paths":["/x"],"keyPrefix":"Bad:Prefix"},{"family":"open-design-events","paths":["/x"]},"#
                              + #"{"id":"fine","family":"open-design-events","paths":["/x"]}]}"#)
        check("bad custom entries are named and skipped", bad.issues.count == 6 && bad.descriptors.count == HarnessCatalog.builtin.count + 1
              && bad.descriptors.last?.id.rawValue == "fine" && bad.descriptors.last?.keyPrefixes == ["fine"]
              && bad.issues.contains { $0.message.contains("bilinmeyen aile") })
        let junk = try catalog("not json")
        check("junk custom file is one issue and the built-ins stay", junk.issues.count == 1 && junk.descriptors.count == HarnessCatalog.builtin.count)
        let noList = try catalog(#"{"other":1}"#)
        check("custom file without sources is one issue", noList.issues.count == 1)
        try FileManager.default.removeItem(atPath: HarnessCatalog.customSourcesPath(home: h))
        check("no custom file is not an issue", HarnessCatalog.load(home: h, environment: [:]).issues.isEmpty)
    } catch { check("custom source file: \(error)", false) }

    // A source with its own prefix and name shows up as its own harness.
    do {
        let h = try tempDir() + "/home", dir = (h as NSString).deletingLastPathComponent
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try write(HarnessCatalog.customSourcesPath(home: h), #"{"sources":[{"id":"mytool","name":"My Tool","family":"open-design-events","paths":["~/m"],"keyPrefix":"mt"}]}"#)
        try write(h + "/m/run-1/events.jsonl", #"{"timestamp":"2026-11-06T10:00:00Z","data":{"type":"status","model":"claude-opus-5-5"}}"# + "\n"
            + #"{"timestamp":"2026-11-06T10:01:00Z","data":{"type":"request_usage","requestId":"mt-1","usage":{"input_tokens":4,"output_tokens":1}}}"# + "\n")
        let result = UsageScanner(store: s, home: h, environment: [:]).scan()
        let report = try s.usageBook(now: now).report(for: .all)
        check("custom source reads under its own prefix and name", result.issues.isEmpty && s.hasEvents(prefix: "mt:")
              && report.harnesses.first?.harness.rawValue == "mytool" && report.harnesses.first?.harness.name == "My Tool")
    } catch { check("custom source reads under its own prefix and name: \(error)", false) }

    // Tool folders can move: the four variables, `~/` allowed, and only the real home follows them.
    do {
        let dir = try tempDir(), h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        let claudeLine = #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"env-s","requestId":"r","message":{"id":"m-env","model":"claude-opus-5-5","usage":{"input_tokens":3,"output_tokens":2}}}"#
        try write(h + "/moved-claude/projects/p/s.jsonl", claudeLine + "\n")
        try write(h + "/.claude/projects/p/ignored.jsonl", claudeLine.replacingOccurrences(of: "m-env", with: "m-default") + "\n")
        try write(h + "/moved-codex/sessions/rollout-env.jsonl", codexHead.replacingOccurrences(of: "cx-s", with: "cx-env") + cx(30, 20, 10, ts) + "\n")
        try makeOC(h + "/xdg/opencode/opencode.db", "env-oc", 5, 1, 0)
        try write(h + "/moved-qwen/usage/token-usage-2026-11.jsonl", #"{"id":"qe","timestamp":"2026-11-06T10:00:00Z","sessionId":"q-e","model":"m","authType":"qwen","inputTokens":4,"cachedTokens":0,"outputTokens":1,"thoughtsTokens":0}"# + "\n")
        let env = ["CLAUDE_CONFIG_DIR": h + "/moved-claude", "CODEX_HOME": "~/moved-codex", "XDG_DATA_HOME": h + "/xdg", "QWEN_HOME": h + "/moved-qwen/"]
        let result = UsageScanner(store: s, home: h, environment: env).scan()
        check("CLAUDE_CONFIG_DIR moves Claude Code", s.hasEvents(prefix: "cc:m-env") && !s.hasEvents(prefix: "cc:m-default"))
        check("CODEX_HOME moves Codex, with ~/", s.hasEvents(prefix: "cx:cx-env"))
        check("XDG_DATA_HOME moves opencode", s.hasEvents(prefix: "oc:env-oc"))
        check("QWEN_HOME moves Qwen Code", s.hasEvents(prefix: "qwen:qe") && result.issues.isEmpty)
        check("environment applies to the real home only", HarnessCatalog.defaultEnvironment(home: h).isEmpty
              && HarnessCatalog.defaultEnvironment(home: NSHomeDirectory()) == ProcessInfo.processInfo.environment)
    } catch { check("environment variables: \(error)", false) }

    // Detection is "the tool's folder exists", reported with the scan.
    do {
        let dir = try tempDir(), h = dir + "/home"
        let s = try UsageStore(path: dir + "/usage.sqlite")
        try FileManager.default.createDirectory(atPath: h + "/.claude", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: h + "/.qwen", withIntermediateDirectories: true)
        try write(HarnessCatalog.customSourcesPath(home: h), #"{"sources":[{"id":"mytool","family":"open-design-events","paths":["~/m.jsonl"],"keyPrefix":"mt"}]}"#)
        let scanner = UsageScanner(store: s, home: h, environment: [:])
        check("detection lists the tools whose folder exists", scanner.scan().detected == [.claudeCode, .qwenCode])
        try FileManager.default.createDirectory(atPath: h + "/.codex", withIntermediateDirectories: true)
        try write(h + "/m.jsonl", "")
        check("a tool installed later is detected by the next scan", scanner.scan().detected == [.claudeCode, .codex, .qwenCode, HarnessID("mytool")])
    } catch { check("detection: \(error)", false) }

    // Watch folders come from the catalog, and a folder that is not there yet is waited for from above.
    do {
        let h = try tempDir() + "/home"
        try write(HarnessCatalog.customSourcesPath(home: h), customSourcesJSON)
        let paths = UsageScanner.watchPaths(home: h, environment: [:]).filter { !G1.watchPaths(home: h).contains($0) }
        let wanted = [".claude/projects", ".codex/sessions", ".codex/archived_sessions", ".local/share/opencode",
                      "Library/Application Support/Open Design/namespaces/release-stable/data/runs", ".omp/agent/sessions", ".qwen",
                      ".kimi-code/sessions", ".local/share/devin/cli/transcripts", ".gemini/antigravity-cli/conversations"]
                      + g3WatchedPaths
        let wantedAll = wanted + g2WatchPathsWanted()
        check("watch paths are the ones the closed list had", Set(paths) == Set(wantedAll.map { h + "/" + $0 }) && paths.count == wantedAll.count)
        try FileManager.default.createDirectory(atPath: h + "/.local/share", withIntermediateDirectories: true)
        check("a missing folder is waited for from its nearest existing parent",
              WatchPlan.waitingOn([h + "/.local/share/devin/cli/transcripts", h + "/.local/share/missing-tool", h + "/.kimi-code/sessions"])
                  == [WatchPlan.canonical(h + "/.local/share"), WatchPlan.canonical(h)]
              && WatchPlan.existing([h + "/.local/share", h + "/.local/share/devin"]) == [WatchPlan.canonical(h + "/.local/share")])
        check("the volume root is never waited on", WatchPlan.waitingOn(["/nonexistent-root-folder/x"]).isEmpty)
    } catch { check("watch plan: \(error)", false) }

    let awkward = [UsageText.fittedFontSize(11, room: -20, width: 50), UsageText.fittedFontSize(11, room: 0, width: 50),
                   UsageText.fittedFontSize(11, room: 10, width: 0), UsageText.fittedFontSize(11, room: .nan, width: 50),
                   UsageText.fittedFontSize(.nan, room: 10, width: 50), UsageText.fittedFontSize(-3, room: 10, width: 50)]
    check("label font never goes negative or NaN", awkward.allSatisfy { $0.isFinite && $0 >= 1 })
    check("label font shrinks to fit and stays when it fits", UsageText.fittedFontSize(11, room: 100, width: 50) == 11
          && UsageText.fittedFontSize(10, room: 40, width: 50) == 8 && UsageText.fittedFontSize(11, room: -20, width: 50) == 6)
    l10nChecks()
    priceChecks()
    displayNameChecks()
    PriceBook.install(catalogs: .embedded)

    do { try runG3Checks(home: home) } catch { check("G3 checks: \(error)", false) }

    G1.run(home: home, scratch: tempDir)

    try g2Checks(home: home, tempDir: tempDir)

    try saglamlikChecks(tempDir: tempDir)

    try argonChecks(tempDir: tempDir)

    try fix901bPriceChecks(tempDir: tempDir)
    try fix901Checks(tempDir: tempDir)
    try fix901bDataChecks(tempDir: tempDir)
    try fix902Checks(tempDir: tempDir)
    try fix903Checks(tempDir: tempDir)
    try fix904Checks(tempDir: tempDir)
    try fix905Checks(tempDir: tempDir)
    try fix906Checks(tempDir: tempDir)
    try fix907Checks(tempDir: tempDir)

    if !skipped.isEmpty { print("\(skipped.count) check(s) skipped, not run: \(skipped.joined(separator: "; "))") }
    if failures == 0 { print("ALL CHECKS PASS") } else { print("\(failures) FAILED") }
    exit(failures == 0 ? 0 : 1)
} catch {
    fputs("FATAL: \(error)\n", stderr)
    print("\(failures + 1) FAILED")
    exit(1)
}
