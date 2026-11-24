"""Price rules shared by scripts/update-prices.py and scripts/oracle.py.

This is the Python twin of Sources/LocalCore/ModelNames.swift, PriceFeed*.swift and Pricing.swift.
The oracle must give the same price as the CLI, so a rule changes in both places or in none.
Prices are USD per 1M tokens. A catalogue row is
    [input, output, cacheRead, cacheWrite, cacheWrite1h, [[minPrompt, input, output, cacheRead, cacheWrite, cacheWrite1h], ...], name?]
where 0 means "the catalogue does not say" (a cache price then falls back to the input price).
"""
import json
import math
import os
import re
from collections import defaultdict

# ---------------------------------------------------------------------------------------------
# Model names

REGION = r"(?:us|eu|apac|global|jp|au|ca|us-gov)"
VENDOR_DOT = (r"(?:anthropic|meta|amazon|mistral|cohere|ai21|deepseek|openai|qwen|google|moonshotai|moonshot|"
              r"minimax|zai|writer|nvidia|stability|twelvelabs)")
# Route marks that never change the model: the table row of the bare name is the price.
TAGS = {"free", "batch", "thinking", "extended", "nitro", "floor", "online", "exacto", "beta", "latest",
        "default", "flex", "priority", "standard"}
QUANT = re.compile(r"[-_.](?:\d+bit|mlx|gguf|dwq|awq|gptq|exl2|i?q\d+(?:_[a-z0-9]+)*)\Z", re.ASCII)
DATE = re.compile(r"-(?:\d{8}|\d{4}-\d{2}-\d{2})\Z", re.ASCII)
BEDROCK_VERSION = re.compile(r"-v\d+:\d+\Z", re.ASCII)
VENDOR_PREFIX = re.compile(rf"^(?:{REGION}\.)?{VENDOR_DOT}\.(?=[a-z0-9])")
REGION_PREFIX = re.compile(rf"^{REGION}\.(?=[a-z])")
FAMILY_TAIL = re.compile(r"-(?:\d{3,4}|high|medium|low|minimal|xhigh|max|\d+k)\Z", re.ASCII)
LOCAL_PROVIDERS = {"ollama", "lmstudio", "lm-studio", "mlx", "omlx", "llama.cpp", "llamacpp", "llama-cpp", "local",
                   "localhost", "jan", "gpt4all", "koboldcpp", "llamafile"}


def fold(s):
    return re.sub(r"-+", "-", re.sub(r"[._@]", "-", s))


# What the Mac app's `trimmingCharacters(in: .whitespaces)` removes from the ends of a name (CharacterSet.whitespaces: the
# characters Foundation counts as a space, listed by enumerating the set): a tab, U+0020, U+00A0, U+1680, U+2000..U+200B,
# U+202F, U+205F and U+3000. NOT the line breaks and control characters Python's str.strip() also takes (\n \r \v \f,
# U+001C..U+001F, U+0085, U+2028, U+2029): a model name that ends in one is another name, and has no price, on every platform.
MAC_SPACES = "\t \u00a0\u1680" + "".join(chr(c) for c in range(0x2000, 0x200C)) + "\u202f\u205f\u3000"


def trim(s):
    return s.strip(MAC_SPACES)


def is_space(c):
    return c in MAC_SPACES


def strip_brackets(s):
    """`[1m]`, `(high)` and the like at the end, one backward pass (what `\\s*(?:\\[[^\\]]*\\]|\\([^)]*\\))\\s*$` removes, again
    and again): a name of many groups is not scanned once per group."""
    end = len(s)
    while True:
        j = end
        while j > 0 and is_space(s[j - 1]):
            j -= 1
        if j == 0 or s[j - 1] not in ")]":
            return s[:end]
        closer = s[j - 1]
        opener = "[" if closer == "]" else "("
        # the first opener after the last closer: the group's body holds no closer
        start = s.find(opener, s.rfind(closer, 0, j - 1) + 1, j - 1)
        if start < 0:
            return s[:end]
        end = start
        while end > 0 and is_space(s[end - 1]):
            end -= 1


MAX_NAME = 256   # the longest model name that is normalised (ModelNames.maxNameLength): the steps walk a name more than once


def clean(model):
    s = strip_brackets(trim(model[:MAX_NAME]).lower())
    s = s.rsplit("/", 1)[-1]
    t = VENDOR_PREFIX.sub("", s)
    if t == s:
        t = REGION_PREFIX.sub("", s)
    return t


def identity(s):
    """The name without route marks, dates and Bedrock versions: still the model's own spelling."""
    while True:
        before = s
        s = re.sub(r"@(?:\d{8}|latest|default)\Z", "", s, flags=re.ASCII)
        s = BEDROCK_VERSION.sub("", s)
        m = re.search(r":([a-z0-9_.-]+)\Z", s)
        if m:
            s = s[:m.start()] + ("" if m.group(1) in TAGS else "-" + m.group(1))
        s = DATE.sub("", s)
        if s == before:
            return s


def variant_free(s):
    while True:
        before = s
        for suffix in ("-free", "-thinking", "-latest"):
            if s.endswith(suffix):
                s = s[:-len(suffix)]
        s = DATE.sub("", s)
        if s == before:
            return s


def quant_free(s):
    """(name without local quantisation or format suffixes, whether it had any)."""
    found = False
    while True:
        t = QUANT.sub("", s)
        if t == s or not t:
            return s, found
        s, found = t, True


class Keys:
    """The lookup keys of one logged name, most specific first."""

    def __init__(self, model):
        base = clean(model)
        ident = identity(base)
        self.key1 = fold(ident)
        self.key2 = fold(variant_free(ident))
        stripped, self.quantised = quant_free(ident)
        self.quant = fold(variant_free(stripped)) if self.quantised else None
        self.ordered = unique([self.key1, self.key2] + ([self.quant] if self.quant else []))


def unique(items):
    seen, out = set(), []
    for x in items:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def is_local_provider(provider, extra=()):
    p = trim(provider).lower().replace("_", "-")
    return p in LOCAL_PROVIDERS or p in {trim(e).lower().replace("_", "-") for e in extra}


# ---------------------------------------------------------------------------------------------
# Catalogue rows from the three raw sources

MAX_RATE = 1_000_000.0  # PriceLimits.maxRate: USD per 1M tokens, far above any model
MAX_TIER_TOKENS = 1_000_000_000_000  # a tier threshold above this is a corrupt row


def num(value):
    """A finite float from a number or a numeric string; JSON true/false, anything else and anything that is not finite
    (NaN, Infinity, 1e999) is 0 (the app's `num`): a bool is never a price, so it can never become $1 per token."""
    if isinstance(value, bool):
        return 0.0
    try:
        v = float(value)
    except (TypeError, ValueError, OverflowError):
        return 0.0
    return v if math.isfinite(v) else 0.0


def per_million(value):
    return round(num(value) * 1_000_000, 6)


def is_rate(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= MAX_RATE


def alias_number(value):
    """`num`, except that a JSON true is 1 and false 0 in a hand-written alias, as on the Mac (an NSNumber): the one place
    a bool counts as a number, an accepted edge. A catalogue row never takes it."""
    return float(value) if isinstance(value, bool) else num(value)


def alias_rates_ok(value):
    """A hand-written price meets the bound a catalogue row does (Swift UserAliases.target): else the entry is dropped."""
    vals = [alias_number(value.get(k)) for k in ("input", "output", "cacheRead", "cacheWrite")]
    return vals[0] > 0 and vals[1] > 0 and all(is_rate(v) for v in vals)


def given(d, key, fallback):
    """A tier's own price, or the base row's when the tier leaves it out (a JSON null is "not given" like a missing key)."""
    return num(d[key]) if d.get(key) is not None else fallback


def tier_sane(t):
    return (isinstance(t, (list, tuple)) and len(t) >= 6 and 1 <= t[0] <= MAX_TIER_TOKENS + 1 and t[1] > 0 and t[2] > 0
            and all(is_rate(x) for x in t[1:6]))


def row_ok(row):
    """A priced row (the app's `row_sane`): both prices positive, every rate finite and at most MAX_RATE, every tier sane."""
    try:
        return (row[0] > 0 and row[1] > 0 and all(is_rate(x) for x in row[:5])
                and all(tier_sane(t) for t in (row[5] if len(row) > 5 else [])))
    except (TypeError, IndexError):
        return False


def _start(v):
    """A tier threshold: a whole positive number of tokens that fits, else None (the row is corrupt)."""
    n = num(v)
    return int(n) if 0 < n <= MAX_TIER_TOKENS else None


def openrouter_rows(raw):
    """id -> row. Routers priced -1 and anything at zero are left out."""
    out = {}
    data = raw.get("data") if isinstance(raw, dict) else None
    for m in data if isinstance(data, list) else []:
        if not isinstance(m, dict) or not isinstance(m.get("id"), str) or not isinstance(m.get("pricing"), dict):
            continue
        p = m["pricing"]
        base = [per_million(p.get("prompt")), per_million(p.get("completion")), max(per_million(p.get("input_cache_read")), 0),
                max(per_million(p.get("input_cache_write")), 0), max(per_million(p.get("input_cache_write_1h")), 0)]
        overrides = [t for t in (p.get("overrides") if isinstance(p.get("overrides"), list) else [])
                     if isinstance(t, dict) and "min_prompt_tokens" in t]
        overrides.sort(key=lambda t: num(t["min_prompt_tokens"]))
        tiers, corrupt = [], False
        for t in overrides:
            start = _start(t["min_prompt_tokens"])
            if start is None:
                corrupt = True
                break
            # a cache price the tier does not state is the base row's (as a LiteLLM tier carries it), not 0: 0 would make
            # it the tier's input price
            # (a JSON null is "not given" like a missing key)
            tiers.append([start,
                          per_million(t["prompt"]) if t.get("prompt") is not None else base[0],
                          per_million(t["completion"]) if t.get("completion") is not None else base[1],
                          per_million(t["input_cache_read"]) if t.get("input_cache_read") is not None else base[2],
                          per_million(t["input_cache_write"]) if t.get("input_cache_write") is not None else base[3],
                          per_million(t["input_cache_write_1h"]) if t.get("input_cache_write_1h") is not None else base[4]])
        name = m.get("name") if isinstance(m.get("name"), str) else ""
        colon = name.find(":")
        if 1 <= colon <= 40:
            name = trim(name[colon + 1:])
        row = base + [tiers, name]
        if not corrupt and row_ok(row):
            out[m["id"]] = row
    return out


LITELLM_TIER = re.compile(r"^(input_cost_per_token|output_cost_per_token|cache_read_input_token_cost|"
                          r"cache_creation_input_token_cost|cache_creation_input_token_cost_above_1hr)_above_([0-9]+)k_tokens\Z")
LITELLM_FIELDS = ("input_cost_per_token", "output_cost_per_token", "cache_read_input_token_cost",
                  "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr")


def litellm_rows(raw):
    out = {}
    if not isinstance(raw, dict):
        return out
    for key, v in raw.items():
        if key == "sample_spec" or not isinstance(v, dict) or v.get("mode") not in ("chat", "completion", "responses", None):
            continue
        base = [per_million(v.get(f)) for f in LITELLM_FIELDS]
        thresholds = defaultdict(dict)
        corrupt = False
        for field, value in v.items():
            m = LITELLM_TIER.match(field)
            if m and isinstance(value, (int, float)) and not isinstance(value, bool):
                # `<N>k` must be a whole number of thousands a prompt can have; a longer run of digits (Python refuses to turn one of
                # 4300 digits into an integer at all) spoils this row only, as on the Mac: never the whole catalogue
                digits = m.group(2).lstrip("0")
                k = int(digits or "0") if len(digits) <= 20 else 0
                if not (1 <= k <= MAX_TIER_TOKENS // 1000):
                    corrupt = True
                    continue
                thresholds[k * 1000][m.group(1)] = per_million(value)
        tiers, carried = [], list(base)
        for threshold in sorted(thresholds):
            carried = [thresholds[threshold].get(f, carried[i]) for i, f in enumerate(LITELLM_FIELDS)]
            tiers.append([threshold + 1] + carried)
        row = base + [tiers]
        if not corrupt and row_ok(row):
            out[key] = row
    return out


def modelsdev_rows(raw):
    """"provider/model" -> row, with the provider's own model id after the first slash."""
    out = {}
    if not isinstance(raw, dict):
        return out
    for provider, body in raw.items():
        models = body.get("models") if isinstance(body, dict) else None
        if not isinstance(models, dict):
            continue
        for model_id, m in models.items():
            c = m.get("cost") if isinstance(m, dict) else None
            if not isinstance(c, dict):
                continue
            base = [num(c.get("input")), num(c.get("output")), num(c.get("cache_read")), num(c.get("cache_write")), 0.0]
            ctx = [t for t in (c.get("tiers") if isinstance(c.get("tiers"), list) else [])
                   if isinstance(t, dict) and isinstance(t.get("tier"), dict) and t["tier"].get("type") == "context"]
            ctx.sort(key=lambda t: num(t["tier"].get("size")))
            tiers, corrupt = [], False
            for t in ctx:
                size = _start(t["tier"].get("size"))
                if size is None:
                    corrupt = True
                    break
                tiers.append([size + 1, given(t, "input", base[0]), given(t, "output", base[1]),
                              given(t, "cache_read", base[2]), given(t, "cache_write", base[3]), 0.0])
            over = c.get("context_over_200k")
            if not tiers and isinstance(over, dict):
                tiers.append([200001, given(over, "input", base[0]), given(over, "output", base[1]),
                              given(over, "cache_read", base[2]), given(over, "cache_write", base[3]), 0.0])
            name = m.get("name") if isinstance(m.get("name"), str) else ""
            row = base + [tiers, name]
            if not corrupt and row_ok(row):
                out[f"{provider}/{model_id}"] = row
    return out


# ---------------------------------------------------------------------------------------------
# One catalogue: rows by id and by key

def catalogue_key(source, row_id):
    return Keys(row_id.split("/", 1)[1] if source == "modelsdev" and "/" in row_id else row_id).key1


def route_tagged(row_id):
    """"vendor/model:free", ":batch" ...: the bare row is the model's price, the tagged one a variant."""
    return ":" in BEDROCK_VERSION.sub("", row_id)


def depth(source, row_id):
    model = row_id.split("/", 1)[1] if source == "modelsdev" and "/" in row_id else row_id
    last = model.rsplit("/", 1)[-1].lower()
    return model.count("/") + (1 if VENDOR_PREFIX.match(last) or REGION_PREFIX.match(last) else 0)


def choose(source, items):
    """The row that speaks for a key: the shallowest ids, then the middle price of those."""
    best = min(depth(source, i) for i, _ in items)
    shallow = sorted(((i, r) for i, r in items if depth(source, i) == best), key=lambda x: (x[1][0], x[1][1], x[0]))
    middle = shallow[(len(shallow) - 1) // 2][1]
    # Of the rows at that price the first id (the list is sorted by price, then id).
    return next((i, r) for i, r in shallow if r[0] == middle[0] and r[1] == middle[1])


class Catalogue:
    def __init__(self, source, rows, exact=None):
        """`rows` are indexed by id and by key; `exact` are rows only a lookup by exact id reaches (see `split`): they
        join the id index and never speak for a key."""
        self.source = source
        self.by_id = {}
        groups = defaultdict(list)
        for row_id, row in rows.items():
            if route_tagged(row_id):
                continue
            groups[catalogue_key(source, row_id)].append((row_id, row))
        if source != "modelsdev":
            # Ids that differ only in case share one slot: the first in sorted order keeps it, so the whole catalogue and
            # the one built again from winners and exact rows agree, whatever order the rows came in.
            every = dict(exact or {})
            every.update(rows)
            for row_id in sorted(every):
                self.by_id.setdefault(row_id.lower(), (row_id, every[row_id]))
        self.by_key = {k: choose(source, v) for k, v in groups.items()}


CATALOGUE_NAMES = {"openrouter": "OpenRouter", "litellm": "LiteLLM", "modelsdev": "models.dev"}


def split(source, rows):
    """What the embedded snapshot (and the app's cache) keeps of a catalogue: (winners, exact). `winners` are the row the
    index picks for each key (the only rows that speak for a name); `exact` are the other rows (OpenRouter and LiteLLM)
    that a lookup by exact id can still return with a price of their own: a route (`:batch`, `:nitro`), a provider
    (`vertex_ai/...`), a dated or regional id, whatever its price. They are kept
    apart because the winner of a key is chosen among all its rows: a catalogue built again from the kept rows has to
    choose the same winners."""
    whole = Catalogue(source, rows)
    winners = {row_id: row for row_id, row in whole.by_key.values()}
    if source == "modelsdev":
        return winners, {}
    # Every other row stays, even one that says what its key's winner says: whole, a lookup by that exact id answers from
    # this catalogue before any later catalogue is asked, and a cache without the row would hand the name to the next one.
    return winners, {row_id: row for row_id, row in rows.items() if row_id not in winners}


def thin(source, rows):
    """The rows the embedded snapshot keeps as winners (see `split`)."""
    return split(source, rows)[0]


# ---------------------------------------------------------------------------------------------
# Entries and resolution

ACRONYMS = {"gpt": "GPT", "glm": "GLM", "oss": "OSS", "vl": "VL", "moe": "MoE", "llm": "LLM",
            "ai": "AI", "ocr": "OCR", "asr": "ASR", "tts": "TTS", "cli": "CLI"}
BRANDS = {"deepseek": "DeepSeek", "minimax": "MiniMax", "mimo": "MiMo", "longcat": "LongCat",
          "sensenova": "SenseNova", "openai": "OpenAI", "qwen": "Qwen"}


def display_name(model):
    """Python twin of ModelNames.display: `claude-mythos-5-2` is "Claude Mythos 5.2", `gpt-6.2-sol` "GPT-6.2 Sol"."""
    words = [w for w in re.split(r"[-_]", identity(clean(model))) if w]
    if not words:
        return model

    def digit(c):
        return c.isascii() and c.isdigit()

    def small(w):
        return 0 < len(w) <= 2 and all(digit(c) for c in w)

    def has_digit(w):
        return any(digit(c) for c in w)

    merged = []
    for w in words:
        if small(w) and merged and digit(merged[-1][-1]):
            merged[-1] = merged[-1] + "." + w
        else:
            merged.append(w)
    words = merged

    def cased(w):
        if w in ACRONYMS:
            return ACRONYMS[w]
        if w in BRANDS:
            return BRANDS[w]
        if has_digit(w):
            return w.upper() if len(w) <= 4 or w[0].isnumeric() else w[:1].upper() + w[1:]
        return w[:1].upper() + w[1:]

    out = []
    for i, w in enumerate(words):
        c = cased(w)
        if i > 0 and out and ACRONYMS.get(words[i - 1]) == "GPT" and has_digit(w) and not any(ch.isalpha() for ch in w):
            out[-1] = out[-1] + "-" + c
        else:
            out.append(c)
    return " ".join(out)


def model_part(kind, row_id):
    """models.dev ids are `provider/model-id`; the provider is not part of the model's name."""
    return row_id.split("/", 1)[1] if kind == "modelsdev" and "/" in row_id else row_id


def entry_from_row(kind, catalog, row_id, row, key):
    """An entry as the Swift PriceEntry holds it. A missing cache price takes the input price."""
    def rates(r):
        inp, out, read, write, write1h = r[:5]
        write = write or inp
        return {"input": inp, "output": out, "cacheRead": read or inp, "cacheWrite": write, "cacheWrite1h": write1h or write}

    tiers = []
    for t in row[5] if len(row) > 5 else []:
        tiers.append(dict(minPrompt=t[0], **rates(t[1:6])))
    name = row[6] if len(row) > 6 and row[6] else display_name(model_part(kind, row_id))
    return dict(key=key, name=name, kind=kind, catalog=catalog, catalogID=row_id,
                source=f"{catalog}: {row_id}", tiers=tiers, **rates(row[:5]))


def override_key(entry_key):
    return Keys(entry_key).key1


ALIAS_DEPTH = 4      # `a` to `b` to `c` to `d` to `e` is four steps and is priced, a fifth is not
ALIAS_LOOP = object()


class Pricer:
    """Resolves a logged (provider, model) to an entry or None. `catalogues` keeps the lookup order."""

    def __init__(self, catalogues, override=(), aliases=None, local_providers=()):
        self.catalogues = catalogues
        self.override = {override_key(e["key"]): e for e in override}
        self.aliases = {Keys(k).key1: v for k, v in (aliases or {}).items()}
        self.local_providers = tuple(local_providers)

    # -- stages ---------------------------------------------------------------------------
    def table_hit(self, table, keys):
        for k in keys:
            if k in table:
                return table[k]
        return None

    def named(self, entry, row, keys):
        """A row the catalogue left without a name takes the name another catalogue gives the same model, else the
        readable form of its id (already in `entry`). Only the label changes, never a price."""
        if len(row) > 6 and row[6]:
            return entry
        for cat in self.catalogues:
            for k in keys:
                other = cat.by_key.get(k)
                if other and len(other[1]) > 6 and other[1][6]:
                    return dict(entry, name=other[1][6])
        return entry

    def catalogue_hit(self, name, keys, raw, only=None):
        catalogues = [c for c in self.catalogues if only is None or c.source == only]
        if raw is not None:
            for cat in catalogues:
                if cat.source in ("openrouter", "litellm") and raw in cat.by_id:
                    row_id, row = cat.by_id[raw]
                    return self.named(entry_from_row(cat.source, CATALOGUE_NAMES[cat.source], row_id, row, keys[0]), row, keys)
        for k in keys:
            for cat in catalogues:
                if k in cat.by_key:
                    row_id, row = cat.by_key[k]
                    return self.named(entry_from_row(cat.source, CATALOGUE_NAMES[cat.source], row_id, row, k), row, keys)
        return None

    def lookup(self, model, keys, raw):
        """override, exact id, normalised name. Returns an entry or None."""
        hit = self.table_hit(self.override, keys.ordered)
        if hit:
            # a table row of kind "openrouter" is a copy of an OpenRouter price pinned at the table's date: the live (or
            # cached) OpenRouter catalogue, when it lists the model, is that price today. Stand-ins ("near") and prices
            # published elsewhere ("other") are for models no catalogue lists, and stay as the table says.
            if hit.get("kind") == "openrouter":
                live = self.catalogue_hit(model, keys.ordered, raw, only="openrouter")
                if live is not None:
                    return live
            return dict(hit)
        return self.catalogue_hit(model, keys.ordered, raw)

    def resolve(self, provider, model):
        if len(model) > MAX_NAME:            # no model has a name this long: such a line is not a model
            return None
        keys = Keys(model)
        raw = strip_brackets(trim(model).lower())
        local = is_local_provider(provider, self.local_providers) or keys.quantised
        k = next((k for k in keys.ordered if k in self.aliases), None)
        if k is not None:
            hit = self.apply_alias(self.aliases[k], keys.key1, k, frozenset([k]))
            if hit is ALIAS_LOOP:
                return None
            if hit is not None:
                return hit
        hit = self.lookup(model, keys, raw)
        if hit:
            if local:
                hit = dict(hit, kind="localCloud", source="yerel → bulut karşılığı: " + hit["source"])
            return hit
        if local:
            return dict(key=keys.key1, name=model, kind="localFree", catalog=None, catalogID=None,
                        source="yerel, bulut karşılığı yok", tiers=[], input=0.0, output=0.0, cacheRead=0.0,
                        cacheWrite=0.0, cacheWrite1h=0.0)
        # Family proxy: drop an account number, effort word or context size, at most twice.
        name = keys.key2
        for _ in range(2):
            m = FAMILY_TAIL.search(name)
            if not m:
                break
            name = name[:m.start()]
            proxy = Keys(name)
            # An alias for the shorter name covers its account-numbered or effort-marked variants too.
            k = next((k for k in proxy.ordered if k in self.aliases), None)
            hit = self.apply_alias(self.aliases[k], proxy.key1, k, frozenset([k])) if k is not None else None
            if hit is ALIAS_LOOP:
                return None
            hit = hit or self.lookup(name, proxy, None)
            if hit:
                return dict(hit, kind="approximate", source=f"yaklaşık: {keys.key2} → {name} ({hit['source']})")
        return None

    def apply_alias(self, alias, key, own=None, visited=frozenset(), steps=0):
        """An entry, None (a target nothing lists: the logged name is priced the ordinary way) or ALIAS_LOOP (a loop, or a
        chain of too many steps: unpriced). `own` is the alias name being applied, `visited` the alias names of the chain so
        far, `steps` how many alias-to-alias steps led here."""
        if isinstance(alias, str):
            target = Keys(alias)
            found = None
            # the target may be another alias name: follow it. A name already met, or a fifth step, is a loop or a chain
            # too long: unpriced. An alias that names itself ("gpt-4o": "azure/gpt-4o") points at the catalogue.
            for k in target.ordered:
                if k in self.aliases:
                    if k != own:
                        if k in visited or steps >= ALIAS_DEPTH:
                            return ALIAS_LOOP
                        found = self.apply_alias(self.aliases[k], target.key1, k, visited | {k}, steps + 1)
                        if found is ALIAS_LOOP:
                            return ALIAS_LOOP
                    break
            hit = found or self.lookup(alias, target, strip_brackets(trim(alias).lower()))
            if hit is None:
                return None
            return dict(hit, kind="alias", source=f"kullanıcı takma adı: {key} → {alias} ({hit['source']})")
        if alias.get("free") is True:
            return dict(key=key, name=key, kind="localFree", catalog=None, catalogID=None,
                        source=f"kullanıcı takma adı: {key} → ücretsiz", tiers=[], input=0.0, output=0.0,
                        cacheRead=0.0, cacheWrite=0.0, cacheWrite1h=0.0)
        if isinstance(alias.get("as"), str) and alias["as"]:
            return self.apply_alias(alias["as"], key, own, visited, steps)
        inp, out = alias_number(alias.get("input")), alias_number(alias.get("output"))
        if alias_rates_ok(alias):
            # 0 is a price (a free cache); only a key that is not there (or is null) leaves the cache priced like input
            read = alias_number(alias["cacheRead"]) if alias.get("cacheRead") is not None else inp
            write = alias_number(alias["cacheWrite"]) if alias.get("cacheWrite") is not None else inp
            note = alias.get("source") if isinstance(alias.get("source"), str) and alias["source"] else None
            kind = alias.get("kind") if alias.get("kind") in ("near", "other") else "alias"
            return dict(key=key, name=alias.get("name") if isinstance(alias.get("name"), str) else key, kind=kind,
                        catalog=None, catalogID=None,
                        source=f"kullanıcı takma adı: {key} → elle yazılmış fiyat" + (f" ({note})" if note else ""),
                        tiers=[], input=inp, output=out, cacheRead=read, cacheWrite=write, cacheWrite1h=write)
        return None


def call_cost(entry, counts, cw1h, tiered=True):
    """USD of one call. counts = (input, cacheRead, cacheWrite, output). A summed row has no tier."""
    inp, cr, cw, out = counts[:4]
    rate = entry
    if tiered:
        prompt = inp + cr + cw
        for tier in entry["tiers"]:
            if prompt >= tier["minPrompt"]:
                rate = tier
    return (inp * rate["input"] + cr * rate["cacheRead"] + (cw - cw1h) * rate["cacheWrite"]
            + cw1h * rate["cacheWrite1h"] + out * rate["output"]) / 1_000_000


# ---------------------------------------------------------------------------------------------
# The shipped data

HERE = os.path.dirname(os.path.abspath(__file__))
SNAPSHOT = os.path.join(os.path.dirname(HERE), "Sources", "LocalCore", "Resources", "prices-snapshot.json")


def load_snapshot(path=SNAPSHOT):
    data = json.load(open(path, encoding="utf-8"))
    exact = data.get("exact") or {}
    return [Catalogue("litellm", data["litellm"], exact.get("litellm")), Catalogue("modelsdev", data["modelsdev"])]


def load_tables(path=os.path.join(HERE, "prices.json")):
    data = json.load(open(path, encoding="utf-8"))
    return data["entries"]


def load_aliases(path):
    """The user's alias file: {"aliases": {...}, "localProviders": [...]} (or the aliases alone)."""
    try:
        data = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return {}, []
    if not isinstance(data, dict):
        return {}, []
    if "aliases" in data or "localProviders" in data:
        raw = data.get("aliases") if isinstance(data.get("aliases"), dict) else {}
    else:
        raw = data
    aliases = {}
    for name, value in raw.items():
        if isinstance(value, str) and value:
            aliases[name] = value
        elif isinstance(value, dict) and (value.get("free") is True or (isinstance(value.get("as"), str) and value["as"])
                                          or alias_rates_ok(value)):
            aliases[name] = value
    providers = data.get("localProviders") if isinstance(data.get("localProviders"), list) else []
    return aliases, [p for p in providers if isinstance(p, str)]


def shipped_pricer(aliases=None, local_providers=()):
    return Pricer(load_snapshot(), load_tables(), aliases, local_providers)
