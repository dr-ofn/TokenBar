import Foundation

/// GitHub Copilot CLI `~/.copilot/session-state/<session>/events.jsonl`.
///
/// Counted: `session.usage_record` events, one per model call (`data.usage`). Their identity is the
/// call's `accounting {sourceSessionId, sequence}` (the same call is copied into a forked
/// session's file), else the event id. Older builds wrote no usage records; their per-run
/// `session.shutdown` `modelMetrics` are used then, and only then: a shutdown also totals calls
/// the records already show. `session-store.db` is not read: it holds the same calls a second
/// time, and one source is enough.
///
/// `inputTokens` is the whole prompt, cache reads and writes inside it.
struct CopilotParser {
    let session: String
    let file: String
    private var records: [UsageEvent] = []
    private var shutdowns: [UsageEvent] = []
    private var watermarked = false

    init(session: String, file: String) {
        self.session = session
        self.file = file
    }

    mutating func consume(line: UnsafeRawBufferPointer) {
        let isRecord = line.contains("\"session.usage_record\"")
        guard isRecord || line.contains("\"session.shutdown\""), let o = J.object(line), let data = J.dict(o["data"]) else { return }
        let time = J.time(o["timestamp"])
        let eventID = J.str(o["id"])
        if isRecord, J.str(o["type"]) == "session.usage_record" {
            guard let usage = J.dict(data["usage"]), let tokens = Self.tokens(usage) else { return }
            let key: String
            let accounting = J.dict(usage["accounting"])
            if let source = J.str(accounting?["sourceSessionId"]), J.int(accounting?["sequence"]) > 0 {
                key = "cop:\(source):\(J.int(accounting?["sequence"]))"
            } else if let eventID {
                key = "cop:\(session):e:\(eventID)"
            } else {
                key = "cop:\(session):l:\(String(line.fnv1a(), radix: 16))"
            }
            records.append(UsageEvent(key: key, provider: "github-copilot", model: J.str(usage["model"]) ?? "unknown",
                                      timestamp: time, tokens: tokens, session: session, file: file))
        } else if J.str(o["type"]) == "session.shutdown" {
            if let marks = J.dict(data["usageAccountingWatermarks"]), marks.values.contains(where: { J.int($0) > 0 }) { watermarked = true }
            for (model, value) in J.dict(data["modelMetrics"]) ?? [:] {
                guard let usage = J.dict(J.dict(value)?["usage"]), let tokens = Self.tokens(usage) else { continue }
                let id = eventID ?? Safe.seconds(time).map { String($0) } ?? "t"
                shutdowns.append(UsageEvent(key: "cop:\(session):sd:\(id):\(model)", provider: "github-copilot", model: model,
                                            timestamp: time, tokens: tokens, session: session, file: file))
            }
        }
    }

    func events() -> [UsageEvent] { records.isEmpty && !watermarked ? shutdowns : records }

    private static func tokens(_ u: [String: Any]) -> TokenCounts? {
        let input = J.count(u["inputTokens"]), read = J.count(u["cacheReadTokens"])
        let write = J.count(u["cacheWriteTokens"]), output = J.count(u["outputTokens"])
        let tokens = TokenCounts(input: max(0, input - read - write), cacheRead: read, cacheWrite: write,
                                 output: output, reasoning: min(J.count(u["reasoningTokens"]), output))
        return tokens.isZero ? nil : tokens
    }
}
