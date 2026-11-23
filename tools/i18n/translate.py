"""Fill locale/<code>.po with machine translations from a local open model.

    python tools/i18n/translate.py --langs es,zh_Hans,ar,hi
    python tools/i18n/translate.py --langs hi --only scenes/ui/timeline_settings_panel.gd --limit 200
    python tools/i18n/translate.py --langs es --model qwen3:14b --dry-run

Engine: Ollama's /api/chat (http://127.0.0.1:11434, `--url` to change), with
a JSON schema so the reply is always {"1": "...", "2": "..."}. Free, local,
open-weights models; nothing leaves the computer. (plans/LOCALIZATION_PLAN.md:
NLLB / MADLAD adapters for the long tail come in Phase 5.)

Only entries that are empty or `fuzzy` are sent, never `reviewed` ones.
Every reply is checked before it is kept:
  - placeholders ({name}, %d, %.1f, %%, BBCode) all there and nothing added;
  - not empty, not left in English (for text with real words);
  - a button no more than 2.5x the English (asked again, shorter, once).
What fails stays empty (English in the game) and is listed at the end.
Kept translations are marked `# machine: ollama/<model> <date>`; the file is
saved after every batch, so a stopped run resumes where it was.

The translation memory (locale/.tm/<code>.jsonl, committed) remembers every
accepted translation by its English and context, so a string that leaves the
game and comes back is not sent again.
"""

from __future__ import annotations

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
import po  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOCALE = os.path.join(ROOT, "locale")
TM_DIR = os.path.join(LOCALE, ".tm")
GLOSSARY_DIR = os.path.join(LOCALE, "glossary")
DEFAULT_MODEL = "gemma4:latest"
DEFAULT_URL = "http://127.0.0.1:11434"
PSEUDO = {"en_XA", "ar_XB"}

LANG_NAMES = {
    "es": "Spanish (neutral, for Spain and Latin America)",
    "zh_Hans": "Simplified Chinese (Mainland China)",
    "zh_Hant": "Traditional Chinese (Taiwan)",
    "yue": "written Cantonese (Hong Kong)",
    "ar": "Modern Standard Arabic",
    "hi": "Hindi (Devanagari; common English technical loanwords are fine)",
    "fr": "French", "pt_BR": "Brazilian Portuguese", "ru": "Russian", "bn": "Bengali",
    "ur": "Urdu", "id": "Indonesian", "de": "German", "ja": "Japanese", "tr": "Turkish",
    "vi": "Vietnamese", "ko": "Korean", "it": "Italian", "fa": "Persian", "tl": "Filipino (Tagalog)",
    "sw": "Swahili", "th": "Thai", "mr": "Marathi", "te": "Telugu", "ta": "Tamil", "pa": "Punjabi (Gurmukhi)",
    "pl": "Polish", "uk": "Ukrainian", "ha": "Hausa", "gu": "Gujarati", "kn": "Kannada", "am": "Amharic",
    "yo": "Yoruba", "nl": "Dutch", "ms": "Malay",
}
# What each plural slot means, by number of forms, for the prompt.
PLURAL_SLOTS = {
    1: ["every number"],
    2: ["one (n = 1)", "other numbers"],
    3: ["one (1, 21, 31…)", "few (2–4, 22–24…)", "many (0, 5–20…)"],
    6: ["zero (0)", "one (1)", "two (2)", "few (3–10)", "many (11–99)", "other (100, 101…)"],
}
SYSTEM = (
    "You translate the user interface of SIMbiogenesis, a first-person simulator of off-grid "
    "sites: solar panels, batteries, water, food, people and festivals. Translate as a "
    "professional software localizer would: the usual wording of {lang} computer interfaces, "
    "natural and short, consistent with earlier strings. A string with budget 'button' is a "
    "button or menu item: make it a short command. 'label' is a field name or short text, "
    "'tooltip' and 'title' as named. Keep exactly as written: every {{placeholder}} in curly "
    "braces, every %d / %s / %.1f / %%, BBCode tags like [b], emoji, arrows and symbols, "
    "numbers, unit symbols (kW, kWh, m, L, °C), and these names: {keep}. Do not add quotes, "
    "notes or explanations."
)


def die(msg: str) -> None:
    print(f"translate: {msg}", file=sys.stderr)
    sys.exit(1)


def tm_key(e: po.Entry) -> str:
    return hashlib.sha1(f"{e.ctx}\x04{e.msgid}\x00{e.plural}".encode()).hexdigest()[:16]


def load_tm(code: str) -> dict:
    p = os.path.join(TM_DIR, f"{code}.jsonl")
    out = {}
    if os.path.exists(p):
        with open(p, encoding="utf-8") as fh:
            for ln in fh:
                try:
                    r = json.loads(ln)
                    out[r["k"]] = r
                except (ValueError, KeyError):
                    pass
    return out


def append_tm(code: str, rows: list[dict]) -> None:
    if not rows:
        return
    os.makedirs(TM_DIR, exist_ok=True)
    with open(os.path.join(TM_DIR, f"{code}.jsonl"), "a", encoding="utf-8", newline="\n") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


def keep_names(code: str) -> list[str]:
    names = []
    for p in (os.path.join(GLOSSARY_DIR, "never_translate.txt"),):
        if os.path.exists(p):
            with open(p, encoding="utf-8") as fh:
                names += [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
    return names


def glossary(code: str) -> list[tuple[str, str]]:
    p = os.path.join(GLOSSARY_DIR, f"{code}.csv")
    out = []
    if os.path.exists(p):
        with open(p, encoding="utf-8") as fh:
            for ln in fh:
                if ln.startswith("#") or "," not in ln:
                    continue
                a, b = ln.rstrip("\n").split(",", 1)
                out.append((a.strip(), b.strip()))
    return out


def budget_of(e: po.Entry) -> str:
    for x in e.extracted:
        if x.startswith("budget:"):
            return x.split(":", 1)[1].strip()
    return "label"


def where_of(e: po.Entry) -> str:
    if not e.refs:
        return ""
    f = e.refs[0].rsplit(":", 1)[0]
    return os.path.splitext(os.path.basename(f))[0].replace("_", " ")


def chat(url: str, model: str, system: str, user: str, keys: list[str], array_len: int = 0) -> dict:
    if array_len:
        schema = {"type": "object", "properties": {"forms": {"type": "array", "items": {"type": "string"},
                  "minItems": array_len, "maxItems": array_len}}, "required": ["forms"]}
    else:
        schema = {"type": "object", "properties": {k: {"type": "string"} for k in keys}, "required": keys}
    body = {"model": model, "stream": False, "think": False, "format": schema,
            "options": {"temperature": 0.2, "num_ctx": 8192},
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    req = urllib.request.Request(url.rstrip("/") + "/api/chat", data=json.dumps(body).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        reply = json.loads(r.read())
    return json.loads(reply["message"]["content"])


LETTERS = re.compile(r"[A-Za-z]{3,}")


def tidy(src: str, out: str) -> str:
    """Small fixes that never change meaning: outer quotes the model added,
    the ellipsis character it turned into three dots, edge spaces."""
    o = out.strip("\n")
    if len(o) >= 2 and o[0] in "\"“«「" and o[-1] in "\"”»」" and not (src[:1] in "\"“" and src[-1:] in "\"”"):
        o = o[1:-1]
    if src.endswith("…") and o.endswith("...") and not src.endswith("..."):
        o = o[:-3] + "…"
    if src == src.strip():
        o = o.strip()
    return o


def _names_only(src: str) -> bool:
    """A glossary name, or a list of names ("Alex, Sam, River, …"): staying in English is right."""
    s = src.strip()
    if s in keep_names(""):
        return True
    parts = [p.strip(" .…") for p in s.split(",") if p.strip(" .…")]
    return len(parts) >= 2 and all(p[:1].isupper() and " " not in p for p in parts)


def problem(src: str, out: str, budget: str, code: str) -> str:
    """Why a translation can't be kept ('' = fine)."""
    if not out.strip():
        return "empty"
    if sorted(set(po.placeholders(out)) - {"{n}"}) != sorted(set(po.placeholders(src)) - {"{n}"}):
        return f"placeholders {po.placeholders(src)} -> {po.placeholders(out)}"
    if out.count("\n") > src.count("\n"):
        return "extra lines"
    if re.search(r"\b(budget|label|tooltip|button|title)\b\s*[,:\]]", out) or out.lstrip().startswith(("[", "{")) and not src.lstrip().startswith(("[", "{")):
        return "copied the context"
    words = LETTERS.findall(src)
    if code not in ("en",) and len(words) >= 2 and out.strip() == src.strip() and not _names_only(src):
        return "left in English"
    if budget == "button" and len(src) >= 4 and len(out) > 2.5 * len(src) + 6:
        return "too long for a button"
    if len(src) >= 12 and len(out) > 4 * len(src) + 20:
        return "far longer than the English"
    return ""


def make_user(code: str, items: list[tuple[str, po.Entry]], gl: list[tuple[str, str]], shorter: bool) -> str:
    lines = [f"Translate each value of the JSON object below into {LANG_NAMES.get(code, code)}."
             " Return a JSON object with the same keys, each value only the translated text."]
    if shorter:
        lines.append("Some were too long or wrongly formatted last time: give only the short translated text.")
    if gl:
        lines.append("Use these terms: " + "; ".join(f"{a} = {b}" for a, b in gl))
    hints = []
    for k, e in items:
        h = [budget_of(e), "in " + where_of(e)]
        if e.ctx:
            h.append("meaning: " + e.ctx)
        h += [x for x in e.extracted if not x.startswith("budget:")]
        if e.has_flag("fuzzy") and e.msgstr and e.msgstr[0] and e.comment_value("qa"):
            # qa.py rejected the last answer: say so, and what it read back as.
            h.append(f"NOT {e.msgstr[0]!r} (that reads back as {e.comment_value('qa')[2:]!r}); "
                     "use the usual word for this in software or games")
        hints.append(f"{k} = " + ", ".join(h))
    lines.append("Where each one appears (do not translate or copy this):")
    lines += hints
    lines.append("Text to translate:")
    lines.append(json.dumps({k: e.msgid for k, e in items}, ensure_ascii=False, indent=0))
    return "\n".join(lines)


def translate_plural(url, model, system, code, e: po.Entry, gl) -> list[str] | None:
    n = po.nplurals(code)
    slots = PLURAL_SLOTS.get(n, [f"form {i}" for i in range(n)])
    user = (f"Translate into {LANG_NAMES.get(code, code)} this text that changes with a number {{n}}.\n"
            f"English one: {json.dumps(e.msgid, ensure_ascii=False)}\n"
            f"English other: {json.dumps(e.plural, ensure_ascii=False)}\n"
            f"Return JSON {{\"forms\": [...]}} with exactly {n} strings, one for each of: "
            + ", ".join(slots) + ". Keep {n} where the number is written.")
    for _ in range(2):
        try:
            forms = chat(url, model, system, user, [], array_len=n).get("forms", [])
        except Exception as ex:  # noqa: BLE001
            print(f"    plural request failed: {ex}")
            return None
        ok = len(forms) == n and all(str(f).strip() for f in forms) and all(
            sorted(set(po.placeholders(str(f))) - {"{n}"}) == sorted(set(po.placeholders(e.plural)) - {"{n}"})
            for f in forms)
        if ok:
            return [str(f) for f in forms]
    return None


def select(cat: po.Catalog, only: list[str], include_fuzzy: bool) -> list[po.Entry]:
    out = []
    for e in cat.entries:
        if e.has_flag("reviewed"):
            continue
        if e.translated and not (include_fuzzy and e.has_flag("fuzzy")):
            continue
        if any(e.msgstr) and not e.has_flag("fuzzy"):
            continue
        if only and not any(fnmatch.fnmatch(r.rsplit(":", 1)[0], pat) for r in e.refs for pat in only):
            continue
        out.append(e)
    return out


def run_lang(code: str, args) -> dict:
    path = os.path.join(LOCALE, f"{code}.po")
    if not os.path.exists(path):
        die(f"{path} missing: run python tools/i18n/merge.py {code} first")
    cat = po.read(path)
    todo = select(cat, args.only, True)
    tm = load_tm(code)
    stats = {"tm": 0, "ok": 0, "failed": [], "asked": 0}
    stamp = f"ollama/{args.model} {datetime.date.today().isoformat()}"
    # Translation memory first.
    rest = []
    for e in todo:
        r = tm.get(tm_key(e))
        # A fuzzy entry still holding what memory has was rejected (qa.py): ask again.
        if r and list(r["s"]) == list(e.msgstr) and e.has_flag("fuzzy"):
            r = None
        if r and len(r["s"]) == len(e.msgstr) and all(r["s"]):
            e.msgstr = list(r["s"])
            e.set_flag("fuzzy", False)
            e.previous = ""
            e.set_comment("machine", r.get("m", stamp))
            stats["tm"] += 1
        else:
            rest.append(e)
    if args.limit:
        rest = rest[:args.limit]
    keep = ", ".join(keep_names(code)) or "SIMbiogenesis"
    system = SYSTEM.format(lang=LANG_NAMES.get(code, code), keep=keep)
    gl = glossary(code)
    singles = [e for e in rest if not e.plural]
    plurals = [e for e in rest if e.plural]
    print(f"translate {code}: {len(todo)} to do ({stats['tm']} from memory), "
          f"{len(singles)} strings + {len(plurals)} plurals to ask {args.model}")
    if args.dry_run:
        return stats
    t0 = time.time()
    done_n = 0
    for i in range(0, len(singles), args.batch):
        batch = singles[i:i + args.batch]
        items = [(str(j + 1), e) for j, e in enumerate(batch)]
        pending = items
        tm_rows = []
        for attempt in range(2):
            if not pending:
                break
            try:
                reply = chat(args.url, args.model, system, make_user(code, pending, gl, attempt > 0),
                             [k for k, _ in pending])
            except Exception as ex:  # noqa: BLE001
                print(f"  batch failed: {ex}")
                break
            stats["asked"] += len(pending)
            retry = []
            for k, e in pending:
                out = tidy(e.msgid, str(reply.get(k, "")))
                why = problem(e.msgid, out, budget_of(e), code)
                if why:
                    if attempt == 0:
                        retry.append((k, e))
                    else:
                        stats["failed"].append(f"{e.msgid!r}: {why}: {out!r}")
                    continue
                e.msgstr = [out]
                e.set_flag("fuzzy", False)
                e.previous = ""
                e.set_comment("machine", stamp)
                tm_rows.append({"k": tm_key(e), "s": e.msgstr, "m": stamp, "src": e.msgid})
                stats["ok"] += 1
            pending = retry
        append_tm(code, tm_rows)
        po.write(path, cat, po.HEADER_ORDER)
        done_n += len(batch)
        rate = done_n / max(1.0, time.time() - t0)
        left = (len(singles) - done_n) / max(rate, 1e-6)
        print(f"  {code} {done_n}/{len(singles)}  ok {stats['ok']}  failed {len(stats['failed'])}  "
              f"~{left / 60:.0f} min left", flush=True)
    for e in plurals:
        forms = translate_plural(args.url, args.model, system, code, e, gl)
        if forms:
            e.msgstr = forms
            e.set_flag("fuzzy", False)
            e.previous = ""
            e.set_comment("machine", stamp)
            append_tm(code, [{"k": tm_key(e), "s": forms, "m": stamp, "src": e.msgid}])
            stats["ok"] += 1
        else:
            stats["failed"].append(f"{e.msgid!r}: plural forms")
        po.write(path, cat, po.HEADER_ORDER)
    po.write(path, cat, po.HEADER_ORDER)
    return stats


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--langs", required=True)
    ap.add_argument("--model", default=os.environ.get("SIMBIO_I18N_MODEL", DEFAULT_MODEL))
    ap.add_argument("--url", default=os.environ.get("OLLAMA_HOST_URL", DEFAULT_URL))
    ap.add_argument("--only", action="append", default=[], help="source file glob (repeatable)")
    ap.add_argument("--only-file", default="", help="a file of source globs, one a line")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--batch", type=int, default=25)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("SIMBIO_I18N_JOBS", "4")),
                    help="languages translated at once (match Ollama's OLLAMA_NUM_PARALLEL)")
    args = ap.parse_args()
    if args.only_file:
        with open(args.only_file, encoding="utf-8") as fh:
            args.only += [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
    try:
        urllib.request.urlopen(args.url.rstrip("/") + "/api/tags", timeout=5).read()
    except Exception:  # noqa: BLE001
        print(f"translate: no Ollama at {args.url}; skipping (strings stay English)")
        return 0
    codes = [c.strip() for c in args.langs.split(",") if c.strip() and c.strip() not in PSEUDO]
    # Each language has its own .po and memory file, so they run side by side: a model
    # writing tokens is limited by memory speed, and parallel requests share each pass
    # over the weights (gemma4 on a Radeon 890M: 19 tok/s alone, 52 with four at once).
    import concurrent.futures as cf
    with cf.ThreadPoolExecutor(max(1, min(args.jobs, len(codes)))) as ex:
        results = list(ex.map(lambda c: (c, run_lang(c, args)), codes))
    for code, s in results:
        print(f"translate {code}: {s['ok']} translated, {s['tm']} from memory, {len(s['failed'])} not kept")
        for f in s["failed"][:15]:
            print(f"    not kept: {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
