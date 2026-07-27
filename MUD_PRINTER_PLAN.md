# Mud 3D Printer — Assessment & Improvement Plan

Polish, correctness, and expansion plan for the mud-building designer + slicer +
GRBL export (the Cursor/Grok proof-of-concept). Goal: convincing building
geometry, an accurate + inspectable slicer, and GRBL that actually runs on the
real large-format mud printer.

## Target machine (confirmed with owner)

- **Extruder drive: on/off relay.** The pump/auger switches on or off — no speed
  (S) control, no E axis. Flow is governed purely by **feedrate**. G-code emits a
  relay-on M-code when a run of extruding moves begins and a relay-off M-code
  before travels. (Default `M3`/`M5`; dialect-selectable to `M8`/`M9`.)
- **Work origin: corner (0,0 at min).** Machine homes to a corner with a positive
  work envelope. The plan is authored centered on origin, so export must translate
  so `bounds_min` → `(0,0)` (positive coords only). Center-origin stays a dialect
  toggle for other machines.

## Current architecture (the good bones)

Cleanly separated, single-responsibility files — very improvable:

| Layer | File |
|---|---|
| Params / plan primitives | `core/machines/mud_building/mud_building_spec.gd` |
| Validation / cleanup | `core/machines/mud_building/mud_plan_ops.gd` |
| Slicer (toolpath) | `core/machines/mud_building/mud_wall_slicer.gd` |
| Preview mesh + STL | `core/machines/mud_building/mud_wall_mesher.gd` |
| GRBL export | `core/machines/mud_building/mud_grbl_export.gd` |
| GRBL dialect | `core/machines/mud_building/mud_grbl_dialect.gd` |
| 2D sketch canvas | `scenes/ui/mud_plan_canvas.gd` |
| Designer modal | `scenes/ui/mud_building_designer_modal.gd` |
| Structure placer | `core/machines/mud_building/mud_building_structure_builder.gd` |
| Selftest | `core/machines/machine_selftest.gd` (`_test_mud_building`) |

One slice path feeds preview, STL, and G-code (they can't diverge); a
`parity_check` re-parses the emitted G-code. Extend `_test_mud_building` with
every change below.

## Key defects (why it's rough)

### GRBL (the "unusable" part)
1. **Emits `G1 X Y Z E<mm³>` — classic GRBL has no E axis.** The relay machine
   ignores/errors on `E`, so nothing extrudes. Must switch to relay M-codes.
2. **Coordinates go negative** (`origin_offset_mm` = 0, plan centered on origin)
   → soft-limit alarm / off-bed on a corner-homing machine.
3. **Travels never lift Z** → nozzle drags through wet walls between islands.
4. No pump prime/purge, no dwell at layer starts, no skirt/brim first layer.
5. Perimeter seam is the same XY every layer → weak vertical seam line.
6. Everything is linear `G1` — thousands of tiny segments starve the GRBL planner
   on curved walls; no arc (G2/G3) output.

### Rendering / resolution
7. Preview `SubViewport` hard-pinned to 640×640 then stretched → blurry; MSAA 2×.
8. Mesher sweeps a **rectangular** bead cross-section → blocky bricks, not the
   rounded stacked ovals of real mud beads. No layer lines, flat brown, gray void.
9. "Gyroid" is a 2D sine field modulating one infill bead — not a real gyroid.

### Toolpath accuracy
10. Offsets keep only the **single largest island** → interior holes / courtyards
    silently lost; concave inner offsets can collapse/split.
11. No first-layer skirt/brim, no seam stagger, no corner overlap, no travel hop.
12. Rebuild is **synchronous on the main thread** in `_process` (slice + mesh) →
    UI jank with zero feedback.

### UX
13. No loading feedback during rebuild.
14. Preview panel too narrow.
15. No way to inspect travels vs extrusion, no per-layer scrubbing.
16. Openings support doors only (gap from z=0 to lintel) — no windows (sill).

---

## Plan

### Phase 0 — Explicit asks + unblock GRBL (do first) — ✅ DONE
- **Loading bar.** `ProgressBar` overlay on the preview panel. Move `_rebuild_now`
  off the synchronous path — chunked build (mirror `batch_renderer` /
  `site_report_builder`) or `WorkerThreadPool`, feeding 0→1 with
  "Slicing… / Building mesh… / Ready".
- **Wider preview.** Raise preview panel `size_flags_stretch_ratio` (0.9→~1.15)
  and `custom_minimum_size` (340→~460); make `SubViewport.size` track the
  container × a supersample factor instead of the fixed 640².
- **GRBL relay extrusion.** Dialect `extrusion_mode = RELAY` (default): emit
  relay-on M-code at the start of an extruding run, relay-off before travels;
  drop the `E` word entirely. Keep `E_AXIS` + `SPINDLE_PWM` as options.
- **GRBL corner origin.** Translate so `bounds_min` → `(0,0)`; dialect toggle for
  center-origin. Verify positive envelope fits `work_x/y/z`.
- Update `parity_check` + selftest for relay/origin (no E, non-negative bounds).

### Phase 1 — GRBL correctness — ✅ DONE
- Travel Z-hop before non-adjacent travels; safe-Z first move; optional
  pump-prime dwell + purge/skirt line at print start.
- Per-layer seam stagger on the perimeter start point.
- Layer-start dwell option (relay settle time).

### Phase 2 — Rendering polish — ✅ DONE
- Rounded 8-sided elliptical bead cross-section (was rectangular) so walls read as
  stacked mud beads with grooved layer lines; authored per-vertex normals.
- Per-layer albedo banding via vertex COLOR (alt 1.0/0.9 shade); warm 3-point
  light rig (warm key / cool fill / rim), filmic tonemap + soft SSAO; MSAA 4× +
  1.25× viewport supersample (from Phase 0).

### Phase 3 — Toolpath inspector (biggest debugging win) — ✅ DONE
- "Toolpath view" toggle: solid mesh ↔ raw print path as coloured lines
  (extrusion green, travel red).
- "Travels" checkbox to show/hide non-extruding (pump-off) moves.
- Per-layer slider to scrub the toolpath by layer (layers ≤ N).

### Phase 4 — Toolpath accuracy
- Real clipper pass preserving interior holes/courtyards + multi-island results.
- Corner overlap compensation; arc fitting (G2/G3) for curved walls.
- Windows: add `sill_mm` to openings (gap active only sill→lintel).

### Phase 5 — Expansion (ambitious)
- Real infill: continuous serpentine / honeycomb between shells, density %.
- Corbelled roof / dome closure (step perimeter inward per layer past a start
  height); optional printed floor slab.
- Physical calibration: min radius vs nozzle, max overhang/reach-over warnings,
  printability check for unsupported spans; feed↔flow calibration for the auger.
- Refined print-time estimate (accel/junction deviation); `.esim`-style design save.

## Validation

Extend `core/machines/machine_selftest.gd` (`_test_mud_building`) with each
change; run:

```
Godot.exe.exe --headless --path . --import
Godot.exe.exe --headless --path . --script core/machines/machine_selftest.gd
```
