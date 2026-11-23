import Foundation

/// Reads one oh-my-pi transcript line.
///
/// An assistant message is one JSON object per line, with a usage block like:
///   ..."provider":"my-server","model":"qwen3.8-flash-next","usage":{"input":1200,"output":80,
///   "cacheRead":0,"cacheWrite":0,"totalTokens":1280,"reasoningTokens":30,"cost":{...}},
///   "responseId":"resp_…","timestamp":"2026-01-01T12:00:00.000Z"...
/// Only lines with a `usage` block are counted; header lines name the session and project. The fields are read from
/// the parsed message, not scanned out of the text: spacing between tokens is free, and a `model` or `role` inside the
/// content (a tool call's arguments) is not the message's own. Lines without the word `usage` are never parsed.
///
/// Pi (badlogic/pi-mono) writes the same lines; `piFormat` only changes what differs: the keys
/// start with `pi:`, the reasoning count is `reasoning` and the one-hour cache share is
/// `cacheWrite1h`, and a line without a `responseId` is identified by its own text alone, so a
/// forked session's copy of it is the same call (the session id is left out of the key).
public struct SessionParser {
    private var sessionID: String
    private var cwd: String?
    private let piFormat: Bool
    /// A `"type":"session"` line met while reading names the session and project (the default, for a caller that feeds lines
    /// one by one). A file reader turns it off after `seedHeader(path:)`: only the file's first non-blank line is a header.
    public var adoptsHeaderLines = true

    public init(sessionID: String, cwd: String? = nil, piFormat: Bool = false) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.piFormat = piFormat
    }

    public var currentCwd: String? { cwd }

    /// The session and project of the file's header: its first non-blank line (a UTF-8 BOM in front is no content),
    /// when that line is `"type":"session"`; any other first line means there is no header and the file's name stands in.
    /// The same rule as the Windows reader and the oracle: the header is found wherever the key sits in the line, and
    /// the same whether the file is read whole or from where an earlier pass stopped. Later `session` lines are no header.
    public mutating func seedHeader(path: String) {
        var header: [String: Any]?
        _ = try? LineReader.forEachLine(path: path, from: 0, upTo: 65536, consumeTrailingLine: true) { (line: UnsafeRawBufferPointer) -> Bool in
            var bytes = line
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { bytes = UnsafeRawBufferPointer(rebasing: bytes[3...]) }
            if bytes.allSatisfy({ (byte: UInt8) -> Bool in byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A }) { return true }
            header = J.object(bytes)
            return false
        }
        guard let header, (header["type"] as? String) == "session" else { return }
        if let id = J.str(header["id"]) { sessionID = id }
        if let path = J.str(header["cwd"]) { cwd = path }
    }

    /// An event for a usage line, nil for everything else.
    public mutating func consume(line: UnsafeRawBufferPointer, filePath: String) -> UsageEvent? {
        let hasUsage = line.contains("\"usage\"")
        // A header line has `"session"` somewhere in it (it may sit past any fixed number of bytes: the key order is free).
        let maybeHeader = adoptsHeaderLines && line.contains("\"session\"")
        guard hasUsage || maybeHeader, let object = J.object(line) else { return nil }
        if (object["type"] as? String) == "session" {
            if adoptsHeaderLines {
                if let id = J.str(object["id"]) { sessionID = id }
                if let path = J.str(object["cwd"]) { cwd = path }
            }
            return nil
        }
        guard hasUsage else { return nil }

        let message = J.dict(object["message"]) ?? object
        // A `task` result repeats its subagents' usage; their own transcripts already count it.
        if (message["role"] as? String) == "toolResult" || (object["role"] as? String) == "toolResult" { return nil }
        guard let usage = J.dict(message["usage"]) else { return nil }
        let counts = usageTokens(usage)
        if counts.isZero { return nil }

        var provider = J.str(message["provider"]) ?? ""
        var model = J.str(message["model"]) ?? "unknown"
        // Some records embed the provider in the model id: "my-server/qwen3.8-flash-next".
        if model.contains("/") {
            let parts = model.split(separator: "/", omittingEmptySubsequences: false)
            if provider.isEmpty && parts.count >= 2 {
                provider = String(parts[0])
                model = parts.dropFirst().joined(separator: "/")
            } else if parts.count == 2 && String(parts[0]) == provider {
                model = String(parts[1])
            }
        }
        let responseID = J.str(message["responseId"])
        let timestamp = J.time(object["timestamp"] ?? message["timestamp"])

        let key: String
        if piFormat {
            key = responseID.map { "pi:\($0)" } ?? "pi:line:\(line.fnv1a())"
        } else {
            key = responseID.map { "omp:\($0)" } ?? "omp:\(sessionID):\(line.fnv1a())"
        }
        return UsageEvent(key: key, provider: provider, model: model, timestamp: timestamp,
                          tokens: counts, session: sessionID, project: cwd, file: filePath)
    }

    // MARK: usage numbers

    /// A whole, non-negative number of tokens. A decimal value is a cost field, never a count; a digit run wider than
    /// Int64 saturates (the cap leaves room to add the four total fields without overflowing the sum).
    private func whole(_ value: Any?) -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let cap = Int64.max / 4
        if CFNumberIsFloatType(number) {
            let d = number.doubleValue
            // An integer too wide for Int64 reads as a float: it saturates; any other decimal is a cost.
            return d.isFinite && d >= 9.0e18 && d == d.rounded() ? cap : 0
        }
        return min(max(number.int64Value, 0), cap)
    }

    private func usageTokens(_ usage: [String: Any]) -> TokenCounts {
        let output = whole(usage["output"])
        let cacheWrite = whole(usage["cacheWrite"])
        var reasoning = whole(usage["reasoningTokens"])
        var cacheWrite1h: Int64 = 0
        if piFormat {
            let own = whole(usage["reasoning"])
            if own > 0 { reasoning = own }
            cacheWrite1h = whole(usage["cacheWrite1h"])
        }
        // In Pi the reasoning count is part of `output`, and the one-hour share part of `cacheWrite`.
        return TokenCounts(input: whole(usage["input"]), cacheRead: whole(usage["cacheRead"]), cacheWrite: cacheWrite, output: output,
                           reasoning: piFormat ? min(reasoning, output) : reasoning,
                           cacheWrite1h: piFormat ? min(cacheWrite1h, cacheWrite) : 0)
    }
}
