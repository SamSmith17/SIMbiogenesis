extends Node

## BuildingService (OsmiVectorService) — lazy-loads OSM buildings, highways, and
## optional landuse polygons via one Overpass request per site bbox.

signal osm_vectors_ready(key: String, payload: Dictionary)
signal buildings_ready(key: String, buildings: Array)
signal buildings_failed(reason: String)
signal buildings_progress(message: String)

const OVERPASS_URL := "https://overpass-api.de/api/interpreter"
const CACHE_DIR := "user://terrain_cache/osm_vectors"
## NOT bumped for the waterway centreline keys: a bump forces an Overpass
## refetch for every site the player ever visited, and Overpass is often 504 —
## the site would come back with no buildings. Caches written before the
## centreline keys existed are read back by DERIVING the centreline from the
## buffered ribbon (see _derive_centerline), so old sites still carve.
const CACHE_VERSION := "v6"
## Real OSM way ids are ~1.4e9 today; a derived (pre-osm_id cache) waterway
## gets a stable geometric id above this so it can never collide.
const PSEUDO_OSM_ID_BASE := 900000000000
const ATTRIBUTION := "© OpenStreetMap contributors"
const REQUEST_TIMEOUT := 60.0
const MAX_RETRIES := 3
const RETRY_BACKOFF := 4.0

const HIGHWAY_REGEX := "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|service|track|path|footway|pedestrian|living_street)$"

var _http: HTTPRequest = null
var _busy: bool = false
var _job: Dictionary = {}
var _pending: Dictionary = {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_http()


func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func attribution() -> String:
	return ATTRIBUTION


func request_buildings(lat: float, lon: float, half_extent_m: float) -> void:
	request_osm_vectors(lat, lon, half_extent_m)


func request_osm_vectors(lat: float, lon: float, half_extent_m: float,
		include_landuse: bool = false, force_refetch: bool = false) -> void:
	var req := {
		"lat": lat,
		"lon": lon,
		"half_extent_m": half_extent_m,
		"include_landuse": include_landuse,
		"force_refetch": force_refetch,
	}
	if _busy:
		_pending = req
		return
	_start_osm_job(req)


func _start_osm_job(req: Dictionary) -> void:
	var lat: float = float(req["lat"])
	var lon: float = float(req["lon"])
	var half_extent_m: float = float(req["half_extent_m"])
	var include_landuse: bool = bool(req.get("include_landuse", false))
	var force_refetch: bool = bool(req.get("force_refetch", false))
	var key := _cache_key(lat, lon, half_extent_m, include_landuse)
	var cache_path := "%s/%s.json" % [CACHE_DIR, key]
	if not force_refetch and TerrainCacheSettings.cache_enabled() \
			and FileAccess.file_exists(cache_path):
		var parsed: Variant = _load_cache(cache_path)
		if parsed is Dictionary:
			var payload: Dictionary = deserialize_payload(parsed as Dictionary)
			_emit_vectors_deferred(key, payload)
			return
	var bbox := GeoMath.bbox_for(lat, lon, half_extent_m)
	var s := float(bbox["south"])
	var w := float(bbox["west"])
	var n := float(bbox["north"])
	var e := float(bbox["east"])
	var landuse_q := ""
	if include_landuse:
		landuse_q = "way[\"landuse\"~\"^(residential|commercial|industrial)$\"](%f,%f,%f,%f);way[\"amenity\"=\"parking\"](%f,%f,%f,%f);way[\"leisure\"=\"pitch\"](%f,%f,%f,%f);" % [
			s, w, n, e, s, w, n, e, s, w, n, e]
	var water_q := (
		"way[\"natural\"=\"water\"](%f,%f,%f,%f);"
		+ "way[\"water\"](%f,%f,%f,%f);"
		+ "way[\"landuse\"=\"reservoir\"](%f,%f,%f,%f);"
		+ "way[\"natural\"=\"bay\"](%f,%f,%f,%f);"
		+ "way[\"waterway\"=\"riverbank\"](%f,%f,%f,%f);"
		+ "way[\"waterway\"~\"^(river|stream|canal|ditch|drain)$\"](%f,%f,%f,%f);"
		+ "relation[\"type\"=\"multipolygon\"][\"natural\"=\"water\"](%f,%f,%f,%f);"
		+ "relation[\"type\"=\"multipolygon\"][\"water\"](%f,%f,%f,%f);"
		+ "relation[\"type\"=\"multipolygon\"][\"landuse\"=\"reservoir\"](%f,%f,%f,%f);"
		+ "relation[\"natural\"=\"water\"](%f,%f,%f,%f);"
		+ "relation[\"water\"](%f,%f,%f,%f);"
	) % [
		# Exactly 11 bbox groups — one per water query line above (44 %f). A 13-group
		# list here throws "not all arguments converted", yielding a 400 from Overpass.
		s, w, n, e, s, w, n, e, s, w, n, e, s, w, n, e, s, w, n, e, s, w, n, e,
		s, w, n, e, s, w, n, e, s, w, n, e, s, w, n, e, s, w, n, e,
	]
	# Rooftop / ground PV arrays: power=generator with a solar source (or PV method).
	# Pulled as ways so we get the array footprint polygon (ROADMAP Pillar 1 — real
	# on-site generation). 8 %f = 2 bbox groups.
	var solar_q := (
		"way[\"power\"=\"generator\"][\"generator:source\"=\"solar\"](%f,%f,%f,%f);"
		+ "way[\"power\"=\"generator\"][\"generator:method\"=\"photovoltaic\"](%f,%f,%f,%f);"
	) % [s, w, n, e, s, w, n, e]
	var query := "[out:json][timeout:60];(way[\"building\"](%f,%f,%f,%f);way[\"highway\"~\"%s\"](%f,%f,%f,%f);%s%s%s);out body;>;out skel qt;" % [
		s, w, n, e, HIGHWAY_REGEX, s, w, n, e, solar_q, landuse_q, water_q]
	_job = {
		"key": key,
		"cache_path": cache_path,
		"lat": lat,
		"lon": lon,
		"half_extent_m": half_extent_m,
		"include_landuse": include_landuse,
		"query": query,
		"retries": 0,
	}
	_busy = true
	buildings_progress.emit("Fetching OSM vectors …")
	_post_query(query)


func _post_query(query: String) -> void:
	_ensure_http()
	var headers := PackedStringArray([
		"Content-Type: application/x-www-form-urlencoded",
		"User-Agent: SIMbiogenesis-Terrain/1.0",
	])
	var body := "data=%s" % query.uri_encode()
	var err := _http.request(OVERPASS_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_fail("HTTPRequest error %d" % err)


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	if _job.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_retry_or_fail("network error %d" % result)
		return
	if response_code == 429 or response_code >= 500:
		_retry_or_fail("HTTP %d" % response_code)
		return
	if response_code != 200:
		_fail("HTTP %d" % response_code)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		_fail("invalid Overpass JSON")
		return
	var payload := _parse_overpass(parsed as Dictionary,
		float(_job["lat"]), float(_job["lon"]), bool(_job.get("include_landuse", false)))
	_save_cache(str(_job["cache_path"]), payload)
	var key := str(_job["key"])
	_busy = false
	_job = {}
	_emit_vectors_deferred(key, payload)
	_start_pending()


func _emit_vectors_deferred(key: String, payload: Dictionary) -> void:
	call_deferred("_emit_vectors", key, payload)


func _emit_vectors(key: String, payload: Dictionary) -> void:
	osm_vectors_ready.emit(key, payload)
	buildings_ready.emit(key, payload.get("buildings", []) as Array)
	_start_pending()


func _start_pending() -> void:
	if _pending.is_empty() or _busy:
		return
	var req: Dictionary = _pending
	_pending = {}
	_start_osm_job(req)


func _retry_or_fail(reason: String) -> void:
	var retries := int(_job.get("retries", 0)) + 1
	_job["retries"] = retries
	if retries > MAX_RETRIES:
		_fail("%s after %d retries" % [reason, MAX_RETRIES])
		return
	buildings_progress.emit("Retrying OSM vectors (%s) …" % reason)
	var timer := get_tree().create_timer(RETRY_BACKOFF * float(retries))
	var query: String = str(_job.get("query", ""))
	timer.timeout.connect(func() -> void:
		if _busy and not _job.is_empty() and query != "":
			_post_query(str(query))
	, CONNECT_ONE_SHOT)


func _fail(reason: String) -> void:
	_busy = false
	_job = {}
	buildings_failed.emit(reason)
	_start_pending()


static func _cache_key(lat: float, lon: float, half_extent_m: float, landuse: bool) -> String:
	return "osm_%s_%.4f_%.4f_%d%s" % [
		CACHE_VERSION, lat, lon, int(half_extent_m), "_lu" if landuse else ""]


static func _load_cache(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


static func _save_cache(path: String, payload: Dictionary) -> void:
	if not TerrainCacheSettings.cache_enabled():
		return
	var serial := _serialize_payload(payload)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(serial))


static func _serialize_payload(payload: Dictionary) -> Dictionary:
	var out := {"version": CACHE_VERSION, "buildings": [], "roads": [], "landuse": [],
		"water": [], "solar": []}
	for b in payload.get("buildings", []):
		if b is Dictionary:
			out["buildings"].append(_ser_item(b))
	for r in payload.get("roads", []):
		if r is Dictionary:
			out["roads"].append(_ser_item(r))
	for l in payload.get("landuse", []):
		if l is Dictionary:
			out["landuse"].append(_ser_item(l))
	for w in payload.get("water", []):
		if w is Dictionary:
			out["water"].append(_ser_item(w))
	for sol in payload.get("solar", []):
		if sol is Dictionary:
			out["solar"].append(_ser_item(sol))
	return out


static func _ser_item(d: Dictionary) -> Dictionary:
	var pts: PackedVector2Array = d.get("points", PackedVector2Array())
	var arr: Array = []
	for p in pts:
		arr.append([p.x, p.y])
	var item := {
		"points": arr,
		"tags": d.get("tags", {}),
	}
	for k in ["height_m", "half_width_m", "highway_type", "kind", "idx", "area_m2"]:
		if d.has(k):
			item[k] = d[k]
	if d.has("roof"):
		item["roof"] = d["roof"]
	# Waterway lines (v7): the centreline + width + identity the stream network
	# carves and renders from. Before v7 these were dropped on every cached
	# reload, so a revisited site lost its river centrelines.
	if d.has("centerline") and d["centerline"] is PackedVector2Array:
		var cl: Array = []
		for p in d["centerline"] as PackedVector2Array:
			cl.append([p.x, p.y])
		item["centerline"] = cl
	for k in ["half_width", "osm_id", "culvert", "covered"]:
		if d.has(k):
			item[k] = d[k]
	return item


static func deserialize_payload(raw: Dictionary) -> Dictionary:
	var out := {"buildings": [], "roads": [], "landuse": [], "water": [], "solar": []}
	for key in ["buildings", "roads", "landuse", "water", "solar"]:
		var idx := 0
		for item in raw.get(key, []):
			if item is Dictionary:
				var parsed := _deser_item(item as Dictionary, key)
				if key == "buildings" and not parsed.has("idx"):
					parsed["idx"] = idx
				(out[key] as Array).append(parsed)
				idx += 1
	return out


static func _deser_item(d: Dictionary, kind: String) -> Dictionary:
	var pts := PackedVector2Array()
	for pair in d.get("points", []):
		if pair is Array and (pair as Array).size() >= 2:
			pts.append(Vector2(
				TerrainBuilder.variant_to_float(pair[0]), TerrainBuilder.variant_to_float(pair[1])))
	var tags: Dictionary = d.get("tags", {})
	var item := {"points": pts, "tags": tags}
	if kind == "buildings":
		if d.has("idx"):
			item["idx"] = int(d["idx"])
		if not tags.is_empty():
			item["height_m"] = BuildingBuilder.parse_height_m(tags)
			item["roof"] = BuildingBuilder.infer_roof_spec(tags, pts)
		else:
			item["height_m"] = TerrainBuilder.dict_float(d, "height_m", BuildingBuilder.DEFAULT_HEIGHT_M)
			if d.has("roof"):
				item["roof"] = d["roof"]
	elif kind == "roads":
		item["half_width_m"] = TerrainBuilder.dict_float(d, "half_width_m", 4.0)
		item["highway_type"] = str(d.get("highway_type", "residential"))
	elif kind == "water":
		item["kind"] = str(d.get("kind", "water"))
		if not d.has("centerline") and OsmWaterParser.is_waterway_line_tags(tags):
			var derived := _derive_centerline(pts)
			if not derived.is_empty():
				item["centerline"] = derived["centerline"]
				item["half_width"] = float(derived["half_width"])
				item["osm_id"] = _pseudo_osm_id(derived["centerline"])
				if OsmWaterParser.is_culvert_tags(tags):
					item["culvert"] = true
		if d.has("centerline"):
			var cl := PackedVector2Array()
			for pair in d.get("centerline", []):
				if pair is Array and (pair as Array).size() >= 2:
					cl.append(Vector2(TerrainBuilder.variant_to_float(pair[0]),
						TerrainBuilder.variant_to_float(pair[1])))
			item["centerline"] = cl
			item["half_width"] = TerrainBuilder.dict_float(d, "half_width", 5.0)
		if d.has("osm_id"):
			item["osm_id"] = int(d["osm_id"])
		if d.has("culvert"):
			item["culvert"] = bool(d["culvert"])
		if d.has("covered"):
			item["covered"] = bool(d["covered"])
	elif kind == "solar":
		item["area_m2"] = TerrainBuilder.dict_float(d, "area_m2",
			BuildingBuilder.footprint_area_m2(pts))
	else:
		item["kind"] = str(d.get("kind", "landuse"))
	return item


## Recover a waterway's centreline from its buffered ribbon (OsmWaterParser.
## _buffer_polyline: n left-bank points, the n right-bank points reversed, and
## usually the first point again to close it). Centre i is the midpoint of left
## i and its mirror on the right. {} when the ribbon is not that shape.
static func _derive_centerline(ribbon: PackedVector2Array) -> Dictionary:
	var m := ribbon.size()
	if m >= 5 and ribbon[0].distance_squared_to(ribbon[m - 1]) < 1e-4:
		m -= 1
	if m < 4 or m % 2 != 0:
		return {}
	var n := m / 2
	var cl := PackedVector2Array()
	for i in n:
		cl.append((ribbon[i] + ribbon[m - 1 - i]) * 0.5)
	return {"centerline": cl, "half_width": ribbon[0].distance_to(ribbon[m - 1]) * 0.5}


static func _pseudo_osm_id(cl: PackedVector2Array) -> int:
	var a := cl[0]
	var b := cl[cl.size() - 1]
	var h := hash([roundi(a.x), roundi(a.y), roundi(b.x), roundi(b.y), cl.size()])
	return PSEUDO_OSM_ID_BASE + (absi(h) % 100000000000)


static func _parse_overpass(doc: Dictionary, center_lat: float, center_lon: float,
		_include_landuse: bool) -> Dictionary:
	var nodes: Dictionary = {}
	var building_ways: Array[Dictionary] = []
	var highway_ways: Array[Dictionary] = []
	var solar_ways: Array[Dictionary] = []
	var landuse_ways: Array[Dictionary] = []
	var ways_by_id: Dictionary = {}
	var water_way_ids: Array = []
	var waterway_line_ids: Array = []
	var water_relations: Array = []
	for el in doc.get("elements", []):
		if not (el is Dictionary):
			continue
		var e: Dictionary = el
		match str(e.get("type", "")):
			"node":
				nodes[int(e["id"])] = Vector2(float(e["lon"]), float(e["lat"]))
			"way":
				var tags: Dictionary = e.get("tags", {})
				ways_by_id[int(e["id"])] = e
				if is_solar_generator_tags(tags):
					solar_ways.append(e)
				elif tags.has("building"):
					building_ways.append(e)
				elif tags.has("highway"):
					highway_ways.append(e)
				elif _include_landuse and (tags.has("landuse") or tags.get("amenity") == "parking" or tags.get("leisure") == "pitch"):
					landuse_ways.append(e)
				elif OsmWaterParser.is_water_way_tags(tags):
					water_way_ids.append(int(e["id"]))
				elif OsmWaterParser.is_waterway_line_tags(tags):
					waterway_line_ids.append(int(e["id"]))
			"relation":
				var rtags: Dictionary = e.get("tags", {})
				if OsmWaterParser.is_water_relation_tags(rtags):
					water_relations.append(e)

	var buildings: Array = []
	var building_idx := 0
	for way in building_ways:
		var poly := _way_to_local_poly(way, nodes, center_lat, center_lon)
		if poly.size() < 3:
			continue
		var tags: Dictionary = way.get("tags", {})
		buildings.append({
			"idx": building_idx,
			"points": poly,
			"height_m": BuildingBuilder.parse_height_m(tags),
			"tags": tags,
			"roof": BuildingBuilder.infer_roof_spec(tags, poly),
		})
		building_idx += 1

	var roads: Array = []
	for way in highway_ways:
		var poly := _way_to_local_poly(way, nodes, center_lat, center_lon, false)
		if poly.size() < 2:
			continue
		var tags: Dictionary = way.get("tags", {})
		roads.append({
			"points": poly,
			"half_width_m": TerrainRoadFlatten.highway_half_width(tags),
			"highway_type": str(tags.get("highway", "residential")),
			"tags": tags,
		})

	var landuse: Array = []
	for way in landuse_ways:
		var poly := _way_to_local_poly(way, nodes, center_lat, center_lon)
		if poly.size() < 3:
			continue
		var tags: Dictionary = way.get("tags", {})
		var kind := str(tags.get("landuse", tags.get("amenity", tags.get("leisure", "area"))))
		landuse.append({"points": poly, "kind": kind, "tags": tags})

	var water: Array = OsmWaterParser.extract_water(
		nodes, ways_by_id, water_way_ids, water_relations, waterway_line_ids,
		center_lat, center_lon)

	var solar: Array = []
	for way in solar_ways:
		var poly := _way_to_local_poly(way, nodes, center_lat, center_lon)
		if poly.size() < 3:
			continue
		var tags: Dictionary = way.get("tags", {})
		solar.append({
			"points": poly,
			"tags": tags,
			"area_m2": BuildingBuilder.footprint_area_m2(poly),
		})

	return {"buildings": buildings, "roads": roads, "landuse": landuse,
		"water": water, "solar": solar}


## True for OSM ways/nodes that represent a photovoltaic solar generator.
static func is_solar_generator_tags(tags: Dictionary) -> bool:
	if str(tags.get("generator:source", "")) == "solar":
		return true
	if str(tags.get("generator:method", "")) == "photovoltaic":
		return true
	return false


static func _way_to_local_poly(way: Dictionary, nodes: Dictionary,
		center_lat: float, center_lon: float, require_closed: bool = true) -> PackedVector2Array:
	var node_ids: Variant = way.get("nodes", [])
	if not (node_ids is Array) or (node_ids as Array).size() < 2:
		return PackedVector2Array()
	var poly := PackedVector2Array()
	for nid_v in node_ids:
		var nid := int(nid_v)
		if not nodes.has(nid):
			poly.clear()
			break
		var ll: Vector2 = nodes[nid]
		poly.append(GeoMath.lonlat_to_local_m(ll.y, ll.x, center_lat, center_lon))
	if poly.size() < 2:
		return PackedVector2Array()
	if require_closed and poly.size() >= 3 and poly[0].distance_squared_to(poly[poly.size() - 1]) > 0.01:
		pass
	return poly
