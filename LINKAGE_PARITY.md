# LinkageLab parity

The game's Linkage Lab (`core/linkage/`) is a GDScript port of the LinkageLab web
app (`../LinkageLab`). This file tracks what the port covers against LinkageLab
**`main`**, how the reference fixtures are made, and where the two deliberately
differ. Plan: `~/.claude/plans/i-ve-made-some-significant-parallel-riddle.md`.

## Reference commit

LinkageLab `main` @ `e11e875ed415dbd87badc4b5ed928c80d6508cbb`
("Part view: free hand placement with push-stacking and snap"). Every fixture
records the SHA it was generated from, and `linkage_selftest` checks they all
agree with the shipped `ll_*` presets.

## Regenerating

```bash
node tools/linkage_parity_dump.mjs ../LinkageLab main
```

- Exports the ref with `git archive` into `%TEMP%\linkage_parity_<sha>` and never
  touches the sibling working tree. That repo's `node_modules` is junctioned in,
  so run `npm install` there once first.
- Runs a generated vitest spec inside the JS repo's own test environment
  (happy-dom + `tests/setup.js`), so the code runs exactly as the JS suite runs
  it.
  - The one stub it replaces is `getOptimalClosedAngleForAnimation`. The setup
    pins it to 0 (a flat ring), but the app deploys at the real closed angle.
- Writes `core/linkage/testdata/parity/<preset>.json` and
  `core/linkage/presets/ll_<preset>.json`.
- **Three environment traps** (each made the JS side differ from the real app,
  with no error):
  1. The state comes from `app-state.js`'s real defaults, deep-copied, NOT from
     `tests/helpers/state-fixture.js`. The fixture lacks
     `vBoltInnerLength`/`vBoltOuterLength`, so JS fell back to the full V-bolt
     length and drilled holes the app never drills.
  2. `tests/setup.js` mocks `hwResolveStructureSpacing` to the legacy gaps.
     Importing the real `hw-structure-spacing.js` bridges the real resolver back
     in, so full-detail designs get their assembly-driven gaps (0.0625 not 0.1)
     and bracket.
  3. `getOptimalClosedAngleForAnimation` is stubbed to 0 (see above).

Each fixture holds:

| Section | Contents |
|---|---|
| Fold angles | saved, folded, deployed, and the assembly pose the generator uses |
| `saved` / `deployed` | solve stats and part keys (`collectParts`) |
| `radialArray` | the radial-array plan |
| `coverings`, `floor`, `shade` | counts |
| `bench` | the bench plan (`planBench(groupBeamsForBench)`) |
| `generatedSteps` | `generateDefaultBuildSteps`, ids stripped, as the app's Auto-generate calls it |
| `savedSteps` | the design's own steps, normalised |
| `holes` | `getBeamBoltIntersections` per beam of the first array copy |

## Presets

| File | Name | Notes |
|---|---|---|
| `ll_starshade_v1_soak_2026.json` | StarShade V1 - SOAK 2026 (LinkageLab) | renamed: the game's default has the same name |
| `ll_starshade_2x3_folding_panels.json` | StarShade 2x3 - Folding Panels | folding panels |
| `ll_starshade_hex.json` | StarShade Hex | coverings, floor deck, shade, 94 build steps |
| `ll_stellarator.json` | Stellarator | 63 build steps |
| `ll_constellation.json` | Constellation | 6-slot radial array (slot 3 hidden), 94 build steps |

Presets keep every config key except the export snapshots
(`LinkageParams.DERIVED_EXPORT_KEYS`), plus a `linkagelabSource {file, sha}`
stamp.

**`starshade_soak_2026.json` (the Lab's default) is not regenerated.**
- It carries hand-corrected values:
  - `panels.gridRotation` is 22.5°; the JS file has 0°;
  - `supportBeams.rcpEndOffset` is 1.3; the JS file has 1.25.
- It also rounds a few bracket and electrical numbers (bracket height 3.8 vs
  3.82, hole distance 2.7 vs 2.69).
- `linkage_selftest` and the hardware placement references pin these values.
- **Open check:** confirm whether the 22.5° grid correction still holds against
  current JS geometry. In JS, the 2x3 preset uses −22.5° and the SOAK preset
  0°. This lands with A3 / A4 panel work.

## Config round trip (A0, done)

`LinkageParams.to_config(from_config(x))` returns every key of `x` with an
equal value.
- Keys the port does not model yet ride `LinkageParams.extra`: `buildSteps`,
  `coverings`, `floor`, `shadeCloth`, `ibc`, `mode.radialArray`,
  `mode.sequentialFold`, the camera pose, panel `presetId` / `formFactor` /
  folding keys, newer `costs`, and support-beam RCP kinematics keys.
- Typed fields win over `extra`.
- `name` / `designName` map to `design_name`.
- Legacy flat (v29) configs keep no extras.

Pinned by `_test_lossless_presets` and `_test_parity_fixtures` in
`core/linkage/linkage_selftest.gd`.

## Part identity (A1, done)

`LinkagePartKeys` (`core/linkage/linkage_part_keys.gd`) is a port of
`part-keys.js`. It covers keys, joint keys, labels, selectors (web camelCase,
since they are config data), resolution and bounds.
- `LinkagePartKeys.part_data(p, fold)` builds the parts the web app would
  collect.
  - The solver still emits every simple bracket and bolt, because
    `LinkageHwPlacement` seats the detailed assemblies on those brackets.
  - The web's representation switch is applied here instead: an enabled
    assembly replaces its brackets, bolts and washers with placements.
  - Its asymmetries are kept (the h-pivot inner bolt and the bottom-inner V
    washers are never replaced).
  - Assembly enablement follows the web's `hwAssemblyEnabled`, which honours
    `detailed`. The game's `LinkageHardware.use_full_detail` does not.
- The solver gained the identity fields `layer_index`, `ring`, `role`, `cap` and
  `gap_index`, plus washers. These are additive: every pinned value is
  unchanged.
- `linkage_selftest._test_part_keys_parity` compares the multisets of keys and
  joint keys per preset. Since A4 nothing is excluded (`PARITY_NOT_YET` is
  empty): floor beams, every covering / deck / tarp ("wall" parts), the rcp
  bolts and every radial copy all equal JS.
- Known divergence: the JS arch transform leaves washers in the cylinder frame.
  The game moves them with their bolts.

## Radial array (A3, done)

- `LinkageRadialArray` (`core/linkage/linkage_radial_array.gd`), a port of
  `radial-array.js`:
  - the plan is measured on the DEPLOYED pose and cached per design (fold
    excluded), so the copies fold in place;
  - `apply(plan, geo, slot_geo)` copies every part list into each visible
    slot, in slot order. `array_index = slot × linear + a`, and panels are
    renumbered across copies, as the web numbers them;
  - `LinkagePartKeys.part_data`, `LinkageBeamHoles.drill_solve` and the
    builder all apply it, so keys, holes, steps and rendering agree.
  - Pinned: the Constellation plan's slot offsets and `max_rad` equal the
    fixture; part keys of every copy equal JS (`_test_part_keys_parity`).
- **BOM** (`LinkageBom.compute`): one structure's bill (`per_structure`) times
  `copies.total` = visible radial copies × arch tunnel segments
  (`structure_copies`). Unit prices are unchanged. Arch panels are divided
  back to one segment's share. `dims.pattern_diameter_in` is the whole
  pattern. With one structure the result is unchanged apart from the two new
  keys.
- **Solar handoff**: `deployed_panel_summary` counts every copy's panels.
  The average normal spans the pattern's real orientations.
- **Shipping**: `packed_spec_for` returns one structure's folded envelope and
  mass with `count` = visible radial copies.
- **Sequential fold** (`LinkageFoldSequence`, a port of `fold-sequence.js`):
  - `mode.sequentialFold` makes the fold angle a master progress: copy j
    of K folds by `clamp(p·K − j, 0, 1)`, centre first, then the ring by slot;
  - the builder solves once per distinct angle (at most three) and keeps
    copies in slot order;
  - `fold_schedule()` exposes the schedule.
  - Not ported: arch tunnel segments folding one at a time. The web solves
    them with `arrayCount 1` and replicates each segment.
- **Lab**: a collapsed "Radial Array" sidebar group (enable, copies, centre,
  rotate, auto radius / radius, spacing, start angle, spin, height offset,
  hidden slots, one-at-a-time), with a readout of the copies and the pattern
  size. `--capture=buildsteps` drives it on Constellation (hide a slot,
  sequential mid-fold, untick).

## Coverings, floor deck, shade tarps (A4, done)

All under `core/linkage/coverings/` plus `core/linkage/linkage_floor.gd`,
pinned by `linkage_coverings_selftest.gd` (`EXPECTED_CHECKS`) and
`linkage_selftest._test_floor_parity` against the dump's `a4` block (one
structure's floor beams, deck, covering shapes, tarps, cut plan and BOM rows,
compared relative to an anchor both frames share).
- `LinkageFloor`: reciprocal (and optional radial) floor beams on the bottom
  ring (stack types `floor-beam*`, they join `beams` after the supports as
  the web appends them), the deck polygon and record, seating and BOM rows.
- `LinkageCoverings`: uprights, spans, per-band wall planes (inward /
  outward / vertical / custom lean), trapezoid walls and fabric bands with
  the mount offset and the beam-clearance warning, and tables.
- `LinkageShadeCloth`: one tarp per module, coverage on a 48 × 48 grid, size
  groups.
- `LinkageEnclosure` is the ONE aggregator (deck → coverings → tarps, the
  web's order). `part_data`, the builder and `LinkageBom` all ask it.
- Records are covering dicts in snake_case: `corners` / `slab_corners`,
  `corners_2d` (Vector2 s, t), `plane`. They key as `wall:s<span>:<band>`.
  `LinkageRadialArray.clone_part` carries `corners`, `slab_corners`, `plane`
  and `y_top` / `y_bottom` to each copy.
- Config keys `floor`, `coverings`, `shadeCloth` ride `LinkageParams.extra`
  in the web's camelCase. The enclosure prices (`plywoodSheet`, `fabricYard`,
  `grommet`, `shadeCloth`) ride `extra.costs` (`LinkageCoveringPlan.price`).
- Rendering: `FloorBeams` MultiMesh; one keyed MeshInstance3D per covering
  under `Coverings` (plywood, canvas, or the tarp's colour and opacity),
  hidden / moved by part state, so the build steps stage them. The deck and
  walls go into the collision mesh.
- BOM: floor beam rows in STRUCTURE (`floor_kg` in the mass chart); an
  ENCLOSURE section (plywood sheets, fabric yards, grommets, tarps) in the
  total, times copies. The Build Guide lists every piece and writes the cut
  files (`export_cut_files`).
- Lab: "Raised Floor", "Coverings (Walls / Tables / Fabric)" and "Roof Shade
  Tarps" groups, with a per-span lower / upper / table grid. Controls are read
  over the normalised config, so hidden keys survive, and nothing is written
  for a design that never had the feature.
- Not ported: the inline wall overview SVG (the guide lists sizes instead);
  plywood as its own shipping unit in `packed_spec_for`.

## Build steps (A2, done)

All under `core/linkage/build/`, pinned by `linkage_build_steps_selftest.gd`
(`EXPECTED_CHECKS`):
- `LinkageBuildSteps`, a port of `build-steps.js`. It covers the step model
  (camelCase, since steps are config data and ride `LinkageParams.extra`;
  accessors are `get_build_steps` / `set_build_steps`), groups, staging
  visibility and parking, bench planning, and the auto-generator.
  - `generate_for(p)` is the app's Auto-generate. Its output equals JS on all
    five presets, every step and its timing, including the floor, covering
    and tarp steps (since A4):
    - exactly on SOAK, Hex, Stellarator and Constellation;
    - 2x3 differs in drill grouping only, at one ill-conditioned crossing (see
      below).
  - The presets' own saved steps normalize identically, and every selector
    resolves to the same number of parts as in JS.
- `LinkageBeamHoles`, a port of `getBeamBoltIntersections`, plus the drill
  solve (legacy bolts, detail off).
- `LinkageGeometry.reciprocal_support_bolts`, a port of
  `generateReciprocalSupportBolts`, static placement only. These bolts are not
  solver bolts, so bolt counts, the BOM and packing are untouched.
- `LinkageBuildOps`: the place / cut / drill / fasten drivers as pure
  functions of progress.
  - `stage(step, ctx)` returns a plan; `place_at` / `cut_at` / `drill_at` /
    `fasten_at` return the tool pose and every part's state.
  - Assembly ops work in the structure frame; bench ops in the bench frame
    (`plan_bench`).
  - The Lab player (A5) and the NPC timeline (B4) both read these.

Two JS behaviours are reproduced deliberately:
- `Array.sort` is stable; ties carry their insertion index.
- `toFixed` rounds an exact tie up (`LinkageBuildSteps.js_fixed`); 1/16 and 1/64
  inch values hit exact ties.
- A JS quirk is also kept: `eachModule` steps keep their UNFILTERED selectors
  (rest-spread order), so a cap selector stays on modules without caps.

Known limit:
- A crossing of two nearly collinear reciprocal beams is ill-conditioned.
  Float32 `Vector3` beam endpoints move it about 0.03 in, which can tip one
  hole into the next 1/16 in bucket of the drill-pattern signature (2x3: one
  beam, 94.44 vs 94.5 in).
- Hole positions are pinned at 1/32 in. The JS generator merges holes at
  1/16 in.

## Step player (A5, done)

- `LinkageStepScene.frame(steps, index, t, ctx)` is the web's
  `applyBuildStepScene` plus its op drivers as a pure function. It returns
  the part statuses (future parts hidden), the parked offsets after the step,
  the fold of the last view at or before the step, the workbench for bench
  steps (the structure is hidden), the tool on its op path, and the focus.
- `LinkageStepPlayer` is the engine (transition, op, hold; repeat mode
  "skip" or "fast") and the renderer in the Lab studio. It is a sibling of
  the builder and takes the builder's transform.
- The Lab's **🎬 Steps** dock lists the steps, with a group shown as one row
  "× N". It has transport controls, a scrubber, speed, repeats and Follow
  camera. Step title, notes and duration are editable, steps can be moved,
  duplicated and deleted. **Auto-generate** and **Save to design** write
  `buildSteps` into the config, so the steps export with it. **NPC
  animation…** opens the crew clip for the step's kind.
- The Build Guide has a "Build Sequence" card: the representative steps,
  their notes, and a crew-of-9 rehearsal time.
- Joint hardware the builder draws its own way (simple brackets, bolts,
  washers) follows its JOINT. It shows when a part of that joint that a step
  introduces shows. Hardware on a joint that no step introduces waits for the
  last step; otherwise the "unreferenced" washers hung over the empty site.
- Not ported:
  - picking step targets in 3D (selectors stay as generated or imported);
  - camera keys (`view` yaw / pitch / dist; the player frames each step's
    focus instead);
  - per-step thumbnails;
  - the WebM / PDF export (the game has an ffmpeg MP4 exporter for the world
    camera; a Lab-studio video path is not wired).

## Feature checklist

| JS feature (module) | Game | Phase |
|---|---|---|
| Solver, kinematics, closed angle | ported, pinned | — |
| Hardware detail, stack layout, placement | ported, pinned (v2 layout) | — |
| Hardware stack layout v3, free hand placement (`hw-stack-layout.js`, `hw-snap.js`) | round-trips, not modelled | later |
| Config v30, lossless | done | A0 |
| Part identity (`part-keys.js`) → `LinkagePartKeys` | **done**: keys + joint keys == JS on all 5 presets | A1 |
| Per-part rendering (show, hide, offset by key) | **done**: `LinkageStructureBuilder.set_part_state` | A1 |
| Washers (`createWashersForBolt`) | **done**: solved and drawn | A1 |
| Build steps model + generator (`build-steps.js`) → `LinkageBuildSteps` | **done**: generator == JS on all 5 presets | A2 |
| Bench plan, stock lengths, hole dedupe | **done** | A2 |
| Bolt / beam intersections → `LinkageBeamHoles` | **done**: every beam's holes == JS (1/32 in) | A2 |
| Reciprocal support bolts (`rcp-ring` / `rcp-cross`) | **done**: keys + places == JS | A2 |
| Tool ops: saw, drill, place, fasten → `LinkageBuildOps` | **done**: pure resolvers, timing pinned by hand | A2 |
| Radial array, hidden slots (`radial-array.js`) → `LinkageRadialArray` | **done**: plan == JS, every copy's part keys == JS, Lab group | A3 |
| Array BOM (`bom.js` copies) | **done**: per-structure × copies | A3 |
| Sequential fold (`fold-sequence.js`) → `LinkageFoldSequence` | **done** for radial arrays; arch tunnel segments still fold together | A3 |
| Pack layout (`pack-layout.js`) | replaced: a radial design ships one folded bundle per copy (`PackedSpec.count`); the IBC column is a glTF-export detail | A3 |
| Coverings (`coverings-geometry.js`) → `LinkageCoverings` | **done**: every wall / fabric band / table == JS on all presets | A4 |
| Sheet nesting, fabric patterns, cut plan → `LinkageSheetNesting` / `LinkageFabricPattern` / `LinkageCoveringPlan` | **done**: plan totals, per-wall nests, enclosure BOM == JS | A4 |
| SVG cut files (`svg-cut-file.js`) → `LinkageSvgCutFile` | **done**: sheet cuts, fabric patterns, tarp layout (Build Guide export); the inline wall overview is not ported | A4 |
| Floor deck, floor beams (`floor-geometry.js`) → `LinkageFloor` | **done**: beams, deck, seating, BOM == JS | A4 |
| Shade cloth (`shade-cloth.js`) → `LinkageShadeCloth` | **done**: tarps, coverage, sizes, BOM == JS | A4 |
| Build-step player (`build-steps-anim.js`) → `LinkageStepScene` / `LinkageStepPlayer` + Lab 🎬 Steps | **done** (no 3D target picking, no camera keys) | A5 |
| Guide export with steps (`build-steps-export.js`) | guide card done; PDF / video not | A5 |
| IBC totes, deploy preview / timeline, circuit, sky model | not planned | — |
