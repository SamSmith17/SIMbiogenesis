"""Check the translations and write locale/coverage.json (shown in the picker).

    python tools/i18n/check.py            # report
    python tools/i18n/check.py --strict   # exit 1 on a broken placeholder or plural

Per language: how much of the game is translated (fuzzy entries count as not
translated), translations that lost or gained a placeholder ({name}, %d,
%.1f, %%, BBCode), plural entries with the wrong number of forms, and
buttons whose translation is much longer than the English (they will not fit).
Also prints how many formatted strings in the scripts still need wrapping
(from extract.py's report).
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import po  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOCALE = os.path.join(ROOT, "locale")
LONG_BUTTON = 1.8   # a button translation this many times the English is flagged


def check(path: str, pot_keys: set) -> dict:
    code = os.path.basename(path)[:-3]
    cat = po.read(path)
    n = po.nplurals(code)
    res = {"code": code, "total": len(pot_keys), "done": 0, "fuzzy": 0, "reviewed": 0,
           "machine": 0, "placeholder": [], "plural": [], "long": []}
    for e in cat.entries:
        if e.key not in pot_keys:
            continue
        if "fuzzy" in e.flags:
            res["fuzzy"] += 1
        if e.comment_value("machine"):
            res["machine"] += 1
        if "reviewed" in e.flags:
            res["reviewed"] += 1
        if e.plural and len(e.msgstr) != n:
            res["plural"].append(e.msgid)
        if not e.translated:
            continue
        res["done"] += 1
        want = po.placeholders(e.msgid)
        want_p = po.placeholders(e.plural) if e.plural else want
        for i, s in enumerate(e.msgstr):
            got = po.placeholders(s)
            ref = want if (i == 0 or not e.plural) else want_p
            # A plural form may drop {n} (e.g. Arabic's "one" form says "a day").
            if sorted(set(got) - {"{n}"}) != sorted(set(ref) - {"{n}"}):
                res["placeholder"].append(f"{e.msgid!r} -> {s!r}")
                break
        if any("budget: button" in x for x in e.extracted) and len(e.msgid) >= 4:
            if max(len(s) for s in e.msgstr) > LONG_BUTTON * len(e.msgid) + 4:
                res["long"].append(f"{e.msgid!r} -> {e.msgstr[0]!r}")
    return res


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--show", type=int, default=5, help="examples to print per problem")
    args = ap.parse_args()
    pot = po.read(os.path.join(LOCALE, "simbiogenesis.pot"))
    keys = {e.key for e in pot.entries}
    coverage = {}
    bad = 0
    for path in sorted(glob.glob(os.path.join(LOCALE, "*.po"))):
        r = check(path, keys)
        pct = r["done"] / r["total"] if r["total"] else 0.0
        coverage[r["code"]] = round(pct, 4)
        print(f"{r['code']:8s} {pct * 100:5.1f} %  {r['done']}/{r['total']}  fuzzy {r['fuzzy']}  "
              f"machine {r['machine']}  reviewed {r['reviewed']}  placeholder errors {len(r['placeholder'])}  "
              f"plural errors {len(r['plural'])}  long buttons {len(r['long'])}")
        for kind in ("placeholder", "plural", "long"):
            for ex in r[kind][:args.show]:
                print(f"    {kind}: {ex}")
        bad += len(r["placeholder"]) + len(r["plural"])
    with open(os.path.join(LOCALE, "coverage.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(coverage, fh, indent=1, sort_keys=True)
    rep = os.path.join(LOCALE, ".extract_report.json")
    if os.path.exists(rep):
        with open(rep, encoding="utf-8") as fh:
            r = json.load(fh)
        print(f"scripts: {r.get('strings', 0)} strings extracted; "
              f"{r.get('needs_wrapping_total', 0)} formatted strings still need wrapping")
    if args.strict and bad:
        print(f"check: FAIL ({bad} broken entries)")
        return 1
    print("check: PASS" if not bad else f"check: {bad} broken entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
