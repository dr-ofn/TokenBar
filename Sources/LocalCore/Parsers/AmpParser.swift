import Foundation

/// Amp (Sourcegraph): `~/.local/share/amp/threads/**/T-*.json`, rewritten as the thread grows.
///
/// A thread that has a `usageLedger` is read from it, one event per ledger entry (`tokens.input`
/// and `.output`; the cache counts live on the assistant message the entry points at with
/// `toMessageId`). A thread without one is read from its assistant messages' `usage`. The ledger
/// and the message usage describe the same calls, so a thread is never read both ways. Keys are
/// the thread id plus the entry's own id (its position when it has none), which a rewrite
/// does not change.
enum AmpParser {
    static func events(data: Data, thread fallback: String, file: String, fallbackTime: Double) -> [UsageEvent] {
        guard let root = (J.parse(data)) as? [String: Any] else { return [] }
        let thread = J.str(root["id"]) ?? fallback
        let messages = (root["messages"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        if let ledger = J.dict(root["usageLedger"]), let entries = ledger["events"] as? [Any] {
            return fromLedger(entries, messages: messages, thread: thread, file: file, fallbackTime: fallbackTime)
        }
        return fromMessages(messages, thread: thread, file: file, fallbackTime: fallbackTime)
    }

    /// The assistant messages' cache counts by message id (numbers and text ids alike).
    private static func cacheByMessage(_ messages: [[String: Any]]) -> [String: (write: Int64, read: Int64)] {
        var out: [String: (Int64, Int64)] = [:]
        for message in messages where J.str(message["role"]) == "assistant" {
            guard let id = messageID(message["messageId"]), let usage = J.dict(message["usage"]) else { continue }
            out[id] = (max(0, J.int(usage["cacheCreationInputTokens"])), max(0, J.int(usage["cacheReadInputTokens"])))
        }
        return out
    }

    private static func messageID(_ value: Any?) -> String? {
        if let text = J.str(value) { return text }
        if let number = value as? NSNumber { return String(number.int64Value) }
        return nil
    }

    /// Fields that give no input or output split but a total count the total as input.
    private static func counts(input: Int64, output: Int64, write: Int64, read: Int64, total: Int64) -> TokenCounts {
        var input = max(0, input)
        let output = max(0, output), write = max(0, write), read = max(0, read)
        if input + output == 0, total > write + read { input = total - write - read }
        return TokenCounts(input: input, cacheRead: read, cacheWrite: write, output: output)
    }

    private static func fromLedger(_ entries: [Any], messages: [[String: Any]], thread: String, file: String,
                                   fallbackTime: Double) -> [UsageEvent] {
        let cache = cacheByMessage(messages)
        var out: [UsageEvent] = []
        for (index, entry) in entries.enumerated() {
            guard let e = entry as? [String: Any], let tokens = J.dict(e["tokens"]) else { continue }
            let cached = messageID(e["toMessageId"]).flatMap { cache[$0] } ?? (0, 0)
            let counted = counts(input: J.int(tokens["input"]), output: J.int(tokens["output"]),
                                 write: cached.0, read: cached.1, total: J.int(tokens["total"]))
            guard !counted.isZero else { continue }
            let id = J.str(e["id"]) ?? "i\(index)"
            let time = J.time(e["timestamp"])
            out.append(UsageEvent(key: "amp:\(thread):\(id)", provider: "amp", model: J.str(e["model"]) ?? "unknown",
                                  timestamp: time > 0 ? time : fallbackTime, tokens: counted, session: thread, file: file))
        }
        return out
    }

    private static func fromMessages(_ messages: [[String: Any]], thread: String, file: String,
                                     fallbackTime: Double) -> [UsageEvent] {
        var out: [UsageEvent] = []
        for (index, message) in messages.enumerated() where J.str(message["role"]) == "assistant" {
            guard let usage = J.dict(message["usage"]) else { continue }
            let counted = counts(input: J.int(usage["inputTokens"]), output: J.int(usage["outputTokens"]),
                                 write: J.int(usage["cacheCreationInputTokens"]), read: J.int(usage["cacheReadInputTokens"]),
                                 total: J.int(usage["totalTokens"]))
            guard !counted.isZero else { continue }
            let id = messageID(message["messageId"]).map { "m" + $0 } ?? "i\(index)"
            let time = [J.time(usage["timestamp"]), J.time(message["timestamp"])].first { $0 > 0 } ?? fallbackTime
            out.append(UsageEvent(key: "amp:\(thread):\(id)", provider: "amp",
                                  model: J.str(usage["model"]) ?? J.str(message["model"]) ?? "unknown",
                                  timestamp: time, tokens: counted, session: thread, file: file))
        }
        return out
    }
}
