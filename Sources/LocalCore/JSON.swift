import Foundation

/// Small accessors over `JSONSerialization` output.
enum J {
    static func object(_ bytes: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = bytes.baseAddress, bytes.count > 1 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    /// An integer field, held to `-fieldLimit...fieldLimit`: a count of `1e20` or `Int64.max` must not overflow the
    /// sums and differences the readers make of up to four of them. Not a number is 0.
    static func int(_ v: Any?) -> Int64 {
        guard let n = v as? NSNumber else { return 0 }
        let d = n.doubleValue
        let limit = TokenCounts.fieldLimit
        if d.isNaN { return 0 }
        if d >= Double(limit) { return limit }
        if d <= -Double(limit) { return -limit }
        return n.int64Value
    }

    static func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

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
