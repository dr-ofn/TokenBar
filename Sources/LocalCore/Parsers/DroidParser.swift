import Foundation

/// Factory Droid: `~/.factory/sessions/**/<id>.settings.json`, rewritten in place as the session
/// grows. `tokenUsage` is the session's running total, so the session is one event with a stable
/// key: a rewrite replaces it (the store keeps the larger total) and nothing is counted twice.
///
/// `thinkingTokens` is counted on top of `outputTokens` and shown as the reasoning share. That
/// follows ccusage's reading of the file (Factory publishes no schema); it was not checked
/// against Factory's own code.
enum DroidParser {
    static func event(data: Data, session: String, file: String, fallbackTime: Double) -> UsageEvent? {
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = J.dict(settings["tokenUsage"]) else { return nil }
        let thinking = max(0, J.int(usage["thinkingTokens"]))
        let tokens = TokenCounts(input: max(0, J.int(usage["inputTokens"])),
                                 cacheRead: max(0, J.int(usage["cacheReadTokens"])),
                                 cacheWrite: max(0, J.int(usage["cacheCreationTokens"])),
                                 output: TokenCounts.saturatingSum(max(0, J.int(usage["outputTokens"])), thinking),
                                 reasoning: thinking)
        guard !tokens.isZero else { return nil }
        let model = name(J.str(settings["model"]))
        let stamp = J.str(settings["providerLockTimestamp"]).flatMap(ISOTime.parse) ?? fallbackTime
        return UsageEvent(key: "droid:\(session)", provider: provider(J.str(settings["providerLock"]), model: model),
                          model: model, timestamp: stamp, tokens: tokens, session: session, file: file)
    }

    /// `custom:Claude-Opus-4.5[Proxy]` → `claude-opus-4.5`: no `custom:` prefix, no bracketed label.
    static func name(_ raw: String?) -> String {
        guard var name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "unknown" }
        if name.hasPrefix("custom:") { name.removeFirst("custom:".count) }
        var depth = 0
        var plain = ""
        for ch in name {
            if ch == "[" { depth += 1 } else if ch == "]" { depth = max(0, depth - 1) } else if depth == 0 { plain.append(ch) }
        }
        let clean = plain.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).lowercased()
        return clean.isEmpty ? "unknown" : clean
    }

    static func provider(_ locked: String?, model: String) -> String {
        switch (locked ?? "").lowercased().replacingOccurrences(of: "-", with: "_") {
        case "claude", "anthropic": return "anthropic"
        case "openai": return "openai"
        case "google", "google_ai", "gemini": return "google"
        case "xai", "x_ai", "grok": return "xai"
        case let other where !other.isEmpty: return other
        default:
            if model.contains("claude") || model.contains("opus") || model.contains("sonnet") || model.contains("haiku") { return "anthropic" }
            if model.hasPrefix("gpt-") || model.contains("-gpt-") { return "openai" }
            if model.contains("gemini") { return "google" }
            if model.contains("grok") { return "xai" }
            return "factory"
        }
    }
}
