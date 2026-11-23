import Foundation

/// The two languages of the interface.
public enum Lang: String, Sendable {
    case tr, en
}

/// Interface language and the numbers and dates written in it.
///
/// The language is Turkish when the system's first preferred language is Turkish and English otherwise;
/// `TOKENBAR_LANG=en|tr` overrides it (the snapshot tool and the videos use that). Every sentence of the
/// interface sits next to its twin at the place that uses it: `L10n.t("Giriş", "Input")`. A table file would
/// need a bundle, and a SwiftPM tool without Xcode has none.
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var forced: Lang?
    nonisolated(unsafe) private static var detected: Lang?

    /// The language in use right now.
    public static var lang: Lang {
        lock.withLock {
            if let forced { return forced }
            if let detected { return detected }
            let found = detect(environment: ProcessInfo.processInfo.environment, preferred: Locale.preferredLanguages)
            detected = found
            return found
        }
    }

    /// Pins the language (tests, tools); `nil` goes back to the environment and the system.
    public static func setLanguage(_ language: Lang?) {
        lock.withLock { forced = language }
    }

    /// `TOKENBAR_LANG` first ("en", "tr", "tr_TR", "en-US"), then the first system language.
    public static func detect(environment: [String: String], preferred: [String]) -> Lang {
        if let value = environment["TOKENBAR_LANG"]?.lowercased().trimmingCharacters(in: .whitespaces) {
            if value.hasPrefix("tr") { return .tr }
            if value.hasPrefix("en") { return .en }
        }
        return preferred.first?.lowercased().hasPrefix("tr") == true ? .tr : .en
    }

    /// The Turkish sentence or its English twin.
    public static func t(_ tr: String, _ en: String) -> String { lang == .tr ? tr : en }

    /// "1 call", "2 calls"; Turkish does not pluralise after a number.
    public static func plural(_ n: Int, tr: String, one: String, many: String) -> String {
        lang == .tr ? tr : (n == 1 ? one : many)
    }

    /// Number and date conventions: tr 1.234,5 and "23 Kas"; en 1,234.5 and "Nov 23".
    public static var locale: Locale { Locale(identifier: lang == .tr ? "tr_TR" : "en_US") }
}
