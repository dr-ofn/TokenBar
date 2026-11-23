import Foundation

/// JetBrains Junie `~/.junie/sessions/<session>/events.jsonl`. A `LlmResponseMetadataEvent`
/// (`event.agentEvent.modelUsage[]`) is one model call's usage per entry; `timestampMs` dates it.
/// The format has no event id, so a call is identified by its own line plus its place in `modelUsage`.
/// Input and cache counts are taken as separate buckets; whether `inputTokens` itself already
/// holds the cache counts is not documented by the tool (not verified).
enum JunieParser {
    static func events(line: UnsafeRawBufferPointer, session: String, file: String, fallbackTime: Double) -> [UsageEvent] {
        guard line.contains("LlmResponseMetadataEvent"), let o = J.object(line),
              let agent = J.dict(J.dict(o["event"])?["agentEvent"]), J.str(agent["kind"]) == "LlmResponseMetadataEvent",
              let usages = agent["modelUsage"] as? [Any] else { return [] }
        let ms = J.double(o["timestampMs"]) ?? 0
        let stamp: Double? = ms > 0 ? ms / 1000 : nil
        let hash = String(line.fnv1a(), radix: 16)
        var out: [UsageEvent] = []
        for (index, raw) in usages.enumerated() {
            guard let u = raw as? [String: Any], let model = J.str(u["model"]) else { continue }
            let output = first(u, "outputTokens", "output")
            let tokens = TokenCounts(input: first(u, "inputTokens", "input"),
                                     cacheRead: first(u, "cacheInputTokens", "cacheReadInputTokens", "cacheRead"),
                                     cacheWrite: first(u, "cacheCreateTokens", "cacheCreationInputTokens", "cacheWrite"),
                                     output: output,
                                     reasoning: min(first(u, "reasoningTokens", "reasoningOutputTokens", "thinkingTokens"), output))
            guard !tokens.isZero else { continue }
            out.append(UsageEvent(key: "jun:\(session):\(hash):\(index)", provider: J.str(u["provider"])?.lowercased() ?? "junie",
                                  model: model, timestamp: stamp ?? fallbackTime, tokens: tokens, session: session, file: file))
        }
        return out
    }

    private static func first(_ u: [String: Any], _ keys: String...) -> Int64 {
        for key in keys where u[key] != nil { return max(0, J.int(u[key])) }
        return 0
    }
}
