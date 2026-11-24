import Foundation

/// A model as the logs name it, with its price.
public struct ModelInfo: Sendable {
    public var provider: String
    public var model: String
    public var price: ModelPrice

    /// The price table's name when it has one, otherwise the logged model name.
    public var name: String { price.entry?.name ?? model }
    public var id: String { provider + "/" + model }
    /// One model reached through several providers, routes or table rows is one band in the picture.
    public var group: String { price.entry?.name ?? PriceBook.normalize(model) }
}

/// One model inside one harness, in one period.
public struct ModelStat: Sendable, Identifiable {
    public var harness: HarnessID
    public var info: ModelInfo
    public var counts = TokenCounts()
    public var calls = 0
    public var cost = 0.0
    public var parts = CostParts()

    public var id: String { harness.rawValue + "|" + info.id }
    public var tokens: Int64 { counts.total }
}

/// One harness in one period.
public struct HarnessStat: Sendable, Identifiable {
    public var harness: HarnessID
    public var models: [ModelStat]
    public var counts = TokenCounts()
    public var calls = 0
    public var cost = 0.0
    public var parts = CostParts()

    public var id: String { harness.rawValue }
    public var tokens: Int64 { counts.total }
}

/// One model across every harness and route that used it.
public struct ModelGroup: Sendable, Identifiable {
    public var key: String
    public var name: String
    public var stats: [ModelStat]
    public var counts = TokenCounts()
    public var calls = 0
    public var cost = 0.0
    public var parts = CostParts()

    public var id: String { key }
    public var tokens: Int64 { counts.total }
    /// True when no route of this model has a price at all.
    public var isUnpriced: Bool { stats.allSatisfy { !$0.info.price.isPriced } }
    public var mainHarness: HarnessID {
        stats.max { ($0.cost, $0.tokens) < ($1.cost, $1.tokens) }?.harness ?? HarnessID(rawValue: "unknown")
    }
}

/// What a click or the pointer is on.
public enum UsageSelection: Sendable, Hashable {
    case flow(String)
    case harness(HarnessID)
    case model(String)
    /// The bands too thin to name, or the models that cost nothing.
    case list(String, [String])
    case total

    /// True when the model in this harness belongs to what is selected.
    public func contains(_ stat: ModelStat) -> Bool {
        switch self {
        case .flow(let id): return stat.id == id
        case .harness(let harness): return stat.harness == harness
        case .model(let key): return stat.info.group == key
        case .list(_, let keys): return keys.contains(stat.info.group)
        case .total: return true
        }
    }
}

/// The breakdown behind a selection.
public struct UsageDetail: Sendable {
    public struct Link: Sendable, Identifiable {
        public var selection: UsageSelection
        public var title: String
        public var tokens: Int64
        public var cost: String
        // Not the title: two logged names can share one price-table name.
        public var id: UsageSelection { selection }
    }

    public var title: String
    public var rows: [(label: String, value: String)]
    public var links: [Link] = []
    public var note: String?
    /// How the selection's tokens and dollars split by kind; nil for a plain list.
    public var counts: TokenCounts?
    public var parts: CostParts?
    /// The harness whose colour the selection is drawn in, when it has one.
    public var harness: HarnessID?
}

/// What one period shows. Adjustment rows hold tokens a harness recorded without a call of
/// their own: they count in tokens and cost but not as calls.
public struct UsageReport: Sendable {
    public var period: Period
    public var harnesses: [HarnessStat] = []
    public var groups: [ModelGroup] = []
    public var counts = TokenCounts()
    public var cost = 0.0
    public var parts = CostParts()
    /// When the period's tokens and dollars were used; nil when it has no buckets.
    public var tide: Tide?
    /// Models that ran in the period with nothing to price them by.
    public var unpriced: [ModelInfo] = []
    /// `PriceBook.revision` the rows were priced under: a view that sees a newer one has stale money.
    public var priceRevision = PriceBook.revision

    init(period: Period, stats: [ModelStat], tide: Tide? = nil) {
        self.period = period
        self.tide = tide
        // Fix the incoming order first, so group names and notes do not depend on dictionary order.
        let stats = stats.sorted { $0.id < $1.id }

        // The groups that already have an unpriced model in the list (a set: the list itself is searched once per model otherwise).
        var unpricedGroups = Set<String>()
        // Every harness the rows name, in a fixed order; the list is sorted by size below.
        let byHarness = Dictionary(grouping: stats, by: \.harness)
        for harness in byHarness.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let models = (byHarness[harness] ?? []).sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id < $1.id }
            guard !models.isEmpty else { continue }

            var stat = HarnessStat(harness: harness, models: models)
            for model in models {
                stat.counts += model.counts
                stat.calls += model.calls
                stat.cost += model.cost
                stat.parts += model.parts
                if !model.info.price.isPriced, unpricedGroups.insert(model.info.group).inserted {
                    unpriced.append(model.info)
                }
            }
            harnesses.append(stat)
            counts += stat.counts
            cost += stat.cost
            parts += stat.parts
        }
        harnesses.sort {
            $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id < $1.id
        }

        var byKey: [String: ModelGroup] = [:]
        for model in stats {
            var group = byKey[model.info.group] ?? ModelGroup(key: model.info.group, name: model.info.name, stats: [])
            group.stats.append(model)
            group.counts += model.counts
            group.calls += model.calls
            group.cost += model.cost
            group.parts += model.parts
            byKey[model.info.group] = group
        }
        groups = byKey.values.sorted {
            $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.key < $1.key
        }
    }

    public var callCount: Int { harnesses.reduce(0) { $0 + $1.calls } }
    public var isEmpty: Bool { harnesses.isEmpty }
    /// Changes when the picture has something new to draw.
    public var version: String { "\(period.rawValue)-\(callCount)-\(counts.total)-p\(priceRevision)" }

    public func model(_ id: String) -> ModelStat? {
        for harness in harnesses {
            if let model = harness.models.first(where: { $0.id == id }) { return model }
        }
        return nil
    }

    public func group(_ key: String) -> ModelGroup? { groups.first { $0.key == key } }

    /// False when something clicked in another report has nothing to show in this one.
    public func has(_ selection: UsageSelection) -> Bool {
        switch selection {
        case .flow(let id): return model(id) != nil
        case .harness(let harness): return harnesses.contains { $0.harness == harness }
        case .model(let key): return group(key) != nil
        case .list(_, let keys): return keys.contains { group($0) != nil }
        case .total: return !isEmpty
        }
    }

    /// How the group's price was found, when it has one: the route with the most tokens decides.
    private func priceRows(_ group: ModelGroup) -> [(label: String, value: String)] {
        guard let top = group.stats.max(by: { $0.tokens < $1.tokens }) else { return [] }
        return [(UsageText.priceTypeLabel, UsageText.priceKindLabel(top.info.price))]
    }

    public func detail(_ selection: UsageSelection) -> UsageDetail {
        switch selection {
        case .flow(let id):
            guard let model = model(id) else { return UsageDetail(title: id, rows: []) }
            return UsageDetail(
                title: "\(model.harness.name) · \(model.info.name), \(period.shortLabel): \(UsageText.calls(model.calls))",
                rows: UsageText.breakdown(model.counts) + [(UsageText.priceTypeLabel, UsageText.priceKindLabel(model.info.price)),
                                                           (UsageText.costLabel, UsageText.cost(model.cost, model.info.price))],
                note: "\(model.info.id). " + UsageText.priceNote(model.info.price),
                counts: model.counts, parts: model.parts, harness: model.harness)

        case .harness(let harness):
            guard let stat = harnesses.first(where: { $0.harness == harness }) else {
                return UsageDetail(title: harness.name, rows: [])
            }
            return UsageDetail(
                title: "\(stat.harness.name), \(period.shortLabel): \(UsageText.calls(stat.calls))",
                rows: UsageText.breakdown(stat.counts) + [(UsageText.costLabel, UsageText.money(stat.cost))],
                links: stat.models.map { model in
                    UsageDetail.Link(selection: .flow(model.id), title: model.info.name + " · " + model.info.provider,
                                     tokens: model.tokens, cost: UsageText.cost(model.cost, model.info.price))
                },
                counts: stat.counts, parts: stat.parts, harness: stat.harness)

        case .model(let key):
            guard let group = group(key) else { return UsageDetail(title: key, rows: []) }
            return UsageDetail(
                title: "\(group.name), \(period.shortLabel): \(UsageText.calls(group.calls))",
                rows: UsageText.breakdown(group.counts) + priceRows(group) + [(UsageText.costLabel, UsageText.groupCost(group))],
                links: group.stats.sorted { $0.tokens > $1.tokens }.map { model in
                    UsageDetail.Link(selection: .flow(model.id), title: model.harness.name + " · " + model.info.provider,
                                     tokens: model.tokens, cost: UsageText.cost(model.cost, model.info.price))
                },
                note: group.stats.max(by: { $0.tokens < $1.tokens }).map { UsageText.priceNote($0.info.price) },
                counts: group.counts, parts: group.parts, harness: group.mainHarness)

        case .list(let title, let keys):
            return UsageDetail(
                title: "\(title), \(period.shortLabel)", rows: [],
                links: keys.compactMap(group).sorted { $0.tokens > $1.tokens }.map { group in
                    UsageDetail.Link(selection: .model(group.key), title: group.name,
                                     tokens: group.tokens, cost: UsageText.groupCost(group))
                })

        case .total:
            return UsageDetail(
                title: L10n.t("Bütün araçlar", "All tools") + ", \(period.shortLabel): \(UsageText.calls(callCount))",
                rows: UsageText.breakdown(counts) + [(UsageText.costLabel, UsageText.money(cost))],
                note: UsageText.totalNote(self), counts: counts, parts: parts)
        }
    }
}
