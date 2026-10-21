#!/usr/bin/env python3
"""Fail when .gitignore hides SOURCE from GitHub.

An unanchored `build/` rule (meant for export output) once matched the
core/linkage/build/ module: it never reached GitHub and every fresh clone
failed to compile. This lists every ignored file with a code or scene
extension outside the places that are ignored on purpose (the art folders and
bespoke map scenes that travel in asset packs, editor caches, local notes,
release output).

    python tools/checks/ignored_source_audit.py      # exit 1 on a hit
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_EXTS = {"gd", "gdshader", "gdshaderinc", "tscn", "tres", "uid", "gdextension", "py", "ps1", "mjs"}
# Prefixes (folders end in "/") that are ignored on purpose.
ALLOWED = [
    ".godot/", ".claude/", "plans/", "build/", "export/", "release/", "scad_library/",
    # The gitignored art + bespoke map scenes (core/sharing/asset_pack_format.gd
    # ART_DIRS / ART_FILES — they ship in asset packs and the release art add-on).
    "Imported Models/", "StarShade FBX/", "Starshade Pretty Version/", "Player Character/",
    "Wood034_1K-JPG/", "Metal051C_1K-JPG/",
    "scenes/maps/soak_festival_2026.tscn", "scenes/maps/mars_aerial.tscn",
    "scenes/maps/mars_main_legacy.tscn", "maps/soak_camp_map.tres", "maps/mars_aerial_map.tres",
    "main.tscn", "scenes/gameplay/Tree.tscn",
    # Root-level one-off debug scripts (.gitignore "Local debug artifacts").
    "test_script.gd", "test_gltf.gd", "dump_props.gd", "debug_analyzer.gd",
]


def main() -> int:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
        capture_output=True, check=True).stdout.decode("utf-8", "replace")
    hits = []
    for rel in filter(None, out.split("\0")):
        ext = rel.rsplit(".", 1)[-1].lower() if "." in rel.rsplit("/", 1)[-1] else ""
        if ext not in SOURCE_EXTS:
            continue
        if any(rel == a or (a.endswith("/") and rel.startswith(a)) for a in ALLOWED):
            continue
        hits.append(rel)
    if hits:
        print("Source files hidden by .gitignore (a fresh clone will not have them):")
        for h in sorted(hits):
            rule = subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-v", h],
                                  capture_output=True, text=True).stdout.strip().split("\t")[0]
            print(f"  {h}    <- {rule}")
        return 1
    print("ignored_source_audit: PASS - no source file is hidden by .gitignore")
    return 0


if __name__ == "__main__":
    sys.exit(main())
