import Foundation

/// Number conversions for logs and catalogues that someone else wrote. A corrupt or hostile file can hold `1e20`,
/// `NaN`-like values, `-5` where a count belongs or an `Int64.max` that overflows the first sum it meets: none of
/// them may trap. Every `Double` to integer conversion in the readers goes through here.
enum Safe {
    /// `d` as an `Int64`, or nil when it is NaN, infinite or outside the `Int64` range. Fractions are cut off.
    static func int64(_ d: Double) -> Int64? {
        guard d.isFinite, d >= Double(Int64.min), d < Double(Int64.max) else { return nil }
        return Int64(d)
    }

    /// `d` as an `Int64` no larger than `limit` in size (negative sizes are 0), or nil when it is not a finite number
    /// that fits. For sizes and thresholds: a value over the limit is a corrupt one, not a very large one.
    static func size(_ d: Double, limit: Int64) -> Int64? {
        guard let n = int64(d), n >= 0, n <= limit else { return nil }
        return n
    }

    /// A token count held to `0...TokenCounts.fieldLimit`.
    static func count(_ n: Int64) -> Int64 { min(max(n, 0), TokenCounts.fieldLimit) }

    /// Whole seconds of a timestamp for use in a dedup key, nil when the time is not a number that fits.
    static func seconds(_ time: Double) -> Int64? { int64(time.rounded(.down)) }
}
