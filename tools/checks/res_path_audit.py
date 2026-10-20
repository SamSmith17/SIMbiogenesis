#!/usr/bin/env python3
"""Find references to files that do not exist.

Scans every tracked text file (plus the maintainer's local, gitignored map
scenes when they are present) for:
  * res:// literals (ext_resource paths, load/preload, const strings,
    project.godot autoloads, export_presets.cfg filters), and
  * relative Markdown links / <img src> in .md files,
and reports each target that is missing on disk.

Paths built at run time (anything with %, {, $, * or <) are skipped, and so
is user://. A target ending in "/" must be a directory.

  python tools/checks/res_path_audit.py                       # list misses
  python tools/checks/res_path_audit.py --write-baseline b.json
  python tools/checks/res_path_audit.py --baseline b.json     # exit 1 on NEW misses

Baselines key on the missing TARGET (repo-relative), so moving the file that
holds a reference does not make an old miss look new.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

TEXT_EXT = {
    ".gd", ".tscn", ".tres", ".godot", ".cfg", ".json", ".gdshader",
    ".gdshaderinc", ".ps1", ".py", ".mjs", ".md", ".txt",
}
# Gitignored maintainer files that still reference the tree.
LOCAL_EXTRA = [
    "scenes/maps/soak_festival_2026.tscn",
    "scenes/maps/mars_aerial.tscn",
    "scenes/maps/mars_main_legacy.tscn",
    "main.tscn",
    "maps/soak_camp_map.tres",
    "maps/mars_aerial_map.tres",
]

# Quoted paths may contain spaces ("res://Imported Models/..."); bare ones may not.
QUOTED_RES_RE = re.compile(r"(?<=[\"'`])res://[^\"'`\n]+")
RES_RE = re.compile(r"res://[^\"'\s)\]>,;`]+")
MD_LINK_RE = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
IMG_RE = re.compile(r"<img[^>]*\ssrc=\"([^\"]+)\"")
DYNAMIC = set("%{$*<[\\…")


def tracked_files():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=REPO,
                         capture_output=True, check=True).stdout
    names = [n for n in out.decode("utf-8").split("\0") if n]
    files = [n for n in names if Path(n).suffix.lower() in TEXT_EXT]
    files += [n for n in LOCAL_EXTRA if (REPO / n).is_file()]
    return files


def res_exists(target: str) -> bool:
    rel = target[len("res://"):]
    if rel.endswith("/"):
        return (REPO / rel).is_dir()
    return (REPO / rel).exists()


def scan(files):
    misses = []  # (key, file, line_no, target)
    for name in files:
        path = REPO / name
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        is_md = name.lower().endswith(".md")
        for no, line in enumerate(text.splitlines(), 1):
            found = [m for m in QUOTED_RES_RE.finditer(line)]
            spans = [(m.start(), m.end()) for m in found]
            found += [m for m in RES_RE.finditer(line)
                      if not any(a <= m.start() < b for a, b in spans)]
            for m in found:
                t = m.group(0).rstrip(".:")
                if any(c in DYNAMIC for c in t) or t in ("res://", "res:///"):
                    continue
                if not res_exists(t):
                    misses.append((t[len("res://"):], name, no, t))
            if not is_md:
                continue
            for rx in (MD_LINK_RE, IMG_RE):
                for m in rx.finditer(line):
                    t = m.group(1)
                    if re.match(r"^[a-z][a-z0-9+.-]*:", t, re.I) or t.startswith("#"):
                        continue
                    t = t.split("#", 1)[0].split("?", 1)[0]
                    if not t or any(c in DYNAMIC for c in t):
                        continue
                    t = t.replace("%20", " ")
                    resolved = (path.parent / t).resolve()
                    if not resolved.exists():
                        try:
                            key = resolved.relative_to(REPO).as_posix()
                        except ValueError:
                            key = str(resolved)
                        misses.append((key, name, no, t))
    return misses


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--baseline", help="fail only on misses not in this file")
    ap.add_argument("--write-baseline", help="write the current misses here")
    ap.add_argument("--quiet", action="store_true", help="print the summary only")
    args = ap.parse_args()

    misses = scan(tracked_files())
    keys = sorted({k for k, *_ in misses})
    if args.write_baseline:
        Path(args.write_baseline).write_text(json.dumps(keys, indent=1), encoding="utf-8")
        print(f"res_path_audit: wrote {len(keys)} missing target(s) to {args.write_baseline}")
        return 0

    known = set()
    if args.baseline:
        known = set(json.loads(Path(args.baseline).read_text(encoding="utf-8")))
    new = [m for m in misses if m[0] not in known]
    shown = new if args.baseline else misses
    if not args.quiet:
        for key, name, no, t in shown:
            print(f"{name}:{no}: {t}")
    label = "new missing" if args.baseline else "missing"
    print(f"res_path_audit: {len({m[0] for m in shown})} {label} target(s) "
          f"in {len(shown)} reference(s) {'FAIL' if shown and args.baseline else 'OK' if args.baseline else ''}".rstrip())
    return 1 if (args.baseline and new) else 0


if __name__ == "__main__":
    sys.exit(main())
