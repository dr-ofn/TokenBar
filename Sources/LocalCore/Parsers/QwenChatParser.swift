import Foundation

/// Qwen Code's newer chat files `~/.qwen/projects/<project>/chats/<session>.jsonl`: assistant lines
/// carry Gemini-shaped `usageMetadata`. `promptTokenCount` is the whole prompt, cache included.
/// Whether `thoughtsTokenCount` sits inside `candidatesTokenCount` depends on the provider, and the
/// recorded total tells: OpenAI-compatible providers report prompt + candidates (thoughts inside),
/// the Gemini API adds the thoughts on top.
enum QwenChatParser {
    static func event(line: UnsafeRawBufferPointer, session fallback: String, file: String) -> UsageEvent? {
        guard line.contains("\"usageMetadata\""), let o = J.object(line), J.str(o["type"]) == "assistant",
              let u = J.dict(o["usageMetadata"]) else { return nil }
        let prompt = J.count(u["promptTokenCount"]), candidates = J.count(u["candidatesTokenCount"])
        let thoughts = J.count(u["thoughtsTokenCount"]), cached = J.count(u["cachedContentTokenCount"])
        let insideCandidates: Bool
        if thoughts > 0, let total = J.number(u["totalTokenCount"])?.int64Value {
            insideCandidates = total == 0 ? candidates > 0 : total == prompt + candidates
        } else {
            insideCandidates = false
        }
        let reasoning = insideCandidates ? min(thoughts, candidates) : thoughts
        let tokens = TokenCounts(input: cached <= prompt ? prompt - cached : prompt, cacheRead: cached,
                                 output: insideCandidates ? candidates : candidates + thoughts, reasoning: reasoning)
        guard !tokens.isZero else { return nil }
        let session = J.str(o["sessionId"]) ?? fallback
        let id = J.str(o["uuid"]) ?? "l" + String(line.fnv1a(), radix: 16)
        return UsageEvent(key: "qwenc:\(session):\(id)", provider: "qwen", model: J.str(o["model"]) ?? "unknown",
                          timestamp: J.time(o["timestamp"]), tokens: tokens, session: session, file: file)
    }
}
