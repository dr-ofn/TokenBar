import Foundation
import LocalCore

// Dev tools behind `TokenChecks <tool>`; check.sh never passes an argument.
//   priceprobe                         stdin "provider|model" lines -> one JSON line each (what the price rules answer)
//   priceparity LITELLM MODELSDEV      raw catalogue files -> which rows the index would keep, as JSON on stdout
// scripts/price-parity.py runs the same names through scripts/pricelib.py and compares.

func entryJSON(_ e: PriceEntry?) -> [String: Any] {
    guard let e else { return [:] }
    let tiers: [[String: Any]] = e.tiers.map { ["minPrompt": $0.minPrompt, "input": $0.rates.input, "output": $0.rates.output, "cacheRead": $0.rates.cacheRead,
                                               "cacheWrite": $0.rates.cacheWrite, "cacheWrite1h": $0.rates.cacheWrite1h] }
    return ["kind": "\(e.kind)", "source": e.source, "name": e.name, "catalog": e.catalog ?? NSNull(), "catalogID": e.catalogID ?? NSNull(),
            "input": e.rates.input, "output": e.rates.output, "cacheRead": e.rates.cacheRead, "cacheWrite": e.rates.cacheWrite,
            "cacheWrite1h": e.rates.cacheWrite1h, "tiers": tiers]
}

func runPriceTool(_ args: [String]) -> Bool {
    guard args.count > 1 else { return false }
    switch args[1] {
    case "priceprobe":
        // --aliases FILE: the user's alias file.
        var aliases = UserAliases.empty
        if let i = args.firstIndex(of: "--aliases"), i + 1 < args.count { aliases = UserAliases.load(path: args[i + 1]) }
        PriceBook.install(catalogs: .embedded, aliases: aliases)
        while let line = readLine() {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let e = ModelPrice(model: parts[1], provider: parts[0]).entry
            let obj: [String: Any] = ["provider": parts[0], "model": parts[1], "entry": e == nil ? NSNull() : entryJSON(e)]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
        }
        return true
    case "pricerefresh":
        // One real pass against the network into a scratch cache directory: TokenChecks pricerefresh DIR [--ttl SECONDS]
        guard args.count >= 3 else { fputs("usage: TokenChecks pricerefresh DIR [--ttl SECONDS]\n", stderr); exit(2) }
        var config = PriceFeed.Config(cacheDirectory: URL(fileURLWithPath: args[2]), offline: PriceFeed.environmentOffline)
        if let i = args.firstIndex(of: "--ttl"), i + 1 < args.count, let ttl = Double(args[i + 1]) { config.ttl = ttl }
        let feed = PriceFeed(config)
        let started = Date()
        let report = feed.refreshBlocking()
        print("updated \(report.updated.map(\.rawValue)) notModified \(report.notModified.map(\.rawValue)) fresh \(report.fresh.map(\.rawValue)) "
              + "failed \(report.failed) skipped \(report.skipped.map(\.rawValue)) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        let local = feed.loadLocal()
        print("origins \(local.origins.mapValues { "\($0)" })")
        PriceBook.install(catalogs: local)
        for name in ["claude-opus-5-5", "kimi-k3.1-pro", "gemini-4-neon", "deepseek-v4-flash-0731"] {
            let e = ModelPrice(model: name).entry
            print("\(name): \(e.map { "\($0.kind)" } ?? "none") \(e?.source ?? "") in \(e?.rates.input ?? 0) out \(e?.rates.output ?? 0)")
        }
        return true
    case "priceparity":
        guard args.count >= 4, let ll = FileManager.default.contents(atPath: args[2]), let md = FileManager.default.contents(atPath: args[3]) else {
            fputs("usage: TokenChecks priceparity LITELLM.json MODELSDEV.json\n", stderr)
            exit(2)
        }
        let kept = PriceTools.keptRows(litellm: ll, modelsdev: md)
        let data = (try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        return true
    default:
        return false
    }
}
