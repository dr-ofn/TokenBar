import Foundation

/// The `--json` text of `tokenbar-cli`. JSON cannot hold `Infinity` or `NaN`, and `JSONSerialization` answers one
/// with an Objective-C exception no `catch` can reach: every number that came out of a price sum goes through
/// `finite` first, and `serialize` refuses what is still not JSON instead of letting the writer abort.
public enum ReportJSON {
    /// A money figure JSON can hold: a number that is not finite (a price that overflowed the sum) is 0.
    public static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    /// The report as the dictionary `--json` prints.
    public static func object(_ report: UsageReport, window: Period, detected: [HarnessID]) -> [String: Any] {
        var harnesses: [String: Any] = [:]
        for h in report.harnesses {
            var models: [String: [Int64]] = [:]
            for m in h.models {
                models[m.info.id] = [m.tokens, Int64(m.calls), m.counts.input, m.counts.cacheRead, m.counts.cacheWrite,
                                     m.counts.output, m.counts.reasoning]
            }
            harnesses[h.harness.rawValue] = ["total": h.tokens, "calls": h.calls, "cost": finite(h.cost), "models": models] as [String: Any]
        }
        return ["window": window.rawValue, "total": report.counts.total, "calls": report.callCount,
                "cost": finite(report.cost), "unpriced": report.unpriced.map(\.id).sorted(), "harnesses": harnesses,
                "detected": detected.map(\.rawValue)]
    }

    /// Pretty, key-sorted JSON; a throw (never a trap) when the object holds something JSON cannot.
    public static func serialize(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw StoreError(message: L10n.t("rapor JSON olarak yazılamıyor (sonlu olmayan bir sayı)", "the report cannot be written as JSON (a number that is not finite)"))
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
