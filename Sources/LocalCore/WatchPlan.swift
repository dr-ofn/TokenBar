import Foundation

/// What a file watcher should listen to, for folders that may not exist yet: a tool installed
/// after the app started is picked up without a restart.
public enum WatchPlan {
    /// `path` with symlinks resolved as far as it exists (`/var` is `/private/var`), the rest
    /// appended as written. FSEvents reports resolved paths.
    public static func canonical(_ path: String) -> String {
        var existing = path
        var rest: [String] = []
        while existing.count > 1, !FileManager.default.fileExists(atPath: existing) {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var resolved = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        for part in rest { resolved += (resolved == "/" ? "" : "/") + part }
        return resolved
    }

    /// The paths that exist now, resolved, each once. Those inside another listed path are
    /// covered by it.
    public static func existing(_ paths: [String]) -> [String] {
        var found: [String] = []
        for path in paths.map(canonical) where FileManager.default.fileExists(atPath: path) && !found.contains(path) {
            found.append(path)
        }
        return found.filter { path in !found.contains { $0 != path && path.hasPrefix($0 + "/") } }
    }

    /// For each path that does not exist yet, the nearest folder above it that does: the one
    /// whose change may be the path appearing. The volume root is never one.
    public static func waitingOn(_ paths: [String]) -> [String] {
        var parents: [String] = []
        for path in paths.map(canonical) where !FileManager.default.fileExists(atPath: path) {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.count > 1, !FileManager.default.fileExists(atPath: folder) {
                folder = (folder as NSString).deletingLastPathComponent
            }
            if folder.count > 1, !parents.contains(folder) { parents.append(folder) }
        }
        return parents
    }
}
