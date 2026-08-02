extends Node3D

## TerrainLoader — lives under the generated map scene (a Main shell with no baked
## terrain). On _ready it resolves the target location (from MapContext, or the
## scene's current/persisted coords as a fallback), routes it through
## Main.apply_location() so weather/sun/solar follow, then fetches elevation +
## imagery and builds the walkable terrain (ROADMAP Pillar 1).
##
## A temporary flat floor holds the player up while the async fetch runs; it is
## removed and the player re-seated once the real terrain exists. The world always
## loads even offline — failed fetches fall back to a flat grid / neutral drape.

signal options_status_changed(message: String, kind: String)
signal vegetation_operation_progress(message: String, fraction: float)
## Emitted once per full load sequence (base terrain + all post-terrain phases).
## `load_completed` latches true at the same moment for late subscribers
## (PlaytestHarness capture waits on this).
signal map_load_complete
## Fired when auto-veg MultiMeshes finish (or veg is disabled). Harness world
## captures wait on this so progressive large-map loads still get a full plate.
signal auto_vegetation_ready
signal climelapse_state_changed

const HALF_EXTENT_DEFAULT := 15000.0   # 30 km square
const DETAIL_HALF_EXTENT_DEFAULT := 1500.0
const OSM_HALF_EXTENT_DEFAULT := 1500.0
# Centre drape resolution. pick_zoom() picks the highest ESRI zoom whose stitched
# width stays <= DETAIL_TARGET_PX, so this is the real lever on sharpness: 2048 px
# only reaches z17 (~1.5 m/px) on the 3 km patch, while 4096 px reaches z18
# (~0.8 m/px) — roughly 2× sharper for the centre the player actually inspects.
# The 4096² RGB8 drape is ~48 MB VRAM (+mips); imagery uploads on its own settle
# frame (step 5), separate from the mesh/collider/building spike, so it does not
# stack onto the load-phase GPU peak. ESRI serves this source up to z19–23 globally;
# push DETAIL_TARGET_PX to 8192 (z19, ~0.4 m/px) only if VRAM/stitch RAM allows.
const DETAIL_TARGET_PX := 4096
## Capped at z19 — ESRI z20+ is metro-only and returns placeholder tiles elsewhere
## (same guard as HYPER_MAX_ZOOM); a failed detail layer leaves the centre blurry.
const DETAIL_MAX_ZOOM := 19
## "Hyper" ortho patch: a third imagery layer over the central ~1 km townsite at
## high ESRI zoom — the texture source for ortho-projected building roofs.
## CAPPED AT z19 (~0.24 m/px at lat 33): ESRI serves z20+ only in select metros
## and returns HTTP-200 "Map data not yet available" PLACEHOLDER tiles
## elsewhere — a z20 fetch at Bombay Beach cached an all-grey 8k mosaic and
## every roof sampled blank grey (ImageryService now also rejects near-uniform
## mosaics as a general guard). z19 over 1 km ≈ 230 tiles ≈ ~30 s first fetch,
## then PNG-cached. Override `[terrain] hyper_target_px=2048` in
## user://terrain_config.cfg for low-VRAM machines (z18, ~0.5 m/px). Fetched
## AFTER the detail layer, never gating load — it pops in like the detail drape.
const HYPER_HALF_EXTENT := 500.0
const HYPER_TARGET_PX_DEFAULT := 8192
const HYPER_MAX_ZOOM := 19

## User-configurable terrain imagery quality tiers (index 0..3). Higher tiers fetch
## higher-zoom ESRI tiles for the detail drape AND stretch the sharpest "hyper"
## layer over a larger walkable radius — sharper foot-level terrain (the sculpt
## tiles walk at 1.5 m/vertex, which exposes the drape's true m/px), at the cost of
## more VRAM and a longer first download (then PNG-cached). Only imagery changes;
## the sculpt mesh/collider density is untouched, so sculpt perf is unaffected.
## Persisted as [terrain] quality_tier in terrain_config.cfg; default = Medium (1),
## which matches the previous hard-coded 4096 detail / 500 m hyper behaviour.
const QUALITY_TIER_COUNT := 4
const QUALITY_TIER_DEFAULT := 1
const QUALITY_TIER_NAMES := ["Low", "Medium", "High", "Ultra"]
## Detail-drape stitch target (px) per tier — the real lever on centre sharpness.
const QUALITY_DETAIL_TARGET_PX := [2048, 4096, 8192, 8192]
## Hyper (sharpest) layer half-extent (m) per tier — how far the crispest imagery
## reaches from the site centre across the walkable zone.
const QUALITY_HYPER_HALF_EXTENT := [500.0, 500.0, 1000.0, 1500.0]
## Hyper stitch target (px) per tier (an explicit [terrain] hyper_target_px still wins).
const QUALITY_HYPER_TARGET_PX := [4096, 8192, 8192, 8192]

## AI "hero" patch: an opt-in Gemini-enhanced ground drape over a small square
## centred on the map origin, overlaid on top of hyper where the player spawns.
## One 2K image per site, cached, so it is a one-time API cost. Default OFF.
## Half-extent (m) — 50 m ⇒ 100 m square ⇒ ~0.05 m/px at 2K (≈5× sharper than hyper).
const AI_HERO_HALF_EXTENT_DEFAULT := 50.0
const AI_IMAGE_SIZE_DEFAULT := "2K"

const MESH_RES := TerrainBuilder.DEFAULT_MESH_RES
# The detail DEM is fetched at 512² but its real source resolution is only ~30–90 m
# (SRTM / Copernicus, or ~10 m USGS), so a 512² visual mesh + 512² HeightMapShape3D
# collider (262 k verts/cells over a 3 km patch = ~5.9 m spacing) is heavily
# oversampled — pure GPU/physics/RAM cost for no real fidelity, and the single
# biggest load-phase spike (overshooting it can exit the process with no error via a
# Windows GPU TDR / OOM on a fresh uncached load). The DEM is resampled to this
# resolution AS SOON AS IT ARRIVES (see _on_elevation_ready), so the mesh, the
# collider, AND footing queries (vegetation + building grounding) all share ONE
# surface — trees and buildings sit exactly on the ground the player sees and walks.
const DETAIL_MESH_RES := 256
const FPV_DRONE_SCENE := preload("res://scenes/gameplay/fpv_drone.tscn")
const DRONE_SPAWN_CLEARANCE_M := 0.1
const DRONE_SPAWN_OFFSET := Vector3(5.0, 0.0, 5.0)

# Spawn-clearing: when the map centre falls inside an OSM building footprint
# (e.g. the picked address is a rooftop), walk outward on a widening ring until
# an open-ground point is found so the player doesn't start trapped in the mesh.
const SPAWN_CLEAR_RING_STEP_M := 5.0
const SPAWN_CLEAR_MAX_RADIUS_M := 150.0
const SPAWN_CLEAR_ANGLE_STEPS := 16
# Extra push (m) past the first clear point so the player lands clearly outside
# the wall rather than flush against it.
const SPAWN_CLEAR_MARGIN_M := 3.0

const TERRAIN_EDIT_UI_SCRIPT := preload("res://scenes/ui/terrain_edit_ui.gd")
const TERRAIN_OPTIONS_UI_SCRIPT := preload("res://scenes/ui/terrain_options_ui.gd")
const VEGETATION_EDIT_UI_SCRIPT := preload("res://scenes/ui/vegetation_edit_ui.gd")
const VEGETATION_PREVIEW_EDITOR_SCRIPT := preload("res://scenes/ui/vegetation_preview_editor.gd")
const CAMP_SCATTER_UI_SCRIPT := preload("res://scenes/ui/camp_scatter_ui.gd")
const SPACE_EDIT_UI_SCRIPT := preload("res://scenes/ui/space_edit_ui.gd")
const PLACED_PROPS_UI_SCRIPT := preload("res://scenes/ui/placed_props_ui.gd")
const PLACED_PROP_EDIT_UI_SCRIPT: GDScript = preload("res://scenes/ui/placed_prop_edit_ui.gd")
const BUILDING_BUILDER_MODAL_SCRIPT := preload("res://scenes/ui/building_builder_modal.gd")
const POND_EDIT_MODAL_SCRIPT := preload("res://scenes/ui/pond_edit_ui.gd")
const STARSHADE_EDIT_MODAL_SCRIPT := preload("res://scenes/ui/starshade_edit_modal.gd")
const PALLET_RACK_BUILDER_MODAL_SCRIPT := preload("res://scenes/ui/pallet_rack_builder_modal.gd")
const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")
const PLACED_PROP_SERVICE_SCRIPT := preload("res://core/placed_models/placed_prop_service.gd")
const CONFIG_PATH := "user://terrain_config.cfg"
## Set true to print TerrainLoader[mem] breadcrumbs during load.
const DEBUG_LOAD := false
## Idle frames between heavy GPU apply steps (mesh upload, shader compile, scatter).
const SETTLE_FRAMES := 3

var _main: Node = null
## True once the full load sequence has finished at least once (see map_load_complete).
var load_completed := false
## True once auto-veg scatter finished (or was skipped). Independent of load_completed
## on large maps where scatter runs in the background after walkable.
var auto_veg_ready := false
var _lat := 0.0
var _lon := 0.0
var _map_label := ""
var _half_extent := HALF_EXTENT_DEFAULT
var _detail_half_extent := DETAIL_HALF_EXTENT_DEFAULT
var _osm_half_extent := OSM_HALF_EXTENT_DEFAULT
var _seam_feather_m := TerrainBuilder.DEFAULT_FEATHER_M
var _detail_vertical_offset := 0.0
## Slide OSM geometry onto imagery (m): +east / +north. Raw Overpass/cache stays
## unoffset in _osm_vectors_raw / _auto_veg_data_raw; applied copies feed attach.
var _osm_offset_east_m := 0.0
var _osm_offset_north_m := 0.0
## True after the player nudges or locks an auto-seed (don't re-overwrite).
var _osm_offset_user_set := false
var _osm_vectors_raw: Dictionary = {}
var _auto_veg_data_raw: Dictionary = {}
var _from_resume := false
var _force_refetch := false
## True when this launch skipped loading user:// placed props / building styles
## (fresh / no-cache). Prevents reground from wiping the on-disk prop file.
var _user_overlays_ephemeral := false
## Terrain UI: show/hide DEM+OSM world geometry (does NOT control cache loading —
## map-select "Load from cache" / _force_refetch is the source of truth for that).
var _cached_geometry_visible := true

var _elev_grid := PackedFloat32Array()
var _elev_cols := 0
var _elev_rows := 0
var _elev_done := false
var _drape: Texture2D = null
var _img_done := false
var _detail_drape: Texture2D = null
var _hyper_drape: Texture2D = null
## Gemini-enhanced hero patch drape + its geo bbox (null until generated/cached).
var _ai_drape: Texture2D = null
var _ai_bbox: Dictionary = {}
var _ai_request_active := false
var _built := false
var _spawn_ground_y := 0.0
var _built_grid := PackedFloat32Array()
var _built_collision_grid := PackedFloat32Array()
var _built_center_elev := 0.0
var _built_extent := 0.0
var _explore_drone: FPVDrone = null
var _buildings_root: Node3D = null
var _buildings_data: Array = []
var _water_root: Node3D = null
var _water_data: Array = []
var _flow_w := 1.0
var _flow_level := 0.0
var _flow_speed := 1.0
var _flow_churn := 1.0
var _flow_alpha := 0.88
var _camps_root: Node3D = null
var _camp_profiles: Dictionary = {}
var _camp_scatter_ui: Control = null
var _base_dem_grid := PackedFloat32Array()
var _detail_elev_grid := PackedFloat32Array()
var _detail_elev_cols := 0
var _detail_elev_rows := 0
var _detail_elev_done := false
var _detail_elev_resolved := false
var _osm_vectors: Dictionary = {}
var _terrain_edits: TerrainEditGrid = null
var _terrain_edit_ui: Control = null
var _space_edit_ui: Control = null
var _terrain_options_ui: Control = null
var _vegetation_layer: VegetationLayer = null
var _vegetation_edit_ui: Control = null
var _vegetation_preview_ui: Control = null
var _auto_veg_layer: AutoVegetationLayer = null
var _auto_veg_data: Dictionary = {}
var _auto_veg_generated := false
var _auto_veg_edits: AutoVegetationEdits = null
var _veg_style: Dictionary = {}
## Re-entrancy guard for the async auto-veg GPU rebuild: overlapping rebuilds
## clear + re-add the same MultiMesh children concurrently (a native crash / GPU
## spike risk), so a rebuild requested while one is running just marks it dirty
## and the in-flight rebuild re-runs once with the latest state when it finishes.
var _auto_rebuild_active := false
var _auto_rebuild_dirty := false
var _veg_undo := VegetationUndo.new()
## Vegetation growth (VegetationGrowth): a monotonic sim-hours clock that ages the
## plants. It advances mostly in analemma / ∞ mode (a day per frame) so the player
## watches forests grow, die at maturity, and reseed over seasons; at normal play
## speeds growth is imperceptible so ticks essentially never fire. Reset each load
## — growth PROGRESS isn't persisted (birth times are re-seeded), only the tunable
## <species>_growth_years survives. See _advance_growth / _growth_tick.
const GROWTH_MAX_STEP_H := 48.0     # ignore bigger per-frame clock jumps (UI scrubs)
const GROWTH_SCALE_BUDGET_PER_FRAME := 2000
var _growth_clock_h := 0.0
var _growth_last_calendar_doy := -1
var _growth_prev_abs_h := 0.0
var _manual_growth_map := VegetationInstanceMap.new()
var _auto_growth_map := VegetationInstanceMap.new()
var _growth_scale_apply_doy := -1
var _growth_caps_manual := {}
## Climelapse pre-bake (Phase 3–4): calendar keyframes + per-instance scale snapshots.
const CLIMELAPSE_ROOT := "user://climelapses"
var _export_render_start := NAN
var _export_render_end := NAN
var _export_time_scale := 1.0
var _clim_play_target_kf := -1
const CLIM_PLAY_SCALE_BUDGET := 12000
var _climelapse_capture: ClimelapseCapture = null
var _export_mp4_path := ""
var _export_camera: ClimelapseCameraRig = null
var _export_pending := false
var _export_fps := 30
## Waypoints collected for hyperlapse export ({pos, yaw, pitch}).
var _climelapse_drone_path: Array = []
var _growth_caps_auto := {}
var _growth_rng := RandomNumberGenerator.new()
var _auto_growth_zone_index: GrowthZoneIndex = null
var _placed_prop_layer: PlacedPropLayer = null
var _placed_props_ui: Control = null
var _placed_prop_edit_ui: Control = null
## Click-to-move from PlacedPropEditUI Move button (see begin_prop_reposition).
var _reposition_prop: PlacedProp = null
var _reposition_valid := false
var _reposition_cam_follow := true
const REPOSITION_FOLLOW_LERP := 4.0
var _building_focus_idx: int = -1
## Per-building style overrides (Building Builder). Styled buildings are
## excluded from the merged Buildings mesh and rebuilt as individual children
## of the BuildingsCustom node ("B_<tag>").
var _building_style_layer: BuildingStyleLayer = null
## Player-tagged NPC spaces (restroom/kitchen/sleep/water point) for this map.
var npc_spaces: SpaceRegistry = null
var _custom_buildings_root: Node3D = null
var _building_builder_ui: Control = null
var _starshade_edit_ui: Control = null
var _pond_edit_ui: Control = null
var _pallet_rack_builder_ui: Control = null
var _building_highlight: MeshInstance3D = null
## OSM solar arrays built in-world but NOT auto-added to the graph. Each record:
## {name, poly, panel_count, watts, base_y, tilt, azimuth, tag, added}. The player
## targets one via the crosshair (see pick_solar_array_at_world) and confirms to add
## it to the system graph — nothing is added automatically on load.
var _solar_arrays: Array = []
var _solar_focus_idx: int = -1
var _solar_highlight: MeshInstance3D = null
var _solar_graph_highlight_idx: int = -1
var _scene_graph_highlight: Node3D = null
## Persist which arrays the player already added across in-session terrain rebuilds
## (tag -> {count, watts}); drives the accumulated SolarUI generation total.
var _added_solar_tags: Dictionary = {}
## OSM / sculpted still-water pond focus (crosshair → Add pond to graph).
var _water_focus_idx: int = -1
var _water_highlight: MeshInstance3D = null
var _added_pond_tags: Dictionary = {}
## Cached D8 watershed on the composed walkable heightfield (optional overlay).
var _watershed_analysis = null
## Transient Site Plan / Elev preview for pond watershed designate (world XZ poly).
var _watershed_preview: Dictionary = {}
## Teal ground outline while watershed preview / designate is active.
var _watershed_highlight: MeshInstance3D = null
var _veg_highlight: MeshInstance3D = null
## Crosshair-focused OSM vegetation area (index into _auto_veg_data["polygons"]).
## Highlighted like buildings; Interact / the O action opens the Tune look modal
## seeded to that area's veg type (see pick_veg_area_at_world / open_veg_area_modal).
var _veg_focus_idx: int = -1
var _veg_focus_area: Dictionary = {}
var _footing_grid := PackedFloat32Array()
var _detail_surface_grid := PackedFloat32Array()
var _detail_collision_active := false
const DRONE_GROUND_CLEARANCE_M := 1.5
var _parcel_rect := Rect2()
var _selection_highlight: MeshInstance3D = null
var _last_selection_rect := Rect2(-99999.0, -99999.0, 0.0, 0.0)
var _last_veg_poly_hash := 0
var _last_veg_highlight_color_hash := 0
var _locked_yaw := 0.0
## Player-designated ponds (sculpted basins filled with water). Each: {points, kind,
## tag, user}. Merged into _water_data so they drape with the OSM water shader and
## survive reloads via user://maps/user_water_<lat>_<lon>.json.
var _user_water_data: Array = []
## Per-map fabricated-part inventory (CNC/printer output) for the crafting
## mechanic. Persisted via user://maps/inventory_<lat>_<lon>.json.
var _part_inventory: PartInventory = null
## Persistent mud/clay/concrete prints that dried in place on the map.
## Persisted via user://maps/printed_objects_<lat>_<lon>.json.
var _printed_objects: Array = []
## ---------------------------------------------------------------------------
## Undo snapshots (water bodies + region-scoped tile edits), capped.
const SCULPT_UNDO_MAX := 16
var _sculpt_undo_stack: Array = []
## True while the terrain sculpt dock is open (drives the drone edit-camera meta).
var _sculpt_session := false
## Legacy earthworks records, loaded only so _migrate_legacy_edits_to_tiles() can
## bake them into the high-res tile layer and then clear them. No longer created.
var _earthworks: Array = []
var _sculpt_highlight: MeshInstance3D = null

## High-resolution edit layer (ROADMAP terrain-builder reimagining). The tile
## store is the persistent data + region-scoped undo; TerrainHeightField renders
## each edited tile as its own hi-res mesh + collider on top of the base terrain,
## while the DetailGround mesh/collider are SUNK beneath active tiles so cut
## bowls are neither occluded visually nor bridged by the coarser collider.
var _edit_tiles: TerrainEditTiles = null
var _height_field: TerrainHeightField = null
## Signature of the sink currently baked into the DetailGround mesh/collider —
## skips the (relatively) heavy detail-patch rebuild when nothing changed.
var _detail_sink_sig := ""

var _load_overlay: TerrainLoadOverlay = null
var _load_progress: TerrainLoadProgress = null
var _load_ui_active := false
var _load_hint := ""
var _load_fast_path := false
var _detail_img_resolved := false
var _detail_img_retry_zoom := -1
var _refresh_pending: Dictionary = {}
var _auto_veg_generate_queued := false
var _auto_veg_scatter_pending := false
var _auto_veg_scatter_regen := false
var _manual_veg_pending := false
## Phase 3a: SoI centre the veg detail rings were last built around, and the
## debounce flag for re-ringing after the player relocates the pin.
var _veg_ring_built_center := Vector2.ZERO
var _veg_ring_rebuild_pending := false
## Phase 3b: in-process impostor baker (windowed only) + rebuild debounce so
## a burst of bake completions triggers ONE veg rebuild.
var _impostor_baker: VegImpostorBaker = null
var _impostor_rebuild_pending := false

## True while _run_load_sequence() owns the pipeline (callbacks must not kick off
## parallel fetches or GPU-heavy side effects).
var _load_sequence_active := false
var _phase_waiting := false
var _phase_key := ""
var _phase_ok := false


func _ready() -> void:
	ServiceLocator.provide(ServiceLocator.TERRAIN_LOADER, self)
	_main = get_parent()
	# Deferred: Main is still "busy setting up children" during our _ready, so
	# add_child() on it would fail. By the deferred call Main is fully ready.
	_begin.call_deferred()


## Push the current weather-driven ground snow cover to the terrain shader(s).
## Cheap (two shader-param sets); runs only once terrain is built.
func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not _built or _main == null:
		return
	# Hydro Lab suspends world CPU — skip snow/growth/water uniform storm.
	if _main.has_method("is_world_suspended_for_lab") \
			and bool(_main.call("is_world_suspended_for_lab")):
		return
	if _reposition_prop != null:
		_tick_prop_reposition(delta)
	PerfMonitor.begin("terrain_tick")
	_advance_growth()
	_apply_water_flow(delta)
	PerfMonitor.end("terrain_tick")
	if not _main.has_method("get_snow_amount"):
		return
	var snow := clampf(float(_main.call("get_snow_amount")), 0.0, 1.0)
	var depth_m := 0.0
	if _main.has_method("get_snow_depth_m"):
		depth_m = clampf(float(_main.call("get_snow_depth_m")), 0.0, SeasonModel.SNOW_DEPTH_MAX_M)
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	for node_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(node_name) as MeshInstance3D
		if mi == null:
			continue
		_push_snow_to_mesh(mi, snow, depth_m)
	_apply_snow_to_buildings(terrain, snow, depth_m)


func _apply_water_flow(delta: float) -> void:
	if _water_root == null or _main == null or not _main.has_method("get_water_flow"):
		return
	var target: Dictionary = _main.call("get_water_flow")
	var k := clampf(delta * 3.0, 0.0, 1.0)
	_flow_w = lerpf(_flow_w, float(target.get("width_scale", 1.0)), k)
	_flow_level = lerpf(_flow_level, float(target.get("level_m", 0.0)), k)
	_flow_speed = lerpf(_flow_speed, float(target.get("speed_scale", 1.0)), k)
	_flow_churn = lerpf(_flow_churn, float(target.get("churn", 1.0)), k)
	_flow_alpha = lerpf(_flow_alpha, float(target.get("water_alpha", 0.88)), k)
	WaterBuilder.apply_flow_visuals(_water_root, _flow_w, _flow_level,
		_flow_speed, _flow_churn, _flow_alpha)


func _push_snow_to_mesh(mi: MeshInstance3D, snow: float, depth_m: float) -> void:
	if mi == null:
		return
	var mats: Array[ShaderMaterial] = []
	if mi.material_override is ShaderMaterial:
		mats.append(mi.material_override as ShaderMaterial)
	if mi.mesh != null:
		for si in mi.mesh.get_surface_count():
			var sm := mi.get_surface_override_material(si)
			if sm is ShaderMaterial and not mats.has(sm):
				mats.append(sm as ShaderMaterial)
	for sm in mats:
		if sm.shader == null:
			continue
		var p := sm.shader.resource_path
		if not (p.ends_with("terrain_detail.gdshader")
				or p.ends_with("building_wall.gdshader")
				or p.ends_with("building_roof.gdshader")):
			continue
		sm.set_shader_parameter("snow_amount", snow)
		sm.set_shader_parameter("snow_depth_m", depth_m)


func _apply_snow_to_buildings(terrain: Node3D, snow: float, depth_m: float) -> void:
	var merged := terrain.get_node_or_null("Buildings") as MeshInstance3D
	if merged != null:
		_push_snow_to_mesh(merged, snow, depth_m)
	var custom := terrain.get_node_or_null("BuildingsCustom")
	if custom == null:
		return
	for child in custom.get_children():
		if child is MeshInstance3D:
			_push_snow_to_mesh(child as MeshInstance3D, snow, depth_m)


func _begin() -> void:
	_resolve_location()

	if _main != null and _main.has_method("apply_location"):
		_main.apply_location(_lat, _lon, _map_label, true)

	_add_temp_floor()
	_begin_load_ui()
	_connect_load_services()
	_run_load_sequence()


func _connect_load_services() -> void:
	var es := get_node_or_null("/root/ElevationService")
	if es != null:
		if not es.elevation_ready.is_connected(_on_elevation_ready):
			es.elevation_ready.connect(_on_elevation_ready)
		if not es.elevation_failed.is_connected(_on_elevation_failed):
			es.elevation_failed.connect(_on_elevation_failed)
		if not es.elevation_progress.is_connected(_on_elevation_progress):
			es.elevation_progress.connect(_on_elevation_progress)
	var img := get_node_or_null("/root/ImageryService")
	if img != null:
		if not img.imagery_ready.is_connected(_on_imagery_ready):
			img.imagery_ready.connect(_on_imagery_ready)
		if not img.imagery_failed.is_connected(_on_imagery_failed):
			img.imagery_failed.connect(_on_imagery_failed)
		if not img.imagery_progress.is_connected(_on_imagery_progress):
			img.imagery_progress.connect(_on_imagery_progress)
	var ai := get_node_or_null("/root/AiImageryService")
	if ai != null:
		if not ai.ai_imagery_ready.is_connected(_on_ai_ready):
			ai.ai_imagery_ready.connect(_on_ai_ready)
		if not ai.ai_imagery_failed.is_connected(_on_ai_failed):
			ai.ai_imagery_failed.connect(_on_ai_failed)
	var bs := get_node_or_null("/root/BuildingService")
	if bs != null:
		if not bs.buildings_failed.is_connected(_on_buildings_failed):
			bs.buildings_failed.connect(_on_buildings_failed)
		if not bs.osm_vectors_ready.is_connected(_on_osm_vectors_ready):
			bs.osm_vectors_ready.connect(_on_osm_vectors_ready)
		if not bs.buildings_progress.is_connected(_on_buildings_progress):
			bs.buildings_progress.connect(_on_buildings_progress)
	var vs := get_node_or_null("/root/VegetationService")
	if vs != null:
		if not vs.vegetation_osm_ready.is_connected(_on_vegetation_osm_ready):
			vs.vegetation_osm_ready.connect(_on_vegetation_osm_ready)
		if not vs.vegetation_osm_failed.is_connected(_on_vegetation_osm_failed):
			vs.vegetation_osm_failed.connect(_on_vegetation_osm_failed)
		if not vs.vegetation_progress.is_connected(_on_vegetation_progress):
			vs.vegetation_progress.connect(_on_vegetation_progress)


## Drop all autoload-signal connections so a map switch (which frees this loader)
## can't deliver callbacks into freed nodes. The terrain data services are
## persistent autoloads, so their connections outlive this scene unless cleared.
func _exit_tree() -> void:
	var es := get_node_or_null("/root/ElevationService")
	if es != null:
		if es.elevation_ready.is_connected(_on_elevation_ready):
			es.elevation_ready.disconnect(_on_elevation_ready)
		if es.elevation_failed.is_connected(_on_elevation_failed):
			es.elevation_failed.disconnect(_on_elevation_failed)
		if es.elevation_progress.is_connected(_on_elevation_progress):
			es.elevation_progress.disconnect(_on_elevation_progress)
	var img := get_node_or_null("/root/ImageryService")
	if img != null:
		if img.imagery_ready.is_connected(_on_imagery_ready):
			img.imagery_ready.disconnect(_on_imagery_ready)
		if img.imagery_failed.is_connected(_on_imagery_failed):
			img.imagery_failed.disconnect(_on_imagery_failed)
		if img.imagery_progress.is_connected(_on_imagery_progress):
			img.imagery_progress.disconnect(_on_imagery_progress)
	var ai := get_node_or_null("/root/AiImageryService")
	if ai != null:
		if ai.ai_imagery_ready.is_connected(_on_ai_ready):
			ai.ai_imagery_ready.disconnect(_on_ai_ready)
		if ai.ai_imagery_failed.is_connected(_on_ai_failed):
			ai.ai_imagery_failed.disconnect(_on_ai_failed)
	var bs := get_node_or_null("/root/BuildingService")
	if bs != null:
		if bs.buildings_failed.is_connected(_on_buildings_failed):
			bs.buildings_failed.disconnect(_on_buildings_failed)
		if bs.osm_vectors_ready.is_connected(_on_osm_vectors_ready):
			bs.osm_vectors_ready.disconnect(_on_osm_vectors_ready)
		if bs.buildings_progress.is_connected(_on_buildings_progress):
			bs.buildings_progress.disconnect(_on_buildings_progress)
	var vs := get_node_or_null("/root/VegetationService")
	if vs != null:
		if vs.vegetation_osm_ready.is_connected(_on_vegetation_osm_ready):
			vs.vegetation_osm_ready.disconnect(_on_vegetation_osm_ready)
		if vs.vegetation_osm_failed.is_connected(_on_vegetation_osm_failed):
			vs.vegetation_osm_failed.disconnect(_on_vegetation_osm_failed)
		if vs.vegetation_progress.is_connected(_on_vegetation_progress):
			vs.vegetation_progress.disconnect(_on_vegetation_progress)


func _unhandled_input(event: InputEvent) -> void:
	if not _built:
		return
	# The dock shortcuts below (V / Y / C / M / B / T) are plain letters, and
	# every branch calls set_input_as_handled() -- so without this guard, typing
	# a coordinate or a site name into any LineEdit opened an edit dock and ate
	# the character. Mouse events still pass through for prop repositioning.
	if event is InputEventKey and InputGuard.blocked(get_viewport()):
		return
	if _reposition_prop != null:
		if event.is_action_pressed("ui_cancel"):
			_cancel_prop_reposition()
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				_confirm_prop_reposition()
				get_viewport().set_input_as_handled()
				return
	if event.is_action_pressed("vegetation_edit") and _vegetation_edit_ui != null:
		if _terrain_edit_ui != null and _terrain_edit_ui.has_method("toggle_mode"):
			if _terrain_edit_ui.visible:
				_terrain_edit_ui.call("_exit_mode")
		if _placed_props_ui != null and _placed_props_ui.has_method("is_panel_open") \
				and bool(_placed_props_ui.call("is_panel_open")):
			_placed_props_ui.call("_exit_mode")
		if _camp_scatter_ui != null and _camp_scatter_ui.visible:
			_camp_scatter_ui.call("_exit_mode")
		_vegetation_edit_ui.toggle_mode()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("space_edit") and _space_edit_ui != null:
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _camp_scatter_ui != null and _camp_scatter_ui.visible:
			_camp_scatter_ui.call("_exit_mode")
		_space_edit_ui.call("toggle_mode")
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("camp_scatter") and _camp_scatter_ui != null:
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _placed_props_ui != null and _placed_props_ui.has_method("is_panel_open") \
				and bool(_placed_props_ui.call("is_panel_open")):
			_placed_props_ui.call("_exit_mode")
		_camp_scatter_ui.toggle_mode()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("placed_props_edit") and _placed_props_ui != null:
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		_placed_props_ui.toggle_mode()
		get_viewport().set_input_as_handled()
		return
	if _terrain_edit_ui == null:
		return
	if event.is_action_pressed("terrain_edit"):
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _placed_props_ui != null and _placed_props_ui.has_method("is_panel_open") \
				and bool(_placed_props_ui.call("is_panel_open")):
			_placed_props_ui.call("_exit_mode")
		_terrain_edit_ui.toggle_mode()
		get_viewport().set_input_as_handled()


func _resolve_location() -> void:
	# Extent priority: MapContext (this launch) → per-site meta → global config
	# → code defaults. Never seed from global config first — the last map's
	# 60 km world half-extent would otherwise pollute every other site.
	_half_extent = HALF_EXTENT_DEFAULT
	_detail_half_extent = DETAIL_HALF_EXTENT_DEFAULT
	_osm_half_extent = OSM_HALF_EXTENT_DEFAULT
	_osm_offset_east_m = 0.0
	_osm_offset_north_m = 0.0
	_osm_offset_user_set = false
	var ctx := get_node_or_null("/root/MapContext")
	if ctx != null and ctx.has_pending:
		var d: Dictionary = ctx.consume()
		_lat = float(d["latitude"])
		_lon = float(d["longitude"])
		_map_label = str(d.get("label", ""))
		var he := float(d["half_extent_m"])
		var dhe := float(d.get("detail_half_extent_m", 0.0))
		var ohe := float(d.get("osm_half_extent_m", 0.0))
		if he > 0.0:
			_half_extent = he
		if dhe > 0.0:
			_detail_half_extent = dhe
		if ohe > 0.0:
			_osm_half_extent = ohe
		_from_resume = bool(d.get("from_resume", false))
		_force_refetch = bool(d.get("force_refetch", false))
		_fill_extent_gaps(he <= 0.0, dhe <= 0.0, ohe <= 0.0)
		# Map-select "Load from cache" is the sole source of truth for this session.
		TerrainCacheSettings.set_cache_enabled(not _force_refetch)
		_load_osm_offset_prefs()
		return
	# Fallback: the scene's current coordinates (set by save-load / location prefs).
	if _main != null:
		var la: Variant = _main.get("latitude")
		var lo: Variant = _main.get("longitude")
		if la != null and lo != null:
			_lat = float(la)
			_lon = float(lo)
	_fill_extent_gaps(true, true, true)
	TerrainCacheSettings.set_cache_enabled(not _force_refetch)
	_load_osm_offset_prefs()


## Fill unset extent fields: per-site meta first, then global config. Meta wins
## over config so a prior visit to this site isn't overwritten by another map.
func _fill_extent_gaps(fill_world: bool, fill_detail: bool, fill_osm: bool) -> void:
	if not fill_world and not fill_detail and not fill_osm:
		return
	var meta := TerrainCacheSettings.get_meta_extents(_lat, _lon)
	var cfg := ConfigFile.new()
	var has_cfg := FileAccess.file_exists(CONFIG_PATH) and cfg.load(CONFIG_PATH) == OK
	if fill_world:
		var he := float(meta.get("half_extent_m", 0.0))
		if he <= 0.0 and has_cfg:
			he = float(cfg.get_value("terrain", "world_half_extent_m", 0.0))
		if he > 0.0:
			_half_extent = he
	if fill_detail:
		var dhe := float(meta.get("detail_half_extent_m", 0.0))
		if dhe <= 0.0 and has_cfg:
			dhe = float(cfg.get_value("terrain", "detail_half_extent_m", 0.0))
		if dhe > 0.0:
			_detail_half_extent = dhe
	if fill_osm:
		var ohe := float(meta.get("osm_half_extent_m", 0.0))
		if ohe <= 0.0 and has_cfg:
			ohe = float(cfg.get_value("terrain", "osm_half_extent_m", 0.0))
		if ohe > 0.0:
			_osm_half_extent = ohe


func _detail_extent_m() -> float:
	return _detail_half_extent * 2.0


func get_terrain_extents() -> Dictionary:
	return {
		"half_extent_m": _half_extent,
		"detail_half_extent_m": _detail_half_extent,
		"osm_half_extent_m": _osm_half_extent,
		"seam_feather_m": _seam_feather_m,
		"osm_offset_east_m": _osm_offset_east_m,
		"osm_offset_north_m": _osm_offset_north_m,
	}


## Load persisted OSM↔imagery offset from map .tres / site meta (if any).
func _load_osm_offset_prefs() -> void:
	var path := "user://maps/loc_%s_%s.tres" % [
		CoordToken.token(_lat), CoordToken.token(_lon)]
	if FileAccess.file_exists(path):
		var md := load(path) as MapDefinition
		if md != null and (absf(md.osm_offset_east_m) > 0.01 \
				or absf(md.osm_offset_north_m) > 0.01):
			_osm_offset_east_m = md.osm_offset_east_m
			_osm_offset_north_m = md.osm_offset_north_m
			_osm_offset_user_set = true
			return
	var meta := TerrainCacheSettings.get_meta_extents(_lat, _lon)
	var ee := float(meta.get("osm_offset_east_m", 0.0))
	var nn := float(meta.get("osm_offset_north_m", 0.0))
	if absf(ee) > 0.01 or absf(nn) > 0.01:
		_osm_offset_east_m = ee
		_osm_offset_north_m = nn
		_osm_offset_user_set = true


func _persist_osm_offset() -> void:
	TerrainCacheSettings.save_meta_extents(
		_lat, _lon, _half_extent, _detail_half_extent, _osm_half_extent,
		_osm_offset_east_m, _osm_offset_north_m)
	var path := "user://maps/loc_%s_%s.tres" % [
		CoordToken.token(_lat), CoordToken.token(_lon)]
	if not FileAccess.file_exists(path):
		return
	var md := load(path) as MapDefinition
	if md == null:
		return
	md.osm_offset_east_m = _osm_offset_east_m
	md.osm_offset_north_m = _osm_offset_north_m
	ResourceSaver.save(md, path)


## Rebind working OSM / veg arrays from raw payloads + current offset, then
## re-attach overlays when the world is already built.
func _rebind_osm_registration(reattach: bool = true) -> void:
	if not _osm_vectors_raw.is_empty():
		_osm_vectors = OsmRegistration.offset_payload(
			_osm_vectors_raw, _osm_offset_east_m, _osm_offset_north_m)
		_buildings_data = _osm_vectors.get("buildings", []) as Array
		_refresh_water_data()
	if not _auto_veg_data_raw.is_empty():
		_auto_veg_data = OsmRegistration.offset_payload(
			_auto_veg_data_raw, _osm_offset_east_m, _osm_offset_north_m)
	if not reattach or not _built or _load_sequence_active:
		return
	_apply_osm_vectors_after_fetch()
	if not _auto_veg_data.is_empty():
		_queue_auto_veg_generate(_auto_veg_generated)


func _maybe_autoseed_brc_osm_offset() -> void:
	if _osm_offset_user_set:
		return
	if absf(_osm_offset_east_m) > 0.01 or absf(_osm_offset_north_m) > 0.01:
		return
	if _osm_vectors_raw.is_empty():
		return
	var suggested := OsmRegistration.suggest_brc_offset_m(
		_lat, _lon, _osm_vectors_raw)
	if suggested.length() < 80.0:
		return
	_osm_offset_east_m = suggested.x
	_osm_offset_north_m = suggested.y
	_osm_offset_user_set = true
	_persist_osm_offset()
	print("TerrainLoader: auto OSM↔imagery offset %+0.f m E, %+0.f m N (BRC year mismatch)" % [
		_osm_offset_east_m, _osm_offset_north_m])
	_toast("Aligned OSM to aerial scars (%+.0f m E, %+.0f m N). Nudge in Terrain options if needed." % [
		_osm_offset_east_m, _osm_offset_north_m], ToastUI.Level.INFO)


## Player / UI: set absolute OSM registration offset (metres east / north).
func set_osm_imagery_offset(east_m: float, north_m: float, reattach: bool = true) -> void:
	_osm_offset_east_m = east_m
	_osm_offset_north_m = north_m
	_osm_offset_user_set = true
	_persist_osm_offset()
	_rebind_osm_registration(reattach)
	_notify_options_status("OSM offset %+.0f m E, %+.0f m N" % [
		_osm_offset_east_m, _osm_offset_north_m], "ok")


func nudge_osm_imagery_offset(east_delta_m: float, north_delta_m: float) -> void:
	set_osm_imagery_offset(
		_osm_offset_east_m + east_delta_m,
		_osm_offset_north_m + north_delta_m)


func auto_align_osm_to_imagery() -> void:
	if _osm_vectors_raw.is_empty():
		_notify_options_status("No OSM data yet — wait for map load", "warn")
		return
	_osm_offset_user_set = false
	_osm_offset_east_m = 0.0
	_osm_offset_north_m = 0.0
	var suggested := OsmRegistration.suggest_brc_offset_m(
		_lat, _lon, _osm_vectors_raw)
	if suggested.length() < 80.0:
		_notify_options_status("No BRC year mismatch detected at this site", "info")
		_rebind_osm_registration(true)
		return
	set_osm_imagery_offset(suggested.x, suggested.y)


func clear_osm_imagery_offset() -> void:
	set_osm_imagery_offset(0.0, 0.0)


## ---------------------------------------------------------------------------
## Sequential load pipeline (one fetch + apply phase at a time)
## ---------------------------------------------------------------------------

func _phase_begin(key: String) -> void:
	_phase_key = key
	_phase_waiting = true
	_phase_ok = false


func _phase_resolve(key: String, ok: bool) -> void:
	if _phase_key != key or not _phase_waiting:
		return
	_phase_ok = ok
	_phase_waiting = false


func _phase_await(timeout_s: float = 0.0) -> bool:
	var deadline_ms := Time.get_ticks_msec() + int(timeout_s * 1000.0) if timeout_s > 0.0 else -1
	while _phase_waiting:
		if deadline_ms >= 0 and Time.get_ticks_msec() >= deadline_ms:
			push_warning("TerrainLoader: phase '%s' timed out after %.0fs" % [_phase_key, timeout_s])
			_phase_waiting = false
			_phase_ok = false
			return false
		await get_tree().process_frame
	return _phase_ok


func _settle_gpu(frames: int = SETTLE_FRAMES) -> void:
	var tree := get_tree()
	if tree == null:
		return
	for _i in frames:
		await tree.process_frame


func _run_load_sequence() -> void:
	_load_sequence_active = true
	auto_veg_ready = false
	_detail_img_retry_zoom = -1
	if _load_progress != null:
		_load_progress.configure_for_extents(_half_extent, _detail_half_extent)
	var es := get_node_or_null("/root/ElevationService")
	if es != null and es.has_method("reset_session"):
		es.reset_session()

	# Fresh launch: bypass DEM/imagery AND wipe OSM caches so BuildingService
	# cannot serve a stale vector file while Elevation/Imagery refetch.
	if _force_refetch or not TerrainCacheSettings.cache_enabled():
		var n := TerrainCacheSettings.invalidate_osm_vectors(_lat, _lon)
		n += TerrainCacheSettings.invalidate_osm_vegetation(_lat, _lon)
		if _force_refetch:
			n += TerrainCacheSettings.invalidate_dem(_lat, _lon)
			n += TerrainCacheSettings.invalidate_imagery(_lat, _lon)
		print("TerrainLoader: fresh load — cleared %d site cache file(s); skipping placed props" % n)

	# 1. Base DEM
	if es != null:
		_phase_begin("elev:base")
		if _force_refetch or not TerrainCacheSettings.cache_enabled():
			_update_load_ui("Elevation — downloading (cache bypassed) …")
		else:
			_update_load_ui("Elevation — checking cache / fetching …")
		if _load_progress != null:
			_load_progress.set_partial("base_dem", 0.02)
			_update_load_ui()
		var bypass := _force_refetch or not TerrainCacheSettings.cache_enabled()
		es.request_elevation(_lat, _lon, _half_extent,
			ElevationService.base_grid_n_for_extent(_half_extent), "base", bypass)
		if not await _phase_await(_elev_phase_timeout_s()):
			_apply_elevation_fallback("base", "timed out waiting for elevation")
		await _settle_gpu()
	else:
		_apply_elevation_fallback("base")

	# 2. Detail DEM (before walkable terrain — composed heightfield is mandatory).
	await _fetch_detail_dem_phase(es)
	await _settle_gpu()

	# 3. Base imagery
	var img := get_node_or_null("/root/ImageryService")
	if img != null:
		_phase_begin("img:base")
		var bypass_img := _force_refetch or not TerrainCacheSettings.cache_enabled()
		img.request_imagery(_lat, _lon, _half_extent, _base_imagery_target_px(),
			"base", 17, bypass_img)
		if not await _phase_await(_imagery_phase_timeout_s()):
			_apply_imagery_fallback("base")
		await _settle_gpu()
	else:
		_apply_imagery_fallback("base")

	# 4. Build terrain from composed base+detail heightfield.
	_update_load_ui("Merging elevation layers …")
	_build_terrain()
	await _settle_gpu()

	# 5–7 + camps: seat the player as soon as DEM/buildings land. Vegetation
	# still runs before map_load_complete (harness waits on that), but the
	# player can walk while MultiMeshes scatter (compact load overlay already
	# entered at walkable).
	await _run_post_terrain_sequence(false)

	# Final seating pass: props/buildings/camps on the composed heightfield
	# before first-person control (stored ground_y can be stale after mean-elev
	# or DEM changes; OSM/camps already use live footing on attach).
	_seat_world_content_for_play()

	if not _from_resume:
		_finalize_spawn_actors()

	TerrainCacheSettings.save_meta_extents(
		_lat, _lon, _half_extent, _detail_half_extent, _osm_half_extent,
		_osm_offset_east_m, _osm_offset_north_m)

	var soi := get_node_or_null("/root/SoiService")
	if soi != null:
		soi.load_for_site(_lat, _lon)
		soi.bind_terrain(self)
		# Phase 3a: veg detail rings are anchored on the SoI centre — re-ring
		# (debounced) when the player relocates the pin.
		var ring_cb := Callable(self, "_on_soi_changed_for_veg")
		if soi.has_signal("soi_changed") and not soi.is_connected("soi_changed", ring_cb):
			soi.connect("soi_changed", ring_cb)
	call_deferred("_try_seed_starshade_graph")
	call_deferred("_notify_graph_map_ready")

	# 8. Vegetation — large maps background the scatter (see phase helper).
	await _run_vegetation_load_phase()

	_load_sequence_active = false
	_check_load_complete()
	_maybe_opentopo_hint()
	var mly := get_node_or_null("/root/MapillaryService")
	if mly != null and bool(mly.is_configured()):
		mly.request_photo_index(_lat, _lon, _osm_half_extent, "site")
	load_completed = true
	map_load_complete.emit()


func _fetch_detail_dem_phase(es: Node) -> void:
	var skip_detail := false
	if es != null:
		var has_key: bool = es.has_method("has_opentopo_key") and es.has_opentopo_key()
		var quota_hit: bool = es.has_method("is_openmeteo_daily_exhausted") \
				and es.is_openmeteo_daily_exhausted()
		skip_detail = not has_key and quota_hit
	if es != null and not skip_detail:
		var has_key: bool = es.has_method("has_opentopo_key") and es.has_opentopo_key()
		if not has_key:
			_update_load_ui("Loading hi-res centre elevation (first visit only — cached after) …")
		_phase_begin("elev:detail")
		var bypass := _force_refetch or not TerrainCacheSettings.cache_enabled()
		es.request_elevation(_lat, _lon, _detail_half_extent,
			ElevationService.DETAIL_GRID_N, "detail", bypass)
		if not await _phase_await(300.0):
			if not _recover_detail_dem_from_cache():
				_skip_detail_dem()
	elif skip_detail:
		push_warning("TerrainLoader: skipping detail DEM — Open-Meteo daily quota exhausted")
		_toast("Elevation quota reached — skipping hi-res detail terrain for now.", ToastUI.Level.WARN)
		if not _recover_detail_dem_from_cache():
			_skip_detail_dem()
	else:
		_skip_detail_dem()


## Post-terrain phases. When `include_vegetation` is false, OSM veg is deferred
## so the player can walk as soon as DEM + buildings land (large-map progressive).
func _run_post_terrain_sequence(include_vegetation: bool = true) -> void:
	# Detail DEM already fetched in _run_load_sequence before terrain build.
	var bypass := _force_refetch or not TerrainCacheSettings.cache_enabled()

	# 5. Hi-res centre imagery + detail-drape shader.
	var img := get_node_or_null("/root/ImageryService")
	if img != null:
		_phase_begin("img:detail")
		img.request_imagery(_lat, _lon, _detail_half_extent, _detail_target_px(), "detail",
			DETAIL_MAX_ZOOM, bypass)
		if not await _phase_await(180.0):
			push_warning("TerrainLoader: detail imagery phase timed out — applying if ready")
		if _detail_drape != null:
			_apply_detail()
		_resolve_detail_imagery()
		_request_hyper_imagery()
	else:
		_resolve_detail_imagery()
	await _settle_gpu()

	# 6–7. OSM vectors -> buildings, then water.
	var bs := get_node_or_null("/root/BuildingService")
	if bs != null:
		_phase_begin("osm_map")
		var cfg := _terrain_config()
		bs.request_osm_vectors(_lat, _lon, _osm_half_extent, cfg.flatten_landuse, bypass)
		if await _phase_await(180.0):
			await _apply_osm_overlays()
		else:
			_load_progress_mark_done("osm_map")
	else:
		_load_progress_mark_done("osm_map")
	await _settle_gpu()

	# 9. Camp generation (deterministic, optional) — before veg so spawn is early.
	_attach_camps()
	await _settle_gpu()
	_refresh_water_reflection_probes()

	if include_vegetation:
		await _run_vegetation_load_phase()
		_apply_large_map_veg_runtime_lod()


func _run_vegetation_load_phase() -> void:
	if not _terrain_config().show_auto_vegetation:
		# Same explicit feedback as _request_auto_vegetation: a silently skipped
		# fetch on a forested site reads as "auto-veg is broken".
		_toast("Auto vegetation is OFF (Terrain options → Auto vegetation).", ToastUI.Level.INFO)
		_load_progress_mark_done("osm_veg")
		_mark_auto_veg_ready()
		return
	var vs := get_node_or_null("/root/VegetationService")
	if vs == null:
		_load_progress_mark_done("osm_veg")
		_mark_auto_veg_ready()
		return
	var bypass := _force_refetch or not TerrainCacheSettings.cache_enabled()
	# World half-extent (not OSM) — Mt. Vernon is 30 km world with a smaller OSM
	# window, but MultiMesh cost still kills FPS.
	var large := _is_large_world_map()
	_phase_begin("osm_veg")
	_update_load_ui("Vegetation — fetching …" if large else "Vegetation — scattering …")
	vs.request_vegetation(_lat, _lon, _osm_half_extent, bypass)
	if not await _phase_await(180.0):
		_load_progress_mark_done("osm_veg")
		_mark_auto_veg_ready()
		return
	# Large maps: fetch unblocks load; scatter continues in background so the
	# player can walk sooner. Smaller maps keep the prior await-scatter behavior.
	if large:
		_load_progress_mark_done("osm_veg")
		_queue_auto_veg_generate(false)
		print("TerrainLoader: large-map progressive — veg scatter backgrounded (world half=%.0f m)" % _half_extent)
	else:
		await _auto_veg_scatter_async(false)
		_load_progress_mark_done("osm_veg")
		await _settle_gpu()
		_apply_large_map_veg_runtime_lod()
		_mark_auto_veg_ready()


func _mark_auto_veg_ready() -> void:
	if auto_veg_ready:
		return
	auto_veg_ready = true
	auto_vegetation_ready.emit()


func _is_large_world_map() -> bool:
	return _half_extent >= 8000.0 or _osm_half_extent >= 8000.0


## Tighten MultiMesh cull distances on large maps without a full re-scatter
## (helps already-built Mt. Vernon MultiMeshes immediately).
func _apply_large_map_veg_runtime_lod() -> void:
	if not _is_large_world_map() or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	_apply_large_map_shadow_budget(terrain)
	var tree_end := 480.0
	var grass_end := 260.0
	var style_end := float(_veg_style.get("auto_visibility_end_m", 1200.0))
	if style_end < 1199.0:
		tree_end = minf(tree_end, style_end)
	var style_grass := float(_veg_style.get("grass_visibility_end_m", 520.0))
	if style_grass < 519.0:
		grass_end = minf(grass_end, style_grass)
	var n := 0
	for root_name in ["AutoVegetation", "Vegetation"]:
		var root := terrain.get_node_or_null(root_name)
		if root == null:
			continue
		for child in root.get_children():
			if not (child is MultiMeshInstance3D):
				continue
			var mi := child as MultiMeshInstance3D
			var nm := str(mi.name).to_lower()
			var want := grass_end if nm.contains("grass") or nm.contains("lawn") \
					or nm.contains("field") or nm.contains("wheat") else tree_end
			if mi.visibility_range_end > want + 1.0:
				mi.visibility_range_end = want
				n += 1
	if n > 0:
		print("TerrainLoader: large-map veg LOD — tightened %d MultiMesh cull ranges" % n)


## 30 km Ground plates in 4-split sun shadows were the Mt. Vernon 6M-prim bomb
## (mesh audit ~640k tris; render counter ×~10 via cascades). Cap cascade count
## for the session and ensure terrain plates do not cast.
func _apply_large_map_shadow_budget(terrain: Node3D) -> void:
	for plate_name in ["Ground", "DetailGround", "GeneratedTerrain/Ground"]:
		var plate := terrain.get_node_or_null(plate_name) as MeshInstance3D
		if plate == null and plate_name.contains("/"):
			plate = terrain.get_node_or_null(plate_name.get_file()) as MeshInstance3D
		if plate != null:
			plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var gen := terrain.get_node_or_null("GeneratedTerrain") as Node3D
	if gen != null:
		var g := gen.get_node_or_null("Ground") as MeshInstance3D
		if g != null:
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Soft session override — do not persist below the player's saved preset.
	if _main != null and int(_main.get("shadow_quality")) >= 2:
		_main.set("shadow_quality", 1)
		print("TerrainLoader: large-map shadow budget — quality→1, terrain cast off")


func _apply_elevation_fallback(tag: String, reason: String = "") -> void:
	if tag == "detail":
		_skip_detail_dem()
		return
	# Fresh / no-cache launches must not silently revive a deleted DEM.
	if not _force_refetch and TerrainCacheSettings.cache_enabled():
		var recovered := ElevationService.find_usable_cached_dem(
			_lat, _lon, "base", _half_extent)
		if recovered.is_empty():
			recovered = ElevationService.find_usable_cached_dem(
				_lat, _lon, "", _half_extent)
		if not recovered.is_empty():
			push_warning("TerrainLoader: live elevation failed — using recovered cached DEM")
			_elev_grid = recovered["grid"]
			_elev_cols = int(recovered["cols"])
			_elev_rows = int(recovered["rows"])
			_elev_done = true
			_load_progress_mark_done("base_dem")
			var msg := "Elevation fetch failed — using last cached terrain"
			if not reason.is_empty():
				msg += " (%s)" % _short_fetch_error(reason)
			_notify_options_status(msg, "warn")
			_toast(msg, ToastUI.Level.WARN)
			return
	push_warning("TerrainLoader: elevation fetch failed — using flat fallback (%s)" % reason)
	var es := get_node_or_null("/root/ElevationService")
	var has_key: bool = es != null and es.has_method("has_opentopo_key") and bool(es.has_opentopo_key())
	var detail := _short_fetch_error(reason) if not reason.is_empty() else "network or API error"
	if has_key:
		_notify_options_status("Elevation unavailable (flat terrain) — %s" % detail, "warn")
	else:
		_notify_options_status(
			"Elevation unavailable (flat terrain) — %s; add OpenTopography key or reduce world radius" % detail,
			"warn")
	_toast("Elevation unavailable — using flat terrain.", ToastUI.Level.WARN)
	_elev_grid = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	_elev_cols = 2
	_elev_rows = 2
	_elev_done = true
	_load_progress_mark_done("base_dem")


func _apply_imagery_fallback(tag: String) -> void:
	if tag == "detail":
		_resolve_detail_imagery()
		return
	push_warning("TerrainLoader: imagery fetch failed — using neutral drape")
	_toast("Satellite imagery unavailable — using a neutral ground drape.", ToastUI.Level.WARN)
	_drape = null
	_img_done = true
	_load_progress_mark_done("base_img")


func _skip_detail_dem() -> void:
	_detail_elev_resolved = true
	_load_progress_mark_done("detail_dem")


## Load a usable hi-res centre DEM from disk when the live detail fetch can't run
## (quota/offline). Returns true and seats _detail_elev_* so the heightfield rebuild
## picks up local relief; false when no cached detail DEM exists for this site.
func _recover_detail_dem_from_cache() -> bool:
	if _force_refetch or not TerrainCacheSettings.cache_enabled():
		return false
	var recovered := ElevationService.find_usable_cached_dem(
		_lat, _lon, "detail", _detail_half_extent)
	if recovered.is_empty():
		return false
	var grid: PackedFloat32Array = recovered["grid"]
	var cols := int(recovered["cols"])
	var rows := int(recovered["rows"])
	if cols > DETAIL_MESH_RES or rows > DETAIL_MESH_RES:
		grid = TerrainBuilder.resample(grid, cols, rows, DETAIL_MESH_RES)
		cols = DETAIL_MESH_RES
		rows = DETAIL_MESH_RES
	_detail_elev_grid = grid
	_detail_elev_cols = cols
	_detail_elev_rows = rows
	_detail_elev_done = true
	_detail_elev_resolved = true
	_load_progress_mark_done("detail_dem")
	push_warning("TerrainLoader: recovered hi-res centre DEM from cache (live fetch unavailable)")
	return true


## Attach buildings + water after OSM vectors arrive (sequential load phase 6–7).
func _apply_osm_overlays() -> void:
	if not _built:
		return
	var cfg := _terrain_config()
	if cfg.flatten_roads or cfg.flatten_landuse:
		await _rebuild_heightfield_staggered(false)
	else:
		_attach_buildings(false)
		await _settle_gpu(2)
		_attach_water()
	_apply_solar_arrays()
	_load_progress_mark_done("osm_map")


## Build OSM rooftop/ground PV arrays in-world so the player can SEE them, and record
## each array's footprint + sizing for crosshair selection. Nothing is fed into the
## system graph or SolarUI automatically — the player targets an array (crosshair
## raycast → red highlight) and confirms to add it (see add_solar_array_to_graph).
## Idempotent: rebuilds the world node + records each call, preserving the set of
## arrays the player already added this session (_added_solar_tags).
func _apply_solar_arrays() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var existing := terrain.get_node_or_null("SolarArrays")
	if existing != null:
		existing.queue_free()
	_clear_solar_highlight()
	_solar_focus_idx = -1
	_solar_arrays.clear()
	var arrays: Array = _osm_vectors.get("solar", []) as Array
	if arrays.is_empty():
		return
	var azimuth := SolarArrayBuilder.default_azimuth_deg(_lat)
	var panel_spec := SolarArrayBuilder.default_panel_spec()
	var container := Node3D.new()
	container.name = "SolarArrays"
	terrain.add_child(container)
	var total := 0
	var idx := 0
	for rec in arrays:
		if not (rec is Dictionary):
			continue
		var tags: Dictionary = (rec as Dictionary).get("tags", {})
		var poly: PackedVector2Array = (rec as Dictionary).get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var mount_style := SolarArrayBuilder.infer_mount_style(tags)
		var mount_defs := SolarArrayBuilder.mount_defaults(mount_style, _lat)
		var tilt := float(mount_defs["tilt_deg"])
		var row_spec := panel_spec.duplicate(true)
		row_spec["row_gap_m"] = float(panel_spec["row_gap_m"]) * float(mount_defs.get("row_gap_scale", 1.0))
		var panels := SolarArrayBuilder.plan_panels(poly, tilt, row_spec)
		if panels.is_empty():
			continue
		var base_y := _solar_array_base_y(poly, tags)
		var node := SolarArrayBuilder.build_array_node(
			"Array_%d" % idx, panels, base_y, tilt, row_spec, mount_style)
		container.add_child(node)
		var tag := _solar_array_tag(poly)
		_solar_arrays.append({
			"name": "Array_%d" % idx,
			"poly": poly,
			"panel_count": panels.size(),
			"watts": float(panel_spec["panel_watts"]),
			"panel_w_m": float(panel_spec["panel_w_m"]),
			"panel_h_m": float(panel_spec["panel_h_m"]),
			"gap_x_m": float(panel_spec["gap_x_m"]),
			"row_gap_m": float(row_spec["row_gap_m"]),
			"voc": float(panel_spec["voc"]),
			"base_y": base_y,
			"tilt": tilt,
			"azimuth": azimuth,
			"mount_style": mount_style,
			"tag": tag,
			"added": _added_solar_tags.has(tag),
		})
		total += panels.size()
		idx += 1
	if _solar_arrays.is_empty():
		container.queue_free()
		return
	var kw := float(total) * float(panel_spec["panel_watts"]) / 1000.0
	print("TerrainLoader: built %d OSM solar array(s), %d panel(s) (%.2f kW) — aim the crosshair at one and press Interact to add it to the system graph" % [
		_solar_arrays.size(), total, kw])
	_notify_options_status("Found %d OSM solar array(s) — look at one and press Interact to add it" % _solar_arrays.size(), "info")
	# Re-apply the accumulated total for any arrays the player added before a rebuild.
	_refresh_added_solar_total()


## Stable per-site key for an array from its footprint centroid (local metres, rounded).
## Lets the added-set survive terrain rebuilds without duplicating panels in the graph.
func _solar_array_tag(poly: PackedVector2Array) -> String:
	var c := SolarArrayBuilder.centroid(poly)
	return "osm_solar_%d_%d" % [roundi(c.x), roundi(c.y)]


## Roof-top Y for a PV footprint: ground at its centroid plus the host building
## height when the array is roof-mounted; ground level otherwise.
func _solar_array_base_y(poly: PackedVector2Array, tags: Dictionary) -> float:
	var c := SolarArrayBuilder.centroid(poly)
	var gy := _ground_height_at(c.x, c.y)
	var on_roof := str(tags.get("location", "")) == "roof"
	if not on_roof:
		return gy
	var host_h := 0.0
	for b in _buildings_data:
		if not (b is Dictionary):
			continue
		var bp: PackedVector2Array = (b as Dictionary).get("points", PackedVector2Array())
		if bp.size() >= 3 and Geometry2D.is_point_in_polygon(c, bp):
			host_h = maxf(host_h, float((b as Dictionary).get("height_m", BuildingBuilder.DEFAULT_HEIGHT_M)))
	if host_h <= 0.0:
		host_h = 5.5  # plausible single-storey house roof when no building height is known
	return gy + host_h


func _feed_solar_ui(panel_count: int, watts: float, tilt_deg: float, azimuth_deg: float) -> void:
	if _main == null:
		return
	var solar_ui := _main.get_node_or_null("UILayer/SolarUI")
	if solar_ui == null:
		solar_ui = get_tree().root.find_child("SolarUI", true, false)
	if solar_ui != null and solar_ui.has_method("apply_imported_solar"):
		solar_ui.call("apply_imported_solar", panel_count, watts, tilt_deg, azimuth_deg, -1.0)


func _feed_solar_graph(panel_count: int, watts: float, label: String = "OSM Solar",
		array_tag: String = "", opts: Dictionary = {}) -> void:
	if _main == null:
		return
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = get_tree().root.find_child("SystemGraphView", true, false)
	if sgv != null and sgv.has_method("add_imported_solar_panels"):
		sgv.call("add_imported_solar_panels", panel_count, watts, label, array_tag, opts)


## ---------------------------------------------------------------------------
## OSM solar array crosshair selection (player targets an array → adds to graph)
## ---------------------------------------------------------------------------

func has_solar_arrays() -> bool:
	return not _solar_arrays.is_empty()


## Which built array footprint contains the world XZ point (topmost / smallest wins
## when nested). Returns {valid, array_idx}.
func get_solar_array_tag(idx: int) -> String:
	if idx < 0 or idx >= _solar_arrays.size():
		return ""
	return str(_solar_arrays[idx].get("tag", ""))


func find_solar_array_index_by_tag(tag: String) -> int:
	if tag.is_empty():
		return -1
	for i in _solar_arrays.size():
		if str(_solar_arrays[i].get("tag", "")) == tag:
			return i
	return -1


## Graph-driven highlight — works even after the array is added to the graph.
func highlight_solar_by_tag(tag: String) -> bool:
	var idx := find_solar_array_index_by_tag(tag)
	if idx < 0:
		return false
	_solar_graph_highlight_idx = idx
	_draw_solar_highlight(idx, Color(0.1, 0.85, 1.0, 0.45))
	return true


func clear_graph_solar_highlight() -> void:
	_solar_graph_highlight_idx = -1
	if _solar_focus_idx >= 0:
		_draw_solar_highlight(_solar_focus_idx)
	else:
		_clear_solar_highlight()


## Import OSM roof footprint as a rain catchment on the system graph.
func add_building_catchment_to_graph(idx: int) -> bool:
	var info := BuildingPicker.footprint_info(_buildings_data, idx)
	if not bool(info.get("valid", false)):
		return false
	var tag := get_building_tag(idx)
	if tag.is_empty():
		return false
	var poly: PackedVector2Array = info.get("points", PackedVector2Array())
	var centroid: Vector2 = info.get("centroid", Vector2.ZERO)
	var area := float(info.get("area_m2", BuildingBuilder.footprint_area_m2(poly)))
	var graph := _find_system_graph_view()
	if graph == null or not graph.has_method("add_imported_catchment"):
		_notify_options_status("System graph unavailable for catchment import", "warn")
		return false
	var ok: bool = bool(graph.call("add_imported_catchment", {
		"osm_tag": tag,
		"label": "Roof Catchment",
		"area_m2": maxf(area, 1.0),
		"runoff_coeff": 0.85,
		"centroid": centroid,
		"width_m": float(info.get("width_m", 5.0)),
		"depth_m": float(info.get("depth_m", 5.0)),
		"points": poly,
	}))
	if ok:
		_notify_options_status(
				"Added roof catchment: %.0f m² → system graph" % area, "ok")
		print("TerrainLoader: added OSM building catchment '%s' (%.0f m²) to the system graph" % [tag, area])
	return ok


## Stable identity for a still-water body (metre-rounded centroid).
func _water_body_tag(poly: PackedVector2Array) -> String:
	var c := SolarArrayBuilder.centroid(poly)
	return "osm_water_%d_%d" % [roundi(c.x), roundi(c.y)]


## Genuinely stable per-pond identity, assigned ONCE at creation and preserved
## across re-carves/resizes/reshapes forever — unlike `tag` (osm_water_tag),
## which is DERIVED from the polygon (centroid + vertex count + bbox, see
## EarthworksBuilder.basin_tag_from_poly) and therefore changes whenever the
## player edits an existing pond's shape, silently orphaning the old record +
## its graph tank (the very fragility `heal_pond_tags_from_map` patches around).
static func _new_pond_id() -> String:
	return "pond_%d_%d" % [Time.get_ticks_usec(), randi() % 1000000]


## Existing USER pond whose centroid lies within `radius_m` of `poly`'s centroid
## — "the same basin the player just re-carved", even though re-deriving the tag
## from the edited polygon would produce a different string. −1 if none.
func _find_user_pond_index_near_poly(poly: PackedVector2Array, radius_m: float) -> int:
	var c := SolarArrayBuilder.centroid(poly)
	var best_i := -1
	var best_d := radius_m
	for i in _user_water_data.size():
		var item: Variant = _user_water_data[i]
		if not (item is Dictionary):
			continue
		var pts: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
		if pts.size() < 3:
			continue
		var d := SolarArrayBuilder.centroid(pts).distance_to(c)
		if d <= best_d:
			best_d = d
			best_i = i
	return best_i


## Mean pond depth heuristic (m) from surface area — shallow farm ponds → deeper basins.
static func _pond_mean_depth_m(area_m2: float) -> float:
	return clampf(0.8 + sqrt(maxf(area_m2, 1.0)) / 40.0, 0.8, 3.5)


## ---------------------------------------------------------------------------
## Pond query + graph wiring (selection modal is the single control surface)
## ---------------------------------------------------------------------------

## True if a pond with this tag (or, preferably, this stable pond_id — robust to
## tag drift from a re-carve) is currently represented on the system graph.
func _pond_tag_on_graph(tag: String, pond_id: String = "") -> bool:
	if tag.is_empty() and pond_id.is_empty():
		return false
	var graph := _find_system_graph_view()
	if graph != null and graph.has_method("has_pond_with_tag"):
		return bool(graph.call("has_pond_with_tag", tag, pond_id))
	return _added_pond_tags.has(tag)


## Build the add_imported_pond payload for a water record, honoring Auto bathymetry
## or Manual capacity / fill modes.
func _pond_payload_for(rec: Dictionary) -> Dictionary:
	_recompute_pond_volume_rec(rec, false)
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	var area := BuildingBuilder.footprint_area_m2(poly)
	var c := SolarArrayBuilder.centroid(poly)
	var capacity_l := maxf(float(rec.get("capacity_l", 100.0)), 1.0)
	var depth := _pond_mean_depth_m(area)
	if area > 0.01:
		depth = maxf(capacity_l / (area * 1000.0), 0.1)
	var rim := float(rec.get("spill_m", sample_pond_basin_elevations(poly).get("rim_m", pond_rim_height(poly))))
	var floor_y := float(rec.get("floor_m", sample_pond_basin_elevations(poly).get("floor_m", rim - depth)))
	var level := TerrainBuilder.variant_to_float(rec.get("level_m", NAN), NAN)
	if is_nan(level):
		level = rim - clampf((rim - floor_y) * 0.15, 0.05, 0.5)
	var stock_l := float(rec.get("stock_l", 0.0))
	var fill_frac := PondBathymetry.fill_frac(stock_l, capacity_l)
	if str(rec.get("fill_mode", "auto")) == "manual" and rec.has("level"):
		fill_frac = clampf(float(rec["level"]), 0.0, 1.0)
	var min_v := poly[0]
	var max_v := poly[0]
	for p in poly:
		min_v.x = minf(min_v.x, p.x)
		min_v.y = minf(min_v.y, p.y)
		max_v.x = maxf(max_v.x, p.x)
		max_v.y = maxf(max_v.y, p.y)
	return {
		"osm_water_tag": str(rec.get("tag", _water_body_tag(poly))),
		"pond_id": str(rec.get("pond_id", "")),
		"label": str(rec.get("label", "Pond")),
		"area_m2": area,
		"mean_depth_m": depth,
		"capacity_l": capacity_l,
		"stock_l": stock_l,
		"capacity_mode": str(rec.get("capacity_mode", "auto")),
		"fill_mode": str(rec.get("fill_mode", "auto")),
		"runoff_coeff": 1.0,
		"centroid": c,
		"width_m": maxf(max_v.x - min_v.x, 1.0),
		"depth_m": maxf(max_v.y - min_v.y, 1.0),
		"points": poly,
		"rim_m": rim,
		"floor_m": floor_y,
		"level_m": level,
		"level": fill_frac,
	}


## Re-push a pond's graph node from its current record (used after a value edit
## while the pond is already on the graph). add_imported_pond is idempotent per tag.
func _sync_pond_graph_node(tag: String) -> void:
	var rec := _water_rec_for_tag(tag)
	if rec.is_empty():
		return
	_sync_pond_graph_from_rec(rec)


## Prefer a light mesh→twin sync when the pond is already on the graph; fall back
## to full re-import when needed.
func _sync_pond_graph_from_rec(rec: Dictionary) -> void:
	var tag := str(rec.get("tag", ""))
	if tag.is_empty():
		return
	var payload := _pond_payload_for(rec)
	var pond_id := str(payload.get("pond_id", ""))
	var graph := _find_system_graph_view()
	if graph == null:
		return
	if graph.has_method("sync_pond_level_from_mesh") and _pond_tag_on_graph(tag, pond_id):
		graph.call("sync_pond_level_from_mesh", tag,
				float(payload.get("level_m", 0.0)),
				float(payload.get("rim_m", 0.0)),
				float(payload.get("floor_m", 0.0)),
				float(payload.get("capacity_l", 0.0)),
				{
					"stock_l": float(payload.get("stock_l", 0.0)),
					"capacity_mode": str(payload.get("capacity_mode", "auto")),
					"fill_mode": str(payload.get("fill_mode", "auto")),
					"level": float(payload.get("level", 0.0)),
					"pond_id": pond_id,
				})
		return
	if graph.has_method("add_imported_pond"):
		graph.call("add_imported_pond", payload)


## Find the _water_data record (OSM or user) carrying this tag.
func _water_rec_for_tag(tag: String) -> Dictionary:
	for item in _water_data:
		if not (item is Dictionary):
			continue
		var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
		var t := str((item as Dictionary).get("tag", _water_body_tag(poly)))
		if t == tag:
			return item
	return {}


## Add the still-water body at _water_data[idx] to the system graph (catchment +
## storage tank). Uses the record's capacity override when present. Idempotent.
func add_pond_to_graph(idx: int) -> bool:
	if idx < 0 or idx >= _water_data.size():
		return false
	var item: Variant = _water_data[idx]
	if not (item is Dictionary):
		return false
	var rec: Dictionary = item
	var kind := str(rec.get("kind", "water"))
	if kind in WaterBuilder.FLOWING_KINDS:
		_notify_options_status("Flowing waterway — pick a pond/lake body", "warn")
		return false
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	if poly.size() < 3:
		return false
	# OSM ponds carry no tag/label on their record — synthesize both.
	if str(rec.get("tag", "")).is_empty():
		rec["tag"] = _water_body_tag(poly)
	if str(rec.get("label", "")).is_empty():
		var area_lbl := BuildingBuilder.footprint_area_m2(poly)
		if bool(rec.get("user", false)):
			rec["label"] = "Sculpted Pond"
		elif kind == "pond" or kind == "water" or kind == "lake" or kind == "reservoir":
			rec["label"] = "Map pond · %.0f m²" % area_lbl
		else:
			rec["label"] = "%s · %.0f m²" % [kind.capitalize(), area_lbl]
	var tag := str(rec["tag"])
	var graph := _find_system_graph_view()
	if graph == null or not graph.has_method("add_imported_pond"):
		_notify_options_status("System graph unavailable for pond import", "warn")
		return false
	var payload := _pond_payload_for(rec)
	var ok: bool = bool(graph.call("add_imported_pond", payload))
	if ok:
		_added_pond_tags[tag] = true
		_notify_options_status("Added pond to graph: %.0f m² / %.0f L" % [
			float(payload["area_m2"]), float(payload["capacity_l"])], "ok")
	return ok


## Remove the pond at _water_data[idx] from the system graph (leaves the water body).
func remove_pond_from_graph(idx: int) -> bool:
	if idx < 0 or idx >= _water_data.size():
		return false
	var item: Variant = _water_data[idx]
	if not (item is Dictionary):
		return false
	var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
	var tag := str((item as Dictionary).get("tag", _water_body_tag(poly)))
	var graph := _find_system_graph_view()
	var ok := false
	if graph != null and graph.has_method("remove_imported_pond"):
		ok = bool(graph.call("remove_imported_pond", tag))
	_added_pond_tags.erase(tag)
	if ok:
		_notify_options_status("Removed pond from graph", "ok")
	return ok


## Structured pond state for the settings modal.
func get_pond_info(idx: int) -> Dictionary:
	if idx < 0 or idx >= _water_data.size():
		return {"valid": false}
	var item: Variant = _water_data[idx]
	if not (item is Dictionary):
		return {"valid": false}
	var rec: Dictionary = item
	var kind := str(rec.get("kind", "water"))
	if kind in WaterBuilder.FLOWING_KINDS:
		return {"valid": false}
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	if poly.size() < 3:
		return {"valid": false}
	var area := BuildingBuilder.footprint_area_m2(poly)
	var tag := str(rec.get("tag", _water_body_tag(poly)))
	if bool(rec.get("user", false)):
		_recompute_pond_volume_rec(rec, false)
	var bounds := sample_pond_basin_elevations(poly)
	var rim := float(rec.get("spill_m", bounds.get("rim_m", pond_rim_height(poly))))
	var floor_y := float(rec.get("floor_m", bounds.get("floor_m", rim)))
	var depth := _pond_mean_depth_m(area)
	var terrain_cap := float(rec.get("terrain_capacity_l", area * depth * 1000.0))
	var capacity_l := float(rec.get("capacity_l", terrain_cap))
	var stock_l := float(rec.get("stock_l", 0.0))
	var level := TerrainBuilder.variant_to_float(rec.get("level_m", NAN), NAN)
	if is_nan(level):
		level = rim - clampf((rim - floor_y) * 0.1, 0.05, 0.5)
	var cap_mode := str(rec.get("capacity_mode", "auto"))
	var fill_mode := str(rec.get("fill_mode", "auto"))
	var pond_id := str(rec.get("pond_id", ""))
	return {
		"valid": true,
		"water_idx": idx,
		"tag": tag,
		"pond_id": pond_id,
		"kind": kind,
		"user": bool(rec.get("user", false)),
		"label": str(rec.get("label", "Pond")),
		"area_m2": area,
		"points": poly,
		"rim_m": rim,
		"floor_m": floor_y,
		"level_m": level,
		"default_capacity_l": terrain_cap,
		"terrain_capacity_l": terrain_cap,
		"capacity_l": capacity_l,
		"stock_l": stock_l,
		"fill_frac": PondBathymetry.fill_frac(stock_l, capacity_l),
		"capacity_mode": cap_mode,
		"fill_mode": fill_mode,
		"has_capacity_override": cap_mode == "manual",
		"on_graph": _pond_tag_on_graph(tag, pond_id),
	}


## Override the visible water surface level (world Y). Live-updates the water mesh
## and mirrors absolute + fractional level onto the graph pond tank twin.
## `from_graph` skips the mesh→graph mirror (avoids feedback loops).
func set_pond_fill_level(idx: int, level_m: float, from_graph: bool = false) -> bool:
	var rec := _user_rec_at_water_idx(idx)
	if rec.is_empty():
		return false
	rec["level_m"] = level_m
	if from_graph:
		# Graph Manual fill pushed an absolute surface — keep fill_mode manual.
		if str(rec.get("fill_mode", "auto")) != "manual":
			rec["fill_mode"] = "auto"
	else:
		# Modal / Rain / Drain drive the surface → Auto fill from level.
		rec["fill_mode"] = "auto"
	_recompute_pond_volume_rec(rec, true)
	_refresh_water_data()
	# Graph twin sync can fire many times/sec — never rebuild all water meshes
	# or rewrite user_water JSON on that path (was Mt. Vernon's ~400 ms/frame).
	if from_graph:
		return true
	_save_user_water()
	_attach_water()
	var tag := str(rec.get("tag", ""))
	if not tag.is_empty() and _pond_tag_on_graph(tag):
		_sync_pond_graph_from_rec(rec)
	return true


## Set fill level by pond tag (graph → mesh twin). Returns false if no user pond.
func set_pond_fill_level_by_tag(tag: String, level_m: float) -> bool:
	if tag.is_empty():
		return false
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
		var t := str((item as Dictionary).get("tag", _water_body_tag(poly)))
		if t == tag:
			return set_pond_fill_level(i, level_m, true)
	return false


## Override the pond's storage volume (litres). Marks capacity Manual and freezes
## Auto overwrites until Reset to Auto. Updates the graph tank if present.
func set_pond_capacity(idx: int, capacity_l: float) -> bool:
	var rec := _user_rec_at_water_idx(idx)
	if rec.is_empty():
		return false
	rec["capacity_l"] = maxf(capacity_l, 1.0)
	rec["capacity_mode"] = "manual"
	_recompute_pond_volume_rec(rec, false)
	_save_user_water()
	_refresh_water_data()
	if _pond_tag_on_graph(str(rec.get("tag", ""))):
		_sync_pond_graph_from_rec(rec)
	return true


## Capacity mode: "auto" (terrain bathymetry) or "manual" (player litres).
func set_pond_capacity_mode(idx: int, mode: String) -> bool:
	var rec := _user_rec_at_water_idx(idx)
	if rec.is_empty():
		return false
	var m := mode.strip_edges().to_lower()
	if m != "auto" and m != "manual":
		return false
	rec["capacity_mode"] = m
	_recompute_pond_volume_rec(rec, true)
	_save_user_water()
	_refresh_water_data()
	if _pond_tag_on_graph(str(rec.get("tag", ""))):
		_sync_pond_graph_from_rec(rec)
	return true


## Fill mode: "auto" (from water surface) or "manual" (locked stock/frac).
func set_pond_fill_mode(idx: int, mode: String) -> bool:
	var rec := _user_rec_at_water_idx(idx)
	if rec.is_empty():
		return false
	var m := mode.strip_edges().to_lower()
	if m != "auto" and m != "manual":
		return false
	rec["fill_mode"] = m
	if m == "auto":
		_recompute_pond_volume_rec(rec, true)
	_save_user_water()
	_refresh_water_data()
	if _pond_tag_on_graph(str(rec.get("tag", ""))):
		_sync_pond_graph_from_rec(rec)
	return true


## Manual fill: set stock litres (and push mesh level via inverse bathymetry).
func set_pond_stock_l(idx: int, stock_l: float, from_graph: bool = false) -> bool:
	var rec := _user_rec_at_water_idx(idx)
	if rec.is_empty():
		return false
	# Manual scrub from UI forces Manual fill; graph Auto twin keeps Auto.
	if not from_graph:
		rec["fill_mode"] = "manual"
	rec["stock_l"] = maxf(stock_l, 0.0)
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	var bounds := sample_pond_basin_elevations(poly)
	var floor_y := float(rec.get("floor_m", bounds.get("floor_m", 0.0)))
	var spill := float(rec.get("spill_m", bounds.get("rim_m", floor_y + 1.0)))
	var cell := PondBathymetry.suggested_cell_m(BuildingBuilder.footprint_area_m2(poly))
	rec["level_m"] = PondBathymetry.level_for_volume_l(
		poly, Callable(self, "ground_height_at"), float(rec["stock_l"]),
		floor_y, spill, cell)
	var cap := maxf(float(rec.get("capacity_l", 1.0)), 1.0)
	rec["level"] = PondBathymetry.fill_frac(float(rec["stock_l"]), cap)
	_refresh_water_data()
	# Ambient graph twin: update records only. Caller rebuilds mesh when the
	# player needs to see it (Lab drag, teardown, Rain/Drain UI).
	if from_graph:
		return true
	_save_user_water()
	_attach_water()
	if _pond_tag_on_graph(str(rec.get("tag", ""))):
		_sync_pond_graph_from_rec(rec)
	return true


## Rebuild the Water node from current `_water_data` (after twin sync / Lab exit).
func refresh_pond_water_mesh() -> void:
	_attach_water()


## Graph → mesh: bathymetric stock → surface (Auto fill twin).
func set_pond_stock_l_by_tag(tag: String, stock_l: float) -> bool:
	if tag.is_empty():
		return false
	var idx := find_pond_idx_by_tag(tag)
	if idx < 0:
		return false
	return set_pond_stock_l(idx, stock_l, true)


## Recompute Auto volume fields for a pond by tag or water-data index.
func recompute_pond_volume(tag_or_idx: Variant) -> Dictionary:
	var rec := {}
	if tag_or_idx is int:
		rec = _user_rec_at_water_idx(int(tag_or_idx))
	else:
		var tag := str(tag_or_idx)
		for uw in _user_water_data:
			if uw is Dictionary and str((uw as Dictionary).get("tag", "")) == tag:
				rec = uw
				break
	if rec.is_empty():
		return {"ok": false, "reason": "not_found"}
	_recompute_pond_volume_rec(rec, true)
	_save_user_water()
	_refresh_water_data()
	if _pond_tag_on_graph(str(rec.get("tag", ""))):
		_sync_pond_graph_from_rec(rec)
	return {
		"ok": true,
		"capacity_l": float(rec.get("capacity_l", 0.0)),
		"stock_l": float(rec.get("stock_l", 0.0)),
		"terrain_capacity_l": float(rec.get("terrain_capacity_l", 0.0)),
		"capacity_mode": str(rec.get("capacity_mode", "auto")),
		"fill_mode": str(rec.get("fill_mode", "auto")),
	}


## Delete a user pond entirely: water body + any graph node. OSM ponds are only
## removed from the graph (their water is map data, not player-owned).
func delete_pond(idx: int) -> bool:
	if idx < 0 or idx >= _water_data.size():
		return false
	var item: Variant = _water_data[idx]
	if not (item is Dictionary):
		return false
	var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
	var tag := str((item as Dictionary).get("tag", _water_body_tag(poly)))
	var graph := _find_system_graph_view()
	if graph != null and graph.has_method("remove_imported_pond"):
		graph.call("remove_imported_pond", tag)
	_added_pond_tags.erase(tag)
	if not bool((item as Dictionary).get("user", false)):
		_notify_options_status("Removed OSM pond from graph", "ok")
		set_water_focus_idx(-1)
		return true
	# Remove the user water record by tag.
	for i in range(_user_water_data.size() - 1, -1, -1):
		var uw: Variant = _user_water_data[i]
		if uw is Dictionary and str((uw as Dictionary).get("tag", "")) == tag:
			_user_water_data.remove_at(i)
	_save_user_water()
	_refresh_water_data()
	_attach_water()
	set_water_focus_idx(-1)
	_notify_options_status("Pond deleted", "ok")
	return true


## The mutable _user_water_data record backing _water_data[idx], or {} for OSM water.
func _user_rec_at_water_idx(idx: int) -> Dictionary:
	if idx < 0 or idx >= _water_data.size():
		return {}
	var item: Variant = _water_data[idx]
	if not (item is Dictionary) or not bool((item as Dictionary).get("user", false)):
		return {}
	var tag := str((item as Dictionary).get("tag", ""))
	for uw in _user_water_data:
		if uw is Dictionary and str((uw as Dictionary).get("tag", "")) == tag:
			return uw
	return {}


## Open the pond settings modal for the water body at idx (Ctrl-click target).
func open_pond_editor(idx: int) -> void:
	if _pond_edit_ui == null:
		return
	var info := get_pond_info(idx)
	if not bool(info.get("valid", false)):
		return
	if _pond_edit_ui.has_method("open_for_pond"):
		_pond_edit_ui.call("open_for_pond", idx)


## Fill a sculpted basin with water. Does NOT touch the system graph — the player
## adds it to the graph explicitly via the Pond settings modal (Ctrl-click the
## pond → Add to graph), so cleared/deleted ponds never leave stale graph nodes.
func designate_sculpted_pond(poly: PackedVector2Array, label: String = "Sculpted Pond",
		level_m: float = NAN, basin_tag: String = "") -> bool:
	if poly.size() < 3:
		return false
	var area := BuildingBuilder.footprint_area_m2(poly)
	if area < WaterBuilder.MIN_AREA_M2:
		_notify_options_status("Pond too small (min ~%.0f m²) — widen the area" % WaterBuilder.MIN_AREA_M2, "warn")
		return false
	var tag := basin_tag if not basin_tag.is_empty() else EarthworksBuilder.basin_tag_from_poly(poly)
	var rec := {
		"points": poly, "kind": "pond", "tag": tag, "user": true, "label": label,
		"capacity_mode": "auto", "fill_mode": "auto",
	}
	if not is_nan(level_m):
		rec["level_m"] = level_m
	# Find the existing record for this SAME basin: exact tag match first (fast
	# path — untouched pond, e.g. a Rain/Drain level nudge), else the nearest
	# existing user pond within a tight radius (the tag drifted because the
	# player just resized/reshaped it — still the same pond). Carries forward
	# player value overrides + the stable pond_id from the old record.
	var replace_i := -1
	for i in _user_water_data.size():
		var item: Variant = _user_water_data[i]
		if item is Dictionary and str((item as Dictionary).get("tag", "")) == tag:
			replace_i = i
			break
	if replace_i < 0:
		replace_i = _find_user_pond_index_near_poly(poly, 15.0)
	var replaced := false
	if replace_i >= 0:
		var prev: Dictionary = _user_water_data[replace_i]
		if str(prev.get("capacity_mode", "auto")) == "manual" and prev.has("capacity_l"):
			rec["capacity_l"] = float(prev["capacity_l"])
			rec["capacity_mode"] = "manual"
		if prev.has("label"):
			rec["label"] = str(prev["label"])
		if prev.has("fill_mode"):
			rec["fill_mode"] = str(prev["fill_mode"])
		rec["pond_id"] = str(prev.get("pond_id", _new_pond_id()))
		_user_water_data[replace_i] = rec
		replaced = true
	if not replaced:
		rec["pond_id"] = _new_pond_id()
		_user_water_data.append(rec)
	_recompute_pond_volume_rec(rec)
	_save_user_water()
	_refresh_water_data()
	_attach_water()
	# If this pond was already on the graph (re-carve of an added pond, even
	# under a now-stale tag — pond_id is what actually identifies it), keep it
	# in sync rather than importing a duplicate twin.
	if _pond_tag_on_graph(tag, str(rec.get("pond_id", ""))):
		_sync_pond_graph_from_rec(rec)
	_notify_options_status("Pond water ready (%.0f m²) — hold Rain to fill" % area, "ok")
	return true


## _water_data = OSM water (fresh copy) + the player's designated ponds.
func _refresh_water_data() -> void:
	var combined: Array = []
	for item in (_osm_vectors.get("water", []) as Array):
		combined.append(item)
	for item in _user_water_data:
		combined.append(item)
	_water_data = combined


func _user_water_path() -> String:
	return "user://maps/user_water_%s_%s.json" % [
		TerrainEditGrid._coord_token(_lat), TerrainEditGrid._coord_token(_lon)]


func _load_part_inventory() -> void:
	_part_inventory = PartInventory.create_empty()
	_part_inventory.load_for_map(_lat, _lon)


## The per-map fabricated-part inventory (auto-created if the load sequence
## hasn't run yet). Consumed by the inventory/crafting UI + machine completion.
func get_part_inventory() -> PartInventory:
	if _part_inventory == null:
		_part_inventory = PartInventory.create_empty()
	return _part_inventory


## Credit a fabricated part to the inventory and persist. Called by
## SystemGraphView when a machine job completes.
func credit_part(part_id: String, count: int, meta: Dictionary) -> void:
	get_part_inventory().add_part(part_id, count, meta)
	save_part_inventory()


func save_part_inventory() -> void:
	if _part_inventory != null:
		_part_inventory.save(_lat, _lon)


var _chore_ledger: ChoreLedger = null


func _load_chore_ledger() -> void:
	_chore_ledger = ChoreLedger.create_default()
	_chore_ledger.load_for_map(_lat, _lon)


## Per-map chore-hours ledger (hybrid auto-debit / confirm gates for recipes).
func get_chore_ledger() -> ChoreLedger:
	if _chore_ledger == null:
		_chore_ledger = ChoreLedger.create_default()
	return _chore_ledger


func save_chore_ledger() -> void:
	if _chore_ledger != null:
		_chore_ledger.save(_lat, _lon)


# ---------------------------------------------------------------------------
# Persistent printed objects (mud/clay/concrete prints). Unlike fabricated
# parts (which go to the crafting inventory), a completed mud print dries in
# place and stays on the map. Records store the source STL path + world
# transform + dry color, keyed by job_id so re-completion/reload never dupes.
# ---------------------------------------------------------------------------
func _printed_objects_path() -> String:
	return "user://maps/printed_objects_%s_%s.json" % [
		TerrainEditGrid._coord_token(_lat), TerrainEditGrid._coord_token(_lon)]


func _load_printed_objects() -> void:
	_printed_objects = []
	var path := _printed_objects_path()
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Array:
				_printed_objects = parsed as Array
	for rec in _printed_objects:
		if rec is Dictionary:
			_spawn_printed_object(rec as Dictionary)


func _save_printed_objects() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(_printed_objects_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_printed_objects))


## Register + spawn a completed mud print. `rec` from CncMachineRuntime carries
## job_id, mesh_path (user:// STL), xform (Transform3D), dry_color ([r,g,b]),
## and optionally a live `mesh` (ArrayMesh) so the handoff matches the reveal.
## Idempotent per job_id so live completion + save reload never double-place it.
func register_printed_object(rec: Dictionary) -> void:
	var job_id := str(rec.get("job_id", ""))
	for existing in _printed_objects:
		if existing is Dictionary and str((existing as Dictionary).get("job_id", "")) == job_id:
			return
	var xf: Transform3D = rec.get("xform", Transform3D.IDENTITY)
	var b := xf.basis
	var stored := {
		"job_id": job_id,
		"mesh_path": str(rec.get("mesh_path", "")),
		"dry_color": rec.get("dry_color", [0.68, 0.56, 0.42]),
		"source": str(rec.get("source", "")),
		"basis": [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z],
		"origin": [xf.origin.x, xf.origin.y, xf.origin.z],
	}
	_printed_objects.append(stored)
	_save_printed_objects()
	var live_mesh: ArrayMesh = null
	if rec.get("mesh") is ArrayMesh:
		live_mesh = rec.get("mesh") as ArrayMesh
	_spawn_printed_object(stored, live_mesh)


func _printed_objects_root() -> Node3D:
	if _main == null:
		return null
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return null
	var root := terrain.get_node_or_null("PrintedObjects") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "PrintedObjects"
		terrain.add_child(root)
	return root


## Spawn a persisted print as a PlacedProp so it's crosshair-selectable and can
## be click-dragged to a new spot like any other placed model (GrabController).
## The stored world transform (rotation + print scale) rides ModelRoot; the
## translation rides the prop, so grab-move (which nudges only global_position)
## and the pick AABB / collision all behave.
func _spawn_printed_object(rec: Dictionary, live_mesh: ArrayMesh = null) -> void:
	var root := _printed_objects_root()
	if root == null:
		return
	var mesh: ArrayMesh = live_mesh
	if mesh == null:
		mesh = StlLoader.build_mesh(str(rec.get("mesh_path", "")))
	if mesh == null:
		return
	var job_id := str(rec.get("job_id", "x"))
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	# No physical wall — inspect layers by walking through; select via pick area.
	mi.set_meta("skip_prop_collision", true)
	var dc: Array = rec.get("dry_color", [0.68, 0.56, 0.42]) as Array
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(float(dc[0]), float(dc[1]), float(dc[2]))
	mat.roughness = 0.92
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	var ba: Array = rec.get("basis", []) as Array
	var oa: Array = rec.get("origin", [0, 0, 0]) as Array
	var bas := Basis.IDENTITY
	if ba.size() >= 9:
		bas = Basis(
			Vector3(float(ba[0]), float(ba[1]), float(ba[2])),
			Vector3(float(ba[3]), float(ba[4]), float(ba[5])),
			Vector3(float(ba[6]), float(ba[7]), float(ba[8])))
	var origin := Vector3.ZERO
	if oa.size() >= 3:
		origin = Vector3(float(oa[0]), float(oa[1]), float(oa[2]))
	var model_root := Node3D.new()
	model_root.name = "ModelRoot"
	model_root.transform = Transform3D(bas, Vector3.ZERO)
	model_root.add_child(mi)
	var prop := PlacedProp.new()
	prop.name = "Print_%s" % job_id
	prop.prop_id = "print_%s" % job_id
	# Distinct from the mud_printer machine so selection / grab treat this as an
	# independent placed model once the print has dried and handed off.
	prop.model_id = "mud_print"
	prop.set_meta("printed_job_id", job_id)
	prop.set_meta("independent_print", true)
	prop.add_child(model_root)
	root.add_child(prop)   # PlacedProp._ready runs here (sets a default prompt)
	prop.prompt = "Inspect · Move (drag)"
	prop.max_distance = 40.0
	prop.global_position = origin
	# Walk-through inspect: no solid wall, but a pick Area3D so the crosshair
	# ray hits the print even when nested inside the printer's collision hull.
	prop.setup_collision()
	_ensure_printed_pick_area(prop)
	# Finished prints accumulate as full-density STL meshes; give them the same
	# size-scaled distance culling + shadow policy as placed props so a yard full
	# of prints doesn't each render + shadow-cast at full cost from any distance.
	PropRenderTuning.apply_to_prop(prop, prop.get_local_pick_radius())


## Area3D proxy so InteractionFocus's physics ray (collide_with_areas) can hit a
## finished print that opted out of solid collision. Layer 2 keeps it off the
## player's walk collision (layer 1) while still ray-selectable.
func _ensure_printed_pick_area(prop: PlacedProp) -> void:
	if prop == null:
		return
	if prop.get_node_or_null("PrintPickArea") != null:
		return
	var aabb := prop.get_world_pick_aabb()
	if aabb.size.length_squared() < 0.0001:
		return
	# Convert world AABB into prop-local box.
	var inv := prop.global_transform.affine_inverse()
	var local_aabb := inv * aabb
	var area := Area3D.new()
	area.name = "PrintPickArea"
	area.collision_layer = 2
	area.collision_mask = 0
	area.monitorable = true
	area.monitoring = false
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(
		maxf(local_aabb.size.x, 0.2),
		maxf(local_aabb.size.y, 0.2),
		maxf(local_aabb.size.z, 0.2))
	cs.shape = box
	cs.position = local_aabb.get_center()
	area.add_child(cs)
	prop.add_child(area)


## Rewrite a printed object's stored world transform (after a grab-move commit)
## and persist. The live node has already moved; this only updates the sidecar so
## the new spot survives a reload.
func update_printed_object_transform(job_id: String, xf: Transform3D) -> void:
	if job_id.is_empty():
		return
	for i in _printed_objects.size():
		var rec: Variant = _printed_objects[i]
		if rec is Dictionary and str((rec as Dictionary).get("job_id", "")) == job_id:
			var b := xf.basis
			(rec as Dictionary)["basis"] = [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z]
			(rec as Dictionary)["origin"] = [xf.origin.x, xf.origin.y, xf.origin.z]
			_printed_objects[i] = rec
			_save_printed_objects()
			return


## Free + respawn every printed object from the sidecar — used to snap a
## cancelled/invalid grab-move back to its saved transform.
func reload_printed_objects() -> void:
	var root := _printed_objects_root()
	if root != null:
		for c in root.get_children():
			c.queue_free()
	for rec in _printed_objects:
		if rec is Dictionary:
			_spawn_printed_object(rec as Dictionary)


func _load_user_water() -> void:
	_user_water_data = []
	var path := _user_water_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	var migrated := false
	for entry in ((parsed as Dictionary).get("ponds", []) as Array):
		if not (entry is Dictionary):
			continue
		var pts := PackedVector2Array()
		for pv in ((entry as Dictionary).get("points", []) as Array):
			if pv is Array and (pv as Array).size() >= 2:
				pts.append(Vector2(float(pv[0]), float(pv[1])))
		if pts.size() < 3:
			continue
		var rec := {"points": pts, "kind": "pond", "user": true,
			"tag": str((entry as Dictionary).get("tag", ""))}
		var lvl := TerrainBuilder.variant_to_float((entry as Dictionary).get("level_m", NAN), NAN)
		if not is_nan(lvl):
			rec["level_m"] = lvl
		var cap := TerrainBuilder.variant_to_float((entry as Dictionary).get("capacity_l", NAN), NAN)
		if not is_nan(cap):
			rec["capacity_l"] = cap
		var stock := TerrainBuilder.variant_to_float((entry as Dictionary).get("stock_l", NAN), NAN)
		if not is_nan(stock):
			rec["stock_l"] = stock
		if (entry as Dictionary).has("capacity_mode"):
			rec["capacity_mode"] = str((entry as Dictionary)["capacity_mode"])
		if (entry as Dictionary).has("fill_mode"):
			rec["fill_mode"] = str((entry as Dictionary)["fill_mode"])
		if (entry as Dictionary).has("label"):
			rec["label"] = str((entry as Dictionary)["label"])
		# Auto-migrate: ponds saved before the stable-id feature get one assigned
		# now (persisted below), so identity stops depending on the shape-derived
		# tag from this point on.
		var pid := str((entry as Dictionary).get("pond_id", ""))
		if pid.is_empty():
			pid = _new_pond_id()
			migrated = true
		rec["pond_id"] = pid
		_user_water_data.append(rec)
	if migrated:
		_save_user_water()


func _save_user_water() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var ponds: Array = []
	for rec in _user_water_data:
		if not (rec is Dictionary):
			continue
		var pts: PackedVector2Array = (rec as Dictionary).get("points", PackedVector2Array())
		var arr: Array = []
		for p in pts:
			arr.append([p.x, p.y])
		var out := {"tag": str((rec as Dictionary).get("tag", "")), "points": arr,
			"pond_id": str((rec as Dictionary).get("pond_id", ""))}
		if (rec as Dictionary).has("level_m"):
			out["level_m"] = float((rec as Dictionary)["level_m"])
		if (rec as Dictionary).has("capacity_l"):
			out["capacity_l"] = float((rec as Dictionary)["capacity_l"])
		if (rec as Dictionary).has("stock_l"):
			out["stock_l"] = float((rec as Dictionary)["stock_l"])
		if (rec as Dictionary).has("capacity_mode"):
			out["capacity_mode"] = str((rec as Dictionary)["capacity_mode"])
		if (rec as Dictionary).has("fill_mode"):
			out["fill_mode"] = str((rec as Dictionary)["fill_mode"])
		if (rec as Dictionary).has("label"):
			out["label"] = str((rec as Dictionary)["label"])
		ponds.append(out)
	var f := FileAccess.open(_user_water_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"version": 2, "ponds": ponds}))


func pick_water_at_world(x: float, z: float) -> Dictionary:
	var p := Vector2(x, z)
	var best_idx := -1
	var best_area := INF
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		var kind := str((item as Dictionary).get("kind", "water"))
		if kind in WaterBuilder.FLOWING_KINDS:
			continue
		var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
		if poly.size() < 3 or not Geometry2D.is_point_in_polygon(p, poly):
			continue
		var area := BuildingBuilder.footprint_area_m2(poly)
		# Prefer the smallest containing body (pond over lake containing it).
		if area < best_area:
			best_area = area
			best_idx = i
	if best_idx < 0:
		return {"valid": false}
	var rec: Dictionary = _water_data[best_idx]
	var poly2: PackedVector2Array = rec.get("points", PackedVector2Array())
	var tag := str(rec.get("tag", _water_body_tag(poly2)))
	return {
		"valid": true,
		"water_idx": best_idx,
		"kind": str(rec.get("kind", "water")),
		"area_m2": BuildingBuilder.footprint_area_m2(poly2),
		"tag": tag,
		"user": bool(rec.get("user", false)),
		"added": _pond_tag_on_graph(tag),
	}


func get_water_focus_idx() -> int:
	return _water_focus_idx


func set_water_focus_idx(idx: int) -> void:
	if idx == _water_focus_idx:
		return
	_water_focus_idx = idx
	if idx < 0:
		_clear_water_highlight()
		return
	_draw_water_highlight(idx)


func is_pond_added(idx: int) -> bool:
	if idx < 0 or idx >= _water_data.size():
		return false
	var item: Variant = _water_data[idx]
	if not (item is Dictionary):
		return false
	var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
	var tag := str((item as Dictionary).get("tag", _water_body_tag(poly)))
	return _pond_tag_on_graph(tag)


func _draw_water_highlight(idx: int, tint: Color = Color(0.15, 0.55, 1.0, 0.45)) -> void:
	if _main == null or idx < 0 or idx >= _water_data.size():
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	var rec: Dictionary = _water_data[idx]
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	if poly.size() < 3:
		return
	if _water_highlight == null:
		_water_highlight = MeshInstance3D.new()
		_water_highlight.name = "WaterPondHighlight"
		terrain.add_child(_water_highlight)
	var mat := _water_highlight.material_override as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_water_highlight.material_override = mat
	mat.albedo_color = tint
	var footing := _highlight_footing_grid(false)
	_water_highlight.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev, 0.35)
	_water_highlight.visible = true


func _clear_water_highlight() -> void:
	if _water_highlight != null:
		_water_highlight.visible = false


## Refresh D8 watershed on the composed heightfield (call after major rebuilds).
func refresh_watershed_analysis() -> void:
	if _built_grid.is_empty() or _built_extent <= 0.0:
		_watershed_analysis = null
		return
	_watershed_analysis = Watershed.analyze(_built_grid, MESH_RES, _built_extent)


func get_watershed_analysis():
	if _watershed_analysis == null and not _built_grid.is_empty():
		refresh_watershed_analysis()
	return _watershed_analysis


## Upstream catchment area (m²) at a world XZ — 0 when analysis unavailable.
func watershed_upstream_area_m2(x: float, z: float) -> float:
	var a: Variant = get_watershed_analysis()
	if a == null:
		return 0.0
	var cell := Watershed.world_to_cell(a, x, z)
	return Watershed.upstream_area_m2(a, cell.x, cell.y)


## Local-window D8 for the hillside that drains into a pond.
## `tag_or_idx`: pond tag string, or water_data index (int).
## Returns `{valid, area_m2, cell_count, pour_xz, poly_world, poly_site, runoff_default,
## pond_tag, centroid, reason}`.
func analyze_pond_watershed(tag_or_idx: Variant, half_extent_m: float = 750.0,
		res: int = 128) -> Dictionary:
	var empty := {
		"valid": false, "reason": "not_found",
		"area_m2": 0.0, "cell_count": 0,
		"pour_xz": Vector2.ZERO, "poly_world": PackedVector2Array(),
		"poly_site": [], "runoff_default": 0.35,
		"pond_tag": "", "centroid": Vector2.ZERO,
	}
	var poly := PackedVector2Array()
	var tag := ""
	if tag_or_idx is int:
		var info := get_pond_info(int(tag_or_idx))
		if not bool(info.get("valid", false)):
			return empty
		tag = str(info.get("tag", ""))
		var item: Variant = _water_data[int(tag_or_idx)] if int(tag_or_idx) < _water_data.size() \
				else {}
		if item is Dictionary:
			poly = (item as Dictionary).get("points", PackedVector2Array()) as PackedVector2Array
	elif tag_or_idx is String:
		tag = str(tag_or_idx)
		for w in _water_data:
			if not (w is Dictionary):
				continue
			var rec: Dictionary = w
			var t := str(rec.get("tag", ""))
			if t == tag:
				poly = rec.get("points", PackedVector2Array()) as PackedVector2Array
				break
	if poly.size() < 3 or tag.is_empty():
		empty["reason"] = "no_pond"
		return empty
	var centroid := Vector2.ZERO
	for p in poly:
		centroid += p
	centroid /= float(maxi(poly.size(), 1))
	var half := clampf(half_extent_m, 80.0, 2000.0)
	# Prefer detail footprint when the pond sits inside the hi-res patch.
	if absf(centroid.x) <= _detail_half_extent and absf(centroid.y) <= _detail_half_extent:
		half = minf(half, maxf(_detail_half_extent * 0.9, 120.0))
	var height_at := func(x: float, z: float) -> float:
		return _ground_height_at(x, z)
	var analysis: Watershed.Analysis = Watershed.analyze_local(
			height_at, centroid, half, clampi(res, 48, 192))
	if analysis.res <= 0:
		empty["reason"] = "no_dem"
		return empty
	# Every DEM cell inside the pond is a pour sink (union of their upstream).
	var seeds := PackedInt32Array()
	var pour_c := -1
	var pour_r := -1
	var best_h := INF
	for r in analysis.res:
		for c in analysis.res:
			var w := Watershed.cell_to_world(analysis, c, r)
			if not Geometry2D.is_point_in_polygon(w, poly):
				continue
			seeds.append(r * analysis.res + c)
			var h := _ground_height_at(w.x, w.y)
			if h < best_h:
				best_h = h
				pour_c = c
				pour_r = r
	if seeds.is_empty():
		# Pond poly may be smaller than a cell — use centroid cell.
		var cell := Watershed.world_to_cell(analysis, centroid.x, centroid.y)
		pour_c = cell.x
		pour_r = cell.y
		seeds.append(pour_r * analysis.res + pour_c)
	var cells := Watershed.upstream_cells_multi(analysis, seeds)
	if cells.is_empty():
		empty["reason"] = "no_upstream"
		empty["pond_tag"] = tag
		empty["centroid"] = centroid
		return empty
	var poly_world := Watershed.upstream_polygon_world(analysis, cells)
	if poly_world.size() < 3:
		# Fallback: axis-aligned bbox of upstream cells.
		var mn := Vector2(INF, INF)
		var mx := Vector2(-INF, -INF)
		for idx_v in cells:
			var idx: int = int(idx_v)
			var cc: int = idx % analysis.res
			var rr: int = idx / analysis.res
			var w2 := Watershed.cell_to_world(analysis, cc, rr)
			mn.x = minf(mn.x, w2.x)
			mn.y = minf(mn.y, w2.y)
			mx.x = maxf(mx.x, w2.x)
			mx.y = maxf(mx.y, w2.y)
		poly_world = PackedVector2Array([
			Vector2(mn.x, mn.y), Vector2(mx.x, mn.y),
			Vector2(mx.x, mx.y), Vector2(mn.x, mx.y),
		])
	var area := float(cells.size()) * analysis.cell_area_m2
	var pour_xz := Watershed.cell_to_world(analysis, pour_c, pour_r)
	var poly_site: Array = []
	for p in poly_world:
		poly_site.append([p.x - centroid.x, p.y - centroid.y])
	return {
		"valid": true,
		"reason": "",
		"area_m2": area,
		"cell_count": cells.size(),
		"pour_xz": pour_xz,
		"poly_world": poly_world,
		"poly_site": poly_site,
		"runoff_default": 0.35,
		"pond_tag": tag,
		"centroid": centroid,
		"half_extent_m": half,
		"analysis_res": analysis.res,
	}


func set_watershed_preview(payload: Dictionary) -> void:
	_watershed_preview = payload.duplicate(true) if not payload.is_empty() else {}
	_update_watershed_highlight()
	_queue_graph_watershed_redraw()


func clear_watershed_preview() -> void:
	_watershed_preview.clear()
	_clear_watershed_highlight()
	_queue_graph_watershed_redraw()


func get_watershed_preview() -> Dictionary:
	return _watershed_preview


func _update_watershed_highlight() -> void:
	if not bool(_watershed_preview.get("valid", false)):
		_clear_watershed_highlight()
		return
	var poly: PackedVector2Array = _watershed_preview.get("poly_world", PackedVector2Array()) \
			as PackedVector2Array
	if poly.size() < 3 or _main == null:
		_clear_watershed_highlight()
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	if _watershed_highlight == null:
		_watershed_highlight = MeshInstance3D.new()
		_watershed_highlight.name = "WatershedPreviewHighlight"
		terrain.add_child(_watershed_highlight)
	var mat := _watershed_highlight.material_override as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_watershed_highlight.material_override = mat
	mat.albedo_color = Color(0.12, 0.82, 0.72, 0.42)
	var footing := _highlight_footing_grid(false)
	_watershed_highlight.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev, 0.45)
	_watershed_highlight.visible = true


func _clear_watershed_highlight() -> void:
	if _watershed_highlight != null:
		_watershed_highlight.visible = false


func _queue_graph_watershed_redraw() -> void:
	var graph := _find_system_graph_view()
	if graph == null:
		return
	if graph.has_method("queue_canvas_redraw"):
		graph.call("queue_canvas_redraw")
		return
	var c: Node = graph.get("_graph_canvas") as Node
	if c != null and c.has_method("queue_redraw"):
		c.call("queue_redraw")


## Analyze + stash preview overlay for a pond (does not touch the graph).
func preview_pond_watershed(idx: int) -> Dictionary:
	var result := analyze_pond_watershed(idx)
	if bool(result.get("valid", false)):
		set_watershed_preview(result)
	else:
		clear_watershed_preview()
		_notify_options_status("Watershed: %s" % str(result.get("reason", "failed")), "warn")
	return result


## Ensure pond is on the graph, then create/update hillside catchment → tank.
func designate_pond_watershed(idx: int) -> bool:
	var info := get_pond_info(idx)
	if not bool(info.get("valid", false)):
		return false
	if not bool(info.get("on_graph", false)):
		if not add_pond_to_graph(idx):
			return false
	var result := analyze_pond_watershed(idx)
	if not bool(result.get("valid", false)):
		_notify_options_status("Watershed: %s" % str(result.get("reason", "failed")), "warn")
		return false
	result["label"] = "%s Hillslope" % str(info.get("label", "Pond"))
	var graph := _find_system_graph_view()
	if graph == null or not graph.has_method("add_imported_watershed_catchment"):
		_notify_options_status("System graph unavailable for watershed", "warn")
		return false
	var ok: bool = bool(graph.call("add_imported_watershed_catchment", result))
	if ok:
		set_watershed_preview(result)
		_notify_options_status("Watershed catchment: %.1f ha" % (
				float(result.get("area_m2", 0.0)) / 10000.0), "ok")
	return ok


func remove_pond_watershed(idx: int) -> bool:
	var info := get_pond_info(idx)
	if not bool(info.get("valid", false)):
		return false
	var tag := str(info.get("tag", ""))
	var graph := _find_system_graph_view()
	if graph == null or not graph.has_method("remove_imported_watershed_catchment"):
		return false
	var ok: bool = bool(graph.call("remove_imported_watershed_catchment", tag))
	clear_watershed_preview()
	if ok:
		_notify_options_status("Removed watershed catchment", "ok")
	return ok


func pond_has_watershed_catchment(idx: int) -> bool:
	var info := get_pond_info(idx)
	if not bool(info.get("valid", false)):
		return false
	var graph := _find_system_graph_view()
	if graph == null or not graph.has_method("has_watershed_catchment_for_pond"):
		return false
	return bool(graph.call("has_watershed_catchment_for_pond", str(info.get("tag", ""))))


## Resolve `_water_data` index for a pond tag (−1 if missing).
func find_pond_idx_by_tag(tag: String) -> int:
	if tag.is_empty():
		return -1
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
		var t := str((item as Dictionary).get("tag", _water_body_tag(poly)))
		if t == tag:
			return i
	return -1


## Exact match on the stable pond_id — robust to the tag drifting from a
## re-carve/resize. Prefer this over find_pond_idx_by_tag wherever a caller
## already knows a pond_id.
func find_pond_idx_by_id(pond_id: String) -> int:
	if pond_id.is_empty():
		return -1
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		if str((item as Dictionary).get("pond_id", "")) == pond_id:
			return i
	return -1


## Tags of still-water bodies currently on the map (OSM + sculpted).
func live_pond_tags() -> PackedStringArray:
	var out := PackedStringArray()
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		var rec: Dictionary = item
		var kind := str(rec.get("kind", "water"))
		if kind in WaterBuilder.FLOWING_KINDS:
			continue
		var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var t := str(rec.get("tag", _water_body_tag(poly)))
		if not t.is_empty():
			out.append(t)
	return out


## Nearest still-water body to a world XZ point (within max_m). −1 if none.
func find_pond_idx_near_world_xz(world_xz: Vector2, max_m: float = 120.0) -> int:
	var best_i := -1
	var best_d := max_m
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		var rec: Dictionary = item
		var kind := str(rec.get("kind", "water"))
		if kind in WaterBuilder.FLOWING_KINDS:
			continue
		var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var c := SolarArrayBuilder.centroid(poly)
		var d := c.distance_to(world_xz)
		# Inside the footprint counts as zero distance.
		if Geometry2D.is_point_in_polygon(world_xz, poly):
			d = 0.0
		if d <= best_d:
			best_d = d
			best_i = i
	return best_i


## Resolve a graph pond tank → live `_water_data` index.
## pond_id match first (exact, robust to any tag drift) — else tag match — else
## nearest map pond to the tank's site (heals stale tags AND backfills pond_id
## for legacy tanks that predate it, so the next resolve is the fast exact path).
## Returns `{idx, tag, pond_id, label, healed, live}` (idx −1 when unresolved).
func resolve_pond_idx_for_graph_tank(tank: Dictionary) -> Dictionary:
	var empty := {"idx": -1, "tag": "", "pond_id": "", "label": "", "healed": false, "live": false}
	if tank.is_empty():
		return empty
	var specs: Dictionary = tank.get("specs", {}) as Dictionary
	var tag := str(specs.get("osm_water_tag", ""))
	var pond_id := str(specs.get("pond_id", ""))
	var label := str(specs.get("name", "Pond"))
	var idx := find_pond_idx_by_id(pond_id)
	if idx >= 0:
		var info_id := get_pond_info(idx)
		var live_tag_id := str(info_id.get("tag", tag))
		return {
			"idx": idx,
			"tag": live_tag_id,
			"pond_id": pond_id,
			"label": str(info_id.get("label", label)),
			"healed": live_tag_id != tag and not tag.is_empty(),
			"live": true,
		}
	idx = find_pond_idx_by_tag(tag)
	if idx >= 0:
		var info := get_pond_info(idx)
		return {
			"idx": idx,
			"tag": str(info.get("tag", tag)),
			"pond_id": str(info.get("pond_id", "")),
			"label": str(info.get("label", label)),
			"healed": false,
			"live": true,
		}
	# Fallback: nearest live body to tank site / poly centroid.
	var world := Vector2.ZERO
	var have_world := false
	var soi := get_node_or_null("/root/SoiService")
	if GraphSiteLayout.has_site_coords(tank) and soi != null and soi.has_method("world_center"):
		var center: Vector3 = soi.call("world_center") as Vector3
		world = GraphSiteLayout.site_to_world_xz(GraphSiteLayout.site_xz(tank), center)
		have_world = true
	if not have_world:
		# Catchment twin on the same tag may still carry osm_poly_site — skip.
		return empty
	idx = find_pond_idx_near_world_xz(world, 150.0)
	if idx < 0:
		return empty
	var info2 := get_pond_info(idx)
	var live_tag := str(info2.get("tag", ""))
	return {
		"idx": idx,
		"tag": live_tag,
		"pond_id": str(info2.get("pond_id", "")),
		"label": str(info2.get("label", label)),
		"healed": live_tag != tag and not live_tag.is_empty(),
		"live": true,
	}


## Drop graph pond tanks/catchments whose tags are no longer on the map.
## Heals stale tags first when a tank still sits on a live water body.
## Keeps siphon-wired tanks unless `force`.
func prune_orphan_ponds_from_graph(force: bool = false) -> int:
	var graph := _find_system_graph_view()
	if graph == null:
		return 0
	if graph.has_method("heal_pond_tags_from_map"):
		graph.call("heal_pond_tags_from_map", self)
	if not graph.has_method("prune_orphan_pond_items"):
		return 0
	var live: Dictionary = {}
	for t in live_pond_tags():
		live[t] = true
	var n: int = int(graph.call("prune_orphan_pond_items", live, force))
	if n > 0:
		_notify_options_status("Removed %d stale pond graph node(s)" % n, "ok")
	return n


## Import OSM vegetation polygon as a plant/crop bed on the system graph.
## Prefer grass_field / orchard / vineyard; other kinds still allowed if caller asks.
func add_veg_area_plant_to_graph(idx: int) -> bool:
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array):
		return false
	var info := VegAreaPicker.area_info(polys as Array, idx)
	if not bool(info.get("valid", false)):
		return false
	var kind := str(info.get("kind", ""))
	var preferred := kind in ["grass_field", "orchard", "vineyard", "park", "grass_lawn"]
	if not preferred and not kind.is_empty():
		# Still allow forest/scrub as canopy beds — label reflects kind.
		pass
	var tag := str(info.get("tag", ""))
	if tag.is_empty():
		return false
	var poly: PackedVector2Array = info.get("points", PackedVector2Array())
	var centroid: Vector2 = info.get("centroid", Vector2.ZERO)
	var area := float(info.get("area_m2", 0.0))
	if area <= 0.0 and poly.size() >= 3:
		area = BuildingBuilder.footprint_area_m2(poly)
	var min_v := poly[0]
	var max_v := poly[0]
	for p in poly:
		min_v.x = minf(min_v.x, p.x)
		min_v.y = minf(min_v.y, p.y)
		max_v.x = maxf(max_v.x, p.x)
		max_v.y = maxf(max_v.y, p.y)
	var graph := _find_system_graph_view()
	if graph == null or not graph.has_method("add_imported_plant"):
		_notify_options_status("System graph unavailable for plant import", "warn")
		return false
	var label := "OSM %s" % str(info.get("kind_label", "field")).capitalize()
	var ok: bool = bool(graph.call("add_imported_plant", {
		"osm_tag": tag,
		"label": label,
		"area_m2": maxf(area, 1.0),
		"centroid": centroid,
		"width_m": maxf(max_v.x - min_v.x, 1.0),
		"depth_m": maxf(max_v.y - min_v.y, 1.0),
		"points": poly,
		"veg_kind": kind,
	}))
	if ok:
		_notify_options_status(
				"Added crop area: %.0f m² (%s) → system graph" % [area, kind], "ok")
		print("TerrainLoader: added OSM veg plant '%s' (%.0f m², %s) to the system graph" % [tag, area, kind])
	return ok


## Highlight roof / veg by osm_tag for graph ↔ world selection sync.
func highlight_building_by_tag(tag: String) -> bool:
	if tag.is_empty():
		return false
	for i in _buildings_data.size():
		if not (_buildings_data[i] is Dictionary):
			continue
		var pts: Variant = (_buildings_data[i] as Dictionary).get("points", PackedVector2Array())
		if not (pts is PackedVector2Array):
			continue
		if BuildingBuilder.building_tag(pts) == tag:
			var idx := int((_buildings_data[i] as Dictionary).get("idx", i))
			set_building_focus_idx(idx)
			return true
	return false


func highlight_veg_by_tag(tag: String) -> bool:
	if tag.is_empty():
		return false
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array):
		return false
	for i in (polys as Array).size():
		var info := VegAreaPicker.area_info(polys as Array, i)
		if str(info.get("tag", "")) == tag:
			set_veg_focus_idx(i)
			return true
	return false


func clear_graph_osm_area_highlight() -> void:
	set_building_focus_idx(-1)
	set_veg_focus_idx(-1)


func _find_system_graph_view() -> Node:
	if _main == null:
		return null
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = get_tree().root.find_child("SystemGraphView", true, false)
	return sgv


func get_prop_graph_item_id(prop_id: String) -> String:
	if _placed_prop_layer == null or prop_id.is_empty():
		return ""
	var rec := _placed_prop_layer.find_by_id(prop_id)
	return str(rec.get("graph_item_id", ""))


func clear_graph_scene_highlight() -> void:
	if _scene_graph_highlight != null and is_instance_valid(_scene_graph_highlight):
		if _scene_graph_highlight.has_method("set_graph_highlight"):
			_scene_graph_highlight.call("set_graph_highlight", false)
	_scene_graph_highlight = null


func highlight_scene_node_for_graph(node: Node) -> void:
	clear_graph_scene_highlight()
	if node == null:
		return
	if node is PlacedProp:
		_scene_graph_highlight = node as Node3D
		(node as PlacedProp).set_graph_highlight(true)
		return
	var cur: Node = node
	while cur != null:
		if cur is PlacedProp:
			_scene_graph_highlight = cur as Node3D
			(cur as PlacedProp).set_graph_highlight(true)
			return
		cur = cur.get_parent()


func pick_solar_array_at_world(x: float, z: float) -> Dictionary:
	var p := Vector2(x, z)
	var best := -1
	var best_area := INF
	for i in _solar_arrays.size():
		var poly: PackedVector2Array = _solar_arrays[i].get("poly", PackedVector2Array())
		if poly.size() < 3 or not Geometry2D.is_point_in_polygon(p, poly):
			continue
		var area := _poly_area(poly)
		if area < best_area:
			best_area = area
			best = i
	if best < 0:
		return {"valid": false}
	return {"valid": true, "array_idx": best}


func _poly_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p0 := poly[i]
		var p1 := poly[(i + 1) % n]
		a += p0.x * p1.y - p1.x * p0.y
	return absf(a) * 0.5


func get_solar_array_focus_idx() -> int:
	return _solar_focus_idx


## Set (or clear with -1) the crosshair-focused array. Draws a red footprint overlay
## for arrays not yet added; clears it otherwise.
func set_solar_array_focus_idx(idx: int) -> void:
	if idx == _solar_focus_idx:
		return
	_solar_focus_idx = idx
	if idx < 0 or idx >= _solar_arrays.size() or bool(_solar_arrays[idx].get("added", false)):
		_clear_solar_highlight()
		return
	_draw_solar_highlight(idx)


func is_solar_array_added(idx: int) -> bool:
	if idx < 0 or idx >= _solar_arrays.size():
		return false
	return bool(_solar_arrays[idx].get("added", false))


## UI-facing summary for the crosshair prompt.
func get_solar_array_info(idx: int) -> Dictionary:
	if idx < 0 or idx >= _solar_arrays.size():
		return {}
	var rec: Dictionary = _solar_arrays[idx]
	var count := int(rec.get("panel_count", 0))
	return {
		"panel_count": count,
		"capacity_kw": float(count) * float(rec.get("watts", SolarArrayBuilder.PANEL_WATTS)) / 1000.0,
		"added": bool(rec.get("added", false)),
	}


## Add the targeted array to the system graph as one compound array node and fold
## its capacity into SolarUI. Idempotent per array (keyed by tag). Recomputes
## panel count from the footprint + configured module dimensions before import.
func add_solar_array_to_graph(idx: int, opts: Dictionary = {}) -> bool:
	if idx < 0 or idx >= _solar_arrays.size():
		return false
	var rec: Dictionary = _solar_arrays[idx]
	if bool(rec.get("added", false)):
		return false
	var poly: PackedVector2Array = rec.get("poly", PackedVector2Array())
	var tilt := float(rec.get("tilt", SolarArrayBuilder.default_tilt_deg(_lat)))
	var panel_spec := SolarArrayBuilder.resolve_panel_spec({
		"panel_w_m": float(opts.get("panel_w_m", rec.get("panel_w_m", SolarArrayBuilder.PANEL_W))),
		"panel_h_m": float(opts.get("panel_h_m", rec.get("panel_h_m", SolarArrayBuilder.PANEL_H))),
		"panel_watts": float(opts.get("watts", rec.get("watts", SolarArrayBuilder.PANEL_WATTS))),
		"gap_x_m": float(opts.get("gap_x_m", rec.get("gap_x_m", SolarArrayBuilder.GAP_X))),
		"row_gap_m": float(opts.get("row_gap_m", rec.get("row_gap_m", SolarArrayBuilder.ROW_GAP))),
		"voc": float(opts.get("voc", rec.get("voc", SolarArrayBuilder.PANEL_VOC))),
	})
	var count := int(rec.get("panel_count", 0))
	if poly.size() >= 3:
		count = SolarArrayBuilder.count_panels_for_footprint(poly, tilt, panel_spec)
		rec["panel_count"] = count
		rec["watts"] = float(panel_spec["panel_watts"])
		rec["panel_w_m"] = float(panel_spec["panel_w_m"])
		rec["panel_h_m"] = float(panel_spec["panel_h_m"])
	if count <= 0:
		return false
	var watts := float(panel_spec["panel_watts"])
	var tag := str(rec.get("tag", ""))
	rec["added"] = true
	_added_solar_tags[tag] = {"count": count, "watts": watts}
	var feed_opts := {
		"panel_w_m": float(panel_spec["panel_w_m"]),
		"panel_h_m": float(panel_spec["panel_h_m"]),
		"gap_x_m": float(panel_spec["gap_x_m"]),
		"row_gap_m": float(panel_spec["row_gap_m"]),
		"voc": float(panel_spec["voc"]),
		"vmp": float(panel_spec["vmp"]),
		"isc": float(panel_spec["isc"]),
		"imp": float(panel_spec["imp"]),
		"tilt_deg": tilt,
		"mount_style": str(opts.get("mount_style", rec.get("mount_style", SolarArrayBuilder.MOUNT_ROOF))),
		"footprint_xz": poly,
		"auto_wire": bool(opts.get("auto_wire", true)),
		"show_picker": bool(opts.get("show_picker", true)),
	}
	if opts.has("controller_id"):
		feed_opts["controller_id"] = str(opts["controller_id"])
	_feed_solar_graph(count, watts, "OSM Solar", tag, feed_opts)
	_refresh_added_solar_total()
	if idx == _solar_focus_idx:
		_clear_solar_highlight()
	var kw := float(count) * watts / 1000.0
	_notify_options_status("Added solar array: %d panels, %.2f kW → system graph" % [count, kw], "ok")
	print("TerrainLoader: added OSM solar array '%s' (%d panels, %.2f kW) to the system graph" % [tag, count, kw])
	return true


## Arrays whose centroid lies inside the current SoI and are not yet graph-imported.
## Returns [{idx, tag, panel_count, watts, centroid}].
func list_soi_solar_arrays_pending() -> Array:
	var out: Array = []
	var soi := get_node_or_null("/root/SoiService")
	for i in _solar_arrays.size():
		var rec: Dictionary = _solar_arrays[i]
		if bool(rec.get("added", false)):
			continue
		var poly: PackedVector2Array = rec.get("poly", PackedVector2Array())
		if poly.size() < 3:
			continue
		var c := SolarArrayBuilder.centroid(poly)
		if soi != null and soi.has_method("contains_xz") \
				and not bool(soi.call("contains_xz", c.x, c.y)):
			continue
		out.append({
			"idx": i,
			"tag": str(rec.get("tag", "")),
			"panel_count": int(rec.get("panel_count", 0)),
			"watts": float(rec.get("watts", SolarArrayBuilder.PANEL_WATTS)),
			"centroid": c,
		})
	return out


## Import every pending SoI solar array into the graph. Returns how many arrays added.
## Bulk import auto-wires without a per-array picker dialog.
func add_all_soi_solar_arrays_to_graph() -> int:
	var pending := list_soi_solar_arrays_pending()
	var n := 0
	for entry in pending:
		if add_solar_array_to_graph(int(entry.get("idx", -1)), {
			"show_picker": false,
			"auto_wire": true,
		}):
			n += 1
	if n > 0:
		_notify_options_status("Added %d OSM solar array(s) inside SoI → system graph" % n, "ok")
	return n


## Feed SolarUI the accumulated panel total across every array the player has added.
func _refresh_added_solar_total() -> void:
	var total := 0
	var tilt := SolarArrayBuilder.default_tilt_deg(_lat)
	var azimuth := SolarArrayBuilder.default_azimuth_deg(_lat)
	for tag in _added_solar_tags:
		total += int((_added_solar_tags[tag] as Dictionary).get("count", 0))
	if total <= 0:
		return
	_feed_solar_ui(total, SolarArrayBuilder.PANEL_WATTS, tilt, azimuth)


func _draw_solar_highlight(idx: int, tint: Color = Color(1.0, 0.12, 0.12, 0.5)) -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	var rec: Dictionary = _solar_arrays[idx]
	var poly: PackedVector2Array = rec.get("poly", PackedVector2Array())
	if poly.size() < 3:
		return
	if _solar_highlight == null:
		_solar_highlight = MeshInstance3D.new()
		_solar_highlight.name = "SolarArrayHighlight"
		terrain.add_child(_solar_highlight)
	var mat := _solar_highlight.material_override as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_solar_highlight.material_override = mat
	mat.albedo_color = tint
	# Sit the red overlay just above the panels (roof arrays float above the ground).
	var c := SolarArrayBuilder.centroid(poly)
	var ground := _ground_height_at(c.x, c.y)
	var lift := maxf(float(rec.get("base_y", ground)) - ground, 0.0) + 0.6
	var footing := _highlight_footing_grid(false)
	_solar_highlight.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev, lift)
	_solar_highlight.visible = true


func _clear_solar_highlight() -> void:
	if _solar_highlight != null:
		_solar_highlight.visible = false


## ---------------------------------------------------------------------------
## Service callbacks
## ---------------------------------------------------------------------------

func _on_elevation_ready(_key: String, grid: PackedFloat32Array, cols: int, rows: int,
		tag: String = "base") -> void:
	if tag == "detail":
		# Resample the detail DEM to the mesh/collision resolution UP FRONT so that
		# footing queries (vegetation + building grounding) sample the EXACT surface
		# the player sees and collides with. The visible DetailGround mesh and its
		# HeightMapShape3D collider are built at DETAIL_MESH_RES (256²); sampling a
		# finer 512² DEM for footing left trees/buildings floating above (or sunk
		# below) that mesh on any slope. One source grid → one surface everywhere.
		if cols > DETAIL_MESH_RES or rows > DETAIL_MESH_RES:
			grid = TerrainBuilder.resample(grid, cols, rows, DETAIL_MESH_RES)
			cols = DETAIL_MESH_RES
			rows = DETAIL_MESH_RES
		_detail_elev_grid = grid
		_detail_elev_cols = cols
		_detail_elev_rows = rows
		_detail_elev_done = true
		_detail_elev_resolved = true
		_load_progress_mark_done("detail_dem")
		print("TerrainLoader: detail DEM ready (%d×%d, %.0f m square)" % [
			_detail_elev_cols, _detail_elev_rows, _detail_extent_m()])
		_log_load_mem("detail DEM ready")
		if _load_sequence_active:
			_phase_resolve("elev:detail", true)
			return
		_rebuild_heightfield_staggered(false)
		_queue_auto_veg_generate(false)
		_check_load_complete()
		if _built:
			_finish_refresh("dem")
		return
	_elev_grid = grid
	_elev_cols = cols
	_elev_rows = rows
	_elev_done = true
	_load_progress_mark_done("base_dem")
	if _load_sequence_active:
		_phase_resolve("elev:base", true)
		return
	if _built:
		_apply_base_dem_refresh()
		if _refresh_pending.has("dem"):
			var es_svc := get_node_or_null("/root/ElevationService")
			if es_svc != null:
				_request_detail_dem(es_svc, true)
		return
	_try_build()


func _on_elevation_failed(reason: String, tag: String = "base") -> void:
	if tag == "detail":
		push_warning("TerrainLoader: detail elevation failed (%s) — keeping base DEM" % reason)
		_detail_elev_resolved = true
		_load_progress_mark_done("detail_dem")
		if _load_sequence_active:
			_phase_resolve("elev:detail", false)
			return
		_queue_auto_veg_generate(false)
		_check_load_complete()
		if _built:
			_abort_refresh("dem", reason)
		return
	if _load_sequence_active:
		_phase_resolve("elev:base", false)
		return
	if _built:
		_abort_refresh("dem", reason)
		return
	push_warning("TerrainLoader: elevation fetch failed (%s) — using flat fallback" % reason)
	_apply_elevation_fallback("base", reason)
	_try_build()


func _on_elevation_progress(done: int, total: int) -> void:
	if not _load_ui_active or _load_progress == null:
		return
	var ratio := float(done) / float(maxi(total, 1))
	if not _elev_done:
		_load_progress.set_partial("base_dem", ratio)
	elif not _detail_elev_resolved:
		_load_progress.set_partial("detail_dem", ratio)
	_update_load_ui("Elevation %d/%d" % [done, total])
	if done == 1 or done == total or done % 8 == 0:
		_log_load_mem("dem %d/%d" % [done, total])


func _on_imagery_ready(_key: String, texture: ImageTexture, tag: String) -> void:
	if tag == "hyper":
		_hyper_drape = texture
		_log_load_mem("hyper img ready")
		print("TerrainLoader: hyper roof ortho ready (%.0f m square)" % (_hyper_half_extent() * 2.0))
		_apply_building_textures()
		_apply_hyper_to_terrain()
		_maybe_request_ai_hero()
		return
	if tag == "detail":
		_log_load_mem("detail img ready")
		_detail_drape = texture
		if _load_sequence_active:
			_phase_resolve("img:detail", true)
			if _built:
				_apply_detail()
			return
		_resolve_detail_imagery()
		_apply_detail()
		_log_load_mem("detail applied")
		_request_hyper_imagery()
		if _built:
			_finish_refresh("imagery")
		return
	_drape = texture
	_img_done = true
	_load_progress_mark_done("base_img")
	if _load_sequence_active:
		_phase_resolve("img:base", true)
		return
	if _built:
		_apply_drape_materials()
		if _refresh_pending.has("imagery"):
			var img_svc := get_node_or_null("/root/ImageryService")
			if img_svc != null:
				img_svc.request_imagery(_lat, _lon, _detail_half_extent,
					_detail_target_px(), "detail", DETAIL_MAX_ZOOM, true)
		return
	_img_done = true
	_try_build()


func _on_imagery_failed(reason: String, tag: String) -> void:
	if tag == "hyper":
		push_warning("TerrainLoader: hyper roof ortho failed (%s) — roofs use detail/procedural" % reason)
		return
	if tag == "detail":
		if _detail_img_retry_zoom < 0:
			_detail_img_retry_zoom = DETAIL_MAX_ZOOM - 1
			var img_retry := get_node_or_null("/root/ImageryService")
			if img_retry != null and _detail_img_retry_zoom >= 15:
				push_warning("TerrainLoader: detail imagery failed (%s) — retrying at z%d" % [
					reason, _detail_img_retry_zoom])
				img_retry.request_imagery(_lat, _lon, _detail_half_extent,
					_detail_target_px(), "detail", _detail_img_retry_zoom)
				return
		push_warning("TerrainLoader: detail imagery failed (%s) — base drape only" % reason)
		if _load_sequence_active:
			_phase_resolve("img:detail", false)
			return
		_resolve_detail_imagery()
		_check_load_complete()
		if _built:
			_abort_refresh("imagery", reason)
		return
	if _load_sequence_active:
		_phase_resolve("img:base", false)
		return
	push_warning("TerrainLoader: imagery fetch failed (%s) — using neutral drape" % reason)
	_apply_imagery_fallback("base")
	_try_build()


func _on_imagery_progress(done: int, total: int) -> void:
	if not _load_ui_active or _load_progress == null:
		return
	var ratio := float(done) / float(maxi(total, 1))
	if not _img_done:
		_load_progress.set_partial("base_img", ratio)
	elif not _detail_img_resolved:
		_load_progress.set_partial("detail_img", ratio)
	_update_load_ui("Imagery tiles %d/%d" % [done, total])
	if done == 1 or done == total or done % 8 == 0:
		_log_load_mem("img tile %d/%d" % [done, total])


func _on_buildings_progress(message: String) -> void:
	_load_hint = message
	_update_load_ui()


func _on_vegetation_progress(message: String) -> void:
	_load_hint = message
	_update_load_ui()


## Queue the hyper roof-ortho fetch (rides ImageryService's serialized queue, so
## it never races the base/detail layers; result lands in _on_imagery_ready).
func _request_hyper_imagery() -> void:
	var img := get_node_or_null("/root/ImageryService")
	if img == null:
		return
	var bypass := _force_refetch or not TerrainCacheSettings.cache_enabled()
	img.request_imagery(_lat, _lon, _hyper_half_extent(), _hyper_target_px(),
		"hyper", HYPER_MAX_ZOOM, bypass)


func _hyper_target_px() -> int:
	# An explicit manual override (low-VRAM machines) always wins; otherwise the
	# selected quality tier drives it.
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK and cfg.has_section_key("terrain", "hyper_target_px"):
		return int(cfg.get_value("terrain", "hyper_target_px", HYPER_TARGET_PX_DEFAULT))
	return int(QUALITY_HYPER_TARGET_PX[_quality_tier()])


## Current terrain imagery quality tier (0..QUALITY_TIER_COUNT-1), from config.
func _quality_tier() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		return clampi(int(cfg.get_value("terrain", "quality_tier", QUALITY_TIER_DEFAULT)),
			0, QUALITY_TIER_COUNT - 1)
	return QUALITY_TIER_DEFAULT


## Detail-drape stitch target (px) for the current quality tier.
func _detail_target_px() -> int:
	return int(QUALITY_DETAIL_TARGET_PX[_quality_tier()])


## Hyper (sharpest) layer half-extent (m) for the current quality tier.
func _hyper_half_extent() -> float:
	return float(QUALITY_HYPER_HALF_EXTENT[_quality_tier()])


## --- Terrain imagery quality (public API for the settings UI) ---------------

## Current quality tier index (0..QUALITY_TIER_COUNT-1).
func get_terrain_quality() -> int:
	return _quality_tier()


## Human-readable label + cost hint for a tier (used by the settings slider).
func terrain_quality_label(tier: int) -> String:
	var t := clampi(tier, 0, QUALITY_TIER_COUNT - 1)
	var name: String = QUALITY_TIER_NAMES[t]
	var detail_px: int = int(QUALITY_DETAIL_TARGET_PX[t])
	var hyper_m: float = float(QUALITY_HYPER_HALF_EXTENT[t])
	return "%s — detail %dpx, sharp to %.0f m" % [name, detail_px, hyper_m]


## Set the imagery quality tier, persist it, and re-fetch the detail + hyper
## drapes at the new resolution/coverage (base drape is tier-independent, so it is
## NOT re-downloaded). No-op if unchanged or if a full load is in progress. Only
## imagery changes — the sculpt tile mesh/collider density stays the same.
func set_terrain_quality(tier: int) -> void:
	var t := clampi(tier, 0, QUALITY_TIER_COUNT - 1)
	if t == _quality_tier():
		return
	_save_terrain_config_value("quality_tier", t)
	if not _built or _load_sequence_active:
		return
	_begin_refresh("imagery")
	_begin_detail_imagery_refetch()
	print("TerrainLoader: terrain quality → %s (detail %d px, hyper %.0f m @ %d px) — re-fetching drape …" % [
		QUALITY_TIER_NAMES[t], _detail_target_px(), _hyper_half_extent(), _hyper_target_px()])


## Scale base drape resolution with world radius so large sites stay readable at distance.
func _base_imagery_target_px() -> int:
	var side_km := _half_extent * 2.0 / 1000.0
	return clampi(int(side_km * 32.0), 2048, 8192)


func _base_drape_bbox() -> Dictionary:
	return GeoMath.bbox_for(_lat, _lon, _half_extent)


func _detail_drape_bbox() -> Dictionary:
	return GeoMath.bbox_for(_lat, _lon, _detail_half_extent)


## Stamp Mercator-correction bboxes onto Ground / DetailGround shader materials
## so mesh UV (lon/lat-linear) samples ESRI drapes at the matching WGS84 point.
func _stamp_drape_mercator_bboxes(terrain: Node3D = null) -> void:
	if terrain == null and _main != null:
		terrain = _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var base_bb := _base_drape_bbox()
	var detail_bb := _detail_drape_bbox()
	for child_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(child_name) as MeshInstance3D
		if mi == null or not (mi.material_override is ShaderMaterial):
			continue
		TerrainBuilder.apply_drape_bboxes(
			mi.material_override as ShaderMaterial, base_bb, detail_bb)
	_apply_hyper_to_terrain(terrain)
	_apply_ai_to_terrain(terrain)


## Stamp the hyper ortho patch (sharpest ESRI zoom over the central ~1 km) onto
## the terrain drape shaders so the core high-res area shows the highest-res
## imagery by default — not just building roofs / berms.
func _apply_hyper_to_terrain(terrain: Node3D = null) -> void:
	if _hyper_drape == null:
		return
	if terrain == null and _main != null:
		terrain = _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var hyper_extent := _hyper_half_extent() * 2.0
	var hyper_vec := TerrainBuilder.bbox_to_shader_vec4(
		GeoMath.bbox_for(_lat, _lon, _hyper_half_extent()))
	var hyper_feather_uv := TerrainBuilder.feather_uv_from_metres(
		_seam_feather_m, hyper_extent)
	for child_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(child_name) as MeshInstance3D
		if mi == null or not (mi.material_override is ShaderMaterial):
			continue
		var sm := mi.material_override as ShaderMaterial
		var span := _detail_extent_m() if child_name == "DetailGround" else _built_extent
		sm.set_shader_parameter("hyper_tex", _hyper_drape)
		sm.set_shader_parameter("use_hyper", true)
		sm.set_shader_parameter("hyper_ratio", span / hyper_extent)
		sm.set_shader_parameter("hyper_bbox", hyper_vec)
		sm.set_shader_parameter("correct_hyper_mercator", true)
		sm.set_shader_parameter("hyper_feather", hyper_feather_uv)


## --- AI hero patch (Gemini-enhanced spawn-area ground) ----------------------

## True when the AI hero patch is enabled in config ([gemini] ai_hero_enabled).
func _ai_hero_enabled() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		return bool(cfg.get_value("gemini", "ai_hero_enabled", false))
	return false


## Hero patch half-extent (m), configurable via [gemini] ai_hero_half_extent_m.
func _ai_hero_half_extent() -> float:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		return maxf(10.0, float(cfg.get_value("gemini", "ai_hero_half_extent_m",
			AI_HERO_HALF_EXTENT_DEFAULT)))
	return AI_HERO_HALF_EXTENT_DEFAULT


## Requested Gemini image size ("1K" or "2K"), via [gemini] ai_image_size.
func _ai_image_size() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		var s := str(cfg.get_value("gemini", "ai_image_size", AI_IMAGE_SIZE_DEFAULT))
		return "1K" if s == "1K" else "2K"
	return AI_IMAGE_SIZE_DEFAULT


## Stable cache key for this site + hero radius (a radius change regenerates).
func _ai_cache_key() -> String:
	return "%s_%s_r%d" % [String.num(_lat, 5), String.num(_lon, 5),
		int(round(_ai_hero_half_extent()))]


## Crop the central hero square out of the hyper drape image. The hyper drape is
## Mercator-linear across the hyper bbox (row 0 = north), so the sub-window is
## located via longitude-linear x and Mercator-y interpolation — the same mapping
## the shader uses. Returns null if the drape isn't available / too small.
func _crop_hero_from_hyper() -> Image:
	if _hyper_drape == null:
		return null
	var src := _hyper_drape.get_image()
	if src == null or src.is_empty():
		return null
	var hyper_bb := GeoMath.bbox_for(_lat, _lon, _hyper_half_extent())
	var hero_bb := GeoMath.bbox_for(_lat, _lon, _ai_hero_half_extent())
	var w := src.get_width()
	var h := src.get_height()
	# Longitude is linear in the drape's x axis.
	var lon_span: float = float(hyper_bb["east"]) - float(hyper_bb["west"])
	var x0 := int(floor((float(hero_bb["west"]) - float(hyper_bb["west"])) / lon_span * float(w)))
	var x1 := int(ceil((float(hero_bb["east"]) - float(hyper_bb["west"])) / lon_span * float(w)))
	# Latitude maps through Mercator-y (asinh(tan)) into the drape's y axis.
	var my_n := GeoMath.asinh(tan(deg_to_rad(clampf(float(hyper_bb["north"]), -85.05, 85.05))))
	var my_s := GeoMath.asinh(tan(deg_to_rad(clampf(float(hyper_bb["south"]), -85.05, 85.05))))
	var my_hero_n := GeoMath.asinh(tan(deg_to_rad(clampf(float(hero_bb["north"]), -85.05, 85.05))))
	var my_hero_s := GeoMath.asinh(tan(deg_to_rad(clampf(float(hero_bb["south"]), -85.05, 85.05))))
	var my_span: float = my_n - my_s
	var y0 := int(floor((my_n - my_hero_n) / my_span * float(h)))
	var y1 := int(ceil((my_n - my_hero_s) / my_span * float(h)))
	x0 = clampi(x0, 0, w - 1)
	x1 = clampi(x1, x0 + 1, w)
	y0 = clampi(y0, 0, h - 1)
	y1 = clampi(y1, y0 + 1, h)
	if (x1 - x0) < 8 or (y1 - y0) < 8:
		return null
	var region := Rect2i(x0, y0, x1 - x0, y1 - y0)
	var crop := src.get_region(region)
	# The crop is Mercator-linear over the hero bbox — that's what _ai_bbox +
	# correct_ai_mercator expect, so no reprojection is needed.
	return crop


## Fire the AI hero request after hyper lands, if enabled + keyed + not already
## in flight. Never gates load (post-hyper, like hyper itself). A cached result
## returns immediately with no API call.
func _maybe_request_ai_hero() -> void:
	if _ai_request_active:
		return
	if not _ai_hero_enabled():
		return
	var ai := get_node_or_null("/root/AiImageryService")
	if ai == null or not ai.has_key():
		return
	if _hyper_drape == null:
		return
	var crop := _crop_hero_from_hyper()
	if crop == null:
		push_warning("TerrainLoader: AI hero skipped — could not crop hero square from hyper drape")
		return
	var hero_bb := GeoMath.bbox_for(_lat, _lon, _ai_hero_half_extent())
	_ai_request_active = true
	_notify_options_status("AI: enhancing spawn-area ground…")
	ai.enhance(crop, hero_bb, _ai_cache_key(), _ai_image_size(), _force_refetch)


func _on_ai_ready(key: String, texture: ImageTexture, bbox: Dictionary) -> void:
	if key != _ai_cache_key():
		return  # stale (site/radius changed since the request)
	_ai_request_active = false
	_ai_drape = texture
	_ai_bbox = bbox
	_log_load_mem("ai hero ready")
	print("TerrainLoader: AI hero patch ready (%.0f m square)" % (_ai_hero_half_extent() * 2.0))
	_apply_ai_to_terrain()
	_notify_options_status("AI: spawn-area ground enhanced")


func _on_ai_failed(reason: String) -> void:
	_ai_request_active = false
	push_warning("TerrainLoader: AI hero patch failed (%s) — keeping hyper drape" % reason)
	_notify_options_status("AI enhance failed: %s" % reason, "warn")


## Stamp the AI hero patch onto the terrain drape shaders, overlaid on top of the
## hyper layer within the central hero square. Mirrors _apply_hyper_to_terrain.
func _apply_ai_to_terrain(terrain: Node3D = null) -> void:
	if _ai_drape == null:
		return
	if terrain == null and _main != null:
		terrain = _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var ai_extent := _ai_hero_half_extent() * 2.0
	var ai_bb: Dictionary = _ai_bbox if not _ai_bbox.is_empty() \
		else GeoMath.bbox_for(_lat, _lon, _ai_hero_half_extent())
	var ai_vec := TerrainBuilder.bbox_to_shader_vec4(ai_bb)
	var ai_feather_uv := TerrainBuilder.feather_uv_from_metres(_seam_feather_m, ai_extent)
	for child_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(child_name) as MeshInstance3D
		if mi == null or not (mi.material_override is ShaderMaterial):
			continue
		var sm := mi.material_override as ShaderMaterial
		var span := _detail_extent_m() if child_name == "DetailGround" else _built_extent
		sm.set_shader_parameter("ai_tex", _ai_drape)
		sm.set_shader_parameter("use_ai", true)
		sm.set_shader_parameter("ai_ratio", span / ai_extent)
		sm.set_shader_parameter("ai_bbox", ai_vec)
		sm.set_shader_parameter("correct_ai_mercator", true)
		sm.set_shader_parameter("ai_feather", ai_feather_uv)


## Delete the cached AI hero PNG and re-request (wired to the UI Regenerate
## button). If disabled, just clears the current AI overlay.
func refresh_ai_hero() -> void:
	var ai := get_node_or_null("/root/AiImageryService")
	if not _ai_hero_enabled():
		_clear_ai_overlay()
		_notify_options_status("AI enhance is off")
		return
	if ai == null or not ai.has_key():
		_notify_options_status("No Gemini key — add [gemini] api_key= to terrain_config.cfg", "warn")
		return
	# Force a fresh generation regardless of cache.
	_ai_request_active = false
	var crop := _crop_hero_from_hyper()
	if crop == null:
		_notify_options_status("AI enhance needs the hyper drape — try again after it loads", "warn")
		return
	var hero_bb := GeoMath.bbox_for(_lat, _lon, _ai_hero_half_extent())
	_ai_request_active = true
	_notify_options_status("AI: regenerating spawn-area ground…")
	ai.enhance(crop, hero_bb, _ai_cache_key(), _ai_image_size(), true)


## Turn off the AI overlay on the terrain materials (leaves hyper untouched).
func _clear_ai_overlay() -> void:
	_ai_drape = null
	_ai_bbox = {}
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	for child_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(child_name) as MeshInstance3D
		if mi != null and mi.material_override is ShaderMaterial:
			(mi.material_override as ShaderMaterial).set_shader_parameter("use_ai", false)


## Swap the Ground material to the high-res-centre shader once the detail patch
## arrives. If the terrain isn't built yet, _try_build() will pick up _detail_drape.
func _apply_detail() -> void:
	if not _built or _main == null or _detail_drape == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var detail_ground := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	if detail_ground != null:
		var feather_uv := TerrainBuilder.feather_uv_from_metres(
			_seam_feather_m, _detail_extent_m())
		detail_ground.material_override = TerrainBuilder.make_terrain_material(
			_drape, _detail_drape, _built_extent, _detail_extent_m(),
			true, false, false, feather_uv, _base_drape_bbox(), _detail_drape_bbox())
		if detail_ground.material_override != null:
			detail_ground.material_override.render_priority = TerrainBuilder.DETAIL_GROUND_RENDER_PRIORITY
	TerrainBuilder.sync_coarse_ground_hide(
		terrain, _drape, _detail_drape, _built_extent, _detail_extent_m(), _seam_feather_m)
	_stamp_drape_mercator_bboxes(terrain)
	# Edit-tile meshes shade with DetailGround's material — hand them the new one.
	if _height_field != null and is_instance_valid(_height_field):
		_height_field.set_material(_detail_ground_material(terrain))
	print("TerrainLoader: applied high-res centre drape (%.0f m square)" % (_detail_extent_m()))
	_apply_building_textures()
	_queue_auto_veg_generate(_auto_veg_generated)


func _apply_base_dem_refresh() -> void:
	var grid := TerrainBuilder.resample(_elev_grid, _elev_cols, _elev_rows, MESH_RES)
	_base_dem_grid = grid
	_built_center_elev = TerrainBuilder.mean_elevation(grid)
	_spawn_ground_y = TerrainBuilder.height_at_world_xz(
		grid, MESH_RES, _built_extent, _built_center_elev, 0.0, 0.0)
	_rebuild_heightfield()
	_sync_actors_to_ground(true)
	print("TerrainLoader: base DEM refreshed")


func _apply_drape_materials() -> void:
	if not _built or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	_rebuild_coarse_surface(terrain)
	_rebuild_detail_patch(terrain)
	_stamp_drape_mercator_bboxes(terrain)
	_apply_building_textures()
	_queue_auto_veg_generate(_auto_veg_generated)
	print("TerrainLoader: imagery drape refreshed")


func _on_osm_vectors_ready(_key: String, payload: Dictionary) -> void:
	_osm_vectors_raw = payload
	_maybe_autoseed_brc_osm_offset()
	_rebind_osm_registration(false)
	if _load_sequence_active:
		_phase_resolve("osm_map", true)
		return
	_load_progress_mark_done("osm_map")
	_check_load_complete()
	if _built:
		call_deferred("_apply_osm_vectors_after_fetch")


func _apply_osm_vectors_after_fetch() -> void:
	if not _built:
		return
	var cfg := _terrain_config()
	if cfg.flatten_roads or cfg.flatten_landuse:
		_rebuild_heightfield()
	else:
		_attach_buildings()
		_attach_water()
	_apply_solar_arrays()
	_queue_auto_veg_generate(_auto_veg_generated)
	call_deferred("_attach_camps")
	_finish_refresh("osm_map")


func _on_buildings_failed(reason: String) -> void:
	push_warning("TerrainLoader: OSM buildings unavailable (%s)" % reason)
	_toast("OSM building/water data unavailable — map will load without them.", ToastUI.Level.WARN)
	if _load_sequence_active:
		_phase_resolve("osm_map", false)
		return
	_load_progress_mark_done("osm_map")
	if _built:
		_finish_refresh("osm_map")
	_check_load_complete()


func set_building_shadows(enabled: bool) -> void:
	if _buildings_root != null:
		_set_shadows_recursive(_buildings_root, enabled)
	if _main != null:
		var terrain = _main.get_node_or_null("Terrain")
		if terrain != null:
			for c in terrain.get_children():
				if c is GeometryInstance3D and c.name.begins_with("Bldg_"):
					c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _set_shadows_recursive(node: Node, enabled: bool) -> void:
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_set_shadows_recursive(child, enabled)

func _attach_buildings(enable_shadows: bool = true) -> void:
	if _main != null and _main.has_method("get_building_shadows_enabled"):
		enable_shadows = _main.get_building_shadows_enabled()
	if _main == null or _buildings_data.is_empty():
		return
	var cfg := _terrain_config()
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	if not cfg.show_buildings:
		_clear_building_nodes(terrain)
		return
	if _built_grid.is_empty():
		var grids := _compose_terrain_grids()
		_footing_grid = grids["footing"]
		_built_grid = grids["built"]
		_built_collision_grid = grids.get("collision_coarse", _built_grid)
		_detail_surface_grid = grids["detail_surface"]
	_clear_building_nodes(terrain)
	var detail_cols := _detail_elev_cols if not _detail_surface_grid.is_empty() else 0
	var detail_rows := _detail_elev_rows if not _detail_surface_grid.is_empty() else 0
	var excluded: Array = []
	if _placed_prop_layer != null:
		excluded = _placed_prop_layer.get_replaced_building_indices()
	# Styled buildings leave the merged mesh and get individual instances.
	var styled := _styled_building_indices()
	for idx in styled:
		excluded.append(idx)
	var t0 := Time.get_ticks_msec()
	var visible_buildings := _features_intersecting_square(_buildings_data, _detail_half_extent)
	var node := BuildingBuilder.build_buildings_node(
		visible_buildings, _built_grid, MESH_RES, _built_extent, _built_center_elev,
		_drape, _detail_drape, _detail_extent_m(), _built_extent,
		_detail_surface_grid, detail_cols, detail_rows, excluded, enable_shadows)
	if node != null:
		terrain.add_child(node)
		_buildings_root = node
	_attach_custom_buildings(terrain, styled, enable_shadows)
	# Ortho roof uniforms: the hyper/detail drape may have landed BEFORE the
	# buildings existed (cached imagery resolves early), so re-apply here too.
	_apply_building_textures()
	print("TerrainLoader: extruded %d OSM buildings (%d styled) in %d ms (hi-res drape=%s)" % [
		visible_buildings.size(), styled.size(), Time.get_ticks_msec() - t0,
		"yes" if _detail_drape != null else "base only"])
	_apply_cached_geometry_visibility()


## idx -> stable tag for every building carrying a style override. Prop-replaced
## buildings stay with the prop (the model wins over a style record).
func _styled_building_indices() -> Dictionary:
	var out: Dictionary = {}
	if _building_style_layer == null or _building_style_layer.styles.is_empty():
		return out
	for item in _buildings_data:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var pts: Variant = d.get("points", PackedVector2Array())
		if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
			continue
		var tag := BuildingBuilder.building_tag(pts)
		if not _building_style_layer.has_style(tag):
			continue
		var idx := int(d.get("idx", -1))
		if _placed_prop_layer != null and _placed_prop_layer.is_building_replaced(idx):
			continue
		out[idx] = tag
	return out


func _attach_custom_buildings(terrain: Node, styled: Dictionary,
		enable_shadows: bool = true) -> void:
	if styled.is_empty():
		return
	var detail_cols := _detail_elev_cols if not _detail_surface_grid.is_empty() else 0
	var detail_rows := _detail_elev_rows if not _detail_surface_grid.is_empty() else 0
	var root := Node3D.new()
	root.name = "BuildingsCustom"
	for idx in styled:
		var d := _find_building_record(int(idx))
		if d.is_empty():
			continue
		var tag: String = styled[idx]
		var style: Dictionary = _building_style_layer.get_style(tag)
		var mi := BuildingBuilder.build_single_building(
			d, style,
			_built_grid, MESH_RES, _built_extent, _built_center_elev,
			_detail_surface_grid, detail_cols, detail_rows,
			_detail_extent_m(), enable_shadows)
		if mi != null:
			mi.name = "B_%s" % tag
			_apply_styled_wall_material(mi, style)
			root.add_child(mi)
	if root.get_child_count() == 0:
		root.free()
		return
	terrain.add_child(root)
	_custom_buildings_root = root


## Facade textures for styled hero buildings: PNG/JPG dropped by the user (or
## tools/generate_facades.py) into user://maps/facade_textures/, referenced by
## file name in style["wall_texture"] with real-world tile size
## style["wall_tex_w_m"]/["wall_tex_h_m"]. Missing/unreadable → warn once,
## procedural wall (the style's wall_mode) stays.
const FACADE_TEX_DIR := "user://maps/facade_textures"
var _facade_tex_cache: Dictionary = {}   # file -> Texture2D or null (negative-cached)


func _apply_styled_wall_material(mi: MeshInstance3D, style: Dictionary) -> void:
	var file := str(style.get("wall_texture", ""))
	if file.is_empty():
		return
	var tex := _facade_texture(file)
	if tex == null:
		return
	var size := Vector2(
		clampf(TerrainBuilder.dict_float(style, "wall_tex_w_m", 4.0), 0.5, 50.0),
		clampf(TerrainBuilder.dict_float(style, "wall_tex_h_m", 3.0), 0.5, 50.0))
	mi.set_surface_override_material(0, BuildingBuilder.make_wall_material(tex, size))


func _facade_texture(file: String) -> Texture2D:
	if _facade_tex_cache.has(file):
		return _facade_tex_cache[file]
	var path := "%s/%s" % [FACADE_TEX_DIR, file.get_file()]
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == OK:
			img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		push_warning("TerrainLoader: facade texture missing/unreadable: %s" % path)
	_facade_tex_cache[file] = tex
	return tex


static func list_facade_textures() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(FACADE_TEX_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		var ext := f.get_extension().to_lower()
		if ext == "png" or ext == "jpg" or ext == "jpeg":
			out.append(f)
		if out.size() >= 64:
			break
	return out


func _find_building_record(building_idx: int) -> Dictionary:
	for item in _buildings_data:
		if item is Dictionary and int((item as Dictionary).get("idx", -1)) == building_idx:
			return item
	return {}


func _attach_water() -> void:
	if _main == null:
		return
	var cfg := _terrain_config()
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	var old := terrain.get_node_or_null("Water")
	if old != null:
		# Detach synchronously — queue_free() alone is deferred to frame end, so
		# the old body's ReflectionProbes stay registered in the render scenario.
		# Water is re-draped once per load layer (10 call sites), and each build
		# adds its probes before the previous node's are freed, stacking several
		# nodes' probes into the 64-slot reflection atlas at once → atlas overflow
		# → null-framebuffer GPU crash (observed while zooming the elevation view).
		# remove_child() pulls the old probes out of the scenario this frame.
		old.name = "WaterOld"
		terrain.remove_child(old)
		old.queue_free()
	_water_root = null
	if not cfg.show_water or _water_data.is_empty():
		return
	if _footing_grid.is_empty():
		_footing_grid = _compose_terrain_grids()["footing"]
	var detail_res := _detail_elev_cols if not _detail_surface_grid.is_empty() else 0
	var coarse_elev := _built_grid if not _built_grid.is_empty() else _footing_grid
	var node := WaterBuilder.build_water_node(
		_water_data, coarse_elev, MESH_RES, _built_extent, _built_center_elev,
		_detail_surface_grid, detail_res, _detail_extent_m(), _seam_feather_m)
	if node == null:
		return
	terrain.add_child(node)
	_water_root = node
	print("TerrainLoader: draped %d OSM water polygons" % _water_data.size())
	call_deferred("_refresh_water_reflection_probes")


func _refresh_water_reflection_probes() -> void:
	if _water_root == null:
		return
	WaterBuilder.refresh_reflection_probes(_water_root)


## Procedurally populate the empty street blocks of a dense city grid (Black Rock
## City and the like) with camp structures + coloured night lights. Gated on
## street density + the generate_camps option, deterministic by lat/lon so saves
## and resumes reproduce the same city. Mirrors _attach_buildings/_attach_water.
func _attach_camps() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		print("TerrainLoader._attach_camps: no Terrain node")
		return
	_remove_existing_camps()
	var cfg := _terrain_config()
	if not cfg.generate_camps:
		print("TerrainLoader._attach_camps: generate_camps disabled in config")
		return
	var all_roads: Array = _osm_vectors.get("roads", []) as Array
	# Core annular streets only — Gate Road / airport / service spurs seed no camps.
	var roads: Array = BrcCampGenerator.filter_camp_streets(all_roads)
	if BrcCampGenerator.count_road_points(roads) < BrcCampGenerator.MIN_ROAD_SEGMENTS:
		roads = all_roads
	var road_pts := BrcCampGenerator.count_road_points(roads)
	print("TerrainLoader._attach_camps: roads=%d city_streets=%d road_pts=%d (need>=%d)" % [
		all_roads.size(), roads.size(), road_pts, BrcCampGenerator.MIN_ROAD_SEGMENTS])
	if road_pts < BrcCampGenerator.MIN_ROAD_SEGMENTS:
		print("TerrainLoader._attach_camps: not enough road points — skipping auto-generate")
		print("  Tip: open camp scatter UI (C key) and use BRC Auto or draw a selection")
		return
	if _footing_grid.is_empty():
		_footing_grid = _compose_terrain_grids()["footing"]
	# Prefer the hi-res detail grid for camp height inside the 3 km patch.
	var height_grid := _footing_grid
	var height_res := MESH_RES
	var height_extent := _built_extent
	if not _detail_surface_grid.is_empty() and _detail_elev_cols > 1:
		height_grid = _detail_surface_grid
		height_res = _detail_elev_cols
		height_extent = _detail_extent_m()
	var seed := _camp_seed()
	# Scatter only where OSM road/building data was actually fetched — using
	# _detail_half_extent alone (which the player can now size independently of
	# _osm_half_extent) either wastes the outer ring on guaranteed-empty cells or,
	# if OSM's extent is the smaller of the two, silently clips real roads out of
	# the mask, both of which read as camps not matching the real city layout.
	var camp_area_half := minf(_detail_half_extent, _osm_half_extent)
	# Clip to the city-street hull so camps stop at the outer ring (not Gate /
	# airport roads that survive inside the OSM fetch radius).
	var city_clip := BrcCampGenerator.compute_city_area(roads)
	print("TerrainLoader._attach_camps: generating (seed=%d, height_grid_size=%d, extent=%.0f, area_half=%.0f, clip_pts=%d)" % [
		seed, height_grid.size(), height_extent, camp_area_half, city_clip.size()])
	var node := BrcCampGenerator.build_camps_node(
		roads, _buildings_data, height_grid, height_res, height_extent,
		_built_center_elev, camp_area_half, seed, _load_camp_profiles(), _main,
		city_clip, BrcCampGenerator.FILL_PROBABILITY, 0.0, 0.9, 1.18, 1.0,
		cfg.camp_exclusion_r)
	if node == null:
		print("TerrainLoader._attach_camps: build_camps_node returned null")
		return
	terrain.add_child(node)
	_camps_root = node
	_apply_cached_geometry_visibility()
	var stats: Dictionary = node.get_meta("stats", {})
	print("TerrainLoader._attach_camps: done — %s" % str(stats))


## Deterministic per-site seed so a reload/resume rebuilds the same camp layout.
func _camp_seed() -> int:
	return hash("%.5f,%.5f" % [_lat, _lon])


## camp_profile_*.tres keyed by class_id; reused for component sizes + GLB art.
func _load_camp_profiles() -> Dictionary:
	if not _camp_profiles.is_empty():
		return _camp_profiles
	var paths := [
		"res://vegetation/camp_profile_shade_structure.tres",
		"res://vegetation/camp_profile_rv.tres",
		"res://vegetation/camp_profile_car.tres",
		"res://vegetation/camp_profile_popup_tent.tres",
		"res://vegetation/camp_profile_camping_tent.tres",
	]
	for p in paths:
		var prof := load(p) as CampScatterProfile
		if prof != null:
			_camp_profiles[String(prof.class_id)] = prof
	return _camp_profiles


func set_camp_exclusion_r(metres: float) -> void:
	_save_terrain_config_value("camp_exclusion_r", metres)


func set_generate_camps(on: bool) -> void:
	_save_terrain_config_value("generate_camps", on)
	if not _built:
		return
	if on:
		_notify_options_status("Generating camps …", "busy")
		_attach_camps()
		_notify_options_status("Camps generated", "ok")
	else:
		_remove_existing_camps()
		_notify_options_status("Camps removed", "ok")


## Return the OSM road array for the current map (for the camp scatter UI).
func get_osm_roads() -> Array:
	return _osm_vectors.get("roads", []) as Array


## Loaded building footprints: [{idx, points (world XZ metres), height_m,
## tags, roof}]. Mirrors get_osm_roads for consumers that need real geometry
## rather than the idx/tag summaries (NPC navigation obstacle stamping).
func get_osm_buildings() -> Array:
	return _buildings_data


## Still-water bodies as world-XZ polygons (ponds/lakes — NOT rivers, which
## are fordable). Used as navigation obstacles.
func get_still_water_polygons() -> Array:
	var out: Array = []
	for item in _water_data:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		# WaterBuilder._is_flowing is private; FLOWING_KINDS is the public form.
		if str(d.get("kind", "")) in WaterBuilder.FLOWING_KINDS:
			continue
		var pts: Variant = d.get("points", PackedVector2Array())
		if pts is PackedVector2Array and (pts as PackedVector2Array).size() >= 3:
			out.append(pts)
	return out


## Convex hull of core city streets — the camp scatter UI's "BRC Auto" area.
## For BRC this is an annular-sector outline (not a radial-percentile hull).
func get_brc_city_area() -> PackedVector2Array:
	var roads := get_osm_roads()
	if roads.is_empty():
		return PackedVector2Array()
	return BrcCampGenerator.compute_city_area(roads)


## Generate camps within the given local-metre polygon with custom parameters.
## Returns number of structures placed (0 on failure).
## Replaces any existing Camps node.
func generate_camps_in_polygon(poly: PackedVector2Array, params: Dictionary) -> int:
	if not _built or _main == null:
		return 0
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return 0
	_remove_existing_camps()

	var all_roads: Array = _osm_vectors.get("roads", []) as Array
	var roads: Array = BrcCampGenerator.filter_camp_streets(all_roads)
	if BrcCampGenerator.count_road_points(roads) < 40:
		roads = all_roads
	var density := float(params.get("density", BrcCampGenerator.FILL_PROBABILITY))
	var mix_bias := float(params.get("mix_bias", 0.0))
	var scale_min := float(params.get("scale_min", 0.9))
	var scale_max := float(params.get("scale_max", 1.18))
	var light_density := float(params.get("light_density", 1.0))
	var use_seed := int(params.get("seed", _camp_seed()))
	var excl_r := float(params.get("exclusion_radius_m", _terrain_config().camp_exclusion_r))
	var plot_depth := float(params.get("plot_depth_m", BrcCampGenerator.PLOT_DEPTH_M))
	var scatter_step := float(params.get("scatter_step_m", BrcCampGenerator.SCATTER_STEP_M))
	var light_lod := float(params.get("light_lod_m", -1.0))
	var max_lights := int(params.get("max_pool_lights", -1))

	if _footing_grid.is_empty():
		_footing_grid = _compose_terrain_grids()["footing"]
	var height_grid := _footing_grid
	var height_res := MESH_RES
	var height_extent := _built_extent
	if not _detail_surface_grid.is_empty() and _detail_elev_cols > 1:
		height_grid = _detail_surface_grid
		height_res = _detail_elev_cols
		height_extent = _detail_extent_m()

	var node := BrcCampGenerator.build_camps_node(
		roads, _buildings_data, height_grid, height_res, height_extent,
		_built_center_elev, minf(_detail_half_extent, _osm_half_extent), use_seed,
		_load_camp_profiles(), _main,
		poly, density, mix_bias, scale_min, scale_max, light_density, excl_r,
		plot_depth, scatter_step, light_lod, max_lights)
	if node == null:
		return 0
	terrain.add_child(node)
	_camps_root = node
	_apply_cached_geometry_visibility()
	var stats: Dictionary = node.get_meta("stats", {})
	return int(stats.get("structures", 0))


## Toggle the camp scatter UI panel (called from terrain_options "Edit camps" button).
func toggle_camp_scatter_ui() -> void:
	if _camp_scatter_ui != null:
		_camp_scatter_ui.toggle_mode()


## Remove the current camp city node.
func clear_camps() -> void:
	_remove_existing_camps()


## Free every camp node under Terrain, not just the one named exactly "Camps".
## Because queue_free() is deferred, regenerating before the old node is gone
## makes Godot rename the new node "Camps2"/"Camps3"…; a name-only lookup then
## leaves those strays behind (the "cached camps persist after Clear" bug). We
## detach immediately (remove_child frees the name) and also drop the tracked
## reference, so a regen right after never collides and Clear removes everything.
func _remove_existing_camps() -> void:
	var terrain := _main.get_node_or_null("Terrain") if _main != null else null
	if terrain != null:
		var doomed: Array = []
		for child in terrain.get_children():
			if String(child.name).begins_with("Camps"):
				doomed.append(child)
		for child in doomed:
			terrain.remove_child(child)
			child.queue_free()
	if is_instance_valid(_camps_root):
		var parent := _camps_root.get_parent()
		if parent != null:
			parent.remove_child(_camps_root)
		_camps_root.queue_free()
	_camps_root = null


func _apply_building_textures() -> void:
	var roof_mat := _make_world_roof_material()
	if _buildings_root != null:
		var mi := _buildings_root.get_node_or_null("BuildingMeshes") as MeshInstance3D
		if mi != null:
			mi.material_override = null
			mi.set_surface_override_material(0, BuildingBuilder.make_wall_material())
			if mi.mesh != null and mi.mesh.get_surface_count() > 1:
				mi.set_surface_override_material(1, roof_mat)
				var uv2_ok := mi.mesh.surface_get_arrays(1)[Mesh.ARRAY_TEX_UV2] != null
				print("TerrainLoader: roof ortho=%s (hyper=%s detail=%s uv2=%s)" % [
					str((roof_mat as ShaderMaterial).get_shader_parameter("use_ortho")),
					str(_hyper_drape != null), str(_detail_drape != null), str(uv2_ok)])
	# Styled buildings are separate MeshInstance3D children; their roofs share the
	# same world material so a styled house still matches its merged neighbours.
	if _custom_buildings_root != null and is_instance_valid(_custom_buildings_root):
		for child in _custom_buildings_root.get_children():
			var cmi := child as MeshInstance3D
			if cmi == null or cmi.mesh == null:
				continue
			if cmi.mesh.get_surface_count() > 1:
				cmi.set_surface_override_material(1, roof_mat)


## Roof material for buildings placed in WORLD coordinates: ortho projection from
## the hyper patch when it has arrived, else the 3 km detail drape (UV2 remapped
## by the extent ratio), else plain procedural. The modal's studio preview keeps
## BuildingBuilder.make_roof_material() — studio coordinates are not world coords.
func _make_world_roof_material() -> Material:
	var mat := BuildingBuilder.make_roof_material()
	var ortho: Texture2D = _hyper_drape if _hyper_drape != null else _detail_drape
	if ortho == null or not (mat is ShaderMaterial):
		return mat
	var sm := mat as ShaderMaterial
	sm.set_shader_parameter("use_ortho", true)
	sm.set_shader_parameter("ortho_tex", ortho)
	var scale := 1.0
	var ortho_half := _hyper_half_extent()
	if _hyper_drape == null:
		scale = BuildingBuilder.ORTHO_HALF_EXTENT_M / _detail_half_extent
		ortho_half = _detail_half_extent
	else:
		ortho_half = _hyper_half_extent()
	sm.set_shader_parameter("ortho_uv_scale", scale)
	# Ortho texture covers this half-extent; UV2 is ORTHO_HALF-normalized then
	# scaled — Mercator-correct samples into that coverage square.
	var bb := GeoMath.bbox_for(_lat, _lon, ortho_half)
	sm.set_shader_parameter("ortho_bbox", TerrainBuilder.bbox_to_shader_vec4(bb))
	sm.set_shader_parameter("correct_ortho_mercator", true)
	return mat


## ---------------------------------------------------------------------------
## Build
## ---------------------------------------------------------------------------

func _build_terrain() -> void:
	if _built:
		return
	_built = true

	var grid := TerrainBuilder.resample(_elev_grid, _elev_cols, _elev_rows, MESH_RES)
	var center_elev := TerrainBuilder.mean_elevation(grid)
	var extent := _half_extent * 2.0
	_base_dem_grid = grid
	_built_center_elev = center_elev
	_built_extent = extent
	_terrain_edits = TerrainEditGrid.create_empty(MESH_RES)
	_terrain_edits.load_for_map(_lat, _lon)
	_load_edit_tiles()
	_load_user_water()
	_load_part_inventory()
	_load_chore_ledger()
	_load_printed_objects()
	_load_earthworks()
	_refresh_water_data()

	var grids := _compose_terrain_grids(false)
	_built_grid = grids["built"]
	_built_collision_grid = grids.get("collision_coarse", _built_grid)
	_footing_grid = grids["footing"]
	_detail_surface_grid = grids["detail_surface"]
	_detail_collision_active = not _detail_surface_grid.is_empty()

	if not _detail_surface_grid.is_empty():
		_spawn_ground_y = TerrainBuilder.height_at_world_xz_rect(
			_detail_surface_grid, _detail_elev_cols, _detail_elev_rows,
			_detail_extent_m(), center_elev, 0.0, 0.0)
	else:
		_spawn_ground_y = TerrainBuilder.height_at_world_xz(
			_built_grid, MESH_RES, extent, center_elev, 0.0, 0.0)

	var terrain := TerrainBuilder.build_terrain_node(
		_built_grid, MESH_RES, extent, center_elev, _drape, null, _detail_extent_m())
	terrain.name = "Terrain"
	if _main != null:
		_main.add_child(terrain)

	if not _detail_surface_grid.is_empty():
		var mesh_grid := _detail_surface_grid
		var mesh_res := _detail_elev_cols
		TerrainBuilder.upsert_detail_patch(
			terrain, mesh_grid, mesh_res, _detail_extent_m(), center_elev,
			_drape, null, extent, _seam_feather_m)
	if _built_collision_grid.size() == _built_grid.size():
		TerrainBuilder.update_terrain_collision(
			terrain, _built_collision_grid, MESH_RES, extent, center_elev)
	_stamp_drape_mercator_bboxes(terrain)
	_migrate_legacy_edits_to_tiles()
	_ensure_height_field(terrain)
	# Saved edits need the DetailGround sunk beneath their tiles from frame one.
	_refresh_detail_sink()

	# Temp floor stays until _finalize_spawn_actors seats the player on composed ground.
	_setup_terrain_edit_ui()
	_setup_terrain_options_ui()
	_setup_vegetation()
	_setup_placed_props()
	_setup_auto_vegetation()
	_load_progress_mark_done("walkable")
	if _load_overlay != null:
		_load_overlay.enter_compact_mode()
	_load_hint = ""
	_update_load_ui()
	var lo := INF
	var hi := -INF
	for v in grid:
		if not is_nan(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	var ground := terrain.get_node_or_null("Ground") as MeshInstance3D
	var aabb := ground.get_aabb() if ground != null else AABB()
	print("TerrainLoader: built terrain at %.4f,%.4f (%.0f km square, drape=%s) elev %.0f..%.0f m, aabb size=%s, spawn ground y=%.1f" % [
		_lat, _lon, extent / 1000.0, "yes" if _drape != null else "no", lo, hi, str(aabb.size), _spawn_ground_y])


## Legacy entry for in-game refresh paths that still gate on elev+img flags.
func _try_build() -> void:
	if _built or not _elev_done or not _img_done:
		return
	_build_terrain()


func _reseat_player() -> void:
	if _main == null:
		return
	var player := _main.get_node_or_null("Player")
	if player == null:
		return
	var spawn := Vector3(0.0, _spawn_ground_y + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M, 0.0)
	player.global_position = spawn
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO
	if "player_spawn_position" in _main:
		_main.player_spawn_position = spawn
	if "fall_start_height" in player:
		player.fall_start_height = spawn.y
		player.highest_point_during_fall = spawn.y


## Re-seat player + explore drone once the final hi-res footing is in place.
func _finalize_spawn_actors() -> void:
	if _main == null:
		return
	_remove_temp_floor()
	if not _from_resume:
		_reseat_player()
	_relocate_player_off_buildings()
	_sync_actors_to_ground(true)
	var player := _main.get_node_or_null("Player")
	if player != null:
		_spawn_explore_drone(player.global_position)
	# Terrain colliders (detail HeightMapShape3D + edit-tile shapes) may not be
	# registered with the physics server in this frame; the height-math seat above
	# is correct but the CharacterBody3D can otherwise fall onto the lower coarse
	# collider before the real surface exists. Wait for the physics server, then
	# reseat on the true topmost surface via raycast.
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not _from_resume:
		_raycast_reseat_player()


## Lift the player to just above the true collision surface (topmost raycast hit),
## guarding against props/buildings by ignoring hits far above the DEM footing.
func _raycast_reseat_player() -> void:
	if _main == null:
		return
	var player := _main.get_node_or_null("Player") as CharacterBody3D
	if player == null:
		return
	var pos := player.global_position
	var footing := _ground_height_at(pos.x, pos.z)
	var ry := _raycast_ground_y(pos.x, pos.z)
	var surface := footing
	# Prefer the raycast when it agrees with the DEM footing to within a few
	# metres (a prop/building hit would sit much higher — fall back to footing).
	if is_finite(ry) and ry >= footing - 0.5 and ry <= footing + 6.0:
		surface = maxf(footing, ry)
	var target_y := surface + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M
	if absf(pos.y - target_y) < 0.05:
		return
	pos.y = target_y
	player.global_position = pos
	player.velocity = Vector3.ZERO
	if "fall_start_height" in player:
		player.fall_start_height = pos.y
		player.highest_point_during_fall = pos.y
	if "void_reference_y" in player:
		player.void_reference_y = pos.y
	_raycast_reseat_drone()


## Lift the explore drone onto the true collision surface (same physics-frame race
## as the player — it is seated before the terrain colliders register).
func _raycast_reseat_drone() -> void:
	if _main == null:
		return
	var drone := _main.get_node_or_null("FPVDrone") as Node3D
	if drone == null:
		return
	var pos := drone.global_position
	var footing := _ground_height_at(pos.x, pos.z)
	var ry := _raycast_ground_y(pos.x, pos.z)
	var surface := footing
	if is_finite(ry) and ry >= footing - 0.5 and ry <= footing + 6.0:
		surface = maxf(footing, ry)
	var target_y := surface + DRONE_GROUND_CLEARANCE_M
	if pos.y >= target_y - 0.05:
		return
	pos.y = target_y
	drone.global_position = pos
	if "drone_spawn_position" in drone:
		drone.drone_spawn_position = pos


## If the spawn XZ sits inside an OSM building footprint, move the player to the
## nearest open ground. No-op when the centre is already clear or when there are
## no buildings (also skipped entirely on save resume via _finalize_spawn_actors).
func _relocate_player_off_buildings() -> void:
	if _buildings_data.is_empty():
		return
	var player := _main.get_node_or_null("Player") as Node3D
	if player == null:
		return
	var origin := Vector2(player.global_position.x, player.global_position.z)
	if not _xz_inside_building(origin.x, origin.y):
		return
	var clear: Variant = _search_clear_xz(origin)
	if clear == null:
		# Fully built-up within the search radius — leave the player where it was.
		return
	var target: Vector2 = clear
	var pos := player.global_position
	pos.x = target.x
	pos.z = target.y
	player.global_position = pos
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO
	if "player_spawn_position" in _main:
		_main.player_spawn_position = pos


func _xz_inside_building(x: float, z: float) -> bool:
	return bool(BuildingPicker.pick_at_xz(_buildings_data, x, z).get("valid", false))


## Widening-ring search for the nearest XZ not inside any building footprint.
## Returns a Vector2 (with a small outward margin) or null if none found.
func _search_clear_xz(origin: Vector2) -> Variant:
	var radius := SPAWN_CLEAR_RING_STEP_M
	while radius <= SPAWN_CLEAR_MAX_RADIUS_M:
		for i in SPAWN_CLEAR_ANGLE_STEPS:
			var ang := TAU * float(i) / float(SPAWN_CLEAR_ANGLE_STEPS)
			var dir := Vector2(cos(ang), sin(ang))
			var cand := origin + dir * radius
			if not _xz_inside_building(cand.x, cand.y):
				# Push a little further along the same bearing so we clear the wall.
				var pushed := cand + dir * SPAWN_CLEAR_MARGIN_M
				if not _xz_inside_building(pushed.x, pushed.y):
					return pushed
				return cand
		radius += SPAWN_CLEAR_RING_STEP_M
	return null


func _terrain_height_at(x: float, z: float) -> float:
	return _ground_height_at(x, z)


## Public footing sampler for PlacedPropService / TerrainSurfaceQuery.
func ground_height_at(x: float, z: float) -> float:
	return _ground_height_at(x, z)


func has_detail_footing() -> bool:
	return not _detail_footing_grid().is_empty()


func _detail_footing_grid() -> PackedFloat32Array:
	if not _detail_surface_grid.is_empty():
		return _detail_surface_grid
	if _detail_elev_done and not _detail_elev_grid.is_empty():
		_detail_surface_grid = _compose_detail_surface(true)
		return _detail_surface_grid
	return PackedFloat32Array()


func _ground_height_at(x: float, z: float) -> float:
	var detail := _detail_footing_grid()
	var in_detail := absf(x) <= _detail_half_extent and absf(z) <= _detail_half_extent
	var fallback := PackedFloat32Array()
	if in_detail and detail.is_empty() and _detail_elev_resolved:
		fallback = _compose_base_footing_grid(true)
	var y := TerrainBuilder.sample_footing_height(
		x, z, _built_grid, MESH_RES, _built_extent, _built_center_elev,
		detail, _detail_elev_cols, _detail_elev_rows, _detail_extent_m(),
		fallback)
	if _built_grid.is_empty() and detail.is_empty():
		return _spawn_ground_y + _edit_tile_delta(x, z)
	# High-resolution edit layer sits on top of the composed DEM footing (this is
	# the EXACT edited surface at 1.5 m resolution — the grids stay edit-free).
	return y + _edit_tile_delta(x, z)


func _edit_tile_delta(x: float, z: float) -> float:
	return 0.0 if _edit_tiles == null else _edit_tiles.sample_delta(x, z)


## Public: net player edit (m) at a world XZ — the dock's live cursor readout.
func terrain_edit_delta_at(x: float, z: float) -> float:
	return _edit_tile_delta(x, z)


## Cut/fill volume estimate for the whole edit layer (m³) for the dock readout.
func edit_volume_estimate() -> Dictionary:
	if _edit_tiles == null:
		return {"cut_m3": 0.0, "fill_m3": 0.0, "net_m3": 0.0}
	return _edit_tiles.volume_estimate()


## True surface Y at (x, z) from a downward physics raycast against the live
## terrain collision — the topmost hit, so it never reports the lower (sunk)
## coarse collider that underlies the hi-res detail patch. Returns NAN when the
## physics space isn't ready or nothing is hit.
func _raycast_ground_y(x: float, z: float) -> float:
	if _main == null or not _main.is_inside_tree():
		return NAN
	var main3d := _main as Node3D
	if main3d == null:
		return NAN
	var world: World3D = main3d.get_world_3d()
	if world == null:
		return NAN
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return NAN
	var top := _built_center_elev + 4000.0
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(x, top, z), Vector3(x, top - 9000.0, z))
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return NAN
	return (hit.get("position") as Vector3).y


# ---------------------------------------------------------------------------
# High-resolution edit layer (TerrainEditTiles baked into the detail surface)
# ---------------------------------------------------------------------------

func _edit_tiles_path() -> String:
	return "user://maps/terrain_tiles_%s_%s.bin" % [
		TerrainEditGrid._coord_token(_lat), TerrainEditGrid._coord_token(_lon)]


func _load_edit_tiles() -> void:
	_edit_tiles = TerrainEditTiles.new()
	var path := _edit_tiles_path()
	if FileAccess.file_exists(path):
		_edit_tiles.load_from_file(path)


## One-time migration of the retired systems (coarse/detail delta grids +
## earthworks meshes) into the unified tile layer, then clear + persist the old
## data so nothing is applied twice. Runs during _build_terrain after the base
## detail surface is composed (edit-free) and before the height field is created.
## Idempotent: it clears the legacy stores after baking, so a second pass finds
## nothing to migrate.
func _migrate_legacy_edits_to_tiles() -> void:
	if _edit_tiles == null:
		return
	var migrated := false
	# 1) Legacy detail_delta grid (hi-res centre edits).
	if _terrain_edits != null and _terrain_edits.has_detail_edits():
		_edit_tiles.bake_delta_grid(_terrain_edits.detail_delta,
			_terrain_edits.detail_res, _terrain_edits.detail_extent_m)
		migrated = true
	# 2) Legacy coarse delta grid.
	if _terrain_edits != null and not _terrain_edits.delta.is_empty():
		for v in _terrain_edits.delta:
			if absf(v) > 1e-4:
				_edit_tiles.bake_delta_grid(_terrain_edits.delta, MESH_RES, _built_extent)
				migrated = true
				break
	# 3) Earthworks (raise / cut) meshes → delta over their footprint.
	for rec_v in _earthworks:
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var pts: PackedVector2Array = (rec as Dictionary).get("points", PackedVector2Array())
		if pts.size() < 3:
			continue
		var kind := str((rec as Dictionary).get("kind", ""))
		var fn := func(x: float, z: float) -> float:
			var base := _height_field_base(x, z)
			if kind == "raise":
				var hy := EarthworksBuilder.height_at_raise(rec, x, z)
				return (hy - base) if not is_nan(hy) else 0.0
			elif kind == "cut":
				var fy := EarthworksBuilder.height_at_cut(rec, x, z)
				return (fy - base) if not is_nan(fy) else 0.0
			return 0.0
		_edit_tiles.bake_delta_fn(_poly_bounds(pts), fn)
		migrated = true
	if not migrated:
		return
	if _terrain_edits != null:
		_terrain_edits.detail_delta = PackedFloat32Array()
		if not _terrain_edits.delta.is_empty():
			_terrain_edits.delta.fill(0.0)
		_terrain_edits.save(_lat, _lon)
	if not _earthworks.is_empty():
		_earthworks.clear()
		_save_earthworks()
	_save_edit_tiles()
	print("TerrainLoader: migrated legacy terrain edits into %d tiles" % _edit_tiles.active_tiles().size())


func _poly_bounds(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var r := Rect2(poly[0], Vector2.ZERO)
	for i in range(1, poly.size()):
		r = r.expand(poly[i])
	return r


func _save_edit_tiles() -> void:
	if _edit_tiles == null:
		return
	_edit_tiles.prune_flat_tiles()
	_edit_tiles.save_to_file(_edit_tiles_path())


## Base (pre-edit-layer) AMSL height the tiles layer over — the composed detail
## DEM footing WITHOUT earthworks or tiles (so no double counting).
func _height_field_base(x: float, z: float) -> float:
	return _dem_height_without_earthworks(x, z)


func _detail_ground_material(terrain: Node3D) -> Material:
	if terrain == null:
		return null
	var dg := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	if dg != null and dg.material_override != null:
		return dg.material_override
	var g := terrain.get_node_or_null("Ground") as MeshInstance3D
	return g.material_override if g != null else null


## Create/refresh the HeightField node under Terrain and re-layer all edit tiles
## onto the current composed base surface. base_fn returns WORLD Y (footing math
## already mean-centres), so the node is configured without a second centring.
func _ensure_height_field(terrain: Node3D) -> void:
	if terrain == null:
		return
	if _edit_tiles == null:
		_edit_tiles = TerrainEditTiles.new()
	var hf := terrain.get_node_or_null("HeightField") as TerrainHeightField
	if hf == null:
		hf = TerrainHeightField.new()
		hf.name = "HeightField"
		terrain.add_child(hf)
	_height_field = hf
	hf.configure(_edit_tiles, Callable(self, "_height_field_base"),
		_detail_extent_m(), _detail_ground_material(terrain))
	hf.rebuild_all_now()


## How far the DetailGround surface drops beneath the interior of active edit
## tiles. Deep on purpose: the coarse grid (~12–47 m/vertex) linearly chords
## between samples, so a shallow graded sink could still cut above a hi-res pond
## floor near its banks. A deep drop makes that geometrically impossible, and
## the chasm is always roofed by the opaque tile meshes.
const TILE_SINK_HEADROOM_M := 60.0


## Signature of the active edited-tile set — the sink only depends on WHICH
## tiles exist, so an unchanged set skips the detail-patch rebuild.
func _sink_signature() -> String:
	if _edit_tiles == null:
		return ""
	var keys: Array = []
	for key in _edit_tiles.active_tiles():
		var k: Vector2i = key
		if _edit_tiles.tile_has_edits(k):
			keys.append(k)
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append(str(k))
	return ";".join(parts)


## The grid the DetailGround mesh + DetailCollision are actually built from:
## the edit-free detail surface, pushed DOWN beneath active edit tiles so the
## hi-res tile meshes/colliders own those areas (cuts stay visible + walkable).
## Only samples strictly INTERIOR to the tile union get the full headroom sink —
## samples on the union's boundary ring stay at (or follow the cut just below)
## the base surface, so no depression trench leaks outside the tile meshes.
func _detail_mesh_grid_with_sink(grid: PackedFloat32Array, res: int) -> PackedFloat32Array:
	if _edit_tiles == null or _edit_tiles.is_empty():
		return grid
	var rects: Array = []
	for key in _edit_tiles.active_tiles():
		var k: Vector2i = key
		if _edit_tiles.tile_has_edits(k):
			rects.append(_edit_tiles.tile_world_rect(k))
	if rects.is_empty():
		return grid
	var out := grid.duplicate()
	var ext := _detail_extent_m()
	var half := ext * 0.5
	var cell := ext / float(maxi(res - 1, 1))
	for r in res:
		var z := float(r) / float(maxi(res - 1, 1)) * ext - half
		for c in res:
			var x := float(c) / float(maxi(res - 1, 1)) * ext - half
			var p := Vector2(x, z)
			if not _in_rect_union(rects, p):
				continue
			# Boundary-ring samples follow the local cut (delta→0 at the union
			# edge, so the surface stays continuous with untouched terrain);
			# fully interior samples (all 8 neighbours covered) drop the whole
			# headroom so a coarse chord can never bridge above a hi-res cut.
			var sink := maxf(0.0, -_edit_tiles.sample_delta(x, z))
			var interior := true
			for oz in [-1, 0, 1]:
				for ox in [-1, 0, 1]:
					if ox == 0 and oz == 0:
						continue
					if not _in_rect_union(rects, p + Vector2(float(ox) * cell, float(oz) * cell)):
						interior = false
			if interior:
				sink = TILE_SINK_HEADROOM_M
			if sink > 0.0:
				out[r * res + c] -= sink
	return out


static func _in_rect_union(rects: Array, p: Vector2) -> bool:
	for rect in rects:
		if (rect as Rect2).has_point(p):
			return true
	return false


## Rebuild the DetailGround mesh + collider when the set of sunk tiles changed —
## called after each committed edit / undo / clear.
func _refresh_detail_sink(force: bool = false) -> void:
	var sig := _sink_signature()
	if not force and sig == _detail_sink_sig:
		return
	_detail_sink_sig = sig
	var terrain := _main.get_node_or_null("Terrain") as Node3D if _main != null else null
	if terrain != null and not _detail_surface_grid.is_empty():
		_rebuild_detail_patch(terrain)
		# upsert_detail_patch made a fresh drape material — tiles must follow it.
		if _height_field != null and is_instance_valid(_height_field):
			_height_field.set_material(_detail_ground_material(terrain))


## After a committed sculpt edit: if the ground under the player/drone was
## RAISED above them (buried), lift them onto the new surface. Lowered ground is
## left to gravity — the actor just falls/steps down naturally.
func _reseat_actors_after_edit() -> void:
	if _main == null:
		return
	var player := _main.get_node_or_null("Player") as CharacterBody3D
	if player != null:
		var pos := player.global_position
		var gy := _ground_height_at(pos.x, pos.z)
		if pos.y < gy + 0.1:
			pos.y = gy + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M
			player.global_position = pos
			player.velocity = Vector3.ZERO
			if "fall_start_height" in player:
				player.fall_start_height = pos.y
				player.highest_point_during_fall = pos.y
			if "void_reference_y" in player:
				player.void_reference_y = pos.y
	var drone := _main.get_node_or_null("FPVDrone") as FPVDrone
	if drone != null:
		var dpos := drone.global_position
		var dgy := _ground_height_at(dpos.x, dpos.z)
		if dpos.y < dgy + 0.25:
			dpos.y = dgy + DRONE_GROUND_CLEARANCE_M
			drone.global_position = dpos


func _sync_actors_to_ground(force: bool = false) -> void:
	if _main == null:
		return
	var player := _main.get_node_or_null("Player") as CharacterBody3D
	if player != null:
		var pos := player.global_position
		var gy := _ground_height_at(pos.x, pos.z)
		var target_y := gy + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M
		var threshold := 0.05 if force else 0.35
		if force or absf(pos.y - target_y) > threshold:
			pos.y = target_y
			player.global_position = pos
			player.velocity = Vector3.ZERO
			if "fall_start_height" in player:
				player.fall_start_height = pos.y
				player.highest_point_during_fall = pos.y
			if "void_reference_y" in player:
				player.void_reference_y = pos.y
	var drone := _main.get_node_or_null("FPVDrone") as FPVDrone
	if drone != null:
		var dpos := drone.global_position
		var dgy := _ground_height_at(dpos.x, dpos.z)
		var dtarget := dgy + DRONE_GROUND_CLEARANCE_M
		if force or absf(dpos.y - dtarget) > (0.05 if force else 0.35):
			dpos.y = dtarget
			drone.global_position = dpos
			drone.drone_spawn_position = dpos


func _spawn_explore_drone(near_player: Vector3) -> void:
	if _main == null or _from_resume:
		return
	var drone := _main.get_node_or_null("FPVDrone") as FPVDrone
	if drone == null:
		drone = FPV_DRONE_SCENE.instantiate() as FPVDrone
		if drone == null:
			return
		drone.name = "FPVDrone"
		_main.add_child(drone)
	_explore_drone = drone
	var pos := Vector3(
		near_player.x + DRONE_SPAWN_OFFSET.x,
		_ground_height_at(near_player.x + DRONE_SPAWN_OFFSET.x, near_player.z + DRONE_SPAWN_OFFSET.z) + DRONE_GROUND_CLEARANCE_M,
		near_player.z + DRONE_SPAWN_OFFSET.z,
	)
	drone.global_position = pos
	drone.drone_spawn_position = pos
	drone.rotation = Vector3.ZERO
	print("TerrainLoader: explore FPV drone at %s (%.1f m above ground)" % [str(pos), DRONE_GROUND_CLEARANCE_M])


## Request the hi-res detail DEM. OpenTopography (30 m / 10 m, key) returns a
## single 512² AAIGrid; without a key we still fetch via Open-Meteo, which the
## ElevationService caps to OPENMETEO_DETAIL_N (64²) — the centre ~3 km grid
## (~47 m spacing) is far finer than the ~1.9 km base grid, at a bounded ~40-
## request cost. Either way the DEM caches, so a site is fetched once and every
## reload is instant.
func _request_detail_dem(es: Object, force: bool = false) -> void:
	es.request_elevation(_lat, _lon, _detail_half_extent,
		ElevationService.DETAIL_GRID_N, "detail", force)


## Mark the detail-DEM stage resolved without fetching (no key / no service).
func _resolve_detail_dem_skipped() -> void:
	_skip_detail_dem()
	if _load_sequence_active:
		return
	_queue_auto_veg_generate(false)
	_check_load_complete()


func _terrain_config() -> Dictionary:
	var flatten_roads := false
	var flatten_landuse := false
	var show_buildings := true
	var show_water := true
	var show_auto_vegetation := true
	var generate_camps := true
	var cache_enabled := TerrainCacheSettings.cache_enabled()
	var camp_exclusion_r := 804.672   # 0.5 miles default
	if FileAccess.file_exists(CONFIG_PATH):
		var cfg := ConfigFile.new()
		if cfg.load(CONFIG_PATH) == OK:
			flatten_roads = bool(cfg.get_value("terrain", "flatten_roads", false))
			flatten_landuse = bool(cfg.get_value("terrain", "flatten_landuse", false))
			show_buildings = bool(cfg.get_value("terrain", "show_buildings", true))
			show_water = bool(cfg.get_value("terrain", "show_water", true))
			show_auto_vegetation = bool(cfg.get_value("terrain", "show_auto_vegetation", true))
			generate_camps = bool(cfg.get_value("terrain", "generate_camps", true))
			cache_enabled = bool(cfg.get_value("terrain", "cache_enabled", true))
			camp_exclusion_r = float(cfg.get_value("terrain", "camp_exclusion_r", 804.672))
	return {
		"flatten_roads": flatten_roads,
		"flatten_landuse": flatten_landuse,
		"show_buildings": show_buildings,
		"show_water": show_water,
		"show_auto_vegetation": show_auto_vegetation,
		"generate_camps": generate_camps,
		"cache_enabled": cache_enabled,
		"camp_exclusion_r": camp_exclusion_r,
	}


func _save_terrain_config_value(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(CONFIG_PATH):
		cfg.load(CONFIG_PATH)
	cfg.set_value("terrain", key, value)
	cfg.save(CONFIG_PATH)


func get_terrain_options() -> Dictionary:
	var opts := _terrain_config()
	opts["half_extent_m"] = _half_extent
	opts["detail_half_extent_m"] = _detail_half_extent
	opts["osm_half_extent_m"] = _osm_half_extent
	opts["osm_offset_east_m"] = _osm_offset_east_m
	opts["osm_offset_north_m"] = _osm_offset_north_m
	# Terrain UI "geometry" toggle — not the map-select cache load flag.
	opts["cached_geometry_visible"] = _cached_geometry_visible
	opts["load_from_cache"] = not _force_refetch
	return opts


func apply_terrain_extents(world_half_m: float, detail_half_m: float, osm_half_m: float) -> void:
	if world_half_m > 0.0:
		_half_extent = world_half_m
	if detail_half_m > 0.0:
		_detail_half_extent = detail_half_m
	if osm_half_m > 0.0:
		_osm_half_extent = osm_half_m
	_save_terrain_config_value("world_half_extent_m", _half_extent)
	_save_terrain_config_value("detail_half_extent_m", _detail_half_extent)
	_save_terrain_config_value("osm_half_extent_m", _osm_half_extent)
	TerrainCacheSettings.save_meta_extents(
		_lat, _lon, _half_extent, _detail_half_extent, _osm_half_extent,
		_osm_offset_east_m, _osm_offset_north_m)
	_persist_active_map_definition_extents()
	if not _built:
		return
	if _load_sequence_active:
		_notify_options_status("Still loading — wait for the map to finish", "warn")
		return
	# The terrain mesh's size (_built_extent, set once in _build_terrain()) and
	# MESH_RES are never touched by the in-place refresh paths (reset_site_to_fresh /
	# refresh_all_cached_layers just re-fetch DEM/imagery/OSM data and resample it
	# onto the EXISTING mesh footprint) — so a bigger world/detail/OSM extent never
	# actually became visible, and _attach_camps()/_setup_placed_props() (which only
	# run inside _build_terrain()'s one-shot path) kept using stale height data until
	# the whole map was reloaded from scratch. Route extent changes through a genuine
	# scene reload (same mechanism as picking the map from the map chooser) so
	# _build_terrain() runs fresh and everything derived from it — mesh size, camp
	# placement, placed props — rebuilds consistently the first time.
	var n_edits := TerrainCacheSettings.invalidate_user_vegetation_edits(_lat, _lon)
	_notify_options_status(
		"Extents changed — reloading map to rebuild the terrain (cleared %d user veg file(s)) …" % n_edits,
		"busy")
	var ctx := get_node_or_null("/root/MapContext")
	if ctx == null or get_tree() == null:
		push_warning("TerrainLoader: MapContext unavailable — falling back to in-place refresh (terrain size will not update until the map is fully reloaded)")
		reset_site_to_fresh()
		return
	ctx.set_pending(_lat, _lon, _map_label, _half_extent, false, _detail_half_extent, _osm_half_extent)
	get_tree().change_scene_to_file(MapDefinition.GENERATED_SCENE)


func _persist_active_map_definition_extents() -> void:
	var path := "user://maps/loc_%s_%s.tres" % [
		CoordToken.token(_lat),
		CoordToken.token(_lon),
	]
	if not FileAccess.file_exists(path):
		return
	var md := load(path) as MapDefinition
	if md == null:
		return
	md.half_extent_m = _half_extent
	md.detail_half_extent_m = _detail_half_extent
	md.osm_half_extent_m = _osm_half_extent
	md.osm_offset_east_m = _osm_offset_east_m
	md.osm_offset_north_m = _osm_offset_north_m
	ResourceSaver.save(md, path)


func set_flatten_roads(on: bool) -> void:
	_save_terrain_config_value("flatten_roads", on)
	if _built:
		_notify_options_status("Rebuilding terrain …", "busy")
		_rebuild_heightfield()
		_notify_options_status("Terrain updated", "ok")


func set_flatten_landuse(on: bool) -> void:
	_save_terrain_config_value("flatten_landuse", on)
	if _built:
		_notify_options_status("Rebuilding terrain …", "busy")
		_rebuild_heightfield()
		_notify_options_status("Terrain updated", "ok")


func set_show_buildings(on: bool) -> void:
	_save_terrain_config_value("show_buildings", on)
	if not _built:
		return
	if on:
		_attach_buildings()
	else:
		var terrain := _main.get_node_or_null("Terrain") if _main != null else null
		if terrain != null:
			_clear_building_nodes(terrain)


func set_show_water(on: bool) -> void:
	_save_terrain_config_value("show_water", on)
	if not _built:
		return
	_attach_water()


## Show/hide DEM + OSM world geometry (Ground, buildings, water, camps, veg).
## Does not affect placed props/lights or whether the next load uses disk cache.
func set_cached_geometry_visible(on: bool) -> void:
	_cached_geometry_visible = on
	_apply_cached_geometry_visibility()


func is_cached_geometry_visible() -> bool:
	return _cached_geometry_visible


func _apply_cached_geometry_visibility() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var on := _cached_geometry_visible
	for child_name in ["Ground", "DetailGround", "Buildings", "BuildingsCustom",
			"Water", "Camps", "AutoVegetation", "Vegetation", "SolarArrays"]:
		var n := terrain.get_node_or_null(child_name) as Node3D
		if n != null:
			n.visible = on
	# Named roots may differ slightly — also toggle known loader handles.
	if _buildings_root != null and is_instance_valid(_buildings_root):
		_buildings_root.visible = on
	if _custom_buildings_root != null and is_instance_valid(_custom_buildings_root):
		_custom_buildings_root.visible = on
	if _water_root != null and is_instance_valid(_water_root):
		_water_root.visible = on
	if _camps_root != null and is_instance_valid(_camps_root):
		_camps_root.visible = on


## Delete cached files for this map and re-fetch elevation (base + detail).
func refresh_dem() -> void:
	if not _built:
		return
	if _load_sequence_active:
		_notify_options_status("Still loading — wait for the map to finish", "warn")
		return
	var es := get_node_or_null("/root/ElevationService")
	if es != null and es.has_method("is_openmeteo_daily_exhausted") \
			and es.is_openmeteo_daily_exhausted() and not es.has_opentopo_key():
		_notify_options_status(
			"Open-Meteo daily limit — cannot refresh without OpenTopography key or cached DEM",
			"warn")
		return
	_begin_refresh("dem")
	_begin_dem_refetch(true)
	print("TerrainLoader: refreshing DEM (force re-fetch, keeping cache backup) …")


## Delete cached imagery and re-fetch base + centre drape.
func refresh_imagery() -> void:
	if not _built:
		return
	_begin_refresh("imagery")
	_begin_imagery_refetch(true)
	print("TerrainLoader: refreshing imagery (force re-fetch, keeping cache backup) …")


## Delete cached OSM vectors (buildings, roads, water) and re-fetch.
func refresh_osm_vectors() -> void:
	if not _built:
		return
	_begin_refresh("osm_map")
	var n := TerrainCacheSettings.invalidate_osm_vectors(_lat, _lon)
	_begin_osm_vectors_refetch()
	print("TerrainLoader: refreshing OSM map data (%d cache file(s) cleared) …" % n)


## Delete cached OSM vegetation and re-fetch (regenerates auto-veg when ready).
func refresh_osm_vegetation() -> void:
	if not _built:
		return
	_begin_refresh("osm_veg")
	var n := TerrainCacheSettings.invalidate_osm_vegetation(_lat, _lon)
	_begin_osm_vegetation_refetch()
	print("TerrainLoader: refreshing OSM vegetation (%d cache file(s) cleared) …" % n)


func refresh_all_cached_layers() -> void:
	if not _built:
		return
	if _load_sequence_active:
		_notify_options_status("Still loading — wait for the map to finish", "warn")
		return
	var es := get_node_or_null("/root/ElevationService")
	if es != null and es.has_method("is_openmeteo_daily_exhausted") \
			and es.is_openmeteo_daily_exhausted() and not es.has_opentopo_key():
		_notify_options_status(
			"Open-Meteo daily limit — cannot reload fresh without OpenTopography key",
			"warn")
		return
	_begin_refresh("dem")
	_begin_refresh("imagery")
	_begin_refresh("osm_map")
	_begin_refresh("osm_veg")
	var n := TerrainCacheSettings.invalidate_osm_vectors(_lat, _lon)
	n += TerrainCacheSettings.invalidate_osm_vegetation(_lat, _lon)
	# Invalidate the AI hero cache too so it regenerates from the fresh imagery
	# (only if enabled — otherwise no cost). The post-hyper hook re-requests it.
	if _ai_hero_enabled():
		var ai := get_node_or_null("/root/AiImageryService")
		if ai != null:
			ai.clear_cache(_ai_cache_key())
	_begin_dem_refetch(true)
	_begin_imagery_refetch(true)
	_begin_osm_vectors_refetch()
	_begin_osm_vegetation_refetch()
	print("TerrainLoader: refreshing all terrain layers (%d OSM cache file(s) cleared) …" % n)


## Wipe painted vegetation sidecars + in-memory edits, then re-fetch all terrain layers live.
func reset_site_to_fresh() -> void:
	if not _built:
		return
	var n_edits := TerrainCacheSettings.invalidate_user_vegetation_edits(_lat, _lon)
	_vegetation_layer = VegetationLayer.create_empty()
	_auto_veg_edits = AutoVegetationEdits.create_empty()
	_veg_style = VegetationStyleConfig.load_merged(_lat, _lon)
	_rebuild_vegetation()
	_clear_auto_vegetation()
	_auto_veg_generated = false
	_auto_veg_data = {}
	_auto_growth_zone_index = null
	_notify_options_status("Resetting site — cleared %d user veg file(s) …" % n_edits, "busy")
	refresh_all_cached_layers()


func needs_opentopo_hint() -> bool:
	var es := get_node_or_null("/root/ElevationService")
	return es != null and not es.has_opentopo_key()


func _notify_options_status(msg: String, kind: String = "info") -> void:
	options_status_changed.emit(msg, kind)


## Surfaces a curated fallback/failure notice to the global HUD toast stack
## (the settings-panel status line via _notify_options_status is a separate,
## quieter channel meant for busy/progress states — this is for the handful
## of moments a player should actually notice: quota exhaustion, flat-terrain
## fallback, neutral-drape fallback, and OSM data unavailable).
func _toast(text: String, level: ToastUI.Level) -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var toast := ui_layer.get_node_or_null("ToastUI")
	if toast == null or not toast.has_method("show_toast"):
		return
	toast.show_toast(text, level)


func _begin_refresh(layer: String) -> void:
	_refresh_pending[layer] = true
	_emit_refresh_status()


func _finish_refresh(layer: String) -> void:
	if not _refresh_pending.has(layer):
		return
	_refresh_pending.erase(layer)
	if _refresh_pending.is_empty():
		_notify_options_status("Refresh complete", "ok")
	else:
		_emit_refresh_status()


func _abort_refresh(layer: String, reason: String) -> void:
	if _refresh_pending.has(layer):
		_refresh_pending.erase(layer)
	var label: String = str({
		"dem": "Elevation",
		"imagery": "Imagery",
		"osm_map": "Map data",
		"osm_veg": "Vegetation",
	}.get(layer, layer))
	_notify_options_status("%s refresh failed: %s" % [label, _short_fetch_error(reason)], "warn")
	if not _refresh_pending.is_empty():
		_emit_refresh_status()


func _short_fetch_error(reason: String) -> String:
	var r := reason.strip_edges()
	if r.length() > 120:
		r = r.substr(0, 117) + "…"
	return r


func _elev_phase_timeout_s() -> float:
	return clampf(_half_extent / 25000.0 * 120.0, 120.0, 360.0)


func _imagery_phase_timeout_s() -> float:
	return clampf(_half_extent / 25000.0 * 180.0, 180.0, 480.0)


func _emit_refresh_status() -> void:
	if _refresh_pending.is_empty():
		return
	var labels := {
		"dem": "elevation",
		"imagery": "imagery",
		"osm_map": "map data",
		"osm_veg": "vegetation",
	}
	var parts: PackedStringArray = PackedStringArray()
	for key in _refresh_pending:
		parts.append(labels.get(key, key))
	_notify_options_status("Refreshing %s …" % ", ".join(parts), "busy")


func _begin_dem_refetch(force: bool = false) -> void:
	_detail_elev_grid = PackedFloat32Array()
	_detail_elev_cols = 0
	_detail_elev_rows = 0
	_detail_elev_done = false
	_detail_elev_resolved = false
	_detail_surface_grid = PackedFloat32Array()
	var es := get_node_or_null("/root/ElevationService")
	if es == null:
		push_warning("TerrainLoader: ElevationService unavailable")
		return
	es.request_elevation(_lat, _lon, _half_extent,
		ElevationService.base_grid_n_for_extent(_half_extent), "base", force)
	# Detail DEM is requested after base completes (_on_elevation_ready refresh path).


func _begin_imagery_refetch(force: bool = false) -> void:
	_detail_img_retry_zoom = -1
	var img := get_node_or_null("/root/ImageryService")
	if img == null:
		push_warning("TerrainLoader: ImageryService unavailable")
		return
	img.request_imagery(_lat, _lon, _half_extent, _base_imagery_target_px(), "base", 17, force)
	# Detail imagery is applied after base in _on_imagery_ready refresh path.


## Re-fetch ONLY the detail drape (which then chains to hyper via _on_imagery_ready,
## the same tail as the base-ready refresh path). Used by set_terrain_quality so a
## tier change doesn't re-download the tier-independent base drape.
func _begin_detail_imagery_refetch() -> void:
	_detail_img_retry_zoom = -1
	var img := get_node_or_null("/root/ImageryService")
	if img == null:
		push_warning("TerrainLoader: ImageryService unavailable")
		return
	img.request_imagery(_lat, _lon, _detail_half_extent, _detail_target_px(),
		"detail", DETAIL_MAX_ZOOM, true)


func _begin_osm_vectors_refetch() -> void:
	var bs := get_node_or_null("/root/BuildingService")
	if bs == null:
		push_warning("TerrainLoader: BuildingService unavailable")
		return
	var cfg := _terrain_config()
	bs.request_osm_vectors(_lat, _lon, _osm_half_extent, cfg.flatten_landuse)


func _begin_osm_vegetation_refetch() -> void:
	_auto_veg_data = {}
	_auto_veg_generated = false
	_auto_growth_zone_index = null
	var vs := get_node_or_null("/root/VegetationService")
	if vs == null:
		push_warning("TerrainLoader: VegetationService unavailable")
		return
	if not _terrain_config().show_auto_vegetation:
		_clear_auto_vegetation()
		return
	vs.request_vegetation(_lat, _lon, _osm_half_extent)


## Natural DEM + user sculpt edits — no road/site flatten.
func _compose_base_footing_grid(apply_user_edits: bool = true) -> PackedFloat32Array:
	var grid := _base_dem_grid.duplicate()
	if apply_user_edits and _terrain_edits != null:
		grid = _terrain_edits.apply_to(grid)
	return grid


## Walkable hi-res centre surface (detail DEM + edge feather + optional flatten + edits).
func _compose_detail_surface(apply_user_edits: bool = true) -> PackedFloat32Array:
	if not _detail_elev_done or _detail_elev_grid.is_empty():
		return PackedFloat32Array()
	var res := _detail_elev_cols
	var extent := _detail_extent_m()
	if _terrain_edits != null:
		_terrain_edits.ensure_detail(res, extent)
	var grid := TerrainBuilder.apply_detail_vertical_offset(
		_detail_elev_grid.duplicate(), _detail_vertical_offset)
	var coarse := _compose_base_footing_grid(false)
	grid = TerrainBuilder.feather_detail_to_coarse(
		grid, res, extent, coarse, MESH_RES, _built_extent, _built_center_elev, _seam_feather_m)
	var cfg := _terrain_config()
	if cfg.flatten_roads and not _osm_vectors.is_empty():
		grid = TerrainRoadFlatten.apply_road_corridors(
			grid, res, extent, _osm_vectors.get("roads", []))
	if cfg.flatten_landuse and not _osm_vectors.is_empty():
		grid = TerrainRoadFlatten.apply_polygon_flattens(
			grid, res, extent, _osm_vectors.get("landuse", []))
	if apply_user_edits and _terrain_edits != null:
		grid = _apply_edits_to_detail(grid, res, extent)
		grid = _terrain_edits.apply_detail_to(grid, res, extent)
	return grid


func _compose_terrain_grids(apply_user_edits: bool = true) -> Dictionary:
	var coarse_foot := _compose_base_footing_grid(apply_user_edits)
	_detail_vertical_offset = 0.0
	_seam_feather_m = TerrainBuilder.DEFAULT_FEATHER_M
	if _detail_elev_done and not _detail_elev_grid.is_empty():
		_detail_vertical_offset = TerrainBuilder.compute_detail_vertical_offset(
			_detail_elev_grid, _detail_elev_cols, _detail_extent_m(),
			coarse_foot, MESH_RES, _built_extent, _built_center_elev)
		if absf(_detail_vertical_offset) > 20.0:
			push_warning("TerrainLoader: detail vertical offset %.1f m — verify DEM cache/sources" \
				% _detail_vertical_offset)
		var aligned := TerrainBuilder.apply_detail_vertical_offset(
			_detail_elev_grid, _detail_vertical_offset)
		_seam_feather_m = TerrainBuilder.compute_adaptive_feather_m(
			aligned, _detail_elev_cols, _detail_extent_m(),
			coarse_foot, MESH_RES, _built_extent, _built_center_elev)
	var detail_surf := _compose_detail_surface(apply_user_edits)
	var built_visual := coarse_foot
	var built_collision := coarse_foot
	if not detail_surf.is_empty():
		built_visual = TerrainBuilder.patch_centre_heights(
			coarse_foot, MESH_RES, detail_surf, _detail_elev_cols,
			_built_extent, _detail_extent_m(), _seam_feather_m)
		built_visual = TerrainBuilder.feather_coarse_exterior_ring(
			built_visual, MESH_RES, _built_extent, _built_center_elev,
			detail_surf, _detail_elev_cols, _detail_extent_m())
		built_collision = built_visual.duplicate()
		var sink_depth := TerrainBuilder.compute_sink_depth_m(detail_surf)
		TerrainBuilder.sink_coarse_centre_for_detail(
			built_collision, MESH_RES, _built_extent, _detail_extent_m(), _built_center_elev,
			sink_depth, _seam_feather_m * 0.75)
		var seam := TerrainSeamDiag.measure_boundary_delta(
			detail_surf, _detail_elev_cols, _detail_extent_m(),
			built_visual, MESH_RES, _built_extent, _built_center_elev)
		print("TerrainLoader: seam max_delta=%.2f m rms=%.2f m (feather=%.0f m, v_offset=%.2f m)" % [
			float(seam.get("max_delta_m", 0.0)), float(seam.get("rms_delta_m", 0.0)),
			_seam_feather_m, _detail_vertical_offset])
	return {
		"footing": built_visual,
		"built": built_visual,
		"collision_coarse": built_collision,
		"detail_surface": detail_surf,
	}


func _apply_edits_to_detail(detail: PackedFloat32Array, res: int, extent_m: float) -> PackedFloat32Array:
	var out := detail.duplicate()
	if _terrain_edits == null or _terrain_edits.delta.is_empty():
		return out
	var half := extent_m * 0.5
	for r in res:
		var z := float(r) / float(maxi(res - 1, 1)) * extent_m - half
		for c in res:
			var x := float(c) / float(maxi(res - 1, 1)) * extent_m - half
			var u := clampf((x + _built_extent * 0.5) / _built_extent, 0.0, 1.0)
			var v := clampf((z + _built_extent * 0.5) / _built_extent, 0.0, 1.0)
			var du := u * float(MESH_RES - 1)
			var dv := v * float(MESH_RES - 1)
			var c0 := int(floor(du))
			var r0 := int(floor(dv))
			var c1 := mini(c0 + 1, MESH_RES - 1)
			var r1 := mini(r0 + 1, MESH_RES - 1)
			var tx := du - float(c0)
			var ty := dv - float(r0)
			var d00 := _terrain_edits.delta[r0 * MESH_RES + c0]
			var d10 := _terrain_edits.delta[r0 * MESH_RES + c1]
			var d01 := _terrain_edits.delta[r1 * MESH_RES + c0]
			var d11 := _terrain_edits.delta[r1 * MESH_RES + c1]
			var delta := lerpf(lerpf(d00, d10, tx), lerpf(d01, d11, tx), ty)
			out[r * res + c] += delta
	return out


func _rebuild_heightfield(skip_overlays: bool = false, reseat_actors: bool = true) -> void:
	if not _built or _base_dem_grid.is_empty():
		return
	var had_detail := _detail_collision_active
	var terrain := _begin_heightfield_rebuild()
	if terrain != null:
		_rebuild_coarse_surface(terrain)
		_rebuild_detail_patch(terrain)
	if not skip_overlays:
		_attach_buildings()
		_attach_water()
	_finish_heightfield_rebuild(had_detail, reseat_actors)
	_watershed_analysis = null  # lazy recompute via get_watershed_analysis()


## Same rebuild as _rebuild_heightfield, but spreads the heavy node construction
## across separate idle frames. Used on the FIRST detail-DEM arrival (uncached
## load): doing the 512² detail mesh (262 k verts) + its HeightMapShape3D collider
## + every building mesh/collider + the detail-drape texture upload all on a single
## frame slams the GPU/physics server hard enough to trip a Windows GPU TDR — the
## process then exits with no error. State other code reads synchronously
## (_built_grid, _detail_surface_grid, _footing_grid, _spawn_ground_y) is still set
## up front in _begin_heightfield_rebuild(); only the GPU/physics uploads stagger.
func _rebuild_heightfield_staggered(skip_overlays: bool = false) -> void:
	if not _built or _base_dem_grid.is_empty():
		return
	var had_detail := _detail_collision_active
	var terrain := _begin_heightfield_rebuild()
	if terrain == null:
		return
	var tree := get_tree()
	_log_load_mem("rebuild: begin")
	_rebuild_coarse_surface(terrain)
	_log_load_mem("rebuild: coarse")
	if tree != null:
		await tree.process_frame
	if not is_instance_valid(terrain):
		return
	_rebuild_detail_patch(terrain)
	_log_load_mem("rebuild: detail patch")
	if tree != null:
		await tree.process_frame
	if not is_instance_valid(terrain):
		return
	if not skip_overlays:
		_attach_buildings(false)
		_log_load_mem("rebuild: buildings")
		if tree != null:
			await tree.process_frame
		if not is_instance_valid(terrain):
			return
		_attach_water()
		if tree != null:
			await tree.process_frame
		if not is_instance_valid(terrain):
			return
	_finish_heightfield_rebuild(had_detail)
	_watershed_analysis = null


## Recompose the terrain grids and refresh the synchronous footing state every
## consumer reads. Returns the Terrain node (or null when not ready).
func _begin_heightfield_rebuild() -> Node3D:
	if not _built or _base_dem_grid.is_empty():
		return null
	var grids := _compose_terrain_grids()
	_footing_grid = grids["footing"]
	_built_grid = grids["built"]
	_built_collision_grid = grids.get("collision_coarse", _built_grid)
	_detail_surface_grid = grids["detail_surface"]
	_spawn_ground_y = TerrainBuilder.height_at_world_xz(
		_built_grid, MESH_RES, _built_extent, _built_center_elev, 0.0, 0.0)
	if not _detail_surface_grid.is_empty():
		_spawn_ground_y = TerrainBuilder.height_at_world_xz_rect(
			_detail_surface_grid, _detail_elev_cols, _detail_elev_rows,
			_detail_extent_m(), _built_center_elev, 0.0, 0.0)
	return _main.get_node_or_null("Terrain") if _main != null else null


## Coarse Ground mesh + collider (and drop any detail patch when detail is gone).
func _rebuild_coarse_surface(terrain: Node3D) -> void:
	if not _detail_surface_grid.is_empty():
		TerrainBuilder.rebuild_terrain_surfaces(
			terrain, _built_grid, MESH_RES, _built_extent, _built_center_elev,
			_drape, _detail_drape, _detail_extent_m(), false, _seam_feather_m,
			_built_collision_grid)
	else:
		TerrainBuilder.remove_detail_patch(terrain)
		TerrainBuilder.rebuild_terrain_surfaces(
			terrain, _built_grid, MESH_RES, _built_extent, _built_center_elev,
			_drape, _detail_drape, _detail_extent_m(), false, _seam_feather_m,
			_built_collision_grid)
	_stamp_drape_mercator_bboxes(terrain)


## Hi-res centre patch: visual mesh + HeightMapShape3D collider (the big spike).
## The detail DEM is already resampled to DETAIL_MESH_RES on arrival, so the mesh,
## collider, and footing all share the one _detail_surface_grid (no float/sink).
func _rebuild_detail_patch(terrain: Node3D) -> void:
	if _detail_surface_grid.is_empty():
		return
	var mesh_grid := _detail_surface_grid
	var mesh_res := _detail_elev_cols
	if _detail_elev_cols > DETAIL_MESH_RES or _detail_elev_rows > DETAIL_MESH_RES:
		mesh_grid = TerrainBuilder.resample(
			_detail_surface_grid, _detail_elev_cols, _detail_elev_rows, DETAIL_MESH_RES)
		mesh_res = DETAIL_MESH_RES
	# Sink the coarse detail surface under active edit tiles (hi-res tile meshes
	# own those areas); keeps cut bowls visible and their colliders authoritative.
	mesh_grid = _detail_mesh_grid_with_sink(mesh_grid, mesh_res)
	_detail_sink_sig = _sink_signature()
	TerrainBuilder.upsert_detail_patch(
		terrain, mesh_grid, mesh_res, _detail_extent_m(),
		_built_center_elev, _drape, _detail_drape, _built_extent, _seam_feather_m)
	_stamp_drape_mercator_bboxes(terrain)
	print("TerrainLoader: hi-res centre mesh %d×%d (%.0f m, ~%.1f m/vertex)" % [
		mesh_res, mesh_res, _detail_extent_m(),
		(_detail_extent_m()) / float(maxi(mesh_res - 1, 1))])


## Re-ground dynamic content and re-seat actors after a heightfield change.
func _finish_heightfield_rebuild(had_detail: bool, reseat_actors: bool = true) -> void:
	_reground_vegetation()
	_reground_placed_props()
	if _auto_veg_generated:
		_reground_auto_vegetation()
	var terrain_node := _main.get_node_or_null("Terrain") if _main != null else null
	if terrain_node != null:
		_ensure_height_field(terrain_node)
	_detail_collision_active = not _detail_surface_grid.is_empty()
	if reseat_actors and _detail_collision_active and (not had_detail or _actors_off_ground()):
		_sync_actors_to_ground(not had_detail)
		# Detail collider just changed; reseat on the true surface once physics
		# has registered it (avoids landing on the lower coarse collider).
		if not had_detail and not _from_resume:
			_deferred_raycast_reseat()
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("refresh_footing"):
		soi.refresh_footing()


## Reseat the player on the true collision surface after the next couple of
## physics frames (so freshly-added terrain colliders are live).
func _deferred_raycast_reseat() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	_raycast_reseat_player()


## Seat props (and refresh building footing) on the final composed heightfield
## before the player takes control. Camps are left alone — `_attach_camps` would
## wipe manually scattered BRC camps when generate_camps is off.
func _seat_world_content_for_play() -> void:
	if not _built:
		return
	_reground_placed_props()
	# Re-extrude OSM so skirts/floors use the composed footing (deferred prop
	# rebuild can race the first attach; this is the authoritative pass).
	if not _buildings_data.is_empty():
		_attach_buildings(false)


func _actors_off_ground() -> bool:
	if _main == null:
		return false
	var player := _main.get_node_or_null("Player") as CharacterBody3D
	if player != null:
		var gy := _ground_height_at(player.global_position.x, player.global_position.z)
		var target := gy + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M
		if absf(player.global_position.y - target) > 0.35:
			return true
	var drone := _main.get_node_or_null("FPVDrone") as FPVDrone
	if drone != null:
		var dgy := _ground_height_at(drone.global_position.x, drone.global_position.z)
		var dpos := drone.global_position
		if dpos.y < dgy + 0.25 or dpos.y > dgy + 80.0:
			return true
	return false


func _maybe_opentopo_hint() -> void:
	var es := get_node_or_null("/root/ElevationService")
	if es == null:
		return
	if es.has_opentopo_key():
		return
	if es.has_method("is_openmeteo_daily_exhausted") and es.is_openmeteo_daily_exhausted():
		_notify_options_status(
			"Open-Meteo elevation quota used up today — add OpenTopography key (see LOCAL_CONFIG.md) or reload tomorrow",
			"warn")
	print("TerrainLoader: add an OpenTopography API key to user://terrain_config.cfg for 30 m / 10 m DEM (see LOCAL_CONFIG.md)")


func _setup_terrain_options_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var opts_ui := PanelContainer.new()
	opts_ui.name = "TerrainOptionsUI"
	opts_ui.set_script(TERRAIN_OPTIONS_UI_SCRIPT)
	ui_layer.add_child(opts_ui)
	opts_ui.bind_loader(self)
	_terrain_options_ui = opts_ui


func _setup_vegetation_edit_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "VegetationEditLayer"
	layer.layer = 25
	ui_layer.add_child(layer)
	var edit_ui := Control.new()
	edit_ui.name = "VegetationEditUI"
	edit_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	edit_ui.set_script(VEGETATION_EDIT_UI_SCRIPT)
	layer.add_child(edit_ui)
	edit_ui.bind_loader(self)
	_vegetation_edit_ui = edit_ui
	var preview_ui := Control.new()
	preview_ui.name = "VegetationPreviewEditor"
	preview_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_ui.set_script(VEGETATION_PREVIEW_EDITOR_SCRIPT)
	layer.add_child(preview_ui)
	preview_ui.bind_loader(self, edit_ui)
	_vegetation_preview_ui = preview_ui


func open_vegetation_preview_editor(initial_preset: int = -1, species_id: String = "") -> void:
	if _vegetation_preview_ui != null and _vegetation_preview_ui.has_method("open"):
		_vegetation_preview_ui.call("open", initial_preset, species_id)


func _setup_camp_scatter_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "CampScatterLayer"
	layer.layer = 24
	ui_layer.add_child(layer)
	var ui := Control.new()
	ui.name = "CampScatterUI"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.set_script(CAMP_SCATTER_UI_SCRIPT)
	layer.add_child(ui)
	ui.bind_loader(self)
	_camp_scatter_ui = ui
	# NPC Spaces dock (Y): areas are the one space target with no object to
	# open, so they need a place of their own to be drawn.
	var space_ui := Control.new()
	space_ui.name = "SpaceEditUI"
	space_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	space_ui.set_script(SPACE_EDIT_UI_SCRIPT)
	layer.add_child(space_ui)
	space_ui.bind_loader(self)
	_space_edit_ui = space_ui


func _setup_vegetation() -> void:
	_vegetation_layer = VegetationLayer.create_empty()
	# Phase 2: no global-shape seeding. The layer only carries SPARSE user
	# deltas now (VegetationLayer v2) and the render path merges those over the
	# style store — seeding would turn global style values into per-map layer
	# deltas that shadow later global tunes.
	_vegetation_layer.load_for_map(_lat, _lon)
	# Phase 3b: impostor baker (windowed only — headless stays deterministic
	# on the FAR-card fallback). Bakes come in bursts on first load of a look;
	# debounce them into one rebuild.
	if DisplayServer.get_name() != "headless" and _impostor_baker == null:
		_impostor_baker = VegImpostorBaker.new()
		_impostor_baker.name = "VegImpostorBaker"
		add_child(_impostor_baker)
		_impostor_baker.bake_completed.connect(_on_impostor_bake_completed)
	_growth_init_manual()
	_setup_vegetation_edit_ui()
	_setup_camp_scatter_ui()
	_manual_veg_pending = true
	if not _load_ui_active or _load_progress == null or _load_progress.is_complete():
		call_deferred("_start_manual_veg_rebuild")


func _start_manual_veg_rebuild() -> void:
	if not _manual_veg_pending:
		return
	_manual_veg_pending = false
	_rebuild_vegetation()


func _rebuild_vegetation() -> void:
	if not _built or _vegetation_layer == null or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	VegetationRuntime.rebuild(terrain, _vegetation_layer, Callable(self, "_ground_height_at"),
		false, _auto_veg_runtime_settings(), _manual_growth_map)



func push_vegetation_undo(label: String = "") -> void:
	if _vegetation_layer == null:
		return
	_veg_undo.push_combined(_vegetation_layer.bulk, _auto_veg_edits, label)


func can_undo_vegetation() -> bool:
	return _veg_undo.can_undo()


func undo_vegetation() -> bool:
	if not _veg_undo.can_undo() or _vegetation_layer == null:
		return false
	var snap := _veg_undo.pop()
	VegetationUndo.restore_manual_bulk(_vegetation_layer, snap)
	_vegetation_layer.save(_lat, _lon)
	if snap.has("auto_edits") and _auto_veg_edits != null:
		_auto_veg_edits.deserialize(snap["auto_edits"])
		_auto_veg_edits.save(_lat, _lon)
		if _auto_veg_generated:
			call_deferred("_full_regenerate_auto_vegetation")
	VegetationCardFactory.clear_foot_cache()
	_rebuild_vegetation()
	return true


## Phase 2: returns the layer's SPARSE user deltas (matches what the render
## path now merges over the style store). Callers wanting the full fallback
## dict should read the style store via get_vegetation_style().
func get_vegetation_settings() -> Dictionary:
	if _vegetation_layer == null:
		return {}
	return _vegetation_layer.user_settings()


func get_map_vegetation_bounds() -> PackedVector2Array:
	var he := _half_extent
	return PackedVector2Array([
		Vector2(-he, -he), Vector2(he, -he), Vector2(he, he), Vector2(-he, he),
	])


func set_vegetation_settings(patch: Dictionary, rebuild: bool = true, persist: bool = true) -> void:
	if _vegetation_layer == null:
		return
	# Phase 2: shape lives in the style store; the layer keeps only deltas the
	# player has NOT re-expressed at style level (see apply_vegetation_look).
	_vegetation_layer.erase_settings_keys(patch.keys())
	_veg_style.merge(patch, true)
	if persist:
		_vegetation_layer.save(_lat, _lon)
		VegetationStyleConfig.save_map(_lat, _lon, _veg_style)
	if rebuild:
		VegetationCardFactory.clear_foot_cache()
		call_deferred("_rebuild_all_vegetation")


func _rebuild_all_vegetation() -> void:
	_rebuild_vegetation()
	if _auto_veg_generated:
		_rebuild_auto_vegetation_async()


## One debounced rebuild after a burst of impostor bakes completes, so OUTER
## rings swap from the FAR-card fallback to the fresh impostor quads.
func _on_impostor_bake_completed(_key: String) -> void:
	if not _built or _impostor_rebuild_pending:
		return
	_impostor_rebuild_pending = true
	var t := get_tree().create_timer(1.5)
	t.timeout.connect(func() -> void:
		_impostor_rebuild_pending = false
		if not _built:
			return
		_rebuild_all_vegetation()
	, CONNECT_ONE_SHOT)


## Re-ring vegetation (debounced) after the SoI pin moves: soi_changed fires
## per drag step, and a full veg rebuild per step would stutter — wait for the
## pin to settle, then rebuild once if it actually moved meaningfully.
func _on_soi_changed_for_veg() -> void:
	if not _built or _veg_ring_rebuild_pending:
		return
	var soi := get_node_or_null("/root/SoiService")
	if soi == null or not soi.has_method("world_center"):
		return
	var c: Vector3 = soi.world_center()
	if Vector2(c.x, c.z).distance_to(_veg_ring_built_center) < 64.0:
		return
	_veg_ring_rebuild_pending = true
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func() -> void:
		_veg_ring_rebuild_pending = false
		if not _built:
			return
		_rebuild_all_vegetation()
	, CONNECT_ONE_SHOT)


func _reground_vegetation() -> void:
	if _vegetation_layer == null or _main == null:
		return
	for item in _vegetation_layer.hero:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		d["ground_y"] = _ground_height_at(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	VegetationRuntime.reground(terrain, _vegetation_layer, Callable(self, "_ground_height_at"),
		_auto_veg_runtime_settings(), _manual_growth_map)


## ---------------------------------------------------------------------------
## Auto-vegetation (generated, non-persisted; ROADMAP Pillar 8)
## ---------------------------------------------------------------------------

func _setup_auto_vegetation() -> void:
	_auto_veg_layer = AutoVegetationLayer.create_empty()
	_auto_veg_generated = false
	_auto_veg_edits = AutoVegetationEdits.create_empty()
	_auto_veg_edits.load_for_map(_lat, _lon)
	_veg_style = VegetationStyleConfig.load_merged(_lat, _lon)
	if not _terrain_config().show_auto_vegetation:
		_load_progress_mark_done("osm_veg")
		if not _load_sequence_active:
			_check_load_complete()


## Kicks off the async OSM-vegetation fetch, AFTER terrain + buildings exist so it
## never gates map display. The wider (~3 km) fetch runs on its own
## VegetationService HTTPRequest, independent of the buildings request.
func _request_auto_vegetation() -> void:
	if not _terrain_config().show_auto_vegetation:
		# Disabled is a valid choice, but a SILENT one reads as "auto-veg is
		# broken" on a forested site — say why the forest is missing and where
		# the switch lives.
		_toast("Auto vegetation is OFF (Terrain options → Auto vegetation).", ToastUI.Level.INFO)
		_clear_auto_vegetation()
		return
	var vs := get_node_or_null("/root/VegetationService")
	if vs == null:
		push_warning("TerrainLoader: VegetationService unavailable")
		_load_progress_mark_done("osm_veg")
		_check_load_complete()
		return
	vs.request_vegetation(_lat, _lon, _osm_half_extent)


func _on_vegetation_osm_ready(key: String, payload: Dictionary) -> void:
	var vs := get_node_or_null("/root/VegetationService")
	# The service runs one job with a single-slot pending queue and delivers
	# whatever finished — the key is the only thing saying WHICH site it was
	# for. Without this check a site switch mid-flight applied the previous
	# site's forests to this map.
	if vs != null and key != "" and not vs.matches_site(key, _lat, _lon, _osm_half_extent):
		push_warning("TerrainLoader: dropped OSM vegetation for stale request %s" % key)
		return
	# Belt-and-suspenders: VegetationService caps on parse/cache, but callers
	# (refresh paths) may still hand us an uncapped dict.
	_auto_veg_data_raw = vs.cap_polygons(payload) if vs != null else payload
	_auto_veg_data = OsmRegistration.offset_payload(
		_auto_veg_data_raw, _osm_offset_east_m, _osm_offset_north_m)
	if _load_sequence_active and _phase_key == "osm_veg" and _phase_waiting:
		_phase_resolve("osm_veg", true)
		return
	# Late arrival: Overpass retries (up to ~384 s worst case) can outlast the
	# 180 s phase budget, so the reply may land after the phase timed out or the
	# whole sequence finished. Still record + queue the scatter — the old
	# unconditional early-return while _load_sequence_active stored the payload
	# and never scattered it. _queue_auto_veg_generate self-defers while the
	# load UI is up (flushed on load complete via _auto_veg_scatter_pending).
	_finish_osm_veg_fetch_stage()
	_queue_auto_veg_generate(false)


func _on_vegetation_osm_failed(reason: String) -> void:
	push_warning("TerrainLoader: OSM vegetation unavailable (%s)" % reason)
	_toast("Vegetation data unavailable — map will load without auto-vegetation.", ToastUI.Level.WARN)
	if _load_sequence_active:
		_phase_resolve("osm_veg", false)
		return
	_finish_osm_veg_fetch_stage()
	if _built:
		_finish_refresh("osm_veg")


## OSM veg fetch complete — unblocks load UI. Scatter is background-only.
func _finish_osm_veg_fetch_stage() -> void:
	if _load_progress == null or _load_progress.is_done("osm_veg"):
		return
	if not _terrain_config().show_auto_vegetation:
		_load_progress_mark_done("osm_veg")
		_check_load_complete()
		return
	_load_progress_mark_done("osm_veg")
	_check_load_complete()


## Queue scatter after detail DEM + OSM payload are ready (never gates map display).
func _queue_auto_veg_generate(regen_for_exclusions: bool = false) -> void:
	if not _built or _auto_veg_data.is_empty():
		return
	if not _auto_veg_ground_ready():
		return
	if not _terrain_config().show_auto_vegetation:
		_clear_auto_vegetation()
		return
	if _auto_veg_generated and not regen_for_exclusions:
		return
	# Never block the load pipeline — HTTP callbacks need the main thread.
	if _load_ui_active and _load_progress != null and not _load_progress.is_complete():
		_auto_veg_scatter_pending = true
		_auto_veg_scatter_regen = regen_for_exclusions
		return
	if _auto_veg_generate_queued:
		return
	_auto_veg_generate_queued = true
	call_deferred("_run_auto_veg_generate", regen_for_exclusions)


func _run_auto_veg_generate(regen_for_exclusions: bool) -> void:
	_auto_veg_scatter_async(regen_for_exclusions)


const SCATTER_BATCH_POLYS := 5


func _auto_veg_scatter_async(regen_for_exclusions: bool) -> void:
	_auto_veg_generate_queued = false
	if not _built or _auto_veg_data.is_empty() or not _auto_veg_ground_ready():
		_mark_auto_veg_ready()
		return
	if not _terrain_config().show_auto_vegetation:
		_mark_auto_veg_ready()
		return
	if _auto_veg_generated and not regen_for_exclusions:
		_apply_large_map_veg_runtime_lod()
		_mark_auto_veg_ready()
		return
	await get_tree().process_frame
	if not _built:
		_mark_auto_veg_ready()
		return
	print("TerrainLoader: scattering vegetation from OSM (background) …")
	var ctx := _auto_veg_ctx()
	var state := AutoVegetationGenerator.prepare_context(_auto_veg_data, ctx)
	while AutoVegetationGenerator.scatter_batch(state, SCATTER_BATCH_POLYS):
		var ratio := state.progress_ratio()
		var pct := int(round(ratio * 100.0))
		_load_hint = "Scattering vegetation… %d%%" % pct
		# Advance the load bar through the osm_veg stage so the scatter reads as
		# progress rather than a frozen bar (the pipeline UI is otherwise only
		# repainted by the elevation/imagery fetch callbacks).
		if _load_ui_active and _load_progress != null:
			_load_progress.set_partial("osm_veg", ratio)
			_update_load_ui()
		await get_tree().process_frame
		if not _built:
			_mark_auto_veg_ready()
			return
	_auto_veg_layer = state.layer
	_auto_veg_poly_stats = state.poly_stats
	_print_auto_veg_diag(state)
	_apply_auto_veg_edits()
	_rebuild_auto_growth_zone_index()
	_growth_init_auto()
	_auto_veg_generated = true
	await get_tree().process_frame
	if not _built:
		_mark_auto_veg_ready()
		return
	await _rebuild_auto_vegetation_async()
	_apply_large_map_veg_runtime_lod()
	var total := _auto_veg_layer.total_bulk() + _auto_veg_layer.hero.size()
	var near_200 := _auto_veg_layer.count_within_radius(0.0, 0.0, 200.0)
	var near_500 := _auto_veg_layer.count_within_radius(0.0, 0.0, 500.0)
	var nearest := _auto_veg_layer.nearest_distance(0.0, 0.0)
	print("TerrainLoader: auto-vegetation %d instances (%d polys, %d points, %d rows); spawn vicinities: %d within 200 m, %d within 500 m, nearest %.0f m" % [
		total,
		(_auto_veg_data.get("polygons", []) as Array).size(),
		(_auto_veg_data.get("tree_points", []) as Array).size(),
		(_auto_veg_data.get("tree_rows", []) as Array).size(),
		near_200, near_500, nearest])
	if _built:
		_finish_refresh("osm_veg")
	_mark_auto_veg_ready()


## Per-polygon scatter diagnostics from the last generator run (see
## GeneratorState.poly_stats). Also feeds the veg-area inspector UI.
var _auto_veg_poly_stats: Array = []


func get_auto_veg_poly_stats() -> Array:
	return _auto_veg_poly_stats


## Per-kind scatter summary: why polygons did/didn't populate (budget, slope,
## exclusion buffers, open-area veto). One table per generator run.
func _print_auto_veg_diag(state: AutoVegetationGenerator.GeneratorState) -> void:
	if state.poly_stats.is_empty():
		return
	var by_kind: Dictionary = {}
	for stat in state.poly_stats:
		var s: Dictionary = stat
		var kind := str(s.get("kind", "?"))
		if kind not in by_kind:
			by_kind[kind] = {"polys": 0, "area": 0.0, "candidates": 0, "placed": 0,
				"rej_excluded": 0, "rej_slope": 0, "rej_open": 0, "rej_edge": 0,
				"rej_budget": 0, "rej_distant": 0, "empty": 0}
		var agg: Dictionary = by_kind[kind]
		agg["polys"] += 1
		agg["area"] += float(s.get("area_m2", 0.0))
		for key in ["candidates", "placed", "rej_excluded", "rej_slope", "rej_open",
				"rej_edge", "rej_budget", "rej_distant"]:
			agg[key] += int(s.get(key, 0))
		if int(s.get("placed", 0)) == 0:
			agg["empty"] += 1
	print("TerrainLoader: OSM veg scatter by kind (polys/empty · area · placed | rejected: excl/slope/open/edge/budget/distant)")
	for kind in by_kind:
		var a: Dictionary = by_kind[kind]
		print("  %-12s %3d/%-3d · %7.1f ha · %6d | %d/%d/%d/%d/%d/%d" % [
			kind, a["polys"], a["empty"], float(a["area"]) / 10000.0, a["placed"],
			a["rej_excluded"], a["rej_slope"], a["rej_open"], a["rej_edge"],
			a["rej_budget"], a["rej_distant"]])
	var fs: Dictionary = state.feature_stats
	if not fs.is_empty():
		print("  mapped features: %d tree points, %d row trees, %d hedge shrubs (budget-rejected: %d/%d/%d)" % [
			int(fs.get("points_placed", 0)), int(fs.get("rows_placed", 0)),
			int(fs.get("hedges_placed", 0)), int(fs.get("points_rej_budget", 0)),
			int(fs.get("rows_rej_budget", 0)), int(fs.get("hedges_rej_budget", 0))])
	# Report against the layer's LIVE caps (apply_instance_caps / large-map
	# thinning), not the class constants — printing 4000/24000 as if 20k of
	# headroom remained hid the large-map clamp entirely.
	print("  budgets: trees %d/%d, grass %d/%d, heroes %d/%d%s" % [
		state.layer.tree_bulk_count(), state.layer.max_tree_bulk,
		state.layer.grass_bulk_count(), state.layer.max_grass_bulk,
		state.layer.hero.size(), AutoVegetationLayer.MAX_HERO,
		" · DENSE site (per-poly cap %d, gap fill off)" % AutoVegetationGenerator.DENSE_POLY_SCATTER_CAP if state.dense else ""])
	if state.layer.max_tree_bulk < AutoVegetationLayer.MAX_TREE_BULK_TOTAL:
		print("  NOTE: large-map thinning active — tree cap %d (of %d), see auto_max_tree_instances" % [
			state.layer.max_tree_bulk, AutoVegetationLayer.MAX_TREE_BULK_TOTAL])


## True once stage-2 detail elevation has succeeded or failed (never while pending).
func _auto_veg_ground_ready() -> bool:
	return _detail_elev_resolved


func _auto_veg_ctx() -> Dictionary:
	var gate: LandcoverImageryGate = null
	if _drape != null and _built_extent > 0.0:
		var detail_ext := _detail_extent_m() if _detail_drape != null else 0.0
		gate = LandcoverImageryGate.from_texture_downsampled(
			_drape, _built_extent, 512, _detail_drape, detail_ext, 512)
	# Pass the larger of world/OSM so large-map thinning triggers even when the
	# OSM fetch window is smaller than the 30 km terrain shell.
	var thin_half := maxf(_osm_half_extent, _half_extent)
	return {
		"latitude": _lat,
		"half_extent_m": thin_half,
		"seed": int(_lat * 10000.0) ^ int(_lon * 10000.0),
		"exclusions": _auto_veg_exclusions(),
		"ground_y_at": Callable(self, "_ground_height_at"),
		"gate": gate,
		"style": _veg_style,
	}


func _auto_veg_runtime_settings() -> Dictionary:
	var seasonal := Color.WHITE
	if _veg_style.get("seasonal_strength", 0.0) > 0.0 and _main != null:
		var month := int(_main.get("month")) if _main.get("month") != null else 6
		var autumn_t := clampf(absf(float(month) - 10.0) / 3.0, 0.0, 1.0)
		seasonal = Color(1.0, 0.92 - autumn_t * 0.2, 0.75 - autumn_t * 0.15)
	var s := VegetationStyleConfig.runtime_settings(_veg_style, _drape, _built_extent, seasonal)
	if _veg_style.get("haze_sync", true) and _drape != null:
		# Haze colour is just an average tint — decode a 512 px downsample, not the
		# full 2048² drape (a full-res Image decode every rebuild is a needless RAM
		# spike during the load-completion build burst).
		var detail_ext := _detail_extent_m() if _detail_drape != null else 0.0
		var gate := LandcoverImageryGate.from_texture_downsampled(
			_drape, _built_extent, 512, _detail_drape, detail_ext, 512)
		if gate != null and gate.is_valid():
			s["haze_color"] = gate.compute_haze_color()
	# Phase 2: merge only the layer's SPARSE user deltas — get_settings()
	# (defaults + deltas) is a complete dict and shadowed every style-store
	# value ("Tune-look doesn't apply" cause #3).
	s.merge(_vegetation_layer.user_settings() if _vegetation_layer != null else {}, true)
	# Current growth-clock time so the runtime can scale each instance by its age
	# (VegetationGrowth.instance_scale_mult). Same value for every record in a
	# rebuild, so it never affects batch partitioning.
	s["growth_now_h"] = _growth_clock_h
	# Phase 3a: static detail rings are anchored on the LIVE SoI centre. Moving
	# the pin re-rings on the next rebuild (_on_soi_changed_for_veg debounces one).
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("world_center"):
		var c: Vector3 = soi.world_center()
		s["veg_ring_center_x"] = c.x
		s["veg_ring_center_z"] = c.z
		_veg_ring_built_center = Vector2(c.x, c.z)
	if _is_large_world_map():
		s["auto_force_far_canopy"] = true
		s["auto_visibility_end_m"] = minf(float(s.get("auto_visibility_end_m", 1200.0)), 480.0)
		s["grass_visibility_end_m"] = minf(float(s.get("grass_visibility_end_m", 520.0)), 260.0)
	return s


# ==================== VEGETATION GROWTH ====================

func _current_abs_h() -> float:
	if _main != null and _main.has_method("get_absolute_hours"):
		return float(_main.call("get_absolute_hours"))
	return 0.0


## Light settings dict for the growth math: growth_years per species + the clock.
func _growth_style() -> Dictionary:
	var s := {"growth_now_h": _growth_clock_h}
	for sp in VegetationLayer.ALL_SPECIES:
		s["%s_growth_years" % sp] = float(_veg_style.get("%s_growth_years" % sp, 0.0))
	return s


## Cheap per-frame check (reads _veg_style directly, no dict build).
func _growth_any_enabled() -> bool:
	if _main != null and _main.get("plant_growth_enabled") == false:
		return false
	for sp in VegetationLayer.ALL_SPECIES:
		if float(_veg_style.get("%s_growth_years" % sp, 0.0)) > 0.0:
			return true
	return false


## Advance the monotonic growth clock; on phenology milestones during the growing
## season, run a growth tick (reseed + rebuild). Winter dormancy freezes the clock.
## Forward-only — rewinding the world clock freezes growth rather than resurrecting
## dead trees. Analemma contributes a fixed day per frame; normal play uses the
## real clock delta but ignores big jumps (UI scrubs) via the clamp.
func _advance_growth() -> void:
	if not _growth_any_enabled():
		return
	var now_abs := _current_abs_h()
	var calendar_doy := _growth_calendar_doy()
	var season := VegetationGrowth.structural_growth_factor(calendar_doy, _lat)
	var step := 0.0
	if bool(_main.get("analemma_mode")):
		var days := 1
		if _main.get("analemma_days_per_frame") != null:
			days = maxi(1, int(_main.get("analemma_days_per_frame")))
		step = 24.0 * float(days)
	else:
		step = clampf(now_abs - _growth_prev_abs_h, 0.0, GROWTH_MAX_STEP_H)
	_growth_prev_abs_h = now_abs
	if step <= 0.0:
		return
	if season > VegetationGrowth.DORMANCY_THRESHOLD:
		_growth_clock_h += step * season
		if bool(_main.get("analemma_mode")):
			if calendar_doy != _growth_scale_apply_doy:
				_growth_scale_apply_doy = calendar_doy
				_manual_growth_map.reset_cursor()
				_auto_growth_map.reset_cursor()
			_apply_growth_scales_budgeted(GROWTH_SCALE_BUDGET_PER_FRAME)
	var prev_doy := _growth_last_calendar_doy
	_growth_last_calendar_doy = calendar_doy
	if prev_doy < 0:
		prev_doy = calendar_doy
	if not VegetationGrowth.milestones_crossed(prev_doy, calendar_doy, _lat):
		return
	if season <= VegetationGrowth.DORMANCY_THRESHOLD:
		return
	var allow_reseed := VegetationGrowth.reseed_allowed(calendar_doy, _lat)
	_growth_tick(allow_reseed)


func _growth_calendar_doy() -> int:
	if _main != null:
		var v: Variant = _main.get("day_of_year")
		if v != null:
			return int(v)
	return 1


func _growth_tick(allow_reseed: bool = true) -> void:
	var st := _growth_style()
	var manual_zone := _manual_growth_zone_index()
	var manual_pop := false
	if allow_reseed and _vegetation_layer != null:
		manual_pop = VegetationGrowth.advance_generations(_vegetation_layer.bulk,
			_growth_clock_h, st, _growth_rng, _growth_caps_manual,
			Callable(self, "_growth_add_manual"), manual_zone)
	var auto_pop := false
	if allow_reseed and _auto_veg_generated and _auto_veg_layer != null:
		auto_pop = VegetationGrowth.advance_generations(_auto_veg_layer.bulk,
			_growth_clock_h, st, _growth_rng, _growth_caps_auto,
			Callable(self, "_growth_add_auto"), _auto_growth_zone_index)
		if auto_pop:
			_auto_veg_layer._recount_bulk()
	# During analemma / ∞ playback a reseed milestone fires while the world is
	# stepping a day per frame; a SYNCHRONOUS full MultiMesh rebuild (~50k auto
	# instances) then hitches a single frame — the periodic spring/fall spikes.
	# Use the frame-chunked async rebuild so the reseed spreads across frames.
	var analemma := _main != null and bool(_main.get("analemma_mode"))
	if manual_pop:
		_rebuild_vegetation()
	elif not _manual_growth_map.is_empty():
		_manual_growth_map.reset_cursor()
		_manual_growth_map.apply_scales(st, Callable(self, "_ground_height_at"), -1)
	if auto_pop:
		if analemma:
			_rebuild_auto_vegetation_async()
		else:
			_rebuild_auto_vegetation()
	elif _auto_veg_generated and not _auto_growth_map.is_empty():
		_auto_growth_map.reset_cursor()
		_auto_growth_map.apply_scales(st, Callable(self, "_ground_height_at"), -1)


func _apply_growth_scales_budgeted(budget: int) -> void:
	if budget <= 0 or not _growth_any_enabled():
		return

	var st := _growth_style()
	var gy := Callable(self, "_ground_height_at")
	var rem := budget
	if _vegetation_layer != null and not _manual_growth_map.is_empty():
		rem = _manual_growth_map.apply_scales(st, gy, rem)
	if rem == 0:
		return
	if _auto_veg_generated and not _auto_growth_map.is_empty():
		_auto_growth_map.apply_scales(st, gy, rem)


# ==================== CLIMELAPSE BAKE / PLAYBACK ====================

func _ensure_climelapse_capture() -> void:
	if is_instance_valid(_climelapse_capture):
		return
	_climelapse_capture = ClimelapseCapture.new()
	_climelapse_capture.name = "ClimelapseCapture"
	add_child(_climelapse_capture)
	_climelapse_capture.capture_progress.connect(_on_climelapse_progress)
	_climelapse_capture.capture_complete.connect(_on_climelapse_capture_complete)


## Capture an MP4 from the locked active camera by simulating forward.
## When climelapse drone path has ≥2 waypoints, camera interpolates along it
## (moving hyperlapse); otherwise the view stays locked at the current pose.
func start_climelapse_export(start_abs: float, end_abs: float, time_scale: float, output_mp4: String, fps: int = 30) -> bool:
	# Every refusal records a message + emits, so the timeline's progress dialog
	# can SHOW why nothing happened instead of silently closing.
	if output_mp4.is_empty():
		return _refuse_export("No output path chosen.")
	if end_abs <= start_abs:
		return _refuse_export("Export range is empty — the end time must be after the start.")
	var tree := get_tree()
	if tree == null:
		return _refuse_export("No scene tree.")
	var rig := ClimelapseCameraRig.snapshot_from_tree(tree)
	if not rig.is_valid():
		return _refuse_export("No active 3D camera — switch to player or drone view first.")
	if _climelapse_drone_path.size() >= 2:
		rig.path = _climelapse_drone_path.duplicate(true)
		rig.mode = "path"
	elif bool(rig.mode == "drone") and _climelapse_drone_path.is_empty():
		# Optional default sweep when exporting from drone with no saved points.
		rig.ensure_default_hyperlapse_path()

	_export_render_start = start_abs
	_export_render_end = end_abs
	_export_time_scale = time_scale
	_export_mp4_path = output_mp4
	_export_camera = rig
	_export_fps = maxi(1, fps)
	_export_pending = true
	_export_status_message = ""
	_export_last_result = ""

	if _main != null and _main.has_method("set_absolute_hours"):
		_main.call("set_absolute_hours", start_abs)

	_ensure_climelapse_capture()
	_climelapse_capture.start_capture(self, start_abs, end_abs, time_scale, output_mp4, rig, fps)
	climelapse_state_changed.emit()
	return true


func _refuse_export(reason: String) -> bool:
	_export_pending = false
	_export_status_message = reason
	_export_last_result = "fail"
	push_warning("Climelapse export: %s" % reason)
	climelapse_state_changed.emit()
	return false


func add_climelapse_path_waypoint() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	var cam := tree.root.get_viewport().get_camera_3d() if tree.root.get_viewport() else null
	if cam == null:
		push_warning("Climelapse path: no active Camera3D.")
		return false
	_climelapse_drone_path.append(ClimelapseCameraRig.waypoint_from_transform(cam.global_transform))
	climelapse_state_changed.emit()
	return true


func clear_climelapse_path() -> void:
	_climelapse_drone_path.clear()
	climelapse_state_changed.emit()


func get_climelapse_path_count() -> int:
	return _climelapse_drone_path.size()


func cancel_climelapse_render() -> void:
	if _climelapse_capture != null and _climelapse_capture.is_active():
		_climelapse_capture.cancel()
	_export_pending = false
	_export_mp4_path = ""
	_export_camera = null
	_export_status_message = "Render cancelled."
	climelapse_state_changed.emit()


func is_climelapse_exporting() -> bool:
	return _climelapse_capture != null and _climelapse_capture.is_active()


func get_climelapse_export_message() -> String:
	return _export_status_message


var _export_status_message := ""
var _export_cull_saved: Array = []
## Result of the LAST finished export: "" while none has run, else "ok"/"fail".
var _export_last_result := ""


## Live export state for the timeline's progress dialog:
## {active, phase ("capture"/"encode"), done, total, progress, message, result}.
func get_climelapse_export_stats() -> Dictionary:
	var active := is_climelapse_exporting()
	return {
		"active": active,
		"phase": _climelapse_capture.get_phase() if active else "",
		"done": _climelapse_capture.get_frames_done() if _climelapse_capture != null else 0,
		"total": _climelapse_capture.get_frames_total() if _climelapse_capture != null else 0,
		"progress": _climelapse_capture.get_progress() if active else -1.0,
		"message": _export_status_message,
		"result": _export_last_result,
	}


func is_climelapse_rendering() -> bool:
	return is_climelapse_exporting()


func get_climelapse_progress() -> float:
	if is_climelapse_exporting():
		return _climelapse_capture.get_progress()
	return -1.0


func get_climelapse_range_abs() -> Vector2:
	return Vector2(_export_render_start, _export_render_end)


func _on_climelapse_progress(_frac: float) -> void:
	climelapse_state_changed.emit()


func _on_climelapse_capture_complete(success: bool, path: String, message: String) -> void:
	_export_pending = false
	_export_mp4_path = ""
	_export_camera = null
	_export_status_message = message
	_export_last_result = "ok" if success else "fail"
	if success:
		print("Climelapse export: %s" % message)
	else:
		push_warning("Climelapse export: %s" % message)
	climelapse_state_changed.emit()


## Tighten draw distance + enable frustum-only scale updates for MP4 capture.
func begin_climelapse_export_cull(export_cam: Camera3D) -> void:
	_export_cull_saved.clear()
	if export_cam == null or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var end_m := _export_visibility_end_m(export_cam)
	for root_name in ["Vegetation", "AutoVegetation"]:
		var veg_root := terrain.get_node_or_null(root_name)
		if veg_root != null:
			_save_tighten_visibility(veg_root, end_m)


func end_climelapse_export_cull() -> void:
	for item in _export_cull_saved:
		if not (item is Dictionary):
			continue
		var node: Variant = (item as Dictionary).get("node")
		if node is MultiMeshInstance3D and is_instance_valid(node):
			var mi := node as MultiMeshInstance3D
			mi.visibility_range_begin = float((item as Dictionary).get("begin", 0.0))
			mi.visibility_range_end = float((item as Dictionary).get("end", 0.0))
	_export_cull_saved.clear()


func _export_visibility_end_m(cam: Camera3D) -> float:
	var half_fov := deg_to_rad(cam.fov * 0.5)
	var reach := cam.far * tan(half_fov) * 1.4
	return clampf(reach, 150.0, minf(cam.far, 2800.0))


func _save_tighten_visibility(node: Node, end_m: float) -> void:
	if node is MultiMeshInstance3D:
		var mi := node as MultiMeshInstance3D
		_export_cull_saved.append({
			"node": mi,
			"begin": mi.visibility_range_begin,
			"end": mi.visibility_range_end,
		})
		var prev_end := mi.visibility_range_end
		if prev_end <= 0.0:
			mi.visibility_range_end = end_m
		else:
			mi.visibility_range_end = minf(prev_end, end_m)
	for child in node.get_children():
		_save_tighten_visibility(child, end_m)



## add_cb for reseeding — appends one manual bulk record and returns it so the
## growth pass can stamp its birth time (a fresh seedling: birth = now).
func _growth_add_manual(species: String, x: float, z: float, yaw: float,
		scale: float, card: Variant) -> Variant:
	if _vegetation_layer == null:
		return null
	var card_dict: Dictionary = card if card is Dictionary else {}
	if not _vegetation_layer.add_bulk(species, x, z, yaw, scale, card_dict):
		return null
	return (_vegetation_layer.bulk[species] as Array).back()


func _growth_add_auto(slot: String, x: float, z: float, yaw: float,
		scale: float, _card: Variant) -> Variant:
	if _auto_veg_layer == null:
		return null
	if not _auto_veg_layer.add_bulk(slot, x, z, yaw, scale):
		return null
	return (_auto_veg_layer.bulk[slot] as Array).back()


const _AUTO_GROWTH_ZONE_SKIP_KINDS: Array[String] = ["grass_lawn", "grass_field"]


func _rebuild_auto_growth_zone_index() -> void:
	_auto_growth_zone_index = null
	if _auto_veg_data.is_empty():
		return
	# Same trim budget as scatter — never index every OSM wood on a dense site.
	var trimmed: Array = AutoVegetationGenerator._trim_polygons(
		_auto_veg_data.get("polygons", []), AutoVegetationGenerator.DENSE_POLY_BUDGET)
	var polys: Array = []
	for rec in trimmed:
		if not (rec is Dictionary):
			continue
		var kind := str((rec as Dictionary).get("kind", ""))
		if kind in _AUTO_GROWTH_ZONE_SKIP_KINDS:
			continue
		var pts: PackedVector2Array = (rec as Dictionary).get("points", PackedVector2Array())
		if pts.size() >= 3:
			polys.append(pts)
	_auto_growth_zone_index = GrowthZoneIndex.from_polygons(polys)


func _manual_growth_zone_index() -> GrowthZoneIndex:
	if _vegetation_layer == null:
		return null
	return GrowthZoneIndex.from_polygons(_vegetation_layer.growth_zones)


## Seed the growth RNG/clock + per-instance birth times right after the manual
## layer loads, so the first render already shows an established age mix. reset=true
## discards any birth_h persisted from a prior session (different clock epoch).
func _growth_init_manual() -> void:
	if _vegetation_layer == null:
		return
	_growth_rng.seed = int(_lat * 10000.0) ^ int(_lon * 10000.0) ^ 0x6b7f
	_growth_prev_abs_h = _current_abs_h()
	_growth_last_calendar_doy = _growth_calendar_doy()
	VegetationGrowth.ensure_birth_times(_vegetation_layer.bulk, _growth_clock_h,
		_growth_style(), _growth_rng, true)
	_growth_caps_manual = VegetationGrowth.capture_caps(_vegetation_layer.bulk)


func _growth_init_auto() -> void:
	if _auto_veg_layer == null:
		return
	# Same gate as _growth_after_manual_edit: with growth disabled (survival
	# toggle off) birth times must NOT be stamped — instance_scale_mult would
	# still apply them while _advance_growth never runs, freezing every auto
	# tree at a random seeded age instead of full mature size.
	if not _growth_any_enabled():
		return
	VegetationGrowth.ensure_birth_times(_auto_veg_layer.bulk, _growth_clock_h,
		_growth_style(), _growth_rng, true)
	_growth_caps_auto = VegetationGrowth.capture_caps(_auto_veg_layer.bulk)


## After a manual placement (paint scatter / single drop) give the new records an
## established age mix (so a painted grove isn't a field of seedlings) and refresh
## the population cap so reseeding holds the new density.
func _growth_after_manual_edit() -> void:
	if _vegetation_layer == null or not _growth_any_enabled():
		return
	VegetationGrowth.ensure_birth_times(_vegetation_layer.bulk, _growth_clock_h,
		_growth_style(), _growth_rng, false)
	_growth_caps_manual = VegetationGrowth.capture_caps(_vegetation_layer.bulk)


## Building / water / road polygons the generator must avoid scattering onto.
func _auto_veg_exclusions() -> Array:
	var building_m := float(_veg_style.get("building_exclusion_m", 0.0))
	var road_m := float(_veg_style.get("road_exclusion_m", 0.0))
	var water_m := float(_veg_style.get("water_exclusion_m", 0.0))
	var building_on := bool(_veg_style.get("building_exclusion_enabled", true))
	var road_on := bool(_veg_style.get("road_exclusion_enabled", true))
	var roads: Array = _osm_vectors.get("roads", []) as Array
	return VegExclusionBuilder.build_all(_buildings_data, roads, _water_data,
		building_m, road_m, water_m, building_on, road_on)


func _apply_auto_veg_edits() -> void:
	if _auto_veg_edits != null and _auto_veg_layer != null:
		_auto_veg_edits.apply_to_layer(_auto_veg_layer)


## Persist a cleared zone and remove matching auto-veg instances immediately.
func clear_auto_vegetation_in_polygon(poly: PackedVector2Array) -> int:
	if poly.size() < 3:
		return 0
	if _auto_veg_edits == null:
		_auto_veg_edits = AutoVegetationEdits.create_empty()
	_auto_veg_edits.add_cleared_polygon(poly)
	_auto_veg_edits.save(_lat, _lon)
	var removed := 0
	if _auto_veg_layer != null and _auto_veg_generated:
		removed = _auto_veg_layer.remove_in_polygon(poly)
		_rebuild_auto_vegetation()
	return removed


func apply_auto_vegetation_patch(poly: PackedVector2Array, params: Dictionary,
		bulk_only: bool = false) -> int:
	if poly.size() < 3:
		return 0
	if _auto_veg_edits == null:
		_auto_veg_edits = AutoVegetationEdits.create_empty()
	_auto_veg_edits.add_patch(poly, params)
	_auto_veg_edits.save(_lat, _lon)
	var n := 0
	if _auto_veg_layer != null and _auto_veg_generated:
		n = _auto_veg_layer.apply_patch_in_polygon(poly, params, bulk_only)
		_rebuild_auto_vegetation()
	return n


## Patch bulk (non-hero) vegetation inside a locked selection — manual + auto layers.
func apply_selection_patch(poly: PackedVector2Array, params: Dictionary) -> Dictionary:
	var result := {"manual": 0, "auto": 0}
	if poly.size() < 3 or params.is_empty():
		return result
	if _vegetation_layer != null:
		result["manual"] = _vegetation_layer.patch_bulk_in_polygon(poly, params)
		if int(result["manual"]) > 0:
			_vegetation_layer.save(_lat, _lon)
			VegetationCardFactory.clear_foot_cache()
			_rebuild_vegetation()
	if _auto_veg_layer != null and _auto_veg_generated:
		result["auto"] = apply_auto_vegetation_patch(poly, params, true)
	return result


func _rebuild_auto_vegetation() -> void:
	if not _built or _auto_veg_layer == null or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	if not _terrain_config().show_auto_vegetation:
		AutoVegetationRuntime.clear(terrain)
		return
	# Never stomp an in-flight async rebuild (they'd both mutate the same
	# MultiMesh children across frames → native crash); let the async one re-run.
	if _auto_rebuild_active:
		_auto_rebuild_dirty = true
		return
	var settings := _auto_veg_runtime_settings()
	var exclusions := _auto_veg_exclusions()
	AutoVegetationRuntime.rebuild(terrain, _auto_veg_layer,
		Callable(self, "_ground_height_at"), settings, exclusions, _auto_growth_map)



## Frame-chunked variant of _rebuild_auto_vegetation for the initial load, so the
## whole vegetation layer doesn't upload to the GPU on a single frame.
func _rebuild_auto_vegetation_async() -> void:
	if not _built or _auto_veg_layer == null or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	if not _terrain_config().show_auto_vegetation:
		AutoVegetationRuntime.clear(terrain)
		return
	if _auto_rebuild_active:
		_auto_rebuild_dirty = true
		return
	_auto_rebuild_active = true
	var settings := _auto_veg_runtime_settings()
	var exclusions := _auto_veg_exclusions()
	await AutoVegetationRuntime.rebuild_async(terrain, _auto_veg_layer,
		Callable(self, "_ground_height_at"), settings, exclusions, _auto_growth_map)
	_auto_rebuild_active = false

	if _auto_rebuild_dirty:
		_auto_rebuild_dirty = false
		await _rebuild_auto_vegetation_async()


## Async sibling of _full_regenerate_auto_vegetation: regenerates the layer, then
## uploads to the GPU via the frame-chunked rebuild so runtime edits (e.g. "Apply
## to map") don't dump the whole vegetation set on one frame.
func _full_regenerate_auto_vegetation_async() -> void:
	if not _auto_veg_generated or _auto_veg_data.is_empty():
		await _rebuild_auto_vegetation_async()
		return
	var state := AutoVegetationGenerator.prepare_context(_auto_veg_data, _auto_veg_ctx())
	while AutoVegetationGenerator.scatter_batch(state, SCATTER_BATCH_POLYS):
		await get_tree().process_frame
		if not _built:
			return
	_auto_veg_layer = state.layer
	_auto_veg_poly_stats = state.poly_stats
	_print_auto_veg_diag(state)
	_apply_auto_veg_edits()
	_growth_init_auto()
	await _rebuild_auto_vegetation_async()


## Single coalesced entry point for the "Tune look… → Apply to map" action.
## Applies BOTH the shape settings (layer + style, so the render's layer-wins
## merge stays consistent) and the style/shader/tint/density in one shot, persists
## once, and schedules exactly ONE rebuild path — instead of the old cascade where
## set_vegetation_settings + set_vegetation_style each queued their own synchronous
## manual + auto rebuilds (~4 full GPU uploads in a frame → spike / silent crash).
func apply_vegetation_look(shape: Dictionary, style: Dictionary) -> void:
	if _vegetation_layer == null:
		return
	var prev := _veg_style.duplicate(true)
	# "Apply to map" restyles EVERY tree of each type. Painted trees can carry a
	# per-instance card_settings override ("Apply to brush") that otherwise wins over
	# the global look forever (it persists to disk), so drop those overrides here so
	# the whole map adopts the new look. Per-brush trees are a paint-time choice; a
	# deliberate global apply is authoritative.
	_vegetation_layer.clear_card_overrides()
	if _auto_veg_layer != null:
		_auto_veg_layer.clear_card_overrides()
	# Phase 2: the style store is the ONE authority for shape — do not write
	# shape into the layer (that created "user deltas" out of unchanged values
	# which then shadowed every later style tune). Erase any stale layer
	# deltas for the keys this apply covers so the new style actually lands.
	_vegetation_layer.erase_settings_keys(shape.keys())
	_veg_style.merge(shape, true)
	_veg_style = VegetationStyleConfig.apply_patch(_veg_style, style)
	_vegetation_layer.save(_lat, _lon)
	VegetationStyleConfig.save_map(_lat, _lon, _veg_style)
	VegetationCardFactory.clear_foot_cache()
	call_deferred("_rebuild_vegetation")
	if _auto_veg_generated and (_forest_params_changed(prev, _veg_style) \
			or _exclusion_buffers_loosened(prev, _veg_style)):
		call_deferred("_full_regenerate_auto_vegetation_async")
	elif _auto_veg_generated and _exclusion_buffers_changed(prev, _veg_style):
		call_deferred("_prune_auto_veg_by_exclusions")
	else:
		call_deferred("_rebuild_auto_vegetation_async")


func get_vegetation_style() -> Dictionary:
	return _veg_style.duplicate(true)


func set_vegetation_style(patch: Dictionary, regen_auto: bool = true, persist: bool = true) -> void:
	var prev := _veg_style.duplicate(true)
	if _is_tint_only_patch(patch):
		_veg_style = VegetationStyleConfig.apply_patch(_veg_style, patch)
		if persist:
			VegetationStyleConfig.save_map(_lat, _lon, _veg_style)
		apply_vegetation_tints_live({})
		return
	_veg_style = VegetationStyleConfig.apply_patch(_veg_style, patch)
	if persist:
		VegetationStyleConfig.save_map(_lat, _lon, _veg_style)
	if regen_auto and _auto_veg_generated:
		if _forest_params_changed(prev, _veg_style) or _exclusion_buffers_loosened(prev, _veg_style):
			call_deferred("_full_regenerate_auto_vegetation_async")
		elif _exclusion_buffers_changed(prev, _veg_style):
			call_deferred("_prune_auto_veg_by_exclusions")
		else:
			call_deferred("_rebuild_auto_vegetation_async")
	else:
		call_deferred("_rebuild_auto_vegetation_async")
	if _vegetation_layer != null:
		call_deferred("_rebuild_vegetation")


func _is_tint_only_patch(patch: Dictionary) -> bool:
	if patch.is_empty():
		return false
	for key in patch:
		if not (str(key).ends_with("_albedo_tint") or str(key).ends_with("_highlight_tint")):
			return false
	return true


func _exclusion_buffers_loosened(prev: Dictionary, next: Dictionary) -> bool:
	if bool(prev.get("building_exclusion_enabled", true)) and not bool(next.get("building_exclusion_enabled", true)):
		return true
	if bool(prev.get("road_exclusion_enabled", true)) and not bool(next.get("road_exclusion_enabled", true)):
		return true
	if float(next.get("building_exclusion_m", 0.0)) < float(prev.get("building_exclusion_m", 0.0)) - 0.01:
		return true
	if float(next.get("road_exclusion_m", 0.0)) < float(prev.get("road_exclusion_m", 0.0)) - 0.01:
		return true
	if float(next.get("water_exclusion_m", 0.0)) < float(prev.get("water_exclusion_m", 0.0)) - 0.01:
		return true
	return false


func _exclusion_buffers_changed(prev: Dictionary, next: Dictionary) -> bool:
	for key in ["building_exclusion_m", "road_exclusion_m", "water_exclusion_m",
			"building_exclusion_enabled", "road_exclusion_enabled"]:
		if key.ends_with("_enabled"):
			if bool(next.get(key, true)) != bool(prev.get(key, true)):
				return true
		elif absf(float(next.get(key, 0.0)) - float(prev.get(key, 0.0))) > 0.01:
			return true
	return false


## Every style key the GENERATOR reads at scatter time. A key listed here forces
## a full re-scatter when it changes; a key the generator reads but NOT listed
## here silently persists without visible effect ("Tune-look doesn't apply").
## Keep in sync with AutoVegetationGenerator.prepare_context/_scatter_* readers.
const _GENERATOR_FLOAT_KEYS: Array[String] = [
	"forest_auto_min_area_m2", "forest_trunk_spacing_m", "forest_canopy_height_m",
	"auto_density_scale", "auto_detail_radius_m", "auto_distant_density",
	"auto_max_tree_instances", "auto_max_grass_instances",
	"forest_edge_feather_m", "slope_max_deg",
	"grass_detail_radius_m", "grass_lawn_card_w",
	"grass_lawn_bulk_scale", "grass_field_bulk_scale",
	"mix_pine", "mix_deciduous", "mix_shrub",
]
const _GENERATOR_BOOL_KEYS: Array[String] = [
	"open_areas_exclude_trees", "scatter_lawn_field",
]


func _forest_params_changed(prev: Dictionary, next: Dictionary) -> bool:
	for key in _GENERATOR_FLOAT_KEYS:
		if absf(float(next.get(key, 0.0)) - float(prev.get(key, 0.0))) > 0.01:
			return true
	for key in _GENERATOR_BOOL_KEYS:
		if bool(next.get(key, true)) != bool(prev.get(key, true)):
			return true
	if _local_mix_changed(prev, next):
		return true
	if _osm_species_map_changed(prev, next):
		return true
	return false


## local_mix (per-species weights for the "mixed" fill) is read at scatter time
## via BiomePalette.mix_weights_from_style — same contract as osm_species_map.
func _local_mix_changed(prev: Dictionary, next: Dictionary) -> bool:
	var a: Dictionary = prev.get("local_mix", {})
	var b: Dictionary = next.get("local_mix", {})
	if a.size() != b.size():
		return true
	for k in b:
		if absf(float(a.get(k, 0.0)) - float(b.get(k, 0.0))) > 0.001:
			return true
	return false


## OSM→species bindings drive which species get scattered per polygon, so any
## change requires a full re-run of the generator (not just a rebuild).
func _osm_species_map_changed(prev: Dictionary, next: Dictionary) -> bool:
	var a: Dictionary = prev.get("osm_species_map", {})
	var b: Dictionary = next.get("osm_species_map", {})
	if a.size() != b.size():
		return true
	for k in b:
		if str(a.get(k, "auto")) != str(b.get(k, "auto")):
			return true
	for k in a:
		if not b.has(k):
			return true
	return false


func _full_regenerate_auto_vegetation() -> void:
	if not _auto_veg_generated or _auto_veg_data.is_empty():
		_rebuild_auto_vegetation()
		return
	var state := AutoVegetationGenerator.prepare_context(_auto_veg_data, _auto_veg_ctx())
	while AutoVegetationGenerator.scatter_batch(state, SCATTER_BATCH_POLYS):
		await get_tree().process_frame
		if not _built:
			return
	_auto_veg_layer = state.layer
	_auto_veg_poly_stats = state.poly_stats
	_print_auto_veg_diag(state)
	_apply_auto_veg_edits()
	_growth_init_auto()
	_rebuild_auto_vegetation()


func _prune_auto_veg_by_exclusions() -> void:
	if _auto_veg_layer == null:
		return
	var excl := _auto_veg_exclusions()
	if excl.is_empty():
		_rebuild_auto_vegetation()
		return
	_prune_layer_by_exclusions(_auto_veg_layer, excl)
	_rebuild_auto_vegetation()


static func _prune_layer_by_exclusions(layer: AutoVegetationLayer, exclusions: Array) -> void:
	for slot in layer.bulk.keys():
		var kept: Array = []
		for item in layer.bulk.get(slot, []):
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
			if not VegExclusionBuilder.point_excluded(pt, exclusions):
				kept.append(d)
		layer.bulk[slot] = kept
	var hero_kept: Array = []
	for item in layer.hero:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
		if not VegExclusionBuilder.point_excluded(pt, exclusions):
			hero_kept.append(d)
	layer.hero = hero_kept


func _clear_auto_vegetation() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain != null:
		AutoVegetationRuntime.clear(terrain)


## Re-sample all vegetation (manual + auto) against the current hi-res footing grid.
func reground_all_vegetation() -> void:
	_reground_vegetation()
	if _auto_veg_generated:
		_reground_auto_vegetation()


func _reground_auto_vegetation() -> void:
	if _auto_veg_layer == null or _main == null:
		return
	for item in _auto_veg_layer.hero:
		if item is Dictionary:
			var d: Dictionary = item
			d["ground_y"] = _ground_height_at(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
	_rebuild_auto_vegetation()


func set_show_auto_vegetation(on: bool) -> void:
	_save_terrain_config_value("show_auto_vegetation", on)
	if not _built:
		return
	if not on:
		_auto_veg_generated = false
		_clear_auto_vegetation()
	elif not _auto_veg_data.is_empty():
		_queue_auto_veg_generate(false)
	else:
		_request_auto_vegetation()


func populate_vegetation(poly: PackedVector2Array, params: Dictionary) -> int:
	if _vegetation_layer == null or poly.size() < 3:
		return 0
	_vegetation_layer.ensure_species_keys()
	if VegetationPaint.polygon_area(poly) < 4.0:
		return 0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 1337)) ^ int(_lat * 10000.0) ^ int(_lon * 10000.0)
	var preset: int = int(params.get("preset", VegetationPaint.Preset.SHRUB))
	var preset_enum := preset as VegetationPaint.Preset
	var spacing := maxf(float(params.get("spacing_m", VegetationPaint.default_spacing_for_preset(preset_enum))), 0.35)
	var scale_min := float(params.get("scale_min", 0.85))
	var scale_max := float(params.get("scale_max", 1.25))
	if preset_enum == VegetationPaint.Preset.GRASS_LAWN or preset_enum == VegetationPaint.Preset.GRASS_FIELD:
		scale_min = float(params.get("scale_min", 0.75))
		scale_max = float(params.get("scale_max", 1.15))
	var existing := _vegetation_layer.all_placement_points()
	var area := VegetationPaint.polygon_area(poly)
	var fill_cap := VegetationPaint.fill_cap_for_preset(preset_enum)
	var cap := mini(_vegetation_layer.remaining_bulk_capacity(), fill_cap)
	if cap <= 0:
		return 0
	var spots: Array[Dictionary]
	if preset_enum == VegetationPaint.Preset.GRASS_LAWN:
		var mat_w := float(_veg_style.get("grass_lawn_card_w", 0.45))
		var est := VegetationPaint.estimate_square_fill_count(poly, mat_w, fill_cap)
		cap = mini(cap, est)
		spots = VegetationPaint.square_grid_fill(poly, mat_w, existing, cap)
		scale_min = 1.0
		scale_max = 1.0
	else:
		var est_slots := int(area / (spacing * spacing * 0.866)) + 8
		cap = mini(mini(est_slots, fill_cap), cap)
		spots = VegetationPaint.poisson_fill(poly, spacing, rng, existing, cap)
	# Optional per-brush look snapshot ("Apply to brush"): stamped onto every new
	# instance so these trees keep their custom look regardless of later map edits.
	var brush_card: Dictionary = params.get("card_settings", {}) if params.get("card_settings") is Dictionary else {}
	var forced_species := str(params.get("species", ""))
	var use_forced := not forced_species.is_empty() and VegSpeciesCatalog.is_paintable(forced_species)
	var added := 0
	for spot in spots:
		var species := forced_species if use_forced else VegetationPaint.pick_species(
			preset_enum,
			float(params.get("mix_pine", 0.3)),
			float(params.get("mix_deciduous", 0.3)),
			float(params.get("mix_shrub", 0.2)), rng,
			float(params.get("mix_grass_lawn", 0.1)),
			float(params.get("mix_grass_field", 0.1)))
		var yaw := 0.0 if preset_enum == VegetationPaint.Preset.GRASS_LAWN \
			else rng.randf() * TAU
		var scale := 1.0 if preset_enum == VegetationPaint.Preset.GRASS_LAWN \
			else lerpf(scale_min, scale_max, rng.randf())
		if _vegetation_layer.add_bulk(species, float(spot["x"]), float(spot["z"]), yaw, scale, brush_card):
			added += 1
	if added > 0:
		if preset_enum != VegetationPaint.Preset.GRASS_LAWN \
				and preset_enum != VegetationPaint.Preset.GRASS_FIELD:
			_vegetation_layer.add_growth_zone(poly)
		_growth_after_manual_edit()
		_vegetation_layer.save(_lat, _lon)
		_rebuild_vegetation()
	return added


## Drop a SINGLE bulk instance of `species` at (x, z) — the paint dock's
## single-click (no-drag) placement. Scale/yaw come from the same params as a
## scatter so a solo tree matches the brush; an optional card_settings snapshot
## ("Apply to brush") is carried through. Returns true if placed.
func place_single_vegetation(species: String, x: float, z: float, params: Dictionary = {}) -> bool:
	if _vegetation_layer == null:
		return false
	_vegetation_layer.ensure_species_keys()
	if species.is_empty() or not VegSpeciesCatalog.is_paintable(species):
		return false
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 1337)) ^ int(x * 131.0) ^ int(z * 977.0)
	var is_lawn := species == "grass_lawn"
	var scale_min := float(params.get("scale_min", 0.85))
	var scale_max := float(params.get("scale_max", 1.25))
	var yaw := 0.0 if is_lawn else rng.randf() * TAU
	var scale := 1.0 if is_lawn else lerpf(scale_min, scale_max, rng.randf())
	var brush_card: Dictionary = params.get("card_settings", {}) if params.get("card_settings") is Dictionary else {}
	if not _vegetation_layer.add_bulk(species, x, z, yaw, scale, brush_card):
		return false
	# A single deliberate drop is planted as a seedling (birth = now) so the player
	# can watch this one grow from scratch, rather than the established age mix a
	# paint scatter gets. Cap refresh keeps reseeding density honest.
	if _growth_any_enabled():
		(_vegetation_layer.bulk[species] as Array).back()["birth_h"] = _growth_clock_h
		_growth_caps_manual = VegetationGrowth.capture_caps(_vegetation_layer.bulk)
	_vegetation_layer.save(_lat, _lon)
	_rebuild_vegetation()
	return true


func clear_vegetation_in_polygon(poly: PackedVector2Array) -> void:
	if _vegetation_layer == null or poly.size() < 3:
		return
	_vegetation_layer.remove_bulk_in_polygon(poly)
	_vegetation_layer.save(_lat, _lon)
	_rebuild_vegetation()


func count_manual_bulk_in_polygon(poly: PackedVector2Array) -> int:
	if _vegetation_layer == null:
		return 0
	return _vegetation_layer.count_bulk_in_polygon(poly)


func count_all_bulk_in_polygon(poly: PackedVector2Array) -> int:
	var n := count_manual_bulk_in_polygon(poly)
	if _auto_veg_layer != null and _auto_veg_generated:
		n += _auto_veg_layer.count_bulk_in_polygon(poly)
	return n


## Replace species/mix inside a locked selection: clear bulk (manual + auto) and re-scatter.
func respecies_selection(poly: PackedVector2Array, params: Dictionary) -> int:
	if _vegetation_layer == null or poly.size() < 3:
		return 0
	var prior := count_all_bulk_in_polygon(poly)
	var area := VegetationPaint.polygon_area(poly)
	var spacing := float(params.get("spacing_m", 4.0))
	if prior > 0 and area > 4.0:
		var derived := sqrt(area / (float(prior) * 0.866))
		spacing = clampf(derived, 0.4, 16.0)
		params = params.duplicate(true)
		params["spacing_m"] = spacing
	clear_vegetation_in_polygon(poly)
	clear_auto_vegetation_in_polygon(poly)
	return populate_vegetation(poly, params)


## Frame-chunked respecies for large selections (yields between clear and scatter).
func respecies_selection_async(poly: PackedVector2Array, params: Dictionary) -> int:
	if _vegetation_layer == null or poly.size() < 3:
		return 0
	vegetation_operation_progress.emit("Preparing re-scatter…", 0.05)
	var prior := count_all_bulk_in_polygon(poly)
	var area := VegetationPaint.polygon_area(poly)
	var scatter_params := params.duplicate(true)
	var spacing := float(scatter_params.get("spacing_m", 4.0))
	if prior > 0 and area > 4.0:
		var derived := sqrt(area / (float(prior) * 0.866))
		spacing = clampf(derived, 0.4, 16.0)
		scatter_params["spacing_m"] = spacing
	vegetation_operation_progress.emit("Clearing existing vegetation…", 0.2)
	clear_vegetation_in_polygon(poly)
	clear_auto_vegetation_in_polygon(poly)
	await get_tree().process_frame
	vegetation_operation_progress.emit("Scattering new vegetation…", 0.5)
	var added := populate_vegetation(poly, scatter_params)
	vegetation_operation_progress.emit("Done — %d instances" % added, 1.0)
	return added


func apply_vegetation_tints_live(patch: Dictionary) -> void:
	if not patch.is_empty():
		_veg_style = VegetationStyleConfig.apply_patch(_veg_style, patch)
	var tree := get_tree()
	if tree == null:
		return
	var env := tree.root.get_node_or_null("VegetationEnvironmentSync")
	if env == null or not env.has_method("apply_species_tints"):
		call_deferred("_rebuild_vegetation")
		call_deferred("_rebuild_auto_vegetation")
		return
	for species in VegetationLayer.ALL_SPECIES:
		var albedo_key := "%s_albedo_tint" % species
		var hi_key := "%s_highlight_tint" % species
		var albedo: Color = _veg_style.get(albedo_key, Color.WHITE)
		var hi: Color = _veg_style.get(hi_key, Color.WHITE)
		env.call("apply_species_tints", species, albedo, hi)


func place_hero_tree(preset: String, x: float, z: float, scale: float,
		ground_y: float = NAN) -> bool:
	if _vegetation_layer == null:
		return false
	var rng := RandomNumberGenerator.new()
	var yaw := rng.randf() * TAU
	var gy := ground_y
	if is_nan(gy):
		gy = _ground_height_at(x, z)
	if not _vegetation_layer.add_hero(preset, x, z, yaw, scale, gy):
		return false
	_vegetation_layer.save(_lat, _lon)
	call_deferred("_rebuild_vegetation")
	return true


func delete_nearest_hero(world_xz: Vector2) -> bool:
	if _vegetation_layer == null:
		return false
	if not _vegetation_layer.remove_nearest_hero(world_xz):
		return false
	_vegetation_layer.save(_lat, _lon)
	_rebuild_vegetation()
	return true


func update_vegetation_highlight(poly: PackedVector2Array,
		color: Color = Color(0.2, 0.9, 0.4, 0.42), fast_preview: bool = false) -> void:
	if _main == null or poly.size() < 3:
		_clear_veg_highlight()
		return
	var poly_hash := _poly_hash(poly)
	var color_hash := int(color.r * 1000.0) + int(color.g * 1000.0) + int(color.b * 1000.0)
	# Live drag previews must rebuild every frame — hash dedup left a stuck min-radius mesh.
	if not fast_preview and poly_hash == _last_veg_poly_hash \
			and color_hash == _last_veg_highlight_color_hash \
			and _veg_highlight != null and _veg_highlight.visible:
		return
	_last_veg_poly_hash = poly_hash
	_last_veg_highlight_color_hash = color_hash
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	if _veg_highlight == null:
		_veg_highlight = MeshInstance3D.new()
		_veg_highlight.name = "VegetationSelectionHighlight"
		terrain.add_child(_veg_highlight)
	if _veg_highlight.material_override == null or not (_veg_highlight.material_override is StandardMaterial3D):
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_veg_highlight.material_override = mat
	var hl_mat := _veg_highlight.material_override as StandardMaterial3D
	hl_mat.albedo_color = color
	var footing := _highlight_footing_grid(fast_preview)
	_veg_highlight.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev)
	_veg_highlight.visible = true


## Cached detail-surface grid for fast highlight draping (no per-tick recompose).
func _ensure_detail_surface_cache(apply_user_edits: bool = true) -> void:
	if _detail_surface_grid.is_empty() and _detail_elev_done and not _detail_elev_grid.is_empty():
		_detail_surface_grid = _compose_detail_surface(apply_user_edits)


func _highlight_footing_grid(fast_preview: bool) -> Dictionary:
	var use_grid := _built_grid
	var use_res := MESH_RES
	var use_extent := _built_extent
	if fast_preview:
		_ensure_detail_surface_cache(true)
		if not _detail_surface_grid.is_empty():
			use_grid = _detail_surface_grid
			use_res = _detail_elev_cols
			use_extent = _detail_extent_m()
	else:
		var detail := _compose_detail_surface(false)
		if not detail.is_empty():
			_detail_surface_grid = detail
			use_grid = detail
			use_res = _detail_elev_cols
			use_extent = _detail_extent_m()
	return {"grid": use_grid, "res": use_res, "extent": use_extent}


func _poly_hash(poly: PackedVector2Array) -> int:
	var h := poly.size()
	for i in poly.size():
		h = h * 31 + int(snappedf(poly[i].x, 0.01) * 100.0)
		h = h * 31 + int(snappedf(poly[i].y, 0.01) * 100.0)
	return h


func clear_vegetation_highlight() -> void:
	_clear_veg_highlight()


func reset_vegetation_highlight_cache() -> void:
	_last_veg_poly_hash = 0
	_last_veg_highlight_color_hash = 0


func _clear_veg_highlight() -> void:
	_last_veg_poly_hash = 0
	_last_veg_highlight_color_hash = 0
	if _veg_highlight != null:
		_veg_highlight.visible = false


func _setup_terrain_edit_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var edit_ui := Control.new()
	edit_ui.name = "TerrainEditUI"
	edit_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	edit_ui.set_script(TERRAIN_EDIT_UI_SCRIPT)
	ui_layer.add_child(edit_ui)
	edit_ui.bind_loader(self)
	_terrain_edit_ui = edit_ui


func terrain_pick_ray(screen_pos: Vector2) -> Variant:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _main == null:
		return null
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(_main, cam, screen_pos)
	if hit.is_empty():
		return null
	return hit["position"]


func apply_sculpt_op(op: String, rect_min: Vector2, rect_max: Vector2,
		falloff_m: float, amount_m: float, level_y: float) -> void:
	if _terrain_edits == null or _base_dem_grid.is_empty():
		return
	var work := _compose_base_footing_grid(false)
	var value := amount_m
	if op == "level":
		value = _mean_local_height_in_rect(work, rect_min, rect_max)
		if level_y != 0.0:
			value = level_y - _built_center_elev
	TerrainSculpt.apply_rect(_terrain_edits.delta, MESH_RES, _built_extent,
		rect_min, rect_max, op, value, falloff_m, work, _built_center_elev)
	_terrain_edits.save(_lat, _lon)
	_rebuild_heightfield()
	update_selection_highlight(rect_min, rect_max)


## ---------------------------------------------------------------------------
## Live brush/shape sculpt (terrain_edit_ui). Precision detail-patch layer.
## ---------------------------------------------------------------------------

## True when the detail patch exists — sculpting authors the hi-res detail delta.
func can_sculpt_detail() -> bool:
	return not _detail_surface_grid.is_empty() and _detail_elev_cols >= 2 \
		and _terrain_edits != null


func sculpt_detail_res() -> int:
	return _detail_elev_cols


## Snapshot the user water bodies for undo (Rain/Drain / designated ponds). The
## high-res terrain layer has its own region-scoped tile-undo entries.
func _push_sculpt_undo() -> void:
	_sculpt_undo_stack.append({"user_water": _user_water_data.duplicate(true)})
	while _sculpt_undo_stack.size() > SCULPT_UNDO_MAX:
		_sculpt_undo_stack.pop_front()


## Public entry for the terrain dock (Rain/Drain undo, etc.).
func push_sculpt_undo() -> void:
	_push_sculpt_undo()


## Begin a high-res tile edit (brush stroke, level, pond carve). Pairs with
## end_terrain_tile_edit(); everything written to the tile layer in between is one
## undo step.
func begin_terrain_tile_edit() -> void:
	_ensure_edit_tiles()
	_edit_tiles.begin_session()


## Close the current tile edit, push it as a single (region-scoped) undo entry,
## re-mesh the touched tiles, and autosave.
func end_terrain_tile_edit() -> void:
	if _edit_tiles == null:
		return
	var snap := _edit_tiles.end_session()
	if not snap.is_empty():
		_sculpt_undo_stack.append({"tiles": snap})
		while _sculpt_undo_stack.size() > SCULPT_UNDO_MAX:
			_sculpt_undo_stack.pop_front()
	# Commit: tile meshes + colliders must be live BEFORE the DetailGround
	# collider sinks beneath them, or an actor in the area has nothing to
	# stand on for a frame.
	if _height_field != null:
		_height_field.reconcile_dirty_now()
	_refresh_detail_sink()
	_save_edit_tiles()
	_reseat_actors_after_edit()


# ---------------------------------------------------------------------------
# High-res sculpt commands (Phase 2 tools call these). Brush stamps run inside a
# stroke session (UI calls begin/end around the drag); one-shot region ops manage
# their own session.
# ---------------------------------------------------------------------------

func _ensure_edit_tiles() -> void:
	if _edit_tiles == null:
		_edit_tiles = TerrainEditTiles.new()
	if _height_field == null or not is_instance_valid(_height_field):
		var terrain := _main.get_node_or_null("Terrain") as Node3D if _main != null else null
		if terrain != null:
			_ensure_height_field(terrain)


## One brush stamp (called each stroke frame between begin/end_terrain_tile_edit).
func brush_stamp(mode: String, world: Vector3, radius: float, amount: float,
		hardness: float, target_y: float = NAN) -> void:
	_ensure_edit_tiles()
	if _edit_tiles == null:
		return
	var c := Vector2(world.x, world.z)
	var base_fn := Callable(self, "_height_field_base")
	match mode:
		"raise":
			TerrainSculptOps.raise_lower_brush(_edit_tiles, c, radius, absf(amount), hardness)
		"lower":
			TerrainSculptOps.raise_lower_brush(_edit_tiles, c, radius, -absf(amount), hardness)
		"smooth":
			TerrainSculptOps.smooth_brush(_edit_tiles, c, radius, amount, base_fn, hardness)
		"flatten":
			var ty := target_y if is_finite(target_y) else _height_field_base(world.x, world.z)
			TerrainSculptOps.flatten_brush(_edit_tiles, c, radius, ty, amount, base_fn, hardness)
	# Live feedback: only the touched tiles re-mesh (same frame, bounded budget).
	if _height_field != null:
		_height_field.queue_dirty()
	# When the stroke spills into a NEW tile, sink the DetailGround under it right
	# away — otherwise a Lower/Pond cut stays hidden under the coarse mesh until
	# mouse-up. No-op while the tile set is unchanged (signature short-circuit).
	_refresh_detail_sink()


## Level a polygon to an absolute Y (one undo step).
func level_region_command(poly: PackedVector2Array, target_y: float,
		feather_m: float) -> void:
	_ensure_edit_tiles()
	if _edit_tiles == null or poly.size() < 3:
		return
	begin_terrain_tile_edit()
	TerrainSculptOps.level_polygon(_edit_tiles, poly, target_y, feather_m,
		Callable(self, "_height_field_base"))
	end_terrain_tile_edit()


## Grade a ramp between two world points (endpoints snap to current surface).
func ramp_command(a: Vector3, b: Vector3, width_m: float) -> void:
	_ensure_edit_tiles()
	if _edit_tiles == null:
		return
	var ya := ground_height_at(a.x, a.z)
	var yb := ground_height_at(b.x, b.z)
	begin_terrain_tile_edit()
	TerrainSculptOps.ramp(_edit_tiles, Vector2(a.x, a.z), Vector2(b.x, b.z),
		ya, yb, width_m, Callable(self, "_height_field_base"))
	end_terrain_tile_edit()


## Lasso a pond: carve a bowl `depth` m deep. Optionally seeds a thin puddle
## (`seed_puddle`); use Rain tool to fill. Carve + optional water share one undo.
func pond_command(poly: PackedVector2Array, depth: float,
		label: String = "Sculpted Pond", _fill_frac: float = 0.85,
		seed_puddle: bool = true) -> bool:
	_ensure_edit_tiles()
	if _edit_tiles == null or poly.size() < 3:
		return false
	# Check the water-body minimum BEFORE carving, so a too-small lasso doesn't
	# dig a dry hole that then fails to fill.
	if BuildingBuilder.footprint_area_m2(poly) < WaterBuilder.MIN_AREA_M2:
		_notify_options_status(
			"Pond too small (min ~%.0f m²) — draw a larger outline" % WaterBuilder.MIN_AREA_M2,
			"warn")
		return false
	var water_before: Array = _user_water_data.duplicate(true)
	begin_terrain_tile_edit()
	var rim := TerrainSculptOps.carve_basin(_edit_tiles, poly, depth, 2.0,
		Callable(self, "_height_field_base"))
	end_terrain_tile_edit()
	if is_nan(rim):
		return false
	var floor_y := rim - maxf(depth, 0.1)
	var tag := EarthworksBuilder.basin_tag_from_poly(poly)
	if seed_puddle:
		var level := floor_y + 0.05
		if not designate_sculpted_pond(poly, label, level, tag):
			# Carve still succeeded — leave dry basin.
			pass
	# Fold the pre-pond water state into the carve's undo entry so ONE Undo
	# reverts both the bowl and its water.
	if not _sculpt_undo_stack.is_empty():
		var last: Variant = _sculpt_undo_stack.back()
		if last is Dictionary and (last as Dictionary).has("tiles"):
			(last as Dictionary)["user_water"] = water_before
	return true


func can_undo_terrain_sculpt() -> bool:
	return not _sculpt_undo_stack.is_empty()


func undo_terrain_sculpt() -> bool:
	if _sculpt_undo_stack.is_empty():
		return false
	var snap: Variant = _sculpt_undo_stack.pop_back()
	var handled := false
	if snap is Dictionary and (snap as Dictionary).has("tiles"):
		# Region-scoped tile-layer undo (the high-res editor). Cheap: only the
		# touched tiles are restored + re-meshed. Reconcile immediately so the
		# tile colliders match before the DetailGround sink refresh + reseat.
		if _edit_tiles != null:
			_edit_tiles.apply_snapshot((snap as Dictionary)["tiles"])
			_edit_tiles.prune_flat_tiles()
			if _height_field != null:
				_height_field.reconcile_dirty_now()
			_refresh_detail_sink()
			_save_edit_tiles()
			_reseat_actors_after_edit()
		handled = true
	if snap is Dictionary and (snap as Dictionary).has("user_water"):
		# Water-body undo (Rain/Drain / pond — may ride the same entry as tiles
		# so one Undo reverts a pond's carve AND its water together).
		_user_water_data = ((snap as Dictionary).get("user_water", []) as Array).duplicate(true)
		_save_user_water()
		_refresh_water_data()
		_attach_water()
		handled = true
	return handled


## Open a sculpt session (drone edit-camera meta on). The high-res tile layer is
## live and self-persisting; there's no legacy preview to prime anymore.
func begin_sculpt_session() -> void:
	_sculpt_session = true
	_set_drone_sculpt_session_meta(true)


## Close the sculpt session: drop the selection highlight and persist the tiles.
func end_sculpt_session() -> void:
	_sculpt_session = false
	_set_drone_sculpt_session_meta(false)
	clear_sculpt_selection_highlight()
	_save_edit_tiles()


func _set_drone_sculpt_session_meta(on: bool) -> void:
	if _main == null:
		return
	var drone := _main.get_node_or_null("FPVDrone")
	if drone != null:
		drone.set_meta("terrain_sculpt_session", on)


## ---------------------------------------------------------------------------
## Selection highlight (used by Level / Pond / Rain / Drain) + clear-all
## ---------------------------------------------------------------------------

func update_sculpt_selection_highlight(poly: PackedVector2Array) -> void:
	if _main == null or poly.size() < 3:
		clear_sculpt_selection_highlight()
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	if _sculpt_highlight == null or not is_instance_valid(_sculpt_highlight):
		_sculpt_highlight = MeshInstance3D.new()
		_sculpt_highlight.name = "SculptSelectionHighlight"
		terrain.add_child(_sculpt_highlight)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_color = Color(0.35, 0.85, 1.0, 0.45)
		_sculpt_highlight.material_override = mat
	var footing := _highlight_footing_grid(true)
	_sculpt_highlight.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev)
	_sculpt_highlight.visible = true


func clear_sculpt_selection_highlight() -> void:
	if _sculpt_highlight != null and is_instance_valid(_sculpt_highlight):
		_sculpt_highlight.visible = false
		_sculpt_highlight.mesh = null


## Samples the composed DEM footing (base for the high-res tile layer).
## Composed base surface height (world Y) WITHOUT the high-res tile edits — the
## surface that tool deltas are measured against (so applying a delta never double
## counts prior edits).
func _dem_height_without_earthworks(x: float, z: float) -> float:
	var detail := _detail_footing_grid()
	var in_detail := absf(x) <= _detail_half_extent and absf(z) <= _detail_half_extent
	var fallback := PackedFloat32Array()
	if in_detail and detail.is_empty() and _detail_elev_resolved:
		fallback = _compose_base_footing_grid(true)
	var y := TerrainBuilder.sample_footing_height(
		x, z, _built_grid, MESH_RES, _built_extent, _built_center_elev,
		detail, _detail_elev_cols, _detail_elev_rows, _detail_extent_m(),
		fallback)
	if _built_grid.is_empty() and detail.is_empty():
		return _spawn_ground_y
	return y


func _earthworks_path() -> String:
	return "user://maps/earthworks_%s_%s.json" % [
		TerrainEditGrid._coord_token(_lat), TerrainEditGrid._coord_token(_lon)]


func _load_earthworks() -> void:
	_earthworks = []
	var path := _earthworks_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	for entry in ((parsed as Dictionary).get("items", []) as Array):
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var pts := PackedVector2Array()
		for pv in (e.get("points", []) as Array):
			if pv is Array and (pv as Array).size() >= 2:
				pts.append(Vector2(float(pv[0]), float(pv[1])))
		if pts.size() < 3:
			continue
		_earthworks.append({
			"tag": str(e.get("tag", "")),
			"kind": str(e.get("kind", "raise")),
			"points": pts,
			"height_m": float(e.get("height_m", 1.0)),
			"slope": float(e.get("slope", 0.0)),
			"round": float(e.get("round", 1.0)),
			"top_y": float(e.get("top_y", 0.0)),
			"floor_y": float(e.get("floor_y", 0.0)),
			"rim_y": float(e.get("rim_y", 0.0)),
		})


func _save_earthworks() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var items: Array = []
	for rec_v in _earthworks:
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var pts: PackedVector2Array = rec.get("points", PackedVector2Array())
		var arr: Array = []
		for p in pts:
			arr.append([p.x, p.y])
		items.append({
			"tag": str(rec.get("tag", "")),
			"kind": str(rec.get("kind", "raise")),
			"points": arr,
			"height_m": float(rec.get("height_m", 1.0)),
			"slope": float(rec.get("slope", 0.0)),
			"round": float(rec.get("round", 1.0)),
			"top_y": float(rec.get("top_y", 0.0)),
			"floor_y": float(rec.get("floor_y", 0.0)),
			"rim_y": float(rec.get("rim_y", 0.0)),
		})
	var f := FileAccess.open(_earthworks_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"version": 1, "items": items}))


## Wipe all user terrain adjustments (high-res tile edits + legacy delta grids +
## sculpted/gravity ponds).
func clear_all_terrain_edits() -> void:
	if _terrain_edits != null:
		_terrain_edits.delta.fill(0.0)
		if not _terrain_edits.detail_delta.is_empty():
			_terrain_edits.detail_delta.fill(0.0)
		_terrain_edits.save(_lat, _lon)
	if _edit_tiles != null:
		_edit_tiles.clear()
		_save_edit_tiles()
	if _height_field != null:
		_height_field.clear_all()
	_detail_sink_sig = ""
	_earthworks.clear()
	_free_all_earthwork_nodes()
	_save_earthworks()
	# Remove any pond graph nodes the player added before clearing the water bodies,
	# so cleared ponds never leave orphaned catchment/tank items behind.
	var graph := _find_system_graph_view()
	if graph != null and graph.has_method("remove_imported_pond"):
		for uw in _user_water_data:
			if uw is Dictionary:
				var utag := str((uw as Dictionary).get("tag", ""))
				if not utag.is_empty():
					graph.call("remove_imported_pond", utag)
	_added_pond_tags.clear()
	_user_water_data.clear()
	_save_user_water()
	_refresh_water_data()
	_sculpt_undo_stack.clear()
	clear_sculpt_selection_highlight()
	_rebuild_heightfield(false, false)
	_notify_options_status("Cleared all terrain edits", "ok")


## Free any leftover legacy "Earthworks" node (created by the retired push/pull
## tool); nothing creates it anymore, but old scenes may still carry one.
func _free_all_earthwork_nodes() -> void:
	var terrain := _main.get_node_or_null("Terrain") if _main != null else null
	if terrain == null:
		return
	var root := terrain.get_node_or_null("Earthworks")
	if root != null:
		root.queue_free()


## Pond spill rim (world Y) — lowest outline elevation (matches carve_basin).
func pond_rim_height(poly: PackedVector2Array) -> float:
	if poly.is_empty():
		return 0.0
	var rim := INF
	for p in poly:
		rim = minf(rim, ground_height_at(p.x, p.y))
	return rim if is_finite(rim) else 0.0


## Sample DEM+tiles inside the footprint: floor = min interior, rim = lowest
## outline (spill). Used by the pond modal so carved bowls aren't clamped wrong.
func sample_pond_basin_elevations(poly: PackedVector2Array) -> Dictionary:
	var out := {"rim_m": 0.0, "floor_m": 0.0}
	if poly.size() < 3:
		return out
	var rim := pond_rim_height(poly)
	var floor_y := rim
	var aabb := Rect2(poly[0], Vector2.ZERO)
	for i in range(1, poly.size()):
		aabb = aabb.expand(poly[i])
	var cell := clampf(sqrt(maxf(aabb.size.x * aabb.size.y, 1.0)) / 32.0, 1.0, 4.0)
	var x := aabb.position.x
	while x <= aabb.end.x + 1e-4:
		var z := aabb.position.y
		while z <= aabb.end.y + 1e-4:
			var p := Vector2(x, z)
			if Geometry2D.is_point_in_polygon(p, poly):
				floor_y = minf(floor_y, ground_height_at(p.x, p.y))
			z += cell
		x += cell
	# Also consider outline verts (bank tops / floors near edge).
	for p in poly:
		floor_y = minf(floor_y, ground_height_at(p.x, p.y))
	if floor_y > rim - 0.05:
		floor_y = rim - 0.05
	out["rim_m"] = rim
	out["floor_m"] = floor_y
	return out


## Gravity-fill closed depressions inside a selection polygon (circle/rect/lasso…).
## Water finds natural spill elevations per pit — like rain ponding in a basin.
## Returns the number of water bodies created.
func fill_selection_depressions(poly: PackedVector2Array, fill_frac: float = 0.85) -> int:
	if poly.size() < 3:
		return 0
	var area := BuildingBuilder.footprint_area_m2(poly)
	# Same gate as WaterBuilder / designate — avoid "found then fail to mesh".
	if area < WaterBuilder.MIN_AREA_M2:
		_notify_options_status(
			"Selection too small to flood (min ~%.0f m²)" % WaterBuilder.MIN_AREA_M2, "warn")
		return 0
	# Cell size scales with selection so large circles stay interactive.
	var cell := clampf(sqrt(area) / 48.0, 1.25, 4.0)
	var height_at := Callable(self, "ground_height_at")
	var bodies: Array = Watershed.fill_depressions_in_polygon(
		poly, height_at, fill_frac, cell, 0.10, WaterBuilder.MIN_AREA_M2)
	if bodies.is_empty():
		_notify_options_status(
			"No closed depressions in selection — dig a basin (Pond) or pick a lower area",
			"warn")
		return 0
	var added := 0
	for i in bodies.size():
		var body: Dictionary = bodies[i]
		var pts: PackedVector2Array = body.get("points", PackedVector2Array())
		var level := float(body.get("level_m", NAN))
		var tag := "grav_pond_%d_%d_%d" % [
			roundi(SolarArrayBuilder.centroid(pts).x),
			roundi(SolarArrayBuilder.centroid(pts).y),
			i]
		var label := "Pond" if bodies.size() == 1 else "Pond %d" % (i + 1)
		if designate_sculpted_pond(pts, label, level, tag):
			added += 1
	if added > 0:
		_notify_options_status(
			"Filled %d depression%s — Ctrl-click pond → Add to graph" % [
				added, "" if added == 1 else "s"],
			"ok")
	return added


## Analyze the primary closed basin under a selection (no mesh mutation).
## Returns `{valid, reason, floor_m, spill_m, area_m2, capacity_l, stock_l,
## level_m, fill_frac, tag?, water_idx?, points}`.
func analyze_selection_basin(poly: PackedVector2Array) -> Dictionary:
	var out := {
		"valid": false, "reason": "no_closed_basin",
		"floor_m": 0.0, "spill_m": 0.0, "area_m2": 0.0,
		"capacity_l": 0.0, "stock_l": 0.0, "level_m": 0.0, "fill_frac": 0.0,
		"tag": "", "water_idx": -1, "points": PackedVector2Array(),
	}
	if poly.size() < 3:
		out["reason"] = "too_small"
		return out
	var sel_area := BuildingBuilder.footprint_area_m2(poly)
	if sel_area < WaterBuilder.MIN_AREA_M2:
		out["reason"] = "too_small"
		out["area_m2"] = sel_area
		return out
	# Prefer an existing user pond whose centroid lies in the selection.
	var existing := _find_user_pond_in_selection(poly)
	if not existing.is_empty():
		var rec: Dictionary = existing["rec"]
		_recompute_pond_volume_rec(rec, false)
		var epoly: PackedVector2Array = rec.get("points", PackedVector2Array())
		out["valid"] = true
		out["reason"] = ""
		out["floor_m"] = float(rec.get("floor_m", 0.0))
		out["spill_m"] = float(rec.get("spill_m", 0.0))
		out["area_m2"] = BuildingBuilder.footprint_area_m2(epoly)
		out["capacity_l"] = float(rec.get("capacity_l", 0.0))
		out["stock_l"] = float(rec.get("stock_l", 0.0))
		out["level_m"] = float(rec.get("level_m", out["floor_m"]))
		out["fill_frac"] = PondBathymetry.fill_frac(
			float(out["stock_l"]), float(out["capacity_l"]))
		out["tag"] = str(rec.get("tag", ""))
		out["water_idx"] = int(existing.get("water_idx", -1))
		out["points"] = epoly
		return out
	var cell := PondBathymetry.suggested_cell_m(sel_area)
	var diag := Watershed.analyze_primary_basin(
		poly, Callable(self, "ground_height_at"), cell, 0.10, WaterBuilder.MIN_AREA_M2)
	if not bool(diag.get("valid", false)):
		out["reason"] = str(diag.get("reason", "no_closed_basin"))
		out["floor_m"] = float(diag.get("floor_m", 0.0))
		out["spill_m"] = float(diag.get("spill_m", 0.0))
		out["area_m2"] = float(diag.get("area_m2", sel_area))
		out["depth_m"] = float(diag.get("depth_m", 0.0))
		return out
	var basin_poly: PackedVector2Array = diag.get("points", PackedVector2Array())
	if basin_poly.size() < 3:
		basin_poly = poly
	var floor_m := float(diag.get("floor_m", 0.0))
	var spill_m := float(diag.get("spill_m", floor_m))
	var height_at := Callable(self, "ground_height_at")
	var cap := PondBathymetry.capacity_l(basin_poly, height_at, spill_m)
	out["valid"] = true
	out["reason"] = ""
	out["floor_m"] = floor_m
	out["spill_m"] = spill_m
	out["area_m2"] = float(diag.get("area_m2", BuildingBuilder.footprint_area_m2(basin_poly)))
	out["capacity_l"] = cap
	out["stock_l"] = 0.0
	out["level_m"] = floor_m
	out["fill_frac"] = 0.0
	out["points"] = basin_poly
	out["depth_m"] = spill_m - floor_m
	return out


## Raise water in the primary basin under `poly` by `delta_m` (surface rise).
## Creates a user pond at floor+ε if none exists. Clamps to spill − freeboard.
func rain_selection(poly: PackedVector2Array, delta_m: float) -> Dictionary:
	var analysis := analyze_selection_basin(poly)
	if not bool(analysis.get("valid", false)):
		return {"ok": false, "reason": str(analysis.get("reason", "no_closed_basin")),
			"depth_m": float(analysis.get("depth_m", 0.0)),
			"area_m2": float(analysis.get("area_m2", 0.0))}
	var floor_m := float(analysis.get("floor_m", 0.0))
	var spill_m := float(analysis.get("spill_m", floor_m + 1.0))
	var freeboard := PondBathymetry.FREEBOARD_DEFAULT_M
	var max_level := spill_m - freeboard
	var tag := str(analysis.get("tag", ""))
	var water_idx := int(analysis.get("water_idx", -1))
	var basin_poly: PackedVector2Array = analysis.get("points", poly)
	var level := float(analysis.get("level_m", floor_m))
	var stock_before := float(analysis.get("stock_l", 0.0))
	if tag.is_empty() or water_idx < 0:
		# Seed a thin puddle, then raise by delta.
		level = floor_m + 0.05
		tag = "grav_pond_%d_%d" % [
			roundi(SolarArrayBuilder.centroid(basin_poly).x),
			roundi(SolarArrayBuilder.centroid(basin_poly).y)]
		if not designate_sculpted_pond(basin_poly, "Pond", level, tag):
			return {"ok": false, "reason": "too_small"}
		_refresh_water_data()
		water_idx = _water_idx_for_tag(tag)
		stock_before = 0.0
	level = clampf(level + maxf(delta_m, 0.0), floor_m + 0.02, max_level)
	if water_idx < 0:
		return {"ok": false, "reason": "no_pond"}
	set_pond_fill_level(water_idx, level, false)
	var info := get_pond_info(water_idx)
	return {
		"ok": true, "reason": "",
		"level_m": float(info.get("level_m", level)),
		"spill_m": spill_m, "floor_m": floor_m,
		"stock_l": float(info.get("stock_l", 0.0)),
		"capacity_l": float(info.get("capacity_l", 0.0)),
		"fill_frac": float(info.get("fill_frac", 0.0)),
		"delta_stock_l": float(info.get("stock_l", 0.0)) - stock_before,
		"tag": str(info.get("tag", tag)),
		"at_spill": float(info.get("level_m", level)) >= max_level - 0.01,
	}


## Lower / remove a user pond under the selection. Near floor → delete water body.
func drain_selection(poly: PackedVector2Array, delta_m: float) -> Dictionary:
	var existing := _find_user_pond_in_selection(poly)
	if existing.is_empty():
		return {"ok": false, "reason": "no_pond"}
	var rec: Dictionary = existing["rec"]
	var water_idx := int(existing.get("water_idx", -1))
	_recompute_pond_volume_rec(rec, false)
	var floor_m := float(rec.get("floor_m", 0.0))
	var spill_m := float(rec.get("spill_m", floor_m + 1.0))
	var level := float(rec.get("level_m", floor_m))
	var stock_before := float(rec.get("stock_l", 0.0))
	level = level - maxf(delta_m, 0.0)
	if level <= floor_m + 0.04:
		if water_idx >= 0:
			delete_pond(water_idx)
		return {
			"ok": true, "reason": "", "removed": true,
			"level_m": floor_m, "stock_l": 0.0, "capacity_l": 0.0,
			"fill_frac": 0.0, "delta_stock_l": -stock_before,
			"spill_m": spill_m, "floor_m": floor_m,
		}
	if water_idx >= 0:
		set_pond_fill_level(water_idx, level, false)
	var info := get_pond_info(water_idx) if water_idx >= 0 else {}
	return {
		"ok": true, "reason": "", "removed": false,
		"level_m": float(info.get("level_m", level)),
		"spill_m": spill_m, "floor_m": floor_m,
		"stock_l": float(info.get("stock_l", 0.0)),
		"capacity_l": float(info.get("capacity_l", 0.0)),
		"fill_frac": float(info.get("fill_frac", 0.0)),
		"delta_stock_l": float(info.get("stock_l", 0.0)) - stock_before,
		"tag": str(rec.get("tag", "")),
	}


## Human-readable status for Rain/Drain analyze failures.
func basin_failure_message(result: Dictionary) -> String:
	var reason := str(result.get("reason", "no_closed_basin"))
	match reason:
		"too_small":
			return "Selection too small (min ~%.0f m²) — enlarge the area" % WaterBuilder.MIN_AREA_M2
		"too_shallow":
			var d := float(result.get("depth_m", 0.0)) * 100.0
			return "Basin only %.0f cm deep — deepen with Lower/Pond or enlarge selection" % d
		"open_edge":
			return "Selection edge is open — expand to enclose the rim, or dig a closed bowl"
		"no_pond":
			return "No user pond here — hold Rain first, or select an existing pond"
		_:
			return "No closed depression — dig with Pond/Lower, then select over the hole"


## Update Auto bathymetry fields on a user-water record. When `overwrite_auto`
## is true, Auto capacity is rewritten from terrain; Manual capacity is kept.
func _recompute_pond_volume_rec(rec: Dictionary, overwrite_auto: bool = true) -> void:
	if rec.is_empty():
		return
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	if poly.size() < 3:
		return
	var bounds := sample_pond_basin_elevations(poly)
	var floor_y := float(bounds.get("floor_m", 0.0))
	var spill := float(bounds.get("rim_m", floor_y + 1.0))
	rec["floor_m"] = floor_y
	rec["spill_m"] = spill
	var cell := PondBathymetry.suggested_cell_m(BuildingBuilder.footprint_area_m2(poly))
	var height_at := Callable(self, "ground_height_at")
	var terrain_cap := PondBathymetry.capacity_l(poly, height_at, spill, PondBathymetry.FREEBOARD_DEFAULT_M, cell)
	rec["terrain_capacity_l"] = terrain_cap
	if not rec.has("capacity_mode"):
		rec["capacity_mode"] = "auto"
	if not rec.has("fill_mode"):
		rec["fill_mode"] = "auto"
	if str(rec.get("capacity_mode", "auto")) == "auto" and overwrite_auto:
		rec["capacity_l"] = maxf(terrain_cap, 1.0)
	elif not rec.has("capacity_l"):
		rec["capacity_l"] = maxf(terrain_cap, 1.0)
	var level := TerrainBuilder.variant_to_float(rec.get("level_m", NAN), NAN)
	if is_nan(level):
		level = floor_y + 0.05
		rec["level_m"] = level
	if str(rec.get("fill_mode", "auto")) == "auto" or not rec.has("stock_l"):
		rec["stock_l"] = PondBathymetry.volume_to_level_l(
			poly, height_at, level, cell, spill)
	var cap := maxf(float(rec.get("capacity_l", 1.0)), 1.0)
	rec["level"] = PondBathymetry.fill_frac(float(rec.get("stock_l", 0.0)), cap)


func _find_user_pond_in_selection(poly: PackedVector2Array) -> Dictionary:
	if poly.size() < 3:
		return {}
	var best := {}
	var best_area := -1.0
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		var rec: Dictionary = item
		if not bool(rec.get("user", false)):
			continue
		var kind := str(rec.get("kind", "pond"))
		if kind in WaterBuilder.FLOWING_KINDS:
			continue
		var pts: PackedVector2Array = rec.get("points", PackedVector2Array())
		if pts.size() < 3:
			continue
		var c := SolarArrayBuilder.centroid(pts)
		if not Geometry2D.is_point_in_polygon(c, poly):
			# Also accept selection centroid inside the pond.
			var sc := SolarArrayBuilder.centroid(poly)
			if not Geometry2D.is_point_in_polygon(sc, pts):
				continue
		var a := BuildingBuilder.footprint_area_m2(pts)
		if a > best_area:
			best_area = a
			best = {"rec": rec, "water_idx": i, "tag": str(rec.get("tag", ""))}
	return best


func _water_idx_for_tag(tag: String) -> int:
	if tag.is_empty():
		return -1
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
		var t := str((item as Dictionary).get("tag", _water_body_tag(poly)))
		if t == tag:
			return i
	return -1


func _mean_local_height_in_rect(grid: PackedFloat32Array, rect_min: Vector2,
		rect_max: Vector2) -> float:
	var x0 := minf(rect_min.x, rect_max.x)
	var x1 := maxf(rect_min.x, rect_max.x)
	var z0 := minf(rect_min.y, rect_max.y)
	var z1 := maxf(rect_min.y, rect_max.y)
	var total := 0.0
	var count := 0
	for r in MESH_RES:
		for c in MESH_RES:
			var w := TerrainSculpt.cell_to_world(c, r, MESH_RES, _built_extent)
			if w.x < x0 or w.x > x1 or w.y < z0 or w.y > z1:
				continue
			total += grid[r * MESH_RES + c] - _built_center_elev
			count += 1
	return total / float(maxi(count, 1))


func get_parcel_rect() -> Rect2:
	return _parcel_rect


func get_sculpt_locked_yaw() -> float:
	return _locked_yaw


func set_sculpt_locked_yaw(yaw: float) -> void:
	_locked_yaw = yaw


func update_selection_highlight(world_min: Vector2, world_max: Vector2) -> void:
	if _main == null or world_max.x - world_min.x < 0.5 or world_max.y - world_min.y < 0.5:
		_clear_selection_highlight()
		return
	var rect := Rect2(world_min, world_max - world_min).abs()
	if rect == _last_selection_rect and _selection_highlight != null and _selection_highlight.visible:
		return
	_last_selection_rect = rect
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	if _selection_highlight == null:
		_selection_highlight = MeshInstance3D.new()
		_selection_highlight.name = "SelectionHighlight"
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.82, 0.1, 0.42)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.no_depth_test = false
		_selection_highlight.material_override = mat
		terrain.add_child(_selection_highlight)
	var detail := _compose_detail_surface(false)
	var use_grid := detail if not detail.is_empty() else _built_grid
	var use_res := _detail_elev_cols if not detail.is_empty() else MESH_RES
	var use_extent := _detail_extent_m() if not detail.is_empty() else _built_extent
	_selection_highlight.mesh = TerrainBuilder.build_selection_highlight(
		world_min, world_max, use_grid, use_res, use_extent, _built_center_elev)
	_selection_highlight.visible = true


func clear_selection_highlight() -> void:
	_clear_selection_highlight()


func _clear_selection_highlight() -> void:
	_last_selection_rect = Rect2(-99999.0, -99999.0, 0.0, 0.0)
	if _selection_highlight != null:
		_selection_highlight.visible = false


func clear_parcel_rect() -> void:
	_parcel_rect = Rect2()


func select_nearest_parcel(world_xz: Vector2) -> void:
	var polys: Array = []
	for key in ["landuse", "buildings"]:
		for item in _osm_vectors.get(key, []):
			if item is Dictionary:
				polys.append(item)
	var poly := TerrainSculpt.nearest_parcel(polys, world_xz)
	if poly.is_empty():
		return
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	_parcel_rect = Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))
	update_selection_highlight(Vector2(min_x, min_z), Vector2(max_x, max_z))
	if _terrain_edit_ui != null and _terrain_edit_ui.has_method("set_selection_from_world_rect"):
		_terrain_edit_ui.call("set_selection_from_world_rect", Vector2(min_x, min_z), Vector2(max_x, max_z))


## ---------------------------------------------------------------------------
## Placed props (user GLB + OSM replacement)
## ---------------------------------------------------------------------------

func _should_load_user_map_overlays() -> bool:
	## Map-select "Load from cache" off → _force_refetch → clean world (no props/styles).
	return not _force_refetch


func _setup_placed_props() -> void:
	_placed_prop_layer = PlacedPropLayer.create_empty()
	_building_style_layer = BuildingStyleLayer.create_empty()
	_user_overlays_ephemeral = not _should_load_user_map_overlays()
	if _user_overlays_ephemeral:
		print("TerrainLoader: fresh/no-cache load — not loading placed props or building styles")
	else:
		_placed_prop_layer.load_for_map(_lat, _lon)
		_building_style_layer.load_for_map(_lat, _lon)
	npc_spaces = SpaceRegistry.create_empty()
	if not _user_overlays_ephemeral:
		npc_spaces.load_for_map(_lat, _lon)
	_setup_placed_props_ui()
	_setup_placed_prop_edit_ui()
	_setup_building_builder_ui()
	_setup_starshade_edit_ui()
	_setup_pond_edit_ui()
	_setup_pallet_rack_builder_ui()
	# Unified library lives on Main (all maps); bind this loader when opening.
	call_deferred("_rebuild_placed_props")
	call_deferred("_consume_design_context")


func _consume_design_context() -> void:
	var dc := get_node_or_null("/root/DesignContext")
	if dc == null or not bool(dc.get("has_pending")):
		return
	if not _built:
		call_deferred("_consume_design_context")
		return
	if not _detail_elev_resolved:
		call_deferred("_consume_design_context")
		return
	var d: Dictionary = dc.consume()
	if d.is_empty():
		return
	var model_id := str(d.get("model_id", ""))
	if not model_id.is_empty() and _main != null:
		PLACED_PROP_SERVICE_SCRIPT.place_model(_main, model_id, false)
		call_deferred("_attach_imported_ibc", model_id, d.get("ibc", {}))
	_apply_imported_graph(d.get("graph_save_state", {}) as Dictionary)
	_apply_imported_solar(d.get("solar", {}) as Dictionary)
	call_deferred("_seed_starshade_after_import", model_id, d)
	_sync_actors_to_ground(true)


func _seed_starshade_after_import(model_id: String, design: Dictionary) -> void:
	if _main == null or not ModelCatalog.is_starshade_model(model_id):
		return
	var sgv := ServiceLocator.graph()
	if sgv != null and sgv.has_method("has_starshade_graph_content"):
		if bool(sgv.call("has_starshade_graph_content")):
			return
		if sgv.has_method("seed_starshade_system"):
			var solar: Dictionary = design.get("solar", {}) as Dictionary
			var n := int(solar.get("panelCount", StarShadeGraphSeeder.DEFAULT_PANEL_COUNT))
			var w := float(solar.get("panelWatts", StarShadeGraphSeeder.DEFAULT_PANEL_WATTS))
			if bool(sgv.call("seed_starshade_system", n, w, "linkagelab_import")):
				if sgv.has_method("_sync_solar_ui_from_graph"):
					sgv.call("_sync_solar_ui_from_graph")
				if sgv.has_method("_schedule_graph_autosave"):
					sgv.call("_schedule_graph_autosave")
				return
	StarShadeGraphSeeder.try_seed_from_main(_main, self)


func _attach_imported_ibc(model_id: String, ibc_info: Variant) -> void:
	if not (ibc_info is Dictionary):
		return
	BUNDLE_IMPORTER_SCRIPT.attach_ibc_to_imported_canopy(get_tree(), model_id, ibc_info as Dictionary)


func _apply_imported_graph(graph_state: Dictionary) -> void:
	if graph_state.is_empty() or _main == null:
		return
	# Skip empty circuits — CircuitMapper always returns a populated wrapper, so
	# an items=[] payload would wipe the map's graph (incl. PBIs) before seeding.
	var graph_d: Dictionary = graph_state.get("graph", {}) as Dictionary
	if (graph_d.get("items", []) as Array).is_empty():
		return
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = get_tree().root.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("apply_save_state"):
		return
	var opts := {}
	if sgv.has_method("has_user_graph_layout") and bool(sgv.call("has_user_graph_layout")):
		opts["preserve_positions"] = true
	sgv.call("apply_save_state", graph_state, opts)


func _apply_imported_solar(solar: Dictionary) -> void:
	if solar.is_empty() or _main == null:
		return
	var solar_ui := _main.get_node_or_null("UILayer/SolarUI")
	if solar_ui == null:
		solar_ui = get_tree().root.find_child("SolarUI", true, false)
	if solar_ui != null and solar_ui.has_method("apply_imported_solar"):
		solar_ui.call("apply_imported_solar",
			int(solar.get("panelCount", 0)),
			float(solar.get("panelWatts", 0.0)),
			float(solar.get("tiltDeg", 0.0)),
			float(solar.get("azimuthDeg", 180.0)),
			float(solar.get("batteryKwh", -1.0)))


func _setup_placed_props_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var edit_ui := ui_layer.get_node_or_null("PlacedPropsUI")
	if edit_ui == null:
		edit_ui = Control.new()
		edit_ui.name = "PlacedPropsUI"
		edit_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		edit_ui.set_script(PLACED_PROPS_UI_SCRIPT)
		ui_layer.add_child(edit_ui)
	edit_ui.bind_loader(self)
	_placed_props_ui = edit_ui


func _setup_placed_prop_edit_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var edit_ui := ui_layer.get_node_or_null("PlacedPropEditUI")
	if edit_ui == null:
		edit_ui = PanelContainer.new()
		edit_ui.name = "PlacedPropEditUI"
		edit_ui.set_script(PLACED_PROP_EDIT_UI_SCRIPT)
		ui_layer.add_child(edit_ui)
	edit_ui.bind_loader(self)
	_placed_prop_edit_ui = edit_ui


func _rebuild_placed_props() -> void:
	if not _built or _placed_prop_layer == null or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	# Drop crosshair/grab refs before queue_free — otherwise the next `is PlacedProp`
	# check hits a freed instance ("Left operand of 'is' is a previously freed instance").
	_clear_placed_prop_focus()
	PlacedPropRuntime.rebuild(terrain, _placed_prop_layer, Callable(self, "_ground_height_at"))
	call_deferred("_try_seed_starshade_graph")
	
	# Also rebuild placed lights
	var PlacedLightService = load("res://core/placed_lights/placed_light_service.gd")
	var PlacedLightRuntime = load("res://core/placed_lights/placed_light_runtime.gd")
	var light_layer = PlacedLightService.get_layer(_main)
	if light_layer != null:
		PlacedLightRuntime.rebuild(terrain, light_layer)


func _try_seed_starshade_graph() -> void:
	if _main == null:
		return
	StarShadeGraphSeeder.try_seed_from_main(_main, self)


## Tell the graph view this map's world/OSM data is ready (per-map key + OSM btn).
func _notify_graph_map_ready() -> void:
	if _main == null:
		return
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = get_tree().root.find_child("SystemGraphView", true, false)
	if sgv == null:
		return
	if sgv.has_method("_on_map_world_ready"):
		sgv.call("_on_map_world_ready")
	elif sgv.has_method("_refresh_osm_solar_btn"):
		sgv.call("_refresh_osm_solar_btn")


func _clear_placed_prop_focus() -> void:
	if _main == null:
		return
	var player := _main.get_node_or_null("Player")
	if player == null:
		return
	var focus := player.get_node_or_null("InteractionFocus")
	if focus != null and focus.has_method("clear_focus"):
		focus.call("clear_focus")
	var grab := player.get_node_or_null("GrabController")
	if grab != null and grab.has_method("release_prop_refs"):
		grab.call("release_prop_refs")


func rebuild_placed_props() -> void:
	call_deferred("_rebuild_placed_props")


func _reground_placed_props() -> void:
	if _placed_prop_layer == null or _main == null:
		return
	for item in _placed_prop_layer.props:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		d["ground_y"] = _ground_height_at(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
	_rebuild_placed_props()
	# Never overwrite the user's saved props after a fresh/no-cache launch that
	# intentionally left the in-memory layer empty.
	if not _user_overlays_ephemeral:
		_placed_prop_layer.save(_lat, _lon)


## Remove every Buildings overlay under Terrain (sync). queue_free() alone leaves
## duplicates when _attach_buildings runs more than once per frame — get_node only
## finds the first child and later copies stack at different footing heights.
func _clear_building_nodes(terrain: Node) -> void:
	if terrain == null:
		_buildings_root = null
		_custom_buildings_root = null
		return
	for i in range(terrain.get_child_count() - 1, -1, -1):
		var child := terrain.get_child(i)
		if child.name == "Buildings" or child.name == "BuildingsCustom":
			terrain.remove_child(child)
			child.free()
	_buildings_root = null
	_custom_buildings_root = null


func is_building_replaced(building_idx: int) -> bool:
	if _placed_prop_layer == null:
		return false
	return _placed_prop_layer.is_building_replaced(building_idx)


func get_building_focus_idx() -> int:
	return _building_focus_idx


## Set (or clear with -1) the crosshair-focused building. Draws an amber
## footprint outline lifted above the roof (solar arrays own red).
func set_building_focus_idx(idx: int) -> void:
	if idx == _building_focus_idx:
		return
	_building_focus_idx = idx
	if idx < 0:
		_clear_building_highlight()
		return
	_draw_building_highlight(idx)


func _draw_building_highlight(idx: int) -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	var rec := _find_building_record(idx)
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	if poly.size() < 3:
		return
	if _building_highlight == null or not is_instance_valid(_building_highlight) \
			or _building_highlight.get_parent() != terrain:
		_building_highlight = MeshInstance3D.new()
		_building_highlight.name = "BuildingFocusHighlight"
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.75, 0.15, 0.4)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_building_highlight.material_override = mat
		terrain.add_child(_building_highlight)
	# Float the outline just above the roof so it reads from street level
	# (a ground-level drape would hide inside the walls).
	var lift := TerrainBuilder.dict_float(rec, "height_m", BuildingBuilder.DEFAULT_HEIGHT_M) + 0.8
	var footing := _highlight_footing_grid(true)
	_building_highlight.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev, lift)
	_building_highlight.visible = true


func _clear_building_highlight() -> void:
	if _building_highlight != null and is_instance_valid(_building_highlight):
		_building_highlight.visible = false


func pick_building_at_world(x: float, z: float) -> Dictionary:
	return BuildingPicker.pick_at_xz(_buildings_data, x, z)


func pick_building_at_screen(screen_pos: Vector2) -> Dictionary:
	var hit: Variant = terrain_pick_ray(screen_pos)
	if hit == null:
		return {"valid": false}
	var p: Vector3 = hit as Vector3
	return pick_building_at_world(p.x, p.z)


## ---------------------------------------------------------------------------
## Crosshair focus on OSM vegetation areas (lawn / field / forest polygons)
## ---------------------------------------------------------------------------

## True only while the vegetation paint dock (V) is open — gates the crosshair
## OSM-vegetation highlight/prompt so it doesn't light up every OSM tree patch
## the player merely walks past outside of veg-editing.
func is_vegetation_edit_active() -> bool:
	return _vegetation_edit_ui != null and is_instance_valid(_vegetation_edit_ui) \
		and bool(_vegetation_edit_ui.visible)

func pick_veg_area_at_world(x: float, z: float) -> Dictionary:
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array):
		return {"valid": false}
	return VegAreaPicker.pick_at_xz(polys as Array, x, z)


func get_veg_focus_idx() -> int:
	return _veg_focus_idx


## Set (or clear with -1) the crosshair-focused OSM veg area. Draws an amber
## ground-draped outline over the polygon (reusing the paint highlight mesh), the
## same "focused, interactable" affordance buildings use.
func set_veg_focus_idx(idx: int) -> void:
	if idx == _veg_focus_idx:
		return
	_veg_focus_idx = idx
	if idx < 0:
		_veg_focus_area = {}
		clear_vegetation_highlight()
		return
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array):
		return
	var info := VegAreaPicker.area_info(polys as Array, idx)
	if not bool(info.get("valid", false)):
		clear_vegetation_highlight()
		return
	_veg_focus_area = info
	var poly: PackedVector2Array = info.get("points", PackedVector2Array())
	update_vegetation_highlight(poly, Color(1.0, 0.75, 0.15, 0.4), true)


## Interact / O on a focused veg area → open the Tune look modal seeded to that
## area's veg type. (Per-area vs all-of-type apply lands in a later phase; for now
## the modal opens on the right species so edits target the correct look.)
func open_veg_area_modal(area_idx: int) -> void:
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array) or area_idx < 0 or area_idx >= (polys as Array).size():
		return
	var d: Variant = (polys as Array)[area_idx]
	if not (d is Dictionary):
		return
	var kind := str((d as Dictionary).get("kind", "grass_field"))
	open_vegetation_preview_editor(_preset_for_veg_kind(kind))


## OSM area kind → VegetationPaint.Preset for seeding the modal. Honors an explicit
## player osm_species_map binding first, else a per-kind heuristic.
func _preset_for_veg_kind(kind: String) -> int:
	var osm_map: Variant = _veg_style.get("osm_species_map", {})
	if osm_map is Dictionary:
		match str((osm_map as Dictionary).get(kind, "auto")):
			"pine":
				return VegetationPaint.Preset.PINE
			"deciduous":
				return VegetationPaint.Preset.DECIDUOUS
			"shrub":
				return VegetationPaint.Preset.SHRUB
			"mixed":
				return VegetationPaint.Preset.MIX
	match kind:
		"grass_lawn":
			return VegetationPaint.Preset.GRASS_LAWN
		"grass_field", "wetland":
			return VegetationPaint.Preset.GRASS_FIELD
		"scrub", "vineyard":
			return VegetationPaint.Preset.SHRUB
		"park", "cemetery":
			return VegetationPaint.Preset.MIX
		_:
			# wood / forest / orchard and any unknown tree area.
			return VegetationPaint.Preset.DECIDUOUS


## ---------------------------------------------------------------------------
## Per-building styles (Building Builder)
## ---------------------------------------------------------------------------

func _setup_building_builder_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "BuildingBuilderLayer"
	layer.layer = 26
	ui_layer.add_child(layer)
	var ui := Control.new()
	ui.name = "BuildingBuilderModal"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.set_script(BUILDING_BUILDER_MODAL_SCRIPT)
	layer.add_child(ui)
	ui.bind_loader(self)
	_building_builder_ui = ui


func _setup_pond_edit_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "PondEditLayer"
	layer.layer = 26
	ui_layer.add_child(layer)
	var ui := PanelContainer.new()
	ui.name = "PondEditModal"
	ui.set_script(POND_EDIT_MODAL_SCRIPT)
	layer.add_child(ui)
	ui.call("bind_loader", self)
	_pond_edit_ui = ui


func _setup_starshade_edit_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "StarShadeEditLayer"
	layer.layer = 27
	ui_layer.add_child(layer)
	var ui := Control.new()
	ui.name = "StarShadeEditModal"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.set_script(STARSHADE_EDIT_MODAL_SCRIPT)
	layer.add_child(ui)
	ui.bind_loader(self)
	_starshade_edit_ui = ui


func _setup_pallet_rack_builder_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "PalletRackBuilderLayer"
	layer.layer = 27
	ui_layer.add_child(layer)
	var ui := Control.new()
	ui.name = "PalletRackBuilderModal"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.set_script(PALLET_RACK_BUILDER_MODAL_SCRIPT)
	layer.add_child(ui)
	ui.bind_loader(self)
	_pallet_rack_builder_ui = ui


func open_starshade_editor(prop_id: String) -> void:
	if _starshade_edit_ui != null and _starshade_edit_ui.has_method("open_for_prop"):
		_starshade_edit_ui.call("open_for_prop", prop_id)


func open_pallet_rack_builder() -> void:
	if _pallet_rack_builder_ui != null and _pallet_rack_builder_ui.has_method("open"):
		_pallet_rack_builder_ui.call("open")


## Open the pallet rack builder bound to an already-placed rack for editing
## (Ctrl-click a placed pallet_rack prop → edit, then "Apply changes").
func open_pallet_rack_builder_for_prop(prop_id: String) -> void:
	if _pallet_rack_builder_ui != null and _pallet_rack_builder_ui.has_method("open_for_prop"):
		_pallet_rack_builder_ui.call("open_for_prop", prop_id)


func open_unified_library(tab: String = "") -> void:
	# Prefer Main's always-available modal (works on soak / mars too).
	if _main != null and _main.has_method("open_unified_library"):
		_main.call("open_unified_library", tab)
		return
	push_warning("TerrainLoader: Main.open_unified_library unavailable")


func begin_pallet_rack_placement(rack_spec: Dictionary, collision_enabled: bool = true) -> bool:
	if _main == null:
		return false
	var spec := PalletRackBuilder.resolve_spec(rack_spec)
	var r: Dictionary = PlacedPropService.begin_placement(_main, PalletRackBuilder.MODEL_ID, {
		"record_extra": {"rack_spec": spec, "collision_enabled": collision_enabled},
	})
	if not bool(r.get("ok", false)):
		return false
	if _placed_props_ui != null and _placed_props_ui.has_method("notify_bundle_imported"):
		_placed_props_ui.call("notify_bundle_imported", r)
	return true


func open_building_builder(building_idx: int) -> void:
	if _building_builder_ui == null:
		return
	if building_idx < 0:
		if _building_builder_ui.has_method("open_library"):
			_building_builder_ui.call("open_library")
	elif _building_builder_ui.has_method("open"):
		_building_builder_ui.call("open", building_idx)


func get_building_record(building_idx: int) -> Dictionary:
	return _find_building_record(building_idx).duplicate(true)


## Start the ghost-placement flow for a library structure (the placed-props UI
## drives per-frame aim + click-confirm once notified).
func begin_structure_placement(model_id: String) -> bool:
	if _main == null or model_id.is_empty():
		return false
	var r: Dictionary = PlacedPropService.begin_placement(_main, model_id)
	if not bool(r.get("ok", false)):
		return false
	if _placed_props_ui != null and _placed_props_ui.has_method("notify_bundle_imported"):
		_placed_props_ui.call("notify_bundle_imported", r)
	return true


## Hand an already-started PlacedPropService placement (e.g. begun by the system
## graph's "Place Model" button) to the placed-props UI so its per-frame aim +
## click-to-confirm loop drives the ghost. `result` is the begin_placement return.
func notify_external_placement_started(result: Dictionary) -> void:
	if _placed_props_ui != null and _placed_props_ui.has_method("notify_bundle_imported"):
		_placed_props_ui.call("notify_bundle_imported", result)


func get_building_tag(building_idx: int) -> String:
	var d := _find_building_record(building_idx)
	var pts: Variant = d.get("points", PackedVector2Array())
	if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
		return ""
	return BuildingBuilder.building_tag(pts)


## World-XZ footprint centroid of the building carrying `tag`, or null when no
## loaded building matches (SpaceRegistry uses null to skip dangling targets).
func building_centroid_by_tag(tag: String) -> Variant:
	if tag.is_empty():
		return null
	for item in _buildings_data:
		if not (item is Dictionary):
			continue
		var pts: Variant = (item as Dictionary).get("points", PackedVector2Array())
		if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
			continue
		var poly: PackedVector2Array = pts
		if BuildingBuilder.building_tag(poly) != tag:
			continue
		var c := Vector2.ZERO
		for p in poly:
			c += p
		return c / float(poly.size())
	return null


## Persist the NPC space registry (lazy-prunes tags whose target vanished).
func save_npc_spaces() -> void:
	if npc_spaces == null:
		return
	if _built:  # never prune mid-load, before props/buildings have streamed in
		npc_spaces.prune_dangling(_main)
	npc_spaces.save(_lat, _lon)


## Building records within radius_m of (x, z) whose footprint area falls in
## [min_area_m2, max_area_m2], nearest first: [{idx, tag, dist_m, area_m2}].
## Used to pick "hero" buildings (near spawn, house-sized) for facade texture
## assignment — house-sized excludes both sheds and outliers like the church.
func list_buildings_near(x: float, z: float, radius_m: float,
		min_area_m2: float = 20.0, max_area_m2: float = 250.0) -> Array:
	var out: Array = []
	for item in _buildings_data:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var pts: Variant = d.get("points", PackedVector2Array())
		if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
			continue
		var poly: PackedVector2Array = pts
		var area := BuildingBuilder.footprint_area_m2(poly)
		if area < min_area_m2 or area > max_area_m2:
			continue
		var cx := 0.0
		var cz := 0.0
		for p in poly:
			cx += p.x
			cz += p.y
		cx /= float(poly.size())
		cz /= float(poly.size())
		var dist := Vector2(cx - x, cz - z).length()
		if dist > radius_m:
			continue
		out.append({
			"idx": int(d.get("idx", -1)),
			"tag": BuildingBuilder.building_tag(poly),
			"dist_m": dist,
			"area_m2": area,
		})
	out.sort_custom(func(a: Variant, b: Variant) -> bool:
		return float((a as Dictionary)["dist_m"]) < float((b as Dictionary)["dist_m"]))
	return out


## Every building currently carrying a style override: [{idx, tag, x, z, area_m2}].
## Used by playtest tooling to photograph exactly the buildings a session just
## customized (e.g. after assigning facade textures), regardless of location.
func list_styled_buildings() -> Array:
	var out: Array = []
	if _building_style_layer == null:
		return out
	for item in _buildings_data:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var pts: Variant = d.get("points", PackedVector2Array())
		if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
			continue
		var poly: PackedVector2Array = pts
		var tag := BuildingBuilder.building_tag(poly)
		if not _building_style_layer.has_style(tag):
			continue
		var cx := 0.0
		var cz := 0.0
		for p in poly:
			cx += p.x
			cz += p.y
		cx /= float(poly.size())
		cz /= float(poly.size())
		out.append({
			"idx": int(d.get("idx", -1)), "tag": tag, "x": cx, "z": cz,
			"area_m2": BuildingBuilder.footprint_area_m2(poly),
		})
	return out


func get_building_style(building_idx: int) -> Dictionary:
	if _building_style_layer == null:
		return {}
	return _building_style_layer.get_style(get_building_tag(building_idx))


## Persist a style and rebuild only what changed: a re-style of an already
## customized building swaps its one BuildingsCustom child; a NEW style changes
## the styled set, so the merged mesh must be rebuilt to exclude it.
func apply_building_style(building_idx: int, style: Dictionary) -> bool:
	if _building_style_layer == null:
		return false
	var tag := get_building_tag(building_idx)
	if tag.is_empty():
		return false
	var was_styled := _building_style_layer.has_style(tag)
	if not _building_style_layer.set_style(tag, style):
		return false
	_building_style_layer.save(_lat, _lon)
	if was_styled:
		_rebuild_custom_building(building_idx, tag)
	else:
		_attach_buildings()
	return true


func clear_building_style(building_idx: int) -> void:
	if _building_style_layer == null:
		return
	var tag := get_building_tag(building_idx)
	if tag.is_empty() or not _building_style_layer.remove_style(tag):
		return
	_building_style_layer.save(_lat, _lon)
	_attach_buildings()


func _rebuild_custom_building(building_idx: int, tag: String) -> void:
	if _custom_buildings_root == null or not is_instance_valid(_custom_buildings_root):
		_attach_buildings()
		return
	var old := _custom_buildings_root.get_node_or_null("B_%s" % tag)
	if old != null:
		_custom_buildings_root.remove_child(old)
		old.free()
	var d := _find_building_record(building_idx)
	if d.is_empty():
		return
	var detail_cols := _detail_elev_cols if not _detail_surface_grid.is_empty() else 0
	var detail_rows := _detail_elev_rows if not _detail_surface_grid.is_empty() else 0
	var style: Dictionary = _building_style_layer.get_style(tag)
	var mi := BuildingBuilder.build_single_building(
		d, style,
		_built_grid, MESH_RES, _built_extent, _built_center_elev,
		_detail_surface_grid, detail_cols, detail_rows,
		_detail_extent_m(), true)
	if mi != null:
		mi.name = "B_%s" % tag
		_apply_styled_wall_material(mi, style)
		_custom_buildings_root.add_child(mi)
		# Late rebuilds must also re-pick up the ortho roof uniforms.
		if mi.mesh != null and mi.mesh.get_surface_count() > 1:
			mi.set_surface_override_material(1, _make_world_roof_material())


func place_prop_from_screen(screen_pos: Vector2, model_id: String) -> bool:
	if _placed_prop_layer == null or model_id.is_empty():
		return false
	var hit: Variant = terrain_pick_ray(screen_pos)
	if hit == null:
		return false
	var p: Vector3 = hit as Vector3
	return _place_free_prop(model_id, p.x, p.z)


func place_prop_at_site_origin(model_id: String) -> bool:
	return _place_free_prop(model_id, 0.0, 0.0)


func _place_free_prop(model_id: String, x: float, z: float) -> bool:
	if _placed_prop_layer == null or model_id.is_empty():
		return false
	var gy := _ground_height_at(x, z)
	var prop_id := _placed_prop_layer.add_free_prop(
		model_id, x, 0.0, z, 0.0, 0.0, 0.0, 1.0, gy)
	if prop_id.is_empty():
		return false
	_placed_prop_layer.save(_lat, _lon)
	call_deferred("_rebuild_placed_props")
	return true


func replace_osm_building_at_screen(screen_pos: Vector2, model_id: String) -> bool:
	if _placed_prop_layer == null or model_id.is_empty():
		return false
	var pick := pick_building_at_screen(screen_pos)
	if not bool(pick.get("valid", false)):
		return false
	return _replace_osm_from_pick(pick, model_id)


func replace_osm_building(building_idx: int, model_id: String) -> bool:
	var pick := BuildingPicker.footprint_info(_buildings_data, building_idx)
	if not bool(pick.get("valid", false)):
		return false
	return _replace_osm_from_pick(pick, model_id)


func _replace_osm_from_pick(pick: Dictionary, model_id: String) -> bool:
	var centroid: Vector2 = pick.get("centroid", Vector2.ZERO)
	var width_m := float(pick.get("width_m", 1.0))
	var depth_m := float(pick.get("depth_m", 1.0))
	var height_m := float(pick.get("height_m", BuildingBuilder.DEFAULT_HEIGHT_M))
	var fit_scale := ModelCatalog.scale_to_footprint(model_id, width_m, depth_m, height_m, 1.0)
	var gy := _ground_height_at(centroid.x, centroid.y)
	var prop_id := _placed_prop_layer.add_osm_prop(
		int(pick.get("building_idx", -1)), model_id,
		centroid.x, 0.0, centroid.y, 0.0, 0.0, 0.0, fit_scale, gy)
	if prop_id.is_empty():
		return false
	_placed_prop_layer.save(_lat, _lon)
	_attach_buildings()
	_rebuild_placed_props()
	return true


func delete_nearest_prop(world_xz: Vector2) -> bool:
	if _placed_prop_layer == null:
		return false
	if not _placed_prop_layer.remove_nearest(world_xz):
		return false
	_placed_prop_layer.save(_lat, _lon)
	_attach_buildings()
	_rebuild_placed_props()
	return true


func delete_prop_by_id(prop_id: String) -> bool:
	if _placed_prop_layer == null:
		return false
	# A live-foldable linkage structure owns a per-prop graph solar array —
	# drop it so deleting the structure doesn't orphan its power contribution.
	var rec := _placed_prop_layer.find_by_id(prop_id)
	if str(rec.get("model_id", "")) == LinkageStructureBuilder.MODEL_ID and _main != null:
		PlacedPropService.remove_linkage_graph(_main, prop_id)
	if not _placed_prop_layer.remove_prop(prop_id):
		return false
	# 2D/3D twin consistency: a graph node bound to this prop is the same object
	# in another view — never leave a dead node behind. No-op for graph-initiated
	# deletes (the node is already gone when this runs).
	if _main != null:
		var sgv := ServiceLocator.graph()
		if sgv != null and sgv.has_method("remove_items_bound_to_prop"):
			sgv.call("remove_items_bound_to_prop", prop_id)
	_placed_prop_layer.save(_lat, _lon)
	_attach_buildings()
	_rebuild_placed_props()
	return true


func get_prop_record(prop_id: String) -> Dictionary:
	if _placed_prop_layer == null:
		return {}
	return _placed_prop_layer.find_by_id(prop_id)


func update_prop_record(prop_id: String, patch: Dictionary) -> void:
	if _placed_prop_layer == null:
		return
	if not _placed_prop_layer.update_prop(prop_id, patch):
		return
	_placed_prop_layer.save(_lat, _lon)
	_attach_buildings()
	_rebuild_placed_props()


## Bulk hide/show every generic placeholder twin (generic_box / generic_tank) from
## the 3D world — the "conceptual storage not ready for 3D" case. Returns the count
## affected. One save + rebuild for the whole batch.
func set_placeholder_twins_hidden(hidden: bool) -> int:
	if _placed_prop_layer == null:
		return 0
	var n := 0
	for rec in _placed_prop_layer.props:
		if not (rec is Dictionary):
			continue
		var mid := str((rec as Dictionary).get("model_id", ""))
		if mid == ModelCatalog.GENERIC_BOX_ID or mid == ModelCatalog.GENERIC_TANK_ID:
			if _placed_prop_layer.update_prop(str((rec as Dictionary).get("id", "")),
					{"hidden_3d": hidden}):
				n += 1
	if n > 0:
		_placed_prop_layer.save(_lat, _lon)
		_rebuild_placed_props()
	return n


func preview_prop(prop_id: String, patch: Dictionary) -> void:
	if _main == null or _placed_prop_layer == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var root := terrain.get_node_or_null("PlacedProps")
	if root == null:
		return
	for child in root.get_children():
		if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
			var rec := _placed_prop_layer.find_by_id(prop_id).duplicate(true)
			rec.merge(patch, true)
			PlacedPropRuntime.apply_record_to_prop(child as PlacedProp, rec, Callable(self, "_ground_height_at"))
			return


func save_prop_from_node(prop: PlacedProp) -> void:
	if _placed_prop_layer == null or prop == null:
		return
	var patch := prop.get_record_patch_from_node(Callable(self, "_ground_height_at"))
	_placed_prop_layer.update_prop(prop.prop_id, patch)
	_placed_prop_layer.save(_lat, _lon)


# ---------------------------------------------------------------------------
# .esim site-layer collect / apply (portable design package — Phases 0–1)
# ---------------------------------------------------------------------------

## Snapshot shareable per-site layers (no DEM/imagery/sculpt binaries).
func collect_esim_site_layers() -> Dictionary:
	var soi_blob: Dictionary = {}
	var soi := get_node_or_null("/root/SoiService")
	if soi == null:
		var tree := get_tree()
		if tree != null:
			soi = tree.root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("collect_save_state"):
		soi_blob = soi.call("collect_save_state")

	var props_blob := {"version": 1, "props": []}
	if _placed_prop_layer != null:
		props_blob = _placed_prop_layer.serialize()

	var styles_blob := {"version": 1, "styles": {}}
	if _building_style_layer != null:
		styles_blob = _building_style_layer.serialize()

	var veg_blob: Dictionary = {}
	if _vegetation_layer != null:
		veg_blob = _vegetation_layer.serialize()

	var veg_style_blob: Dictionary = {}
	if not _veg_style.is_empty():
		veg_style_blob = VegetationStyleConfig.to_serializable(_veg_style)

	var auto_edits_blob: Dictionary = {}
	if _auto_veg_edits != null:
		auto_edits_blob = _auto_veg_edits.serialize()

	return {
		"soi": soi_blob,
		"placed_props": props_blob,
		"building_styles": styles_blob,
		"vegetation": veg_blob,
		"vegetation_style": veg_style_blob,
		"auto_veg_edits": auto_edits_blob,
		"user_water": _serialize_user_water(),
	}


## Apply .esim sidecars onto the current map and optionally rebuild world meshes.
func apply_esim_site_layers(layers: Dictionary, options: Dictionary = {}) -> Dictionary:
	if layers.is_empty():
		return {"ok": false, "error": "Empty site layers"}
	var rebuild := bool(options.get("rebuild", true))
	var applied: Array = []

	var soi_blob: Dictionary = layers.get("soi", {}) as Dictionary
	if not soi_blob.is_empty():
		var soi := get_tree().root.get_node_or_null("SoiService") if get_tree() != null else null
		if soi != null and soi.has_method("apply_save_state"):
			soi.call("apply_save_state", soi_blob)
			applied.append("soi")

	var props_blob: Dictionary = layers.get("placed_props", {}) as Dictionary
	if not props_blob.is_empty():
		if _placed_prop_layer == null:
			_placed_prop_layer = PlacedPropLayer.create_empty()
		_placed_prop_layer.deserialize(props_blob)
		_placed_prop_layer.save(_lat, _lon)
		applied.append("placed_props")

	var styles_blob: Dictionary = layers.get("building_styles", {}) as Dictionary
	if not styles_blob.is_empty():
		if _building_style_layer == null:
			_building_style_layer = BuildingStyleLayer.create_empty()
		_building_style_layer.deserialize(styles_blob)
		_building_style_layer.save(_lat, _lon)
		applied.append("building_styles")

	var veg_blob: Dictionary = layers.get("vegetation", {}) as Dictionary
	if not veg_blob.is_empty():
		if _vegetation_layer == null:
			_vegetation_layer = VegetationLayer.create_empty()
		_vegetation_layer.deserialize(veg_blob)
		_vegetation_layer.save(_lat, _lon)
		applied.append("vegetation")

	var veg_style_blob: Dictionary = layers.get("vegetation_style", {}) as Dictionary
	if not veg_style_blob.is_empty():
		var style := VegetationStyleConfig.from_serializable(veg_style_blob)
		_veg_style = VegetationStyleConfig.apply_patch(
			VegetationStyleConfig.load_merged(_lat, _lon), style)
		VegetationStyleConfig.save_map(_lat, _lon, _veg_style)
		applied.append("vegetation_style")

	var auto_blob: Dictionary = layers.get("auto_veg_edits", {}) as Dictionary
	if not auto_blob.is_empty():
		if _auto_veg_edits == null:
			_auto_veg_edits = AutoVegetationEdits.create_empty()
		_auto_veg_edits.deserialize(auto_blob)
		_auto_veg_edits.save(_lat, _lon)
		applied.append("auto_veg_edits")

	var water_blob: Dictionary = layers.get("user_water", {}) as Dictionary
	if not water_blob.is_empty():
		_deserialize_user_water(water_blob)
		_save_user_water()
		_refresh_water_data()
		applied.append("user_water")

	if rebuild and _built:
		if "building_styles" in applied or "placed_props" in applied:
			_attach_buildings()
		if "placed_props" in applied:
			_rebuild_placed_props()
		if "vegetation" in applied or "vegetation_style" in applied \
				or "auto_veg_edits" in applied:
			call_deferred("_rebuild_vegetation")
			if _auto_veg_generated:
				call_deferred("_full_regenerate_auto_vegetation_async")
		if "user_water" in applied:
			call_deferred("_attach_water")

	return {"ok": true, "applied": applied}


func _serialize_user_water() -> Dictionary:
	var ponds: Array = []
	for rec in _user_water_data:
		if not (rec is Dictionary):
			continue
		var pts: PackedVector2Array = (rec as Dictionary).get("points", PackedVector2Array())
		var arr: Array = []
		for p in pts:
			arr.append([p.x, p.y])
		var out := {"tag": str((rec as Dictionary).get("tag", "")), "points": arr}
		if (rec as Dictionary).has("level_m"):
			out["level_m"] = float((rec as Dictionary)["level_m"])
		if (rec as Dictionary).has("capacity_l"):
			out["capacity_l"] = float((rec as Dictionary)["capacity_l"])
		if (rec as Dictionary).has("label"):
			out["label"] = str((rec as Dictionary)["label"])
		ponds.append(out)
	return {"version": 1, "ponds": ponds}


func _deserialize_user_water(data: Dictionary) -> void:
	_user_water_data = []
	for raw in data.get("ponds", []) as Array:
		if not (raw is Dictionary):
			continue
		var d: Dictionary = raw as Dictionary
		var pts := PackedVector2Array()
		for p in d.get("points", []) as Array:
			if p is Array and (p as Array).size() >= 2:
				pts.append(Vector2(float(p[0]), float(p[1])))
			elif p is Vector2:
				pts.append(p)
		if pts.size() < 3:
			continue
		var rec := {
			"points": pts,
			"kind": "pond",
			"tag": str(d.get("tag", "")),
			"user": true,
		}
		if d.has("level_m"):
			rec["level_m"] = float(d["level_m"])
		if d.has("capacity_l"):
			rec["capacity_l"] = float(d["capacity_l"])
		if d.has("label"):
			rec["label"] = str(d["label"])
		_user_water_data.append(rec)


## Enter click-to-move for a placed prop (edit-UI Move button). The real node
## follows the crosshair terrain hit; LMB confirms, Esc cancels. Camera XZ
## lerps toward the prop while active (drone or player).
func begin_prop_reposition(prop_id: String) -> void:
	if prop_id.is_empty() or _main == null:
		return
	_cancel_prop_reposition()
	var prop := _find_placed_prop_node(prop_id)
	if prop == null:
		return
	_reposition_prop = prop
	_reposition_valid = false
	_reposition_cam_follow = true
	prop.set_collision_enabled(false)
	if prop.has_method("on_focus_exit"):
		var player := _main.get_node_or_null("Player")
		prop.on_focus_exit(player)
	_clear_placed_prop_focus()
	if _placed_prop_edit_ui != null and _placed_prop_edit_ui.has_method("close"):
		_placed_prop_edit_ui.call("close")
	CursorController.request_modal("prop_reposition", Callable(self, "_cancel_prop_reposition"))


func _find_placed_prop_node(prop_id: String) -> PlacedProp:
	if _main == null or prop_id.is_empty():
		return null
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return null
	var root := terrain.get_node_or_null("PlacedProps")
	if root == null:
		return null
	for child in root.get_children():
		if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
			return child as PlacedProp
	return null


func _tick_prop_reposition(delta: float) -> void:
	if _reposition_prop == null or not is_instance_valid(_reposition_prop):
		_reposition_prop = null
		CursorController.release_modal("prop_reposition")
		return
	var cam := _active_world_camera()
	if cam == null:
		return
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(_main, cam)
	if hit.is_empty():
		_reposition_valid = false
	else:
		var pos: Vector3 = hit["position"] as Vector3
		var model := _reposition_prop.get_node_or_null("ModelRoot") as Node3D
		var foot_y := ModelCatalog.foot_local_y(_reposition_prop.model_id)
		var ws := model.scale.x if model != null else 1.0
		_reposition_prop.global_position = Vector3(pos.x, pos.y - foot_y * ws, pos.z)
		_reposition_valid = true
	if _reposition_cam_follow:
		_follow_camera_toward_prop(delta, _reposition_prop.global_position)


func _active_world_camera() -> Camera3D:
	if _main == null:
		return null
	var vp_cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if vp_cam != null:
		return vp_cam
	var player := _main.get_node_or_null("Player")
	if player != null:
		var pc := player.get_node_or_null("CameraArm/Camera3D") as Camera3D
		if pc != null:
			return pc
	return null


func _follow_camera_toward_prop(delta: float, target: Vector3) -> void:
	if _main == null:
		return
	var t := clampf(delta * REPOSITION_FOLLOW_LERP, 0.0, 1.0)
	var drone := _main.get_node_or_null("FPVDrone") as Node3D
	var player := _main.get_node_or_null("Player") as Node3D
	var body: Node3D = null
	if drone != null and bool(drone.get("is_mounted")):
		body = drone
	elif player != null:
		body = player
	if body == null:
		return
	var gp := body.global_position
	body.global_position = Vector3(
		lerpf(gp.x, target.x, t),
		gp.y,
		lerpf(gp.z, target.z, t))


func _confirm_prop_reposition() -> void:
	var prop := _reposition_prop
	_reposition_prop = null
	CursorController.release_modal("prop_reposition")
	if prop == null or not is_instance_valid(prop):
		return
	if _reposition_valid:
		save_prop_from_node(prop)
		# Keep any bound 2D graph node's site/elevation coords in sync (D).
		var pid := str(prop.prop_id)
		var sgv := _find_system_graph_view()
		if sgv != null and pid != "" and sgv.has_method("sync_site_from_prop"):
			sgv.call_deferred("sync_site_from_prop", pid)
	rebuild_placed_props()


func _cancel_prop_reposition() -> void:
	if _reposition_prop == null:
		CursorController.release_modal("prop_reposition")
		return
	_reposition_prop = null
	_reposition_valid = false
	CursorController.release_modal("prop_reposition")
	rebuild_placed_props()


## Keep only OSM footprints that touch the hi-res centre square (building meshes).
static func _features_intersecting_square(features: Array, half_m: float) -> Array:
	var out: Array = []
	for item in features:
		if not (item is Dictionary):
			continue
		var pts: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
		if _polygon_intersects_square(pts, half_m):
			out.append(item)
	return out


static func _polygon_intersects_square(poly: PackedVector2Array, half_m: float) -> bool:
	if poly.is_empty():
		return false
	for p in poly:
		if absf(p.x) <= half_m and absf(p.y) <= half_m:
			return true
	var cx := 0.0
	var cz := 0.0
	for p in poly:
		cx += p.x
		cz += p.y
	cx /= float(poly.size())
	cz /= float(poly.size())
	return absf(cx) <= half_m and absf(cz) <= half_m


## ---------------------------------------------------------------------------
## Temporary floor + loading overlay (Phase 5 multi-stage progress)
## ---------------------------------------------------------------------------

func _begin_load_ui() -> void:
	_load_ui_active = true
	_load_hint = ""
	_load_fast_path = TerrainCacheSettings.has_warm_cache(_lat, _lon)
	_detail_img_resolved = false
	_load_progress = TerrainLoadProgress.new()
	_load_overlay = TerrainLoadOverlay.new()
	var ui_layer := _main.get_node_or_null("UILayer") if _main != null else null
	var host: Node = ui_layer if ui_layer != null else self
	host.add_child(_load_overlay)
	var title := "Loading %s" % _map_label if not _map_label.is_empty() else "Loading map"
	_load_overlay.setup(title)
	_load_overlay.dismissed.connect(_on_load_overlay_dismissed)
	if _load_fast_path:
		_load_overlay.set_progress(0.0, "Loading from cache", "Previously fetched data on this PC")
	_update_load_ui()


func _on_load_overlay_dismissed() -> void:
	_load_overlay = null
	_load_progress = null


func _load_progress_mark_done(stage: String) -> void:
	if _load_progress != null:
		_load_progress.mark_done(stage)


func _resolve_detail_imagery() -> void:
	if _detail_img_resolved:
		return
	_detail_img_resolved = true
	_load_progress_mark_done("detail_img")
	_check_load_complete()


## Load-phase memory/VRAM trace. Silent exits during load are almost always a GPU
## TDR or VRAM/RAM exhaustion; this prints the resident footprint at each stage so
## a crashing run leaves a breadcrumb of where the budget blew up. Look for the
## last line printed before the process disappears.
func _log_load_mem(tag: String) -> void:
	if not DEBUG_LOAD:
		return
	var vram := float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
	var tex := float(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)) / 1048576.0
	print("TerrainLoader[mem] %-22s vram=%.1f MB tex=%.1f MB static=%.1f MB" % [
		tag, vram, tex, OS.get_static_memory_usage() / 1048576.0])


func _update_load_ui(hint: String = "") -> void:
	if not _load_ui_active or _load_overlay == null or _load_progress == null:
		return
	if not hint.is_empty():
		_load_hint = hint
	_load_overlay.set_progress(
		_load_progress.fraction(), _load_progress.active_label(), _load_hint)


func _check_load_complete() -> void:
	if _load_sequence_active:
		return
	if not _load_ui_active or _load_overlay == null or _load_progress == null:
		return
	_update_load_ui()
	if _load_progress.is_complete():
		_load_ui_active = false
		_load_overlay.show_map_loaded(_load_fast_path)
		print("TerrainLoader: map loaded")
		_log_load_mem("map loaded")
		if _auto_veg_scatter_pending:
			_auto_veg_scatter_pending = false
			var regen := _auto_veg_scatter_regen
			call_deferred("_run_auto_veg_generate", regen)
		if _manual_veg_pending:
			call_deferred("_start_manual_veg_rebuild")


func _add_temp_floor() -> void:
	if _main == null:
		return
	var body := StaticBody3D.new()
	body.name = "TerrainLoaderTempFloor"
	var cs := CollisionShape3D.new()
	var shape := WorldBoundaryShape3D.new()  # infinite plane at y=0
	cs.shape = shape
	body.add_child(cs)
	_main.add_child(body)


func _remove_temp_floor() -> void:
	if _main == null:
		return
	var f := _main.get_node_or_null("TerrainLoaderTempFloor")
	if f != null:
		f.queue_free()
