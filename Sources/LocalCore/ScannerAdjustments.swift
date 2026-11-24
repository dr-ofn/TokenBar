import Foundation

/// One `usage_record.jsonl` line's usage for a session and model, with the line's timestamp.
private struct QwenRecord {
    var usage: [String: Any]
    var time: Double
}

extension UsageScanner {
    /// What each session's `cost-state` holds beyond its transcript rows. The gap has no time
    /// of its own, so it is dated at the start of the session's latest run.
    func updateClaudeAdjustments() throws {
        let rows = try store.metaRows(prefix: Self.costPrefix)
        guard !rows.isEmpty else { return }

        var seen: [String: TokenCounts] = [:]
        for sum in try store.sums(prefix: "cc:", excluding: "cc:adj:") {
            seen[sum.session + "\n" + sum.model] = sum.tokens
        }

        var events: [UsageEvent] = []
        for row in rows {
            let session = String(row.key.dropFirst(Self.costPrefix.count))
            guard let state = try? JSONDecoder().decode(ClaudeCostState.self, from: Data(row.value.utf8)) else { continue }
            for (model, counts) in state.models {
                let gap = claudeGap(counts, over: seen[session + "\n" + model] ?? TokenCounts())
                guard !gap.isZero else { continue }
                events.append(UsageEvent(key: "cc:adj:\(session):\(model)", provider: ClaudeParser.provider(model),
                                         model: model, timestamp: state.lastRun, tokens: gap,
                                         session: session, file: "cost-state", adjustment: true))
            }
        }
        try store.replaceEvents(prefix: "cc:adj:", with: events)
    }

    /// `usage_record.jsonl` lines are cumulative per session: the largest one stands, and what
    /// it holds beyond the per-call lines becomes an adjustment row.
    func updateQwenAdjustments(records paths: [String]) throws {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var latest: [String: QwenRecord] = [:]
        for path in existing {
            for (key, record) in try qwenLatest(in: path) {
                // Across files the larger cumulative record stands, the later one on a tie.
                if J.int(record.usage["totalTokens"]) >= J.int(latest[key]?.usage["totalTokens"]) { latest[key] = record }
            }
        }

        var seen: [String: UsageStore.SessionSum] = [:]
        for sum in try store.sums(prefix: "qwen:", excluding: "qwen:adj:") {
            seen[sum.session + "\n" + sum.model] = sum
        }

        var events: [UsageEvent] = []
        for (key, record) in latest {
            let parts = key.components(separatedBy: "\n")
            let gap = qwenGap(record.usage, over: seen[key]?.tokens ?? TokenCounts())
            guard !gap.isZero else { continue }
            events.append(UsageEvent(key: "qwen:adj:\(parts[0]):\(parts[1])", provider: seen[key]?.provider ?? "qwen",
                                     model: parts[1], timestamp: record.time, tokens: gap,
                                     session: parts[0], file: existing[0], adjustment: true))
        }
        try store.replaceEvents(prefix: "qwen:adj:", with: events)
    }

    /// The largest cumulative record per session and model. On a tie the later line wins.
    private func qwenLatest(in path: String) throws -> [String: QwenRecord] {
        var latest: [String: QwenRecord] = [:]
        _ = try readLines(FileToRead(path: path, offset: 0, limit: .max, settled: true)) { line in
            guard let object = J.object(line), let models = J.dict(object["models"]) else { return }
            let session = J.str(object["sessionId"]) ?? ""
            for (model, value) in models {
                guard let usage = J.dict(value) else { continue }
                let key = session + "\n" + model
                if J.int(usage["totalTokens"]) >= J.int(latest[key]?.usage["totalTokens"]) {
                    latest[key] = QwenRecord(usage: usage, time: J.time(object["timestamp"]))
                }
            }
        }
        return latest
    }

    /// The part of the cost-state counts not already in the transcript rows.
    private func claudeGap(_ counts: [Int64], over old: TokenCounts) -> TokenCounts {
        // The counts come from a saved value that a tool or a user may have cut short.
        guard counts.count >= 4 else { return TokenCounts() }
        return TokenCounts(input: max(0, counts[0] - old.input), cacheRead: max(0, counts[1] - old.cacheRead),
                    cacheWrite: max(0, counts[2] - old.cacheWrite), output: max(0, counts[3] - old.output))
    }

    /// Cumulative input includes cached tokens and output includes thoughts, so split the
    /// gross deltas the way the per-call Qwen rows do.
    private func qwenGap(_ usage: [String: Any], over old: TokenCounts) -> TokenCounts {
        let input = max(0, J.int(usage["inputTokens"]) - (old.input + old.cacheRead))
        let cached = max(0, J.int(usage["cachedTokens"]) - old.cacheRead)
        return TokenCounts(input: max(0, input - cached), cacheRead: min(cached, input),
                           output: max(0, J.int(usage["outputTokens"]) - old.output),
                           reasoning: max(0, J.int(usage["thoughtsTokens"]) - old.reasoning))
    }
}
