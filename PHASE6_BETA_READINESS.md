# Phase 6 — Patreon beta, exports, and stability

**Status:** implementation log for private beta / WIP patron builds.  
**Depends on:** Phase 5 (map select, `scene_path` in saves, return-to-menu).

---

## Scope

1. **Documentation** — How patrons run the game, where saves/config live, and how to produce binaries.
2. **Exports** — Keep presets portable under `build/`; document Godot version and template requirement.
3. **Light stability** — Invalidate stale scene references after `change_scene_to_file` (autoload caches fixed in SimMode/AutomationEngine; `player_health` refreshes dead `Main` links).
4. **Deeper performance** — Deferred to **Phase 7** (profiler-driven; avoid risky `_process` refactors in Phase 6).

---

## Run from source

- **Engine:** Godot **4.6** (Forward Plus), same as `project.godot` → `config/features`.
- **Play:** Press Play with `run/main_scene` = `res://scenes/ui/map_select/map_select.tscn` (map picker).
- **Direct map test:** Open `scenes/maps/mars_aerial.tscn` or `scenes/maps/soak_festival_2026.tscn` in the editor and run the **current** scene (F6) — no map select.

---

## Export checklist (maintainer)

1. Install **export templates** matching your editor build (Editor → Manage Export Templates).
2. **Project → Export…** — presets: *Windows Desktop*, *macOS*, *Linux* (see `export_presets.cfg`).
3. Outputs (relative to project root):
   - `build/SIMbiogenesis.exe` — Windows x86_64, embedded PCK.
   - `build/SIMbiogenesis.app` — macOS universal (codesign / notarize before public distribution).
   - `build/SIMbiogenesis.x86_64` — Linux x86_64.
4. **macOS:** Set `application/bundle_identifier` and signing identity in the preset before shipping outside ad-hoc local tests; patron zips often skip notarization but should still avoid Gatekeeper surprises where possible.
5. **Smoke test each platform:** Map select → each map → Timeline 💾 save/load → map button → back → reload Mars; optional `Continue` from menu.

---

## Patron / tester quick reference

| Topic | Location |
|--------|-----------|
| Saves | `user://saves/` (see `core/save_system.gd`) |
| HA / UISP / calibration | `LOCAL_CONFIG.md`, `config-templates/` |
| Lite clone vs full art | `PHASE3_ASSET_PACK.md` |
| Module toggles | `gameplay/gameplay_rules.gd`, `ScenarioConfig` on `main.gd` |

**Secrets:** Never commit real `user://` configs or tokens; templates only in repo.

---

## Phase 7

See **[`PHASE7_PERFORMANCE.md`](PHASE7_PERFORMANCE.md)** — profiler workflow, soak matrix, and implemented low-risk throttles (`SimMode`, `HealthUI`).

---

## Completion notes (2026-04-29)

- Added this doc; README *Beta builds & map flow* + roadmap link; PHASE1 inventory main scene row updated.
- `player_health.gd`: clear invalid `_main_node` and re-resolve each frame when freed.
- macOS preset: placeholder `application/bundle_identifier` for export dialog (replace before App Store / wide distribution).
