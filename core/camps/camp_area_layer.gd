class_name CampAreaLayer
extends RefCounted

## Per-map store of player-painted camp areas (user://maps/camp_areas_*.json).
##
## A camp AREA is a polygon plus the handful of numbers that decide what stands
## in it: a style, a density, a seed and a heading. Nothing about the tents
## themselves is saved — CampLayoutGenerator rebuilds them from the record, and
## because its lattice is anchored to the WORLD and seeded per cell, the same
## record always produces the same camp.
##
## The polygon operations live here (paint = union, erase = difference) rather
## than in the UI so they can be asserted offline.
##
## Record:
##   id, name, polygon (PackedVector2Array, local metres XZ), holes (Array of
##   PackedVector2Array), style, density, seed, heading_deg (compass bearing of
##   the long axis, 0..180; < 0 = resolve automatically), heading_auto (the UI's
##   memory of how the heading was chosen), align_jitter_deg, light_density,
##   group_id (set on plots made by one Subdivide).

const VERSION := 1
const MAX_AREAS := 400
## Pieces smaller than this are dropped when an erase or a paint leaves scraps.
const MIN_AREA_M2 := 20.0

var areas: Array = []  # Array[Dictionary]
## This MAP's edit to each style ({style_id: entry}) — "all camps of this type
## on this map". Sits between the global style and a camp's own override.
var map_styles: Dictionary = {}
var _next_id := 1


static func create_empty() -> CampAreaLayer:
	return CampAreaLayer.new()


static func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/camp_areas_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


func save(lat: float, lon: float) -> bool:
	return save_to(save_path_for_map(lat, lon))


func save_to(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(serialize()))
	return true


func load_for_map(lat: float, lon: float) -> bool:
	return load_from(save_path_for_map(lat, lon))


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


# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

## Append one area as-is (no merging). Returns its id, or "" when refused.
func add(poly: PackedVector2Array, params: Dictionary = {}) -> String:
	if poly.size() < 3 or areas.size() >= MAX_AREAS:
		return ""
	var ring := _ccw(poly)
	if polygon_area(ring) < MIN_AREA_M2:
		return ""
	var id := "camp_%d" % _next_id
	_next_id += 1
	var rec := _normalized({
		"id": id,
		"name": str(params.get("name", "Camp %d" % (_next_id - 1))),
		"polygon": ring,
		"holes": params.get("holes", []),
		"style": params.get("style", CampStyles.DEFAULT_STYLE),
		"density": params.get("density", 0.8),
		"seed": params.get("seed", _poly_seed(ring)),
		"heading_deg": params.get("heading_deg", -1.0),
		"heading_auto": params.get("heading_auto", float(params.get("heading_deg", -1.0)) < 0.0),
		"align_jitter_deg": params.get("align_jitter_deg", 5.0),
		"light_density": params.get("light_density", 1.0),
		"group_id": params.get("group_id", ""),
		# A new camp draws one of its style's saved layouts, by weight, off its
		# own seed — and KEEPS it, so adding a layout later never restyles a
		# camp that is already standing.
		"variant": params.get("variant", CampStyles.pick_variant(
			str(params.get("style", CampStyles.DEFAULT_STYLE)),
			int(params.get("seed", _poly_seed(ring))))),
		"style_override": params.get("style_override", {}),
		"edits": params.get("edits", {}),
	})
	areas.append(rec)
	return id


func index_of(id: String) -> int:
	for i in areas.size():
		if str((areas[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


func get_area(id: String) -> Dictionary:
	var at := index_of(id)
	return (areas[at] as Dictionary) if at >= 0 else {}


func update(id: String, patch: Dictionary) -> bool:
	var at := index_of(id)
	if at < 0:
		return false
	var rec: Dictionary = (areas[at] as Dictionary).duplicate()
	for k in patch.keys():
		if k != "id":
			rec[k] = patch[k]
	areas[at] = _normalized(rec)
	return true


func remove(id: String) -> bool:
	var at := index_of(id)
	if at < 0:
		return false
	areas.remove_at(at)
	return true


## Topmost (most recently added) area containing the point, or "".
func area_at(p: Vector2) -> String:
	var i := areas.size() - 1
	while i >= 0:
		var rec: Dictionary = areas[i]
		if contains(rec, p):
			return str(rec["id"])
		i -= 1
	return ""


static func contains(rec: Dictionary, p: Vector2) -> bool:
	var poly: PackedVector2Array = rec.get("polygon", PackedVector2Array())
	if poly.size() < 3 or not Geometry2D.is_point_in_polygon(p, poly):
		return false
	for h in rec.get("holes", []):
		if h is PackedVector2Array and Geometry2D.is_point_in_polygon(p, h):
			return false
	return true


## Net area of a record (outline minus holes), m².
static func record_area(rec: Dictionary) -> float:
	var a := polygon_area(rec.get("polygon", PackedVector2Array()))
	for h in rec.get("holes", []):
		if h is PackedVector2Array:
			a -= polygon_area(h)
	return maxf(a, 0.0)


# ---------------------------------------------------------------------------
# Paint / erase
# ---------------------------------------------------------------------------

## Paint a polygon. It GROWS an existing camp when it overlaps one of the same
## style that is not part of a subdivision (that camp keeps its id, seed,
## heading and settings, so nothing already standing moves); otherwise it becomes
## a new camp. Either way the painted ground is carved out of every OTHER camp it
## crosses — the newest paint wins, two camps never fill the same ground.
##
## Returns {"id": String, "changed": Array[String], "removed": Array[String]}.
func paint(poly: PackedVector2Array, params: Dictionary = {}) -> Dictionary:
	var out := {"id": "", "changed": [], "removed": []}
	if poly.size() < 3:
		return out
	var ring := _ccw(poly)
	if polygon_area(ring) < MIN_AREA_M2:
		return out
	var style_id := str(params.get("style", CampStyles.DEFAULT_STYLE))

	# Which existing camps does this stroke extend?
	var merge_ids: Array = []
	for rec: Dictionary in areas:
		if str(rec.get("style", "")) != style_id or not str(rec.get("group_id", "")).is_empty():
			continue
		if _overlaps(rec.get("polygon", PackedVector2Array()), ring):
			merge_ids.append(str(rec["id"]))

	# Everything else it crosses loses that ground.
	var others: Array = []
	for rec: Dictionary in areas:
		if not merge_ids.has(str(rec["id"])):
			others.append(str(rec["id"]))
	var carve := _erase_from(ring, others)
	out["changed"].append_array(carve["changed"])
	out["removed"].append_array(carve["removed"])

	if merge_ids.is_empty():
		var id := add(ring, params)
		out["id"] = id
		if not id.is_empty():
			out["changed"].append(id)
		return out

	# Union the stroke into the first match; fold any further matches into it.
	var target_id := str(merge_ids[0])
	var outline := ring
	var holes: Array = []
	for mid in merge_ids:
		var rec := get_area(str(mid))
		var merged := _union(outline, rec.get("polygon", PackedVector2Array()))
		if merged["outers"].size() != 1:
			continue  # numerically disjoint after all; leave that camp alone
		outline = merged["outers"][0]
		holes.append_array(merged["holes"])
		# The camp's own holes survive, minus whatever the stroke painted over.
		for h in rec.get("holes", []):
			if h is PackedVector2Array:
				for piece in Geometry2D.clip_polygons(h, ring):
					if not Geometry2D.is_polygon_clockwise(piece) \
							and polygon_area(piece) >= 1.0:
						holes.append(piece)
		if str(mid) != target_id:
			remove(str(mid))
			out["removed"].append(str(mid))
	update(target_id, {"polygon": outline, "holes": holes})
	out["id"] = target_id
	out["changed"].append(target_id)
	return out


## Remove a polygon of ground from every camp it touches. A camp cut in two
## becomes two camps (same settings and seed, so the surviving tents do not
## move); a cut in the middle becomes a hole.
## Returns {"changed": Array[String], "removed": Array[String]}.
func erase(poly: PackedVector2Array) -> Dictionary:
	if poly.size() < 3:
		return {"changed": [], "removed": []}
	var ids: Array = []
	for rec: Dictionary in areas:
		ids.append(str(rec["id"]))
	return _erase_from(_ccw(poly), ids)


func _erase_from(ring: PackedVector2Array, ids: Array) -> Dictionary:
	var out := {"changed": [], "removed": []}
	for id in ids:
		var rec := get_area(str(id))
		if rec.is_empty():
			continue
		var poly: PackedVector2Array = rec.get("polygon", PackedVector2Array())
		if not _overlaps(poly, ring):
			continue
		var outers: Array = []
		var holes: Array = []
		for piece: PackedVector2Array in Geometry2D.clip_polygons(poly, ring):
			if Geometry2D.is_polygon_clockwise(piece):
				var h := piece.duplicate()
				h.reverse()
				holes.append(h)
			elif polygon_area(piece) >= MIN_AREA_M2:
				outers.append(piece)
		# Existing holes that the eraser did not swallow whole.
		for h in rec.get("holes", []):
			if h is PackedVector2Array:
				holes.append(h)
		if outers.is_empty():
			remove(str(id))
			out["removed"].append(str(id))
			continue
		for i in outers.size():
			var mine: Array = []
			for h: PackedVector2Array in holes:
				if h.size() >= 3 and Geometry2D.is_point_in_polygon(_inner_point(h), outers[i]):
					mine.append(h)
			if i == 0:
				update(str(id), {"polygon": outers[i], "holes": mine})
				out["changed"].append(str(id))
			else:
				var params := rec.duplicate()
				params["holes"] = mine
				params["name"] = "%s (%d)" % [str(rec.get("name", "Camp")), i + 1]
				var nid := add(outers[i], params)
				if not nid.is_empty():
					out["changed"].append(nid)
	return out


# ---------------------------------------------------------------------------
# Serialization. Every record key must appear in BOTH directions — a key
# written here and not read back is silently lost on the next load.
# ---------------------------------------------------------------------------

func serialize() -> Dictionary:
	var arr: Array = []
	for rec: Dictionary in areas:
		var holes: Array = []
		for h in rec.get("holes", []):
			if h is PackedVector2Array and (h as PackedVector2Array).size() >= 3:
				holes.append(_ser_points(h))
		arr.append({
			"id": str(rec.get("id", "")),
			"name": str(rec.get("name", "")),
			"polygon": _ser_points(rec.get("polygon", PackedVector2Array())),
			"holes": holes,
			"style": str(rec.get("style", CampStyles.DEFAULT_STYLE)),
			"density": float(rec.get("density", 0.8)),
			"seed": int(rec.get("seed", 0)),
			"heading_deg": float(rec.get("heading_deg", -1.0)),
			"heading_auto": bool(rec.get("heading_auto", true)),
			"align_jitter_deg": float(rec.get("align_jitter_deg", 5.0)),
			"light_density": float(rec.get("light_density", 1.0)),
			"group_id": str(rec.get("group_id", "")),
			"variant": str(rec.get("variant", "")),
			"style_override": rec.get("style_override", {}),
			"edits": rec.get("edits", {}),
		})
	return {"version": VERSION, "next_id": _next_id, "areas": arr,
		"map_styles": map_styles.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	areas = []
	map_styles = {}
	var ms: Variant = data.get("map_styles", {})
	if ms is Dictionary:
		for sid in (ms as Dictionary).keys():
			if CampStyles.STYLES.has(str(sid)) and ms[sid] is Dictionary:
				var e := CampStyleStore.normalize_entry(ms[sid], _lenient_models(ms[sid]))
				if not e.is_empty():
					map_styles[str(sid)] = e
	_next_id = maxi(int(data.get("next_id", 1)), 1)
	for raw in data.get("areas", []):
		if not (raw is Dictionary):
			continue
		var d: Dictionary = raw
		var pts := _deser_points(d.get("polygon", []))
		var id := str(d.get("id", ""))
		if pts.size() < 3 or id.is_empty() or index_of(id) >= 0:
			continue
		var holes: Array = []
		for h in d.get("holes", []):
			var hp := _deser_points(h)
			if hp.size() >= 3:
				holes.append(hp)
		areas.append(_normalized({
			"id": id,
			"name": str(d.get("name", id)),
			"polygon": pts,
			"holes": holes,
			"style": d.get("style", CampStyles.DEFAULT_STYLE),
			"density": d.get("density", 0.8),
			"seed": d.get("seed", _poly_seed(pts)),
			"heading_deg": d.get("heading_deg", -1.0),
			"heading_auto": d.get("heading_auto", true),
			"align_jitter_deg": d.get("align_jitter_deg", 5.0),
			"light_density": d.get("light_density", 1.0),
			"group_id": d.get("group_id", ""),
			"variant": d.get("variant", ""),
			"style_override": d.get("style_override", {}),
			"edits": d.get("edits", {}),
		}))
		# Ids are "camp_<n>"; never hand one out twice even if next_id was lost.
		var n := int(id.trim_prefix("camp_"))
		_next_id = maxi(_next_id, n + 1)


## Whole-layer snapshot for undo.
func snapshot() -> Dictionary:
	return serialize()


func restore(snap: Dictionary) -> void:
	deserialize(snap)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _normalized(rec: Dictionary) -> Dictionary:
	var style_id := str(rec.get("style", CampStyles.DEFAULT_STYLE))
	if not CampStyles.is_valid(style_id):
		style_id = CampStyles.DEFAULT_STYLE
	var holes: Array = []
	for h in rec.get("holes", []):
		if h is PackedVector2Array and (h as PackedVector2Array).size() >= 3:
			holes.append(h)
	var heading := float(rec.get("heading_deg", -1.0))
	if heading >= 0.0:
		heading = fposmod(heading, 180.0)
	return {
		"id": str(rec.get("id", "")),
		"name": str(rec.get("name", "")),
		"polygon": rec.get("polygon", PackedVector2Array()),
		"holes": holes,
		"style": style_id,
		"density": clampf(float(rec.get("density", 0.8)), 0.2, 1.0),
		"seed": int(rec.get("seed", 0)),
		"heading_deg": heading,
		"heading_auto": bool(rec.get("heading_auto", true)),
		"align_jitter_deg": clampf(float(rec.get("align_jitter_deg", 5.0)), 0.0, 45.0),
		"light_density": clampf(float(rec.get("light_density", 1.0)), 0.0, 2.0),
		"group_id": str(rec.get("group_id", "")),
		"variant": str(rec.get("variant", "")),
		"style_override": _clean_override(rec.get("style_override", {})),
		"edits": _clean_edits(rec.get("edits", {})),
	}


## Model templates are kept even when the model is not registered right now
## (the style file may load after the map, or live on another machine): the
## resolver simply ignores a template it cannot find.
static func _lenient_models(entry: Variant) -> Dictionary:
	var out := {}
	if entry is Dictionary:
		for tid in ((entry as Dictionary).get("templates", {}) as Dictionary).keys():
			var t := str(tid)
			if t.begins_with(CampStyles.MODEL_TEMPLATE_PREFIX):
				out[t.substr(CampStyles.MODEL_TEMPLATE_PREFIX.length())] = true
	return out


static func _clean_override(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	return CampStyleStore.normalize_entry(raw, _lenient_models(raw))


## {key: {yaw_deg, scale, removed}} — only entries that actually change something.
static func _clean_edits(raw: Variant) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	for key in (raw as Dictionary).keys():
		var e: Variant = raw[key]
		if not (e is Dictionary):
			continue
		var yaw := fposmod(float((e as Dictionary).get("yaw_deg", 0.0)) + 180.0, 360.0) - 180.0
		var scale := clampf(float((e as Dictionary).get("scale", 1.0)), 0.3, 3.0)
		var removed := bool((e as Dictionary).get("removed", false))
		if removed:
			out[str(key)] = {"removed": true}
		elif absf(yaw) > 0.01 or absf(scale - 1.0) > 0.001:
			out[str(key)] = {"yaw_deg": yaw, "scale": scale}
	return out


static func polygon_area(poly: PackedVector2Array) -> float:
	return absf(_signed_area(poly))


static func _signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		a += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return a * 0.5


static func _ccw(poly: PackedVector2Array) -> PackedVector2Array:
	var out := poly.duplicate()
	if Geometry2D.is_polygon_clockwise(out):
		out.reverse()
	return out


static func _overlaps(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() < 3 or b.size() < 3:
		return false
	for piece in Geometry2D.intersect_polygons(a, b):
		if polygon_area(piece) > 0.25:
			return true
	return false


## {"outers": Array[PackedVector2Array], "holes": Array[PackedVector2Array]}
static func _union(a: PackedVector2Array, b: PackedVector2Array) -> Dictionary:
	var outers: Array = []
	var holes: Array = []
	for piece: PackedVector2Array in Geometry2D.merge_polygons(a, b):
		if Geometry2D.is_polygon_clockwise(piece):
			if polygon_area(piece) >= 1.0:
				var h := piece.duplicate()
				h.reverse()
				holes.append(h)
		else:
			outers.append(piece)
	return {"outers": outers, "holes": holes}


## A point strictly inside a (simple) ring — the centroid of its first ear.
static func _inner_point(ring: PackedVector2Array) -> Vector2:
	var tris := Geometry2D.triangulate_polygon(ring)
	if tris.size() >= 3:
		return (ring[tris[0]] + ring[tris[1]] + ring[tris[2]]) / 3.0
	var c := Vector2.ZERO
	for p in ring:
		c += p
	return c / float(maxi(ring.size(), 1))


static func _poly_seed(poly: PackedVector2Array) -> int:
	var h := 17
	for p in poly:
		h = (h * 31 + int(p.x * 10.0)) & 0x7fffffff
		h = (h * 31 + int(p.y * 10.0)) & 0x7fffffff
	return h


static func _ser_points(pts: PackedVector2Array) -> Array:
	var arr: Array = []
	for p in pts:
		arr.append([p.x, p.y])
	return arr


static func _deser_points(raw: Variant) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if raw is Array:
		for pair in raw:
			if pair is Array and (pair as Array).size() >= 2:
				pts.append(Vector2(float(pair[0]), float(pair[1])))
	return pts
