#!/usr/bin/env python3
"""Turn a feature-tour run into docs: docs/tour/*.jpg, docs/FEATURES.md and
the README gallery between <!-- TOUR:BEGIN --> / <!-- TOUR:END -->.

    python tools/tour_docs.py                 # the latest tools\\tour.ps1 run
    python tools/tour_docs.py --run <dir>     # a specific run folder
    python tools/tour_docs.py --strict        # fail if any stop failed
    python tools/tour_docs.py --check         # only report, write nothing

Stdlib only. The persistent catalogue is docs/tour/index.json: a run UPDATES
it (a partial run with -Stops refreshes just those stops), a stop whose run
FAILED keeps its previous image (with a warning), and entries for stops whose
file no longer exists in core/tour/stops/ are dropped with their image.

The full-tour video link comes from docs/tour/video.json
({"url": "...", "date": "...", "minutes": 6}), edited by hand after uploading
the tour.mp4 a record run produced — this script never uploads anything.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
STOPS_DIR = REPO / "core" / "tour" / "stops"
DOCS = REPO / "docs"
TOUR_DOCS = DOCS / "tour"
INDEX = TOUR_DOCS / "index.json"
VIDEO = TOUR_DOCS / "video.json"
FEATURES = DOCS / "FEATURES.md"
README = REPO / "README.md"
BEGIN = "<!-- TOUR:BEGIN -->"
END = "<!-- TOUR:END -->"
CHAPTERS = ["World", "Build", "Systems", "People", "Labs"]
CHAPTER_BLURB = {
    "World": "The real place: terrain, imagery, sky, time and weather.",
    "Build": "Shape the site and put things on it.",
    "Systems": "The resource-flow graph and the tools that design it.",
    "People": "The community that lives there, and the crowd simulation.",
    "Labs": "Design studios and multiplayer.",
}
GRID_COLS = 3
THUMB_W = 260
MAX_IMAGE_KB = 400


def screenshots_root() -> Path:
    appdata = os.environ.get("APPDATA", "")
    return Path(appdata) / "Godot" / "app_userdata" / "SIMbiogenesis" / "screenshots"


def latest_run() -> Path | None:
    root = screenshots_root()
    marker = root / "tour_latest.txt"
    if marker.exists():
        label = marker.read_text(encoding="ascii", errors="ignore").strip()
        if label and (root / label / "tour_manifest.json").exists():
            return root / label
    runs = sorted((p for p in root.glob("tour_*") if (p / "tour_manifest.json").exists()),
                  key=lambda p: p.stat().st_mtime, reverse=True)
    return runs[0] if runs else None


OPTIONAL: set[str] = set()


def stop_files() -> dict[str, int]:
    """id -> file order, parsed from core/tour/stops/NN_<id>.gd (optional
    stops are noted in OPTIONAL)."""
    out: dict[str, int] = {}
    files = sorted(f for f in STOPS_DIR.glob("*.gd") if not f.name.startswith("_"))
    for i, f in enumerate(files):
        text = f.read_text(encoding="utf-8")
        m = re.search(r'(?m)^\s*id\s*=\s*"([^"]+)"', text)
        sid = m.group(1) if m else re.sub(r"^\d+_", "", f.stem)
        out[sid] = i
        if re.search(r"(?m)^\s*optional\s*=\s*true", text):
            OPTIONAL.add(sid)
    return out


def load_json(p: Path, default):
    try:
        return json.loads(p.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default


META_KEYS = ["id", "title", "chapter", "summary", "how", "action", "button", "key",
             "open_hints", "world", "blurb", "optional"]


def merge_run(index: dict, run_dir: Path, check: bool) -> tuple[dict, list[str], list[str]]:
    manifest = load_json(run_dir / "tour_manifest.json", None)
    if manifest is None:
        raise SystemExit(f"no tour_manifest.json in {run_dir}")
    warnings: list[str] = []
    failed: list[str] = []
    stops = index.setdefault("stops", {})
    for s in manifest.get("stops", []):
        sid = s.get("id", "")
        if not sid:
            continue
        entry = stops.get(sid, {})
        for k in META_KEYS:
            if k in s:
                entry[k] = s[k]
        entry["status"] = s.get("status", "?")
        entry["failures"] = s.get("failures", [])
        img = run_dir / s.get("hero", "") if s.get("hero") else None
        if s.get("status") == "PASS" and img is not None and img.exists():
            kb = img.stat().st_size / 1024.0
            if kb > MAX_IMAGE_KB:
                warnings.append(f"{sid}: hero image is {kb:.0f} KB (> {MAX_IMAGE_KB} KB)")
            if not check:
                TOUR_DOCS.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(img, TOUR_DOCS / f"{sid}.jpg")
            entry["image"] = f"{sid}.jpg"
            entry["image_run"] = manifest.get("generated", "")
            entry["image_commit"] = manifest.get("git_commit", "")
        else:
            why = "; ".join(s.get("failures", [])) or "no image"
            had = "keeping the previous image" if entry.get("image") else "no image yet"
            warnings.append(f"{sid}: {s.get('status', '?')} ({why}) — {had}")
            failed.append(sid)
        stops[sid] = entry
    index["last_run"] = {
        "label": manifest.get("label", run_dir.name),
        "generated": manifest.get("generated", ""),
        "git_commit": manifest.get("git_commit", ""),
        "passed": manifest.get("passed", 0),
        "total": manifest.get("total", 0),
        "video_secs": manifest.get("video_secs", None),
    }
    return index, warnings, failed


def prune(index: dict, order: dict[str, int], check: bool) -> list[str]:
    gone = [sid for sid in index.get("stops", {}) if sid not in order]
    for sid in gone:
        img = index["stops"][sid].get("image")
        del index["stops"][sid]
        if img and not check:
            (TOUR_DOCS / img).unlink(missing_ok=True)
    return gone


def how_to_open(e: dict) -> str:
    hints = e.get("open_hints") or []
    if not hints:
        if e.get("key"):
            hints = [f"Press {e['key']}"]
        elif e.get("button"):
            hints = [f"Click {e['button']}"]
    return " · ".join(f"**{h}**" for h in hints)


def ordered(index: dict, order: dict[str, int]) -> list[dict]:
    return sorted(index.get("stops", {}).values(), key=lambda e: order.get(e.get("id", ""), 10**6))


def video_line(prefix: str = "") -> str:
    v = load_json(VIDEO, {})
    url = (v.get("url") or "").strip()
    if not url:
        return ""
    mins = v.get("minutes")
    length = f" ({mins} min)" if mins else ""
    return f"{prefix}▶ **[Watch the full feature tour{length}]({url})**"


def render_features(index: dict, order: dict[str, int]) -> str:
    entries = ordered(index, order)
    lr = index.get("last_run", {})
    out = ["# SIMbiogenesis — feature tour", "",
           "A short visual tour of what the game can do today, one section per mode or "
           "feature, with how to open it. Every image is a screenshot from the automated "
           "feature tour (`tools\\tour.ps1`), taken on the author's real sites.", ""]
    vl = video_line()
    if vl:
        out += [vl, ""]
    out.append("**Contents** — " + " · ".join(
        f"[{c}](#{c.lower()})" for c in CHAPTERS if any(e.get("chapter") == c for e in entries)))
    out.append("")
    for c in CHAPTERS:
        group = [e for e in entries if e.get("chapter") == c]
        if not group:
            continue
        out += [f'<a id="{c.lower()}"></a>', "", f"## {c}", "", f"*{CHAPTER_BLURB.get(c, '')}*", ""]
        for e in group:
            sid = e["id"]
            out += [f'<a id="{sid}"></a>', "", f"### {e.get('title', sid)}", ""]
            if e.get("image"):
                out += [f"![{e.get('title', sid)}](tour/{e['image']})", ""]
            out += [f"*{e.get('summary', '')}*", ""]
            hto = how_to_open(e)
            if hto:
                out += [f"**How to open:** {hto}", ""]
            how = e.get("how") or []
            if how:
                out += [f"- {h}" for h in how] + [""]
            if e.get("blurb"):
                out += [e["blurb"], ""]
            if e.get("status") not in (None, "PASS"):
                out += [f"> ⚠ The last tour run could not demo this ({e.get('status')}); "
                        "the image is from an earlier run." if e.get("image") else
                        f"> ⚠ The last tour run could not demo this ({e.get('status')}).", ""]
    commit = lr.get("git_commit", "")
    out += ["---", "",
            f"<sub>Generated by `tools/tour_docs.py` from tour run {lr.get('label', '?')} "
            f"({lr.get('generated', '?')}{', commit ' + commit if commit else ''}; "
            f"{lr.get('passed', 0)}/{lr.get('total', 0)} stops passed). Regenerate with "
            "`tools\\tour.ps1 -Mode stills` then `python tools/tour_docs.py`. "
            "Add a feature: copy `core/tour/stops/_template.gd`.</sub>", ""]
    return "\n".join(out)


def render_readme_block(index: dict, order: dict[str, int]) -> str:
    entries = [e for e in ordered(index, order) if e.get("image")]
    lines = [BEGIN,
             "<!-- Generated by tools/tour_docs.py — edit the tour stops in core/tour/stops/, not this block. -->",
             "", "## What it does", ""]
    vl = video_line()
    if vl:
        lines += [vl, ""]
    lines += [f"A quick look at every mode — full write-ups with how to open each are in "
              f"**[docs/FEATURES.md](docs/FEATURES.md)**.", ""]
    for c in CHAPTERS:
        group = [e for e in entries if e.get("chapter") == c]
        if not group:
            continue
        lines += [f"**{c}** — {CHAPTER_BLURB.get(c, '')}", "", "<table>"]
        for i in range(0, len(group), GRID_COLS):
            lines.append("<tr>")
            for e in group[i:i + GRID_COLS]:
                sid = e["id"]
                key = e.get("key") or ""
                sub = f"<br><sub>{key.split(' / ')[0]}</sub>" if key else (
                    f"<br><sub>{e['button']}</sub>" if e.get("button") else "")
                lines.append(
                    f'<td align="center" valign="top" width="{THUMB_W + 20}">'
                    f'<a href="docs/FEATURES.md#{sid}"><img src="docs/tour/{e["image"]}" '
                    f'width="{THUMB_W}" alt="{e.get("title", sid)}"></a><br>'
                    f'<b>{e.get("title", sid)}</b>{sub}</td>')
            lines.append("</tr>")
        lines += ["</table>", ""]
    lines.append(END)
    return "\n".join(lines)


def update_readme(block: str, check: bool) -> bool:
    text = README.read_text(encoding="utf-8")
    if BEGIN in text and END in text:
        a = text.index(BEGIN)
        b = text.index(END) + len(END)
        new = text[:a] + block + text[b:]
    else:
        # First run: after the intro, before the first "## " section.
        m = re.search(r"(?m)^## ", text)
        at = m.start() if m else len(text)
        new = text[:at] + block + "\n\n" + text[at:]
    if new == text:
        return False
    if not check:
        README.write_text(new, encoding="utf-8", newline="\n")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--run", type=Path, help="tour run folder (has tour_manifest.json)")
    ap.add_argument("--strict", action="store_true", help="exit 1 if any stop in the run failed")
    ap.add_argument("--check", action="store_true", help="report only; write nothing")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    run = args.run or latest_run()
    if run is None:
        print("tour_docs: no tour run found — run tools\\tour.ps1 -Mode stills first", file=sys.stderr)
        return 2
    order = stop_files()
    index = load_json(INDEX, {"version": 1, "stops": {}})
    index, warnings, failed = merge_run(index, run, args.check)
    gone = prune(index, order, args.check)
    missing = [sid for sid in order if sid not in index.get("stops", {})]

    features = render_features(index, order)
    block = render_readme_block(index, order)
    if not args.check:
        TOUR_DOCS.mkdir(parents=True, exist_ok=True)
        INDEX.write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        FEATURES.write_text(features, encoding="utf-8", newline="\n")
        if not VIDEO.exists():
            VIDEO.write_text(json.dumps({"url": "", "date": "", "minutes": None}, indent=2) + "\n",
                             encoding="utf-8")
    readme_changed = update_readme(block, args.check)

    lr = index.get("last_run", {})
    print(f"tour_docs: run {lr.get('label')} — {lr.get('passed')}/{lr.get('total')} stops passed")
    print(f"tour_docs: {len(index.get('stops', {}))} features documented"
          f"{'' if args.check else ' -> docs/FEATURES.md, docs/tour/'}"
          f"; README {'updated' if readme_changed else 'unchanged'}{' (check only)' if args.check else ''}")
    for w in warnings:
        print(f"  warning: {w}")
    for sid in gone:
        print(f"  removed: {sid} (its stop file is gone)")
    for sid in missing:
        why = "optional - run with -IncludeOptional" if sid in OPTIONAL else "never run"
        print(f"  not yet documented: {sid} ({why})")
    if args.strict and failed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
