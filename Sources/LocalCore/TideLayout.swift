import CoreGraphics
import Foundation

/// When the period's tokens and dollars were used, as a stream: tokens rise above a midline and
/// dollars hang below it, stacked by harness in the order the ribbons stand. Each side is linear
/// on its own scale, taken from the whole period so that focusing never rescales the picture.
public struct TideLayout: Sendable {
    /// One harness's share of every bucket, as y positions, oldest bucket first.
    public struct Band: Sendable, Identifiable {
        public var harness: HarnessID
        public var tokenOuter: [Double]
        public var tokenInner: [Double]
        public var dollarInner: [Double]
        public var dollarOuter: [Double]
        public var id: String { harness.rawValue }
    }

    /// One piece of a smooth edge, starting where the previous one ended.
    public struct Segment: Sendable {
        public var control1: CGPoint
        public var control2: CGPoint
        public var end: CGPoint
    }

    public var width: Double
    public var midline: Double
    /// One x per bucket.
    public var xs: [Double] = []
    public var bands: [Band] = []
    /// The part of `bands` that matches the focus, stacked from the midline; empty without one.
    public var focused: [Band] = []
    /// Every bucket's totals, whatever the focus.
    public var tokens: [Int64]
    public var dollars: [Double]
    public var peakTokens: Int64
    public var peakDollars: Double
    public var start: Double
    public var bucketSize: Double

    /// Nil when the period has no buckets or no calls.
    public init?(report: UsageReport, width: Double, height: Double, focus: UsageSelection? = nil) {
        guard let tide = report.tide, tide.count >= 1, !report.isEmpty else { return nil }
        // A picture with no room, or a NaN from a layout pass, is a flat one: never a NaN coordinate.
        let width = width.isFinite ? Swift.max(0, width) : 0
        let height = height.isFinite ? Swift.max(0, height) : 0
        self.width = width
        midline = height / 2
        start = tide.start
        bucketSize = tide.size
        // One bucket has no span to spread over: it sits at the left edge.
        xs = (0..<tide.count).map { tide.count > 1 ? Double($0) / Double(tide.count - 1) * width : 0 }
        tokens = [Int64](repeating: 0, count: tide.count)
        dollars = [Double](repeating: 0, count: tide.count)

        let order = report.harnesses.sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
        for model in order.flatMap(\.models) {
            for i in 0..<tide.count {
                tokens[i] = TokenCounts.saturatingSum(tokens[i], tide.tokens[model.id]?[i] ?? 0)
                dollars[i] += tide.dollars[model.id]?[i] ?? 0
            }
        }
        peakTokens = tokens.max() ?? 0
        peakDollars = dollars.max() ?? 0

        let reach = Swift.max(0, midline - 1)
        let tokenScale = peakTokens > 0 ? reach / Double(peakTokens) : 0
        let dollarScale = peakDollars > 0 ? reach / peakDollars : 0
        let midline = self.midline

        func stack(_ keep: (ModelStat) -> Bool) -> [Band] {
            var above = [Double](repeating: 0, count: tide.count)
            var below = [Double](repeating: 0, count: tide.count)
            var out: [Band] = []
            for harness in order {
                let models = harness.models.filter(keep)
                guard !models.isEmpty else { continue }
                var band = Band(harness: harness.harness, tokenOuter: [], tokenInner: [], dollarInner: [], dollarOuter: [])
                for i in 0..<tide.count {
                    let up = models.reduce(0.0) { $0 + Double(tide.tokens[$1.id]?[i] ?? 0) } * tokenScale
                    let down = models.reduce(0.0) { $0 + (tide.dollars[$1.id]?[i] ?? 0) } * dollarScale
                    band.tokenInner.append(midline - above[i])
                    band.tokenOuter.append(midline - above[i] - up)
                    band.dollarInner.append(midline + below[i])
                    band.dollarOuter.append(midline + below[i] + down)
                    above[i] += up
                    below[i] += down
                }
                out.append(band)
            }
            return out
        }

        bands = stack { _ in true }
        if let focus, focus != .total { focused = stack(focus.contains) }
    }

    /// The bucket nearest to a horizontal position.
    public func bucket(atX x: Double) -> Int {
        guard xs.count > 1 else { return 0 }
        // Clamped before converting: NaN, infinity or a huge x must not trap in Int().
        guard x.isFinite else { return x > 0 ? xs.count - 1 : 0 }
        let step = width / Double(xs.count - 1)
        let position = step > 1e-9 ? x / step : 0
        return Int(Swift.min(Double(xs.count - 1), Swift.max(0, position.rounded())))
    }

    /// A smooth line through every bucket that never overshoots between them (a monotone cubic
    /// with harmonic-mean tangents), as Bézier pieces.
    public func segments(_ ys: [Double]) -> [Segment] {
        guard ys.count >= 2, ys.count == xs.count else { return [] }
        let step = xs[1] - xs[0]
        // Buckets stacked on one x (no width) have no slope to follow.
        let slopes = zip(ys, ys.dropFirst()).map { step > 1e-9 ? ($1 - $0) / step : 0 }
        var tangents = [Double](repeating: 0, count: ys.count)
        tangents[0] = slopes[0]
        tangents[ys.count - 1] = slopes[slopes.count - 1]
        if ys.count > 2 {
            for i in 1..<(ys.count - 1) where slopes[i - 1] * slopes[i] > 0 {
                tangents[i] = 2 * slopes[i - 1] * slopes[i] / (slopes[i - 1] + slopes[i])
            }
        }
        let third = step / 3
        return (0..<(ys.count - 1)).map { (i: Int) -> Segment in
            let x0: Double = xs[i], x1: Double = xs[i + 1]
            let y0: Double = ys[i] + tangents[i] * third
            let y1: Double = ys[i + 1] - tangents[i + 1] * third
            return Segment(control1: CGPoint(x: x0 + third, y: y0),
                           control2: CGPoint(x: x1 - third, y: y1),
                           end: CGPoint(x: x1, y: ys[i + 1]))
        }
    }
}
