"""Model names, catalogue rows and price resolution.

Prices are USD per 1M tokens. A catalogue row is
    [input, output, cacheRead, cacheWrite, cacheWrite1h, [[minPrompt, input, output, cacheRead, cacheWrite, cacheWrite1h], ...], name?]
where 0 means "the catalogue does not say" (a cache price then falls back to the input price).
A cloud model is never free here: the picture shows API-equivalent use. A model that runs on this PC is priced as
its cloud counterpart when there is one, and costs nothing when there is not.
"""
from __future__ import annotations

import math
import re
from collections import defaultdict

# ---------------------------------------------------------------------------------------------- limits

MAX_RATE = 1_000_000.0                  # USD per 1M tokens: a dollar a token is far above any model
MAX_TIER_TOKENS = 1_000_000_000_000


def is_rate(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= MAX_RATE


def tier_sane(t) -> bool:
    return (isinstance(t, (list, tuple)) and len(t) >= 6 and 1 <= t[0] <= MAX_TIER_TOKENS + 1 and t[1] > 0 and t[2] > 0
            and all(is_rate(x) for x in t[1:6]))


def row_sane(row) -> bool:
    """A priced row: both prices positive, every rate finite and at most MAX_RATE, every tier sane."""
    try:
        return (row[0] > 0 and row[1] > 0 and all(is_rate(x) for x in row[:5])
                and all(tier_sane(t) for t in (row[5] if len(row) > 5 else [])))
    except (TypeError, IndexError):
        return False


def compact_row(a):
    """A row from the snapshot or a cache file, or None when it is not a sane priced row."""
    if not isinstance(a, list) or len(a) < 5:
        return None
    try:
        nums = [num(x) for x in a[:5]]
        tiers = []
        if len(a) > 5 and isinstance(a[5], list):
            for t in a[5]:
                if isinstance(t, list) and len(t) >= 6:
                    start = num(t[0])
                    if not (1 <= start <= MAX_TIER_TOKENS + 1):
                        return None
                    tiers.append([int(start)] + [num(x) for x in t[1:6]])
        row = nums + [tiers]
        if len(a) > 6 and isinstance(a[6], str):
            row.append(a[6])
    except (TypeError, ValueError, OverflowError):
        return None
    return row if row_sane(row) else None


def compact_rows(d):
    if not isinstance(d, dict):
        return None
    out = {}
    for rid, a in d.items():
        row = compact_row(a)
        if row is not None and isinstance(rid, str):
            out[rid] = row
    return out or None


# ---------------------------------------------------------------------------------------------- model names

REGION = r"(?:us|eu|apac|global|jp|au|ca|us-gov)"
VENDOR_DOT = (r"(?:anthropic|meta|amazon|mistral|cohere|ai21|deepseek|openai|qwen|google|moonshotai|moonshot|"
              r"minimax|zai|writer|nvidia|stability|twelvelabs)")
TAGS = {"free", "batch", "thinking", "extended", "nitro", "floor", "online", "exacto", "beta", "latest",
        "default", "flex", "priority", "standard"}
QUANT = re.compile(r"[-_.](?:\d+bit|mlx|gguf|dwq|awq|gptq|exl2|i?q\d+(?:_[a-z0-9]+)*)$")
DATE = re.compile(r"-(?:\d{8}|\d{4}-\d{2}-\d{2})$")
BEDROCK_VERSION = re.compile(r"-v\d+:\d+$")
VENDOR_PREFIX = re.compile(rf"^(?:{REGION}\.)?{VENDOR_DOT}\.(?=[a-z0-9])")
REGION_PREFIX = re.compile(rf"^{REGION}\.(?=[a-z])")
FAMILY_TAIL = re.compile(r"-(?:\d{3,4}|high|medium|low|minimal|xhigh|max|\d+k)$")
LOCAL_PROVIDERS = {"ollama", "lmstudio", "lm-studio", "mlx", "omlx", "llama.cpp", "llamacpp", "llama-cpp", "local",
                   "localhost", "jan", "gpt4all", "koboldcpp", "llamafile"}


def fold(s):
    return re.sub(r"-+", "-", re.sub(r"[._@]", "-", s))


def strip_brackets(s):
    """`[1m]`, `(high)` and the like at the end, one backward pass (what `\\s*(?:\\[[^\\]]*\\]|\\([^)]*\\))\\s*$` removes, again
    and again): a name of many groups is not scanned once per group."""
    end = len(s)
    while True:
        j = end
        while j > 0 and s[j - 1].isspace():
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
        while end > 0 and s[end - 1].isspace():
            end -= 1


MAX_NAME = 256   # the longest model name that is normalised (ModelNames.maxNameLength): the steps walk a name more than once


def clean(model):
    s = strip_brackets(model[:MAX_NAME].strip().lower())
    s = s.rsplit("/", 1)[-1]
    t = VENDOR_PREFIX.sub("", s)
    if t == s:
        t = REGION_PREFIX.sub("", s)
    return t


def identity(s):
    """The name without route marks, dates and Bedrock versions: still the model's own spelling."""
    while True:
        before = s
        s = re.sub(r"@(?:\d{8}|latest|default)$", "", s)
        s = BEDROCK_VERSION.sub("", s)
        m = re.search(r":([a-z0-9_.-]+)$", s)
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


def unique(items):
    seen, out = set(), []
    for x in items:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


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


def provider_key(p: str) -> str:
    return p.strip().lower().replace("_", "-")


def is_local_provider(provider, extra=()):
    p = provider_key(provider)
    return p in LOCAL_PROVIDERS or p in {provider_key(e) for e in extra}


def normalize(model: str) -> str:
    """Grouping key of a model with no price: lower case, no provider path, no free mark or date stamp."""
    name = model.lower()
    if "/" in name:
        name = name[name.rindex("/") + 1:]
    for suffix in (":free", "-free"):
        if name.endswith(suffix):
            name = name[:-len(suffix)]
            break
    tail = name[-9:]
    if len(tail) == 9 and tail[0] == "-" and tail[1:].isascii() and tail[1:].isdigit():
        name = name[:-9]
    return name


# ---------------------------------------------------------------------------------------------- display names

ACRONYMS = {"gpt": "GPT", "glm": "GLM", "oss": "OSS", "vl": "VL", "moe": "MoE", "llm": "LLM", "ai": "AI", "ocr": "OCR",
            "asr": "ASR", "tts": "TTS", "cli": "CLI"}
BRANDS = {"deepseek": "DeepSeek", "minimax": "MiniMax", "mimo": "MiMo", "longcat": "LongCat", "sensenova": "SenseNova",
          "openai": "OpenAI", "qwen": "Qwen"}


def display(model: str) -> str:
    """A readable name for a catalogue id that has no name of its own: `claude-mythos-5-2` is "Claude Mythos 5.2",
    `gpt-6.2-sol` "GPT-6.2 Sol". Only a name for the picture: it never takes part in a lookup."""
    words = [w for w in re.split(r"[-_]", identity(clean(model))) if w]
    if not words:
        return model

    def small(w):
        return 0 < len(w) <= 2 and w.isascii() and w.isdigit()

    def has_digit(w):
        return any(c.isascii() and c.isdigit() for c in w)

    merged = []
    for w in words:
        if small(w) and merged and merged[-1][-1].isascii() and merged[-1][-1].isdigit():
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
            return w.upper() if len(w) <= 4 or w[0].isdigit() else w[0].upper() + w[1:]
        return w[0].upper() + w[1:]

    out = []
    for i, w in enumerate(words):
        c = cased(w)
        if i > 0 and out and ACRONYMS.get(words[i - 1]) == "GPT" and has_digit(w) and not any(ch.isalpha() for ch in w):
            out[-1] = out[-1] + "-" + c
        else:
            out.append(c)
    return " ".join(out)


# ---------------------------------------------------------------------------------------------- catalogue rows

def num(value):
    """A finite float from a number or a numeric string; anything else is 0."""
    if isinstance(value, bool):
        return 0.0
    try:
        v = float(value)
    except (TypeError, ValueError, OverflowError):
        return 0.0
    return v if math.isfinite(v) else 0.0


def per_million(value):
    return round(num(value) * 1_000_000, 6)


def _start(v):
    """A tier threshold: a whole positive number of tokens that fits, else None (the row is corrupt)."""
    n = num(v)
    return int(n) if 0 < n <= MAX_TIER_TOKENS else None


def openrouter_rows(raw):
    """id -> row. Routers priced -1 and anything at zero are left out; time-of-day overrides are not tiers."""
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
            name = name[colon + 1:].strip()
        row = base + [tiers, name]
        if not corrupt and row_sane(row):
            out[m["id"]] = row
    return out or None


LITELLM_FIELDS = ("input_cost_per_token", "output_cost_per_token", "cache_read_input_token_cost",
                  "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr")
LITELLM_TIER = re.compile(r"^(" + "|".join(LITELLM_FIELDS) + r")_above_(\d+)k_tokens$")


def litellm_rows(raw):
    out = {}
    if not isinstance(raw, dict):
        return None
    for key, v in raw.items():
        if key == "sample_spec" or not isinstance(v, dict) or v.get("mode") not in ("chat", "completion", "responses", None):
            continue
        base = [per_million(v.get(f)) for f in LITELLM_FIELDS]
        thresholds = defaultdict(dict)
        corrupt = False
        for field, value in v.items():
            m = LITELLM_TIER.match(field)
            if m and isinstance(value, (int, float)) and not isinstance(value, bool):
                k = int(m.group(2))
                if not (1 <= k <= MAX_TIER_TOKENS // 1000):
                    corrupt = True
                    continue
                thresholds[k * 1000][m.group(1)] = per_million(value)
        tiers, carried = [], list(base)
        for threshold in sorted(thresholds):
            carried = [thresholds[threshold].get(f, carried[i]) for i, f in enumerate(LITELLM_FIELDS)]
            tiers.append([threshold + 1] + carried)
        row = base + [tiers]
        if not corrupt and row_sane(row):
            out[key] = row
    return out or None


def modelsdev_rows(raw):
    """"provider/model" -> row, with the provider's own model id after the first slash."""
    out = {}
    if not isinstance(raw, dict):
        return None
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
                tiers.append([size + 1, num(t["input"]) if t.get("input") is not None else base[0],
                              num(t["output"]) if t.get("output") is not None else base[1],
                              num(t["cache_read"]) if t.get("cache_read") is not None else base[2],
                              num(t["cache_write"]) if t.get("cache_write") is not None else base[3], 0.0])
            over = c.get("context_over_200k")
            if not tiers and isinstance(over, dict):
                tiers.append([200001, num(over["input"]) if over.get("input") is not None else base[0],
                              num(over["output"]) if over.get("output") is not None else base[1],
                              num(over["cache_read"]) if over.get("cache_read") is not None else base[2],
                              num(over["cache_write"]) if over.get("cache_write") is not None else base[3], 0.0])
            row = base + [tiers, str(m.get("name") or "")]
            if not corrupt and row_sane(row):
                out[f"{provider}/{model_id}"] = row
    return out or None


PARSERS = {"openrouter": openrouter_rows, "litellm": litellm_rows, "modelsdev": modelsdev_rows}


# ---------------------------------------------------------------------------------------------- one catalogue

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
    """The row that speaks for a key: the shallowest ids, then the middle price of those, then the first id."""
    best = min(depth(source, i) for i, _ in items)
    shallow = sorted(((i, r) for i, r in items if depth(source, i) == best), key=lambda x: (x[1][0], x[1][1], x[0]))
    middle = shallow[(len(shallow) - 1) // 2][1]
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


def split(source, rows):
    """What a cache file or the snapshot keeps of a whole catalogue: (winners, exact). `winners` are the row the index
    picks for each key (the only rows that speak for a name); `exact` are the other rows (OpenRouter and LiteLLM) that
    a lookup by exact id can still return with a price of their own: a route (`:batch`, `:nitro`), a provider
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


CATALOGUE_NAMES = {"openrouter": "OpenRouter", "litellm": "LiteLLM", "modelsdev": "models.dev"}
SOURCES = ("openrouter", "litellm", "modelsdev")


# ---------------------------------------------------------------------------------------------- resolution

def entry_from_row(kind, catalog, row_id, row, key):
    """An entry as the Mac `PriceEntry` holds it. A missing cache price takes the input price."""
    def rates(r):
        inp, out, read, write, write1h = r[:5]
        write = write or inp
        return {"input": inp, "output": out, "cacheRead": read or inp, "cacheWrite": write, "cacheWrite1h": write1h or write}

    tiers = [dict(minPrompt=t[0], **rates(t[1:6])) for t in (row[5] if len(row) > 5 else [])]
    part = row_id.split("/", 1)[1] if kind == "modelsdev" and "/" in row_id else row_id
    name = row[6] if len(row) > 6 and row[6] else display(part)
    return dict(key=key, name=name, kind=kind, catalog=catalog, catalogID=row_id, source=f"{catalog}: {row_id}",
                tiers=tiers, **rates(row[:5]))


def free_entry(key, name, source):
    return dict(key=key, name=name, kind="localFree", catalog=None, catalogID=None, source=source, tiers=[],
                input=0.0, output=0.0, cacheRead=0.0, cacheWrite=0.0, cacheWrite1h=0.0)


ALIAS_DEPTH = 4      # `a` to `b` to `c` to `d` to `e` is four steps and is priced, a fifth is not
ALIAS_LOOP = object()


class Pricer:
    """Resolves a logged (provider, model) to an entry or None. `catalogues` keeps the lookup order."""

    def __init__(self, catalogues, override=(), aliases=None, local_providers=()):
        self.catalogues = catalogues
        self.override = {Keys(e["key"]).key1: e for e in override}
        self.aliases = {Keys(k).key1: v for k, v in (aliases or {}).items()}
        self.local_providers = tuple(local_providers)

    def _named(self, entry, row, keys):
        """A row the catalogue left without a name takes the name another catalogue gives the same model, else the
        readable form of its id. Only the picture's label changes, never a price."""
        if len(row) > 6 and row[6]:
            return entry
        for cat in self.catalogues:
            for k in keys:
                other = cat.by_key.get(k)
                if other and len(other[1]) > 6 and other[1][6]:
                    return dict(entry, name=other[1][6])
        return entry

    def catalogue_hit(self, keys, raw, only=None):
        catalogues = [c for c in self.catalogues if only is None or c.source == only]
        if raw is not None:
            for cat in catalogues:
                if cat.source in ("openrouter", "litellm") and raw in cat.by_id:
                    row_id, row = cat.by_id[raw]
                    return self._named(entry_from_row(cat.source, CATALOGUE_NAMES[cat.source], row_id, row, keys[0]), row, keys)
        for k in keys:
            for cat in catalogues:
                if k in cat.by_key:
                    row_id, row = cat.by_key[k]
                    return self._named(entry_from_row(cat.source, CATALOGUE_NAMES[cat.source], row_id, row, k), row, keys)
        return None

    def lookup(self, keys, raw):
        """The hand-corrected table, then an exact catalogue id, then the normalised name."""
        for k in keys.ordered:
            if k in self.override:
                hit = self.override[k]
                # a table row of kind "openrouter" is a copy of an OpenRouter price pinned at the table's date: the live
                # (or cached) OpenRouter catalogue, when it lists the model, is that price today. Stand-ins ("near") and
                # prices published elsewhere ("other") are for models no catalogue lists, and stay as the table says.
                if hit.get("kind") == "openrouter":
                    live = self.catalogue_hit(keys.ordered, raw, only="openrouter")
                    if live is not None:
                        return live
                return dict(hit)
        return self.catalogue_hit(keys.ordered, raw)

    def resolve(self, provider, model):
        if len(model) > MAX_NAME:            # no model has a name this long: such a line is not a model
            return None
        keys = Keys(model)
        raw = strip_brackets(model.strip().lower())
        local = is_local_provider(provider, self.local_providers) or keys.quantised
        for k in keys.ordered:
            if k in self.aliases:
                hit = self.apply_alias(self.aliases[k], keys.key1, k, frozenset([k]))
                if hit is ALIAS_LOOP:
                    return None
                if hit is not None:
                    return hit
                break
        hit = self.lookup(keys, raw)
        if hit:
            if local:
                hit = dict(hit, kind="localCloud", source="local -> cloud equivalent: " + hit["source"])
            return hit
        if local:
            return free_entry(keys.key1, model, "local, no cloud equivalent")
        # Family proxy: drop an account number, effort word or context size, at most twice.
        name = keys.key2
        for _ in range(2):
            m = FAMILY_TAIL.search(name)
            if not m:
                break
            name = name[:m.start()]
            proxy = Keys(name)
            hit = None
            for k in proxy.ordered:
                if k in self.aliases:
                    hit = self.apply_alias(self.aliases[k], proxy.key1, k, frozenset([k]))
                    if hit is ALIAS_LOOP:
                        return None
                    break
            hit = hit or self.lookup(proxy, None)
            if hit:
                return dict(hit, kind="approximate", source=f"approximate: {keys.key2} -> {name} ({hit['source']})")
        return None

    def apply_alias(self, alias, key, own=None, visited=frozenset(), steps=0):
        """An entry, None (a target nothing lists: the logged name is priced the ordinary way) or ALIAS_LOOP (a loop, or a
        chain of too many steps: unpriced). `own` is the alias name being applied, `visited` the alias names of the chain so
        far, `steps` how many alias-to-alias steps led here."""
        if isinstance(alias, str):
            keys = Keys(alias)
            found = None
            # the target may be another alias name: follow it. A name already met, or a fifth step, is a loop or a chain
            # too long: unpriced. An alias that names itself ("gpt-4o": "azure/gpt-4o") points at the catalogue.
            for k in keys.ordered:
                if k in self.aliases:
                    if k != own:
                        if k in visited or steps >= ALIAS_DEPTH:
                            return ALIAS_LOOP
                        found = self.apply_alias(self.aliases[k], keys.key1, k, visited | {k}, steps + 1)
                        if found is ALIAS_LOOP:
                            return ALIAS_LOOP
                    break
            hit = found or self.lookup(keys, strip_brackets(alias.strip().lower()))
            if hit is None:
                return None
            return dict(hit, kind="alias", source=f"your alias: {key} -> {alias} ({hit['source']})")
        if alias.get("free") is True:
            return free_entry(key, key, f"your alias: {key} -> free")
        if isinstance(alias.get("as"), str) and alias["as"]:
            return self.apply_alias(alias["as"], key, own, visited, steps)
        inp, out = _alias_number(alias.get("input")), _alias_number(alias.get("output"))
        if inp > 0 and out > 0 and all(is_rate(x) for x in (inp, out, _alias_number(alias.get("cacheRead")), _alias_number(alias.get("cacheWrite")))):
            # 0 is a price (a free cache); only a key that is not a number or text (missing, null, a list, an object)
            # leaves the cache priced like input (the Mac app's `given`)
            read = _alias_number(alias["cacheRead"]) if _alias_given(alias.get("cacheRead")) else inp
            write = _alias_number(alias["cacheWrite"]) if _alias_given(alias.get("cacheWrite")) else inp
            note = alias.get("source") if isinstance(alias.get("source"), str) and alias["source"] else None
            kind = alias.get("kind") if alias.get("kind") in ("near", "other") else "alias"
            return dict(key=key, name=alias.get("name") if isinstance(alias.get("name"), str) and alias["name"] else key,
                        kind=kind, catalog=None, catalogID=None,
                        source=f"your alias: {key} -> hand-written price" + (f" ({note})" if note else ""),
                        tiers=[], input=inp, output=out, cacheRead=read, cacheWrite=write, cacheWrite1h=write)
        return None


def rates_for(entry, prompt, tiered=True):
    rate = entry
    if tiered:
        for tier in entry["tiers"]:
            if prompt >= tier["minPrompt"]:
                rate = tier
    return rate


def call_cost(entry, inp, cr, cw, out, cw1h, tiered=True):
    """USD of one call (a summed row has no tier). `cw1h` is the one-hour share of `cw`."""
    rate = rates_for(entry, inp + cr + cw, tiered)
    hour = min(max(cw1h, 0), cw)
    return (inp * rate["input"] + cr * rate["cacheRead"] + (cw - hour) * rate["cacheWrite"] + hour * rate["cacheWrite1h"]
            + out * rate["output"]) / 1_000_000


def _alias_given(v) -> bool:
    """A hand-written rate that says something: a number, a boolean (the Mac app's NSNumber) or text."""
    return isinstance(v, (bool, int, float, str))


def _alias_number(v) -> float:
    """`num`, except that a JSON true is 1 and false 0, as on the Mac app (an NSNumber); other kinds are 0."""
    return float(v) if isinstance(v, bool) else num(v)


def _alias_rates_ok(value) -> bool:
    """A hand-written price the book can use: input and output above zero, all four rates within the bound a catalogue
    row has to meet (the Mac app lets none other into its table; a later `break` in the lookup would otherwise stop
    at an alias that prices nothing)."""
    rates = [_alias_number(value.get(k)) for k in ("input", "output", "cacheRead", "cacheWrite")]
    return rates[0] > 0 and rates[1] > 0 and all(is_rate(x) for x in rates)


def parse_aliases(data):
    """The user's alias file: {"aliases": {...}, "localProviders": [...]} (or the aliases alone)."""
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
                                          or _alias_rates_ok(value)):
            aliases[name] = value
    providers = data.get("localProviders") if isinstance(data.get("localProviders"), list) else []
    return aliases, [p for p in providers if isinstance(p, str)]
