import Foundation

/// `~/.qwen/usage/token-usage-YYYY-MM.jsonl`: one line per request, OpenAI semantics
/// (`inputTokens` includes `cachedTokens`; `outputTokens` includes `thoughtsTokens`).
enum QwenParser {
    static func event(line: UnsafeRawBufferPointer, file: String) -> UsageEvent? {
        guard line.contains("\"inputTokens\""), let o = J.object(line), let id = J.str(o["id"]) else { return nil }
        let input = J.int(o["inputTokens"]), cached = J.int(o["cachedTokens"])
        let tokens = TokenCounts(input: max(0, input - cached), cacheRead: min(cached, input),
                                 output: J.int(o["outputTokens"]), reasoning: J.int(o["thoughtsTokens"]))
        guard !tokens.isZero else { return nil }
        return UsageEvent(key: "qwen:\(id)", provider: J.str(o["authType"]) ?? "qwen",
                          model: J.str(o["model"]) ?? "unknown", timestamp: J.time(o["timestamp"]),
                          tokens: tokens, session: J.str(o["sessionId"]) ?? "", file: file)
    }
}
