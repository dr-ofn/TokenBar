import Foundation

/// How the price of a model was found.
public enum PriceKind: Sendable, Equatable {
    /// An OpenRouter price: from the hand-corrected table (pinned at its date) or from the live catalogue.
    case openrouter
    /// The price of the nearest paid model, chosen by hand (see the row's note).
    case near
    /// A price published elsewhere, quoted in the row.
    case other
    /// A LiteLLM catalogue row.
    case litellm
    /// A models.dev catalogue row.
    case modelsdev
    /// The user's alias (`~/.config/tokenbar/model-aliases.json`).
    case alias
    /// No catalogue lists the name, but its family does: an account number, effort word or context size dropped.
    case approximate
    /// A model that runs on this Mac, priced as its cloud counterpart.
    case localCloud
    /// A model that runs on this Mac and has no cloud counterpart: no cost.
    case localFree
}

/// What one call costs, split by token kind.
public struct CostParts: Sendable, Equatable {
    public var input = 0.0
    public var cacheRead = 0.0
    public var cacheWrite = 0.0
    public var output = 0.0

    public init() {}

    public var total: Double { input + cacheRead + cacheWrite + output }

    public subscript(kind: TokenKind) -> Double {
        switch kind {
        case .cacheRead: return cacheRead
        case .input: return input
        case .cacheWrite: return cacheWrite
        case .output: return output
        }
    }

    public static func += (a: inout CostParts, b: CostParts) {
        a.input += b.input
        a.cacheRead += b.cacheRead
        a.cacheWrite += b.cacheWrite
        a.output += b.output
    }
}

/// USD per 1M tokens.
public struct PriceRates: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var cacheWrite1h: Double

    /// The 1-hour share of the cache writes is priced apart from the rest.
    func parts(_ t: TokenCounts) -> CostParts {
        // The fields are public vars: held again here, so a count set by hand cannot overflow or cost less than nothing.
        let written = Safe.count(t.cacheWrite), hour = min(Safe.count(t.cacheWrite1h), written)
        var parts = CostParts()
        parts.input = Double(Safe.count(t.input)) * input / 1_000_000
        parts.cacheRead = Double(Safe.count(t.cacheRead)) * cacheRead / 1_000_000
        parts.cacheWrite = (Double(written - hour) * cacheWrite + Double(hour) * cacheWrite1h) / 1_000_000
        parts.output = Double(Safe.count(t.output)) * output / 1_000_000
        return parts
    }
}

/// One row of the generated table (`scripts/update-prices.py`).
public struct PriceEntry: Sendable {
    /// Rates that apply from `minPrompt` prompt tokens up.
    public struct Tier: Sendable {
        public var minPrompt: Int64
        public var rates: PriceRates

        init(minPrompt: Int64, input: Double, output: Double, cacheRead: Double, cacheWrite: Double, cacheWrite1h: Double) {
            self.minPrompt = minPrompt
            rates = PriceRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h)
        }
    }

    public var key: String
    public var name: String
    public var kind: PriceKind
    /// Where the price is from, in words: "LiteLLM: claude-opus-5-5", "yerel → bulut karşılığı: ...".
    public var source: String
    /// The catalogue the price was read from ("OpenRouter", "LiteLLM", "models.dev") and the row's id in it; nil for
    /// hand-made rows, user aliases and local models without a cloud counterpart.
    public var catalog: String?
    public var catalogID: String?
    public var rates: PriceRates
    public var tiers: [Tier]

    public init(key: String, name: String, kind: PriceKind, source: String, catalog: String? = nil, catalogID: String? = nil,
         input: Double, output: Double, cacheRead: Double, cacheWrite: Double, cacheWrite1h: Double, tiers: [Tier]) {
        self.key = key
        self.name = name
        self.kind = kind
        self.source = source
        self.catalog = catalog
        self.catalogID = catalogID
        rates = PriceRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h)
        self.tiers = tiers
    }

    /// The last tier the prompt reaches; the table lists tiers in ascending order.
    func rates(forPrompt prompt: Int64) -> PriceRates {
        tiers.last { prompt >= $0.minPrompt }?.rates ?? rates
    }
}

/// The price of one model as the logs name it. A cloud model is never free here: a call on a free route or a free
/// preview is priced at the list price, because the picture shows API-equivalent use. A model that runs on this Mac
/// is priced as its cloud counterpart when there is one, and costs nothing when there is not.
public struct ModelPrice: Sendable {
    public var entry: PriceEntry?

    /// `provider` is the harness's own name for the server ("ollama", "lmstudio", "anthropic"); it only decides whether
    /// the model runs locally.
    public init(model: String, provider: String = "") {
        entry = PriceBook.resolve(provider: provider, model: model)
    }

    /// False when no table, catalogue or alias has a row for the model; such calls stay out of the cost.
    public var isPriced: Bool { entry != nil }

    public func parts(_ tokens: TokenCounts) -> CostParts {
        guard let entry else { return CostParts() }
        return entry.rates(forPrompt: tokens.promptTotal).parts(tokens)
    }

    /// For a row that sums many calls: its prompt total says nothing about a price tier.
    public func baseParts(_ tokens: TokenCounts) -> CostParts {
        guard let entry else { return CostParts() }
        return entry.rates.parts(tokens)
    }

    public func cost(_ tokens: TokenCounts) -> Double { parts(tokens).total }
}

public enum PriceBook {
    /// The newest date among the catalogues in use ("yyyy-MM-dd"): the embedded snapshot's, or a cache file's.
    public static var date: String { state().date }

    /// Counts up whenever the catalogues or the alias file are reloaded, so a view can tell its prices are stale.
    public static var revision: Int { _ = state(); return lock.withLock { revisionValue } }

    /// Posted (on the thread that installed the catalogues) after `revision` changed.
    public static let didChange = Notification.Name("TokenBarPriceBookDidChange")

    /// True when the network is off: `TOKENBAR_OFFLINE=1` or `PriceBook.offline = true` (the app's setting).
    public static var isOffline: Bool { offline || PriceFeed.environmentOffline }
    /// The app's Offline setting: written on the main thread, read by the refresh in the background.
    public static var offline: Bool {
        get { lock.withLock { offlineValue } }
        set { lock.withLock { offlineValue = newValue } }
    }

    /// The feed the app uses: the network is off when the setting or the environment says so, and a pass already
    /// running stops asking as soon as the setting turns on.
    public static func liveFeed() -> PriceFeed {
        var config = PriceFeed.Config(offline: isOffline)
        config.shouldStop = { PriceBook.isOffline }
        return PriceFeed(config)
    }

    /// `TOKENBAR_PRICES_PINNED=1`: the embedded snapshot and the hand-made tables only. No cache file, no alias file,
    /// no network: the same prices on every machine (scripts/check.sh, the oracle and the tests run pinned).
    public static var isPinned: Bool { ProcessInfo.processInfo.environment["TOKENBAR_PRICES_PINNED"] == "1" }

    // MARK: Lookup

    /// The price row of a logged model, or nil. See `PriceResolver.resolve`.
    static func resolve(provider: String, model: String) -> PriceEntry? { state().resolve(provider: provider, model: model) }

    /// The grouping key of a logged name: lowercase, without provider path, free mark or a date stamp. Prices are
    /// looked up by `ModelNames` keys; this key names the group of a model with no price.
    public static func normalize(_ model: String) -> String {
        var name = model.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        for suffix in [":free", "-free"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        let tail = name.suffix(9)
        if tail.count == 9, tail.first == "-", tail.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
            name = String(name.dropLast(9))
        }
        return name
    }

    // MARK: Catalogues

    /// Use these catalogues from now on (tests, tools and `reload`). Bumps `revision` and posts `didChange`.
    public static func install(catalogs: PriceCatalogs, aliases: UserAliases = .empty) {
        install(PriceResolver(catalogs: catalogs, override: priceTable, aliases: aliases))
    }

    static func install(_ resolver: PriceResolver) {
        lock.withLock {
            current = resolver
            revisionValue += 1
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Re-reads the cache files and the alias file (the embedded snapshot where a cache is missing).
    public static func reload(feed: PriceFeed = PriceFeed()) {
        install(catalogs: isPinned ? .embedded : feed.loadLocal(), aliases: isPinned ? .empty : loadAliases())
    }

    /// Reads the alias file of this home folder from now on, not the process's own (`tokenbar-cli --home DIR`,
    /// `Engine(home:)`). Call before the first price is looked up; a resolver already built is built again.
    public static func useHome(_ home: String) {
        let path = UserAliases.path(home: home)
        let rebuild = lock.withLock { () -> Bool in
            let changed = aliasPathValue != path
            aliasPathValue = path
            return changed && current != nil
        }
        if rebuild { reload() }
    }

    private static func loadAliases() -> UserAliases {
        UserAliases.load(path: lock.withLock { aliasPathValue } ?? UserAliases.defaultPath)
    }

    /// Asks the network for fresher catalogues, in the background and at most once a day per source; the first
    /// prices never wait for it. When something changed the cache is reloaded and `revision` counts up.
    /// Does nothing when offline or pinned.
    public static func startBackgroundRefresh(feed: PriceFeed = PriceBook.liveFeed()) {
        guard !isOffline, !isPinned, lock.withLock({ let first = !refreshStarted; refreshStarted = true; return first }) else { return }
        Task.detached(priority: .utility) {
            let report = await feed.refresh()
            if report.changed { reload(feed: feed) }
        }
    }

    // MARK: State

    nonisolated(unsafe) private static var current: PriceResolver?
    nonisolated(unsafe) private static var revisionValue = 0
    nonisolated(unsafe) private static var refreshStarted = false
    /// The alias file of the home folder in use; nil is the process's own home.
    nonisolated(unsafe) private static var aliasPathValue: String?
    nonisolated(unsafe) private static var offlineValue = false
    private static let lock = NSLock()

    private static func state() -> PriceResolver {
        if let c = lock.withLock({ current }) { return c }
        // Built outside the lock: reading cache files takes a moment. A second thread may build it too; the first wins.
        let built = PriceResolver(catalogs: isPinned ? .embedded : PriceFeed().loadLocal(), override: priceTable,
                                  aliases: isPinned ? .empty : loadAliases())
        return lock.withLock {
            if let c = current { return c }
            current = built
            revisionValue += 1
            return built
        }
    }
}
