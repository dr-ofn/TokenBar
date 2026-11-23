import Foundation
import SQLite3
import LocalCore

// Checks for the findings of the independent review of the published 9.0.1 (Mac side), 9.0.2 patch.
// Called once from `main.swift`; every case builds a small home and scans it in this process.
//
//   2  with the English interface no source warning, scan error or CLI message is left in Turkish (and Turkish stays Turkish)
//   3  docs/HARNESSES: which reader families custom-sources.json can use for a new tool is what the code says
//   4  model-aliases.json: one item of localProviders that is not a string leaves the strings around it alone
//   5  a log line with invalid UTF-8 (raw bytes, or a lone surrogate escape "\\udc80" in the JSON) is read, the bad part U+FFFD
//   1  Antigravity and Zed databases are read by the opencode rule (inode:size:mtime_ns, .db and -wal each on its own),
//      so a clock set back or a backup put back is not missed; an index from 9.0.0/9.0.1 reads each of them once

private let fix902Now = Date(timeIntervalSince1970: 1793970000)
private let fix902Support = "/Library/Application Support"

private struct Scan902 {
    var calls: Int
    var tokens: Int64
    var filesRead: Int
    var issues: [String]
}

private func scan902(_ dir: String, _ home: String) throws -> Scan902 {
    let store = try UsageStore(path: dir + "/usage.sqlite")
    let result = UsageScanner(store: store, home: home, environment: [:]).scan()
    var calls = 0
    var tokens: Int64 = 0
    for stat in try store.usageBook(now: fix902Now).report(for: .all).harnesses.flatMap(\.models) {
        calls += stat.calls
        tokens += stat.tokens
    }
    let read = result.sources.reduce(0) { (sum: Int, source: SourceStat) -> Int in sum + source.filesRead }
    return Scan902(calls: calls, tokens: tokens, filesRead: read, issues: result.issues.map { (issue: SourceIssue) -> String in issue.message })
}

private func hex902(_ bytes: [UInt8]) -> String { bytes.map { (byte: UInt8) -> String in String(format: "%02x", byte) }.joined() }

private func agStep902(_ idx: Int) -> String {
    let usage = protoInt(1, 1) + protoInt(2, 7) + protoInt(3, 4) + protoInt(4, 2) + protoInt(5, 1) + protoInt(9, 1)
    let meta = protoBytes(8, protoInt(1, 1793968800 + idx)) + protoBytes(9, usage)
    return "INSERT INTO steps VALUES(\(idx),15,X'\(hex902(meta))');"
}

private func agSchema902() -> String {
    let gen = protoBytes(1, protoInt(3, 1) + protoBytes(19, Array("gemini-3.8-flash".utf8)))
    return "CREATE TABLE gen_metadata(idx INTEGER, data BLOB); CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB); "
        + "INSERT INTO gen_metadata VALUES(0,X'\(hex902(gen))');"
}

private let zedSchema902 = "CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL, data BLOB NOT NULL, created_at TEXT);"

private func zedThread902(_ id: String, input: Int) -> String {
    let json = #"{"model":{"provider":"zed.dev","model":"claude-sonnet-4-5"},"request_token_usage":{"a":{"input_tokens":\#(input)}},"cumulative_token_usage":{"input_tokens":\#(input),"output_tokens":0}}"#
    return "INSERT INTO threads VALUES('\(id)','t','2026-11-06T10:0\(id.count):00Z','json', CAST('\(json)' AS BLOB), NULL);"
}

private func setTime902(_ path: String, _ seconds: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
}

private func size902(_ path: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? -1 }

func fix902Checks(tempDir: () throws -> String) throws {
    PriceBook.install(catalogs: .embedded)

    // MARK: 1  a clock set back, a backup put back: same inode, same size, an older mtime, new rows

    do {
        let dir = try tempDir(), h = dir + "/home"
        let db = h + "/.gemini/antigravity-cli/conversations/ag-back.db"
        try runSQL(db, agSchema902() + agStep902(0))
        try setTime902(db, 1_800_000_000)
        let first = try scan902(dir, h)
        let quiet = try scan902(dir, h)
        let sizeBefore = size902(db)
        try runSQL(db, agStep902(1) + agStep902(2))
        try setTime902(db, 1_700_000_000)
        let back = try scan902(dir, h)
        let again = try scan902(dir, h)
        check("antigravity clock back: the first scan reads the conversation (1 call)", first.calls == 1 && first.filesRead == 1)
        check("antigravity clock back: an unchanged database is not read again", quiet.filesRead == 0 && quiet.calls == 1)
        check("antigravity clock back: the database kept its size (the case under test)", size902(db) == sizeBefore)
        check("antigravity clock back: the rows added under an older mtime are counted (3 calls)", back.calls == 3 && back.filesRead == 1)
        check("antigravity clock back: nothing is read or counted twice afterwards", again.filesRead == 0 && again.calls == 3)
    } catch { check("antigravity clock back: \(error)", false) }

    do {
        let dir = try tempDir(), h = dir + "/home"
        let db = h + fix902Support + "/Zed/threads/threads.db"
        try runSQL(db, zedSchema902 + zedThread902("a", input: 500))
        try setTime902(db, 1_800_000_000)
        let first = try scan902(dir, h)
        let quiet = try scan902(dir, h)
        let sizeBefore = size902(db)
        try runSQL(db, zedThread902("bb", input: 300))
        try setTime902(db, 1_700_000_000)
        let back = try scan902(dir, h)
        let again = try scan902(dir, h)
        check("zed clock back: the first scan reads the threads (500 tokens)", first.tokens == 500 && first.filesRead == 1)
        check("zed clock back: an unchanged database is not read again", quiet.filesRead == 0 && quiet.tokens == 500)
        check("zed clock back: the database kept its size (the case under test)", size902(db) == sizeBefore)
        check("zed clock back: the thread added under an older mtime is counted (800 tokens)", back.tokens == 800 && back.filesRead == 1)
        check("zed clock back: nothing is read or counted twice afterwards", again.filesRead == 0 && again.tokens == 800)
    } catch { check("zed clock back: \(error)", false) }

    // MARK: 1b  an index of 9.0.0/9.0.1 (no stamp for these databases): each is read once, nothing is counted twice

    do {
        let dir = try tempDir(), h = dir + "/home"
        let ag = h + "/.gemini/antigravity-cli/conversations/ag-up.db"
        let zed = h + fix902Support + "/Zed/threads/threads.db"
        try runSQL(ag, agSchema902() + agStep902(0) + agStep902(1))
        try runSQL(zed, zedSchema902 + zedThread902("a", input: 500))
        try setTime902(ag, 1_790_000_000)
        try setTime902(zed, 1_790_000_000)
        let before = try scan902(dir, h)
        // The index as 9.0.1 left it: the file records are there, the stamps of these databases are not.
        try runSQL(dir + "/usage.sqlite", "DELETE FROM meta WHERE k LIKE 'dbstamp:%';")
        let upgraded = try scan902(dir, h)
        let after = try scan902(dir, h)
        check("upgrade: the starting index counts both (2 calls + 500 tokens' thread)", before.calls == 3 && before.filesRead == 2)
        check("upgrade: each database is read once more (2 files) and nothing is counted twice", upgraded.filesRead == 2 && upgraded.calls == before.calls && upgraded.tokens == before.tokens)
        check("upgrade: after that nothing is read again", after.filesRead == 0 && after.calls == before.calls && after.tokens == before.tokens)
    } catch { check("upgrade: \(error)", false) }

    try fix902LanguageChecks(tempDir: tempDir)
    try fix902CustomFamilyChecks(tempDir: tempDir)
    fix902AliasChecks()
    try fix902InvalidUTF8Checks(tempDir: tempDir)
    try fix902OmpHeaderChecks(tempDir: tempDir)
    try fix902ZedProblemChecks(tempDir: tempDir)
}

// MARK: 2  the sources' own messages in the interface language

private let turkishLetters = Set("çğıöşüÇĞİÖŞÜ")
private let turkishWords = ["dosya", " yok", "okunam", "bilinmeyen", "geçersiz", "açılam", "hata", "dizi", "olamaz", "kullanıyor", "kopyala",
                            "atlandı", "sıkıştır", "aşıyor", "büyük", "adım", "anlaşıl", "dokunul", "tarih", "kayıt", "sonraki", "taramada",
                            "değil", "konuşma", "pencere", "tablo", "boş", "yarıda", "oturum"]

/// What is still Turkish in `text` (nothing for an English sentence).
private func turkishLeft(_ text: String) -> [String] {
    var found = text.filter { turkishLetters.contains($0) }.map { String($0) }
    let lower = text.lowercased()
    found += turkishWords.filter { lower.contains($0) }
    return found
}

/// The probe: a home with one broken source of every kind that has a message of its own, scanned with the language pinned
/// (the parent sets `TOKENBAR_ZSTD=none`). Prints one `source | message` per line.
func fix902Probe(_ name: String, dir: String) -> String? {
    if name == "fix902-omp-home" {                  // the oh-my-pi header homes, for running the other readers on them
        do { try fix902OmpWrite(dir, parts: 3) } catch { return "probe error: \(error)" }
        return "written"
    }
    if name == "fix902-zed-en" || name == "fix902-zed-tr" { return fix902ZedProbe(name, dir: dir) }
    guard name == "fix902-lang-en" || name == "fix902-lang-tr" else { return nil }
    L10n.setLanguage(name.hasSuffix("en") ? .en : .tr)
    var lines: [String] = []
    func scan(_ home: String) {
        guard let store = try? UsageStore(path: home + "/u.sqlite") else { return }
        for issue in UsageScanner(store: store, home: home, environment: [:]).scan().issues {
            lines.append("\(issue.source) | \(IssueText.localized(issue.message))")
        }
    }
    do {
        // custom-sources.json: a document that is not an object, one without sources, and one entry of every refusal.
        for (index, body) in ["[1]", "{}", #"""
            {"sources": [5, {"id": "bad id"}, {"id": "x", "family": "nope"}, {"id": "y", "family": "opencode-sqlite", "paths": []},
              {"id": "z", "family": "crush-sqlite", "paths": ["~/z"]}, {"id": "q", "family": "crush-sqlite", "keyPrefix": "q", "paths": ["~/q"]},
              {"id": "w", "family": "cline-tasks", "keyPrefix": "Bad Prefix", "paths": ["~/w"]}]}
            """#].enumerated() {
            let home = dir + "/custom\(index)"
            try write(home + "/.config/tokenbar/custom-sources.json", body)
            scan(home)
        }
        // The editors: logs that are not what the reader expects, a Zed database it cannot read, an unreadable pair.
        let home = dir + "/editors"
        let support = home + "/Library/Application Support"
        try write(support + "/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/1/ui_messages.json", "not json")
        try write(support + "/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/2/ui_messages.json", #"[{"say":"api_req_started""#)
        try write(home + "/.cline/data/sessions/s1/s1.messages.json", "[1]")
        try write(support + "/Code/User/workspaceStorage/h/chatSessions/old.json", "[1]")
        let zed = support + "/Zed/threads/threads.db"
        try runSQL(zed, "CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT, updated_at TEXT, data_type TEXT, data BLOB);"
                   + "INSERT INTO threads VALUES('p','t','2026-11-06T10:00:00Z','zstd', x'28b52ffd');"
                   + "INSERT INTO threads VALUES('l','t','2026-11-06T10:01:00Z','lz4', x'7878');")
        let usage = protoInt(1, 1) + protoInt(2, 1 << 41)
        let step = protoBytes(8, protoInt(1, 1793968800)) + protoBytes(9, usage)
        try runSQL(home + "/.gemini/antigravity-cli/conversations/huge.db",
                   "CREATE TABLE gen_metadata(idx INTEGER, data BLOB); CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB);"
                   + "INSERT INTO steps VALUES(0,15,X'\(step.map { String(format: "%02x", $0) }.joined())');")
        let denied = home + "/.gemini/antigravity-cli/conversations/denied.db"
        try runSQL(denied, "CREATE TABLE steps(idx INTEGER);")
        try write(denied + "-wal", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied + "-wal")
        try write(home + "/.codex/archived_sessions/rollout-a.jsonl.zst", "x")
        try write(home + "/.local/share/opencode/opencode.db", "this is not a database")
        scan(home)
        // An index of another schema version.
        try runSQL(dir + "/old.sqlite", "CREATE TABLE events(key TEXT); PRAGMA user_version = 99;")
        do { _ = try UsageStore(path: dir + "/old.sqlite") } catch {
            lines.append("index | \(IssueText.localized((error as? StoreError)?.message ?? "\(error)"))")
        }
    } catch { lines.append("probe error: \(error)") }
    return lines.joined(separator: "\n")
}

func fix902LanguageChecks(tempDir: () throws -> String) throws {
    let english = probe("fix902-lang-en", dir: try tempDir(), env: ["TOKENBAR_ZSTD": "none"])
    let turkish = probe("fix902-lang-tr", dir: try tempDir(), env: ["TOKENBAR_ZSTD": "none"])
    let enLines = english.out.split(separator: "\n").map(String.init)
    let trLines = turkish.out.split(separator: "\n").map(String.init)
    let leftovers = enLines.filter { !turkishLeft($0).isEmpty }
    for line in leftovers { fputs("  still Turkish in English: \(line)\n", stderr) }
    check("english: the probe ran and every kind of source message was produced (20 or more lines)", english.status == 0 && enLines.count >= 20)
    check("english: not one source warning keeps a Turkish letter or word", leftovers.isEmpty)
    check("english: the named cases read in English",
          enLines.contains { $0.contains("ui_messages.json is not a valid JSON array") }
          && enLines.contains { $0.contains("Zed threads are compressed") }
          && enLines.contains { $0.contains("could not be copied") }
          && enLines.contains { $0.contains("data_type lz4 is unknown") }
          && enLines.contains { $0.hasPrefix("index | Index schema 99") })
    check("turkish: the same probe still speaks Turkish", trLines.count == enLines.count
          && trLines.contains { $0.contains("ui_messages.json geçerli bir JSON dizisi değil") }
          && trLines.contains { $0.contains("kopyalanamadı") } && trLines.contains { $0.contains("bilinmiyor") })

    // The command line, end to end, with the environment variable and not the switch the probe uses.
    let cli = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tokenbar-cli").path
    guard FileManager.default.isExecutableFile(atPath: cli) else { skip("english cli", "tokenbar-cli is not built beside TokenChecks"); return }
    func run(_ arguments: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TOKENBAR_LANG"] = "en"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", "") }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
    let dir = try tempDir()
    let flag = run(["--bogus-flag"])
    let window = run(["--window", "zz"])
    let index = run(["--home", dir, "--db", dir + "/i.sqlite", "--index"])
    let rebuild = run(["--rebuild"])
    check("english cli: an unknown flag is an English error on stderr (exit 1)",
          flag.status == 1 && flag.out.isEmpty && flag.err.contains("unknown argument") && turkishLeft(flag.err).isEmpty)
    check("english cli: a bad window is an English error on stderr (exit 1)",
          window.status == 1 && window.out.isEmpty && window.err.contains("invalid window") && turkishLeft(window.err).isEmpty)
    check("english cli: --index is in English", index.status == 0 && index.out.contains("records:") && turkishLeft(index.out).isEmpty)
    check("english cli: a refused --rebuild is in English", rebuild.status == 2 && turkishLeft(rebuild.err).isEmpty)
}

// MARK: 3  custom-sources.json: a family with a fixed key prefix serves its own built-in tool only

/// The built-in tool id a family with a fixed prefix belongs to: the one that owns the prefix.
private func builtInOwner(of family: ParserFamily) -> String? {
    guard let prefix = family.fixedPrefix else { return nil }
    return HarnessCatalog.builtin.first { $0.keyPrefixes.contains(prefix) }?.id.rawValue
}

func fix902CustomFamilyChecks(tempDir: () throws -> String) throws {
    var newIdRefused: [String] = [], newIdAccepted: [String] = [], ownIdRefused: [String] = [], noOwner: [String] = []
    for family in ParserFamily.allCases {
        func problems(id: String) throws -> [String] {
            let home = try tempDir() + "/home"
            try write(home + "/.config/tokenbar/custom-sources.json",
                      #"{"sources":[{"id":"\#(id)","family":"\#(family.rawValue)","paths":["~/somewhere"]}]}"#)
            return HarnessCatalog.load(home: home, environment: [:]).issues.map(\.message)
        }
        if family.fixedPrefix == nil {
            if try problems(id: "my-own-tool").isEmpty { newIdAccepted.append(family.rawValue) } else { newIdRefused.append(family.rawValue) }
        } else {
            if try problems(id: "my-own-tool").isEmpty { newIdAccepted.append(family.rawValue) } else { newIdRefused.append(family.rawValue) }
            guard let owner = builtInOwner(of: family) else { noOwner.append(family.rawValue); continue }
            if try !problems(id: owner).isEmpty { ownIdRefused.append(family.rawValue) }
        }
    }
    let free = ParserFamily.allCases.filter { $0.fixedPrefix == nil }.map(\.rawValue)
    check("custom families: exactly the families without a fixed prefix take a new id (\(free.count) of \(ParserFamily.allCases.count))",
          Set(newIdAccepted) == Set(free) && newIdRefused.count == ParserFamily.allCases.count - free.count)
    check("custom families: every fixed-prefix family takes the id of the built-in tool that owns its prefix", ownIdRefused.isEmpty && noOwner.isEmpty)

    // The page says the same: the line that lists the families open to a new id names exactly those.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for (file, marker) in [("HARNESSES.md", "Families open to a new `id`:"), ("HARNESSES.tr.md", "Yeni bir `id` ile açılabilen aileler:")] {
        let text = (try? String(contentsOf: root.appendingPathComponent("docs/" + file), encoding: .utf8)) ?? ""
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first { $0.contains(marker) }.map(String.init) ?? ""
        let named = Set(line.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)).subtracting(["id"])
        check("docs/\(file): the families open to a new id are the ones the code lets through (\(free.count))", !line.isEmpty && named == Set(free))
        let missing = ParserFamily.allCases.filter { $0.fixedPrefix != nil }.filter { (family: ParserFamily) -> Bool in
            !text.contains("| `\(family.rawValue)` | `\(builtInOwner(of: family) ?? "?")` |")
        }.map(\.rawValue)
        check("docs/\(file): every fixed-prefix family is listed with the id of the built-in tool it needs (none missing: \(missing))", missing.isEmpty)
    }
}

// MARK: 4  localProviders keeps its strings, as on Windows

func fix902AliasChecks() {
    let mixed = UserAliases(json: Data(#"{"aliases": {"a": "claude-opus-5-5"}, "localProviders": ["Studio", 5, null, {"x": 1}, ["nested"], true, "my_mac"]}"#.utf8))
    check("aliases 902: a non-string item in localProviders drops only itself", mixed.localProviders == ["studio", "my-mac"])
    check("aliases 902: the aliases next to it are untouched", mixed.targets.count == 1)
    let only = UserAliases(json: Data(#"{"localProviders": [1, 2]}"#.utf8))
    check("aliases 902: a list with no string at all is no providers (and not a crash)", only.localProviders.isEmpty && only.targets.isEmpty)
    let notList = UserAliases(json: Data(#"{"localProviders": "studio"}"#.utf8))
    check("aliases 902: localProviders that is not a list is no providers", notList.localProviders.isEmpty)
}

// MARK: 5  invalid UTF-8 in a log line (as Windows reads it: the bad part becomes U+FFFD, the call counts)

private func keys902(_ dbPath: String) -> [String] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
    defer { sqlite3_close(db) }
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT key FROM events ORDER BY key", -1, &st, nil) == SQLITE_OK, let st else { return [] }
    defer { sqlite3_finalize(st) }
    var out: [String] = []
    while sqlite3_step(st) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(st, 0))) }
    return out
}

private func writeBytes902(_ path: String, _ parts: [[UInt8]]) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(parts.flatMap { $0 }).write(to: URL(fileURLWithPath: path))
}

/// The home of the invalid-UTF-8 case, written for both readers (also used by scripts to run the Windows CLI on it).
func fix902InvalidHome(_ h: String) throws {
    func pi(_ id: String, _ model: String = "gpt-6-luna") -> [UInt8] {
        Array((#"{"type":"message","id":"\#(id)","timestamp":"2026-11-06T10:00:01.000Z","message":{"role":"assistant","provider":"openai","model":"\#(model)","usage":{"input":10,"output":1},"responseId":"r-\#(id)"}}"# + "\n").utf8)
    }
    func piRaw(_ id: String) -> [UInt8] {   // the response id holds a raw 0xFF byte
        Array(#"{"type":"message","id":"\#(id)","timestamp":"2026-11-06T10:00:01.000Z","message":{"role":"assistant","provider":"openai","model":"gpt-6-luna","usage":{"input":20,"output":1},"responseId":"rb"#.utf8) + [0xFF] + Array(#"x"}}"#.utf8) + [0x0A]
    }
    let dir = h + "/.pi/agent/sessions/x/"
    try writeBytes902(dir + "a-good.jsonl", [pi("g1"), pi("g2")])
    try writeBytes902(dir + "b-raw.jsonl", [pi("b1"), piRaw("b2")])
    try writeBytes902(dir + "c-escape.jsonl", [pi("c1"), pi("c2").map { $0 }, Array((#"{"type":"message","id":"c3","timestamp":"2026-11-06T10:00:01.000Z","message":{"role":"assistant","provider":"openai","model":"gpt-6-luna","usage":{"input":30,"output":1},"responseId":"re\udc80x"}}"# + "\n").utf8)])
    func claude(_ id: String, model: String = "claude-opus-5-5", session: String = "s1") -> [UInt8] {
        Array((#"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"\#(session)","requestId":"q-\#(id)","message":{"id":"m-\#(id)","model":"\#(model)","usage":{"input_tokens":5,"output_tokens":1}}}"# + "\n").utf8)
    }
    let raw: [UInt8] = Array(#"{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","sessionId":"s1","requestId":"q-raw","message":{"id":"m-raw","model":"claude-"#.utf8)
        + [0xFF, 0xC3] + Array(#"opus","usage":{"input_tokens":7,"output_tokens":1}}}"#.utf8) + [0x0A]
    try writeBytes902(h + "/.claude/projects/p/s.jsonl", [claude("ok"), raw,
                      claude("esc", model: "claude-\\udc80opus", session: "s\\ud800")])
}

func fix902InvalidUTF8Checks(tempDir: () throws -> String) throws {
    let dir = try tempDir(), h = dir + "/home"
    try fix902InvalidHome(h)
    let first = try scan902(dir, h)
    let keys = keys902(dir + "/usage.sqlite")
    // pi: 2 + 2 + 3 lines, claude: 3 lines: every call counts, like Windows (7 + 3 = 10).
    check("invalid utf-8: every call of a line with a bad byte or a lone surrogate escape is counted (10 calls)", first.calls == 10)
    check("invalid utf-8: the bad part of a key is U+FFFD, as on Windows",
          keys.contains("pi:rb\u{FFFD}x") && keys.contains("pi:re\u{FFFD}x"))
    let second = try scan902(dir, h)
    check("invalid utf-8: a second scan reads nothing again and counts nothing twice", second.filesRead == 0 && second.calls == 10)
    check("invalid utf-8: ASCII keys are untouched", keys.contains("pi:r-g1") && keys.contains("pi:r-b1") && keys.contains("cc:m-ok:q-ok"))
}

// MARK: 6  oh-my-pi: the session header is the first non-blank line, as Windows reads it

private struct OmpCase902 {
    let stem: String                // the name after the last `_`: what a file without a header is called
    let head: [UInt8]               // everything before the first usage line
    let session: String?            // the id the header gives (nil: none, the file name stands in)
    var bomOnFirstUsage = false     // a BOM in front of the first usage line (no header at all)
    var expected: String { session ?? stem }
}

private let bom902: [UInt8] = [0xEF, 0xBB, 0xBF]

private func ompCases902() -> [OmpCase902] {
    func line(_ s: String) -> [UInt8] { Array((s + "\n").utf8) }
    let longCwd = String(repeating: "x", count: 150)
    return [
        OmpCase902(stem: "bom", head: bom902 + line(#"{"type":"session","id":"s-bom","cwd":"/x"}"#), session: "s-bom"),
        OmpCase902(stem: "blank", head: line("") + line("  ") + line(#"{"type":"session","id":"s-blank","cwd":"/x"}"#), session: "s-blank"),
        OmpCase902(stem: "late", head: line(#"{"cwd":"/\#(longCwd)","id":"s-late","type":"session"}"#), session: "s-late"),
        OmpCase902(stem: "notfirst", head: line(#"{"type":"other"}"#) + line(#"{"type":"session","id":"s-notfirst"}"#), session: nil),
        OmpCase902(stem: "bomblank", head: bom902 + line("") + line(#"{"type":"session","id":"s-bomblank"}"#), session: "s-bomblank"),
        OmpCase902(stem: "bomusage", head: [], session: nil, bomOnFirstUsage: true),
    ]
}

private func ompUsage902(_ n: Int) -> [UInt8] {
    Array((#"{"timestamp":"2026-11-06T10:00:0\#(n)Z","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":\#(100 * n),"output":1}}}"# + "\n").utf8)
}

/// The home of the header cases. With `parts` 1 a file holds its header and the first call, 3 holds all three calls.
private func fix902OmpWrite(_ h: String, parts: Int) throws {
    for c in ompCases902() {
        let first = c.bomOnFirstUsage ? bom902 + ompUsage902(1) : ompUsage902(1)
        let rest = (2...3).filter { $0 <= parts }.flatMap { ompUsage902($0) }
        try writeBytes902(h + "/.omp/agent/sessions/p/2026-11-06_\(c.stem).jsonl", [c.head, first, rest])
    }
    // Two files of one name in two folders, the same calls, each its own session named late in its header line: two sets
    // of calls. Read by their name alone (the header missed) the second set would be taken for a copy of the first.
    for (folder, id) in [("p1", "s-twin-1"), ("p2", "s-twin-2")] {
        let head = Array((#"{"cwd":"/\#(String(repeating: "y", count: 150))","id":"\#(id)","type":"session"}"# + "\n").utf8)
        let rest = (2...3).filter { $0 <= parts }.flatMap { ompUsage902($0) }
        try writeBytes902(h + "/.omp/agent/sessions/\(folder)/2026-11-06_twin.jsonl", [head, ompUsage902(1), rest])
    }
}

func fix902OmpHeaderChecks(tempDir: () throws -> String) throws {
    do {
        let cases = ompCases902()
        let fullDir = try tempDir(), fullHome = fullDir + "/home"
        try fix902OmpWrite(fullHome, parts: 3)
        let full = try scan902(fullDir, fullHome)
        let fullKeys = keys902(fullDir + "/usage.sqlite")

        // The same files built up in two steps: the second pass reads only what was added, from past the header.
        let stepDir = try tempDir(), stepHome = stepDir + "/home"
        try fix902OmpWrite(stepHome, parts: 1)
        let firstStep = try scan902(stepDir, stepHome)
        var grown = cases.map { "p/2026-11-06_\($0.stem).jsonl" }
        grown += ["p1/2026-11-06_twin.jsonl", "p2/2026-11-06_twin.jsonl"]
        for name in grown {
            try append(stepHome + "/.omp/agent/sessions/" + name, String(decoding: ompUsage902(2) + ompUsage902(3), as: UTF8.self))
        }
        let secondStep = try scan902(stepDir, stepHome)
        let stepKeys = keys902(stepDir + "/usage.sqlite")

        check("omp header: a full scan counts every call of every file (\(cases.count * 3 + 6))", full.calls == cases.count * 3 + 6)
        check("omp header: the first step counts one call a file, the second the rest",
              firstStep.calls == cases.count + 2 && secondStep.calls == cases.count * 3 + 6)
        check("omp header: two files of one name with their own late headers are two sets of calls, not a copy (3 + 3)",
              fullKeys.filter { $0.hasPrefix("omp:s-twin-1:") }.count == 3 && fullKeys.filter { $0.hasPrefix("omp:s-twin-2:") }.count == 3)
        for c in cases {
            let prefix = "omp:\(c.expected):"
            let mine = fullKeys.filter { $0.hasPrefix(prefix) }.count
            let stepped = stepKeys.filter { $0.hasPrefix(prefix) }.count
            check("omp header \(c.stem): the calls of a full scan are keyed by session \(c.expected) (3)", mine == 3)
            check("omp header \(c.stem): the calls added in a second pass are keyed by session \(c.expected) too (3)", stepped == 3)
        }
        check("omp header: building a file up in steps gives the keys of a full scan, none twice or lost", stepKeys == fullKeys)
    } catch { check("omp header: \(error)", false) }
}

// MARK: 7  a Zed thread that cannot be unpacked: its id and a sentence in the interface language, no enum dump, no temporary path

/// A zstd blob of one line far above the 256 MiB a thread may be, made with the packer on PATH (nil without one).
private func hugeZstd902() -> [UInt8]? {
    guard let tool = zstdPacker else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "head -c 270000000 /dev/zero | '\(tool)' -q -c"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 && !data.isEmpty ? Array(data) : nil
}

func fix902ZedProbe(_ name: String, dir: String) -> String {
    L10n.setLanguage(name.hasSuffix("en") ? .en : .tr)
    guard let huge = hugeZstd902() else { return "probe error: no zstd" }
    do {
        let home = dir + "/home"
        let db = home + fix902Support + "/Zed/threads/threads.db"
        let hex = { (bytes: [UInt8]) -> String in hex902(bytes) }
        // `bad`: a stream that starts like zstd and is cut off; `big`: unpacks to a single line over the limit.
        try runSQL(db, zedSchema902
                   + "INSERT INTO threads VALUES('bad','t','2026-11-06T10:00:00Z','zstd', X'28b52ffd0000', NULL);"
                   + "INSERT INTO threads VALUES('big','t','2026-11-06T10:01:00Z','zstd', X'\(hex(huge))', NULL);")
        let store = try UsageStore(path: dir + "/u.sqlite")
        let issues = UsageScanner(store: store, home: home, environment: [:]).scan().issues
        return issues.map { (issue: SourceIssue) -> String in "\(issue.source) | \(IssueText.localized(issue.message))" }.joined(separator: "\n")
    } catch { return "probe error: \(error)" }
}

func fix902ZedProblemChecks(tempDir: () throws -> String) throws {
    guard zstdPacker != nil else { skip("zed thread problems", zstdWhy); return }
    let english = probe("fix902-zed-en", dir: try tempDir())
    let turkish = probe("fix902-zed-tr", dir: try tempDir())
    let en = english.out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Zed") }
    let tr = turkish.out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Zed") }
    check("zed problems: the probe ran and named both threads (en)", en.count == 2 && en.contains { $0.contains("big") } && en.contains { $0.contains("bad") })
    check("zed problems: no raw enum, no argument label, no temporary path in the text (en)",
          en.allSatisfy { !$0.contains("path:") && !$0.contains("what:") && !$0.contains("tooLarge") && !$0.contains("decompressFailed")
                          && !$0.contains("tokenbar-zed") && !$0.contains(".zst") })
    check("zed problems: the same for Turkish",
          tr.count == 2 && tr.allSatisfy { !$0.contains("path:") && !$0.contains("what:") && !$0.contains("tooLarge") && !$0.contains("decompressFailed")
                                           && !$0.contains("tokenbar-zed") && !$0.contains(".zst") })
    check("zed problems: each line is the thread id and a sentence (en)",
          en.contains { $0.contains("big: the unpacked content is too large") } && en.contains { $0.contains("bad: zstd failed") } && en.allSatisfy { turkishLeft($0).isEmpty })
    check("zed problems: each line is the thread id and a sentence (tr)",
          tr.contains { $0.contains("big: açılmış içerik çok büyük") } && tr.contains { $0.contains("bad: zstd başarısız") })

    // The same failure met through a Codex archive reaches the scan's own error text: also a sentence, not the enum.
    let dir = try tempDir(), home = dir + "/home"
    try write(home + "/.codex/archived_sessions/rollout-bad.jsonl.zst", "this is not a zstd stream")
    let archive = try scan902(dir, home).issues
    check("zed problems: a corrupt Codex archive is named by a sentence (\(archive.count) issue), not by its enum case",
          archive.count == 1 && !archive[0].contains("decompressFailed") && !archive[0].contains("path:") && archive[0].contains("zstd"))
}
