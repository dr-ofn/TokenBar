import Foundation

/// Devin CLI's `~/.local/share/devin/cli/sessions.db`: assistant rows of `message_nodes` carry
/// `chat_message.metadata.metrics`. `input_tokens` is the fresh input; the cache reads and
/// writes are counted apart (`context_input_tokens` is their sum with it), so the four counts
/// are disjoint. One request can be saved twice, so `metadata.request_id` is the dedup key,
/// with the node id standing in when a row has none.
///
/// The keys carry `:db:` after the session id, which no transcript key has, so the two
/// sources of one session can never collide. A session that has a transcript is read from the
/// transcript only (`DevinParser`); this parser is for the sessions that have none.
enum DevinDBParser {
    struct Row {
        var session: String
        var node: Int64
        var requestID: String?
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
        var time: Double
        var generationModel: String?
        var sessionModel: String?
        var workingDirectory: String?
    }

    static func event(_ row: Row, file: String) -> UsageEvent? {
        let tokens = TokenCounts(input: max(0, row.input), cacheRead: max(0, row.cacheRead),
                                 cacheWrite: max(0, row.cacheWrite), output: max(0, row.output))
        guard !tokens.isZero else { return nil }
        let id = J.str(row.requestID) ?? "n\(row.node)"
        return UsageEvent(key: "devin:\(row.session):db:\(id)", provider: "devin",
                          model: real(row.generationModel) ?? real(row.sessionModel) ?? "unknown",
                          timestamp: row.time, tokens: tokens, session: row.session,
                          project: J.str(row.workingDirectory), file: file)
    }

    /// `adaptive` is a routing mode of Devin, not a model.
    private static func real(_ model: String?) -> String? {
        guard let name = J.str(model), name != "adaptive" else { return nil }
        return name
    }
}
