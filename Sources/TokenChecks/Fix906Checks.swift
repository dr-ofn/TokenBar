import Foundation
import SQLite3
import LocalCore

// Checks for the findings of the independent review of the published 9.0.5 (Mac side), 9.0.6 patch.
// Called once from `main.swift`; every case builds a small home and scans it in this process or in a child.
// `TokenChecks --probe fix906-only <dir>` runs just these (the rest of the run takes minutes).
//
//   1  a call whose id is exactly `adj` (a Claude message id, a Cline task id) is a call, not an adjustment row
//   2  a price cache folder that cannot be written: one request per catalogue and day, named once
//   3  a folder that cannot be read is named for opencode, Kilo Code (CLI and tasks), Continue and Copilot Chat
//   4  names that go to a terminal (tokenbar-cli text) hold no bidi, line-separator or control character
//   5  a folder that goes while the walk runs is not named
//   6  a FIFO under the name of opencode.db, Devin's sessions.db, Crush's crush.db: the scan ends, the rest counts
//   7  tokenbar-cli's real path of --home is Python's os.path.realpath
//   8  a file that cannot be opened for permission says so, not "no such file"
//  10  a pipe, socket or device beside a plain SQLite database (-journal, -wal, -shm) does not block the scan: the database is named, not opened
//  11  tokenbar-cli's last error line goes through the same filter as its other text
//  12  a link to a database: the pipe beside the database it leads to is found too
//  13  the cache warning is over once the cache can be written, and comes again if it breaks again
//  14  tokenbar-cli's flag errors go through the filter
//   9  an id that is exactly `adj` also keeps the prefixes made from it (retire, replace): checkpoint of a task, Devin transcript, rewritten Claude file

private let appSupport906 = "/Library/Application Support"

func fix906Probe(_ name: String, dir: String) -> String? {
    switch name {
    case "fix906-only":
        var count = 0
        func tempDir() throws -> String {
            count += 1
            let path = dir + "/c\(count)"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        do { try fix906Checks(tempDir: tempDir) } catch { check("fix906: \(error)", false) }
        return failures == 0 ? "ALL FIX906 PASS" : "\(failures) FAILED"
    case "fix906-scan":
        // The home of the caller, scanned twice by this child (a scan that opens a FIFO never returns).
        guard let store = try? UsageStore(path: dir + "/usage.sqlite") else { return "store error" }
        let first = UsageScanner(store: store, home: dir + "/home", environment: [:]).scan()
        let again = UsageScanner(store: store, home: dir + "/home", environment: [:]).scan()
        let named = first.issues.map { "\($0.source): \($0.message)" }.joined(separator: " | ")
        return "events=\(first.events) issues=\(first.issues.count) again=\(again.issues.count) named=\(named)"
    default:
        return nil
    }
}

private func claudeRow906(_ id: String, request: String = "r1", tokens: Int) -> String {
    #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"s1","requestId":"\#(request)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
}

/// What a child process printed, and whether it ended in time (`seconds`; then it is stopped).
private func child906(_ arguments: [String], executable: String = CommandLine.arguments[0], environment: [String: String] = [:],
                      seconds: Double = 20) -> (status: Int32, out: String, err: String, timedOut: Bool)? {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return nil }
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    let timer = DispatchWorkItem { if process.isRunning { flag.fired = true; process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
    // Both pipes are drained at once: a child that fills one while the other is waited on would stall.
    final class Box: @unchecked Sendable { var data = Data() }
    let errBox = Box()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    timer.cancel()
    return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errBox.data, as: UTF8.self), flag.fired)
}

private func cliPath906() -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("tokenbar-cli").path
}

/// Python's own answer (`python3` found on PATH, as CI has it); nil when there is no Python here. The expected paths
/// are also written down in the check, so a missing Python never lets a wrong path pass.
private func pythonReal906(_ path: String) -> String? {
    guard let r = child906(["python3", "-c", "import os, sys; print(os.path.realpath(sys.argv[1]))", path], executable: "/usr/bin/env"),
          r.status == 0 else { return nil }
    return r.out.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
}

func fix906Checks(tempDir: () throws -> String) throws {
    PriceBook.install(catalogs: .embedded)
    func scanned(_ home: String, in dir: String) throws -> (store: UsageStore, result: ScanResult) {
        let store = try UsageStore(path: dir + "/usage.sqlite")
        return (store, UsageScanner(store: store, home: home, environment: [:]).scan())
    }

    // MARK: 1  a call whose id is `adj`

    do {
        struct Outcome: Equatable { var calls: Int; var total: Int64; var cost: Double; var adjustmentRows: Bool }
        func claude(_ id: String) throws -> Outcome {
            let dir = try tempDir(), h = dir + "/home"
            try write(h + "/.claude/projects/p/a.jsonl", claudeRow906(id, tokens: 600) + "\n"
                + #"{"type":"cost-state","sessionId":"s1","startTime":"2026-11-06T10:00:00.000Z","modelUsage":{"claude-opus-5-5":{"inputTokens":620,"outputTokens":0}}}"# + "\n")
            let (store, _) = try scanned(h, in: dir)
            let report = try store.usageBook(now: Date(timeIntervalSince1970: 1793970000)).report(for: .all)
            return Outcome(calls: report.callCount, total: report.counts.total, cost: report.cost, adjustmentRows: store.hasEvents(prefix: "cc:adj:"))
        }
        let plain = try claude("m1"), named = try claude("adj")
        check("adj: Claude message.id 'adj' is a call and the cost-state gap is added (calls \(named.calls), total \(named.total))",
              named.calls == 1 && named.total == 620 && named.cost == plain.cost && named.adjustmentRows && plain.adjustmentRows)

        func cline(_ id: String) throws -> Outcome {
            let dir = try tempDir(), h = dir + "/home"
            try write(h + clineTasks + "/\(id)/ui_messages.json",
                      "[" + clineRow(#"{"tokensIn":250000,"tokensOut":100}"#, model: "claude-sonnet-4-20250514") + "]")
            let (store, _) = try scanned(h, in: dir)
            let report = try store.usageBook(now: Date(timeIntervalSince1970: 1793970000)).report(for: .all)
            return Outcome(calls: report.callCount, total: report.counts.total, cost: report.cost, adjustmentRows: false)
        }
        let t1 = try cline("t1"), adj = try cline("adj")
        check("adj: Cline task 'adj' is a call and its price tier applies as for any other task (calls \(adj.calls), cost \(adj.cost) vs \(t1.cost))",
              adj.calls == 1 && adj.total == 250_100 && adj.cost == t1.cost && adj.cost > 0)
    } catch { check("adj: \(error)", false) }

    // MARK: 2  price cache that cannot be written

    do {
        let dir = try tempDir()
        let cacheDir = URL(fileURLWithPath: dir + "/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        chmod(cacheDir.path, 0o555)
        defer { chmod(cacheDir.path, 0o755) }
        let fetcher = ScriptedFetcher()
        fetcher.script(.openrouter, .ok(#"{"data":[{"id":"vendor/zz-906","name":"Zz","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}"#, etag: "\"o1\""))
        fetcher.script(.litellm, .ok(#"{"zz-906-l":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"mode":"chat"}}"#, etag: "\"l1\""))
        fetcher.script(.modelsdev, .ok(#"{"prov":{"models":{"zz-906-m":{"cost":{"input":1,"output":2}}}}}"#, etag: nil))
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        func feed() -> PriceFeed {
            var config = PriceFeed.Config(cacheDirectory: cacheDir, offline: false, fetcher: fetcher)
            config.now = { clock.now }
            return PriceFeed(config)
        }
        let first = feed().refreshBlocking()
        let afterFirst = fetcher.count()
        clock.advance(3600)
        // A new feed, as the app makes for every pass: the process still remembers what the disk would not keep.
        let second = feed().refreshBlocking()
        let note = L10n.t("fiyat önbelleği yazılamıyor: ", "price cache cannot be written: ") + cacheDir.path
        check("price cache unwritable: three catalogues taken once (\(afterFirst) requests), the problem named once (\(first.warnings))",
              afterFirst == 3 && first.updated.count == 3 && first.failed.isEmpty && first.warnings == [note])
        check("price cache unwritable: the next pass an hour later asks nothing and says nothing (\(fetcher.count()) requests, \(second.warnings))",
              fetcher.count() == 3 && second.fresh.count == 3 && second.warnings.isEmpty && second.updated.isEmpty)
        check("price cache unwritable: the catalogues taken are read back (origin \(String(describing: feed().loadLocal().origins[.openrouter])))",
              feed().loadLocal().origins[.openrouter] != nil)
        clock.advance(25 * 3600)
        let third = feed().refreshBlocking()
        check("price cache unwritable: after the day's wait the catalogues are asked again, once each (\(fetcher.count()) requests)",
              fetcher.count() == 6 && third.updated.count + third.notModified.count == 3)
    } catch { check("price cache unwritable: \(error)", false) }

    // Every catalogue fails and the state file cannot be written either: the failures are remembered in memory (no new
    // request before the wait is over) and the folder is named, as on Windows.
    do {
        let dir = try tempDir()
        let cacheDir = URL(fileURLWithPath: dir + "/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        chmod(cacheDir.path, 0o555)
        defer { chmod(cacheDir.path, 0o755) }
        let fetcher = ScriptedFetcher()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        func feed() -> PriceFeed {
            var config = PriceFeed.Config(cacheDirectory: cacheDir, offline: false, fetcher: fetcher)
            config.now = { clock.now }
            return PriceFeed(config)
        }
        let first = feed().refreshBlocking()
        clock.advance(60)
        let second = feed().refreshBlocking()
        let note = L10n.t("fiyat önbelleği yazılamıyor: ", "price cache cannot be written: ") + cacheDir.path
        check("price state unwritable: every catalogue failed, the folder is named once (\(first.failed.count) failed, \(first.warnings))",
              first.failed.count == 3 && first.warnings == [note])
        check("price state unwritable: the failures are remembered, a minute later nothing is asked and nothing is said (\(fetcher.count()) requests, \(second.warnings))",
              fetcher.count() == 3 && second.skipped.count == 3 && second.warnings.isEmpty)
    } catch { check("price state unwritable: \(error)", false) }

    // MARK: 3  a folder that cannot be read is named

    func named(_ home: String, in dir: String, source: String, folder: String) throws -> (found: Bool, all: [String]) {
        let (_, r) = try scanned(home, in: dir)
        let want = folder + ": " + L10n.t("okunamıyor", "cannot be read")
        return (r.issues.contains { $0.source == source && $0.message == want }, r.issues.map { "\($0.source): \($0.message)" })
    }
    do {
        let code = appSupport906 + "/Code"
        let cases: [(label: String, source: String, folder: String, make: [String])] = [
            ("Copilot Chat workspaceStorage", "Copilot Chat", code + "/User/workspaceStorage", [code + "/User/workspaceStorage/h1/chatSessions"]),
            ("Copilot Chat chatSessions", "Copilot Chat", code + "/User/workspaceStorage/h1/chatSessions", [code + "/User/workspaceStorage/h1/chatSessions"]),
            ("Kilo Code tasks", "Kilo Code", code + "/User/globalStorage/kilocode.kilo-code/tasks", [code + "/User/globalStorage/kilocode.kilo-code/tasks/t1"]),
            ("Continue root", "Continue", "/.continue", ["/.continue/dev_data/0.2.0"]),
            ("opencode root", "opencode", "/.local/share/opencode", ["/.local/share/opencode"]),
            ("Kilo Code CLI root", "Kilo Code (kilo)", "/.local/share/kilo", ["/.local/share/kilo"]),
        ]
        for c in cases {
            let dir = try tempDir(), h = dir + "/home"
            for folder in c.make { try FileManager.default.createDirectory(atPath: h + folder, withIntermediateDirectories: true) }
            let target = h + c.folder
            chmod(target, 0)
            defer { chmod(target, 0o755) }
            let r = try named(h, in: dir, source: c.source, folder: target)
            check("unreadable \(c.label): named by its folder under \(c.source) (\(r.all))", r.found)
        }
        // A folder that is not there is no problem at all.
        let dir = try tempDir(), h = dir + "/home"
        try FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true)
        let (_, empty) = try scanned(h, in: dir)
        check("unreadable: a home with none of the tools' folders names nothing (\(empty.issues.map(\.message)))", empty.issues.isEmpty)
    } catch { check("unreadable folders: \(error)", false) }

    // MARK: 4  names that go to the terminal

    do {
        let evil = "A\u{200E}B\u{200F}C\u{061C}D\u{2028}E\u{2029}F\u{1B}G\u{7}H\u{202E}I\u{2066}J"
        check("displaySafe: the marks, separators, controls and bidi characters go (\(ModelNames.displaySafe(evil)))",
              ModelNames.displaySafe(evil) == "ABCDEFGHIJ" && ModelNames.displaySafe("Çağrı ı İ ş \u{200D}x") == "Çağrı ı İ ş \u{200D}x")
        let dir = try tempDir(), h = dir + "/home", db = dir + "/u.sqlite"
        let store = try UsageStore(path: db)
        let badModel = "evil\u{1B}]0;PWNED\u{7}\u{202E}abc", badProvider = "prov\u{1B}[31m\u{2028}x\u{200F}"
        try store.insertEvents([UsageEvent(key: "cc:z:1", provider: badProvider, model: badModel, timestamp: Date().timeIntervalSince1970 - 60,
                                           tokens: TokenCounts(input: 100, output: 10), session: "s", file: "f")])
        // A folder that cannot be read, with a name made of the same: the problem's path goes through the filter too.
        let badFolder = h + "/.claude/projects/q\u{1B}[41m\u{202E}\u{200E}z"
        try FileManager.default.createDirectory(atPath: badFolder, withIntermediateDirectories: true)
        chmod(badFolder, 0)
        defer { chmod(badFolder, 0o755) }
        let env = ["HOME": dir, "CFFIXED_USER_HOME": dir, "TOKENBAR_PRICES_PINNED": "1", "TOKENBAR_LANG": "tr"]
        let args = ["--home", h, "--db", db, "--window", "all", "--offline"]
        if let text = child906(args + ["--no-scan"], executable: cliPath906(), environment: env),
           let scan = child906(args, executable: cliPath906(), environment: env),
           let json = child906(args + ["--no-scan", "--json"], executable: cliPath906(), environment: env) {
            func clean(_ s: String) -> Bool {
                !s.unicodeScalars.contains { (u: Unicode.Scalar) -> Bool in
                    u == "\u{1B}" || u == "\u{7}" || u == "\u{202E}" || u == "\u{200E}" || u == "\u{200F}" || u == "\u{2028}" || u == "\u{2029}" || u == "\u{061C}"
                }
            }
            check("cli text: model and provider names are filtered (\(text.status): \(text.out.replacingOccurrences(of: "\n", with: " ⏎ ")))",
                  text.status == 0 && clean(text.out) && text.out.contains("PWNED") && text.out.contains("abc"))
            check("cli text: the unreadable folder's path in the problem line is filtered (\(scan.err.replacingOccurrences(of: "\n", with: " ⏎ ")))",
                  scan.status == 0 && clean(scan.err) && scan.err.contains(L10n.t("okunamıyor", "cannot be read")) && scan.err.contains("projects/q"))
            let parsed = (try? JSONSerialization.jsonObject(with: Data(json.out.utf8))) != nil
            check("cli json: the names are left as the log holds them (valid JSON \(parsed), ESC escaped \(json.out.contains("\\u001b")))",
                  json.status == 0 && parsed && json.out.contains("\\u001b") && json.out.contains("PWNED"))
        } else {
            skip("cli displaySafe", "tokenbar-cli is not built beside TokenChecks (swift build -c release)")
        }
    } catch { check("terminal names: \(error)", false) }

    // MARK: 5  a folder that goes while the walk runs

    do {
        // Thousands of empty folders; another thread removes them from the end while the scan walks from the start.
        var vanishedNamed: [String] = []
        for _ in 0..<6 {
            let dir = try tempDir(), h = dir + "/home", projects = h + "/.claude/projects"
            try write(projects + "/a/ok.jsonl", claudeRow906("ok", tokens: 10) + "\n")
            for i in 0..<3000 { try FileManager.default.createDirectory(atPath: projects + "/z\(String(format: "%04d", i))", withIntermediateDirectories: false) }
            let store = try UsageStore(path: dir + "/usage.sqlite")
            let remover = Thread {
                for i in stride(from: 2999, through: 0, by: -1) { try? FileManager.default.removeItem(atPath: projects + "/z\(String(format: "%04d", i))") }
            }
            remover.start()
            let r = UsageScanner(store: store, home: h, environment: [:]).scan()
            vanishedNamed += r.issues.map(\.message).filter { $0.contains("/projects/z") }
            while !remover.isFinished { usleep(1000) }
        }
        check("walk: a folder that went while the walk ran is not named (\(vanishedNamed.count) named: \(vanishedNamed.prefix(2)))", vanishedNamed.isEmpty)
    } catch { check("walk vanishing: \(error)", false) }

    // MARK: 6  a FIFO under a database's name

    do {
        let dir = try tempDir(), h = dir + "/home"
        try write(h + "/.claude/projects/p/s.jsonl", claudeRow906("fifo1", tokens: 40) + "\n")
        func fifo(_ path: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard mkfifo(path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try fifo(h + "/.local/share/opencode/opencode.db")
        try fifo(h + "/.local/share/kilo/kilo.db")
        try fifo(h + "/.local/share/devin/cli/sessions.db")
        try fifo(h + "/proj/.crush/crush.db")
        try write(h + "/.local/share/crush/projects.json", #"{"projects":[{"path":"\#(h)/proj","data_dir":"\#(h)/proj/.crush"}]}"#)
        guard let r = child906(["--probe", "fix906-scan", dir]) else { throw CocoaError(.fileNoSuchFile) }
        check("FIFO named opencode.db, kilo.db, sessions.db, crush.db: the scan ends, the other sources count, nothing is named (\(r.timedOut ? "timed out" : "\(r.status)"): \(r.out))",
              !r.timedOut && r.status == 0 && r.out.contains("events=1 issues=0 again=0"))
    } catch { check("fifo databases: \(error)", false) }

    // MARK: 7  the real path of --home is Python's

    do {
        let base = (try tempDir()) + "/rp"
        let fm = FileManager.default
        for folder in ["sub/deep", "tgt", "loop", "real/inner"] { try fm.createDirectory(atPath: base + "/" + folder, withIntermediateDirectories: true) }
        try fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: "sub/deep")
        try fm.createSymbolicLink(atPath: base + "/dl", withDestinationPath: "tgt/gone")
        try fm.createSymbolicLink(atPath: base + "/abs", withDestinationPath: base + "/real")
        try fm.createSymbolicLink(atPath: base + "/l1", withDestinationPath: "l2")
        try fm.createSymbolicLink(atPath: base + "/l2", withDestinationPath: "l1")
        try fm.createSymbolicLink(atPath: base + "/up", withDestinationPath: "real/inner/..")
        try fm.createSymbolicLink(atPath: base + "/chain", withDestinationPath: "link/../deep2")
        // The folder the checks run in may itself be reached through a link (.build/release): the written-down results start at its real path.
        guard let realPtr = realpath(base, nil) else { throw CocoaError(.fileNoSuchFile) }
        let rb = String(cString: realPtr)
        free(realPtr)
        let cwd = FileManager.default.currentDirectoryPath
        let cases: [(input: String, expected: String)] = [
            (base + "/link/../notyet", rb + "/sub/notyet"),
            (base + "/dl", rb + "/tgt/gone"),
            (base + "/dl/x/../y", rb + "/tgt/gone/y"),
            (base + "/nope/a/b", rb + "/nope/a/b"),
            (base + "/nope/../real", rb + "/real"),
            (base + "/sub/../sub/deep", rb + "/sub/deep"),
            (base + "/abs/inner/../x", rb + "/real/x"),
            (base + "/up/inner", rb + "/real/inner"),
            (base + "/chain", rb + "/sub/deep2"),
            (base + "/l1/x", rb + "/l1/x"),
            (base + "//sub///deep/./", rb + "/sub/deep"),
            ("/tmp/../tmp", "/private/tmp"),
            ("/var/../tmp", "/private/tmp"),
            ("rel/../a/./b", cwd + "/a/b"),
        ]
        var bad: [String] = []
        var pythonSaid = 0
        for (input, expected) in cases {
            let mine = try RealPath.resolve(input)
            if mine != expected { bad.append("\(input): swift \(mine) expected \(expected)") }
            if let theirs = pythonReal906(input) {
                pythonSaid += 1
                if theirs != expected { bad.append("\(input): python \(theirs) but written down \(expected)") }
            }
        }
        check("realpath: \(cases.count) spellings (links, broken links, .., loops, relative) give the written-down path, Python's too where there is a Python (\(pythonSaid) asked) (\(bad))", bad.isEmpty)
        // A link that lstat shows and readlink cannot read is an error, as in Python, never a guess from the folder above.
        struct Refused: Error {}
        var refused = false
        do { _ = try RealPath.resolve(base + "/link/x", readLink: { (_: String) throws -> String in throw Refused() }) } catch is Refused { refused = true }
        check("realpath: a link that cannot be read is an error, not a guess", refused)
        // And a plain path never reads a link at all.
        var asked = 0
        let plain = try RealPath.resolve(rb + "/sub/deep", readLink: { (p: String) throws -> String in asked += 1; return p })
        check("realpath: a path with no link asks for none (\(plain), \(asked))", asked == 0 && plain == rb + "/sub/deep")
    } catch { check("realpath: \(error)", false) }

    // MARK: 8  an unreadable file is a permission error

    do {
        let dir = try tempDir()
        let path = dir + "/secret.jsonl"
        try write(path, "x\n")
        chmod(path, 0)
        defer { chmod(path, 0o644) }
        var kind = "none"
        do {
            _ = try LineReader.forEachLine(path: path, from: 0) { (_: UnsafeRawBufferPointer) -> Bool in true }
        } catch let error as CocoaError {
            kind = error.code == .fileReadNoPermission ? "permission" : "cocoa \(error.code.rawValue)"
        } catch {
            kind = "\(error)"
        }
        check("line reader: a file that cannot be opened for permission is a permission error, not a missing file (\(kind))", kind == "permission")
        let missing = dir + "/not-there.jsonl"
        var missingKind = "none"
        do {
            _ = try LineReader.forEachLine(path: missing, from: 0) { (_: UnsafeRawBufferPointer) -> Bool in true }
        } catch let error as CocoaError {
            missingKind = error.code == .fileReadNoSuchFile ? "missing" : "cocoa \(error.code.rawValue)"
        } catch {
            missingKind = "\(error)"
        }
        check("line reader: a file that is not there is still a missing-file error (\(missingKind))", missingKind == "missing")
        // Through a scan: the issue names the file and does not say it is missing.
        let scanDir = try tempDir(), h = scanDir + "/home"
        let log = h + "/.claude/projects/p/locked.jsonl"
        try write(log, claudeRow906("lk", tokens: 5) + "\n")
        chmod(log, 0)
        defer { chmod(log, 0o644) }
        let (_, r) = try scanned(h, in: scanDir)
        let text = r.issues.map(\.message).joined(separator: " | ")
        check("line reader: the scan names the locked file with a permission message (\(text))",
              text.contains("locked.jsonl") && !text.lowercased().contains("doesn’t exist") && !text.lowercased().contains("doesn't exist") && !text.contains("no such file"))
    } catch { check("line reader permission: \(error)", false) }

    // MARK: 9  the prefixes made from an id `adj` follow the key

    do {
        func totals(_ store: UsageStore) throws -> String {
            let report = try store.usageBook(now: Date(timeIntervalSince1970: 1793970000)).report(for: .all)
            return "\(report.counts.total)/\(report.callCount)"
        }
        // A task whose first call a checkpoint restore dropped: the file is the whole truth of its task, so the rows the first
        // reading wrote for the dropped call go, whatever the task is called.
        let kiloTasks = appSupport906 + "/Code/User/globalStorage/kilocode.kilo-code/tasks"
        var seen: [String] = []
        for (label, tasks) in [("Cline", clineTasks), ("Roo Code", rooTasks), ("Kilo Code", kiloTasks)] {
            for id in ["t9", "adj"] {
                let dir = try tempDir(), h = dir + "/home"
                let file = h + tasks + "/\(id)/ui_messages.json"
                let first = clineRow(#"{"tokensIn":1000,"tokensOut":10}"#, ts: "1793968800000", model: "claude-sonnet-4-20250514")
                let second = clineRow(#"{"tokensIn":2000,"tokensOut":10}"#, ts: "1793968900000", model: "claude-sonnet-4-20250514")
                try write(file, "[" + first + "," + second + "]")
                let store = try UsageStore(path: dir + "/usage.sqlite")
                let scanner = UsageScanner(store: store, home: h, environment: [:])
                _ = scanner.scan()
                let before = try totals(store)
                try write(file, "[" + second + "]")
                _ = scanner.scan()
                seen.append("\(label) \(id): \(before) -> \(try totals(store))")
            }
        }
        check("adj prefixes: a task called adj loses the dropped call as any other task does (\(seen))",
              seen.allSatisfy { $0.hasSuffix("3020/2 -> 2010/1") })

        // Devin: a session called adj read from the database, then its transcript appears: counted once.
        var devin: [String] = []
        for id in ["t9", "adj"] {
            let dir = try tempDir(), h = dir + "/home"
            try runSQL(h + "/.local/share/devin/cli/sessions.db", """
            CREATE TABLE sessions(id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL, model TEXT NOT NULL,
                agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL, title TEXT);
            CREATE TABLE message_nodes(row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, node_id INTEGER NOT NULL,
                parent_node_id INTEGER, chat_message TEXT NOT NULL, created_at INTEGER NOT NULL, metadata TEXT, UNIQUE(session_id, node_id));
            INSERT INTO sessions VALUES('\(id)','/work','local','adaptive','normal',1793968800,1793968900,NULL);
            INSERT INTO message_nodes(session_id,node_id,chat_message,created_at) VALUES('\(id)',1,
                '{"role":"assistant","metadata":{"request_id":"r1","generation_model":"swe-1-6-slow","metrics":{"input_tokens":100,"output_tokens":20}}}',1793968801);
            """)
            let store = try UsageStore(path: dir + "/usage.sqlite")
            let scanner = UsageScanner(store: store, home: h, environment: [:])
            _ = scanner.scan()
            let alone = try totals(store)
            try write(h + "/.local/share/devin/cli/transcripts/\(id).json",
                      #"{"session_id":"\#(id)","agent":{"model_name":"swe-1-6-slow"},"steps":[{"step_id":1,"timestamp":"2026-11-06T10:00:00Z","metrics":{"prompt_tokens":100,"cached_tokens":0,"completion_tokens":20}}]}"#)
            _ = scanner.scan()
            devin.append("\(id): \(alone) -> \(try totals(store))")
        }
        check("adj prefixes: a Devin session called adj is counted once when its transcript (the same figures) appears (\(devin))",
              devin.allSatisfy { $0.hasSuffix("120/1 -> 120/1") })

        // A 9.0.5 index holds the rows of such a task under the raw id (`cline:adj:...`, `devin:adj:db:...`): the same reading
        // clears them too, and nothing of a raw `adj:` prefix is left.
        do {
            let dir = try tempDir(), h = dir + "/home"
            let file = h + clineTasks + "/adj/ui_messages.json"
            let first = clineRow(#"{"tokensIn":1000,"tokensOut":10}"#, ts: "1793968800000", model: "claude-sonnet-4-20250514")
            let second = clineRow(#"{"tokensIn":2000,"tokensOut":10}"#, ts: "1793968900000", model: "claude-sonnet-4-20250514")
            try write(file, "[" + first + "," + second + "]")
            let store = try UsageStore(path: dir + "/usage.sqlite")
            let scanner = UsageScanner(store: store, home: h, environment: [:])
            _ = scanner.scan()
            // What 9.0.5 wrote for the dropped call: the raw key (an `adjustment` event keeps its key as given).
            try store.insertEvents([UsageEvent(key: "cline:adj:1793968800000|1000|0|0|10", provider: "anthropic", model: "claude-sonnet-4-20250514",
                                               timestamp: 1793968800, tokens: TokenCounts(input: 1000, output: 10), session: "adj", file: file, adjustment: true)])
            let withOld = try totals(store), rawBefore = store.hasEvents(prefix: "cline:adj:")
            try write(file, "[" + second + "]")
            _ = scanner.scan()
            let after = try totals(store), rawAfter = store.hasEvents(prefix: "cline:adj:")
            check("adj prefixes: a raw cline:adj: row of a 9.0.5 index goes when the task file changes (\(withOld) raw \(rawBefore) -> \(after) raw \(rawAfter))",
                  rawBefore && !rawAfter && after == "2010/1")
        }

        // Claude: a transcript with the id adj, rewritten longer: every call once, the gap row follows the new cost-state.
        var claude: [String] = []
        for id in ["m1", "adj"] {
            let dir = try tempDir(), h = dir + "/home"
            let file = h + "/.claude/projects/p/a.jsonl"
            func costState(_ n: Int) -> String {
                #"{"type":"cost-state","sessionId":"s1","startTime":"2026-11-06T10:00:00.000Z","modelUsage":{"claude-opus-5-5":{"inputTokens":\#(n),"outputTokens":0}}}"#
            }
            try write(file, claudeRow906(id, tokens: 600) + "\n" + costState(620) + "\n")
            let store = try UsageStore(path: dir + "/usage.sqlite")
            let scanner = UsageScanner(store: store, home: h, environment: [:])
            _ = scanner.scan()
            let before = try totals(store)
            try write(file, claudeRow906(id, tokens: 600) + "\n" + claudeRow906("m2", request: "r2", tokens: 300) + "\n" + costState(950) + "\n")
            _ = scanner.scan()
            claude.append("\(id): \(before) -> \(try totals(store))")
        }
        check("adj prefixes: a Claude transcript with the id adj, rewritten longer, counts as one with another id (\(claude))",
              claude.allSatisfy { $0.hasSuffix("620/1 -> 950/2") })
    } catch { check("adj prefixes: \(error)", false) }

    // MARK: 10  a pipe beside a plain database

    do {
        for suffix in ["-journal", "-wal", "-shm"] {
            let dir = try tempDir(), h = dir + "/home"
            try write(h + "/.claude/projects/p/s.jsonl", claudeRow906("side1", tokens: 40) + "\n")
            let db = h + "/.local/share/opencode/opencode.db"
            try runSQL(db, "CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);")
            guard mkfifo(db + suffix, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
            guard let r = child906(["--probe", "fix906-scan", dir]) else { throw CocoaError(.fileNoSuchFile) }
            check("pipe named opencode.db\(suffix) beside a plain database: the scan ends, the other sources count, the file is named (\(r.timedOut ? "timed out" : "\(r.status)"): \(r.out.replacingOccurrences(of: dir, with: "~")))",
                  !r.timedOut && r.status == 0 && r.out.contains("events=1") && r.out.contains("opencode.db\(suffix):"))
        }
    } catch { check("pipe beside a database: \(error)", false) }

    // MARK: 11  tokenbar-cli's last error line

    do {
        let dir = try tempDir()
        // The index folder is a file: the error of the store names it (NSFilePath), ESC and bidi characters included.
        let folder = dir + "/no\u{1B}[31mpe\u{202E}x\u{200F}"
        try write(folder, "a file where the index folder should be")
        let bad = folder + "/u.sqlite"
        let env = ["HOME": dir, "CFFIXED_USER_HOME": dir, "TOKENBAR_PRICES_PINNED": "1", "TOKENBAR_LANG": "tr"]
        if let r = child906(["--db", bad, "--window", "all", "--offline", "--no-scan"], executable: cliPath906(), environment: env) {
            let dirty = r.err.unicodeScalars.contains { (u: Unicode.Scalar) -> Bool in u == "\u{1B}" || u == "\u{202E}" || u == "\u{200F}" }
            check("cli error line: a path with control and bidi characters is filtered (\(r.status): \(r.err.replacingOccurrences(of: dir, with: "~")))",
                  r.status != 0 && !dirty && r.err.hasPrefix("tokenbar-cli: ") && r.err.contains("pe"))
        } else {
            skip("cli error line", "tokenbar-cli is not built beside TokenChecks (swift build -c release)")
        }
    } catch { check("cli error line: \(error)", false) }
    // MARK: 12  a link to a database

    do {
        let dir = try tempDir(), h = dir + "/home"
        try write(h + "/.claude/projects/p/s.jsonl", claudeRow906("link1", tokens: 40) + "\n")
        let real = dir + "/elsewhere/real.db"
        try runSQL(real, "CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);")
        guard mkfifo(real + "-journal", 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(atPath: h + "/.local/share/opencode", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: h + "/.local/share/opencode/opencode.db", withDestinationPath: real)
        guard let r = child906(["--probe", "fix906-scan", dir]) else { throw CocoaError(.fileNoSuchFile) }
        check("pipe beside the database a link leads to: the scan ends, the other sources count, the pipe is named (\(r.timedOut ? "timed out" : "\(r.status)"): \(r.out.replacingOccurrences(of: dir, with: "~")))",
              !r.timedOut && r.status == 0 && r.out.contains("events=1") && r.out.contains("real.db-journal:"))
    } catch { check("link to a database: \(error)", false) }

    // MARK: 13  the cache warning's life

    do {
        let dir = try tempDir()
        let cacheDir = URL(fileURLWithPath: dir + "/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { chmod(cacheDir.path, 0o755) }
        let fetcher = ScriptedFetcher()
        fetcher.script(.openrouter, .ok(#"{"data":[{"id":"vendor/zz-906","name":"Zz","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}"#, etag: "\"o1\""))
        fetcher.script(.litellm, .ok(#"{"zz-906-l":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"mode":"chat"}}"#, etag: "\"l1\""))
        fetcher.script(.modelsdev, .ok(#"{"prov":{"models":{"zz-906-m":{"cost":{"input":1,"output":2}}}}}"#, etag: nil))
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        func feed() -> PriceFeed {
            var config = PriceFeed.Config(cacheDirectory: cacheDir, offline: false, fetcher: fetcher)
            config.now = { clock.now }
            return PriceFeed(config)
        }
        let note = L10n.t("fiyat önbelleği yazılamıyor: ", "price cache cannot be written: ") + cacheDir.path
        chmod(cacheDir.path, 0o555)
        let broken = feed().refreshBlocking()
        check("cache warning: while the cache cannot be written the pass says so (\(broken.cacheProblem ?? "-"), once: \(broken.warnings.count))",
              broken.cacheChecked && broken.cacheProblem == note && broken.warnings == [note])
        chmod(cacheDir.path, 0o755)
        clock.advance(600)
        let mended = feed().refreshBlocking()
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []).filter { $0.hasPrefix("prices-") }.count
        check("cache warning: once the folder can be written the held catalogues go to disk and the problem is over (\(String(describing: mended.cacheProblem)), \(onDisk) files)",
              mended.cacheChecked && mended.cacheProblem == nil && onDisk >= 3 && fetcher.count() == 3)
        chmod(cacheDir.path, 0o555)
        clock.advance(25 * 3600)
        let again = feed().refreshBlocking()
        check("cache warning: broken again, it is said again (\(again.cacheProblem ?? "-"), \(again.warnings.count))",
              again.cacheProblem == note && again.warnings == [note])
    } catch { check("cache warning life: \(error)", false) }

    // MARK: 14  the flag errors of tokenbar-cli

    do {
        let dir = try tempDir()
        let env = ["HOME": dir, "CFFIXED_USER_HOME": dir, "TOKENBAR_PRICES_PINNED": "1", "TOKENBAR_LANG": "tr"]
        if let window = child906(["--db", dir + "/u.sqlite", "--window", "x\u{1B}[31m\u{202E}y\u{200F}"], executable: cliPath906(), environment: env),
           let flag = child906(["--bad\u{1B}]0;PWNED\u{7}\u{202E}flag"], executable: cliPath906(), environment: env) {
            func dirty(_ s: String) -> Bool {
                s.unicodeScalars.contains { (u: Unicode.Scalar) -> Bool in u == "\u{1B}" || u == "\u{7}" || u == "\u{202E}" || u == "\u{200F}" }
            }
            check("cli flags: the window value and an unknown flag are filtered in the error line (\(window.err), \(flag.err))",
                  window.status == 1 && flag.status == 1 && !dirty(window.err) && !dirty(flag.err) && window.err.contains("x") && flag.err.contains("PWNED"))
        } else {
            skip("cli flag errors", "tokenbar-cli is not built beside TokenChecks (swift build -c release)")
        }
    } catch { check("cli flag errors: \(error)", false) }
}
