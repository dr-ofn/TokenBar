import Foundation
import SQLite3
import LocalCore

// Checks for the findings of the independent review of the published 9.0.3 (Mac side), 9.0.4 patch.
// Called once from `main.swift`; every case builds a small home and scans it in this process or in a child.
//
//   2  model-aliases.json that is there and cannot be read is named among the scan issues (as on Windows); a missing or empty one is not
//   3  a bounded period counts only calls up to a day ahead of now (futureSlackSeconds); `all` counts every call (same rule as Windows)
//   4  the price feed is asked again after a failed pass in an hour, twice as long after each failure in a row, six hours at most (Windows rule)
//   5  with a home of its own (tokenbar-cli --home, Engine(home:)) the price cache is that home's, not the user's
//   1  two unpriced models with token counts at the limit: the ribbons, the tide and every detail read through without a trap

/// The child's side of the cases that must not trap: a trap ends that process, not the run.
func fix904Probe(_ name: String, dir: String) -> String? {
    switch name {
    case "fix904-huge":
        guard let store = try? UsageStore(path: dir + "/usage.sqlite") else { return "store error" }
        let result = UsageScanner(store: store, home: dir + "/home", environment: [:]).scan()
        guard let book = try? store.usageBook(now: Date(timeIntervalSince1970: 1793970000)) else { return "report error" }
        var drawn = 0, details = 0
        for period in Period.allCases {
            let report = book.report(for: period)
            for (width, height) in [(460.0, 620.0), (20.0, 20.0), (460.0, 200.0)] {
                _ = RibbonLayout(report: report, width: width, height: height, leftColumn: min(104, width / 4), rightColumn: min(186, width / 4),
                                 top: 2, bottomMargin: 2)
                _ = TideLayout(report: report, width: width, height: height)
                drawn += 1
            }
            var selections: [UsageSelection] = [.total]
            selections += report.harnesses.map { .harness($0.harness) }
            selections += report.groups.map { .model($0.key) }
            selections += report.harnesses.flatMap(\.models).map { .flow($0.id) }
            selections.append(.list("x", report.groups.map(\.key)))
            for selection in selections { _ = report.detail(selection); _ = UsageText.summary(report); details += 1 }
            _ = try? ReportJSON.serialize(ReportJSON.object(report, window: period, detected: []))
        }
        let all = book.report(for: .all)
        return "ok drawn=\(drawn) details=\(details) calls=\(all.callCount) issues=\(result.issues.count) first=\(result.issues.first.map { "\($0.source): \($0.message)" } ?? "-") models=\(all.groups.count)"
    case "fix904-alias":
        // This home's price names, read for real: a pinned run reads no alias file, and HOME is the fake home (see the caller).
        setenv("TOKENBAR_PRICES_PINNED", "0", 1)
        PriceBook.useHome(dir + "/home")
        guard let store = try? UsageStore(path: dir + "/usage.sqlite") else { return "store error" }
        let result = UsageScanner(store: store, home: dir + "/home", environment: [:]).scan()
        guard let report = try? store.usageBook(now: Date(timeIntervalSince1970: 1793970000)).report(for: .all) else { return "report error" }
        let named = result.issues.filter { $0.source == UserAliases.fileName }
        return "cost=\(report.cost) aliasIssues=\(named.count) other=\(result.issues.count - named.count) text=\(named.first?.message ?? "-")"
    case "fix904-cache":
        // The prices of this home, read from its cache folder: HOME (the decoy) has a cache of its own with another price.
        setenv("TOKENBAR_PRICES_PINNED", "0", 1)
        PriceBook.useHome(dir + "/home")
        let entry = ModelPrice(model: "acme/zz-cache-model").entry
        return "input=\(entry?.rates.input ?? -1)"
    default:
        return nil
    }
}

private func claudeRow904(_ id: String, model: String, tokens: String, time: String = "2026-11-06T10:00:00.000Z") -> String {
    #"{"type":"assistant","timestamp":"\#(time)","sessionId":"s1","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(tokens),"output_tokens":\#(tokens),"cache_read_input_tokens":\#(tokens),"cache_creation_input_tokens":\#(tokens)}}}"#
}

func fix904Checks(tempDir: () throws -> String) throws {
    PriceBook.install(catalogs: .embedded)

    // MARK: 1  token counts at the limit in two models that have no price

    do {
        let dir = try tempDir()
        // 10**20 in every field: the reader holds each to Int64.max / 4, and two such models add up past Int64.
        let rows = [claudeRow904("m1", model: "zz-a", tokens: "100000000000000000000"),
                    claudeRow904("m2", model: "zz-b", tokens: "100000000000000000000")]
        try write(dir + "/home/.claude/projects/p/s.jsonl", rows.joined(separator: "\n") + "\n")
        let r = probe("fix904-huge", dir: dir)
        check("huge counts in two unpriced models: the ribbons, the tide and every detail read without a trap (status \(r.status))",
              r.status == 0 && r.out.hasPrefix("ok "))
        check("huge counts in two unpriced models: both calls still count", r.out.contains("calls=2") && r.out.contains("models=2"))
    } catch { check("huge counts: \(error)", false) }

    // MARK: 1b  a sum over the index (SQL SUM) of rows that each hold the limit

    do {
        let dir = try tempDir()
        let big = "100000000000000000000"
        var rows = (1...5).map { claudeRow904("m\($0)", model: "claude-opus-5-5", tokens: big) }
        rows.append(#"{"type":"cost-state","sessionId":"s1","startTime":"2026-11-06T10:00:00.000Z","modelUsage":{"claude-opus-5-5":{"inputTokens":5,"outputTokens":1}}}"#)
        try write(dir + "/home/.claude/projects/p/s.jsonl", rows.joined(separator: "\n") + "\n")
        let r = probe("fix904-huge", dir: dir)
        check("five rows at the limit and a cost-state: no trap, no scan error, all five calls count (\(r.out))",
              r.status == 0 && r.out.contains("calls=5") && r.out.contains("issues=0"))
    } catch { check("sum of huge rows: \(error)", false) }

    // MARK: 2  a price-name file that is there and cannot be read

    do {
        let row = claudeRow904("m1", model: "zz-home-model", tokens: "0").replacingOccurrences(of: #""input_tokens":0"#, with: #""input_tokens":1000000"#)
            .replacingOccurrences(of: #""output_tokens":0"#, with: #""output_tokens":0"#)
        let good = #"{"aliases":{"zz-home-model":{"input":1,"output":2}}}"#
        let unreadable: [(String, [UInt8])] = [
            ("invalid UTF-8", Array(#"{"aliases":{"zz-home-model":{"input":1,"output":2,"source":"caf"#.utf8) + [0xE9] + Array(#""}}}"#.utf8)),
            ("NaN", Array(#"{"aliases":{"zz-home-model":{"input":NaN,"output":2}}}"#.utf8)),
            ("a lone surrogate", Array(#"{"aliases":{"zz-home-model":{"input":1,"output":2,"source":"\ud800"}}}"#.utf8)),
            ("a cut-off file", Array(#"{"aliases":{"zz-home-model":{"input":1,"output":2}"#.utf8)),
            ("a JSON array", Array("[1,2]".utf8)),
            ("a JSON number", Array("5".utf8)),
            ("spaces only", Array("  \n".utf8)),
        ]
        func run(_ name: String, bytes: [UInt8]?, mode: Int? = nil) throws -> (status: Int32, out: String) {
            let dir = try tempDir(), h = dir + "/home"
            try write(h + "/.claude/projects/p/s.jsonl", row + "\n")
            let path = h + "/.config/tokenbar/model-aliases.json"
            if let bytes {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data(bytes), attributes: mode.map { [.posixPermissions: $0] })
            }
            defer { if mode != nil { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) } }
            // HOME is the fake home as well: the price cache is read from there, never from this Mac's.
            return probe("fix904-alias", dir: dir, env: ["HOME": h, "CFFIXED_USER_HOME": h])
        }
        for (name, bytes) in unreadable {
            let r = try run(name, bytes: bytes)
            check("model-aliases.json that is \(name): one scan issue names it, no alias is used (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
                  r.status == 0 && r.out.contains("aliasIssues=1") && r.out.contains("cost=0.0") && r.out.contains("other=0"))
        }
        let noRead = try run("no permission", bytes: Array(good.utf8), mode: 0)
        check("model-aliases.json that cannot be opened: one scan issue names it (\(noRead.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
              noRead.status == 0 && noRead.out.contains("aliasIssues=1") && noRead.out.contains("cost=0.0"))
        let ok = try run("good", bytes: Array(good.utf8))
        check("model-aliases.json that is fine: no issue, the alias prices (\(ok.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
              ok.status == 0 && ok.out.contains("aliasIssues=0") && ok.out.contains("cost=1.0"))
        for (name, bytes) in [("missing", nil), ("empty (no bytes)", []), ("null", Array("null".utf8))] as [(String, [UInt8]?)] {
            let r = try run(name, bytes: bytes)
            check("model-aliases.json \(name): no issue (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
                  r.status == 0 && r.out.contains("aliasIssues=0") && r.out.contains("other=0"))
        }
    } catch { check("alias issue: \(error)", false) }

    // MARK: 3  calls dated in the future

    do {
        let dir = try tempDir()
        let now = 1793970000.0
        let store = try UsageStore(path: dir + "/usage.sqlite")
        func event(_ key: String, _ time: Double, _ tokens: Int64) -> UsageEvent {
            UsageEvent(key: key, provider: "anthropic", model: "claude-opus-5-5", timestamp: time,
                       tokens: TokenCounts(input: tokens), session: key, file: "f")
        }
        let slack = UsageBook.futureSlackSeconds
        check("future slack is one day", slack == 86400)
        try store.insertEvents([
            event("cc:now", now - 60, 1),                       // 1
            event("cc:hour", now + 3600, 10),                   // 10: an hour ahead (a clock a little fast) counts
            event("cc:edge", now + slack, 100),                 // 100: exactly a day ahead counts
            event("cc:past-edge", now + slack + 1, 1000),       // 1000: a second more does not
            event("cc:three-years", now + 3 * 365 * 86400, 10_000),
            event("cc:y2100", 4102444800, 100_000),             // 2100-01-01
        ])
        let book = try store.usageBook(now: Date(timeIntervalSince1970: now))
        func total(_ period: Period) -> Int64 { book.report(for: period).counts.total }
        func calls(_ period: Period) -> Int { book.report(for: period).callCount }
        for period in [Period.oneHour, .fiveHours, .day, .week, .month] {
            check("future rows: \(period.rawValue) holds the calls up to now + one day only (\(total(period)), \(calls(period)) calls)",
                  total(period) == 111 && calls(period) == 3)
        }
        check("future rows: all holds every call (\(total(.all)), \(calls(.all)) calls)", total(.all) == 111_111 && calls(.all) == 6)
        let tide = book.report(for: .oneHour).tide
        check("future rows: the 1h picture's buckets hold the same 111", tide.map { $0.tokens.values.flatMap { $0 }.reduce(0, +) } == 111)
    } catch { check("future rows: \(error)", false) }

    // MARK: 4  the wait between price passes

    do {
        let hour = 3600.0
        let waits = [0, 1, 2, 3, 4, 5, 9, 63, 64, 1000, Int.max].map { PriceSchedule.wait(failuresInARow: $0) }
        check("price pass wait: six hours after a success, then 1, 2, 4, 6, 6 ... hours after failures in a row (\(waits.map { Int($0 / hour * 10) }))",
              waits == [6, 1, 2, 4, 6, 6, 6, 6, 6, 6, 6].map { $0 * hour })
        check("price pass wait: a remembered failure that ends sooner shortens it, one that ends later does not",
              PriceSchedule.wait(failuresInARow: 0, retryIn: 600) == 600 && PriceSchedule.wait(failuresInARow: 3, retryIn: 600.2) == 601
              && PriceSchedule.wait(failuresInARow: 0, retryIn: 9 * hour) == 6 * hour && PriceSchedule.wait(failuresInARow: 2, retryIn: 5 * hour) == 2 * hour
              && PriceSchedule.wait(failuresInARow: 0, retryIn: -5) == 1)

        let dir = URL(fileURLWithPath: try tempDir(), isDirectory: true)
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000)), fetcher = ScriptedFetcher()   // every source fails
        var config = PriceFeed.Config(cacheDirectory: dir, offline: false, fetcher: fetcher)
        config.now = { clock.now }
        let feed = PriceFeed(config)
        var count = 0
        var seen: [Double] = []
        let first = feed.refreshBlocking()
        count = PriceSchedule.failures(after: first, was: count)
        seen.append(PriceSchedule.wait(failuresInARow: count, retryIn: first.retryIn))
        clock.advance(600)                       // the app woke early: the feed still remembers the failure, and asks nobody
        let second = feed.refreshBlocking()
        count = PriceSchedule.failures(after: second, was: count)
        seen.append(PriceSchedule.wait(failuresInARow: count, retryIn: second.retryIn))
        clock.advance(hour)
        let third = feed.refreshBlocking()
        count = PriceSchedule.failures(after: third, was: count)
        seen.append(PriceSchedule.wait(failuresInARow: count, retryIn: third.retryIn))
        check("price pass after a failure: 1 h, the same failure still counted once when woken early (3000 s left), then 2 h (\(seen), \(fetcher.count()) asks)",
              first.failed.count == 3 && second.failed.isEmpty && second.skipped.count == 3 && second.retryIn == 3000
              && third.failed.count == 3 && seen == [hour, 3000, 2 * hour] && fetcher.count() == 6)
        check("price pass: a success or offline sets the count back", PriceSchedule.failures(after: PriceRefreshReport(), was: 3) == 0 && PriceSchedule.failures(after: nil, was: 3) == 0)
    } catch { check("price pass wait: \(error)", false) }

    // MARK: 5  the price cache of a home of its own

    do {
        let dir = try tempDir()
        func cache(_ home: String, input: String) {
            let text = #"{"data":[{"id":"acme/zz-cache-model","name":"Acme: ZZ","pricing":{"prompt":"\#(input)","completion":"0.00001"}}]}"#
            let fetcher = ScriptedFetcher()
            fetcher.script(.openrouter, .ok(text, etag: "o"))
            let folder = URL(fileURLWithPath: home + "/Library/Caches/TokenBar", isDirectory: true)
            _ = PriceFeed(PriceFeed.Config(cacheDirectory: folder, offline: false, fetcher: fetcher)).refreshBlocking()
        }
        cache(dir + "/home", input: "0.000003")        // $3 per 1M tokens: the home's own
        cache(dir + "/user", input: "0.000007")        // $7: the account's, which `--home` must not read
        let moved = probe("fix904-cache", dir: dir, env: ["HOME": dir + "/user", "CFFIXED_USER_HOME": dir + "/user"])
        check("--home: prices come from that home's Library/Caches/TokenBar, not the account's (\(moved.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
              moved.status == 0 && moved.out.contains("input=3.0"))
        let own = probe("fix904-cache", dir: dir, env: ["HOME": dir + "/home", "CFFIXED_USER_HOME": dir + "/home"])
        check("the account's own home reads its own cache as before (\(own.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
              own.status == 0 && own.out.contains("input=3.0"))
        let bare = try tempDir()
        let none = probe("fix904-cache", dir: bare, env: ["HOME": dir + "/user", "CFFIXED_USER_HOME": dir + "/user"])
        check("--home with no cache of its own falls back to the embedded snapshot, not the account's cache (\(none.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
              none.status == 0 && none.out.contains("input=-1.0"))
    } catch { check("home price cache: \(error)", false) }
}
