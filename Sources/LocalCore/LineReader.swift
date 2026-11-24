import Foundation

/// Reads newline-terminated lines from a file starting at a byte offset.
///
/// Only complete lines are delivered, so a line still being written is picked up on
/// the next pass. `endOffset` always points just past the last consumed newline.
/// An unterminated final line is consumed only when `consumeTrailingLine` is set
/// (the caller knows the file is settled) and it is complete JSON.
///
/// A line longer than `maxLineBytes` (counted with its newline, as the Windows reader counts it) is never loaded: its
/// end is found by reading ahead in small steps, and it is skipped, the offset moving past it. An unterminated tail
/// that is already that long is left where it is (it may still be written); it is named, not read.
public enum LineReader {
    /// Same figure as the Windows reader's `util.MAX_LINE_BYTES`.
    public static let maxLineBytes = 256 << 20

    public struct Result {
        public var endOffset: UInt64
        public var bytesRead: UInt64
        /// Lines over the limit that were skipped (an unterminated tail that is already too long counts as one).
        public var skippedLines = 0
    }

    @discardableResult
    public static func forEachLine(path: String, from offset: UInt64, upTo limit: UInt64 = .max, chunkSize: Int = 256 << 10,
                                   maxLine: Int = maxLineBytes, consumeTrailingLine: Bool = false,
                                   _ body: (UnsafeRawBufferPointer) throws -> Bool) throws -> Result {
        // Opened without waiting: a pipe (or a device) under a log's name would otherwise block here until something
        // writes to it. A pipe, socket or device reads as nothing, the offset where it was; anything else (a folder
        // included, which then fails to read and is named) goes on as before.
        let special: (mode_t) -> Bool = { (mode: mode_t) -> Bool in [S_IFIFO, S_IFSOCK, S_IFCHR, S_IFBLK].contains(mode & S_IFMT) }
        var before = Darwin.stat()
        // Looked at first: a socket cannot even be opened (EOPNOTSUPP), and would be named as a missing file.
        if stat(path, &before) == 0, special(before.st_mode) { return Result(endOffset: offset, bytesRead: 0) }
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 {
            if errno == EACCES || errno == EPERM {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
            }
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        defer { close(fd) }
        var info = Darwin.stat()
        if fstat(fd, &info) == 0, special(info.st_mode) {
            return Result(endOffset: offset, bytesRead: 0)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var filled = 0
        var fileOffset = offset
        var consumedEnd = offset
        var totalRead: UInt64 = 0
        var stop = false
        var skipped = 0
        // From this size on, a line that still has no end is measured before it is held (see `measure`).
        let measureAt = min(64 << 20, max(chunkSize, maxLine / 4))
        var measuredLine: UInt64?

        while !stop {
            if filled == buffer.count {
                // One partial line fills the buffer. Once it is big, look for its end without keeping it: over the limit
                // it is skipped (or left, when it has no end yet), under it the buffer grows to hold it.
                if buffer.count >= measureAt, measuredLine != fileOffset || buffer.count >= maxLine {
                    measuredLine = fileOffset
                    let (length, terminated) = try measure(fd: fd, path: path, from: fileOffset, upTo: limit)
                    if length > UInt64(maxLine) {
                        skipped += 1
                        if !terminated { filled = 0; break }
                        fileOffset += length
                        consumedEnd = fileOffset
                        filled = 0
                        continue
                    }
                    if buffer.count >= maxLine { break }
                }
                let grown = min(buffer.count * 2, max(maxLine, chunkSize))
                let old = buffer
                let kept = filled
                buffer = [UInt8](unsafeUninitializedCapacity: grown) { target, count in
                    old.withUnsafeBytes { _ = memcpy(target.baseAddress!, $0.baseAddress!, kept) }
                    count = grown
                }
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
        return Result(endOffset: consumedEnd, bytesRead: totalRead, skippedLines: skipped)
    }

    /// How long the line that starts at `start` is, newline included, found by reading ahead in 1 MiB steps and keeping
    /// nothing. `terminated` is false when the file (or `limit`) ends first: the length is then what is there so far.
    private static func measure(fd: Int32, path: String, from start: UInt64, upTo limit: UInt64) throws -> (length: UInt64, terminated: Bool) {
        var step = [UInt8](repeating: 0, count: 1 << 20)
        var position = start
        while position < limit {
            let want = min(step.count, Int(clamping: limit - position))
            var n: Int
            repeat {
                n = step.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, want, off_t(position)) }
            } while n < 0 && errno == EINTR
            if n < 0 { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path]) }
            if n == 0 { break }
            let hit = step.withUnsafeBytes { memchr($0.baseAddress!, 0x0A, n) }
            if let hit {
                let index = step.withUnsafeBytes { $0.baseAddress!.distance(to: UnsafeRawPointer(hit)) }
                return (position - start + UInt64(index) + 1, true)
            }
            position += UInt64(n)
        }
        return (position - start, false)
    }

    /// True when the first `count` bytes are one complete JSON value (a half line is not, an object cut anywhere never is).
    private static func isWholeJSON(_ buffer: [UInt8], _ count: Int) -> Bool {
        buffer.withUnsafeBytes { raw in
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!), count: count, deallocator: .none)
            return (J.parse(data, options: [.fragmentsAllowed])) != nil
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
