import Foundation

/// Parses opencode SQLite `message` rows.
enum OpenCodeParser {
    static func event(prefix: String, id: String, session: String, directory: String?, json: String, file: String) -> UsageEvent? {
        guard let data = json.data(using: .utf8),
              let obj = (J.parse(data)) as? [String: Any],
              obj["role"] as? String == "assistant",
              let provider = J.str(obj["providerID"]),
              let model = J.str(obj["modelID"]),
              let tokensDict = J.dict(obj["tokens"]) else {
            return nil
        }

        let cache = J.dict(tokensDict["cache"])
        let reasoning = J.int(tokensDict["reasoning"])
        // opencode records output tokens without reasoning tokens, so combine them.
        let tokens = TokenCounts(
            input: J.int(tokensDict["input"]),
            cacheRead: J.int(cache?["read"]),
            cacheWrite: J.int(cache?["write"]),
            output: J.int(tokensDict["output"]) + reasoning,
            reasoning: reasoning
        )
        guard !tokens.isZero else { return nil }

        let timeDict = J.dict(obj["time"])
        let timestamp = J.time(timeDict?["created"])
        let project = J.str(J.dict(obj["path"])?["cwd"]) ?? directory

        return UsageEvent(
            key: "\(prefix):\(id)",
            provider: provider,
            model: model,
            timestamp: timestamp,
            tokens: tokens,
            session: session,
            project: project,
            file: file
        )
    }
}
