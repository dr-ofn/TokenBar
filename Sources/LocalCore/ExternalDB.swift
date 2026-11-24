import Foundation
import SQLite3

/// Read-only handle on another tool's SQLite database.
///
/// TokenBar never writes into the folder of a tool it reads. A database in WAL mode is the catch: SQLite opens even a
/// read-only handle on it through a `-shm` file next to it, and makes that file when it is missing. So a WAL database
/// is read from a copy of its `.db` and `-wal` files in a private temporary folder (a copy sees the `-wal` that holds
/// the newest writes, and the original folder stays as the tool left it). The copy is deleted with the handle.
final class ExternalDB {
    private var handle: OpaquePointer?
    /// The temporary folder holding the copy of a WAL database; nil when the original is opened.
    private var scratch: String?

    /// A WAL database larger than this (with its `-wal`) is opened in place, `immutable`, instead of being copied.
    static let copyLimit: UInt64 = 4 << 30
    static let scratchPrefix = "tokenbar-extdb-"

    /// `immutable` skips locking entirely (for files whose writer holds them without WAL sharing);
    /// otherwise the database is opened read-only so a live writer is respected.
    init(path: String, immutable: Bool) throws {
        // Looked at before anything opens it: a pipe under the database's name, or under the name of a file SQLite opens
        // beside it (`-journal` when it checks for a hot journal, `-wal`, `-shm`), would block the open until something
        // writes to it. A pipe, socket or device is no database and no journal (the same rule as `LineReader`): the
        // database is named and left alone.
        // SQLite follows a link and opens the side files of the file it leads to: the real path is looked at as well as the
        // link's own folder.
        // The path is resolved once, before anything opens it: a database that is a link (opencode.db kept on another disk by
        // a dotfile manager, a relative link too) has its `-wal`, `-shm` and `-journal` beside the file it leads to, not
        // beside the link. Everything below (the WAL test, the copy, the stamps) works on that real path, and nothing is
        // written, moved or deleted in the tool's folders.
        let real = Self.resolvedPath(path)
        var spellings = [path]
        if real != path { spellings.append(real) }
        for spelling in spellings {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                var st = Darwin.stat()
                if stat(spelling + suffix, &st) == 0, [S_IFIFO, S_IFSOCK, S_IFCHR, S_IFBLK].contains(st.st_mode & S_IFMT) {
                    throw StoreError(message: L10n.t("\(spelling + suffix): düzenli dosya değil, veritabanı açılmadı", "\(spelling + suffix): not a regular file, the database was not opened"))
                }
            }
        }
        var openPath = real
        var query = immutable ? "immutable=1" : "mode=ro"
        if !immutable, Self.usesWAL(real) {
            if (Self.stamp(real + "-wal")?.size ?? 0) == 0 {
                // A WAL database with no `-wal` (or an empty one) holds everything in its main file: the tool's last
                // connection checkpointed and closed it. A read-only connection cannot open such a file through a `-shm`
                // it would have to make, and there is nothing newer to copy: read the file as it is.
                query = "immutable=1"
            } else if let copy = try Self.copyForReading(real) {
                scratch = copy.folder
                openPath = copy.database
            } else {
                // Too large to copy: read the main file in place. It sees no `-wal`, so the very last writes may be
                // missing, but no file is written next to the tool's database. (A copy that failed is an error, not
                // this: see `copyForReading`.)
                query = "immutable=1"
            }
        }
        let uri = "file:\(Self.uriPath(openPath))?\(query)"
        if sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            // A failed open still returns a handle; deinit closes it, so it must not close here too.
            throw StoreError(message: "\(path): \(msg)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        sqlite3_close(handle)
        if let scratch { try? FileManager.default.removeItem(atPath: scratch) }
    }

    /// True when the database is, or may be, in WAL mode. A `-wal` file next to it settles that on its own: the header
    /// alone is not enough, because a database whose first checkpoint has not happened yet is 0 bytes long (and SQLite
    /// deletes the `-wal` of a 0-byte file it opens in place) and a header that says "1, 1" is a writer's claim, not a
    /// promise that no `-shm` is made. Otherwise bytes 18 and 19 of the file header are the file format versions:
    /// 2 means WAL.
    static func usesWAL(_ path: String) -> Bool {
        if stamp(path + "-wal") != nil { return true }
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 20), head.count == 20, head.prefix(15) == Data("SQLite format 3".utf8) else { return false }
        return head[head.startIndex + 18] == 2 || head[head.startIndex + 19] == 2
    }

    /// The real path of a database: every link followed (a relative one too), the path itself when it cannot be resolved
    /// (a file that is not there). The `-wal`, `-shm` and `-journal` of a database are named from this path, never from
    /// the link's own folder.
    static func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private struct Stamp: Equatable { var size: Int64; var seconds: Int; var nanos: Int }

    private static func stamp(_ path: String) -> Stamp? {
        var st = Darwin.stat()
        guard stat(path, &st) == 0 else { return nil }
        return Stamp(size: Int64(st.st_size), seconds: st.st_mtimespec.tv_sec, nanos: st.st_mtimespec.tv_nsec)
    }

    /// Copies `<db>` and `<db>-wal` into a new private folder. The two files are copied one after the other, so a
    /// writer that checkpoints in between would give a pair that does not fit: the copy is repeated (three tries) until
    /// neither file changed while it ran. Nil when the pair is over `copyLimit`. A copy that fails throws: the newest
    /// rows live in the `-wal`, so reading the `.db` without it would count too little and call the file read. Only a
    /// `-wal` that has just gone (a checkpoint removed it) is no error (the Windows build's rule too).
    private static func copyForReading(_ path: String) throws -> (folder: String, database: String)? {
        sweepOldScratch()
        let fm = FileManager.default
        let folder = NSTemporaryDirectory() + scratchPrefix + UUID().uuidString
        let name = (path as NSString).lastPathComponent
        let database = folder + "/" + name
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var copied = false
            for _ in 0..<3 {
                let before = (stamp(path), stamp(path + "-wal"))
                guard let main = before.0, UInt64(max(0, main.size)) + UInt64(max(0, before.1?.size ?? 0)) <= copyLimit else { break }
                try? fm.removeItem(atPath: database)
                try? fm.removeItem(atPath: database + "-wal")
                try fm.copyItem(atPath: path, toPath: database)
                if before.1 != nil {
                    do { try fm.copyItem(atPath: path + "-wal", toPath: database + "-wal") } catch where isNoSuchFile(error) {}
                }
                // SQLite deletes the `-wal` of a database file that is 0 bytes long (there can be none) and reads nothing: a
                // main file that has not had its first checkpoint yet is given one empty page in the copy, so the `-wal`
                // beside it is read. The tool's own files are not touched.
                if main.size == 0, before.1 != nil, let pageSize = walPageSize(database + "-wal") {
                    guard truncate(database, off_t(pageSize)) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: database]) }
                }
                copied = true
                if (stamp(path), stamp(path + "-wal")) == before { return (folder, database) }
            }
            // A pair that kept changing while it was copied: the last copy is the best there is (SQLite checks the
            // `-wal` frames against the file and ignores the ones that do not fit).
            if copied { return (folder, database) }
        } catch {
            try? fm.removeItem(atPath: folder)
            throw StoreError(message: L10n.t("\(path): kopyalanamadı (\(error.localizedDescription)); dosya okunmuş sayılmadı, sonraki taramada yeniden denenir",
                                                  "\(path): could not be copied (\(error.localizedDescription)); the file is not counted as read and is tried again on the next scan"))
        }
        try? fm.removeItem(atPath: folder)
        return nil
    }

    /// The page size a `-wal` file says it was written with (bytes 8...11 of its header, after the magic number), or nil
    /// when the file is not a WAL or the number is not a page size SQLite accepts.
    private static func walPageSize(_ path: String) -> Int? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 12), head.count == 12 else { return nil }
        let bytes = [UInt8](head)
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        guard magic == 0x377f0682 || magic == 0x377f0683 else { return nil }
        let size = Int(UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11]))
        return size >= 512 && size <= 65536 && size & (size - 1) == 0 ? size : nil
    }

    /// True for "the file is not there": Cocoa's no-such-file codes, or ENOENT underneath.
    static func isNoSuchFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) { return true }
        return false
    }

    private static let sweepOnce: Void = {
        // Copies a crashed run left behind: a day old is nobody's.
        let fm = FileManager.default
        let base = NSTemporaryDirectory()
        for entry in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where entry.hasPrefix(scratchPrefix) {
            let path = base + entry
            if let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, Date().timeIntervalSince(modified) > 86_400 {
                try? fm.removeItem(atPath: path)
            }
        }
    }()

    private static func sweepOldScratch() { _ = sweepOnce }

    /// A path inside a `file:` URI: everything but letters, digits and `/-._~` is percent-encoded,
    /// so `?`, `#` and `%` in a directory name stay part of the name (SQLite decodes `%XX`).
    private static let uriSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-._~"))
    static func uriPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: uriSafe) ?? path
    }

    func query(_ sql: String, bind: [Int64] = [], _ row: (OpaquePointer) throws -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw StoreError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(st) }

        for (idx, value) in bind.enumerated() {
            sqlite3_bind_int64(st, Int32(idx + 1), value)
        }

        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW {
                try row(st)
                continue
            }
            if rc == SQLITE_DONE {
                return
            }
            throw StoreError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    static func text(_ st: OpaquePointer, _ column: Int32) -> String? {
        guard let p = sqlite3_column_text(st, column) else { return nil }
        return String(cString: p)
    }

    static func blob(_ st: OpaquePointer, _ column: Int32) -> Data {
        guard let p = sqlite3_column_blob(st, column) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, column)))
    }
}
