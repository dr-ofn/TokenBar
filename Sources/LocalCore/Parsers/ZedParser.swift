import Foundation

/// Zed's agent threads: `~/Library/Application Support/Zed/threads/threads.db`, table
/// `threads(id, summary, updated_at, data_type, data, …)`. `data` is the thread's JSON (`DbThread`,
/// `crates/agent/src/db.rs`), plain when `data_type` is `json` and zstd-compressed when it is `zstd`.
/// In it: `model {provider, model}`, `request_token_usage` (user message id -> `TokenUsage`) and
/// `cumulative_token_usage`; `TokenUsage` is `{input_tokens, output_tokens, cache_creation_input_tokens,
/// cache_read_input_tokens}` (`crates/language_model_core`).
///
/// One event per request. A request has no time of its own: it is dated at the thread's creation
/// (its last update when the column is missing). The cumulative figure can hold more than the requests
/// (a thread older than the per-request map): the difference is an adjustment row, `zed:adj:<thread>`.
/// Zed's providers differ on whether `input_tokens` counts the cache; it is taken as it stands.
enum ZedParser {
    static func events(threadID: String, createdAt: String?, updatedAt: String?, json: Data, file: String) -> [UsageEvent] {
        guard let thread = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              (thread["imported"] as? Bool) != true else { return [] }
        let model = J.dict(thread["model"])
        let name = J.str(model?["model"]) ?? "unknown"
        let provider = J.str(model?["provider"]) ?? "zed"
        let time = [createdAt, updatedAt, J.str(thread["updated_at"])].compactMap { $0 }
            .compactMap { ISOTime.parse($0) }.first ?? 0

        var out: [UsageEvent] = []
        var sum = TokenCounts()
        let requests: [(String, Any)]
        if let map = thread["request_token_usage"] as? [String: Any] {
            requests = map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else if let list = thread["request_token_usage"] as? [Any] {
            requests = list.enumerated().map { (String($0.offset), $0.element) }
        } else {
            requests = []
        }
        for (id, value) in requests {
            let tokens = counts(value)
            guard !tokens.isZero else { continue }
            sum += tokens
            out.append(UsageEvent(key: "zed:\(threadID):\(id)", provider: provider, model: name, timestamp: time,
                                  tokens: tokens, session: threadID, file: file))
        }
        let all = counts(thread["cumulative_token_usage"])
        let gap = TokenCounts(input: max(0, all.input - sum.input), cacheRead: max(0, all.cacheRead - sum.cacheRead),
                              cacheWrite: max(0, all.cacheWrite - sum.cacheWrite), output: max(0, all.output - sum.output))
        if !gap.isZero {
            out.append(UsageEvent(key: "zed:adj:\(threadID)", provider: provider, model: name, timestamp: time,
                                  tokens: gap, session: threadID, file: file))
        }
        return out
    }

    private static func counts(_ value: Any?) -> TokenCounts {
        guard let u = J.dict(value) else { return TokenCounts() }
        return TokenCounts(input: max(0, J.int(u["input_tokens"])), cacheRead: max(0, J.int(u["cache_read_input_tokens"])),
                           cacheWrite: max(0, J.int(u["cache_creation_input_tokens"])), output: max(0, J.int(u["output_tokens"])))
    }
}
