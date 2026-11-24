import Foundation

/// The user's own price names, from `~/.config/tokenbar/model-aliases.json`:
///
///     {
///       "aliases": {
///         "my-qwen-q4": "qwen3.8-27b",                       price it like this model
///         "sidecar": {"as": "claude-haiku-5-5"},             the same, spelled out
///         "house-model": {"input": 1, "output": 4},          USD per 1M tokens (cacheRead, cacheWrite, name optional)
///         "home-7b": {"input": 0.1, "output": 0.3, "kind": "near",
///                     "source": "OpenRouter en yakın: acme/small (why)"},   optional note, and "near"/"other" mark the row
///                                                                           as a stand-in or a price published elsewhere
///         "test-server": {"free": true}                      no cost
///       },
///       "localProviders": ["my-mac-mini", "studio"]          servers that run models on your own machines
///     }
///
/// An alias wins over every table and catalogue. The file may also be the aliases alone (no "aliases" key).
public struct UserAliases: Sendable {
    public enum Target: Sendable, Equatable {
        case model(String)
        /// A cache price left out is nil (it costs what input costs); one written as 0 is 0, a free cache.
        case rates(input: Double, output: Double, cacheRead: Double?, cacheWrite: Double?, name: String?, source: String?, kind: PriceKind)
        case free
    }

    /// Keyed by `ModelKeys.key1` of the alias name.
    public var targets: [String: Target] = [:]
    /// Provider names in `ModelNames.providerKey` spelling.
    public var localProviders: Set<String> = []

    /// Why the file is not in use when it is there and cannot be read (not JSON, not an object, no permission), in the
    /// interface language; nil when it is fine, missing or has no bytes. Said as a scan issue, never skipped.
    public var issue: String?

    /// The file's name, as the scan issue names it.
    public static let fileName = "model-aliases.json"

    public static let empty = UserAliases()

    public init() {}

    public static var defaultPath: String { path(home: NSHomeDirectory()) }

    /// The alias file of a home folder (`tokenbar-cli --home DIR` reads DIR's, like it reads DIR's custom sources).
    public static func path(home: String) -> String { home + "/.config/tokenbar/model-aliases.json" }

    /// The file's aliases. A file that is not there, or has no bytes, is no aliases and no problem. One that is there and
    /// cannot be used (no permission, not JSON, not an object) is no aliases either, and `issue` says so (as on Windows).
    public static func load(path: String = defaultPath) -> UserAliases {
        guard let data = FileManager.default.contents(atPath: path) else {
            var unread = UserAliases()
            if FileManager.default.fileExists(atPath: path) {
                unread.issue = L10n.t("dosya okunamadı; takma adlar kullanılmadı", "the file could not be read; the aliases are not used")
            }
            return unread
        }
        return UserAliases(json: data)
    }

    public init(json data: Data) {
        // Fragments are read too, to tell a file that is not JSON from one that is JSON but not an object; `null` says nothing.
        let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = parsed as? [String: Any] else {
            if !data.isEmpty && !(parsed is NSNull) {
                issue = L10n.t("geçerli bir JSON nesnesi değil; takma adlar kullanılmadı", "not a valid JSON object; the aliases are not used")
            }
            return
        }
        let aliases = (root["aliases"] as? [String: Any]) ?? (root["localProviders"] != nil ? [:] : root)
        // Names that fold to one key ("My-Model", "my_model"): the last one in the file wins, as on Windows. A dictionary
        // has no order, so the text is asked for it; without one (it cannot be scanned) the names go in sorted order.
        let written = JSONKeyOrder.keys(of: data, member: root["aliases"] is [String: Any] ? "aliases" : nil)
        let seen = Set(written)
        let order = written.filter { aliases[$0] != nil } + aliases.keys.filter { !seen.contains($0) }.sorted()
        for name in order {
            if let value = aliases[name], let target = Self.target(value) { targets[ModelNames.keys(name).key1] = target }
        }
        // One item that is not a string is dropped alone (the same as on Windows), not the whole list with it.
        for case let provider as String in (root["localProviders"] as? [Any]) ?? [] { localProviders.insert(ModelNames.providerKey(provider)) }
    }

    static func target(_ value: Any) -> Target? {
        if let s = value as? String { return s.isEmpty ? nil : .model(s) }
        guard let d = value as? [String: Any] else { return nil }
        if d["free"] as? Bool == true { return .free }
        if let s = d["as"] as? String, !s.isEmpty { return .model(s) }
        let input = PriceParsers.number(d["input"]), output = PriceParsers.number(d["output"])
        let cacheRead = PriceParsers.number(d["cacheRead"]), cacheWrite = PriceParsers.number(d["cacheWrite"])
        // The same bound a catalogue row has to meet: a hand-written 1e308 would turn into an `Infinity` cost, a
        // negative cache price into a negative one. An entry that breaks it is no entry (a broken line, not a crash).
        guard input > 0, output > 0, [input, output, cacheRead, cacheWrite].allSatisfy(PriceLimits.isRate) else { return nil }
        // 0 is a price (a free cache); only a key that is not there leaves the cache priced like input.
        func given(_ key: String, _ value: Double) -> Double? { d[key] is NSNumber || d[key] is String ? value : nil }
        let source = (d["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let kind: PriceKind = d["kind"] as? String == "near" ? .near : d["kind"] as? String == "other" ? .other : .alias
        return .rates(input: input, output: output, cacheRead: given("cacheRead", cacheRead),
                      cacheWrite: given("cacheWrite", cacheWrite), name: d["name"] as? String, source: source, kind: kind)
    }
}
