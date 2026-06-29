extends RefCounted
class_name TopojsonLoader
## Decodes world-atlas countries-110m.json: arcs, stitch rings, point-in-land, coast polylines.

const DEFAULT_PATH: String = "res://data/countries-110m.json"

## Each outer ring as PackedVector2 in (lon, lat)
var _outer_rings: Array[PackedVector2Array] = []
var _bbox_cache: Array[Rect2] = []
var _all_arcs: Array[PackedVector2Array] = []
var _loaded: bool = false


func is_loaded() -> bool:
	return _loaded


func load_from_path(path: String = DEFAULT_PATH) -> bool:
	_loaded = false
	_outer_rings.clear()
	_bbox_cache.clear()
	_all_arcs.clear()
	if not FileAccess.file_exists(path):
		push_warning("TopojsonLoader: missing %s" % path)
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var p: Variant = JSON.parse_string(f.get_as_text())
	if not (p is Dictionary):
		return false
	var d: Dictionary = p
	if str(d.get("type", "")) != "Topology":
		return false
	var t: Dictionary = d.get("transform", {})
	if t.is_empty():
		return false
	var scale: Variant = t.get("scale", [1.0, 1.0])
	var trans: Variant = t.get("translate", [0.0, 0.0])
	if not (scale is Array) or not (trans is Array):
		return false
	var sx: float = float((scale as Array)[0])
	var sy: float = float((scale as Array)[1])
	var tx: float = float((trans as Array)[0])
	var ty: float = float((trans as Array)[1])

	var arcs_raw: Variant = d.get("arcs", [])
	if not (arcs_raw is Array):
		return false
	for a in (arcs_raw as Array):
		_all_arcs.append(_decode_arc_deltas(a as Array, sx, sy, tx, ty))

	var objects: Variant = d.get("objects", {})
	if not (objects is Dictionary):
		return false
	var odict: Dictionary = objects
	# world-atlas ships "countries" GeometryCollection; web uses "land" — support both
	var key: String = "land" if odict.has("land") else "countries"
	if not odict.has(key):
		return false
	var obj: Variant = odict[key]
	if not (obj is Dictionary):
		return false
	var geom: Variant = (obj as Dictionary).get("geometries", [])
	if not (geom is Array):
		return false
	for g in (geom as Array):
		if not (g is Dictionary):
			continue
		var gdict: Dictionary = g
		var tname: String = str(gdict.get("type", ""))
		if tname == "Polygon":
			_process_polygon_rings(gdict)
		elif tname == "MultiPolygon":
			_process_multipolygon(gdict)
		_loaded = true
	if _outer_rings.is_empty():
		_loaded = false
		return _loaded
	# bounding boxes for quick reject
	_bbox_cache.resize(_outer_rings.size())
	for i in range(_outer_rings.size()):
		_bbox_cache[i] = _ring_bbox(_outer_rings[i])
	return _loaded


func get_outer_rings() -> Array[PackedVector2Array]:
	return _outer_rings


func get_ring_bbox_cache() -> Array[Rect2]:
	return _bbox_cache


func _decode_arc_deltas(arc: Array, sx: float, sy: float, tx: float, ty: float) -> PackedVector2Array:
	# Cumulative in quantized space
	var qx: float = 0.0
	var qy: float = 0.0
	var res := PackedVector2Array()
	for pt in arc:
		if not (pt is Array):
			continue
		var ap: Array = pt
		if ap.size() < 2:
			continue
		qx += float(ap[0])
		qy += float(ap[1])
		var lon: float = qx * sx + tx
		var lat: float = qy * sy + ty
		res.append(Vector2(lon, lat))
	return res


func _stitch(arc_list: Array) -> PackedVector2Array:
	## Join topojson arc indices (signed = reverse) into one ring
	var out := PackedVector2Array()
	for k in range(arc_list.size()):
		var si: int = int(arc_list[k])
		var use_rev: bool = (si < 0)
		var ai: int = (si) if (si >= 0) else (~si)
		if ai < 0 or ai >= _all_arcs.size():
			continue
		var seg: PackedVector2Array = _all_arcs[ai].duplicate()
		if use_rev:
			seg.reverse()
		if out.is_empty():
			out = seg
			continue
		# de-duplicate shared vertex
		if seg.is_empty():
			continue
		if out[out.size() - 1].distance_to(seg[0]) < 1.0e-4:
			for t in range(1, seg.size()):
				out.append(seg[t])
		else:
			for t in range(seg.size()):
				out.append(seg[t])
	return out


func _process_polygon_rings(g: Dictionary) -> void:
	## Only outer ring (arcs[0]) — ignore holes; avoids classifying Great Lakes as land, etc. at 2° scale
	var al: Variant = g.get("arcs", [])
	if not (al is Array) or (al as Array).is_empty():
		return
	var first_ring: Variant = (al as Array)[0]
	if not (first_ring is Array):
		return
	var r: PackedVector2Array = _stitch(first_ring as Array)
	if r.size() < 3:
		return
	_outer_rings.append(r)


func _process_multipolygon(g: Dictionary) -> void:
	## arcs: [ [ [arc indices...] ], [ polygon 2 ] ]
	var al: Variant = g.get("arcs", [])
	if not (al is Array):
		return
	for poly in (al as Array):
		# each poly is list of rings
		if not (poly is Array) or (poly as Array).is_empty():
			continue
		for ri in range((poly as Array).size()):
			var ring_arcs: Variant = (poly as Array)[ri]
			if not (ring_arcs is Array):
				continue
			var r2: PackedVector2Array = _stitch(ring_arcs as Array)
			if r2.size() < 3:
				continue
			# In MultiPolygon, first ring of first polygon = outer, subsequent rings in same poly = holes
			# We add all rings as point-in test: odd-even over union of outers is wrong for holes, but
			# for 2° grid we add outer only for inclusion; holes = lakes — optional second pass
			if ri == 0:
				_outer_rings.append(r2)
			else:
				# store as negative-space later — skip for fast path (Great Lakes, etc. may be wrong)
				pass


func _ring_bbox(ring: PackedVector2Array) -> Rect2:
	if ring.is_empty():
		return Rect2()
	var mn: Vector2 = ring[0]
	var mx: Vector2 = ring[0]
	for i in range(1, ring.size()):
		mn = mn.min(ring[i])
		mx = mx.max(ring[i])
	return Rect2(mn, mx - mn)


## Point-in-land: true if inside any outer ring and not in hole (we skip holes — rare errors OK)
func is_on_land(lng: float, lat: float) -> bool:
	var p := Vector2(lng, lat)
	for i in range(_outer_rings.size()):
		var bb: Rect2 = _bbox_cache[i]
		# Slight grow for edge cells
		var exp := bb.grow(0.1)
		if p.x < exp.position.x or p.x > exp.end.x or p.y < exp.position.y or p.y > exp.end.y:
			continue
		if _point_in_ring(p, _outer_rings[i]):
			return true
	return false


func _point_in_ring(pt: Vector2, ring: PackedVector2Array) -> bool:
	if ring.size() < 3:
		return false
	var y: float = pt.y
	var n: int = ring.size()
	var j: int = n - 1
	var c: bool = false
	for i0 in range(n):
		var a: Vector2 = ring[i0]
		var b: Vector2 = ring[j]
		if (a.y > y) != (b.y > y):
			var xin: float = (b.x - a.x) * (y - a.y) / (b.y - a.y + 1.0e-20) + a.x
			if pt.x < xin:
				c = not c
		j = i0
	return c
