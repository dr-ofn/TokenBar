# Supported tools (harnesses)

TokenBar reads the usage logs that AI coding tools already write on your Mac. Nothing is configured: if a tool's data directory exists, TokenBar counts it.

Not every tool keeps a token record on your machine, so tools fall into two classes. The app shows the same split.

1. **Counted**: a local log with token counts exists and TokenBar reads it.
2. **Detected, not countable**: the tool keeps token data on the vendor's servers, or its local files hold no token counts. TokenBar lists it as detected, shows no number, and never estimates.

Türkçe: [HARNESSES.tr.md](HARNESSES.tr.md).

This page is written from the catalog in `Sources/LocalCore/HarnessCatalog.swift`, `HarnessG2.swift` and the readers in `Sources/LocalCore/Scanner*.swift`. If the code and this page disagree, the code is right; please open an issue.

## How to read the tables

- **Root**: where TokenBar looks, under your home folder (`~`). A tool is *detected* when any of its roots exists. Several roots mean the tool may keep its data in any of them.
- **Env**: an environment variable that moves the tool's data. When it is set (and non-empty) it replaces the root. TokenBar only follows these variables for the real home folder, never for another home it is asked to scan.
- **Key prefix**: the start of the de-duplication key TokenBar stores for each call (`cc:...`). A call is stored once however often a file is re-read or copied, and the prefix keeps two tools from clashing.
- **Status**:
  - **verified**: checked against real data (real logs, compared with an independent Python reader, `scripts/oracle.py`).
  - **schema only**: written from the tool's documented or inspected file format and tested against a made-up home folder in `Sources/TokenChecks`. It has not been run on real data. If it miscounts for you, open a [new-harness issue](https://github.com/dr-ofn/TokenBar/issues/new?template=new-harness.yml) with a sample.

## Counted tools

| Tool | Root | Env | Key prefix | What is read | Status |
|---|---|---|---|---|---|
| Claude Code | `~/.claude`, `~/.config/claude` | `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME` | `cc` | `projects/**/*.jsonl`; de-duplicated by request id | verified |
| Codex | `~/.codex` | `CODEX_HOME` | `cx` | `sessions`, `archived_sessions`: `rollout-*.jsonl` and `.jsonl.zst` (the latter needs the `zstd` command: `brew install zstd`); differences of cumulative counters, resets detected | verified |
| opencode | `~/.local/share/opencode` | `XDG_DATA_HOME` | `oc` | `opencode.db`, opened read-only | verified |
| oh-my-pi | `~/.omp` | none | `omp` | `agent/sessions/**/*.jsonl`; `toolResult` lines are not counted | verified |
| Qwen Code | `~/.qwen` | `QWEN_HOME` | `qwen`, `qwenc` | `usage/token-usage-*.jsonl` and `usage_record.jsonl` (`qwen`); the newer chat files only where those are absent (`qwenc`) | `qwen` verified, `qwenc` schema only |
| Kimi Code | `~/.kimi-code` | `KIMI_CODE_HOME` | `kimi` | `sessions/**/wire.jsonl` | verified |
| Devin | `~/.local/share/devin` | none | `devin` | `cli/transcripts/*.json`, plus the CLI's `sessions.db` for sessions that have no transcript | verified |
| Antigravity | `~/.gemini/antigravity-cli` | none | `ag` | `conversations/*.db` (protobuf inside SQLite), read-only | verified |
| Crush | `~/.local/share/crush` | `XDG_DATA_HOME`, `CRUSH_GLOBAL_DATA` | `crush` | each project's database named in `projects.json` | schema only |
| Goose | `~/.local/share/goose/sessions`, `~/Library/Application Support/goose/sessions`, the same two under `Block/`, `~/.local/share/goose` | `GOOSE_PATH_ROOT` | `goose` | `sessions.db`, read whole when it changes | schema only |
| Factory Droid | `~/.factory` | none | `droid` | `sessions/**/*.settings.json` | schema only |
| Amp | `~/.local/share/amp` | `AMP_DATA_DIR` | `amp` | `threads/T-*.json` | schema only |
| OpenHands | `~/.openhands/conversations`, `~/.openhands` | `OPENHANDS_CONVERSATIONS_DIR`, `OPENHANDS_PERSISTENCE_DIR` | `oh` | each conversation's `base_state.json` | schema only |
| Gemini CLI | `~/.gemini/tmp` | `GEMINI_CLI_HOME` (data is then in `$GEMINI_CLI_HOME/.gemini/tmp`) | `gem` | chat files under `tmp` | schema only |
| Pi | `~/.pi/agent` | `PI_CODING_AGENT_DIR` | `pi` | `sessions/**/*.jsonl` | schema only |
| GitHub Copilot CLI | `~/.copilot` | `COPILOT_HOME` | `cop` | `session-state` event files | schema only |
| Junie | `~/.junie` | none | `jun` | `sessions` event files | schema only |
| Codebuff | `~/.config/manicode`, `~/.config/manicode-dev`, `~/.config/manicode-staging` | `CODEBUFF_DATA_DIR` (replaces all three) | `cbuf` | `projects` chat files | schema only |
| Mistral Vibe | `~/.vibe` | `VIBE_HOME` | `vibe` | `logs/session` | schema only |
| Augment | `~/.augment` | none | `aug` | `sessions` | schema only |
| Cline | `~/Library/Application Support/<editor>/User/globalStorage/saoudrizwan.claude-dev` for Code, Code - Insiders, Cursor, Windsurf, VSCodium, Kiro, Positron, Trae and Antigravity; `~/.cline/data` | none | `cline` | `tasks/<id>/ui_messages.json`; the CLI's `sessions/<id>/<id>.messages.json` | schema only |
| Roo Code | the same editors, extension `rooveterinaryinc.roo-cline` | none | `roo` | `tasks/<id>/ui_messages.json` | schema only |
| Kilo Code | the same editors, extension `kilocode.kilo-code`; and `~/.local/share/kilo` (version 7 and the CLI, opencode's database layout) | `XDG_DATA_HOME` for the CLI | `kilocode`, `kilo` | task folders; the CLI database | schema only |
| GitHub Copilot Chat | `~/Library/Application Support/Code` and `Code - Insiders`: `User/workspaceStorage`, `User/globalStorage/emptyWindowChatSessions` | none | `copilot-chat` | `chatSessions/<id>.jsonl` (or `.json`) | schema only |
| Continue | `~/.continue` | `CONTINUE_GLOBAL_DIR` | `continue` | `dev_data/0.2.0/tokensGenerated.jsonl` | schema only |
| Zed | `~/Library/Application Support/Zed` | none | `zed` | `threads/threads.db` (a missing `zstd` command is named as one issue) | schema only |

A Cline extension installed inside Cursor is counted as Cline, not as Cursor (the same holds for Roo and Kilo, whose roots are the same editor folders).

Tools you add yourself (see [custom sources](#your-own-sources-custom-sourcesjson)) show up in the same list. The `open-design-events` reader (Open Design's `events.jsonl` runs) is meant for such entries: it is not tied to a built-in tool.

## Detected, not countable

TokenBar shows these as "detected, token data is not stored locally". It does not invent numbers for them.

| Tool | Root | Why it is not counted |
|---|---|---|
| Cursor | `~/Library/Application Support/Cursor`, `~/.cursor` | The local `tokenCount` field is `0`; usage lives on Cursor's servers |
| Windsurf | `~/.codeium/windsurf`, `~/Library/Application Support/Windsurf` | No local token log found; usage lives on the vendor's servers |
| Trae | `~/Library/Application Support/Trae` | No local token log found; usage lives on the vendor's servers |
| Kiro | `~/.kiro`, `~/Library/Application Support/kiro-cli`, `~/Library/Application Support/Kiro` | The local logs hold zero tokens in the Auto agent and credits otherwise, not token counts |
| Warp | `~/Library/Group Containers/*.dev.warp` | Token totals sit in `warp.sqlite` without an input/output split, and the app-group folder has not been seen on a real Mac: named, never counted |
| Amazon Q | `~/Library/Application Support/amazon-q` | The CLI records no token counts locally (its request metadata has none) |

If you can show a local record we missed, open a [new-harness issue](https://github.com/dr-ofn/TokenBar/issues/new?template=new-harness.yml).

## Your own sources: `custom-sources.json`

Any tool whose files one of the readers above already understands can be added without touching the code (as a new tool for five of the readers, as more folders of a built-in tool for the rest; see below the table). Create `~/.config/tokenbar/custom-sources.json`:

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
      "name": "My opencode fork",
      "family": "opencode-sqlite",
      "paths": ["~/work/fork-data"],
      "keyPrefix": "myfork",
      "recursive": true
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Groups sources under one tool. Letters, digits, `.`, `_`, `-`. Two entries with the same `id` appear as one tool. |
| `name` | The name shown. Defaults to `id`. |
| `family` | The reader to use: `anthropic-jsonl`, `codex-rollout`, `opencode-sqlite`, `open-design-events`, `omp-jsonl`, `qwen-usage`, `kimi-wire`, `devin-transcripts`, `antigravity-sqlite`, `crush-sqlite`, `goose-sqlite`, `droid-settings`, `amp-threads`, `openhands-state`, `gemini-chats`, `pi-jsonl`, `copilot-events`, `junie-events`, `codebuff-chats`, `vibe-sessions`, `augment-sessions`, `qwen-chats`, `cline-tasks`, `roo-tasks`, `copilot-chat`, `continue-tokens`, `zed-threads` or `not-countable` (detect only). Only five of them can start a new tool under an `id` of your own: see [which families can start a new tool](#your-own-sources-custom-sourcesjson) below the table. |
| `paths` | Folders or files, starting with `~/` or `/`. Required. |
| `keyPrefix` | De-duplication key prefix: lower-case letters, digits and `-`. For a family that fixes its own prefix it must equal it; otherwise it defaults to the lower-cased `id`. A prefix a built-in tool already uses is refused. |
| `hue` | Colour in degrees. Optional; without it the colour is derived from the `id` and stays the same between runs. |
| `recursive` | For `opencode-sqlite` folders: look for databases at any depth. Defaults to `true`. |

**Which families can start a new tool.** A reader writes its own de-duplication prefix (`cc`, `cx`, `zed`, ...), and the prefix is how a call is traced back to its tool. So a family with a fixed prefix cannot start a new tool under an `id` of your own: the entry has to use the `id` of the built-in tool that owns the prefix, and then it only adds folders to that tool (for example the `~/.claude` of a second account). A new `id` with such a family is refused (`the prefix "cc" is used by claude-code`).

Families open to a new `id`: `opencode-sqlite`, `open-design-events`, `cline-tasks`, `roo-tasks`, `not-countable`.

The other 23 families take the `id` of their built-in tool:

| Family | `id` it requires |
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

A mistake in an entry is named in the app (`custom-sources.json: ...`) and only that entry is skipped.

## Your own price names: `model-aliases.json`

TokenBar prices a model from the price catalogues (see the README). When a model you run has a name no catalogue knows, or you want a different price, add `~/.config/tokenbar/model-aliases.json`. An alias wins over every table and catalogue.

```json
{
  "aliases": {
    "my-qwen-q4": "qwen3.8-27b",
    "sidecar": {"as": "claude-haiku-5-5"},
    "house-model": {"input": 1, "output": 4, "cacheRead": 0.1, "name": "House Model"},
    "home-7b": {"input": 0.1, "output": 0.3, "kind": "near",
                "source": "OpenRouter nearest: acme/small, same family and size"},
    "test-server": {"free": true}
  },
  "localProviders": ["my-mac-mini", "studio"]
}
```

- A string, or `{"as": "model"}`: price it like that model.
- `{"input": ..., "output": ...}`: USD per 1M tokens. `cacheRead`, `cacheWrite` and `name` are optional. `source` (a note shown in the breakdown) and `kind` (`"near"` for a stand-in price, `"other"` for a price published elsewhere) are optional too.
- `{"free": true}`: no cost.
- `localProviders`: servers that run models on your own machines. A model on such a server, or with a local quantisation suffix such as `-4bit` or `-q4_k_m`, is priced as its cloud counterpart when one exists, and costs nothing when none does.
- An alias for a short name also covers its account-numbered, effort-marked or context-sized variants (`my-model-high`, `my-model-256k`), marked as an approximation.
- Names are matched the way TokenBar folds every model name: lower case, no provider path, `.` and `_` read as `-`.
- The file may also be the aliases alone, without the `"aliases"` key. A missing or unreadable file means no aliases, never an error. With `TOKENBAR_PRICES_PINNED=1` (what the checks use) the file is ignored.

## Adding a tool to TokenBar itself

See [CONTRIBUTING.md](../CONTRIBUTING.md): a catalog entry, a made-up home fixture, and a matching `scripts/oracle.py` reader.
