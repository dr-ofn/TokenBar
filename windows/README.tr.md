# Windows için TokenBar

[English](README.md) · **Türkçe**

Windows için TokenBar, yapay zekâ kodlama araçlarınızın kendi yerel günlüklerinden saydığı token'ları gösteren ve bu kullanımın API fiyatlarıyla ne tutacağını hesaplayan bir sistem tepsisi uygulamasıdır. [macOS için TokenBar](../README.tr.md)'ın Windows sürümüdür: aynı araçlar, aynı fiyat kuralları, aynı toplamlar (testler, kurmaca bir ev klasöründe Mac uygulamasının kendi sayımlarıyla karşılaştırır).

> **Durum:** kod, kurmaca ev klasörleriyle ve Mac uygulamasındakiyle aynı denetimlerle macOS'ta sınandı. **Gerçek bir Windows bilgisayarında henüz çalıştırılmadı:** tepsi simgesi, pencere, PyInstaller derlemesi ve otomatik başlatma, kütüphanelerinin belgelerinden yazıldı; `.github/workflows/windows.yml` CI işi bunları yalnızca başsız çalışabildiği ölçüde sınar. Bir şey bozuksa [sorun açın](https://github.com/dr-ofn/TokenBar/issues).

## Ne yapar

- **Tepsi simgesi**, ipucunda toplam tutarla. Tıklayınca pencere açılır.
- **Pencere:** dönem düğmeleri (1 sa, 5 sa, 24 sa, 7 gün, 30 gün, Tümü), toplam dolar ve token; altında her araç ve onun altında her model: token, dolar, milyon token başına fiyat (girdi / çıktı) ve çağrı sayısı.
- **Algılandı, sayılamaz:** Cursor, Windsurf, Trae, Kiro, Warp ve Amazon Q kuruluysa listelenir, uydurma sayı gösterilmez: token verisini sağlayıcının sunucusunda ya da token sayısı olmayan günlüklerde tutarlar.
- **26 araç sayılır** (Claude Code, Codex, opencode, oh-my-pi, Qwen Code, Kimi Code, Devin, Antigravity, Crush, Goose, Factory Droid, Amp, OpenHands, Gemini CLI, Pi, GitHub Copilot CLI, Junie, Codebuff, Mistral Vibe, Augment, Cline, Roo Code, Kilo Code, GitHub Copilot Chat, Continue, Zed). Her birinin Windows'ta verisini nerede tuttuğu ve neyin doğrulandığı [docs/HARNESSES.md](docs/HARNESSES.md) dosyasında.
- **Fiyatlar güncel kalır:** gömülü anlık görüntü (LiteLLM, models.dev), elle denetlenmiş bir tablo ve OpenRouter, LiteLLM, models.dev genel katalogları; kendiliğinden **günde en çok bir kez** yenilenir (24 saat önbellek, `If-None-Match`; başarısız indirme bir saat içinde yeniden denenir); **Fiyatları güncelle** / `--refresh-prices` ile ya da Çevrimdışı'nı kapatınca hemen yenilenir. Bulut modeli asla "ücretsiz" değildir; yerel model, bulut karşılığının fiyatıyla sayılır, karşılığı yoksa `$0`.
- **Türkçe ve İngilizce**, Windows görüntüleme dilinden (`TOKENBAR_LANG=en` ya da `tr` ezer).
- **Komut satırı:** `tokenbar-cli.exe --window all --json`, Mac komut satırıyla aynı JSON'u yazar.

## Kurulum

Gereksinim: Windows 10 ya da 11, 64 bit. Başka bir şey gerekmez: Python indirmenin içindedir.

1. [Releases](https://github.com/dr-ofn/TokenBar/releases) sayfasından `TokenBar-Windows-<sürüm>.zip` dosyasını indirin ve istediğiniz yere açın (örneğin `C:\Users\siz\TokenBar`).
2. Klasörü açıp `TokenBar.exe` dosyasını başlatın. Tepsiye küçük bir simge gelir (Windows gizliyorsa saatin yanındaki `^` oku). Pencereyi açmak için simgeye tıklayın.

### SmartScreen uyarısı

TokenBar **imzasız**dır (sertifika ücretlidir, bu ücretsiz bir açık kaynak projedir). İlk açılışta Windows SmartScreen "Windows bilgisayarınızı korudu / Yayımcı bilinmiyor" gösterebilir. İmzasız bir program için beklenen budur:

1. **Ek bilgi**ye tıklayın.
2. **Yine de çalıştır**a tıklayın.

Windows seçimi o dosya için hatırlar. İndirmeye güvenmek istemezseniz kendiniz derleyin (aşağıda) ya da kaynaktan çalıştırın; kod kısadır ve her ağ çağrısı `tokenbar/prices/feed.py` içindedir.

### Windows ile başlat

Pencerede **⋯** menüsünü açıp **Windows ile başlat**ı işaretleyin. Bu, yalnız sizin kullanıcınız için `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` altına tek bir değer (`TokenBar`) ekler; yönetici hakkı, hizmet ya da zamanlanmış görev yoktur. İşareti kaldırınca değer silinir. (Ya da `shell:startup` klasörüne `TokenBar.exe` kısayolu koyun.)

### Kaynaktan çalıştırma, exe derleme

```powershell
py -3.12 -m venv .venv
.venv\Scripts\activate
pip install -r requirements-dev.txt
python -m pytest -q              # testler
python -m tokenbar               # tepsi uygulaması
python -m tokenbar --window 7d   # metin raporu
python build.py                  # dist\TokenBar\TokenBar.exe ve dist\TokenBar-Windows-<sürüm>.zip
```

Python 3.11 ya da üstü. Tepsi için `pystray` ve `Pillow`, Codex'in sıkıştırılmış kayıtları ile Zed'in sıkıştırılmış iş parçacıkları için `zstandard` gerekir. Pencere, Python ile gelen düz `tkinter`dir.

## Gizlilik

- TokenBar araçlarınızın zaten yazdığı günlük dosyalarını yalnızca **okur**. Onları değiştirmez, taşımaz, silmez ve yüklemez. WAL kipindeki bir veritabanı, SQLite yanına `-shm` dosyası açmadan salt okunur bile açılamaz; bu yüzden böyle veritabanları, geçici özel bir klasördeki kopyadan okunur ve kopya silinir. Bir aracın klasöründe hiçbir şey oluşturulmaz.
- Tek ağ trafiği **üç genel fiyat kataloğuna (OpenRouter, LiteLLM, models.dev) sabit GET istekleridir**: kendiliğinden her katalog için günde en çok bir kez, başarısızlıktan sonra bir saat içinde bir yeniden deneme, ayrıca **Fiyatları güncelle**'ye bastığınızda, `--refresh-prices` çalıştırdığınızda ya da Çevrimdışı'nı kapattığınızda bir tur daha. Verinizden hiçbir şey taşımazlar. Bunu da kapatmak için `TOKENBAR_OFFLINE=1` ayarlayın ya da menüden **Çevrimdışı**yı işaretleyin.
- Telemetri, analitik, hesap, API anahtarı yok.

TokenBar'ın kendi dosyaları:

| Ne | Nerede |
|---|---|
| Gördüğü çağrıların indeksi | `%LOCALAPPDATA%\TokenBar\usage.sqlite` |
| Fiyat listesi önbelleği | `%LOCALAPPDATA%\TokenBar\cache` |
| Ayarlar (dönem, Çevrimdışı, dil) | `%APPDATA%\TokenBar\settings.json` |
| Kendi fiyat adlarınız (isteğe bağlı) | `%APPDATA%\TokenBar\model-aliases.json` |

Sıfırlamak için bunları silin. İndeks, özgün günlüğü artık olmayan çağrıları da tutar (örneğin Claude Code eski kayıtları siler), geçmiş birikmeye devam eder.

## Kendi fiyat adlarınız

Çalıştırdığınız bir modelin adını hiçbir katalog bilmiyorsa ya da başka bir fiyat istiyorsanız `%APPDATA%\TokenBar\model-aliases.json` oluşturun. Takma ad, her tablo ve katalogdan önce gelir:

```json
{
  "aliases": {
    "my-qwen-q4": "qwen3.8-27b",
    "house-model": {"input": 1, "output": 4, "cacheRead": 0.1, "name": "House Model"},
    "test-server": {"free": true}
  },
  "localProviders": ["my-pc", "studio"]
}
```

Bir metin (ya da `{"as": "model"}`) o modelin fiyatını verir; `{"input": ..., "output": ...}` milyon token başına USD'dir (her oran 0 ile 1.000.000 arasında; ötesi, `NaN` ve sonsuz yok sayılır); `{"free": true}` bedelsizdir; `localProviders` kendi makinelerinizde model çalıştıran sunucuları adlandırır. Okunamayan dosya "takma ad yok" demektir, hata değildir. Mac uygulamasının `custom-sources.json` özelliği (dosya biçimiyle araç eklemek) Windows sürümünde **henüz yok**.

## Komut satırı

```
tokenbar-cli.exe --window all --json     JSON: total, calls, cost, harnesses, unpriced, detected
tokenbar-cli.exe --window 7d             metin raporu
tokenbar-cli.exe --home D:\yedek\ben     başka bir ev klasörünü oku (ortam değişkeni izlenmez;
                                         indeks kendi %LOCALAPPDATA%'nda kalır, o klasöre hiçbir şey yazılmaz;
                                         sayılarını kendi indeksinden ayırmak için --db DOSYA ekle)
tokenbar-cli.exe --refresh-prices        (ya da --prices-now) fiyat listelerini şimdi indir, bir günlük bekleme ya da önceki bir
                                         başarısızlık ne derse desin (menüdeki Fiyatları güncelle gibi); --offline ile hiçbir şey indirilmez
tokenbar-cli.exe --offline --no-scan     indeksten raporla, hiçbir şeye dokunma (--offline: hiç ağ yok)
```

`TokenBar.exe` aynı bayrakları yanıtlar (kendi konsolu olmadığından `--output dosya.json` yanıtı dosyaya yazar).

## Bilinmesi gerekenler

- Başka bir programın başkalarının okumasına izin vermeden açık tuttuğu günlük o anda okunamaz; TokenBar bunu okunamayan kaynak olarak adlandırır ve sonraki turda yeniden dener. Araçlar neredeyse her zaman okumaya izin verir.
- Bir aracın derdi diğerlerini durdurmaz: okunamayan ya da bozuk dosya pencerede adlandırılır (durum satırına tıklayın), gerisi sayılır.
- Dolar tutarı **API karşılığıdır, gerçek faturanız değil**: "bu token'lar liste fiyatıyla ne tutardı?" sorusunu yanıtlar, sabit abonelik altındaki çağrılar dahil.

## Lisans

Deponun geri kalanı gibi MIT. TokenBar, okuduğu araçların hiçbiriyle bağlantılı değildir.
