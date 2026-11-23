"""Bring each locale/<code>.po up to date with locale/simbiogenesis.pot.

    python tools/i18n/merge.py es zh_Hans ar hi   # create or update these
    python tools/i18n/merge.py --all              # every .po already in locale/

Like gettext's msgmerge:
  - a string still in the game keeps its translation, flags and notes;
  - a new string arrives empty;
  - a string whose English changed slightly (the closest removed one, 85 %
    alike) keeps the old translation flagged `fuzzy`, with the old English as
    `#| msgid`, so translate.py redoes it and a reviewer sees what changed;
  - strings no longer in the game are dropped.
Entries marked `reviewed` are never touched except their references.
"""

from __future__ import annotations

import argparse
import difflib
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import po  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOCALE = os.path.join(ROOT, "locale")
POT = os.path.join(LOCALE, "simbiogenesis.pot")


def merge(code: str, pot: po.Catalog) -> dict:
    path = os.path.join(LOCALE, f"{code}.po")
    old = po.read(path) if os.path.exists(path) else po.Catalog()
    old_idx = old.index()
    n = po.nplurals(code)
    used: set = set()
    out: list[po.Entry] = []
    stats = {"kept": 0, "new": 0, "fuzzy": 0, "dropped": 0}
    removed = [e for k, e in old_idx.items() if k not in {p.key for p in pot.entries}]
    removed_ids = [e.msgid for e in removed]
    for p in pot.entries:
        e = old_idx.get(p.key)
        if e is not None:
            used.add(p.key)
            e.refs, e.extracted, e.plural = list(p.refs), list(p.extracted), p.plural
            stats["kept"] += 1
        else:
            e = po.Entry(msgid=p.msgid, ctx=p.ctx, plural=p.plural, refs=list(p.refs),
                         extracted=list(p.extracted))
            e.msgstr = [""] * (n if p.plural else 1)
            close = difflib.get_close_matches(p.msgid, removed_ids, n=1, cutoff=0.85) if removed_ids else []
            if close:
                src = removed[removed_ids.index(close[0])]
                if bool(src.plural) == bool(p.plural) and any(src.msgstr):
                    e.msgstr = list(src.msgstr)
                    e.previous = src.msgid
                    e.comments = [c for c in src.comments if not c.startswith("reviewed")]
                    e.set_flag("fuzzy")
                    stats["fuzzy"] += 1
                    out.append(e)
                    continue
            stats["new"] += 1
        if e.plural:
            e.msgstr = (e.msgstr + [""] * n)[:n]
        out.append(e)
    stats["dropped"] = len(old_idx) - len(used)
    header = po.header_for(code)
    header.update({k: v for k, v in old.header.items() if k not in ("Plural-Forms", "Language")})
    po.write(path, po.Catalog(header=header, entries=out), po.HEADER_ORDER)
    return stats


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("codes", nargs="*")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()
    codes = list(args.codes)
    if args.all:
        codes += [os.path.basename(p)[:-3] for p in glob.glob(os.path.join(LOCALE, "*.po"))]
    if not codes:
        ap.error("name the languages, or --all")
    pot = po.read(POT)
    for code in sorted(set(codes)):
        s = merge(code, pot)
        print(f"merge {code}: {s['kept']} kept, {s['new']} new, {s['fuzzy']} changed (fuzzy), {s['dropped']} dropped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
