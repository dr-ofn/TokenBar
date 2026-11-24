"""The window: period buttons, total tokens and dollars, tool -> model list, and what was found but cannot be counted."""
from __future__ import annotations

import queue
import threading
import time
import tkinter as tk
from tkinter import font as tkfont
from tkinter import messagebox, ttk

from .. import __version__
from ..catalog import HUES, harness_name
from ..fmt import calls, money, period_label, period_short, rate, tokens
from ..i18n import t
from ..report import PERIOD_ORDER
from . import startup, theme
from .model import AppModel

WIDTH, HEIGHT = 460, 660


class MainWindow:
    def __init__(self, root: tk.Tk, model: AppModel, on_quit, on_hide=None):
        self.root = root
        self.model = model
        self.on_quit = on_quit
        self.pal = theme.palette()
        self.dark = self.pal is theme.DARK
        self.jobs: queue.Queue = queue.Queue()
        self.on_offline_changed = None      # the tray menu's tick follows the window's switch
        self.on_report = None               # told each report that is painted: the tray tooltip follows the window's numbers
        self.report = None
        self._refresh_seq = 0               # the newest report asked for: an older one that ends later is dropped
        self._menu = None                   # the open menu and its variables (one set, replaced at every opening)
        self._menu_vars: list = []
        self.status = ""
        self.period_buttons: dict[str, tk.Label] = {}
        self._visible = False
        root.title("TokenBar")
        root.geometry(f"{WIDTH}x{HEIGHT}")
        root.minsize(380, 420)
        root.configure(bg=self.pal["bg"])
        root.protocol("WM_DELETE_WINDOW", self.hide)
        self._build()
        self._poll()

    # ------------------------------------------------------------------ building
    def _font(self, size=10, bold=False):
        return (theme.FONT, size, "bold" if bold else "normal")

    def _build(self) -> None:
        p = self.pal
        top = tk.Frame(self.root, bg=p["bg"])
        top.pack(fill="x", padx=16, pady=(14, 6))
        bar = tk.Frame(top, bg=p["bg"])
        bar.pack(fill="x")
        for period in PERIOD_ORDER:
            b = tk.Label(bar, text=period_short(period), font=self._font(10, True), padx=10, pady=4, cursor="hand2")
            b.pack(side="left", padx=(0, 4))
            b.bind("<Button-1>", lambda _e, pr=period: self.choose(pr))
            self.period_buttons[period] = b
        self.menu_button = tk.Label(bar, text="⋯", font=self._font(16, True), fg=p["dim"], bg=p["bg"], cursor="hand2", padx=6)
        self.menu_button.pack(side="right")
        self.menu_button.bind("<Button-1>", self._popup_menu)

        card = tk.Frame(self.root, bg=p["card"], highlightbackground=p["line"], highlightthickness=1)
        card.pack(fill="x", padx=16, pady=(6, 8))
        self.total_money = tk.Label(card, text="$0", font=self._font(28, True), fg=p["fg"], bg=p["card"], anchor="w")
        self.total_money.pack(fill="x", padx=14, pady=(10, 0))
        self.total_tokens = tk.Label(card, text="", font=self._font(12), fg=p["dim"], bg=p["card"], anchor="w")
        self.total_tokens.pack(fill="x", padx=14, pady=(0, 10))

        body = tk.Frame(self.root, bg=p["bg"])
        body.pack(fill="both", expand=True, padx=16)
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TB.Treeview", background=p["card"], fieldbackground=p["card"], foreground=p["fg"], borderwidth=0,
                        rowheight=24, font=self._font(10))
        style.configure("TB.Treeview.Heading", background=p["bg"], foreground=p["dim"], font=self._font(9), borderwidth=0, relief="flat")
        style.map("TB.Treeview", background=[("selected", p["sel"])], foreground=[("selected", p["fg"])])
        style.map("TB.Treeview.Heading", background=[("active", p["bg"])])
        style.configure("TB.Vertical.TScrollbar", background=p["btn"], troughcolor=p["bg"], bordercolor=p["bg"], arrowcolor=p["dim"])
        cols = ("tokens", "cost", "price", "calls")
        self.tree = ttk.Treeview(body, columns=cols, style="TB.Treeview", selectmode="browse")
        self.tree.heading("#0", text=t("Araç / model", "Tool / model"), anchor="w")
        self.tree.heading("tokens", text="Token", anchor="e")
        self.tree.heading("cost", text="$", anchor="e")
        self.tree.heading("price", text=t("$/M (gir./çık.)", "$/M (in/out)"), anchor="e")
        self.tree.heading("calls", text=t("çağrı", "calls"), anchor="e")
        self.tree.column("#0", width=170, minwidth=120, stretch=True)
        self.tree.column("tokens", width=62, anchor="e", stretch=False)
        self.tree.column("cost", width=58, anchor="e", stretch=False)
        self.tree.column("price", width=78, anchor="e", stretch=False)
        self.tree.column("calls", width=48, anchor="e", stretch=False)
        scroll = ttk.Scrollbar(body, orient="vertical", command=self.tree.yview, style="TB.Vertical.TScrollbar")
        self.tree.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.tree.pack(side="left", fill="both", expand=True)

        foot = tk.Frame(self.root, bg=p["bg"])
        foot.pack(fill="x", padx=16, pady=(8, 12))
        self.detected_label = tk.Label(foot, text="", font=self._font(9), fg=p["dim"], bg=p["bg"], anchor="w", justify="left", wraplength=WIDTH - 40)
        self.detected_label.pack(fill="x")
        self.status_label = tk.Label(foot, text="", font=self._font(9), fg=p["dim"], bg=p["bg"], anchor="w", justify="left", wraplength=WIDTH - 40)
        self.status_label.pack(fill="x", pady=(4, 0))
        self.status_label.bind("<Button-1>", lambda _e: self._show_issues())
        self._paint_periods()

    def _paint_periods(self) -> None:
        for period, b in self.period_buttons.items():
            on = period == self.model.period
            b.configure(bg=self.pal["btn_on"] if on else self.pal["btn"], fg=self.pal["btn_on_fg"] if on else self.pal["fg"])

    # ------------------------------------------------------------------ actions
    def choose(self, period: str) -> None:
        self.model.set_period(period)
        self._paint_periods()
        self.refresh()

    def show(self) -> None:
        self.root.update_idletasks()
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        if not self._visible:
            # Next to the tray: the bottom right corner, above the taskbar.
            self.root.geometry(f"{WIDTH}x{HEIGHT}+{max(0, sw - WIDTH - 16)}+{max(0, sh - HEIGHT - 64)}")
        self.root.deiconify()
        self.root.lift()
        self.root.attributes("-topmost", True)
        self.root.after(200, lambda: self.root.attributes("-topmost", False))
        self.root.focus_force()
        self._visible = True
        self.refresh()
        self.rescan()

    def hide(self) -> None:
        self.root.withdraw()
        self._visible = False

    def toggle(self) -> None:
        if self._visible and self.root.state() != "withdrawn":
            self.hide()
        else:
            self.show()

    def request_refresh(self) -> None:
        """Safe from any thread: the window repaints on its own thread (tkinter is not thread-safe)."""
        self.jobs.put(("refresh", None))

    def background_scan_done(self) -> None:
        """Safe from any thread: the tray's own scan finished; an open window shows it."""
        self.jobs.put(("bgscan", None))

    def rescan(self) -> None:
        if self.model.scanning:
            self.set_status(t("Taranıyor…", "Scanning…"))     # the scan that runs now reports back through the tray loop
            return
        self.set_status(t("Taranıyor…", "Scanning…"))

        def work():
            result = self.model.rescan()
            self.jobs.put(("scanned", result))
        threading.Thread(target=work, daemon=True).start()

    def refresh(self) -> None:
        period = self.model.period
        self._refresh_seq += 1
        seq = self._refresh_seq

        def work():
            try:
                report = self.model.report(period)
            except Exception as e:      # never let the window die on one bad read
                self.jobs.put(("error", str(e)))
                return
            self.jobs.put(("report", (seq, report)))
        threading.Thread(target=work, daemon=True).start()

    def update_prices(self) -> None:
        if self.model.offline:
            messagebox.showinfo("TokenBar", t("Çevrimdışı açık: fiyat listeleri indirilmez.", "Offline is on: price lists are not fetched."))
            return
        self.set_status(t("Fiyatlar güncelleniyor…", "Updating prices…"))

        def work():
            try:
                report = self.model.update_prices(force=True)
            except Exception as e:
                report = e
            self.jobs.put(("prices", report))
        threading.Thread(target=work, daemon=True).start()

    def prices_when_online(self) -> None:
        """Offline was just switched off: the price lists are asked for now, not at the next round of the scanning thread
        (the Mac app's startBackgroundRefresh). A day's cache is respected, nothing is said unless something changed."""
        def work():
            try:
                report = self.model.update_prices(force=False)
            except Exception as e:
                report = e
            if report is None or (not isinstance(report, Exception) and not report.changed and not report.failed):
                self.jobs.put(("refresh", None))
            else:
                self.jobs.put(("prices", report))
        threading.Thread(target=work, daemon=True).start()

    # ------------------------------------------------------------------ the menu
    def _popup_menu(self, event=None) -> None:
        # Built again at every opening (the ticks follow the settings), and the one before is destroyed with the
        # variables its entries held: a menu and a variable that are only dropped stay in Tcl for good.
        if self._menu is not None:
            try:
                self._menu.destroy()
            except tk.TclError:
                pass
        self._menu_vars = []
        m = self._menu = tk.Menu(self.root, tearoff=0, font=self._font(10))
        m.add_command(label=t("Fiyatları güncelle", "Update prices"), command=self.update_prices)
        offline = tk.BooleanVar(value=self.model.offline)
        self._menu_vars.append(offline)
        m.add_checkbutton(label=t("Çevrimdışı", "Offline"), variable=offline, command=lambda: self._toggle_offline(offline.get()))
        if startup.available():
            at_login = tk.BooleanVar(value=startup.is_enabled())
            self._menu_vars.append(at_login)
            m.add_checkbutton(label=t("Windows ile başlat", "Start with Windows"), variable=at_login,
                              command=lambda: startup.set_enabled(at_login.get()))
        lang = tk.Menu(m, tearoff=0)
        current = tk.StringVar(value=self.model.settings["language"])
        self._menu_vars.append(current)
        for code, label in (("auto", t("Otomatik", "Automatic")), ("tr", "Türkçe"), ("en", "English")):
            lang.add_radiobutton(label=label, value=code, variable=current, command=lambda c=code: self._set_language(c))
        m.add_cascade(label=t("Dil", "Language"), menu=lang)
        m.add_separator()
        m.add_command(label=t("TokenBar hakkında", "About TokenBar"), command=self._about)
        m.add_command(label=t("Çık", "Quit"), command=self.on_quit)
        x = self.menu_button.winfo_rootx()
        y = self.menu_button.winfo_rooty() + self.menu_button.winfo_height()
        try:
            m.tk_popup(x, y)
        finally:
            m.grab_release()

    def _toggle_offline(self, value: bool) -> None:
        self.model.set_offline(value)
        if self.on_offline_changed:
            self.on_offline_changed()
        self.refresh()
        if not value:
            self.prices_when_online()

    def _set_language(self, code: str) -> None:
        self.model.set_language(code)
        messagebox.showinfo("TokenBar", t("Dil bir sonraki açılışta uygulanır.", "The language applies the next time TokenBar starts."))

    def _about(self) -> None:
        messagebox.showinfo("TokenBar", f"TokenBar {__version__}\n\n" + t(
            "Yapay zekâ kodlama araçlarının bu bilgisayardaki günlüklerini salt okunur okur. Veri bilgisayardan çıkmaz; "
            "tek ağ trafiği fiyat listeleri (kendiliğinden günde en çok bir kez, ya da siz istediğinizde).",
            "Reads the logs AI coding tools wrote on this PC, read-only. Your data never leaves this PC; the only "
            "network traffic is the price lists (at most once a day on its own, or when you ask)."))

    def _show_issues(self) -> None:
        scan = self.model.last_scan
        if scan and scan.issues:
            text = "\n".join(f"{source}: {message}" for source, message in scan.issues[:40])
            messagebox.showinfo(t("Okunamayan kaynaklar", "Sources that could not be read"), text)

    # ------------------------------------------------------------------ painting
    def set_status(self, text: str) -> None:
        self.status = text
        self.status_label.configure(text=text, fg=self.pal["dim"])

    def _poll(self) -> None:
        """Serves the jobs the worker threads posted, then plans the next turn whatever happened: a job that fails
        costs that job, never the loop (a window that stops polling shows nothing new again)."""
        try:
            while True:
                try:
                    kind, payload = self.jobs.get_nowait()
                except queue.Empty:
                    break
                try:
                    self._serve(kind, payload)
                except Exception:
                    pass
        finally:
            try:
                self.root.after(150, self._poll)
            except tk.TclError:         # the window is gone
                pass

    def _serve(self, kind, payload) -> None:
        if kind == "report":
            seq, report = payload
            if seq != self._refresh_seq:        # a newer request is under way (the period changed): this one is stale
                return
            self.report = report
            self._paint_report()
            if self.on_report:
                self.on_report(report)
        elif kind == "scanned":
            self._after_scan(payload)
        elif kind == "prices":
            self._after_prices(payload)
        elif kind == "error":
            self.set_status(payload)
        elif kind == "refresh":
            self.refresh()
        elif kind == "bgscan":
            if self._visible:
                self._after_scan(self.model.last_scan)

    def _after_scan(self, result) -> None:
        if result is None:
            return
        n = len(result.issues)
        if n:
            self.status_label.configure(text=t(f"{n} kaynak okunamadı (ayrıntı için tıkla)", f"{n} source(s) could not be read (click for details)"),
                                        fg=self.pal["warn"])
        else:
            self.set_status(t("Güncel", "Up to date") + f" · {time.strftime('%H:%M')}" + (f" · {t('fiyatlar', 'prices')} {self.model.book.date}" if self.model.book.date else ""))
        self.refresh()

    def _after_prices(self, report) -> None:
        if isinstance(report, Exception):
            self.set_status(t("Fiyatlar güncellenemedi: ", "Could not update prices: ") + str(report))
        elif report is None:
            self.set_status(t("Çevrimdışı", "Offline"))
        elif report.failed:
            self.set_status(t("Bazı fiyat listeleri alınamadı: ", "Some price lists could not be fetched: ") + ", ".join(report.failed))
        elif getattr(report, "notes", None) or self.model.book.cache_problem():
            self.set_status(" · ".join(getattr(report, "notes", None) or [self.model.book.cache_problem()]))
        else:
            self.set_status(t("Fiyatlar güncel", "Prices are up to date") + (f" · {self.model.book.date}" if self.model.book.date else ""))
        self.refresh()

    def _paint_report(self) -> None:
        r = self.report
        self._paint_periods()
        self.total_money.configure(text=money(r.cost))
        self.total_tokens.configure(text=f"{tokens(r.tokens)} {t('token', 'tokens')} · {calls(r.calls)} · {period_label(r.period)}")
        self.tree.delete(*self.tree.get_children())
        for h in r.harnesses:
            tag = f"h-{h.harness}"
            self.tree.tag_configure(tag, foreground=theme.hue_color(HUES.get(h.harness, 200), self.dark), font=self._font(10, True))
            node = self.tree.insert("", "end", text=h.name, values=(tokens(h.tokens), money(h.cost), "", h.calls), open=True, tags=(tag,))
            for m in h.models:
                price = f"{rate(m.entry['input'])} / {rate(m.entry['output'])}" if m.entry else t("fiyat yok", "no price")
                self.tree.insert(node, "end", text="   " + m.name, values=(tokens(m.tokens), money(m.cost) if m.priced else "–", price, m.calls))
        if not r.harnesses:
            self.tree.insert("", "end", text=t("Bu aralıkta çağrı yok", "No calls in this period"))
        self._paint_detected()
        self.root.event_generate("<<ReportPainted>>")

    def _paint_detected(self) -> None:
        counted = {h.harness for h in self.report.harnesses} if self.report else set()
        found, not_countable = self.model.detected()
        quiet = [harness_name(h) for h in found if h not in counted and h not in not_countable]
        parts = []
        if not_countable:
            parts.append(t("Algılandı, sayılamaz: ", "Detected, cannot be counted: ") + ", ".join(harness_name(h) for h in not_countable)
                         + " " + t("(token sayıları bilgisayarda tutulmuyor)", "(token counts are not kept on this PC)"))
        if quiet:
            parts.append(t("Algılandı, bu aralıkta çağrı yok: ", "Detected, no calls in this period: ") + ", ".join(quiet))
        self.detected_label.configure(text="\n".join(parts))
