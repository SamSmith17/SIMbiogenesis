#!/usr/bin/env python3
"""Summarise a feature-tour run's UI audit (stops/<id>/ui_audit.json files).

    python tools/ui_audit_report.py <run dir> [--compare <older run dir>] [--md out.md]

Prints totals by kind, the worst stops, and the owner pairs behind overlaps
(e.g. "EditToolbarLayer x SolarUI"), so a fix can be aimed at a cause rather
than a count. With --compare, shows the change per kind and per stop.
Stdlib only.
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path


def load_run(run: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for f in sorted(run.glob("**/stops/*/ui_audit.json")):
        try:
            out[f.parent.name] = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass
    return out


def owner_of(path: str) -> str:
    parts = [p for p in path.split("/") if p and p not in ("root", "Main", "UILayer")]
    return parts[0] if parts else path


def summarise(run: dict[str, dict]) -> dict:
    kinds = collections.Counter()
    sev = collections.Counter()
    pairs = collections.Counter()
    clip_by = collections.Counter()
    per_stop = {}
    for stop, a in run.items():
        e = int(a.get("errors", 0))
        w = int(a.get("warnings", 0))
        per_stop[stop] = (e, w)
        sev["error"] += e
        sev["warning"] += w
        for fd in a.get("findings", []):
            kinds[fd["kind"]] += 1
            if fd["kind"] in ("overlap", "text_overlap"):
                a1 = owner_of(fd["path"])
                b1 = owner_of(fd.get("other", ""))
                pairs[" x ".join(sorted([a1, b1]))] += 1
            elif fd["kind"] in ("clipped", "overhang"):
                clip_by[f'{fd["kind"]}: {owner_of(fd["path"])}'] += 1
        for k, v in (a.get("canvas_truncated") or {}).items():
            kinds["canvas_truncated:" + k] += len(v) if isinstance(v, list) else int(v)
    return {"kinds": kinds, "sev": sev, "pairs": pairs, "clip_by": clip_by, "per_stop": per_stop}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run", type=Path)
    ap.add_argument("--compare", type=Path)
    ap.add_argument("--md", type=Path)
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    cur = summarise(load_run(args.run))
    old = summarise(load_run(args.compare)) if args.compare else None
    lines = [f"# UI audit — {args.run.name}", ""]
    if old:
        lines.append(f"Compared with {args.compare.name}.")
        lines.append("")
    lines.append(f"**{cur['sev']['error']} errors, {cur['sev']['warning']} warnings** across {len(cur['per_stop'])} stops"
                 + (f" (was {old['sev']['error']} / {old['sev']['warning']})" if old else ""))
    lines += ["", "## By kind", "", "| kind | count |" + (" before |" if old else ""), "|---|---|" + ("---|" if old else "")]
    for k, v in cur["kinds"].most_common():
        lines.append(f"| {k} | {v} |" + (f" {old['kinds'].get(k, 0)} |" if old else ""))
    if old:
        for k, v in old["kinds"].items():
            if k not in cur["kinds"]:
                lines.append(f"| {k} | 0 | {v} |")
    lines += ["", "## Worst stops", "", "| stop | errors | warnings |" + (" errors before |" if old else ""),
              "|---|---|---|" + ("---|" if old else "")]
    for stop, (e, w) in sorted(cur["per_stop"].items(), key=lambda kv: -kv[1][0])[:15]:
        lines.append(f"| {stop} | {e} | {w} |" + (f" {old['per_stop'].get(stop, ('-',))[0]} |" if old else ""))
    lines += ["", "## Overlaps by owner pair", "", "| owners | findings |", "|---|---|"]
    for p, v in cur["pairs"].most_common(20):
        lines.append(f"| {p} | {v} |")
    lines += ["", "## Clipped / overhang by owner", "", "| where | findings |", "|---|---|"]
    for p, v in cur["clip_by"].most_common(20):
        lines.append(f"| {p} | {v} |")
    text = "\n".join(lines) + "\n"
    print(text)
    if args.md:
        args.md.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
