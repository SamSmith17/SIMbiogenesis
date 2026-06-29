@tool
extends Node3D
class_name VegetationScatter

## VegetationScatter
##
## Procedurally scatters foliage cards over the photogrammetric `Soak site 3`
## terrain and applies a per-pixel vegetation-aware overlay shader to that same
## terrain. Two systems wired into one node:
##
##   Option 1 - Scatter (editor-time bake):
##     Walks every MeshInstance3D descendant of `target_terrain`, samples each
##     surface's albedo image triangle-by-triangle, classifies pixels as
##     vegetation (dark AND green-biased), and emits a Transform3D into a
##     MultiMesh that draws crossed-quad shrubs. Output saved to disk so the
##     runtime cost is just loading the resource.
##
##   Option 2 - Terrain overlay (runtime apply):
##     Replaces each terrain surface's BaseMaterial3D with a ShaderMaterial
##     that wraps the original albedo and adds bump + roughness + speckle on
##     pixels matching the same vegetation classifier. No file writes, just a
##     per-surface material override at _ready.
##
## Usage:
##   1. Instance this scene as a child of the main scene root.
##   2. Set `target_terrain` to the terrain node (default `../Soak site 3`).
##   3. Toggle `bake_now` in the inspector to run the bake (once).
##   4. Run the game - the bake output loads automatically and the terrain
##      overlay applies on _ready.
##
## Re-bake whenever the terrain or classifier thresholds change.

const BAKED_DIR : String = "res://vegetation/baked/"
const SHRUB_TEXTURE_PATH : String = BAKED_DIR + "shrub_albedo.res"
const SHRUB_MESH_PATH : String = BAKED_DIR + "shrub_mesh.tres"
const SHRUB_MATERIAL_PATH : String = BAKED_DIR + "shrub_material.tres"
const SCATTER_MULTIMESH_PATH : String = BAKED_DIR + "scatter_multimesh.tres"
const FOLIAGE_SHADER_PATH : String = "res://vegetation/foliage.gdshader"
const TERRAIN_OVERLAY_SHADER_PATH : String = "res://vegetation/terrain_overlay.gdshader"

@export_group( "Target" )
## Node whose MeshInstance3D descendants are scanned for vegetation pixels.
## Usually `../Soak site 3` when this node is a sibling of the terrain.
@export var target_terrain : NodePath = NodePath( "../Soak site 3" )
## Directory containing the source PNG / JPG atlas pages for the terrain.
## Used as a CPU-readable fallback when `Texture2D.get_image()` returns nothing
## (which is common for VRAM-compressed imported textures). Leave empty to
## disable the fallback.
@export_dir var source_texture_search_root : String = "res://Imported Models/Soak Terrain/"

@export_group( "Vegetation Classifier" )
## Pixels darker than this luma (0..1) count as vegetation candidates. Tight
## values (~0.30) keep only the dark canopy + shrub shadow; loose values
## (~0.55) also catch mid-tone grass. Run **Diagnose Textures** for stats.
@export_range( 0.0, 1.0, 0.01 ) var luma_threshold : float = 0.30
## Required `G - max(R, B)` value. Positive numbers demand a clear green tint;
## zero allows neutral darks (catches shadows); negative allows olive/brown
## where green is slightly *less* than red/blue (sage, dry desert scrub).
@export_range( -0.2, 0.2, 0.005 ) var green_excess : float = 0.01
## Minimum chroma (`max(R,G,B) - min(R,G,B)`) required. Excludes neutral dark
## pixels (rock shadows, dirt) that pass luma + green_excess by accident. Set
## to 0 to disable; ~0.04 keeps only pixels with visible saturated colour.
@export_range( 0.0, 0.5, 0.005 ) var min_chroma : float = 0.04
## Discard triangles whose surface normal Y is below this. Vegetation rarely
## grows on near-vertical cliffs; this prevents shrubs floating on rock faces.
@export_range( 0.0, 1.0, 0.01 ) var min_surface_up : float = 0.45
## Skip any candidate placement whose world-space Y is below this height.
## Use this to keep shrubs off a flat valley floor when the floor's texture
## happens to contain dark/green pixels (grass shadows etc.). World units.
@export_range( -1000.0, 1000.0, 0.1 ) var min_world_height : float = -1000.0

@export_group( "Manual Editing" )
## Box-shaped Node3D volumes that remove shrubs from a bake. A default CubeMesh
## scaled in the editor works well: the local box is -0.5..+0.5 on each axis.
@export var exclusion_volumes : Array[ NodePath ] = []
## Box-shaped Node3D volumes that mark where shrubs are allowed or forced.
## Exclusion volumes win if a point is inside both include and exclude.
@export var inclusion_volumes : Array[ NodePath ] = []
## If true, pixels inside inclusion volumes place shrubs even when the texture
## classifier rejects them. Useful for manually adding shrub patches.
@export var include_volumes_bypass_classifier : bool = true
## Fraction of shrub candidates inside an inclusion volume that are actually
## placed. 1.0 = full density, 0.2 = sparse. Combines with the global density.
## Reducing this prevents the obvious rectangular look of a box volume.
@export_range( 0.01, 1.0, 0.01 ) var include_volume_density : float = 0.5
## How much of the volume's interior is used for density feathering (0..1).
## 0 = hard box edge; 0.4 = outer 40% of the box fades from full to zero
## density so the boundary dissolves naturally into the surrounding scatter.
@export_range( 0.0, 1.0, 0.05 ) var include_volume_edge_falloff : float = 0.4
## If true, candidates below include_required_below_height must be inside an
## inclusion volume. This keeps low valley-floor false positives out while
## still letting you manually add low shrubs where you want them.
@export var require_include_below_height : bool = false
@export_range( -1000.0, 1000.0, 0.1 ) var include_required_below_height : float = 1.0

@export_group( "Scatter" )
## Candidate samples per square metre of (filtered) terrain surface.
## Each candidate that passes the classifier becomes one shrub instance.
@export_range( 0.1, 20.0, 0.1 ) var density : float = 2.5
## Vertical offset (m) applied to placed shrubs. Slightly negative sinks the
## card base into the ground so there is no visible floating sliver.
@export_range( -5.0, 0.5, 0.05 ) var ground_anchor_offset : float = -0.05
## If true, rotate each shrub so its up-axis follows the terrain normal.
## Off by default - upright shrubs read more naturally on rolling terrain.
@export var align_to_surface : bool = false
@export var seed_value : int = 1337

@export_group( "Shrub Look" )
@export var shrub_min_scale : Vector3 = Vector3( 0.7, 0.7, 0.7 )
@export var shrub_max_scale : Vector3 = Vector3( 1.3, 1.6, 1.3 )
## Card width and height in metres at scale=1. Tune to the shrub size you want
## relative to your terrain; 0.9 x 0.7 reads as low desert scrub.
@export_range( 0.2, 4.0, 0.05 ) var card_width : float = 0.9
@export_range( 0.2, 4.0, 0.05 ) var card_height : float = 0.7

@export_group( "Rendering" )
## Shrubs begin fading out at this camera distance (metres). Set to 0 for no
## minimum - shrubs are always visible up close.
@export_range( 0.0, 1500.0, 5.0 ) var visibility_range_begin : float = 0.0
## Shrubs are fully invisible beyond this distance. 0 = unlimited.
## 350 m covers ridge-to-valley views while keeping the draw budget reasonable.
@export_range( 0.0, 1500.0, 5.0 ) var visibility_range_end : float = 0.0
## Cast shadows from the shrubs. Off by default - alpha-tested shadow maps are
## expensive on tens of thousands of cards, and the terrain overlay already
## sells "this ground is shrubby" close-up.
@export var cast_shadows : bool = false

@export_group( "Terrain Overlay" )
## Apply Option 2's per-pixel vegetation shader to the terrain at runtime.
@export var apply_terrain_overlay : bool = true
@export_range( 0.0, 1.0, 0.01 ) var overlay_fuzz_strength : float = 0.35
@export_range( 0.1, 20.0, 0.1 ) var overlay_fuzz_scale : float = 4.0
@export_range( 0.0, 1.0, 0.01 ) var overlay_albedo_tint : float = 0.15
@export_range( 0.0, 1.0, 0.01 ) var overlay_terrain_roughness : float = 0.75
@export_range( 0.0, 1.0, 0.01 ) var overlay_vegetation_roughness : float = 0.95

@export_group( "Editor Preview" )
## Show a lightweight dot preview of the baked scatter in the editor viewport.
## This hides the full shrub cards in editor only; runtime rendering is unchanged.
@export var show_editor_preview : bool = true : set = _set_show_editor_preview
@export_range( 100, 200000, 100 ) var editor_preview_max_points : int = 8000
@export_range( 0.05, 5.0, 0.05 ) var editor_preview_dot_size : float = 0.35

@export_group( "Actions" )
## Tick this checkbox in the inspector to run a fresh bake. Resets to false
## after the bake completes. Editor-only.
@export var bake_now : bool = false : set = _set_bake_now
## Tick to regenerate only the procedural shrub mesh + albedo texture. Useful
## after changing card_width / card_height. Editor-only.
@export var rebuild_shrub_assets : bool = false : set = _set_rebuild_shrub_assets
## Tick to scan all terrain surfaces and print a per-surface report of image
## status, luma + hue distribution, and how many pixels pass the current
## classifier thresholds. Use this when a bake returns 0 instances to figure
## out which thresholds to use. Editor-only, no side effects.
@export var diagnose_textures : bool = false : set = _set_diagnose_textures
## When a diagnose runs, this many random pixels are sampled per surface.
@export_range( 100, 20000, 100 ) var diagnose_samples_per_surface : int = 2000
## Bypass the classifier entirely (place a shrub at every candidate that
## passes the geometry filters). Use this to verify the rest of the pipeline
## works when the classifier seems to reject everything.
@export var force_classifier_pass : bool = false
## Dump the raw type and length of every Mesh.ARRAY_* slot for the first
## MeshInstance3D surface found under target_terrain. Use this when samples=0
## to determine which array check is silently skipping geometry.
@export var probe_mesh_arrays : bool = false : set = _set_probe_mesh_arrays
## Last successful bake instance count (read-only, just for the inspector).
@export var last_bake_count : int = 0

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

var _multimesh_instance : MultiMeshInstance3D = null
var _preview_instance : MultiMeshInstance3D = null
var _overlay_applied : bool = false

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void :
	# In the editor, set up the visible multimesh child so the user can see
	# previously-baked scatter in the 3D viewport without re-running anything.
	_ensure_multimesh_child()
	_refresh_multimesh_child()

	if Engine.is_editor_hint() :
		return

	if apply_terrain_overlay :
		# Defer one frame so the imported terrain has finished entering the
		# tree before we walk it.
		call_deferred( "_apply_terrain_overlay" )

# ---------------------------------------------------------------------------
# Inspector toggle setters
# ---------------------------------------------------------------------------

func _set_bake_now( value : bool ) -> void :
	bake_now = false
	if value and Engine.is_editor_hint() :
		bake()

func _set_rebuild_shrub_assets( value : bool ) -> void :
	rebuild_shrub_assets = false
	if value and Engine.is_editor_hint() :
		_ensure_baked_dir()
		_generate_shrub_texture( true )
		_generate_shrub_mesh( true )
		_generate_shrub_material( true )
		_refresh_multimesh_child()
		print( "[VegetationScatter] Rebuilt shrub assets." )

func _set_diagnose_textures( value : bool ) -> void :
	diagnose_textures = false
	if value and Engine.is_editor_hint() :
		diagnose()

func _set_probe_mesh_arrays( value : bool ) -> void :
	probe_mesh_arrays = false
	if value and Engine.is_editor_hint() :
		_probe_mesh_arrays()

func _set_show_editor_preview( value : bool ) -> void :
	show_editor_preview = value
	if Engine.is_editor_hint() :
		_refresh_multimesh_child()

func _probe_mesh_arrays() -> void :
	var terrain : Node = get_node_or_null( target_terrain )
	if terrain == null :
		push_error( "[VegetationScatter] probe: terrain not found" )
		return
	var mesh_instances : Array[ MeshInstance3D ] = []
	_collect_mesh_instances( terrain, mesh_instances )
	if mesh_instances.is_empty() :
		print( "[probe] No MeshInstance3D found under terrain." )
		return
	# Probe the first three surfaces so we can see any pattern.
	print( "==== Mesh Array Probe ====" )
	var probed : int = 0
	for mi in mesh_instances :
		if mi.mesh == null :
			continue
		for surface_idx in mi.mesh.get_surface_count() :
			print( "--- %s  surface %d ---" % [ mi.name, surface_idx ] )
			print( "  mesh class       : %s" % mi.mesh.get_class() )
			var arrays : Array = mi.mesh.surface_get_arrays( surface_idx )
			print( "  arrays.size()    : %d  (Mesh.ARRAY_MAX = %d)" % [ arrays.size(), Mesh.ARRAY_MAX ] )
			if arrays.size() < Mesh.ARRAY_MAX :
				print( "  !! arrays smaller than ARRAY_MAX - this surface would be SKIPPED" )
				probed += 1
				if probed >= 3 :
					return
				continue
			for slot_idx in Mesh.ARRAY_MAX :
				var slot : Variant = arrays[ slot_idx ]
				var type_name : String = type_string( typeof( slot ) )
				var length : int = -1
				if slot is Array :
					length = ( slot as Array ).size()
				elif slot is PackedVector3Array :
					length = ( slot as PackedVector3Array ).size()
				elif slot is PackedVector2Array :
					length = ( slot as PackedVector2Array ).size()
				elif slot is PackedInt32Array :
					length = ( slot as PackedInt32Array ).size()
				elif slot is PackedFloat32Array :
					length = ( slot as PackedFloat32Array ).size()
				elif slot is PackedByteArray :
					length = ( slot as PackedByteArray ).size()
				var label : String = _array_slot_name( slot_idx )
				if slot == null :
					print( "  [%2d] %-20s  NULL" % [ slot_idx, label ] )
				else :
					print( "  [%2d] %-20s  %s  len=%d" % [ slot_idx, label, type_name, length ] )
			probed += 1
			if probed >= 3 :
				print( "==== (stopped after 3 surfaces) ====" )
				return
	print( "==== Probe complete ====" )

func _array_slot_name( idx : int ) -> String :
	match idx :
		Mesh.ARRAY_VERTEX       : return "VERTEX"
		Mesh.ARRAY_NORMAL       : return "NORMAL"
		Mesh.ARRAY_TANGENT      : return "TANGENT"
		Mesh.ARRAY_COLOR        : return "COLOR"
		Mesh.ARRAY_TEX_UV       : return "TEX_UV (UV0)"
		Mesh.ARRAY_TEX_UV2      : return "TEX_UV2 (UV1)"
		Mesh.ARRAY_CUSTOM0      : return "CUSTOM0"
		Mesh.ARRAY_CUSTOM1      : return "CUSTOM1"
		Mesh.ARRAY_CUSTOM2      : return "CUSTOM2"
		Mesh.ARRAY_CUSTOM3      : return "CUSTOM3"
		Mesh.ARRAY_BONES        : return "BONES"
		Mesh.ARRAY_WEIGHTS      : return "WEIGHTS"
		Mesh.ARRAY_INDEX        : return "INDEX"
	return "slot_%d" % idx

# ---------------------------------------------------------------------------
# Bake
# ---------------------------------------------------------------------------

## Returns the effective density, guarding against zero from @tool hot-reload.
func _effective_density() -> float :
	return density if density > 0.0 else 2.5

## Returns the effective luma threshold, guarding against zero from @tool hot-reload.
func _effective_luma_threshold() -> float :
	return luma_threshold if luma_threshold > 0.0 else 0.50

## Returns the effective green_excess; negative is valid, so only guard 0.0 that
## looks like a hot-reload zero-init by treating it as the safe default.
func _effective_green_excess() -> float :
	return green_excess

## Returns the effective shrub_min_scale, guarding against zero-vectors from @tool hot-reload.
func _effective_shrub_min_scale() -> Vector3 :
	if shrub_min_scale.length_squared() < 0.001 :
		return Vector3( 0.7, 0.7, 0.7 )
	return shrub_min_scale

## Returns the effective shrub_max_scale, guarding against zero-vectors from @tool hot-reload.
func _effective_shrub_max_scale() -> Vector3 :
	if shrub_max_scale.length_squared() < 0.001 :
		return Vector3( 1.3, 1.6, 1.3 )
	return shrub_max_scale

## Returns the effective card_width, guarding against zero from @tool hot-reload.
func _effective_card_width() -> float :
	return card_width if card_width > 0.05 else 0.9

## Returns the effective card_height, guarding against zero from @tool hot-reload.
func _effective_card_height() -> float :
	return card_height if card_height > 0.05 else 0.7

## Prints all live export values so the Output panel shows exactly what the
## running instance is using. Call this at the start of bake/diagnose.
func _print_settings() -> void :
	print( "[VegetationScatter] ---- live settings ----" )
	print( "  target_terrain        : %s" % target_terrain )
	print( "  density               : %.3f  (effective: %.3f)" % [ density, _effective_density() ] )
	print( "  luma_threshold        : %.3f  (effective: %.3f)" % [ luma_threshold, _effective_luma_threshold() ] )
	print( "  green_excess          : %.3f  (effective: %.3f)" % [ green_excess, _effective_green_excess() ] )
	print( "  min_chroma            : %.3f" % min_chroma )
	print( "  min_surface_up        : %.3f" % min_surface_up )
	print( "  min_world_height      : %.2f" % min_world_height )
	print( "  exclusion_volumes     : %d" % exclusion_volumes.size() )
	print( "  inclusion_volumes     : %d  (bypass classifier: %s)" % [ inclusion_volumes.size(), include_volumes_bypass_classifier ] )
	print( "  require_include_below : %s  (height: %.2f)" % [ require_include_below_height, include_required_below_height ] )
	print( "  force_classifier_pass : %s" % force_classifier_pass )
	print( "  diagnose_samples/surf : %d  (effective: %d)" % [ int( diagnose_samples_per_surface ), maxi( diagnose_samples_per_surface, 500 ) ] )
	print( "  seed_value            : %d" % seed_value )
	var eff_min := _effective_shrub_min_scale()
	var eff_max := _effective_shrub_max_scale()
	var raw_ok  := shrub_min_scale.length_squared() > 0.001
	print( "  shrub_min_scale       : %s  (effective: %s)%s" % [
		str( shrub_min_scale ), str( eff_min ),
		"  *** WAS ZERO - hot-reload? Will use default ***" if not raw_ok else "" ] )
	print( "  shrub_max_scale       : %s  (effective: %s)" % [ str( shrub_max_scale ), str( eff_max ) ] )
	var cw_ok := card_width > 0.05
	var ch_ok := card_height > 0.05
	print( "  card_width            : %.3f  (effective: %.3f)%s" % [
		card_width, _effective_card_width(),
		"  *** WAS ZERO - mesh cache will be force-regenerated ***" if not cw_ok else "" ] )
	print( "  card_height           : %.3f  (effective: %.3f)%s" % [
		card_height, _effective_card_height(),
		"  *** WAS ZERO - mesh cache will be force-regenerated ***" if not ch_ok else "" ] )
	print( "[VegetationScatter] -----------------------" )

func bake() -> void :
	_ensure_baked_dir()
	var terrain : Node = get_node_or_null( target_terrain )
	if terrain == null :
		push_error( "[VegetationScatter] target_terrain '%s' not found" % target_terrain )
		return

	_print_settings()

	# Always force-regenerate shrub assets so a stale cached zero-size mesh
	# (from a previous hot-reload zero-init run) never silently persists.
	_generate_shrub_texture( true )
	_generate_shrub_mesh( true )
	_generate_shrub_material( true )

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var transforms : Array[ Transform3D ] = []
	var to_local : Transform3D = global_transform.affine_inverse()

	var mesh_instances : Array[ MeshInstance3D ] = []
	_collect_mesh_instances( terrain, mesh_instances )
	print( "[VegetationScatter] Scanning %d MeshInstance3D surfaces under '%s'..." % [ mesh_instances.size(), terrain.name ] )

	var total_surfaces : int = 0
	var processed : int = 0
	for mi in mesh_instances :
		if mi.mesh != null :
			total_surfaces += mi.mesh.get_surface_count()

	var surface_idx_global : int = 0
	var samples_taken_total : int = 0
	var samples_passed_classifier_total : int = 0
	var surfaces_with_image : int = 0
	var surfaces_without_image : int = 0
	for mi in mesh_instances :
		var stats : Dictionary = {
			"samples_taken": 0,
			"samples_passed_classifier": 0,
			"samples_passed_geometry": 0,
			"surfaces_with_image": 0,
			"surfaces_without_image": 0,
			"image_diagnostics": [],
		}
		var before : int = transforms.size()
		_process_mesh_instance( mi, rng, to_local, transforms, stats )
		var added : int = transforms.size() - before
		processed += 1
		if mi.mesh != null :
			surface_idx_global += mi.mesh.get_surface_count()
		samples_taken_total += stats.samples_taken
		samples_passed_classifier_total += stats.samples_passed_classifier
		surfaces_with_image += stats.surfaces_with_image
		surfaces_without_image += stats.surfaces_without_image
		var diag_summary : String = ""
		for img_diag : String in stats.image_diagnostics :
			diag_summary += " [" + img_diag + "]"
		print( "[VegetationScatter]  %d/%d  %s  +%d instances  samples %d -> classifier %d -> placed %d%s" % [
			processed,
			mesh_instances.size(),
			mi.name,
			added,
			stats.samples_taken,
			stats.samples_passed_classifier,
			added,
			diag_summary,
		] )

	last_bake_count = transforms.size()
	print( "[VegetationScatter] Bake complete. %d instances across %d surfaces (surfaces with image: %d, without: %d, total samples taken: %d, samples passing classifier: %d)." % [
		last_bake_count,
		total_surfaces,
		surfaces_with_image,
		surfaces_without_image,
		samples_taken_total,
		samples_passed_classifier_total,
	] )

	if last_bake_count == 0 :
		if surfaces_without_image > 0 and surfaces_with_image == 0 :
			push_warning( "[VegetationScatter] All %d surfaces produced no readable image. Try setting `source_texture_search_root` to where the source PNG files live, or run **Diagnose Textures** to investigate." % surfaces_without_image )
		elif samples_passed_classifier_total == 0 :
			push_warning( "[VegetationScatter] Image data extracted but no pixel matched the classifier (luma < %.2f and g - max(r,b) > %.3f). Run **Diagnose Textures** to see your terrain's actual luma + hue distribution." % [ luma_threshold, green_excess ] )

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _load_or_make_shrub_mesh()
	mm.instance_count = transforms.size()
	for i in transforms.size() :
		mm.set_instance_transform( i, transforms[ i ] )

	var err : int = ResourceSaver.save( mm, SCATTER_MULTIMESH_PATH )
	if err != OK :
		push_error( "[VegetationScatter] Failed to save scatter multimesh: %s" % err )
		return

	_refresh_multimesh_child()
	print( "[VegetationScatter] Saved scatter to %s" % SCATTER_MULTIMESH_PATH )

func _collect_mesh_instances( root : Node, out_list : Array[ MeshInstance3D ] ) -> void :
	var stack : Array[ Node ] = [ root ]
	while not stack.is_empty() :
		var n : Node = stack.pop_back()
		for child in n.get_children() :
			stack.append( child )
		if n is MeshInstance3D :
			out_list.append( n as MeshInstance3D )

func _process_mesh_instance( mi : MeshInstance3D, rng : RandomNumberGenerator, to_local : Transform3D, transforms : Array[ Transform3D ], stats : Dictionary ) -> void :
	var mesh : Mesh = mi.mesh
	if mesh == null :
		return
	var mi_xform : Transform3D = mi.global_transform

	for surface_idx in mesh.get_surface_count() :
		var material : Material = mi.get_active_material( surface_idx )
		var extract : Dictionary = _extract_albedo_image( material )
		var albedo_image : Image = extract.image
		var status : String = extract.status
		if albedo_image == null :
			stats.surfaces_without_image += 1
			stats.image_diagnostics.append( "surface %d: NO IMAGE - %s" % [ surface_idx, status ] )
			continue
		stats.surfaces_with_image += 1
		stats.image_diagnostics.append( "surface %d: %s" % [ surface_idx, status ] )

		var arrays : Array = mesh.surface_get_arrays( surface_idx )
		if arrays.size() < Mesh.ARRAY_MAX :
			stats.image_diagnostics[ stats.image_diagnostics.size() - 1 ] += \
				" | SKIP: arrays.size()=%d < ARRAY_MAX=%d" % [ arrays.size(), Mesh.ARRAY_MAX ]
			continue

		var verts : PackedVector3Array = arrays[ Mesh.ARRAY_VERTEX ]
		# UV0 is the primary texture UV in GLB/GLTF.
		# If arrays[ARRAY_TEX_UV] comes back as null, GDScript converts to empty
		# PackedVector2Array, so we check and fall back to UV2.
		var raw_uv0 : Variant = arrays[ Mesh.ARRAY_TEX_UV ]
		var raw_uv2 : Variant = arrays[ Mesh.ARRAY_TEX_UV2 ]
		var uvs : PackedVector2Array
		if raw_uv0 is PackedVector2Array and ( raw_uv0 as PackedVector2Array ).size() > 0 :
			uvs = raw_uv0 as PackedVector2Array
		elif raw_uv2 is PackedVector2Array and ( raw_uv2 as PackedVector2Array ).size() > 0 :
			uvs = raw_uv2 as PackedVector2Array
			stats.image_diagnostics[ stats.image_diagnostics.size() - 1 ] += " | using UV2 fallback"
		else :
			stats.image_diagnostics[ stats.image_diagnostics.size() - 1 ] += \
				" | SKIP: UV0 type=%s UV2 type=%s" % [ type_string( typeof( raw_uv0 ) ), type_string( typeof( raw_uv2 ) ) ]
			continue

		var raw_idx : Variant = arrays[ Mesh.ARRAY_INDEX ]
		var indices : PackedInt32Array
		if raw_idx is PackedInt32Array :
			indices = raw_idx as PackedInt32Array
		# (if null/other type, indices stays empty → non-indexed path)

		if verts.is_empty() :
			stats.image_diagnostics[ stats.image_diagnostics.size() - 1 ] += " | SKIP: verts empty"
			continue
		if verts.size() != uvs.size() :
			stats.image_diagnostics[ stats.image_diagnostics.size() - 1 ] += \
				" | SKIP: verts.size()=%d != uvs.size()=%d" % [ verts.size(), uvs.size() ]
			continue

		var has_indices : bool = not indices.is_empty()
		var tri_count : int = ( indices.size() / 3 ) if has_indices else ( verts.size() / 3 )
		var img_w : int = albedo_image.get_width()
		var img_h : int = albedo_image.get_height()

		for tri_i in tri_count :
			var i0 : int
			var i1 : int
			var i2 : int
			if has_indices :
				i0 = indices[ tri_i * 3 + 0 ]
				i1 = indices[ tri_i * 3 + 1 ]
				i2 = indices[ tri_i * 3 + 2 ]
			else :
				i0 = tri_i * 3 + 0
				i1 = tri_i * 3 + 1
				i2 = tri_i * 3 + 2

			var v0 : Vector3 = mi_xform * verts[ i0 ]
			var v1 : Vector3 = mi_xform * verts[ i1 ]
			var v2 : Vector3 = mi_xform * verts[ i2 ]

			var e1 : Vector3 = v1 - v0
			var e2 : Vector3 = v2 - v0
			var cross_v : Vector3 = e1.cross( e2 )
			var area : float = 0.5 * cross_v.length()
			if area < 0.001 :
				continue
			var normal : Vector3 = cross_v.normalized()
			# GLB/photogrammetry exporters can use either vertex winding order,
			# so the computed face normal may point down. Flip it to always point
			# in whichever hemisphere faces up, then test against min_surface_up.
			if normal.y < 0.0 :
				normal = -normal
			if normal.y < min_surface_up :
				continue

			var uv0 : Vector2 = uvs[ i0 ]
			var uv1 : Vector2 = uvs[ i1 ]
			var uv2 : Vector2 = uvs[ i2 ]

			var samples : int = int( ceil( area * _effective_density() ) )
			for s in samples :
				stats.samples_taken += 1
				stats.samples_passed_geometry += 1
				# Uniform random barycentric (mirror trick for the unit triangle).
				var b1 : float = rng.randf()
				var b2 : float = rng.randf()
				if b1 + b2 > 1.0 :
					b1 = 1.0 - b1
					b2 = 1.0 - b2
				var b0 : float = 1.0 - b1 - b2

				var uv : Vector2 = uv0 * b0 + uv1 * b1 + uv2 * b2
				var px : int = clampi( int( fposmod( uv.x, 1.0 ) * img_w ), 0, img_w - 1 )
				var py : int = clampi( int( fposmod( uv.y, 1.0 ) * img_h ), 0, img_h - 1 )
				var col : Color = albedo_image.get_pixel( px, py )
				var classifier_passed : bool = force_classifier_pass or _is_vegetation_color( col )

				var world_pos : Vector3 = v0 * b0 + v1 * b1 + v2 * b2
				world_pos.y += ground_anchor_offset

				# Exclusion is a hard reject (no density factor needed).
				if _is_in_any_manual_volume( world_pos, exclusion_volumes ) :
					continue

				# Inclusion volumes return a 0..1 density factor that encodes
				# both the volume density multiplier and edge falloff. 0 means
				# the point is outside all inclusion volumes.
				var include_density : float = _include_volume_density_at( world_pos )
				var in_include_volume : bool = include_density > 0.0

				# Reject anything below the configured minimum world-Y. Keeps
				# shrubs off the flat valley floor even when that floor's
				# baked texture happens to satisfy the colour classifier.
				if world_pos.y < min_world_height :
					continue

				if require_include_below_height and world_pos.y < include_required_below_height and not in_include_volume :
					continue

				if not classifier_passed and not ( include_volumes_bypass_classifier and in_include_volume ) :
					continue

				# Apply per-inclusion-volume density as a probability so that
				# candidates inside the volume are still randomly thinned and
				# feathered at the edges rather than forming a solid box.
				if in_include_volume and rng.randf() > include_density :
					continue

				stats.samples_passed_classifier += 1

				var local_pos : Vector3 = to_local * world_pos

				var basis : Basis
				if align_to_surface :
					var up : Vector3 = ( to_local.basis * normal ).normalized()
					basis = _basis_from_up( up ).rotated( up, rng.randf() * TAU )
				else :
					basis = Basis( Vector3.UP, rng.randf() * TAU )

				var eff_min_s := _effective_shrub_min_scale()
				var eff_max_s := _effective_shrub_max_scale()
				var sx : float = rng.randf_range( eff_min_s.x, eff_max_s.x )
				var sy : float = rng.randf_range( eff_min_s.y, eff_max_s.y )
				var sz : float = rng.randf_range( eff_min_s.z, eff_max_s.z )
				basis = basis.scaled( Vector3( sx, sy, sz ) )

				transforms.append( Transform3D( basis, local_pos ) )

func _basis_from_up( up : Vector3 ) -> Basis :
	# Guard against a zero/degenerate up vector (e.g. a zero surface normal) which
	# would yield zero basis columns and an invalid Basis.
	var u : Vector3 = up.normalized()
	if u.length_squared() < 1e-8 :
		u = Vector3.UP
	var ref : Vector3 = Vector3.RIGHT if abs( u.x ) < 0.9 else Vector3.FORWARD
	var x : Vector3 = ref.cross( u ).normalized()
	if x.length_squared() < 1e-8 :
		x = Vector3.RIGHT if abs( u.x ) < 0.9 else Vector3.FORWARD
	var z : Vector3 = u.cross( x ).normalized()
	return Basis( x, u, z )

## Returns true if world_pos is inside any volume in the list (hard boolean,
## used for exclusion volumes which have no density falloff).
func _is_in_any_manual_volume( world_pos : Vector3, volume_paths : Array[ NodePath ] ) -> bool :
	for path in volume_paths :
		var volume : Node3D = get_node_or_null( path ) as Node3D
		if volume == null :
			continue
		if _box_density_factor( world_pos, volume, 0.0, 1.0 ) > 0.0 :
			return true
	return false

## Returns the highest density factor (0..1) across all inclusion volumes.
## Combines the configured include_volume_density with edge feathering so that
## points near the box boundary are thinned out and the hard-box look dissolves.
func _include_volume_density_at( world_pos : Vector3 ) -> float :
	var best : float = 0.0
	for path in inclusion_volumes :
		var volume : Node3D = get_node_or_null( path ) as Node3D
		if volume == null :
			continue
		var d : float = _box_density_factor(
			world_pos, volume,
			include_volume_edge_falloff,
			include_volume_density
		)
		if d > best :
			best = d
	return best

## Returns a density factor in [0, peak_density] for a point relative to a
## box volume. 0 = outside the box. Inside, density is smoothly ramped from 0
## at the face up to peak_density at the falloff_fraction boundary inward.
## falloff_fraction = 0 means a hard edge (no ramp).
func _box_density_factor( world_pos : Vector3, volume : Node3D,
		falloff_fraction : float, peak_density : float ) -> float :
	var local_pos : Vector3 = volume.global_transform.affine_inverse() * world_pos
	var half : Vector3 = Vector3( 0.5, 0.5, 0.5 )
	if "size" in volume :
		var sz : Variant = volume.get( "size" )
		if sz is Vector3 and ( sz as Vector3 ).length_squared() > 0.0 :
			half = ( sz as Vector3 ) * 0.5
	elif volume is MeshInstance3D :
		var mi_mesh : Mesh = ( volume as MeshInstance3D ).mesh
		if mi_mesh != null and "size" in mi_mesh :
			var sz : Variant = mi_mesh.get( "size" )
			if sz is Vector3 and ( sz as Vector3 ).length_squared() > 0.0 :
				half = ( sz as Vector3 ) * 0.5
	# Normalised signed distance from each face: 0 = on face, 1 = at centre.
	var nx : float = 1.0 - absf( local_pos.x ) / half.x
	var ny : float = 1.0 - absf( local_pos.y ) / half.y
	var nz : float = 1.0 - absf( local_pos.z ) / half.z
	if nx <= 0.0 or ny <= 0.0 or nz <= 0.0 :
		return 0.0   # outside the box
	# How far "inside" the box are we? 0 = touching a face, 1 = fully interior.
	# Use the minimum across axes so all six faces feather equally.
	var depth : float = minf( nx, minf( ny, nz ) )
	# Smoothstep ramp over the falloff band (falloff_fraction = 0 → hard edge).
	var ramp_width : float = maxf( falloff_fraction, 0.001 )
	var t : float = smoothstep( 0.0, ramp_width, depth )
	return t * peak_density

## Classifier: pixel is vegetation if dark enough AND green-leaning relative to
## red/blue. `green_excess` controls hue strictness:
##   > 0   : true green required (rejects olive/sage)
##   = 0   : green must equal or exceed max(R, B) - rejects neutral shadows
##   < 0   : olive/sage allowed - green may be slightly *less* than max(R, B)
## For desert photogrammetry, slightly negative values (-0.01 to -0.05) usually
## work best; sun-bleached sagebrush is olive-brown, not chlorophyll-green.
func _is_vegetation_color( c : Color ) -> bool :
	var luma : float = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	if luma > _effective_luma_threshold() :
		return false
	var hue_score : float = c.g - max( c.r, c.b )
	if hue_score < _effective_green_excess() :
		return false
	# Reject near-gray pixels (rock shadows, dirt) that happen to pass the
	# luma + green gates. Real shrubs have visible chroma even when dark.
	var max_c : float = max( max( c.r, c.g ), c.b )
	var min_c : float = min( min( c.r, c.g ), c.b )
	var chroma : float = max_c - min_c
	return chroma >= min_chroma

## Returns { "image": Image or null, "status": String describing what happened }.
##
## Image extraction is the #1 source of "bake produces 0 instances" because
## VRAM-compressed imported textures sometimes don't expose a CPU-readable
## image. The fallback path loads the source PNG directly from disk if the
## texture's resource_path lets us derive its original filename.
func _extract_albedo_image( material : Material ) -> Dictionary :
	var result : Dictionary = { "image": null, "status": "no material" }
	if material == null :
		return result
	var tex : Texture2D = null
	if material is BaseMaterial3D :
		tex = ( material as BaseMaterial3D ).albedo_texture
		if tex == null :
			result.status = "BaseMaterial3D has no albedo_texture"
			return result
	elif material is ShaderMaterial :
		var p : Variant = ( material as ShaderMaterial ).get_shader_parameter( "albedo_tex" )
		if p is Texture2D :
			tex = p
		else :
			result.status = "ShaderMaterial has no albedo_tex parameter"
			return result
	else :
		result.status = "unsupported material type: %s" % material.get_class()
		return result

	# First try the texture's own CPU-side image (works for uncompressed and
	# some compressed imports).
	var img : Image = null
	var via : String = ""
	var get_image_failed_reason : String = ""
	var raw_img : Image = tex.get_image()
	if raw_img != null and not raw_img.is_empty() :
		if raw_img.is_compressed() :
			var err : int = raw_img.decompress()
			if err == OK :
				img = raw_img
				via = "get_image+decompress"
			else :
				get_image_failed_reason = "decompress err %d" % err
		else :
			img = raw_img
			via = "get_image"
	else :
		get_image_failed_reason = "get_image() returned null/empty"

	# Source-PNG fallback. Common when textures are imported with VRAM
	# compression and the source bytes aren't kept on the CPU.
	if img == null and source_texture_search_root != "" :
		var src_path : String = _find_source_image_path( tex )
		if src_path != "" :
			var fresh : Image = Image.new()
			var err : int = fresh.load( src_path )
			if err == OK :
				img = fresh
				via = "source-png fallback at %s" % src_path
			else :
				result.status = "%s; source PNG load failed err %d at %s" % [ get_image_failed_reason, err, src_path ]
				return result
		else :
			result.status = "%s; no matching source PNG under %s" % [ get_image_failed_reason, source_texture_search_root ]
			return result

	if img == null :
		result.status = get_image_failed_reason
		return result

	if img.get_format() != Image.FORMAT_RGBA8 :
		img.convert( Image.FORMAT_RGBA8 )

	result.image = img
	result.status = "%s, %dx%d %s" % [ via, img.get_width(), img.get_height(), _image_format_name( img.get_format() ) ]
	return result

## Best-effort source-PNG locator. Parses the original filename out of the
## imported `.ctex` resource path and looks for it under
## `source_texture_search_root` (recursively, one directory deep).
func _find_source_image_path( tex : Texture2D ) -> String :
	if tex == null :
		return ""
	var res_path : String = tex.resource_path
	if res_path.is_empty() :
		return ""
	var fname : String = res_path.get_file()
	# Imported textures look like: "<orig>.png-<md5>.s3tc.ctex". Strip the hash
	# suffix to recover the original file name.
	var orig_name : String = ""
	for ext : String in [ ".png", ".jpg", ".jpeg", ".webp", ".tga", ".bmp", ".exr", ".hdr" ] :
		var marker : String = ext + "-"
		var idx : int = fname.find( marker )
		if idx > 0 :
			orig_name = fname.substr( 0, idx + ext.length() )
			break
	if orig_name == "" :
		# Maybe it's not in .godot/imported at all (e.g. a runtime ImageTexture).
		return ""
	# Try the configured root first (flat).
	var direct : String = source_texture_search_root.path_join( orig_name )
	if FileAccess.file_exists( direct ) :
		return direct
	# Then a one-level recursive scan.
	return _search_for_filename( source_texture_search_root, orig_name )

func _search_for_filename( dir_path : String, filename : String ) -> String :
	var dir : DirAccess = DirAccess.open( dir_path )
	if dir == null :
		return ""
	dir.list_dir_begin()
	var name : String = dir.get_next()
	var subdirs : Array[ String ] = []
	while name != "" :
		if name == "." or name == ".." :
			name = dir.get_next()
			continue
		var full : String = dir_path.path_join( name )
		if dir.current_is_dir() :
			subdirs.append( full )
		elif name == filename :
			dir.list_dir_end()
			return full
		name = dir.get_next()
	dir.list_dir_end()
	for sub in subdirs :
		var found : String = _search_for_filename( sub, filename )
		if found != "" :
			return found
	return ""

func _image_format_name( fmt : int ) -> String :
	if fmt == Image.FORMAT_RGBA8 :
		return "RGBA8"
	if fmt == Image.FORMAT_RGB8 :
		return "RGB8"
	if fmt == Image.FORMAT_L8 :
		return "L8"
	return "fmt#%d" % fmt

# ---------------------------------------------------------------------------
# Diagnose
# ---------------------------------------------------------------------------

func diagnose() -> void :
	var terrain : Node = get_node_or_null( target_terrain )
	if terrain == null :
		push_error( "[VegetationScatter] Diagnose: target_terrain '%s' not found" % target_terrain )
		return

	var mesh_instances : Array[ MeshInstance3D ] = []
	_collect_mesh_instances( terrain, mesh_instances )
	print( "" )
	print( "==== VegetationScatter Diagnose ====" )
	print( "Terrain: %s  (%d MeshInstance3D nodes)" % [ terrain.name, mesh_instances.size() ] )
	_print_settings()
	print( "Effective thresholds: luma_threshold=%.3f, green_excess=%.3f" % [ _effective_luma_threshold(), _effective_green_excess() ] )
	print( "" )

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var grand_total_pixels : int = 0
	var grand_pass_current : int = 0
	var grand_pass_luma_only : int = 0
	var grand_dark_passes_by_luma : Array[ float ] = []
	var grand_hue_scores : Array[ float ] = []

	for mi_idx in mesh_instances.size() :
		var mi : MeshInstance3D = mesh_instances[ mi_idx ]
		var mesh : Mesh = mi.mesh
		if mesh == null :
			print( "[%d] %s: NO MESH" % [ mi_idx, mi.name ] )
			continue
		for surface_idx in mesh.get_surface_count() :
			var material : Material = mi.get_active_material( surface_idx )
			var extract : Dictionary = _extract_albedo_image( material )
			var img : Image = extract.image
			var status : String = extract.status
			if img == null :
				print( "[%d.%d] %s: IMAGE FAILED - %s" % [ mi_idx, surface_idx, mi.name, status ] )
				continue

			var img_w : int = img.get_width()
			var img_h : int = img.get_height()
			# Guard against @tool hot-reload zero-initializing this to 0.
			var samples : int = maxi( diagnose_samples_per_surface, 500 )

			var luma_min : float = 1.0
			var luma_max : float = 0.0
			var luma_sum : float = 0.0
			var hue_min : float = 1.0
			var hue_max : float = -1.0
			var hue_sum : float = 0.0
			var pass_current : int = 0
			var pass_luma_only : int = 0

			for s in samples :
				var px : int = rng.randi_range( 0, img_w - 1 )
				var py : int = rng.randi_range( 0, img_h - 1 )
				var c : Color = img.get_pixel( px, py )
				var luma : float = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
				var hue : float = c.g - max( c.r, c.b )
				luma_min = min( luma_min, luma )
				luma_max = max( luma_max, luma )
				luma_sum += luma
				hue_min = min( hue_min, hue )
				hue_max = max( hue_max, hue )
				hue_sum += hue
				grand_dark_passes_by_luma.append( luma )
				grand_hue_scores.append( hue )
				if luma < _effective_luma_threshold() :
					pass_luma_only += 1
					if hue > _effective_green_excess() :
						pass_current += 1

			grand_total_pixels += samples
			grand_pass_current += pass_current
			grand_pass_luma_only += pass_luma_only

			var pct_current : float = 100.0 * float( pass_current ) / float( samples )
			var pct_luma : float = 100.0 * float( pass_luma_only ) / float( samples )

			print( "[%d.%d] %s  %s" % [ mi_idx, surface_idx, mi.name, status ] )
			print( "       luma:  min=%.3f  max=%.3f  mean=%.3f" % [ luma_min, luma_max, luma_sum / float( samples ) ] )
			print( "       hue (g - max(r,b)):  min=%+.3f  max=%+.3f  mean=%+.3f" % [ hue_min, hue_max, hue_sum / float( samples ) ] )
			print( "       passing luma<%.2f only:  %5.1f%%   passing both:  %5.1f%%" % [ _effective_luma_threshold(), pct_luma, pct_current ] )

	if grand_total_pixels == 0 :
		print( "" )
		print( "No pixels were sampled (no surfaces had readable images)." )
		print( "Try setting `source_texture_search_root` to the folder containing the source PNG files." )
		return

	print( "" )
	print( "==== Overall ====" )
	print( "Total pixels sampled: %d across %d MeshInstance3D nodes." % [ grand_total_pixels, mesh_instances.size() ] )
	print( "Pixels passing current thresholds (luma<%.2f, hue>%+.3f): %.2f%%  (%d / %d)" % [
		_effective_luma_threshold(),
		_effective_green_excess(),
		100.0 * float( grand_pass_current ) / float( grand_total_pixels ),
		grand_pass_current,
		grand_total_pixels,
	] )
	print( "Pixels passing luma threshold alone:                       %.2f%%  (%d / %d)" % [
		100.0 * float( grand_pass_luma_only ) / float( grand_total_pixels ),
		grand_pass_luma_only,
		grand_total_pixels,
	] )
	print( "" )
	print( "Suggested thresholds (aim for ~5-15%% pass rate on a desert terrain):" )
	_print_quantile_hint( grand_dark_passes_by_luma, "luma_threshold", [ 0.05, 0.10, 0.20, 0.30 ] )
	_print_quantile_hint( grand_hue_scores, "green_excess", [ 0.05, 0.10, 0.20, 0.30 ], true )

func _print_quantile_hint( values : Array[ float ], label : String, fractions : Array, lower_is_stricter : bool = false ) -> void :
	if values.is_empty() :
		return
	values.sort()
	var n : int = values.size()
	var bits : Array[ String ] = []
	for f : float in fractions :
		var idx : int
		if lower_is_stricter :
			# Higher quantile == stricter (only top-X% pass).
			idx = clampi( int( ( 1.0 - f ) * float( n ) ), 0, n - 1 )
		else :
			idx = clampi( int( f * float( n ) ), 0, n - 1 )
		bits.append( "%.0f%% -> %+.3f" % [ f * 100.0, values[ idx ] ] )
	print( "  %s value that admits this %% of sampled pixels: %s" % [ label, ", ".join( bits ) ] )

# ---------------------------------------------------------------------------
# Runtime setup
# ---------------------------------------------------------------------------

func _ensure_multimesh_child() -> void :
	if _multimesh_instance != null and is_instance_valid( _multimesh_instance ) :
		return
	_multimesh_instance = get_node_or_null( "MultiMeshInstance3D" ) as MultiMeshInstance3D
	if _multimesh_instance != null :
		return
	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.name = "MultiMeshInstance3D"
	add_child( _multimesh_instance )
	if Engine.is_editor_hint() and is_inside_tree() :
		var edited : Node = get_tree().edited_scene_root
		if edited != null :
			_multimesh_instance.owner = edited

func _refresh_multimesh_child() -> void :
	_ensure_multimesh_child()
	if _multimesh_instance == null :
		return

	_multimesh_instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if cast_shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)

	# visibility_range_end = 0 means unlimited in Godot 4, which is the safe
	# default for a scene where vegetation may be 300-500 m from the camera.
	# Set a non-zero value in the Inspector to impose a culling distance.
	_multimesh_instance.visibility_range_begin = visibility_range_begin
	_multimesh_instance.visibility_range_begin_margin = 0.0
	_multimesh_instance.visibility_range_end = visibility_range_end
	_multimesh_instance.visibility_range_end_margin = \
		0.0 if visibility_range_end <= 0.0 else maxf( 20.0, visibility_range_end * 0.08 )
	_multimesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

	var loaded_multimesh : MultiMesh = null
	if ResourceLoader.exists( SCATTER_MULTIMESH_PATH ) :
		var mm : Resource = ResourceLoader.load( SCATTER_MULTIMESH_PATH )
		if mm is MultiMesh :
			loaded_multimesh = mm as MultiMesh
			_multimesh_instance.multimesh = loaded_multimesh
	if ResourceLoader.exists( SHRUB_MATERIAL_PATH ) :
		var mat : Resource = ResourceLoader.load( SHRUB_MATERIAL_PATH )
		if mat is Material :
			_multimesh_instance.material_override = mat
	VegetationEnvironmentSync.register_multimesh_instance( _multimesh_instance )

	if Engine.is_editor_hint() :
		_multimesh_instance.visible = not show_editor_preview
		_refresh_editor_preview( loaded_multimesh )
	elif _preview_instance != null and is_instance_valid( _preview_instance ) :
		_preview_instance.visible = false

func _ensure_preview_child() -> void :
	if _preview_instance != null and is_instance_valid( _preview_instance ) :
		return
	_preview_instance = get_node_or_null( "EditorPreviewDots" ) as MultiMeshInstance3D
	if _preview_instance != null :
		return
	_preview_instance = MultiMeshInstance3D.new()
	_preview_instance.name = "EditorPreviewDots"
	add_child( _preview_instance )

func _refresh_editor_preview( source_multimesh : MultiMesh ) -> void :
	_ensure_preview_child()
	if _preview_instance == null :
		return
	_preview_instance.visible = show_editor_preview and source_multimesh != null
	if not _preview_instance.visible :
		_preview_instance.multimesh = null
		return

	var source_count : int = source_multimesh.instance_count
	if source_count <= 0 :
		_preview_instance.multimesh = null
		return
	var preview_count : int = mini( source_count, maxi( editor_preview_max_points, 1 ) )
	var step : int = maxi( int( ceili( float( source_count ) / float( preview_count ) ) ), 1 )

	var dot_mesh := BoxMesh.new()
	dot_mesh.size = Vector3.ONE * maxf( editor_preview_dot_size, 0.01 )

	var dot_material := StandardMaterial3D.new()
	dot_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_material.albedo_color = Color( 0.05, 0.8, 0.2, 1.0 )
	dot_mesh.material = dot_material

	var preview_mm := MultiMesh.new()
	preview_mm.transform_format = MultiMesh.TRANSFORM_3D
	preview_mm.mesh = dot_mesh
	preview_mm.instance_count = preview_count

	for i in preview_count :
		var source_idx : int = mini( i * step, source_count - 1 )
		var source_transform : Transform3D = source_multimesh.get_instance_transform( source_idx )
		preview_mm.set_instance_transform( i, Transform3D( Basis(), source_transform.origin ) )

	_preview_instance.multimesh = preview_mm

# ---------------------------------------------------------------------------
# Terrain overlay (Option 2)
# ---------------------------------------------------------------------------

func _apply_terrain_overlay() -> void :
	if _overlay_applied :
		return
	if not ResourceLoader.exists( TERRAIN_OVERLAY_SHADER_PATH ) :
		push_warning( "[VegetationScatter] Terrain overlay shader missing at %s" % TERRAIN_OVERLAY_SHADER_PATH )
		return
	var terrain : Node = get_node_or_null( target_terrain )
	if terrain == null :
		push_warning( "[VegetationScatter] Cannot apply terrain overlay; target_terrain '%s' not found" % target_terrain )
		return
	var shader : Shader = ResourceLoader.load( TERRAIN_OVERLAY_SHADER_PATH )
	if shader == null :
		return

	var mesh_instances : Array[ MeshInstance3D ] = []
	_collect_mesh_instances( terrain, mesh_instances )

	var applied_count : int = 0
	for mi in mesh_instances :
		applied_count += _apply_overlay_to_mesh( mi, shader )

	_overlay_applied = true
	print( "[VegetationScatter] Terrain overlay applied to %d surface(s)." % applied_count )

func _apply_overlay_to_mesh( mi : MeshInstance3D, shader : Shader ) -> int :
	var mesh : Mesh = mi.mesh
	if mesh == null :
		return 0
	var applied : int = 0
	for surface_idx in mesh.get_surface_count() :
		var original : Material = mi.get_active_material( surface_idx )
		if original == null :
			continue
		var albedo : Texture2D = null
		if original is BaseMaterial3D :
			albedo = ( original as BaseMaterial3D ).albedo_texture
		elif original is ShaderMaterial :
			# Already a ShaderMaterial - probably ours from a previous apply.
			# Skip rather than chain wrap.
			continue
		if albedo == null :
			continue
		var sm := ShaderMaterial.new()
		sm.shader = shader
		sm.set_shader_parameter( "albedo_tex", albedo )
		sm.set_shader_parameter( "vegetation_luma_threshold", _effective_luma_threshold() )
		sm.set_shader_parameter( "vegetation_green_excess", _effective_green_excess() )
		sm.set_shader_parameter( "vegetation_min_chroma", min_chroma )
		sm.set_shader_parameter( "fuzz_scale",
			overlay_fuzz_scale if overlay_fuzz_scale > 0.0 else 4.0 )
		sm.set_shader_parameter( "vegetation_albedo_tint", overlay_albedo_tint )
		# Guard against hot-reload zero-init: roughness of 0.0 makes terrain
		# mirror-like. Enforce sane minimums.
		sm.set_shader_parameter( "terrain_roughness",
			overlay_terrain_roughness if overlay_terrain_roughness > 0.1 else 0.75 )
		sm.set_shader_parameter( "vegetation_roughness",
			overlay_vegetation_roughness if overlay_vegetation_roughness > 0.1 else 0.92 )
		mi.set_surface_override_material( surface_idx, sm )
		applied += 1
	return applied

# ---------------------------------------------------------------------------
# Procedural shrub assets
# ---------------------------------------------------------------------------

func _ensure_baked_dir() -> void :
	var abs_path : String = ProjectSettings.globalize_path( BAKED_DIR )
	if not DirAccess.dir_exists_absolute( abs_path ) :
		DirAccess.make_dir_recursive_absolute( abs_path )

func _generate_shrub_texture( force : bool ) -> Texture2D :
	if not force and ResourceLoader.exists( SHRUB_TEXTURE_PATH ) :
		var loaded : Resource = ResourceLoader.load( SHRUB_TEXTURE_PATH )
		if loaded is Texture2D :
			return loaded as Texture2D

	var size : int = 128
	var img : Image = Image.create( size, size, true, Image.FORMAT_RGBA8 )
	img.fill( Color( 0, 0, 0, 0 ) )

	# Three noise fields drive three independent visual properties:
	#   n_shape  - low-frequency overall canopy outline (alpha mask)
	#   n_color  - mid-frequency colour variation (lit highlights vs base)
	#   n_shadow - mid-frequency shadow patches (deep dark interior pixels)
	var n_shape : FastNoiseLite = FastNoiseLite.new()
	n_shape.seed = 1337
	n_shape.frequency = 0.045
	n_shape.fractal_octaves = 4

	var n_color : FastNoiseLite = FastNoiseLite.new()
	n_color.seed = 9999
	n_color.frequency = 0.09
	n_color.fractal_octaves = 2

	var n_shadow : FastNoiseLite = FastNoiseLite.new()
	n_shadow.seed = 2222
	n_shadow.frequency = 0.18
	n_shadow.fractal_octaves = 2

	var half : float = size * 0.5
	var shrub_radius : float = size * 0.44

	# Palette: dark forest-green canopy with near-black shadow patches.
	# Tuned to match the reference photograph the user supplied of low desert
	# scrub: deep olive/forest top, brown-charcoal base, occasional black gaps.
	var top_color    : Color = Color( 0.08, 0.18, 0.05 )
	var bottom_color : Color = Color( 0.14, 0.12, 0.05 )
	var highlight    : Color = Color( 0.22, 0.30, 0.10 )
	var shadow       : Color = Color( 0.015, 0.025, 0.010 )

	for y in size :
		for x in size :
			var cx : float = ( float( x ) - half ) / shrub_radius
			# Anchor visible mass slightly above the texture centre so the
			# bottom of the card reads as branches/dirt and the top as foliage.
			var cy : float = ( ( float( y ) + float( size ) * 0.08 ) - half ) / shrub_radius
			var r : float = sqrt( cx * cx + cy * cy )

			var disk : float = clamp( 1.0 - r, 0.0, 1.0 )
			var n : float = ( n_shape.get_noise_2d( float( x ), float( y ) ) + 1.0 ) * 0.5
			var density_val : float = disk * ( 0.45 + n * 0.9 )
			var alpha : float = clamp( smoothstep( 0.30, 0.55, density_val ), 0.0, 1.0 )

			if alpha < 0.02 :
				continue

			var brown_t : float = clamp( ( float( y ) - half * 0.3 ) / ( float( size ) - half * 0.3 ), 0.0, 1.0 )
			# Base canopy colour: lerp from dark olive top to brown-charcoal base.
			var base : Color = top_color.lerp( bottom_color, brown_t )

			# Colour noise: occasionally push the pixel toward a brighter
			# highlight (sun-hit foliage). Smoothstep makes it cluster into
			# coherent patches rather than salt-and-pepper noise.
			var ncol : float = ( n_color.get_noise_2d( float( x ), float( y ) ) + 1.0 ) * 0.5
			var hl_amount : float = smoothstep( 0.55, 0.95, ncol )
			var lit : Color = base.lerp( highlight, hl_amount * 0.55 )

			# Shadow noise: punch deep almost-black holes into the interior so
			# the texture reads as a chunky branchy mass with visible negative
			# space, not a uniform green blob.
			var nshd : float = ( n_shadow.get_noise_2d( float( x ), float( y ) ) + 1.0 ) * 0.5
			var shadow_amount : float = smoothstep( 0.55, 0.78, nshd )
			# Shadows lean harder toward the base of the card (under the bush).
			shadow_amount = clamp( shadow_amount * ( 0.65 + brown_t * 0.55 ), 0.0, 1.0 )
			var final : Color = lit.lerp( shadow, shadow_amount )

			final.a = alpha
			img.set_pixel( x, y, final )

	img.generate_mipmaps()
	var tex : ImageTexture = ImageTexture.create_from_image( img )
	var err : int = ResourceSaver.save( tex, SHRUB_TEXTURE_PATH )
	if err != OK :
		push_error( "[VegetationScatter] Failed to save shrub texture: %s" % err )
	return tex

func _generate_shrub_mesh( force : bool ) -> ArrayMesh :
	if not force and ResourceLoader.exists( SHRUB_MESH_PATH ) :
		var loaded : Resource = ResourceLoader.load( SHRUB_MESH_PATH )
		if loaded is ArrayMesh :
			return loaded as ArrayMesh

	var arr_mesh : ArrayMesh = ArrayMesh.new()
	var arr : Array = []
	arr.resize( Mesh.ARRAY_MAX )

	var verts : PackedVector3Array = PackedVector3Array()
	var uvs : PackedVector2Array = PackedVector2Array()
	var normals : PackedVector3Array = PackedVector3Array()
	var indices : PackedInt32Array = PackedInt32Array()

	# Three vertical cards rotated 0 / 60 / 120 degrees around Y. Three is the
	# sweet spot for low-angle silhouettes - any horizontal viewpoint sees at
	# least one card close to parallel.
	# UV: (0,0) top-left, (1,1) bottom-right. UV.y=0 -> top of card, used by
	# foliage.gdshader to drive the wind sway gradient and bottom-AO tint.
	var eff_cw : float = _effective_card_width()
	var eff_ch : float = _effective_card_height()
	for card_i in 3 :
		var angle : float = float( card_i ) * PI / 3.0
		var dx : float = cos( angle ) * eff_cw * 0.5
		var dz : float = sin( angle ) * eff_cw * 0.5
		var base : int = verts.size()

		verts.append( Vector3( -dx, 0.0, -dz ) )
		verts.append( Vector3( dx, 0.0, dz ) )
		verts.append( Vector3( dx, eff_ch, dz ) )
		verts.append( Vector3( -dx, eff_ch, -dz ) )

		uvs.append( Vector2( 0.0, 1.0 ) )
		uvs.append( Vector2( 1.0, 1.0 ) )
		uvs.append( Vector2( 1.0, 0.0 ) )
		uvs.append( Vector2( 0.0, 0.0 ) )

		# Face-perpendicular normal blended with up. Each card has a unique
		# facing direction, so after the per-instance Y-rotation baked into the
		# multimesh transforms, adjacent shrubs shade differently under the
		# directional sun — breaking up the flat uniform look at distance.
		var card_dir   := Vector3( dx, 0.0, dz ).normalized() if ( dx != 0.0 or dz != 0.0 ) else Vector3.FORWARD
		var face_perp  := Vector3( -card_dir.z, 0.0, card_dir.x )  # 90° in XZ
		var face_normal := ( face_perp + Vector3( 0.0, 0.7, 0.0 ) ).normalized()
		for _j in 4 :
			normals.append( face_normal )

		indices.append( base + 0 )
		indices.append( base + 1 )
		indices.append( base + 2 )
		indices.append( base + 0 )
		indices.append( base + 2 )
		indices.append( base + 3 )

	arr[ Mesh.ARRAY_VERTEX ] = verts
	arr[ Mesh.ARRAY_TEX_UV ] = uvs
	arr[ Mesh.ARRAY_NORMAL ] = normals
	arr[ Mesh.ARRAY_INDEX ] = indices

	arr_mesh.add_surface_from_arrays( Mesh.PRIMITIVE_TRIANGLES, arr )
	var err : int = ResourceSaver.save( arr_mesh, SHRUB_MESH_PATH )
	if err != OK :
		push_error( "[VegetationScatter] Failed to save shrub mesh: %s" % err )
	return arr_mesh

func _generate_shrub_material( force : bool ) -> ShaderMaterial :
	if not force and ResourceLoader.exists( SHRUB_MATERIAL_PATH ) :
		var loaded : Resource = ResourceLoader.load( SHRUB_MATERIAL_PATH )
		if loaded is ShaderMaterial :
			return loaded as ShaderMaterial

	var shader : Shader = load( FOLIAGE_SHADER_PATH )
	var mat : ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter( "albedo_tex", _generate_shrub_texture( false ) )
	var err : int = ResourceSaver.save( mat, SHRUB_MATERIAL_PATH )
	if err != OK :
		push_error( "[VegetationScatter] Failed to save shrub material: %s" % err )
	return mat

func _load_or_make_shrub_mesh() -> ArrayMesh :
	if ResourceLoader.exists( SHRUB_MESH_PATH ) :
		var loaded : Resource = ResourceLoader.load( SHRUB_MESH_PATH )
		if loaded is ArrayMesh :
			return loaded as ArrayMesh
	return _generate_shrub_mesh( true )
