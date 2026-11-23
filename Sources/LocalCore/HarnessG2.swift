import Foundation

/// Editor extensions and IDEs: Cline, Roo Code, Kilo Code, Copilot Chat, Continue, Kiro, Zed, and
/// the editors that keep their token counts to themselves (Cursor, Windsurf, Trae).
extension HarnessID {
    public static let cline = HarnessID("cline")
    public static let rooCode = HarnessID("roo-code")
    public static let kiloCode = HarnessID("kilo-code")
    public static let copilotChat = HarnessID("copilot-chat")
    public static let continueDev = HarnessID("continue")
    public static let kiro = HarnessID("kiro")
    public static let zed = HarnessID("zed")
    public static let cursor = HarnessID("cursor")
    public static let windsurf = HarnessID("windsurf")
    public static let trae = HarnessID("trae")
}

extension HarnessCatalog {
    /// The VS Code family's application-support folders an extension may live in. Cline, Roo and
    /// Kilo are installed into any of them, so each one is a root; a folder without the extension
    /// is simply not there.
    static let g2Editors = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Kiro", "Positron", "Trae", "Antigravity"]

    private static func g2Extension(_ id: String, editors: [String] = g2Editors) -> [HarnessRoot] {
        editors.map { HarnessRoot("Library/Application Support/\($0)/User/globalStorage/\(id)") }
    }

    /// Appended to `builtin`.
    static let g2Descriptors: [HarnessDescriptor] = [
        HarnessDescriptor(id: .cline, name: "Cline", keyPrefixes: ["cline"], family: .clineTasks,
                          roots: g2Extension("saoudrizwan.claude-dev") + [HarnessRoot(".cline/data")], hue: 120),
        HarnessDescriptor(id: .rooCode, name: "Roo Code", keyPrefixes: ["roo"], family: .rooTasks,
                          roots: g2Extension("rooveterinaryinc.roo-cline"), hue: 60),
        // Kilo Code's task folders (versions 3 to 5), then version 7 and the CLI: opencode's schema.
        HarnessDescriptor(id: .kiloCode, name: "Kilo Code", keyPrefixes: ["kilocode"], family: .rooTasks,
                          roots: g2Extension("kilocode.kilo-code"), hue: 280),
        HarnessDescriptor(id: .kiloCode, name: "Kilo Code", keyPrefixes: ["kilo"], family: .opencodeSQLite,
                          roots: [HarnessRoot(".local/share", env: "XDG_DATA_HOME", below: "kilo")], hue: 280),
        HarnessDescriptor(id: .copilotChat, name: "Copilot Chat", keyPrefixes: ["copilot-chat"], family: .copilotChat,
                          roots: ["Code", "Code - Insiders"].flatMap { editor in
                              ["User/workspaceStorage", "User/globalStorage/emptyWindowChatSessions"].map {
                                  HarnessRoot("Library/Application Support/\(editor)/\($0)")
                              }
                          }, hue: 240),
        HarnessDescriptor(id: .continueDev, name: "Continue", keyPrefixes: ["continue"], family: .continueTokens,
                          roots: [HarnessRoot(".continue", env: "CONTINUE_GLOBAL_DIR")], hue: 175),
        HarnessDescriptor(id: .zed, name: "Zed", keyPrefixes: ["zed"], family: .zedThreads,
                          roots: [HarnessRoot("Library/Application Support/Zed")], hue: 35),
        // Found, never counted: their logs hold no token counts (Kiro's are zero in the Auto agent
        // and the rest are credits; Cursor, Windsurf and Trae keep usage on their servers).
        HarnessDescriptor(id: .kiro, name: "Kiro", keyPrefixes: ["kiro"], family: .notCountable,
                          roots: [HarnessRoot(".kiro"), HarnessRoot("Library/Application Support/kiro-cli"),
                                  HarnessRoot("Library/Application Support/Kiro")], hue: 305),
        HarnessDescriptor(id: .cursor, name: "Cursor", keyPrefixes: ["cursor"], family: .notCountable,
                          roots: [HarnessRoot("Library/Application Support/Cursor"), HarnessRoot(".cursor")], hue: 210),
        HarnessDescriptor(id: .windsurf, name: "Windsurf", keyPrefixes: ["windsurf"], family: .notCountable,
                          roots: [HarnessRoot(".codeium/windsurf"), HarnessRoot("Library/Application Support/Windsurf")], hue: 150),
        HarnessDescriptor(id: .trae, name: "Trae", keyPrefixes: ["trae"], family: .notCountable,
                          roots: [HarnessRoot("Library/Application Support/Trae")], hue: 335),
    ]

    /// The tools found on this Mac whose logs hold no token counts, in catalog order, each once.
    public func notCountable() -> [HarnessID] {
        var seen = Set<HarnessID>()
        var out: [HarnessID] = []
        for d in descriptors where d.family == .notCountable {
            if rootPaths(of: d).contains(where: { FileManager.default.fileExists(atPath: $0) }), seen.insert(d.id).inserted {
                out.append(d.id)
            }
        }
        return out
    }
}
