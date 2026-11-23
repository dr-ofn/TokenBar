import AppKit
import Foundation
import LocalCore
import SQLite3
import SwiftUI
import TokenBarUI

// Visual smoke check: renders the panel and the dashboard to TIFFs in both appearances
// (`swift run UISnapshot [window]` -> /tmp/tokenbar-{panel,dashboard}-{dark,light}.tiff),
// and `swift run UISnapshot selfcheck` runs the UI invariants, in Turkish and in English.
// TOKENBAR_LANG=en|tr picks the language of the pictures (the file names then end in -en / -tr);
// TOKENBAR_SNAPSHOT_DIR moves the files out of /tmp. TOKENBAR_SNAPSHOT_DEMO=1 draws invented usage instead of this
// machine's (the pictures in docs/ are made that way: TOKENBAR_PRICES_PINNED=1 TOKENBAR_LANG=en ... UISnapshot all).

/// Contrast gate: every text color must clear 5:1 on its ground.
func contrastChecks() -> Int {
    var failed = 0
    func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    func lum(_ c: RGB) -> Double { 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }
    func ratio(_ a: RGB, _ b: RGB) -> Double {
        (max(lum(a), lum(b)) + 0.05) / (min(lum(a), lum(b)) + 0.05)
    }
    for (mode, style) in [("koyu", Palette.dark), ("açık", Palette.light)] {
        for (name, ink) in [("metin", style.text), ("soluk metin", style.muted), ("uyarı", style.warning)] {
            let r = ratio(ink, style.background)
            let ok = r >= 5
            print((ok ? "ok   " : "FAIL ") + "\(mode) · \(name) ölçülen \(String(format: "%.2f", r)):1 ≥ 5:1")
            if !ok { failed += 1 }
        }
    }
    return failed
}

/// The picture itself: shares, hit testing, clicks, and an empty period, in one interface language.
@MainActor func layoutChecks(_ lang: Lang) -> Int {
    L10n.setLanguage(lang)
    defer { L10n.setLanguage(nil) }
    // The words each language puts on the picture.
    let words = lang == .tr ? (unpriced: "1 fiyatsız", more: "model daha", source: "Kaynak", total: "API eşdeğeri")
                            : (unpriced: "1 unpriced", more: "more models", source: "Source", total: "API equivalent")
    var failed = 0
    func expect(_ name: String, _ cond: Bool) {
        print((cond ? "ok   " : "FAIL ") + "[\(lang.rawValue)] " + name)
        if !cond { failed += 1 }
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-ui-\(UUID().uuidString.prefix(8))").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let store = try? UsageStore(path: dir + "/u.sqlite") else { print("FAIL dizin açılamadı"); return 1 }
    let now = Date().timeIntervalSince1970
    func event(_ key: String, _ model: String, _ ago: Double, _ input: Int64, _ output: Int64) -> UsageEvent {
        UsageEvent(key: key, provider: "test", model: model, timestamp: now - ago,
                   tokens: TokenCounts(input: input, output: output), session: key, file: "test")
    }
    try? store.insertEvents([event("cc:a", "claude-opus-5-5", 60, 200_000, 20_000),
                             event("cx:b", "gpt-6-luna", 30, 500_000, 9_000),
                             event("oc:c", "big-pickle", 20, 900_000, 1000),
                             event("oc:d", "never-listed", 20, 50_000, 0),
                             event("cc:adj:s:claude-opus-5-5", "claude-opus-5-5", 90, 1000, 0)])
    guard let report = (try? store.usageBook())?.report(for: .day) else { print("FAIL dizin okunamadı"); return 1 }
    expect("düzeltme satırı çağrı sayılmıyor", report.callCount == 4)
    expect("düzeltme satırı toplamda", report.counts.total == 200_000 + 20_000 + 509_000 + 901_000 + 50_000 + 1000)
    expect("araçlar token sırasıyla", report.harnesses.map(\.harness) == [.opencode, .codex, .claudeCode])

    let layout = RibbonLayout(report: report, width: 460, height: 620, leftColumn: 104, rightColumn: 186, top: 40, bottomMargin: 12)
    let tokenHeight = layout.ribbons.reduce(0) { $0 + $1.leftHeight }
    let perToken = layout.ribbons[0].leftHeight / Double(layout.ribbons[0].stat.tokens)
    expect("sol kalınlık tokenle orantılı", layout.ribbons.allSatisfy { abs($0.leftHeight - Double($0.stat.tokens) * perToken) < 1e-6 })
    expect("sol ray yüksekliğe sığıyor", tokenHeight <= layout.bottom - layout.top + 0.01)
    let paid = layout.ribbons.filter { $0.stat.cost > 0 }
    let perDollar = paid[0].rightHeight / paid[0].stat.cost
    expect("sağ kalınlık dolarla orantılı", paid.allSatisfy { abs($0.rightHeight - $0.stat.cost * perDollar) < 1e-6 })
    expect("fiyatsız şerit noktada biter", layout.ribbons.filter { $0.stat.cost == 0 }.allSatisfy { $0.rightHeight == 0 && $0.rightTop == layout.freePoint })
    expect("en pahalı araç üstte", layout.ribbons[0].stat.harness == .claudeCode)
    expect("etiketler üst üste binmiyor", zip(layout.rightLabels, layout.rightLabels.dropFirst()).allSatisfy { $1.y - $0.y >= 13.9 })
    expect("etiketler resimde kalıyor", (layout.leftLabels + layout.rightLabels).allSatisfy { $0.y >= layout.top && $0.y <= layout.bottom + 0.01 })
    expect("fiyatsız satırı sayıyı yazıyor", layout.rightLabels.last?.title == words.unpriced)

    // A short picture with many paid models: the names that don't fit join the rest.
    let many = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-fable-5-2", "gpt-6-astra", "gpt-6.1-sol",
                "gpt-6.1-terra", "glm-5.3", "gemini-3.8-flash", "gemini-3.7-flash", "inkling", "step-5-preview"]
    if let crowdStore = try? UsageStore(path: dir + "/crowd.sqlite"),
       (try? crowdStore.insertEvents(many.enumerated().map { event("oc:m\($0.offset)", $0.element, 60, 0, 1_000_000) })) != nil,
       let crowd = (try? crowdStore.usageBook())?.report(for: .day) {
        let short = RibbonLayout(report: crowd, width: 460, height: 200, leftColumn: 104, rightColumn: 186, top: 40, bottomMargin: 12)
        expect("kısa resimde etiketler üst üste binmiyor", zip(short.rightLabels, short.rightLabels.dropFirst()).allSatisfy { $1.y - $0.y >= 13.9 })
        expect("kısa resimde etiketler resimde kalıyor", (short.leftLabels + short.rightLabels).allSatisfy { $0.y >= short.top && $0.y <= short.bottom + 0.01 })
        expect("sığmayan adlar 'model daha' satırında", short.rightLabels.last?.title.hasSuffix(words.more) == true && short.rightLabels.count < many.count)
    } else {
        expect("kalabalık dizin kuruldu", false)
    }

    let first = layout.ribbons[0]
    let x = (layout.leftX + layout.rightX) / 2
    let edges = layout.edges(first, at: x)
    expect("üzerine gelince şerit bulunuyor", layout.hit(x: x, y: (edges.top + edges.bottom) / 2) == .flow(first.stat.id))
    expect("sol etiket aracı seçiyor", layout.hit(x: 40, y: layout.leftLabels[0].y) == layout.leftLabels[0].selection)
    expect("sağ etiket modeli seçiyor", layout.hit(x: 400, y: layout.rightLabels[0].y) == layout.rightLabels[0].selection)
    expect("başlık toplamı seçiyor", layout.hit(x: 200, y: 10) == .total)
    let selections: [UsageSelection] = [.flow(first.stat.id), layout.leftLabels[0].selection, layout.rightLabels[0].selection, .total]
    expect("her seçimin dökümü var", selections.allSatisfy { !report.detail($0).rows.isEmpty })
    expect("toplam dökümü maliyeti anlatıyor", report.detail(.total).note?.contains(words.total) == true)
    expect("model dökümü fiyat kaynağını yazıyor", report.detail(.flow(first.stat.id)).note?.contains(words.source) == true)
    if let list = layout.rightLabels.last?.selection {
        expect("fiyatsız listesi modeli açıyor", report.detail(list).links.count == 1)
    }
    expect("aracın dökümü modellerini listeliyor", report.detail(.harness(.opencode)).links.count == 2)
    expect("model dökümü fiyat türünü yazıyor", report.detail(.flow(first.stat.id)).rows.contains { $0.label == UsageText.priceTypeLabel && $0.value == "OpenRouter" })
    expect("fiyatsız modelin dökümü fiyat yok diyor", report.detail(.flow("opencode|test/never-listed")).rows.contains { $0.value == UsageText.noPrice })
    expect("toplam çağrı dilde", report.detail(.total).title.hasSuffix(UsageText.calls(4)))

    let stage = RibbonStage()
    stage.toggle(.total)
    expect("tıklama dökümü açıyor", stage.selected == .total)
    stage.toggle(.total)
    expect("ikinci tıklama kapatıyor", stage.selected == nil)
    stage.toggleExpanded(.codex)
    expect("araca tıklama modelleri açıyor", stage.expanded == .codex)

    let tiny = RibbonLayout(report: report, width: 20, height: 20, leftColumn: 3, rightColumn: 3, top: 2, bottomMargin: 2)
    expect("küçük resimde de dolar kalınlığı var", tiny.ribbons.reduce(0) { $0 + $1.rightHeight } > 10)
    expect("menü simgesi 20 nokta", RibbonIcon.render(report)?.size == NSSize(width: 20, height: 20))
    guard let empty = (try? store.usageBook(now: Date(timeIntervalSinceNow: 7200)))?.report(for: .oneHour) else { return failed + 1 }
    expect("boş dönem düzgün", empty.isEmpty && RibbonLayout(report: empty, width: 460, height: 600, leftColumn: 104, rightColumn: 186, top: 40, bottomMargin: 12).ribbons.isEmpty && RibbonIcon.render(empty) == nil)
    return failed
}

/// SwiftUI hands the controls of a hosted view (buttons, the "⋯" menu) to AppKit as focus proxies or pop-up buttons;
/// its accessibility tree stays empty without an assistive client, so the controls are counted by what AppKit sees.
@MainActor func controlCount(in root: NSView) -> Int {
    let name = String(describing: type(of: root))
    let own = name.contains("KeyViewProxy") || name.contains("PopupButton") ? 1 : 0
    return root.subviews.reduce(own) { (sum: Int, view: NSView) -> Int in sum + controlCount(in: view) }
}

/// Shows `content` in an invisible window for a moment and returns how many controls it has.
@MainActor func hostedControls<V: View>(_ content: V, size: CGSize) async -> Int {
    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.contentView = hosting
    window.orderFront(nil)
    try? await Task.sleep(for: .seconds(1))
    hosting.layoutSubtreeIfNeeded()
    let count = controlCount(in: hosting)
    window.orderOut(nil)
    window.contentView = nil
    return count
}

/// A menu-bar app with no Dock icon: whatever the panel shows, a menu ("Quit" is in it) has to be on it.
@MainActor func menuReachabilityChecks(_ lang: Lang) async -> Int {
    L10n.setLanguage(lang)
    defer { L10n.setLanguage(nil) }
    var failed = 0
    func expect(_ name: String, _ cond: Bool) {
        print((cond ? "ok   " : "FAIL ") + "[\(lang.rawValue)] " + name)
        if !cond { failed += 1 }
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-menu-\(UUID().uuidString.prefix(8))").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // The positive control: a panel with a report has the menu (and the finder sees it).
    let model = AppModel(engine: Engine(home: dir, dbPath: dir + "/engine-model.sqlite"))
    if let store = try? UsageStore(path: dir + "/u.sqlite") {
        let now = Date().timeIntervalSince1970
        try? store.insertEvents([UsageEvent(key: "cc:a", provider: "test", model: "claude-opus-5-5", timestamp: now - 60,
                                            tokens: TokenCounts(input: 1000, output: 100), session: "a", file: "test")])
        model.report = (try? store.usageBook())?.report(for: .day)
    }
    let withReport = await hostedControls(PanelView(model: model), size: PanelView.fixedSize)
    expect("rapor varken panelde menü var (kontrol)", model.report != nil && withReport >= 3)

    // The index could not be opened (a newer schema, a lock): the panel says why, and still has the menu.
    let broken = AppModel(engine: Engine(home: dir, dbPath: dir + "/broken.sqlite"))
    broken.statusMessage = "Dizin şeması 99, beklenen 21: dokunulmadı"
    expect("hata durumunda rapor yok", broken.report == nil && broken.notice != nil)
    let brokenPanel = await hostedControls(PanelView(model: broken), size: PanelView.fixedSize)
    let brokenDashboard = await hostedControls(DashboardView(model: broken), size: DashboardView.defaultSize)
    expect("hata durumunda panelde menü var", brokenPanel >= 1)
    expect("hata durumunda panoda menü var", brokenDashboard >= 1)
    // The first scan has not finished: no report and no notice yet.
    let scanning = AppModel(engine: Engine(home: dir, dbPath: dir + "/scanning.sqlite"))
    let scanningPanel = await hostedControls(PanelView(model: scanning), size: PanelView.fixedSize)
    let scanningDashboard = await hostedControls(DashboardView(model: scanning), size: DashboardView.defaultSize)
    expect("ilk taramada panelde menü var", scanningPanel >= 1)
    expect("ilk taramada panoda menü var", scanningDashboard >= 1)
    return failed
}

/// The list of detected tools, the stage's two panels and what a price change does to a report.
@MainActor func detectedAndPriceChecks(_ lang: Lang) async -> Int {
    L10n.setLanguage(lang)
    defer { L10n.setLanguage(nil) }
    var failed = 0
    func expect(_ name: String, _ cond: Bool) {
        print((cond ? "ok   " : "FAIL ") + "[\(lang.rawValue)] " + name)
        if !cond { failed += 1 }
        fflush(stdout)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-det-\(UUID().uuidString.prefix(8))").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let store = try? UsageStore(path: dir + "/u.sqlite") else { print("FAIL dizin açılamadı"); return 1 }
    let now = Date().timeIntervalSince1970
    try? store.insertEvents([UsageEvent(key: "cc:a", provider: "test", model: "claude-opus-5-5", timestamp: now - 60,
                                        tokens: TokenCounts(input: 200_000, output: 20_000), session: "a", file: "test"),
                             UsageEvent(key: "cx:b", provider: "test", model: "gpt-6-luna", timestamp: now - 30,
                                        tokens: TokenCounts(input: 5_000_000, output: 9_000), session: "b", file: "test")])
    guard let all = (try? store.usageBook())?.report(for: .all) else { print("FAIL dizin okunamadı"); return 1 }

    // "Cursor" keeps its token counts on a server: it is detected and cannot be counted here.
    let cursor = HarnessID("cursor")
    let list = DetectedTools.list(detected: [.opencode, .claudeCode, .codex, cursor], notCountable: [cursor], report: all)
    expect("algılananlar: verisi olan önce, sonra boşta, sonra sayılamayan", list.map(\.harness) == [.codex, .claudeCode, .opencode, cursor])
    expect("algılananlar: boştaki araç 'henüz kullanım yok' diyor",
           list[2].status == L10n.t("henüz kullanım yok", "no usage yet") && list[2].state == .notYet)
    expect("algılananlar: sayılamayan araç nedenini söylüyor", list[3].line.hasSuffix(L10n.t("token verisi yerelde yok", "token data is not stored locally")))
    expect("algılananlar: verisi olan araç token ve çağrıyı yazıyor", list[0].status.contains(UsageText.calls(1)) && list[0].status.contains(UsageText.tokens(5_009_000)))
    expect("algılananlar: aynı araç iki kez sayılmıyor", DetectedTools.list(detected: [.codex, .codex], notCountable: [.codex], report: nil).count == 1)
    expect("algılananlar: özet satırı sayıyı yazıyor", DetectedTools.summary(5) == L10n.t("Algılanan: 5 araç", "Detected: 5 tools") && DetectedTools.summary(1).contains("1"))

    let stage = RibbonStage()
    stage.toggleDetected()
    expect("liste açılınca döküm kapanıyor ve panel açık sayılıyor", stage.showsDetected && stage.selected == nil && stage.hasOpenPanel)
    stage.toggle(.total)
    expect("döküm açılınca liste kapanıyor", stage.selected == .total && !stage.showsDetected)
    stage.toggleDetected()
    expect("liste döküm yerine geçiyor", stage.showsDetected && stage.selected == nil)
    stage.closePanel()
    expect("Kapat ikisini de kapatıyor", !stage.hasOpenPanel)

    // New prices change the money of rows already in the book: the report must look new to the views.
    let before = all.version
    PriceBook.install(catalogs: .embedded)
    guard let again = (try? store.usageBook())?.report(for: .all) else { return failed + 1 }
    expect("fiyat sürümü değişince rapor sürümü de değişiyor", again.version != before && again.priceRevision == PriceBook.revision)

    // Offline asks the network for nothing, and the menu's "update prices" says so.
    PriceBook.offline = true
    let report = await PriceBook.refreshNow()
    PriceBook.offline = false
    expect("çevrimdışıyken güncelleme ağa gitmiyor", report.skipped.count == PriceSource.allCases.count && report.updated.isEmpty && !report.changed)
    let old = try? JSONDecoder().decode(Preferences.self, from: Data(#"{"window":"24h"}"#.utf8))
    expect("eski ayar dosyası çevrimdışı alanı olmadan okunuyor", old?.window == .day && old?.offline == false)
    return failed
}

/// A scan never throws: a broken source is named and the rest still counts.
func engineFaultChecks() async throws -> Int {
    var failed = 0
    func expect(_ name: String, _ cond: Bool) {
        print((cond ? "ok   " : "FAIL ") + name)
        if !cond { failed += 1 }
        fflush(stdout)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-fault-\(UUID().uuidString.prefix(8))").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir + "/.local/share/opencode", withIntermediateDirectories: true)
    try? "bu bir sqlite dosyası değil".write(toFile: dir + "/.local/share/opencode/opencode.db", atomically: false, encoding: .utf8)
    // A healthy Claude Code transcript beside it: it is still read.
    try? fm.createDirectory(atPath: dir + "/.claude/projects/p", withIntermediateDirectories: true)
    let line = "{\"type\":\"assistant\",\"timestamp\":\"2026-10-27T10:00:00.000Z\",\"sessionId\":\"s\",\"requestId\":\"r1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":5,\"output_tokens\":2}}}\n"
    try? line.write(toFile: dir + "/.claude/projects/p/s.jsonl", atomically: false, encoding: .utf8)
    let engine = Engine(home: dir, dbPath: dir + "/u.sqlite")
    let result = try await engine.scan()
    let book = try await engine.book()
    expect("çöp opencode dosyası sorun olarak bildirilir", result.issues.contains { $0.source == "opencode" })
    expect("opencode bozukken diğer kaynak sayılıyor", book.report(for: .all).callCount == 1)
    let empty = Engine(home: dir + "/yok", dbPath: dir + "/2.sqlite")
    let none = try await empty.scan()
    expect("eksik kaynak sorun sayılmaz", none.issues.isEmpty)
    return failed
}

/// Counts watcher callbacks; read from the test's task while FSEvents bumps it on its own queue.
final class Hits: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    /// True once the count passes `after`, false if `seconds` run out first.
    func pass(_ after: Int, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while count <= after, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return count > after
    }
}

/// The engine opens its index off the caller's thread, and the watcher finds a folder made later.
@MainActor func engineStartChecks() async -> Int {
    var failed = 0
    func expect(_ name: String, _ cond: Bool) {
        print((cond ? "ok   " : "FAIL ") + name)
        if !cond { failed += 1 }
        fflush(stdout)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-start-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath().path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // Another process holds the index: opening it waits, but not on the thread that asked.
    var raw: OpaquePointer?
    let locked = dir + "/locked.sqlite"
    if sqlite3_open(locked, &raw) == SQLITE_OK { sqlite3_exec(raw, "CREATE TABLE t(x); BEGIN EXCLUSIVE;", nil, nil, nil) }
    let started = Date()
    let engine = Engine(home: dir, dbPath: locked)
    expect("Engine açılışı çağıran iş parçacığını bloklamıyor", Date().timeIntervalSince(started) < 1)
    sqlite3_exec(raw, "ROLLBACK;", nil, nil, nil)
    sqlite3_close(raw)
    expect("kilit kalkınca Engine dizini açıyor", (try? await engine.book()) != nil)

    // A folder that does not exist yet is waited for; once it exists, its files are watched.
    let root = dir + "/watch", late = root + "/tool/data"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let hits = Hits()
    let watcher = FileWatcher(paths: [late], latency: 0.2) { hits.bump() }
    try? FileManager.default.createDirectory(atPath: late, withIntermediateDirectories: true)
    expect("sonradan kurulan aracın klasörü yeniden başlatmadan algılanıyor", await hits.pass(0, within: 8))
    try? await Task.sleep(for: .seconds(1.5))
    let before = hits.count
    try? "x".write(toFile: late + "/log.jsonl", atomically: false, encoding: .utf8)
    expect("klasör oluşunca içindeki dosya değişiklikleri izleniyor", await hits.pass(before, within: 8))
    withExtendedLifetime(watcher) {}
    return failed
}

/// UI invariants that can be checked without a screen.
@MainActor func selfcheck() async throws -> Int32 {
    // The prices the checks expect are the embedded snapshot's and the hand-made tables': never this Mac's price cache
    // or its model-aliases.json (an alias for claude-opus-5-5 would make the price kind "your alias" and fail them).
    setenv("TOKENBAR_PRICES_PINNED", "1", 1)
    var failed = 0
    func expect(_ name: String, _ cond: Bool) {
        print((cond ? "ok   " : "FAIL ") + name)
        if !cond { failed += 1 }
        fflush(stdout)
    }

    expect("panel sabit boyutu 460x760", PanelView.fixedSize == CGSize(width: 460, height: 760))
    expect("pano açılış boyutu 1280x800", DashboardView.defaultSize == CGSize(width: 1280, height: 800))
    expect("dönem kısayolları ⌘1–6 için altı dönem var", Period.allCases.count == 6)

    failed += try await engineFaultChecks()
    failed += await engineStartChecks()
    failed += layoutChecks(.tr)
    failed += layoutChecks(.en)
    failed += await menuReachabilityChecks(.tr)
    failed += await menuReachabilityChecks(.en)
    failed += await detectedAndPriceChecks(.tr)
    failed += await detectedAndPriceChecks(.en)
    failed += contrastChecks()
    print(failed == 0 ? "UI SELF-CHECK OK" : "\(failed) UI SELF-CHECK FAILED")
    return failed == 0 ? 0 : 1
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "selfcheck" {
    exit(try await selfcheck())
}

/// Made-up usage over the last 110 days for the pictures in `docs/`: a seeded generator, invented tools' mix and sizes.
func demoEvents(now: Double) -> [UsageEvent] {
    // (key prefix, provider, model, share of that tool's calls, input, cache read, cache write, output)
    let mix: [(String, String, String, Double, Int64, Int64, Int64, Int64)] = [
        ("cc", "anthropic", "claude-opus-5-5", 5.0, 9_000, 520_000, 22_000, 4_500),
        ("cc", "anthropic", "claude-sonnet-5-5", 2.0, 6_000, 300_000, 14_000, 3_000),
        ("cc", "anthropic", "claude-haiku-5-5", 1.5, 4_000, 180_000, 8_000, 2_000),
        ("cc", "anthropic", "claude-fable-5-2", 0.7, 8_000, 400_000, 18_000, 4_000),
        ("cx", "openai", "gpt-6-luna", 2.5, 12_000, 260_000, 0, 3_500),
        ("cx", "openai", "gpt-6-astra", 1.0, 14_000, 300_000, 0, 5_000),
        ("cx", "openai", "gpt-6.1-sol", 0.6, 11_000, 240_000, 0, 4_200),
        ("oc", "openrouter", "deepseek-v4.1-flash", 3.0, 16_000, 420_000, 0, 2_800),
        ("oc", "openrouter", "qwen3.8-27b", 1.2, 9_000, 120_000, 0, 1_800),
        ("oc", "openrouter", "glm-5.3", 0.8, 10_000, 150_000, 0, 2_200),
        ("oc", "openrouter", "step-5-preview", 0.5, 8_000, 90_000, 0, 1_600),
        ("ag", "google-antigravity", "gemini-3.8-flash", 1.0, 7_000, 160_000, 0, 1_900),
        ("ag", "google-antigravity", "gemini-3.1-pro-low", 0.3, 9_000, 120_000, 0, 2_400),
        ("qwen", "qwen", "qwen3.8-flash-next", 0.7, 6_000, 60_000, 0, 1_200),
        ("omp", "anthropic", "claude-haiku-5-5", 0.3, 4_000, 90_000, 4_000, 1_300),
        ("devin", "devin", "swe-1-6-slow", 0.15, 5_000, 70_000, 0, 1_500),
        ("kimi", "moonshot", "never-listed-model", 0.1, 3_000, 20_000, 0, 900),
    ]
    var state: UInt64 = 0x9E3779B97F4A7C15
    func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    var events: [UsageEvent] = []
    for day in 0..<110 {
        // Quieter months ago, busier lately, a weekend dip.
        let ramp = 0.15 + 0.85 * pow(1 - Double(day) / 110, 2)
        let weekend = day % 7 >= 5 ? 0.45 : 1.0
        for (n, row) in mix.enumerated() {
            let calls = Int((row.3 * 5.0 * ramp * weekend * (0.4 + 1.2 * next())).rounded())
            for c in 0..<max(calls, 0) {
                let scale = 0.3 + 1.6 * next()
                let when = now - Double(day) * 86_400 - next() * 80_000
                let tokens = TokenCounts(input: Int64(Double(row.4) * scale), cacheRead: Int64(Double(row.5) * scale),
                                         cacheWrite: Int64(Double(row.6) * scale), output: Int64(Double(row.7) * scale))
                events.append(UsageEvent(key: "\(row.0):demo-\(day)-\(n)-\(c)", provider: row.1, model: row.2, timestamp: when,
                                         tokens: tokens, session: "demo-\(day)", file: "demo"))
            }
        }
    }
    return events
}

@MainActor
func snapshot() async throws {
    let period = Period(rawValue: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "7d") ?? .week
    let model = AppModel()
    model.prefs.window = period
    if ProcessInfo.processInfo.environment["TOKENBAR_SNAPSHOT_DEMO"] == "1" {
        // Invented usage for the README pictures: nothing here is read from this machine.
        let demoDir = NSTemporaryDirectory() + "tokenbar-demo-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: demoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: demoDir) }
        let store = try UsageStore(path: demoDir + "/demo.sqlite")
        try store.insertEvents(demoEvents(now: Date().timeIntervalSince1970))
        let book = try store.usageBook()
        model.book = book
        model.report = book.report(for: period)
        model.detected = [.claudeCode, .codex, .opencode, .antigravity, .qwenCode, .ohMyPi, .devin, .kimiCode]
    } else {
        let engine = Engine()
        let book = try await engine.book()
        model.book = book
        model.report = book.report(for: period)
        model.detected = HarnessCatalog.load(home: NSHomeDirectory()).detected()
    }

    func capture<V: View>(_ name: String, size: CGSize, appearance: NSAppearance?, _ content: V) async throws {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.alphaValue = 0          // never visible, but SwiftUI runs its tasks
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .seconds(3))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("\(name): bitmap üretilemedi"); exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        guard let tiff = rep.tiffRepresentation else { print("\(name): tiff yok"); exit(1) }
        let environment = ProcessInfo.processInfo.environment
        let folder = environment["TOKENBAR_SNAPSHOT_DIR"] ?? "/tmp"
        // Pictures of one chosen language carry it in their name, so tr and en do not overwrite each other.
        let path = "\(folder)/tokenbar-\(name)\(environment["TOKENBAR_LANG"] == nil ? "" : "-" + L10n.lang.rawValue).tiff"
        try tiff.write(to: URL(fileURLWithPath: path))
        print("\(name): \(Int(size.width))x\(Int(size.height)) -> \(path)")
    }

    for (suffix, name) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
        let appearance = NSAppearance(named: name)
        try await capture("panel-\(suffix)", size: PanelView.fixedSize, appearance: appearance, PanelView(model: model))
        try await capture("dashboard-\(suffix)", size: DashboardView.defaultSize, appearance: appearance, DashboardView(model: model))
        try await capture("dashboard-narrow-\(suffix)", size: CGSize(width: 900, height: 560), appearance: appearance, DashboardView(model: model))
    }

    // The states a pointer or a click opens.
    guard let report = model.report, let top = report.harnesses.flatMap(\.models).max(by: { $0.cost < $1.cost }) else { return }
    func stage(_ configure: (RibbonStage) -> Void) -> RibbonStage {
        let stage = RibbonStage()
        configure(stage)
        return stage
    }
    let dark = NSAppearance(named: .darkAqua)
    try await capture("panel-hover", size: PanelView.fixedSize, appearance: dark, PanelView(model: model, stage: stage {
        $0.hovered = .flow(top.id)
        $0.hoveredKind = .output
        $0.pointer = CGPoint(x: 180, y: 240)
    }))
    try await capture("panel-open", size: PanelView.fixedSize, appearance: dark, PanelView(model: model, stage: stage { $0.selected = .flow(top.id) }))
    try await capture("panel-total", size: PanelView.fixedSize, appearance: NSAppearance(named: .aqua), PanelView(model: model, stage: stage { $0.selected = .total }))
    try await capture("dashboard-open", size: DashboardView.defaultSize, appearance: dark, DashboardView(model: model, stage: stage { $0.selected = .model(top.info.group) }))
    try await capture("dashboard-expanded", size: DashboardView.defaultSize, appearance: dark, DashboardView(model: model, stage: stage {
        $0.expanded = top.harness
        $0.hovered = .harness(top.harness)
    }))

    // The list of detected tools, with a tool whose token data is not on this Mac (a made-up "Cursor").
    let home = NSTemporaryDirectory() + "tokenbar-snapshot-home-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: home + "/.config/tokenbar", withIntermediateDirectories: true)
    try? #"{"sources": [{"id": "cursor", "name": "Cursor", "family": "open-design-events", "paths": ["~/.cursor/x.jsonl"], "keyPrefix": "cursor"}]}"#
        .write(toFile: home + "/.config/tokenbar/custom-sources.json", atomically: false, encoding: .utf8)
    HarnessCatalog.load(home: home).register()
    try? FileManager.default.removeItem(atPath: home)
    model.detected = Array((model.detected + [HarnessID("cursor")]).prefix(8))
    model.notCountable = [HarnessID("cursor")]
    try await capture("panel-detected", size: PanelView.fixedSize, appearance: dark, PanelView(model: model, stage: stage { $0.showsDetected = true }))
    try await capture("dashboard-detected", size: DashboardView.defaultSize, appearance: dark, DashboardView(model: model, stage: stage { $0.showsDetected = true }))

    // A model priced by a stand-in (nearest model, family, local) shows its kind in the breakdown.
    let standIn = report.harnesses.flatMap(\.models).first { [.near, .approximate, .localCloud, .localFree].contains($0.info.price.entry?.kind) }
    if let standIn {
        try await capture("panel-standin", size: PanelView.fixedSize, appearance: dark, PanelView(model: model, stage: stage { $0.selected = .flow(standIn.id) }))
    }
}

try await snapshot()
