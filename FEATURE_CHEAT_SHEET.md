# SIMbiogenesis — Feature Cheat Sheet

Player-facing reference for modes, docks, hotkeys, and how to use them.
Validated against `project.godot` InputMap + current UI scripts (July 2026).

**In-game help:** press **F1** (`toggle_help`) for Controls & Tips.

Status tags used below:

| Tag | Meaning |
|-----|---------|
| ✅ | Usable end-to-end |
| ⚠️ | Partial / foundation / UI thin / easy to miss |
| ❌ | Orphaned, unbound, or documented-but-not-in-UI |

---

## Quick answers: the two features you asked about

### Site Plan radial + array (camp tools) ✅

Site Plan is a **gods-eye 3D arrange** view (LMB picks/moves placed props). Radial / Array tools live on a visible Site Plan dock (not only View options).

**How to use**

1. Press **G** → **Site Plan** chip.
2. **Radial** toggle (topbar dock): bold **working radius** ring + auto-yaw on move. Slider **R** sets camp radius without resizing the SoI. **Array ▾ → Reset R to SoI** restores SoI radius.
3. **LMB-drag a 3D prop**; hold **Shift** while dragging to snap yaw to the **radial tangent** (faces outward). Shift+drag on empty disc still orbits.
4. **Array ▾**: Line / Arc / Circle → ghost preview → **Confirm array** (prop-only duplicates). Optional **Set array center** for smaller rings.
5. **View options ▾**: Show graph chips (off by default), Live lighting, Site wires **3D / Metro / none**.

**Tips**

- Watershed outlines are not movable (select-only).
- Daytime bake (mean solar noon) is default; enable Live lighting to follow the clock.
- Freeform stays the abstract systems graph.

**Source:** `graph_spatial_edit.gd`, `system_graph_view.gd` (Site dock), `graph_canvas.gd` (guides / wire modes).

---

### Watershed catchment → pond ✅ (pond-first; no freehand paint)

Designate the hillside that drains into a pond as a graph **watershed rain catchment** so WeatherService precip fills the tank (mesh twin follows). Manual **T** Rain/Drain remains for instant scrub.

#### A) Preview / Designate (player-visible) ✅

1. Ctrl/Alt-click a pond → **Pond settings** (or open **Siphon Lab** with a bound pond).
2. **Watershed** row: **Preview** runs a local D8 window around the pond → teal outline on **Site Plan** / **Elevation CT**.
3. **Designate catchment** (pond must be on the graph — **Add to graph** first, or designate auto-adds): creates/updates a `catchment_kind: "watershed"` node wired to that pond’s tank (`area_m2` from DEM upstream, default runoff ~0.35).
4. Preview draws a **teal ground outline** plus a band on **Elevation CT / Site Plan**. Designate adds a catchment node beside the pond tank.
5. Scrub rainy hours on the Timeline → tank stock rises → 3D pond level follows (bathymetric). Siphon drain lowers it when primed.
6. **Siphon Lab → Sim inflow**: optional L/s into the bound pond (no rain/watershed). Enable + set rate, then play the Timeline so the flow engine advances.
7. **Bind to nearest pond** prefers map-live tanks; **Clean orphan ponds** removes leftover prototype pond nodes. Status shows which pond is bound.
8. **Clear preview** / **Remove catchment** as needed. Inspector: area, runoff, linked pond tag, **Refresh from DEM**.

#### B) Terrain → Rain / Drain (manual setup) ✅

1. Press **T** (terrain sculpt dock) → **Rain** / **Drain**.
2. Hold to raise/lower a user pond toward spill / empty. Graph tank tracks bathymetric volume in Auto fill.

#### C) Hydro design flow (silent / automatic) ⚠️

1. Put a **hydro** node and a higher **intake / catchment / water** node on the graph with Site Plan positions.
2. Connect intake → hydro; ticks may overwrite gross head, penstock length, and design flow from `upstream_area × precip × 0.35`.

**What you will not see today**

- Freehand / lasso hillside paint for catchments.
- Full-SoI colored flow-accumulation heatmap.
- A top-level “Watershed mode” toggle in Terrain options.

**Offline check**

```text
Godot.exe.exe --headless --path . --script core/terrain/watershed_selftest.gd
```

**Source:** `core/terrain/watershed.gd`, `terrain_loader.analyze_pond_watershed` / `designate_pond_watershed`, `system_graph_view.add_imported_watershed_catchment`, `resource_flow_engine` (`catchment_kind: "watershed"`), pond modal + Siphon Lab Watershed row, `graph_canvas` Site Plan/Elev overlay.

---

## Hotkey reference (authoritative InputMap)

| Key / action | What it does | Notes |
|--------------|--------------|-------|
| **WASD** | Move | |
| **Shift** | Sprint | |
| **Mouse look** | Look (when captured) | **Space** pause releases mouse |
| **Space** | Pause / resume sim | `sim_pause_toggle` |
| **O** | Interact | Also bound to `vegetation_area_edit` — interactables win; bare ground veg tune is fallback |
| **X** | Dismount / stop charge | |
| **C** | Charge EUC (at a charging station) / CAMPS section of the edit toolbar | `charge` + `camp_scatter`; the legacy camp scatter dock is **Shift+C** (`camp_scatter_legacy`). Both handlers are event-driven, so whichever consumes the event wins — see [Key conflicts](#key-conflicts--gotchas) |
| **R** | Repair shorted EUC | |
| **Shift+H** | WATER section of the edit toolbar (Trace / Draw / Edit / Culvert / View) | `water_edit` (2026-10-18); switches sections when the toolbar is already up, like T / V |
| **1 / 0** | Equip / unequip tool | |
| **G** | System graph | Core gameplay surface |
| **U** | Unified Library | Also timeline 📦 |
| **L** | Location picker | Older docs sometimes say **M** — InputMap is **L** |
| **T** | Edit toolbar - terrain tools | Unified toolbar; keep walking/looking (RMB) while you edit |
| **V** | Edit toolbar - vegetation tools | Same toolbar, plants section |
| **Shift+T / Shift+V** | Classic sculpt / paint docks | Legacy modals, kept until the toolbar fully replaces them |
| **B** | Building Builder (aimed building) | Or Interact on amber-highlighted building |
| **J** | Light place mode | LMB place, RMB / J exit; Ctrl/Alt+click existing light to edit |
| **N** | Linkage Lab | |
| **K** | Site Report | Also timeline 📊 |
| **H** | Parametric part store (OpenSCAD) | `toggle_scad_store` |
| **Q** | Packing Lab (site cargo → truck) | `toggle_packing_lab`; also Site Report packing card |
| **M** | Placed Props edit dock | `placed_props_edit` |
| **Y** | NPC space edit dock | `space_edit` |
| **Z** | POV warp overlay | `toggle_pov_warp` (StarShade projector) |
| **Home** | Reference-star markers (computed Polaris/Sirius/… over the star map — alignment check) | `toggle_star_calibration` |
| **P** | Light menu / pallet rack | Contextual — see [Key conflicts](#key-conflicts--gotchas) |
| **I** | Projection canvas | NLE / compare panels |
| **F1** | Help overlay | |
| **F11** | Window wall (multi-monitor viewport) | `toggle_window_wall`; off until enabled in Settings → Window Wall. In the view: Esc/F11 leave, U toggles UI, WASD/QE nudge, ←→ or mouse-drag turn, R reset, Ctrl+S save viewpoint, I identify screens |
| **Enter** | Multiplayer chat compose | `mp_chat` |
| Esc | Close modal / cancel | |

Controller labels for common actions live in `interaction_prompt_ui.gd` (A = interact, B = dismount, etc.).

### Key conflicts / gotchas

`core/input_map_selftest.gd` enforces this table — it fails on any key bound to
two actions that is not listed in its `ALLOWED_OVERLAPS` (resolved) or
`KNOWN_CONFLICTS` (real, tracked) const. Run it after any `[input]` edit.

| Collision | Reality |
|-----------|---------|
| **O** = Interact + veg-area edit | Resolved. Focusing a prop/SoI/solar/pond/building wins; veg area modal only if nothing else is focused (`interaction_focus.gd:872-878`) |
| **Shift** = Sprint + drone ascend | Resolved. Mode-exclusive — `sprint` is polled only in `player.gd`, `drone_ascend` only in `fpv_drone.gd`, and the two are never active together |
| **Enter** = `mp_chat` + `ui_accept` | Resolved. Chat is handled in `_unhandled_input`, so a focused Control takes Enter as `ui_accept` first |
| **P** = Light menu + pallet rack | Resolved. `govee_lights.gd` only claims **P** while you are in range of a light and consumes it; elsewhere **P** opens the pallet rack |
| **C** = Charge + CAMPS toolbar section | Resolved. `charge` is event-driven now (`scenes/gameplay/player.gd` `_unhandled_input`, `event.is_action_pressed("charge")`), so a consumed event reaches one handler only. The legacy camp scatter dock moved to **Shift+C** |
| README / Wave walkthrough | Some keys (**M** location, Berm/Hill/Swale) are outdated vs current UI. Note **M** is now Placed Props edit |

**Resolved since the last pass:** `toggle_camera` (**V**) was deleted — it had
zero handlers anywhere (the game is first-person only) yet the help overlay
advertised it to players as "Toggle camera view". `placed_props_edit` was
unbound, which made the Placed Props panel unreachable from both of its keyboard
openers; it is **M** now. POV warp moved off its hardcoded, unguarded `KEY_P` in
`main.gd` to the `toggle_pov_warp` action on **Z**.

---

## 1. Launch hub & maps ✅

| Feature | How |
|---------|-----|
| Launch hub | Play project → map select (`YOUR WORLDS`, world map) |
| Create map here | Pick lat/lon on world map → **Create map here** → writes `user://maps/*.tres` |
| Start / Continue | Start selected map; Continue loads latest autosave / newest slot |
| Load from cache | Per user-map checkbox — prefer cached DEM/imagery |
| Delete user map | Per-row **Delete** (built-ins refuse) |
| Add StarShade | Hub / Building Library — places catalog `starshade` |
| Return to hub in-game | Timeline **🗺** (autosaves first) |
| Location while playing | **L** or Timeline ⚙ → location |

---

## 2. Movement, vehicles, survival

| Feature | How | Status |
|---------|-----|--------|
| Walk / sprint | WASD + Shift | ✅ |
| Interact | **O** (or A on pad) when prompt shows | ✅ |
| EUC / vehicles | Interact to ride; **X** dismount; **C** charge | ✅ |
| Repair shorted EUC | **R** when prompted | ✅ |
| FPV drone | Mount drone vehicle; look/move via drone | ✅ |
| Survival mechanics | Timeline ⚙ → Survival toggle | ✅ |
| Random fires | Settings / exports; manual fire with **F** when enabled | ⚠️ map-dependent |
| Fire extinguisher | Pickups when enabled; known spawn spam in Known Issues | ⚠️ |
| Death / Game Over | Survival + crises | ✅ |

---

## 3. Timeline, time, weather ✅

Bottom bar owns the clock.

| Control | How |
|---------|-----|
| Play / pause | ▶ / **Space** |
| Speed | ◀◀ / ▶▶ chips |
| Scrub | Drag track; wheel zoom; Alt/MMB pan |
| Date | Y/M/D spinboxes |
| Mode chips | LIVE / SIM / PLAYBACK (TimeDirector) |
| Weather indicator | Non-interactive source chip (forecast / archive / synthetic) — no manual weather picker |
| Settings ⚙ | Clouds, sun/moon, stars, location, live mode, survival, HA keys, OpenTopography key |
| Save 💾 | 8 slots + Continue + Delete |
| Needs chips ⚡💧🍎♻ | Closure health → click for System Review |

**NLE / datastream (left icon cluster)**

| Icon | Action |
|------|--------|
| 📥 | Import HA CSV as observed clip |
| 📈 | Render energy batch for Ctrl-drag selection |
| 🎬 | Export selection to **MP4** at 30 fps, at the bar's playback speed (needs `ffmpeg`) |
| 📍 / 🧹 | Add / clear climelapse drone path waypoints |
| 📄/🧮 | Render load: CSV vs Modeled |
| ⧉ | Compare observed vs sim → projection canvas (**I**) |
| 🎚 | Tracks menu (waveform lanes) |
| 📹 📷 ⏲ | Load video / live camera / snap video to playhead |

**🎬 video export** — needs a **location map** (TerrainLoader) *and* a Ctrl-drag range
on the track; both refusals raise a HUD toast. Flow: pick a save path → (if the render
is longer than ~1 min of video) a confirmation showing frame count + video length →
the world **pauses** and the capture steps it by `speed / 30` sim-hours per rendered
frame, so the video plays back at the speed shown on the bar. A progress window
reports `frame N / M`, then the ffmpeg encode, then the result (it stays up until
closed). Cancel is safe; the clock's speed/analemma state is restored on every exit
path. The old handler forced `analemma_mode` on before starting and auto-played at ∞
afterwards — which is why an export looked like "the game just starts flying" — and
the orphaned `_on_render_clim_pressed` bake handler was removed.

**📹 📷 ⏲ / projection canvas (I)** — only `soak_festival_2026.tscn` and the legacy
`main.tscn` author a `UILayer/ProjectionCanvas`, so on Mars and every generated
location map these silently did nothing. `main.ensure_projection_canvas()` now
instances it on demand (lazily — it owns an always-updating SubViewport).

---

## 4. Sphere of Influence (SoI) & Snowglobe ✅

| Action | How |
|--------|-----|
| Open Snowglobe / resize | Aim at SoI map pin → **O** (Interact) → radius slider |
| Graph SoI chip | Shows radius; same pin workflow |
| Freeform SoI bubble | Graph → Freeform + **View options ▾ → SoI bubble** — Shift+drag orbit, Shift+scroll zoom |
| Snowglobe mode chip | Graph mode strip **Snowglobe** (modal preview) |
| Site Plan | Top-down SoI; LMB move 3D props; Radial/Array dock; Shift+drag orbits (or tangent yaw on props); daytime bake by default |
| Elevation CT | Half-cutaway 3D section (default on); **Slice** slider −R…+R; Shift+drag rotate heading / scrub depth; Shift+wheel zoom cut; noon bake; **Hydro Lab…** deep-dive |
| Hydro Section chip | Elevation toolbar: live ΣQ / head / PE (or gen kW) from pond + culverts |
| Designate roof/crop | **Designate ▾** in Site Plan → Catchment or Crop → click empty roof/field on disc |

---

## 5. System graph (**G**) ✅

### Modes (chip strip)

| Chip | Use |
|------|-----|
| Freeform | Abstract wiring canvas |
| Site Plan | Plan on SoI disc; binds 2D↔3D |
| Elevation | Section view |
| Snowglobe | Live 3D SoI preview |

### View options ▾

| Item | Use |
|------|-----|
| SoI bubble (freeform) | 3D snowglobe behind freeform nodes |
| 3D snowglobe section (elevation) | Live CT half-cutaway (on by default in Elevation) |
| Node cards / Preview labels | Display toggles |
| **Radial layout** | Auto-yaw twins outward (see top) |
| Seed site from freeform… | Copy freeform layout into site coords |
| Elevation scale 1× / 5× | Vertical exaggeration |
| Rotate section heading +15° | Twist elevation cut |
| Reset section | Heading east · slice 0 · zoom fit SoI |

### Combine ▾ / Layout ▾ / navigation

| Action | How |
|--------|-----|
| Group / Ungroup / Explode | Combine menu or **Ctrl+G** / **Ctrl+Shift+G** |
| Make Solar Array / Battery Bank | Multi-select → Combine |
| Wire Series / Parallel | Marquee panels → Combine |
| Pick controller for array… | Voc-ranked picker |
| Arrange layout | Layout ▾ |
| Spawn 3D placeholder | Gray-box twin for selection |
| Expand / Collapse | ▸ Expand / ◂ Collapse (or Esc to pop scope) |
| Drill into compounds | Zoom / Expand — seamless tween into child scope |

### Components (SketchUp-style) ✅

| Action | How |
|--------|-----|
| Save as Component | Select compound → Inspector **Save as Component** → My Components library |
| Edit one → update all | Structural edits debounce-sync siblings; SOC etc. stay per-instance |
| Make Unique | Detach instance from definition |
| Built-in Super-nodes | Library → Super-nodes (e.g. StarShade tree) |

### Wiring & electrical ✅

| Feature | How |
|---------|-----|
| Connect | Drag from port to port |
| Wire styles | **Wire ▾** Bezier / Rounded / Metro; Apply to all |
| Voc fault | Over-Voc controllers destroy + education overlay; RESET on node or Export inspector |
| History / Legend / Hints | **View ▾** |
| Export / Import graph JSON | **Graph ▾** |
| .esim site package | **Share ▾** export/import/ghost/share-code |
| 3D conduits | Inspector conduit route — LMB pin, Enter commit, Esc cancel |

### Library / Inspector

| Action | How |
|--------|-----|
| Empty click | Deselect → Library sidebar |
| Spawn | Click or drag library item |
| Place Model | Presets with `model_id` → ghost place in world |
| PBI / fundamental nodes | Seeded, locked (cannot delete) |

### Challenges 🎯 ✅

Timeline **🎯** or graph Challenge flow → e.g. **Keep the Lights On** (power-only fail rules).

---

## 6. Unified Library (**U** / 📦) ✅

Tabs: Buildings · Graph nodes · Vegetation · Structures (+ Linkage Lab entry).

| Action | How |
|--------|-----|
| Search / Use / Place | Select row → Place or open editor |
| Linkage Lab… | Opens **N** designer |

---

## 7. Crosshair world interactions (**O**) ✅

| Target | Highlight | Interact does |
|--------|-----------|---------------|
| SoI pin | — | Snowglobe / SoI panel |
| OSM solar array | Red | Add array compound to graph (idempotent per tag) |
| Still water / pond | Blue | Pond settings drawer |
| OSM building | Amber outline | Building Builder (**B** also) |
| Placed prop | — | Edit drawer / special (Linkage deploy, printer, pallet rack…) |
| Placed light | Gizmo spheres in place mode | Brightness/color modal |
| OSM veg area | — | Tune-look for that area (if nothing else focused) |

**Pond drawer:** fill level, **Capacity Auto (terrain L) / Manual**, **Fill Auto / Manual**, **Add to graph / Remove**, **Delete** (sculpted only). Ponds are **never** auto-added to the graph. Auto capacity/stock come from gravity bathymetry; graph tank `capacity_qty`/`level` twin the mesh unless Manual.

**Culvert hydrology (Elevation):** wire **Culvert Pipe** from a pond tank/catchment → outlet/hydro. Set **Invert in/out** in the connection inspector (auto-seeded from elevations). Staged multi-outlet: as pond level rises, culverts engage in invert order; live Q + PE show on the wire and **Hydro Section** chip. Optional hydro node tracks live Q/head unless `lock_design_flow` / `lock_gross_head`. Elevation stays **generic**: solid blue pond band (`floor_m`→`level_m`), straight culvert chords, no Storage/Catchment chips (blue body is the visual).

**Siphon Lab (graph view chip):** toggle **Siphon Lab** next to Freeform / Site Plan / Elevation (also inspector **Open Siphon Lab…**, double-click siphon, or placed-prop **Siphon Lab**). Fills the graph canvas with a zoomed elevation slice (2D water + spinning prop); set **module height**, **siphon start** / **break**; live RPM, PE (ρgQH), electrical W. **Bind to nearest pond** / **Ensure ∞ culvert outlet**. Parks the SoI SubViewport while open (perf).

**Siphon Hydroturbine (library → Hydro):** 6″ PVC intake + 8″ culvert out, hoverboard motor ≤250 W DC. Place Model optional (`hydroturbine` GLB — spins in-world with output). Prefer Siphon Lab for levels; **DC +/- → 48 V battery**. Primes at `siphon_start_m`; breaks below `siphon_break_m`.

**Mt Vernon playtest (windowed):** map file is `user://maps/loc_48p3252_n122p2469.tres` (alias `--user-map=mtvernon`). Dig upper pond → Add to graph → Rain to fill → Siphon Hydroturbine (or 8″ culverts) → Elevation / Siphon Lab. Full agent review (world + freeform + site + elev + snowglobe + Lab + diagnostics/perf):
`Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=site-review --review-sets=world,freeform,site,elevation,snowglobe,siphon --perf --shots-dir=mt_vernon_review --quit-after-capture`
Output: `user://screenshots/mt_vernon_review/{world,graph,siphon,perf}/` + `diagnostics.json` + `manifest.json`.

**OSM solar bulk:** Graph toolbar **☀ Add OSM Solar** (arrays inside current SoI).

---

## 8. Terrain sculpt (**T**) ✅

Tools: **Level · Pond · Rain · Drain · Raise · Lower · Smooth · Ramp · Measure** · Undo · Clear all · Top-down.

| Tool | Interaction |
|------|-------------|
| Level | Drag rect → pad to centre height (feathered) |
| Pond | Lasso (≥80 m²) → carve bowl (+ thin seed puddle); switch to Rain to fill |
| Rain | Draw over depression → hold LMB to raise `level_m` toward spill (rate m/s) |
| Drain | Draw over user pond → hold LMB to lower; near floor removes the pond |
| Raise / Lower / Smooth | Paint with Size / Strength / Hardness |
| Ramp | Click start, then end |
| Measure | Two points → distance, Δelev, % grade |
| Top-down | Ortho overview + contours / cut-fill readout |
| Undo | Button or **Ctrl+Z** (one entry per Rain/Drain hold) |

Shapes: Brush · Circle · Rect · Lasso · Polygon.

**Outdated docs:** Wave walkthrough Berm / Hill / Swale + 45°/90° camera — **not** in the current dock. Berm/swale math still exists in earthworks / selftests (**❌** as dock tools).

---

## 9. Vegetation (**V**) ✅

Tools: **Paint · Place · Clear · Select** · shapes Brush/Circle/Rect/Lasso/Polygon · **Tune look…** · Undo · Exit.

| Feature | How |
|---------|-----|
| Paint | Hold LMB brush; subspecies under Type |
| Place | Click hero tree |
| Select + retype | Lock area → change Type |
| Tune look… | SubViewport studio — density, H/W, shader knobs, OSM→species map |
| Apply to map | Writes through TerrainLoader settings/style |

Lawn/field auto-scatter is **off by default** (`scatter_lawn_field`).

---

## 10. Camps (**C**) ✅ (BRC-oriented)

| Action | How |
|--------|-----|
| Open dock | **C** or Terrain options → **Edit camps** |
| Shapes | Circle / Rect / Lasso / Polygon / **BRC Auto** |
| Generate / Clear | Rebuild or remove Camps node |
| Advanced | Plot depth, scatter step, light LOD/density |
| Terrain options | Generate BRC camps toggle, playa exclusion miles |

Requires street density / BRC-like OSM; elsewhere use manual selection + Generate.

---

## 11. Buildings (**B**) ✅

| Action | How |
|--------|-----|
| Open | Aim at building → **O** or **B** |
| Style | Roof shape/pitch/colors/height, wall mode, facade tex |
| Doors/windows | Click preview wall to place |
| Library tab | ModelCatalog structures → place or replace OSM |
| Photoreal roofs | Hyper imagery UV2 when available |
| Reference tab | Mapillary nearby photos (token in `terrain_config.cfg`) |

---

## 12. Placement: props, lights, printers, racks

| Feature | How | Status |
|---------|-----|--------|
| Place from graph Library | **Place Model** → ghost → LMB | ✅ |
| Prop edit drawer | Interact / click prop — Move, Apply, Delete, Collide, Burnable | ✅ |
| Move | Edit → **Move** (aim + LMB; Esc cancel) or Alt+drag grab | ✅ |
| Light place | **J** → aim → LMB; RMB/J exit; Ctrl/Alt select | ✅ |
| Linkage structure | **N** design → Place in world; Interact deploy/stow; click → Linkage Lab | ✅ |
| Pallet rack | **P** (collides) or Library; Interact to re-edit | ⚠️ key conflict |
| CNC / mud / trash printers | Interact → Print modal (STL, place, start) | ✅ |
| Placed Props panel | Upload GLB, Place mode, OSM replace | **M** (`placed_props_edit`) |
| Geodesic / mud designers | Library / machine flows | ✅ |

---

## 13. Terrain options panel ✅

Expand **▸ Terrain options** (on-map UI):

- Flatten roads / sites · Show buildings / water · BRC camps · Auto veg + density · Show geometry  
- **AI-enhance spawn area** (Gemini key; ~$0.04 cached) + Generate/Regenerate  
- Align OSM to imagery (nudge / Auto BRC / Reset)  
- Refresh Elevation / Imagery / Map data / Vegetation / All · Reset site  

---

## 14. Energy, solar UI, shading

| Feature | How | Status |
|---------|-----|--------|
| SolarUI | Appears when graph has solar; panel settings (high-accuracy SPA, shadow raycast) | ✅ |
| Open-Meteo weather | Automatic when data covers site | ✅ |
| HA live SOC | LIVE mode only; scrub uses EnergyTimeline | ✅ |
| Solar shading heatmap | Timeline **🔆** — year shadow decal; click again to clear | ✅ |
| Site Report | **K** / 📊 — monthly GHI/PV/wind/rain/temp/hydro | ✅ |
| Climate Record Book | Timeline 🌡 | ✅ |

---

## 15. Hydro + water catchments ⚠️/✅

| Feature | How | Status |
|---------|-----|--------|
| Library Hydro | Physics (Paish / Darcy–Weisbach) | ✅ |
| Terrain-derived head / penstock / Q | Site Plan + intake + weather | ⚠️ silent coupling |
| Pond → catchment + tank | Pond drawer **Add to graph** | ✅ |
| Roof catchment designate | Site Plan Designate ▾ Catchment | ✅ |
| Watershed → pond catchment | Pond / Siphon Lab **Preview** → **Designate** | ✅ |
| Freehand watershed paint | — | ❌ out of scope v1 |

---

## 16. Renewables & machines (graph ↔ 3D)

| Asset | Place / use |
|-------|-------------|
| PV panels / arrays | Library or OSM Interact; Combine wiring |
| Wind (VAWT etc.) | Library Place Model |
| CSP trough | Library CSP → Place Model; tracks sun; steam ports | ✅ |
| StarShade | Component tree + 3D model | ✅ |
| Precious Plastic / processors | Library Place Model + chore recipes | ✅ |
| Habitat / tanks / PBI | Locked fundamentals + library | ✅ |

---

## 17. Linkage Lab (**N**) ✅

Full-screen parametric scissor designer (inches internally).

1. **N** or Library → Linkage Lab…  
2. Edit structure / panels / supports → live preview  
3. **Place in world** → ghost place  
4. In world: Interact toggles deploy/stow; stowed arrays contribute 0 capacity  
5. Click structure → **Linkage Lab** to edit in place  
6. Import `.gamebundle.json` via timeline 🎮 or Placed Props  

**📋 Build Guide** (topbar, or "Build guide" on a placed structure): priced
bill of materials with editable unit prices, weight breakdown, cut list, drill
templates with dimensioned hole positions, the U-bracket detail drawing, the
per-joint assembly sequence, and the crew schedule. Exports CSV / JSON to
`user://linkage_designs/` (no PDF — see the footnote in the guide).

**🔩 Hardware Detail** (topbar): the parts stacked at each joint — bolt,
bushing, lock washer, beam, washer, nut — threaded on the real bolt, through
ghosted timber cut from your own design. Assembly tabs across the top, an
explode slider, per-axis part cards with the shipped preset library. Click a
part in 3D to select it, drag along its axis to move it (it snaps flush),
`Del` removes, `Ctrl+D` duplicates, arrows nudge by 0.01″.

- **In structure** (default ON, the webapp's part view): the joint on the
  solved frame, with EVERY detailed assembly's hardware stamped at EVERY joint
  that uses it and the camera parked on the focused one. Untick for a
  standalone studio when you want the stack alone.
- **Hardware Full Detail** (in the Lab's Hardware Settings card) lets those
  parts drive the structure's real stack gaps and bracket dimensions. Off by
  default; the sidebar's own numbers are preserved while it is on.

---

## 18. Multiplayer ✅

Timeline **Multiplayer** chip → lobby:

- Host / join (join code, optional password)  
- Shared clock + avatars  
- Design share / ghost merge + live graph/prop sync  
- **Enter** chat; proximity bubbles; mute  
- Hardening: expiry, allowlist, rate limits  

---

## 19. Home Assistant digital twin ⚠️/✅

| Piece | How | Status |
|-------|-----|--------|
| Connect | Timeline ⚙ / HAConnectionUI — URL+token in `user://` only | ✅ |
| Entity link | Graph inspector Advanced · HA link | ✅ |
| Automations | Inspector Automation section; Push YAML | ✅ |
| CSV replay | Timeline 📥 / 📂 | ✅ |
| LIVE gating | SimMode / TimeDirector — live data only in LIVE | ✅ |
| HACS integration | ROADMAP Pillar 5 — not the current architecture | ❌ migration TBD |

---

## 20. Projection / POV / video ✅/⚠️

| Feature | Key / UI |
|---------|----------|
| Projection canvas | **I** — BL/BR panels, compare mode |
| POV warp | **Z** (`toggle_pov_warp`) — calibration-related |
| Warp / calibration actions | InputMap `toggle_projection_warp` / `_calibration` / `reset_projection_warp` (special keys) |
| Video / OBS feed | Timeline 📹 📷 |

---

## 21. Save / share / portable sites ✅

| Feature | How |
|---------|-----|
| Game save | 💾 slots + 3 min autosave |
| Graph autosave | Per-map JSON |
| .esim package | Graph Share ▾ — graph + SoI + props + styles |
| Share code | Copy / paste graph+SoI |

---

## 22. NPC population & desire lines ✅ (opt-in — nothing appears until you switch it on)

Individual simulated people (10–50) with needs, morale, chores and real
pathfinding. **Two things must both be true before anyone exists**, which is why
a freshly loaded map looks unchanged:

1. you have **tagged at least one space** for each critical need, and
2. a **Population node** on the graph has **Simulated individuals** ticked.

### A) Tag the spaces people walk to

| Target | How |
|--------|-----|
| Placed prop | Hold **Ctrl** or **Alt**, aim at it → **O** (or click) → bottom drawer → **NPC space** dropdown + capacity |
| StarShade / pallet rack | Same, but these open their own editor — the **NPC space** row is in that modal |
| An **area** of ground | Press **Y** → pick a type + capacity → **Draw area** → click corners on the ground, click the first corner (or right-click) to close |
| OSM building | Hold **Ctrl**/**Alt**, aim at it → **O** or **B** → Building Builder → **NPC space** row (Customize tab) |

Types: **Restroom · Kitchen/Eating · Sleeping · Water Point · Shower/Wash**, plus
enrichment: **Fire Circle · Dance/Movement · Quiet · Making/Craft**.

> Tag at least a **kitchen, water point, restroom and sleeping** space. A need with
> no tagged space counts as *blocked*, which costs **double** morale — that is the
> fastest way to watch a camp fall apart.

### B) Add the people

1. **G** → Library → **Population** category → place the **Population** node.
2. **Wire its inputs**: a water tank → water input, a food tank → food input.
   (3rd input, biomass, is optional fuel for fire circles.) Outputs go to
   greywater / blackwater / biomass tanks. Unwired inputs read as starved.
3. Select the node → Inspector → **Occupants** (1–64) → tick **Simulated individuals**.
4. Press **Space** / play so the clock runs. The sim ticks **with the graph closed**.

### C) Where to see them

| View | What |
|------|------|
| 3D world | Silhouette figures walk, sleep, work, dance. Ctrl/Alt-aim one → name, morale band, what they are doing |
| **G** → Site Plan | Space markers (glyph + live occupancy) and morale-tinted dots with trails |
| Inspector → Population Simulation | Roster, morale bands, collapse risk, blocked needs, walking distance / kcal / furthest trip |
| **Routines & chores…** button | Roster + day-plan strips, chore board, weather, the **Daily routine** tab, and the **Animations** tab (bind a clip to each space) |

### D) Desire lines (View options ▾, Site Plan)

| Item | Effect |
|------|--------|
| **Show worn paths** | Heat map of where feet actually wear routes in (legend bottom-left) |
| **Show live trails** | Fading trail behind each person |
| **Filter: …** | Cycle all traffic → water → food → restroom → sleep → wash → gather → work |
| **Remember: …** | Today / Past week / All time |
| **Drape worn paths in the 3D world** | Same heat map painted on the terrain (works outside Site Plan) |

Traffic has to accumulate — give it a few sim-hours at speed before the pattern reads.

### Gotchas

- **Wayfinding takes ~30 s of real time to map the site.** Until then people walk
  straight lines through obstacles. The inspector shows *"mapping the site… 62%"*.
- People path **into and through buildings**; a building with no door gets one
  auto-placed facing the nearest road. Buildings you tag as a space are always
  enterable.
- Occupants is the **authored** headcount; the live count (after anyone quits)
  shows as *"12 of 16 present"*.
- **If everyone vanishes, they rage-quit.** People leave permanently when a
  critical need stays blocked, and once the last one goes the world falls
  silent — nothing moves or consumes. The inspector then shows *"EMPTY — all N
  people have left"* and why. Fix the cause first, then press **Reset
  population** (habitat inspector); resetting alone just brings in a group who
  will leave the same way.
- People follow a **daily schedule** (sleep, bathroom, eat, yoga, work, wash),
  edit it in **Routines & chores… → Daily routine**. Each person is shifted up
  to ±30 min so the camp does not move in lockstep; needs still interrupt and
  the schedule is what they return to. Times are in minutes past midnight, and
  edits only take effect on **Apply**.
- Morale caps at **75%** on needs alone — the rest is earned at enrichment spaces.
- **Settings → NPCs → Body style** switches between *Humanoid* (rigged
  character) and *Simplified* (articulated stick figures with elbows and
  knees). Behaviour is identical either way — only the look changes.
- People are **dark silhouettes with a coloured edge**, and the colour is that
  person's identity — the same one their Site Plan dot uses. Up close (within
  45 m, nearest 12) they are a real animated figure that walks, sits to eat,
  works, dances and lies down to sleep; further away they switch to a simpler
  shape. If everyone looks like a simple capsule figure at ALL distances, the
  optional Mixamo character pack is not installed — see `ASSETS.md`. Nothing
  else changes; the simulation is identical either way.

**Source:** `core/population/` (+ `POPULATION_PLAN.md` for the design and invariants).

---

## 23. Incomplete / partial / outdated (summary)

| Item | Status | Notes |
|------|--------|-------|
| Freehand watershed paint / SoI heatmap | ❌ | Pond Preview/Designate + Site Plan/Elev outline shipped |
| Berm / Hill / Swale dock tools | ❌ | Walkthrough outdated; not in **T** UI |
| Climelapse keyframe bake | ✅ | Folded into 🎬 (`start_climelapse_export`); the separate bake button and its handler were removed on purpose |
| **P** key overload | ⚠️ | Warp / pallet / light-menu labels conflict |
| NDVI vegetation from Sentinel | ❌ | Deferred (no JP2) |
| Full ISRU catalog / PBI vision | ⚠️ | Partial vs SYSTEMS_GRAPH_VISION |
| SSAO/SSIL etc. | ⚠️ | Depends on renderer; see UX notes |
| ToolManager under Player | ✅ | `get_node_or_null` + self-heal; no boot error |
| NPC stairs / upper floors | ⚠️ | Nav supports layers; nothing GENERATES stairs or upper floors yet |
| Tagging a 3D printer as a space | ❌ | Print Setup modal has no tag row yet (it is keyed by graph item, not prop) |

---

## 24. Suggested “first play” smoke path

1. Create or open a user map → wait for terrain load.  
2. **O** on SoI pin → set radius.  
3. **G** → Site Plan → place Habitat / panels / wire; try **Radial layout** and drag a Place Model twin.  
4. Aim OSM solar (red) → **O** → confirm SolarUI + array node.  
5. **T** → Pond carve or Rain into a depression → Interact water → Add to graph.  
6. Add Hydro + high intake on Site Plan → watch head / penstock / flow.  
7. **V** paint + Tune look; **U** library browse; **N** Linkage Lab place + deploy.  
8. **J** light; **K** Site Report; ⚙ Live mode / HA if configured.  
9. Tag a kitchen / water point / restroom / sleeping space (**O** on a prop or **B** on a building), place a **Population** node, wire water + food tanks, tick **Simulated individuals**, then play — watch people walk, then **View options ▾ → Show worn paths**.  
10. **F1** whenever stuck.

---

*Generated as a living player reference. Prefer this file over Wave walkthrough key names when they disagree with `project.godot`.*
