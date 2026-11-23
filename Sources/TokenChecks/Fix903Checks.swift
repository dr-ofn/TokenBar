import Foundation
import SQLite3
import LocalCore

// Checks for the findings of the independent review of the published 9.0.2 (Mac side), 9.0.3 patch.
// Called once from `main.swift`; every case builds a small home and scans it in this process.
//
//   4  KIMI_CODE_HOME moves Kimi Code (as on Windows)
//   7  a price answer larger than the limit fails and is not kept (128 MiB as on Windows; the check uses a small limit)
//   6  the price GET carries no Accept-Language (nor anything else that says who or where the user is)
//   5  two alias names that fold to the same key: the last one in the file wins, every time (as on Windows)
//   3  with the English interface the reason a price is a "nearest model" stand-in (and every other table note) reads in English
//   2  custom-sources.json "opencode-sqlite" with "recursive": true finds opencode*.db at any depth (docs/HARNESSES.md)

private func ocDB903(_ path: String, _ id: String, _ input: Int) throws {
    try runSQL(path, "CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session(id TEXT, directory TEXT);")
    let json = #"{"role":"assistant","providerID":"openrouter","modelID":"gpt-6-luna","path":{"cwd":"/fixture"},"tokens":{"input":\#(input),"output":1,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1793968800}}"#
    try runSQL(path, "INSERT INTO session VALUES('s','/fixture'); INSERT INTO message VALUES('\(id)','s','\(json)',1793968800);")
}

func fix903Checks(tempDir: () throws -> String) throws {
    PriceBook.install(catalogs: .embedded)

    // MARK: 2  the documented fork example: a folder, "recursive": true, databases that are not under data/opencode/

    do {
        let dir = try tempDir(), h = dir + "/home"
        try write(h + "/.config/tokenbar/custom-sources.json",
                  #"{"sources":[{"id":"my-fork","name":"My opencode fork","family":"opencode-sqlite","paths":["~/work/fork-data"],"keyPrefix":"myfork","recursive":true}]}"#)
        try ocDB903(h + "/work/fork-data/opencode.db", "fk-top", 10)
        try ocDB903(h + "/work/fork-data/a/b/c/opencode-2.db", "fk-deep", 20)
        try ocDB903(h + "/work/fork-data/x/data/opencode/opencode.db", "fk-xdg", 30)
        try ocDB903(h + "/work/fork-data/x/other.db", "fk-other", 40)
        let store = try UsageStore(path: dir + "/usage.sqlite")
        _ = UsageScanner(store: store, home: h, environment: [:]).scan()
        check("custom opencode recursive: the database at the top of the folder is read", store.hasEvents(prefix: "myfork:fk-top"))
        check("custom opencode recursive: an opencode*.db at any depth is read", store.hasEvents(prefix: "myfork:fk-deep"))
        check("custom opencode recursive: the data/opencode/ layout is still read", store.hasEvents(prefix: "myfork:fk-xdg"))
        check("custom opencode recursive: a database that is not named opencode*.db is left alone", !store.hasEvents(prefix: "myfork:fk-other"))
    } catch { check("custom opencode recursive: \(error)", false) }

    do {
        let dir = try tempDir(), h = dir + "/home"
        try write(h + "/.config/tokenbar/custom-sources.json",
                  #"{"sources":[{"id":"my-fork","family":"opencode-sqlite","paths":["~/work/fork-data"],"keyPrefix":"myfork","recursive":false}]}"#)
        try ocDB903(h + "/work/fork-data/opencode.db", "fk-top", 10)
        try ocDB903(h + "/work/fork-data/a/b/opencode-2.db", "fk-deep", 20)
        let store = try UsageStore(path: dir + "/usage.sqlite")
        _ = UsageScanner(store: store, home: h, environment: [:]).scan()
        check("custom opencode, recursive false: only the folder's own opencode.db", store.hasEvents(prefix: "myfork:fk-top") && !store.hasEvents(prefix: "myfork:fk-deep"))
    } catch { check("custom opencode, recursive false: \(error)", false) }

    try fix903PriceNoteChecks()

    // MARK: 4  KIMI_CODE_HOME

    do {
        let dir = try tempDir(), h = dir + "/home"
        let wire = #"{"type":"llm.request","modelAlias":"openrouter/gpt-6-luna"}"# + "\n"
            + #"{"time":"2026-11-06T10:00:00Z","event":{"type":"step.end","messageId":"MSG","usage":{"inputOther":20,"inputCacheRead":2,"inputCacheCreation":3,"output":5}}}"# + "\n"
        try write(h + "/moved-kimi/sessions/work/km/agents/a/wire.jsonl", wire.replacingOccurrences(of: "MSG", with: "k-moved"))
        try write(h + "/.kimi-code/sessions/work/kd/agents/a/wire.jsonl", wire.replacingOccurrences(of: "MSG", with: "k-default"))
        let store = try UsageStore(path: dir + "/usage.sqlite")
        let result = UsageScanner(store: store, home: h, environment: ["KIMI_CODE_HOME": h + "/moved-kimi"]).scan()
        check("KIMI_CODE_HOME moves Kimi Code", store.hasEvents(prefix: "kimi:km:k-moved") && !store.hasEvents(prefix: "kimi:kd:k-default") && result.issues.isEmpty)
        let plain = try UsageStore(path: dir + "/plain.sqlite")
        _ = UsageScanner(store: plain, home: h, environment: [:]).scan()
        check("Kimi Code without KIMI_CODE_HOME reads ~/.kimi-code", plain.hasEvents(prefix: "kimi:kd:k-default") && !plain.hasEvents(prefix: "kimi:km:k-moved"))
    } catch { check("KIMI_CODE_HOME: \(error)", false) }
}

// MARK: 3  the reasons in price-map.json read in English

private let turkishLetters903 = Set("çğıöşüÇĞİÖŞÜ")
private let turkishWords903 = [" yok", "listel", "ücretsiz", "en yakın", "gizli", "vekil", "ücretli", "ayrı", "model adı", "ince ayar", "yayımlam", "satırı"]

func fix903PriceNoteChecks() throws {
    defer { L10n.setLanguage(nil) }
    PriceBook.install(catalogs: .embedded)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let map = (try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("scripts/price-map.json")))) as? [String: Any] ?? [:]
    var withNote: [String] = [], notEnglish: [String] = [], noReason: [String] = [], turkishStays: [String] = [], missing: [String] = []
    for (key, value) in map.sorted(by: { $0.key < $1.key }) {
        guard let spec = value as? [String: Any], let note = spec["note"] as? String else { continue }
        guard let entry = ModelPrice(model: key, provider: "").entry else { missing.append(key); continue }
        withNote.append(key)
        L10n.setLanguage(.tr)
        if !UsageText.sourceText(entry).contains(note) { turkishStays.append(key) }
        L10n.setLanguage(.en)
        let english = UsageText.sourceText(entry)
        if english.contains(note) || english.contains(where: { turkishLetters903.contains($0) }) || turkishWords903.contains(where: { english.contains($0) }) { notEnglish.append(key) }
        if spec["near"] != nil && !english.contains(" (") { noReason.append(key) }
    }
    check("price notes: every model of price-map.json with a note is in the price table (\(withNote.count) with a note, missing: \(missing))", missing.isEmpty && withNote.count >= 25)
    check("price notes: Turkish still shows the Turkish note as written (\(turkishStays))", turkishStays.isEmpty)
    check("price notes: in English no Turkish letter or word is left in a source text (\(notEnglish))", notEnglish.isEmpty)
    check("price notes: in English a nearest-model price still says why (\(noReason))", noReason.isEmpty)

    fix903AliasOrderChecks()
    fix903FeedChecks()
}

// MARK: 5  alias names that fold together

func fix903AliasOrderChecks() {
    func target(_ json: String, _ name: String = "my-model") -> UserAliases.Target? {
        UserAliases(json: Data(json.utf8)).targets[ModelNames.keys(name).key1]
    }
    check("alias order: the two names fold to one key (the case under test)", ModelNames.keys("My-Model").key1 == ModelNames.keys("my-model").key1
          && ModelNames.keys("MY_MODEL").key1 == ModelNames.keys("my-model").key1 && ModelNames.keys("My.Model").key1 == ModelNames.keys("my-model").key1)
    let ab = #"{"aliases": {"My-Model": "claude-opus-5-5", "my-model": "gpt-6-luna"}}"#
    let ba = #"{"aliases": {"my-model": "gpt-6-luna", "My-Model": "claude-opus-5-5"}}"#
    check("alias order: the last of two names that fold together wins (a, b -> b)", target(ab) == .model("gpt-6-luna"))
    check("alias order: ... and the other way round (b, a -> a)", target(ba) == .model("claude-opus-5-5"))
    let three = #"{"My.Model": "glm-5.3", "x": {"input": 1, "output": 2}, "My-Model": "claude-opus-5-5", "my-model": "gpt-6-luna"}"#
    check("alias order: the aliases alone (no \"aliases\" key), three names -> the last", target(three) == .model("gpt-6-luna"))
    let nested = #"{"localProviders": ["a{", "\"b"], "aliases": {"k\"ey": {"as": "claude-opus-5-5", "n": {"x": "}"}}, "My-Model": "glm-5.3", "my-model": "gpt-6-luna", "MY_MODEL": "claude-haiku-5-5"}}"#
    check("alias order: braces and quotes inside values and keys do not confuse the order (-> MY_MODEL)", target(nested) == .model("claude-haiku-5-5"))
    let invalidLast = #"{"aliases": {"my-model": "gpt-6-luna", "My-Model": {"input": -1}}}"#
    check("alias order: a later entry that is no alias does not replace an earlier one", target(invalidLast) == .model("gpt-6-luna"))
    // The same file read many times, and with the keys spelled so a dictionary might shuffle them.
    var stable = true
    for _ in 0..<50 where target(ab) != .model("gpt-6-luna") { stable = false }
    check("alias order: the winner is the same on every read", stable)
    // Many names: the order is followed in linear time (a 50,000-name file took 17 s when each name searched a list).
    let many = "{" + (0..<100_000).map { (i: Int) -> String in "\"m\(i)\": \"gpt-6-luna\"" }.joined(separator: ",") + "}"
    let started = Date()
    let manyTargets = UserAliases(json: Data(many.utf8)).targets.count
    let took = Date().timeIntervalSince(started)
    check("alias order: 100,000 names load in under 2 s (\(String(format: "%.2f", took)) s, \(manyTargets) names)", took < 2 && manyTargets == 100_000)
    // A file saved as UTF-16 (PowerShell's ">" writes UTF-16 LE with a BOM) keeps its order too, as on Windows.
    func utf16(_ text: String, _ encoding: String.Encoding, bom: [UInt8]) -> Data { Data(bom) + text.data(using: encoding)! }
    let ba16le = utf16(ba, .utf16LittleEndian, bom: [0xFF, 0xFE]), ab16be = utf16(ab, .utf16BigEndian, bom: [0xFE, 0xFF])
    let ba16bare = utf16(ba, .utf16LittleEndian, bom: [])
    check("alias order: a UTF-16 LE file with a BOM keeps the file's order (b, a -> a)",
          UserAliases(json: ba16le).targets[ModelNames.keys("my-model").key1] == .model("claude-opus-5-5"))
    check("alias order: a UTF-16 BE file with a BOM keeps the file's order (a, b -> b)",
          UserAliases(json: ab16be).targets[ModelNames.keys("my-model").key1] == .model("gpt-6-luna"))
    check("alias order: a UTF-16 LE file without a BOM keeps the file's order (b, a -> a)",
          UserAliases(json: ba16bare).targets[ModelNames.keys("my-model").key1] == .model("claude-opus-5-5"))

}

// MARK: 6, 7  what the price GET looks like on the wire

/// One connection at a time on 127.0.0.1: records the request head it reads and answers with `reply(head)`.
final class LocalServer903: @unchecked Sendable {
    private let listener: Int32
    let port: UInt16
    private let lock = NSLock()
    private var heads: [String] = []
    private var stopped = false

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return heads }

    init?(reply: @escaping @Sendable (String) -> Data) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        let bound = withUnsafePointer(to: &address) { (pointer: UnsafePointer<sockaddr_in>) -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { (pointer: UnsafeMutablePointer<sockaddr_in>) -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var head = Data()
                var byte: UInt8 = 0
                while !head.suffix(4).elementsEqual([13, 10, 13, 10]), read(client, &byte, 1) == 1 { head.append(byte) }
                let text = String(decoding: head, as: UTF8.self)
                lock.lock(); heads.append(text); lock.unlock()
                let answer = reply(text)
                answer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
                    var sent = 0
                    while sent < raw.count {
                        let n = write(client, raw.baseAddress! + sent, raw.count - sent)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                close(client)
            }
        }
    }

    deinit { close(listener) }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/models")! }

    static func response(status: String = "200 OK", headers: [String] = [], body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n" + headers.map { $0 + "\r\n" }.joined() + "Connection: close\r\n\r\n"
        head += ""
        return Data(head.utf8) + body
    }
}

func fix903FeedChecks() {
    final class Box: @unchecked Sendable { var value: PriceFetchResponse?; var error: Error? }
    func run(_ fetcher: URLSessionPriceFetcher, _ url: URL, etag: String? = nil) -> Box {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = try await fetcher.get(url, etag: etag) } catch { box.error = error }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 60)
        return box
    }

    // MARK: 6  the request head

    let json = Data("{\"data\": []}".utf8)
    guard let server = LocalServer903(reply: { _ in LocalServer903.response(headers: ["Content-Length: \(json.count)", "ETag: \"v1\""], body: json) }) else {
        check("price GET on the wire: a local server could be started", false)
        return
    }
    let got = run(URLSessionPriceFetcher(), server.url, etag: "\"v0\"")
    var answered = false
    if case .ok(let data, let etag)? = got.value, data == json, etag == "\"v1\"" { answered = true }
    check("price GET on the wire: the answer and its ETag are read (\(String(describing: got.error)))", answered)
    let head = server.requests.first ?? ""
    var fields: [String: String] = [:]
    for line in head.components(separatedBy: "\r\n").dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 { fields[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
    }
    let names = fields.keys.sorted()
    check("price GET on the wire: it is a GET with If-None-Match and the product name only as identification (\(names))",
          head.hasPrefix("GET /models ") && head.lowercased().contains("if-none-match: \"v0\"") && head.contains("User-Agent: TokenBar\r\n"))
    // URLSession always writes the header, so an empty one is as good as none: it says nothing about the user's language.
    check("price GET on the wire: Accept-Language says nothing (\(fields["accept-language"] ?? "absent"))", (fields["accept-language"] ?? "").isEmpty)
    check("price GET on the wire: no cookie, no authorization, no referer (\(names))",
          !names.contains("cookie") && !names.contains("authorization") && !names.contains("referer"))
    let allowed: Set<String> = ["host", "accept", "user-agent", "if-none-match", "accept-encoding", "connection", "accept-language"]
    check("price GET on the wire: only plain protocol headers are sent (\(Set(names).subtracting(allowed).sorted()))", Set(names).subtracting(allowed).isEmpty)

    // MARK: 7  the size limit

    let small = Data(repeating: 0x20, count: 400) + json
    let big = Data(repeating: 0x20, count: 5000) + json
    func serve(_ body: Data, length: Bool) -> LocalServer903? {
        LocalServer903(reply: { _ in LocalServer903.response(headers: length ? ["Content-Length: \(body.count)"] : [], body: body) })
    }
    func outcome(_ box: Box) -> String {
        if case .ok(let data, _)? = box.value { return "ok \(data.count) bytes" }
        return "error: \(String(describing: box.error))"
    }
    let limit = 1000
    if let withLength = serve(big, length: true), let streamed = serve(big, length: false), let fits = serve(small, length: true) {
        let a = run(URLSessionPriceFetcher(maxResponseBytes: limit), withLength.url)
        let b = run(URLSessionPriceFetcher(maxResponseBytes: limit), streamed.url)
        let c = run(URLSessionPriceFetcher(maxResponseBytes: limit), fits.url)
        let d = run(URLSessionPriceFetcher(), withLength.url)
        check("size limit: an answer whose Content-Length is over the limit fails (\(outcome(a)))", a.value == nil && a.error != nil)
        check("size limit: an answer that grows past the limit without a length fails (\(outcome(b)))", b.value == nil && b.error != nil)
        var fitting = false
        if case .ok(let data, _)? = c.value, data == small { fitting = true }
        check("size limit: an answer under the limit is read whole (\(outcome(c)))", fitting)
        var normal = false
        if case .ok(let data, _)? = d.value, data == big { normal = true }
        check("size limit: the default limit (128 MiB) lets a normal answer through (\(outcome(d)))", normal && URLSessionPriceFetcher.defaultMaxResponseBytes == 128 * 1024 * 1024)
    } else {
        check("size limit: local servers could be started", false)
    }
}
