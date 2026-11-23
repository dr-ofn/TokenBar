import Foundation

/// Augment Code (Auggie CLI) `~/.augment/sessions/<session>.json`: a snapshot whose `chatHistory[]`
/// turns hold `exchange.response_nodes[].token_usage`. Only `completed` turns count, and a turn's
/// last non-empty usage stands (never a sum). Input and cache counts are separate buckets.
enum AugmentParser {
    static func events(data: Data, fallbackSession: String, fallbackTime: Double, file: String) -> [UsageEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let session = J.str(root["sessionId"]) ?? fallbackSession
        let defaultModel = J.str(J.dict(root["agentState"])?["modelId"])
        var out: [UsageEvent] = []
        for (index, raw) in ((root["chatHistory"] as? [Any]) ?? []).enumerated() {
            guard let turn = raw as? [String: Any], (turn["completed"] as? Bool) == true,
                  let exchange = J.dict(turn["exchange"]) else { continue }
            var tokens: TokenCounts?
            for case let node as [String: Any] in ((exchange["response_nodes"] as? [Any]) ?? []).reversed() {
                guard let u = J.dict(node["token_usage"]) else { continue }
                let counts = TokenCounts(input: J.count(u["input_tokens"]), cacheRead: J.count(u["cache_read_input_tokens"]),
                                         cacheWrite: J.count(u["cache_creation_input_tokens"]), output: J.count(u["output_tokens"]))
                if !counts.isZero { tokens = counts; break }
            }
            guard let tokens else { continue }
            let model = J.str(exchange["model_id"]) ?? defaultModel ?? "unknown"
            let key: String
            if let request = J.str(exchange["request_id"]) {
                key = "aug:\(session):req:\(request)"
            } else if let sequence = turn["sequenceId"], !(sequence is NSNull), "\(sequence)" != "" {
                key = "aug:\(session):seq:\(sequence)"
            } else {
                key = "aug:\(session):turn:\(index)"
            }
            let finished = J.time(turn["finishedAt"])
            out.append(UsageEvent(key: key, provider: model.hasPrefix("claude") ? "anthropic" : "augment", model: model,
                                  timestamp: finished > 0 ? finished : fallbackTime, tokens: tokens, session: session, file: file))
        }
        return out
    }
}
