import Foundation

/// Mistral Vibe `~/.vibe/logs/session/session_*/meta.json` (`$VIBE_HOME`), and the 1.x flat
/// `session_*.json` whose metadata sits under a `metadata` key. The counts are per session and
/// cumulative (`stats.session_prompt_tokens`, `session_completion_tokens`, `session_cached_tokens`),
/// the format carries no per-call counts. One row per session under the key `vibe:<session>`: a
/// grown session writes the same key with larger counts, and the store keeps the larger row, which
/// is the same as counting the growth once. The cached tokens are part of the prompt tokens.
enum VibeParser {
    static func events(data: Data, fallbackSession: String, fallbackTime: Double, file: String) -> [UsageEvent] {
        guard let root = (J.parse(data)) as? [String: Any] else { return [] }
        let meta = J.dict(root["metadata"]) ?? root
        guard let stats = J.dict(meta["stats"]) else { return [] }
        let prompt = max(0, J.int(stats["session_prompt_tokens"], booleans: true)), cached = max(0, J.int(stats["session_cached_tokens"], booleans: true))
        let tokens = TokenCounts(input: max(0, prompt - cached), cacheRead: cached,
                                 output: max(0, J.int(stats["session_completion_tokens"], booleans: true)))
        guard !tokens.isZero else { return [] }
        var time = J.time(meta["end_time"])
        if time <= 0 { time = J.time(meta["start_time"]) }
        if time <= 0 { time = fallbackTime }
        let session = J.str(meta["session_id"]) ?? fallbackSession
        return [UsageEvent(key: "vibe:\(session)", provider: "mistral", model: model(meta), timestamp: time,
                           tokens: tokens, session: session, project: J.str(meta["origin_directory"]), file: file)]
    }

    /// The pinned model, else the single configured one, else Vibe's own default alias. An empty
    /// `active_model` means "unpinned", not a model named "".
    static func model(_ meta: [String: Any]) -> String {
        let config = J.dict(meta["config"])
        if let pinned = J.str(config?["active_model"]) ?? J.str(meta["active_model"]) ?? J.str(meta["model"]) { return pinned }
        let models = J.dict(config?["models"]) ?? [:]
        let aliases = models.map { key, entry in J.str(J.dict(entry)?["alias"]) ?? key }.filter { !$0.isEmpty }.sorted()
        return aliases.count == 1 ? aliases[0] : (aliases.contains("mistral-medium-latest") || aliases.isEmpty ? "mistral-medium-latest" : aliases[0])
    }
}
