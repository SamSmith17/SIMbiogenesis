"""One command per release: extract -> merge -> pseudo -> check.

    python tools/i18n/update.py                 # every language already in locale/
    python tools/i18n/update.py --langs es,hi   # and create these if missing

translate.py (the AI step, plans/LOCALIZATION_PLAN.md Phase 1) runs between
merge and check once it exists; until then new strings stay English.
"""

from __future__ import annotations

import argparse
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LOCALE = os.path.join(HERE, "..", "..", "locale")
PSEUDO = {"en_XA", "ar_XB"}


def run(script: str, *args: str) -> int:
    return subprocess.call([sys.executable, os.path.join(HERE, script), *args])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--langs", default="")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    if run("extract.py") != 0:
        return 1
    codes = {os.path.basename(p)[:-3] for p in glob.glob(os.path.join(LOCALE, "*.po"))} - PSEUDO
    codes |= {c.strip() for c in args.langs.split(",") if c.strip()}
    if codes and run("merge.py", *sorted(codes)) != 0:
        return 1
    if os.path.exists(os.path.join(HERE, "translate.py")) and codes:
        if run("translate.py", "--langs", ",".join(sorted(codes))) != 0:
            print("update: translate step failed; untranslated strings stay English")
    run("pseudo.py")
    return run("check.py", *(["--strict"] if args.strict else []))


if __name__ == "__main__":
    sys.exit(main())
