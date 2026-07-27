# Parametric Hardware Store — Build Plan

**Goal.** Bring the parametric OpenSCAD "hardware store" into SIMbiogenesis so a
player can pick a part (fan, duct base, hose reducer, cup, bowl, turbine, vase…),
adjust its parameters through an in-game panel, and export a custom STL — **without
ever leaving the game or touching OpenSCAD directly.**

**Core strategy.** Split the problem cleanly in two:

1. **Parse the Customizer parameter block ourselves** (the `//[10:300]`,
   `//[yes,no]` comments). This is a small, well-defined text-parsing job and is
   the "recreate the OpenSCAD Customizer modal" half — the easy, high-value part.
2. **Do NOT reimplement geometry.** Shell out to a bundled headless **OpenSCAD**
   binary to evaluate the CSG and produce STL
   (`openscad -o out.stl part.scad -D var=val …`). Reimplementing `linear_extrude`
   with twist/scale + `difference()` means rebuilding a scripting language *and* a
   CGAL-class boolean-mesh kernel — years of work that already exists, is open
   source, and has a CLI built for exactly this.

This mirrors patterns already in the codebase: shelling out to `ffmpeg` for
Climelapse MP4 export, and the chunked-async job pattern in `site_report_builder`
/ `batch_renderer`.

---

## Phase −1 — Credits & attribution system  ✅ (done first)

Before adding any third-party parts, stand up a durable way to track open
licenses and give credit. **Status: complete.**

- [`CREDITS.md`](CREDITS.md) — human-readable running ledger: sections
  (tools, engine/addons, ported code, SCAD parts, data sources, models, fonts),
  an add-an-entry template, a license quick-reference table, and hard rules
  (never invent a license; `-NC`/`-ND` are red flags; anything
  `pending-verification` at release is not shipped).
- [`credits/credits.json`](credits/credits.json) — machine-readable mirror that a
  future in-game credits screen + automated license audit read from. Seeded with
  every dependency already discoverable in the repo (Godot, OpenSCAD, FFmpeg,
  addons, LinkageLab port, the vase file, and all live data sources — OSM, Esri,
  Open-Meteo, OpenTopography, NASA POWER, Mapillary, Gemini).
- [`credits/licenses/`](credits/licenses/) — full verbatim license texts, named by
  SPDX id (first one due: `GPL-2.0.txt` when OpenSCAD is bundled).

**Ongoing obligation for every later phase:** each `.scad` part (and each model,
texture, font) gets a `CREDITS.md` entry + `credits.json` object at ingest time,
defaulting to `pending-verification`. The ingestion tool (Phase 2) auto-emits a
stub per file. A part with no discoverable license is **quarantined, not shipped.**

---

## Phase 0 — End-to-end vertical slice (prove the pipeline)

Prove the whole path on the **one vase file** before generalizing. Smallest thing
that renders a parametrized part in-world.

**Status (2026-07-22): pipeline built + offline-verified; awaiting the binary for
the live render.** Shipped:
- `core/scad/scad_runtime.gd` (`ScadRuntime`) — locates OpenSCAD (config →
  managed install → known dirs → PATH, mirroring `ClimelapseVideoEncoder`),
  builds type-correct `-D` args (`format_define`), invokes it via `OS.execute`,
  and hands the STL to the **existing** `StlLoader` (no new STL reader needed —
  reused `core/machines/stl_loader.gd`).
- `core/scad/scad_provisioner.gd` (`ScadProvisioner`) — on-demand/updatable
  install: versioned folders under `user://tools/openscad/<version>/` + a JSON
  manifest, native `ZIPReader` extraction, permission-gated `request_install`.
- `core/scad/scad_selftest.gd` — offline deterministic (**32 checks, passing**):
  `-D` quoting per type, graceful no-binary failure, and a synthesized-binary-STL
  → `ArrayMesh` round-trip. Added to the validation list below.
- Distribution decision locked: **not committed to git**; resolved at runtime,
  fetched on demand, updatable via versioned installs.

Remaining to close Phase 0: obtain an OpenSCAD binary, run one real vase render,
confirm the STL imports + places in-world, then flip the OpenSCAD `credits.json`
entry to verified and drop `GPL-2.0.txt` into `credits/licenses/`.

1. **Bundle/locate OpenSCAD.** Find the binary at a known path first (config +
   PATH probe), fall back to a bundled copy. Record version. Add `GPL-2.0.txt` to
   `credits/licenses/` and flip the OpenSCAD `credits.json` entry toward verified.
2. **Hardcode** the vase's parameters in a throwaway panel (no parser yet).
3. **Invoke** `openscad -o <tmp>.stl vase_20160822.scad -D radius=50 -D height=150
   -D "filling=\"no\"" …` via `OS.execute` on a background thread. Get the `-D`
   quoting right per type: numbers/bools bare, strings as escaped quotes, vectors
   as `[1,2,3]`.
4. **Import the STL** into a Godot `ArrayMesh`. Hand-roll the binary-STL reader —
   it's a trivial fixed-layout format (80-byte header, uint32 triangle count,
   50 bytes/triangle) plus a normal pass. (This *is* worth writing ourselves,
   unlike the CSG.)
5. **Place** the mesh in-world (reuse the `PlacedPropService` ghost/placement path).

**Exit criteria:** changing a hardcoded number and re-running produces a visibly
different mesh in-game. Validates subprocess + quoting + STL import + placement in
one cheap shot before investing in UI or ingestion.

---

## Phase 1 — Customizer parameter parser  ✅ (done)

Parse the OpenSCAD Customizer metadata block into a structured schema the UI can
render. This is the "recreate the modal" core.

**Status: complete.** `core/scad/scad_param_parser.gd` (`ScadParamParser`) parses
a `.scad` file into `{ok, title, params[], groups[], warnings[]}`. Over the seed
vase it extracts all **18 user parameters**, correctly **excludes the 9 calculated
values** (expression RHS = not a Customizer param), classifies widgets
(slider/stepped-slider/dropdown/checkbox/field), pulls labels from the comment
line above each var, recovers a **malformed unclosed annotation** (`//[0:600`)
with a warning, and `default_params()` yields a render-ready dict that renders
successfully end-to-end. Covered by `scad_selftest.gd` (parser + live-render
checks). A discovery worth keeping: OpenSCAD's `-D` string quoting is mangled by
Godot's `OS.execute` on Windows, so the runtime drives parameters through
OpenSCAD's **Customizer parameter-set JSON** (`-p`/`-P`) instead — the exact
mechanism this parser mirrors.

**Parsing rules** (the vase file follows all of these):
- **Scope:** only top-level `name = value;` assignments **before the first
  `module`/`function` definition** are user-facing. Everything after is
  implementation. (In the vase, all params sit above `module Rim`.)
- **Widget from the trailing `//…` comment:**
  - `//[min:max]` → slider; `//[min:step:max]` → stepped slider
  - `//[a,b,c]` → dropdown/toggle; `//[a:Label A,b:Label B]` → labeled dropdown
  - no annotation → free numeric/text field, inferred from the literal's type
- **Label/tooltip:** the `//` comment line(s) directly **above** the assignment
  ("Outer Radius of the Base in mm").
- **Groups:** `/* [Group Name] */` block comments segment the panel into sections.
- **Value type:** infer from the literal — number, bool-ish (`"yes"/"no"`), string,
  vector `[…]`.

**Deliverable:** a `ScadParamSchema` (params: name, label, type, widget, min/max/
step, options, default, group) with an offline, deterministic selftest over the
vase file (and a few hand-written edge cases) — following the project's
`*_selftest.gd` convention.

**Out of scope / known limits (document, don't solve):** OpenSCAD Customizer's
full grammar has corners (tab-based groups, `//` inside strings, computed
defaults, `$fn` specials). Parse what's common; skip/flag the rest cleanly.

---

## Phase 2 — Library ingestion & license triage  ✅ (done)

Turn "a large folder of `.scad` files" into a curated, vetted in-game catalog.

**Status: complete.** `core/scad/scad_catalog.gd` (`ScadCatalog`, pure/offline)
does the per-file work: parse schema, **detect `use`/`include` dependencies**,
infer a store **category** from filename keywords, reconcile **license status**
against `credits/credits.json` by matching the file path, and compute a final
`ready` / `usable-dev` / `quarantined` verdict (`finalize_status`). The runner
`core/scad/scad_ingest.gd` walks `scad_library/`, does a coarse **validation
render** of each file's defaults (facet counts capped for speed), writes
`scad_library/catalog.json` (full per-part schema + render stats + verdict), and
**auto-appends a `pending-verification` credits stub** to `credits/credits.json`
for any part with no ledger entry — so nothing ships uncredited (no ledger entry
→ `quarantined`; it never invents a license). First run over the seed vase:
parsed 18 params, rendered 260 tris/415 ms, matched the existing pending license →
`usable-dev`. The `ScadCatalog` logic (deps, category, license reconciliation,
verdict truth-table, stub generation) is covered by `scad_selftest.gd`.

**Note on the library in git:** `.scad` files carry per-author CC licenses that
are `pending-verification` until confirmed, so the curated library is treated like
the gitignored asset pack (`ASSETS.md`) — don't commit unverified part files to
the public repo. `catalog.json` (metadata only, no copyrighted geometry) is safe
to track if desired.

1. **Ingest tool** (offline `--script`, like the other selftests/tools): walk the
   library, run the Phase 1 parser on each file, and emit a catalog manifest
   (part id, title, thumbnail hint, param schema, source path).
2. **Dependency gate:** flag any file with `use <…>` / `include <…>` (BOSL2, MCAD,
   Write.scad…). Those need their libraries bundled too — quarantine until handled.
3. **Validation pass:** render each file once headless (default params) to confirm
   it actually produces geometry with the bundled OpenSCAD — catches broken files
   at curation time, not in front of a player.
4. **License stub emission:** for every ingested file, auto-append a
   `pending-verification` entry to `CREDITS.md` + `credits.json`. **No license →
   quarantined.** This is where the Phase −1 system earns its keep.
5. **Reality check:** report the clean-parse / needs-dependency / fails-render /
   no-license split. This tells us the true scope of "large library" before we
   commit — treat 100% auto-ingest as optimistic, not a given.

---

## Phase 2.5 — Real library seeded  ✅ (done)

Seeded the store from the external **OpenSCAD Part Library** (Thingiverse-style
`<Category>/<project>/[files/]*.scad` with adjacent `LICENSE.txt`/`README.txt`).
`core/scad/scad_import.gd` copies `.scad` by directory (siblings travel so
`include <>`s resolve), classifies the real license docs (`ScadCatalog.classify_license`
— rich "Title (URL) by AUTHOR … licensed under …" + terse "cc-nc" forms + CC URL
slugs → SPDX + NC/ND flags), extracts the README `# Summary` for UI text, and
writes real credits entries. STLs/images intentionally skipped. Result: **61 parts
across 48 categories** — 16 ready, 11 restricted (NC/ND, flagged for a licensing
decision), 34 license-pending (absent/empty license docs). Library is local +
gitignored (like the asset pack); `credits/credits.json` is the committed record.

## Phase 3 — In-game store & render pipeline  ✅ (core done)

The player-facing feature, built as its own modal in the spirit of the existing
Tune-Look / Linkage Lab / Building Builder modals. **Press `H` in a loaded map.**

**Status: core complete.**
- `core/scad/scad_store.gd` (`ScadStore`) — reads `catalog.json`; categories,
  search, per-part schema/license/description. Selftested.
- `scenes/ui/scad_store_modal.gd` — script-built full-screen modal: category/
  search browser, generated parameter panel (sliders/dropdowns/checkboxes/fields
  from the schema), **threaded async render** (OpenSCAD on a background `Thread`,
  no frame hitch), SubViewport 3D preview, **Export STL** (`user://exports/scad/`)
  and **Place in world**. License/restricted state shown per part. Wired in
  `main.gd` (`open_scad_store`, `toggle_scad_store` = H) + registered CanvasLayer.
- `core/scad/scad_part_builder.gd` (`ScadPartBuilder`, MODEL_ID `scad_part`) —
  rendered STL → placeable Node3D; dispatched by `ModelCatalog.instantiate` +
  `PlacedPropService._build_ghost`; the STL path rides in `record_extra.scad_spec`
  so a placed part survives save/reload (same mechanism as the linkage structure).
- Covered by `scad_selftest.gd` (store queries + a runtime UI-builder smoke).

**Remaining polish (not blocking):** render caching by (part+param hash),
per-slider debounced live preview, restricted-part gating in the UI, richer
studio lighting/turntable, and a visual pass (needs a windowed session).

- **Catalog browser:** categories (fans, ducts, reducers, cups, turbines…) from
  the Phase 2 manifest, with thumbnails.
- **Parameter panel:** generated from the `ScadParamSchema` — sliders, stepped
  sliders, dropdowns, toggles, numeric fields, grouped into sections. This is the
  in-game OpenSCAD Customizer.
- **Async render:** on "Generate" (**debounced**, not live per-tick — CGAL renders
  of twisted/scaled extrusions take real seconds), run OpenSCAD on a background
  thread with a **timeout + process-kill** safety net and a "rendering…" spinner.
  Reuse the poll/callback shape of `site_report_builder` / `batch_renderer`.
- **Preview + place:** import the STL (Phase 0 reader), preview in a SubViewport
  studio, then place in-world and/or **export the STL** to `user://` for real
  printing. Show the part's attribution line from `credits.json` in the modal.

**UX guardrails:** cache renders by (part + param hash) so re-opening is instant;
cap simultaneous renders; surface OpenSCAD stderr as a friendly error, not a hang.

---

## Phase 4 (stretch) — Player-uploaded `.scad` files

Only after the curated store is solid.

- Let players drop their own `.scad` into `user://` and get the same panel.
- **Security:** this is untrusted-code execution. OpenSCAD's language can loop,
  recurse, and read files via `import()`. The killable-subprocess-with-timeout
  from Phase 3 contains most of it, but treat this as its own hardening pass
  (resource caps, sandbox the working dir, no network). Scope as a later phase,
  never the v1 target.
- Uploaded files are the user's own responsibility for licensing — don't auto-add
  them to `CREDITS.md` (that ledger is for what *we* redistribute).

---

## Cross-cutting concerns

- **Distribution size:** OpenSCAD + its Qt/CGAL tree is ~100–150 MB. Real but not
  prohibitive; consider an optional download (like the asset pack) vs. baked-in.
- **Platform:** plan is Windows-first (matches dev env). OpenSCAD is
  cross-platform; keep the invocation path abstracted so Linux/Mac builds can
  swap the binary.
- **Licensing (recap):** unmodified bundled OpenSCAD binary via CLI = mere
  aggregation, does not affect our MIT code — but ship its GPL-2.0 text. Each
  `.scad` carries its author's own CC license; honor per-part (Phase −1 system).
- **Validation:** every phase adds an offline `*_selftest.gd` where it can
  (parser, ingest manifest, STL reader round-trip) per project convention; the
  render/subprocess step needs the real binary so it's a windowed/manual smoke.

## Suggested order of execution

Phase −1 (done) → Phase 0 vertical slice → Phase 1 parser → Phase 2 ingest+triage
→ Phase 3 store UI → Phase 4 uploads (stretch). Phases 0–1 are cheap and derisk
everything; Phase 2's library audit tells us the real scope before Phase 3's UI
investment.
