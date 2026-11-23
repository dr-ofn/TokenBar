import LocalCore

/// One tool the scan found on this Mac, and what the picture can say about it.
public struct DetectedTool: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Logged calls: all-time tokens and calls.
        case used(tokens: Int64, calls: Int)
        /// Its data folder exists but nothing was logged yet.
        case notYet
        /// Its token data is not stored on this Mac.
        case notCountable
    }

    public var harness: HarnessID
    public var state: State
    public var id: String { harness.rawValue }

    /// "Cursor · token verisi yerelde yok".
    public var line: String { harness.name + " · " + status }

    public var status: String {
        switch state {
        case .used(let tokens, let calls): return UsageText.tokens(tokens) + UsageText.tokenWord + " · " + UsageText.calls(calls)
        case .notYet: return L10n.t("henüz kullanım yok", "no usage yet")
        case .notCountable: return L10n.t("token verisi yerelde yok", "token data is not stored locally")
        }
    }
}

public enum DetectedTools {
    /// Tools with data first (most tokens first), then the ones with a folder and no calls, then the ones whose
    /// tokens cannot be counted here. `report` is the all-time report, so the list does not change with the period.
    public static func list(detected: [HarnessID], notCountable: [HarnessID], report: UsageReport?) -> [DetectedTool] {
        var used: [DetectedTool] = [], idle: [DetectedTool] = [], blind: [DetectedTool] = []
        var seen = Set<HarnessID>()
        for harness in detected + notCountable where seen.insert(harness).inserted {
            if let stat = report?.harnesses.first(where: { $0.harness == harness }), stat.calls > 0 || stat.tokens > 0 {
                used.append(DetectedTool(harness: harness, state: .used(tokens: stat.tokens, calls: stat.calls)))
            } else if notCountable.contains(harness) {
                blind.append(DetectedTool(harness: harness, state: .notCountable))
            } else {
                idle.append(DetectedTool(harness: harness, state: .notYet))
            }
        }
        used.sort { lhs, rhs in
            guard case .used(let a, _) = lhs.state, case .used(let b, _) = rhs.state else { return false }
            return a != b ? a > b : lhs.id < rhs.id
        }
        return used + idle + blind
    }

    /// "Algılanan: 5 araç", "Detected: 5 tools".
    public static func summary(_ count: Int) -> String {
        L10n.t("Algılanan: \(count) araç", "Detected: \(count) " + (count == 1 ? "tool" : "tools"))
    }

    public static var title: String { L10n.t("Algılanan araçlar", "Detected tools") }
    public static var footnote: String {
        L10n.t("Veri klasörü bu Mac'te bulunan araçlar. Sayılar tüm zamanları gösterir.",
               "Tools whose data folder exists on this Mac. Numbers cover all time.")
    }
    public static var help: String { L10n.t("Algılanan araçların listesi", "List of the detected tools") }
}
