import Foundation

/// Continue's `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl` (`$CONTINUE_GLOBAL_DIR` moves
/// `~/.continue`): one line per model call, `{"timestamp", "model", "provider", "promptTokens",
/// "generatedTokens", …}`. Source: `core/llm/index.ts` `_logEnd` writes them, `core/data/log.ts` appends the line.
///
/// These are Continue's own `countTokens` figures over the prompt and the completion text, not
/// what the provider reported: no cache split, no reasoning, and they can differ from the bill.
/// `devdata.sqlite` (`tokens_generated`) is written by the same call with the same numbers, so only
/// the JSONL is read. A line has no id of its own: its key is the hash of the line.
enum ContinueParser {
    static func event(line: UnsafeRawBufferPointer, file: String, prefix: String = "continue") -> UsageEvent? {
        guard let o = J.object(line), let model = J.str(o["model"]) else { return nil }
        let tokens = TokenCounts(input: max(0, J.int(o["promptTokens"])), output: max(0, J.int(o["generatedTokens"])))
        guard !tokens.isZero else { return nil }
        return UsageEvent(key: "\(prefix):\(line.fnv1a())", provider: J.str(o["provider"]) ?? "", model: model,
                          timestamp: J.time(o["timestamp"]), tokens: tokens, session: "continue", file: file)
    }
}
