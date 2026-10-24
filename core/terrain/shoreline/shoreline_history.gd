class_name ShorelineHistory
extends Node

## "Shoreline over time": the drape as of an archived capture, and a lake's
## level from its gauge, both PURE FUNCTIONS OF THE SIM CLOCK so the timeline
## scrubs them backwards (the ExtremeWeather / plant-growth rule). A child of
## TerrainLoader ("ShorelineHistory"), made the first time the loader asks.
##
##  1. IMAGERY. WaybackCatalog lists every Esri World Imagery Wayback release;
##     the distinct captures over this site are found once (a tilemap walk at
##     the site's centre tile + one metadata query per changed release) and
##     cached under terrain_cache/wayback/. The world picks:
##       current — today's ESRI drape (nothing changes; the default);
##       pinned  — one capture, always;
##       follow  — the latest capture taken on or before the clock's date, so
##                 scrubbing back to 2016 swaps the drape to the 2016 photo.
##     Only the detail + hyper layers swap (the sharp square round the site;
##     the site patch is off while a capture is shown, the 30 km base stays
##     today's). drape_chain() is what the loader's imagery requests ask.
##  2. LAKE LEVEL. LakeGauge finds a USGS lake gauge within 45 km (the known
##     list first, then NWIS), reads its whole daily record (cached under
##     terrain_cache/lake_gauge/, refreshed once a day), shifts NGVD29 to the
##     DEM's NAVD88 with VERTCON at the gauge, and draws the lake as ONE flat
##     plane at the level of the clock's date: the lake's OSM outline grown by
##     PLANE_MARGIN_M so higher water creeps over the exposed playa, hidden by
##     the ground wherever the ground is higher. The lake's own still-water
##     body is left out of WaterBuilder while this plane stands in for it.
##     ⚠ The DEM only knows the ground ABOVE the water it was surveyed at:
##     a level below that surface is under the DEM's flat lake and cannot be
##     drawn (dem_water_m(), said in the UI).
##
## The world's choice rides world.json `terrain_imagery.history`
## ({mode, release, lake_level}) through TerrainLoader.world_imagery_record.

signal changed

const CATALOG_PATH := "user://terrain_cache/wayback/waybackconfig.json"
const CAPTURES_DIR := "user://terrain_cache/wayback"
const GAUGE_DIR := "user://terrain_cache/lake_gauge"
## Release list refetched after a week (Esri adds about one a month).
const CATALOG_MAX_AGE_S := 7 * 86400
## Gauge series refetched after a day (a new daily value lands each day).
const GAUGE_MAX_AGE_S := 86400
## Zoom the captures are listed at (the detail drape's zoom class).
const LIST_ZOOM := 17
const MODES := ["current", "pinned", "follow"]
## How far past the OSM outline the level plane reaches (m).
const PLANE_MARGIN_M := 2500.0
## A still body this large with no name match is taken as the gauged lake.
const LAKE_MIN_AREA_M2 := 1.0e6
## Follow mode waits this long on one capture before asking for its drape
## (scrubbing across three captures must not queue three downloads).
const FOLLOW_SETTLE_S := 1.0
const HTTP_TIMEOUT_S := 45.0
## By path, not the autoload name, so this file compiles under --script.
const _IMAGERY := preload("res://core/terrain/imagery_service.gd")

var _loader: Node = null
var _lat := 0.0
var _lon := 0.0
var _rec: Dictionary = {"mode": "current", "release": -1}

var _releases: Array = []          # WaybackCatalog.parse_config
var _captures: Array = []          # WaybackCatalog.dedupe, oldest first
var _captures_status := "idle"     # idle | loading | ready | failed
var _captures_note := ""
var _requested_release := -1       # the release the last drape request used
var _follow_want := -1
var _follow_since := 0.0

var _gauge: Dictionary = {}        # LakeGauge.pick_gauge + shift_m
var _series: Dictionary = {}       # LakeGauge.parse_dv_json
var _gauge_status := "idle"
var _gauge_note := ""
var _plane: MeshInstance3D = null
var _lake_items: Array = []        # the OSM still bodies the plane replaces
var _dem_water_m := NAN
var _level_m := NAN                # NAVD88 at the clock's date (NAN = none)
var _level_info: Dictionary = {}
## The reach mask (LakeSpill): ground sampled a budget of rows per frame, the
## flood on a worker, then a spill texture on the plane's material.
const SPILL_CELL_M := 8.0
const SPILL_MAX_HALF_M := 4500.0
const SPILL_FRAME_MS := 4.0
var _spill_gen := 0
var _spill_n := 0
var _spill_half := 0.0
var _spill_h := PackedFloat32Array()
var _spill_row := -1                 # next row to sample; -1 = idle
var _spill_task := -1
var _spill: PackedFloat32Array = PackedFloat32Array()
var _spill_ready := false

var _http: HTTPRequest = null
var _queue: Array = []             # [{url, cb}]
var _busy := false
var _tick := 0.0


func setup(loader: Node, lat: float, lon: float, rec: Dictionary) -> void:
	_loader = loader
	_lat = lat
	_lon = lon
	_rec = normalize_record(rec)
	_gauge = LakeGauge.known_gauge_for(lat, lon)
	ImagerySources.wayback_meta.clear()
	_load_cached_captures()
	if _lake_level_on() and not _gauge.is_empty():
		_load_cached_series()


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = HTTP_TIMEOUT_S
	add_child(_http)
	_http.request_completed.connect(_on_http_done)
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _rec["mode"] != "current":
		ensure_captures()
	if _lake_level_on():
		ensure_gauge()


## {mode, release, lake_level (true/false; absent = on for a known gauge)}.
static func normalize_record(rec: Variant) -> Dictionary:
	var d: Dictionary = rec if rec is Dictionary else {}
	var mode := str(d.get("mode", "current"))
	var out := {"mode": mode if mode in MODES else "current", "release": int(d.get("release", -1))}
	if out["mode"] == "pinned" and int(out["release"]) < 0:
		out["mode"] = "current"
	if d.has("lake_level"):
		out["lake_level"] = bool(d["lake_level"])
	return out


func record() -> Dictionary:
	return _rec.duplicate()


# ---------------------------------------------------------------------------
# The drape
# ---------------------------------------------------------------------------

## The source chain the loader's detail + hyper requests use: [] = today's
## imagery, else ["wayback_<release>"]. Remembers what it handed out.
func drape_chain() -> Array:
	var rel := _wanted_release()
	_requested_release = rel
	return [] if rel < 0 else [ImagerySources.wayback_id(rel)]


## The capture on screen (or being fetched) — {} for today's imagery.
func shown_capture() -> Dictionary:
	return {} if _requested_release < 0 else WaybackCatalog.capture_of_release(_captures, _requested_release)


func _wanted_release() -> int:
	match str(_rec["mode"]):
		"pinned":
			return int(_rec["release"])
		"follow":
			var c := WaybackCatalog.capture_at(_captures, _clock_date())
			return int(c.get("release", -1))
	return -1


func captures() -> Array:
	return _captures


func captures_status() -> Dictionary:
	return {"status": _captures_status, "note": _captures_note, "count": _captures.size()}


func mode() -> String:
	return str(_rec["mode"])


## Switch the drape: "current", "follow", or "pinned" with a release id.
func set_mode(m: String, release: int = -1) -> void:
	var nxt := normalize_record({"mode": m, "release": release})
	if nxt["mode"] == _rec["mode"] and int(nxt["release"]) == int(_rec["release"]):
		return
	_rec["mode"] = nxt["mode"]
	_rec["release"] = nxt["release"]
	if _rec["mode"] != "current":
		ensure_captures()
	_refresh_drape_if_needed(true)
	changed.emit()


func _refresh_drape_if_needed(force: bool = false) -> void:
	var want := _wanted_release()
	if not force and want == _requested_release:
		return
	if _loader != null and _loader.has_method("refresh_history_drape"):
		_loader.call("refresh_history_drape")


func ensure_captures(refetch: bool = false) -> void:
	if _captures_status == "loading":
		return
	if not refetch and _captures_status == "ready" and not _captures.is_empty():
		return
	_captures_status = "loading"
	_captures_note = "Reading the Wayback release list…"
	changed.emit()
	if not refetch and _catalog_fresh():
		_releases = WaybackCatalog.parse_config(FileAccess.get_file_as_string(CATALOG_PATH))
		if not _releases.is_empty():
			_start_walk()
			return
	_fetch(WaybackCatalog.CONFIG_URL, func(ok: bool, code: int, body: PackedByteArray) -> void:
		var text := body.get_string_from_utf8()
		var rels := WaybackCatalog.parse_config(text) if ok and code == 200 else []
		if rels.is_empty():
			# Offline: an older copy still works.
			if FileAccess.file_exists(CATALOG_PATH):
				rels = WaybackCatalog.parse_config(FileAccess.get_file_as_string(CATALOG_PATH))
			if rels.is_empty():
				_captures_fail("the Wayback release list could not be read (HTTP %d)" % code)
				return
		else:
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURES_DIR))
			var f := FileAccess.open(CATALOG_PATH, FileAccess.WRITE)
			if f != null:
				f.store_string(text)
		_releases = rels
		_start_walk())


func _catalog_fresh() -> bool:
	if not FileAccess.file_exists(CATALOG_PATH):
		return false
	return Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(CATALOG_PATH)) < CATALOG_MAX_AGE_S


## Walk the tilemap chain at the site's centre tile, then read each changed
## release's capture metadata. (A method, not a self-calling lambda: a
## lambda captures its own variable before it is assigned, as null.)
func _start_walk() -> void:
	var t := GeoMath.lonlat_to_tile_f(_lon, _lat, LIST_ZOOM)
	_captures_note = "Finding the distinct captures over this site…"
	changed.emit()
	_walk_step(_releases.size() - 1, int(floor(t.x)), int(floor(t.y)), [])


func _walk_step(idx: int, tx: int, ty: int, changed_rel: Array) -> void:
	if idx < 0:
		_read_metadata(changed_rel, 0, [])
		return
	var rid := int((_releases[idx] as Dictionary)["id"])
	_fetch(WaybackCatalog.tilemap_url(rid, LIST_ZOOM, tx, ty), func(ok: bool, code: int, body: PackedByteArray) -> void:
		if not ok or code != 200:
			_captures_fail("the Wayback tile map did not answer (HTTP %d)" % code)
			return
		var tm := WaybackCatalog.parse_tilemap(body.get_string_from_utf8())
		var st := WaybackCatalog.next_in_walk(_releases, rid, tm)
		if int(st["changed"]) >= 0 and not changed_rel.has(int(st["changed"])):
			changed_rel.append(int(st["changed"]))
		_walk_step(int(st["next_index"]), tx, ty, changed_rel))


func _read_metadata(rels: Array, i: int, obs: Array) -> void:
	if i >= rels.size():
		_captures = WaybackCatalog.dedupe(obs)
		if _captures.is_empty():
			_captures_fail("no dated captures over this site")
			return
		_register_meta()
		_save_captures()
		_captures_status = "ready"
		_captures_note = "%s over this site, %s to %s" % [UiText.count(_captures.size(), "capture"),
			str((_captures[0] as Dictionary)["date"]), str((_captures[-1] as Dictionary)["date"])]
		print("ShorelineHistory: %d Wayback captures over the site (%d releases changed the centre tile)" % [
			_captures.size(), rels.size()])
		changed.emit()
		_refresh_drape_if_needed()
		return
	var rid := int(rels[i])
	var rel: Dictionary = _releases[WaybackCatalog.index_of(_releases, rid)]
	_captures_note = "Reading capture dates (%d of %d)…" % [i + 1, rels.size()]
	changed.emit()
	_query_layer(rel, WaybackCatalog.LAYER_FIRST, func(meta: Dictionary) -> void:
		if bool(meta.get("ok", false)):
			obs.append({"release": rid, "release_date": str(rel["date"]), "date": meta["date"],
				"sensor": meta["sensor"], "provider": meta["provider"], "res_m": meta["res_m"]})
		_read_metadata(rels, i + 1, obs))


## The metadata layer whose capture is drawn at LIST_ZOOM: from the 30 cm band
## outward until a feature's zoom range covers it.
func _query_layer(rel: Dictionary, layer: int, done: Callable) -> void:
	if layer > WaybackCatalog.LAYER_LAST or str(rel["meta_url"]).is_empty():
		done.call({"ok": false})
		return
	_fetch(WaybackCatalog.metadata_url(str(rel["meta_url"]), layer, _lat, _lon),
			func(ok: bool, code: int, body: PackedByteArray) -> void:
		var meta := WaybackCatalog.parse_metadata(body.get_string_from_utf8()) if ok and code == 200 else {"ok": false}
		if WaybackCatalog.meta_covers_zoom(meta, LIST_ZOOM):
			done.call(meta)
		else:
			_query_layer(rel, layer + 1, done))


func _captures_fail(why: String) -> void:
	push_warning("ShorelineHistory: " + why)
	_captures_status = "failed" if _captures.is_empty() else "ready"
	_captures_note = why
	changed.emit()


func _captures_path() -> String:
	return "%s/captures_%s_%s_z%d.json" % [CAPTURES_DIR, CoordToken.token(_lat), CoordToken.token(_lon), LIST_ZOOM]


func _load_cached_captures() -> void:
	var p := _captures_path()
	if not FileAccess.file_exists(p):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if parsed is Dictionary and (parsed as Dictionary).get("captures", null) is Array:
		_captures = (parsed as Dictionary)["captures"]
		for c_v in _captures:
			var c: Dictionary = c_v
			c["release"] = int(c.get("release", -1))
		_register_meta()
		_captures_status = "ready"
		_captures_note = "%s over this site (saved list)" % UiText.count(_captures.size(), "capture")
		# A week-old list may be missing the newest release: refresh it quietly.
		if Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(p)) > CATALOG_MAX_AGE_S:
			_captures_status = "idle"


func _save_captures() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURES_DIR))
	var f := FileAccess.open(_captures_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"lat": _lat, "lon": _lon, "zoom": LIST_ZOOM, "captures": _captures}, "\t"))


func _register_meta() -> void:
	for c_v in _captures:
		var c: Dictionary = c_v
		ImagerySources.wayback_meta[int(c["release"])] = c


# ---------------------------------------------------------------------------
# The lake level
# ---------------------------------------------------------------------------

func _lake_level_on() -> bool:
	if _rec.has("lake_level"):
		return bool(_rec["lake_level"])
	return not LakeGauge.known_gauge_for(_lat, _lon).is_empty()


func lake_level_enabled() -> bool:
	return _lake_level_on()


func set_lake_level(on: bool) -> void:
	_rec["lake_level"] = on
	if on:
		ensure_gauge()
	_apply_level(true)
	if _loader != null and _loader.has_method("_attach_water"):
		_loader.call("_attach_water")
	changed.emit()


func gauge() -> Dictionary:
	return _gauge


func gauge_status() -> Dictionary:
	return {"status": _gauge_status, "note": _gauge_note,
		"first": str(_series.get("first", "")), "last": str(_series.get("last", "")),
		"level_m": _level_m, "level_info": _level_info, "dem_water_m": _dem_water_m,
		"shift_m": float(_gauge.get("shift_m", NAN)), "name": str(_gauge.get("name", "")),
		"param": str(_gauge.get("param", ""))}


## The level (NAVD88 m) the clock's date shows; NAN without a series.
func level_now() -> float:
	return _level_m


func ensure_gauge() -> void:
	if _gauge_status == "loading" or (_gauge_status == "ready" and not _series_stale()):
		return
	_gauge_status = "loading"
	if _gauge.is_empty():
		_gauge_note = "Looking for a lake gauge near this site…"
		changed.emit()
		_fetch(LakeGauge.site_search_url(_lat, _lon), func(ok: bool, code: int, body: PackedByteArray) -> void:
			var found := LakeGauge.pick_gauge(LakeGauge.parse_site_rdb(body.get_string_from_utf8()), _lat, _lon) \
				if ok and code == 200 else {}
			if found.is_empty():
				_gauge_fail("no USGS lake gauge within %d km" % int(LakeGauge.SEARCH_RADIUS_KM))
				return
			_gauge = found
			_fetch_shift_then_series())
		return
	_fetch_shift_then_series()


func _fetch_shift_then_series() -> void:
	if str(_gauge.get("param", "")) == LakeGauge.PARAM_NAVD88:
		_gauge["shift_m"] = 0.0
	if _gauge.has("shift_m"):
		_fetch_series()
		return
	_gauge_note = "Asking NOAA VERTCON for the NGVD29 → NAVD88 shift…"
	changed.emit()
	_fetch(LakeGauge.ncat_url(float(_gauge["lat"]), float(_gauge["lon"])), func(ok: bool, code: int, body: PackedByteArray) -> void:
		var s := LakeGauge.parse_ncat_shift(body.get_string_from_utf8()) if ok and code == 200 else NAN
		if is_nan(s):
			_gauge_fail("NOAA's VERTCON service did not answer, so the gauge's NGVD29 level cannot be put on the DEM's datum")
			return
		_gauge["shift_m"] = s
		_fetch_series())


func _series_path() -> String:
	return "%s/usgs_%s_%s.json" % [GAUGE_DIR, str(_gauge.get("id", "")), str(_gauge.get("param", ""))]


func _series_stale() -> bool:
	var p := _series_path()
	return not FileAccess.file_exists(p) \
		or Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(p)) > GAUGE_MAX_AGE_S


func _load_cached_series() -> void:
	var p := _series_path()
	if not FileAccess.file_exists(p):
		return
	var s := LakeGauge.parse_dv_json(FileAccess.get_file_as_string(p))
	if bool(s["ok"]):
		_series = s
		_gauge_status = "ready"
		_gauge_note = ""
		_apply_level(true)


func _fetch_series() -> void:
	if not _series_stale() and not _series.is_empty():
		_gauge_status = "ready"
		_apply_level(true)
		changed.emit()
		return
	_gauge_note = "Reading %s's daily levels…" % str(_gauge.get("name", "the gauge"))
	changed.emit()
	var today := Time.get_date_string_from_system()
	_fetch(LakeGauge.dv_url(_gauge, today), func(ok: bool, code: int, body: PackedByteArray) -> void:
		var text := body.get_string_from_utf8()
		var s := LakeGauge.parse_dv_json(text) if ok and code == 200 else {"ok": false, "reason": "HTTP %d" % code}
		if not bool(s["ok"]):
			if not _series.is_empty():
				_gauge_status = "ready"   # yesterday's copy still stands
				changed.emit()
				return
			_gauge_fail("the gauge's daily values could not be read (%s)" % str(s.get("reason", "")))
			return
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GAUGE_DIR))
		var f := FileAccess.open(_series_path(), FileAccess.WRITE)
		if f != null:
			f.store_string(text)
		_series = s
		_gauge_status = "ready"
		_gauge_note = ""
		print("ShorelineHistory: %s, %d daily levels %s to %s, NGVD29→NAVD88 %+.3f m" % [
			str(_gauge.get("name", "")), (s["days"] as PackedInt32Array).size(), s["first"], s["last"],
			float(_gauge.get("shift_m", 0.0))])
		if _loader != null and _loader.has_method("_attach_water"):
			_loader.call("_attach_water")
		_apply_level(true)
		changed.emit())


func _gauge_fail(why: String) -> void:
	push_warning("ShorelineHistory: " + why)
	_gauge_status = "failed"
	_gauge_note = why
	changed.emit()


## True when the gauge plane is drawing the lake (its OSM body is left out).
func lake_plane_active() -> bool:
	return _lake_level_on() and bool(_series.get("ok", false)) and _gauge.has("shift_m")


## The still bodies WaterBuilder should draw: every one except the gauged
## lake's while the level plane stands in for it. Remembers the lake's bodies
## and rebuilds the plane from them.
func filter_still(still: Array) -> Array:
	_lake_items = _find_lake_items(still)
	if not lake_plane_active() or _lake_items.is_empty():
		_free_plane()
		return still
	var out: Array = []
	for it in still:
		if not _lake_items.has(it):
			out.append(it)
	_build_plane()
	return out


func _find_lake_items(still: Array) -> Array:
	if _gauge.is_empty():
		return []
	var lake_name := str(_gauge.get("lake", "")).to_lower()
	var named: Array = []
	var biggest: Dictionary = {}
	var big_area := 0.0
	for it_v in still:
		if not (it_v is Dictionary):
			continue
		var it: Dictionary = it_v
		if bool(it.get("user", false)) or str(it.get("kind", "")) in WaterBuilder.FLOWING_KINDS:
			continue
		var poly: PackedVector2Array = it.get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var nm := str((it.get("tags", {}) as Dictionary).get("name", "")).to_lower()
		if not lake_name.is_empty() and not nm.is_empty() and (nm.find(lake_name) >= 0 or lake_name.find(nm) >= 0):
			named.append(it)
			continue
		var a := absf(_poly_area(poly))
		if a > big_area:
			big_area = a
			biggest = it
	if not named.is_empty():
		return named
	return [biggest] if big_area >= LAKE_MIN_AREA_M2 else []


static func _poly_area(p: PackedVector2Array) -> float:
	var s := 0.0
	for i in p.size():
		var a := p[i]
		var b := p[(i + 1) % p.size()]
		s += a.x * b.y - b.x * a.y
	return s * 0.5


func _build_plane() -> void:
	_free_plane()
	var terrain: Node3D = null
	if _loader != null and _loader.get("_main") != null:
		terrain = (_loader.get("_main") as Node).get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base := 0
	for it_v in _lake_items:
		var poly: PackedVector2Array = (it_v as Dictionary).get("points", PackedVector2Array())
		for grown in Geometry2D.offset_polygon(poly, PLANE_MARGIN_M, Geometry2D.JOIN_ROUND):
			var tris := Geometry2D.triangulate_polygon(grown)
			if tris.is_empty():
				continue
			for p in grown:
				st.set_normal(Vector3.UP)
				st.set_uv(p)
				st.add_vertex(Vector3(p.x, 0.0, p.y))
			for t in tris:
				st.add_index(base + t)
			base += grown.size()
	if base == 0:
		return
	_plane = MeshInstance3D.new()
	_plane.name = "LakeLevel"
	_plane.mesh = st.commit()
	_plane.material_override = WaterBuilder._make_water_material()
	_plane.layers = WaterBuilder.WATER_RENDER_LAYER
	_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	terrain.add_child(_plane)
	_dem_water_m = _measure_dem_water()
	_start_spill()
	_apply_level(true)


func _free_plane() -> void:
	_spill_gen += 1
	_spill_row = -1
	_spill_ready = false
	if _plane != null and is_instance_valid(_plane):
		_plane.get_parent().remove_child(_plane)
		_plane.queue_free()
	_plane = null


## The DEM's own lake surface near the site (NAVD88 m): the 10th-percentile
## ground height inside the lake outline within 2 km of the site centre.
func _measure_dem_water() -> float:
	if _loader == null or not _loader.has_method("_ground_height_at"):
		return NAN
	var hs: Array = []
	for it_v in _lake_items:
		var poly: PackedVector2Array = (it_v as Dictionary).get("points", PackedVector2Array())
		for gx in range(-20, 21):
			for gz in range(-20, 21):
				var p := Vector2(gx * 100.0, gz * 100.0)
				if Geometry2D.is_point_in_polygon(p, poly):
					hs.append(float(_loader.call("_ground_height_at", p.x, p.y)))
	if hs.is_empty():
		return NAN
	hs.sort()
	return float(hs[int(hs.size() * 0.1)]) + _center_elev()


func dem_water_m() -> float:
	return _dem_water_m


func _center_elev() -> float:
	return float(_loader.get("_built_center_elev")) if _loader != null else 0.0


func _apply_level(force: bool = false) -> void:
	if not bool(_series.get("ok", false)):
		_level_m = NAN
		if _plane != null:
			_plane.visible = false
		return
	var day := _clock_day()
	var lv := LakeGauge.level_at(_series["days"], _series["ft"], day)
	var m := LakeGauge.navd88_m(float(lv["ft"]), str(_gauge.get("param", "")), float(_gauge.get("shift_m", 0.0)))
	if not force and is_equal_approx(m, _level_m):
		return
	_level_m = m
	_level_info = lv
	if _plane != null and is_instance_valid(_plane):
		_plane.visible = lake_plane_active()
		_plane.position.y = drawn_level_m() - _center_elev() + WaterBuilder.SURFACE_OFFSET_M
		var mat := _plane.material_override as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("spill_level", drawn_level_m() - _center_elev())


## The level the plane is drawn at: the gauge's, but never under the DEM's own
## flat lake — the ground model holds no ground below the water it was
## surveyed at, so a lower level would hide the lake entirely.
func drawn_level_m() -> float:
	if is_nan(_level_m):
		return NAN
	return _level_m if is_nan(_dem_water_m) else maxf(_level_m, _dem_water_m)


## True when the clock's level is below what the DEM can show.
func level_below_dem() -> bool:
	return not is_nan(_level_m) and not is_nan(_dem_water_m) and _level_m < _dem_water_m - 0.01


# ---------------------------------------------------------------------------
# The clock
# ---------------------------------------------------------------------------

func _clock_hours() -> float:
	var main: Node = _loader.get("_main") if _loader != null else null
	if main != null and main.has_method("get_absolute_hours"):
		return float(main.call("get_absolute_hours"))
	var d := Time.get_date_dict_from_system()
	return float(LakeGauge.abs_day(int(d["year"]), int(d["month"]), int(d["day"]))) * 24.0


func _clock_day() -> float:
	return _clock_hours() / 24.0


func _clock_date() -> String:
	return LakeGauge.date_of(int(floor(_clock_day())))


func _process(delta: float) -> void:
	if _spill_row >= 0:
		_sample_spill_rows()
	_tick += delta
	if _tick < 0.1:
		return
	_tick = 0.0
	if lake_plane_active():
		_apply_level()
	# A capture not on disk when the world loaded is fetched once it has.
	if _loader != null and bool(_loader.get("_history_deferred")) \
			and not bool(_loader.get("_load_sequence_active")) and bool(_loader.get("_built")):
		_loader.call("refresh_history_drape")
		return
	if str(_rec["mode"]) == "follow" and _captures_status == "ready":
		var want := _wanted_release()
		if want == _requested_release:
			_follow_want = want
			return
		var now := Time.get_ticks_msec() / 1000.0
		if want != _follow_want:
			_follow_want = want
			_follow_since = now
			return
		if now - _follow_since >= FOLLOW_SETTLE_S:
			_refresh_drape_if_needed()


# ---------------------------------------------------------------------------
# HTTP: one request at a time, Godot's own User-Agent (see WaybackCatalog).
# ---------------------------------------------------------------------------

func _fetch(url: String, cb: Callable) -> void:
	_queue.append({"url": url, "cb": cb})
	_pump()


func _pump() -> void:
	if _busy or _queue.is_empty() or _http == null:
		return
	if _IMAGERY.offline_for_test:
		var job: Dictionary = _queue.pop_front()
		(job["cb"] as Callable).call_deferred(false, 0, PackedByteArray())
		return
	_busy = true
	var err := _http.request(str((_queue[0] as Dictionary)["url"]))
	if err != OK:
		_busy = false
		var job2: Dictionary = _queue.pop_front()
		(job2["cb"] as Callable).call(false, 0, PackedByteArray())
		_pump()


func _on_http_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if _queue.is_empty():
		return
	var job: Dictionary = _queue.pop_front()
	(job["cb"] as Callable).call(result == HTTPRequest.RESULT_SUCCESS, code, body)
	_pump()


# ---------------------------------------------------------------------------
# The reach mask
# ---------------------------------------------------------------------------

func _start_spill() -> void:
	_spill_gen += 1
	_spill_ready = false
	var dh := float(_loader.get("_detail_half_extent")) if _loader != null else 1500.0
	_spill_half = clampf(dh + 1000.0, 1500.0, SPILL_MAX_HALF_M)
	_spill_n = LakeSpill.grid_n(_spill_half, SPILL_CELL_M)
	_spill_h = PackedFloat32Array()
	_spill_h.resize(_spill_n * _spill_n)
	_spill_row = 0


func _sample_spill_rows() -> void:
	if _loader == null or _plane == null or not is_instance_valid(_plane):
		_spill_row = -1
		return
	var t0 := Time.get_ticks_usec()
	var n := _spill_n
	var cell := 2.0 * _spill_half / float(n - 1)
	while _spill_row < n:
		var z := -_spill_half + float(_spill_row) * cell
		for c in n:
			_spill_h[_spill_row * n + c] = float(_loader.call("_ground_height_at", -_spill_half + float(c) * cell, z))
		_spill_row += 1
		if float(Time.get_ticks_usec() - t0) / 1000.0 > SPILL_FRAME_MS:
			return
	_spill_row = -1
	if is_nan(_dem_water_m):
		return
	var gen := _spill_gen
	var h := _spill_h
	var half := _spill_half
	var outlines: Array = []
	for it_v in _lake_items:
		outlines.append((it_v as Dictionary).get("points", PackedVector2Array()))
	var water_y := _dem_water_m - _center_elev()
	var task := func() -> void:
		var sd := LakeSpill.seeds(h, n, half, outlines, water_y)
		var sp := LakeSpill.spill(h, n, sd)
		_spill_done.call_deferred(gen, sp)
	_spill_task = WorkerThreadPool.add_task(task, false, "lake_spill")


func _spill_done(gen: int, sp: PackedFloat32Array) -> void:
	if _spill_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_spill_task)
		_spill_task = -1
	if gen != _spill_gen or _plane == null or not is_instance_valid(_plane):
		return
	_spill = sp
	_spill_ready = true
	var n := _spill_n
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RF, sp.to_byte_array())
	var mat := _plane.material_override as ShaderMaterial
	if mat != null:
		var size := 2.0 * _spill_half
		mat.set_shader_parameter("spill_tex", ImageTexture.create_from_image(img))
		mat.set_shader_parameter("spill_rect", Vector4(-_spill_half, -_spill_half, 1.0 / size, 1.0 / size))
		mat.set_shader_parameter("use_spill", true)
	print("ShorelineHistory: lake reach mask %dx%d at %.1f m over a %.0f m square" % [n, n,
		2.0 * _spill_half / float(n - 1), 2.0 * _spill_half])
	_apply_level(true)
	changed.emit()


## Whether the lake's water stands at world (x, z) now (the reach mask when it
## is ready, else plain "ground below the level").
func wet_at(x: float, z: float) -> bool:
	if is_nan(_level_m) or _loader == null:
		return false
	var y := drawn_level_m() - _center_elev()
	if _spill_ready:
		var s := LakeSpill.spill_at(_spill, _spill_n, _spill_half, x, z)
		if not is_nan(s):
			return s < y
	return float(_loader.call("_ground_height_at", x, z)) < y


func spill_ready() -> bool:
	return _spill_ready


# ---------------------------------------------------------------------------
# The shore band: where vegetation scatter keeps off
# ---------------------------------------------------------------------------

## Beach above the highest reading, kept clear as well.
const SHORE_MARGIN_M := 0.5
var _max_level_m := NAN
var _max_level_n := -1


## The highest level in the gauge record (NAVD88 m); NAN without a series.
func max_level_m() -> float:
	if not bool(_series.get("ok", false)):
		return NAN
	var ft: PackedFloat64Array = _series["ft"]
	if ft.size() != _max_level_n:
		_max_level_n = ft.size()
		var hi := -INF
		for v in ft:
			if is_finite(v):
				hi = maxf(hi, v)
		_max_level_m = NAN if hi == -INF else LakeGauge.navd88_m(hi, str(_gauge.get("param", "")),
			float(_gauge.get("shift_m", 0.0)))
	return _max_level_m


## True once in_shore answers from the reach mask and the gauge record.
func shore_ready() -> bool:
	return _spill_ready and not is_nan(max_level_m()) and not is_nan(_dem_water_m)


## Changes when the shore band would: the record's top and the mask.
func shore_signature() -> String:
	if not shore_ready():
		return ""
	return "%.2f|%.2f|%d" % [max_level_m(), _dem_water_m, _spill_n]


## Whether world (x, z) is ground the lake has covered at any time in its
## gauge record (or covers now), plus SHORE_MARGIN_M of beach. The photos of
## those years show the shallows dark green, and the auto scatter's gap fill
## read them as forest; nothing should be planted there. False before the
## reach mask is ready, and outside it.
func in_shore(x: float, z: float) -> bool:
	if not shore_ready():
		return false
	var y := maxf(max_level_m(), _dem_water_m) - _center_elev() + SHORE_MARGIN_M
	var s := LakeSpill.spill_at(_spill, _spill_n, _spill_half, x, z)
	return not is_nan(s) and s < y


func _exit_tree() -> void:
	if _spill_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_spill_task)
		_spill_task = -1
