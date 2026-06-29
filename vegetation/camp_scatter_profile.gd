@tool
extends Resource
class_name CampScatterProfile

## Per-class configuration for the camp scatter tool. Drives both heuristic
## detection (which blobs in the aerial belong to this class) and how each
## accepted candidate is materialised on the map.

## Internal identifier for this class. Must match the `class_id` used on your
## CampStamp markers. Keep it lowercase with underscores: popup_tent, rv, car…
@export var class_id : StringName = &"popup_tent"
## Human-readable label shown in diagnostics and JSON export.
@export var display_name : String = "Popup Tent"
## PackedScene to instantiate for each placed candidate. Supports complex
## prefabs with lights, colliders, and child nodes. Leave null to use the
## faster MultiMesh path (set `use_multimesh = true` in Rendering).
@export var scene : PackedScene
## Colour of the fallback box mesh shown when `scene` and `multimesh_mesh` are
## both null. Also used for the editor preview dot colour for this class.
@export var fallback_color : Color = Color( 0.95, 0.95, 0.95, 1.0 )
## Size (X, Y, Z) in metres of the fallback box used when no mesh or scene is
## assigned. Gives a rough visual stand-in during layout.
@export var fallback_size : Vector3 = Vector3( 3.0, 2.5, 3.0 )

@export_group( "Mask Heuristics" )
## Minimum luminance (0–1) a pixel must have to be considered part of this class.
## Luminance = 0.299·R + 0.587·G + 0.114·B.  White objects → high min_luma.
@export_range( 0.0, 1.0, 0.01 ) var min_luma : float = 0.55
## Maximum luminance. Dark objects (shadows, black vehicles) → low max_luma.
@export_range( 0.0, 1.0, 0.01 ) var max_luma : float = 1.0
## Minimum HSV saturation. High saturation = vivid colour. White/grey → ~0.
@export_range( 0.0, 1.0, 0.01 ) var min_saturation : float = 0.0
## Maximum HSV saturation. Use a low max to exclude colourful vegetation/flags.
@export_range( 0.0, 1.0, 0.01 ) var max_saturation : float = 0.35
## Minimum HSV value (brightness). Usually leave at 0 unless filtering shadows.
@export_range( 0.0, 1.0, 0.01 ) var min_value : float = 0.0
## Maximum HSV value. Rarely needs to be below 1.
@export_range( 0.0, 1.0, 0.01 ) var max_value : float = 1.0

@export_group( "Shape Heuristics" )
## Minimum real-world area in m² for a blob to be accepted as this class.
## Popup tent (~9 m²), RV (~20 m²), car (~8 m²). Reject anything smaller.
@export_range( 0.1, 2000.0, 0.1 ) var min_area_m2 : float = 4.0
## Maximum real-world area. Rejects huge clumps that are clearly not individual objects.
@export_range( 0.1, 4000.0, 0.1 ) var max_area_m2 : float = 80.0
## Minimum width/length aspect ratio. 1.0 = square; lower values allow thin slivers.
@export_range( 0.1, 20.0, 0.05 ) var min_aspect_ratio : float = 0.4
## Maximum aspect ratio. An RV might be ~3:1 so set this above 3 for RVs.
@export_range( 0.1, 20.0, 0.05 ) var max_aspect_ratio : float = 2.5
## Blobs that pass the size/aspect filters but whose composite confidence score
## is below this threshold are discarded. Lower = more results, more noise.
@export_range( 0.0, 1.0, 0.01 ) var confidence_threshold : float = 0.40
## Minimum centre-to-centre distance (metres) between instances of THIS class.
## Works alongside the global `minimum_spacing_radius` in CampScatter.
@export_range( 0.0, 20.0, 0.05 ) var spacing_radius : float = 1.8

@export_group( "Orientation" )
## Expected real-world rectangle this object occupies, in metres (length × width).
## Used to score detections (size match) and to snap auto-oriented stamps.
## Set to (0, 0) to skip the size-match scoring.
## Examples: 10×10 popup tent → (3.05, 3.05);  10×20 carport → (3.05, 6.10);
## Class-A motorhome → (~8.5, ~2.6);  sedan → (~4.6, ~1.8).
@export var expected_footprint_size : Vector2 = Vector2.ZERO
## When the detected blob's aspect ratio is below `min_aspect_for_oriented`,
## the long axis is ambiguous. Enable this to assign a random yaw instead.
@export var random_yaw_when_square : bool = false
## Aspect ratios below this value are treated as "square" for the rule above.
## 1.15 means any blob less than ~15% longer than wide gets a random yaw.
@export_range( 1.0, 4.0, 0.01 ) var min_aspect_for_oriented : float = 1.15
## Snaps the detected heading to the nearest multiple of this angle in degrees.
## 0 = no snap. Try 5 for soft snapping, 90 for strict grid-aligned objects.
@export_range( 0.0, 90.0, 0.5 ) var orientation_snap_degrees : float = 0.0
## Random ±jitter added to the snapped heading in degrees. Adds organic variety.
@export_range( 0.0, 180.0, 1.0 ) var max_yaw_jitter_degrees : float = 0.0

@export_group( "Placement" )
## Vertical offset (metres) added to the terrain-raycast Y position when placing
## this class. Use a small positive value if meshes clip into the ground.
@export_range( -5.0, 5.0, 0.01 ) var y_offset : float = 0.0
## Tilt each instance to match the terrain surface normal at its placement point.
## Useful for large objects on sloped terrain. Requires a physics collision body.
@export var align_to_surface_normal : bool = false

@export_group( "Rendering" )
## When enabled, all instances of this class share a single MultiMeshInstance3D.
## Much faster for hundreds of identical meshes. Disable when your prefab has
## extra child nodes (lights, colliders, scripts) that must be separate nodes.
@export var use_multimesh : bool = false
## Mesh drawn by the MultiMesh renderer. If null, a fallback coloured BoxMesh
## is used so you can see placements even without art assigned.
@export var multimesh_mesh : Mesh
## Disable if this class never needs to cast shadows (e.g. flat ground decals).
@export var cast_shadows : bool = true
