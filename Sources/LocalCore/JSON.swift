import Foundation

/// Small accessors over `JSONSerialization` output.
enum J {
    static func object(_ bytes: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = bytes.baseAddress, bytes.count > 1 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        return parse(data) as? [String: Any]
    }

    /// `JSONSerialization` for a log: a line that holds invalid UTF-8 (a byte a tool cut in the middle of a character, a
    /// log copied through a wrong code page) or a lone surrogate escape (`"\udc80"`, which a tool that wrote UTF-16 text
    /// leaves) is not dropped, it is read with the bad part as U+FFFD, as the Windows reader reads it. Input that parses
    /// as it is goes the same way as before (so every valid and every ASCII line is untouched); only a failed parse gets
    /// a second try, and only when there is something to repair.
    static func parse(_ data: Data, options: JSONSerialization.ReadingOptions = []) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: data, options: options) { return value }
        guard let fixed = repaired(data) else { return nil }
        return try? JSONSerialization.jsonObject(with: fixed, options: options)
    }

    /// The same bytes with invalid UTF-8 and lone `\uD800`..`\uDFFF` escapes replaced by U+FFFD; nil when there was none.
    static func repaired(_ data: Data) -> Data? {
        var bytes = Array(data)
        var changed = false
        // Decoding replaces every invalid sequence by U+FFFD: the result differs from the input exactly when it was invalid.
        let decoded = Array(String(decoding: bytes, as: UTF8.self).utf8)
        if decoded != bytes {
            bytes = decoded
            changed = true
        }
        let replacement: [UInt8] = Array("\\ufffd".utf8)
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for k in 0..<4 {
                let c = bytes[at + k]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c) - 0x30
                case 0x41...0x46: d = UInt32(c) - 0x41 + 10
                case 0x61...0x66: d = UInt32(c) - 0x61 + 10
                default: return nil
                }
                v = v << 4 | d
            }
            return v
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            guard c == 0x5C, i + 1 < bytes.count else { out.append(c); i += 1; continue }
            if bytes[i + 1] == 0x75, let code = hex4(i + 2), (0xD800...0xDFFF).contains(code) {
                if code <= 0xDBFF, i + 11 < bytes.count, bytes[i + 6] == 0x5C, bytes[i + 7] == 0x75,
                   let low = hex4(i + 8), (0xDC00...0xDFFF).contains(low) {
                    out.append(contentsOf: bytes[i..<(i + 12)])     // a pair of escapes is one character: kept
                    i += 12
                } else {
                    out.append(contentsOf: replacement)
                    changed = true
                    i += 6
                }
            } else {
                out.append(c)
                out.append(bytes[i + 1])                              // the escaped character (an escaped backslash too)
                i += 2
            }
        }
        return changed ? Data(out) : nil
    }

    /// A JSON number that is not a boolean (an `NSNumber` is both): `true` and `false` are no number in a log, as they are
    /// none for the Windows build (`util.whole`) and for the price catalogues.
    static func number(_ v: Any?) -> NSNumber? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    /// An integer field, held to `-fieldLimit...fieldLimit`: a count of `1e20` or `Int64.max` must not overflow the
    /// sums and differences the readers make of up to four of them. Not a number (a boolean is none) is 0.
    ///
    /// `booleans: true` is the rule of the readers that the Windows build reads with `util.count` (Gemini, Qwen chats,
    /// Copilot CLI, Junie, Vibe, Augment, Codebuff): there a JSON `true` is 1 and `false` 0. The other readers are
    /// `util.num`/`util.whole` there, and a boolean is no number.
    static func int(_ v: Any?, booleans: Bool = false) -> Int64 {
        if booleans, let b = v as? NSNumber, CFGetTypeID(b) == CFBooleanGetTypeID() { return b.boolValue ? 1 : 0 }
        guard let n = number(v) else { return 0 }
        let d = n.doubleValue
        let limit = TokenCounts.fieldLimit
        if d.isNaN { return 0 }
        if d >= Double(limit) { return limit }
        if d <= -Double(limit) { return -limit }
        return n.int64Value
    }

    static func double(_ v: Any?) -> Double? { number(v)?.doubleValue }

    static func str(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }

    /// Unix seconds from a number (seconds or milliseconds) or an ISO-8601 string.
    static func time(_ v: Any?) -> Double {
        if let n = double(v) { return n > 1e11 ? n / 1000 : n }
        return str(v).flatMap(ISOTime.parse) ?? 0
    }
}
