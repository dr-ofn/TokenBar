import Foundation

/// What one anonymous GET of a price catalogue answered.
public enum PriceFetchResponse: Sendable {
    case ok(Data, etag: String?)
    case notModified
}

public enum PriceFeedError: Error, Sendable {
    case status(Int)
    case notFound(String)
    /// The answer is over the limit; the download was cut off and the cached copy stays as it was.
    case tooLarge(Int)
}

/// Where catalogue text comes from. The app uses `URLSessionPriceFetcher`; tests and tools feed from files.
public protocol PriceFetching: Sendable {
    func fetch(_ source: PriceSource, etag: String?) async throws -> PriceFetchResponse
}

/// A plain GET with no cookies, no credentials and nothing about the user: only `If-None-Match` and a product name.
public struct URLSessionPriceFetcher: PriceFetching {
    /// The most one answer may carry (the Windows app's limit too); the real catalogues are a few MB.
    public static let defaultMaxResponseBytes = 128 * 1024 * 1024
    public var maxResponseBytes: Int

    public init(maxResponseBytes: Int = URLSessionPriceFetcher.defaultMaxResponseBytes) { self.maxResponseBytes = maxResponseBytes }

    public func fetch(_ source: PriceSource, etag: String?) async throws -> PriceFetchResponse {
        try await get(source.url, etag: etag)
    }

    /// The one request the app makes, for any address (the checks point it at a local server to see what goes out).
    public func get(_ url: URL, etag: String?) async throws -> PriceFetchResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")
        // URLSession adds the system's language list on its own; the catalogues have no use for it and it says where the user is.
        request.setValue("", forHTTPHeaderField: "Accept-Language")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 120
        let download = CappedDownload(limit: maxResponseBytes)
        let session = URLSession(configuration: config, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, http) = try await download.run(session.dataTask(with: request))
        switch http.statusCode {
        case 200: return .ok(data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304: return .notModified
        default: throw PriceFeedError.status(http.statusCode)
        }
    }
}

/// One download that is cut off as soon as it is over `limit` bytes (by its declared length, or by what has arrived).
final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var overLimit = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    init(limit: Int) { self.limit = limit }

    func run(_ task: URLSessionDataTask) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (next: CheckedContinuation<(Data, HTTPURLResponse), Error>) -> Void in
                lock.lock()
                continuation = next
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(limit) { overLimit = true }
        let stop = overLimit
        lock.unlock()
        completionHandler(stop ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        if buffer.count > limit { overLimit = true }
        let stop = overLimit
        if stop { buffer = Data() }
        lock.unlock()
        if stop { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let next = continuation
        continuation = nil
        let outcome: Result<(Data, HTTPURLResponse), Error>
        if overLimit {
            outcome = .failure(PriceFeedError.tooLarge(limit))
        } else if let error {
            outcome = .failure(error)
        } else if let response {
            outcome = .success((buffer, response))
        } else {
            outcome = .failure(PriceFeedError.status(0))
        }
        lock.unlock()
        next?.resume(with: outcome)
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
    /// Seconds until the soonest remembered failure (one a source had before this pass, which left it alone) is over,
    /// when the pass skipped a source for that. The app asks again then, not after the full wait.
    public var retryIn: TimeInterval?

    public init() {}

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

    /// 1 (9.0.0) kept no exact-id rows a lookup could still reach: such a file is read, never trusted for an ETag.
    static let schema = 2
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
        /// The row the index picks for each key.
        var rows: [String: CatalogRow]
        /// Rows only an exact id reaches (see `Catalog.split`); none in a cache file an older TokenBar wrote.
        var exact: [String: CatalogRow] = [:]
        /// A file under `PriceFeed.schema` is read but asked for again, in full.
        var schema = PriceFeed.schema
    }

    func cacheURL(_ source: PriceSource) -> URL { config.cacheDirectory.appendingPathComponent(source.cacheFileName) }
    var stateURL: URL { config.cacheDirectory.appendingPathComponent("prices-state.json") }

    /// A cache file that is not ours, not this schema or has no priced row is as good as none.
    func readCache(_ source: PriceSource) -> CacheFile? {
        guard let data = try? Data(contentsOf: cacheURL(source)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schema = root["schema"] as? Int, schema == 1 || schema == PriceFeed.schema, (root["source"] as? String) == source.rawValue,
              let fetched = root["fetched"] as? Double else { return nil }
        let rows = PriceParsers.compactRows(root["rows"]) ?? [:]
        let exact = PriceParsers.compactRows(root["exact"]) ?? [:]
        // A catalogue of routes alone has no winner, but its exact rows are a cache.
        guard !rows.isEmpty || !exact.isEmpty else { return nil }
        return CacheFile(etag: root["etag"] as? String, fetched: Date(timeIntervalSince1970: fetched), rows: rows, exact: exact, schema: schema)
    }

    /// What a lookup can return: the row the index picks for each key and the rows an exact id reaches with a price of
    /// their own (`Catalog.split`), so the cache stays small and loads fast and prices every name as the whole catalogue did.
    func writeCache(_ source: PriceSource, rows: [String: CatalogRow], etag: String?, fetched: Date) {
        let split = Catalog.split(source: source, rows: rows)
        writeCache(source, winners: split.winners, exact: split.exact, etag: etag, fetched: fetched)
    }

    func writeCache(_ source: PriceSource, winners: [String: CatalogRow], exact: [String: CatalogRow], etag: String?, fetched: Date) {
        var root: [String: Any] = ["schema": PriceFeed.schema, "source": source.rawValue, "url": source.url.absoluteString,
                                   "fetched": fetched.timeIntervalSince1970, "rows": winners.mapValues { (row: CatalogRow) -> [Any] in row.compact }]
        if !exact.isEmpty { root["exact"] = exact.mapValues { (row: CatalogRow) -> [Any] in row.compact } }
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
                out.set(source, rows: cache.rows, exact: cache.exact, origin: .cache(cache.fetched))
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
            // A schema 1 copy lacks the exact rows: it is read, but the next pass asks for the whole catalogue (no ETag).
            if let cache, cache.schema >= PriceFeed.schema, case let age = now.timeIntervalSince(cache.fetched), age >= 0, age < config.ttl {
                report.fresh.append(source)
                continue
            }
            if let last = failed[source.rawValue], now.timeIntervalSince1970 - last < config.retryAfterFailure, now.timeIntervalSince1970 >= last {
                report.skipped.append(source)
                let left = last + config.retryAfterFailure - now.timeIntervalSince1970
                report.retryIn = Swift.min(report.retryIn ?? left, left)
                continue
            }
            do {
                let sendEtag = cache.flatMap { (c: CacheFile) -> String? in c.schema >= PriceFeed.schema ? c.etag : nil }
                switch try await config.fetcher.fetch(source, etag: sendEtag) {
                case .notModified:
                    guard let cache, cache.schema >= PriceFeed.schema else { throw PriceFeedError.status(304) }
                    writeCache(source, winners: cache.rows, exact: cache.exact, etag: cache.etag, fetched: now)
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

/// When the running app asks the price feed again (the Windows app's rule, `PRICE_CHECK_SECONDS` and `PRICE_RETRY_SECONDS`
/// in gui/app.py): every six hours while all goes well (the feed's one-day wait decides whether that asks the network at
/// all); after a failed pass an hour, twice as long after each further failure in a row, never past six hours; and no
/// later than a failure the feed remembers from before is over. A success sets the count back to zero.
public enum PriceSchedule {
    public static let checkSeconds: TimeInterval = 6 * 3600
    public static let retrySeconds: TimeInterval = 3600

    /// The wait before the next pass. `failuresInARow` counts the passes that failed, this one included; `retryIn` is
    /// `PriceRefreshReport.retryIn`.
    public static func wait(failuresInARow: Int, retryIn: TimeInterval? = nil) -> TimeInterval {
        var wait = checkSeconds
        if failuresInARow > 0 {
            // 1 h, 2 h, 4 h, 6 h: the shift stops where six hours are passed anyway (and cannot overflow).
            wait = failuresInARow >= 4 ? checkSeconds : Swift.min(checkSeconds, retrySeconds * Double(1 << (failuresInARow - 1)))
        }
        if let retryIn { wait = Swift.min(wait, Swift.max(1, retryIn.rounded(.up))) }
        return wait
    }

    /// The count after a pass: one more for a pass that failed, back to zero for one that went through, the same for a
    /// pass that only waited out a remembered failure (or did nothing, offline).
    public static func failures(after report: PriceRefreshReport?, was count: Int) -> Int {
        guard let report else { return 0 }
        if !report.failed.isEmpty { return count + 1 }
        return report.retryIn != nil ? count : 0
    }
}
