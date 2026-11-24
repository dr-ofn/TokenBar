import Foundation

extension J {
    /// A token count held to `0...TokenCounts.fieldLimit`, so sums of two counts cannot overflow.
    /// (Read as `util.count` on Windows: a JSON `true` is 1 here, as there.)
    static func count(_ v: Any?) -> Int64 { min(max(int(v, booleans: true), 0), TokenCounts.fieldLimit) }
}

/// Gemini CLI chat recordings: `~/.gemini/tmp/<project>/chats/session-*.jsonl` (older builds wrote
/// one `session-*.json` document). A JSONL file holds records of four shapes, all read here:
///   - a header with `sessionId` (and optionally `messages`),
///   - a message `{"id","type","model","tokens":{...}}`, appended again whenever it changes,
///   - `{"$set":{...}}` which may rewrite the whole `messages` list (after a rewind),
///   - `{"$patch":...}` and `{"$rewindTo":...}`, which carry no usage.
/// A message seen again under the same `id` replaces the earlier copy, as Gemini CLI itself does.
///
/// `tokens` is the API's usage metadata: `input` is the whole prompt, cached part included;
/// `output` excludes `thoughts` (the API bills them as output); `tool` is the tool-use prompt.
/// So fresh input = input - cached + tool, output = output + thoughts, cache read = cached.
struct GeminiChatParser {
    private let fallbackSession: String
    private let file: String
    private var session: String?
    private var order: [String] = []
    private var latest: [String: (model: String, time: Double, tokens: TokenCounts)] = [:]

    init(fallbackSession: String, file: String) {
        self.fallbackSession = fallbackSession
        self.file = file
    }

    mutating func consume(object o: [String: Any]) {
        if let set = J.dict(o["$set"]) {
            if let id = J.str(set["sessionId"]) { session = id }
            consume(messages: set["messages"])
            return
        }
        if o["$rewindTo"] != nil || o["$patch"] != nil { return }
        if J.str(o["id"]) != nil, J.str(o["type"]) != nil {
            message(o)
            return
        }
        if let id = J.str(o["sessionId"]) { session = id }
        consume(messages: o["messages"])
    }

    private mutating func consume(messages: Any?) {
        for case let m as [String: Any] in (messages as? [Any]) ?? [] where J.str(m["id"]) != nil { message(m) }
    }

    private mutating func message(_ m: [String: Any]) {
        guard J.str(m["type"]) == "gemini", let id = J.str(m["id"]), let t = J.dict(m["tokens"]) else { return }
        let prompt = J.count(t["input"]), cached = J.count(t["cached"]), thoughts = J.count(t["thoughts"])
        let tokens = TokenCounts(input: prompt - min(cached, prompt) + J.count(t["tool"]),
                                 cacheRead: cached, output: J.count(t["output"]) + thoughts, reasoning: thoughts)
        guard !tokens.isZero else { return }
        if latest[id] == nil { order.append(id) }
        latest[id] = (J.str(m["model"]) ?? "unknown", J.time(m["timestamp"]), tokens)
    }

    func events() -> [UsageEvent] {
        let sessionID = session ?? fallbackSession
        return order.compactMap { id in
            latest[id].map {
                UsageEvent(key: "gem:\(sessionID):\(id)", provider: "google", model: $0.model, timestamp: $0.time,
                           tokens: $0.tokens, session: sessionID, file: file)
            }
        }
    }
}
