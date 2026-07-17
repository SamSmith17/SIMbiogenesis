# Waves 1–5 Walkthrough

How to use and test the wishlist work shipped in Waves 1–5.  
Includes **new** behavior and features that **already existed** but may not have been obvious.

Hotkeys used below: **G** system graph · **T** terrain edit · **C** camp scatter · **V** vegetation · **P** placed props · **J** place light · **M** location picker (in-game) · **Interact** (default E / project `interact` action).

---

## Wave 1 — UI layout polish

### Thinner timeline
**What changed:** Timeline bar chrome is shorter (`INFO_ROW_HEIGHT` 56, less bottom pad). Side docks that clear the timeline use the updated stack height.

**How to test:**
1. Boot any map.
2. Confirm the bottom timeline is slimmer and still usable (date, play/pause, scrub).
3. Open **G** (graph) and **P** (placed props) — docks should sit above the bar, not under it.

### Graph sidebars meet the timeline
**What changed:** Left/right graph sidebars already inset above the timeline; Wave 1 made their scroll content expand to fill that height.

**Already present — empty click → library:**
1. Press **G**.
2. Place or select any node.
3. **Single-click empty canvas** (not on a node/wire).
4. Expect: selection clears, right sidebar returns to **Library**.

**How to test sidebars:**
1. Open graph; open left (telemetry) and right (Library/Inspector) sidebars.
2. Confirm bottoms align with the top of the timeline (no dead band / cutoff).

### Library view style
**What changed:** Category headers and item buttons are cleaner (rounded rows, clearer hover/pressed, taller hit targets).

**How to test:** Open graph → right **Library** tab → expand a category → hover/click items.

### Place-edit drawer (horizontal, timeline height)
**What changed:** Placed-prop editor is a slim bottom bar (X/Y/Z/Yaw/Pitch/Roll/Scale in a row) instead of a tall vertical drawer. Includes **Move**, **Apply**, **Delete**.

**How to test:**
1. **P** → place a structure, or Interact on an existing placed prop.
2. Edit drawer should match roughly timeline height.
3. Tweak spins → live preview; **Apply** commits; **X** closes.

### SolarUI hidden when no solar
**What changed:** Top-left Power / Solar panel is **fully hidden** until the graph has solar (panels or imported array). Previously it stayed as a collapsed “No solar…” bar.

**How to test:**
1. Fresh graph with no panels → no SolarUI.
2. Add a panel from the library **or** Interact-add an OSM array → SolarUI appears.
3. Remove all solar → it hides again.

### Map select cleanups
**What changed:**
- Removed **Advanced terrain size** from the launch / location picker.
- Removed in-game **Terrain extent** rebuild section from Terrain options.
- YOUR WORLDS list is taller/scrollable; action buttons stay on-screen.

**How to test (launch hub):**
1. Run the project → map select / launch scene.
2. Confirm no Advanced terrain size expander.
3. Scroll YOUR WORLDS; confirm **Start selected**, **Create map here**, **Add StarShade** remain visible and clickable at the bottom.
4. In-game: Terrain options (▸) should not show World / Hi-res DEM / OSM extent spins.

---

## Wave 2 — Config & content fixes

### Mission 1 = power only
**What changed:** Challenge **Keep the Lights On** no longer fails on food/water/starvation. Starter graph seeds AC + grid import only (no food/water tanks).

**How to test:**
1. Timeline → **🎯 Challenges** → **Keep the Lights On**.
2. Open graph: expect power/habitat AC nodes, **not** food/water catchments for this mission.
3. Run: fail condition is AC down > ~30 min, not empty water/food.

### PBI nodes always present + locked
**What changed:** Fundamental PBI / catchment library nodes are seeded on graph init and cannot be deleted (`locked` / `fundamental`).

**How to test:**
1. Open graph on a generated map (or after graph init).
2. Find PBI / fundamental resource nodes in the library / canvas.
3. Select one → Delete / Backspace — should refuse removal.
4. Reload graph / new session — they reappear if missing.

### Field / lawn OSM veg off by default
**What changed:** Auto-scatter skips lawn/field/meadow-style grass kinds unless `style.scatter_lawn_field` is opted in.

**How to test:**
1. Load a site with OSM grass/meadow (or a known grassy area).
2. Expect trees/scrub where tagged, **not** a default green lawn carpet everywhere.
3. (Advanced) Set `scatter_lawn_field` in vegetation style if you want the old behavior back.

### Per-map Delete + Load from cache
**What changed:** Each YOUR WORLDS row has selection, **Load from cache** checkbox, and **Delete** (user maps only).

**How to test:**
1. Launch hub → YOUR WORLDS.
2. Toggle **Load from cache** on a user map → reload that map; DEM/imagery should prefer cache (uncheck to force refetch).
3. **Delete** a `user://maps` world → row disappears; built-in maps should refuse delete.

### StarShade IBC look
**What changed:** Brighter green IBC glow; cage meshes render gray/opaque for night silhouette.

**How to test:** Place/import StarShade → night time (scrub timeline) → bright green tank glow + gray cage silhouette.

### Add StarShade button
**What changed:** Launch / builder **Add StarShade** queues/places the V1 catalog model (`starshade`), not the old broken bundle-only path.

**How to test:**
1. Launch hub → **Add StarShade** → **Create map here** (or Start a map) → model should appear / place on load.
2. In-game Building Builder Library → **Add StarShade** → ghost placement of V1 model.

---

## Wave 3 — Solar array intelligence

### OSM solar imports as one array node
**What changed:** Interact-add OSM solar creates a single **array compound** node (true panel count / watts / tag), not up to 48 separate panel nodes.

**How to test:**
1. Load a site with OSM `power=generator` solar (or known arrays).
2. Aim crosshair at a red-highlightable array → **Interact**.
3. Open **G**: one array node keyed by tag; re-Interact should replace that array, not duplicate forever.

### Area tiling + module dimensions
**What changed:** Panel W/H/watts/gaps drive footprint tiling (`SolarArrayBuilder`). Inspector can retile an array from stored footprint + module dims.

**How to test:**
1. Import an OSM array.
2. Select array → Inspector → **Module Dimensions** → change size → **Retile**.
3. Panel count should update to max that fit; 3D / watts specs stay consistent.

### Auto-wire within controller Voc limits
**What changed:** After import, the array is auto-wired (series×parallel) under the chosen/nearest controller’s `max_voc`.

**How to test:**
1. Have a controller on the graph (or let import place a recommended preset).
2. Import OSM solar → check wires from array `+/-` to controller PV ports.
3. Over-Voc configs should still fault (education overlay / destroyed) if forced past limits — same Voc system as before.

### Controller picker
**What changed:** Combine menu **Pick controller for array…** ranks controllers by Voc fit + distance; can place a recommended preset if none fit. Import flow can open the same picker (bulk SoI may auto-wire without dialog).

**How to test:**
1. Select an array (and optionally panels).
2. Toolbar **Combine ▾** → **Pick controller for array…**.
3. Pick a row → wires update; or accept “place recommended”.

**Already present — manual series/parallel wire:**
1. Marquee-select multiple **panel** nodes.
2. Combine → **Wire panels in Series / Parallel** (nearest controller).
3. Useful for hand-built arrays; OSM path now prefers the array + auto-wire flow above.

---

## Wave 4 — Placement & interaction

### Place edit → Move (click-to-reposition + camera follow)
**What changed:** Edit drawer **Move** calls `begin_prop_reposition`: aim with crosshair, LMB confirm, Esc cancel; camera follows on XZ.

**How to test:**
1. Interact a placed prop → **Move**.
2. Look around — prop (or ghost) follows ground under aim; camera tracks.
3. LMB places; Esc aborts.

**Already present — Alt+drag grab:** Hold Alt while focusing a prop and drag (grab controller) — still works; Move is the explicit edit-drawer path with follow-cam.

### Light place fix
**What changed:** Interact on a placed light opens `UILayer/PlacedLightModal` (path was wrong). Clearer dual-sphere ghost/gizmo; modal **Brightness** (+ color).

**How to test:**
1. **J** → aim → LMB place a light.
2. Interact the light → modal: brightness + color.
3. Confirm gizmo spheres are visible while editing/aiming.

### IBC SOC → 10-level battery glow
**What changed:** IBC glow reads battery SOC (SolarUI / graph average). Ten discrete levels; **green >50%**, **yellow >30%**, **red ≤30%**. Night + power-available still gate visibility.

**How to test:**
1. StarShade (or IBC) + graph battery with solar.
2. Scrub time / drain–charge SOC.
3. Glow steps through levels and hue bands like a charging battery icon.

### Camp scatter shapes + Advanced
**What changed:** Camp tools add **Circle** and **Polygon** (shared veg paint helpers). Advanced: plot depth, scatter step, light LOD, billboard light density.

**How to test:**
1. **C** (or Terrain options → Edit camps).
2. Draw Rect / Lasso / Circle / Polygon → generate.
3. Open Advanced sliders → regenerate; density/LOD of camp lights should change.

**Already present — veg paint shapes:** **V** dock still has Paint/Clear/Select with Circle/Rect/Lasso/Polygon — camp now matches that selection language.

### Deeper zoom (map + site plan)
**What changed:** World map `MAX_ZOOM` raised (~56); graph Site Plan zoom max raised; SoI preview can orbit closer.

**How to test:**
1. Launch hub world map — scroll-zoom further into a city block.
2. Graph Site / Elevation / SoI preview — zoom in tighter for placement.

### Model footprint → site plan chip
**What changed:** Placing/binding a 3D model stamps `footprint_w_m` / `footprint_d_m` from mesh AABB × scale.

**How to test:** Place a catalog structure linked to a graph node → Site Plan chip size matches the model’s plan footprint.

### Icon replaces node frame
**What changed:** Nodes with a `model_id` (or icon-replace flag) draw the icon/model preview as the node itself; ports + selection glow remain.

**How to test:** Open graph → model-bound nodes should look like icons, not emoji-in-a-box. Select — ports still work.

---

## Wave 5 — Terrain, ponds, watershed, hydro

### Earthwork: 45° view + berm / hill / swale + smoother level
**What changed:** Terrain edit defaults to **45°** ortho (toggle **90°**). New ops: **Berm**, **Hill**, **Swale**. **Level** still uses falloff and adds perimeter smoothing.

**How to test:**
1. **T** → drag a selection rect.
2. Toggle 45° / 90° camera.
3. Try Raise/Lower/Level, then Berm / Hill / Swale — heightfield rebuilds underfoot.
4. Level a noisy patch — edges should feather more cleanly.

### Ponds as catchment + storage
**What changed:** Still water (OSM lake/pond) or a sculpted basin can become a graph **catchment + water tank** (`osm_water_tag` idempotent). Capacity ≈ area × depth heuristic.

**How to test:**
1. Aim at still water → prompt → **Interact** → **Add pond to graph**.
2. Or **T** → select basin → **Add pond**.
3. Open **G**: catchment + storage; re-add same tag should not duplicate.

### Watershed analysis (foundation)
**What changed:** D8 flow on the composed DEM (`Watershed` + loader cache). API for basin / upstream area / flow path; hydro can use upstream area.

**How to test (play):**
1. After terrain loads, place hydro + high intake; upstream area can influence design flow when precip data exists.
2. Offline:  
   `Godot.exe.exe --headless --path . --script core/terrain/watershed_selftest.gd`

**Note:** Full “paint micro-watersheds like solar overlay” visualization may still be thin — analysis + hydro coupling are the Wave 5 foundation.

### Hydro head / penstock / flow from terrain
**What changed:** Graph tick injects derived **gross head** from elevations, auto **penstock_length_m** from site XY distance, optional **design_flow_lps** from watershed upstream × rain.

**How to test:**
1. Graph: water tank/catchment at high site elev + hydro at lower elev (Site/Elevation modes).
2. Connect intake → hydro; confirm inspector/specs show derived head and penstock length after tick.
3. With watershed ready + weather, flow estimate may update (not only a fixed L/s).

**Already present — HydroSource physics:** Library hydro node still uses Paish / Darcy–Weisbach; Wave 5 wires terrain elevation + catchment area into those specs.

---

## Quick regression checklist (Waves 1–5)

| Area | Smoke check |
|------|-------------|
| Launch hub | YOUR WORLDS scroll + **Start selected** / **Create map here** visible |
| Timeline | Slimmer bar; docks clear it |
| Graph | Empty click → Library; PBI locked; SolarUI only with solar |
| OSM solar | Interact → one array + auto-wire / picker |
| Props | Edit HBox + **Move** + camera follow |
| Lights | **J** place → Interact → brightness/color modal |
| IBC | SOC bands green/yellow/red at night |
| Camps | **C** Circle/Polygon + Advanced |
| Terrain | **T** 45° + berm/hill/swale |
| Pond | Interact water → catchment+tank on graph |
| Challenge 1 | Power-only fail rules |

### Headless selftests (optional)

```text
C:\Users\notsa\Downloads\Godot\Godot.exe.exe --headless --path . --import
C:\Users\notsa\Downloads\Godot\Godot.exe.exe --headless --path . --script core/terrain/terrain_selftest.gd
C:\Users\notsa\Downloads\Godot\Godot.exe.exe --headless --path . --script core/terrain/watershed_selftest.gd
C:\Users\notsa\Downloads\Godot\Godot.exe.exe --headless --path . --script system_graph/graph_electrical_selftest.gd
C:\Users\notsa\Downloads\Godot\Godot.exe.exe --headless --path . --script gameplay/challenge_selftest.gd
```

---

## Already-implemented features (wishlist items that were not greenfield)

These were on the wishlist but largely already in the build; Wave work polished or documented them:

| Wishlist item | How to use / test |
|---------------|-------------------|
| Empty canvas deselect → library | **G** → select node → click empty canvas |
| Graph sidebars above timeline | Already inset; Wave 1 filled height |
| OSM area→panel tiling (3D) | Arrays always tiled in world; Wave 3 exposed dims + graph retile |
| Manual PV series/parallel wire | Select panels → Combine → Wire Series/Parallel |
| Alt+drag prop move | Alt + focus + drag (Move button is the new guided path) |
| Veg Circle/Rect/Lasso/Polygon | **V** dock (camp **C** now mirrors this) |
| Terrain Level/Raise/Lower | **T** (Wave 5 added berm/hill/swale + 45°) |
| Hydro physics node | Library → Hydro; Wave 5 adds terrain head/penstock/Q |
| Roof catchment import | Interact building / existing catchment import (ponds are the new water-body path) |

---

## Out of scope here (later waves)

Waves 6–10 (veg species pack, Stellarium trails, connectors, node port tagging, Godot 4.7, etc.) are **not** covered — roadmap paused after Wave 5.
