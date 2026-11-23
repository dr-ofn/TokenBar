import os
import sys

# Prices are pinned (embedded snapshot and tables only): the same numbers on every machine, no cache, no network.
os.environ["TOKENBAR_PRICES_PINNED"] = "1"
os.environ["TOKENBAR_LANG"] = "en"
os.environ["TOKENBAR_OFFLINE"] = "1"
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import json  # noqa: E402

import pytest  # noqa: E402

from tokenbar.paths import Env  # noqa: E402
from tokenbar.prices.book import PriceBook  # noqa: E402
from tokenbar.report import build_report  # noqa: E402
from tokenbar.scanner import Scanner  # noqa: E402
from tokenbar.store import Store  # noqa: E402


class Home:
    """A made-up home folder with helpers to write tool files into it and count them."""

    def __init__(self, root):
        self.root = str(root)
        os.makedirs(self.root, exist_ok=True)
        self.env = Env.for_home(self.root)
        self.store = Store(os.path.join(self.root, "_index", "usage.sqlite"))
        self.book = PriceBook(self.env, pinned=True, offline=True)
        self.scanner = Scanner(self.store, self.env)

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def write(self, rel, text, mode="w"):
        p = self.path(*rel.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if isinstance(text, bytes):
            mode = "wb"
        with open(p, mode, **({} if "b" in mode else {"encoding": "utf-8", "newline": ""})) as f:
            f.write(text)
        return p

    def jsonl(self, rel, *rows):
        return self.write(rel, "".join(json.dumps(r) + "\n" for r in rows))

    def scan(self):
        return self.scanner.scan()

    def report(self, period="all"):
        return build_report(self.store, self.book, period)

    def total(self, harness=None):
        r = self.report()
        if harness is None:
            return r.tokens
        return next((h.tokens for h in r.harnesses if h.harness == harness), 0)

    def calls(self, harness):
        return next((h.calls for h in self.report().harnesses if h.harness == harness), 0)


@pytest.fixture
def home(tmp_path):
    h = Home(tmp_path / "home")
    yield h
    h.store.close()


def claude_line(mid="m1", req="r1", inp=1, out=1, model="claude-opus-5-5", ts="2026-11-06T10:00:00.000Z", extra=None):
    usage = {"input_tokens": inp, "output_tokens": out}
    usage.update(extra or {})
    return {"type": "assistant", "timestamp": ts, "sessionId": "s1", "requestId": req,
            "message": {"id": mid, "model": model, "usage": usage}}
