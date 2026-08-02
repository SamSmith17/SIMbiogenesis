extends Node

## VegetationService — lazy-loads OSM vegetation (wood/forest/scrub/orchard
## polygons, natural=tree points, tree_row lines) via one Overpass request per
## site bbox. Mirrors BuildingService (HTTP + cache + deferred signals) but owns
## its OWN HTTPRequest/job so a wider vegetation fetch never blocks the buildings
## request. Feeds AutoVegetationGenerator (ROADMAP Pillar 8 — auto land cover).

signal vegetation_osm_ready(key: String, payload: Dictionary)
signal vegetation_osm_failed(reason: String)
signal vegetation_progress(message: String)

const OVERPASS_URL := "https://overpass-api.de/api/interpreter"
const CACHE_DIR := "user://terrain_cache/osm_vegetation"
## v8: veg multipolygons keep outer rings only (v6/v7 hole-punch exploded to millions).
const CACHE_VERSION := "v8"
const ATTRIBUTION := "© OpenStreetMap contributors"
const REQUEST_TIMEOUT := 90.0
const MAX_RETRIES := 3
const RETRY_BACKOFF := 4.0
## Soft ceiling after parse/deserialize. Dense sites rarely need more; beyond this
## scatter already trims to DENSE_POLY_BUDGET (640) and ranking millions of polys
## stalls the main thread (~hundreds of ms/frame via GrowthZoneIndex rebuild).
const MAX_POLYGONS_RETAINED := 4000
const MAX_OPEN_AREA_POLYS := 800
## Reject on-disk caches larger than this (GB-scale corrupt payloads).
const MAX_CACHE_BYTES := 32 * 1024 * 1024

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


func request_vegetation(lat: float, lon: float, half_extent_m: float,
		force_refetch: bool = false) -> void:
	var req := {
		"lat": lat,
		"lon": lon,
		"half_extent_m": half_extent_m,
		"force_refetch": force_refetch,
	}
	if _busy:
		_pending = req
		return
	_start_veg_job(req)


func _start_veg_job(req: Dictionary) -> void:
	var lat: float = float(req["lat"])
	var lon: float = float(req["lon"])
	var half_extent_m: float = float(req["half_extent_m"])
	var force_refetch: bool = bool(req.get("force_refetch", false))
	var key := _cache_key(lat, lon, half_extent_m)
	var cache_path := "%s/%s.json" % [CACHE_DIR, key]
	if not force_refetch and TerrainCacheSettings.cache_enabled() \
			and FileAccess.file_exists(cache_path):
		if _cache_file_too_large(cache_path):
			push_warning("VegetationService: rejecting oversized cache %s — refetching"
				% cache_path.get_file())
			DirAccess.remove_absolute(ProjectSettings.globalize_path(cache_path))
		else:
			var parsed: Variant = _load_cache(cache_path)
			if parsed is Dictionary:
				var payload := deserialize_payload(parsed as Dictionary)
				payload = cap_polygons(payload)
				_emit_veg_deferred(key, payload)
				return
	var bbox := GeoMath.bbox_for(lat, lon, half_extent_m)
	var s := float(bbox["south"])
	var w := float(bbox["west"])
	var n := float(bbox["north"])
	var e := float(bbox["east"])
	# Area polygons (ways + multipolygon relations), tree_row lines, grass/meadow
	# lawns, and individual natural=tree nodes.
	var query := _build_overpass_query(s, w, n, e)
	_job = {
		"key": key,
		"cache_path": cache_path,
		"lat": lat,
		"lon": lon,
		"half_extent_m": half_extent_m,
		"query": query,
		"retries": 0,
	}
	_busy = true
	vegetation_progress.emit("Fetching OSM vegetation …")
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
	var payload := cap_polygons(_parse_overpass(parsed as Dictionary,
		float(_job["lat"]), float(_job["lon"])))
	_save_cache(str(_job["cache_path"]), payload)
	var key := str(_job["key"])
	_busy = false
	_job = {}
	_emit_veg_deferred(key, payload)
	_start_pending()


func _emit_veg_deferred(key: String, payload: Dictionary) -> void:
	call_deferred("_emit_veg", key, payload)


func _emit_veg(key: String, payload: Dictionary) -> void:
	vegetation_osm_ready.emit(key, payload)
	_start_pending()


func _start_pending() -> void:
	if _pending.is_empty() or _busy:
		return
	var req: Dictionary = _pending
	_pending = {}
	_start_veg_job(req)


func _retry_or_fail(reason: String) -> void:
	var retries := int(_job.get("retries", 0)) + 1
	_job["retries"] = retries
	if retries > MAX_RETRIES:
		_fail("%s after %d retries" % [reason, MAX_RETRIES])
		return
	vegetation_progress.emit("Retrying OSM vegetation (%s) …" % reason)
	var timer := get_tree().create_timer(RETRY_BACKOFF * float(retries))
	var query: String = str(_job.get("query", ""))
	timer.timeout.connect(func() -> void:
		if _busy and not _job.is_empty() and query != "":
			_post_query(str(query))
	, CONNECT_ONE_SHOT)


func _fail(reason: String) -> void:
	_busy = false
	_job = {}
	vegetation_osm_failed.emit(reason)
	_start_pending()


static func _cache_key(lat: float, lon: float, half_extent_m: float) -> String:
	return "osmveg_%s_%.4f_%.4f_%d" % [CACHE_VERSION, lat, lon, int(half_extent_m)]


## True when `key` (as delivered by vegetation_osm_ready) belongs to the given
## site request. The service runs one job at a time with a single-slot pending
## queue, so a listener that changed sites mid-flight can otherwise receive —
## and must be able to reject — the PREVIOUS site's payload.
static func matches_site(key: String, lat: float, lon: float, half_extent_m: float) -> bool:
	return key == _cache_key(lat, lon, half_extent_m)


static func _cache_file_too_large(path: String) -> bool:
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path) and not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var n := f.get_length()
	f.close()
	return n > MAX_CACHE_BYTES


static func _load_cache(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


## Keep open-area (lawn/meadow) veto polys first, then the largest remaining by
## footprint area. Mutates a shallow copy of the payload dict.
static func cap_polygons(payload: Dictionary,
		max_count: int = MAX_POLYGONS_RETAINED) -> Dictionary:
	var polys: Array = payload.get("polygons", [])
	if polys.size() <= max_count:
		return payload
	var open: Array = []
	var ranked: Array = []
	for rec in polys:
		if not (rec is Dictionary):
			continue
		var d: Dictionary = rec
		var poly: PackedVector2Array = d.get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var kind := str(d.get("kind", ""))
		if kind == "grass_lawn" or kind == "grass_field":
			open.append(d)
		else:
			ranked.append({"rec": d, "area": _poly_area_m2(poly)})
	if open.size() > MAX_OPEN_AREA_POLYS:
		# Prefer larger lawns/meadows when the open-area set itself is huge.
		var open_ranked: Array = []
		for d in open:
			var poly: PackedVector2Array = (d as Dictionary).get("points", PackedVector2Array())
			open_ranked.append({"rec": d, "area": _poly_area_m2(poly)})
		open_ranked.sort_custom(func(a, b): return float(a["area"]) > float(b["area"]))
		open = []
		for i in mini(open_ranked.size(), MAX_OPEN_AREA_POLYS):
			open.append(open_ranked[i]["rec"])
	ranked.sort_custom(func(a, b): return float(a["area"]) > float(b["area"]))
	var rest_budget := maxi(max_count - open.size(), 0)
	var out: Array = open.duplicate()
	for i in mini(ranked.size(), rest_budget):
		out.append(ranked[i]["rec"])
	push_warning("VegetationService: capped OSM polygons %d → %d (open=%d)"
		% [polys.size(), out.size(), open.size()])
	var capped := payload.duplicate(false)
	capped["polygons"] = out
	return capped


static func _poly_area_m2(poly: PackedVector2Array) -> float:
	# Shoelace; abs so winding doesn't matter for ranking.
	var a := 0.0
	var n := poly.size()
	if n < 3:
		return 0.0
	for i in n:
		var j := (i + 1) % n
		a += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return absf(a) * 0.5


static func _save_cache(path: String, payload: Dictionary) -> void:
	if not TerrainCacheSettings.cache_enabled():
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_serialize_payload(payload)))


## --- serialization (PackedVector2Array <-> [[x, y], …]) ---------------------

static func _serialize_payload(payload: Dictionary) -> Dictionary:
	var polys: Array = []
	for p in payload.get("polygons", []):
		if p is Dictionary:
			var d: Dictionary = p
			var entry := {
				"points": _ser_points(d.get("points", PackedVector2Array())),
				"kind": str(d.get("kind", "wood")),
			}
			var tags: Dictionary = d.get("tags", {})
			if not tags.is_empty():
				entry["tags"] = tags
			polys.append(entry)
	var rows: Array = []
	for r in payload.get("tree_rows", []):
		if r is Dictionary:
			var d: Dictionary = r
			var entry := {"points": _ser_points(d.get("points", PackedVector2Array()))}
			var tags: Dictionary = d.get("tags", {})
			if not tags.is_empty():
				entry["tags"] = tags
			rows.append(entry)
	var pts: Array = []
	for t in payload.get("tree_points", []):
		if t is Dictionary:
			var d: Dictionary = t
			var pos: Vector2 = d.get("pos", Vector2.ZERO)
			var entry: Array = [pos.x, pos.y, float(d.get("height_m", 0.0))]
			var tags: Dictionary = d.get("tags", {})
			if not tags.is_empty():
				entry.append(tags)
			pts.append(entry)
	# Hedge rows are a full scatter phase in AutoVegetationGenerator; omitting them
	# here dropped every hedge on cached reloads (fresh fetch had them, cache did not).
	var hedges: Array = []
	for r in payload.get("hedge_rows", []):
		if r is Dictionary:
			var d: Dictionary = r
			var entry := {"points": _ser_points(d.get("points", PackedVector2Array()))}
			var tags: Dictionary = d.get("tags", {})
			if not tags.is_empty():
				entry["tags"] = tags
			hedges.append(entry)
	return {"version": CACHE_VERSION, "polygons": polys, "tree_rows": rows,
		"tree_points": pts, "hedge_rows": hedges}


static func _ser_points(pts: PackedVector2Array) -> Array:
	var arr: Array = []
	for p in pts:
		arr.append([p.x, p.y])
	return arr


static func _deser_points(arr: Variant) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if arr is Array:
		for pair in arr:
			if pair is Array and (pair as Array).size() >= 2:
				pts.append(Vector2(
					TerrainBuilder.variant_to_float(pair[0]),
					TerrainBuilder.variant_to_float(pair[1])))
	return pts


static func _deser_vec2(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(
			TerrainBuilder.variant_to_float(v[0]),
			TerrainBuilder.variant_to_float(v[1]))
	return Vector2.ZERO


static func deserialize_payload(raw: Dictionary) -> Dictionary:
	var polys: Array = []
	for p in raw.get("polygons", []):
		if p is Dictionary:
			var d: Dictionary = p
			polys.append({
				"points": _deser_points(d.get("points", [])),
				"kind": str(d.get("kind", "wood")),
				"tags": d.get("tags", {}),
			})
	var rows: Array = []
	for r in raw.get("tree_rows", []):
		if r is Dictionary:
			var d: Dictionary = r
			rows.append({
				"points": _deser_points(d.get("points", [])),
				"tags": d.get("tags", {}),
			})
	var pts: Array = []
	for t in raw.get("tree_points", []):
		if t is Dictionary:
			var d: Dictionary = t
			pts.append({
				"pos": _deser_vec2(d.get("pos", Vector2.ZERO)),
				"height_m": float(d.get("height_m", 0.0)),
				"tags": d.get("tags", {}),
			})
		elif t is Array and (t as Array).size() >= 2:
			var arr: Array = t
			var h := 0.0
			if arr.size() >= 3:
				h = TerrainBuilder.variant_to_float(arr[2])
			var tags: Dictionary = {}
			if arr.size() >= 4 and arr[3] is Dictionary:
				tags = arr[3]
			pts.append({"pos": Vector2(
				TerrainBuilder.variant_to_float(arr[0]),
				TerrainBuilder.variant_to_float(arr[1])), "height_m": h, "tags": tags})
	var hedges: Array = []
	for r in raw.get("hedge_rows", []):
		if r is Dictionary:
			var d: Dictionary = r
			hedges.append({
				"points": _deser_points(d.get("points", [])),
				"tags": d.get("tags", {}),
			})
	return {"polygons": polys, "tree_rows": rows, "tree_points": pts, "hedge_rows": hedges}


## --- parsing -----------------------------------------------------------------

static func _parse_overpass(doc: Dictionary, center_lat: float, center_lon: float) -> Dictionary:
	var nodes: Dictionary = {}
	var ways_by_id: Dictionary = {}
	var polygon_ways: Array[Dictionary] = []
	var row_ways: Array[Dictionary] = []
	var hedge_ways: Array[Dictionary] = []
	var relations: Array[Dictionary] = []
	var tree_points: Array = []

	for el in doc.get("elements", []):
		if not (el is Dictionary):
			continue
		var e: Dictionary = el
		match str(e.get("type", "")):
			"node":
				nodes[int(e["id"])] = Vector2(float(e["lon"]), float(e["lat"]))
				var ntags: Dictionary = e.get("tags", {})
				if str(ntags.get("natural", "")) == "tree":
					tree_points.append({
						"pos": GeoMath.lonlat_to_local_m(
							float(e["lat"]), float(e["lon"]), center_lat, center_lon),
						"height_m": _height_tag(ntags),
						"tags": ntags,
					})
			"way":
				ways_by_id[int(e["id"])] = e
				var wtags: Dictionary = e.get("tags", {})
				if str(wtags.get("natural", "")) == "tree_row":
					row_ways.append(e)
				elif str(wtags.get("barrier", "")) == "hedge":
					hedge_ways.append(e)
				elif _is_veg_area_tags(wtags):
					polygon_ways.append(e)
			"relation":
				relations.append(e)

	var polygons: Array = []
	var used_mp_ways: Dictionary = {}
	# Relations FIRST so member ways are marked used before the tagged-way pass
	# (otherwise every multipolygon outer is double-counted as way + relation).
	for rel in relations:
		var rtags: Dictionary = rel.get("tags", {})
		if str(rtags.get("type", "")) != "multipolygon":
			continue
		if not _is_veg_area_tags(rtags):
			continue
		var kind := _veg_kind(rtags)
		# Outers only — never punch forest holes (combinatorial fragment bomb).
		for assembled in OsmWaterParser._multipolygon_to_polys(
				rel, ways_by_id, nodes, center_lat, center_lon, used_mp_ways, false):
			if assembled.size() >= 3:
				polygons.append({"points": assembled, "kind": kind, "tags": rtags})

	for way in polygon_ways:
		var wid := int(way.get("id", -1))
		if used_mp_ways.has(wid):
			continue
		var poly := _way_to_local_poly(way, nodes, center_lat, center_lon, true)
		if poly.size() < 3:
			continue
		var tags: Dictionary = way.get("tags", {})
		polygons.append({"points": poly, "kind": _veg_kind(tags), "tags": tags})

	var tree_rows: Array = []
	for way in row_ways:
		var line := _way_to_local_poly(way, nodes, center_lat, center_lon, false)
		if line.size() >= 2:
			tree_rows.append({"points": line, "tags": way.get("tags", {})})

	var hedge_rows: Array = []
	for way in hedge_ways:
		var line := _way_to_local_poly(way, nodes, center_lat, center_lon, false)
		if line.size() >= 2:
			hedge_rows.append({"points": line, "tags": way.get("tags", {})})

	return {"polygons": polygons, "tree_rows": tree_rows, "tree_points": tree_points,
		"hedge_rows": hedge_rows}


static func _build_overpass_query(s: float, w: float, n: float, e: float) -> String:
	var parts: PackedStringArray = []
	var bbox := "%f,%f,%f,%f" % [s, w, n, e]
	for key_val in [
		["natural", "wood"], ["natural", "forest"], ["landuse", "forest"],
		["natural", "scrub"], ["natural", "heath"], ["natural", "wetland"],
		["landuse", "orchard"], ["landuse", "vineyard"], ["landuse", "cemetery"],
		["landuse", "grass"], ["landuse", "meadow"], ["landuse", "farmland"],
		["landuse", "recreation_ground"], ["natural", "grassland"],
		["leisure", "garden"], ["leisure", "park"], ["leisure", "pitch"],
	]:
		parts.append("way[\"%s\"=\"%s\"](%s);" % [key_val[0], key_val[1], bbox])
	parts.append("way[\"natural\"=\"tree_row\"](%s);" % bbox)
	parts.append("way[\"barrier\"=\"hedge\"](%s);" % bbox)
	for key_val in [
		["natural", "wood"], ["natural", "forest"], ["landuse", "forest"],
		["natural", "scrub"], ["natural", "heath"], ["natural", "wetland"],
		["landuse", "orchard"], ["landuse", "vineyard"], ["landuse", "cemetery"],
		["landuse", "grass"], ["landuse", "meadow"], ["landuse", "farmland"],
		["landuse", "recreation_ground"], ["natural", "grassland"],
		["leisure", "garden"], ["leisure", "park"], ["leisure", "pitch"],
	]:
		parts.append(
			"relation[\"type\"=\"multipolygon\"][\"%s\"=\"%s\"](%s);" % [key_val[0], key_val[1], bbox])
	parts.append("node[\"natural\"=\"tree\"](%s);" % bbox)
	return "[out:json][timeout:90];(" + "".join(parts) + ");out body;>;out skel qt;"


static func _grass_lawn_tags(tags: Dictionary) -> bool:
	var lu := str(tags.get("landuse", ""))
	var le := str(tags.get("leisure", ""))
	if lu == "grass" or lu == "recreation_ground":
		return true
	if le == "garden":
		return true
	if le == "pitch" and str(tags.get("surface", "")) == "grass":
		return true
	return false


static func _grass_field_tags(tags: Dictionary) -> bool:
	var lu := str(tags.get("landuse", ""))
	var nat := str(tags.get("natural", ""))
	if lu == "meadow" or lu == "farmland":
		return true
	if nat == "grassland":
		return true
	return false


static func _is_veg_area_tags(tags: Dictionary) -> bool:
	var nat := str(tags.get("natural", ""))
	var lu := str(tags.get("landuse", ""))
	var le := str(tags.get("leisure", ""))
	if nat == "wood" or nat == "forest" or nat == "scrub" or nat == "heath" \
			or nat == "wetland" or lu == "forest" or lu == "orchard" \
			or lu == "vineyard" or lu == "cemetery":
		return true
	if le == "park":
		return true
	if le == "pitch" and str(tags.get("surface", "")) == "grass":
		return true
	return _grass_lawn_tags(tags) or _grass_field_tags(tags)


static func _veg_kind(tags: Dictionary) -> String:
	var nat := str(tags.get("natural", ""))
	var lu := str(tags.get("landuse", ""))
	var le := str(tags.get("leisure", ""))
	if nat == "scrub" or nat == "heath":
		return "scrub"
	if nat == "wetland":
		return "wetland"
	if lu == "orchard":
		return "orchard"
	if lu == "vineyard":
		return "vineyard"
	if lu == "cemetery":
		return "cemetery"
	if le == "park":
		return "park"
	if le == "pitch" and str(tags.get("surface", "")) == "grass":
		return "grass_lawn"
	if _grass_lawn_tags(tags):
		return "grass_lawn"
	if _grass_field_tags(tags):
		return "grass_field"
	return "wood"


static func _height_tag(tags: Dictionary) -> float:
	if not tags.has("height"):
		return 0.0
	return parse_height_m(str(tags["height"]))


## Parse an OSM height value ("30", "30 m", "90 ft", "25'", "250 cm") to meters.
## OSM's convention is meters when no unit is given; feet appear in US-mapped
## data — the old parser stripped only "m", so "90 ft" read as 90 meters.
## Unparseable input returns 0 (caller treats as "no tag").
static func parse_height_m(raw_value: String) -> float:
	var raw := raw_value.strip_edges().to_lower().replace(",", ".")
	if raw.is_empty():
		return 0.0
	var factor := 1.0
	if raw.ends_with("ft") or raw.ends_with("feet") or raw.ends_with("'"):
		factor = 0.3048
	elif raw.ends_with("in") or raw.ends_with("\""):
		factor = 0.0254
	elif raw.ends_with("cm"):
		factor = 0.01
	var num := ""
	for ch in raw:
		if (ch >= "0" and ch <= "9") or ch == "." or ch == "-":
			num += ch
		elif not num.is_empty():
			break
	return maxf(num.to_float() * factor, 0.0)


static func _way_to_local_poly(way: Dictionary, nodes: Dictionary,
		center_lat: float, center_lon: float, _require_closed: bool) -> PackedVector2Array:
	var node_ids: Variant = way.get("nodes", [])
	if not (node_ids is Array) or (node_ids as Array).size() < 2:
		return PackedVector2Array()
	var poly := PackedVector2Array()
	for nid_v in node_ids:
		var nid := int(nid_v)
		if not nodes.has(nid):
			return PackedVector2Array()
		var ll: Vector2 = nodes[nid]
		poly.append(GeoMath.lonlat_to_local_m(ll.y, ll.x, center_lat, center_lon))
	return poly
