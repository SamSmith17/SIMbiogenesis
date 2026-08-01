# Phase 3 — Asset packaging (lite repo vs full Patreon build)

> **SUPERSEDED — historical archive (April 2026).** This documents a completed
> repo-hygiene / beta-readiness effort and is kept for provenance only. Its
> figures describe a 107-file, 7-autoload project with no `addons/`; the project
> is now ~540 `.gd` files and 33 autoloads. For current guidance see
> [`ARCHITECTURE.md`](ARCHITECTURE.md) (structure + debt backlog) and
> [`CLAUDE.md`](CLAUDE.md) (features + validation), which win on any conflict.

**Goal:** Share **essential code** on GitHub (small clone) while Patreon / private testers get **playable builds** or a **single asset archive** that drops into the same folder layout.

This project is **not** yet set up to open `scenes/maps/mars_aerial.tscn` with zero art: maps reference `res://` models and textures. A **lite clone** expects either (a) you add the asset pack to the project root, or (b) future work adds stub maps (Phase 4–5).

---

## 1. Three tiers

| Tier | What it is | Typical use |
|------|------------|----------------|
| **A — Source lite** | Scripts, shaders, small `data/`, UI scenes, `project.godot`, docs | Public GitHub |
| **B — Map data (medium)** | Terrain meshes + materials at repo root, HDR/stellarium sky assets, linkage GLTFs, etc. | Optional in Git or in asset pack |
| **C — Heavy art** | `Imported Models/`, large FBX trees, player mesh folder | Patreon zip / LFS / not in public Git |

---

## 2. Folders: full build vs GitHub lite

**Recommended to omit from a public “lite” Git repo** (distribute via Patreon / Drive / separate private repo):

| Path | Role |
|------|------|
| [`Imported Models/`](Imported%20Models/) | Most GLB/FBX scenes, props, trees, Mars aerial, fire extinguisher model, etc. |
| [`StarShade FBX/`](StarShade%20FBX/) | Starshade FBX/GLB hierarchy |
| [`Starshade Pretty Version/`](Starshade%20Pretty%20Version/) | FBX variant |
| [`Player Character/`](Player%20Character/) | Player FBX mesh + animations (`player.tscn`, `player.gd`) |
| [`Wood034_1K-JPG/`](Wood034_1K-JPG/) | Optional PBR set (if present) |
| [`Metal051C_1K-JPG/`](Metal051C_1K-JPG/) | Optional PBR set (if present) |

**`Imported Models/` is required** for most referenced scenes: [`player_tools/fire_extinguisher_pickup.tscn`](player_tools/fire_extinguisher_pickup.tscn), [`scenes/gameplay/Tree.tscn`](scenes/gameplay/Tree.tscn), nested scenes under [`Imported Models/`](Imported%20Models/), etc.

**Smaller/frequent root files** used by maps (examples — not exhaustive):

- [`scenes/gameplay/Terrain.tscn`](scenes/gameplay/Terrain.tscn): `10m_-115.74_33.76_tile_1_1.obj`, [`Ground088_1K-JPG.tres`](Ground088_1K-JPG.tres) + `Ground088_1K-JPG_*.jpg`
- [`scenes/maps/mars_aerial.tscn`](scenes/maps/mars_aerial.tscn): many `res://Imported Models/...`, `res://StarShade FBX/...`, `res://Starshade Pretty Version...`, root `Starshade Pretty Version - 18 panel version no rails.glb`, `Mars 2026 New.glb` / textures, `LinkageLab_Export_*.gltf`, etc.
- [`main- maybe unstable.tscn`](main-%20maybe%20unstable.tscn): [`Imported Models/Soak Terrain/`](Imported%20Models/), [`Imported Models/Trees/`](Imported%20Models/), [`Imported Models/StarShades/`](Imported%20Models/), plus Starshade FBX folder scene

[`mars_2026_expanded.tscn`](mars_2026_expanded.tscn): `Imported Models/Mars 2026 expanded.glb`.

[`burnable_component.gd`](crisis_events/fire/burnable_component.gd): default texture under `Imported Models/Mars Aerial/`.

---

## 3. Scene → dependency cheat sheet

Use this when deciding what to ship in **Sky-assets.zip**.

| Entry / map scene | Depends heavily on |
|--------------------|---------------------|
| [`scenes/maps/mars_aerial.tscn`](scenes/maps/mars_aerial.tscn) | `Imported Models/**`, `StarShade FBX/**`, `Starshade Pretty Version/**`, root starshade/Mars GLBs + texture sprawl, `scenes/gameplay/Terrain.tscn` chain |
| [`main- maybe unstable.tscn`](main-%20maybe%20unstable.tscn) | `Imported Models/` (Soak, Trees, StarShades, buses, appa, euc, …), `Starshade Pretty Version/` |
| [`main_old_backup.tscn`](main_old_backup.tscn) | Similar to `scenes/maps/mars_aerial.tscn` |
| [`player.tscn`](player.tscn) | `Player Character/*.fbx` |
| [`scenes/gameplay/Tree.tscn`](scenes/gameplay/Tree.tscn) | `Imported Models/Trees/` |
| Fire extinguisher scenes | `Imported Models/Fire Extinguisher/` |

---

## 4. Patreon / private **asset pack** workflow (recommended)

1. On your machine, with a **known-good full project**, zip the Tier **C** folders (and optionally **B** root blobs) preserving paths from the directory that contains `project.godot`.
2. Name e.g. `Sky-WIP-assets-v1.zip` and host on Patreon / cloud.
3. Contributors: clone **lite** repo → extract asset zip **into the same folder** as `project.godot` so `Imported Models` sits beside `project.godot`.
4. Open in **Godot 4.6**; let the editor reimport (`.godot/` is local-only per clone).

No code changes required.

---

## 5. `*.import` policy

Current [`.gitignore`](.gitignore) ignores **`*.import`**.

| Approach | Pros | Cons |
|--------|------|------|
| **Ignore `*.import` (current)** | Smaller repo, fewer merge conflicts | First open on a new PC reimports; slight “first load” cost |
| **Commit `*.import`** | More reproducible imports across clones | Noisy diffs, binary-ish churn |

**Recommendation:** keep ignoring `*.import` for the public lite repo; pin **Godot 4.6** in README; document reimport in onboarding.

---

## 6. Optional: Git LFS

For a **single monorepo** that still tracks binaries, use Git LFS instead of excluding folders. See [`.gitattributes.lfs.example`](.gitattributes.lfs.example): merge the contents into [`.gitattributes`](.gitattributes) after `git lfs install`, then migrate existing files if needed.

Use **either** (asset zip + thin Git) **or** (LFS monorepo), not both blindly — LFS still costs bandwidth and host limits.

---

## 7. Optional: lite repo `.gitignore`

See the **commented block** at the bottom of [`.gitignore`](.gitignore). Uncomment the lines for a clone that should never commit heavy trees. You still need a strategy for **root-level** `.glb/.jpg/.obj` files (selective `git add`, or expand ignore patterns once you freeze a lite file list).

---

## 8. Placeholder / stub maps (later)

Opening the simulator **without** Tier C assets will show missing resources for `scenes/maps/mars_aerial.tscn` / player. A **minimal dev scene** (flat ground + sun + UI only) is a good Phase 4–5 task; not required to freeze the asset-pack strategy above.

---

## Phase 3 checkpoint

- [x] Tiers A/B/C defined  
- [x] Folder list + scene dependency matrix documented  
- [x] Patreon zip workflow documented  
- [x] `*.import` policy recorded  
- [x] Optional LFS + optional `.gitignore` lite block  
- [ ] Stub map for zero-art open (deferred to Phase 4/5)
