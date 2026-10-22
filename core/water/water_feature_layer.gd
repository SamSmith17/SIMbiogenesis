class_name WaterFeatureLayer
extends RefCounted

## The player's water features for one map, persisted to
## `user://maps/water_features_<lat>_<lon>.json`.
##
## Three things live here, and nothing else does:
##   * `streams`  — streams the player drew, traced or promoted from the derived
##                  drainage network. Points are world XZ in DOWNSTREAM order.
##   * `osm`      — sparse OVERRIDES of OSM waterways, keyed by OSM way id
##                  (string): a re-route, a cross-section, carve on/off, hidden,
##                  span modes. The OSM data itself is never copied in, so a
##                  re-fetch that improves the map still shows through.
##   * `settings` — map-wide knobs: carve on/off, per-kind cross-sections, the
##                  drainage threshold, the water display mode.
##
## A span is the segment between two consecutive points; `modes[i]` is the
## mode of segment i (points[i] → points[i+1]): "surface" (open channel),
## "culvert" (gravity barrel under the ground), "pipe" (pressurised, may
## rise while there is net head) or "penstock" — the reach is DIVERTED into a
## poly penstock feeding a turbine on the systems graph: the water system
## draws nothing there (no channel, no barrel); the graph's routed
## `poly_penstock` conduit is the visual and the flow engine takes the
## stream's discharge at the intake station. `modes.size() == points.size() - 1`.

const VERSION := 1
const MODES := ["surface", "culvert", "pipe", "penstock"]
const MODE_PENSTOCK := "penstock"
const MIN_POINTS := 2

var streams: Array = []
var osm: Dictionary = {}
var settings: Dictionary = {}
var next_id: int = 1
## Depth (m) floods have cut into each feature's bed, per resolved feature id,
## one value per ChannelProfile.EROSION_STEP_M of arc. Added to the carved
## depth; "Reset erosion" (View tool) clears it.
var erosion: Dictionary = {}


func erosion_of(fid: String) -> PackedFloat32Array:
	var e: Variant = erosion.get(fid, null)
	return e if e is PackedFloat32Array else PackedFloat32Array()


static func save_path_for_map(lat: float, lon: float) -> String:
	return WorldPaths.site_file("water_features", lat, lon)


static func default_settings() -> Dictionary:
	return {
		"carve_enabled": true,
		# Per-kind cross-section overrides ({} = StreamNetwork.KIND_SECTIONS).
		"kind_sections": {},
		# Smallest catchment (ha) the derived drainage network draws.
		"min_catchment_ha": 2.0,
		"show_drainage": false,
		# "osm" | "all" | "flow" | "off"
		"display_mode": "all",
		"show_buried": false,
		# StreamCurve knobs for every stream without its own (0..1).
		"curve_smooth": 0.0,
		"curve_meander": 0.0,
		# Streams without a base flow of their own run only when rain reaches them.
		"dry_between_storms": false,
	}


func setting(key: String) -> Variant:
	if settings.has(key):
		return settings[key]
	return default_settings().get(key)


func set_setting(key: String, value: Variant) -> void:
	settings[key] = value


# ---------------------------------------------------------------------------
# Streams
# ---------------------------------------------------------------------------

## Add a stream; returns its id. `points` world XZ, downstream order.
func add_stream(points: PackedVector2Array, fields: Dictionary = {}) -> String:
	if points.size() < MIN_POINTS:
		return ""
	var id := "ws_%d" % next_id
	next_id += 1
	var rec := {
		"id": id,
		"name": str(fields.get("name", "Stream %d" % (next_id - 1))),
		"source": str(fields.get("source", "user")),
		"kind": str(fields.get("kind", "stream")),
		"points": points,
		"modes": _fit_modes(fields.get("modes", []), points.size()),
		"section": (fields.get("section", {}) as Dictionary).duplicate(),
		"base_lps": float(fields.get("base_lps", -1.0)),
		"carve": bool(fields.get("carve", true)),
	}
	streams.append(rec)
	return id


func stream(id: String) -> Dictionary:
	for s in streams:
		if str((s as Dictionary).get("id", "")) == id:
			return s
	return {}


func remove_stream(id: String) -> bool:
	for i in streams.size():
		if str((streams[i] as Dictionary).get("id", "")) == id:
			streams.remove_at(i)
			return true
	return false


## Patch a stream. `points` re-fits `modes` (new spans copy their neighbour).
func update_stream(id: String, patch: Dictionary) -> bool:
	var rec := stream(id)
	if rec.is_empty():
		return false
	for k in patch.keys():
		if k == "id":
			continue
		if patch[k] == null:
			rec.erase(k)
		else:
			rec[k] = patch[k]
	var pts: PackedVector2Array = rec.get("points", PackedVector2Array())
	rec["modes"] = _fit_modes(rec.get("modes", []), pts.size())
	return true


# ---------------------------------------------------------------------------
# OSM overrides
# ---------------------------------------------------------------------------

func osm_override(osm_id: int) -> Dictionary:
	return osm.get(str(osm_id), {})


func set_osm_override(osm_id: int, patch: Dictionary) -> void:
	var key := str(osm_id)
	var cur: Dictionary = osm.get(key, {})
	for k in patch.keys():
		if patch[k] == null:
			cur.erase(k)
		else:
			cur[k] = patch[k]
	if cur.has("points"):
		var pts: PackedVector2Array = cur["points"]
		cur["modes"] = _fit_modes(cur.get("modes", []), pts.size())
	if cur.is_empty():
		osm.erase(key)
	else:
		osm[key] = cur


func clear_osm_override(osm_id: int) -> void:
	osm.erase(str(osm_id))


# ---------------------------------------------------------------------------
# Span modes + waypoint edits (shared by user streams and OSM re-routes)
# ---------------------------------------------------------------------------

## A modes array fitted to `n_points` (n-1 spans): extra entries dropped,
## missing ones copy the last ("surface" when there is none), unknown values
## become "surface".
static func _fit_modes(modes_v: Variant, n_points: int) -> Array:
	var out: Array = []
	var src: Array = modes_v if modes_v is Array else (Array(modes_v) if modes_v is PackedStringArray else [])
	var want := maxi(n_points - 1, 0)
	for i in want:
		var m := str(src[i]) if i < src.size() else (str(out.back()) if not out.is_empty() else "surface")
		out.append(m if m in MODES else "surface")
	return out


## Insert a point AFTER index `after` (so it splits span `after`); the two new
## spans keep the split span's mode. Returns the new (points, modes).
static func insert_point(points: PackedVector2Array, modes: Array, after: int,
		p: Vector2) -> Dictionary:
	var pts := points.duplicate()
	var ms := _fit_modes(modes, points.size())
	var i := clampi(after, 0, pts.size() - 1)
	pts.insert(i + 1, p)
	var m := str(ms[i]) if i < ms.size() else "surface"
	ms.insert(mini(i, ms.size()), m)
	return {"points": pts, "modes": _fit_modes(ms, pts.size())}


## Remove point `idx` (never below MIN_POINTS). The merged span takes the mode
## of the span BEFORE the removed point (the first span when idx == 0).
static func remove_point(points: PackedVector2Array, modes: Array, idx: int) -> Dictionary:
	if points.size() <= MIN_POINTS or idx < 0 or idx >= points.size():
		return {"points": points, "modes": _fit_modes(modes, points.size())}
	var pts := points.duplicate()
	var ms := _fit_modes(modes, points.size())
	pts.remove_at(idx)
	# Removing interior point idx merges spans idx-1 and idx → keep idx-1.
	if idx >= ms.size():
		ms.remove_at(ms.size() - 1)
	else:
		ms.remove_at(idx)
	return {"points": pts, "modes": _fit_modes(ms, pts.size())}


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func serialize() -> Dictionary:
	var out_streams: Array = []
	for s in streams:
		var d: Dictionary = (s as Dictionary).duplicate(true)
		d["points"] = _ser_points(d.get("points", PackedVector2Array()))
		out_streams.append(d)
	var out_osm := {}
	for k in osm.keys():
		var d: Dictionary = (osm[k] as Dictionary).duplicate(true)
		if d.has("points"):
			d["points"] = _ser_points(d["points"])
		out_osm[k] = d
	var out_ero := {}
	for k in erosion.keys():
		var arr: Array = []
		for v in (erosion[k] as PackedFloat32Array):
			arr.append(snappedf(v, 0.001))
		out_ero[k] = arr
	return {"version": VERSION, "next_id": next_id, "streams": out_streams,
		"osm": out_osm, "settings": settings.duplicate(true), "erosion": out_ero}


func deserialize(d: Dictionary) -> void:
	streams = []
	osm = {}
	erosion = {}
	var ero_in: Variant = d.get("erosion", {})
	if ero_in is Dictionary:
		for k in (ero_in as Dictionary).keys():
			var arr := PackedFloat32Array()
			for v in ((ero_in as Dictionary)[k] as Array):
				arr.append(float(v))
			erosion[str(k)] = arr
	settings = (d.get("settings", {}) as Dictionary).duplicate(true) if d.get("settings") is Dictionary else {}
	next_id = maxi(int(d.get("next_id", 1)), 1)
	for s in d.get("streams", []):
		if not (s is Dictionary):
			continue
		var rec: Dictionary = (s as Dictionary).duplicate(true)
		var pts := _deser_points(rec.get("points", []))
		if pts.size() < MIN_POINTS:
			continue
		rec["points"] = pts
		rec["modes"] = _fit_modes(rec.get("modes", []), pts.size())
		rec["id"] = str(rec.get("id", "ws_%d" % next_id))
		rec["section"] = rec.get("section", {}) if rec.get("section") is Dictionary else {}
		rec["base_lps"] = float(rec.get("base_lps", -1.0))
		rec["carve"] = bool(rec.get("carve", true))
		rec["kind"] = str(rec.get("kind", "stream"))
		rec["source"] = str(rec.get("source", "user"))
		streams.append(rec)
		var num := str(rec["id"]).trim_prefix("ws_")
		if num.is_valid_int():
			next_id = maxi(next_id, int(num) + 1)
	var osm_in: Variant = d.get("osm", {})
	if osm_in is Dictionary:
		for k in (osm_in as Dictionary).keys():
			var o: Variant = (osm_in as Dictionary)[k]
			if not (o is Dictionary):
				continue
			var rec2: Dictionary = (o as Dictionary).duplicate(true)
			if rec2.has("points"):
				var pts2 := _deser_points(rec2["points"])
				if pts2.size() < MIN_POINTS:
					rec2.erase("points")
					rec2.erase("modes")
				else:
					rec2["points"] = pts2
					rec2["modes"] = _fit_modes(rec2.get("modes", []), pts2.size())
			osm[str(k)] = rec2


func snapshot() -> Dictionary:
	return serialize()


func restore(snap: Dictionary) -> void:
	deserialize(snap)


func save_to(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(serialize()))
	return true


func load_from(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	deserialize(parsed)
	return true


static func _ser_points(v: Variant) -> Array:
	var out: Array = []
	if v is PackedVector2Array:
		for p in v as PackedVector2Array:
			out.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01)])
	return out


static func _deser_points(v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if v is PackedVector2Array:
		return v
	if v is Array:
		for pair in v:
			if pair is Array and (pair as Array).size() >= 2:
				out.append(Vector2(float(pair[0]), float(pair[1])))
	return out
