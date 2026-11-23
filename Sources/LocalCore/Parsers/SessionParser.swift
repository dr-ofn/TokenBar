import Foundation

/// Scans one oh-my-pi transcript line in place, without building a JSON tree.
///
/// An assistant message is one JSON object per line, with a usage block like:
///   ..."provider":"my-server","model":"qwen3.8-flash-next","usage":{"input":1200,"output":80,
///   "cacheRead":0,"cacheWrite":0,"totalTokens":1280,"reasoningTokens":30,"cost":{...}},
///   "responseId":"resp_…","timestamp":"2026-01-01T12:00:00.000Z"...
/// Only lines carrying `"usage":{` are counted; header lines name the session and project.
///
/// Pi (badlogic/pi-mono) writes the same lines; `piFormat` only changes what differs: the keys
/// start with `pi:`, the reasoning count is `reasoning` and the one-hour cache share is
/// `cacheWrite1h`, and a line without a `responseId` is identified by its own text alone, so a
/// forked session's copy of it is the same call (the session id is left out of the key).
public struct SessionParser {
    private var sessionID: String
    private var cwd: String?
    private let piFormat: Bool

    public init(sessionID: String, cwd: String? = nil, piFormat: Bool = false) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.piFormat = piFormat
    }

    public var currentCwd: String? { cwd }

    /// An event for a usage line, nil for everything else.
    public mutating func consume(line: UnsafeRawBufferPointer, filePath: String) -> UsageEvent? {
        if line.indexOf(StaticString("\"type\":\"session\""), limit: 80) >= 0 {
            if let id = stringValue(line, key: StaticString("\"id\":\"")) { sessionID = id }
            if let path = stringValue(line, key: StaticString("\"cwd\":\"")) { cwd = path }
            return nil
        }

        let usageAt = line.indexOf(StaticString("\"usage\":{"))
        if usageAt < 0 { return nil }
        // A `task` result repeats its subagents' usage; their own transcripts already count it.
        if line.indexOf(StaticString("\"role\":\"toolResult\"")) >= 0 { return nil }
        let counts = usageTokens(line, from: usageAt)
        if counts.isZero { return nil }

        var provider = stringValue(line, key: StaticString("\"provider\":\"")) ?? ""
        var model = stringValue(line, key: StaticString("\"model\":\"")) ?? "unknown"
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
        let responseID = stringValue(line, key: StaticString("\"responseId\":\""))
        let timestamp = timestampOf(line)

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

    private func usageTokens(_ line: UnsafeRawBufferPointer, from usageAt: Int) -> TokenCounts {
        var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0
        var cacheWrite1h: Int64 = 0
        var i = usageAt + 9 // past "usage":{
        let end = line.count
        let base = line.baseAddress!
        // A quarter of Int64 is the most one field may take and still sum with the other three.
        let usageCap = Int64.max / 4
        while i < end {
            let c = line[i]
            if c == 0x7D { break } // end of the usage object
            if c != 0x22 { i += 1; continue }
            i += 1
            let keyStart = i
            while i < end, line[i] != 0x22 { i += 1 }
            let keyLen = i - keyStart
            i += 1
            if i >= end || line[i] != 0x3A { continue }
            i += 1

            // A nested object such as "cost":{...} is skipped whole; its floats never count.
            if i < end, line[i] == 0x7B {
                var depth = 1
                i += 1
                while i < end, depth > 0 {
                    if line[i] == 0x7B { depth += 1 } else if line[i] == 0x7D { depth -= 1 }
                    i += 1
                }
                continue
            }

            var value: Int64 = 0
            while i < end, line[i] >= 48, line[i] <= 57 {
                // Saturate rather than trap on a digit run wider than Int64. The cap leaves
                // room to add the four total fields without overflowing the sum.
                if value > (usageCap - 9) / 10 { value = usageCap }
                else { value = value * 10 + Int64(line[i] - 48) }
                i += 1
            }
            // A decimal value is a cost field, never a token count.
            if i < end, line[i] == 0x2E { continue }

            if keyIs(line, base, keyStart, keyLen, StaticString("input")) { input = value }
            else if keyIs(line, base, keyStart, keyLen, StaticString("output")) { output = value }
            else if keyIs(line, base, keyStart, keyLen, StaticString("cacheRead")) { cacheRead = value }
            else if keyIs(line, base, keyStart, keyLen, StaticString("cacheWrite")) { cacheWrite = value }
            else if keyIs(line, base, keyStart, keyLen, StaticString("reasoningTokens")) { reasoning = value }
            else if piFormat, keyIs(line, base, keyStart, keyLen, StaticString("reasoning")) { reasoning = value }
            else if piFormat, keyIs(line, base, keyStart, keyLen, StaticString("cacheWrite1h")) { cacheWrite1h = value }
        }
        // In Pi the reasoning count is part of `output`, and the one-hour share part of `cacheWrite`.
        return TokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
                           reasoning: piFormat ? min(reasoning, output) : reasoning,
                           cacheWrite1h: piFormat ? min(cacheWrite1h, cacheWrite) : 0)
    }

    @inline(__always)
    private func keyIs(_ line: UnsafeRawBufferPointer, _ base: UnsafeRawPointer, _ keyStart: Int,
                       _ keyLen: Int, _ needle: StaticString) -> Bool {
        guard keyLen == needle.utf8CodeUnitCount else { return false }
        return needle.withUTF8Buffer { n in
            memcmp(base + keyStart, n.baseAddress!, n.count) == 0
        }
    }

    // MARK: strings

    /// Value of `key":"…"` up to the closing quote, with JSON escapes decoded.
    private func stringValue(_ line: UnsafeRawBufferPointer, key: StaticString) -> String? {
        let at = line.indexOf(key)
        if at < 0 { return nil }
        let start = at + key.utf8CodeUnitCount
        var i = start
        var escaped = false
        while i < line.count, line[i] != 0x22 {
            if line[i] == 0x5C { escaped = true; i += 1 }
            i += 1
        }
        let end = min(i, line.count)
        guard end > start else { return nil }
        let raw = line[start..<end]
        if !escaped { return String(decoding: raw, as: UTF8.self) }
        var quoted: [UInt8] = [0x22]
        quoted += raw
        quoted.append(0x22)
        return (try? JSONSerialization.jsonObject(with: Data(quoted), options: .fragmentsAllowed)) as? String
    }

    // MARK: timestamp

    /// Line timestamp: the ISO string when present, else a numeric epoch
    /// (`"timestamp":1793022556729`, milliseconds above 1e11).
    private func timestampOf(_ line: UnsafeRawBufferPointer) -> Double {
        let isoAt = line.indexOf(StaticString("\"timestamp\":\""))
        if isoAt >= 0 {
            var i = isoAt + 13
            var bytes: [UInt8] = []
            while i < line.count, line[i] != 0x22 {
                bytes.append(line[i])
                i += 1
            }
            if let parsed = ISOTime.parse(String(decoding: bytes, as: UTF8.self)) { return parsed }
        }
        let numAt = line.indexOf(StaticString("\"timestamp\":"))
        if numAt < 0 { return 0 }
        var i = numAt + 12
        var value: Double = 0
        while i < line.count, line[i] >= 48, line[i] <= 57 {
            value = value * 10 + Double(line[i] - 48)
            i += 1
        }
        // Unix seconds only reach 1e11 in year 5138, so a larger value is milliseconds.
        return value > 1e11 ? value / 1000 : value
    }
}
