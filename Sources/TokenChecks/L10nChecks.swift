import Foundation
import LocalCore

/// The two interface languages: which one is chosen, and that numbers, dates and price sources read right in both.
func l10nChecks() {
    defer { L10n.setLanguage(nil) }

    check("TOKENBAR_LANG wins over the system language",
          L10n.detect(environment: ["TOKENBAR_LANG": "en"], preferred: ["tr-TR"]) == .en
          && L10n.detect(environment: ["TOKENBAR_LANG": "TR"], preferred: ["en-US"]) == .tr
          && L10n.detect(environment: ["TOKENBAR_LANG": "en_US"], preferred: []) == .en)
    check("a Turkish system gets Turkish, every other one English",
          L10n.detect(environment: [:], preferred: ["tr-TR", "en-US"]) == .tr
          && L10n.detect(environment: [:], preferred: ["en-US", "tr-TR"]) == .en
          && L10n.detect(environment: [:], preferred: ["de-DE"]) == .en
          && L10n.detect(environment: [:], preferred: []) == .en
          && L10n.detect(environment: ["TOKENBAR_LANG": "fr"], preferred: ["tr"]) == .tr)

    L10n.setLanguage(.tr)
    check("tr: numbers, percent and periods",
          UsageText.tokens(1_404_730_925) == "1,40 milyar" && UsageText.tokens(1_186_548) == "1,2 milyon"
          && UsageText.tokens(113_600) == "113,6 bin" && UsageText.compact(5_180_000_000) == "5,18 mr"
          && UsageText.percent(12, of: 100) == "%12" && UsageText.percent(0.1, of: 100) == "<%1"
          && Period.week.label == "7 gün" && Period.week.shortLabel == "7 gün" && UsageText.calls(1) == "1 çağrı"
          && UsageText.perMillion(1.23, tokens: 1_000_000) == "$1,230/M")

    L10n.setLanguage(.en)
    check("en: money, tokens and percent use English conventions",
          UsageText.money(3070.43) == "$3,070.43" && UsageText.money(0.001) == "<$0.01" && UsageText.money(0) == "$0"
          && UsageText.tokens(1_404_730_925) == "1.40B" && UsageText.tokens(1_186_548) == "1.2M"
          && UsageText.tokens(113_600) == "113.6K" && UsageText.tokens(999) == "999"
          && UsageText.compact(5_180_000_000) == "5.18B"
          && UsageText.percent(12, of: 100) == "12%" && UsageText.percent(0.1, of: 100) == "<1%" && UsageText.percent(0, of: 0) == "0%"
          && UsageText.perMillion(1.23, tokens: 1_000_000) == "$1.230/M" && UsageText.short(1352.4) == "$1,352")
    check("en: periods, counts and plural",
          Period.week.label == "7 days" && Period.oneHour.shortLabel == "1h" && Period.all.shortLabel == "All"
          && UsageText.calls(1) == "1 call" && UsageText.calls(1234) == "1,234 calls"
          && UsageText.moreModels(3) == "3 more models" && UsageText.unpricedCount(2) == "2 unpriced"
          && UsageText.empty(.all) == "No calls yet")
    check("en: the $0 point says unpriced only when every model there is unpriced",
          RibbonLayout.zeroCostTitle(free: ["a", "b"], unpriced: ["a", "b"]) == "2 unpriced"
          && RibbonLayout.zeroCostTitle(free: ["a", "b", "c"], unpriced: ["a"]) == "3 free or unpriced"
          && RibbonLayout.zeroCostTitle(free: ["local"], unpriced: []) == "1 free or unpriced")
    let day = UsageText.tideTick(time: 1793970000, period: .week)
    check("en: tide ticks name the month first", day.hasPrefix("Nov") && !day.contains("Kas"))

    // The price a row shows: where it came from, in both languages.
    let opus = ModelPrice(model: "claude-opus-5-5")
    check("en: a catalogue price names its catalogue and id",
          opus.entry.map { UsageText.sourceText($0).hasPrefix("OpenRouter: anthropic/claude-opus-5.5") } == true
          && UsageText.priceKindLabel(opus) == "OpenRouter" && UsageText.priceNote(opus).hasPrefix("Per 1M tokens: input $4.00")
          && UsageText.priceNote(opus).contains(" Source: OpenRouter: anthropic/claude-opus-5.5"))
    check("en: the source texts of the resolver read in English",
          UsageText.englishSource("yerel → bulut karşılığı: LiteLLM: gemini/gemini-4-neon") == "local → cloud equivalent: LiteLLM: gemini/gemini-4-neon"
          && UsageText.englishSource("yerel, bulut karşılığı yok") == "local, no cloud counterpart"
          && UsageText.englishSource("yaklaşık: foo-xhigh → foo (models.dev: acme/foo)") == "approximate: foo-xhigh → foo (models.dev: acme/foo)"
          && UsageText.englishSource("kullanıcı takma adı: kısa → claude-opus-5-5 (OpenRouter: anthropic/claude-opus-5.5)")
              == "your alias: kısa → claude-opus-5-5 (OpenRouter: anthropic/claude-opus-5.5)"
          && UsageText.englishSource("kullanıcı takma adı: x → ücretsiz") == "your alias: x → free"
          && UsageText.englishSource("OpenRouter en yakın: deepseek/deepseek-v4.1-flash (gizli model, vekil fiyat)") == "OpenRouter, nearest paid model: deepseek/deepseek-v4.1-flash"
          && UsageText.englishSource("OpenRouter: anthropic/claude-haiku-5.5 (yerel takma ad: haiku)") == "OpenRouter: anthropic/claude-haiku-5.5 (local alias: haiku)"
          && UsageText.englishSource("https://example.com/pricing \"x\"") == "https://example.com/pricing \"x\"")
    let local = ModelPrice(model: "never-listed-local", provider: "ollama")
    check("en: a local model without a cloud counterpart is free and says so",
          UsageText.priceKindLabel(local) == "local, free" && UsageText.priceNote(local).hasPrefix("A model that runs on this Mac")
          && UsageText.cost(0, local) == "$0")
    let unknown = ModelPrice(model: "never-listed-cloud")
    check("en: no price", UsageText.cost(0, unknown) == "no price" && UsageText.priceKindLabel(unknown) == "no price"
          && UsageText.priceNote(unknown).hasPrefix("Not in the price table"))
    check("a near or family price carries a tilde, an exact one does not",
          ModelPrice(model: "crouton-alpha").isApproximate && UsageText.cost(1.5, ModelPrice(model: "crouton-alpha")) == "~$1.50"
          && !opus.isApproximate && UsageText.cost(1.5, opus) == "$1.50")
    check("en: source warnings read in English, unknown ones stay as written",
          IssueText.localized("custom-sources.json: \"sources\" dizisi yok") == "custom-sources.json: \"sources\" array is missing"
          && IssueText.localized("zstd yok: brew install zstd (.jsonl.zst arşivleri okunamıyor) (3 dosya atlandı)")
              == "zstd is missing: brew install zstd (.jsonl.zst archives cannot be read) (3 files skipped)"
          && IssueText.localized("bambaşka bir mesaj") == "bambaşka bir mesaj")

    L10n.setLanguage(.tr)
    check("tr: the same warnings stay untouched", IssueText.localized("dosya kayıtları okunamadı") == "dosya kayıtları okunamadı"
          && UsageText.cost(0, unknown) == "fiyat yok" && UsageText.priceKindLabel(local) == "yerel, ücretsiz")
}
