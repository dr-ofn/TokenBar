"""Price rules shared by scripts/update-prices.py and scripts/oracle.py.

This is the Python twin of Sources/LocalCore/ModelNames.swift, PriceFeed*.swift and Pricing.swift.
The oracle must give the same price as the CLI, so a rule changes in both places or in none.
Prices are USD per 1M tokens. A catalogue row is
    [input, output, cacheRead, cacheWrite, cacheWrite1h, [[minPrompt, input, output, cacheRead, cacheWrite, cacheWrite1h], ...], name?]
where 0 means "the catalogue does not say" (a cache price then falls back to the input price).
"""
import json
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
    while True:
        t = re.sub(r"\s*(?:\[[^\]]*\]|\([^)]*\))\s*$", "", s)
        if t == s:
            return s
        s = t


def clean(model):
    s = strip_brackets(model.strip().lower())
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
    p = provider.strip().lower().replace("_", "-")
    return p in LOCAL_PROVIDERS or p in {e.strip().lower().replace("_", "-") for e in extra}


# ---------------------------------------------------------------------------------------------
# Catalogue rows from the three raw sources

def per_million(value):
    return round(float(value or 0) * 1_000_000, 6)


def num(value):
    try:
        v = float(value)
    except (TypeError, ValueError):
        return 0.0
    return v if v == v and v != float("inf") else 0.0


MAX_RATE = 1_000_000.0  # PriceLimits.maxRate: USD per 1M tokens, far above any model


def is_rate(v):
    return v == v and 0 <= v <= MAX_RATE


def alias_rates_ok(value):
    """A hand-written price meets the bound a catalogue row does (Swift UserAliases.target): else the entry is dropped."""
    vals = [num(value.get(k)) for k in ("input", "output", "cacheRead", "cacheWrite")]
    return vals[0] > 0 and vals[1] > 0 and all(is_rate(v) for v in vals)


def row_ok(row):
    return row[0] > 0 and row[1] > 0


def openrouter_rows(raw):
    """id -> row. Routers priced -1 and anything at zero are left out."""
    out = {}
    for m in raw.get("data", []):
        p = m.get("pricing") or {}
        try:
            inp, outp = per_million(p.get("prompt")), per_million(p.get("completion"))
        except (TypeError, ValueError):
            continue
        base = [inp, outp, max(per_million(p.get("input_cache_read")), 0), max(per_million(p.get("input_cache_write")), 0),
                max(per_million(p.get("input_cache_write_1h")), 0)]
        tiers = []
        for t in sorted((t for t in p.get("overrides") or [] if "min_prompt_tokens" in t), key=lambda t: t["min_prompt_tokens"]):
            tiers.append([int(t["min_prompt_tokens"]),
                          per_million(t["prompt"]) if "prompt" in t else base[0],
                          per_million(t["completion"]) if "completion" in t else base[1],
                          per_million(t.get("input_cache_read")), per_million(t.get("input_cache_write")),
                          per_million(t.get("input_cache_write_1h"))])
        row = base + [tiers, re.sub(r"^[^:]{1,40}:\s*", "", m.get("name") or "")]
        if row_ok(row) and m.get("id"):
            out[m["id"]] = row
    return out


LITELLM_TIER = re.compile(r"^(input_cost_per_token|output_cost_per_token|cache_read_input_token_cost|"
                          r"cache_creation_input_token_cost|cache_creation_input_token_cost_above_1hr)_above_(\d+)k_tokens$")
LITELLM_FIELDS = ("input_cost_per_token", "output_cost_per_token", "cache_read_input_token_cost",
                  "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr")


def litellm_rows(raw):
    out = {}
    for key, v in raw.items():
        if key == "sample_spec" or not isinstance(v, dict) or v.get("mode") not in ("chat", "completion", "responses", None):
            continue
        base = [per_million(v.get(f)) for f in LITELLM_FIELDS]
        thresholds = defaultdict(dict)
        for field, value in v.items():
            m = LITELLM_TIER.match(field)
            if m and isinstance(value, (int, float)):
                thresholds[int(m.group(2)) * 1000][m.group(1)] = per_million(value)
        tiers, carried = [], list(base)
        for threshold in sorted(thresholds):
            carried = [thresholds[threshold].get(f, carried[i]) for i, f in enumerate(LITELLM_FIELDS)]
            tiers.append([threshold + 1] + carried)
        row = base + [tiers]
        if row_ok(row):
            out[key] = row
    return out


def modelsdev_rows(raw):
    """"provider/model" -> row, with the provider's own model id after the first slash."""
    out = {}
    for provider, body in raw.items():
        if not isinstance(body, dict):
            continue
        for model_id, m in (body.get("models") or {}).items():
            c = m.get("cost") if isinstance(m, dict) else None
            if not isinstance(c, dict):
                continue
            base = [num(c.get("input")), num(c.get("output")), num(c.get("cache_read")), num(c.get("cache_write")), 0]
            tiers = []
            for t in sorted((t for t in c.get("tiers") or [] if isinstance(t, dict) and (t.get("tier") or {}).get("type") == "context"),
                            key=lambda t: t["tier"].get("size", 0)):
                tiers.append([int(t["tier"].get("size", 0)) + 1, num(t.get("input", base[0])), num(t.get("output", base[1])),
                              num(t.get("cache_read")), num(t.get("cache_write")), 0])
            over = c.get("context_over_200k")
            if not tiers and isinstance(over, dict):
                tiers.append([200001, num(over.get("input", base[0])), num(over.get("output", base[1])),
                              num(over.get("cache_read")), num(over.get("cache_write")), 0])
            row = base + [tiers, str(m.get("name") or "")]
            if row_ok(row):
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
    def __init__(self, source, rows):
        self.source = source
        self.by_id = {}
        groups = defaultdict(list)
        for row_id, row in rows.items():
            if source != "modelsdev":
                self.by_id[row_id.lower()] = (row_id, row)
            if route_tagged(row_id):
                continue
            groups[catalogue_key(source, row_id)].append((row_id, row))
        self.by_key = {k: choose(source, v) for k, v in groups.items()}


CATALOGUE_NAMES = {"openrouter": "OpenRouter", "litellm": "LiteLLM", "modelsdev": "models.dev"}


def thin(source, rows):
    """What the embedded snapshot keeps of a catalogue: the rows its index would pick, and LiteLLM's exact ids."""
    keep = {}
    groups = defaultdict(list)
    for row_id, row in rows.items():
        if route_tagged(row_id):
            continue
        groups[catalogue_key(source, row_id)].append((row_id, row))
    for items in groups.values():
        row_id, row = choose(source, items)
        keep[row_id] = row
    return keep


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

    def catalogue_hit(self, name, keys, raw):
        if raw is not None:
            for cat in self.catalogues:
                if cat.source in ("openrouter", "litellm") and raw in cat.by_id:
                    row_id, row = cat.by_id[raw]
                    return self.named(entry_from_row(cat.source, CATALOGUE_NAMES[cat.source], row_id, row, keys[0]), row, keys)
        for k in keys:
            for cat in self.catalogues:
                if k in cat.by_key:
                    row_id, row = cat.by_key[k]
                    return self.named(entry_from_row(cat.source, CATALOGUE_NAMES[cat.source], row_id, row, k), row, keys)
        return None

    def lookup(self, model, keys, raw):
        """override, exact id, normalised name. Returns an entry or None."""
        hit = self.table_hit(self.override, keys.ordered)
        if hit:
            return dict(hit)
        return self.catalogue_hit(model, keys.ordered, raw)

    def resolve(self, provider, model):
        keys = Keys(model)
        raw = strip_brackets(model.strip().lower())
        local = is_local_provider(provider, self.local_providers) or keys.quantised
        alias = self.table_hit(self.aliases, keys.ordered)
        if alias is not None:
            hit = self.apply_alias(alias, keys.key1)
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
            alias = self.table_hit(self.aliases, proxy.ordered)
            hit = self.apply_alias(alias, proxy.key1) if alias is not None else None
            hit = hit or self.lookup(name, proxy, None)
            if hit:
                return dict(hit, kind="approximate", source=f"yaklaşık: {keys.key2} → {name} ({hit['source']})")
        return None

    def apply_alias(self, alias, key):
        if isinstance(alias, str):
            target = Keys(alias)
            hit = self.lookup(alias, target, strip_brackets(alias.strip().lower()))
            if hit is None:
                return None
            return dict(hit, kind="alias", source=f"kullanıcı takma adı: {key} → {alias} ({hit['source']})")
        if alias.get("free") is True:
            return dict(key=key, name=key, kind="localFree", catalog=None, catalogID=None,
                        source=f"kullanıcı takma adı: {key} → ücretsiz", tiers=[], input=0.0, output=0.0,
                        cacheRead=0.0, cacheWrite=0.0, cacheWrite1h=0.0)
        if isinstance(alias.get("as"), str) and alias["as"]:
            return self.apply_alias(alias["as"], key)
        inp, out = num(alias.get("input")), num(alias.get("output"))
        if alias_rates_ok(alias):
            write = num(alias.get("cacheWrite")) or inp
            note = alias.get("source") if isinstance(alias.get("source"), str) and alias["source"] else None
            kind = alias.get("kind") if alias.get("kind") in ("near", "other") else "alias"
            return dict(key=key, name=alias.get("name") if isinstance(alias.get("name"), str) else key, kind=kind,
                        catalog=None, catalogID=None,
                        source=f"kullanıcı takma adı: {key} → elle yazılmış fiyat" + (f" ({note})" if note else ""),
                        tiers=[], input=inp, output=out, cacheRead=num(alias.get("cacheRead")) or inp, cacheWrite=write,
                        cacheWrite1h=write)
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
    return [Catalogue("litellm", data["litellm"]), Catalogue("modelsdev", data["modelsdev"])]


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
