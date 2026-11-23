import Foundation

/// Parses lines from OpenDesign `events.jsonl` files.
/// `status` lines update the active model; `request_usage` lines emit token usage events.
struct OpenDesignParser {
    var model = "unknown"
    let session: String
    let file: String
    /// Dedup-key prefix; `od` unless the source is configured otherwise.
    var prefix = "od"

    mutating func consume(line: UnsafeRawBufferPointer) -> UsageEvent? {
        guard line.contains("request_usage") || line.contains("\"status\""),
              let obj = J.object(line),
              let data = J.dict(obj["data"]) else {
            return nil
        }

        let type = J.str(data["type"])
        if type == "status" {
            if let m = J.str(data["model"]) {
                model = m
            }
            return nil
        }

        guard type == "request_usage",
              let requestId = J.str(data["requestId"]),
              let usage = J.dict(data["usage"]) else {
            return nil
        }

        let tokens = TokenCounts(
            input: J.int(usage["input_tokens"]),
            cacheRead: J.int(usage["cache_read_input_tokens"]),
            cacheWrite: J.int(usage["cache_creation_input_tokens"]),
            output: J.int(usage["output_tokens"])
        )
        guard !tokens.isZero else { return nil }

        return UsageEvent(
            key: "\(prefix):\(requestId)",
            provider: "anthropic",
            model: model,
            timestamp: J.time(obj["timestamp"]),
            tokens: tokens,
            session: session,
            file: file
        )
    }
}
