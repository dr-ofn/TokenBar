import Foundation

/// Cline, Roo Code and Kilo Code task logs. One folder per task under
/// `<globalStorage>/<extension>/tasks/<id>/`; `ui_messages.json` is one JSON array of messages and
/// every model call is a `say: "api_req_started"` message whose `text` is itself a JSON string:
/// `{"tokensIn", "tokensOut", "cacheWrites", "cacheReads", "cost", "apiProtocol"?}`.
///
/// What `tokensIn` holds depends on the tool and its age (the Roo and Kilo rule is the one
/// tokscale applies to the same logs, `sessions/roocode.rs`):
/// - Cline: always apart from the cache counts, so the four are disjoint as they stand.
/// - Roo Code and Kilo Code, from release 3.29.5 (2025-11-01; the cut is 2025-11-02T00:00:00Z,
///   a day late on purpose): `tokensIn` is the whole prompt, the cache counts included, so the
///   cache counts come out of it. Before that only rows of the OpenAI wire protocol were whole.
/// The extension's own `cost` is not read: prices come from the price table, as for every tool.
/// Tokens only: nothing in these logs splits the reasoning out of `tokensOut`.
///
/// `deleted_api_reqs` rows are read too: when a task is restored to a checkpoint Cline folds the
/// usage of the messages it drops into one such row (its own `getApiMetrics` sums them). Cline's
/// `subagent_usage` snapshots are not read: whether they repeat the subagents' own tasks is unverified.
enum ClineTasksParser {
    enum Style { case cline, roo }

    /// 2025-11-02T00:00:00Z in milliseconds.
    static let wholePromptFromMs: Double = 1_762_041_600_000

    /// The model of a task's calls when its messages do not name one themselves.
    struct ModelHints {
        /// Cline's `task_metadata.json` `model_usage`, in file order: when the model was switched to.
        var switches: [(ts: Double, model: String, provider: String?)] = []
        /// The last `<model>` tag of `api_conversation_history.json` (Roo and Kilo).
        var tagged: String?
    }

    static func events(data: Data, taskID: String, prefix: String, style: Style, fallbackTime: Double,
                       hints: () -> ModelHints, file: String) throws -> [UsageEvent] {
        guard !data.isEmpty else { return [] }
        var out: [UsageEvent] = []
        var seen: [String: Int] = [:]
        var loaded: ModelHints?
        for (index, range) in try usageObjects(data) {
            guard let row = (J.parse(data.subdata(in: range))) as? [String: Any], row["type"] as? String == "say",
                  let say = row["say"] as? String, say == "api_req_started" || say == "deleted_api_reqs",
                  let text = row["text"] as? String, !text.isEmpty,
                  let payload = (J.parse(Data(text.utf8))) as? [String: Any] else { continue }

            let rawTime = J.double(row["ts"])
            // A time that is not a number an Int64 can hold (1e20) is a corrupt one: the row is dated by the file.
            let ms = rawTime.map { $0 < 1e11 ? $0 * 1000 : $0 }.flatMap { Safe.int64($0) != nil ? $0 : nil }
            let cacheRead = max(0, J.int(payload["cacheReads"]))
            let cacheWrite = max(0, J.int(payload["cacheWrites"]))
            var input = max(0, J.int(payload["tokensIn"]))
            let apiProtocol = J.str(payload["apiProtocol"])
            if style == .roo, wholePrompt(ms: ms, apiProtocol: apiProtocol) {
                input = max(0, input - cacheRead - cacheWrite)
            }
            let tokens = TokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite,
                                     output: max(0, J.int(payload["tokensOut"])))
            guard !tokens.isZero else { continue }

            var model = J.str(J.dict(row["modelInfo"])?["modelId"])
            var provider = J.str(J.dict(row["modelInfo"])?["providerId"])
            if model == nil {
                if loaded == nil { loaded = hints() }
                if let found = loaded?.switches.last(where: { $0.ts <= (ms ?? 0) }) {
                    model = found.model
                    provider = provider ?? found.provider
                } else {
                    model = loaded?.tagged
                }
            }
            let name = model ?? "unknown"
            // `split` drops empty pieces, so a name of only slashes has no first one.
            if provider == nil { provider = name.contains("/") ? (name.split(separator: "/").first.map(String.init) ?? apiProtocol) : apiProtocol }

            let stamp = ms.flatMap { Safe.int64($0) }.map { String($0) } ?? "i\(index)"
            var key = "\(prefix):\(taskID):\(say == "deleted_api_reqs" ? "del:" : "")\(stamp)"
            seen[key, default: 0] += 1
            if let n = seen[key], n > 1 { key += ":\(n)" }
            out.append(UsageEvent(key: key, provider: provider ?? "", model: name, timestamp: ms.map { $0 / 1000 } ?? fallbackTime,
                                  tokens: tokens, session: taskID, file: file))
        }
        return out
    }

    /// The top-level objects of the JSON array in `data` that mention a usage message, with their
    /// position in the array. A task log holds screenshots and file contents that dwarf the usage
    /// rows and the extension rewrites it as the task goes: the rest is walked over by bytes
    /// (strings and nesting only) and never decoded. A file that is not an array, or ends inside
    /// one, is an error.
    static func usageObjects(_ data: Data) throws -> [(index: Int, range: Range<Int>)] {
        let wanted = [Array("api_req_started".utf8), Array("deleted_api_reqs".utf8)]
        var out: [(index: Int, range: Range<Int>)] = []
        var closed = false
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
            while i < n, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
            guard i < n, bytes[i] == 0x5B else { throw EditorLogFormatError(message: L10n.t("ui_messages.json geçerli bir JSON dizisi değil", "ui_messages.json is not a valid JSON array")) }
            i += 1
            var depth = 1, index = 0, start = -1
            var inString = false, escaped = false
            while i < n, depth > 0 {
                let c = bytes[i]
                if inString {
                    if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
                } else {
                    switch c {
                    case 0x22: inString = true
                    case 0x7B, 0x5B:
                        if depth == 1, c == 0x7B { start = i }
                        depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 1, c == 0x7D, start >= 0 {
                            let object = UnsafeRawBufferPointer(rebasing: raw[start...i])
                            let hit = wanted.contains { needle in
                                needle.withUnsafeBytes { memmem(object.baseAddress!, object.count, $0.baseAddress!, $0.count) != nil }
                            }
                            if hit { out.append((index, start..<(i + 1))) }
                            start = -1
                        }
                    case 0x2C:
                        if depth == 1 { index += 1 }
                    default:
                        break
                    }
                }
                i += 1
            }
            closed = depth == 0
        }
        guard closed else { throw EditorLogFormatError(message: L10n.t("ui_messages.json yarıda kesilmiş (dizi kapanmıyor)", "ui_messages.json is cut off (the array never closes)")) }
        return out
    }

    /// Whether a Roo or Kilo row's `tokensIn` already holds the cache counts.
    static func wholePrompt(ms: Double?, apiProtocol: String?) -> Bool {
        if let ms, ms >= wholePromptFromMs { return true }
        guard let tail = apiProtocol?.split(separator: "/").last else { return false }
        return tail.trimmingCharacters(in: .whitespaces).lowercased() == "openai"
    }

    /// Cline CLI: `~/.cline/data/sessions/<id>/<id>.messages.json`, `{"sessionId", "messages":[…]}`.
    /// An assistant message carries `modelInfo {id, provider}` and `metrics {inputTokens, outputTokens,
    /// cacheReadTokens, cacheWriteTokens}`. This SDK's `inputTokens` holds the cache counts (the
    /// same rule as tokscale's `parse_cline_cli_file`), so they come out of it.
    static func cliEvents(data: Data, manifest: Data?, sessionFallback: String, prefix: String, fallbackTime: Double,
                          file: String) throws -> [UsageEvent] {
        guard !data.isEmpty else { return [] }
        guard let root = (J.parse(data)) as? [String: Any] else {
            throw EditorLogFormatError(message: L10n.t("messages.json geçerli bir JSON nesnesi değil", "messages.json is not a valid JSON object"))
        }
        let head = manifest.flatMap { (J.parse($0)) as? [String: Any] } ?? [:]
        let session = J.str(root["sessionId"]) ?? J.str(head["session_id"]) ?? sessionFallback
        var model = J.str(head["model"]) ?? "unknown"
        var provider = J.str(head["provider"]) ?? ""
        var out: [UsageEvent] = []
        var assistant = 0
        for case let message as [String: Any] in (root["messages"] as? [Any]) ?? [] {
            guard message["role"] as? String == "assistant" else { continue }
            if let info = J.dict(message["modelInfo"]) {
                model = J.str(info["id"]) ?? model
                provider = J.str(info["provider"]) ?? provider
            }
            guard let metrics = J.dict(message["metrics"]) else { continue }
            let cacheRead = max(0, J.int(metrics["cacheReadTokens"]))
            let cacheWrite = max(0, J.int(metrics["cacheWriteTokens"]))
            let tokens = TokenCounts(input: max(0, J.int(metrics["inputTokens"]) - cacheRead - cacheWrite),
                                     cacheRead: cacheRead, cacheWrite: cacheWrite,
                                     output: max(0, J.int(metrics["outputTokens"])))
            let ordinal = assistant
            assistant += 1
            guard !tokens.isZero else { continue }
            let id = J.str(message["id"]) ?? String(ordinal)
            let time = J.time(message["ts"])
            out.append(UsageEvent(key: "\(prefix):\(session):\(id)", provider: provider, model: model,
                                  timestamp: time > 0 ? time : fallbackTime, tokens: tokens, session: session, file: file))
        }
        return out
    }
}

/// A file that cannot be read as the format it should be: named as a source issue, and read again
/// on the next pass (a file caught half written is fine by then).
struct EditorLogFormatError: LocalizedError, CustomStringConvertible {
    var message: String
    var errorDescription: String? { message }
    var description: String { message }
}
