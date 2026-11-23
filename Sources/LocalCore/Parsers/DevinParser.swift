import Foundation

/// `~/.local/share/devin/cli/transcripts/<name>.json` (rewritten as the session grows).
/// Agent steps carry `metrics {prompt_tokens (incl. cached), completion_tokens, cached_tokens}`.
enum DevinParser {
    static func events(data: Data, fallbackSession: String, file: String) -> [UsageEvent] {
        guard let o = (J.parse(data)) as? [String: Any],
              let steps = o["steps"] as? [[String: Any]] else { return [] }
        let session = J.str(o["session_id"]) ?? fallbackSession
        let agentModel = J.dict(o["agent"]).flatMap { J.str($0["model_name"]) }
        var out: [UsageEvent] = []
        for s in steps {
            guard let m = J.dict(s["metrics"]) else { continue }
            let prompt = J.int(m["prompt_tokens"]), cached = J.int(m["cached_tokens"])
            let tokens = TokenCounts(input: max(0, prompt - cached), cacheRead: min(cached, prompt),
                                     output: J.int(m["completion_tokens"]))
            guard !tokens.isZero else { continue }
            out.append(UsageEvent(key: "devin:\(session):\(stepKey(s))", provider: "devin",
                                  model: J.str(s["model_name"]) ?? agentModel ?? "unknown",
                                  timestamp: J.time(s["timestamp"]), tokens: tokens,
                                  session: session, file: file))
        }
        return out
    }

    /// `step_id` is absent on some transcripts; fall back to the row's timestamp so two
    /// step-less steps in one session still get distinct, re-read-stable keys.
    private static func stepKey(_ s: [String: Any]) -> String {
        let id = J.int(s["step_id"])
        if id != 0 { return String(id) }
        return J.str(s["timestamp"]) ?? String(J.time(s["timestamp"]))
    }
}
