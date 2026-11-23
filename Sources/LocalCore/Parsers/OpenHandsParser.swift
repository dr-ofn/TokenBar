import Foundation

/// OpenHands: `~/.openhands/conversations/<id>/base_state.json`, rewritten as the conversation
/// runs. `stats.usage_to_metrics` maps each LLM's usage id (the agent, a condenser...) to its
/// metrics, whose `accumulated_token_usage` is the running total; the SDK itself adds them up
/// across usage ids. Each (conversation, usage id) is one event with a stable key, replaced by a
/// rewrite when it grew.
///
/// `prompt_tokens` includes the cache counts (litellm style), except when the cache read is
/// larger than the prompt, which the SDK takes to mean an agent that reports them separately
/// (ACP); the fresh input is then the prompt itself. `completion_tokens` includes the reasoning.
/// A metrics block with no accumulated total is summed from its `token_usages` list.
enum OpenHandsParser {
    static func events(data: Data, conversation: String, file: String, fallbackTime: Double) -> [UsageEvent] {
        guard let root = (J.parse(data)) as? [String: Any],
              let stats = J.dict(root["stats"]), let byUsage = J.dict(stats["usage_to_metrics"]) else { return [] }
        var out: [UsageEvent] = []
        for (usageID, value) in byUsage {
            guard let metrics = J.dict(value) else { continue }
            var model = J.str(metrics["model_name"]) ?? "unknown"
            var raw = Raw()
            if let total = J.dict(metrics["accumulated_token_usage"]) {
                raw = Raw(total)
                if let named = J.str(total["model"]) { model = named }
            }
            if raw.isZero {
                for usage in (metrics["token_usages"] as? [Any])?.compactMap({ $0 as? [String: Any] }) ?? [] { raw.add(Raw(usage)) }
            }
            let tokens = raw.counts
            guard !tokens.isZero else { continue }
            let stamp = ((metrics["costs"] as? [Any])?.compactMap { J.double(($0 as? [String: Any])?["timestamp"]) }.max())
                .map { J.time($0) } ?? fallbackTime
            var provider = "openhands"
            if let slash = model.firstIndex(of: "/") {
                provider = String(model[..<slash])
                model = String(model[model.index(after: slash)...])
            }
            out.append(UsageEvent(key: "oh:\(conversation):\(usageID)", provider: provider, model: model,
                                  timestamp: stamp > 0 ? stamp : fallbackTime, tokens: tokens,
                                  session: conversation, file: file))
        }
        return out
    }

    private struct Raw {
        var prompt: Int64 = 0, completion: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0

        init() {}
        init(_ o: [String: Any]) {
            prompt = max(0, J.int(o["prompt_tokens"]))
            completion = max(0, J.int(o["completion_tokens"]))
            cacheRead = max(0, J.int(o["cache_read_tokens"]))
            cacheWrite = max(0, J.int(o["cache_write_tokens"]))
            reasoning = max(0, J.int(o["reasoning_tokens"]))
        }

        var isZero: Bool { prompt + completion + cacheRead + cacheWrite == 0 }

        mutating func add(_ other: Raw) {
            prompt = TokenCounts.saturatingSum(prompt, other.prompt)
            completion = TokenCounts.saturatingSum(completion, other.completion)
            cacheRead = TokenCounts.saturatingSum(cacheRead, other.cacheRead)
            cacheWrite = TokenCounts.saturatingSum(cacheWrite, other.cacheWrite)
            reasoning = TokenCounts.saturatingSum(reasoning, other.reasoning)
        }

        var counts: TokenCounts {
            if cacheRead > prompt {
                return TokenCounts(input: prompt, cacheRead: cacheRead, cacheWrite: cacheWrite, output: completion,
                                   reasoning: min(reasoning, completion))
            }
            let read = cacheRead, write = min(cacheWrite, prompt - read)
            return TokenCounts(input: prompt - read - write, cacheRead: read, cacheWrite: write, output: completion,
                               reasoning: min(reasoning, completion))
        }
    }
}
