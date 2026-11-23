/// The English reading of the notes in scripts/price-map.json (the reason a model is priced by a stand-in, a published
/// page or another name). The generated price table keeps the notes in Turkish, as the Windows tables do; the English
/// interface looks each one up by its Turkish text. A note without a line here shows no reason in English, and
/// TokenChecks fails until it has one.
enum PriceNotesEN {
    static let notes: [String: String] = [
    "gizli model, kimliği açıklanmadı ve yalnız ücretsiz sunuldu; vekil fiyat: aynı işlerde kullanılan DeepSeek V4.1 Flash":
        "hidden model, identity not disclosed and offered only for free; stand-in price: DeepSeek V4.1 Flash, used for the same jobs",
    "ücretsiz yönlendirici, yanıtlayan model kayıtlı değil; vekil fiyat: aynı işlerde kullanılan DeepSeek V4.1 Flash":
        "free router, the model that answered is not recorded; stand-in price: DeepSeek V4.1 Flash, used for the same jobs",
    "OpenRouter Flash-Next'i ayrı listelemiyor; en yakını Qwen3.8 Flash. Aynı fiyat: https://www.orcarouter.ai/blog/qwen-3-8-flash-release \"$0.15 per million input tokens\"":
        "OpenRouter does not list Flash-Next separately; the nearest is Qwen3.8 Flash. Same price: https://www.orcarouter.ai/blog/qwen-3-8-flash-release \"$0.15 per million input tokens\"",
    "Qwen3.5-9B'nin ince ayarı, OpenRouter'da yok; en yakını tabanı Qwen3.5-9B":
        "a fine-tune of Qwen3.5-9B, not on OpenRouter; the nearest is its base Qwen3.5-9B",
    "Antigravity'nin model adı; OpenRouter'da ayrı değil":
        "Antigravity's name for the model; not listed separately on OpenRouter",
    "OpenRouter LongCat 2.5'i listelemiyor; en yakını LongCat 2.0":
        "OpenRouter does not list LongCat 2.5; the nearest is LongCat 2.0",
    "yalnız ücretsiz listeleniyor; en yakını ücretli Nemotron 3 Nano 30B A3B":
        "listed only for free; the nearest is the paid Nemotron 3 Nano 30B A3B",
    "Z.ai'de ücretsiz; en yakını GLM-4.5 ailesinin en ucuz ücretlisi GLM 4.5 Air":
        "free at Z.ai; the nearest is GLM 4.5 Air, the cheapest paid model of the GLM-4.5 family",
    "Z.ai'de ücretsiz; en yakını ücretli GLM 4.6V":
        "free at Z.ai; the nearest is the paid GLM 4.6V",
    "Antigravity'nin model adı; en yakını Gemini 3.1 Pro Preview":
        "Antigravity's name for the model; the nearest is Gemini 3.1 Pro Preview",
    "türev model; en yakını Gemma 4 26B-A4B":
        "a derived model; the nearest is Gemma 4 26B-A4B",
    "yalnız ücretsiz listeleniyor; en yakını Cohere'in listedeki en küçük modeli Command R7B":
        "listed only for free; the nearest is Cohere's smallest listed model, Command R7B",
    "yalnız ücretsiz listeleniyor (Recursive, 40B); en yakın boyuttaki açık model Gemma 4 31B":
        "listed only for free (Recursive, 40B); the open model of the nearest size is Gemma 4 31B",
    "yalnız ücretsiz listelendi; en yakını aynı sınıftaki Gemma 4 26B-A4B":
        "listed only for free; the nearest is Gemma 4 26B-A4B of the same class",
    "opencode Zen gizli modeli; yaygın kanı GLM-4.6 tabanlı olduğu, doğrulanmadı":
        "opencode Zen hidden model; widely believed to be based on GLM-4.6, not verified",
    "opencode Zen'in Beam Free'si; OpenRouter'daki ücretli karşılığı Reflection Beam 1.0":
        "opencode Zen's Beam Free; its paid counterpart on OpenRouter is Reflection Beam 1.0",
    "opencode Zen gizli modeli, kimliği açıklanmadı; vekil fiyat: aynı işlerde kullanılan DeepSeek V4.1 Flash":
        "opencode Zen hidden model, identity not disclosed; stand-in price: DeepSeek V4.1 Flash, used for the same jobs",
    "gizli model; MiniMax M3.1 Flash olduğu bildirildi, opencode Zen de onu ücretsiz listeliyor":
        "hidden model; reported to be MiniMax M3.1 Flash, and opencode Zen lists that one for free",
    "OpenRouter'da yok; en yakını aynı sınıftaki görsel model Qwen3 VL 30B A3B":
        "not on OpenRouter; the nearest is the vision model of the same class, Qwen3 VL 30B A3B",
    "OpenRouter'da yok; en yakını listedeki en küçük görsel model Gemma 3 4B":
        "not on OpenRouter; the nearest is the smallest listed vision model, Gemma 3 4B",
    "OpenRouter'da yok (LiteLLM'de nvidia_nim satırı fiyatsız); en yakını aynı ailenin en küçük ücretli modeli Nemotron 3.5 Lightning":
        "not on OpenRouter (the LiteLLM nvidia_nim row has no price); the nearest is the smallest paid model of the same family, Nemotron 3.5 Lightning",
    "yalnız ücretsiz listeleniyor (opencode, Recursive Flint v1.0 ile aynı 40B model); en yakın boyuttaki açık model Gemma 4 31B":
        "listed only for free (opencode; the same 40B model as Recursive Flint v1.0); the open model of the nearest size is Gemma 4 31B",
    "OpenRouter, models.dev ve Kilo yalnız ücretsiz sürümü listeliyor; aynı yapımcının OpenRouter'daki tek ücretli modeli ERNIE-Light-DT-1.0":
        "OpenRouter, models.dev and Kilo list only the free version; the only paid model of the same maker on OpenRouter is ERNIE-Light-DT-1.0",
    "Devin fiyat yayımlamıyor; fiyat izleme sayfasının SWE 1.6 satırı":
        "Devin does not publish a price; the SWE 1.6 row of a price-tracking page",
    "aynı model, boyut adıyla (120B A12B); sağlayıcılar böyle de yazıyor":
        "the same model under its size name (120B A12B); providers write it that way too",
    "-trial deneme planı işaretidir; API eşdeğeri liste fiyatıdır":
        "-trial marks a trial plan; the API equivalent is the list price",
    ]
}
