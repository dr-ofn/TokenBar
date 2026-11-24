import CryptoKit
import Foundation
import SQLite3
import LocalCore

// Checks for the findings of the independent review of the published 9.0.4 (Mac side), 9.0.5 patch.
// Called once from `main.swift`; every case builds a small home and scans it in this process or in a child.
// `TokenChecks --probe fix905-only <dir>` runs just these (the rest of the run takes minutes).
//
//   1  a folder under a tool's root that cannot be read is named as a scan issue; the readable files still count
//   2  a line over 256 MiB in a plain log is skipped in bounded memory, named once; shorter lines still count
//   3  a .jsonl that is a FIFO (not a regular file) is skipped, never opened
//   4  tokenbar-cli --home without --db keeps the index inside that home
//   5  a catalogue row that says true/false for a number is dropped (model-aliases.json keeps bool as 1/0)
//   6  a report with many unpriced model names is built in linear time
//   7  token counts that round up to a thousand/million read in the next unit
//   8  one unknown saved preference leaves the others as they were
//   9  the notice under the picture names the first few issues and counts the rest
//  10  the refresh checks set their own TOKENBAR_OFFLINE
//  11  a catalogue's model name holds no control or bidi characters

func fix905Probe(_ name: String, dir: String) -> String? {
    switch name {
    case "fix905-only":
        var count = 0
        func tempDir() throws -> String {
            count += 1
            let path = dir + "/c\(count)"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        do { try fix905Checks(tempDir: tempDir) } catch { check("fix905: \(error)", false) }
        return failures == 0 ? "ALL FIX905 PASS" : "\(failures) FAILED"
    case "fix905-long":
        // The home of the caller, scanned twice; the peak memory is this process's own (a child of the run).
        guard let store = try? UsageStore(path: dir + "/usage.sqlite") else { return "store error" }
        let scanner = UsageScanner(store: store, home: dir + "/home", environment: [:])
        let first = scanner.scan(), second = scanner.scan()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let offsets = ((try? store.fileRecords()) ?? [:]).values.map { "\($0.offset)/\($0.size)" }.sorted().joined(separator: ",")
        let named = first.issues.map { $0.message.components(separatedBy: ": ").last ?? "" }.joined(separator: "|")
        return "events=\(first.events) issues=\(first.issues.count) again=\(second.issues.count) offsets=\(offsets) maxrss=\(usage.ru_maxrss) named=\(named) first=\(first.issues.first?.message ?? "-")"
    case "fix905-many":
        // `dir`/usage.sqlite holds N calls of N different models that no table or catalogue prices.
        guard let store = try? UsageStore(path: dir + "/usage.sqlite") else { return "store error" }
        let n = Int(ProcessInfo.processInfo.environment["FIX905_N"] ?? "") ?? 20_000
        let events = (0..<n).map { (i: Int) -> UsageEvent in
            UsageEvent(key: "cc:m\(i)", provider: "anthropic", model: "zz-req-\(i)-x", timestamp: 1793968800 + Double(i % 3000),
                       tokens: TokenCounts(input: Int64(10 + i % 7)), session: "s", file: "f")
        }
        guard (try? store.insertEvents(events)) != nil else { return "insert error" }
        let started = Date()
        guard let book = try? store.usageBook(now: Date(timeIntervalSince1970: 1793970000)) else { return "report error" }
        let report = book.report(for: .all)
        let seconds = Date().timeIntervalSince(started)
        let first = report.unpriced.first?.model ?? "-", last = report.unpriced.last?.model ?? "-"
        return "unpriced=\(report.unpriced.count) groups=\(report.groups.count) calls=\(report.callCount) first=\(first) last=\(last) seconds=\(String(format: "%.2f", seconds))"
    default:
        return nil
    }
}

/// A file of `zeros` NUL bytes (sparse: no disk, no time), then `tail`.
private func sparseFile905(_ path: String, zeros: Int, tail: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(fd) }
    guard ftruncate(fd, off_t(zeros)) == 0 else { throw CocoaError(.fileWriteUnknown) }
    let bytes = Array(tail.utf8)
    _ = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress!, bytes.count, off_t(zeros)) }
}

private func claudeRow905(_ id: String, model: String = "claude-opus-5-5", tokens: Int, time: String = "2026-11-06T10:00:00.000Z") -> String {
    #"{"type":"assistant","timestamp":"\#(time)","sessionId":"s1","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(tokens),"output_tokens":1}}}"#
}

func fix905Checks(tempDir: () throws -> String) throws {
    PriceBook.install(catalogs: .embedded)

    // MARK: 0  a pipe given to the line reader (Qwen's usage_record.jsonl is read without the scanner's file check)

    do {
        let dir = try tempDir(), fifo = dir + "/usage_record.jsonl"
        check("line reader: the test pipe is made", mkfifo(fifo, 0o600) == 0)
        let done = DispatchSemaphore(value: 0)
        var result: LineReader.Result?
        Thread.detachNewThread {
            result = try? LineReader.forEachLine(path: fifo, from: 0) { (_: UnsafeRawBufferPointer) -> Bool in true }
            done.signal()
        }
        let returned = done.wait(timeout: .now() + 5) == .success
        check("line reader: a pipe is not opened for reading, nothing blocks (returned: \(returned))", returned && result?.bytesRead == 0 && result?.endOffset == 0)
    } catch { check("line reader pipe: \(error)", false) }

    // A socket under a log's name cannot even be opened: it is looked at first and reads as nothing, not as a missing file.
    do {
        let sockPath = NSTemporaryDirectory() + "tb905-\(getpid()).jsonl"
        unlink(sockPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sockPath.utf8)
        let bound: Bool = bytes.count < MemoryLayout.size(ofValue: addr.sun_path) && withUnsafeMutableBytes(of: &addr.sun_path) { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            raw.copyBytes(from: bytes + [0])
            return true
        } && withUnsafePointer(to: &addr) { (ptr: UnsafePointer<sockaddr_un>) -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { (sa: UnsafePointer<sockaddr>) -> Bool in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        defer { close(fd); unlink(sockPath) }
        if bound {
            let r = try? LineReader.forEachLine(path: sockPath, from: 0) { (_: UnsafeRawBufferPointer) -> Bool in true }
            check("line reader: a socket reads as nothing, no error (\(r.map { "\($0.bytesRead)" } ?? "threw"))", r?.bytesRead == 0 && r?.endOffset == 0)
        } else {
            skip("line reader: a socket", "no Unix socket could be made in the temporary folder")
        }
    }

    // A tool's folder that is a file, not a folder: no logs and no problem (as on Windows).
    do {
        let dir = try tempDir(), h = dir + "/home"
        try write(h + "/.claude/projects", "not a folder\n")
        let r = UsageScanner(store: try UsageStore(path: dir + "/usage.sqlite"), home: h, environment: [:]).scan()
        check("a root that is a file: no issue (\(r.issues.map(\.message)))", r.issues.isEmpty && r.events == 0)
    } catch { check("root that is a file: \(error)", false) }

    // MARK: 1  a folder that cannot be read

    do {
        let dir = try tempDir(), h = dir + "/home"
        try write(h + "/.claude/projects/pa/a.jsonl", claudeRow905("a1", tokens: 100) + "\n")
        try write(h + "/.claude/projects/pb/b.jsonl", claudeRow905("b1", tokens: 200) + "\n")
        try write(h + "/.claude/projects/pc/deep/c.jsonl", claudeRow905("c1", tokens: 400) + "\n")
        defer { chmod(h + "/.claude/projects/pb", 0o755) }
        chmod(h + "/.claude/projects/pb", 0)
        let store = try UsageStore(path: dir + "/usage.sqlite")
        let result = UsageScanner(store: store, home: h, environment: [:]).scan()
        let named = result.issues.filter { $0.message.hasPrefix(h + "/.claude/projects/pb: ") }
        check("unreadable folder: named as one scan issue with the folder (\(result.issues.map(\.message)))", named.count == 1 && result.issues.count == 1)
        check("unreadable folder: the issue says it cannot be read", named.first.map { $0.message.hasSuffix(L10n.t("okunamıyor", "cannot be read")) } ?? false)
        check("unreadable folder: the readable files still count (\(result.events) events)", result.events == 2)
        let second = UsageScanner(store: store, home: h, environment: [:]).scan()
        check("unreadable folder: named again on the next pass, once", second.issues.filter { $0.message.hasPrefix(h + "/.claude/projects/pb: ") }.count == 1)
        chmod(h + "/.claude/projects/pb", 0o755)
        let third = UsageScanner(store: store, home: h, environment: [:]).scan()
        check("unreadable folder: readable again, no issue and its file counts (\(third.issues.count) issues, \(third.events) events)",
              third.issues.isEmpty && third.events == 1)
        // A root reached through a symbolic link (/var -> /private/var, a dotfiles manager): the files are found and the issue
        // names the folder in the link's spelling.
        let link = dir + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: h)
        chmod(h + "/.claude/projects/pb", 0)
        defer { chmod(h + "/.claude/projects/pb", 0o755) }
        let viaLink = UsageScanner(store: try UsageStore(path: dir + "/link.sqlite"), home: link, environment: [:]).scan()
        check("root behind a symbolic link: the readable files count and the unreadable folder is named once (\(viaLink.events) events, \(viaLink.issues.map(\.message)))",
              viaLink.events == 2 && viaLink.issues.count == 1 && viaLink.issues[0].message.hasSuffix("/.claude/projects/pb: " + L10n.t("okunamıyor", "cannot be read")))
        let empty = try tempDir()
        let none = UsageScanner(store: try UsageStore(path: empty + "/usage.sqlite"), home: empty + "/nohome", environment: [:]).scan()
        check("missing root: no issue (as before)", none.issues.isEmpty)
        // The root itself a symbolic link (~/.claude/projects kept on another disk): followed, as in 9.0.4 and on Windows.
        let sl = try tempDir(), sh = sl + "/home"
        try write(sl + "/elsewhere/projects/pa/a.jsonl", claudeRow905("s1", tokens: 100) + "\n")
        try write(sl + "/elsewhere/projects/pb/deep/b.jsonl", claudeRow905("s2", tokens: 200) + "\n")
        try FileManager.default.createDirectory(atPath: sh + "/.claude", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sh + "/.claude/projects", withDestinationPath: sl + "/elsewhere/projects")
        let linked = UsageScanner(store: try UsageStore(path: sl + "/usage.sqlite"), home: sh, environment: [:]).scan()
        check("root that is a symbolic link: its files are found, no issue (\(linked.events) events, \(linked.issues.map(\.message)))", linked.events == 2 && linked.issues.isEmpty)
        // A root whose way cannot be walked (a parent without permission) is there, not missing: named, as on Windows.
        let up = try tempDir(), uh = up + "/home"
        try write(uh + "/.claude/projects/pa/a.jsonl", claudeRow905("u1", tokens: 100) + "\n")
        chmod(uh + "/.claude", 0)
        defer { chmod(uh + "/.claude", 0o755) }
        let blocked = UsageScanner(store: try UsageStore(path: up + "/usage.sqlite"), home: uh, environment: [:]).scan()
        let rootNamed = blocked.issues.filter { $0.message == uh + "/.claude/projects: " + L10n.t("okunamıyor", "cannot be read") }
        check("root behind a parent without permission: named once (\(blocked.issues.map(\.message)))", rootNamed.count == 1 && blocked.issues.count == 1)
        chmod(uh + "/.claude", 0o755)
    } catch { check("unreadable folder: \(error)", false) }

    // MARK: 2  a line over 256 MiB in a plain log

    do {
        // Through the reader, with a small limit so the edges can be tried: a line counts with its newline, as in Windows.
        let dir = try tempDir()
        let limit = 1 << 20
        func lines(_ parts: [[UInt8]], consumeTrailing: Bool = true, chunk: Int = 64 << 10) throws -> (got: [Int], end: UInt64, skipped: Int, size: Int) {
            let path = dir + "/r\(UUID().uuidString).jsonl"
            let all = parts.flatMap { $0 }
            try Data(all).write(to: URL(fileURLWithPath: path))
            var got: [Int] = []
            let r = try LineReader.forEachLine(path: path, from: 0, chunkSize: chunk, maxLine: limit, consumeTrailingLine: consumeTrailing) { line in
                got.append(line.count); return true
            }
            return (got, r.endOffset, r.skippedLines, all.count)
        }
        func json(_ size: Int) -> [UInt8] { Array(#"{"a":1}"#.utf8) + [UInt8](repeating: 0x20, count: size - 7) }
        let nl: [UInt8] = [0x0A]
        let exact = try lines([json(limit - 1), nl, json(9), nl])
        check("reader: a line of exactly the limit with its newline is delivered (\(exact.got), skipped \(exact.skipped))",
              exact.got == [limit - 1, 9] && exact.skipped == 0 && exact.end == UInt64(exact.size))
        let over = try lines([json(limit), nl, json(9), nl, json(limit + 5000), nl, json(11), nl])
        check("reader: a line one byte over is skipped, the shorter ones around it are delivered, the offset ends the file (\(over.got), skipped \(over.skipped))",
              over.got == [9, 11] && over.skipped == 2 && over.end == UInt64(over.size))
        let big = try lines([json(5 * limit), nl, json(13), nl], chunk: 4 << 10)
        check("reader: a line five times the limit is skipped and the next one read (\(big.got))", big.got == [13] && big.skipped == 1 && big.end == UInt64(big.size))
        let open = try lines([json(7), nl, json(limit + 100)])
        check("reader: an unterminated tail over the limit is not delivered, not consumed, and named (end \(open.end), \(open.skipped))",
              open.got == [7] && open.skipped == 1 && open.end == 8)
        let tailOK = try lines([json(7), nl, json(limit)])
        check("reader: an unterminated whole-JSON tail of exactly the limit is delivered (\(tailOK.got))", tailOK.got == [7, limit] && tailOK.skipped == 0 && tailOK.end == UInt64(tailOK.size))
        let crlf = try lines([json(limit - 2), [0x0D, 0x0A], json(limit - 1), [0x0D, 0x0A], json(9), nl])
        check("reader: CR counts toward the limit, as in Windows (\(crlf.got))", crlf.got == [limit - 2, 9] && crlf.skipped == 1)

        // Through the scanner, at the real limit: a sparse file, bounded memory, named once.
        let a = try tempDir()
        try sparseFile905(a + "/home/.claude/projects/p/big.jsonl", zeros: 300 << 20, tail: "\n" + claudeRow905("ok", tokens: 70) + "\n")
        try write(a + "/home/.claude/projects/p/small.jsonl", claudeRow905("small", tokens: 30) + "\n")
        let r = probe("fix905-long", dir: a)
        let size = (300 << 20) + 1 + claudeRow905("ok", tokens: 70).utf8.count + 1
        check("300 MiB line then a call: the call counts, the line is named once, the offset is the end, memory stays small (\(r.out))",
              r.status == 0 && r.out.contains("events=2 issues=1 again=0") && r.out.contains("\(size)/\(size)") && rss905(r.out) < 300_000_000
              && r.out.contains("256 MiB"))
        let b = try tempDir()
        try sparseFile905(b + "/home/.claude/projects/p/nul.jsonl", zeros: 600 << 20, tail: "")
        try write(b + "/home/.claude/projects/p/small.jsonl", claudeRow905("small", tokens: 30) + "\n")
        let rb = probe("fix905-long", dir: b)
        check("600 MiB of one unterminated line: the other file counts, the big one is named, peak memory under 300 MB (\(rb.out))",
              rb.status == 0 && rb.out.contains("events=1 issues=1 again=1") && rss905(rb.out) < 300_000_000)
    } catch { check("long line: \(error)", false) }

    // MARK: 3  a log name that is not a regular file

    do {
        let dir = try tempDir(), h = dir + "/home"
        try write(h + "/.claude/projects/p/real.jsonl", claudeRow905("r1", tokens: 100) + "\n")
        let fifo = h + "/.claude/projects/p/pipe.jsonl"
        guard mkfifo(fifo, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createSymbolicLink(atPath: h + "/.claude/projects/p/null.jsonl", withDestinationPath: "/dev/null")
        try FileManager.default.createDirectory(atPath: h + "/.claude/projects/p/folder.jsonl", withIntermediateDirectories: true)
        // A child with a deadline: a scan that opens the FIFO never returns.
        let r = probeWithDeadline905("fix905-long", dir: dir, seconds: 20)
        check("FIFO and device named .jsonl: skipped, no hang, no issue; a folder named .jsonl is still named as before (\(r.status): \(r.out))",
              r.status == 0 && r.out.contains("events=1 issues=1 again=1") && r.out.contains("folder.jsonl"))
    } catch { check("not a regular file: \(error)", false) }

    // MARK: 4  tokenbar-cli --home without --db

    do {
        let dir = try tempDir()
        let realHome = dir + "/realhome", fake = dir + "/fakehome"
        try write(fake + "/.claude/projects/p/s.jsonl", claudeRow905("h1", tokens: 100) + "\n")
        try FileManager.default.createDirectory(atPath: realHome, withIntermediateDirectories: true)
        let env = ["HOME": realHome, "CFFIXED_USER_HOME": realHome, "TOKENBAR_PRICES_PINNED": "1"]
        if let r = runCLI905(["--home", fake, "--window", "all", "--offline"], environment: env) {
            // Never inside the home that is read (it may be a read-only backup, as on Windows), never the user's own
            // index: an index of its own beside it, <own>/homes/<first 16 hex of SHA-256 of the home's real path>.
            let written = FileManager.default.fileExists(atPath: fake + "/Library")
            let own = FileManager.default.fileExists(atPath: realHome + "/Library/Application Support/TokenBar/usage.sqlite")
            let expected = realHome + "/Library/Application Support/TokenBar/homes/" + homeDigest905(fake) + "/usage.sqlite"
            let separate = FileManager.default.fileExists(atPath: expected)
            check("cli --home without --db: an index of its own beside the user's, nothing in the home read (\(r.status), in home \(written), own \(own), separate \(separate))",
                  r.status == 0 && !written && !own && separate && r.out.contains("1 çağrı"))
            let again = runCLI905(["--home", fake, "--window", "all", "--offline", "--no-scan"], environment: env)
            check("cli --home without --db: the second run reads the same index (\(again?.out ?? "-"))", again?.out.contains("1 çağrı") ?? false)
            let plain = runCLI905(["--window", "all", "--offline", "--no-scan"], environment: env)
            check("cli without --home: the user's own index path as before (\(plain?.status ?? -1))",
                  plain?.status == 0 && FileManager.default.fileExists(atPath: realHome + "/Library/Application Support/TokenBar/usage.sqlite"))
            // The same home by another spelling (a link to it) is the same index and the same files: nothing read twice.
            let alias = dir + "/fakelink"
            try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fake)
            let viaLink = runCLI905(["--home", alias, "--window", "all", "--offline"], environment: env)
            let index = runCLI905(["--home", alias, "--index"], environment: env)
            check("cli --home by two spellings: one index, one file record, one call (\(viaLink?.out.split(separator: "\n").first ?? "-") / \(index?.out.split(separator: "\n").first ?? "-"))",
                  viaLink?.out.contains("1 çağrı") == true && (index?.out.contains(L10n.t("dosya: 1", "files: 1")) ?? false))
            // A home that is not there yet gets the index it will have once it appears (resolved through its parent).
            let later = dir + "/later/./"
            _ = runCLI905(["--home", later, "--window", "all", "--offline"], environment: env)
            try write(dir + "/later/.claude/projects/p/s.jsonl", claudeRow905("h9", tokens: 100) + "\n")
            _ = runCLI905(["--home", dir + "/later", "--window", "all", "--offline"], environment: env)
            let homes = (try? FileManager.default.contentsOfDirectory(atPath: realHome + "/Library/Application Support/TokenBar/homes")) ?? []
            check("cli --home not there yet, then there: one index for it (\(homes.count) indexes for 3 homes)", homes.count == 2)
            let explicit = runCLI905(["--home", fake, "--db", dir + "/mine.sqlite", "--window", "all", "--offline"], environment: env)
            check("cli --home with --db: that db", explicit?.status == 0 && FileManager.default.fileExists(atPath: dir + "/mine.sqlite"))
        } else {
            skip("cli --home without --db", "tokenbar-cli is not built beside TokenChecks (swift build -c release)")
        }
    } catch { check("cli home: \(error)", false) }

    // MARK: 5  a catalogue that says true for a number

    do {
        func kept(litellm: String = "{}", modelsdev: String = "{}") -> [String: [String: [Any]]] {
            PriceTools.keptRows(litellm: Data(litellm.utf8), modelsdev: Data(modelsdev.utf8))
        }
        func row(_ k: [String: [String: [Any]]], _ source: String, _ id: String) -> [Any]? { k[source]?[id] }
        func num(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? -1 }
        func tiers(_ r: [Any]?) -> Int { ((r?.count ?? 0) > 5 ? (r?[5] as? [Any])?.count : 0) ?? 0 }
        let ll = kept(litellm: #"""
        {"good": {"mode":"chat","input_cost_per_token":1e-6,"output_cost_per_token":2e-6},
         "bool-in": {"mode":"chat","input_cost_per_token":true,"output_cost_per_token":2e-6},
         "bool-out": {"input_cost_per_token":1e-6,"output_cost_per_token":false},
         "bool-cache": {"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"cache_read_input_token_cost":true},
         "tier-bool": {"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"input_cost_per_token_above_200k_tokens":true},
         "tier-real": {"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"input_cost_per_token_above_200k_tokens":3e-6},
         "mode-num": {"mode":5,"input_cost_per_token":1e-6,"output_cost_per_token":2e-6},
         "mode-true": {"mode":true,"input_cost_per_token":1e-6,"output_cost_per_token":2e-6},
         "mode-null": {"mode":null,"input_cost_per_token":1e-6,"output_cost_per_token":2e-6},
         "mode-embedding": {"mode":"embedding","input_cost_per_token":1e-6,"output_cost_per_token":2e-6}}
        """#)
        check("litellm: a good row is kept (control)", row(ll, "litellm", "good") != nil)
        check("litellm: true as the input price drops the row (it was a million dollars)", row(ll, "litellm", "bool-in") == nil)
        check("litellm: false as the output price drops the row", row(ll, "litellm", "bool-out") == nil)
        check("litellm: true as the cache price is 0, not 1", num(row(ll, "litellm", "bool-cache")?[2]) == 0 && row(ll, "litellm", "bool-cache") != nil)
        check("litellm: true as a tier price makes no tier; a real one does", tiers(row(ll, "litellm", "tier-bool")) == 0 && tiers(row(ll, "litellm", "tier-real")) == 1)
        check("litellm: a mode that is a number or a boolean drops the row, null does not, a word that is not chat does", row(ll, "litellm", "mode-num") == nil
              && row(ll, "litellm", "mode-true") == nil && row(ll, "litellm", "mode-null") != nil && row(ll, "litellm", "mode-embedding") == nil)

        let md = kept(modelsdev: #"""
        {"p": {"models": {
          "good": {"cost": {"input": 1, "output": 2}},
          "bool-in": {"cost": {"input": true, "output": 2}},
          "bool-cache": {"cost": {"input": 1, "output": 2, "cache_read": true}},
          "tier-size-bool": {"cost": {"input": 1, "output": 2, "tiers": [{"tier": {"type": "context", "size": true}, "input": 3}]}},
          "tier-price-bool": {"cost": {"input": 1, "output": 2, "tiers": [{"tier": {"type": "context", "size": 200000}, "input": true}]}},
          "over-bool": {"cost": {"input": 1, "output": 2, "context_over_200k": {"input": true}}}
        }}}
        """#)
        check("models.dev: a good row is kept (control)", row(md, "modelsdev", "p/good") != nil)
        check("models.dev: true as the input price drops the row", row(md, "modelsdev", "p/bool-in") == nil)
        check("models.dev: true as the cache price is 0", num(row(md, "modelsdev", "p/bool-cache")?[2]) == 0 && row(md, "modelsdev", "p/bool-cache") != nil)
        check("models.dev: true as a tier size drops the row", row(md, "modelsdev", "p/tier-size-bool") == nil)
        check("models.dev: true as a tier price is 0 there, and a tier priced 0 drops the row (as on Windows), not a tier at a dollar", row(md, "modelsdev", "p/tier-price-bool") == nil)
        check("models.dev: true in a context_over_200k price drops the row the same way", row(md, "modelsdev", "p/over-bool") == nil)

        let or = #"{"data":[{"id":"acme/zz-or-good","pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"acme/zz-or-bool","pricing":{"prompt":true,"completion":"0.000002"}}]}"#
        PriceBook.install(catalogs: PriceCatalogs.fromRaw([.openrouter: Data(or.utf8)]))
        check("openrouter: a good row prices, true as the prompt price does not", ModelPrice(model: "acme/zz-or-good").entry != nil && ModelPrice(model: "acme/zz-or-bool").entry == nil)
        PriceBook.install(catalogs: .embedded)

        // model-aliases.json keeps its reading (9.0.3): true is 1, false is 0
        let alias = UserAliases(json: Data(#"{"aliases":{"zz-a":{"input":true,"output":2},"zz-b":{"input":1,"output":false}}}"#.utf8))
        if case .rates(let input, let output, _, _, _, _, _)? = alias.targets[ModelNames.keys("zz-a").key1] {
            check("model-aliases.json: true is still 1 (accepted in 9.0.3)", input == 1 && output == 2)
        } else { check("model-aliases.json: true is still 1 (accepted in 9.0.3)", false) }
        check("model-aliases.json: false is 0, so the entry is no price", alias.targets[ModelNames.keys("zz-b").key1] == nil)
    }

    // MARK: 6  a report of thousands of models that have no price

    do {
        let dir = try tempDir()
        let r = probeWithDeadline905("fix905-many", dir: dir, seconds: 90)
        let seconds = r.out.range(of: "seconds=").flatMap { Double(r.out[$0.upperBound...].prefix { $0.isNumber || $0 == "." }) } ?? .infinity
        check("20 000 unpriced model names: every one listed once, in the order of the biggest first, in seconds (\(r.status): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
              r.status == 0 && r.out.contains("unpriced=20000 groups=20000 calls=20000") && seconds < 10)
    } catch { check("many unpriced: \(error)", false) }

    // MARK: 7  a count that rounds up to the next unit

    do {
        defer { L10n.setLanguage(.tr) }
        let counts: [Int64] = [999, 1000, 999_949, 999_950, 999_951, 999_999, 1_000_000, 1_049_949, 999_949_999, 999_950_000, 999_999_999, 1_000_000_000]
        L10n.setLanguage(.tr)
        let tr = counts.map { UsageText.tokens($0) }
        check("token text (tr): a count that rounds up to a thousand reads in the next unit (\(tr))",
              tr == ["999", "1,0 bin", "999,9 bin", "1,0 milyon", "1,0 milyon", "1,0 milyon", "1,0 milyon", "1,0 milyon", "999,9 milyon", "1,00 milyar", "1,00 milyar", "1,00 milyar"])
        L10n.setLanguage(.en)
        let en = counts.map { UsageText.tokens($0) }
        check("token text (en): the same (\(en))", en == ["999", "1.0K", "999.9K", "1.0M", "1.0M", "1.0M", "1.0M", "1.0M", "999.9M", "1.00B", "1.00B", "1.00B"])
        L10n.setLanguage(.tr)
        check("token text: nothing reads 1.000 any more, up to a hundred billion",
              (0..<5000).map { Int64($0) * 20_000_000 + 999_950 }.allSatisfy { !UsageText.tokens($0).hasPrefix("1.000") && !UsageText.tokens($0).hasPrefix("1,000") }
              && !UsageText.compact(999_999).contains("1.000"))
    }

    // MARK: 11  a model name that came over the network

    do {
        func banned(_ text: String) -> Bool {
            text.unicodeScalars.contains { (u: Unicode.Scalar) -> Bool in
                u.value < 0x20 || (0x7F...0x9F).contains(u.value) || (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value)
            }
        }
        let evil = "Evil: \u{1B}[2J\u{1B}]0;pwned\u{07}AAAA\u{202E}BBBB\u{2066}CC\u{2069}\u{85}\u{9B}DD\r\nEE\u{7F}"
        let or = ["data": [["id": "evil/zz-or-name", "name": evil, "pricing": ["prompt": "0.000001", "completion": "0.000002"]]]]
        let md = ["p": ["models": ["zz-md-name": ["name": evil, "cost": ["input": 1, "output": 2]]]]]
        PriceBook.install(catalogs: PriceCatalogs.fromRaw([.openrouter: try JSONSerialization.data(withJSONObject: or),
                                                           .modelsdev: try JSONSerialization.data(withJSONObject: md)]))
        defer { PriceBook.install(catalogs: .embedded) }
        let fromOR = ModelPrice(model: "evil/zz-or-name").entry?.name ?? "-"
        let fromMD = ModelPrice(model: "p/zz-md-name").entry?.name ?? "-"
        check("openrouter name: no control, C1 or bidi character reaches the name (\(fromOR.debugDescription))",
              !banned(fromOR) && fromOR.contains("AAAA") && fromOR.contains("BBBB") && fromOR.contains("DD") && fromOR.contains("EE"))
        check("models.dev name: the same (\(fromMD.debugDescription))", !banned(fromMD) && fromMD.contains("AAAA") && fromMD.contains("EE"))
        check("the source line names the catalogue row without those characters", !banned(ModelPrice(model: "evil/zz-or-name").entry?.source ?? "\u{1}"))
        let onlyControls = [["id": "acme/zz-ctl-only", "name": "\u{1B}\u{202E}", "pricing": ["prompt": "0.000001", "completion": "0.000002"]]]
        PriceBook.install(catalogs: PriceCatalogs.fromRaw([.openrouter: try JSONSerialization.data(withJSONObject: ["data": onlyControls])]))
        check("a name that is nothing but such characters falls back to the id's readable form, never empty",
              !(ModelPrice(model: "acme/zz-ctl-only").entry?.name.isEmpty ?? true))
        let plain = [["id": "acme/zz-plain", "name": "Acme: Türkçe İğüşöç ‍ Model-1 (beta)", "pricing": ["prompt": "0.000001", "completion": "0.000002"]]]
        PriceBook.install(catalogs: PriceCatalogs.fromRaw([.openrouter: try JSONSerialization.data(withJSONObject: ["data": plain])]))
        check("a plain name, Turkish letters and a zero-width joiner included, is left as it is",
              ModelPrice(model: "acme/zz-plain").entry?.name == "Türkçe İğüşöç ‍ Model-1 (beta)")
    } catch { check("catalogue name: \(error)", false) }
}


/// `maxrss=N` of a probe's line.
private func rss905(_ out: String) -> Int {
    guard let range = out.range(of: "maxrss=") else { return Int.max }
    return Int(out[range.upperBound...].prefix { $0.isNumber }) ?? Int.max
}

/// `probe` that gives up after `seconds` (status -9 and no output): for a case that hangs when it is broken.
private func probeWithDeadline905(_ name: String, dir: String, seconds: Double) -> (status: Int32, out: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--probe", name, dir]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}


/// The `homes/` folder name tokenbar-cli gives another home's index (the Windows `home_index_path` rule).
private func homeDigest905(_ home: String) -> String {
    let real: String = {
        guard let p = realpath(home, nil) else { return home }
        defer { free(p) }
        return String(cString: p)
    }()
    return String(SHA256.hash(data: Data(real.utf8)).map { (b: UInt8) -> String in String(format: "%02x", b) }.joined().prefix(16))
}

/// Runs the built `tokenbar-cli` beside TokenChecks; nil when it is not built.
private func runCLI905(_ arguments: [String], environment: [String: String]) -> (status: Int32, out: String)? {
    let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("tokenbar-cli").path
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
