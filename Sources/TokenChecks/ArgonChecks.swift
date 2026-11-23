import Foundation
import SQLite3
import LocalCore

// Checks for the findings of the last independent review (Argon, before 9.0.0). Each case builds a small home and scans
// it in a child process (see SaglamlikChecks.swift: `scan(dir)` scans DIR/home into DIR/usage.sqlite). A case that scans
// twice changes the files between the two runs. Called once from `main.swift`; `argonProbe` is the child's side for the
// cases that need more than a scan.
//
//   1  a WAL database is never opened in place: a -wal beside the .db is enough, even next to a 0-byte .db
//   2  a hand-written price meets the catalogue bound; the CLI's JSON never holds Infinity or NaN
//   3  Claude [1m]: one counter per spelling in a run, folded and summed per model
//   4  Cline/Roo/Kilo checkpoint restore does not count the dropped calls twice
//   5  a recreated opencode/kilo database is read from its first row
//   6  Zed: one pass over threads.db + -wal; an emptied thread loses its adjustment row
//   7  zstd is optional for the build and the checks (documented)
//   9  the Python twins agree: price names, Copilot snapshots
//   10 --home reads that home's model-aliases.json
//   11 UISnapshot selfcheck pins the prices itself
//   13 the oracles read a WAL database from a copy

private let appSupport = "/Library/Application Support"
private let codeUser = appSupport + "/Code/User"
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
private let binaryFolder = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()

/// The child's side of the cases that need more than `saglam-scan`.
func argonProbe(_ name: String, dir: String) -> String? {
    switch name {
    case "argon-home-alias":
        // Prices of this home only: DIR/home/.config/tokenbar/model-aliases.json. TokenChecks pins the prices at its start
        // (every run of it, this child too); a pinned run reads no alias file, so this case takes the pin off again.
        setenv("TOKENBAR_PRICES_PINNED", "0", 1)
        PriceBook.useHome(dir + "/home")
        guard let store = try? UsageStore(path: dir + "/usage.sqlite") else { return "store error" }
        let result = UsageScanner(store: store, home: dir + "/home", environment: [:]).scan()
        guard let report = try? store.usageBook(now: Date(timeIntervalSince1970: 1793970000)).report(for: .all) else { return "report error" }
        let json = (try? ReportJSON.serialize(ReportJSON.object(report, window: .all, detected: []))).map { _ in "ok" } ?? "refused"
        let kinds = report.harnesses.flatMap(\.models).map { "\($0.info.price.entry?.kind == .alias)" }.sorted().joined(separator: ",")
        return "cost=\(report.cost) finite=\(report.cost.isFinite) json=\(json) alias=\(kinds) issues=\(result.issues.count)"
    default:
        return nil
    }
}

private func claudeRow(_ id: String, model: String, input: Int, session: String = "s1") -> String {
    #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"\#(session)","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
}

private func listing(_ folder: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() }

private func inode(_ path: String) -> UInt64? {
    var st = Darwin.stat()
    return stat(path, &st) == 0 ? UInt64(st.st_ino) : nil
}

/// `python3 scripts/oracle.py all` over `home`: harness -> (total, calls); nil when python3 or the answer is missing.
private func oracleTotals(home: String) -> [String: (Int64, Int)]? {
    let script = repoRoot + "/scripts/oracle.py"
    guard FileManager.default.fileExists(atPath: script) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script, "all"]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home
    environment["TOKENBAR_PRICES_PINNED"] = "1"
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

/// Runs a built tool of this checkout that sits beside TokenChecks; nil when it is not built.
private func runTool(_ name: String, _ arguments: [String], environment: [String: String], remove: [String] = []) -> (status: Int32, out: String, err: String)? {
    let path = binaryFolder.appendingPathComponent(name).path
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    for key in remove { env[key] = nil }
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return nil }
    // stderr is small; stdout is read to the end first, which is what ends the child.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
}

func argonChecks(tempDir: () throws -> String) throws {
    func fresh() throws -> (dir: String, home: String) {
        let dir = try tempDir()
        try FileManager.default.createDirectory(atPath: dir + "/home", withIntermediateDirectories: true)
        return (dir, dir + "/home")
    }
    let ocSchema = "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT);"
    func ocMessage(input: Int, output: Int) -> String {
        #"{"role":"assistant","providerID":"openrouter","modelID":"gpt-6-luna","tokens":{"input":\#(input),"output":\#(output),"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1793968800}}"#
    }
    /// A database in WAL mode as a tool that died would leave it: the `.db` (header page only) and the `-wal`, no `-shm`.
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

    // MARK: 1  a -wal beside the .db always means a copy

    do {
        // The first checkpoint has not happened: the .db is 0 bytes and the rows are only in the -wal. SQLite opens a
        // 0-byte file in place and deletes its -wal: the user's file, with rows in it.
        let (dir, h) = try fresh()
        let folder = h + "/.local/share/opencode"
        try writeWALDatabase(folder + "/opencode.db", ocSchema + "INSERT INTO message VALUES('m','s','\(ocMessage(input: 7, output: 3))',1);")
        try Data().write(to: URL(fileURLWithPath: folder + "/opencode.db"))
        let wal = try Data(contentsOf: URL(fileURLWithPath: folder + "/opencode.db-wal"))
        let before = listing(folder)
        let r = scan(dir)
        let kept = (try? Data(contentsOf: URL(fileURLWithPath: folder + "/opencode.db-wal"))) == wal
        check("argon 1: a 0-byte .db beside a -wal leaves the user's -wal in place", r.status == 0 && kept && listing(folder) == before)
        check("argon 1: ... and the 0-byte .db is still 0 bytes", ((try? FileManager.default.attributesOfItem(atPath: folder + "/opencode.db")[.size]) as? NSNumber)?.intValue == 0)
    } catch { check("argon 1 0-byte: \(error)", false) }

    do {
        // A header that claims rollback mode (bytes 18 and 19 are 1) with a -wal beside it: no -shm may appear.
        let (dir, h) = try fresh()
        let folder = h + "/.local/share/opencode"
        try writeWALDatabase(folder + "/opencode.db", ocSchema + "INSERT INTO message VALUES('m','s','\(ocMessage(input: 7, output: 3))',1);")
        let file = try FileHandle(forUpdating: URL(fileURLWithPath: folder + "/opencode.db"))
        try file.seek(toOffset: 18)
        try file.write(contentsOf: Data([1, 1]))
        try file.close()
        let before = listing(folder)
        let r = scan(dir)
        check("argon 1: a header of [1,1] beside a -wal makes no -shm", r.status == 0 && listing(folder) == before)
    } catch { check("argon 1 header: \(error)", false) }

    // MARK: 2  hand-written prices are bounded; the JSON never holds Infinity

    do {
        let hostile = UserAliases(json: Data(#"""
        {"aliases": {"huge": {"input": 1e308, "output": 1e308}, "over": {"input": 1000001, "output": 1},
                     "neg-cache": {"input": 1, "output": 1, "cacheRead": -1}, "huge-cache": {"input": 1, "output": 1, "cacheWrite": 1e300},
                     "edge": {"input": 1000000, "output": 1000000, "cacheRead": 0}, "fine": {"input": 1, "output": 2}}}
        """#.utf8))
        check("argon 2: an alias price above the bound or with a negative cache price is dropped, the rest stay",
              Set(hostile.targets.keys) == ["edge", "fine"])
        PriceBook.install(catalogs: .embedded, aliases: UserAliases(json: Data(#"{"aliases": {"claude-opus-5-5": {"input": 1e308, "output": 1e308}}}"#.utf8)))
        let price = ModelPrice(model: "claude-opus-5-5")
        let cost = price.cost(TokenCounts(input: 2_000_000, cacheRead: 0, cacheWrite: 0, output: 2_000_000))
        check("argon 2: an alias of 1e308 never reaches a cost (the catalogue prices the model)", cost.isFinite && cost > 0 && price.entry?.kind != .alias)
        PriceBook.install(catalogs: .embedded)
    }

    check("argon 2: a money figure that is not finite is 0 in the JSON", ReportJSON.finite(.infinity) == 0 && ReportJSON.finite(-.infinity) == 0
          && ReportJSON.finite(.nan) == 0 && ReportJSON.finite(1.5) == 1.5)
    do {
        let refused = (try? ReportJSON.serialize(["cost": Double.infinity])) == nil
        let nan = (try? ReportJSON.serialize(["nested": ["cost": Double.nan]])) == nil
        let ok = (try? ReportJSON.serialize(["cost": 1.5, "total": Int64(3)])).map { String(decoding: $0, as: UTF8.self).contains("1.5") } ?? false
        check("argon 2: a report that holds Infinity or NaN is refused with an error, not an abort; a good one is written", refused && nan && ok)
    }

    do {
        let (dir, h) = try fresh()
        try write(h + "/.config/tokenbar/model-aliases.json", #"{"aliases": {"my-x": {"input": 1e308, "output": 1e308}}}"#)
        try write(h + "/.claude/projects/p/s.jsonl", claudeRow("m1", model: "my-x", input: 1_000_000) + "\n")
        // The home is the process's own home as well (HOME), the way the app reads it: the old code read only that one.
        let own = ["HOME": h, "CFFIXED_USER_HOME": h]
        let r = probe("argon-home-alias", dir: dir, env: own)
        check("argon 2: an alias of 1e308 in a home leaves the cost finite and the report JSON writable",
              r.status == 0 && r.out.contains("finite=true") && r.out.contains("json=ok") && r.out.contains("alias=false") && r.out.contains("cost=0.0"))
        if let cli = runTool("tokenbar-cli", ["--home", h, "--db", dir + "/cli.sqlite", "--rebuild", "--window", "all", "--json"], environment: own.merging(["TOKENBAR_PRICES_PINNED": "0"]) { $1 }) {
            check("argon 2: tokenbar-cli --json survives an alias of 1e308 (no abort)", cli.status == 0 && (try? JSONSerialization.jsonObject(with: Data(cli.out.utf8))) != nil)
        } else {
            skip("argon 2: tokenbar-cli --json survives an alias of 1e308", "tokenbar-cli is not built beside TokenChecks (swift build -c release)")
        }
    } catch { check("argon 2 home: \(error)", false) }

    // MARK: 3  Claude [1m]

    do {
        // One run, two spellings: `[1m]` is in the transcript (100), the plain name only in cost-state (80). 100 + 80.
        let (dir, h) = try fresh()
        let state = #"{"type":"cost-state","sessionId":"s1","startTime":"2026-11-06T10:00:00.000Z","modelUsage":{"claude-opus-5-5[1m]":{"inputTokens":100},"claude-opus-5-5":{"inputTokens":80}}}"#
        try write(h + "/.claude/projects/p/s.jsonl", [claudeRow("m1", model: "claude-opus-5-5[1m]", input: 100), state].joined(separator: "\n") + "\n")
        let r = scan(dir)
        check("argon 3a: two spellings of one model in one run add up (100 + 80), not max", r.ok && r.total("claude-code") == 180)
    } catch { check("argon 3a: \(error)", false) }

    do {
        // A copy saved before the suffix was dropped: its `[1m]` key must meet the transcript's plain name.
        let (dir, h) = try fresh()
        try write(h + "/.claude/projects/p/s.jsonl", claudeRow("m1", model: "claude-opus-5-5", input: 100) + "\n")
        try write(dir + "/meta.json", #"{"cc-cost:s1": "{\"runs\":{\"1793968800\":{\"claude-opus-5-5[1m]\":[100,0,0,0]}}}"}"#)
        let r = scan(dir)
        check("argon 3b: an old cc-cost copy with a [1m] key is folded into the model: 100, not 200", r.ok && r.total("claude-code") == 100)
    } catch { check("argon 3b: \(error)", false) }

    do {
        // A log whose date is in the future (a wrong clock, an unpacked archive) is as quiet as an old one: its last line,
        // written without a newline, is read.
        let (dir, h) = try fresh()
        let path = h + "/.claude/projects/p/s.jsonl"
        try write(path, claudeRow("m1", model: "claude-opus-5-5", input: 100))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(7200)], ofItemAtPath: path)
        let r = scan(dir)
        check("argon 3c: a log dated in the future has its last line, without a newline, counted: 100", r.ok && r.total("claude-code") == 100)
    } catch { check("argon 3c: \(error)", false) }

    // MARK: 4  checkpoint restore

    do {
        func api(_ ts: String, _ input: Int, _ output: Int) -> String { clineRow(#"{"tokensIn":\#(input),"tokensOut":\#(output)}"#, ts: ts, model: "m") }
        func deleted(_ ts: String, _ input: Int, _ output: Int) -> String {
            #"{"type":"say","say":"deleted_api_reqs","ts":\#(ts),"text":"{\"tokensIn\":\#(input),\"tokensOut\":\#(output)}"}"#
        }
        for (label, tasks, harness) in [("cline", clineTasks, "cline"), ("roo", rooTasks, "roo-code")] {
            let (dir, h) = try fresh()
            let path = h + tasks + "/t1/ui_messages.json"
            try write(h + tasks + "/t2/ui_messages.json", "[" + api("1793968800000", 10, 5) + "]")
            try write(path, "[" + [api("1793968800000", 100, 20), api("1793968860000", 200, 50)].joined(separator: ",") + "]")
            let first = scan(dir)
            // The user goes back to a checkpoint: the second call is dropped and its usage folded into a deleted_api_reqs row.
            try write(path, "[" + [api("1793968800000", 100, 20), deleted("1793968900000", 200, 50)].joined(separator: ",") + "]")
            let second = scan(dir)
            check("argon 4: \(label): a checkpoint restore keeps the total (370 + the other task's 15), nothing counted twice",
                  first.ok && first.total(harness) == 385 && second.ok && second.total(harness) == 385)
            // The task goes on after the restore: the new call adds, the others stay.
            try write(path, "[" + [api("1793968800000", 100, 20), deleted("1793968900000", 200, 50), api("1793969000000", 1, 1)].joined(separator: ",") + "]")
            let third = scan(dir)
            check("argon 4: \(label): a call made after the restore is added", third.ok && third.total(harness) == 387)
        }
    } catch { check("argon 4: \(error)", false) }

    // MARK: 5  a recreated opencode database

    do {
        func make(_ path: String, _ rows: [(rowid: Int, input: Int)]) throws {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            let values = rows.map { "(\($0.rowid),'m\($0.rowid)','s','\(ocMessage(input: $0.input, output: 0))',1)" }.joined(separator: ",")
            try runSQL(path, ocSchema + "INSERT INTO message(rowid, id, session_id, data, time_created) VALUES " + values + ";")
        }
        let (dir, h) = try fresh()
        let db = h + "/.local/share/opencode/opencode.db"
        try make(db, [(5000, 15)])
        let first = scan(dir)
        let oldInode = inode(db)
        try make(db, [(1, 100)])
        let second = scan(dir)
        check("argon 5a: a database made again with rowids below the old watermark is read from its first row (15 + 100)",
              first.ok && first.total("opencode") == 15 && second.ok && second.total("opencode") == 115)

        // Higher rowids than the watermark minus the overlap, but another file: its early rows must not be skipped.
        let (dir2, h2) = try fresh()
        let db2 = h2 + "/.local/share/opencode/opencode.db"
        try make(db2, [(5000, 15)])
        let seen = scan(dir2)
        let oldInode2 = inode(db2)
        try make(db2, [(10, 100), (6000, 1)])
        let again = scan(dir2)
        if oldInode2 != nil, oldInode2 == inode(db2) || oldInode == inode(db) && false {
            skip("argon 5b: a database made again keeps its rows from below the watermark", "the new file got the old inode number")
        } else {
            check("argon 5b: another file under the same name is read in full even when its newest rowid is higher (15 + 100 + 1)",
                  seen.ok && seen.total("opencode") == 15 && again.ok && again.total("opencode") == 116)
        }
    } catch { check("argon 5: \(error)", false) }

    // MARK: 6  Zed

    let zedSchema = "CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL, data BLOB NOT NULL, created_at TEXT);"
    func zedJSON(_ requests: String, cumulative: Int, imported: Bool = false) -> String {
        #"{"model":{"provider":"zed.dev","model":"claude-sonnet-4-5"},"imported":\#(imported),"request_token_usage":\#(requests),"cumulative_token_usage":{"input_tokens":\#(cumulative),"output_tokens":0}}"#
    }
    do {
        // threads.db and threads.db-wal are one database: one read, so one issue for the one thread nobody can read.
        let (dir, h) = try fresh()
        let folder = h + appSupport + "/Zed/threads"
        let good = zedJSON(#"{"a":{"input_tokens":500}}"#, cumulative: 500)
        try writeWALDatabase(folder + "/threads.db", zedSchema
                             + "INSERT INTO threads VALUES('t1','t','2026-11-06T10:00:00Z','json', CAST('\(good)' AS BLOB), NULL);"
                             + "INSERT INTO threads VALUES('t2','t','2026-11-06T10:01:00Z','lz4', x'7878', NULL);")
        let r = scan(dir)
        check("argon 6a: threads.db and its -wal are one read: the unreadable thread is named once, the rest counts", r.status == 0 && r.issues == 1 && r.total("zed") == 500)
    } catch { check("argon 6a: \(error)", false) }

    do {
        for (label, update) in [("a thread that was emptied", zedJSON("{}", cumulative: 0)),
                                ("a thread that became imported", zedJSON("{}", cumulative: 1000, imported: true))] {
            let (dir, h) = try fresh()
            let db = h + appSupport + "/Zed/threads/threads.db"
            try runSQL(db, zedSchema + "INSERT INTO threads VALUES('t','t','2026-11-06T10:00:00Z','json', CAST('\(zedJSON("{}", cumulative: 1000))' AS BLOB), NULL);")
            let first = scan(dir)
            try runSQL(db, "UPDATE threads SET updated_at='2026-11-06T10:05:00Z', data=CAST('\(update)' AS BLOB) WHERE id='t';")
            let second = scan(dir)
            check("argon 6b: \(label) loses its adjustment row (1000 -> nothing)", first.ok && first.total("zed") == 1000 && second.ok && (second.total("zed") ?? 0) == 0)
        }
    } catch { check("argon 6b: \(error)", false) }

    // MARK: 7  zstd is optional and documented

    do {
        let readme = (try? String(contentsOfFile: repoRoot + "/README.md", encoding: .utf8)) ?? ""
        let readmeTr = (try? String(contentsOfFile: repoRoot + "/README.tr.md", encoding: .utf8)) ?? ""
        let ci = (try? String(contentsOfFile: repoRoot + "/.github/workflows/ci.yml", encoding: .utf8)) ?? ""
        let note = "brew install zstd` (optional, for zstd-compressed logs)"
        if readme.isEmpty { skip("argon 7: README and CI name zstd", "the repository files are not beside the binary") } else {
            check("argon 7: both READMEs say zstd is optional and what it is for, and CI installs it",
                  readme.contains(note) && readmeTr.contains("optional, for zstd-compressed logs") && ci.contains("brew install zstd"))
        }
    }

    // MARK: 9  the Python twins

    do {
        let script = repoRoot + "/scripts/price-parity.py"
        if !FileManager.default.fileExists(atPath: script) {
            skip("argon 9: pricelib.py names every model as the Swift rules do", "scripts/price-parity.py is not beside the binary")
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script, "--swift", binaryFolder.appendingPathComponent("TokenChecks").path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            check("argon 9: price-parity.py finds no difference between pricelib.py and the Swift price rules (names included)",
                  process.terminationStatus == 0 && text.contains(", 0 different"))
        }
    } catch { check("argon 9 parity: \(error)", false) }

    do {
        // Two `kind: 0` snapshots in one Copilot Chat session with different requests: the second replaces the first's
        // (10 tokens), in the scanner and in the oracle (which used to append: 16).
        let (dir, h) = try fresh()
        func snapshot(_ prompt: Int, _ time: Int64) -> String {
            #"{"kind":0,"v":{"requests":[{"promptTokens":\#(prompt),"completionTokens":1,"timestamp":\#(time),"modelId":"copilot/gpt-6-luna"}]}}"#
        }
        try write(h + codeUser + "/workspaceStorage/h/chatSessions/s.jsonl", snapshot(5, 1793968800000) + "\n" + snapshot(9, 1793968900000) + "\n")
        let r = scan(dir)
        if let oracle = oracleTotals(home: h) {
            check("argon 9: oracle_g2.py replaces the requests at a second snapshot, as the scanner does (10 and 10)",
                  r.ok && r.total("copilot-chat") == 10 && oracle["copilot-chat"]?.0 == 10 && oracle["copilot-chat"]?.1 == 1)
        } else {
            skip("argon 9: oracle_g2.py replaces the requests at a second snapshot", "python3 or scripts/oracle.py is not available")
        }
    } catch { check("argon 9 snapshot: \(error)", false) }

    // MARK: 10  --home reads that home's aliases

    do {
        let (dir, h) = try fresh()
        try write(h + "/.config/tokenbar/model-aliases.json", #"{"aliases": {"my-x": {"input": 1, "output": 2}}}"#)
        try write(h + "/.claude/projects/p/s.jsonl", claudeRow("m1", model: "my-x", input: 1_000_000) + "\n")
        let r = probe("argon-home-alias", dir: dir)
        check("argon 10: the home's model-aliases.json prices the model ($1 for 1M tokens)", r.status == 0 && r.out.contains("cost=1.0") && r.out.contains("alias=true"))
        if let cli = runTool("tokenbar-cli", ["--home", h, "--db", dir + "/cli.sqlite", "--rebuild", "--window", "all", "--json"], environment: ["TOKENBAR_PRICES_PINNED": "0"]),
           let object = (try? JSONSerialization.jsonObject(with: Data(cli.out.utf8))) as? [String: Any] {
            check("argon 10: tokenbar-cli --home reads that home's aliases", (object["cost"] as? Double) == 1.0)
        } else {
            skip("argon 10: tokenbar-cli --home reads that home's aliases", "tokenbar-cli is not built beside TokenChecks (swift build -c release)")
        }
    } catch { check("argon 10: \(error)", false) }

    // MARK: 11  UISnapshot selfcheck is not changed by this Mac's alias file

    do {
        let home = try tempDir() + "/home"
        try write(home + "/.config/tokenbar/model-aliases.json", #"{"aliases": {"claude-opus-5-5": {"input": 9, "output": 9}}}"#)
        let env = ["HOME": home, "CFFIXED_USER_HOME": home, "TOKENBAR_LANG": "tr"]
        if let ui = runTool("UISnapshot", ["selfcheck"], environment: env, remove: ["TOKENBAR_PRICES_PINNED"]) {
            check("argon 11: UISnapshot selfcheck passes with an alias for claude-opus-5-5 in the home (it pins the prices itself)",
                  ui.status == 0 && ui.out.contains("UI SELF-CHECK OK"))
        } else {
            skip("argon 11: UISnapshot selfcheck pins the prices itself", "UISnapshot is not built beside TokenChecks (swift build -c release)")
        }
    } catch { check("argon 11: \(error)", false) }

    // MARK: 13  the oracles read a WAL database from a copy

    do {
        let (_, h) = try fresh()
        let ocFolder = h + "/.local/share/opencode"
        try writeWALDatabase(ocFolder + "/opencode.db", ocSchema + "INSERT INTO message VALUES('m','s','\(ocMessage(input: 7, output: 3))',1);")
        let zedFolder = h + appSupport + "/Zed/threads"
        try writeWALDatabase(zedFolder + "/threads.db", zedSchema
                             + "INSERT INTO threads VALUES('t','t','2026-11-06T10:00:00Z','json', CAST('\(zedJSON(#"{"a":{"input_tokens":500}}"#, cumulative: 500))' AS BLOB), NULL);")
        let before = (listing(ocFolder), listing(zedFolder))
        if let oracle = oracleTotals(home: h) {
            let after = (listing(ocFolder), listing(zedFolder))
            check("argon 13: the oracle reads the rows only the -wal holds (opencode 10, zed 500)", oracle["opencode"]?.0 == 10 && oracle["zed"]?.0 == 500)
            check("argon 13: the oracle leaves no -shm (or anything else) in the tool's folders", before == after && !after.0.contains("opencode.db-shm") && !after.1.contains("threads.db-shm"))
        } else {
            skip("argon 13: the oracles read a WAL database from a copy", "python3 or scripts/oracle.py is not available")
        }
    } catch { check("argon 13: \(error)", false) }
}
