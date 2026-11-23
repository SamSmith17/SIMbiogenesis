"""Write the pseudo-locales from the POT: locale/en_XA.po and locale/ar_XB.po.

    python tools/i18n/pseudo.py

en_XA ("long accents"): every letter accented, 40 % longer, wrapped in
[! … !]. Pick it in Settings → Interface → Language and look round the game:
  - text with no [! … !] is not going through translation (a formatted
    string, a canvas draw_string, a popup built at runtime);
  - text cut off or spilling over has no room for a longer language.
ar_XB ("right to left"): the same text written right to left with the layout
mirrored, to find screens that do not mirror.

Placeholders ({name}, %d, %.1f, %%, BBCode tags) and line breaks are kept,
so formatting still works.
"""

from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
import po  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOCALE = os.path.join(ROOT, "locale")

ACCENT = str.maketrans(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "àƀçđéƒĝĥîĵķĺɱñöƥǫŕšţûṽŵẋýžÀƁÇĐÉƑĜĤÎĴĶĹṀÑÖƤǪŔŠŢÛṼŴẊÝŽ")
RLO, PDF = "\u202e", "\u202c"


def _split(s: str) -> list[tuple[bool, str]]:
    """(is_placeholder, text) pieces."""
    out, pos = [], 0
    for m in po.PLACEHOLDER_RE.finditer(s):
        if m.start() > pos:
            out.append((False, s[pos:m.start()]))
        out.append((True, m.group(0)))
        pos = m.end()
    if pos < len(s):
        out.append((False, s[pos:]))
    return out


def long_accents(s: str) -> str:
    body = "".join(t if ph else t.translate(ACCENT) for ph, t in _split(s))
    letters = len(re.findall(r"[^\W\d_]", s))
    pad = "~" * max(1, round(letters * 0.4))
    lines = body.split("\n")
    lines[0] = "[!" + lines[0]
    lines[-1] = lines[-1] + " " + pad + "!]"
    return "\n".join(lines)


def right_to_left(s: str) -> str:
    # Each line forced right to left; placeholders kept left to right inside it.
    return "\n".join(RLO + ln + PDF if ln else ln for ln in s.split("\n"))


def build(code: str, fn) -> int:
    pot = po.read(os.path.join(LOCALE, "simbiogenesis.pot"))
    n = po.nplurals(code)
    out = []
    for p in pot.entries:
        e = po.Entry(msgid=p.msgid, ctx=p.ctx, plural=p.plural)
        if p.plural:
            e.msgstr = [fn(p.msgid)] + [fn(p.plural)] * (n - 1)
        else:
            e.msgstr = [fn(p.msgid)]
        e.comments = ["machine: pseudo"]
        out.append(e)
    hdr = po.header_for(code)
    po.write(os.path.join(LOCALE, f"{code}.po"), po.Catalog(header=hdr, entries=out), po.HEADER_ORDER)
    return len(out)


def main() -> int:
    a = build("en_XA", long_accents)
    b = build("ar_XB", right_to_left)
    print(f"pseudo: en_XA {a} strings, ar_XB {b} strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
