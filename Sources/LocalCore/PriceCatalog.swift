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

    init(source: PriceSource, rows: [String: CatalogRow]) {
        self.source = source
        var ids: [String: Hit] = [:]
        var groups: [String: [Hit]] = [:]
        for (id, row) in rows {
            if source != .modelsdev { ids[id.lowercased()] = Hit(id: id, row: row) }
            if Catalog.isRouteTagged(id) { continue }
            groups[Catalog.key(source: source, id: id), default: []].append(Hit(id: id, row: row))
        }
        byID = ids
        byKey = groups.mapValues { Catalog.choose(source: source, $0) }
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

    mutating func set(_ source: PriceSource, rows: [String: CatalogRow], origin: Origin) {
        catalogs[source] = Catalog(source: source, rows: rows)
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
            if let rows = PriceParsers.compactRows(root[source.rawValue]) { out.set(source, rows: rows, origin: .snapshot(generated)) }
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

    /// USD per token (or per 1M) -> USD per 1M tokens, six decimals.
    static func perMillion(_ any: Any?) -> Double {
        let v = number(any) * 1_000_000
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
                .sorted { number($0["min_prompt_tokens"]) < number($1["min_prompt_tokens"]) }
            var corrupt = false
            for t in overrides {
                // A threshold that is zero, negative or no Int64 spoils the row, as a negative rate does.
                guard let start = Safe.size(number(t["min_prompt_tokens"]), limit: PriceLimits.maxTierTokens), start > 0 else { corrupt = true; break }
                row.tiers.append(CatalogTier(minPrompt: start,
                                             input: t["prompt"] != nil ? perMillion(t["prompt"]) : row.input,
                                             output: t["completion"] != nil ? perMillion(t["completion"]) : row.output,
                                             cacheRead: perMillion(t["input_cache_read"]), cacheWrite: perMillion(t["input_cache_write"]),
                                             cacheWrite1h: perMillion(t["input_cache_write_1h"])))
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
            if let mode = v["mode"] as? String, !["chat", "completion", "responses"].contains(mode) { continue }
            let base = literalFields.map { perMillion(v[$0]) }
            var thresholds: [Int64: [Int: Double]] = [:]
            var corrupt = false
            for (field, value) in v where value is NSNumber {
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
                var row = CatalogRow(input: number(c["input"]), output: number(c["output"]), cacheRead: number(c["cache_read"]),
                                     cacheWrite: number(c["cache_write"]), cacheWrite1h: 0)
                let contextTiers = (c["tiers"] as? [[String: Any]] ?? []).filter { ($0["tier"] as? [String: Any])?["type"] as? String == "context" }
                    .sorted { number(($0["tier"] as? [String: Any])?["size"]) < number(($1["tier"] as? [String: Any])?["size"]) }
                var corrupt = false
                for t in contextTiers {
                    // A size that is zero, negative or no Int64 spoils the row, as a negative rate does.
                    guard let size = Safe.size(number((t["tier"] as? [String: Any])?["size"]), limit: PriceLimits.maxTierTokens), size > 0 else {
                        corrupt = true
                        break
                    }
                    row.tiers.append(CatalogTier(minPrompt: size + 1, input: t["input"] != nil ? number(t["input"]) : row.input,
                                                 output: t["output"] != nil ? number(t["output"]) : row.output,
                                                 cacheRead: number(t["cache_read"]), cacheWrite: number(t["cache_write"]), cacheWrite1h: 0))
                }
                if row.tiers.isEmpty, let over = c["context_over_200k"] as? [String: Any] {
                    row.tiers.append(CatalogTier(minPrompt: 200_001, input: over["input"] != nil ? number(over["input"]) : row.input,
                                                 output: over["output"] != nil ? number(over["output"]) : row.output,
                                                 cacheRead: number(over["cache_read"]), cacheWrite: number(over["cache_write"]), cacheWrite1h: 0))
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
            var kept: [String: [Any]] = [:]
            for hit in Catalog(source: source, rows: rows).byKey.values { kept[hit.id] = hit.row.compact }
            out[source.rawValue] = kept
        }
        return out
    }
}
