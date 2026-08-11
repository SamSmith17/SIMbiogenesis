# SIMbiogenesis — UX/UI Streamlining + Vegetation Realism Plan

## Context

The project is functionally rich and technically solid (terrain-from-lat/lon, OSM veg/water/solar, node-graph electrical sim, HA twin, NLE timeline) but has three quality gaps:

1. **UI look/consistency**: ~28k lines of UI code with **no central Theme** — the same color palette is duplicated (with drift) in `timeline_ui.gd:14-24`, `system_graph_view.gd:9-17`, `inspector_panel.gd:9-16`, `graph_canvas.gd:9-23`; 4 different "error red" shades across solar/health/EUC UIs; ~200 `add_theme_*_override` calls; inline `StyleBoxFlat` construction everywhere; ad-hoc CanvasLayer z-order numbers.
2. **UX gaps**: zero onboarding/help (25+ keybinds discoverable only by trial), **all failures silent** to the player (network/quota/save errors are console `push_warning` only), graphics settings not persisted across restarts, game is nearly silent (no ambience, no UI sounds, no volume control).
3. **Vegetation realism**: 100% procedural ~128–160px FastNoiseLite textures (blobby up close), no normal maps anywhere, additive fake-SSS glow, stippled dither alpha, no far-tree impostor tier (full card geometry + shadows to 900–2200 m), and **terrain is effectively unlit** (`terrain_detail.gdshader` = `specular_disabled`, drape-only). Also: **project actually runs GL Compatibility** (`project.godot:278`) despite CLAUDE.md saying Forward+ — TAA is set but dead, and the settings panel's SSAO/SSIL/SDFGI toggles do nothing.

**User decisions (locked):** include Forward+ switch; allow bundled CC0 texture assets; Theme system + visible polish only (do NOT split solar_ui.gd/system_graph_view.gd/timeline_ui.gd); onboarding + audio both in scope.

**Plan shape:** 13 small phases, easiest wins → most comprehensive, each independently shippable. Most are sized for a Composer/Haiku-class model; **3 phases flagged as needing a strong model** (P9, P11, P13) with reasons.

---

## Standard verification suite — "[SUITE]"

Run from repo root with `C:\Users\notsa\Downloads\Godot\Godot.exe.exe`:

```
--headless --path . --import                       # only after new class_name scripts
--headless --path . --quit-after 120
--headless --path . --quit-after 120 res://scenes/maps/mars_aerial.tscn
--headless --path . --script power_system/sources/source_physics_selftest.gd
--headless --path . --script core/terrain/terrain_selftest.gd
--headless --path . --script system_graph/graph_electrical_selftest.gd
--headless --path . --script vegetation/vegetation_selftest.gd
```

Compare boot errors against CLAUDE.md "Known pre-existing runtime errors". Gotchas: headless renames `addons/**/~lib*.dll` → `.TMP` (git checkout + delete TMPs); never run headless with the Godot editor open; never rename UILayer children (node-name lookups are load-bearing).

---

## Phase 1 — UITheme foundation ⚙ Composer-class

**Goal:** Single source of truth for palette, status colors, StyleBox factories, font scale, and CanvasLayer z-order. Pure additive — no existing UI touched.

**Files:** NEW `scenes/ui/ui_theme.gd` (`class_name UITheme`); one paragraph in `CLAUDE.md`.

**Approach:** Canonical palette copied from `timeline_ui.gd:14-24` (C_BG/C_PANEL/C_BORDER/C_PRIMARY #22d3ee/C_AMBER/C_TEXT…, resolving the 0.97-vs-1.0 alpha drift). One canonical `C_OK`/`C_WARN`/`C_ERROR`/`C_INFO` (currently 4 reds: `solar_ui.gd:3505`, `health_ui.gd:31`, `euc_ui.gd:79`). Static factories `panel_style()/card_style()/button_style(state)/chip_style(color)` extracted from the common inline pattern in `timeline_settings_panel.gd`. Layer consts: `LAYER_HUD=10, LAYER_PANEL=30, LAYER_MODAL=50` (matches `save_load_ui.gd:32`), `LAYER_TOAST=90, LAYER_LOAD_OVERLAY=100`. Font scale `FONT_XS=11…FONT_XL=20`.

**Verify:** `--import` then [SUITE]; zero new boot errors.

## Phase 2 — Mechanical palette migration ⚙ Composer-class

**Goal:** Kill duplicated const blocks + the 4-reds problem; consistent status colors everywhere.

**Files (7):** `scenes/ui/timeline_ui.gd`, `system_graph/system_graph_view.gd`, `system_graph/inspector_panel.gd`, `system_graph/graph_canvas.gd`, `scenes/ui/solar_ui.gd` (status-color literals only), `scenes/ui/health_ui.gd`, `scenes/ui/euc_ui.gd`.

**Approach:** Keep local const *names*, redirect values: `const C_BG := UITheme.C_BG` — the ~200 usage sites don't change. Replace ad-hoc red/green/amber literals in status paths with `UITheme.C_ERROR` etc. Do NOT touch `graph_canvas.gd` PORT_COLORS/NODE_BORDER_COLORS (semantic registries, not chrome).

**Verify:** [SUITE] (graph selftest matters). Manual: G-panel + timeline look identical; low-battery and destroyed-controller reds now match.

## Phase 3 — Toast/notification system + error wiring ⚙ Composer-class

**Goal:** Reusable HUD toasts; silent failures become user-visible.

**Files (5):** NEW `scenes/ui/toast_ui.gd` (CanvasLayer at `UITheme.LAYER_TOAST`); `main.gd` (instance as UILayer sibling "ToastUI" + `show_toast()` delegate); `core/terrain/terrain_loader.gd` (quota-exhausted / flat-fallback / OSM-failure branches); `core/save_system.gd` (save/load failure paths); ToastUI itself connects existing `weather_fetch_failed`/`elevation_failed`/`imagery_failed` autoload signals in its `_ready()` (services untouched — matches project convention of code-wired signals).

**Approach:** Visual style borrowed from `terrain_load_overlay.gd` compact bar via UITheme. Bottom-right stack above the timeline — use `UiScreenLayout.timeline_stack_height()` (`scenes/ui/ui_screen_layout.gd`). API `show_toast(text, level=INFO, duration=5.0)`, max 4 stacked, tween fade, `MOUSE_FILTER_IGNORE`.

**Verify:** [SUITE]. Manual: load a location map offline → visible "Elevation unavailable — using cached/flat terrain" toast.

## Phase 4 — Graphics settings persistence ⚙ Composer-class — DONE (scope revised)

**Discovery during implementation:** the premise "graphics quality changes not persisted" was stale. `scenes/ui/sim_settings_controller.gd` already had a complete `persist_settings()`/`_load_persisted_settings()` pair writing `user://sim_settings.cfg`, covering shadow_quality, graphics_quality, SSAO/SSIL/SDFGI/volumetric fog, tonemap mode/exposure/white, fog/sun/moon knobs — `persist_settings()` fires on `timeline_settings_panel.gd`'s `close()`, and load runs automatically via `_initialize_sim_defaults()` on boot. Verified round-trip correctness with a headless script (toggle → persist → reload from disk → values match).

**Actual gap found:** `persist_settings()` only had one caller (settings-panel `close()`). A player who changes a setting and quits without closing that panel first — OS titlebar X / Alt+F4, or the in-game "Quit" button in `location_picker/location_picker_ui.gd:_on_quit_pressed()` — lost the change, since neither exit path called it.

**Fix applied:**
- `scenes/ui/sim_settings_controller.gd`: added `_notification(what)` handling `NOTIFICATION_WM_CLOSE_REQUEST` → `persist_settings()`, so the OS window-close path is covered (autoloads receive this notification via root propagation even though `get_tree().quit()` itself does not).
- `location_picker/location_picker_ui.gd:_on_quit_pressed()`: persists via `SimSettingsController` before calling `get_tree().quit()`.

**Verify:** [SUITE] all green, no new boot errors vs. the known baseline; headless script confirmed `_notification(NOTIFICATION_WM_CLOSE_REQUEST)` on the autoload writes `ssao_enabled=false` to `user://sim_settings.cfg` without an explicit `persist_settings()` call.

## Phase 5 — Help overlay + first-run hints ⚙ Composer-class — DONE

**Goal:** F1 keybind/concepts overlay; auto-show on first boot; contextual hint toasts.

**Built:** `project.godot` adds `toggle_help` (F1, physical_keycode 4194332 — pulled from the running engine, not guessed); NEW `scenes/ui/help_overlay_ui.gd` (`HelpOverlayUI`, `UITheme.LAYER_MODAL`) with 21 curated actions across Movement/Interaction/Panels/Time & Menus plus a short static Tips list; `main.gd` instances it under `UILayer` (mirrors `_setup_toast_ui()`), wires `_maybe_show_first_run_help()` in `_ready()`, and queues 3 staggered hint toasts via `ToastUI` on first run.

**Key labels:** read live from `InputMap.action_get_events()` + `OS.get_keycode_string()` (not hand-copied), falling back to `interaction_prompt_ui.gd`'s existing `KEYBOARD_LABELS`/`CONTROLLER_LABELS` dicts (via `preload(...).DICT_NAME`, not duplicated) for the ~14 actions it already curates — so it stays accurate if a rebind system ever lands.

**First-run gate:** since neither default map (`soak_festival_2026`/`mars_aerial`) has a `TerrainLoader` node — that only exists under the generated-location shell — the gate polls for a `TerrainLoadOverlay` child under `UILayer` every 0.5s (capped at 120 tries) and proceeds the instant it's absent, so default maps show help immediately and generated maps wait out the load. Flag: `user://ui_prefs.cfg` `[help] first_run_seen` (file already existed for timeline units/track prefs — new section, no collision).

**Verify:** [SUITE] all green, no new boot errors vs. baseline. Functional headless script confirmed: `toggle()` opens/closes + correctly registers/releases a `CursorController` modal; keyboard labels resolve correctly (`system_graph_toggle`→"G", `interact`→"O", the latter from the curated dict); first-run call with the flag cleared auto-opens the overlay and persists the flag; a second call with the flag set is a no-op. (First test draft had a false failure — it forgot boot's own `_ready()` already auto-opens the overlay when the flag is absent, colliding with the test's manual-toggle assumptions; fixed by pre-seeding the flag before boot.)

## Phase 6a — UI visual polish wave (part 1) ⚙ Composer-class — DONE

**Goal:** Consistent chrome on remaining surfaces: shared StyleBox factories, unified `UITheme.LAYER_*` z-order, kill remaining exact-duplicate palettes.

**Done (8 files):**
- `scenes/ui/save_load_ui.gd` — was using the **stock engine gray theme** (a real, visible inconsistency vs. every other panel's dark navy/cyan chrome). Added `_style_ui()` applying `UITheme.panel_style()` + `UITheme.style_button()` to all 5 buttons + text colors; `layer` → `UITheme.LAYER_MODAL`. Also fixed `show_load_message(text, success)` — the `success` param was previously received as `_success` and silently dropped, so save/load outcomes never got a status color; now routes to `UITheme.C_OK`/`C_ERROR` and all internal status-line writes (`_do_save_slot`, delete confirm/empty-slot) go through it for one consistent code path.
- `scenes/ui/terrain_load_overlay.gd` — local `C_BG/C_TEXT/C_MUTED/C_ACCENT/C_OK` (near-exact duplicates of the canonical palette) → `UITheme.*`; `layer` → `UITheme.LAYER_LOAD_OVERLAY`. Also fixed a real drift bug: its own `TIMELINE_CLEARANCE := 162.0` no longer matched `UiScreenLayout.timeline_stack_height()` (178.0, a 16px gap) — replaced with a direct call to the canonical helper so the compact loading bar sits correctly relative to the timeline.
- `scenes/ui/timeline_settings_panel.gd` — local `C_PANEL/C_BORDER/C_PRIMARY/C_TEXT/C_TEXT_S` (exact duplicates) → `UITheme.*`. Left the bespoke `psb`/`tab_panel_sb` StyleBoxFlat construction in place (different corner radius/shadow/margins than the generic factories — swapping to `panel_style()`/`card_style()` would add unintended content-margin padding around the TabContainer; not "visually equivalent" so out of scope per the phase's own guardrail).
- `scenes/ui/crosshair_ui.gd`, `scenes/ui/conduit_route_ui.gd` (also had an exact-duplicate palette, fixed), `scenes/ui/health_ui.gd`, `scenes/ui/mars_college_credits_ui.gd` — `layer =` literals → `UITheme.LAYER_*`. `conduit_route_ui.gd` needs to render above the crosshair, so it's `UITheme.LAYER_WORLD_HINT + 1` (documented in a comment) rather than forcing a same-band collision.

**Deferred to Phase 6b:** `scenes/ui/vegetation_edit_ui.gd` and `scenes/ui/map_select/` chrome. Both have their own internally-consistent bespoke color systems (a distinct blue tone, not byte-identical to the canonical palette) and `vegetation_edit_ui.gd` already implements proper hover/pressed button states via `_toggle_btn_style(on)`. Forcing these onto `UITheme` would be a subjective recolor with no way to visually verify the result in this headless-only environment — do in 6b with actual screenshot/manual verification, not blind.

**Verify:** [SUITE] all green, zero new boot errors vs. baseline (both maps). Functional headless checks: `TerrainLoadOverlay` (not exercised by normal boot — neither default map has a `TerrainLoader`) instantiated and driven directly through `setup()`/`set_progress()`/`enter_compact_mode()`/`show_map_loaded()` with no errors, confirmed `layer == UITheme.LAYER_LOAD_OVERLAY`; `SaveLoadUI` confirmed `layer == UITheme.LAYER_MODAL`, panel stylebox override present, and `show_load_message()` correctly applies `C_OK`/`C_ERROR` to the status label for success/failure.

## Phase 6b — UI visual polish wave (part 2, vegetation dock + map select) ⚙ Composer-class, needs manual/screenshot verification

**Goal:** Decide, with actual visual verification (not headless-only), whether `vegetation_edit_ui.gd`'s and `map_select/`'s bespoke blue palettes should converge onto `UITheme` or stay as intentionally-distinct sub-themes. If converging: same mechanical swap pattern as 6a. If not: document why in `CLAUDE.md`'s UITheme note so future passes don't re-litigate it.

**Verify:** [SUITE] + an actual windowed run (or screenshots) of the vegetation paint dock and the map-select screen before/after.

## Phase 7 — Audio system 🔶 Sonnet-class (bus routing + crossfade wiring is multi-part)

**Human step zero:** stage CC0 assets in `assets/audio/` (freesound.org): `wind_soft_loop.ogg`, `wind_strong_loop.ogg`, `birds_day_loop.ogg`, `ui_click.ogg`, `ui_toggle.ogg`, `toast_pop.ogg` + `LICENSES.md`.

**Goal:** Ambient wind tracking real WeatherService wind speed, day/season-gated birdsong, UI click feedback, Master/Ambient/UI sliders persisted.

**Files (6):** NEW `default_bus_layout.tres` + `project.godot` (bus layout + `AudioManager` autoload); NEW `core/audio_manager.gd`; assets; `scenes/ui/timeline_settings_panel.gd` (`_build_audio_tab` following the `_build_lighting_tab` pattern); one line in `toast_ui.gd`.

**Approach:** Two crossfading `AudioStreamPlayer`s on Ambient bus; poll `WeatherService.sample()` wind ~every 2 s at current clock, map 0–15 m/s → mix/volume_db with lerp; birds gated by `day_time` 5–20 h + season (reuse `core/season_model.gd` signals as `vegetation_environment_sync.gd` does). `play_ui("click")`; wire only high-traffic buttons. Persist to `user://audio_prefs.cfg` via `AudioServer.set_bus_volume_db`. Guard AudioServer calls so headless stays clean; synthetic weather fallback already always returns wind.

**Verify:** [SUITE] error-free. Manual: wind swells on a windy archive day; sliders persist; muting Ambient keeps UI clicks.

## Phase 8 — Vegetation texture asset pipeline 🔶 Sonnet-class (careful UV mapping across ~600 lines of mesh code)

**Human step zero:** stage CC0 atlases (ambientCG/Polyhaven) in `assets/vegetation/`: `leaf_deciduous`, `needle_pine`, `shrub`, `bark` — each `_albedo.png` (alpha-cut) + `_normal.png`, ~1024², + `LICENSES.md`.

**Goal:** Replace blobby runtime canopy/bark textures with real atlases — **albedo swap only** (normals loaded/passed but consumed in P11). Procedural path kept as fallback + toggle. Renderer-agnostic, so it lands before Forward+.

**Files (4 + assets):** NEW `vegetation/vegetation_texture_library.gd` (static species→{albedo,normal} loader, cached ImageTextures, procedural fallback); `vegetation/vegetation_card_factory.gd` (asset branch in `_build_cluster_foliage_texture` ~557-601 and bark ~531-554; atlas sub-rect per cluster for variety); `vegetation/vegetation_style_config.gd` (`use_texture_assets: bool = true`, JSON round-trip like existing knobs); `scenes/ui/vegetation_preview_editor.gd` (checkbox in Tune look modal).

**Approach:** `foliage.gdshader`/`bark.gdshader` already sample an albedo texture — no shader edits. `albedo_tint`, hue jitter, and seasonal blends operate on sampled color and keep working; re-default per-species tints in style config if needed (iterate live in Tune look).

**Verify:** `vegetation_selftest.gd` + [SUITE]. Manual: toggle assets off/on per species; tree at 2 m shows leaf silhouettes not noise blobs; autumn scrub still tints.

## Phase 9 — DONE (accepted). Evidence-based verification below; original spec follows.

**Switched** `project.godot` `rendering_method` to `forward_plus` (`.mobile` stays `gl_compatibility`). Verified with a windowed screenshot harness (NOT headless — headless is blind to rendering): booted the real game at 1280×720 on the machine's AMD Radeon 890M, planted a controlled vegetation test garden, captured summer-noon / autumn-noon / golden-hour / night / vista PNGs plus FPS soaks under **both** renderers, and visually compared the images.

**Results:**
- Vulkan 1.3 initialized; **zero shader compile errors** across full runs of both maps (all 9 custom shaders, sky, terrain, water builders load clean).
- **FPS improved**: garden 17.1→18.5, vista 14.1→15.8 — *with SSAO now actually rendering* (it was a silent no-op under compat).
- Near-field visuals clearly richer (linear-HDR pipeline): vivid grass/autumn colors, excellent golden-hour sky gradient. Night improved — structures dimly moonlit while vegetation stays dark (the night_darkness fix holds under the real lighting pipeline).
- Canvas rendering (system graph, timeline NLE bar) pixel-perfect under Vulkan.
- No visible TAA ghosting on wind-animated foliage in stills; TAA also smooths the foliage screen-door dither as predicted.
- One cosmetic note for P10: the distant vista reads slightly paler than compat (linear ambient/tonemap response, present-but-milder under compat too). Isolated via haze-zero A/B — NOT the foliage haze shader. Fix belongs in P10's tonemap/ambient tuning (user cfg currently tonemap=Linear).
- Deliberate defaults per plan: `ssil_user_enabled` code default true→**false** (real cost now, subtle outdoors; gear-panel re-enableable + persisted); SSAO stays on. Also corrected two toggles in the live `user://sim_settings.cfg`: `ssao_enabled=false` was residue written by the Phase 4 test harness (not a user choice — restored to true), `ssil_enabled=true` was a persisted no-op from compat days (set false to match the new default). Other cfg values (sun_energy 2.19, cloud/moon tweaks) are genuine user settings and were left untouched.
- Full headless SUITE re-run post-switch: physics 124 / terrain 115 / graph 6 / vegetation 2139 all PASS; no addon-DLL fallout.
- **Water/ReflectionProbes caveat:** neither default map has Water nodes, so per-lake ReflectionProbes under Vulkan remain unexercised — check on the first generated location map with lakes (they compile from the same portable shaders; risk is perf, not correctness).

**Rollback if ever needed:** revert the one project.godot line, delete `.godot/shader_cache`.

## Phase 9 (original spec) — Forward+ renderer switch (GATED) 🔴 STRONG MODEL REQUIRED

**Why strong:** the change is one line; the *validation is judgment-heavy* — triaging visual regressions on two maps, TAA-vs-wind-vertex ghosting (no motion vectors from `wind_vertex.gdshaderinc`), SSAO/SSIL snapping on, ReflectionProbe cost, and the keep-or-rollback call. A weak model will flip the line, see a clean headless boot, and declare success while the game ghosts at 20 fps.

**Goal:** `project.godot:278` `"gl_compatibility"` → `"forward_plus"` (leave `.mobile` override), fallout contained.

**Known fallout to handle in-phase (verified):**
1. `main.gd:308-320` defaults `ssao_user_enabled=true`/`ssil_user_enabled=true` — no-ops under compat, activate instantly under Forward+. Set defaults deliberately (recommend SSAO on, SSIL off); P4 persistence makes it a saved choice.
2. TAA (`project.godot:284`) becomes real → expect canopy smear. Mitigations in order: accept (TAA also smooths the foliage FRAGCOORD dither — screen-door largely disappears), reduce, or swap to MSAA 2x + FXAA. Judged visually.
3. All 9 shaders use portable render_mode hints (verified) — still check boot log for compile errors, sky quarter-res pass, per-lake ReflectionProbes on a lake-heavy site.
4. Perf on both maps + one generated map (24k trees/40k grass stress case).

**Rollback:** revert one line (+ delete `.godot/shader_cache` if weird). State in commit body. Keep P10–P13 off the branch until P9 is accepted in actual play.

**Verify:** [SUITE] both maps, error diff vs known set; manual play: fps before/after, day/night scrub, water, graph UI, close-up wind ghosting check.

## Phase 10 — DONE. Evidence-based verification below; original spec follows.

**Tonemap: Linear → ACES (default changed).** A/B screenshot comparison (Linear/ACES/AgX × vista/golden-hour/night) showed ACES fixes the pale-vista issue Phase 9 flagged — deep contrast, rich greens, real depth cue — with **no regression** at golden hour or night (tonemap curves converge near black; night frames were pixel-similar across all three). AgX was nearly indistinguishable from Linear in this scene and wasn't chosen. `main.gd`'s `tonemap_mode` default updated with rationale in a comment. Existing per-user persisted choices are respected (not force-overwritten) — this only changes what a *fresh* profile gets, consistent with the project's established persistence precedent.

**MSAA added** as an independent AA choice alongside the TAA implied by `graphics_quality` (some players prefer MSAA's sharper edges over TAA's ghosting trade-off on wind-animated foliage). New `main.gd` `msaa_level` property (0=Off/1=2x/2=4x/3=8x) applying `Viewport.msaa_3d`, wired through the full `SimSettingsController` persist/load/snapshot chain and a new "MSAA" dropdown in the Lighting tab. Verified end-to-end: dropdown → `apply_msaa_level()` → `Viewport.msaa_3d` → persisted cfg → snapshot, all confirmed via headless script.

**SSAO/SSIL labels already accurate** — checked before touching anything; no "may not work" caveats existed to remove, so left as-is (they're honestly true now that Forward+ makes these real).

**Foliage dither NOT retuned.** Before touching `alpha_dither_min/max`/`near_crisp_m`/`far_dither_m`, I captured close-up shots of a real tree canopy at the near-crisp boundary and the far-dither boundary under Forward+/TAA — both looked clean with no visible stipple/screen-door artifact. Evidence didn't support a change, so none was made; retuning blind (as the original spec's wording invited) would have been guessing, not tuning.

**Bug found and fixed (out of scope for Phase 10, but directly blocking its own verification):** testing on a real generated-location map (Lincoln, MA — user-directed correction after the soak-festival map's hand-placed vegetation gave false confidence) revealed auto-scattered deciduous trees had **zero registered shader materials** — the seasonal/wind uniform sync silently never reached them. Root cause: `VegetationRuntime.rebuild()` (manual layer) and `AutoVegetationRuntime.rebuild()`/`rebuild_async()` (auto layer) each unconditionally clear **all** shader registrations via `_clear_shader_registrations()`, but the manual-layer rebuild is deliberately deferred until the full load sequence completes — i.e. *after* auto-vegetation has already registered. On a fresh site (empty manual layer) nothing re-registers afterward, permanently silencing autumn color, leaf-drop, spring bud, winter dormancy, snow, wind, and the night-darkening fix from the previous turn — for every auto-scattered tree on every generated map, forever. Fixed symmetrically: `AutoVegetationRuntime.reregister_existing(terrain)` / `VegetationRuntime.reregister_existing(terrain)` (new functions) are now called at the end of the *other* layer's rebuild, so whichever layer didn't just rebuild gets its existing materials re-registered rather than orphaned. Verified end-to-end on the real map: registered-material count 0→3, foliage `autumn` uniform 0.0→0.9999, and the close-up screenshot changed from green to vivid orange/red.

**Also found, NOT fixed (separate bug, flagged for follow-up):** auto-scattered deciduous trees render as sparse "pom-pom" canopies (thin trunk + small disconnected foliage clusters) rather than full canopy, on the same Lincoln, MA map. This is a mesh-generation/scale issue in the auto-vegetation card-building path, unrelated to Forward+ or tonemap — it would look identical under GL Compatibility. Out of scope for this phase; needs its own investigation into why auto-scatter's `VegetationCardFactory` output differs so much from manually-painted specimens of the same species.

> **RESOLVED by Veg Overhaul v2 (verified 2026-08-11):** the deciduous canopy
> was rebuilt on a space-colonization branch skeleton with real foliage clumps
> capping the tips (see CLAUDE.md "Procedural deciduous tree"), and the
> `--capture=tree` portraits on the Mount Vernon map now show a full connected
> canopy at NEAR for every deciduous species (~7k tris, exact authored
> heights, foot at y 0). The clump-scale root causes (NEUTRAL_BULK ×1.6 on the
> auto path, clump floor swallowing the trunk) are pinned in
> `auto_vegetation_selftest.gd`.

**Verify:** [SUITE] all green (physics 124, terrain 115, graph 6, vegetation 2139) both before and after the registration fix; both maps boot clean vs. baseline throughout.

## Phase 10 (original spec) — Post-switch environment & AA tuning 🔶 Sonnet-class

**Goal:** Make Forward+ pay off: tuned SSAO/SSIL, tonemap default review (currently Linear at `main.gd:328` — evaluate AgX/ACES/Filmic for outdoor scenes), glow subtlety, foliage dither window re-tune for the TAA era, and honest settings-panel labels (remove/annotate any still-dead toggles).

**Files (4):** `main.gd` (env defaults), `scenes/ui/timeline_settings_panel.gd` (TAA/MSAA choice, correct SSAO/SSIL labels), `vegetation/foliage.gdshader` + `vegetation/vegetation_style_config.gd` (re-default `alpha_dither_min/max`, `near_crisp_m/far_dither_m` — existing knobs, no new plumbing).

**Verify:** [SUITE]; A/B screenshots noon/golden-hour/night on both maps; each toggle produces a visible change and persists. Depends: P9 (hard), P4.

## Out-of-band: silent-crash diagnosis + stability/VRAM pass (2026-07-02)

**Symptom:** game silently exits 1–2 min after loading a generated map, "just looking around," after the user's cloud + vegetation improvements. **Root cause (from Windows event log + Godot run logs):** six APPCRASHes, all `0xc000001d` (SIGILL) at the identical offset — Godot's deliberate trap in its **`Vulkan device was lost`** handler (`on_device_lost` → `command_queue_execute_and_present`). The GPU context itself was killed by the driver (AMD 890M iGPU, driver 24.30.46 / 2025-03). `VK_EXT_device_fault` reported "No fault detected" (timeout-style hang, not a shader page fault). Breadcrumbs inconclusive (SKY/BLIT/UI region).

**Reproduction attempts (all SURVIVED 5 min, 48–60 fps, flat memory):** (1) 720p windowed look-around soak on Lincoln MA; (2) fullscreen 1080p with sim pinned to sunset (activating the new twilight-sky branch) and camera sweeping the cloud layer; (3) same again **with the Godot editor running concurrently** (two Vulkan contexts on the 2 GB carve-out — FPS dropped to 39–50 but no device loss). The app in scripted isolation is stable; the crash needs conditions scripting can't fully match (real first-person play with camera inside dense grass shells = worst-case overdraw, long editor sessions, driver/thermal state).

**Mitigations landed:**
- `imagery_service.gd`: drape textures now get mipmaps + S3TC/DXT compression on the GPU copy (`_make_drape_texture`) — disk PNG cache unchanged; all three CPU readers (landcover gate, scatter samplers, camp scatter) already had `is_compressed() → decompress()` guards. Verified: identical 63,323-instance scatter on Lincoln, clean drape screenshot, ~38 MB VRAM saved measured (947 vs 981 MB at 720p; more at 1080p).
- `project.godot`: `window/size/mode` 4 → 3 (borderless fullscreen instead of exclusive) — visually identical, avoids exclusive-mode swapchain switches that are a known instability source on hybrid AMD + older drivers.
- Fixed Phase 4-era test residue and stale `tonemap_mode=0` key handling in the live `sim_settings.cfg` during earlier phases; user's cfg now: ssao on, ssil off, msaa 2x, Reinhard (their choice).

**Next-step experiment matrix for the user (ordered by information value):**
1. **Update the AMD driver** (24.30.46 is from 2025-03; 890M Vulkan device-lost fixes shipped in later Adrenalin releases). Single most likely full fix.
2. **Play a session launched standalone** (`Godot.exe.exe --path .` or an export) with the editor closed — if it never crashes standalone but does under F5, it's editor+game GPU contention and the workflow answer is "close the editor's 3D viewport / use a smaller editor window while playtesting."
3. If it still crashes standalone: bisect content — same session with `clouds_amount=0` (gear panel) vs vegetation density lowered; the logs at `%APPDATA%/Godot/app_userdata/SIMbiogenesis/logs/` now reliably capture the device-lost banner + breadcrumbs; grab the newest log after each crash.
4. Optional diagnostic: raise the Windows TDR timeout (`TdrDelay`=10, HKLM, admin + reboot) — if crashes stop entirely, it's a long-GPU-frame timeout, not a driver fault, and further GPU-load reduction in-app is the fix.

## Phase 11 — Foliage & bark shader realism rework 🔴 STRONG MODEL REQUIRED

**Why strong:** lighting-model surgery in a shader with five interacting systems (seasonal phenology, snow, drape-match, dither, style knobs); the additive fake-SSS (`foliage.gdshader:175-183`) must be **replaced, not stacked**, or everything double-glows; `vegetation_environment_sync.gd` uniform pushes must change in the same commit.

**Goal:** Normal-mapped leaves responding to the sun, real specular, backlight translucency via a `light()` function instead of the additive albedo hack; bark normal + grain. Biggest single vegetation-realism jump, consuming P8's normal textures.

**Files (5):** `vegetation/foliage.gdshader`, `vegetation/bark.gdshader`, `vegetation/vegetation_card_factory.gd` (bind `normal_tex`; TANGENT setup on card quads), `vegetation/vegetation_style_config.gd` (`normal_strength`, `specular_strength` knobs; keep `translucency_strength`/`subsurface_strength` names, re-scale semantics), `scenes/ui/vegetation_preview_editor.gd` (slider rows).

**Approach:** `render_mode diffuse_burley, specular_schlick_ggx` (cf. `camp_tint.gdshader` which already uses burley); `NORMAL_MAP`/`NORMAL_MAP_DEPTH` from atlas normals; translucency in `light()`: `pow(max(dot(-LIGHT, VIEW),0), p) * ATTENUATION * translucency_strength * top_mask`; delete the `sun_direction`/`night_factor` uniform hacks it replaces (and their dead pushes in the 0.2 s sync poller). Preserve untouched: seasonal blocks, snow, drape match, hue jitter, dither/scissor, `canopy_roundness`.

**Verify:** `vegetation_selftest.gd` + [SUITE]; golden-hour walkthrough (backlit canopy glows without whiteout, noon leaf sparkle subtle); winter/autumn scrub correct; Tune look sliders behave. Depends: P8 (hard), P9 (soft — works under compat, but tune once under the final renderer).

## Phase 12 — Terrain lighting realism 🔶 Sonnet-class

**Goal:** Terrain that responds to the sun. `terrain_detail.gdshader` is currently `specular_disabled` with mesh-resolution-only normals — visually dead at grazing sun. Pairs with P11 (trees casting onto responsive ground sells both).

**Files (3–4):** `core/terrain/terrain_detail.gdshader`; `core/terrain/terrain_builder.gd` (bake a normal-map Image from the height grid via central differences — pure static, add a `terrain_selftest.gd` check); `core/terrain/terrain_loader.gd` (pass texture into base + detail-patch materials); optionally `main.gd`.

**Approach:** `NORMAL_MAP` from the height-derived texture (detail DEM ⇒ ~47 m-or-better relief pops at low sun); `specular_schlick_ggx` with roughness ~0.9 so only snow/wet sheens (existing snow block already drops roughness — keep); cheap slope-based cavity darkening. Do NOT attempt to de-light baked imagery shadows (known limitation).

**Verify:** extended `terrain_selftest.gd` + [SUITE]; manual: sunrise scrub on a mountainous generated map — relief shading sweeps with the sun; flat offline fallback (2×2 grid) bakes a flat normal map without error. Depends: P9 (soft).

## Out-of-band: grass shell-extrusion rewrite (done ahead of sequence)

Landed directly on user request, ahead of P8/P11/P13: `vegetation/grass_builder.gd` and `vegetation/grass.gdshader` were rewritten from discrete per-blade crossed-quad clumps (NEAR 5 blades / MID 3 blades) to a **shell-extrusion "mat"** — a stack of flat horizontal shells (NEAR 14, MID 7), each a fragment-shader fake-blade density mask (per-cell randomized height/thickness/lean, height-based AO, discard-based cutout blending into the existing distance-based flat-patch fade). `grass_lawn_card_w`/`grass_field_card_w` now mean **mat footprint width** (bumped 0.08→0.45, 0.11→0.55), not blade width — the FAR patch tier is untouched. New per-species knobs (`*_cells_per_side`, `*_height_variation`, `*_blade_thickness`, `*_blade_lean`, `*_hue_jitter`) live in `VegetationStyleConfig.defaults()` and are exposed in both `vegetation_edit_ui.gd` (paint dock) and `vegetation_preview_editor.gd` (Tune look modal). A follow-up realism pass raised `cells_per_side` ceiling to 32, made the fake-blade mask anisotropic (elongated line, not a radial dot), and re-defaulted lawn to short/uniform/saturated-green vs. field's taller/varied/olive. **Any future grass work (P8 texture assets, P11 lighting rework, P13 impostors) should read the new `grass_builder.gd`/`grass.gdshader` directly rather than trusting old "crossed-blade-card" descriptions elsewhere in this doc or in exploration notes predating this change.**

## Out-of-band: seasonal timelapse polish (autumn colour, grass growth, night lighting)

Landed on user request. Three coupled changes across the seasonal-uniform pipeline (`SeasonModel.season_signals` → `main.get_season_signals` → `VegetationEnvironmentSync._push_uniforms` → shaders):
- **Vivid autumn** (`foliage.gdshader`): the 2-stop yellow→red autumn ramp became a 3-stop yellow→**orange**→red ramp (new `autumn_orange` uniform), brighter base colours, and a stronger blend (0.85→0.92) with less luma-darkening, so deciduous foliage clearly changes colour *before* leaf-loss thins it. Timing was already correct in `SeasonModel` (autumn peaks ~Oct 25, just before leaf-drop starts ~Oct 27) — this was purely a vividness fix, no model timing change.
- **Grass growth** (`SeasonModel` + `grass.gdshader`): new `grass_growth` phenology signal (0 winter → 1 summer, `GRASS_GROW_START/FULL/FADE_*` constants) drives a new `growth` uniform that scales grass shell height in the vertex stage (`VERTEX.y *= mix(growth_floor, 1.0, growth)`), so turf visibly grows in over spring/summer and lays down for winter. `growth_floor` (0.30) keeps a short dormant mat. Normalized height (COLOR.r) is untouched so blade-masking + wind are unaffected.
- **Night moon-glow fix** (`foliage.gdshader` + `grass.gdshader`): both caught the moon's directional light and lit up unrealistically at night. Fixed by multiplying final ALBEDO by `1 - night_factor * night_darkness` (default 0.82). Chose albedo-darkening over a custom `light()` function deliberately: it's **guaranteed daytime-identical** (night_factor=0 → ×1.0) and can't be visually verified headlessly, whereas a `light()` rewrite risks a daytime brightness shift. Dim bluish ambient still reads the vegetation as moonlit. Bark left alone (dark already, not reported, and the sync doesn't push it night_factor).

Verified: `source_physics_selftest.gd` gained 3 grass-growth checks (121→124, all pass); forced render pass compiled both shaders' new vertex+fragment paths; both maps boot clean vs. the known baseline (the 26 `data.tree is null` import errors are pre-existing editor-import noise, confirmed by stash-diff).

## Phase 13 — Far-tree impostor/billboard LOD 🔴 STRONG MODEL REQUIRED

> **SUPERSEDED by Veg Overhaul v2 (2026-08-11):** the impostor tier shipped in
> a different, more capable form than planned here —
> `vegetation/veg_impostor_baker.gd` (in-process 8-yaw + top 3×3 atlas bakes,
> content-hash cached under `user://veg_impostors/`, BAKE_VERSION-gated) +
> `veg_impostor.gdshader` + `veg_lod_policy.gd` (budget-aware detail distance
> replacing the SoI rings). See CLAUDE.md "Tree LOD (Overhaul v2)". The plan
> below is retained for history only; do not build from it.

**Why strong:** cross-system — runtime SubViewport baking, distance-partitioned MultiMesh population inside AutoVegetationGenerator (caps, species weights, OSM overrides), rebake hooks on style change, shadow policy. Easiest phase to get subtly wrong (popping, double-drawing, stale bakes).

**Goal:** Trees beyond ~350–400 m render as single baked camera-facing cards (grass already has a FAR patch tier; trees currently draw full geometry + shadows to 900/2200 m). Perf headroom + better distant silhouettes.

**Files (6):** NEW `vegetation/impostor_baker.gd` (reuse the neutral-ground + key/fill light SubViewport studio from `scenes/ui/vegetation_preview_editor.gd`); NEW `vegetation/impostor.gdshader` (vertical-axis billboard, alpha scissor, haze uniforms matching `foliage.gdshader` so tiers fog identically); `vegetation/vegetation_card_factory.gd` (impostor mesh/material builders); `vegetation/auto_vegetation_generator.gd` (near-MultiMesh vs impostor-MultiMesh partition per species, dither cross-fade band); `core/terrain/terrain_loader.gd` (rebake inside the `set_vegetation_style` path — same hook as `_full_regenerate_auto_vegetation`); `vegetation/vegetation_selftest.gd` (bake determinism + partition counts).

**Approach:** 1–2 views per species+style (front + 45°), 256² atlas, baked once per style application (octahedral impostors explicitly out of scope). Impostor tier `shadows_disabled` (distant shadows are the current perf tax). Seasonal tinting: pass the same `autumn/winter/leaf_coverage` uniforms and copy the albedo-space blend blocks from `foliage.gdshader:140-162`. Respect the 24k cap accounting.

**Verify:** `vegetation_selftest.gd` + [SUITE]; manual: walk toward a treeline — ~350–400 m transition near-invisible; fps at a forest overlook before/after; species tint change in Tune look updates distant trees after rebake; season scrub reaches far trees. Depends: P8, P9, P11 (bake captures the final lit look).

---

## Dependency graph

```
P1 UITheme ──► P2 palette migration ──► P6 polish wave
   ├────────► P5 help overlay ◄── P3 toasts (hints)
P4 gfx persistence ──► P9 Forward+ ──► P10 env/AA tuning
P7 audio  (independent, anytime after P1)
P8 veg textures ──► P11 foliage rework ──► P13 impostors
P9 ──► P10 (hard); P11/P12/P13 (soft)
P12 terrain lighting (soft-depends P9 only)
```

Shippable checkpoints: after **P6** (UX coherent), after **P10** (renderer upgraded + tuned), after **P13** (full realism).

## Risk notes

- **P9 is the pivot risk.** Compat may have been chosen deliberately (StarShadeConsole/OBS pipeline or GPU limits) — biggest technical risk is TAA ghosting on wind-displaced vegetation. Rollback is one line; keep P10–P13 off the branch until P9 is accepted in play.
- **Headless validation is blind to visuals.** [SUITE] proves "not broken", never "looks better" — every phase from P8 on needs an eyeball pass; bake the manual checklist into each phase's commit/PR description.
- **P7/P8 have a human step zero** (CC0 asset sourcing + `LICENSES.md`) before a coding model starts.
- **P11 must replace, not stack** the additive SSS, in one commit, with `vegetation_environment_sync.gd` updated in the same change.
- Never rename UILayer children; run multi-file UI phases with the Godot editor closed.
