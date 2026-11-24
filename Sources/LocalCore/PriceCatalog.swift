import Foundation

/// The three price catalogues. OpenRouter is read at run time only (its catalogue licence is not verified,
/// so it is never embedded); LiteLLM and models.dev are MIT and ship as a snapshot.
public enum PriceSource: String, CaseIterable, Sendable {
    case openrouter, litellm, modelsdev

    public var displayName: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .litellm: return "LiteLLM"
        case .modelsdev: return "models.dev"
        }
    }

    public var url: URL {
        switch self {
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1/models")!
        case .litellm: return URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
        case .modelsdev: return URL(string: "https://models.dev/api.json")!
        }
    }

    var cacheFileName: String { "prices-\(rawValue).json" }
}

/// What a catalogue row may hold. A catalogue (or a cache file someone edited) that says otherwise is corrupt:
/// the row is left out rather than priced, or written back as `Infinity`, which JSON cannot hold.
enum PriceLimits {
    /// USD per 1M tokens: a million dollars is a dollar a token, far above any model.
    static let maxRate = 1_000_000.0
    /// Prompt tokens a price tier may start at.
    static let maxTierTokens: Int64 = 1_000_000_000_000

    static func isRate(_ v: Double) -> Bool { v.isFinite && v >= 0 && v <= maxRate }
}

/// Rates that apply from `minPrompt` prompt tokens up. Zero means the catalogue does not say.
struct CatalogTier: Sendable, Equatable {
    var minPrompt: Int64
    var input, output, cacheRead, cacheWrite, cacheWrite1h: Double

    /// A tier starts at 1 token or more and prices both input and output; the cache prices may be unsaid (0).
    var isSane: Bool {
        minPrompt >= 1 && minPrompt <= PriceLimits.maxTierTokens + 1 && input > 0 && output > 0
            && [input, output, cacheRead, cacheWrite, cacheWrite1h].allSatisfy(PriceLimits.isRate)
    }
}

/// One catalogue row in USD per 1M tokens, as the catalogue states it: a cache price it leaves out is 0 here
/// and falls back to the input price only when the row becomes a `PriceEntry`.
struct CatalogRow: Sendable, Equatable {
    var input, output, cacheRead, cacheWrite, cacheWrite1h: Double
    var tiers: [CatalogTier] = []
    var name = ""

    /// Both prices must be positive: a router priced -1 or a free route says nothing about a price. Every rate must be
    /// a finite number from 0 up to `PriceLimits.maxRate`, and every tier sane: a row that is not is no price at all.
    var isPriced: Bool {
        input > 0 && output > 0 && [input, output, cacheRead, cacheWrite, cacheWrite1h].allSatisfy(PriceLimits.isRate)
            && tiers.allSatisfy(\.isSane)
    }

    /// `[input, output, cacheRead, cacheWrite, cacheWrite1h, [[minPrompt, input, ...]], name?]`
    init?(compact a: [Any]) {
        guard a.count >= 5 else { return nil }
        let nums = a.prefix(5).map { PriceParsers.number($0) }
        input = nums[0]; output = nums[1]; cacheRead = nums[2]; cacheWrite = nums[3]; cacheWrite1h = nums[4]
        if a.count > 5, let list = a[5] as? [[Any]] {
            for t in list where t.count >= 6 {
                let n = t.map { PriceParsers.number($0) }
                // A threshold that is no Int64 is a corrupt cache file, and so is the row it is in.
                guard let start = Safe.size(n[0], limit: PriceLimits.maxTierTokens + 1) else { return nil }
                tiers.append(CatalogTier(minPrompt: start, input: n[1], output: n[2], cacheRead: n[3], cacheWrite: n[4], cacheWrite1h: n[5]))
            }
        }
        if a.count > 6, let s = a[6] as? String { name = s }
        guard isPriced else { return nil }
    }

    init(input: Double, output: Double, cacheRead: Double = 0, cacheWrite: Double = 0, cacheWrite1h: Double = 0,
         tiers: [CatalogTier] = [], name: String = "") {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h; self.tiers = tiers; self.name = name
    }

    var compact: [Any] {
        var a: [Any] = [input, output, cacheRead, cacheWrite, cacheWrite1h]
        a.append(tiers.map { [Double($0.minPrompt), $0.input, $0.output, $0.cacheRead, $0.cacheWrite, $0.cacheWrite1h] as [Any] })
        if !name.isEmpty { a.append(name) }
        return a
    }
}

/// One catalogue, indexed two ways: by exact id (OpenRouter and LiteLLM) and by `ModelNames` key.
final class Catalog: @unchecked Sendable {
    struct Hit { let id: String; let row: CatalogRow }

    let source: PriceSource
    let byID: [String: Hit]
    let byKey: [String: Hit]

    var rowCount: Int { byID.isEmpty ? byKey.count : byID.count }

    /// `rows` are indexed by id and by key. `exact` are rows only a lookup by exact id can reach (see `split`): they join
    /// the id index and never speak for a key.
    init(source: PriceSource, rows: [String: CatalogRow], exact: [String: CatalogRow] = [:]) {
        self.source = source
        var ids: [String: Hit] = [:]
        var groups: [String: [Hit]] = [:]
        for (id, row) in rows {
            if Catalog.isRouteTagged(id) { continue }
            groups[Catalog.key(source: source, id: id), default: []].append(Hit(id: id, row: row))
        }
        if source != .modelsdev {
            // Ids that differ only in case share one slot: the first in sorted order keeps it, so the whole catalogue and the
            // one built again from winners and exact rows agree, whatever order the rows came in.
            var every = exact
            for (id, row) in rows { every[id] = row }
            let sorted = every.keys.sorted { (a: String, b: String) -> Bool in a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }
            for id in sorted {
                let folded = id.lowercased()
                if ids[folded] == nil, let row = every[id] { ids[folded] = Hit(id: id, row: row) }
            }
        }
        byID = ids
        byKey = groups.mapValues { Catalog.choose(source: source, $0) }
    }

    /// What a cache file or the snapshot keeps of a whole catalogue: `winners`, the row the index picks for each key (the
    /// only rows that speak for a name), and `exact`, the other rows (OpenRouter and LiteLLM) that a lookup by exact id
    /// can still return: a route (`:batch`, `:nitro`), a provider (`vertex_ai/...`), a dated or regional id, whatever its
    /// price. A row that says what its key's winner says stays too: whole, a lookup by that exact id answers from this
    /// catalogue before a later one is asked, and a cache without the row would hand the name to the next catalogue. The
    /// two are kept apart because the winner of a key is chosen among all its rows: a catalogue built again from the
    /// kept rows must choose the same winners.
    static func split(source: PriceSource, rows: [String: CatalogRow]) -> (winners: [String: CatalogRow], exact: [String: CatalogRow]) {
        let whole = Catalog(source: source, rows: rows)
        var winners: [String: CatalogRow] = [:]
        for hit in whole.byKey.values { winners[hit.id] = hit.row }
        guard source != .modelsdev else { return (winners, [:]) }
        var exact: [String: CatalogRow] = [:]
        for (id, row) in rows where winners[id] == nil { exact[id] = row }
        return (winners, exact)
    }

    /// models.dev ids are `provider/model-id`; the provider is not part of the model's name.
    static func modelPart(_ source: PriceSource, _ id: String) -> String {
        if source == .modelsdev, let slash = id.firstIndex(of: "/") { return String(id[id.index(after: slash)...]) }
        return id
    }

    static func key(source: PriceSource, id: String) -> String { ModelNames.key1(modelPart(source, id)) }

    /// `vendor/model:free`, `:batch` ...: the bare row is the model's price, the tagged one a variant.
    static func isRouteTagged(_ id: String) -> Bool { ModelNames.dropBedrockVersion(id).contains(":") }

    static func depth(_ source: PriceSource, _ id: String) -> Int {
        let model = modelPart(source, id)
        let last = (model.lastIndex(of: "/").map { String(model[model.index(after: $0)...]) } ?? model).lowercased()
        let slashes = model.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
        let prefixed = ModelNames.vendorPrefixLength(last) != nil || ModelNames.regionPrefixLength(last) != nil
        return slashes + (prefixed ? 1 : 0)
    }

    /// The row that speaks for a key: the shallowest ids, then the middle price of those, then the first id.
    static func choose(source: PriceSource, _ items: [Hit]) -> Hit {
        let best = items.map { depth(source, $0.id) }.min() ?? 0
        let shallow = items.filter { depth(source, $0.id) == best }.sorted {
            if $0.row.input != $1.row.input { return $0.row.input < $1.row.input }
            if $0.row.output != $1.row.output { return $0.row.output < $1.row.output }
            return $0.id < $1.id
        }
        let middle = shallow[(shallow.count - 1) / 2].row
        return shallow.first { $0.row.input == middle.input && $0.row.output == middle.output } ?? shallow[0]
    }
}

/// The catalogues the app prices from, with where each came from.
public struct PriceCatalogs: Sendable {
    public enum Origin: Sendable, Equatable { case cache(Date), snapshot(String), none }

    var catalogs: [PriceSource: Catalog] = [:]
    public var origins: [PriceSource: Origin] = [:]

    public init() {}

    /// Lookup order: OpenRouter, LiteLLM, models.dev.
    var ordered: [Catalog] { PriceSource.allCases.compactMap { catalogs[$0] } }

    mutating func set(_ source: PriceSource, rows: [String: CatalogRow], exact: [String: CatalogRow] = [:], origin: Origin) {
        catalogs[source] = Catalog(source: source, rows: rows, exact: exact)
        origins[source] = origin
    }

    /// Newest date among the sources, "yyyy-MM-dd"; nil when there are none.
    public var date: String? {
        let days: [String] = origins.values.compactMap {
            switch $0 {
            case .cache(let d): return PriceCatalogs.day(d)
            case .snapshot(let s): return s
            case .none: return nil
            }
        }
        return days.max()
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// What ships inside the app: LiteLLM and models.dev as of the last `scripts/update-prices.py` run.
    public static var embedded: PriceCatalogs { PriceSnapshot.catalogs }

    /// The text of the embedded snapshot (the same as Resources/prices-snapshot.json).
    public static var embeddedSnapshotText: String { priceSnapshotJSON }

    /// Rows from raw source text, for tests and tools (no network, no cache).
    public static func fromRaw(_ files: [PriceSource: Data], date: String = "test") -> PriceCatalogs {
        var out = PriceCatalogs()
        for (source, data) in files {
            if let rows = PriceParsers.rows(source, data) { out.set(source, rows: rows, origin: .snapshot(date)) }
        }
        return out
    }
}

/// The embedded snapshot (Resources/prices-snapshot.json, also written as `priceSnapshotJSON`).
enum PriceSnapshot {
    static let catalogs: PriceCatalogs = {
        var out = PriceCatalogs()
        guard let root = (try? JSONSerialization.jsonObject(with: Data(priceSnapshotJSON.utf8))) as? [String: Any] else { return out }
        let generated = (root["generated"] as? String) ?? ""
        for source in [PriceSource.litellm, .modelsdev] {
            let exact = PriceParsers.compactRows((root["exact"] as? [String: Any])?[source.rawValue]) ?? [:]
            if let rows = PriceParsers.compactRows(root[source.rawValue]) { out.set(source, rows: rows, exact: exact, origin: .snapshot(generated)) }
        }
        return out
    }()
}

/// Catalogue text -> rows in USD per 1M tokens. A parser returns nil for text that is not that catalogue's JSON
/// or has no priced row; nothing partial reaches the cache.
enum PriceParsers {
    static func number(_ any: Any?) -> Double {
        let v: Double
        if let n = any as? NSNumber { v = n.doubleValue } else if let s = any as? String, let d = Double(s) { v = d } else { return 0 }
        return v.isFinite ? v : 0
    }

    /// `number` for a catalogue that came over the network: a JSON `true`/`false` is no number there (0, as on Windows), not
    /// 1/0. The alias file keeps its own reading (a boolean is 1/0 in `model-aliases.json`, accepted since 9.0.3).
    static func catalogNumber(_ any: Any?) -> Double {
        if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return 0 }
        return number(any)
    }

    /// A JSON number that is not a boolean (an `NSNumber` is both).
    static func isCatalogNumber(_ any: Any?) -> Bool {
        guard let n = any as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID()
    }

    /// A JSON field that says something: a missing key and a null are both "not given" (a tier then keeps the base row's price).
    static func given(_ any: Any?) -> Bool { any != nil && !(any is NSNull) }

    /// USD per token (or per 1M) -> USD per 1M tokens, six decimals.
    static func perMillion(_ any: Any?) -> Double {
        let v = catalogNumber(any) * 1_000_000
        return (v * 1_000_000).rounded(.toNearestOrEven) / 1_000_000
    }

    static func rows(_ source: PriceSource, _ data: Data) -> [String: CatalogRow]? {
        switch source {
        case .openrouter: return openRouter(data)
        case .litellm: return liteLLM(data)
        case .modelsdev: return modelsDev(data)
        }
    }

    /// `{"id": [input, output, ...]}` as the snapshot and the cache files hold it.
    static func compactRows(_ any: Any?) -> [String: CatalogRow]? {
        guard let dict = any as? [String: [Any]] else { return nil }
        var out: [String: CatalogRow] = [:]
        for (id, a) in dict { if let row = CatalogRow(compact: a) { out[id] = row } }
        return out.isEmpty ? nil : out
    }

    private static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// OpenRouter /api/v1/models: USD per token as strings. `-1` (routers) and zero prices are dropped;
    /// `pricing.overrides` entries with `min_prompt_tokens` are length tiers, the time-of-day ones are not.
    static func openRouter(_ data: Data) -> [String: CatalogRow]? {
        guard let root = json(data) as? [String: Any], let list = root["data"] as? [[String: Any]] else { return nil }
        var out: [String: CatalogRow] = [:]
        for m in list {
            guard let id = m["id"] as? String, let p = m["pricing"] as? [String: Any] else { continue }
            var row = CatalogRow(input: perMillion(p["prompt"]), output: perMillion(p["completion"]),
                                 cacheRead: max(perMillion(p["input_cache_read"]), 0), cacheWrite: max(perMillion(p["input_cache_write"]), 0),
                                 cacheWrite1h: max(perMillion(p["input_cache_write_1h"]), 0))
            let overrides = (p["overrides"] as? [[String: Any]] ?? []).filter { $0["min_prompt_tokens"] != nil }
                .sorted { catalogNumber($0["min_prompt_tokens"]) < catalogNumber($1["min_prompt_tokens"]) }
            var corrupt = false
            for t in overrides {
                // A threshold that is zero, negative or no Int64 spoils the row, as a negative rate does.
                guard let start = Safe.size(catalogNumber(t["min_prompt_tokens"]), limit: PriceLimits.maxTierTokens), start > 0 else { corrupt = true; break }
                // A cache price the tier does not state is the base row's (as a LiteLLM tier carries it), not 0: 0 would
                // make it the tier's input price.
                let tierInput: Double = given(t["prompt"]) ? perMillion(t["prompt"]) : row.input
                let tierOutput: Double = given(t["completion"]) ? perMillion(t["completion"]) : row.output
                let tierRead: Double = given(t["input_cache_read"]) ? perMillion(t["input_cache_read"]) : row.cacheRead
                let tierWrite: Double = given(t["input_cache_write"]) ? perMillion(t["input_cache_write"]) : row.cacheWrite
                let tierWrite1h: Double = given(t["input_cache_write_1h"]) ? perMillion(t["input_cache_write_1h"]) : row.cacheWrite1h
                row.tiers.append(CatalogTier(minPrompt: start, input: tierInput, output: tierOutput, cacheRead: tierRead,
                                             cacheWrite: tierWrite, cacheWrite1h: tierWrite1h))
            }
            row.name = displayName(m["name"] as? String ?? "")
            if !corrupt, row.isPriced { out[id] = row }
        }
        return out.isEmpty ? nil : out
    }

    /// "Anthropic: Claude Opus 5.5" -> "Claude Opus 5.5".
    static func displayName(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":"), name.distance(from: name.startIndex, to: colon) >= 1,
              name.distance(from: name.startIndex, to: colon) <= 40 else { return name }
        return String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    private static let literalFields = ["input_cost_per_token", "output_cost_per_token", "cache_read_input_token_cost",
                                        "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr"]

    /// LiteLLM: USD per token as numbers; `<field>_above_<N>k_tokens` is a tier that starts above N thousand tokens.
    static func liteLLM(_ data: Data) -> [String: CatalogRow]? {
        guard let root = json(data) as? [String: Any] else { return nil }
        var out: [String: CatalogRow] = [:]
        for (id, any) in root {
            guard id != "sample_spec", let v = any as? [String: Any] else { continue }
            // `mode` is one of the three words, or not there (null is "not there"): a number or a boolean there drops the row, as on Windows.
            if let raw = v["mode"], !(raw is NSNull) {
                guard let mode = raw as? String, ["chat", "completion", "responses"].contains(mode) else { continue }
            }
            let base = literalFields.map { perMillion(v[$0]) }
            var thresholds: [Int64: [Int: Double]] = [:]
            var corrupt = false
            for (field, value) in v where isCatalogNumber(value) {
                for (index, name) in literalFields.enumerated() where field.hasPrefix(name + "_above_") && field.hasSuffix("k_tokens") {
                    let middle = field.dropFirst(name.count + 7).dropLast(8)
                    if !middle.isEmpty, middle.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        // `<N>k` must be a whole number of thousands that, times 1000, is a size a prompt can have.
                        guard let k = Int64(middle), k >= 1, k <= PriceLimits.maxTierTokens / 1000 else { corrupt = true; continue }
                        thresholds[k * 1000, default: [:]][index] = perMillion(value)
                    }
                }
            }
            var carried = base
            var tiers: [CatalogTier] = []
            for threshold in thresholds.keys.sorted() {
                for index in 0..<5 { carried[index] = thresholds[threshold]?[index] ?? carried[index] }
                tiers.append(CatalogTier(minPrompt: threshold + 1, input: carried[0], output: carried[1], cacheRead: carried[2],
                                         cacheWrite: carried[3], cacheWrite1h: carried[4]))
            }
            let row = CatalogRow(input: base[0], output: base[1], cacheRead: base[2], cacheWrite: base[3], cacheWrite1h: base[4], tiers: tiers)
            if !corrupt, row.isPriced { out[id] = row }
        }
        return out.isEmpty ? nil : out
    }

    /// models.dev: `{provider: {models: {id: {cost: {input, output, cache_read, cache_write, tiers, context_over_200k}}}}}`,
    /// USD per 1M tokens already. Row ids are `provider/model-id`.
    static func modelsDev(_ data: Data) -> [String: CatalogRow]? {
        guard let root = json(data) as? [String: Any] else { return nil }
        var out: [String: CatalogRow] = [:]
        for (provider, body) in root {
            guard let models = (body as? [String: Any])?["models"] as? [String: Any] else { continue }
            for (modelID, any) in models {
                guard let m = any as? [String: Any], let c = m["cost"] as? [String: Any] else { continue }
                var row = CatalogRow(input: catalogNumber(c["input"]), output: catalogNumber(c["output"]), cacheRead: catalogNumber(c["cache_read"]),
                                     cacheWrite: catalogNumber(c["cache_write"]), cacheWrite1h: 0)
                let contextTiers = (c["tiers"] as? [[String: Any]] ?? []).filter { ($0["tier"] as? [String: Any])?["type"] as? String == "context" }
                    .sorted { catalogNumber(($0["tier"] as? [String: Any])?["size"]) < catalogNumber(($1["tier"] as? [String: Any])?["size"]) }
                var corrupt = false
                for t in contextTiers {
                    // A size that is zero, negative or no Int64 spoils the row, as a negative rate does.
                    guard let size = Safe.size(catalogNumber((t["tier"] as? [String: Any])?["size"]), limit: PriceLimits.maxTierTokens), size > 0 else {
                        corrupt = true
                        break
                    }
                    let tierInput: Double = given(t["input"]) ? catalogNumber(t["input"]) : row.input
                    let tierOutput: Double = given(t["output"]) ? catalogNumber(t["output"]) : row.output
                    let tierRead: Double = given(t["cache_read"]) ? catalogNumber(t["cache_read"]) : row.cacheRead
                    let tierWrite: Double = given(t["cache_write"]) ? catalogNumber(t["cache_write"]) : row.cacheWrite
                    row.tiers.append(CatalogTier(minPrompt: size + 1, input: tierInput, output: tierOutput, cacheRead: tierRead,
                                                 cacheWrite: tierWrite, cacheWrite1h: 0))
                }
                if row.tiers.isEmpty, let over = c["context_over_200k"] as? [String: Any] {
                    let overInput: Double = given(over["input"]) ? catalogNumber(over["input"]) : row.input
                    let overOutput: Double = given(over["output"]) ? catalogNumber(over["output"]) : row.output
                    let overRead: Double = given(over["cache_read"]) ? catalogNumber(over["cache_read"]) : row.cacheRead
                    let overWrite: Double = given(over["cache_write"]) ? catalogNumber(over["cache_write"]) : row.cacheWrite
                    row.tiers.append(CatalogTier(minPrompt: 200_001, input: overInput, output: overOutput, cacheRead: overRead,
                                                 cacheWrite: overWrite, cacheWrite1h: 0))
                }
                row.name = (m["name"] as? String) ?? ""
                if !corrupt, row.isPriced { out["\(provider)/\(modelID)"] = row }
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// For `TokenChecks priceparity`: which rows the index keeps of raw catalogue files.
public enum PriceTools {
    public static func keptRows(litellm: Data, modelsdev: Data) -> [String: [String: [Any]]] {
        var out: [String: [String: [Any]]] = [:]
        for (source, data) in [(PriceSource.litellm, litellm), (.modelsdev, modelsdev)] {
            guard let rows = PriceParsers.rows(source, data) else { continue }
            let split = Catalog.split(source: source, rows: rows)
            out[source.rawValue] = split.winners.mapValues { (row: CatalogRow) -> [Any] in row.compact }
            if !split.exact.isEmpty { out[source.rawValue + "-exact"] = split.exact.mapValues { (row: CatalogRow) -> [Any] in row.compact } }
        }
        return out
    }
}
