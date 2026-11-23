# TokenBar for Windows

**English** · [Türkçe](README.tr.md)

TokenBar for Windows is a system tray app that counts the tokens your AI coding tools used, from their own local logs, and shows what that usage would cost at API prices. It is the Windows edition of [TokenBar for macOS](../README.md): the same tools, the same price rules, the same totals (the tests check them against the Mac app's own counts on a made-up home folder).

> **Status:** the code is tested on macOS and Linux-style paths with made-up home folders and the same checks as the Mac app. It has **not been run on a real Windows PC yet**: the tray icon, the window, the PyInstaller build and the automatic start were written from the documentation of their libraries and are verified by the CI job in `.github/workflows/windows.yml` only as far as it can run headlessly. If something misbehaves on your PC, please [open an issue](https://github.com/dr-ofn/TokenBar/issues).

## What it does

- **Tray icon** with today's total in its tooltip. Click it to open the window.
- **Window:** period buttons (1 h, 5 h, 24 h, 7 days, 30 days, All), total dollars and tokens, then every tool and, under it, every model with tokens, dollars, price per million tokens (input / output) and calls.
- **Detected, cannot be counted:** Cursor, Windsurf, Trae, Kiro, Warp and Amazon Q are listed when they are installed, with no invented numbers: they keep token data on the vendor's servers or in logs without token counts.
- **26 tools counted** (Claude Code, Codex, opencode, oh-my-pi, Qwen Code, Kimi Code, Devin, Antigravity, Crush, Goose, Factory Droid, Amp, OpenHands, Gemini CLI, Pi, GitHub Copilot CLI, Junie, Codebuff, Mistral Vibe, Augment, Cline, Roo Code, Kilo Code, GitHub Copilot Chat, Continue, Zed). Where each one keeps its data on Windows, and what is verified, is in [docs/HARNESSES.md](docs/HARNESSES.md).
- **Prices stay current:** an embedded snapshot (LiteLLM, models.dev), a hand-checked table, and the public catalogues OpenRouter, LiteLLM and models.dev, refreshed **at most once a day** (24 h cache, `If-None-Match`). Cloud models are never "free"; a local model costs its cloud equivalent, or `$0` when it has none.
- **English and Turkish**, from the Windows display language (`TOKENBAR_LANG=en` or `tr` overrides it).
- **Command line:** `tokenbar-cli.exe --window all --json` prints the same JSON as the Mac app's command line.

## Install

Requirements: Windows 10 or 11, 64-bit. Nothing else: Python is inside the download.

1. Download `TokenBar-Windows-<version>.zip` from the [Releases](https://github.com/dr-ofn/TokenBar/releases) page and unzip it anywhere you like (for example `C:\Users\you\TokenBar`).
2. Open the folder and start `TokenBar.exe`. A small icon appears in the tray (click the `^` next to the clock if Windows hides it). Click the icon to open the window.

### The SmartScreen warning

TokenBar is **not code-signed** (a certificate costs money, and this is a free open source project). The first time you start it, Windows SmartScreen may show "Windows protected your PC / Unknown publisher". That is expected for an unsigned program:

1. Click **More info**.
2. Click **Run anyway**.

Windows remembers the choice for that file. If you prefer not to trust a download, build it yourself (below) or run it from source; the code is short and every network call is in `tokenbar/prices/feed.py`.

### Start with Windows

In the window, open the **⋯** menu and tick **Start with Windows**. This adds one value (`TokenBar`) to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` for your user only; no administrator rights, no service, no scheduled task. Untick it to remove the value. (Or put a shortcut to `TokenBar.exe` in `shell:startup`.)

### Run from source, or build the exe

```powershell
py -3.12 -m venv .venv
.venv\Scripts\activate
pip install -r requirements-dev.txt
python -m pytest -q              # the tests
python -m tokenbar               # the tray app
python -m tokenbar --selftest-gui --home DIR --db FILE --selftest-out FILE   # starts the tray path on a made-up home, quits itself, writes "GUI SELFTEST OK"
python -m tokenbar --window 7d   # a text report
python build.py                  # dist\TokenBar\TokenBar.exe and dist\TokenBar-Windows-<version>.zip
```

Python 3.11 or newer. The tray needs `pystray` and `Pillow`; `zstandard` reads Codex's compressed rollouts and Zed's compressed threads. The window is plain `tkinter`, which ships with Python.

## Privacy

- TokenBar only **reads** the log files your tools already wrote. It never modifies, moves or deletes them, and never uploads them. A database in WAL mode cannot be opened even read-only without SQLite making a `-shm` file next to it, so such databases are read from a copy in a private temporary folder that is deleted again. Nothing is ever created in a tool's folder.
- The only network traffic is **at most three static GET requests a day**, one for each public price catalogue (OpenRouter, LiteLLM, models.dev). They carry none of your data. Set `TOKENBAR_OFFLINE=1`, or tick **Offline** in the menu, to turn even that off.
- No telemetry, no analytics, no accounts, no API keys.

Where TokenBar keeps its own files:

| What | Where |
|---|---|
| Index of the calls it has seen | `%LOCALAPPDATA%\TokenBar\usage.sqlite` |
| Price list cache | `%LOCALAPPDATA%\TokenBar\cache` |
| Settings (period, Offline, language) | `%APPDATA%\TokenBar\settings.json` |
| Your own price names (optional) | `%APPDATA%\TokenBar\model-aliases.json` |

Delete them to reset TokenBar. The index keeps calls whose original logs are gone (Claude Code, for one, deletes old transcripts), so history keeps accumulating.

## Your own price names

When a model you run has a name no catalogue knows, or you want a different price, create `%APPDATA%\TokenBar\model-aliases.json`. An alias wins over every table and catalogue:

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

A string (or `{"as": "model"}`) prices it like that model; `{"input": ..., "output": ...}` is USD per million tokens (each rate from 0 to 1,000,000; anything else, and `NaN` or infinity, is ignored); `{"free": true}` costs nothing; `localProviders` names servers that run models on your own machines. An unreadable file means no aliases, never an error. The Mac app's `custom-sources.json` (adding a tool by file format) is **not** supported in the Windows version yet.

## Command line

```
tokenbar-cli.exe --window all --json     JSON: total, calls, cost, harnesses, unpriced, detected
tokenbar-cli.exe --window 7d             a text report
tokenbar-cli.exe --home D:\backup\me     read another home folder (no environment variable is followed;
                                         the index stays in your own %LOCALAPPDATA%, nothing is written into that
                                         folder; add --db FILE to keep its numbers out of your own index)
tokenbar-cli.exe --refresh-prices        (also --prices-now) fetch the price lists now (a day's cache is respected)
tokenbar-cli.exe --offline --no-scan     report from the index, touch nothing
```

`TokenBar.exe` answers the same flags: with `>` or `|` the answer goes where you sent it; `--output file.json` writes it to a file.

## Limits to know about

- A log that another program holds open without allowing others to read it cannot be read at that moment; TokenBar names it as a source it could not read and tries again on the next pass. Tools almost always allow reading.
- One tool's trouble never stops the others: an unreadable or corrupt file is named in the window (click the status line), the rest is counted.
- The dollar figure is an **API-equivalent cost, not your actual bill**: it answers "what would these tokens cost at list price?", including calls made under a flat subscription.

## License

MIT, as the rest of the repository. TokenBar is not affiliated with any of the tools it reads.
