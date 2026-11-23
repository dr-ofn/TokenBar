import Foundation

/// Crush (Charm): one row of `sessions` in `<project>/.crush/crush.db`.
///
/// The token columns are overwritten, not added to: `prompt_tokens` is the prompt size of the
/// session's latest step (input + cache read + cache write, not separable) and
/// `completion_tokens` its output. A session is therefore one event with a stable key, and a
/// later scan replaces it when it grew (the store keeps the larger total), so a re-scan never
/// counts a session twice. Crush counts only the latest step, so its own numbers fall short of
/// what the session consumed in all.
enum CrushParser {
    static func event(sessionID: String, promptTokens: Int64, completionTokens: Int64, time: Double,
                      model: String?, provider: String?, project: String?, file: String) -> UsageEvent? {
        guard !sessionID.isEmpty else { return nil }
        let tokens = TokenCounts(input: promptTokens, output: completionTokens)
        guard !tokens.isZero else { return nil }
        let name = model.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let vendor = provider.flatMap { $0.isEmpty ? nil : $0 } ?? "crush"
        return UsageEvent(key: "crush:\(sessionID)", provider: vendor, model: name, timestamp: time,
                          tokens: tokens, session: sessionID, project: project, file: file)
    }
}
