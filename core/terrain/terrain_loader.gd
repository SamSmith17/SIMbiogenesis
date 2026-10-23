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

# Sizes are HALF-extents (centre to edge); TerrainExtents owns the rules.
const HALF_EXTENT_DEFAULT := TerrainExtents.WORLD_HALF_DEFAULT     # 30 km square
const DETAIL_HALF_EXTENT_DEFAULT := TerrainExtents.DETAIL_HALF_DEFAULT
const OSM_HALF_EXTENT_DEFAULT := TerrainExtents.OSM_HALF_DEFAULT
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
const QUALITY_TIER_COUNT := TerrainImageryPlan.TIER_COUNT
const QUALITY_TIER_DEFAULT := TerrainImageryPlan.TIER_DEFAULT
const QUALITY_TIER_NAMES := TerrainImageryPlan.TIER_NAMES
## Detail-drape stitch target (px) per tier — the real lever on centre sharpness.
const QUALITY_DETAIL_TARGET_PX := TerrainImageryPlan.DETAIL_TARGET_PX
## Hyper (sharpest) layer half-extent (m) per tier — how far the crispest imagery
## reaches from the site centre across the walkable zone.
const QUALITY_HYPER_HALF_EXTENT := TerrainImageryPlan.HYPER_HALF_EXTENT
## Hyper stitch target (px) per tier (an explicit [terrain] hyper_target_px still wins).
const QUALITY_HYPER_TARGET_PX := TerrainImageryPlan.HYPER_TARGET_PX
## "Site" patch half-extent (m) per tier: the property at the best source's
## NATIVE resolution (ImagerySources — a county orthophoto where one is
## listed, else ESRI z19), BC7-compressed, over hyper. 0 = off. Hyper alone
## on High/Ultra spreads one 8192 px texture over 2–3 km (0.25–0.37 m/px),
## coarser than the source; this patch keeps the walkable core native.
## Shrunk automatically to what fits SITE_TARGET_PX at the native zoom.
## Override `[terrain] site_half_extent_m` (0 disables).
const QUALITY_SITE_HALF_EXTENT := TerrainImageryPlan.SITE_HALF_EXTENT
const SITE_TARGET_PX := TerrainImageryPlan.SITE_TARGET_PX

## AI "hero" patch: an opt-in Gemini-enhanced ground drape over a small square
## centred on the map origin, overlaid on top of hyper where the player spawns.
## One 2K image per site, cached, so it is a one-time API cost. Default OFF.
## Half-extent (m) — 50 m ⇒ 100 m square ⇒ ~0.05 m/px at 2K (≈5× sharper than hyper).
const AI_HERO_HALF_EXTENT_DEFAULT := 50.0
const AI_IMAGE_SIZE_DEFAULT := "2K"

## A resumed player saved this far above the ground (or any amount below it)
## is in another frame — the world was rebuilt at another size — and is
## reseated. Generous, so someone saved on a roof or a hill-top deck stays put.
const RESUME_MAX_ABOVE_GROUND_M := 40.0
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
const _IMAGERY_SERVICE := preload("res://core/terrain/imagery_service.gd")
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
const EDIT_TOOLBAR_UI_SCRIPT := preload("res://scenes/ui/toolbar/edit_toolbar_ui.gd")
const TERRAIN_OPTIONS_UI_SCRIPT := preload("res://scenes/ui/terrain_options_ui.gd")
const VEGETATION_EDIT_UI_SCRIPT := preload("res://scenes/ui/vegetation_edit_ui.gd")
const VEGETATION_PREVIEW_EDITOR_SCRIPT := preload("res://scenes/ui/vegetation_preview_editor.gd")
const CAMP_SCATTER_UI_SCRIPT := preload("res://scenes/ui/camp_scatter_ui.gd")
const SPACE_EDIT_UI_SCRIPT := preload("res://scenes/ui/space_edit_ui.gd")
const PLACED_PROPS_UI_SCRIPT := preload("res://scenes/ui/placed_props_ui.gd")
const PLACED_PROP_EDIT_UI_SCRIPT: GDScript = preload("res://scenes/ui/placed_prop_edit_ui.gd")
const BUILDING_BUILDER_MODAL_SCRIPT := preload("res://scenes/ui/building_builder_modal.gd")
const POND_EDIT_MODAL_SCRIPT := preload("res://scenes/ui/pond_edit_ui.gd")
const VEG_AREA_FILL_UI_SCRIPT := preload("res://scenes/ui/veg_area_fill_ui.gd")
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
## Points of interest (core/poi/): KML pins imported from Google Earth, one
## layer per site through WorldPaths, drawn by a PoiRuntime under Terrain.
var pois: PoiLayer = null
var _pois_path := ""
var _poi_runtime: PoiRuntime = null
var _show_pois := true
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
## Native-resolution site patch drape + the half-extent it was fetched at.
var _site_drape: Texture2D = null
var _site_half_m := 0.0
## Hyper patch half-extent the CURRENT hyper drape was requested at (0 = none):
## the tier or the hi-res patch can change between request and arrival.
var _hyper_half_m := 0.0
## The half-extents of the hyper / site drapes actually ON SCREEN (the two
## above are the latest request's): a request that fails with nothing to fall
## back to restores these, so the layer still showing keeps its own size.
var _hyper_drape_half := 0.0
var _site_drape_half := 0.0
## Per-world imagery (see "Per-world imagery"): the world's mode, its imported
## imagery tier, the tier a failed download falls back to, the tier each layer
## was last asked for at, and the layers that fell back this session.
var _imagery_mode := "local"
var _imagery_saved_tier := -1
var _imagery_fallback_tier := -1
var _imagery_tag_tier := {}
var _imagery_tag_shown := {}
## The cache key each layer was last asked for. A result with another key is
## an earlier request finishing late (a mode switch while it downloaded) and is
## dropped — it would otherwise put the previous mode's layer back on screen.
var _imagery_tag_key := {}
var _imagery_fell_back := {}
## A base / detail DEM that landed after its load phase had given up waiting
## (the world went on flat or without the hi-res patch): applied once the load
## sequence finishes instead of being dropped on the floor.
var _late_base_dem := false
var _late_detail_dem := false
## Why the base DEM failed this load (ElevationService's reason). The phase
## await only reports true/false, so a refused fetch used to be reported as
## "timed out waiting for elevation" — which hid the Open-Meteo quota answer.
var _base_elev_fail_reason := ""
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
## Player-painted camp areas (core/camps/). Separate from the street-following
## `_camps_root` above: these are saved per map and survive every regenerate.
var camp_areas: CampAreaLayer = null
var _camp_areas_path := ""
var _camp_area_runtime: CampAreaRuntime = null
var _camp_excl_index: RefCounted = null
var _camp_undo: Array = []
var _camp_highlight: MeshInstance3D = null
var _camp_style_modal: Control = null
var _camp_focus_id := ""
const CAMP_UNDO_MAX := 24
var _base_dem_grid := PackedFloat32Array()
var _detail_elev_grid := PackedFloat32Array()
var _detail_elev_cols := 0
var _detail_elev_rows := 0
var _detail_elev_done := false
var _detail_elev_resolved := false
var _osm_vectors: Dictionary = {}
var _terrain_edits: TerrainEditGrid = null
var _terrain_edit_ui: Control = null
## The unified edit toolbar (scenes/ui/toolbar/) — coexists with the legacy
## T/V docks (now on Shift+T / Shift+V) until it fully replaces them.
var _edit_toolbar_ui: Control = null
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
## Vegetation growth is a PURE FUNCTION of the calendar (VegGrowthModel): each
## plant's birth year rides its MultiMesh instance data and the shaders evaluate
## its size from one `growth_year` uniform. The loader's whole job is to say what
## year it is (_push_growth_year) and to stamp a birth year on painted plants.
## There is no growth clock, no tick and no kill-and-reseed pass any more.
var _growth_year_pushed := NAN
var _growth_frozen_pushed := false
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
## Camera keyframes for the hyperlapse export, each pinned to a timeline
## moment (ClimelapseKeyframes). Saved per world (WorldPaths kind
## "climelapse_keys"), loaded lazily on first use.
var _clim_keys: ClimelapseKeyframes = null
var _clim_preview: ClimelapsePreview = null
var _clim_path_editor: Control = null
var _placed_prop_layer: PlacedPropLayer = null
## Linkage fold-to-pack sweeps currently animating (prop_id → true) — a
## second Pack press mid-fold must not double-toggle the sweep.
var _pack_anim_in_flight: Dictionary = {}
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
## The player's MAX FILL LEVEL per still-water body (tag -> world Y): a dam
## above the basin's natural rim. The spill height becomes max(basin rim,
## this), so inflow can raise the pond past the rim, capacity grows as a
## vertical wall over the footprint (area x extra depth) and the graph tank's
## rim follows. Persisted in the user_water file; map ponds carry it too.
var _pond_max_levels: Dictionary = {}
## tag -> PondLevelHandle (the grabbable surface in the world).
var _pond_level_handles: Dictionary = {}
var _veg_area_fill_ui: Control = null
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
## Separate mesh for the crosshair-focused OSM area outline (Phase 8) — it and
## the paint selection used to fight over one node.
var _veg_area_highlight: MeshInstance3D = null
## Crosshair-focused OSM vegetation area (index into _auto_veg_data["polygons"]).
## Highlighted like buildings; Interact / the O action opens the Tune look modal
## seeded to that area's veg type (see pick_veg_area_at_world / open_veg_area_modal).
var _veg_focus_idx: int = -1
var _veg_focus_area: Dictionary = {}
var _footing_grid := PackedFloat32Array()
var _detail_surface_grid := PackedFloat32Array()
var _detail_collision_active := false
const DRONE_GROUND_CLEARANCE_M := 1.5
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
## The DELTA STACK. `_edit_tiles` above is the PLAYER layer (sculpt tools,
## undo, saved to terrain_tiles_*.bin). `_channel_tiles` is PROCEDURAL — the
## waterway channels the WaterNetwork carves, regenerated from the stream
## features and never in player undo. `_composed_tiles` = channel + player,
## summed per touched tile; it is what the HeightField renders and the
## DetailGround sink reads. Ground queries sum the two layers directly
## (`_edit_tile_delta`), so they are exact even before a recompose.
var _channel_tiles: TerrainEditTiles = null
var _composed_tiles: TerrainEditTiles = null
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
## Phase 3b: in-process impostor baker (windowed only) + rebuild debounce so
## a burst of bake completions triggers ONE veg rebuild.
var _impostor_baker: VegImpostorBaker = null
var _impostor_rebuild_pending := false
## Far-tier reach the current veg build was made with (_impostor_reach_m).
var _impostor_reach_built_m := 0.0
var _impostor_reach_rebuild_pending := false
## Globe lens / snowglobe orbit cap (graph_soi_preview_service + 
## soi_snowglobe_camera MAX_ORBIT_MULT) and the 256 m chunk half-diagonal.
const IMPOSTOR_GLOBE_ORBIT_MULT := 4.5
const IMPOSTOR_CHUNK_HALF_DIAG_M := 182.0
const IMPOSTOR_REACH_MAX_M := 8000.0

## True while _run_load_sequence() owns the pipeline (callbacks must not kick off
## parallel fetches or GPU-heavy side effects).
var _load_sequence_active := false
var _phase_waiting := false
var _phase_key := ""
var _phase_ok := false


func _ready() -> void:
	ServiceLocator.provide(ServiceLocator.TERRAIN_LOADER, self)
	add_to_group(WorldSession.PERSIST_GROUP)
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
	if _veg_hidden:
		_veg_hide_poll -= delta
		if _veg_hide_poll <= 0.0:
			_veg_hide_poll = 0.5
			_apply_vegetation_visibility()
	_push_growth_year()
	_apply_water_flow(delta)
	PerfMonitor.end("terrain_tick")
	PerfMonitor.begin("terrain_season")
	_tick_season_uniforms()
	PerfMonitor.end("terrain_season")


## The snow / leaf-litter / floor-moss uniforms on the ground and building
## materials. Litter is change-gated on the season; snow is pushed whenever the
## amount or depth moved since the last push.
func _tick_season_uniforms() -> void:
	if not _main.has_method("get_snow_amount"):
		return
	var snow := clampf(float(_main.call("get_snow_amount")), 0.0, 1.0)
	var depth_m := 0.0
	if _main.has_method("get_snow_depth_m"):
		depth_m = clampf(float(_main.call("get_snow_depth_m")), 0.0, SeasonModel.SNOW_DEPTH_MAX_M)
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var litter := 0.0
	if _litter_tex != null and _main.has_method("get_season_signals"):
		var sig: Variant = _main.call("get_season_signals")
		if sig is Dictionary:
			litter = VegLitterMask.strength_for_season(sig as Dictionary, snow)
	# Litter moves only with the season, so a settled date pushes nothing.
	var litter_due := absf(litter - _litter_pushed) > 0.001
	if litter_due:
		_litter_pushed = litter
	# Snow likewise: pushed when the amount or depth moved, and otherwise on a
	# slow poll so a drape swap or a building rebuild (a fresh material that
	# never saw the value) catches up within SNOW_REPUSH_S. It used to walk
	# every ground and building material every frame.
	var snow_key := Vector2(snappedf(snow, 0.002), snappedf(depth_m, 0.005))
	var now_ms := Time.get_ticks_msec()
	var snow_due := snow_key != _snow_pushed_key \
			or now_ms - _snow_pushed_at_ms > int(SNOW_REPUSH_S * 1000.0)
	if snow_due:
		_snow_pushed_key = snow_key
		_snow_pushed_at_ms = now_ms
	for node_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(node_name) as MeshInstance3D
		if mi == null:
			continue
		if snow_due:
			_push_snow_to_mesh(mi, snow, depth_m)
		if litter_due:
			_push_litter_to_mesh(mi, litter)
		# A drape swap replaces the material: re-push the moss when it lost it.
		if not _floor_moss.is_empty():
			var msm := mi.material_override as ShaderMaterial
			# An unset uniform reads back null (float(null) is a runtime error).
			var moss_now: Variant = msm.get_shader_parameter("moss_strength") \
					if msm != null else null
			if msm != null and (moss_now == null or float(moss_now) != _floor_moss_effective()):
				_push_floor_moss()
	if snow_due:
		_apply_snow_to_buildings(terrain, snow, depth_m)


## The snow value last pushed to the ground / building materials and when.
const SNOW_REPUSH_S := 2.0
var _snow_pushed_key := Vector2.INF
var _snow_pushed_at_ms := -100000


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


## Phase 6 leaf litter: the coverage mask (built once per scatter) plus the live
## seasonal strength. Only the terrain shader carries these uniforms.
var _litter_tex: ImageTexture = null
var _litter_extent_m := 0.0
## The strength last written, so a settled season skips the per-frame push (the
## same "did it move?" discipline VegetationEnvironmentSync uses).
var _litter_pushed := -1.0


func _push_litter_to_mesh(mi: MeshInstance3D, strength: float) -> void:
	if mi == null:
		return
	var sm := mi.material_override as ShaderMaterial
	if sm == null or sm.shader == null:
		return
	if not sm.shader.resource_path.ends_with("terrain_detail.gdshader"):
		return
	if _litter_tex == null:
		sm.set_shader_parameter("litter_extent_m", 0.0)
		return
	sm.set_shader_parameter("litter_tex", _litter_tex)
	sm.set_shader_parameter("litter_extent_m", _litter_extent_m)
	sm.set_shader_parameter("litter_strength", 0.0 if _veg_hidden else strength)


## Rasterise the deciduous instances into the ground litter mask. Called once
## per scatter; null (no broadleaf trees on this map) disables the layer.
func _rebuild_litter_mask() -> void:
	_litter_tex = null
	_litter_extent_m = 0.0
	_litter_pushed = -1.0
	if _auto_veg_layer == null:
		return
	var extent := maxf(_built_extent, _half_extent * 2.0)
	if extent <= 0.0:
		return
	_litter_tex = VegLitterMask.build(_auto_veg_layer.bulk, extent)
	if _litter_tex != null:
		_litter_extent_m = extent


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
	# Legacy docks live on Shift+T / Shift+V while the unified toolbar proves
	# out. These branches MUST run before the plain-key ones: is_action_pressed
	# without exact_match also matches the shifted chord, so the plain branches
	# below pass exact_match=true and the legacy checks come first.
	if event.is_action_pressed("terrain_edit_legacy") and _terrain_edit_ui != null:
		_close_edit_toolbar()
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _placed_props_ui != null and _placed_props_ui.has_method("is_panel_open") \
				and bool(_placed_props_ui.call("is_panel_open")):
			_placed_props_ui.call("_exit_mode")
		if _camp_scatter_ui != null and _camp_scatter_ui.visible:
			_camp_scatter_ui.call("_exit_mode")
		_terrain_edit_ui.toggle_mode()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("vegetation_edit_legacy") and _vegetation_edit_ui != null:
		_close_edit_toolbar()
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _placed_props_ui != null and _placed_props_ui.has_method("is_panel_open") \
				and bool(_placed_props_ui.call("is_panel_open")):
			_placed_props_ui.call("_exit_mode")
		if _camp_scatter_ui != null and _camp_scatter_ui.visible:
			_camp_scatter_ui.call("_exit_mode")
		_vegetation_edit_ui.toggle_mode()
		get_viewport().set_input_as_handled()
		return
	# Plain V = the unified toolbar, vegetation section (Shift+V keeps the
	# legacy dock). Like T, the dispatch stays live while the toolbar is open
	# because the tool overlay is not a blocking modal.
	if event.is_action_pressed("vegetation_edit", false, true) and _edit_toolbar_ui != null:
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _placed_props_ui != null and _placed_props_ui.has_method("is_panel_open") \
				and bool(_placed_props_ui.call("is_panel_open")):
			_placed_props_ui.call("_exit_mode")
		if _camp_scatter_ui != null and _camp_scatter_ui.visible:
			_camp_scatter_ui.call("_exit_mode")
		_edit_toolbar_ui.call("toggle_section", "veg")
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("space_edit") and _space_edit_ui != null:
		_close_edit_toolbar()
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _camp_scatter_ui != null and _camp_scatter_ui.visible:
			_camp_scatter_ui.call("_exit_mode")
		_space_edit_ui.call("toggle_mode")
		get_viewport().set_input_as_handled()
		return
	# Shift+C = the legacy street-following camp dock. Like the other legacy
	# branches it must be tested BEFORE plain C (which passes exact_match).
	if event.is_action_pressed("camp_scatter_legacy") and _camp_scatter_ui != null:
		_close_edit_toolbar()
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
	# Plain C = the unified toolbar, camps section.
	if event.is_action_pressed("camp_scatter", false, true) and _edit_toolbar_ui != null:
		# C is shared with `charge`. At a usable charging station the charge
		# wins: yield the event (do NOT consume) so the player's event-driven
		# handler takes it — deterministic in either _unhandled_input order,
		# unlike the old polling which fired BOTH.
		if _main != null:
			var plr := _main.get_node_or_null("Player")
			if plr != null and plr.has_method("charge_available") \
					and bool(plr.call("charge_available")):
				return
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _placed_props_ui != null and _placed_props_ui.has_method("is_panel_open") \
				and bool(_placed_props_ui.call("is_panel_open")):
			_placed_props_ui.call("_exit_mode")
		if _camp_scatter_ui != null and _camp_scatter_ui.visible:
			_camp_scatter_ui.call("_exit_mode")
		_edit_toolbar_ui.call("toggle_section", "camps")
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("placed_props_edit") and _placed_props_ui != null:
		_close_edit_toolbar()
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		_placed_props_ui.toggle_mode()
		get_viewport().set_input_as_handled()
		return
	# Plain T = the unified toolbar (terrain section). The toolbar runs in the
	# non-blocking tool overlay, so this dispatch stays live while it is open
	# and T toggles it closed — unlike the legacy docks, whose modal claim
	# makes InputGuard eat their own hotkey.
	if event.is_action_pressed("terrain_edit", false, true) and _edit_toolbar_ui != null:
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		if _placed_props_ui != null and _placed_props_ui.has_method("is_panel_open") \
				and bool(_placed_props_ui.call("is_panel_open")):
			_placed_props_ui.call("_exit_mode")
		if _camp_scatter_ui != null and _camp_scatter_ui.visible:
			_camp_scatter_ui.call("_exit_mode")
		_edit_toolbar_ui.call("toggle_section", "terrain")
		get_viewport().set_input_as_handled()
	# Shift+H = the unified toolbar's WATER section (streams, culverts, the
	# flow view). It had no key: every other section has one, and the only
	# way in was T then a click on the strip. Same switch-or-close rule as T.
	if event.is_action_pressed("water_edit", false, true) and _edit_toolbar_ui != null:
		if _vegetation_edit_ui != null and _vegetation_edit_ui.visible:
			_vegetation_edit_ui.call("_exit_mode")
		if _terrain_edit_ui != null and _terrain_edit_ui.visible:
			_terrain_edit_ui.call("_exit_mode")
		_edit_toolbar_ui.call("toggle_section", "water")
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
	_imagery_mode = "local"
	_imagery_saved_tier = -1
	_imagery_fallback_tier = -1
	_imagery_tag_tier.clear()
	_imagery_tag_shown.clear()
	_imagery_tag_key.clear()
	_imagery_fell_back.clear()
	var ctx := get_node_or_null("/root/MapContext")
	if ctx != null and ctx.has_pending:
		var d: Dictionary = ctx.consume()
		_lat = float(d["latitude"])
		_lon = float(d["longitude"])
		var ti: Dictionary = d.get("terrain_imagery", {})
		_imagery_saved_tier = clampi(int(ti.get("saved_tier", -1)), -1, QUALITY_TIER_COUNT - 1)
		_imagery_mode = "saved" if str(ti.get("mode", "local")) == "saved" and _imagery_saved_tier >= 0 else "local"
		# A download that fails falls back to the imported imagery, else to the
		# tier this world was last shown at (still on disk from that visit).
		_imagery_fallback_tier = _imagery_saved_tier if _imagery_saved_tier >= 0 \
			else clampi(int(ti.get("tier", -1)), -1, QUALITY_TIER_COUNT - 1)
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
		_sanitize_extents()
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
	_sanitize_extents()
	TerrainCacheSettings.set_cache_enabled(not _force_refetch)
	_load_osm_offset_prefs()


## Clamp the three sizes into range and keep the hi-res patch and the OSM
## square inside the world (TerrainExtents.sanitize). A saved 180 km world with
## a 10 km hi-res patch stays as it is; a hand-edited 0 or a patch bigger than
## the world does not reach a fetch.
func _sanitize_extents() -> void:
	var s := TerrainExtents.sanitize(_half_extent, _detail_half_extent, _osm_half_extent)
	_half_extent = float(s["world_half_m"])
	_detail_half_extent = float(s["detail_half_m"])
	_osm_half_extent = float(s["osm_half_m"])


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
	# Seed the near-field detail choice BEFORE anything builds a terrain material,
	# or the first build of the session takes the shader default instead of the
	# player's saved setting.
	TerrainBuilder.near_detail_enabled = bool(
		_terrain_config().get("near_field_detail", true))
	_veg_hidden = not bool(_terrain_config().get("show_vegetation", true))
	if _load_progress != null:
		_load_progress.configure_for_extents(_half_extent, _detail_half_extent)
	var es := get_node_or_null("/root/ElevationService")
	if es != null and es.has_method("reset_session"):
		es.reset_session()
	# The imagery queue outlives the scene too: the previous load's hyper /
	# site / detail jobs would otherwise download ahead of this load's base
	# drape, and their results be taken as this load's (TerrainExtents).
	var img_svc := get_node_or_null("/root/ImageryService")
	if img_svc != null and img_svc.has_method("reset_session"):
		img_svc.reset_session()
	_hyper_half_m = 0.0
	_site_half_m = 0.0
	_hyper_drape_half = 0.0
	_site_drape_half = 0.0
	_late_base_dem = false
	_late_detail_dem = false
	_base_elev_fail_reason = ""

	# Fresh launch: bypass DEM/imagery AND wipe OSM caches so BuildingService
	# cannot serve a stale vector file while Elevation/Imagery refetch.
	if _force_refetch or not TerrainCacheSettings.cache_enabled():
		var n := TerrainCacheSettings.invalidate_osm_vectors(_lat, _lon)
		n += TerrainCacheSettings.invalidate_osm_vegetation(_lat, _lon)
		if _force_refetch:
			n += TerrainCacheSettings.invalidate_dem(_lat, _lon)
			n += TerrainCacheSettings.invalidate_imagery(_lat, _lon)
		print("TerrainLoader: fresh load — cleared %d site cache file(s)%s" % [n,
			"" if WorldPaths.has_active_world() else "; skipping placed props"])

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
			_apply_elevation_fallback("base", _base_elev_fail_reason
				if not _base_elev_fail_reason.is_empty() else "timed out waiting for elevation")
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
	else:
		_finalize_resume_actors()

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
	_apply_late_dems()
	_check_load_complete()
	_maybe_opentopo_hint()
	var mly := get_node_or_null("/root/MapillaryService")
	if mly != null and bool(mly.is_configured()):
		mly.request_photo_index(_lat, _lon, _osm_half_extent, "site")
	load_completed = true
	_ensure_leaf_fall()
	_resolve_graph_site_elevations()
	map_load_complete.emit()


## A DEM that arrived after its phase timed out (see _late_base_dem).
func _apply_late_dems() -> void:
	if not _built:
		return
	if _late_base_dem:
		_late_base_dem = false
		_late_detail_dem = false
		print("TerrainLoader: base DEM arrived after the load gave up — rebuilding the terrain")
		_apply_base_dem_refresh()
		_toast("Elevation arrived late — terrain updated.", ToastUI.Level.INFO)
	elif _late_detail_dem:
		_late_detail_dem = false
		print("TerrainLoader: hi-res DEM arrived after the load gave up — rebuilding the centre")
		_rebuild_heightfield_staggered(false)


## Resolve every placed graph item's `elevation_m` now that the terrain exists.
##
## Item elevations used to be recomputed ONLY on entry to Site / Elevation / the
## Hydro Lab, so a freshly loaded map ran with whatever the save carried — and an
## UNBOUND item (a culvert outlet sink has no prop) whose saved elevation was 0
## anchored its conduit at world Y ≈ 0 while the machine sat 80 m below. The
## culvert therefore shot several hundred feet into the sky at an angle until the
## player happened to open the graph, which is exactly what "it fixes itself after
## I press G" was describing.
##
## Deferred so the placed props are all in the tree first (prop-bound items
## resolve against their real connection ports), and it re-syncs the conduits
## afterwards so anything already built at the wrong height is re-routed.
func _resolve_graph_site_elevations() -> void:
	var sgv := _find_system_graph_view()
	if sgv == null or not sgv.has_method("_refresh_item_elevations"):
		return
	sgv.call_deferred("resolve_site_elevations_after_load")


func _fetch_detail_dem_phase(es: Node) -> void:
	# A keyless detail patch comes from Terrarium tiles first, so a spent
	# Open-Meteo quota no longer means "skip the hi-res centre" — only that its
	# own last-resort rung fails fast (ElevationService._begin_rung).
	var skip_detail := false
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
		_request_detail_imagery()
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
	_attach_camp_areas()
	_attach_pois()
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
	_notify_options_status("Found %s — look at one and press Interact to add it" % UiText.count(_solar_arrays.size(), "OSM solar array"), "info")
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
		"basin_rim_m": float(rec.get("basin_rim_m", bounds.get("rim_m", rim))),
		"max_level_m": pond_max_level_for_tag(tag),
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
		rec = _map_pond_rec_at_water_idx(idx)
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


## The player's max fill level for a pond tag (NAN = none: the basin rim).
func pond_max_level_for_tag(tag: String) -> float:
	if tag.is_empty() or not _pond_max_levels.has(tag):
		return NAN
	return float(_pond_max_levels[tag])


## Set (or clear, with NAN / at-or-below the basin rim) the MAX FILL LEVEL of
## the still-water body at `idx` — map ponds included: the override lives on
## the loader, keyed by tag, and persists in the user_water file. Raises the
## spill, recomputes Auto capacity over the footprint up to it (a vertical
## wall above the basin — a dam), rebuilds the water, syncs the graph tank's
## rim / capacity and re-seats the PondLevelHandle.
func set_pond_max_level(idx: int, max_y: float) -> bool:
	if idx < 0 or idx >= _water_data.size():
		return false
	var item: Variant = _water_data[idx]
	if not (item is Dictionary):
		return false
	var rec: Dictionary = item
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	if poly.size() < 3 or rec.has("centerline"):
		return false
	var tag := str(rec.get("tag", _water_body_tag(poly)))
	rec["tag"] = tag
	var bounds := sample_pond_basin_elevations(poly)
	var basin_rim := float(bounds.get("rim_m", 0.0))
	if is_nan(max_y) or max_y <= basin_rim + 0.005:
		_pond_max_levels.erase(tag)
	else:
		_pond_max_levels[tag] = max_y
	# Auto capacity re-integrates to the new spill; a Manual capacity is the
	# player's number and stays.
	if str(rec.get("capacity_mode", "auto")) == "auto":
		rec.erase("capacity_l")
	_recompute_pond_volume_rec(rec, true)
	_refresh_water_data()
	_save_user_water()
	_attach_water()
	if _pond_tag_on_graph(tag, str(rec.get("pond_id", ""))):
		_sync_pond_graph_from_rec(rec)
	_refresh_pond_level_handles()
	return true


func set_pond_max_level_by_tag(tag: String, max_y: float) -> bool:
	var idx := find_pond_idx_by_tag(tag)
	if idx < 0:
		return false
	return set_pond_max_level(idx, max_y)


## One PondLevelHandle per still-water body, seated at its max fill height
## over the centroid, its pick slab spanning the water surface up to that
## height. Called after every water rebuild.
func _refresh_pond_level_handles() -> void:
	if _main == null:
		return
	var seen := {}
	for i in _water_data.size():
		var item: Variant = _water_data[i]
		if not (item is Dictionary):
			continue
		var rec: Dictionary = item
		if rec.has("centerline"):
			continue
		if str(rec.get("kind", "water")) in WaterBuilder.FLOWING_KINDS:
			continue
		var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var tag := str(rec.get("tag", _water_body_tag(poly)))
		seen[tag] = true
		var h: Variant = _pond_level_handles.get(tag, null)
		if h == null or not is_instance_valid(h):
			h = PondLevelHandle.new()
			(h as Node).name = "PondLevel_%s" % tag.validate_node_name()
			_main.add_child(h)
			_pond_level_handles[tag] = h
		(h as PondLevelHandle).configure(self, i, tag)
		var basin_rim := float(rec.get("basin_rim_m", NAN))
		if is_nan(basin_rim):
			basin_rim = pond_rim_height(poly)
			rec["basin_rim_m"] = basin_rim
		var mx := pond_max_level_for_tag(tag)
		var top := basin_rim if is_nan(mx) else maxf(mx, basin_rim)
		var lvl := TerrainBuilder.variant_to_float(rec.get("level_m", NAN), NAN)
		var c := SolarArrayBuilder.centroid(poly)
		var r2 := Rect2(poly[0], Vector2.ZERO)
		for k in range(1, poly.size()):
			r2 = r2.expand(poly[k])
		(h as PondLevelHandle).set_geometry(c, r2, basin_rim, top,
				BuildingBuilder.footprint_area_m2(poly), lvl)
	for t in _pond_level_handles.keys():
		if not seen.has(t):
			var old: Variant = _pond_level_handles[t]
			if old != null and is_instance_valid(old):
				(old as Node).queue_free()
			_pond_level_handles.erase(t)


## The pond level handle for a tag (null = none).
func pond_level_handle_for_tag(tag: String) -> PondLevelHandle:
	var h: Variant = _pond_level_handles.get(tag, null)
	return h if (h != null and is_instance_valid(h)) else null


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
		rec = _map_pond_rec_at_water_idx(idx)
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
	rec["level_m"] = PondBathymetry.level_for_volume_from_samples(
		_basin_samples_for(poly, cell), cell, float(rec["stock_l"]), floor_y, spill)
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


## Stage–storage curve of a pond basin: `n` rows of [stock_l, level_m] from the
## floor to the fill ceiling (spill − freeboard), integrated off the SAME
## edited ground and cell size `set_pond_stock_l` inverts with — so a graph
## tank that reads its level off this curve stands exactly where the 3D water
## does. Before this the engine wrote a LINEAR floor→rim level and the mesh
## push wrote the bathymetric one, ~0.5 m apart on Mt Vernon, alternating.
## Cached per (tag, floor, ceiling, outline); [] when the pond is unknown.
var _stage_curve_cache: Dictionary = {}

func pond_stage_curve(tag: String, n: int = 24) -> Array:
	var idx := find_pond_idx_by_tag(tag)
	if idx < 0:
		return []
	var info := get_pond_info(idx)
	if not bool(info.get("valid", false)):
		return []
	var poly: PackedVector2Array = info.get("points", PackedVector2Array())
	var floor_y := float(info.get("floor_m", NAN))
	var spill := float(info.get("rim_m", NAN))
	if poly.size() < 3 or is_nan(floor_y) or is_nan(spill) or spill <= floor_y + 0.06:
		return []
	var hi := spill - PondBathymetry.FREEBOARD_DEFAULT_M
	var key := "%s|%.3f|%.3f|%d|%.3f" % [tag, floor_y, hi, poly.size(), _basin_ground_fingerprint(poly)]
	if _stage_curve_cache.has(key):
		return _stage_curve_cache[key]
	var cell := PondBathymetry.suggested_cell_m(float(info.get("area_m2", 0.0)))
	var samples := _basin_samples_for(poly, cell)
	var out: Array = []
	var rows := maxi(n, 2)
	for i in rows:
		var lv := lerpf(floor_y, hi, float(i) / float(rows - 1))
		out.append([PondBathymetry.volume_from_samples(samples, cell, lv, spill), lv])
	if _stage_curve_cache.size() > 32:
		_stage_curve_cache.clear()
	_stage_curve_cache[key] = out
	return out


## Cheap change detector for a basin's ground (a sculpt edit inside the
## outline moves it): summed ground height at a handful of interior points.
func _basin_ground_fingerprint(poly: PackedVector2Array) -> float:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= float(maxi(poly.size(), 1))
	var acc := ground_height_at(c.x, c.y)
	var step := maxi(poly.size() / 6, 1)
	for i in range(0, poly.size(), step):
		var q := c.lerp(poly[i], 0.5)
		acc += ground_height_at(q.x, q.y)
	return acc


## Move ONE pond's 3D water plane to `level_m` without rebuilding the Water
## node. Still water is a flat plane over a fixed outline, so translating it is
## exact; WaterBuilder builds every level-driven pond as its own mesh for this.
func set_pond_surface_level_by_tag(tag: String, level_m: float) -> bool:
	if _water_root == null or not is_instance_valid(_water_root) or is_nan(level_m):
		return false
	for c in _water_root.get_children():
		if c is Node3D and str((c as Node3D).get_meta("pond_tag", "")) == tag:
			var built := float((c as Node3D).get_meta("built_level_m", level_m))
			(c as Node3D).position.y = level_m - built
			return true
	return false


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


## A MAP (OSM) still-water record by water-data index — the live dict shared
## with `_osm_vectors.water`, so level / stock writes stick for the session
## (the graph tank is what persists them). Empty for user ponds and streams.
func _map_pond_rec_at_water_idx(idx: int) -> Dictionary:
	if idx < 0 or idx >= _water_data.size():
		return {}
	var item: Variant = _water_data[idx]
	if not (item is Dictionary) or bool((item as Dictionary).get("user", false)):
		return {}
	var rec: Dictionary = item
	if rec.has("centerline") or str(rec.get("kind", "water")) in WaterBuilder.FLOWING_KINDS:
		return {}
	if (rec.get("points", PackedVector2Array()) as PackedVector2Array).size() < 3:
		return {}
	if not rec.has("tag"):
		rec["tag"] = _water_body_tag(rec.get("points", PackedVector2Array()))
	return rec


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
	return WorldPaths.site_file("user_water", _lat, _lon)


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
	# A LOADED ledger keeps exactly the setting it was saved with, so no
	# existing site silently stops producing when the crew-gated path landed.
	# Only a map that has never had one takes the new default.
	if not _chore_ledger.load_for_map(_lat, _lon):
		_chore_ledger.infinite_labor = ChoreLedger.DEFAULT_INFINITE_FOR_NEW_MAPS


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
	return WorldPaths.site_file("printed_objects", _lat, _lon)


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
	_pond_max_levels = {}
	var path := _user_water_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	var mls: Variant = (parsed as Dictionary).get("pond_max_levels", {})
	if mls is Dictionary:
		for k in (mls as Dictionary):
			var v := TerrainBuilder.variant_to_float((mls as Dictionary)[k], NAN)
			if not is_nan(v):
				_pond_max_levels[str(k)] = v
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
	f.store_string(JSON.stringify({"version": 2, "ponds": ponds,
			"pond_max_levels": _pond_max_levels.duplicate()}))


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
		_notify_options_status("Removed %s" % UiText.count(n, "stale pond graph node"), "ok")
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
	# Phase 10: if the trees standing in this outline are food species, the bed
	# becomes a FOOD FOREST node — a rain-fed perennial crop delivered in a
	# harvest window — instead of the generic annual-crop plant model.
	var food := _area_food_summary(poly)
	var payload := {
		"osm_tag": tag,
		"label": label,
		"area_m2": maxf(area, 1.0),
		"centroid": centroid,
		"width_m": maxf(max_v.x - min_v.x, 1.0),
		"depth_m": maxf(max_v.y - min_v.y, 1.0),
		"points": poly,
		"veg_kind": kind,
	}
	if float(food.get("kg_per_year", 0.0)) > 0.0:
		payload["food"] = food
		payload["label"] = "%s Food Forest" % str(info.get("kind_label", "area")).capitalize()
	var ok: bool = bool(graph.call("add_imported_plant", payload))
	if ok:
		if payload.has("food"):
			_notify_options_status("Added food forest: %s, %.0f kg/yr → system graph"
				% [UiText.count(int(food.get("trees", 0)), "tree"), float(food.get("kg_per_year", 0.0))], "ok")
			print("TerrainLoader: added food forest '%s' — %d trees, %.0f kg/yr (%.0f kcal/yr), harvest doy %d–%d" % [
				tag, int(food.get("trees", 0)), float(food.get("kg_per_year", 0.0)),
				float(food.get("kcal_per_year", 0.0)),
				int(food.get("harvest_start_doy", 1)), int(food.get("harvest_end_doy", 365))])
		else:
			_notify_options_status(
					"Added crop area: %.0f m² (%s) → system graph" % [area, kind], "ok")
			print("TerrainLoader: added OSM veg plant '%s' (%.0f m², %s) to the system graph" % [tag, area, kind])
	return ok


## Food yield of every food-bearing plant inside a polygon, across BOTH veg
## layers — an area fill lands in the auto layer, hand-painted trees in the
## manual one, and the player sees one orchard either way.
func _area_food_summary(poly: PackedVector2Array) -> Dictionary:
	var st := _growth_style()
	var total := VegFoodYield.summarize(
		_auto_veg_layer.bulk if _auto_veg_layer != null else {}, poly, st)
	if _vegetation_layer == null:
		return total
	var manual := VegFoodYield.summarize(_vegetation_layer.bulk, poly, st)
	if int(manual.get("trees", 0)) <= 0:
		return total
	if int(total.get("trees", 0)) <= 0:
		return manual
	# Merge: masses add, the dominant species (and so the harvest window) is
	# whichever layer contributes more.
	var merged := total.duplicate(true)
	merged["trees"] = int(total["trees"]) + int(manual["trees"])
	merged["kg_per_year"] = float(total["kg_per_year"]) + float(manual["kg_per_year"])
	merged["kcal_per_year"] = float(total["kcal_per_year"]) + float(manual["kcal_per_year"])
	merged["kcal_per_kg"] = float(merged["kcal_per_year"]) / maxf(float(merged["kg_per_year"]), 0.001)
	var counts: Dictionary = (total.get("species_counts", {}) as Dictionary).duplicate()
	for k in (manual.get("species_counts", {}) as Dictionary):
		counts[k] = int(counts.get(k, 0)) + int((manual["species_counts"] as Dictionary)[k])
	merged["species_counts"] = counts
	if float(manual.get("kg_per_year", 0.0)) > float(total.get("kg_per_year", 0.0)):
		merged["dominant"] = manual.get("dominant", "")
		merged["harvest_start_doy"] = manual.get("harvest_start_doy", 1)
		merged["harvest_end_doy"] = manual.get("harvest_end_doy", 365)
	return merged


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


## All placed-prop records (the layer's live array — treat as read-only).
## Used by CampManifest's packing sweep (PACKING_PLAN.md Phase 2).
func placed_prop_records() -> Array:
	if _placed_prop_layer == null:
		return []
	return _placed_prop_layer.props


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
	_notify_options_status("Added solar array: %s, %.2f kW → system graph" % [UiText.count(count, "panel"), kw], "ok")
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
		_notify_options_status("Added %s inside the SoI to the system graph" % UiText.count(n, "OSM solar array"), "ok")
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

func _on_elevation_ready(key: String, grid: PackedFloat32Array, cols: int, rows: int,
		tag: String = "base") -> void:
	if not _result_is_current(key, _detail_half_extent if tag == "detail" else _half_extent, tag + " DEM"):
		return
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
			if _phase_waiting and _phase_key == "elev:detail":
				_phase_resolve("elev:detail", true)
			elif _built:
				_late_detail_dem = true
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
		if _phase_waiting and _phase_key == "elev:base":
			_phase_resolve("elev:base", true)
		elif _built:
			_late_base_dem = true
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
		_base_elev_fail_reason = reason
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


## True when a fetch result is for THIS load's site and square. ImageryService
## and ElevationService are autoloads: a result requested by the previous load
## (another size, another map) used to be taken as this load's own, draping an
## old-size photo over the new terrain — the hi-res patch "not lining up".
func _result_is_current(key: String, half_m: float, what: String) -> bool:
	if TerrainExtents.key_matches(key, _lat, _lon, half_m):
		return true
	print("TerrainLoader: ignoring a stale %s result (%s) — not this load's %s square" % [
		what, key, TerrainExtents.format_side(TerrainExtents.side_from_half(half_m))])
	return false


func _imagery_half_for_tag(tag: String) -> float:
	match tag:
		"hyper":
			return _hyper_half_m
		"site":
			return _site_half_m
		"detail":
			return _detail_half_extent
	return _half_extent


func _on_imagery_ready(key: String, texture: ImageTexture, tag: String) -> void:
	if not _result_is_current(key, _imagery_half_for_tag(tag), tag + " imagery"):
		return
	if _imagery_tag_key.has(tag) and str(_imagery_tag_key[tag]) != key:
		print("TerrainLoader: ignoring a late %s imagery result (%s) — %s was asked for since" % [
			tag, key, str(_imagery_tag_key[tag]) if not str(_imagery_tag_key[tag]).is_empty() else "no layer"])
		return
	if tag == "hyper":
		_hyper_drape = texture
		_hyper_drape_half = _hyper_half_m
		_imagery_tag_shown["hyper"] = _imagery_tag_tier.get("hyper", -1)
		_log_load_mem("hyper img ready")
		print("TerrainLoader: hyper roof ortho ready (%.0f m square)" % (_hyper_half_m * 2.0))
		_apply_building_textures()
		_apply_hyper_to_terrain()
		_maybe_request_ai_hero()
		_request_site_imagery()
		return
	if tag == "site":
		_site_drape = texture
		_site_drape_half = _site_half_m
		_imagery_tag_shown["site"] = _imagery_tag_tier.get("site", -1)
		_log_load_mem("site img ready")
		var svc := get_node_or_null("/root/ImageryService")
		print("TerrainLoader: site patch ready (%.0f m square) — %s" % [_site_half_m * 2.0,
			str(svc.call("attribution_for", "site")) if svc != null else ""])
		_apply_site_to_terrain()
		return
	if tag == "detail":
		_log_load_mem("detail img ready")
		_detail_drape = texture
		_imagery_tag_shown["detail"] = _imagery_tag_tier.get("detail", -1)
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
				_request_detail_imagery(-1, true)
		return
	_img_done = true
	_try_build()


func _on_imagery_failed(reason: String, tag: String) -> void:
	if tag in ["detail", "hyper", "site"] and _imagery_saved_fallback(tag):
		return
	if tag == "hyper":
		_hyper_half_m = _hyper_drape_half
		push_warning("TerrainLoader: hyper roof ortho failed (%s) — roofs use detail/procedural" % reason)
		_request_site_imagery()
		return
	if tag == "site":
		_site_half_m = _site_drape_half
		push_warning("TerrainLoader: native site patch failed (%s) — hyper drape only" % reason)
		return
	if tag == "detail":
		if _detail_img_retry_zoom < 0:
			_detail_img_retry_zoom = DETAIL_MAX_ZOOM - 1
			var img_retry := get_node_or_null("/root/ImageryService")
			if img_retry != null and _detail_img_retry_zoom >= 15:
				push_warning("TerrainLoader: detail imagery failed (%s) — retrying at z%d" % [
					reason, _detail_img_retry_zoom])
				_imagery_tag_key["detail"] = _IMAGERY_SERVICE.layer_key(_lat, _lon, _detail_half_extent,
					_detail_target_px(), _detail_img_retry_zoom)
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
func _request_hyper_imagery(tier: int = -1) -> void:
	var img := get_node_or_null("/root/ImageryService")
	if img == null:
		return
	var t := tier if tier >= 0 else _tier_for_tag("hyper")
	_imagery_tag_tier["hyper"] = t
	var bypass := (_force_refetch or not TerrainCacheSettings.cache_enabled()) and tier < 0
	_hyper_half_m = _hyper_half_extent(t)
	var chain := ImagerySources.chain_for(_lat, _lon)
	_imagery_tag_key["hyper"] = _IMAGERY_SERVICE.layer_key(_lat, _lon, _hyper_half_m,
		_hyper_target_px(t), HYPER_MAX_ZOOM, chain)
	img.request_imagery(_lat, _lon, _hyper_half_m, _hyper_target_px(t),
		"hyper", HYPER_MAX_ZOOM, bypass, chain)


## Half-extent (m) the site patch is fetched at: the tier's (or the config
## override), shrunk so the native zoom fits SITE_TARGET_PX. 0 = off.
func _site_half_extent(tier: int = -1) -> float:
	var l := TerrainImageryPlan.layer("site", tier if tier >= 0 else _imagery_tier(), _lat, _lon,
		_detail_half_extent, TerrainImageryPlan.config_overrides())
	return 0.0 if l.is_empty() else float(l["half"])


## Queue the native-resolution site patch (after hyper, so it never delays
## the walkable drape). BC7 on a worker thread; the layer pops in when done.
func _request_site_imagery(tier: int = -1) -> void:
	var img := get_node_or_null("/root/ImageryService")
	if img == null:
		return
	var t := tier if tier >= 0 else _tier_for_tag("site")
	var half := _site_half_extent(t)
	if half <= 0.0:
		_imagery_tag_tier["site"] = t
		_imagery_tag_key["site"] = ""
		_site_half_m = 0.0
		if _site_drape != null:
			# This tier has no site patch (a live switch to Low imagery).
			_site_drape = null
			_site_half_m = 0.0
			_site_drape_half = 0.0
			_imagery_tag_shown.erase("site")
			_set_site_patch_off()
		return
	_imagery_tag_tier["site"] = t
	var chain := ImagerySources.chain_for(_lat, _lon)
	var z := ImagerySources.native_zoom(chain, _lat)
	var bypass := (_force_refetch or not TerrainCacheSettings.cache_enabled()) and tier < 0
	_site_half_m = half
	print("TerrainLoader: site patch %.0f m square at z%d from %s (%.2f m/px)" % [
		half * 2.0, z, " -> ".join(PackedStringArray(chain)),
		ImagerySources.metres_per_px(z, _lat)])
	_imagery_tag_key["site"] = _IMAGERY_SERVICE.layer_key(_lat, _lon, half, SITE_TARGET_PX, z, chain)
	img.request_imagery(_lat, _lon, half, SITE_TARGET_PX, "site", z, bypass, chain, true)


func _set_site_patch_off() -> void:
	var terrain := _main.get_node_or_null("Terrain") as Node3D if _main != null else null
	if terrain == null:
		return
	for child_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(child_name) as MeshInstance3D
		if mi != null and mi.material_override is ShaderMaterial:
			(mi.material_override as ShaderMaterial).set_shader_parameter("use_site", false)


## Stamp the site patch onto the terrain drape shaders (over hyper).
func _apply_site_to_terrain(terrain: Node3D = null) -> void:
	if _site_drape == null or _site_half_m <= 0.0:
		return
	if terrain == null and _main != null:
		terrain = _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var site_extent := _site_half_m * 2.0
	var site_vec := TerrainBuilder.bbox_to_shader_vec4(GeoMath.bbox_for(_lat, _lon, _site_half_m))
	var site_feather_uv := TerrainBuilder.feather_uv_from_metres(
		minf(_seam_feather_m, _site_half_m * 0.15), site_extent)
	for child_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(child_name) as MeshInstance3D
		if mi == null or not (mi.material_override is ShaderMaterial):
			continue
		var sm := mi.material_override as ShaderMaterial
		var span := _detail_extent_m() if child_name == "DetailGround" else _built_extent
		sm.set_shader_parameter("site_tex", _site_drape)
		sm.set_shader_parameter("use_site", true)
		sm.set_shader_parameter("site_ratio", span / site_extent)
		sm.set_shader_parameter("site_bbox", site_vec)
		sm.set_shader_parameter("correct_site_mercator", true)
		sm.set_shader_parameter("site_feather", site_feather_uv)


func _hyper_target_px(tier: int = -1) -> int:
	# An explicit manual override (low-VRAM machines) always wins; otherwise the
	# selected quality tier drives it.
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK and cfg.has_section_key("terrain", "hyper_target_px"):
		return int(cfg.get_value("terrain", "hyper_target_px", HYPER_TARGET_PX_DEFAULT))
	return int(QUALITY_HYPER_TARGET_PX[tier if tier >= 0 else _imagery_tier()])


## This COMPUTER's terrain imagery quality tier (0..QUALITY_TIER_COUNT-1),
## from config — the Terrain options slider. What this world shows can differ:
## see _imagery_tier().
func _quality_tier() -> int:
	return TerrainImageryPlan.local_tier()


## Detail-drape stitch target (px) for `tier` (default: the tier this world shows).
func _detail_target_px(tier: int = -1) -> int:
	return int(QUALITY_DETAIL_TARGET_PX[tier if tier >= 0 else _imagery_tier()])


## Hyper (sharpest) layer half-extent (m) for `tier`, never past the hi-res
## patch (TerrainExtents.overlay_half): on High / Ultra the 1–1.5 km hyper
## square used to reach beyond a smaller hi-res patch, so the sharpest photo
## lay on the coarse world mesh and its edge cut across the hi-res terrain's.
func _hyper_half_extent(tier: int = -1) -> float:
	return TerrainExtents.overlay_half(
		float(QUALITY_HYPER_HALF_EXTENT[tier if tier >= 0 else _imagery_tier()]), _detail_half_extent)


# -- Per-world imagery ------------------------------------------------------------
#
# A shared world arrives with its author's imagery cached at the AUTHOR's tier,
# while the quality setting is this computer's. MapContext hands the loader the
# world's record ({"tier": author's tier, "mode": "saved" | "local"}):
#   saved — each layer of the author's tier that is on disk loads from it, as
#           the author saw it (a layer it lacks falls back to this computer's
#           tier). The default for an imported world.
#   local — this computer's tier, downloaded if not cached. A layer that fails
#           (offline, server error) loads the saved tier's copy from disk
#           instead (_imagery_saved_fallback), so it never goes blurry.
# Nothing is ever deleted; switching back is instant.

## The tier this world shows: the saved tier in "saved" mode, else this computer's.
func _imagery_tier() -> int:
	if _imagery_mode == "saved" and _imagery_saved_tier >= 0:
		return _imagery_saved_tier
	return _quality_tier()


## The tier to ask for for one layer: in "saved" mode the saved tier when that
## layer is on disk (no surprise download of the author's bigger layers) or
## when the saved tier has no such layer at all (Low has no site patch: it
## stays off, as it was saved); otherwise this computer's.
func _tier_for_tag(tag: String) -> int:
	if _imagery_mode == "saved" and _imagery_saved_tier >= 0 and _imagery_saved_tier != _quality_tier():
		var l := TerrainImageryPlan.layer(tag, _imagery_saved_tier, _lat, _lon, _detail_half_extent,
			TerrainImageryPlan.config_overrides())
		if l.is_empty() or TerrainImageryPlan.is_cached(l):
			return _imagery_saved_tier
	return _quality_tier()


## A layer failed. If the saved tier has that layer on disk and it is not what
## just failed, load it instead. True when a fallback was queued.
func _imagery_saved_fallback(tag: String) -> bool:
	var saved := _imagery_fallback_tier
	if saved < 0 or int(_imagery_tag_tier.get(tag, -1)) == saved:
		return false
	var l := TerrainImageryPlan.layer(tag, saved, _lat, _lon, _detail_half_extent,
		TerrainImageryPlan.config_overrides())
	if not TerrainImageryPlan.is_cached(l):
		return false
	push_warning("TerrainLoader: %s imagery could not be downloaded — using the saved %s copy" % [
		tag, TerrainImageryPlan.tier_name(saved)])
	_imagery_fell_back[tag] = true
	match tag:
		"detail":
			_request_detail_imagery(saved)
		"hyper":
			_request_hyper_imagery(saved)
		"site":
			_request_site_imagery(saved)
	return true


## Queue the detail drape at `tier` (default: per _tier_for_tag).
func _request_detail_imagery(tier: int = -1, force: bool = false) -> void:
	var img := get_node_or_null("/root/ImageryService")
	if img == null:
		return
	var t := tier if tier >= 0 else _tier_for_tag("detail")
	_imagery_tag_tier["detail"] = t
	var bypass := force or ((_force_refetch or not TerrainCacheSettings.cache_enabled()) and tier < 0)
	_imagery_tag_key["detail"] = _IMAGERY_SERVICE.layer_key(_lat, _lon, _detail_half_extent,
		_detail_target_px(t), DETAIL_MAX_ZOOM)
	img.request_imagery(_lat, _lon, _detail_half_extent, _detail_target_px(t), "detail",
		DETAIL_MAX_ZOOM, bypass)


## What this world's imagery is doing, for the world panel and Terrain options.
## {mode, saved_tier, local_tier, shown {tag: tier ON SCREEN},
##  requested {tag: tier last asked for}, fell_back [tags],
##  saved_cached Vector2i(on disk, layers), vram_saved, vram_local}
func get_world_imagery() -> Dictionary:
	var ov := TerrainImageryPlan.config_overrides()
	var local := _quality_tier()
	var out := {"mode": _imagery_mode, "saved_tier": _imagery_saved_tier, "local_tier": local,
		"shown": _imagery_tag_shown.duplicate(), "requested": _imagery_tag_tier.duplicate(),
		"fell_back": _imagery_fell_back.keys(),
		"vram_local": TerrainImageryPlan.vram_bytes(local, _lat, _lon, _detail_half_extent, ov)}
	if _imagery_saved_tier >= 0:
		out["vram_saved"] = TerrainImageryPlan.vram_bytes(_imagery_saved_tier, _lat, _lon, _detail_half_extent, ov)
		out["saved_cached"] = TerrainImageryPlan.cached_count(_imagery_saved_tier, _lat, _lon, _detail_half_extent, ov)
	return out


## Switch this world between its saved imagery and this computer's quality,
## live: the detail drape is re-requested (from disk when it is there) and
## chains on to hyper and the site patch, each falling back to the saved copy
## if a download fails. The world's record is written on the next save
## (world_extras "terrain_imagery").
func set_world_imagery_mode(mode: String) -> void:
	var m := "saved" if mode == "saved" else "local"
	if m == _imagery_mode:
		return
	_imagery_mode = m
	_imagery_fell_back.clear()
	if not _built or _load_sequence_active:
		return
	_begin_refresh("imagery")
	_detail_img_retry_zoom = -1
	_request_detail_imagery()
	print("TerrainLoader: world imagery → %s (%s) — reloading the drape" % [m,
		TerrainImageryPlan.tier_name(_imagery_tier())])


## For the world record (WorldSession folds it into world.json on every save):
##   tier       — what this world is shown at now. The next person it is
##                shared with gets this as their "saved" imagery, and a later
##                load here falls back to it if a download fails.
##   saved_tier — the imported imagery's tier (-1 for a world made here).
##   mode       — "saved" | "local".
func world_imagery_record() -> Dictionary:
	return {"tier": _imagery_tier(), "saved_tier": _imagery_saved_tier, "mode": _imagery_mode}


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
	if _imagery_mode == "saved":
		# This world shows its saved imagery; the slider applies to it once
		# the world panel switches it to this computer's quality.
		print("TerrainLoader: terrain quality → %s; this world keeps its saved %s imagery" % [
			QUALITY_TIER_NAMES[t], TerrainImageryPlan.tier_name(_imagery_saved_tier)])
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
	_apply_site_to_terrain(terrain)
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
	var hyper_half := _hyper_half_m if _hyper_half_m > 0.0 else _hyper_half_extent()
	var hyper_extent := hyper_half * 2.0
	var hyper_vec := TerrainBuilder.bbox_to_shader_vec4(
		GeoMath.bbox_for(_lat, _lon, hyper_half))
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
	call_deferred("_attach_camp_areas")
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
		_request_water_network_rebuild()
		return
	if _footing_grid.is_empty():
		_footing_grid = _compose_terrain_grids()["footing"]
	var detail_res := _detail_elev_cols if not _detail_surface_grid.is_empty() else 0
	var coarse_elev := _built_grid if not _built_grid.is_empty() else _footing_grid
	# Drape onto the EDITED surface (player sculpt + carved channels), not the
	# edit-free grids — a pond bank or river reach that was cut used to float.
	WaterBuilder.ground_delta_fn = Callable(self, "_edit_tile_delta")
	# Waterway LINES (anything with a centreline) are drawn by the WaterNetwork
	# as level surfaces in their carved channels; WaterBuilder keeps the still
	# water (lakes, ponds, riverbank polygons).
	var still_only: Array = []
	for item in _water_data:
		if item is Dictionary and (item as Dictionary).has("centerline"):
			continue
		still_only.append(item)
	var node := WaterBuilder.build_water_node(
		still_only, coarse_elev, MESH_RES, _built_extent, _built_center_elev,
		_detail_surface_grid, detail_res, _detail_extent_m(), _seam_feather_m)
	WaterBuilder.ground_delta_fn = Callable()
	if node == null:
		_request_water_network_rebuild()
		return
	terrain.add_child(node)
	_water_root = node
	print("TerrainLoader: draped %d OSM water polygons" % _water_data.size())
	call_deferred("_refresh_water_reflection_probes")
	_request_water_network_rebuild()
	_refresh_pond_level_handles()


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


## ---------------------------------------------------------------------------
## Painted camp areas (core/camps/) — the unified toolbar's Camps section.
##
## Unlike the street-following generator above, these need no roads, are saved
## per map (user://maps/camp_areas_*.json) and are rebuilt one camp at a time.
## ---------------------------------------------------------------------------

## Load this map's camp areas (once) and (re)build them under Terrain. Safe to
## call again after a terrain rebuild or an OSM refresh: the layer is the
## authority, the nodes are disposable.
func _attach_camp_areas() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var path := CampAreaLayer.save_path_for_map(_lat, _lon)
	if camp_areas == null or _camp_areas_path != path:
		camp_areas = CampAreaLayer.create_empty()
		camp_areas.load_from(path)
		_camp_areas_path = path
		_camp_undo.clear()
	_attach_placement()
	# Roads / buildings / water may have changed under us (OSM refresh).
	_camp_excl_index = null
	# The player's tuned styles + added models (global, like veg styles).
	CampStyleStore.load_and_apply()
	var rt := _ensure_camp_area_runtime()
	if rt == null:
		return
	rt.sync(camp_areas, _camp_ctx())
	_apply_cached_geometry_visibility()
	if not camp_areas.areas.is_empty():
		print("TerrainLoader._attach_camp_areas: %d camps, %d structures" % [
			camp_areas.areas.size(), rt.structure_count()])


func _ensure_camp_area_runtime() -> CampAreaRuntime:
	if _main == null:
		return null
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return null
	if is_instance_valid(_camp_area_runtime) and _camp_area_runtime.get_parent() == terrain:
		return _camp_area_runtime
	var stale := terrain.get_node_or_null(CampAreaRuntime.NODE_NAME)
	if stale != null:
		terrain.remove_child(stale)
		stale.queue_free()
	_camp_area_runtime = CampAreaRuntime.new()
	# Headless runs (selftests, boot smoke) never load the imported camp art.
	_camp_area_runtime.setup(_main, DisplayServer.get_name() != "headless")
	terrain.add_child(_camp_area_runtime)
	return _camp_area_runtime


## What CampLayoutGenerator needs from the world. The exclusion index is built
## lazily and kept until the next attach — rebuilding it per brush stroke would
## re-buffer every building on the map.
func _camp_ctx() -> Dictionary:
	if _camp_excl_index == null:
		var roads: Array = (_osm_vectors.get("roads", []) as Array).duplicate()
		# Festival roads are corridors too: their dicts carry the same
		# points/half_width_m keys, so they buffer exactly like OSM roads.
		roads.append_array(get_festival_roads())
		_camp_excl_index = VegExclusionBuilder.build_index(
			VegExclusionBuilder.build_all(_buildings_data, roads, _water_data,
				1.0, 1.0, 1.5, true, true),
			maxf(_osm_half_extent, 500.0))
	var heading_roads: Array = get_festival_roads()
	heading_roads.append_array(get_osm_roads())
	return {
		"ground_y_at": Callable(self, "_ground_height_at"),
		"roads": heading_roads,
		"is_excluded": Callable(_camp_excl_index, "is_excluded"),
		"map_styles": camp_areas.map_styles if camp_areas != null else {},
	}


## The same world context for the Tune-look studio: real exclusions and slope
## tests (so the preview shows what the map will show) drawn on flat ground.
func camp_preview_ctx() -> Dictionary:
	var ctx := _camp_ctx()
	ctx["flatten"] = true
	return ctx


## Re-seat every painted camp on the current ground (after sculpting).
func reground_camp_areas() -> void:
	_reground_camp_areas()


func _reground_camp_areas() -> void:
	if camp_areas == null or camp_areas.areas.is_empty():
		return
	var rt := _ensure_camp_area_runtime()
	if rt != null:
		rt.sync(camp_areas, _camp_ctx())


func _apply_camp_changes(changed: Array, removed: Array) -> void:
	var rt := _ensure_camp_area_runtime()
	if rt != null:
		var ctx := _camp_ctx()
		for id in removed:
			rt.remove_area(str(id))
		for id in changed:
			var rec := camp_areas.get_area(str(id))
			if not rec.is_empty():
				rt.rebuild_area(rec, ctx)
	camp_areas.save_to(_camp_areas_path)


func _camp_layer_ready() -> bool:
	if not _built or _main == null:
		return false
	if camp_areas == null:
		_attach_camp_areas()
	return camp_areas != null


## Paint a camp. Overlapping a camp of the same style GROWS it (nothing already
## standing moves); otherwise a new camp is created. params: style, density,
## heading_deg (< 0 = auto: nearest road, else the outline's longest edge),
## align_jitter_deg, light_density, seed, name. Returns the camp id ("" = refused).
func paint_camp_area(poly: PackedVector2Array, params: Dictionary = {}) -> String:
	if not _camp_layer_ready() or poly.size() < 3:
		return ""
	var p := params.duplicate()
	var auto := float(p.get("heading_deg", -1.0)) < 0.0
	p["heading_auto"] = auto
	if auto:
		# Resolved ONCE and stored, so brushing the camp bigger later cannot
		# swing its heading (and with it every tent) to a new longest edge.
		p["heading_deg"] = _resolve_camp_heading(poly)
	var res := camp_areas.paint(poly, p)
	_apply_camp_changes(res["changed"], res["removed"])
	return str(res["id"])


## Remove camp ground inside the polygon. Returns how many camps were touched.
func erase_camps_in_polygon(poly: PackedVector2Array) -> int:
	if not _camp_layer_ready() or poly.size() < 3:
		return 0
	var res := camp_areas.erase(poly)
	_apply_camp_changes(res["changed"], res["removed"])
	return (res["changed"] as Array).size() + (res["removed"] as Array).size()


## Split a zone into plots with lanes; every plot becomes its own camp.
## params: plot_w_m, plot_d_m, lane_w_m, heading_deg (< 0 = auto), style
## (CampStyles.VARIED = a seeded style per plot), density, align_jitter_deg,
## light_density. Returns the new camp ids.
func subdivide_camp_zone(poly: PackedVector2Array, params: Dictionary = {}) -> Array:
	var ids: Array = []
	if not _camp_layer_ready() or poly.size() < 3:
		return ids
	var heading := float(params.get("heading_deg", -1.0))
	var auto := heading < 0.0
	if auto:
		heading = _resolve_camp_heading(poly)
	var plots := CampSubdivider.subdivide(poly, heading,
		float(params.get("plot_w_m", 30.0)), float(params.get("plot_d_m", 22.0)),
		float(params.get("lane_w_m", 6.0)))
	if plots.is_empty():
		return ids
	# The zone replaces whatever camps stood on that ground.
	var cleared := camp_areas.erase(poly)
	var style_id := str(params.get("style", CampStyles.DEFAULT_STYLE))
	var group_id := "zone_%d" % (Time.get_ticks_usec() & 0x7fffffff)
	var base_seed := int(params.get("seed", CampAreaLayer._poly_seed(poly)))
	for i in plots.size():
		var plot: Dictionary = plots[i]
		var plot_seed := hash(Vector2i(base_seed & 0x7fffffff, i)) & 0x7fffffff
		var plot_style := style_id
		if style_id == CampStyles.VARIED:
			plot_style = str(CampStyles.VARIED_POOL[plot_seed % CampStyles.VARIED_POOL.size()])
		var id := camp_areas.add(plot["polygon"], {
			"name": str(plot["name"]), "style": plot_style, "seed": plot_seed,
			"density": params.get("density", 0.8), "heading_deg": heading,
			"heading_auto": auto,
			"align_jitter_deg": params.get("align_jitter_deg", 5.0),
			"light_density": params.get("light_density", 1.0), "group_id": group_id})
		if not id.is_empty():
			ids.append(id)
	var changed: Array = cleared["changed"]
	changed.append_array(ids)
	_apply_camp_changes(changed, cleared["removed"])
	return ids


## Edit one camp's settings (name, style, density, heading_deg, seed, ...).
func update_camp_area(id: String, patch: Dictionary) -> bool:
	if not _camp_layer_ready() or camp_areas.index_of(id) < 0:
		return false
	var p := patch.duplicate()
	# Hand edits are keyed by lattice cell. Anything that re-deals the lattice
	# (a reseed, another style or layout) makes them point at different
	# households, so they go unless the caller is setting them explicitly.
	if not p.has("edits"):
		var before := camp_areas.get_area(id)
		for k in ["seed", "style", "variant"]:
			if p.has(k) and str(p[k]) != str(before.get(k, "")):
				p["edits"] = {}
				break
	if p.has("heading_deg"):
		var auto := float(p["heading_deg"]) < 0.0
		p["heading_auto"] = auto
		if auto:
			p["heading_deg"] = _resolve_camp_heading(
				camp_areas.get_area(id).get("polygon", PackedVector2Array()))
	camp_areas.update(id, p)
	_apply_camp_changes([id], [])
	# A headcount is a graph fact (the camp's compound and its habitat), so a
	# hand-set one goes to the graph the way festival mode's does.
	if p.has("headcount"):
		_push_camps_to_graph()
	return true


func delete_camp_area(id: String) -> bool:
	if not _camp_layer_ready() or not camp_areas.remove(id):
		return false
	_apply_camp_changes([], [id])
	return true


## Topmost camp under a world XZ point, or "".
func camp_area_at(xz: Vector2) -> String:
	return camp_areas.area_at(xz) if _camp_layer_ready() else ""


## Record + live counts for the options bar / harness. {} when unknown.
func camp_area_info(id: String) -> Dictionary:
	if not _camp_layer_ready():
		return {}
	var rec := camp_areas.get_area(id)
	if rec.is_empty():
		return {}
	var info := rec.duplicate()
	info["area_m2"] = CampAreaLayer.record_area(rec)
	info["structures"] = 0
	info["stats"] = {}
	if is_instance_valid(_camp_area_runtime):
		info["structures"] = _camp_area_runtime.area_structure_count(id)
		info["stats"] = _camp_area_runtime.area_stats(id)
	return info


## {areas, structures, budget} across every painted camp.
func camp_areas_summary() -> Dictionary:
	var n := 0
	if is_instance_valid(_camp_area_runtime):
		n = _camp_area_runtime.structure_count()
	return {"areas": camp_areas.areas.size() if camp_areas != null else 0,
		"structures": n, "budget": CampAreaRuntime.MAX_TOTAL_STRUCTURES}


## Persist a tuned style set (CampStyleStore data) and rebuild every camp with it.
func apply_camp_styles(data: Dictionary) -> void:
	CampStyleStore.save_data(data)
	CampStyleStore.apply(data)
	CampMeshLibrary.clear_cache()
	if camp_areas != null:
		var rt := _ensure_camp_area_runtime()
		if rt != null:
			rt.sync(camp_areas, _camp_ctx())


## Save this MAP's edit to a style ("all camps of this type on this map") and
## rebuild the camps it touches. An empty entry removes the map-level edit.
func save_map_camp_style(style_id: String, entry: Dictionary) -> void:
	if not _camp_layer_ready() or not CampStyles.is_valid(style_id):
		return
	var clean := CampStyleStore.normalize_entry(entry)
	if clean.is_empty():
		camp_areas.map_styles.erase(style_id)
	else:
		camp_areas.map_styles[style_id] = clean
	var changed: Array = []
	for rec: Dictionary in camp_areas.areas:
		if str(rec["style"]) == style_id:
			changed.append(str(rec["id"]))
	_apply_camp_changes(changed, [])


func map_camp_style(style_id: String) -> Dictionary:
	if camp_areas == null:
		return {}
	return (camp_areas.map_styles.get(style_id, {}) as Dictionary).duplicate(true)


## Crosshair pick: the camp under a world XZ point. {valid, id, name, style}.
func pick_camp_at_world(x: float, z: float) -> Dictionary:
	if camp_areas == null or camp_areas.areas.is_empty():
		return {"valid": false}
	var id := camp_areas.area_at(Vector2(x, z))
	if id.is_empty():
		return {"valid": false}
	var rec := camp_areas.get_area(id)
	return {"valid": true, "id": id, "name": str(rec.get("name", "Camp")),
		"style": str(rec.get("style", ""))}


## Crosshair focus highlight, change-gated (it is called every physics frame).
func set_camp_focus(id: String) -> void:
	if id == _camp_focus_id:
		return
	_camp_focus_id = id
	if id.is_empty():
		clear_camp_highlight()
	else:
		update_camp_highlight(id)


## Open the Tune-look modal on ONE placed camp (its real outline and elements).
func open_camp_tune_for_camp(camp_id: String) -> void:
	if camp_areas == null or camp_areas.index_of(camp_id) < 0:
		return
	open_camp_style_modal(str(camp_areas.get_area(camp_id).get("style", "")), camp_id)


## The camp Tune-look modal (preview + mix + models for one style).
func open_camp_style_modal(style_id: String = "", camp_id: String = "") -> void:
	if _main == null:
		return
	if _camp_style_modal == null or not is_instance_valid(_camp_style_modal):
		var ui_layer := _main.get_node_or_null("UILayer")
		if ui_layer == null:
			return
		var layer := CanvasLayer.new()
		layer.name = "CampStyleModalLayer"
		layer.layer = UITheme.LAYER_MODAL
		ui_layer.add_child(layer)
		var modal := Control.new()
		modal.name = "CampStyleModal"
		modal.set_script(load("res://scenes/ui/camp_style_modal.gd"))
		layer.add_child(modal)
		modal.call("bind_loader", self)
		_camp_style_modal = modal
	_camp_style_modal.call("open", style_id, camp_id)


func push_camp_undo() -> void:
	if not _camp_layer_ready():
		return
	_camp_undo.append(camp_areas.snapshot())
	while _camp_undo.size() > CAMP_UNDO_MAX:
		_camp_undo.pop_front()


func can_undo_camps() -> bool:
	return not _camp_undo.is_empty()


func undo_camps() -> bool:
	if _camp_undo.is_empty() or camp_areas == null:
		return false
	camp_areas.restore(_camp_undo.pop_back())
	var rt := _ensure_camp_area_runtime()
	if rt != null:
		rt.sync(camp_areas, _camp_ctx())
	camp_areas.save_to(_camp_areas_path)
	clear_camp_highlight()
	return true


## Outline one camp on the ground (the Camp Select tool).
func update_camp_highlight(id: String) -> void:
	var rec := camp_areas.get_area(id) if camp_areas != null else {}
	var poly: PackedVector2Array = rec.get("polygon", PackedVector2Array())
	if _main == null or poly.size() < 3:
		clear_camp_highlight()
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	if _camp_highlight == null or not is_instance_valid(_camp_highlight):
		_camp_highlight = MeshInstance3D.new()
		_camp_highlight.name = "CampAreaHighlight"
		terrain.add_child(_camp_highlight)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_color = Color(1.0, 0.72, 0.2, 0.35)
		_camp_highlight.material_override = mat
	var footing := _highlight_footing_grid(true)
	_camp_highlight.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev)
	_camp_highlight.visible = true


func clear_camp_highlight() -> void:
	# The crosshair focus is change-gated on _camp_focus_id; a highlight cleared
	# by any other path (the toolbar's Edit tool, an undo) must reset it, or the
	# gate and what is drawn disagree and an outline outlives its focus.
	_camp_focus_id = ""
	if _camp_highlight != null and is_instance_valid(_camp_highlight):
		_camp_highlight.visible = false
		_camp_highlight.mesh = null


## ---------------------------------------------------------------------------
## Festival placement (core/camps/festival_*) — the toolbar's PLACEMENT section.
##
## Roads the placement team draws, the zones it allocates along them, the lots
## those zones are cut into (equal USABLE area on real ground) and the roster of
## camps that want a lot. Lots are mirrored into CampAreaLayer one record each
## (group_id = the zone) so the painted-camp generator fills them unchanged;
## `camp_area_id` on the lot is the link. Saved per map next to the camps file.
## ---------------------------------------------------------------------------

var placement: FestivalPlacementLayer = null
var _placement_path := ""
var _placement_undo: Array = []
var _placement_highlight: MeshInstance3D = null
## A festival road wins the camp heading at this reach; OSM roads at 40 m.
const FESTIVAL_ROAD_ALIGN_DIST_M := 60.0
const PLACEMENT_UNDO_MAX := 24
const FESTIVAL_ROAD_FEATHER_M := 3.0


func _attach_placement() -> void:
	var path := FestivalPlacementLayer.save_path_for_map(_lat, _lon)
	if placement == null or _placement_path != path:
		placement = FestivalPlacementLayer.create_empty()
		placement.load_from(path)
		_placement_path = path
		_placement_undo.clear()
		if not placement.is_empty():
			print("TerrainLoader._attach_placement: %d roads, %d zones, %d lots" % [
				placement.roads.size(), placement.zones.size(), placement.lots.size()])
	_push_camps_to_graph()


## Every assigned lot is a camp super-node on the systems graph
## (SystemGraphView.sync_camps_from_placement, idempotent by lot id). Called
## after every placement change; a no-op before the graph view exists.
func _push_camps_to_graph() -> void:
	if placement == null:
		return
	var graph: Node = ServiceLocator.graph()
	if graph == null or not graph.has_method("sync_camps_from_placement"):
		return
	# Each lot carries its zone's provisioning preset (how many days the
	# camp's stores last), falling back to the global testing default.
	var lots: Array = placement.lots.duplicate(true)
	var zones := placement.zones_by_id()
	for l in lots:
		var zone: Dictionary = zones.get(str((l as Dictionary).get("zone_id", "")), {})
		var spec: Dictionary = zone.get("spec", {})
		(l as Dictionary)["provision"] = str(spec.get("provision", PopTestPrefs.provision_preset()))
	# Painted camps the player POPULATED (festival mode's one button, or a
	# headcount set by hand) ride the SAME sync as lot-shaped records keyed
	# "camp:<id>" — so a free-painted camp is a camp on the graph too, not
	# scenery. A live lot's own camp record is skipped here: its headcount is
	# the lot assignment above.
	if camp_areas != null:
		var painted := FestivalSeedLayout.camp_lots(camp_areas.areas, zones)
		for l in painted:
			(l as Dictionary)["provision"] = PopTestPrefs.provision_preset()
		lots.append_array(painted)
	_apply_population_target(lots)
	graph.call_deferred("sync_camps_from_placement", lots)


## The festival population target (PopTestPrefs, 0 = natural): scale the
## assigned headcounts of these lot records IN THE COPY handed to the graph,
## never in the saved layers, so the natural split is kept and 0 restores it.
## Returns {natural, people}.
func _apply_population_target(lots: Array) -> Dictionary:
	var counts: Array = []
	var holders: Array = []
	for l in lots:
		var ac: Dictionary = (l as Dictionary).get("assigned_camp", {})
		if ac.is_empty() or int(ac.get("headcount", 0)) <= 0:
			continue
		counts.append(int(ac["headcount"]))
		holders.append(ac)
	var natural := 0
	for c in counts:
		natural += int(c)
	var scaled := FestivalSeedLayout.scale_headcounts(counts, PopTestPrefs.festival_target_people())
	var people := 0
	for i in holders.size():
		(holders[i] as Dictionary)["headcount"] = int(scaled[i])
		people += int(scaled[i])
	return {"natural": natural, "people": people}


## Re-push the camps after the festival population target changed: rosters
## resize IN PLACE on the next population tick (NpcPopulationBridge).
func apply_festival_population_target() -> Dictionary:
	_push_camps_to_graph()
	return camp_population_summary()


# --- Festival mode: populated painted camps -----------------------------------

## Give every painted camp that has no headcount one — derived from its area
## and style at the placement tool's own density — so it becomes a camp
## compound on the graph (the graph sync runs deferred). Returns
## {"camps": n populated in total, "people": their summed headcount,
## "changed": n given a headcount by this call}. Camps that already carry a
## headcount keep it; a live lot's camp is never touched (see camp_lots).
func populate_camp_areas() -> Dictionary:
	var out := {"camps": 0, "people": 0, "changed": 0}
	if not _camp_layer_ready():
		return out
	var zones: Dictionary = placement.zones_by_id() if placement != null else {}
	var changed := 0
	for raw in camp_areas.areas.duplicate():
		var rec: Dictionary = raw
		if not FestivalSeedLayout.is_populatable(rec, zones):
			continue
		var n := int(rec.get("headcount", 0))
		if n <= 0:
			n = FestivalSeedLayout.camp_headcount(rec)
			if n <= 0:
				continue
			camp_areas.update(str(rec["id"]), {"headcount": n})
			changed += 1
		out["camps"] = int(out["camps"]) + 1
		out["people"] = int(out["people"]) + n
	out["changed"] = changed
	if changed > 0:
		camp_areas.save_to(_camp_areas_path)
	_push_camps_to_graph()
	return out


## The reverse: every populated painted camp back to scenery (headcount 0);
## their compounds leave the graph on the deferred sync. Returns how many.
func depopulate_camp_areas() -> int:
	if not _camp_layer_ready():
		return 0
	var zones: Dictionary = placement.zones_by_id() if placement != null else {}
	var n := 0
	for raw in camp_areas.areas.duplicate():
		var rec: Dictionary = raw
		if int(rec.get("headcount", 0)) > 0 and FestivalSeedLayout.is_populatable(rec, zones):
			camp_areas.update(str(rec["id"]), {"headcount": 0})
			n += 1
	if n > 0:
		camp_areas.save_to(_camp_areas_path)
	_push_camps_to_graph()
	return n


## Headcounts the graph sync will stamp: {"camps", "people"} over assigned
## placement lots + populated painted camps.
func camp_population_summary() -> Dictionary:
	var out := {"camps": 0, "people": 0}
	if camp_areas == null and placement == null:
		return out
	var zones: Dictionary = placement.zones_by_id() if placement != null else {}
	if placement != null:
		for l in placement.lots:
			var ac: Dictionary = (l as Dictionary).get("assigned_camp", {})
			if not ac.is_empty() and int(ac.get("headcount", 0)) > 0:
				out["camps"] = int(out["camps"]) + 1
				out["people"] = int(out["people"]) + int(ac["headcount"])
	var lots: Array = []
	if placement != null:
		for l in placement.lots:
			var ac0: Dictionary = (l as Dictionary).get("assigned_camp", {})
			if not ac0.is_empty() and int(ac0.get("headcount", 0)) > 0:
				lots.append({"assigned_camp": ac0.duplicate()})
	if camp_areas != null:
		for l in FestivalSeedLayout.camp_lots(camp_areas.areas, zones):
			out["camps"] = int(out["camps"]) + 1
			lots.append(l)
	# What the graph actually gets: the target-scaled total, and the natural
	# one it came from (the HUD shows both).
	var r := _apply_population_target(lots)
	out["people"] = int(r["people"])
	out["natural"] = int(r["natural"])
	return out


## The world outline behind a camp compound's `camp_lot_id`: a placement lot's
## polygon, or the painted camp's for a "camp:<id>" key. Empty when unknown.
func camp_lot_polygon(lot_id: String) -> PackedVector2Array:
	var cid := FestivalSeedLayout.camp_id_for_lot(lot_id)
	if not cid.is_empty():
		if camp_areas == null:
			return PackedVector2Array()
		return camp_areas.get_area(cid).get("polygon", PackedVector2Array())
	if placement != null:
		return placement.get_lot(lot_id).get("polygon", PackedVector2Array())
	return PackedVector2Array()


## Where people can SLEEP inside a polygon (a camp's sleep area): the camp
## generator's shelters (tents, pods, yurts, vans, RVs) plus shiftpod props,
## as [{pos: Vector2, yaw (radians), sleeps}]. Empty when nothing is there —
## the caller falls back to the ground.
func camp_shelters_in_polygon(poly: PackedVector2Array) -> Array:
	var out: Array = []
	if poly.size() < 3:
		return out
	if is_instance_valid(_camp_area_runtime):
		for s in _camp_area_runtime.all_shelters():
			var sd: Dictionary = s
			if Geometry2D.is_point_in_polygon(sd["pos"], poly):
				out.append({"pos": sd["pos"], "yaw": float(sd.get("yaw", 0.0)),
					"sleeps": int(sd.get("sleeps", 2))})
	for r in placed_prop_records():
		var rec: Dictionary = r
		var mid := str(rec.get("model_id", ""))
		var sleeps := int(CampStyles.SHELTER_SLEEPS.get(mid, 0))
		if sleeps <= 0 and mid == "shiftpod":
			sleeps = 2
		if sleeps <= 0 or bool(rec.get("packed", false)):
			continue
		var p := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
		if Geometry2D.is_point_in_polygon(p, poly):
			out.append({"pos": p, "yaw": deg_to_rad(float(rec.get("yaw", 0.0))), "sleeps": sleeps})
	return out


## Shade people can stand under (NpcComfort): every camp's canopies, tarps
## and shade arrays, plus placed props that ARE shade — a StarShade, a
## deployed linkage canopy, an EZ-up or carport — as {pos, yaw, size: Vector3
## (x length, z width)}. Placed props use their live pick AABB (yaw 0).
func shade_footprints() -> Array:
	var out: Array = []
	if is_instance_valid(_camp_area_runtime):
		for s in _camp_area_runtime.all_shades():
			var sd: Dictionary = s
			out.append({"pos": sd["pos"], "yaw": float(sd.get("yaw", 0.0)),
				"size": sd.get("size", Vector3(3.0, 2.5, 3.0))})
	var terrain := _main.get_node_or_null("Terrain") if _main != null else null
	var root := terrain.get_node_or_null("PlacedProps") if terrain != null else null
	if root == null:
		return out
	for child in root.get_children():
		if not (child is PlacedProp):
			continue
		var prop := child as PlacedProp
		var mid := str(prop.model_id)
		var shade := ModelCatalog.is_starshade_model(mid) or mid == "ez_up" or mid == "carport" \
			or mid == LinkageStructureBuilder.MODEL_ID
		if not shade:
			continue
		var rec := get_prop_record(prop.prop_id)
		if bool(rec.get("packed", false)) or (mid == LinkageStructureBuilder.MODEL_ID \
				and not bool(rec.get("linkage_deployed", true))):
			continue
		var bb: AABB = prop.get_world_pick_aabb()
		if bb.size.x < 1.5 or bb.size.z < 1.5:
			continue
		var c := bb.get_center()
		out.append({"pos": Vector2(c.x, c.z), "yaw": 0.0, "size": Vector3(bb.size.x, bb.size.y, bb.size.z)})
	return out


## Footprints people cannot walk THROUGH, for the nav grid: every camp's
## vehicles and every placed prop over a metre across (PackedSpec dims),
## as oriented rectangles. Props tagged as a space people must ENTER
## (`enterable` ids) are left out — the registry's goal snapping puts them
## beside it anyway.
func nav_solid_footprints(enterable: Dictionary = {}) -> Array:
	var out: Array = []
	if is_instance_valid(_camp_area_runtime):
		for s in _camp_area_runtime.all_solids():
			var sd: Dictionary = s
			var size: Vector3 = sd.get("size", Vector3.ONE)
			out.append(_oriented_rect(sd["pos"], float(sd.get("yaw", 0.0)), size.x, size.z))
	# Placed props by their LIVE pick AABB (PackedSpec dims are the shipping
	# size — a shiftpod packs to 1.3 m and stands 3.6 m). World-aligned
	# boxes; good enough for a walk-round.
	var terrain := _main.get_node_or_null("Terrain") if _main != null else null
	var root := terrain.get_node_or_null("PlacedProps") if terrain != null else null
	if root != null:
		for child in root.get_children():
			if not (child is PlacedProp):
				continue
			var prop := child as PlacedProp
			if enterable.has(prop.prop_id):
				continue
			var rec := get_prop_record(prop.prop_id)
			if bool(rec.get("packed", false)):
				continue
			var bb: AABB = prop.get_world_pick_aabb()
			if bb.size.x < 1.0 or bb.size.z < 1.0 or bb.size.x > 60.0 or bb.size.z > 60.0:
				continue
			out.append(PackedVector2Array([Vector2(bb.position.x, bb.position.z),
				Vector2(bb.end.x, bb.position.z), Vector2(bb.end.x, bb.end.z),
				Vector2(bb.position.x, bb.end.z)]))
	return out


static func _oriented_rect(c: Vector2, yaw: float, len_x: float, len_z: float) -> PackedVector2Array:
	# Camp items: X is the long axis in the item's local frame; the world
	# yaw rotates about +Y (Basis(Vector3.UP, yaw)), which on the XZ plane
	# carries local +X to (cos yaw, -sin yaw).
	var ux := Vector2(cos(yaw), -sin(yaw)) * (len_x * 0.5)
	var uz := Vector2(sin(yaw), cos(yaw)) * (len_z * 0.5)
	return PackedVector2Array([c - ux - uz, c + ux - uz, c + ux + uz, c - ux + uz])


## How many camp structures stand right now — folded into the nav grid's
## fingerprint so a repainted camp re-bakes the grid.
func camp_structure_count() -> int:
	return _camp_area_runtime.structure_count() if is_instance_valid(_camp_area_runtime) else 0


## The world's veto for festival mode's venue search: a square footprint is
## free when neither its centre nor its corners sit on a building, road or
## water (the camp generator's own exclusion index).
func festival_ground_free(centre: Vector2, half: float) -> bool:
	if not _camp_layer_ready():
		return true
	var ctx := _camp_ctx()
	var excl: Callable = ctx.get("is_excluded", Callable())
	if not excl.is_valid():
		return true
	for p in FestivalSeedLayout.square(centre, half):
		if bool(excl.call(p)):
			return false
	return not bool(excl.call(centre))


func _placement_ready() -> bool:
	if not _camp_layer_ready():
		return false
	if placement == null:
		_attach_placement()
	return placement != null


func _save_placement() -> void:
	if placement != null and not _placement_path.is_empty():
		placement.save_to(_placement_path)


## Festival road dicts, OSM-shaped ({points, half_width_m, tags, …}).
func get_festival_roads() -> Array:
	if placement == null:
		return []
	return placement.road_dicts()


## Camp heading: festival road within 60 m → OSM road within 40 m → the
## outline's longest edge.
func _resolve_camp_heading(poly: PackedVector2Array) -> float:
	var d := CampLayoutGenerator.nearest_road_dir(poly, get_festival_roads(), FESTIVAL_ROAD_ALIGN_DIST_M)
	if d == Vector2.ZERO:
		d = CampLayoutGenerator.nearest_road_dir(poly, get_osm_roads(), CampLayoutGenerator.ROAD_ALIGN_DIST_M)
	if d == Vector2.ZERO:
		return CampLayoutGenerator.resolve_heading(poly, [])
	return CampLayoutGenerator.direction_to_heading(d)


# --- Roads -------------------------------------------------------------------

## params: name, width_m, surface, flatten (bool). Returns the road id or "".
func add_festival_road(points: PackedVector2Array, params: Dictionary = {}) -> String:
	if not _placement_ready() or points.size() < 2:
		return ""
	var id := placement.add_road(points, params)
	if id.is_empty():
		return ""
	_camp_excl_index = null   # the corridor is now an exclusion
	_save_placement()
	if bool(params.get("flatten", false)):
		flatten_festival_road(id)
	else:
		_reground_camp_areas()
	return id


func update_festival_road(id: String, patch: Dictionary) -> bool:
	if not _placement_ready() or not placement.update_road(id, patch):
		return false
	_camp_excl_index = null
	_save_placement()
	_reground_camp_areas()
	return true


func delete_festival_road(id: String) -> bool:
	if not _placement_ready() or not placement.remove_road(id):
		return false
	_camp_excl_index = null
	_save_placement()
	_reground_camp_areas()
	return true


## Grade the road's corridor to its own smoothed profile on the edit layer —
## ONE terrain undo entry (the Terrain section's Undo takes it back).
func flatten_festival_road(id: String) -> bool:
	if not _placement_ready():
		return false
	var road := placement.get_road(id)
	if road.is_empty() or not can_sculpt_detail():
		return false
	_ensure_edit_tiles()
	if _edit_tiles == null:
		return false
	begin_terrain_tile_edit()
	TerrainSculptOps.level_polyline(_edit_tiles, road["points"], float(road["half_width_m"]),
		FESTIVAL_ROAD_FEATHER_M, Callable(self, "_height_field_base"))
	end_terrain_tile_edit()
	placement.update_road(id, {"flattened": true})
	_save_placement()
	_reground_camp_areas()
	return true


## Roads whose corridor comes within `depth_m` of the outline, nearest first.
func _zone_roads_auto(poly: PackedVector2Array, depth_m: float) -> Array:
	var scored: Array = []
	for r: Dictionary in get_festival_roads():
		var pts: PackedVector2Array = r["points"]
		var best := INF
		for p in poly:
			for i in range(pts.size() - 1):
				best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])))
		# Also the road passing THROUGH the zone.
		for q in pts:
			if Geometry2D.is_point_in_polygon(q, poly):
				best = 0.0
		if best <= float(r["half_width_m"]) + depth_m:
			scored.append([best, str(r["id"])])
	scored.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var out: Array = []
	for s in scored:
		out.append(s[1])
	return out


# --- Zones -------------------------------------------------------------------

## params: name, spec (FestivalPlacementLayer spec keys), road_ids (default:
## every festival road within the spec's depth, nearest first), features,
## subdivide (default true). Returns the zone id or "".
func add_placement_zone(poly: PackedVector2Array, params: Dictionary = {}) -> String:
	if not _placement_ready() or poly.size() < 3:
		return ""
	var spec := FestivalPlacementLayer.normalize_spec(params.get("spec", {}))
	var road_ids: Array = params.get("road_ids", [])
	if road_ids.is_empty():
		road_ids = _zone_roads_auto(poly, float(spec["depth_m"]))
	var id := placement.add_zone(poly, {
		"name": params.get("name", "Zone %s" % CampSubdivider.row_letters(placement.zones.size())),
		"spec": spec, "road_ids": road_ids, "features": params.get("features", []),
		"holes": params.get("holes", []),
	})
	if id.is_empty():
		return ""
	# The zone replaces whatever free-painted camps stood on that ground.
	var cleared := camp_areas.erase(poly)
	_apply_camp_changes(cleared["changed"], cleared["removed"])
	_save_placement()
	if bool(params.get("subdivide", true)):
		subdivide_placement_zone(id)
	return id


func update_placement_zone(id: String, patch: Dictionary, resubdivide: bool = false) -> bool:
	if not _placement_ready() or not placement.update_zone(id, patch):
		return false
	_save_placement()
	if resubdivide:
		subdivide_placement_zone(id)
	return true


func delete_placement_zone(id: String) -> bool:
	if not _placement_ready() or placement.get_zone(id).is_empty():
		return false
	var camp_ids := placement.remove_zone(id)
	var removed: Array = []
	for cid in camp_ids:
		if camp_areas.remove(str(cid)):
			removed.append(str(cid))
	_apply_camp_changes([], removed)
	_save_placement()
	_push_camps_to_graph()
	return true


## Cut (or re-cut) one zone into lots and mirror them into camp records.
## Returns the partition result ({lots, stats, warnings, lot_ids}); {} when refused.
func subdivide_placement_zone(id: String) -> Dictionary:
	if not _placement_ready():
		return {}
	var zone := placement.get_zone(id)
	if zone.is_empty():
		return {}
	var res := FestivalLotPartition.partition(zone, get_festival_roads(), _placement_ctx(id))
	var lot_ids := placement.apply_partition(id, res)
	_sync_lot_camps(id)
	_save_placement()
	res["lot_ids"] = lot_ids
	return res


func subdivide_all_placement_zones() -> Dictionary:
	var out := {"zones": 0, "lots": 0}
	if not _placement_ready():
		return out
	for z in placement.zones.duplicate():
		var res := subdivide_placement_zone(str((z as Dictionary)["id"]))
		out["zones"] = int(out["zones"]) + 1
		out["lots"] = int(out["lots"]) + (res.get("lot_ids", []) as Array).size()
	return out


## What the partition needs from the world: the edit-aware ground, the camp
## exclusion index (buildings / water / OSM roads / festival corridors), the
## zone's locked lots and its previous lots for id inheritance.
func _placement_ctx(zone_id: String) -> Dictionary:
	var ctx := _camp_ctx()
	return {
		"ground_y_at": ctx["ground_y_at"],
		"is_excluded": ctx["is_excluded"],
		"locked_lots": placement.locked_lots_for_zone(zone_id),
		"prior_lots": placement.lots_for_zone(zone_id),
	}


## One camp record per lot, byte-stable where the lot did not change. Camp
## records of this zone that no lot points at any more are removed.
func _sync_lot_camps(zone_id: String) -> void:
	var zone := placement.get_zone(zone_id)
	var spec: Dictionary = zone.get("spec", FestivalPlacementLayer.default_spec())
	var styles: Array = spec.get("styles", [CampStyles.DEFAULT_STYLE])
	var style0 := str(styles[0]) if not styles.is_empty() else CampStyles.DEFAULT_STYLE
	var referenced: Dictionary = {}
	var changed: Array = []
	for lot in placement.lots_for_zone(zone_id):
		var l: Dictionary = lot
		var ac: Dictionary = l.get("assigned_camp", {})
		var style := str(ac.get("style", style0)) if not ac.is_empty() else style0
		var name := str(ac.get("name", "")) if not ac.is_empty() else ""
		if name.is_empty():
			name = str(l.get("name", "Lot"))
		var seed := hash(Vector2i(int(zone.get("seed", 0)) & 0x7fffffff,
			int(str(l["lot_id"]).trim_prefix("lot_")))) & 0x7fffffff
		var patch := {
			"polygon": l["polygon"], "name": name, "style": style, "seed": seed,
			"heading_deg": float(l.get("heading_deg", 0.0)), "heading_auto": false,
			"density": float(spec.get("density", 0.8)),
			"align_jitter_deg": float(spec.get("align_jitter_deg", 5.0)),
			"light_density": float(spec.get("light_density", 1.0)), "group_id": zone_id,
		}
		var cid := str(l.get("camp_area_id", ""))
		var rec := camp_areas.get_area(cid) if not cid.is_empty() else {}
		if rec.is_empty():
			cid = camp_areas.add(l["polygon"], patch)
			if cid.is_empty():
				continue
			placement.update_lot(str(l["lot_id"]), {"camp_area_id": cid})
			changed.append(cid)
		else:
			# Only touch the record when something it draws from moved.
			var same_poly: bool = (rec.get("polygon", PackedVector2Array()) as PackedVector2Array) == (l["polygon"] as PackedVector2Array)
			var differs := not same_poly \
				or str(rec.get("style", "")) != style or str(rec.get("name", "")) != name \
				or absf(float(rec.get("heading_deg", 0.0)) - float(patch["heading_deg"])) > 0.01 \
				or absf(float(rec.get("density", 0.8)) - float(patch["density"])) > 0.001
			if differs:
				if str(rec.get("style", "")) != style:
					patch["edits"] = {}
				camp_areas.update(cid, patch)
				changed.append(cid)
		referenced[cid] = true
	var removed: Array = []
	for rec: Dictionary in camp_areas.areas.duplicate():
		if str(rec.get("group_id", "")) == zone_id and not referenced.has(str(rec["id"])):
			camp_areas.remove(str(rec["id"]))
			removed.append(str(rec["id"]))
	_apply_camp_changes(changed, removed)
	_push_camps_to_graph()


# --- Assignment ----------------------------------------------------------------

## Auto-assign the roster (largest-first best-fit) over every zone, or one.
func assign_placement(zone_id: String = "") -> Dictionary:
	if not _placement_ready():
		return {}
	var lots: Array = placement.lots if zone_id.is_empty() else placement.lots_for_zone(zone_id)
	var res := FestivalAssigner.assign(lots, placement.roster, placement.zones_by_id())
	var touched: Dictionary = {}
	for lid in (res["assignments"] as Dictionary).keys():
		placement.update_lot(str(lid), {"assigned_camp": res["assignments"][lid]})
		touched[str(placement.get_lot(str(lid)).get("zone_id", ""))] = true
	for zid in touched.keys():
		_sync_lot_camps(str(zid))
	_save_placement()
	return res


func assign_lot(lot_id: String, roster_id: String) -> bool:
	if not _placement_ready():
		return false
	var lot := placement.get_lot(lot_id)
	var entry := placement.get_roster_entry(roster_id)
	if lot.is_empty() or entry.is_empty():
		return false
	# One lot per camp: clear it off any other lot first.
	for other: Dictionary in placement.lots:
		if str((other.get("assigned_camp", {}) as Dictionary).get("roster_id", "")) == roster_id \
				and str(other["lot_id"]) != lot_id:
			placement.update_lot(str(other["lot_id"]), {"assigned_camp": {}})
	var hc := int(entry.get("headcount", 0))
	if hc <= 0:
		hc = FestivalAssigner.default_headcount(float(lot.get("usable_m2", 0.0)), str(entry["style"]))
	placement.update_lot(lot_id, {"assigned_camp": {
		"roster_id": roster_id, "name": str(entry["name"]), "style": str(entry["style"]),
		"headcount": hc, "requirements": (entry["requirements"] as Array).duplicate(),
		"manual": true}})
	_sync_lot_camps(str(lot.get("zone_id", "")))
	_save_placement()
	return true


func clear_lot_assignment(lot_id: String) -> bool:
	if not _placement_ready() or placement.get_lot(lot_id).is_empty():
		return false
	placement.update_lot(lot_id, {"assigned_camp": {}})
	_sync_lot_camps(str(placement.get_lot(lot_id).get("zone_id", "")))
	_save_placement()
	return true


## Edit a lot's camp by hand: style, headcount, name (keeps/creates a manual
## assignment with no roster entry).
func update_lot_camp(lot_id: String, patch: Dictionary) -> bool:
	if not _placement_ready():
		return false
	var lot := placement.get_lot(lot_id)
	if lot.is_empty():
		return false
	var ac: Dictionary = (lot.get("assigned_camp", {}) as Dictionary).duplicate(true)
	if ac.is_empty():
		var zone := placement.get_zone(str(lot.get("zone_id", "")))
		var styles: Array = (zone.get("spec", {}) as Dictionary).get("styles", ["mixed"])
		ac = {"roster_id": "", "name": str(lot.get("name", "")), "style": str(styles[0]),
			"headcount": FestivalAssigner.default_headcount(float(lot.get("usable_m2", 0.0)), str(styles[0])),
			"requirements": [], "manual": true}
	for k in ["style", "headcount", "name", "requirements"]:
		if patch.has(k):
			ac[k] = patch[k]
	ac["manual"] = true
	placement.update_lot(lot_id, {"assigned_camp": ac})
	_sync_lot_camps(str(lot.get("zone_id", "")))
	_save_placement()
	return true


func set_lot_locked(lot_id: String, on: bool) -> bool:
	if not _placement_ready() or placement.get_lot(lot_id).is_empty():
		return false
	placement.update_lot(lot_id, {"locked": on})
	_save_placement()
	return true


# --- Picking / info ------------------------------------------------------------

## {kind: "lot"|"zone"|"road"|"", id} under a world XZ point — lot first (the
## most specific thing), then zone, then road corridor.
func placement_pick_at(xz: Vector2) -> Dictionary:
	if not _placement_ready():
		return {"kind": "", "id": ""}
	var lid := placement.lot_at(xz)
	if not lid.is_empty():
		return {"kind": "lot", "id": lid}
	var zid := placement.zone_at(xz)
	if not zid.is_empty():
		return {"kind": "zone", "id": zid}
	var rid := placement.road_at(xz, 1.0)
	if not rid.is_empty():
		return {"kind": "road", "id": rid}
	return {"kind": "", "id": ""}


## Record + live numbers for the options bar / harness. {} when unknown.
func placement_info(kind: String, id: String) -> Dictionary:
	if not _placement_ready():
		return {}
	match kind:
		"lot":
			var lot := placement.get_lot(id)
			if lot.is_empty():
				return {}
			var info := lot.duplicate(true)
			info["structures"] = 0
			var cid := str(lot.get("camp_area_id", ""))
			if not cid.is_empty() and is_instance_valid(_camp_area_runtime):
				info["structures"] = _camp_area_runtime.area_structure_count(cid)
			info["orphan"] = not cid.is_empty() and camp_areas.get_area(cid).is_empty()
			info["size_class"] = FestivalAssigner.size_class(float(lot.get("usable_m2", 0.0)))
			return info
		"zone":
			var zone := placement.get_zone(id)
			if zone.is_empty():
				return {}
			var info := zone.duplicate(true)
			info["lots"] = placement.lots_for_zone(id).size()
			info["area_m2"] = CampAreaLayer.record_area(zone)
			return info
		"road":
			var road := placement.get_road(id)
			if road.is_empty():
				return {}
			var info := road.duplicate(true)
			var pts: PackedVector2Array = road["points"]
			var l := 0.0
			for i in range(pts.size() - 1):
				l += pts[i].distance_to(pts[i + 1])
			info["length_m"] = l
			info["width_m"] = float(road["half_width_m"]) * 2.0
			return info
	return {}


## Whole-site (or one zone's) readout for the options bar.
func placement_summary(zone_id: String = "") -> Dictionary:
	if not _placement_ready():
		return {}
	var lots: Array = placement.lots if zone_id.is_empty() else placement.lots_for_zone(zone_id)
	var people := 0
	var assigned := 0
	var usable := 0.0
	for l: Dictionary in lots:
		usable += float(l.get("usable_m2", 0.0))
		var ac: Dictionary = l.get("assigned_camp", {})
		if not ac.is_empty():
			people += int(ac.get("headcount", 0))
			if not str(ac.get("roster_id", "")).is_empty():
				assigned += 1
	var unplaced := 0
	var placed_ids: Dictionary = {}
	for l: Dictionary in placement.lots:
		placed_ids[str((l.get("assigned_camp", {}) as Dictionary).get("roster_id", ""))] = true
	for e: Dictionary in placement.roster:
		if not placed_ids.has(str(e["id"])):
			unplaced += 1
	return {"roads": placement.roads.size(), "zones": placement.zones.size(),
		"lots": lots.size(), "usable_m2": usable, "people": people,
		"assigned": assigned, "roster": placement.roster.size(), "unplaced": unplaced}


# --- Road helpers --------------------------------------------------------------

## A road along edge `edge_i` of a zone, inset by `inset_m`; the zone fronts it.
func road_from_zone_edge(zone_id: String, edge_i: int, inset_m: float = 6.0,
		params: Dictionary = {}) -> String:
	if not _placement_ready():
		return ""
	var zone := placement.get_zone(zone_id)
	if zone.is_empty():
		return ""
	var pts := FestivalPlacementLayer.road_from_zone_edge(zone["polygon"], edge_i, inset_m, inset_m)
	var rid := add_festival_road(pts, params)
	if not rid.is_empty():
		var ids: Array = (zone.get("road_ids", []) as Array).duplicate()
		ids.push_front(rid)
		update_placement_zone(zone_id, {"road_ids": ids})
	return rid


func road_from_zone_spine(zone_id: String, params: Dictionary = {}) -> String:
	if not _placement_ready():
		return ""
	var zone := placement.get_zone(zone_id)
	if zone.is_empty():
		return ""
	var pts := FestivalPlacementLayer.road_from_zone_spine(zone["polygon"])
	var rid := add_festival_road(pts, params)
	if not rid.is_empty():
		var ids: Array = (zone.get("road_ids", []) as Array).duplicate()
		ids.push_front(rid)
		update_placement_zone(zone_id, {"road_ids": ids})
	return rid


# --- Undo (both layers at once) ------------------------------------------------

func push_placement_undo() -> void:
	if not _placement_ready():
		return
	_placement_undo.append({"placement": placement.snapshot(), "camps": camp_areas.snapshot()})
	while _placement_undo.size() > PLACEMENT_UNDO_MAX:
		_placement_undo.pop_front()


func can_undo_placement() -> bool:
	return not _placement_undo.is_empty()


func undo_placement() -> bool:
	if _placement_undo.is_empty() or placement == null or camp_areas == null:
		return false
	var snap: Dictionary = _placement_undo.pop_back()
	placement.restore(snap["placement"])
	camp_areas.restore(snap["camps"])
	_camp_excl_index = null
	var rt := _ensure_camp_area_runtime()
	if rt != null:
		rt.sync(camp_areas, _camp_ctx())
	camp_areas.save_to(_camp_areas_path)
	_save_placement()
	clear_placement_highlight()
	return true


# --- Highlight -----------------------------------------------------------------

## Drape an outline on the ground (the picked road / zone / lot).
func update_placement_highlight(poly: PackedVector2Array, color: Color = Color(0.9, 0.55, 0.95, 0.35)) -> void:
	if _main == null or poly.size() < 3:
		clear_placement_highlight()
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	if _placement_highlight == null or not is_instance_valid(_placement_highlight):
		_placement_highlight = MeshInstance3D.new()
		_placement_highlight.name = "PlacementHighlight"
		terrain.add_child(_placement_highlight)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_placement_highlight.material_override = mat
	(_placement_highlight.material_override as StandardMaterial3D).albedo_color = color
	var footing := _highlight_footing_grid(true)
	_placement_highlight.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev)
	_placement_highlight.visible = true


func clear_placement_highlight() -> void:
	if _placement_highlight != null and is_instance_valid(_placement_highlight):
		_placement_highlight.visible = false
		_placement_highlight.mesh = null


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
	var ortho_half := _detail_half_extent if _hyper_drape == null \
		else (_hyper_half_m if _hyper_half_m > 0.0 else _hyper_half_extent())
	var scale := BuildingBuilder.roof_ortho_uv_scale(ortho_half)
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
	_setup_edit_toolbar()
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
	var xz := _spawn_xz()
	var gy := _spawn_ground_y
	if xz != Vector2.ZERO:
		gy = _ground_height_at(xz.x, xz.y)
	var spawn := Vector3(xz.x, gy + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M, xz.y)
	player.global_position = spawn
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO
	if "player_spawn_position" in _main:
		_main.player_spawn_position = spawn
	if "fall_start_height" in player:
		player.fall_start_height = spawn.y
		player.highest_point_during_fall = spawn.y


## Where a fresh (non-resume) load puts the player: the site's location marker
## (the Sphere-of-Influence centre the player drags around), so moving the marker
## moves the spawn. Read straight from the per-map SoiConfig because SoiService
## is only bound to this map AFTER the spawn pass. A map whose marker was never
## moved has it at the origin, which is the old behaviour.
func _spawn_xz() -> Vector2:
	var cfg := SoiConfig.load_for_map(_lat, _lon)
	var xz := Vector2(cfg.center_x, cfg.center_z)
	# A marker dragged off the built terrain would spawn the player in the void.
	var limit := maxf(_half_extent - 50.0, 0.0)
	if not (is_finite(xz.x) and is_finite(xz.y)) or absf(xz.x) > limit or absf(xz.y) > limit:
		return Vector2.ZERO
	return xz


## True once the terrain is built, i.e. ground_height_at answers in world Y.
## Before that it samples grids that are not centred yet (and the actors stand
## on the temporary load floor), so nothing may treat its heights as ground.
func is_terrain_ready() -> bool:
	return _built


## Make sure the map has a survey drone (a save resume skips the spawn pass, and
## an older save may not carry one). Used by the remote drone-view hotkey.
func ensure_explore_drone() -> Node3D:
	if _main == null:
		return null
	var drone := _main.get_node_or_null("FPVDrone") as FPVDrone
	if drone == null:
		drone = FPV_DRONE_SCENE.instantiate() as FPVDrone
		if drone == null:
			return null
		drone.name = "FPVDrone"
		_main.add_child(drone)
	_explore_drone = drone
	return drone


## Re-seat player + explore drone once the final hi-res footing is in place.## Re-seat player + explore drone once the final hi-res footing is in place.
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


## A save RESUME keeps the saved position, but the temporary load floor (an
## infinite WorldBoundary plane at y = 0, _add_temp_floor) must still go. On a
## site whose ground lies below zero (Walton's is ~-95 m) the restored body
## was pushed up onto that plane during the load and left standing on it at
## y = 0 for good — every resume there came back in mid-air. Removes the
## floor, waits for the real colliders, then puts the player back exactly
## where they were saved, with the fall tracker reset so the move is not a fall.
func _finalize_resume_actors() -> void:
	if _main == null:
		return
	_remove_temp_floor()
	var player := _main.get_node_or_null("Player") as Node3D
	if player == null:
		return
	var saved: Variant = _main.get("player_spawn_position")
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_instance_valid(player) or not (saved is Vector3):
		return
	var pos: Vector3 = saved
	# A vehicle carries its rider; leave them be. The survey drone does NOT:
	# a world saved mid-flight parks the body here, and skipping it left the
	# body on the vanished load floor (y 0, ~73 m over Mount Vernon's ground).
	if bool(player.get("is_riding")) and not bool(player.get("is_fpv_drone_mode")):
		return
	# A world reloaded at a different size (Terrain options → Apply & reload)
	# is centred on a different mean elevation, so the saved Y belongs to the
	# old frame — hundreds of metres off on a big world — and a smaller world
	# can leave the saved spot past its edge. Keep the spot, fix the height.
	var limit := maxf(_half_extent - 50.0, 0.0)
	pos.x = clampf(pos.x, -limit, limit)
	pos.z = clampf(pos.z, -limit, limit)
	player.global_position = pos + Vector3(0.0, 0.05, 0.0)
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO
	if "fall_start_height" in player:
		player.fall_start_height = pos.y
		player.highest_point_during_fall = pos.y
	if "void_reference_y" in player:
		player.void_reference_y = pos.y
	var footing := _ground_height_at(pos.x, pos.z)
	if is_finite(footing) and (pos.y < footing - 0.5 or pos.y > footing + RESUME_MAX_ABOVE_GROUND_M):
		print("TerrainLoader: resumed player %.1f m off the ground — reseating" % (pos.y - footing))
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
	var d := 0.0 if _edit_tiles == null else _edit_tiles.sample_delta(x, z)
	if _channel_tiles != null:
		d += _channel_tiles.sample_delta(x, z)
	return d


## Ensure the channel + composed stores exist (same grid as the player layer).
func _ensure_tile_stack() -> void:
	if _edit_tiles == null:
		_edit_tiles = TerrainEditTiles.new()
	if _channel_tiles == null:
		_channel_tiles = TerrainEditTiles.new()
	if _composed_tiles == null:
		_composed_tiles = TerrainEditTiles.new()


## Fold every tile either layer dirtied since the last call into the composed
## store (which marks those composed tiles dirty for the HeightField). Bound as
## the HeightField's `pre_consume`, so every queue/reconcile site stays as is.
func _sync_composed_tiles() -> void:
	_ensure_tile_stack()
	var keys := {}
	for k in _edit_tiles.consume_dirty():
		keys[k] = true
	for k in _channel_tiles.consume_dirty():
		keys[k] = true
	if keys.is_empty():
		return
	_composed_tiles.compose_from([_channel_tiles, _edit_tiles], keys.keys())


## Deep copies of the player + channel layers for a worker thread (drainage
## analysis samples the EDITED surface off the main thread).
func tile_layers_snapshot() -> Array:
	_ensure_tile_stack()
	return [_edit_tiles.clone(), _channel_tiles.clone()]


## The procedural channel layer the WaterNetwork carves into.
func channel_tile_layer() -> TerrainEditTiles:
	_ensure_tile_stack()
	return _channel_tiles


## Push freshly-carved channel tiles into the rendered terrain. Tiles under the
## player reconcile immediately (so nobody stands over a sunk DetailGround);
## the rest go through the HeightField's per-frame budget.
func commit_channel_tiles(touched_keys: Array) -> void:
	_ensure_edit_tiles()
	if _height_field != null and is_instance_valid(_height_field):
		_height_field.queue_dirty()
		var player := _main.get_node_or_null("Player") as Node3D if _main != null else null
		if player != null and _xz_in_touched_tiles(
				Vector2(player.global_position.x, player.global_position.z), touched_keys):
			_height_field.reconcile_dirty_now()
	_refresh_detail_sink()
	_reseat_actors_after_edit(touched_keys)


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
	return WorldPaths.site_file("terrain_tiles", _lat, _lon, "bin")


func _load_edit_tiles() -> void:
	_edit_tiles = TerrainEditTiles.new()
	var path := _edit_tiles_path()
	if FileAccess.file_exists(path):
		_edit_tiles.load_from_file(path)
	# Fresh stack for this map: the channel layer comes back from the water
	# network's cache (so a returning site renders its channels from frame
	# one) and is then re-carved incrementally once OSM water is known.
	_channel_tiles = TerrainEditTiles.new()
	_composed_tiles = TerrainEditTiles.new()
	var wn := _water_network()
	if wn != null:
		wn.bind_map(_lat, _lon)
		wn.load_cache_into(_channel_tiles)


# ---------------------------------------------------------------------------
# Water network (core/water/) — carved channels, streams, drainage
# ---------------------------------------------------------------------------

## The WaterNetwork child, created on first use.
func _water_network() -> WaterNetwork:
	var wn := get_node_or_null("WaterNetwork") as WaterNetwork
	if wn == null:
		wn = WaterNetwork.new()
		wn.name = "WaterNetwork"
		wn.loader = self
		add_child(wn)
	return wn


func water_network() -> WaterNetwork:
	return _water_network()


## Terrain options' "show water" — the network hides its stream surfaces too.
func water_visible() -> bool:
	return _terrain_config().show_water


func _request_water_network_rebuild(force: bool = false) -> void:
	if not _built:
		return
	var wn := _water_network()
	if wn != null:
		wn.request_rebuild(force)


## OSM water items only (the network resolves lines from their centrelines;
## the player's ponds are not flowing water).
func osm_water_items() -> Array:
	return _osm_vectors.get("water", []) as Array


## A frozen, thread-safe copy of the BASE ground (no edit tiles) — exactly
## what `_height_field_base` / `_dem_height_without_earthworks` sample.
func make_water_ground_sampler() -> WaterGroundSampler:
	var s := WaterGroundSampler.new()
	var detail := _detail_footing_grid()
	s.coarse = _built_grid
	s.coarse_res = MESH_RES
	s.coarse_extent_m = _built_extent
	s.center_elev = _built_center_elev
	s.detail = detail
	s.detail_cols = _detail_elev_cols
	s.detail_rows = _detail_elev_rows
	s.detail_extent_m = _detail_extent_m()
	if detail.is_empty() and _detail_elev_resolved:
		s.fallback = _compose_base_footing_grid(true)
	s.flat_y = _spawn_ground_y
	return s


## A carve landed on `touched` tiles: things seated on the ground there follow
## it down (vegetation, camps, props) and the water surfaces re-drape.
## `light` = an erosion re-carve: the beds dropped a few cm inside the
## channels, where nothing stands — only placed props (an intake on the bank)
## are re-seated; the forest, camps and still water are left as they are.
func on_channels_carved(touched: Array, light: bool = false) -> void:
	if touched.is_empty():
		return
	if light:
		# Only a prop standing on a touched tile can have moved, and only
		# a move of a centimetre or more is worth rebuilding the props for.
		var moved := false
		if _placed_prop_layer != null:
			for item in _placed_prop_layer.props:
				if not (item is Dictionary):
					continue
				var d: Dictionary = item
				var xz := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
				if not _xz_in_touched_tiles(xz, touched):
					continue
				var gy := _ground_height_at(xz.x, xz.y)
				if absf(gy - float(d.get("ground_y", gy))) > 0.01:
					d["ground_y"] = gy
					moved = true
		if moved:
			_rebuild_placed_props()
			if not _user_overlays_ephemeral:
				_placed_prop_layer.save(_lat, _lon)
		return
	_reground_vegetation()
	if _auto_veg_generated:
		_reground_auto_vegetation()
	_reground_camp_areas()
	_reground_placed_props()
	_queue_water_redrape()


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
	_ensure_tile_stack()
	var hf := terrain.get_node_or_null("HeightField") as TerrainHeightField
	if hf == null:
		hf = TerrainHeightField.new()
		hf.name = "HeightField"
		terrain.add_child(hf)
	_height_field = hf
	hf.pre_consume = Callable(self, "_sync_composed_tiles")
	hf.configure(_composed_tiles, Callable(self, "_height_field_base"),
		_detail_extent_m(), _detail_ground_material(terrain))
	_sync_height_field_shadows(terrain)
	hf.rebuild_all_now()


## Edit tiles cast shadows exactly when the DetailGround around them does. A
## large patch (≥ 3 km) turns the ground's shadows off; tiles that still cast
## then spill a shadow-map texel (15–20 m at that range) off every edge onto
## ground that throws none back, which under a low sun draws a dark staircase
## along each tile and makes it read as a raised slab.
func _sync_height_field_shadows(terrain: Node3D) -> void:
	if _height_field == null or not is_instance_valid(_height_field) or terrain == null:
		return
	var dg := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	if dg != null:
		_height_field.set_cast_shadow(dg.cast_shadow)


## How far the DetailGround surface drops beneath the interior of active edit
## tiles. Deep on purpose: the coarse grid (~12–47 m/vertex) linearly chords
## between samples, so a shallow graded sink could still cut above a hi-res pond
## floor near its banks. A deep drop makes that geometrically impossible, and
## the chasm is always roofed by the opaque tile meshes.
const TILE_SINK_HEADROOM_M := 60.0


## Signature of the active edited-tile set — the sink only depends on WHICH
## tiles exist, so an unchanged set skips the detail-patch rebuild.
func _sink_signature() -> String:
	if _composed_tiles == null:
		return ""
	_sync_composed_tiles()
	var keys: Array = []
	for key in _composed_tiles.active_tiles():
		var k: Vector2i = key
		if _composed_tiles.tile_has_edits(k):
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
	if _composed_tiles == null:
		return grid
	_sync_composed_tiles()
	if _composed_tiles.is_empty():
		return grid
	# Edited-tile membership as a key SET: carved channels can activate a
	# hundred-odd tiles, and the old rect-list scan (every sample × 9
	# neighbours × every rect) grew into tens of millions of tests.
	var keyset := {}
	for key in _composed_tiles.active_tiles():
		var k: Vector2i = key
		if _composed_tiles.tile_has_edits(k):
			keyset[k] = true
	if keyset.is_empty():
		return grid
	var span := float(_composed_tiles.tile_cells) * _composed_tiles.cell_m
	var out := grid.duplicate()
	var ext := _detail_extent_m()
	var half := ext * 0.5
	var cell := ext / float(maxi(res - 1, 1))
	for r in res:
		var z := float(r) / float(maxi(res - 1, 1)) * ext - half
		for c in res:
			var x := float(c) / float(maxi(res - 1, 1)) * ext - half
			var p := Vector2(x, z)
			if not _in_tile_keyset(keyset, span, p):
				continue
			# Boundary-ring samples follow the local cut (delta→0 at the union
			# edge, so the surface stays continuous with untouched terrain);
			# fully interior samples (all 8 neighbours covered) drop the whole
			# headroom so a coarse chord can never bridge above a hi-res cut.
			var sink := maxf(0.0, -_composed_tiles.sample_delta(x, z))
			var interior := true
			for oz in [-1, 0, 1]:
				for ox in [-1, 0, 1]:
					if ox == 0 and oz == 0:
						continue
					if not _in_tile_keyset(keyset, span, p + Vector2(float(ox) * cell, float(oz) * cell)):
						interior = false
			if interior:
				sink = TILE_SINK_HEADROOM_M
			if sink > 0.0:
				out[r * res + c] -= sink
	return out


## Tile-key membership of a world XZ (the tile whose rect holds the point).
static func _in_tile_keyset(keyset: Dictionary, span: float, p: Vector2) -> bool:
	return keyset.has(Vector2i(floori(p.x / span), floori(p.y / span)))


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
##
## Scoped to `touched_keys` (the edit-tile keys the commit actually changed):
## an actor standing outside every touched tile cannot have been buried by the
## edit, so it is never moved. The burial test is against the actor's FEET —
## the Player origin sits at the capsule bottom, so a grounded player has
## pos.y ≈ gy and `pos.y < gy + 0.1` was true on EVERY commit, teleporting them
## to gy + 2.0 to fall back down (the "player pops on brush release" bug).
func _reseat_actors_after_edit(touched_keys: Array = []) -> void:
	# Every sculpt commit and undo lands here: the ground under a pond may have
	# moved, so the basin memos go (the fingerprint check is the backstop) —
	# and so does any pre-rendered simulation that integrated the old basin.
	_invalidate_basin_caches()
	var graph := _find_system_graph_view()
	if graph != null and graph.has_method("invalidate_sim_render_all"):
		graph.call("invalidate_sim_render_all")
	if _main == null or touched_keys.is_empty():
		return
	var player := _main.get_node_or_null("Player") as CharacterBody3D
	if player != null:
		var pos := player.global_position
		if _xz_in_touched_tiles(Vector2(pos.x, pos.z), touched_keys):
			var gy := _ground_height_at(pos.x, pos.z)
			if pos.y < gy - 0.05:
				pos.y = gy + 0.1
				player.global_position = pos
				player.velocity = Vector3(player.velocity.x, 0.0, player.velocity.z)
				if "fall_start_height" in player:
					player.fall_start_height = pos.y
					player.highest_point_during_fall = pos.y
				if "void_reference_y" in player:
					player.void_reference_y = pos.y
	var drone := _main.get_node_or_null("FPVDrone") as FPVDrone
	if drone != null:
		var dpos := drone.global_position
		if _xz_in_touched_tiles(Vector2(dpos.x, dpos.z), touched_keys):
			var dgy := _ground_height_at(dpos.x, dpos.z)
			if dpos.y < dgy + 0.25:
				dpos.y = dgy + DRONE_GROUND_CLEARANCE_M
				drone.global_position = dpos


## True when the XZ point lies inside (or within one cell of) any touched
## edit-tile's world rect — the grow covers an actor straddling a tile edge
## whose height came from the neighbouring tile's edited corner samples.
func _xz_in_touched_tiles(p: Vector2, keys: Array) -> bool:
	if _edit_tiles == null:
		return false
	for k: Variant in keys:
		if k is Vector2i and _edit_tiles.tile_world_rect(k).grow(_edit_tiles.cell_m).has_point(p):
			return true
	return false


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
	var show_vegetation := true
	var generate_camps := true
	var near_field_detail := true
	var show_pois := true
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
			show_vegetation = bool(cfg.get_value("terrain", "show_vegetation", true))
			generate_camps = bool(cfg.get_value("terrain", "generate_camps", true))
			near_field_detail = bool(cfg.get_value("terrain", "near_field_detail", true))
			show_pois = bool(cfg.get_value("terrain", "show_pois", true))
			cache_enabled = bool(cfg.get_value("terrain", "cache_enabled", true))
			camp_exclusion_r = float(cfg.get_value("terrain", "camp_exclusion_r", 804.672))
	return {
		"flatten_roads": flatten_roads,
		"flatten_landuse": flatten_landuse,
		"show_buildings": show_buildings,
		"show_water": show_water,
		"show_auto_vegetation": show_auto_vegetation,
		"show_vegetation": show_vegetation,
		"generate_camps": generate_camps,
		"near_field_detail": near_field_detail,
		"show_pois": show_pois,
		"cache_enabled": cache_enabled,
		"camp_exclusion_r": camp_exclusion_r,
	}


## ---------------------------------------------------------------------------
## Points of interest (core/poi/): pins imported from a Google Earth KML so a
## real place on the property — a culvert inlet, the pond outlet, a clearing —
## can be found in the world instead of guessed at. One PoiLayer per site
## (WorldPaths kind "poi"), rendered by a PoiRuntime under Terrain, listed in
## Terrain options with a Go button, drawn on the Site Plan.
## ---------------------------------------------------------------------------

func _attach_pois() -> void:
	if _main == null:
		return
	var path := PoiLayer.save_path_for_map(_lat, _lon)
	if pois == null or _pois_path != path:
		pois = PoiLayer.create_empty()
		pois.load_from(path)
		_pois_path = path
	_show_pois = bool(_terrain_config().get("show_pois", true))
	_sync_pois()
	if pois.count() > 0:
		print("TerrainLoader._attach_pois: %d points of interest" % pois.count())


func _ensure_poi_runtime() -> PoiRuntime:
	if _main == null:
		return null
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return null
	if is_instance_valid(_poi_runtime) and _poi_runtime.get_parent() == terrain:
		return _poi_runtime
	var stale := terrain.get_node_or_null(PoiRuntime.NODE_NAME)
	if stale != null:
		terrain.remove_child(stale)
		stale.queue_free()
	_poi_runtime = PoiRuntime.new()
	_poi_runtime.name = PoiRuntime.NODE_NAME
	terrain.add_child(_poi_runtime)
	return _poi_runtime


func _sync_pois() -> void:
	var rt := _ensure_poi_runtime()
	if rt == null or pois == null:
		return
	rt.set_shown(_show_pois)
	rt.sync(pois, _lat, _lon, Callable(self, "_ground_height_at"))


func _save_pois() -> void:
	if pois == null or _pois_path.is_empty():
		return
	pois.save_to(_pois_path)


## Import a Google Earth KML / KMZ: every placemark becomes a pin (a line or
## polygon a draped ribbon) at its real coordinates. Importing the same file
## again REPLACES its pins. Returns {ok, added, replaced, off_map, error,
## warnings}.
func import_kml_file(path: String) -> Dictionary:
	if pois == null:
		_attach_pois()
	if pois == null:
		return {"ok": false, "error": "No site loaded", "added": 0, "replaced": 0, "off_map": 0, "warnings": []}
	var parsed := KmlPoiParser.parse_file(path)
	if not bool(parsed.get("ok", false)):
		_toast("KML import failed: %s" % str(parsed.get("error", "")), ToastUI.Level.ERROR)
		return {"ok": false, "error": str(parsed.get("error", "")), "added": 0, "replaced": 0, "off_map": 0, "warnings": []}
	var res := pois.import_kml(parsed, path.get_file())
	_save_pois()
	_sync_pois()
	var n := int(res.get("added", 0))
	var off := _poi_count_off_map(path.get_file())
	var msg := "Imported %d point%s of interest from %s" % [n, "" if n == 1 else "s", path.get_file()]
	if off > 0:
		msg += " — %d outside this map" % off
	if n == 0:
		msg = "No placemarks found in %s" % path.get_file()
	_toast(msg, ToastUI.Level.WARN if (off > 0 or n == 0) else ToastUI.Level.OK)
	return {"ok": true, "added": n, "replaced": int(res.get("replaced", 0)), "off_map": off,
		"error": "", "warnings": parsed.get("warnings", [])}


func _poi_count_off_map(source: String) -> int:
	if pois == null:
		return 0
	var n := 0
	for rec in pois.records:
		if str(rec.get("source", "")) != source:
			continue
		var xz := PoiLayer.world_xz(rec, _lat, _lon)
		if absf(xz.x) > _half_extent or absf(xz.y) > _half_extent:
			n += 1
	return n


## Copies of the site's POI records (for the options list / harnesses).
func poi_records() -> Array:
	return pois.records.duplicate(true) if pois != null else []


## Site Plan markers: [{id, name, kind, pos: Vector2 (site xz), color: Color,
## points: PackedVector2Array (lines / polygons)}]. Empty while pins are hidden.
func poi_markers() -> Array:
	var out: Array = []
	if pois == null or not _show_pois:
		return out
	for rec in pois.records:
		var kind := str(rec.get("kind", "point"))
		out.append({
			"id": str(rec.get("id", "")),
			"name": str(rec.get("name", "")),
			"kind": kind,
			"pos": PoiLayer.world_xz(rec, _lat, _lon),
			"color": PoiLayer.color_of(rec),
			"points": PoiLayer.points_world_xz(rec, _lat, _lon) if kind != "point" else PackedVector2Array(),
		})
	return out


## World position of a pin's foot (on the edit-aware ground), or Vector3.INF.
func poi_world_position(id: String) -> Vector3:
	if pois == null:
		return Vector3.INF
	var rec := pois.get_record(id)
	if rec.is_empty():
		return Vector3.INF
	var xz := PoiLayer.world_xz(rec, _lat, _lon)
	return Vector3(xz.x, _ground_height_at(xz.x, xz.y), xz.y)


func remove_poi(id: String) -> bool:
	if pois == null or not pois.remove(id):
		return false
	_save_pois()
	_sync_pois()
	return true


func remove_poi_source(source: String) -> int:
	if pois == null:
		return 0
	var n := pois.remove_source(source)
	if n > 0:
		_save_pois()
		_sync_pois()
	return n


func clear_pois() -> void:
	if pois == null:
		return
	pois.clear()
	_save_pois()
	_sync_pois()


func show_pois() -> bool:
	return _show_pois


func set_show_pois(on: bool) -> void:
	_show_pois = on
	_save_terrain_config_value("show_pois", on)
	if is_instance_valid(_poi_runtime):
		_poi_runtime.set_shown(on)


## Put the player a step south of the pin, on the ground, so the pin stands
## right in front of them. A save resume still restores the saved position.
func teleport_to_poi(id: String) -> bool:
	var at := poi_world_position(id)
	if at == Vector3.INF or _main == null:
		return false
	var player := _main.get_node_or_null("Player")
	if player == null:
		return false
	var pos := Vector3(at.x, 0.0, at.z + 2.5)
	pos.y = _ground_height_at(pos.x, pos.z) + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M
	player.global_position = pos
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO
	if "fall_start_height" in player:
		player.fall_start_height = pos.y
		player.highest_point_during_fall = pos.y
	var rec := pois.get_record(id)
	_toast("At %s" % str(rec.get("name", "the pin")), ToastUI.Level.INFO)
	return true


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


## Ground truth for the terrain-options "which DEM is actually loaded" hint.
## Reads the ACTUAL cached file for the current site/extent (filename-only, no
## multi-hundred-MB JSON decode — see ElevationService.cached_dem_source), not
## a prediction from the extent alone: eligible-by-size and actually-loaded are
## different questions once OpenTopography's own access tier is in play (a
## non-academic key gets HTTP 401 on USGS1m regardless of coverage — see
## ElevationService.USGS1M_MAX_SIDE_M).
func get_detail_dem_status() -> Dictionary:
	var source := ElevationService.cached_dem_source(_lat, _lon, "detail", _detail_half_extent)
	var miss_reason := ElevationService.usgs1m_miss_reason(_lat, _lon)
	var label := "not loaded yet"
	var is_best := false
	match source:
		"":
			label = "not loaded yet"
		"opentopo_usgs1":
			label = "1 m USGS lidar"
			is_best = true
		"opentopo_usgs10":
			label = "10 m USGS"
		"openmeteo":
			label = "Open-Meteo (~90 m)"
		"terrarium":
			label = "Terrain tiles (no key)"
		_:
			if source.begins_with("opentopo_"):
				label = "OpenTopography %s" % source.trim_prefix("opentopo_")
			else:
				label = source
	return {
		"source": source,
		"label": label,
		"is_best": is_best,
		"miss_reason": miss_reason,
	}


## Rebuild this map at new sizes. All three are HALF-extents (centre to edge);
## the Terrain options panel converts from the side lengths it shows. A value
## <= 0 keeps the current size.
func apply_terrain_extents(world_half_m: float, detail_half_m: float, osm_half_m: float) -> void:
	var s := TerrainExtents.sanitize(
		world_half_m if world_half_m > 0.0 else _half_extent,
		detail_half_m if detail_half_m > 0.0 else _detail_half_extent,
		osm_half_m if osm_half_m > 0.0 else _osm_half_extent)
	_half_extent = float(s["world_half_m"])
	_detail_half_extent = float(s["detail_half_m"])
	_osm_half_extent = float(s["osm_half_m"])
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
		"Extents changed — reloading map to rebuild the terrain (cleared %s) …" % UiText.count(n_edits, "user veg file"),
		"busy")
	# Inside a world, reload THROUGH the world: record the new sizes on its
	# map block, save the snapshot (which now carries them, with the player,
	# clock and battery), and play it again. The old direct scene change left
	# the snapshot holding the OLD sizes — WorldSession.launch prefers the
	# snapshot's — so the next time the world was played from the list it
	# came back at the size it had before; it also skipped the WorldPaths
	# seal and reset the clock and battery.
	if WorldPaths.has_active_world() and _relaunch_world_at_current_extents():
		return
	var ctx := get_node_or_null("/root/MapContext")
	if ctx == null or get_tree() == null:
		push_warning("TerrainLoader: MapContext unavailable — falling back to in-place refresh (terrain size will not update until the map is fully reloaded)")
		reset_site_to_fresh()
		return
	ctx.set_pending(_lat, _lon, _map_label, _half_extent, false, _detail_half_extent, _osm_half_extent)
	WorldSession.switch_scene(MapDefinition.GENERATED_SCENE, {}, "")


func _relaunch_world_at_current_extents() -> bool:
	var rec := WorldSession.active_record()
	if rec.is_empty():
		return false
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	map["half_extent_m"] = _half_extent
	map["detail_half_extent_m"] = _detail_half_extent
	map["osm_half_extent_m"] = _osm_half_extent
	rec["map"] = map
	WorldStore.save_record(rec)
	if not WorldSession.save_now(_main, false, false):
		push_warning("TerrainLoader: world save before the resize failed")
	# launch() takes the snapshot's sizes over the map block's: make sure the
	# snapshot on disk says the new ones even if the save above did not run.
	var id := str(rec.get("id", ""))
	var snap := WorldStore.read_snapshot(id)
	if not snap.is_empty():
		snap["half_extent_m"] = _half_extent
		snap["detail_half_extent_m"] = _detail_half_extent
		snap["osm_half_extent_m"] = _osm_half_extent
		WorldStore.write_snapshot(id, snap)
	var err := WorldSession.launch(WorldSession.active_record())
	if err != OK:
		push_warning("TerrainLoader: world relaunch failed (%s) — reloading the map directly" % error_string(err))
		return false
	return true


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


## Near-field ground detail: the tiling dirt albedo/normal (or its procedural
## fallback) that terrain_detail.gdshader blends over the aerial photo within
## ~30 m of the camera. Reads well on bare ground, fights grass/forest.
##
## Applied in TWO places on purpose: the static on TerrainBuilder so any material
## built LATER (terrain rebuild, refresh, new hi-res tile) is stamped with the
## choice, and a live push onto the materials already on screen so the toggle is
## instant. Neither alone is sufficient — the shader's own default is true, so a
## rebuild without the static would silently switch it back on.
func set_near_field_detail(on: bool) -> void:
	_save_terrain_config_value("near_field_detail", on)
	TerrainBuilder.near_detail_enabled = on
	_push_near_field_detail(on)


func _push_near_field_detail(on: bool) -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	_push_near_field_detail_recursive(terrain, on)


## Walks the whole Terrain subtree rather than the named Ground/DetailGround pair
## the snow push uses: the HeightField sculpt tiles, and any future draped mesh,
## carry this same shader, and a tile left on the old setting is a visible seam.
## (Tiles share DetailGround's material INSTANCE, so most writes here are
## redundant — harmless for a one-shot toggle, and it cannot miss anything.)
func _push_near_field_detail_recursive(node: Node, on: bool) -> void:
	var mi := node as MeshInstance3D
	if mi != null:
		var sm := mi.material_override as ShaderMaterial
		if sm != null and sm.shader != null \
				and sm.shader.resource_path.ends_with("terrain_detail.gdshader"):
			sm.set_shader_parameter("near_detail_enabled", on)
	for child in node.get_children():
		_push_near_field_detail_recursive(child, on)


## Show/hide DEM + OSM world geometry (Ground, buildings, water, camps, veg).
## Does not affect placed props/lights or whether the next load uses disk cache.
func set_cached_geometry_visible(on: bool) -> void:
	_cached_geometry_visible = on
	_apply_cached_geometry_visibility()


func _apply_cached_geometry_visibility() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var on := _cached_geometry_visible
	for child_name in ["Ground", "DetailGround", "Buildings", "BuildingsCustom",
			"Water", "Camps", CampAreaRuntime.NODE_NAME, "AutoVegetation", "Vegetation",
			"SolarArrays"]:
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
	# Inside a WORLD this is "Re-download map data": the MAP layers (DEM,
	# imagery, OSM) refetch and the world's own painted vegetation, props and
	# sculpting are kept. A clean slate is a NEW world (World panel / picker).
	if WorldPaths.has_active_world():
		_notify_options_status("Re-downloading this map's terrain, imagery and OSM — your world is kept …", "busy")
		refresh_all_cached_layers()
		return
	var n_edits := TerrainCacheSettings.invalidate_user_vegetation_edits(_lat, _lon)
	_vegetation_layer = VegetationLayer.create_empty()
	_auto_veg_edits = AutoVegetationEdits.create_empty()
	_veg_style = VegetationStyleConfig.load_merged(_lat, _lon)
	_rebuild_vegetation()
	_clear_auto_vegetation()
	_auto_veg_generated = false
	_auto_veg_data = {}
	_notify_options_status("Resetting site — cleared %s …" % UiText.count(n_edits, "user veg file"), "busy")
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


## How long the base elevation phase waits. A big world goes up as several
## OpenTopography tiles with retries and a fallback ladder (ElevationService),
## so it gets up to 10 minutes; a DEM that still lands later is applied then
## (_late_base_dem) rather than thrown away.
func _elev_phase_timeout_s() -> float:
	return clampf(_half_extent / 25000.0 * 150.0, 150.0, 600.0)


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
	if get_node_or_null("/root/ImageryService") == null:
		push_warning("TerrainLoader: ImageryService unavailable")
		return
	_request_detail_imagery(-1, true)


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
		# Sink below the LOWEST ground in the patch, not below the map's mean
		# elevation: on a wide map the site can sit far under the mean (Walton:
		# ~100 m on a 120 km world), and a floor at "mean - 80" then hangs
		# metres ABOVE the real terrain as an invisible walkable sheet.
		TerrainBuilder.sink_coarse_centre_for_detail(
			built_collision, MESH_RES, _built_extent, _detail_extent_m(),
			TerrainBuilder.sink_reference_elev(detail_surf, _built_center_elev),
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
	# Normals still come from the UNSUNK grid, or every vertex on a tile's edge
	# leans toward the hidden 60 m drop and shades the ground beside the tiles.
	var shade_grid := mesh_grid
	mesh_grid = _detail_mesh_grid_with_sink(mesh_grid, mesh_res)
	_detail_sink_sig = _sink_signature()
	TerrainBuilder.upsert_detail_patch(
		terrain, mesh_grid, mesh_res, _detail_extent_m(),
		_built_center_elev, _drape, _detail_drape, _built_extent, _seam_feather_m,
		shade_grid)
	_sync_height_field_shadows(terrain)
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
	_reground_camp_areas()
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
			"Open-Meteo elevation quota used up today — add OpenTopography key (see docs/LOCAL_CONFIG.md) or reload tomorrow",
			"warn")
	print("TerrainLoader: add an OpenTopography API key to user://terrain_config.cfg for 30 m / 10 m DEM (see docs/LOCAL_CONFIG.md)")


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
	# Phase 8: the dock and the Tune-look modal used to SHARE one ad-hoc layer
	# (25), so which one drew on top came down to sibling order. They are
	# different bands — a dock and a modal — and now say so via UITheme.
	var layer := CanvasLayer.new()
	layer.name = "VegetationEditLayer"
	layer.layer = UITheme.LAYER_PANEL
	ui_layer.add_child(layer)
	var edit_ui := Control.new()
	edit_ui.name = "VegetationEditUI"
	edit_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	edit_ui.set_script(VEGETATION_EDIT_UI_SCRIPT)
	layer.add_child(edit_ui)
	edit_ui.bind_loader(self)
	_vegetation_edit_ui = edit_ui
	var modal_layer := CanvasLayer.new()
	modal_layer.name = "VegetationPreviewLayer"
	modal_layer.layer = UITheme.LAYER_MODAL
	ui_layer.add_child(modal_layer)
	var preview_ui := Control.new()
	preview_ui.name = "VegetationPreviewEditor"
	preview_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_ui.set_script(VEGETATION_PREVIEW_EDITOR_SCRIPT)
	modal_layer.add_child(preview_ui)
	preview_ui.bind_loader(self, edit_ui)
	_vegetation_preview_ui = preview_ui


func open_vegetation_preview_editor(initial_preset: int = -1, species_id: String = "") -> void:
	if _vegetation_preview_ui != null and _vegetation_preview_ui.has_method("open"):
		_vegetation_preview_ui.call("open", initial_preset, species_id)


## Tune look on ONE plant (V toolbar Select → click): the modal's one-tree
## mode, with "this tree / this world / every world" scopes.
func open_vegetation_instance_editor(desc: Dictionary) -> bool:
	if _vegetation_preview_ui == null or not _vegetation_preview_ui.has_method("open_for_instance"):
		return false
	_vegetation_preview_ui.call("open_for_instance", desc)
	return bool(_vegetation_preview_ui.call("is_instance_mode"))


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
	# The growth maths reads <species>_growth_years off the style, so it must be
	# loaded BEFORE the painted records are migrated (_setup_auto_vegetation
	# loads it again; it used to be the only load).
	_veg_style = VegetationStyleConfig.load_merged(_lat, _lon)
	_growth_migrate_manual()
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
	var settings := _auto_veg_runtime_settings()
	if not _auto_veg_generated:
		_note_impostor_reach_built()
	VegetationRuntime.rebuild(terrain, _vegetation_layer, Callable(self, "_ground_height_at"),
		false, settings)
	_rebuild_deadwood(settings)
	_apply_vegetation_visibility()


## Stumps and fallen logs among the standing trees (VegDeadwood). Derived from
## the painted AND generated records, so it runs after either layer rebuilds;
## off unless the style sets deadwood_per_100_trees.
func _rebuild_deadwood(settings: Dictionary = {}) -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	if settings.is_empty():
		settings = _auto_veg_runtime_settings()
	var bulks: Array = []
	if _vegetation_layer != null:
		bulks.append(_vegetation_layer.bulk)
	if _auto_veg_layer != null and _terrain_config().show_auto_vegetation:
		bulks.append(_auto_veg_layer.bulk)
	_rebuild_floor_moss(settings, bulks)
	if not VegDeadwood.enabled(settings):
		VegDeadwood.clear(terrain)
		return
	VegDeadwood.rebuild(terrain, bulks, Callable(self, "_ground_height_at"), settings,
		veg_point_excluded_callable())


## Forest-floor moss (VegFloorMoss): rebuild the mask with the vegetation and
## push it onto the terrain materials (the per-tick push keeps it on a
## material that was swapped when imagery landed).
var _floor_moss: Dictionary = {}
var _floor_moss_strength := 0.0
var _floor_moss_color := VegFloorMoss.DEFAULT_COLOR


func _rebuild_floor_moss(settings: Dictionary, bulks: Array) -> void:
	_floor_moss_strength = VegFloorMoss.strength(settings)
	var c: Variant = settings.get(VegFloorMoss.KEY_COLOR, VegFloorMoss.DEFAULT_COLOR)
	_floor_moss_color = c if c is Color else VegFloorMoss.DEFAULT_COLOR
	_floor_moss = VegFloorMoss.build(bulks) if _floor_moss_strength > 0.0 else {}
	_push_floor_moss()


func _push_floor_moss() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	for node_name in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(node_name) as MeshInstance3D
		if mi == null:
			continue
		var sm := mi.material_override as ShaderMaterial
		if sm == null or sm.shader == null:
			continue
		if not sm.shader.resource_path.ends_with("terrain_detail.gdshader"):
			continue
		if _floor_moss.is_empty():
			sm.set_shader_parameter("moss_strength", 0.0)
			continue
		sm.set_shader_parameter("moss_tex", _floor_moss["tex"])
		sm.set_shader_parameter("moss_rect", _floor_moss["rect"])
		sm.set_shader_parameter("moss_strength", _floor_moss_effective())
		sm.set_shader_parameter("moss_color", _floor_moss_color)


func _floor_moss_effective() -> float:
	return 0.0 if _veg_hidden else _floor_moss_strength


## Terrain options -> "Show vegetation": hides EVERY plant layer (painted,
## OSM-generated, hero trees, stumps and logs, falling leaves) and the ground
## moss / leaf litter they paint. Visibility only: nothing is deleted or
## regenerated, so switching it back on is instant. The tick re-applies it
## while hidden, because the auto-veg rebuild replaces its root node.
var _veg_hidden := false
var _veg_hide_poll := 0.0
const VEG_ROOT_NAMES: Array[String] = ["Vegetation", "AutoVegetation",
	VegDeadwood.ROOT_NAME, "VegLeafFall"]


func show_vegetation() -> bool:
	return not _veg_hidden


func set_show_vegetation(on: bool) -> void:
	_save_terrain_config_value("show_vegetation", on)
	_veg_hidden = not on
	_litter_pushed = -1.0
	_apply_vegetation_visibility()
	_push_floor_moss()
	_refresh_lens_after_veg_rebuild()


func _apply_vegetation_visibility() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	for nm in VEG_ROOT_NAMES:
		var n := terrain.get_node_or_null(nm) as Node3D
		if n != null and n.visible == _veg_hidden:
			n.visible = not _veg_hidden
	# Plants the player placed as MODELS (a tree, a stump, hanging vines from
	# the model library) are props, not vegetation records — hide those too.
	# Only nodes hidden HERE are shown again (a prop can be hidden for its
	# own reasons).
	for holder in [terrain.get_node_or_null("PlacedProps"), _main]:
		if holder == null:
			continue
		for ch in (holder as Node).get_children():
			if not (ch is PlacedProp):
				continue
			var pp := ch as PlacedProp
			if _veg_hidden:
				if pp.visible and prop_is_plant(pp.model_id):
					pp.visible = false
					pp.set_meta(&"veg_hidden", true)
			elif pp.has_meta(&"veg_hidden"):
				pp.visible = true
				pp.remove_meta(&"veg_hidden")


## Words that make a placed model a plant for "Show vegetation" (its catalog
## category, label or id, whole words; plurals too).
const PLANT_WORDS: Array[String] = ["tree", "cedar", "maple", "fir", "pine", "spruce",
	"hemlock", "alder", "oak", "birch", "aspen", "willow", "stump", "log", "vine", "vines",
	"ivy", "fern", "shrub", "bush", "hedge", "plant", "palm", "cactus", "flower", "grass",
	"moss", "bamboo", "leaf", "leaves", "foliage", "vegetation", "trees", "plants"]
static var _plant_cache := {}


static func prop_is_plant(model_id: String) -> bool:
	if _plant_cache.has(model_id):
		return bool(_plant_cache[model_id])
	var e := ModelCatalog.find(model_id)
	var text := "%s %s %s" % [str(e.get("category", "")), str(e.get("label", "")), model_id]
	var hit := false
	var rx := RegEx.create_from_string("[a-z]+")
	for m in rx.search_all(text.to_lower()):
		var w := m.get_string()
		if w in PLANT_WORDS or w.trim_suffix("s") in PLANT_WORDS:
			hit = true
			break
	_plant_cache[model_id] = hit
	return hit


## Roads / buildings / water as a point test (Vector2 site metres -> bool) for
## anything scattered off the standing vegetation (deadwood, understory) that
## must not land on a road. Built FRESH each call: the camp tool's cached index
## can predate the OSM load and would then exclude nothing.
func veg_point_excluded_callable() -> Callable:
	var roads: Array = (_osm_vectors.get("roads", []) as Array).duplicate()
	roads.append_array(get_festival_roads())
	var idx := VegExclusionBuilder.build_index(
		VegExclusionBuilder.build_all(_buildings_data, roads, _water_data,
			1.5, 1.0, 1.0, true, true),
		maxf(_osm_half_extent, 500.0))
	# A lambda, not Callable(idx, ...): a Callable does not keep a RefCounted
	# alive, the captured variable does.
	return func(p: Vector2) -> bool: return idx.is_excluded(p)


## How many TREES (pine / deciduous families — never grass, shrubs or
## crops) stand within `radius_m` of a site point, over the painted layer,
## the generated forest (when it is shown) and the hero GLBs. The ambient
## bed's birdsong reads it (AmbientMix.forest_density); a bounding-box test
## first, so a 30 m query over a 20 000-record forest is one cheap pass.
func forest_trees_within(x: float, z: float, radius_m: float) -> int:
	var r2 := radius_m * radius_m
	var n := 0
	var bulks: Array = []
	if _vegetation_layer != null:
		bulks.append(_vegetation_layer.bulk)
	if _auto_veg_layer != null and _terrain_config().show_auto_vegetation:
		bulks.append(_auto_veg_layer.bulk)
	for b in bulks:
		for species in (b as Dictionary):
			if not VegSpeciesCatalog.is_tree_family(str(species)):
				continue
			var recs: Variant = (b as Dictionary)[species]
			if not (recs is Array):
				continue
			for rec in (recs as Array):
				if not (rec is Dictionary):
					continue
				var dx := float((rec as Dictionary).get("x", 0.0)) - x
				if dx > radius_m or dx < -radius_m:
					continue
				var dz := float((rec as Dictionary).get("z", 0.0)) - z
				if dz > radius_m or dz < -radius_m:
					continue
				if dx * dx + dz * dz <= r2:
					n += 1
	if _vegetation_layer != null:
		for h in _vegetation_layer.hero:
			if h is Dictionary:
				var dx := float((h as Dictionary).get("x", 0.0)) - x
				var dz := float((h as Dictionary).get("z", 0.0)) - z
				if dx * dx + dz * dz <= r2:
					n += 1
	return n



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
	_ensure_leaf_fall()
	_refresh_lens_after_veg_rebuild()


## The graph's 3D lenses capture ON DEMAND and do not notice node changes, so
## a capture taken while the veg batches were being freed and rebuilt kept
## whole species missing until the next orbit — another source of "trees
## popping" in the Globe. Re-capture a moment after a rebuild lands.
func _refresh_lens_after_veg_rebuild() -> void:
	if not is_inside_tree():
		return
	var t := get_tree().create_timer(0.25)
	t.timeout.connect(func() -> void:
		if _auto_rebuild_active:
			return
		var sgv: Node = ServiceLocator.graph()
		if sgv == null or not is_instance_valid(sgv) or not (sgv is CanvasItem):
			return
		if not (sgv as CanvasItem).is_visible_in_tree():
			return
		var pv: Variant = sgv.get("_soi_preview")
		if pv is Node and is_instance_valid(pv) and (pv as Node).has_method("request_refresh"):
			(pv as Node).call("request_refresh")
	, CONNECT_ONE_SHOT)


## Phase 6: the falling-leaf emitter host. One node per map, created after the
## first load and kept across veg rebuilds (it scans the built batches rather
## than living inside them — see VegLeafFall's header). Enable state follows the
## graphics preset's veg tier, so re-selecting a quality level turns it on/off
## without a rebuild.
var _leaf_fall: VegLeafFall = null


func _ensure_leaf_fall() -> void:
	if _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	if _leaf_fall == null or not is_instance_valid(_leaf_fall):
		_leaf_fall = VegLeafFall.new()
		_leaf_fall.name = "VegLeafFall"
		terrain.add_child(_leaf_fall)
	_leaf_fall.bind_terrain(terrain)
	var vq := RenderProfile.QUALITY_HIGH
	if _main.get("graphics_quality") != null:
		vq = int(_main.get("graphics_quality"))
	_leaf_fall.set_enabled(bool(RenderProfile.veg_profile(vq).get("leaf_fall", false)))


## Phase 4: graphics preset changed. Re-scatter when the tier moved a
## generator-read key (density, caps — _forest_params_changed decides), else
## just rebuild so ring radii / shells / cull distances re-apply. No-ops on a
## re-select of the current level.
var _veg_quality_applied := -999
var _veg_quality_prev_eff: Dictionary = {}


func on_graphics_quality_changed(level: int) -> void:
	if not _built:
		_veg_quality_applied = level
		return
	if level == _veg_quality_applied:
		return
	_veg_quality_applied = level
	var new_eff := _veg_style_with_quality()
	var scatter_changed := true
	if not _veg_quality_prev_eff.is_empty():
		scatter_changed = _forest_params_changed(_veg_quality_prev_eff, new_eff)
	_veg_quality_prev_eff = new_eff
	_toast("Vegetation tier: %s" % RenderProfile.quality_name(level), ToastUI.Level.INFO)
	VegetationCardFactory.clear_foot_cache()
	_ensure_leaf_fall()
	if _auto_veg_generated and scatter_changed:
		call_deferred("_rebuild_vegetation")
		call_deferred("_full_regenerate_auto_vegetation_async")
	else:
		call_deferred("_rebuild_all_vegetation")


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


## Overhaul v2: tree LOD is camera-distance based, so moving the SoI pin no
## longer changes which trees are detailed. What the SoI RADIUS does decide is
## how far the impostor tier must reach for the Globe lens / snowglobe to see
## the whole sphere (`_impostor_reach_m`); ranges are build-time only, so a
## radius change that moves that reach debounces ONE rebuild.
## The impostor reach the forest was last FULLY built with.
func _note_impostor_reach_built() -> void:
	_impostor_reach_built_m = _impostor_reach_m()


func _on_soi_changed_for_veg() -> void:
	if not _built or _impostor_reach_rebuild_pending:
		return
	var want := _impostor_reach_m()
	if absf(want - _impostor_reach_built_m) < 25.0:
		return
	_impostor_reach_rebuild_pending = true
	var t := get_tree().create_timer(1.0)
	t.timeout.connect(func() -> void:
		_impostor_reach_rebuild_pending = false
		if _built and absf(_impostor_reach_m() - _impostor_reach_built_m) >= 25.0:
			_rebuild_all_vegetation()
	, CONNECT_ONE_SHOT)


## How far the far (impostor / photocard) tree tier must draw so the Globe lens
## and the full-screen snowglobe never cut whole 256 m chunks out of the
## sphere. Visibility range is measured from the camera to each CHUNK'S AABB
## centre, the orbit camera stands up to MAX_ORBIT_MULT x R from the SoI
## centre, the sphere's far rim is another R beyond that, and a tree can sit a
## chunk half-diagonal nearer than its chunk centre. Measured on Mount Vernon
## (R 200 m, large map): the plain 480 m cull end lost the back third of the
## globe and blocks blinked in and out as the camera orbited.
func _impostor_reach_m() -> float:
	var r := SoiConfig.DEFAULT_RADIUS_M
	var soi := get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("radius_m"):
		r = float(soi.call("radius_m"))
	return clampf(r * (IMPOSTOR_GLOBE_ORBIT_MULT + 1.0) + IMPOSTOR_CHUNK_HALF_DIAG_M
		+ 40.0, 0.0, IMPOSTOR_REACH_MAX_M)


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
		_auto_veg_runtime_settings())


## ---------------------------------------------------------------------------
## Auto-vegetation (generated, non-persisted; ROADMAP Pillar 8)
## ---------------------------------------------------------------------------

func _setup_auto_vegetation() -> void:
	_auto_veg_layer = AutoVegetationLayer.create_empty()
	_auto_veg_generated = false
	_auto_veg_edits = AutoVegetationEdits.create_empty()
	_auto_veg_edits.load_for_map(_lat, _lon)
	_veg_style = VegetationStyleConfig.load_merged(_lat, _lon)
	# Phase 4: seed the quality-change tracker with the level this load builds
	# at, so the first preset switch compares against the right baseline.
	if _main != null and _main.get("graphics_quality") != null:
		_veg_quality_applied = int(_main.get("graphics_quality"))
	_veg_quality_prev_eff = _veg_style_with_quality()
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
	_rebuild_litter_mask()
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
		"winter_min_c": _site_winter_min_c(),
		# Phase 7: player per-area fills scatter inside the generator (FILLS
		# phase) so they obey the same budgets/exclusions as OSM polygons.
		"fills": _auto_veg_edits.fills.duplicate(true) if _auto_veg_edits != null else [],
		"seed": int(_lat * 10000.0) ^ int(_lon * 10000.0),
		"exclusions": _auto_veg_exclusions(),
		"ground_y_at": Callable(self, "_ground_height_at"),
		"gate": gate,
		# Phase 4: the generator sees the SAME quality-tier baseline as the
		# runtimes, so scatter caps/density and render rings always agree.
		"style": _veg_style_with_quality(),
	}


## Phase 6: the site's estimated winter minimum temperature, feeding the
## species climate envelope's cold-hardiness gate. NAN whenever the weather
## service has nothing for this location (offline, uncovered, still fetching) —
## the gate then falls back to latitude alone rather than guessing.
## Cached because a scatter can re-run several times per load and the estimate
## only moves when the site does; `_veg_winter_min_site` records which.
var _veg_winter_min_c := NAN
var _veg_winter_min_site := Vector2(NAN, NAN)


func _site_winter_min_c() -> float:
	var site := Vector2(_lat, _lon)
	if is_finite(_veg_winter_min_c) and _veg_winter_min_site.is_equal_approx(site):
		return _veg_winter_min_c
	var ws := get_node_or_null("/root/WeatherService")
	if ws == null or not ws.has_method("covers") or not bool(ws.call("covers", _lat, _lon)):
		return NAN
	_veg_winter_min_c = SeasonModel.estimate_winter_min_c(ws, _lat)
	_veg_winter_min_site = site
	return _veg_winter_min_c


## Phase 4: _veg_style + the RenderProfile veg tier baseline. The graphics
## preset supplies ring radii, leaf-shell count, instance caps, cull distances
## and (large maps) scatter density — replacing the old silent hardcoded
## thinning with a visible, selectable tier. A key the player explicitly tuned
## (merged value differs from VegetationStyleConfig.defaults(), the same
## provenance rule the style store uses) always wins over the tier. Both the
## scatter ctx and the render settings build on this, so generator and
## runtimes never disagree.
## The RenderProfile veg-tier style overlay for the current quality level,
## exposed publicly so the Tune-look preview can apply the SAME
## only-fills-defaults rule the render path uses below (WYSIWYG).
func veg_quality_tier_style() -> Dictionary:
	var vq := RenderProfile.QUALITY_HIGH
	if _main != null and _main.get("graphics_quality") != null:
		vq = int(_main.get("graphics_quality"))
	var prof := RenderProfile.veg_profile(vq)
	var tier_style: Dictionary = (prof["style"] as Dictionary).duplicate()
	if _is_large_world_map():
		tier_style.merge(prof["style_large"] as Dictionary, true)
	return tier_style


func _veg_style_with_quality() -> Dictionary:
	var tier_style := veg_quality_tier_style()
	var out := _veg_style.duplicate(true)
	var veg_defaults: Dictionary = VegetationStyleConfig.defaults()
	for k in tier_style:
		if not out.has(k):
			out[k] = tier_style[k]
		elif veg_defaults.has(k) and VegStyleStore.values_equal(out[k], veg_defaults[k]):
			out[k] = tier_style[k]
		# else: explicit player/style value — the tier never overrides it.
	# Tells AutoVegetationGenerator.prepare_context its legacy large-map
	# fallback rewrite is superseded (the tier values are authoritative).
	out["veg_quality_managed"] = true
	return out


func _auto_veg_runtime_settings() -> Dictionary:
	var seasonal := Color.WHITE
	if _veg_style.get("seasonal_strength", 0.0) > 0.0 and _main != null:
		var month := int(_main.get("month")) if _main.get("month") != null else 6
		var autumn_t := clampf(absf(float(month) - 10.0) / 3.0, 0.0, 1.0)
		seasonal = Color(1.0, 0.92 - autumn_t * 0.2, 0.75 - autumn_t * 0.15)
	var s := VegetationStyleConfig.runtime_settings(
		_veg_style_with_quality(), _drape, _built_extent, seasonal)
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
	# Growth: only the STATIC inputs go in here (the site epoch the derived
	# births hang off). The current year must NOT — mesh/material caches and
	# batch partitioning hash this dict, and a value that moves with the clock
	# would miss the cache on every rebuild. The year reaches the shaders as a
	# uniform instead (_push_growth_year).
	s[VegetationGrowth.KEY_EPOCH] = _growth_epoch_y()
	# Overhaul v2 LOD: budget-shrunk effective tree detail distance. The user's
	# tree_detail_distance_m is honoured wherever affordable; on dense maps the
	# worst-case near-set of full 3D trees is capped by the quality tier's
	# budget (VegLodPolicy shrinks the range, never flattens the forest).
	var bulks: Array = []
	if _vegetation_layer != null:
		bulks.append(_vegetation_layer.bulk)
	if _auto_veg_layer != null:
		bulks.append(_auto_veg_layer.bulk)
	var requested := float(s.get("tree_detail_distance_m", 220.0))
	var budget := int(s.get("tree_near_budget", 1500))
	s["tree_detail_eff_m"] = VegLodPolicy.effective_detail_distance(
		VegLodPolicy.chunk_tree_counts(bulks), requested, budget)
	# Far tier reach for the Globe lens / snowglobe (see _impostor_reach_m).
	# Never SHORTER than the style's own cull end.
	# Only the FULL rebuilds record the reach as built (see
	# _note_impostor_reach_built): a painted-only or chunk rebuild must not
	# make the SoI-radius debounce skip the generated forest.
	s[VegLodPolicy.KEY_FAR_TIER_END] = maxf(_impostor_reach_m(),
		float(s.get("auto_visibility_end_m", 0.0)))
	return s


# ==================== VEGETATION GROWTH ====================

## The growth-year right now: whole years tick with the calendar, the fraction
## follows the growing season (VegGrowthModel.growth_year).
func _growth_year_now() -> float:
	if _main == null:
		return VegGrowthModel.BASE_YEAR
	var y: Variant = _main.get("year")
	var doy: Variant = _main.get("day_of_year")
	var hour: Variant = _main.get("day_time")
	if y == null or doy == null:
		return VegGrowthModel.BASE_YEAR
	return VegGrowthModel.growth_year(int(y),
		float(doy) + (float(hour) / 24.0 if hour != null else 0.0), _lat)


## Site epoch the `mixed` / `young` forest-age profiles count from. Stamped once
## per map (and saved) the first time one of those profiles is in use; the
## default `mature` profile is stationary and never reads it.
func _growth_epoch_y() -> float:
	if _vegetation_layer == null:
		return VegGrowthModel.BASE_YEAR
	if is_nan(_vegetation_layer.growth_epoch_y):
		if VegetationGrowth.forest_age_profile(_veg_style) == VegetationGrowth.FOREST_AGE_MATURE:
			return VegGrowthModel.BASE_YEAR
		_vegetation_layer.growth_epoch_y = _growth_year_now()
		_vegetation_layer.save(_lat, _lon)
	return _vegetation_layer.growth_epoch_y


## Settings for CPU-side growth queries (food yield, readouts, stamping): the
## span keys off the style + what year it is. NOT for the render path — see the
## cache note in _auto_veg_runtime_settings.
func _growth_style() -> Dictionary:
	var s := {
		VegetationGrowth.KEY_NOW: _growth_year_now(),
		VegetationGrowth.KEY_EPOCH: _growth_epoch_y(),
		VegetationGrowth.KEY_FROZEN: not _growth_any_enabled(),
		"forest_age": str(_veg_style.get("forest_age",
			VegetationGrowth.FOREST_AGE_MATURE)),
	}
	for k in _veg_style:
		var ks := str(k)
		if ks.ends_with("_growth_years") or ks.ends_with("_growth_days") \
				or ks.ends_with("_lifespan_years"):
			s[ks] = _veg_style[k]
	return s


## Cheap per-frame check (reads _veg_style directly, no dict build).
func _growth_any_enabled() -> bool:
	if _main != null and _main.get("plant_growth_enabled") == false:
		return false
	for sp in VegetationLayer.ALL_SPECIES:
		if float(_veg_style.get("%s_growth_years" % sp, 0.0)) > 0.0:
			return true
	return false


## Tell the vegetation shaders what year it is. This is ALL that happens as time
## passes: no transform is rewritten and nothing is rebuilt. Change-gated, so a
## paused clock costs one float compare per frame.
func _push_growth_year() -> void:
	var frozen := not _growth_any_enabled()
	var now := _growth_year_now()
	if frozen == _growth_frozen_pushed and not is_nan(_growth_year_pushed) \
			and absf(now - _growth_year_pushed) < 1.0e-5:
		return
	var tree := get_tree()
	if tree == null:
		return
	var env := tree.root.get_node_or_null("VegetationEnvironmentSync")
	if env == null or not env.has_method("set_growth"):
		return
	env.call("set_growth", now - VegGrowthModel.BASE_YEAR, frozen)
	_growth_year_pushed = now
	_growth_frozen_pushed = frozen


## Upgrade painted records to calendar birth years right after the manual layer
## loads (legacy files carry `birth_h` on a dead per-session clock, or nothing).
## Not saved here — the next ordinary save persists it, so merely LOADING a map
## never rewrites the player's vegetation file.
func _growth_migrate_manual() -> void:
	if _vegetation_layer == null:
		return
	var st := _growth_style()
	var n := VegetationGrowth.migrate_records(_vegetation_layer.bulk, st,
		float(st[VegetationGrowth.KEY_NOW]))
	if n > 0:
		print("TerrainLoader: migrated %d painted plant(s) to calendar birth years" % n)


# ==================== CLIMELAPSE BAKE / PLAYBACK ====================

func _ensure_climelapse_capture() -> void:
	if is_instance_valid(_climelapse_capture):
		return
	_climelapse_capture = ClimelapseCapture.new()
	_climelapse_capture.name = "ClimelapseCapture"
	add_child(_climelapse_capture)
	_climelapse_capture.capture_progress.connect(_on_climelapse_progress)
	_climelapse_capture.capture_complete.connect(_on_climelapse_capture_complete)


## Export a video. `opts` is a ClimelapseExportOptions dictionary (range,
## speed, size, fps, folder + file name, render settings). The camera follows
## the timeline keyframes when there are any; with none it stays locked on the
## current view. (The drone used to make up a sweep of its own with no keys —
## a half-orbit pan nobody asked for; with no keys the shot is now still.)
func start_climelapse_export_with(opts: Dictionary) -> bool:
	var o := ClimelapseExportOptions.normalize(opts)
	if str(o.get("folder", "")).is_empty():
		return _refuse_export("No output folder chosen.")
	if float(o["end_abs"]) <= float(o["start_abs"]):
		return _refuse_export("Export range is empty — the end time must be after the start.")
	var tree := get_tree()
	if tree == null:
		return _refuse_export("No scene tree.")
	stop_climelapse_preview()
	var rig := ClimelapseCameraRig.snapshot_from_tree(tree)
	if not rig.is_valid():
		return _refuse_export("No active 3D camera — switch to player or drone view first.")
	var keys := climelapse_keys()
	if not keys.is_empty():
		rig.keys = keys.duplicate_keys()
		rig.mode = "keys"

	_export_render_start = float(o["start_abs"])
	_export_render_end = float(o["end_abs"])
	_export_time_scale = float(o["hours_per_second"])
	_export_mp4_path = ClimelapseExportOptions.output_path(o)
	_export_camera = rig
	_export_fps = int(o["fps"])
	_export_pending = true
	_export_status_message = ""
	_export_last_result = ""

	if _main != null and _main.has_method("set_absolute_hours"):
		_main.call("set_absolute_hours", _export_render_start)

	_ensure_climelapse_capture()
	_climelapse_capture.start_capture(self, o, rig)
	climelapse_state_changed.emit()
	return true


## Older entry point (range + world speed + full path), kept for scripts.
func start_climelapse_export(start_abs: float, end_abs: float, time_scale: float, output_mp4: String, fps: int = 30) -> bool:
	if output_mp4.is_empty():
		return _refuse_export("No output path chosen.")
	var o := ClimelapseExportOptions.load_prefs()
	o["start_abs"] = start_abs
	o["end_abs"] = end_abs
	o["hours_per_second"] = time_scale
	o["fps"] = fps
	o["folder"] = output_mp4.replace("\\", "/").get_base_dir()
	o["file_name"] = output_mp4.get_file()
	return start_climelapse_export_with(o)


func _refuse_export(reason: String) -> bool:
	_export_pending = false
	_export_status_message = reason
	_export_last_result = "fail"
	push_warning("Climelapse export: %s" % reason)
	climelapse_state_changed.emit()
	return false


# --- camera keyframes ---------------------------------------------------------

func _clim_keys_path() -> String:
	return WorldPaths.site_file("climelapse_keys", _lat, _lon)


func climelapse_keys() -> ClimelapseKeyframes:
	if _clim_keys == null:
		_clim_keys = ClimelapseKeyframes.load_json(_clim_keys_path())
	return _clim_keys


func _save_climelapse_keys() -> void:
	var keys := climelapse_keys()
	var path := _clim_keys_path()
	if keys.is_empty():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	else:
		keys.save_json(path)
	climelapse_state_changed.emit()


func _active_camera() -> Camera3D:
	var tree := get_tree()
	if tree == null or tree.root.get_viewport() == null:
		return null
	return tree.root.get_viewport().get_camera_3d()


## Key the current view at absolute hour `t` (replaces a key already at that
## moment). Returns the key's index, or -1 without a camera.
func set_climelapse_key_at(t: float) -> int:
	var cam := _active_camera()
	if cam == null:
		push_warning("Climelapse keyframe: no active Camera3D.")
		return -1
	var i := climelapse_keys().set_key(t, cam.global_transform, cam.fov)
	_save_climelapse_keys()
	return i


func move_climelapse_key(i: int, t: float) -> int:
	var j := climelapse_keys().move_key(i, t)
	_save_climelapse_keys()
	return j


## Give key i the current view, keeping its time.
func repose_climelapse_key(i: int) -> void:
	var cam := _active_camera()
	if cam == null:
		return
	climelapse_keys().repose_key(i, cam.global_transform, cam.fov)
	_save_climelapse_keys()


func remove_climelapse_key(i: int) -> void:
	climelapse_keys().remove_key(i)
	_save_climelapse_keys()


## Set key i's pose (the camera-path editor). `save` false while a gizmo drag
## is under way; the release saves.
func set_climelapse_key_pose(i: int, pos: Vector3, yaw: float, pitch: float, fov: float, save: bool = true) -> void:
	climelapse_keys().set_pose(i, pos, yaw, pitch, fov)
	if save:
		_save_climelapse_keys()


## Put the keys back as they were (the editor's Revert).
func restore_climelapse_keys(kf: ClimelapseKeyframes) -> void:
	if kf == null:
		return
	_clim_keys = kf.duplicate_keys()
	_save_climelapse_keys()


## The camera-path editor: the keyframes drawn as a path in the world with
## each one's view, a gizmo for pan / tilt / position, and the numbers.
## `key_index` -1 = the key nearest the playhead. `opts` = the export's
## options for its Preview (empty = the remembered ones).
func open_climelapse_path_editor(key_index: int = -1, opts: Dictionary = {}) -> bool:
	if is_climelapse_exporting():
		return false
	stop_climelapse_preview()
	if not is_instance_valid(_clim_path_editor):
		if _main == null:
			return false
		var ui_layer := _main.get_node_or_null("UILayer")
		if ui_layer == null:
			return false
		_clim_path_editor = PanelContainer.new()
		_clim_path_editor.name = "ClimelapsePathEditor"
		_clim_path_editor.set_script(load("res://scenes/ui/climelapse_path_editor.gd"))
		ui_layer.add_child(_clim_path_editor)
		_clim_path_editor.call("bind_loader", self)
	return bool(_clim_path_editor.call("open", key_index, opts))


func is_climelapse_path_editing() -> bool:
	return is_instance_valid(_clim_path_editor) and bool(_clim_path_editor.call("is_open"))


func close_climelapse_path_editor() -> void:
	if is_instance_valid(_clim_path_editor):
		_clim_path_editor.call("close")


func set_climelapse_keys_smooth(on: bool) -> void:
	climelapse_keys().smooth = on
	_save_climelapse_keys()


## 📍: key the current view at the playhead.
func add_climelapse_path_waypoint() -> bool:
	var t := float(_main.call("get_absolute_hours")) if _main != null and _main.has_method("get_absolute_hours") else 0.0
	return set_climelapse_key_at(t) >= 0


func clear_climelapse_path() -> void:
	climelapse_keys().clear()
	_save_climelapse_keys()


func get_climelapse_path_count() -> int:
	return climelapse_keys().size()


# --- preview ------------------------------------------------------------------

## Play the shot in the game window before exporting: the clock walks the range
## at the export's speed in real time and the camera follows the keyframes.
## `from_abs` NAN = the range start. Esc or stop_climelapse_preview ends it.
func start_climelapse_preview(opts: Dictionary, from_abs: float = NAN, paused: bool = false) -> bool:
	if is_climelapse_exporting():
		return false
	stop_climelapse_preview()
	var rig := ClimelapseCameraRig.snapshot_from_tree(get_tree())
	if not rig.is_valid():
		return false
	var keys := climelapse_keys()
	if not keys.is_empty():
		rig.keys = keys.duplicate_keys()
	_clim_preview = ClimelapsePreview.new()
	_clim_preview.name = "ClimelapsePreview"
	add_child(_clim_preview)
	_clim_preview.finished.connect(func() -> void:
		_clim_preview = null
		climelapse_state_changed.emit())
	var ok := _clim_preview.begin(_main, ClimelapseExportOptions.normalize(opts), rig, from_abs, paused)
	if not ok:
		_clim_preview.queue_free()
		_clim_preview = null
	climelapse_state_changed.emit()
	return ok


func stop_climelapse_preview() -> void:
	if is_instance_valid(_clim_preview):
		_clim_preview.end()
	_clim_preview = null


func is_climelapse_previewing() -> bool:
	return is_instance_valid(_clim_preview) and _clim_preview.is_running()


func get_climelapse_preview_hours() -> float:
	return _clim_preview.current_hours() if is_climelapse_previewing() else NAN


func get_climelapse_export_preview_texture() -> Texture2D:
	return _climelapse_capture.get_preview_texture() if _climelapse_capture != null else null


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


## A pair of absolute hours is a PackedFloat64Array, never a Vector2: its
## float32 components hold ~1.8e7 h only to the nearest 2 h.
func get_climelapse_range_abs() -> PackedFloat64Array:
	return PackedFloat64Array([_export_render_start, _export_render_end])


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
		# Validity first: a vegetation rebuild during the export frees batches,
		# and `is` on a freed instance is a runtime error.
		if is_instance_valid(node) and node is MultiMeshInstance3D:
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


## ---------------------------------------------------------------------------
## Per-area fill (veg overhaul Phase 7)
## ---------------------------------------------------------------------------

## Fill one OSM vegetation area with a chosen species. Records the fill (keyed by
## the area's stable centroid tag, so it survives an OSM re-fetch), applies it to
## the LIVE layer immediately, and rebuilds. The same fill replays through the
## generator's FILLS phase on the next load and produces the identical forest —
## AutoVegetationGenerator.apply_fill is the one implementation, seeded per fill
## rather than from the run.
##
## `params`: {species, density, height_m, replace}. Returns {placed, removed}.
func apply_area_fill(area_idx: int, params: Dictionary) -> Dictionary:
	var out := {"placed": 0, "removed": 0, "ok": false}
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array):
		return out
	var info := VegAreaPicker.area_info(polys as Array, area_idx)
	if not bool(info.get("valid", false)):
		return out
	var poly: PackedVector2Array = info.get("points", PackedVector2Array())
	var tag := str(info.get("tag", ""))
	if _auto_veg_edits == null:
		_auto_veg_edits = AutoVegetationEdits.create_empty()
	_auto_veg_edits.add_fill(tag, poly, params)
	_auto_veg_edits.save(_lat, _lon)
	if _auto_veg_layer == null or not _auto_veg_generated:
		# Nothing scattered yet (fill drawn mid-load): the record is saved and the
		# generator's FILLS phase will place it.
		out["ok"] = true
		return out
	var at := _auto_veg_edits.fill_index_for_tag(tag)
	var fill: Dictionary = _auto_veg_edits.fills[at]
	var res := AutoVegetationGenerator.apply_fill(_auto_veg_layer, fill,
		_auto_veg_biome(), VegExclusionBuilder.build_index(_auto_veg_exclusions(),
			maxf(_osm_half_extent, _half_extent)), _auto_veg_ctx())
	out["placed"] = int(res.get("placed", 0))
	out["removed"] = int(res.get("removed", 0))
	out["ok"] = true
	_rebuild_litter_mask()
	# Incremental: a fill touches a handful of 256 m chunks, so only those are
	# re-meshed. The full rebuild is kept as the fallback for the paths that
	# genuinely change everything (style/quality/ring changes).
	if not _rebuild_auto_vegetation_chunks(poly):
		_rebuild_auto_vegetation()
	return out


## Re-mesh only the chunks a polygon touches. False when the incremental path
## isn't usable (no terrain / auto veg not built / auto veg hidden), so the
## caller can fall back to the whole-layer rebuild.
func _rebuild_auto_vegetation_chunks(poly: PackedVector2Array) -> bool:
	if not _built or _auto_veg_layer == null or _main == null or poly.size() < 3:
		return false
	if not _auto_veg_generated or not _terrain_config().show_auto_vegetation:
		return false
	var terrain := _main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return false
	var keys := VegetationRuntime.chunk_keys_for_polygon(poly)
	if keys.is_empty():
		return false
	var n := AutoVegetationRuntime.rebuild_chunks(terrain, _auto_veg_layer,
		Callable(self, "_ground_height_at"), _auto_veg_runtime_settings(), keys)
	print("TerrainLoader: incremental veg rebuild — %d chunk batches over %d chunks"
		% [n, keys.size()])
	return true


## Drop an area's fill record. The trees it placed stay until the next full
## re-scatter (they are ordinary layer instances by then) unless `clear_now`,
## which strips everything inside the outline — the honest "undo the fill".
func clear_area_fill(area_idx: int, clear_now: bool = true) -> bool:
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array):
		return false
	var info := VegAreaPicker.area_info(polys as Array, area_idx)
	if not bool(info.get("valid", false)) or _auto_veg_edits == null:
		return false
	var tag := str(info.get("tag", ""))
	var had := _auto_veg_edits.remove_fill_for_tag(tag)
	if clear_now:
		var poly: PackedVector2Array = info.get("points", PackedVector2Array())
		_auto_veg_edits.add_cleared_polygon(poly)
		if _auto_veg_layer != null:
			_auto_veg_layer.remove_in_polygon(poly)
	_auto_veg_edits.save(_lat, _lon)
	if _auto_veg_layer != null and _auto_veg_generated:
		_rebuild_litter_mask()
		# Clearing an area is the same shape of edit as filling it, so it takes
		# the same incremental path.
		var cleared_poly: PackedVector2Array = info.get("points", PackedVector2Array())
		if not clear_now or not _rebuild_auto_vegetation_chunks(cleared_poly):
			_rebuild_auto_vegetation()
	return had or clear_now


## The fill recorded for an area, or {} — lets the UI open showing what is
## already there instead of defaults.
func area_fill_params(area_idx: int) -> Dictionary:
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array) or _auto_veg_edits == null:
		return {}
	var info := VegAreaPicker.area_info(polys as Array, area_idx)
	if not bool(info.get("valid", false)):
		return {}
	var at := _auto_veg_edits.fill_index_for_tag(str(info.get("tag", "")))
	if at < 0:
		return {}
	return (_auto_veg_edits.fills[at] as Dictionary).duplicate(true)


## The biome table the generator would use for this site, climate-gated the same
## way prepare_context gates it — so a live fill can't offer species the next
## re-scatter would refuse.
func _auto_veg_biome() -> Dictionary:
	var biome := BiomePalette.for_location(_lat)
	var bw: Variant = biome.get("weights", {})
	if bw is Dictionary:
		biome["weights"] = VegSpeciesRegistry.filter_weights_by_climate(
			bw as Dictionary, _lat, _site_winter_min_c())
	return biome


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
	_note_impostor_reach_built()
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
	_note_impostor_reach_built()
	var exclusions := _auto_veg_exclusions()
	await AutoVegetationRuntime.rebuild_async(terrain, _auto_veg_layer,
		Callable(self, "_ground_height_at"), settings, exclusions)
	_auto_rebuild_active = false
	_apply_vegetation_visibility()
	_rebuild_deadwood(settings)
	_refresh_lens_after_veg_rebuild()

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
	_rebuild_litter_mask()
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
	# Re-read the store so the side channels (_user_family_keys /
	# _species_overrides) match what was just persisted. Without this the
	# in-session render path kept the side channels from load time: a key
	# freshly edited away from defaults wasn't flagged as a user family edit,
	# so SPECS variants kept shadowing it until the NEXT session — "the map
	# only matches the preview after I restart".
	_veg_style.merge(VegStyleStore.flat_merged(_lat, _lon), true)
	VegetationCardFactory.clear_foot_cache()
	call_deferred("_rebuild_vegetation")
	if _auto_veg_generated and (_forest_params_changed(prev, _veg_style) \
			or _exclusion_buffers_loosened(prev, _veg_style)):
		call_deferred("_full_regenerate_auto_vegetation_async")
	elif _auto_veg_generated and _exclusion_buffers_changed(prev, _veg_style):
		call_deferred("_prune_auto_veg_by_exclusions")
	else:
		call_deferred("_rebuild_auto_vegetation_async")


## Overhaul v2: a reset that actually works. Deletes THIS map's veg style
## store (+ retired v2/v1 sidecars), drops the layer's settings deltas and
## every per-record card snapshot, reloads the merged style (global + defaults
## remain) and rebuilds. Painted tree positions survive.
func reset_map_veg_style() -> void:
	for path in [VegStyleStore.map_v2_path(_lat, _lon)]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for path in VegStyleStore.legacy_style_paths(_lat, _lon):
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if _vegetation_layer != null:
		_vegetation_layer.settings = {}
		_vegetation_layer.clear_card_overrides()
		_vegetation_layer.save(_lat, _lon)
	VegStyleStore.invalidate_cache()
	_veg_style = VegetationStyleConfig.load_merged(_lat, _lon)
	VegetationCardFactory.clear_foot_cache()
	call_deferred("_rebuild_all_vegetation")
	_toast("Map vegetation style reset", ToastUI.Level.INFO)


## --- Vegetation look backups (VegLookBackup) ---------------------------------

## Snapshot this world's vegetation look (style store, painted plants, area
## edits). Returns the snapshot folder, "" on failure.
func snapshot_veg_look(label: String) -> String:
	if _vegetation_layer != null:
		_vegetation_layer.save(_lat, _lon)
	return VegLookBackup.snapshot(_lat, _lon, label)


## [{dir, label, stamp, unix}] newest first.
func veg_look_backups() -> Array:
	return VegLookBackup.list(_lat, _lon)


## Put an earlier look back and rebuild everything from it. The look as it
## stands is snapshotted first ("Before restore"), so a restore is undoable.
func restore_veg_look(dir: String) -> bool:
	snapshot_veg_look("Before restore")
	if not VegLookBackup.restore(_lat, _lon, dir):
		_toast("Could not restore that vegetation look", ToastUI.Level.WARN)
		return false
	VegStyleStore.invalidate_cache()
	_veg_style = VegetationStyleConfig.load_merged(_lat, _lon)
	if _vegetation_layer != null:
		_vegetation_layer.bulk = {}
		_vegetation_layer.hero = []
		_vegetation_layer.settings = {}
		_vegetation_layer.ensure_species_keys()
		_vegetation_layer.load_for_map(_lat, _lon)
	if _auto_veg_edits != null:
		_auto_veg_edits = AutoVegetationEdits.create_empty()
		_auto_veg_edits.load_for_map(_lat, _lon)
	VegetationCardFactory.clear_foot_cache()
	if _auto_veg_generated:
		call_deferred("_full_regenerate_auto_vegetation")
	call_deferred("_rebuild_all_vegetation")
	_toast("Vegetation look restored", ToastUI.Level.INFO)
	return true


## Nukes the GLOBAL veg style store too (every map falls back to shipped
## defaults unless it has its own per-map store). Destructive: confirmed by
## the Terrain-options dialog before calling.
func reset_all_veg_styles() -> void:
	VegetationStyleConfig.clear_global()
	reset_map_veg_style()
	_toast("ALL vegetation styles reset to defaults", ToastUI.Level.WARN)


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
	# v3: auto records bake scale = osm_height / resolved_height at SCATTER, so
	# an authored-height change must re-scatter or every stored scale encodes
	# the old resolved height.
	"deciduous_height_m", "pine_height_m",
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
	_rebuild_litter_mask()
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
	if params.get("mix") is Dictionary and not (params["mix"] as Dictionary).is_empty():
		return _populate_mix(poly, params["mix"] as Dictionary, params)
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
	# Painted plants appear MATURE, exactly as previewed: each is stamped with a
	# birth year that puts it somewhere on its full-size plateau (seed-chosen,
	# so one brush stroke dies decades-to-centuries apart). "Plant young" stamps
	# the birth as NOW instead — a seedling that grows year on year.
	var plant_young := bool(params.get("plant_young", false))
	var growth_st := _growth_style()
	var growth_now := float(growth_st[VegetationGrowth.KEY_NOW])
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
			var rec: Dictionary = (_vegetation_layer.bulk[species] as Array).back()
			if plant_young:
				VegetationGrowth.stamp_young(rec, growth_now)
			else:
				VegetationGrowth.stamp_established(rec, species, growth_st, growth_now)
	if added > 0:
		_vegetation_layer.save(_lat, _lon)
		_rebuild_vegetation()
	return added


## Paint a MIX (VegMix): the same scatter the Tune-look preview runs, so what
## was previewed is what lands — canopy, young trees, understory — and the
## mix's site look (floor moss, trunk moss, deadwood) is raised on the map to
## the mix's values (never lowered: another mix painted earlier keeps its).
func _populate_mix(poly: PackedVector2Array, mix_in: Dictionary, params: Dictionary) -> int:
	var mix := VegMix.normalized(mix_in)
	var cap := mini(_vegetation_layer.remaining_bulk_capacity(), VegMix.MAX_SCATTER)
	if cap <= 0:
		return 0
	var c := VegetationPaint.polygon_aabb(poly)
	var seed := int(params.get("seed", 1337)) ^ int(_lat * 10000.0) ^ int(_lon * 10000.0) \
		^ int(c.position.x * 13.0) ^ int(c.position.y * 7.0)
	var items := VegMix.scatter(poly, mix, seed, {
		"density": float(params.get("density", 1.0)),
		"size_var": float(params.get("size_var", 0.25)),
		"scale": float(params.get("scale", 1.0)),
		"cap": cap,
		"existing": _vegetation_layer.all_placement_points(),
	})
	var plant_young := bool(params.get("plant_young", false))
	var growth_st := _growth_style()
	var growth_now := float(growth_st[VegetationGrowth.KEY_NOW])
	var added := 0
	for it in items:
		var d: Dictionary = it
		var sid := str(d["species"])
		if not _vegetation_layer.ensure_species_key(sid) and not _vegetation_layer.bulk.has(sid):
			continue
		if _vegetation_layer.add_bulk(sid, float(d["x"]), float(d["z"]), float(d["yaw"]),
				float(d["scale"])):
			added += 1
			var rec: Dictionary = (_vegetation_layer.bulk[sid] as Array).back()
			if plant_young:
				VegetationGrowth.stamp_young(rec, growth_now)
			else:
				VegetationGrowth.stamp_established(rec, sid, growth_st, growth_now)
	if added > 0:
		_vegetation_layer.save(_lat, _lon)
		var raise := {}
		var extras := VegMix.style_extras(mix)
		for k in extras:
			if float(extras[k]) > float(_veg_style.get(k, 0.0)) + 0.001:
				raise[k] = extras[k]
		if not raise.is_empty():
			set_vegetation_style(raise, false, true)
		else:
			_rebuild_vegetation()
	return added


## The V toolbar's paint brush (density / size_var / scale / mix), for the
## Tune-look modal to preview and hand back.
func get_veg_brush() -> Dictionary:
	if _edit_toolbar_ui != null and _edit_toolbar_ui.has_method("get_veg_brush"):
		return _edit_toolbar_ui.call("get_veg_brush")
	return {}


func set_veg_brush(b: Dictionary) -> void:
	if _edit_toolbar_ui != null and _edit_toolbar_ui.has_method("set_veg_brush"):
		_edit_toolbar_ui.call("set_veg_brush", b)


## The map's own mix (style `paint_mix`); without one, the legacy mix weights
## (mix_pine / mix_deciduous / local_mix) as a mix, shrubs as understory.
func get_paint_mix() -> Dictionary:
	var m: Variant = _veg_style.get(VegMix.KEY_STYLE, {})
	if m is Dictionary and not (m as Dictionary).is_empty():
		return VegMix.normalized(m as Dictionary)
	var w := BiomePalette.mix_weights_from_style(_veg_style)
	var shrub := float(w.get("shrub", 0.0))
	w.erase("shrub")
	if w.is_empty():
		return VegMix.preset("mixed_woodland")
	var mix := VegMix.normalized({"label": "This map's mix", "trees": w})
	if shrub > 0.0:
		mix["understory"] = {"shrub": shrub * 2.0}
	return mix


## Save the map's mix. With `apply_site_look` its floor moss / trunk moss /
## deadwood are written as the map's values too (the Tune-look Apply).
func set_paint_mix(mix: Dictionary, apply_site_look: bool = true) -> void:
	var m := VegMix.normalized(mix)
	var patch := {VegMix.KEY_STYLE: m}
	if apply_site_look:
		patch.merge(VegMix.style_extras(m), true)
	# The generated forest's "Mixed (local blend)" follows the same canopy.
	patch["local_mix"] = m["trees"]
	patch["mix_pine"] = 0.0
	patch["mix_deciduous"] = 0.0
	patch["mix_shrub"] = 0.0
	set_vegetation_style(patch, true, true)


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
	# Overhaul v2: single drops match the preview too — mature by default.
	# "Plant young" (dock toggle) plants a seedling to watch grow. The old
	# always-seedling single click (a 0.14× sprout) read as "my tree shrank".
	var growth_st := _growth_style()
	var placed: Dictionary = (_vegetation_layer.bulk[species] as Array).back()
	if bool(params.get("plant_young", false)):
		VegetationGrowth.stamp_young(placed, float(growth_st[VegetationGrowth.KEY_NOW]))
	else:
		VegetationGrowth.stamp_established(placed, species, growth_st,
			float(growth_st[VegetationGrowth.KEY_NOW]))
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
	vegetation_operation_progress.emit("Done — %s" % UiText.count(added, "instance"), 1.0)
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


## ---------------------------------------------------------------------------
## Per-tree Select (veg overhaul Phase 8)
## ---------------------------------------------------------------------------

## Describe the single plant nearest a world point, for the Select tool's
## readout. {} when nothing is close enough. Manual layer only — auto-scattered
## OSM vegetation is regenerated every load, so a per-instance edit there would
## not survive (clear/fill are the tools for that).
func pick_plant_at(world_xz: Vector2, radius_m: float = 6.0) -> Dictionary:
	if _vegetation_layer == null:
		return {}
	return _vegetation_layer.nearest_plant(world_xz, radius_m)


func delete_plant_at(world_xz: Vector2, radius_m: float = 6.0) -> Dictionary:
	if _vegetation_layer == null:
		return {}
	var desc := _vegetation_layer.nearest_plant(world_xz, radius_m)
	if desc.is_empty() or not _vegetation_layer.remove_plant(desc):
		return {}
	_vegetation_layer.save(_lat, _lon)
	_rebuild_vegetation()
	return desc


func scale_plant_at(world_xz: Vector2, factor: float, radius_m: float = 6.0) -> Dictionary:
	if _vegetation_layer == null:
		return {}
	var desc := _vegetation_layer.nearest_plant(world_xz, radius_m)
	if desc.is_empty() or not _vegetation_layer.scale_plant(desc, factor):
		return {}
	_vegetation_layer.save(_lat, _lon)
	_rebuild_vegetation()
	return desc


## Promote the picked bulk plant to a hero GLB tree at the same spot, sized to
## match the card it replaces. The card species picks the model, so a pine
## becomes a pine — the dock's currently-selected hero preset is irrelevant to
## a plant that is already standing there.
##
## Returns {} when nothing was picked or the plant is already a hero.
func convert_plant_to_hero_at(world_xz: Vector2, radius_m: float = 6.0) -> Dictionary:
	if _vegetation_layer == null:
		return {}
	var desc := _vegetation_layer.nearest_plant(world_xz, radius_m)
	if desc.is_empty() or str(desc.get("kind", "")) == "hero":
		return {}
	var species := str(desc.get("species", ""))
	var preset := HeroTreeCatalog.preset_for_species(species)
	# Match the apparent height of the card being replaced: its draw scale times
	# the species' nominal card height (the same table the generator sizes
	# scattered trees with), expressed as a hero user-scale.
	var card_h := float(AutoVegetationGenerator.NOMINAL_CARD_H.get(species, 8.0))
	var target_h := maxf(card_h * float(desc.get("scale", 1.0)), 0.5)
	var hero_scale := HeroTreeCatalog.user_scale_for_target_height(preset, target_h)
	var x := float(desc.get("x", 0.0))
	var z := float(desc.get("z", 0.0))
	var gy := _ground_height_at(x, z)
	var rng := RandomNumberGenerator.new()
	if not _vegetation_layer.add_hero(preset, x, z, rng.randf() * TAU, hero_scale, gy):
		return {}
	# Only remove the card AFTER the hero is placed, so a hero-cap refusal
	# leaves the plant standing rather than deleting it into nothing.
	_vegetation_layer.remove_plant(desc)
	_vegetation_layer.save(_lat, _lon)
	_rebuild_vegetation()
	return {
		"species": species, "preset": preset, "height_m": target_h,
		"x": x, "z": z,
	}


## ---------------------------------------------------------------------------
## Select across BOTH layers: hover, the species glow, per-tree looks.
##
## The painted layer and the OSM-generated forest used to be two worlds: the
## Select tool only saw painted plants, Tune look only edited whole families,
## and nothing said what species a tree was. Here one pick (VegTreePick, a ray
## through the crowns) answers for either layer, and every edit lands where
## it persists for that layer — a painted plant's record, or a pinned patch in
## the OSM edits file that a reload replays onto the regenerated scatter.
## ---------------------------------------------------------------------------

var _veg_pick := VegTreePick.new()
## Bumped by edits that change a plant's size without changing a count (the
## pick index caches heights).
var _veg_pick_rev := 0
var _veg_hover_marker: VegHoverMarker = null
var _veg_glow_species := ""
var _veg_glow_nodes: Array = []
var _veg_glow_materials: Array = []
var _veg_glow_walked_ms := 0
var _veg_nominal_cache: Dictionary = {}


func _veg_pick_sources() -> Array:
	var out: Array = []
	if _vegetation_layer != null:
		out.append({"source": "painted", "bulk": _vegetation_layer.bulk,
			"hero": _vegetation_layer.hero, "rev": _veg_pick_rev})
	if _auto_veg_layer != null and _auto_veg_generated and _terrain_config().show_auto_vegetation:
		out.append({"source": "auto", "bulk": _auto_veg_layer.bulk,
			"hero": _auto_veg_layer.hero,
			"rev": _auto_veg_layer.get_instance_id() + _veg_pick_rev})
	return out


## The species a layer slot draws as (an OSM slot can be an alias: conifer →
## pine). Painted slots ARE species ids.
func _veg_species_of(source: String, slot: String) -> String:
	if source == "auto":
		return AutoVegetationRuntime._resolve_species(slot)
	return slot


## Resolved species dims, cached per species until the look changes.
func _veg_nominal(species: String) -> Dictionary:
	if _veg_nominal_cache.has(species):
		return _veg_nominal_cache[species]
	var fam := VegSpeciesCatalog.mesh_family(species)
	var s := VegSpeciesCatalog.settings_with_variant(species, _veg_style,
		VegetationCardFactory.SPECS)
	var h := 0.0
	var crown := 0.0
	if fam == "pine" or fam == "deciduous":
		h = float(s.get("%s_height_m" % fam, 0.0))
		crown = float(s.get("%s_crown_width_m" % fam, 0.0))
	else:
		h = float(s.get("%s_card_h" % fam, 0.0))
		crown = float(s.get("%s_card_w" % fam, 0.0))
	if h <= 0.05:
		h = float(AutoVegetationGenerator.NOMINAL_CARD_H.get(species, 6.0))
	if crown <= 0.05:
		crown = clampf(h * 0.55, 0.8, 18.0)
	var out := {"height_m": h, "crown_m": crown}
	_veg_nominal_cache[species] = out
	return out


func _veg_plant_height(slot: String, rec: Dictionary) -> float:
	var hm := float(rec.get("height_m", 0.0))
	if hm > 0.1:
		return hm
	if rec.has("preset"):
		return 12.0 * float(rec.get("scale", 1.0))
	var species := AutoVegetationRuntime._resolve_species(slot) \
		if not VegSpeciesCatalog.is_paintable(slot) else slot
	return float(_veg_nominal(species)["height_m"]) * float(rec.get("scale", 1.0))


## The plant under a screen point (ray through the crowns), else {}. The
## descriptor is good until the next edit: {source: painted|auto, kind:
## bulk|hero, slot, species, index, x, z, height_m, crown_m, label, …}.
func veg_pick_at_screen(screen_pos: Vector2) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _main == null:
		return {}
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var terrain_t := INF
	var ground: Variant = terrain_pick_ray(screen_pos)
	if ground is Vector3:
		terrain_t = origin.distance_to(ground as Vector3)
	_veg_pick.rebuild_if_changed(_veg_pick_sources(), Callable(self, "_veg_plant_height"))
	var hit := _veg_pick.pick(origin, dir, terrain_t, Callable(self, "_ground_height_at"))
	if hit.is_empty():
		return {}
	return _veg_describe(str(hit["source"]), str(hit["kind"]), str(hit["slot"]),
		int(hit["index"]), float(hit["x"]), float(hit["z"]), float(hit["h"]), float(hit["r"]))


## Nearest plant to a ground point over both layers (the click fallback when
## the ray passes between crowns).
func veg_pick_near(world_xz: Vector2, radius_m: float = 6.0) -> Dictionary:
	var best := {}
	if _vegetation_layer != null:
		var d := _vegetation_layer.nearest_plant(world_xz, radius_m)
		if not d.is_empty():
			best = d
			best["source"] = "painted"
	if _auto_veg_layer != null and _auto_veg_generated and _terrain_config().show_auto_vegetation:
		var a := _auto_veg_layer.nearest_plant(world_xz, radius_m)
		if not a.is_empty() and (best.is_empty() \
				or float(a["dist_m"]) < float(best.get("dist_m", INF))):
			best = a
			best["source"] = "auto"
	if best.is_empty():
		return {}
	var src := str(best["source"])
	var slot := str(best["species"])
	var rec: Dictionary = (_vegetation_layer.record_for(best) if src == "painted"
		else _auto_veg_layer.record_for(best))
	var h := _veg_plant_height(slot, rec)
	return _veg_describe(src, str(best.get("kind", "bulk")), slot, int(best["index"]),
		float(best["x"]), float(best["z"]), h, clampf(h * 0.28, 0.5, 9.0))


func _veg_describe(source: String, kind: String, slot: String, index: int,
		x: float, z: float, h: float, r: float) -> Dictionary:
	var species := slot if kind == "hero" else _veg_species_of(source, slot)
	var label := ""
	if kind == "hero":
		label = "%s (hero model)" % slot.capitalize()
	else:
		label = VegSpeciesCatalog.label_for(species)
	var rec: Dictionary = {}
	var layer: Variant = _vegetation_layer if source == "painted" else _auto_veg_layer
	var desc := {"source": source, "kind": kind, "slot": slot, "species": species,
		"index": index, "x": x, "z": z, "height_m": h, "crown_m": r * 2.0,
		"label": label,
		"source_label": "painted" if source == "painted" else "OSM forest"}
	if layer != null:
		rec = layer.record_for(desc)
	desc["scale"] = float(rec.get("scale", 1.0))
	var card: Variant = rec.get("card_settings", {})
	desc["custom_look"] = card is Dictionary and (card as Dictionary).has(
		VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE)
	return desc


## How many plants of `species` stand in this world, both layers.
func veg_species_count(species: String) -> int:
	var n := 0
	if _vegetation_layer != null and _vegetation_layer.bulk.get(species) is Array:
		n += (_vegetation_layer.bulk[species] as Array).size()
	if _auto_veg_layer != null and _auto_veg_generated:
		for slot in _auto_veg_layer.bulk.keys():
			if _veg_species_of("auto", str(slot)) == species:
				n += (_auto_veg_layer.bulk[slot] as Array).size()
	return n


## Show the hover ring + label on one plant, and glow its whole species.
func set_veg_hover(desc: Dictionary) -> void:
	if desc.is_empty():
		clear_veg_hover()
		return
	if _veg_hover_marker == null or not is_instance_valid(_veg_hover_marker):
		var terrain := _main.get_node_or_null("Terrain") if _main != null else null
		if terrain == null:
			return
		_veg_hover_marker = VegHoverMarker.new()
		_veg_hover_marker.name = "VegHoverMarker"
		terrain.add_child(_veg_hover_marker)
	var x := float(desc["x"])
	var z := float(desc["z"])
	var gy := _ground_height_at(x, z)
	var species := str(desc["species"])
	var n := veg_species_count(species) if str(desc.get("kind", "")) != "hero" else 0
	var line2 := "%s · %.0f m" % [str(desc.get("source_label", "")), float(desc["height_m"])]
	if n > 1:
		line2 += " · %s in this world" % UiText.thousands(n)
	if bool(desc.get("custom_look", false)):
		line2 += " · own look"
	_veg_hover_marker.show_at(Vector3(x, gy, z), float(desc["height_m"]),
		float(desc["crown_m"]) * 0.5, "%s\n%s" % [str(desc["label"]), line2])
	set_veg_species_glow("" if str(desc.get("kind", "")) == "hero" else species)


func clear_veg_hover() -> void:
	if _veg_hover_marker != null and is_instance_valid(_veg_hover_marker):
		_veg_hover_marker.hide_marker()
	set_veg_species_glow("")


## Light every batch of one species (material uniform `veg_hl`, see
## veg_lighting.gdshaderinc); "" turns it off. Batches carry their species
## as meta "veg_species" (VegetationRuntime / AutoVegetationRuntime); the
## glow is written on THEIR MATERIALS (shared per species look by
## VegAssetCache), never per instance — see the shader for why. The walk is
## redone at most twice a second while a species is lit, so chunks rebuilt
## under the pointer pick it up.
func set_veg_species_glow(species: String) -> void:
	var now := Time.get_ticks_msec()
	var stale := not _veg_glow_nodes.is_empty() and not is_instance_valid(_veg_glow_nodes[0])
	if species == _veg_glow_species and not stale \
			and (species.is_empty() or now - _veg_glow_walked_ms < 500):
		return
	for m in _veg_glow_materials:
		if is_instance_valid(m):
			(m as ShaderMaterial).set_shader_parameter(&"veg_hl", 0.0)
	_veg_glow_materials = []
	_veg_glow_nodes = []
	_veg_glow_species = species
	_veg_glow_walked_ms = now
	if species.is_empty() or _main == null:
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	for root_name in ["Vegetation", AutoVegetationRuntime.ROOT_NAME]:
		var root := terrain.get_node_or_null(NodePath(root_name))
		if root == null:
			continue
		for node in root.find_children("*", "GeometryInstance3D", true, false):
			if str(node.get_meta(&"veg_species", "")) == species:
				_veg_glow_nodes.append(node)
				for m in veg_glow_materials_of(node as GeometryInstance3D):
					if not _veg_glow_materials.has(m):
						m.set_shader_parameter(&"veg_hl", 1.0)
						_veg_glow_materials.append(m)


## The vegetation ShaderMaterials a batch draws with (override, overlay and
## per-surface), those whose shader has the `veg_hl` uniform.
static func veg_glow_materials_of(gi: GeometryInstance3D) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	var mats: Array = [gi.material_override, gi.material_overlay]
	var mesh: Mesh = null
	if gi is MeshInstance3D:
		mesh = (gi as MeshInstance3D).mesh
		for i in (gi as MeshInstance3D).get_surface_override_material_count():
			mats.append((gi as MeshInstance3D).get_surface_override_material(i))
	elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
		mesh = (gi as MultiMeshInstance3D).multimesh.mesh
	if mesh != null:
		for i in mesh.get_surface_count():
			mats.append(mesh.surface_get_material(i))
	for m in mats:
		var sm := m as ShaderMaterial
		if sm != null and sm.shader != null and not out.has(sm) and _shader_has_veg_hl(sm.shader):
			out.append(sm)
	return out


static var _veg_hl_shaders := {}


static func _shader_has_veg_hl(sh: Shader) -> bool:
	var key := sh.get_instance_id()
	if not _veg_hl_shaders.has(key):
		var found := false
		for u in sh.get_shader_uniform_list(true):
			if str((u as Dictionary).get("name", "")) == "veg_hl":
				found = true
				break
		_veg_hl_shaders[key] = found
	return bool(_veg_hl_shaders[key])


## The per-tree look on one plant ({} = it follows its species).
func veg_instance_look(desc: Dictionary) -> Dictionary:
	if str(desc.get("source", "")) == "auto":
		return _auto_veg_layer.instance_look(desc) if _auto_veg_layer != null else {}
	return _vegetation_layer.instance_look(desc) if _vegetation_layer != null else {}


## Give ONE plant its own look (Tune look → "This tree"). `look` holds
## unprefixed species-override keys (height_m, archetype, albedo_tint, …);
## {} returns the plant to its species. Painted: on the record. OSM: a pinned
## single-tree patch, replayed after every regeneration.
func apply_veg_instance_look(desc: Dictionary, look: Dictionary) -> bool:
	var x := float(desc.get("x", 0.0))
	var z := float(desc.get("z", 0.0))
	if str(desc.get("source", "")) == "auto":
		if _auto_veg_layer == null:
			return false
		if _auto_veg_edits == null:
			_auto_veg_edits = AutoVegetationEdits.create_empty()
		var slot := str(desc.get("slot", ""))
		var key := VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE
		_auto_veg_edits.remove_tree_patches(slot, key, Vector2(x, z))
		var rec := _auto_veg_layer.record_for(desc)
		if look.is_empty():
			if rec.get("card_settings") is Dictionary:
				(rec["card_settings"] as Dictionary).erase(key)
		else:
			_auto_veg_edits.add_tree_patch(x, z, slot, {key: look})
			var card: Dictionary = rec.get("card_settings", {}) if rec.get("card_settings") is Dictionary else {}
			card = card.duplicate()
			card[key] = look.duplicate(true)
			rec["card_settings"] = card
		_auto_veg_edits.save(_lat, _lon)
		if not _rebuild_auto_vegetation_chunks(AutoVegetationEdits.tree_pin(x, z)):
			_rebuild_auto_vegetation()
		return true
	if _vegetation_layer == null or not _vegetation_layer.set_instance_look(desc, look):
		return false
	_vegetation_layer.save(_lat, _lon)
	_rebuild_vegetation()
	return true


## Every plant of `species`, in this world ("world") or every world ("all"):
## the species override at that scope, with the per-tree looks of that
## species in THIS world dropped so all of them follow. "all" also removes
## the same keys from this map's own species entry, or they would keep
## shadowing the new default right here.
func apply_veg_species_look(species: String, values: Dictionary, scope: String) -> int:
	if species.is_empty() or values.is_empty():
		return 0
	if scope == "world":
		VegStyleStore.save_species_override_map(_lat, _lon, species, values)
	else:
		VegStyleStore.save_species_override(species, values)
		VegStyleStore.remove_species_override_keys_map(_lat, _lon, species, values.keys())
	var cleared := 0
	if _vegetation_layer != null:
		cleared += _vegetation_layer.clear_species_looks(species)
		_vegetation_layer.save(_lat, _lon)
	if _auto_veg_layer != null:
		for slot in _auto_veg_layer.bulk.keys():
			if _veg_species_of("auto", str(slot)) != species:
				continue
			cleared += _auto_veg_layer.clear_species_looks(str(slot))
			if _auto_veg_edits != null:
				_auto_veg_edits.remove_tree_patches(str(slot),
					VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE)
		if _auto_veg_edits != null:
			_auto_veg_edits.save(_lat, _lon)
	VegStyleStore.invalidate_cache()
	_veg_style.merge(VegStyleStore.flat_merged(_lat, _lon), true)
	_veg_nominal_cache.clear()
	_veg_pick_rev += 1
	VegetationCardFactory.clear_foot_cache()
	call_deferred("_rebuild_vegetation")
	call_deferred("_rebuild_auto_vegetation_async")
	return cleared


## Delete one plant from either layer. An OSM tree is cleared through a
## pinned clear polygon, so it stays gone after a reload.
func delete_veg_plant(desc: Dictionary) -> bool:
	if str(desc.get("source", "")) != "auto":
		return not delete_plant_at(Vector2(float(desc["x"]), float(desc["z"])), 0.5).is_empty()
	if _auto_veg_layer == null:
		return false
	var pin := AutoVegetationEdits.tree_pin(float(desc["x"]), float(desc["z"]))
	if _auto_veg_edits == null:
		_auto_veg_edits = AutoVegetationEdits.create_empty()
	_auto_veg_edits.add_cleared_polygon(pin)
	_auto_veg_edits.save(_lat, _lon)
	var n := _auto_veg_layer.remove_in_polygon(pin)
	if not _rebuild_auto_vegetation_chunks(pin):
		_rebuild_auto_vegetation()
	return n > 0


## Resize one plant from either layer (OSM: a pinned scale patch, which
## stacks with earlier resizes the way repeated [ / ] does).
func scale_veg_plant(desc: Dictionary, factor: float) -> bool:
	_veg_pick_rev += 1
	if str(desc.get("source", "")) != "auto":
		return not scale_plant_at(Vector2(float(desc["x"]), float(desc["z"])), factor, 0.5).is_empty()
	if _auto_veg_layer == null:
		return false
	var x := float(desc["x"])
	var z := float(desc["z"])
	var slot := str(desc.get("slot", ""))
	var params := {"scale_mul": factor}
	if _auto_veg_edits == null:
		_auto_veg_edits = AutoVegetationEdits.create_empty()
	_auto_veg_edits.add_tree_patch(x, z, slot, params)
	_auto_veg_edits.save(_lat, _lon)
	var live := params.duplicate()
	live["patch_species"] = slot
	var n := _auto_veg_layer.apply_patch_in_polygon(AutoVegetationEdits.tree_pin(x, z), live, true)
	if not _rebuild_auto_vegetation_chunks(AutoVegetationEdits.tree_pin(x, z)):
		_rebuild_auto_vegetation()
	return n > 0


## ---------------------------------------------------------------------------
## Detect plants from the satellite photo (VegColorDetect; the V toolbar's
## Detect tool). The SOAK scene's editor bake, available on every map.
## ---------------------------------------------------------------------------

## Longest side of the CPU copy kept of each drape for detection. A 1 km site
## patch at 3072 px is still 0.33 m a pixel — finer than any crown.
const VEG_DETECT_MAX_PX := 3072

var _veg_detect: VegColorDetect = null
var _veg_detect_sig := ""
var _veg_detect_overlay: MeshInstance3D = null
var _veg_detect_last: Dictionary = {}
var _veg_detect_last_key := 0


## The drapes as CPU images, finest first. Rebuilt only when a drape changed;
## release_veg_detect_cache() frees them when the tool is put down.
func _veg_detect_layers() -> VegColorDetect:
	var hyper_half := _hyper_half_m if _hyper_half_m > 0.0 else _hyper_half_extent()
	var layers := [
		[_site_drape, _site_half_m], [_hyper_drape, hyper_half],
		[_detail_drape, _detail_half_extent], [_drape, _half_extent],
	]
	var sig := ""
	for l in layers:
		sig += "%d:%.1f|" % [(l[0] as Object).get_instance_id() if l[0] != null else 0, float(l[1])]
	if _veg_detect != null and sig == _veg_detect_sig:
		return _veg_detect
	var d := VegColorDetect.new()
	for l in layers:
		var tex: Texture2D = l[0]
		var half := float(l[1])
		if tex == null or half <= 0.0:
			continue
		var img := tex.get_image()
		if img == null or img.is_empty():
			continue
		if img.is_compressed() and img.decompress() != OK:
			continue
		if img.get_format() != Image.FORMAT_RGB8 and img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		var longest := maxi(img.get_width(), img.get_height())
		if longest > VEG_DETECT_MAX_PX:
			var k := float(VEG_DETECT_MAX_PX) / float(longest)
			img.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)),
				Image.INTERPOLATE_BILINEAR)
		var bb := GeoMath.bbox_for(_lat, _lon, half)
		d.add_layer(img, half, float(bb["north"]), float(bb["south"]))
	_veg_detect = d
	_veg_detect_sig = sig
	return d


func release_veg_detect_cache() -> void:
	_veg_detect = null
	_veg_detect_sig = ""
	_veg_detect_last = {}
	clear_veg_detect_preview()


## The square the sharpest photo covers — "Whole area" for the Detect tool:
## the place where individual plants can actually be seen.
func veg_detect_whole_area() -> PackedVector2Array:
	var d := _veg_detect_layers()
	var half := d.finest_half_m() * 0.995
	if half <= 0.0:
		return PackedVector2Array()
	return PackedVector2Array([Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half)])


func _veg_detect_run(poly: PackedVector2Array, params: Dictionary) -> Dictionary:
	var key := hash([poly, params])
	if key == _veg_detect_last_key and not _veg_detect_last.is_empty():
		return _veg_detect_last
	var d := _veg_detect_layers()
	if not d.has_layers():
		return {}
	var p := params.duplicate()
	p["spacing_m"] = _veg_detect_spacing(params)
	var res := d.detect(poly, p)
	_veg_detect_last = res
	_veg_detect_last_key = key
	return res


## Canopy fill spacing: the planted species' crown, closed up a little (crowns
## overlap in a stand), divided by the brush density.
func _veg_detect_spacing(params: Dictionary) -> float:
	var crowns: Array = []
	var mix: Variant = params.get("mix")
	if mix is Dictionary and (mix as Dictionary).get("trees") is Dictionary:
		for sid in ((mix as Dictionary)["trees"] as Dictionary):
			crowns.append(float(_veg_nominal(str(sid))["crown_m"]))
	elif VegSpeciesCatalog.is_paintable(str(params.get("species", ""))):
		crowns.append(float(_veg_nominal(str(params["species"]))["crown_m"]))
	var c := 6.0
	if not crowns.is_empty():
		c = 0.0
		for v in crowns:
			c += float(v)
		c /= float(crowns.size())
	return clampf(c * 0.8 / maxf(float(params.get("density", 1.0)), 0.25), 1.0, 30.0)


## Classify the region and show what was found (green over the ground) without
## planting anything. Returns the stats line's numbers.
func preview_veg_detect(poly: PackedVector2Array, params: Dictionary) -> Dictionary:
	var res := _veg_detect_run(poly, params)
	if res.is_empty():
		clear_veg_detect_preview()
		return {"error": "No imagery loaded yet"}
	_draw_veg_detect_overlay(res.get("mask", {}))
	return _veg_detect_stats(res)


static func _veg_detect_stats(res: Dictionary) -> Dictionary:
	var plants: Array = res.get("plants", [])
	var canopy := 0
	for p in plants:
		if bool((p as Dictionary).get("canopy", false)):
			canopy += 1
	return {"plants": plants.size(), "canopy": canopy, "patches": int(res.get("patches", 0)),
		"green_m2": float(res.get("green_m2", 0.0)), "area_m2": float(res.get("area_m2", 0.0)),
		"cut": float(res.get("cut", NAN)), "auto": bool(res.get("auto", true)),
		"separability": float(res.get("separability", 0.0)),
		"auto_split": bool(res.get("auto_split", false)),
		"mpp": float(res.get("mpp", INF)), "cell_m": float(res.get("cell_m", 0.0))}


## Plant what detection found as PAINTED plants (editable, clearable and
## undoable like anything painted). A patch narrower than `shrub_below_m`
## becomes a shrub; the rest take the brush species / mix, sized from the
## patch (single plants) or the fill spacing (canopy). Plants are skipped on
## roads / buildings / water and where a plant already stands.
func place_detected_vegetation(poly: PackedVector2Array, params: Dictionary) -> Dictionary:
	var res := _veg_detect_run(poly, params)
	if res.is_empty() or _vegetation_layer == null:
		return {"added": 0, "error": "No imagery loaded yet"}
	_vegetation_layer.ensure_species_keys()
	var excluded := veg_point_excluded_callable()
	var existing := _veg_point_grid(3.0)
	var rng := RandomNumberGenerator.new()
	var growth_st := _growth_style()
	var growth_now := float(growth_st[VegetationGrowth.KEY_NOW])
	var forced := str(params.get("species", ""))
	var use_forced := VegSpeciesCatalog.is_paintable(forced)
	var mix: Dictionary = params["mix"] if params.get("mix") is Dictionary else {}
	var shrub_below := float(params.get("shrub_below_m", 0.0))
	var shrub_sp := _veg_detect_shrub_species(forced, mix)
	var plant_scale := clampf(float(params.get("scale", 1.0)), 0.1, 5.0)
	var size_var := clampf(float(params.get("size_var", 0.25)), 0.0, 0.5)
	var added := 0
	var skipped := 0
	var by_species := {}
	for item in res.get("plants", []):
		var pl: Dictionary = item
		var x := float(pl["x"])
		var z := float(pl["z"])
		var dm := float(pl["d_m"])
		rng.seed = hash(Vector2i(int(round(x * 10.0)), int(round(z * 10.0))))
		if bool(excluded.call(Vector2(x, z))) or _veg_point_taken(existing, x, z, maxf(0.9, dm * 0.35)):
			skipped += 1
			continue
		var species := ""
		if shrub_below > 0.0 and not bool(pl["canopy"]) and dm < shrub_below:
			species = shrub_sp
		elif use_forced:
			species = forced
		elif not mix.is_empty():
			species = BiomePalette.pick_species(mix.get("trees", {"deciduous": 1.0}), rng)
		else:
			species = "shrub"
		if not _vegetation_layer.ensure_species_key(species):
			skipped += 1
			continue
		var fam := VegSpeciesCatalog.mesh_family(species)
		var scale := 1.0
		if not fam.begins_with("grass_"):
			scale = clampf(dm / maxf(float(_veg_nominal(species)["crown_m"]), 0.3), 0.3, 2.5)
			scale *= plant_scale * (1.0 + (rng.randf() * 2.0 - 1.0) * size_var)
		if not _vegetation_layer.add_bulk(species, x, z, rng.randf() * TAU, scale):
			skipped += 1
			continue
		var rec: Dictionary = (_vegetation_layer.bulk[species] as Array).back()
		VegetationGrowth.stamp_established(rec, species, growth_st, growth_now)
		_veg_point_mark(existing, x, z)
		added += 1
		by_species[species] = int(by_species.get(species, 0)) + 1
	if added > 0:
		_vegetation_layer.save(_lat, _lon)
		_rebuild_vegetation()
	clear_veg_detect_preview()
	var out := _veg_detect_stats(res)
	out["added"] = added
	out["skipped"] = skipped
	out["by_species"] = by_species
	return out


func _veg_detect_shrub_species(forced: String, mix: Dictionary) -> String:
	if VegSpeciesCatalog.mesh_family(forced) == "shrub":
		return forced
	if mix.get("understory") is Dictionary:
		for sid in (mix["understory"] as Dictionary):
			if VegSpeciesCatalog.mesh_family(str(sid)) == "shrub" \
					and VegSpeciesCatalog.is_paintable(str(sid)):
				return str(sid)
	return "shrub"


## Every standing plant (both layers) in a coarse hash grid, for the
## "something already grows here" test.
func _veg_point_grid(cell: float) -> Dictionary:
	var g := {"cell": cell, "cells": {}}
	var pts: Array = []
	if _vegetation_layer != null:
		pts.append_array(_vegetation_layer.all_placement_points())
	if _auto_veg_layer != null and _auto_veg_generated:
		pts.append_array(_auto_veg_layer.all_points())
	for p in pts:
		_veg_point_mark(g, (p as Vector2).x, (p as Vector2).y)
	return g


static func _veg_point_mark(g: Dictionary, x: float, z: float) -> void:
	var c := float(g["cell"])
	var k := Vector2i(floori(x / c), floori(z / c))
	var cells: Dictionary = g["cells"]
	if not cells.has(k):
		cells[k] = []
	(cells[k] as Array).append(Vector2(x, z))


static func _veg_point_taken(g: Dictionary, x: float, z: float, r: float) -> bool:
	var c := float(g["cell"])
	var cells: Dictionary = g["cells"]
	var k := Vector2i(floori(x / c), floori(z / c))
	var reach := int(ceil(r / c))
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			for p in cells.get(Vector2i(k.x + dx, k.y + dz), []):
				if (p as Vector2).distance_squared_to(Vector2(x, z)) < r * r:
					return true
	return false


## The detection mask laid on the ground: a terrain-following grid (one
## ground sample per vertex, so it hugs slopes) textured with the mask.
func _draw_veg_detect_overlay(mask: Dictionary) -> void:
	var img := VegColorDetect.mask_image(mask)
	if img == null or _main == null:
		clear_veg_detect_preview()
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	if _veg_detect_overlay == null or not is_instance_valid(_veg_detect_overlay):
		_veg_detect_overlay = MeshInstance3D.new()
		_veg_detect_overlay.name = "VegDetectPreview"
		_veg_detect_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.render_priority = 5
		_veg_detect_overlay.material_override = mat
		terrain.add_child(_veg_detect_overlay)
	var origin: Vector2 = mask["origin"]
	var cell := float(mask["cell"])
	var size := Vector2(float(mask["w"]), float(mask["h"])) * cell
	var segs_x := clampi(int(size.x / 4.0), 2, 96)
	var segs_z := clampi(int(size.y / 4.0), 2, 96)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in segs_z:
		for ix in segs_x:
			var quad: Array = []
			for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]:
				var u := float(ix + (c as Vector2i).x) / float(segs_x)
				var v := float(iz + (c as Vector2i).y) / float(segs_z)
				var wx := origin.x + u * size.x
				var wz := origin.y + v * size.y
				quad.append([Vector3(wx, _ground_height_at(wx, wz) + 0.25, wz), Vector2(u, v)])
			for t in [0, 1, 2, 0, 2, 3]:
				st.set_uv(quad[t][1])
				st.add_vertex(quad[t][0])
	_veg_detect_overlay.mesh = st.commit()
	(_veg_detect_overlay.material_override as StandardMaterial3D).albedo_texture = \
		ImageTexture.create_from_image(img)
	_veg_detect_overlay.visible = true


func clear_veg_detect_preview() -> void:
	if _veg_detect_overlay != null and is_instance_valid(_veg_detect_overlay):
		_veg_detect_overlay.visible = false


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
		_veg_highlight = _make_highlight_mesh(terrain, "VegetationSelectionHighlight")
	_draw_highlight_mesh(_veg_highlight, poly, color, fast_preview)


## Shared drape-and-draw for the ground outline meshes. Both the paint
## selection and the OSM area focus use it, but they own SEPARATE meshes —
## sharing one was a live bug: aiming at an area cleared the paint highlight
## mid-drag, and painting erased the focus outline the prompt was referring to.
func _make_highlight_mesh(terrain: Node, node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	terrain.add_child(mi)
	return mi


func _draw_highlight_mesh(mi: MeshInstance3D, poly: PackedVector2Array,
		color: Color, fast_preview: bool) -> void:
	if mi == null:
		return
	var hl_mat := mi.material_override as StandardMaterial3D
	if hl_mat != null:
		hl_mat.albedo_color = color
	var footing := _highlight_footing_grid(fast_preview)
	mi.mesh = TerrainBuilder.build_polygon_highlight(
		poly, footing["grid"], footing["res"], footing["extent"], _built_center_elev)
	mi.visible = true


## Crosshair-focused OSM vegetation area outline — its own mesh, independent of
## the paint selection highlight (see _make_highlight_mesh).
func update_veg_area_outline(poly: PackedVector2Array, color: Color) -> void:
	if _main == null or poly.size() < 3:
		clear_veg_area_outline()
		return
	var terrain := _main.get_node_or_null("Terrain")
	if terrain == null:
		return
	if _veg_area_highlight == null or not is_instance_valid(_veg_area_highlight):
		_veg_area_highlight = _make_highlight_mesh(terrain, "VegetationAreaFocusHighlight")
	_draw_highlight_mesh(_veg_area_highlight, poly, color, false)


func clear_veg_area_outline() -> void:
	if _veg_area_highlight != null and is_instance_valid(_veg_area_highlight):
		_veg_area_highlight.visible = false


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


## The unified toolbar gets its own CanvasLayer at the panel band — unlike the
## legacy terrain dock, which sits on bare UILayer (layer 1) and predates the
## UITheme.LAYER_* convention.
func _setup_edit_toolbar() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "EditToolbarLayer"
	layer.layer = UITheme.LAYER_PANEL
	ui_layer.add_child(layer)
	var toolbar := Control.new()
	toolbar.name = "EditToolbarUI"
	toolbar.set_script(EDIT_TOOLBAR_UI_SCRIPT)
	layer.add_child(toolbar)
	toolbar.bind_loader(self)
	_edit_toolbar_ui = toolbar


## The stream (mapped / drawn / traced, never a derived drainage line) within
## `max_m` of a ground point: {valid, id, name, kind, dist_m, seg, tapped}.
## The crosshair's stream rung — aimed at a creek, the player used to get the
## forest polygon it runs through ("Fill forest") and nothing about the water.
## `max_m` is the floor of the pick reach: a CARVED stream reaches to its
## bank tops (half the bed + the bank's run + 1 m), because the crosshair's
## ground point on a creek is the BANK — a ray from eye height into a 0.7 m
## trench lands on the slope, up to ~3.5 m off the centreline on a 3.5 m
## stream — and a click on the bank is a click on the creek. With a flat
## 3 m reach the stream rung lost to the forest polygon round it
## (Mount Vernon's Stream 2, --capture=penstock).
func pick_stream_at_world(x: float, z: float, max_m: float = 3.0) -> Dictionary:
	var wn := water_network()
	if wn == null:
		return {"valid": false}
	var p := Vector2(x, z)
	var best := {"valid": false}
	var best_d := INF
	for f_v in wn.features():
		var f: Dictionary = f_v
		var fid := str(f.get("id", ""))
		if fid.begins_with("dc_"):
			continue
		var sec: Dictionary = f.get("section", {}) if f.get("section", {}) is Dictionary else {}
		var reach := maxf(max_m, 0.5 * float(sec.get("bed_w", 0.0))
				+ float(sec.get("bank_slope", 0.0)) * float(sec.get("depth", 0.0)) + 1.0)
		var near := StreamNetwork.nearest_on_line(f["points"], p)
		var d := float(near.get("dist", INF))
		if d < reach and d < best_d:
			best_d = d
			var tapped := false
			for m in f.get("modes", []):
				if str(m) == WaterFeatureLayer.MODE_PENSTOCK:
					tapped = true
			best = {"valid": true, "id": fid, "name": str(f.get("name", "")),
				"kind": str(f.get("kind", "stream")), "dist_m": d,
				"seg": int(near.get("seg", 0)), "tapped": tapped}
	return best


## Interact on a focused stream: the WATER toolbar on its Edit tool with this
## stream picked (name, section, base flow, span modes, Penstock chip).
func open_water_tools_on(feature_id: String) -> void:
	if _edit_toolbar_ui == null or feature_id.is_empty():
		return
	if _edit_toolbar_ui.has_method("open_with_section"):
		_edit_toolbar_ui.call("open_with_section", "water")
	if _edit_toolbar_ui.has_method("_set_active_tool"):
		_edit_toolbar_ui.call("_set_active_tool", "water_edit")
	var wt: Variant = _edit_toolbar_ui.get("_water_tools")
	if wt != null and wt.has_method("pick_feature"):
		wt.call("pick_feature", feature_id)


func _close_edit_toolbar() -> void:
	if _edit_toolbar_ui != null and _edit_toolbar_ui.has_method("is_panel_open") \
			and bool(_edit_toolbar_ui.call("is_panel_open")):
		_edit_toolbar_ui.call("_exit_mode")


func terrain_pick_ray(screen_pos: Vector2) -> Variant:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _main == null:
		return null
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(_main, cam, screen_pos)
	if hit.is_empty():
		return null
	return hit["position"]


## ---------------------------------------------------------------------------
## Live brush/shape sculpt (terrain_edit_ui). Precision detail-patch layer.
## ---------------------------------------------------------------------------

## True when the detail patch exists — sculpting authors the hi-res detail delta.
func can_sculpt_detail() -> bool:
	return not _detail_surface_grid.is_empty() and _detail_elev_cols >= 2 \
		and _terrain_edits != null


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
	_reseat_actors_after_edit(snap.keys())
	_on_terrain_tiles_changed(snap.keys())


# ---------------------------------------------------------------------------
# High-res sculpt commands (Phase 2 tools call these). Brush stamps run inside a
# stroke session (UI calls begin/end around the drag); one-shot region ops manage
# their own session.
# ---------------------------------------------------------------------------

## Terrain under these edit tiles changed (a committed sculpt, an undo, a
## channel carve). Anything draped on the ground that a tile overlaps is
## re-draped once, debounced — today that is the water surfaces; the
## WaterNetwork also hears it so derived drainage goes stale.
func _on_terrain_tiles_changed(keys: Array) -> void:
	if keys.is_empty():
		return
	var span := TerrainEditTiles.CELL_M * float(TerrainEditTiles.TILE_CELLS)
	var hit := false
	for item in _water_data:
		if not (item is Dictionary):
			continue
		var pts: Variant = (item as Dictionary).get("points", PackedVector2Array())
		if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 2:
			continue
		var r := _poly_bounds(pts as PackedVector2Array)
		for k: Variant in keys:
			if not (k is Vector2i):
				continue
			var kv: Vector2i = k
			if r.grow(2.0).intersects(Rect2(float(kv.x) * span, float(kv.y) * span, span, span)):
				hit = true
				break
		if hit:
			break
	if hit:
		_queue_water_redrape()
	var wn := get_node_or_null("WaterNetwork")
	if wn != null and wn.has_method("on_terrain_tiles_changed"):
		wn.call("on_terrain_tiles_changed", keys)


var _water_redrape_pending := false


## Debounced `_attach_water` — a burst of commits (or a whole-feature carve)
## re-drapes once.
func _queue_water_redrape() -> void:
	if _water_redrape_pending or not is_inside_tree():
		return
	_water_redrape_pending = true
	get_tree().create_timer(0.35).timeout.connect(func() -> void:
		_water_redrape_pending = false
		_attach_water())


func _ensure_edit_tiles() -> void:
	_ensure_tile_stack()
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
## Grade a straight strip from a to b (TerrainSculptOps.ramp): `width_m` flat
## top, `height_m` above (berm) or below (channel) the line between the two
## clicked ground heights, sides at `side_run`:1 down / up to the ground.
func ramp_command(a: Vector3, b: Vector3, width_m: float, height_m: float = 0.0,
		side_run: float = TerrainSculptOps.DEFAULT_RAMP_SIDE_RUN) -> void:
	_ensure_edit_tiles()
	if _edit_tiles == null:
		return
	var ya := ground_height_at(a.x, a.z)
	var yb := ground_height_at(b.x, b.z)
	begin_terrain_tile_edit()
	TerrainSculptOps.ramp(_edit_tiles, Vector2(a.x, a.z), Vector2(b.x, b.z),
		ya, yb, width_m, Callable(self, "_height_field_base"), height_m, side_run)
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
			var tile_snap: Dictionary = (snap as Dictionary)["tiles"]
			_edit_tiles.apply_snapshot(tile_snap)
			_edit_tiles.prune_flat_tiles()
			if _height_field != null:
				_height_field.reconcile_dirty_now()
			_refresh_detail_sink()
			_save_edit_tiles()
			_reseat_actors_after_edit(tile_snap.keys())
			_on_terrain_tiles_changed(tile_snap.keys())
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
	return WorldPaths.site_file("earthworks", _lat, _lon)


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
## Basin geometry memos. Everything a pond push needs is a pure function of
## the outline and the ground inside it: the bounds sweep below, and the grid
## of ground samples PondBathymetry integrates volumes over. Both are keyed on
## the outline's hash plus `_basin_ground_fingerprint` (a handful of ground
## queries, re-read on every lookup, so a sculpt edit inside the basin misses
## the memo) and cleared outright on a sculpt commit / undo. Before this a
## pond push re-ran the ~1k-sample sweep three times and a 19-sweep bisection
## per pond every 0.25 s: gv_pond_push averaged 36 ms a frame (215 ms peaks)
## on Mount Vernon with ONE pond — the first-person stall, measured.
var _basin_samples_cache: Dictionary = {}
var _basin_bounds_cache: Dictionary = {}


func _basin_samples_for(poly: PackedVector2Array, cell: float) -> PackedFloat64Array:
	if poly.size() < 3:
		return PackedFloat64Array()
	var key := "%d|%.4f" % [hash(poly), cell]
	var fp := _basin_ground_fingerprint(poly)
	var hit: Variant = _basin_samples_cache.get(key)
	if hit is Dictionary and float((hit as Dictionary).get("fp", NAN)) == fp:
		return (hit as Dictionary)["samples"]
	var samples := PondBathymetry.basin_samples(poly, Callable(self, "ground_height_at"), cell)
	if _basin_samples_cache.size() > 64:
		_basin_samples_cache.clear()
	_basin_samples_cache[key] = {"fp": fp, "samples": samples}
	return samples


## Drop every basin memo (and the stage curves built from them): the ground
## under a pond may have moved. Called from the sculpt commit / undo paths.
func _invalidate_basin_caches() -> void:
	_basin_samples_cache.clear()
	_basin_bounds_cache.clear()
	_stage_curve_cache.clear()


func sample_pond_basin_elevations(poly: PackedVector2Array) -> Dictionary:
	if poly.size() < 3:
		return {"rim_m": 0.0, "floor_m": 0.0}
	var key := "%d" % hash(poly)
	var fp := _basin_ground_fingerprint(poly)
	var hit: Variant = _basin_bounds_cache.get(key)
	if hit is Dictionary and float((hit as Dictionary).get("fp", NAN)) == fp:
		return ((hit as Dictionary)["bounds"] as Dictionary).duplicate()
	var bounds := _sample_pond_basin_elevations_uncached(poly)
	if _basin_bounds_cache.size() > 64:
		_basin_bounds_cache.clear()
	_basin_bounds_cache[key] = {"fp": fp, "bounds": bounds.duplicate()}
	return bounds


func _sample_pond_basin_elevations_uncached(poly: PackedVector2Array) -> Dictionary:
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
	var basin_rim := float(bounds.get("rim_m", floor_y + 1.0))
	# The spill is the basin's natural rim — or the player's max fill level
	# above it (a dam). Everything downstream (capacity, level-for-volume,
	# the graph rim) reads `spill_m`, so the override lands everywhere at once.
	var spill := basin_rim
	var mx := pond_max_level_for_tag(str(rec.get("tag", _water_body_tag(poly))))
	if not is_nan(mx) and mx > basin_rim + 0.005:
		spill = mx
	rec["floor_m"] = floor_y
	rec["basin_rim_m"] = basin_rim
	rec["spill_m"] = spill
	var cell := PondBathymetry.suggested_cell_m(BuildingBuilder.footprint_area_m2(poly))
	var samples := _basin_samples_for(poly, cell)
	var terrain_cap := PondBathymetry.capacity_from_samples(samples, cell, spill,
		PondBathymetry.FREEBOARD_DEFAULT_M)
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
		rec["stock_l"] = PondBathymetry.volume_from_samples(samples, cell, level, spill)
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


func _clear_selection_highlight() -> void:
	_last_selection_rect = Rect2(-99999.0, -99999.0, 0.0, 0.0)
	if _selection_highlight != null:
		_selection_highlight.visible = false


## ---------------------------------------------------------------------------
## Placed props (user GLB + OSM replacement)
## ---------------------------------------------------------------------------

func _should_load_user_map_overlays() -> bool:
	## Inside a WORLD, re-downloading the map (_force_refetch) refreshes only the
	## MAP layers (DEM, imagery, OSM); the world's own props, styles and spaces
	## always load — a fresh start is a NEW world, not a refetch. Without a world
	## (a harness, a direct scene boot) the old "refetch = clean session"
	## behaviour is kept.
	if WorldPaths.has_active_world():
		return true
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
	# Saved fires come back at the right moment of their life; the FireNodes
	# that outlived a rebuild rebind to the new prop nodes on their own.
	call_deferred("_sync_prop_fires")
	
	# Placed lights (J Light Studio) — keyed by this site, so rebuild now
	# that the site is known; they live under Main, not Terrain.
	PlacedLightService.rebuild_all(_main)


func _try_seed_starshade_graph() -> void:
	if _main == null:
		return
	StarShadeGraphSeeder.try_seed_from_main(_main, self)


func _sync_prop_fires() -> void:
	if _main != null:
		FireNode.sync_prop_fires(_main, self)


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
		clear_veg_area_outline()
		return
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array):
		return
	var info := VegAreaPicker.area_info(polys as Array, idx)
	if not bool(info.get("valid", false)):
		clear_veg_area_outline()
		return
	_veg_focus_area = info
	var poly: PackedVector2Array = info.get("points", PackedVector2Array())
	update_veg_area_outline(poly, Color(1.0, 0.75, 0.15, 0.4))


## Interact / O on a focused veg area → the per-area Fill drawer (Phase 7). It
## carries a "Tune look…" button through to open_veg_area_tune for the
## all-of-type edit, which is what this used to do on its own.
func open_veg_area_modal(area_idx: int) -> void:
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array) or area_idx < 0 or area_idx >= (polys as Array).size():
		return
	if _veg_area_fill_ui == null or not is_instance_valid(_veg_area_fill_ui):
		_setup_veg_area_fill_ui()
	if _veg_area_fill_ui != null and _veg_area_fill_ui.has_method("open_for_area"):
		_veg_area_fill_ui.call("open_for_area", area_idx)
		return
	open_veg_area_tune(area_idx)


## Open the Tune look modal seeded to this area's veg type — an ALL-OF-TYPE
## edit (how every wood on the map looks), as distinct from filling this one
## outline.
func open_veg_area_tune(area_idx: int) -> void:
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array) or area_idx < 0 or area_idx >= (polys as Array).size():
		return
	var d: Variant = (polys as Array)[area_idx]
	if not (d is Dictionary):
		return
	var kind := str((d as Dictionary).get("kind", "grass_field"))
	open_vegetation_preview_editor(_preset_for_veg_kind(kind))


## Area header for the Fill drawer (kind label, size, stable tag).
func get_veg_area_info(area_idx: int) -> Dictionary:
	var polys: Variant = _auto_veg_data.get("polygons", [])
	if not (polys is Array):
		return {"valid": false}
	return VegAreaPicker.area_info(polys as Array, area_idx)


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


## Per-area vegetation Fill drawer (Phase 7). Created lazily on first use — an
## area fill is an occasional action, and the drawer costs nothing until then.
func _setup_veg_area_fill_ui() -> void:
	if _main == null:
		return
	var ui_layer := _main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "VegAreaFillLayer"
	layer.layer = 26
	ui_layer.add_child(layer)
	var ui := PanelContainer.new()
	ui.name = "VegAreaFillModal"
	ui.set_script(VEG_AREA_FILL_UI_SCRIPT)
	layer.add_child(ui)
	ui.call("bind_loader", self)
	_veg_area_fill_ui = ui


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
	_save_props_and_share()
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
	_save_props_and_share()
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
	elif str(rec.get("model_id", "")) == PalletRackBuilder.MODEL_ID and _main != null:
		PlacedPropService.remove_pallet_rack_graph(_main, prop_id)
	if not _placed_prop_layer.remove_prop(prop_id):
		return false
	# 2D/3D twin consistency: a graph node bound to this prop is the same object
	# in another view — never leave a dead node behind. No-op for graph-initiated
	# deletes (the node is already gone when this runs).
	if _main != null:
		var sgv := ServiceLocator.graph()
		if sgv != null and sgv.has_method("remove_items_bound_to_prop"):
			sgv.call("remove_items_bound_to_prop", prop_id)
	_save_props_and_share()
	_attach_buildings()
	_rebuild_placed_props()
	return true


func get_prop_record(prop_id: String) -> Dictionary:
	if _placed_prop_layer == null:
		return {}
	return _placed_prop_layer.find_by_id(prop_id)


## PACKED ⇄ DEPLOYED (PACKING_PLAN.md Phase 5): flip a prop's pack state,
## persist, rebuild, and keep the graph honest — a packed linkage array is
## stowed (node + wiring survive, zero contribution), and unpacking restores
## the fold-state truth rather than blindly un-stowing a still-folded frame.
## Linkage structures ANIMATE the transition: packing folds the live frame
## first (the stow sweep IS the packing) and only then swaps in the crate;
## unpacking swaps the crate for the stowed frame and plays the deploy
## sweep — so pack/unpack reads as one continuous motion, never a teleport.
func set_prop_packed(prop_id: String, packed: bool) -> void:
	if _placed_prop_layer == null or prop_id.is_empty():
		return
	if _pack_anim_in_flight.has(prop_id):
		return
	var rec := _placed_prop_layer.find_by_id(prop_id)
	if rec.is_empty():
		return
	if packed and PlacedPropRuntime.packed_spec_for_record(rec).is_empty():
		return  # non-packable — nothing to collapse into
	# You cannot erect a shiftpod inside a shipping container. A stowed crate
	# is riding the stack at height with its collision off; deploying it in
	# place would put the model through the container walls, floating at stack
	# height. The crew hauling it out is what clears `stowed_in`.
	if not packed and not str(rec.get("stowed_in", "")).is_empty():
		var sgv0: Node = ServiceLocator.graph()
		if sgv0 != null and sgv0.has_method("_show_toast"):
			sgv0.call("_show_toast",
				"📦 Stowed in the container — unload the delivery first")
		return
	var main := get_tree().current_scene
	var is_linkage := str(rec.get("model_id", "")) == LinkageStructureBuilder.MODEL_ID
	if packed and is_linkage and main != null:
		var prop := PlacedPropRuntime.find_by_prop_id(main, prop_id)
		var deploy: Node = prop.get_node_or_null("LinkageDeployRuntime") \
			if prop != null else null
		if deploy != null and (bool(deploy.call("is_deployed"))
				or bool(deploy.call("is_animating"))):
			_pack_anim_in_flight[prop_id] = true
			if not bool(deploy.call("is_animating")):
				deploy.call("toggle_deploy")            # start the stow sweep
			elif float(deploy.get("_rate")) > 0.0:
				deploy.call("toggle_deploy")            # reverse a deploy mid-flight
			await deploy.deploy_state_changed
			_pack_anim_in_flight.erase(prop_id)
			if _placed_prop_layer == null or not is_inside_tree():
				return
			# Re-read: the settle persisted the stowed fold pose + graph stow.
			rec = _placed_prop_layer.find_by_id(prop_id)
			if rec.is_empty():
				return
	if not _placed_prop_layer.update_prop(prop_id, {"packed": packed}):
		return
	_save_props_and_share()
	_rebuild_placed_props()
	var sgv: Node = ServiceLocator.graph()
	if is_linkage:
		if sgv != null and sgv.has_method("set_imported_array_stowed"):
			var stowed := packed or not bool(rec.get("linkage_deployed", false))
			sgv.call("set_imported_array_stowed", "linkage_%s" % prop_id, stowed)
	# Any prop bound to a graph item: flag/unflag the twin so every producer
	# gate (renewables/CSP/heliostat ticks, flow-engine processors) sees it.
	var gid := str(rec.get("graph_item_id", ""))
	if not gid.is_empty() and sgv != null and sgv.has_method("set_item_packed_3d"):
		sgv.call("set_item_packed_3d", gid, packed)
	# UNPACKING a linkage: the crate just swapped for the STOWED frame — now
	# play the deploy sweep so it visibly unfolds (its settle re-arms the
	# graph array and persists the deployed pose through the normal path).
	if not packed and is_linkage and main != null:
		await get_tree().process_frame
		var prop2 := PlacedPropRuntime.find_by_prop_id(main, prop_id)
		var deploy2: Node = prop2.get_node_or_null("LinkageDeployRuntime") \
			if prop2 != null else null
		if deploy2 != null and not bool(deploy2.call("is_animating")):
			if bool(deploy2.call("is_deployed")):
				# The crate's DESIGN was saved at the deployed fold (the common
				# case — the Lab shows designs deployed), so from here there is
				# no sweep to play and _settle would never run: linkage_deployed
				# never gets persisted and set_imported_array_stowed(9645) reads
				# `not linkage_deployed` = true — the graph array stays STOWED
				# forever on a visibly standing structure. Snap to the stowed
				# pose and raise from it: the deploy sweep IS the honest visual
				# (and the Site Projects raise), and its settle persists truth.
				var b: Node = prop2.get_node_or_null("ModelRoot")
				if b != null and b.has_method("set_fold_angle"):
					b.call("set_fold_angle", maxf(float(b.call("min_fold_angle")),
						LinkageKinematics.MIN_FOLD_ANGLE))
			deploy2.call("toggle_deploy")


## Spawn an UnpackScenario delivery (container + packed crates) at a world
## position — PACKING_PLAN.md Phase 6. Returns the spawn result (or {}).
func deliver_packed_kit(scenario_id: String, at_x: float, at_z: float,
		yaw_deg: float = 0.0) -> Dictionary:
	if _placed_prop_layer == null:
		return {}
	var main_now := get_tree().current_scene
	var abs_h := float(main_now.call("get_absolute_hours")) \
		if main_now != null and main_now.has_method("get_absolute_hours") else 0.0
	var res := UnpackScenario.spawn(_placed_prop_layer, scenario_id, at_x, at_z,
		yaw_deg, abs_h)
	if res.is_empty():
		return {}
	_save_props_and_share()
	_rebuild_placed_props()
	_queue_unload_chore(res, at_x, at_z)
	return res


## A delivery is WORK: queue ONE HAUL CHORE PER CRATE (target = the crate
## prop, carry_to = its stamped staging slot, effect = the move_prop that
## actually relocates the record on completion) plus a zero-effect "Delivery
## unloaded" gate depending on all of them — the hook later project phases
## (or a player-authored chore) can depend on. Crates spawn stacked at the
## container door (UnpackScenario v2), so the haul is real: the crew streams
## between the door and the staging rows, visibly carrying. Total labour is
## priced by NpcHaulModel over the real route and split per crate. Silent
## no-op with no population — the player just unpacks by hand.
func _queue_unload_chore(spawn_res: Dictionary, cx: float, cz: float) -> void:
	var sgv: Node = ServiceLocator.graph()
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return
	var bridge: Variant = sgv.call("npc_population_bridge")
	if bridge == null:
		return
	var iid := str(bridge.call("first_crewable_habitat"))
	if iid.is_empty():
		return
	var board: Variant = bridge.call("chore_board_for", iid)
	if board == null:
		return
	var crate_ids: Array = spawn_res.get("crate_ids", [])
	if crate_ids.is_empty():
		return
	var from := Vector2(cx, cz)
	var roster := maxi(int(bridge.call("roster_size_for", iid)), 1)
	var crates: Array = []
	for pid in crate_ids:
		var rec := _placed_prop_layer.find_by_id(str(pid))
		var at := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
		var st: Dictionary = rec.get("staging", {})
		var entry := ModelCatalog.find(str(rec.get("model_id", "")))
		# Honest shipping mass + longest dimension drive the TEAM-LIFT crew
		# size per crate (NpcHaulModel.carriers_for via unload_spec_rows).
		var pspec := PlacedPropRuntime.packed_spec_for_record(rec)
		var long_m := maxf(float(pspec.get("w_m", 0.0)),
			maxf(float(pspec.get("d_m", 0.0)), float(pspec.get("h_m", 0.0))))
		crates.append({"pid": str(pid),
			"stage": Vector2(float(st.get("x", at.x)), float(st.get("z", at.y))),
			"rank": int(rec.get("unload_rank", rec.get("delivery_slot", 0))),
			"mass_kg": float(pspec.get("mass_kg", -1.0)),
			"long_m": long_m,
			"label": str(entry.get("label", rec.get("model_id", "crate")))})
	# LIFO. This ONE sort serves both strategies: the brigade's stage effects
	# fire in list order, and the round-trip rows take an ascending priority
	# from it — so nobody pulls a crate out from under the one stacked on it.
	crates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("rank", 0)) < int(b.get("rank", 0)))
	# Strategy + rows are pure (SiteProject.unload_spec_rows): round trips =
	# one carry chore per crate; bucket brigade = ONE crew chore with the
	# crates flowing through as stage effects along the relay line.
	var built: Dictionary = SiteProject.unload_spec_rows(crates, from, roster)
	var rows: Array = built.get("rows", [])
	var centre: Vector2 = built.get("centre", from)
	var project_id := ""
	if bridge.has_method("create_site_project"):
		project_id = str(bridge.call("create_site_project", iid,
			"delivery_unload", "Unload delivery (%s)" % str(built.get("strategy", "")).replace("_", " "),
			str(spawn_res.get("container_prop_id", "")), centre, rows,
			{"start_h": 7.0, "end_h": 19.0},
			{"kind": "pos", "x": centre.x, "z": centre.y}, {}))
	if project_id.is_empty():
		push_warning("Delivery unload plan refused — chore board full")


func is_prop_packed(prop_id: String) -> bool:
	if _placed_prop_layer == null:
		return false
	return bool(_placed_prop_layer.find_by_id(prop_id).get("packed", false))


func update_prop_record(prop_id: String, patch: Dictionary) -> void:
	if _placed_prop_layer == null:
		return
	if not _placed_prop_layer.update_prop(prop_id, patch):
		return
	_save_props_and_share()
	_attach_buildings()
	_rebuild_placed_props()


## --- fire: the burn record rides the prop ------------------------------------
## Written by FireNode (ignition, extinguisher holds, going out) and the prop
## editor (durations). QUIET: no prop rebuild — a rebuild frees every prop
## node, and spraying writes this once a second. The save is debounced.
func set_prop_burn_record(prop_id: String, burn: Dictionary) -> void:
	if _placed_prop_layer == null or prop_id.is_empty():
		return
	if not _placed_prop_layer.update_prop(prop_id, {"burn": burn.duplicate(true)}):
		return
	_schedule_prop_layer_save()


## The player's chosen durations for a fire that has NOT started yet
## ({climb_h, bonfire_h, ember_h}, any subset); {} clears it. FireNode reads
## it over the geometry estimate at ignition. Quiet, like the burn record.
func set_prop_fire_plan(prop_id: String, plan: Dictionary) -> void:
	if _placed_prop_layer == null or prop_id.is_empty():
		return
	var rec := _placed_prop_layer.find_by_id(prop_id)
	if rec.is_empty():
		return
	if plan.is_empty():
		rec.erase("fire_plan")
	else:
		rec["fire_plan"] = plan.duplicate(true)
	_schedule_prop_layer_save()


## A copy of a prop record (already offset by the caller) as a new free prop.
## Returns the new id, "" when the layer is full.
func duplicate_prop_record(copy: Dictionary) -> String:
	if _placed_prop_layer == null or copy.is_empty():
		return ""
	var mid := str(copy.get("model_id", ""))
	var new_id := _placed_prop_layer.add_free_prop(mid, float(copy.get("x", 0.0)),
		float(copy.get("y_offset", 0.0)), float(copy.get("z", 0.0)),
		float(copy.get("yaw", 0.0)), float(copy.get("pitch", 0.0)),
		float(copy.get("roll", 0.0)), float(copy.get("scale", 1.0)))
	if new_id.is_empty():
		return ""
	var patch := copy.duplicate(true)
	for k in ["id", "type", "model_id", "x", "y_offset", "z", "yaw", "pitch", "roll", "scale",
			"y", "ground_y", "building_idx"]:
		patch.erase(k)
	if not patch.is_empty():
		_placed_prop_layer.update_prop(new_id, patch)
	_save_props_and_share()
	_rebuild_placed_props()
	return new_id


## Restore / "forget the fire": the FireNode disposes itself on its next frame.
func clear_prop_burn_record(prop_id: String) -> void:
	if _placed_prop_layer == null or prop_id.is_empty():
		return
	var rec := _placed_prop_layer.find_by_id(prop_id)
	if rec.is_empty() or not rec.has("burn"):
		return
	rec.erase("burn")
	_schedule_prop_layer_save()


var _prop_layer_save_pending := false
## Persist the prop layer AND tell a multiplayer session a person changed it
## (deletes, duplicates, editor commits, pack / unpack used to reach the other
## players only on the 12 s full resync). The session ignores calls made while
## it is applying a change it received, so this cannot echo.
func _save_props_and_share() -> void:
	_placed_prop_layer.save(_lat, _lon)
	PlacedPropService._notify_mp_props_edited()


func _schedule_prop_layer_save() -> void:
	if _prop_layer_save_pending:
		return
	_prop_layer_save_pending = true
	var tree := get_tree()
	if tree == null:
		_flush_prop_layer_save()
		return
	tree.create_timer(1.0).timeout.connect(_flush_prop_layer_save)


func _flush_prop_layer_save() -> void:
	_prop_layer_save_pending = false
	if _placed_prop_layer != null:
		_placed_prop_layer.save(_lat, _lon)


## World save / exit (WorldSession): write anything still waiting on a
## debounce timer — a timer created on the SceneTree dies with a scene change,
## so a pending save would otherwise be lost on "Exit to menu".
func flush_world_state() -> void:
	if not _built:
		return
	if _prop_layer_save_pending:
		_flush_prop_layer_save()


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
	_save_props_and_share()


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
		"water_features": _water_network().layer.serialize() if _water_network() != null else {},
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

	# Streams, OSM overrides and water settings — the carve regenerates from
	# them, so the channel tiles never travel in the package.
	var wf_blob: Dictionary = layers.get("water_features", {}) as Dictionary
	if not wf_blob.is_empty() and _water_network() != null:
		var wn := _water_network()
		wn.layer.deserialize(wf_blob)
		wn.save_layer()
		wn.invalidate_cache()
		applied.append("water_features")

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
		if "user_water" in applied or "water_features" in applied:
			call_deferred("_attach_water")
		if "water_features" in applied:
			_request_water_network_rebuild(true)

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
	var title := "Loading %s" % SitePrivacy.place(_map_label, "map") if not _map_label.is_empty() else "Loading map"
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
		call_deferred("_maybe_schedule_fps_autodrop")


## Phase 4: one-shot performance safety net. If the settled post-load frame
## rate averages under 45 fps, drop the graphics preset ONE level and remember
## having done so (perf_prefs.cfg) — never fight the player more than once.
## Skipped headless and under the playtest harness (frozen-clock captures
## would give meaningless readings and mutate the player's preset).
const _VEG_AUTODROP_FLAG := "veg_auto_dropped"
const _VEG_AUTODROP_MIN_FPS := 45.0


func _maybe_schedule_fps_autodrop() -> void:
	if DisplayServer.get_name() == "headless" or _main == null:
		return
	var ph := get_node_or_null("/root/PlaytestHarness")
	if ph != null and bool(ph.get("_active")):
		return
	var cfg := ConfigFile.new()
	cfg.load(RenderProfile.PERF_PREFS_CFG)
	if bool(cfg.get_value("render", _VEG_AUTODROP_FLAG, false)):
		return
	var q := 2
	if _main.get("graphics_quality") != null:
		q = int(_main.get("graphics_quality"))
	if q <= RenderProfile.QUALITY_LOW:
		return
	# Let the load burst settle, then average real frames for 5 s.
	await get_tree().create_timer(20.0).timeout
	if not _built:
		return
	var sum := 0.0
	var n := 0
	for _i in 5:
		await get_tree().create_timer(1.0).timeout
		if not _built:
			return
		sum += Performance.get_monitor(Performance.TIME_FPS)
		n += 1
	if n == 0 or sum / float(n) >= _VEG_AUTODROP_MIN_FPS:
		return
	var new_q := q - 1
	if _main.has_method("set_graphics_quality_level"):
		_main.call("set_graphics_quality_level", new_q)
	cfg.set_value("render", _VEG_AUTODROP_FLAG, true)
	cfg.save(RenderProfile.PERF_PREFS_CFG)
	_toast("Frame rate under %d fps — graphics preset lowered to %s (Settings → Lighting to change back)." % [
		int(_VEG_AUTODROP_MIN_FPS), RenderProfile.quality_name(new_q)], ToastUI.Level.WARN)
	print("TerrainLoader: FPS auto-drop -> %s (avg %.0f fps)" % [
		RenderProfile.quality_name(new_q), sum / float(n)])


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
