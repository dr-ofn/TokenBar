import Foundation

/// Claude Code transcripts (`~/.claude/projects/**/*.jsonl`).
///
/// Claude Code writes one line per content block, so one API response appears several times
/// with the same `message.id` + `requestId`, and a resumed session copies earlier lines into
/// a new file. That pair is the dedup key.
enum ClaudeParser {
    static func events(object obj: [String: Any], file: String) -> [UsageEvent] {
        guard (obj["type"] as? String) == "assistant",
              let message = J.dict(obj["message"]),
              let usage = J.dict(message["usage"]),
              let stamp = J.str(obj["timestamp"]), let time = ISOTime.parse(stamp) else { return [] }
        let model = baseModel(J.str(message["model"]) ?? "unknown")
        if model == "<synthetic>" { return [] } // client-side placeholder, never billed

        let id = J.str(message["id"]) ?? J.str(obj["uuid"]) ?? "\(stamp)|\(model)"
        let key = "cc:\(id):\(J.str(obj["requestId"]) ?? "")"
        func event(_ key: String, _ model: String, _ usage: [String: Any]) -> UsageEvent {
            UsageEvent(key: key, provider: provider(model), model: model, timestamp: time, tokens: counts(usage),
                       session: J.str(obj["sessionId"]) ?? "", project: J.str(obj["cwd"]), file: file)
        }
        var out = [event(key, model, usage)]
        // Passes other than `message` (an advisor consulted mid-request) are billed on top
        // of the top-level usage, under their own model.
        for (i, pass) in ((usage["iterations"] as? [[String: Any]]) ?? []).enumerated() {
            let kind = J.str(pass["type"]) ?? "message"
            if kind != "message" { out.append(event("\(key):\(kind):\(i)", J.str(pass["model"]).map(baseModel) ?? model, pass)) }
        }
        return out.filter { !$0.tokens.isZero }
    }

    /// The model without the context-window suffix Claude Code appends (`claude-opus-5-5[1m]`).
    /// Transcript rows and `cost-state` lines must name a model the same way, or the gap
    /// between them is computed against a name that never matches and counts everything twice.
    static func baseModel(_ raw: String) -> String {
        guard let bracket = raw.firstIndex(of: "["), bracket != raw.startIndex else { return raw }
        return String(raw[..<bracket])
    }

    static func provider(_ model: String) -> String { model.hasPrefix("claude") ? "anthropic" : "custom" }

    private static func counts(_ u: [String: Any]) -> TokenCounts {
        let write = J.int(u["cache_creation_input_tokens"])
        let output = J.int(u["output_tokens"])
        return TokenCounts(input: J.int(u["input_tokens"]), cacheRead: J.int(u["cache_read_input_tokens"]),
                           cacheWrite: write, output: output,
                           reasoning: min(J.int(J.dict(u["output_tokens_details"])?["thinking_tokens"]), output),
                           cacheWrite1h: min(J.int(J.dict(u["cache_creation"])?["ephemeral_1h_input_tokens"]), write))
    }
}

/// Claude Code's own accounting of a session (`cost-state` line). It holds calls the
/// transcript never shows, so what it has beyond the transcript becomes an adjustment row.
struct ClaudeCostState: Codable {
    /// Unix seconds of the process run → model name as the line spelled it (`claude-opus-5-5[1m]` stays apart from
    /// `claude-opus-5-5`: they are two cumulative counters) → [input, cacheRead, cacheWrite, output].
    var runs: [String: [String: [Int64]]] = [:]

    /// Each line is cumulative for its run: the largest count per name stands.
    mutating func merge(object obj: [String: Any]) {
        guard let usage = J.dict(obj["modelUsage"]) else { return }
        let run = Safe.seconds(J.time(obj["startTime"])).map { String($0) } ?? "0"
        for (raw, value) in usage {
            guard let u = J.dict(value) else { continue }
            let new = [J.int(u["inputTokens"]), J.int(u["cacheReadInputTokens"]),
                       J.int(u["cacheCreationInputTokens"]), J.int(u["outputTokens"])]
            let old = runs[run]?[raw] ?? [0, 0, 0, 0]
            runs[run, default: [:]][raw] = zip(old, new).map(Swift.max)
        }
    }

    /// Per model (context-window suffix dropped), the sum over the names and the runs. The names are folded here, not
    /// when a line is merged, so a copy saved before the suffix was dropped (or one that names both spellings in one
    /// run) adds up instead of being replaced by the larger of the two.
    var models: [String: [Int64]] {
        var out: [String: [Int64]] = [:]
        for run in runs.values {
            for (raw, counts) in run {
                let model = ClaudeParser.baseModel(raw)
                out[model] = zip(out[model] ?? [0, 0, 0, 0], counts).map(TokenCounts.saturatingSum)
            }
        }
        return out
    }

    var lastRun: Double { runs.keys.compactMap(Double.init).max() ?? 0 }
}
