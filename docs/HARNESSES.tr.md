# Desteklenen araçlar

TokenBar, yapay zekâ kodlama araçlarının Mac'inde zaten yazdığı kullanım loglarını okur. Ayar yapılmaz: bir aracın veri klasörü varsa TokenBar onu sayar.

Her araç token kaydını makinende tutmaz; bu yüzden araçlar iki sınıfa ayrılır. Uygulama da aynı ayrımı gösterir.

1. **Sayılan:** yerelde token sayılarıyla bir log var ve TokenBar onu okur.
2. **Algılanır, sayılamaz:** araç token verisini üreticinin sunucusunda tutar ya da yerel dosyalarında token sayısı yoktur. TokenBar onu "algılandı" diye listeler, sayı göstermez, hiçbir zaman tahmin etmez.

English: [HARNESSES.md](HARNESSES.md) (ana belge; kodla ayrışırsa kod doğrudur).

Bu sayfa `Sources/LocalCore/HarnessCatalog.swift`, `HarnessG2.swift` ve `Sources/LocalCore/Scanner*.swift` dosyalarındaki katalogdan yazılmıştır.

## Tablolar nasıl okunur

- **Kök:** TokenBar'ın baktığı yer, ev klasörünün (`~`) altında. Köklerden biri varsa araç *algılanmış* sayılır. Birden çok kök, aracın verisini bunlardan herhangi birinde tutabileceği anlamına gelir.
- **Ortam değişkeni:** aracın verisini başka yere taşıyan değişken. Tanımlı ve boş değilse kökün yerine geçer. TokenBar bu değişkenleri yalnız gerçek ev klasörü için izler, taranması istenen başka bir ev için izlemez.
- **Anahtar öneki:** TokenBar'ın her çağrı için sakladığı tekilleştirme anahtarının başı (`cc:...`). Dosya kaç kez okunursa okunsun ya da kopyalansın çağrı bir kez saklanır; önek iki aracın çakışmasını önler.
- **Durum:**
  - **doğrulandı (gerçek veri):** gerçek loglarla, bağımsız bir Python okuyucusuyla (`scripts/oracle.py`) karşılaştırılarak denendi.
  - **kaynak şemasından, gerçek veriyle denenmedi:** aracın belgelenmiş ya da incelenmiş dosya biçiminden yazıldı ve `Sources/TokenChecks` içinde kurmaca bir evle sınandı. Gerçek veride çalıştırılmadı. Yanlış sayarsa örnek bir dosyayla [new-harness issue](https://github.com/dr-ofn/TokenBar/issues/new?template=new-harness.yml) aç.

## Sayılan araçlar

| Araç | Kök | Ortam değişkeni | Önek | Ne okunur | Durum |
|---|---|---|---|---|---|
| Claude Code | `~/.claude`, `~/.config/claude` | `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME` | `cc` | `projects/**/*.jsonl`; istek kimliğine göre tekilleştirilir | doğrulandı |
| Codex | `~/.codex` | `CODEX_HOME` | `cx` | `sessions`, `archived_sessions`: `rollout-*.jsonl` ve `.jsonl.zst` (sonuncusu `zstd` komutunu ister: `brew install zstd`); birikimli sayaçların farkı, sıfırlanmalar algılanır | doğrulandı |
| opencode | `~/.local/share/opencode` | `XDG_DATA_HOME` | `oc` | `opencode.db`, salt okunur açılır | doğrulandı |
| oh-my-pi | `~/.omp` | yok | `omp` | `agent/sessions/**/*.jsonl`; `toolResult` satırları sayılmaz | doğrulandı |
| Qwen Code | `~/.qwen` | `QWEN_HOME` | `qwen`, `qwenc` | `usage/token-usage-*.jsonl` ve `usage_record.jsonl` (`qwen`); yeni sohbet dosyaları yalnız bunlar yoksa (`qwenc`) | `qwen` doğrulandı, `qwenc` kaynak şemasından |
| Kimi Code | `~/.kimi-code` | `KIMI_CODE_HOME` | `kimi` | `sessions/**/wire.jsonl` | doğrulandı |
| Devin | `~/.local/share/devin` | yok | `devin` | `cli/transcripts/*.json`; dökümü olmayan oturumlar için CLI'nin `sessions.db`'si | doğrulandı |
| Antigravity | `~/.gemini/antigravity-cli` | yok | `ag` | `conversations/*.db` (SQLite içinde protobuf), salt okunur | doğrulandı |
| Crush | `~/.local/share/crush` | `XDG_DATA_HOME`, `CRUSH_GLOBAL_DATA` | `crush` | `projects.json`'ın adını verdiği her projenin veritabanı | kaynak şemasından |
| Goose | `~/.local/share/goose/sessions`, `~/Library/Application Support/goose/sessions`, aynı ikisi `Block/` altında, `~/.local/share/goose` | `GOOSE_PATH_ROOT` | `goose` | `sessions.db`, değişince bütün okunur | kaynak şemasından |
| Factory Droid | `~/.factory` | yok | `droid` | `sessions/**/*.settings.json` | kaynak şemasından |
| Amp | `~/.local/share/amp` | `AMP_DATA_DIR` | `amp` | `threads/T-*.json` | kaynak şemasından |
| OpenHands | `~/.openhands/conversations`, `~/.openhands` | `OPENHANDS_CONVERSATIONS_DIR`, `OPENHANDS_PERSISTENCE_DIR` | `oh` | her konuşmanın `base_state.json`'ı | kaynak şemasından |
| Gemini CLI | `~/.gemini/tmp` | `GEMINI_CLI_HOME` (veri o zaman `$GEMINI_CLI_HOME/.gemini/tmp`'de) | `gem` | `tmp` altındaki sohbet dosyaları | kaynak şemasından |
| Pi | `~/.pi/agent` | `PI_CODING_AGENT_DIR` | `pi` | `sessions/**/*.jsonl` | kaynak şemasından |
| GitHub Copilot CLI | `~/.copilot` | `COPILOT_HOME` | `cop` | `session-state` olay dosyaları | kaynak şemasından |
| Junie | `~/.junie` | yok | `jun` | `sessions` olay dosyaları | kaynak şemasından |
| Codebuff | `~/.config/manicode`, `~/.config/manicode-dev`, `~/.config/manicode-staging` | `CODEBUFF_DATA_DIR` (üçünün yerine geçer) | `cbuf` | `projects` sohbet dosyaları | kaynak şemasından |
| Mistral Vibe | `~/.vibe` | `VIBE_HOME` | `vibe` | `logs/session` | kaynak şemasından |
| Augment | `~/.augment` | yok | `aug` | `sessions` | kaynak şemasından |
| Cline | Code, Code - Insiders, Cursor, Windsurf, VSCodium, Kiro, Positron, Trae ve Antigravity için `~/Library/Application Support/<editör>/User/globalStorage/saoudrizwan.claude-dev`; `~/.cline/data` | yok | `cline` | `tasks/<id>/ui_messages.json`; CLI'nin `sessions/<id>/<id>.messages.json`'ı | kaynak şemasından |
| Roo Code | aynı editörler, `rooveterinaryinc.roo-cline` eklentisi | yok | `roo` | `tasks/<id>/ui_messages.json` | kaynak şemasından |
| Kilo Code | aynı editörler, `kilocode.kilo-code` eklentisi; ve `~/.local/share/kilo` (sürüm 7 ve CLI, opencode'un veritabanı düzeni) | CLI için `XDG_DATA_HOME` | `kilocode`, `kilo` | görev klasörleri; CLI veritabanı | kaynak şemasından |
| GitHub Copilot Chat | `~/Library/Application Support/Code` ve `Code - Insiders`: `User/workspaceStorage`, `User/globalStorage/emptyWindowChatSessions` | yok | `copilot-chat` | `chatSessions/<id>.jsonl` (ya da `.json`) | kaynak şemasından |
| Continue | `~/.continue` | `CONTINUE_GLOBAL_DIR` | `continue` | `dev_data/0.2.0/tokensGenerated.jsonl` | kaynak şemasından |
| Zed | `~/Library/Application Support/Zed` | yok | `zed` | `threads/threads.db` (eksik `zstd` komutu tek bir sorun olarak adıyla yazılır) | kaynak şemasından |

Cursor içine kurulu bir Cline eklentisi Cursor olarak değil Cline olarak sayılır (Roo ve Kilo için de aynı editör klasörleri kök olduğundan aynısı geçerlidir).

Kendi eklediğin araçlar ([özel kaynaklar](#kendi-kaynakların-custom-sourcesjson)) aynı listede görünür. `open-design-events` okuyucusu (Open Design'ın `events.jsonl` çalıştırmaları) bu tür girdiler içindir: yerleşik bir araca bağlı değildir.

## Algılanır, sayılamaz

TokenBar bunları "algılandı, token verisi yerelde tutulmuyor" diye gösterir. Onlar için sayı uydurmaz.

| Araç | Kök | Neden sayılmıyor |
|---|---|---|
| Cursor | `~/Library/Application Support/Cursor`, `~/.cursor` | Yerel `tokenCount` alanı `0`; kullanım Cursor'ın sunucusunda |
| Windsurf | `~/.codeium/windsurf`, `~/Library/Application Support/Windsurf` | Yerel token logu bulunamadı; kullanım üreticinin sunucusunda |
| Trae | `~/Library/Application Support/Trae` | Yerel token logu bulunamadı; kullanım üreticinin sunucusunda |
| Kiro | `~/.kiro`, `~/Library/Application Support/kiro-cli`, `~/Library/Application Support/Kiro` | Yerel loglarda Auto ajanında sıfır token, ötekinde kredi var; token sayısı yok |
| Warp | `~/Library/Group Containers/*.dev.warp` | Token toplamları `warp.sqlite` içinde, giriş/çıktı ayrımı olmadan; uygulama grubu klasörü gerçek bir Mac'te görülmedi: adı yazılır, hiç sayılmaz |
| Amazon Q | `~/Library/Application Support/amazon-q` | CLI yerelde token sayısı kaydetmez (istek üst verisinde yok) |

Kaçırdığımız bir yerel kayıt gösterebilirsen [new-harness issue](https://github.com/dr-ofn/TokenBar/issues/new?template=new-harness.yml) aç.

## Kendi kaynakların: `custom-sources.json`

Dosyalarını yukarıdaki okuyuculardan biri zaten anlayan her araç, koda dokunmadan eklenebilir (beş okuyucuda yeni araç olarak, kalanlarda yerleşik bir aracın ek klasörleri olarak; tablonun altına bak). `~/.config/tokenbar/custom-sources.json` oluştur:

```json
{
  "sources": [
    {
      "id": "open-design",
      "name": "Open Design",
      "family": "open-design-events",
      "paths": ["~/Library/Application Support/Open Design/namespaces/release-stable/data/runs"],
      "keyPrefix": "od",
      "hue": 325
    },
    {
      "id": "my-fork",
      "name": "Benim opencode çatalım",
      "family": "opencode-sqlite",
      "paths": ["~/work/fork-data"],
      "keyPrefix": "myfork",
      "recursive": true
    }
  ]
}
```

| Alan | Anlamı |
|---|---|
| `id` | Kaynakları tek araç altında toplar. Harf, rakam, `.`, `_`, `-`. Aynı `id`'li iki girdi tek araç görünür. |
| `name` | Gösterilen ad. Varsayılan `id`. |
| `family` | Kullanılacak okuyucu: `anthropic-jsonl`, `codex-rollout`, `opencode-sqlite`, `open-design-events`, `omp-jsonl`, `qwen-usage`, `kimi-wire`, `devin-transcripts`, `antigravity-sqlite`, `crush-sqlite`, `goose-sqlite`, `droid-settings`, `amp-threads`, `openhands-state`, `gemini-chats`, `pi-jsonl`, `copilot-events`, `junie-events`, `codebuff-chats`, `vibe-sessions`, `augment-sessions`, `qwen-chats`, `cline-tasks`, `roo-tasks`, `copilot-chat`, `continue-tokens`, `zed-threads` ya da `not-countable` (yalnız algıla). Bunlardan yalnız beşi kendi seçtiğin bir `id` ile yeni araç başlatabilir: tablonun altına bak. |
| `paths` | `~/` ya da `/` ile başlayan klasör veya dosyalar. Zorunlu. |
| `keyPrefix` | Tekilleştirme anahtarı öneki: küçük harf, rakam ve `-`. Önekini kendisi sabitleyen bir ailede ona eşit olmalı; yoksa varsayılan, küçük harfli `id`. Yerleşik bir aracın kullandığı önek reddedilir. |
| `hue` | Derece cinsinden renk. İsteğe bağlı; yoksa renk `id`'den türetilir ve çalıştırmalar arasında aynı kalır. |
| `recursive` | `opencode-sqlite` klasörleri için: veritabanlarını her derinlikte ara. Varsayılan `true`. |

**Hangi aileler yeni araç başlatabilir.** Her okuyucu kendi tekilleştirme önekini yazar (`cc`, `cx`, `zed`, ...) ve bir çağrının hangi araca ait olduğu o önekle bulunur. Bu yüzden öneki sabit bir aile, kendi seçtiğin bir `id` ile yeni araç başlatamaz: girdi, o öneki taşıyan yerleşik aracın `id`'sini kullanmalıdır; o zaman yalnız o araca klasör eklemiş olur (örneğin ikinci bir hesabın `~/.claude` klasörü). Böyle bir aileyle yeni bir `id` verilirse girdi reddedilir (`"cc" önekini claude-code kullanıyor`).

Yeni bir `id` ile açılabilen aileler: `opencode-sqlite`, `open-design-events`, `cline-tasks`, `roo-tasks`, `not-countable`.

Diğer 23 aile, yerleşik aracının `id`'sini alır:

| Aile | Gereken `id` |
|---|---|
| `anthropic-jsonl` | `claude-code` |
| `codex-rollout` | `codex` |
| `omp-jsonl` | `oh-my-pi` |
| `qwen-usage` | `qwen-code` |
| `kimi-wire` | `kimi-code` |
| `devin-transcripts` | `devin` |
| `antigravity-sqlite` | `antigravity` |
| `crush-sqlite` | `crush` |
| `goose-sqlite` | `goose` |
| `droid-settings` | `factory-droid` |
| `amp-threads` | `amp` |
| `openhands-state` | `openhands` |
| `gemini-chats` | `gemini-cli` |
| `pi-jsonl` | `pi` |
| `copilot-events` | `copilot-cli` |
| `junie-events` | `junie` |
| `codebuff-chats` | `codebuff` |
| `vibe-sessions` | `mistral-vibe` |
| `augment-sessions` | `augment` |
| `qwen-chats` | `qwen-code` |
| `copilot-chat` | `copilot-chat` |
| `continue-tokens` | `continue` |
| `zed-threads` | `zed` |

Bir girdideki hata uygulamada adıyla yazılır (`custom-sources.json: ...`) ve yalnız o girdi atlanır.

## Kendi fiyat adların: `model-aliases.json`

TokenBar bir modeli fiyat kataloglarından fiyatlar (bkz. README). Çalıştırdığın modelin adı hiçbir katalogda yoksa ya da başka bir fiyat istiyorsan `~/.config/tokenbar/model-aliases.json` ekle. Takma ad, bütün tabloların ve katalogların önüne geçer.

```json
{
  "aliases": {
    "my-qwen-q4": "qwen3.8-27b",
    "sidecar": {"as": "claude-haiku-5-5"},
    "house-model": {"input": 1, "output": 4, "cacheRead": 0.1, "name": "House Model"},
    "home-7b": {"input": 0.1, "output": 0.3, "kind": "near",
                "source": "OpenRouter en yakın: acme/small, aynı aile ve boyut"},
    "test-server": {"free": true}
  },
  "localProviders": ["my-mac-mini", "studio"]
}
```

- Bir metin ya da `{"as": "model"}`: o modelle aynı fiyatlanır.
- `{"input": ..., "output": ...}`: 1M token başına USD. `cacheRead`, `cacheWrite` ve `name` isteğe bağlı. `source` (dökümde görünen not) ve `kind` (vekil fiyat için `"near"`, başka yerde yayımlanmış fiyat için `"other"`) de isteğe bağlı.
- `{"free": true}`: maliyet yok.
- `localProviders`: kendi makinelerinde model çalıştıran sunucular. Böyle bir sunucudaki ya da `-4bit`, `-q4_k_m` gibi yerel kuantizasyon sonekli model, bulut karşılığı varsa onun fiyatından hesaplanır, yoksa maliyeti sıfırdır.
- Kısa ad için yazılan takma ad, hesap numaralı, efor sözcüklü ya da bağlam boyutlu varyantlarını da (`my-model-high`, `my-model-256k`) yaklaşık olarak işaretleyerek kapsar.
- Adlar TokenBar'ın bütün model adlarını katladığı gibi eşleşir: küçük harf, sağlayıcı yolu yok, `.` ve `_` `-` okunur.
- Dosya `"aliases"` anahtarı olmadan yalnız takma adlardan da oluşabilir. Dosya yoksa ya da okunamıyorsa takma ad yoktur, hata değildir. `TOKENBAR_PRICES_PINNED=1` ile (kontrollerin kullandığı) dosya yok sayılır.

## TokenBar'ın kendisine araç eklemek

[CONTRIBUTING.md](../CONTRIBUTING.md): katalog girdisi, kurmaca ev fixture'ı ve `scripts/oracle.py`'de karşılığı.
