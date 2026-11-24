import Foundation

/// Python's `os.path.realpath(path)` (strict=False) on POSIX, step for step (CPython 3.12 `posixpath._joinrealpath`), so
/// the Mac CLI and the Windows tool give one home the same real path, and with it the same index folder.
///
/// Each name of the path is looked at in turn with `lstat`: a symbolic link (a broken one too) is replaced by its target,
/// which is walked the same way from the folder the link sits in; `..` takes the last name off the path as walked so far
/// (a resolved path, never the written one); a name that is not there is kept as written. A link met a second time on its
/// own way (a loop) stops the walk and the rest of the path is kept unchanged. The result is made absolute and tidied
/// (`abspath`).
///
/// A link that `lstat` shows and `readlink` then cannot read (permission, or the link went in between) is an error, as it
/// is in Python (`OSError`): the path is not guessed from the folder above it.
public enum RealPath {
    private enum Seen { case unresolved, resolved(String) }

    public struct Failure: Error, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String { "\(path): \(String(cString: strerror(code)))" }
    }

    public static func resolve(_ path: String, readLink: (String) throws -> String = RealPath.systemReadLink) throws -> String {
        var seen: [String: Seen] = [:]
        let (resolved, _) = try joinReal("", path, &seen, readLink)
        return abspath(resolved)
    }

    private static func joinReal(_ start: String, _ text: String, _ seen: inout [String: Seen],
                                 _ readLink: (String) throws -> String) throws -> (String, Bool) {
        var path = start
        var rest = Substring(text)
        if rest.hasPrefix("/") {
            rest = rest.dropFirst()
            path = "/"
        }
        while !rest.isEmpty {
            let name: Substring
            if let slash = rest.firstIndex(of: "/") {
                name = rest[..<slash]
                rest = rest[rest.index(after: slash)...]
            } else {
                name = rest
                rest = ""
            }
            if name.isEmpty || name == "." { continue }
            if name == ".." {
                if !path.isEmpty {
                    let (head, tail) = split(path)
                    path = head
                    if tail == ".." { path = join(join(path, ".."), "..") }
                } else {
                    path = ".."
                }
                continue
            }
            let newPath = join(path, String(name))
            var info = Darwin.stat()
            let isLink = lstat(newPath, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
            if !isLink {
                path = newPath
                continue
            }
            if let known = seen[newPath] {
                if case .resolved(let value) = known {
                    path = value
                    continue
                }
                // A link that is still being resolved: a loop. What is resolved so far plus the rest, unchanged.
                return (join(newPath, String(rest)), false)
            }
            seen[newPath] = .unresolved
            let (target, ok) = try joinReal(path, try readLink(newPath), &seen, readLink)
            path = target
            if !ok { return (join(path, String(rest)), false) }
            seen[newPath] = .resolved(path)
        }
        return (path, true)
    }

    public static func systemReadLink(_ path: String) throws -> String {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n >= 0 else { throw Failure(path: path, code: errno) }
        return String(decoding: buffer[0..<n], as: UTF8.self)
    }

    /// `posixpath.split`
    private static func split(_ p: String) -> (String, String) {
        guard let slash = p.lastIndex(of: "/") else { return ("", p) }
        var head = String(p[...slash])
        let tail = String(p[p.index(after: slash)...])
        if !head.isEmpty, head.contains(where: { $0 != "/" }) {
            while head.hasSuffix("/") { head.removeLast() }
        }
        return (head, tail)
    }

    /// `posixpath.join` for two parts.
    private static func join(_ a: String, _ b: String) -> String {
        if b.hasPrefix("/") { return b }
        if a.isEmpty { return b }
        return a.hasSuffix("/") ? a + b : a + "/" + b
    }

    /// `posixpath.abspath`: made absolute against the working folder, then `normpath`.
    private static func abspath(_ p: String) -> String {
        normpath(p.hasPrefix("/") ? p : join(FileManager.default.currentDirectoryPath, p))
    }

    /// `posixpath.normpath`: `.` and empty parts dropped, `..` applied to the text; two leading slashes (and only two) are kept.
    private static func normpath(_ p: String) -> String {
        if p.isEmpty { return "." }
        var initial = p.hasPrefix("/") ? 1 : 0
        if initial == 1, p.hasPrefix("//"), !p.hasPrefix("///") { initial = 2 }
        var parts: [Substring] = []
        for comp in p.split(separator: "/", omittingEmptySubsequences: false) {
            if comp.isEmpty || comp == "." { continue }
            if comp != ".." || (initial == 0 && parts.isEmpty) || parts.last == ".." {
                parts.append(comp)
            } else if !parts.isEmpty {
                parts.removeLast()
            }
        }
        let joined = String(repeating: "/", count: initial) + parts.joined(separator: "/")
        return joined.isEmpty ? "." : joined
    }
}
