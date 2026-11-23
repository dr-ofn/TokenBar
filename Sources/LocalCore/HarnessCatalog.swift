import Foundation

/// The tools TokenBar reads: the ones it knows (a list in Swift) and the ones the user adds in
/// `~/.config/tokenbar/custom-sources.json`:
///
///     {"sources": [{"id": "mytool", "name": "My Tool", "family": "opencode-sqlite",
///                   "paths": ["~/.mytool/sessions"], "keyPrefix": "mt"}]}
///
/// `id` groups sources under one tool; `family` is a `ParserFamily`; `paths` start with `~/` or `/`;
/// `keyPrefix` (optional) is the dedup-key prefix of families that don't fix their own; `hue`
/// (optional, degrees) pins the colour; `recursive` (optional) is for `opencode-sqlite` folders.
public struct HarnessCatalog: Sendable {
    public var descriptors: [HarnessDescriptor]
    /// What was wrong with the user's file, named once per load.
    public var issues: [SourceIssue] = []
    public let home: String
    public let environment: [String: String]

    public static let customSourcesName = "custom-sources.json"

    public static func customSourcesPath(home: String) -> String { home + "/.config/tokenbar/" + customSourcesName }

    /// The tools with a parser of their own. The prefixes are the ones already in users' indexes.
    public static let builtin: [HarnessDescriptor] = [
        HarnessDescriptor(id: .claudeCode, name: "Claude Code", keyPrefixes: ["cc"], family: .anthropicJSONL,
                          roots: [HarnessRoot(".claude", env: "CLAUDE_CONFIG_DIR"),
                                  // Claude Code also writes under the XDG config folder (`~/.config/claude`).
                                  HarnessRoot(".config", env: "XDG_CONFIG_HOME", below: "claude")], hue: 21),
        HarnessDescriptor(id: .codex, name: "Codex", keyPrefixes: ["cx"], family: .codexRollout,
                          roots: [HarnessRoot(".codex", env: "CODEX_HOME")], hue: 158),
        HarnessDescriptor(id: .ohMyPi, name: "oh-my-pi", keyPrefixes: ["omp"], family: .ompJSONL,
                          roots: [HarnessRoot(".omp")], hue: 270),
        HarnessDescriptor(id: .qwenCode, name: "Qwen Code", keyPrefixes: ["qwen"], family: .qwenUsage,
                          roots: [HarnessRoot(".qwen", env: "QWEN_HOME")], hue: 195),
        HarnessDescriptor(id: .kimiCode, name: "Kimi Code", keyPrefixes: ["kimi"], family: .kimiWire,
                          roots: [HarnessRoot(".kimi-code", env: "KIMI_CODE_HOME")], hue: 46),
        HarnessDescriptor(id: .devin, name: "Devin", keyPrefixes: ["devin"], family: .devinTranscripts,
                          roots: [HarnessRoot(".local/share/devin")], hue: 88),
        HarnessDescriptor(id: .antigravity, name: "Antigravity", keyPrefixes: ["ag"], family: .antigravitySQLite,
                          roots: [HarnessRoot(".gemini/antigravity-cli")], hue: 352),
        HarnessDescriptor(id: .opencode, name: "opencode", keyPrefixes: ["oc"], family: .opencodeSQLite,
                          roots: [HarnessRoot(".local/share", env: "XDG_DATA_HOME", below: "opencode")], hue: 224),
        // `crush.json`'s folder holds `projects.json`, which names each project's data folder.
        HarnessDescriptor(id: .crush, name: "Crush", keyPrefixes: ["crush"], family: .crushSQLite,
                          roots: [HarnessRoot(".local/share", env: "XDG_DATA_HOME", below: "crush"),
                                  HarnessRoot(".local/share/crush", env: "CRUSH_GLOBAL_DATA")], hue: 290),
        // A root is a folder that holds `sessions.db`, or `GOOSE_PATH_ROOT` (the database is under `data/sessions`).
        HarnessDescriptor(id: .goose, name: "Goose", keyPrefixes: ["goose"], family: .gooseSQLite,
                          roots: [HarnessRoot(".local/share/goose/sessions"),
                                  HarnessRoot("Library/Application Support/goose/sessions"),
                                  HarnessRoot(".local/share/Block/goose/sessions"),
                                  HarnessRoot("Library/Application Support/Block/goose/sessions"),
                                  HarnessRoot(".local/share/goose", env: "GOOSE_PATH_ROOT")], hue: 135),
        HarnessDescriptor(id: .factoryDroid, name: "Factory Droid", keyPrefixes: ["droid"], family: .droidSettings,
                          roots: [HarnessRoot(".factory")], hue: 62),
        HarnessDescriptor(id: .amp, name: "Amp", keyPrefixes: ["amp"], family: .ampThreads,
                          roots: [HarnessRoot(".local/share/amp", env: "AMP_DATA_DIR")], hue: 5),
        HarnessDescriptor(id: .openHands, name: "OpenHands", keyPrefixes: ["oh"], family: .openhandsState,
                          roots: [HarnessRoot(".openhands/conversations", env: "OPENHANDS_CONVERSATIONS_DIR"),
                                  HarnessRoot(".openhands", env: "OPENHANDS_PERSISTENCE_DIR", below: "conversations")], hue: 175),
        // Warp keeps its token totals in `warp.sqlite` without an input/output split, and the
        // app-group folder (`<team id>.dev.warp`) was not seen on a real Mac: named, never counted.
        HarnessDescriptor(id: .warp, name: "Warp", keyPrefixes: ["warp"], family: .notCountable,
                          roots: [HarnessRoot("Library/Group Containers/*.dev.warp")], hue: 210),
        // Amazon Q Developer CLI records no token counts locally (`RequestMetadata` has none).
        HarnessDescriptor(id: .amazonQ, name: "Amazon Q", keyPrefixes: ["amq"], family: .notCountable,
                          roots: [HarnessRoot("Library/Application Support/amazon-q")], hue: 35),
        // GEMINI_CLI_HOME replaces the home folder: the data is in `$GEMINI_CLI_HOME/.gemini/tmp`. The root is
        // `.gemini/tmp`, not `.gemini`, so the folder Antigravity also keeps there does not make Gemini CLI "detected".
        HarnessDescriptor(id: .geminiCLI, name: "Gemini CLI", keyPrefixes: ["gem"], family: .geminiChats,
                          roots: [HarnessRoot("~", env: "GEMINI_CLI_HOME", below: ".gemini/tmp")], hue: 217),
        // PI_CODING_AGENT_DIR is the agent folder itself (`~/.pi/agent` by default).
        HarnessDescriptor(id: .pi, name: "Pi", keyPrefixes: ["pi"], family: .piJSONL,
                          roots: [HarnessRoot(".pi/agent", env: "PI_CODING_AGENT_DIR")], hue: 300),
        HarnessDescriptor(id: .copilotCLI, name: "GitHub Copilot CLI", keyPrefixes: ["cop"], family: .copilotEvents,
                          roots: [HarnessRoot(".copilot", env: "COPILOT_HOME")], hue: 262),
        HarnessDescriptor(id: .junie, name: "Junie", keyPrefixes: ["jun"], family: .junieEvents,
                          roots: [HarnessRoot(".junie")], hue: 140),
        HarnessDescriptor(id: .codebuff, name: "Codebuff", keyPrefixes: ["cbuf"], family: .codebuffChats,
                          // CODEBUFF_DATA_DIR replaces all three channel folders with one root.
                          roots: [HarnessRoot(".config/manicode", env: "CODEBUFF_DATA_DIR"),
                                  HarnessRoot(".config/manicode-dev", env: "CODEBUFF_DATA_DIR"),
                                  HarnessRoot(".config/manicode-staging", env: "CODEBUFF_DATA_DIR")], hue: 120),
        HarnessDescriptor(id: .mistralVibe, name: "Mistral Vibe", keyPrefixes: ["vibe"], family: .vibeSessions,
                          roots: [HarnessRoot(".vibe", env: "VIBE_HOME")], hue: 28),
        HarnessDescriptor(id: .augment, name: "Augment", keyPrefixes: ["aug"], family: .augmentSessions,
                          roots: [HarnessRoot(".augment")], hue: 175),
        // Qwen Code's newer chat files. Read only where Qwen's own usage files are absent (see `qwenKeepsOwnAccounting`).
        HarnessDescriptor(id: .qwenCode, name: "Qwen Code", keyPrefixes: ["qwenc"], family: .qwenChats,
                          roots: [HarnessRoot(".qwen", env: "QWEN_HOME")], hue: 195),
    ] + g2Descriptors

    /// The variables only move the real home's tools: a scan of another home (a fixture, a
    /// backup) must not follow this process's environment into the real one.
    public static func defaultEnvironment(home: String) -> [String: String] {
        home == NSHomeDirectory() ? ProcessInfo.processInfo.environment : [:]
    }

    public static func load(home: String = NSHomeDirectory(), environment: [String: String]? = nil) -> HarnessCatalog {
        var catalog = HarnessCatalog(descriptors: builtin, home: home, environment: environment ?? defaultEnvironment(home: home))
        let path = customSourcesPath(home: home)
        guard let data = FileManager.default.contents(atPath: path) else { return catalog }
        let parsed = parseCustom(data)
        catalog.descriptors += parsed.descriptors
        catalog.issues = parsed.issues
        return catalog
    }

    /// Makes the catalog's names, colours and prefixes known to every report in the process.
    public func register() { HarnessRegistry.shared.register(descriptors) }

    // MARK: custom sources

    static func parseCustom(_ data: Data) -> (descriptors: [HarnessDescriptor], issues: [SourceIssue]) {
        var issues: [SourceIssue] = []
        func problem(_ message: String) { issues.append(SourceIssue(source: customSourcesName, message: message)) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            problem(L10n.t("geçerli bir JSON nesnesi değil", "not a valid JSON object"))
            return ([], issues)
        }
        guard let entries = root["sources"] as? [Any] else {
            problem(L10n.t("\"sources\" dizisi yok", "\"sources\" array is missing"))
            return ([], issues)
        }

        var claimed: [String: HarnessID] = [:]
        for d in builtin { for prefix in d.keyPrefixes { claimed[prefix] = d.id } }
        var out: [HarnessDescriptor] = []
        let idOK = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } }
        let prefixOK = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } }

        for (index, entry) in entries.enumerated() {
            let label = "sources[\(index)]"
            guard let o = entry as? [String: Any] else { problem("\(label): " + L10n.t("nesne değil", "not an object")); continue }
            guard let id = o["id"] as? String, idOK(id) else { problem("\(label): " + L10n.t("\"id\" yok ya da geçersiz (harf, rakam, . _ -)", "\"id\" is missing or invalid (letters, digits, . _ -)")); continue }
            guard let familyName = o["family"] as? String, let family = ParserFamily(rawValue: familyName) else {
                let known = ParserFamily.allCases.map(\.rawValue).joined(separator: ", ")
                let given = o["family"].map { "\($0)" } ?? L10n.t("yok", "none")
                problem("\(label) (\(id)): " + L10n.t("bilinmeyen aile \(given); bilinenler: \(known)", "unknown family \(given); known: \(known)"))
                continue
            }
            guard let paths = o["paths"] as? [String], !paths.isEmpty, paths.allSatisfy({ !$0.isEmpty }) else {
                problem("\(label) (\(id)): " + L10n.t("\"paths\" boş ya da dizi değil", "\"paths\" is empty or not an array"))
                continue
            }
            var prefix = (o["keyPrefix"] as? String) ?? family.fixedPrefix ?? id.lowercased()
            if let fixed = family.fixedPrefix, prefix != fixed {
                problem("\(label) (\(id)): " + L10n.t("\(family.rawValue) ailesinin öneki \(fixed), \"\(prefix)\" olamaz", "the prefix of the \(family.rawValue) family is \(fixed), \"\(prefix)\" is not allowed"))
                continue
            }
            if family.fixedPrefix == nil, !prefixOK(prefix) {
                problem("\(label) (\(id)): " + L10n.t("\"keyPrefix\" küçük harf, rakam ve - olmalı", "\"keyPrefix\" must be lowercase letters, digits and -"))
                continue
            }
            if let owner = claimed[prefix], owner != HarnessID(id) {
                problem("\(label) (\(id)): " + L10n.t("\"\(prefix)\" önekini \(owner.rawValue) kullanıyor", "the prefix \"\(prefix)\" is used by \(owner.rawValue)"))
                continue
            }
            prefix = prefix.lowercased()
            claimed[prefix] = HarnessID(id)
            var hue: Double?
            if let value = o["hue"] as? Double, value.isFinite { hue = (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
            out.append(HarnessDescriptor(
                id: HarnessID(id), name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                keyPrefixes: [prefix], family: family, roots: paths.map { HarnessRoot($0) }, hue: hue,
                recursive: (o["recursive"] as? Bool) ?? true, custom: true))
        }
        return (out, issues)
    }

    // MARK: places

    /// Where a descriptor's tool keeps its data on this Mac.
    public func rootPaths(of descriptor: HarnessDescriptor) -> [String] {
        // Two roots that resolve to one folder (a variable pointing at the other root) are read once.
        var seen = Set<String>()
        return descriptor.roots.flatMap { Self.expandingGlobs($0.resolve(home: home, environment: environment)) }
            .filter { seen.insert($0).inserted }
    }

    /// The tools whose root exists, in catalog order, each once.
    public func detected() -> [HarnessID] {
        var seen = Set<HarnessID>()
        var out: [HarnessID] = []
        for d in descriptors where rootPaths(of: d).contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            if seen.insert(d.id).inserted { out.append(d.id) }
        }
        return out
    }

    /// Folders whose changes should wake a scan; they may not exist yet.
    public func watchPaths() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for d in descriptors where d.family != .notCountable {
            for root in rootPaths(of: d) {
                let base = Self.looksLikeFile(root) ? (root as NSString).deletingLastPathComponent : root
                for below in d.family.watchBelow {
                    let path = below.isEmpty || base != root ? base : base + "/" + below
                    if seen.insert(path).inserted { out.append(path) }
                }
            }
        }
        for path in crushWatchPaths() where seen.insert(path).inserted { out.append(path) }
        return out
    }

    /// A file that exists, or a name with an extension that does not exist yet. An extension is
    /// letters and digits: `saoudrizwan.claude-dev` (an editor extension's folder) is not one.
    static func looksLikeFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) { return !isDirectory.boolValue }
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
