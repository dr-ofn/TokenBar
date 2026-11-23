# Supported tools on Windows

TokenBar reads the usage logs that AI coding tools already write on your PC. Nothing is configured: if a tool's data folder exists, TokenBar counts it. This page is written from `tokenbar/catalog.py` and the readers in `tokenbar/readers/`; if the code and this page disagree, the code is right.

Two classes, as on the Mac: **counted** (a local log with token counts exists) and **detected, not countable** (the tool keeps token data on the vendor's servers, or its local files hold no token counts: listed, never estimated).

`%USERPROFILE%` is your home folder (`C:\Users\you`), `%APPDATA%` is `...\AppData\Roaming`, `%LOCALAPPDATA%` is `...\AppData\Local`.

## How to read the tables

- **Folder**: where TokenBar looks. A tool is *detected* when any of its folders exists.
- **Variable**: an environment variable that moves the tool's data; when set (absolute path, or starting with `~`) it replaces the folder. TokenBar follows these variables only for the real home, never for a `--home` folder.
- **Path check** (the Windows location, not the file format):
  - **verified**: confirmed in the tool's own documentation or source code (link given).
  - **not verified**: the folder is the one the Mac version uses under the home folder, or follows the same convention; nothing found that states the Windows location. If your copy keeps its data elsewhere, TokenBar finds nothing for it (it never invents numbers): please open an issue with the real path.
- **Format**: how the files are read. The readers follow the Mac app's; "verified" on the Mac means checked against real logs there. **Nothing here has been run against a real Windows PC's logs yet.**

## Counted tools

| Tool | Folder | Variable | Key prefix | What is read | Path check |
|---|---|---|---|---|---|
| Claude Code | `%USERPROFILE%\.claude`, `%USERPROFILE%\.config\claude` | `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME` | `cc` | `projects\**\*.jsonl`, de-duplicated by request id; `cost-state` gaps | verified: [claude-directory](https://code.claude.com/docs/en/claude-directory) ("`~/.claude` resolves to `%USERPROFILE%\.claude`", `CLAUDE_CONFIG_DIR`); the `.config\claude` root is the Mac catalog's, not verified on Windows |
| Codex | `%USERPROFILE%\.codex` | `CODEX_HOME` | `cx` | `sessions`, `archived_sessions`: `rollout-*.jsonl` and `.jsonl.zst` (needs `zstandard`, bundled) | verified: [codex-rs/utils/home-dir](https://github.com/openai/codex/blob/main/codex-rs/utils/home-dir/src/lib.rs) (`CODEX_HOME`, else `dirs::home_dir()/.codex`) |
| opencode | `%USERPROFILE%\.local\share\opencode` | `XDG_DATA_HOME` | `oc` | `opencode.db` (read from a copy when it has a `-wal`) | verified: [packages/util/src/global-roots.ts](https://github.com/anomalyco/opencode/blob/dev/packages/util/src/global-roots.ts) (XDG on every OS: `XDG_DATA_HOME` or `~/.local/share`) |
| oh-my-pi | `%USERPROFILE%\.omp` | none | `omp` | `agent\sessions\**\*.jsonl` | verified: [packages/utils/src/dirs.ts](https://github.com/can1357/oh-my-pi/blob/main/packages/utils/src/dirs.ts) (`os.homedir()/.omp`) |
| Qwen Code | `%USERPROFILE%\.qwen` | `QWEN_HOME` | `qwen`, `qwenc` | `usage\token-usage-*.jsonl` and `usage_record.jsonl`; the chat files only where those are absent | verified: [packages/core/src/config/storage.ts](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/config/storage.ts) |
| Kimi Code | `%USERPROFILE%\.kimi-code` | `KIMI_CODE_HOME` | `kimi` | `sessions\**\wire.jsonl` | verified: [apps/kimi-code/src/utils/paths.ts](https://github.com/MoonshotAI/kimi-code/blob/main/apps/kimi-code/src/utils/paths.ts) and `constant/app.ts` (`os.homedir()` + `.kimi-code`, `KIMI_CODE_HOME`) |
| Devin | `%USERPROFILE%\.local\share\devin` | none | `devin` | `cli\transcripts\*.json`, and `cli\sessions.db` for sessions without a transcript | **not verified** (Mac folder under the home folder; no Windows source found) |
| Antigravity | `%USERPROFILE%\.gemini\antigravity-cli` | none | `ag` | `conversations\*.db` (protobuf inside SQLite) | **not verified** (Mac folder under the home folder; no Windows source found) |
| Crush | `%LOCALAPPDATA%\crush` | `CRUSH_GLOBAL_DATA`, `XDG_DATA_HOME` | `crush` | each project's `crush.db`, named in `projects.json` | verified: [internal/config/load.go `GlobalConfigData`](https://github.com/charmbracelet/crush/blob/main/internal/config/load.go) and the README (`%LOCALAPPDATA%\crush`) |
| Goose | `%APPDATA%\Block\goose\data\sessions`; also `%USERPROFILE%\.local\share\goose\sessions` and `...\Block\goose\sessions` | `GOOSE_PATH_ROOT` | `goose` | `sessions.db`, read whole when it changes | verified from source: [config/paths.rs](https://github.com/block/goose/blob/main/crates/goose/src/config/paths.rs) (`etcetera` app strategy, author `Block`, app `goose`, `data` folder) and etcetera's Windows strategy (`AppData\Roaming\<author>\<app>\data`); `session_manager.rs` (`sessions` / `sessions.db`). The two `.local\share` roots are the Mac catalog's, not verified on Windows |
| Factory Droid | `%USERPROFILE%\.factory` | none | `droid` | `sessions\**\*.settings.json` | verified (the folder): [docs.factory.ai settings](https://docs.factory.ai/cli/configuration/settings) (`%USERPROFILE%\.factory\settings.json`); the `sessions` layout is the Mac's |
| Amp | `%USERPROFILE%\.local\share\amp` | `AMP_DATA_DIR` | `amp` | `threads\**\T-*.json` | **not verified** (Amp is closed source; its manual names no Windows folder) |
| OpenHands | `%USERPROFILE%\.openhands\conversations` | `OPENHANDS_CONVERSATIONS_DIR`, `OPENHANDS_PERSISTENCE_DIR` | `oh` | each conversation's `base_state.json` | verified: [openhands_cli/locations.py](https://github.com/OpenHands/OpenHands-CLI/blob/main/openhands_cli/locations.py) (`os.path.expanduser("~/.openhands")`) |
| Gemini CLI | `%USERPROFILE%\.gemini\tmp` | `GEMINI_CLI_HOME` (data is then in `%GEMINI_CLI_HOME%\.gemini\tmp`) | `gem` | `<project>\chats\*.json[l]` | verified: [packages/core/src/utils/paths.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts) and `config/storage.ts` (`homedir()/.gemini/tmp`) |
| Pi | `%USERPROFILE%\.pi\agent` | `PI_CODING_AGENT_DIR` | `pi` | `sessions\**\*.jsonl` | verified: [packages/coding-agent/src/config.ts](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/config.ts) `getAgentDir()` |
| GitHub Copilot CLI | `%USERPROFILE%\.copilot` | `COPILOT_HOME` | `cop` | `session-state\*\events.jsonl` | partly verified: [GitHub docs](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference) name `~/.copilot`, `COPILOT_HOME` and `session-state/`; they do not spell out the Windows path |
| Junie | `%USERPROFILE%\.junie` | none | `jun` | `sessions\*\events.jsonl` | **not verified** |
| Codebuff | `%USERPROFILE%\.config\manicode` (and `-dev`, `-staging`) | `CODEBUFF_DATA_DIR` (replaces all three) | `cbuf` | `projects\**\chats\*\chat-messages.json` | verified: [cli/src/utils/config-dir.ts](https://github.com/CodebuffAI/codebuff/blob/main/cli/src/utils/config-dir.ts) (`os.homedir()/.config/manicode`). Its newer override variable is `FREEBUFF_CONFIG_DIR`, which TokenBar does not follow yet |
| Mistral Vibe | `%USERPROFILE%\.vibe` | `VIBE_HOME` | `vibe` | `logs\session` | verified: [vibe/utils/vibe_home.py](https://github.com/mistralai/mistral-vibe/blob/main/vibe/utils/vibe_home.py) (`Path.home() / ".vibe"`) |
| Augment | `%USERPROFILE%\.augment` | none | `aug` | `sessions\*.json` | partly verified: [docs](https://docs.augmentcode.com/cli/reference) name `~/.augment` as the default; no Windows spelling |
| Cline | `%APPDATA%\<editor>\User\globalStorage\saoudrizwan.claude-dev` for Code, Code - Insiders, Cursor, Windsurf, VSCodium, Kiro, Positron, Trae and Antigravity; `%USERPROFILE%\.cline\data` | none | `cline` | `tasks\<id>\ui_messages.json`; the CLI's `sessions\<id>\<id>.messages.json` | verified: VS Code keeps user data in `%APPDATA%\<product>` ([settings docs](https://code.visualstudio.com/docs/configure/settings), [userDataPath.ts](https://github.com/microsoft/vscode/blob/main/src/vs/platform/environment/node/userDataPath.ts)), and its forks follow Electron's `appData` ([Electron docs](https://www.electronjs.org/docs/latest/api/app)); the CLI: `os.homedir()/.cline` ([sdk storage paths.ts](https://github.com/cline/cline/blob/main/sdk/packages/shared/src/storage/paths.ts)), the `data` folder below it is the Mac catalog's. VS Code's portable mode and `VSCODE_APPDATA` are not followed |
| Roo Code | the same editors, extension `rooveterinaryinc.roo-cline` | none | `roo` | `tasks\<id>\ui_messages.json` | as Cline |
| Kilo Code | the same editors, extension `kilocode.kilo-code`; and `%USERPROFILE%\.local\share\kilo` (version 7 and the CLI, opencode's database layout) | `XDG_DATA_HOME` for the CLI | `kilocode`, `kilo` | task folders; the CLI database | extension: as Cline. CLI: **not verified** (an opencode fork; opencode's convention is verified, Kilo's own source was not found) |
| GitHub Copilot Chat | `%APPDATA%\Code` and `Code - Insiders`: `User\workspaceStorage`, `User\globalStorage\emptyWindowChatSessions` | none | `copilot-chat` | `chatSessions\<id>.jsonl` (or `.json`) | verified as VS Code above |
| Continue | `%USERPROFILE%\.continue` | `CONTINUE_GLOBAL_DIR` | `continue` | `dev_data\0.2.0\tokensGenerated.jsonl` | verified: [core/util/paths.ts](https://github.com/continuedev/continue/blob/main/core/util/paths.ts) (`os.homedir()/.continue`) |
| Zed | `%LOCALAPPDATA%\Zed` | none | `zed` | `threads\threads.db` | verified: [crates/paths/src/paths.rs](https://github.com/zed-industries/zed/blob/main/crates/paths/src/paths.rs) (`%LOCALAPPDATA%\Zed`) and [crates/agent/src/db.rs](https://github.com/zed-industries/zed/blob/main/crates/agent/src/db.rs) (`data_dir()/threads/threads.db`) |

A Cline extension installed inside Cursor is counted as Cline, not as Cursor (the same holds for Roo and Kilo).

There is no `custom-sources.json` (adding a tool by file format) in the Windows version yet.

## Detected, not countable

| Tool | Folder | Why it is not counted | Path check |
|---|---|---|---|
| Cursor | `%APPDATA%\Cursor`, `%USERPROFILE%\.cursor` | The local `tokenCount` field is `0`; usage lives on Cursor's servers | Electron/VS Code convention (verified as above) for `%APPDATA%\Cursor`; `.cursor` **not verified** |
| Windsurf | `%USERPROFILE%\.codeium\windsurf`, `%APPDATA%\Windsurf` | No local token log found | **not verified** (Windsurf's docs now speak of "Devin Desktop"; the folders are the Mac catalog's) |
| Trae | `%APPDATA%\Trae` | No local token log found | Electron convention; **not verified** for Trae itself |
| Kiro | `%USERPROFILE%\.kiro`, `%LOCALAPPDATA%\kiro-cli`, `%APPDATA%\Kiro` | The local logs hold zero tokens in the Auto agent and credits otherwise | **not verified** (Kiro CLI 3 is a single `kiro-cli` binary; its Windows data folder was not found) |
| Warp | `%LOCALAPPDATA%\warp` | Token totals sit in `warp.sqlite` without an input/output split | partly verified: [Warp docs](https://docs.warp.dev/support-and-community/troubleshooting-and-support/sending-us-feedback) put logs in `%LOCALAPPDATA%\warp\Warp\data\logs`, so the data folder is below `%LOCALAPPDATA%\warp` |
| Amazon Q | `%LOCALAPPDATA%\amazon-q` | The CLI records no token counts locally | verified: [crates/agent/src/agent/util/directories.rs](https://github.com/aws/amazon-q-developer-cli/blob/main/crates/agent/src/agent/util/directories.rs) (`dirs::data_local_dir()/amazon-q`) |

If you can show a local record we missed, open an issue.

## Your own price names

`%APPDATA%\TokenBar\model-aliases.json`, as described in [../README.md](../README.md#your-own-price-names). Names are matched the way TokenBar folds every model name: lower case, no provider path, `.` and `_` read as `-`. With `TOKENBAR_PRICES_PINNED=1` (what the tests use) the file is ignored.
