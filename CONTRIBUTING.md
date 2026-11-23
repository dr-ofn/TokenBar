# Contributing to TokenBar

Thanks for helping. Bug reports, new-tool requests and patches are all welcome. Please read the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

macOS 14+, Xcode Command Line Tools (`xcode-select --install`), Swift 6 toolchain, `python3`.

```bash
git clone https://github.com/dr-ofn/TokenBar.git
cd TokenBar
scripts/check.sh
```

## The one rule: `scripts/check.sh` must be green

`scripts/check.sh` builds in release mode, runs `TokenChecks`, compares `tokenbar-cli` against the independent Python reader `scripts/oracle.py` on a made-up home (they must match exactly), compares them on your real logs (within 0.5%, because logs grow between the two reads), and runs the UI invariants. A pull request needs a green run. CI runs everything except the live-logs comparison.

The two counters being independent is the point: a bug has to be made twice, in different languages, to go unnoticed. Keep it that way. Do not copy Swift logic into `oracle.py`; read the tool's real log format and implement it separately.

## Adding a new tool (harness)

A new tool needs three things, in one pull request:

1. **A catalog entry**: the tool's name, where its data lives (home-relative paths and any environment variable that moves them), the parser family it uses, and the de-duplication prefix. Look at how existing tools are registered in `Sources/LocalCore` (`Scanner*.swift`, `Parsers/`); the data-driven catalog file `Resources/harnesses.json` replaces those registrations as the catalog work lands. Do not change the prefix of an existing tool: stored history is keyed by it.
2. **A made-up home fixture**: files in the real on-disk format of that tool, with invented numbers and paths (`/fixture`), added to the fixture home built by `Sources/TokenChecks`. Use the real schema, not a simplified one. Never commit anyone's real logs. Cover the tool's traps: duplicated lines, cumulative counters, overwritten fields, archive files.
3. **The matching reader in `scripts/oracle.py`**, written independently of the Swift parser. `scripts/check.sh` must still report identical totals for CLI and oracle on the fixture.

Also add the tool to [docs/HARNESSES.md](docs/HARNESSES.md), moving it from "Coming" to "Supported". If a tool keeps no token data locally, add it to the "Cannot be counted" table instead, with evidence. Never estimate tokens.

Open a [new-harness issue](https://github.com/dr-ofn/TokenBar/issues/new?template=new-harness.yml) first if you are unsure about the log format.

## Prices

Prices come from `scripts/update-prices.py` and `scripts/price-map.json`. A price change should come from a regenerated table, not a hand edit. Zero prices are rejected on purpose: there is no "free" in TokenBar.

## Pull requests

- Keep a pull request to one change. Add or update a check for behaviour you change.
- Describe what you ran. Paste the final line of `scripts/check.sh`.
- Do not include personal paths, usernames or real log content in code, fixtures, screenshots or descriptions.
- Update `CHANGELOG.md` for user-visible changes.

## Releases (maintainers)

`scripts/release.sh VERSION --universal` (releases are universal: arm64 + x86_64) runs the checks, builds the app, and writes `dist/TokenBar-VERSION.zip`, its `.sha256` and `dist/RELEASE_NOTES.md`. It uploads nothing and prints the `gh release` commands to run (the Windows workflow adds its zip and `.sha256` to the same release when the tag is pushed; the printed commands work whichever of the two comes first).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
