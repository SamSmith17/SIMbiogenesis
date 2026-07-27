# SCAD library — parametric hardware store parts

Local, curated OpenSCAD generators the in-game **Parametric Hardware Store**
(press **H** in a loaded map) renders on demand. Layout mirrors the source
Thingiverse export: `<Category>/<project>/[files/]part.scad` (sibling `.scad`
travel together so `include <>`s resolve). This whole folder is gitignored except
these docs — it's local like the asset pack (`../ASSETS.md`); the committed record
is the attribution ledger in `../CREDITS.md` / `../credits/credits.json`.

## Rebuild from a source folder

```
# 1. Copy .scad + parse licenses/readmes from an external part library:
Godot.exe.exe --headless --path . --script core/scad/scad_import.gd -- \
    --src="C:/Users/<you>/Documents/OpenSCAD Part Library"

# 2. Build the catalog (+ optional validation renders, bounded):
Godot.exe.exe --headless --path . --script core/scad/scad_ingest.gd
Godot.exe.exe --headless --path . --script core/scad/scad_ingest.gd -- --render-budget=600
```

Generated (also gitignored): `catalog.json` (per-part Customizer schema + license
+ readme description + `ready`/`review`/`usable-dev`/`quarantined` verdict, read
by the store UI) and `part_docs.json` (category + description + license per file).
The importer writes real credits entries into `../credits/credits.json`.

## Current seed (from OpenSCAD Part Library, 2026-07)

61 parts across 48 categories. License triage:
- **16 ready** — permissive (CC-BY / CC-BY-SA / CC0), parametric, cleared.
- **11 review** — **CC-BY-NC / -NC-SA / -NC-ND (restricted)**. NC blocks commercial
  forks; ND forbids the modification a customizer performs. A licensing decision
  is required before shipping these — they're usable in dev only.
- **34 pending** — folders whose license doc was absent or an empty template;
  confirm each on Thingiverse before shipping.

**No part ships until its license is confirmed** (and isn't NC/ND). STLs and
images from the source folder are intentionally not imported.
