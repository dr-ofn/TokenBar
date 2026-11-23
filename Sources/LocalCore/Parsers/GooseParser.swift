import Foundation

/// Goose (Block): one row of `sessions` in `sessions.db`.
///
/// The `accumulated_*` columns hold the session's running totals; the plain ones hold the latest
/// call and stand in only for a session that has no accumulated numbers. Goose's `input_tokens`
/// counts every prompt token, cache reads and writes included (they are subsets of it), so the
/// fresh input is what is left after them. Goose has no reasoning column: whatever it counts
/// as output is output.
enum GooseParser {
    struct Row {
        var id: String
        var modelConfigJSON: String?
        var provider: String?
        var time: Double
        var input: Int64?
        var output: Int64?
        var cacheRead: Int64?
        var cacheWrite: Int64?
        var workingDir: String?
    }

    static func event(_ row: Row, file: String) -> UsageEvent? {
        guard !row.id.isEmpty else { return nil }
        let prompt = max(0, row.input ?? 0)
        let cacheRead = min(max(0, row.cacheRead ?? 0), prompt)
        let cacheWrite = min(max(0, row.cacheWrite ?? 0), prompt - cacheRead)
        let tokens = TokenCounts(input: prompt - cacheRead - cacheWrite, cacheRead: cacheRead, cacheWrite: cacheWrite,
                                 output: max(0, row.output ?? 0))
        guard !tokens.isZero else { return nil }
        return UsageEvent(key: "goose:\(row.id)", provider: J.str(row.provider) ?? "goose", model: model(row.modelConfigJSON),
                          timestamp: row.time, tokens: tokens, session: row.id, project: J.str(row.workingDir), file: file)
    }

    /// `{"model_name": "..."}`; anything else is an unnamed model.
    static func model(_ json: String?) -> String {
        guard let data = json?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = J.str(object["model_name"])?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "unknown" }
        return name
    }
}
