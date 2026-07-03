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

const HALF_EXTENT_DEFAULT := 15000.0   # 30 km square
## Auto-vegetation + hi-res detail share the same mid-range square (~3 km / ~1.9 mi).
const AUTO_VEG_HALF_EXTENT := 1500.0
## High-resolution centre patch: same footprint as auto-veg so trees sit on hi-res mesh + drape.
const DETAIL_HALF_EXTENT := AUTO_VEG_HALF_EXTENT
# Centre drape resolution. pick_zoom() picks the highest ESRI zoom whose stitched
# width stays <= DETAIL_TARGET_PX, so this is the real lever on sharpness: 2048 px
# only reaches z17 (~1.5 m/px) on the 3 km patch, while 4096 px reaches z18
# (~0.8 m/px) — roughly 2× sharper for the centre the player actually inspects.
# The 4096² RGB8 drape is ~48 MB VRAM (+mips); imagery uploads on its own settle
# frame (step 5), separate from the mesh/collider/building spike, so it does not
# stack onto the load-phase GPU peak. ESRI serves this source up to z19–23 globally;
# push DETAIL_TARGET_PX to 8192 (z19, ~0.4 m/px) only if VRAM/stitch RAM allows.
const DETAIL_TARGET_PX := 4096
const DETAIL_MAX_ZOOM := 20
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
const PLACED_PROPS_UI_SCRIPT := preload("res://scenes/ui/placed_props_ui.gd")
const PLACED_PROP_EDIT_UI_SCRIPT: GDScript = preload("res://scenes/ui/placed_prop_edit_ui.gd")
const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")
const PLACED_PROP_SERVICE_SCRIPT := preload("res://core/placed_models/placed_prop_service.gd")
const CONFIG_PATH := "user://terrain_config.cfg"
## Set true to print TerrainLoader[mem] breadcrumbs during load.
const DEBUG_LOAD := false
## Idle frames between heavy GPU apply steps (mesh upload, shader compile, scatter).
const SETTLE_FRAMES := 3

var _main: Node = null
var _lat := 0.0
var _lon := 0.0
var _map_label := ""
var _half_extent := HALF_EXTENT_DEFAULT
var _from_resume := false

var _elev_grid := PackedFloat32Array()
var _elev_cols := 0
var _elev_rows := 0
var _elev_done := false
var _drape: Texture2D = null
var _img_done := false
var _detail_drape: Texture2D = null
var _built := false
var _spawn_ground_y := 0.0
var _built_grid := PackedFloat32Array()
var _built_center_elev := 0.0
var _built_extent := 0.0
var _explore_drone: FPVDrone = null
var _buildings_root: Node3D = null
var _buildings_data: Array = []
var _water_root: Node3D = null
var _water_data: Array = []
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
var _placed_prop_layer: PlacedPropLayer = null
var _placed_props_ui: Control = null
var _placed_prop_edit_ui: Control = null
var _building_focus_idx: int = -1
## OSM solar arrays built in-world but NOT auto-added to the graph. Each record:
## {name, poly, panel_count, watts, base_y, tilt, azimuth, tag, added}. The player
## targets one via the crosshair (see pick_solar_array_at_world) and confirms to add
## it to the system graph — nothing is added automatically on load.
var _solar_arrays: Array = []
var _solar_focus_idx: int = -1
var _solar_highlight: MeshInstance3D = null
## Persist which arrays the player already added across in-session terrain rebuilds
## (tag -> {count, watts}); drives the accumulated SolarUI generation total.
var _added_solar_tags: Dictionary = {}
var _veg_highlight: MeshInstance3D = null
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

var _load_overlay: TerrainLoadOverlay = null
var _load_progress: TerrainLoadProgress = null
var _load_ui_active := false
var _load_hint := ""
var _load_fast_path := false
var _detail_img_resolved := false
var _refresh_pending: Dictionary = {}
var _auto_veg_generate_queued := false
var _auto_veg_scatter_pending := false
var _auto_veg_scatter_regen := false
var _manual_veg_pending := false

## True while _run_load_sequence() owns the pipeline (callbacks must not kick off
## parallel fetches or GPU-heavy side effects).
var _load_sequence_active := false
var _phase_waiting := false
var _phase_key := ""
var _phase_ok := false


func _ready() -> void:
	_main = get_parent()
	# Deferred: Main is still "busy setting up children" during our _ready, so
	# add_child() on it would fail. By the deferred call Main is fully ready.
	_begin.call_deferred()


## Push the current weather-driven ground snow cover to the terrain shader(s).
## Cheap (two shader-param sets); runs only once terrain is built.
func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or not _built or _main == null:
		return
	if not _main.has_method("get_snow_amount"):
		return
	var snow := clampf(float(_main.call("get_snow_amount")), 0.0, 1.0)
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	for node_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(node_name) as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.material_override
		if mat is ShaderMaterial:
			(mat as ShaderMaterial).set_shader_parameter("snow_amount", snow)


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
	if event is InputEventKey and (event as InputEventKey).keycode == KEY_C \
			and (event as InputEventKey).pressed and not (event as InputEventKey).echo \
			and _camp_scatter_ui != null:
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
	var ctx := get_node_or_null("/root/MapContext")
	if ctx != null and ctx.has_pending:
		var d: Dictionary = ctx.consume()
		_lat = float(d["latitude"])
		_lon = float(d["longitude"])
		_map_label = str(d.get("label", ""))
		var he := float(d["half_extent_m"])
		_half_extent = he if he > 0.0 else HALF_EXTENT_DEFAULT
		_from_resume = bool(d.get("from_resume", false))
		return
	# Fallback: the scene's current coordinates (set by save-load / location prefs).
	if _main != null:
		var la: Variant = _main.get("latitude")
		var lo: Variant = _main.get("longitude")
		if la != null and lo != null:
			_lat = float(la)
			_lon = float(lo)


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
	var es := get_node_or_null("/root/ElevationService")
	if es != null and es.has_method("reset_session"):
		es.reset_session()

	# 1. Base DEM
	if es != null:
		_phase_begin("elev:base")
		es.request_elevation(_lat, _lon, _half_extent, ElevationService.DEFAULT_GRID_N, "base")
		if not await _phase_await(120.0):
			_apply_elevation_fallback("base")
		await _settle_gpu()
	else:
		_apply_elevation_fallback("base")

	# 2. Base imagery
	var img := get_node_or_null("/root/ImageryService")
	if img != null:
		_phase_begin("img:base")
		img.request_imagery(_lat, _lon, _half_extent)
		if not await _phase_await(180.0):
			_apply_imagery_fallback("base")
		await _settle_gpu()
	else:
		_apply_imagery_fallback("base")

	# 3. Build walkable terrain (base drape only — detail arrives later).
	_build_terrain()
	await _settle_gpu()

	# 4–9. Detail DEM, detail imagery, OSM overlays, vegetation, camps.
	await _run_post_terrain_sequence()

	if not _from_resume:
		_finalize_spawn_actors()

	_load_sequence_active = false
	_check_load_complete()
	_maybe_opentopo_hint()


func _run_post_terrain_sequence() -> void:
	# 4. Hi-res centre DEM. OpenTopography (key) delivers a single 512² AAIGrid;
	# without a key we still fetch via Open-Meteo — the ElevationService caps that
	# to OPENMETEO_DETAIL_N (64²) so the centre ~3 km gets ~47 m spacing (far finer
	# than the ~1.9 km base grid) at a bounded ~40-request cost. The result caches,
	# so the first load per site pays the fetch once and every reload is instant.
	# When Open-Meteo daily quota is exhausted and there is no OpenTopography key,
	# skip detail entirely so OSM + vegetation phases are not blocked for ~20 min.
	var es := get_node_or_null("/root/ElevationService")
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
		es.request_elevation(_lat, _lon, DETAIL_HALF_EXTENT,
			ElevationService.DETAIL_GRID_N, "detail")
		if await _phase_await(300.0):
			await _rebuild_heightfield_staggered(true)
		elif _recover_detail_dem_from_cache():
			await _rebuild_heightfield_staggered(true)
		else:
			_skip_detail_dem()
	else:
		if skip_detail:
			push_warning("TerrainLoader: skipping detail DEM — Open-Meteo daily quota exhausted")
			_toast("Elevation quota reached — skipping hi-res detail terrain for now.", ToastUI.Level.WARN)
		if _recover_detail_dem_from_cache():
			await _rebuild_heightfield_staggered(true)
		else:
			_skip_detail_dem()
	await _settle_gpu()

	# 5. Hi-res centre imagery + detail-drape shader.
	var img := get_node_or_null("/root/ImageryService")
	if img != null:
		_phase_begin("img:detail")
		img.request_imagery(_lat, _lon, DETAIL_HALF_EXTENT, DETAIL_TARGET_PX, "detail", DETAIL_MAX_ZOOM)
		if await _phase_await(180.0):
			_apply_detail()
			_resolve_detail_imagery()
		else:
			_resolve_detail_imagery()
	else:
		_resolve_detail_imagery()
	await _settle_gpu()

	# 6–7. OSM vectors -> buildings, then water.
	var bs := get_node_or_null("/root/BuildingService")
	if bs != null:
		_phase_begin("osm_map")
		var cfg := _terrain_config()
		bs.request_osm_vectors(_lat, _lon, AUTO_VEG_HALF_EXTENT, cfg.flatten_landuse)
		if await _phase_await(180.0):
			await _apply_osm_overlays()
		else:
			_load_progress_mark_done("osm_map")
	else:
		_load_progress_mark_done("osm_map")
	await _settle_gpu()

	# 8. OSM vegetation fetch + chunked scatter.
	if _terrain_config().show_auto_vegetation:
		var vs := get_node_or_null("/root/VegetationService")
		if vs != null:
			_phase_begin("osm_veg")
			vs.request_vegetation(_lat, _lon, AUTO_VEG_HALF_EXTENT)
			if await _phase_await(180.0):
				await _auto_veg_scatter_async(false)
			_load_progress_mark_done("osm_veg")
		else:
			_load_progress_mark_done("osm_veg")
	else:
		_load_progress_mark_done("osm_veg")
	await _settle_gpu()

	# 9. Camp generation (deterministic, optional).
	_attach_camps()
	await _settle_gpu()
	_refresh_water_reflection_probes()


func _apply_elevation_fallback(tag: String) -> void:
	if tag == "detail":
		_skip_detail_dem()
		return
	var recovered := ElevationService.find_usable_cached_dem(_lat, _lon, "base")
	if recovered.is_empty():
		recovered = ElevationService.find_usable_cached_dem(_lat, _lon)
	if not recovered.is_empty():
		push_warning("TerrainLoader: live elevation failed — using recovered cached DEM")
		_elev_grid = recovered["grid"]
		_elev_cols = int(recovered["cols"])
		_elev_rows = int(recovered["rows"])
		_elev_done = true
		_load_progress_mark_done("base_dem")
		_notify_options_status("Elevation fetch failed — using last cached terrain", "warn")
		_toast("Elevation fetch failed — using last cached terrain for this site.", ToastUI.Level.WARN)
		return
	push_warning("TerrainLoader: elevation fetch failed — using flat fallback")
	_notify_options_status(
		"Elevation unavailable (flat terrain) — Open-Meteo quota or network; add OpenTopography key",
		"warn")
	_toast("Elevation unavailable — using flat terrain (network/quota issue).", ToastUI.Level.WARN)
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
	var recovered := ElevationService.find_usable_cached_dem(_lat, _lon, "detail")
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
	var tilt := SolarArrayBuilder.default_tilt_deg(_lat)
	var azimuth := SolarArrayBuilder.default_azimuth_deg(_lat)
	var container := Node3D.new()
	container.name = "SolarArrays"
	terrain.add_child(container)
	var total := 0
	var idx := 0
	for rec in arrays:
		if not (rec is Dictionary):
			continue
		var poly: PackedVector2Array = (rec as Dictionary).get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var panels := SolarArrayBuilder.plan_panels(poly, tilt)
		if panels.is_empty():
			continue
		var base_y := _solar_array_base_y(poly, (rec as Dictionary).get("tags", {}))
		var node := SolarArrayBuilder.build_array_node("Array_%d" % idx, panels, base_y, tilt)
		container.add_child(node)
		var tag := _solar_array_tag(poly)
		_solar_arrays.append({
			"name": "Array_%d" % idx,
			"poly": poly,
			"panel_count": panels.size(),
			"watts": SolarArrayBuilder.PANEL_WATTS,
			"base_y": base_y,
			"tilt": tilt,
			"azimuth": azimuth,
			"tag": tag,
			"added": _added_solar_tags.has(tag),
		})
		total += panels.size()
		idx += 1
	if _solar_arrays.is_empty():
		container.queue_free()
		return
	var kw := float(total) * SolarArrayBuilder.PANEL_WATTS / 1000.0
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
		array_tag: String = "") -> void:
	if _main == null:
		return
	var sgv := _main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		sgv = get_tree().root.find_child("SystemGraphView", true, false)
	if sgv != null and sgv.has_method("add_imported_solar_panels"):
		sgv.call("add_imported_solar_panels", panel_count, watts, label, array_tag)


## ---------------------------------------------------------------------------
## OSM solar array crosshair selection (player targets an array → adds to graph)
## ---------------------------------------------------------------------------

func has_solar_arrays() -> bool:
	return not _solar_arrays.is_empty()


## Which built array footprint contains the world XZ point (topmost / smallest wins
## when nested). Returns {valid, array_idx}.
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


## Add the targeted array's panels to the system graph and fold its capacity into the
## accumulated SolarUI generation. Idempotent per array (keyed by tag).
func add_solar_array_to_graph(idx: int) -> bool:
	if idx < 0 or idx >= _solar_arrays.size():
		return false
	var rec: Dictionary = _solar_arrays[idx]
	if bool(rec.get("added", false)):
		return false
	var count := int(rec.get("panel_count", 0))
	if count <= 0:
		return false
	var watts := float(rec.get("watts", SolarArrayBuilder.PANEL_WATTS))
	var tag := str(rec.get("tag", ""))
	rec["added"] = true
	_added_solar_tags[tag] = {"count": count, "watts": watts}
	_feed_solar_graph(count, watts, "OSM Solar", tag)
	_refresh_added_solar_total()
	if idx == _solar_focus_idx:
		_clear_solar_highlight()
	var kw := float(count) * watts / 1000.0
	_notify_options_status("Added solar array: %d panels, %.2f kW → system graph" % [count, kw], "ok")
	print("TerrainLoader: added OSM solar array '%s' (%d panels, %.2f kW) to the system graph" % [tag, count, kw])
	return true


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


func _draw_solar_highlight(idx: int) -> void:
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
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.12, 0.12, 0.5)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_solar_highlight.material_override = mat
		terrain.add_child(_solar_highlight)
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
			_detail_elev_cols, _detail_elev_rows, DETAIL_HALF_EXTENT * 2.0])
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
				_request_detail_dem(es_svc)
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
			_finish_refresh("dem")
		return
	if _load_sequence_active:
		_phase_resolve("elev:base", false)
		return
	push_warning("TerrainLoader: elevation fetch failed (%s) — using flat fallback" % reason)
	_apply_elevation_fallback("base")
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
	if tag == "detail":
		_log_load_mem("detail img ready")
		_detail_drape = texture
		if _load_sequence_active:
			_phase_resolve("img:detail", true)
			return
		_resolve_detail_imagery()
		_apply_detail()
		_log_load_mem("detail applied")
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
				img_svc.request_imagery(_lat, _lon, DETAIL_HALF_EXTENT,
					DETAIL_TARGET_PX, "detail", DETAIL_MAX_ZOOM)
		return
	_img_done = true
	_try_build()


func _on_imagery_failed(reason: String, tag: String) -> void:
	if tag == "detail":
		push_warning("TerrainLoader: detail imagery failed (%s) — base drape only" % reason)
		if _load_sequence_active:
			_phase_resolve("img:detail", false)
			return
		_resolve_detail_imagery()
		_check_load_complete()
		if _built:
			_finish_refresh("imagery")
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


## Swap the Ground material to the high-res-centre shader once the detail patch
## arrives. If the terrain isn't built yet, _try_build() will pick up _detail_drape.
func _apply_detail() -> void:
	if not _built or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	var ground := terrain.get_node_or_null("Ground") as MeshInstance3D
	if ground != null:
		var hide := TerrainBuilder.has_detail_ground(terrain)
		ground.material_override = TerrainBuilder.make_terrain_material(
			_drape, _detail_drape, _built_extent, DETAIL_HALF_EXTENT * 2.0,
			false, false, hide)
	if _detail_drape == null:
		return
	var detail_ground := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	if detail_ground != null:
		detail_ground.material_override = TerrainBuilder.make_terrain_material(
			_drape, _detail_drape, _built_extent, DETAIL_HALF_EXTENT * 2.0, true, false)
	print("TerrainLoader: applied high-res centre drape (%.0f m square)" % (DETAIL_HALF_EXTENT * 2.0))
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
	_apply_building_textures()
	_queue_auto_veg_generate(_auto_veg_generated)
	print("TerrainLoader: imagery drape refreshed")


func _on_osm_vectors_ready(_key: String, payload: Dictionary) -> void:
	_osm_vectors = payload
	_buildings_data = payload.get("buildings", []) as Array
	_water_data = payload.get("water", []) as Array
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


func _attach_buildings(enable_shadows: bool = true) -> void:
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
		_detail_surface_grid = grids["detail_surface"]
	_clear_building_nodes(terrain)
	var detail_cols := _detail_elev_cols if not _detail_surface_grid.is_empty() else 0
	var detail_rows := _detail_elev_rows if not _detail_surface_grid.is_empty() else 0
	var excluded: Array = []
	if _placed_prop_layer != null:
		excluded = _placed_prop_layer.get_replaced_building_indices()
	var visible_buildings := _features_intersecting_square(_buildings_data, DETAIL_HALF_EXTENT)
	var node := BuildingBuilder.build_buildings_node(
		visible_buildings, _built_grid, MESH_RES, _built_extent, _built_center_elev,
		_drape, _detail_drape, DETAIL_HALF_EXTENT * 2.0, _built_extent,
		_detail_surface_grid, detail_cols, detail_rows, excluded, enable_shadows)
	if node == null:
		return
	terrain.add_child(node)
	_buildings_root = node
	print("TerrainLoader: extruded %d OSM buildings (natural footing, hi-res drape=%s)" % [
		visible_buildings.size(), "yes" if _detail_drape != null else "base only"])


func _attach_water() -> void:
	if _main == null:
		return
	var cfg := _terrain_config()
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	var old := terrain.get_node_or_null("Water")
	if old != null:
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
		_detail_surface_grid, detail_res, DETAIL_HALF_EXTENT * 2.0)
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
	var roads: Array = _osm_vectors.get("roads", []) as Array
	var road_pts := BrcCampGenerator.count_road_points(roads)
	print("TerrainLoader._attach_camps: roads=%d ways, road_pts=%d (need>=%d)" % [
		roads.size(), road_pts, BrcCampGenerator.MIN_ROAD_SEGMENTS])
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
		height_extent = DETAIL_HALF_EXTENT * 2.0
	var seed := _camp_seed()
	print("TerrainLoader._attach_camps: generating (seed=%d, height_grid_size=%d, extent=%.0f)" % [
		seed, height_grid.size(), height_extent])
	var node := BrcCampGenerator.build_camps_node(
		roads, _buildings_data, height_grid, height_res, height_extent,
		_built_center_elev, DETAIL_HALF_EXTENT, seed, _load_camp_profiles(), _main,
		PackedVector2Array(), BrcCampGenerator.FILL_PROBABILITY, 0.0, 0.9, 1.18,
		cfg.camp_exclusion_r)
	if node == null:
		print("TerrainLoader._attach_camps: build_camps_node returned null")
		return
	terrain.add_child(node)
	_camps_root = node
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


## Convex hull of all road points — the camp scatter UI's "BRC Auto" area.
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

	var roads: Array = _osm_vectors.get("roads", []) as Array
	var density := float(params.get("density", BrcCampGenerator.FILL_PROBABILITY))
	var mix_bias := float(params.get("mix_bias", 0.0))
	var scale_min := float(params.get("scale_min", 0.9))
	var scale_max := float(params.get("scale_max", 1.18))
	var use_seed := int(params.get("seed", _camp_seed()))
	var excl_r := float(params.get("exclusion_radius_m", _terrain_config().camp_exclusion_r))

	if _footing_grid.is_empty():
		_footing_grid = _compose_terrain_grids()["footing"]
	var height_grid := _footing_grid
	var height_res := MESH_RES
	var height_extent := _built_extent
	if not _detail_surface_grid.is_empty() and _detail_elev_cols > 1:
		height_grid = _detail_surface_grid
		height_res = _detail_elev_cols
		height_extent = DETAIL_HALF_EXTENT * 2.0

	var node := BrcCampGenerator.build_camps_node(
		roads, _buildings_data, height_grid, height_res, height_extent,
		_built_center_elev, DETAIL_HALF_EXTENT, use_seed,
		_load_camp_profiles(), _main,
		poly, density, mix_bias, scale_min, scale_max, excl_r)
	if node == null:
		return 0
	terrain.add_child(node)
	_camps_root = node
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
	if _buildings_root == null:
		return
	var mi := _buildings_root.get_node_or_null("BuildingMeshes") as MeshInstance3D
	if mi == null:
		return
	mi.material_override = null
	mi.set_surface_override_material(0, BuildingBuilder.make_wall_material())
	if mi.mesh != null and mi.mesh.get_surface_count() > 1:
		mi.set_surface_override_material(1, BuildingBuilder.make_roof_material())


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
	_built_grid = grid
	_built_center_elev = center_elev
	_built_extent = extent
	_terrain_edits = TerrainEditGrid.create_empty(MESH_RES)
	_terrain_edits.load_for_map(_lat, _lon)
	_spawn_ground_y = TerrainBuilder.height_at_world_xz(grid, MESH_RES, extent, center_elev, 0.0, 0.0)
	var terrain := TerrainBuilder.build_terrain_node(grid, MESH_RES, extent, center_elev,
		_drape, null, DETAIL_HALF_EXTENT * 2.0)
	terrain.name = "Terrain"
	if _main != null:
		_main.add_child(terrain)

	_remove_temp_floor()
	if not _from_resume:
		_reseat_player.call_deferred()
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
	# Buildings exist by now, so nudge the player off any footprint at the centre
	# BEFORE the ground sync and drone spawn (both key off the player XZ).
	_relocate_player_off_buildings()
	_sync_actors_to_ground(true)
	var player := _main.get_node_or_null("Player")
	if player != null:
		_spawn_explore_drone(player.global_position)


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


func _detail_footing_grid() -> PackedFloat32Array:
	if not _detail_surface_grid.is_empty():
		return _detail_surface_grid
	if _detail_elev_done and not _detail_elev_grid.is_empty():
		_detail_surface_grid = _compose_detail_surface(true)
		return _detail_surface_grid
	return PackedFloat32Array()


func _ground_height_at(x: float, z: float) -> float:
	var detail := _detail_footing_grid()
	var in_detail := absf(x) <= DETAIL_HALF_EXTENT and absf(z) <= DETAIL_HALF_EXTENT
	var fallback := PackedFloat32Array()
	if in_detail and detail.is_empty() and _detail_elev_resolved:
		fallback = _compose_base_footing_grid(true)
	var y := TerrainBuilder.sample_footing_height(
		x, z, _built_grid, MESH_RES, _built_extent, _built_center_elev,
		detail, _detail_elev_cols, _detail_elev_rows, DETAIL_HALF_EXTENT * 2.0,
		fallback)
	if _built_grid.is_empty() and detail.is_empty():
		return _spawn_ground_y
	return y


func _sync_actors_to_ground(force: bool = false) -> void:
	if _main == null:
		return
	var player := _main.get_node_or_null("Player") as CharacterBody3D
	if player != null:
		var pos := player.global_position
		var gy := _ground_height_at(pos.x, pos.z)
		var target_y := gy + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M
		if force or absf(pos.y - target_y) > 0.35:
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
		if force or absf(dpos.y - dtarget) > 0.35:
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
func _request_detail_dem(es: Object) -> void:
	es.request_elevation(_lat, _lon, DETAIL_HALF_EXTENT,
		ElevationService.DETAIL_GRID_N, "detail")


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
	return _terrain_config()


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


func set_cache_enabled(on: bool) -> void:
	TerrainCacheSettings.set_cache_enabled(on)


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
	var n := TerrainCacheSettings.invalidate_dem(_lat, _lon)
	_begin_dem_refetch()
	print("TerrainLoader: refreshing DEM (%d cache file(s) cleared) …" % n)


## Delete cached imagery and re-fetch base + centre drape.
func refresh_imagery() -> void:
	if not _built:
		return
	_begin_refresh("imagery")
	var n := TerrainCacheSettings.invalidate_imagery(_lat, _lon)
	_begin_imagery_refetch()
	print("TerrainLoader: refreshing imagery (%d cache file(s) cleared) …" % n)


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
	var n := TerrainCacheSettings.invalidate_all(_lat, _lon)
	_begin_dem_refetch()
	_begin_imagery_refetch()
	_begin_osm_vectors_refetch()
	_begin_osm_vegetation_refetch()
	print("TerrainLoader: refreshing all terrain layers (%d cache file(s) cleared) …" % n)


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


func _begin_dem_refetch() -> void:
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
	es.request_elevation(_lat, _lon, _half_extent, ElevationService.DEFAULT_GRID_N, "base")
	# Detail DEM is requested after base completes (_on_elevation_ready refresh path).


func _begin_imagery_refetch() -> void:
	var img := get_node_or_null("/root/ImageryService")
	if img == null:
		push_warning("TerrainLoader: ImageryService unavailable")
		return
	img.request_imagery(_lat, _lon, _half_extent)
	# Detail imagery is applied after base in _on_imagery_ready refresh path.


func _begin_osm_vectors_refetch() -> void:
	var bs := get_node_or_null("/root/BuildingService")
	if bs == null:
		push_warning("TerrainLoader: BuildingService unavailable")
		return
	var cfg := _terrain_config()
	bs.request_osm_vectors(_lat, _lon, AUTO_VEG_HALF_EXTENT, cfg.flatten_landuse)


func _begin_osm_vegetation_refetch() -> void:
	_auto_veg_data = {}
	_auto_veg_generated = false
	var vs := get_node_or_null("/root/VegetationService")
	if vs == null:
		push_warning("TerrainLoader: VegetationService unavailable")
		return
	if not _terrain_config().show_auto_vegetation:
		_clear_auto_vegetation()
		return
	vs.request_vegetation(_lat, _lon, AUTO_VEG_HALF_EXTENT)


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
	var extent := DETAIL_HALF_EXTENT * 2.0
	var grid := _detail_elev_grid.duplicate()
	var coarse := _compose_base_footing_grid(false)
	grid = TerrainBuilder.feather_detail_to_coarse(
		grid, res, extent, coarse, MESH_RES, _built_extent, _built_center_elev)
	var cfg := _terrain_config()
	if cfg.flatten_roads and not _osm_vectors.is_empty():
		grid = TerrainRoadFlatten.apply_road_corridors(
			grid, res, extent, _osm_vectors.get("roads", []))
	if cfg.flatten_landuse and not _osm_vectors.is_empty():
		grid = TerrainRoadFlatten.apply_polygon_flattens(
			grid, res, extent, _osm_vectors.get("landuse", []))
	if apply_user_edits and _terrain_edits != null:
		grid = _apply_edits_to_detail(grid, res, extent)
	return grid


func _compose_terrain_grids(apply_user_edits: bool = true) -> Dictionary:
	var coarse_foot := _compose_base_footing_grid(apply_user_edits)
	var detail_surf := _compose_detail_surface(apply_user_edits)
	var built := coarse_foot
	if not detail_surf.is_empty():
		built = TerrainBuilder.patch_centre_heights(
			coarse_foot, MESH_RES, detail_surf, _detail_elev_cols,
			_built_extent, DETAIL_HALF_EXTENT * 2.0, 40.0)
		TerrainBuilder.sink_coarse_centre_for_detail(
			built, MESH_RES, _built_extent, DETAIL_HALF_EXTENT * 2.0, _built_center_elev)
	return {
		"footing": built,
		"built": built,
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


func _rebuild_heightfield(skip_overlays: bool = false) -> void:
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
	_finish_heightfield_rebuild(had_detail)


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


## Recompose the terrain grids and refresh the synchronous footing state every
## consumer reads. Returns the Terrain node (or null when not ready).
func _begin_heightfield_rebuild() -> Node3D:
	if not _built or _base_dem_grid.is_empty():
		return null
	var grids := _compose_terrain_grids()
	_footing_grid = grids["footing"]
	_built_grid = grids["built"]
	_detail_surface_grid = grids["detail_surface"]
	_spawn_ground_y = TerrainBuilder.height_at_world_xz(
		_built_grid, MESH_RES, _built_extent, _built_center_elev, 0.0, 0.0)
	return _main.get_node_or_null("Terrain") if _main != null else null


## Coarse Ground mesh + collider (and drop any detail patch when detail is gone).
func _rebuild_coarse_surface(terrain: Node3D) -> void:
	if not _detail_surface_grid.is_empty():
		TerrainBuilder.rebuild_terrain_surfaces(
			terrain, _built_grid, MESH_RES, _built_extent, _built_center_elev,
			_drape, _detail_drape, DETAIL_HALF_EXTENT * 2.0, false)
	else:
		TerrainBuilder.remove_detail_patch(terrain)
		TerrainBuilder.rebuild_terrain_surfaces(
			terrain, _built_grid, MESH_RES, _built_extent, _built_center_elev,
			_drape, _detail_drape, DETAIL_HALF_EXTENT * 2.0, false)


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
	TerrainBuilder.upsert_detail_patch(
		terrain, mesh_grid, mesh_res, DETAIL_HALF_EXTENT * 2.0,
		_built_center_elev, _drape, _detail_drape, _built_extent)
	print("TerrainLoader: hi-res centre mesh %d×%d (%.0f m, ~%.1f m/vertex)" % [
		mesh_res, mesh_res, DETAIL_HALF_EXTENT * 2.0,
		(DETAIL_HALF_EXTENT * 2.0) / float(maxi(mesh_res - 1, 1))])


## Re-ground dynamic content and re-seat actors after a heightfield change.
func _finish_heightfield_rebuild(had_detail: bool) -> void:
	_reground_vegetation()
	_reground_placed_props()
	if _auto_veg_generated:
		_reground_auto_vegetation()
	_detail_collision_active = not _detail_surface_grid.is_empty()
	if _detail_collision_active and (not had_detail or _actors_off_ground()):
		_sync_actors_to_ground(not had_detail)


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


func open_vegetation_preview_editor(initial_preset: int = -1) -> void:
	if _vegetation_preview_ui != null and _vegetation_preview_ui.has_method("open"):
		_vegetation_preview_ui.call("open", initial_preset)


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


func _setup_vegetation() -> void:
	_vegetation_layer = VegetationLayer.create_empty()
	_vegetation_layer.load_for_map(_lat, _lon)
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
		false, _auto_veg_runtime_settings())


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


func get_vegetation_settings() -> Dictionary:
	if _vegetation_layer == null:
		return VegetationLayer.default_settings()
	return _vegetation_layer.get_settings()


func get_map_vegetation_bounds() -> PackedVector2Array:
	var he := _half_extent
	return PackedVector2Array([
		Vector2(-he, -he), Vector2(he, -he), Vector2(he, he), Vector2(-he, he),
	])


func set_vegetation_settings(patch: Dictionary, rebuild: bool = true, persist: bool = true) -> void:
	if _vegetation_layer == null:
		return
	_vegetation_layer.apply_settings(patch)
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
	VegetationRuntime.reground(terrain, _vegetation_layer, Callable(self, "_ground_height_at"))


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
		_clear_auto_vegetation()
		return
	var vs := get_node_or_null("/root/VegetationService")
	if vs == null:
		push_warning("TerrainLoader: VegetationService unavailable")
		_load_progress_mark_done("osm_veg")
		_check_load_complete()
		return
	vs.request_vegetation(_lat, _lon, AUTO_VEG_HALF_EXTENT)


func _on_vegetation_osm_ready(_key: String, payload: Dictionary) -> void:
	_auto_veg_data = payload
	if _load_sequence_active:
		_phase_resolve("osm_veg", true)
		return
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
		return
	if not _terrain_config().show_auto_vegetation:
		return
	if _auto_veg_generated and not regen_for_exclusions:
		return
	await get_tree().process_frame
	if not _built:
		return
	print("TerrainLoader: scattering vegetation from OSM (background) …")
	var ctx := _auto_veg_ctx()
	var state := AutoVegetationGenerator.prepare_context(_auto_veg_data, ctx)
	while AutoVegetationGenerator.scatter_batch(state, SCATTER_BATCH_POLYS):
		var pct := int(round(state.progress_ratio() * 100.0))
		_load_hint = "Scattering trees… %d%%" % pct
		await get_tree().process_frame
		if not _built:
			return
	_auto_veg_layer = state.layer
	_apply_auto_veg_edits()
	_auto_veg_generated = true
	await get_tree().process_frame
	if not _built:
		return
	await _rebuild_auto_vegetation_async()
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


## True once stage-2 detail elevation has succeeded or failed (never while pending).
func _auto_veg_ground_ready() -> bool:
	return _detail_elev_resolved


func _auto_veg_ctx() -> Dictionary:
	var gate: LandcoverImageryGate = null
	if _drape != null and _built_extent > 0.0:
		var detail_ext := DETAIL_HALF_EXTENT * 2.0 if _detail_drape != null else 0.0
		gate = LandcoverImageryGate.from_texture_downsampled(
			_drape, _built_extent, 512, _detail_drape, detail_ext, 512)
	return {
		"latitude": _lat,
		"half_extent_m": AUTO_VEG_HALF_EXTENT,
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
		var detail_ext := DETAIL_HALF_EXTENT * 2.0 if _detail_drape != null else 0.0
		var gate := LandcoverImageryGate.from_texture_downsampled(
			_drape, _built_extent, 512, _detail_drape, detail_ext, 512)
		if gate != null and gate.is_valid():
			s["haze_color"] = gate.compute_haze_color()
	s.merge(_vegetation_layer.get_settings() if _vegetation_layer != null else {}, true)
	return s


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
		Callable(self, "_ground_height_at"), settings, exclusions)


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
		Callable(self, "_ground_height_at"), settings, exclusions)
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
	_auto_veg_layer = AutoVegetationGenerator.generate(_auto_veg_data, _auto_veg_ctx())
	_apply_auto_veg_edits()
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
	_vegetation_layer.apply_settings(shape)
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


func _forest_params_changed(prev: Dictionary, next: Dictionary) -> bool:
	for key in ["forest_auto_min_area_m2", "forest_trunk_spacing_m", "forest_canopy_height_m"]:
		if absf(float(next.get(key, 0.0)) - float(prev.get(key, 0.0))) > 0.01:
			return true
	if absf(float(next.get("auto_density_scale", 1.0)) - float(prev.get("auto_density_scale", 1.0))) > 0.01:
		return true
	if _osm_species_map_changed(prev, next):
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
	_auto_veg_layer = AutoVegetationGenerator.generate(_auto_veg_data, _auto_veg_ctx())
	_apply_auto_veg_edits()
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
		var est := VegetationPaint.estimate_hex_fill_count(poly, mat_w, fill_cap)
		cap = mini(cap, est)
		spots = VegetationPaint.hex_grid_fill(poly, mat_w, existing, cap)
		scale_min = 1.0
		scale_max = 1.0
	else:
		var est_slots := int(area / (spacing * spacing * 0.866)) + 8
		cap = mini(mini(est_slots, fill_cap), cap)
		spots = VegetationPaint.poisson_fill(poly, spacing, rng, existing, cap)
	# Optional per-brush look snapshot ("Apply to brush"): stamped onto every new
	# instance so these trees keep their custom look regardless of later map edits.
	var brush_card: Dictionary = params.get("card_settings", {}) if params.get("card_settings") is Dictionary else {}
	var added := 0
	for spot in spots:
		var species := VegetationPaint.pick_species(
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
		_vegetation_layer.save(_lat, _lon)
		_rebuild_vegetation()
	return added


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
			use_extent = DETAIL_HALF_EXTENT * 2.0
	else:
		var detail := _compose_detail_surface(false)
		if not detail.is_empty():
			_detail_surface_grid = detail
			use_grid = detail
			use_res = _detail_elev_cols
			use_extent = DETAIL_HALF_EXTENT * 2.0
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
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var space: PhysicsDirectSpaceState3D = _main.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 50000.0)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# Sunk coarse TerrainCollision sits under DetailGround — exclude it when hi-res footing exists.
	if not _detail_footing_grid().is_empty():
		var terrain := _main.get_node_or_null("Terrain")
		var coarse := terrain.get_node_or_null("TerrainCollision") if terrain != null else null
		if coarse is CollisionObject3D:
			query.exclude = [(coarse as CollisionObject3D).get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	var p: Vector3 = hit["position"]
	p.y = _ground_height_at(p.x, p.z)
	return p


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
	var use_extent := DETAIL_HALF_EXTENT * 2.0 if not detail.is_empty() else _built_extent
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

func _setup_placed_props() -> void:
	_placed_prop_layer = PlacedPropLayer.create_empty()
	_placed_prop_layer.load_for_map(_lat, _lon)
	_setup_placed_props_ui()
	_setup_placed_prop_edit_ui()
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
	_sync_actors_to_ground(true)


func _attach_imported_ibc(model_id: String, ibc_info: Variant) -> void:
	if not (ibc_info is Dictionary):
		return
	BUNDLE_IMPORTER_SCRIPT.attach_ibc_to_imported_canopy(get_tree(), model_id, ibc_info as Dictionary)


func _apply_imported_graph(graph_state: Dictionary) -> void:
	if graph_state.is_empty() or _main == null:
		return
	var sgv := _main.get_node_or_null("UILayer/SystemGraphView")
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
	PlacedPropRuntime.rebuild(terrain, _placed_prop_layer, Callable(self, "_ground_height_at"))


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


## Remove every Buildings overlay under Terrain (sync). queue_free() alone leaves
## duplicates when _attach_buildings runs more than once per frame — get_node only
## finds the first child and later copies stack at different footing heights.
func _clear_building_nodes(terrain: Node) -> void:
	if terrain == null:
		_buildings_root = null
		return
	for i in range(terrain.get_child_count() - 1, -1, -1):
		var child := terrain.get_child(i)
		if child.name == "Buildings":
			terrain.remove_child(child)
			child.free()
	_buildings_root = null


func is_building_replaced(building_idx: int) -> bool:
	if _placed_prop_layer == null:
		return false
	return _placed_prop_layer.is_building_replaced(building_idx)


func get_building_focus_idx() -> int:
	return _building_focus_idx


func set_building_focus_idx(idx: int) -> void:
	_building_focus_idx = idx


func pick_building_at_world(x: float, z: float) -> Dictionary:
	return BuildingPicker.pick_at_xz(_buildings_data, x, z)


func pick_building_at_screen(screen_pos: Vector2) -> Dictionary:
	var hit: Variant = terrain_pick_ray(screen_pos)
	if hit == null:
		return {"valid": false}
	var p: Vector3 = hit as Vector3
	return pick_building_at_world(p.x, p.z)


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
		model_id, x, NAN, z, 0.0, 0.0, 0.0, 1.0, gy)
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
		centroid.x, gy, centroid.y, 0.0, 0.0, 0.0, fit_scale, gy)
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
	if not _placed_prop_layer.remove_prop(prop_id):
		return false
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
