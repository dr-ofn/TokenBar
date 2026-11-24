import Foundation
import LocalCore

/// Persisted user settings.
public struct Preferences: Equatable, Codable {
    public var window: Period = .week
    /// No network at all, the price catalogues included (same effect as `TOKENBAR_OFFLINE=1`).
    public var offline = false

    static let defaultsKey = "tokenbar.prefs.v2"

    public init() {}

    /// A saved copy from before a setting existed has no key for it: that setting keeps its default. A value this version
    /// does not understand (a period a newer or older version wrote, a wrong type) is one setting back to its default, not
    /// all of them: the others are read as they were.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = ((try? c.decodeIfPresent(Period.self, forKey: .window)) ?? nil) ?? .week
        offline = ((try? c.decodeIfPresent(Bool.self, forKey: .offline)) ?? nil) ?? false
    }

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
