import Foundation

/// The order in which the keys of a JSON object are written in the text. `JSONSerialization` hands back a dictionary,
/// which forgets it, and this is needed where two keys can mean the same thing and the later one has to win (the
/// alias file: the Windows app reads the same file into an ordered dictionary).
enum JSONKeyOrder {
    /// The keys of the root object, or of the object under `member` of the root when that is an object; each key once, at
    /// the place it first appears. Empty when the text is not an object (the caller then has no order to follow).
    static func keys(of data: Data, member: String? = nil) -> [String] {
        let bytes = utf8(data)
        var scanner = Scanner903(bytes: bytes, index: bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        guard let root = scanner.members(), scanner.tail() else { return [] }
        if let member, let last = root.last(where: { $0.key == member }), bytes[last.value.lowerBound] == UInt8(ascii: "{") {
            var inner = Scanner903(bytes: bytes, index: last.value.lowerBound)
            return unique((inner.members() ?? []).map(\.key))
        }
        return unique(root.map(\.key))
    }

    /// The text as UTF-8, the only encoding the scanner reads. `JSONSerialization` also reads UTF-16 (a file saved by
    /// PowerShell's ">" is UTF-16 LE with a BOM), found by its BOM or by where the zero bytes are; such a file is
    /// re-encoded first, or its order would be lost and the names would fall back to sorted order.
    private static func utf8(_ data: Data) -> [UInt8] {
        let raw = [UInt8](data)
        guard raw.count >= 2 else { return raw }
        let encoding: String.Encoding?
        switch (raw[0], raw[1]) {
        case (0xFF, 0xFE): encoding = .utf16LittleEndian
        case (0xFE, 0xFF): encoding = .utf16BigEndian
        case let (a, b) where a != 0 && b == 0: encoding = .utf16LittleEndian
        case let (a, b) where a == 0 && b != 0: encoding = .utf16BigEndian
        default: encoding = nil
        }
        guard let encoding else { return raw }
        let hasBOM = (raw[0] == 0xFF && raw[1] == 0xFE) || (raw[0] == 0xFE && raw[1] == 0xFF)
        let body: Data = hasBOM ? data.dropFirst(2) : data
        guard let text = String(data: body, encoding: encoding) else { return raw }
        return [UInt8](text.utf8)
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private struct Scanner903 {
        let bytes: [UInt8]
        var index: Int

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        /// Only whitespace may follow the document.
        mutating func tail() -> Bool {
            skipSpace()
            return index == bytes.count
        }

        /// The members of the object at `index`, each with the range its value occupies; nil if it is not well formed.
        mutating func members() -> [(key: String, value: Range<Int>)]? {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
            index += 1
            var out: [(key: String, value: Range<Int>)] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return out }
            while true {
                skipSpace()
                guard let key = string() else { return nil }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                skipSpace()
                let start = index
                guard skipValue() else { return nil }
                out.append((key, start..<index))
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return out }
                return nil
            }
        }

        /// A string literal, decoded (escapes, \uXXXX pairs) by the JSON reader itself.
        mutating func string() -> String? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    let literal = Data(bytes[start..<index])
                    return (try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed)) as? String
                default: index += 1
                }
            }
            return nil
        }

        /// Steps over one value of any kind. Whether it is valid JSON is the reader's business, not this scan's.
        mutating func skipValue() -> Bool {
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case UInt8(ascii: "\""):
                return string() != nil
            case UInt8(ascii: "{"):
                return members() != nil
            case UInt8(ascii: "["):
                index += 1
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return true }
                while true {
                    skipSpace()
                    guard skipValue() else { return false }
                    skipSpace()
                    guard index < bytes.count else { return false }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return true }
                    return false
                }
            default:
                let start = index
                while index < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
                return index > start
            }
        }
    }
}
