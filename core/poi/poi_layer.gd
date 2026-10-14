class_name PoiLayer
extends RefCounted

## Per-site POINTS OF INTEREST — the pins a player marked in Google Earth
## (a hydro inlet, the pond outlet, the yurt clearing) imported from a KML so
## they can be found in the world instead of guessed at.
##
## One file per site, through WorldPaths like every other world layer:
##   user://maps/poi_<lat>_<lon>.json   (generated maps, no / legacy world)
##   user://worlds/<id>/poi.json        (dir worlds)
##
## A record is a point, a line or a polygon in WGS84 — the import keeps the
## file's own coordinates and the runtime converts to site metres at build
## time, so a site whose centre moves (a re-registered map) still puts the
## pin on the right ground. `lat`/`lon` on a line or polygon is its centroid:
## where the label stands and where "Go to" lands.
##
## Re-importing a file REPLACES that file's records (keyed by `source`), so a
## pin edited in Google Earth and exported again moves instead of doubling.
## Ids are stable across re-imports (hash of source + KML id + index).

const VERSION := 1
const KIND := "poi"

var records: Array = []   # Array[Dictionary]


static func create_empty() -> PoiLayer:
	return PoiLayer.new()


static func save_path_for_map(lat: float, lon: float) -> String:
	return WorldPaths.site_file(KIND, lat, lon)


static func save_path_for_scene(scene_key: String) -> String:
	return WorldPaths.scene_file(KIND, scene_key)


func load_from(path: String) -> bool:
	records.clear()
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return false
	return deserialize(parsed)


func save_to(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("PoiLayer: cannot write %s" % path)
		return false
	f.store_string(JSON.stringify(serialize(), "\t"))
	f.close()
	return true


func serialize() -> Dictionary:
	return {"version": VERSION, "records": records.duplicate(true)}


func deserialize(d: Dictionary) -> bool:
	records.clear()
	var arr: Variant = d.get("records", [])
	if not (arr is Array):
		return false
	for r_v in arr:
		if not (r_v is Dictionary):
			continue
		var r: Dictionary = (r_v as Dictionary).duplicate(true)
		if not _valid_record(r):
			continue
		records.append(r)
	return true


## Add every placemark of a KmlPoiParser result under `source` (the file's
## name), replacing whatever that source imported before. Returns
## {added, replaced, skipped}.
func import_kml(parsed: Dictionary, source: String) -> Dictionary:
	var replaced := remove_source(source)
	var added := 0
	var skipped := 0
	var pms: Array = parsed.get("placemarks", [])
	for i in pms.size():
		var pm: Dictionary = pms[i]
		var rec := record_from_placemark(pm, source, i)
		if rec.is_empty():
			skipped += 1
			continue
		records.append(rec)
		added += 1
	return {"added": added, "replaced": replaced, "skipped": skipped}


## One KmlPoiParser placemark → one layer record ({} when it has no usable
## geometry). Pure; the selftest pins it.
static func record_from_placemark(pm: Dictionary, source: String, index: int) -> Dictionary:
	var kind := str(pm.get("kind", KmlPoiParser.KIND_POINT))
	var coords: Array = pm.get("coords", [])
	if coords.is_empty():
		return {}
	var pts: Array = []
	var lat_sum := 0.0
	var lon_sum := 0.0
	# Parser tuples are [lon, lat, alt] float Arrays (64-bit — never Vector3,
	# which is float32 and rounds a longitude by about a metre on the ground).
	for c_v in coords:
		if not (c_v is Array) or (c_v as Array).size() < 2:
			continue
		var c: Array = c_v
		pts.append([float(c[1]), float(c[0])])
		lat_sum += float(c[1])
		lon_sum += float(c[0])
	if pts.is_empty():
		return {}
	var n := float(pts.size())
	var rec := {
		"id": stable_id(source, str(pm.get("kml_id", "")), index),
		"source": source,
		"kml_id": str(pm.get("kml_id", "")),
		"name": str(pm.get("name", "")).strip_edges(),
		"desc": str(pm.get("description", "")),
		"folder": str(pm.get("folder", "")),
		"kind": kind,
		"lat": lat_sum / n,
		"lon": lon_sum / n,
		"alt": float((coords[0] as Array)[2]) if kind == KmlPoiParser.KIND_POINT and (coords[0] as Array).size() >= 3 else 0.0,
		"color": str(pm.get("color", "")),
	}
	if kind != KmlPoiParser.KIND_POINT:
		rec["points"] = pts
	if rec["name"].is_empty():
		rec["name"] = "Pin %d" % (index + 1)
	return rec


static func stable_id(source: String, kml_id: String, index: int) -> String:
	var key := "%s|%s|%d" % [source, kml_id, index]
	return "poi_%08x" % (hash(key) & 0xFFFFFFFF)


func get_record(id: String) -> Dictionary:
	for r in records:
		if str(r.get("id", "")) == id:
			return r
	return {}


func remove(id: String) -> bool:
	for i in records.size():
		if str(records[i].get("id", "")) == id:
			records.remove_at(i)
			return true
	return false


func remove_source(source: String) -> int:
	var kept: Array = []
	var dropped := 0
	for r in records:
		if str(r.get("source", "")) == source:
			dropped += 1
		else:
			kept.append(r)
	records = kept
	return dropped


func clear() -> void:
	records.clear()


func sources() -> Array:
	var out: Array = []
	for r in records:
		var s := str(r.get("source", ""))
		if not out.has(s):
			out.append(s)
	return out


func count() -> int:
	return records.size()


## Site-relative metres (+X east, +Z south) of a record's anchor.
static func world_xz(rec: Dictionary, center_lat: float, center_lon: float) -> Vector2:
	return GeoMath.lonlat_to_local_m(float(rec.get("lat", 0.0)), float(rec.get("lon", 0.0)),
		center_lat, center_lon)


## Site-relative metres of a line / polygon record's vertices (empty for a point).
static func points_world_xz(rec: Dictionary, center_lat: float, center_lon: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var pts: Variant = rec.get("points", [])
	if not (pts is Array):
		return out
	for p_v in pts:
		if p_v is Array and (p_v as Array).size() >= 2:
			out.append(GeoMath.lonlat_to_local_m(float(p_v[0]), float(p_v[1]), center_lat, center_lon))
	return out


## The record's colour as a Color, or the default for its kind.
static func color_of(rec: Dictionary) -> Color:
	var c := str(rec.get("color", ""))
	if c.length() == 7 and c.begins_with("#") and Color.html_is_valid(c):
		return Color.html(c)
	return Color(0.16, 0.55, 0.95) if str(rec.get("kind", "")) == KmlPoiParser.KIND_POINT \
		else Color(1.0, 0.72, 0.2)


static func _valid_record(r: Dictionary) -> bool:
	if str(r.get("id", "")).is_empty():
		return false
	var lat: Variant = r.get("lat", null)
	var lon: Variant = r.get("lon", null)
	if not (lat is float or lat is int) or not (lon is float or lon is int):
		return false
	if not is_finite(float(lat)) or not is_finite(float(lon)):
		return false
	if absf(float(lat)) > 90.0 or absf(float(lon)) > 180.0:
		return false
	var kind := str(r.get("kind", KmlPoiParser.KIND_POINT))
	if kind != KmlPoiParser.KIND_POINT:
		var pts: Variant = r.get("points", [])
		if not (pts is Array) or (pts as Array).size() < 2:
			return false
	if not r.has("kind"):
		r["kind"] = KmlPoiParser.KIND_POINT
	if not r.has("name"):
		r["name"] = ""
	return true
