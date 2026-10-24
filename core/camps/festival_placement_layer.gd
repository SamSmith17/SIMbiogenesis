class_name FestivalPlacementLayer
extends RefCounted

## Per-map store of festival PLACEMENT: the roads a placement team draws, the
## ZONES it allocates for theme camps along them, the LOTS those zones are cut
## into, and the ROSTER of camps waiting for a lot
## (user://maps/festival_placement_<lat>_<lon>.json).
##
## One file for all four, because they reference each other by id (a zone
## names its frontage roads, a lot names its zone and road, an assignment names
## a roster entry): one snapshot is one undo entry and one round-trip test.
## Lots are ALSO mirrored into CampAreaLayer (one camp record per lot,
## `group_id` = the zone) so CampLayoutGenerator fills them without knowing
## placement exists; `camp_area_id` is the link.
##
## Records (every key written in serialize() is read in deserialize()):
##   road  {id, name, points, half_width_m, surface, flattened, tags}
##   zone  {id, name, polygon, holes, seed, road_ids, spec, features, stats}
##   lot   {lot_id, zone_id, road_id, side, index, name, camp_area_id, polygon,
##          frontage_m, depth_m, usable_m2, raw_m2, mean_slope_deg,
##          max_slope_deg, s_start, s_end, corner, touches_road_ids, locked,
##          heading_deg, features, assigned_camp, fairness}
##   roster {id, name, size_class, headcount, style, requirements, adjacent_to,
##          requested_m2}

const VERSION := 1
const MAX_ROADS := 200
const MAX_ZONES := 100
const MAX_LOTS := 2000
const MAX_ROSTER := 500
const SURFACES := ["dirt", "gravel", "playa", "paved", "grass"]
const FEATURES := ["power", "water", "quiet", "loud", "shade"]
const SPEC_MODES := ["count", "area"]
const EQUALISE_MODES := ["usable", "raw"]

var roads: Array = []
var zones: Array = []
var lots: Array = []
var roster: Array = []
var _next_road := 1
var _next_zone := 1
var _next_lot := 1
var _next_roster := 1


static func create_empty() -> FestivalPlacementLayer:
	return FestivalPlacementLayer.new()


static func save_path_for_map(lat: float, lon: float) -> String:
	return WorldPaths.site_file("festival_placement", lat, lon)


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
	deserialize(parsed as Dictionary)
	return true


func is_empty() -> bool:
	return roads.is_empty() and zones.is_empty() and lots.is_empty() and roster.is_empty()


# ---------------------------------------------------------------------------
# Specs
# ---------------------------------------------------------------------------

static func default_spec() -> Dictionary:
	return {
		"mode": "count", "target_n": 8, "target_m2": 600.0,
		"depth_m": 25.0, "lane_w_m": 5.0, "lots_per_lane": 4, "lane_every_m": 0.0,
		"front_min_m": 12.0, "front_max_m": 45.0, "slope_limit_deg": 10.0,
		"equalise": "usable", "styles": [CampStyles.DEFAULT_STYLE],
		"density": 0.8, "align_jitter_deg": 5.0, "light_density": 1.0,
	}


## Every key present and in range; unknown keys dropped.
static func normalize_spec(raw: Variant) -> Dictionary:
	var d := default_spec()
	if not (raw is Dictionary):
		return d
	var r: Dictionary = raw
	var mode := str(r.get("mode", d["mode"]))
	d["mode"] = mode if SPEC_MODES.has(mode) else "count"
	d["target_n"] = clampi(int(r.get("target_n", d["target_n"])), 1, 200)
	d["target_m2"] = clampf(float(r.get("target_m2", d["target_m2"])), 50.0, 20000.0)
	d["depth_m"] = clampf(float(r.get("depth_m", d["depth_m"])), 4.0, 200.0)
	d["lane_w_m"] = clampf(float(r.get("lane_w_m", d["lane_w_m"])), 0.0, 20.0)
	d["lots_per_lane"] = clampi(int(r.get("lots_per_lane", d["lots_per_lane"])), 0, 50)
	d["lane_every_m"] = clampf(float(r.get("lane_every_m", d["lane_every_m"])), 0.0, 1000.0)
	d["front_min_m"] = clampf(float(r.get("front_min_m", d["front_min_m"])), 2.0, 200.0)
	d["front_max_m"] = clampf(float(r.get("front_max_m", d["front_max_m"])), 4.0, 400.0)
	d["slope_limit_deg"] = clampf(float(r.get("slope_limit_deg", d["slope_limit_deg"])), 1.0, 45.0)
	var eq := str(r.get("equalise", d["equalise"]))
	d["equalise"] = eq if EQUALISE_MODES.has(eq) else "usable"
	var styles: Array = []
	for s in r.get("styles", d["styles"]):
		if CampStyles.is_valid(str(s)) and not styles.has(str(s)):
			styles.append(str(s))
	d["styles"] = styles if not styles.is_empty() else [CampStyles.DEFAULT_STYLE]
	d["density"] = clampf(float(r.get("density", d["density"])), 0.2, 1.0)
	d["align_jitter_deg"] = clampf(float(r.get("align_jitter_deg", d["align_jitter_deg"])), 0.0, 45.0)
	d["light_density"] = clampf(float(r.get("light_density", d["light_density"])), 0.0, 2.0)
	return d


static func _clean_features(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for f in raw:
			if FEATURES.has(str(f)) and not out.has(str(f)):
				out.append(str(f))
	return out


# ---------------------------------------------------------------------------
# Roads
# ---------------------------------------------------------------------------

## params: name, width_m (full width), surface, tags. Returns id or "".
func add_road(points: PackedVector2Array, params: Dictionary = {}) -> String:
	if points.size() < 2 or roads.size() >= MAX_ROADS:
		return ""
	var id := "road_%d" % _next_road
	_next_road += 1
	roads.append(_normalized_road({
		"id": id,
		"name": str(params.get("name", "Road %d" % (_next_road - 1))),
		"points": points.duplicate(),
		"half_width_m": float(params.get("half_width_m", float(params.get("width_m", 8.0)) * 0.5)),
		"surface": str(params.get("surface", "gravel")),
		"flattened": bool(params.get("flattened", false)),
		"tags": params.get("tags", {"highway": "festival"}),
	}))
	return id


func get_road(id: String) -> Dictionary:
	for r: Dictionary in roads:
		if str(r["id"]) == id:
			return r
	return {}


func update_road(id: String, patch: Dictionary) -> bool:
	for i in roads.size():
		if str((roads[i] as Dictionary)["id"]) == id:
			var rec: Dictionary = (roads[i] as Dictionary).duplicate()
			for k in patch.keys():
				if k == "width_m":
					rec["half_width_m"] = float(patch[k]) * 0.5
				elif k != "id":
					rec[k] = patch[k]
			roads[i] = _normalized_road(rec)
			return true
	return false


## Removing a road un-fronts the zones that used it; their lots stay until
## the zone is re-subdivided (they are still valid camps).
func remove_road(id: String) -> bool:
	for i in roads.size():
		if str((roads[i] as Dictionary)["id"]) == id:
			roads.remove_at(i)
			for z: Dictionary in zones:
				var ids: Array = z.get("road_ids", [])
				ids.erase(id)
				z["road_ids"] = ids
			return true
	return false


## The road whose corridor (plus `tol`) covers p, or "".
func road_at(p: Vector2, tol: float = 1.0) -> String:
	var best := ""
	var best_d := INF
	for r: Dictionary in roads:
		var pts: PackedVector2Array = r["points"]
		var reach := float(r["half_width_m"]) + tol
		for i in range(pts.size() - 1):
			var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1]))
			if d <= reach and d < best_d:
				best_d = d
				best = str(r["id"])
	return best


## Road dicts in the shape OSM roads use ({points, half_width_m, tags, …}),
## so heading resolution, exclusions and nav consume them unchanged.
func road_dicts() -> Array:
	var out: Array = []
	for r: Dictionary in roads:
		out.append(r)
	return out


static func _normalized_road(rec: Dictionary) -> Dictionary:
	var surface := str(rec.get("surface", "gravel"))
	var tags: Variant = rec.get("tags", {})
	return {
		"id": str(rec.get("id", "")),
		"name": str(rec.get("name", "")),
		"points": rec.get("points", PackedVector2Array()),
		"half_width_m": clampf(float(rec.get("half_width_m", 4.0)), 1.0, 20.0),
		"surface": surface if SURFACES.has(surface) else "gravel",
		"flattened": bool(rec.get("flattened", false)),
		"tags": tags if tags is Dictionary else {"highway": "festival"},
	}


## A road along one edge of a zone, moved `inset_m` inward (the Esplanade
## case: the road runs just inside the allocation's boundary). `extend_m`
## stretches both ends so the corridor covers the corners.
static func road_from_zone_edge(poly: PackedVector2Array, edge_i: int, inset_m: float,
		extend_m: float = 0.0) -> PackedVector2Array:
	if poly.size() < 3:
		return PackedVector2Array()
	var a := poly[edge_i % poly.size()]
	var b := poly[(edge_i + 1) % poly.size()]
	var t := (b - a)
	if t.length_squared() < 1e-6:
		return PackedVector2Array()
	t = t.normalized()
	var n := Vector2(-t.y, t.x)
	var mid := (a + b) * 0.5
	if not Geometry2D.is_point_in_polygon(mid + n * 0.5, poly):
		n = -n
	return PackedVector2Array([a + n * inset_m - t * extend_m, b + n * inset_m + t * extend_m])


## A road down the middle of a zone along `heading_deg` (the longest edge by
## default): the mid-line of the outline's extent across the heading, clipped
## to the inside.
static func road_from_zone_spine(poly: PackedVector2Array, heading_deg: float = -1.0) -> PackedVector2Array:
	if poly.size() < 3:
		return PackedVector2Array()
	var h := heading_deg if heading_deg >= 0.0 else CampLayoutGenerator.resolve_heading(poly, [])
	var phi := CampLayoutGenerator.heading_to_angle(h)
	var u := Vector2(cos(phi), sin(phi))
	var v := Vector2(-u.y, u.x)
	var u_min := INF
	var u_max := -INF
	var v_min := INF
	var v_max := -INF
	for p in poly:
		u_min = minf(u_min, p.dot(u))
		u_max = maxf(u_max, p.dot(u))
		v_min = minf(v_min, p.dot(v))
		v_max = maxf(v_max, p.dot(v))
	var v_mid := (v_min + v_max) * 0.5
	var line := PackedVector2Array([u * (u_min - 10.0) + v * v_mid, u * (u_max + 10.0) + v * v_mid])
	var best := PackedVector2Array()
	var best_len := 0.0
	for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(line, poly):
		if piece.size() < 2:
			continue
		var l := piece[0].distance_to(piece[piece.size() - 1])
		if l > best_len:
			best_len = l
			best = piece
	return best


# ---------------------------------------------------------------------------
# Zones
# ---------------------------------------------------------------------------

## params: name, spec, road_ids, features, holes, seed. Returns id or "".
func add_zone(poly: PackedVector2Array, params: Dictionary = {}) -> String:
	if poly.size() < 3 or zones.size() >= MAX_ZONES:
		return ""
	var ring := CampAreaLayer._ccw(poly)
	if CampAreaLayer.polygon_area(ring) < CampAreaLayer.MIN_AREA_M2:
		return ""
	var id := "zone_%d" % _next_zone
	_next_zone += 1
	zones.append(_normalized_zone({
		"id": id,
		"name": str(params.get("name", "Zone %s" % CampSubdivider.row_letters(_next_zone - 2))),
		"polygon": ring,
		"holes": params.get("holes", []),
		"seed": int(params.get("seed", CampAreaLayer._poly_seed(ring))),
		"road_ids": params.get("road_ids", []),
		"spec": params.get("spec", {}),
		"features": params.get("features", []),
		"stats": {},
	}))
	return id


func get_zone(id: String) -> Dictionary:
	for z: Dictionary in zones:
		if str(z["id"]) == id:
			return z
	return {}


func update_zone(id: String, patch: Dictionary) -> bool:
	for i in zones.size():
		if str((zones[i] as Dictionary)["id"]) == id:
			var rec: Dictionary = (zones[i] as Dictionary).duplicate()
			for k in patch.keys():
				if k == "spec" and patch[k] is Dictionary:
					var merged: Dictionary = (rec.get("spec", {}) as Dictionary).duplicate()
					merged.merge(patch[k], true)
					rec["spec"] = merged
				elif k != "id":
					rec[k] = patch[k]
			zones[i] = _normalized_zone(rec)
			return true
	return false


## Removes the zone and its lots. Returns the camp_area_ids the caller must
## drop from CampAreaLayer.
func remove_zone(id: String) -> Array:
	var camp_ids: Array = []
	for i in zones.size():
		if str((zones[i] as Dictionary)["id"]) == id:
			zones.remove_at(i)
			break
	var keep: Array = []
	for l: Dictionary in lots:
		if str(l.get("zone_id", "")) == id:
			if not str(l.get("camp_area_id", "")).is_empty():
				camp_ids.append(str(l["camp_area_id"]))
		else:
			keep.append(l)
	lots = keep
	return camp_ids


## Topmost zone containing p, or "".
func zone_at(p: Vector2) -> String:
	var i := zones.size() - 1
	while i >= 0:
		var z: Dictionary = zones[i]
		if CampAreaLayer.contains(z, p):
			return str(z["id"])
		i -= 1
	return ""


func zones_by_id() -> Dictionary:
	var out := {}
	for z: Dictionary in zones:
		out[str(z["id"])] = z
	return out


static func _normalized_zone(rec: Dictionary) -> Dictionary:
	var holes: Array = []
	for h in rec.get("holes", []):
		if h is PackedVector2Array and (h as PackedVector2Array).size() >= 3:
			holes.append(h)
	var road_ids: Array = []
	for rid in rec.get("road_ids", []):
		if not road_ids.has(str(rid)):
			road_ids.append(str(rid))
	var stats: Variant = rec.get("stats", {})
	return {
		"id": str(rec.get("id", "")),
		"name": str(rec.get("name", "")),
		"polygon": rec.get("polygon", PackedVector2Array()),
		"holes": holes,
		"seed": int(rec.get("seed", 0)),
		"road_ids": road_ids,
		"spec": normalize_spec(rec.get("spec", {})),
		"features": _clean_features(rec.get("features", [])),
		"stats": stats if stats is Dictionary else {},
	}


# ---------------------------------------------------------------------------
# Lots
# ---------------------------------------------------------------------------

func get_lot(lot_id: String) -> Dictionary:
	for l: Dictionary in lots:
		if str(l["lot_id"]) == lot_id:
			return l
	return {}


func lots_for_zone(zone_id: String) -> Array:
	var out: Array = []
	for l: Dictionary in lots:
		if str(l.get("zone_id", "")) == zone_id:
			out.append(l)
	return out


func locked_lots_for_zone(zone_id: String) -> Array:
	var out: Array = []
	for l in lots_for_zone(zone_id):
		if bool((l as Dictionary).get("locked", false)):
			out.append(l)
	return out


## Topmost lot containing p, or "".
func lot_at(p: Vector2) -> String:
	var i := lots.size() - 1
	while i >= 0:
		var l: Dictionary = lots[i]
		if Geometry2D.is_point_in_polygon(p, l.get("polygon", PackedVector2Array())):
			return str(l["lot_id"])
		i -= 1
	return ""


func update_lot(lot_id: String, patch: Dictionary) -> bool:
	for i in lots.size():
		if str((lots[i] as Dictionary)["lot_id"]) == lot_id:
			var rec: Dictionary = (lots[i] as Dictionary).duplicate()
			for k in patch.keys():
				if k != "lot_id":
					rec[k] = patch[k]
			lots[i] = _normalized_lot(rec)
			return true
	return false


## Replace a zone's lots with a partition result (locked lots included in it
## already, untouched). Mints ids for new lots and writes the zone's stats.
## Returns the lot ids in order.
func apply_partition(zone_id: String, result: Dictionary) -> Array:
	var keep: Array = []
	for l: Dictionary in lots:
		if str(l.get("zone_id", "")) != zone_id:
			keep.append(l)
	var ids: Array = []
	for raw in result.get("lots", []):
		if not (raw is Dictionary) or keep.size() + ids.size() >= MAX_LOTS:
			continue
		var rec: Dictionary = (raw as Dictionary).duplicate(true)
		rec["zone_id"] = zone_id
		if str(rec.get("lot_id", "")).is_empty():
			rec["lot_id"] = "lot_%d" % _next_lot
			_next_lot += 1
		keep.append(_normalized_lot(rec))
		ids.append(str(rec["lot_id"]))
	lots = keep
	var z := get_zone(zone_id)
	if not z.is_empty():
		update_zone(zone_id, {"stats": result.get("stats", {})})
	return ids


static func _normalized_lot(rec: Dictionary) -> Dictionary:
	var ac: Variant = rec.get("assigned_camp", {})
	var side := int(rec.get("side", 0))
	return {
		"lot_id": str(rec.get("lot_id", "")),
		"zone_id": str(rec.get("zone_id", "")),
		"road_id": str(rec.get("road_id", "")),
		"side": 1 if side > 0 else (-1 if side < 0 else 0),
		"index": int(rec.get("index", 0)),
		"name": str(rec.get("name", "")),
		"camp_area_id": str(rec.get("camp_area_id", "")),
		"polygon": rec.get("polygon", PackedVector2Array()),
		"frontage_m": float(rec.get("frontage_m", 0.0)),
		"depth_m": float(rec.get("depth_m", 0.0)),
		"usable_m2": float(rec.get("usable_m2", 0.0)),
		"raw_m2": float(rec.get("raw_m2", 0.0)),
		"mean_slope_deg": float(rec.get("mean_slope_deg", 0.0)),
		"max_slope_deg": float(rec.get("max_slope_deg", 0.0)),
		"s_start": float(rec.get("s_start", 0.0)),
		"s_end": float(rec.get("s_end", 0.0)),
		"corner": bool(rec.get("corner", false)),
		"touches_road_ids": (rec.get("touches_road_ids", []) as Array).duplicate(),
		"locked": bool(rec.get("locked", false)),
		"heading_deg": fposmod(float(rec.get("heading_deg", 0.0)), 180.0),
		"features": _clean_features(rec.get("features", [])),
		"assigned_camp": clean_assignment(ac),
		"fairness": float(rec.get("fairness", 0.0)),
	}


static func clean_assignment(raw: Variant) -> Dictionary:
	if not (raw is Dictionary) or (raw as Dictionary).is_empty():
		return {}
	var a: Dictionary = raw
	var style := str(a.get("style", CampStyles.DEFAULT_STYLE))
	return {
		"roster_id": str(a.get("roster_id", "")),
		"name": str(a.get("name", "")),
		"style": style if CampStyles.is_valid(style) else CampStyles.DEFAULT_STYLE,
		"headcount": clampi(int(a.get("headcount", 0)), 0, 5000),
		"requirements": _clean_features(a.get("requirements", [])),
		"manual": bool(a.get("manual", false)),
		# Given by festival mode to a lot nobody had assigned; Clear takes
		# these back and leaves the player's own assignments.
		"festival_seeded": bool(a.get("festival_seeded", false)),
	}


# ---------------------------------------------------------------------------
# Roster
# ---------------------------------------------------------------------------

func add_roster_entry(params: Dictionary) -> String:
	if roster.size() >= MAX_ROSTER:
		return ""
	var id := "camp_r_%d" % _next_roster
	_next_roster += 1
	var rec := params.duplicate()
	rec["id"] = id
	roster.append(_normalized_roster(rec))
	return id


func get_roster_entry(id: String) -> Dictionary:
	for e: Dictionary in roster:
		if str(e["id"]) == id:
			return e
	return {}


func update_roster_entry(id: String, patch: Dictionary) -> bool:
	for i in roster.size():
		if str((roster[i] as Dictionary)["id"]) == id:
			var rec: Dictionary = (roster[i] as Dictionary).duplicate()
			for k in patch.keys():
				if k != "id":
					rec[k] = patch[k]
			roster[i] = _normalized_roster(rec)
			return true
	return false


## Also clears the entry off any lot it was assigned to.
func remove_roster_entry(id: String) -> bool:
	for i in roster.size():
		if str((roster[i] as Dictionary)["id"]) == id:
			roster.remove_at(i)
			for l: Dictionary in lots:
				var ac: Dictionary = l.get("assigned_camp", {})
				if str(ac.get("roster_id", "")) == id:
					l["assigned_camp"] = {}
			return true
	return false


static func _normalized_roster(rec: Dictionary) -> Dictionary:
	var cls := str(rec.get("size_class", "M"))
	var style := str(rec.get("style", CampStyles.DEFAULT_STYLE))
	var adj: Array = []
	for a in rec.get("adjacent_to", []):
		adj.append(str(a))
	return {
		"id": str(rec.get("id", "")),
		"name": str(rec.get("name", rec.get("id", ""))),
		"size_class": cls if FestivalAssigner.SIZE_CLASSES.has(cls) else "M",
		"headcount": clampi(int(rec.get("headcount", 0)), 0, 5000),
		"style": style if CampStyles.is_valid(style) else CampStyles.DEFAULT_STYLE,
		"requirements": _clean_features(rec.get("requirements", [])),
		"adjacent_to": adj,
		"requested_m2": maxf(float(rec.get("requested_m2", 0.0)), 0.0),
	}


# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

func serialize() -> Dictionary:
	var rd: Array = []
	for r: Dictionary in roads:
		rd.append({
			"id": str(r["id"]), "name": str(r["name"]),
			"points": CampAreaLayer._ser_points(r["points"]),
			"half_width_m": float(r["half_width_m"]), "surface": str(r["surface"]),
			"flattened": bool(r["flattened"]), "tags": (r["tags"] as Dictionary).duplicate(),
		})
	var zd: Array = []
	for z: Dictionary in zones:
		var holes: Array = []
		for h in z.get("holes", []):
			holes.append(CampAreaLayer._ser_points(h))
		zd.append({
			"id": str(z["id"]), "name": str(z["name"]),
			"polygon": CampAreaLayer._ser_points(z["polygon"]), "holes": holes,
			"seed": int(z["seed"]), "road_ids": (z["road_ids"] as Array).duplicate(),
			"spec": (z["spec"] as Dictionary).duplicate(true),
			"features": (z["features"] as Array).duplicate(),
			"stats": (z["stats"] as Dictionary).duplicate(true),
		})
	var ld: Array = []
	for l: Dictionary in lots:
		var d := l.duplicate(true)
		d["polygon"] = CampAreaLayer._ser_points(l["polygon"])
		ld.append(d)
	var rs: Array = []
	for e: Dictionary in roster:
		rs.append(e.duplicate(true))
	return {"version": VERSION, "next_road": _next_road, "next_zone": _next_zone,
		"next_lot": _next_lot, "next_roster": _next_roster,
		"roads": rd, "zones": zd, "lots": ld, "roster": rs}


func deserialize(data: Dictionary) -> void:
	roads = []
	zones = []
	lots = []
	roster = []
	_next_road = maxi(int(data.get("next_road", 1)), 1)
	_next_zone = maxi(int(data.get("next_zone", 1)), 1)
	_next_lot = maxi(int(data.get("next_lot", 1)), 1)
	_next_roster = maxi(int(data.get("next_roster", 1)), 1)
	for raw in data.get("roads", []):
		if not (raw is Dictionary):
			continue
		var d: Dictionary = raw
		var pts := CampAreaLayer._deser_points(d.get("points", []))
		var id := str(d.get("id", ""))
		if pts.size() < 2 or id.is_empty() or not get_road(id).is_empty():
			continue
		var rec := d.duplicate()
		rec["points"] = pts
		roads.append(_normalized_road(rec))
		_next_road = maxi(_next_road, int(id.trim_prefix("road_")) + 1)
	for raw in data.get("zones", []):
		if not (raw is Dictionary):
			continue
		var d: Dictionary = raw
		var pts := CampAreaLayer._deser_points(d.get("polygon", []))
		var id := str(d.get("id", ""))
		if pts.size() < 3 or id.is_empty() or not get_zone(id).is_empty():
			continue
		var holes: Array = []
		for h in d.get("holes", []):
			var hp := CampAreaLayer._deser_points(h)
			if hp.size() >= 3:
				holes.append(hp)
		var rec := d.duplicate()
		rec["polygon"] = pts
		rec["holes"] = holes
		zones.append(_normalized_zone(rec))
		_next_zone = maxi(_next_zone, int(id.trim_prefix("zone_")) + 1)
	for raw in data.get("lots", []):
		if not (raw is Dictionary):
			continue
		var d: Dictionary = raw
		var pts := CampAreaLayer._deser_points(d.get("polygon", []))
		var id := str(d.get("lot_id", ""))
		if pts.size() < 3 or id.is_empty() or not get_lot(id).is_empty():
			continue
		var rec := d.duplicate()
		rec["polygon"] = pts
		lots.append(_normalized_lot(rec))
		_next_lot = maxi(_next_lot, int(id.trim_prefix("lot_")) + 1)
	for raw in data.get("roster", []):
		if not (raw is Dictionary):
			continue
		var id := str((raw as Dictionary).get("id", ""))
		if id.is_empty() or not get_roster_entry(id).is_empty():
			continue
		roster.append(_normalized_roster(raw))
		_next_roster = maxi(_next_roster, int(id.trim_prefix("camp_r_")) + 1)


func snapshot() -> Dictionary:
	return serialize()


func restore(snap: Dictionary) -> void:
	deserialize(snap)
