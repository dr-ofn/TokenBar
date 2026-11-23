import LocalCore

/// The tools a scan found whose token data does not live on this Mac (a tool that keeps its counts on a server),
/// so the picture can say so instead of showing nothing.
enum NotCountableBridge {
    static func tools(in result: ScanResult) -> [HarnessID] { result.notCountable }
}
