# Privacy

TokenBar is built so that your usage data never leaves your Mac.

## What it reads

- The local log and database files that AI coding tools already write in your home directory (for example `~/.claude/projects`, `~/.codex/sessions`). The full list per tool is in [docs/HARNESSES.md](docs/HARNESSES.md).
- It opens them **read-only**. It never modifies, moves or deletes them.
- Databases in WAL mode (opencode, Zed, ...) cannot be opened even read-only without SQLite creating a `-shm` file next to them, so TokenBar reads them from a copy in a private temporary folder, deleted again right after. Nothing is ever created in a tool's own folder.
- It reads token counts, model names, timestamps, project paths and session identifiers. It does not need, and does not intentionally store, the text of your prompts or the model's replies.

## What it stores

- A local index at `~/Library/Application Support/TokenBar/usage.sqlite` so unchanged files are not re-read.
- Cached price lists, one file per catalogue (`prices-openrouter.json`, `prices-litellm.json`, `prices-modelsdev.json`) and a small `prices-state.json` with the time of the last failed attempt, in `~/Library/Caches/TokenBar`.
- Window and display preferences in the app's standard preferences (`UserDefaults`).

Delete these to reset TokenBar. Uninstalling the app does not delete them automatically.

## What goes over the network

- **Static GET requests for the three public price catalogues**, on their own at most one per catalogue per day (so three a day at most), plus a retry an hour after a failed one (after each further failure in a row the wait doubles, six hours at most) and one more round of three whenever you choose **Update prices** in the menu. The catalogues are: `openrouter.ai/api/v1/models` (OpenRouter), `raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json` (LiteLLM) and `models.dev/api.json` (models.dev). On their own, a catalogue is asked only when its cached copy is more than 24 hours old, with `If-None-Match` (ETag) so an unchanged list costs no download; after a failure the next automatic try waits an hour, and on repeated failures the wait doubles, six hours at most. **Update prices** asks all three at once, whatever the cache says. The requests carry no usage data, no identifiers, no cookies and no account: the headers are plain protocol ones (such as `Accept`, `Accept-Encoding` and `If-None-Match`) and the user agent `TokenBar`; the language header is sent empty, so no language preference goes out. As with any HTTPS request, the server sees your IP address and the app's user agent.
- Set `TOKENBAR_OFFLINE=1` in the app's environment to disable even this. TokenBar then uses its cached or built-in prices.

## What it does not do

- No telemetry, analytics, crash reporting or tracking.
- No accounts, logins or API keys. It never asks for your provider keys.
- No uploading of logs, counts, costs or paths.

## Verify it

The app is open source, so you can read every network call in `Sources/`. You can also watch it with a tool such as Little Snitch or `nettop`, or run it with `TOKENBAR_OFFLINE=1`.

## Questions

Open an issue at https://github.com/dr-ofn/TokenBar/issues.
