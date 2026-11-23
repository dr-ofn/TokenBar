# Changelog

## 9.0.0 — 2026-11-23
First open-source release (MIT).

- **Windows.** A Windows 10/11 tray app (`windows/`, Python) reads the same tools with the same price rules and gives the same totals as the Mac app on the shared made-up home folder; built and tested on GitHub's Windows runners (`.github/workflows/windows.yml`). Download `TokenBar-Windows-9.0.0.zip` from Releases. Not code-signed: SmartScreen asks once (More info → Run anyway). See `windows/README.md`.

- **Automatic tool detection.** TokenBar now finds the AI coding tools on your Mac by itself: 26 are counted from their local logs (Claude Code, Codex, opencode, oh-my-pi, Qwen Code, Kimi Code, Devin, Antigravity, Crush, Goose, Factory Droid, Amp, OpenHands, Gemini CLI, Pi, GitHub Copilot CLI, Junie, Codebuff, Mistral Vibe, Augment, Cline, Roo Code, Kilo Code, GitHub Copilot Chat, Continue, Zed). Eight were checked against real data; the rest are written from the tools' file formats and tested on a made-up home (see `docs/HARNESSES.md`). Tool locations follow the tools' own environment variables.
- **Tools that cannot be counted are named, not guessed.** Cursor, Windsurf, Trae, Kiro, Warp and Amazon Q are listed as detected; their logs hold no token counts.
- **Your own sources.** `~/.config/tokenbar/custom-sources.json` adds a tool whose files an existing reader understands.
- **Run-time price engine.** Prices come from three public catalogues, OpenRouter, LiteLLM and models.dev, plus a small hand-checked table for models none of them lists. LiteLLM and models.dev (MIT) ship as an embedded snapshot, so the first launch is already priced; OpenRouter is read from the network only. Each catalogue is refreshed at most once a day (one anonymous static GET, 24 hour cache, ETag), never when `TOKENBAR_OFFLINE=1` or **Offline** is on. The menu has **Update prices** and **Offline**. Model names fold the same way everywhere (provider path, `:free`, dates, `.`/`_`/`-`).
- **Local model rule.** A model that runs on your machine is priced as its cloud counterpart when one exists and costs nothing when none does. A cloud model is never free: a free-only model takes the price of its nearest paid model, and the breakdown says which and why. A model with no source stays "no price"; nothing is invented.
- **Your own price names.** `~/.config/tokenbar/model-aliases.json` prices names no catalogue knows (a home server, a routing chain, a quantised copy), with an optional note and a `near`/`other` mark.
- **Readable model names.** A model a catalogue lists without a name shows as "Claude Mythos 5.2" or "GPT-6.2 Sol" instead of its raw id.
- **Free-only routes priced:** Nemotron 3.5 Bolt E4B and Super VL (120B A12B spelling), Flint 40B, ERNIE-5.5-Flash-Preview, Gemini 4 Argon (trial plan).
- **Two languages.** English and Turkish interface, chosen by the system language; `TOKENBAR_LANG=en|tr` overrides it.
- **Open source.** MIT licence, `PRIVACY.md`, contribution guide and code of conduct, English and Turkish READMEs, no telemetry. The only network traffic is the price-catalogue GETs above.
- **Packaging.** `scripts/build-app.sh` builds an ad-hoc signed `TokenBar.app` (arm64, or `--universal`); `scripts/release.sh` makes the zip, its SHA-256 and release notes; a Homebrew cask template is in `packaging/homebrew`. The app is not notarized, so the first launch needs the Gatekeeper step in the README.

## 8.x and earlier
Private pre-release history; not part of this repository.
