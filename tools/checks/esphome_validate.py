"""Run the ESP board designer's YAML through ESPHome's own validator.

    python tools/checks/esphome_validate.py [--esphome <path>] [--godot <path>] [--keep]

Dumps a spread of designs with tools/checks/esplab_dump_yaml.gd, then runs
`esphome config` on each and prints one line per file plus a summary.
Skips (exit 0, with a note) when no ESPHome CLI is found: install it with
`pip install esphome` (a virtualenv is fine; pass --esphome to its exe).
Exit code 1 if any file fails.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

DEFAULT_GODOT = r"C:\Users\notsa\Downloads\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"


def find_esphome(given):
    if given:
        return given if os.path.exists(given) else None
    return shutil.which("esphome")


def check(esphome, path):
    r = subprocess.run([esphome, "config", path], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", cwd=os.path.dirname(path))
    if r.returncode == 0:
        return path, True, ""
    out = (r.stdout + r.stderr).splitlines()
    # ESPHome prints the failing config with the error lines marked.
    lines = [l for l in out if "[" in l and ("is an invalid option" in l or "required" in l.lower()
             or "invalid" in l.lower() or "error" in l.lower())]
    if not lines:
        lines = [l for l in out if l.strip()][-12:]
    return path, False, "\n      ".join(lines[:12])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esphome", default="")
    ap.add_argument("--godot", default=os.environ.get("GODOT", DEFAULT_GODOT))
    ap.add_argument("--keep", action="store_true", help="keep the dumped YAML folder")
    ap.add_argument("--jobs", type=int, default=6)
    a = ap.parse_args()
    esphome = find_esphome(a.esphome)
    if not esphome:
        print("esphome_validate: SKIP (no esphome CLI; pip install esphome)")
        return 0
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out = tempfile.mkdtemp(prefix="esplab_yaml_")
    r = subprocess.run([a.godot, "--headless", "--path", repo, "--script", "tools/checks/esplab_dump_yaml.gd",
                        "--", "--out=" + out], capture_output=True, text=True, encoding="utf-8", errors="replace")
    print("\n".join(l for l in r.stdout.splitlines() if l.startswith("esplab dump")))
    files = []
    for root, _dirs, names in os.walk(out):
        for n in names:
            if n.endswith(".yaml") and n != "secrets.yaml":
                files.append(os.path.join(root, n))
    files.sort()
    fails = 0
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for path, ok, why in ex.map(lambda p: check(esphome, p), files):
            name = os.path.basename(path)
            if ok:
                print("  ok    %s" % name)
            else:
                fails += 1
                print("  FAIL  %s\n      %s" % (name, why))
    print("esphome_validate: %d files, %d failed -> %s" % (len(files), fails, "PASS" if fails == 0 and files else "FAIL"))
    if a.keep:
        print("kept: " + out)
    else:
        shutil.rmtree(out, ignore_errors=True)
    return 1 if fails or not files else 0


if __name__ == "__main__":
    sys.exit(main())
