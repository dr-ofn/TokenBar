import CryptoKit
import Foundation
import LocalCore

// tokenbar-cli: index every harness log on this Mac and print a report.
//
//   tokenbar-cli [--window 1h|5h|24h|7d|30d|all] [--db PATH] [--home DIR] [--rebuild] [--no-scan] [--json]
//                [--offline] [--prices-now]
//   tokenbar-cli --index     show index info (file count, event count, last scan)
//
//   --home DIR     read that home's logs; without --db the index is the app's folder/homes/<hash of DIR>/usage.sqlite
//   --offline      never touch the network (what TOKENBAR_OFFLINE=1 says, too)
//   --prices-now   fetch the price catalogues now, whatever the one-day wait says (alias: --refresh-prices, as on Windows)

var windowArg = "24h"
var dbPath = UsageStore.defaultPath
var dbGiven = false
var home = NSHomeDirectory()
var homeGiven = false
var rebuild = false
var scan = true
var jsonOut = false
var indexOnly = false
var offline = false
var pricesNow = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--window", "-w": windowArg = args.next() ?? windowArg
    case "--db": dbPath = args.next() ?? dbPath; dbGiven = true
    case "--home": home = args.next() ?? home; homeGiven = true
    case "--rebuild": rebuild = true
    case "--no-scan": scan = false
    case "--json": jsonOut = true
    case "--index": indexOnly = true
    case "--offline": offline = true
    case "--prices-now", "--refresh-prices": pricesNow = true
    case "-h", "--help":
        print("usage: tokenbar-cli [--window 1h|5h|24h|7d|30d|all] [--db PATH] [--home DIR] [--rebuild] [--no-scan] [--json] [--offline] [--prices-now] | --index")
        exit(0)
    default:
        FileHandle.standardError.write(Data((L10n.t("bilinmeyen argüman: \(a)", "unknown argument: \(a)") + "\n").utf8))
        exit(1)
    }
}

// Another home (--home) without --db gets an index of its own beside the user's: its calls must not go into the user's
// own index, and the index is not written into the home that is read (it may be a read-only backup). The folder is the
// first 16 hex of the SHA-256 of the home's real path, as on Windows. Without --home the path is the app's, as ever.
// The home is read by its real path, so two spellings of one home (a link, /tmp and /private/tmp) are one set of files.
/// The real path, as Python's os.path.realpath gives it: a home that is not there (yet) resolves through the nearest
/// folder above it that is, so the index it gets does not change once it appears.
func realHome(_ path: String) -> String {
    var head = URL(fileURLWithPath: path).standardizedFileURL.path
    var tail: [String] = []
    while true {
        if let p = realpath(head, nil) {
            defer { free(p) }
            return ([String(cString: p)] + tail.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
        }
        if head == "/" || head.isEmpty { return path }
        tail.append((head as NSString).lastPathComponent)
        head = (head as NSString).deletingLastPathComponent
    }
}
if homeGiven {
    home = realHome(home)
    let digest = SHA256.hash(data: Data(home.utf8)).map { (b: UInt8) -> String in String(format: "%02x", b) }.joined().prefix(16)
    if !dbGiven { dbPath = (UsageStore.defaultPath as NSString).deletingLastPathComponent + "/homes/\(digest)/usage.sqlite" }
}

guard let window = Period(rawValue: windowArg) else {
    FileHandle.standardError.write(Data((L10n.t("geçersiz pencere: \(windowArg)", "invalid window: \(windowArg)") + "\n").utf8))
    exit(1)
}

// --rebuild drops every row; refuse it for the live index, where the loss is permanent.
func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
if rebuild, canonical(dbPath) == canonical(UsageStore.defaultPath) {
    FileHandle.standardError.write(Data(("tokenbar-cli: " + L10n.t("--rebuild reddedildi: veritabanı varsayılan konumda (\(dbPath))", "--rebuild refused: the database is at the default location (\(dbPath))") + "\n").utf8))
    exit(2)
}

do {
    let store = try UsageStore(path: dbPath)
    if indexOnly {
        let stats = try store.storageStats()
        let last = store.meta("lastScan").flatMap(Double.init).map { Date(timeIntervalSince1970: $0).formatted() } ?? "-"
        print(L10n.t("kayıt: ", "records: ") + "\(try store.eventCount())" + L10n.t(" · dosya: ", " · files: ") + "\((try store.fileRecords()).count)" + L10n.t(" · son tarama: ", " · last scan: ") + last)
        print(L10n.t("tablo: \(stats.pages) sayfa (\(stats.pages * 4096 / 1024 / 1024) MB), boş \(stats.free) sayfa", "table: \(stats.pages) pages (\(stats.pages * 4096 / 1024 / 1024) MB), \(stats.free) free pages"))
        exit(0)
    }
    if rebuild { try store.reset() }
    // This home's own price names too (its model-aliases.json), not the Mac user's.
    PriceBook.useHome(home)
    if offline { PriceBook.offline = true }
    if pricesNow {
        // One anonymous GET per catalogue, only when asked; offline (the flag or TOKENBAR_OFFLINE) it asks nothing.
        final class Box: @unchecked Sendable { var report = PriceRefreshReport() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached {
            box.report = await PriceBook.refreshNow()
            done.signal()
        }
        done.wait()
        let r = box.report
        FileHandle.standardError.write(Data((L10n.t("fiyatlar: ", "prices: ")
            + "\(r.updated.count) updated, \(r.notModified.count) not modified, \(r.fresh.count) fresh, \(r.failed.count) failed, \(r.skipped.count) skipped\n").utf8))
    }
    // Names and colours of the tools in this home's custom-sources.json, scan or not.
    HarnessCatalog.load(home: home).register()

    var detected: [HarnessID] = []
    if scan {
        let result = UsageScanner(store: store, home: home).scan()
        detected = result.detected
        for issue in result.issues {
            FileHandle.standardError.write(Data((L10n.t("kaynak hatası", "source error") + " · \(issue.source): \(IssueText.localized(issue.message))\n").utf8))
        }
        if !jsonOut {
            let parts = result.sources.filter { $0.filesRead > 0 }.map { "\($0.name) \($0.filesRead) " + L10n.t("dosya", "files") + ", \($0.events) " + L10n.t("kayıt", "records") }
            print(L10n.t("tarama: \(result.bytesRead) bayt · ", "scan: \(result.bytesRead) bytes · ") + parts.joined(separator: " · "))
            print(L10n.t("algılanan araçlar: ", "detected tools: ") + (detected.isEmpty ? "-" : detected.map(\.name).joined(separator: ", ")))
        }
    }

    let report = try store.usageBook().report(for: window)

    if jsonOut {
        let data = try ReportJSON.serialize(ReportJSON.object(report, window: window, detected: detected))
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("\(window.label): \(UsageText.tokens(report.counts.total))\(UsageText.tokenWord) · \(UsageText.money(report.cost))\(UsageText.moneyWord) · \(UsageText.totalLine(report))")
        for h in report.harnesses {
            print("\(h.harness.name): \(UsageText.tokens(h.tokens)) · \(UsageText.money(h.cost)) · \(UsageText.calls(h.calls))")
            for m in h.models {
                print("  \(m.info.name) [\(m.info.provider)]  \(UsageText.tokens(m.tokens)) · \(UsageText.cost(m.cost, m.info.price)) · \(UsageText.calls(m.calls))")
            }
        }
        if report.harnesses.isEmpty { print(L10n.t("  (bu aralıkta çağrı yok)", "  (no calls in this window)")) }
    }
} catch {
    FileHandle.standardError.write(Data("tokenbar-cli: \(error)\n".utf8))
    exit(1)
}