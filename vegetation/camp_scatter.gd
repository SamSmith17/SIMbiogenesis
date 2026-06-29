@tool
extends Node3D
class_name CampScatter

# Explicit preloads of sibling class scripts. Godot's global class table is
# scanned project-wide, but the order is not guaranteed during the first
# project load. Preload here forces these scripts to compile and register
# their class_name before this script's parse continues, which avoids
# "Could not find type CampStamp" parse errors at fresh-open time.
const CampStampScript : GDScript = preload( "res://vegetation/camp_stamp.gd" )
const CampScatterProfileScript : GDScript = preload( "res://vegetation/camp_scatter_profile.gd" )
const CampScatterCandidateScript : GDScript = preload( "res://vegetation/camp_scatter_candidate.gd" )
const CampScatterBakeScript : GDScript = preload( "res://vegetation/camp_scatter_bake.gd" )
const CampForcedVolumeScript : GDScript = preload( "res://vegetation/camp_forced_volume.gd" )

## CampScatter
##
## Editor-time tool that auto-populates a large festival map with recurring
## camp props (popup tents, RVs, camping tents, shade structures, cars) using
## two complementary inputs:
##
##   1) Aerial image detection (heuristic).
##      A high-resolution top-down aerial photo is segmented per class using
##      colour/luma/saturation thresholds from each `CampScatterProfile`, then
##      connected-component analysis + a minimum-area-rectangle fit yields a
##      candidate for every detected object (position, heading, footprint,
##      confidence).
##
##   2) Manual stamps.
##      `CampStamp` Marker3D nodes you drop in the 3D viewport. Each stamp
##      becomes one placement; orientation can be set manually, taken from
##      the marker's own yaw, or auto-detected from the local aerial pixels.
##      Use stamps for items the heuristic misses, for items in difficult
##      lighting/clutter, or whenever you just want exact control.
##
## Baked output is saved to `res://vegetation/baked/camp_scatter_bake.tres`
## as an array of `CampScatterCandidate`. When the bake reloads, instances
## are rendered either as packed scenes (one Node per candidate) or via a
## single `MultiMeshInstance3D` per class (toggle on the profile).
##
## Editor actions live in the Actions group at the bottom of the Inspector:
##   - Bake Now            : run image detection + stamps + save
##   - Bake Manual Stamps  : process stamps only and append to bake
##   - Auto Orient Stamps  : detect orientation for every stamp from the image
##     (updates stamp.rotation.y in place; does not bake)
##   - Diagnose Detection  : print per-class blob counts and confidence bins
##   - Clear Bake          : delete the saved bake and remove baked instances
##   - Export Candidates   : write the bake out as readable JSON
##   - Add Stamp At Origin : create a new CampStamp child at the scatter origin

const BAKED_DIR : String = "res://vegetation/baked/"
const BAKED_CANDIDATES_PATH : String = BAKED_DIR + "camp_scatter_bake.tres"
const EXPORTED_CANDIDATES_JSON_PATH : String = BAKED_DIR + "camp_scatter_candidates.json"

const DEFAULT_PROFILE_PATHS : PackedStringArray = [
	"res://vegetation/camp_profile_popup_tent.tres",
	"res://vegetation/camp_profile_rv.tres",
	"res://vegetation/camp_profile_camping_tent.tres",
	"res://vegetation/camp_profile_shade_structure.tres",
	"res://vegetation/camp_profile_car.tres",
]

const BAKED_ROOT_NAME : String = "CampScatterBaked"
const PREVIEW_NODE_NAME : String = "CampPreviewDots"

# ---------------------------------------------------------------------------
# Inspector
# ---------------------------------------------------------------------------

@export_group( "Target" )
## NodePath to the terrain node whose mesh AABB defines the world footprint of
## the aerial image. Only used when `use_target_terrain_bounds` is true.
@export var target_terrain : NodePath = NodePath( "../Soak site 3" )
## Path to the raw aerial photo (PNG/JPG). The image is loaded directly from
## disk so it bypasses Godot's import compression — use the original file.
@export_file( "*.png", "*.jpg", "*.jpeg", "*.webp" ) var aerial_image_path : String = "res://Imported Models/Soak Terrain/SOAK Serious Aerial/soak 2025.png"
## Alternative: drag an imported Texture2D here instead of using a file path.
## If both are set, the texture takes priority.
@export var aerial_texture : Texture2D
## Optional visible alignment plane. Create or assign a MeshInstance3D with a
## PlaneMesh textured with the aerial image, then scale/rotate/move it until it
## matches the terrain. When enabled below, pixel detection maps through this
## plane instead of using terrain bounds or manual min/max bounds.
@export var aerial_reference_plane : NodePath
## Opacity of the generated aerial reference plane. Lower this to see the
## terrain underneath while aligning the photo.
@export_range( 0.05, 1.0, 0.05 ) var aerial_reference_plane_opacity : float = 0.85
## Maximum long-side texture size used for the visible reference plane. The
## detection still uses the source image, but the display copy may be
## downsampled so very large PNGs do not exceed the GPU/editor texture limit.
## Raise this for sharper alignment if your GPU handles the texture size.
@export_range( 512, 16384, 512 ) var aerial_reference_preview_max_dimension : int = 8192

@export_group( "Alignment" )
## When enabled, the aerial image is stretched to cover the world-space AABB of
## the `target_terrain` mesh. Disable and set the min/max XZ bounds manually
## if you want precise control or the terrain node is not in this scene.
@export var use_target_terrain_bounds : bool = true
## When enabled and `aerial_reference_plane` points to a MeshInstance3D/Node3D,
## the aerial photo's pixels are mapped through that placed rectangle. This is
## the best workflow when the PNG is not already scaled exactly to the terrain.
@export var use_aerial_reference_plane : bool = false
## World-space XZ corner of the aerial image (X = East, Z = South) in metres.
## Only used when `use_target_terrain_bounds` is disabled.
@export var world_bounds_min_xz : Vector2 = Vector2( -150.0, -150.0 )
## Opposite world-space XZ corner of the aerial image in metres.
## Only used when `use_target_terrain_bounds` is disabled.
@export var world_bounds_max_xz : Vector2 = Vector2( 150.0, 150.0 )
## The aerial image is downsampled to this dimension (longest side) before
## analysis. Lower = faster bake; higher = more precise blob detection.
## 1024 is fast, 2048 is a good balance, 4096 is slow but very accurate.
@export_range( 128, 8192, 64 ) var max_work_image_dimension : int = 2048
## Height (Y) from which the vertical terrain raycast is fired for each
## candidate. Must be above the highest point of your terrain.
@export_range( 10.0, 5000.0, 10.0 ) var raycast_start_height : float = 1200.0
## Total distance the raycast travels downward. Extend if terrain is very deep.
@export_range( 10.0, 5000.0, 10.0 ) var raycast_depth : float = 2500.0
## Y position used when the terrain raycast misses (e.g. no physics body).
## Set this to your average terrain height so objects land in the right place.
@export_range( -1000.0, 1000.0, 0.1 ) var fallback_world_y : float = 0.0

@export_group( "Class Profiles" )
## Array of CampScatterProfile resources — one per class (popup_tent, rv, …).
## Leave empty to auto-load the five default profiles from the vegetation folder.
## To customise a class, duplicate its .tres, edit values, and replace the entry.
@export var class_profiles : Array[ CampScatterProfile ] = []

@export_group( "Detection" )
## Enable colour/shape analysis of the aerial image. Disable when you only
## want to bake manually placed CampStamp markers.
@export var run_image_detection : bool = true
## Blobs smaller than this many pixels (in the downsampled work image) are
## discarded as noise. Raise this if you are getting too many false positives
## from dust/artifacts; lower it if small objects like bikes are missed.
@export_range( 1, 2000, 1 ) var min_blob_pixel_count : int = 8
## When multiple class profiles match the same region, keep only the highest-
## confidence match. Prevents duplicate objects at the same location.
@export var deduplicate_overlapping_classes : bool = true
## Two candidates of different classes within this world-space radius are
## considered duplicates. The lower-confidence one is dropped.
@export_range( 0.1, 30.0, 0.1 ) var deduplicate_radius_m : float = 1.5

@export_group( "Manual Editing" )
## NodePaths to Node3D nodes (typically MeshInstance3D boxes) that define
## regions where NO objects will be placed, regardless of image detections.
@export var exclusion_volumes : Array[ NodePath ] = []
## NodePaths to Node3D nodes that define regions where placement IS allowed.
## Only used when `restrict_detection_to_inclusion_volumes` is enabled.
@export var inclusion_volumes : Array[ NodePath ] = []
## When enabled, image detection only produces candidates inside the
## `inclusion_volumes` boxes. Useful for focusing on a specific camp area.
@export var restrict_detection_to_inclusion_volumes : bool = false
## List of CampForcedVolume resources. Any candidate inside a forced-volume
## box has its class overridden and confidence boosted to the volume's values.
@export var forced_class_volumes : Array[ CampForcedVolume ] = []
## When enabled, every CampStamp Marker3D child of this node is included in
## the bake as a manually-placed candidate. Disable to bake image detections only.
@export var include_stamps_in_bake : bool = true

@export_group( "Placement" )
## Random seed for placement jitter and random-yaw decisions. Change this to
## get a different spatial arrangement without re-baking from the image.
@export var seed_value : int = 2026
## Minimum centre-to-centre distance (metres) enforced across ALL classes.
## Each class profile's own `spacing_radius` also applies; the larger value wins.
@export_range( 0.0, 50.0, 0.1 ) var minimum_spacing_radius : float = 1.0
## Random XZ offset (metres) added to every placed candidate. Adds organic
## variation so objects don't sit exactly on the detected centroid.
@export_range( 0.0, 5.0, 0.01 ) var position_jitter_meters : float = 0.0
## Hard cap on total placed instances across all classes. Bake stops accepting
## new candidates once this is reached (highest-confidence ones survive).
@export_range( 10, 200000, 10 ) var max_instances_total : int = 12000

@export_group( "Editor Preview" )
## Show coloured dot preview in the 3D editor viewport after baking.
## Each dot represents one placed candidate. Toggle off if the scene feels cluttered.
@export var show_editor_preview : bool = true : set = _set_show_editor_preview
## Maximum dots drawn in the preview. Lower this if the viewport slows down.
@export_range( 10, 50000, 10 ) var editor_preview_max_points : int = 5000
## World-space radius of each preview dot sphere in metres.
@export_range( 0.02, 4.0, 0.02 ) var editor_preview_dot_size : float = 0.25
## Colour scheme for the preview dots.
## Class = one colour per object class. Confidence = green→red gradient.
## Source = blue for image-detected, yellow for manual stamps.
@export_enum( "Class", "Confidence", "Source" ) var preview_color_mode : int = 0
## Show/hide popup tent candidates in the preview and spawned instances.
@export var show_popup_tents : bool = true
## Show/hide RV candidates in the preview and spawned instances.
@export var show_rvs : bool = true
## Show/hide camping tent candidates in the preview and spawned instances.
@export var show_camping_tents : bool = true
## Show/hide shade structure candidates in the preview and spawned instances.
@export var show_shade_structures : bool = true
## Show/hide car candidates in the preview and spawned instances.
@export var show_cars : bool = true

@export_group( "Actions" )
## Tick this checkbox to run the full pipeline: image detection + all CampStamp
## markers. The checkbox resets itself after the action starts.
@export var bake_now : bool = false : set = _set_bake_now
## Tick to bake only CampStamp children without re-running image detection.
## Useful after manually placing or moving stamps.
@export var bake_manual_stamps_only : bool = false : set = _set_bake_manual_stamps_only
## Tick to update every AUTO_DETECT_FROM_IMAGE CampStamp's marker rotation from
## the aerial photo. This does not bake; it only rotates markers for inspection.
@export var auto_orient_stamps_now : bool = false : set = _set_auto_orient_stamps_now
## Tick to print per-class detection counts and confidence data without saving
## or spawning anything. Use this to tune class profile thresholds.
@export var diagnose_detection : bool = false : set = _set_diagnose_detection
## Tick to reload the saved bake file and redraw spawned instances/preview dots.
@export var refresh_preview : bool = false : set = _set_refresh_preview
## Tick to delete the saved bake file and remove spawned camp instances.
## CampStamp markers are left untouched.
@export var clear_bake : bool = false : set = _set_clear_bake
## Tick to hide the editor preview dots. This does not delete the saved bake.
@export var hide_preview_now : bool = false : set = _set_hide_preview_now
## Tick to write the current bake to readable JSON beside the .tres bake file.
@export var export_candidates : bool = false : set = _set_export_candidates
## Tick to create a new CampStamp Marker3D child at the CampScatter origin.
@export var add_stamp_at_origin : bool = false : set = _set_add_stamp_at_origin
## Tick to create a visible horizontal PlaneMesh textured with the aerial image.
## Move/scale/rotate this plane until it lines up with the 3D terrain, then
## enable `use_aerial_reference_plane` and bake.
@export var create_aerial_reference_plane : bool = false : set = _set_create_aerial_reference_plane

@export_subgroup( "Last Bake Stats" )
## Read-only. Total placed candidates saved in the last bake (after spacing filters).
@export var last_bake_count : int = 0
## Read-only. Image-detection candidates before the stamp merge in the last run.
@export var last_detected_count : int = 0
## Read-only. CampStamp-sourced candidates included in the last run.
@export var last_stamp_count : int = 0

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

var _baked_root : Node3D = null
var _preview_instance : MultiMeshInstance3D = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void :
	set_process( Engine.is_editor_hint() )
	_ensure_default_profiles()
	_ensure_baked_root()
	_refresh_baked_instances()
	_refresh_editor_preview()


func _process( _delta : float ) -> void :
	if not Engine.is_editor_hint() :
		return
	_consume_editor_actions()


# ---------------------------------------------------------------------------
# Inspector toggle setters
# ---------------------------------------------------------------------------

func _set_show_editor_preview( value : bool ) -> void :
	show_editor_preview = value
	if Engine.is_editor_hint() :
		_refresh_editor_preview()


func _set_bake_now( value : bool ) -> void :
	bake_now = false
	if value :
		_queue_editor_action( "bake_full" )


func _set_bake_manual_stamps_only( value : bool ) -> void :
	bake_manual_stamps_only = false
	if value :
		_queue_editor_action( "bake_stamps" )


func _set_auto_orient_stamps_now( value : bool ) -> void :
	auto_orient_stamps_now = false
	if value :
		_queue_editor_action( "auto_orient" )


func _set_diagnose_detection( value : bool ) -> void :
	diagnose_detection = false
	if value :
		_queue_editor_action( "diagnose" )


func _set_refresh_preview( value : bool ) -> void :
	refresh_preview = false
	if value :
		_queue_editor_action( "refresh" )


func _set_clear_bake( value : bool ) -> void :
	clear_bake = false
	if value :
		_queue_editor_action( "clear" )


func _set_hide_preview_now( value : bool ) -> void :
	hide_preview_now = false
	if value :
		_queue_editor_action( "hide_preview" )


func _set_export_candidates( value : bool ) -> void :
	export_candidates = false
	if value :
		_queue_editor_action( "export_json" )


func _set_add_stamp_at_origin( value : bool ) -> void :
	add_stamp_at_origin = false
	if value :
		_queue_editor_action( "add_stamp" )


func _set_create_aerial_reference_plane( value : bool ) -> void :
	create_aerial_reference_plane = false
	if value :
		_queue_editor_action( "create_aerial_reference" )


func _queue_editor_action( action : StringName ) -> void :
	print( "[CampScatter] Inspector action queued: %s" % action )
	call_deferred( "_run_editor_action", action )


func _run_editor_action( action : StringName ) -> void :
	print( "[CampScatter] Running inspector action: %s" % action )
	match action :
		&"bake_full" :
			bake( true, true )
		&"bake_stamps" :
			bake( false, true )
		&"auto_orient" :
			auto_orient_stamps()
		&"diagnose" :
			diagnose()
		&"refresh" :
			_refresh_baked_instances()
			_refresh_editor_preview()
		&"clear" :
			_clear_baked_output()
		&"hide_preview" :
			_hide_editor_preview()
		&"export_json" :
			_export_baked_candidates_json()
		&"add_stamp" :
			_add_stamp_at_origin()
		&"create_aerial_reference" :
			_create_aerial_reference_plane()
		_ :
			push_warning( "[CampScatter] Unknown inspector action: %s" % action )


func _consume_editor_actions() -> void :
	if bake_now :
		bake_now = false
		print( "[CampScatter] Bake Now requested from inspector." )
		bake( true, true )
	if bake_manual_stamps_only :
		bake_manual_stamps_only = false
		print( "[CampScatter] Bake Stamps Only requested from inspector." )
		bake( false, true )
	if auto_orient_stamps_now :
		auto_orient_stamps_now = false
		print( "[CampScatter] Auto-Orient Stamps requested from inspector." )
		auto_orient_stamps()
	if diagnose_detection :
		diagnose_detection = false
		print( "[CampScatter] Diagnose Detection requested from inspector." )
		diagnose()
	if refresh_preview :
		refresh_preview = false
		print( "[CampScatter] Refresh Preview requested from inspector." )
		_refresh_baked_instances()
		_refresh_editor_preview()
	if clear_bake :
		clear_bake = false
		print( "[CampScatter] Clear Bake requested from inspector." )
		_clear_baked_output()
	if hide_preview_now :
		hide_preview_now = false
		print( "[CampScatter] Hide Preview requested from inspector." )
		_hide_editor_preview()
	if export_candidates :
		export_candidates = false
		print( "[CampScatter] Export Candidates requested from inspector." )
		_export_baked_candidates_json()
	if add_stamp_at_origin :
		add_stamp_at_origin = false
		print( "[CampScatter] Add Stamp requested from inspector." )
		_add_stamp_at_origin()
	if create_aerial_reference_plane :
		create_aerial_reference_plane = false
		print( "[CampScatter] Create Aerial Reference Plane requested from inspector." )
		_create_aerial_reference_plane()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Runs the full bake pipeline. `include_detection` runs the image scanner;
## `include_stamps` processes every CampStamp under this node. The two
## results are merged through the same placement rules.
func bake( include_detection : bool, include_stamps : bool ) -> void :
	_ensure_default_profiles()

	if class_profiles.is_empty() :
		push_error( "[CampScatter] No class profiles loaded. Check that the .tres files exist at: %s" % str( DEFAULT_PROFILE_PATHS ) )
		return

	_ensure_baked_dir()

	print( "[CampScatter] ── Bake started  (detection=%s  stamps=%s  profiles=%d) ──" % [
		str( include_detection ), str( include_stamps ), class_profiles.size()
	] )

	var source_image : Image = null
	var work_image : Image = null
	var bounds : Rect2 = _resolve_world_bounds()
	print( "[CampScatter] World bounds: origin=%s  size=%s" % [ str( bounds.position ), str( bounds.size ) ] )
	var ref_node : Node3D = _get_aerial_reference_node()
	if ref_node != null :
		print( "[CampScatter] Mapping aerial pixels through reference plane: %s" % ref_node.get_path() )
	if bounds.size.x <= 0.001 or bounds.size.y <= 0.001 :
		push_error( "[CampScatter] Invalid world bounds — set 'world_bounds_min/max_xz' or connect a terrain node." )
		return

	if include_detection and run_image_detection :
		print( "[CampScatter] Loading aerial image from '%s'..." % aerial_image_path )
		source_image = _load_source_image()
		if source_image == null :
			push_warning( "[CampScatter] No aerial image loaded. Check 'aerial_image_path' or assign 'aerial_texture'." )
		else :
			print( "[CampScatter] Source image: %d × %d px" % [ source_image.get_width(), source_image.get_height() ] )
			work_image = _make_work_image( source_image )
			print( "[CampScatter] Work image:   %d × %d px" % [ work_image.get_width(), work_image.get_height() ] )

	# Image-only candidates may need image-derived data so we keep work_image
	# in scope for stamp auto-detection too.
	if work_image == null and include_stamps :
		var src : Image = _load_source_image()
		if src != null :
			work_image = _make_work_image( src )
			if source_image == null :
				source_image = src

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var detected : Array[ CampScatterCandidate ] = []
	if include_detection and run_image_detection and work_image != null :
		print( "[CampScatter] Running image detection..." )
		detected = _detect_candidates( work_image, bounds, rng )
		print( "[CampScatter] Raw detections: %d" % detected.size() )
		if deduplicate_overlapping_classes :
			detected = _deduplicate_candidates( detected )
			print( "[CampScatter] After dedup:   %d" % detected.size() )
	elif include_detection and run_image_detection and work_image == null :
		print( "[CampScatter] Skipping detection — no work image." )

	var stamps : Array[ CampScatterCandidate ] = []
	if include_stamps and include_stamps_in_bake :
		stamps = _process_manual_stamps( work_image, bounds, rng )
		print( "[CampScatter] Manual stamps processed: %d" % stamps.size() )

	last_detected_count = detected.size()
	last_stamp_count = stamps.size()

	var combined : Array[ CampScatterCandidate ] = []
	combined.append_array( stamps )    # stamps placed first → highest priority
	combined.append_array( detected )

	combined.sort_custom( _sort_candidates_for_placement )
	var placed : Array[ CampScatterCandidate ] = _place_candidates( combined, rng )
	print( "[CampScatter] After placement filter: %d candidates" % placed.size() )

	var bake_resource := CampScatterBake.new()
	bake_resource.candidates = placed
	bake_resource.generated_at_unix = int( Time.get_unix_time_from_system() )
	bake_resource.source_image_path = aerial_image_path
	if source_image != null :
		bake_resource.source_image_size = Vector2i( source_image.get_width(), source_image.get_height() )
	if work_image != null :
		bake_resource.downsampled_size = Vector2i( work_image.get_width(), work_image.get_height() )

	print( "[CampScatter] Saving bake to '%s'..." % BAKED_CANDIDATES_PATH )
	var err : int = ResourceSaver.save( bake_resource, BAKED_CANDIDATES_PATH )
	if err != OK :
		push_error( "[CampScatter] Failed to save bake — error %d. Check that the 'vegetation/baked/' folder exists under the project." % err )
		return

	last_bake_count = placed.size()
	print( "[CampScatter] ── Bake complete: detected=%d  stamps=%d  placed=%d → %s ──" % [
		detected.size(), stamps.size(), placed.size(), BAKED_CANDIDATES_PATH
	] )
	_refresh_baked_instances()
	_refresh_editor_preview()


## For every CampStamp set to AUTO_DETECT_FROM_IMAGE, samples the aerial
## around its world position, fits a rotated bounding box, and writes the
## resulting yaw back into the stamp's Y rotation so the user can verify
## the orientation before baking.
func auto_orient_stamps() -> void :
	_ensure_default_profiles()
	var source_image : Image = _load_source_image()
	if source_image == null :
		push_error( "[CampScatter] auto_orient_stamps: no aerial image available." )
		return
	var work_image : Image = _make_work_image( source_image )
	var bounds : Rect2 = _resolve_world_bounds()
	if bounds.size.x <= 0.001 or bounds.size.y <= 0.001 :
		push_error( "[CampScatter] auto_orient_stamps: invalid bounds." )
		return

	var stamps : Array[ CampStamp ] = _collect_stamps()
	var updated : int = 0
	for stamp in stamps :
		if stamp == null :
			continue
		if stamp.orientation_mode != CampStamp.OrientationMode.AUTO_DETECT_FROM_IMAGE :
			continue
		var profile : CampScatterProfile = _profile_for_class( stamp.class_id )
		if profile == null :
			continue
		var result : Dictionary = _auto_orient_at_world_position(
			stamp.global_position, profile, work_image, bounds
		)
		if not result.is_empty() :
			# Set world Y rotation: convert through global_basis so we respect
			# any rotation of CampScatter itself.
			var current_euler : Vector3 = stamp.global_basis.get_euler()
			current_euler.y = result.heading
			stamp.global_basis = Basis.from_euler( current_euler )
			stamp.last_auto_heading_degrees = rad_to_deg( result.heading )
			stamp.last_auto_footprint = result.footprint
			updated += 1
	print( "[CampScatter] auto_orient_stamps: updated %d / %d stamps" % [ updated, stamps.size() ] )


## Print blob/confidence statistics per class without saving anything.
func diagnose() -> void :
	_ensure_default_profiles()
	var source_image : Image = _load_source_image()
	if source_image == null :
		push_error( "[CampScatter] Diagnose failed: no aerial image." )
		return
	var work_image : Image = _make_work_image( source_image )
	var bounds : Rect2 = _resolve_world_bounds()
	if bounds.size.x <= 0.001 or bounds.size.y <= 0.001 :
		push_error( "[CampScatter] Diagnose failed: invalid bounds." )
		return

	var mpp : Vector2 = _meters_per_pixel( work_image, bounds )
	var m2_per_pixel : float = maxf( mpp.x * mpp.y, 0.0001 )
	print( "[CampScatter] Diagnose image=%dx%d (source=%dx%d) m2_per_pixel=%.4f bounds=%s" % [
		work_image.get_width(), work_image.get_height(),
		source_image.get_width(), source_image.get_height(), m2_per_pixel, str( bounds )
	] )

	for profile in class_profiles :
		if profile == null :
			continue
		var mask : PackedByteArray = _build_profile_mask( work_image, profile )
		var components : Array[ Dictionary ] = _extract_connected_components(
			mask, work_image.get_width(), work_image.get_height()
		)
		var accepted : int = 0
		var bins : PackedInt32Array = PackedInt32Array( [ 0, 0, 0, 0, 0 ] )
		for component in components :
			var analysis : Dictionary = _analyze_component( component, mpp, profile )
			var bin_idx : int = clampi( int( floor( analysis.confidence * 5.0 ) ), 0, 4 )
			bins[ bin_idx ] += 1
			if analysis.confidence >= profile.confidence_threshold :
				accepted += 1
		print( "[CampScatter]   %-18s blobs=%4d accepted=%4d conf-bins[0.0-1.0]=%s" % [
			String( profile.class_id ), components.size(), accepted, str( bins )
		] )


# ---------------------------------------------------------------------------
# Detection pipeline
# ---------------------------------------------------------------------------

func _detect_candidates( work_image : Image, bounds : Rect2, rng : RandomNumberGenerator ) -> Array[ CampScatterCandidate ] :
	var out : Array[ CampScatterCandidate ] = []
	var width : int = work_image.get_width()
	var height : int = work_image.get_height()
	var mpp : Vector2 = _meters_per_pixel( work_image, bounds )
	var blob_id : int = 0

	# Optional: build a mask of pixels that lie within inclusion volumes when
	# restrict_detection_to_inclusion_volumes is on.
	var include_pixel_mask : PackedByteArray = PackedByteArray()
	var use_include_mask : bool = restrict_detection_to_inclusion_volumes and not inclusion_volumes.is_empty()
	if use_include_mask :
		include_pixel_mask = _build_inclusion_volume_pixel_mask( width, height, bounds )

	for profile in class_profiles :
		if profile == null :
			continue
		print( "[CampScatter]   Scanning '%s'..." % profile.class_id )
		var mask : PackedByteArray = _build_profile_mask( work_image, profile )
		if use_include_mask :
			for i in mask.size() :
				if include_pixel_mask[ i ] == 0 :
					mask[ i ] = 0
		var components : Array[ Dictionary ] = _extract_connected_components( mask, width, height )
		print( "[CampScatter]   '%s': %d blobs (before size/confidence filter)" % [ profile.class_id, components.size() ] )
		var passed_size : int = 0
		var passed_confidence : int = 0

		for component in components :
			if int( component.pixel_count ) < min_blob_pixel_count :
				continue
			passed_size += 1
			var analysis : Dictionary = _analyze_component( component, mpp, profile )
			if analysis.confidence < profile.confidence_threshold :
				continue
			passed_confidence += 1
			var heading : float = _resolve_heading( analysis, profile, rng, true )
			var centroid_px : Vector2 = analysis.centroid
			var world_xz : Vector2 = _pixel_centroid_to_world_xz( centroid_px, Vector2( width, height ), bounds )

			var candidate := CampScatterCandidate.new()
			candidate.class_id = profile.class_id
			candidate.confidence = analysis.confidence
			candidate.world_position = Vector3(
				world_xz.x,
				_sample_world_height( world_xz ) + profile.y_offset,
				world_xz.y
			)
			candidate.footprint_size = analysis.footprint
			candidate.heading_radians = heading
			candidate.source = CampScatterCandidate.Source.IMAGE_DETECTION
			candidate.source_blob_id = blob_id
			candidate.bounds_min_px = Vector2i( component.min_x, component.min_y )
			candidate.bounds_max_px = Vector2i( component.max_x, component.max_y )
			_apply_forced_class_overrides( candidate )
			out.append( candidate )
			blob_id += 1
		print( "[CampScatter]   '%s': %d passed size, %d passed confidence → %d candidates so far" % [
			profile.class_id, passed_size, passed_confidence, out.size()
		] )
	return out


func _process_manual_stamps( work_image : Image, bounds : Rect2, rng : RandomNumberGenerator ) -> Array[ CampScatterCandidate ] :
	var stamps : Array[ CampStamp ] = _collect_stamps()
	var out : Array[ CampScatterCandidate ] = []
	var stamp_id : int = 0
	for stamp in stamps :
		if stamp == null or not stamp.include_in_bake :
			continue
		var profile : CampScatterProfile = _profile_for_class( stamp.class_id )
		var world_pos : Vector3 = stamp.global_position
		var world_xz : Vector2 = Vector2( world_pos.x, world_pos.z )
		var world_y : float = _sample_world_height( world_xz )
		if profile != null :
			world_y += profile.y_offset

		var stamp_world_yaw : float = stamp.global_basis.get_euler().y
		var heading : float = stamp_world_yaw
		var footprint : Vector2 = _default_footprint_for( profile )
		if not stamp.footprint_size_override.is_zero_approx() :
			footprint = stamp.footprint_size_override

		match stamp.orientation_mode :
			CampStamp.OrientationMode.AUTO_DETECT_FROM_IMAGE :
				if work_image != null and profile != null :
					var result : Dictionary = _auto_orient_at_world_position(
						Vector3( world_xz.x, world_y, world_xz.y ), profile, work_image, bounds
					)
					if not result.is_empty() :
						heading = result.heading
						if stamp.footprint_size_override.is_zero_approx() :
							footprint = result.footprint
			CampStamp.OrientationMode.RANDOM_YAW :
				heading = rng.randf() * TAU
			CampStamp.OrientationMode.MANUAL_YAW, CampStamp.OrientationMode.ALIGN_TO_TERRAIN_NORMAL :
				heading = stamp_world_yaw

		# Apply snap (stamp overrides profile if non-zero).
		var snap_deg : float = stamp.orientation_snap_degrees
		if snap_deg <= 0.0 and profile != null :
			snap_deg = profile.orientation_snap_degrees
		heading = _snap_angle( heading, snap_deg )

		var candidate := CampScatterCandidate.new()
		candidate.class_id = stamp.class_id
		candidate.confidence = clampf( stamp.confidence, 0.0, 1.0 )
		candidate.world_position = Vector3( world_xz.x, world_y, world_xz.y )
		candidate.footprint_size = footprint
		candidate.heading_radians = heading
		candidate.source = CampScatterCandidate.Source.MANUAL_STAMP
		candidate.source_blob_id = stamp_id
		candidate.stamp_node_path = get_path_to( stamp )
		_apply_forced_class_overrides( candidate )
		out.append( candidate )
		stamp_id += 1
	return out


## Returns { heading: float, footprint: Vector2, confidence: float } or {} if
## the stamp doesn't sit on a detectable blob.
func _auto_orient_at_world_position( world_pos : Vector3, profile : CampScatterProfile, work_image : Image, bounds : Rect2 ) -> Dictionary :
	var width : int = work_image.get_width()
	var height : int = work_image.get_height()
	var mpp : Vector2 = _meters_per_pixel( work_image, bounds )

	var pixel : Vector2i = _world_xz_to_pixel( Vector2( world_pos.x, world_pos.z ), Vector2( width, height ), bounds )
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= width or pixel.y >= height :
		return {}

	# Search radius in pixels: how far from the click the blob can extend.
	var search_radius_m : float = 8.0
	if profile.expected_footprint_size.length() > 0.01 :
		search_radius_m = maxf( profile.expected_footprint_size.x, profile.expected_footprint_size.y ) * 1.25
	var radius_px : int = maxi( 3, int( ceil( search_radius_m / maxf( mpp.x, 0.0001 ) ) ) )

	# Crop a local window around the stamp, build the profile mask in that
	# window, find the blob containing or closest to the click.
	var min_x : int = maxi( pixel.x - radius_px, 0 )
	var min_y : int = maxi( pixel.y - radius_px, 0 )
	var max_x : int = mini( pixel.x + radius_px, width - 1 )
	var max_y : int = mini( pixel.y + radius_px, height - 1 )
	var local_w : int = max_x - min_x + 1
	var local_h : int = max_y - min_y + 1
	if local_w <= 1 or local_h <= 1 :
		return {}

	var local_mask : PackedByteArray = PackedByteArray()
	local_mask.resize( local_w * local_h )
	for ly in local_h :
		for lx in local_w :
			var ix : int = min_x + lx
			var iy : int = min_y + ly
			var c : Color = work_image.get_pixel( ix, iy )
			local_mask[ ly * local_w + lx ] = 1 if _pixel_matches_profile( c, profile ) else 0

	var components : Array[ Dictionary ] = _extract_connected_components( local_mask, local_w, local_h )
	if components.is_empty() :
		return {}

	# Pick the component containing the click; if none does, pick the nearest.
	var click_local : Vector2i = Vector2i( pixel.x - min_x, pixel.y - min_y )
	var best : Dictionary = {}
	var best_dist : float = INF
	for component in components :
		if int( component.pixel_count ) < maxi( 4, min_blob_pixel_count / 2 ) :
			continue
		var cx : float = component.sum_x / maxf( float( component.pixel_count ), 1.0 )
		var cy : float = component.sum_y / maxf( float( component.pixel_count ), 1.0 )
		var dist : float = Vector2( cx - float( click_local.x ), cy - float( click_local.y ) ).length()
		var contains_click : bool = click_local.x >= component.min_x and click_local.x <= component.max_x \
			and click_local.y >= component.min_y and click_local.y <= component.max_y
		if contains_click :
			best = component
			break
		if dist < best_dist :
			best_dist = dist
			best = component
	if best.is_empty() :
		return {}

	var analysis : Dictionary = _analyze_component( best, mpp, profile )
	var heading : float = _resolve_heading( analysis, profile, null, false )
	return {
		"heading": heading,
		"footprint": analysis.footprint,
		"confidence": analysis.confidence
	}


# ---------------------------------------------------------------------------
# Image processing helpers
# ---------------------------------------------------------------------------

func _pixel_matches_profile( c : Color, profile : CampScatterProfile ) -> bool :
	var luma : float = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	if luma < profile.min_luma or luma > profile.max_luma :
		return false
	if c.s < profile.min_saturation or c.s > profile.max_saturation :
		return false
	if c.v < profile.min_value or c.v > profile.max_value :
		return false
	return true


func _build_profile_mask( image : Image, profile : CampScatterProfile ) -> PackedByteArray :
	var width : int = image.get_width()
	var height : int = image.get_height()
	var mask : PackedByteArray = PackedByteArray()
	mask.resize( width * height )
	for y in height :
		for x in width :
			var c : Color = image.get_pixel( x, y )
			mask[ y * width + x ] = 1 if _pixel_matches_profile( c, profile ) else 0
	return mask


func _build_inclusion_volume_pixel_mask( width : int, height : int, bounds : Rect2 ) -> PackedByteArray :
	var mask : PackedByteArray = PackedByteArray()
	mask.resize( width * height )
	if inclusion_volumes.is_empty() :
		return mask
	for y in height :
		for x in width :
			var world_xz : Vector2 = _pixel_centroid_to_world_xz(
				Vector2( float( x ) + 0.5, float( y ) + 0.5 ),
				Vector2( width, height ),
				bounds
			)
			var pos : Vector3 = Vector3( world_xz.x, 0.0, world_xz.y )
			mask[ y * width + x ] = 1 if _is_in_any_volume( pos, inclusion_volumes ) else 0
	return mask


## 4-connected flood-fill connected-component extraction. Stores pixel-list
## per component so we can do an oriented bounding box later.
func _extract_connected_components( mask : PackedByteArray, width : int, height : int ) -> Array[ Dictionary ] :
	var components : Array[ Dictionary ] = []
	var visited : PackedByteArray = PackedByteArray()
	visited.resize( width * height )

	for y in height :
		for x in width :
			var idx : int = y * width + x
			if mask[ idx ] == 0 or visited[ idx ] == 1 :
				continue

			var pixels : PackedVector2Array = PackedVector2Array()
			var queue : Array[ Vector2i ] = [ Vector2i( x, y ) ]
			visited[ idx ] = 1
			var q_head : int = 0
			var count : int = 0
			var min_x : int = x
			var min_y : int = y
			var max_x : int = x
			var max_y : int = y
			var sum_x : float = 0.0
			var sum_y : float = 0.0

			while q_head < queue.size() :
				var p : Vector2i = queue[ q_head ]
				q_head += 1
				count += 1
				pixels.append( Vector2( float( p.x ), float( p.y ) ) )
				if p.x < min_x : min_x = p.x
				if p.y < min_y : min_y = p.y
				if p.x > max_x : max_x = p.x
				if p.y > max_y : max_y = p.y
				sum_x += float( p.x )
				sum_y += float( p.y )

				# 4-connected neighbours keep blobs from merging diagonally
				# through narrow noise specks.
				var nbrs : Array[ Vector2i ] = [
					Vector2i( p.x + 1, p.y ),
					Vector2i( p.x - 1, p.y ),
					Vector2i( p.x, p.y + 1 ),
					Vector2i( p.x, p.y - 1 ),
				]
				for nb in nbrs :
					if nb.x < 0 or nb.y < 0 or nb.x >= width or nb.y >= height :
						continue
					var nidx : int = nb.y * width + nb.x
					if mask[ nidx ] == 0 or visited[ nidx ] == 1 :
						continue
					visited[ nidx ] = 1
					queue.append( nb )

			components.append( {
				"pixel_count": count,
				"min_x": min_x,
				"min_y": min_y,
				"max_x": max_x,
				"max_y": max_y,
				"sum_x": sum_x,
				"sum_y": sum_y,
				"pixels": pixels,
			} )
	return components


## Build the per-blob analysis: confidence score, footprint, heading, etc.
## Returns:
##   {
##     centroid: Vector2 (pixel coords)
##     area_m2: float
##     aspect_ratio: float       # length / width, always >= 1
##     heading: float (radians)  # Godot world-Y rotation that aligns the
##                               # placed instance's local +X with the
##                               # rectangle's long axis.
##     footprint: Vector2        # (length_m, width_m)
##     confidence: float (0..1)
##     is_square: bool
##   }
func _analyze_component( component : Dictionary, mpp : Vector2, profile : CampScatterProfile ) -> Dictionary :
	var pixels : PackedVector2Array = component.pixels
	var pixel_count : int = component.pixel_count
	var cx : float = component.sum_x / maxf( float( pixel_count ), 1.0 )
	var cy : float = component.sum_y / maxf( float( pixel_count ), 1.0 )

	var area_m2 : float = float( pixel_count ) * mpp.x * mpp.y

	var rect : Dictionary = _min_area_rectangle( pixels, cx, cy )
	var length_px : float = maxf( rect.length, 1.0 )
	var width_px : float = maxf( rect.width, 1.0 )
	var aspect : float = length_px / width_px
	var heading : float = float( rect.heading )

	var avg_mpp : float = 0.5 * ( mpp.x + mpp.y )
	var footprint : Vector2 = Vector2( length_px * avg_mpp, width_px * avg_mpp )

	# Confidence: average three signals. Area match, aspect match, expected-size
	# match (when the profile specifies an expected_footprint_size).
	var area_score : float = _range_score( area_m2, profile.min_area_m2, profile.max_area_m2 )
	var aspect_score : float = _range_score( aspect, profile.min_aspect_ratio, profile.max_aspect_ratio )
	var expected_score : float = 1.0
	if profile.expected_footprint_size.length_squared() > 0.01 :
		var expected_l : float = maxf( profile.expected_footprint_size.x, profile.expected_footprint_size.y )
		var expected_w : float = minf( profile.expected_footprint_size.x, profile.expected_footprint_size.y )
		var l_score : float = clampf( 1.0 - absf( footprint.x - expected_l ) / maxf( expected_l, 0.5 ), 0.0, 1.0 )
		var w_score : float = clampf( 1.0 - absf( footprint.y - expected_w ) / maxf( expected_w, 0.5 ), 0.0, 1.0 )
		expected_score = 0.5 * ( l_score + w_score )

	var confidence : float = clampf( 0.45 * area_score + 0.25 * aspect_score + 0.30 * expected_score, 0.0, 1.0 )
	var is_square : bool = aspect < profile.min_aspect_for_oriented

	return {
		"centroid": Vector2( cx, cy ),
		"area_m2": area_m2,
		"aspect_ratio": aspect,
		"heading": heading,
		"footprint": footprint,
		"confidence": confidence,
		"is_square": is_square,
	}


## Find the rotated bounding box of minimum area for a set of pixel positions.
##
## Strategy: do a coarse sweep [0, 90) at 5° step, then a fine refinement
## in [-5°, +5°) around the best at 1° step. This is robust for both
## elongated objects (RVs, carports) and near-square objects (popups).
##
## Returns { heading, length, width, area }. `length` >= `width`; `heading`
## is the Godot world-Y rotation that puts the object's local +X along the
## long axis assuming the standard image-to-world mapping (px_x→world_X,
## px_y→world_-Z).
func _min_area_rectangle( pixels : PackedVector2Array, cx : float, cy : float ) -> Dictionary :
	if pixels.size() < 2 :
		return { "heading": 0.0, "length": 1.0, "width": 1.0, "area": 1.0 }

	var best : Dictionary = { "heading": 0.0, "length": 0.0, "width": 0.0, "area": INF }
	# Coarse sweep.
	for i in 18 :
		var deg : float = float( i ) * 5.0
		_evaluate_rect_at_angle( pixels, cx, cy, deg, best )
	# Fine refinement.
	var coarse_deg : float = rad_to_deg( float( best.heading ) )
	for j in 11 :
		var deg : float = coarse_deg - 5.0 + float( j )
		_evaluate_rect_at_angle( pixels, cx, cy, deg, best )

	return best


func _evaluate_rect_at_angle( pixels : PackedVector2Array, cx : float, cy : float, deg : float, best : Dictionary ) -> void :
	var rad : float = deg_to_rad( deg )
	var cos_t : float = cos( rad )
	var sin_t : float = sin( rad )
	var min_u : float = INF
	var max_u : float = -INF
	var min_v : float = INF
	var max_v : float = -INF
	for p in pixels :
		var dx : float = p.x - cx
		var dy : float = p.y - cy
		# Rotate pixel-space point by -rad so that the candidate axis aligns
		# with the +u axis. Pixel coords have Y down so rotation handedness
		# is opposite world. atan2 below compensates.
		var u : float = dx * cos_t + dy * sin_t
		var v : float = -dx * sin_t + dy * cos_t
		if u < min_u : min_u = u
		if u > max_u : max_u = u
		if v < min_v : min_v = v
		if v > max_v : max_v = v
	var extent_u : float = max_u - min_u
	var extent_v : float = max_v - min_v
	var area : float = extent_u * extent_v
	if area >= float( best.area ) :
		return

	# Heading is the world-Y rotation that aligns +X with the long side.
	# Pixel angle rad rotates the long axis toward +u (image x increases right,
	# image y down). World mapping: px_x → world_X, px_y → world_-Z. A vector
	# (cos rad, sin rad) in pixels maps to (cos rad, -sin rad) in (X, Z). The
	# Godot Y rotation ψ taking +X to (cos ψ, 0, -sin ψ) is ψ = rad.
	var heading : float = _image_axis_angle_to_world_heading( rad )
	var length : float = extent_u
	var width : float = extent_v
	# We want length >= width and heading along the long axis.
	if extent_v > extent_u :
		length = extent_v
		width = extent_u
		heading = _image_axis_angle_to_world_heading( rad + PI * 0.5 )
	# Normalise heading into (-PI/2, PI/2] so snap math is intuitive.
	heading = wrapf( heading, -PI * 0.5, PI * 0.5 )

	best.area = area
	best.heading = heading
	best.length = length
	best.width = width


func _resolve_heading( analysis : Dictionary, profile : CampScatterProfile, rng : RandomNumberGenerator, allow_random : bool ) -> float :
	var heading : float = float( analysis.heading )
	if profile.random_yaw_when_square and bool( analysis.is_square ) :
		if allow_random and rng != null :
			heading = rng.randf() * TAU
		else :
			heading = 0.0
	heading = _snap_angle( heading, profile.orientation_snap_degrees )
	if profile.max_yaw_jitter_degrees > 0.0 and allow_random and rng != null :
		var jitter : float = deg_to_rad( rng.randf_range( -profile.max_yaw_jitter_degrees, profile.max_yaw_jitter_degrees ) )
		heading += jitter
	return heading


func _snap_angle( angle : float, snap_degrees : float ) -> float :
	if snap_degrees <= 0.0 :
		return angle
	var snap_rad : float = deg_to_rad( snap_degrees )
	return round( angle / snap_rad ) * snap_rad


# ---------------------------------------------------------------------------
# Coordinate helpers
# ---------------------------------------------------------------------------

func _meters_per_pixel( image : Image, bounds : Rect2 ) -> Vector2 :
	var ref_node : Node3D = _get_aerial_reference_node()
	if ref_node != null :
		var aabb : AABB = _get_reference_local_aabb( ref_node )
		var left : Vector3 = ref_node.global_transform * Vector3( aabb.position.x, aabb.position.y, aabb.position.z )
		var right : Vector3 = ref_node.global_transform * Vector3( aabb.position.x + aabb.size.x, aabb.position.y, aabb.position.z )
		var top : Vector3 = ref_node.global_transform * Vector3( aabb.position.x, aabb.position.y, aabb.position.z + aabb.size.z )
		var bottom : Vector3 = ref_node.global_transform * Vector3( aabb.position.x, aabb.position.y, aabb.position.z )
		return Vector2(
			Vector2( left.x, left.z ).distance_to( Vector2( right.x, right.z ) ) / maxf( float( image.get_width() ), 1.0 ),
			Vector2( top.x, top.z ).distance_to( Vector2( bottom.x, bottom.z ) ) / maxf( float( image.get_height() ), 1.0 )
		)
	return Vector2(
		bounds.size.x / maxf( float( image.get_width() ), 1.0 ),
		bounds.size.y / maxf( float( image.get_height() ), 1.0 )
	)


## Convert a pixel coordinate (px center) into a world XZ position. Pixel +X
## maps to world +X; pixel +Y maps to world -Z (the aerial image is oriented
## so the top of the image is +Z, matching the user-confirmed alignment).
func _pixel_centroid_to_world_xz( pixel : Vector2, image_size : Vector2, bounds : Rect2 ) -> Vector2 :
	var u : float = ( pixel.x + 0.5 ) / image_size.x
	var v : float = ( pixel.y + 0.5 ) / image_size.y
	var ref_node : Node3D = _get_aerial_reference_node()
	if ref_node != null :
		var aabb : AABB = _get_reference_local_aabb( ref_node )
		var local_x : float = lerpf( aabb.position.x, aabb.position.x + aabb.size.x, u )
		var local_z : float = lerpf( aabb.position.z + aabb.size.z, aabb.position.z, v )
		var local_y : float = aabb.position.y + aabb.size.y * 0.5
		var world : Vector3 = ref_node.global_transform * Vector3( local_x, local_y, local_z )
		return Vector2( world.x, world.z )
	var world_x : float = lerpf( bounds.position.x, bounds.position.x + bounds.size.x, u )
	var world_z : float = lerpf( bounds.position.y + bounds.size.y, bounds.position.y, v )
	return Vector2( world_x, world_z )


func _world_xz_to_pixel( world_xz : Vector2, image_size : Vector2, bounds : Rect2 ) -> Vector2i :
	var ref_node : Node3D = _get_aerial_reference_node()
	if ref_node != null :
		var aabb : AABB = _get_reference_local_aabb( ref_node )
		var world_on_plane := Vector3( world_xz.x, ref_node.global_position.y, world_xz.y )
		var local : Vector3 = ref_node.global_transform.affine_inverse() * world_on_plane
		var u_ref : float = ( local.x - aabb.position.x ) / maxf( aabb.size.x, 0.0001 )
		var v_ref : float = 1.0 - ( local.z - aabb.position.z ) / maxf( aabb.size.z, 0.0001 )
		return Vector2i(
			int( floor( u_ref * image_size.x ) ),
			int( floor( v_ref * image_size.y ) )
		)
	var u : float = ( world_xz.x - bounds.position.x ) / maxf( bounds.size.x, 0.0001 )
	var v : float = 1.0 - ( world_xz.y - bounds.position.y ) / maxf( bounds.size.y, 0.0001 )
	var px : int = int( floor( u * image_size.x ) )
	var py : int = int( floor( v * image_size.y ) )
	return Vector2i( px, py )


func _image_axis_angle_to_world_heading( image_angle : float ) -> float :
	var ref_node : Node3D = _get_aerial_reference_node()
	if ref_node == null :
		return image_angle
	# Image +Y points down the photo, which maps to local -Z on the reference
	# plane. Convert the image-space axis to a local plane vector, transform it
	# through the placed plane, then convert that world XZ vector into Godot yaw.
	var local_dir := Vector3( cos( image_angle ), 0.0, -sin( image_angle ) )
	var world_dir : Vector3 = ref_node.global_basis * local_dir
	var xz := Vector2( world_dir.x, world_dir.z )
	if xz.length_squared() <= 0.000001 :
		return image_angle
	return atan2( -xz.y, xz.x )


func _get_aerial_reference_node() -> Node3D :
	if not use_aerial_reference_plane or aerial_reference_plane.is_empty() :
		return null
	return get_node_or_null( aerial_reference_plane ) as Node3D


func _get_reference_local_aabb( ref_node : Node3D ) -> AABB :
	if ref_node is MeshInstance3D :
		var mi := ref_node as MeshInstance3D
		if mi.mesh != null :
			var mesh_aabb : AABB = mi.mesh.get_aabb()
			if mesh_aabb.size.x > 0.0001 and mesh_aabb.size.z > 0.0001 :
				return mesh_aabb
	# Fallback assumes a one-metre horizontal rectangle centred on the node.
	return AABB( Vector3( -0.5, 0.0, -0.5 ), Vector3( 1.0, 0.0, 1.0 ) )


# ---------------------------------------------------------------------------
# Manual stamp helpers
# ---------------------------------------------------------------------------

func _collect_stamps() -> Array[ CampStamp ] :
	var out : Array[ CampStamp ] = []
	_collect_stamps_recursive( self, out )
	return out


func _collect_stamps_recursive( node : Node, out : Array[ CampStamp ] ) -> void :
	if node.name == BAKED_ROOT_NAME :
		# Don't descend into baked instances - they may contain unrelated
		# Marker3D children inside prefabs.
		return
	if node is CampStamp :
		out.append( node as CampStamp )
	for child in node.get_children() :
		_collect_stamps_recursive( child, out )


func _default_footprint_for( profile : CampScatterProfile ) -> Vector2 :
	if profile == null :
		return Vector2( 2.0, 2.0 )
	if profile.expected_footprint_size.length_squared() > 0.01 :
		return profile.expected_footprint_size
	return Vector2( profile.fallback_size.x, profile.fallback_size.z )


func _add_stamp_at_origin() -> void :
	var stamp := CampStamp.new()
	var class_id : StringName = &"popup_tent"
	if not class_profiles.is_empty() and class_profiles[ 0 ] != null :
		class_id = class_profiles[ 0 ].class_id
	stamp.class_id = class_id
	stamp.name = "CampStamp_%s" % String( class_id )
	add_child( stamp )
	var edited_root : Node = get_tree().edited_scene_root if get_tree() != null else null
	if edited_root != null :
		stamp.owner = edited_root
	stamp.position = Vector3.ZERO
	print( "[CampScatter] Added stamp '%s' as child. Drag it to the desired position in the 3D viewport." % stamp.name )


func _create_aerial_reference_plane() -> void :
	var existing : Node3D = get_node_or_null( aerial_reference_plane ) as Node3D
	if existing != null :
		_make_reference_plane_world_space( existing )
		if existing is MeshInstance3D :
			_apply_aerial_reference_material( existing as MeshInstance3D )
		print( "[CampScatter] Aerial reference plane already assigned; refreshed material: %s" % existing.get_path() )
		return

	var plane := MeshInstance3D.new()
	plane.name = "AerialReferencePlane"
	plane.mesh = _make_aerial_reference_mesh( Vector2( 100.0, 100.0 ) )
	_apply_aerial_reference_material( plane )

	add_child( plane )
	plane.top_level = true
	var edited_root : Node = get_tree().edited_scene_root if get_tree() != null else null
	if edited_root != null :
		plane.owner = edited_root

	plane.global_position = global_position + Vector3( 0.0, 2.0, 0.0 )
	aerial_reference_plane = get_path_to( plane )
	use_aerial_reference_plane = true
	use_target_terrain_bounds = false
	print( "[CampScatter] Created AerialReferencePlane. Scale/rotate/move it over the terrain, then bake. Reference path set to %s." % aerial_reference_plane )


func _make_reference_plane_world_space( ref_node : Node3D ) -> void :
	var saved_global_transform : Transform3D = ref_node.global_transform
	ref_node.top_level = true
	ref_node.global_transform = saved_global_transform


func _apply_aerial_reference_material( plane : MeshInstance3D ) -> void :
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.albedo_color = Color( 1.0, 1.0, 1.0, aerial_reference_plane_opacity )
	var tex : Texture2D = _load_aerial_texture_for_reference_plane()
	if tex != null :
		material.albedo_texture = tex
		print( "[CampScatter] Applied aerial texture to reference plane (%d x %d)." % [ tex.get_width(), tex.get_height() ] )
	else :
		push_warning( "[CampScatter] Could not load aerial texture for the reference plane. Assign the texture manually on the plane material." )
	plane.material_override = material


func _load_aerial_texture_for_reference_plane() -> Texture2D :
	if aerial_texture != null :
		return aerial_texture
	var image : Image = _load_source_image()
	if image == null :
		return null
	var max_dim : int = maxi( image.get_width(), image.get_height() )
	if max_dim > aerial_reference_preview_max_dimension :
		var scale : float = float( aerial_reference_preview_max_dimension ) / float( max_dim )
		var new_w : int = maxi( 64, int( round( float( image.get_width() ) * scale ) ) )
		var new_h : int = maxi( 64, int( round( float( image.get_height() ) * scale ) ) )
		image = image.duplicate()
		image.resize( new_w, new_h, Image.INTERPOLATE_LANCZOS )
		print( "[CampScatter] Downsampled reference plane texture to %d x %d for viewport display." % [ new_w, new_h ] )
	var texture := ImageTexture.create_from_image( image )
	return texture


func _make_aerial_reference_mesh( size : Vector2 ) -> ArrayMesh :
	var half_x : float = size.x * 0.5
	var half_z : float = size.y * 0.5
	var vertices := PackedVector3Array( [
		Vector3( -half_x, 0.0, half_z ),
		Vector3( half_x, 0.0, half_z ),
		Vector3( half_x, 0.0, -half_z ),
		Vector3( -half_x, 0.0, -half_z ),
	] )
	var uvs := PackedVector2Array( [
		Vector2( 0.0, 0.0 ),
		Vector2( 1.0, 0.0 ),
		Vector2( 1.0, 1.0 ),
		Vector2( 0.0, 1.0 ),
	] )
	var indices := PackedInt32Array( [ 0, 1, 2, 0, 2, 3 ] )
	var arrays : Array = []
	arrays.resize( Mesh.ARRAY_MAX )
	arrays[ Mesh.ARRAY_VERTEX ] = vertices
	arrays[ Mesh.ARRAY_TEX_UV ] = uvs
	arrays[ Mesh.ARRAY_INDEX ] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays( Mesh.PRIMITIVE_TRIANGLES, arrays )
	return mesh


# ---------------------------------------------------------------------------
# Placement / deduplication
# ---------------------------------------------------------------------------

func _deduplicate_candidates( detected : Array[ CampScatterCandidate ] ) -> Array[ CampScatterCandidate ] :
	if detected.size() < 2 :
		return detected
	var sorted : Array[ CampScatterCandidate ] = detected.duplicate()
	sorted.sort_custom( _sort_candidates_by_confidence )
	var kept : Array[ CampScatterCandidate ] = []
	for candidate in sorted :
		var conflict : bool = false
		for existing in kept :
			var d_xz : float = Vector2(
				existing.world_position.x - candidate.world_position.x,
				existing.world_position.z - candidate.world_position.z
			).length()
			if d_xz < deduplicate_radius_m :
				conflict = true
				break
		if not conflict :
			kept.append( candidate )
	return kept


func _place_candidates( combined : Array[ CampScatterCandidate ], rng : RandomNumberGenerator ) -> Array[ CampScatterCandidate ] :
	var accepted : Array[ CampScatterCandidate ] = []
	for candidate in combined :
		if accepted.size() >= max_instances_total :
			break
		if candidate == null :
			continue
		var world_pos : Vector3 = candidate.world_position
		if _is_in_any_volume( world_pos, exclusion_volumes ) :
			continue
		if _is_hidden_by_toggle( candidate.class_id ) :
			continue

		var profile : CampScatterProfile = _profile_for_class( candidate.class_id )
		var candidate_spacing : float = minimum_spacing_radius
		if profile != null :
			candidate_spacing = maxf( candidate_spacing, profile.spacing_radius )

		var conflict : bool = false
		for existing in accepted :
			var other_profile : CampScatterProfile = _profile_for_class( existing.class_id )
			var other_spacing : float = minimum_spacing_radius
			if other_profile != null :
				other_spacing = maxf( other_spacing, other_profile.spacing_radius )
			var spacing_needed : float = maxf( candidate_spacing, other_spacing )
			var d_xz : float = Vector2(
				existing.world_position.x - world_pos.x,
				existing.world_position.z - world_pos.z
			).length()
			if d_xz < spacing_needed :
				conflict = true
				break
		if conflict :
			continue

		var placed : CampScatterCandidate = candidate
		if position_jitter_meters > 0.0 and candidate.source == CampScatterCandidate.Source.IMAGE_DETECTION :
			placed = _duplicate_candidate( candidate )
			placed.world_position.x += rng.randf_range( -position_jitter_meters, position_jitter_meters )
			placed.world_position.z += rng.randf_range( -position_jitter_meters, position_jitter_meters )
		accepted.append( placed )
	return accepted


func _duplicate_candidate( c : CampScatterCandidate ) -> CampScatterCandidate :
	var copy := CampScatterCandidate.new()
	copy.class_id = c.class_id
	copy.confidence = c.confidence
	copy.world_position = c.world_position
	copy.footprint_size = c.footprint_size
	copy.heading_radians = c.heading_radians
	copy.source = c.source
	copy.source_blob_id = c.source_blob_id
	copy.stamp_node_path = c.stamp_node_path
	copy.bounds_min_px = c.bounds_min_px
	copy.bounds_max_px = c.bounds_max_px
	return copy


func _sort_candidates_by_confidence( a : CampScatterCandidate, b : CampScatterCandidate ) -> bool :
	return a.confidence > b.confidence


## Stamps win over image detection; within each source, sort by confidence.
func _sort_candidates_for_placement( a : CampScatterCandidate, b : CampScatterCandidate ) -> bool :
	if a.source != b.source :
		return a.source == CampScatterCandidate.Source.MANUAL_STAMP
	return a.confidence > b.confidence


func _apply_forced_class_overrides( candidate : CampScatterCandidate ) -> void :
	for entry in forced_class_volumes :
		if entry == null :
			continue
		var volume : Node3D = get_node_or_null( entry.volume_path ) as Node3D
		if volume == null :
			continue
		if _box_density_factor( candidate.world_position, volume ) > 0.0 :
			candidate.class_id = entry.class_id
			candidate.confidence = clampf( candidate.confidence + entry.confidence_boost, 0.0, 1.0 )


# ---------------------------------------------------------------------------
# World bounds + terrain height
# ---------------------------------------------------------------------------

func _resolve_world_bounds() -> Rect2 :
	var ref_node : Node3D = _get_aerial_reference_node()
	if ref_node != null :
		return _resolve_reference_plane_bounds( ref_node )
	if not use_target_terrain_bounds :
		return Rect2( world_bounds_min_xz, world_bounds_max_xz - world_bounds_min_xz )
	var terrain : Node = get_node_or_null( target_terrain )
	if terrain == null :
		return Rect2( world_bounds_min_xz, world_bounds_max_xz - world_bounds_min_xz )
	var mesh_nodes : Array[ MeshInstance3D ] = []
	_collect_mesh_instances( terrain, mesh_nodes )
	if mesh_nodes.is_empty() :
		return Rect2( world_bounds_min_xz, world_bounds_max_xz - world_bounds_min_xz )
	var min_x : float = INF
	var min_z : float = INF
	var max_x : float = -INF
	var max_z : float = -INF
	for mi in mesh_nodes :
		if mi.mesh == null :
			continue
		var aabb : AABB = mi.mesh.get_aabb()
		for corner in 8 :
			var c : Vector3 = aabb.get_endpoint( corner )
			var wc : Vector3 = mi.global_transform * c
			min_x = minf( min_x, wc.x )
			min_z = minf( min_z, wc.z )
			max_x = maxf( max_x, wc.x )
			max_z = maxf( max_z, wc.z )
	if not is_finite( min_x ) :
		return Rect2( world_bounds_min_xz, world_bounds_max_xz - world_bounds_min_xz )
	return Rect2( Vector2( min_x, min_z ), Vector2( max_x - min_x, max_z - min_z ) )


func _resolve_reference_plane_bounds( ref_node : Node3D ) -> Rect2 :
	var aabb : AABB = _get_reference_local_aabb( ref_node )
	var min_x : float = INF
	var min_z : float = INF
	var max_x : float = -INF
	var max_z : float = -INF
	for corner in 8 :
		var world : Vector3 = ref_node.global_transform * aabb.get_endpoint( corner )
		min_x = minf( min_x, world.x )
		min_z = minf( min_z, world.z )
		max_x = maxf( max_x, world.x )
		max_z = maxf( max_z, world.z )
	if not is_finite( min_x ) :
		return Rect2( world_bounds_min_xz, world_bounds_max_xz - world_bounds_min_xz )
	return Rect2( Vector2( min_x, min_z ), Vector2( max_x - min_x, max_z - min_z ) )


func _sample_world_height( world_xz : Vector2 ) -> float :
	if get_world_3d() == null :
		return fallback_world_y
	var state : PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if state == null :
		return fallback_world_y
	var from : Vector3 = Vector3( world_xz.x, raycast_start_height, world_xz.y )
	var to : Vector3 = Vector3( world_xz.x, raycast_start_height - raycast_depth, world_xz.y )
	var params := PhysicsRayQueryParameters3D.create( from, to )
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var hit : Dictionary = state.intersect_ray( params )
	if hit.is_empty() :
		return fallback_world_y
	return ( hit.position as Vector3 ).y


# ---------------------------------------------------------------------------
# Manual volumes
# ---------------------------------------------------------------------------

func _is_in_any_volume( world_pos : Vector3, volume_paths : Array[ NodePath ] ) -> bool :
	for path in volume_paths :
		var volume : Node3D = get_node_or_null( path ) as Node3D
		if volume == null :
			continue
		if _box_density_factor( world_pos, volume ) > 0.0 :
			return true
	return false


func _box_density_factor( world_pos : Vector3, volume : Node3D ) -> float :
	var local_pos : Vector3 = volume.global_transform.affine_inverse() * world_pos
	var half : Vector3 = Vector3( 0.5, 0.5, 0.5 )
	if "size" in volume :
		var sz : Variant = volume.get( "size" )
		if sz is Vector3 and ( sz as Vector3 ).length_squared() > 0.0 :
			half = ( sz as Vector3 ) * 0.5
	elif volume is MeshInstance3D :
		var mi_mesh : Mesh = ( volume as MeshInstance3D ).mesh
		if mi_mesh != null and "size" in mi_mesh :
			var mesh_sz : Variant = mi_mesh.get( "size" )
			if mesh_sz is Vector3 and ( mesh_sz as Vector3 ).length_squared() > 0.0 :
				half = ( mesh_sz as Vector3 ) * 0.5
	if half.x <= 0.0 or half.y <= 0.0 or half.z <= 0.0 :
		return 0.0
	if absf( local_pos.x ) > half.x : return 0.0
	if absf( local_pos.y ) > half.y : return 0.0
	if absf( local_pos.z ) > half.z : return 0.0
	return 1.0


# ---------------------------------------------------------------------------
# Spawning baked instances
# ---------------------------------------------------------------------------

func _load_bake_resource() -> CampScatterBake:
	if not ResourceLoader.exists(BAKED_CANDIDATES_PATH):
		return null
	return ResourceLoader.load(
		BAKED_CANDIDATES_PATH, "", ResourceLoader.CACHE_MODE_REPLACE
	) as CampScatterBake


func _refresh_baked_instances() -> void :
	_ensure_baked_root()
	# Clear previous children. Use free() (immediate) rather than queue_free()
	# because we're about to add new children with the same expected names.
	for child in _baked_root.get_children() :
		_baked_root.remove_child( child )
		child.free()

	var bake_resource : CampScatterBake = _load_bake_resource()
	if bake_resource == null :
		last_bake_count = 0
		return
	last_bake_count = bake_resource.candidates.size()

	# Bucket by class so we can switch between MultiMesh and scene instancing
	# in one pass per class.
	var buckets : Dictionary = {}
	for candidate in bake_resource.candidates :
		if candidate == null :
			continue
		if _is_hidden_by_toggle( candidate.class_id ) :
			continue
		var key : StringName = candidate.class_id
		if not buckets.has( key ) :
			buckets[ key ] = []
		( buckets[ key ] as Array ).append( candidate )

	var to_local : Transform3D = global_transform.affine_inverse()
	for class_id in buckets.keys() :
		var profile : CampScatterProfile = _profile_for_class( class_id )
		var bucket : Array = buckets[ class_id ]
		if profile != null and profile.scene != null and not profile.use_multimesh :
			_spawn_bucket_as_scenes( profile, bucket, to_local )
		else :
			_spawn_bucket_as_multimesh( profile, String( class_id ), bucket, to_local )


func _spawn_bucket_as_scenes( profile : CampScatterProfile, bucket : Array, to_local : Transform3D ) -> void :
	var container := Node3D.new()
	container.name = "Class_%s" % String( profile.class_id )
	_baked_root.add_child( container )
	for i in bucket.size() :
		var candidate : CampScatterCandidate = bucket[ i ]
		var inst : Node = profile.scene.instantiate()
		if not ( inst is Node3D ) :
			inst.queue_free()
			continue
		var node : Node3D = inst as Node3D
		node.name = "%s_%d" % [ String( profile.class_id ), i ]
		var basis : Basis = Basis( Vector3.UP, candidate.heading_radians )
		var local_pos : Vector3 = to_local * candidate.world_position
		node.transform = Transform3D( basis, local_pos )
		container.add_child( node )


func _spawn_bucket_as_multimesh( profile : CampScatterProfile, class_id : String, bucket : Array, to_local : Transform3D ) -> void :
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Class_%s_MM" % class_id
	_baked_root.add_child( mmi )

	var mesh : Mesh = null
	if profile != null and profile.multimesh_mesh != null :
		mesh = profile.multimesh_mesh
	else :
		mesh = _make_fallback_box_mesh( profile )
	if profile != null and not profile.cast_shadows :
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = bucket.size()

	for i in bucket.size() :
		var candidate : CampScatterCandidate = bucket[ i ]
		var basis : Basis = Basis( Vector3.UP, candidate.heading_radians )
		# Scale fallback boxes to match the candidate footprint so the user
		# can see real sizes even before assigning art.
		if profile != null and profile.multimesh_mesh == null :
			var box_size : Vector3 = profile.fallback_size
			var sx : float = candidate.footprint_size.x / maxf( box_size.x, 0.01 )
			var sz : float = candidate.footprint_size.y / maxf( box_size.z, 0.01 )
			# Only apply non-degenerate scales (footprint may be 0 from manual stamps).
			if sx > 0.01 and sz > 0.01 :
				basis = basis.scaled( Vector3( sx, 1.0, sz ) )
		var local_pos : Vector3 = to_local * candidate.world_position
		mm.set_instance_transform( i, Transform3D( basis, local_pos ) )

	mmi.multimesh = mm


func _make_fallback_box_mesh( profile : CampScatterProfile ) -> Mesh :
	var box := BoxMesh.new()
	if profile != null :
		box.size = profile.fallback_size
	else :
		box.size = Vector3( 2.0, 1.5, 2.0 )
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = profile.fallback_color if profile != null else Color( 1.0, 0.2, 0.2, 0.9 )
	box.material = material
	return box


# ---------------------------------------------------------------------------
# Editor preview (per-class colored dots)
# ---------------------------------------------------------------------------

func _refresh_editor_preview() -> void :
	_preview_instance = get_node_or_null( PREVIEW_NODE_NAME ) as MultiMeshInstance3D
	if _preview_instance == null :
		_preview_instance = MultiMeshInstance3D.new()
		_preview_instance.name = PREVIEW_NODE_NAME
		add_child( _preview_instance )

	if not show_editor_preview :
		_preview_instance.visible = false
		return

	var bake_resource : CampScatterBake = _load_bake_resource()
	if bake_resource == null or bake_resource.candidates.is_empty() :
		_preview_instance.visible = false
		return

	var visible_candidates : Array[ CampScatterCandidate ] = []
	for candidate in bake_resource.candidates :
		if candidate == null :
			continue
		if _is_hidden_by_toggle( candidate.class_id ) :
			continue
		visible_candidates.append( candidate )
	if visible_candidates.is_empty() :
		_preview_instance.visible = false
		return

	var stride : int = maxi( 1, int( ceil( float( visible_candidates.size() ) / float( editor_preview_max_points ) ) ) )
	var sampled : Array[ CampScatterCandidate ] = []
	for i in range( 0, visible_candidates.size(), stride ) :
		sampled.append( visible_candidates[ i ] )

	var dot_mesh := SphereMesh.new()
	dot_mesh.radius = editor_preview_dot_size
	dot_mesh.height = editor_preview_dot_size * 2.0
	dot_mesh.radial_segments = 6
	dot_mesh.rings = 4
	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.vertex_color_use_as_albedo = true
	dot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dot_mesh.material = dot_mat

	var preview_mm := MultiMesh.new()
	preview_mm.transform_format = MultiMesh.TRANSFORM_3D
	preview_mm.use_colors = true
	preview_mm.mesh = dot_mesh
	preview_mm.instance_count = sampled.size()

	var to_local : Transform3D = global_transform.affine_inverse()
	for i in sampled.size() :
		var c : CampScatterCandidate = sampled[ i ]
		var local_pos : Vector3 = to_local * c.world_position
		preview_mm.set_instance_transform( i, Transform3D( Basis.IDENTITY, local_pos ) )
		preview_mm.set_instance_color( i, _preview_color_for_candidate( c ) )

	_preview_instance.multimesh = preview_mm
	_preview_instance.visible = true


func _hide_editor_preview() -> void :
	_preview_instance = get_node_or_null( PREVIEW_NODE_NAME ) as MultiMeshInstance3D
	if _preview_instance != null :
		_preview_instance.visible = false
		_preview_instance.multimesh = null


func _preview_color_for_candidate( candidate : CampScatterCandidate ) -> Color :
	match preview_color_mode :
		1 :
			return Color( 1.0 - candidate.confidence, candidate.confidence, 0.1, 0.9 )
		2 :
			if candidate.source == CampScatterCandidate.Source.MANUAL_STAMP :
				return Color( 0.2, 0.8, 1.0, 0.95 )
			return Color( 1.0, 0.85, 0.2, 0.9 )
		_ :
			var profile : CampScatterProfile = _profile_for_class( candidate.class_id )
			if profile != null :
				return profile.fallback_color
			return Color( 1, 0, 0, 0.9 )


func _is_hidden_by_toggle( class_id : StringName ) -> bool :
	match String( class_id ) :
		"popup_tent" :
			return not show_popup_tents
		"rv" :
			return not show_rvs
		"camping_tent" :
			return not show_camping_tents
		"shade_structure" :
			return not show_shade_structures
		"car" :
			return not show_cars
		_ :
			return false


func _profile_for_class( class_id : StringName ) -> CampScatterProfile :
	for profile in class_profiles :
		if profile != null and profile.class_id == class_id :
			return profile
	return null


# ---------------------------------------------------------------------------
# Image IO
# ---------------------------------------------------------------------------

func _load_source_image() -> Image :
	var img : Image = null
	if aerial_texture != null :
		img = aerial_texture.get_image()
		if img != null and img.is_compressed() :
			var err : int = img.decompress()
			if err != OK :
				img = null
	if img == null and aerial_image_path != "" :
		var loaded := Image.new()
		var load_err : int = loaded.load( aerial_image_path )
		if load_err == OK :
			img = loaded
	if img == null or img.is_empty() :
		return null
	if img.get_format() != Image.FORMAT_RGBA8 :
		img.convert( Image.FORMAT_RGBA8 )
	return img


func _make_work_image( source : Image ) -> Image :
	var work : Image = source.duplicate()
	var w : int = source.get_width()
	var h : int = source.get_height()
	var max_dim : int = maxi( w, h )
	if max_dim <= max_work_image_dimension :
		return work
	var scale : float = float( max_work_image_dimension ) / float( max_dim )
	var nw : int = maxi( 64, int( round( float( w ) * scale ) ) )
	var nh : int = maxi( 64, int( round( float( h ) * scale ) ) )
	work.resize( nw, nh, Image.INTERPOLATE_LANCZOS )
	return work


func _collect_mesh_instances( root : Node, out_list : Array[ MeshInstance3D ] ) -> void :
	var stack : Array[ Node ] = [ root ]
	while not stack.is_empty() :
		var n : Node = stack.pop_back()
		for child in n.get_children() :
			stack.append( child )
		if n is MeshInstance3D :
			out_list.append( n as MeshInstance3D )


# ---------------------------------------------------------------------------
# Bookkeeping
# ---------------------------------------------------------------------------

func _ensure_default_profiles() -> void :
	if not class_profiles.is_empty() :
		return
	var loaded : Array[ CampScatterProfile ] = []
	for path in DEFAULT_PROFILE_PATHS :
		var p : CampScatterProfile = load( path ) as CampScatterProfile
		if p != null :
			loaded.append( p )
	if not loaded.is_empty() :
		class_profiles = loaded


func _ensure_baked_root() -> void :
	_baked_root = get_node_or_null( BAKED_ROOT_NAME ) as Node3D
	if _baked_root != null :
		return
	_baked_root = Node3D.new()
	_baked_root.name = BAKED_ROOT_NAME
	add_child( _baked_root )


func _ensure_baked_dir() -> void :
	# dir_exists_absolute / make_dir_recursive_absolute require a real OS path,
	# not a res:// virtual path. Globalize first so this works on all platforms.
	var abs_path : String = ProjectSettings.globalize_path( BAKED_DIR.rstrip( "/" ) )
	if DirAccess.dir_exists_absolute( abs_path ) :
		return
	var err : Error = DirAccess.make_dir_recursive_absolute( abs_path )
	if err != OK :
		push_error( "[CampScatter] Cannot create baked dir '%s': error %d" % [ abs_path, err ] )


func _clear_baked_output() -> void :
	var abs_bake_path : String = ProjectSettings.globalize_path( BAKED_CANDIDATES_PATH )
	if FileAccess.file_exists( abs_bake_path ) :
		var remove_err : Error = DirAccess.remove_absolute( abs_bake_path )
		if remove_err != OK :
			push_warning( "[CampScatter] Could not delete bake file '%s' (err %d)." % [ abs_bake_path, remove_err ] )
	last_bake_count = 0
	last_detected_count = 0
	last_stamp_count = 0
	_clear_baked_scene_nodes()
	_hide_editor_preview()
	print( "[CampScatter] Cleared bake output." )


func _clear_baked_scene_nodes() -> void :
	_baked_root = get_node_or_null( BAKED_ROOT_NAME ) as Node3D
	if _baked_root != null :
		for child in _baked_root.get_children() :
			_baked_root.remove_child( child )
			child.free()


func _export_baked_candidates_json() -> void :
	var bake_resource : CampScatterBake = _load_bake_resource()
	if bake_resource == null :
		push_warning( "[CampScatter] No bake found to export." )
		return
	var rows : Array[ Dictionary ] = []
	for c in bake_resource.candidates :
		if c == null :
			continue
		rows.append( {
			"class_id" : String( c.class_id ),
			"confidence" : c.confidence,
			"world_position" : [ c.world_position.x, c.world_position.y, c.world_position.z ],
			"footprint_size" : [ c.footprint_size.x, c.footprint_size.y ],
			"heading_radians" : c.heading_radians,
			"heading_degrees" : rad_to_deg( c.heading_radians ),
			"source" : ( "manual_stamp" if c.source == CampScatterCandidate.Source.MANUAL_STAMP else "image_detection" ),
			"source_blob_id" : c.source_blob_id,
		} )
	var file : FileAccess = FileAccess.open( EXPORTED_CANDIDATES_JSON_PATH, FileAccess.WRITE )
	if file == null :
		push_error( "[CampScatter] Failed to open JSON export path." )
		return
	file.store_string( JSON.stringify( rows, "\t" ) )
	file.close()
	print( "[CampScatter] Exported candidates JSON: %s" % EXPORTED_CANDIDATES_JSON_PATH )


# ---------------------------------------------------------------------------
# Misc utility
# ---------------------------------------------------------------------------

func _range_score( value : float, min_value : float, max_value : float ) -> float :
	if value >= min_value and value <= max_value :
		return 1.0
	if value < min_value :
		return clampf( 1.0 - ( ( min_value - value ) / maxf( min_value, 0.001 ) ), 0.0, 1.0 )
	return clampf( 1.0 - ( ( value - max_value ) / maxf( max_value, 0.001 ) ), 0.0, 1.0 )
