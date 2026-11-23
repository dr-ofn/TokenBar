import Foundation

/// `~/.kimi-code/sessions/<wd>/<session>/agents/<agent>/wire.jsonl`. `llm.request` names the model;
/// each `step.end` loop event carries that step's `usage {inputOther, inputCacheRead, inputCacheCreation, output}`.
struct KimiParser {
    /// Model alias of the most recent request ("provider/model").
    var model: String?
    let sessionID: String
    let file: String
    var events: [UsageEvent] = []

    mutating func consume(line: UnsafeRawBufferPointer) {
        if line.contains("\"type\":\"llm.request\"") || line.contains("\"type\": \"llm.request\"") {
            if let o = J.object(line) { model = J.str(o["modelAlias"]) ?? J.str(o["model"]) ?? model }
            return
        }
        guard line.contains("step.end"), line.contains("\"usage\""), let o = J.object(line),
              let e = J.dict(o["event"]), J.str(e["type"]) == "step.end",
              let u = J.dict(e["usage"]) else { return }
        let tokens = TokenCounts(input: J.int(u["inputOther"]), cacheRead: J.int(u["inputCacheRead"]),
                                 cacheWrite: J.int(u["inputCacheCreation"]), output: J.int(u["output"]))
        guard !tokens.isZero else { return }
        let alias = model ?? "unknown"
        let parts = alias.split(separator: "/", maxSplits: 1).map(String.init)
        let id = J.str(e["messageId"]) ?? J.str(e["uuid"]) ?? String(line.fnv1a(), radix: 16)
        events.append(UsageEvent(key: "kimi:\(sessionID):\(id)", provider: parts.count == 2 ? parts[0] : "",
                                 model: parts.count == 2 ? parts[1] : alias,
                                 timestamp: J.time(o["time"]), tokens: tokens,
                                 session: sessionID, file: file))
    }
}
