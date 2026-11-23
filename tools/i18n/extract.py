"""Collect the game's player-facing text into locale/simbiogenesis.pot.

    python tools/i18n/extract.py            # writes the POT + locale/.extract_report.json
    python tools/i18n/extract.py --report   # also prints the files with the most unwrapped text

What counts as text (plans/LOCALIZATION_PLAN.md, "extract.py"):
  - calls: I18n.t("…"[, "ctx"]), I18n.f("…", …), I18n.tn("one", "many", …),
    tr("…"), tr_n("one", "many", …), atr("…");
  - a constant string assigned to text, tooltip_text, placeholder_text, title,
    dialog_text, ok_button_text (Godot translates these by itself);
  - the first argument of add_item / add_check_item / add_radio_check_item /
    add_icon_item / add_separator / add_tab / set_item_text / set_tab_title,
    when it is a constant string;
  - text / tooltip_text properties in .tscn scenes.

Left out: print / push_warning / push_error lines, strings with no letter,
lines or files marked `# i18n:skip` / `# i18n:skip-file`, selftests,
diagnostics, harness checks and tools. A comment `# i18n: <note>` on the line
above becomes a note for translators. `# i18n:extract` on the line above a
constant takes every prose string in it (labels kept in const tables; the
code must still translate them where they are shown).

Assignments of a FORMATTED string (`.text = "…%d…" % x`) cannot translate by
themselves: they are counted per file in the report as "needs wrapping", the
to-do list for Phase 2.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
import po  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "locale", "simbiogenesis.pot")
REPORT = os.path.join(ROOT, "locale", ".extract_report.json")

SCAN_DIRS = ["scenes", "system_graph", "core", "gameplay", "crisis_events", "vegetation",
             "power_system", "maps"]
SKIP_DIRS = {".godot", ".git", "parked", "addons", "testdata", "tools", "harness",
             "Imported Models", "assets", "screenshots", "plans", "release"}
SKIP_FILE_RE = re.compile(r"(_selftest|_smoketest|_diag|_diag_run|_probe|_bench)\.gd$")

STR = r'"((?:[^"\\\n]|\\.)*)"'
STR_ANY = r'(?:"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\')'

CALLS = [
    # (regex, kind) — kind: "t" (msg[, ctx]), "f" (msg, args[, ctx]), "tn" (one, many, n[, ctx])
    (re.compile(r"\bI18n\.t\(\s*" + STR + r"(?:\s*,\s*" + STR + r")?"), "t"),
    (re.compile(r"\bI18n\.f\(\s*" + STR), "f"),
    (re.compile(r"\bI18n\.tn\(\s*" + STR + r"\s*,\s*" + STR), "tn"),
    (re.compile(r"(?<![\w.])a?tr\(\s*" + STR + r"(?:\s*,\s*" + STR + r")?"), "t"),
    (re.compile(r"(?<![\w.])tr_n\(\s*" + STR + r"\s*,\s*" + STR), "tn"),
]
PROPS = r"(?:text|tooltip_text|placeholder_text|title|dialog_text|ok_button_text|cancel_button_text)"
ASSIGN = re.compile(r"(?:^|[\s.(])" + PROPS + r"\s*=\s*" + STR + r"\s*(?:#.*)?$")
ASSIGN_FORMATTED = re.compile(r"(?:^|[\s.(])" + PROPS + r"\s*=\s*" + STR + r"\s*%")
ITEM_CALLS = re.compile(r"\.(?:add_item|add_check_item|add_radio_check_item|add_separator|add_tab|"
                        r"add_icon_item|add_icon_check_item)\(\s*(?:[^,()\"]+,\s*)?" + STR + r"\s*[,)]")
SET_ITEM = re.compile(r"\.(?:set_item_text|set_tab_title|set_item_tooltip)\(\s*[^,]+,\s*" + STR + r"\s*\)")
TSCN_PROP = re.compile(r'^(text|tooltip_text|placeholder_text|title)\s*=\s*' + STR + r"\s*$")
# Helpers that put their string arguments on screen (_add_slider(v, "Max speed", …),
# SectionHeader.make("Wiring"), IconButton.make("trash-2", "Remove", …), …). Their
# literal arguments that read as prose are extracted; ids and icon names are not.
HELPER_CALL = re.compile(r"(?<![\w.])(?:_?(?:add|make|labeled|section|hint|tip|lbl|hdr|title|label|header|status|caption|"
                         r"note|row|chip|pill|card|toast|notify)\w*|(?:SectionHeader|KVRow|FormRow|IconButton|"
                         r"AlertBanner|EmptyState|ModalFrame|Collapsible|DockShell)\.\w+|show_alert|set_hint|"
                         r"set_mode|set_badge|toast|notify|show_toast|_toast)\((.*)")
PROSE = re.compile(r"(\s|^[A-Z]|[.!?…:]$)")
ID_LIKE = re.compile(r"^[a-z0-9][a-z0-9_.:/-]*$")
NOISE = re.compile(r"^(print|prints|printerr|push_warning|push_error|assert)\(")
HAS_LETTER = re.compile(r"[^\W\d_]", re.UNICODE)


def budget_for(line: str) -> str:
    if "tooltip" in line:
        return "tooltip"
    if "Button" in line or "add_item" in line or "add_tab" in line:
        return "button"
    if "title" in line:
        return "title"
    return "label"


def wanted(s: str) -> bool:
    s = s.strip()
    if not s or not HAS_LETTER.search(s):
        return False
    if re.fullmatch(r"[A-Za-z0-9_./:-]+", s) and ("_" in s or "/" in s or "://" in s):
        return False   # an id, path or url
    if s.startswith("res://") or s.startswith("user://"):
        return False
    return True


class Pot:
    def __init__(self) -> None:
        self.entries: dict[tuple[str, str], po.Entry] = {}

    def add(self, msg: str, ctx: str, ref: str, note: str = "", plural: str = "", budget: str = "") -> None:
        msg = po.unescape(msg)
        ctx = po.unescape(ctx)
        plural = po.unescape(plural)
        if not wanted(msg):
            return
        key = (ctx, msg)
        e = self.entries.get(key)
        if e is None:
            e = po.Entry(msgid=msg, ctx=ctx, plural=plural, msgstr=["", ""] if plural else [""])
            self.entries[key] = e
        # One reference per file (up to 12 files): --only filters by file, so a string
        # used on a first-hour screen must keep that screen even when used elsewhere first.
        f = ref.rsplit(":", 1)[0]
        if len(e.refs) < 12 and not any(r.rsplit(":", 1)[0] == f for r in e.refs):
            e.refs.append(ref)
        if note and note not in e.extracted:
            e.extracted.append(note)
        if budget and not any(x.startswith("budget:") for x in e.extracted):
            e.extracted.append(f"budget: {budget}")


def scan_gd(path: str, rel: str, pot: Pot, report: dict) -> None:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    if any("i18n:skip-file" in ln for ln in lines[:15]):
        return
    note = ""
    unwrapped = 0
    block = depth = 0
    for i, line in enumerate(lines, 1):
        s = line.strip()
        if s.startswith("#") and "i18n:extract" in s:
            block = 1          # extract the prose literals of the next statement
            continue
        if block:
            for lit in re.finditer(STR, line):
                if PROSE.search(lit.group(1)) and not ID_LIKE.match(lit.group(1)):
                    pot.add(lit.group(1), "", f"{rel}:{i}", "", budget="label")
            depth += line.count("[") + line.count("{") + line.count("(")                 - line.count("]") - line.count("}") - line.count(")")
            if depth <= 0:
                block, depth = 0, 0
            continue
        m_note = re.match(r"#\s*i18n:\s*(?!skip|extract)(.+)", s)
        if m_note:
            note = m_note.group(1).strip()
            continue
        if s.startswith("#") or "i18n:skip" in line or NOISE.match(s):
            note = ""
            continue
        ref = f"{rel}:{i}"
        for rx, kind in CALLS:
            for m in rx.finditer(line):
                if kind == "tn":
                    pot.add(m.group(1), "", ref, note, plural=m.group(2))
                elif kind == "t":
                    ctx = m.group(2) if m.lastindex and m.lastindex >= 2 and m.group(2) else ""
                    pot.add(m.group(1), ctx or "", ref, note)
                else:
                    pot.add(m.group(1), "", ref, note)
        m = ASSIGN.search(line)
        if m:
            pot.add(m.group(1), "", ref, note, budget=budget_for(line))
        elif ASSIGN_FORMATTED.search(line) and "I18n." not in line and "tr(" not in line:
            unwrapped += 1
        for rx in (ITEM_CALLS, SET_ITEM):
            for m in rx.finditer(line):
                pot.add(m.group(1), "", ref, note, budget=budget_for(line))
        for m in HELPER_CALL.finditer(line):
            args = m.group(1)
            for lit in re.finditer(STR, args):
                txt = lit.group(1)
                # A whole literal only, not the left side of "..." % x or "..." + y.
                tail = args[lit.end():].lstrip()
                if tail.startswith("%") or tail.startswith("+"):
                    continue
                if PROSE.search(txt) and not ID_LIKE.match(txt):
                    pot.add(txt, "", ref, note, budget="label")
        note = ""
    if unwrapped:
        report["needs_wrapping"][rel] = unwrapped


def scan_tscn(path: str, rel: str, pot: Pot) -> None:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh, 1):
            m = TSCN_PROP.match(line.strip())
            if m:
                pot.add(m.group(2), "", f"{rel}:{i}", budget=m.group(1).replace("_text", ""))


def walk() -> tuple[Pot, dict]:
    pot = Pot()
    report = {"needs_wrapping": {}, "files": 0}
    for top in SCAN_DIRS:
        base = os.path.join(ROOT, top)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for fn in sorted(filenames):
                p = os.path.join(dirpath, fn)
                rel = os.path.relpath(p, ROOT).replace(os.sep, "/")
                if fn.endswith(".gd") and not SKIP_FILE_RE.search(fn):
                    report["files"] += 1
                    scan_gd(p, rel, pot, report)
                elif fn.endswith(".tscn"):
                    scan_tscn(p, rel, pot)
    return pot, report


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--report", action="store_true", help="print the files with the most unwrapped text")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    pot, report = walk()
    cat = po.Catalog(header=po.header_for(""), entries=sorted(pot.entries.values(),
                     key=lambda e: (e.refs[0] if e.refs else "", e.msgid)))
    cat.header.pop("Language", None)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    po.write(args.out, cat, po.HEADER_ORDER)
    report["strings"] = len(cat.entries)
    report["needs_wrapping_total"] = sum(report["needs_wrapping"].values())
    with open(REPORT, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(report, fh, indent=1, sort_keys=True)
    print(f"extract: {len(cat.entries)} strings from {report['files']} scripts -> "
          f"{os.path.relpath(args.out, ROOT)}; {report['needs_wrapping_total']} formatted "
          f"assignments still need wrapping")
    if args.report:
        top = sorted(report["needs_wrapping"].items(), key=lambda kv: -kv[1])[:25]
        for f, n in top:
            print(f"  {n:4d}  {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
