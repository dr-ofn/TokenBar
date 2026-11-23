import Foundation

/// Which tool logged a call: an open string, so a tool nobody listed still has a name and a colour.
/// The built-in tools have constants; everything else comes from `HarnessCatalog`.
public struct HarnessID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let claudeCode = HarnessID("claude-code")
    public static let codex = HarnessID("codex")
    public static let opencode = HarnessID("opencode")
    public static let ohMyPi = HarnessID("oh-my-pi")
    public static let qwenCode = HarnessID("qwen-code")
    public static let kimiCode = HarnessID("kimi-code")
    public static let devin = HarnessID("devin")
    public static let antigravity = HarnessID("antigravity")
    public static let crush = HarnessID("crush")
    public static let goose = HarnessID("goose")
    public static let factoryDroid = HarnessID("factory-droid")
    public static let amp = HarnessID("amp")
    public static let openHands = HarnessID("openhands")
    public static let warp = HarnessID("warp")
    public static let amazonQ = HarnessID("amazon-q")
    public static let geminiCLI = HarnessID("gemini-cli")
    public static let pi = HarnessID("pi")
    public static let copilotCLI = HarnessID("copilot-cli")
    public static let junie = HarnessID("junie")
    public static let codebuff = HarnessID("codebuff")
    public static let mistralVibe = HarnessID("mistral-vibe")
    public static let augment = HarnessID("augment")

    /// The name shown for the tool; the id itself when the catalog does not know it.
    public var name: String { HarnessRegistry.shared.name(of: self) }

    /// The tool's colour as a hue in degrees: the catalog's, else one derived from the id, so an
    /// unlisted tool keeps the same colour from run to run.
    public var hue: Double { HarnessRegistry.shared.hue(of: self) ?? Self.stableHue(rawValue) }

    /// The tool a dedup key belongs to, from the text before its first colon. A prefix no catalog
    /// entry claims names a tool of its own, so rows already in the index never disappear from
    /// the report. Nil only for an empty prefix.
    public init?(keyPrefix: Substring) {
        guard !keyPrefix.isEmpty else { return nil }
        self = HarnessRegistry.shared.id(forPrefix: String(keyPrefix)) ?? HarnessID(String(keyPrefix))
    }

    /// FNV-1a over the id's UTF-8 bytes, folded to a hue.
    public static func stableHue(_ id: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360)
    }
}

/// How a tool's files are laid out and read. One parser serves one family; a tool joins the
/// catalog by naming its family and where its files are.
public enum ParserFamily: String, CaseIterable, Sendable {
    case anthropicJSONL = "anthropic-jsonl"
    case codexRollout = "codex-rollout"
    case opencodeSQLite = "opencode-sqlite"
    case openDesignEvents = "open-design-events"
    case ompJSONL = "omp-jsonl"
    case qwenUsage = "qwen-usage"
    case kimiWire = "kimi-wire"
    case devinTranscripts = "devin-transcripts"
    case antigravitySQLite = "antigravity-sqlite"
    case crushSQLite = "crush-sqlite"
    case gooseSQLite = "goose-sqlite"
    case droidSettings = "droid-settings"
    case ampThreads = "amp-threads"
    case openhandsState = "openhands-state"
    /// A tool that is detected but logs no token counts on this Mac: it is named, never counted.
    case notCountable = "not-countable"
    case geminiChats = "gemini-chats"
    case piJSONL = "pi-jsonl"
    case copilotEvents = "copilot-events"
    case junieEvents = "junie-events"
    case codebuffChats = "codebuff-chats"
    case vibeSessions = "vibe-sessions"
    case augmentSessions = "augment-sessions"
    case qwenChats = "qwen-chats"
    /// Cline's `tasks/<id>/ui_messages.json` (`tokensIn` stays apart from the cache counts), plus
    /// Cline CLI's `sessions/<id>/<id>.messages.json`.
    case clineTasks = "cline-tasks"
    /// Roo Code and Kilo Code's `tasks/<id>/ui_messages.json`: Cline's layout, but `tokensIn` holds
    /// the cache counts too from November 2025 on.
    case rooTasks = "roo-tasks"
    /// VS Code Copilot Chat's `chatSessions/<id>.jsonl` (or `.json`).
    case copilotChat = "copilot-chat"
    /// Continue's `dev_data/0.2.0/tokensGenerated.jsonl`.
    case continueTokens = "continue-tokens"
    /// Zed's `threads/threads.db`.
    case zedThreads = "zed-threads"

    /// The dedup-key prefix the family's parser writes, when it is fixed. The others take the
    /// source's own `keyPrefix`.
    public var fixedPrefix: String? {
        switch self {
        case .anthropicJSONL: return "cc"
        case .codexRollout: return "cx"
        case .ompJSONL: return "omp"
        case .qwenUsage: return "qwen"
        case .kimiWire: return "kimi"
        case .devinTranscripts: return "devin"
        case .antigravitySQLite: return "ag"
        case .crushSQLite: return "crush"
        case .gooseSQLite: return "goose"
        case .droidSettings: return "droid"
        case .ampThreads: return "amp"
        case .openhandsState: return "oh"
        case .opencodeSQLite, .openDesignEvents, .notCountable: return nil
        case .geminiChats: return "gem"
        case .piJSONL: return "pi"
        case .copilotEvents: return "cop"
        case .junieEvents: return "jun"
        case .codebuffChats: return "cbuf"
        case .vibeSessions: return "vibe"
        case .augmentSessions: return "aug"
        case .qwenChats: return "qwenc"
        case .copilotChat: return "copilot-chat"
        case .continueTokens: return "continue"
        case .zedThreads: return "zed"
        case .clineTasks, .rooTasks: return nil
        }
    }

    /// Folders below a root worth watching for changes ("" is the root itself).
    var watchBelow: [String] {
        switch self {
        case .anthropicJSONL: return ["projects"]
        case .codexRollout: return ["sessions", "archived_sessions"]
        case .ompJSONL: return ["agent/sessions"]
        case .kimiWire: return ["sessions"]
        case .devinTranscripts: return ["cli/transcripts"]
        case .antigravitySQLite: return ["conversations"]
        case .droidSettings: return ["sessions"]
        case .ampThreads: return ["threads"]
        case .opencodeSQLite, .openDesignEvents, .qwenUsage, .crushSQLite, .gooseSQLite,
             .openhandsState: return [""]
        case .geminiChats: return [""]
        case .piJSONL: return ["sessions"]
        case .copilotEvents: return ["session-state"]
        case .junieEvents: return ["sessions"]
        case .codebuffChats: return ["projects"]
        case .vibeSessions: return ["logs/session"]
        case .augmentSessions: return ["sessions"]
        case .qwenChats: return [""]
        case .clineTasks: return ["tasks", "sessions"]
        case .rooTasks: return ["tasks"]
        case .copilotChat: return [""]
        case .continueTokens: return ["dev_data"]
        case .zedThreads: return ["threads"]
        // Nothing is read, and these folders (an editor's whole data folder) change all the time.
        case .notCountable: return []
        }
    }

    /// The family reads its own databases in `scanG3`, not as a list of files.
    var readsOwnDatabases: Bool { self == .crushSQLite || self == .gooseSQLite || self == .notCountable }
}

/// Where a tool keeps its data. `env` names the variable that moves it, when the tool has one.
public struct HarnessRoot: Sendable, Equatable {
    /// Under the home folder (`.claude`), or absolute, or starting with `~/`.
    public var base: String
    /// A variable that replaces `base` when set and not empty.
    public var env: String?
    /// A fixed folder below whichever of the two applies.
    public var below: String

    public init(_ base: String, env: String? = nil, below: String = "") {
        self.base = base
        self.env = env
        self.below = below
    }

    public func resolve(home: String, environment: [String: String]) -> String {
        var path = Self.expand(base, home: home)
        if let env, let value = environment[env], !value.isEmpty { path = Self.expand(value, home: home) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return below.isEmpty ? path : path + "/" + below
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + "/" + path.dropFirst(2) }
        return path.hasPrefix("/") ? path : home + "/" + path
    }
}

/// One tool, or one place a tool's logs live.
public struct HarnessDescriptor: Sendable {
    public var id: HarnessID
    public var name: String
    /// Dedup-key prefixes its rows carry. The first is the one new rows get.
    public var keyPrefixes: [String]
    public var family: ParserFamily
    /// The tool is detected when any of these exists.
    public var roots: [HarnessRoot]
    /// A colour in degrees, to keep a tool's colour when it has one already.
    public var hue: Double?
    /// For `opencode-sqlite` roots that are folders: look for databases at any depth.
    public var recursive: Bool
    /// From the user's `custom-sources.json`, not from the built-in list.
    public var custom: Bool

    public init(id: HarnessID, name: String, keyPrefixes: [String], family: ParserFamily, roots: [HarnessRoot],
                hue: Double? = nil, recursive: Bool = false, custom: Bool = false) {
        self.id = id
        self.name = name
        self.keyPrefixes = keyPrefixes
        self.family = family
        self.roots = roots
        self.hue = hue
        self.recursive = recursive
        self.custom = custom
    }
}

/// What the app knows about tools, process-wide: names, colours and key prefixes. It only grows,
/// so a report keeps its names when another scanner reads another home.
final class HarnessRegistry: @unchecked Sendable {
    static let shared = HarnessRegistry()

    private let lock = NSLock()
    private var names: [HarnessID: String] = [:]
    private var hues: [HarnessID: Double] = [:]
    private var prefixes: [String: HarnessID] = [:]
    private let builtinIDs = Set(HarnessCatalog.builtin.map(\.id))

    private init() { register(HarnessCatalog.builtin) }

    func register(_ descriptors: [HarnessDescriptor]) {
        lock.lock()
        defer { lock.unlock() }
        for d in descriptors {
            // The built-in names stay; a user's own entries may be edited while the app runs.
            if names[d.id] == nil || (d.custom && !builtinIDs.contains(d.id)) {
                names[d.id] = d.name
                hues[d.id] = d.hue
            }
            for prefix in d.keyPrefixes { prefixes[prefix] = d.id }
        }
    }

    func name(of id: HarnessID) -> String {
        lock.lock()
        defer { lock.unlock() }
        return names[id] ?? id.rawValue
    }

    func hue(of id: HarnessID) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return hues[id]
    }

    func id(forPrefix prefix: String) -> HarnessID? {
        lock.lock()
        defer { lock.unlock() }
        return prefixes[prefix]
    }
}
