# SIMbiogenesis — Project Memory

Godot 4.7 (Forward+ on desktop; GL Compatibility only as the `.mobile` fallback).
First-person ISRU / renewable-energy simulator with a real
Home Assistant digital-twin bridge. **Core gameplay = 2D systems graph** (schematic
map of resource flows within a Sphere of Influence); **3D world = embodied digital twin**.
Product vision: `docs/ROADMAP.md` + graph overhaul: `docs/SYSTEMS_GRAPH_VISION.md`. Structure
& module conventions (where new code goes, extension points, cleanup backlog):
`docs/ARCHITECTURE.md`. Restructure history: `plans/PHASE1_INVENTORY.md` … `plans/PHASE7_PERFORMANCE.md`. Secrets policy:
`docs/LOCAL_CONFIG.md` (real HA/UISP credentials live under `user://` only — never
commit URLs or tokens).

## Repo layout and where files go (2026-10-20)

- **The repo root stays minimal:** `project.godot`, `export_presets.cfg` (Godot
  needs both there), `README.md`, `CLAUDE.md`, `CREDITS.md` (`linkage_selftest`
  opens `res://CREDITS.md`), `LICENSE`, `.gitignore`, `.gitattributes`. Never add
  scripts, textures or notes at the root.
- **Plans, status matrices, walkthroughs and working notes go in `plans/`**
  (gitignored, local only). That includes plan files, "next pass" lists, phase
  write-ups and the harness status matrix (`plans/HARNESS_MATRIX.md`).
  `.gitignore` also catches `*PLAN*.md`, `PHASE*_*.md`, `*_MATRIX.md` and the
  like dropped at the root. Code comments may still cite them by bare name.
- **Documentation that ships goes in `docs/`** (architecture, assets, local
  config, the feature cheat sheet, roadmap, vision, `docs/FEATURES.md` + the tour
  images, `docs/config-templates/`).
- **Moving a file:** move its `.uid` / `.import` sidecar with it, rewrite every
  `res://` reference (including the gitignored local map scenes), then run
  `python tools/checks/res_path_audit.py` — it lists every `res://` path and
  relative Markdown link whose target is missing.

## Releases + fresh clones (2026-10-20, docs/RELEASES.md)

- **A fresh clone must compile.** An unanchored `build/` in `.gitignore`
  hid `core/linkage/build/` from GitHub, and every clone failed with
  "LinkageBuildSteps not declared". Anchor every output-folder rule
  (`/build/`, `/release/`). Before pushing, run
  `python tools/checks/ignored_source_audit.py`: it fails on any ignored
  `.gd` / `.tscn` / `.gdshader` / `.uid` outside the art folders and
  local-only folders.
- **Releases:** `python tools/release/build_release.py` (templates:
  `tools/release/install_export_templates.py`). It writes
  `release/<version>/` (gitignored, `.gdignore`d), containing:
  - three game zips with NO gitignored art;
  - the art add-on, `simbiogenesis-art-{mars,soak,starshade,models}.pck`,
    each under GitHub's 2 GiB asset limit (`ART_PACKS` groups);
  - `SHA256SUMS.txt` and the release notes.

  `GAME_EXCLUDE` / `GAME_INCLUDE` in the script are the ONE filter list. The
  script syncs them into the committed presets, so the editor's
  Project → Export makes the same build.
- **`ArtPackMount` (core/art_packs.gd) is the FIRST autoload** (`ArtPacks`).
  In an exported game it mounts every `simbiogenesis-art-*.pck` found beside
  the executable (also `art/`, macOS `Contents/Resources` and beside the
  `.app`, `user://art/`, `--art-dir=`). It mounts with
  `replace_files = false`, so code always comes from the game build.
- **Exported builds have no `project.godot`** and list `res://` folders as
  `X.import` / `X.remap`. `InputOverrides.project_actions` falls back to
  `ProjectSettings` for that reason. Any new `DirAccess` listing of
  `res://` must strip those suffixes; the NPC rig, tour catalog and Linkage
  presets already do. A loose file opened with `FileAccess` needs its
  extension in `GAME_INCLUDE`.
- **The friend's path**, rehearsed by `<clone>\tools\harness.ps1 -EmptyUser
  -Capture assetpack-import -UserArgs @("--import=<pack>")`: it installs the
  pack, WAITS for the Share window's background art import, then plays.
  Closing the Share window mid-import keeps it alive, and it reopens with
  Restart now.
- **Per-world terrain imagery** (`TerrainImageryPlan`, the "Per-world imagery"
  block in terrain_loader). The quality tier is per COMPUTER
  (terrain_config.cfg), but cache keys are site + square + zoom, so a pack's
  layers at the author's tier were never loaded on a friend's tier. Now:
  - `world.json` `terrain_imagery` = `{tier` (shown at, recorded on every
    save via world_extras), `saved_tier` (the imported imagery's, -1 for a
    world made here), `mode` "saved" | "local"`}`.
  - The installer sets `mode: "saved"`. Its tier comes from the record, or
    from `infer_tier` over the cached files for older packs.
  - In saved mode a layer the saved tier has on disk (or does not have at
    all) is shown at that tier.
  - In local mode a layer that fails (`_on_imagery_failed`) re-requests the
    saved tier's copy from disk, or the last-shown tier's for a world made
    here.
  - `_hyper_drape_half` / `_site_drape_half` keep the size of the drape on
    screen when a request fails with no fallback.
  - The UI is `TerrainImageryChoice`, in the Share install screen and the
    world panel.
  - `terrain_imagery.sharp` ("sharpest" | "newest", Settings → Lighting →
    "Sharpest layer"): the hyper + site layers' chain. Sharpest = regional /
    Clarity (often an OLDER photo: at Bombay Beach the shoreline jumped at
    the sharp square's edge); newest = plain ESRI, the detail drape's own
    capture. Through `TerrainImageryPlan.with_sharp` / overrides
    `sharp_source`, carried by `record_for_import`.
  - `ImagerySources.is_blank_tile` calls a tile empty only if it is the
    ESRI placeholder's neutral grey (204,204,204). Uniform water / sand used
    to count as blank and fell through to the next source, mixing two
    captures tile by tile (the stepped Salton Sea shoreline, 2026-10-23).
  - `ImageryService.offline_for_test` / `--imagery-offline` makes every
    download fail, which is how the fallback is tested.
  - Caches made before the source-chain change are named without the
    `_esri_clarity` (or regional) suffix. Since 2026-10-20 a chained layer
    also loads that plain-ESRI file (`ImageryService.cache_candidates`:
    own name → img_v1_ → plain), with ESRI attribution. Before that, those
    files were ignored and re-downloaded, which made the author's pack read
    as Low instead of Ultra. `TerrainImageryPlan.is_cached` uses the same
    list, so inference and loading always agree.

## Validation (run before every commit)

### Harness rules (user, 2026-10-12): read before running ANY windowed capture
- **Never use the SOAK 2026 or Mars built-in scenes for harness testing** unless
  the user explicitly asks. They are large imported meshes, not TerrainLoader
  maps, and caused repeated harness failures (e.g. the soak-map graph-open
  hang). Every capture runs on the user's real **Mount Vernon** (`mtvernon`) or
  **Walton** (`walton`) WORLD. `HarnessRegistry` (`core/terrain/harness/`)
  gives every mode a default world, and the harness refuses `--scene=<SOAK/Mars>`
  without `--allow-builtin-scene`.
- **Always launch through `tools/harness.ps1`.** Godot builds `user://` from
  `APPDATA`. The launcher seeds a throwaway sandbox copy of the user data dir
  under `%LOCALAPPDATA%\SIMbiogenesis_harness\runs\<id>\`, points `APPDATA` at it
  for the Godot process, and hash-checks the real dir afterwards
  (`REAL USER DATA UNCHANGED`). How it seeds:
  - Copied: worlds, maps, saves, prefs.
  - Hard-linked: immutable `.glb`, `.stl` and `.mp3` assets only. A Godot WRITE
    through a hard link changes the original, so measure before adding a type.
  - Junctioned: regenerable caches, plus `screenshots/` so PNGs land where they
    always did.
  - Seeding takes about 1 s. The newest 6 sandboxes are kept and older ones are
    pruned junction-first.
  - The harness refuses to start (exit 4) without the sandbox marker
    `user://.harness_sandbox`, so a bare `Godot … -- --capture=x` can no longer
    write into the player's world.
- **The run loads the world exactly as the user left it.** `--world=<alias|id>`
  goes through `WorldSession.launch`, so the snapshot (player pose, clock,
  battery, panel config) is restored. `--user-map=mtvernon` now means that
  world too.
- **When the user reports a problem, run `-Capture look` first.** It writes
  `look/`: the saved view with UI and without, four drone shots round the
  player, the graph in its saved lens, and `diagnostics.json`.
- **Changing the user's real world takes `-Persist`, and only for fixes.** Allowed
  only with `-RunScript res://tools/fixes/<fix>.gd` (a `run(main, harness) ->
  Dictionary` that may await; the world is saved through
  `WorldSession.save_now`) or with `-Capture look`. The launcher first backs up
  the world-state files and prints `tools\harness.ps1 -RestoreBackup <dir>`.
  Test captures never persist. Dry-run a fix in the sandbox first.
- **Every run ends with one line:** `HARNESS RESULT <mode> PASS|FAIL|TIMEOUT …`
  plus `results.json` in the shots dir, and a real exit code: 0 pass, 1 fail,
  3 watchdog timeout, 4 refused, 5 launcher kill (compile error, never
  started, or hard limit), 6 real data changed.
  - `HarnessReport` is an engine `Logger`. It counts the captures' own
    `PASS` / `FAIL` / `FAILED` / `FAILURE(S)` tokens (case-sensitive) and fails
    on any GDScript runtime error.
  - Every mode has a watchdog budget; `-Timeout` overrides it.
  - `-Capture a,b,c` runs several captures on one map load.

```
# Harness examples (PowerShell; add -Label <dir> to name the shots folder):
tools\harness.ps1 -World mtvernon -Capture look
tools\harness.ps1 -World walton -Capture festivalmode
tools\harness.ps1 -World mtvernon -RunScript res://tools/fixes/<fix>.gd            # dry run
tools\harness.ps1 -World mtvernon -RunScript res://tools/fixes/<fix>.gd -Persist   # keep it
# Registry + report selftest (offline):
Godot.exe.exe --headless --path . --script core/terrain/harness/harness_registry_selftest.gd
# Feature tour (see "Feature tour" below) — stop metadata selftest (offline,
# check count = 19 + 10 per stop) and the tour itself:
Godot.exe.exe --headless --path . --script core/tour/tour_selftest.gd
# Site address redaction for harness shots (offline, SitePrivacy):
Godot.exe.exe --headless --path . --script core/site_privacy_selftest.gd
tools\tour.ps1 -Mode stills            # all stops, both worlds -> screenshots + manifest
tools\tour.ps1 -Mode stills -Resolution 1280x720 -Audit strict   # the small-screen UI gate
tools\harness.ps1 -World mtvernon -Capture modals -UserArgs @("--window-size=1280x720")  # every modal audited
python tools/tour_docs.py              # -> docs/tour/*.jpg, docs/FEATURES.md, README gallery
```

The windowed `--capture=` commands further down are the GODOT args the launcher
passes. Run them as `tools\harness.ps1 -World <w> -Capture <mode> [extra args]`.
Their `--world=` / `--user-map=<x>` parts name the default world, and
`--user-map=mtvernon|walton` resolves to that world. The 14 commands that
used to boot SOAK were moved to Mount Vernon or Walton on 2026-10-12. Their
prose may still say "soak map"; read that as the world they now run on.
`tools\harness_matrix.ps1 [-Modes a,b]` runs a list of captures back to back
and prints a results table. `plans/HARNESS_MATRIX.md` holds the current status of
every mode and the open items. Two baselines apply to test captures and are
skipped for `look` and `script`:
- `PopTestPrefs` is reset in memory, because the author's all-off guardrails
  break every scarcity check.
- The sandbox's `npc_display.cfg` is set aside, because display taste skewed
  the hero-pool and rig checks.

The launcher also kills a run whose stderr shows a GDScript Parse/Compile
Error, or whose harness never wrote `user://harness_started.json` within
120 s (exit 5).

```
# Godot 4.7.1-stable binary (the examples below use "Godot.exe.exe" as a
# shorthand for whichever current binary you have on PATH):
C:\Users\notsa\Downloads\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe
# (The old 4.6.2 binary — double extension correct — still lives at
#  C:\Users\notsa\Downloads\Godot\Godot.exe.exe for A/B comparison.)

# After adding any new class_name script, import once or headless runs fail
# with "Could not find type":
Godot.exe.exe --headless --path . --import

# Physics self-test (extend it with every physics change):
Godot.exe.exe --headless --path . --script power_system/sources/source_physics_selftest.gd
# Resource-flow engine self-test (offline — spec-driven hydro incl. the
# stream-source path, penstock-conn authority, habitat/processor/tank flows;
# extend it with every flow-engine change):
Godot.exe.exe --headless --path . --script power_system/sources/resource_flow_selftest.gd
# Services node-registry self-test (offline — register/get/has, auto-clear on
# tree exit, freed-node guard; see docs/ARCHITECTURE.md debt #1):
Godot.exe.exe --headless --path . --script core/services_selftest.gd
# Render presets self-test (offline — the graphics/shadow quality tables pulled
# out of main.gd into core/env/render_profile.gd; pins every value AND that the
# presets are ordered as advertised. Worth having because project.godot carries
# only the HIGH baseline and main.gd overrides atlas size, soft-shadow quality
# and TAA at runtime, so project.godot alone does NOT tell you what the game
# renders with. Phase 4 added QUALITY_ULTRA (3, appended — indices persist) and
# veg_profile(quality): the veg tier baseline — SoI ring radii, leaf shells,
# instance caps, cull distances, large-map scatter density, veg shadows —
# applied by terrain_loader._veg_style_with_quality (player-tuned keys, i.e.
# values differing from VegetationStyleConfig.defaults(), always win; the
# generator sees the SAME dict via _auto_veg_ctx so scatter and render agree;
# veg_quality_managed supersedes prepare_context's legacy large-map rewrite).
# HIGH is pinned == pre-Phase-4 defaults, HIGH-large == the old hardcoded
# thinning. One-shot <45 fps auto-drop after load persists veg_auto_dropped
# in perf_prefs.cfg [render]):
Godot.exe.exe --headless --path . --script core/env/render_profile_selftest.gd
# Camera-claim stack self-test (offline — the CAMERA counterpart of the clock
# stack, same API and same reason. ~11 subsystems each swapped the active
# camera by hand with a private saved-camera field, which cannot nest: a
# harness capture saves the player cam, the snowglobe then saves the CAPTURE
# cam and restores THAT, and when the capture frees its camera the viewport is
# left on a freed object. The selftest reproduces exactly that, released out
# of order. The service stores camera_id ints so it stays pure; main.gd owns
# push/pop/_apply_camera_claim and every side effect (hide_player_mesh,
# shadow_max_distance, prop_cull_scale_m) plus restore-on-empty. NOT claimants,
# permanently: the six SubViewport modal previews and graph_soi_preview_service
# never touch the main viewport's camera):
Godot.exe.exe --headless --path . --script core/camera_claims_selftest.gd
# Window Wall data layer self-test (offline — core/windowwall/): the multi-
# monitor viewport's layout + off-axis frustum maths, prefs and per-map
# viewpoint. The load-bearing check INVERTS the projection Godot itself builds
# (Projection.create_frustum_aspect with flip_fov = KEEP_WIDTH) and asserts the
# four corner rays land on the physical monitor's corners, plus a NEGATIVE pin
# that the flip_fov=false form does NOT — that pair is what freezes "size is
# the near-plane WIDTH", the whole bezel-continuity property. Also the far-
# point-through-any-panel = one wall point identity, screen auto-assignment,
# prefs round-trip against a TEMP path, and the viewpoint JSON. Carries
# EXPECTED_CHECKS (a runtime error aborts a test function while PASS prints):
Godot.exe.exe --headless --path . --script core/windowwall/window_wall_selftest.gd
# Points of interest / KML import (offline — core/poi/): KmlPoiParser over the
# shipped Google Earth export of the Mount Vernon property (testdata/
# compoundity.kml: 11 pins + 4 lines, CDATA HTML descriptions, CascadingStyle
# + StyleMap colours, aabbggrr → #rrggbb), a MultiGeometry / Folder / polygon-
# with-hole case, the KMZ path through a zip written to a TEMP folder,
# PoiLayer records (stable ids, re-import REPLACES a source, file round-trip
# against a TEMP path), the WGS84 → site-metre mapping pinned by hand against
# GeoMath (the House pin ~7 m east / ~7 m south of the site centre), the
# WorldPaths "poi" kind (legacy path byte-identical, dir-world path), and
# PoiRuntime building one marker per record on a flat ground callable.
# ⚠ Coordinates are 64-bit float Arrays, NEVER Vector3 (float32 rounds a
# longitude by ~1 m — the whole error budget); the 1e-9° pins catch it.
# Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/poi/poi_selftest.gd
# Points of interest end to end (WINDOWED, needs a REAL TerrainLoader map —
# mtvernon, where the fixture's pins fall on the actual property): imports
# the fixture through the loader's real import path and asserts 15 markers,
# the House pin at GeoMath's xz AND on the ground, nothing off-map, the Site
# Plan marker list matching the 3D pins, Go landing the player beside a pin,
# hide emptying the plan list, re-import replacing not doubling, the file on
# disk; opens the REAL Terrain options panel and asserts the KML block's
# title AND the whole panel sit inside the viewport (the block used to be
# unfindable at the bottom of a column that ran off the screen, and the panel
# itself was 84 px past the right edge) with the pin rows listed; shoots the
# panel + a street + aerial + close-up PNG. Byte-restores the site's poi file
# and the show_pois pref:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=poi --shots-dir=<label> --quit-after-capture
# Maps vs worlds (offline — core/worlds/, see "MAPS vs WORLDS"): legacy-path
# IDENTITY for every routed subsystem with no world active, the coverage
# guard (no new "user://maps/" literal outside the MAP allow-list), dir-world
# paths incl. a stale coordinate never landing on the world's file, the
# sealed switch, WorldStore against a TEMP root (migration idempotent + never
# moves a file + adopts the old autosave, duplicate legacy -> dir byte for
# byte, rename, newest-first, trash, no resurrection), WorldAssets vendor /
# restore / remap, the cache-token boundary (8.3252 vs 48.3252) and the
# picker's coordinate parser + reverse-geocode label. EXPECTED_CHECKS;
# --import first:
Godot.exe.exe --headless --path . --script core/worlds/world_store_selftest.gd
# Asset packs (offline — core/sharing/, see "Asset packs"): TEMP sender /
# friend / project roots. No secret reaches a pack (sentinels searched in every
# DECOMPRESSED entry), no code even inside an art folder, the reader refuses a
# whole pack for one unsafe entry (zip-slip, absolute, .gd, .tres / raw .cfg as
# user data, unlisted, missing part, newer format), a round trip lands as NEW
# worlds in DIR layout (a legacy world too) byte-identical, map cache matched
# at each cache's own coordinate precision, keep-both libraries, opt-in +
# backed-up settings, the prefs codec keeps ints ints, damaged files reported,
# multi-part split. EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/sharing/asset_pack_selftest.gd
# Asset packs end to end (WINDOWED, sandbox): exports the running world + its
# map data + presets/music through the REAL Share modal, installs it again by
# emitting the window's files_dropped, asserts every data file byte-identical,
# then PLAYS the imported copy and diffs its fingerprint (props, lights, camps,
# tiles, graph ids + wires). --pack-out=<path> keeps the pack:
tools\harness.ps1 -World mtvernon -Capture assetpack
# The friend's side: an EMPTY user folder (-EmptyUser), the pack dropped on the
# launch hub ("menu" capture kind: no world is launched), installed, played:
tools\harness.ps1 -EmptyUser -Capture assetpack-import -UserArgs @("--import=<pack>")
# Settings from the LAUNCH HUB ("menu" kind, no world): a REAL click on the
# header gear opens the settings modal in hub_mode — exactly
# TimelineSettingsPanel.HUB_PAGES (Lighting as the graphics-preset page,
# Interface, Player, NPC, Stars & Planets, Window Wall), every nav entry on
# screen, UiAudit per page (0 errors at 1080 and 720), a graphics-quality +
# star-brightness change with NO Main landing in sim_settings.cfg /
# star_calibration.cfg (SimSettingsController's hub store, restored after),
# Esc closing it. ⚠ The hub's own Esc handler quit the game while a modal
# was up until this capture caught it. Also the Controls page end to end:
# a REAL click on the help row's key chip + a REAL F6 press rebinds it (the
# InputMap, the file, HarnessInput.action_label = the tour's title cards,
# and the F1 overlay's label all read F6), ↺ restores F1 and empties the
# file:
tools\harness.ps1 -Capture hubsettings
tools\harness.ps1 -Capture hubsettings -UserArgs @("--window-size=1280x720")
# Worlds end to end (WINDOWED, needs a world: --scratch-world copies the most
# recent world on the map into a throwaway one, deleted on quit; --world=<name
# or id> runs inside a real one). Builds a prop + a light, freezes the clock,
# saves, Exits to menu, Plays the world again through WorldSession.launch and
# diffs the whole WorldSession.fingerprint (player pos/yaw/pitch, clock,
# graph ids + connections, per-habitat people + morale, props, lights, camps,
# tiles, peak total, battery, festival mode), then starts a NEW world on the
# same map and asserts it is empty (props/lights/camps/tiles/peak 0, graph =
# PBI nodes only) while the first world's files are byte-identical:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=walton --scratch-world --capture=worlds --quit-after-capture
# Shared crosshair-ladder self-test (offline — SiteTargetPicker, the ONE
# ray→target resolver used by BOTH the first-person crosshair and the
# settlement view's mouse, so the two provably agree. Pins the ladder order,
# the `want` filter, and — the invisible one — the MINIMUM ANGULAR PICK RADIUS:
# at 500 m a person is sub-pixel and an exact sphere test is unclickable, so
# the radius grows as t·tan(0.6°) past a ~52 m crossover. Also pins its own
# check COUNT, because a Godot runtime error aborts the enclosing test function
# while the suite still prints PASS — this file lost a whole function to that):
Godot.exe.exe --headless --path . --script gameplay/site_target_picker_selftest.gd
# NPC spacing probe (offline, NOT a selftest — the measurement behind the
# 2026-10-25 realism pass): two days of a 24-person camp in BOTH tiers on the
# crowd selftest's synthetic site; per tick, standing pairs under 0.3 / 0.6 /
# 0.9 m, sleepers on one spot, walkers passing through each other and
# travellers bound for one spot, with the activity pairs behind the worst
# bucket NAMED. Expect "< 0.3 m: 0" in both tiers on both routines; a new
# generator that stacks people shows up here by name. --routine=default too:
Godot.exe.exe --headless --path . --script tools/diag/npc_spacing_probe.gd -- --days=2 --routine=festival
# Tier morale under the step-aside switch (NpcAgent.loiter_enabled on / off,
# last-day averages + loiter counts; how the equivalence pin was moved to a
# day average):
Godot.exe.exe --headless --path . --script tools/diag/npc_tier_morale_diag.gd
# Peak Experience self-test (offline — NpcPeak rules, PeakField onset /
# contagion + the player multiplier / CHARGE (Exp(1) thresholds, feeding,
# leak) / hold + GRACE_H / scrub-freeze / catch-up clear / score + its
# file, both tiers' "vibing" test, NpcPeak.pack_mood round trip. Carries
# EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script core/population/npc_peak_selftest.gd
# Mo-cap spice self-test (offline — NpcMocapSpice moments / chances / picks,
# NpcStickMocap.solve_points on synthetic poses, and with the NPC pack
# installed the seamless fade back to the procedural pose. EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script core/population/npc_mocap_selftest.gd
# Cosmetic clock self-test (offline — SimFxRate, core/sim_fx_rate.gd: the ONE
# rate curve fire, crowd figures and placed lights animate on — 0 when paused
# or scrubbing back, linear below 1x, sqrt above, capped per system; the
# integrated clock never jumps on a speed change. Carries EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script core/sim_fx_rate_selftest.gd
# Clock-claim stack self-test (offline — the ordered claim stack that replaced
# nine private `_saved_time_scale` fields; covers re-claim-does-not-stack,
# order-independent release, exclusive refusal, partial-claim fall-through, and
# a direct reproduction of the snowglobe-over-CSV-playback bug where the clock
# ended up stuck paused. Extend it with every new clock owner):
Godot.exe.exe --headless --path . --script core/clock_claims_selftest.gd
# InputMap self-test (offline — parses project.godot's [input] section, NOT
# InputMap.get_actions() which also carries Godot's built-in ui_* defaults):
# fails on a key bound to two actions (whitelist intentional pairs in
# ALLOWED_OVERLAPS with the file:line that disambiguates them), on an action
# with no events at all (a dead action orphans every handler keyed to it), and
# on a key event bound via `keycode` instead of `physical_keycode` (which drifts
# on AZERTY/Dvorak). Also pins the player's REBINDING file
# (core/input_overrides.gd, Settings → Controls, user://input_overrides.cfg:
# `action = "key <physical> [ctrl] [shift] [alt] [meta]" | "mouse <n>" |
# "none"`): encode/decode round trips, malformed lines dropped not applied,
# a TEMP-path file round trip, apply replacing key + mouse events while the
# joypad event stays, ↺ restoring project.godot's events exactly, and the
# parser agreeing with this file's own. Run it after ANY project.godot
# [input] edit:
Godot.exe.exe --headless --path . --script core/input_map_selftest.gd
# UI compile smoke + duck-typing contract guard (offline — sweeps scenes/ui/,
# crisis_events/ and scenes/ui/location_picker/; these scripts mostly have NO class_name,
# so Godot never parses them at import and a GDScript error surfaces only when
# a player opens that panel). Also asserts the method surface other subsystems
# call BY STRING still exists — terrain_loader.gd calls `_exit_mode` at ~10
# sites with no has_method() guard, so a rename there is a hard runtime error.
# Catches parse/identifier/preload/autoload errors, NOT node-path misses or
# layout — those still need the windowed --capture harnesses:
Godot.exe.exe --headless --path . --script scenes/ui/ui_compile_selftest.gd
# HUD layout solver (offline — HudLayoutCore, see "UI foundation"): no two
# placed panels overlap, everything stays above the timeline and clear of a
# claim's insets, claims tuck / hide their regions, an overflowing column
# tucks its LOWEST-priority panels first, an untuckable bottom-left panel
# (the ride dashboard) tucks the top-left column rather than spilling onto
# the timeline, the bottom region stacks upward. EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script scenes/ui/hud/hud_layout_selftest.gd
# Player-facing text helpers (offline — UiText: plurals incl. irregulars,
# counts, SI-prefixed numbers with units, durations, percentages, id →
# display name, fit-with-ellipsis). EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script scenes/ui/ui_text_selftest.gd
# Unified edit toolbar data layer (offline — scenes/ui/toolbar/): the tool
# registry, PER-TOOL parameter isolation (the whole reason the toolbar exists —
# the legacy T dock kept ONE global radius/strength/hardness, so tuning Smooth
# silently moved Raise), per-tool shape memory, option_specs row model,
# ConfigFile + real-file persistence round-trips (against a TEMP path, so a
# player's user://toolbar_prefs.cfg is never touched) including a corrupt /
# stale-build config, and the ShapeGestureController ladder (circle/rect/lasso/
# polygon, the Esc peel, the radius cap, lasso pixel-threshold sampling).
# Pins the one cross-file coupling that would fail SILENTLY: VEG_FAMILIES
# stores VegetationPaint.Preset values as LITERAL ints (so the model still
# loads with a stale global class cache), and this asserts they still match the
# enum — reorder it and every scatter paints the wrong family. Carries its own
# EXPECTED_CHECKS count, because a Godot runtime error aborts the enclosing
# test function while the suite still prints PASS:
Godot.exe.exe --headless --path . --script scenes/ui/toolbar/toolbar_selftest.gd

# Painted camp areas (offline — core/camps/): every household template fits its
# style's lattice cell (the property that makes neighbouring households
# independent), a ROADLESS field fills (the regression the module exists for —
# BrcCampGenerator places nothing farther than plot_depth from an OSM street),
# vehicles within the alignment jitter of the camp heading with ONE parking
# direction per row, no two footprints overlapping in any style, nothing outside
# the outline or inside a hole, GROW STABILITY (enlarging a camp leaves every
# existing structure byte-identical — the lattice is world-anchored and seeded
# per cell, never from a running RNG), slope/exclusion rejection, the layer's
# paint = union / erase = difference algebra incl. a cut that splits one camp in
# two, file round-trip of every record key, the Plots subdivider, and
# CampAreaRuntime's per-camp nodes. Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/camps/camp_area_selftest.gd
# Festival placement (offline — core/camps/festival_*): the usable-ground
# raster (slope + exclusions + holes + locked lots), the equal-USABLE-area lot
# partition along a road (count + area modes, cross lanes, curved road, double-
# loaded block, corner lots, grow-stability in area mode, id inheritance by
# overlap, locked lots never move, no-road lattice fallback), the roster
# assigner (largest-first best-fit, features/styles honoured, manual pins
# untouched, deterministic) incl. the people-per-m² derived from the camp
# templates, the placement layer's file round-trip, the road helpers, the
# festival-road heading preference, and TerrainSculptOps.level_polyline.
# Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/camps/festival_placement_selftest.gd
# Light population tier (offline — CrowdCohort / CrowdFocus / NpcTierConvert):
# determinism (two 40-person 2-day runs trace-identical), mass-exact billing
# at two cadences, a daily loop, the EQUIVALENCE property (one 24-person camp
# run 3 days FULL vs LIGHT: water/food within 6 %, morale within 0.08 and one
# band), queues at a full space, venue billing to a bound tank, scrub-back /
# catch-up contracts, the compact snapshot round-trip, tier conversion both
# ways, the focus policy incl. hysteresis, the departure cascade, and a
# 2000-person day bounded in time. Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/population/crowd_cohort_selftest.gd
# Festival camps on the graph (offline — CampTemplates stamped through
# GraphComponentDefs + make_unique, five promoted boundary ports, CampLedger's
# closed/importing/surplus/open classification, live demand overrides, wired
# ports leaving the badge, the festival sum). Carries EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script system_graph/camp_ledger_selftest.gd
# Simplified per-camp energy (offline — CampPowerModel: the style defaults,
# the night-lighting load term + inverter cap, charge/drain through the SAME
# EnergyTimeline.step_soc the player's battery uses, the floor + unserved
# load, two camps stepping independently, the daily balance):
Godot.exe.exe --headless --path . --script core/power/camp_power_selftest.gd
# Camp provisioning + the testing switches (offline — CampProvisioning rates
# / presets / supply sizing / days remaining / space requirements, the
# PopTestPrefs file round trip against a TEMP path, and every guardrail the
# switches turn off, each asserted OFF and ON: the flow engine's IDEAL
# SUPPLY (a habitat with no tanks is not starved; the shortfall is stamped as
# ideal imports and CampLedger reads it as IMPORTING / EXPORTING), both
# tiers meeting a need with NOTHING tagged (the guarded camp walks out before
# the day ends — sample blocked needs DURING the run, not at the end), the
# registry's capacity switch, no departures, the muted settlement log):
Godot.exe.exe --headless --path . --script core/population/camp_provisioning_selftest.gd
# Festival vibe (offline — FestivalVibe over per-camp summaries: headcount
# weighting, histogram sum, blocked share from CRITICAL needs only,
# component ordering, the headline, the 24 h trend ring incl. scrub reset):
Godot.exe.exe --headless --path . --script core/population/festival_vibe_selftest.gd
# Festival-scale crowd BENCH (WINDOWED): seeds --count=N people as
# ceil(N/100) pop-driven habitats + shared spaces, runs ~450x with the graph
# closed, and prints median fps / frame / render CPU+GPU ms, the per-section
# cost (npc_population / npc_dots / npc_host / crowd_render / flow_engine),
# draw calls and node count, a GPU probe of whether MultiMesh INSTANCE_CUSTOM
# / COLOR survive at float32 (Forward+ here: both float32), the first slots'
# heights against the ground raycast, and four PNGs aimed at the BUSIEST
# 10 m cell of people (the centroid of a crowd spread over six spaces is the
# empty middle of the field — the first shots looked at nobody). Runs on the
# soak map or any user map (`--user-map=walton` is the festival target site;
# the soak map is GPU-bound on its own at ~70 ms, so read deltas there).
# ⚠ PerfMonitor.snapshot() used to divide the section ms by 1000 a second
# time, so every bench median before 2026-10-06 printed 1000x low — the F3
# HUD was right (npc_host ≈ 220 ms for 100 NpcAvatars, ~2 ms per figure):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=walton --capture=crowdbench --count=1000 --shots-dir=<label> --quit-after-capture
# First-person ambient bed (offline — AmbientMix, the ONE mix rule the
# AmbientBed node follows, + AmbientSynth's procedural loops): wind / rain /
# stream / birds each monotonic, bounded, continuous in its input (Beaufort
# wind, the met rain classes, Manning velocity × distance, DaylightModel ×
# forest with the rain + wind hush and the midday hush), the gates (night,
# bare field, paused, away from first person, volume 0) silencing exactly
# what they should, the master scaling every layer, the loops SEAMLESS
# (join step ≤ the largest step inside), bounded, told apart by brightness
# and deterministic, a chirp short and silent at both ends. EXPECTED_CHECKS;
# --import first:
Godot.exe.exe --headless --path . --script core/audio/ambient_mix_selftest.gd
# The bed on a REAL world (sandbox, read-only): Main made it, the live
# inputs come off the weather / sun / forest count / nearest stream, forced
# inputs drive the players (gain → volume_db, playing, calls on the chirp
# players), a paused clock and the open graph silence it, the Settings
# volume at 0 silences it:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/ambient_bed_probe.gd
# Settings → Environment horizon + haze (sandbox): every control reaches its
# sky uniform / the fog, the matched horizon == fog_light_color, a
# persist_settings → _load_persisted_settings round trip, the reset:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/horizon_settings_check.gd
# Festival look studio (WINDOWED, not a selftest): a lit FIREPIT, crowd
# figures in the DJ (1 m up on a box) / cheer / rave / talk / sit poses with
# glow sticks, and three stick figures with glow bands — at night and by day,
# user://festival_look_{night,day}.png. The way to judge the firepit flames
# and the glow bands; a settlement-view shot is too far out to tell:
Godot.exe.exe --path . --windowed --resolution 1280x720 --script core/population/festival_look_diag.gd
# Ground / burn pose studio (WINDOWED, not a selftest): the cross-legged,
# lounging, kneeling (sandman), redirect, fire-flow, gaze, chair-sit, lying
# and work poses on BOTH bodies (crowd shader + stick figure), side and front,
# as one grid, user://ground_pose_grid.png. The crowd figure faces +Z and a
# NEGATIVE limb_angle swings a limb FORWARD — this grid is the only place a
# backwards leg shows (SIT and WORK were mirrored for months):
Godot.exe.exe --path . --windowed --resolution 1280x720 --script core/population/ground_pose_diag.gd
# Placed vehicles + third person end to end (WINDOWED, SOAK scene is fine —
# no TerrainLoader needed): places Appa, gets in through the crosshair
# Interact path, drives, switches to third person and asserts the chase camera
# is BEHIND, gets out (step-out distance, record saved, collision re-baked),
# walks in third person (the body turns to the camera's heading), then the
# tool bus, then back to first person (arm home exactly). Byte-restores
# user://player.cfg and removes what it placed:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=walton --capture=vehicles --shots-dir=<label> --quit-after-capture
# THE BEAT (offline + ~22 s of real audio — the headless Dummy driver
# mixes): BeatGrid's virtual set (phrase / breakdown / build / drop timing),
# BeatTracker on a synthetic set (tempo within 1 BPM, kicks on whole beats,
# breakdown, the drop found AND known 3 s before it is heard, 174 not halved,
# 92 not doubled), StageBeat lookups + extrapolation + the light levels, the
# crowd shader / project.godot mirror constants, and a generated kick track
# through StageMusic's REAL analysis bus. Run it --windowed for a real
# driver's timing (128.1 BPM, the drop within 20 ms; Dummy is skewed ~0.6 %).
# Carries EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script core/population/stage_beat_selftest.gd
# Beat look studio (WINDOWED): crowd + stick figures (rave, dance, sway, DJ)
# mid-groove, in the run-up to a drop (hands up, the DJ's arm held up) and on
# the drop (arms up, the jump): user://beat_look_{groove,runup,drop}.png:
Godot.exe.exe --path . --windowed --resolution 1280x720 --script core/population/beat_look_diag.gd
# Vehicle + player-body studio (WINDOWED, not a selftest): every catalog
# vehicle as placement + riding build it, with a red bar on the rider's
# FORWARD (the vehicle's front must point the same way) and its built size
# printed; then the player's detailed figure in idle / walk / run / rising /
# falling / drive / EUC / aim. user://vehicle_look.png + player_pose_grid.png:
Godot.exe.exe --path . --windowed --resolution 1280x720 --script gameplay/vehicle_look_diag.gd
# Crowd renderer studio diagnostic (WINDOWED, not a selftest): three crowd
# figures in an empty grey studio rendered FIVE ways — plain material with
# cull_back / cull_disabled, crowd_figure.gdshader as shipped / with culling
# patched off, and the card shader — counting the pixels each puts on screen
# and saving user://crowd_diag_<variant>.png. Separates "the shader is wrong"
# from "the mesh is wound inside out" from "the game is gating it":
Godot.exe.exe --path . --windowed --resolution 640x480 --script core/population/crowd_render_diag.gd
# Festival end to end on Walton (WINDOWED, needs a TerrainLoader map): road +
# zone cut into ~24 assigned lots → one camp compound per lot (habitat,
# tanks, power model) → venues with a 20:00–02:00 stage set, temple, center
# camp, two portapotty banks + a water station BOUND to graph tanks → one
# sim-day at 720x with the graph CLOSED → cut the water → the settlement
# view's five zoom stops over the crowd. Asserts what a PNG cannot: stage
# occupancy inside vs outside the set, L/person/day off the camps' own water
# stores, blackwater landing on BOTH bound tanks, both tiers running, every
# camp with a power state, the ledger's headcount, the vibe falling and
# naming thirst, per-stop ms + draw calls. --count=N scales the headcounts.
# Snapshots and byte-restores camp / placement / spaces files + the graph
# autosave; strips its cap_fest_* items and the camp compounds:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=walton --capture=festival --shots-dir=<label> --quit-after-capture
# Crowd POP-IN probe (WINDOWED, Walton): festival mode at 20:30, the camera
# at street height over the stage crowd; every frame every person within 70 m
# is checked through NpcPopulationHost.drawn_position — VANISH / APPEAR /
# JUMP (faster than a catch-up glide) with cause (tier, hero, camp just
# switched tier). Phase A still camera, phase B camera hops. --light=on|off
# overrides the distant-crowd setting for the run, --ts=N the clock. Expect
# zero events of every kind; byte-restores what festival mode touches:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=walton --capture=popin --ts=60 --light=off --shots-dir=<label> --quit-after-capture
# Festival MODE data layer (offline — FestivalSeedLayout + the PopTestPrefs
# EASY OVERRIDE): painted-camp headcounts (the assigner's own density,
# floored/clamped, style-aware), the lot-shaped records the graph sync eats
# (free camps + orphans only, never a live lot's camp), the venue plan (a
# sleep + kitchen per camp as DISTINCT area targets, shared venues sized
# from CampProvisioning.requirements, searched outward from the camps'
# centroid, clear of every camp and past the world veto, the stage carrying
# its 20:00–02:00 set, every label prefixed), and the override reading ON for
# all four guardrails while the SAVED flags stay untouched. Carries
# EXPECTED_CHECKS; --import first. ⚠ A GDScript lambda captures locals BY
# VALUE — a counter a Callable increments must live in an Array:
Godot.exe.exe --headless --path . --script core/camps/festival_seed_layout_selftest.gd
# The festival calculator + loop challenge (offline — CampFlowMeter: mass-
# exact at any step, scrub-back truncation, a jump not metered, per day /
# per person / pee + poo / off-site imports, dict round trip; CampLoopClosure
# over a real CampTemplates camp: 0 when open, suggestions, `apply` wires a
# Greywater Filter to the camp's own tanks and greywater closes).
# EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/population/camp_flow_meter_selftest.gd
# Festival set-up + site editing on a world whose marker MOVED (sandbox,
# Bombay Beach): Move festival to marker, Clear seeded after a reload, the
# setup card's 6 named camps of exactly 10, REAL clicks in the festival view
# (select, drag a camp 20 m with its beds, Ctrl+Z, draw a space), the same
# editor in Site Plan, own / shared / infinite supply, the meter, a loop
# closer:
tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/festival_setup_check.gd -Label festival_setup -Timeout 1200
# A camp whose water runs out STAYS starved (sandbox, Walton): every camp
# tank cut to 0, the starved flag held on all of them while people stop
# drinking, and thirst blocks once they wake. A pop-driven habitat used to
# count a dry tank as starved only while someone drew on it, so the flag
# flipped every tick or two (at most 8 of 40 camps starved at once):
tools\harness.ps1 -World walton -RunScript res://tools/checks/camp_water_cut_probe.gd -Timeout 900
# Venue choreography + capacity sharing (offline — VenueCrowd, NpcVenueState,
# the AUTO capacity in SpaceRegistry / NpcVenueChoice): the effigy's phases
# as a pure function of a FireTimeline record (idle → burning → circling for
# CIRCLE_H → after) with the phase-end caps; the burn RING (rows fill front
# to back, every seat outside the safe radius, rings further apart and seats
# looser the further out, no two seats colliding, front row sits/lies, back
# rows stand); the circle dance (constant lane radius, angle INCREASING with
# time = counter-clockwise from above, lanes shearing, ~half dancing); the
# embers spiral; the stage FAN (every slot in FRONT of the front edge, found
# from the footprint, facing the camps, densest at the front, raving only
# while a set is on); a set is a pull, the burn an EVENT; AUTO capacity never
# fills, claims never refuse, six arrivals share two equal restrooms, a
# crowded nearer space loses to a farther empty one, an explicit cap still
# refuses; AUTO venues pay no room penalty and pull beats taste. Carries
# EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/population/venue_crowd_selftest.gd
# Festival MODE end to end on Walton (WINDOWED, needs a map with painted
# camps). After the mode asserts below it ALSO drives the two venue
# choreographies through real sim time at 180×: jumps to 21:00 and asserts a
# crowd (≥20) stands in FRONT of the bass stage's speakers, every one raving;
# then writes a burn record onto the tagged Effigy prop (FireTimeline.make,
# synced through FireNode) and asserts the lit effigy is BURNING + an EVENT,
# ≥40 gathered with NOBODY inside the safe radius, front rows seated/lying
# and back rows standing, that after the collapse the phase is CIRCLING with
# ≥70 % of the movers' bearings increasing counter-clockwise (sampled ONE
# circle step apart — a lap is 0.1 h, so a longer gap wraps past 180° and
# reads clockwise), and that 45 min later the dance is over and everyone at
# the embers claps or stands. Clears the burn record again. PNGs 04–07.
# Drives Main.open_festival_mode and asserts the easy override is on
# with the player's saved testing flags untouched, every populatable painted
# camp got a headcount and became a compound with ONE pop-driven habitat, no
# lot is left unassigned, every required space type is tagged with one seeded
# sleep area per camp and the stage's set on at 21:00, the settlement view
# opened over the camps' cluster at a framing height, people exist for the
# headcounts and MOVE over ~4 sim-hours with a ZERO blocked share, leaving
# hands the guardrails back and keeps the camps, and clear_seeded removes
# exactly the prefixed venues + every festival headcount. Three PNGs
# (open / evening / block). Snapshots and byte-restores camp / placement /
# spaces files, the graph autosave and npc_display.cfg:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=walton --capture=festivalmode --shots-dir=<label> --quit-after-capture
# Site deployment schedule (offline — SiteDeploySchedule record: add / move /
# remove, forward-crossing `due`, backward-crossing `rewound`, phase_at, the
# JSON round trip; SiteDeployPlanner: labour from the packed mass, the rows
# per structure kind and action with their effects and deps, nearest-crew
# assignment under the board caps, the ALL HANDS pick; a real NpcChoreBoard
# taking a deploy plan + the SiteProject rollup; the camp reveal count and
# the camp record's `built` flag; the staging site's stage_state / part_seat,
# the load-out row, the manual stamp). EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/population/site_deploy_selftest.gd
# The same end to end on Walton (sandbox): three packed kits + festival mode,
# "pack everything now" strikes every camp (no beds) and packs every prop, a
# DEPLOY event the clock crosses pins crews ALL HANDS, projects land, people
# are seen DOING them, a camp seen half-pitched, every kit unpacked + every
# camp standing at the end (the shiftpod cut into parts and laid out by its
# staging site, the dome staged by its builder); a scrub back past the event
# puts it all back and re-crossing fires it again; a PACK-UP event with the
# crew carries the crates to the container's door; the file; one crate
# handed to the crew on its own (queue_item):
tools\harness.ps1 -World walton -RunScript res://tools/checks/site_deploy_probe.gd -Label site_deploy -Timeout 1500
# The LOOK of per-part staging, close up (sandbox, ~2.5 min): three kits on
# open ground near the marker handed to the crew one by one (queue_item), the
# settlement camera 40-55 m over them, shots of the yard laid out, the dome
# half up by its builder, the shiftpod seating, everything standing:
tools\harness.ps1 -World walton -RunScript res://tools/checks/site_deploy_look_probe.gd -Label site_deploy_look -Timeout 900
# J Light Studio (offline — core/placed_lights/): layer v2 -> v3 migration
# (radians -> degrees, type -> kind, identical looks share ONE auto style), the
# built-in map path staying the v2 path, linked styles (style edit restyles
# every user, overrides survive / prune / revert, make_unique, push to style,
# remove_style keeps the look), groups + duplicates incl. string pins, string
# geometry (sag below the chord, half-spacing bulb inset), LedEffects (rainbow
# moves one bulb per 1/speed s, theatre chase lights n/gap) + the
# led_bulb.gdshader mirror constants, gizmo maths round trips, service
# undo/redo + node refresh, and the graph-load contract (no load until "Add to
# graph", idempotent, never a power_consumers member). EXPECTED_CHECKS; it
# byte-restores the bare-scene lights file. --import first:
Godot.exe.exe --headless --path . --script core/placed_lights/placed_lights_selftest.gd
# Light Studio end to end (WINDOWED — REAL input events: J through Main, mouse
# clicks / drags / a double-click pushed through the viewport): omni + spot
# placement on a surface (a ground-clicked spot hangs 3 m up aiming down), a
# gumball X-arrow drag and yaw-ring drag, a 4-pin string finished by
# double-clicking its last pin, a pin drag with the String tool still active,
# Ctrl+drag moving the WHOLE string rigidly, Shift+drag duplicating it into the
# source's group, a rainbow chase advancing, Add to graph making exactly one
# load, a moving-head beam sweeping on its program, a 7-beam laser fan, a
# neon-flex tube, J closing the dock. Run it on --user-map=walton too: it also
# asserts no IK sphere shows and no camp highlights with J closed and no
# modifier held. Byte-restores the map's lights file and removes the graph load:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=walton --capture=lights --shots-dir=<label> --quit-after-capture
# Legacy street-following camp generator (offline — BrcCampGenerator, still what
# auto-generate-on-load and the Shift+C dock use; CampMeshLibrary borrows its
# mesh builders, so this must keep passing):
Godot.exe.exe --headless --path . --script vegetation/camp_generator_selftest.gd
# Painted camps end to end (WINDOWED, needs a REAL TerrainLoader map): scores a
# grid of candidate sites with the real generator + the loader's real
# exclusions, paints an RV camp on the best one, and asserts what a PNG cannot:
# worst RV deviation from the camp heading (DUMPED; must sit inside the jitter),
# every structure seated on ground_height_at (the edit-aware surface), growing
# the camp keeps every RV where it stood, a zone splits into filled plots, a
# fresh attach reproduces the same counts (= what a reload does), erase + undo.
# Shoots day and night sets. Snapshots and byte-restores the map's
# camp_areas_*.json, so a run never leaves camps on the player's site:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=camps --shots-dir=<label> --quit-after-capture

# Fire (offline — FireTimeline + FireNode surface mode): the record maths
# first — burn hours net of extinguisher HOLDS, the phase ladder (climb →
# 3 s collapse → pile aged from the landing), the fuel estimate (a tonne of
# fuel ≈ 6 h of bonfire; a known PackedSpec mass beats the surface guess),
# put-out FREEZING the state at that hour while an earlier hour still burns —
# then ONE FireNode driven by MOVING THE CLOCK on an inch-unit, Z-up rig:
# ignition in the bottom quarter of the WORLD box, a monotonic climb, flames
# from surface points, the char overlay following the front, a sprayed hold
# that delays the collapse by exactly its length, the collapse into a
# FireAshPile on the base footprint (whoosh on the way down), bonfire →
# embers → ash — and then BACK: scrub to the bonfire (flames again), to the
# climb (the structure stands, charred, no pile), to before the ignition
# (clean), forward again (the whoosh re-fires). Carries EXPECTED_CHECKS.
# Headless has no renderer, so the three shaders are only proven windowed:
Godot.exe.exe --headless --path . --script crisis_events/fire/fire_burn_selftest.gd
# Placed-prop editor end to end (WINDOWED, needs a REAL TerrainLoader map,
# REAL input events through the viewport): a seeded shiftpod opens the dock
# in the TOOL-OVERLAY tier (never a modal), the gumball's X arrow moves it
# along X only and the yaw ring turns it (the record is read back — note
# get_prop_record returns the LIVE dict, duplicate it before comparing),
# Duplicate adds one record, the two-click Delete removes it, a StarShade
# opens THE SAME editor with its designer as a button and can be deleted from
# it, and the Fire section: a planned climb time lands on the record before
# any fire, Ignite lights it with THAT duration (estimate kept as auto), the
# clock past the collapse shows the pile, the clock scrubbed BACK stands the
# structure up again, before the ignition it is clean, Restore forgets the
# fire. Removes everything it seeded:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=propedit --shots-dir=<label> --quit-after-capture

# Night-sky star field self-test (offline — core/astronomy/): StarSkyMath's
# GMST pinned to Meeus's worked examples 12.a/12.b, the equatorial BASIS form
# of RA/Dec -> world direction against the independent hour-angle/alt-az
# derivation (the sky shader used to read the texture latitude off the rotated
# WORLD vector — the zenith as the texture pole, only right at latitude 90°;
# this pin is what keeps the shader and the reference-star markers on one
# sky), a line-for-line GDScript MIRROR of the shader's star block against the
# pure UV mapping (edit sky.gdshader -> edit StarSkyMath.shader_uv_for_direction
# -> or this fails), the "one sky" timezone contract (the DirectionalLight sun
# and Meeus SPA at the clock's own UTC point at the same sun — they were ~4°
# apart at Bombay Beach while the sun used the rounded meridian and everything
# UTC-based used the exact longitude), and the shipped map + sidecar
# (assets/sky/starmap_equirect_8k.{png,json}: 2:1, pole rows black, fit
# residual <= 8 px). Carries EXPECTED_CHECKS; run --import first:
Godot.exe.exe --headless --path . --script core/astronomy/star_sky_selftest.gd
# Daylight model self-test (offline — core/env/daylight_model.gd, the ONE curve
# the DirectionalLight sun/moon, the ambient, the vegetation night signal, the
# glow AND sky.gdshader's daylight_fraction() all follow). Pins what a PNG
# cannot: the sunrise is CONTINUOUS — beam energy, beam colour, skylight and
# the vegetation signal sampled at 0.05° across the horizon with the largest
# single step asserted small (the "lightbulb" regression IS a step); the beam
# is ZERO below the horizon (the old ramp put 26 % of noon, in white, on the
# ground with the sun 5.7° down); the one-atmosphere contract (beam
# transmittance == SolarIrradiance's clear-sky DNI ratio, so what the player
# sees and what the panels make cannot disagree); measured-CCT colour anchors
# (≈2100 K on the horizon, ≈3700 K at 5°, white by 30°); and the twilight
# decades (-6° = 22 %, -12° = 5 %, dark by -21°). Carries EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script core/env/daylight_model_selftest.gd
# Star-map regeneration (NOT a selftest — the asset pipeline): run
# tools/stellarium_starmap_export.ssc in Stellarium >= 1.2 (config.ini custom
# screenshot size 8192x4096; the header is the checklist), then
#   python tools/starmap_prepare.py <screenshot.png> --note "Stellarium <ver>"
# which black-floors the export, MEASURES the registration from the bright
# stars (RA at the left edge, RA direction, north-up — never assumed), and
# refuses to write the sidecar if the stars are not where the catalog says.
# Star-field capture (WINDOWED): parks the clock at a fixed night, shoots each
# reference star with the computed markers ON and OFF, and DUMPS per star the
# projected marker position vs the brightest texture blob nearby plus the 2 h
# rotation about the pole (Polaris still, Dubhe moved ~117 px, +30° CCW) — the
# numbers a PNG cannot prove; then the same at a southern site about the SCP:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=stars --shots-dir=<label> --quit-after-capture
# Dawn lighting capture (WINDOWED): parks the clock at a ladder of solar
# altitudes (-14° … +20°, equinox, found by bisection on the clock's own sun
# direction), shoots toward the sun's bearing and away from it at each, and
# DUMPS per step what the lighting actually did on the live nodes — beam
# energy + colour, ambient, night amount — because a single PNG cannot show a
# RATE. Asserts end to end: no beam with the sun below the horizon, energy and
# ambient monotonic through the ladder, a few percent on the horizon (not a
# lightbulb), deep orange there and white by 20°. NOTE the ambient column is
# the PLAYER'S ramp (ambient_energy_mult 0 reads 0 at every step); the header
# prints their prefs. Clock and clouds restored, nothing persisted:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=dawn --shots-dir=<label> --quit-after-capture

# Boot both maps, 120 frames each; compare errors against the known
# pre-existing set (see Known Issues). NOTE the default main scene is the map
# CHOOSER, so the bare form below boots almost nothing — pass a map explicitly
# to actually exercise one:
Godot.exe.exe --headless --path . --quit-after 120
Godot.exe.exe --headless --path . --quit-after 120 res://scenes/maps/soak_festival_2026.tscn
Godot.exe.exe --headless --path . --quit-after 120 res://scenes/maps/mars_aerial.tscn

# Per-world terrain imagery (offline — TerrainImageryPlan: the loader's tier
# tables ARE the plan's, layer keys == ImageryService.layer_key, infer_tier
# off fake cache files at a coordinate nobody plays (deleted after),
# record_for_import precedence, GPU cost, when the choice is offered;
# EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script core/terrain/terrain_imagery_plan_selftest.gd
# The same end to end on a friend's side: install a pack with
# `tools\harness.ps1 -EmptyUser -Capture assetpack-import -UserArgs @("--import=<pack>")`,
# then with APPDATA at that sandbox run
# `Godot --path . -- --world=<id> --run-script=res://tools/checks/terrain_imagery_check.gd`.
# It covers saved -> my quality OFFLINE (the cached layers load at my tier,
# the rest fall back to the saved copy) -> online -> saved again, and that
# world.json follows each switch.
# Shoreline over time (offline — LakeGauge dv parse / level at a date /
# VERTCON shift / gauge pick, WaybackCatalog config / tilemap walk /
# metadata / capture dedupe, the wayback source id + cache key; EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script core/terrain/shoreline/shoreline_selftest.gd
# The same on Bombay Beach (sandbox, network): the level at five dates and the
# water edge moving seaward, the captures listed, a pinned 2011 drape and
# follow-the-clock at 2017, shots under screenshots\shoreline\:
tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/shoreline_history_check.gd -Label shoreline -Timeout 1800
# Map extents (offline — TerrainExtents side/half + clamps + overlay cap, the
# stale-result key test against the REAL elevation/imagery key formats, the
# elevation source ladder, tiling + stitch == one request, retry delay;
# EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script core/terrain/terrain_extents_selftest.gd
# Terrain options → Apply & reload end to end (sandbox; one Overpass request):
# the new size in the loader, world record, snapshot and site meta, the SAME
# world relaunched, the resumed player on the ground:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/terrain_extents_apply_check.gd -Timeout 600
# Pallet-rack design elements on a real world (sandbox): every built-in design
# built + shot, the Door / Window / Stairs / Railing tools clicked through the
# modal's own click path, a slope bay picked on its own, close-ups:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_elements_shots.gd -Label <dir>
# Nested selection with REAL clicks: rack → deck → bay → sheet, slope →
# bay → module, Esc / click outside / breadcrumb, colour, hide, show hidden:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_nested_check.gd -Label <dir>
# A crew building a rack (offline — PalletRackBuildPlan: the Mars build
# lab's sequence on the "Build a rack bay" design with six, holds until the
# release, beams only on standing frames, high beams after it with four,
# four can't build, state_at pure; Chiba 2024 plans; the yard: every piece
# flat, none overlapping, each on the bearers or a piece under it, bundles
# set down on the ground clear of the rack and carried at hand height, the
# same on a side yard, the side picker avoiding a slope; EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script core/terrain/pallet_rack_build_plan_selftest.gd
# The same on a real world (sandbox): Plan + Rehearse clicked in the
# builder, the clock moved through the build, the rack's mesh back after;
# the yard's bearers never in the ground and every stack touching it, shots
# of the yard (00b / 00c) and the bundles set down (01b):
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_build_check.gd -Label rack_build
# Stairs with turns and flights, picked through the inspector's own Flights
# dropdown (rows shown only where they apply, flight / landing counts, the
# turn side, the landing height), a shot per shape incl. a low side view,
# and the deck's top lit brighter than its underside (the winding fix):
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_stairs_check.gd -Label rack_stairs
# Joined racks with REAL clicks and drags: a click on a faded rack edits it
# (the camera stays put), a drag moves it while the others stay, Ctrl+Z, a
# small drag snaps back onto a shared frame (Chiba 2024), the turn buttons;
# the Open bay tool on a roof deck and its drag one bay over; a slope with
# doors in both closed ends; a placed rack turned a quarter turn and applied:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_modules_check.gd -Label rack_modules
# Flat-pack furniture (offline — core/flatpack/): outlines with true arcs,
# dogbones / T-bones, mortises, the joint solver (cross-lap depths, widths,
# which part opens which way, parallel parts refused, interference), the
# SAMPLE PARITY against testdata/playatech_daybed_ref.json (12 parts, rail
# slots at 6¼/24¼/48/71¾/89¾ 6" deep, arm slots 12" / 9", three 4×8 sheets,
# all three poses clash-free), the router-ready sofa still 3 sheets, every
# type clean, wedges + per-joint overrides, MaxRects nesting, DXF/SVG round
# trip (units, bulges, layers), the builder (floor, centring, ray pick, seat
# spots) and the packed stack. EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/flatpack/flatpack_selftest.gd
# The designer on a real world (sandbox): every built-in design shot in the
# studio + sheets (+ profile for chairs), UiAudit on the open modal, the DXFs
# exported and read back, a bench and a daybed placed — tagged quiet / sleep
# with seat spots ON them at seat height — packed and unpacked, removed:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/flatpack_designer_check.gd -Label flatpack
# Dome & zome designer (offline — core/domelab/): the Goldberg–Coxeter
# construction against the published chord-factor tables (2V A 0.54653 /
# B 0.61803; 3V 0.34862 / 0.40355 / 0.41241; 4V six values) and strut /
# hub / face counts (65 / 26 / 40, 165 / 61 / 105, 250 / 91 / 160), Euler on
# Class II and III, the polar zonohedron (one strut length, a level floor,
# the helix rib through its nodes), a sphere's dip = half the central angle,
# the nexorade fit (four holes a slat, band vs rigid), plate flanges and
# folds, panel nesting, stock packing, the packed envelope, the DXF round
# trip, every preset error-free, the builder's picking; the helical zome
# (the corten GLB's 452 / 900 / 450 node for node, one strut length, five
# rhombus zones at their angles, w = 3 and stacked rhombic dodecahedra,
# every window closing, the floor cut, handedness) and the folded plates
# (section geometry, rounded openings, holes shared per edge, bolts on the
# bisector plane, corten + glass + bolts drawn, winding). EXPECTED_CHECKS;
# --import first:
Godot.exe.exe --headless --path . --script core/domelab/domelab_selftest.gd
# The designer on a real world (sandbox): every built-in design shot in the
# studio (+ sheets / hubs / schedule for a few), UiAudit on the open modal,
# the files exported and the DXFs read back, a 2V dome and a zome placed
# (height, collision, counted as shade), packed to the strut bundle and
# unpacked, the designer reopened bound to the dome and Apply growing it:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/domelab_designer_check.gd -Label domelab
# CNC gantry designer (offline — core/gantrylab/): the parts tables, the
# spec (7 kinematics, applications, shared-belt coupling, key stability
# through JSON), steps/mm against the community reference values (GT2 20T
# 16 µsteps = 80, Tr8×8 = 400, Tr8×2 = 1600), CoreXY / H-bot / CoreXZ
# inverse kinematics, the delta inverse + forward trilateration round trip
# and reach, torque → force → acceleration, belt stretch, screw critical
# speed, beam sag by hand, the G-code parser (arcs by I/J and R, relative,
# G92, grbl laser S, packed words, to_toolpath), the trapezoid planner
# (times by hand, corner speed = jerk/|Δd|, monotone sampling, step-rate
# peak), every layout's assemblies / poses / belts, every preset solving
# with no error-level check, the BOM, the graph preset, the exports, every
# sample on every preset, and the builder (frame mesh, drivers, belts, pick,
# beads). EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/gantrylab/gantrylab_selftest.gd
# Gantry parts that mate (offline — mates, snapping, stock bolt lengths,
# NEMA patterns, resize keeps distances, mirrored twins, every V-slot
# preset with no collision or belt error, the BOM counting what is drawn;
# EXPECTED_CHECKS; --import first):
Godot.exe.exe --headless --path . --script core/gantrylab/assembly/gantrylab_assembly_selftest.gd
# The designer on a real world (sandbox): every built-in machine drawn and
# shot, CoreXY A = X + Y on the live jog, the delta's carriages, the cube
# sample played through the planner (beads laid, scrub to the end), UiAudit,
# the export round trip; a CoreXY placed (record kind gantry_machine, the
# builder with its drivers, GantryRuntime attached and the GLB CNC runtime
# NOT, a cartesian_machine graph node bound), a job sent from the lab and
# run on the world clock (drivers in true mm, beads on the placed bed),
# packed → bundle, Edit gantry… rebinds, Apply re-syncs the graph node:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/gantrylab_designer_check.gd -Label gantrylab
# Solar designer (offline — core/pvlab/): the JA JAM60S20-380 data sheet
# derived from its 120 half-cut M6 cells, substrings / sample points, the
# single-diode fit passing through Vmp / Imp, bypass diodes (one shaded path =
# a substring; a half-cut module under a bottom-edge shadow keeps half; CdTe
# with no diode follows its weakest strip), two P–V peaks, parallel-string
# mismatch, the tracker by hand + backtracking, the P1000 span by hand, layout
# / strings / leads / window, every built-in error-free, the builder (winding,
# pick, tracker heads, pieces), the graph (one compound per MPPT input, strings
# inside, the controller's Voc, re-seed in place), shading, the roof plane;
# the real-module catalog (every entry Vmp×Imp ≈ Pmax and fitting its face,
# search), type switches building different meshes, the frame lip, the rack
# parts (clamp counts, BOM == drawn parts, a clamp picked from above).
# EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/pvlab/pvlab_selftest.gd
# The designer on a real world (sandbox): every built-in in the studio, the
# three tabs with UiAudit, a string painted with REAL clicks, a test shadow;
# arrays placed on the ground (graph compound, SolarUI plane, a box shading
# one module and the factor recovering), on an OSM roof (in the roof plane),
# on a placed pallet rack (moving the rack carries it), a tracker (east in
# the morning, west in the afternoon); every Type through the real picker
# (front + back shots), the face at 1.2 / 2.5 / 4 / 7 m for moiré, a search
# picking a catalog module, a REAL click selecting a mid clamp, each rack
# shot down to the part:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pvlab_designer_check.gd -Label pvlab
# Toroid designer (offline — core/toroidlab/): the torus from measures and
# back, the reference build against "Overview Toroid structure.glb" (the rib
# circle, the four rings, the inner column's bearings, the canopy's corners,
# the panels' span), every rib point on the torus, fittings by kind, the
# canopy's flat pieces (isometric unfold, one 4' x 8' sheet per half-bay,
# 144 bolts), bracing and tension lines, the solar summary, the builder
# (winding, picking, explode / assembly), the packed spec, JSON, the files,
# every built-in. EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/toroidlab/toroidlab_selftest.gd
# The designer on a real world (sandbox): every built-in shot, the section /
# sheets / schedule views, UiAudit, the rib count / outer radius / bracing /
# canopy controls, the files read back; the reference toroid placed (shade,
# collision, a 24 x 100 W 6S x 4P graph array), packed (array gone) and
# unpacked, Apply with 20 ribs re-seeding 20 panels, delete removing it:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/toroidlab_designer_check.gd -Label toroidlab
# Terrain pipeline self-test (offline, deterministic — geo math + mesh builder;
# also the pallet rack + its design elements, _test_pallet_rack_elements):
Godot.exe.exe --headless --path . --script core/terrain/terrain_selftest.gd
# Terrain seam compose diagnostic (offline, synthetic mismatch grid):
Godot.exe.exe --headless --path . --script core/terrain/terrain_seam_diag_run.gd
# Building pipeline self-test (offline — roof geometry/UVs/styles/facade
# elements/wall picking/model catalog; extend it with every building change):
Godot.exe.exe --headless --path . --script core/terrain/building_builder_selftest.gd
# Climelapse / video export (offline — the series bake, timed camera keyframes
# (ClimelapseKeyframes: pose at each key's hour, ease at the ends, no stop at an
# interior key, short-way yaw, retime/repose/round trip), the export options
# maths (frame count, even sizes, Max == the bar's Max, prefs round trip) and
# the ffmpeg frame pipe (12 frames in, ffprobe count, a decoded frame is not
# black; counted as skipped without ffmpeg). EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script core/climelapse/climelapse_series_selftest.gd
# Camera-path editor + sky options (sandbox): no keys = still, a REAL click
# on a CLIM key opens the editor, REAL ring / arrow drags, marker click,
# look through, revert, follow-the-sun preview, a weekly analemma export with
# clear sky + trails + follow stars and the world handed back:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/clim_path_editor_probe.gd -Label clim_path -Timeout 1200
# Video export end to end (sandbox): one-day selection → 🎬 dialog (range
# pre-filled) → Max → three keyframes → Preview (clock + camera claimed and
# handed back) → Export → ffprobe 361 frames 1920×1080 12.03 s → 04/12/20 h
# frames to screenshots\clim_export\ with their brightness → world restored.
# See "Video export" below:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/clim_export_probe.gd -Label clim_export -Timeout 1500
# Plant growth model (offline — VegGrowthModel, the pure calendar → size
# function, + the VegetationGrowth record facade: Chapman-Richards height
# exactly 1.0 at maturity, crown/girth allometry, the staggered life cycle
# (plateau → decline → snag → gap → regrowth) sampled for continuity, the
# growth year's spring flush incl. the southern-hemisphere half-year shift, the
# "painted grove never shrinks together" property over 500 simulated years,
# legacy birth_h migration incl. the real Walton stamp, forest-age profiles
# (mature = STATIONARY), and the shader-mirror constants parsed out of
# veg_growth.gdshaderinc. Carries EXPECTED_CHECKS; --import first):
Godot.exe.exe --headless --path . --script vegetation/vegetation_growth_selftest.gd
# Veg style store (offline — Phase 2 layered persistence: precedence matrix
# species>family>SPECS>defaults, v1→v2 migrations incl. the defaults-dump
# purge, subspecies mesh divergence, VegetationLayer sparse-delta round-trip;
# run --import first so VegStyleStore registers):
Godot.exe.exe --headless --path . --script vegetation/veg_style_store_selftest.gd
# Veg species registry (offline — Phase 5: vegetation/species/species_catalog.json
# schema + facade parity, palm/cactus builder meshes, phenology profiles
# (tropical evergreens KEEP leaves — palms used to carry deciduousness 1.0 and
# dropped fronds every winter), climate-envelope lat gates + generator weight
# filtering, food yields/harvest windows (Phase 10 feed), photocard drop-in
# hook (assets/vegetation/photocards/<id>.png or user://veg_photocards/):
Godot.exe.exe --headless --path . --script vegetation/veg_species_registry_selftest.gd
# Veg phenology (offline — Phase 6: latitude damping of the seasonal signals
# (no autumn/leaf-drop/dormancy below ~15° abs lat, full by ~35°, hemisphere
# flip still at full strength), SeasonModel.estimate_winter_min_c incl. the
# southern-hemisphere half-year window, the species cold-hardiness gate
# (min_winter_c + tolerance; NAN = latitude only, so offline keeps its forest),
# VegLeafFall's drop window vs spring leaf-out, and the VegLitterMask
# sizing/conifer-exclusion/seasonal-strength rules):
Godot.exe.exe --headless --path . --script vegetation/veg_phenology_selftest.gd
# Food forest yield (offline — Phase 10: VegFoodYield's per-polygon summary
# over the layer records + species registry, the maturity ramp (nothing below
# half size), harvest windows INCLUDING the ones that wrap the new year, and
# the property the flow engine leans on — integrating the harvest rate over the
# window returns exactly the annual yield):
Godot.exe.exe --headless --path . --script vegetation/veg_food_selftest.gd
# Veg paint dock state (offline — Phase 8: the chip row's pure data model, the
# tool/shape/species state machine over a REAL instantiated dock, and the
# per-tree Select primitives on VegetationLayer. Two traps this file exists to
# close: the dock references CursorController at parse time, so it must be
# load()ed inside _initialize (a const preload silently fails and every
# dock.call() no-ops while the suite still says PASS); and the suite runs on the
# first PROCESS frame because the SceneTree root is not inside the tree during
# _initialize, so an added child never gets _ready() and no Controls exist):
Godot.exe.exe --headless --path . --script vegetation/veg_dock_state_selftest.gd
# Veg LOD policy (offline — Overhaul v2: budget-aware tree detail distance
# replacing the old SoI rings + large-map force_far flattening; sparse maps
# keep the requested range, dense maps shrink until the worst-case near-set
# fits the tier budget, 60 m floor, grass/shrub never counted; --import first):
Godot.exe.exe --headless --path . --script vegetation/veg_lod_policy_selftest.gd
# PNW forest pass (offline — VegDeadwood plan / log seating / log mesh, the
# PNW species building real meshes, the conifer whorl layout honouring crown
# base + droop, the VegConiferBuilder (every species above ground, sprays,
# variants differ), VegMix scatter (weights, understory, determinism, cap),
# floor moss, the broadleaf sprays (exact height, no leaf under the crown
# base, a leaf form per species, species habit + the family shift, per-
# species autumn, coverage-preserving cutout mips + colour bleed, shells
# still selectable, variants, oak registered), and the VegLookBackup
# snapshot/restore round trip against a
# coordinate nobody plays, deleted afterwards). EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script vegetation/veg_deadwood_selftest.gd
# Globe tree reach + the forest look (sandbox, applies the Mt Vernon PNW v2
# fix first): species portraits (3 variants each), the Tune-look mix page,
# the painted forest in October and July, the deadwood, and the Globe lens at
# 3 zooms x 3 yaws; FAILs if any far-tier tree batch inside the SoI sphere is
# past its visibility range from the lens camera:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pnw_forest_shots.gd -Label <dir>
# Broadleaf rebuild (sandbox, applies the Mt Vernon broadleaf fix first):
# portraits of every broadleaf (3 variants, July + October), maple close-ups
# from eye level / underneath / in the crown, the painted stand July +
# October, the Tune-look maple page; FAILs unless "Show vegetation" off hides
# every plant root, the plant props and the floor moss, and on brings them back:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/broadleaf_shots.gd -Label <dir>
# V Select across both layers + Detect (offline — the per-tree look as the
# strongest resolution layer + idempotent, KEY_MAP_SPECIES beating map family
# edits for a generic species, map species store writes on a TEMP path, a
# painted per-tree look through JSON, OSM single-tree pins (look replaces,
# resize stacks, clear removes one), VegTreePick ray picks, VegColorDetect on a
# synthetic photo incl. the two-tone-sand trap, the shader glow uniform.
# EXPECTED_CHECKS; --import first):
Godot.exe.exe --headless --path . --script vegetation/veg_select_detect_selftest.gd
# The same on a real world (sandbox): a screen-ray pick of a painted and an OSM
# tree, hover marker + species glow, one-tree Tune look re-meshing that tree,
# "This world" → map override, an OSM tree's look surviving a regeneration,
# Detect preview / plant / Undo. Shots under screenshots\veg_select_detect\:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/veg_select_detect_check.gd -Timeout 900
# In-game "Restore an earlier vegetation look" round trip (sandbox):
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/veg_look_restore_check.gd
# Extreme weather (offline — core/weather/): hazard catalog + VTEC mapping, the
# HazardState algebra (blank() is the IDENTITY element, combine() commutative,
# worst-wins optics / multiplying energy), Koschmieder + IMPROVE visibility
# maths, the per-hazard severity curves (incl. a CLIFF guard comparing each
# step's ratio against the median — a previous dust curve did nothing until 0.8
# severity then collapsed 2.4 km -> 90 m), the smoke-vs-dust fine-mode
# disambiguation (both events push PM2.5/PM10/AOD the same way; PM2.5/PM10 is
# what tells them apart), the AirQualityService parser incl. a NEW YEAR window
# crossing, the risk profile from canned VTEC history + the climatology
# fallback, and AtmosphereApplier's identity guarantee — resolve(base, blank())
# returns base FIELD FOR FIELD, which is what makes "feature off => not one
# pixel changes" true. Run --import first:
Godot.exe.exe --headless --path . --script core/weather/extreme_weather_selftest.gd
# Microclimate (offline — core/microclimate/): FogDiagnosis pinned to REAL
# frozen Open-Meteo rows for Walton OR 2026-10-02/03 (testdata/), where the
# user stood in valley fog ~22–23 h → ~10–11 h: ERA5 shows it as 100 % LOW
# cloud at RH 100 % (onset/clear asserted), HRRR — what the game reads — only
# via visibility hours late, and the valley cold-pool correction pulls its
# onset back to 21–23 h. Plus scrub determinism (windowed == full series),
# rule soft-ramps + hold, "make rule from now" recurring the next night,
# nearest-match cutoff, pinned cross-fade, blend, profile round-trip incl.
# INF/NaN, physics-vs-visual corrections and the HazardState identity.
# Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/microclimate/microclimate_selftest.gd
# Microclimate capture (WINDOWED): parks the clock across Walton's two fog
# nights, DUMPS per stop the data source, dew-point gap (raw + valley), low
# cloud, model visibility, auto fog + why, fog visibility/top, and shoots a
# ground + drone PNG each; asserts fog at 23/03/08 h and none at 15 h ONLY when
# the 2026 archive loaded (else SKIP), then checks a live drawer preview.
# Read-only:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=walton --capture=microclimate --shots-dir=<label> --quit-after-capture
# Extreme weather capture (WINDOWED): shoots the settings tab through its real
# entry point, then a clear baseline and a severity ramp per simulated hazard
# from one fixed viewpoint with distant terrain in frame, plus a night shot
# (where a daylight-ungated sky tint shows up as a brown, starless sky). DUMPS
# every resolved number to console — visibility, fog density, sun tint, AOD,
# AQI, DNI/GHI — because a PNG cannot tell you whether the fog is 900 m or
# 9 km, and that difference is the whole feature. Snapshots and byte-restores
# user://extreme_weather.cfg. NOTE the scene renders non-deterministically
# (TAA), so two identical runs produce different PNGs — pixel-diffing cannot
# prove the no-op property; the selftest identity assertion is what does:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=weather --shots-dir=<label> --quit-after-capture
# Site Report metrics/data + UI-compile self-test (offline, deterministic):
Godot.exe.exe --headless --path . --script core/report/site_report_selftest.gd
# NPC population self-test (offline, deterministic — SpaceRegistry tagging/
# queries/occupancy/persistence; agent needs/FSM/nav: identical-run
# determinism, priority ladder, sleep schedule, starvation block, mass-exact
# time-averaged demand, teleport threshold, scrub-freeze, snapshot round-trip;
# Tier 2: morale bands/superlinear+blocked pressure/ceiling, supplied-vs-
# starved runs, brief-outage recovery, enrichment ceiling lift + social
# clustering, departure/contagion/collapse cascade + resilience buffer,
# weather multiplicative gating, chore board windows/claims/credit/serialize,
# chore-vs-need preemption and productivity scaling, and the v2 crew board
# (stacking claims to max_workers, quorum-gated credit incl. the v1
# credit-without-claim back-compat for single-worker chores, dependency
# holds + deleted-dep unblock, roster filter, add_plan wiring a whole
# NpcCrewPlan schedule with a shared build-site target, site rules
# night_shift/tools_down incl. persistence, haul-route storage +
# worker_index claim order = brigade station assignment; NOTE the suite must
# never reference NpcPopulationBridge — bare PerfMonitor autoload fails the
# --script compile and silently aborts the test function while PASS prints);
# SITE PROJECTS (the unified camp-lifecycle mechanic): completion-keeps-
# progress semantics (remaining()==0 for a done cycle — the re-work-loop
# fix; daily chores re-arm via _arm_cycle when next due), atomic add_plan
# refusal at MAX_CHORES(160), per-task target/effect/carry_to/haul fields,
# held pause flag, uncapped priority ordering, the chore_completed
# toast-only signal, the two-leg carry FSM (chore_leg pickup→carry_to,
# preemption leaves the crate unmoved — the move is the COMPLETION effect,
# dispatched once by the bridge's post-tick sweep with effect_done as the
# persisted fire-once flag), the carrying/carry_prop dot payload, and
# SiteProject/SiteProjectStore (status sync incl. deleted-chore=skipped,
# labour-weighted rollup, build_progress fractions for the ghost reveal,
# breakdown_spec_rows, store cap/round-trip); round 2: stage_effects
# (incremental world effects fired as progress crosses thresholds —
# due_stage_effects, fire-once per stage, completion brings stragglers due,
# persistence with fired flags), unload_spec_rows strategy split (round-trip
# carry rows vs ONE brigade crew chore whose stage effects move the crates
# while the relay line works; brigade station workers read as carrying in
# the dot payload), and the muster fixes (gathering crew chores jump the
# available_for queue; quorum patience scales with crew fraction present);
# round 3: SiteProject.breakdown_progress (the REVERSE lifecycle's visuals —
# emits ALL five element keys because _apply_build_progress defaults a
# MISSING key to 1.0, which is why the old panels-only push left the frame
# solid; beams deliberately stay 1.0 throughout since fold_pack's pack_prop
# awaits the stow sweep and the fold IS the beam visual; monotonic, and a
# design with no panels keeps its nonexistent panels whole), the LIFO unload
# row order (round-trip priorities ascend, gate above all; every set-down
# carries y_offset 0 + collision_enabled so a crate hauled off a container
# stack lands ON THE GROUND), NpcRig.role_needs_offset_curve (four lines
# pinning the carry-clip drop-in hazard: a lift MEASURES as descend and the
# offset curve would sink the figure ~0.7 m mid-pickup, so ROLE_CARRY is
# forced past classify() to take the constant path), and NpcExperimentLab
# (the sim-backed variant comparison — determinism, chunked==blocking,
# simulated never beats the planned lower bound, unmeetable quorum names
# every row at ZERO tick cost, hour-cap DNF, n/a haul rows on a non-delivery,
# signature stable under progress_h churn but tracking min_workers/roster,
# and force_strategy "" byte-identical to the unforced unload_spec_rows);
# Tier 3: nav-grid region/bake/slope-vs-steps/stamping/fingerprints, and A*
# mazes, step + drop asymmetry, staircase climbing, climb-cost detours,
# route cache/lane jitter/determinism, path following + teleport degradation;
# extend it with every population change):
Godot.exe.exe --headless --path . --script core/population/npc_population_selftest.gd
# Nested super-node self-test (offline — portal resolution, flattened connections,
# walk recursion, cascade delete, v6->v7 migration, exposed-port maintenance,
# nesting-aware PV faulting; run --import first so GraphNesting registers):
Godot.exe.exe --headless --path . --script system_graph/graph_nesting_selftest.gd
# Hydro node unification (offline — Phase B of the Hydro Lab overhaul): legacy
# type=="hydro" estimator items migrate on deserialize into processor role
# "siphon_hydro" (specs carried, DC wires remapped positive/negative →
# res_out_1_pos/neg, battery trace still counts the kW), idempotent over a
# serialize round-trip, existing siphon processors untouched. The spec-driven
# output path itself (no pond → estimator physics; run_of_river never drains)
# is pinned in resource_flow_selftest's _test_spec_driven_hydro:
Godot.exe.exe --headless --path . --script system_graph/hydro_migration_selftest.gd
# Graph COMPONENTS self-test (offline — SketchUp-style definitions: realize
# single + multi-level (StarShade tree), capture round-trip, edit-one-instance-
# updates-all with per-instance battery SOC preserved, external-wire survival on
# re-stamp, Make Unique detach, v6->v7 definitions round-trip; --import first):
Godot.exe.exe --headless --path . --script system_graph/graph_components_selftest.gd
# Freeform force layout (offline — GraphForceLayout: edge direction from the
# port sides, cycle-safe layers, the bootcamp 3S2P graph laid out panels above
# controller above battery with no overlap and the panels on ONE row, Live ==
# Tidy, pinned nodes never move, a stacked start separates, a 120-node tidy in
# under 8 s). Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script system_graph/graph_force_layout_selftest.gd
# Unified graph cards (offline — GraphCardSpecs per type: panel live/peak +
# "Not wired", battery SOC/flow/time-to, controller delivered vs offered +
# clipping, load ON/OFF + waiting for AC, destroyed → alert + RESET):
Godot.exe.exe --headless --path . --script system_graph/graph_card_specs_selftest.gd
# Solar Bootcamp played by the harness (WINDOWED, REAL drags port to port on
# every level, the run levels run, L12 Ctrl-click + Ctrl+G). FAILs on any
# wire that had to be added through the model (= something ate the drag),
# a level that does not complete (L11 may stop at its verdict — the audit
# adds no loads), a stale card, overlapping cards after load. Shoots each
# level brief / seed / mid-drag / after / debrief / CLEAN (debrief closed),
# writes bootcamp_audit.json. --bootcamp-from=N starts at a level:
tools\harness.ps1 -World mtvernon -Capture bootcamp -UserArgs @("--window-size=1920x1080")
# Graph show-only views (offline — GraphDomainFilter: wire / port domains,
# Power hides the pond + tanks + hose wires and keeps the inverter, a habitat
# with AC + water shows under both, the unwired-node rule, compounds by their
# descendants, save round trip). EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script system_graph/graph_domain_filter_selftest.gd
# Solar grid snap (offline — PvGridSnap: edge to edge with the gap, the yaw
# lock, the no-shade row pitch pinned to 4.213 m at 48.3°N / 30° tilt, own
# array beats a nearer foreign rack, grid_layout, GraphPvWiring's 9S×2P string
# grid). EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script core/placed_models/pv_grid_snap_selftest.gd
# Timeline info row must not move while the clock runs (24 h in 7-min steps +
# a lunar month; FAILs on > 0.5 px drift or a right-cluster refold):
tools\harness.ps1 -World mtvernon -Capture timeline -UserArgs @("--window-size=1280x720")
# Graph tools: show-only filter, the "In the world" library drawer (2 J
# lights), Locate in 3D / Esc back / Walk to it, the Globe Connect tool with
# REAL clicks (pin, bend, pin -> a 3D run, bend locked, measured) and the
# full-screen globe continuing + handing back the lens orbit:
tools\harness.ps1 -World mtvernon -Capture graphtools -UserArgs @("--window-size=1920x1080")
# Solar grid snap in 3D (racks edge to edge, the no-shade pitch, Line up this
# array) and on the graph (Arrange as grid, drag snap, Tidy keeps the block):
tools\harness.ps1 -World mtvernon -Capture pvsnap -UserArgs @("--window-size=1920x1080")
# 3D connectors: plug-drag with a REAL release (HUD length == committed
# route_length_m within 1 %), the LIVE style modal (no Apply, real-run
# preview, Revert), run-length tags, the Shift chain port:
tools\harness.ps1 -World mtvernon -Capture conduits -UserArgs @("--window-size=1920x1080")
# Graph electrical self-test (offline — string Voc, controller ranking, Voc across
# a super-node boundary; DC side: battery-bank bus topology (4S/2S2P/mismatch),
# short-circuit detection (direct + closed series loop, parallel banks clean),
# unregulated-PV battery overcharge, and the controller current-throttle
# wattages 120/360/720/1200 W pinned; extend with every electrical change):
Godot.exe.exe --headless --path . --script system_graph/graph_electrical_selftest.gd
# SoI stage self-tests (offline — see "SoI stage" below; each carries
# EXPECTED_CHECKS; --import first). GraphElevFrame: the ONE Elevation frame —
# the disc sits where the SoI centre PROJECTS after pan / cursor zoom / siphon
# framing, the section camera looks at the exact inverse at the container
# centre, chord vs silhouette radii either side of the slice, the ortho floor at
# ZOOM_MAX. SoiStagePose: the lens-transition maths — exact endpoints, the
# dolly-zoom keeps the frame height, a near-ortho perspective projects within
# half a pixel of true ortho (so the final switch is invisible), the Plan →
# Section bulge through perspective, antipodal dirs without NaN. SoiSectionCap:
# the cut-face strip builder — on the backed-off plane, bottoms on the chord
# circle, tops = ground clamped to the circle, lip only on ground-limited tops:
Godot.exe.exe --headless --path . --script system_graph/graph_elev_frame_selftest.gd
Godot.exe.exe --headless --path . --script system_graph/soi_stage_pose_selftest.gd
Godot.exe.exe --headless --path . --script core/soi/soi_section_cap_selftest.gd
# Wire routing + port presentation (offline geometry — bezier control points for
# same-edge ports (the U loop), facing ports, direction-fallback endpoints;
# ambient-port classification; DC solid-fill/glyph styling rules; the "+ is
# always on the left" terminal convention; complete-circuit flow gating):
Godot.exe.exe --headless --path . --script system_graph/graph_wire_routing_selftest.gd
# Tiered UI feedback sounds (offline — every tier well-formed/deterministic,
# the success chime rises, the womp-womp descends with a gap between notes,
# the per-wire click stays short + quiet, DANGER == the graph destroy boom):
Godot.exe.exe --headless --path . --script core/ui_sfx_selftest.gd
# Solar Bootcamp tutorial (offline — ProgressStore grandfathering/grants/levels,
# 12-level catalog integrity incl. every seed/unlock/palette entry resolving,
# TutorialGoals predicates: deliverable-watts/bus-V/string-config over synthetic
# graphs, AC-load wiring, compound-containing, run verdicts; extend with every
# tutorial change):
Godot.exe.exe --headless --path . --script gameplay/tutorial_selftest.gd
# Challenge pre-bake loop (offline — span step policy vs the 20160-sample
# timeline caps, prebake ChallengeDef round-trip + legacy default, catalog
# prebake entries, power-failure accumulator edges, two-run bake determinism):
Godot.exe.exe --headless --path . --script gameplay/challenge_bake_selftest.gd
# Challenge defs/catalog/runner rules (offline):
Godot.exe.exe --headless --path . --script gameplay/challenge_selftest.gd
# 3D conduits (offline — kinds/conceptual default, mesh/drape/lights, loss,
# bound-prop routability, connection ports, triangle pick, ortho elbows, the
# size-driven tube radius (a size-listed kind renders at its STYLED bore; the
# mesh builder reads radius_m off the kind meta, so without ConduitManager
# stamping it a 2" poly run drew exactly as thin as a 1" one and the size
# picker looked inert), and
# the poly_penstock kind + ContourRouter (Hydro Lab overhaul Phase C):
# SDR-9 ID-per-size table, PPI 25×OD bend radius, terrain-following route that
# bridges too-sharp gullies, dispatch contour branch determinism + no-ground
# chord fallback. The flow-engine side (routed conn is the authority for
# penstock length/Ø/outlet invert; contour conns exempt from the generic
# Hazen-Williams derate) is pinned in resource_flow_selftest's
# _test_penstock_conn_authority. Run --import first so class_names register:
Godot.exe.exe --headless --path . --script core/conduits/conduit_selftest.gd
# Culvert stage-discharge + Hydro Section calculator (offline — weir/orifice,
# Manning cap, stepped 3×8″ bank, PE vs HydroSource; --import first):
Godot.exe.exe --headless --path . --script core/conduits/culvert_hydraulics_selftest.gd
# Siphon micro-hydro prime/break + power cap (offline; --import first):
Godot.exe.exe --headless --path . --script core/conduits/siphon_hydraulics_selftest.gd
# Unified hydro reach: pond→siphon→culvert→outlet ONE stepper — parity vs
# SiphonHydraulics, prime/break cycle, mass conservation, effective air-break
# dead pool, overflow, penstock conveyance (design-flow vs gravity capacity),
# and the NOZZLE model (Hydro Lab overhaul Phase D): powerspout_pelton runs
# PeltonPhysics' operating point (penstock delivery meets nozzle demand,
# Cv 0.97, x_opt 0.46 — Thake; pinned to a hand-computed 20 m / 100 m /
# 1×10 mm case), jet-derived RPM (not the 5 kW siphon rotor curve), and the
# kind's 1.6 kW nameplate when the spec leaves max_power_w at 0. PeltonPhysics'
# own pins (jet velocity, nozzle head/flow round-trip, runner parabola, the
# powerspout estimator branch of power_kw_from_graph_specs incl. the pelton
# head-band floor moving 30→10 m) live in source_physics_selftest. Offline,
# deterministic; --import first. This reach is the single physics source for
# the flow engine + Hydro Lab (no fallback branch). Also pins the LEVELLESS
# STREAM mode (`penstock_source_mode: "stream"`): a spring/creek tapped by a
# penstock has no water surface to draw down, so the reach takes its head from
# the adopted invert drop and skips both the `is_nan(level)` bail and the
# submergence dead-pool — without it a stream-fed PowerSpout reported regime
# "unset" and every Lab readout sat at zero. Plus the supply cap, the
# oversized-nozzle head collapse, and `no_supply` (a DRY spring, distinct from
# `no_head` — the Lab must not tell you to move a correctly-sited turbine):
Godot.exe.exe --headless --path . --script core/conduits/hydro_reach_selftest.gd
# Water features (offline — core/water/: the feature layer + span edits,
# StreamNetwork resolution (OSM overrides, kinds, culvert spans, drainage links,
# outlets-first order), ChannelProfile (monotone bed, max-cut flags, junction
# floor never above the ground), StreamHydraulics vs a hand-computed trapezoid
# and the rational method, ChannelCarver (only lowers, bed under the centreline,
# brute-force bank sample, no terraces on a 20 % reach, incremental re-runs, C1
# toe / soft lip), the delta stack (compose = channel + player, player undo
# isolation, one-pass mesher == reference), and the v6-cache centreline
# derivation. Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/water/water_features_selftest.gd
# Drainage (offline — FlowRouting: Priority-Flood+e leaves no interior sinks,
# accumulation conserves cells, valley channel on its axis, Strahler 2 at a Y,
# burning, trace downhill, RDP, determinism):
Godot.exe.exe --headless --path . --script core/water/flow_routing_selftest.gd
# Stream curves + channel-tile seams on a REAL world with streams (sandbox):
# the map-wide Smoothing / Meander re-curve and re-carve every stream (longer,
# ends on the waypoints, bed on the centreline) and V reopens the toolbar
# where it closed; the seam probe checks tile edges vs the DetailGround,
# its normals beside the tiles, and matching shadow casting:
tools\harness.ps1 -World <world> -RunScript res://tools/checks/stream_curve_check.gd
tools\harness.ps1 -World <world> -RunScript res://tools/checks/channel_tile_seam_probe.gd
# Ramp Height / Top width / Side slope with REAL clicks (berm + channel cross
# sections measured, undo), and nothing swallowing world clicks under the
# toolbar (a grid of points per section):
tools\harness.ps1 -World <world> -RunScript res://tools/checks/ramp_tool_check.gd
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/toolbar_input_probe.gd
# A Rain-tool storm over the head of the longest stream with REAL input, "dry
# between storms" on: the front runs down the channel, never skips ahead, and
# the channel drains after; close-up shots of the rain and the front:
tools\harness.ps1 -World <world> -RunScript res://tools/checks/stream_storm_check.gd -Label <dir>
# A bowl dug across a stream fills before anything runs on, then spills, then
# soaks away; a large storm cuts the bed and is re-carved; Reset erosion:
tools\harness.ps1 -World <world> -RunScript res://tools/checks/stream_basin_check.gd -Label <dir>
tools\harness.ps1 -World <world> -RunScript res://tools/checks/stream_erosion_check.gd
# Rain + stream frame bench (Bombay Beach = w6ad922917357): a 100 mm/h storm,
# a bowl across a stream, then the real 2023 Hilary weather, 10 sim-h each;
# prints p50/p95/max frame ms, every water_* / terrain_* section's avg + peak,
# what the slow frames spent, and whole-frame dark-flash detection. Env:
# WBENCH_X (speed, default 600), WBENCH_NOREAD=1 (no readbacks — the honest
# frame times), WBENCH_ONLY=D|E (re-drape probe / flash hunt), WBENCH_HEAVY=1
# (replay the old full carve side effects), WBENCH_HUNT_S. 2026-10-22 at
# 1440x NOREAD: p50 ~24 ms, p95 ~27 ms, 0 dark frames:
tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/bench/stream_rain_bench.gd
# Water end to end (WINDOWED, a REAL map with waterways; --time=14 dodges the
# Mt Vernon valley fog): carve + drainage land, every bed monotone, ground ==
# bed on carved stations, water at or below the banks, rain raises a mapped
# stream's discharge, then the WATER toolbar driven with REAL input (Draw, pick,
# pin drag, line-drag insert, hover + Delete, span → culvert (hidden in first
# person, shown by the toggle, headwalls), Ctrl+Z, Trace), the flow view (beads
# move only while the clock runs, storm raises the outflow chip) and the graph
# link (an intake on a stream takes its flow). Byte-restores the map's
# water_features / channel_tiles files. (Curves: the stream_curve_check below.)
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=water --time=14 --shots-dir=<label> --quit-after-capture
# ABS DWV pipe kit (offline — kit JSON/meshes, planner 45/90 BOM; bake once with
# pipe_kit_extractor.gd if data/*.res missing; --import first):
Godot.exe.exe --headless --path . --script core/conduits/pipe_kit_selftest.gd
# Re-bake ABS fittings from Imported Models/PipeFittings/abs_dwv_elbows.glb:
Godot.exe.exe --headless --path . --script core/conduits/pipe_kit_extractor.gd
# LinkageLab designer self-test (offline — solver/kinematics pinned to JS
# reference values, support/panel geometry, structure builder, world-placement
# runtime, solar/graph handoff, modal compile smoke; PLUS the hardware/BOM port:
# v30 hardware-assembly round-trip, LinkageBom counts cross-checked against the
# SOLVER's own bolt/bracket arrays (the web app never did this), the packing
# mass fence, drill templates, the BOM→crew fabrication graph incl. a frozen
# back-compat literal, build-guide + hardware-modal compile smoke, hardware
# axis-stack layout/snap/mirror maths JS-PINNED via tools/linkage_hw_reference.mjs,
# part meshes (incl. an outward-normal
# WINDING assertion), the credits lockstep guard, and the hardware-spacing
# parity proof — `is_same(effective_params(p), p)` when full detail is off,
# which is what protects every pinned value here. Extend with every solver
# change; run --import first so new class_names register):
Godot.exe.exe --headless --path . --script core/linkage/linkage_selftest.gd
# Packing data model (offline — plans/PACKING_PLAN.md Phase 0: PackedSpec
# resolution/normalization, per-type mass+dims heuristics, the shipped-model
# packing-decision coverage guard (a new structures/tools catalog model FAILS
# this until it appears in CURATED_MODELS / DYNAMIC_MODELS / NON_PACKABLE),
# and the LinkageLab packed envelope solved at the EFFECTIVE min fold angle;
# run --import first so PackedSpec registers):
Godot.exe.exe --headless --path . --script core/packing/packing_selftest.gd
# Process recipes + chore ledger + workflow runner (offline — normalize/catalog,
# legacy batch migration, scrub-safe progress, hybrid chore confirm, part credits,
# workflow step advance; run --import first so class_names register):
Godot.exe.exe --headless --path . --script core/machines/process_recipe_selftest.gd
# Portable .esim site package (offline — validate/build, ghost strip/remap,
# share-code + file round-trip, summary counts; run --import first):
Godot.exe.exe --headless --path . --script core/esim/esim_selftest.gd
# Multiplayer helpers (offline — join-code round-trip/expiry, bare ip:port,
# protocol reject, avatar color, transfer codec, chat sanitize/mute, Phase 6
# password/allowlist/rate-limit + headless host bind smoke, which now also pins
# that a hosted code carries a candidate address list AND still mirrors the LAN
# address into the top-level ip/port every pre-v3 consumer reads; plus the
# shared-world change sets (MpChangeSet: prop / graph diff, merge onto a copy
# the host changed meanwhile, reject-revert, JSON int/float equality, telemetry
# keys never an edit), the presence body packet and the guest-world keys;
# --import first):
Godot.exe.exe --headless --path . --script core/multiplayer/multiplayer_selftest.gd
# Multiplayer end to end — TWO sandboxed instances on one machine over
# 127.0.0.1, stepping each other through %TEMP%\mp_probe\. Start the host,
# wait ~4 s (two harness runs in the same second share a sandbox id and the
# second fails to seed), then the guest. Times a host prop reaching the guest
# (0.33 s on 2026-10-20), a guest move as a proposal (card words, ghost,
# host world unchanged until Accept), a declined delete put back, a guest
# graph node, "view only", the silhouette bodies + positions:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/mp_host_probe.gd -Label mp_host -Timeout 900
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/mp_guest_probe.gd -Label mp_guest -Timeout 900
# What another player looks like (one instance, no network):
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/mp_figure_probe.gd -Label mp_figure
# Sim vs reality experiments (offline — core/experiment/: SiteTime Unix <->
# site clock (PDT / PST noons, round trip), ExperimentObserved held states /
# time-weighted flows / sums / gaps / CSV watts, ExperimentEnergyRun == step_soc,
# AC hysteresis, battery-full curtailment, determinism + chunking, the scores
# incl. ASHRAE G14 NMBE by hand and a time shift failing CV(RMSE), and
# HaHistoryFetch's link resolution + units, the fork store (temp-file round
# trip, unique names, the without-automation copy) and an A/B run where B
# lacks an evening heater rule, and a pump on a 30 L tank run by the copy's
# own flow engine (runs 3 h, draws only then, blocks), and the
# counterfactual / savings maths by hand. EXPECTED_CHECKS;
# --import first):
Godot.exe.exe --headless --path . --script core/experiment/experiment_selftest.gd
# Automations in sim time (offline — AutomationSim crossings incl. midnight,
# the same switches at 1-min and 1-h steps, numeric edges + `for` in sim
# seconds, delays, time / weekday / sun conditions, and ExperimentWorld: a
# graph copy whose heater follows 18:00-on / 23:00-off through a real
# GraphAcLoad reading while the live model never moves. EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script power_system/automation/automation_sim_selftest.gd
# Absolute hours never through a Vector2 (sandbox): an odd-hour selection
# arrives exact in SolarUI, the video-export range + dialog, the render end,
# and the track window is the view's own start:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/timeline_abs_precision_probe.gd
# Would / did save end to end (sandbox, fake HA): reality = the world's own
# sim with a nightly shutdown, served as history; "did" with a fork without
# it — the window's span exact to the hour, the estimate = the fork's sim,
# the reality sim a good match; "would" worded as a what-if:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/compare_savings_probe.gd -Label compare_savings
# Projection mapping (offline — ProjectionWarp: the perspective corner pin's
# homography, Basis == GLSL mat3, layouts, bow-tie refused, v2 round trip and
# the v1 pixel file migrated, on TEMP paths; EXPECTED_CHECKS; --import first):
Godot.exe.exe --headless --path . --script scenes/ui/projection/projection_warp_selftest.gd
# The canvas (I) + POV warp (Z) on a real world (sandbox): no dashboard left,
# viewports idle while hidden, F9 inert while hidden, a keystone quad drawn
# with black outside, handles over the quads, the panel off the corners,
# UiAudit clean, the HUD hidden while up; shots under screenshots\projection\:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/projection_warp_probe.gd -Label projection
# A vs B end to end (sandbox): a nightly shutdown on a load, the automation
# card's A/B (fork without it, next week) — A asks for less and wins; editing
# the fork (canvas holds it, clock held, engine + HA links stand down), Done
# restores the world byte for byte with every HA link, the fork keeps its
# change, Compare reopens; the bootcamp sandbox keeps the HA links:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/compare_ab_probe.gd -Label compare_ab
# The LIVE engine at 2 sim-h per second (sandbox): an on / off time rule
# pair on a graph load fires once each and the load follows; load W in W:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/automation_speed_probe.gd
# The Compare window end to end (sandbox, fake HA): reality for the last 3
# days MADE BY THE SIM and served as history → NMBE ≈ 0 (the hours line up,
# W → kW); 25 % less real solar → not a match, sim 33 % high; the live world
# unmoved; ⧉ opens it; UiAudit 0 errors; shots under screenshots\compare_probe\:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/compare_calibration_probe.gd -Label compare_probe
# Home Assistant (offline — HaUrl / HaToken / HaFailure / HaProfiles on TEMP
# files incl. the ha_connection.cfg migration, HaUnits, HaTargets, HaLinkStore
# incl. the specs.ha_links + SolarUI cfg migration and pruning, HaObservedStore,
# HaPresets; then the REAL HomeAssistantService against HaFakeServer on
# 127.0.0.1: steps in order, one subscription for many callers, coalesced
# get_states, wrong token (no retry), dead port + the finder's suggestion, not
# HA's API, auth timeout, dropped + reconnected. EXPECTED_CHECKS; --import first):
Godot.exe.exe --headless --path . --script core/ha/ha_selftest.gd
# The same on a real world (sandbox, fake HA): the settings page with a REAL
# Connect click and its four steps, links to the site battery / a load (W) /
# the weather (°F), Live mode at 1x drives them with user_rev unmoved, 60x only
# records, HA history backfills the track, the timeline HA lane, automations see
# the sensor, the Live links window (UiAudit), a preset, unlink:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/ha_link_probe.gd -Label ha_probe
# Timeline binning (offline — ladder, anchoring across a pan, exact nesting
# across zoom levels, a sawtooth keeping its range at every level, the weather
# trapezoid, HA step bins with gaps and NOW; EXPECTED_CHECKS):
Godot.exe.exe --headless --path . --script core/timeline/timeline_binning_selftest.gd
# Timeline tracks (sandbox, fake HA): the Tracks ▾ submenus through the menu's
# own handler (a power track — the old id-as-index bug — and three weather
# tracks with their lanes filled from WeatherService), Pick any sensor… with a
# REAL click, the lane filled from HA's history, Remove a track:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/timeline_tracks_probe.gd -Label tl_tracks
# Discord integration (offline — every security-relevant decision in core/discord/
# is a PURE class_name file precisely so it can be fed fixtures here instead of
# only against a live Discord app). Covers: PKCE pinned to the RFC 7636 Appendix B
# vector (catches every base64url/padding slip at once — a slip otherwise surfaces
# only as an opaque `invalid_grant` from Discord's token endpoint); the community
# file codec INCLUDING the SSRF guard that a webhook URL must be on discord.com;
# the session-directory record's parse/staleness/seq and its ELECTION arbitration
# (two simultaneous claims, exactly one winner, loser flips to joining); the gate
# verdicts over canned /oauth2/@me + guild-member bodies (notably that a token
# minted by any OTHER Discord application is rejected); deep-link injection
# rejection; reachability classification incl. the 100.64/10 CGNAT block and a
# sweep of every UPNP_RESULT_* constant; relay batching (every payload must carry
# allowed_mentions.parse == [] or an in-game "@everyone" pings the whole server);
# telemetry redaction; the admission hold-vs-kick states; join-code v3 plus a
# FROZEN v2 literal so codes already pasted into Discord keep decoding; the
# DiscordIdentity offline contract + loopback-port binding; the community STORE
# (snapshots and byte-restores the player's user://communities + active pointer,
# same write-discipline as the veg harnesses); and an END-TO-END election driven
# through a FakeDiscordHttp stand-in — empty directory wins, live host stands
# down, stale host frees the seat. That last one is awaited and deliberately
# waits out the real confirm delay, because the delay IS the mechanism:
Godot.exe.exe --headless --path . --script core/discord/discord_selftest.gd
# Terrain live-fetch smoke test (NETWORK — elevation + imagery for one site):
Godot.exe.exe --headless --path . --script core/terrain/terrain_fetch_smoketest.gd
# Parametric SCAD store (offline — -D/param-set literal formatting, param-set JSON,
# StlLoader STL->mesh round-trip, ScadProvisioner manifest/plan, ScadParamParser
# Customizer schema over the seed vase, ScadCatalog deps/category/license triage;
# run --import first so the new class_names register):
Godot.exe.exe --headless --path . --script core/scad/scad_selftest.gd
# SCAD live render smoke (REQUIRES OpenSCAD binary — renders seed vase twice,
# confirms params change geometry + STL imports to a mesh):
Godot.exe.exe --headless --path . --script core/scad/scad_render_smoke.gd
# SCAD library ingest + license triage (needs OpenSCAD for validation renders):
# walks scad_library/ RECURSIVELY, parses each, validation-renders defaults
# (bounded by --render-budget=<sec>, default 240), writes scad_library/catalog.json,
# auto-stubs missing credits into credits/credits.json (--no-render = metadata only):
Godot.exe.exe --headless --path . --script core/scad/scad_ingest.gd
# SCAD library import (seed scad_library/ from an external Thingiverse-style folder:
# copies .scad by dir, classifies LICENSE.txt, extracts README, writes credits):
Godot.exe.exe --headless --path . --script core/scad/scad_import.gd -- --src="<path>"
# In-game store: press H in a loaded map (ScadStore + scenes/ui/scad_store_modal.gd;
# ScadPartBuilder MODEL_ID scad_part places rendered parts via PlacedProp).

# Packing Lab capture (WINDOWED — plans/PACKING_PLAN.md Phase 4): sweeps the site
# cargo (graph + placed props, same sweep as the Site Report card) into the
# interactive Packing Lab modal, auto-packs it into the 15' and 26' trucks,
# orbits, then loads the builtin StarShade kit into a 20' container — one PNG
# per state for visual review. Read-only, nothing persisted:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=packing --shots-dir=<label> --quit-after-capture
# Hardware Detail capture (WINDOWED): opens the hardware editor through Main's
# real entry point (so it lands on its own CanvasLayer above the HUD) and shoots
# one PNG per state — each assembly seated on the frame, exploded, standalone,
# selected-with-axis-gizmo, and arch mode — then DUMPS to console how many
# joints each assembly got, how many flipped their stack axis, and the worst
# "anchor error": the distance from each seat's bracket hole to the V-stack
# pivot it clamps. That number must be 0.000000; anything else means the
# placement is back on the wrong pivot. Joint placement is unreviewable from a
# description — the port shipped anchored on the H-ring pivot, with no
# flipStackAxis and a 90°-yawed H-centre frame, and all three RENDERED:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=hardware --shots-dir=<label> --quit-after-capture
# Regenerate the hardware LAYOUT + PLACEMENT reference values from the real web
# app (writes core/linkage/testdata/hw_placement_ref.json in place; run from the
# repo root). Part 2 solves with showHardwareFullDetail=false + hwDetailMode=true
# — the only combination that emits placements while leaving the beams identical
# to linkage_reference.mjs's cyl_default, which the printed cornerSum proves:
node tools/linkage_hw_reference.mjs ../LinkageLab
# LinkageLab PARITY fixtures + the shipped JS presets (plans/LINKAGE_PARITY.md): exports
# the ref (default main) with git archive — the sibling working tree is never
# touched — and runs a generated vitest spec in the JS repo's own environment.
# Writes core/linkage/testdata/parity/*.json and core/linkage/presets/ll_*.json.
# Needs `npm install` run once in ../LinkageLab:
node tools/linkage_parity_dump.mjs ../LinkageLab main
# LinkageLab build steps (offline — core/linkage/build/): the step model,
# groups, staging visibility, bench planning, LinkageBeamHoles, and the
# auto-generator pinned == the web app's Auto-generate per preset; the op
# resolvers (LinkageBuildOps place/cut/drill/fasten timing) pinned by hand.
# Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/linkage/build/linkage_build_steps_selftest.gd
# LinkageLab coverings / raised floor / shade tarps (offline — A4,
# core/linkage/coverings/ + linkage_floor.gd): every wall / fabric band /
# table, the deck, the tarps (coverage, sizes), the cut plan (per-wall sheet
# nests, totals) and the ENCLOSURE BOM rows pinned == the parity dump's "a4"
# block on all five presets, plus nesting / fabric unit cases, every plan
# entry rendering an SVG cut file, and LinkageBom's enclosure section x copies.
# Carries EXPECTED_CHECKS; --import first:
Godot.exe.exe --headless --path . --script core/linkage/coverings/linkage_coverings_selftest.gd
# Fabrication figure layer (offline — swarm plan B1/B2): NpcLimbIk (analytic
# two-bone IK: exact on every reachable target, middle joint toward the pole,
# elbow bends -X / knee +X), NpcAnimClip (keyframe clips: per-joint TRACKS,
# quaternion slerp, loop wrap, events, mirror, shipped clips load), the stick
# figure's wrist / clip / IK / held-tool layer (palm and planted foot land on
# target; a cleared clip or released IK leaves EXACTLY the procedural pose —
# the mo-cap spice rule) and FabToolCatalog (every tool builds with sound
# sockets; an attached tool's grip IS the palm). Carries EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script core/population/npc_anim_selftest.gd
# Fabrication pose studio (WINDOWED, not a selftest): every starter clip in
# core/population/anims/ on a stick figure holding its tool by IK (saw on a
# bench, drill, driver, wrench, a beam carried / set down / lifted), side +
# three-quarter, prints palm-to-grip error per hand (0.000 m expected; 0.1 m =
# out of reach). Run with APPDATA pointed at a scratch folder (user:// would
# otherwise be the player's). Writes user://fab_pose_grid.png:
Godot.exe.exe --path . --windowed --resolution 1280x720 --script core/population/fab_pose_diag.gd
# NPC animation editor end to end (WINDOWED, REAL input through the viewport —
# swarm B3): opens through Main on drill_hole in the drill context (both hands
# on the drill's grips), starts a NEW clip, CLICKS the upper arm (joint
# picked), DRAGS the gizmo's X ring (a key appears, the shoulder turns), CLICKS
# the timeline halfway + K (a second key), Ctrl+S (file written), reloads and
# byte-compares, Escape closes. Shots per state + the cut / fasten / lift
# contexts. Saves into the sandbox and deletes what it wrote:
tools\harness.ps1 -World mtvernon -Capture animeditor
# Fabrication swarm timeline (offline — swarm B4, core/linkage/build/
# linkage_build_timeline.gd): the SOAK build planned for named workers —
# every job kind present, nothing blocked with 9 hands, deterministic, every
# job after its dependencies and within its crew min..max, no worker in two
# places at once, cut -> drill -> place per beam, the lift waits for a raising
# crew, makespan >= critical path and >= work / crew, more hands never worse,
# state_at pure (scrub back == first visit), the structure only grows, a crew
# smaller than a quorum lifts with everyone. Carries EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script core/linkage/build/linkage_build_timeline_selftest.gd
# A Linkage Lab structure built by the crew (sandbox; replaced fabswarm /
# fabcrew on 2026-10-27, when the Linkage-only site was retired): a placed
# StarShade rehearsed on a held clock — nothing at the start, the part-open
# frame the crew builds stands on the DEPLOYED ring's middle, half built,
# whole, then the real structure opens about that middle and stands at its
# placed pose; scrub back; then the build at speed against the world's own
# frame time (the `build_site` PerfSpan section). LCB_DESIGN=<res:// preset>
# for another design (Constellation: 235 pieces, the heaviest fold):
tools\harness.ps1 -World walton -RunScript res://tools/checks/linkage_crew_build_check.gd -Label linkage_crew -Timeout 1200
# Lab build-step player (offline — A5): LinkageStepScene frames (a cut is a
# bench step with the saw out and every row kept at the end, drilling adds
# holes, a place step starts its parts away from their seats, parts only
# appear, everything stands at the end, the driver at the fastened joint, the
# lift carries the parked ring home) and LinkageStepPlayer on a real builder
# (structure hidden on bench steps, future parts hidden, no joint hardware
# before its joint, the step's pose, the saw where the cut puts it, skip mode
# plays each group once, exit seats everything). Carries EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script core/linkage/build/linkage_step_player_selftest.gd
# Lab build steps end to end (WINDOWED, REAL input through the viewport):
# opens the Lab through Main on the SOAK 2026 preset, CLICKS 🎬 Steps, a list
# row, play and pause; per kind asserts the bench / tool / hidden-part state
# (the drill bit on the hole it drills, 0 mm), CLICKS Save to design (the
# sequence is in the config) and closes with every part seated. Then reopens
# on Constellation and drives the Radial Array group (A3): the preset's array
# in the controls, hiding a slot drops a copy, "one at a time" mid-fold shows
# several poses, unticking Enable draws one structure. Then Hex (A4): walls,
# tables, deck and tarps drawn, the tarp checkbox and "Every span: Fabric"
# rebuild them, the deck step stages the deck, the guide writes the SVG cut
# files. PNG per kind + radial_* + enclosure_*:
tools\harness.ps1 -World mtvernon -Capture buildsteps
# The crew build of a Linkage frame through the deploy schedule / the Lab's
# "Queue build for crew" (both SiteDeployDirector.queue_item) is the linkage
# kit of structure_build_check (SB_ONLY=linkage).
# Visual playtest capture (WINDOWED — cannot be --headless): launch a user map
# by CLI, freeze a daytime clock, hide HUD, shoot drone-orbit + street PNG sets
# (+ manifest.json) to user://screenshots/<label>/ for agent/visual review:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=<file.tres> --capture=both --shots-dir=<label> --quit-after-capture
# Terrain-sculpt smoke test (WINDOWED): runs a real Raise stroke + Level pad +
# Pond through the TerrainLoader commands, shoots before/after PNG sets (incl.
# low grazing views where a 3 m mound/bowl actually silhouettes), dumps the
# HeightField tile-mesh state (AABBs/material — catches invisible-mesh bugs),
# then UNDOES everything (map save data untouched):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=<file.tres> --sculpt-test --shots-dir=<label> --quit-after-capture
# Systems-graph UI capture (WINDOWED): opens the G view on the soak map (the
# boot scene is the map chooser, so pass --scene) and shoots one PNG per UI
# state — freeform/arranged/selection+inspector/compound interior/zoom
# extremes/site plan/elevation — via the REAL view handlers, for visual review:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=graph --shots-dir=<label> --quit-after-capture
# Hydro Lab capture (WINDOWED): builds a pond + siphon on the graph, binds them,
# opens the Lab's own 2D cross-section (VIEW_SIPHON, item-bound — the mode chip
# is gone), and shoots primed/flowing → time-accelerated drain/broken →
# test-inflow refill/reprime (drives the pond on the world clock via the unified
# HydroReach) for visual review of the flow render. The read-only variant also
# flips the turbine to powerspout_pelton for one shot (04) — nozzle knobs +
# Penstock-route section + the power-curve chart (P vs head per poly size, live
# operating-point marker) with the dock scrolled to frame them — and DUMPS the
# per-size watts line to console (the number a PNG can't prove), then restores
# the saved kind. Then flips it to micro_pelton (the AliExpress vertical-shaft
# unit) and asserts the close-up SWAPPED its model, found the runner (Node6,
# r 0.101 m, axis Y) and the GLB's own nozzle fitting, lands the jet ON the
# pitch cylinder along -X, drives the exit sheets from
# PeltonPhysics.bucket_exit_velocity, stands the jet's-eye camera at the
# mouth looking down the jet, and that a 12 mm axial nudge moves the landing
# off the splitter (shots 08-10 + a debug_summary dump):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=siphon --shots-dir=<label> --quit-after-capture
# GLB dump (NOT a selftest — read it BEFORE authoring a ModelCatalog entry):
# the node tree with local transforms, every mesh's AABB / verts / material,
# then each top-level part's GLOBAL AABB in metres. Says which node is the
# runner, which axis its shaft is, where a nozzle fitting sits, and what the
# exporter left in the file (SketchUp scale figures) that must be stripped.
# ⚠ Globals only resolve on the first PROCESS frame — the SceneTree root is
# not in-tree during _initialize (the veg-dock selftest trap):
Godot.exe.exe --headless --path . --script core/placed_models/glb_dump_diag.gd -- --glb=<path.glb>
# Runner look studio (WINDOWED, not a selftest): each hydro turbine's BARE
# runner shot from the jet's eye at the pitch point, radially from outside,
# in plan and 3/4, with a cyan rod on the jet line, red on the shaft, amber
# on the radial. How a bucket's orientation vs the jet is judged — a Pelton
# splitter is RADIAL with a cup each side ALONG the shaft; what reads rotated
# a quarter turn here is modelled wrong, what reads side-on only in the Lab
# is a landing-point bug (it was). user://runner_look_<model>_<view>.png:
Godot.exe.exe --path . --windowed --resolution 900x900 --script core/placed_models/runner_look_diag.gd
# Site-review (WINDOWED): load a REAL user map as-is (autosaved graph + terrain
# artifacts), shoot world/ + graph/ (freeform + elevation) + siphon/ Lab, write
# diagnostics.json + perf/*.json. Alias --user-map=mtvernon resolves Mount Vernon
# under user://maps/. --perf enables F3 HUD; --no-mutate skips Demo Lab drive:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=loc_48p3252_n122p2469.tres --capture=site-review --perf --shots-dir=mt_vernon_review --quit-after-capture
# Vegetation regression capture (WINDOWED — veg overhaul Phase 1 baseline): waits
# for the auto-veg scatter, then shoots forest-anchored sets (veg_00 close canopy,
# veg_01 the NEAR→FAR LOD boundary, veg_02 distant, veg_03 aerial) + orbit + a
# 4-date seasonal series (winter/spring/summer/autumn from one fixed waypoint),
# and writes veg_diagnostics.json (per-batch instances/visibility/fade-mode/
# surfaces, VegAssetCache stats, primitives/draw-call counters, key style knobs).
# Run before/after ANY veg rendering change and diff the JSON + boundary shots:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=veg --shots-dir=<label> --quit-after-capture
# Per-area fill end-to-end (WINDOWED — veg overhaul Phase 7): on a REAL saved
# map, picks the largest OSM vegetation area, drives the loader's own
# apply_area_fill / area_fill_params / clear_area_fill, and asserts the fill
# placed instances, planted the CHOSEN species, persisted to the map's
# auto_veg_edits file, and cleared again; shoots before/after/cleared PNG pairs
# of the outline. It SNAPSHOTS and RESTORES auto_veg_edits_<lat>_<lon>.json, so
# a regression run never mutates the player's site (verify after: the file is
# back at its original version/cleared/patch counts with 0 fills):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=areafill --shots-dir=<label> --quit-after-capture
# Growth capture (WINDOWED): an AGE LADDER per family — nine ages of one species
# side by side in ONE MultiMesh, for the 3D mesh and the impostor card, with the
# model's height/crown/girth/leaf DUMPED per rung (a PNG cannot tell 0.72 from
# 0.80) — then a TIME-LAPSE from one drone viewpoint over the painted grove at
# +0/+5/+20/+80/+200 years and BACK to +0, dumping per-layer size statistics.
# Asserts the painted layer is full size today, is never mostly small at any
# stop, and that the rewind reproduces the first stop exactly. Read-only: it
# restores the calendar and never saves (the load-time record migration is
# deliberately not persisted, so the vegetation file's hash is unchanged):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=<file.tres> --capture=growth --shots-dir=<label> --quit-after-capture
# Tree portraits (WINDOWED, console + PNGs): stands ONE tree of each species in
# empty air against sky and shoots it at NEAR and FAR, with per-shot surface/
# tri/AABB/foot numbers. Shape work is unreviewable from forest shots — a
# silhouette defect just reads as "the forest looks off". It builds meshes
# straight from VegetationCardFactory and never touches the map's veg layers,
# but it DOES read the map's live style, so run it on a real site (mtvernon),
# not the soak map, or you are reviewing library defaults nobody renders:
Godot.exe.exe --path . --windowed --resolution 900x900 -- --user-map=mtvernon --capture=tree --shots-dir=<label> --quit-after-capture
# Veg paint dock + Tune-look visual check (WINDOWED — veg overhaul Phase 8):
# opens the V dock through its real entry point and shoots the chip row in four
# tool states, then opens Tune look…, calls Apply, and asserts the modal STAYS
# OPEN (Phase 8 made applying iterative instead of close-on-apply). Read-only —
# it never paints or persists:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=vegdock --shots-dir=<label> --quit-after-capture
# Food-forest harvest guard (WINDOWED, console-only — veg overhaul Phase 10):
# seeds a food-forest bed + biomass store on the graph, keeps the graph screen
# CLOSED, and asserts the harvest is credited on the ambient tick INSIDE the
# window and nothing is credited outside it. Keep the test time_scale low (20
# h/s): at 400 h/s a 4 s run advances 66 sim-days and leaves the 61-day harvest
# window before the assertion reads it. Removes its seeded nodes afterward:
Godot.exe.exe --path . --windowed --resolution 640x480 -- --world=mtvernon --capture=foodforest --quit-after-capture
# Ambient resource-flow regression guard (WINDOWED — the harness hard no-ops
# under --headless; no screenshots, console-only): builds a primed pond+siphon+
# culvert-outlet, keeps SystemGraphView.visible=false the ENTIRE time (graph
# never opened), speeds up the world clock, and asserts the pond drained + the
# outlet accumulated volume. Guards against the water/siphon/catchment
# simulation regressing back to only running while the 2D graph screen is open
# (system_graph_view._tick_resource_flow_ambient):
Godot.exe.exe --path . --windowed --resolution 640x480 -- --world=mtvernon --capture=ambient --quit-after-capture
# NPC population end-to-end verify + Site Plan/3D capture (WINDOWED): seeds 4
# tagged area spaces + a pop-driven habitat with supply/waste tanks on the soak
# graph, runs the clock with the graph CLOSED and asserts ambient consumption
# (tanks moved) + agent movement, shoots Site Plan dot PNGs (incl. a zoomed
# close-up), shoots the 3D silhouette avatars + crosshair/space-marker
# contracts WHILE THE ROSTER IS ALIVE (phases are ordered this way on purpose
# — the cascade below empties the camp), then empties the food tank and
# asserts the starvation loop closes (STARVED flash seen, hunger climbing),
# and finally cuts the water and asserts the whole Tier-2 cascade: morale
# falls, people rage-quit, the roster shrinks, the colony collapses. Do NOT
# add a >6 h time jump to the starvation phase — that takes the coarse
# catch-up path and empties the camp before anything can be observed.
# It also seeds a plain 0.5 h scheduled chore and asserts it reached
# `done_day >= 0` during the ambient day: movement and consumption were always
# checked, but WORK REACHING COMPLETION was the gap the hygiene stall lived in
# (see the settlement plan) — the same hole the selftest had one level down.
# Note avatars are counted by TYPE, not by the host's child count: the host
# also parents the pooled CrewSiteMarker nodes, so a child count reads high
# whenever crew work is on the board.
# After the reset it flips "Simulate & draw NPCs" OFF in memory and asserts
# the roster froze, the host + crowd renderer were freed and the habitat lost
# its demand override, then that all of it resumes when switched back on.
# Cleans its cap_pop_* graph items off the map autosave:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=population --shots-dir=<label> --quit-after-capture
# Settlement view capture (WINDOWED — the mode's whole risk surface is
# invisible to every other harness): opens the view through Main's REAL entry
# point and shoots five zoom stops (eye 1.7 / street 12 / block 60 / camp 300 /
# site 1200 m), dumping height, pitch, near/far, scale label and prop-cull
# reach per stop. At each stop it drives SiteTargetPicker at a known agent's
# screen position — that is the ANGULAR pick radius (`t·tan(0.6°)`) end to end,
# the one line that makes a person clickable at every zoom and which is
# invisible to both code review and screenshots. Beyond ~52 m the radius
# exceeds a body, so picking a NEIGHBOUR is correct and only the sub-4 m stops
# demand exact identity. Ends with the anti-snowglobe assertions: the player
# camera is current again, `time_scale` NEVER moved, and the cull override is
# cleared. The harness parks the clock at --time BEFORE opening (the view must
# not touch it; the harness may, or a run after sunset ships five dark PNGs):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=settlement --shots-dir=<label> --quit-after-capture
# Window Wall capture (WINDOWED): opens the multi-monitor view through Main's
# REAL entry point with prefs forced IN MEMORY (the player's window_wall.cfg is
# never written) and proves what a PNG cannot: every slot camera shares ONE
# origin and ONE basis and differs only by its frustum (size/offset/near/corner
# hits DUMPED per slot), the extra native windows exist fullscreen with
# KEEP_WIDTH frustum cameras, U twice restores every CanvasLayer EXACTLY, a
# nudge moves all cameras together, a key pushed into an EXTRA window reaches
# the view (the relay node — `window_input` never fires for push_input), the
# "live" clock mode claims 1x + syncs the date and hands both back, and
# close() restores the ROOT WINDOW, the embed flag, the player camera, the UI
# map and the player's process mode. One PNG per window per state. On a
# single-screen machine every slot lands on screen 0 as overlapping fullscreen
# windows, which still proves creation, restoration and the maths:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --world=mtvernon --capture=windowwall --shots-dir=<label> --quit-after-capture
# NPC pose portraits (WINDOWED): stands ONE stick figure per work-pose family
# in empty air against sky and shoots it NEAR (2.5 m) and FAR (13 m), printing
# the family asked for beside the clip the pose machine actually chose — which
# is what separates "this pose looks wrong" from "the machine picked the wrong
# clip", two different bugs in two different files. `--capture=npc-anim` cannot
# do this job: it observes only is_rigged() avatars, and the rigged Mixamo body
# aliases all seven families onto its single `work` clip, so the families only
# exist on the stick figure. Traps it handles: it FORCES NpcDisplayPrefs to
# STYLE_SIMPLE and restores it (a global persisted player preference); the
# avatar must be add_child'ed because _simple.pose runs only from _process;
# `paused` must be false even though the harness freezes time_scale; the
# transitions are ONE-SHOTS so they are pinned via the anim_map slot override
# rather than waited for; `carrying` OVERRIDES the family so it is set for
# haul_hold only; and the camera sits BELOW the waist looking up so the horizon
# never crosses the silhouette:
Godot.exe.exe --path . --windowed --resolution 900x900 -- --user-map=mtvernon --capture=npcpose --shots-dir=<label> --quit-after-capture
# Labour merge verify (WINDOWED, console-only, needs a REAL TerrainLoader map):
# parks a processor on a `chore_hours` step with the ledger at infinite_labor
# false and ZERO abstract pool, then asserts the whole merge: the step asks for
# CREW (not a confirm), a chore is minted AT the machine's bound prop (so
# people walk to it), somebody finishes it and the step resumes, and — the
# contract no screenshot can show — `chore_hours_consumed_total` moves by
# EXACTLY the step's hours. A second accounting path shows up here as a
# doubling and nowhere else. Cleans its cap_lab_* items and prop afterward:
Godot.exe.exe --path . --windowed --resolution 640x480 -- --user-map=mtvernon --capture=labour --quit-after-capture
# Site Projects end-to-end verify (WINDOWED, needs a REAL TerrainLoader map —
# the delivery path is loader-only): seeds a 12-person pop-driven habitat +
# tanks + spaces, delivers the StarShade kit, and walks the WHOLE unified
# camp-lifecycle mechanic with console asserts + a PNG per stage: crates
# spawn AT the container door carrying delivery identity + staging slots and
# an unload project lands on the board; a CARRYING dot is observed and the
# crate record moves to staging via the chore's COMPLETION effect (the world
# only changes when labour is done — a preempted carry moves nothing); a
# linkage build project grows the ghost structure's beam
# visible_instance_count with real labour; the erect phase's unpack effect
# plays the deploy sweep (packed:false, linkage_deployed, build_state
# cleared); the reverse breakdown project folds it back to packed:true.
# Round 2 added a SECOND delivery (starter_camp, 7 crates) whose strategy
# NpcHaulModel picks from crew density — brigade = one crew chore with the
# crates flowing as stage effects — asserting every crate reaches its
# staging slot either way. NOTE the carrying flag is sampled at a CRAWL
# (~7×, per-frame polls) before the clock speeds up: at 720× a carry leg is
# sub-frame and a 0.5 s poll never catches it.
# Round 3 asserts: crates spawn STOWED INSIDE the container (inside the
# interior footprint, at the solved stack height) and a hauled crate is set
# down with y_offset ~0 and no `stowed_in` — the XZ checks pass either way,
# so a crate left floating at stack height would otherwise ship invisible
# (and a stale `stowed_in` silently BLOCKS the erect phase's unpack, which
# is how that bug was caught); the teardown strips hardware while the beams
# stand (05a_stripping); and the experiment lab runs, dumping the whole
# variant table (sim / plan / drag / status per row) to console, because a
# PNG cannot tell you whether a makespan is 6 h or 60 h.
# Runs the board on night_shift and steps the clock by time_scale (never a
# >6 h jump — the catch-up path would reroll the roster). Cleans its
# cap_prj_* graph items off the map autosave:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=project --shots-dir=<label> --quit-after-capture
# Settlement view (WINDOWED): opens the mode through Main's REAL entry point,
# seeds a small crew (so the picking assertions have somebody to click), and
# shoots five zoom stops — eye 1.7 / street 12 / block 60 / camp 300 / site
# 1200 m — dumping what a PNG cannot show: height, pitch, near/far, the scale
# label and the prop-cull override. At each stop it projects a known agent to
# screen and resolves the ray BACK through SiteTargetPicker, which is the
# angular-pick-radius property end to end; past ~500 m the radius exceeds the
# spacing between people, so "picked a neighbour" is correct and only "picked
# nobody" fails. Ends on the ANTI-SNOWGLOBE assertions: the player camera is
# current again, the prop-cull override is back to 0, and `time_scale` NEVER
# MOVED — no view may freeze the clock (the snowglobe used to; see SoI stage):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=settlement --shots-dir=<label> --quit-after-capture
# NPC animation observation on a REAL saved map (WINDOWED, READ-ONLY): unlike
# --capture=population (which SEEDS its own spaces/tanks/habitat and would
# overwrite a curated site), this finds whatever pop-driven habitat is already
# saved, stands the camera in the middle of the roster (the rigged body is
# handed out by distance from the VIEWER — observing from spawn means nobody is
# ever rigged and no clip ever plays), anchors the clock at 08:85 because
# routines make people travel only at BLOCK BOUNDARIES, drops time_scale to
# 0.02 so the transition budget gate can open at all (a 5-min bathroom visit is
# 1.7 s at 0.05 and 4.2 s at 0.02, against a ~2.6 s requirement), and asserts
# nobody holds a lying/seated pose while the sim says they are travelling:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=<file.tres> --capture=npc-anim --shots-dir=<label> --quit-after-capture
# Penstock placement verify (WINDOWED, needs a REAL TerrainLoader map — the
# terrain scan and prop placement are loader-only). Drives the whole "drop the
# pipe uphill and THAT is the source" path: scans rings for genuinely high
# ground within 90 m, seats a PowerSpout bound to a real prop at the site
# centre, then calls the same SystemGraphView.create_penstock_intake_at both
# the Lab gizmo and the 3D plug-drag commit through. Asserts what a screenshot
# cannot: a Stream Intake prop + graph node exist at the release point (a
# conduit has NO free endpoints — a `resource` item only gets a 3D anchor via
# bound_prop_id), the run RENDERED (3D wires default OFF, and ConduitManager
# ignores model changes while they are — the original "route does nothing"
# bug), the rebuild stamped a measured run ≥ the straight chord plus endpoint
# inverts falling toward the turbine, and the turbine ADOPTED run/bore/head and
# produced power. That last group is the one that failed first: a stream intake
# has no water LEVEL, so the pond path bailed before adopting the route — and
# the fix's change-gate then hid itself, because `absf(NAN - x) > 0.01` is
# FALSE and an unset outlet_invert_m never got its first write. Cleans its
# cap_pen_* items + props afterward:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=penstock --shots-dir=<label> --quit-after-capture
# Whole-site balance (WINDOWED, console-only, the player's own world, graph
# CLOSED): every hydro turbine with DC wires reaches a battery (a controller's
# battery terminal is the bank bus); SolarUI's graph-DC term equals the wired
# turbines' output and the battery integrates it; a turbine making watts moves
# water; each pond's graph level == its 3D surface and its own 3D plane follows;
# an 8 mm/h storm books rain on each pond's surface and raises it (or it spills
# / a siphon drains it). The Mt Vernon playtest of 2026-10-12, formalized:
tools\harness.ps1 -World mtvernon -Capture sitebalance
# Power Scoreboard daily counters (sandbox): dawn -> past midnight, the
# TODAY column (solar / wind & hydro / max capture / generated / consumed,
# from the timeline's solar/aux/raw/load channels) counts up, resets at
# midnight, YESTERDAY takes the day's solar, a scrub back rewinds it:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/solar_scoreboard_probe.gd
# Energy balance (sandbox, edits the graph in memory): a load switched on
# inside a scrubbed-back hour drains the battery, solar follows the sun with
# the graph OPEN, double-clicking a turbine switches it off (0 W, SolarUI's
# hydro term drops, no Hydro Lab) and on again. Prints the graph's readouts
# beside SolarUI's:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/energy_balance_probe.gd
# Sim pre-render substrate (offline — core/sim/: SimBakeStepper's contract
# over stubs: step order energy → people → camp power → water, 0.1 h
# population substeps, the FLOOR vs HYSTERESIS AC rules (off at 10 %, back
# at 20 %, loads shed in the series), hydro-into-battery coupling, keyframe
# cadence. EXPECTED_CHECKS; --import first. The cache, replay_at, truncation
# and the engine-state snapshots are pinned in resource_flow_selftest
# (_test_model_revisions / _test_replay_truncate_and_snapshots /
# _test_sim_render_cache) and the energy fill in source_physics_selftest):
Godot.exe.exe --headless --path . --script core/sim/sim_render_selftest.gd
# Sim pre-render end to end (sandbox): renders the next 24 h through
# SystemGraphView.sim_renderer() and asserts the clock, every tank, the
# battery and the claims are back at the playhead, the cache covers the
# range, user_rev did NOT move (a render is sim writes only — the probe turns
# on GraphModel.trace_user_rev, which names any writer that forgot the
# bracket), then runs the clock INTO the range: the ambient tick replays
# (flow_engine idle, flow_replay busy), tanks == their timelines, the 3D
# pond follows, the battery reads the rendered SOC; a capacity edit cuts the
# range at the playhead and the live step resumes; a scrub back replays:
tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/sim_render_probe.gd
# Graph-CLOSED cost bench + the flow engine's ACCURACY PIN (sandbox): F3
# sections at 60x and paused (incl. the once-invisible gv_pond_push /
# gv_dc_throttle / gv_faults / gv_placeholder), a user_rev PASS line (no
# writer outside the sim-write bracket over 10 s), then 24 h of render_step
# from a fixed clock hashed over every tank / wire / telemetry. Every live-sim
# optimization must leave that hash unchanged (2026-10-17: fe644fbb3825ae00
# on the Mount Vernon world as saved that day; 2026-10-18: 1205f81ade523735
# at HEAD 646f533 AND after the perf pass — the world file had changed, the
# code had not. ALWAYS take the before-hash on the same world in the same
# session; the saved world moves it):
tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/flow_step_bench.gd
# FIRST-PERSON frame bench (sandbox, either world): graph closed, clock parked
# at noon, every F3 section at 1x / 60x / paused, render CPU / GPU split, draw
# calls, the nav-bake + crowd-raster progress and the F4 processing histogram.
# The sections main_fx / planets / terrain_season / stream_tracers / prop_ticks
# / placed_lights / interact_focus / solar_ui / timeline_ui / hud_layout were
# added 2026-10-18 through `PerfSpan` (core/perf/perf_span.gd — autoload-safe,
# use it in any script a selftest loads under --script; a bare `PerfMonitor`
# there fails the compile). Baselines in plans/HARNESS_MATRIX.md:
tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/first_person_bench.gd
# GPU isolation bench (sandbox): the renderer's measured GPU ms with ONE
# feature or scene layer off at a time (SSIL, SSAO, volumetric fog, glow,
# MSAA, sun shadow, vegetation, props, tiles, buildings, water, camps, people,
# lights, ground), then the canopy shaders re-rendered as alpha scissor /
# alpha-to-coverage with a PNG per variant under screenshots\gpubench\.
# `-UserArgs @("--veg-groups")` hides each species/tier batch group in turn.
# 2026-10-18 on Mount Vernon: vegetation 24 of 31 GPU ms, MSAA 8x another 12:
tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/gpu_toggle_bench.gd
# Hydro LOAD-TIME diagnostic (WINDOWED, console-only, needs a REAL saved map with
# hydro on it): dumps every penstock/culvert conn's visible_3d, routability, 3D
# instance and BOTH resolved endpoint anchors at four moments — as loaded (graph
# never opened), graph open, back in 3D, and after a Hydro Lab round trip. It
# exists because those states differ: item elevations used to be resolved only on
# graph-view entry, so a culvert loaded anchored at world Y ~ 0 and fired into the
# sky until the player pressed G. Asserts up front that no culvert outlet sits
# above its inlet and no endpoint pair is stranded 120 m apart, and — the state
# no screenshot of this run can show — the WORLD-VISIBILITY gate at each moment:
# runs hidden in first person, shown while the Lab CT is up, and the global
# wires pref handed back on graph close (see "Conduits are x-ray by design"):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=hydroload --quit-after-capture
# Siphon auto-bind distance-cap guard (WINDOWED, console-only): places a NEAR
# pond and a FAR pond next to a synthetic siphon and confirms bind_siphon_to_
# nearest_pond(id, silent, max_dist_m) binds the near one, refuses the far one
# beyond the cap, and an uncapped manual Rebind ignores distance — the
# guardrail behind auto-bind-on-placement (Phase 3):
Godot.exe.exe --path . --windowed --resolution 640x480 -- --world=mtvernon --capture=autobind --quit-after-capture
# Stable pond-id guard (WINDOWED, needs a REAL TerrainLoader — generated
# location maps only, e.g. a throwaway --map-lat=/--map-lon= test coordinate,
# NOT the trusted built-in scenes which have no TerrainLoader): carves a pond,
# adds it to the graph, then re-designates the SAME basin with a reshaped
# polygon (forcing EarthworksBuilder.basin_tag_from_poly to derive a DIFFERENT
# tag — exactly what resizing/reshaping an existing pond does). Asserts no
# duplicate water-body record, pond_id preserved across the tag change, and
# the graph tank still resolves to the live re-shaped pond with no manual
# healing. Clean up the throwaway coordinate's files under user:// afterward
# (maps/, saves/graph_autosave/, terrain_cache/, weather_cache/, scores/ —
# all suffixed with the test lat/lon token):
Godot.exe.exe --path . --windowed --resolution 640x480 -- --map-lat=<f> --map-lon=<f> --half-extent=3000 --capture=pondid --quit-after-capture
# Downhill-culvert-routing guard (WINDOWED, needs a REAL TerrainLoader — a
# throwaway generated-map test coordinate, NOT the trusted built-in scenes):
# builds a siphon, calls ensure_siphon_outlet_sink, and confirms the outlet
# either (a) traced a real downhill route (Watershed.trace_downhill over the
# actual DEM — route_3d has waypoints, invert is a real terrain elevation, the
# site moved off the old fixed +12m/-9m chord) or (b) correctly fell back to
# the fixed +12m offset on flat/no-DEM terrain — either is valid; only "neither"
# is a regression. Clean up the throwaway coordinate's user:// files afterward:
Godot.exe.exe --path . --windowed --resolution 640x480 -- --map-lat=<f> --map-lon=<f> --half-extent=3000 --capture=culvert --quit-after-capture
```

Gotchas: headless runs rename `addons/**/~lib*.dll` → `*.TMP` (restore with
`git checkout`, delete TMPs). Don't `git stash` around headless runs — the
ignored `.godot` class cache goes stale. If the Godot editor is open during
file operations, it can resurrect deleted/modified scenes from memory on save.

## First-person ambient bed (core/audio/, 2026-10-18)

The world used to be near-silent on foot. `AmbientBed` (a Main child made
in `_ready` beside StageMusic) plays four non-positional layers under ONE
pure rule, `AmbientMix.levels(inputs)`: **wind** from WeatherService's wind
speed (Beaufort: nothing under 1 m/s, full by 14), **rain** from
`rain_rate_mmh` through the met classes NpcComfort uses (light < 2.5 mm/h,
moderate to 7.6, heavy beyond), the nearest **stream**'s Manning velocity
(`WaterNetwork.nearest_flow` — ONE station's hydraulics, full within 6 m,
gone by 60) and **birdsong** gated by `DaylightModel.sky_light` (none at
night, the chorus from civil dawn, quieter under a high sun) × the forest
round the listener (`TerrainLoader.forest_trees_within`, trees only — a
bbox pass over both layers' records, every 2 s) and hushed by rain and
wind. The master is `NpcDisplayPrefs.ambient_volume` (Settings → NPCs,
beside the stage music), ZERO while `SimFxRate.is_paused` (a frozen world
is silent, like the fire and the lights) and away from first person (the
graph hides the world; a camera claim — settlement view, globe, window
wall — swaps the camera; the drone borrows the player's and still hears
the wind). Gains ease with `AmbientMix.smooth` (0.6 s); wind rides two
slow sines as gusts; birds are single calls on a Poisson clock over
one-shot players (deterministic hashes of the gust clock, never randf).
- **No shipped audio.** Each layer plays the player's own
  `user://ambient/<wind|rain|stream|birds>.{mp3,ogg,wav}` when one exists,
  else `AmbientSynth`'s procedural loop made once at load: filtered noise
  (wind dark, rain bright with drops, the stream mid-band with a two-tone
  bubbling) cross-faded tail-into-head so the loop point is SEAMLESS (the
  selftest pins the join step), chirps as 2–4 sine sweeps.
- **The sound-effects mute** (`UiSfx`, the UiSound autoload; Settings →
  UI sounds and the timeline's 🔇/🔊 button) mutes the `UI` and `SFX`
  AudioServer buses. The bed, thunder and the extinguisher play on `SFX`
  (`UiSfx.sfx_bus()`): a new world effect must too, or the mute misses it.
  Muted by DEFAULT (`audio_prefs.cfg [audio] sfx_muted`, a new key so every
  install starts muted once). Stage music is not an effect and stays on Master.
- Probes read `inputs()` / `levels()` / `gains()` / `debug_line()` and
  force the rule through `override_inputs`.
- **No tour stop**: the tour is hero stills and the bed has no pixels.
  `tools/checks/ambient_bed_probe.gd` is its gate instead (Validation list).

## Feature tour (core/tour/ — the show-people-what-it-does harness)

A recordable visual tour of every mode: a title card per feature (chapter,
name, one line, and the REAL key read from the InputMap), a short demo, one
clean hero screenshot, and `docs/FEATURES.md` + the README gallery generated
from the same metadata. **A new player-facing feature gets a tour stop.**
- **One stop = one file**, `core/tour/stops/NN_<id>.gd` extending `TourStop`
  (metadata in `_init`: id, title, chapter World/Build/Systems/People/Labs,
  summary, how[], action and/or button, world mtvernon|walton, budget_s,
  hour, optional, blurb; hooks `setup` / `run` / `teardown`, all may await).
  `TourCatalog` finds stops by scanning the folder in file order — copy
  `stops/_template.gd`, no other file changes. Keep chapters contiguous in
  the numbering (the selftest checks it).
- **`TourContext`** is the stop's toolkit: wait (× pace), hold(actions),
  caption, hero() (captions + nested CanvasLayers hidden for the grab, PNG +
  1280 px JPG), shot, a tour camera on Main's camera-claim stack (place / fly
  / orbit), set_hour / scrub / run_clock / hour_for_sun, press(action) via
  the action's real key, open_graph(lens) / graph_orbit / graph_select,
  open_festival / settle_cam / space_xz, prop_records / nearest,
  require(ok, what). ⚠ Stops reach game classes through `ctx.klass("Name")`
  and autoloads through `ctx.autoload("Name")`, NEVER by bare identifier:
  the selftest loads every stop under `--script`, where an autoload name
  does not compile (the headless trap).
- **`TourDirector`** (launched by `--capture=tour`, registry entry `tour`):
  opening card → per stop: baseline (player back at the tour's start
  transform, first person, no lab / graph / globe / festival / forced
  weather, clock at real time, the stop's hour) → title card → setup + run
  raced against the budget (a script error or an overrun cancels it and the
  tour moves on) → teardown → one `tour PASS|FAIL <id>` line → closing card.
  Budgets and offsets run on the frames' own delta, so under Movie Maker they
  are in VIDEO seconds. Hides `UILayer/InteractionPromptUI` for the run.
  Writes `tour_manifest.json` (per stop: metadata, resolved key, status,
  failures, shots, start/end frame and seconds).
- **`tools\tour.ps1 -Mode stills|live|record`** groups the chosen stops by
  world, runs one sandboxed harness pass per world (`-EngineArgs` /
  `-UserArgs` were added to harness.ps1 for this), and merges the manifests in
  FILE order. `record` adds `--write-movie <w>.avi --fixed-fps 30` (Movie
  Maker: fixed timestep + game audio, smooth however slowly it renders), then
  ffmpeg cuts one clip per stop, reassembles them in tour order as
  `tour.mp4` and writes `chapters.txt`. `live` = slow pace for OBS.
  Output under `screenshots\<label>\`; `screenshots\tour_latest.txt` names
  the last run.
- **`tools/tour_docs.py`** (stdlib): merges the run into
  `docs/tour/index.json` (a partial run refreshes only its stops; a FAILED
  stop keeps its previous image; deleted stops are pruned), copies the hero
  JPGs to `docs/tour/<id>.jpg`, writes `docs/FEATURES.md` and rewrites only
  the README block between `<!-- TOUR:BEGIN -->` / `<!-- TOUR:END -->`. The
  full-video link comes from `docs/tour/video.json` (edited by hand after
  uploading; nothing is uploaded).
- Iterate on one stop: `tools\tour.ps1 -Mode stills -Stops <id>`.
- **The site's address never reaches a screenshot** (`SitePrivacy`,
  `core/site_privacy.gd`).
  - A world's place label is the reverse-geocoded street address. These
    printed it: the loading screen ("Loading <address>"), the Site Report
    header, coordinates and footnote, the world panel, the world list and
    the record book.
  - Each now goes through `SitePrivacy.place()` / `coords()`. The harness
    switches those to "this site" / "location hidden" for EVERY run;
    `--show-location` opts out for a private debug run. Only display text
    changes, never saved data.
  - `TourContext.hero` then walks the visible text and FAILS the stop if the
    real label's identifying pieces (parts with a digit, the first two
    parts) or the coordinates at 3 dp are on screen.
  - A new UI that prints the site label or lat/lon must use those two
    helpers. Selftest: `core/site_privacy_selftest.gd`.
- `HarnessInput` (`core/terrain/harness/harness_input.gd`) is the shared
  real-input toolkit the tour uses (mouse press/move/click/drag, key, action
  press through its bound event, action/event labels, find_button); the
  older captures still carry their own `_lc_*` / `_ae_*` / `_bs_*` copies.

## UI foundation — theme, font, icons, text, HUD layout, audit (2026-10-13)

Plan: `~/.claude/plans/i-want-you-create-mutable-sonnet.md` (UI polish +
UX streamlining; user's choices: Inter, Lucide, HUD auto-tucks into pills,
1080p primary / 720p usable + a UI scale).
- **`UiAudit`** (`core/terrain/harness/ui_audit.gd`, pure over the live
  tree) finds overhang, clipped, owner-vs-owner panel overlap, text-on-text
  overlap, hard truncation, tiny hit targets and raw text ("(s)", ids,
  3-decimal numbers). Modal layers (≥ 50) are exempt from overlap. The tour
  runs it at every hero shot (`-Audit report|strict|off`), writes
  `stops/<id>/ui_audit.json` (with the HUD manager's own `hud` snapshot +
  per-panel `debug`), and `python tools/ui_audit_report.py <run> --compare
  <baseline>` tabulates it. Baselines: `screenshots/ui_base_1080`,
  `ui_base_720`. Canvas-drawn text reports truncation through
  `UiText.fit(...)` → `UiAudit.note_canvas_truncation`.
- **Theme**: `UiThemeBuilder` (`scenes/ui/ui_theme_builder.gd`) builds ONE
  Theme from UITheme's palette (buttons, fields, popups, tooltips, tabs,
  lists, slim scrollbars, sliders, dialogs) and `install(root)` merges it
  into `ThemeDB.get_default_theme()` + sets `ThemeDB.fallback_font` —
  ⚠ a theme set on the root does NOT reach Controls under a CanvasLayer
  (propagation stops at non-Control parents), which is every HUD here.
  Installed from `CursorController._ready`. Font: Inter (OFL,
  `assets/fonts/inter/`), `UITheme.font(weight, numeric)`; the numeric
  variant turns on tabular figures so changing readouts do not jitter.
  `FONT_XS` is 11. The `style_*` helpers still work as overrides.
- **UI scale**: `user://ui_prefs.cfg [ui] scale` (`UiThemeBuilder
  .scale_pref/set_scale_pref`, `SCALE_CHOICES`, Auto = 1.0 at ≥ 1000 px
  tall, 1.25 at 720), `--ui-scale=` on the CLI; drives the root window's
  `content_scale_factor`. Stretch mode is `canvas_items` at 1920×1080, so
  the LOGICAL layout is ~1920×1080 at every window size — 720p only shrinks
  the text, which is what the scale corrects.
- **Icons**: Lucide (ISC, `assets/ui/icons/*.svg`, `.gdignore`d) compiled by
  `tools/ui_icons_build.py` into `scenes/ui/ui_icon_data.gd`;
  `UiIcons.icon(name, px, stroke)` → a cached white `DPITexture` (crisp at
  any scale, tint with modulate / icon colour), `UiIcons.apply(btn, name,
  tip)`. Add an icon: drop the SVG in, re-run the tool.
- **`UiText`** (pure): `plural` / `count` ("1 day", "3 days"; irregulars),
  `num(x, unit, sig)` (SI prefixes for W/Wh/J/V/A/Hz/g/Pa; litres only
  from 10 kL), `thousands`, `duration`, `pct`, `sentence`, `from_id`,
  `fit`. Never write "(s)" or a raw id to a player again.
- **`HudLayout`** (`scenes/ui/hud/hud_layout.gd`, Main child created in
  `_ready`, `ServiceLocator` key `hud_layout`; pure solver
  `HudLayoutCore`) places the first-person HUD. A panel REGISTERS
  (`HudLayout.register(node, id, region, {order, priority, tuckable, title,
  icon, size: Callable, compact: Callable, place: Callable, ignore_layer})`,
  queued if the manager is not up yet) into top_left / top_right /
  top_center / bottom_left / center_prompt; the manager stacks each region
  inside the screen and above the timeline (`get_stack_height`, live) and
  writes position AND size. A tool or mode CLAIMS
  (`HudLayout.claim(owner, {inset: {left, top, right, bottom}, tuck: [...],
  hide: [... | "*"]})`, `release(owner)`, nested like the camera / clock
  claims; helpers `claim_right_dock(owner, dock, w)` and
  `claim_modal(owner)`): insets push every region clear of the tool, tucked
  panels become pill Buttons (compact text, refreshed 2×/s; click = peek
  until the pointer has been away 1.5 s). Registered today: weather card,
  scoreboard, terrain options, Fun Meter (until dragged), hazard / vibe /
  peak chips, toasts, settlement feed, interaction prompt, the settlement
  view's status / festival / log / card panels, the work dock, the ride
  dashboard. Claims: graph (hides the HUD), edit toolbar (insets + tucks),
  Light Studio + prop editor (right dock), settlement view (tucks), Site
  Report + in-game location picker (`claim_modal`). Rules that carry it:
  - A panel's own visibility writes are its INTENT; while it is tucked or
    hidden the manager puts it back — ⚠ DEFERRED (`_revert_suppressed`):
    `visibility_changed` fires BEFORE the change propagates to children,
    so re-hiding inside the handler left every child's "visible in tree"
    cache set and the scoreboard's body drew on under the graph.
  - A panel on a hidden CanvasLayer frees its slot and is not written
    (it reappears in place) — unless a claim would hide or tuck it anyway,
    then it is hidden now. Ancestor layers' `visibility_changed` requeue the
    layout; a 0.5 s poll is the backstop. The node is PROCESS_MODE_ALWAYS.
  - An untuckable bottom-left panel outranks the top-left column: the
    column tucks (lowest priority first) until it fits.
  - A dragged Fun Meter unregisters (its saved position wins).
- **Timeline info row** (`timeline_ui._layout_info_clusters`): measured —
  the centre (clock / transport / date / sun-moon) sits centred when it
  fits and slides into the gap between the side clusters when not; the
  right cluster folds its least-used buttons (`_right_fold_items`, fold
  order) into a "⋯" MenuButton, change-gated on the fold COUNT (it runs as
  the clock text changes; hiding a hovered button per frame would flicker).
  Width changes of the centre / chips requeue it.
- The edit toolbar's options bar is an `HFlowContainer` (it wraps instead of
  running off the right edge), its strip is an accordion of sections, and
  `_sync_hud_claim` keeps the strip under the bar.
- **Graph top bar** (`SystemGraphView._fit_topbar`): labels drop to icons in
  levels (lens chips → menus → the rest + the SoI chip) when the measured
  row would overflow. The level is chosen from MEASURED label widths and the
  buttons are written only when the level changes — ⚠ the first version set
  every button's text once per TRIAL level on every pass and crashed the
  engine (signal 11 in Button.set_text, twice, at graph open / the Globe
  stop). Dynamic labels (Wire: Metro, Designate · Roof) go through
  `_topbar_set_text` so a compact bar is not re-expanded. "Graph ▾" + "Site
  ▾" merged into "Share ▾" (graph ids < 10, site ids ≥ 10). The inspector
  form tames every row after building (`_tame_form_widths`: row labels
  ellipsize with a hover tooltip, free labels wrap, option buttons stop
  fitting their longest item) — one wide row used to stretch the whole form
  20 px past the sidebar.
- **Kit** (`scenes/ui/kit/`, class_names — `--import` after adding one):
  `KVRow` (key / value, both ellipsize, value tooltip, `make_with` for a
  control), `AlertBanner` (THE look for critical state: icon + status
  colour fill + left bar, `show_alert(level, text)` change-gated, `clear`),
  `ModalFrame` (backdrop, title/subtitle, one close button, scroll body,
  footer PRIMARY/SECONDARY/DESTRUCTIVE, CursorController modal +
  `HudLayout.claim_modal`, sized above the timeline), `SectionHeader`
  (small caps + hairline + note). In use: the dashboard's Site Balance
  (`SiteBalance.rows` — structured, `lines()` kept for the selftest) and
  the SolarUI scoreboard's AC-off / low-battery banner.
  - **Added 2026-10-14:**
    - **`IconButton`:** `make(icon, tip, cb)`, `style(btn, …)`, plus
      `close(cb)` / `as_close(btn)`, which is THE close button. It has a
      Lucide "x", a hover face and a 28 px minimum hit target. Before this
      the close button was written four ways in 29 files.
    - **`Collapsible`:** a `FoldableContainer` that you fill through `.body`.
      Its look lives in `UiThemeBuilder`: a quiet title row, a Lucide
      chevron, semibold text. Persist its state from `folding_changed`.
    - **`DockShell.header(title, subtitle, on_close, extras)`:** the header
      row of the right-hand docks (prop editor, Light Studio, microclimate,
      work dock). Its title and subtitle ellipsize.
  - **Adopted everywhere a clean swap existed:** the close buttons, the
    row-delete "✕" (now `trash-2` or `x` with a tooltip), every panel's
    section-title helper (Settings' ~45 titles, inspector, dashboard, Hydro
    Lab dock, Linkage Lab / guide / hardware, work planner, routines, SCAD
    store, help, multiplayer) and the hand-rolled "▸/▾" toggles (Linkage Lab
    groups, hardware modal, veg Tune look, camp scatter, Hydro Lab folds,
    Light Studio sections).
  - **The inspector's "Advanced" sections are a `Collapsible` HEADER only.**
    Their fields are built lazily straight after it, and toggling rebuilds
    the form.
  - **Deliberately NOT converted:**
    - Panel-level collapse / tuck toggles (Terrain options, weather card,
      scoreboard), because `HudLayout` sizes those panels.
    - The edit toolbar's strip accordion, which follows the active tool.
    - Footer text buttons ("Close" beside "Try again").
  - **No `Pill` class:** `HudLayout` owns the one pill and `UITheme.chip_style`
    the chips.
  - **No `StatTile`:** the Hydro Lab deck is its only user.
  - **Panels registered with `HudLayout` report their REAL minimum width**
    through the `size` callable (`maxf(design_w, get_combined_minimum_size().x)`).
    Terrain options declared a fixed 260 px while its content needed 284, so
    it hung 12 px off the right edge. `--capture=poi` caught it; that capture
    now turns pins ON for its own checks, since the player's `show_pois` pref
    may hide them.
- **Modals (`UiFit`, `scenes/ui/kit/ui_fit.gd`).** Every modal panel sits
  in the area ABOVE the timeline and never larger than it:
  `UiFit.keep_fitted(panel, want)` (re-fits on resize / show / content
  growth, and claims the HUD while visible unless `claim_hud` false) or
  `UiFit.adopt(panel)` for an existing modal (reads the intended size off
  the panel, lifts it out of a CenterContainer). `UiScreenLayout.
  clamped_center` follows the same rule. `UiFit.tame_widths(root)` is the
  shared form of the inspector's width pass. A new modal: register with
  `CursorController.request_modal(name, close)` WITH the close callable
  (without it Esc and every other flow that pops the stack leave it open —
  the Record Book and the SCAD store stayed up behind every later modal),
  and `HudLayout.claim_modal(name)` / `release` beside the cursor calls.
  The content must scroll: fitting cannot shrink a container below its
  children's minimum (the Lab's right column was 820 px of fixed insets +
  stats).
- **Edit toolbar options (T / V / C, 2026-10-14).**
  - Parameter specs carry a human `label`, a `unit` (the SpinBox suffix) and
    an optional `auto_below`. A value under `auto_below` reads "Heading ·
    auto". Never put the unit or "(-1 auto)" in the label again.
  - `SliderSpinRow.add_param` is the compact row. Its slider is FIXED width:
    an expanding slider fills a flow row and spreads the parameters apart.
  - Strip tools carry Lucide icons (`TOOL_ICONS`).
  - The options box is an `HFlowContainer`, so a section's row builders must
    take `Container`. The water controller typed `HBoxContainer` and silently
    built NO rows for every water tool until `--capture=water` showed four
    script errors.
- **`--capture=modals`** (`ModalAudit`, `core/terrain/harness/
  modal_audit.gd`): opens all 19 reachable modals through their real entry
  points, audits, shoots `<id>.png`, closes; prints one `modalaudit <id>:`
  line each (incl. "hud up: …" for a modal that left HUD panels showing)
  and writes `modal_audit.json`. `--modal-audit=strict` turns audit errors
  into FAILs. `tools\harness.ps1 -World mtvernon -Capture modals -UserArgs
  @("--window-size=1280x720")` checks the small screen (any capture honours
  `--window-size`). 0 errors at 1536×864 and 1920×1080 on 2026-10-13.
- **Harness window size.** project.godot opens MAXIMIZED, which overrides
  `--resolution`: every "720p" capture was really shot at the monitor's
  size. `tour.ps1` passes `--window-size=WxH` and the harness resizes the
  window (`_apply_window_resolution`; the tour or `--exact-resolution`
  only — older captures post raw window coordinates). `HarnessInput` now
  posts mouse events in viewport coordinates (`push_input(ev, true)`).
- `tour.ps1` reports a CRASHED pass: a native crash exits negative and used
  to read as success with that world's stops silently missing; now exit
  5 / a FAIL line naming the stops that never reported.
- The settlement's "Nobody can reach a X" alarm latches ONCE per need for
  the site (`_alarm_habs`), not once per camp.
- **Copy sweep (2026-10-14).** 87 player-facing counts in 42 files go through
  `UiText.count(n, "<singular>")`. Prints, selftests and dev readouts (fps,
  ms, tris) were left alone. The JS-parity notes in `core/linkage/build` and
  `coverings` were left alone too, because the parity fixtures diff them.
  Irregular plurals take the third argument (`count(n, "axis", "axes")`).
  A new `"%d nodes"` in a toast or label is a regression.
- **Resource hub names** (`graph_canvas_v2._hub_name_lines`): one line if it
  fits; else two balanced lines at a word break, shrinking up to 20 %; each
  line is tested against the circle's CHORD at its own height. Anything that
  still fails becomes a CAPTION beside the circle. Ports are on the top and
  bottom edges, so the sides are free. The circle then keeps just the
  quantity. The tour at 720 strict is at 0 findings across all 32 stops.

## Graph tools, solar grids, settings, 3D routing (2026-10-14, later)

Plan: `~/.claude/plans/pasted-content-id-aeda-ok-good-composed-umbrella.md`.
Each piece has its own harness gate (Validation list).
- **Timeline clock** (`timeline_ui._pin_label_widths`): the clock, sunrise /
  sunset and moon labels use tabular figures AND are pinned to their widest
  possible text. The unpinned proportional clock re-centred the whole centre
  cluster every sim minute (measured 24 px of jitter). `--capture=timeline`.
- **Settings modal** (`timeline_settings_panel.gd`): 1180×880 via `UiFit`, a
  grouped searchable sidebar (`CATEGORIES`; a page missing from it lands under
  "Other"), the TabContainer kept with its tab bar hidden so every
  `_build_*_tab(tabs)` and `current_tab` caller still works; `open_page(title)`,
  `page_titles()`, last page in `ui_prefs.cfg [settings] page`. The modal
  audit walks every page and FAILs if a nav entry is off screen at 720p.
- **Show-only views** (`GraphDomainFilter`, pure): Show ▾ in the DISPLAY
  cluster (Everything / Power / Water / Food & waste / Fuel & heat / custom
  ticks / "include nodes with no wire of that kind"), an amber canvas chip
  while on, saved with the graph (`view_filter`). Hooked ONLY in the canvas's
  `_compute_visible_items/_connections` (draw + every hit-test), the layout
  driver (Tidy/Live lay out what is shown) and ConduitManager
  (`set_preview_domain_filter`: runs of hidden kinds hide in the LENSES only,
  never first person). A hidden node is deselected. Ambient sun/wind ports
  never decide a node's domain.
- **"In the world, not on the graph"** (`GraphWorldInventory`, library drawer
  pinned on top): J lights, placed models with a library preset (by
  `model_id`), pv_array racks, Linkage structures, OSM solar in the SoI,
  ponds, scene devices / energy sources — each row Add (the SAME function the
  world path uses) and ◎ Locate. Replaced the "In Model" / "Scene Objects"
  shelves (the latter never skipped what was already on the graph).
- **Graph ↔ world handoff**: `locate_item_in_world`, `open_node_in_graph`,
  "Route in 3D" go through `open/close_graph_view` (they set `visible`
  directly and left gameplay paused). Return ticket: Esc in the settlement
  view after Locate comes back to the graph on the same node and lens (G
  there drops in — `SettlementView.last_close_was_drop_in`); finishing a
  Route in 3D reopens the graph; inspector **Walk to it** stands the player
  beside the node, and G comes back to it. The full-screen globe opens on the
  Globe lens's orbit and hands it back (`globe_orbit_state` /
  `apply_globe_orbit_state`, `SoiSnowglobeCamera.enter(..., orbit)`).
- **Solar grid snap** (`PvGridSnap`, pure; prefs `ui_prefs.cfg [pv_snap]`):
  edge to edge in the row (gap), or a row behind at the no-winter-shade pitch
  (`h_top / tan(90° − |lat| − 23.44°)`, floored at 10°), yaw locks within 12°,
  own array (same controller) first; Alt drags free. 3D: the placement ghost
  (`PlacedPropService.update_placement_aim`, the ghost's yaw is now placed)
  and the prop editor gumball, amber guide lines, "Line up this array"
  (`line_up_pv_array`). Graph: panel / array-card drag
  (`_pv_snap_delta`), Combine ▾ "Arrange array as grid" and Series/Parallel
  lay one row per series string (`GraphPvWiring.string_rows /
  layout_panels_grid`); Tidy moves an array as ONE block laid out as that grid
  (`GraphLayoutDriver.pv_groups / _collapse_groups`), Live keeps array panels
  still. Layout ▾ "Snap solar panels into grids" toggles both.
- **Conduit style modal is LIVE** (`conduit_style_modal.gd`): every control
  writes to the wire (0.15 s debounce, history suppressed, ONE undo entry on
  close), Revert restores the wire as opened, Done/Esc keeps. The preview is a
  copy of the REAL run (`ConduitManager.run_visual_copy`) framed on its bounds
  with ghost end boxes and a translucent path highlight for hairline runs; a
  run not drawn in 3D falls back to a material sample. The header measures the
  run (`ConduitLength`: m + ft, stock fit — "fits a 100 ft cord", sticks,
  coils — straight line, rise/fall, live I²R loss). Dropdowns come from
  `conduit_style_options.gd`, shared with the connection-port modal.
  ⚠ `_on_conduit_style_applied` no longer runs `sync_all` (live writes would
  rebuild every run at slider rate).
- **One length rule**: `ConduitManager.mesh_build_params` is THE tessellation
  rule for a run and `measure_route` uses it, so the routing HUD shows the
  committed `route_length_m` (with a snapped plug it measures the exact spec
  the release creates — the drag ghost path read ~3 % short). Inspector
  "Length" is read-only once routed. Run-length tags (`RunLengthLabels`,
  Settings → Gameplay "Show run lengths on 3D wires") at each run's arc
  midpoint; the toggle re-measures only the runs already drawn (a `sync_all`
  re-reads the 3D-wires pref and would clear them).
- **Routing**: the Globe / Site Plan **Connect (C)** tool (canvas
  `_handle_connect_tool_input`; pin → ground bends → pin, a port menu when
  several fit; the view makes the connection with `visible_3d`, the bends as a
  LOCKED `route_3d`, kind from the resource default). First person: a port
  prompt on the crosshair (`ConduitRouteController.port_under_crosshair`, the
  click's own rule, 8 Hz) and Shift+release chaining from the device just
  plugged into (`_next_free_port`). The HUD names the mode (plug / route / drag).
- ⚠ `ConduitMeshBuilder._build_dashed_tube_mesh` added a surface PER DASH and
  hit Godot's 256-surface cap on runs over ~256 dash periods (197 errors on a
  190 m run from the Globe); all dashes now go into one SurfaceTool surface.
- **Editing runs in the lens** (Globe + pin-mode Site Plan;
  `graph_canvas._draw_lens_runs` / `_handle_run_edit_input`, view
  `_on_world_route_edited`). Every built run is projected from
  ConduitManager's sample cache. Each run gets a pill: its value plus
  `ConduitLength.format(route_length_m)`. The Elevation projection pills
  carry the length too (`_wire_pill_text`). Clicking a run's line selects it.
  The selected run's LOCKED `route_3d` points are handles:
  - drag one over the ground (`_pin_ground_hit`, +0.3 m);
  - press the line and drag to insert a bend (an auto-routed run becomes
    locked);
  - double-click a handle to remove it (an empty route unlocks).

  Each gesture emits ONE `world_route_edited` on release. The view writes
  the route under `_history_suppress`, calls `force_remesh` (which
  re-measures) and pushes ONE history snapshot. The connect tool's own
  run is one snapshot too now; before, the add pushed a route-less
  snapshot.
- **"Place it here"** (`_ct_offer_place`). With Connect on, clicking the pin
  of a node with no 3D twin offers "Place it here". So does clicking the
  ground while such a node is selected (it may have no pin at all). The
  view's `_on_world_place_requested` places it through
  `_on_lib_place_model_requested(..., at_world)` →
  `PlacedPropService.place_prepped_at`. That is the ghost's own commit,
  split out of `confirm_placement` as `_commit_prepped`; a grey box is
  placed when there is no model. The node is bound and the run carries on
  from it. Pond / stream / PBI nodes are refused with the reason.
  `--capture=graphtools` drives all of it with real clicks.
- Not built: clickable legend toggles.

## Video export + camera keyframes (core/climelapse/, 2026-10-22)

The timeline's 🎬 renders a range to an MP4: it steps the world one frame at a
time with the clock held, draws each instant through its own camera into an
off-screen SubViewport and streams the frames into ffmpeg.
- **Why every export was black.** The 3D SubViewport's `get_image()` is RGB8;
  the old timecode compositor built an RGBA8 frame, and `Image.blit_rect`
  refuses mismatched formats (an engine error, nothing copied), so every frame
  stayed all-zero. The user's `climelapse_2024_04_18.mp4` was 1350 frames of
  Y = 16. The timecode is now a Label on a CanvasLayer INSIDE the capture
  viewport, so a frame is one image straight off the GPU and nothing is
  composited on the CPU. The capture viewport also copies the root viewport's
  MSAA / TAA / scaling / shadow atlas and the player camera's `environment`,
  `attributes` and `cull_mask` (`ClimelapseCameraRig`); without them it drew
  far darker than the game.
- **Frames go through a pipe, not PNGs** (`ClimelapseFramePipe`): raw rgb24 on
  ffmpeg's stdin via `OS.execute_with_pipe(..., true)` (a writer thread, a
  6-frame queue). ⚠ The pipe must be BLOCKING: non-blocking dropped every
  write once the buffer filled and ffmpeg wrote a 262-byte file (measured).
  ffmpeg runs `-loglevel error` so its stderr cannot fill; it is read after
  exit. `store_buffer` returns false once ffmpeg dies.
- **The options dialog** (`scenes/ui/climelapse_export_dialog.gd`, a
  `ModalFrame`): range (pre-filled from the Ctrl-drag selection; none = the
  next 24 h from the playhead), speed in sim-hours per VIDEO second
  (`ClimelapseExportOptions.TIME_PRESETS`: the bar's speeds, "Max" = the bar's
  Max = 2 h/s, then a day / 3 days / a week / a month / a season / a year per
  second, or any value up to `MAX_RATE`; or type the VIDEO LENGTH and the
  speed follows, `speed_for_length`), folder +
  file name, size (presets, the game window, custom; rounded to even for
  yuv420p), fps, CRF, the date/time strip, and render settings for the export
  only (graphics + shadow preset, MSAA, TAA, settle frames per video frame).
  Choices persist in `user://climelapse_export.cfg`. Frame i is at
  `start + i × hours_per_second / fps`, both ends included (24 h at Max,
  30 fps = 361 frames, 12.03 s).
- **While it renders** the export holds an exclusive clock claim
  (`climelapse_export`: time_scale 0, analemma off unless the export is an
  analemma), sets the root viewport
  `disable_3d` (the world is drawn once per step, by the export) and shows
  the export's own picture in the progress window. `_restore_world` gives back
  the claim, the graphics / shadow presets it changed and `disable_3d` on
  every exit path. A cancel keeps nothing (the partial MP4 is deleted).
- **Camera keyframes** (`ClimelapseKeyframes`, replacing the untimed
  waypoint list): each key is pinned to an absolute hour, saved per world
  (WorldPaths kind `climelapse_keys`). Between keys the camera follows a cubic
  Hermite in TIME (Catmull-Rom tangents over uneven spacing, zero at the
  ends, so the shot eases in and out; "Smooth path" off = straight lines);
  yaw is unwrapped the short way; fov lerps. 0 keys = a STILL shot from the
  current view, whatever the camera (2026-10-23: the drone used to make up a
  near-full-circle sweep of its own; `ensure_default_hyperlapse_path` is
  gone), 1 key = locked on it. Editing on the timeline's CLIM lane: 📍 keys
  the current view at the playhead (a key at the same moment is replaced),
  drag a diamond to retime (a press that moves under 4 px is a CLICK and
  opens the camera-path editor on that key), double-click to jump the
  playhead to it, right-click for jump / preview from here / set to the
  current view / edit camera path / delete, or on empty lane: key here / key
  at playhead / preview / edit camera path / clear all.
- **Camera-path editor** (`scenes/ui/climelapse_path_editor.gd`,
  `UILayer/ClimelapsePathEditor`, made by `TerrainLoader.open_climelapse_
  path_editor(key, opts)`; also "Edit camera path…" in the export dialog,
  which hides while it is open). A right-edge dock in the TOOL-OVERLAY tier
  (prop-editor contract: free cursor, RMB looks, Esc steps out a drag, then
  Look through, then the editor). `ClimelapsePathView` draws the keys in the
  world, no depth test: the flown path (`ClimelapseKeyframes.sample_path`,
  the export's own sampling), view ticks along it, each key's marker, number
  + time and frustum wireframe at the export's aspect (`frustum_corners`,
  VERTICAL fov), the selected key amber, the playhead's camera white. A
  `LightGizmo` sits on the selected key in a YAW-ONLY frame with
  `hidden = ["rz"]` (the gizmo's new hidden-handles list): the green ring
  pans (yaw about world up), the red ring tilts (pitch about the key's side
  axis, clamped ±89°), arrows / squares move it. A ring seen edge-on (the
  tilt ring when the key faces along your view) cannot be grabbed — use the
  Tilt field or Look through. Fields: Pan = compass heading
  (`heading_deg` = −yaw, 0 north), Tilt, FOV, East / Up / South. Look
  through = a (non-exclusive) camera claim on an editor camera at the key;
  drag pans and tilts (from mouse POSITIONS — pushed / warped motions carry
  a wrong `relative`), the wheel zooms. Click a marker to select a key.
  Edits save on release (`set_climelapse_key_pose(..., save)`); Revert =
  `restore_climelapse_keys` with the keys as the editor opened; Preview
  plays from the selected key and the editor comes back after. Undo / redo
  (Ctrl+Z / Ctrl+Y in `_input`, ahead of the terrain's own undo; buttons
  too) over whole-key snapshots, held-spin / wheel edits coalesced;
  "Add at the playhead" (your view), "Move here" (the selected key to the
  playhead), PageUp / PageDown, and where the key lands in the video.
- **Sky options** (dialog "Sky" + "Aim"; `ClimelapseSkyDirector`, shared by
  the export and the preview so they match; everything restored by `end()`):
  - Analemma (sun / moon): the game's ∞, stepped by the export
    (`analemma_export_begin / _step / _end`, `analemma_external_step` stops
    `_process` stepping it). Its speed is `analemma_days_per_second` (any
    value; presets a day … a year per second, "60 days/s" = the game's ∞ at
    60 fps; the speed row switches unit). Frame i shows day
    `analemma_day_of_frame` = floor(i × dps / fps): below the frame rate a
    day is held, above it days are skipped in the VIDEO but the director
    still steps through each one (≤ 7 per call), so the figure on the sky
    gets every day, as in the game. A range under `ANALEMMA_MIN_DAYS` (30)
    becomes a year from its start day (`analemma_range`, 365 frames at one a
    day) — in the dialog, the path editor's preview and the lane menu's
    preview; the dialog also has a "One year" range button.
  - Clouds off = `main.clear_sky_override` (cloud layers, cloud shadows and
    the weather light factor, for the video only; data untouched).
  - Star trails "grow through the night": closed above −6° sun altitude,
    then the exposure arc grows at 15.04°/h (`trail_state`).
  - Aim: follow the sun / moon (look at it, horizon level, `look_basis`) or
    the stars (the camera turned with the sky since the first frame,
    `follow_stars_basis`: the stars hold still and the horizon rolls).
- **Keyframe timing** (`camera_timing` auto / pinned / spread,
  `ClimelapseExportOptions.key_timing`, `rig.key_timing`): PINNED = each key
  at its hour on the timeline; SPREAD = the path from the first key to the
  last fills the whole video (`ClimelapseKeyframes.sample_progress(t_norm)`,
  t_norm = VIDEO progress in both the capture and the preview), keys keeping
  their spacing. Auto pins when ≥ 2 keys are inside the range or their span
  covers half of it, and always spreads under an analemma. ⚠ Before this, a
  path keyed a few hours apart played in the first frames of a year-long
  analemma (or never, for a range elsewhere) and the camera then sat on the
  last key — "the preview has no camera movement". The dialog's camera note
  says which timing applies and why.
- **Preview** (`ClimelapsePreview`, the dialog's Preview button or the lane
  menu): plays the shot in the game window in real time at the export's
  speed, with an exclusive clock claim and an exclusive camera claim
  (`climelapse_preview`), a top bar (Pause / Restart / Stop, a scrub bar,
  Space / ← → / Home, a camera-path line), HUD hidden; an analemma scrubbed
  back restarts and steps forward; from a key on a spread path it starts at
  that key's place in the video. Esc or Stop puts the clock back where it
  was and the player camera back.
- Old `start_climelapse_export(start, end, time_scale, path, fps)` still works
  (it fills the remembered options). Selftest + probe in the Validation list.

## Sim pre-render + playback (2026-10-17, the timeline's 📈 Render button)

Plan: `~/.claude/plans/i-ve-noticed-that-as-quiet-dove.md`. The sim is a
deterministic function of sim-hours, so a stretch of it is RENDERED ahead into
the live caches and the ambient tick REPLAYS it (reads) instead of simulating,
which is what lets the player explore in first person with a growing graph.
`core/sim/`: `SimRenderCache` (ranges + keyframes), `SimBakeStepper` (the ONE
deterministic step, shared with `ChallengeBakeEngine`), `SimRenderer` (a child
of SystemGraphView, `sim_renderer()`); `scenes/ui/hud/render_progress_card.gd`.
- **The user's complaint was measured first** (`tools/bench/flow_step_bench.gd`):
  on Mount Vernon (14 items) the flow step was 0.3 ms a frame; the pond twin
  push was **36 ms a frame, 215 ms peaks** — `get_pond_info` re-swept the
  basin three times and ran a 19-sweep level bisection per pond every 0.25 s.
  `TerrainLoader._basin_samples_for` memoises the basin's ground samples on
  `_basin_ground_fingerprint` (cleared on sculpt commit / undo) and
  `PondBathymetry.*_from_samples` integrate over them in the SAME cell order,
  bit-identical (pinned exactly in terrain_selftest). 16 → 35 fps at 60×, the
  same as paused. The F3 HUD gained `gv_pond_push`, `gv_dc_throttle`,
  `gv_faults`, `gv_placeholder`: read them before blaming `flow_engine`.
- **Render into the LIVE timelines.** `energy_timeline` (battery) and every
  tank's `ResourceTimeline` already had backward read + forward-in-cache read;
  the render fills them ahead of the playhead through
  `SolarUI.make_sim_render_evaluator(model)` (solar = SPA + weather + shade +
  DC caps at the instant; load = the SAME `GraphAcLoad.compute_kw` the live
  tick integrates, zero while the inverter is shed; aux = scene aux + the flow
  engine's graph DC from the PREVIOUS step — hydro into the battery, one-step
  lag like the live 0.25 s sync). Range = `[playhead, end]` (tanks can only be
  rendered from the current state), end = the Ctrl-drag selection's end or
  +24 h, capped at `MAX_RENDER_H` 7 d (the live timelines are a fixed 1-min
  grid of 20160 samples INCLUDING history). `_sim_series` stays for the
  observed-vs-sim Compare render (Shift-click 📈).
- **Keyframes carry only what no timeline records and nothing re-derives**
  (`SimRenderCache.keyframe_key`): node states, starved kinds, habitat ideal
  imports, batch progress, camp power, pop_state, the deficit tanks (no
  timeline), the wire flows, and the engine's between-step state
  (`internal_state_snapshot`: batch progress, demand overrides, per-scope AC,
  supply curves) so a live step resuming at any instant of the range starts
  from THAT instant's state. Hydro `live_*` is recomputed on replay by
  `_refresh_hydro_telemetry_readonly`; `dc_*` is the DC throttle's live display.
  Sparse deltas every 15 sim-min; the range's first keyframe is FULL; a
  non-incremental compose ERASES keys later keyframes introduced (a node
  state the engine set at step 40 must be gone at step 10).
- **Replay = read, never simulate** (`_tick_resource_flow_ambient`): inside a
  rendered range `cache.apply_at` then `flow.replay_at(now)` (apply first — it
  restores the engine's clock-at-keyframe; replay_at leaves `_last_abs_hours`
  at now, so a later live step continues from here); camp power stands down
  (keyframes carry `camp_*`; `_camp_power` is cleared so it re-seeds from
  specs on exit); the DC throttle runs display-only; SolarUI reads the
  rendered SOC and takes the readouts from the cache (the divergence
  truncation is gated OFF inside a range — the live scene-sun path differs
  from the pure evaluator by more than 0.05 kW on the first tick). NPCs keep
  simulating live off the cached supply (user's call). **Not in LIVE mode**
  (`SimMode.is_live()`): HA measurements are authoritative there, and this
  also sidesteps a 1× playback resolving LIVE and pushing to HA.
- **Invalidation is `GraphModel.user_rev`.** `struct_rev` moves on topology,
  `user_rev` on any write made while `model.sim_writing` is false. The view's
  `_begin_sim_writes()` / `_end_sim_writes()` is THE bracket for every sim
  writer (it replaced eight hand-rolled `was_suppress / was_bulk` blocks) and
  sets the flag; the HA linker and the fault check set it themselves; wire
  telemetry goes through `stamp_connection_telemetry` (reason
  `"conn_telemetry"`: a coalesced redraw, no fault check, no conduit remesh,
  no counter). A `user_rev` move → `SimRenderer.invalidate_from(playhead)`
  cuts every range there (drops one starting after the playhead) and
  truncates the energy + tank timelines. Non-graph inputs the render
  integrated are compared each tick (`_weather_sig`: datasets loaded +
  forecast window; connector-losses setting; PopTestPrefs generation) and a
  sculpt commit calls `invalidate_sim_render_all`. ⚠ **ANY unbracketed sim
  write kills the cache** — by design. `GraphModel.trace_user_rev = true`
  prints each move with the item and the changed keys; the probe turns it on.
  Found that way: `_sync_graph_energy_from_solar` reached from the post-tick
  flush (panel `current_output_kw` / `pv_offered_kw`). The bench prints a
  `user_rev` PASS line for the graph-closed regime.
- **The render owns the world like the bake**: exclusive clock claim
  `"sim_render"` at time_scale 0 (time stands still, the player can walk), the
  ambient tick suspended, `_pond_twin_push_blocked` (render steps would walk
  the 3D water to the range's end), `NpcPopulationBridge.freeze_tiers` (a
  FULL snapshot cannot `restore_all` onto a camp CrowdFocus re-tiered
  meanwhile), snapshots of specs / rosters / battery / flow internals /
  `camp_power_state_snapshot`. Finish or cancel keeps the rendered part
  (Premiere keeps a partial preview) and restores the playhead: specs →
  `cache.apply_at` → `flow.replay_at` → rosters → `reseat_battery_at` → one
  pond push → claims released. Steps on a 24 ms per-frame budget (Mount
  Vernon: 24 h ≈ 1441 steps ≈ 5 s; solar ~0.4 s, resources ~2 s of that).
  `SaveSystem` skips an autosave tick while a render is active (the specs are
  at the cursor). Refused in LIVE mode, while another system owns the clock,
  in the bootcamp sandbox, or for an end at or before the playhead.
- **Timeline UI**: 📈 enabled whenever nothing owns the clock (it used to be
  disabled without a CSV clip, and the disabled look was invisible —
  `_mk_icon_btn` now has a `disabled` stylebox + `_dim_disabled`); a
  3 px **render strip** at the top of the clips lane (`RENDER_STRIP_H`; the
  default clips track is 14 px): green = rendered, dim green = rendering,
  red = a selection ahead of the playhead not yet rendered; the
  `RenderProgressCard` (HudLayout top_center: range, bar, %, ETA, Cancel);
  toasts on refusal and completion; `TimeDirector.Provenance.RENDERED`
  (`register_rendered_ranges`, the data chip reads RENDERED in green). Tour
  stop `20b_render_sim`.
- **Live-sim streamlining, accuracy-neutral (the bench hash is the pin):**
  `GraphNesting.flat_connections_cached` (keyed struct_rev + user_rev +
  count; read-only — fault-flag writers keep the fresh copy) for the flow
  index, the AC load reading (10 Hz) and the DC sum (4 Hz); the engine's conn
  index rebuilt only when that key moves; lazy `duplicate(true)` in the
  siphon / JIT passes; a per-step pond-tag → tank map for culverts; the
  siphon outlet stamp through the index; `_write_if_changed` (exact compare)
  for the PBI / catchment writes; the deferred fault check coalesced to one
  per frame and never queued by `conn_telemetry`; `GraphPlaceholderHost`
  one deferred sync per frame and none for sim writes; `_find_terrain_loader`
  cached; `_dc_analysis` keyed on struct_rev.

## Flat-pack furniture designer (core/flatpack/, 2026-10-23)

Slotted plywood furniture, Burning Man "PlayaTech" style, cut on a CNC
router: Library → Structures → "Flat-pack furniture designer…" (no hotkey).
Plan: `~/.claude/plans/c-users-notsa-documents-playa-tech-glb-dapper-wilkinson.md`.
Built from the user's `Playa Tech.glb` (a SimLab export, inches): an 8 ft
sofa of 12 half-inch parts that sets up upright, reclined or flat as a
daybed and nests onto exactly three 4×8 sheets. `tools/flatpack_glb_reference.py`
measured it into `core/flatpack/testdata/playatech_daybed_ref.json` (the GLB
is not committed; it carries a scale figure).
- **Units are INCHES** until the mesh builder (×0.0254) or a mm export.
- **Outlines keep true arcs** (`FlatpackProfile`): a ring is points + DXF
  bulges. A part is a straight-edged BASE polygon + per-vertex fillet radii +
  EDGE NOTCHES; `ring_from_base` lays the notches in and shrinks a fillet
  that would run into a slot. Inside corners get dogbones, T-bones (overcut
  sideways only, slot bottoms stay flat) or none. Holes are CW rings.
- **Every slot is derived from the 3D assembly** (`FlatpackJoints`): a
  template emits slabs (base + `frame` Transform3D whose z is the normal)
  and joints; the solver intersects the mid-planes, clips the line to both
  outlines and cuts: `cross_lap` (A notched from the end toward `open`, B
  from the other, A takes `ratio`; width = other sheet / sin(angle) + 2 ×
  clearance) or `tenon` (A's outline carries tabs; B gets a mortise, or an
  edge slot where the tab reaches B's edge; `wedge` adds a wedge hole in A
  drawn in 1/16" and a wedge part). Slots from every POSE are laid in
  together, and parts in one `match` group are cut identically (union), so
  one set of parts assembles every way — exactly the sample. Only the 2-D
  base is used for chords; parallel or <45° pairs are refused with a reason.
- `FlatpackJoints.interference` walks the line where each pair's mid-planes
  meet: a point solid in BOTH finished outlines is a clash (a grid sample
  misses a 15/32" band). Every built-in design is clash-free in every pose.
- **Templates** (`FlatpackTemplates`, furniture frame X length, Y up, +Z
  front): sofa (the sample; rails, cross rails, arms, deck slotted into the
  arms, back + braces per pose; the upright brace stands ~7" forward of the
  reclined one so their rail slots do not overlap, never far enough to reach
  the deck); the table family (bench / stool / table / coffee table: tabbed
  leg panels or crossed X legs, a stretcher wedged outside the end legs, a
  bench back from leg posts); chair / lounger (side profiles from six control
  points the player can drag — `profile_offsets` — seat and back on tabs,
  wedged stretchers). `FlatpackPresets`: the sample as drawn (0.5" exact, no
  clearance/relief/spacing — what the selftest pins), router-ready versions
  (15/32" actual, 0.010" clearance, dogbones, 3/8" spacing, 0 margin so a 96"
  part comes out of a 96" sheet) and the library `user://flatpack_library.json`.
  Router-ready sofa defaults (11 1/2" rails, 35 1/2" deck, 23 3/4" arms and
  braces) still nest on three sheets.
- `FlatpackDesign.solve(spec)` (cached by the resolved spec) is the ONE
  solved design the modal, builder, packing and CNC writers read: parts with
  rings, cut list (identical parts grouped, labelled A, B1…), MaxRects nest
  (`FlatpackNesting`, Jylänkä 2010, BSSF, grain lock), BOM (sheets, use, cut
  feet, passes, router minutes, mass from 1.5 lb/ft² per 1/2" — APA).
- **CNC** (`FlatpackCam`): R12 DXF per sheet (POLYLINE + bulges; layers
  OUTSIDE_CUT / INSIDE_CUT / ETCH_LABELS / SHEET; $INSUNITS), SVG per sheet
  sized in real in/mm (no fills, no background rect — an importer would cut
  it), a fit-test coupon (slots at thickness −0.010…+0.020"), a cut-list txt;
  `write_all` → `user://flatpack_designs/<name>/` or a native folder pick.
- **Modal** (`scenes/ui/flatpack_designer_modal.gd`, on the loader's
  CanvasLayer 27 like the rack builder; `UiFit.keep_fitted`, modal claim):
  types + designs left; Assembled (orbit, pose, explode, build scrub, click
  picks a part) / Sheets / Side profile centre; Size, Material, Joinery
  (per-joint kind / wedge / share overrides), Machine, Style, checks, parts,
  cut list, export right. ⚠ Godot takes a SpinBox's decimals from its step
  (a 1/4" step prints 23.75 as "23.8"): length spins step 0.001 with the
  arrow step at the real increment.
- **World**: ModelCatalog procedural `flatpack_furniture` (record key
  `flatpack_spec`; one "Mesh" MeshInstance3D so prop collision works),
  `begin_flatpack_placement`, prop editor "Edit furniture…", PackedSpec
  DYNAMIC (`FlatpackDesign.packed_spec`: a panel_stack of the parts).
  `PlacedPropService.tag_flatpack_space` tags it `sleep` (daybed pose: one
  per lying spot) or `quiet` (one per seat), tables untagged.
- **People sit ON it**: the builder's `seat_spots` meta (local metres, yaw
  turning −Z to the faced direction) → the bridge's `_resolve_seat_spots`
  (once a second, spaces whose prop is flat-pack furniture) → ctx
  `seat_spot_of(sid, k)` (forwarded by the engine's `_make_ctx` WHITELIST)
  → full tier `NpcAgent._take_seat` (target, face anchor, `seat_elev` read by
  `elev()` while DOING, lie yaw) and light tier `CrowdCohort._take_seat`
  (`_seat` read by `elev_of`). No furniture = no change (the tier
  equivalence pins are untouched). Light-tier sleepers still use their camp
  beds, so a daybed sleeper is full tier only.
- Not built: true-shape nesting (bounding rectangles today), router G-code
  (the user chose DXF + SVG), PDF templates, an NPC crew that cuts and
  assembles it.

## Dome & zome designer (core/domelab/, 2026-10-25)

Library → Structures → "Dome & zome designer…" (no hotkey); click a placed
dome or the prop editor's "Edit dome…" reopens it bound to the prop. Pure
modules under `core/domelab/`, the modal `scenes/ui/domelab_modal.gd`
(flat-pack designer pattern: own CanvasLayer 27, `UiFit.keep_fitted`, modal
claim, SubViewport studio). Record key `domelab_spec`, model id
`domelab_structure` (`DomeLabBuilder.MODEL_ID`), the existing crafted 2V
`geodesic_dome` / `DomeParts` is untouched.
- **`DomeLabGeodesic`** is the Goldberg–Coxeter construction: a (b, c)
  triangular lattice per face of the icosahedron / octahedron /
  tetrahedron, Class I (f, 0), Class II (f/2, f/2), Class III (b, c),
  projected to the sphere. Straddling corners are carried across the edge
  with `(λ1 + λ3, λ2 + λ3, −λ3)` on the neighbour (the reflected far corner)
  until inside; vertices merge by position, faces by vertex set. Chord
  factors match Domebook / desertdomes to 2e-5 (2V, 3V, 4V pinned).
  ⚠ **The lattice maths is 64-bit scalars, never Vector2**: a Class II tie
  (unit triangle whose centroid lies ON the face edge) computed in float32
  read −1e-7 near two corners and 15 faces of 240 vanished with V − E + F
  = −8. ⚠ Every icosahedral mirror plane holds two icosa edges, which a
  Class II lattice straddles, so a Class II "hemisphere" is never a clean
  great circle: the 8 straddlers are trimmed (4V edge-up keeps 116 of 240)
  and the base-level check says so. Truncation picks the ring nearest the
  fraction's height (rings merged within 3 % R: a 3V "5/8" base is two
  heights ~0.01 R apart = one ring; `flat_base` levels it, adding strut
  lengths; the real 3V "5/8" is ~0.59 of the sphere). `stretch` makes an
  ellipsoid. Normals for the connector maths are the FULL surface's
  face-average normals, taken before the cut (base hubs keep the true
  surface normal).
- **`DomeLabZome`**: the polar zonohedron of order n — generators on one
  cone, vertices V(i, k) = Σ of k consecutive generators, rhombi
  R(i, k) = [V(i,k), V(i,k+1), V(i−1,k+2), V(i−1,k+1)], ONE strut length,
  n(n−1) rhombi. Layers 0 … K; "cut" floor = the bottom row trimmed to
  triangles on the level ring V(·, K); "zigzag" keeps whole rhombi. Every
  edge is tagged with its RIB (R_i: fixed i; L_m: fixed i + k). The helix
  zome (simplydifferently.org/Helix_Zome) is exactly the polar zonohedron's
  infinite-frequency limit: `rib_point` is the smooth curve through a rib's
  nodes (r = L sinθ sin(kπ/n)/sin(π/n), ψ linear in k, y linear in k); the
  ribs option builds continuous curved ribs lapped where R crosses L.
- **`DomeLabConnectors`** reads every angle off the geometry: dip =
  asin(−d · N) (half the central angle on a sphere = the conduit end bend),
  azimuths in the tangent plane → hub arm patterns (canonical rotation of
  the gap/dip sequence, `angle_tol_deg`), dihedral → flange fold = half the
  angle between face normals, flat-bar arc = chord · δ / sin δ, bend radius
  = chord / 2 sin δ, strain = t / 2R. Strut classes by (cut, sorted end
  bends) within `group_tol_mm`, A = shortest. Systems: `bolt_stack` (cut =
  chord + 2 × hole offset, bend = dip, one bolt per hub sized from the
  stack), `hub` (socket: cut = chord − 2 × reach; plate: flattened ends on
  a star plate, drill template per hub type; ring), `flat_bar` (arc lengths,
  bars lie flat on the bolt), `nexorade`, `plate`.
- **`DomeLabNexorade`**: every edge a slat turned about its midpoint in the
  tangent plane by ρ; consecutive slats round a vertex cross at the skew
  lines' closest points → four holes a slat (two ends, two inboard), length
  = span + overhang. `mode` "band" (flexible bands on the surface, holes
  spaced along the ARC; auto fits the engagement LENGTH to `engage_frac` of
  the edge) or "rigid" (straight slats; auto fits the mean eccentricity to
  the slat thickness — tiny angles for thin slats, that is physics).
  Base-ring slats have no neighbour below and are shorter.
- **`DomeLabPanels`**: a panel per face inset by the seam gap, screw holes
  along the edges (strut systems) or FLANGES (plate system: mitred along the
  exterior bisector, ext = w · tan(ext/2) capped at 1.5 w, relief, fold
  lines carry the bend); each part turned to its smallest bounding box and
  nested with `FlatpackNesting` onto the sheet (material's, or the
  Fabrication override). Classes = congruent panels. Rings are
  FlatpackProfile rings in MILLIMETRES.
- **`DomeLabDesign.solve`** (cached by `DomeLabSpec.key_of`) is the one
  solved design: geo, frames, edges, fans, struts, classes, hubs, nexorade,
  ribs, panels, bolts, stats (height, floor area, surface, volume, chord
  factors), the build order (rings from the base up), `DomeLabBom.compute`
  (rows, first-fit-decreasing stock packing with kerf, fasteners, masses)
  and the checks (Euler, stock length, slenderness L/r, flattenable
  section, bar strain, rhombus mechanism, base level, nexorade fit, panel
  fit, folding sheet). `packed_spec` = strut bundle (longest cut × √(n ·
  section) square) merged with the panel stack. `DomeLabCam.write_all`:
  DXF (R12, layers OUTSIDE_CUT / INSIDE_CUT / FOLD / ETCH / ETCH_LABELS /
  SHEET) + SVG per sheet and per plate-hub template, a strut-end SVG per
  conduit class, `_struts.csv`, `_bom.csv`, `_cut_sheet.txt`,
  `_design.json` (`DomeLabBom.fabrication_json`: vertices, faces, struts,
  hubs with arm azimuths / dips, nexors, panel outlines, BOM, checks).
- **`DomeLabBuilder`**: one MeshInstance3D "Mesh" with a surface per
  material, tubes round (8 sides, 16 past 6 cm, RADIAL normals), bars flat
  on the surface, lumber / beams / ribs on edge, hubs as bolt + nut /
  sphere / disc, slats offset by half a thickness, ribs as helix segments;
  `explode` moves parts out along the normal, `assembly` drops rings in
  from the base up; `record` keeps segment / sphere / triangle pick data
  read by `pick`. The placed dome counts as SHADE (`shade_footprints`).
  ⚠ **Never `generate_normals()` on these SurfaceTools** (2026-10-25): its
  default smooth group merges every vertex by position, so the flat panels
  and the prisms' edges rendered as one rounded "bubble" — every emitter
  writes the normal it means (`_tri` / `_tri_n`). Finishes follow the
  STOCK: `DomeLabMaterials.STRUT_LOOK` / `SHEET_LOOK` (galv / alu / paint /
  plastic / wood / ply / glazing / fabric) → `StructureMaterials` kinds
  (GALVANISED, ALUMINIUM, PLASTIC, GLAZING, FABRIC were appended for it);
  the PV-glass PANEL kind is not used here. A part is drawn in the player's
  colour, or the stock's own while the colour is still the default
  (`_part_color`; the modal's Colours rows show the drawn colour and reset
  to the stock). The studio lights with a sky ambient + SSAO so the facets
  shade apart; the Sheets tab scrolls at a readable size.
- **Helical zomes (`DomeLabHelical`, family "helical", 2026-10-26).** The
  zome's n generators indexed over all integers; a CELL is the zonohedron
  of w consecutive ones, and cell a−1 sits at b(a) + g_{a+w−1} — one step
  round and down. w = n is the polar zonohedron swept along a helix (n steps
  a turn); w = 3 stacks rhombohedra, n = w = 4 at 54.7356° rhombic
  dodecahedra (your photo's "stacked cubes"). The surface is EXACT: bricks
  {i<j<k, k−i<w} at Σ_{i<l<j} g + Σ_{l>k} g tile every cell with the SAME
  bricks wherever cells overlap, so the boundary = brick faces met once.
  ⚠ Keys are integer generator-count vectors; 0.1 mm float keys split one
  face pair in ~2700 and left a hole. Spec `helical` {sides, pitch_deg,
  window, steps, hand, levels (rows kept from the apex, floor cut level
  there, straddling rhombi keep their top triangle), stretch}; radius_m =
  one CELL's widest ring. Faces carry `face_zone` (generator distance,
  1 … n/2 = one rhombus shape each; the plain zome got it too).
  `Helical Zome Corten Steel.glb` (user's Documents) is reproduced node for
  node by n = w = 10, θ 57.1°, 1.585 m, 20 steps (452 / 900 / 450); preset
  `helical_corten` cuts it at the person's floor (14 rows), 3 mm corten,
  PMMA in zones 1–2. `tools/diag/rack_model_study.gd --dome-preset=<id>`
  shoots a preset the same eight ways as the GLB.
- **Folded plates are solid (2026-10-26).** `DomeLabPanels.flange_section`
  is the ONE section (mm, x into the face, y along its normal): flat plate
  to xc, a bend of inside radius `fold_radius_mm` (0 = t) swept 90° + ang/2,
  a flange parallel to the dihedral's bisector plane with its outer skin
  gap/2 off it, so neighbours meet back to back and the bolted pair is the
  strut (SPACEPLATES). The builder extrudes it per edge, each profile point
  clipped on the plane bisecting the two flanges at a corner (closes like a
  folded box). Bolt holes are laid out per EDGE (`bolts3d`, margin from the
  corner angle), so both plates of a seam are drilled alike; floor-edge
  holes are anchors. Openings: `oculus` + `oculus_mm` + `oculus_round` +
  `oculus_zones`, a `glazing` pane lapped 25 mm behind (DomeLabPanels.
  rounded_inset); `thickness_mm` overrides the sheet. Faces go into packed
  arrays, not SurfaceTool (the 216-plate home: 608k vertices, ~130 ms).
  Sheets corten_2/3 (look "corten" → `StructureMaterials.Kind.
  WEATHERING_STEEL`, appended) and pmma_4/6.
- **Folded-plate seams that bolt up (2026-10-26).** The flanges "almost
  joined" because:
  - **Valleys folded the wrong way.** `flange_bend` was `acos(n1·n2)/2`,
    which is unsigned, and the section clamped it to ≥ 0. A helical zome's
    cells meet in VALLEYS (12 seams on `helical_corten`; 85 of 372 on the
    user's saved window-8 home). There the flanges stood 160–168° apart.
    - `DomeLabConnectors.edge_records` now signs it: negative when the second
      face's centroid is above the first face's plane (`_valley`). `dihedral`
      is then over 180°.
    - `flange_section` takes a half-angle in ±`MAX_HALF_BEND`. A valley's
      fold is less than 90°.
    - BOM / cut sheet folds print the signed half-angle.
  - **Corners of 4+ plates.** At 3-plate nodes the three bisector planes
    share one line, so the plate mitres close exactly (measured 1e-4°). At
    nodes of four or more plates they don't: the two plates on a seam ended
    their flanges along mitre lines 20–118° apart (the wedges).
    `DomeLabPanels._node_cuts` gives such a seam end ONE plane that both
    flanges of the pair end on (`pn.node_cuts`, world mm, keyed
    `_cut_key(face, node, a, b)`). That plane runs halfway between the two
    mitre lines, at least `NODE_END_MIN_DEG` 40° off the seam, square to the
    seam, and set back `NODE_CLEAR_MM` past both mitres. The node itself is
    left open, as a real folded-plate node is.
  - **Mitre cap.** A mitre never runs past its corner by more than
    `MITRE_CAP` 1.5 × the point's depth (the flat pattern's own cap). Without
    it, a steep valley flange and its plate's next flange met 200–330 mm
    off.
  - **The flat pattern is developed from the section** (`developed`,
    `BEND_K` 0.44):
    - the face region is the outline inset by xc;
    - each flange is the bend allowance plus the run;
    - the DXF fold lines are the bend centre lines;
    - each hole sits where the folded flange carries it.

    Before, holes were at flange/2 from a gap/2 inset, which missed the 3D
    bolts. Bolt end margins clear any node cut.
  - Gate: `domelab_selftest._test_plate_seams` (196 checks). For every plate
    preset plus a window-8 valley variant it checks, as the builder draws
    them:
    - flange skins within 0.5° of parallel and gap ± 0.5 mm apart;
    - every flat-pattern hole, folded up, within 0.5 mm of its partner and
      of a bolt;
    - node-cut pairs on one plane.

    It fails at 160° and 88 mm on the old code.
  - Diags: `tools/diag/domelab_seam_probe.gd -- --preset=<id>|lib:<id>`
    (headless numbers: seams, corner wedge by valence, spikes) and
    `tools/diag/domelab_seam_look_diag.gd` (WINDOWED, APPDATA at a scratch
    folder; close-ups of a valley, a ridge, a 4+ node and a 3 node;
    `--library=<id>` for a saved design).
- 16 presets (`DomeLabPresets.builtins`); library `user://domelab_library.json`.
  Panels that do not fit the sheet are an ERROR in the checks (a real
  blocker): the presets are sized so every one solves clean. Gates in the
  Validation list; tour stop `18d_domelab`.

## CNC gantry designer (core/gantrylab/, 2026-10-25)

Library → Structures → "CNC gantry designer…" (no hotkey); click a placed
machine or the prop editor's "Edit gantry…" reopens it bound to the prop.
The dome-lab pattern: pure modules under `core/gantrylab/`, the modal
`scenes/ui/gantrylab_modal.gd` (own CanvasLayer 27, `UiFit.keep_fitted`,
modal claim, SubViewport studio). Record key `gantry_spec`, model id
`gantry_machine` (`GantryLabBuilder.MODEL_ID`, catalog category "tools"),
library `user://gantrylab_library.json`, exports `user://gantrylab_designs/`.
- **The pattern language** is `GantryLabSpec.KINEMATICS` (bedslinger,
  cartesian_xy, corexy, corexz, hbot, delta, router) with `KINEMATICS_WHY`
  (when to use each) and `APPLICATIONS` (a job → pattern + tool + sizes,
  `for_application`). `resolve` couples the shared-belt axes (CoreXY / H-bot
  copy X's drive onto Y; CoreXZ onto Z), forces a delta's bed round, and
  keeps `volts` an int (the JSON round trip made it a float and moved the
  cache key). `motor_axes(kin)` names the motors (A / B, the three towers).
- **Parts are data with sources** (`GantryLabParts`): V-slot 2020 / 2040 /
  2060 / 4040 / C-Beam 4080 / 3030 with kg/m and Ix / Iy (OpenBuilds /
  Misumi), guides (V-wheel, MGN9 / 12, 8 mm rod, HGR15), drives (GT2 6 / 9,
  GT3 15, Tr8×8, Tr8×2, Tr12×3, SFU1605 / 1610, mod-1 rack; belt spring rate
  per metre, screw root diameter, efficiency), motors (NEMA 17 pancake …
  NEMA 34, holding torque / amps / mass), boards with their usable step
  rate (RAMPS 10 k … Klipper RP2040 500 k) and firmware list, tools
  (hotends, pellet and clay extruders, spindles, lasers, pen: mass, watts,
  line width, feedstock kind), beds, hardware prices.
- **`GantryLabKinematics`** (pure): steps/mm, CoreXY A = x + y / B = x − y
  (H-bot the same on one belt, CoreXZ with z), delta carriages
  `z + √(L² − d²)` + forward trilateration, `motor_velocity` (per-motor mm/s
  per mm/s of tool: a CoreXY diagonal runs one motor at √2 and the other
  not at all), force from torque (half the holding torque usable), belt
  stretch, `screw_critical_rpm = 4.76e6 · d_root · C / L²`, beam sag
  `F L³ / 48 E I`, the toolhead's ringing frequency.
- **`GantryLabGcode`** reads moves with feed / E / line (G0–G3 with I J and
  R arcs expanded to 1 mm chords, G20 / 21 / 28 / 90 / 91 / 92, M82 / 83,
  M104 / 109 / 140 / 190, M3 / M5 with S ≤ 1000 read as laser power so a
  laser program "extrudes"), and `to_toolpath` emits the game's Toolpath
  shape (points + extruding, decimated) so the job store takes it.
  `GantryLabMotion.plan` is the classic-jerk trapezoid planner (per-move
  caps from feed, max feed, per-axis and per-motor step-rate caps,
  `v_junction = jerk / |d₂ − d₁|`, backward then forward pass);
  `sample(t)` is the scrub. `GantryLabSamples` generates seven real
  programs sized to the machine (cube, vase, speed test, pocket, laser
  raster, plotter, surfacing).
- **`GantryLabFrame.layout`** is the geometry: the static frame (beams with
  profile + `up`, parts, screws) and the moving ASSEMBLIES ({parent, base,
  beams, parts, mass, axis}); `pose(spec, layout, tool_mm)` is the
  kinematics as offsets (a bed-slinger's bed at `vy/2 − y`, a cube's bed at
  `−z`, delta carriages at their heights), `belt_routes` / `delta_arms`
  the drawn loops. Machine frame: X → local +X, Y → local +Z, Z up; the
  work origin is the bed's front-left at its surface (`origin`); beads go
  under `bead_parent` ("Bed" where the bed moves, else the root) at
  `bead_origin`. A delta's carriage base is the TOWER CENTRELINE with the
  pivot `carriage_r` inward (the delta-radius convention) — the first cut
  put the base on the tower face and the drawn arms were 34 mm short.
- **`GantryLabDesign.solve`** (cached by `key_of`) → layout, bom, motors
  (steps/mm, resolution, speed caps, accel capable), limits for the
  planner, stats, checks, `graph_preset`. Checks: step rate at the max feed
  (× √2 on a shared belt) vs the board, acceleration vs torque and moving
  mass, Z lift force, Tr8×8 back-driving a heavy bed, belt stretch, X-beam
  sag (tolerance `sag_tol_mm` = max(process floor, a tenth of the line —
  an 8 mm clay bead forgives 0.8 mm), router rail sag and upright flex,
  screw whip (Z runs 10 mm/s on a Tr8×2, 30 on other screws, never the XY
  feed), resolution vs the line, delta reach and arm ratio, H-bot racking,
  driver count, 12 V above 120 mm/s, bed-slinger inertia past 300 mm, 2020
  past 350 mm. `GantryLabBom`: cut list rounded to 5 mm packed first-fit
  into 1.5 m stock, corner hardware per beam end, rails + carriages per
  axis, belts (two motors for A/B), pulleys / idlers / screws / nuts /
  couplers, motors + drivers, a PSU sized to the DC load, endstops, wiring,
  cable chain, tool, bed, enclosure. `GantryLabExport`: Klipper
  `printer.cfg` (kinematics, rotation_distance, delta arm / radius, input
  shaper at the ringing estimate), Marlin `Configuration.h` defines, grbl
  `$` settings, BOM CSV, cut list, design JSON (INF → null).
- **`GantryLabBuilder`** (Node3D): the static frame as one "Mesh" (the
  V-slot profile outline with a 6 mm groove per 20 mm cell, extruded;
  parts as boxes, screws and motor shafts as cylinders; surface per
  material key), a Node3D per assembly parented as the layout says (its
  mesh carries `skip_prop_collision`), "Belts" rebuilt per pose, and three
  DRIVER nodes `XDrive` / `YDrive` / `ZDrive` whose local position along
  their axis is the tool in metres; `_process` follows the drivers
  (`follow_drivers`, off in the studio), `set_tool_mm` is the one pose
  call, `set_toolpath_preview` / `set_preview_progress` lay beads at true
  scale on the bed node, `pick` tests per-part AABBs through the assembly
  chain from LOCAL transforms (a studio node is picked before it is in a
  tree).
- **In the world** a placed gantry's record carries `gantry_spec` and kind
  `gantry_machine` — NOT `cartesian_machine`, whose `CncMachineRuntime`
  stretches a path over the GLB's axis window and draws the ghost at 40 %
  of the footprint. `GantryRuntime` (gameplay/) attaches by MODEL ID, reads
  the same `get_cnc_job_state` + `MachineJobStore` job and moves the
  drivers in true mm (eased, snapping on a clock jump), beads on the bed
  by progress. `PlacedPropService.seed_gantry_graph` (deferred on
  placement) makes a `cartesian_machine` processor from
  `GantryLabDesign.graph_preset` through `create_bound_generator_node`
  (machine_role fdm_printer for an extruder, cnc_router otherwise;
  inputs = the tool's feedstock — the new `filament` resource kind,
  `plastic_flake`, `mud`; watts and work volume from the design);
  `sync_gantry_graph` after Apply. The TOOLS preset "CNC Gantry
  (designed)" carries an empty `gantry_spec` (placing it from the graph
  builds the default bed-slinger). Modal Simulate → "Send to placed
  machine" = `start_machine_job` with `to_toolpath` + the planner's time,
  so the job's duration is the simulated one.
- Gates: `gantrylab_selftest` (227), `tools/checks/gantrylab_designer_check.gd`
  (41), tour stop `18e_gantrylab`.
- **High-detail parts (2026-10-26).** Modelled on
  the user's CR-10 S4 GLB: `GantryLabDetail` (`core/gantrylab/gantrylab_detail.gd`)
  draws every part the frame names — motors on brackets, GT2 pulleys and
  idlers, Tr8 screws with couplers and brass nuts, V-wheels on their axles,
  rails and blocks, endstops, a V6-class hotend, a Bowden extruder, spool,
  springs, feet, corner brackets, PSU, LCD, board — in a LOCAL frame whose
  +Y is the part's axis. Belts are LOOPS of pulleys (`lay["loops"]`, nodes
  {asm, c, r, s = wrap sign, kind}) solved by common tangents
  (`GantryLabFrame.solve_loop`); the builder makes one `Spin_<label>` node
  per turning part (angle = motor mm / per_rev_mm) and scrolls the belt
  teeth (`gantry_belt.gdshader` `offset_m`); screws / couplers / springs are
  plain cylinders under `gantry_thread.gdshader` (UV = angle, metres).
  Still open: the look pass by eye (belt wrap signs, the i3 bed belt), the
  print-setup hookup for placed gantries (GantryRuntime must speak
  CncMachineRuntime's preview / reveal API), the modal pass. ⚠ Loop node
  key `s` is the wrap sign — a clamp's extent travels as `size`. Not built: an NPC crew assembling it,
  SCAD part models for pulleys / brackets (the scad_library has them),
  the print-setup STL slicer on a gantry (the inspector's Load G-code / STL
  works through the graph node), multi-tool heads.
- **Parts that MATE (core/gantrylab/assembly/, 2026-10-26).** The V-slot
  machines (bed-slinger, Cartesian XY, CoreXY, H-bot; `GantryLabAssembly
  .KINEMATICS`) are no longer hand-placed offsets: each generator
  (`GantryLabGenSlinger`, `GantryLabGenCube`, helpers `GantryLabGen`) builds
  the machine the way a kit manual does, every part MATED to a feature of
  another. CoreXZ, delta and router still use `GantryLabFrame`'s old
  functions (`GantryLabFrame.layout` dispatches).
  - `GantryLabCatalog`: real parts with FEATURES in their local frame
    (`{id, kind face|grid|holes|axis|bore|end|run|point, cls, xf}`, +Y =
    the contact face's outward normal, +X = slide / reference): V-slot
    faces with their slot lines (20 mm cells, the side slot 10 mm in = where
    V-wheels run), beam ends, cast corner brackets, NEMA 17/23 L mounts
    (motor face 31 / 47.14 mm square; leg B carries a hole grid), a NEMA
    standoff plate, gantry plates (wheel `run`, hole grids `top` / `back`,
    `tool`), nut blocks, bed carriage plate (+ `springs`), belt clamps
    (`grip` = where the belt passes), GT2 pulleys / idlers (bore + `belt`
    band point), couplers, Tr8 screw / nut, motors (face + shaft).
  - `GantryLabMates`: `COMPAT` (child class → target class → mate type:
    slot, grid, endgrid, lines, butt, run, pattern, shaft, idler), `place`
    (`W_t · F_t · T(s·x + lat·z + h·y) · Ry(turn·90°) · Rx(180°) · F_c⁻¹`),
    `fits` (every bolt on a slot line / grid hole / pattern hole), `snap`,
    `slide_range`, `infer` (pose → mate numbers), `fasteners` (T-nuts,
    bolts cut to `STOCK_LEN`, a NEMA 17 bolt never longer than the 4.5 mm
    thread, nylocs, washers, spacers; a `run` mate generates the V-wheels
    with the 6 mm eccentric spacer that puts a plate 1.1 mm off the face).
  - `GantryLabAssembly`: `build(spec)` = generated doc + the player's
    sparse edits (`spec["assembly"] = {over: {id: {mate, ref, params,
    removed}}, added: [part], unlinked: [id]}`); `resolve` → world poses,
    fasteners, exempt pairs, loops; `to_layout` = the SAME layout shape the
    builder / pose / BOM / design / runtime read (every assembly's `base`
    is zero: parts are drawn where they are at tool 0, so a node's position
    IS the jog). Belt planes come from the loop's first node; `auto` nodes
    (idlers on spacer stacks, pulleys on shafts) and clamps follow it, so a
    belt is planar by construction. A mate's `s` is measured from its
    `anchor` (start / centre / end) so resizing keeps distances. Twins:
    `edit_part` re-solves the mirrored twin (`mirror_mate`: mirror the
    world pose across x = 0, pick the turn whose boxes overlay the mirror
    image); `unlink`, `add_twin`. Editor queries: `candidate` (best spot
    for a part under a ray), `slide` (drag along a mate), `subtree`.
  - `GantryLabClash.check(spec, lay)`: oriented boxes (shrunk 0.4 mm, mated
    pairs + grandparents + screw-through-nut exempt) at home and the 8
    travel corners, belt spans through parts, loops crossing themselves or
    another loop in their plane. It feeds `GantryLabDesign._checks`
    (`{level, text, parts}`) and the selftest gate: EVERY V-slot preset is
    clean, and `tools/diag/gantry_assembly_probe.gd -- --kin=sweep:<kin>`
    (180 variants each: sizes, tools, profiles, motors) is clean.
  - The CoreXY routing: motors behind the back corners on L mounts whose
    leg carries the OTHER belt's back idler; the turning idlers on the X
    beam's two top slots (A front line, B back line); clamps on a tall X
    carriage (plate `off` up) at each deck; the two decks a belt width + 5
    mm apart. ⚠ The V-slot generators ignore the axis `guide` (MGN rails
    are not in the catalog yet): every V-slot machine rides V-wheels.
  - `GantryLabBom` counts what the assembly draws (`_assembly_rows`):
    parts by label, fasteners by size and stock length, belts from the
    drawn loops; guides / corner formulas only for the old layouts.
  - Builder: picks carry the part `id` and hit `point`; `mark_part` /
    `mark_ghost` / `clear_marks` (see-through overlays riding their
    assembly); fasteners are `fastener_*` detail kinds in the merged mesh.
  - Modal (`scenes/ui/gantrylab_parts_editor.gd`, preloaded): Parts palette
    at the top of the left column, "Selected part" card at the top of the
    right. Click picks, drag slides along the mate (1 mm, Shift 5 mm, Alt
    free), dragging well off re-snaps elsewhere, R turns, Del removes,
    Ctrl+D duplicates, Esc; palette tool + ghost with its bolts + "Add
    mirrored"; card: swap within the family, length, teeth, distance +
    anchor, across (grids), stand-off, Unlink, fasteners. Collisions are
    drawn red ("Show collisions").
  - **Parts from the player's reference model** ("additional 3d printer
    parts.glb", 2026-10-26; measured with `tools/diag/glb_topview_diag.gd`,
    drawn by `tools/diag/gantry_parts_look_diag.gd`): T / 90° joining
    plates, cube / 3-way / inside hidden corner connectors, flat NEMA 17 /
    23 motor plates (`mount` along a slot, `wide` across a 2040, motor on
    either face), the 8 mm Acme anti-backlash nut block (screw PARALLEL to
    the plate), the mini V gantry plate (mini wheels Ø15.2 × 8.8: `wheel_r`
    / `wheel_w` params reach `GantryLabMates.wheels` through the mate
    extra), the 5 × 6 mm coupler (`bore2`). New mate classes: `tap5`
    (into a beam's tapped end, kind `end` is now a target) and `hid`
    (set-screwed inside a slot). A feature marked `leg` on a part with no
    `also` gets its secondary contact found by `_auto_legs` (a joining
    plate's second beam, a cube's other ends). Drawn by the
    `outline_plate` emitter (outline + dark holes / pilot / slots / bores).
  - Gates: `core/gantrylab/assembly/gantrylab_assembly_selftest.gd` (48)
    and the parts-editor half of `gantrylab_designer_check.gd` (REAL
    clicks: module pick, double-click down to the part, slide, undo,
    palette mount + T-nuts, NEMA 17 onto it, unlink, reset, the X5S Z axis
    dragged as one). Not done: CoreXZ / delta / router as mates, MGN rails,
    belts the player routes by hand (loops are the generator's), more Z
    motors than two drawn, hidden / plate corners, the tour still re-shot.
- **Shaft-guided lowering bed + modules (2026-10-26).**
  - A cube machine whose Z guide is `rod_8` / `rod_10` / `rod_12`
    (`GantryLabGenCube._rod_bed`) gets the X5SA / Ender-5 Plus Z: per side
    a Tr8 screw between two round shafts, mirrored front and back of it
    (spacing = half the bed depth, 120–420 mm). Shafts stand in SK supports
    (`sk8/10/12`, origin ON the shaft axis, base `sk_h` behind) on the base
    side beam's inner face and on a new Z top beam (`zt.L/R`) under the Y
    wheel plates. A `z_carriage` plate rides the shafts (its `bore` is a
    sliding shaft mate on `rod`, no fasteners), two `lmf*uu` flange
    bearings hang under it, the Tr8 nut sits on top, the bed arm lies on
    its grid ("lines" mate). The motor hangs under the base side beam on an
    L mount; the screw is drawn at the drive's real Ø. Coax pairs check
    every shaft through its bearings and top support. `ROD_DIMS` (Misumi SK,
    Samick LMF, 7850 kg/m³) is the one table. Other Z guides keep the
    V-wheel back-upright bed. The big-flake application uses `rod_12`.
  - Unmodelled settings now SAY so as `"note": true` issues (MGN / HGR
    guides on V-slot frames, non-bracket corners, more than two Z motors);
    the design's "Every part fastens" line and the clean-preset gate skip
    notes.
  - **Modules** (`doc.modules`: {id, label, parts, kids, anchor, twin},
    added by `GantryLabGen.module` / `twin_modules`; cube: frame, XY
    gantry, motor drives, `zaxis.L/R` ⊃ `zdrive` + `zguide` + `zcarr`, bed,
    electronics; slinger: base, gantry ⊃ X axis + Z drives, Y drive, bed).
    `GantryLabAssembly.move_group(res, ids, delta)` moves a group rigidly:
    each member whose parent is not moving is re-mated by `infer` at its
    moved pose (refused if it cannot land there), the rest follow their
    parents; a coax pair with one side moving is allowed only ALONG the
    shared axis (a nut riding its screw), so a Z drive cannot leave its nut
    behind. `drag_module` slides the module's `anchor` along its own mate
    and moves the twin module by the x-mirrored delta; `apply_patches`
    writes the results with `set_part` (no second mirroring).
  - Editor (pallet-rack pattern): a click picks the module directly inside
    the open one (`ctx`), dragging it moves it as one, a double-click opens
    it, Esc / the breadcrumb step out, a module card lists its sub-modules
    and parts. ⚠ The open module is reset when another design loads (same
    module ids exist across designs).
  - Presets: `tronxy_x5s` (CoreXY 330, 2020, 10 mm shafts, dual Z, RAMPS,
    Z at 8 microsteps), `cube_350` (Ender-5 Plus class), `tronxy_x3` (from
    the X3 assembly guide: 2020 bed-slinger, M8 threaded-rod dual Z,
    GT2-16; drive `threaded_m8`, Z feed capped at 2.5 rev/s).
  - Probe: `tools/diag/gantry_assembly_probe.gd -- --kin=rods:<kin>` (720
    shaft-bed variants, clean for corexy and cartesian_xy).
- **Print preview = extruded roads (2026-10-26).** The old preview put ≤4000
  boxes at the toolpath's VERTICES: on a cube's walls those are the corners,
  so layers read as vertical posts. `GantryLabBuilder.set_print_preview(moves,
  line_mm, layer_mm, color, mottle)` lays one rounded road per extruding
  planner move (straight runs merged), line wide (nozzle × 1.12 for
  additive), layer tall (`layer_guess_mm`: the commonest Z step), its top at
  the nozzle, alternate layers shaded, under the bed node.
  `set_print_progress(move, s)` (the modal) grows the current road to the
  nozzle; `set_preview_progress(frac)` (the in-world runtime, by printed
  length) and `set_toolpath_preview` (point list) still work.
  ⚠ Two MultiMesh traps, both of which hid the print:
  - Instances written while `visible_instance_count` hides them are dropped
    when the count grows: only the road being drawn showed. Every road stays
    drawn (`visible_instance_count = -1`), unprinted ones at a zero basis
    (`_HIDDEN`), and `_set_shown` rewrites only the range that changes.
  - The engine's own bounds are taken once, while few roads show, so the
    rest was culled: `custom_aabb` covers the whole print.

  Headless, MultiMesh keeps no transforms: tests read `road_transform(k)` and
  `roads_shown()`. A pale colour washes out white under the studio light;
  plastic flake is a mottled deep blue. The cube sample now has solid bottom
  and top layers and 25 % crossing infill. Diag:
  `tools/diag/gantry_print_look_diag.gd` (windowed, `--preset=`, `--frac=`,
  `--out=`).
- **Tools drawn from a model.** `GantryLabFrame.TOOL_SCENES` = {path, tip
  (the nozzle tip in the model's frame), strip (exporter leftovers), env
  (envelope round the tip: clash box, clearances)};
  `GantryLabBuilder._scene_nodes` instances it with the tip on the tool's
  origin. Without the art it falls back to the TOOL_KINDS emitter.
  `TOOL_MOUNT_BACK` sets the carriage face behind the axis (default 13.5 mm).
  `tool_front` / `tool_side` widen the cube (`cz`, `x_pull`, X motor, idlers,
  Y belt) and the slinger (`x_margin`, X motor, idler) for a big head. First
  tool: `flake_extruder_6mm` (the player's "Trash Printer Extruder.glb",
  copied to the gitignored `Imported Models/Gantry/trash_printer_extruder.glb`:
  2" camlock hopper, wye, 4" flange, 150 W band, 6 mm nozzle, tip at model
  (0, -0.1597, 0)), 6 mm beads, 3 mm layers, PP / PETE flake; preset
  `trash_flake_600`. Hopper tools (material not "filament") get no Bowden
  extruder.

## Toroid designer (core/toroidlab/, 2026-10-26)

Library → Structures → "Toroid designer…" (no hotkey); click a placed
toroid or the prop editor's "Edit toroid…" reopens it bound to the prop.
The dome-lab pattern: pure modules under `core/toroidlab/`, the modal
`scenes/ui/toroidlab_modal.gd` (own CanvasLayer 27, `UiFit.keep_fitted`,
modal claim, SubViewport studio; it reuses DomeLab's emitters `_atri` /
`_hex` / `kind_for_look`, DomeLabSpec's formatting, DomeLabMaterials' bolts
and DomeLabCam's DXF / SVG writers). Record key `toroid_spec`, model id
`toroidlab_structure` (`ToroidLabBuilder.MODEL_ID`), library
`user://toroidlab_library.json`, exports `user://toroidlab_designs/`.
- **It is a torus.** The user's "Overview Toroid structure.glb" (in their
  Documents, not committed; inch units, SketchUp via SimLab) measured with
  `tools/diag/glb_mesh_table_diag.gd` (every mesh as a JSON row, `--verts-mat=`
  dumps a material's vertices): a least-squares circle fit of every rib tube
  gives ONE circle, r 1.825 m centred 2.205 m out and 1.352 m up, for the
  outer wall, the top AND the inner hourglass. So a design is
  `torus {major_r_m, minor_r_m, centre_h_m, base_y_m, segments}`; a point is
  (θ round the axis, φ on the minor circle from its outer equator up over the
  crown, ρ from its centre). The modal edits inner radius at the ground /
  outer radius / height and solves back (`torus_from_measures`:
  r = (H + A) − √(2AH)).
- **Ribs**: outer ground (φ = −g, the ground cut) to the inner top ring
  (−1 = 180 − g, so the arcs are equal) in `ribs.pieces` arcs (couplers);
  every `inner_every`-th rib continues down the inner wall (`inner_skip` =
  a doorway; the reference leaves ribs 17 and 19 open), with an optional
  straight post beside it.
- **Rings** sit at φ; on a rib node they take tees / crosses (5-way where
  a post joins), off a node they pass ONE OD inside the ribs on crossover
  clamps (the reference crown ring at 77° is clamped under the ribs); ring
  tubes span `piece_bays` bays; splices off a tee are couplers.
- **Bracing** = a list between ring indices (in φ order: outer ground = 0),
  pattern x / diag / zigzag, member tube (swivel clamps) or cable (eye
  clamps, a turnbuckle, thimbles), every / start.
- **Canopy** (`ToroidLabCanopy`): per bay a diamond pleat — seam A–B on the
  rib, mid-bay valley Vi, peak P, valley Vo, each at (φ, depth inside the
  rib circle) — as three triangles per half, unfolded isometrically (A at
  the origin, B on +x, flaps across A–P and P–B), a 2" flange along the
  seam standing in the rib plane, bolted back to back with the neighbour's
  (each half a sheet's thickness off the plane). Pieces turned to their
  smallest rectangle that fits the sheet; MaxRects nesting. The reference:
  692 × 2434 mm, one 4' × 8' sheet per half-bay, 48 sheets, 144 bolts —
  the user's build. ⚠ `phi_in_deg` 118.8 (measured 119.2) keeps the seam
  under 2440 mm; at 119.2 it is 2444 and nothing nests.
- **Solar**: per bay, centred mid-bay at `centre_deg`, flexible modules
  bent along the minor circle (rigid ones on the chord, with a sag warning);
  `series` × `parallel` from the spec. Placing (or Apply) seeds a graph
  array tagged `toroid_<prop_id>` (`PlacedPropService.seed_toroid_graph`;
  packed = removed; delete = removed) and
  `add_imported_solar_panels` now honours `opts.series` / `opts.parallel`
  instead of its own best guess. A full ring's mean normal is straight up,
  so the array is flat (tilt 0).
- `ToroidLabCam`: the canopy sheet layouts (one file per distinct layout),
  a full-size SVG bending template per bent class (the tube's band, the
  chord, ticks every 100 mm), tube / BOM CSVs, cut sheet, JSON.
- Not built: tube splice positions on rings longer than a stick (counted,
  not placed), the canopy's hanger hardware drawn, an NPC crew, per-panel
  azimuths on the graph (one flat array).

## Solar designer (core/pvlab/, 2026-10-27)

Library → Structures → "Solar designer…" (no hotkey); click a placed array or
the prop editor's "Edit solar array…" reopens it bound to the prop. A placed
legacy `pv_array` rack has "Open in Solar designer…", which converts it
(PlacedPropService.convert_pv_array_to_pvlab). Model id `pvlab_array`
(`PvLabBuilder.MODEL_ID`), record key `pvlab_spec`, library
`user://pvlab_library.json` ({modules, designs}), exports
`user://pvlab_designs/`. Plan: `~/.claude/plans/i-want-a-new-foamy-goose.md`.
- **A spec is one module on one array** (`PvLabSpec`): `module` (PvLabModule:
  dims mm, type rigid / glass_glass / flexible / thin_film / folding, cells
  {tech, format, cut, cols, rows — counts of cell PIECES — gap, split gap,
  busbars, fingers, chamfer, parallel}, frame, backsheet, glass, jbox
  {layout, leads_mm, connector}, bypass_diodes, folding, look, electrical
  {mode derived | datasheet, nameplate, coefficients, NOCT, mass}),
  `array`, `rack`, `tracker`, `strings` {mode rows | cols | custom, size
  (0 = the longest the target allows), inputs, groups}, `target` (the
  controller window), `colors`.
- **The cells ARE the electrics** (`PvLabCells`, per-cell Voc / Jsc / vm / im
  read back from real data sheets, cited): Voc = series cells × cell Voc,
  Isc = paths × Jsc × piece area (pseudo-square chamfer from the ingot
  diameter; poly is cast square). A half-cut module is two halves in
  parallel. Datasheet mode keeps the typed nameplate and warns past 12 %.
- **Substrings** (`PvLabModule.substrings`): diode groups by column pairs (else
  rows), each with its parallel paths, each path a list of sample BANDS: a
  path's light = MIN over bands of each band's MEAN (series cells run at the
  weakest; a thin-film strip averages along its length).
- **I–V** (`PvLabIV`): single-diode with Rs, no shunt (Villalva 2009), V(I)
  explicit; a, Rs, I0 fitted per cell through (Vmp, Imp) with dP/dI = 0, so
  a uniform module at STC makes exactly Wmp (pinned). When even Rs = 0 cannot
  reach the fill factor (CdTe), Rs = 0 and a is solved through Vmp; ⚠ v(Imp)
  FALLS as a grows, the first bisection had it backwards. Substring = paths in
  parallel behind a 0.5 V Schottky drop; string = voltages add at one current
  (current grid dense under each substring's limit); array = currents add at
  one voltage; MPP refined. Curves cached on quantised irradiance (2 W/m²).
- ⚠ **Half-cut physics**: one shaded HALF still sends its substring's current
  through the shared diode — it costs a third, like a full-cell module. The
  half-cut advantage is a shadow along an EDGE (every substring's lower half):
  half kept, where full cells go nearly dark. The plan's "a sixth" was wrong.
- **Layout** (`PvLabArray.layout`): the array frame faces +Z (south at yaw 0,
  as PvArrayBuilder). Fixed tables: rows march north, `cols` across, `stack`
  up the slope; row pitch 0 = no winter-noon shade (PvGridSnap.shade_gap_m at
  `site_lat`). roof_flush / none are tilt 0 in their own frame — the PROP's
  pitch / roll lay them on the roof. Trackers: rows spaced along X by GCR,
  the axis along Z, heads turned about Z (+ tips toward −X, west at yaw 0).
- **Racks** (`PvLabRack`): 2x4 / 2x6 lumber (NDS 2018 Table 4A SPF #2),
  Unistrut P1000 / P1001 (catalog Ix / Sx, 25 ksi), generic Al rail
  (labelled an estimate), posts, torque tube, pipe; mounts ground, roof_flush
  (L-feet), roof_tilt, ballast, pole, tracker, none. Span check = simply
  supported rail, bending and L/180 deflection; BOM first-fit stock packing.
- **Tracker** (`PvLabTracker`): Marion & Dobos 2013 eq. 7 (pvlib singleaxis
  convention), backtracking `R − sign(R)·acos(min(cos R / GCR, 1))`
  (pinned: the next row never shades), limits, night / wind stow.
  `PvTrackerRuntime` turns the heads (sim-time aware like CspTroughTracker);
  the energy model computes the same angle per instant itself.
- **Builder** (`PvLabBuilder`): module mesh per design (glass face with
  `pv_module.gdshader` — the cell grid procedural over UV, fingers / busbars
  box-filtered with fwidth so they never shimmer — frame C-profile, backsheet,
  junction boxes, connectors), modules a MultiMesh ("Panels", per tracker
  head), members swept from their real section ("Rack"), string links as
  cables, a hidden "CollisionMesh" (modules + members: other rows' shading
  rays hit it), `pieces` for deploy crews. Overlay tints go through
  INSTANCE_CUSTOM only with `use_overlay` (a plain mesh's COLOR is white).
- **Modal** (`scenes/ui/pvlab_modal.gd`): Cell / Panel / Array tabs over one
  studio, an I–V / P–V chart, string painting by clicking modules (switches
  to custom wiring), test shadows (edge / module / pole / leaf) with the
  mismatch loss, live tables against the controller window, "now" at the
  site when bound (sun, weather, plane, live shade).
- **Graph** (`GraphPvLabArrays`, view delegates add_designed_solar_array /
  remove_designed_solar_array / designed_array_strings): one compound
  `compound_kind` "pv_design" per MPPT input with ONE + / − pair (exposed
  ports "positive" / "negative" over the strings' bus) and the real panels
  wired in strings inside, so flat_connections / PvElectrical /
  GraphDcElectrical see real strings. Re-seeding rebuilds the interior in
  place (outside wires survive). Not compound_kind "array": walk_items counts
  the panels, never the compound too. Panels carry pvlab_tag / pvlab_panel /
  bound_prop_id and their plane or tracker. Opening the designer bound reads
  the graph's strings back (custom wiring).
- **Energy**: `_collect_root_array_aggregate` adds "planes" ONLY when a
  designed array exists (each MPPT input its plane or tracker, the rest of the
  PV one plane at SolarUI's orientation); SolarUI `_compute_solar_kw` sums
  share × POA per plane (`_poa_for` is the same arithmetic). No planes = the
  old single-plane path, untouched.
- **Shade** (`PvLabShading`): samples on the module faces 3 cm out, rays to
  the sun (`Live`: 96 rays a tick round-robin, a pass restarted when the sun
  moves 0.25°), a shaded sample keeps the plane's diffuse share
  (`PvLabShading.poa`, SolarUI's model), the I–V model gives the factor.
  The throttle pass adds one receiver per compound (its `s` + a
  `factor_fn` that GraphSolarShading.factors_at calls for rendered instants:
  one ray per module, ≤ 48). Panel cards say "Shade on N of 3 substrings".
  A tracker excludes its own PropBody (the collider is built flat).
- **Placement** (`PvSurfaceAim`): physics hit on terrain or a PropBody, or an
  OSM roof via `TerrainLoader.roof_ray` (marching `BuildingBuilder.roof_plane_at`
  over footprints the ray crosses — buildings have no collider). A pitched
  surface (> 6°) switches the ghost to roof_flush and lays it in the surface,
  facing down the slope; R / Shift+R turn it. The record stores yaw / pitch /
  roll / y_offset and `mount_host` {kind, id, local}: a prop host moving
  carries it (`_reseat_hosted`), a deleted host drops it to the ground
  (`release_hosted`). ConduitSurfaceAim's merged-buildings lookup now finds
  "Buildings/BuildingMeshes".
- **Second pass (2026-10-27).**
  - **A type is a build** (`PvLabModule.type_patch`, `TYPE_PATCH`):
    switching Rigid / Glass–glass / Flexible / Thin film / Folding sets the
    frame, thickness, front sheet, backsheets, boxes and (for thin film) the
    cells. Before, the type was only a label and nothing on screen changed.
    Flexible laminates have rounded corners (`corner_r_mm`, −1 = by type),
    ETFE dimples and grommets; a clear rear (glass–glass) draws the cells'
    grey backs through it (`cell_material(..., back = true)`, shader
    `back_side`).
  - **Frame lip**: `frame.overlap_mm` (default 4) and `lip_mm` (1.8). The
    glass runs under the lip, which stands proud of it.
  - ⚠ **No point-sampled fine lines in `pv_module.gdshader`.** Every pattern
    (cell gaps, busbars, fingers, scribes, the film's relief) is the
    box-filtered INTEGRAL of its pulse train (`pulse_int` / `pulse_cov`, a
    1.5-pixel box). Footprints are taken once at the top, in uniform control
    flow: derivatives inside a branch are undefined at its edges. Sampling a
    0.35 mm busbar with a soft edge is what made the medium-distance moiré.
  - **Racks are drawn down to the part** (`PvLabHardware`, d["parts"]):
    - module clamps (mid / end, black on a black frame unless set), rail
      splices, end caps (yellow on Unistrut), grounding lugs;
    - a joint at each rail-over-purlin (aluminium L-bracket / P1026-class
      fitting / H2.5A-class hurricane tie) and at each leg top (post bracket
      / gusset / BC4-class post cap);
    - footings (`rack.footing`: ground screw, pier, base plate,
      ABU44-class post base), flashed L-feet on roofs, ballast brackets,
      brace bolts;
    - on trackers: bearings, a slew drive per row, module rails
      (`mrail` members), U-bolt rail clamps and module bolt sets.

    L-feet, ground screws and bearings stopped being members. The BOM counts
    the drawn parts and their fasteners (`FASTENERS`). `PvLabBuilder.emit_part`
    draws each part; `pick_any` picks module / member / part.
  - **The Array tab picks parts.** A click selects a part or member. Its card
    says what it is, its spec, where it is, how many, cost, mass and
    fasteners, with "Light all". The Modules toggle hides the modules. The
    BOM's eye buttons light every part of that kind.
  - **Real modules** (`PvLabCatalog`): 21 data-sheet modules (JA, LONGi,
    Canadian Solar, Trina, Jinko, Qcells, REC, Maxeon, Panasonic, LG,
    First Solar). They come from the makers' data sheets as transcribed, not
    re-checked against the PDFs. The selftest holds every entry to
    Vmp × Imp ≈ Pmax and its cells fitting the face. `module_spec` picks the
    largest standard wafer that leaves a 7–25 mm lip.
  - The left list has a search box that matches every word against maker,
    model, watts, tech and size.
- Not built: per-module orientation on curved hosts (an array is planar), a
  2D plan view for string painting, bifacial rear gain, inverter /
  optimiser / micro-inverter models, a building host re-seated after a style
  change, MPPT-input split of one prop across two controllers by hand (the
  compounds wire to the nearest controller), moving or swapping a rack part
  by hand (parts are picked and listed, not edited).

## Maps and scene shell

Two playable maps, both rooted on `main.gd` (Node3D "Main"):
- `scenes/maps/soak_festival_2026.tscn`
- `scenes/maps/mars_aerial.tscn`
Map chooser: `scenes/ui/map_select/` + `maps/map_definition.gd`
(TRUSTED_SCENE_PATHS, legacy-path normalization for old saves).
The boot scene is the launch hub (`scenes/ui/map_select/map_select.tscn`). The
older Mars variant `scenes/maps/mars_main_legacy.tscn` (formerly root
`main.tscn`, gitignored) is the fallback when `mars_aerial.tscn` is missing;
`res://main.tscn` survives only as an old-save key in `MapDefinition`.

**MAPS vs WORLDS (core/worlds/, 2026-10-10).** A MAP is terrain + auto-
generated OSM content: `terrain_cache/*`, `weather_cache/*`, the
`user://maps/loc_<lat>_<lon>.tres` registry — shared, regenerable. A WORLD is
a map plus everything built or simulated on it, and several worlds can stand
on one map. The map chooser lists WORLDS (newest first, renamable, Copy,
Delete = move to `user://worlds/_trash`) plus a NEW WORLD panel (a clicked
location or a built-in map, a name defaulting to the location label, a
"Re-download map data" box that refreshes only the MAP). The 8 anonymous slots
are retired (`slot_NN.save.json` left on disk); the timeline 💾 opens
`scenes/ui/world_panel.gd` (rename, "what this world holds", Save now, Save a
copy as…, New world on this map, Exit to menu).
- **`WorldPaths` is the ONE resolver** for every per-site world file
  (`site_file(kind, lat, lon, ext)` / `scene_file` / `keyed_file` /
  `graph_autosave_path` / `scores_path`, families in `WorldPaths.KINDS`).
  Storage modes: none (no world active — selftests, a harness without
  `--world`: paths BYTE-IDENTICAL to the old `user://maps/<kind>_<lat>_<lon>`
  literals), `legacy` (a build migrated from that layout — files stay where
  they were, nothing is moved), `dir` (`user://worlds/<id>/<kind>.<ext>`). A
  new per-site file family MUST go through it: `world_store_selftest`'s
  coverage guard fails on any new `"user://maps/` literal outside the MAP
  allow-list. Static, autoload-free on purpose (layer classes load under
  `--script`). Static caches keyed by site must key on the RESOLVED path
  (`PlacedLightService.get_layer`, `PlacedPropService._layer_for_main`) — two
  worlds share a site key.
- **`WorldStore`** (records `world.json`, `snapshot.json`, `thumb.png`,
  `assets/`), all functions take the worlds root so the selftest runs on a
  TEMP folder. `migrate_legacy` runs once per site from the picker (recorded
  in `user://worlds/migrated.json`, so trashing a migrated world does not
  resurrect it) and adopts the old global `autosave.save.json` as the
  matching world's snapshot.
- **Always-live save model** (`WorldSession`): props, lights, camps,
  sculpting, water, vegetation, the graph (incl. NPC `pop_state`) and the peak
  score are written as they change; a save = `flush` (group
  `world_persist` → `flush_world_state()`: the graph view forces every
  habitat's `pop_state` past its ≤2×/sim-hour gate via
  `NpcPopulationBridge.persist_all_now` + the peak score; the loader flushes
  its debounced prop save) + the SNAPSHOT (`main.build_save_snapshot` WITHOUT
  `system_graph` — the world's graph file is newer — plus `world_extras`: the
  ridden vehicle, festival mode, the SolarUI panel config). It runs on the
  180 s autosave, Save now, Exit to menu and window close. ⚠ An EMPTY
  `system_graph` must not be applied (`_apply_save_snapshot` guards it): it
  latches "a game save owns the graph" and skips the world's graph file.
- ⚠ **Switching scenes SEALS WorldPaths** (`WorldSession.switch_scene`):
  the old scene's exit-time flushes (the graph view writes its autosave in
  `_exit_tree`) would land in the NEXT world's files, or with no world active
  on the player's legacy build. Sealed writes go to `user://worlds/_discard`
  (duplicates — save_now already ran); the next world activates on the new
  scene root's `node_added`, before any `_ready`, with a 3 s fallback so a
  session can never stay sealed. Never `clear_active()` while a world scene
  is running for the same reason (the harness seals instead).
- **Resume fixes found by `--capture=worlds`:** the temp load floor (an
  infinite plane at y = 0) was never removed on a resume, so a site below
  zero (Walton, -95 m) restored the player standing on it
  (`_finalize_resume_actors`); `Player._ready` defers
  `_init_first_person_camera`, which zeroed the restored pitch
  (`main._reapply_resume_view`). `PeakField` now saves its LIVE state
  (who is mid-peak, charge, episodes) with the score.
  Fixed 2026-10-12: the battery jumped on every reload of a world whose graph
  battery bank differs from `solar_panel_config.cfg`'s capacity. SolarUI boots
  at the config capacity and the snapshot restores the saved kWh. The first
  `apply_from_graph` then saw a "capacity change" and rescaled the battery by
  a mirrored fraction (Walton: 5.09 → 4.12 kWh). `_soc_restored_pending` makes
  that first sync keep the restored kWh.
- `WorldAssets` vendors what a world references from global libraries (user
  GLB catalog entries by `model_id`, G-code jobs by `job_id`, `music`,
  `wall_texture`, any `user://` path string in the world's JSON, plus small
  libraries: resource kinds, recipes, presets, camp styles, pack defs) into
  `assets/` on full saves; `restore` before a launch puts back missing files,
  restores a CHANGED library file beside it and remaps the world's own data to
  it, and re-registers missing catalog entries.
- Inside a world "Re-download map data" (Terrain options, the new-world box)
  refetches DEM / imagery / OSM only — the world's overlays always load
  (`_should_load_user_map_overlays`); a clean slate is a new world.
- `StarShadeGraphSeeder._scene_has_starshade` only matches Node3D: the
  loader's `StarShadeEditLayer` UI node used to seed an 18-panel StarShade
  system into every empty generated-map graph.

**Asset packs — Share… (core/sharing/ + scenes/ui/asset_pack_modal.gd,
2026-10-15).** The GitHub repo has no large art. **Share…** (launch hub
header, each world row, the in-game 💾 panel) exports one `.simpack.zip`.
Installing one (Share → Install a pack, or drop the zip on the window from
any screen, via `CursorController._on_files_dropped`) puts a friend's game in
the same state. Plan: `~/.claude/plans/the-github-version-of-starry-lighthouse.md`.
- **Sections** (`AssetPackFormat`):
  - `worlds/<id>/…` — DIR layout. `data_files` → tags, as `duplicate_world`
    does, so a legacy world travels like a new one. Includes the snapshot,
    thumb, `assets/` and the map's `extents_*.json`.
  - `mapcache/terrain_cache|weather_cache/…` — on by default. Matched by
    `AssetPackCatalog.file_names_site` at each name's OWN precision: the AI
    patch is 5 dp, climate is 2 dp, and 8.3252 is not 48.3252.
  - `library/…` — the content groups (`LIBRARY_GROUPS`).
  - `settings/*.cfgjson` — off by default (`AssetPackPrefs.SHAREABLE`).
  - `project/…` — the gitignored art (`ART_DIRS` / `ART_FILES` /
    `ART_ROOT_GLOBS`) WITH its `.import` sidecars, which keeps `uid://`
    stable. Only offered when `running_from_source()`.
  - `simpack.json` (the manifest, in part 1) plus `simpack.hashes.json` at
    the end of every part.
- **Hard rules, enforced by BOTH writer and reader** (`entry_allowed`):
  - Secrets never travel: `SECRET_FILES` / `SECRET_DIRS`.
  - Code never travels: `CODE_EXTENSIONS`.
  - A `.tres` / `.tscn` never travels as user data. The map's
    `loc_*.tres` is rebuilt from `world.json`'s map dict by
    `MapRegistry.ensure_generated`, which the location picker now uses too.
  - A `.cfg` travels as `.cfgjson`: primitive values only, with ints tagged
    so they come back as ints, and absolute paths dropped. An untrusted
    `.cfg` would otherwise go through the Variant parser.
  - Every zip entry goes through `SafeZip`, which `ScadProvisioner` shares.
- ⚠ **Godot's ZIPPacker has no zip64.** A 5 GB write closed `OK` and read
  back as nothing (measured on 4.7.1). The writer bins entries IN ORDER into
  parts ≤ `PART_MAX_BYTES` (3.5 GB) before writing anything. The reader
  finds every part from any one of them (`base_part`). A single file bigger
  than a part is refused.
- **Install never costs the friend anything** (`AssetPackInstaller`):
  - Every world is a NEW id. A clashing name gets " (from <creator>)".
  - The map cache adds only what is missing.
  - A differing folder-library file is written beside theirs as
    `__from_<creator>`. A root single-file preset library keeps theirs:
    the world's own `assets/` copy comes back through `WorldAssets.restore`
    keep-both.
  - The model catalog is MERGED by id.
  - Settings are backed up to `user://pack_backups/<stamp>/`.
  - Art is skipped when the same size is already there.
- `extract()` is file work on a worker thread (`AssetPackJob`, always
  waited on). `finish()` does registry, restore and catalog work on the main
  thread.
- **Art:** after writing, `start_reimport` runs `--headless --path <project>
  --import` as a separate process, polled. Then `restart_game` sets
  `OS.set_restart_on_exit` with the same args, minus the editor's debugger
  hand-off, and quits.
- Export first `save_now`s the running world and `WorldAssets.collect`s
  every ticked world. "Tick what my worlds need" maps props' `model_id`
  through `ModelCatalog._shipped_models` to art groups, plus camps → Camp
  components. A map group pulls in its scene's dependency closure. NPC and
  Player are always included.

**User-created location maps (ROADMAP Pillar 1 — location→world).** One reusable
shell scene `scenes/maps/generated_location.tscn` serves ALL user maps; it is the
Mars shell with world content stripped, regenerated by
`core/terrain/build_generated_scene.gd` (re-run that one-off `--script` tool if
the shell scene changes). Each user map is a `MapDefinition` .tres in
`user://maps/` pointing at `MapDefinition.GENERATED_SCENE` (now in
TRUSTED_SCENE_PATHS) and carrying `latitude`/`longitude`/`half_extent_m`.
`map_select` scans `user://maps/`; the location picker's **"Create map here"**
(`location_picker_ui.gd:_create_map`) writes the .tres and launches it.
Coordinates reach the scene via the `MapContext` autoload (set before
`change_scene_to_file`, which can't pass args; `from_resume` flag keeps the loader
from re-seating the player on save resume). `core/terrain/terrain_loader.gd`
(node "TerrainLoader" under the shell) resolves the site, calls
`apply_location`, fetches elevation + imagery, builds the terrain via
`TerrainBuilder`, and re-seats the player. Save/load already round-trips lat/lon
(main.gd save snapshot + `_apply_save_snapshot`); resume rebuilds the same terrain
(deterministic, same mean-elevation centring → saved player y still valid).

**Spawn = the location marker.** A fresh (non-resume) load seats the player at
the map's SoI centre — the marker the player drags — via
`TerrainLoader._spawn_xz()`, which reads `SoiConfig.load_for_map` directly
because SoiService is bound to the map only AFTER the spawn pass. A marker never
moved is at the origin (the old behaviour); one dragged off the built terrain
falls back to the origin. A save RESUME still restores the saved position.
⚠ The coarse `TerrainCollision` is sunk under the hi-res patch from
`TerrainBuilder.sink_reference_elev` (the patch's LOWEST point), not from the
map's mean elevation: on a wide map the site can lie far below the mean
(Walton: ~100 m on a 120 km world), and a floor at "mean − 80" then hangs
metres ABOVE the ground as an invisible walkable sheet. It went unnoticed while
the spawn was the origin only because `_raycast_reseat_player` rejects a hit
more than 6 m above the footing, which put the player UNDER the one-sided
sheet; at the marker the sheet was 5.7 m up and the player was seated on it.
**Remote drone view (Tab, action `drone_view`)**:
`Player.toggle_remote_drone_view()` moves the drone's home to the current camera
position (minus FPVDrone.mount()'s 1.5 m takeoff lift, hence
`REMOTE_DRONE_LIFT_M`) and mounts it, so the view starts where the player was
looking from; Tab again or X lands it there. `ensure_explore_drone()` covers a
resumed map with no drone node.

**OSM solar arrays (player-selected, not auto-added).** BuildingService pulls
`power=generator` solar ways; `terrain_loader._apply_solar_arrays()` builds each
footprint's panels in-world (`core/terrain/solar_array_builder.gd`) and records them
in `_solar_arrays` (poly + panel_count + base_y + stable centroid `tag`), but adds
NOTHING to the graph/SolarUI on load. The player aims the crosshair at an array
(`interaction_focus.gd:_update_solar_focus` → `pick_solar_array_at_world`), it
highlights **red** (`_draw_solar_highlight`, reuses `TerrainBuilder.build_polygon_highlight`),
and Interact calls `add_solar_array_to_graph(idx)` → `SystemGraphView.add_imported_solar_panels(count, watts, label, array_tag)`
(per-`array_tag` idempotent: re-adding replaces only that array's nodes, keeps
others) + `_refresh_added_solar_total()` feeds the accumulated count to SolarUI.
Added-set (`_added_solar_tags`) survives in-session terrain rebuilds; graph autosave
persists nodes across loads (tag keying prevents duplicates on re-add).

**OSM buildings + Building Builder (core/terrain/building_builder.gd).** Extruded
footprints seat at ONE base Y (lowest corner sample + 0.35 m skirt) so eaves/roofs
stay LEVEL on slopes. Roofs honor `roof:shape`/`roof:angle`/`roof:orientation`/
`roof:direction`; with no tag, residential types default gabled 28°, commercial flat,
`building=yes` by footprint heuristic (`infer_roof_spec`; cache needs NO version bump
for tag-parsing changes — `_deser_item` re-derives from cached tags). Ridge geometry
is a Chebyshev height field over the ridge frame with triangles split at crease
lines (gable/hip/pyramid faces exactly planar; gable-end wall fills share
`_roof_height_at` → watertight; star-shaped footprints fall back flat). Merged mesh
= 2 surfaces (0 walls+floor with per-facade metric UVs, 1 roof with eave-aligned
slope-metric UVs) under procedural `building_wall.gdshader` (lap siding, foundation
band at V<0) + `building_roof.gdshader` (staggered shingles; COLOR.a=0 → flat
membrane); per-building tint in vertex COLOR from `building:colour`/`roof:colour`
or a tag-hashed palette. **Per-building styles:** `BuildingStyleLayer`
(`user://maps/building_styles_<lat>_<lon>.json`, keyed by `building_tag` =
metre-rounded centroid) overrides roof shape/pitch/colors/height/base offset +
facade `elements` (doors/windows as proud quads on a 3rd surface); styled buildings
are EXCLUDED from the merged mesh and rebuilt as `BuildingsCustom/B_<tag>` children
via `build_single_building` (same `_append_footprint` path; the modal previews with
a flat 2×2 DEM). Crosshair focus draws an amber roof-level outline; Interact or B
(`building_builder` action) opens `scenes/ui/building_builder_modal.gd` (veg
"Tune look" pattern: SubViewport studio + debounced sidebar; clicking the preview
ray-picks the wall via `pick_wall_point` — pure math, no studio physics — to place
doors/windows; Library tab lists `ModelCatalog.models_in_category("structures")`
incl. StarShade and hands off to `PlacedPropService` ghost placement or
`replace_osm_building`). `apply_building_style` rebuilds one child; entering/leaving
the styled set re-runs `_attach_buildings`. Selftest:
`core/terrain/building_builder_selftest.gd` (148 checks).

**User model cache (2026-10-21).** `ModelCatalog._packed_scene_for_user`
saves each converted user GLB (glTF import + `_replace_importer_meshes` + the
SketchUp fix) as `user://model_cache/<file>_<key>.scn` (key = size + mtime +
`material_fix` mode + `USER_SCENE_CACHE_VERSION`; older conversions of the same
file are deleted) and later launches load that. Before it, every launch
re-imported every placed user model from the raw file, slow for the big ones,
and Godot printed a "specular and glossiness workflow" warning per SimLab
material (259 a launch on Mount Vernon, 466 on Walton). Bump
`USER_SCENE_CACHE_VERSION` when the conversion itself changes (the fixer's
rules, `_replace_importer_meshes`).

**SketchUp material fix (`core/placed_models/import_material_fixer.gd`,
`ImportMaterialFixer`, 2026-10-13).** SketchUp has no PBR, so glTF exporters
invent the shading terms: SimLab (generator "SimLab GLTF", the common SketchUp
route — 41 of the repo's GLBs and the user's "Halvorsen" models) writes
KHR_materials_pbrSpecularGlossiness specular 0.5 / glossiness 0.5 on EVERY
material plus a metallic/roughness 0.5 fallback, and Godot converts that to
metallic 0 / roughness 0.5 / specular 0.5 — semi-gloss brick, shingles and
siding. The fixer recognises a SketchUp export (generator keywords, or the
SimLab fingerprint: ≥80 % of materials spec-gloss at gloss 0.5), classifies each
material by its NAME (`RULES`, first match wins, specific finishes above
families — "Metal Corrugated Shiny" is painted roofing, "Textile" must not hit
"tile") into a `PROFILES` metallic/roughness/specular class, clears the
invented metallic/roughness maps, and turns the alpha-scissor SimLab puts on
every material OFF where the albedo has no transparency (leaf textures keep it;
a see-through material named after nothing becomes glass). Colours, textures
and UVs are never touched. Two entry points, one class: the in-game loader
(`ModelCatalog._packed_scene_for_user` — per-model `material_fix`
auto/off/force on the catalog entry, `source_app` stamped by
`ModelImporter.import_from_path`, prop editor Model section "Materials" row,
`ModelCatalog.set_material_fix`) and the editor import hook
(`addons/sketchup_import_fix/` — a `GLTFDocumentExtension._import_post`,
project setting `simbiogenesis/import/sketchup_material_fix`). The editor hook
only affects files Godot (re)imports. All 50 SimLab GLBs in the repo (models,
the Mars / SOAK map scenes, StarShade, Airstream…) were reimported with it on
2026-10-13 at the user's request. To force a reimport, TOUCH the source and run
`--headless --import`: Godot re-checks an asset only when its mtime changes —
deleting the `.godot/imported/*.md5` alone does nothing. The plugin is active in
headless imports (it prints "SketchUp Import Fix: <name> — N materials").
Selftest `core/placed_models/import_material_fixer_selftest.gd` (also pins
ImagerySources).

**Pallet-rack design elements (2026-10-20, `core/terrain/pallet_rack_builder.gd`
+ `scenes/ui/pallet_rack_builder_modal.gd`).** Modelled on the Mars College
builds. `rack_spec.elements` is ONE list of `{id, type, ...}` records: `door`
(hinged / double / sliding barn door on a track / open doorway, painted per
colour), `window`, `stair` (IRC risers ≤ 7.5", 10" treads; "along" a face to a
landing, or "out"), `lean_to` (a sloped array on any face: solar modules,
greenhouse glazing, plywood, bare rafters, or "none", per bay via `segments`,
optional glazed ends), `railing` (one per deck: a rail on every deck-cell edge
with no same-height deck beside it, minus faces turned off, stretches a wall
guards and stair landings) and `courtyard` (cut rects in `_layout`'s notch:
deck cells and the rows strictly inside go). `resolve_element` fills
`ELEMENT_DEFAULTS` and clamps to the rack; an unknown type is kept, not drawn.
`ELEMENT_FIELDS` is the inspector's row model (selftest: every key has a
default). Walls gained a band (`wall_bottom_ft` / `wall_top_ft`, -1 = top) and
doors / windows cut their holes (`rect_minus`). Rules that carry it:
- **Faces are named as seen standing in front of the front (-Z) face: left
  is +X, right is -X** (`_face_frame`, `_wall_faces`, the railing classifier).
  Before 2026-10-20 the left wall was -X; the modal camera opens on the
  front-right three-quarter now, and the old naming put "left" on your right.
- Positions along a face are feet from the face's start (`_face_frame.base`),
  floors index `_levels` (template levels then the roof), -1 = ground.
- Pick ids: `el:<id>` (doors, windows, stairs, courtyards), `el:<id>:<bay>`
  (one ORIENTED box per slope bay: `obb_xf` / `obb_half`, tested by
  `ray_hits_component`), `el:<id>:r<k>` (railing runs). The modal groups them
  by `el_id`; a slope bay is selectable alone and Del on it sets that bay to
  "none".
- `solar_summary(spec)` uses the SAME `_pv_layout` as the geometry; placing
  or applying a rack seeds a graph array tagged `rack_<prop_id>`
  (`PlacedPropService.seed_pallet_rack_graph`, removed on delete).
- Modal: "Add to the structure" tools (`TOOL_PRESETS`) arm a placement; the
  cyan ghost is `element_components(spec, candidate)`; a door/window on a wall
  that is off turns it on. Undo snapshots the WHOLE spec now. Designs:
  `design_presets()` (Solar workshop, Two storey with stairs, Stepped
  amphitheatre, Courtyard compound) + the player's library
  (`user://pallet_rack_library.json`, designs and element presets).
- **Winding (fixed 2026-10-24): the rack was built INSIDE OUT.** `_emit_box`
  and `_emit_tri` laid every triangle counter-clockwise seen from outside;
  Godot's front face is CLOCKWISE (a `BoxMesh` has cross(b − a, c − a) · n
  < 0 on every triangle). The double-sided materials still drew each face,
  but Godot turns a back face's normal round, so every face you saw was lit
  as if it faced away: the whole rack rendered dark, walls facing away from
  the sun glowed with bright diagonal streaks, and nothing cast a proper
  shadow. Both emitters now put the corners in clockwise (a mirroring
  transform flips them back); `_test_pallet_rack_more` checks every
  triangle of every design. Any new emitter must keep cross · n < 0.
- **Nested selection (2026-10-21, SketchUp-style).** Emission files every
  piece it draws under a PART id with a path of groups
  (`_Geom.begin(path, labels)`), so the tree and the mesh can never drift:
  - Top level: `deck:<li>` (a level), `frames` (uprights), `wallface:<face>`,
    `el:<id>`. Then `strip:<c>,<li>` (only with more than one column),
    `cell:<b>,<c>,<li>`, then the pieces: `ply:<cell>:<ix>,<iz>`,
    `joist:<cell>:<i>`, `tread:<cell>:<k>`, `beam:<li>,<r>,<b>,<side>` (in
    the cell it carries, `_beam_cell`), `post:<r>,<bx>`, `wall:<face>,<ia>,<iv>`,
    slope `el:<id>:<bay>` → `:m<r>,<c>` modules / `:s<ia>,<si>` sheets /
    `:purlins`, plus `el:<id>:frame` and `:ends`; railing `el:<id>:r<k>`.
    Ids are grid indices: stable across rebuilds and undo.
  - `spec["part_overrides"]` = {id: {hidden, color}}; a group's entry covers
    everything under it, the nearest wins (`merged_override`). Colour paints
    wood (`paint_for`) or steel (`metal_for`); hidden parts are still
    registered (flag `hidden`, no pick box) so "Show hidden" can find them.
    Deleted beams / wall sheets keep their old stores and are flagged too.
    `solar_summary` skips hidden modules.
  - `build_node(spec, name, {record, dim_ctx})`: `record` keeps
    `part_tree()` as meta, `dim_ctx` routes everything outside that group to
    one faded surface. Placed props pass neither; old specs build
    byte-identically (vertex hash checked on every preset).
  - `pick_part(tree, o, d, ctx)` = the nearest piece INSIDE the open group,
    resolved to the group's child (0.3 ms on the largest preset). Pick boxes
    are the oriented boxes each piece was drawn with (≤ 64 a part): a union
    AABB of a sloped frame swallowed the slope's bays.
  - Modal: `_ctx` (open path), `_sel_nodes` (selected part ids); `_selection`
    is DERIVED (the editable components under them) and drives drags, Del and
    the element card as before. Click = select at the level; double-click
    opens; Esc / click outside / the breadcrumb (over the preview) step out;
    Shift or Ctrl adds. Del per kind: element removed, slope bay "none",
    deck/column/bay loses its decking, beam/wall sheet the old way, a whole
    wall turned off, anything else hidden. The parts card: decking + height
    for cells, beam offset, colour (a group colour clears its pieces' own),
    Show hidden inside, Open.
  - Gate: `tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_nested_check.gd -Label <dir>`
    (real clicks / double-clicks / keys, a shot per level) and
    `_test_pallet_rack_parts` in terrain_selftest.
- **Second pass (2026-10-24).** Gate:
  `tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_more_check.gd -Label <dir>`
  and `_test_pallet_rack_more` in terrain_selftest.
  - **Slopes:** `offset_ft` stands the slope off the face; `_emit_lean_bridge`
    puts a ledger, a joist per rafter, a rim, posts past 4' and (`bridge`
    plywood / glazing) a cover over the strip, part `el:<id>:bridge`. The
    module is the element's own: `panel_model` (a `PV_MODULES` preset or
    "custom") + `panel_long_in / short_in / gap_in / watts / voc / vmp / isc
    / imp`; `_pv_layout` uses them and `solar_summary` hands the module that
    makes most of the panels to the graph array (`seed_pallet_rack_graph`
    passes voc / vmp / isc / imp). `gap_fill` seals each solar bay round and
    between its modules (`rect_minus` of the bay, part `<bay>:g`).
  - **Inspector fields** may carry `show_if` (`PalletRackBuilder.field_visible`:
    key → allowed values, `_min`, `_solar`), `section` and `tip`; the card
    rebuilds when the visible set changes (`_vis_sig`).
  - **Stepped module = element `stepped`** (tool "Stepped module"): mode "bay"
    turns deck cell (bay, col, level) into `steps` steps up from the level
    below toward `rise_toward`; mode "face" builds big steps outside a face
    over bays seg_from..seg_to up to `to_level`, each ≤ `rise_in` tall and
    `tread_ft` deep. A bay-mode module CLAIMS its cell: `resolve_spec`
    derives `_stepped_cells` (never read back from a saved spec) and
    `_resolve_cell` reports kind "stepped" (no deck drawn, no deck pick).
    The old `stepped_module` count and per-cell kind "step" migrate into
    these elements on resolve (once); the Variants spin and the "Add steps"
    button are gone, S / the parts card's Decking "Steps" add / remove them.
  - **Dragging moves things** (`_begin_gesture`): a bay (`cell_move`, ghost +
    release; `_remap_cells` swaps the displaced cells into the vacated ones,
    with their overrides, piece colours and stepped modules; Alt-drag still
    raises), doors / windows / stairs round corners onto another face, a slope
    or face steps along / onto a face (`el_bays`), bay steps and courtyards
    cell by cell (`el_cell`), a slope bay onto another (`seg_swap`).
  - **The modal persists** (`user://pallet_rack_draft.json`): "fresh" (the
    new rack) and per placed rack `props[id]` with `base` = a signature of
    the record's spec — restored only while the record is unchanged, dropped
    on Apply / Delete. Saved on close and at most every 1.5 s of edits, only
    while the modal is open (selftests never write it). "New" / "Revert".
  - **Fused racks:** `spec["fused"]` = [{spec, x, z, yaw}] in rack 0's frame.
    `_emit_all` draws every rack (the edited one first and alone in the part
    tree; the others `no_tree`, faded with `dim_others`) through the static
    `_mxf` that `_emit_box` / `_emit_tri` apply, and skips a frame whose two
    posts were already drawn (`_posts_done`). `fuse_transform` snaps the
    relative yaw to a quarter turn and finds the shift landing the most posts
    within 0.6 m (≥ 2 = one frame); `fuse_specs` / `split_fused`. Modal
    "Joined racks": Find racks to join → Join (deletes the other prop, applies
    at once, clears undo), the rack picker (`_switch_module`), Split off
    (`duplicate_prop_record` at its world spot).
- **Chiba presets (2026-10-24).** "Chiba 2024" / "Chiba 2026"
  (`chiba_2024_spec` / `chiba_2026_spec`, ids `chiba_2024` / `chiba_2026`)
  reproduce the camp's real builds from the user's models (`Chiba 2024.glb`,
  `Chiba 2026.glb` in their Downloads, not committed). They were read with
  `tools/diag/rack_model_study.gd` (WINDOWED, `--glb=` or `--rack-preset=`,
  `--out=`, `--dist=`; APPDATA at a scratch folder): the same eight views of
  a model or a preset, plus the post grid, deck heights and sloped areas.
  Rules added to match them:
  - `row_gap_ft` in half feet from 2' (`ROW_GAP_STEP_FT` / `ROW_GAP_MIN_FT`);
    the real racks stand 3.5' and 4.5' apart.
  - Several slopes per face, each on its own bays (the modal's `_slope_over`
    owns the rule; the tool fills the free run round the clicked bay).
  - `pv_rows` / `pv_from` limit a slope's modules to rows from the top /
    bottom / centred; the rest is the gap seal.
  - Stairs `tread_in` (9–24") and `landing_ft` for a run straight out; width
    to 12'.
  - Element `ladder` (face, at_ft, floor, to_level, width), BOM `ladders`.
  Chiba 2026's fused racks sit at measured offsets with yaw 90; open bays are
  roof cells "none" + deleted top beams + deleted upper wall sheets.
  `_test_pallet_rack_more` pins the footprints (2024 26.1 × 11.2 m, 2026
  29.4 × 26.4 m post to post, as the models measure).
- **Stairs with turns and flights (2026-10-24).** Stair element keys
  `shape` (`STAIR_SHAPES`: straight / landing = two flights in line / l =
  a quarter turn on a square landing / u = a switchback on a landing as
  wide as both flights plus `STAIR_U_GAP` / wrap = three flights round two
  quarter turns), `turn` (left / right as you CLIMB; going down turns the
  other way) and `turn_pct` (the landing's height, 20–80 % of the climb;
  a wrap's lower landing at half that). `stair_flight_counts` splits the
  risers; `_stair_flights` lays it out from the top down into
  `G.flights` [{top, h downhill, m, yt, yb}] and `G.landings` [{c, y, h,
  along, across, rails}]; a flight's last riser comes down at
  (m − 1) × tread, where the landing below starts. Landings are at least
  as deep as the stair is wide and 3' (IRC R311.7.6). Handrails on both
  sides of each flight and round the landings' open edges, except a side
  or edge against the structure. A flight that doubles back would run into
  the rack: `_stair_intrusion` measures it and a stair straight out stands
  off on a deeper top landing (`auto_landing`), one along a wall turns the
  other way (`turn_swapped`). `stair_walk_path(G)` is the walk up (the
  crew's visitor uses it). Inspector rows: Flights, Turns going up (L / U
  / wrap only), Landing height (any landing).
- **Open bay, doors in a slope's ends, moving and turning joined racks
  (2026-10-24).**
  - **Open bay** is an element (`open_bay`: bay0, bays, col0, cols 0 = every
    column, `floor` = the deck that STAYS, -1 = the ground, `beams`,
    `walls`). `resolve_spec` derives `_open_cells` ("b,c,li" -> {id, beams,
    walls}, never read back, erased wherever `_stepped_cells` is):
    `_resolve_cell` gives those cells kind "none", the beams carrying them
    are skipped when `beams`, and `_open_bay_wall_holes` cuts the walls over
    them. The tool clicks a deck cell (that cell and everything above opens;
    from above that is the roof deck); it drags like a courtyard. Chiba
    2026's turned rack uses one instead of the old hand-deleted cells.
  - **Doors in a slope's closed ends:** lean_to keys `end_door`
    (none / left / right / both, as seen from outside facing the slope),
    `end_door_style`, `end_door_w_ft`, `end_door_h_ft`, `end_door_color`;
    rows show only while the ends are glazing or plywood. `end_door_spots`
    puts a door as near the structure as fits and lowers it under the slope
    (none where even 5' will not); `_emit_end_wall_with_door` cuts the end
    wall round it. Doors count in the BOM.
  - **Joined racks:** `move_module(xfs, j, a)` moves rack j by `a`
    (left-multiplied, rack 0's frame) and, when rack 0 itself moves,
    re-expresses every rack so rack 0 stays the identity, returning `root`
    = how the build's own pose moved. The modal keeps that as
    `_root_shift` (in undo, the draft and Apply: the prop goes to
    `pose * _root_shift`; join / split / find use `_bound_world_xf()`).
    `snap_posts(pa, pb_local, xf, tol)` = the shift landing the most posts
    (needs 2). A click on a faded rack (`_mod_boxes`, ray vs its box, nearer
    than the edited rack's part) edits it, and `_carry_camera` keeps the
    view put across the frame change; a drag moves it on the ground with
    the snap (Alt off). Joined racks: "⟲ 90° / ⟳ 90°" turn the edited rack
    about its middle (then snap); a placed rack on its own turns itself.
    A fresh build's root turn is not carried into "Place in world" (the
    placement ghost has no initial yaw). Chiba 2026's racks are set apart
    by measured offsets and share no frame, so none of them snaps.
- **Tool Camp pass (2026-10-26, from the user's "tool camp.glb", read with
  `rack_model_study.gd` + `glb_mesh_table_diag.gd`).** Gate:
  `tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_tool_camp_check.gd -Label <dir>`
  and `_test_pallet_rack_tool_camp` in terrain_selftest.
  - **Stairs inside**: stair `run` "inside" (tool "Stairs inside", click the
    deck it reaches). Keys `bay`, `col`, `from_floor`, `climb` (CLIMB_DIRS),
    `pos_ft`, `lat_ft`, `cut_floor`. `_inside_stair_geo` builds the face
    stair's G round a made-up face (base = the top edge, out = downhill),
    centred on the column's clear gap; flights end at `G.y_bot`. `G.hole`
    (the plan footprint + 2") is the stairwell: `_deck_holes(s, L, li)` cuts
    it from every deck the climb passes (plywood by `rect_minus`, joists cut
    with headers, beams crossing it left out) and the stair puts a guard on
    the three sides you do not step off. Inside stairs drag cell to cell.
  - **Workbench** element `bench` {row (rack row), bay0, bays, height_in (top
    of the plywood), overhang_in, shelf, shelf_in}: steel beams on the
    frame's two post lines, plywood across them (`_bench_boxes`). Tool
    "Workbench" picks `bench_slots` (a slab per frame per bay). Inspector
    kind "row" (1-based, column_count + 1 rows).
  - **Pitched roof**: spec `roof_pitch_deg` (0 = flat), `roof_low_side`,
    `roof_eave_ft`, `roof_side_ft` (Levels section). The roof level's cells
    are replaced by `_emit_pitched_roof`: packing on the top beams (falling
    front / back) or on the frames + purlins (left / right), none at the low
    frame line; rafters at the joist spacing; 4x8 sheets laid down the
    fall from the high edge (`ply:roof:i,j`, no sizing). `pick_components`
    and `_deck_rects` skip the pitched roof level. `roof_peak_y(spec)`.
  - **Sheet sizing**: part override `edges` (inches, + grows, − cuts;
    EDGE_KEYS, clamped ±EDGE_MAX_IN, read from the part's OWN id — never
    inherited down the path): `cell:` and `ply:` x0 / x1 / z0 / z1
    (`_cell_rect` is the one cell rect for emission, picking and railings),
    `wallface:` and `wall:` a0 / a1 / y0 / y1 (`_wall_faces` applies the
    face's, `_sized_sheet` the sheet's). A wall face also takes `sheet_w_in`
    / `sheet_h_in` (`_wall_face_sheets` tiles at that size; `_wall_faces`
    entries gained [8] sheet width, [9] height). Parts card "Size" rows +
    Reset size.
  - **Sections**: sidebar "Sections (joined racks)" → Add section (face,
    joined with the row spacing or sharing the end frame, bays, columns,
    starting bay / row). `section_spec` copies the rack system,
    `section_transform` places it (shared frames are drawn once by the
    fused-rack rule); the new rack becomes a module and is edited.
  - **Tool Camp 26** (`tool_camp_26_spec`, preset `tool_camp_26`): main
    3 bays x 4 columns of 36" x 16' frames 5' apart (the model's frames are
    15.5'), decks at 0.4' / 8.4' (none in the middle bay above: double
    height), 2.5° roof falling back with 3.5' eaves, front + end walls 0.75'
    to 13' with a 4' x 9' doorway in every gap of the ends, benches 41.5" on
    the front row / 49" behind, an inside stair in bay 1; a 1-bay x 3-column
    section on the back of bay 3 at the row spacing, benches on its four
    rows, its loft's far half boxed in (walls 8.75'–13.25', sides started
    13' in) and the main loft cell over it run on 5' to meet it. Rack X runs
    along the model's z; the extension sits on bay 3, the same side as in
    the model. Not reproduced: the box's
    50° sloped inner end, the loose table, the roof sitting below the frame
    tops (our roof rests on them, so it peaks ~2' higher).
- **A crew builds it (2026-10-24, from Gene's Mars build lab,

  mars-campus-2026…/lab?scenario=build-bay).** `PalletRackBuildPlan`
  (core/terrain/, pure) turns a rack into the lab's step graph with named
  workers: carry each piece from piles in front of the rack (frames, beams,
  lumber, sheets, walls, parts), raise a frame with two and HOLD it (the
  raisers are busy until the bay's `release`, crew 0), seat the low beams
  with two while both frames stand, release, then the high beams with four
  (two climbing the frame, two handing up), then joists (`fix`), sheets
  (`lay`), steps, walls (`hang`), elements (`assemble`), and a visitor
  climbing onto the top deck. Six is the fewest who can build (two frames
  held + two seating); four reports blocked jobs. `state_at(tl, t)` is pure:
  every piece is in the pile, lifted, carried, set down, raised about its
  base, or installed. Pieces are the rack's BUILD UNITS:
  `PalletRackBuilder.build_units_node` (`_Geom.split`: one Node3D per part
  id, per-material meshes, meta `units` {aabb, kind}); fused racks' ids keep
  their `m<i>|` prefix. `PalletRackBuildSite` (gameplay/) is the rehearsal on
  a placed rack, LinkageBuildSite's pattern: record `build_run = {start_h,
  crew_n}`, build time from the world clock (scrubs, survives a reload), the
  rack's own mesh and collision off while it stands, hi-detail figures on
  the fab clips (carry_beam, lift_ring, hold_brace, place_beam, fasten_bolt)
  with hands on the FabContextRig tool, a progress label over the rack, the
  mesh back after `LINGER_S`. Rack builder → "Build it with a crew": Plan
  (time, jobs, longest chain) and, for a placed rack, Rehearse the build /
  End rehearsal (unapplied edits are applied first). Not built: the real
  NPC population doing it (the site draws its own crew, like the Linkage
  rehearsal), forklifts / hand-up variants of the lab, ladders as climb
  routes. Site cost 0.44 ms a frame on Mount Vernon.
  **The yard (2026-10-26).** Pieces used to be stacked 8 high by their
  AXIS-ALIGNED box in their installed orientation, so sloped modules and
  rafters stacked as tilted boards with air between, mixed sizes overlapped
  or floated, a carried bundle was set down at its old pile heights (in the
  air), poses blended about the build origin (metres away, swinging pieces
  through the air), and the yard sat at the rack's base height whatever the
  terrain. Now:
  - `PalletRackBuilder.flat_frame` gives every build unit its own frame
    (thinnest way up, long way from the smallest rectangle round it), from
    the boxes / triangles it drew (`_Geom.unit_shape`, split mode only);
    units meta `flat` = {basis, size, centre}.
  - `_layout_yard`: a stack per shape per pile kind, pieces flat with the
    long way from the rack, a few side by side a layer (a bundle's
    proportions), up to `STACK_H`, on `DUNNAGE_H` bearers, the piece used
    first on TOP (slots assigned in reverse use order after planning).
    Stacks run along the yard's side and wrap to a row behind.
  - `_finish_carries` / `_stage_bundle`: picks, stands and lift height are
    worked out after the layout; a bundle is set down compactly on the
    ground along the rack's face, clear of the rack and of earlier bundles
    and stacks; carried at hand height (`CARRY_LOW`) but clear of what stays
    in the stack. `_blend` moves a piece's CENTRE in a straight line.
  - `unit_pose` returns g / gxz / rest; the site lifts resting pieces onto a
    ground plane fitted over the stack's or bundle's footprint (`rests`),
    tilt capped at 25°, raised onto the highest point so nothing sinks; the
    bearers use the same plane.
  - `yard_side(bounds, ground)`: the site puts the yard on the flattest side
    of the rack (front unless another is clearly flatter; plan opt
    `yard_side`, part of `plan_for`'s cache key). Mount Vernon's test spot
    is a hillside with the pond in front, so the yard there goes to a side.

**Photoreal buildings (ortho roofs + wall modes + facade textures).** Roof
surface carries geo-registered **UV2** (plan position / `ORTHO_HALF_EXTENT_M`
= 500 m square, (0,0) = NW like the terrain drape; fixed constant → mesh never
rebuilds when imagery lands). A third imagery layer "hyper" (`HYPER_HALF_EXTENT`
500 m, `HYPER_MAX_ZOOM` 19 ≈ 0.24 m/px; cfg override `[terrain]
hyper_target_px`) is requested after the detail layer, never gating load.
**ESRI z20+ exists only in select metros — elsewhere it returns HTTP-200 "Map
data not yet available" placeholder tiles** (a z20 fetch at Bombay Beach cached
an all-grey mosaic → blank grey roofs); ImageryService `_region_is_placeholder`
now rejects near-uniform mosaics as failed layers. `_make_world_roof_material()` sets `use_ortho`/`ortho_tex`/`ortho_uv_scale`
on `building_roof.gdshader` so roofs inside the patch sample the REAL aerial
photo (procedural shingle shade layered on top via `ortho_relief`; detail-drape
fallback remaps UV2 by extent ratio; outside-patch/no-texture → procedural).
**`ortho_uv_scale` must be `BuildingBuilder.roof_ortho_uv_scale(ortho_half_extent)`
— `ORTHO_HALF_EXTENT_M / <half-extent of whatever texture is actually bound>` —
in BOTH the hyper and detail-drape branches, not just one.** The hyper branch
used to leave it at its `1.0` default, which is only correct by coincidence at
quality tiers Low/Medium (`QUALITY_HYPER_HALF_EXTENT` = 500 m there, matching
`ORTHO_HALF_EXTENT_M`); at High/Ultra (1000/1500 m) it silently mis-registered
every roof, worse the farther a building sits from the site center — a bug that
was invisible until a session raised the quality tier specifically to get
sharper imagery. Pinned by `_test_roof_ortho_uv_scale` in
`building_builder_selftest.gd`.
Wall surface UV2 = `(WallMode + 0.5, seed01)`: `building_wall.gdshader` modes
LAP(0, byte-identical original)/TRAILER/CORRUGATED/PLYWOOD/STUCCO +
`weathering` uniform; `resolve_wall_mode` maps `building:material`/
`static_caravan` tags, else footprint <80 m² = trailer-town stock (Bombay Beach
has ZERO material tags in OSM — size heuristic does the lifting). Style keys:
`wall_mode` (int, −1 auto), `wall_texture` (+`wall_tex_w_m/h_m`) — a PNG from
`user://maps/facade_textures/` (drop-in or `tools/generate_facades.py`, Gemini
Imagen, GEMINI_API_KEY env) tiled in metric wall UVs on styled buildings only
(missing file → warn + procedural). Modal adds Material + Facade tex controls
and a **Reference** tab: `MapillaryService` autoload (token
`user://terrain_config.cfg [mapillary] access_token=`, cache
`user://terrain_cache/mapillary/`, CC-BY-SA attribution shown; Google Street
View is ToS-forbidden for texturing) shows nearby street photos; click = wall
eyedropper, right-click = roof.

**Playtest harness (`core/terrain/playtest_harness.gd`, autoload).** Hard no-op
without CLI user args (after `--`). `--user-map=<user://maps/*.tres>` (or
`--map-lat/--map-lon`, or alias `mtvernon`) seeds MapContext + switches to the
generated shell; `--capture=orbit|street|hero|both|graph|siphon|site-review`
waits for `TerrainLoader.map_load_complete` (+ the hyper drape, bounded 420 s
for world), freezes `--time=<hour>` (default 10.0), shoots PNG sets +
`manifest.json` to `user://screenshots/<--shots-dir>/`. **`site-review`** is the
agent-facing composite for a saved site: `world/` + `graph/` (freeform / site
plan / elevation / globe) + `snowglobe/` + `siphon/` Lab + `diagnostics.json` + optional
`--perf` → F3 HUD + `perf/*.json`. `--review-sets=world,freeform,site,elevation,globe,snowglobe,siphon,arranged`
(default omits site/globe/snowglobe); `--no-mutate` skips Lab Demo drive. The
elevation, globe and snowglobe sets print `soi-stage —` PASS/FAIL lines (disc
vs projected SoI centre after pan + cursor zoom, the cut-face cap, no graph
clock claim, captures while the clock runs, the Globe lens drawing, the
Globe → Site Plan flight landing orthographic, and the full-screen globe
entered OVER the open graph): grep them, the PNGs cannot show these.
`--quit-after-capture` exits. F12 = manual shot. Windowed only.

**Graph PV electrical + layout (system_graph/).** `PvElectrical` computes string Voc
(series sum / parallel branch max, cold-temp boost) on PV connections; exceeding
`controller.specs.max_voc` sets `destroyed` + education overlay + smoke FX on the
canvas; RESET hit-test on the node (`controller_reset_pressed`) or inspector button
clears fault and re-checks wiring. `GraphLayout.resolve_overlaps` + fit-to-view run
on first load (no saved layout) and via toolbar **Arrange**; `GraphPvWiring` wires
marquee-selected panels **Series** or **Parallel** to nearest controller `pvPositive`/
`pvNegative`. Destroyed controllers shed AC via `SolarUI.set_graph_controller_destroyed`.
Self-test: `system_graph/graph_electrical_selftest.gd`.

**Solar Concentrators (parabolic-trough CSP, Library category "csp").**
`ComponentPresets.CSP_CONCENTRATORS` (type `"processor"`, `specs.role =
"csp_concentrator"`, reuses the processor UI/save-to-library/inspector path —
see `inspector_panel.gd:_build_csp_concentrator_section`) with `model_id =
"csp_trough"` → same "Place Model" library flow as the 3D VAWT
(`system_graph_view.gd:_on_lib_place_model_requested` → `PlacedPropService` →
`PlacedPropRuntime._maybe_attach_csp_tracker`, which attaches
`gameplay/csp_trough_tracker.gd` to the placed prop). The GLB
(`Imported Models/CSP/single_axis_csp.glb`, inch-unit like the StarShade
bundles → `preserve_scale: true`) splits into `Component#452` (fixed base)
and `Component#453` (the moving concentrator — mirror + focal tube, pivot at
its own origin). **This is an E-W horizontal single-axis tracker**: the pivot
axis runs east-west (`CspTroughSource.TRACKING_AXIS` = world east, the shared
source of truth for physics + 3D), so the trough's long axis lies E-W and the
aperture faces the equator (south in N hemisphere, north in S) while tilting
up/down to follow the sun's altitude. The GLB's NATURAL pose already runs
`Component#453`'s local +X (the ~12 m module-length / pivot axis) along world
east-west — verified empirically (a throwaway diagnostic instantiated the GLB
and measured that axis + the mirror mesh's average normal in world space at
several yaws) — so `ModelCatalog.forced_yaw_deg("csp_trough")` is 0 (no yaw);
`PlacedPropService._build_ghost` applies the SAME forced-yaw constant to the
placement ghost so the preview matches the placed prop exactly (no snap on
confirm). `CspTroughTracker` force-holds `ModelRoot`'s yaw every frame (a
single-axis trough's heading is physically fixed; only its tilt tracks) and
drives `Component#453.rotation.x` from the live tracking angle. Because the
GLB's OWN rest pose (`Component#453.rotation == 0`) doesn't correspond to
"aperture normal straight up" — it measured ~64° tilted toward south, an
artifact of the asset's export pose — `_bind()` measures that bias once from
the actual mesh geometry (`CspTroughSource.tracking_offset_from_normal`:
average local normal of the mirror mesh, composed up the local-transform
chain to `ModelRoot`, projected onto the plane perpendicular to the E-W axis)
rather than hardcoding it, so `rotation.x = ideal_tracking_angle − rest_offset`
lands exactly on the ideal angle regardless of the asset's rest pose (a
re-export keeps working). **Slewing is sim-time aware** (the sun is a function
of the sim clock, which can run at big time-scales or be scrubbed): each frame
the target is refreshed and the concentrator eases toward it with a smoothing
factor driven by BOTH real time (`_TRACK_TAU_REAL`/`_RESET_TAU_REAL`, so it
visibly eases in when the clock is idle) AND elapsed sim-hours from
`clock.get_absolute_hours()` (`_TRACK_TAU_SIM`/`_RESET_TAU_SIM`, so it stays
locked to the sun at any speed); a single-frame sim jump beyond
`_SNAP_SIM_HOURS` snaps instantly (fixes lag at high speed + crawl across
timeline scrubs). Below the horizon it stops chasing the sun and eases toward
the sunrise-ready pose (flat/facing up, angle 0 — an E-W axis can't face the
due-east dawn sun) over the slower reset constants, reading as "park at
sunset, slowly reset overnight". `CspTroughTracker` also paints the curved
mirror mesh (material `Metal_06_1K`) with a near-mirror `StandardMaterial3D`
(metallic≈1, roughness≈0.02). **Absorber-tube identification is geometric, not
by material name**: the model has TWO thin cylinders — an on-axis torque tube
(material `<LightGray>`, perpendicular offset ~0 from the pivot) and the real
solar-collector tube held at the focal line ~188 cm in front of the mirrors
(authored as a glass-envelope material). `_resolve_meshes` picks the thin/long
mesh (`length/cross ≥ _TUBE_MIN_ASPECT`) whose center is FARTHEST from the
local-X pivot axis (via `_relative_to_pivot`), so it glows the focal tube, not
the axis tube (the earlier `<LightGray>`-name heuristic wrongly lit the torque
tube on the rotation axis).

**"Blinding" focal-tube glow.** A plain self-emissive tube material reads as
flat white, not brilliant: this project's WorldEnvironment deliberately caps
DAYTIME bloom to a compact core (fine mips only, capped HDR luminance — see
`main.gd`'s glow setup comments) so ordinary bright surfaces don't wash out
daylight scenes; pushing raw emission higher barely helps once past that cap.
`_update_glow` (per-frame, from `_refresh_target`) therefore drives THREE
layered elements off the same `focus = clamp(dni × cos_incidence /
_GLOW_REF_WM2, 0, 1)` (already cloud- and low-sun-angle-attenuated) with a
shared perceptual gamma curve (`_GLOW_GAMMA`) and an ember→white-hot color
ramp: (1) the tube's own emissive `StandardMaterial3D` (self-lit surface,
peak `_TUBE_EMISSION_PEAK`), (2) a child `OmniLight3D` (shadow/bake/GI-cost
disabled except a touch of `light_indirect_energy`, distance-fade for perf)
that actually lights the mirror/mount around the tube — the "this is really a
light source" cue bloom alone can't sell, and (3) a small camera-facing
additive glow card (`gameplay/csp_focal_glow.gdshader`, a soft radial-falloff
quad drawn straight into the HDR framebuffer — same trick as
`vegetation/camp_glow.gdshader`'s night-light dots) that reads as a convincing
hot point independent of how conservative the daytime bloom tuning is.
**Positioning/scale gotcha:** the GLB has an internal `Node2` ancestor between
`ModelRoot` and `Component#453` carrying a baked 0.0254 (inch→metre) scale
(confirmed empirically) — a light/card parented directly under the tube mesh
would have `omni_range`/card size silently divided by ~39, and spatial
shaders have NO built-in `billboard` render_mode (must face the camera by
hand in the vertex stage via `MODELVIEW_MATRIX`, as `camp_glow.gdshader`
already does — `render_mode billboard` does not exist and fails to compile).
So the light + card are children of `CspTroughTracker` itself (a sibling of
`ModelRoot` under `PlacedProp`, already real-world metres) with their LOCAL
position resynced every `_process` via `_local_chain_transform(_tube_mesh,
_model_root)` — pure local-transform composition, the same technique
`_measure_rest_offset_rad` already uses, robust regardless of the GLB's
internal scale/rest-pose quirks and not dependent on `global_transform` cache
timing. `SystemGraphView._tick_graph_csp` (same cadence/
pattern as `_tick_graph_renewables`) is the authority for telemetry + resource
ports: each tick it computes real sun az/el (`SolarPosition` +
`main.clock.get_julian_day_utc()`) and weather (`SolarIrradiance.sample_weather`),
calls `CspTroughSource.simulate()`, and writes the result onto `specs`
(tracking angle, DNI, end loss, thermal_output_kw) plus `specs.inputs[0].rate`
(water L/h) / `specs.outputs[0].rate` (steam kg/h) so `ResourceFlowEngine`'s
generic tank-throughput logic moves the mass (density 1 kg/L, so the two rates
are numerically equal — mass-conserving). `efficiency: 1.0` / `energy_source: ""`
on the preset bypasses the generic power-draw gating (the CSP is passive — no
AC/DC energy port). Tracking math (`tracking_angle_deg`/`cos_incidence`) is a
pure function of sun azimuth/elevation, so it needs no hemisphere-specific
branches — a southern-hemisphere site's midday sun (in the north) tilts the
aperture the opposite way from the same formula. The E-W config's signature:
zero incidence at every solar noon (perfect, any elevation), worst at
sunrise/sunset (sun on-axis due E/W). New `"steam"` `ResourceKinds` entry +
a "Steam Buffer" resource-container preset close the loop. Self-test:
`_test_csp()` in `source_physics_selftest.gd` (E-W tracking/incidence,
hemisphere symmetry, and `tracking_offset_from_normal` regression checks
pinned to the GLB's measured rest-pose bias — the identity is covered without
loading the GLB).

**Near-field ground detail (Terrain options → "Near-field ground texture").**
`terrain_detail.gdshader` blends a tiling ground albedo/normal (CC0 AmbientCG
`ground049a`, `use_detail_textures`; procedural fBm fallback when the files are
absent) over the aerial photo inside `near_detail_start..end` (4–30 m from the
camera) to give the flat ortho real relief up close. The set is DIRT/SAND — it
sells playa/desert/gravel and fights grass and forest floor, so it is a player
toggle (`[terrain] near_field_detail`, default true = the long-standing
behaviour). Turning it off restores the plain ortho colour, which also exposes
how soft the underlying imagery is — the grain was partly hiding that.
The setting is applied in TWO places and needs both: `TerrainBuilder`'s
`near_detail_enabled` static is stamped into every material `make_terrain_material`
mints (the SHADER's own default is true, so a terrain rebuild/refresh would
otherwise silently switch it back on), and `TerrainLoader.set_near_field_detail`
pushes it live onto the materials already on screen so the toggle is instant.
The live push walks the whole `Terrain` subtree rather than the named
Ground/DetailGround pair the snow push uses, because the HeightField sculpt tiles
carry the same shader and a tile left on the old setting is a visible seam.
`_run_load_sequence` seeds the static from config before anything builds.
Pinned by `_test_near_detail_toggle` in terrain_selftest.

**Terrain data services (autoloads, copy the weather_service HTTP+cache+deferred
pattern):**
- `core/terrain/elevation_service.gd` (`ElevationService`): DEM grid.
  **No-key default (since 2026-10-21) = Terrarium terrain tiles** on AWS Open
  Data (`TERRARIUM_URL`, PNG tiles, no key, no quota), tried before Open-Meteo
  in every source ladder. Why: a fresh install (the exported .exe) has no
  OpenTopography key, and Open-Meteo bills EACH POINT as one call at 600 a
  minute — the 64² default base grid could never finish, the per-minute 429
  was misread as the daily quota, and the world built flat (Bombay Beach
  0..0 m; with tiles -135..914 m). Open-Meteo is now the last rung, capped at
  24² per fetch, and a per-minute / per-hour 429 waits 62 s instead of
  latching the daily flag. The notes below describe Open-Meteo as it still
  behaves when it IS reached. **Open-Meteo rate-limits
  CONCURRENT connections per IP (429), not request count** — so batches are
  fetched SEQUENTIALLY (POOL_SIZE=1, DISPATCH_DELAY between requests). A concurrent
  pool tripped 429 and fell back to flat terrain; sequential is reliable.
 DEFAULT_GRID_N=64 (configurable via `[terrain] base_dem_grid_n`) = ~41 serial
 Open-Meteo batches first visit (~30 s), then cached; ~470 m spacing over 30 km,
 upsampled to mesh res). **Detail DEM is fetched before the first walkable terrain
 build** (not lazy-loaded afterward). With an OpenTopography key it's a single
 512² AAIGrid; without a key the service caps the Open-Meteo detail fetch to
 OPENMETEO_DETAIL_N (64² ≈ ~47 m spacing) at ~40 serial requests. **Seam compose**
 (`TerrainBuilder` + `TerrainSeamDiag`): vertical offset alignment in the overlap
 ring, adaptive feather (80–800 m from boundary delta), exterior coarse ring blend,
 and player spawn gated until composed heightfield is ready. **Map extents
 (`core/terrain/terrain_extents.gd`, `TerrainExtents`, 2026-10-19)** — the
 one set of rules for the three sizes (world / hi-res patch / OSM square).
 STORED as half-extents (`MapDefinition.*half_extent_m`, MapContext,
 `extents_*.json`, the world snapshot + map block, every fetch); SHOWN as side
 lengths in km in Terrain options → "Advanced terrain size". ⚠ The panel used to
 show the half under "World size", so typing 80 built a 160 km world (the
 loading screen prints the side) and quadrupled every request — convert only
 with `side_from_half` / `half_from_side`. `sanitize` clamps (world 10–200 km,
 patch 1–10 km, OSM 1–16 km) and keeps patch and OSM inside the world; the
 loader runs it on every resolve and apply. Sharp overlays (hyper, site) never
 reach past the hi-res patch (`overlay_half`) — outside it the photo lay on the
 coarse world mesh. **Stale results:** ImageryService / ElevationService are
 autoloads that outlive a scene; both get `reset_session()` at load start (job
 seq guards on retry timers) and the loader drops any result whose key is not
 this load's site + square (`TerrainExtents.key_matches`, `_result_is_current`)
 — the previous load's drape used to be taken as the new one's (the "hi-res
 imagery does not line up" report) and its hyper/site downloads queued ahead of
 the new base drape. A DEM that lands after its phase timed out is applied once
 the load finishes (`_late_base_dem` / `_late_detail_dem`) instead of leaving the
 world flat. **Apply & reload** (`apply_terrain_extents`) relaunches THROUGH the
 world (`_relaunch_world_at_current_extents`: map block + snapshot get the new
 sizes, `WorldSession.save_now`, `WorldSession.launch`) — the old direct scene
 change left the snapshot on the old sizes, and `launch` prefers the
 snapshot's, so the next play from the list undid the resize; a resumed player
 off the new frame's ground is reseated (`RESUME_MAX_ABOVE_GROUND_M`). Per-site
 meta still wins over the global `terrain_config.cfg` for a returning site.
 Verify: `terrain_extents_selftest` + `tools/checks/terrain_extents_apply_check.gd`
 (Validation list). The `terrain_loader` used to
 gate detail behind post-terrain phases — detail now blocks terrain build. DEM caches,
 so the first visit per site pays the fetch once (inside the blocking load sequence)
 and every reload is an instant cache hit. Optional upgrade = OpenTopography SRTM 30 m
 when `user://terrain_config.cfg [opentopography] api_key=` is set (gitignored, never
 commit). **3DEP 1 m lidar detail patch (key required — and gated further, see
 below):** with a key, a US `detail` request whose square is ≤ `USGS1M_MAX_SIDE_M`
 (3200 m, so the 3 km default qualifies) fetches `datasetName=USGS1m` off the same
 `usgsdem` endpoint — the USGS-published bare-earth DTM derived from the 3DEP
 lidar projects, ~0.1 m accurate where Copernicus/SRTM carry 1–2 m of their own
 noise. **OpenTopography restricts USGS1m itself to academic-verified accounts —
 confirmed empirically, an ordinary self-registered key gets HTTP 401 "restricted
 for academics" at every site regardless of coverage** (see
 https://opentopography.org/content/how-access-restricted-data-opentopography, or
 email info@opentopography.org re: an Enterprise key). USGS10m has no such gate,
 so it is what most players actually get; `_retry_opentopo_coarser` classifies the
 401 as PERMANENT same as a genuine coverage gap (both correctly fall back), but
 records which one actually happened (`usgs1m_miss_reason`) rather than collapsing
 them into one generic message, since a player can't do anything about a coverage
 gap but might chase down academic access for the 401 case. Surfaced live in
 Terrain options → Advanced terrain size (`TerrainLoader.get_detail_dem_status`,
 filename-only lookup via `ElevationService.cached_dem_source` — no need to decode
 a 100+ MB cached grid just to answer "which one loaded"). **That grid arrives
 in UTM METRES, not degrees** — every other source here is geographic, and feeding a
 UTM header through the degrees path is a SILENT failure: `(lon − 617228)/1.0` clamps
 every sample onto one corner cell, returns a dead-flat plane, and `grid_is_usable`
 then rejects it, so it reads as "1 m did nothing" rather than as a bug.
 `resample_aaigrid_to_bbox` therefore dispatches on `aaigrid_is_projected` and
 forward-projects each target sample via `GeoMath.lonlat_to_utm` (Snyder PP 1395;
 WGS84 ellipsoid — the ~1 m CONUS NAD83 shift is sub-cell and unmodelled). A
 projected grid that fails the centre-containment gate returns EMPTY and drops a
 rung rather than being stretch-fitted (that would misregister terrain vs OSM and
 imagery while looking plausible). Coverage is patchy by nature — 1 m only exists
 where a project flew — so `_retry_opentopo_coarser` falls USGS1m→USGS10m on the
 same endpoint (the one rung allowed for the `detail` tag), and a PERMANENT failure
 writes `dem_usgs1m_miss_<token>.flag` so the next load skips straight to 10 m
 instead of re-pulling ~190 MB; transient 429/network failures deliberately do NOT
 latch it. The flag carries the `dem_` prefix + standard coord token so
 `TerrainCacheSettings.invalidate_dem` sweeps it with the rest of the generation.
 No CACHE_VERSION bump was needed: `opentopo_usgs1` is a new cache-source key, and
 the broken projected path never cached anything (it was rejected upstream).
 Note a 3 km 1 m square is ~9 M cells ≈ 190 MB of ASCII (measured: 26 s to pull,
 10 s to parse) resampled down to `DETAIL_GRID_N` 512² ≈ 5.9 m/vertex — the win is
 accuracy and noise floor, NOT resolution; raising the mesh resolution to actually
 express 1 m is a separate, unmade decision. **Fetch plan (2026-10-19):** every
 request walks `source_ladder` (pure): base = the size's global product then the
 coarser ones, detail = USGS 1 m → 10 m → SRTMGL1 → COP90 (US), and ALWAYS
 Open-Meteo last (a keyed base falls back at ≤ 96²), so a run of 502s no longer
 means flat terrain. A global square over `OPENTOPO_MAX_TILE_CELLS` (2 M source
 cells) goes up as ≤ 4×4 padded tiles stitched into one grid (`tile_bboxes`,
 `sample_tile_into`) — one 180 km COP90 AAIGrid (~5 M cells) 502'd / timed out
 and the world loaded flat; tiled it loads (measured live: 9 tiles at 1.2 M,
 194 s). A timeout drops a rung at once; 429 / 5xx / network errors retry with
 doubling backoff honouring Retry-After (`retry_delay_s`), then drop a rung;
 Open-Meteo batches retry network errors too (one blip used to fail the DEM). A
 later rung's cached grid is served on the next load (`_cached_fallback_path`,
 never for a 1 m first choice) instead of re-hitting the failing source. **Open-Meteo enforces a DAILY quota
 per IP** — when a batch returns `{"error":true,"reason":"Daily API request limit exceeded"}`
 (`_is_openmeteo_daily_limit`), the service fails FAST (no wasteful retries),
 latches `is_openmeteo_daily_exhausted()`, and the loader then SKIPS the no-key
 detail-DEM storm so OSM + vegetation phases aren't blocked ~20 min. **Cache
 recovery:** `find_usable_cached_dem(lat, lon, tag)` returns the best on-disk DEM
 for a site IGNORING the cache_enabled toggle; the loader's `_apply_elevation_fallback`
 (base) and `_recover_detail_dem_from_cache` (detail) use it so a quota/offline
 failure reuses the last good DEM instead of going flat. `grid_is_usable()` rejects
 flat 2×2 / zero-relief grids (both live results and corrupt caches, which are then
 deleted). Only when NO usable cache exists does it fall back to the flat 2×2 grid
 (with a user-visible "Elevation unavailable" warning). Each load phase in
 `terrain_loader._run_load_sequence` now has a TIMEOUT (`_phase_await(secs)`: base
 120 s, detail 300 s, OSM/veg 180 s) so a lost/stale callback can't hang the load
 forever; `ElevationService.reset_session()` cancels in-flight HTTP on each new load.
 Refresh/reset-fresh are blocked while `_load_sequence_active` or when quota is
 exhausted with no OpenTopography key (would delete cache with no way to refetch).
 Cache `user://terrain_cache/dem/` (CACHE_VERSION v3 bumps on grid-N default change).
 Both ElevationService + ImageryService print `served from cache — no download` vs
 `not cached — fetching …` per layer.
- `core/terrain/imagery_service.gd` (`ImageryService`): ESRI World Imagery XYZ
  JPEG tiles (no key), stitched + cropped to the bbox so UV 0..1 aligns with the
  mesh. Cache `user://terrain_cache/imagery/`. `attribution()` must be credited.
  (Raw Sentinel-2 JP2 is intentionally NOT used — Godot has no JP2 decoder; NDVI
  vegetation stays deferred to Pillar 8.) `request_imagery(lat, lon, half_extent,
  target_px, tag, max_zoom)` — `tag` (default "base") labels the layer and is
  echoed in `imagery_ready(key, tex, tag)`/`imagery_failed(reason, tag)`; multiple
  requests serialise through the one HTTPRequest via an internal queue (older 2-arg
  handlers still connect — Godot drops the extra arg). **High-res centre patch:**
  the loader fires a second "detail" request — a 1 km square at z18 (~0.3–0.5 m/px,
  vs ~15–25 m/px for the 30 km base) — and `terrain_detail.gdshader` blends it over
  the central region of the Ground mesh (feathered, no seam). It loads in the
  background and pops in after the base drape, so the world isn't gated on the
  larger fetch (`TerrainBuilder.make_terrain_material` builds the shader material;
  `terrain_loader._apply_detail` swaps it in). ESRI serves the SAME source up to
  z19–23 globally — close-range was low-res only because the base zoom packs all
  30 km into ~2048 px. USGS NAIP (US-only, no key) and Mapbox (key) were evaluated
  as additional sources but not wired (ESRI high-zoom covers it globally, no key).
  ⚠ "ESRI serves z19–23 globally" is FALSE in rural areas: measured at Mount
  Vernon 2026-10-13, z20+ is the "Map data not yet available" placeholder and
  z19 is soft (upsampled).
- **Imagery sources + the native "site" patch (2026-10-13).**
  `core/terrain/imagery_sources.gd` (`ImagerySources`, pure) lists tile sources:
  `esri`, `esri_clarity` (ESRI's sharper, sometimes older capture) and REGIONAL
  orthophotos with a coverage bbox and a capture GSD (`skagit_2021_9in`:
  Skagit County GIS's public ArcGIS tile cache, 9-inch / 0.229 m — roof
  panels readable at z19). `chain_for(lat, lon)` = covering regional sources
  (finest first) → Clarity → ESRI; `request_imagery(..., sources, hq)` takes
  each TILE from the first source that holds it (an ArcGIS cache's blank PNG,
  a 404 or ESRI's placeholder falls through — `is_blank_tile`), records the
  sources used (`<key>.sources.json` sidecar, `attribution_for(tag)`), and a
  non-ESRI chain gets its own cache key (`_<source>` suffix; plain ESRI keys are
  unchanged). ⚠ Extent boxes are not footprints: Skagit's 2013/2015 4-inch
  services cover Mount Vernon by bbox and answer blank tiles there, and its 2021
  3-inch flight stops at 48.357°N. Hyper now uses the chain; detail and base stay
  plain ESRI (most recent everywhere). The new `site` layer
  (`TerrainLoader._request_site_imagery`, fired when hyper lands) covers the
  property at the chain's NATIVE zoom (`native_zoom`: first zoom whose pixels
  are ≤ 1.15 × the capture's GSD), half-extent per tier
  `QUALITY_SITE_HALF_EXTENT` [0, 400, 500, 600] m shrunk to fit
  `SITE_TARGET_PX` 8192 (override `[terrain] site_half_extent_m`, 0 = off), and
  is BC7-compressed on a worker thread (`hq`; DXT1 is 0.09 s for 5k² but its
  two-colour 4×4 blocks read as pixelation at walking height, BC7 ≈ 4 s).
  Shader: `site_*` uniforms in `terrain_detail.gdshader`, over hyper and under
  the AI patch; every drape sampler is now `filter_linear_mipmap_anisotropic`
  (the ground went soft and blocky at grazing angles from 1.7 m). Why the
  Ultra tier looked worse than Medium: hyper spreads one 8192 px texture over
  3 km there (0.37 m/px) while Medium's 1 km hyper sits at z19 (0.2 m/px).
  Skagit's service carries no license text; it is credited as county imagery.
  ⚠ **The real cause of "very pixelated" was the shader, not the tiles.** The
  drape's equirect→Mercator correction computed `asinh(tan(lat))` per pixel
  and subtracted the north edge's: two float32 values ~0.97 that differ in the
  4th decimal over a 1 km patch, so v was quantised into 1–2 m steps and EVERY
  hyper / site drape and photo-textured roof rendered as hard-edged ~2 m
  blocks however sharp the photo (identical with the 0.2 m site layer on or
  off — that is how it was found). `equirect_to_mercator_uv` in
  terrain_detail.gdshader AND building_roof.gdshader now uses the
  centre-relative Taylor series of ∫ sec φ dφ (to d⁴, sub-mm over 120 km);
  `TerrainBuilder.mercator_v_relative` is its GDScript mirror, pinned against
  the exact form in import_material_fixer_selftest. Never compute a Mercator
  difference from absolute latitudes in a shader. The leaf-litter and snow
  break-up also lost their per-cell hashes (`floor(world/1.7)` drew a 1.7 m
  checkerboard) for smooth fBm. ⚠ BC7 runs on WorkerThreadPool and every task
  must be waited on (`_hq_tasks`, `_exit_tree`): an un-waited task crashed
  the engine on quit (0xC0000005).
- `core/terrain/ai_imagery_service.gd` (`AiImageryService` autoload): **opt-in**
  AI "hero patch" — after the hyper drape lands, `terrain_loader._maybe_request_ai_hero()`
  crops the central ~100 m square (`AI_HERO_HALF_EXTENT_DEFAULT` 50 m) out of
  `_hyper_drape` and sends it to Gemini `gemini-2.5-flash-image` (nano-banana,
  image-in/image-out) to sharpen + add photoreal fine ground detail beyond the
  ESRI ~0.24 m/px ceiling where the player spawns. One 2K image per site, cached
  to `user://terrain_cache/ai_imagery/` (so ~$0.04 one-time), overlaid on top of
  hyper in `terrain_detail.gdshader` via the feathered `ai_*` uniforms
  (`_apply_ai_to_terrain`, re-stamped in `_stamp_drape_mercator_bboxes`). Key:
  `user://terrain_config.cfg [gemini] api_key=` (or `GEMINI_API_KEY` env);
  `ai_hero_enabled`/`ai_hero_half_extent_m`/`ai_image_size` also live there.
  Default OFF (no surprise API charge); toggle + **Generate/Regenerate** in the
  Terrain options UI, `refresh_ai_hero()` deletes the cache and re-requests (also
  folded into `refresh_all_cached_layers`). Generative — it only recolours ground
  (buildings/roads/veg are separate meshes) and the prompt pins framing/positions,
  so drift is cosmetic; output carries an invisible SynthID watermark. No key /
  offline / disabled → clean no-op, world still loads.
- `core/terrain/geo_math.gd` (`GeoMath`) + `core/terrain/terrain_builder.gd`
  (`TerrainBuilder`): pure static math (tile/Mercator/extent; ArrayMesh +
  HeightMapShape3D collision). Both covered by `terrain_selftest.gd`.
Both services emit `*_ready`/`*_failed`/`*_progress`; offline → loader falls back
to a flat grid / neutral drape so the world still loads.
- `core/terrain/vegetation_osm_service.gd` (`VegetationService`): one Overpass
 request per site → polygons (wood/forest/scrub/orchard/grass…), `tree_row` lines,
 `barrier=hedge` lines, and `natural=tree` points; feeds AutoVegetationGenerator's
 scatter phases. Cache `user://terrain_cache/osm_vegetation/` (CACHE_VERSION now v8).
 **Cache serializer must include every payload key** — `hedge_rows` was once omitted,
 so cached reloads silently dropped every hedge (fresh fetch had them, cache didn't);
 any new payload key needs matching `_serialize_payload`/`deserialize_payload`
 entries or it vanishes on reload. **Ready-payloads are key-matched to the site**
 (`matches_site`) — the service runs one job with a single-slot pending queue, so a
 listener that changed sites mid-flight must reject the previous site's payload;
 late replies that outlive the loader's 180 s phase budget still queue the scatter.

**Veg overhaul (in progress — plan + full audit:
`~/.claude/plans/i-want-to-overhaul-scalable-biscuit.md`; Phases 0–2 landed).**
**Phase 2 style architecture:** `vegetation/veg_style_store.gd` (`VegStyleStore`)
is the ONE authority for user veg-style persistence — layered v2 JSON
(`{global, family:{pine…}, species:{spruce…}}`, files
`user://vegetation_style_v2.json` + `user://maps/vegetation_style_v2_*.json`),
holding ONLY explicit user edits; v1 files (flat cfg / species-defaults JSON /
per-map JSON) migrate one-way on first read, dropping values equal to
defaults(). Resolution precedence: **species override > user family edit >
catalog SPECS variant > defaults()**, enforced in
`VegSpeciesCatalog.settings_with_variant` via two side-channel keys the store
embeds in the flat merged dict (`_user_family_keys`, `_species_overrides`) —
this is what makes subspecies REAL (spruce/fir/birch dims + colors + white
bark from `VegetationCardFactory.SPECS` finally render; they were dead for
years because family keys always existed). `VegetationStyleConfig` remains the
facade (load_merged/save_global/save_map/save_species_default all delegate).
`VegetationLayer` v2 persists SPARSE settings deltas only (`user_settings()`);
the render path merges those over the store — never merge `get_settings()`
(complete dict) over the style, that is the shadowing bug Phase 2 removed.
`--headless --import` after touching these (VegStyleStore is a class_name).
Selftest: `vegetation/veg_style_store_selftest.gd` (precedence matrix,
migrations, layer sparse round-trip).
Invariants to preserve: `AutoVegetationRuntime.neutralized_settings` — the
per-species `*_bulk_scale` keys are FORCED neutral on the auto path (the
generator bakes height into each record's scale; letting the style's 1.6 win
oversized every auto tree) and `auto_tree_scale` (style key, clamp 0.2–3.0,
rebuild-only) is the one whole-forest size knob. `VegetationRuntime.reground`
MUST receive live settings + growth map (a bare rebuild was the "V pops full
detail" bug). All veg MMIs get `visibility_range_fade_mode = FADE_SELF` + a
24 m margin via `VegetationRuntime.apply_visibility_range` at BUILD time only
(AMD Vulkan hard-crashes on live visibility_range sweeps). Built meshes/
materials memoize in `VegAssetCache` keyed `kind|species|tier|hash(settings)`
(matches batch partitioning; `clear_foot_cache()` clears it too). Generator
scatter order is POINTS→ROWS→HEDGES→POLYS→GAP_FILL — explicitly mapped
features must never lose the budget race to polygon fill.
**Tree LOD (Overhaul v2 — `vegetation/veg_lod_policy.gd` +
`veg_impostor_baker.gd`/`veg_impostor_set.gd`/`veg_impostor.gdshader`):**
every tree chunk builds exactly TWO batches: the real 3D mesh inside a
CAMERA-based detail range (`tree_detail_distance_m`, per-quality-tier default
120/160/220/400 m, user slider in Tune-look Advanced) and the baked impostor
beyond it. The old SoI ring system and the large-map `auto_force_far_canopy`
flattening are GONE — force_far was why a 30 km map never rendered a real 3D
tree at ANY distance. Its prim-guard duty moved to `VegLodPolicy`: the loader
computes a budget-shrunk `tree_detail_eff_m` per rebuild (worst-case near-set
tree count over 256 m chunk neighbourhoods vs the tier's `tree_near_budget`
400/800/1500/4000, 60 m floor) and injects it via
`_auto_veg_runtime_settings`. Visibility ranges are BUILD-time only (AMD
Vulkan hard-crashes on live sweeps); the slider triggers the debounced
rebuild. Impostors are baked IN-PROCESS (no GLBs exist — meshes are
procedural): 8 yaw + 1 top view into a 1024² 3×3 atlas + a foliage-vs-bark
mask atlas, neutral-season materials, keyed by a STABLE content hash
(`bake_key` — excludes drape/growth/LOD keys, INCLUDES String values so an
archetype switch re-bakes), cached `user://veg_impostors/<key>.res`,
BAKE_VERSION-gated (now v7). Headless/selftests never bake: `cached_set`
misses fall back to the simplified crossed-card stand-in deterministically
(the flat branch-card fan is deleted); windowed bakes debounce ONE rebuild
via `_on_impostor_bake_completed`. The impostor shader is unshaded (day/night
from the env-sync uniforms), billboards manually in vertex (spatial shaders
have no billboard render_mode), and seasonally recolors/thins ONLY
mask-flagged foliage pixels. Selftest: `vegetation/veg_lod_policy_selftest.gd`.

**Seasonal phenology (Phase 6).** `SeasonModel.season_signals` now damps every
signal by ABSOLUTE latitude (`seasonality_strength`: 0 below ~15°, 1 by ~35°,
returned in the dict as `seasonality`) — inside the tropics day length barely
varies, so a mango at 5°N must never turn red; the SH half-year flip still runs
at full strength. `SeasonModel.estimate_winter_min_c(ws, lat)` samples the
coldest ~60 days (flipped south) off WeatherService and feeds
`VegSpeciesRegistry.species_allowed_at(id, lat, winter_min_c)` — cold-hardiness
now gates the auto mix alongside the latitude range, with NAN = "unknown, use
latitude only" so an offline session keeps its forest.
`vegetation/leaf_phenology.gdshaderinc` is the ONE leaf law shared by all three
canopy tiers (leaf shells / FAR cards / impostor): whole-leaf removal on a
WORLD-stable key at `(1-leaf_coverage)*deciduousness` (the cards used a
SCREEN-space dither that crawled with the camera; the shells shrank leaves to
nothing instead of dropping them), one per-tree autumn ramp, and winter
dormancy through the FOLIAGE MASK rather than deciduousness — so evergreen
needles grey off in the impostor tier the way they already did up close.
`VegLeafFall` (`vegetation/veg_leaf_fall.gd`, High/Ultra via
`RenderProfile.veg_profile()["leaf_fall"]`) hangs ≤6 GPUParticles3D emitters
over the nearest NEAR-ring deciduous chunks during the drop window; it SCANS
the built batch nodes on a 0.75 s tick rather than living inside them, so it
survives every veg rebuild. `VegLitterMask` rasterises the deciduous instances
into a coverage mask (resolution from the map extent — a fixed 256² over 30 km
is 117 m/texel and one street tree browned a 350 m circle) consumed by
`terrain_detail.gdshader`'s `litter_*` uniforms, pushed by terrain_loader with
the snow uniforms and change-gated. Selftest:
`vegetation/veg_phenology_selftest.gd`.

**Per-area fill (Phase 7).** Aim the crosshair at an OSM vegetation area and
Interact → the Fill drawer (`scenes/ui/veg_area_fill_ui.gd`, opened by
`terrain_loader.open_veg_area_modal`; its "Tune look…" button still reaches the
all-of-type edit via `open_veg_area_tune`). Fills are ADDITIVE edits stored in
`AutoVegetationEdits.fills` (VERSION 4) keyed by the area's metre-rounded
centroid tag, so they survive an OSM re-fetch that renumbers the polygon list;
`cleared`/`patches` stay subtractive and are still replayed after all scatter,
which is why `add_fill` LIFTS any clear over the same outline (otherwise the
clear would erase the forest just planted). One implementation does the work —
`AutoVegetationGenerator.apply_fill`, seeded PER FILL — called both by the
generator's new FILLS phase (last, after GAP_FILL: a player-authored fill is
the most explicit instruction on the map and may replace what scatter put
there) and by `terrain_loader.apply_area_fill` for the live edit, so a fill
looks identical before and after a reload. Density scales SPACING, not a count.
Loader API: `apply_area_fill(idx, {species, density, height_m, replace})`,
`area_fill_params(idx)`, `clear_area_fill(idx, clear_now)`,
`get_veg_area_info(idx)`. Fill AND clear re-mesh only the 256 m chunks the
outline touches (`AutoVegetationRuntime.rebuild_chunks` +
`VegetationRuntime.chunk_keys_for_polygon`, falling back to the whole-layer
rebuild when the incremental path can't apply). That path deliberately does NOT
clear shader registrations or the growth map: surviving chunks keep theirs, new
batches register themselves, and growth slots pointing at freed MultiMeshes are
dropped lazily on the next pass (the Phase 9 dedupe keys entries on species +
position, so re-registering a rebuilt chunk re-attaches to the same plants). The
chunk set comes from the polygon's AABB — a superset, since missing a chunk
would leave stale trees on screen, while a spare one costs only time. Verify
with `--capture=areafill` (above) plus the `_test_area_fill_*` and
`_test_incremental_chunk_rebuild` checks in `auto_vegetation_selftest.gd` (the
latter pins incremental == full-regen).

**V Select across both layers + Detect from the photo (2026-10-20).** The
painted layer and the OSM-generated forest are one thing to the V toolbar now.
- **Pick** (`VegTreePick`, pure): every non-grass plant of both layers is a
  vertical cylinder (ground → height, radius ≈ crown) in a lazy 16 m grid; the
  pick is the nearest one the SCREEN RAY passes through, culled behind the
  terrain hit. Rebuilt on a count/identity signature (`_veg_pick_rev` bumps
  for resizes). Loader: `veg_pick_at_screen` / `veg_pick_near` return a
  descriptor `{source: painted|auto, kind, slot, species (RESOLVED — an OSM
  slot can be an alias), index, x, z, height_m, crown_m, label, …}`; layers'
  `record_for(desc)` look up by **slot**, never by species.
- **Hover** (Select tool, 20 Hz): `VegHoverMarker` (rings + Label3D, no depth
  test) on the plant and the **species glow**: every batch carries meta
  `veg_species` (set at the five batch-construction sites in the two
  runtimes) and `set_veg_species_glow` sets the material uniform `veg_hl` on
  their MATERIALS (`veg_glow_materials_of`; VegAssetCache shares one per
  species look, so the whole species lights; declared in
  `veg_lighting.gdshaderinc`, applied in foliage / leaf_canopy / bark /
  impostor). No per-tree markers. ⚠ It was an `instance uniform` until
  2026-10-21: every object using one reserves 16 slots of the global shader
  buffer (4096 objects at the default size), Mount Vernon has more vegetation
  batches than that, and the engine logged ~3000 "Too many instances using
  shader instance variables" / "instance_buffer_pos" errors a session (they
  surface at whatever script line next flushes the renderer's dirty
  instances, e.g. a `free()` in ModelCatalog.instantiate). Do not add an
  instance uniform to any shader drawn by many objects.
- **Click** opens Tune look in **one-tree mode**
  (`open_vegetation_instance_editor` → modal `open_for_instance`; Shift+click
  only selects). Map-wide rows (shader, forest age, OSM binding, brush rows,
  type pickers, leaf/branch builder) hide; every shape edit is species-scoped
  (`_is_named_variant()` is true in this mode). Three scopes:
  - **This tree**: the strongest resolution layer,
    `VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE` (unprefixed species-override
    keys, applied after the whole ladder, never gated by the generic-family
    rule). Painted: on the record's `card_settings` (nested colours
    round-trip as arrays). OSM: `AutoVegetationEdits.add_tree_patch` — a
    0.3 m pin polygon replayed by the ordinary patch path after every
    regeneration (a later look REPLACES, resizes stack, a pinned clear
    deletes). Positions are deterministic, so a pin finds its tree again;
    a re-scatter that moves trees (density change) orphans pins harmlessly.
  - **This world**: `VegStyleStore.save_species_override_map`; flat_merged
    lists such species under `KEY_MAP_SPECIES` (only when non-empty — maps
    without one resolve byte-identically), which lets a GENERIC species'
    map entry beat that map's family edits.
  - **Every world**: the global species override, minus the same keys on
    this map's species entry. Both "all" scopes drop that species'
    per-tree looks in this world.
- One-tree mode's SIZE rows (height, crown, trunk, shrub card size) read the
  tree's real metres: a record's own `scale` (paint jitter, or OSM height ÷
  resolved height) multiplies the mesh, so the rows show stored × scale and
  edits store ÷ scale (`_inst_dim_scale`). The world/all scopes then scale
  that look to each tree's own size.
- ⚠ A partition group with its own look (per-tree look, brush snapshot)
  draws in the SAME chunk as its species-mates, so its batches carry a look
  tag (`VegetationRuntime.KEY_LOOK_TAG`, `Bulk_cedar_v2_l1_0_0_0`). Before
  that, the names collided and Godot renamed one `@MultiMeshInstance3D@N`,
  which every by-name lookup (chunk rebuilds, leaf fall, harness checks)
  silently missed.
- Del / [ ] work on OSM trees too (`delete_veg_plant` / `scale_veg_plant`,
  pinned); H stays painted-only. Vegetation undo already snapshots the OSM
  edits file.
- **Detect** (toolbar tool `veg_detect`, the SOAK scene's editor-only
  `VegetationScatter` bake made general — that one is untouched):
  `VegColorDetect` (pure) reads ONE drape per region (the finest covering it:
  site > hyper > detail > base, CPU copies ≤ 3072 px cached until the tool is
  put down), crops + box-filters it to the cell grid natively (a per-cell
  `get_pixel` loop cost seconds per preview), classifies by excess green
  (ExG, Woebbecke 1995) + a brightness cap with an **Otsu** cut per region;
  the cut is trusted only when the split is clean AND the class above it is
  green (mean ExG ≥ 0.07) — two-tone bare sand is bimodal too. 8-connected
  patches: up to "One plant up to" across → one plant at the centroid sized
  to the patch (below "Shrubs under" it is a shrub); bigger → canopy filled
  on a world-anchored jittered lattice at the species crown × 0.8 / density.
  The mask previews on the ground (terrain-following quad grid); Enter /
  "Plant them" adds PAINTED plants (editable, undoable), skipping roads,
  buildings, water and spots a plant already stands on. "Whole hi-res area"
  = the finest photo's square (where single plants are visible at all).

**Veg UI (Phase 8).** The V dock is on `UITheme` (panel/button/chip styles,
`LAYER_PANEL`; the Tune-look modal moved to its OWN CanvasLayer at
`LAYER_MODAL` — the two shared layer 25, so which drew on top came down to
sibling order). Every toggle button now has a real hover face; before this all
15 rendered hover identically to normal. A persistent **chip row** carries the
state that used to be implied or buried in a clipping status label: tool +
species (family-coloured swatch), density, brush radius or shape, size
variance, a **custom look** badge for the invisible per-brush override, the
locked selection's area, and the picked plant. `chip_specs()` is pure data so
the dock's visible state is assertable offline. **Tune look… no longer closes
on Apply** — it re-baselines and stays open, each `_values`-keyed slider gets a
per-slider revert (↺) plus an amber "changed since last apply" label, and the
Apply button counts pending edits. **Select + Brush is the per-tree tool**:
click picks ONE plant (`VegetationLayer.nearest_plant` → loader
`pick_plant_at`/`delete_plant_at`/`scale_plant_at`), Del deletes, `[`/`]`
resize, H promotes it to a hero GLB (the SPECIES picks the model and the card's
apparent height sets its scale, so a pine becomes a pine — placed before the
card is removed, so a hero-cap refusal leaves the plant standing); heroes are
pickable too and hero placement finally pushes an undo entry. The Tune-look
modal's ~32 per-species shape sliders are grouped into collapsible sections
(Size & form / Branches & clumps / Foliage / Growth / Detail & LOD) by a rule
derived from the KEY (`slider_section`), so a new slider files itself and the
selftest can assert every real key lands in a known section. **Top-down** mounts the survey drone and locks it to an ortho view via
the `vegetation_edit_ortho` meta the drone had always read but nothing ever
set; leaving the dock releases it. Drone WASD is gated while a LineEdit/SpinBox
holds focus (typing a brush radius used to fly the drone). The crosshair area
focus and the paint selection now own SEPARATE highlight meshes. Selftest:
`vegetation/veg_dock_state_selftest.gd`.

**Vegetation lighting + colour contract (2026-10-10).** Trees printed black or
flat beside the self-lit SoI soil for SEVEN stacked reasons; each fix guards a
trap that renders plausibly:
- **Tint is a COLOUR in the style, a MULTIPLIER in the shader.** Textures,
  shell `leaf_color` and bark are already painted in the SPECS `top`/`bark`
  colour, so `albedo_tint` = `VegetationCardFactory.tint_multiplier(picked,
  painted)` (white = 1). Passing the colour raw — and the old "tint defaults
  to spec.top" fallback, and the variant fill — squared it (maple leaf ≈
  linear 0.0007). `deciduous_albedo_tint` default is WHITE now.
  `VegStyleStore` drops near-black `*tint` values and the old dark deciduous
  default (`LEGACY_DECIDUOUS_DEFAULT_TINT`) on read (`is_black_tint`).
- **No manual back-face flip.** Godot already turns NORMAL to the camera on
  back faces under cull_disabled (probed); flipping again lit every back face
  from behind. Shared helpers in `vegetation/veg_lighting.gdshaderinc`
  (`VEG_BACK_FACE`, `veg_world_normal` — NORMAL is VIEW space in fragment()).
- **Palettes were authored as tints.** Conifer SPECS colours raised ~2.2× in
  sRGB (needle green ≈ 5–7 % linear); bark painted through
  `bark_paint_color` (≤1.8× for dark barks, none for birch/aspen) — the SAME
  colour is the tint reference and the variant `bark_albedo_tint` fill, or the
  multiplier undoes the gain.
- **Card foliage floors the sun's shadow** (`foliage.gdshader` custom
  `light()`, `shadow_floor` 0.45, directional only): a crossed-card crown is
  almost entirely in its own shadow map. BACKLIGHT is real transmission now
  (it used to be added to ALBEDO and multiplied by N·L ≈ 0).
- **Shade fill.** Global `veg_sky_fill` (Main `_push_veg_sky_fill`) =
  `VEG_SHADE_FILL` × DaylightModel sky_light × the share of ambient the
  player turned OFF (0 at the default multiplier); previews raise `veg_fill`
  and zero `veg_haze_mul` (`SoiService.set_preview_vegetation_look`).
  Shaders read `veg_fill_amount()` = max of the two. All `veg_*` globals are
  declared in project.godot `[shader_globals]` — never add at runtime
  (`global_shader_parameter_get_list` is editor-only; SoiService's guard used
  it and errored on every boot; it now asks ProjectSettings).
- **Photocards are photographs** (overcast, ≈ sRGB 0.19): `photocard_exposure`
  maps their mean opaque colour onto the species' painted `top` once per
  texture, stored as material meta `TINT_EXTRA_META` so live tint pushes keep
  it. **Hero GLBs** import with metallic leaves (free_tree_1 = 0.54);
  `HeroTreeCatalog.strip_night_glow` also makes them matte (cached dups).
- **The SoI shell draws LAST** (`soi_subsurface.gd` render_priority MAX):
  vegetation WAS `depth_prepass_alpha` (depth in the opaque pre-pass, colour in
  the transparent pass); the `depth_draw_always` glass sorting ahead of a tree
  rejected its colour pass → tree-shaped BLACK holes in the Globe lens and the
  snowglobe only. Found by hiding Main children one at a time with a forced
  `request_refresh()` — the preview does NOT redraw on visibility changes.
  **2026-10-18: the canopy shaders (`foliage`, `leaf_canopy`, `veg_impostor`)
  are ONE opaque pass now** — `ALPHA_SCISSOR_THRESHOLD` written beside
  `ALPHA`, the existing discard rules unchanged. The two-pass form was 24 of
  Mount Vernon's 31 GPU ms at half render scale (`gpu_toggle_bench`: canopy
  as scissor −9 ms at 8x MSAA, scissor + MSAA off 13.5 ms / 61 fps; MSAA 8x
  alone is 12 ms; alpha-to-coverage thins the shrubs away, so not that). The
  shell-last rule still stands; the trees simply no longer have a colour pass
  for the glass to reject.
Impostors: BAKE_VERSION 7 (side key light, ambient 0.5, `fix_alpha_edges`).
Verify with `--capture=tree` on mtvernon and a `site-review` with
`--review-sets=world,elevation,globe,snowglobe`.

**Procedural deciduous tree (space colonization).** The broadleaf skeleton is
grown by space colonization (Runions et al. 2007, `_build_branch_skeleton` in
vegetation_card_factory.gd): a deterministic attractor cloud fills the crown
envelope (`_sc_attractors` — profile from the ARCHETYPE table), limbs seeded
at `deciduous_primary_placements` (pure data, selftest-asserted) grow
step-by-step toward their nearest attractors and fork where the field
diverges; two Laplacian passes over pure chain links round the per-step kinks
(forks/seeds/tips pinned). SC tuning traps pinned by
`auto_vegetation_selftest`: step ≪ crown radius or the kill radius (1.05×step)
wipes crown regions before growth visits them; saturated nodes are SKIPPED in
the nearest search or their attractors starve and the loop stalls; momentum
can ratchet shoots past consumed attractors — hard-clamped to the envelope
(+6% ceiling / ×1.05 radial fence). NEAR trunk is a 7-sided tapered tube (UVs
ping-pong inside the bark texture's opaque CENTRE band — the margins are
transparent card silhouette and a full 0..1 wrap renders a cutout slab).
Foliage clumps cap the real tips (`_clusters_from_tips`) at BOTH tiers (the
stand-in runs the skeleton `emit=false`; the impostor atlas bakes FROM the
NEAR mesh); clump radius tiles the ENVELOPE volume share, clump centres
pre-fit inside the authored crown width, and the clump FLOOR is the authored
crown base (floored at 0 the canopy swallowed the trunk — bush balls).
leaf_canopy.gdshader stamps TWO interleaved size-jittered per-cell leaf
layers and keeps surviving leaves near-OPAQUE. **Bump
`VegImpostorBaker.BAKE_VERSION` on ANY change to this geometry** (now v7) or
cached impostors serve the old silhouette forever. Verify with
`--capture=tree` (pinned to July 15 so seasonal thinning can't fake or hide a
shape defect) and `--capture=veg`.

**v3 parameter model (Overhaul v2 — REAL UNITS + ARCHETYPES).** Tree families
are authored as: `<fam>_height_m` (total, EXACT — `_normalize_tree_surfaces`
rescales every surface so the built mesh hits it to the centimetre),
`<fam>_crown_width_m` (radial, pre-fit + normalized), `<fam>_trunk_diameter_cm`
(tube radius = cm/200, honest), `<fam>_crown_base_pct`, `<fam>_archetype`
(round/spreading/columnar/vase/weeping/conical), `<fam>_variant_seed` (0–9)
and four 0..1 character macros (branchiness/crookedness/droop/
foliage_density). `vegetation/veg_tree_archetypes.gd` maps archetype+macros
onto the SC builder's internal knobs at ONE choke point
(`_deciduous_adapter_settings`); the internal keys are derived, never
persisted. Advanced fine keys (leaf_*, whorl_*, fur_*) derive from the macros
unless the player explicitly sets them (`_derived_or_user` reads the store
provenance side channel, which `settings_with_variant` extends with
species-override keys). **One scale rule:** `species_bulk_scale` is hard 1.0
for trees; painted trees render at exactly the previewed size × paint jitter
(and plant MATURE — the dock "Plant young" toggle opts into seedlings); auto
records bake `scale = osm_height / resolved_height` at scatter (so
`deciduous_height_m`/`pine_height_m` changes are in `_GENERATOR_FLOAT_KEYS`
and trigger a re-scatter). `foot_local_y` is a constant 0 for trees.

**Fresh start (v3 stores).** `VegStyleStore` VERSION 3 lives in NEW files
(`vegetation_style_v3*.json`); legacy v1/v2 style files are never read
(in-place backup, deleted by the reset tooling), migrations gone.
`VegetationLayer` VERSION 3 keeps painted records/heroes/zones from ≤v2 files
but drops settings deltas and per-record card_settings; `create_empty()`
starts with EMPTY settings (it used to seed the full defaults dump as "user
deltas" — every fresh map then froze its defaults against later style edits).
Picking a subspecies in the dock no longer auto-attaches a card_settings
snapshot; `card_settings` is written ONLY by explicit "Apply to brush".
**Resets that work:** `invalidate_user_vegetation_edits` (was building
filenames from the combined "%.4f_%.4f" cache token — matched NOTHING) now
uses per-component `CoordToken.token()` and covers the v3 store + retired
sidecars; Terrain options gained "Reset map veg style" and "Reset ALL veg
styles" (loader `reset_map_veg_style`/`reset_all_veg_styles`).

**Tune-look WYSIWYG contract.** The preview builds from the SAME resolution
the render path uses: `_merged_settings` re-derives the VegStyleStore side
channels and applies the loader's `veg_quality_tier_style()` overlay under
the same only-fills-defaults rule; a headless PARITY selftest
(`_test_preview_parity` in auto_vegetation_selftest) builds the preview-path
and render-path meshes from one store state and asserts identical geometry.
Editing a NAMED subspecies routes edits (sliders AND the archetype dropdown)
to per-species overrides; sliders DISPLAY resolved per-species values.
`save_global_patch` PRUNES values equal to defaults();
`apply_vegetation_look` re-reads `flat_merged` after persisting. Modal
sections: Size (real-unit knobs + archetype dropdown + variant) / Character
(4 macros) / Foliage detail / Growth / Advanced (incl. the Detail distance
slider); colour rows Tint / Highlight / Bark; hover help via `SLIDER_TIPS`.

**Resolution ladder.** species override > user family edit > SPECS variant >
defaults, with: (1) a user FAMILY edit applies to named variants' numeric
dims as a RATIO over the family default (clamp 0.15–8; flat replacement made
every subspecies a clone on any tuned map) — the archetype string applies
directly; (2) a species-layer entry for a GENERIC family id is the WEAKEST
user layer (yields to any family edit). Selftests: veg_style_store,
vegetation_growth (`_test_settings_with_variant_non_clobber`).

**Harness write-discipline.** `--capture=vegdock` exercises the modal's Apply,
which persists global + per-map style — the harness snapshots the style files
(global/map v2 stores, layer JSON, species defaults, presets) and byte-restores
them after (`_snapshot_files`/`_restore_files`, same discipline as areafill).
Before this every vegdock run silently rewrote the player's saved looks.

**Growth — a pure function of the calendar, drawn on the GPU.** A plant is four
numbers: the growth-year it was born, its maturity age, its (individually
jittered) lifespan and a 0..1 seed. `VegGrowthModel.state(t, born, maturity,
lifespan, seed)` (pure static, `vegetation/veg_growth_model.gd`) returns
height / crown / girth / leaf / present / generation, and
`vegetation/veg_growth.gdshaderinc` is its LINE-FOR-LINE MIRROR: the batch
builders write `INSTANCE_CUSTOM = (born − 2000, maturity, lifespan, seed)` once
(`VegetationGrowth.custom_for`), transforms are written at FULL size, and the
only thing that changes as time passes is ONE uniform, `growth_year`
(`TerrainLoader._push_growth_year` → `VegetationEnvironmentSync.set_growth`).
Nothing ticks, nothing mutates a record, nothing is rebuilt; it scrubs
backwards and survives a reload. **What it replaced, so nobody restores it:** a
per-session growth clock + milestone ticks + `advance_generations` (kill and
reseed, mutating the record lists) + population caps + growth zones +
`VegetationInstanceMap` rewriting MultiMesh transforms on a frame budget + the
climelapse scale bake. Its painted trees were stamped at exactly clock − growth
span, i.e. AT their death age, so one milestone replaced a whole painted grove
with 0.14× seedlings in a frame (the Walton "all my trees shrank" report).
Rules that carry the design:
- **`maturity == 0` is the IDENTITY** — a plain `MeshInstance3D` reads
  `INSTANCE_CUSTOM = 0`, and the impostor baker, the Tune-look preview and
  `--capture=tree` all draw plain meshes. Likewise a settings dict with no
  `growth_year` means full size on the CPU side (every selftest relies on it).
- **The current year must NEVER enter the render settings dict.** Mesh and
  material caches and batch partitioning hash that dict; a value that moves
  with the clock would miss the cache on every rebuild. Only the static inputs
  go in (`growth_epoch_y`, `forest_age`, the `*_growth_years` keys).
- **Lifespan is never inside 1.25 × maturity** (`effective_lifespan`) — the old
  bug was exactly lifespan == maturity. Lifespans come from
  `species_catalog.json` `lifespan_years` (× 0.7–1.3 per plant); only the
  pine/deciduous families cycle, shrubs and grass grow and hold (`lifespan 0`).
- **All three curves are EXACTLY 1.0 at maturity** (Chapman-Richards height,
  crown = height^1.35, girth = height^1.6), which is what keeps "a painted tree
  is the previewed size" true. Girth alone creeps on to 1.2 through old age;
  `bark.gdshader` applies it inside `growth_trunk_radius` and crown width
  beyond, so branches still reach the foliage.
- **Painted records carry `born_y`** (VegetationLayer v4). Mature paint stamps a
  SEED-CHOSEN point on the full-size plateau (`established_born`) so one brush
  stroke dies decades-to-centuries apart; "Plant young" stamps now. Legacy
  `birth_h` migrates on load (`migrate_records`) but is NOT saved by loading —
  the next ordinary save persists it. Before `born` a plant is a seedling,
  never a previous generation.
- **The generated forest stores nothing**: birth is derived from the position
  hash and `forest_age` — `mature` is a STATIONARY uneven-aged stand (phase
  uniform over the whole cycle, births pushed ~2500 y back so no reachable date
  precedes them), `mixed`/`young` count from a per-map `growth_epoch_y`.
- **The growth year is not the date**: whole years tick with the calendar but
  the fraction follows the spring flush (flat in winter), damped to linear in
  the tropics and shifted half a year in the southern hemisphere so there is no
  jump at New Year. In August `growth_year` already reads the NEXT whole number.
- **Regeneration is advance regeneration, not bare ground.** A later
  generation rises out of the gap over 2–4 years as a released sapling and
  grows on from age `REGEN_HEAD_START` (0.15) × maturity — about a quarter of
  full height. Generation 0 (a plant set out young) still starts as a
  seedling. The first cut left the spot EMPTY for 2–8 years and restarted from
  a 3 % seedling, which put ~3 % of a generated forest missing and ~8 %
  visibly small at any date. What remains small is structural: the share of a
  life spent growing (maturity ÷ lifespan), so a long "Maturity age" on a
  short-lived species (53 y on an 80 y cottonwood) reads as a young stand.
  For scale: the OLD system's default "mature" profile drew 15 % of the
  generated forest under half size and only 8 % at full size.
- **Impostor snag.** The atlas is a bake in full leaf, so the stem behind the
  foliage was never drawn; `veg_impostor.gdshader` draws a tapered stem band
  procedurally where a declining tree's foliage has gone (`snag_*` uniforms,
  radius stamped per look by `VegImpostorBaker.stamp_snag`). ⚠ Keep it as ONE
  top-level `if (gone && stem < 0.5) discard;` — the first form nested the
  discard inside a second `if` and every HEALTHY impostor rendered as blocky
  fragments with no trunk, with no shader error; only `--capture=growth`'s
  impostor ladder showed it.
- Per-generation size (±8 %) and position (≤1 m) jitter is SHADER-ONLY and
  cosmetic; the CPU model reports sizes without it, and generation 0 — the
  plant the player placed — is exact. Seeds use linear sub-streams so CPU and
  GPU never have to agree on a chaotic hash.
- Grass and crops are NOT on this system (grass batches carry no instance
  data); `scale_for_lifecycle` / `growth_stage` on VegetationGrowth are the
  GROW BED's crop model and unrelated to the forest.
Verify with the growth selftest and `--capture=growth` (Validation list).

**Food forest → graph (Phase 10).** Adding an OSM vegetation area to the graph
(`terrain_loader.add_veg_area_plant_to_graph` → `add_imported_plant`) now
summarises the food-bearing trees ACTUALLY standing in that outline —
`VegFoodYield.summarize` over both veg layers, per-tree registry yields ×
maturity — and the bed becomes a `food_forest` plant node instead of the
generic annual-crop one. `ResourceFlowEngine._process_food_forest` takes its
own branch: rain-fed (an unwired water port is normal, not a fault), and a
whole year's yield delivered across the harvest window rather than trickled
hourly, so a food forest reads as a season. Outside the window the node idles
with "harvest in N d". Windows may WRAP the new year (an orange is doy 335→90),
which is why `in_window`/`window_days` exist rather than a `start <= doy <= end`
test. Maturity gates yield: nothing below half apparent size, ramping to full —
a freshly planted fill must not read as a working orchard. Verify with
`--capture=foodforest` (above) + `vegetation/veg_food_selftest.gd`.

**Pacific Northwest forest pass (2026-10-15).** Built from the player's
Mount Vernon reference photos (second-growth Douglas-fir / cedar / hemlock,
bigleaf maple and red alder turning gold, sword fern and blackberry, logging
stumps and mossy logs). Four pieces, each reusable on any map:
- **The Globe lens no longer drops whole chunks of trees.** Visibility range
  is measured to each 256 m chunk's AABB CENTRE, and the far (impostor /
  photocard) tier used to stop at the first-person cull end (480 m on large
  maps) while the Globe / snowglobe orbit up to 4.5 x the SoI radius out: the
  back of the sphere blinked in and out by chunk as the camera orbited. The
  far tier now ends at `VegLodPolicy.KEY_FAR_TIER_END` (`far_tier_end_m`,
  runtime-only, = R x 5.5 + chunk half-diagonal, from
  `TerrainLoader._impostor_reach_m`); a mesh-only chain keeps the cull end
  (that tier is the prim budget). An SoI radius change that moves the reach
  debounces one rebuild (`_on_soi_changed_for_veg`). The key is UNPREFIXED on
  purpose: the impostor bake key hashes family-prefixed keys only, so a
  radius change never re-bakes. The mesh/impostor handoff fade scales with
  distance (`VegLodPolicy.fade_margin_for`, 12 %, 24-140 m — one orbit zoom
  notch used to cross the fixed 24 m band), the impostor adds the lens
  `veg_fill` (the swap was a brightness jump in the lenses), and the lens
  re-captures 0.25 s after a veg rebuild (`_refresh_lens_after_veg_rebuild`;
  on-demand captures kept a mid-rebuild frame with species missing).
  ⚠ **A rebuild must DETACH old batches before queue_free**
  (`VegetationRuntime._clear_children`, `AutoVegetationRuntime`): a dying
  "Bulk_fir_…" left in the tree made the new one `@MultiMeshInstance3D@…`,
  which silently broke every lookup by batch name (`chunk_of_batch_node`
  for incremental chunk rebuilds, leaf fall, harness checks), and a dying
  AutoVegetation root was the one the next rebuild found and built into.
- **Species** `hemlock` (pine builder, drooping), `alder` (pale bark),
  `sword_fern` (the PALM builder with `fern: true` in SPECS — three upright /
  arching frond rings, no trunk, a full-width pinnae texture) and
  `blackberry` (shrub). Understory draws to
  `VegetationRuntime.UNDERSTORY_VISIBILITY_END` (220 m) and sits under the
  Shrub button (`VegSpeciesCatalog.UNDERSTORY_IDS`). The conifer whorl layout
  now honours `crown_base_pct` (above 20 %) and `droop` (above 0.12); every
  shipped SPECS conifer is below both, so the default layout is
  byte-identical (selftest-pinned); BAKE_VERSION 8. ⚠ A map's own pine-family
  droop edit outranks a species' SPECS droop — set droop per species.
- **Deadwood** (`VegDeadwood`, `vegetation/veg_deadwood.gd`): stumps (the
  player's imported GLBs, `deadwood_stump_models`, a COMMA STRING — the
  style store reads any JSON array of 3+ as a Color) and procedural mossy
  logs (`deadwood_log.gdshader`), derived from the standing tree records by
  a position hash, nothing stored; `deadwood_per_100_trees` (0 = off, the
  default), `deadwood_log_share`, `deadwood_visibility_m`. Logs lie between
  the ground under their ends and turn across a slope too steep to follow.
  A flat-painted stump model (no albedo texture — SketchUp paint) is drawn
  with `deadwood_stump.gdshader`; a textured one keeps its bark plus the
  `deadwood_moss.gdshader` overlay. Both find "up" from screen derivatives
  (imported stumps are often double-sided / inside out). Off roads and
  buildings via `TerrainLoader.veg_point_excluded_callable()` (built fresh —
  the camp tool's cached index can predate the OSM load; returned as a
  LAMBDA, since a Callable does not keep a RefCounted alive).
- **Look backups** (`VegLookBackup`): snapshot / list / restore of one
  world's style store + painted plants + area edits under
  `user://veg_look_backups/<hash of the resolved style path>/<stamp>/`; a
  restore deletes files that did not exist at snapshot time and snapshots
  "Before restore" first. Terrain options → "Earlier vegetation looks" →
  Restore this look (`TerrainLoader.snapshot_veg_look / veg_look_backups /
  restore_veg_look`). A fix that re-styles a world snapshots first.
- **Tune look is reachable from V now** (the unified toolbar's species row,
  opening on the painted species); it used to exist only on Shift+V and the
  Library. The modal took the legacy dock's brush (Shrub) over a caller's
  preset — a named preset or species now wins.
- Mount Vernon was converted by `tools/fixes/mtvernon_pnw_forest.gd`
  (persisted 2026-10-15; generic pine / spruce / redwood / deciduous records
  re-speciesed in patches, ferns round the trees, blackberry at thin-canopy
  edges, gold-orange autumn, the regional `local_mix` for when auto
  vegetation is switched on). Idempotent. Not done: understory for the
  GENERATED forest (the generator scatters no ferns; deadwood does read the
  auto records when auto vegetation is on).

**PNW pass, part 2 — the tree builder and the mix (2026-10-15).**
- **Conifers are built as a trunk plus foliage SPRAYS** (`VegConiferBuilder`,
  `vegetation/veg_conifer_builder.gd`), not whorls of cards. One `FORMS`
  entry per species says how it grows: crown profile and bulge, branch tilt
  at base and top, sag, upturned tips, branch spacing / per tier / whorled,
  spray width and cross ribbon, hanging pendants (cedar), bare lower limbs,
  gaps, a nodding leader (hemlock), trunk flare and fluting, needle
  texture. `spray_texture` paints the spray image per species (filled
  feather lobes + a needle fringe — 1 px needles vanish at any distance).
  Everything is clamped above the ground (`GROUND_CLEAR_M`; pendants and
  ribbon vertices too — cedar and hemlock skirts went under the soil).
  `VegetationCardFactory._build_pine_mesh` routes to it unless the style
  says `pine_builder: "whorl"` (the old builder, kept for that).
- **Real species, real sizes.** SPECS now carry PNW heights / crowns /
  trunks / colours: `douglas_fir` is its own species (42 m, corky bark);
  `fir` is the TRUE fir; plus cedar 35 m stringy, hemlock 32 m flaky with a
  nodding leader, spruce, pine plated, redwood, bigleaf maple 24 m vase,
  alder 22 m smooth; understory `bracken` (fern) and `salal` (shrub) join
  sword fern and blackberry.
- **Every tree species draws 3 seeded variants** (`tree_variants`, default
  3). `VegetationRuntime` splits each species' records by a position hash
  into variant batches (`<fam>_variant_index`, batch suffix `vK`); the
  seed folds the index in, so a stand never repeats one tree. Cost: up to
  3x the tree batches.
- **Bark** has styles (`bark_style` in SPECS: corky / stringy / flaky /
  plated / smooth, "" = the old texture) and **trunk moss**
  (`bark.gdshader` `moss_amount` / `moss_height_m`, 3-D value noise climbing
  from the ground on up-facing bark; amount = style `bark_moss` x the
  species' `moss_affinity` — maple 1.0, so maples go green, firs barely).
  ⚠ The bark reads the variant species from the INCOMING settings
  (`_variant_species`): `settings_with_variant("pine")` resets it.
- **Floor moss** (`VegFloorMoss`): a 2 m-texel mask of the canopy's
  footprint (max 1024 px) pushed to `terrain_detail.gdshader`
  (`moss_tex` / `moss_rect` / `moss_strength` / `moss_color`), blended
  under the leaf litter. Style `forest_floor_moss` (0 = off).
- **`VegMix`** (`vegetation/veg_mix.gd`) is ONE scatter for the brush and
  the preview: a mix = canopy weights + understory per tree + stand
  (spacing, patchiness via patch noise, patch size, share of young trees)
  + site extras (floor moss, trunk moss, deadwood). Presets `pnw_lowland`,
  `pnw_cedar_bottom`, `pnw_maple_alder`, `pnw_second_growth_fir`,
  `mixed_woodland`; saved mixes in `user://veg_mixes.json`. A map's own
  mix is style `paint_mix` (`TerrainLoader.get_paint_mix` /
  `set_paint_mix`, which also writes `local_mix` so the generated forest
  follows the canopy). Painting a mix (`populate_vegetation` with
  `params.mix` -> `_populate_mix`) runs the same `VegMix.scatter` the
  preview runs and RAISES (never lowers) the map's site extras.
- **V toolbar:** a **Plant scale** parameter (0.25-3x, multiplies on top
  of size variation) and, on the Mix family, a dropdown of "This map's
  mix" + presets + saved mixes (`veg_mix_id`, saved in toolbar prefs).
  Tune look... on the Mix family opens the mix page.
- **Tune look -> Mixed woodland** is the mix editor: load a preset / save
  as, canopy sliders (+ add a tree / remove), understory per tree, stand,
  and forest floor & bark. The preview is `VegMix.scatter` with the
  brush's density / size variation / plant scale (pulled from the toolbar),
  deadwood drawn, and a moss tint on the ground; a stats line gives trees
  / understory / trees per ha. Apply to map = `set_paint_mix`.
- BAKE_VERSION 9.
- Mount Vernon: `tools/fixes/mtvernon_pnw_forest_v2.gd` (persisted
  2026-10-15, snapshot "Before PNW v2 (tree builder)") removed the saved
  family dims (global and map) that ratio-scaled the new species (a 166 cm
  pine-family trunk made a 3.3 m spruce trunk), the map's per-species dims
  from the first pass, re-speciesed painted `fir` as `douglas_fir`, added
  salal + bracken, and set the PNW lowland mix as the map's mix. The GLOBAL
  edits touch every map; only the harness backup restores those.

**PNW pass, part 3 — broadleaf leaf sprays + Show vegetation (2026-10-15).**
- **Broadleaf crowns are leaf SPRAYS on the twigs** (`VegBroadleafBuilder`,
  `vegetation/veg_broadleaf_builder.gd`), not the lumpy leaf-shell
  ellipsoids ("blobby"). `_build_branch_skeleton` exports its whole node
  soup (`out_nodes`: pos / parent / depth / pipe-model `tipw` / y0 / y1 /
  env_r); `build_sprays` hangs one textured quad per spray along the outer
  twigs (weight by `tipw` vs the form's `shell`, scaffold limbs stay bare),
  fans the rest on the twig ends (`clump`), and sets each card a little OFF
  its twig so the volume between the skeleton's few-metre-apart twigs fills.
  No leaf below the authored crown base − 0.4 m. Count = crown shell area ×
  3 cards deep × `fill` × density (quality tier's leaf-shell count / 4 ×
  the foliage macro), 120..1800 sprays, ~1.7k–4.4k tris a tree.
  `deciduous_leaf_builder` "shells" (Tune look → Leaves) brings the old
  crowns back.
- **Per species** (`VegBroadleafBuilder.FORMS`): the leaf outline the
  texture draws (bigleaf maple's five-lobed palms, alder's toothed ovals,
  birch's small triangles, aspen rounds, cottonwood deltoids, Garry oak
  lobes, beech ellipses, chestnut lances, walnut / acacia compound leaves),
  real leaf size, spray length, how far leaves reach inward, how flat they
  face the sky, twig droop (birch hangs), clumping, silver undersides,
  gloss. `leaf_texture` draws one twig with side twiglets and the leaves to
  scale (256×160).
- ⚠ **Cutout textures need `VegBroadleafBuilder.finalize_cutout`** (also
  used by the conifer sprays now): transparent texels take the leaves' mean
  colour (Godot's mipmaps averaged in black — dark crown edges, and a
  near-black autumn maple at distance) and each mip's alpha is scaled to
  keep the level-0 coverage above the cut (Castano 2010). Without it small
  leaves average under the shader's 0.35-0.4 cut and a crown thins to bare
  wire as it moves away — what the first sprays looked like.
- **Foliage shader `spray_mode`** (opt-in, every other material unchanged):
  vertex COLOR.r = depth into the crown (AO + highlight), .g = height
  fraction (wind), .b = per-spray seed (leaf-fall key, so sprays drop
  unevenly instead of the same leaf of every card).
- **Species carry their own habit in SPECS**: `branchiness`, `crookedness`,
  `droop`, `foliage_density` (`_species_macro`: a family-wide edit SHIFTS
  the species value by its distance from the default, a per-species
  override wins), `bark_style`, and `autumn` = [warm, orange, hot]
  (`autumn_palette`: species override > SPECS > the style's own autumn_*;
  applied to the sprays, the shells and the impostors via `stamp_snag`).
  Real PNW numbers for maple (22 m, 17 m round crown, gold), red alder
  (dull green-brown autumn), black cottonwood (32 m), birch, aspen, beech,
  chestnut, walnut, apple, pear, olive. New species **`oak`** (Oregon
  white / Garry oak) in SPECS, the catalog JSON, MESH_FAMILY,
  DECIDUOUS_IDS, LABELS, growth slots and NOMINAL_CARD_H.
- Tune look: **Leaves** row (sprays / shells) and **Tree variants** (1-4,
  `tree_variants`, default 3, each variant its own batch — lower = cheaper).
  BAKE_VERSION 11 (10 here, 11 with the slider wiring below).
- **Terrain options → Show vegetation** (`TerrainLoader.set_show_vegetation`,
  `[terrain] show_vegetation`): hides the Vegetation / AutoVegetation /
  Deadwood / VegLeafFall roots, zeroes the floor moss and leaf litter, and
  hides placed props that are plants (`prop_is_plant`: catalog category /
  label / id whole words — tree, cedar, stump, vine, fern …; only props it
  hid are shown again). Visibility only: nothing is deleted or regenerated.
  The tick re-applies it every 0.5 s while hidden (an auto-veg rebuild makes
  a fresh root).
- Mount Vernon: `tools/fixes/mtvernon_broadleaf_v3.gd` (persisted
  2026-10-15, snapshot "Before broadleaf rebuild") removed the GLOBAL
  family/generic-species deciduous macros (branchiness 0.35, crookedness
  0.41, droop 0.14, foliage 0.72 — tuned for the shells; they would now
  shift every species off its habit). Offline probe:
  `tools/checks/broadleaf_probe.gd` (tris / size / ms per species + each
  leaf texture to user://broadleaf_probe/).

**Tune look = the world (2026-10-15, "what I see is not what I get").**
- ⚠ **The world resolved a species TWICE.** `VegetationRuntime._build_bulk_batch`
  (and the auto runtime) call `settings_with_variant`, then
  `mesh_for_canopy_lod` resolves again; Tune look resolved once. A family
  edit is a RATIO over the family default, so it was applied squared in the
  world: a 75 cm Pine-family trunk drew a Douglas-fir 400 cm thick in the
  world against 183 cm in the preview, and crown base compounded into its
  80 % clamp. `settings_with_variant` is now IDEMPOTENT: every key it
  rewrites goes through `put`, which records the replaced value under
  `KEY_RESOLVE_RAW` (`RESOLVE_ABSENT` = the key was missing); a dict that
  carries that record is restored first. Resolving twice == once, and
  re-resolving a Douglas-fir dict as spruce == resolving spruce from the
  style (pinned in `vegetation_growth_selftest`, plus "world mesh
  (pre-resolved) == preview mesh" for a conifer and a maple).
- **54 slider/species pairs did nothing.** The spray builders (the default
  for both families) never read the whorl-card / leaf-shell sliders. Wired
  now, each NEUTRAL at its default: conifers — Whorls (branch tiers against
  what branchiness derives, `whorl_default`), Whorl gap, Bough size (branch
  length), Jitter, Variation (azimuth irregularity), Crookedness (trunk lean
  + irregularity), Foliage (spray width), Trunk taper, Roundness; broadleaf —
  Leaf size (spray size), Clumps (twig-end bunching), Leaf density (only when
  the player set it, against the Foliage macro's derived value), Leaf layers,
  Roundness and AO on the spray material. `foliage.gdshader` spray mode
  takes roundness off crown depth (COLOR.r).
- Sliders the CURRENT builder ignores are hidden
  (`vegetation_preview_editor.builder_hidden_keys`): pine fur unless
  Branches = Whorl cards, leaf aspect / gap / lump / shadow proxy unless
  Leaves = shells. Conifers gained a **Branches** row (`pine_builder`
  "spray" / "whorl", default "spray" in `VegetationStyleConfig`); changing
  either builder rebuilds the slider list.
- Checks: `tools/checks/tune_look_slider_probe.gd` (offline: every shown
  shape + shader slider at min vs max must change the mesh or a material
  uniform, per species — 0 dead), and
  `tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tune_look_world_parity.gd`
  (the editor's own `_merged_settings` mesh against the meshes the world's
  near batches carry, per species).

**Vegetation paint + live preview (`scenes/ui/vegetation_edit_ui.gd`,
`scenes/ui/vegetation_preview_editor.gd`).** V toggles the bottom paint dock
(paint/place/clear/select, density, shape tools, Advanced per-species sliders).
**Tune look…** opens a modal with an isolated `SubViewport` studio (neutral ground +
fixed key/fill lights) showing a configurable-diameter preview patch filled via
`VegetationCardFactory`/`GrassBuilder` MultiMesh scatter; right sidebar has veg-type
dropdown, density, patch diameter, per-species shape sliders, tint, and shader knobs.
Live edits debounce ~0.1 s; **Apply to map** writes through
`terrain_loader.set_vegetation_settings` / `set_vegetation_style` (same persistence as
the dock). Per-tree layout knobs (Tune look + Advanced): pine `pine_whorl_count`,
`pine_bough_scale`, `pine_whorl_spacing` (whorls centered on trunk); deciduous
`deciduous_cluster_count/spread/size/tightness`, `deciduous_branch_count/thickness/reach/base`;
shrub `shrub_cluster_count/spread/size`. Style defaults + per-map JSON in `vegetation/vegetation_style_config.gd`.

**OSM → species binding (Tune look… modal "OSM → tree type" section).** The player
picks which shader species fills each OSM area kind: `wood`/`scrub`/`park`/`cemetery`/
`orchard`/`vineyard`/`wetland` → `auto` (biome) | `pine` | `deciduous` | `shrub` |
`mixed`. Stored as `style["osm_species_map"]` (kind→choice dict, JSON round-trips via
`VegetationStyleConfig`). `BiomePalette.MAPPABLE_KINDS` / `SPECIES_OVERRIDE_OPTIONS`
drive the UI; `BiomePalette.species_override_for_kind()` returns a weight dict (or {}
for auto) that `AutoVegetationGenerator._scatter_polygon` applies over the biome/tag
default (row crops use `override_single_species`). Changing the map requires a FULL
generator re-run — `terrain_loader._osm_species_map_changed` (inside
`_forest_params_changed`) triggers `_full_regenerate_auto_vegetation`. NOTE: a
format-string bug in `VegetationCardFactory._foot_settings_key` (12 specifiers vs 13
args) used to spam a runtime error on every scatter batch → slow, error-flooded veg
loads; fixed to 13 specifiers.
Card meshes + materials: `vegetation/vegetation_card_factory.gd` → `foliage.gdshader`
(canopy) + `bark.gdshader` (trunks); shared wind in `wind_vertex.gdshaderinc`.
Configurable realism uniforms (no extra texture fetches): `translucency_strength`,
`canopy_roundness`, `color_variation`, `foliage_roughness`, `ao_strength`,
`subsurface_strength`, `bark_roughness`, `bark_ao_strength`, `bark_color_jitter`.

**OSM water (`core/terrain/water_builder.gd` + `osm_water_parser.gd`).** WaterBuilder
now draws only STILL water (lake/pond/reservoir/wetland/bay/riverbank polygons —
one flat plane per body at a low percentile of bank heights, `terrain_water.gdshader`
+ per-lake ReflectionProbe), draped onto the EDITED surface (`ground_delta_fn` =
the loader's tile stack). Every waterway LINE (anything with a `centerline`) is
drawn by the WaterNetwork below. The parser keeps a waterway that a riverbank
polygon already covers (flagged `covered`, carved but not drawn) and tags
`tunnel=culvert`/`covered`/negative `layer` reaches `culvert`; items carry
`osm_id`. ⚠ The OSM cache stays **v6** on purpose — a version bump forces an
Overpass refetch for every visited site, and Overpass 504s (the site then loads
with NO buildings). Caches written before the waterway keys existed are read
back by `BuildingService._derive_centerline` (centre = midpoint of the buffered
ribbon's mirrored bank points) with a pseudo `osm_id` ≥ 9e11.

**Water on the land (`core/water/` — the WaterNetwork; plan
`~/.claude/plans/on-maps-with-significant-smooth-castle.md`).** OSM waterways +
the player's streams are ONE system: resolved, carved into the terrain, drawn
level in their channels, analysed for drainage, editable with waypoints, and
wired into the graph. `WaterNetwork` is TerrainLoader's child "WaterNetwork";
it only ever writes the procedural CHANNEL tile layer.
- **Delta stack** (terrain_loader): `_edit_tiles` = the PLAYER layer (sculpt,
  undo, `terrain_tiles_*.bin`), `_channel_tiles` = procedural channels (never in
  player undo; cached as `channel_tiles_<lat>_<lon>.bin` + `.json` signatures),
  `_composed_tiles` = their per-tile sum, which the HeightField renders (its
  `pre_consume` hook composes whatever either layer dirtied, so every existing
  queue/reconcile site works unchanged) and the DetailGround sink reads (now a
  tile-KEY set, not a rect list — channels activate ~150–200 tiles).
  `_ground_height_at` sums both layers directly. Channels are carved only inside
  the hi-res patch (minus `ChannelCarver.PATCH_MARGIN_M`); the coarse Ground is
  never sunk. Tile meshes now come from `TerrainEditTiles.build_tile_mesh_data`
  (one height pass for mesh + collider, ~5× fewer base samples) and each quad
  splits along its min-height-difference diagonal (a fixed split drew every
  diagonal channel as a sawtooth).
- **Model**: `WaterFeatureLayer` (`water_features_<lat>_<lon>.json`: player
  streams in DOWNSTREAM order with per-span modes surface|culvert|pipe, sparse
  OSM overrides keyed by way id, map settings) → `StreamNetwork.resolve` →
  features `{id: "osm:<id>"|"ws_<n>", points, modes, section{bed_w, depth,
  bank_slope, max_cut}, carve, base_lps, covered}`. Only a MAPPED `width` tag
  sizes the bed (the parser's 10 m default "stream" width is a render default —
  carving it made 7 m trenches holding 2 cm of water). Beds are sized for
  bankfull, so base flow sits over a flat bed with its own smooth edge.
- **Curves** (`StreamCurve`, pure, 2026-10-21): a feature's waypoints are
  CONTROL points (`ctrl_points` / `ctrl_modes`); `points` / `modes` are the
  centreline made from them, which everything downstream (profile, carve,
  surface, tracers, drainage links, intakes) uses. Two knobs, each 0..1, map-wide
  (`settings.curve_smooth` / `curve_meander`, View tool) or per stream (`smooth`
  / `meander` on the stream record or OSM override, Edit tool, "Use map curve"
  drops them): Smoothing = centripetal Catmull-Rom through the waypoints mixed
  with the polyline; Meander = a sine-generated curve (Langbein & Leopold 1966,
  Kinoshita skew), ω = meander × 2.0 rad (per-wave ω capped at 2.1 — past ~2.2
  it crosses itself), valley wavelength 11 bankfull widths, each wave its own
  length / swing from the id's hash, every wave closed back onto the valley
  line, lateral offset pinned to 0 at the ends, at tributary junctions and
  across culvert / pipe / penstock spans. Both 0 = the waypoint line exactly (no
  re-carve for old worlds). `apply_curves` finds links on the WAYPOINT lines,
  then snaps each tributary's end onto the curved channel it joins.
  `ctrl_seg` (centreline span → waypoint span) and `ctrl_vtx` (waypoint →
  centreline index) are how the editor, the Site Plan stream drop
  (`StreamNetwork.ctrl_span_of`) and the penstock tap
  (`centreline_between`) translate. Full meander roughly doubles a channel's
  length and swings ~1 wavelength either side of the mapped line.
- **Profile** (`ChannelProfile`): smoothed ground − depth, clamped under the
  LOWER BANK (`bank_offset_m` — mapped streams run on valley sides the DEM
  smeared), then a running MINIMUM downstream with a 0.0005 grade
  (Priority-Flood+ε in 1-D): every bed is monotone. A cut past `max_cut` is held
  and the station flagged `blocked` (editor paints it red). Features are
  profiled outlets-first; a tributary is floored at the bed it joins, but never
  lifted above its own ground (that floated the water).
- **Carve** (`ChannelCarver`, WorkerThreadPool, pure): per-segment trapezoid
  sweep with a C1-rounded toe (`TOE_ROUND_M`) and a soft-min lip
  (`soft_cut`) — sharp creases alias on the 1.5 m grid; min over segments
  (channels union); only lowers. Interior joints sweep their end-caps ONLY in
  the outer-bend wedge — a round cap carries the downstream (lower) bed back up
  the channel and terraced every steep reach. Incremental by per-feature
  signature + footprint; Mt Vernon (32 waterways) carves in ~1 s.
- **Surface** (`StreamMeshBuilder` + `stream_water.gdshader`): stations every
  2 m × 7 across, LEVEL across each station at bed + Manning normal depth
  (`StreamHydraulics`, Chow 1959) on carved stations, draped elsewhere; culvert
  spans emit nothing. The shader reads the depth texture for the water column
  (absorption, soft shoreline, lap foam only near the strip edge), two-phase
  flow-mapped ripples, and white water only where Froude > 1 AND the water is
  deep enough to tumble. Q = base + rational-method runoff (C 0.25) of rain at
  the CLOCK (`WeatherService.rain_rate_mmh`) on each station's catchment — a pure
  function of time, scrub-safe.
- **Rain reaching the streams** (`StreamRunoff`, pure, 2026-10-21): the
  discharge the surfaces, beads and readouts show is `station_q_now`: base flow
  plus the rational-method hydrograph of the weather's rain (the mean rate over
  each station's time of concentration, Kirpich 1940 on Hack's-law length, from
  a 5-min rain history) plus every Rain-tool STORM. A storm
  (`WaterNetwork.add_storm(poly, mm/h, start_h, end_h)`) is the toolbar's Rain
  held over ground that is not a pond (no closed basin, or a hollow under 20 %
  of the selection): its patch is accumulated down the drainage grid
  (`weighted_accumulate`) to the stations it feeds, enters each channel at one
  station and TRAVELS from there (`channel_travel_h`: Σ ds / Manning v — never a
  difference of Tc, which jumps where a side catchment joins and made the water
  skip ahead with dry gaps), rising over the patch's own Tc and spreading 0.3 ×
  the lag, volume conserved. Everything is a function of the clock (storms are
  kept for the session, newest 64), so it scrubs. Rain streaks fall over a storm
  while the clock is inside it. `station_q_lps(f, i, rain)` is still the
  instantaneous form the graph's intakes use. "Dry between storms" (View tool,
  `settings.dry_between_storms`) drops the kind's default base flow so a desert
  wash carries nothing until rain reaches it. The poll remeshes when any of 9
  sample stations per channel changes by 12 % or wets / dries (every 0.5 s
  while water is moving). Verify: `tools/checks/stream_storm_check.gd`.
  The storm PULSE (`storm_arrival_mean`): nothing runs off until the first
  `INITIAL_LOSS_MM` (3 mm, SCS initial abstraction) has fallen — the delay —
  then a linear reservoir (Clark / Zoch) with K = the patch's Tc + 0.3 × the
  travel time: a smooth rise and an exponential tail after the rain.
- **Basins along a stream** (`StreamBasins`, 2026-10-21): on the EDITED
  ground along each carved channel, a 1-D Priority-Flood
  (`level[i] = max(ground[i], level[i+1])`) finds stretches the water must
  rise through; each is flood-filled in 2-D at 1.5 m below its spill height
  (with a DAM across the channel at the spill station — without it the fill
  runs on down the channel, which is lower, and every hollow reads as open;
  an `open` hollow is not a basin). `_q_at(f, i, tau)` is the ONE discharge
  function: sources (base, weather slices, storms) are held back by every
  basin between them and the station until that basin was full when the
  water passed it; inside a basin no stream is drawn. Each basin's water is a
  2-min balance over the last 24 h (inflow above it − 8 mm/h infiltration
  over the wetted area, clamped: fill-and-spill), recomputed as the clock
  moves, its surface meshed flat at the level (`StreamBasins` node). Found in
  `_update_station_areas` (after every carve / drainage pass, so a sculpt
  shows up once drainage reruns). Verify: `tools/checks/stream_basin_check.gd`.
- **Erosion** (`StreamHydraulics.bed_shear_pa` / `erosion_rate_mps`,
  excess-shear model, k_d 2e-6 m³/(N·s), τc 4 Pa): while the clock runs
  FORWARD (steps ≤ 1 h; a scrub or jump erodes nothing) every carved open
  station lowers at k_d (τ − τc); the cut lives in
  `WaterFeatureLayer.erosion[fid]` (10 m bins, saved with the map, capped at
  2.5 m), `ChannelProfile.compute(..., erosion)` adds it to the depth and the
  carver re-carves every 5 cm (≥ 10 s apart, the rest flushed when the flood
  ends). A 15-min 60 mm/h shower cuts ~1 cm; an hour at 100 mm/h over 50 ha
  cut 0.40 m on Bombay Beach. View tool: Reset erosion. Verify:
  `tools/checks/stream_erosion_check.gd`.
- **Rain at speed stays smooth (perf pass 2026-10-22).** At 600x in a storm
  the stream system froze the game for 1.1–1.3 s every 3 s (p95 1248 ms) —
  the likely cause of the reported "black flash", which never showed up in
  any rendered frame. Now ~24 ms steady at 1440x. What carries it:
  - An EROSION re-carve takes a LIGHT path (`_apply_job_result`,
    `erosion_only`): only props on the touched tiles are re-grounded
    (`on_channels_carved(touched, true)`), the station hydraulics are
    re-derived from the existing areas (`_update_station_hydraulics`, no
    catchment pass), no drainage rerun, the channel cache is saved at most
    every 30 s, and the changed streams re-mesh on a worker.
  - The flow re-mesh the poll asks for runs on a WORKER
    (`_start_async_remesh` → static `_remesh_job` → `_process_remesh`): q is
    summed on the main thread, states + strip arrays off it from per-feature
    caches (`_bank_refs`, `_drape_refs`, `_surf_masks`, `_surf_arrays`); a
    result whose `_rev`/`_surf_gen` moved is re-queued, never applied.
    `StreamMeshBuilder.feature_arrays` builds packed arrays directly (no
    SurfaceTool, UP normals) and with no ground Callable uses the bank tops
    and the drape cache.
  - `StreamNetwork.surface_mask` replaces per-station `mode_at` (one pass);
    `StreamHydraulics.normal_depth_m` is Illinois regula falsi, not a
    48-step bisection; `feature_states_now` is vectorised per feature.
  - Storm areas: `StreamRunoff.sparse_accumulate` walks only the sources'
    downstream closure in rank order (bit-identical to the dense pass over
    409k cells; pinned in water_features_selftest).
  - `rebuild_buried` is signature-gated and `_update_buried_flow` only
    re-tints; the basin mesh rebuilds on its own show signature.
  - Terrain tiles: `build_tile_mesh_data` reuses the base heights
    (`TerrainHeightField._base_cache`, 5 probe points check them) and the
    rebuild loop is TIME-budgeted (`REBUILD_BUDGET_MS` 6, was 4 tiles a frame
    ≈ 105 ms).
  - Still rare and large: the DetailGround sink rebuild when the SET of
    carved tiles changes (~240–330 ms), and drainage + find_basins after a
    player edit (~380 + 260 ms). PerfMonitor `last_frame` holds the last
    frame's unsmoothed section times for the bench's slow-frame breakdowns.
  - Bench: `tools/bench/stream_rain_bench.gd` (Validation list).
- **Drainage** (`FlowRouting`, worker): burn mapped lines 4 m, Priority-Flood+ε
  (Barnes 2014) with a binary heap, D8, accumulation in reverse pop order,
  Strahler channels, RDP. 597² @ 5 m in ~4 s. Gives every station its catchment
  area, the Trace tool's path, and the derived network (channels that duplicate
  a feature are dropped — ⚠ a PackedVector2Array fetched from a Dictionary is a
  copy-on-write value; appending to it in place silently filled nothing).
- **Underground** (`BuriedWaterBuilder`): culvert/pipe runs follow the bed;
  auto-size = smallest standard pipe whose Manning full-barrel capacity (n 0.012)
  passes the 25 mm/h design discharge; SURCHARGED / shallow-cover flags in the
  readout. Barrels use the conduit flow material (X-RAY), so `WaterBuried` is
  hidden in first person unless "Show buried" or a graph lens is up (the graph's
  `_on_soi_preview_active_changed` pushes `set_preview_visibility`); headwalls +
  `ConduitDischargeVfx` outlet jets are always drawn.
- **Flow view** (display mode "flow"): `StreamTracers` beads at each stream's
  Manning velocity on the cosmetic clock (`SimFxRate` lights track — frozen
  when paused), the drainage overlay, and a site-outflow chip.
- **Editing** (toolbar WATER section → `scenes/ui/toolbar/water_tool_controller.gd`,
  preloaded, delegated to from edit_toolbar_ui): Trace / Draw / Edit (Light-Studio
  pin contract: press arms, drag past 6 px, release = ONE undo step; drag a line
  to insert a waypoint, Del removes the hovered one or deletes/hides the stream,
  Ctrl-drag moves it all) / Culvert (span modes) / View. Picking is screen-space
  against projected waypoints (pins) and the projected CENTRELINE (line clicks,
  mapped back to the waypoint span); a curved stream draws its waypoint polygon
  dashed under the pins and re-curves live while a pin is dragged. Undo = layer
  snapshots in the network (the carve regenerates from the layer).
- **Graph link**: the flow engine asks its host `water_feature_supply_for_intake`
  — an intake within 6 m of a stream takes that stream's discharge (supply 0.0
  is still DRY, the supply_lps contract) and its seasonal curve; streams ending
  in a pond on the graph credit that tank (`stream_pond_inflows`, headroom-capped).
- `.esim` packages carry `water_features` (not the channel tiles).
- **Carved tiles must look like the ground around them** (fixed 2026-10-21 on
  Bombay Beach, where every channel tile read as a slab hovering on a ledge
  with a dark staircase along its edges). Two causes, neither of them height —
  the edges meet the DetailGround within 6 cm: (1) the DetailGround's normals
  were generated from its SUNK grid, so every vertex on a tile's edge leaned
  toward the hidden 60 m drop and the ground beside the tiles shaded as a cliff
  (orange toward a low sun, dark blue away). `TerrainBuilder.build_mesh` takes
  `shade_elev` and `_rebuild_detail_patch` passes the unsunk grid. (2) a ≥ 3 km
  patch turns the DetailGround's shadows off, but the tiles still cast, so
  under a low sun a 15–20 m shadow texel spilled off each tile edge onto ground
  that casts none (`TerrainHeightField.set_cast_shadow`, synced by
  `_sync_height_field_shadows`). `tools/checks/channel_tile_seam_probe.gd`
  measures both; `channel_tile_seam_shots.gd` is the sunrise A/B.
⚠ `SystemGraphView._input` used to handle Delete / Ctrl+Z / Ctrl+Y even with the
graph CLOSED — it runs before every `_unhandled_input`, so it ate those keys
from the 3D tools (edit toolbar, Light Studio). They are gated on `visible` now.
⚠ The Bash tool collapses `\\` even inside a quoted heredoc: write any script
or spec containing backslashes with the Write tool (an earlier session's
line-continuations ended up joined onto one line with stray tabs).

**Terrain sculpting (T dock — the rebuilt terrain builder).** ONE edit substrate:
`core/terrain/terrain_edit_tiles.gd` (`TerrainEditTiles`) — sparse per-vertex
height DELTAS at 1.5 m/cell in 64-cell tiles allocated only where edited, with
region-scoped undo sessions + binary persistence (`user://maps/terrain_tiles_*`).
Ops in `core/terrain/terrain_sculpt_ops.gd` (raise/lower/smooth/flatten brushes,
`level_polygon`, `ramp`, `carve_basin`). `ramp` (2026-10-21) is a straight
graded strip: a flat top `width_m` wide running from the ground at one click to
the other plus `height_m` (+ berm, − channel, 0 a road across a slope), sides at
`side_run`:1 that cut where the ground is higher and fill where it is lower
until they meet it (rounded toe, rounded ends; a side that cannot daylight
within 120 m eases back to the ground); toolbar params Top width / Height /
Side slope 1:; loader commands `brush_stamp` /
`level_region_command` / `ramp_command` / `pond_command` (carve + optional seed puddle;
water folded into the SAME undo entry as the carve). **Rendering is an overlay,
NOT a bake**: the detail DEM mesh is far too coarse (~12–47 m/vertex) to show a
1.5 m edit — `core/terrain/terrain_height_field.gd` (`TerrainHeightField`, node
"HeightField" under Terrain) renders each edited tile as its own hi-res mesh +
`HeightMapShape3D` collider (base_fn returns WORLD Y — no second centring), dirty
tiles re-mesh live during a drag (budgeted; `reconcile_dirty_now()` drains fully on
commit/undo BEFORE the sink refresh so actors never lose footing). The coarse
DetailGround mesh+collider are SUNK `TILE_SINK_HEADROOM_M` (60 m) beneath the
interior of active tiles (`_detail_mesh_grid_with_sink`; boundary ring follows the
local cut) so cut bowls/ponds are neither occluded nor bridged — tile skirts
(`SKIRT_DROP_M` 65 m, must exceed the sink; selftest-pinned) seal the chasm at
cut boundaries. Footing: `_ground_height_at = composed DEM + tile delta`; commits
call `_reseat_actors_after_edit(touched_keys)` — scoped to the committed tiles
(an actor outside every touched tile is never moved) and lift only when the
FEET are genuinely below the new surface (`pos.y < gy - 0.05`, small lift, keep
horizontal velocity; the player origin is at the capsule bottom, so the old
`< gy + 0.1` test fired on every commit and launched a grounded player 2 m up —
the "player pops on brush release" bug). Lowering lets gravity work. Tile meshes share DetailGround's drape material (re-pointed via
`set_material` whenever imagery lands). Legacy coarse/detail delta grids +
earthworks migrate one-time into tiles (`_migrate_legacy_edits_to_tiles`).
Validate with the `--sculpt-test` harness (above) + terrain_selftest.

**Unified edit toolbar (`scenes/ui/toolbar/`) — T / V.** One Photoshop-style
surface for BOTH tool sets: a vertical tool strip on the left (TERRAIN: Raise /
Lower / Smooth / Level / Ramp / Pond / Rain / Drain / Measure; VEGETATION:
Paint / Place / Clear / Select) plus a slim options bar across the top carrying
the ACTIVE tool's parameters, its shape picker, the species picker, live
ground/basin readouts and Undo. It exists to fix three things the two legacy
docks could not: they locked out navigation, they shared one global
radius/strength/hardness across every tool, and getting the camera back took
Esc THEN Space. The old docks are untouched and still reachable on **Shift+T /
Shift+V** until they are retired.

**It is NOT a modal — it runs in CursorController's TOOL OVERLAY tier**
(`request_tool_overlay` / `release_tool_overlay` / `has_tool_overlay` /
`overlay_look_active` / `tool_overlay_movement_active`). `should_capture_look()`
excludes the overlay, so every downstream consumer (crosshair, interaction
focus, grab controller) correctly treats it as "not capturing", while the actual
mouse-capture decision is `should_capture_look() OR overlay_look_active()` in
BOTH `_apply_capture_deferred` and the diagnostic `_wanted_mode` — keep those
two in sync or the reconcile warns every quarter second. `player.gd` gained
exactly three additive branches: RMB edge tracking + an overlay-look motion
branch in `_input`, `tool_overlay_movement_active()` in the movement gate
(guarded by a SpinBox-aware `_keyboard_captured_by_ui()` so typing a brush
radius does not walk the player), and a `has_tool_overlay()` guard around
tool-use — **that last one is mandatory: tool use fires on raw LMB, so without
it every paint stroke sprays the fire extinguisher.** Because the overlay never
touches the pause latch, ONE Esc returns full control. And because it is not a
blocking modal, `InputGuard` stays open and terrain_loader's key dispatch stays
live while it is open, which is how T/V toggle it closed (the legacy docks
cannot — their modal claim eats their own hotkey).

**Per-tool parameters are the headline fix.** `EditToolbarState`
(`toolbar_state.gd`, pure data) holds a params dict PER TOOL seeded from a
schema, plus per-tool shape memory and the shared veg brush identity
(family / subspecies / hero preset). `option_specs()` is the row model the
options bar renders from. Persisted to `user://toolbar_prefs.cfg` via
`save_to`/`load_from` (file I/O lives on the model so the selftest can
round-trip a TEMP path), loaded in `_ready` BEFORE the strip is built, written
on a 1 s debounce and flushed immediately on close.

Traps worth keeping: `VEG_FAMILIES` stores `VegetationPaint.Preset` values as
LITERAL ints so the model still loads with a stale class cache — the selftest
asserts they still match the enum, because a reorder would silently paint the
wrong family everywhere. `set_veg_family` resets the subspecies only on a REAL
family change (membership belongs to the species catalog; a name-prefix guess
wrongly cleared spruce, which is a pine). T/V go through `toggle_section`, which
SWITCHES sections when the toolbar is already open on the other one rather than
closing. A section opens on the tool last used in it
(`last_tool_by_section`), and V with the toolbar CLOSED reopens it exactly where
it was closed (`reopen_tool`, any section — a Water Edit session comes back as
Water Edit with its stream still picked); both persist in toolbar_prefs.cfg. There is no fullscreen capture rect — the two panels stop mouse events
over themselves and everything else arrives via `_unhandled_input`, which is
what lets RMB reach the player. ⚠ So ANY visible Control with the default
STOP filter swallows the world clicks under it: the legacy `TimeUI` root (a
430 px column down the right) and `HAConnectionUI` root (445 × 490 bottom-left)
did, with nothing drawn, until 2026-10-21 (both now MOUSE_FILTER_IGNORE).
`tools/checks/toolbar_input_probe.gd` lists every Control under a grid of
points with the toolbar open; run it after adding a full-size UI root. **RMB deliberately does NOT close a polygon or
cancel a shape** (it is the look button); polygons close with Enter or by
clicking the first vertex. Options rows are rebuilt per tool switch with the
dying rows DETACHED before `queue_free`, or the container measures both sets for
a frame and the bar visibly doubles in width. Selftest:
`scenes/ui/toolbar/toolbar_selftest.gd` (312 checks, in the Validation list).

**Painted camp areas (`core/camps/`) — the toolbar's CAMPS section, C.** The
player paints or draws where a festival camps and the area fills with tents,
shade and vehicles. Four tools: **Camp** (brush / circle / rect / lasso /
polygon), **Erase**, **Plots** (draw a zone → plots with lanes, each plot its
own camp) and **Edit** (click a camp: style, density, heading, name, reseed,
Del). Saved per map in `user://maps/camp_areas_<lat>_<lon>.json`
(`CampAreaLayer`); nothing about the tents is stored — `CampLayoutGenerator`
rebuilds them from the record.

It exists because the street-following `BrcCampGenerator` only works on Black
Rock City: it places a structure only within `plot_depth` of an OSM street (a
polygon over a field got ZERO), always excludes an 804 m "playa" disc at the map
origin, saves nothing, and puts a 9 m RV and a 2 m tent on the same 6 m grid.
**That generator, its auto-generate-on-load and its dock are deliberately left
unchanged** (the dock moved to **Shift+C**, action `camp_scatter_legacy`); the
two systems render into different nodes and do not know about each other.

- **Households, not props.** `CampStyles.TEMPLATES` are units — RV + awning +
  car, tents round a canopy — in a household frame; a STYLE is a lattice cell
  plus a weighted template mix. Every template must fit its style's cell
  (selftest-asserted): that is what makes neighbouring households independent.
- **The lattice is anchored to the WORLD and seeded per cell**
  (`hash(seed, i, row)`), never from a running RNG, and every random draw for a
  cell happens whether or not the household survives. A household therefore
  depends only on (seed, heading, style, density, cell) — so brushing a camp
  bigger adds households and moves nothing already standing. `paint` grows a
  same-style camp in place (keeping id / seed / heading) for the same reason,
  and the loader resolves an auto heading ONCE at creation and stores it, or the
  next stroke would swing every tent to a new longest edge.
- **Plots are the exception**: a record with a `group_id` fits its lattice to
  its OWN extent (no inner lane, cells stretched to share the slack). On the
  world lattice a 30 x 22 m plot wasted most of itself on straddled cells.
- **Alignment.** `ALIGNED` classes (vehicles, rigid shade) take the camp heading
  or its reverse — one choice per ROW — plus uniform +/- `align_jitter_deg`
  (default 5). Tents are `LOOSE` (+/- 25), domes `FREE`. `heading_deg` is a
  compass bearing folded to 0..180 (an axis has no front); auto = the nearest
  road within 40 m, else the outline's longest edge.
- **Footprints are real**: oriented-rect SAT against everything placed, corners
  inside the outline with a 0.75 m margin, outside holes, off buildings / roads /
  water (`VegExclusionBuilder`, cached in `_camp_excl_index` until the next
  attach), and under a slope limit (vehicles 10 deg and they tilt with the
  ground; tents 18 deg and stay plumb). Heights come from `_ground_height_at`,
  which includes sculpt edits — the legacy path reads the raw grid.
- **One node per camp** (`PaintedCamps/Area_<id>`), so an edit rebuilds one
  camp and each culls on its own; GLB classes draw the art to 220 m (padded by
  the batch radius — ranges are measured to the batch, not the instance) and a
  tinted proxy beyond; ONE glow batch + `CampLightPool` for all camps.
  ⚠ The root is `PaintedCamps`, never `Camps*`: `_remove_existing_camps()` frees
  every Terrain child whose name begins with "Camps".
- `CampMeshLibrary` normalises each GLB (recentred, stood on y = 0, long axis
  onto +X, scaled to the class's nominal length) so the footprint reserved is
  the footprint drawn. The pop-up canopy GLB is deliberately unused — one black
  model repeated reads as a car park; the tinted shape takes a per-camp colour.
- Toolbar: `CAMP_STYLES` in `toolbar_state.gd` is a LITERAL copy of
  `CampStyles` ids (stale-class-cache rule, same as `VEG_FAMILIES`; selftest
  pins the match). A brush stroke only accumulates an outline and commits ONE
  polygon + ONE undo entry on release. In **Edit** the sliders are the picked
  camp's own settings, applied on a 0.2 s debounce and only where they differ.
- The editor-only `CampScatter` aerial-photo detector and its stamp / bake /
  candidate / forced-volume resources were deleted (no bake file ever shipped,
  so it rendered nothing). `camp_scatter_profile.gd` and the five
  `camp_profile_*.tres` stay — the legacy generator reads them.
**Night lights.** A lit household gets ONE main light (`pool: true`) hung
`LIGHT_DROP_M` under the top of its structure (under a canopy, at a tent's
peak — they used to float 0.2–1.2 m ABOVE the roof as orbs) plus 1–4 dim
string-light points (cards only); the extras draw from their own
(seed, cell key) stream, so they can never move a tent. Three layers hand
over by distance: real OmniLights (`CampLightPool`, 64 for painted camps)
with sticky slots that ease in and out (`ease_tau_s`) and dim toward the
edge of the pool's reach — the old pool snapped full-energy lights on at a
fixed radius ("motion-activated"); round emissive cards (`camp_glow`) that
are hidden inside ~22–75 m, where the real lights already carry the look;
and `camp_light_spill.gdshader`, a flat additive ground disc per main light
that fades in across the pool's fade-out band so far/aerial views still see
light pooling between tents. ⚠ Both additive shaders are `fog_disabled`:
Godot fogs unshaded `blend_add` quads too, so by day every zero-light card
was a fog-coloured rectangle up to 30 m across — the bluish sheen over
every camp at low angles.
Not built: collision on camp structures, camps as NPC `sleep` spaces, per-vertex
outline editing, the built-in SOAK/Mars scenes (no TerrainLoader), nose-in cars.

**Camp Tune look (`scenes/ui/camp_style_modal.gd`).** One modal, two ways in:
STYLE mode ("Tune look…" in the Camps options bar — a sample patch; where a
preset's baseline and its LAYOUTS are authored) and CAMP mode (Ctrl-aim a placed
camp + click, or the Edit tool's "Tune look…" with a camp picked — that camp's
real outline, seed and heading). The preview runs the REAL
`CampLayoutGenerator` + `CampAreaRuntime` in an `own_world_3d` SubViewport.

- **Four layers, one resolver.** `CampStyles.resolve(style_id, layers)` stacks
  sparse ENTRIES over the shipped table, weakest first: global style edit →
  the camp's LAYOUT → this map's edit → the camp's own override
  (`style_for_area(area, map_styles)`). An entry is `{fill, lane_w,
  rows_per_block, spacing, pos_jitter, loose_jitter_deg, scale_var,
  templates: {template_id: weight}}`. With no layers the shipped styles are
  byte-identical (selftest-pinned).
- **Three save scopes, one DELTA.** Sliders write a delta drawn on top of
  everything saved; the buttons decide where it lands: **This camp**
  (`rec.style_override` + `edits` + `variant`), **All <style> here**
  (`CampAreaLayer.map_styles`, saved in the map's camp file), **Global
  baseline** (`CampStyleStore`, `user://camp_styles.json`, every map — the dev
  tuning path). Models and layouts are ALWAYS persisted to the global file
  whichever scope is chosen: a camp cannot wear a layout or use a model that
  was never stored.
- **Layouts ("variants").** Several named looks under one style
  (`styles[sid].variants`, max 8, each with a `weight`; the style itself is
  "Default" with `default_weight`). `CampAreaLayer.add` deals a NEW camp one
  via `CampStyles.pick_variant(style, seed)` and STORES it on the record, so
  adding a layout later never restyles a camp already standing. This is the
  camp analogue of the veg "mix".
- **Hand edits to single elements** (`rec.edits`: `{key: {yaw_deg, scale,
  removed}}`). Every emitted item carries `key = "i:row:k"` (lattice cell +
  item index). Edits are applied AFTER the placement tests on purpose — turning
  an RV must not make it fail a test and vanish — so a hand edit may overlap a
  neighbour, by the player's choice. They are tied to the lattice:
  `update_camp_area` clears them when the seed, style or layout changes.
  Layouts do NOT carry hand edits (a cell key means nothing on another outline).
- **Click picking in the studio** is `CampLayoutGenerator.pick_item_on_ray`
  (ray vs each element's oriented box; flat things get a 2.4 m clickable body)
  over `CampAreaRuntime.area_items` (`rebuild_area(..., keep_items=true)`).
  It lives on the generator, not the modal, because the modal references the
  CursorController autoload and cannot be loaded under `--script`.
- CAMP mode passes `camp_preview_ctx()` — the real exclusions and slope tests
  with `flatten: true`, so the preview shows exactly the elements the map
  shows, on flat ground.
- A player-added model is a household of ONE (template `m:<class_id>`, class
  `u_<model_id>`, REAL size from `CampMeshLibrary.measure_model`), and
  `resolve()` grows the lattice cell to the largest household in the mix (and
  with `scale_var`) — that is what keeps no-overlap and grow stability true.
- The modal mutates the STATIC user layer while open; `close()` re-applies the
  SAVED data. Performance is a WARNING, never a refusal (`model_warnings` /
  `layout_cost`).
- **World focus:** `interaction_focus._update_camp_focus` (before water /
  buildings / veg — a painted camp is the player's own object) →
  `pick_camp_at_world` → `set_camp_focus` (change-gated footprint highlight) →
  Interact / Ctrl-click → `open_camp_tune_for_camp`. The focus is stamped with
  the physics frame and dropped from `_clear_water_focus`, which every other
  focus path already calls.
`--capture=camps` drives all of it and byte-restores the style file and the
map's camp file. ⚠ A run that is KILLED mid-way (or dies on a script error)
never reaches the restore and leaves its test camps in the map's
`camp_areas_*.json` — delete that file if a run did not finish.

**Festival placement (`core/camps/festival_*`) — the toolbar's PLACEMENT
section (Road / Zone / Lots / Assign / Edit).** Phase 1 of the festival-scale
plan (`~/.claude/plans/we-already-have-the-federated-brooks.md`). Regionals
allocate theme-camp ZONES along festival ROADS (rarely OSM roads), cut them
into LOTS of equal area despite slope and irregular outlines, and hand lots to
camps by size class and requirements. This tool recreates real layouts and
plans new ones; its lots are what the later phases populate.
- **One file, four record kinds** (`FestivalPlacementLayer`,
  `user://maps/festival_placement_<lat>_<lon>.json`): roads, zones, lots,
  roster — they reference each other by id, so one snapshot is one undo entry
  (the placement undo snapshots the CAMP layer too). NOT `kind:"zone"` records
  in CampAreaLayer: its `paint` carves every record a stroke crosses and its
  runtime would fill a zone with households.
- **Lots ARE camp records.** `_sync_lot_camps` mirrors each lot into one
  CampAreaLayer record (`group_id` = the zone, `heading_auto: false`, name /
  style from the assignment) through the same path the Plots tool used, so
  `CampLayoutGenerator` fills them unchanged (a `group_id` record fits the
  lattice to its own extent — trapezoid lots just work). `camp_area_id` on
  the lot is the link; records of a zone no lot points at are removed.
- **Fair = equal USABLE area.** `FestivalUsableRaster` (1–2 m cells,
  synchronous, ≤ 22 500 cells for a 90 000 m² zone) marks each cell inside /
  unusable (slope over the limit, or excluded: buildings, water, OSM roads
  AND festival road corridors — the corridors are fed to
  `VegExclusionBuilder.build_all` as plain road dicts) / usable; holes and
  LOCKED lots are not ground at all. `FestivalLotPartition`: per road (zone
  priority order) and side, usable cells in the band `[half_w, half_w+depth]`
  bin their area along arc length `s` → `cum(s)`; cuts at equal increments of
  `cum` (cross lane every K lots or D metres, second pass re-targets with the
  lane area removed); each `[s_a, s_b]` becomes a ribbon between the offset
  curves at `half_w + 0.3` and `half_w + depth`, clipped to the zone minus
  holes / locked lots / earlier roads' lots; slivers and lots under
  `front_min_m` fold into the smaller neighbour; names `A1…` with the block
  letter = road × side. The lot over blocked ground is WIDER — equal usable,
  unequal raw. `equalise: raw` ignores slope and exclusions (holes still bind).
  `target_n` is the ZONE's count, split across road sides by usable share
  (largest remainder, so the total lands on N); a side whose band is under
  0.3 of a lot or averages shallower than 0.35 × depth is SKIPPED — the first
  real-terrain run cut the 2 m strip between an inset road and the zone edge
  into eight 18 m² "lots" because each side used to get N of its own.
- **Grow-stability has two mechanisms.** In `area` mode the cuts march from
  the road's own s = 0, so extending a zone along its road appends lots and
  moves none (bit-identical, selftest-pinned). In `count` mode cuts must
  rebalance, so ids survive by overlap matching (IoU ≥ 0.5 against
  `prior_lots`, same road + side), carrying the assignment and the camp
  record with them. A LOCKED lot is subtracted before anything is cut and
  re-emitted untouched. Extending a zone at the START of its road shifts
  every cut — documented, not solved.
- **No road in reach** (`_zone_roads_auto`: corridors within `depth_m` of
  the outline, nearest first) → the old rectangular `CampSubdivider` lattice,
  measured like the rest, `road_id ""` and a warning; draw a Road, then
  Re-cut. The CAMPS Plots tool is untouched.
- **Headcounts are derived, not guessed**: `CampStyles.PEOPLE_PER_TEMPLATE`
  (how many each household sleeps) → `FestivalAssigner.people_per_m2(style)`
  = fill × weighted mean people per household ÷ lattice cell (`mixed` ≈ 0.027
  p/m² ≈ 37 m²/person, `theme_camp` ≈ 0.024). The assigner is largest-first
  best-fit (`usable ≥ 0.85 × requested`, features ⊇ requirements, style
  allowed by the zone, adjacency preference within 15 % of best fit), never
  touches `manual` assignments, and is deterministic.
- **Heading** now resolves festival road within 60 m → OSM road within 40 m →
  longest edge (`TerrainLoader._resolve_camp_heading`, replacing the three
  `resolve_heading(poly, get_osm_roads())` sites; `nearest_road_dir` was
  split out of `resolve_heading`, whose behaviour is unchanged).
- **Flatten** grades a road's corridor on the EDIT layer
  (`TerrainSculptOps.level_polyline`: smoothed centreline profile, feathered
  shoulder, absolute op) as ONE terrain undo entry — the TERRAIN section's
  Undo takes it back, not the placement Undo.
- Toolbar: `ShapeGestureController` gained a `"path"` mode (open polyline,
  never closes on its first vertex, Enter finishes via `finish_polygon`,
  `path_rejection_reason`); `EditToolbarState` carries the shared placement
  identity (allowed style mix, features, surface, equalise, cut-now) with
  `PLACEMENT_SURFACES` / `PLACEMENT_FEATURES` as LITERAL copies of the layer's
  tables (selftest-pinned). The overlay draws roads, zones and lots coloured
  by fairness (±5 % green / ±15 % amber / red), assigned lots filled, locked
  lots bold. `--capture=camps` step 10 cuts a real zone on Mount Vernon and
  dumps the per-lot table; it snapshots and restores the placement file too.
Not built: per-vertex lot editing, a roster modal (the Assign bar adds entries
inline), lots → population/graph (Phases 3 and 5 of the plan).

**Festival spaces, programme and venue choice (plan Phase 2).**
`SpaceTypes` gained the VENUES `stage` / `temple` / `center_camp` / `art`
(enrichment) plus `vendor` (feeds `hunger` after `kitchen` via
`NEED_ALTERNATIVES` / `spaces_for_need`) and `medical` (a role, no need
yet). A portapotty bank is a `restroom` with `units`; a water station is a
`water_point`. Every enrichment type carries a KIND (music / quiet / social /
art, `ENRICHMENT_KIND`) matched against a person's TASTE —
`NpcVenueChoice.taste_for(id)` hashes four 0..1 appetites per person — so two
stages pull the same people and a stage and the temple pull different ones.
- **`SpaceRegistry` v2**: `MAX_SPACES` 200 → 4000; records carry `draw`
  (base pull), `units`, `graph_item_id` (the tank / machine that receives what
  is consumed there — Phase 3 bills it) and `program`; v1 files gain the
  defaults; **unknown types are KEPT on load** (an older build must not erase
  a venue on its next save — the old test asserted the opposite). Lazy
  `_by_id` / `_by_type` indices replace the linear scans, and a POSITION
  CACHE (`refresh_positions(pos_of)`, filled once per bridge tick) means
  `nearest_space_by` and venue choice never resolve a prop record per
  candidate; `_nav_anchor_points` reads the cache too. `set_space_fields`
  patches the v2 keys.
- **`FestivalProgram`** (pure static over `rec.program`, slots `{day, start_h,
  end_h, draw, label, load_w}`, `end_h ≤ start_h` wraps midnight):
  `state_at(rec, hour)` → active / draw / label / load_w / ends_h /
  programmed. A programmed venue outside its slots keeps `CLOSED_DRAW` 0.15 ×
  base (people drift past a dark stage); a venue with NO programme is simply
  open at its base draw, so a site with only fire circles behaves as before.
  `load_w` is reserved for Phase 6 (a set's sound system on the camp's power).
- **`NpcVenueChoice.pick`** is the ONE enrichment rule for every tier:
  `draw × (0.35 + taste[kind]) × room − dist/150 m + company × 0.08`,
  deterministic (ties on id). `NpcAgent._begin_enrichment` builds the
  candidates from the registry (fire circles with no biomass skipped, as
  before), caches `_taste`, and clamps the visit to the set's remaining hours
  (`_enrichment_cap_h`) so nobody stands at a dark stage.
- The Y dock lists a venue's programme under its row (base draw, each set as
  a removable chip, an add-set line); capacity spinners everywhere go to 5000.
  Pose/host/routines name the new types (stage → dance, temple → sit,
  center camp / art → clap). Pinned by `_test_festival_spaces` in
  `npc_population_selftest.gd` (TYPES.size is now 15).
**A festival camp lives a festival day.** `NpcRoutine.festival_day()` (sleep
02:30–09:30, FREE afternoons, ENRICHMENT 19:05–02:00) is stamped as
`pop_routine` on every `CampTemplates` habitat. The camp `default_day` puts
everyone to bed at 23:30 and gathers in the AFTERNOON, which emptied a
20:00–02:00 stage set an hour and a half in and filled the DARK stage by
day (it is the closest, roomiest venue, and `NpcVenueChoice`'s distance
term beats a 0.15 closed draw) — the festival harness measured the set's
mean occupancy at 4.7 against 55.7 outside it before the swap.
Not built: per-camp default-space tables (`camp_defaults`, needs the camp
unit from Phase 3), day-of-festival slots in the UI (the `day` field exists).

**The LIGHT population tier (plan Phase 3) — `CrowdCohort`, `CrowdFocus`,
`NpcTierConvert`.** `NpcPopulationEngine` steps every agent's FSM on every
substep; `core/population/crowd_cohort.gd` simulates the same people as a
DISCRETE-EVENT crowd in packed arrays: a person is touched only when
something happens to them (arrive, finish, queue poll, set ends, an hour of
sleep), needs are lines between events (`value + rate × dt`,
`_materialize`), positions are segments (`a → b` over `t0 → t1`, `pos_at`),
and due events fire in (time, index) order (`MAX_EVENT_PASSES` bounds a
tick). Every random draw is `NpcHash.unit01(id, counter)`. 2000 people × one
sim-day at 0.1 h ticks ≈ 2.8 s here (≈12 ms per tick).
- **Consumption is tier-independent by construction**, and
  `crowd_cohort_selftest._test_equivalence_with_full_engine` pins it: the
  same 24-person camp run 3 days in both tiers lands water and food within
  6 % (measured 1–2 %) and morale within 0.08 / one band. Getting there
  meant mirroring three things the full tier actually does, each found by
  measuring per-activity hours: (1) a routine block RE-ISSUES its activity
  for as long as it lasts — a second meal inside the same EAT block
  (`NpcAgent._step_idle` has no "served once"; the shipped full tier eats
  ~2.5 kg/person/day against the preset's 1.5 — a calibration finding, left
  consistent across tiers rather than fixed in one); (2) sleep is NEVER
  interrupted (the wake test is the only terminator; the light heartbeat was
  sending sleepers to the bathroom at 1–5 am); (3) a DAYTIME sleep (need
  ≥ 0.9 between the wake hour and 21:00) is INSTANT in the full tier — its
  wake test fires on the next substep and refreshes the need — so it is
  instant here too, not a two-hour nap. Also `has_work`: with no chores on
  the (parked) board a WORK block falls through to gathering, as
  `_step_idle` does.
- **What the tier does not do:** A* (straight lines + a per-person lane
  offset), separation, chores with effects, crews, PERISH, walking kcal.
  Work is credited statistically (`take_work_hours`, banked by the bridge in
  `_light_work_h`; Phase 5 pays it onto the board). Queues are real: a full
  space makes people stand in a seeded slot and re-poll every 3 min for up
  to 30 min. Consumption at a space with a `graph_item_id` goes to THAT item
  (`take_venue_flows` → `ResourceFlowEngine.add_external_flow`, applied as a
  rate over the next step — a portapotty bank fills from the whole festival,
  `PORTAPOTTY_BLACKWATER_L` per visit and no flush water on the camp).
- **`CrowdFocus.decide`** is the tier policy, pure: a site whose whole
  population fits `MAX_FULL_PEOPLE` (150) is FULL everywhere — today's maps
  never convert — otherwise the watched camp and the camps within
  `FULL_RADIUS_M` of the viewer (nearest first, within the budget) are full,
  the rest light, with hysteresis (`LEAVE_RADIUS_M`, `HYSTERESIS_H`) so a lot
  boundary does not thrash. The view sets the viewer each ambient tick
  (`set_viewer`); `set_watched_habitat` pins a camp.
- **Conversion** (`npc_tier_convert.gd`) copies exactly what a person IS —
  id, position, six needs, morale, quit pressure — releases registry claims,
  and lets the receiving tier re-plan from IDLE. The full engine is PARKED
  (`_parked`) while its camp is light so the board, labour log, skills and
  duties survive; promotion hands the crowd back to it. Both snapshots ride
  `specs.pop_state` (`v: 3, tier: "light"`, packed arrays base64, ~45 B per
  person; `CrowdCohort.is_light_snapshot` discriminates) and `_ensure_engine`
  / `_ensure_cohort` restore from either shape, so a map saved in one tier
  loads in the other. The bridge now enumerates habitats through
  `GraphNesting.walk_items` (a habitat inside a camp compound counts), and
  `agent_dots` / `summary_for` / `habitat_of_agent` / `active` /
  `snapshot_all` / `reset_population` are tier-aware.
Verify with `core/population/crowd_cohort_selftest.gd` (Validation list)
and the unchanged `npc_population_selftest` + `--capture=population`
(the single-camp contract).

**Crowd rendering (plan Phase 4) — `CrowdRenderer` + `crowd_figure.gdshader`
+ `crowd_card.gdshader` + `CrowdFigureMesh`.** Every light-tier person is
drawn from TWO MultiMeshes (a ~220-vertex six-capsule figure, and a 2-triangle
card) with no per-frame CPU work beyond one uniform. The instance "transform"
is DATA, not a transform: `basis.x` = segment start, `basis.y` = segment end
(world, y from `TerrainSurfaceQuery` at the endpoints), `basis.z` = (t0, t1,
yaw_hint), `origin` = (pose, seed, flags); instance COLOR = the pastel +
morale. The vertex stage computes `mix(a, b, (t_rel − t0)/(t1 − t0))`, so
motion costs nothing and SCRUBS BACKWARDS inside a segment for free — the
growth-year pattern applied to people. Slots are rewritten only for people
whose event fired (`CrowdCohort.take_dirty`), everyone on a layout change or
a time REBASE (times are float32 relative to `time_base`; absolute sim hours
are ~1.7e7 and would quantise to whole hours). `custom_aabb` covers the site
because Godot's own instance AABB is meaningless for this layout. UV2 tags
each vertex's body PART and limb fraction (never COLOR — that is the instance
tint), and the shader swings limbs about joint constants that MUST match
`CrowdFigureMesh` (walk from distance travelled ÷ stride, sit, lie, dance,
work, queue). LOD is in the vertex stage: past `figure_dist` the figure
collapses behind the clip plane and the card draws at constant APPARENT size
(view-space, never `VIEWPORT_SIZE` — see camp_glow.gdshader), so the
settlement view at 1200 m shows a thousand marks where a thousand people
are. `NpcPopulationHost` skips dots with `tier == "light"` (never an
NpcAvatar for them) and hides itself under the "Nobody" pref.
`NpcDisplayPrefs.crowd_draw` (`home | all | lod | none`, Settings → NPCs →
"Draw people") + `crowd_lod_m` are uniforms, so switching is instant.
`SystemGraphView._ensure_crowd_renderer` creates it whenever anybody
simulates (empty it costs nothing) and `sync(abs_h)` runs after each
population tick (`crowd_render` section).
**The HERO POOL.** An NpcAvatar costs ~2 ms per figure per frame (measured:
`npc_host` 220 ms for the 100 full-tier avatars of a bench camp), so
`NpcPopulationHost._pick_heroes` keeps a real avatar only for the
`RenderProfile.npc_profile(quality).hero_max` (16/24/40/64) full-tier people
nearest the viewer — possessed and crosshair-focused people always, with
`HERO_HYSTERESIS_M` of grace so walking a boundary does not thrash — and
hands the rest to the SAME CrowdRenderer (`set_full_people`: a segment from
the last two tick positions, so the GPU glides them exactly as the host's
own prev→next interpolation would; pose from `_crowd_pose_for`). A roster
at or under the budget is ALL heroes with no distance test, which is what
keeps every single-camp map byte-identical. Hidden non-hero avatars keep
their node (invisible, no process) so promotion back is free.
**Nobody blinks out (2026-10-08).** With "Light-tier crowd figures" OFF the
whole CrowdRenderer used to hide — including the full-tier OVERFLOW the host
hands it — so only the nearest hero_budget people existed, and a turning
effigy circle read as people rotating in and out of the world (the user's
own npc_display.cfg had light_crowd=false). Now the renderer hides only the
LIGHT slots (shader `light_draw` + `full_base`: light slots sit below the
full block) and draws the overflow in every mode but "Nobody". Three more
fixes landed with it: the full block keeps a STABLE slot per person with
`FULL_SLACK` spare (a hero-set change used to change `instance_count`, which
clears and rewrites every light slot too — every frame while a circle turns);
the overflow segment now glides FORWARD from the drawn position over one tick
spacing (it used to END at the push time, so the figure arrived instantly and
stood — 5 Hz stepping); and a light-tier `S_CIRCLE` step is drawn as its
segment instead of a point (circlers jumped arc to arc). ⚠ After a re-layout
every FREE slot must be written hidden — a zeroed slot is a visible figure at
the world origin. **Knobs** (NpcDisplayPrefs, Settings → NPCs → Crowd detail,
each 0 = Auto, with a live readout of heroes / overflow / light / fps):
`full_figures` (hero budget), `full_sim` (CrowdFocus budget — only full-tier
people can be heroes), `figure_dist_m` (crowd figure → dot; Auto is now the
quality tier's `figure_dist_m`, the RenderProfile value that was never wired)
and `speed_shed` (the 300×/1000× caps; a player's own budgets shed in
proportion). Verify with the circle-visibility probe in `--capture=festivalmode`
(`_fm_visibility_probe`).
**No pops, no jumps (2026-10-09, measured with `--capture=popin`).** Hiding
the light tier outright could never be pop-free: a camera move (a toast's
click-to-look) switches ~60 camps' tier and whole camps appeared/vanished
(measured 111 appear / 19 vanish per 50 s of hops). The setting is now
"Distant crowd as dots" — OFF hides only the light tier's DOTS; its figures
still draw inside the figure reach and DISSOLVE out over its last quarter
(crowd_figure.gdshader `v_fade`, a 4×4 Bayer screen-door in the opaque pass).
Every slot write goes through `CrowdRenderer._put`, which EASES: it keeps the
last segment per person by id (`_seg_rec`, ABSOLUTE hours, survives a
re-layout via `_seg_old`), and a new segment whose start is not where the
figure is drawn now (a cohort event processed a tick late — a walker stood at
the end of a leg then leapt ~17 m; a tier switch; a hand-off) starts from the
drawn point and reaches its end no faster than `EASE_MPS` (3 m/s sim). An
eased glide into a STANDING spot keeps the person's facing (yaw_hint +
`YAW_FIXED` marker, mirrored in the shader and `drawn_yaw`). `drawn_position`
reads the record (no GPU readback). Records carry `full`; a person whose camp
just went light briefly owns BOTH slots until the host's next push — the full
slot is hidden at once (`_light_ids`) and must not overwrite the light
record. The host hands a new avatar in at `last_drawn_position` (slot, else
`_gone` for 3 s) and an avatar whose person went light calls `ease_from`. The
probe's phases: still camera at the stage crowd, then camera hops; it counts
VANISH / APPEAR / JUMP (a move faster than a catch-up glide) per cause and
dumps the record behind each jump.
Verifying the renderer: the figures were "invisible" for a whole evening
because the bench cameras looked from the crowd's CENTROID (the empty middle
of a field with people at six spaces) toward the origin, and then read dot
`x`/`z` keys that do not exist (dots carry `pos`). Aim at the busiest 10 m
cell (`--capture=crowdbench` now does), and use the studio diagnostic
`core/population/crowd_render_diag.gd` to separate shader / winding / gating
before touching the shader. Measured on Walton: 1000 people at 33–42 fps,
draw calls flat in N, slot heights equal to the ground raycast.
Not built yet: crowd picking, a height raster (a long segment over a hill
floats or sinks mid-way), the Site Plan MultiMesh dots, blob shadows.

**Camps as super-nodes + ledgers (plan Phase 5) — `CampTemplates`,
`SystemGraphView.sync_camps_from_placement`, `CampLedger`.** Every ASSIGNED
placement lot becomes one compound at root, stamped from
`CampTemplates.definition(style, headcount)` (a pop-driven habitat, water /
food / firewood stores and greywater / blackwater tanks sized per person,
with the five open loops promoted as ports: water, food, firewood IN on the
top face, greywater, blackwater OUT on the bottom) through
`GraphComponentDefs.realize` and then **`make_unique`** — camps are
independent by default; editing one must not restamp fifty (a player who
wants lock-step camps can still Save as Component one and re-stamp).
Idempotent by `specs.camp_lot_id` (the `add_imported_solar_panels` tag
discipline): a re-sync updates `camp_headcount` / name / `site_x_m,z_m` and
the habitat's `occupants` + `home_x/home_z` (which `NpcPopulationBridge
._home_pos` now reads before `bound_prop_id` — a camp has no prop), and a lot
that vanished removes its compound. The loader calls it (deferred, through
`ServiceLocator.graph()`) from `_attach_placement`, `_sync_lot_camps` and
`delete_placement_zone`. `CampLedger.compute(model, scope)` is the per-scope
sibling of the whole-model `ClosureMetrics`: per kind stock / capacity /
supply / demand / imports (nominal specs, or the bridge's live demand per
habitat) → `closed | importing | surplus | open`, days to empty / full;
`boundary_ports` says which promoted ports carry a wire in the parent scope;
`open_kinds` = the loops neither closed nor wired out (the badge);
`festival()` sums every camp compound. Selftest
`system_graph/camp_ledger_selftest.gd`. The canvas draws a camp compound as
a CARD (`graph_canvas._draw_camp_card`: present/headcount + morale band in
its colour, the power line, the open loops) off `camp_open` / `camp_morale`
/ `camp_present`, which `SystemGraphView._refresh_camp_cards` stamps once a
second inside the bulk/history-suppressed window — the canvas never walks
the model. Not built: festival infrastructure presets (water depot, pump-out,
portapotty bank item), crediting `take_light_work_hours` onto the parked
board.

**Simplified per-camp energy (plan Phase 6) — `CampPowerModel`
(`core/power/camp_power_model.gd`, pure static).** A camp is four numbers
on its compound — `pv_wp`, `battery_kwh`, `inverter_w`, `base_load_w`
(stamped from `STYLE_DEFAULTS` by `sync_camps_from_placement`) — plus a
state of charge that lives in `SystemGraphView._camp_power` and is stepped
by `_tick_camp_power` every ambient tick: `pv = pv_wp × yield` where the
yield is SolarUI's own `evaluate_solar_at` over its nameplate (camps see
the player's sun, tilt and weather — one sun, no per-camp tilt at this
tier), load = base load + `LIGHT_W_PER_PERSON` after dusk × `camp_present`,
capped by the inverter, and the SOC moves through the SAME
`EnergyTimeline.step_soc` the player's battery uses (95 %/95 %, a 10 %
floor). `ac_available` = the load was served; it is pushed per scope into
`ResourceFlowEngine.set_scope_ac_available`, and `_processor_has_power`
consults `_scope_ac_available[scope]` BEFORE the global `AcPowerBus` — so a
camp's processors run off that camp's power while root-scope and
single-system maps are untouched. Written onto the compound (`camp_soc`,
`camp_pv_kw`, `camp_load_kw`, `camp_ac`, `camp_hours_left`) at most twice a
sim-hour or on a 1 % SOC move; a scrub-back or a >6 h jump HOLDS (the SOC is
a forward integrator). Selftest `core/power/camp_power_selftest.gd`.

**Provisioning + testing switches (playability).** `CampProvisioning`
(`core/population/camp_provisioning.gd`, pure static) is the ONE source for
what a headcount consumes (the habitat preset's per-person rates × 24:
50 L water, 1.5 kg food, 0.5 kg firewood, 40 L grey, 10 L black per day),
the duration presets (`bare` 1 d / `weekend` 3 d / `week` 7 d /
`fortnight` 14 d, each with a margin), `supply(n, preset)` (supplies full,
waste tanks empty, both sized days × rate × margin), `days_remaining`, and
`requirements(n)` (simultaneous slots per space type from each need's
visit length over the routine window it is spread across — 316 people need
~35 restroom slots, which is the queue the Walton harness saw with 48).
`CampTemplates.definition(style, n, preset)` sizes a camp's stores from it
(the old per-person constants are gone; `def_id_for(style, preset)` keys
non-weekend presets separately), the loader stamps each lot with its zone's
`spec.provision` (else the global default), and
`SystemGraphView.provision_habitat(iid, preset)` — the inspector's
**Provision / Stock up** row on ANY habitat — adds a wired tank for every
unwired supply input and waste output, or grows + tops up a wired one, then
clears the flow timelines so the levels take. The population section also
prints "Needs (N people)". `PopTestPrefs` (`user://pop_testing.cfg`,
Settings → NPC → Testing & provisioning; `reset_defaults()` in selftests,
all off under `--script`) holds the guardrail switches: **ideal supply**
(the flow engine never starves a habitat — a dry/absent channel is counted
as `ideal_import_rates` on the habitat, waste with no sink as
`ideal_export_rates`, both erased when the switch is off; both tiers meet
a need with no space tagged, or every space full, WHERE THE PERSON STANDS
via `NpcAgent._begin_virtual_need` / the cohort's `_go(i, t, here, …)`,
still consuming, so what it bills IS the optimal demand curve; CampLedger
reads the stamps as IMPORTING / EXPORTING and the inspector shows "Ideal
supply … in / out"), **ignore capacity** (`SpaceRegistry.ignore_capacity`,
set by the bridge each tick — implied by ideal supply), **no departures**
(`_process_departures` and `_remove_agents` in the engine, the cohort's
`_process_departures`) and **mute alarms** (`SettlementLog.add` records
nothing; `_service_alarms` skips). The settlement HUD's speed line says
"TESTING (guardrails off)" while any is on. Selftest:
`core/population/camp_provisioning_selftest.gd`.

**Festival vibe + the Walton harness (plan Phase 7) — `FestivalVibe`
(`core/population/festival_vibe.gd`).** `compute(summaries)` is pure over
the per-camp `summary()` dicts both tiers share: the headcount-weighted
mean morale → band via `NpcMorale.BANDS`, the band histogram, the share of
people with a BLOCKED critical need, queueing, departures, and a
`components` list naming the need that drags the number — a diagnostic,
not a mood ring. `SystemGraphView._refresh_camp_cards` computes it once a
second (`festival_vibe()`, with a 24 h trend ring and the `headline`), and
three readers never walk the model: the top-centre chip
(`scenes/ui/festival_vibe_chip.gd`, created by Main under the hazard badge,
visible only while camps exist), the settlement HUD's line under the
scale label, and the dashboard's Festival block. Verify end to end with
`--capture=festival` on Walton (Validation list).

**Festival MODE (`scenes/settlement/festival_mode.gd`, `FestivalMode`; the
timeline's **Festival** chip; `Main.open/close/toggle_festival_mode`).** The
one-button way INTO the crowd simulation, on easy supplies. It exists because
the whole chain above was unreachable by hand: a painted camp is SCENERY (no
headcount), only an ASSIGNED placement lot became a compound, nobody moves
unless beds / kitchen / portapotties / water / showers / a stage are tagged,
and without the testing switches a camp with no tanks wired starves and walks
out — Walton had 30-odd painted camps and zero people. `open()`: (1) switches
`PopTestPrefs.set_easy_override(true)` — ideal supply, no queues, no
departures, muted alarms, for the SESSION; the saved flags are untouched and
the settings tab reads `saved_flags()` so its boxes never pretend the player
ticked them; (2) `TerrainLoader.populate_camp_areas()` gives every painted
camp a `headcount` (new CampAreaLayer record key, 0 = scenery; derived from
area × `FestivalAssigner.people_per_m2(style)` — the placement tool's own
density) and `update_lot_camp` fills every unassigned lot; with no camps at
all it seeds a demo zone next to the player, and on a scene with no
TerrainLoader plain `fest_hab_*` habitats on the graph; (3) seeds only the
MISSING space types from `FestivalSeedLayout.venue_plan` (a `sleep` area over
each camp outline + a `kitchen` on the inset outline — area targets match by
polygon, so the two must differ — plus portapotty banks / water stations /
showers sized from `CampProvisioning.requirements`, a stage with a
20:00–02:00 set, center camp and temple, searched outward from the camps'
centroid so they land BETWEEN camps, vetoed by the camp generator's exclusion
index via `festival_ground_free`), every label prefixed `Festival · `; (4)
forces `crowd_draw != none` and unpauses the clock (a NUDGE, never a claim);
(5) opens the settlement view over the camps' cluster at a framing height
(`open_settlement_view(at, start_h)` — new third parameter, threaded through
`SettlementView.open`). The settlement HUD shows a festival panel (people /
camps / up-close vs crowd / seeded venues, Evening 19:30 and Morning 10:00
jumps, Leave, Clear seeded — two clicks) and its speed line reads "FESTIVAL
(each camp's own supply)". The population slider shows a number at every
position (at 0, the camps' own total). `close()` hands the guardrails back and closes the view
but KEEPS the camps and venues (they are the player's site now);
`clear_seeded()` removes exactly the prefixed venues, every painted camp's
headcount, the demo zone/road and the fallback habitats. **Painted camps ride
the SAME graph sync as lots**: `TerrainLoader._push_camps_to_graph` appends
`FestivalSeedLayout.camp_lots(camp_areas.areas, zones)` — lot-shaped records
keyed `camp:<id>` — to the placement lots, so `sync_camps_from_placement`
stamps and removes them idempotently and they survive a reload. A live lot's
own camp record (`group_id` = an existing zone) is skipped there — its
headcount is the lot assignment; an ORPHAN lot camp (zone gone) counts as
painted. Measured on Walton: 32 painted camps + 3 lots → 855 people, 709 in
the light tier, zero blocked after 4 sim-hours. Verify with
`core/camps/festival_seed_layout_selftest.gd` and `--capture=festivalmode`.

**The marker is the site; festival set-up, site editing, the calculator
(2026-10-24).** Plan: `~/.claude/plans/when-i-activate-festival-effervescent-key.md`.
- **`SiteCentre.xz(context)`** (`core/soi/site_centre.gd`, autoload-free) is
  where "the site" is: the location marker (SoiService's centre), never the
  world origin or the player. Festival seeding (demo zone, fallback
  habitats), the settlement view's default framing and the population
  bridge's fallback home use it. The world's lat/lon frame does not move.
  ⚠ Camp compounds' `site_x_m/site_z_m` are MARKER-relative like every graph
  item (they used to be world xz); `home_x/home_z` stay world.
- **Seeded records are flagged, not remembered.** `festival_seeded` on camp
  records (CampAreaLayer, now a saved key with `headcount_locked`) and space
  records; a space seeded FOR a camp carries `camp_id` = the camp's lot key.
  `FestivalSeedLayout.is_seeded_space` = flag OR the legacy label prefix;
  Clear finds the demo zone / road by NAME too (the old ids were memory-only,
  so Clear did nothing after a reload — Bombay Beach kept a demo zone round
  the origin, 1.4 km from its marker).
- **Move festival to marker** (`FestivalMode.move_to_marker`,
  `TerrainLoader.translate_festival_layout`, `SpaceRegistry.translate_areas`):
  roads, zones, lots, populated camps and seeded / camp-linked area spaces
  shift by marker − cluster centre; one placement undo entry.
- **Setup card** (`scenes/settlement/festival_setup_card.gd`,
  `FestivalMode.setup_gathering`, pure `FestivalSeedLayout.setup_layout`):
  N named camps × people × style round the marker — a ring, each square
  sized to sleep its headcount at its style's density (×1.25), plaza
  (`SETUP_PLAZA_R_M`) in the middle for the shared venues, pushed out of
  vetoed ground. Camps are added as NEW records (`add_festival_camp`, never
  grown into a neighbour) with `headcount_locked`: the population target
  scales only unlocked camps (`_apply_population_target`). A typed People
  value locks too.
- **Site editor** (`scenes/settlement/site_editor.gd`): ONE screen-space
  editor for the festival view (E / "✎ Edit site") and Site Plan ("✎ Edit
  site" in the lens tool row), driven by `ground_at` / `to_screen` /
  `pick_prop` callables (graph_canvas `site_editor_ground_at` /
  `site_editor_to_canvas`). Select (smallest footprint first across props,
  spaces and camps; a camp's own beds / kitchen last; a still click cycles),
  drag = move, corners = reshape, edge + = add a corner, ⟳ = rotate, Del,
  Ctrl+Z; Draw space; Tag object (NpcSpaceTagRow for props / buildings /
  areas). Commits: `update_camp_area` (polygon / name / style / headcount
  all reach the graph now; a moved camp's linked spaces follow via
  `FestivalSeedLayout.follow_camp`), `SpaceRegistry.set_space_target` /
  `set_space_type_of`, `PlacedPropService.update_prop_record`. Picked props
  must contain the ground point (a slanted lens ray crossed the effigy's
  box 100 m away). `SpaceRegistry.revision` bumps on every change; the
  settlement overlay rebuilds on it. ⚠ A Control under a CanvasLayer needs
  `set_anchors_and_offsets_preset` — `set_anchors_preset` alone left the
  editor 0×0 and its right-anchored dock at x = −340.
- **Per-camp supply** (`SystemGraphView.camp_supply_modes / set_camp_supply /
  set_all_camp_supply`): compound `camp_supply` {inputs, wastes} → habitat
  `supply_mode`, read by `ResourceFlowEngine._process_habitat` through
  `PopTestPrefs.habitat_ideal`: "infinite" = never runs out (tanks and any
  loop-closing machine first, only the SHORTFALL imported / hauled off);
  "own" / "shared" follow only the player's SAVED ideal switch (festival
  mode's override no longer reaches them); unset = the global switch.
  "shared" tops the camp's tanks up from root-scope site depots
  (`fest_depot_*`) by `add_external_flow` at the rate its people used them.
- **The calculator** (`CampFlowMeter`, compound `camp_meter`, instance-only):
  the habitat's live flows (`ResourceFlowEngine.habitat_flows`: in, out,
  imports, exports) binned hourly on absolute hours; scrub back truncates.
  Pee / poo per person-day from Rose et al. 2015. **Camps & calculator**
  window (`scenes/settlement/festival_camps_panel.gd`,
  `SystemGraphView.open_camps_panel`, festival panel + Site Plan "Camps"):
  per camp supply pickers, per day / per person / so far / off site, Look,
  Sub-graph (`open_camp_subgraph`), CSV. **Loops** (`CampLoopClosure`): per
  kind closure from the camp's own sub-graph (plants' `biomass_kg_h`,
  catchments' `live_capture_lph` as live telemetry), suggestions keyed on
  the worst loop, `apply` drops a preset in wired to the camp's tanks.
- An edit to a LOT camp (in a zone) is written to the lot too
  (`TerrainLoader._write_edit_to_lot`): `_sync_lot_camps` mirrors the lot's
  outline / name / style back onto the record on every sync, so the edit
  used to be undone by the next sync. A moved or reshaped outline also LOCKS
  the lot, so a zone re-cut keeps it.
- Festival mode's default camps on empty lots carry `festival_seeded` on the
  assignment (`assign_default_lot_camps`, one save); Clear takes them back
  (`clear_seeded_lot_camps`) and leaves the player's own. A headcount the
  player typed on their own camp (`headcount_locked`, not seeded) survives
  Clear and Set up. Set up's supply choice applies to the camps it lays out.
- Loops: a plant credits a BIOMASS tank in the flow engine (the camp's
  firewood), so `CampLoopClosure` counts plants toward firewood; nothing in
  the library makes food yet, and the food row says so.
- Not built: toilet types (urine / feces as their own kinds); goal cards.

**Venue choreography + capacity sharing (`core/population/venue_crowd.gd`,
`npc_venue_state.gd`).** Three asks landed together on 2026-10-06:
- **Capacity is AUTO by default.** `SpaceRegistry.CAPACITY_AUTO` (0) never
  fills; `nearest_space_by` charges every occupant already there
  `SHARE_SPREAD_M` (12 m) of walk, so people draw their share of a type's
  spaces by distance + crowding instead of converging on the nearest one.
  An explicit number is still a hard limit (`DEFAULT_CAPACITY` 2 stays the
  API default for callers that pass nothing — the selftests depend on it);
  both tagging UIs and every festival seed default to 0. `NpcVenueChoice`
  gives AUTO venues no room penalty and adds a venue's `pull` to the score.
- **`NpcVenueState.resolve(space, hour, abs_h, fire_rec)`** is the ONE "what
  is this venue doing now" for both tiers: a stage's programme (a live set is
  a `pull` of 0.6), an effigy's FIRE RECORD (the burn is an EVENT, pull 2.0 —
  the enrichment-need gate is waived while any event is on, in
  `NpcAgent._wants_enrichment` and `CrowdCohort._decide`). The bridge resolves
  every venue once per tick (`_resolve_venues`, reading `burn` off the tagged
  prop) and hands `venue_state_of` / `venue_front_of` / `event_active` through
  ctx; a PHASE CHANGE wakes everyone seated there (`CrowdCohort.wake_at_venue`)
  — before that, light-tier people who sat down at the unlit effigy's spiral
  were still sitting 11 m from the fire mid-burn, waiting for a heartbeat.
- **The Effigy** (space type `effigy`, tagged on the burn structure; festival
  mode tags the burnable prop itself): IDLE = an art piece (loose spiral at
  0.8 × the safe radius); BURNING = everyone comes and sits in concentric
  RINGS from `EFFIGY_SAFE_R_M` (14 m) outward — row 0 lies (40 %) or sits,
  row 1 sits, the rest stand, rings further apart and seats looser the
  further out, so the crowd THINS with distance; from the collapse,
  CIRCLING for `CIRCLE_H` (45 min) — four lanes, one lap per 6 min, outer
  lanes a little slower, about half dancing and the rest walking,
  COUNTER-CLOCKWISE seen from above (`(cos a, −sin a)` with `a` increasing:
  east toward north); then AFTER = the spiral again, clapping or standing.
  Full-tier agents re-seat EVERY step (`_update_live_venue` — the circle is a
  moving slot, so `pos` follows it and the host glides the body; dancers keep
  the dance because the host clears `in_transit` for `venue_pose` dance /
  rave); the light tier runs the circle as `S_CIRCLE`, a chain of
  `CIRCLE_STEP_H` arc segments (`_circle_step`), so the GPU draws the glide.
- **The Bass Stage** (`stage`, relabelled): while a set is on the crowd packs a
  FAN in front of the speakers — a Vogel spiral folded onto ±65° ahead of the
  stage's FRONT EDGE (`stage_front`: the footprint's extent along the
  facing; `facing_deg` on the record, else toward the mean of the sleep
  spaces, else south) — and RAVES: `venue_pose` "rave" → pose machine
  CLIP_DANCE with the "rave" flavour (NpcSimpleFigure throws the dance 1.5×
  harder and 1.3× faster), crowd shader `POSE_RAVE` (7).
- **`venue_pose` is an INPUT** to NpcPoseMachine like `work_pose` (dot key
  from both tiers; `_pose_clip` lets it override the per-type default), which
  keeps the machine pure; "lie" maps onto CLIP_SLEEP, "sit" CLIP_SIT, "clap"
  CLIP_CLAP, "dance"/"rave" CLIP_DANCE, "stand"/"walk" idle.
- **Overhead readouts** fade with 3D distance from the camera (full inside 12
  m, gone by 34 m — `NpcAvatar.set_ambient_alpha`) and at most
  `AMBIENT_MAX_TAGS` (10) nearest people carry one; measured in 3D because
  from the settlement view's block height the camp straight below read as
  0 m away in XZ and stacked a wall of "sleeping" tags.
  The labels SHRINK with distance (2026-10-09; `NpcAvatar.LABEL_REF_M`,
  `fixed_size = false`): they used to be constant on SCREEN, which read as
  "smaller as I approach" (tiny beside a body up close, huge beside a speck).
  The name tag and the status stack hang off one `Labels` anchor at the top
  of the head (`Labels/Stack`, LABEL_STACK_Y above it) that follows the head
  down and is scaled `sqrt(max(1, d / LABEL_SHRINK_FROM_M))` — real size
  inside 3 m, then 1/sqrt(d) on screen: always smaller further away, never a
  speck (pure world size was unreadable by 8 m), and it grows UP from the
  head, never into it. Bar quads need `billboard_keep_scale` or the scale (and
  the fill's scale.x fraction) is dropped by the billboard. Verify with a
  three-distance shot (a NpcAvatar with set_tag_visible(true)).
- **Two facing conventions, half a turn apart.** A FULL-tier dot's
  `face_yaw` (NpcFacing.base_yaw) is the AVATAR's — forward −Z; the LIGHT
  tier's and the crowd shader's are forward +Z. The host converts both ways
  (`_hand_in` and the overflow entries add PI); an unconverted overflow figure
  stood facing backwards — the effigy circle "walked facing out of its lane"
  (the festival check read 0 of 55 full-tier circlers along the circle).
- **"Paths through the air" had two sources, both fixed.** (1) The host
  sampled a hero's ground height at the SIM position while drawing the body
  along its prev→next glide; on a slope at speed the two differ by metres —
  `_pose_avatar` now re-samples at the DRAWN xz. (2) The crowd shaders
  interpolated the segment ENDPOINTS' heights, so a 300 m tick-to-tick
  segment flew over a hill: `CrowdRenderer` now bakes a HEIGHT RASTER
  (2 m cells over the bridge's population region + 80 m, `FORMAT_RF`, 6000
  terrain queries per frame, rebuilt when the region moves 60 m) and both
  shaders read `height_tex` at the interpolated xz (`textureLod` in vertex),
  falling back to endpoint heights outside the rect or before the bake lands.
- **The sleep NEED's window follows the routine.** `NpcAgent.SLEEP_START_H`
  (21:00) used to open the sleep window for everyone; a festival camp whose
  routine sleeps from 02:30 still went to bed at 21:00 by need (the first
  festival harness measured 200 of 316 asleep at 22:00, through the headline
  set). Both tiers' `_pick` now take the window start from
  `NpcRoutine.sleep_start_h(fallback)` (the SLEEP block's start, else the
  constant); the wake hour and the instant-daytime-nap rule are unchanged.
- **An EVENT's first tick wakes the site**: `CrowdCohort.wake_for_event` ENDS
  (not merely pokes — a woken S_DOING person whose end_h is still ahead only
  gets a heartbeat) every light-tier visit at a non-live venue and every
  dawdle, so they re-decide and the pull brings them; full-tier agents do the
  same once per visit in `_step_doing` (`_event_checked`) and leave only if
  the event venue actually wins the pick — re-picking every step would be a
  finish/claim livelock.
Verify with `core/population/venue_crowd_selftest.gd` and the venue half of
`--capture=festivalmode` (Validation list).

**NPC realism pass (2026-10-07).** Six fixes, each with the trap it closed:
- **The stick figure walked BACKWARDS.** `NpcSimpleFigure` is built facing
  +Z (knees bend toward −Z, carry box at +Z) while the avatar's forward is
  −Z; the rigged body gets its half-turn from `NpcRig.model_yaw_offset()`,
  the simple body never did. `NpcAvatar._ensure_visuals` now rotates it by
  PI. Every stylised figure had walked away from its destination and faced
  away from its anchor since the style landed.
- **People sleep INSIDE shelters.** `CampAreaRuntime` always keeps a compact
  `shelters` meta per camp (tents / pods / yurts / vans / RVs with
  `CampStyles.SHELTER_SLEEPS`) and a `solids` meta (vehicles);
  `TerrainLoader.camp_shelters_in_polygon(poly)` + shiftpod props feed the
  bridge's `_sleep_spots` (one bed per sleeper, spread along the shelter's
  long axis). A sleep AREA resolves slot k to a bed (`bed_spot_of` in ctx,
  `NpcAgent._begin_need`) with the shelter's yaw as `lie_yaw`; the light
  tier's `home_slots` become the camp's beds (`_home_beds`). No shelters →
  the old spiral.
- **Fire perimeter = height + 10 ft while standing, 5 ft off the pile after.**
  `FireTimeline.estimate/make` now carry `height_m` / `footprint_r_m`;
  `VenueCrowd.safe_radius(rec, phase)` derives the radius per phase (defaults
  reproduce the old 14 m for records without a size) and every ring / lane /
  spiral keys off it. The bridge STAMPS the perimeter `F_BLOCKED` on the nav
  grid as the fire moves through its phases (`_apply_fire_perimeter`,
  re-applied after a rebake), so nobody walks into the fall radius or the
  pile either.
- **Crowd jitter.** Per-person scatter in every slot (`SEAT_JITTER_M`,
  `SpaceRegistry.slot_jitter`), per-person tempo / throw / stance yaw in
  `crowd_figure.gdshader`, and the circle's lane speeds vary a little.
- **Needs stagger.** `NpcAgent.rate_scale_for(id, need)` scatters hunger /
  thirst / bladder rise ±25 % per person (both tiers), and a programme
  slot's draw RAMPS from 35 % to full over its first half hour
  (`FestivalProgram.RAMP_H`), so a set's crowd builds by taste and distance
  instead of materialising at the first beat. ⚠ A per-person "linger" at
  block boundaries was tried in three forms (dawdle on every block, wait
  in place on meal blocks, idle delay on the gathering block) and EVERY form
  drifted the two tiers' morale apart past the 0.08 equivalence pin — the
  tiers see block boundaries at different moments (substeps vs events), so
  any boundary-relative delay lands asymmetrically. Do not reintroduce it;
  stagger through rates, offsets and ramps, which both tiers read
  identically. The ENRICHMENT routine block now goes through venue choice
  in the full tier (`_begin_enrichment`, as the light tier always did)
  instead of "the nearest fire circle".
- **⚠ `NpcPopulationEngine._make_ctx` is a WHITELIST.** Every ctx key the
  agents need must be forwarded there by hand; a key added only to the
  bridge's ctx never arrives, and the agent code falls back silently. All
  five venue keys (`venue_state_of`, `venue_front_of`, `event_active`,
  `bed_spot_of`, `no_go`) were missing for the first fourteen harness runs:
  full-tier agents resolved the effigy with NO fire record (idle spiral), the
  stage with no front (a fan round the centre facing south — "100 people
  behind the speakers"), no event waiver, no beds, no detours — while the
  light tier, which gets the bridge's ctx directly, did everything right.
  When a behaviour works in one tier and not the other, check this function
  before anything else.
- **Fire perimeter on foot.** A straight-line walk (grid baking, query
  budget spent) that would cut through a fire perimeter takes ONE waypoint
  round it (`NpcNav.detour`, fed `no_go` circles through ctx in both tiers);
  the light tier's A* routes end on the exact seat (the planner's goal is a
  cell centre, up to half a cell inward — a ring seat drifted inside the
  perimeter).
- **Paths.** The light tier now walks the SAME A* routes as the full tier
  (`plan_path` in its ctx; `_go` plans and `_advance_leg` chains the legs,
  keyed by `last_space` for the route cache), and the nav bake blocks camp
  vehicles plus every placed prop's live pick AABB
  (`TerrainLoader.nav_solid_footprints`; props tagged as spaces stay
  passable; PackedSpec dims are the SHIPPING size and must not be used for
  this — a shiftpod packs to 1.3 m and stands 3.6 m). Tents and pods are
  deliberately NOT blocked: people sleep in them. The camp structure count is
  folded into the nav fingerprint so a repainted camp re-bakes.

**Ponds are player-owned, never auto-added to the graph.** `pond_command` carves a
basin and optionally seeds a thin puddle; **Rain** / **Drain** (T dock) hold-modulate
`level_m` toward spill with bathymetric `stock_l`/`capacity_l` (Auto). Persisted per
site in `user://maps/user_water_*.json` (`level_m`, `capacity_mode`/`fill_mode`,
`capacity_l`, `stock_l`, …). The player Ctrl/Alt-aims a still-water body
(`interaction_focus._update_water_focus` → `pick_water_at_world`, highlights blue)
and Interact/clicks to open the **Pond settings modal**
(`scenes/ui/pond_edit_ui.gd`): level, Capacity Auto/Manual, Fill Auto/Manual,
**Add to graph / Remove**, **Delete**. Graph tank twins Auto bathymetry via
`sync_pond_level_from_mesh`. Membership via `SystemGraphView.has_pond_with_tag`.

`main.gd` (~1,900 lines) owns: environment/sky, shadow quality, collision
generation, save/load orchestration, vehicle/death-zone/crisis wiring.
World clock + astronomy live in `core/celestial_clock.gd` (`CelestialClock`,
owned by Main as `clock`); main.gd keeps delegating properties:
`year`, `month`, `day`, `day_time` (0–24 h), `latitude`, `longitude`,
`time_scale`, `sun`, `moon`.

Main scene UILayer (CanvasLayer) children by name (looked up by other code):
TimeUI (legacy hidden shim), GameOverUI, SolarUI, InteractionPromptUI, CrosshairUI,
EUCUI, HealthUI, HAConnectionUI, SaveLoadUI, SystemGraphView, TimelineUI,
CsvPlaybackUI, ProjectionCanvas, POVWarpOverlay, LocationPickerUI. HAClient
(`ha_websocket_client.gd`) is a direct child of Main, but only a FACADE over the
HomeAssistant autoload, which owns the connection (see "Home Assistant").

**Timeline-centric UI (replaces ESC TimeUI panel):** `TimelineUI` owns date
Y/M/D spinboxes, play/pause (Space releases mouse), and a gear settings drawer
(clouds, sun/moon/shadows, location, live mode, survival). `SimSettingsController`
autoload holds the shared logic; `TimeUI` only forwards signals for backward compat.
`CursorController` autoload owns mouse capture (play vs pause vs modal). Center-screen
`CrosshairUI` + `InteractionFocus` on Player drive crosshair interactables (group
`interactables`, base `gameplay/interactable.gd`).

## Autoloads (project.godot)

| Name | Script | Role / key signals |
|---|---|---|
| DeviceRegistry | power_system/core/device_registry.gd | Consumer registry; `total_power_changed(w)` |
| AutomationEngine | power_system/automation/automation_engine.gd | HA-style rules @0.1s; exports HA YAML |
| SaveSystem | core/save_system.gd | 8 slots + autosave, SAVE_VERSION=2, user://saves/ |
| GhiService | scenes/ui/location_picker/ghi_service.gd | NASA POWER GHI grid (scenes/ui/location_picker/data/ghi-grid.json) |
| InverterBridge | core/inverter_bridge.gd | Mirrors ~80 live HA entities (EcoWorthy + Shelly) |
| TimeDirector | core/time_director.gd | Authority over sim time: modes (LIVE/PLAYBACK/SIMULATE), NOW anchor, playhead, provenance; `mode_changed`/`playhead_changed`/`now_changed` |
| SimMode | core/sim_mode.gd | Compatibility shim over TimeDirector (preserves is_live/should_run_realworld_actions/etc.) |
| GameplayRules | gameplay/gameplay_rules.gd | Survival toggles, sync with main.gd |
| CameraServerBootstrap | scenes/ui/projection/camera_server_bootstrap.gd | OBS virtual camera |
| WeatherService | core/weather_service.gd | Open-Meteo archive weather, cached per location/year |
| ElevationService | core/terrain/elevation_service.gd | DEM grid: Open-Meteo (no key) / OpenTopography (key); `elevation_ready/failed/progress` |
| ImageryService | core/terrain/imagery_service.gd | ESRI World Imagery XYZ drape; `imagery_ready/failed/progress` |
| AiImageryService | core/terrain/ai_imagery_service.gd | Opt-in Gemini "hero patch" ground enhancement (image in/out); `ai_imagery_ready/failed`; key `[gemini] api_key` / `GEMINI_API_KEY` |
| DiscordIdentity | core/discord/discord_identity.gd | "Sign in with Discord" via OAuth2 **authorization-code + PKCE, no client_secret** (needs the app's "Public Client" toggle — see docs/LOCAL_CONFIG.md). Loopback `TCPServer` on one of 34199/34200/34201 catches the callback; refresh token in `user://discord_auth.cfg`; scopes deliberately limited to `identify` + `guilds.members.read`. Signals `sign_in_completed/failed`, `signed_out`, `membership_checked` |
| DiscordDirectory | core/discord/discord_directory.gd (+ `Relay` and `Population` children on MultiplayerSession) | "Who is playing right now", as ONE webhook message edited in place (no server, no bot). Read/heartbeat/vacate + the host election; `play_together()` is the whole one-button flow. Polls only while the lobby is open or we host — the webhook route budget is shared by the community. Signals `directory_changed`, `directory_error`, `election_result(won, record)` |
| MultiplayerSession | core/multiplayer/multiplayer_session.gd | **v3**: UPnP reachability + candidate-address connect ladder + Discord admission (see below). Listen-server co-presence (ENet host/join, avatars, host clock) + Phase 3–4 design share/ghost-merge + live graph/props sync (`Design` child) + Phase 5 session text chat (`Chat` child; Enter compose, proximity bubbles, mute, Discord invite deep-link) + Phase 6 hardening (join-code expiry, optional password, trusted-key allowlist, peer/snapshot caps, rate-limit kicks, local `user://mp_telemetry.log`); lobby via Timeline **Multiplayer** chip |
| AirQualityService | core/weather/air_quality_service.gd | Open-Meteo/CAMS hourly aerosols (pm2_5, pm10, dust, AOD, us_aqi); `air_quality_ready/failed` |
| ExtremeWeather | core/weather/extreme_weather_director.gd | Resolves hazards as a PURE FUNCTION of abs hours; `hazard_began/ended`, `risk_profile_ready` |
| MapContext | core/terrain/map_context.gd | Transient lat/lon hand-off to generated map scene (pre-`change_scene`) |
| CursorController | scenes/ui/cursor_controller.gd | Mouse capture policy: play/pause/modal stack |
| SimSettingsController | scenes/ui/sim_settings_controller.gd | Date/location/clouds/lighting/live mode; `live_mode_changed` / `simulation_started` |
| HomeAssistant | core/ha/ha_service.gd | The ONE HA WebSocket connection, saved instances, entity catalog; `state_changed(state, info)`, `sensor_updated`, `catalog_updated` |

## Energy sources (power_system/sources/)

`EnergySource` (base, group `"energy_sources"`): signal
`power_updated(instant_kw, daily_kwh)`; `get_current_power_kw()`,
`get_daily_energy_kwh()`, `get_peak_capacity_kw()`; finds Main for the world
clock. `contribute_to_grid=false` opts out of the grid balance
(SolarPanelSource does this — SolarUI models solar internally).

- `SolarPanelSource` (power_system/sources/solar_calculator.gd) — PV estimator.
- `WindTurbineSource` + `WindTurbineConfig` — P=½ρACpv³ (Manwell et al.),
  Betz cap 16/27, ISA density, log-law shear. Default: default_wind_1kw.tres.
- `HydroSource` + `HydroConfig` — P=ρgQh_netη (Paish 2002), Darcy–Weisbach via
  Swamee–Jain, monthly flow multipliers. Default: default_hydro_500w.tres.
- `CspTroughSource` (`power_system/sources/csp_trough_source.gd`, static, no
  3D EnergySource node — not an electrical source) — parabolic-trough CSP:
  single-axis N-S tracking law `cos θi = sqrt(1-(cosEl·cosAz)²)` (general
  1-DOF-tracker incidence formula; zero loss when the sun is due east/west,
  worst at solar noon high in the south — the real, documented "cosine loss"
  of N-S trough fields), Duffie & Beckman finite-length end losses, DNI via
  `SolarIrradiance` + cloud attenuation, water→steam boil-off (cp + h_fg).
  `simulate(specs, sun_az, sun_el, weather)` returns tracking angle +
  telemetry + `water_lph`/`steam_kg_h`.
- Static graph adapters: `power_kw_from_graph_specs(specs, hour|month)` drive
  the 2D graph items — extend these (not the canvas) for new physics params.

SolarUI sums contributing sources via `_poll_aux_generation()` into
`current_aux_generation_kw` → battery balance + HUD net.

## System graph (system_graph/ + system_graph/canvas_v2/) — **core gameplay surface**

**Vision:** `docs/SYSTEMS_GRAPH_VISION.md` (SoI, Planetary Basic Income catchments, ISRU
catalog, TouchDesigner nested canvases, sim↔real calibration). ROADMAP Pillar 9 +
Phase 8.

One view: `system_graph/system_graph_view.gd` (G toggles), using the V2 canvas
`system_graph/canvas_v2/graph_canvas_v2.gd` (extends graph_canvas.gd). Type
registries in graph_canvas.gd: PORT_COLORS / NODE_BORDER_COLORS / NODE_SIZES /
HANDLES / `_type_title`. Library presets: `system_graph/data/component_presets.gd`
(types: panel, wind, hydro, battery, smartbattery, controller, appliance,
acload, processor, resource, shelly4pm, compound). Inspector forms:
`inspector_panel.gd` `_rebuild_for_item` match. Solar mirroring:
`solar_bridge.gd` (virtual_* items @0.25s). Wind/hydro live refresh:
`system_graph_view._tick_graph_renewables()`. Multi-resource flow:
`resource_flow_engine.gd` + `ResourceTimeline` (scrub-safe tanks). Typed resources:
`resource_kinds.gd` (water, biomass, plastic_waste, …). Nested scopes:
`_active_scope_id` / compound Enter-Back (partial TD-style drill-in).
Graph state round-trips via `collect_save_state()`/`apply_save_state()` + per-scene
autosave JSON. **Overhaul direction:** SoI metadata, PBI catchment nodes, full
compound promoted ports, ISRU catalog beyond electrical, 3D↔2D node binding,
observed-vs-sim calibration per resource channel.

**SketchUp-style components (`system_graph/data/graph_component_defs.gd` +
`GraphModel.definitions`).** A generic super-node can be promoted to a reusable
**component definition** (inspector **Save as Component** → names it, mints a
`def_id`, persists to `user://user_presets.json` under the "My Components"
library category with nested defs). Each placement is an **instance**: a generic
compound with `specs.definition_id`/`definition_rev`, its child scope a realized
copy whose children carry `specs.def_local_id` linking them to template slots.
`GraphComponentDefs` (static): `realize` (recursive, multi-level — nested
template items reference other defs by id), `capture` (rebuild a def from a live
instance, strip `INSTANCE_ONLY_SPEC_KEYS` = SOC/telemetry/HA/3D/site/`*_tag`, bump
rev), `restamp` (reconcile a sibling to the def, matching by `def_local_id` so
per-instance state + external wires by stable handle id survive), `make_unique`
(detach). **Live propagation:** a structural edit inside an instance debounces
(`_component_sync_timer`, 0.15 s) → `_flush_component_sync` captures that
instance's def and re-stamps every sibling; re-entrancy-guarded by
`_component_sync_active` + `_history_suppress`. Built-in defs live in
`ComponentPresets` (`builtin_definition`/`builtin_component_tree`/
`component_preset_entries`) under the **Super-nodes** category; **StarShade** is a
3-level tree (array `starshade_solar_array` 3S×6P / hybrid inverter
`starshade_hybrid_inverter` CC+inverter / battery bank `starshade_battery_bank`)
that `StarShadeGraphSeeder.seed_graph` now realizes (with `source`/`starshade_tag`
as instance-only identity so dedupe/clear/HA still work) instead of flat nodes.
Model v6→v7 adds the `definitions` registry (old saves load empty). Ctrl+G group
/ Ctrl+Shift+G explode. Zoom drill-in/pop-out is now seamless (child bbox mapped
onto the collapsed body rect then tweened to fit + a short content fade — see
`graph_canvas.gd` `begin/finish_enter_transition` + `begin/finish_pop_transition`);
collapsed compounds draw + hit-test ALL promoted handles. **All super-node ports
follow the base graph's top-to-bottom flow: inputs across the TOP edge, outputs
across the BOTTOM edge** (`_distribute_handles` / `_distribute_compound_handle_positions`
/ `_compound_handle_pos`); when inside a child scope the boundary **portal pills**
dock along the top (inputs) / bottom (outputs) edges and draw a marching connector
wire down to the child port each fronts (`_draw_portal_pill_row`). PV Voc grouping
is now **series-aware** (`PvElectrical.connected_components(..., series_only=true)`:
only +→− links merge a string, +→+ / −→− are parallel) so the StarShade array's
**3S×6P** reads as six 3-panel strings (~112 Voc) instead of one 18-panel series
string (>600 Voc) — the controller no longer over-volts. A super-node may carry
`node_banner`+`model_id` (+`icon_replaces_frame:false`) to render its 3D subject's
GLB thumbnail as a 2D banner filling the node body instead of the child-graph
miniature (`_draw_compound_banner`, same preview path as processor cards) — the
StarShade definition does this. Self-test: `system_graph/graph_components_selftest.gd`
(includes a 3S6P no-over-voltage regression check).

## Home Assistant (core/ha/, 2026-10-22)

Plan: `~/.claude/plans/early-in-the-development-immutable-owl.md`. Connect, say
what happened, link any sensor to any tracked sim value.
- **Why "Connect did nothing":** Godot's WebSocketPeer never reports a REFUSED
  port on Windows. The socket stays "connecting" forever (measured: still
  connecting after 25 s), and the old client only signalled after a socket had
  opened, then retried every frame in silence. The player's saved
  `ws://<lan-ip>:8123` was refused because their HA answers on port 80.
  - A dead address is now only found by `connect_timeout_s` (6 s).
  - The FINDER starts at `early_probe_s` (2 s): it probes `HaUrl.candidates`
    (the same host on :8123 / :80 / wss :443) for a peer that sends
    `auth_required`. No token is sent. A hit becomes `info.suggestion_url`,
    offered on the status card as "Use <address>".
  - Never classify by elapsed time: Windows retries a refused SYN for about 2 s.
- **`HomeAssistant` autoload** (`HomeAssistantService`, autoload-free so the
  selftest builds it under `--script`) owns everything:
  - **State machine:** IDLE → CONNECTING → AUTHENTICATING → CONNECTED, or
    FAILED with `info.reason` set to an `HaFailure` constant.
    `HaFailure.describe` gives the words and a fix.
  - **Auth** is sent ON `auth_required`, never on a timer.
  - **Keepalive:** ping every 30 s, with a pong timeout.
  - **Retries** back off from 2 s to 60 s, and only after a success or under
    auto-connect. A rejected token is never retried.
  - **ONE** `state_changed` subscription per connection, filtered locally. The
    old client opened one per caller, so each update arrived N times.
  - `get_entity_states` calls are COALESCED into one `get_states` per frame.
    The old client's second call overwrote the first's filter, and that reply
    leaked every entity.
  - `get_single_entity_state` used to open a `render_template` subscription per
    call, which leaked; it now goes through the coalesced fetch.
  - The entity catalog comes from that same fetch.
  - `call_service` is gated by `SimMode.should_run_realworld_actions` unless
    `force`.
- **Main/HAClient** (`ha_websocket_client.gd`) is a FACADE that re-emits the
  service's signals and forwards its methods. The scene consumers keep finding it
  by node path or `ServiceLocator.HA_CLIENT`; new code uses the autoload.
- **Saved instances** (`HaProfiles`, `user://ha_profiles.cfg`, SECRET and in
  `AssetPackFormat.SECRET_FILES`):
  - `ha_connection.cfg` is migrated once.
  - A world can name its own instance (world.json `ha_profile_id`).
  - Auto-connect runs on `SceneTree.scene_changed`, only for an instance that
    has worked before (`last_ok_unix`).
  - It is OFF under `--capture` / `--run-script` (`--ha-autoconnect`
    re-enables it), so a test never reaches the player's real HA.
- **UI:**
  - Settings → Home Assistant is `scenes/ui/ha_settings_tab.gd`, in `HUB_PAGES`
    so it works at the launch hub. It has the instance list, a lenient address
    with a live "Will connect to" line, a token shape check (`HaToken`), and a
    status card with four steps and fix buttons.
  - The timeline **HA** chip shows grey (off), amber (connecting / retrying),
    green "· N live", or red, and opens the page.
  - Toasts announce connected / failed / lost, once per reason per attempt chain.
  - `SimSettingsController`'s `*_ha_*` functions are thin wrappers.
- **Live links** (`HaTargets`, `HaUnits`, `HaLinkStore`, `HAEntityLinker`):
  - A TARGET is `site.<f>` (SolarUI energy), `weather.<f>`, or
    `item.<graph id>.<field>`. The item field ids are the old `specs.ha_links`
    roles, plus tank `level_pct` / `stock_l`, processor `switch`, wind / hydro
    `power`.
  - Links are saved per world (WorldPaths kind `ha_links`): entity ids only.
    One link per target.
  - The old places migrate once into a world with no link file: each node's
    `specs.ha_links` (stripped afterwards) and `solar_ui_ha_entities.cfg`.
  - The runtime is `HAEntityLinker`, a SystemGraphView child. It converts by the
    sensor's `unit_of_measurement`, then applies the link's scale / offset /
    flip.
  - In every mode it writes the `specs.ha_live` badge cache and records the
    reading (below).
  - It APPLIES only when TimeDirector is LIVE, the service is CONNECTED and the
    reading is fresh (`STALE_S` 600). ⚠ LIVE needs the player's **Live mode**
    switch on (SolarUI `is_in_live_mode`), not just 1×. The Live links window
    and the HA page say so and offer "Turn on Live mode".
  - Item writes go inside the view's `_begin_sim_writes` bracket, and the probe
    pins that `user_rev` does not move. `apply_historical_value` used to bump it
    on every replayed sample.
  - Site / weather values go through `SolarUI.set_live_reading` /
    `clear_live_reading`. SolarUI's own per-field entity handling stands down
    while `ha_links_external`; only its solar history-graph sensor is still read
    there.
  - Tanks are re-held on their `ResourceTimeline.set_current_level` once a
    second in LIVE.
  - Battery / panel / inverter node links still drive SolarUI's battery /
    solar / load unless the world links that site value directly.
- **Observed tracks** (`HaObservedStore`):
  - Every reading, in the target's unit, on REAL time: local wall-clock absolute
    hours, the NOW marker's axis.
  - HA's recorder backfills `HISTORY_BACKFILL_H` (72 h) per link per session.
  - Timeline Tracks ▾ → Add Home Assistant track → a linked value adds a
    source-`ha` lane (`TimelineTrackLayout.add_ha_track`,
    `timeline_ui._draw_ha_lane`).
  - The Live links window shows sim vs real.
- **Timeline tracks for weather and any HA sensor** (2026-10-22):
  - Tracks ▾ has the shown tracks (click to show / hide), then the submenus
    Add power track, Add weather track, Add Home Assistant track and Remove a
    track.
  - ⚠ The old handler read PopupMenu metadata by ID, while the "＋" items have
    ids from 1000 that never match an index, so adding a track from the menu
    never worked. Metadata is now read by `get_item_index(id)`.
  - **Weather** (`TimelineWeatherChannels`, source `weather`): temperature,
    dew point, humidity, wind, gusts, solar radiation, cloud cover, rain and
    snow depth.
    - Each value comes from WeatherService's own accessor, sampled per bin; rain
      and gusts take the bin's peak.
    - The display follows the weather card's °F / °C switch.
    - NAN draws as a gap.
    - Lanes are cached 10 s per window.
  - **Any HA entity** (source `ha_entity`) is picked in
    `scenes/ui/ha_entity_picker.gd`. It lists numbers and on / off domains;
    text states are skipped.
    - `HomeAssistantService.track_entity` records every reading.
    - `entity_bins` fetches the visible window from HA's recorder
      (`significant_changes_only` false, ≤ 14 days back). It fetches only what is
      not covered yet (`_hist_cover`), and the cover is cleared on reconnect.
  - HA lanes are REAL time (the NOW axis) and are never carried past NOW
    (`HaObservedStore.bins(..., until)`). With the playhead days away from NOW,
    the lane says "no readings in this window".
  - **Zoom-stable binning (`TimelineBinning`, all lanes, power included).**
    The old lanes cut a fixed number of bins between the window's edges and
    kept ONE value per bin, and power bins strided past 64 samples. Every zoom
    or pan moved the bin edges in time, so a sawtooth turned smooth at some
    zoom levels.
    - Bin widths now come from a fixed `LADDER` (1 min … ~1 y), at one bin per
      ~3 px and never finer than the data's step.
    - Bins are ANCHORED: bin k is [k·w, (k+1)·w) whatever the window.
    - Each bin is EXACT: min / mean / max of everything in it.
      - `from_regular` is used for the energy timeline / sim / CSV, through
        their packed-array `channel_slice`.
      - `from_function` is used for hourly-linear weather. It reads the edges
        plus every whole hour, at most `MAX_POINTS_PER_BIN`, with a trapezoid
        mean.
      - `from_steps` is used for HA readings: time-weighted mean, the held
        value counted, gaps, nothing past NOW.
    - Drawing (`TimelineWaveformDraw.draw_bins`) shows a soft fill to the mean,
      the min–max band and the mean line. The fill and band are explicit
      triangle strips (`RenderingServer.canvas_item_add_triangle_array`):
      `draw_colored_polygon` failed triangulation on flat stretches.
    - Lane caches are keyed on the anchored grid.
    - SolarUI's entry point is `get_timeline_bins(source, channel, w, i0, n)`.
      The old fixed-count `get_timeline_waveform_bins` and the one-value draw
      helpers are gone.
    - Selftest `core/timeline/timeline_binning_selftest.gd`; the probe below
      shoots five zoom levels.
- **Windows:**
  - `scenes/ui/ha_links_modal.gd` (`Main.open_ha_links(target_id)`): the tracked
    values with live / sim values, plus an entity browser. It searches, filters
    by domain, and defaults to "Compatible only" (`HaUnits.compatibility`: unit
    family, then device_class).
  - The inspector's Live twin rows, and SolarUI's value labels, open it on
    their target.
  - `scenes/ui/ha_presets_modal.gd` (`HaPresets`): EcoWorthy ESP32 CAN bus,
    Shelly Pro 4PM (both `output_N` and `switch_N` naming), and a single Shelly
    relay. These replaced InverterBridge's 78 hard-coded ids. InverterBridge no
    longer subscribes by name, and its Shelly toggle uses the node's links.
- **Also fixed:**
  - `HAAutomationPusher` looked for a `/root/HAClient` that never existed.
  - LoadCalibrator now switches its load back off.
  - AutomationEngine's context carries every followed entity's state, so
    "Custom (HA entity…)" triggers can fire.
  - The CSV player no longer fakes `sensor_updated`.
- Real-load measurement: `system_graph/load_calibrator.gd`. Automation push:
  AutomationEngine YAML + `system_graph/ha_automation_pusher.gd`.
- NOTE: docs/ROADMAP.md Pillar 5 prescribes a HACS-integration architecture
  instead. That is a migration decision; do not start it without an explicit
  call.

## Location (single source of truth)

`main.gd` owns `latitude`/`longitude` (full GPS precision; they delegate to
`clock`). **All location changes route through `main.apply_location(lat, lon,
label="", persist=true)`** — it sets the coords (sun/moon/stars are pure clock
functions, so they follow for free), persists to `user://location_prefs.cfg`
(actual lat/lon + label, not just a flag), and emits `location_changed(lat, lon)`.
`WeatherService` re-fetches on its own location poll (`_process` compares
`covers()`); no explicit weather call is needed.

- **Persistence across playtests:** `_load_location_prefs()` runs in `_ready`
  (after `_init_from_system_time`), restoring the last chosen site independent of
  save games. Save-load also routes through `apply_location` so a loaded location
  persists and syncs every UI.
- **Entry points (all unified):** TimelineUI gear settings + lat/lon SpinBoxes
  (step 1e-7), LocationPickerUI (M key — map click, address geocode, or typed
  WGS84 coords via "Use coords"), and save-load. Legacy TimeUI node remains hidden.
- `location_prefs.cfg` is gitignored (user pref, never committed).

## Weather (Open-Meteo)

`core/weather_service.gd` (autoload `WeatherService`): two data sources,
seamlessly merged in `sample()`:
- **Archive** (`archive-api.open-meteo.com`): one full calendar year of hourly
  data cached at `user://weather_cache/`. Sim years without complete archive
  coverage (current/future) substitute the latest complete year via
  `effective_year()`.
- **Forecast** (`api.open-meteo.com`): 5 past + 16 future days (~21-day window),
  fetched daily when `_sim_year == current calendar year`. Stored in
  `_forecast_series` with `_forecast_start_hoy` (hour-of-year of first entry).
  `sample()` silently prefers forecast data for dates in the window; archive is
  the fallback. No UTC conversion — `timezone=auto` + pure calendar arithmetic.

Variables: shortwave_radiation, diffuse_radiation, wind_speed_10m,
temperature_2m, precipitation, cloud_cover.
Signals: `weather_data_ready(lat, lon, year)`, `weather_fetch_failed(reason)`,
`forecast_data_ready(lat, lon)`, `forecast_fetch_failed(reason)`.
Public helpers: `has_data()`, `covers(lat, lon)`, `has_forecast()`,
`is_forecast_date(month, day)`, `effective_year(sim_year)`.
Connect `forecast_data_ready` BEFORE calling `request_forecast()` (same
deferred-emit pattern as the archive signal). Consumers: solar_ui
`_try_apply_open_meteo_weather` (sets `_forecast_active` flag when in window),
WindTurbineSource (real 10m wind), HydroSource monthly multipliers.
Synthetic fallback must always keep working offline.
**Leap years (fixed 2026-10-21).** A leap-year archive has 8784 hours. Every
(month, day, hour) → index goes through `WeatherService.hour_index` /
`day_of_year0(month, day, leap)`; never index a series with
`_DAYS_BEFORE_MONTH` directly. Reading a 2024 archive with the common table
put every date after Feb 29 one day early (Bombay Beach's Apr 14 15:00 dust
storm, 28.5 mph, read Apr 13's 5.5 mph). The layout comes from the array
(`is_leap_layout`: size ≥ 8784), from `_cy_year` for the partial current
year, from the start year for the forecast window. Feb 29 on a common-year
dataset reads Feb 28. Generated years stay 8760, and training archives lose
Feb 29 (`to_common_year`) before the engines see them. Checks:
`_test_weather_leap_index` in source_physics_selftest, and on the world
`tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/weather_leap_probe.gd`.
UI indicators: 🌤 green-teal = live forecast; 🌎 blue = historical archive;
📡 = live HA; 🔄 = synthetic.
**No manual weather picker.** Open-Meteo drives automatically whenever a dataset
covers the location (synthetic only fills offline/uncovered gaps); solar_ui
`_update_weather` always calls `_try_apply_open_meteo_weather()`. The bottom-bar
weather control is a non-interactive **source indicator** (`_wx_source_lbl` in
timeline_ui), not a toggle. The legacy `set_weather()`/`cycle_weather()` manual
state machine is retained in code but no longer wired to any UI.

**Time-zone alignment (2026-10-21).** `timezone=auto` stamps the WHOLE series
with ONE fixed offset, the one in force on the day it was fetched (Bombay Beach
2024 cached at UTC-7 all year: no skipped or repeated hour at the DST changes).
The game clock is its own zone (`CelestialClock.zone_offset_hours`: rounded
meridian + US DST anywhere). Reading the file by the clock's wall time put US
winter weather an hour early and Madrid / Sydney 1-2 h off. `sample()` now
re-expresses the clock's local instant in each real dataset's offset
(`_data_utc_off_h` / `_cy_utc_off_h` / `_forecast_utc_off_h`, parsed from
`utc_offset_seconds`; `shift_calendar`, `_offset_shift`), so the weather is
the weather of the UTC instant the in-game sun is drawn for. Generated years
and runs with no clock (selftests) are unshifted. Pinned by
`_test_weather_utc_alignment`; end to end by
`tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/weather_fidelity_check.gd -Timeout 1500`.
That check reads every hour of 15 extreme events against a UTC reference
fetched independently (`python tools/checks/weather_reference_fetch.py` →
`core/weather/testdata/weather_events_ref.json`). The sites include your
worlds plus Madrid, Houston and Sydney; the events include the heat dome,
the Skagit atmospheric river, Hilary, Ciarán, Filomena, Harvey, the Texas
freeze and Feb 29. After the fix every reading matched; 1,277 of the 3,720
(about a third) were off before it. The game equals the Open-Meteo
reanalysis (ERA5 family); a reanalysis grid cell is smoother than a station,
so it under-reads local peaks. Note the clock's US-DST-everywhere rule is a
separate, older simplification (the sun is drawn by the same rule, so weather
and sun agree).

**Rain looks like its rate (core/precipitation_vfx.gd `rain_look`).**
- Drop size: Marshall-Palmer D0 = 0.89 R^0.21 mm, drawn ×1.6.
- Fall speed: Atlas 1973, v = 9.65 − 10.3 e^(−0.6 D).
- Drops in the air ∝ R^0.37 / v, normalised at 50 mm/h.
- Streak = a camera-facing quad along each drop's own velocity
  (`core/rain_streak.gdshader`, `particle_flag_align_y`). Its length is the
  speed × 0.05 s exposure and its width scales with the diameter.
- Wind: the drops' horizontal speed is the 10 m wind × 0.72 (log law to 2 m).
  So light rain blows over and heavy rain falls nearly straight; still air is
  vertical. SolarUI passes the wind speed (`update_frame(..., wind_ms)`).
- The volume is a tight 26 × 18 × 26 m box in WORLD space round the eye.
- Classes are the AMS ones. Pinned by `_test_rain_look`; shots:
  `tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/bombay_rain_check.gd`
  (Hilary 2023-08-20, local time: 10:00 light, 12:00 heavy, 15:00 windy).

## Solar physics (SolarUI + SolarPanelSource)

Standard mode (always-on, default):
- DNI from Kasten-Young atmospheric transmittance formula
- NOCT cell temp: `T_cell = T_amb + (NOCT-20)*G/800`, NOCT=45°C
- Temperature derating γ = -0.004/°C: `factor = 1 + γ*(T_cell-25)`
- `_estimate_ambient_temp()`: prefers `WeatherService.temperature_c()` when
  Open-Meteo data is active; falls back to synthetic 15-38°C diurnal cycle
- Sun position from `main_node.sun` (DirectionalLight3D, driven by CelestialClock)

High-accuracy mode (`_high_accuracy_physics = true` in Panel Settings):
- `core/solar_position.gd` (`SolarPosition`): Meeus Ch.25 + Bennett refraction,
  ~0.01° accuracy; `get_position(lat, lon, jd_utc)` → `{elevation_deg, azimuth_deg}`;
  requires `main_node.clock.get_julian_day_utc()` (falls back to DirectionalLight3D)
- Erbs (1982) diffuse fraction: decomposes real GHI (from WeatherService
  `solar_radiation_wm2`) into DNI+DHI → tilted-plane POA via isotropic sky model;
  falls back to geometric DNI when no real data
- Optional 3D shadow: single `PhysicsDirectSpaceState3D.intersect_ray()` toward sun
  from `Vector3(0, _shadow_sample_height, 0)` or node in group "solar_panel_location";
  enabled separately by `_shadow_raycast_enabled`
- Both flags persisted to `user://solar_panel_config.cfg` (`high_accuracy`, `shadow_raycast`)
- Panel Settings UI: two CheckButton toggles at bottom of settings panel

Self-test: `power_system/sources/source_physics_selftest.gd` (97 checks total)
includes solar-physics checks (NOCT formula, gamma derating, SPA horizon, cos_incidence).

## Night sky (stars)

`core/astronomy/star_system.gd` (node "StarSystem" under Main) + the star block of
`sky.gdshader` + `core/astronomy/star_sky_math.gd` (`StarSkyMath`, pure static,
selftest `core/astronomy/star_sky_selftest.gd`). **Orientation is COMPUTED,
never calibrated:** every sky tick StarSystem pushes the local sidereal time
and the equatorial basis for the current latitude — `pole = (0, sin φ, −cos φ)`,
`meridian = (0, cos φ, sin φ)` (due south), `east = (1, 0, 0)` — as three
vec3 uniforms, and the shader inverts them per pixel: `dec = asin(v·P)`,
`H = atan2(−v·E, v·M)` (positive WEST), `RA = LST − H`. **The bug this
replaced, so nobody puts it back:** the shader rotated the view about the pole
by LST and then read the texture latitude off the rotated WORLD vector's y —
the zenith as the texture pole — which is only right at latitude 90°; the old
RA/Dec "offset" + "flip" sliders existed to fight that and could only null it
at one instant. They are gone (`user://star_calibration.cfg`
`calibration_version 2` erases the keys); HOME toggles the computed
reference-star markers (Polaris/Sirius/…) which must sit ON the texture stars.
**The map's registration is DATA:** `assets/sky/starmap_equirect_8k.json`
(sidecar next to the PNG) says which RA sits at u = 0, which way RA runs across
the image (`ra_direction −1` = increases leftward, the inside-the-sphere
convention) and whether the NCP is the top row — MEASURED by
`tools/starmap_prepare.py` from the bright stars, never assumed. The map is a
J2000 plate-carrée export from Stellarium (`tools/stellarium_starmap_export.ssc`,
GUI/ground/atmosphere/labels off; Stellarium's all-sky projection works in the
mount frame — keep the mount equatorial). Two traps the prep tool exists to
close: Stellarium draws bright stars as SATURATED discs, so "the brightest
pixel" ties across dozens of stars (blobs are ranked by integrated brightness),
and the Milky Way core at intensity 1.6 out-sums every star disc (compact-disc
area/mean filters). The old FOV-180 "Cylindrical" screenshots were alt-az
panoramas with the GUI baked in and could not be registered at all. **Third
trap — Polaris vanishes without it:** Stellarium draws every star as a fixed
~10 px disc in IMAGE space, and a plate carrée squeezes 1 px of x into
`360/w·cos δ` degrees, so at dec 89.26° a 10 px disc is 0.006° of sky and the
shader renders the pole star as a sub-pixel sliver. The prep tool's
`pole_footprint_dilate` runs a 1-D horizontal MAX filter of radius
`R·(1/cos δ − 1)` per declination band (R measured from the anchor star's own
disc, x wrapping like RA) for |δ| ≥ 45°, so image-space discs become
sky-space discs; recorded in the sidecar under `prepare.pole_footprint`. **One
timezone for sun AND stars:** `CelestialClock.zone_offset_hours` (rounded
meridian + the US DST rule) feeds `get_solar_time`, both `*_to_clock_time`
inverses and `_julian_day_utc_for`; `get_julian_day()` is UTC. Sidereal time
is `StarSkyMath.gmst_deg` (Meeus 12.4) for the stars, moon and clock alike.
Texture import: BC7 (`compress/high_quality=true`), no mipmaps — the sampler
is `filter_linear` and mips bloomed halos. Planets stay in `planets.gd` but
share `StarSkyMath` for their alt/az.
**Analemma planet paths** (main.gd `PLANET PATHS`, `show_planet_paths` +
`planet_path_frame`): SKY = horizon-frame directions sampled at the sun's (or
moon's) daily instant; STARS = RA/Dec meshed once as
`StarSkyMath.equatorial_vector` and turned with the sky every frame by
`equatorial_to_world_basis(live LST, lat)` — that basis must stay identical
to `direction_from_equatorial` or the loops slide off the stars. Both pinned
in star_sky_selftest, which also checks the retrograde station dates of all
five planets against the 2024–25 almanac (measured within 0.5 d).
**Zodiac overlay + analemma "stars through daylight".**
`assets/sky/zodiac_overlay_8k.png` (R = 12 figures, G = names, B =
Ophiuchus) is built by `tools/zodiac_overlay_export.py`: Stellarium supplies
DATA (the "modern" sky culture's HIP polylines + a scripted
`core.getObjectInfo` dump of each star's J2000 position) and the tool
rasterises in the star map's own sidecar registration, then refuses to write
unless every bright line star sits on a blob in the star map (measured worst
1.06 px). Screenshots were tried first and abandoned: 26.2's scripted
"isolate selected" drew one constellation, then all 88, with English names.
The overlay is CC BY-SA 4.0 (share-alike — see CREDITS). BC7, NO mipmaps (a
mip-selecting sampler draws a seam at the RA wrap). The ZODIAC block in
sky.gdshader re-derives the same UV as the STARS block and draws the J2000
ecliptic analytically (Meeus 13.4). StarSystem owns `zodiac_*` (persisted in
star_calibration.cfg) and pushes `stars_daylight_reveal` from
`Main.analemma_star_reveal` while analemma_mode is on — it opens the star
night gate, zeroes the sky-glow washout, and dims the dome + sun aureole/glow
by `pow(0.01, reveal)` (deep because sRGB lifts a dim linear sky: a 9 % dome
read mid-grey) but NEVER in `AT_CUBEMAP_PASS`, so ground/ambient lighting is
unchanged. reveal 0 is a byte-for-byte no-op.

**Daylight model (`core/env/daylight_model.gd`, `DaylightModel`) — ONE curve
for the sun, the sky and the ground.** The sunrise used to switch on like a
lightbulb because four different altitude curves ran the lighting: the
DirectionalLight faded in with `smoothstep(-0.1, 0.2, sin alt)` — 26 % of noon
power, pure WHITE, hard shadows, with the disc still 5.7° BELOW the horizon;
the sky shader went from black to full twilight between −7° and +2°; the
ambient ramp was still a third of daylight at −12°; the forest went dark over
its own 4.6° window. Now `main.gd` reads everything off DaylightModel and
`sky.gdshader` carries `daylight_fraction()`, a line-for-line MIRROR of
`DaylightModel.sky_light` (edit both or the ground and the sky darken on
different curves; the selftest pins the GDScript side). Direct beam:
Kasten-Young air mass through the SAME four-term clear-sky transmittance
`SolarIrradiance.dni_clear_sky_wm2` uses for the PV physics, normalised to the
zenith (2.5 % on the horizon, 31 % at 5°, 52 % at 10°, 85 % at 30°), zero
until the refracted upper limb clears −0.9°, times `SUN_ZENITH_GAIN` 1.3 so
the midday look the old high-sun boost gave is preserved. Beam COLOUR:
Rayleigh optical depth relative to green over 0.45 of the excess air mass
(≈2100 K on the horizon, ≈3700 K at 5°, white by 30°), `sun_warmth` scales
it; the light's colour is `_sun_clear_color × _hazard_sun_tint`, so a cleared
hazard restores the altitude colour, NOT flat white (the old code hard-reset
`Color.WHITE`). The moon gets the same extinction + reddening. Skylight:
55 % at sunrise → full by 15° above; `exp(−0.25 · depression°)` below (−6° =
22 %, −12° = 5 %, cut by −21°), scaled by `twilight_length`; it drives the
ambient (`lerp(night, day, sky_light)`), the fog/glow `night_amount`
(`1 − palette`) and the shader's night mix. Vegetation's `night_factor`
follows the BEAM (`1 − smoothstep(0, 0.35, direct)`), not a step at sunset.
⚠ `air_mass()` returns the HORIZON value below 0°: the Kasten-Young fit is
only defined to −6.08° and, evaluated there with the sine clamped, it SHRINKS
again as the sun sinks (12 at −3°), which wobbled the beam and its colour
during the disc rise. Note a player running `ambient_energy_mult 0` (the
author's own prefs at the time) sees the ground lit by the beam alone —
the ambient ramp being wrong was probably why it got zeroed. Verify with the
selftest and `--capture=dawn` (Validation list).

**Horizon + haze settings (Settings → Environment, 2026-10-20).** On a flat
map (Bombay Beach) the terrain's edge meets the sky directly, and the scenes'
sky material paints everything BELOW the line a hard-coded teal
(`horizon_color` 0, 0.5, 0.6) — a dark stripe between the fogged playa and the
sky. `horizon_match_haze` (default on) pushes the FINAL `fog_light_color`
(after the hazard pass) into `horizon_color` every environment update
(`main._push_horizon_color`), so distant ground and the sky under it are one
colour at every hour. New sky uniforms: `horizon_height` (sin elev, + raises
the line — the sun/moon "behind the horizon" test follows it) and a
`horizon_haze` band of horizon colour fading up over `horizon_haze_height`
(0 = the old look); `horizon_blur` is guarded against 0. Previously
hard-coded haze knobs are now multipliers on the time-of-day curve
(`haze_density_mult`, `haze_aerial_mult`, `haze_sun_glow_mult` — all 1.0 =
the built-in look), plus `day_haze_color`, `twilight_cool_bias`,
`late_day_clearing` (UI 0..1 = `pre_sunset_reduction_strength` / 0.00025)
and the day sky gradient (`sky_zenith_color` / `sky_horizon_color` =
`day_top/bottom_color` on the material). All are Main `set_/get_` pairs
saved by SimSettingsController's `[rendering_adv]` loops
(`HORIZON_FLOAT_KEYS` / `HORIZON_COLOR_KEYS`); `HORIZON_HAZE_DEFAULTS` /
`horizon_haze_defaults()` back the page's reset button. The Environment page
also now carries Sun, Twilight, Moon and Night sky (moved from Lighting) and
Fog amount; Lighting keeps rendering (quality, shadows, ambient, glow, AO/GI,
volumetric fog, tonemap, MSAA, god rays). Verify:
`tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/horizon_settings_check.gd`.

**Night-sky look (visual polish pass).** The shader's TWILIGHT/NIGHT blocks are
a solar-DEPRESSION model: `_sunset_amount` is 1 on the horizon and gone 15°
above / 14° below; `_night_amount = 1 − min(daylight_fraction / 0.55, 1)`, i.e.
the DaylightModel twilight envelope (civil twilight still 22 % lit, gone by
−21°). Two older forms, so nobody restores them: ONE symmetric sunset tint from
30° above to 30° below the horizon (afternoon went pale early, midnight stayed
violet) with "night" already 70 % black with the sun ON the horizon (dim
sunsets, purple night); then a `smoothstep(−0.12, 0.03)^1.6` that was black by
−7° while the ground ambient was still two-thirds of daylight (dusk read as a
switch). The star washout reads the WHOLE sky's luminance, so the twilight
glow hides the faint stars exactly as the moon does. The dark sky is a
near-black blue-grey gradient (`night_top/bottom_color`, no purple) plus three
separate user light sources: airglow band (`airglow_strength/color`), a
light-pollution dome (`light_pollution/_color`) and moonlit sky
(`moon_sky_glow`, from the moon's phase × altitude); their luminance feeds
`stars_wash`, which raises the star background cut so a full moon hides the
faint stars and the Milky Way like it does outside. `twilight_drama` scales
the horizon fire band (pushed past 1.0 so bloom carries the glare), the
aureole/glow near the horizon and the Belt of Venus opposite the sun. Star
look: every neighbour tap is in TEXELS (`stars_texel`, pushed by StarSystem
from the texture size, so 8k and 16k render alike); `stars_point_size`
erodes/dilates the discs by a texel; star COLOUR is read off each disc's
fringe (the export clips cores to white) and re-applied to the core's
luminance (`stars_saturation`); the map is split by luminance into star cores
(contrast curve) and the diffuse Milky Way, which is sampled through a 4-texel
ring (the export's dithered, block-compressed band SPECKLES at one texel) with
its own `milkyway_gain/saturation/tint`. Texture quality: Settings → Stars
offers the 16k map (`assets/sky/starmap_equirect_16k.png`, same pipeline,
BC7 = 128 MiB VRAM) when it is shipped; `StarSystem.texture_quality`.
Planet labels: `PlanetSystem.planet_labels_mode` (0 off / 1 on highlight
within 3° of the view centre / 2 always; sky-gated on the sun below +3°),
a CanvasLayer of Labels projected through the active camera, persisted with
the planet prefs. Knobs live on Main (`twilight_drama`, `airglow_*`,
`light_pollution*`, `moon_sky_glow` → `_update_celestial_sizes`) and persist
through `SimSettingsController.apply_sky_setting` / `[rendering_adv]`.

## Time & simulation (timecode, modes, reversibility)

**Timebase.** `core/celestial_clock.gd` (owned by Main as `clock`) is the
authoritative, reversible clock. `main.gd:_process` does
`day_time += delta * time_scale` (time_scale may be negative → time runs
backward; the `day_time` setter rolls the date both directions). The canonical
timecode is **absolute hours since year 1 Jan 1 00:00**:
`clock.get_absolute_hours()/set_absolute_hours()` (passthrough on main.gd). Sun,
moon, sky, and `WeatherService.sample()` are pure functions of the clock, so they
scrub correctly in both directions for free.

**Modes.** `TimeDirector` autoload owns mode + NOW + playhead + provenance:
- `Mode { LIVE, PLAYBACK, SIMULATE }`, resolved by: history latch (PLAYBACK) →
  explicit user pin (`set_explicit_mode`/`clear_explicit_mode`) → legacy
  heuristics. `now_abs_hours` = real wall clock; `playhead_abs_hours` = sim time.
- `provenance_at(abs_hours) → {REAL, OBSERVED, PROJECTED, RECORDED}` for UI.
- `core/sim_mode.gd` is now a thin shim delegating to TimeDirector (its public
  API and `Mode {LIVE,SIMULATE,HISTORICAL}` enum are unchanged for consumers).

**Reversible battery (the key invariant).** The battery is a path-dependent
forward integrator (efficiency losses + 0/100% + SOC-floor clamps) and cannot be
reversed analytically. `core/energy_timeline.gd` (`EnergyTimeline`, owned by
SolarUI) samples SOC + solar/aux/load into a fixed-step buffer keyed by absolute
hours. `solar_ui.gd:_update_battery` integrates **forward** (record_step) and
reads SOC **back** from the buffer when scrubbing, so the battery "uncharges"
exactly along the curve it charged. **HA SOC only drives the battery in LIVE mode**
(`SimMode.is_live()`); in SIMULATE/PLAYBACK the timeline owns SOC so scrubbing
rewinds it (otherwise a live HA reading pins the battery and it never uncharges).
While LIVE, the measured SOC is mirrored into the buffer
(`EnergyTimeline.record_measured`) so the user can scrub back through real recorded
history. Daily scoreboard counters are derived queries
over the buffer (`_recompute_scoreboard_from_timeline`); the 24h graph
(`_update_solar_history`) and load line are buffer views. The pure step math
(`EnergyTimeline.step_soc`) mirrors the old `_integrate_power_step`. Determinism:
the synthetic-weather fallback is seeded by absolute time (`_det_unit`), never
`randf()`, so replays reconstruct exactly. On load, `energy_timeline.clear()`
re-anchors at the loaded SOC.
⚠ **A cached FUTURE is a prediction, not history** (fixed 2026-10-15, Mt
Vernon: "2.5 kW load, SolarUI says deficit, the battery never leaves 100 %").
After any backward move of the clock (timeline scrub, a tutorial / Lab clock
restore, a date jump) the buffer holds samples ahead of the playhead, and
moving forward inside them used to be a pure read — so a load switched on
since then never reached the SOC until the playhead passed the end of the
cache (up to 14 days), while Net (live inputs) read a deficit.
`_update_battery` now compares the cached sample's net against the live net
when moving forward inside the cache; past `BATTERY_CACHE_DIVERGE_KW` it
`truncate_after`s at the previous tick and integrates live from there.
Backward reads are untouched. Also: SolarUI reads the sun from
`clock.get_sun_direction()` (`_sun_direction`), not the DirectionalLight —
Main stops re-aiming the light while the graph hides the 3D world, which
froze solar output for as long as the graph was open.
Verify: `tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/energy_balance_probe.gd`.

**UI.** `timeline_ui.gd` replaces the 24h slider with a custom-drawn multi-day
absolute-time track (`_draw_track`/`_on_track_input`, ±~3.5 days, dead-zone
scrolling) with a white **NOW** marker, an amber playhead, provenance color bands
(teal=observed, lavender=projected, green=recorded), and **mode + data chips**
(`_update_mode_chips`). Dragging calls `set_absolute_hours`.

Self-test (`source_physics_selftest.gd`, now 97 checks) covers abs-hours
round-trip, reversible SOC (forward-then-rewind), provenance boundaries, the
unix↔abs bridge, ObservedSeries resampling, and batch-render determinism.

## Observed-vs-simulated comparison (NLE batch render)

Import a real HA datastream and compare it against a deterministically
re-simulated curve over the same dates — the realized "pre-render a day/week"
feature built on the EnergyTimeline + `set_evaluator` substrate.

**Data alignment.** `core/celestial_clock.gd` adds pure helpers
`unix_to_abs_hours()` and `abs_hours_to_julian_day_utc()` (+ `abs_hours_to_date()`)
so CSV wall-clock timestamps land on the same absolute-hours axis as the sim, and
a render at the CSV's dates pulls the real archived weather for those days.

**Observed track.** `core/observed_series.gd` (`ObservedSeries`) resamples the
CSV's role timelines (battery_soc%→kWh, solar/load W→kW) onto the EnergyTimeline
grid via zero-order hold; `sample_at`/`integrate_channel` mirror EnergyTimeline.
`core/csv_history_player.gd` gains a **clip mode** (`load_clip()`): parse-only, no
world-clock takeover, emits `clip_ready`; `build_observed_series()` produces the
ObservedSeries. SolarUI owns its own `ObservedClipPlayer` child for imports
(separate from CsvPlaybackUI's replay player).

**Evaluator + render.** `solar_ui.gd:evaluate_inputs_at(abs_hours)` is a *pure*
function of time (no scene sun, no HA overrides): solar via Meeus SPA + the shared
`_compute_solar_kw` POA core + WeatherService sampled at that instant; load is
either the observed CSV load (default — isolates solar/weather-model error) or a
deterministic `_modeled_load_at` (baseline + time-scheduled lights), per the
`RenderLoadMode` toggle. `core/batch_renderer.gd` (a SolarUI child Node) drives
`EnergyTimeline.fill_forward_chunk()` ~240 steps/frame into a dedicated
`_sim_series`, anchored at the observed SOC so divergence is pure model drift.

**NLE timeline UI.** `timeline_ui.gd`'s track grew to stacked lanes: the time
ruler/playhead (lane 0) plus an amber **Observed (CSV)** clip and a cyan
**Rendered (sim)** clip (with a render-progress fill). Shift-drag sets the
render in/out selection (defaults to the full clip). A controls row adds
**Import datastream…**, **Render selection**, the **Load: CSV/Modeled** toggle,
and **Compare**. `BAR_HEIGHT` is 164 (scene `TimelineUI` offset_top/min-size match).

**Split-screen compare: RETIRED (2026-10-22).** SolarUI no longer feeds the
"I" `ProjectionCanvas` (`set_compare_active` / `_tick_compare_feed` are gone);
⧉ opens the Compare window below. The canvas's dashboard half went with the
projection split (next section).

## Projection mapping (scenes/ui/projection/, 2026-10-23)

The projection canvas (**I**) and the POV warp (**Z**) are projector outputs,
nothing else. Until 2026-10-23 the canvas was also a 2×2 "sim vs live"
dashboard whose bottom half showed placeholder numbers, a fabricated history
curve and device rows nothing fed; that is gone (the Compare window does the
job with real data).
- **`ProjectionWarp`** (`projection_warp.gd` + `.gdshader`) is the ONE
  corner-pin, used by both views. The source texture is cut into 1, 2 or 4
  regions; each is drawn into a quad whose corners the player drags. It is a
  true PERSPECTIVE pin: `homography(quad)` (Heckbert 1989) solved on the CPU,
  its inverse a `mat3` uniform, mapped per pixel in the shader (outside the
  quad discarded, black backdrop). The old Polygon2D quads were two affine
  triangles and bent the image along the diagonal on any keystone. A Basis
  goes into a `mat3` column for column (pinned in the selftest).
- Corners are stored as FRACTIONS of the control, so a resize keeps a
  calibration on the wall (`[warp] version 2, quads, q0..`). A v1 file
  (absolute pixels, TL/TR/BL/BR) migrates on load, divided by its saved
  `canvas_size`; the canvas reads its old `projection_canvas_warp.cfg`
  through `load_config(legacy_path)` and saves to `..._warp_v2.cfg`.
- Keys act only while the host is visible (the canvas) or the warp is up
  (POV, `key_gate`): `toggle_projection_warp` F9 (canvas only — POV has Z),
  `toggle_projection_calibration` F10, `reset_projection_warp` F8, Enter
  save, Tab next quad, Esc done. They used to fire while the canvas was
  hidden, and both views fought over F10.
- Handles draw on a child layer: a parent's `_draw` is UNDER its children,
  so drawn on the warp control they were hidden by the quads. The panel moves
  to mid-screen when a corner is under its top-centre spot.
- **The canvas** (`ProjectionCanvas.tscn`, `projection_canvas.gd`, ~1300
  lines from 2400): left = sim camera (free / synced, click to fly), right =
  live camera feed (OBS virtual camera preferred) or a timelapse video locked
  to the sim clock (the timeline's VID lane, 📹 📷 ⏲). Two warp quads. Its
  SubViewports render only while it is shown (they were UPDATE_ALWAYS for the
  life of the scene, hidden or not), and it claims the HUD hidden while up.
- **The POV warp** (`pov_warp_overlay.gd`): a mirror of the player camera in
  four quads; its viewport renders only while warped; made on demand on maps
  without one (`Main.ensure_pov_warp_overlay`), as the canvas is.
- Gates: `scenes/ui/projection/projection_warp_selftest.gd` (offline) and
  `tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/projection_warp_probe.gd -Label projection`.

## Sim vs reality: the Compare window (core/experiment/, 2026-10-22)

Plan: `~/.claude/plans/i-want-to-be-polymorphic-island.md` (A/B experiments;
landed: calibration, automations in sim time, forks + A vs B, resources
in the runs, would / did save; next: the projection split). ⧉ on the
timeline (`Main.open_compare_view(selection)`, `scenes/ui/experiment/
compare_view.gd`, a `ModalFrame`) simulates THIS world over a past span and
lays it over what really happened, with error numbers.
- **Isolated runs.** `ExperimentEnergyRun` steps its own `ExperimentSeries`
  on a frame budget (6 ms) from `inputs_at(abs_h)`; same battery as SolarUI
  (`EnergyTimeline.step_soc`), SolarUI's AC hysteresis (shed at
  max(MIN_BATTERY_PERCENT, battery_soc_shutdown_pct), back at
  battery_soc_resume_pct) and its battery-full curtailment (raw_kw keeps what
  the array could make). Nothing live is touched: no clock claim, no model
  write, no SolarUI state (the probe pins user_rev, clock and battery).
- **Each sim is an `ExperimentWorld`**: its OWN copy of the graph
  (`GraphModel.deserialize(live.serialize())`; loads start as the player
  REQUESTED them — the run sheds them itself), the graph's automations
  running on it in sim time (`AutomationSim`, below, via
  `ExperimentEnergyRun.before_step`), and the AC load read off the copy after
  every switch (`GraphAcLoad.compute_watts_offline(model, losses_on)`: on /
  off from specs, scene devices at rated watts, the AC bus assumed on, wire
  losses as the player's setting). Solar = `SolarUI.evaluate_solar_pair_at`
  (public wrapper of `_evaluate_solar_pair`: SPA + weather at the hour +
  panel shade + DC caps). Load "model" or "observed" (the real load
  replayed); aux "held" (today's hydro / wind) or "observed".
  The window lists what the automations switched ("Automations in the sim").
- **Resources in the runs** (`ExperimentWorld.enable_flow(host)`, used by
  every A/B world and the calibration's model-loads sim): the copy gets its
  OWN `ResourceFlowEngine`, `render_step`ped at each run step with the AC
  state the battery had (weather + sun at the instant). Tanks fill and
  drain, processors run / block / starve, siphon and penstock turbines run
  on the copy's ponds and streams. It feeds back: the load is re-read every
  step (a machine draws only while RUNNING), tank levels and node states
  (incl. starved / blocked) reach the automations, and the copy's graph DC
  generation (`DcPowerWiring.sum_graph_dc_generation_kw`, one step behind,
  as the pre-render) joins the battery with the scene's own sources held.
  The host is the live SystemGraphView, asked read-only questions only
  (`get_pond_info` via the loader, `water_feature_supply_for_intake`,
  `stream_pond_inflows` — matched to tanks by id, so a pond only a fork has
  gets no stream); its signals are connected to nothing. Not simulated:
  people (pop-driven habitats bill their authored headcount at the preset
  rates), the graph's wind / hydro ESTIMATOR nodes (held), camp power.
  `resource_summary()`: per tank start / end / lowest fill, hours empty
  (only for a tank wired to feed something) and full; per processor /
  habitat hours running / blocked / starved; totals `tank_empty_h`,
  `machine_down_h`, `machine_run_h` (merged into the energy dict, so they
  are A/B metrics too). The window's "Tanks and machines" table shows both
  versions.
- **Two sims per comparison** when the real load is known: model loads (the
  whole model on trial) and real loads (only solar + battery on trial).
  Both start from the real battery at the span's start.
- **Reality** (`HaHistoryFetch`): the world's live links —
  site.battery_soc / solar_kw / load_kw, falling back to the first battery
  node's soc, the SUM of panel power links, the sum of inverter ac_power
  links; aux = wind / hydro power links. `HomeAssistantService.request_history`
  / `request_statistics` (new, callback-based; a dropped connection answers
  pending callbacks with []) fetch every change (significant_changes_only
  false); where raw history starts late (recorder purge, 10 days by default)
  the hourly long-term statistics fill the gap and the channel says so.
  Units through `HaUnits` + the link's scale / offset / invert. Or the
  imported CSV clip (`ExperimentObserved.from_csv_roles`).
- **One time axis: `SiteTime`.** Unix → absolute hours on the SITE's clock
  via `CelestialClock.zone_offset_hours` (the clock the sun and weather use).
  `CelestialClock.unix_to_abs_hours` treats UTC as local (the old CSV clip
  path) and `HaObservedStore.abs_hours_local` uses the computer's zone — use
  neither for anything compared with the sim.
- **Resampling** (`ExperimentObserved.build`): a state (SOC) is the reading
  held at the sample's start; a flow (power) is the time-weighted mean of the
  held readings over the sample (unknown below half an interval known);
  several entities of one channel SUM (unknown if any is); "unavailable" is a
  gap. Step: 1 min to 2 days, 5 min to 2 weeks, 15 min beyond (max 62 days).
- **Scores** (`ExperimentScore`): `energy()` (made, used, unserved, AC-off
  hours, curtailed, throughput, cycles, per day) and `calibration()` per
  channel: MAE, bias (sim − real), RMSE, r, and on HOURLY means the ASHRAE
  Guideline 14-2014 NMBE and CV(RMSE) (p = 1): good = |NMBE| ≤ 10 % and
  CV ≤ 30 %, fair = within twice that; battery judged by mean error in
  points (≤ 5 good, ≤ 12 fair). A time shift keeps NMBE small and fails CV —
  that is the point of reporting both.
- `ExperimentCompareChart`: four lanes (battery %, solar, load, net), reality
  as a min–max band + mean, sims as lines, TimelineBinning bins, hover values.
- **Automations in sim time** (`power_system/automation/automation_sim.gd`,
  pure): evaluates each item's `specs.graph_automations` (the inspector's
  cards) between two instants. Time / sun triggers fire when their clock time
  is CROSSED in (t0, t1] (`AutomationSim.crossed`), numeric / state triggers
  on entering their range after `for_seconds` of SIM time, conditions at t1,
  `delay` defers the rest of the list (the rule ignores new triggers while
  it waits — mode "single"); a numeric trigger already in range at the first
  step fires, as the live engine's does. The same 1-min and 1-h steps give
  the same switches (pinned).
- **The live AutomationEngine follows the same rules now**: it puts
  `prev_abs_hours` / `abs_hours` (a jump > 2 h or backwards is no crossing),
  `sim_seconds` and `weekday` in the context; TimeTrigger / SunTrigger fire
  on crossing (their ±1 / ±5 min window — stepped over at speed — is only the
  fallback), numeric / state `for` counts sim seconds, and
  `sensor.solar_power` / `sensor.load_power` are in W as the inspector labels
  them (they were kW, so a W threshold never hit). Still open there:
  `DelayAction` does nothing live (`update_delay` is never called).
- **A vs B** (the window's second mode, `AbExperiment`): two versions of
  the world — "This world as it is" (copied at run time) and FORKS — over the
  same span (Next 24 h / Next 7 d from the playhead, Last 7 d, the timeline
  selection, custom), from the battery and tank levels as they are now, each
  an `ExperimentWorld` with its own automations and resources. Scored on a headline metric
  (`AbExperiment.METRICS`; default "Energy the loads asked for" — delivered
  energy is capped by the battery: on Mount Vernon in October a nightly
  2.5 kW shutdown cut demand 420 → 295 kWh a week while delivered moved
  164 → 162 kWh and the difference showed as AC-off hours 102 → 67), with
  every other metric, B − A and the better side, per-day rows and both
  automation logs. `compare(ea, eb, key, better)` calls a tie within 0.5 %.
- **Forks** (`ExperimentStore`, WorldPaths kind `experiments`, so they
  travel with the world): named copies of the world's graph
  ({id, name, note, created_unix, graph}) plus the window's `last` choice.
  Made / renamed / deleted in the window; EDITED in the real graph editor:
  `Main.edit_experiment_fork(id)` → `scenes/ui/experiment/fork_edit_bar.gd`
  → `SystemGraphView.begin_fork_edit / end_fork_edit` (the tutorial
  sandbox's pattern: the real state waits in `_fork_pre_state`,
  `collect_save_state` returns it so no save can capture the fork, autosave
  off, a (non-exclusive) clock claim "fork_edit" at time_scale 0, the live
  AutomationEngine stopped, the HA linker suspended, the world's automations
  unregistered and re-registered; the battery kWh is put back and a
  capacity difference is treated as a restore, not new hardware). A game
  load meanwhile emits `fork_edit_interrupted(id, graph)` and the bar saves
  the fork. Done writes the fork back and reopens Compare on it.
- **"A/B this automation"** (chart icon on each inspector automation card,
  `Main.ab_test_automation(item, auto_id)`): a fork named
  `Without “<alias>”` (refreshed from the world if it exists) and Compare
  in A vs B over the next week, run at once.
- **"Would a change have saved?" / "Did a change save?"** (the window's
  third and fourth modes; IPMVP Option D, calibrated simulation). On a past
  span with real data (HA or the CSV clip), `CalibrationExperiment` runs the
  two chosen setups (opts `variants`: reality's setup first, then the other)
  with model loads, their automations and resources, hydro simulated, from
  the real battery at the start. `ExperimentScore.counterfactual(obs,
  sim_real, sim_other)` = the real readings + (other − reality) per channel
  (flows ≥ 0, battery inside its capacity, unknown where either side is):
  only the sims' DIFFERENCE is used, so their absolute error largely
  cancels (pinned: a constant sim error gives the same savings).
  `ExperimentScore.savings` totals real vs estimated energy used / solar /
  aux and the battery at the end. "Would" = reality + the change; "did" =
  reality had the change, the estimate is without it. The banner states the
  saving and, when the battery rather than the loads limited what was used
  (the sims' demand moves ≥ 2× more than delivered energy), where it really
  shows (asked-for kWh, AC-off hours). The notes say how far to trust it:
  how well the sim of reality's setup matched (G14 NMBE / CV(RMSE), battery
  points). Probe: the estimate without the change equals the fork's own sim
  to 0.01 kWh when reality IS the world's sim.
- ⚠ **Never put absolute hours in a Vector2.** Its components are float32,
  which holds ~1.8e7 only to the nearest 2 h. Found in the Compare spans (a
  23:00 start ran from 00:00) and then everywhere a pair of hours crossed an
  API: the timeline's `_track_window()` (the whole track — playhead, NOW,
  clips, lanes, keyframes — was positioned from a start rounded to 2 h, so
  panning moved it in 2-hour jumps), `SolarUI.get_selection_abs /
  get_observed_range_abs / get_rendered_range_abs`, `SimRenderer
  .active_range`, `TerrainLoader.get_climelapse_range_abs`,
  `ProjectionCanvas.get_video_clip_range_abs`, `HaObservedStore.range_of`
  (+ the linker's `observed_range`), the video-export dialog's selection
  and the microclimate sweep's cache key. All return / take
  `PackedFloat64Array([a, b])` now ([NAN, NAN] = none). Also: never compare
  absolute hours with `is_equal_approx` — it is relative (1e-5 ≈ 177 h).
  Gate: `tools/checks/timeline_abs_precision_probe.gd` (an odd-hour
  selection exact in every consumer).
- **HA links survive the bootcamp now.** `HAEntityLinker.set_suspended`:
  the tutorial sandbox's cleared graph used to make the linker prune (and
  save away) every node-level link of the world — once from the model's
  "deserialize", once from the view's deferred `refresh_subscriptions`.
  Suspended, it neither prunes, writes live badges nor applies readings;
  both sandboxes suspend it.
- ⚠ A Node that defines `_process` is processing from the start: the
  experiment "finished" on its first frame, before the history arrived, until
  `_ready` turned it off. Any new background stepper needs the same.

## Site Report (interactive infographic)

Full-screen modal giving a **deep single representative year, month-by-month**
site analysis: solar radiation resource (GHI), PV potential of the *current graph*,
windrose + wind energy potential, rainflow/precipitation, temperature bands, and
hydro potential (when the graph has hydro). Opened by the timeline toolbar **📊**
button (`timeline_ui._on_site_report_pressed`, lazy-instantiated like the Record
Book) or the `toggle_site_report` input action (**K**, routed via
`main._unhandled_input`). New files under `core/report/` + `scenes/ui/`:
- `core/report/site_report_metrics.gd` (`SiteReportMetrics`, pure static): calendar
  ↔ absolute-hours (same proleptic-Gregorian epoch as `CelestialClock`, so it feeds
  `SolarUI.evaluate_solar_at`), 8760-hour monthly aggregation (sum/mean/min/max,
  wet-day counts), windrose sector binning, capacity factor, peak-sun-hours.
- `core/report/site_report_data.gd` (`SiteReportData`): typed container (12-length
  monthly arrays + annual scalars + site header + `capacity_signature`) with
  `to_dict()`/`from_dict()` JSON round-trip.
- `core/report/site_report_builder.gd` (`SiteReportBuilder extends Node`): async,
  chunked (`DAYS_PER_CHUNK` days/frame, mirrors `batch_renderer`) engine. Samples
  `WeatherService` for radiation/wind/precip/temp, reuses `SolarUI.evaluate_solar_at`
  for PV yield (graph-synced capacity/tilt/azimuth), enumerates graph `wind`/`hydro`
  items via `model.get_items_in_scope("root")` → `WindTurbineSource`/`HydroSource`
  adapters. Uses `WeatherService.effective_year(sim_year)` for the representative
  year. Caches to `user://site_reports/report_v1_<lat>_<lon>_<year>.json`, keyed by a
  `capacity_signature` (site + PV + turbine/hydro specs + weather source) so an
  unchanged report re-opens instantly and a graph/site change invalidates it.
- `core/report/site_report_selftest.gd`: offline deterministic selftest (57 checks:
  abs-hours vs CelestialClock, windrose bins, monthly aggregation, wet days, capacity
  factor, data round-trip, and a UI-script compile smoke since the panel/charts have
  no `class_name`).
- `scenes/ui/site_report_charts.gd` (`SiteReportCharts`, static): `UITheme`-styled
  drawers — `draw_monthly_bars`, `draw_temp_band`, `draw_windrose` (+ `windrose_sector_at`).
- `scenes/ui/site_report_panel.gd`: dim-backdrop centered modal (record_book pattern),
  scrollable cards (solar/PV/windrose/wind/rain/temp/hydro) with per-month hover, a
  compute-progress overlay, `Recompute` button, and `CursorController.request_modal`.
  Ensures weather coverage (fires `request_weather`, waits on `weather_data_ready`
  with a timeout) before building; offline → PV still computes via clear-sky geometry.
First-draft limits (stated in the panel footnote): single representative year (no
multi-year/decade or `ClimateProjectionService` scenarios yet), PV uses SolarUI's
global tilt/azimuth and ignores 3D shading (live-only), no PNG export.

## Linkage Lab (scissor-linkage designer port, `core/linkage/`)

Native Godot port of the LinkageLab three.js web app (parametric folding
deployable structures via compound scissor mechanisms). **N key** or the unified
library "Linkage Lab…" entry opens the full-screen designer modal. All solver
math is **inches internally** (pinned 1:1 against JS reference values), converted
to metres (×0.0254) only in the mesh builder.
- `linkage_params.gd` (`LinkageParams`, RefCounted): full parameter model; `to_config`/
  `from_config` round-trip the web app's v30 config JSON (structure/mode/foldAngle/
  panels/supportBeams/visibility) so web designs load directly and vice-versa.
  The round trip is LOSSLESS (2026-10-12): every key the typed fields do not
  emit (`buildSteps`, `coverings`, `floor`, `shadeCloth`, `mode.radialArray`,
  newer panel/cost keys, the camera, …) rides `extra` and is merged back by
  `to_config()`. Typed fields win. `DERIVED_EXPORT_KEYS` (`geometrySnapshot`,
  `summary`, `handoff`, …) are dropped. `name`/`designName` → `design_name`.
  A port that starts modelling a key takes it over just by emitting it.
  Parity status, the five shipped JS presets (`presets/ll_*.json`) and the
  fixtures: `plans/LINKAGE_PARITY.md`.
- **Coverings, raised floor, shade tarps (A4, plans/LINKAGE_PARITY.md).**
  - `LinkageEnclosure` is the ONE aggregator for `part_data`, the builder
    and the BOM: deck, then coverings, then tarps (the web's order; the
    walls can start on the deck, the tarps sit above the wall bands).
  - Records are snake_case covering dicts keyed `wall:s<span>:<band>`.
  - Floor beams are `_make_beam` records (`floor-beam*`) drawn in their own
    `FloorBeams` MultiMesh. Coverings are keyed MeshInstance3Ds under
    `Coverings`, staged by part state like every other part.
  - BOM gains floor rows and an ENCLOSURE section; the Build Guide writes
    the SVG cut files.
  - ⚠ The project treats "type inferred from Variant" as an ERROR, and
    `Callable.call(...)` returns Variant: `var x := some_callable.call()`
    fails to compile, and every script that depends on that file then fails
    with it. Call the static function directly.
- **Radial array + sequential fold (A3, plans/LINKAGE_PARITY.md).**
  - `LinkageRadialArray` is the JS radial-array.js. The plan is measured on
    the DEPLOYED pose and cached per design. `apply(plan, geo, slot_geo)`
    copies every part list into each visible slot, IN SLOT ORDER, so part
    keys never depend on the fold.
  - `part_data`, `drill_solve` and the builder all apply it.
  - `LinkageBom.compute` = one structure (`per_structure`) ×
    `structure_copies` (radial visible × arch tunnel segments).
  - `packed_spec_for` ships one bundle per copy (`count`).
  - `deployed_panel_summary` counts every copy.
  - `LinkageFoldSequence` (`mode.sequentialFold`): the fold angle becomes a
    master progress over the copies, centre first. The builder solves once
    per distinct angle (≤3). Arch tunnel segments still fold together.
  - Lab: the "Radial Array" sidebar group.
- `linkage_part_keys.gd` (`LinkagePartKeys`, port of part-keys.js): the web's
  stable part keys (`beam:vertical:a0:m2:s2:B:L1`, `joint:a0:m0:top:inner:cap`,
  …) and selectors, so a LinkageLab build step names the same part in the game.
  `part_data(p, fold)` applies the web's hardware representation switch
  (detailed assemblies replace brackets/bolts/washers) — the SOLVER keeps
  emitting every simple bracket/bolt because LinkageHwPlacement seats on them.
  The solver now stamps `layer_index` / `ring` / `role` / `cap` and emits
  `washers`; `LinkageStructureBuilder.set_part_state(key, {visible, offset})`
  hides or moves any drawn part by key (washers are drawn now too). Keys are
  pinned == JS per preset (`_test_part_keys_parity`).
- `core/linkage/build/` (plans/LINKAGE_PARITY.md A2): `LinkageBuildSteps` (port of
  build-steps.js — steps are camelCase CONFIG data in `extra["buildSteps"]`,
  `p.get_build_steps()/set_build_steps()`; `generate_for(p)` == the web's
  Auto-generate), `LinkageBeamHoles` (getBeamBoltIntersections + the drill
  solve), `LinkageBuildOps` (the place/cut/drill/fasten drivers as pure
  functions of progress — what the Lab player and the NPC build timeline both
  read). `LinkageGeometry.reciprocal_support_bolts` ports the rcp-ring /
  rcp-cross bolts OUTSIDE the solver's bolt list (counts/BOM/packing
  untouched). ⚠ `ease` is a Godot builtin (two args) — a one-arg static named
  `ease` fails to parse.
- **Fabrication tools + the figure's hands (swarm B1/B2).** `FabToolCatalog`
  (`core/fab_tools/`): circular saw, drill, impact driver, wrench, mallet,
  clamp — procedural primitives in metres, each with `grip` / `grip2` / `tip`
  sockets (Marker3D children + meta) and a spin part; a GLB + sockets JSON in
  `user://fab_tools/<id>.*` overrides one. HAND FRAME (every grip is written in
  it): palm centre at the origin, the handle along the hand's X, the forearm
  leaving along +Y, the palm facing +Z. `NpcSimpleFigure` gained `Wrist0/1`
  (+ a `ToolMount` at the palm) and ONE layered pose path: procedural → mo-cap
  spice → `set_clip(NpcAnimClip, t, w)` → `set_hand_target(i, palm_world)` /
  `set_foot_target(i, ankle_world)` IK — the procedural pose is saved after its
  step and restored before the next whenever any layer ran, so layers never
  feed the easing. `attach_tool` hangs a tool off the wrist (moves WITH the
  hand); a tool that follows its op's path (LinkageBuildOps) is placed in the
  world and the hands IK to its grips instead. Clips: `core/population/anims/`
  (shipped) + `user://npc_anims/` (the player's, wins). ⚠ A pistol grip is
  VERTICAL — its hand X runs up the grip; a socket written as if horizontal
  wrapped the arm round the drill (`fab_pose_diag.gd` is how that showed).
- **NPC animation editor (swarm B3, `scenes/ui/npc_anim_editor.gd`).**
  - Opened from `Main.open_npc_anim_editor(clip_id)` (its own CanvasLayer at
    `LAYER_MODAL + 2`, above the Lab) or Settings → NPC → "Animation editor…".
  - The studio plays the clip in an op CONTEXT (`FabContextRig`: the
    canonical bench / beam / post, the tool on the SAME `LinkageBuildOps`
    timing the swarm uses), with the hands IK'd to the tool's sockets.
  - Edits go through `NpcAnimClip`'s helpers (`set_joint_at`, `remove_at`,
    `pose_at` / `paste_pose`, `mirror_pose`). Only the edited joint's TRACK
    changes.
  - The gizmo is a `LightGizmo` in local space.
  - A free hand's orange IK ball bakes the arm solution into shoulder + elbow
    keys.
  - Saves to `user://npc_anims/`; "Revert" deletes the user copy.
  - ⚠ The camera is placed from LOCAL transforms (`Basis.looking_at`): it is
    built before the studio is in the tree. `look_at` there fails and leaves
    the camera unplaced, so every click ray misses. The `animeditor` capture
    is what caught it.
- **Build timeline (swarm B4, `LinkageBuildTimeline`).** A build sequence
  becomes a crew schedule with NAMED workers: jobs per beam at the bench (cut,
  drill), per step (place; per panel), per JOINT (fasten), the lift from the
  parked spot (quorum `ERECT_MIN_WORKERS`, clamped to the crew) and the deploy
  (a view step that opens the fold). Workers walk at 1.3 m/s, carry beams to
  the structure, hold saw/drill stations. `state_at(tl, t)` is pure: workers
  `{pos, face, activity, clip, tool, u}`, parts `{visible, offset}`, `joints`
  (hardware keyed by joint, for a renderer that draws it its own way) and
  `fold_deg`. ⚠ `_resolve_parking` used to call `compute_displacement` (which
  replays every earlier step) once per JOB — 2 s of a 2.2 s SOAK plan; it is
  one pass over the steps now.
  ⚠ The solver chains the modules from module 0 AT the origin, so the origin
  is a point on the ring's EDGE, the frame's `max_rad` is measured from there
  (≈ the diameter), and the ring's middle MOVES as it folds. The plan measures
  circles, benches and "outside" from `ring_footprint` (the parts' middle +
  radius) instead: each assembly job carries the ring it is worked round
  (`job["ring"]`: the half-folded pose before the deploy, the open ring after,
  `ring_union` of both for the deploy itself). Centred on the origin, the
  deploy and lift circles stood off to one side of the structure (pinned by
  `_test_ring_centre`).
- **Build site (swarm B5) — RETIRED 2026-10-27.** `LinkageBuildSite`
  (its own crew of IK'd figures at saw / drill benches over
  LinkageBuildTimeline) was replaced by the shared crew build site
  (`PalletRackBuildSite`; see "Crew builds of Linkage Lab structures" in the
  deploy schedule section). LinkageBuildTimeline stays: the build guide's
  "crew of 9" summary and its selftest.
- **Lab step player (A5).** `LinkageStepScene` (pure frames) +
  `LinkageStepPlayer` (engine + renderer, sibling of the Lab's builder) +
  `scenes/ui/linkage_steps_panel.gd` (the 🎬 Steps dock under the 3D view:
  list with groups as "× N", transport, scrub, speed, repeats, Follow,
  title / notes / duration, move / duplicate / delete, Auto-generate, Save
  to design, NPC animation…). See plans/LINKAGE_PARITY.md "Step player". ⚠ The
  Lab offsets its builder INSIDE the holder (turntable centring), so the
  player copies `builder.transform` every frame; a sibling that assumed the
  holder frame framed every step on empty ground. ⚠ Hardware the builder
  draws its own way follows its JOINT, and only parts a step introduces
  count. "Unreferenced" washers share joints with brackets, so they had lit
  every joint over the empty site.
- **The crew builds it (B6)** — now the Lab's "Queue build for crew" hands
  the kit to `SiteDeployDirector.queue_item` (the deploy schedule's path);
  see "Crew builds of Linkage Lab structures".
- `linkage_kinematics.gd` (static): closed-form `calculate_joint_positions`,
  `optimal_closed_angle` (ring-closure scan), `min_fold_angle_v_overlap`. Core math
  runs in 64-bit scalars before `Vector2` conversion (Godot vectors are 32-bit).
- `linkage_solver.gd` (static): `solve(params, fold)` — module chaining, zHeight from
  radial span, cylinder→arch transform, `arrayCount` tunnel dup, simplified brackets/
  bolts (visual only). Returns beams (8 corners each) + brackets + bolts + stats.
- `linkage_geometry.gd` (static): canopy area, module frames, radial support (S) beams +
  simplified static RCP beams, and panel layouts (rectangular/radial/spiral for
  cylinder, arch wall-face for arch). `solar_panels()` returns panel dicts (center +
  axes + watts); `total_watts()`.
- `linkage_structure_builder.gd` (`LinkageStructureBuilder extends Node3D`, MODEL_ID
  `"linkage_structure"`): renders the solved frame as MultiMeshInstance3D beams/
  brackets/bolts/supports/panels (cheap per-frame `set_fold_angle` transform rewrites,
  no mesh rebuild). `build_node(spec, name)` is the ModelCatalog factory;
  `refresh_collision_mesh()` builds a hidden "CollisionMesh" MeshInstance3D (box
  geometry from beam/support/panel corners) that PlacedProp consumes for collision +
  pick AABB. `deployed_panel_summary()` = count/watts/per-panel-watts/avg-normal +
  electrical specs at the closed angle (the Phase 6 handoff numbers);
  `orientation_from_normal(n_world)` → tilt + compass azimuth (CelestialClock
  convention: north −Z, east +X, clockwise).
- `linkage_selftest.gd`: offline deterministic (1122 checks) — in CLAUDE.md validation
  list; run `--import` first so class_names register.

**World placement + live folding.** ModelCatalog procedural entry delegates to
`build_node`; the modal's "Place in world" → `PlacedPropService.begin_placement`
(ghost preview at the current fold). `gameplay/linkage_deploy_runtime.gd`
(`LinkageDeployRuntime`, attached by `PlacedPropRuntime._maybe_attach_linkage_deploy`,
node name "LinkageDeployRuntime") owns the in-world fold: **Interact toggles deploy/
stow** with a 3 s animated fold; fold state persists on the prop record
(`linkage_fold_deg`/`linkage_deployed`); collision mesh rebuilds only when motion
settles. Crosshair **click** opens `placed_prop_edit_ui`'s "Edit in Linkage Lab" →
`main.open_linkage_lab_for_prop(prop_id)` (bound modal; "Apply to structure" rebuilds
that prop in place).

**Solar/graph handoff (deploy-gated, idempotent per prop).** On placement and on
"Apply to structure", `PlacedPropService.seed_linkage_graph(main, prop_id)` reads the
builder's `deployed_panel_summary`, rotates the avg panel normal into world space for
real tilt/azimuth, and calls `SystemGraphView.add_imported_solar_panels(count,
watts_per_panel, "Linkage Structure", tag, opts)` where `tag = "linkage_<prop_id>"`
(re-adding replaces only that structure's array). When the structure folds, the deploy
runtime calls `SystemGraphView.set_imported_array_stowed(tag, not deployed)` — a stowed
array keeps its node/wiring but contributes NO capacity to SolarUI
(`_collect_root_array_aggregate` skips `array_stowed` compounds, summary prefixed
"STOWED •"). Deleting the prop (`terrain_loader.delete_prop_by_id`) calls
`remove_linkage_graph` → `SystemGraphView.remove_imported_solar_array(tag)`.
`.gamebundle.json` import still works unchanged (static GLB); additionally, when a
bundle carries the v30 `project` block (`DesignBundle.project_from_bundle`), TimelineUI
offers "Open in Linkage Lab" so the web design becomes live-foldable natively.
**Hardware detail + BOM + build guide (ported 2026-08-04).**

- **`LinkageBom`** (`core/linkage/linkage_bom.gd`, pure static) — the whole
  bill of materials: counts, priced line items, masses, dimensions, actuator
  stroke, panel electricals, per-joint `assembly_steps`, plus `to_csv` /
  `to_json` / `fab_counts`. Counts are derived ANALYTICALLY from the params
  (as `gatherBOMData` does), because the solver only emits bolt geometry when
  "show bolts" is on while the hardware exists regardless; the selftest
  cross-checks the two against each other, which the web app never did.
  **Masses are metric** — `PackedSpec.WOOD_KG_M3` (470) and steel 7850 —
  because `packed_spec_for` now reduces the SAME extracted helpers
  (`bracket_mass_kg` / `bolt_mass_kg`), so a design's shipping weight and its
  BOM weight can never disagree. The web app's lb constants (`woodDensity
  0.018`, 0.5 lb/bracket, 0.01 lb/bolt) are deleted, not converted, so figures
  run ~6% lighter than a web export. **Two deliberate divergences:** stack
  washers are BOM-only and must NEVER be added to `packed_spec_for` (it would
  move the pinned shipping masses in packing_selftest), and cap uprights ARE
  priced here though `gatherBOMData` omits them — flagged in `bom.warnings`.
- **`LinkageDrillPlan`** — hole patterns per beam type. The reciprocal R#/X#
  positions are derived ANALYTICALLY from support-beam geometry rather than by
  porting `rcp-ring`/`rcp-cross` bolts: the web app only uses those bolts as a
  pass-through (it projects each back onto a representative beam), and adding
  ~3n bolts would move `get_stats().bolt_count`, `packed_spec_for`'s mass and
  the crew graph at once.
- **Hardware assemblies** — `LinkageHardware` (data model + `ensure`),
  `LinkageHwLayout` (axis-stack maths: `compute_axis_layout`,
  `assembly_sandwich_gap`, snapping, mirror coupling), `LinkageHwPresets`
  (the 9-part library under `core/linkage/hardware/`), `LinkageHwParts`
  (procedural meshes) and `LinkageHwAssemblyBuilder` (per-part
  MeshInstance3D + StaticBody3D so Godot can ray-pick them — a mesh with no
  body is invisible to the physics server). `params.hardware_assemblies` is
  stored in the web app's own **camelCase** shape, the one deliberate casing
  exception in this port, so unknown keys from a newer web build survive a
  round-trip instead of being silently dropped.
- **`LinkageHardwareSpacing` is THE choke point** where hardware takes over the
  structure's stack gaps and bracket dimensions. `effective_params(p)` is
  called at exactly two sites — `LinkageSolver.solve` and
  `LinkageGeometry.support_beams` — and **returns `p` ITSELF when
  `show_hardware_full_detail` is false**, which is what makes the flag-off path
  bit-identical to the pre-hardware port. ⚠ **That flag defaults FALSE and must
  stay that way**: every pinned reference value in `linkage_selftest.gd` was
  generated by running the real JS app with the `hw*` globals mocked off
  (`tools/linkage_reference.mjs`), so flipping the default silently re-pins the
  entire suite to a different configuration. The selftest asserts the identity
  with `is_same()`, not value equality, so it is protected by construction.
- **Build Guide** (`scenes/ui/linkage_build_guide_modal.gd`, 📋 in the Lab
  topbar or the prop edit drawer) — summary, editable-price BOM tree, weight
  breakdown, cut list, `_draw`-painted drill templates + U-bracket detail
  (`LinkageGuideCharts`), the **assembly sequence** from `bom.assembly_steps`,
  the crew Gantt, actuator and electricals. **Hardware Detail**
  (`linkage_hardware_modal.gd`, 🔩) — assembly tabs, explode slider, per-axis
  part cards with preset pickers, ray-pick + drag-snap along a part's own axis.
  Both live on `UITheme.LAYER_MODAL + 1` so they stack OVER the Lab;
  `CursorController` keeps a modal stack, so Esc pops them one at a time.
- **What makes the hardware preview read correctly** (each of these looked
  "nearly right" while wrong):
  (1) `LinkageHardware.sync_beams_from_structure` re-cuts every preview beam
  from the DESIGN's own members (V-beams FULL length, H-beams the web's own
  8–24″ segment rule — both per `hwSyncBeamPartFromState`); (2)
  `LinkageHwParts.beam_mesh` drills real bolt holes and translates the member
  so its ALIGNMENT hole sits on the stack axis; (3) every part is anchored on
  its axial CENTRE and `flipAxis` is a half-turn about that centre — anchoring
  on the start looked identical for straight parts but slid every flipped part
  a full part-length out of its slot; (4) `part_transform` adds
  `bracket_hole_y` to the cross offset on HORIZONTAL axes, because that chain
  hangs off the bracket's side wall, not its centre; (5) timber uses
  `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS` — plain no-depth alpha stacked every
  internal face of the drilled mesh into a milky mess. **Layout numbers are
  pinned against the REAL web app**: `tools/linkage_hw_reference.mjs` runs
  hardware-detail.js in node (browser + THREE stubs) and
  `_test_hw_layout_reference` pins every default part's base/len/rank/centre
  per axis. The bracket GLB is THREE meshes under differently scaled nodes —
  `glb_bracket_vertices` merges them all (single-mesh loading renders one side
  plate that reads as a stray nut) and `_build_glb_bracket` follows the web's
  exact pipeline: authored glbRotX/Y/Z euler, auto-orient longest-axis-vertical,
  fit to authored height, recentre.
- **The part view IS the in-structure view** (default ON, = the web's
  `hwDetailMode`): the DISPLAY frame is solved with simple brackets/bolts
  hidden (`hideLegacyHardware`), a separate flags-ON solve feeds
  `LinkageHwPlacement` (brackets seat outer/inner joints; the `"center"`
  sub-type bolts seat hCenter at BOTH ring crossings and vCenter at the
  V-stack middle — 56 placements on the stock design), and EVERY detailed
  assembly is stamped at EVERY joint, `exclude_beams` everywhere since the
  real members are the beams. The editable stack sits on the active
  assembly's first seat; other assemblies get pick-body-stripped context
  builders. Traps: a seat must apply
  `LinkageStructureBuilder.ground_offset_for_frame` or hardware floats off
  the frame; a seat carries NO scale (parts bake the inch conversion); camera
  re-aims along the joint's radial FROM THE RING'S CENTRE (the solver builds
  module 0 AT the world origin, so the structure's middle is nowhere near it).
  ⚠ `LinkageHardwareSpacing`'s substituted-params cache is keyed on the FULL
  `to_config()` hash — it bakes every field, and a spacing-inputs-only key let
  the modal's flags-off display solve poison the flags-on placement solve
  (every placement silently vanished).
- **Three placement invariants, all of which RENDER when broken** — the port
  shipped with each of them wrong, and none produced an error, only hardware in
  the wrong place. Pinned by `_test_hw_placement_reference` against
  `core/linkage/testdata/hw_placement_ref.json`; verify visually with
  `--capture=hardware`, whose "anchor error" must read 0.000000.
  (1) **A detailed assembly anchors on `bracket["v_bolt_pivot"]`, NOT
  `bracket["pos"]`.** `pos` is the H-ring pivot where the SIMPLE bracket mesh is
  drawn; `v_bolt_pivot` is the V-stack corner the crossed uprights bolt through,
  a bracket-hole-distance away (solver.js:1987 hands `spec.vBoltPivot` to
  `hwAddAssemblyPlacement`). Reads as "right area, wrong relation to the beams".
  (2) **`compute_bracket_basis` takes a 5th `flip_stack_axis`**, mirroring the
  bolt+beam axes so an asymmetric stack sits on the correct side of the CROSSED
  V-beams. Rule in `LinkageHwPlacement.flip_stack_axis`; ~half of all joints
  flip. Simple brackets pass false, which is why `bracket["basis"]` and every
  value pinned against it are untouched by the parameter existing.
  (3) **hCentre's local +X is the RADIAL direction**, `+Y` the bolt axis
  (`computeHwHCenterBasis`). Yawing that 90° still yields a valid right-handed
  basis, so it renders fine while sending every `crossOffset` tangentially.
  In ARCH mode the port deliberately diverges: the web hardcodes world-up as the
  hCentre stack axis claiming "the H-ring bolt never tilts" (solver.js:2790),
  but the arch's 90° X-rotation makes that bolt horizontal and collapses every
  arch hCentre joint to one ±X yaw — so the port takes the axis from the bolt's
  own transformed direction. Identical in cylinder mode; those rows carry
  `skip_basis: "arch"` in the fixture.
  Also fixed alongside: the cap-upright bracket chord spans the H-ring heights
  (0..top_h), not the upright heights (y_min..y_max) — the web's bracket and
  bolt blocks genuinely differ there (solver.js:2134 vs :2103) and the port had
  copied the bolt block's into both, tilting every cap joint ~half a degree.
- **Editing UX invariants.** Typed offsets are NOT snapped (a drag still is —
  Ctrl suppresses it): the snap-plane list always contains the layout origin, so
  at a 0.18" threshold a typed 0.05 was unconditionally reverted to 0 while the
  field went on showing 0.05, which is the whole of "changing the offsets does
  nothing". Every write echoes the STORED value back via `_sync_field`.
  `axis_pos_from_part` returns the part's axial CENTRE and
  `pos_assembled_for_axis_pos` is its exact inverse (round-trip pinned over
  offset × explode × copy_index × flip) — the drag is that inverse, so a
  half-part disagreement makes every grabbed part jump. Edits are classified by
  `LinkageHardware.edit_requires_respacing`: only sandwich standoffs, centre-slot
  spans and the outer bracket's dims can move the STRUCTURE, so only those pay a
  re-solve (debounced 150 ms, forced on mouse-up); everything else is a
  transform-only `set_part_offset`. Before this, every mouse-motion event ran
  `set_params` + `set_fold_angle` + a full `LinkageSolver.solve`.
  `set_explode`/`set_part_offset` call `sync_instances()` — `set_instances`
  DUPLICATES the stack, so without it the context joints stayed frozen at the
  pose they were cloned at. ⚠ **A clone's `transform` is LOCAL and the builder
  it hangs under is ALREADY seated on placement 0**, so `set_instances` divides
  that seat out (`inv * seat_transform(...)`); assigning the absolute seat
  composes the two and puts joint i at `seat0 * seat_i`. The tell is specific
  and misleading — joint 0 IS the builder node rather than a clone, so the
  FOCUSED joint looks perfect while every other joint on the frame scatters.
  Pinned by the "every context joint lands on its own seat" check (verified to
  fail 15/15 when the inverse is removed). Clones also get
  `material_override = null`: `duplicate()` copies the selection highlight, so
  whichever part was selected when they were minted lit up at every joint.
  **The BRACKET is draggable** — it is not on a stack, so it drives its own
  `posX`/`posY` nudge (Shift for Y) through `refresh_bracket`, which is the same
  field the inspector edits. It used to refuse in silence, and since it is the
  biggest thing on screen it is the part a player grabs first, which reads as
  "dragging doesn't work" rather than "not this one". Declines now say why
  (`_flash_hint`). Verify with `--capture=hardware`, which drives REAL
  InputEvents through the viewport — including via the Lab entry point, since
  opening the editor standalone does not test whether the Lab's own full-rect
  Control swallows the pointer first — and prints DRAG OK/FAIL with the inches
  moved. The part view ghosts the surrounding timber
  (`LinkageStructureBuilder.set_ghost_alpha`, X-ray toggle) because a joint sits
  INSIDE the members it clamps; ghost materials are DUPLICATES, since the
  originals are shared with every structure in the game.
- **The crew plan reads the BOM.** `NpcCrewPlan.linkage_fab_tasks` takes
  optional `bom_bolt_count` (replacing its `modules * 6` estimate) and
  `assembly_steps` (splitting one flat "assemble" task into one per joint, at
  `T_HW_PART_S` per piece). Omit both and the emitted graph is byte-identical
  to before — a frozen literal in the selftest guards that, because
  `npc_population_selftest` and `packing_selftest` both pin schedules over it.

**Deferred:** kinematic RCP continuation solver; PDF export (GDScript has no
jsPDF equivalent — the guide exports CSV and JSON and says so in a footnote).

## Packing data model (core/packing/ — plans/PACKING_PLAN.md, Phase 0 landed)

Every physical thing gets a **packed ("shipping") spec** — dims (m, displayed
ft/in), first-class `mass_kg` (-1.0 = unknown; NAN doesn't survive JSON), form,
stackable/this_side_up flags, `count`, `contains` (Phase 3 nesting), `source:
curated|computed|estimated`. `PackedSpec` (core/packing/packed_spec.gd, pure
static) is the ONE resolver: curated (`packed` dict on a catalog entry/preset
specs, else `CURATED_MODELS`) > computed (procedural builders) > estimated
(type heuristics with cited constants — W/kg panels, Wh/kg by chemistry,
kg/L HDPE tanks, wood/steel densities). Unless `this_side_up`, dims
canonicalize w≥d≥h. **Coverage guard:** every structures/tools catalog model
must appear in CURATED_MODELS / DYNAMIC_MODELS / NON_PACKABLE or the selftest
fails — adding a model forces a packing decision. **LinkageLab computes its
own** (`LinkageStructureBuilder.packed_spec_for`): solved at the EFFECTIVE min
fold angle (`LinkageKinematics.effective_min_fold_angle` — user override else
V-beam contact), never the live slider angle, so an impossible over-fold can't
fake smaller shipping dims; structure only (beams+brackets+bolts+supports),
panels deliberately excluded (they pack as their own stack — Phase 3 split);
cached on the instance keyed on params-minus-foldAngle because the modal's
stats refresh runs per fold tick. The modal's fold-slider FLOOR now tracks
`min_fold_angle()` (was hardcoded 5° — brackets/outer V-beams could be dragged
through each other), with the Min Fold Angle Override spin as the escape
hatch; "Packed Size"/"Packed Wt" stat rows show the result. The BETTER fix —
collision-aware min fold via OBB sweep over solved beams+brackets — is
planned, not built (plans/PACKING_PLAN.md Phase 0.5). **Display:** library item
buttons carry a "Packs to" tooltip; the inspector adds a generic "Packed
(shipping)" section after the per-type match (`_build_packed_section` —
short ft/in form via `format_dims_short`, the narrow value column clips the
metric-parens string; compounds fall back to their `model_id`'s entry so
StarShade super-nodes resolve); the prop-edit drawer shows a 📦 line, with
linkage props computing from the record's live `linkage_spec`. **Phase 1
containers:** `ContainerCatalog` (core/packing/container_catalog.gd, pure
data) holds 16 real target volumes — U-Haul fleet (published interior/door/
payload specs), 5x8/6x12 trailers, ISO 668 20'/40'/40HC, and nestable subs
(GMA pallet, 27-gal tote, action packer, job box, 55-gal drum) — each with
interior dims + DOOR APERTURE (`fits_through_door`: 90° orientations only,
no diagonal tilt; open-top = always passes) + payload; droppable containers
also carry exterior+tare (`packed_spec_for`, `this_side_up` so normalize()
can't lay a container on its side). `CargoContainerBuilder` (procedural
ModelCatalog id `cargo_container`, `container_spec.container_id` picks the
box, default 20') emits ONE MeshInstance3D "Mesh" (PalletRack pattern —
PlacedProp collision/pick just works); dims come FROM the catalog so
geometry and packing data can't drift. Gotcha burned once already: Godot
front faces wind CLOCKWISE from outside — CCW-wound boxes render as culled
backfaces and the whole prop reads as an unlit silhouette. **Phase 2
solver + report:** `PackSolver` (core/packing/pack_solver.gd, pure static,
deterministic) is a greedy extreme-point largest-first heuristic —
deliberately NOT optimal; ~70-85% fill matches a careful human crew, which
is the honest number for a "will it fit" report. Honours container bounds,
overlap, gravity support (floor or ≥50% footprint on a STACKABLE top —
non-stackable tops support nothing), this_side_up (2 yaw orientations vs
all 6), the door aperture, and payload (reported via `payload_ok`, not
blocking — an overweight load still physically packs); also returns
mass-weighted CoM + `com_len_frac` for tongue-weight checks. Test-writing
trap: largest-first placement legally rearranges around a contrived
scenario — unit-test `_supported`/constraint internals directly instead of
trying to force an arrangement through solve(). `CampManifest`
(core/packing/camp_manifest.gd): PURE collectors (`from_graph_items` over
`GraphNesting.walk_items` output — skips virtual/compound/abstract and
resource tanks >20,000 L = site infrastructure, nobody U-Hauls a pond;
`from_prop_records` over `TerrainLoader.placed_prop_records()` — linkage
props compute their honest folded envelope, containers resolve their
variant), qty merge, solver expansion, and `fleet_report` (smallest-first
shortlist). Surfaced as the Site Report "📦 Packing & Logistics" card
(site_report_panel `_refresh_packing_card` — computed LIVE at populate
time, deliberately OUTSIDE the cached report pipeline so graph edits never
serve a stale verdict). **Phase 3 nesting:** `PackTree`
(core/packing/pack_tree.gd) solves boxes-within-boxes INNERMOST-FIRST —
a container unit's contents solve into its ContainerCatalog interior and
the parent scope sees one leaf at the exterior dims with tare+contents
mass; contents that don't fit a sub-container ESCAPE loose into the parent
scope ("(loose from <tote>)") rather than failing the load; qty>1
container units are identical instances (contents solved once, outer units
replicated); MAX_DEPTH 8. `PackDefs` (core/packing/pack_defs.gd) holds
reusable kits as UNIT LISTS — a def is a list, not one root box, because
real kits split across handling units (the StarShade 18-panel stack
physically cannot share the 2' crate with the folded frame; forcing one
root just makes panels escape on every solve). Builtins `starshade_kit`
(crate + strapped panel stack, mirrors the graph's 3-level StarShade
component tree) and `solar_starter_kit`; `{def_ref: id}` splices another
def's units with a visited-set cycle guard; user defs in
user://pack_defs.json (selftest snapshots+restores that file). **Phase 4
Packing Lab (`scenes/ui/packing_lab_modal.gd`, no class_name — ui_compile
sweeps it):** interactive 3D packing modal (own CanvasLayer at
UITheme.LAYER_MODAL, CursorController modal contract) — SubViewport studio
with a cutaway container (camera-facing walls hide themselves per orbit
frame; amber door marker at the HIGH-z end because the solver fills from
z=0, so auto-packs read as loaded nose-first — the order LIFO unpack
warnings will lean on), Auto-pack seeds from PackSolver, manual placement
ghost (ItemList pick → aim → R rotate via _unhandled_key_input so focus
doesn't matter → LMB place; click a placed box to take it back out —
placement/removal are each other's undo). Hand-placement validity calls
THE SOLVER'S OWN `_overlaps_any`/`_supported`/`_orientations`, so the
modal can never teach a packing the report would reject. Sidebar: container
picker (whole catalog incl. sub-containers), kit loader (PackDefs), live
stats (fill %, load vs payload, CoM % toward rear + trailer tail-heavy
warning), door-blocked items tinted red in the list. Opened from the Site
Report packing card ("Open Packing Lab…", preselects the smallest fitting
vehicle) or `--capture=packing`. v1 deferrals: per-site layout persistence,
tote drill-in, LIFO warnings (need deploy-priority data). **Phase 5
PACKED⇄DEPLOYED:** a prop record with `packed: true` builds
`PackedFormBuilder` (core/packing/packed_form_builder.gd — form-styled
crate/bundle/panel_stack/pallet/tank/folded silhouette from the record's
resolved PackedSpec via `PlacedPropRuntime.packed_spec_for_record`, Godot
PRIMITIVE meshes so no winding traps) instead of the model: yaw-only
USER-scale transform (the catalog's GLB unit-compensation `resolved_scale`
must NOT touch a real-metre crate), NO behavior runtimes (trackers animate
geometry that doesn't exist) and NO connection ports. Interact on a crate
unpacks in place (interaction_focus checks the prop's `packed` meta FIRST —
a deployed prop's Interact is already owned by linkage fold/StarShade edit,
so packing must never hijack it; repack lives in the edit drawer's
"📦 Pack up" button, hidden for non-packables). `TerrainLoader.
set_prop_packed(id, bool)` persists + rebuilds + keeps linkage graph
arrays honest via set_imported_array_stowed (unpack restores fold-state
truth). The packed-generation gate: `specs.packed_3d`
(`SystemGraphView.set_item_packed_3d`, called by set_prop_packed for any
prop bound via graph_item_id) zeroes the renewables tick (wind/hydro), the
CSP/heliostat ticks (empty result dict → every telemetry key defaults 0),
and refuses `ResourceFlowEngine._processor_switched_on` — ONE guard there
covers every processor path. Still ungated: individual panel items,
battery/controller electrical presence. **Phase 6 delivery scenarios**
(`core/packing/unpack_scenario.gd`): spawn = REAL prop records (container +
`packed: true` crates staged off the door end) so the Phase 5 loop IS the
gameplay and `progress()` just counts records; builtins `starter_camp` /
`starshade_kit` (linkage crate carries a real default v30 design); Packing
Lab "🚚 Deliver kit to site" button (14 m ahead, door toward player;
disabled without a TerrainLoader) / loader `deliver_packed_kit`.
**Emergent group-labor groundwork** (`core/population/npc_haul.gd`,
`NpcHaulModel`, pure static): round-trip vs bucket-brigade throughput from
first principles; `best_plan` picks the winner — the strategy FLIP with
crew density and the saturated brigade's route-length independence
(throughput → 1/t_handoff) are pinned as selftest properties, surfaced in
the Lab's delivery crew readout, and bridged to the chore board via
`chore_spec`. **Pit-crew scheduler** (`core/population/npc_crew_plan.gd`,
`NpcCrewPlan`, pure static): compound-task graphs ({work_s person-seconds,
min_workers = barn-raising threshold, max_workers, deps}) scheduled by
event-driven critical-path-first list scheduling with malleable
reallocation at every completion event. Selftest pins the classic
emergent facts: makespan ≥ max(critical path, total/N), more hands never
hurt, flatline at the critical path once parallelism exhausts, min-crew
gates block AT the blocking task (blocked_id). `linkage_fab_tasks` builds
the swarm-manufacturing DAG from a design's REAL solver part counts
(cut → drill → assemble ∥ brackets → bolt → fold-test → raise min-6 →
panels). Bolts come from `LinkageBom.fab_counts` when a bill of materials
is available; the `modules * 6` estimate survives only as the fallback for
hand-authored counts (the solver emits bolt GEOMETRY only when show_bolts
is on, but the hardware exists regardless). With `assembly_steps` present
the flat "assemble" task splits into one per hardware assembly, priced at
`T_HW_PART_S` per piece — the payoff of porting the hardware editor.
`recommend_crew` = "bring 9, not 40";
`timeline_text` = ASCII Gantt for build docs; `chore_specs` bridges a
schedule onto NpcChoreBoard (depends_on/min_workers carried as groundwork
for a dependency-aware board). Surfaced LIVE in the Linkage Lab stats
block ("🔧 Fabrication …", cached on part counts — recommend_crew sweeps
crew sizes, not per fold tick). Full vision: plans/PACKING_PLAN.md Phase 6.5.
**Deliveries stow INSIDE the container (Round 3).**
`UnpackScenario.stow_plan(scenario_id)` resolves each unit to a PackedSpec
(`LinkageStructureBuilder.packed_spec_for` for `linkage_default`, else
`PackedSpec.for_model`), **forces `this_side_up` on every item** — the solver
otherwise returns all six axis permutations, but a spawned crate is a BoxMesh
with yaw and nothing else, so only `(w,h,d)` and `(d,h,w)` are renderable —
and runs `PackSolver.solve`. `spawn()` maps each placement into world space
(solver `x` = interior width → container-local +X = world `side`; `z` = load
length with the DOOR at high z → world `fwd`) and sets **`y_offset = pos.y`
exactly**: `PackedFormBuilder` puts a crate's origin at its own floor and the
container's floor is local Y=0, so no deck fudge. Stowed crates carry
`stowed_in` + `unload_rank` + `collision_enabled: false`; anything the solver
cannot fit falls back to the pre-v3 door stack so an oversized unit degrades
visibly. `crate_ids` is returned in **LIFO order** (highest top first, then
nearest the door), so every consumer inherits it — the brigade's stage-effect
index IS its order, and round-trip rows take an ascending priority from the
same sort. Two rules keep it honest: **`move_prop` always clears `stowed_in`
and puts `y_offset` back to 0** (moving a crate is what un-stows it, whether a
chore effect or a player drag), and **`set_prop_packed` refuses to unpack a
stowed crate** ("unload the delivery first") — you cannot erect a shiftpod
inside a shipping container. Note `PlacedPropLayer.update_prop` treats a
`null` patch value as an ERASE: readers do `str(rec.get(k, "")).is_empty()`,
and a stored null reads back as `"<null>"`, so a stale `stowed_in` silently
blocked an erect-phase deploy until this was fixed. The container mesh is a
solid box with no cavity, so the stack is invisible in-world — the Packing
Lab (`--capture=packing`) is its visual surface.
Selftest: `core/packing/packing_selftest.gd` (511 checks; --import first).

## NPC population simulation (core/population/)

**The master switch: Settings → NPC → "Simulate & draw NPCs"**
(`NpcDisplayPrefs.npcs_enabled`, `npc_display.cfg` key `npcs_enabled`,
default on) — for site analysis with none of the people's cost. Off, the
GATE IS IN SystemGraphView, never in the bridge: the ambient tick skips
`bridge.tick` and the per-frame `service_frame` slices, `_ensure_npc_host` /
`_ensure_crowd_renderer` free both visual layers, `_suspend_npcs` (edge-
triggered) clears every habitat demand override so pop-driven habitats bill
their headcount at the classic constant rate, and `npc_dot_summary` /
`festival_vibe` / the Site Plan dot + crew providers return empty (the fun
meter, peak chip and habitat inspector check the pref too; StageMusic resolves
venue programmes itself so a set still ends on time). Camp power keeps
stepping, on the clock's hours. The roster is FROZEN, not erased — switching
back on resumes it, a long gap through the ordinary coarse catch-up. Because
the bridge itself is ungated, the challenge bake and every offline selftest
are untouched. `force_npcs_for_session` (never saved) turns it back on for
every `--capture` run; festival mode switches it on for real.

Individual simulated people (10–50) driven by needs, wayfinding to
player-tagged spaces; consumption emerges from activity and flows through the
graph, and morale decides whether the community holds together. Design doc:
`plans/POPULATION_PLAN.md`. **Tagging:** `SpaceTypes`
(restroom/kitchen/sleep/water_point/shower + enrichment types fire_circle/
movement/quiet/workshop_social, with `COLORS`/`ICONS` for markers) +
`SpaceRegistry` (per-map `user://maps/npc_spaces_*.json`; targets = prop id /
`building_tag` / area polygon [v2-reserved]; runtime occupancy never
persisted). Tag via the prop edit drawer ("Space:" OptionButton + capacity) or
Building Builder's "NPC space" row — registry only, NEVER BuildingStyleLayer
(styling de-merges the building). `TerrainLoader.npc_spaces` owns it on
generated maps; `NpcPopulationBridge` falls back to a scene-keyed registry on
built-in maps. **Agents:** `NpcAgent` (pure RefCounted FSM
IDLE→TRAVELING→DOING; needs 0..1 rise per sim-hour, activity table with
consumption rates calibrated to the habitat preset's ~50 L water + 1.5 kg
food/person/day; per-agent RNG reseeded per sim-day → deterministic).
`step()` returns **time-averaged rates** (rate × fraction of the step spent
doing) so integrating them over dt bills exact mass at any time scale.
Needs are hunger/thirst/bladder/sleep/**hygiene**/**enrichment** (shower ~12 L
→ ~60 L water/person/day total). **Priority ladder** (`_pick` = tiers 1-2,
`_step_idle` = 3-4): critical need → comfort (hygiene) → chore → enrichment.
Two livelocks to never reintroduce: comparing raw need levels ACROSS tiers
(hygiene pinned at 1.0 out-scores thirst at 0.99 → shower/interrupt loop), and
letting a non-critical need interrupt (`_most_urgent` iterates CRITICAL_NEEDS
only; `NON_INTERRUPTING` = sleep/hygiene/enrichment). Backoff after a failed
attempt is **per-tier** (`retry_at` dict) — a single scalar let a failed
enrichment attempt stop someone re-evaluating whether they were thirsty.
Agents carry a deterministic `display_name` (`NpcAgent.name_for`) +
`status_line()`.

**Morale (worst→best: "FUCK THIS!!!" · "Fuck You" · "Fuck Me" · "Fuck It" · "Fuck Maybe" · "Fuck It!", then the peak state "FUCK YES!!!")** — `NpcMorale` (pure static): 6 bands;
pressure from unmet CRITICAL needs is superlinear past `PAIN_THRESHOLD` 0.75
and **2× when the need is BLOCKED** (no tagged space / starved supply) —
broken infrastructure is what breaks a community, not busy people. Needs alone
cap at `BASELINE_CEILING` 0.75; `ceiling(enrichment_need)` lifts it to 1.0 only
through gathering. Recovery (0.035/h) is far slower than loss. **Departure:**
quit pressure accrues below 0.12 and decays on rescue; at `QUIT_PRESSURE_H` the
agent leaves → `agent_departed` → roster + labour shrink, plus a
`DEPARTURE_SHOCK` contagion hit to everyone else → `collapse_warning` at risk
0.5 → `colony_collapsed` below 35% of the starting roster (a story beat, NOT a
game over). `occupants` stays the AUTHORED headcount (editing it rebuilds the
roster); live counts surface as `specs.pop_present`/`pop_morale`/
`pop_collapse_risk`.

**Chores** — `NpcChoreBoard` (per engine, rides `pop_state`): label, target,
`chore_hours`, daily window (may wrap midnight), repeat, exposure class,
priority, assignment. Progress is credited in EFFECTIVE hours = dt ×
`NpcMorale.productivity(morale)` (0.55–1.15) × `NpcWeatherGate.productivity` —
low morale slows the work that would raise it. Credit clamps to what's left
(mass-exact) and feeds the existing `chore_hours` ledger. UI:
`scenes/ui/npc_routines_panel.gd` (inspector **Routines & chores…**) — roster
with morale bands, chore board, and a 24 h **day-plan strip** per person
(sleep/needs/chores/free, red overflow) so over-scheduling is visible.

**Weather** — `NpcWeatherGate` (static, sources cited: ISO 7243 WBGT, Beaufort,
met rain classes): per-driver severity MULTIPLIES (a hot windy rainy day is
brutal, not merely additive), floored at 0.15; `is_unsafe` skips the chore
entirely (work backs up); exposure also drains morale. Indoor work is immune;
sheltered gets `SHELTER_RELIEF`. Weather is sampled per tick from
`WeatherService` and degrades to "comfortable" when uncovered/offline.
**Navigation** (`NpcNavGrid` + `NpcNavQuery`, plans/POPULATION_PLAN.md Tier 3):
person-scale walkable grid (0.75 m cells) over the bounding box of the tagged
spaces + habitat, padded — not the whole SoI. The bake is **chunked across
ticks** (`bake_step`); `ConduitAStar`'s header records that per-cell ground
fetches caused GPU TDR, so nothing samples terrain inline. Until `is_ready()`
agents walk straight lines, and a declined plan always falls back to that.
**Slope vs steps is the load-bearing distinction**: cell slope is a central
difference over ±2 cells (3 m — a single 1.2 m step reads 22°, walkable; a
cliff reads 80°+, blocked), while per-move `STEP_UP_M` 1.2 / `STEP_DOWN_M` 2.5
are enforced at *connection* time in the A*. Measuring slope between adjacent
cells instead would read a step as 58° and strand people at the bottom of it.
A* is hand-rolled over the packed arrays (not `AStar3D`: 71k points would cost
~350k binding calls on every re-bake, and the grid re-bakes when a prop
moves). Smoothing is **cost-aware string-pulling** — a shortcut is only taken
when it is no dearer than the run it replaces, or straightening would undo the
climb avoidance the search just paid for and send everyone over the hill.
Routes between tagged spaces are cached per (from,to) pair and offset per
agent by ±0.4 m *only in open ground*, which gives desire lines their width;
in a doorway the jitter declines, and any jittered polyline that fails a
segment check reverts. `STEP_EPS` exists because heights are float32, so a
step authored at exactly 1.2 m reads back as 1.20000004768 and would be
refused by a rounding error.
**Buildings** (`NpcBuildingNav`): walls become a 0.6 m blocked band, interiors
stay walkable, and doors punch openings — so people path INTO and THROUGH
buildings. Player-placed door `elements` resolve via the NORMALIZED ring from
`BuildingBuilder.resolve_building_params` (open, CCW — the only form `edge`
indices mean anything in). The **auto-door heuristic is load-bearing, not a
nicety**: almost every OSM building has no door data, so one is punched at the
edge midpoint facing the nearest road (else the site centre), derived
deterministically from the footprint. Buildings tagged as an NPC space are
forced enterable whatever their size; sheds under 9 m² stay solid.
**Upper levels**: `surfaces_fn` probes downward rays for decks/floors, but ONLY
in `F_STRUCTURE` cells, and the layer pass budgets *probes* rather than cells
scanned. Nothing in the project generates walkable upper floors yet — the
mechanism exists so stairs/ramps connect automatically when content does (an
inter-layer link is just a move whose height delta passes the step limit).
**Walking cost** (`NpcMetabolism`, Tier 3d): per-agent daily `distance_m` /
`climb_m` / `walk_kcal` with per-need trip attribution, rolled at the sim-day
boundary (yesterday kept in `prev_day`). Model is the **ACSM walking
equation** (cited; ~51 kcal/km at 70 kg, pinned in the selftest); grade is
clamped at zero downhill because the equation has no valid negative term.
Aggregates surface as `walk_overhead` (share of a 2000 kcal day) plus an
`efficiency_label` Compact→Punishing, and mean metres per trip SPLIT BY NEED —
the diagnostic that says *which* space is misplaced. Climb reads the baked nav
grid, never a terrain query (hot path). Note the arrival branch must account
for its final leg: a trip that finishes inside one step never calls `_walk`,
and at high time scale that is every trip, which would zero the whole metric.
**Desire lines** (`NpcDesireMap`, Tier 3e): metres walked rasterised into a
2 m heat grid with per-need channels, log-scaled (foot traffic is heavy-
tailed) and drawn as ONE `draw_texture_rect` under the Site Plan overlays;
per-agent fading trails on top. Retention is Today / Past week / All time,
rolled at the sim-day boundary. **Build the ImageTexture on the TICK, never
inside `_draw()`** — allocating a GPU resource mid-draw yields undefined
contents (it rendered as a solid white block over the whole site). Toggles
live in **View options ▾** at ids ≥152 (151 is already double-booked by
`VIEW_MODE_EMBODY_TWINS` and `VIEW_MODE_SITE_PORTS`).
3D drape (`NpcDesireOverlay` + `npc_desire_drape.gdshader`): one
terrain-following mesh over the map's rect with world-XZ UVs baked into the
vertices — the mesh IS the registration, so there is no bbox uniform to keep
in sync. Additive, unshaded, no depth write; built lazily on first enable and
freed on disable. Grid-tessellated rather than reusing
`build_polygon_highlight`, which samples only a polygon's corners and floats
over rolling ground.
**Coarse catch-up models COPING, not neglect.** A >6 h jump is the player
scrubbing or a frame hitch — time the community lived through but the sim did
not simulate. Needs land at ordinary mid-cycle levels, morale drifts at most
`CATCHUP_MORALE_DRIFT`, and quit pressure only DECAYS. Integrating the whole
gap as deprivation emptied a healthy camp (morale 0.75, nothing blocked) in a
single 12.8 h tick. Crucially, a need whose supply is currently STARVED is
exempt and keeps rising — otherwise a jump silently feeds a camp whose food
tank is empty.
**On scenes with no TerrainLoader the nav grid uses a FLAT height source**:
`TerrainSurfaceQuery.ground_height_at` falls back to a raycast that returns
0.0 on a MISS, so every hole in collision coverage would read as a cliff and
island the grid (this was causing real path failures on the soak map). **Engine/coupling:** `NpcPopulationEngine`
(roster, substepped tick, scrub-back = freeze, >6 h forward jump = coarse
catch-up, snapshot/restore) is ticked by `NpcPopulationBridge` from
`system_graph_view._tick_resource_flow_ambient` BEFORE the flow tick (works
with the graph closed). It writes aggregate demand into
`ResourceFlowEngine.set_habitat_demand(item_id, rates)`; `_process_habitat`
uses that override instead of `rate × occupants` when present (waste caps
bypassed pop-driven — bursty rates would clip mass), and last tick's
`specs.starved_kinds` feeds back so blocked activities abort and the need
pins at 1.0. Enable per habitat: inspector **Population Simulation** →
`specs.pop_driven` (occupants = roster size; closure metrics unchanged).
Persistence: change-gated `specs.pop_state` snapshot (≤2×/sim-hour) rides the
normal graph save; `pop_state` is in both INSTANCE_ONLY_SPEC_KEYS strip
lists. **Daily routines (`core/population/npc_routine.gd`).** People follow a schedule
of blocks that tile 24 h and may wrap midnight; `NpcAgent._step_idle` consults
it at tier 2.5 (needs still outrank it, and the routine is what they return
to). This exists because a purely need-driven model has a visible failure: a
finished activity left the agent IDLE where it stood, and nearest-space
selection then kept picking the same place, so everyone pooled at the
restrooms. Activities are clamped to the end of the block that asked for them,
or a "5-minute" visit is only 5 minutes if the schedule can reclaim the
person. Per-agent phase offsets (`offset_for`) come from an AVALANCHED hash —
Godot's string hash over `hab_npc_0..23` is nearly sequential, and `% 1001`
put 24 people in 4 buckets, still lockstep. Bathroom = 3 scheduled visits x 5
min x one 6 L flush (18 L/person/day, replacing ~40 L of threshold-driven
phantom flushes). **The schedule only holds because the bladder was
recalibrated**: at rise 1/4 per hour + a 0.12 drink kick the need re-fired
every ~2.4 h and dragged people back (restroom share only fell 40%->23%);
1/12 with threshold 0.75 makes 3 visits sufficient and leaves the need as a
backstop for a MISSED visit. Editing lives in the Routines panel's **Daily
routine** tab, staged in a draft until Apply and persisted to
`specs.pop_routine` — deliberately NOT part of `pop_state`, so Reset
population keeps the authored day. Note a scheduled camp is materially more
resilient (morale starts ~0.81 vs 0.60), which is why the harness collapse
window had to widen 90->220 iterations.
**Personal schedules (2026-10-09).** A routine is a shape: each person lives
their own version, different each day (`NpcRoutine.personal_blocks` /
`day_shift`, keyed `day_key` = "<id>|<routine day>", the day rolling at
`roll_h()` = mid-sleep). On top of `offset_for` (±0.5 h, fixed) the whole day
shifts by up to `MAX_DAY_SHIFT_H` (±0.6 h, new each day) and SHORT blocks
(< `SHORT_BLOCK_H`, the 5-minute toilet visits) float as a unit up to
`MAX_FLOAT_JITTER_H` inside their neighbours. The sleep window and wake hour
move with the person's whole shift (`NpcAgent._personal_shift`, the cohort's
`pshift`) using `night_key`, which rolls at MIDDAY so one night keeps one
shift (otherwise a person who just woke finds the window moved and goes back
to bed — the one-session-per-night pin caught it), and the
instant-daytime-nap rule ends "day" at `NpcAgent.night_from_h(personal
start)`, not a fixed 21:00 (a 20:30 bedtime is a night). ⚠ Measured traps:
jittering ordinary block BOUNDARIES independently drifted the tiers' morale
apart (the "linger" trap again) — shift whole days instead; and the light
tier's idle dawdle (15–45 min) under-gathered by a third, which is what had
the morale pin sitting at ~0.075 of its 0.08 — an idle light-tier person now
re-decides the moment their enrichment need crosses its bar (exact: needs are
lines). Waking idlers at every need crossing or block end instead re-issued
meals (+20 % food) — enrichment only.

**Area spaces (Tier 4b).** `target.kind == "area"` was always in the schema;
what it lacked was geometry and a way to create one. `SpaceEditUI`
(`scenes/ui/space_edit_ui.gd`, **Y**, wired in `terrain_loader._unhandled_input`
alongside the C camp dock — raw keycode, no new input action) draws a polygon
on the ground via `terrain_pick_ray`, closing on a click near the first corner
or RMB. Props and buildings are still tagged in place through `NpcSpaceTagRow`;
areas get a dock because there is no object to open. **Position resolution is
the subtle part**: `polygon_centroid` is a shoelace centroid, NOT a vertex
average (a vertex average drifts toward whichever edge is finely subdivided),
and for a concave outline — a courtyard wrapping a building — the centroid can
land OUTSIDE the polygon, so `area_interior_point` falls back to the bounded
grid sample furthest from any edge, which is both inside and the roomiest place
to stand. Site Plan draws the real outline plus the marker at that point
(`space_markers` carries `poly`), so a 40 m plaza no longer looks identical to a
single portaloo.

**Desertion is a dead end the sim cannot leave on its own.** Departures are
permanent, so a barren site eventually empties the roster COMPLETELY (past
`colony_collapsed`, which fires at 35% and still leaves people). At zero agents
`tick()` returns `{}` immediately: nothing moves, nothing is consumed, no
further events fire — the world just goes quiet, which reads as a bug.
`colony_deserted(cause)` is emitted separately from `colony_collapsed` for that
moment, the inspector replaces the whole Population readout with an EMPTY
banner + the dominant departure cause (`departure_cause()` tallies the
`_departures` log), and **Reset population**
(`SystemGraphView.npc_reset_population` → `NpcPopulationBridge.reset_population`)
rebuilds the roster. Reset MUST erase `specs.pop_state`, or the next
`_ensure_engine` restores the roster that just walked out. `_ensure_engine`
only rebuilds when the AUTHORED `occupants` count changes, so before this the
sole recovery was toggling `pop_driven` off and on — undiscoverable. Reset
deliberately does not fix the underlying cause; a fresh group walks out the
same way, which the selftest asserts.

**Personal space (Tier 4c) is cosmetic by contract.** Two mechanisms, because
the problems differ: **standing slots** for people who have ARRIVED (a Vogel
sunflower spiral, `r = PERSONAL_SPACE_M*sqrt(n)` at the golden angle, indexed
by position in `SpaceRegistry`'s occupancy array — claim order IS slot order,
so an arrangement is stable for a whole visit; nearest-neighbour spacing
settles at ~0.9 m for every n without looking like a lattice), and a
**separation pass** in `NpcPopulationEngine._separate` for everyone in transit.
Separation is O(n²) ON PURPOSE — the roster caps at 64, so it is ~2k pairs of
vector math, and a spatial hash would add bucket-ordering questions that the
determinism guarantee then has to answer. Pushes are biased 85% SIDEWAYS for
travelling agents (`PERP_BIAS`): shoving someone back down their own route
reads as barging and feeds back into arrival time. It is skipped above
`SEPARATION_MAX_DT_H` (agents teleport at high time scale, so nudging is noise
on noise), refuses any push onto unwalkable ground, and derives a deterministic
direction from the id pair when two agents are exactly coincident (which is
what a fresh roster is). **Displacement is deliberately NOT banked into the
walking/kcal ledger** — folding it in would make spatial-efficiency numbers
depend on crowd density. The selftest asserts consumption is unchanged to a
RELATIVE 0.1% rather than exactly: position feeds travel time feeds activity
scheduling, so a sideways nudge shifts what someone is mid-way through at the
measurement boundary (measured drift ~4 ppm over a simulated day).

**Selftest gotcha:** a Godot runtime error (assigning through a null
reference, say) PRINTS and execution continues, so `npc_population_selftest`
still reports PASS. A crash on every map load hid behind that for a whole
commit. Assert on OBSERVABLE state after construction (`NpcAvatar.has_body()`),
and when a change swaps a body/material out, grep the selftest output for
`base object of type '"Nil"'` rather than trusting the PASS line.

**Two body styles, one behaviour.** `NpcSimpleFigure`
(`core/population/npc_simple_figure.gd`) is an articulated stick figure — head,
torso, shoulder→upper-arm→ELBOW→forearm, hip→thigh→KNEE→shin, all capsules
under the silhouette shader — posed procedurally. It exists because the Mixamo
body is photoreal enough that any imperfection in how it is driven reads as
uncanny, while a stylised figure has no such contract and the same approximate
motion reads as deliberate. **It is posed from the SAME `NpcPoseMachine`** as
the rigged body, so behaviour cannot drift between styles: people walk the whole
route, lie down on arrival, sit for the bathroom, dance at the fire. Gait
cadence multiplies by the same playback rate, so it time-lapses identically.
Two details make it read as a body: the knee bends only on the RECOVERY leg
(the stance leg stays near-straight — the one asymmetry separating walking from
scissoring), and every pose is an eased TARGET rather than a jump, since this
body has no cross-fade to hide a cut. Style lives in `NpcDisplayPrefs`
(`user://npc_display.cfg`, global — a taste about the game, not a property of a
site), exposed as **Settings → NPCs → Body style**. Keep
`NpcDisplayPrefs.wants_simple()` (a CHOICE, survives installing the art)
distinct from `NpcRig.available()` (a missing-asset condition): both draw the
same figure, but only the second is worth warning about.

**Playback is time-scaled.** A gait is rate-matched to the body's APPARENT
speed — metres per REAL second measured off the rendered step, not the sim's
nominal 1.3 m/s, which is only correct at 1x. At 60x the body covers ground
60x faster and a gait pinned near 1x is exactly the skating that made speed-up
look wrong. Measuring the rendered step means smoothing, catch-up and time
scale are already in the number, with nothing to keep in sync. Other loops
(work, dance, exercise, clap) scale by `time_scale * 3600` so a chore at speed
reads as time-lapse. Capped at `MAX_PLAYBACK_RATE` 12x — past that it is a blur
either way. Rate refreshes EVERY FRAME, not on clip change, since apparent
speed varies continuously and the clock can change mid-stride. Consequence to
respect: the pose machine's one-shot timer must divide by the playback rate, or
a transition played at 6x is held five-sixths longer than the animation it
represents. Figures freeze entirely at `time_scale <= 0` (pause AND backward
scrub, where the population engine already freezes) — and because freezing is
`speed_scale = 0`, the INTENDED rate is stored separately or unpausing resumes
at zero forever.

**Animation is driven by `NpcPoseMachine`, a pure FSM** (`core/population/
npc_pose_machine.gd`; states IDLE/WALK_START/WALK/WALK_STOP/ENTER/POSE/EXIT).
It exists because clip choice used to be a function of `moving` and `activity`
only — and `NpcAgent` sets `activity` to the INTENT when travel begins, so
someone walking to bed reported `activity == "sleep"` for the whole trip and
played the lying-down clip while sliding. **The deeper bug was the `moving`
flag itself**: `_pose_avatar` compared THIS frame's sim position to LAST
frame's, but the sim advances every 0.25 s while the host poses every frame, so
it read true ~1 frame in 15 — false for exactly the window the body is gliding.
No epsilon fixes aliasing a stepped signal. `in_transit` now comes from
`dot["state"] == TRAVELING` (a LEVEL, immune to the sampling mismatch; it was
already in the payload and simply unread) OR'd with "the RENDERED body has not
arrived yet" (`gap > ARRIVE_EPS_M`, bounded by `ARRIVE_MAX_S` because the lerp
is asymptotic and never literally lands). Pure logic over an AnimationTree
**so the no-wedge guarantee can be fuzzed headless** — 200k steps with dt up to
0.5 s (far-LOD passes its accumulator as delta, so nothing may assume 60 Hz).
Getting OUT of a pose keys off `_current_pose`, NOT `_activity`: by the time an
abort runs `_activity` already holds the next intent, and looking the exit up
from it made waking skip the get-up entirely. **Clip roles are MEASURED, never
read off the filename** (`NpcRig.measure`/`classify`): "Idle To Situp" measured
as the LIE-DOWN (hips 0.940→0.123), giving sleep a real matched pair, and
Start/Stop Walking are told apart by which THIRD of the clip is faster — the
check a filename map cannot do. The loader refuses a clip whose measured role
contradicts `SOURCES`. Sitting down is `sit_exit` played BACKWARDS, so
`_apply_clip` keys on `(clip, direction)` — a clip-only guard makes
sit-down→stand-up a no-op and freezes the figure half-seated. Ground offset is
now a **phase curve** (`clip_ground_offset_at`) parameterised on the clip's own
hip descent, because one scalar is wrong at one end of a stand→lie clip;
verified continuous at the seams (sleep 9 mm, sit 29 mm). Transitions are
**budget-gated**: a 5-min bathroom visit is 0.67 REAL seconds at 450×, shorter
than one sit-down, so at speed everyone cuts straight to the pose. Harness
note: routines mean people travel at BLOCK BOUNDARIES, so the nav/pose window
anchors the clock at 08:85 and **restores it afterwards** — leaving it shifted
broke the later starvation phase.

**3D figures (`NpcRig` + `npc_silhouette.gdshader`):** `NpcAvatar` carries TWO
bodies behind one API — the rigged Mixamo character up close, the original
head/torso/legs primitive far away and whenever the FBX assets are missing
(`Imported Models/NPC/` is **gitignored**, so the fallback is the normal state
on a fresh clone; see docs/ASSETS.md). `NpcPopulationHost` hands the rig to the
`MAX_RIGGED` (12) nearest agents within `RIG_DIST_M` (45 m), with hysteresis so
walking the boundary doesn't thrash the swap. Everything the Mixamo exporter
gets wrong for this use is corrected in `NpcRig` at load, and each correction is
**measured from the files, not hardcoded**, so a re-export keeps working:
every clip is named `mixamo_com` (renamed by role into one shared
`AnimationLibrary`); three clips carry root motion (horizontal hip translation
is flattened — vertical is kept, since for a squat that IS the animation);
nothing loops; the model faces **+Z** while the avatar's forward is −Z
(`model_yaw_offset` derives the half-turn from the direction the hips travel in
the walk clip); the walk clip covers 1.69 m/cycle at 1.64 m/s vs the sim's
1.3 m/s (`walk_speed_scale` rate-matches it or the feet skate). **Clips are
authored around their own origin, not the ground, and they disagree** —
"Laying Sleeping" puts the hips at 1.018 m, *higher* than a standing walk, so
an uncorrected figure lies down a metre in the air; `TARGET_HIPS_Y` expresses
the fix as a target height and `clip_ground_offset` derives the shift.
There is **no standing idle in the pack** (the character's bundled `Take 001`
is a static bind pose held 9 s — measured 0.0° of rotation), so the player
character's Breathing Idle is retargeted by rewriting `mixamorig_` →
`mixamorig1_`; Godot drops unbound tracks SILENTLY (a bad retarget looks like a
T-pose, not an error), so `_retarget_idle` verifies the bind ratio and rejects
the clip rather than trusting it. Shading is deliberately `unshaded` near-black
with a fresnel rim in the agent's pastel: a lit character reads as a *person*,
a flat dark mass reads as *someone*. Note a human is mostly limbs, and cylinders
show grazing angles across most of their visible surface, so a rim exponent
that edges a sphere floods a whole body — `rim_power` is 6.5 for that reason.
Skinned meshes cull against their REST AABB, so `extra_cull_margin` is set or
lying/arms-overhead figures pop out at the screen edge.

**Rendering:** Site Plan draws tagged spaces (`npc_spaces_provider` →
`_draw_npc_spaces_site`: disc + glyph + live occupancy sweep) UNDER the agent
dots (`npc_agents_provider` → `_draw_npc_agents_site`), redrawn only on
population ticks while visible; 3D = `NpcPopulationHost` (spawned by the view
while any engine runs, child of Main) posing `NpcAvatar` silhouette figures
(head/torso/legs, per-agent pastel, walk bob + leg swing, lies down asleep)
kinematically snapped to `TerrainSurfaceQuery.ground_height_at` — no
CharacterBody3D. **LOD:** cull >220 m, quarter-rate pose >90 m, ground height
cached until the agent moves 0.35 m or 0.5 s lapses (it was a terrain query
per avatar per frame). **Crosshair:** avatars join group `npc_avatars` and are
picked by a pure software ray-vs-sphere in
`interaction_focus._update_npc_focus` (deliberately NO collider — a moving
StaticBody would shove the player); Ctrl/Alt-aim shows "Name — status" and
that person's Label3D nametag. Selftest + the `--capture=population` harness
(which also asserts the crosshair contract + space-marker resolution) are in
the Validation list.

## J Light Studio (core/placed_lights/ + scenes/ui/lights/light_dock.gd)

J opens a right-edge DOCK (not a modal — the old centred, dimmed
PlacedLightModal hid exactly what was being lit) in CursorController's
TOOL-OVERLAY tier, like the T/V/C toolbar: free cursor, RMB-look, WASD, one
Esc peels one layer (string in progress → drag → selection → close). Tools:
Select (click / Shift-add / box-select, gumball, drag a light or pin along
surfaces, drag a WIRE to insert a pin), Omni, Spot (on open ground it hangs
`SPOT_HANG_M` up aiming DOWN at the click — a spot on the ground shines at the
sky; on a wall it aims out and 30° down), String (click pins, double-click the
LAST pin or Enter to finish, Backspace drops one), Aim (selected spots face the
clicked point). Outside the dock, Ctrl/Alt + click on a light or a string pin
opens the dock on it and Ctrl/Alt + drag moves it (GrabController's
relocatable-marker contract, which gained `world_drag_aim(camera)` so a marker
can follow SURFACES, not just the terrain, plus optional
`world_drag_begin` / `world_drag_preview(pos)` / `world_drag_cancel` hooks so a
marker can show the drag itself). DRAG RULES, the same in both modes: J closed
— Ctrl/Alt + drag moves the WHOLE light or string (every pin keeps its place
relative to the others), Ctrl/Alt + Shift + drag duplicates it and moves the
copy, a click opens the dock; J open — a plain drag on a pin moves just that
pin (a light slides along surfaces), Ctrl + drag moves the whole string or the
whole selection, Shift + drag duplicates. Nothing opens the dock on release (it
dropped the player back into J on every nudge). All of it goes through
`PlacedLightService.begin_drag_many` / `drag_to` / `end_drag` / `cancel_drag`
(one undo step; cancel restores the checkpoint, copy and all). Offsets are
measured from the FIRST aim point, so a lamp hung 3 m up keeps its height.
COPIES SHARE the source's style AND groups (a source in no group gets a
"<style> set" group with them), so by default everything stamped from one
light restyles and switches together. Inside the dock every tool GRABS an
existing pin or light under the pointer first — the String tool used to start
a new string from a finished string's pin — except while a string is in
progress. A selected string gets a SMALL gumball at its pin centroid (move +
rotate — rotation swings every pin about the handle) for fine adjustment.

- **Data** (`PlacedLightLayer` v3, `user://maps/placed_lights_<key>.json`):
  key = `<lat>_<lon>` tokens on a generated map (one file per SITE — v2 keyed
  every generated map to the shared shell scene, so all user maps read and
  wrote ONE file; the first site to load adopts it and renames it `.adopted`),
  `scene_<basename>` on built-in maps (== the v2 path, so they migrate in
  place). Records hold WORLD xyz and rotation in DEGREES (v2: radians, and the
  world hit point applied as a LOCAL position under Terrain). Nodes are
  `top_level` under `Main/PlacedLights` — not Terrain — which is what lets the
  SOAK/Mars scenes (no TerrainLoader) show their lights at all
  (`main._build_placed_lights`; generated maps rebuild from
  `_rebuild_placed_props` once the site key is known).
- **Linked styles** (`PlacedLightStyles`, pure): a light renders
  `defaults(kind) ⊕ style ⊕ overrides`. The inspector's scope picker writes
  either INTO the style (every user follows) or as an override (amber dot + ↺);
  an override equal to the style is pruned. Make unique / Push to style /
  removing a style keeps the look. Groups are named sets with on/off + hide.
- **Undo**: whole-layer snapshots (`checkpoint()` BEFORE a gesture,
  `commit()` after = one undo step + one file write). Inspector edits within
  0.6 s coalesce into one step.
- **String lights** (`PlacedStringLight`) are deliberately NOT conduits: not
  under ConduitManager (hidden in first person), no x-ray material, NOT in
  `power_consumers`. Geometry is `ConduitMeshBuilder.sample_path` /
  `bulb_positions_along` (the lights-as-wires sampler) via
  `LightStringGeometry`; presets borrow `led_patio/fairy/strip` numbers.
  One bulb MultiMesh on `gameplay/led_bulb.gdshader` + `real_lights` OmniLights
  (distance-faded, `DEFAULT_FADE_M` 90).
- **LED effects**: `LedEffects.color_at` is the ONE definition (solid,
  rainbow_chase, theatre chase, twinkle, breathe, colour wipe);
  `led_bulb.gdshader` is its line-for-line MIRROR (HSV output linearised to
  match a CPU sRGB `Color.from_hsv`), fed the SAME `fx_time` the node advances
  (real time; "Pause w/ sim" freezes it at time_scale 0) so the OmniLights,
  which sample `color_at` at their own bulb indices at 15 Hz, chase with the
  bulbs. The selftest parses the shader's constants.
- **Gumball** (`LightGizmo` + `LightGizmoMath`, pure ray maths, no colliders):
  arrows / plane squares / yaw-pitch-roll rings + a spot cone preview, constant
  screen size, Shift snaps 0.25 m / 15°, L toggles world/local. Where a ring
  crosses an axis it also lies on that move arrow, and the arrow wins the pick.
- **Graph (load only)**: "Add to graph" → `SystemGraphView.add_placed_light_load`
  (idempotent on `specs.placed_light_id`) makes an `appliance` whose
  `scene_device_path` is the light's node: that gives it a 3D anchor for feed
  conduits (a string's `PlugAnchor` = its first pin) AND lets GraphAcLoad read
  the node's `get_current_power()` (0 unless bound + lit). No `light_conduit` /
  `watts_per_m` on it — those would render the FEED cord as a second string.
  Bound, a light is lit only when the item is on and AC is available
  (`PlacedLightPower`). Deleting the light removes its load.
- **Ctrl/Alt come from `ModifierKeys`**, not `Input.is_key_pressed`: the key
  table goes stale when a release is lost (Alt+Tab), which left every J IK
  sphere AND every Ctrl-gated crosshair highlight (camps, props) on while
  walking. interaction_focus feeds it the latest event's modifier flags (each
  mouse motion carries them, so a stuck key heals on the next move) and resets
  it on focus loss. Also: `clear_camp_highlight` resets the loader's
  change-gated `_camp_focus_id`, so a highlight cleared by another path (the
  toolbar Edit tool) can no longer desync the gate.
- **Show bulb** (`show_body` style key): omni/spot default OFF (only the light;
  the IK sphere only while J is open or Ctrl/Alt held), strings default ON (the
  bulbs are the look); off on a string hides its bulb MultiMesh.
- **Presets** (`PlacedLightStyles.PRESETS` / `PRESET_ORDER`, per kind, with
  real-product numbers): picking one in the dock's "New <kind>:" row makes (or
  reuses) ONE style per preset per map (`style_for_preset`, keyed by
  `preset_id`), so every light placed from it restyles together; the
  inspector's Preset row applies one to the selection. `spot_angle` is Godot's
  HALF-angle — product sheets quote the full beam angle.
- **Continuous tubes** (string presets with `continuous: true`: LED rope, LED
  neon flex, glass neon, EL wire): `LightStringGeometry.build_tube` carries the
  ARC LENGTH in UV.x and `led_rope.gdshader` puts pixel i at i / `leds_per_m`,
  blending between pixels (the diffuser look). Graph watts use the preset's
  `watts_per_m`.
- **Movers** (kind `mover`, `PlacedMoverLight` extends PlacedLight): moving-head
  beam / gobo spot / wash / laser / gobo projector / strobe / sky tracker.
  Base +Y = the mount axis (`MoverProgram.mount_rotation` stands it on the
  clicked surface — hang one under a truss by clicking its underside); yoke
  pans about +Y, head tilts away from it; `MoverProgram.direction(pan, tilt)`
  is pinned against the real node hierarchy in the selftest. Programs (static /
  pan / tilt / circle / figure-8 / wander) are pure functions of the SHARED
  `PlacedLightClock`; `phase_deg` + the dock's "Fan phases" turn a set into a
  fan. The Aim tool centres a mover's sweep (pan/tilt centre) instead of
  turning its mount. Beams: `light_beam.gdshader` shaft (unit cone scaled to
  (R, L, R), min apparent width so a 3 mm laser never vanishes, night-gated)
  plus the SpotLight's volumetric-fog energy; beams and lasers stop at the
  first surface (10 Hz raycast). Gobos are procedural (`MoverGobo`). ⚠ Clamp
  the base of every `pow()` in an additive shader: the interpolated
  `v_along` overshoots 1.0 at the beam's far end, `pow(negative)` is NaN, and
  the glow pass turns one NaN pixel into a bright square with a black centre.
- **One effect clock** (`PlacedLightClock`): strings, lamps and movers all read
  it, so duplicates chase and sweep in step. Effects now include `flicker`
  (flame / lantern) and `strobe` (fx_speed = flashes/s); the GPU half lives in
  ONE include, `gameplay/led_effects.gdshaderinc`, used by both the bulb and
  the tube shaders, and mirrors `LedEffects.color_at`.
- Light distance fade uses Godot's own Light3D distance fade (the old LOD hid a
  light outright past a threshold — it popped).

## Window wall (multi-monitor viewport — `core/windowwall/` + `scenes/windowwall/`)

The bus has three 27" 1080p monitors in a row on one wall, 4" bezel gap; the
Window Wall renders the world across them so they read as WINDOWS. Off by
default (Settings → Window Wall, `user://window_wall.cfg` via `WindowWallPrefs`,
own file on the `ExtremeWeatherPrefs` pattern); **F11** / `toggle_window_wall`
or the tab's button opens it; `--window-wall` opens it after load for a desktop
shortcut. Mode class `WindowWallView`, claim id `"window_wall"`, mirrors
`SettlementView` (modal via CursorController, camera through the claim stack,
idempotent `close()` on every exit path).

**One eye, one orientation, N off-axis frusta — physically correct, not
fanned.** `WindowWallLayout` (pure static) lays the panels out along the wall
(eye at the origin, wall at `z = -eye_distance_m`) and turns each rectangle
into `Camera3D.set_frustum(size, offset, near, far)` with
`keep_aspect = KEEP_WIDTH`: `size = w·near/d`, `offset = (cx, cy)·near/d`.
⚠ Under `KEEP_WIDTH` Godot's `size` is the near-plane WIDTH; with
`KEEP_HEIGHT` the engine multiplies it by the aspect first and it becomes the
HEIGHT — same call, silently different picture. The selftest inverts
`Projection.create_frustum_aspect(..., flip_fov=true)` (the exact call the
camera makes) to put the corner rays on the monitor corners AND pins that
`flip_fov=false` does not. Tilted panels rotate the camera basis to the
panel's normal and project in that frame (`slot_basis`); a panel the eye is
not in front of returns `{}` rather than a plausible-looking frustum.

**The game window IS one of the monitors.** Its root `Window` is moved
fullscreen onto the assigned OS screen and shows the main slot's camera via
`push_camera_claim` (no `shadow_max_distance` / `prop_cull_scale_m` — this is
eye-level tuning); every other slot is a native `Window` with
`own_world_3d = false`, `world_3d = root.world_3d`, borderless
`MODE_FULLSCREEN` (never exclusive: focus loss would minimise it), a
`Camera3D` child (which IS that window's camera), the root viewport's
`msaa_3d/use_taa/screen_space_aa/use_debanding/scaling_3d_*/shadow atlas`
copied over (main.gd applies those to the root viewport only), and an
`InputRelay` node. Spawned ONE PER FRAME (the AMD-TDR discipline from
`graph_soi_preview_service`). Facts measured by the Phase 0 spike, on this
machine: (1) `root.gui_embed_subwindows` CAN be flipped at runtime, and Godot
REFUSES (warning, value unchanged) while any embedded child window is visible
— every existing `Window.new()` popup in the project is embedded, so
`_set_embed(false)` hides visible ones first and a refusal aborts the open with
a toast rather than the project-wide setting flip (which would turn every
popup native); (2) screen/size/position may be set before or after
`add_child`, both land; (3) `w.get_texture().get_image()` works on a native
window; (4) `window_input` does NOT fire for `push_input` — only for OS
events — which is why each window carries a relay NODE whose `_input`
forwards to the view (harness-drivable AND responsive to real keys); (5) three
KEEP_WIDTH cameras put the horizon on the identical pixel row (539.5/1080).
Nudge keys are POLLED (`Input.is_physical_key_pressed`) so they work from
whichever window has focus; discrete keys go through `handle_window_event`
from both the main window's `_input` and the relays, and every key is marked
handled while the view is up (hidden panels still receive `_unhandled_input`
— the help overlay would un-hide itself on F1).

**⚠ Two measured ordering rules, both of which fail SILENTLY or CRASH.**
(1) **Closing from a relay must be DEFERRED.** Esc is delivered by the relay
INSIDE an extra window; the teardown frees that window, so a synchronous
`close()` destroys the caller and its viewport mid-stack — "Cannot call method
'get_viewport' on a previously freed instance". `request_close()` sets
`_closing`, stops consuming input and defers `close()` by one idle frame;
every input-reachable path (Esc/F11, `close_requested`, the CursorController
modal callable, Main's toggle) goes through it, while `close()` stays
synchronous for `_exit_tree` and the harness. The relay additionally captures
its viewport BEFORE calling in and re-validates after, so nothing touches
`self` past the call. Pinned by `--capture=windowwall`'s "Esc inside an extra
window closes the view".
(2) **`current_screen`/`position`/`size` go BEFORE `add_child`, and `mode`
in the SAME frame as it.** Applying `MODE_FULLSCREEN` a frame later is
silently ignored (measured on a 3-screen machine: `mode` reads back 0 and the
window sits 2 px short of the screen), and writing `size` to an
already-fullscreen window drops it back to windowed the same way. Only the
camera is re-asserted on the following frame. `_log_window_state()` prints one
line per slot on every open — screen wanted vs landed, size vs screen, mode,
camera, shared world, eye — because a grey window is indistinguishable from a
working one by eye, and the harness reads those lines back.

**A grey monitor is a PRESENTATION failure, not a rendering one.**
`w.get_texture().get_image()` can come back with a perfect frame while the
monitor shows flat grey: the render target and the swapchain are different
things, and a second fullscreen window whose monitor hangs off a different
graphics adapter may never present. Hence `extra_window_mode`
(`WindowWallPrefs.WINDOW_MODES`): "fullscreen" (default) or "borderless",
which leaves the extra windows windowed + `always_on_top` at exactly the
screen rect — visually identical, different presentation path. Exposed as
Settings → Window Wall → "Extra monitors".

**Clock: claim the scale, sync the date, never `set_live_mode`.** "live"
(default) and "1×" push a non-exclusive clock claim
`{"time_scale": 1/3600}` (composes with every other owner, base restored by
construction); "live" additionally calls
`SimSettingsController.sync_to_system_time()` on open and every 10 s while
our scale is still the effective one, and hands the date back on close unless
the player was already in live mode. `set_live_mode` is deliberately not used:
it persists a user preference and its disable path hard-writes
`time_scale = 1.0` (3600×). A refused claim (video export, a bake) toasts the
owner and carries on.

**Leave the world exactly as found.** `open()` snapshots the root window's
mode/screen/size/position, the embed flag, the root render scale, the player's
process mode and every Main CanvasLayer's `visible`; `close()` puts each back
— never blanket-true, several layers are hidden by design. Windows are
`free()`d (not queued) BEFORE the embed flag is restored, since the flip is
refused while a child window is displayed. ⚠ The extra windows take their
cameras with them: check `is_instance_valid` BEFORE `is Camera3D`, because
`is` on a freed instance is a runtime error that aborted the rest of the
restore (UI map, player mode, clock) while the harness still read
"closed PASS" — caught by `--capture=windowwall`'s restore assertions. The
hint strip lives UNDER THE VIEW NODE so the hide sweep never touches it.

**Viewpoint** (`WindowWallViewpoint`): a per-map ground point + yaw
(`user://maps/window_wall_viewpoint_<lat>_<lon>.json`, scene fallback by
basename, `CoordToken` keying like `SpaceRegistry`); pitch is always 0 (the
wall is vertical) and the eye is `seat_eye_height_m` above it, a global pref
so re-seating the chair does not touch every map. No file → the player's
current pose + a hint to Ctrl+S. Settings tab:
`scenes/ui/window_wall_settings_tab.gd` (own script, instantiated by
`timeline_settings_panel._build_window_wall_tab`; ⚠ a helper named `_set`
there collided with `Object._set` and failed the compile sweep).

## Settlement mode + the work substrate it exists to show

Plan: `~/.claude/plans/i-want-to-strengthen-groovy-pearl.md`. The second play
mode: shape the conditions, then watch the community work. **Never call it a
"god's eye" view** — in code or in game. The mode is `Settlement` /
`SettlementView`, claim id `"settlement"`, and the verbs are *shape, schedule,
watch*.

**The stall this arc exists to fix.** `NpcAgent._step_idle` used to `return`
unconditionally once `_pick()` named ANY need. `_pick` returns `"hygiene"` at
0.7 with no satisfiability check, so on a map with no shower tagged the agent
re-picked it forever and tiers 2.5/3/4 became unreachable — **every agent
locked between ~5 and ~13 sim-hours and never worked again.** Tier 1 absorbs by
design (`plans/POPULATION_PLAN.md:248`); tier 2 inherited it by accident. Now only
`CRITICAL_NEEDS` absorb, and a blocked comfort need falls through to routine
and chores. It hid three ways: hygiene is not in `NpcMorale.CRITICAL_NEEDS` so
morale sat at 0.75 with no warning; `status_line()` reported `_worst_need()`
over ALL needs and so blamed enrichment; and **no test ran a chore to
completion** — every fixture tagged a shower, making the absorbing state
structurally unreachable. Companion fixes: `default_day()`'s evening block is
`FREE`, not `ENRICHMENT` (which is in `KIND_ACTIVITY` and can never reach a
chore) — ~10.9 chore-eligible h/day vs 6; a crew AT QUORUM yields only at
`URGENT` and solo work at `CHORE_PREEMPT_FLOOR` 0.80 (one thirsty person used
to zero six people's progress); and `_most_urgent` ranks by NORMALIZED EXCESS
among needs already past their own threshold (argmax-then-threshold let bladder
0.74 mask over-threshold hunger 0.60). Pinned by
`_test_chore_run_to_completion` (240 person-hours over 6 days on a site with
NO shower — verified to FAIL on the pre-fix code with `145.7 h left`).

**Consequences (`core/population/npc_consequence.gd`).** What running out of a
critical resource does is the PLAYER'S choice, authored per-habitat in
`specs["pop_consequence"]` via the Routines panel: `STRIKE` (default — today's
behaviour, named), `LEAVE` (routes through the ONE existing exit by setting
`quit_pressure = QUIT_PRESSURE_H`, so the cascade and its selftests are
untouched by construction) or `PERISH` (`agent_lost`, a NEW signal — challenge
code keys off collapse and must not read a death as a walk-out; no body, no
marker). Not in `NpcDisplayPrefs` (global cross-save taste) and not in
`GameplayRules` (an autoload, invisible under `--script`). ⚠ `PERISH` makes
`_process_departures` return early: morale rage-quit at ~24 h otherwise beats
the 72 h thirst window and nobody ever reaches the consequence they chose.

**The quiet alarm (`core/population/settlement_log.gd`).** A CAP-400 ring
buffer with **per-consumer cursors**, replacing the destructive `take_events()`
whose two consumers (toast drain / challenge-bake collapse detection) raced —
toasts vanished during a bake. Blocked needs are LATCHED (fire once after
`ALARM_H`, relief when the last clears): `blocked` flaps on every backoff and an
unlatched signal would strobe. Nothing beeps; nothing must be dismissed.

**`CameraClaims` (`core/camera_claims.gd`, + Main's impure half).** Mirrors
`ClockClaims`; stores `camera_id` as an int instance id to stay pure. Main owns
`push_camera_claim`/`pop_camera_claim`/`_apply_camera_claim`, resolves the top
claim, applies `hide_player_mesh` / `shadow_max_distance` / `prop_cull_scale_m`,
and **restores the player camera when the stack empties** — all restore
knowledge in one place. The six SubViewport modal previews and
`graph_soi_preview_service` are PERMANENTLY excluded as CAMERA claimants
(private composited worlds) — the one exception is the Globe lens's
camera-LESS `graph_globe_shadow` claim (`shadow_max_distance` only;
`value_or` falls through to the camera below). The full-screen SoI globe is a
real claimant (`soi_snowglobe`). Selftest: `core/camera_claims_selftest.gd`.

**The mode (`scenes/settlement/`).** A real full-screen `Camera3D` on Main, NOT
a SubViewport — the preview service carries AMD-TDR crop/clamp scar tissue and
a 60 m height cap, and rendering to the main viewport is what makes picking,
culling, shadows and TAA behave exactly as in first person. **One scalar `_h`**
(camera height) drives everything: pitch 0 → −80° interpolated on `log(_h)`,
**perspective throughout with no ortho toggle** (a projection switch is the
discontinuity that makes Site Plan picking fiddly), pan speed ∝ `_h`. Three
rules the file exists to hold, restated in its docstring: **the clock is NEVER
claimed** (no view does any more — the snowglobe and Elevation both used to);
**no orders, ever** (selection is inspection + follow-cam; the levers are the
routine editor, chore board, priorities, space tagging and site rules); **it
borrows nothing from the 2D graph** (reading `agent_dots()` as DATA for the
inspector card is fine, drawing dots over people who are right there is not).
Overlays reuse the existing 3D ones; the only new one is `space_overlay.gd`
(tagged AREA spaces, triangulated with per-vertex ground sampling — 
`TerrainBuilder.build_polygon_highlight` takes a DEM grid + extent, not a height
callable, and this view must work on scenes with no TerrainLoader).
`pick_point_once(cb)` lends the view for ONE ground pick (the Routines panel's
"Where…" and the project panel's site picker) — ground only, so clicking a
person can never quietly become an order, and Esc always answers with
`Vector2.INF`.

**Picking (`gameplay/site_target_picker.gd`).** `resolve(main, origin, dir,
opts)` is the ONE crosshair ladder as a function of a ray, shared by the
first-person centre ray and the settlement mouse ray. The load-bearing line is
the **minimum angular pick radius** `r = max(PICK_RADIUS_M, t·tan(0.6°))` — at
500 m a person is sub-pixel and an exact sphere test is unclickable. Crossover
is ~52 m, so beyond that picking a NEIGHBOUR is correct behaviour, which is why
`--capture=settlement` only demands exact identity where the radius is under
4 m. Selftest carries an `EXPECTED_CHECKS` guard: a Godot runtime error aborts
the enclosing test function while PASS still prints, and instantiating a real
`NpcAvatar` in a bare SceneTree throws — the NPC rung is tested as pure
ray-vs-sphere maths for that reason.

**The labour merge.** `ChoreLedger` is now the **meter, not the supply**. A
`chore_hours` step without `require_confirm` stamps `recipe_waiting_kind =
"crew"`; `NpcPopulationBridge._service_machine_chores` mints an idempotent
chore keyed `mach|<gid>|<step_id>` whose `target` is the machine's
`bound_prop_id` (so people WALK there), and completion fires the new
`recipe_step_done` effect op through the post-tick sweep — the only place
completed work mutates the world, already fire-once. That calls the SAME
`RecipeRunner.confirm_chore` the player's button always did. ⚠ It must call
`ChoreLedger.record_worked`, not `try_debit`: finite labour means an empty
pool, an empty pool refuses the debit, and the step the crew just finished
would refuse to resume — the merge deadlocks by construction. A PACKED machine
mints an `unpack_prop` chore instead. `infinite_labor` is now the DIFFICULTY
switch, defaulting false **for new maps only** (`DEFAULT_INFINITE_FOR_NEW_MAPS`;
a loaded ledger keeps its own value, so no existing site silently stops
producing). `credit_available()` is deleted — it modelled a pool that stopped
existing. The contract is an EQUALITY, verified by `--capture=labour`.

**Facing (`core/population/npc_facing.gd`) — the "everyone works facing the
same way" fix.** `npc_population_host` used to write yaw ONLY while the body
was still moving (`if dir.length() > YAW_EPS_M`). `_step_traveling` sets
`pos = target_pos` on arrival, the rendered body converges, `dir` falls under
the threshold, and **the yaw latched on the approach heading for the whole work
session** — and since a non-brigade crew chore resolves to exactly ONE
coordinate, the whole crew walked one nav route to one point and froze on one
bearing. `_separate` then spread their POSITIONS by pushes capped at
`MAX_PUSH_M` 0.25, at or below the very threshold that would have re-triggered
the write, so the facings never followed. The fix is not a bigger epsilon:
`NpcAgent` latches a TRANSIENT `face_anchor` when it commits to a destination
(space centre before the slot offset / chore target / the relay's far end),
`agent_dots()` derives `face_yaw` from `(pos, face_anchor)` **every tick**, and
the host gates the travel branch on `in_transit` instead. Re-deriving per tick
is the whole mechanism — it is what finally lets the separation spread reach
the facings. Three subtleties: the anchor must be cleared in THREE places
(`_finish`, `release_claims` via `_finish`, and the engine's `_catch_up`); a
SOLO worker standing on their own anchor projects the arrival heading ~8 m
forward while a SHARED job keeps its anchor (`_chore_is_shared` — projecting
for a crew scatters the facings without aiming any of them, which looked
"fixed" while everyone faced out into a field); and the idle drift is bounded
in AMPLITUDE not rate, because beyond `FAR_DIST_M` the 0.25 s pose interval
turns the slew into a hard set. MP costs zero protocol churn — `_pack_frame`'s
`yaw` slot is meaningful only for possessed agents, a possessed agent never
runs the FSM planner, so the two are mutually exclusive and `flags` bit 0
already discriminates them. Pinned by `_test_crew_facing_spread` (circular
concentration R over a crew's facings, verified to FAIL on the pre-fix
behaviour with `R=1.000` and `7 of 7 within 20 deg of the walk-in bearing`),
its paired brigade opposite (`R > 0.9`, every station within 10° of the relay
line — so the rules are proven CONTEXT-AWARE rather than merely noisy), and
end to end by `--capture=population`'s facing-spread line.

**Task-aware work poses (`core/population/npc_work_pose.gd`).** A chore record
has no `kind` field and does not need one — the work is named by what it DOES:
`haul.strategy`, `carry_to`, a `chore_key` prefixed `mach|`, and above all
`effect.op` plus `effect.phase` (which carries the Linkage Lab's real
fabrication phase names). Deliberately NOT the free-text `label`, and not
`SiteProject.kind` (bridge-side, unreachable from a pure classifier).
`family_for` is TOTAL and returns one of seven families chosen to differ in
SILHOUETTE at ~60 m: `haul_hold` / `lift` / `dig` / `overhead` / `drill` /
`bench` / `inspect`. Rule 1 subsumes the pose machine's old `carrying` special
case. Plumbing: classified in `agent_dots()` (where the board is in hand),
rides the dot as `work_pose`, forwarded by the host, read by the machine as an
**INPUT** — which is what keeps the machine's purity contract. The families are
LOGICAL clips that `_clip_file_for` aliases onto `NpcRig.CLIP_WORK`, so the
rigged Mixamo body plays its single work clip unchanged while
`NpcSimpleFigure` (which already matched the logical name first, for carry)
draws the real family. That asymmetry is permanent until somebody authors more
Mixamo clips. ⚠ `merge_catalog` must be applied at `NpcAvatar.setup`, NOT
inside `NpcRig.catalog()` — that function answers "what art is installed" and
has other callers; without the merge every `_has()` guard skips the families
and their transitions on a fresh clone, silently, on exactly the body they were
written for. (The same condition means `sleep_enter`/`sit_enter` do not play on
a fresh clone either — a real gap, deliberately not widened here.) Per-agent
flavour (mirror / amplitude / stance / tempo / lean / variant) is cached in
`NpcSimpleFigure.setup()`; ⚠ **tempo scales each pose's own frequency constant,
never `_phase`'s advance**, which is what rate-matches the walk to apparent
speed. `work_enter`/`work_exit` are the one new transition pair — the exit is
the one that pays, since a worker used to snap out of a deep stoop into a
stride.

**`NpcHash` (`core/population/npc_hash.gd`).** One avalanche hash for every
per-agent scatter, lifted BIT-IDENTICALLY from `NpcRoutine.offset_for` (pinned
against a frozen literal, because routine offsets move every downstream sim
golden). Measured over 64 sequential ids in 8 bins: the naive `hash() % n` form
leaves FIVE BINS EMPTY with 30 of 64 in one; the avalanche fills every bin.
Two deliberate non-adopters: `NpcAgent.name_for` (snapshot only persists
`display_name` when it differs, so changing it would rename every unnamed
person in every save) and `color_for_agent` (already avalanched).

**Authoring depth.** The Routines panel exposes `priority` as three named bands
(never a raw int — it is uncapped and LOWER sorts first), one crew-size pair,
`repeat`, and the highest-value control, `target` via "Where…". Without a
target a hand-authored chore has no position and the worker does it where they
stand, which reads as broken. `depends_on`/`haul`/`effect`/`stage_effects`/
`carry_to` stay unexposed: that is the project compiler's vocabulary. The Site
Project panel gained a one-task "New project…" row (same reason — the
generators split into phases because they KNOW what the phases are) and a
per-project **Watch** button that opens the settlement view over that site.
`space_edit_ui.set_ray_source(Callable)` is the seam that lets the mode drive
the same polygon state machine rather than growing a second drawing UI.

**The work dock (`scenes/settlement/work_dock.gd`).** The chore board, inside
the settlement view, because editing the work and watching the work used to be
mutually exclusive — the board lived in a full-screen modal over the 2D graph,
so "retune a priority, see the crew re-form" meant closing the only surface
that shows the crew. It carries the queue in WORK order with live crew
fractions and exactly three knobs, all of which change a CONDITION: priority
band, hold, and look-at. Deep authoring stays in the modal, one button away.
It inherits the mode's no-order-verb rule verbatim. It rebuilds only when a
content SIGNATURE changes, not blindly every tick — a blind rebuild dismisses
tooltips mid-hover and makes a button impossible to click twice, which is most
of why the modal panels feel unresponsive. ⚠ That signature starts at a
sentinel, not `""`: an empty board produces an empty signature, so `""` would
compare equal on the first pass and the empty-state row would never build.

**Work-UI polish.** Both big panels now route every button through
`UITheme.style_button`, use the `FONT_*` scale, and take their palette from
UITheme (the local `C_OVER`/`C_FREE` were near-misses of `C_ERROR`/`C_GREEN`,
so two reds and two greens meant the same thing on one screen);
`UITheme.style_progress` exists because a stock Godot `ProgressBar` was the
only light-grey chrome in a dark panel, and a work UI is mostly progress bars.
The chore board is **sorted into the order the crew actually works it** —
`board.chores` is insertion order while `available_for` sorts by priority, so
the list the player read was never the queue, which made the priority control
two rows below it look inert. Rows now surface the live crew fraction, the
repeat mode, whether a chore is held or dependency-blocked, and whether it has
a PLACE at all (a chore with no target happens wherever the worker is standing,
which reads as broken). Two real bugs fixed alongside: the "Where…" round trip
called `close()`+`open()`, which re-ran the draft loaders and silently
discarded an unapplied routine or animation edit; and the project panel
reported failures by mutating a `LineEdit`'s placeholder, invisible the moment
anyone types.

## Graph view UI pass (2026-10-14) — freeform cards, flow, force layout

Plan: `~/.claude/plans/yesterday-we-did-a-graceful-candy.md`. Found by
playing the bootcamp through `--capture=bootcamp` (the regression gate).
- **Force layout** (`GraphForceLayout`, pure; `GraphLayoutDriver` runs it on
  the live canvas). Layout ▾ → **Tidy** (animated, ONE undo step), **Live**
  (keeps running; a dragged node is pinned while held; edits reheat), Pin /
  Unpin (`specs.layout_pinned`, lock glyph), **Layout settings…** (Spacing,
  Wire length, Flow direction, Gravity, "Keep each layer on one line";
  `ui_prefs.cfg [graph_layout]`; Live rides the save state as `layout_live`).
  Flow direction comes from the PORT SIDES (inputs top, outputs bottom), so
  sources settle above controllers above storage above loads; components with
  no directed wire keep an organic web. Manual stays the default; bootcamp
  seeds auto-Tidy. Positions are written straight onto the live item dicts
  while animating (update_item would fire the view's cascade per node per
  frame); the settle commits one history entry + autosave. Round tanks /
  catchments get a layout box widened by their caption (`scope_items`).
  "Arrange" is now "Only remove overlaps".
- **One card anatomy** (`GraphCard` draw + LOD, `GraphCardSpecs` per type,
  `GraphTheme` tokens) for panel / battery / controller / load: header (icon,
  name, chip), hero number, sub line, bar (+ ghost band for a clipped
  controller), footer, centred alert + RESET. Other types keep their old
  renderers. Display settings (View options → "Display settings…",
  `ui_prefs.cfg [graph_display]`): unified cards, hover path highlight, flow
  when paused, wire value pills, the freeform SoI ring (default OFF).
- **Flow** animates whenever flow is active and the clock runs OR a run plays
  back OR "flow when paused" is on. Wire pills (UiText.num) skip any spot that
  would collide with a card or another pill; a PV wire carries its STRING's
  watts (`_panel_string_w`), not the site total.
- **Selection:** Ctrl-click and Shift-click toggle; ⚠ `_begin_item_press`
  must not re-select when the press lands inside an existing multi-selection
  (it collapsed every Ctrl-click selection — L12 could not be completed), and
  V2's Ctrl+LMB wire pick only fires with no item under the pointer.
- **Bootcamp:** fault cards queue cleared on level load/exit
  (`GraphFaultCardModal.clear_queue/dismiss_all`); a ~2.5 s CELEBRATE state
  before the debrief, which docks to a corner; run levels start at 30 % SOC
  (`DEFAULT_RUN_START_SOC`); a missed run shows a verdict; unwired panels
  count 0 W in the sandbox; the real-world projection / best score are hidden
  while sandboxed; the live globe dims to a backdrop during a run (shader
  `opacity`, container modulate does nothing to it); a newly wired AC load
  defaults ON; the TEMP dev card-text editor (`--card-editor`,
  `EducationCardOverrides`) was removed on 2026-10-18 — card copy is
  edited in `GraphEducationCards` / the tutorial catalog. The DC throttle
  runs display-only while the ambient flow is suspended (bake / playback) so
  the controller card follows the playback without touching SolarUI's cap.
- Freeform drags push ONE history entry on release (`items_moved`).
- `--capture=graph` now really shoots freeform (`01b_freeform`), Tidy
  (`02b_freeform_tidied`) and prints `graph tidy: N item(s), M overlapping
  pair(s) PASS|FAIL`.
- **One energy story per frame.** Panel cards, the controller card, the
  battery card and the dashboard's "Making" all derive from SolarUI's
  `current_solar_kw` on the SAME SolarUI tick (`sim_tick_serial`; the view's
  `_tick_dc_throttle` and the dashboard both sync when it moves).
  - Per controller, `_dc_throttle_pass` writes OFFERED (`dc_array_w`, its
    Wmp share of `_raw_solar_kw`), CAP (`dc_cap_w`, V × A) and DELIVERED
    (`dc_delivered_w`). Delivered is `current_solar_kw` split over the caps
    (`GraphDcElectrical.split_actual`). It also writes `dc_curtail`
    (battery_full / battery_topping / held_back) as the reason.
  - Panels get their controller's delivered share (`_pv_live_w`) plus
    `pv_offered_kw` / `pv_curtail`, so they sum to it.
  - The caps reach SolarUI as a FUNCTION of raw (`set_graph_dc_caps`,
    `GraphDcElectrical.delivered_for_caps`), for the live tick and the bake
    alike. A single watt figure frozen when Run was pressed used to cap the
    whole baked day: level 10 read 17 % of the sun used, now 57 %.
  - In playback, `SolarUI._apply_playback_readouts` takes solar / load / raw
    from the BAKED series at the playhead.
  - The battery-full taper no longer keeps a constant +0.1 kW "top-off", which
    read as "▲ 100 W" on a full battery. It is aux-aware.
  - World shade (`_tick_graph_solar_shading`) skips the tutorial sandbox.
    Level 8's panels were ray-cast into a Mount Vernon tree's shadow and read
    0.2× of the controller.
  - `--capture=bootcamp` FAILs on a settled shot whose readouts disagree.
    Those shots are c_running / d_playback / f_after / h_clean / g_verdict;
    the check covers panels vs Making, controller vs Making, dashboard vs
    Making, and a full battery reading as charging.
  - **Shade is one model (2026-10-14):** a placed panel's `sunlight_factor`
    lowers what the ARRAY makes; nothing is redistributed to sunlit panels.
    - The throttle pass pushes the placed panels to
      `SolarUI.set_graph_pv_shade(receivers, total_wmp)`. Each receiver is
      `{wmp, group = controller cap index, pos, s}`.
    - SolarUI scales the live output by the Wmp-weighted factor
      (`_apply_graph_pv_shade`).
    - `graph_dc_delivered_kw` re-splits each controller's share by its own
      panels' shade (`GraphSolarShading.shaded_caps`).
    - `evaluate_solar_at` ray-casts every rendered instant
      (`factors_at`, ≤ 48 merged origins).
    - The cards split by effective Wmp (wmp × factor), so they still sum.
    - The old one-point `_shadow_raycast_enabled` test is skipped while
      graph shade is on. The sandbox pushes no receivers.
    - Verify with `tools\harness.ps1 -World mtvernon -RunScript
      res://tools/checks/pv_shade_consistency.gd`. It runs in the sandbox:
      four placed panels, one in a shadow.
    - A controller that stops being a PV route now zeroes its `dc_*`
      watts. It used to show its last delivered figure forever.
    - Only `panel` items are receivers: Mount Vernon's own array is one
      `compound` and is not shaded.
- **Wire bundling** (`GraphWireBundles`, pure; pinned in
  `graph_wire_routing_selftest`): wires sharing a port leave it as one short
  trunk, then fan into evenly spaced lanes ordered by where their far ends
  sit (no crossings in the fan); the curve starts at the lane's tooth. Plan
  built per draw in `_draw_connections` (`_bundle_plan`) and reused by the
  wire hit test, so a click lands on the wire you see. Bezier style, freeform
  only; hub (round tank) ends skip it. Display pref `wire_bundling`.
- **Every freeform card is a GraphCard** now: wind, hydro (`hydro` and
  `siphon_hydro` machines — footer = `SiphonStateRing.state_for`, the 3D
  ring's own words), machines (CSP, habitat, generic), tanks, groups (array,
  battery bank, load group, camp, generic / component). `spec.media` reserves
  a picture zone (`GraphCard.media_split`) the canvas fills in
  `_draw_card_media` (GLB thumbnail, group miniature, banner, panel grid).
  Tanks draw round (`GraphCard.draw_hub`) so hub ports stay on the rim.
  Model-thumbnail controllers / loads keep their full-bleed picture.
- Ports: names beside the dots from zoom 1.0 (Display pref `port_names`,
  `_draw_port_annotations`; names grow outward along the edge, cut at the
  next port) and a wire-count badge on any port with ≥ 2 wires.
- Bootcamp keeps the camera across levels (`tutorial_clear_graph` passes the
  pan / zoom through); `tutorial_frame_if_needed` re-frames only when the
  level's content (Tidy's target) would fall outside the canvas, never past 1×.
- **Top bar = captioned clusters** EDIT / STRUCTURE / PLAY / LENS / DISPLAY
  (`_topbar_cluster`), identical in every lens. The lens-only controls
  (Designate, Slice, Globe radius, Hydro Lab, Radial / Array / R) moved into
  a row of the lens strip on the canvas (`_lens_slot`, built in
  `_build_lens_strip`); Site Plan's tool row used to push every label off the
  bar. Challenges / Bootcamp are labelled (fold to icons in the fit).
- **Draw cost (measured 2026-10-14, `tools/bench/graph_draw_bench.gd`, a
  dry-run `-RunScript`: 60 nodes / 76 wires in the bootcamp sandbox).** On
  this build one `draw_circle` costs ~9 µs, an outline circle ~13 µs and one
  `draw_style_box` of an anti-aliased rounded StyleBoxFlat ~16 µs (both are
  re-tessellated every call), against 0.1 µs for `draw_line` and 1–2 µs for
  `draw_string`; `get_string_size` is 0.15 µs (the engine caches shaped
  text). A port dot was five circles and a card six style boxes → ~14 ms a
  draw. `GraphFastDraw` (cached anti-aliased white textures: `disc`, `ring`,
  `rrect`, `rrect_border`, two-tone `rrect_box`) replaces them in GraphCard,
  the port dots and the wire pills; never put `draw_circle` /
  `draw_style_box` back in a per-node or per-port path. Also: one
  `draw_polyline` per bezier stroke, curve sampled once per wire; per-draw
  caches for resolved handles, wired ports and handle info (`_handles_cache`,
  `_wired_cache`, `_hinfo_cache` — valid while `_draw_cache_active`; the
  handle-info dict is SHARED, copy before mutating); `draw_primitive` for
  flow arrows. ⚠ PerfMonitor's `gv_draw` (the F3 figure) is a PER-FRAME
  average and the canvas draws every few frames, so it reads ~3× low while
  flow animates; the bench prints both. Now: one draw ~7 ms (was ~14),
  `gv_draw` < 1 ms per frame. The 20 Hz cadence now runs only while a wire
  actually animates (`_flowing_drawn`); "animate flow when paused" had made
  it permanent.
- ⚠ `HarnessInput.mouse_move` warps the real cursor with
  `vp.get_final_transform() * pos`: `Input.warp_mouse` takes WINDOW pixels,
  and warping to the logical point put the cursor 1.2× off at 1280×720 (UI
  scale 1.25); the OS's own motion event then dragged every hover and wire
  drag there. That alone failed the 720 bootcamp (58 failures → 0).

## Solar Bootcamp tutorial + pre-baked challenges

**DC electrical layer (`system_graph/graph_dc_electrical.gd`, sibling of
PvElectrical, both over `GraphNesting.flat_connections`).** Battery-bank
topology via a weighted union-find over conductive nets (KVL
potential-consistency: an inconsistent constraint IS a closed loop with net
EMF = a **short circuit**; equal-voltage parallel banks are consistent and
clean). Derives bus voltage (series sums), capacity, S×P counts, chain
mismatch. `find_battery_overvoltage` = PV reachable with no live controller
in the path and string Voc > 1.217×nominal charge ceiling.
`controller_throttle` = P ≈ V_bus × max_charge_amps (Victron PWM/MPPT paper)
— the previously dead preset amp specs made live.
`system_graph_view._check_electrical_faults` (renamed from
`_check_pv_voltage_faults`) trips all three fault families; shorts sever the
loop's wires (reuses conduit burnout severing); batteries share the
controller's DESTROYED/RESET canvas contract; cards live in
`GraphEducationCards.card_for_fault` keyed by `GraphNodeState` reason and
present through `GraphFaultCardModal` (queued; replaced the hand-rolled
overlay whose `%`-precedence format bug is now selftest-guarded).
`_tick_dc_throttle` runs AMBIENT (graph closed too) and pushes the summed
delivery cap into `SolarUI.set_graph_dc_limit_w` (−1 = no cap; PV not routed
through a real controller+bank passes uncapped so freeplay is untouched).

**Tutorial (`gameplay/tutorial_*` + `scenes/ui/tutorial_hud.gd`).** 12
data-driven levels (`TutorialCatalog`): short circuit (failure IS the win) →
overcharge → PWM 120 W → array scaling 360 W → 24 V/720 W → 48 V/1200 W →
3S2P string sizing → 24 h runs with loads/utilization → Ctrl+G power-station
merge → unlock_all. Goals (`TutorialGoals`) are pure TOPOLOGY predicates
("deliverable watts" = min(array W, bus×amps)) so they read the same at
midnight and selftest offline; run-levels are judged from bake results
(`evaluate_run`). `TutorialDirector` (lazy SystemGraphView child, 🎓 toolbar
button) owns flow + the **sandbox**: `begin/end_tutorial_sandbox` snapshot
and restore the player's real graph, `collect_save_state()` RETURNS THE
PRE-STATE while sandboxed (autosave also flag-suspended), an external
apply_save_state drops the sandbox (incoming wins, `sandbox_interrupted`),
solar_bridge is `set_enabled(false)`d, and the director snapshots clock +
battery SOC so tutorial runs can't leak time into the real world. Unlocks
persist in `ProgressStore` (`user://progress.json`) — **no file = everything
unlocked** (grandfathering for existing installs); the first-load prompt
(new players, headless/harness no-op) offers bootcamp vs skip-unlock-all;
`library_panel` gates categories/presets by unlock (keyed by preset LABEL)
with a per-level `tutorial_preset_filter` override. Trainer presets (300 W /
40 Voc panel, PWM 10 A, MPPT 150/30) make the curriculum numbers exact.

**Pre-baked challenges (`gameplay/challenge_bake_engine.gd`).** `run_mode:
"prebake"` ChallengeDefs (span day/month/year → 1/4/38-min sample steps,
sized to the 20160-sample timeline caps) compute the WHOLE span in seconds:
energy via SolarUI's `_sim_series` (reused so the timeline's SIM clip lane
draws the bake for free), resources via `ResourceFlowEngine.render_step`
(AC availability injected from the co-baked SOC), population via
`NpcPopulationBridge.tick_at` at ≤0.1 h substeps (never the stochastic >6 h
catch-up). Failure = power failure (SOC PINNED at the floor while net<0,
sustained 0.25 h — the clamp means SOC never reads below the floor),
colony collapse, or stockouts; playback sweeps the playhead ~20 s reading
baked buffers (battery read-through, `seek_all_tanks`), parks at the
breakpoint, and **retry replays the SAME segment** against the player's
edits (specs/NPC/battery snapshots restore; wiring changes survive).
Ownership discipline mirrors the video exporter: time_scale 0 + the view's
`set_ambient_flow_suspended` (the ambient tick would otherwise rewind tank
specs mid-bake via its frozen-clock scrub path); every exit through
`_release_world()`. ChallengeRunner maps engine signals onto the classic
challenge_started/failed/won wiring (main.gd/timeline/picker unchanged;
realtime challenges byte-identical; runner refuses to start over an active
tutorial sandbox and vice versa). "Useful utilization" = (loads served +
charge banked)/potential — the generated-solar channel reads ~100% even
while the battery-full clamp wastes sun, so it is the wrong teaching number.

## Extreme weather (core/weather/)

Eleven hazards in `HazardCatalog`; four SIMULATED so far (wildfire smoke, dust
storm, damaging winds, heatwave), the rest are risk-profile-only rows marked
"not yet simulated". Master toggle is `GameplayRules.extreme_weather_enabled`
(**default false**, save- and scenario-scoped like every other mechanic);
per-hazard opt-ins + the "Drama" slider live in `ExtremeWeatherPrefs`
(`user://extreme_weather.cfg`). Settings → **Extreme Weather** tab shows the
site's real risk profile and a non-persistent **Preview** control.

**Severity is a PURE FUNCTION of absolute hours.** This is the load-bearing
constraint, not a stylistic choice: it is why hazards scrub backwards, replay,
and bake into prebaked challenges for free. `crisis_events/crisis_event_manager.gd`
is therefore the WRONG host — it rolls triggers on real seconds and PAUSES every
event whenever `time_scale != 1/3600`, so weather there would vanish at any speed
players actually use. Dependency direction is one-way: a crisis event may READ
the director; the director never reads crisis state. `hazard_began`/`hazard_ended`
are derived by DIFFING the evaluated set, never by a trigger, so rewinding out of
a smoke event emits `ended` exactly as fast-forwarding past it does.

**Four-layer resolution ladder** (`ExtremeWeather.resolve_at`): NWS/IEM alert
spans (authoritative timing, 1986→now, US) → measured AQ + weather (shapes the
alert into an hourly curve, and can raise a hazard on its own) → deterministic
climatology synthesis (ONLY where layers 1-2 have no DATA, not merely no event —
otherwise you invent smoke onto a verifiably clean day) → `blank()`.

**`HazardState` is the one contract.** `blank()` is the IDENTITY element and
`combine()` is commutative; optics take the worst, energy factors MULTIPLY.
`AtmosphereApplier.resolve(base, blank())` returns `base` field-for-field — that
single property is the "feature off ⇒ zero visual change" guarantee.

Traps, each of which RENDERS rather than erroring:
- **`fog_aerial_perspective` moves DOWN under haze, not up.** With
  `fog_sky_affect = 0` it blends the *rendered sky colour* into distant geometry,
  so raising it under smoke pushes terrain toward BLUE.
- **`fog_sky_affect` alone cannot take over the sky**, because the fog colour is
  simultaneously the terrain haze — which must be dark while the sky is luminous.
  Hence the `hazard_haze_color`/`hazard_haze` block in `sky.gdshader`, applied
  BEFORE the sun block so the disc survives as a dim red ball. Daylight-gate it
  or nights go brown and starless.
- **`weather_light_factor` has one owner** (`solar_ui._apply_smooth_weather_lighting`,
  rewritten every frame). Hazard dimming is a SEPARATE `_hazard_light_factor`
  multiplied alongside it in `_update_sun`.
- **`_apply_advanced_rendering_toggles` owns volumetric fog** and is reachable
  straight from the settings panel, so the emissive dust wall is forced there,
  not at the environment choke point — writing both erased the wall on any
  god-rays toggle.
- **`clampf` does NOT filter NaN**, and CAMS returns real null hours. Every 0..1
  factor in the applier goes through a NaN-safe clamp; the selftest sweep exists
  because three of them originally did not.
- **`SolarIrradiance.ghi_wm2_at_calendar` short-circuits on `has_real`** and
  returns measured GHI verbatim. Aerosol is applied on THAT branch too, or
  extreme weather is silently free of consequence on exactly the sites that have
  real weather data. Open-Meteo's shortwave field carries only climatological
  aerosol and does not resolve plumes — which is why CAMS publishes it separately.
- **Four weather samplers exist** with different key names. They are not unified
  (too risky across the prebake path); instead all four call
  `SolarIrradiance.decorate_with_hazard` and the selftest pins that they agree.
- **`NpcWeatherGate` air uses a SECOND exposure factor**
  (`air_exposure_factor`), never a change to `exposure_factor` — walls stop rain
  completely but only damp smoke, and every existing threshold depends on the
  original returning 0.0 indoors.

**Severity-curve design lessons** (both shipped broken once): anchor severity 1.0
at the observed EXTREME TAIL, not a category boundary — anchoring smoke at the
EPA "Hazardous" threshold rendered a hazardous day as light haze. And check the
curve SHAPE, not just monotonicity: the selftest's cliff guard compares each
step's ratio against the MEDIAN step, because a uniformly steep curve is
legitimate (dust fronts really do arrive fast) while one anomalous step is not.
Related: the US AQI truncates at 500 by definition, which smoke reaches by ~0.6
severity, so gameplay channels derive from SEVERITY while the displayed AQI stays
truncated like the real index.

**Wind-blown dust + the smoke/dust look swap (2026-10-21).** Dust used to fire
only from CAMS dust readings, which cover a ~99-day window, so a windy desert
site (Bombay Beach, `w6ad922917357`) never got dusty. Now:
- `HazardEvaluators.evaluate_dust_storm` = max(measured AQ dust,
  `evaluate_wind_dust`). The wind layer is the player's rule: 10 m wind above
  `ExtremeWeatherPrefs.dust_wind_mph` (10) with no rain ≥ 0.1 mm in the last
  `dust_dry_hours` (24). Severity follows a Bagnold/Gillette flux
  u³(1 − (ut/u)²) normalised at 20 m/s, through the inverse of the dust PM10
  curve: ~0.1 at 12 mph, ~0.55 at 30, 1.0 from 45 mph. `dust_climate_scale`
  multiplies the flux by `dust_ground_factor(annual precip)` (1.0 under
  250 mm, 0.2 by 1000 mm), so Mount Vernon raises a fifth as much.
- The director puts `rain_prev_mm` (`HazardEvaluators.rain_in_window` over
  WeatherService's hourly precipitation, cached per whole hour, cleared by
  `invalidate()`), the threshold and `dust_ground` into the sample; still a pure
  function of the clock. `dust_drivers_now()` feeds the Settings line.
- Settings → Extreme Weather → "Wind-blown dust" (wind mph, dry spell h,
  climate scaling, a live "Now: wind … → dust N %" line). Prefs `[dust]` in
  `extreme_weather.cfg`. The MASTER switch is still per world and OFF by
  default — Bombay Beach's snapshot has it off.
- **The look swap.** The old dust rendered as a glowing orange dome (the emissive
  volumetric wall + an orange-biased sky lift) and read as wildfire; the old
  smoke read as low brown haze. Only LOOK fields moved; AOD, PM, visibility,
  sun_energy_mult, energy and life channels stayed with their hazard. Smoke:
  grey-brown, `sky_tint` sev × 1.25, `horizon_bias` 0.25 (the whole dome),
  red disc. Dust: tan/ochre, `horizon_bias` 0.92, pale sun, glow halved,
  `haze_layer_m` 30–350 m. Two new HazardState fields: `horizon_bias`
  (→ sky.gdshader `hazard_horizon_bias`; combine blends by severity) and
  `haze_layer_m` (combine takes the deeper).
- A dust layer is drawn by main.gd as a SECOND GroundFogLayer (`DustLayer`,
  `_update_dust_layer`): top = ground under the camera + `haze_layer_m`,
  σ = 1.5 × the hazard's Koschmieder σ (`AtmosphereApplier.volumetric_for`
  `layer_*`), tan, drifting with the wind (`drift_cap_ms`/`drift_frac`,
  `keep_hue`). With a layer the uniform froxel fog is only a quarter-strength
  veil and `vol_sky_affect` 0.35, or it fills the sky again. The sky lift is
  `AtmosphereApplier.lift_sky_color` (hue-preserving; main.gd's per-channel
  ×1.9/1.7/1.5 turned tan yellow). `sky_affect_scale(bias)` trims
  fog_sky_affect for horizon-heavy hazards only (bias ≤ 0.65 → unchanged).
- **Dust look v2 (same day, to the player's whiteout photo).** No particles
  (`particle_kind` ""; `haze_layer_m > 0` is what marks dust for
  `volumetric_for` now, the microclimate's grain dust keeps the old path).
  Light dust stays a low layer on the horizon; from ~0.3 the horizon bias
  falls to 0.05 and `sky_veil` climbs to 1 — sky.gdshader's `hazard_veil`
  block at the very END of `sky()` covers sun, moon, clouds and stars, and its
  colour darkens with the night (`AtmosphereApplier.sky_haze_for` `veil` /
  `veil_color`); a full tint now reaches the whole gradient. Whiteout light
  is bright and flat (`ambient_mult` up to 1.7, exposure +0.12), and the fog
  colour target darkens at night for every hazard (`NIGHT_HAZE_LIGHT`). The
  player's look lives in `ExtremeWeatherPrefs` `[dust_look]` (colour default
  0.82/0.79/0.74, Thickness default 2.0 → `optical_mult`, Hides the sky,
  Layer height, Wind streaks) and touches no physics channel —
  `visibility_m` stays physical, the applier multiplies fog and layer σ.
  Settings → Extreme Weather → "Dust look" (+ Reset look). The dust layer
  streams with the wind: ground_fog.gdshader `wind_dir` / `streak` (noise
  stretched along the wind) / `gust_amount` (broad bands sweeping downwind);
  defaults reproduce the valley fog exactly. Selftests pin the shipped look
  with `ExtremeWeatherPrefs.use_defaults_for_test()`.
- Verify: the selftest (`_test_smoke_dust_look_swap`, `_test_dust_look_controls`, `_test_wind_blown_dust`)
  and `tools\harness.ps1 -World w6ad922917357 -RunScript
  res://tools/checks/bombay_dust_check.gd` (2024-04-14 15:00 28.5 mph dry →
  storm; 12:00 6.3 mph → none; 2024-02-07 15:00 19.1 mph after 1.5 mm → none;
  22:00 14.9 mph → light; forced smoke vs dust shots).

## Microclimate calibration (core/microclimate/ + 🌫 timeline drawer)

Weather models are 10–30 km cells; a valley floor fogs hours before its cell
saturates and an open playa blows harder than its station. Autoload
`Microclimate` (`MicroclimateResolver`) is a PURE FUNCTION of abs hours (the
ExtremeWeather rule — scrubs backwards, no timers) layered on the weather data:
pinned observations > rules + nearest-match > automatic fog (`FogDiagnosis`),
blended by `MicroclimateProfile.blend` (fog/haze in EXTINCTION space, worst
wins). Per-map `user://maps/microclimate_<lat>_<lon>.json` holds looks, rules
(soft conditions + a `hold` so fog lingers until burn-off), observations and
input corrections. Deliberately NOT in TerrainCacheSettings' reset sweep.
- **Fog evidence, worst wins:** ERA5 reports radiation fog as ~100 % LOW cloud
  at T−Td ≈ 0 (the cloud is on the ground — `ground_cloud` is taken back OUT
  of the sky's cover in `solar_ui._update_sky_visuals`, never out of
  `cloud_cover`, which PV reads); HRRR's `visibility`; a radiation index with a
  terrain cold-pool bias (TPI at 1/2.5 km → 0.03 °C/m, cap 3).
- **Data:** WeatherService now fetches `dew_point_2m`, `cloud_cover_low`
  (+ forecast `visibility`), past_days 14, and the CURRENT YEAR's partial
  archive (`om_v5_*_<year>_partial.json`, daily refresh) — before it a 2026
  date outside the forecast window silently showed 2025. `_sample_forecast_var`
  indexed by hour-of-year (always the window's LAST hour) — fixed.
- **Visual vs physics:** `visual_hazard()` combines with ExtremeWeather in
  main.gd (`_combined_visual_hazard`) and the veg wind driver; `physics_hazard()`
  (only looks ticked "affects physics": τ = σ·depth as AOD) in
  `SolarIrradiance.hazard_at`. Unconditional physics CORRECTIONS (playa wind
  ×1.5) live in `MicroclimateCorrections`, a static the WeatherService
  accessors apply (WeatherService must not name the autoload); conditional ones
  degrade to visual-only.
- **Ground fog** = `GroundFogLayer`, one camera-following FogVolume whose
  shader caps fog at an ABSOLUTE world height (valley floor + depth), so ridges
  stand out of it. Forces the volumetric pass on while present (dust-wall rule)
  and sizes `volumetric_fog_length` so the drone still samples it. Three traps,
  each of which rendered "no fog" or "black fog" with no error: (1) the
  terrain context is measured only once `TerrainLoader.load_completed` — the
  detail footing exists earlier but answers in metres ABOVE SEA LEVEL (Walton:
  floor y 119 vs people at y −100); (2) the floor is the LOWEST ground within
  ~1.5 km of the marker, and the box reaches down past the camera — a fog hung
  from the marker floated 200 m over the property; (3) the droplets carry a
  skylight EMISSION (DaylightModel.sky_light), because the player's ambient
  multiplier can be 0 and a dawn fog lit by the low sun alone reads as black
  murk. Harness shots need ~1 s after a camera jump: volumetric fog reprojects
  90 % of the previous frame and smears the last viewpoint's fog.
- **Volumetric fog slider fix:** the "Fog amount" slider used to touch only the
  exponential fog (+0.00015); the plain volumetric branch never wrote density,
  so the scene's 0.2546 /m (≈15 m) rendered at any setting. Every branch of
  `_apply_advanced_rendering_toggles` now composes density explicitly from
  `FogOptics.volumetric_density_for_amount` (0 → exactly 0), never reading it
  back, and writes the full parameter set; it now runs AFTER the hazard pass.

## Multiplayer shared world: changes, approval, bodies (2026-10-20)

The host's world IS the shared world. PROTOCOL_VERSION 4 (old builds neither
join nor see new ones).
- **Changes travel as ops, not snapshots** (`MpChangeSet`, pure). The old
  sync sent the whole props layer + whole graph save state on every edit
  and every 12 s; the receiver rebuilt EVERY prop and applied the host's whole
  save state (lens, camera, scope too). On top of that the loader's delete /
  duplicate / editor commit / pack paths never notified, so most edits only
  arrived on the 12 s resync — the "5–10 s" the user saw. Now:
  - props diff by id against the last published copy; the receiver upserts or
    removes ONE record (`PlacedPropService.mp_upsert_record` / `mp_remove_record`
    / `mp_finish`; a pose-only change slides the node, an OSM replacement
    forces the full rebuild). Every loader prop save goes through
    `_save_props_and_share()`.
  - graph diffs adds/removes by id and "changed" only for ids a PERSON wrote
    (`GraphModel.take_mp_touched()`, recorded when `sim_writing` is false),
    compared through `MpChangeSet.authored` (VOLATILE_SPEC_PREFIXES stripped —
    extend it when a new sim writer stamps a spec key). Applied through the
    model's own CRUD (`SystemGraphView.apply_shared_graph_ops`), so undo
    history, tank timelines and the viewer's camera survive.
    `apply_shared_graph(blob)` (whole graph, keeps the view) is only for the
    join snapshot.
  - Guests don't run the flow engine: every 2 s the host sends the volatile
    spec values that moved (`volatile_frame` → `apply_shared_sim_state`, sim
    writes) plus `design_rev`; a guest behind that rev asks for the full world.
  - Guest graph ids are `p<peer>_item_N` (`GraphModel.id_prefix`) so they
    never collide with the host's.
- **Guests propose, the host decides** (`mp_design_controller.gd`). A guest
  edit shows locally at once and goes as a proposal after a 0.45 s quiet
  period (a drag = one proposal). The host's `guest_policy`: ask (default) /
  auto / view; per-peer "Always accept". The card text is worded ON THE HOST
  from its own copy (`summarize`) — guest text is never shown. Waiting changes
  draw as ghosts (`MpReviewGhosts`, guest colour; removals red). Decline →
  the guest's copy is put back (`revert_props` / `revert_graph` against the
  canon). Alt+Y / Alt+N take the oldest without freeing the cursor.
- **Feedback** (`scenes/ui/multiplayer_activity_hud.gd`): the sync line
  (top centre: waiting / accepted / declined / getting the world N %), the
  host's review cards (FIRST in the top-right column — Terrain options draws
  taller than it reports and covered them at order 1), edge arrows with
  name + distance for off-screen players (projected in CAMERA SPACE first:
  `unproject_position` errors for a point on the camera plane). Lobby →
  Design: the policy picker + counts; each player row has "Go to" + distance.
- **Guests play in a throwaway world** (`MpGuestWorld`,
  `user://worlds/_mp_guest/`). Joining used to write the host's props and
  graph over the guest's OWN files for that site. Now the guest's world is
  saved, their own files for the host's site are copied in (terrain edits,
  veg, water — what the sync does not carry), and WorldPaths points there.
  Leaving keeps the copy (it says so); exit to the menu to get back.
- **Bodies.** `RemotePlayerAvatar` is the NPC silhouette `NpcSimpleFigure`
  in the player's own outline colour (sent in presence), posed from their
  `player.net_body_state()` (8-float packet: mode idle/walk/run/air/drive/euc,
  rate, vy, steer, aim, seat), drawn 0.12 s behind the newest packet and
  interpolated, x-ray constant-size name tag with distance, a ring at the
  feet. The PLAYER's default body is now the same silhouette
  (`PlayerPrefs.BODY_SILHOUETTE`); the detailed figure is
  `BODY_FIGURE`.
- **Chat** registers with HudLayout (bottom-left, above the timeline), takes
  the mouse only while typing, fades when idle, and Enter yields to tool
  overlays, focused controls and the graph (`_may_open`). It used to sit ON
  the timeline with MOUSE_FILTER_STOP and eat its clicks.
Not synced yet: vegetation painting, sculpting, water edits, camps, J lights,
the SoI after the join snapshot — those still differ per machine.

## Discord-native multiplayer (core/discord/ + core/multiplayer/)

Goal: a private community on one Discord server drops into a shared world with
Discord handling identity, discovery and voice. **Zero always-on servers of
ours.** Full plan + remaining phases:
`~/.claude/plans/i-want-to-do-flickering-torvalds.md`. One-time Discord
developer-portal setup: `docs/LOCAL_CONFIG.md`.

**The structural rule:** every security-relevant decision lives in a PURE
`class_name` file with no HTTP (`discord_pkce`, `gate_rules`, `community_file`,
`directory_record`, `relay_batcher`, `discord_links`, `discord_config`, plus
`MpReachability`'s classification half), so `core/discord/discord_selftest.gd`
feeds it fixtures offline. The Node halves (`discord_http`, `discord_identity`,
`discord_gate`) only fetch. Do not move a verdict into a Node.

**Sign-in** is OAuth2 authorization-code + **PKCE with no client_secret**
(needs the app's "Public Client" toggle — without it every token exchange 401s,
and Discord's own error text does not say so, which is why
`discord_identity._on_token_response` appends the hint). The code arrives in the
redirect's QUERY STRING, so a loopback `TCPServer` is enough — no JS shim, which
the implicit grant would have required. **The redirect port cannot be dynamic**
(Discord demands an exact registered match): three are reserved, 34199–34201,
and binding falls through them; all busy = a loud refusal, never an unregistered
port. The callback socket is held ~0.75 s before closing so the browser actually
renders the "you can close this tab" page. Scopes are deliberately
`identify` + `guilds.members.read` only — the broad `guilds` scope would let a
host holding a guest's token enumerate every server that guest is in.

**Reachability.** `pick_lan_ipv4()` returns an RFC1918 address by design (LAN
discovery depends on it), so internet play never worked: the join code's address
was always a LAN address. `MpReachability` adds UPnP — **on a WorkerThreadPool
task, because `UPNP.discover()` blocks ~2 s** — and the public address is folded
in ADDITIVELY as a second candidate. Join code v3 carries `addrs` while STILL
mirroring the LAN address into the top-level `ip`/`port`, so every pre-v3
consumer keeps working untouched; `decode()` accepts v2 and v3, pinned by a
frozen v2 literal in the selftest. The client tries candidates in order —
**LAN first only when its own /16 matches**, since a naive LAN-first costs every
internet player a pointless 6 s timeout. `_on_connection_failed` used to call
`leave_session` unconditionally; the ladder now intercepts before it, and there
is a wall-clock per-candidate timeout because a black-holed UDP port (the common
NAT case) may never fire `connection_failed` at all. We run no external server,
so a mapping is reported "created — not verified" until a peer actually connects
from a public address. CGNAT (`100.64/10`) is called out by name — port
forwarding cannot work there, so "check your router" would be wrong advice.

**Admission.** `rpc_hello` was only ever ADVISORY: once ENet connects, any peer
can drive `@rpc("any_peer")` handlers before saying hello, and
`rpc_lock_claim`/`rpc_lock_release` had no gate or rate limit at all. Async
Discord verification would have widened that window to seconds, so
`peer_admitted()` now gates **inside `note_peer_traffic`** (covering presence,
chat and every design transfer in one edit) with explicit checks added to the
handlers that bypass it. Two rules that must not be "simplified":
the not-admitted path **drops without kicking** (the rate-limit path kicks, and a
slow Discord round-trip must not punish a fast joiner), and `rpc_hello` passes
`require_admitted = false` since it legitimately precedes admission.
All the cheap synchronous checks still run first and unchanged, so a peer that
fails one never costs an API call; only then does `_begin_discord_admission`
hold the peer out of `peers` pending `DiscordGate`. **The gate's first call is
`GET /oauth2/@me` to prove the token was issued to OUR application** — without
it, a token the guest granted to any other Discord app would be accepted.
Discord unreachable fails **CLOSED** by default, deliberately the opposite of
`MpHardening.trusted_key_allowed`'s fail-open-on-empty (that is a
*configuration* statement; this is a *runtime failure* of a restriction the host
asked for) — do not let a refactor harmonise them. The host briefly holds a
guest's bearer token: it is never persisted, the cache keys on its SHA-256, and
`MpHardening.redact` strips it at the telemetry choke point. `DiscordBridge` is
the seam that removes the trade-off once someone runs a bot.

**The directory is ONE Discord message, edited in place forever.** Discord's
webhook message endpoints (`GET`/`PATCH` `/webhooks/{id}/{token}/messages/{msg}`)
need no authentication, so a single message is a readable AND writable
key-value store every member can reach with no bot and no server of ours. It is
created once and only ever edited, so its Discord link never changes — that pin
IS the permanent "join my map" link. `SimDirRecord` (pure) owns all the
concurrency; `discord_directory.gd` fetches and sequences.
**Host election:** read → if no live host (heartbeat older than `STALE_SEC` 150)
mint a claim, PATCH with `seq+1`, wait `CONFIRM_DELAY_SEC` **writing nothing**,
re-read. Discord serialises the two PATCHes and last-write-wins the stored
content, so if both racers re-read after the same fixed delay with no
intervening write, exactly one sees its own claim. **That no-intervening-write
discipline is what makes last-write-wins a valid arbiter** — which is why the
claim PATCH passes `no_retry` (`discord_http` would otherwise silently retry a
429 into the confirm window and mint a second host) and why a failed claim reads
as LOST, not as a retry. A `RECONFIRM_SEC` (+8 s) re-read before the winner
accepts its first peer makes the rare double-host self-healing. Reads whose
`seq` regressed are ignored (stale cache). `_host_block` reads LIVE session
state on every heartbeat, not the cached publish, so a refreshed join code or a
changed player count never goes stale in the channel. Writes DO overwrite a
hand-edited message: refusing would lock the community out of hosting until
someone tidied the channel, which is worse than losing one typed line — give the
directory its own channel. The directory is a CONVENIENCE, not a security
boundary; anyone with the community file can stomp it. `DiscordGate` is the
boundary.

**The community file** (`SimCommunity`, `SMBC1:` + base64(gzip(JSON)), also a
`.simcommunity` file) is the one blob an owner hands members: client id, guild,
role ids, voice channel, directory webhook + message id. `validate()` is a
SECURITY BOUNDARY — every id must be a snowflake (they are interpolated into
URLs) and **every webhook URL must be on discord.com**, or a pasted file
redirects the host's relayed chat to an attacker. Stored one file per community
under `user://communities/`, active one in `mp_prefs.cfg`; `active()` falls back
to "the only one on disk" so a member who imports a single file never also has
to pick it.

**Chat relay is OUTBOUND ONLY and host-only.** `rpc_chat_deliver` is
`call_local`, so `MpChatController._append` runs on the host for every message —
relaying from each client would post every line N times and would need to hand
every client the webhook credential. ⚠ A BROADCAST system line arrives with
`peer_id == 0` **and `system: false`** (rpc_chat_deliver hardcodes that field),
so the relay filters on `peer_id <= 0` too — without it the relay's own "chat is
being mirrored" notice gets copied into the channel. Every payload must carry
`allowed_mentions: {"parse": []}` or an in-game `@everyone` pings the server.
Off by default and it ANNOUNCES itself, to everyone present and to each later
joiner — mirroring people's chat into a semi-public channel silently is a trust
violation, so the notice is part of the feature. Inbound needs a bot
(`DiscordBridge`): a webhook can only read back messages it wrote itself.

**Host-authoritative simulation + NPC replication.**
`SystemGraphView._tick_resource_flow_ambient` had NO host/client guard: every
client ran its own `ResourceFlowEngine` and `NpcPopulationBridge` off its synced
graph copy, drifted, and got stomped by the host snapshot every 12 s — the
people on a joiner's screen were a local hallucination that snapped twice a
minute. `_mp_is_replica()` now short-circuits that tick **before** the
`_resource_flow == null` guard (the client path must not depend on an engine it
never steps). `MpPopulationController` streams the roster at 6 Hz: an id TABLE
on roster change (reliable), then INDEXED frames (unreliable_ordered) — by name
a 64-person camp would be ~7 kB/s of pure string, by index it is ~4 kB/s.
**The seam is one call:** `NpcPopulationHost._process` reads
`_bridge.agent_dots()` and nothing else, so handing it the controller's mirror
(which duck-types `agent_dots`/`active`) makes the whole avatar/LOD/pose path
work unchanged. Frames for an unknown table rev are dropped, not queued — the
reliable table and unreliable frames race by design.

**Possession ("play as one of the NPCs").** Call it **possess**, never
"embody" — `VIEW_MODE_EMBODY_TWINS := 157` already means "give a graph item a 3D
twin" and has a documented id-collision history. `NpcAgent.controlled_by_peer`
is TRANSIENT (absent from `snapshot()`; persisting it strands a frozen agent
with no controller after a reload). The engine skips a controlled agent in
`tick()`, `_separate()` (they push, they are never pushed), `_catch_up()` (which
would otherwise reroll their needs mid-possession) and `_process_departures()`
(they cannot rage-quit out from under a player — quit pressure still accrues, so
they leave the moment they are released). `_decay`, `_update_morale` and
`current_consumption` keep running: possession is not a way to opt out of the
resource economy. Bind by `agent_id` STRING, never by object reference —
`_ensure_engine` replaces every `NpcAgent` when authored `occupants` changes.
`_pose_possessed` bypasses the SMOOTH_RATE lerp (~125 ms of lag reads as broken
controls), `wants_anchor` (reads as input dropping out), and clock-derived
`paused`/`time_mult` (a possessed body would freeze when the host pauses); yaw
comes from the player's own look direction, not the direction of travel.
Possessed avatars are exempt from cull/far-pose/rig budget. Per the design
decision the clock is **warned about, never clamped** (`MpPossession
.time_scale_warning`, throttled by cooldown AND speed bracket since `rpc_clock`
lands at 2 Hz; note main.gd defaults `time_scale` to 0.01 ≈ 36×, so the
threshold is a tuned multiplier and not "> 1").

⚠ `PROTOCOL_VERSION` is now **3**, and `_poll_lan_packets` filters LAN beacons on
the same constant — old and new builds neither join nor SEE each other, and only
the new client can print a useful message about it.

## SoI stage — the graph's 3D lenses (Plan / Section / Globe)

One renderer, `system_graph/graph_soi_preview_service.gd` (a SubViewport sharing
the main World3D), draws every 3D lens of the G view: Site Plan (top-down),
Elevation (side-on section), the freeform SoI bubble, and the
**Globe** lens (`GraphSiteLayout.VIEW_GLOBE`, the "Globe" chip) — the snowglobe
inside the graph: a full-canvas perspective orbit, glass dome faded by pitch,
the shared rim sun (`SoiRimSun`, owned by SoiService and ref-counted by owner),
read-only PINS on placed items (`graph_canvas._draw_globe_lens`), drag orbits /
wheel zooms / click selects / double-click re-fits. The full-screen globe
(`SoiSnowglobeCamera`, map pin) stays; it renders through the ROOT viewport,
which the open graph runs with `disable_3d`, so `SoiService.enter_snowglobe`
closes the graph first and reopens it on exit, and opening the graph ends the
globe. Both globes share framing (`SoiOrbitMath`). Rules that carry it:

- **No view claims the clock.** Elevation's noon lock (time_scale 0 + snap to
  noon + write the old day_time back on exit) and the snowglobe's time_scale-0
  claim are gone; the timeline's "⏸ held · …" pill (`main.clock_hold_owner`,
  `ClockClaims.owner_of`) names any OTHER system that pins the clock.
  Readability at night is a per-camera lighting floor
  (`_sync_lens_env` / `_apply_night_floor`).
- **The preview follows the clock** (`_clock_refresh_due`): scrub → prompt
  captures (≤10 Hz, 6 heavy); playing → when the sun moved ≥0.35° or 0.25
  sim-h, or every 5 s (≤4 Hz, 2 heavy); paused → nothing; one capture in flight
  (`frame_post_draw` ack, `frames_rendered`). Lens environments are SHALLOW
  duplicates (the Sky resource is shared, so sky-shader params stay live)
  re-synced from the world on every capture — the old `duplicate(true)` froze
  sky, fog and ambient until G was reopened.
- **Elevation fills the panel (2026-10-11).** The section has NO disc mask:
  `_sync_layout`'s section branch takes the Globe's full-canvas path with the
  disc material kept (`use_mask` 0 — the poster sky still paints the air),
  `_want_crop` reports true for the section so a wheel notch never re-lays-
  out, `_current_mask_canvas` returns a covering circle so lens flights
  morph Plan's disc open into the window, and the canvas skips its hole fill
  / dot grid / disc reveal in Elevation. The 3D clip to the SoI sphere is
  unchanged — what the circle used to cover is air, so
  `graph_soi_preview_disc.gdshader` paints a ground band (`backdrop_ground*`)
  under the horizon line outside the cut. The frame maths and the cap are
  untouched (`site-review` elevation set: disc-vs-centre 0.00 px, cap PASS).
- **One Elevation frame** (`GraphElevFrame`): the disc mask, its label, the
  reveal fade, the preview container AND the section camera's look point (the
  world point under the container centre) all derive from it. The disc used to
  be pinned to the canvas centre while the camera followed the metre anchors,
  so the sphere slid out of its circle on any pan or cursor zoom. The separate
  Shift+wheel section zoom is gone (it was overwritten by the anchors anyway).
- **The cut is solid** (`SoiSectionCap`, driven by `set_section_cutaway`): a
  strip mesh on the cut plane, 3 cm behind it, from the ground profile down to
  the chord circle, painted with `soi_strata.gdshaderinc` (the bowl's own
  strata, now shared). ⚠ The section renders with a TRANSPARENT clear and the
  disc shader paints the air with a time-of-day poster sky
  (`_sync_section_backdrop`): an orthographic side-on camera sees the sky only
  along the horizon, and this project's horizon sky is lit by the volumetric
  fog the preview turns off — it rendered BLACK. The Hydro Lab embed uses the
  same disc material with `use_mask = 0`.
- **Every lens is a PERSPECTIVE camera (2026-10-13)**, like the Globe — the
  orthographic Plan and Section were where the "old ortho" artifacts came
  from (an ortho camera never reads as the world, and the ortho↔perspective
  switch was a seam in every flight). Plan (`PLAN_FOV_DEG` 35) and Section
  (`SECTION_FOV_DEG` 30) stand at the DISTANCE that makes px/m on the focus
  plane equal the 2D scale (`_matched_distance`: frame_h/2 ÷ tan(fov/2),
  `_frame_h_m` = canvas_h ÷ px_per_m, floored at `MIN_FRAME_H_M`), so at rest
  the 2D overlays on that plane stay registered; the plan's focus is the
  GROUND under the view centre (`_ground_y_or`). near/far follow the distance
  (`_set_near_far`). Shadows: a camera-less `LENS_SHADOW_CLAIM` while a lens
  is live. Off the focus plane (and whenever orbited) a 2D overlay must go
  through the camera: Site Plan's SoI ring, radial guides, working radius,
  array ghosts and watershed outline are DRAPED on the ground and projected
  (`graph_canvas._site_point_canvas` / `_draw_site_ring`, ground heights
  cached 2 s on a 0.5 m key); `GraphNpcSiteRenderer.project` (dots, spaces,
  streams, POI markers) projects at the ground too, not the SoI centre's
  height. Drag-pan on an orbited plan intersects both pointer rays with the
  focus plane (`_site_pan_by_pixels`). POI name tags live on render layer
  `PoiRuntime.LABEL_RENDER_LAYER` (1<<18), excluded from the lens camera's
  cull mask — they are screen-size see-through first-person furniture and
  printed as giant text over every lens. Hydro Lab fixes with it: the overlay
  floor is `GraphSiteLayout.LAB_MIN_ORTHO_H_M` (it was 1.0 m, so deep zoom
  unlinked overlay and camera), `_dia_px` no longer multiplies the zoom twice
  when linked, and the embed's layout key is written in the format it is read.
- **Lens changes fly** (`SoiStagePose`, `begin/end_lens_transition` bracketing
  `_sync_soi_preview_for_mode`): ~0.56 s between perspective poses (the
  dolly-zoom to a near-ortho pose below survives only for old callers), the
  mask circle morphing, the 2D
  overlay faded out mid-flight (`canvas.modulate`), no projection authority
  while flying. No flight on first entry, into the Lab embed, or same lens.
  ⚠ Camera3D refuses `fov < 1°`: set_fov errors and keeps its old value. The
  dolly therefore used to back off for 0.2° while still drawing at about 1°,
  and the frame shrank about 5× just before the ortho switch. The harness
  matrix's graph run caught it as 12 `set_fov` engine errors. `SoiStagePose.apply`
  now draws any pose under 1° as an equivalent `PROJECTION_FRUSTUM`
  (size = near-plane height), and `from_camera` reads one back.
- **Chrome.** The lenses are one segmented control in the top bar
  (`_make_mode_chip` + `_style_lens_segment`) with procedural icons
  (`GraphLensIcons` — drawn in code because the fallback font has no reliable
  ◐/◍ glyphs). Each physical lens shows a **lens strip** at the canvas's
  top-left (`_build_lens_strip` / `_update_lens_strip`, 5 Hz, text written only
  on change): lens name, live state (SoI radius, working radius, heading +
  slice, vertical exaggeration on the 2D-only section), the controls, and a
  clock chip (live N× / paused / time held). It REPLACED the hint strings the
  canvas drew on the disc's top edge (they sat on the Sunlight/Rain/Wind pills
  and scrolled away at depth) — don't put per-lens hints back on the canvas.
  Entering Elevation the cut plane SWEEPS into the globe from the rim while the
  camera flies (`_tween_sweep`, `_push_sweep_cutaway`; leaving, it slides back
  out), and the live section clips the 2D ground line to the disc. Lighting
  floors: the section keeps 75 % of its floor by day, the bubble/Globe 50 % —
  the player's world ambient can be 0.05, which printed shadowed slopes and
  roofs black. Vegetation is NOT lifted by this (its shaders take main.gd's own
  ambient, not the camera environment). The full-screen globe's dock is a
  centred card above the timeline.
- **The soil** (`core/soi/shaders/soi_strata.gdshaderinc`, `soi_soil()`, shared
  by the bowl and the cut cap) is a Pacific-Northwest forest profile: litter /
  humus → dark topsoil → iron-rich red-brown subsoil (mottled) → glacial till
  with cobbles, fading darker to the globe's bottom → columnar basalt, with
  roots, undulating horizon boundaries, and the terrain's own near-field ground
  maps (ground049a, `TerrainBuilder.apply_soil_textures`) as grain + relief.
  Horizon thicknesses scale with the SoI radius (`k = clamp(R/45, 1, 5)`) so a
  humus layer still reads on a 300 m globe; the key says "depths drawn ×k".
  The water table is a LEVEL surface at `centre − 0.70 R` (`soi_water_level`):
  the old band sat a fixed 15 m under the LOCAL surface and flooded every
  hillside cut. Percolation channels (`soi_channels`, one per ~120 m, each
  forking twice) carry animated water from under the humus to a seep at the
  table. Face coordinates: the cap uses metres along the cut, the bowl arc
  length round the vertical axis. Colours are authored sRGB and stored linear;
  `GraphSoilLegend.COLORS` / `BOUNDS_K` / `WATER_FRAC` MIRROR the shader — edit
  both. UI: the collapsible **Soil profile** key under the lens strip
  (Elevation, Globe) and the Elevation **soil probe** — hovering the cut names
  the horizon, its depth and the distance to the water table
  (`graph_canvas._draw_elev_soil_probe`, `GraphSoilLegend.horizon_at`).
- ⚠ **`SubViewportContainer` owns its child viewport's update mode.** On
  `NOTIFICATION_ENTER_TREE` / `VISIBILITY_CHANGED` the engine sets
  `UPDATE_ALWAYS` (visible in tree) or `UPDATE_DISABLED`, overriding whatever
  the script chose. `graph_soi_preview_service` re-asserts its own mode in
  `_on_container_visibility_changed`.
  - The handler is connected **CONNECT_DEFERRED**. The `visibility_changed`
    signal is emitted from CanvasItem's base-class half of the notification,
    before SubViewportContainer's half writes the mode, so a direct handler
    is overwritten.
  - `_request_viewport_refresh` refuses a viewport under `MIN_VIEWPORT_PX`.
  - What this fixed: a lens applied to the CLOSED graph activated the preview
    behind it. The viewport was then stretched from a 0-size canvas to 2×2,
    and on reveal it rendered every frame, about 200 "Too many mipmaps" /
    zero-dispatch errors (Hydro Lab → Bootcamp; also the saved lens at map
    load).
  - `close_hydro_lab()` is now a no-op unless the Lab is open. It used to fall
    back to switching a closed graph to Elevation.
  - Any other preview built on a `SubViewportContainer` that sets
    `render_target_update_mode` itself has the same trap.
- `_canvas_layout_key()` is the ONE layout signature (store and compare); a
  mismatch re-lays-out — and re-renders the shared world — every frame. (The
  Hydro Lab embed still has two different key formats; it was left alone
  because the Lab may depend on that continuous refresh.)

## The siphon turbine is a SIPHON (2026-10-11)

`core/conduits/siphon_turbine_physics.gd` (`SiphonTurbinePhysics`, pure,
pinned in `siphon_hydraulics_selftest._test_siphon_turbine_physics`) replaced
the culvert stage-discharge that used to stand in for the siphon kind. The
machine: a 6″ dip tube hangs from the turbine into the pond; the turbine sits
at the siphon's CREST on the bank; the draft pipe (the "culvert") runs from
the runner down the hill. Rules the model carries:
- **Head is pond surface − exit** (a closed conduit: the crest costs pressure,
  not head). Energy balance pond → exit: H = h_dip + h_draft + v_exit²/2g +
  h_turbine, Darcy–Weisbach + minor losses, closed by the runner law
  Q = 0.7·A_r·√(2g·h_t) (propeller flow coefficient; Dixon & Hall). An 8″
  runner on an 8″ free-discharge draft pipe throws ~half the head out as the
  exit jet — real, and why draft tubes diffuse.
- **Two atmospheric limits, both reported:** the crest (runner inlet) absolute
  head = H_atm − lift − h_dip − v²/2g must stay above `H_ABS_MIN_M` 2 m or the
  column lets go (`regime: lift_exceeded`, prime latched, no flow); the
  runner outlet = H_atm − (runner − tail) + h_draft must stay above
  H_vapour + σ·h_t (Thoma, σ 0.6). Past that: `cavitating`, h_t capped at
  (inlet_abs − H_v)/(1+σ), and `draft_excess_m` / `useful_draft_m` (bisection
  on the exit height to inception) say how much of the draft does nothing.
  `atm_head_m(site_elev)` is barometric.
- **Prime / break come from GEOMETRY now:** `dip_tube_length_m` (mouth =
  break level) and `siphon_prime_mode` ("overflow" = the pond reaches the
  crest, the turbine; "pump" = the mouth a half-bore under).
  `resolve_siphon_levels` honours them over stored offsets; legacy saves with
  only offsets are unchanged. `manning_n` is accepted and ignored.
- **Speed:** tip-speed ratio φ 1.6 on the runner bore (`runner_diameter_mm`,
  0 = the dip tube's), not the 5 kW rotor curve.
Three bugs fixed with it (each measured by `--capture=siphon`'s "siphon
verify" lines): `bind_siphon_to_nearest_pond` no longer moves a prop-bound
turbine's site to the pond centroid (a siteless one is seated on the SHORE),
and seeds the dip tube from the pond depth; `ensure_siphon_outlet_sink` traces
with a VETO on the pond's basin (`Watershed.trace_downhill(..., veto)`) and
LOCKS the traced route (unlocked, `route_3d` was never read and the culvert
drew a chord), with `retrace_siphon_outlet(id, drop)` for "further downhill";
`_auto_penstock_for_new_water_wires` skips `direct_intake` wires and
non-penstock kinds — it used to turn the bind's own pond→siphon wire into a
poly penstock anchored at the tank centroid, the "immovable intake node".
The dip tube is drawn in the world by `gameplay/siphon_dip_tube.gd` (on the
prop, off the inlet port via `ConduitManager.resolve_port_binding`). Lab:
Siphon section (dip length, priming, runner Ø, draft length; prime/break
read-only), crest / dip-mouth / draft-exit drag handles on the cut, a
suction gauge with the limit tick, Pond level + Suction deck tiles, siphon
insights and a siphon sensitivity line ("exit 0.5 m lower → +N W"); the
exit spin writes through to the outlet node + culvert end.
**Lab open HEALS a saved siphon** (`prepare_siphon_lab_session`): a legacy
item gets `dip_tube_length_m` from its break level (the break does not move)
and `siphon_prime_mode` "pump" when its prime sat below the module; an
intake wire converted to a poly penstock goes back to a direct intake
(`heal_siphon_intake_wires`); an auto outlet inside the pond's basin is
re-traced (`_siphon_outlet_in_pond`); and the THREE exit heights a save can
carry (specs `outlet_invert_m`, culvert `invert_out_m`, the outlet node's
`elevation_m`) are reconciled to the node (`sync_siphon_outlet_invert_from_
sink`) — Mt Vernon's siphon carried −89.4 / −81.6 / −82.7 and read 9.3 m of
head on a 1.5 m drop. ⚠ The cavitation cap is on the TOTAL head across the
runner (pressure + the dip→draft velocity-head change) at the RUNNER's
datum; the first cut used the crest datum and the static pressure only,
which stepped the power 29 % at inception on a 6″ dip / 8″ draft (pinned).
**Round 2 (same day):** the Lab's draft-exit handle sits where the OUTLET
NODE really is on the cut and drags on BOTH axes — x walks it along the
slice (down the hill), y sets the height, never above the ground there
(`_drag_exit` → `SystemGraphView.move_siphon_outlet(id, site, elev)`: the
node, the culvert's far end and `outlet_invert_m` move together; the traced
route is dropped, the engine re-measures the draft length). The test-fill
slider reaches 200 L/s on a siphon (a 20 L/s fill could never out-draw a
siphon pulling 70; the "Pond: inflow − draw = net" line says so) and "Fill
pond to the prime level" primes it in one click. The close-up has a SIPHON
MODE (`hydro_turbine_closeup.gd` `_process_siphon`): the propeller from the
reach's rpm, the pond's waterline relative to the turbine, the water column
in the riser/leg, the dip and draft tubes, beads riding the path at the draft
velocity, a siphon HUD; the camera looks ACROSS the shaft and frames the
dip tube. The GLB's propeller is "Node15" (`turbine_node`), normal +Z —
unnamed, the size heuristic spun a motor BOLT in the world.
⚠ **A pond cannot rise above its rim, and a crest above the rim can never
overflow-prime.** Mt Vernon's siphon stands 1 m above its pond's rim with the
pond 2 cm under the rim — "test inflow does nothing" was the pond spilling,
and a 1 m dip tube's mouth sat AT the surface. "Fill pond to the prime
level" (`_on_fill_to_prime`) therefore switches to pump priming when the
crest is above the rim AND extends the dip tube so its mouth is half a metre
under the rim, toasting both; the net readout says "Pond: FULL" and the
insight names the crest/rim conflict. The harness reads the Lab's `_last_r`
for "primed" — the engine stamps `siphon_primed` only on a clock tick and
the harness holds the clock.
`--capture=siphon` prefers a SIPHON-kind turbine on the map (Mt Vernon also
has a PowerSpout), strips its own stale `cap_lab_*` seeds, and on a map
with a pond but no siphon seeds a TEMPORARY one on that pond (no site, so
the bind seats it on the shore; removed before quitting); the "siphon
verify" lines cover binding, outlet, physics, Lab controls and the 3D dip
tube. ⚠ The soak scene occasionally exits natively at scene load (log ends
after boot, exit 0, no harness line): rerun, it is not the Lab.

## Siphon round 3 (2026-10-12): world pins, the plan window, the outlet end, max fill

Six player complaints after round 2, each with the trap it closed:
- **World pins — the Globe's 3D placement is the source of truth.** The
  Globe lens's read-only pins became ONE pin layer (`graph_canvas.gd`
  `_draw_world_pins` / `_handle_pin_input`) that Site Plan and Elevation now
  take whenever the live camera is the projection authority
  (`phys_pins_mode`, View options → "World pins", default on; off = the
  legacy chip / port / schematic-wire overlay, whose hit-tests return
  nothing in pin mode so nothing invisible is clickable). Pins DRAG: a press
  on a pin is a pin drag (never an orbit), empty canvas still orbits / pans /
  zooms, click selects, double-click opens the inspector. Globe + Site Plan
  drags MARCH the pointer's ray against `ground_y_at` (`_pin_ground_hit`: a
  physics ray's first hit was tens of metres off in plan on a slanted Globe
  ray — the coarse collision is sunk under the hi-res patch and the
  snowglobe's shells have bodies); Elevation walks the pin along the slice
  and takes the height from the section-plane hit. Release emits
  `world_pin_moved` → `SystemGraphView._on_world_pin_moved`: an OUTLET SINK
  routes through `move_siphon_outlet` (culvert end + invert follow, ground
  − 0.3 on a ground drop), a bound prop through the usual Site Plan heal
  (`_on_canvas_layout_changed` now also runs for the Globe). Locked pins
  (pond tanks, stream intakes, scene-embodied devices) say what to move
  instead. ⚠ The Globe's `_draw` returned before the per-draw caches were
  cleared, so a dragged pin kept projecting its OLD anchor — the pin pass
  clears `_conn_anchor_cache` itself. ⚠ `_refresh_item_elevations` keeps an
  outlet sink's hand-set invert when it is at or under the ground (it used
  to flatten every Lab / Elevation exit drag back onto the surface on the
  next lens entry).
- **Site Plan fills the panel** (`_sync_layout` top-down branch, `use_mask`
  0, the air painted the canvas colour by `_sync_plan_backdrop`; `_want_crop`
  true for the plan; the canvas skips its hole fill / dot grid / disc
  reveal). The crop / no-crop hysteresis that re-laid-out the viewport at the
  threshold was the "zoom jumps". **Cursor zoom on an orbited plan**: the
  flat 2D rule assumes a straight-down camera; `_zoom_at` now remembers the
  GROUND point under the wheel and `_hold_world_under_cursor` solves the pan
  exactly (two probe steps, a 2×2 Jacobian — a plain `pan += error` spirals
  on a yawed camera). site-review's site set pins container == canvas and
  0 px drift over 40 notches; its globe + site sets drive a synthetic pin
  drag (an outlet sink lands under the pointer, ground − 0.3, culvert
  follows).
- **The draft outlet's END is grabbable in 3D** (`gameplay/outlet_end_marker.gd`,
  one per propless outlet sink, owned by `ConduitManager._update_outlet_marker`,
  parented to Main so it shows while the x-ray pipe is hidden). GrabController's
  relocatable-marker contract: Ctrl/Alt + aim focuses it (the crosshair's
  conduit rung and the route controller's drag pick both hand a pick within
  `OUTLET_END_PICK_M` 1 m of the mouth to the marker — a drag there used to
  INSERT A WAYPOINT), LMB + drag carries it on the terrain, release commits
  through `move_siphon_outlet`; `grab_distance_m()` lets a marker set its own
  reach (the stock 60 m never reached down the hill). `--capture=hydroload`
  drives a REAL Ctrl+drag (focus = the marker, the grab picks it up, the
  outlet moves, the culvert follows, 0 waypoints added).
- **Pond MAX FILL LEVEL** (`TerrainLoader._pond_max_levels`, tag → world Y,
  persisted in the user_water file; MAP ponds take it too — Mt Vernon's pond
  is OSM water with no user record). `_recompute_pond_volume_rec` sets
  `spill_m = max(basin rim, max level)`, so Auto capacity integrates the
  footprint up to the dam (a vertical wall until a flood-fill outline
  lands), the graph tank's `rim_m` follows and the Lab can fill past the old
  rim. Set it three ways: Ctrl/Alt-aim the pond SURFACE and drag up / down
  (`gameplay/pond_level_handle.gd`: a ring at the max height over the
  centroid, a pick slab from the water surface to the max, the drag = the
  crosshair ray's closest point to the vertical line through it, a live
  "+0.40 m above the basin rim · capacity +N kL" readout), the Pond settings
  "Max fill level" row (with "Rim" to reset), or the Lab's "Fill pond to the
  prime level", which now DAMS the pond when the crest is within 1 m above
  the rim instead of switching to pump priming
  (`raise_pond_max_level_for_siphon`). Map ponds also take level / stock
  writes now (`_map_pond_rec_at_water_idx`) so the graph's level push moves
  their water plane. `--capture=siphon` on mtvernon pins rim / capacity /
  fill-past-rim / the handle's commit.
- **Flowing / generating feedback** (`gameplay/siphon_state_ring.gd`, on
  every hydro prop beside the spin): an emissive ring round the machine's
  foot — green generating, amber primed with no power, red broken / lift
  exceeded / cavitating, grey dry — a status label over it ("PRIMED · 70 L/s
  · 144 W", "NOT PRIMED — pond below the crest", shrinking with distance,
  gone past 60 m), air bubbles rising from the dip tube's mouth when the
  siphon has BROKEN. `SiphonStateRing.state_for(specs)` is pure (pinned in
  the siphon verify); the world pins' heads take the same colour.
- **The dip tube** is hidden by default (`show_dip_tube`, prop editor Model
  section + the Lab's Siphon section) and, shown, is ONE vertical cylinder
  whose TOP is the open end of the 6″ 90° PVC ELBOW on the intake side
  (`SiphonGeometry.elbow_outlet` / `dip_anchor_for_model_root`, shared with
  the close-up; on the shipped GLB the elbow is `Geom3D_22` at the far end
  of the leg, turned down) and whose MOUTH is the physics break level
  (turbine datum − `dip_tube_length_m`), so the length only moves the
  bottom (2026-10-18; the first cut hung it off the leg's end under the
  riser, 0.7 m from the elbow, and before that off the connection port).
- **Buried pipes read as buried** (`core/conduits/conduit_buried.gdshader`,
  `ConduitManager._apply_burial_cue`): a physical run under the ground
  anywhere gets per-vertex burial in UV2.x, fades / desaturates / dashes
  with depth (floor alpha 0.38 — the player must still find it) and a
  dotted ground TRACE draped on the surface above the buried spans with a
  normal depth test. Light strings and conceptual flow runs opt out. Kit
  runs (the culvert kit, ABS parts) get the profile + trace but not the
  material fade. ⚠ The trace is ONE surface (`_dotted_trace_mesh`):
  `ConduitMeshBuilder._build_dashed_tube_mesh` adds a surface PER DASH, and
  a long buried run on the soak map blew past Godot's 256-surface cap every
  frame (1066 add_surface errors, then a native exit mid-capture).
  `--capture=hydroload` dumps max burial per run and asserts the trace.
- ⚠ **Site Plan's wire-mode session only runs while the graph is OPEN.** The
  saved lens is applied at map load with the graph hidden, before
  SimSettingsController has read its file, and `_apply_site_wire_mode_session`
  captured the DEFAULT (false) as "the player's pref" and restored it over
  the real one when the graph closed — every x-ray run vanished from first
  person after one Site Plan visit on a save whose lens was Site.
Verify: `siphon_hydraulics_selftest` (SiphonGeometry), site-review
`--review-sets=site,globe` on mtvernon (pins / drag / window / zoom lines),
`--capture=hydroload` (marker drag, burial, wires pref), `--capture=siphon`
on mtvernon (dip tube, state ring, max fill).

## The site as one system (2026-10-12 Mt Vernon playtest)

The user's real site (pond, Stream 2, a micro Pelton on a penstock, a siphon
turbine, a 48 V bank) showed turbine labels making power while the battery
sat at its 10 % floor, and a pond that never moved. Measured with a sandboxed
probe; each fix guards a trap that rendered plausibly:
- **Hydro → battery had TWO stacked breaks.** `DcPowerWiring.find_battery_
  for_dc_port` only passed a controller entered on its PV terminals; a
  turbine on the controller's BATTERY terminal (where the bank also lands —
  the right real-world wiring for a PowerSpout's own regulator) dead-ended.
  It now follows every wire on that terminal. And `_sync_graph_dc_generation_
  to_solar` ran only inside the VISIBLE energy sync, so with the graph closed
  (or the Lab up) SolarUI's `current_graph_dc_kw` never moved; it is on the
  ambient path now (`_dc_gen_sync_acc`, before the visibility gate).
- **No water ⇒ no watts.** The pond-drawdown path took power from the
  unclamped reach while the clamped drain moved 0 L; watts now scale by
  drained ÷ evaluated flow (paused: only if the source can sustain 1 s).
- **A routed penstock decides what feeds a penstock turbine**
  (`_resolve_siphon_inlet_tank`), and `_pond_level_of` never treats a stream
  intake as a reservoir — an empty 100 L tank carrying a COPIED pond level
  out-voted the penstock. The copies came from `sync_pond_level_from_mesh`,
  which wrote level/rim/floor onto any resource sharing the pond's tag; it is
  restricted to pond tanks + catchments now.
- **Stream diversion**: a penstock turbine whose tailwater is delivered to a
  wired outlet debits that stream's discharge into its end pond
  (`_stream_diversions` → `stream_pond_inflows(rain, diversions)`); with no
  outlet the tailrace returns to the stream (`live_tailrace` says which).
- **One pond level.** `TerrainLoader.pond_stage_curve(tag)` integrates the
  basin ([[stock_l, level_m] × 24], same ground + cell size as
  `set_pond_stock_l`), stamped on the tank as `stage_curve` by the mesh
  writeback; `_apply_tank_sample` reads `level_m` off it, and HydroReach uses
  it for level ↔ stock and the dead pool (`set_stage_curve`, cleared by every
  `set_pond`). Linear floor→rim put the graph 0.55 m off the 3D water and the
  siphon's dead pool 0.67 m above its dip mouth. Helpers are pure in
  `PondBathymetry` (`stage_level_for_stock` / `stage_stock_for_level` /
  `stage_area_at_level`).
- **A pond's own budget** (`_pond_budget_pass`, after every source credits):
  rain on the open water (area = dV/dh off the curve) is intrinsic — no
  surface catchment needed (a wired one still does it instead); ponds take
  whole streams and catchments uncapped, and whatever would lift them past
  the fill ceiling SPILLS to `specs.spill_outlet_id` (booked either way).
  `budget_rain_lph` / `budget_stream_lph` / `budget_spill_lph` are stamped
  on the tank. A designated hillside `watershed` catchment subtracts the
  area already drained by streams ending in the same pond
  (`stream_pond_catchment_m2`, `stream_covered_m2`) — it double-counted.
- **3D water moves continuously**: WaterBuilder builds every level-driven
  pond (has `level_m` + `tag`) as its OWN `PondSurface` mesh (meta
  `pond_tag`, `built_level_m`); `set_pond_surface_level_by_tag` translates it
  on every pond push. The 0.10 m-throttled full rebuild remains.
- **3D ↔ freeform**: preview-mode thumbnails of hydro turbines carry a
  caption from `SiphonStateRing.state_for` (the 3D ring's own function) and a
  state-coloured border; `reconcile_world_bindings()` runs first in
  `resolve_site_elevations_after_load` (bound site xy snapped to the prop —
  3D is the truth; one-way bindings repaired; a bind to a deleted stream
  re-binds to the resolved one; intake names follow their stream); inspector
  "Locate in 3D" (settlement camera, player not moved) and prop editor
  "Open node in graph"; `GraphSimLoadHost.is_load_item` skips siphon_hydro
  generators (the consumer proxy stamped "off" on running turbines).
- **SITE BALANCE card** (graph dashboard, `system_graph/site_balance.gd`,
  pure): each generator by name, make vs use, battery time to the floor or
  to full, hydro not reaching the bank, each pond's streams / rain / draw /
  spill and time to full, and a FORWARD PROJECTION (`SiteProjection`, pure:
  next 24 h and 7 d with real weather through `SolarUI.evaluate_solar_at`,
  the AC loads' demand from `GraphAcLoad.demand_watts`, SolarUI's own
  floor/resume hysteresis; soc min/end, kWh made/used/unserved, hours with
  AC off, first outage) — its own pure loop, NOT the challenge bake engine,
  which owns the clock and its playback. Cached 20 s / 0.25 sim-h.
- The Lab close-up's electrical load is the slider (100 % = matched, what a
  battery regulator / dump load holds). It used to read output ÷ nameplate
  whenever DC was wired, which put a battery-tied turbine near runaway.
- `GraphSoiPreview`'s SubViewport is born UPDATE_DISABLED: born
  WHEN_VISIBLE, every graph reopen rendered the 2×2 placeholder (200
  renderer errors per reopen on Mt Vernon).
- The Mt Vernon world was cleaned by `tools/fixes/mtvernon_hydro_cleanup.gd`
  (persisted with backup): two empty supply tanks, an orphan intake + prop,
  a pond self-loop wire, and a spillway outlet at the user's "Pond Outlet
  Pipes" pin. The "Custom Load" is the user's placeholder (2500 W
  `avg_watts` as of 2026-10-15).
- **Double-click a turbine to switch it off / on** (2026-10-15;
  `SystemGraphView.set_hydro_turbine_off`, inspector "Running" box,
  `specs.hydro_off` = `HydroSource.SPEC_OFF`). Off = valve shut: the engine
  skips it at the top of `_process_siphon_hydro` (`_idle_switched_off_turbine`
  zeroes telemetry AND every port rate — a stale rate keeps water moving),
  and the Lab-pause fill and scrub-back refresh skip it too. The card chip
  reads OFF, `SiphonStateRing.state_for` returns state "off". The Hydro Lab
  moved to the inspector's "Open Hydro Lab…" (double-click used to open it).
Verify: `resource_flow_selftest` (battery-terminal trace, stray-tank inlet,
no phantom watts, stage curve, surface rain, spill, SiteBalance),
`hydro_reach_selftest` (curved-basin dead pool), `--capture=sitebalance`.

**The real power system + placed solar racks (2026-10-12/13).**
- Presets from data sheets (`ComponentPresets`): **EG4 6000XP** (480 V max
  Voc, 2 MPPTs 120–385 V, 100 V start-up, 17 A per MPPT, 8 kW PV, 6 kW AC,
  125 A charge), **EG4 48V 20.8 kWh Bank** (51.2 V × 406.25 Ah — no single
  EG4 SKU is 20.8 kWh; it is the user's bank), **JA Solar 380W** (Voc 41.62,
  Vmp 34.77, Voc −0.272 %/°C, Pmax −0.35 %/°C). Mt Vernon runs them via
  `tools/fixes/mtvernon_solar_eg4.gd` + `mtvernon_pv_coeffs.gd` (persisted).
- The controller's limits reach SolarUI: `_controller_power_limits()` →
  `pv_limit_kw` (max_pv_watts) and `ac_overload_w` (overload_watts) in
  `_sync_solar_ui_from_graph`; the array aggregate also carries a watt-
  weighted plane of array (`orientation`: tilt + azimuth) which becomes
  SolarUI's `panel_tilt_degrees` / `panel_azimuth_degrees`. Only arrays that
  HAVE an azimuth steer it (a real plane: a placed rack, a deployed linkage).
- **`pv_array` prop** (`PvArrayBuilder`, Library "Solar Array (ground
  mount)", PackedSpec dynamic): a ground-mount rack drawn by
  `SolarArrayBuilder` + a hidden CollisionMesh. Placing one calls
  `bind_pv_array_prop` (binds the record's `graph_item_id` array, else makes
  a `pv_<prop_id>` array wired to the first controller) — so placing the
  array that is already on the graph never makes a second one. Graph → 3D:
  inspector "Place array in 3D" (`place_array_in_world`). The rack's YAW is
  the array's azimuth (`orientation_for`: azimuth = 180 − yaw,
  `yaw_for_azimuth` the inverse); `update_prop_record` notifies the graph on
  x/z/yaw/y_offset/pv_array_spec and `sync_site_from_prop` re-orients. Prop
  editor "Solar array" section: tilt + "Face the equator". The panel COUNT
  is the graph array's (the electrical string); the rack only draws it.
- **String design check** (`PvElectrical.string_window_report`, inspector
  "PV string check" on a controller): cold-morning Voc (−10 °C) vs max_voc,
  STC Voc vs `startup_v`, hot-noon Vmp (NOCT cell, 40 °C air → 71 °C) vs
  `mppt_min_v`, STC Vmp vs `mppt_max_v`. Coefficients are PER PANEL
  (`voc_temp_coeff_pct`, `pmax_temp_coeff_pct` / `vmp_temp_coeff_pct` on the
  panel or array specs; `add_imported_solar_panels` takes them in `opts`),
  also in the live over-voltage check (`component_string_voc`); without them
  the generic 0.3 %/°C (Voc) and 0.40 %/°C (Vmp = Pmax + Imp's +0.05) apply.
  Mt Vernon's 9S: 410 V cold (70 V headroom), 255 V hot Vmp — inside.
Verify: `graph_electrical_selftest` (`_test_string_window`: 9S ok, 13S over
the limit, 3S under the floor, hand numbers), `resource_flow_selftest`
(`_test_pv_array_and_projection`).

## Stream-fed PowerSpout (the tapped-source hydro loop)

The play loop: place a PowerSpout, drop a **stream intake** uphill, draw a
penstock between them, dial a test L/s in the Hydro Lab, watch real power.

**A source is a FLOW, not a reservoir.** `create_penstock_intake_at` mints a
`resource` item with `stream_source: true`, `unlimited_capacity: true` and NO
`level_m`/`floor_m`/`rim_m` — there is no surface to draw down. Its **ground
elevation is the gross head** (the routed contour penstock's invert drop, adopted
by `_adopt_penstock_conn`), and how much water it runs comes from
`core/conduits/hydro_supply.gd` (`HydroSupply`, pure static):
`Q = base_flow_lps + rain_lps_per_tenth_in_h × (rain_mmh / 2.54)`, capped by
`max_flow_lps`, optionally lagged by `recession_tau_h` (default 0). **0.1 in =
2.54 mm exactly** — that conversion is the single likeliest thing to be silently
wrong, so it is pinned. Authored in the freeform inspector
(`_build_stream_intake_section`); `recess()` uses `1 − exp(−dt/τ)`, exact for a
step at ANY dt, because the world clock hands it multi-hour ticks at speed.

**Supply and design flow are DIFFERENT ZEROES, and merging them is the bug that
keeps coming back.** `HydroSource.available_supply_lps` discriminates on
`specs.has("supply_lps")`, never on `> 0`: an engine-written `supply_lps` of 0.0
means a spring that has stopped running, while `design_flow_lps` of 0 means a
nozzle kind is UNLIMITED. Downstream, `PeltonPhysics.operating_point_supply_limited`
carries the same contract — **NAN = unconstrained, 0.0 = dry**.

**Supply-limited physics is honest, not a clamp.** When the spring runs less than
the nozzle would pass, `Q = supply` AND the nozzle only converts the head its own
flow demands (`nozzle_head_required_m`), so the penstock runs partly full and the
surplus head is never turned into jet velocity. That is why a big jet on a small
spring makes far less power than the gross head suggests; the Lab warns and names
the matching nozzle via `nozzle_d_for_supply_m`. Verified end to end by
`--capture=penstock`: 0.25 L/s → 0.7 W, 4.0 L/s → 505 W on the same 46 m head.

**Water really moves.** `_process_spec_driven_hydro` takes `net_rates` and
`dt_hours` and classifies on the kind's `pond_drawdown`: run-of-river STREAMS THE
RIVER THROUGH (rate stays 0 — the river is not a resource the graph owns, and
crediting a sink from it would conjure water out of the landscape), while a tapped
penstock stamps real port rates, credits the outlet sink through the shared
`_credit_outlet_sink`, glows the penstock via `_cache_conn_flow`, and debits the
source ONLY when it is not `unlimited_capacity`. Before this the branch forced the
water output to 0 and took no `net_rates` at all — the reported "I can't get water
to flow through the turbine".

**Opening the Lab must not rebind a stream-fed turbine.** `prepare_siphon_lab_session`
auto-binds the nearest pond when `resolve_siphon_pond` comes back empty — and a
stream intake is not a pond, so that fired every single time and
`bind_siphon_to_nearest_pond` REPLACED the water-in wiring, deleting the penstock
the player had just routed and latching the turbine onto a pond elsewhere on the
map. Guarded by `_turbine_has_stream_source`; the explicit "Rebind to nearest
pond" button is deliberately NOT gated (that one is the player asking). Pinned by
`--capture=penstock`'s "opening the Lab did NOT delete the penstock wiring".

**The annual estimate needs the SEASONAL supply.** `available_supply_lps` returns
one instantaneous number, so `annual_energy_kwh_from_specs` reused it for all
twelve months — the annual figure read whatever the spring happened to be doing
when the panel opened, blind to the rainfall that is the whole point of the rain
coefficient. The engine now stamps `supply_monthly_lps` (12 × L/s, from
`HydroSupply.monthly_supply_lps` against `WeatherService.monthly_precip_mm`,
change-gated on the intake's authored params) and the annual closed form takes it
as an optional argument. Separate key from `supply_lps` ON PURPOSE: the live tick
must use real-time rain, never a monthly mean.

**The stat deck (2026-10-11, `scenes/ui/hydro_stat_deck.gd`).** The Lab's
headline readout is a row of big tiles under the section in CAUSAL order —
Flow → Net head → Pressure → Jet → Speed → Power (siphon kinds: Pond level
instead of Pressure/Jet) — each with a bar against what LIMITS it (source
flow, gross head, the pipe's SDR rating from the design checks, the jet's
full-head demand, runaway, nameplate), the relation under the number, a
hover tip in words, and a flash when a value moves. Under it an INSIGHT line
names the binding constraint (dry / no head / source-limited with the
matching nozzle / pipe-limited / under the head band / generator-capped /
nozzle- or flow-governed) and a SENSITIVITY line ("+1 m head → +12 W · +1 mm
jet → …", five closed-form evaluations inside the estimate's signature gate,
never per tick). `_refresh_stat_deck` reads `_last_r` in the SAME refresh as
the dock rows and the strip, so the three cannot disagree; the dock's Live
readouts went to 14 px and the power chart marks the routed pipe's curve.
A tile is four rows that never share a line (2026-10-14): LABEL left with
the bar's verdict right, the value + unit (Inter tabular figures), the
relation at full width, the bar. The verdict used to sit right-aligned on
the relation line and overprinted it. Captions lead with their number
("40.9 m gross − 1.7 m friction") and every fit goes through `UiText.fit`,
so a caption that stops fitting shows up as `canvas_truncated` in the tour
audit. Roughness is shown in µm in the Lab (the spec stays in mm).
**The close-up's load slider is a what-if, and it costs watts.** The graph node
reports the MATCHED-load output (what a dump-load or MPPT controller holds).
`runner_efficiency(x, 1.0)` is the fraction of that delivered at the current speed
ratio — 1.0 at x_opt by construction — so the HUD scales the graph's power through
it. Without that the HUD read "η 0%" at runaway while the status strip a few
pixels below reported full watts.

**The Lab's test flow is the SUPPLY, not a pond fill.** For penstock kinds
`lab_sim_inflow_lps` overrides base flow + rain at the intake (flagged there as
`supply_override`, cleared by `teardown_siphon_lab_session`), and
`_apply_lab_sim_inflow_realtime` gained a stream branch BEFORE its pond lookup so
the knob moves the power instantly while the Lab holds the clock frozen.

**Per-view cameras.** `graph_canvas._view_cam` holds `{zoom, pan, along_m, elev_m}`
per view; `set_view_mode` captures the outgoing view and restores the incoming one
— capture happens at the SWITCH, not at each of the ten `_zoom` write sites, so a
new writer cannot break it. `VIEW_SIPHON` is a real mode (the canvas draws only its
background under the Lab) instead of being faked by parking in `VIEW_FREEFORM`,
which is what handed the Lab the freeform camera to overwrite;
`frame_elevation_for_siphon(id, set_camera)` lets the Lab take the heading/slice
without the framing. Pinned by `--capture=siphon`'s decoupling assertion.

**Elevation registers with 3D.** `_refresh_item_elevations` resolves a prop-bound
item's elevation from `ConduitManager.anchor_global_for_item` — the SAME resolver
the 3D conduit terminates its pipes at — before falling back to terrain ground Y,
and skips siphon modules whose elevation the flow engine and the Lab own.
`_phys_item_world_center` does the same for the whole anchor (XZ too), memoized
per draw. `_elev_exaggeration_draw()` returns 1.0 whenever a CAMERA is the
projection authority, not just under `soi_live_preview`: the overlay sits ON the
3D image, so a 5× stretch could never line up. `GraphSiteLayout.LAB_MIN_ORTHO_H_M`
(0.05 m) is clamped by BOTH the Lab's `_lab_view_metrics` and the section camera,
so deep zoom can no longer unlink them.

**Conduits are X-RAY by design, so they are HIDDEN in first person.**
`ConduitKinds.make_material` sets `no_depth_test` and `conduit_flow.gdshader`
declares `depth_test_disabled` so buried runs read through the Elevation / Site
CT soil bowl — which is exactly what made them confusing in the world: an
auto-revealed culvert tailrace or routed penstock (both stamped `visible_3d:
true` by `ensure_siphon_outlet_sink` / `create_penstock_intake_at`, which the
player never asked for) draws straight through the terrain. They cannot simply
stop being built — the REBUILD is what stamps `route_length_m` and the endpoint
inverts the flow engine adopts — so `ConduitManager._refresh_world_visibility`
gates the NODE instead: `visible = _global_visible or _preview_visible`. The
preview flag is pushed by SystemGraphView off the SoI service's
`preview_active_changed` (one signal covers mode switches AND the graph-close
teardown), and since the preview shares this World3D (`own_world_3d = false`),
that same node visibility is what keeps Site Plan / Elevation CT / the Hydro Lab
section drawing the pipes they exist to show. "Show 3D wires (world)" ON =
visible everywhere, unchanged. Two consequences to preserve: the first-person
plug/route GHOST is parented to `ConduitRouteController` itself with
`top_level = true` (its verts are world-space) so the drag feedback survives the
hide — everything left under the manager is a run visual and hides with it; and
Site Plan's `prefer_3d` wire mode, which BORROWS the global pref, must hand it
back on graph close (`_restore_site_conduit_visibility` in the visibility-changed
branch and `_exit_tree`) — it used to restore only when switching to a
non-physical view, so one visit to Site Plan left every x-ray run hanging over
the landscape for the rest of the session. All four states are pinned by
`--capture=hydroload`.

**Item elevations must be resolved AT MAP LOAD, not only on graph-view entry.**
`_refresh_item_elevations` used to run solely from `_apply_graph_view_mode` for
Site / Elevation / Siphon, so a map booted into first person ran every conduit off
whatever the save carried. An UNBOUND item — a culvert outlet sink has no prop —
saved at elevation 0 anchored at world Y ≈ 0 while its machine sat 80 m below, and
the culvert fired ~265 ft into the sky at an angle until the player pressed G.
`TerrainLoader` now calls `SystemGraphView.resolve_site_elevations_after_load`
(backfill + refresh + `ConduitManager.sync_all`) right before `map_load_complete`;
the `sync_all` also rebuilds any conduit that failed to build at boot. Pinned by
`--capture=hydroload`, which asserts BEFORE the graph is ever opened that no
culvert outlet sits above its inlet and no endpoint pair is stranded 120 m apart.

**Three Lab traps that all render plausibly while being wrong.** (a) The overlay
draws in POND-RELATIVE along — `_ensure_dem_bake` subtracts `pond_along` — so
anything built from an ABSOLUTE `project_onto_section` coordinate must too
(`_pond_along_m`). The routed penstock and the drag ghost did not, and on sloping
ground a sideways shift reads as the pipe FLOATING metres above the terrain while
3D looks right. (b) Port positions are flat `x`/`y`/`z` scalars, NOT a `pos`
Vector3 — `get("pos", Vector3.ZERO)` silently measures the model ORIGIN and
returns a plausible 0.000 m offset. (c) `design_flow_lps == 0` means UNLIMITED for
a nozzle kind, so the Lab's `maxf(design, 0.01)` floor pinned the whole power
curve to a 0.01 L/s supply and drew it at ~0 W; only design-flow kinds get the
floor.

**The power chart separates HARDWARE from SITE.** The per-size curves exclude
`supply_lps` (a live supply is a property of the site, not the pipe — leaving it
in made all four sizes return the identical number and four curves drew on top of
each other, silently answering "a fatter pipe buys you nothing"). The supply gets
its own labelled curve, and the per-size STATS stay supply-aware and say outright
when the source, not the pipe, is the limit.

**The runner's DISPLAYED speed is compressed** (`_display_omega`). 24 buckets at
533 rpm is 213 bucket-passes/s against 60 fps — far above Nyquist, so the wheel
aliased into a crawl while only the arms read ("spins so fast it looks slow"). No
frame rate fixes that. The display saturates toward `DISPLAY_RPM_MAX` 55 (~22
passes/s) on a monotonic curve, so faster still looks faster; the HUD reports the
TRUE rpm, and only the animation is slowed.

**The splash is the OTHER half of the Euler relation, not a fudge.**
`PeltonPhysics.bucket_exit_speed_ms(v_jet, x)` = `v_jet·|1 − 2x|` (ideal 180°
bucket reverses the relative velocity). At the matched load that is only
0.08·v_jet, because nearly all the jet's momentum went into the shaft — which is
why a well-tuned Pelton visibly DRIBBLES while a runaway flings water everywhere.
Driving the close-up's splash from it makes the load slider legible at a glance
and replaced an arbitrary fraction-of-jet-speed constant. `--capture=siphon`'s two
shots are the visual pin.

**A stream reach as the penstock (2026-10-10) — WATER toolbar → Culvert
tool → "Penstock" chip.** Click a span of any mapped / drawn / traced stream:
from that span's upstream vertex DOWN to the nearest PowerSpout (within
`PENSTOCK_TURBINE_REACH_M` 250 m of any downstream vertex; none → one is
seated 3 m beside the stream's end via `SystemGraphView.place_powerspout_at`)
the stream becomes the turbine's penstock. Water side: those spans get
`WaterFeatureLayer.MODE_PENSTOCK` — no channel is carved, no surface strip,
`BuriedWaterBuilder.runs` emits NO barrel (the graph's routed conduit is the
visual; below the exit the stream carries on, the tailrace returns the
water). Graph side (`create_penstock_from_stream` →
`create_penstock_intake_at(..., opts)`): the intake prop stands at the reach's
head, the `poly_penstock` carries the reach's interior vertices (≤ 24, strided)
as LOCKED `route_3d` waypoints so the pipe follows the creek bed instead of a
chord over the ridge, and the intake is BOUND to the feature
(`specs.water_feature_bind`): `water_feature_supply_for_intake` asks
`WaterNetwork.feature_supply_on(fid, p, rain)` first — the stream's discharge
at the intake station at ANY distance — and only an unbound intake falls back
to the 6 m `feature_supply_at` rule. Also landed with it: **one penstock per
turbine** (`_remove_existing_penstock` — a re-route replaces the old intake +
run; a second drag used to leave two of each and the engine fed the turbine
from whichever it found first), a "not above the turbine" toast before a
headless pipe is routed, a plug pulled off an INTAKE's own port no longer mints
a second intake, `create_penstock_intake_at` refuses a non-hydro target, and
the Hydro Lab frames a stream-fed turbine along intake → turbine
(`frame_elevation_for_siphon` / the Lab's `_pond_context` use the stream
intake as the far end; with no pond the heading collapsed to 0 and the cut
ran E–W whatever direction the penstock came from). Verify: the stream-tap
half of `--capture=penstock` (ws_1 on Mt Vernon: 25 L/s, 45 m, ~210 W).

**Why the turbine could not be clicked ("a conduit modal keeps popping
up").** Three stacked causes, all fixed 2026-10-10, each of which RENDERED
plausibly: (1) `ConduitRouteController._input` started a plug/reroute on
EVERY left-press whose centre ray passed within 0.45 m of any port, with no
capture gate — a PowerSpout is 0.6 m long with four ports, so aiming anywhere
on it hit one; with the prop editor's tool overlay up (free cursor, screen
centre still on the turbine) every click on the dock's buttons was eaten the
same way, and the release opened the style modal. Now: nothing STARTS there
unless `CursorController.should_capture_look()`; a port on the prop under the
crosshair needs precise aim (`PORT_PRECISE_PICK_M` 0.15); a port behind
another prop never starts. (2) `InteractionFocus._update_conduit_focus` ran
before the (Ctrl-gated) prop pick with no occlusion test, and every conduit
ends AT a port on its prop, so its last samples always passed within the
0.42 m pick radius of the turbine body — the turbine could never be focused
and Ctrl+click (the documented select) opened the conduit style modal. Now a
pick at or behind the prop under the crosshair (`CONDUIT_PROP_CLEARANCE_M`
0.6, same rule in the route controller's `_conduit_pick_occluded`) is the
prop's, and (3) hidden runs (wires off in first person) are never picked —
they were still sampled and won focus invisibly. Pinned by the Ctrl+click
half of `--capture=penstock` (REAL events through the viewport: prop focused,
conduit focus empty, tool overlay up, no blocking modal).

**Your pipe, not a stock pipe (2026-10-10) — SDR, bends, high points, stock,
design checks.** The poly penstock used to be PE4710 SDR 9 by definition; a
player's coil is usually SDR 11 / 11.5. `conduit_style.pipe_sdr` (Hydro Lab
route row, `ConduitKinds.PENSTOCK_SDR_OPTIONS`) now drives three things from
ONE number: the bore (`inner_diameter_for`, ID = OD·(1−2/SDR) — 2" SDR 11.5 =
49.8 mm vs 46.9 for SDR 9), the working pressure (`pressure_rating_psi` =
2·HDS/(SDR−1), PE4710 HDS 1000 psi: SDR 9 → 250, 11 → 200, 11.5 → 190 psi) and
the minimum long-term cold-bend radius (`bend_radius_mult_for_sdr`, PPI
Handbook ch. 7 Table 1: DR ≤ 9 → 20×OD, 11–13.5 → 25×, 17–21 → 27×, else 30×;
a run with no styled SDR keeps the kind's 25× so every existing route is
byte-identical). **Bends are real in plan now**: `ContourRouter.fillet_xz`
rounds every interior joint (a pin, a stream vertex) with an arc of the pipe's
radius whose APEX is the joint — the pin stays ON the pipe, as coil is laid
past a stake — and a corner whose legs are too short for the radius gets the
biggest arc that fits. ⚠ The sweep direction is chosen by which arc end is
nearer the previous point, never by a cross-product sign: `Vector2.angle` in
the XZ plane inverted it and the route walked the arc backwards (a 0.6 m
"kink" and 3 m of extra run on a 90° corner). `ContourRouter.route_report`
(on a 1 m RESAMPLE — three samples on one sub-metre arc chord read as a
kink) stamps `route_min_bend_r_m` (plan + profile, −1 = straight),
`route_high_points` (crests of ≥ 0.3 m prominence) and `route_rise_m` (how
far the run climbs above the intake = a siphon leg) onto the connection via
`ConduitManager._write_contour_report`. `core/conduits/penstock_design.gd`
(`PenstockDesign`, pure) turns the operating point + those keys into the
checks a real install asks: velocity ≤ 3 m/s, friction ≤ 10 % of gross,
static head vs rating, Joukowsky surge on an instant stop (HDPE wave speed
≈ 317 m/s for 2" SDR 11.5 — a 2 m/s stop adds ~66 m, which is why a spear
valve closes slowly and a ball valve is never the shut-off), tightest bend vs
the pipe, high points (air-release valves), siphon lift (≤ ~8 m), and the
routed run vs `stock_length_m` (the Lab's "Pipe on hand (ft)"). The Lab's
Estimate fold lists them (✓ ⚠ ✗) and **Copy design summary** puts the whole
spec on the clipboard. Size / SDR changes restyle the LIVE run and remesh it
(`_apply_route_style`), so the engine adopts the new bore. Pinned to
hand-computed numbers in `conduit_selftest._test_penstock_spec_and_design`;
end to end (2" SDR 11.5, 350 ft, through the Lab's controls) in
`--capture=penstock`.
Round 3 (same day): **surge for the real closure** — the Lab's "Valve closure
(s)" (`specs.valve_close_s`, default 10 s) turns the instant-stop Joukowsky
figure into the Michaud slow-closure line ΔH = 2·L·v/(g·t) once the closure
is slower than 2L/a (`PenstockDesign.surge_head_closure_m` /
`critical_time_s`; the check names both numbers — a hand-wound spear over 10 s
on 118 m of 2" SDR 11.5 at 0.49 m/s is +1.2 m, a ball valve slammed under the
0.74 s critical time is the full +16 m). **Intake works** fold (`intake_works`):
screen gross area from a 0.3 m/s approach at 50 % open (ESHA §5.5), a settling
box sized to drop 0.3 mm sand (Pelton nozzle wear) at 2× the ideal Camp area,
L:W 4, through-flow ≤ 0.2 m/s, depth floored at 0.3 m, and the pipe mouth's
Gordon submergence S = 1.7·v·√D — all for the jet's FULL demand at the head,
not today's flow. **Firm flow** in the Estimate fold (`firm_flow`): the
driest / wettest month of the intake's seasonal curve with that month's watts
(from the annual estimate's own `monthly_kwh`), how many months run below the
jet's demand, and the nozzle that would run unlimited all year
(`PeltonPhysics.nozzle_d_for_supply_m` at the driest month). All three ride
the Copy design summary. Pinned in `conduit_selftest`; rendered + asserted in
`--capture=penstock`.

**Site Plan hardening for the water → turbine pipeline (2026-10-10).**
(1) Port dots and grabs are CAPPED on screen in Site Plan (`_draw_port_dot` /
`_port_grab_radius`, `SITE_PORT_DOT_*` / `SITE_PORT_GRAB_*`, ~0.3 m of ground
clamped to 3.5–7 px / 8–14 px) — the uncapped `6 × _zoom` drew every port the
size of the node at a zoom where a PowerSpout is 12 px, so four discs hid the
turbine and each other, and the matching `9 × _zoom` grab blocked every pick
around a port (Elevation had the same cap already). (2) A water wire pulled
off a hydro turbine's input and dropped ON a stream (or the cyan outlet dot now
drawn at the end of every penstock / pipe run) emits `stream_tap_requested`
→ `SystemGraphView.tap_stream_for_turbine(fid, seg, turbine, handle)`: inside
an existing penstock / pipe run the WHOLE run is the reach (its upstream
vertex the intake, its outlet the exit), otherwise the reach runs from the
drop's vertex down to the vertex nearest the turbine; the water side is
marked penstock and the graph side routed + bound exactly as the toolbar's
Penstock chip does. The hovered stream highlights amber during the drag with a
hint. (3) First person has a STREAM rung (`_update_stream_focus`, after
still water, before buildings / veg): aimed at a creek the player used to get
the forest polygon it runs through ("Fill forest") — Interact now opens the
WATER toolbar on its Edit tool with the stream picked
(`TerrainLoader.pick_stream_at_world` / `open_water_tools_on`,
`WaterToolController.pick_feature`). All three asserted in `--capture=penstock`.

**Hydro perf pass (2026-10-10).** `ResourceFlowEngine._penstock_conn_for`
memoises per step (`_penstock_conn_cache`, cleared in `_rebuild_conn_index`;
five callers rescanned every connection each tick); the seasonal supply
curve is cached PER INTAKE (`_supply_profiles` — one engine-wide field
thrashed between two stream-fed turbines); `SystemGraphView._item_world_xz`
caches the prop-anchor resolve for 1 s; `HydroSource._pelton_op` memoises the
40-iteration Pelton bisection by its seven inputs (power and flow asked for
the same point every tick, the Lab's charts dozens per redraw);
`WaterNetwork._drive_outlet_vfx` runs at 10 Hz; the WATER toolbar's `process`
is idle-gated on pointer + camera motion like the other sections; the Lab
samples pond inflow at 4 Hz and quantises the live supply in its estimate /
chart signatures (at 4 decimals live rain reran 12 Pelton solves + the curve
families at 6 Hz).

**ONE water-source model (2026-10-10, the merge pass).** The five ways to
make a penstock (3D plug drag → `create_penstock_intake_at`; Lab drag; Lab
auto-route with its own terrain ring scan; Lab "From pond" restyling the
pond wire in the modal; the WATER toolbar chip / Site Plan drop with their
own reach + turbine-seating code) had three source types and no shared
notion of "what feeds this turbine". Now ONE module owns it —
`system_graph/graph_hydro_routing.gd` (`GraphHydroRouting`, lifted out of
the view on 2026-10-18 as the first Push 4 monolith slice; the view keeps
one-line delegates with the same names, so every caller below still says
`SystemGraphView.<fn>`):
- `resolve_hydro_source_at(world_xz, stream_max_m=8)` → `{kind: "pond" |
  "pond_unadded" | "stream" | "spring", …}` — a still-water body with a
  `pond_storage` tank on the graph (matched by `osm_water_tag`), else a
  water body not yet on the graph (toast: add it first), else a stream
  within 8 m (`TerrainLoader.pick_stream_at_world`), else bare ground.
- `route_penstock_to_source(turbine_id, source, opts)` — the ONE router:
  pond → `_route_penstock_from_pond` (reuse or add the pond→turbine water
  wire, restyle `poly_penstock`, clear pins, reveal — the Lab's old "From
  pond" moved here); stream → `tap_stream_for_turbine` (now takes the
  style); spring → `create_penstock_intake_at`. `opts` carries
  `pipe_size_in` / `pipe_sdr` / `stock_length_m` / `handle_id`. ONE penstock
  per turbine: `_remove_existing_penstock(turbine, keep_conn_id)` now
  sweeps EVERY poly_penstock on the turbine (it used to drop only the engine's
  current one, so a pond penstock could survive beside a stream one) and
  frees an orphaned intake + its prop.
- `find_uphill_source(turbine_id, max_m=150)` — a STREAM vertex ≥ 1 m
  above the turbine (highest, shorter on a tie), else the old 48-angle terrain
  ring scan as a spring. A creek is where the water IS; the terrain scan
  found hilltops with no flow. The Lab's auto-route button calls it.
- `hydro_source_summary(turbine_id)` → the Lab's "Water source & penstock"
  section's first line (Stream: Walton Creek — 2.4 L/s at the intake / Pond:
  … level / Spring: … / No source).
- `_auto_penstock_for_new_water_wires` (deferred off `_on_model_changed`
  "add_connection", skipped under history-suppress / bulk): a plain water
  wire from a pond tank or a stream intake into a hydro turbine's `res_in_*`
  becomes that turbine's penstock. A Site Plan / freeform port drop used to
  make a schematic wire the physics ignored, and the Lab then said "Not
  routed".
  ⚠ Every hydro preset marks its water input `direct_intake`, so
  `GraphModel.add_connection` stamped a hand-drawn wire into a PowerSpout as
  a no-pipe dip-tube intake and the restyle skipped it. The turbine KIND now
  decides: `ConduitKinds.is_direct_intake_connection` ignores the flag for
  `has_penstock` kinds, and the restyle clears a stale stamp. Only the siphon
  drinks directly. Pinned in conduit_selftest and penstock's auto-restyle
  check (fixed 2026-10-12).
Call sites now all go through the resolver: the route controller's
`_commit_penstock_to_new_intake` (a plug dropped in a creek taps the creek;
a pond, the pond), the Lab's `_commit_penstock_drag` / `_on_auto_route_uphill`
/ `_on_route_penstock` (`_route_style_opts()` reads size / SDR / stock off
the route row for all three), and `water_tool_controller._make_penstock_run`
(delegates to `tap_stream_for_turbine`; the toolbar's own exit-vertex /
span-marking copy is gone). Site Plan: a node under
`SITE_PORTS_MIN_NODE_PX` (44 px — chips floor at `MIN_CHIP_PX` 28) draws NO ports and `_get_interactive_
handle_infos` returns none for it — the magnifier is the thing to click
there; before, four capped-but-still-7-px discs sat on a 12 px turbine.
⚠ **The port cap lives in TWO files (2026-10-11).** `graph_canvas_v2.gd`
OVERRIDES `_draw_port_dot` for its freeform billboard (pulse, hover ring,
`6.8 × _zoom` disc) and that override used to run in Site Plan and Elevation
too — so the base's `SITE_PORT_DOT_*` / Elevation caps were DEAD in the
shipping canvas and the ports still grew to the node's size at high zoom
after the cap "landed". The override now routes every `_is_physical_view()`
call to `super()`; `--capture=graph` shoots `07c_site_plan_zoomed_ports`
and prints the dot/grab radii against their caps (PASS/FAIL). Any new
per-view sizing rule in the base must check that V2 does not shadow it.
`--capture=penstock` asserts the resolver (creek → stream, 64 m off →
spring), spring + stream routes replacing each other with the opts carried,
`find_uphill_source`, the summary, the auto-restyle of a hand-drawn wire,
and the tiny-node port hide.

**Stream-intake VFX** (`gameplay/stream_intake_flow.gd`, attached by
`PlacedPropRuntime._maybe_attach_stream_intake_flow` on `model_id ==
"stream_intake"`): falling inflow plus a pool whose level rises with
`live_supply_lps`, so a dry spring and one in spate no longer look identical in
the world. ⚠ It resolves its `graph_item_id` LAZILY per poll, because
`create_penstock_intake_at` places the prop and patches `graph_item_id` onto the
record AFTERWARDS — the runtime is attached with an empty id and, without the
re-read, never showed water at all.

**Turbine close-up** (`scenes/ui/hydro_turbine_closeup.gd`, a Hydro Lab view tab):
an `own_world_3d` studio — deliberately not `graph_soi_preview_service`, which
carries the AMD-TDR crop/clamp scar tissue — showing the real
`Pelton Wheel, 24 Spoon` node with the housing ghosted (`CULL_FRONT` on the shell
is what reads as *cut open* rather than as fog; the housing set is DERIVED as
"every mesh that is not the runner", never name-matched). Two traps, both of which
RENDER rather than erroring: the spin centre must be measured in the runner's
**PARENT** frame (`_runner_centre_parent`) because `_runner.transform` is local and
the GLB has a baked inch→metre node between ModelRoot and the wheel — rotating
about a ModelRoot-space centre throws the wheel out of the housing; and the jet
must arrive **in the plane of the wheel** (`_jet_side`, perpendicular to the spin
axis), or a side-on camera looking along that axis sees it end-on and it is
invisible. Speed is `omega_rad_s_at_ratio(v_jet, PCD, speed_ratio_for_load(load))`,
so shedding the load runs the wheel toward 2·x_opt while `runner_efficiency`
collapses to zero — verified by `--capture=siphon`'s console dump (matched 458 rpm
η 65% → runaway 903 rpm η 0%). `core/conduits/pelton_jet.gdshader` scrolls at the
REAL `jet_velocity_ms`; it is written clean rather than reusing
`terrain_river`/`terrain_water`, which `#include soi_clip.gdshaderinc` and can
vanish in a studio viewport where the clip uniforms are unset.

**Second Pelton + the jet's-eye close-up (2026-10-11).** The AliExpress-class
micro Pelton (`Imported Models/Hydro/ali_pelton.glb`, the user's SketchUp
model; catalog `ali_pelton`, kind `micro_pelton`, preset "Micro Pelton 500W")
is an 8″ runner on a VERTICAL shaft under a 10″ plate with a Nema 34 stepper
hung below as the generator and a 1/4″ NPT hose-barb fitting through the
housing wall as the nozzle. Measured with `glb_dump_diag` (never assumed):
runner `Node6`, r 0.101 m, thin axis → model-local +Y (`spin_axis: "y"` —
SiphonTurbineSpin's +Z default would tumble it); the fitting's centreline
runs along −X at 0.084 m off the shaft → PCD 0.168 m; the housing bottom at
y −0.076, the stepper to y −0.156 (the foot). The export carries two FLAT
SketchUp SCALE FIGURES ("Sree", and "Susan#1" under a node named "Pelton")
metres from the machine: `strip_nodes` on the catalog entry, freed inside
`ModelCatalog.instantiate` so `mesh_metrics`, the foot, the pick AABB and
every studio see one machine. `ConnectionPortDefs.default_ports_for_model`
has a measured branch for it (the generic hydro box puts the inlet on a face
with no fitting). PackedSpec coverage: `ali_pelton` curated.
- **⚠ Two frames for one axis (fixed 2026-10-11).** `spin_axis` on the
  catalog is a MODEL-ROOT axis; the close-up rotates `_runner.transform`,
  which lives in the runner's PARENT frame, and this GLB's top node is turned
  −90° about X — so model-root +Y arrives in the parent frame as +Z. The
  close-up used the catalog axis raw and the micro Pelton spun like a coin
  on a table (axis in the disc's plane; the PowerSpout's chain has no
  rotation, so it never showed there). `_measure_runner` now carries the
  axis through the inverse of the parent's chain (`_runner_axis_parent`,
  the same conversion `SiphonTurbineSpin` does via world space), measures
  the disc's own normal (thinnest mesh extent) in that frame, warns and
  falls back to the measured normal if the two disagree, and
  `--capture=siphon` asserts spin axis ∥ disc normal in the parent frame.
- **The close-up wears the kind's model.** `set_state` carries `model_id`
  (from `HydroSource.kind_meta`) and `_rebuild_model` swaps the machine in
  place; the runner's axis / centre / radius / thickness, the inlet port
  height and the nozzle are re-measured. Catalog `nozzle_node` +
  `nozzle_axis` name a MODELLED nozzle: `_measure_nozzle_base` takes the
  fitting's authored axis, signs it toward the runner, and puts the mouth at
  the fitting's far corner along it; with none (the PowerSpout) the
  procedural spear nozzle hangs off the real `res_in_0` port as before. The
  side camera orbits in a frame built from the shaft (`_orbit_frame`: world
  UP unless the shaft IS vertical), so a vertical-shaft machine is seen in
  plan.
- **Nozzle placement is six numbers on the specs** (Lab "Nozzle placement",
  nozzle kinds only; visual, never physics): `nozzle_offset_mm` (aim offset —
  the in-plane perpendicular, height on a horizontal shaft; the old single
  knob), `nozzle_axial_mm` (along the shaft: the splitter vs one half of the
  bucket), `nozzle_angle_deg` (where on the rim, turned about the shaft),
  `nozzle_tilt_in_deg` / `nozzle_tilt_out_deg`, `nozzle_standoff_mm`. All
  applied in `_nozzle_pose` on top of the measured base; the SECOND jet is
  the first turned half a revolution about the shaft (both drive the wheel
  the same way — the old code mirrored it across the shaft, which would have
  driven it backwards). The landing is `_impact_from`: the ray vs the PITCH
  cylinder (`_pitch_radius`: the kind's PCD/2, clamped inside the tip; a
  chord on it lands at the TANGENT point; closest approach when it misses),
  so a tilted or off-rim jet still lands somewhere. ⚠ The first cut used the
  TIP radius: the chord enters the tip circle well before the tangent point,
  grazing the first bucket's outer edge, and the jet's-eye shot read as the
  jet hitting the cups FROM THE SIDE — "the runner must be 90° off". It was
  not: `core/placed_models/runner_look_diag.gd` (bare runner from the jet's
  eye / radially / in plan with jet + shaft rods) showed the splitter ridge
  radial with a cup each side along the shaft, i.e. modelled right.
- **Jet's eye** (`set_camera_mode("jet")`): the eye just behind the mouth,
  lifted off the jet line by a couple of nozzle radii so the rod does not fill
  the frame, looking at a cyan LANDING RING on the cups; the modelled fitting
  is hidden (the eye is inside it); drag nudges round the landing, wheel
  dollies. The HUD adds where it lands ("on the splitter" / "N % to one
  side").
- **The water leaves the bucket by the bucket relation, as two SHEETS.**
  `PeltonPhysics.bucket_exit_velocity(v_jet, x, deflect)` (pure; pinned):
  the relative flow `w = v − u` turned through `BUCKET_DEFLECTION_DEG` 165°
  (Thake — the lip is cut back so the water clears the next bucket; 180° is
  the textbook limit) plus the bucket's own `u` → {tangential (along the jet,
  − = thrown back), axial (sideways, ± per splitter half), speed}. At 180° it
  IS `bucket_exit_speed_ms`; at the matched load it leaves slow, slightly
  backward and mostly SIDEWAYS; stalled, straight back at full speed. One
  GPUParticles sheet per splitter half per jet (spread 9°, velocity from the
  relation), their shares weighted by how far the landing sits off the
  splitter (`split`, from the axial offset vs the runner thickness) — the
  axial knob visibly starves one side. "Vectors" draws the jet (cyan), the
  bucket's u (amber) and both exits (blue) in one length scale. The old
  back-splash is now a small mist at the strike.
Verify with `source_physics_selftest` (the vector form), `siphon_hydraulics_
selftest` (catalog / kind / ports / strip pins) and the micro-Pelton phase of
`--capture=siphon`.

## Conventions

- Signals are wired in code in `_ready()` (zero editor connections).
- UI styling goes through `scenes/ui/ui_theme.gd` (`UITheme`): palette,
  status colors (`C_OK/C_WARN/C_ERROR/C_INFO` — one red, not four), StyleBox
  factories (`panel_style`/`card_style`/`button_style`/`chip_style`), font +
  spacing scales, and `LAYER_*` CanvasLayer bands. Migrating files keep their
  local const names but redirect values (`const C_BG := UITheme.C_BG`).
  Semantic registries (graph PORT_COLORS etc.) stay local. Multi-phase UX/veg
  improvement plan: `plans/UX_IMPROVEMENT_PLAN.md`.
- Physics: cite formula sources in comments; never invent constants; every
  physics change adds checks to source_physics_selftest.gd.
- Node-name lookups are load-bearing (e.g. "SystemGraphView", "SolarUI",
  "Main") — renaming scene nodes breaks SimMode/AutomationEngine/UIs.
- Commit style: imperative subject, body explains what+why, validated-by note.

## gstack

Use the `/browse` skill from gstack for all web browsing. Never use the
`mcp__claude-in-chrome__*` tools directly.

Available gstack skills: `/office-hours`, `/plan-ceo-review`, `/plan-eng-review`,
`/plan-design-review`, `/design-consultation`, `/design-shotgun`, `/design-html`,
`/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`,
`/connect-chrome`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`,
`/setup-deploy`, `/setup-gbrain`, `/retro`, `/investigate`, `/document-release`,
`/document-generate`, `/codex`, `/cso`, `/autoplan`, `/plan-devex-review`,
`/devex-review`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`,
`/learn`.

## Fire (crisis_events/fire/) — the burn front

A fire used to be a POINT: it sat where it was lit and "spread" only by
absorbing whole sibling meshes, so a structure that is one mesh never spread,
and `ignition_point_on_mesh_progress` worked in the mesh's LOCAL frame (local Y
is not up on a Z-up GLB, and its "lift" was read off the local height and added
as metres — on an inch-unit import that is metres above the model: "the flame
starts at the very top"). `FireNode` now runs in **surface mode**:

- On its first `_process` frame (not `_ready` — the event positions the node
  AFTER `add_child`, and that position is the ignition spot) the structure is
  sampled once into ~3000 world-space surface points, AREA-weighted over the
  triangles (a box is twelve triangles; one point each is eight candles),
  sorted by height.
- `burn_progress` 0..1 is the front. It climbs in REAL time (~0.22 m/s, 18–90 s)
  as well as sim time, holds while sprayed, and reaches round the base from the
  ignition spot before it tops out. `WALL_GROWTH_PER_SEC` does the same for
  intensity: at 1x sim speed `GROWTH_RATE` alone adds 0.02/s and a fire never
  reached `SPREAD_MIN_INTENSITY`.
- The emitters switch to `EMISSION_SHAPE_POINTS` over the points in a band
  under the front, rebuilt in `BURN_STEPS` steps; the node moves to that band's
  centre so the lights and the extinguisher's detection sphere travel with it.
  In surface mode the emitters keep a FIXED `amount` and unit scale/zero offset
  (the points are world offsets) and `amount_ratio` does the scaling — writing
  `amount` restarts an emitter.
- `fire_char.gdshader` is assigned as `material_overlay` (so the model keeps
  its own materials): scorched behind the front, black below, an ember line on
  the front, all from world height + distance from the ignition point. Late in
  the fire `char_all` takes the whole structure black, then from
  `BURN_AWAY_FROM` of its life the materials are swapped for `fire_ash.gdshader`
  (noise-threshold dissolve, top first) — the overlay is REMOVED at that point,
  because it redraws the whole mesh and would fill the holes back in.
  ⚠ `GeometryInstance3D.transparency` was tried for the fade first: it hides an
  alpha overlay entirely, so the charred structure flashed back to clean wood.
- Restore goes through the existing `_restore_burned_mesh` /
  `regenerate_meshes_under`, which now also clear the overlay
  (`fire_char_overlay` / `fire_pre_overlay` metas). A fire put out part-way
  leaves the char exactly where the front reached, with the embers off.
- **Collapse, then a pile that burns down** (`FireAshPile`,
  `fire_ash_pile.gd` + `fire_pile.gdshader`). Burning away used to leave the
  last quarter of a structure hanging in the air. At `DISSOLVE_AT_COLLAPSE`
  0.65 — MEASURED as 75 % of the surface gone against the ash shader's noise,
  not a guess — the ash shader's `collapse` uniform drops what is left into
  the base (world_vertex_coords; the burn pattern is keyed on the PRE-fall
  position so the holes ride down with the piece), the pile fires a one-shot
  `whoosh()` (flame, smoke, sparks) as the fall passes its midpoint, and the
  meshes are hidden when it lands. The pile covers the footprint of the BASE
  (bottom quarter of the surface points) and is a RENDERER: FireNode hands
  it `FireAshPile.look(age, bonfire_h, ember_h)` every frame (`set_look`);
  it keeps no clock of its own. It is removed by Restore / prop delete.

**The fire is a PURE FUNCTION of sim time (`FireTimeline`,
`crisis_events/fire/fire_timeline.gd`).** Everything a fire IS lives in one
JSON record — `ignited_h`, the three durations `climb_h` (ignition →
collapse), `bonfire_h`, `ember_h`, their `auto` estimate, `holds`
(`[[a, b], …]` abs hours the extinguisher held it; the burn clock stops
inside) and `out_h` (put out: the state FREEZES there) — and
`FireTimeline.state_at(rec, t)` says what to draw. `FireNode` integrates
NOTHING any more: each frame it reads the clock
(`Main.get_absolute_hours`), computes the state and RECONCILES the scene to
it (`_apply_state`, idempotent and order-free), so scrubbing the timeline
backwards stands the structure up again and the whole life runs at the
world's rate at any speed. Records are written only when something happens
(ignition, spray holds, going out, a duration edit). What it replaced, so
nobody restores it: a real-time climb (18–90 s regardless of sim speed),
`fire_time_hours` integration, `DESTROY_TIME_HOURS`, the per-frame re-armed
smouldering pile, and `FireEvent.cleanup` freeing the nodes. Rules:
- **For a placed prop the record rides the prop** (`rec["burn"]`, written
  via `TerrainLoader.set_prop_burn_record`, which is QUIET — a prop rebuild
  frees every prop node and spraying writes once a second — and debounces
  the save). `FireNode.sync_prop_fires` (from `_rebuild_placed_props`) brings
  a saved fire back at the right moment of its life on reload; a FireNode
  whose prop was rebuilt under it `_rebind_scope`s to the new node and
  re-applies the state; one whose record was removed (Restore →
  `clear_prop_burn_record`) disposes itself, pile and all. ⚠ A fresh
  FireNode has no record on the prop until its first flush — `_flushed_once`
  is what stops it disposing itself on frame one. Scene structures (no
  prop) keep the record in memory.
- **Durations are estimated from the structure** (`FireTimeline.estimate`:
  climb from height + base footprint, bonfire ∝ fuel mass^0.7 with a tonne ≈
  6 h, embers a 0.35 share; mass from `PackedSpec` where the catalog knows
  it, else surface area × 25 mm of timber) and the player can override them
  in the prop editor's Fire section — on the LIVE record while it burns
  (`set_duration`, `reset_to_auto`) or as `rec["fire_plan"]` for a fire that
  has not started, which `_estimate_durations` applies over the estimate at
  ignition. The collapse itself is `COLLAPSE_H` = 3 s of SIM time: a real
  fall at 1x, a snap at speed, with the real-time whoosh carrying the moment.
- **The extinguisher writes HOLDS, not progress.** While sprayed the front
  simply does not advance (`burn_hours` nets the hold out), so a held fire
  collapses later by exactly the hold; `intensity` is now only the fight —
  it sits at the phase's level and the spray pulls it down; at the threshold
  `put_out` is written and everything freezes at that hour (char where the
  front reached, embers off, a doused pile loses its glow). `FireEvent` is a
  thin wrapper: it mints the record (`fire.ignite_at`), hears
  `fire_extinguished` ONCE when there is no open flame left (put out →
  RESOLVED; burned down past the collapse → FAILED, the structure is lost)
  and never frees a FireNode.
Scope: `MeshInstance3D` only (as `set_burnable` always was) — MultiMesh-built
structures such as Linkage frames are not sampled. A point fire (no readable
geometry) gets the same timeline and pile without the fall.

## Placed-prop editor (`scenes/ui/placed_prop_edit_ui.gd`) — ONE dock, a gumball

`UILayer/PlacedPropEditUI` is the editor for EVERY placed thing. It replaced
a two-row bottom drawer of spinboxes that locked the mouse into a modal, and
— the complaint that drove it — the per-model redirects in
`interaction_focus.open_prop_edit_ui` that sent a StarShade to the StarShade
designer, a trash/mud printer to the print setup and a pallet rack to its
builder, none of which could move or delete the prop (a StarShade had no
Delete anywhere). Those are BUTTONS in its Model section now; the Interact
key keeps its "use it" meaning (linkage deploy/stow, FDM print setup, packed
crate unpack) while a click always opens the editor.
- **Tool-overlay tier** (`CursorController.request_tool_overlay`, the J
  Light Studio contract): free cursor, RMB look, WASD, one Esc closes (Esc
  first cancels a drag or disarms Delete). Right-edge dock, `UITheme`
  sections: Placement / Display / Fire / Model, footer Duplicate + Delete.
- **The gumball is a `LightGizmo`** (generic despite its name) on the
  prop's origin: arrows + planes move, rings rotate, `L` or the World/Local
  button switches frames, Shift snaps 0.25 m / 15°. Drags preview through
  `TerrainLoader.preview_prop` and COMMIT on release through
  `PlacedPropService.update_prop_record(main, id, patch, rebuild_prop=true)`
  — only THIS prop is rebuilt; the loader's `update_prop_record` rebuilds
  every prop and would pull the node out from under the gizmo (OSM
  replacements still go through the loader so their building re-attaches).
  Clicking another prop in the world switches the editor to it.
- **Fire section**: Burnable; the auto estimate line (durations + fuel
  mass); three duration spinboxes in MINUTES that write `fire_plan` before a
  fire and the live record during one; Auto (reset), 🔥 Ignite (through the
  crisis manager — found by NAME, `CrisisEventManager`, the group is only
  added later), Put out, Restore.
- Delete is two-click (arm, confirm); Duplicate goes through
  `TerrainLoader.duplicate_prop_record` (strips id / burn / graph binding /
  stow state) and selects the copy.
Verify with `--capture=propedit` (Validation list).

## The beat: dancing to the music, sound-reactive lights (2026-10-08)

**One registry, `StageBeat` (`core/population/stage_beat.gd`).** Every stage
with a set on — and every venue playing its own track — publishes its beat
each frame from `StageMusic._publish`: {pos (the speakers), radius
EARSHOT_M 180, bpm, beat, energy, breakdown, build, drop_pulse, until_drop,
since_drop, running, live}. Readers ask `StageBeat.at(pos)` (nearest in
earshot, extrapolated to NOW so a reader between publishes still lands on the
beat). The crowd shader gets the 4 nearest to the camera as globals
`music_pos0..3` / `music_beat0..3` (declared in project.godot
[shader_globals]; beat wrapped mod 128 for float precision; reading a global
back is editor-only, so `StageBeat.pushed_pos` mirrors what was sent). The
music plays at 1× whatever the sim speed, so dancers at a stage move at the
real tempo; it pauses with the sim.
- **Real tracks: live analysis with LOOKAHEAD.** `StageMusic` plays a
  second, silent, non-positional copy of the track LOOKAHEAD_S (5 s) AHEAD of
  the audible one on its own bus (`BeatAnalysis0..3`, ANALYSIS_SLOTS 4) at
  -80 dB with an `AudioEffectSpectrumAnalyzer` — measured: the analyzer reads
  the signal before the bus volume, on WASAPI and the headless Dummy driver
  alike. `BeatTracker` (pure) turns the bass band into kicks, tempo (the
  pairwise-interval histogram gives a COARSE tempo; a least-squares line
  through the kicks' chained beat indices gives the period and phase — the
  histogram alone sat on 0.467 / 0.483 s for a 0.476 s beat because kick
  times are quantised to the 60 Hz analysis frame), breakdowns (slow bass
  under 0.35 of its peak for 1.5 s) and DROPS (the first strong kick after
  ≥ 2 s of breakdown, snapped to the beat). Queried at the HEARD time, a drop
  is known up to 5 s before it is heard — that is what lets the DJ raise an
  arm in time. The audible player starts at, and is re-synced to (> 0.12 s
  drift), analysis − 5 s. Analysis time is the track POSITION only (no
  time-since-mix extrapolation: measured closer to the true tempo).
- **No track: `BeatGrid`** — a virtual set per stage (tempo by hash from
  122/124/126/128/140/174), 32-bar phrases: groove, breakdown at beat 96,
  build from 112, the drop on the phrase. Opens mid-groove so the first drop
  is ~30 s in. Same output keys.
- **Dancing** (Settings → NPCs → "Dance to the beat", `NpcDisplayPrefs.
  beat_sync`, default on): the crowd shader's `music_at` and the stick
  figure's `set_beat` (NpcAvatar hands it `StageBeat.at` while dancing) put
  dance / rave / sway / samba / DJ on the beat — one bounce per beat, half the
  crowd a beat out on the sway — throw harder with the energy, raise both
  hands through the run-up to a drop (3 in 4 dancers; `ANTICIPATE_S` 4 s,
  mirrored in the shader as `MUSIC_ANTICIPATE_S`) and keep them up as it
  lands with a jump. **The DJ** raises the left arm and HOLDS it through the
  run-up, both arms in the last moment and on the drop, and jumps. Verify
  with `beat_look_diag.gd`; the rigged Mixamo body plays its clip unsynced.
- **Sound-reactive lights**: three style keys on every light kind
  (`sound_reactive`, `sound_mode` pulse | beat | both, `sound_depth`), shown
  in the J dock's "Sound" section. `StageBeat.light_level` = a kick envelope
  on every beat (rolling to 8ths then 16ths through a build), scaled by the
  energy (dim in a breakdown), plus a flash on the drop; "beat" mode drives
  the effect clock from the music (`light_time`, chases and mover sweeps move
  with the tempo). PlacedLight / PlacedMoverLight (`sound_level`,
  `effect_time()`) and PlacedStringLight (heard at the middle of the string)
  apply it; a light with no music in earshot is just itself.

## Placed vehicles, third person, the player's body (2026-10-08)

**Driveable vehicles from the library** (Unified library → **Vehicles** tab;
catalog category `vehicles`, entries carry `vehicle: <PlacedVehicle.PROFILES
id>`): EUC, Appa (golf cart), skid steer — the scene vehicles' own art at
native scale — plus **Tool Bus** (the International 3800 out of
`Busses.tscn`, the other bus in that file deliberately left out) and the GMC
camper van, which go
through `VehicleModelBuilder` (`source_path` + `isolate` + real `length_m`:
keeps ONE bus of the pair, FREES every hidden node — `ModelCatalog.mesh_metrics`
measures hidden meshes too — lays the long axis on Z, scales to metres, stands
it on y = 0; `flip` turns a model round if its front is backwards).
`PlacedPropRuntime._maybe_attach_vehicle` hangs a `PlacedVehicle`
(`gameplay/placed_vehicle.gd`) under the prop; it speaks the scene vehicles'
duck-typed API (mount / dismount / get_riding_params / range signals — it
self-notifies the player, since `main._connect_vehicles` runs once at boot),
so the player's riding code drives it unchanged. Rules: getting IN snaps the
rider onto the parked vehicle facing its way (scene vehicles snap to the
rider); the prop's collision is OFF while ridden and re-baked
(`setup_collision`, deferred) after the rider steps out LEFT past its
half-width — the StaticBody bakes ModelRoot's rotation into its shapes; the
record is patched IN MEMORY every 0.5 s while driving and saved on dismount;
a prop rebuild while ridden hands the rider to the replacement node
(`_handover`, never during map unload); electric profiles drain with
distance and trickle-charge parked (`charge_w`, sim time) so a flat battery is
a wait, fuel ones show "fuel" on the dashboard. Interact on a placed vehicle
under the crosshair drives it (`interaction_focus._open_placed_prop_edit` →
`player.request_mount`); a click still opens the prop editor. Riding numbers
for the original three are copied from their scripts (the skid steer's
`model_rotation_offset = 91.145` in the scene is RADIANS ≈ 182.2°). A vehicle
model's ROOT position is zeroed in `ModelCatalog.instantiate` (appa.tscn's
root carries a 0.6 m offset the scene instance overrides — left in, the
driver sat beside the cart). Verify the art faces the right way with
`gameplay/vehicle_look_diag.gd` and the whole loop with `--capture=vehicles`
(Validation). Two pre-existing bugs fixed on the way:
`PlacedPropRuntime.find_by_prop_id` looked only under Terrain, so on the
built-in scenes (props under Main) it found nothing and every
`_reposition_scene_prop` move SPAWNED A DUPLICATE node; and
`PlacedProp.setup_collision` queue_freed the old "PropBody" and added the new
one the same frame, so the new one was auto-renamed and lookups by name found
the dying body (the old one is now renamed and disabled first).

**Third person (F5 `toggle_third_person`, Settings → Player).** The CameraArm
detaches (`top_level`) and is placed every frame behind and over the shoulder;
the Camera3D under it keeps its own LOCAL maths (pitch on rotation.x, shake on
position), which is why the FOV, the crosshair ray, camera claims and the FPV
drone (which borrows this camera — the arm goes home while it flies) all keep
working untouched. Mouse yaw orbits (`_tp_yaw`); walking is camera-relative
and the body turns to face its velocity (or the camera while using a tool);
driving, the camera orbits and swings back behind after 1.4 s untouched; on
the EUC the mouse still steers so the camera rides locked behind. Collision:
a physics-frame ray pivot→camera (`_tp_probe_camera`), pulled in at once and
eased back out. In third person the vehicle tilt / seat offset are skipped
and interaction REACH is measured from the player's head
(`player.reach_origin`, read by InteractionFocus). Fixed alongside: the centre
ray's `exclude` passed the player NODE where Godot wants RIDs. PlayerPrefs
(`core/player_prefs.gd`, `user://player.cfg`) holds camera mode, follow
distance, shoulder, recenter, body and tint, polled by generation (the panel
and the player never reference each other). The **player FOV slider moved**
from Lighting to the Player tab; its storage is unchanged
(sim_settings.cfg [camera] player_fov).

**The player's body.** Default = `NpcSimpleFigure` with `hi_detail` (waist,
pelvis + shoulder girdle, neck, jaw, hands, feet kept level, and two extra
pivots the driver writes directly so they never fight the poses' easing: LEAN
at the hips, NECK for head-look) driven by `_update_character_animation_simple`:
idle / walk / RUN (its own pose, flight phase + pumping arms) / air (tuck
rising, reach falling) / landing dip / seated at the wheel at the vehicle's
seat / standing on the EUC / arms forward with a tool, lean into speed and
turns, head following the camera. ⚠ The figure is built facing +Z and is
turned PI — the player's body had been walking BACKWARDS (the NPC avatar got
this fix long ago; the player's never did). First person hides the head and
neck (shadow-only). Remy (asset pack) and custom characters are opt-in
(`PlayerPrefs.body()`): `.glb/.gltf/.fbx` in `user://player_characters/` load
at RUNTIME (GLTFDocument / FBXDocument), are scaled to 1.75 m and turned to
face forward; their own idle/walk/run clips are used when named so, else a
Mixamo rig borrows Remy's clips RETARGETED by bone name (`_bone_key`:
mixamorig:Hips == mixamorig1_Hips == Hips; hips position scaled by hip height;
a clip binding < 12 bones is refused, never played as a T-pose).

**NPC names (Settings → NPC → Names).** Comma-separated names are ADDED to
`NpcAgent.NAME_POOL` (`NpcDisplayPrefs.custom_names`, `parse_names` splits on
, ; and new lines, dedupes case-insensitively); `NpcAgent.name_pool()` caches
per prefs generation. Changing the list re-deals names. Names carry NO number
("Spark", never "Spark 25" — 2026-10-09): a camp ("<seed>_npc_<i>") walks the
pool from a per-camp start with a stride coprime to its size, so nobody in one
camp shares a name until the camp outgrows the pool; other ids hash. The id is
the unique key everywhere, never the name. The population and cohort
selftests clear custom names in `_init` (`reset_custom_names_for_test`) so a
player's friends never move a pin.

## Site deployment schedule — "set a time, everyone builds / packs" (2026-10-26)

Plan: `plans/DEPLOY_SCHEDULE_PLAN.md`. Deployable infrastructure as a game
mechanic: the timeline's **Deploy** chip (or the festival panel's "Deploy
from now" / "Pack up from now") puts a DEPLOY or PACK-UP event at the
playhead; when the clock crosses it, the camps' people build every packed
structure and pitch every struck camp (or take it all down and pack it),
and the site lives in it. Flags on the clips lane (drag to retime,
right-click, double-click to jump); the chip reads green while a crew is on
it. Everything rides the existing Site Projects pipeline; nothing was
duplicated.
- **`SiteDeploySchedule`** (pure): the per-world record (WorldPaths kind
  `deploy_schedule`, `TerrainLoader.deploy_schedule_path`) — events
  `{id, action deploy|packup, at_h}` and a `fired` stamp per event that
  carries what a reload needs (crews, items, pending, projects, done).
  `due(prev, now)` = forward crossings not yet fired; `rewound` = fired
  events the clock went back past; moving an event clears its stamp.
- **`SiteDeployPlanner`** (pure): inventory items (props with a packed spec,
  painted camps) → `pick_crews` (nearest camps to the work until
  `ALL_HANDS_MAX_PEOPLE` 320) → `assign` (nearest crew with board room: rows
  + one project slot; the rest wait) → `rows_for(item, action, roster)`:
  linkage = the rebuild / breakdown rows; pallet rack = unpack → raise
  frames (four) → decks → finish (unpack_prop); any other packable prop =
  lay out → assemble (ghost firming through `set_build_phase`) → finish;
  pack-up = take down (ghost) → pack (pack_prop); a camp = one pitch /
  strike row with the new `set_camp_built` effect. Labour is PERSON-HOURS
  from the packed mass (0.4 + kg/40, pack-up ×0.6) — estimates, tune there.
- **`SiteDeployDirector`** (SystemGraphView `site_deploy()`, ticked after
  the bridge): fires due events (toast + "tap to watch"), pins the picked
  crews as **ALL HANDS** (`NpcPopulationBridge.set_all_hands`: forced FULL
  tier after `CrowdFocus.decide`, ctx `all_hands` through `_make_ctx`, and
  in `NpcAgent._step_idle` the board beats every LEISURE block — a festival
  day is SOCIAL all afternoon and `_begin_social` always succeeds, so
  without this nobody ever reached the board), creates one project per item
  (kinds `site_deploy` / `site_packup`; `SiteProject.is_build_kind` /
  `is_breakdown_kind` drive the linkage ghost push), retries pending items
  every tick as boards free up, pushes a camp's live built fraction from
  the project rollup, releases the crews when all are done. A backward
  scrub past a fired event cancels its projects and puts every item back
  INSTANTLY (the fire's scrub rule, as far as a simulated crew allows);
  the chip's "Pack / Deploy everything now, no crew" does the same for
  setting up a before-state.
- **World reveal**: a packed prop with `build_state` that is not a linkage
  falls through to its REAL model, ghosted, with the kit crate beside it
  (`PlacedPropRuntime`, `packed_build`); the pack effect clears
  `build_state` + `build_run` (left on, the crate rendered as a ghost
  forever). `PalletRackBuildSite` gained LABOUR mode (progress × makespan,
  lanes only for people on site, NpcStandIns). Painted camps carry `built`
  (CampAreaLayer, default true); `CampAreaRuntime.set_built_fraction` hides
  household instances (`visible_instance_count`, prefix per class batch),
  their lights, and the shelters / shades / solids people use (entries carry
  `ix` / `n` in their batch), so a struck camp offers no beds and its people
  sleep on the ground until it is pitched.
- Caps raised: `SiteProjectStore.MAX_PROJECTS` 8 → 48 (one project per
  structure). Boards stay at 160 chores; the planner spreads items over the
  nearest crews and the rest wait.
- **Per-part staging (`gameplay/assembly_build_site.gd`, `AssemblyBuildSite`,
  second pass the same day).** Every non-linkage, non-rack prop a crew
  builds or packs gets a labour-mode site (`build_run = {mode: "labour",
  action, iid, project_id}`, attached by PlacedPropRuntime beside the
  generic ghost, which it hides while it owns the picture). It reads the
  project's PER-TASK fractions (`SiteProject.task_fractions`, carried by
  `linkage_build_status` as `tasks`) through the pure `stage_state`:
  deploy = `lay_out` lays the parts in a yard beside the crate, `assemble`
  seats them one at a time bottom up (`part_seat`); pack-up = `strip`
  takes them down to the yard, `pack` takes them into the crate. Two ways
  of cutting a structure into parts: the designer builders with an
  `assembly` build option (dome & zome, toroid, flat-pack) are REBUILT at a
  quantised fraction (`BUILDER_STEPS` 24, their own ring / part drop-in);
  everything else (a GLB, a gantry) is instantiated once through the shared
  `PlacedPropRuntime.model_extras` and SPLIT into its mesh instances (one
  mesh of several surfaces splits per surface), sorted bottom up, each part
  gliding from its yard spot to its seat with a lift. The real people on
  the chore stand at the prop in their work poses; the site draws no crew
  of its own.
- **One structure at a time**: the prop editor's "Crew: build" / "Crew:
  pack up" (every packable thing but a linkage, which keeps its own pair)
  go through `SiteDeployDirector.queue_item(kind, id, action)` — the same
  rows and staging, the nearest crew with board room, pinned ALL HANDS if
  it has no board yet, waiting under the record's `manual` stamp that the
  tick services like an event's. A pack-up near a cargo container (200 m)
  ends with the crate carried to its door (`item.loadout` → the `load_out`
  row; the linkage breakdown rows take the same).
- Polish: the Site Projects panel heads its list with the live deployment
  line, a progress bar and **Watch** (the settlement view over the busiest
  work site); the active flag's tag on the timeline fills with the crews'
  progress; the chip's no-crew actions ask first (ConfirmationDialog naming
  what they will swap).
- **No twin, no ghost (2026-10-27, Tool Camp 26).** The "full rack standing
  where they build it" was the PLAN crashing: a pitched roof's
  `ply:roof:i,j` sheets hit the deck pass (`bits[2]` out of bounds), the
  script error aborted the module, and 244 of 557 build units got no job —
  `_apply_units` never touched them, so they stood finished from frame one.
  `PalletRackBuildPlan` now splits a rack into `_plan_racking` (frames +
  beams, every joined rack in turn) and `_plan_fitout` (decks, the pitched
  roof — packing, rafters in fives, sheets in sixes — steps, walls,
  elements), and EVERY fit-out job waits for ALL the racking. Any new unit
  id family must land in a bucket there, or it will stand finished again
  (the selftest pins "every Tool Camp piece planned").
  Both staging sites (`PalletRackBuildSite`, `AssemblyBuildSite`) never show
  the prop's own model while it is `under_construction` (that model IS the
  ghost): suspended / finished / disposed fall back to the kit crate
  (`_show_model`), and the rack site holds its last frame until the prop
  is rebuilt for real. The rack site hides the KitCrate while its yard is
  out, plays a PACK-UP backwards (`(1 − progress) × makespan`), and moves
  its work loops off the clock's own steps when the clock is held but moving
  (the video export). Gate: `tools\harness.ps1 -World walton -RunScript
  res://tools/checks/tool_camp_build_video.gd -Label tool_camp_build`
  (`TCV_VIDEO=0` checks only; with the video it films a second rack into
  the user's Videos folder; `TCV_SPAN_H` 4.5 fits the build). ⚠ The
  project lives on ONE camp's board, so its roster is the crew: the
  sandbox's festival target (60 people = 2 a camp) made a 10 h build;
  the script resets the target to natural (1053 on Walton, crew 12,
  ~3 sim-h) and starts at noon (Walton's valley fog hides the morning).
  The rack site hides its progress label while the 🎬 export or preview
  holds the clock. Offline: `tools/diag/rack_build_order_diag.gd
  -- --preset=<id>` prints the job order and what is up at 0/10/…/100 %.
- **Every structure, piece by piece (2026-10-27).** A scheduled deploy or
  pack-up of ANY prop — dome / zome, toroid, Linkage Lab frame, gantry,
  flat-pack, a GLB — runs on the same crew site as a rack
  (`PalletRackBuildSite`; `is_schedule_run` = labour mode with an
  `action`, stamped by the director for every model with `crew_n`):
  - `StructureUnits` (`core/assembly/structure_units.gd`) cuts the REAL
    model into pieces: each MultiMesh instance (poses from the builder's
    `instance_transforms()` when it has one — the linkage builder; a
    headless MultiMesh keeps no transforms), each MeshInstance3D surface
    split into welded connected components; bits under `SMALL_M` ride with
    the nearest piece; > `MAX_UNITS` gathered on a grid; one surface per
    material (`_concat`, the 256-surface cap). Pile kind from the flat frame
    (frames / beams / sheets / parts), `stage` = 1.2 m height band × 4 +
    kind rank. Scale baked in, `ground_shift` = the lowest piece; the site
    stands at the ModelRoot's rotation + that shift (`_site_xf`). Cut cached
    by `look_key` (cost: 25–600 ms, the 216-plate corten zome 2.7 s, once).
  - `PalletRackBuildPlan.plan_units` schedules stage after stage, small
    bundles round the structure, carried and fitted one by one (`PIECE_*`
    tables); same timeline as the rack, no visitor.
  - A linkage frame is cut and built FOLDED (effective min fold); the
    finish unpacks it and the deploy sweep raises it. A linkage pack-up
    stows first (`_stow_then_stamp`, the stamp deferred a frame — stamping
    inside `deploy_state_changed` frees the emitting runtime: native crash).
  - The planner's rows lost their `set_build_phase` ghost stamps (only the
    finish unpacks, only the pack packs); the linkage rebuild / breakdown
    rows are the Lab / Site Projects path's now. The unpack effect KEEPS a
    schedule run so the finished prop's site draws the last pieces (they
    trail the labour), carrying the drawn time across the rebuild (`_carry`)
    and clearing the run itself when done (`_finish_run`). The read and the
    ease keep pace with the clock (`_speed`): at 1440× a 1.2 s ease left
    the last third of the pieces to pop.
  - `AssemblyBuildSite` is now only the fallback for an old per-part run.
  - Gates: `tools\harness.ps1 -World walton -RunScript
    res://tools/checks/structure_build_check.gd -Label structure_build`
    (deploy + pack-up of one of each, no ghost, monotone, all up / all
    down, shots); offline `tools/diag/structure_units_diag.gd [-- --only=x]`
    (every preset cut + planned, ms).
- **Pieces are the parts a crew handles (2026-10-27).** Connectivity alone
  cut the wrong pieces: a folded plate's flanges are separate meshes from
  its face, so a helical zome (plates, no struts or hubs) was planned as
  96 "struts" + 48 sheets; the toroid's canopy came apart triangle by
  triangle. Now:
  - Builders that know their parts draw them whole when asked: build
    option `pieces` (ModelCatalog forwards `extras.pieces`; StructureUnits
    always sets it) makes `DomeLabBuilder` / `ToroidLabBuilder` emit one
    MeshInstance3D per part, tagged by `StructureUnits.tag_piece(mi, kind,
    words, order)`: a strut, hub, rib length, slat, a plate WITH its
    flanges, a panel with its pane, a tube, a fitting, a solar panel, one
    bay's origami canopy fold (both halves' six triangles + flange +
    bolts). A tagged node is never split; its `kind` / `words` ("a plate")
    / `order` override the guesses, and stage = order × `ORDER_STRIDE` +
    band × 4 + rank, so a covering (dome panels, the toroid canopy at its
    builder stage 5, PV at 6) goes on after the frame. Bolts are their own
    small pieces and ride with the nearest plate. Each builder's one-mesh
    commit is now a static `_commit`. Overview toroid: 24 canopy panels + 24
    PV; helical_rd 24 plates; helical_corten 216 plates (cut 0.7 s, was 3 s).
  - A part that PACKS to another shape gives `tag_piece` a `packed` mesh
    (flat, thin along y, centred): a toroid canopy fold packs as its two
    flat cut pieces stacked (`ToroidLabBuilder._packed_canopy`, from
    ToroidLabCanopy's unfold, flange included — scored corrugated plastic
    folds flat), a bent flexible solar panel as a flat panel of its curve's
    length (`_packed_panel`). StructureUnits maps it into the piece's flat
    frame (vertex = basis · L + centre, so the yard's pose lays it flat),
    sets the flat `size` to the packed shape's (`packed: true`) and gives the
    unit node "Installed" + "Packed" children; PalletRackBuildSite shows
    "Packed" while g ≥ 0.5 (yard, carried, set down, first half of the fit).
    ⚠ `get_meta(key, null)` still errors on a missing key (null = no
    default): use `has_meta`.
  - Rack slopes: the end walls are 4x8 sheets stood on end
    (`_emit_end_wall_sheets`: the end's region in (out, height), minus the
    door, intersected with each sheet's rect — the top ones cut to the
    slope; ids `el:<id>:ends:<end>,<col>,<row>[,<k>]`, the door
    `el:<id>:ends:d<end>`), solid slabs (`_emit_slab_2d`). They were ONE
    zero-thickness quad per end with both ends one unit, which the yard
    could not lay flat and which rendered black from behind. The slope
    frame is its rafters (`el:<id>:frame:<k>`, `:top`, `:sill`), the bridge
    its ledger / rim / joists / posts / 4x8 cover sheets, a pitched roof's
    packing its blocks (`packing:<li>:<k>`). The planner puts an element up
    in `_el_stage` order — rafters + bridge, purlins, cover, ends — one
    chained job each (`EL_STAGE_WORDS`), so a strike runs the other way.
  - A pack-up's progress line reads the job in teardown words
    (`PalletRackBuildPlan.strike_label`: "raise and hold" → "lower",
    "carry X" → "carry X back to the yard" …). The site's drawn time starts
    at the first readable target (`_t_seeded`): eased up from 0, a pack-up
    re-played the whole build in its first second.
  - Measured in game (`tool_camp_build_video.gd`, now with a pack-up phase;
    `TCV_PACKUP=0` skips it): Tool Camp's fit-out is off AND back in the
    yard before the first beam or frame comes down. Selftest pins it, the
    slopes and the zome / toroid pieces (`pallet_rack_build_plan_selftest`,
    49). Stairs and ladders stay one prefab piece.
- **Crew builds of Linkage Lab structures (2026-10-27).** One crew system:
  the deploy schedule, the Lab's "Queue build for crew" (queue_item on the
  kit crate: nearest camp with board room, ALL HANDS) and the prop editor's
  "Rehearse build" (`PalletRackBuildSite.start_rehearsal`, crew default
  `LINKAGE_DEFAULT_CREW` 9) all run on `PalletRackBuildSite`.
  - **The centre bug.** The solver hangs the ring off module 0 at the
    origin, so the ring's middle sat off to one side and SWUNG as it folded:
    the crew's folded frame and the opened structure stood apart, and a
    deploy swung round module 0. `LinkageStructureBuilder.centre_fixed` (on
    for build_node = every placed structure, and the construction ghost; off
    in the Lab studio, which centres itself) slides each pose so the ring's
    plan middle (`plan_centre_of`: the beams' corners) stays where it is at
    the DEPLOYED (closed) angle: `_shift`, `frame_offset()` (= slide +
    grounding; every transform, instance_transforms, collision, walls,
    frame_aabb add it; the step player uses frame_offset()). A deployed
    structure is exactly where it always was.
  - **Built part-open.** `crew_pose_angle(p)` = stowed + `CREW_POSE_FRAC`
    0.45 of the way to deployed (the Lab's build pose): folded flat a
    StarShade is a 2.5 x 1.1 x 0.35 m bundle that does not read as a ring.
    StructureUnits cuts there; a crew build's unpack opens from there
    (terrain_loader's unpack, when the record carries a build_run); a
    pack-up folds there first (`LinkageDeployRuntime.fold_to`, the
    director's `_stow_then_stamp`); a rehearsal opens from there over
    `LINKAGE_DEPLOY_S` 120 build-seconds after the last piece, on the real
    structure (`_drive_fold`; scrubbing back folds it again; dispose / the
    end land it at the placed pose).
  - **The Lab's step order.** `instance_piece_info()` gives each MultiMesh
    instance an order + words from its part key (`piece_info_for_key`):
    bottom ring, V modules (+ their brackets and bolts), top ring, supports,
    floor, panels, coverings (wall nodes are `tag_piece`d); radial copies
    one after another.
  - **Speed.** `set_fold_angle` cost on Constellation was ~19 ms a step
    (radial copies 9 ms: `deployed_plan` hashed a JSON dump of the config on
    every call; coverings 3.7 ms, parity-pinned JS port, left as is). Now:
    the deployed plan and the design key are per rebuild (`_design_key`),
    the other angles' copies cached (`_geo_cache`), ~14 ms. Sweeps of heavy
    designs re-solve at most ~13x a second (`fold_cost_ms`;
    LinkageDeployRuntime `HEAVY_FOLD_MS` / `FOLD_GAP_PER_MS` /
    `MAX_FOLD_GAP_S`, the site's `_drive_fold` alike) while the angle keeps
    time. The site's own cost is the `build_site` PerfSpan: ~2.6 ms a frame
    at 115x on a StarShade, ~4.4 ms at 369x on Constellation (Walton's
    world alone was ~55-60 ms median there).
  - The bridge's ghost push stands down for any build site that owns the
    visuals (`PalletRackBuildSite.NODE_NAME`).
- **Toroid centre posts**: the straight uprights beside the inner-wall arcs
  are `ribs.inner_posts` ("Straight centre posts" under Tube and ribs in the
  Lab). The reference GLB draws them, the real build has none: off in the
  overview preset and the spec default (the selftest counts the GLB's
  fittings on a posted copy). A placed toroid keeps the value it was saved
  with.
- Not built: per-camp schedules, the light tier working (only pinned full
  camps do), a tour stop, the gantry's own assembly order (it splits by
  mesh like a GLB).

## NPC realism pass — spacing, sliding, moving between spaces (2026-10-25)

Plan: `plans/NPC_REALISM_PASS.md`. The report: "people go to exactly the same
place; at speed they slide around, even lying down; they should avoid each
other and stand at a realistic distance." Measured FIRST with
`tools/diag/npc_spacing_probe.gd` (Validation list): the full tier never
stacked (the separation pass works); the light tier put 39 pairs on one spot
on the festival day and **15 158 on the default day**. Both tiers read
"< 0.3 m: 0" now. What it was, and the rules that carry the fix:
- **The light tier's LANE OFFSET moved the GOAL.** `CrowdCohort._go` added
  the per-person ±0.8 m lane to the destination; standing slots are 0.855 m
  apart, so two lanes meeting at the goal cancelled the spacing (kitchen,
  shower, water point). The lane is for the WALK: a straight walk now takes
  it to `LANE_MERGE_M` (4 m) short of the goal and converges on the exact
  spot (a two-leg `legs[i]`); a routed walk takes no extra lane (the route
  cache's own lanes — NpcNavQuery — already end on the goal).
- **Idlers hung about ON the slot they had just used** (12 207 pairs on the
  default day: "nothing to do → dawdle where we are", while the released
  slot went to the next thirsty person). Both tiers now STEP ASIDE: within
  `LOITER_NEAR_M` (6 m) of the space's centre they walk to a spot
  `LOITER_MIN_M`..`+LOITER_SPREAD_M` (5–8 m) out, hashed per person and
  quarter hour, and hang out there. Light: `CrowdCohort._loiter_spot` (turns
  the spot a golden-angle step at a time until it is clear of every standing
  person — this tier has no separation pass, so the spot must be clear when
  chosen) → `_go(... A_FREE)`; the dawdle's `end_h` (the first need
  crossing) still ends it, no heartbeats. Full: `NpcAgent.LOITER_ACTIVITY`
  ("loiter", in ACTIVITIES, consumes nothing; `_maybe_loiter` at the END of
  `_step_idle`; any need past its THRESHOLD ends it, like the light tier's
  FREE bar; status "stepping aside" / "hanging out"). Never after sleep
  (waking in one's own bed) or after a loiter (`_loiter_ok`).
  - ⚠ **Its duration is HASHED, never `rng.randf_range`**: a draw there moved
    the RNG stream for everything after, and the separation-neutrality pin
    read 3 % of water from it.
  - ⚠ The engine gained a `separation` ctx switch (through `_make_ctx`).
    `npc_population_selftest._consumption_over_a_day` used to disable the
    pass by pinning `walkable` to false — which also refused every loiter
    walk, so the two runs no longer did the same thing (5 % water).
  - `NpcAgent.loiter_enabled` (static) is the diagnostics switch.
- **Sleepers in a bare sleep AREA lie in rows** (`SpaceRegistry.
  lying_offset_for_index`: 1.1 m across × 2.4 m along, one yaw per space
  from `lying_yaw_for(space_id)`), not 0.9 m apart on the standing spiral at
  random yaws. Full tier only — the light tier sleeps at its home slots.
- **Furniture seats that wrap** (`NpcPopulationBridge.seat_spot`, slot k ≥
  the seat count) now STAND behind the seat's owner (kind "stand", no elev)
  instead of landing on the identical cushion.
- **Friend-group clusters in a mingle circle** take sunflower cluster slots
  by RANK among the camp's groups sharing that circle this bucket
  (`NpcSocial.cluster_rank`, `GROUP_INNER_M` 2.6 + `GROUP_SEAT_M` 2.4·√rank,
  a per-bucket rotation) instead of independent hashed points 1.2–3.8 m out
  that stacked two groups. The rank needs the camp's headcount: the cohort
  passes `_n`, the engine puts `camp_n` in `_make_ctx`; `NpcFriends.group_of`
  now returns `g`, plus `group_key` / `group_count`.
- **"They slide around, even lying down"** had three faces, all rendering:
  (1) `NpcPopulationHost._pose_avatar` in interp mode tracks a MOVING point,
  so `gap` was small, `catching_up` never fired, and the pose machine got
  `in_transit = false` while the body still glided prev→next — a person who
  reached bed inside one tick lay down for the glide. `on_segment` (f < 1)
  is now part of `in_transit` (dancers, ravers and fire-flow performers
  excepted — they move in their own pose). (2) The full-tier OVERFLOW
  figures glide to each tick position with the dot's SETTLED pose, on the
  GPU. (3) An eased segment (late event, tier switch, hand-off) slid a lying
  figure. `crowd_figure.gdshader`: a STATIC pose on a segment over 2 m with
  u < 1 draws as a WALK facing the segment heading (the YAW_FIXED facing
  only survives on short shuffles); dance / rave / sway / peak / DJ /
  fire-flow keep their pose while moving.
- **The equivalence pin is the LAST DAY'S AVERAGE morale**, not the value at
  the final instant (08:00 on a waking camp). Changing only the loiter
  spot's hash salt moved the light tier's end value 0.795 ↔ 0.815 while the
  day average stayed within 0.01; the instantaneous 0.08 pin was already at
  0.074 before this pass. `tools/diag/npc_tier_morale_diag.gd` prints both.
- Not done: a light-tier per-pair avoidance while walking (positions are
  segments, not ticks — walkers passing through each other measured 0–1 per
  two days); the light tier sleeping at `home` while the full tier sleeps at
  a tagged shelterless area.

## NPC festival refinement pass (2026-10-07)

Plan: `~/.claude/plans/the-npc-festival-system-humble-brooks.md`. Five
contracts landed together; each has a trap that will come back.

**Cosmetic motion follows the sim clock (`SimFxRate`, core/sim_fx_rate.gd).**
Fire flicker + particles, crowd-figure loops, LED chases / mover sweeps and
NPC clip playback all run on ONE curve: `rate = 0` while paused or scrubbing
backwards (`SimFxRate.is_paused` is THE pause query — five disagreeing tests
existed), linear slow-motion below 1x, `sqrt(multiple)` above, capped per
system (`FX_CAP_NPC` 12 == `NpcRig.MAX_PLAYBACK_RATE`, fire 6, lights 8).
Time-lapsed on purpose but never 1:1 (the user's call: speed should READ,
not strobe). The clocks INTEGRATE delta x rate — multiplying TIME by a new
rate teleports every phase — and Main pushes them once per frame as global
shader uniforms `fx_time_npc/_fire/_lights`, DECLARED in project.godot
`[shader_globals]` (never `global_shader_parameter_add` at runtime: the list
query is editor-only and the add errors). Shaders on it: crowd_figure,
fire_char, fire_pile, light_beam, camp_glow. `PlacedLightClock` is now the
lights track; `fx_pause_with_sim` is retired (key kept for old files).
`CrisisEventManager` no longer hides fires off-realtime — that path was
undone by FireNode the next frame and left `fire_light` dark forever.

**Effigy pre-roll + perimeter.** `FireTimeline` gained `preroll_h` (ignition
-> first flame; absent = 0, so old records are unchanged; a tagged EFFIGY
defaults to `PREROLL_H` 0.25 via `FireNode.default_preroll_for_prop`).
`burn_hours` counts from the first flame; `state_at` reports phase NONE +
`preroll`/`flame_in_h` inside the window, and a record put out during the
pre-roll is idle. `VenueCrowd.effigy_phase` maps the pre-roll to BURNING at
the BURNING radius — that is the whole mechanism: the ring forms, the nav
perimeter is stamped and bystanders are evacuated (`evacuate_from` in both
tiers, a straight radial walk to `safe_r + 2`) at IGNITION, not at the first
flame. The idle spiral now starts OUTSIDE the safe radius (it used to sit at
0.8 of it), the idle radius IS the burning one, and an unlit effigy's size
comes from its pick AABB (`_effigy_size`). Late arrivals re-seat
(`CrowdCohort._begin_activity` compares the phase they left for; the full
tier re-targets mid-walk in `_retarget_effigy`). The perimeter is its own
nav bit `F_FIRE` (`NpcNavGrid.BLOCKING`): stamping/clearing `F_BLOCKED`
wiped real obstacles inside the circle. Prop editor: "Pre-roll (min)".

**Festival population target (`PopTestPrefs.festival_target_people`, 0 =
natural; festival HUD slider + Settings -> NPCs).** Global, not per site — it
is a performance knob. Camp headcounts are NEVER rewritten: the loader's
graph sync scales the copy it hands over (`_apply_population_target` ->
`FestivalSeedLayout.scale_headcounts`, largest remainder, floor 2), so 0
restores everything. Rosters resize IN PLACE (`CrowdCohort.resize`,
`NpcPopulationEngine.resize`) — survivors keep position, needs and morale.
Stores are not re-sized (festival mode runs on ideal supply).

**Festival leisure is SOCIAL, not FREE (`NpcSocial`).** FREE only reached a
venue past the enrichment threshold (1/30 per hour, reset per visit), so
~80 % of a festival stood where it had last eaten from 11:00 to 18:00 —
measured. `NpcRoutine.SOCIAL` ("Hanging out") always does something, chosen
per person per HOUR by hash: a venue without the gate, a stint in one of the
camp's conversation circles (activity `mingle`, zero consumption, eases
enrichment by 0.4, crowd pose `POSE_TALK` 8 / simple-figure "talk" flavour),
or a wander 30-120 m out. Both tiers make the identical choice (ctx keys
`camp_home`/`camp_seed` forwarded through the `_make_ctx` whitelist). Old
saves migrate: `NpcRoutine.from_array` recognises the exact legacy festival
shape and retypes its two FREE blocks. Also landed with it: a festival day
serves each EAT / BATHROOM / WASH block ONCE (`serves_once`, any routine with
a SOCIAL block) — re-issuing meals gave ~5 a day and split the tiers' food
bills — and the WAKE hour follows the routine (`wake_base_h` = SLEEP end - 2
h: 06:00 default, 07:30 festival; it was a fixed 06:00, so festival-goers
slept four hours). The festival-day equivalence pin is honest and LOOSER
(15 % / 0.15 morale, measured ~8-12 %) than the default-day 6 % / 0.08 —
it was never pinned and was already 10 % / 0.106 apart before this pass.
Art pieces are seeded (3-8, draw 0.55) so afternoons have destinations.

**Performance at festival speeds.** The cliff at 350-450x was tick frames:
the flow engine gates the ambient tick (0.5 s at >= 450x) and every camp,
persist and bake landed in that one frame. Now: light camps are SLICED
across frames (`NpcPopulationBridge._drain_light_queue`, 2.5 ms budget,
leftovers forced at the next tick; the challenge bake's direct `tick_at`
never defers) — ⚠ the per-frame slice MUST run inside the view's history-
suppress / bulk window, or every persisted snapshot records undo history and
refreshes the canvas (28 ms a frame, measured); persistence is jittered per
camp with a per-tick budget of 4; the nav bake and the crowd height raster
are TIME-budgeted per frame (the raster was 36 ms frames, the nav bake ~4.4
minutes at 450x); the route cache is LRU at 4096 with per-route cached
lanes and a keyed-miss budget; `spaces_of_type` no longer copies; beds and
the SolarUI lookup are cached; the host reads full-tier dots only; desire
textures build only while an overlay is on; `CrowdFocus` shrinks the full
tier with the clock (150 / 90 / 40 / 16 at 60 / 300 / 1000 / beyond, only
past `MAX_FULL_PEOPLE`) and the hero pool with it (24 at 300x, 12 at 1000x,
festival scale only); separation is off at 120x+. PerfMonitor shows a 2 s
PEAK per section (the EMA hid tick spikes), and `--capture=crowdbench`
takes `--ts=<multiple>` and prints peaks. Walton, ~1255 people at 450x:
frame 45.7 -> 40 ms, frame peak 138 -> 116 ms, population peak 51 -> 26 ms;
what is left is GPU (~28 ms — the scene, not the crowd).

## NPC social + weather pass (2026-10-07, after the refinement pass)

Friend groups, gatherings, glow sticks, weather attractors, the firepit prop,
the DJ and venue layouts. Every behaviour is a HASH both tiers ask
identically, so the light/full equivalence pins still hold
(`crowd_cohort_selftest`, `venue_crowd_selftest`).

- **Friend groups (`NpcFriends`, pure).** A camp's index line ("<seed>_npc_<i>")
  is cut into consecutive groups of 1-5 with hashed sizes. The GROUP key, not
  the person, drives the hourly SOCIAL choice, the circle, the wander target,
  stint lengths, the evening venue's TASTE (`taste_for(group key)`, both
  tiers) and the comfort responses — needs stay personal. A group in a camp
  circle holds its own F-formation (`formation_offset`); at an ordinary ROUND
  venue `VenueCrowd.group_spot` replaces the registry's arrival-order spiral
  (conversation types face the cluster, art/fire face the venue). Live
  choreography (ring, fan, circle) is untouched.
- **Shared moments.** `effigy_phase.cheer` = the last `CHEER_LEAD_H` before
  the collapse; `NpcVenueState` stage `peak` = a set's last `PEAK_H`. Both are
  folded into the bridge's venue phase KEY, so the light tier is re-posed by
  `wake_at_venue` the moment they begin (the evacuation trigger compares the
  PHASE field only — a cheer must not re-run it). Pose `cheer`
  (crowd POSE_CHEER 9, simple-figure flavour "cheer", rigged = dance).
- **Glow sticks.** Global uniform `npc_night` (project.godot, pushed by Main
  from `DaylightModel.night_amount`, change-gated). One carrier rule +
  six-colour palette keyed on `NpcHash.unit01(id, "pose")` in THREE places
  that must agree: crowd_figure (bands picked on the REST pose by UV2 part /
  limb fraction / height — tested PER FRAGMENT on interpolated varyings: the
  capsules have no vertex ring inside a 7 cm band, so the first, per-vertex
  version tagged nothing and drew no band at all), crowd_card (a far person's dot glows), and
  `NpcSimpleFigure.glow_for` (torus rings under `npc_glow.gdshader`, an
  instance uniform colour). Not on the rigged Mixamo body.
- **Weather attractors (`NpcComfort`, pure).** `pulls(weather, hour)` ->
  {heat (hot AND sunny: GHI from WeatherService `shortwave_radiation`), cold
  (night only), rain (met classes: light < 2.5 mm/h pulls nobody; heavy
  > 7.6 nearly everyone)}. A pull is a SHARE: each friend group draws one hash
  per hour (`respond`). Only LEISURE blocks (SOCIAL / FREE / ENRICHMENT) and
  never during an EVENT; the cold pulls half as hard in the evening's
  ENRICHMENT block (a cold night must not empty the stage). The stint reuses
  the mingle activity (`_comfort` / cohort `ckind`), so consumption is
  untouched. Spots come from the bridge (`comfort_spot` ctx callable): shade =
  camp `CampStyles.SHADE_CLASSES` + StarShade / EZ-up / carport / deployed
  linkage props + "shade" spaces (`TerrainLoader.shade_footprints`); warmth =
  LIT firepits + fire circles; one of the 4 nearest to the camp by group hash,
  in a 100 m grid. Shelter goes to a tarp or (a share) the person's own bed
  (`home_bed_of`, engines only — it must be in `_make_ctx`). Hard rain's
  ONSET wakes ordinary leisure in both tiers (`wake_for_weather`). Harness /
  testing: `bridge.comfort_override`.
- **Firepit prop (`FirepitBuilder` + `FirepitFire`).** Procedural (primitive
  meshes — no winding traps), category structures, PackedSpec curated.
  Placing one auto-tags a fire circle (`PlacedPropService._auto_tag_space`).
  `FirepitBuilder.lit_for(rec, env_now(main))` is the ONE rule the fire node
  and the bridge both ask (`firepit_mode` auto/on/off, `firepit_below_c`
  default 15 °C; auto = night and colder, unknown temperature counts as cold).
  An unlit pit's fire circle draws `UNLIT_PIT_DRAW` of its crowd; a lit one
  adds cold x `WARM_PIT_PULL` (never an EVENT). Flames/sparks/light run on the
  FIRE cosmetic clock. Prop editor: a "Firepit" section, record-only (no
  rebuild — the fire re-reads the live record each second).
- **Venue layouts.** Record keys `layout` ("" by type / "ring" /
  "directional") and `perform_h_m`, alongside `facing_deg`. ANY venue can face
  one way: the bridge now writes `_venue_fronts` for every venue ({layout, r,
  front, fwd}; footprint from the prop's pick AABB), both tiers' `_venue_extra`
  read it for every type. A directional venue's crowd stands in the fan in
  front of it whether or not a set is on; a stage turned "ring" rings outside
  its footprint. Editor: `NpcSpaceTagRow` (now a VBox) has a venue line —
  Crowd by type / around it / facing one way, a compass spin, "Toward me"
  (points it at the camera), the DJ deck height (Auto = measured) — and draws
  an amber facing arrow on the ground while open.
- **The DJ.** `_service_djs`: for every stage with a set on or starting within
  `DJ_LEAD_H`, one person per SET (the lowest `NpcHash(id, "<sid>|<set start>")`
  over everyone on site) is cast via `CrowdCohort.perform` /
  `NpcPopulationEngine.perform` -> walks to the middle of the footprint and
  plays until the set ends, `elev` m up, facing the speakers' way. Re-cast at
  most every `DJ_RECAST_H` (a toilet run is not interrupted). Deck height:
  `perform_h_m`, else `_deck_height` — the lowest horizontal mesh surface over
  the footprint's middle 0.25-2.6 m up, taking that slab's top (meshes whose
  bounds miss are skipped). Elevation reaches the renderers as a NEGATIVE
  `flags` in the crowd slot (`>= 1` stays hidden) and as the dot's `elev`
  (host adds it to the ground height, including the drawn-position resample).
  One set's DJ steps down when a new one is cast (`end_perform`).
  Festival mode gives a player's stage with NO programme the evening set
  (slot label prefixed, so Clear removes it). Verify with the venue part of
  `--capture=festivalmode` (DJ on each live stage, the prop stage's DJ 0.4-2 m
  up, the firepit lit and tagged, shade/rain/warmth shares via the override).

- **No goal inside a fire perimeter (`NpcNav.outside`).** Found when the
  Walton RINSE stage got a set: it faces the effigy 31 m away and its fan
  spilled into the 11 m fall zone. Every walk goal in both tiers (cohort
  `_go`, agent `_request_path`), a live venue's per-step re-seat
  (`_update_live_venue`) and a light-tier ARRIVAL (`_begin_activity` steps out
  first) is pushed to just outside any no-go circle; effigy seats are exempt
  (already outside by construction). Evacuation at ignition now includes
  SLEEPERS — a tent inside the fall zone is slept beside, outside it, until
  the fire is out.
- **Shared space-pair routes have private ends.** `NpcNavQuery` caches one
  route per (from space, to space) — planned from the FIRST walker's start to
  THEIR goal. Two traps, both fixed in both tiers: (1) a re-seat at the venue
  you are already at (effigy ring -> circle lane) got the camp->venue route
  and walked back to camp straight across the fire — a route whose start is
  farther away than the goal is now discarded; (2) the joining legs (your
  start -> route start, route end -> your seat) now go round any fire via
  `NpcNav.detour`.

## Peak Experience — "FUCK YES!" (2026-10-08)

The body GLOW is how a person's good time reads; the overhead morale bar is
hidden by default (`NpcDisplayPrefs.mood_bars`, Settings -> NPCs), glow sticks
are WRISTBANDS only. Plan: `~/.claude/plans/the-npc-festival-system-humble-brooks.md`.

- **Rules (`NpcPeak`, pure).** A person is VIBING when DOING something social
  (a venue, the DJ set, a chat / shade / fireside hang — not sheltering, not
  in a tent), every critical need under its threshold, nothing blocked, morale
  >= 0.72. The onset RATE per hour is `BASE_RATE_H x mass(n) x (1 + CONTAGION
  x contagion_mult x peakers) x venue boost`, n = other vibing people in the
  person's 3x3 block of 6 m cells (mass 0 below 5, full at 20 — a chat circle
  never gets there, a stage crowd does), peakers capped at 8, boosts for a live
  set / its closer / the burn. `contagion_mult` is the player's
  (`PopTestPrefs.peak_contagion`, 0 = no spread .. 4; Settings -> NPCs and the
  festival HUD). The rate fills a CHARGE (`PeakField.charge`, integrated
  exactly: dt-exact and deterministic) toward a per-person threshold drawn from
  Exp(1) by hash per episode (`NpcPeak.threshold`) — statistically the same
  Poisson onset as a per-tick draw, but "how close" is now a number:
  `buzz = charge / threshold`. Charge leaks (`CHARGE_LEAK_H`) while the rate is
  zero; `fed` records who has peakers feeding them. A peak holds while
  vibing with >= 2 others, MIN_HOLD_H 0.05, and survives GRACE_H 0.1 of lapse
  (walking back to the same stage between visits); it lifts morale toward 0.95.
- **Authority: `PeakField` in the bridge**, never a tier — `_service_peaks`
  (after the camps tick) collects `peak_inputs` (packed arrays) from light
  cohorts and full engines, counts cells (no pair distances), pushes
  `cohort.set_peak` / `agent.peak_since` (transient) and the morale lift back.
  A scrub back freezes; a >6 h jump clears every peak without scoring. The
  score `{total, by_day, best}` only grows and is saved per map,
  `user://maps/peak_experience_<lat>_<lon>.json` (4 s debounce). ⚠ Harnesses
  must snapshot/restore it — `--capture=festivalmode` does — or test onsets
  land on the player's score.
- **The glow contract.** Light tier: instance `COLOR.a` = `NpcPeak.pack_mood`:
  not peaking = buzz in 31 steps in the integer part + morale x 0.999 in the
  fraction (< 32); peaking = 64 + peak start in sim hours relative to the
  renderer's time_base (62..89). crowd_figure / crowd_card unpack with the SAME
  numbers (`a >= 48` is a peak). There is NO mood glow any more (user call,
  2026-10-08: a "Fuck Maybe" person is a BLACK figure; the linear morale glow
  lit half the crowd and by day read as flat green). BUZZ = a green OUTLINE
  only, through `glow_ramp(buzz)` = smoothstep(0.35, 1, b)^3 in all three
  shaders (nothing below ~35 %, a hint at 60 %, clearly lit at 80 %), beating
  double-time to the peak pulse and sparkling past 0.85 — the body turns green
  ONLY at the peak. By DAY (`npc_night` ~0) a peaker is a dark body with a
  strong green outline and a faint fill; the solid green body is night only.
  The light-tier figures can be switched off (`NpcDisplayPrefs.light_crowd`,
  Settings -> NPCs): the LIGHT slots hide (the full-tier overflow still draws) and the Auto hero budget rises to
  `HERO_MAX_NO_CROWD` 64. Peak = solid green (at night), ramped in
  over 0.012 sim-h with an ignition flash, then a breathing pulse on ONE shared
  phase (no per-person seed) so a peaking crowd breathes together and the
  people catching it shimmer in time with them. Full tier:
  `npc_silhouette.gdshader` `mood` / `buzz` / `peak` / `peak_flash`, eased by
  `NpcAvatar.set_mood(morale, since, buzz, fed)`; over the head a thin green
  meter + "64 %  ↑ 3 peaking near" (`_buzz_track/_buzz_fill/_buzz_lbl`, kept
  out of the mood-bar toggle by identity).
- **The peak dance.** A peaker on their feet at a venue or a hang (enrichment
  / mingle, not sitting, lying, the DJ or a shared cheer) dances the SAMBA:
  `NpcPoseMachine` input `peaking` -> `NpcRig.CLIP_PEAK_DANCE`, sourced from
  `Imported Models/NPC/Samba Dancing.fbx` via `NpcRig.RETARGET_SOURCES` (a
  `mixamorig:` export: prefix-retargeted, bind-ratio checked, hip track scaled
  to the pack's standing height by the first frame — the source rig's hips
  sit at 0.096 of its units). `_clip_file_for` hands the rigged body the plain
  dance when the file is missing; `NpcSimpleFigure._pose_samba` (feet working,
  hips + twist, forearms rolling at chest height) and crowd `POSE_PEAK` 11 draw
  their own (`CrowdCohort.pose_code` / the host's `_crowd_pose_for` apply the
  same rule).
- **Personal space: STABLE SLOTS (`SpaceRegistry`).** A slot is the LOWEST
  free index, taken at claim (or earlier by `reserve_slot`) and kept for the
  visit; one per person (`_slot_at`). It replaced two bugs that piled people
  up: the light tier used `occupant_count` at DECISION time (it claims on
  arrival), so everyone who set off for the stage in the same tick got the
  same slot and walked onto one spot — the "pile" round a peak; and the full
  tier's `array.find` index shifted everyone behind a leaver. Friend groups get
  a lowest-free CLUSTER per space (`cluster_index_for`; the hashed one of 48
  stacked groups by the birthday problem). The stage fan packs at ~1.1 m
  nearest neighbour (`STAGE_SEAT_M` 0.62, jitter 0.3).
- **Crowd distance.** A venue's `crowd_gap_m` (< 0 = `STAGE_FAN_GAP_M` 1.5 m;
  Ctrl-focus row "Crowd distance", with a green ground line where the front
  row stands) is how far the fan's apex sits off the front edge, or a round
  stage's ring off its footprint. The fan's bearing is `fract(k x phi)` over
  the span — folding the golden ANGLE onto 130 deg stepped seats 7.5 deg
  apart and drew two spiral arms.
- **SLEEP IS EXEMPT from personal space — people pile up to sleep.** The
  full tier's `_separate` pass skips anyone DOING sleep (both ways): two people
  sharing a tent are closer than PERSONAL_SPACE_M and the push walked them
  out onto the ground (it ran whenever the clock was under 120x). A sleep
  space never refuses (`has_free_capacity` is true for type `sleep`; an
  assigned bed is still the assignment's). Sleepers search for a sleep space
  from `camp_home`, with NO crowding charge (`nearest_space_by(..., spread
  = false)`) — the 12 m-per-occupant charge sent a full camp's people to bed in
  the neighbours' camp or on bare ground. More sleepers than beds pile in beside
  a bed's owner (`SpaceRegistry.pile_offset`, both tiers).
- **A fire is gathered ROUND — heat draws people, they chat, and sway when a
  stage's music carries** (2026-10-08, replacing the turning dance ring). The
  ring of seats is unchanged (`fire_ring_slot`) but STILL: `is_circling` is
  false for `fire_circle` (the `moving` option survives, no caller asks for
  it). Poses (`VenueCrowd.venue_pose`): lit = `FIRE_TALK_SHARE` 60 % talk, the
  rest sit; lit with `music_near` = `FIRE_SWAY_SHARE` 70 % `POSE_SWAY` (a
  LIGHT dance on the spot — crowd shader `POSE_SWAY` 18, stick-figure flavour
  "sway" / `_pose_sway`, cohort `VPOSE_SWAY` 16 APPENDED to `VPOSE_NAMES`, the
  rigged body's dance clip), the rest talk; cold = sit / talk as before.
  `music_near` is stamped by the bridge (`_stamp_fire_music`) when a lit fire
  is within `MUSIC_EARSHOT_M` 180 m of a playing stage's speakers (its front
  edge) or any venue playing its own track; a change re-poses the light tier
  (`_fire_keys`, and `_phase_code` folds music in as +200). HEAT: every
  burning fire circle (not only firepits) gets `pull +=
  NpcComfort.fire_warmth(temp, night) × FIRE_HEAT_PULL` 0.8 —
  0 above 22 °C by day, ramping to full at 4 °C, with a `FIRE_NIGHT_BASE` 0.25
  after dark however mild; `pulls()` carries it as `warmth` (kept apart from
  the night-only comfort `cold`, which the selftests pin). Comfort stints at a
  warm spot now sit or TALK (was stand). Also fixed: the pose machine had no
  `POSE_TALK` case for enrichment, so full-tier talkers round a cold pit DANCED
  while the light tier drew them talking. Pinned in `venue_crowd_selftest`'s
  `_test_fire_ring`. The text below is the history of the turning ring.
- **(History) A fire was danced AROUND** (`fire_circle` is a LIVE venue type):
  `VenueCrowd.fire_ring_slot` — rings from `round_gap` (FIRE_RING_GAP_M 1.2 m,
  or the venue's crowd distance) off the pit, seats ~0.95 m apart, turning
  counter-clockwise (one lap per FIRE_LAP_H 0.12 h, outer rings slower) while
  `fire_lit(state)` (a firepit's lit state from the bridge; anything else counts
  as lit), standing still and talking round a cold pit. Full tier: re-seated
  every step by `_update_live_venue`; light tier: `S_CIRCLE` arcs through the
  same `_circle_step` as the effigy (`VenueCrowd.is_circling` replaced the
  effigy-only test; a NON-event circle ends when the visit does — the effigy's
  circle is an event and holds people, a fire's must not). Fire dancers stay
  wakeable for hard rain and the burn (`wake_for_weather` / `wake_for_event`
  include them though they are "live"). Two traps, both measured by
  `crowd_cohort_selftest`'s tier equivalence: (1) the seat MOVES, so anyone
  already at their ring's radius JOINS / goes round with it in both tiers —
  chasing it (the effigy late-arrival rule, the full tier's RESEAT_WALK_M walk)
  never arrives, and a walking full-tier agent skips the end-of-visit check:
  the fire's dancers never went to bed; (2) a light-tier fire visit gets the
  ordinary enrichment length on arrival — the live branch of `_begin_activity`
  returns before the duration is set, so it lasted the whole routine block
  and people went to bed parched (sleep is never interrupted; morale 0.45 vs
  0.90). Circle steps round a fire are FIRE_LAP_H / 16. Before this a fire circle used the
  friend-group clusters, and once clusters were lowest-free the first group
  stood ON the pit; clusters now start `GROUP_CLEAR_M` past `round_gap`.
- **Peak ripples** (`core/population/peak_ripple_fx.gd` + `peak_ripple.gdshader`,
  Main's `PeakRippleFx`): every onset sends a green ring out across the ground to
  the contagion's reach (1.5 cells), scaled by the contagion setting. Reads the
  bridge's NON-consuming `peak_events_since(serial)` (PeakField `_log` /
  `serial`) — the toast drains a different list; on the NPC cosmetic clock.
  The score chip adds "⚡ N close" (`peak_building(0.5)`). The Ctrl-focus row
  draws a green RING at a round venue's front row (`VenueCrowd.front_ring_r`),
  the line at a directional one.
- **Fun Meter (`scenes/ui/fun_meter.gd`, UILayer `FunMeter`).** The crowd's
  overall vibe as a half-dial needle gauge: the six NpcMorale bands in their
  colours across the first `ZONE_FY` 0.86 of the arc (each band as wide as its
  morale range), then the FUCK YES zone. `needle_for(mean, peak_share)` =
  lerp(mean x ZONE_FY, 1, min(share / 0.25, 1)) — mood alone never reaches
  the zone; a quarter of the crowd peaking pins it. Damped-spring needle,
  shiver while people peak, zone pulses. Data: `festival_vibe()` else
  FestivalVibe over the bridge's `vibe_summaries()` (tier-aware: a light
  camp's PARKED engine is stale). Draggable, position + on/off in
  NpcDisplayPrefs (`fun_meter`, `fun_meter_pos`).
- **Peak beacons (`core/population/peak_beacon.gd` + `.gdshader`, Main's
  `PeakBeacon`).** Each toast pings it with its events: a green light column
  over the headline peaker for 9 s (width/height grow with camera distance —
  slim up close, a tower from the settlement view), a ring at its foot, a name
  + distance tag, and an EDGE ARROW when the spot is off-screen or behind.
  Real time; ≤3 at once; toasts off still ping (folded to 2 s).
  `NpcDisplayPrefs.peak_beacons`. In the settlement view the toast is
  clickable ("click to look" -> `SettlementView.look_at_person`), and only
  there does it take the mouse.
- **Venue music (`StageMusic`, core/population/stage_music.gd, Main's
  `StageMusic`).** A venue record's `music` names a file in `user://stage_audio/`
  (the player's tracks live in user data, never the repo — licences are
  theirs); the Ctrl-focus row's "Music" picker lists that folder and "Add
  file…" copies one in. One AudioStreamPlayer3D per venue at the speakers
  (the bridge's front edge, deck + 2 m, `-Z` = facing so the emission cone
  muffles it behind the stage), inverse-distance (full inside 14 m, gone by
  520 m) with the highs rolled off over distance. `should_play` (pure): a stage
  while a SET is on, a fire circle while lit, other venues while open; resolves
  the venue state itself when there is no population. Fades 2 s, restarts at a
  set's start, loops, pauses with the sim. Loaded with
  `AudioStreamMP3/OggVorbis/WAV.load_from_file` (no import). Volume:
  `NpcDisplayPrefs.stage_music_volume` (Settings -> NPCs, 0 = off).
- **Activity pass (2026-10-08, "too much standing around").** Measured with
  a one-day pose census (light + full tier, festival_day, a typical site),
  HEAD vs working tree — the SIM was already busier than the last commit
  (light STAND 41 % -> 12 %, full IDLE 27 % -> 5 %); what remained was LOOK
  and two schedule holes, both mirrored in the two tiers: (1) before the sleep
  window opens the sleep NEED alone sent people to bed at its ordinary
  threshold — a festival-goer up since 08:00 crosses it ~21:00, so 46 % of the
  crowd slept through the set; a festival routine now needs exhaustion
  (`NpcRoutine.early_bed_bar` = FESTIVAL_LATE_BED_BAR 0.97) -> 15 % asleep,
  50-61 % dancing 21-24h; (2) awake inside a festival SLEEP block (woke 07:30,
  block to 09:30) people dawdled by their beds — that time is now SOCIAL. Look:
  the stick figure's idle shifts weight, glances round and fidgets (hands on
  hips / arms crossed); talk speaks ~45 % of the time with both hands,
  listeners nod, the circle laughs; the crowd shader's POSE_STAND and
  POSE_TALK got the same (head tips about PIVOT_NECK); a cold firepit is a
  hangout (half sit, half talk), not a still standing ring.
- **Mo-cap SPICE on the stick figure (`NpcMocapSpice`, `NpcStickMocap`,
  `NpcSimpleFigure` "mo-cap spice" block).** The user's call: the stick
  figure's PROCEDURAL poses are the base and the fallback for everything; a
  Mixamo clip is a punchline now and then. A hidden copy of the pack's
  character (skinned meshes FREED: a bare Skeleton3D + a MANUAL
  AnimationPlayer the figure advances at its own rate, capped at 3x) plays a
  clip; `solve_points` turns joint POSITIONS into the stick joints' rotations
  — capsules are round, so a limb is just a direction (shortest arc from the
  arms-down rest; the T-pose rest never has to match); pelvis and head take
  the bone's delta from its upright rest; the torso is built from the spine
  and the shoulder line. Index 0 = the person's RIGHT (-X), the Mixamo
  Right* bones. The figure runs its procedural pose EVERY frame, caches it
  (Euler ROTATIONS — a basis written back re-decomposes and can swing a limb
  the long way round), restores the cache before the next procedural step,
  and slerps the clip pose over it by a 0.35 s weight — so fading out lands
  EXACTLY on the procedural pose (selftested to 1e-4 rad). Moments
  (`moment_for(clip, flavor)`): peak / cheer / wake are EVENTS (rolled on
  entry), dance / dj / talk / idle / sit / work PERIODIC (rolled per window
  from the second window); walking and lying never. Chance scales with
  `NpcDisplayPrefs.mocap_spice` (0 = never, 0.5 = table). Clips: every FBX in
  `Imported Models/NPC/mocap/<moment>/` (names free; `_retarget_extra` takes
  any Mixamo rig, scaling the hips by the SOURCE skeleton's rest height —
  the first frame of a seated clip would blow it up; sit clips get the
  ground-sitting offset), else MOMENT_DEFAULTS from the base pack. Budget: the
  host's MAX_RIGGED nearest (set_detail -> set_mocap_allowed in simple style);
  an idle skeleton is freed after 30 s. Selftest:
  `core/population/npc_mocap_selftest.gd`.
- **The Mixamo peak samba on the HUMANOID body** (Body style "humanoid") is
  the pose machine's CLIP_PEAK_DANCE; in "simple" style it reaches the stick
  figure as mo-cap SPICE (above); the light tier draws POSE_PEAK.
- **Selftests reset `PopTestPrefs`** (crowd_cohort / venue_crowd /
  npc_population `_init`): a player's saved "no departures" leaked into
  `crowd_cohort_selftest` and failed its departure checks.
- **The scale (user's wording, worst to best):** FUCK THIS!!! · Fuck You ·
  Fuck Me · Fuck It · Fuck Maybe · Fuck It! are the six `NpcMorale.BANDS`;
  FUCK YES!!! (`NpcPeak.LABEL`) is the PEAK state above them, never a band.
  Over each nearby full-tier head (`AMBIENT_MAX_TAGS` 20, overhead mode
  permitting) the STATE shows as words in its band colour — green FUCK YES!!!
  while peaking — with the task under it (`NpcAvatar._state_lbl`); the bar is
  optional.
- **Score + toast.** `PeakScoreChip` (UILayer, under the vibe chip: count-up,
  pop, "N now / today"), the settlement HUD's green score line, and
  `PeakToast` (own CanvasLayer at LAYER_TOAST): one toast at a time, onsets
  MERGE into it (re-pop, hold extended but never past MAX_HOLD_S from its
  start — a steady stream once kept one toast up forever), a new one at most
  every 5 s; `NpcDisplayPrefs.peak_toasts`. One `SettlementLog` "peak" line per
  quarter sim-hour of onsets.
- **DJ re-cast rule (found here).** The 0.5 h re-cast cooldown applies ONLY
  while the DJ is on a need; a set lost to a >6 h catch-up or a tier switch is
  re-cast at once (`_dj_on_a_need`). The DJ's interrupt bar is
  `NpcAgent.PERFORM_URGENT` 0.995.

## The effigy burn sequence (2026-10-08)

Plan: `~/.claude/plans/effigy-burn-sequence-and-poses.md`. A burn is now a
sequence, not a switch, and the effigy is a destination at every hour.

- **Stages live INSIDE the pre-roll.** `VenueCrowd.effigy_phase` adds
  `stage` (`gather` -> `flow` -> `sandmen` -> `burn`), `stage_ends_in_h`,
  `perimeter`, `flow_t0` and `burn_key` (`"%.4f" % ignited_h`). The pre-roll
  splits by fraction (`GATHER_FRAC` 0.35, `FLOW_END_FRAC` 0.80), so a record
  with any pre-roll works; an effigy's default pre-roll is
  `FireTimeline.EFFIGY_PREROLL_H` 0.75 h. The nav perimeter (F_FIRE) is
  stamped only while `perimeter` is true (sandmen, burn, circling) and after:
  the fire-flow performers dance INSIDE the line.
- **Attraction.** IDLE / AFTER: `EFFIGY_IDLE_DRAW` 0.9 + `EFFIGY_IDLE_PULL`
  0.3 — beats an art piece at the same distance, not a quiet person's temple
  next door (both pinned). Idle poses: gaze up / cross-legged / lounge / talk
  / a few dancing. LIT: `VenueCrowd.attends(id, burn_key)` — a hashed share
  `BURN_TURNOUT` 0.85 — picks the turnout; an attendee's routine block reads
  as ENRICHMENT and their bedtime bar rises to `STAY_UP_BAR` 0.99 (they stay
  up for the burn). **It never wakes a sleeper** — the user's rule; both
  tiers' `_pick` take the stay-up bar only for people still awake.
  `burn_key` reaches the agents through BOTH ctx dicts — and the engine's
  `_make_ctx` whitelist.
- **Roles (bridge, `_service_burn_roles`, after `_service_djs`)** reuse the
  DJ's `perform` path with a `role`: `flow` performers (`flow_count` =
  turnout/30, 10-20) on a moving `orbit` (`flow_orbit` at
  `FLOW_LANE_FRAC` 0.62 x safe_r, one lap per `FLOW_LAP_H`; light tier steps
  it as `ORBIT_STEP_H` arcs, full tier re-seats every step); `sandman` posts
  (`sandman_count`, one per 6 m, 8-24) at safe_r - 0.6 m KNEELING facing OUT;
  `redirect`: anyone (not a role) inside safe_r - 0.3 m is turned and walked
  radially out (`redirect_out` in both tiers) and the nearest sandman stands
  and gestures for `REDIRECT_HOLD_H`. `burn_roles()` / `burn_redirects()`
  are the read API. Roles end when the phase leaves BURNING.
- **A burn role's goal is exempt from `NpcNav.outside`** (cohort `_go` /
  `_begin_activity` on A_PERFORM, agent `_request_path` when `perform_role`
  is set) — otherwise every sandman's post was pushed out past the line.
- **Fire props:** `FirePropFx` (Main child): two particle poi and a warm light
  per performer, placed from `NpcPopulationHost.drawn_position` (either tier),
  spun on the NPC cosmetic clock.
- **The closing circle faces along it** (`ccw_tangent`), full tier via the
  face anchor, light tier along its arc.
- **Ground poses** (both bodies + rig logical clips, all aliased to the
  rigged body's sit/idle/dance): `sit_cross` (meals, quiet venues, idle
  effigy), `sit_lounge` (feet out, propped on straight arms — the burn's front
  row, replacing LYING, which read as casualties), `kneel`, `redirect`,
  `fire_flow`, `gaze`. The chair `sit` stays for the portapotty. Crowd codes
  12-17 (`POSE_CROSS`..`POSE_GAZE`). ⚠ **Crowd shader sign convention**
  (comment in `crowd_figure.gdshader`, measured by `ground_pose_diag.gd`):
  the figure faces +Z; NEGATIVE `limb_angle` = forward, NEGATIVE
  `body_tilt` = lean forward, positive `head_nod` = nod down. SIT's legs and
  WORK's bend were mirrored (sitting with the thighs out behind, bending over
  backwards) until this pass.
- **Labels follow the head**: `NpcAvatar._follow_head` eases the status root
  and the name tag down by how far the head is below standing
  (`NpcSimpleFigure.head_height()`; the rig uses the pose machine's
  lying/seated flags).
- **One drawn position per person.** `CrowdRenderer.drawn_position(id)`
  replays the shader's segment mix on the CPU; `NpcPopulationHost
  .drawn_position(id)` = the hero avatar, else that. The FUCK YES beacon
  follows it every frame and `spotlight`s its person into the hero pool.
  **Hero hand-offs are same-frame now** (the pop-in): a hero set change
  forces the crowd push (a periodic 0.2 s push alone left a leaver invisible
  and a joiner doubled), a joiner's avatar is seeded at the renderer's drawn
  position + yaw with its glide state cleared (`_hand_in`; it used to slide
  in from the spot it was last shown at), a leaver's crowd figure starts at
  the avatar and glides on, and a hero past the cull distance is handed to
  the crowd renderer instead of vanishing.
- Mo-cap spice moments `gaze` and `fireflow` (folders + READMEs).
- **Found by the Walton runs, fixed with it:** (1) attendees put off a meal
  until hunger `NpcAgent.BURN_HUNGER_BAR` 0.85 in both tiers' `_pick`
  (thirst/bladder unchanged). (2) `VenueCrowd.rain_clears(type, event)` is
  the ONE rain-wake rule: an UNLIT effigy's crowd takes cover (it was a live
  venue type, so a downpour left the idle-effigy crowd sitting in it).
  (3) **A backward scrub REBASES pending times** (`CrowdCohort._rebase_times`,
  `NpcAgent.rebase_time`): still a freeze (no state changes), but end/next/
  segment/need timestamps move back with the clock — left absolute, an
  85-day rewind left 250 people mid-meal for 85 days (`ends_in` 2034 h), and
  the burn "turnout" read 55 %. (4) Festival mode seeds the PER-CAMP types
  (`FestivalSeedLayout.PER_CAMP_TYPES` sleep, kitchen) for every camp whose
  outline holds none (`needs_seeding`) — before, ONE tagged capacity-1 bed
  anywhere on the site stopped all 35 camps getting beds. (5) The idle
  effigy's pull is 0.3 (0.45 competed with live sets at 21:00).
Verify: `venue_crowd_selftest` (`_test_burn_sequence`), the burn half of
`--capture=festivalmode` (flow / sandmen / turnout / tangent / beacon lock-on
asserts, PNGs 05a/05b), and `ground_pose_diag.gd`.

## Points of interest — KML pins from Google Earth (core/poi/, 2026-10-12)

The player marks real places on the property in Google Earth (the hydro
inlet, the pond outlet, the yurt clearing), exports a KML, and **Terrain
options → Points of interest → Import KML / KMZ…** puts a pin at every
placemark's exact coordinates so nothing has to be guessed at in the world.
- **`KmlPoiParser`** (`core/poi/kml_poi_parser.gd`, pure — NOT the older
  `KmlParser` in `scenes/ui/location_picker/`, which is the regex zone parser for the
  world map): Godot `XMLParser` over Placemarks with a Point / LineString /
  Polygon (outer ring only; MultiGeometry splits into "name (2)" …), name,
  description (HTML stripped), folder, and the colour the `styleUrl` resolves
  to through a StyleMap's "normal" pair — a KML `<color>` is AABBGGRR, and a
  Google Earth POINT carries its colour only in the icon URL (`color=1976d2`).
  ⚠ Two traps: XMLParser hands a CDATA section's content back through
  `get_node_name()` (`get_node_data()` errors); and coordinates are returned
  as `[lon, lat, alt]` float Arrays — a Vector3 is float32 and puts a pin a
  metre off. `.kmz` is read through `ZIPReader` (`doc.kml`, else the first
  `.kml`).
- **`PoiLayer`** — WorldPaths kind `"poi"` (one file per site:
  `user://maps/poi_<lat>_<lon>.json`, `user://worlds/<id>/poi.json`).
  Records keep WGS84 (a line / polygon's `lat`/`lon` is its vertex mean, the
  label + Go point) and are converted to site metres at build time with
  `GeoMath.lonlat_to_local_m` against the loader's `_lat`/`_lon` — the same
  mapping OSM uses, so a pin lands where the OSM features do. The OSM
  imagery-registration offset is deliberately NOT applied: a Google Earth pin
  was placed against imagery, so it is already registered to the photo.
  Re-importing a file REPLACES that `source`'s records (ids are a stable hash
  of source + KML id + index), so an edited export moves pins, never doubles.
- **`PoiRuntime`** (`Terrain/PointsOfInterest`): a pole + coloured head +
  ground disc + `no_depth_test` name tag per point (found through trees and
  from the far side of a hill is the whole point), a 0.4 m ribbon draped on
  `_ground_height_at` every 2 m per line / polygon with a shorter pole at the
  centroid. Rebuilt whole on `sync`; `set_shown` hides it.
- **Loader API** (`TerrainLoader`): `_attach_pois` in the load sequence after
  the camps; `import_kml_file(path)` (toasts added / off-map), `poi_records`,
  `poi_markers` (Site Plan: `graph_canvas._draw_poi_site` draws a pin glyph +
  name between the tagged spaces and the crew sites, reading the loader
  directly like the water network), `poi_world_position`, `remove_poi`,
  `remove_poi_source`, `clear_pois`, `show_pois` / `set_show_pois`
  (`[terrain] show_pois` in terrain_config.cfg), `teleport_to_poi` (player a
  step south of the pin, on the ground).
- UI: `terrain_options_ui._build_poi_ui` — FIRST block in the panel body:
  import button (native FileDialog), the list (colour swatch, name,
  "(path)"/"(area)", Go, ✕; a ScrollContainer past 8 rows), Show + Clear all
  (confirm). The list is rebuilt every time the panel opens, not only after
  the panel's own import. ⚠ The Terrain options panel is a 260 px
  PanelContainer anchored top-right with a FIXED design height, and its
  column had outgrown both: the body is now in a ScrollContainer clamped to
  the window height (`_apply_collapsed_size`), and the "Reset map / ALL veg
  styles" pair is stacked (side by side it was 328 px and pushed the whole
  panel 84 px off the right edge — measured with a headless min-size probe;
  any new row wider than ~250 px does it again). Verify with
  `core/poi/poi_selftest.gd` and `--capture=poi` on mtvernon (Validation
  list), which asserts the panel and the block are inside the viewport.

## Shoreline over time — archived drape + gauged lake level (core/terrain/shoreline/, 2026-10-23)

Terrain options → "Shoreline over time". Both layers are PURE FUNCTIONS of the
sim clock, so scrubbing the timeline moves them (the ExtremeWeather rule).
`ShorelineHistory` is a TerrainLoader child (`shoreline_history()`, made on
first ask); its record rides world.json `terrain_imagery.history`
({mode current|pinned|follow, release, lake_level}) via `world_imagery_record`.
- **Archived imagery = Esri World Imagery Wayback** (`WaybackCatalog`, pure).
  Source id `wayback_<release>` in `ImagerySources` (the release is the cache
  key suffix; `ImagerySources.wayback_meta` carries each capture's date /
  provider for the attribution). `ImageryService.cache_candidates` never falls
  back from a Wayback key to today's plain mosaic. Distinct captures: walk
  the tilemap `select` chain at the site's centre tile (z17: 14 requests at
  Bombay Beach instead of 197), read each changed release's metadata (layer
  4 outward until MinMapLevel..MaxMapLevel covers the zoom), dedupe on
  capture date + sensor keeping the newest release → 8 captures 2011–2024
  there. Cached in terrain_cache/wayback/. Only the detail + hyper drapes swap
  (`_history_chain()` in the loader's requests); the site patch is off while
  a capture is shown and the 30 km base stays today's. A capture not on disk
  at load is fetched after the load (`_history_deferred`). Follow mode waits
  1 s on one capture before asking for it.
  ⚠ **The "403s" were Python-urllib's User-Agent**: about half of Wayback's
  Apache backends refuse it (30 of 60); Godot's own agent is 60 of 60. No
  Referer or token.
- **Lake level = the USGS gauge** (`LakeGauge`, pure): NWIS daily values,
  62614 (NGVD29 ft) or 62615 (NAVD88); the known list first (Salton Sea
  10254005), else an NWIS lake-site search within 45 km. Cached in
  terrain_cache/lake_gauge/, refetched daily. NGVD29 → NAVD88 (the DEM's
  datum) from NOAA NCAT / VERTCON 3.0 **at the gauge**: +0.534 m there,
  +0.682 m at Bombay Beach 22 km north — the lake surface is level, so only
  the gauge's shift is its height. The lake is drawn as ONE plane (the OSM
  outline grown 2.5 km) at the level; its OSM body is left out of
  WaterBuilder (`filter_still`). Days are CelestialClock absolute days.
  **Reach mask** (`LakeSpill`, pure): a flat plane floods every hollow
  under the level, but the blocks behind Bombay Beach's berm stayed dry. A
  Priority-Flood seeded at the lake's own DEM cells gives each 8 m cell its
  SPILL level (the lowest lake level that reaches it); the plane's material
  (`terrain_water.gdshader` `use_spill`, off for every other body) discards
  where spill > level. Ground sampled a few rows a frame, the flood on a
  worker; unreached cells are 1e6, not INF (linear filtering of INF beside a
  number gives NaN, which draws). `wet_at(x, z)` is the same test on the CPU.
  ⚠ The DEM only holds ground ABOVE the water it was surveyed at (-72.56 m at
  Bombay Beach); a lower level (2026: -73.84 m) is drawn AT the DEM's lake
  (`drawn_level_m()`, said in the UI) — a hidden plane left no water at all.
  The sea ROSE 1990 → ~1997 before falling. Lake level defaults ON only
  where a KNOWN gauge is in range.
- **The shore band keeps vegetation off** (`ShorelineHistory.in_shore`):
  every cell the reach mask floods at the gauge record's HIGHEST level (or
  the DEM's lake, whichever is higher) + `SHORE_MARGIN_M`. The auto scatter's
  gap fill plants wherever the photo is dark green, and the old captures'
  shallows are. Fed to the generator as ctx `exclude_fn` and to
  `veg_point_excluded_callable` (Detect, deadwood) through
  `VegExclusionBuilder.build_index(..., extra)`. The mask lands frames after
  the water, so the loader rescatters once when `shore_signature()` first
  appears or changes (`_on_shoreline_changed_for_veg`, also called after the
  load and after the scatter). Bombay Beach: 202 → 23 auto plants, 0 on the
  old lakebed. Only while the lake level is on (no mask otherwise).
- Gates: `core/terrain/shoreline/shoreline_selftest.gd` (offline, real
  fixtures in testdata/) and `tools/checks/shoreline_history_check.gd`
  (Validation list).

## Known pre-existing runtime errors (not regressions)

List re-verified + pruned 2026-08-11: both boot-time "Node not found" errors
are FIXED (`ToolManager` under Player → `get_node_or_null` + self-heal;
HAConnectionUI button paths now include `/ButtonContainer`). Four long-listed
entries were STALE and are dropped: duplicate device id `ibc_glow_lights`
(second instance renamed `ibc_glow_lights_2`, see docs/ARCHITECTURE.md), the 4×
fire-extinguisher `!is_inside_tree()` (main.gd adds children before setting
global_position), the missing `camp_scatter_bake.tres` (the only load site is
guarded by `ResourceLoader.exists()`), and "target vector can't be zero" from
road/camp scatter (every look_at/Basis site now guards zero-length).
The clean-boot claim for the built-in maps no longer holds. A boot log on
2026-10-12 showed two C++ errors:
- "target vector can't be zero" with a backtrace into `scenes/gameplay/road/road.gd:190`
  (`curve.get_baked_length()`, i.e. Curve3D baking its up vectors over
  coincident points of the SOAK scene's road, not a script look_at).
- `curve.cpp` `!p_data.has("tilts")` from a Curve3D in the Mars /
  `mars_main_legacy.tscn` `string_lights.tscn` instance.

Both belong to the built-in scenes, which are no longer harness targets.
Neither is a script error.

**`core/terrain/site_boot_selftest.gd` currently FAILS 2 of 7** — "player above
ground gap -93.75 m" and "auto-veg generated got 0" at Mount St. Helens. It is a
live-NETWORK full-scene boot test (it fetches a z16 detail imagery layer that
never lands: `'detail' layer not cached — fetching z16 tiles …`), it is **not**
in the Validation list above, and it fails identically on d38417a — i.e. this
predates the 2026-08-01 stabilisation pass and is not a regression from it.
Diagnose the imagery fetch before trusting the grounding/vegetation assertions.

**`--capture=population` flakes: FIXED 2026-08-09** (root cause found): the
food/chore/cascade sub-checks were "state-sensitive" because the soak map's
autosave carries the SIM CLOCK forward between runs and agent RNG reseeds per
sim-DAY — every run sampled a different population day. The harness now pins
2026-07-15 07:00 at the start of `_run_population_verify` and the capture
passes fully and reproducibly. If a sub-check fails now, it is a real
regression (or someone removed the date pin).

**`--capture=graph` on the SOAK scene hangs at "opening the graph" since the
siphon round 3 (2026-10-12)** — the main thread stalls and the process grows
past 6 GB; a bisect with the outlet marker, state ring and burial cue all
switched off still hung, and the soak autosave opens in freeform where the
pin / plan-window code is inert, so the cause is not yet known. It does NOT
reproduce on a real map: the Mount Vernon site-review (freeform / site /
elevation / globe sets) and `--capture=hydroload` pass with zero script
errors. The user asked that the soak map no longer be used for verification
(see "Harness rules" at the top). `--capture=graph` now defaults to the Mount
Vernon world, and the harness refuses SOAK without `--allow-builtin-scene`.

**Re-verify this list before trusting it** — it is hand-maintained and drifts.
The former "UISP button node-path misses" entry was stale: nothing outside
`uisp/` ever referenced UISP, and that subsystem is now under `parked/uisp/`
(see `parked/README.md`).
