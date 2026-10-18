class_name WaterNetwork
extends Node

## The map's flowing water as ONE system: OSM waterways + the player's streams
## resolved into features (StreamNetwork), their beds profiled and carved into
## the terrain's procedural channel layer (ChannelCarver, on a worker thread),
## and — in later phases — rendered, analysed and wired into the graph.
##
## Owned by TerrainLoader as its child "WaterNetwork". The loader stays the
## authority for the terrain; this node only ever writes the CHANNEL tile layer
## (never the player's sculpt layer) and asks the loader to commit it.
##
## Lifecycle:
##   bind_map(lat, lon)  — loads the feature layer + the channel-tile cache
##   request_rebuild()   — debounced; resolves features, and when anything that
##                         a carve depends on changed, runs a carve job
##   _process            — polls the job, installs its tiles, saves the cache
##
## The carve is deterministic from (features, sections, base ground), so the
## cache (`channel_tiles_<lat>_<lon>.bin` + `.json` sidecar of signatures and
## footprints) is purely a load-time shortcut: delete it and the same channels
## come back.

signal network_rebuilt
signal features_changed
signal drainage_changed
signal display_mode_changed(mode: String)
signal buried_visibility_changed(on: bool)

const DEBOUNCE_S := 0.4
const CACHE_VERSION := 1
const STREAM_SHADER := preload("res://core/water/stream_water.gdshader")
## How often (real seconds) the discharge is re-read off the clock + weather.
const HYDRAULICS_POLL_S := 1.5
## Re-mesh the surfaces when any feature's flow moved by more than this share.
const REMESH_Q_CHANGE := 0.12
const STREAMS_NODE := "WaterStreams"
const BURIED_NODE := "WaterBuried"
const MOUTHS_NODE := "WaterCulvertMouths"
const COL_SURCHARGED := Color(1.0, 0.25, 0.2)
const DRAINAGE_NODE := "WaterDrainage"
const DRAINAGE_SHADER := preload("res://core/water/drainage_overlay.gdshader")
## Drainage grid cell (m). 5 m over the 3 km hi-res patch = 600² cells, the
## FlowRouting cap; the DEM itself is ~6 m there, so finer buys nothing.
const DRAIN_CELL_M := 5.0
## Re-analyse this long after the last terrain edit / carve.
const DRAIN_DEBOUNCE_S := 2.0
## A derived channel is "already mapped" when this share of its points lies
## within DUP_DIST_M of a feature line.
const DUP_SHARE := 0.6
const DUP_DIST_M := 12.0

## Testing / harness override of the rain rate (mm/h); < 0 = live weather.
var rain_override_mmh := -1.0
## Catchment area (m²) draining to each profile station, per feature id
## (PackedFloat32Array, one per station) — filled by the drainage analysis;
## absent = base flow only.
var station_area: Dictionary = {}

var loader: Node = null
var layer := WaterFeatureLayer.new()

var _lat := 0.0
var _lon := 0.0
var _bound := false
var _features: Array = []
var _by_id: Dictionary = {}
var _profiles: Dictionary = {}
var _links: Dictionary = {}
var _sigs: Dictionary = {}
var _footprints: Dictionary = {}
var _inputs_sig := 0

var _rebuild_pending := false
var _rebuild_force := false
var _debounce_t := 0.0
var _task_id := -1
var _task_box: Dictionary = {}
var _task_force := false
var _task_started_ms := 0

var _drain: Dictionary = {}
var _derived: Array = []
var _drain_task := -1
var _drain_box: Dictionary = {}
var _drain_pending := false
var _drain_reextract_only := false
var _drain_t := 0.0
var _drain_started_ms := 0
var _drain_mi: MeshInstance3D = null
var _drain_mat: ShaderMaterial = null

var _buried_root: Node3D = null
var _mouths_root: Node3D = null
var _runs: Dictionary = {}          # feature id -> Array of BuriedWaterBuilder runs
var _outlet_vfx: Array = []         # [{vfx, fid, run}]
var _preview_visible := false
var _headwall_mat: StandardMaterial3D = null

var _tracers: StreamTracers = null
var _flow_chip: Label = null

var _streams_mi: MeshInstance3D = null
var _streams_mat: ShaderMaterial = null
var _hyd_t := 0.0
var _last_rain := -1.0
var _last_q: Dictionary = {}      # feature id -> representative Q (L/s) last meshed
var _states: Dictionary = {}      # feature id -> Array of station states

## Layer-snapshot undo for water edits (a carve is regenerated from the layer,
## so restoring the layer IS restoring the terrain channel).
var _undo: Array = []
var _redo: Array = []
const UNDO_DEPTH := 30


func _ready() -> void:
	set_process(true)


## A carve or drainage job may still be running on a worker thread when the
## map unloads or the game quits; tearing the tree down under it crashed at
## exit. Wait for both before this node goes.
func _exit_tree() -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	if _drain_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_drain_task)
		_drain_task = -1


func bind_map(lat: float, lon: float) -> void:
	_lat = lat
	_lon = lon
	_bound = true
	layer = WaterFeatureLayer.new()
	layer.load_from(WaterFeatureLayer.save_path_for_map(lat, lon))
	_undo.clear()
	_redo.clear()
	_sigs = {}
	_footprints = {}
	_inputs_sig = 0


func layer_path() -> String:
	return WaterFeatureLayer.save_path_for_map(_lat, _lon)


func save_layer() -> void:
	if _bound:
		layer.save_to(layer_path())


# ---------------------------------------------------------------------------
# Channel-tile cache
# ---------------------------------------------------------------------------

func _cache_paths() -> Array:
	return [WorldPaths.site_file("channel_tiles", _lat, _lon, "bin"),
		WorldPaths.site_file("channel_tiles", _lat, _lon, "json")]


## Load the cached channel tiles straight into the loader's channel layer (call
## BEFORE the HeightField's first rebuild so a returning site renders its
## channels from frame one). Restores the signatures so the first carve job is
## incremental (usually touching nothing).
func load_cache_into(channel: TerrainEditTiles) -> bool:
	if not _bound or channel == null:
		return false
	var paths := _cache_paths()
	if not FileAccess.file_exists(paths[0]) or not FileAccess.file_exists(paths[1]):
		return false
	var f := FileAccess.open(paths[1], FileAccess.READ)
	if f == null:
		return false
	var meta: Variant = JSON.parse_string(f.get_as_text())
	if not (meta is Dictionary) or int((meta as Dictionary).get("version", 0)) != CACHE_VERSION:
		return false
	if not channel.load_from_file(paths[0]):
		return false
	_sigs = {}
	for k in ((meta as Dictionary).get("sigs", {}) as Dictionary).keys():
		_sigs[str(k)] = int(meta["sigs"][k])
	_footprints = {}
	var fps: Dictionary = (meta as Dictionary).get("footprints", {})
	for k in fps.keys():
		var keys: Array = []
		for pair in fps[k]:
			if pair is Array and (pair as Array).size() == 2:
				keys.append(Vector2i(int(pair[0]), int(pair[1])))
		_footprints[str(k)] = keys
	return true


func _save_cache(channel: TerrainEditTiles) -> void:
	if not _bound or channel == null:
		return
	var paths := _cache_paths()
	channel.save_to_file(paths[0])
	var fps := {}
	for k in _footprints.keys():
		var arr: Array = []
		for key in _footprints[k]:
			var v: Vector2i = key
			arr.append([v.x, v.y])
		fps[k] = arr
	var f := FileAccess.open(paths[1], FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"version": CACHE_VERSION, "sigs": _sigs, "footprints": fps}))


## Forget the cache (and the carve) — the next rebuild re-carves everything.
func invalidate_cache() -> void:
	for p in _cache_paths():
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	_sigs = {}
	_footprints = {}
	_inputs_sig = 0


# ---------------------------------------------------------------------------
# Rebuild
# ---------------------------------------------------------------------------

## Ask for a re-resolve + (incremental) re-carve. Debounced; `force` ignores
## the input signature and re-rasterises every footprint.
func request_rebuild(force: bool = false) -> void:
	_rebuild_pending = true
	_rebuild_force = _rebuild_force or force
	_debounce_t = DEBOUNCE_S


func _process(delta: float) -> void:
	_hyd_t -= delta
	if _hyd_t <= 0.0 and _task_id < 0:
		_hyd_t = HYDRAULICS_POLL_S
		_poll_hydraulics()
	_process_drainage(delta)
	_drive_outlet_vfx(delta)
	if _task_id >= 0:
		if WorkerThreadPool.is_task_completed(_task_id):
			WorkerThreadPool.wait_for_task_completion(_task_id)
			_task_id = -1
			_apply_job_result(_task_box.get("result", {}))
			_task_box = {}
		return
	if _rebuild_pending:
		_debounce_t -= delta
		if _debounce_t <= 0.0:
			_rebuild_pending = false
			var force := _rebuild_force
			_rebuild_force = false
			_start_rebuild(force)


func is_busy() -> bool:
	return _task_id >= 0 or _rebuild_pending


func _start_rebuild(force: bool) -> void:
	if loader == null or not is_instance_valid(loader) or not _bound:
		return
	var osm_water: Array = loader.call("osm_water_items") if loader.has_method("osm_water_items") else []
	_features = StreamNetwork.resolve(osm_water, layer)
	_by_id = {}
	for f in _features:
		_by_id[(f as Dictionary)["id"]] = f
	_rev += 1
	features_changed.emit()
	var sampler: WaterGroundSampler = loader.call("make_water_ground_sampler") \
		if loader.has_method("make_water_ground_sampler") else null
	if sampler == null:
		return
	var carve_on := bool(layer.setting("carve_enabled"))
	var in_sig := hash([_features, carve_on, sampler.coarse.size(), sampler.detail.size(),
		sampler.center_elev, sampler.detail_extent_m, _grid_probe(sampler)])
	if not force and in_sig == _inputs_sig and not _sigs.is_empty():
		# Nothing a carve depends on moved; the surfaces may still need a
		# re-drape (water toggled, a sculpt under an uncarved reach).
		rebuild_surfaces()
		return
	_inputs_sig = in_sig
	var job := {
		"features": _features.duplicate(true),
		"sampler": sampler,
		"carve_enabled": carve_on,
		"prev_sigs": _sigs.duplicate(),
		"prev_footprints": _footprints.duplicate(true),
		"force_all": force,
	}
	var box := {}
	_task_box = box
	_task_force = force
	_task_started_ms = Time.get_ticks_msec()
	_task_id = WorkerThreadPool.add_task(func() -> void:
		box["result"] = ChannelCarver.run(job), false, "WaterNetwork carve")


## Set by commit(): the next carve result clears vegetation on the channels
## a player edit changed (never a load-time carve).
var _clear_veg_after_carve := false

## Half-width of the ground a channel takes beyond its bank top: the bank's
## soft lip plus the strip the carver rounds (ChannelCarver.TOE_ROUND_M-ish).
const VEG_CLEAR_MARGIN_M := 1.0


## A player-drawn (or edited) stream now cuts through the forest: a tree
## standing in the new channel used to stay, rooted in mid-air over the bed.
## Every feature whose carve signature moved since the previous result gets
## the vegetation inside its channel footprint (bank top to bank top, plus a
## margin) cleared the way a Level pad clears it — the painted layer's records
## removed and a persisted clear patch on the auto-vegetation edits, so the
## forest never grows back into the water on the next scatter.
func _clear_vegetation_on_changed_channels(prev_sigs: Dictionary) -> void:
	if loader == null or not loader.has_method("clear_vegetation_in_polygon"):
		return
	for f_v in _features:
		var f: Dictionary = f_v
		var fid := str(f.get("id", ""))
		if not bool(f.get("carve", true)):
			continue
		if prev_sigs.has(fid) and int(prev_sigs[fid]) == int(_sigs.get(fid, -1)):
			continue   # unchanged by this edit
		var pts: PackedVector2Array = f.get("points", PackedVector2Array())
		if pts.size() < 2:
			continue
		var sec: Dictionary = f.get("section", {})
		var half := 0.5 * float(sec.get("bed_w", 3.5)) 				+ float(sec.get("bank_slope", 2.5)) * float(sec.get("depth", 0.7)) + VEG_CLEAR_MARGIN_M
		var poly := channel_footprint_polygon(pts, half)
		if poly.size() < 3:
			continue
		# The painted layer's clear rebuilds the whole vegetation set, so only
		# pay it when a painted plant actually stands in the channel; the
		# auto-vegetation clear is a persisted patch (cheap) and always lands,
		# so the next scatter keeps out of the water too.
		var painted := int(loader.call("count_manual_bulk_in_polygon", poly)) 				if loader.has_method("count_manual_bulk_in_polygon") else 1
		if painted > 0:
			loader.call("clear_vegetation_in_polygon", poly)
		var auto_n := 0
		if loader.has_method("clear_auto_vegetation_in_polygon"):
			auto_n = int(loader.call("clear_auto_vegetation_in_polygon", poly))
		print("WaterNetwork: cleared vegetation along %s (%.1f m half-width, %d points): %d painted, %d auto" % [
			fid, half, pts.size(), painted, auto_n])


## The ground a channel occupies: the centreline offset `half` m to each side
## (mitred at the joints, capped so a hairpin cannot throw a vertex out), the
## left bank forward and the right bank back, as one closed outline. Pure.
static func channel_footprint_polygon(pts: PackedVector2Array, half: float) -> PackedVector2Array:
	var n := pts.size()
	var out := PackedVector2Array()
	if n < 2 or half <= 0.0:
		return out
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in n:
		var d_in := (pts[i] - pts[i - 1]).normalized() if i > 0 else Vector2.ZERO
		var d_out := (pts[i + 1] - pts[i]).normalized() if i < n - 1 else Vector2.ZERO
		var d := d_in + d_out
		if d.length_squared() < 1e-9:
			d = d_in if d_in.length_squared() > 0.0 else d_out
		if d.length_squared() < 1e-9:
			continue
		d = d.normalized()
		var nrm := Vector2(-d.y, d.x)
		# Mitre: widen at a bend so the offset stays `half` off BOTH legs, but
		# never past 2 × half (a hairpin's mitre runs to infinity).
		var m := 1.0
		if i > 0 and i < n - 1:
			var cos_half := nrm.dot(Vector2(-d_in.y, d_in.x))
			m = clampf(1.0 / maxf(cos_half, 0.5), 1.0, 2.0)
		left.append(pts[i] + nrm * half * m)
		right.append(pts[i] - nrm * half * m)
	for p in left:
		out.append(p)
	for i in range(right.size() - 1, -1, -1):
		out.append(right[i])
	return out


## Cheap fingerprint of the ground the sampler sees (a few samples): the
## detail DEM landing changes this, so the carve follows a better DEM.
static func _grid_probe(s: WaterGroundSampler) -> Array:
	var out: Array = []
	for p in [Vector2(0, 0), Vector2(311, -127), Vector2(-523, 401), Vector2(907, 913)]:
		out.append(snappedf(s.base_at(p.x, p.y), 0.01))
	return out


func _apply_job_result(res: Dictionary) -> void:
	if res.is_empty() or loader == null or not is_instance_valid(loader):
		return
	_profiles = res.get("profiles", {})
	_links = res.get("links", {})
	var prev_sigs: Dictionary = _sigs
	_sigs = res.get("sigs", {})
	_footprints = res.get("footprints", {})
	if _clear_veg_after_carve:
		_clear_veg_after_carve = false
		_clear_vegetation_on_changed_channels(prev_sigs)
	var touched: Array = res.get("touched", [])
	print("WaterNetwork: %d features, %d channel tiles re-carved (%d ms)" % [
		_features.size(), touched.size(), Time.get_ticks_msec() - _task_started_ms])
	var channel: TerrainEditTiles = loader.call("channel_tile_layer")
	if not touched.is_empty() and channel != null:
		var tiles: Dictionary = res.get("tiles", {})
		for k in touched:
			channel.set_tile_data(k, tiles.get(k, PackedFloat32Array()))
		loader.call("commit_channel_tiles", touched)
		_save_cache(channel)
		if loader.has_method("on_channels_carved"):
			loader.call("on_channels_carved", touched)
	elif channel != null and _task_force:
		_save_cache(channel)
	# New/moved features get catchment areas off the current grid at once; the
	# debounced re-analysis below refines them once the new channel is in it.
	_update_station_areas()
	_rev += 1
	rebuild_surfaces()
	network_rebuilt.emit()
	if not touched.is_empty() or _drain.is_empty() or _task_force:
		request_drainage()


# ---------------------------------------------------------------------------
# Hydraulics + surfaces
# ---------------------------------------------------------------------------

## Rain at the clock's instant (mm/h) — the same WeatherService sample the
## resource-flow engine's catchments use, so the streams and the graph agree.
func rain_mmh_now() -> float:
	if rain_override_mmh >= 0.0:
		return rain_override_mmh
	var main: Node = loader.get("_main") if loader != null else null
	if main == null:
		return 0.0
	var ws := get_node_or_null("/root/WeatherService")
	if ws == null or not ws.has_method("rain_rate_mmh"):
		return 0.0
	var lat := float(main.get("latitude")) if main.get("latitude") != null else 0.0
	var lon := float(main.get("longitude")) if main.get("longitude") != null else 0.0
	if ws.has_method("covers") and not bool(ws.call("covers", lat, lon)):
		return 0.0
	return float(ws.call("rain_rate_mmh", int(main.get("month")), int(main.get("day")),
		float(main.get("day_time"))))


## Discharge (L/s) at station i of a feature: its base flow plus rain runoff
## from whatever drains to that station.
func station_q_lps(f: Dictionary, i: int, rain_mmh: float) -> float:
	var area := 0.0
	var arr: Variant = station_area.get(f["id"], null)
	if arr is PackedFloat32Array and (arr as PackedFloat32Array).size() > 0:
		area = (arr as PackedFloat32Array)[clampi(i, 0, (arr as PackedFloat32Array).size() - 1)]
	return StreamHydraulics.discharge_lps(float(f.get("base_lps", 0.0)), area, rain_mmh)


## Per-station hydraulic state of one feature at a rain rate.
func feature_states(f: Dictionary, rain_mmh: float) -> Array:
	var prof: Dictionary = _profiles.get(f["id"], {})
	var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
	var bed: PackedFloat32Array = prof.get("bed", PackedFloat32Array())
	var sec: Dictionary = f["section"]
	var b := float(sec.get("bed_w", 2.0))
	var z := float(sec.get("bank_slope", 1.5))
	var out: Array = []
	for i in s.size():
		var slope := ChannelProfile._slope(s, bed, i)
		out.append(StreamHydraulics.state(station_q_lps(f, i, rain_mmh), b, z, slope))
	return out


## Which stations sit in a carved channel (same rule ChannelCarver applies).
func _carved_flags(f: Dictionary, prof: Dictionary, sampler_half: float) -> PackedByteArray:
	var pts: PackedVector2Array = prof.get("points", PackedVector2Array())
	var out := PackedByteArray()
	out.resize(pts.size())
	if not bool(layer.setting("carve_enabled")) or not bool(f.get("carve", true)):
		return out
	var half := sampler_half - ChannelCarver.PATCH_MARGIN_M
	for i in pts.size():
		if maxf(absf(pts[i].x), absf(pts[i].y)) <= half:
			out[i] = 1
	return out


func _display_allows(f: Dictionary) -> bool:
	var mode := str(layer.setting("display_mode"))
	if mode == "off":
		return false
	if mode == "osm":
		return str(f.get("source", "")) == "osm"
	return true


func _poll_hydraulics() -> void:
	if _features.is_empty() or _profiles.is_empty():
		return
	var rain := rain_mmh_now()
	if absf(rain - _last_rain) < 0.05 and not _last_q.is_empty():
		return
	var moved := false
	for f in _features:
		var n_st := (_profiles.get(f["id"], {}).get("s", PackedFloat32Array()) as PackedFloat32Array).size()
		var q := station_q_lps(f, maxi(n_st - 1, 0), rain)
		var prev := float(_last_q.get(f["id"], -1.0))
		if prev < 0.0 or absf(q - prev) > REMESH_Q_CHANGE * maxf(prev, 1.0):
			moved = true
			break
	_last_rain = rain
	if moved:
		rebuild_surfaces()
	elif _flow_chip != null and is_instance_valid(_flow_chip) and _flow_chip.visible:
		_update_flow_chip()


## (Re)mesh every visible feature's water surface at the current flow.
func rebuild_surfaces() -> void:
	if loader == null or not is_instance_valid(loader):
		return
	var terrain := _terrain_node()
	if terrain == null:
		return
	var show := bool(loader.call("water_visible")) if loader.has_method("water_visible") else true
	var rain := rain_mmh_now()
	_last_rain = rain
	var half := 0.0
	var sampler: WaterGroundSampler = loader.call("make_water_ground_sampler") \
		if loader.has_method("make_water_ground_sampler") else null
	if sampler != null:
		half = sampler.detail_half()
	var items: Array = []
	_states = {}
	_last_q = {}
	for f in _features:
		var prof: Dictionary = _profiles.get(f["id"], {})
		if prof.is_empty():
			continue
		var states := feature_states(f, rain)
		_states[f["id"]] = states
		if not states.is_empty():
			_last_q[f["id"]] = float((states.back() as Dictionary).get("q_lps", 0.0))
		if bool(f.get("covered", false)) or not _display_allows(f):
			continue
		items.append({"feature": f, "profile": prof, "states": states,
			"carved": _carved_flags(f, prof, half)})
	var mesh: ArrayMesh = null
	if show and not items.is_empty():
		mesh = StreamMeshBuilder.build(items, Callable(loader, "ground_height_at"))
	rebuild_buried()
	_rebuild_flow_view(items)
	if mesh == null:
		if _streams_mi != null and is_instance_valid(_streams_mi):
			_streams_mi.queue_free()
		_streams_mi = null
		return
	if _streams_mi == null or not is_instance_valid(_streams_mi):
		_streams_mi = MeshInstance3D.new()
		_streams_mi.name = STREAMS_NODE
		_streams_mi.layers = WaterBuilder.WATER_RENDER_LAYER
		_streams_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _streams_mat == null:
			_streams_mat = ShaderMaterial.new()
			_streams_mat.shader = STREAM_SHADER
		_streams_mi.material_override = _streams_mat
		terrain.add_child(_streams_mi)
	_streams_mi.mesh = mesh


func streams_material() -> ShaderMaterial:
	return _streams_mat


# ---------------------------------------------------------------------------
# Flow view (display mode "flow"): beads at Manning speed + the drainage
# overlay + a site-outflow chip
# ---------------------------------------------------------------------------

func _rebuild_flow_view(items: Array) -> void:
	var on := str(layer.setting("display_mode")) == "flow"
	var terrain := _terrain_node()
	if not on or terrain == null:
		if _tracers != null and is_instance_valid(_tracers):
			_tracers.queue_free()
		_tracers = null
		if _flow_chip != null and is_instance_valid(_flow_chip):
			_flow_chip.visible = false
		return
	if _tracers == null or not is_instance_valid(_tracers):
		_tracers = StreamTracers.new()
		terrain.add_child(_tracers)
	var main: Node = loader.get("_main")
	var beads: Array = []
	for it_v in items:
		var it: Dictionary = it_v
		var f: Dictionary = it["feature"]
		var prof: Dictionary = it["profile"]
		var states: Array = it["states"]
		var carved: PackedByteArray = it["carved"]
		var pts: PackedVector2Array = prof["points"]
		var bed: PackedFloat32Array = prof["bed"]
		var lev := PackedFloat32Array()
		lev.resize(pts.size())
		var vsum := 0.0
		for i in pts.size():
			var st: Dictionary = states[i]
			vsum += float(st.get("velocity_ms", 0.0))
			if i < carved.size() and carved[i] == 1:
				lev[i] = bed[i] + maxf(float(st.get("depth_m", 0.0)), StreamMeshBuilder.MIN_RENDER_DEPTH_M)
			else:
				lev[i] = float(loader.call("ground_height_at", pts[i].x, pts[i].y)) + StreamMeshBuilder.DRAPE_LIFT_M
		beads.append({"id": f["id"], "points": pts, "s": prof["s"], "level": lev,
			"velocity_ms": vsum / float(maxi(pts.size(), 1)),
			"q_lps": float((states.back() as Dictionary).get("q_lps", 0.0)) if not states.is_empty() else 0.0})
	_tracers.set_streams(beads, main)
	if _drain_mat != null:
		_drain_mat.set_shader_parameter("dash_speed_ms", 1.5 + 0.25 * _last_rain)
	_ensure_flow_chip()
	_update_flow_chip()


func _ensure_flow_chip() -> void:
	if _flow_chip != null and is_instance_valid(_flow_chip):
		_flow_chip.visible = true
		return
	var main: Node = loader.get("_main")
	var ui: Node = main.get_node_or_null("UILayer") if main != null else null
	if ui == null:
		return
	_flow_chip = Label.new()
	_flow_chip.name = "WaterFlowChip"
	_flow_chip.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_flow_chip.add_theme_color_override("font_color", Color(0.75, 0.95, 1.0))
	_flow_chip.add_theme_stylebox_override("normal", UITheme.chip_style(Color(0.2, 0.5, 0.8)))
	_flow_chip.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_flow_chip.offset_top = 96.0
	_flow_chip.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_flow_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_flow_chip)


## Total discharge leaving the site: every outlet stream (one that drains into
## no other feature), read at its last station.
func site_outflow_lps() -> float:
	var total := 0.0
	for f in _features:
		var id: String = (f as Dictionary)["id"]
		if _links.has(id):
			continue
		var states: Array = _states.get(id, [])
		if not states.is_empty():
			total += float((states.back() as Dictionary).get("q_lps", 0.0))
	return total


func _update_flow_chip() -> void:
	if _flow_chip == null or not is_instance_valid(_flow_chip):
		return
	var q := site_outflow_lps()
	var qs := ("%.2f m³/s" % (q / 1000.0)) if q >= 1000.0 else ("%.0f L/s" % q)
	_flow_chip.text = "  Flow view · site outflow %s · rain %.1f mm/h  " % [qs, _last_rain]


func _terrain_node() -> Node3D:
	var main: Node = loader.get("_main") if loader != null else null
	return main.get_node_or_null("Terrain") as Node3D if main != null else null


## Hydraulic state at the station nearest a world point on a feature (for the
## cursor readout): {q_lps, depth_m, top_w_m, velocity_ms, froude, s, bed, blocked}.
func state_near(id: String, p: Vector2) -> Dictionary:
	var f := feature(id)
	var prof := profile(id)
	if f.is_empty() or prof.is_empty():
		return {}
	var hit := StreamNetwork.nearest_on_line(prof["points"], p)
	var s_at := float(hit["s"])
	var s: PackedFloat32Array = prof["s"]
	var i := ChannelProfile.station_index(prof, s_at)
	var states: Array = _states.get(id, [])
	var out: Dictionary = (states[i] as Dictionary).duplicate() if i < states.size() else {}
	out["s"] = s_at
	out["bed"] = ChannelProfile.bed_at(prof, s_at).x
	var blocked: PackedByteArray = prof.get("blocked", PackedByteArray())
	out["blocked"] = i < blocked.size() and blocked[i] == 1
	for run_v in _runs.get(id, []):
		var run: Dictionary = run_v
		if i >= int(run["i0"]) and i <= int(run["i1"]):
			out["run"] = run
			break
	return out


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func features() -> Array:
	return _features


# ---------------------------------------------------------------------------
# Graph link (Phase 9): stream intakes and ponds
# ---------------------------------------------------------------------------

var _rev := 0
var _supply_cache: Dictionary = {}
var _supply_cache_rev := -1
var _pond_ends: Array = []
var _pond_ends_rev := -1


## The stream a point stands in (within `max_dist` m of its line), with its
## discharge there at `rain_mmh`: {feature_id, name, q_lps, area_m2, base_lps}
## or {} when the point is not in any stream. Cached per network revision.
func feature_supply_at(p: Vector2, rain_mmh: float, max_dist: float = 6.0) -> Dictionary:
	if _supply_cache_rev != _rev:
		_supply_cache = {}
		_supply_cache_rev = _rev
	var key := Vector2i(roundi(p.x * 2.0), roundi(p.y * 2.0))
	var hit: Dictionary
	if _supply_cache.has(key):
		hit = _supply_cache[key]
	else:
		hit = {}
		var best := max_dist
		for f_v in _features:
			var f: Dictionary = f_v
			var near := StreamNetwork.nearest_on_line(f["points"], p)
			if float(near["dist"]) < best:
				best = float(near["dist"])
				var prof: Dictionary = _profiles.get(f["id"], {})
				hit = {"fid": f["id"], "i": ChannelProfile.station_index(prof, float(near["s"]))
					if not prof.is_empty() else 0}
		_supply_cache[key] = hit
	if hit.is_empty():
		return {}
	var f2 := feature(str(hit["fid"]))
	if f2.is_empty():
		return {}
	var i := int(hit["i"])
	var area := 0.0
	var arr: Variant = station_area.get(f2["id"], null)
	if arr is PackedFloat32Array and (arr as PackedFloat32Array).size() > 0:
		area = (arr as PackedFloat32Array)[clampi(i, 0, (arr as PackedFloat32Array).size() - 1)]
	return {"feature_id": f2["id"], "name": str(f2.get("name", "")),
		"q_lps": station_q_lps(f2, i, rain_mmh), "area_m2": area,
		"base_lps": float(f2.get("base_lps", 0.0))}


## Discharge of ONE named feature at the station nearest `p` — for an intake
## the player BOUND to a stream (the Penstock span tool). No distance cap: a
## carved bank or a nudged prop must not silently unbind the tap. {} when the
## feature is gone (deleted / hidden), so the caller falls back to proximity.
func feature_supply_on(fid: String, p: Vector2, rain_mmh: float) -> Dictionary:
	var f := feature(fid)
	if f.is_empty():
		return {}
	var prof: Dictionary = _profiles.get(fid, {})
	var near := StreamNetwork.nearest_on_line(f["points"], p)
	var i := ChannelProfile.station_index(prof, float(near["s"])) if not prof.is_empty() else 0
	var area := 0.0
	var arr: Variant = station_area.get(fid, null)
	if arr is PackedFloat32Array and (arr as PackedFloat32Array).size() > 0:
		area = (arr as PackedFloat32Array)[clampi(i, 0, (arr as PackedFloat32Array).size() - 1)]
	return {"feature_id": fid, "name": str(f.get("name", "")),
		"q_lps": station_q_lps(f, i, rain_mmh), "area_m2": area,
		"base_lps": float(f.get("base_lps", 0.0)), "station": i}


## Streams whose downstream end lies in a pond that is on the graph:
## Array of {feature_id, tag, pond_id, q_lps}. The end→pond mapping is cached
## per revision (a polygon scan); the discharge is read at `rain_mmh`.
func pond_inflows(rain_mmh: float) -> Array:
	if _pond_ends_rev != _rev:
		_pond_ends_rev = _rev
		_pond_ends = []
		if loader != null and loader.has_method("pick_water_at_world"):
			var water: Array = loader.get("_water_data")
			for f_v in _features:
				var f: Dictionary = f_v
				if _links.has(f["id"]):
					continue
				var pts: PackedVector2Array = f["points"]
				var end := pts[pts.size() - 1]
				var w: Dictionary = loader.call("pick_water_at_world", end.x, end.y)
				if not bool(w.get("valid", false)) or not bool(w.get("added", false)):
					continue
				var idx := int(w.get("water_idx", -1))
				var pid := ""
				if idx >= 0 and idx < water.size() and water[idx] is Dictionary:
					pid = str((water[idx] as Dictionary).get("pond_id", ""))
				_pond_ends.append({"feature_id": f["id"], "tag": str(w.get("tag", "")), "pond_id": pid})
	var out: Array = []
	for e_v in _pond_ends:
		var e: Dictionary = e_v
		var f3 := feature(str(e["feature_id"]))
		if f3.is_empty():
			continue
		var n := (_profiles.get(f3["id"], {}).get("s", PackedFloat32Array()) as PackedFloat32Array).size()
		var o := e.duplicate()
		o["q_lps"] = station_q_lps(f3, maxi(n - 1, 0), rain_mmh)
		var arr: Variant = station_area.get(f3["id"], null)
		if arr is PackedFloat32Array and (arr as PackedFloat32Array).size() > 0:
			o["area_m2"] = (arr as PackedFloat32Array)[(arr as PackedFloat32Array).size() - 1]
		out.append(o)
	return out


func feature(id: String) -> Dictionary:
	return _by_id.get(id, {})


func profile(id: String) -> Dictionary:
	return _profiles.get(id, {})


func links() -> Dictionary:
	return _links


## The terrain changed under some tiles (a player sculpt). Carved beds are
## relative to the BASE ground, so the carve itself does not move; derived
## drainage (Phase 5) goes stale and the stream surfaces re-drape.
func on_terrain_tiles_changed(_keys: Array) -> void:
	request_rebuild()
	request_drainage()


# ---------------------------------------------------------------------------
# Drainage (derived network, catchment areas)
# ---------------------------------------------------------------------------

## Re-run the drainage analysis (debounced, background). `reextract_only`
## reuses the last grid and only re-extracts channels (threshold changed).
func request_drainage(reextract_only: bool = false) -> void:
	# A pending FULL analysis always wins over a re-extract.
	var full_pending := _drain_pending and not _drain_reextract_only
	if reextract_only and not _drain.is_empty() and not full_pending:
		_drain_reextract_only = true
		_drain_t = 0.05
	else:
		_drain_reextract_only = false
		_drain_t = DRAIN_DEBOUNCE_S
	_drain_pending = true


func drainage_busy() -> bool:
	return _drain_task >= 0 or _drain_pending


func _process_drainage(delta: float) -> void:
	if _drain_task >= 0:
		if WorkerThreadPool.is_task_completed(_drain_task):
			WorkerThreadPool.wait_for_task_completion(_drain_task)
			_drain_task = -1
			_apply_drainage(_drain_box.get("result", {}))
			_drain_box = {}
		return
	if not _drain_pending or _task_id >= 0:
		return
	_drain_t -= delta
	if _drain_t > 0.0:
		return
	_drain_pending = false
	_start_drainage(_drain_reextract_only)
	_drain_reextract_only = false


func _start_drainage(reextract_only: bool) -> void:
	if loader == null or not is_instance_valid(loader) or not _bound:
		return
	var min_area := float(layer.setting("min_catchment_ha")) * 10000.0
	var lines: Array = []
	for f in _features:
		lines.append((f as Dictionary)["points"])
	var job := {"min_area": min_area, "lines": lines}
	if reextract_only and not _drain.is_empty():
		job["reuse"] = _drain
	else:
		var sampler: WaterGroundSampler = loader.call("make_water_ground_sampler")
		if sampler == null:
			return
		if loader.has_method("tile_layers_snapshot"):
			sampler.layers = loader.call("tile_layers_snapshot")
		var half := sampler.detail_half()
		if half <= 0.0:
			half = minf(1500.0, sampler.coarse_extent_m * 0.5)
		job["sampler"] = sampler
		job["half"] = maxf(half - 10.0, 100.0)
	var box := {}
	_drain_box = box
	_drain_started_ms = Time.get_ticks_msec()
	_drain_task = WorkerThreadPool.add_task(func() -> void:
		box["result"] = _drainage_job(job), false, "WaterNetwork drainage")


## Worker: analyse (or reuse) the grid, extract channels, drop the ones that
## duplicate a mapped/user stream.
static func _drainage_job(job: Dictionary) -> Dictionary:
	var res: Dictionary = job.get("reuse", {})
	if res.is_empty():
		var sampler: WaterGroundSampler = job["sampler"]
		res = FlowRouting.analyze(Callable(sampler, "surface_at"), float(job["half"]),
			DRAIN_CELL_M, job.get("lines", []))
	var chans := FlowRouting.channels(res, float(job["min_area"]))
	# Spatial hash of the feature lines (10 m buckets) for the duplicate test.
	var bucket := {}
	for l_v in job.get("lines", []):
		var rs := ChannelProfile.resample(l_v, 4.0)
		for p in (rs["points"] as PackedVector2Array):
			var k := Vector2i(floori(p.x / 10.0), floori(p.y / 10.0))
			var arr: PackedVector2Array = bucket.get(k, PackedVector2Array())
			arr.append(p)
			bucket[k] = arr
	var kept: Array = []
	var idx := 0
	for ch_v in chans:
		var ch: Dictionary = ch_v
		var rs2 := ChannelProfile.resample(ch["points"], 5.0)
		var pts: PackedVector2Array = rs2["points"]
		var near := 0
		for p in pts:
			if _near_bucket(bucket, p, DUP_DIST_M):
				near += 1
		if pts.size() > 0 and float(near) / float(pts.size()) >= DUP_SHARE:
			continue
		ch["id"] = "dc_%d" % idx
		idx += 1
		kept.append(ch)
	return {"grid": res, "channels": kept}


static func _near_bucket(bucket: Dictionary, p: Vector2, dist: float) -> bool:
	var k0 := Vector2i(floori(p.x / 10.0), floori(p.y / 10.0))
	var d2 := dist * dist
	for dz in [-1, 0, 1, 2, -2]:
		for dx in [-1, 0, 1, 2, -2]:
			var k := Vector2i(k0.x + int(dx), k0.y + int(dz))
			if not bucket.has(k):
				continue
			for q in (bucket[k] as PackedVector2Array):
				if q.distance_squared_to(p) <= d2:
					return true
	return false


func _apply_drainage(res: Dictionary) -> void:
	if res.is_empty():
		return
	_drain = res.get("grid", {})
	_derived = res.get("channels", [])
	_rev += 1
	print("WaterNetwork: drainage %d² @ %.1f m — %d derived channels (%d ms)" % [
		int(_drain.get("n", 0)), float(_drain.get("cell_m", 0.0)), _derived.size(),
		Time.get_ticks_msec() - _drain_started_ms])
	_update_station_areas()
	rebuild_surfaces()
	rebuild_drainage_overlay()
	drainage_changed.emit()


## Catchment area at every profile station of every feature — a running max
## downstream, since a hand-drawn line may wander a cell off the thread.
func _update_station_areas() -> void:
	station_area = {}
	if _drain.is_empty():
		return
	for f in _features:
		var prof: Dictionary = _profiles.get(f["id"], {})
		var pts: PackedVector2Array = prof.get("points", PackedVector2Array())
		var arr := PackedFloat32Array()
		arr.resize(pts.size())
		var run := 0.0
		for i in pts.size():
			run = maxf(run, FlowRouting.area_at(_drain, pts[i]))
			arr[i] = run
		station_area[f["id"]] = arr


func drainage() -> Dictionary:
	return _drain


func derived_channels() -> Array:
	return _derived


func derived_channel(id: String) -> Dictionary:
	for ch in _derived:
		if str((ch as Dictionary).get("id", "")) == id:
			return ch
	return {}


## The drainage overlay: derived channels as ribbons that run downstream.
func rebuild_drainage_overlay() -> void:
	var terrain := _terrain_node()
	var show := bool(layer.setting("show_drainage")) or str(layer.setting("display_mode")) == "flow"
	if terrain == null or not show or _derived.is_empty():
		if _drain_mi != null and is_instance_valid(_drain_mi):
			_drain_mi.queue_free()
		_drain_mi = null
		return
	var lines: Array = []
	for ch in _derived:
		var o := int((ch as Dictionary).get("order", 1))
		lines.append({"points": ch["points"], "width": 0.8 + 0.7 * float(o),
			"color": Color(WaterLineMesh.order_color(o), 0.55 + 0.1 * float(o))})
	var mesh := WaterLineMesh.build(lines, Callable(loader, "ground_height_at"), 0.3)
	if mesh == null:
		return
	if _drain_mi == null or not is_instance_valid(_drain_mi):
		_drain_mi = MeshInstance3D.new()
		_drain_mi.name = DRAINAGE_NODE
		_drain_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _drain_mat == null:
			_drain_mat = ShaderMaterial.new()
			_drain_mat.shader = DRAINAGE_SHADER
		_drain_mi.material_override = _drain_mat
		terrain.add_child(_drain_mi)
	_drain_mi.mesh = mesh


func set_show_drainage(on: bool) -> void:
	layer.set_setting("show_drainage", on)
	save_layer()
	rebuild_drainage_overlay()


## "off" | "osm" | "all" | "flow" — what water is drawn.
func set_display_mode(mode: String) -> void:
	if not (mode in ["off", "osm", "all", "flow"]):
		return
	layer.set_setting("display_mode", mode)
	save_layer()
	rebuild_surfaces()
	rebuild_drainage_overlay()
	display_mode_changed.emit(mode)


func set_carve_enabled(on: bool) -> void:
	layer.set_setting("carve_enabled", on)
	save_layer()
	request_rebuild()


func set_show_buried(on: bool) -> void:
	layer.set_setting("show_buried", on)
	save_layer()
	_refresh_buried_visibility()
	buried_visibility_changed.emit(on)


# ---------------------------------------------------------------------------
# Underground spans: culverts + pipes
# ---------------------------------------------------------------------------

## The graph's 3D lens (Site Plan / Elevation / Globe) is up — buried runs read
## through the soil there exactly like conduits (see ConduitManager).
func set_preview_visibility(on: bool) -> void:
	_preview_visible = on
	_refresh_buried_visibility()


func _refresh_buried_visibility() -> void:
	if _buried_root != null and is_instance_valid(_buried_root):
		_buried_root.visible = (bool(layer.setting("show_buried")) or _preview_visible) \
			and str(layer.setting("display_mode")) != "off"


func buried_runs(id: String) -> Array:
	return _runs.get(id, [])


## (Re)build every culvert / pipe barrel, its headwalls and its outlet jet.
## Barrels use the conduit flow material (X-RAY — they read through the
## ground), so the root is hidden in first person unless "Show buried" is on
## or a graph lens is up; the headwalls and jets are above ground and always
## drawn.
func rebuild_buried() -> void:
	var terrain := _terrain_node()
	if terrain == null:
		return
	if _buried_root == null or not is_instance_valid(_buried_root):
		_buried_root = Node3D.new()
		_buried_root.name = BURIED_NODE
		terrain.add_child(_buried_root)
	if _mouths_root == null or not is_instance_valid(_mouths_root):
		_mouths_root = Node3D.new()
		_mouths_root.name = MOUTHS_NODE
		terrain.add_child(_mouths_root)
	for c in _buried_root.get_children():
		c.queue_free()
	for c in _mouths_root.get_children():
		c.queue_free()
	_outlet_vfx = []
	_runs = {}
	if str(layer.setting("display_mode")) == "off":
		_refresh_buried_visibility()
		return
	var ground := Callable(loader, "ground_height_at")
	for f_v in _features:
		var f: Dictionary = f_v
		if not _display_allows(f):
			continue
		var has_buried := false
		for m in f["modes"]:
			if str(m) != "surface":
				has_buried = true
				break
		if not has_buried:
			continue
		var prof: Dictionary = _profiles.get(f["id"], {})
		if prof.is_empty():
			continue
		var fd := f
		var rs := BuriedWaterBuilder.runs(f, prof, ground, func(i: int) -> float:
			return station_q_lps(fd, i, BuriedWaterBuilder.DESIGN_RAIN_MMH))
		_runs[f["id"]] = rs
		var states: Array = _states.get(f["id"], [])
		for run_v in rs:
			var run: Dictionary = run_v
			var q := float((states[int(run["i0"])] as Dictionary).get("q_lps", 0.0)) \
				if int(run["i0"]) < states.size() else 0.0
			run["q_lps"] = q
			run["surcharged"] = BuriedWaterBuilder.surcharged(run, q)
			var tint := COL_SURCHARGED if bool(run["surcharged"]) else Color(0, 0, 0, 0)
			var mi := MeshInstance3D.new()
			mi.mesh = ConduitMeshBuilder.build_tube(run["path"], float(run["d"]) * 0.5)
			mi.material_override = ConduitKinds.make_flow_material(
				"culvert_pipe" if str(run["mode"]) == "culvert" else "pvc_6in", tint,
				clampf(q / maxf(float(run["capacity_lps"]), 1.0), 0.15, 1.0), 1.0)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_buried_root.add_child(mi)
			_add_headwall(run["inlet"], run, ground, false)
			_add_headwall(run["outlet"], run, ground, true)
			var vfx := ConduitDischargeVfx.new()
			_mouths_root.add_child(vfx)
			_outlet_vfx.append({"vfx": vfx, "fid": f["id"], "run": run})
	_refresh_buried_visibility()


## A concrete headwall at a barrel mouth, square to the flow, seated on the
## ground — the visible sign that the stream goes under here.
func _add_headwall(at: Vector3, run: Dictionary, ground: Callable, is_outlet: bool) -> void:
	if _headwall_mat == null:
		_headwall_mat = StandardMaterial3D.new()
		_headwall_mat.albedo_color = Color(0.62, 0.61, 0.57)
		_headwall_mat.roughness = 0.9
	var d := float(run["d"])
	var path: PackedVector3Array = run["path"]
	var n := path.size()
	var a := path[0]
	var b := path[mini(1, n - 1)]
	if is_outlet:
		a = path[maxi(n - 2, 0)]
		b = path[n - 1]
	var fwd := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if fwd.length_squared() < 1e-6:
		fwd = Vector3(1, 0, 0)
	fwd = fwd.normalized()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	var invert := at.y - d * 0.5
	var gy := float(ground.call(at.x, at.z))
	var top := maxf(gy + 0.15, invert + d + 0.25)
	box.size = Vector3(d * 2.2, top - invert + 0.2, 0.3)
	mi.mesh = box
	mi.material_override = _headwall_mat
	var basis := Basis.looking_at(fwd, Vector3.UP)
	mi.transform = Transform3D(basis, Vector3(at.x, (top + invert - 0.2) * 0.5, at.z))
	_mouths_root.add_child(mi)


## Outlet jets are smoothed inside ConduitDischargeVfx; 10 Hz is plenty, and
## it was one particle-material write per outlet per FRAME before.
const OUTLET_VFX_S := 0.1
var _vfx_acc := 0.0


func _drive_outlet_vfx(delta: float) -> void:
	_vfx_acc += delta
	if _vfx_acc < OUTLET_VFX_S:
		return
	delta = _vfx_acc
	_vfx_acc = 0.0
	for e_v in _outlet_vfx:
		var e: Dictionary = e_v
		var vfx: ConduitDischargeVfx = e["vfx"]
		if not is_instance_valid(vfx):
			continue
		var run: Dictionary = e["run"]
		var states: Array = _states.get(e["fid"], [])
		var i1 := int(run["i1"])
		var q := float((states[i1] as Dictionary).get("q_lps", 0.0)) if i1 < states.size() else 0.0
		vfx.set_flow(delta, q, run["outlet"], run["out_dir"])


func set_min_catchment_ha(ha: float) -> void:
	layer.set_setting("min_catchment_ha", clampf(ha, 0.1, 500.0))
	save_layer()
	request_drainage(true)


# ---------------------------------------------------------------------------
# Editing API (the WATER toolbar section). Every mutator expects the caller to
# have called checkpoint() first and to call commit() after; ids are resolved
# feature ids: "ws_<n>" (player), "osm:<way id>", "dc_<n>" (derived).
# ---------------------------------------------------------------------------

static func source_of(id: String) -> String:
	if id.begins_with("osm:"):
		return "osm"
	if id.begins_with("dc_"):
		return "derived"
	return "user"


static func osm_id_of(id: String) -> int:
	var tail := id.trim_prefix("osm:")
	return int(tail) if tail.is_valid_int() else -1


## {points, modes} of any feature (a derived channel reports all-surface).
func editable_points(id: String) -> Dictionary:
	if source_of(id) == "derived":
		var ch := derived_channel(id)
		if ch.is_empty():
			return {}
		var pts: PackedVector2Array = ch["points"]
		return {"points": pts, "modes": WaterFeatureLayer._fit_modes([], pts.size())}
	var f := feature(id)
	if f.is_empty():
		return {}
	return {"points": (f["points"] as PackedVector2Array).duplicate(),
		"modes": (f["modes"] as Array).duplicate()}


## Turn a derived channel into a player stream (kind by Strahler order).
## Returns the new stream id.
func promote_derived(dc_id: String) -> String:
	var ch := derived_channel(dc_id)
	if ch.is_empty():
		return ""
	var order := int(ch.get("order", 1))
	var kind := "stream" if order >= 2 else "ditch"
	var id := layer.add_stream(ch["points"], {"name": "Drainage %s" % dc_id.trim_prefix("dc_"),
		"source": "derived", "kind": kind})
	_derived.erase(ch)
	return id


## Replace a feature's geometry. A derived channel is promoted first; an OSM
## way stores the edit as an override (its data is never copied otherwise).
## Returns the id the edit landed on.
func apply_points(id: String, points: PackedVector2Array, modes: Array) -> String:
	if points.size() < WaterFeatureLayer.MIN_POINTS:
		return id
	match source_of(id):
		"derived":
			var nid := promote_derived(id)
			if nid.is_empty():
				return id
			layer.update_stream(nid, {"points": points, "modes": modes})
			return nid
		"osm":
			layer.set_osm_override(osm_id_of(id), {"points": points, "modes": modes})
		_:
			layer.update_stream(id, {"points": points, "modes": modes})
	# Keep the resolved copy current so the editor draws the edit before the
	# debounced rebuild re-resolves.
	var f := feature(id)
	if not f.is_empty():
		f["points"] = points
		f["modes"] = WaterFeatureLayer._fit_modes(modes, points.size())
	return id


## Patch name / kind / section / base_lps / carve.
func set_feature_fields(id: String, patch: Dictionary) -> void:
	match source_of(id):
		"osm":
			layer.set_osm_override(osm_id_of(id), patch)
		"user":
			layer.update_stream(id, patch)


## Mode of one span (segment index) of a feature.
func set_span_mode(id: String, seg: int, mode: String) -> String:
	var ep := editable_points(id)
	if ep.is_empty() or not (mode in WaterFeatureLayer.MODES):
		return id
	var modes: Array = ep["modes"]
	if seg < 0 or seg >= modes.size():
		return id
	modes[seg] = mode
	if source_of(id) == "osm":
		layer.set_osm_override(osm_id_of(id), {"modes": modes})
		var f := feature(id)
		if not f.is_empty():
			f["modes"] = modes
		return id
	return apply_points(id, ep["points"], modes)


## Delete a player stream; hide an OSM way (Revert brings it back).
func delete_feature(id: String) -> void:
	match source_of(id):
		"osm":
			layer.set_osm_override(osm_id_of(id), {"hidden": true})
		"user":
			layer.remove_stream(id)
		"derived":
			var ch := derived_channel(id)
			if not ch.is_empty():
				_derived.erase(ch)
	_by_id.erase(id)
	for i in range(_features.size() - 1, -1, -1):
		if str((_features[i] as Dictionary)["id"]) == id:
			_features.remove_at(i)


func revert_osm(id: String) -> void:
	if source_of(id) == "osm":
		layer.clear_osm_override(osm_id_of(id))


## Flip a stream's direction (points and span modes).
func reverse_feature(id: String) -> String:
	var ep := editable_points(id)
	if ep.is_empty():
		return id
	var modes: Array = (ep["modes"] as Array).duplicate()
	modes.reverse()
	return apply_points(id, StreamNetwork.reversed(ep["points"]), modes)


## A new player stream, oriented DOWNHILL (reversed when drawn uphill).
## Returns {id, reversed}.
func add_user_stream(points: PackedVector2Array, kind: String = "stream") -> Dictionary:
	var pts := points
	var rev := false
	if loader != null and loader.has_method("ground_height_at") \
			and not StreamNetwork.runs_downhill(pts, Callable(loader, "ground_height_at")):
		pts = StreamNetwork.reversed(pts)
		rev = true
	var id := layer.add_stream(pts, {"kind": kind})
	return {"id": id, "reversed": rev}


## The path water takes downhill from `p`, along the drainage grid, stopping
## where it reaches an existing stream (so the new one joins it) or the edge.
## Simplified to editable waypoints.
func trace_from(p: Vector2) -> PackedVector2Array:
	if _drain.is_empty():
		return PackedVector2Array()
	var raw := FlowRouting.trace(_drain, p)
	var cut := raw.size()
	var cell := float(_drain.get("cell_m", 5.0))
	var bucket := {}
	for f in _features:
		var rs := ChannelProfile.resample((f as Dictionary)["points"], 3.0)
		for q in (rs["points"] as PackedVector2Array):
			var k := Vector2i(floori(q.x / 10.0), floori(q.y / 10.0))
			# Read-modify-WRITE: a packed array fetched from a Dictionary is a
			# copy-on-write value, so appending to it in place changes nothing.
			var arr: PackedVector2Array = bucket.get(k, PackedVector2Array())
			arr.append(q)
			bucket[k] = arr
	for i in range(3, raw.size()):
		if _near_bucket(bucket, raw[i], cell * 1.2):
			cut = i + 1
			break
	var path := raw.slice(0, cut)
	return FlowRouting.rdp(path, cell * 0.75)


# ---------------------------------------------------------------------------
# Edits with undo (the WATER toolbar section drives these)
# ---------------------------------------------------------------------------

func checkpoint() -> void:
	_undo.append(layer.snapshot())
	while _undo.size() > UNDO_DEPTH:
		_undo.pop_front()
	_redo.clear()


## Persist + re-carve after an edit made between checkpoint() and here.
func commit() -> void:
	save_layer()
	# A player edit: once the carve lands, the channels it dug get their
	# vegetation cleared (see _apply_job_result). Load-time carves do not —
	# the forest on a saved map must not change because a cache missed.
	_clear_veg_after_carve = true
	request_rebuild()


func can_undo() -> bool:
	return not _undo.is_empty()


func undo() -> bool:
	if _undo.is_empty():
		return false
	_redo.append(layer.snapshot())
	layer.restore(_undo.pop_back())
	commit()
	return true


func redo() -> bool:
	if _redo.is_empty():
		return false
	_undo.append(layer.snapshot())
	layer.restore(_redo.pop_back())
	commit()
	return true
