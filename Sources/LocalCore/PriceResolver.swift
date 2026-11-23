import Foundation

/// Resolves a logged (provider, model) to a price row. Swift twin of `Pricer` in scripts/pricelib.py.
///
/// Order, first hit wins:
///  1. the user's alias (`UserAliases`)
///  2. the hand-corrected table (the "override" layer)
///  3. an exact catalogue id (OpenRouter, then LiteLLM): `anthropic/claude-sonnet-4.5`
///  4. the normalised name in OpenRouter, LiteLLM, models.dev
///  5. the family proxy (`.approximate`): an account number, effort word or context size dropped, at most twice
///  6. nothing
/// A model on this Mac (a local provider, or a quantisation suffix in the name) takes steps 1-4 and is then
/// priced as that cloud counterpart (`.localCloud`); without one it costs nothing (`.localFree`).
final class PriceResolver: @unchecked Sendable {
    let catalogs: PriceCatalogs
    private let ordered: [Catalog]
    private let override: [String: PriceEntry]
    private let aliases: UserAliases
    private let lock = NSLock()
    private var memo: [String: PriceEntry?] = [:]

    init(catalogs: PriceCatalogs, override: [PriceEntry], aliases: UserAliases) {
        self.catalogs = catalogs
        ordered = catalogs.ordered
        // A later row wins when two keys fold to the same name, as in the Python twin.
        self.override = Dictionary(override.map { (ModelNames.key1($0.key), $0) }, uniquingKeysWith: { _, last in last })
        self.aliases = aliases
    }

    var date: String { catalogs.date ?? priceTableDate }

    func resolve(provider: String, model: String) -> PriceEntry? {
        let id = ModelNames.providerKey(provider) + "\u{0}" + model
        if let cached = lock.withLock({ memo[id] }) { return cached }
        let entry = compute(provider: provider, model: model)
        lock.withLock { memo[id] = .some(entry) }
        return entry
    }

    // MARK: Stages

    private func tableHit(_ table: [String: PriceEntry], _ keys: [String]) -> PriceEntry? {
        for k in keys { if let e = table[k] { return e } }
        return nil
    }

    private func entry(_ catalog: Catalog, _ hit: Catalog.Hit, key: String) -> PriceEntry {
        PriceResolver.entry(source: catalog.source, id: hit.id, row: hit.row, key: key)
    }

    static func entry(source: PriceSource, id: String, row: CatalogRow, key: String) -> PriceEntry {
        func rates(_ input: Double, _ output: Double, _ read: Double, _ write: Double, _ write1h: Double) -> (Double, Double, Double, Double, Double) {
            let w = write > 0 ? write : input
            return (input, output, read > 0 ? read : input, w, write1h > 0 ? write1h : w)
        }
        let r = rates(row.input, row.output, row.cacheRead, row.cacheWrite, row.cacheWrite1h)
        let tiers = row.tiers.map { t -> PriceEntry.Tier in
            let x = rates(t.input, t.output, t.cacheRead, t.cacheWrite, t.cacheWrite1h)
            return PriceEntry.Tier(minPrompt: t.minPrompt, input: x.0, output: x.1, cacheRead: x.2, cacheWrite: x.3, cacheWrite1h: x.4)
        }
        // The catalogue's own name when it has one (LiteLLM rows have none); otherwise a readable form of the id.
        let name = !row.name.isEmpty ? row.name : ModelNames.display(Catalog.modelPart(source, id))
        let kind: PriceKind = source == .openrouter ? .openrouter : source == .litellm ? .litellm : .modelsdev
        return PriceEntry(key: key, name: name, kind: kind, source: "\(source.displayName): \(id)", catalog: source.displayName, catalogID: id,
                          input: r.0, output: r.1, cacheRead: r.2, cacheWrite: r.3, cacheWrite1h: r.4, tiers: tiers)
    }

    /// A row the catalogue left without a name takes the name another catalogue gives the same model (OpenRouter,
    /// models.dev), else the readable form of its id. Only the picture's label changes, never a price.
    private func named(_ e: PriceEntry, hit: Catalog.Hit, keys: [String]) -> PriceEntry {
        guard hit.row.name.isEmpty else { return e }
        var out = e
        for catalog in ordered {
            for key in keys {
                if let other = catalog.byKey[key], !other.row.name.isEmpty { out.name = other.row.name; return out }
            }
        }
        return out
    }

    private func catalogHit(keys: [String], raw: String?) -> PriceEntry? {
        if let raw {
            for catalog in ordered where catalog.source != .modelsdev {
                if let hit = catalog.byID[raw] { return named(entry(catalog, hit, key: keys[0]), hit: hit, keys: keys) }
            }
        }
        for key in keys {
            for catalog in ordered {
                if let hit = catalog.byKey[key] { return named(entry(catalog, hit, key: key), hit: hit, keys: keys) }
            }
        }
        return nil
    }

    /// The hand-made tables, the exact id, the normalised name.
    private func lookup(_ keys: ModelKeys, raw: String?) -> PriceEntry? {
        if let e = tableHit(override, keys.ordered) { return e }
        return catalogHit(keys: keys.ordered, raw: raw)
    }

    private func free(key: String, name: String, source: String) -> PriceEntry {
        PriceEntry(key: key, name: name, kind: .localFree, source: source, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 0, tiers: [])
    }

    private func apply(alias: UserAliases.Target, key: String) -> PriceEntry? {
        switch alias {
        case .model(let target):
            guard var hit = lookup(ModelNames.keys(target), raw: ModelNames.stripBrackets(target.trimmingCharacters(in: .whitespaces).lowercased())) else { return nil }
            hit.source = "kullanıcı takma adı: \(key) → \(target) (\(hit.source))"
            hit.kind = .alias
            return hit
        case .free:
            return free(key: key, name: key, source: "kullanıcı takma adı: \(key) → ücretsiz")
        case .rates(let input, let output, let read, let write, let name, let note, let kind):
            let w = write > 0 ? write : input
            return PriceEntry(key: key, name: name ?? key, kind: kind,
                              source: "kullanıcı takma adı: \(key) → elle yazılmış fiyat" + (note.map { " (\($0))" } ?? ""),
                              input: input, output: output, cacheRead: read > 0 ? read : input, cacheWrite: w, cacheWrite1h: w, tiers: [])
        }
    }

    private func compute(provider: String, model: String) -> PriceEntry? {
        let keys = ModelNames.keys(model)
        let raw = ModelNames.stripBrackets(model.trimmingCharacters(in: .whitespaces).lowercased())
        let local = ModelNames.isLocalProvider(provider, extra: aliases.localProviders) || keys.quantised
        if let k = keys.ordered.first(where: { aliases.targets[$0] != nil }), let alias = aliases.targets[k],
           let hit = apply(alias: alias, key: keys.key1) { return hit }
        if var hit = lookup(keys, raw: raw) {
            if local {
                hit.kind = .localCloud
                hit.source = "yerel → bulut karşılığı: " + hit.source
            }
            return hit
        }
        if local { return free(key: keys.key1, name: model, source: "yerel, bulut karşılığı yok") }
        // Family proxy: drop an account number, effort word or context size, at most twice.
        var name = keys.key2
        for _ in 0..<2 {
            guard let shorter = ModelNames.familyStripped(name) else { break }
            name = shorter
            let proxy = ModelNames.keys(name)
            // An alias for the shorter name covers its account-numbered or effort-marked variants too.
            var found: PriceEntry?
            if let k = proxy.ordered.first(where: { aliases.targets[$0] != nil }), let alias = aliases.targets[k] { found = apply(alias: alias, key: proxy.key1) }
            if var hit = found ?? lookup(proxy, raw: nil) {
                hit.kind = .approximate
                hit.source = "yaklaşık: \(keys.key2) → \(name) (\(hit.source))"
                return hit
            }
        }
        return nil
    }
}
