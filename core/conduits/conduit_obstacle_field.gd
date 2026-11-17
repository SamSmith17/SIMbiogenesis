class_name ConduitObstacleField
extends RefCounted

## What a conduit run has to go round: placed props as boxes with their REAL
## height, and OSM buildings as wall prisms. The old obstacle list stretched
## every prop to a 100 m column, so nothing could ever step over a low crate or
## run along a wall at head height, and it held no buildings at all.
##
## Pure data + geometry once built (the scene walk is `from_scene`). Spatial
## hash on 8 m XZ bins so a run only looks at what is near it. Ground height is
## taken ONCE per footprint at build time, never per grid cell (the AMD TDR rule
## that killed the old full-site A*).

const BIN := 8.0
## Props wider than this are terrain shells or whole camps, not obstacles.
const MAX_PROP_SPAN_M := 40.0

## {min: Vector3, max: Vector3, prop: String}
var boxes: Array = []
## {poly: PackedVector2Array, y0: float, y1: float, min: Vector2, max: Vector2}
var prisms: Array = []
var _bins: Dictionary = {}
var _by_prop: Dictionary = {}
var _built := false
var revision: int = 0


func add_box(aabb: AABB, prop_id: String = "") -> void:
	var e := {"min": aabb.position, "max": aabb.end, "prop": prop_id}
	if not prop_id.is_empty():
		_by_prop[prop_id] = boxes.size()
	boxes.append(e)
	_built = false


func add_prism(poly: PackedVector2Array, y0: float, y1: float) -> void:
	if poly.size() < 3 or y1 <= y0:
		return
	var mn := poly[0]
	var mx := poly[0]
	for p: Vector2 in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	prisms.append({"poly": poly, "y0": y0, "y1": y1, "min": mn, "max": mx})
	_built = false


func is_empty() -> bool:
	return boxes.is_empty() and prisms.is_empty()


## The world box of a placed prop (empty AABB when the prop is not in the field).
func box_of(prop_id: String) -> AABB:
	if prop_id.is_empty() or not _by_prop.has(prop_id):
		return AABB()
	var e: Dictionary = boxes[int(_by_prop[prop_id])]
	return AABB(e["min"] as Vector3, (e["max"] as Vector3) - (e["min"] as Vector3))


func build_index() -> void:
	_bins.clear()
	for i: int in range(boxes.size()):
		var e: Dictionary = boxes[i]
		_insert(i, Vector2((e["min"] as Vector3).x, (e["min"] as Vector3).z),
			Vector2((e["max"] as Vector3).x, (e["max"] as Vector3).z))
	for j: int in range(prisms.size()):
		var p: Dictionary = prisms[j]
		_insert(-(j + 1), p["min"] as Vector2, p["max"] as Vector2)
	_built = true
	revision += 1


func _insert(entry: int, mn: Vector2, mx: Vector2) -> void:
	var b0 := Vector2i(int(floor(mn.x / BIN)), int(floor(mn.y / BIN)))
	var b1 := Vector2i(int(floor(mx.x / BIN)), int(floor(mx.y / BIN)))
	for bx: int in range(b0.x, b1.x + 1):
		for bz: int in range(b0.y, b1.y + 1):
			var k := Vector2i(bx, bz)
			if not _bins.has(k):
				_bins[k] = PackedInt32Array()
			var arr: PackedInt32Array = _bins[k]
			arr.append(entry)
			_bins[k] = arr


## Entries (>= 0 box index, < 0 prism -(i+1)) overlapping an XZ rectangle,
## sorted so every caller sees them in the same order.
func query_xz(mn: Vector2, mx: Vector2) -> PackedInt32Array:
	if not _built:
		build_index()
	var seen := {}
	var b0 := Vector2i(int(floor(mn.x / BIN)), int(floor(mn.y / BIN)))
	var b1 := Vector2i(int(floor(mx.x / BIN)), int(floor(mx.y / BIN)))
	for bx: int in range(b0.x, b1.x + 1):
		for bz: int in range(b0.y, b1.y + 1):
			var k := Vector2i(bx, bz)
			if not _bins.has(k):
				continue
			for e: int in (_bins[k] as PackedInt32Array):
				seen[e] = true
	var out := PackedInt32Array(seen.keys())
	out.sort()
	return out


## A stable number for what stands in a rectangle — part of a run's dirty key,
## so moving a prop next to a run re-routes it and moving one far away does not.
func fingerprint_xz(mn: Vector2, mx: Vector2) -> int:
	var parts: Array = []
	for e: int in query_xz(mn, mx):
		if e >= 0:
			var b: Dictionary = boxes[e]
			parts.append([_r(b["min"] as Vector3), _r(b["max"] as Vector3)])
		else:
			var p: Dictionary = prisms[-e - 1]
			parts.append([_r2(p["min"] as Vector2), _r2(p["max"] as Vector2), p["y1"]])
	return parts.hash()


static func _r(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x * 20.0), roundi(v.y * 20.0), roundi(v.z * 20.0))


static func _r2(v: Vector2) -> Vector2i:
	return Vector2i(roundi(v.x * 20.0), roundi(v.y * 20.0))


## Is `p` inside any obstacle grown by `c`? `entries` limits the test to a
## query result (pass the solver's region list; empty = query here).
func point_blocked(p: Vector3, c: float, entries: PackedInt32Array) -> bool:
	for e: int in entries:
		if e >= 0:
			var b: Dictionary = boxes[e]
			var mn: Vector3 = b["min"]
			var mx: Vector3 = b["max"]
			if p.x > mn.x - c and p.x < mx.x + c and p.y > mn.y - c and p.y < mx.y + c \
					and p.z > mn.z - c and p.z < mx.z + c:
				return true
		else:
			var pr: Dictionary = prisms[-e - 1]
			if p.y < float(pr["y0"]) - c or p.y > float(pr["y1"]) + c:
				continue
			var q := Vector2(p.x, p.z)
			var pmn: Vector2 = pr["min"]
			var pmx: Vector2 = pr["max"]
			if q.x < pmn.x - c or q.x > pmx.x + c or q.y < pmn.y - c or q.y > pmx.y + c:
				continue
			var poly: PackedVector2Array = pr["poly"]
			if Geometry2D.is_point_in_polygon(q, poly) or _dist_to_poly(q, poly) < c:
				return true
	return false


## Does the segment a→b pass through any obstacle grown by `c`?
func segment_blocked(a: Vector3, b: Vector3, c: float, entries: PackedInt32Array) -> bool:
	for e: int in entries:
		if e >= 0:
			var bx: Dictionary = boxes[e]
			var mn: Vector3 = (bx["min"] as Vector3) - Vector3(c, c, c)
			var mx: Vector3 = (bx["max"] as Vector3) + Vector3(c, c, c)
			if _seg_hits_box(a, b, mn, mx):
				return true
		else:
			var pr: Dictionary = prisms[-e - 1]
			var y0 := float(pr["y0"]) - c
			var y1 := float(pr["y1"]) + c
			# Clip the segment to the prism's height band.
			var t0 := 0.0
			var t1 := 1.0
			var dy := b.y - a.y
			if absf(dy) < 1e-9:
				if a.y < y0 or a.y > y1:
					continue
			else:
				var ta := (y0 - a.y) / dy
				var tb := (y1 - a.y) / dy
				t0 = maxf(t0, minf(ta, tb))
				t1 = minf(t1, maxf(ta, tb))
				if t0 > t1:
					continue
			var pa := a.lerp(b, t0)
			var pb := a.lerp(b, t1)
			var qa := Vector2(pa.x, pa.z)
			var qb := Vector2(pb.x, pb.z)
			var poly: PackedVector2Array = pr["poly"]
			if Geometry2D.is_point_in_polygon(qa, poly) \
					or Geometry2D.is_point_in_polygon(qb, poly):
				return true
			if _seg_dist_to_poly(qa, qb, poly) < c + 1e-9:
				return true
	return false


## How far `p` is from the nearest obstacle side (capped at `cap`). Walls of
## buildings count; the runs that hug them get cheaper in the solver.
func distance_to_side(p: Vector3, cap: float, entries: PackedInt32Array) -> float:
	var best := cap
	for e: int in entries:
		if e >= 0:
			var b: Dictionary = boxes[e]
			var mn: Vector3 = b["min"]
			var mx: Vector3 = b["max"]
			if p.y < mn.y - cap or p.y > mx.y + cap:
				continue
			var dx := maxf(maxf(mn.x - p.x, 0.0), p.x - mx.x)
			var dz := maxf(maxf(mn.z - p.z, 0.0), p.z - mx.z)
			best = minf(best, sqrt(dx * dx + dz * dz))
		else:
			var pr: Dictionary = prisms[-e - 1]
			if p.y < float(pr["y0"]) - cap or p.y > float(pr["y1"]) + cap:
				continue
			best = minf(best, _dist_to_poly(Vector2(p.x, p.z), pr["poly"] as PackedVector2Array))
	return best


static func _seg_hits_box(a: Vector3, b: Vector3, mn: Vector3, mx: Vector3) -> bool:
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	for ax: int in range(3):
		var o := a[ax]
		var dv := d[ax]
		if absf(dv) < 1e-12:
			if o <= mn[ax] or o >= mx[ax]:
				return false
			continue
		var ta := (mn[ax] - o) / dv
		var tb := (mx[ax] - o) / dv
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
		if t0 >= t1:
			return false
	return true


static func _dist_to_poly(q: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	var n := poly.size()
	for i: int in range(n):
		var p := Geometry2D.get_closest_point_to_segment(q, poly[i], poly[(i + 1) % n])
		best = minf(best, q.distance_to(p))
	return best


static func _seg_dist_to_poly(a: Vector2, b: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	var n := poly.size()
	for i: int in range(n):
		var c := poly[i]
		var d := poly[(i + 1) % n]
		if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
			return 0.0
		var pts := Geometry2D.get_closest_points_between_segments(a, b, c, d)
		best = minf(best, (pts[0] as Vector2).distance_to(pts[1] as Vector2))
	return best


## Build from the running scene: every placed prop's model box, and every OSM
## building as a prism from the ground at its middle to its height.
static func from_scene(main: Node, ground_fn: Callable = Callable()) -> ConduitObstacleField:
	var f := ConduitObstacleField.new()
	if main == null:
		return f
	for node in main.find_children("*", "Node3D", true, false):
		var scr: Script = node.get_script() as Script
		if scr == null or not str(scr.resource_path).ends_with("placed_prop.gd"):
			continue
		if not (node as Node3D).is_visible_in_tree():
			continue
		var pid := ""
		if node.has_meta("prop_id"):
			pid = str(node.get_meta("prop_id"))
		elif "prop_id" in node:
			pid = str(node.get("prop_id"))
		var model := node.get_node_or_null("ModelRoot") as Node3D
		var root: Node3D = model if model != null else (node as Node3D)
		var aabb := ConduitPathfinder._mesh_aabb_world(root)
		if aabb.size.length_squared() < 0.0004:
			continue
		if aabb.size.x > MAX_PROP_SPAN_M or aabb.size.z > MAX_PROP_SPAN_M:
			continue
		f.add_box(aabb, pid)
	var loader := main.get_node_or_null("TerrainLoader")
	if loader == null:
		for c in main.get_children():
			if c.has_method("get_osm_buildings"):
				loader = c
				break
	if loader != null and loader.has_method("get_osm_buildings"):
		for bd: Variant in loader.call("get_osm_buildings") as Array:
			if not (bd is Dictionary):
				continue
			var d: Dictionary = bd
			var pts: Variant = d.get("points", PackedVector2Array())
			if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
				continue
			var poly: PackedVector2Array = pts
			var mid := Vector2.ZERO
			for p: Vector2 in poly:
				mid += p
			mid /= float(poly.size())
			var gy := 0.0
			if ground_fn.is_valid():
				gy = float(ground_fn.call(Vector3(mid.x, 0.0, mid.y)))
			var h := maxf(float(d.get("height_m", 6.0)), 2.5)
			f.add_prism(poly, gy - 1.0, gy + h)
	f.build_index()
	return f
