import Foundation

/// Reads newline-terminated lines from a file starting at a byte offset.
///
/// Only complete lines are delivered, so a line still being written is picked up on
/// the next pass. `endOffset` always points just past the last consumed newline.
/// An unterminated final line is consumed only when `consumeTrailingLine` is set
/// (the caller knows the file is settled) and it is complete JSON.
public enum LineReader {
    public struct Result {
        public var endOffset: UInt64
        public var bytesRead: UInt64
    }

    @discardableResult
    public static func forEachLine(path: String, from offset: UInt64, upTo limit: UInt64 = .max, chunkSize: Int = 256 << 10,
                                   consumeTrailingLine: Bool = false,
                                   _ body: (UnsafeRawBufferPointer) throws -> Bool) throws -> Result {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var filled = 0
        var fileOffset = offset
        var consumedEnd = offset
        var totalRead: UInt64 = 0
        var stop = false

        while !stop {
            if filled == buffer.count {
                buffer.append(contentsOf: [UInt8](repeating: 0, count: buffer.count))
            }
            let n = readChunk(fd: fd, at: fileOffset + UInt64(filled), into: &buffer, from: filled, upTo: limit)
            if n < 0 { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path]) }
            if n == 0 { break }
            filled += n
            totalRead += UInt64(n)

            var lineStart = 0
            try buffer.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                while lineStart < filled {
                    guard let nl = memchr(base + lineStart, 0x0A, filled - lineStart) else { break }
                    let nlIndex = base.distance(to: UnsafeRawPointer(nl))
                    var lineEnd = nlIndex
                    if lineEnd > lineStart, base.load(fromByteOffset: lineEnd - 1, as: UInt8.self) == 0x0D {
                        lineEnd -= 1
                    }
                    if lineEnd > lineStart,
                       try !body(UnsafeRawBufferPointer(start: base + lineStart, count: lineEnd - lineStart)) {
                        stop = true
                    }
                    lineStart = nlIndex + 1
                    consumedEnd = fileOffset + UInt64(lineStart)
                    if stop { break }
                }
            }
            if lineStart > 0 {
                let remaining = filled - lineStart
                if remaining > 0 {
                    _ = buffer.withUnsafeMutableBytes { raw in
                        memmove(raw.baseAddress!, raw.baseAddress! + lineStart, remaining)
                    }
                }
                fileOffset += UInt64(lineStart)
                filled = remaining
            }
        }

        if !stop, consumeTrailingLine, filled > 0 {
            var lineEnd = filled
            if lineEnd > 0, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            // A quiet file's last line is delivered only when it is whole JSON: a line cut in half by a writer (a crash,
            // a suspended machine, a slow disk) must not be consumed, or the offset would move past it for good and the
            // rest of it, written later, would be read from its middle.
            let blank = !buffer[0..<lineEnd].contains { (byte: UInt8) -> Bool in byte != 0x20 && byte != 0x09 }
            if blank {
                consumedEnd = fileOffset + UInt64(filled)
            } else if lineEnd > 0, Self.isWholeJSON(buffer, lineEnd) {
                try buffer.withUnsafeBytes { raw in
                    _ = try body(UnsafeRawBufferPointer(start: raw.baseAddress!, count: lineEnd))
                }
                consumedEnd = fileOffset + UInt64(filled)
            }
        }
        return Result(endOffset: consumedEnd, bytesRead: totalRead)
    }

    /// True when the first `count` bytes are one complete JSON value (a half line is not, an object cut anywhere never is).
    private static func isWholeJSON(_ buffer: [UInt8], _ count: Int) -> Bool {
        buffer.withUnsafeBytes { raw in
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!), count: count, deallocator: .none)
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        }
    }

    /// One `pread`, retried while a signal interrupts it.
    private static func readChunk(fd: Int32, at position: UInt64, into buffer: inout [UInt8], from filled: Int, upTo limit: UInt64) -> Int {
        guard position < limit else { return 0 }
        let want = min(buffer.count - filled, Int(clamping: limit - position))
        var n: Int
        repeat {
            n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, want, off_t(position))
            }
        } while n < 0 && errno == EINTR
        return n
    }
}

extension UnsafeRawBufferPointer {
    /// Raw substring test — the hot pre-filter for candidate lines.
    @inline(__always)
    func contains(_ needle: StaticString) -> Bool {
        guard let base = baseAddress, count >= needle.utf8CodeUnitCount else { return false }
        return needle.withUTF8Buffer { n in
            memmem(base, count, n.baseAddress!, n.count) != nil
        }
    }

    /// Index of `needle`, or -1. Searching only the first `limit` bytes when given.
    @inline(__always)
    func indexOf(_ needle: StaticString, limit: Int = Int.max) -> Int {
        guard let base = baseAddress else { return -1 }
        let len = Swift.min(count, limit)
        guard len >= needle.utf8CodeUnitCount else { return -1 }
        return needle.withUTF8Buffer { n -> Int in
            guard let hit = memmem(base, len, n.baseAddress!, n.count) else { return -1 }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    /// Stable FNV-1a hash of the whole line; fallback dedup key.
    func fnv1a() -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        guard let base = baseAddress else { return h }
        for i in 0..<count {
            h = (h ^ UInt64(base.load(fromByteOffset: i, as: UInt8.self))) &* 0x100000001b3
        }
        return h
    }
}
