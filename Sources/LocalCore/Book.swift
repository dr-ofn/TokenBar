import Foundation

/// The six periods of one load, all computed from a single pass over the rows.
public struct UsageBook: Sendable {
    private var reports: [Period: UsageReport]

    init(reports: [Period: UsageReport]) { self.reports = reports }

    /// A period other than `all` counts the calls from its start up to this many seconds after now: a clock that runs a
    /// little fast still counts, a call dated years ahead (a corrupt log, a wrong date) does not land in every period.
    /// `all` counts every call. The same rule, and the same number, as the Windows app (store.py).
    public static let futureSlackSeconds: Double = 86400

    public func report(for period: Period) -> UsageReport {
        reports[period] ?? UsageReport(period: period, stats: [])
    }
}

/// When a period's tokens and dollars were used: equal buckets, the last one holding now, per model.
public struct Tide: Sendable {
    public var start: Double
    /// Seconds in one bucket.
    public var size: Double
    public var count: Int
    /// Keyed by `ModelStat.id`; every array has `count` entries, oldest first.
    public var tokens: [String: [Int64]] = [:]
    public var dollars: [String: [Double]] = [:]
}

/// Where a period's buckets fall.
private struct Grid {
    var start: Double
    var size: Double
    var count: Int

    init(period: Period, now: Double, earliest: Double?) {
        let buckets: Int
        switch period {
        case .oneHour: (size, buckets) = (60, 60)
        case .fiveHours: (size, buckets) = (300, 60)
        case .day: (size, buckets) = (900, 96)
        case .week: (size, buckets) = (7200, 84)
        case .month: (size, buckets) = (21600, 120)
        case .all:
            let span = Swift.max(0, now - (earliest ?? now))
            size = 86400 * Swift.max(1, (span / 180 / 86400).rounded(.up))
            buckets = Swift.max(1, Int((span / size).rounded(.up)))
        }
        // Edges on whole multiples of the size: counted back from now, every reload would cut
        // the calls differently and the peaks would jump. One bucket more, so the period's
        // oldest moment has its own; the first and the last bucket are partial.
        count = buckets + 1
        start = ((now / size).rounded(.up) - Double(count)) * size
    }

    /// A row with no real time belongs to the period but to no moment in it.
    func index(_ time: Double) -> Int? {
        guard time > 0 else { return nil }
        // Clamped before converting: a corrupt timestamp must not trap in Int().
        return Int(Swift.min(Double(count - 1), Swift.max(0, (time - start) / size)))
    }
}

/// Collects the store's rows into a book.
struct UsageBookBuilder {
    private struct Key: Hashable {
        var harness: HarnessID
        var model: String
    }

    /// One model inside one harness, in one period.
    private struct Line {
        var stat: ModelStat
        var tokens: [Int64]
        var dollars: [Double]

        init(stat: ModelStat, buckets: Int) {
            self.stat = stat
            tokens = [Int64](repeating: 0, count: buckets)
            dollars = [Double](repeating: 0, count: buckets)
        }

        mutating func add(_ counts: TokenCounts, _ parts: CostParts, isCall: Bool, bucket: Int?) {
            stat.counts += counts
            stat.parts += parts
            stat.cost += parts.total
            if isCall { stat.calls += 1 }
            if let bucket {
                tokens[bucket] = TokenCounts.saturatingSum(tokens[bucket], counts.total)
                dollars[bucket] += parts.total
            }
        }
    }

    private struct Sheet {
        var period: Period
        var since: Double
        /// The latest time the period counts; every time for `all`.
        var until: Double
        var grid: Grid
        var lines: [Key: Line] = [:]
    }

    private var sheets: [Sheet]
    private var prices: [String: ModelInfo] = [:]
    private var harnesses: [String: HarnessID] = [:]

    init(now: Double, earliest: Double?) {
        sheets = Period.allCases.map { period in
            Sheet(period: period, since: period.seconds.map { now - $0 } ?? -.infinity,
                  until: period.seconds == nil ? .infinity : now + UsageBook.futureSlackSeconds,
                  grid: Grid(period: period, now: now, earliest: earliest))
        }
    }

    /// Adjustment rows sum many calls, so they take the base price and count no call of their own.
    mutating func add(prefix: String, isAdjustment: Bool, provider: String, model: String, time: Double, tokens: TokenCounts) {
        let harness: HarnessID
        if let known = harnesses[prefix] {
            harness = known
        } else if let found = HarnessID(keyPrefix: Substring(prefix)) {
            harnesses[prefix] = found
            harness = found
        } else {
            return
        }
        let id = provider + "/" + model
        let info = prices[id] ?? ModelInfo(provider: provider, model: model, price: ModelPrice(model: model, provider: provider))
        prices[id] = info
        let parts = isAdjustment ? info.price.baseParts(tokens) : info.price.parts(tokens)
        let key = Key(harness: harness, model: id)
        for index in sheets.indices where time >= sheets[index].since && time <= sheets[index].until {
            let grid = sheets[index].grid
            // Added in place: copying a line's bucket arrays for every row would slow a load.
            sheets[index].lines[key, default: Line(stat: ModelStat(harness: harness, info: info), buckets: grid.count)]
                .add(tokens, parts, isCall: !isAdjustment, bucket: grid.index(time))
        }
    }

    func book() -> UsageBook {
        var reports: [Period: UsageReport] = [:]
        for sheet in sheets {
            var tide = Tide(start: sheet.grid.start, size: sheet.grid.size, count: sheet.grid.count)
            for line in sheet.lines.values {
                tide.tokens[line.stat.id] = line.tokens
                tide.dollars[line.stat.id] = line.dollars
            }
            reports[sheet.period] = UsageReport(period: sheet.period, stats: sheet.lines.values.map(\.stat), tide: tide)
        }
        return UsageBook(reports: reports)
    }
}
