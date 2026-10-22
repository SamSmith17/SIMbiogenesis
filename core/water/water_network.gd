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
## Stations sampled per channel to decide when to remesh, the flow below which
## a station counts as dry for that test, and the poll interval while rain is
## moving through the network.
const SAMPLE_STATIONS := 9
const WET_LPS := 0.5
const ACTIVE_POLL_S := 0.5
const MAX_STORMS := 64
## How far back a basin's water is followed, and the step of its balance.
const BASIN_HORIZON_H := 24.0
const BASIN_STEP_H := 2.0 / 60.0
const BASINS_NODE := "StreamBasins"
## Erosion: re-carve once the bed has dropped this much somewhere since the
## last carve (and no more often than EROSION_RECARVE_MS); never deeper than
## EROSION_MAX_M below the designed bed.
const EROSION_RECARVE_M := 0.05
const EROSION_RECARVE_MS := 10000
## A re-carve rewrites the channel tile cache; erosion's are saved at most
## this often (and on exit).
const CHANNEL_CACHE_SAVE_MS := 30000
const EROSION_MAX_M := 2.5
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
## Time of concentration (h) at every profile station, per feature id
## (StreamRunoff.station_tc_h) — how long rain takes to reach that point.
var station_tc: Dictionary = {}
## Travel time (h) down each channel from its first station
## (StreamRunoff.channel_travel_h): when a storm's water reaches a point.
var station_travel: Dictionary = {}
## Rain-tool storms: [{id, start_h, end_h, rate_mmh, poly, areas: {fid ->
## PackedFloat32Array per station}, pending}]. Session-only, and timed in sim
## hours, so a storm scrubs back and forth with the clock like real rain.
var _storms: Array = []
var _storm_seq := 0
var _storm_fx: Dictionary = {}    # storm id -> GPUParticles3D
## Rain history ending at _hist_now_h (StreamRunoff.history_prefix).
var _hist_prefix := PackedFloat32Array()
var _hist_now_h := NAN
## Discharge last meshed at a few sample stations per feature, to tell when a
## storm front has moved far enough to remesh.
var _sample_q: Dictionary = {}
## Hollows the channels run into (StreamBasins), per feature id, in
## downstream order: {i0, i1, i_low, spill_y, floor_y, flood…, capacity_m3,
## t0, vol (PackedFloat32Array), full (PackedByteArray)} — the series is the
## basin's water over the last BASIN_HORIZON_H, recomputed as the clock moves.
var _basins: Dictionary = {}
var _basins_mi: MeshInstance3D = null
var _basin_levels: Dictionary = {}    # "fid:i0" -> level last meshed
var _erosion_last_h := NAN
var _erosion_pending_m := 0.0
var _erosion_carved_ms := 0
## A rebuild asked for only by erosion (no edit, no setting): its carve lowers
## beds a few cm, so it skips what a real edit needs — the vegetation / camp
## re-ground, catchments, basins and the drainage re-analysis.
var _erosion_rebuild := false
var _task_erosion := false
var _channel_cache_dirty := false
var _channel_cache_due_ms := 0
## Per feature, the station facts erosion reads every poll: {rev, carved,
## surface, slope} — fixed until the next carve.
var _ero_cache: Dictionary = {}
## Per feature, its water surface arrays (StreamMeshBuilder.feature_arrays),
## and the ground beside its channel top per station (bank_refs) — fixed until
## the next carve.
var _surf_arrays: Dictionary = {}
var _bank_refs: Dictionary = {}
## Per feature, the ground under its uncarved stations (StreamMeshBuilder.
## drape_refs) — outside the carved patch, so an erosion re-carve keeps it.
var _drape_refs: Dictionary = {}
var _surf_masks: Dictionary = {}
var _buried_sig := 0
## The flow re-mesh the poll asks for runs on a worker: {task, box, rev}.
var _remesh_task := -1
var _remesh_box: Dictionary = {}
var _remesh_rev := -1
var _remesh_pending: Dictionary = {}
var _surf_gen := 0
var _remesh_ids: Dictionary = {}
var _basin_show_sig := ""

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
	if _channel_cache_dirty:
		_flush_channel_cache()
	if _drain_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_drain_task)
		_drain_task = -1
	if _remesh_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_remesh_task)
		_remesh_task = -1


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
	clear_storms()


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
	_erosion_rebuild = false
	_debounce_t = DEBOUNCE_S


func _request_erosion_rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	_erosion_rebuild = true
	_debounce_t = DEBOUNCE_S


func _process(delta: float) -> void:
	_hyd_t -= delta
	if _hyd_t <= 0.0 and _task_id < 0:
		_hyd_t = HYDRAULICS_POLL_S
		_poll_hydraulics()
	_process_drainage(delta)
	_process_remesh()
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
			_task_erosion = _erosion_rebuild and not force
			_erosion_rebuild = false
			_start_rebuild(force)
	elif _channel_cache_dirty and Time.get_ticks_msec() >= _channel_cache_due_ms:
		_flush_channel_cache()


func _flush_channel_cache() -> void:
	_channel_cache_dirty = false
	var channel: TerrainEditTiles = loader.call("channel_tile_layer") \
		if loader != null and is_instance_valid(loader) else null
	if channel != null:
		_save_cache(channel)


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
	PerfSpan.begin("water_carve_apply")
	_apply_job_result_inner(res)
	PerfSpan.end("water_carve_apply")


func _apply_job_result_inner(res: Dictionary) -> void:
	if res.is_empty() or loader == null or not is_instance_valid(loader):
		return
	var erosion_only := _task_erosion
	_task_erosion = false
	_profiles = res.get("profiles", {})
	_links = res.get("links", {})
	_ero_cache = {}
	_bank_refs = {}
	_surf_masks = {}
	if not erosion_only:
		_drape_refs = {}
	# A re-carve rebuilt every profile dict, but a feature whose carve signature
	# did not move has the same stations: keep its surface and flow.
	var changed := {}
	for f in _features:
		var fid: String = f["id"]
		if not _sigs.has(fid) or int(_sigs[fid]) != int((res.get("sigs", {}) as Dictionary).get(fid, -1)):
			changed[fid] = true
	# An erosion carve keeps the changed streams' surfaces on screen (beds a few
	# cm off) until their worker re-mesh lands; any other carve drops them.
	if not erosion_only:
		for fid in _surf_arrays.keys():
			if changed.has(fid):
				_surf_arrays.erase(fid)
		for fid in changed.keys():
			_states.erase(fid)
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
		PerfSpan.begin("water_carve_commit")
		loader.call("commit_channel_tiles", touched)
		PerfSpan.end("water_carve_commit")
		if erosion_only:
			_channel_cache_dirty = true
			_channel_cache_due_ms = Time.get_ticks_msec() + CHANNEL_CACHE_SAVE_MS
		else:
			_save_cache(channel)
		if loader.has_method("on_channels_carved"):
			PerfSpan.begin("water_carve_reground")
			loader.call("on_channels_carved", touched, erosion_only)
			PerfSpan.end("water_carve_reground")
	elif channel != null and _task_force:
		_save_cache(channel)
	PerfSpan.begin("water_carve_areas")
	if erosion_only:
		# The beds dropped a few cm: same lines, same grid, same catchments and
		# basins — only the travel times and Tc follow the new bed.
		_update_station_hydraulics()
		_hist_now_h = NAN
	else:
		# New/moved features get catchment areas off the current grid at once;
		# the debounced re-analysis below refines them once the channel is in it.
		_update_station_areas()
	PerfSpan.end("water_carve_areas")
	_rev += 1
	if erosion_only:
		_start_async_remesh(changed)
	else:
		rebuild_surfaces()
	network_rebuilt.emit()
	if not erosion_only and (not touched.is_empty() or _drain.is_empty() or _task_force):
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


## Discharge (L/s) at station i NOW, with rain's travel time: base flow plus
## the rational-method hydrograph of the weather's rain and of every Rain-tool
## storm draining there (StreamRunoff). Before the drainage analysis lands
## there are no catchments yet, so it is base flow.
func station_q_now(f: Dictionary, i: int) -> float:
	var tcs: Variant = station_tc.get(f["id"], null)
	if not (tcs is PackedFloat32Array) or (tcs as PackedFloat32Array).is_empty():
		return station_q_lps(f, i, rain_mmh_now())
	_ensure_rain_history()
	return _q_at(f, i, _hist_now_h)


## Discharge (L/s) at station i at time `tau` (≤ the history's end): base
## flow + the weather's rain over each station's Tc + every storm's travelled
## pulse — with every basin between a source and the station holding the
## source back until that basin was full at the time the water passed it.
## Inside a basin nothing flows as a stream (the basin's own water is drawn).
func _q_at(f: Dictionary, i: int, tau: float) -> float:
	var fid: String = f["id"]
	var tcs: PackedFloat32Array = station_tc[fid]
	var n := tcs.size()
	i = clampi(i, 0, n - 1)
	var basins: Array = _basins.get(fid, [])
	for bv in basins:
		if i >= int((bv as Dictionary)["i0"]) and i <= int((bv as Dictionary)["i1"]):
			return 0.0
	var areas: PackedFloat32Array = station_area.get(fid, PackedFloat32Array())
	var trv: PackedFloat32Array = station_travel.get(fid, PackedFloat32Array())
	var a_i := areas[mini(i, areas.size() - 1)] if areas.size() > 0 else 0.0
	var mean := StreamRunoff.window_mean_offset(_hist_prefix, _hist_now_h - tau, tcs[i])
	# Weather + base flow, in slices between the basins above this station,
	# each held back by every basin below it (bottom-up gate product).
	var q := 0.0
	var gate := 1.0
	var a_below := a_i
	for k in range(basins.size() - 1, -1, -1):
		var bd: Dictionary = basins[k]
		if int(bd["i1"]) >= i:
			continue
		var a_in := areas[maxi(int(bd["i0"]) - 1, 0)] if areas.size() > 0 else 0.0
		q += gate * StreamHydraulics.runoff_m3s(mean, maxf(a_below - a_in, 0.0)) * 1000.0
		var lag_b := (trv[i] - trv[int(bd["i1"])]) if trv.size() == n else 0.0
		gate *= _basin_full_at(bd, tau - lag_b)
		a_below = a_in
		if gate <= 0.0:
			break
	q += gate * (StreamHydraulics.runoff_m3s(mean, a_below) * 1000.0 + float(f.get("base_lps", 0.0)))
	for st_v in _storms:
		var st: Dictionary = st_v
		var sa: Variant = (st["areas"] as Dictionary).get(fid, null)
		if not (sa is PackedFloat32Array) or (sa as PackedFloat32Array).is_empty():
			continue
		var a2: float = (sa as PackedFloat32Array)[mini(i, (sa as PackedFloat32Array).size() - 1)]
		if a2 <= 0.0:
			continue
		# Travel time down the channel from where the storm's water enters it,
		# held back by any basin between the entry and here.
		var entry := int((st["entry"] as Dictionary).get(fid, 0))
		var lag := 0.0
		if trv.size() == n:
			lag = maxf(trv[i] - trv[clampi(entry, 0, n - 1)], 0.0)
		var g2 := 1.0
		for bv2 in basins:
			var bd2: Dictionary = bv2
			if int(bd2["i0"]) >= entry and int(bd2["i1"]) < i:
				var lag_b2 := (trv[i] - trv[int(bd2["i1"])]) if trv.size() == n else 0.0
				g2 *= _basin_full_at(bd2, tau - lag_b2)
		if g2 <= 0.0:
			continue
		var smean := StreamRunoff.storm_arrival_mean(float(st["start_h"]), float(st["end_h"]),
			float(st["rate_mmh"]), tau, lag, float(st["patch_tc_h"]))
		q += g2 * StreamHydraulics.runoff_m3s(smean, a2) * 1000.0
	return q


## 1 when the basin was full (spilling) at `tau`, else 0.
func _basin_full_at(bd: Dictionary, tau: float) -> float:
	var full: Variant = bd.get("full", null)
	if not (full is PackedByteArray) or (full as PackedByteArray).is_empty():
		return 0.0
	var k := int(floor((tau - float(bd["t0"])) / BASIN_STEP_H))
	if k < 0:
		return 0.0
	var fa: PackedByteArray = full
	return float(fa[mini(k, fa.size() - 1)])


## Per-station hydraulic state of one feature NOW (station_q_now).
func feature_states_now(f: Dictionary) -> Array:
	var prof: Dictionary = _profiles.get(f["id"], {})
	var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
	var bed: PackedFloat32Array = prof.get("bed", PackedFloat32Array())
	var sec: Dictionary = f["section"]
	var b := float(sec.get("bed_w", 2.0))
	var z := float(sec.get("bank_slope", 1.5))
	var qs := _feature_q_now(f, s.size())
	var out: Array = []
	out.resize(s.size())
	var dry := {"q_lps": 0.0, "depth_m": 0.0, "top_w_m": 0.0, "velocity_ms": 0.0, "froude": 0.0}
	for i in s.size():
		if qs[i] <= 0.0:
			out[i] = dry
			continue
		out[i] = StreamHydraulics.state(qs[i], b, z, ChannelProfile._slope(s, bed, i))
	return out


## station_q_now at every station of a feature at once: the same sum as _q_at,
## with the per-feature lookups and each storm's constants taken once. A
## feature with basins on it goes station by station (_q_at) for its gates.
func _feature_q_now(f: Dictionary, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	var fid: String = f["id"]
	var tcs: Variant = station_tc.get(fid, null)
	if not (tcs is PackedFloat32Array) or (tcs as PackedFloat32Array).size() != n:
		var rain := rain_mmh_now()
		for i in n:
			out[i] = station_q_lps(f, i, rain)
		return out
	_ensure_rain_history()
	if not (_basins.get(fid, []) as Array).is_empty():
		for i in n:
			out[i] = _q_at(f, i, _hist_now_h)
		return out
	var tc: PackedFloat32Array = tcs
	var areas: PackedFloat32Array = station_area.get(fid, PackedFloat32Array())
	var trv: PackedFloat32Array = station_travel.get(fid, PackedFloat32Array())
	var base := float(f.get("base_lps", 0.0))
	var hist := _hist_prefix
	var src: Array = []
	for st_v in _storms:
		var st: Dictionary = st_v
		var sa: Variant = (st["areas"] as Dictionary).get(fid, null)
		if not (sa is PackedFloat32Array) or (sa as PackedFloat32Array).size() != n:
			continue
		var entry := clampi(int((st["entry"] as Dictionary).get(fid, 0)), 0, n - 1)
		src.append([sa, entry, float(st["start_h"]), float(st["end_h"]), float(st["rate_mmh"]),
			float(st["patch_tc_h"])])
	var now := _hist_now_h
	var has_trv := trv.size() == n
	for i in n:
		var a_i := areas[mini(i, areas.size() - 1)] if areas.size() > 0 else 0.0
		var mean := StreamRunoff.window_mean_offset(hist, 0.0, tc[i])
		var q := StreamHydraulics.runoff_m3s(mean, a_i) * 1000.0 + base
		for sv in src:
			var sd: Array = sv
			var a2: float = (sd[0] as PackedFloat32Array)[i]
			if a2 <= 0.0:
				continue
			var lag := maxf(trv[i] - trv[int(sd[1])], 0.0) if has_trv else 0.0
			var smean := StreamRunoff.storm_arrival_mean(float(sd[2]), float(sd[3]), float(sd[4]),
				now, lag, float(sd[5]))
			q += StreamHydraulics.runoff_m3s(smean, a2) * 1000.0
		out[i] = q
	return out


## The clock now, in absolute hours (NAN without a world).
func _now_h() -> float:
	var main: Node = loader.get("_main") if loader != null else null
	if main == null or not main.has_method("get_absolute_hours"):
		return NAN
	return float(main.call("get_absolute_hours"))


## Rain intensity (mm/h) at any instant: the harness override, else the
## weather at that date and hour.
func rain_mmh_at(abs_h: float) -> float:
	if rain_override_mmh >= 0.0:
		return rain_override_mmh
	var main: Node = loader.get("_main") if loader != null else null
	if main == null:
		return 0.0
	var ws := get_node_or_null("/root/WeatherService")
	var clock: Variant = main.get("clock")
	if ws == null or not ws.has_method("rain_rate_mmh") or clock == null:
		return 0.0
	var lat := float(main.get("latitude")) if main.get("latitude") != null else 0.0
	var lon := float(main.get("longitude")) if main.get("longitude") != null else 0.0
	if ws.has_method("covers") and not bool(ws.call("covers", lat, lon)):
		return 0.0
	var d: Dictionary = (clock as Object).call("abs_hours_to_date", abs_h)
	return float(ws.call("rain_rate_mmh", int(d["month"]), int(d["day"]), float(d["day_time"])))


## Rebuild the rain history when the clock has moved (it is a pure function of
## the clock, so a scrub back simply reads the past again).
func _ensure_rain_history() -> void:
	var now := _now_h()
	if not is_finite(now):
		now = 0.0
	if is_finite(_hist_now_h) and absf(now - _hist_now_h) < 1e-4:
		return
	var max_tc := StreamRunoff.TC_MIN_H
	for fid in station_tc.keys():
		for t in (station_tc[fid] as PackedFloat32Array):
			max_tc = maxf(max_tc, t)
	var span := max_tc + (BASIN_HORIZON_H if not _basins.is_empty() else 0.0)
	var samples := clampi(int(ceil(span / StreamRunoff.HISTORY_STEP_H)) + 1, 2,
		int(ceil((StreamRunoff.TC_MAX_H + BASIN_HORIZON_H) / StreamRunoff.HISTORY_STEP_H)) + 1)
	PerfSpan.begin("water_hist")
	_hist_prefix = StreamRunoff.history_prefix(Callable(self, "rain_mmh_at"), now, samples)
	PerfSpan.end("water_hist")
	_hist_now_h = now
	PerfSpan.begin("water_basins")
	_refresh_basin_series()
	PerfSpan.end("water_basins")


# ---------------------------------------------------------------------------
# Erosion: floods deepen the beds they run over
# ---------------------------------------------------------------------------

## While the clock runs FORWARD (a step of at most an hour — a jump or a scrub
## back erodes nothing), every carved, open-channel station whose flow puts
## more than the critical shear on its bed lowers it at
## StreamHydraulics.erosion_rate_mps. The cut is kept per feature in 10 m bins
## (WaterFeatureLayer.erosion, saved with the map) and re-carved in steps.
func _accumulate_erosion() -> void:
	var now := _now_h()
	if not is_finite(now):
		return
	var last := _erosion_last_h
	_erosion_last_h = now
	if not is_finite(last) or not bool(layer.setting("carve_enabled")):
		return
	var dt_s := (now - last) * 3600.0
	if dt_s <= 0.0 or dt_s > 3600.0:
		_maybe_erosion_recarve([], 0.0)
		return
	var step := ChannelProfile.EROSION_STEP_M
	var grew := 0.0
	var touched: Array = []
	var half := -1.0
	for f in _features:
		var fid: String = f["id"]
		var states: Array = _states.get(fid, [])
		var prof: Dictionary = _profiles.get(fid, {})
		var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
		if states.is_empty() or states.size() != s.size() or not bool(f.get("carve", true)):
			continue
		var ec: Dictionary = _ero_cache.get(fid, {})
		if ec.is_empty():
			if half < 0.0:
				half = _carve_half()
			ec = _erosion_facts(f, prof, half)
			_ero_cache[fid] = ec
		var mask: PackedByteArray = ec["mask"]
		var slope: PackedFloat32Array = ec["slope"]
		var sec: Dictionary = f["section"]
		var b := float(sec.get("bed_w", 2.0))
		var z := float(sec.get("bank_slope", 1.5))
		var ero := PackedFloat32Array()
		var bins := int(ceil(s[s.size() - 1] / step)) + 1
		var any := false
		for i in range(1, states.size()):
			if mask[i] == 0:
				continue
			var y := float((states[i] as Dictionary).get("depth_m", 0.0))
			if y < 0.02:
				continue
			var rate := StreamHydraulics.erosion_rate_mps(StreamHydraulics.bed_shear_pa(b, z, y, slope[i]))
			if rate <= 0.0:
				continue
			if not any:
				any = true
				ero = layer.erosion_of(fid).duplicate()
				if ero.size() < bins:
					var old := ero.size()
					ero.resize(bins)
					for k in range(old, bins):
						ero[k] = 0.0
			var k := clampi(int(round(s[i] / step)), 0, bins - 1)
			var dz := rate * dt_s * (s[i] - s[i - 1]) / step
			var before := ero[k]
			ero[k] = minf(ero[k] + dz, EROSION_MAX_M)
			grew = maxf(grew, ero[k] - before)
		if any:
			layer.erosion[fid] = ero
			f["erosion"] = ero
			touched.append(fid)
	_maybe_erosion_recarve(touched, grew)


## What erosion needs per station, fixed until the next carve: carved AND an
## open (surface) span, and the bed slope.
func _erosion_facts(f: Dictionary, prof: Dictionary, half: float) -> Dictionary:
	var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
	var bed: PackedFloat32Array = prof.get("bed", PackedFloat32Array())
	var varc: PackedFloat32Array = prof.get("varc", PackedFloat32Array())
	var carved := _carved_flags(f, prof, half)
	var open_ := StreamNetwork.surface_mask(f, s, varc)
	var mask := PackedByteArray()
	mask.resize(s.size())
	var slope := PackedFloat32Array()
	slope.resize(s.size())
	var modes: Array = f.get("modes", [])
	var va := varc if not varc.is_empty() or modes.is_empty() else StreamNetwork.vertex_arc(f["points"])
	var j := 0
	for i in s.size():
		slope[i] = ChannelProfile._slope(s, bed, i)
		# Erosion wants the station's OWN span open (not the mouth rule).
		var own := true
		if not modes.is_empty():
			while j < modes.size() - 1 and s[i] > va[j + 1] + 1e-4:
				j += 1
			own = str(modes[j]) == "surface"
		if i < carved.size() and carved[i] == 1 and own and open_[i] == 1:
			mask[i] = 1
	return {"mask": mask, "slope": slope}


## Re-carve once the beds have dropped EROSION_RECARVE_M somewhere (at most
## every EROSION_RECARVE_MS), or carve what is left once the floods stop.
func _maybe_erosion_recarve(touched: Array, grew: float) -> void:
	_erosion_pending_m += grew
	if _erosion_pending_m <= 0.002:
		return
	if Time.get_ticks_msec() - _erosion_carved_ms < EROSION_RECARVE_MS:
		return
	if not touched.is_empty() and _erosion_pending_m < EROSION_RECARVE_M:
		return
	print("WaterNetwork: floods cut %s deeper (%.2f m since the last carve) — re-carving" % [
		", ".join(PackedStringArray(touched)) if not touched.is_empty() else "the beds",
		_erosion_pending_m])
	_erosion_pending_m = 0.0
	_erosion_carved_ms = Time.get_ticks_msec()
	save_layer()
	_request_erosion_rebuild()


## Forget every flood cut (View tool's Reset erosion).
func reset_erosion() -> void:
	layer.erosion = {}
	_erosion_pending_m = 0.0
	save_layer()
	request_rebuild()


# ---------------------------------------------------------------------------
# Basins along the channels (StreamBasins): fill, then spill
# ---------------------------------------------------------------------------

## Find every closed hollow the carved channels run into, on the EDITED
## ground (a swale or pond the player dug across a stream).
func _update_basins() -> void:
	_basins = {}
	if loader == null or not loader.has_method("ground_height_at"):
		return
	var half := _carve_half()
	var gfn := Callable(loader, "ground_height_at")
	for f in _features:
		var prof: Dictionary = _profiles.get(f["id"], {})
		var pts: PackedVector2Array = prof.get("points", PackedVector2Array())
		if pts.size() < 3:
			continue
		var ground := PackedFloat32Array()
		ground.resize(pts.size())
		for i in pts.size():
			ground[i] = float(gfn.call(pts[i].x, pts[i].y))
		var found: Array = []
		var sec: Dictionary = f["section"]
		var top_w := float(sec.get("bed_w", 2.0)) + 2.0 * float(sec.get("bank_slope", 2.0)) * float(sec.get("depth", 0.7))
		for pit_v in StreamBasins.find_pits(ground, _carved_flags(f, prof, half)):
			var pit: Dictionary = pit_v
			# A dam across the channel where it leaves the hollow (the spill).
			var r := mini(int(pit["i1"]) + 1, pts.size() - 1)
			var tg := (pts[mini(r + 1, pts.size() - 1)] - pts[maxi(r - 1, 0)]).normalized()
			var dam_half := top_w * 0.5 + 6.0
			var nrm := Vector2(-tg.y, tg.x) * dam_half
			var dams := [[pts[r] - nrm, pts[r] + nrm]]
			var fl := StreamBasins.flood(pts[int(pit["i_low"])], float(pit["spill_y"]), gfn,
				StreamBasins.CELL_M, StreamBasins.MAX_HALF_M, dams)
			if bool(fl["open"]) or float(fl["volume_m3"]) < 1.0:
				continue
			pit.merge(fl)
			pit["capacity_m3"] = float(fl["volume_m3"])
			found.append(pit)
		if not found.is_empty():
			_basins[f["id"]] = found
			var desc := PackedStringArray()
			for b in found:
				desc.append("%.0f m3 / %.0f m2" % [float(b["capacity_m3"]), float(b["area_m2"])])
			print("WaterNetwork: %s runs into %s (%s)" % [f["id"], UiText.count(found.size(), "basin"),
				", ".join(desc)])
	_basin_levels = {}


## Half-size of the carved (hi-res) square, as rebuild_surfaces measures it.
func _carve_half() -> float:
	var sampler: WaterGroundSampler = loader.call("make_water_ground_sampler") \
		if loader != null and loader.has_method("make_water_ground_sampler") else null
	return sampler.detail_half() if sampler != null else 0.0


## Each basin's water over the last BASIN_HORIZON_H, empty at the start:
## the inflow at the station above it (held back by basins further up) less
## infiltration, clamped at full. Basins in downstream order, so a lower one
## sees the upper ones' spill.
func _refresh_basin_series() -> void:
	if _basins.is_empty():
		return
	var steps := int(ceil(BASIN_HORIZON_H / BASIN_STEP_H))
	var t0 := _hist_now_h - BASIN_HORIZON_H
	for fid in _basins.keys():
		var f := feature(str(fid))
		if f.is_empty():
			continue
		for bv in _basins[fid]:
			var bd: Dictionary = bv
			bd["t0"] = t0
			bd["full"] = PackedByteArray()
			var vol := PackedFloat32Array()
			var full := PackedByteArray()
			vol.resize(steps + 1)
			full.resize(steps + 1)
			var cap := float(bd["capacity_m3"])
			var stage: PackedVector3Array = bd["stage"]
			var i_in := maxi(int(bd["i0"]) - 1, 0)
			var v := 0.0
			for k in steps + 1:
				var tau := t0 + float(k) * BASIN_STEP_H
				if k > 0:
					v = StreamBasins.step_volume(v, _q_at(f, i_in, tau), BASIN_STEP_H, stage, cap)
				vol[k] = v
				full[k] = 1 if v >= cap * 0.995 else 0
			bd["vol"] = vol
			bd["full"] = full


## Water in a basin now (m³), and its level.
func basin_now(bd: Dictionary) -> Vector2:
	var vol: Variant = bd.get("vol", null)
	if not (vol is PackedFloat32Array) or (vol as PackedFloat32Array).is_empty():
		return Vector2(0.0, float(bd.get("floor_y", 0.0)))
	var v: float = (vol as PackedFloat32Array)[(vol as PackedFloat32Array).size() - 1]
	return Vector2(v, StreamBasins.level_for_volume(bd["stage"], v))


func basins() -> Dictionary:
	return _basins


## Re-mesh the basins' water when a level has moved (2 cm) or a basin
## emptied / started filling.
func _sync_basin_mesh(force: bool = false) -> void:
	var show_sig := "%s|%s" % [str(loader.call("water_visible")) if loader != null
		and loader.has_method("water_visible") else "true", str(layer.setting("display_mode"))]
	var changed := force or show_sig != _basin_show_sig
	_basin_show_sig = show_sig
	var want := {}
	for fid in _basins.keys():
		for bv in _basins[fid]:
			var bd: Dictionary = bv
			var now_v := basin_now(bd)
			var key := "%s:%d" % [fid, int(bd["i0"])]
			want[key] = now_v
			var prev: Variant = _basin_levels.get(key, null)
			if prev == null or absf((prev as Vector2).y - now_v.y) > 0.02 \
					or ((prev as Vector2).x > 0.5) != (now_v.x > 0.5):
				changed = true
	if _basin_levels.size() != want.size():
		changed = true
	if not changed:
		return
	_basin_levels = want
	var terrain := _terrain_node()
	if terrain == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	var show := bool(loader.call("water_visible")) if loader.has_method("water_visible") else true
	for fid in _basins.keys():
		var f := feature(str(fid))
		if not show or f.is_empty() or not _display_allows(f):
			continue
		for bv in _basins[fid]:
			var bd: Dictionary = bv
			var now_v := basin_now(bd)
			if now_v.x < 0.5:
				continue
			var lv := now_v.y
			var cells: PackedVector2Array = bd["cells"]
			var zs: PackedFloat32Array = bd["z"]
			var h := float(bd["cell"]) * 0.5
			for c in cells.size():
				if zs[c] >= lv:
					continue
				var p := cells[c]
				any = true
				var col := Color(0.5, 0.5, 0.0, 0.0)
				for q in [Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, -h), Vector2(h, h), Vector2(-h, h)]:
					var v2: Vector2 = p + (q as Vector2)
					st.set_color(col)
					st.set_uv(v2)
					st.set_uv2(Vector2(0.0, 0.0))
					st.set_normal(Vector3.UP)
					st.add_vertex(Vector3(v2.x, lv, v2.y))
	if not any:
		if _basins_mi != null and is_instance_valid(_basins_mi):
			_basins_mi.queue_free()
		_basins_mi = null
		return
	if _basins_mi == null or not is_instance_valid(_basins_mi):
		_basins_mi = MeshInstance3D.new()
		_basins_mi.name = BASINS_NODE
		_basins_mi.layers = WaterBuilder.WATER_RENDER_LAYER
		_basins_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _streams_mat == null:
			_streams_mat = ShaderMaterial.new()
			_streams_mat.shader = STREAM_SHADER
		_basins_mi.material_override = _streams_mat
		terrain.add_child(_basins_mi)
	_basins_mi.mesh = st.commit()


# ---------------------------------------------------------------------------
# Rain-tool storms
# ---------------------------------------------------------------------------

## A storm over `poly` (world XZ) at `rate_mmh` from `start_h` to `end_h`
## (absolute sim hours). Its runoff reaches each stream through the drainage
## grid. Returns its id.
func add_storm(poly: PackedVector2Array, rate_mmh: float, start_h: float, end_h: float) -> int:
	_storm_seq += 1
	var st := {"id": _storm_seq, "poly": poly.duplicate(), "rate_mmh": maxf(rate_mmh, 0.0),
		"start_h": start_h, "end_h": maxf(end_h, start_h), "areas": {}, "entry": {},
		"area_m2": 0.0, "patch_tc_h": StreamRunoff.TC_MIN_H}
	_compute_storm_areas(st)
	_storms.append(st)
	if _drain.is_empty():
		request_drainage()
	_hist_now_h = NAN
	_hyd_t = 0.0
	return _storm_seq


## Move a storm's end (the Rain tool extends it while the button is held).
func extend_storm(id: int, end_h: float) -> void:
	for st in _storms:
		if int((st as Dictionary)["id"]) == id:
			(st as Dictionary)["end_h"] = maxf(end_h, float((st as Dictionary)["start_h"]))
			_hyd_t = minf(_hyd_t, 0.25)
			return


func storms() -> Array:
	return _storms


## True while any storm's water can still be in a channel.
func _storm_flowing() -> bool:
	var now := _now_h()
	for st in _storms:
		var s: Dictionary = st
		if is_finite(now) and now >= float(s["start_h"]) \
				and now <= float(s["end_h"]) + StreamRunoff.TC_MAX_H + 1.0:
			return true
	return false


## How much of a storm's ground drains into the mapped / drawn streams (m²).
func storm_reach_m2(id: int) -> float:
	for st in _storms:
		if int((st as Dictionary)["id"]) == id:
			var best := 0.0
			for arr in ((st as Dictionary)["areas"] as Dictionary).values():
				var a := arr as PackedFloat32Array
				if a.size() > 0:
					best = maxf(best, a[a.size() - 1])
			return best
	return 0.0


func clear_storms() -> void:
	_storms = []
	for k in _storm_fx.keys():
		if is_instance_valid(_storm_fx[k]):
			(_storm_fx[k] as Node).queue_free()
	_storm_fx = {}


## The storm's area (m²) draining to every station: its ground as weights on
## the drainage grid, accumulated downstream the way the catchments are.
func _compute_storm_areas(st: Dictionary) -> void:
	st["areas"] = {}
	st["entry"] = {}
	st["patch_tc_h"] = StreamRunoff.TC_MIN_H
	if _drain.is_empty():
		return
	var poly: PackedVector2Array = st["poly"]
	var n := int(_drain["n"])
	var cell := float(_drain["cell_m"])
	var half := float(_drain["half_m"])
	var w := PackedFloat32Array()
	if not _drain.has("rank"):
		w.resize(n * n)
	var bb := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		bb = bb.expand(p)
	var c0 := clampi(int(floor((bb.position.x + half) / cell)), 0, n - 1)
	var c1 := clampi(int(ceil((bb.end.x + half) / cell)), 0, n - 1)
	var r0 := clampi(int(floor((bb.position.y + half) / cell)), 0, n - 1)
	var r1 := clampi(int(ceil((bb.end.y + half) / cell)), 0, n - 1)
	var cells := 0
	var src := PackedInt32Array()
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			if Geometry2D.is_point_in_polygon(Vector2(-half + float(c) * cell, -half + float(r) * cell), poly):
				src.append(r * n + c)
				cells += 1
	st["area_m2"] = float(cells) * cell * cell
	st["patch_tc_h"] = StreamRunoff.patch_tc_h(float(st["area_m2"]))
	if cells == 0:
		return
	var acc: PackedFloat32Array
	if _drain.has("rank"):
		acc = StreamRunoff.sparse_accumulate(_drain["recv"], _drain["rank"], src)
	else:
		for i in src:
			w[i] = 1.0
		acc = StreamRunoff.weighted_accumulate(_drain["recv"], _drain["order"], w)
	var grid := {"n": n, "cell_m": cell, "half_m": half, "acc": acc}
	for f in _features:
		var prof: Dictionary = _profiles.get(f["id"], {})
		var pts: PackedVector2Array = prof.get("points", PackedVector2Array())
		var arr := PackedFloat32Array()
		arr.resize(pts.size())
		var run := 0.0
		var entry := -1
		for i in pts.size():
			run = maxf(run, FlowRouting.area_at(grid, pts[i]))
			arr[i] = run
			if run > 0.0 and entry < 0:
				entry = i
		if entry >= 0:
			(st["areas"] as Dictionary)[f["id"]] = arr
			(st["entry"] as Dictionary)[f["id"]] = entry


## Rain falling over every storm the clock is inside of. Storms are kept for
## the session (a scrub back must find them again), the newest MAX_STORMS.
func _sync_storm_fx() -> void:
	var now := _now_h()
	var terrain := _terrain_node()
	var keep := {}
	while _storms.size() > MAX_STORMS:
		_storms.pop_front()
	for st_v in _storms:
		var st: Dictionary = st_v
		var id := int(st["id"])
		var raining: bool = is_finite(now) and now >= float(st["start_h"]) and now <= float(st["end_h"])
		if not raining or terrain == null:
			continue
		keep[id] = true
		if not _storm_fx.has(id) or not is_instance_valid(_storm_fx[id]):
			_storm_fx[id] = _make_storm_fx(st, terrain)
	for k in _storm_fx.keys():
		if not keep.has(k):
			if is_instance_valid(_storm_fx[k]):
				(_storm_fx[k] as Node).queue_free()
			_storm_fx.erase(k)


func _make_storm_fx(st: Dictionary, terrain: Node3D) -> GPUParticles3D:
	var poly: PackedVector2Array = st["poly"]
	var bb := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		bb = bb.expand(p)
	var c := bb.get_center()
	var gy := float(loader.call("ground_height_at", c.x, c.y)) if loader != null else 0.0
	var fx := GPUParticles3D.new()
	fx.name = "Storm_%d" % int(st["id"])
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(bb.size.x * 0.5, 1.0, bb.size.y * 0.5)
	pm.direction = Vector3(0.05, -1.0, 0.0)
	pm.spread = 2.0
	pm.initial_velocity_min = 16.0
	pm.initial_velocity_max = 20.0
	pm.gravity = Vector3(0.0, -4.0, 0.0)
	fx.process_material = pm
	var quad := QuadMesh.new()
	# Thicker and longer than a real drop: rain reads as streaks blurred by
	# motion, and a true 2 mm drop is sub-pixel past a few metres.
	quad.size = Vector2(0.07, 1.6)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.85, 0.9, 0.97, 0.42)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	quad.material = mat
	fx.draw_pass_1 = quad
	fx.amount = clampi(int(bb.get_area() / 4.0), 400, 14000)
	fx.lifetime = 2.2
	fx.preprocess = 2.2
	fx.visibility_aabb = AABB(Vector3(-bb.size.x * 0.5 - 5.0, -45.0, -bb.size.y * 0.5 - 5.0),
		Vector3(bb.size.x + 10.0, 50.0, bb.size.y + 10.0))
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	terrain.add_child(fx)
	fx.global_position = Vector3(c.x, gy + 38.0, c.y)
	return fx


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
	PerfSpan.begin("water_poll")
	_poll_hydraulics_inner()
	PerfSpan.end("water_poll")


func _poll_hydraulics_inner() -> void:
	_sync_storm_fx()
	if _features.is_empty() or _profiles.is_empty():
		return
	PerfSpan.begin("water_erosion")
	_accumulate_erosion()
	PerfSpan.end("water_erosion")
	if not _basins.is_empty():
		_ensure_rain_history()
		_sync_basin_mesh()
	var rain := rain_mmh_now()
	# Rain takes its travel time to reach each point, so the flow changes
	# while the clock runs even at a steady rate: compare the discharge at a
	# few stations down every channel with what was last meshed.
	# Only the streams whose flow moved are re-meshed; the rest keep theirs.
	var full := _last_q.is_empty()
	var moved_ids := {}
	for f in _features:
		if full:
			break
		var n_st := (_profiles.get(f["id"], {}).get("s", PackedFloat32Array()) as PackedFloat32Array).size()
		if n_st == 0:
			continue
		var prev: PackedFloat32Array = _sample_q.get(f["id"], PackedFloat32Array())
		for k in SAMPLE_STATIONS:
			var i := int(round(float(k) / float(SAMPLE_STATIONS - 1) * float(n_st - 1)))
			var q := station_q_now(f, i)
			var p := prev[k] if k < prev.size() else -1.0
			var wet_flip := (q >= WET_LPS) != (p >= WET_LPS)
			if p < 0.0 or wet_flip or absf(q - p) > REMESH_Q_CHANGE * maxf(p, 1.0):
				moved_ids[f["id"]] = true
				break
	# Poll faster while anything is moving through the channels.
	if _storm_flowing() or not _basins.is_empty() \
			or StreamRunoff.window_mean(_hist_prefix, StreamRunoff.TC_MAX_H) > 0.01:
		_hyd_t = minf(_hyd_t, ACTIVE_POLL_S)
	_last_rain = rain
	if full:
		rebuild_surfaces()
	elif not moved_ids.is_empty():
		_start_async_remesh(moved_ids)
	elif _flow_chip != null and is_instance_valid(_flow_chip) and _flow_chip.visible:
		_update_flow_chip()


## (Re)mesh every visible feature's water surface at the current flow.
func rebuild_surfaces() -> void:
	PerfSpan.begin("water_remesh")
	_rebuild_surfaces_inner()
	PerfSpan.end("water_remesh")


func _rebuild_surfaces_inner(only: Dictionary = {}) -> void:
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
	var partial := not only.is_empty()
	var items: Array = []
	var arrays: Array = []
	if not partial:
		_surf_gen += 1
		_states = {}
		_last_q = {}
		_sample_q = {}
		_surf_arrays = {}
	var ground := Callable(loader, "ground_height_at")
	for f in _features:
		var fid: String = f["id"]
		var prof: Dictionary = _profiles.get(fid, {})
		if prof.is_empty():
			continue
		var fresh := not partial or only.has(fid) or not _states.has(fid)
		var states: Array = _states.get(fid, [])
		if fresh:
			PerfSpan.begin("water_states")
			states = feature_states_now(f)
			PerfSpan.end("water_states")
			_states[fid] = states
			if not states.is_empty():
				var smp := PackedFloat32Array()
				for k in SAMPLE_STATIONS:
					var i := int(round(float(k) / float(SAMPLE_STATIONS - 1) * float(states.size() - 1)))
					smp.append(float((states[i] as Dictionary).get("q_lps", 0.0)))
				_sample_q[fid] = smp
				_last_q[fid] = float((states.back() as Dictionary).get("q_lps", 0.0))
		if bool(f.get("covered", false)) or not _display_allows(f):
			continue
		var it := {"feature": f, "profile": prof, "states": states,
			"carved": _carved_flags(f, prof, half)}
		items.append(it)
		if show:
			if fresh or not _surf_arrays.has(fid):
				PerfSpan.begin("water_mesh_build")
				if not _bank_refs.has(fid):
					_bank_refs[fid] = StreamMeshBuilder.bank_refs(f, prof, ground)
				if not _drape_refs.has(fid):
					_drape_refs[fid] = StreamMeshBuilder.drape_refs(f, prof, it["carved"], ground)
				if not _surf_masks.has(fid):
					_surf_masks[fid] = StreamNetwork.surface_mask(f, prof.get("s", PackedFloat32Array()),
						prof.get("varc", PackedFloat32Array()))
				_surf_arrays[fid] = StreamMeshBuilder.feature_arrays(it, ground, _bank_refs[fid],
					_drape_refs[fid], _surf_masks[fid])
				PerfSpan.end("water_mesh_build")
			arrays.append(_surf_arrays[fid])
	_sync_basin_mesh()
	var mesh: ArrayMesh = null
	if show and not arrays.is_empty():
		mesh = StreamMeshBuilder.mesh_from_arrays(arrays)
	rebuild_buried()
	_update_buried_flow()
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


## Re-mesh `ids` on a worker: the flow at every station is summed here (it
## reads the storms, the rain history and the basins), the depth / width at
## each (StreamHydraulics.state) and the strip's arrays are built off the main
## thread from the per-feature caches (bank tops, drape, open spans), and the
## result swaps in when it lands. A carve or a full rebuild meanwhile makes it
## stale (dropped). Asked again while one runs, the ids wait for it.
func _start_async_remesh(ids: Dictionary) -> void:
	if _remesh_task >= 0:
		_remesh_pending.merge(ids)
		return
	if loader == null or not is_instance_valid(loader):
		return
	PerfSpan.begin("water_remesh_prep")
	var sampler: WaterGroundSampler = loader.call("make_water_ground_sampler") \
		if loader.has_method("make_water_ground_sampler") else null
	var half := sampler.detail_half() if sampler != null else 0.0
	var ground := Callable(loader, "ground_height_at")
	var jobs: Array = []
	for f in _features:
		var fid: String = f["id"]
		if not ids.has(fid):
			continue
		var prof: Dictionary = _profiles.get(fid, {})
		var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
		if s.is_empty():
			continue
		var carved := _carved_flags(f, prof, half)
		if not _bank_refs.has(fid):
			_bank_refs[fid] = StreamMeshBuilder.bank_refs(f, prof, ground)
		if not _drape_refs.has(fid):
			_drape_refs[fid] = StreamMeshBuilder.drape_refs(f, prof, carved, ground)
		if not _surf_masks.has(fid):
			_surf_masks[fid] = StreamNetwork.surface_mask(f, s, prof.get("varc", PackedFloat32Array()))
		jobs.append({"fid": fid, "f": f.duplicate(true), "prof": prof.duplicate(true),
			"qs": _feature_q_now(f, s.size()), "carved": carved, "bank": _bank_refs[fid],
			"drape": _drape_refs[fid], "mask": _surf_masks[fid],
			"draw": not bool(f.get("covered", false)) and _display_allows(f)})
	PerfSpan.end("water_remesh_prep")
	if jobs.is_empty():
		return
	var box := {}
	_remesh_box = box
	_remesh_rev = _rev * 100000 + _surf_gen
	_remesh_ids = ids.duplicate()
	_remesh_task = WorkerThreadPool.add_task(func() -> void:
		box["result"] = _remesh_job(jobs), false, "WaterNetwork remesh")


## Worker: states + strip arrays per feature (pure).
static func _remesh_job(jobs: Array) -> Array:
	var out: Array = []
	for j_v in jobs:
		var j: Dictionary = j_v
		var f: Dictionary = j["f"]
		var prof: Dictionary = j["prof"]
		var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
		var bed: PackedFloat32Array = prof.get("bed", PackedFloat32Array())
		var sec: Dictionary = f["section"]
		var b := float(sec.get("bed_w", 2.0))
		var z := float(sec.get("bank_slope", 1.5))
		var qs: PackedFloat32Array = j["qs"]
		var dry := {"q_lps": 0.0, "depth_m": 0.0, "top_w_m": 0.0, "velocity_ms": 0.0, "froude": 0.0}
		var states: Array = []
		states.resize(s.size())
		for i in s.size():
			states[i] = dry if qs[i] <= 0.0 \
				else StreamHydraulics.state(qs[i], b, z, ChannelProfile._slope(s, bed, i))
		var arrays: Array = []
		if bool(j["draw"]):
			arrays = StreamMeshBuilder.feature_arrays({"feature": f, "profile": prof,
				"states": states, "carved": j["carved"]}, Callable(), j["bank"], j["drape"], j["mask"])
		out.append({"fid": j["fid"], "states": states, "arrays": arrays})
	return out


func _process_remesh() -> void:
	if _remesh_task < 0 or not WorkerThreadPool.is_task_completed(_remesh_task):
		return
	WorkerThreadPool.wait_for_task_completion(_remesh_task)
	_remesh_task = -1
	var res: Array = _remesh_box.get("result", [])
	_remesh_box = {}
	if _remesh_rev != _rev * 100000 + _surf_gen:
		# Stale (a carve or a full re-mesh landed meanwhile): do them again.
		_remesh_pending.merge(_remesh_ids)
	elif not res.is_empty():
		PerfSpan.begin("water_remesh_swap")
		for r_v in res:
			var r: Dictionary = r_v
			var fid: String = r["fid"]
			var states: Array = r["states"]
			_states[fid] = states
			if not states.is_empty():
				var smp := PackedFloat32Array()
				for k in SAMPLE_STATIONS:
					var i := int(round(float(k) / float(SAMPLE_STATIONS - 1) * float(states.size() - 1)))
					smp.append(float((states[i] as Dictionary).get("q_lps", 0.0)))
				_sample_q[fid] = smp
				_last_q[fid] = float((states.back() as Dictionary).get("q_lps", 0.0))
			_surf_arrays[fid] = r["arrays"]
		_swap_stream_mesh()
		PerfSpan.end("water_remesh_swap")
	if not _remesh_pending.is_empty():
		var ids := _remesh_pending
		_remesh_pending = {}
		_start_async_remesh(ids)


## The strip mesh from every shown feature's cached arrays, plus what reads
## the states (buried flow, the flow view, the basins' water).
func _swap_stream_mesh() -> void:
	var terrain := _terrain_node()
	if terrain == null:
		return
	var show := bool(loader.call("water_visible")) if loader.has_method("water_visible") else true
	var arrays: Array = []
	var items: Array = []
	var flow_on := str(layer.setting("display_mode")) == "flow"
	var sampler: WaterGroundSampler = loader.call("make_water_ground_sampler") 		if flow_on and loader.has_method("make_water_ground_sampler") else null
	var half := sampler.detail_half() if sampler != null else 0.0
	for f in _features:
		var fid: String = f["id"]
		if bool(f.get("covered", false)) or not _display_allows(f) or not _states.has(fid):
			continue
		var prof: Dictionary = _profiles.get(fid, {})
		items.append({"feature": f, "profile": prof, "states": _states[fid],
			"carved": _carved_flags(f, prof, half) if flow_on else PackedByteArray()})
		if show and _surf_arrays.has(fid):
			arrays.append(_surf_arrays[fid])
	_sync_basin_mesh()
	_update_buried_flow()
	_rebuild_flow_view(items)
	var mesh: ArrayMesh = StreamMeshBuilder.mesh_from_arrays(arrays) if show and not arrays.is_empty() else null
	if mesh == null:
		if _streams_mi != null and is_instance_valid(_streams_mi):
			_streams_mi.queue_free()
		_streams_mi = null
		return
	if _streams_mi == null or not is_instance_valid(_streams_mi):
		rebuild_surfaces()
		return
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
		# The ground under the line from the drape cache (its middle offset).
		var dr: Dictionary = _drape_refs.get(f["id"], {})
		var dz: PackedFloat32Array = dr.get("z", PackedFloat32Array())
		var dm := int(dr.get("m", 1))
		var vsum := 0.0
		for i in pts.size():
			var st: Dictionary = states[i]
			vsum += float(st.get("velocity_ms", 0.0))
			if i < carved.size() and carved[i] == 1:
				lev[i] = bed[i] + maxf(float(st.get("depth_m", 0.0)), StreamMeshBuilder.MIN_RENDER_DEPTH_M)
			elif dz.size() == pts.size() * dm:
				lev[i] = dz[i * dm + dm / 2] + StreamMeshBuilder.DRAPE_LIFT_M
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


## The nearest stream to a point and how fast it runs there: {feature_id,
## name, dist_m, velocity_ms, q_lps, depth_m}, or {} when no feature lies
## within `max_dist`. One station's hydraulics, not the whole feature's — the
## ambient bed asks every second from wherever the listener stands.
func nearest_flow(p: Vector2, max_dist: float, rain_mmh: float = -1.0) -> Dictionary:
	var best := max_dist
	var best_f: Dictionary = {}
	var best_s := 0.0
	for f_v in _features:
		var f: Dictionary = f_v
		var pts: PackedVector2Array = f.get("points", PackedVector2Array())
		if pts.size() < 2:
			continue
		var near := StreamNetwork.nearest_on_line(pts, p)
		if float(near["dist"]) < best:
			best = float(near["dist"])
			best_f = f
			best_s = float(near["s"])
	if best_f.is_empty():
		return {}
	var prof: Dictionary = _profiles.get(best_f["id"], {})
	var rain := rain_mmh if rain_mmh >= 0.0 else rain_mmh_now()
	var i := ChannelProfile.station_index(prof, best_s) if not prof.is_empty() else 0
	var q := station_q_lps(best_f, i, rain)
	var sec: Dictionary = best_f.get("section", {})
	var slope := 0.002
	var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
	var bed: PackedFloat32Array = prof.get("bed", PackedFloat32Array())
	if s.size() > 1 and bed.size() == s.size():
		slope = ChannelProfile._slope(s, bed, clampi(i, 0, s.size() - 1))
	var st := StreamHydraulics.state(q, float(sec.get("bed_w", 2.0)), float(sec.get("bank_slope", 1.5)), slope)
	return {"feature_id": best_f["id"], "name": str(best_f.get("name", "")), "dist_m": best,
		"velocity_ms": float(st.get("velocity_ms", 0.0)), "q_lps": q, "depth_m": float(st.get("depth_m", 0.0))}


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
		res["rank"] = StreamRunoff.order_rank(res["order"])
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
	PerfSpan.begin("water_drain_apply")
	_apply_drainage_inner(res)
	PerfSpan.end("water_drain_apply")


func _apply_drainage_inner(res: Dictionary) -> void:
	if res.is_empty():
		return
	_drain = res.get("grid", {})
	_derived = res.get("channels", [])
	_rev += 1
	print("WaterNetwork: drainage %d² @ %.1f m — %d derived channels (%d ms)" % [
		int(_drain.get("n", 0)), float(_drain.get("cell_m", 0.0)), _derived.size(),
		Time.get_ticks_msec() - _drain_started_ms])
	_drape_refs = {}
	_update_station_areas()
	rebuild_surfaces()
	rebuild_drainage_overlay()
	drainage_changed.emit()


## Catchment area at every profile station of every feature — a running max
## downstream, since a hand-drawn line may wander a cell off the thread.
func _update_station_areas() -> void:
	station_area = {}
	station_tc = {}
	station_travel = {}
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
	_update_station_hydraulics()
	PerfSpan.begin("water_storm_areas")
	for st in _storms:
		_compute_storm_areas(st)
	PerfSpan.end("water_storm_areas")
	PerfSpan.begin("water_find_basins")
	_update_basins()
	PerfSpan.end("water_find_basins")
	_hist_now_h = NAN


## Tc and travel time at every station from its catchment and the CURRENT bed.
func _update_station_hydraulics() -> void:
	station_tc = {}
	station_travel = {}
	for f in _features:
		var arr: PackedFloat32Array = station_area.get(f["id"], PackedFloat32Array())
		var prof: Dictionary = _profiles.get(f["id"], {})
		var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
		if arr.size() != s.size():
			continue
		station_tc[f["id"]] = StreamRunoff.station_tc_h(s,
			prof.get("ground", PackedFloat32Array()), prof.get("bed", PackedFloat32Array()), arr)
		var sec: Dictionary = f["section"]
		station_travel[f["id"]] = StreamRunoff.channel_travel_h(s,
			prof.get("bed", PackedFloat32Array()), arr, float(sec.get("bed_w", 2.0)),
			float(sec.get("bank_slope", 1.5)))


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
func rebuild_buried(force: bool = false) -> void:
	var terrain := _terrain_node()
	if terrain == null:
		return
	# The barrels, headwalls and outlet jets follow the network, not the flow:
	# a re-mesh as the flow changes only re-tints them (_update_buried_flow).
	var sig := hash([_rev, str(layer.setting("display_mode")), _features.size()])
	if not force and sig == _buried_sig and _buried_root != null and is_instance_valid(_buried_root):
		return
	_buried_sig = sig
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
			run["mi"] = mi
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


## The buried runs' flow, surcharge flag and tint at the current states.
func _update_buried_flow() -> void:
	for fid in _runs.keys():
		var states: Array = _states.get(fid, [])
		for run_v in (_runs[fid] as Array):
			var run: Dictionary = run_v
			var q := float((states[int(run["i0"])] as Dictionary).get("q_lps", 0.0)) \
				if int(run["i0"]) < states.size() else 0.0
			var sur := BuriedWaterBuilder.surcharged(run, q)
			var mi: Variant = run.get("mi", null)
			var fill := clampf(q / maxf(float(run["capacity_lps"]), 1.0), 0.15, 1.0)
			if absf(float(run.get("q_lps", -1.0)) - q) < 0.05 and bool(run.get("surcharged", false)) == sur:
				continue
			run["q_lps"] = q
			run["surcharged"] = sur
			if mi is MeshInstance3D and is_instance_valid(mi):
				(mi as MeshInstance3D).material_override = ConduitKinds.make_flow_material(
					"culvert_pipe" if str(run["mode"]) == "culvert" else "pvc_6in",
					COL_SURCHARGED if sur else Color(0, 0, 0, 0), fill, 1.0)


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


## Streams with no base flow of their own carry nothing between storms
## (desert washes): the kind's default base flow is dropped.
func set_dry_between_storms(on: bool) -> void:
	layer.set_setting("dry_between_storms", on)
	save_layer()
	request_rebuild()


## Map-wide stream curve defaults (each 0..1; a stream's own values win).
func set_curve_defaults(smooth: float, meander: float) -> void:
	layer.set_setting("curve_smooth", clampf(smooth, 0.0, 1.0))
	layer.set_setting("curve_meander", clampf(meander, 0.0, 1.0))
	save_layer()
	_clear_veg_after_carve = true
	request_rebuild()


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
	return {"points": (f.get("ctrl_points", f["points"]) as PackedVector2Array).duplicate(),
		"modes": (f.get("ctrl_modes", f["modes"]) as Array).duplicate()}


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
		f["ctrl_points"] = points
		f["ctrl_modes"] = WaterFeatureLayer._fit_modes(modes, points.size())
		StreamNetwork.curve_feature(f, layer.settings)
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
			f["ctrl_modes"] = modes
			StreamNetwork.curve_feature(f, layer.settings)
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
