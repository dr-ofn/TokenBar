import Foundation
import SQLite3
import LocalCore

// Checks for the findings of the independent review of the published 9.0.6 (Mac side), 9.0.7 patch.
// Called once from `main.swift`; every case builds a small home and scans it in this process or in a child.
// `TokenChecks --probe fix907-only <dir>` runs just these (the rest of the run takes minutes).
// The cache warning's life in the app (findings on `updatePrices`) is checked in `UISnapshot selfcheck`.
//
//   1  a database that is a link (absolute or relative): the `-wal` beside the file it leads to is read and followed
//      (stamp), a main file of 0 bytes with a `-wal` counts, and no file of the user's is written, moved or deleted
//   3  a log file that cannot be read says so in one short sentence (no Foundation dump); one that went away says nothing
//   4  a JSON `true` or `false` in a usage field is no number (0), as on Windows
//   5  the total's note names the first unpriced models and counts the rest
//   6  RibbonLayout does not trap on an infinite or NaN size

func fix907Probe(_ name: String, dir: String) -> String? {
    switch name {
    case "fix907-only":
        var count = 0
        func tempDir() throws -> String {
            count += 1
            let path = dir + "/c\(count)"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        do { try fix907Checks(tempDir: tempDir) } catch { check("fix907: \(error)", false) }
        return failures == 0 ? "ALL FIX907 PASS" : "\(failures) FAILED"
    case "fix907-ribbon":
        // A size that is no number, a gap that is none: a picture without ribbons, never a trap.
        guard let store = try? UsageStore(path: dir + "/usage.sqlite") else { return "store error" }
        _ = UsageScanner(store: store, home: dir + "/home", environment: [:]).scan()
        guard let book = try? store.usageBook(now: Date(timeIntervalSince1970: 1793970000)) else { return "report error" }
        let report = book.report(for: .all)
        let sizes: [Double] = [0, -5, 1, 7, 100, 480, 5000, 1e9, 1e15, 1e300, .nan, .infinity, -.infinity, 1e-300]
        let gaps: [Double] = [14, 0, -1, .infinity, .nan, 1e-300]
        var built = 0
        for width in sizes {
            for height in sizes {
                for gap in gaps {
                    let layout = RibbonLayout(report: report, width: width, height: height, leftColumn: 104, rightColumn: 186,
                                              top: 40, bottomMargin: 12, labelGap: gap)
                    _ = layout.ribbons.count
                    built += 1
                }
            }
        }
        return "ok built=\(built) empty=\(report.isEmpty)"
    default:
        return nil
    }
}

private let ocSchema907 = "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT);"

private func ocMessage907(input: String, output: Int = 10) -> String {
    #"{"role":"assistant","providerID":"openrouter","modelID":"gpt-6-luna","tokens":{"input":\#(input),"output":\#(output),"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1793968800}}"#
}

private func ocRows907(_ ids: ClosedRange<Int>) -> String {
    ids.map { "INSERT INTO message VALUES('m\($0)','s','\(ocMessage907(input: "100"))',\($0));" }.joined()
}

private func claudeRow907(_ id: String, model: String = "claude-opus-5-5", usage: String) -> String {
    #"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"s1","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":\#(usage)}}"#
}

/// A connection that stays open, in WAL mode, never checkpointing: a tool that is running.
private final class Writer907 {
    private var db: OpaquePointer?
    init(_ path: String, _ sql: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        try run("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;" + sql)
    }
    func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 2) }
    }
    func close() { sqlite3_close(db); db = nil }
    deinit { sqlite3_close(db) }
}

/// Name, size and modification time (to the nanosecond) of everything in these folders: what a read must leave as it was.
private func snapshot907(_ folders: [String]) -> [String] {
    var out: [String] = []
    for folder in folders {
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() {
            var st = Darwin.stat()
            if lstat(folder + "/" + name, &st) == 0 {
                out.append("\(folder)/\(name):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)")
            } else {
                out.append("\(folder)/\(name):gone")
            }
        }
    }
    return out
}

func fix907Checks(tempDir: () throws -> String) throws {
    PriceBook.install(catalogs: .embedded)
    func scanned(_ dir: String) throws -> (store: UsageStore, result: ScanResult) {
        let store = try UsageStore(path: dir + "/usage.sqlite")
        return (store, UsageScanner(store: store, home: dir + "/home", environment: [:]).scan())
    }
    func report(_ store: UsageStore) throws -> UsageReport {
        try store.usageBook(now: Date(timeIntervalSince1970: 1793970000)).report(for: .all)
    }

    // MARK: 1  a database that is a link

    for relative in [false, true] {
        let label = relative ? "relative link" : "absolute link"
        do {
            let dir = try tempDir(), h = dir + "/home"
            let elsewhere = dir + "/elsewhere", real = elsewhere + "/real.db"
            let folder = h + "/.local/share/opencode"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            // Two rows in the main file (a closed database keeps WAL mode), three more only in the `-wal` of a running tool.
            try runSQL(real, "PRAGMA journal_mode=WAL;" + ocSchema907 + ocRows907(1...2))
            let writer = try Writer907(real, ocRows907(3...5))
            defer { writer.close() }
            try FileManager.default.createSymbolicLink(atPath: folder + "/opencode.db", withDestinationPath: relative ? "../../../../elsewhere/real.db" : real)
            let before = snapshot907([elsewhere, folder])
            let first = try scanned(dir)
            let calls = try report(first.store).callCount
            check("db link (\(label)): the rows that are only in the -wal beside the real file count (\(calls) of 5, issues \(first.result.issues.map(\.message)))",
                  calls == 5 && first.result.issues.isEmpty)
            check("db link (\(label)): nothing of the user's is written, moved or deleted by the read", snapshot907([elsewhere, folder]) == before)
            // The tool writes again: only the real file's -wal changes. The stamp must see it, or the rows wait for a checkpoint.
            try writer.run(ocRows907(6...8))
            let again = try scanned(dir)
            let more = try report(again.store).callCount
            check("db link (\(label)): rows the tool writes later (the real -wal only) are read on the next scan (\(more) of 8)", more == 8)
        } catch { check("db link (\(label)): \(error)", false) }
    }

    do {
        // A tool that died before its first checkpoint: the main file is 0 bytes, everything is in the -wal. SQLite deletes
        // the -wal of a 0-byte file it opens in place (the link made the read open the link's own folder): the user's file.
        let dir = try tempDir(), h = dir + "/home"
        let elsewhere = dir + "/elsewhere", real = elsewhere + "/real.db"
        let folder = h + "/.local/share/opencode"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        let live = dir + "/live.db"
        do {
            let writer = try Writer907(live, ocSchema907 + ocRows907(1...3))
            defer { writer.close() }
            try FileManager.default.copyItem(atPath: live, toPath: real)
            try FileManager.default.copyItem(atPath: live + "-wal", toPath: real + "-wal")
        }
        try Data().write(to: URL(fileURLWithPath: real))
        let wal = try Data(contentsOf: URL(fileURLWithPath: real + "-wal"))
        try FileManager.default.createSymbolicLink(atPath: folder + "/opencode.db", withDestinationPath: real)
        let before = snapshot907([elsewhere, folder])
        let (store, result) = try scanned(dir)
        let calls = try report(store).callCount
        let kept = (try? Data(contentsOf: URL(fileURLWithPath: real + "-wal"))) == wal
        check("db link, main file of 0 bytes: the rows in the -wal count (\(calls) of 3, issues \(result.issues.map(\.message)))", calls == 3 && result.issues.isEmpty)
        check("db link, main file of 0 bytes: the real -wal is still there, as it was, and nothing else changed", kept && snapshot907([elsewhere, folder]) == before)
    } catch { check("db link, 0 bytes: \(error)", false) }

    do {
        // The same without a link: a 0-byte main file beside its -wal is read from a copy too, and counts.
        let dir = try tempDir(), h = dir + "/home"
        let folder = h + "/.local/share/opencode"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let live = dir + "/live.db"
        do {
            let writer = try Writer907(live, ocSchema907 + ocRows907(1...3))
            defer { writer.close() }
            try FileManager.default.copyItem(atPath: live, toPath: folder + "/opencode.db")
            try FileManager.default.copyItem(atPath: live + "-wal", toPath: folder + "/opencode.db-wal")
        }
        try Data().write(to: URL(fileURLWithPath: folder + "/opencode.db"))
        let before = snapshot907([folder])
        let (store, result) = try scanned(dir)
        let calls = try report(store).callCount
        check("db 0 bytes beside its -wal (no link): the rows count and the folder is as it was (\(calls) of 3, issues \(result.issues.map(\.message)))",
              calls == 3 && result.issues.isEmpty && snapshot907([folder]) == before)
    } catch { check("db 0 bytes: \(error)", false) }

    // MARK: 3  a file that cannot be read

    do {
        let wording = L10n.t("okunamıyor (izin yok)", "cannot be read (no permission)")
        if getuid() == 0 {
            skip("unreadable log file", "running as root: a file mode does not stop root")
        } else {
            let dir = try tempDir(), h = dir + "/home"
            let file = h + "/.claude/projects/p/a.jsonl"
            try write(file, claudeRow907("u1", usage: #"{"input_tokens":5,"output_tokens":0}"#) + "\n")
            chmod(file, 0)
            defer { chmod(file, 0o644) }
            let (_, result) = try scanned(dir)
            let named = result.issues.filter { $0.source == "Claude Code" }.map(\.message)
            check("unreadable log: one short sentence, the path once, no Foundation dump (\(named))",
                  named == [file + ": " + wording] && !named.joined().contains("Error Domain") && !named.joined().contains("UserInfo"))
        }
        // A folder under the name of a log: named, in words, not as a dump.
        let dir2 = try tempDir(), h2 = dir2 + "/home"
        let folder = h2 + "/.claude/projects/p/a.jsonl"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (_, result2) = try scanned(dir2)
        let named2 = result2.issues.filter { $0.source == "Claude Code" }.map(\.message)
        check("folder named a.jsonl: one short sentence, no Foundation dump (\(named2))",
              named2 == [folder + ": " + L10n.t("okunamıyor (dosya değil, klasör)", "cannot be read (a folder, not a file)")])
        // A file that went between the listing and the read is nobody's problem (the next pass lists what is there).
        let gone: [Error] = [CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "/x/a.jsonl"]),
                             CocoaError(.fileNoSuchFile), NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))]
        check("a log that went away while the scan ran is no problem",
              gone.allSatisfy { (e: Error) -> Bool in UsageScanner.readProblem("/x/a.jsonl", e) == nil })
        check("a permission refusal (Cocoa or POSIX) is named in words",
              UsageScanner.readProblem("/x/a.jsonl", CocoaError(.fileReadNoPermission)) == wording
              && UsageScanner.readProblem("/x/a.jsonl", NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == wording)
        check("a message the readers wrote themselves stays as it is",
              UsageScanner.readProblem("/x/a.jsonl", StoreError(message: "unable to open database file")) == "unable to open database file")
    } catch { check("unreadable log: \(error)", false) }

    // MARK: 4  JSON true and false in a usage field

    do {
        func totals(_ usage: String) throws -> (calls: Int, total: Int64) {
            let dir = try tempDir()
            try write(dir + "/home/.claude/projects/p/a.jsonl", claudeRow907("b1", usage: usage) + "\n")
            let (store, _) = try scanned(dir)
            let r = try report(store)
            return (r.callCount, r.counts.total)
        }
        let plain = try totals(#"{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}"#)
        let booleans = try totals(#"{"input_tokens":100,"cache_read_input_tokens":true,"cache_creation_input_tokens":true,"output_tokens":true}"#)
        check("usage fields that are true are 0, not 1: the total is that of the same call with 0 (\(booleans.total) vs \(plain.total))",
              plain.calls == 1 && booleans.calls == 1 && plain.total == 100 && booleans.total == plain.total)
        let dir = try tempDir(), folder = dir + "/home/.local/share/opencode"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try runSQL(folder + "/opencode.db", ocSchema907
                   + "INSERT INTO message VALUES('b1','s','\(ocMessage907(input: "true", output: 7))',1);"
                   + "INSERT INTO message VALUES('b2','s','\(ocMessage907(input: "false", output: 7))',2);")
        let (store, _) = try scanned(dir)
        let r = try report(store)
        check("opencode: a token field that is true or false is 0 (calls \(r.callCount), total \(r.counts.total) of 14)", r.callCount == 2 && r.counts.total == 14)
    } catch { check("usage booleans: \(error)", false) }

    // MARK: 5  the note of the total

    do {
        let dir = try tempDir()
        var lines: [String] = []
        for i in 1...5000 { lines.append(claudeRow907("n\(i)", model: "zz-fix907-\(i)", usage: #"{"input_tokens":10,"output_tokens":0}"#)) }
        try write(dir + "/home/.claude/projects/p/a.jsonl", lines.joined(separator: "\n") + "\n")
        let (store, _) = try scanned(dir)
        let r = try report(store)
        let note = UsageText.totalNote(r)
        let named = note.components(separatedBy: "zz-fix907-").count - 1
        check("total note: 5000 unpriced models are 20 names and a count (unpriced \(r.unpriced.count), \(note.count) characters, \(named) names)",
              r.unpriced.count == 5000 && named == UsageText.totalNoteModelLimit && note.count < 1500
              && note.contains(L10n.t("ve 4980 tane daha", "and 4980 more")))
        let dir3 = try tempDir()
        try write(dir3 + "/home/.claude/projects/p/a.jsonl", (1...3).map { claudeRow907("f\($0)", model: "zz-fix907-\($0)", usage: #"{"input_tokens":10,"output_tokens":0}"#) }.joined(separator: "\n") + "\n")
        let (store3, _) = try scanned(dir3)
        let note3 = UsageText.totalNote(try report(store3))
        check("total note: three unpriced models are all named, none counted", note3.components(separatedBy: "zz-fix907-").count - 1 == 3 && !note3.contains(L10n.t("tane daha", "more")))
    } catch { check("total note: \(error)", false) }

    // MARK: 6  RibbonLayout with a size that is no number

    do {
        let dir = try tempDir()
        try write(dir + "/home/.claude/projects/p/a.jsonl",
                  claudeRow907("r1", usage: #"{"input_tokens":1000,"output_tokens":500}"#) + "\n"
                  + claudeRow907("r2", model: "zz-fix907-ribbon", usage: #"{"input_tokens":10,"output_tokens":0}"#) + "\n")
        let r = probe("fix907-ribbon", dir: dir)
        check("ribbon layout: an infinite, NaN or huge size and gap never trap (\(r.status): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))",
              r.status == 0 && r.out.contains("ok built=1176 empty=false"))
    } catch { check("ribbon layout: \(error)", false) }
}
