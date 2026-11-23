import Foundation

/// What one anonymous GET of a price catalogue answered.
public enum PriceFetchResponse: Sendable {
    case ok(Data, etag: String?)
    case notModified
}

public enum PriceFeedError: Error, Sendable {
    case status(Int)
    case notFound(String)
}

/// Where catalogue text comes from. The app uses `URLSessionPriceFetcher`; tests and tools feed from files.
public protocol PriceFetching: Sendable {
    func fetch(_ source: PriceSource, etag: String?) async throws -> PriceFetchResponse
}

/// A plain GET with no cookies, no credentials and nothing about the user: only `If-None-Match` and a product name.
public struct URLSessionPriceFetcher: PriceFetching {
    public init() {}

    public func fetch(_ source: PriceSource, etag: String?) async throws -> PriceFetchResponse {
        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PriceFeedError.status(0) }
        switch http.statusCode {
        case 200: return .ok(data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304: return .notModified
        default: throw PriceFeedError.status(http.statusCode)
        }
    }
}

/// Feeds the catalogues from `openrouter.json`, `litellm.json` and `modelsdev.json` in a directory: no network.
public struct FilePriceFetcher: PriceFetching {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func fetch(_ source: PriceSource, etag: String?) async throws -> PriceFetchResponse {
        let name = source == .modelsdev ? "modelsdev.json" : "\(source.rawValue).json"
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { throw PriceFeedError.notFound(name) }
        return .ok(data, etag: nil)
    }
}

/// Lets one refresh pass run at a time in this process; the others wait their turn.
actor RefreshGate {
    static let shared = RefreshGate()
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !running { running = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// The turn passes straight to the first waiter, so `running` stays true.
    func leave() {
        if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() }
    }
}

/// How one refresh pass went, per source.
public struct PriceRefreshReport: Sendable {
    public var updated: [PriceSource] = []
    public var notModified: [PriceSource] = []
    public var fresh: [PriceSource] = []
    public var failed: [PriceSource: String] = [:]
    public var skipped: [PriceSource] = []

    /// The cache files changed (new rows or a new timestamp).
    public var changed: Bool { !updated.isEmpty || !notModified.isEmpty }
}

/// The price catalogues on disk and, once a day at most, on the network.
///
/// Order of trust for each source: the cache file (any age), then the embedded snapshot (LiteLLM and models.dev only).
/// The network is asked only when the cache is older than `ttl`, with `If-None-Match`; an answer that is not that
/// catalogue's JSON never replaces the cache. After a failed attempt the next one waits `retryAfterFailure`.
/// Nothing user-specific leaves the machine; `TOKENBAR_OFFLINE=1` switches the network off for good.
public final class PriceFeed: @unchecked Sendable {
    public struct Config: Sendable {
        public var cacheDirectory: URL
        public var ttl: TimeInterval = 24 * 3600
        public var retryAfterFailure: TimeInterval = 3600
        public var offline: Bool
        /// Asked before every source of a pass: true ends the pass there (the user went offline while it ran).
        public var shouldStop: @Sendable () -> Bool = { false }
        public var fetcher: PriceFetching
        public var now: @Sendable () -> Date = { Date() }

        public init(cacheDirectory: URL = PriceFeed.defaultCacheDirectory, offline: Bool = PriceFeed.environmentOffline,
                    fetcher: PriceFetching = URLSessionPriceFetcher()) {
            self.cacheDirectory = cacheDirectory
            self.offline = offline
            self.fetcher = fetcher
        }
    }

    static let schema = 1
    public let config: Config

    public init(_ config: Config = Config()) { self.config = config }

    /// ~/Library/Caches/TokenBar
    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return base.appendingPathComponent("TokenBar", isDirectory: true)
    }

    /// `TOKENBAR_OFFLINE=1` (or true/yes): no network call at all.
    public static var environmentOffline: Bool {
        guard let v = ProcessInfo.processInfo.environment["TOKENBAR_OFFLINE"]?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(v)
    }

    // MARK: Disk

    struct CacheFile {
        var etag: String?
        var fetched: Date
        var rows: [String: CatalogRow]
    }

    func cacheURL(_ source: PriceSource) -> URL { config.cacheDirectory.appendingPathComponent(source.cacheFileName) }
    var stateURL: URL { config.cacheDirectory.appendingPathComponent("prices-state.json") }

    /// A cache file that is not ours, not this schema or has no priced row is as good as none.
    func readCache(_ source: PriceSource) -> CacheFile? {
        guard let data = try? Data(contentsOf: cacheURL(source)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["schema"] as? Int) == PriceFeed.schema, (root["source"] as? String) == source.rawValue,
              let fetched = root["fetched"] as? Double,
              let rows = PriceParsers.compactRows(root["rows"]) else { return nil }
        return CacheFile(etag: root["etag"] as? String, fetched: Date(timeIntervalSince1970: fetched), rows: rows)
    }

    /// The rows the index would pick: all a lookup can ever return, so the cache stays small and loads fast.
    func writeCache(_ source: PriceSource, rows: [String: CatalogRow], etag: String?, fetched: Date) {
        let kept = Catalog(source: source, rows: rows).byKey.values
        var compact: [String: [Any]] = [:]
        for hit in kept { compact[hit.id] = hit.row.compact }
        var root: [String: Any] = ["schema": PriceFeed.schema, "source": source.rawValue, "url": source.url.absoluteString,
                                   "fetched": fetched.timeIntervalSince1970, "rows": compact]
        if let etag { root["etag"] = etag }
        writeJSON(root, to: cacheURL(source))
    }

    private func writeJSON(_ object: [String: Any], to url: URL) {
        // `data(withJSONObject:)` raises an Objective-C exception, which nothing catches, on NaN and Infinity.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: config.cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func failures() -> [String: Double] {
        guard let data = try? Data(contentsOf: stateURL), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return (root["failed"] as? [String: Double]) ?? [:]
    }

    private func saveFailures(_ failed: [String: Double]) { writeJSON(["failed": failed], to: stateURL) }

    // MARK: Reading

    /// What is on disk or embedded right now. No network, and cheap enough for the first price lookup.
    public func loadLocal() -> PriceCatalogs {
        var out = PriceCatalogs()
        let embedded = PriceCatalogs.embedded
        for source in PriceSource.allCases {
            if let cache = readCache(source) {
                out.set(source, rows: cache.rows, origin: .cache(cache.fetched))
            } else if let catalog = embedded.catalogs[source], let origin = embedded.origins[source] {
                out.catalogs[source] = catalog
                out.origins[source] = origin
            }
        }
        return out
    }

    // MARK: Refreshing

    /// One pass over the three sources: network only for those whose cache is older than `ttl`. Passes run one after
    /// the other: two at once (the one-day refresh at launch and "Update prices") would ask the same catalogues twice and
    /// write `prices-state.json` over each other.
    public func refresh() async -> PriceRefreshReport {
        await RefreshGate.shared.enter()
        let report = await pass()
        await RefreshGate.shared.leave()
        return report
    }

    private func pass() async -> PriceRefreshReport {
        var report = PriceRefreshReport()
        if config.offline || config.shouldStop() {
            report.skipped = PriceSource.allCases
            return report
        }
        var failed = failures()
        let startFailed = failed
        for source in PriceSource.allCases {
            if config.offline || config.shouldStop() {
                report.skipped.append(source)
                continue
            }
            let now = config.now()
            let cache = readCache(source)
            // A copy stamped in the future (the clock was set back) is not fresh: its age would be negative.
            if let cache, case let age = now.timeIntervalSince(cache.fetched), age >= 0, age < config.ttl {
                report.fresh.append(source)
                continue
            }
            if let last = failed[source.rawValue], now.timeIntervalSince1970 - last < config.retryAfterFailure, now.timeIntervalSince1970 >= last {
                report.skipped.append(source)
                continue
            }
            do {
                switch try await config.fetcher.fetch(source, etag: cache?.etag) {
                case .notModified:
                    guard let cache else { throw PriceFeedError.status(304) }
                    writeCache(source, rows: cache.rows, etag: cache.etag, fetched: now)
                    report.notModified.append(source)
                case .ok(let data, let etag):
                    guard let rows = PriceParsers.rows(source, data) else {
                        report.failed[source] = "answer is not the \(source.displayName) catalogue"
                        failed[source.rawValue] = now.timeIntervalSince1970
                        continue
                    }
                    writeCache(source, rows: rows, etag: etag, fetched: now)
                    report.updated.append(source)
                }
                failed[source.rawValue] = nil
            } catch {
                report.failed[source] = String(describing: error)
                failed[source.rawValue] = now.timeIntervalSince1970
            }
        }
        if failed != startFailed { saveFailures(failed) }
        return report
    }

    /// `refresh()` for code that is not async (tests, tools). Never call it from the main thread of the app.
    public func refreshBlocking() -> PriceRefreshReport {
        final class Box: @unchecked Sendable { var report = PriceRefreshReport() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.report = await self.refresh()
            done.signal()
        }
        done.wait()
        return box.report
    }
}
