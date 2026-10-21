#!/usr/bin/env python3
"""Install the Godot export templates that match the editor binary, so
tools/release/build_release.py can export. Same as the editor's
Editor -> Manage Export Templates -> Download and Install.

    python tools/release/install_export_templates.py
    python tools/release/install_export_templates.py --godot <path to Godot> --tpz <already downloaded .tpz>

Downloads Godot_v<version>-stable_export_templates.tpz (~1.2 GB) from the
official godotengine/godot GitHub release unless --tpz is given.
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_release import DEFAULT_GODOT, godot_version, templates_dir  # noqa: E402

URL = "https://github.com/godotengine/godot/releases/download/{tag}/Godot_v{tag}_export_templates.tpz"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot", default=os.environ.get("SIMBIO_GODOT", DEFAULT_GODOT))
    ap.add_argument("--tpz", default="", help="use this .tpz instead of downloading")
    args = ap.parse_args()

    ver = godot_version(args.godot)             # e.g. "4.7.1.stable"
    dest = templates_dir(ver)
    if (dest / "version.txt").exists():
        print(f"export templates for {ver} are already installed in {dest}")
        return
    tag = ver.rsplit(".", 1)[0] + "-" + ver.rsplit(".", 1)[1]   # "4.7.1-stable"
    tpz = Path(args.tpz) if args.tpz else None
    tmp = None
    if tpz is None:
        tmp = Path(tempfile.mkdtemp(prefix="godot_templates_"))
        tpz = tmp / f"Godot_v{tag}_export_templates.tpz"
        url = URL.format(tag=tag)
        print(f"downloading {url} …")
        with urllib.request.urlopen(url) as r, open(tpz, "wb") as fh:
            total = int(r.headers.get("Content-Length", 0))
            done = 0
            while chunk := r.read(1 << 20):
                fh.write(chunk)
                done += len(chunk)
                if total:
                    print(f"\r  {done / 2**20:7.0f} / {total / 2**20:.0f} MB", end="", flush=True)
        print()
    with zipfile.ZipFile(tpz) as z:
        names = z.namelist()
        if "templates/version.txt" not in names:
            sys.exit(f"{tpz} does not look like a Godot export template archive")
        got = z.read("templates/version.txt").decode().strip()
        if got != ver:
            sys.exit(f"{tpz} holds templates for {got}, the editor is {ver}")
        dest.mkdir(parents=True, exist_ok=True)
        for n in names:
            if n.endswith("/") or not n.startswith("templates/"):
                continue
            rel = n[len("templates/"):]
            if ".." in Path(rel).parts:
                continue
            out = dest / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            with z.open(n) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
    if tmp is not None:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"installed export templates {ver} -> {dest}")


if __name__ == "__main__":
    main()
