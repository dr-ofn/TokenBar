import Foundation

/// Token categories of one model call. The fields are disjoint, so `total` is a plain sum
/// of the counts, each held to `0...fieldLimit`: a negative or absurd count in a log or in the
/// index is a corrupt row, and it must not trap the arithmetic that reads it.
/// - `input`: fresh (uncached) input tokens
/// - `cacheRead`: tokens served from the prompt cache
/// - `cacheWrite`: tokens written into the prompt cache
/// - `output`: generated tokens, reasoning included
/// - `reasoning`: the reasoning share of `output` (informational, already inside `output`)
/// - `cacheWrite1h`: the one-hour share of `cacheWrite`, which has its own price
public struct TokenCounts: Equatable, Sendable {
    public var input: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var output: Int64
    public var reasoning: Int64
    public var cacheWrite1h: Int64

    public init(input: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0,
                cacheWrite1h: Int64 = 0) {
        // Held on the way in: a negative or absurd count from a log is a corrupt row, and every field
        // read later (a price, a sum, a difference) can then count on `0...fieldLimit`.
        self.input = Safe.count(input)
        self.cacheRead = Safe.count(cacheRead)
        self.cacheWrite = Safe.count(cacheWrite)
        self.output = Safe.count(output)
        self.reasoning = Safe.count(reasoning)
        self.cacheWrite1h = Safe.count(cacheWrite1h)
    }

    /// The largest count one field holds. Four of them still add up inside `Int64`.
    public static let fieldLimit = Int64.max / 4

    private static func held(_ count: Int64) -> Int64 { Safe.count(count) }

    /// Every token the call touched.
    public var total: Int64 { Self.held(input) + Self.held(cacheRead) + Self.held(cacheWrite) + Self.held(output) }
    /// Tokens the model read as prompt (fresh + cached + written).
    public var promptTotal: Int64 { Self.held(input) + Self.held(cacheRead) + Self.held(cacheWrite) }
    public var isZero: Bool { total == 0 }

    /// Share of prompt tokens served from cache (0...1).
    public var cacheHitRate: Double {
        let p = promptTotal
        return p > 0 ? Double(cacheRead) / Double(p) : 0
    }

    public static func += (a: inout TokenCounts, b: TokenCounts) {
        // Both sides are held first, so the sum cannot overflow; it stops at the limit.
        func add(_ x: Int64, _ y: Int64) -> Int64 { held(held(x) + held(y)) }
        a.input = add(a.input, b.input)
        a.cacheRead = add(a.cacheRead, b.cacheRead)
        a.cacheWrite = add(a.cacheWrite, b.cacheWrite)
        a.output = add(a.output, b.output)
        a.reasoning = add(a.reasoning, b.reasoning)
        a.cacheWrite1h = add(a.cacheWrite1h, b.cacheWrite1h)
    }

    /// `a + b` that stops at `Int64.max` instead of trapping, for running totals of totals.
    public static func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b < 0 ? .min : .max) : sum
    }
}

/// The four disjoint kinds a token can be, in the order the ribbons stack them, top to bottom.
public enum TokenKind: CaseIterable, Sendable {
    case cacheRead, input, cacheWrite, output
}

extension TokenCounts {
    public subscript(kind: TokenKind) -> Int64 {
        switch kind {
        case .cacheRead: return cacheRead
        case .input: return input
        case .cacheWrite: return cacheWrite
        case .output: return output
        }
    }
}

/// One model call from any harness log.
public struct UsageEvent: Sendable {
    /// Every prefix that can hold the rows a prefix made from a raw id stands for (`cline:<task>:`, `devin:<session>:db:`): its
    /// `adj#gercek` form and, when that differs, the prefix itself, for the rows a 9.0.5 index wrote under the raw id. Never for
    /// the adjustment prefixes (`cc:adj:`, `qwen:adj:`, `zed:adj:`), which are fixed names.
    public static func realPrefixes(_ prefix: String) -> [String] {
        let real = realKey(prefix)
        return real == prefix ? [prefix] : [real, prefix]
    }

    /// The key of a real (not adjustment) event: a second component of exactly `adj` becomes `adj#gercek`.
    public static func realKey(_ key: String) -> String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        let rest = key[key.index(after: colon)...]
        let second = rest.firstIndex(of: ":").map { rest[..<$0] } ?? rest
        guard second == "adj" else { return key }
        return String(key[...colon]) + "adj#gercek" + rest.dropFirst(3)
    }

    public var key: String        // stable dedup key; its prefix names the harness
    public var provider: String   // e.g. "anthropic"
    public var model: String      // as the log names it
    public var timestamp: Double  // unix seconds
    public var tokens: TokenCounts
    public var session: String
    public var project: String?
    public var file: String

    /// `adjustment` is true only for the rows that top a cumulative figure up (`cc:adj:...`, `qwen:adj:...`, `zed:adj:...`).
    /// A real call whose second key component is exactly `adj` (a Claude message id, a Cline task id) is stored as
    /// `adj#gercek`, so it is never taken for an adjustment row.
    public init(key: String, provider: String, model: String, timestamp: Double, tokens: TokenCounts,
                session: String, project: String? = nil, file: String, adjustment: Bool = false) {
        self.key = adjustment ? key : Self.realKey(key)
        self.provider = provider
        self.model = model
        self.timestamp = timestamp
        self.tokens = tokens
        self.session = session
        self.project = project
        self.file = file
    }
}

/// Reporting windows (named `Period`, not `Window`, to avoid clashing with SwiftUI's
/// `Window` scene type inside the app targets).
public enum Period: String, CaseIterable, Codable, Sendable {
    case oneHour = "1h"
    case fiveHours = "5h"
    case day = "24h"
    case week = "7d"
    case month = "30d"
    case all = "all"

    public var seconds: Double? {
        switch self {
        case .oneHour: return 3600
        case .fiveHours: return 5 * 3600
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        case .all: return nil
        }
    }

    public var label: String {
        switch self {
        case .oneHour: return L10n.t("1 saat", "1 hour")
        case .fiveHours: return L10n.t("5 saat", "5 hours")
        case .day: return L10n.t("24 saat", "24 hours")
        case .week: return L10n.t("7 gün", "7 days")
        case .month: return L10n.t("30 gün", "30 days")
        case .all: return L10n.t("Tümü", "All time")
        }
    }
}
