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

    public static let empty = UserAliases()

    public init() {}

    public static var defaultPath: String { path(home: NSHomeDirectory()) }

    /// The alias file of a home folder (`tokenbar-cli --home DIR` reads DIR's, like it reads DIR's custom sources).
    public static func path(home: String) -> String { home + "/.config/tokenbar/model-aliases.json" }

    /// The file's aliases; an unreadable, missing or foreign file is no aliases, never an error.
    public static func load(path: String = defaultPath) -> UserAliases {
        guard let data = FileManager.default.contents(atPath: path) else { return .empty }
        return UserAliases(json: data)
    }

    public init(json data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let aliases = (root["aliases"] as? [String: Any]) ?? (root["localProviders"] != nil ? [:] : root)
        for (name, value) in aliases {
            if let target = Self.target(value) { targets[ModelNames.keys(name).key1] = target }
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
