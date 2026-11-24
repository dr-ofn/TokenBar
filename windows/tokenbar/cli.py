"""`tokenbar`: with no arguments the tray app, with any of the flags below the command line.

    tokenbar --window all --json         the same JSON as the Mac app's command line
    tokenbar --window 7d                 a text report
    tokenbar --home DIR                  read another home folder (a backup, a test folder), no variable followed
    tokenbar --db PATH, --no-scan, --rebuild, --index, --refresh-prices (alias --prices-now), --offline
"""
from __future__ import annotations

import argparse
import json
import hashlib
import os
import sys

from . import __version__
from .catalog import Catalog, harness_name
from .fmt import calls, money, period_label, rate, tokens
from .i18n import t
from .paths import Env
from .prices.book import PriceBook
from .prices.engine import display_safe
from .report import PERIODS, build_report, to_json
from .scanner import Scanner
from .store import Store, StoreError

CLI_FLAGS = {"--window", "-w", "--json", "--home", "--db", "--rebuild", "--no-scan", "--index", "--refresh-prices",
             "--prices-now", "--offline", "--version", "-h", "--help", "--output"}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="tokenbar", description=t(
        "TokenBar: yapay zekâ kodlama araçlarının bu bilgisayardaki günlüklerini salt okunur okur, token ve maliyeti gösterir.",
        "TokenBar: reads the logs AI coding tools wrote on this PC (read-only) and shows tokens and cost."))
    p.add_argument("--window", "-w", default="24h", choices=list(PERIODS), help="1h 5h 24h 7d 30d all")
    p.add_argument("--json", action="store_true", help=t("JSON çıktısı", "JSON output"))
    p.add_argument("--home", help=t("başka bir kullanıcı klasörünü oku (ortam değişkenleri izlenmez)", "read another home folder (no variable is followed)"))
    p.add_argument("--db", help=t("indeks dosyası", "index file"))
    p.add_argument("--rebuild", action="store_true", help=t("indeksi sıfırla (varsayılan indekste reddedilir)", "reset the index (refused for the live index)"))
    p.add_argument("--no-scan", action="store_true", help=t("taramadan raporla", "report without scanning"))
    p.add_argument("--index", action="store_true", help=t("indeks bilgisi", "show index info"))
    p.add_argument("--refresh-prices", "--prices-now", dest="refresh_prices", action="store_true", help=t("fiyat listelerini şimdi indir (günlük beklemeyi yok sayar, menüdeki Fiyatları güncelle gibi)", "fetch the price lists now, whatever the one-day wait says (like the menu's Update prices)"))
    p.add_argument("--offline", action="store_true", help=t("ağa hiç çıkma", "never touch the network"))
    p.add_argument("--output", help=t("çıktıyı bu dosyaya yaz", "write the output to this file"))
    p.add_argument("--version", action="store_true")
    return p


GUI_ARGS = {"--show"}       # what the tray app itself takes (`--selftest-gui` is handled before)


def is_cli(argv: list[str]) -> bool:
    """TokenBar.exe is the tray app only with no arguments (or `--show`). Anything else is the command line, so a flag
    the parser does not know (`-w7d` mistyped, `--bogus`) is an error with a message and not a window that opens."""
    return any(a not in GUI_ARGS for a in argv)


def _attach_console() -> None:
    """The GUI executable has no console of its own: borrow the parent's so `TokenBar.exe --json` prints.

    Only a stream that does not exist is replaced. One that exists is a file or a pipe somebody redirected to
    (`> out.json`, `| jq`): it is not a terminal, but it must keep the output."""
    if sys.platform != "win32" or (sys.stdout is not None and sys.stderr is not None):
        return
    try:
        import ctypes
        if ctypes.windll.kernel32.AttachConsole(-1):
            if sys.stdout is None:
                sys.stdout = open("CONOUT$", "w", encoding="utf-8")
            if sys.stderr is None:
                sys.stderr = open("CONOUT$", "w", encoding="utf-8")
    except Exception:
        pass


def run_cli(argv: list[str]) -> int:
    _attach_console()
    # A windowed program has no stdout at all, and a pipe may use a code page that cannot hold every model name.
    for name in ("stdout", "stderr"):
        stream = getattr(sys, name)
        if stream is None:
            setattr(sys, name, open(os.devnull, "w", encoding="utf-8"))
        else:
            try:
                stream.reconfigure(errors="replace")
            except (AttributeError, ValueError):
                pass
    args = build_parser().parse_args(argv)
    out = sys.stdout
    if args.version:
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(__version__ + "\n")
        else:
            print(__version__)
        return 0
    if args.home:
        # Read by its real path, so two spellings of one home (a link, a different case) are one set of files.
        try:
            args.home = _real_path(args.home)
        except (OSError, ValueError) as e:       # a name the system cannot take (an embedded NUL): said, not a traceback
            print("tokenbar: " + display_safe(t("--home çözülemedi", "cannot resolve --home") + f" ({args.home!r}): {e}"), file=sys.stderr)
            return 2
    env = Env.for_home(args.home) if args.home else Env.from_os()
    # The index and the price cache are TokenBar's own files: they live with the person running it (or in `--db`),
    # never inside the folder that is being read. Another home (`--home` without `--db`) gets an index of its own there,
    # as on the Mac, so its calls are never mixed into the person's own index.
    own = Env.from_os()
    db_path = args.db or (home_index_path(own, args.home) if args.home else own.db_path())
    try:
        at_default = args.rebuild and os.path.normcase(_real_path(db_path)) == os.path.normcase(os.path.realpath(own.db_path()))
    except (OSError, ValueError) as e:
        print("tokenbar: " + display_safe(t("--db çözülemedi", "cannot resolve --db") + f" ({db_path!r}): {e}"), file=sys.stderr)
        return 2
    if at_default:
        print("tokenbar: --rebuild " + t("reddedildi: indeks varsayılan konumda", "refused: the index is at its default location")
              + f" ({display_safe(db_path)})", file=sys.stderr)
        return 2
    try:
        store = Store(db_path)
    except StoreError as e:
        print(f"tokenbar: {display_safe(str(e))}", file=sys.stderr)
        return 1
    try:
        if args.index:
            print(f"{t('kayıt', 'events')}: {store.event_count()} · {t('dosya', 'files')}: {len(store.file_records())}")
            return 0
        if args.rebuild:
            store.reset()
        # The price cache is the user's own; the price names (model-aliases.json) are the inspected home's, as on the Mac.
        book = PriceBook(own, offline=args.offline, aliases_env=env if args.home else None)
        if args.refresh_prices:
            report = book.refresh(force=True)
            if report is not None:
                print(t("fiyatlar: ", "prices: ") + f"{len(report.updated)} updated, {len(report.not_modified)} not modified, "
                      f"{len(report.fresh)} fresh, {len(report.failed)} failed", file=sys.stderr)
                for note in report.notes:
                    print(display_safe(note), file=sys.stderr)
        detected: list[str] = Catalog(env).detected()
        if not args.no_scan:
            result = Scanner(store, env).scan()
            detected = result.detected
            for source, message in result.issues:
                print(f"{t('kaynak hatası', 'source error')} · {display_safe(source)}: {display_safe(message)}", file=sys.stderr)
        report = build_report(store, book, args.window)
        problem = book.alias_problem()
        if problem:
            print(f"{t('kaynak hatası', 'source error')} · model-aliases.json: {display_safe(problem)}", file=sys.stderr)
        text = json.dumps(to_json(report, detected), indent=1, sort_keys=True) if args.json else render_text(report, args.window)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(text + "\n")
        else:
            print(text, file=out)
        return 0
    finally:
        store.close()


def render_text(report, window: str) -> str:
    lines = [f"{period_label(window)}: {tokens(report.tokens)} {t('token', 'tokens')} · {money(report.cost)} · {calls(report.calls)}"]
    for h in report.harnesses:
        lines.append(f"{display_safe(h.name)}: {tokens(h.tokens)} · {money(h.cost)} · {calls(h.calls)}")
        for m in h.models:
            price = f"${rate(m.entry['input'])}/${rate(m.entry['output'])} per M" if m.entry else t("fiyat yok", "no price")
            lines.append(f"  {display_safe(m.name)} [{display_safe(m.provider)}]  {tokens(m.tokens)} · {money(m.cost)} · {price} · {calls(m.calls)}")
    if not report.harnesses:
        lines.append(t("  (bu aralıkta çağrı yok)", "  (no calls in this window)"))
    return "\n".join(lines)


def _real_path(path):
    """os.path.realpath that refuses a name no file system can hold: on Windows realpath passes an embedded NUL through
    (POSIX raises ValueError), and the scan would then fail once per source instead of once here."""
    if "\x00" in path:
        raise ValueError("embedded null character in path")
    return os.path.realpath(path)


def home_index_path(own: Env, home: str) -> str:
    """`<own data folder>/homes/<first 16 hex of the SHA-256 of the home's real path>/usage.sqlite` (the Mac's rule)."""
    real = os.path.normcase(os.path.realpath(home))
    digest = hashlib.sha256(real.encode("utf-8", "surrogatepass")).hexdigest()[:16]
    return os.path.join(own.data_dir(), "homes", digest, "usage.sqlite")


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if "--selftest-gui" in argv:        # the tray path itself, on a made-up home (the packaged app's smoke test)
        from .gui.app import run_gui
        return run_gui(argv)
    if is_cli(argv):
        return run_cli(argv)
    from .gui.app import run_gui
    return run_gui(argv)
