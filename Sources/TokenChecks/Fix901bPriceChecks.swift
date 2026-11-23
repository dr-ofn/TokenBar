import Foundation
import LocalCore

// The price-engine findings of the second 9.0.1 review. Called once from `main.swift`; everything runs without the network:
// catalogues are small raw texts and the feed is driven by a scripted fetcher. The Python engines answer the same cases in
// windows/tests/test_prices901b.py.
//
//   1  the price cache gives back the prices the whole catalogue gave (route row equal to its winner, ids that differ in
//      case, cache schema 2, a schema 1 file is asked for again in full)
//   2  an alias chain of four steps is priced, five are not
//   3  an alias loop is unpriced
//   4  a JSON null is "not given"

private func pair(_ name: String) -> [Double]? {
    ModelPrice(model: name).entry.map { (e: PriceEntry) -> [Double] in [e.rates.input, e.rates.output] }
}

private func five(_ name: String) -> [Double]? {
    ModelPrice(model: name).entry.map { (e: PriceEntry) -> [Double] in
        [e.rates.input, e.rates.output, e.rates.cacheRead, e.rates.cacheWrite, e.rates.cacheWrite1h]
    }
}

func fix901bPriceChecks(tempDir: () throws -> String) throws {
    // MARK: 1  the cache gives back the prices the whole catalogue gave

    do {
        let openRouter = #"""
        {"data":[{"id":"acme/m","name":"Acme: M","pricing":{"prompt":"0.000001","completion":"0.000002"}},
                 {"id":"acme/m:nitro","name":"Acme: M","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}
        """#
        let liteLLM = #"""
        {"acme/m":{"mode":"chat","input_cost_per_token":3e-6,"output_cost_per_token":6e-6},
         "acme/m:nitro":{"mode":"chat","input_cost_per_token":5e-6,"output_cost_per_token":1e-5}}
        """#
        let routesOnly = #"{"acme/m:nitro":{"mode":"chat","input_cost_per_token":5e-6,"output_cost_per_token":1e-5}}"#
        // Ids that differ only in case, at two prices: the id index must hold the same row whole and cut.
        var cased: [String: Any] = [:]
        for n in 0..<24 {
            let cheap: [String: Any] = ["mode": "chat", "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6]
            let dear: [String: Any] = ["mode": "chat", "input_cost_per_token": 3e-6, "output_cost_per_token": 4e-6]
            cased["Vend\(n)/Mod\(n)"] = n % 2 == 0 ? cheap : dear
            cased["vend\(n)/mod\(n)"] = n % 2 == 0 ? dear : cheap
        }
        let casedText = String(decoding: try JSONSerialization.data(withJSONObject: cased), as: UTF8.self)
        let raw: [PriceSource: Data] = [.openrouter: Data(openRouter.utf8), .litellm: Data(liteLLM.utf8)]
        let rawCased: [PriceSource: Data] = [.litellm: Data(casedText.utf8)]
        let dir = URL(fileURLWithPath: try tempDir(), isDirectory: true)
        let fetcher = ScriptedFetcher()
        fetcher.script(.openrouter, .ok(openRouter, etag: "o1"))
        fetcher.script(.litellm, .ok(liteLLM, etag: "l1"))
        fetcher.script(.modelsdev, .fail)
        var config = PriceFeed.Config(cacheDirectory: dir, offline: false, fetcher: fetcher)
        config.ttl = 3600
        let feed = PriceFeed(config)
        _ = feed.refreshBlocking()
        let names = ["acme/m", "acme/m:nitro", "ACME/M:NITRO"]
        func priced(_ catalogs: PriceCatalogs) -> [[Double]] {
            PriceBook.install(catalogs: catalogs)
            return names.map { (name: String) -> [Double] in pair(name) ?? [] }
        }
        let fresh = priced(PriceCatalogs.fromRaw(raw))
        let cached = priced(feed.loadLocal())
        check("cache 1: fresh, OpenRouter's exact acme/m:nitro ($1/$2) wins over LiteLLM's ($5/$10)", fresh[1] == [1, 2] && fresh[2] == [1, 2])
        check("cache 1: a route row at its winner's price stays in the cache, so the cached price is the fresh one", cached == fresh)
        let schema = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("prices-openrouter.json")))) as? [String: Any])?["schema"] as? Int
        check("cache 1: the cache is written as schema 2", schema == 2)

        // Ids that differ only in case.
        let casedDir = URL(fileURLWithPath: try tempDir(), isDirectory: true)
        let casedFetcher = ScriptedFetcher()
        casedFetcher.script(.litellm, .ok(casedText, etag: nil))
        casedFetcher.script(.openrouter, .fail)
        casedFetcher.script(.modelsdev, .fail)
        let casedFeed = PriceFeed(PriceFeed.Config(cacheDirectory: casedDir, offline: false, fetcher: casedFetcher))
        _ = casedFeed.refreshBlocking()
        let lowerNames = (0..<24).map { (n: Int) -> String in "vend\(n)/mod\(n)" }
        let casedFresh = priced2(PriceCatalogs.fromRaw(rawCased), lowerNames)
        let casedCached = priced2(casedFeed.loadLocal(), lowerNames)
        check("cache 1: ids that differ only in case price the same whole and cut", casedFresh == casedCached)
        // ... and the whole catalogue is the same on every build of it (the id index no longer follows dictionary order).
        let again = priced2(PriceCatalogs.fromRaw(rawCased), lowerNames)
        check("cache 1: the whole catalogue's id index does not depend on the order the rows came in", again == casedFresh)

        // A catalogue of routes alone has no winner: its cache file is the exact rows, and is read.
        let routeDir = URL(fileURLWithPath: try tempDir(), isDirectory: true)
        let routeFetcher = ScriptedFetcher()
        routeFetcher.script(.litellm, .ok(routesOnly, etag: nil))
        routeFetcher.script(.openrouter, .fail)
        routeFetcher.script(.modelsdev, .fail)
        let routeFeed = PriceFeed(PriceFeed.Config(cacheDirectory: routeDir, offline: false, fetcher: routeFetcher))
        _ = routeFeed.refreshBlocking()
        check("cache 1: a catalogue of routes alone is still read from its cache", routeFeed.loadLocal().origins[.litellm] != nil
              && { if case .cache = routeFeed.loadLocal().origins[.litellm] ?? PriceCatalogs.Origin.none { return true } else { return false } }()
              && priced2(routeFeed.loadLocal(), ["acme/m:nitro"]) == [[5, 10]])

        // A schema 1 cache (9.0.0): read, but the next refresh sends no ETag and asks for the whole catalogue.
        let oldDir = URL(fileURLWithPath: try tempDir(), isDirectory: true)
        let oldFile = #"{"schema":1,"source":"openrouter","fetched":1793900000,"etag":"\"old\"","rows":{"acme/m":[1,2,0,0,0,[],"Acme: M"]}}"#
        try write(oldDir.path + "/prices-openrouter.json", oldFile)
        let oldFetcher = ScriptedFetcher()
        oldFetcher.script(.openrouter, .ok(openRouter, etag: "\"new\""))
        oldFetcher.script(.litellm, .fail)
        oldFetcher.script(.modelsdev, .fail)
        var oldConfig = PriceFeed.Config(cacheDirectory: oldDir, offline: false, fetcher: oldFetcher)
        oldConfig.now = { Date(timeIntervalSince1970: 1793900060) }
        let oldFeed = PriceFeed(oldConfig)
        PriceBook.install(catalogs: oldFeed.loadLocal())
        check("cache 1: a schema 1 cache file is still read", pair("acme/m") == [1, 2])
        let report = oldFeed.refreshBlocking()
        check("cache 1: a schema 1 cache is asked for again whatever its age, without its ETag",
              report.updated == [.openrouter] && oldFetcher.lastEtag(.openrouter) == nil)
        PriceBook.install(catalogs: oldFeed.loadLocal())
        check("cache 1: the rewritten cache is schema 2 and holds the route row", pair("acme/m:nitro") == [1, 2]
              && ((try? JSONSerialization.jsonObject(with: Data(contentsOf: oldDir.appendingPathComponent("prices-openrouter.json")))) as? [String: Any])?["schema"] as? Int == 2)
    } catch { check("cache 1: \(error)", false) }
    PriceBook.install(catalogs: .embedded)

    // MARK: 2, 3  alias chains and loops

    do {
        let catalogue = #"""
        {"zq-base":{"mode":"chat","input_cost_per_token":2.5e-6,"output_cost_per_token":1e-5},
         "azure/zq-self":{"mode":"chat","input_cost_per_token":9e-6,"output_cost_per_token":9e-6},
         "zq-cat":{"mode":"chat","input_cost_per_token":7e-6,"output_cost_per_token":8e-6}}
        """#
        let file = #"""
        {"aliases":{"a":"b","b":"c","c":"d","d":"e","e":{"input":5,"output":10},
                    "f1":"f2","f2":"f3","f3":"f4","f4":"f5","f5":"f6","f6":{"input":5,"output":10},
                    "m1":{"as":"m2"},"m2":"m3","m3":{"as":"m4"},"m4":"m5","m5":"zq-cat",
                    "n1":"n2","n2":"n3","n3":"n4","n4":"n5","n5":"n6","n6":"zq-cat",
                    "zq-loop":"zq-base","zq-base":"zq-loop","x":{"as":"y"},"y":{"as":"z"},"z":"x",
                    "zq-self":"azure/zq-self"}}
        """#
        PriceBook.install(catalogs: PriceCatalogs.fromRaw([.litellm: Data(catalogue.utf8)]), aliases: UserAliases(json: Data(file.utf8)))
        check("alias chain: a to e (four steps) is priced $5/$10", pair("a") == [5, 10] && pair("b") == [5, 10])
        check("alias chain: f1 to f6 (five steps) is unpriced, f2 to f6 (four) is priced", ModelPrice(model: "f1").entry == nil && pair("f2") == [5, 10])
        check("alias chain: four alias-to-alias steps and then the catalogue is priced, five are not", pair("m1") == [7, 8] && ModelPrice(model: "n1").entry == nil)
        check("alias loop: two names that name each other are unpriced, not priced from the catalogue row of one of them",
              ModelPrice(model: "zq-loop").entry == nil && ModelPrice(model: "zq-base").entry == nil)
        check("alias loop: three names in a ring are unpriced", ModelPrice(model: "x").entry == nil && ModelPrice(model: "y").entry == nil && ModelPrice(model: "z").entry == nil)
        check("alias loop: an alias that names the catalogue row of its own name is no loop", pair("zq-self") == [9, 9] && ModelPrice(model: "zq-self").entry?.kind == .alias)
    }
    PriceBook.install(catalogs: .embedded)

    // MARK: 4  a JSON null is "not given"

    do {
        let file = #"""
        {"aliases":{"zq-nulls":{"input":10,"output":20,"cacheRead":null,"cacheWrite":null},
                    "zq-zero":{"input":10,"output":20,"cacheRead":0,"cacheWrite":0},
                    "zq-half":{"input":10,"output":20,"cacheRead":2,"cacheWrite":null}}}
        """#
        PriceBook.install(catalogs: .embedded, aliases: UserAliases(json: Data(file.utf8)))
        check("null: an alias with cacheRead and cacheWrite null prices the cache like input", five("zq-nulls") == [10, 20, 10, 10, 10])
        check("null: an explicit 0 stays a price, a null beside a given one is not given", five("zq-zero") == [10, 20, 0, 0, 0] && five("zq-half") == [10, 20, 2, 10, 10])

        let openRouter = #"""
        {"data":[{"id":"acme/tier-1","name":"Acme: Tier 1","pricing":{"prompt":"0.000001","completion":"0.000004","input_cache_read":"0.0000001","input_cache_write":"0.00000125",
          "overrides":[{"min_prompt_tokens":200000,"prompt":"0.000002","completion":null,"input_cache_read":null,"input_cache_write":null,"input_cache_write_1h":null}]}}]}
        """#
        let modelsDev = #"""
        {"acme":{"models":{
          "tier-2":{"name":"Tier 2","cost":{"input":1,"output":4,"cache_read":0.1,"cache_write":1.25,
            "tiers":[{"tier":{"type":"context","size":200000},"input":2,"output":null,"cache_read":null,"cache_write":null}]}},
          "tier-3":{"name":"Tier 3","cost":{"input":1,"output":4,"cache_read":0.1,"cache_write":1.25,
            "context_over_200k":{"input":2,"output":null,"cache_read":null,"cache_write":null}}}}}}
        """#
        PriceBook.install(catalogs: PriceCatalogs.fromRaw([.openrouter: Data(openRouter.utf8), .modelsdev: Data(modelsDev.utf8)]))
        for name in ["acme/tier-1", "acme/tier-2", "acme/tier-3"] {
            let tier = ModelPrice(model: name).entry?.tiers.first
            let got = tier.map { (t: PriceEntry.Tier) -> [Double] in [t.rates.input, t.rates.output, t.rates.cacheRead, t.rates.cacheWrite] } ?? []
            check("null: a null in a tier of \(name) keeps the base row's price (input 2, output 4, cache 0.1 and 1.25)",
                  got.count == 4 && abs(got[0] - 2) < 1e-9 && abs(got[1] - 4) < 1e-9 && abs(got[2] - 0.1) < 1e-9 && abs(got[3] - 1.25) < 1e-9)
        }
    }
    PriceBook.install(catalogs: .embedded)
}

private func priced2(_ catalogs: PriceCatalogs, _ names: [String]) -> [[Double]] {
    PriceBook.install(catalogs: catalogs)
    return names.map { (name: String) -> [Double] in pair(name) ?? [] }
}
