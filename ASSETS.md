# Local asset pack (not in Git)

This repo tracks **code, UI, and small shared data**. Bespoke map art (SOAK Festival, Mars aerial, player mesh, Starshade FBX trees) lives in a **local asset pack** beside `project.godot`. Git ignores those paths so clones stay small.

## Quick start (full maps on your machine)

If you already have the folders below in this directory, open the project in **Godot 4.6** and play — no extra steps.

Required for SOAK / Mars / player:

| Path | Role |
|------|------|
| `Imported Models/` | Props, terrain GLBs, trees, Mars aerial art |
| `StarShade FBX/` | Starshade rig / export hierarchy |
| `Starshade Pretty Version/` | Alternate Starshade FBX set |
| `Player Character/` | Player FBX mesh + animations |
| Root `10m_*.obj` | Mars terrain tiles (see `scenes/gameplay/Terrain.tscn`) |
| Root `Mars *.glb`, `Mars*.jpg` | Mars aerial scene dependencies |

Optional PBR sets: `Wood034_1K-JPG/`, `Metal051C_1K-JPG/`.

## Without the asset pack

The simulator still runs:

- **Launch hub** boots by default (`project.godot` → unified energy-zone map + saved worlds list).
- **Create map here** builds any site via `generated_location.tscn` + terrain fetch.
- SOAK / Mars entries appear in **Your maps** only when you add the local scene files and MapDefinition resources (see below).

## Local custom maps (SOAK / Mars)

The public GitHub tree ships **`generated_location.tscn`** only. Bespoke SOAK and Mars scenes stay **gitignored** on your machine at the same paths as always:

| Local file (gitignored) | MapDefinition (gitignored) |
|-------------------------|----------------------------|
| `scenes/maps/soak_festival_2026.tscn` | `maps/soak_camp_map.tres` |
| `scenes/maps/mars_aerial.tscn` | `maps/mars_aerial_map.tres` |

**After a fresh clone:** copy [`maps/examples/soak_camp_map.example.tres`](maps/examples/soak_camp_map.example.tres) → `maps/soak_camp_map.tres` (and the Mars example likewise), restore your scene files from backup, and ensure `ResourceLoader.exists()` succeeds for each `scene_path`. The launch hub lists only maps whose scene files are present.

Legacy root [`main.tscn`](main.tscn) is also gitignored (slim Mars fallback for local exports).

## Restore from backup / zip

1. Clone or copy this repo to a folder containing `project.godot`.
2. Extract (or copy) the asset pack **into the same folder** so `Imported Models/` sits next to `project.godot`.
3. Delete `.godot/` if you copied from another machine, then open in Godot 4.6 and let it reimport.

See also [PHASE3_ASSET_PACK.md](PHASE3_ASSET_PACK.md) for tier A/B/C breakdown and Patreon zip workflow.
