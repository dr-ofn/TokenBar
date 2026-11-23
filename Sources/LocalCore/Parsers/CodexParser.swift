import Foundation

/// Codex rollout files. `token_count` events hold cumulative totals and repeat, so a call is
/// the difference between consecutive distinct totals. `input_tokens` includes the cached
/// ones and `output_tokens` the reasoning. State survives between incremental reads.
struct CodexParser {
    struct Totals: Codable {
        var input: Int64 = 0
        var cached: Int64 = 0
        var cacheWrite: Int64 = 0
        var output: Int64 = 0
        var reasoning: Int64 = 0
        var total: Int64 = 0

        init() {}

        init(_ dict: [String: Any]) {
            input = J.int(dict["input_tokens"])
            cached = J.int(dict["cached_input_tokens"])
            cacheWrite = J.int(dict["cache_write_input_tokens"])
            output = J.int(dict["output_tokens"])
            reasoning = J.int(dict["reasoning_output_tokens"])
            let totalTokens = J.int(dict["total_tokens"])
            total = totalTokens > 0 ? totalTokens : input + output
        }

        static func - (lhs: Totals, rhs: Totals) -> Totals {
            var diff = Totals()
            diff.input = max(0, lhs.input - rhs.input)
            diff.cached = max(0, lhs.cached - rhs.cached)
            diff.cacheWrite = max(0, lhs.cacheWrite - rhs.cacheWrite)
            diff.output = max(0, lhs.output - rhs.output)
            diff.reasoning = max(0, lhs.reasoning - rhs.reasoning)
            diff.total = max(0, lhs.total - rhs.total)
            return diff
        }

        var counts: TokenCounts {
            let cachedInput = min(cached, input)
            let writes = min(cacheWrite, max(0, input - cachedInput))
            return TokenCounts(
                input: max(0, input - cachedInput - writes),
                cacheRead: cachedInput,
                cacheWrite: writes,
                output: output,
                reasoning: min(reasoning, output)
            )
        }
    }

    struct State: Codable {
        var sessionID: String?
        var provider: String?
        var model: String?
        var cwd: String?
        var startedAt: Double?
        var last: Totals?
        var turnStartedAt: Double?
        var epoch: Int?
    }

    var state: State
    private(set) var events: [UsageEvent] = []
    let fallbackSession: String
    let file: String

    mutating func consume(line: UnsafeRawBufferPointer) {
        if line.indexOf("\"session_meta\"", limit: 160) >= 0 {
            guard state.sessionID == nil, let obj = J.object(line) else { return }
            parseSessionMeta(obj)
        } else if line.indexOf("\"turn_context\"", limit: 160) >= 0 {
            guard let obj = J.object(line), let payload = J.dict(obj["payload"]) else { return }
            parseTurnContext(payload)
        } else if line.indexOf("\"task_started\"", limit: 200) >= 0 {
            guard let obj = J.object(line), let payload = J.dict(obj["payload"]) else { return }
            parseTaskStarted(payload)
        } else if line.contains("\"token_count\"") {
            guard let obj = J.object(line) else { return }
            parseTokenCount(obj)
        }
    }

    private mutating func parseSessionMeta(_ obj: [String: Any]) {
        guard (obj["type"] as? String) == "session_meta", let payload = J.dict(obj["payload"]) else { return }
        // Only the first session_meta describes this file; forks append the parent's after it.
        state.sessionID = J.str(payload["id"]) ?? J.str(payload["session_id"]) ?? fallbackSession
        state.provider = J.str(payload["model_provider"]) ?? "openai"
        if state.cwd == nil {
            state.cwd = J.str(payload["cwd"])
        }
        if let stamp = J.str(payload["timestamp"]) ?? J.str(obj["timestamp"]) {
            state.startedAt = ISOTime.parse(stamp)
        }
    }

    private mutating func parseTurnContext(_ payload: [String: Any]) {
        if let model = J.str(payload["model"]) {
            if state.model == nil {
                // Usage logged before the first turn_context belongs to this model.
                for i in events.indices where events[i].model == "unknown" {
                    events[i].model = model
                }
            }
            state.model = model
        }
        if state.cwd == nil {
            state.cwd = J.str(payload["cwd"])
        }
    }

    private mutating func parseTaskStarted(_ payload: [String: Any]) {
        guard (payload["type"] as? String) == "task_started",
              J.double(payload["started_at"]) != nil else { return }
        state.turnStartedAt = J.time(payload["started_at"])
    }

    private mutating func parseTokenCount(_ obj: [String: Any]) {
        guard (obj["type"] as? String) == "event_msg",
              let payload = J.dict(obj["payload"]),
              (payload["type"] as? String) == "token_count",
              let stamp = J.str(obj["timestamp"]),
              let lineTime = ISOTime.parse(stamp),
              let info = J.dict(payload["info"]),
              let totalsDict = J.dict(info["total_token_usage"]) else { return }

        let total = Totals(totalsDict)
        guard total.total > 0 else { return }
        let time = max(lineTime, state.turnStartedAt ?? lineTime)

        // History replayed from a parent session predates this file.
        if let start = state.startedAt, time < start - 1 {
            state.last = total
            return
        }

        let delta: Totals
        if let last = state.last {
            if total.total == last.total { return } // repeated totals: not a new call
            if total.total > last.total {
                delta = total - last
            } else {
                state.epoch = (state.epoch ?? 0) + 1
                delta = J.dict(info["last_token_usage"]).map(Totals.init) ?? total
            }
        } else {
            delta = total
        }
        state.last = total

        let tokens = delta.counts
        guard !tokens.isZero else { return }

        let session = state.sessionID ?? fallbackSession
        let epoch = state.epoch.map { ":e\($0)" } ?? ""
        let key = "cx:\(session)\(epoch):\(total.total)"
        let event = UsageEvent(
            key: key,
            provider: state.provider ?? "openai",
            model: state.model ?? "unknown",
            timestamp: time,
            tokens: tokens,
            session: session,
            project: state.cwd,
            file: file
        )
        events.append(event)
    }
}
