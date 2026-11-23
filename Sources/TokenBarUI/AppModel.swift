import AppKit
import Foundation
import LocalCore
import Observation

/// Observable UI state: owns the engine, the watcher and the current numbers.
/// All heavy work (SQLite, scanning) happens off the main thread; this
/// class only publishes finished values.
@MainActor
@Observable
public final class AppModel {
    /// Harness logs change constantly while agents run; file events scan this often at most.
    private static let eventScanSeconds = 15.0
    private static let timerSeconds = 60.0

    public var prefs = Preferences.load()
    public var book: UsageBook?
    public var report: UsageReport?
    public var menuIcon: NSImage?
    public var issues: [SourceIssue] = []
    public var statusMessage: String?
    /// The tools whose data folder exists on this Mac, as of the last scan.
    public var detected: [HarnessID] = []
    /// The tools found whose token data is not on this Mac.
    public var notCountable: [HarnessID] = []
    /// What the last "update prices" did, in a muted line; a failure goes to `notice` instead.
    public var priceInfo: String?
    public var priceWarning: String?
    public var isRefreshingPrices = false

    private let engine = Engine()
    private var watcher: FileWatcher?
    private var scanInFlight = false
    private var lastScan = Date.distantPast
    private var iconVersion: String?
    private var priceObserver: NSObjectProtocol?

    public init() {
        PriceBook.offline = prefs.offline
    }

    /// A failure or a broken source, named instead of silently shrinking the numbers.
    public var notice: String? {
        var parts: [String] = []
        if let statusMessage { parts.append(statusMessage) }
        parts += issues.map { "\($0.source): \(IssueText.localized($0.message))" }
        if let priceWarning { parts.append(priceWarning) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Every tool the picture can name, for the list behind "Detected: N tools".
    public var detectedTools: [DetectedTool] {
        DetectedTools.list(detected: detected, notCountable: notCountable, report: book?.report(for: .all))
    }

    public func start() {
        PriceBook.startBackgroundRefresh()
        // New prices change the money of rows already in the book, so the book is read again.
        priceObserver = NotificationCenter.default.addObserver(forName: PriceBook.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pricesChanged() }
        }
        watcher = FileWatcher(paths: UsageScanner.watchPaths(home: engine.home)) { [weak self] in
            Task { @MainActor in self?.logsChanged() }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.requestScan(reload: true)
                try? await Task.sleep(for: .seconds(Self.timerSeconds))
            }
        }
    }

    private func logsChanged() {
        if Date().timeIntervalSince(lastScan) >= Self.eventScanSeconds { requestScan(reload: false) }
    }

    /// Incremental scan. Overlapping requests are dropped: FSEvents or the timer fires again
    /// while the logs keep changing. The numbers reload when a scan found rows, and on every
    /// timer tick so calls leave the short periods as they age.
    private func requestScan(reload: Bool) {
        if scanInFlight { return }
        scanInFlight = true
        lastScan = Date()
        Task {
            defer { scanInFlight = false }
            do {
                let result = try await engine.scan()
                let fresh = reload || result.events > 0 ? try await engine.book() : nil
                issues = result.issues
                detected = result.detected
                notCountable = NotCountableBridge.tools(in: result)
                statusMessage = nil
                if let fresh {
                    book = fresh
                    showWindow()
                }
            } catch {
                statusMessage = L10n.t("Tarama hatası: ", "Scan error: ") + IssueText.localized("\(error)")
            }
        }
    }

    /// The catalogues or the alias file were reloaded: read the book again so every row is priced anew.
    private func pricesChanged() {
        Task {
            if let fresh = try? await engine.book() {
                book = fresh
                showWindow()
            }
        }
    }

    /// "Update prices": one pass over the catalogues now, whatever the one-day wait says.
    func updatePrices() {
        guard !isRefreshingPrices else { return }
        isRefreshingPrices = true
        priceWarning = nil
        say(L10n.t("Fiyatlar güncelleniyor…", "Updating prices…"))
        Task {
            let report = await PriceBook.refreshNow()
            isRefreshingPrices = false
            if PriceBook.isOffline {
                say(L10n.t("Çevrimdışı: ağ kullanılmıyor, fiyatlar güncellenmedi.", "Offline: the network is not used, prices were not updated."))
            } else if PriceBook.isPinned {
                say(L10n.t("Fiyatlar sabitlenmiş (TOKENBAR_PRICES_PINNED), güncellenmedi.", "Prices are pinned (TOKENBAR_PRICES_PINNED), not updated."))
            } else if !report.failed.isEmpty {
                let names = report.failed.keys.map(\.displayName).sorted().joined(separator: ", ")
                priceInfo = nil
                priceWarning = L10n.t("Fiyat güncellemesi başarısız: ", "Price update failed: ") + names
            } else {
                say(L10n.t("Fiyatlar güncel, tarih ", "Prices are up to date, dated ") + PriceBook.date)
            }
        }
    }

    /// "Offline": the same as `TOKENBAR_OFFLINE=1`, remembered between runs.
    func setOffline(_ offline: Bool) {
        prefs.offline = offline
        prefs.save()
        PriceBook.offline = offline
        priceWarning = nil
        if offline {
            say(L10n.t("Çevrimdışı: fiyatlar yalnız yerel önbellekten okunur.", "Offline: prices come from the local cache only."))
        } else {
            say(L10n.t("Çevrimiçi: fiyatlar günde bir kez yenilenir.", "Online: prices refresh once a day."))
            PriceBook.startBackgroundRefresh()
        }
    }

    /// A line in the caption that goes away by itself.
    private func say(_ text: String) {
        priceInfo = text
        Task {
            try? await Task.sleep(for: .seconds(12))
            if priceInfo == text { priceInfo = nil }
        }
    }

    func setWindow(_ window: Period) {
        prefs.window = window
        prefs.save()
        showWindow()
    }

    private func showWindow() {
        guard let report = book?.report(for: prefs.window) else { return }
        self.report = report
        guard report.version != iconVersion else { return }
        iconVersion = report.version
        menuIcon = RibbonIcon.render(report)
    }
}
