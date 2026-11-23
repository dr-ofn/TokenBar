import Foundation

/// Codex compresses finished rollout logs to `.jsonl.zst` and deletes the plain
/// file. Decompression shells out to the `zstd` CLI; archives are immutable once
/// written, so they are always read whole rather than incrementally.
enum Zstd {
    enum Failure: LocalizedError, CustomStringConvertible {
        case binaryMissing
        case spawnFailed(path: String, code: Int32)
        case decompressFailed(path: String, status: Int32)
        /// One line, or the whole output, is larger than any log of a tool is: not read (a small archive can unpack to gigabytes).
        case tooLarge(path: String, what: String)

        /// The sentence without the file's path: for a caller whose file is a temporary copy that means nothing to the reader.
        var summary: String {
            switch self {
            case .binaryMissing:
                return L10n.t("zstd yok: brew install zstd (.jsonl.zst arşivleri okunamıyor)", "zstd is missing: brew install zstd (.jsonl.zst archives cannot be read)")
            case let .spawnFailed(_, code):
                return L10n.t("zstd başlatılamadı (hata \(code))", "zstd could not be started (error \(code))")
            case let .decompressFailed(_, status):
                return L10n.t("zstd başarısız oldu (durum \(status))", "zstd failed (status \(status))")
            case let .tooLarge(_, what):
                return L10n.t("açılmış içerik çok büyük (\(what)), okunmadı", "the unpacked content is too large (\(what)), not read")
            }
        }

        var errorDescription: String? {
            switch self {
            case .binaryMissing, .tooLarge:
                return summary
            case let .spawnFailed(path, _), let .decompressFailed(path, _):
                return summary + L10n.t(": \(path) okunurken", " while reading \(path)")
            }
        }

        /// What `String(describing:)` and `"\(error)"` print: the sentence, never the case and its labels.
        var description: String { errorDescription ?? summary }
    }

    /// macOS has no zstd in libcompression (LZ4, ZLIB, LZMA, Brotli, LZFSE only), so the `zstd` CLI
    /// is the way in. Homebrew (both prefixes), MacPorts and the system come first, since an app
    /// started from Finder has a bare `$PATH`; then `$PATH`. `TOKENBAR_ZSTD` names the binary, or
    /// `none` (or empty) says there is none.
    static var binary: String? { resolver.binary }

    static var isAvailable: Bool { binary != nil }

    private final class Resolver: @unchecked Sendable {
        private let lock = NSLock()
        private var found: String?

        /// A binary that was found is kept; a miss is looked up again each time, so installing
        /// zstd while the app runs is enough.
        var binary: String? {
            lock.lock()
            defer { lock.unlock() }
            if let found, FileManager.default.isExecutableFile(atPath: found) { return found }
            found = Self.search()
            return found
        }

        private static func search() -> String? {
            let environment = ProcessInfo.processInfo.environment
            if let forced = environment["TOKENBAR_ZSTD"] {
                return forced.isEmpty || forced == "none" || !FileManager.default.isExecutableFile(atPath: forced) ? nil : forced
            }
            var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
            directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            for directory in directories {
                let candidate = "\(directory)/zstd"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }
    }

    private static let resolver = Resolver()

    /// The longest line (Codex writes whole tool outputs into one) and the most output one archive may unpack to.
    static let maxLineBytes = 64 << 20
    static let maxOutputBytes: UInt64 = 4 << 30

    /// Streams the decompressed file as newline-delimited lines (CRLF tolerated,
    /// newline excluded). `body` receives the raw bytes, matching `LineReader`.
    /// Returning `false` from `body` stops the read early; that is success.
    /// Returns the decompressed byte count.
    ///
    /// Uses `posix_spawn`/`waitpid` instead of `Process.waitUntilExit`: the
    /// Foundation wait drives per-thread run loops and deadlocks once many scan
    /// workers spawn zstd concurrently.
    @discardableResult
    static func forEachLine(path: String, maxLine: Int = maxLineBytes, maxOutput: UInt64 = maxOutputBytes,
                            _ body: (UnsafeRawBufferPointer) -> Bool) throws -> UInt64 {
        guard let binary else { throw Failure.binaryMissing }

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw Failure.spawnFailed(path: path, code: errno) }
        let readFD = fds[0], writeFD = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        defer { posix_spawn_file_actions_destroy(&actions) }

        let args: [String] = [binary, "-dc", "--", path]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { (arg: String) -> UnsafeMutablePointer<CChar>? in strdup(arg) }
        argv.append(nil)
        defer { for case let arg? in argv { free(arg) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, binary, &actions, nil, &argv, environ)
        close(writeFD)
        guard spawnResult == 0 else {
            close(readFD)
            throw Failure.spawnFailed(path: path, code: spawnResult)
        }

        var decompressed: UInt64 = 0
        var pending = [UInt8]()
        var searchFrom = 0
        var stopped = false
        var readFailed = false
        var oversize: String?
        var chunk = [UInt8](repeating: 0, count: 1 << 16)

        readLoop: while !stopped {
            let n = chunk.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                readFailed = true
                break
            }
            if n == 0 { break }
            decompressed += UInt64(n)
            pending.append(contentsOf: chunk[0..<n])

            var lineStart = 0
            while searchFrom < pending.count {
                let nlIndex = pending.withUnsafeBufferPointer { buf -> Int? in
                    guard let base = buf.baseAddress,
                          let hit = memchr(base + searchFrom, 0x0A, buf.count - searchFrom) else { return nil }
                    return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                }
                guard let nl = nlIndex else { searchFrom = pending.count; break }
                if !emit(pending[lineStart..<nl], into: body) { stopped = true; break }
                lineStart = nl + 1
                searchFrom = lineStart
            }
            if lineStart > 0 {
                pending.removeFirst(lineStart)
                searchFrom = max(0, searchFrom - lineStart)
            }
            if !stopped, pending.count > maxLine { oversize = L10n.t("tek satır \(maxLine >> 20) MiB'ı aşıyor", "a single line is over \(maxLine >> 20) MiB"); break }
            if decompressed > maxOutput { oversize = L10n.t("çıktı \(maxOutput >> 20) MiB'ı aşıyor", "the output is over \(maxOutput >> 20) MiB"); break }
        }

        close(readFD)
        // A read that gave up has a zstd that is still writing: it ends on the closed pipe, and is ended here at once.
        if oversize != nil { kill(pid, SIGKILL) }
        let status = reap(pid)
        if let oversize { throw Failure.tooLarge(path: path, what: oversize) }
        if readFailed { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path]) }
        // When the caller stopped early we closed the pipe, so zstd dies of
        // SIGPIPE with a nonzero status; that stop is success, not an error.
        if !stopped {
            let exited = (status & 0x7F) == 0
            let exitCode = (status >> 8) & 0xFF
            guard exited, exitCode == 0 else {
                throw Failure.decompressFailed(path: path, status: exited ? exitCode : status)
            }
        }
        // Archives are complete files: an unterminated tail is a real (non-blank) line.
        if !stopped, !pending.isEmpty, pending.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) {
            _ = emit(pending[...], into: body)
        }
        return decompressed
    }

    private static func emit(_ slice: ArraySlice<UInt8>, into body: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        var line = slice
        if line.last == 0x0D { line = line.dropLast() }
        guard !line.isEmpty else { return true }
        return line.withUnsafeBufferPointer { body(UnsafeRawBufferPointer($0)) }
    }

    private static func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        return waited == -1 ? -1 : status
    }
}
