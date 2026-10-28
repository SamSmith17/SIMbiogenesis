#!/usr/bin/env python3
"""Build a SIMbiogenesis release: Windows / macOS / Linux game builds plus the
optional ART ADD-ON (the gitignored art as simbiogenesis-art-*.pck files).

    python tools/release/build_release.py                    # everything
    python tools/release/build_release.py --platforms windows --no-art
    python tools/release/build_release.py --art-only
    python tools/release/build_release.py --version 0.2.0

Output: release/<version>/
    SIMbiogenesis-<version>-windows.zip   (SIMbiogenesis.exe + its DLLs)
    SIMbiogenesis-<version>-macos.zip     (SIMbiogenesis.app, ad-hoc signed)
    SIMbiogenesis-<version>-linux.zip     (SIMbiogenesis.x86_64 + its .so files)
    simbiogenesis-art-<group>.pck         (one per ART_PACKS group, any OS)
    SHA256SUMS.txt, RELEASE_NOTES.md

Every file is checked against GitHub's 2 GiB per-asset limit. The game finds
the art packs next to itself (core/art_packs.gd), so a player unzips the game
and drops the .pck files beside it. See docs/RELEASES.md.

Needs the Godot editor binary of the project's version and its export
templates (tools/release/install_export_templates.py). The script edits
export_presets.cfg (art lists, version numbers) and project.godot (the
version) for the length of the build and puts both back byte for byte.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRESETS = ROOT / "export_presets.cfg"
PROJECT = ROOT / "project.godot"
GITHUB_ASSET_LIMIT = 2 * 1024 ** 3          # GitHub release assets: 2 GiB each
SAFE_LIMIT = int(1.95 * 1024 ** 3)
DEFAULT_GODOT = r"C:\Users\notsa\Downloads\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"

# Game presets in export_presets.cfg: platform key -> (preset name, file inside the build dir).
GAME_PRESETS = {
    "windows": ("Windows Desktop", "SIMbiogenesis.exe"),
    "macos": ("macOS", "SIMbiogenesis.zip"),
    "linux": ("Linux", "SIMbiogenesis.x86_64"),
}

# The art add-on. A file belongs to the group with the LONGEST matching prefix
# (a prefix ending in "/" is a folder, one ending in "*" every file whose
# path starts with the rest — a model and its extracted textures — anything
# else one file), so a folder
# can be lifted out of another group's: the camp components live under
# "Soak Terrain/" but painted camps and the Structures catalog use them on
# every map, so they ship in "models", not "soak". Sizes measured 2026-10-20
# as imported data: mars ~1.9 GB, soak ~1.1 GB, starshade ~1.2 GB, models
# ~1.0 GB. A pack over SAFE_LIMIT stops the build: split its group.
ART_PACKS = [
    ("mars", ["Imported Models/Mars Aerial/", "Imported Models/Newest Mars Model/",
              "scenes/maps/mars_aerial.tscn", "scenes/maps/mars_main_legacy.tscn",
              "maps/mars_aerial_map.tres", "main.tscn",
              # Mars-only art that sits in other groups' folders.
              "Imported Models/Mars 2026 expanded*",
              "StarShade FBX/Starshade Pretty Version - 18 panel version/Mars 2026 - Aerial Located smaller*"]),
    ("soak", ["Imported Models/Soak Terrain/", "scenes/maps/soak_festival_2026.tscn",
              "maps/soak_camp_map.tres", "scenes/gameplay/Tree.tscn",
              "Imported Models/Soak Terrain/Camps/Camp Components/SOAK barn*"]),
    ("starshade", ["StarShade FBX/", "Starshade Pretty Version/", "Imported Models/StarShades/"]),
    ("models", ["Imported Models/", "Player Character/",
                "Imported Models/Soak Terrain/Camps/Camp Components/"]),
]
# The groups a release builds when --art-groups is not given. SOAK and Mars
# are the author's own festival maps and ship separately (user, 2026-10-28);
# `--art-groups mars,soak` builds them.
DEFAULT_ART_GROUPS = ["starshade", "models"]
# Model file types listed in ART_CONTENTS.md.
MODEL_EXTS = {"glb", "gltf", "fbx", "obj", "blend", "dae", "stl"}
ART_ROOTS = ["Imported Models", "StarShade FBX", "Starshade Pretty Version", "Player Character"]
RESOURCE_EXTS = {"tscn", "tres", "scn", "res", "material", "mesh", "anim"}

# Never in a game build: the art (it ships as the add-on), dev-only folders and
# editor-only addons. macOS additionally drops ffmpeg (no macOS libraries).
GAME_EXCLUDE = [
    "res://Imported Models/*", "res://StarShade FBX/*", "res://Starshade Pretty Version/*",
    "res://Player Character/*", "res://scenes/maps/soak_festival_2026.tscn",
    "res://scenes/maps/mars_aerial.tscn", "res://scenes/maps/mars_main_legacy.tscn",
    "res://maps/soak_camp_map.tres", "res://maps/mars_aerial_map.tres", "res://main.tscn",
    "res://scenes/gameplay/Tree.tscn",
    "res://tools/*", "res://parked/*", "res://plans/*", "res://release/*", "res://build/*",
    "res://scad_library/*", "res://core/linkage/testdata/*", "res://core/microclimate/testdata/*",
    "res://core/poi/testdata/*",
    "res://addons/spacemouse_editor/*", "res://addons/spacemouse_native/*",
    "res://addons/sketchup_import_fix/*",
]
GAME_EXCLUDE_EXTRA = {"macos": ["res://addons/ffmpeg/*"]}
# Loose (non-resource) files the game opens with FileAccess at runtime.
GAME_INCLUDE = ["*.json", "*.stl", "res://CREDITS.md", "res://LICENSE"]


def log(msg: str) -> None:
    print(f"[release] {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"[release] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


# -- Godot ------------------------------------------------------------------

def godot_version(godot: str) -> str:
    out = subprocess.run([godot, "--version"], capture_output=True, text=True).stdout.strip()
    m = re.match(r"(\d+\.\d+(?:\.\d+)?)\.([a-z0-9]+)", out)
    if not m:
        fail(f"could not read the Godot version from '{out}'")
    return f"{m.group(1)}.{m.group(2)}"


def templates_dir(ver: str) -> Path:
    if sys.platform == "win32":
        base = Path(os.environ["APPDATA"]) / "Godot"
    elif sys.platform == "darwin":
        base = Path.home() / "Library/Application Support/Godot"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "godot"
    return base / "export_templates" / ver


def run_godot(godot: str, args: list[str], log_path: Path, output: Path) -> None:
    cmd = [godot, "--headless", "--path", str(ROOT)] + args
    log(" ".join(f'"{a}"' if " " in a else a for a in cmd))
    if output.exists():
        output.unlink()
    with open(log_path, "w", encoding="utf-8", errors="replace") as fh:
        rc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT).returncode
    text = log_path.read_text(encoding="utf-8", errors="replace")
    failed = [ln for ln in text.splitlines() if "Export failed" in ln
              or ("Project export for preset" in ln and "failed" in ln)]
    if rc != 0 or failed or not output.exists() or output.stat().st_size == 0:
        tail = "\n".join(text.splitlines()[-25:])
        fail(f"Godot exited {rc}; see {log_path}\n" + "\n".join(failed[:10])
             + "\n--- last lines ---\n" + tail)
    # The editor loads every exported scene to convert it, and runs scene
    # scripts that are not @tool as placeholders. Their errors are noise for
    # the build, but listed so a real one is not missed.
    warn = sorted({ln.strip() for ln in text.splitlines() if "SCRIPT ERROR" in ln})
    for ln in warn[:5]:
        log(f"  (editor, during export) {ln}")


# -- preset file editing ----------------------------------------------------

def cfg_str_array(items: list[str]) -> str:
    return "PackedStringArray(" + ", ".join('"%s"' % i.replace('"', '\\"') for i in items) + ")"


def set_preset_key(text: str, preset_name: str, key: str, value: str, options: bool = False) -> str:
    """Set `key=value` in the [preset.N] (or [preset.N.options]) section of the
    preset called preset_name. Adds the key when the section lacks it."""
    m = re.search(r'^\[preset\.(\d+)\]\n(?:(?!^\[).*\n)*?^name="%s"$' % re.escape(preset_name), text, re.M)
    if not m:
        fail(f"export_presets.cfg has no preset named '{preset_name}'")
    head = f"[preset.{m.group(1)}.options]" if options else f"[preset.{m.group(1)}]"
    start = text.index(head + "\n")
    end = text.find("\n[", start + len(head))
    end = len(text) if end < 0 else end
    section = text[start:end]
    line_re = re.compile(r"^%s=.*$" % re.escape(key), re.M)
    new_line = f"{key}={value}"
    if line_re.search(section):
        section = line_re.sub(lambda _m: new_line, section, count=1)
    else:
        section = section.rstrip("\n") + "\n" + new_line + "\n"
    return text[:start] + section + text[end:]


def next_preset_index(text: str) -> int:
    idx = [int(x) for x in re.findall(r"^\[preset\.(\d+)\]$", text, re.M)]
    return (max(idx) + 1) if idx else 0


def art_preset_block(index: int, name: str, files: list[str], exclude: list[str], include: str) -> str:
    return (
        f"\n[preset.{index}]\n\n"
        f'name="{name}"\n'
        'platform="Linux"\n'          # the platform only picks texture formats; a .pck is OS-neutral
        "runnable=false\n"
        "dedicated_server=false\n"
        'custom_features=""\n'
        'export_filter="resources"\n'
        f"export_files={cfg_str_array(['res://' + f for f in files])}\n"
        f'include_filter="{include}"\n'
        f'exclude_filter="{", ".join(exclude)}"\n'
        'export_path=""\n'
        "patches=PackedStringArray()\n"
        "encryption_include_filters=\"\"\nencryption_exclude_filters=\"\"\n"
        "seed=0\nencrypt_pck=false\nencrypt_directory=false\nscript_export_mode=2\n"
        f"\n[preset.{index}.options]\n\n"
        "texture_format/s3tc_bptc=true\ntexture_format/etc2_astc=false\n"
        'binary_format/architecture="x86_64"\n'
    )


def sync_game_filters() -> None:
    """Write GAME_EXCLUDE / GAME_INCLUDE into the committed game presets, so
    the editor's Project -> Export makes the same build. Permanent on purpose
    (unlike the version stamps and art presets, which last one build)."""
    old = PRESETS.read_text(encoding="utf-8")
    text = old
    for plat, (pname, _f) in GAME_PRESETS.items():
        excl = GAME_EXCLUDE + GAME_EXCLUDE_EXTRA.get(plat, [])
        text = set_preset_key(text, pname, "export_filter", '"all_resources"')
        text = set_preset_key(text, pname, "include_filter", '"%s"' % ", ".join(GAME_INCLUDE))
        text = set_preset_key(text, pname, "exclude_filter", '"%s"' % ", ".join(excl))
    if text != old:
        PRESETS.write_bytes(text.encode("utf-8"))
        log("export_presets.cfg: game filters updated to match this script (commit the change)")


# -- the art add-on ---------------------------------------------------------

def art_files_on_disk() -> list[str]:
    out: list[str] = []
    for root in ART_ROOTS:
        base = ROOT / root
        if not base.is_dir():
            continue
        for dp, dns, fns in os.walk(base):
            if ".gdignore" in fns:
                dns[:] = []
                continue
            for f in fns:
                rel = (Path(dp) / f).relative_to(ROOT).as_posix()
                out.append(rel)
    for _name, prefixes in ART_PACKS:
        for p in prefixes:
            if not p.endswith("/") and not p.endswith("*") and (ROOT / p).is_file():
                out.append(p)
    return sorted(set(out))


def is_resource(rel: str, on_disk: set[str]) -> bool:
    if rel.endswith(".import") or rel.endswith(".uid"):
        return False
    return rel + ".import" in on_disk or rel.rsplit(".", 1)[-1].lower() in RESOURCE_EXTS


def group_of(rel: str) -> str:
    best, best_len = "", -1
    for name, prefixes in ART_PACKS:
        for p in prefixes:
            if p.endswith("*"):
                hit = rel.startswith(p[:-1])
            else:
                hit = (p.endswith("/") and rel.startswith(p)) or rel == p
            if hit and len(p) > best_len:
                best, best_len = name, len(p)
    return best


def art_groups() -> dict[str, list[str]]:
    files = art_files_on_disk()
    on_disk = set(files)
    groups: dict[str, list[str]] = {name: [] for name, _ in ART_PACKS}
    for rel in files:
        if not is_resource(rel, on_disk):
            continue
        g = group_of(rel)
        if g:
            groups[g].append(rel)
    return groups


def art_exclude_for(group: str) -> list[str]:
    """res:// patterns for everything this pack must NOT carry: the other
    groups' art (a scene's dependencies on another pack's art stay in that
    pack) and the tracked game itself (it is in every game build)."""
    own = dict(ART_PACKS)[group]
    pats: set[str] = set()
    for name, prefixes in ART_PACKS:
        if name == group:
            continue
        for p in prefixes:
            if not p.endswith("/"):
                pats.add("res://" + p)
                continue
            # A folder of ours INSIDE p ("Imported Models/" round "Mars Aerial/",
            # "Soak Terrain/" round the camp components) keeps its way down;
            # everything else in p is the other group's.
            _exclude_around(p, [o for o in own if o.endswith("/") and o.startswith(p) and o != p], pats)
    for top in sorted(ROOT.iterdir()):
        if top.name.startswith(".") or top.name in ART_ROOTS or not top.is_dir() or top == UID_DIR:
            continue
        if top.name in ("scenes", "maps"):
            continue       # the bespoke map scenes live here; their tracked siblings are tiny
        pats.add(f"res://{top.name}/*")
    return sorted(pats)


def _exclude_around(p: str, keep: list[str], pats: set[str]) -> None:
    """Exclude folder p except the folders in `keep` (deeper than p): every
    sibling along the way down to each kept folder is excluded."""
    if not keep:
        pats.add("res://" + p + "*")
        return
    base = ROOT / p
    for child in sorted(base.iterdir()) if base.is_dir() else []:
        rel = child.relative_to(ROOT).as_posix() + ("/" if child.is_dir() else "")
        if any(o == rel for o in keep):
            continue
        inner = [o for o in keep if o.startswith(rel) and o != rel]
        if inner and child.is_dir():
            _exclude_around(rel, inner, pats)
            continue
        pats.add("res://" + rel + ("*" if child.is_dir() else ""))


def _model_files(files: list[str]) -> list[str]:
    return [f for f in files if f.rsplit(".", 1)[-1].lower() in MODEL_EXTS]


def _catalog_paths() -> list[tuple[str, str, str]]:
    """(id, label, res path) of every shipped ModelCatalog entry with a file."""
    src = (ROOT / "core" / "placed_models" / "model_catalog.gd").read_text(encoding="utf-8")
    out = []
    for m in re.finditer(r'\{"id":\s*"([^"]+)",\s*"label":\s*"([^"]*)",\s*"path":\s*"res://([^"]+)"', src):
        out.append((m.group(1), m.group(2), m.group(3)))
    return out


def _user_library() -> list[tuple[str, str]]:
    """The author's own imported models (user://models/catalog.json on this
    computer): never in a release."""
    appdata = os.environ.get("APPDATA", "")
    cat = Path(appdata) / "Godot" / "app_userdata" / "SIMbiogenesis" / "models" / "catalog.json"
    if not appdata or not cat.is_file():
        return []
    import json
    try:
        data = json.loads(cat.read_text(encoding="utf-8"))
    except Exception:
        return []
    ents = data.get("models", data) if isinstance(data, dict) else data
    if isinstance(ents, dict):
        ents = list(ents.values())
    return sorted((str(e.get("label", e.get("id", ""))), str(e.get("id", ""))) for e in ents if isinstance(e, dict))


def write_art_contents(out: Path, groups: dict[str, list[str]], built: list[str]) -> Path:
    """ART_CONTENTS.md: which model files each art pack carries, which groups
    this release left out, where every catalog model's file is, and the
    author's own library (which no release carries)."""
    lines = ["# What the art packs carry", ""]
    lines.append("The game zips carry no imported art. Each `simbiogenesis-art-<group>.pck` "
                 "carries the model files below (with their textures and materials).")
    lines.append("")
    for name, _ in ART_PACKS:
        models = _model_files(groups.get(name, []))
        state = "in this release" if name in built else "NOT in this release"
        lines.append(f"## {name} ({state}) - {len(models)} model files")
        lines.append("")
        by_dir: dict[str, list[str]] = {}
        for f in models:
            d, _, base = f.rpartition("/")
            by_dir.setdefault(d, []).append(base)
        for d in sorted(by_dir):
            lines.append(f"- `{d}/`: " + ", ".join(sorted(by_dir[d])))
        lines.append("")
    lines.append("## Library models and where their files ship")
    lines.append("")
    lines.append("| Catalog model | File | Ships in |")
    lines.append("|---|---|---|")
    for mid, label, rel in _catalog_paths():
        g = group_of(rel)
        where = (f"{g} pack" if g in built else f"{g} pack (not in this release)") if g else "the game zip"
        if g == "" and not (ROOT / rel).exists():
            where = "nowhere (file missing)"
        lines.append(f"| {label} (`{mid}`) | `{rel}` | {where} |")
    lines.append("")
    lib = _user_library()
    lines.append(f"## Your own library ({len(lib)} models) - never in a release")
    lines.append("")
    lines.append("These live in `user://models/` on the computer that imported them. They travel only "
                 "inside a world shared with **Share...** (a `.simpack.zip`), which vendors the models "
                 "its worlds use.")
    lines.append("")
    for label, mid in lib:
        lines.append(f"- {label} (`{mid}`)")
    path = out / "ART_CONTENTS.md"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


UID_DIR = ROOT / "art_uids"
_UID_RE = re.compile(r'uid="(uid://[a-z0-9]+)"')


def write_uid_list(group: str, files: list[str]) -> str:
    """The uid -> path table for one art pack. Godot does not merge a mounted
    pack's uid cache, so without it every uid:// reference to the art falls
    back to its text path with a warning. ArtPackMount registers this file.
    Returns its res:// path (temporary; removed after the build)."""
    lines = []
    for rel in files:
        src = ROOT / rel
        meta = Path(str(src) + ".import") if (ROOT / (rel + ".import")).exists() else src
        try:
            with open(meta, encoding="utf-8", errors="replace") as fh:
                head = fh.read(4096)
        except OSError:
            continue
        m = _UID_RE.search(head)
        if m:
            lines.append(f"{m.group(1)}\tres://{rel}\n")
    UID_DIR.mkdir(exist_ok=True)
    (UID_DIR / f"{group}.txt").write_text("".join(lines), encoding="utf-8")
    return f"res://art_uids/{group}.txt"


# -- packaging --------------------------------------------------------------

def zip_dir(src_dir: Path, zip_path: Path) -> None:
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
        for p in sorted(src_dir.rglob("*")):
            if not p.is_file():
                continue
            info = zipfile.ZipInfo.from_file(p, p.relative_to(src_dir).as_posix())
            info.compress_type = zipfile.ZIP_DEFLATED
            # The Linux binary must stay executable when unzipped.
            info.external_attr = (0o755 if p.suffix == ".x86_64" else 0o644) << 16
            with open(p, "rb") as src, z.open(info, "w", force_zip64=True) as dst:
                shutil.copyfileobj(src, dst, 1 << 20)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def numeric_version(v: str) -> str:
    nums = [int(x) for x in re.findall(r"\d+", v)][:4]
    nums += [0] * (4 - len(nums))
    return ".".join(str(n) for n in nums)


def project_version() -> str:
    m = re.search(r'^config/version="([^"]*)"', PROJECT.read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else "0.0.0"


def git_commit() -> str:
    try:
        return subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot", default=os.environ.get("SIMBIO_GODOT", DEFAULT_GODOT))
    ap.add_argument("--version", default="", help="release version (default: project.godot config/version)")
    ap.add_argument("--platforms", default="windows,macos,linux")
    ap.add_argument("--no-art", action="store_true", help="skip the art add-on")
    ap.add_argument("--art-only", action="store_true", help="only build the art add-on")
    ap.add_argument("--art-groups", default="", help="comma list of art groups to build "
                    "(default: %s; also mars, soak)" % ",".join(DEFAULT_ART_GROUPS))
    ap.add_argument("--debug", action="store_true", help="export debug builds (console + asserts)")
    ap.add_argument("--out", default="", help="output folder (default release/<version>)")
    args = ap.parse_args()

    if not Path(args.godot).exists() and shutil.which(args.godot) is None:
        fail(f"Godot not found at {args.godot} (pass --godot or set SIMBIO_GODOT)")
    gver = godot_version(args.godot)
    tdir = templates_dir(gver)
    if not args.art_only and not tdir.is_dir():          # a .pck needs no template
        fail(f"export templates for Godot {gver} are not installed ({tdir}).\n"
             f"  Run: python tools/release/install_export_templates.py --godot \"{args.godot}\"")
    version = args.version or project_version()
    out = Path(args.out) if args.out else ROOT / "release" / version
    out.mkdir(parents=True, exist_ok=True)
    for d in (ROOT / "release", out):                # Godot must never scan the outputs
        d.mkdir(parents=True, exist_ok=True)
        (d / ".gdignore").touch()
    logs = out / "logs"
    logs.mkdir(exist_ok=True)
    platforms = [] if args.art_only else [p.strip() for p in args.platforms.split(",") if p.strip()]
    for p in platforms:
        if p not in GAME_PRESETS:
            fail(f"unknown platform '{p}' (choose from {', '.join(GAME_PRESETS)})")
    log(f"SIMbiogenesis {version} ({git_commit()}) with Godot {gver} -> {out}")

    sync_game_filters()
    presets_orig = PRESETS.read_bytes()
    project_orig = PROJECT.read_bytes()
    built: list[Path] = []
    try:
        # Version stamps, in force for this build only.
        ptxt = project_orig.decode("utf-8")
        if re.search(r'^config/version=', ptxt, re.M):
            ptxt = re.sub(r'^config/version=.*$', f'config/version="{version}"', ptxt, count=1, flags=re.M)
        else:
            ptxt = ptxt.replace('config/name="SIMbiogenesis"\n', f'config/name="SIMbiogenesis"\nconfig/version="{version}"\n', 1)
        PROJECT.write_bytes(ptxt.encode("utf-8"))
        text = presets_orig.decode("utf-8")
        nv = numeric_version(version)
        text = set_preset_key(text, "Windows Desktop", "application/file_version", f'"{nv}"', True)
        text = set_preset_key(text, "Windows Desktop", "application/product_version", f'"{nv}"', True)
        text = set_preset_key(text, "macOS", "application/short_version", f'"{version}"', True)
        text = set_preset_key(text, "macOS", "application/version", f'"{version}"', True)

        art_jobs: list[tuple[str, str]] = []
        if not args.no_art:
            groups = art_groups()
            want = [g.strip() for g in args.art_groups.split(",") if g.strip()] or list(DEFAULT_ART_GROUPS)
            for name in want:
                files = groups.get(name, [])
                if not files:
                    log(f"art group '{name}': no art on disk, skipped")
                    continue
                pname = f"Art add-on: {name}"
                excl = art_exclude_for(name)
                uids = write_uid_list(name, files)
                text += art_preset_block(next_preset_index(text), pname, files, excl, uids)
                art_jobs.append((name, pname))
        PRESETS.write_bytes(text.encode("utf-8"))

        mode = "--export-debug" if args.debug else "--export-release"
        for plat in platforms:
            pname, fname = GAME_PRESETS[plat]
            stage = out / "stage" / plat
            if stage.exists():
                shutil.rmtree(stage)
            stage.mkdir(parents=True)
            run_godot(args.godot, [mode, pname, str(stage / fname)], logs / f"export_{plat}.log", stage / fname)
            zip_path = out / f"SIMbiogenesis-{version}-{plat}.zip"
            if plat == "macos":
                shutil.move(str(stage / fname), zip_path)    # Godot writes the .app as a zip already
            else:
                zip_dir(stage, zip_path)
            built.append(zip_path)
            log(f"{zip_path.name}: {zip_path.stat().st_size / 2**20:.0f} MB")

        if not args.no_art:
            log(f"{write_art_contents(out, groups, [n for n, _ in art_jobs]).name}: what each pack carries")
        for name, pname in art_jobs:
            pck = out / f"simbiogenesis-art-{name}.pck"
            run_godot(args.godot, ["--export-pack", pname, str(pck)], logs / f"art_{name}.log", pck)
            built.append(pck)
            log(f"{pck.name}: {pck.stat().st_size / 2**20:.0f} MB")
    finally:
        PRESETS.write_bytes(presets_orig)
        PROJECT.write_bytes(project_orig)
        shutil.rmtree(UID_DIR, ignore_errors=True)

    too_big = [p for p in built if p.stat().st_size > SAFE_LIMIT]
    sums = out / "SHA256SUMS.txt"
    present = sorted(p for p in out.iterdir() if p.is_file() and p.suffix in (".zip", ".pck"))
    sums.write_text("".join(f"{sha256(p)}  {p.name}\n" for p in present), encoding="utf-8")
    notes_src = ROOT / "tools" / "release" / "RELEASE_NOTES_TEMPLATE.md"
    if notes_src.exists():
        notes = notes_src.read_text(encoding="utf-8").replace("{version}", version).replace("{commit}", git_commit())
        (out / "RELEASE_NOTES.md").write_text(notes, encoding="utf-8")
    shutil.rmtree(out / "stage", ignore_errors=True)
    for p in present:
        log(f"  {p.stat().st_size / 2**20:8.0f} MB  {p.name}")
    if too_big:
        fail("over GitHub's 2 GiB per-file limit (split the group in ART_PACKS): "
             + ", ".join(p.name for p in too_big))
    log(f"done. Upload with:\n  gh release create v{version} --title \"SIMbiogenesis {version}\" "
        f"--notes-file \"{out / 'RELEASE_NOTES.md'}\" " + " ".join(f'"{p}"' for p in present))


if __name__ == "__main__":
    main()
