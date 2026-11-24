import Foundation

/// The four edges of something that runs from the left rail to the right rail.
public protocol FlowShape {
    var leftTop: Double { get }
    var leftHeight: Double { get }
    var rightTop: Double { get }
    var rightHeight: Double { get }
}

/// Where everything sits in the picture: harnesses stacked on the left by tokens, models on
/// the right by dollars, one ribbon per model in each harness. Both scales are linear, so a
/// ribbon's width at each end is its true share. Coordinates grow downward.
public struct RibbonLayout: Sendable {
    /// One kind of token inside a ribbon.
    public struct Strand: Sendable, FlowShape {
        public var kind: TokenKind
        public var leftTop: Double
        public var leftHeight: Double
        public var rightTop: Double
        public var rightHeight: Double
    }

    public struct Ribbon: Sendable, Identifiable, FlowShape {
        public var stat: ModelStat
        public var group: String
        /// Shade inside the harness's colour: -1, 0 or 1.
        public var tone: Int
        public var leftTop: Double
        public var leftHeight: Double
        public var rightTop: Double
        public var rightHeight: Double
        /// How each end splits by token kind, in `TokenKind.allCases` order. Each sums to 1,
        /// or is all zeros when the end has nothing to split.
        public var leftShares: [Double]
        public var rightShares: [Double]
        public var id: String { stat.id }

        /// Its kinds of token, top to bottom; empty when the ribbon is too thin to show them.
        public var strands: [Strand] {
            guard leftHeight + rightHeight > 3, stat.tokens > 0 else { return [] }
            var left = leftTop, right = rightTop
            return TokenKind.allCases.enumerated().map { index, kind in
                let strand = Strand(kind: kind, leftTop: left, leftHeight: leftHeight * leftShares[index],
                                    rightTop: right, rightHeight: rightHeight * rightShares[index])
                left += strand.leftHeight
                right += strand.rightHeight
                return strand
            }
        }
    }

    /// A named label beside one of the rails.
    public struct Label: Sendable {
        public var selection: UsageSelection
        public var title: String
        public var value: String
        public var extra: String?
        public var harness: HarnessID?
        /// Where the band sits on the rail.
        public var anchor: Double
        /// Where the text sits; differs from `anchor` when labels had to make room.
        public var y: Double
        public var strong: Bool
    }

    public var width: Double
    public var leftX: Double
    public var rightX: Double
    public var top: Double
    public var bottom: Double
    public var ribbons: [Ribbon] = []
    public var leftLabels: [Label] = []
    public var rightLabels: [Label] = []
    /// Where ribbons of models the table has no price for end.
    public var freePoint: Double?
    /// The share of all tokens that ends at the free point.
    public var freeShare = 0.0

    public init(report: UsageReport, width: Double, height: Double, leftColumn: Double, rightColumn: Double,
                top: Double, bottomMargin: Double, labelGap: Double = 14) {
        self.width = width
        self.top = top
        bottom = height - bottomMargin
        leftX = leftColumn
        rightX = width - rightColumn
        guard !report.isEmpty else { return }
        let span = bottom - top

        let harnesses = report.harnesses.sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
        var harnessRank: [HarnessID: Int] = [:]
        for (index, h) in harnesses.enumerated() { harnessRank[h.harness] = index }

        // Models keep their main harness's order, so ribbons cross as little as possible.
        let groups = report.groups.sorted {
            let a = (harnessRank[$0.mainHarness] ?? 0, -$0.cost, -Double($0.tokens))
            let b = (harnessRank[$1.mainHarness] ?? 0, -$1.cost, -Double($1.tokens))
            return a < b
        }
        var groupRank: [String: Int] = [:]
        for (index, g) in groups.enumerated() { groupRank[g.key] = index }
        let tones = [0, 1, -1]
        var groupTone: [String: Int] = [:]
        var seenInHarness: [HarnessID: Int] = [:]
        for g in groups {
            let seen = seenInHarness[g.mainHarness, default: 0]
            groupTone[g.key] = tones[seen % tones.count]
            seenInHarness[g.mainHarness] = seen + 1
        }

        let paid = groups.filter { $0.cost > 0 }
        let free = groups.filter { $0.cost <= 0 }

        // Right rail. Gaps come out of the height first; the scale stays linear.
        let freeGap = free.isEmpty || paid.isEmpty ? 0.0 : Swift.min(22, span * 0.05)
        let namedShare = 0.006
        let wideGap = Swift.min(5, span * 0.008), thinGap = Swift.min(1, span * 0.002)
        func gap(before index: Int) -> Double {
            guard index > 0 else { return 0 }
            if paid[index - 1].mainHarness != paid[index].mainHarness { return wideGap }
            return paid[index].cost / report.cost >= namedShare ? thinGap : 0
        }
        let gapTotal = freeGap + paid.indices.reduce(0) { $0 + gap(before: $1) }
        let dollarScale = report.cost > 0 ? Swift.max(0, span - gapTotal) / report.cost : 0
        var groupTop: [String: Double] = [:]
        var y = top
        for (index, g) in paid.enumerated() {
            y += gap(before: index)
            groupTop[g.key] = y
            y += g.cost * dollarScale
        }
        if !free.isEmpty {
            let point = paid.isEmpty ? (top + bottom) / 2 : bottom
            freePoint = point
            for g in free { groupTop[g.key] = point }
        }

        // Left rail and ribbons.
        let harnessGap = Swift.min(8, span * 0.012)
        let tokenScale = Swift.max(0, span - harnessGap * Double(harnesses.count - 1)) / Double(Swift.max(1, report.counts.total))
        var left = top
        var rightUsed: [String: Double] = [:]
        var leftBands: [(HarnessStat, Double, Double)] = []
        let flowOrder = report.harnesses.flatMap(\.models).sorted {
            (groupRank[$0.info.group] ?? 0, harnessRank[$0.harness] ?? 0) < (groupRank[$1.info.group] ?? 0, harnessRank[$1.harness] ?? 0)
        }
        var rightTops: [String: Double] = [:]
        for stat in flowOrder {
            let used = rightUsed[stat.info.group, default: 0]
            rightTops[stat.id] = (groupTop[stat.info.group] ?? top) + used
            rightUsed[stat.info.group] = used + stat.cost * dollarScale
        }
        for h in harnesses {
            let start = left
            for stat in h.models.sorted(by: { (groupRank[$0.info.group] ?? 0) < (groupRank[$1.info.group] ?? 0) }) {
                let height = Double(stat.tokens) * tokenScale
                ribbons.append(Ribbon(stat: stat, group: stat.info.group, tone: groupTone[stat.info.group] ?? 0,
                                      leftTop: left, leftHeight: height,
                                      rightTop: rightTops[stat.id] ?? top, rightHeight: stat.cost * dollarScale,
                                      leftShares: Self.shares(stat.counts), rightShares: Self.shares(stat.parts)))
                left += height
            }
            leftBands.append((h, start, left - start))
            left += harnessGap
        }

        // Labels.
        let total = Double(report.counts.total)
        leftLabels = leftBands.map { band in
            let (h, start, height) = band
            return Label(selection: .harness(h.harness), title: h.harness.name, value: UsageText.compact(h.tokens),
                         extra: UsageText.percent(Double(h.tokens), of: total), harness: h.harness,
                         anchor: start + height / 2, y: 0, strong: height >= labelGap * 2)
        }
        Self.spread(&leftLabels, gap: labelGap, top: top + 6, bottom: bottom - 6)

        // Only as many names as the rail has lines for; the cheapest of the rest join "N model daha".
        let lines = Int(Swift.max(0, span - 6) / labelGap) + 1
        let room = Swift.max(1, lines - 1 - (free.isEmpty ? 0 : 1))
        let keep = Set(paid.filter { $0.cost / report.cost >= namedShare }.sorted { $0.cost > $1.cost }.prefix(room).map(\.key))
        let named = paid.filter { keep.contains($0.key) }
        let rest = paid.filter { !keep.contains($0.key) }
        rightLabels = named.map { g in
            Label(selection: .model(g.key), title: g.name, value: UsageText.short(g.cost),
                  extra: nil, harness: g.mainHarness,
                  anchor: (groupTop[g.key] ?? top) + g.cost * dollarScale / 2, y: 0, strong: false)
        }
        if !rest.isEmpty {
            let title = UsageText.moreModels(rest.count)
            let sum = rest.reduce(0) { $0 + $1.cost }
            rightLabels.append(Label(selection: .list(UsageText.smallModelsTitle, rest.map(\.key)), title: title, value: UsageText.short(sum),
                                     extra: nil, harness: nil, anchor: bottom - freeGap - 2, y: 0, strong: false))
        }
        if !free.isEmpty {
            // Stops at the limit: two models of a damaged log can each hold Int64.max / 4 times four.
            let freeTokens = free.reduce(Int64(0)) { TokenCounts.saturatingSum($0, $1.tokens) }
            freeShare = total > 0 ? Double(freeTokens) / total : 0
            rightLabels.append(Label(selection: .list(UsageText.unpricedModelsTitle, free.map(\.key)),
                                     title: Self.zeroCostTitle(free: free.map(\.key), unpriced: Set(report.unpriced.map(\.group))), value: "$0",
                                     extra: UsageText.compact(freeTokens), harness: nil, anchor: freePoint ?? bottom, y: 0, strong: false))
        }
        Self.spread(&rightLabels, gap: labelGap, top: top + 6, bottom: bottom)
    }

    /// The $0 point holds models with no price and models priced at $0 on purpose (a local model with no cloud
    /// counterpart). Call them "unpriced" only when every one of them is; otherwise the label says both.
    public static func zeroCostTitle(free: [String], unpriced: Set<String>) -> String {
        free.allSatisfy(unpriced.contains) ? UsageText.unpricedCount(free.count) : UsageText.freeOrUnpricedCount(free.count)
    }

    /// Each kind's share of a whole, in `TokenKind.allCases` order.
    private static func shares(_ counts: TokenCounts) -> [Double] {
        guard counts.total > 0 else { return TokenKind.allCases.map { _ in 0 } }
        return TokenKind.allCases.map { Double(counts[$0]) / Double(counts.total) }
    }

    private static func shares(_ parts: CostParts) -> [Double] {
        guard parts.total > 0 else { return TokenKind.allCases.map { _ in 0 } }
        return TokenKind.allCases.map { parts[$0] / parts.total }
    }

    /// Puts each label at its band, pushing down then up just enough that none overlap.
    private static func spread(_ labels: inout [Label], gap: Double, top: Double, bottom: Double) {
        var previous = top - gap
        func height(_ label: Label) -> Double { label.strong ? gap * 2 : gap }
        for i in labels.indices {
            labels[i].y = Swift.max(labels[i].anchor, previous + height(labels[i]) / 2 + (i > 0 ? height(labels[i - 1]) / 2 : gap / 2))
            previous = labels[i].y
        }
        var next = bottom + gap
        for i in labels.indices.reversed() {
            let room = i < labels.count - 1 ? height(labels[i]) / 2 + height(labels[i + 1]) / 2 : 0
            labels[i].y = Swift.min(labels[i].y, i < labels.count - 1 ? next - room : bottom)
            next = labels[i].y
        }
    }

    /// How far from the left end to the right end the curves have moved at `x`, 0...1.
    private func progress(at x: Double) -> Double {
        let u = Swift.max(0, Swift.min(1, (x - leftX) / Swift.max(1, rightX - leftX)))
        // The curve's x runs as 1.5t - 1.5t² + t³ of the span; solve it for t by halving.
        var low = 0.0, high = 1.0
        for _ in 0..<18 {
            let t = (low + high) / 2
            if 1.5 * t - 1.5 * t * t + t * t * t < u { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * t * t - 2 * t * t * t
    }

    /// Top and bottom edge of a ribbon or strand at horizontal position `x`.
    public func edges(_ flow: some FlowShape, at x: Double) -> (top: Double, bottom: Double) {
        let v = progress(at: x)
        let upper = flow.leftTop + (flow.rightTop - flow.leftTop) * v
        let lower = flow.leftTop + flow.leftHeight + (flow.rightTop + flow.rightHeight - flow.leftTop - flow.leftHeight) * v
        return (upper, lower)
    }

    /// The token kind under a point on a ribbon, when the ribbon shows its kinds.
    public func strand(x: Double, y: Double, flowID: String) -> TokenKind? {
        ribbons.first { $0.id == flowID }?.strands.first {
            let e = edges($0, at: x)
            return y >= e.top && y <= e.bottom
        }?.kind
    }

    /// This picture `p` of the way from `old`. Ribbons that are new grow from nothing where they
    /// will sit; those that are gone shrink away where they sat.
    public func morphed(from old: RibbonLayout, progress p: Double) -> RibbonLayout {
        guard p < 1 else { return self }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        let before = Dictionary(old.ribbons.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = self
        out.ribbons = ribbons.map { new in
            var r = new
            guard let was = before[new.id] else {
                r.leftHeight *= p
                r.rightHeight *= p
                return r
            }
            r.leftTop = mix(was.leftTop, new.leftTop)
            r.leftHeight = mix(was.leftHeight, new.leftHeight)
            r.rightTop = mix(was.rightTop, new.rightTop)
            r.rightHeight = mix(was.rightHeight, new.rightHeight)
            r.leftShares = zip(was.leftShares, new.leftShares).map(mix)
            r.rightShares = zip(was.rightShares, new.rightShares).map(mix)
            return r
        }
        let kept = Set(ribbons.map(\.id))
        out.ribbons += old.ribbons.filter { !kept.contains($0.id) }.map { was in
            var r = was
            r.leftHeight *= 1 - p
            r.rightHeight *= 1 - p
            return r
        }
        return out
    }

    /// What sits under a point: a label, the thinnest ribbon there, or the header.
    public func hit(x: Double, y: Double) -> UsageSelection? {
        func nearest(_ labels: [Label]) -> UsageSelection? {
            guard let best = labels.min(by: { abs($0.y - y) < abs($1.y - y) }), abs(best.y - y) <= 12 else { return nil }
            return best.selection
        }
        if y < top { return .total }
        if x < leftX - 6 { return nearest(leftLabels) }
        if x > rightX + 6 { return nearest(rightLabels) }
        var best: (selection: UsageSelection, height: Double)?
        for r in ribbons {
            let e = edges(r, at: x)
            let slack = 1.5
            guard y >= e.top - slack, y <= e.bottom + slack else { continue }
            if best == nil || e.bottom - e.top < best!.height { best = (.flow(r.stat.id), e.bottom - e.top) }
        }
        return best?.selection
    }
}
