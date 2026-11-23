import CoreServices
import Foundation
import LocalCore

/// Coalesced FSEvents watcher. The kernel batches bursts for `latency` seconds;
/// the callback runs on a utility queue and only wakes the app when something
/// actually changed under one of the paths.
///
/// A path that does not exist yet is not forgotten: the nearest existing folder above it is
/// watched for entries appearing or going (the folder only, not its subtree, so a busy parent
/// such as the home folder costs nothing). When one fires, the paths are checked again, the
/// stream moves to what exists now, and the callback runs: a tool installed while the app is
/// running is detected without a restart.
public final class FileWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tokenbar.fsevents", qos: .utility)
    private let wanted: [String]
    private let latency: TimeInterval
    private let callback: @Sendable () -> Void
    // Everything below only on `queue`.
    private var stream: FSEventStreamRef?
    private var streamRoots: [String] = []
    private var doors: [String: DispatchSourceFileSystemObject] = [:]

    public init(paths: [String], latency: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
        wanted = paths
        self.latency = latency
        callback = onChange
        queue.sync { rebuild() }
    }

    deinit {
        stopStream()
        for source in doors.values { source.cancel() }
    }

    private func rebuild() {
        // Looked at again once the doors are open: a folder made in between would otherwise be
        // missed, with nothing left to announce it.
        for _ in 0..<4 {
            let roots = WatchPlan.existing(wanted)
            let parents = WatchPlan.waitingOn(wanted)
            if roots != streamRoots {
                stopStream()
                streamRoots = roots
                startStream(roots)
            }
            for (path, source) in doors where !parents.contains(path) {
                source.cancel()
                doors[path] = nil
            }
            for path in parents where doors[path] == nil { openDoor(path) }
            if WatchPlan.existing(wanted) == roots, WatchPlan.waitingOn(wanted) == parents { break }
        }
    }

    private func openDoor(_ path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete, .link], queue: queue)
        source.setEventHandler { [weak self] in self?.somethingAppeared() }
        source.setCancelHandler { close(descriptor) }
        doors[path] = source
        source.resume()
    }

    private func somethingAppeared() {
        // A renamed or deleted folder leaves its descriptor pointing nowhere: open them all again.
        for source in doors.values { source.cancel() }
        doors = [:]
        rebuild()
        callback()
    }

    private func startStream(_ roots: [String]) {
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().callback()
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
