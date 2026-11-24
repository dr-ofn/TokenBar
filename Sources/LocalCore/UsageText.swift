import Foundation

/// Every sentence the picture puts on screen.
public enum UsageText {
    /// A label's font size when its text is `width` wide and only `room` is free: scaled down to
    /// fit, but never to zero, a negative size or NaN, which a font cannot take. A label with
    /// no room at all keeps a size too small to read rather than a broken one.
    public static func fittedFontSize(_ size: Double, room: Double, width: Double) -> Double {
        guard size.isFinite, size > 0 else { return 1 }
        guard width.isFinite, width > 0, room.isFinite, room < width else { return size }
        return max(min(size, 6), size * max(room, 0) / width)
    }

    /// Numbers in the interface language: Turkish groups thousands with "." and has a decimal comma
    /// (1.234,5), English the other way round (1,234.5). A fresh formatter per call keeps the code
    /// thread-safe without any locking.
    private static func decimal(_ v: Double, _ digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private static func date(_ time: Double, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = format
        return f.string(from: Date(timeIntervalSince1970: time))
    }

    /// Turkish 1_404_730_925 → "1,40 milyar", 1_186_548 → "1,2 milyon", 113_600 → "113,6 bin";
    /// English "1.40B", "1.2M", "113.6K".
    public static func tokens(_ n: Int64) -> String {
        let turkish = L10n.lang == .tr
        // The unit is chosen after the rounding: 999 950 is "1,0 milyon" (999,95 rounds to 1000,0), never "1.000,0 bin".
        if n >= 999_950_000 { return decimal(Double(n) / 1e9, 2) + (turkish ? " milyar" : "B") }
        if n >= 999_950 { return decimal(Double(n) / 1e6, 1) + (turkish ? " milyon" : "M") }
        if n >= 1000 { return decimal(Double(n) / 1e3, 1) + (turkish ? " bin" : "K") }
        return String(n)
    }

    /// The same number for a label beside the picture: "5,18 mr", "352,9 mn" (English: as `tokens`).
    public static func compact(_ n: Int64) -> String {
        tokens(n).replacingOccurrences(of: " milyar", with: " mr")
            .replacingOccurrences(of: " milyon", with: " mn")
    }

    /// "12 çağrı", "1 call", "2 calls".
    public static func calls(_ n: Int) -> String {
        count(n) + " " + L10n.plural(n, tr: "çağrı", one: "call", many: "calls")
    }

    /// The word after the big token number in the picture's header.
    public static var tokenWord: String { L10n.t(" token", " tokens") }
    /// The word after the big dollar number in the picture's header.
    public static var moneyWord: String { L10n.t(" API eşdeğeri", " API equivalent") }
    /// The last tick of the tide's axis.
    public static var now: String { L10n.t("şimdi", "now") }

    public static func count(_ n: Int) -> String { decimal(Double(n), 0) }

    /// "$3.070,43", "<$0,01", "$0".
    public static func money(_ usd: Double) -> String {
        if usd <= 0 { return "$0" }
        if usd < 0.01 { return L10n.t("<$0,01", "<$0.01") }
        return "$" + decimal(usd, 2)
    }

    public static var costLabel: String { L10n.t("Maliyet", "Cost") }
    public static var priceTypeLabel: String { L10n.t("Fiyat türü", "Price type") }
    public static var noPrice: String { L10n.t("fiyat yok", "no price") }

    /// The cost of a row: its money, or why there is none. A price that is only an approximation
    /// (the nearest model, the model's family) carries a "~".
    public static func cost(_ usd: Double, _ price: ModelPrice) -> String {
        guard price.isPriced else { return noPrice }
        return (price.isApproximate && usd > 0 ? "~" : "") + money(usd)
    }

    public static func kindName(_ kind: TokenKind) -> String {
        switch kind {
        case .cacheRead: return L10n.t("Cache okuma", "Cache read")
        case .input: return L10n.t("Giriş", "Input")
        case .cacheWrite: return L10n.t("Cache yazma", "Cache write")
        case .output: return L10n.t("Çıktı", "Output")
        }
    }

    /// The exact numbers the token kinds don't show. Reasoning is part of the output and
    /// shows only when the source reports it.
    public static func breakdown(_ t: TokenCounts) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if t.reasoning > 0 { rows.append((L10n.t("Akıl yürütme", "Reasoning"), count(Int(t.reasoning)))) }
        let hit = Int((t.cacheHitRate * 100).rounded())
        rows += [(L10n.t("Toplam", "Total"), count(Int(t.total))),
                 (L10n.t("Cache isabeti", "Cache hit rate"), L10n.t("%\(hit)", "\(hit)%"))]
        return rows
    }

    /// One muted line under an open harness.
    public static func line(_ h: HarnessStat) -> String {
        L10n.t("giriş", "input") + " \(tokens(h.counts.input)) · " + L10n.t("cache okuma", "cache read") + " \(tokens(h.counts.cacheRead)) · "
            + L10n.t("cache yazma", "cache write") + " \(tokens(h.counts.cacheWrite)) · " + L10n.t("çıktı", "output")
            + " \(tokens(h.counts.output)) · " + calls(h.calls)
    }

    /// A per-million rate; three decimals once two would round small prices to $0,00.
    private static func rate(_ usd: Double) -> String {
        "$" + decimal(usd, usd > 0 && usd < 0.1 ? 3 : 2)
    }

    /// Short name of how a price was found: the catalogue, or what kind of stand-in it is.
    public static func priceKindLabel(_ price: ModelPrice) -> String {
        guard let entry = price.entry else { return noPrice }
        switch entry.kind {
        case .openrouter: return "OpenRouter"
        case .litellm: return "LiteLLM"
        case .modelsdev: return "models.dev"
        case .near: return L10n.t("yaklaşık (en yakın model)", "approximate (nearest model)")
        case .approximate: return L10n.t("yaklaşık (model ailesi)", "approximate (model family)")
        case .other: return L10n.t("başka yayın", "published elsewhere")
        case .alias: return L10n.t("takma ad", "your alias")
        case .localCloud: return L10n.t("yerel → bulut karşılığı", "local → cloud equivalent")
        case .localFree: return L10n.t("yerel, ücretsiz", "local, free")
        }
    }

    /// Where a price row came from, in words: "LiteLLM: gemini/gemini-4-neon". The generated tables and the
    /// resolver write these in Turkish; the English reading rebuilds them from the same parts.
    public static func sourceText(_ entry: PriceEntry) -> String {
        L10n.lang == .tr ? entry.source : englishSource(entry.source)
    }

    public static func englishSource(_ source: String) -> String {
        func split(_ text: String) -> (head: String, inner: String?) {
            guard let open = text.range(of: " (") else { return (text, nil) }
            var inner = String(text[open.upperBound...])
            if inner.hasSuffix(")") { inner.removeLast() }
            return (String(text[..<open.lowerBound]), inner)
        }
        func word(_ text: String) -> String { String(text.prefix { $0 != " " }) }
        if let rest = source.dropPrefix("yerel → bulut karşılığı: ") { return "local → cloud equivalent: " + englishSource(rest) }
        if source == "yerel, bulut karşılığı yok" { return "local, no cloud counterpart" }
        if let rest = source.dropPrefix("yaklaşık: ") {
            let (head, inner) = split(rest)
            return "approximate: " + head + (inner.map { " (" + englishSource($0) + ")" } ?? "")
        }
        if let rest = source.dropPrefix("kullanıcı takma adı: ") {
            let (head, inner) = split(rest)
            let words = head.replacingOccurrences(of: "→ ücretsiz", with: "→ free")
                .replacingOccurrences(of: "→ elle yazılmış fiyat", with: "→ hand-written price")
            return "your alias: " + words + (inner.map { " (" + englishSource($0) + ")" } ?? "")
        }
        func reason(_ inner: String?) -> String { inner.flatMap { PriceNotesEN.notes[$0] }.map { " (" + $0 + ")" } ?? "" }
        if let rest = source.dropPrefix("OpenRouter en yakın: ") { return "OpenRouter, nearest paid model: " + word(rest) + reason(split(rest).inner) }
        for catalog in ["OpenRouter: ", "LiteLLM: ", "models.dev: "] {
            guard let rest = source.dropPrefix(catalog) else { continue }
            var text = catalog + word(rest)
            if let tail = split(rest).inner {
                if tail.hasPrefix("yerel takma ad: ") { text += " (local alias: " + tail.dropFirst("yerel takma ad: ".count) + ")" }
                else if tail == "yerel kuant" { text += " (local quant)" }
                else { text += reason(tail) }
            }
            return text
        }
        // A published page and its quote, then the note: `https://… "quote" (note)`.
        for (turkish, english) in PriceNotesEN.notes where source.hasSuffix(" (" + turkish + ")") {
            return String(source.dropLast(turkish.count + 2)) + " (" + english + ")"
        }
        return source
    }

    /// Unit prices and where they came from.
    public static func priceNote(_ price: ModelPrice) -> String {
        guard let entry = price.entry else { return L10n.t("Fiyat tablosunda yok, maliyete girmedi.", "Not in the price table, left out of the cost.") }
        let source = L10n.t(" Kaynak: ", " Source: ") + sourceText(entry)
        if entry.kind == .localFree { return L10n.t("Bu Mac'te çalışan model, ücretsiz sayıldı.", "A model that runs on this Mac, counted as free.") + source }
        let r = entry.rates
        var text = L10n.t("1 milyon token: giriş ", "Per 1M tokens: input ") + rate(r.input) + L10n.t(", çıktı ", ", output ") + rate(r.output)
            + L10n.t(", cache okuma ", ", cache read ") + rate(r.cacheRead) + L10n.t(", cache yazma ", ", cache write ") + rate(r.cacheWrite) + "."
        if !entry.tiers.isEmpty { text += L10n.t(" Uzun istemde üst fiyat uygulanır.", " A higher rate applies to long prompts.") }
        return text + source
    }

    /// How many unpriced model names the total's note spells out; the rest are counted (the whole list is `tokenbar-cli --json`'s).
    public static let totalNoteModelLimit = 20
    /// The longest a single model name is written there.
    public static let totalNoteNameCharacters = 80

    public static func totalNote(_ r: UsageReport) -> String {
        var text = L10n.t("API eşdeğeri, gerçek fatura değil: abonelikle çalışan çağrılar da liste fiyatından hesaplanır. Fiyatlar \(PriceBook.date) tarihli. Web arama ücretleri dahil değil.",
                          "API equivalent, not a real bill: calls made on a subscription are priced at list prices too. Prices dated \(PriceBook.date). Web search fees are not included.")
        if !r.unpriced.isEmpty {
            text += L10n.t(" Fiyatı bulunamayan, maliyete girmeyen modeller: ", " Models with no price, left out of the cost: ") + unpricedNames(r.unpriced) + "."
        }
        return text
    }

    /// The first `totalNoteModelLimit` names, then "and N more": a tool that writes a new model name on every call must
    /// not make a note as long as the log (the same shape as the scan warnings' "and N more").
    private static func unpricedNames(_ models: [ModelInfo]) -> String {
        let shown = models.prefix(totalNoteModelLimit).map { (m: ModelInfo) -> String in
            m.id.count > totalNoteNameCharacters ? String(m.id.prefix(totalNoteNameCharacters)) + "…" : m.id
        }
        var text = shown.joined(separator: ", ")
        if models.count > totalNoteModelLimit {
            text += ", " + L10n.t("ve \(models.count - totalNoteModelLimit) tane daha", "and \(models.count - totalNoteModelLimit) more")
        }
        return text
    }

    /// The line under the total: calls, price date and how many models have no price.
    public static func totalLine(_ r: UsageReport) -> String {
        var text = calls(r.callCount) + L10n.t(" · fiyatlar ", " · prices ") + PriceBook.date
        if !r.unpriced.isEmpty { text += " · " + unpricedModels(r.unpriced.count) }
        return text
    }

    public static func summary(_ r: UsageReport) -> String {
        "\(r.period.shortLabel): \(tokens(r.counts.total))" + tokenWord + ", \(money(r.cost))" + moneyWord
    }

    public static var reading: String {
        L10n.t("Soldaki kalınlık token, sağdaki kalınlık dolar. Şerit sivrilirse o token ucuzdur.",
               "Thickness on the left is tokens, on the right dollars. If a ribbon narrows, those tokens are cheap.")
    }

    /// "3 model fiyatsız", "3 unpriced": the line under the total.
    public static func unpricedModels(_ n: Int) -> String {
        L10n.t("\(n) model fiyatsız", "\(n) unpriced")
    }
    /// The picture's last right label: "1 fiyatsız", "1 unpriced".
    public static func unpricedCount(_ n: Int) -> String { L10n.t("\(n) fiyatsız", "\(n) unpriced") }
    /// The same label when some of those models are free (a local model with no cloud counterpart), not unpriced.
    public static func freeOrUnpricedCount(_ n: Int) -> String { L10n.t("\(n) ücretsiz ya da fiyatsız", "\(n) free or unpriced") }
    /// The picture's label for the bands too thin to name: "4 model daha", "4 more models".
    public static func moreModels(_ n: Int) -> String { L10n.t("\(n) model daha", n == 1 ? "1 more model" : "\(n) more models") }
    public static var smallModelsTitle: String { L10n.t("Küçük modeller", "Small models") }
    public static var unpricedModelsTitle: String { L10n.t("Fiyatsız modeller", "Unpriced models") }

    /// Money without cents once cents stop mattering: "$1.352", "$84,40".
    public static func short(_ usd: Double) -> String {
        usd >= 100 ? "$" + decimal(usd, 0) : money(usd)
    }

    public static func groupCost(_ g: ModelGroup) -> String {
        if g.isUnpriced { return noPrice }
        return (g.stats.contains { $0.info.price.isApproximate && $0.cost > 0 } ? "~" : "") + money(g.cost)
    }

    /// What a row really paid per million tokens. Always three decimals so the column lines up: "$1,230/M".
    public static func perMillion(_ usd: Double, tokens: Int64) -> String {
        guard usd > 0, tokens > 0 else { return "–" }
        return "$" + decimal(usd / Double(tokens) * 1_000_000, 3) + "/M"
    }

    /// What an empty picture says. Only a shorter period can be left for a longer one.
    public static func empty(_ period: Period) -> String {
        period == .all ? L10n.t("Henüz çağrı yok", "No calls yet")
                       : L10n.t("Bu dönemde çağrı yok. Daha uzun bir dönem seç.", "No calls in this period. Pick a longer one.")
    }

    /// A share of some whole, always in "%…" form. A zero share is shown as "%0":
    /// "<%1" would claim it is nonzero, and an empty string leaves fixed "()" behind.
    public static func percent(_ part: Double, of whole: Double) -> String {
        guard whole > 0, part > 0 else { return L10n.t("%0", "0%") }
        let share = part / whole * 100
        return share < 1 ? L10n.t("<%1", "<1%") : L10n.t("%" + decimal(share, 0), decimal(share, 0) + "%")
    }

    /// One token kind of a model, where the pointer is on that strand.
    public static func kindNote(_ kind: TokenKind, of m: ModelStat) -> String {
        let t = m.counts[kind], d = m.parts[kind]
        return "\(kindName(kind)): \(tokens(t))\(tokenWord) (\(percent(Double(t), of: Double(m.tokens)))), \(money(d)) (\(percent(d, of: m.parts.total)))"
    }

    /// The axis label of a moment in a period.
    public static func tideTick(time: Double, period: Period) -> String {
        let withinDay = (period.seconds ?? .infinity) <= 86_400
        return date(time, withinDay ? "HH:mm" : dayFormat)
    }

    /// Day and month: "23 Kas", "Nov 23".
    private static var dayFormat: String { L10n.t("d MMM", "MMM d") }

    /// The two scales of the tide, each linear on its own.
    public static func tideScale(tokens n: Int64, dollars: Double) -> String {
        L10n.t("Yukarı token, en yoğun \(tokens(n)) · aşağı dolar, en yoğun \(money(dollars))",
               "Up: tokens, peak \(tokens(n)) · down: dollars, peak \(money(dollars))")
    }

    /// What one bucket of the tide holds.
    public static func tideHover(start: Double, size: Double, tokens n: Int64, dollars: Double) -> String {
        let end = start + size
        let range = size < 86_400 ? date(start, dayFormat + " HH:mm") + "–" + date(end, "HH:mm")
                                  : date(start, dayFormat) + "–" + date(end, dayFormat)
        return "\(range): \(tokens(n))\(tokenWord), \(money(dollars))"
    }

    /// One line about what the pointer is on.
    public static func hover(_ selection: UsageSelection, _ r: UsageReport) -> String {
        switch selection {
        case .flow(let id):
            guard let m = r.model(id) else { return id }
            return "\(m.harness.name) · \(m.info.name): \(tokens(m.tokens))\(tokenWord), \(cost(m.cost, m.info.price)), \(calls(m.calls))"
        case .harness(let harness):
            guard let h = r.harnesses.first(where: { $0.harness == harness }) else { return harness.name }
            return "\(h.harness.name): \(tokens(h.tokens))\(tokenWord) (\(percent(Double(h.tokens), of: Double(r.counts.total)))), \(money(h.cost)) (\(percent(h.cost, of: r.cost)))"
        case .model(let key):
            guard let g = r.group(key) else { return key }
            return "\(g.name): \(tokens(g.tokens))\(tokenWord) (\(percent(Double(g.tokens), of: Double(r.counts.total)))), \(groupCost(g)) (\(percent(g.cost, of: r.cost)))"
        case .list(let title, let keys):
            return "\(title): " + L10n.t("\(keys.count) model, dökümü tıklayınca açılır",
                                         "\(keys.count) " + (keys.count == 1 ? "model" : "models") + ", click to open the breakdown")
        case .total:
            return summary(r)
        }
    }
}

extension Period {
    public var shortLabel: String {
        switch self {
        case .oneHour: return L10n.t("1 sa", "1h")
        case .fiveHours: return L10n.t("5 sa", "5h")
        case .day: return L10n.t("24 sa", "24h")
        case .week: return L10n.t("7 gün", "7d")
        case .month: return L10n.t("30 gün", "30d")
        case .all: return L10n.t("Tümü", "All")
        }
    }
}

extension ModelPrice {
    /// The price is a stand-in: the nearest model's, or the model family's.
    public var isApproximate: Bool {
        guard let kind = entry?.kind else { return false }
        return kind == .near || kind == .approximate
    }
}

extension String {
    /// What follows `prefix`, or nil when the text does not start with it.
    fileprivate func dropPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}
