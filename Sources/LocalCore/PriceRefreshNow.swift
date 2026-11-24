import Foundation

extension PriceBook {
    /// The menu's "Update prices": asks the network now, whatever the one-day wait says, and reloads the catalogues
    /// when something changed (`revision` counts up, `didChange` is posted). Nothing happens when offline or pinned:
    /// the report then says every source was skipped.
    @discardableResult
    public static func refreshNow() async -> PriceRefreshReport {
        var config = feedConfig(offline: isOffline)
        config.shouldStop = { PriceBook.isOffline }
        config.ttl = 0
        config.retryAfterFailure = 0
        let feed = PriceFeed(config)
        guard !isOffline, !isPinned else {
            var report = PriceRefreshReport()
            report.skipped = PriceSource.allCases
            return report
        }
        let report = await feed.refresh()
        if report.changed { reload(feed: feed) }
        noteWarnings(report)
        return report
    }
}
