# Vegetation Scatter

Implements **Option 1 + Option 2** from the design discussion: a
`MultiMeshInstance3D` of crossed-quad shrubs procedurally placed where the
photogrammetric terrain texture looks like vegetation, combined with a
per-pixel terrain overlay shader that tufts up the dark/green areas of the
ground itself.

## What's in this folder

| File | Role |
| --- | --- |
| `vegetation_scatter.gd` | `@tool` script. Bakes the scatter, generates the procedural shrub mesh + texture + material, applies the terrain overlay at runtime. |
| `vegetation_scatter.tscn` | Scene wrapping the script. Already instanced in `main- maybe unstable.tscn`. |
| `foliage.gdshader` | Shader for the shrub cards. TAA-safe dithered alpha test, wind sway, double-sided lighting, fake bottom-AO. |
| `terrain_overlay.gdshader` | Shader applied to the 51 terrain surfaces at runtime. Reads the same vegetation classifier as the scatter, then adds bump + roughness + speckle on matching pixels. |
| `baked/` *(generated)* | Output of the bake: shrub mesh / texture / material and the scatter `MultiMesh`. Commit if you want others to skip the bake step. |

## First-time usage

1. Open `main- maybe unstable.tscn` in the editor.
2. Select the `VegetationScatter` node in the scene tree (added at the scene
   root).
3. In the Inspector, scroll down to **Actions** and tick **Bake Now**.
4. Watch the Output panel: it logs progress like
   `[VegetationScatter]  3/51  Mesh_001  +428 instances (running total 1230)`.
   On a typical machine the bake takes a few seconds to a minute depending on
   `density`.
5. The checkbox auto-clears when the bake finishes. The viewport should now
   show shrubs scattered over the terrain.
6. Run the game. The terrain overlay applies automatically on `_ready()`.

## Tuning knobs (Inspector)

**Vegetation Classifier**

The classifier is `luma < luma_threshold  AND  g - max(r, b) > green_excess`.

- `luma_threshold` — Pixels brighter than this are not considered vegetation. Desert vegetation is typically luma 0.30–0.55, bare sand 0.60+. Lower if shrubs are being placed on bare dirt; raise if dark shadows are being mistaken for shrubs.
- `green_excess` — Hue strictness. `> 0` demands a clear green channel; `= 0` allows neutral darks (catches shadows); `< 0` allows olive/sage where green is slightly less than red or blue. Default -0.01 works for dry desert scrub. Raise to filter out neutral shadows; lower if vegetation is brownish.
- `min_surface_up` — Surface-normal cosine. Triangles whose normal Y is below this are skipped; default 0.45 ≈ 63° slope, which rejects cliffs.

**If the first bake produces 0 instances**, run **Diagnose Textures** (Actions group). It prints the actual luma and hue distribution of every terrain texture and tells you what thresholds would admit 5/10/20/30% of pixels. See the "Diagnose" section below.

**Scatter**
- `density` — Candidate samples per m² of (filtered) surface. Tune this first; each candidate has roughly a 5–30 % chance of passing the classifier, so the actual instance count is `area * density * pass_rate`.
- `ground_anchor_offset` — Push card bases slightly into the ground so there's no visible sliver of empty air beneath them.
- `align_to_surface` — Off by default; in valley terrain, real shrubs grow upright regardless of slope, and upright cards read more natural.

**Manual Editing**
- `exclusion_volumes` — NodePaths to box-shaped `Node3D` / cube volumes. Any candidate inside one is removed from the bake. Use these to clear open spaces or roads.
- `inclusion_volumes` — NodePaths to box-shaped volumes where shrubs are allowed or forced. If `include_volumes_bypass_classifier` is enabled, candidates inside these boxes can place shrubs even when the texture classifier rejects the pixel.
- `require_include_below_height` + `include_required_below_height` — If enabled, any candidate below this world-Y height must be inside an inclusion volume. This is useful for keeping the valley floor mostly clear while still allowing hand-designated low shrub patches.

Volume setup: create a `Node3D` or visible `MeshInstance3D` cube, scale/rotate it over the area, then assign its NodePath in the Inspector. The volume test treats the node's local `-0.5..+0.5` cube as the editable box, so a default CubeMesh scaled in the editor is a good visual helper.

## Auto-vegetation (generated maps)

OSM woodland polygons above ~1.2 ha (configurable in **V → Style drawer → Forest ha**) route to **forest zones**: a shared horizontal canopy mesh with dappled shadow holes plus sparse walkable trunks, instead of thousands of card instances.

- **Paint forest** (V-mode toolbar): user-painted forest zones persist in `user://maps/auto_veg_edits_*.json`.
- **Building / Road clearance** sliders expand OSM exclusion buffers so trees stay off structures and roads.
- Deciduous bulk cards use split **bark + foliage** materials (crisp trunks, soft canopy dither).
- Style settings persist per map via `VegetationStyleConfig` (`user://maps/vegetation_style_*.json`).

Self-test: `godot --headless --path . --script vegetation/auto_vegetation_selftest.gd`

**Shrub Look**
- `shrub_min_scale` / `shrub_max_scale` — Per-axis random scale range.
- `card_width` / `card_height` — Base size of the procedural card mesh. Toggle `Rebuild Shrub Assets` after changing these.

**Rendering**
- `visibility_range_begin` / `visibility_range_end` — Per-instance fade distances. Multimesh-aware; the cull is cheap. Defaults of 140 / 260 m are tuned for ridge views into a valley; raise if your ridges are farther out.
- `cast_shadows` — Off by default. Alpha-tested shadow maps on tens of thousands of cards are expensive; the terrain overlay sells the close-up.

**Editor Preview**
- `show_editor_preview` — Shows a lightweight green-dot preview of the baked placements in the 3D editor viewport and hides the full shrub cards in editor only. Runtime rendering is unchanged.
- `editor_preview_max_points` — Caps the number of preview dots so editor navigation stays responsive.
- `editor_preview_dot_size` — Size of each preview cube.

**Terrain Overlay**
- `apply_terrain_overlay` — Toggle to disable Option 2 while keeping the scatter.
- `overlay_fuzz_strength` — Strength of the bump perturbation on vegetation pixels.
- `overlay_fuzz_scale` — Noise tiles per metre. 4 ≈ 25 cm features.
- `overlay_albedo_tint` — How much to darken vegetation pixels (0 = no change).
- `overlay_terrain_roughness` / `overlay_vegetation_roughness` — Roughness on bare ground vs vegetation. Vegetation should be high (matte).

## Diagnose

Tick the **Diagnose Textures** action to sample every terrain surface (default 2000 random pixels each) and dump a report to the Output panel. Per-surface, you'll see:

```
[0.0] Geom3D  get_image+decompress, 4096x4096 RGBA8
       luma:  min=0.043  max=0.812  mean=0.392
       hue (g - max(r,b)):  min=-0.083  max=+0.071  mean=-0.014
       passing luma<0.50 only:   62.3%   passing both:    7.4%
```

The line "**passing luma<X only**" tells you what fraction of pixels are dark enough. "**passing both**" includes the green-excess filter. If the first is non-zero but the second is zero, your `green_excess` is too high — try lowering it (or going negative).

At the bottom, the report prints quantile hints:

```
luma_threshold value that admits this % of sampled pixels: 5% -> 0.187, 10% -> 0.230, 20% -> 0.291, 30% -> 0.340
green_excess value that admits this % of sampled pixels: 5% -> +0.041, 10% -> +0.023, 20% -> +0.005, 30% -> -0.011
```

Pick a `luma_threshold` whose admit-rate is in the 5–20% range. For `green_excess`, the quantiles describe what value lets the top X% of pixels through, so smaller numbers admit more.

### "All surfaces had no readable image"

If Diagnose reports `IMAGE FAILED - get_image() returned null/empty` on every surface and the source-PNG fallback also failed, the texture import probably stripped the CPU image and we couldn't find a matching source file. Fixes:

1. Set `source_texture_search_root` to the folder that contains the source PNG/JPG atlas pages. Default is `res://Imported Models/Soak Terrain/`.
2. Make sure the source PNG files are actually present in your project (they should be — Godot needs them to re-import).
3. If neither works, re-import the textures with `Compress > Mode = Lossless` so the CPU image is retained. Right-click the textures in the FileSystem dock → Reimport with this setting changed.

## Force-pass mode

The **Force Classifier Pass** toggle bypasses the colour classifier entirely — every candidate that passes the geometry filters (triangle area, slope) gets a shrub. Use this to verify the rest of the pipeline (image extraction, transform stacking, MultiMesh upload) is working when you're not sure whether the issue is classifier vs everything else.

## Re-baking

Re-tick **Bake Now** any time you:
- Re-import the `Soak site 3.glb`.
- Change `luma_threshold`, `green_excess`, `density`, `seed_value`, scale
  range, or any classifier knob.
- Move the `VegetationScatter` node itself in world space.

You **don't** need to re-bake when you change:
- Visibility range, cast shadows, terrain overlay parameters (these apply on
  `_ready` from inspector values, no transforms need re-emitting).

## Re-building shrub assets only

If you only change `card_width` / `card_height` or want to swap the procedural
texture algorithm, tick **Rebuild Shrub Assets** instead of running a full
bake. This regenerates `baked/shrub_*.{tres,res}` without re-scanning the
terrain.

## How it works (one paragraph)

The `bake()` method walks every `MeshInstance3D` under `target_terrain`, calls
`mesh.surface_get_arrays()` on each surface to get its vertex / UV / index
buffers, and `material.albedo_texture.get_image()` to get its atlas page.
For each triangle it generates `area * density` candidate points with random
barycentrics, interpolates the UV, reads the pixel, runs the
luma + green-excess classifier, and if the pixel passes, emits a
`Transform3D` (world position, random Y rotation, random scale). All
transforms are packed into a single `MultiMesh` saved to disk. At runtime,
`_ready()` loads the multimesh into a `MultiMeshInstance3D` child and calls
`_apply_terrain_overlay()` which walks the same mesh tree and replaces each
surface's `BaseMaterial3D` with a `ShaderMaterial` wrapping the original
albedo texture and our overlay shader. The classifier is the same in both
places (GDScript + GLSL), so the cards line up with the shaded ground tufts.

## Performance

- One draw call for the entire scatter (MultiMesh).
- The terrain overlay is one extra fragment-shader pass per terrain surface
  with one extra `value_noise` per pixel — negligible on a Forward+ desktop
  pipeline.
- Bake time: order ~5–30 seconds depending on density. Editor-only.
- Memory: ~80 bytes per instance (one `Transform3D`). 50 k shrubs ≈ 4 MB.

## Known limitations

- The classifier sees photographic bake-light, so shadowed bare ground may be
  flagged as vegetation. Tune `green_excess` to reject neutral darks.
- Adjacent atlas pages with different colour calibration can produce hard
  edges in the scatter density. If you see this, raise `luma_threshold` or
  re-bake the GLB textures with consistent exposure.
- Wind sway is not motion-vector aware, so very strong sway can ghost under
  TAA. The default `wind_strength = 0.03` is below the threshold where this
  is visible.
- The bake reads textures via `Image.decompress()`, which works for the
  S3TC/ETC2 imports used by this project. If you switch to BPTC HDR or some
  other format, verify the decompress path still works.
