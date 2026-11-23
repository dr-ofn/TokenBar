import Foundation

/// Codebuff (formerly Manicode) `~/.config/manicode/projects/<project>/chats/<chatId>/chat-messages.json`
/// (`manicode-dev` and `manicode-staging` for the other channels): a JSON array of chat messages.
/// An assistant message carries its usage on `metadata.usage` or `metadata.codebuff.usage`, or,
/// for provider-routed calls, on the last assistant entries of `metadata.runState...messageHistory`.
///
/// Anthropic-style counts (`cache_read_input_tokens`) are separate buckets. OpenAI-style counts
/// (`prompt_tokens` with `prompt_tokens_details.cached_tokens`) hold the cache inside the prompt,
/// so the cached part is taken out of the input then. Whether a given Codebuff build uses one
/// style or the other is not documented by the tool (only tokscale's reader is the source).
enum CodebuffParser {
    private struct Usage {
        var model: String?
        var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0
        /// The cache read came from `prompt_tokens_details`, so it is inside `input`.
        var cacheInsideInput = false

        var hasSignal: Bool { input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 }

        mutating func fillGaps(from other: Usage) {
            if input <= 0 { input = other.input }
            if output <= 0 { output = other.output }
            if cacheRead <= 0 { cacheRead = other.cacheRead; cacheInsideInput = other.cacheInsideInput }
            if cacheWrite <= 0 { cacheWrite = other.cacheWrite }
            if model == nil { model = other.model }
        }
    }

    static func events(data: Data, session: String, chatTime: Double, fallbackTime: Double, file: String) -> [UsageEvent] {
        guard let messages = (J.parse(data)) as? [Any] else { return [] }
        var out: [UsageEvent] = []
        for (ordinal, raw) in messages.enumerated() {
            guard let msg = raw as? [String: Any], isAssistant(msg) else { continue }
            let usage = usage(of: msg)
            guard usage.hasSignal else { continue }
            let input = usage.cacheInsideInput ? max(0, usage.input - usage.cacheRead) : usage.input
            let tokens = TokenCounts(input: input, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite, output: usage.output)
            guard !tokens.isZero else { continue }
            // Without an id the position names the message. The counts are not part of the key: a message read half
            // finished and again finished would otherwise be two.
            let key = J.str(msg["id"]).map { "cbuf:\($0)" } ?? "cbuf:\(session):\(ordinal)"
            let meta = J.dict(msg["metadata"])
            var time = J.time(msg["timestamp"])
            if time == 0 { time = J.time(msg["createdAt"]) }
            if time == 0 { time = J.time(meta?["timestamp"]) }
            if time == 0 { time = chatTime }
            if time == 0 { time = fallbackTime }
            out.append(UsageEvent(key: key, provider: "codebuff", model: usage.model ?? "codebuff-unknown",
                                  timestamp: time, tokens: tokens, session: session, file: file))
        }
        return out
    }

    /// `chatId` is an ISO time with `:` written as `-` (`2025-12-14T10-00-00.000Z`).
    static func chatTime(_ chatID: String) -> Double {
        guard let t = chatID.firstIndex(of: "T") else { return 0 }
        var time = String(chatID[t...])
        for _ in 0..<2 { if let dash = time.firstIndex(of: "-") { time.replaceSubrange(dash...dash, with: ":") } }
        return ISOTime.parse(String(chatID[..<t]) + time) ?? 0
    }

    private static func isAssistant(_ m: [String: Any]) -> Bool {
        ["ai", "agent", "assistant"].contains(J.str(m["variant"]) ?? J.str(m["role"]) ?? "")
    }

    private static func usage(of msg: [String: Any]) -> Usage {
        var usage = Usage()
        guard let meta = J.dict(msg["metadata"]) else { return usage }
        usage.model = J.str(meta["model"])
        if let u = J.dict(meta["usage"]) { usage.fillGaps(from: parse(u)) }
        if let u = J.dict(J.dict(meta["codebuff"])?["usage"]) { usage.fillGaps(from: parse(u)) }
        if let entries = J.dict(J.dict(J.dict(meta["runState"])?["sessionState"])?["mainAgentState"])?["messageHistory"] as? [Any] {
            for case let entry as [String: Any] in entries.reversed() where J.str(entry["role"]) == "assistant" {
                guard let options = J.dict(entry["providerOptions"]) else { continue }
                var found = Usage()
                if let u = J.dict(options["usage"]) { found.fillGaps(from: parse(u)) }
                if let u = J.dict(J.dict(options["codebuff"])?["usage"]) { found.fillGaps(from: parse(u)) }
                found.model = J.str(J.dict(options["codebuff"])?["model"]) ?? found.model
                usage.fillGaps(from: found)
            }
        }
        return usage
    }

    private static func parse(_ v: [String: Any]) -> Usage {
        var u = Usage()
        u.input = pick(v, "inputTokens", "input_tokens", "promptTokens", "prompt_tokens")
        u.output = pick(v, "outputTokens", "output_tokens", "completionTokens", "completion_tokens")
        u.cacheRead = pick(v, "cacheReadInputTokens", "cache_read_input_tokens", "cachedTokensCreated", "cached_tokens_created")
        if u.cacheRead == 0, let d = J.dict(v["promptTokensDetails"] ?? v["prompt_tokens_details"]) {
            u.cacheRead = J.count(d["cachedTokens"] ?? d["cached_tokens"])
            u.cacheInsideInput = u.cacheRead > 0
        }
        u.cacheWrite = pick(v, "cacheCreationInputTokens", "cache_creation_input_tokens", "cacheCreationTokens", "cache_creation_tokens")
        u.model = J.str(v["model"])
        return u
    }

    private static func pick(_ v: [String: Any], _ keys: String...) -> Int64 {
        for key in keys { let n = J.count(v[key]); if n > 0 { return n } }
        return 0
    }
}
