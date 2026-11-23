import Foundation

/// VS Code Copilot Chat sessions: `<Code>/User/workspaceStorage/<hash>/chatSessions/<id>.jsonl` (and
/// `<Code>/User/globalStorage/emptyWindowChatSessions/<id>.jsonl` for a window without a folder).
/// Each line is a patch on one JSON document (the same shape tokscale's `copilot_vscode.rs` replays):
///   `{"kind":0,"v":{"requests":[…]}}`            a snapshot
///   `{"kind":1,"k":["requests",2,"result"],"v":…}` the value at a path is set
///   `{"kind":2,"k":["requests"],"v":[…]}`          requests are appended
/// A finished request carries `promptTokens`, `completionTokens`, `timestamp` and `modelId`, the
/// first three also under `result.metadata` (`promptTokens`, `outputTokens`, `resolvedModel`).
/// An older session is one `.json` file with the same `requests` array.
///
/// Tokens only, no cache split: `promptTokens` counts as input. The reasoning that
/// `toolCallRounds[].thinking.tokens` records is not added: whether `completionTokens` holds it is
/// unverified (the source is the extension's own log; Microsoft's code was not read).
struct CopilotChatParser {
    private(set) var requests: [[String: Any]] = []

    /// How many keys below a request a patch may name (`result`, `metadata`, `promptTokens` need three).
    static let maxPatchDepth = 32

    /// One line of a `.jsonl` session.
    mutating func consume(line: UnsafeRawBufferPointer) {
        if Self.cannotMatter(line) { return }
        guard let o = J.object(line), let kind = (o["kind"] as? NSNumber)?.intValue else { return }
        switch kind {
        case 0:
            // A snapshot is the whole document as it stands: it replaces the requests read so far, and the
            // patches that follow name positions in it.
            if let list = J.dict(o["v"])?["requests"] as? [Any] { requests = list.map(Self.pruned) }
        case 1:
            // The paths the events read are at most five deep; a longer one cannot matter and would only recurse.
            guard let path = o["k"] as? [Any], path.first as? String == "requests",
                  path.count >= 2, path.count <= 2 + Self.maxPatchDepth, let index = (path[1] as? NSNumber)?.intValue, requests.indices.contains(index),
                  let value = o["v"] else { return }
            var request: Any = requests[index]
            Self.set(&request, path: path.dropFirst(2), value: value)
            requests[index] = Self.pruned(request)
        case 2:
            // Only a top-level append grows the list; a nested one carries no tokens and must not
            // move the positions the other patches name.
            if let path = o["k"] as? [Any], path.count == 1, path.first as? String == "requests", let list = o["v"] as? [Any] {
                requests += list.map(Self.pruned)
            }
        default:
            break
        }
    }

    /// An older session: the whole file is one document.
    mutating func consume(document: Data) throws {
        guard let o = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else {
            throw EditorLogFormatError(message: "oturum dosyası geçerli bir JSON nesnesi değil")
        }
        requests += ((o["requests"] as? [Any]) ?? []).map(Self.pruned)
    }

    /// The events of the session. Requests of another provider (no `copilot/` model, no resolved
    /// model) are not Copilot's calls and are left out.
    func events(session: String, file: String) -> [UsageEvent] {
        var out: [UsageEvent] = []
        for (index, request) in requests.enumerated() {
            let metadata = J.dict(J.dict(request["result"])?["metadata"])
            let prompt = request["promptTokens"] is NSNumber ? J.int(request["promptTokens"]) : J.int(metadata?["promptTokens"])
            let completion = request["completionTokens"] is NSNumber ? J.int(request["completionTokens"]) : J.int(metadata?["outputTokens"])
            let tokens = TokenCounts(input: max(0, prompt), output: max(0, completion))
            guard !tokens.isZero else { continue }
            let resolved = J.str(metadata?["resolvedModel"])?.trimmingCharacters(in: .whitespaces)
            let named = J.str(request["modelId"])?.trimmingCharacters(in: .whitespaces)
            guard (resolved?.isEmpty == false) || (named?.hasPrefix("copilot/") == true) else { continue }
            let model = [resolved, named.map { $0.hasPrefix("copilot/") ? String($0.dropFirst(8)) : $0 }]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "auto"
            let ms = J.double(request["timestamp"]) ?? 0
            let stamp = ms > 0 ? Safe.int64(ms).map { String($0) } ?? "i\(index)" : "i\(index)"
            out.append(UsageEvent(key: "copilot-chat:\(session):\(stamp)", provider: "github-copilot", model: model,
                                  timestamp: J.time(request["timestamp"]), tokens: tokens, session: session, file: file))
        }
        return out
    }

    // MARK: patching

    /// A patch the events cannot read, told from its first bytes, so a streamed response (the bulk of
    /// a session) is never decoded: a nested append (`"kind":2,"k":["requests",0,"response"…`), or
    /// a set at a path whose key is not one of the few the events use. Lines that do not start the
    /// way VS Code writes them are decoded as usual.
    static func cannotMatter(_ line: UnsafeRawBufferPointer) -> Bool {
        if line.indexOf(StaticString("{\"kind\":2,\"k\":[\"requests\","), limit: 40) == 0 { return true }
        let head = Array("{\"kind\":1,\"k\":[\"requests\",".utf8)
        guard line.count > head.count + 4, memcmp(line.baseAddress!, head, head.count) == 0 else { return false }
        var i = head.count
        let digits = i
        while i < line.count, line[i] >= 0x30, line[i] <= 0x39 { i += 1 }
        guard i > digits, i + 1 < line.count, line[i] == 0x2C, line[i + 1] == 0x22 else { return false }
        i += 2
        let keyStart = i
        while i < line.count, line[i] != 0x22, line[i] != 0x5C { i += 1 }
        guard i < line.count, line[i] == 0x22 else { return false }
        let key = String(decoding: line[keyStart..<i], as: UTF8.self)
        return !["promptTokens", "completionTokens", "timestamp", "modelId", "result"].contains(key)
    }

    /// Sets the value at `path` inside `target`, making the objects and arrays on the way.
    static func set(_ target: inout Any, path: ArraySlice<Any>, value: Any) {
        guard let head = path.first else { target = value; return }
        let rest = path.dropFirst()
        if let key = head as? String {
            var object = (target as? [String: Any]) ?? [:]
            var child: Any = object[key] ?? [String: Any]()
            set(&child, path: rest, value: value)
            object[key] = child
            target = object
        } else if let index = (head as? NSNumber)?.intValue, index >= 0, index <= 4096 {
            var array = (target as? [Any]) ?? []
            while array.count <= index { array.append(NSNull()) }
            set(&array[index], path: rest, value: value)
            target = array
        }
    }

    /// A request cut down to what the events read: a session can hold gigabytes of responses.
    static func pruned(_ request: Any) -> [String: Any] {
        guard let r = request as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for key in ["promptTokens", "completionTokens", "timestamp", "modelId"] { out[key] = r[key] }
        if let metadata = J.dict(J.dict(r["result"])?["metadata"]) {
            var kept: [String: Any] = [:]
            for key in ["promptTokens", "outputTokens", "resolvedModel"] { kept[key] = metadata[key] }
            out["result"] = ["metadata": kept]
        }
        return out
    }
}
