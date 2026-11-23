"""Second opinion on machine translations: back-translate and rate.

    python tools/i18n/qa.py --langs es,hi --sample 120
    python tools/i18n/qa.py --langs ar --sample 0          # every machine string
    python tools/i18n/qa.py --langs hi --report-only       # list what is flagged

For each machine-translated string (never `reviewed` ones) the local model is
asked, in a separate request, to translate it back to English without seeing
the original, then to rate 1-5 how well that back-translation keeps the
original's meaning for a game interface. A score of 2 or less marks the entry
`fuzzy` (it shows in English in the game and is retranslated by the next
translate.py run, with the reason as a note); 3 is noted as `# qa: 3 …` for a
human to look at. The score goes into the entry as `# qa: <n> <back-translation>`
so a reviewer sees why.

Same engine and settings as translate.py (Ollama, `--model`, `--url`).
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
import po  # noqa: E402
import translate as tr  # noqa: E402

LOCALE = tr.LOCALE


def back_translate(args, code: str, items: list[tuple[str, po.Entry]]) -> dict:
    system = ("You translate software interface text into plain English, word for word where you can. "
              "Keep {placeholders} and symbols. No explanations.")
    user = (f"Translate each value from {tr.LANG_NAMES.get(code, code)} into English. Return JSON with the "
            "same keys.\n" + json.dumps({k: e.msgstr[0] for k, e in items}, ensure_ascii=False, indent=0))
    return tr.chat(args.url, args.model, system, user, [k for k, _ in items])


def rate(args, items: list[tuple[str, po.Entry, str]]) -> dict:
    system = ("You check translations of a video game's interface. For each item you get the original "
              "English and a back-translation of the translation. Rate 1-5 how well the meaning was kept: "
              "5 same meaning, 4 small wording change, 3 noticeably different or awkward, 2 wrong meaning, "
              "1 nonsense or a different thing. Judge meaning, not word choice. Return JSON: each key -> "
              "the number as a string.")
    rows = {k: {"original": e.msgid, "back": back} for k, e, back in items}
    return tr.chat(args.url, args.model, system, json.dumps(rows, ensure_ascii=False, indent=0),
                   [k for k, _, _ in items])


def run_lang(code: str, args) -> dict:
    path = os.path.join(LOCALE, f"{code}.po")
    cat = po.read(path)
    pool = [e for e in cat.entries if e.translated and not e.plural and not e.has_flag("reviewed")
            and e.comment_value("machine") and not e.comment_value("qa")]
    if args.report_only:
        flagged = [e for e in cat.entries if e.comment_value("qa")[:1] in ("1", "2", "3")]
        for e in flagged:
            print(f"  {code} qa {e.comment_value('qa')[:1]}: {e.msgid!r} -> {e.msgstr[0]!r}  "
                  f"(back: {e.comment_value('qa')[2:]!r})")
        return {"checked": 0, "low": len(flagged), "mid": 0}
    random.seed(args.seed)
    if args.sample and len(pool) > args.sample:
        pool = random.sample(pool, args.sample)
    st = {"checked": 0, "low": 0, "mid": 0, "scores": []}
    for i in range(0, len(pool), args.batch):
        chunk = pool[i:i + args.batch]
        items = [(str(j + 1), e) for j, e in enumerate(chunk)]
        try:
            back = back_translate(args, code, items)
            scored = rate(args, [(k, e, str(back.get(k, ""))) for k, e in items])
        except Exception as ex:  # noqa: BLE001
            print(f"  qa batch failed: {ex}")
            continue
        for k, e in items:
            try:
                s = int(str(scored.get(k, "0")).strip()[:1])
            except ValueError:
                continue
            st["checked"] += 1
            st["scores"].append(s)
            e.set_comment("qa", f"{s} {str(back.get(k, '')).strip()}")
            if s <= 2:
                e.set_flag("fuzzy")
                st["low"] += 1
            elif s == 3:
                st["mid"] += 1
        po.write(path, cat, po.HEADER_ORDER)
        print(f"  {code} qa {min(i + args.batch, len(pool))}/{len(pool)}  low {st['low']}  mid {st['mid']}",
              flush=True)
    return st


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--langs", required=True)
    ap.add_argument("--sample", type=int, default=100, help="strings per language (0 = all)")
    ap.add_argument("--batch", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--model", default=os.environ.get("SIMBIO_I18N_MODEL", tr.DEFAULT_MODEL))
    ap.add_argument("--url", default=os.environ.get("OLLAMA_HOST_URL", tr.DEFAULT_URL))
    ap.add_argument("--report-only", action="store_true")
    args = ap.parse_args()
    for code in [c.strip() for c in args.langs.split(",") if c.strip()]:
        s = run_lang(code, args)
        sc = s.get("scores", [])
        mean = sum(sc) / len(sc) if sc else 0.0
        print(f"qa {code}: {s['checked']} checked, mean {mean:.2f}, {s['low']} flagged fuzzy, "
              f"{s['mid']} to look at")
    return 0


if __name__ == "__main__":
    sys.exit(main())
