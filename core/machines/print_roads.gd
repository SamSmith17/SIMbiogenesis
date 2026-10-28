class_name PrintRoads
extends MultiMeshInstance3D

## The print as ROADS: one rounded bead per extruding move (straight runs of
## short moves merged), `line_mm` wide and `layer_mm` tall, its top at the
## nozzle tip's height, laid in path order at true scale. Every printer in
## the game draws its print with this — the designed gantry's builder, the
## GLB machines' runtime and the print setup studio — so a road laid in the
## world is the road the planner moved the nozzle along.
##
## `moves` = [{p0, p1, e_mm}] in work mm (X, Y on the bed, Z up); this node's
## own frame is the work frame in metres with `origin` where work (0, 0, 0)
## sits: road local = origin + (x, z, y) · 0.001. Progress is by MOVE
## (`set_progress_move(i, s)`: every road before move i whole and the current
## one grown to the nozzle) or by printed length (`set_progress_frac`).
##
## Two MultiMesh traps this file carries (both hid the print once):
## instances written while `visible_instance_count` hid them are dropped
## when the count grows, so every road stays in the draw at a zero basis;
## and the engine's own bounds are taken once, while few roads show, so
## `custom_aabb` covers the whole print.
##
## A wet band: the last `wet_mm` of printed road is tinted `wet_color` and
## dries to the base colour behind the nozzle (mud, clay; off for plastic).

const HIDDEN := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
## Roads over this count are baked without their end caps (a mesh budget).
const BAKE_MAX_ROADS := 60000

var _roads: Array = []                 # {a, dir, len, rise, layer, col}
var _road_cum := PackedFloat32Array()  # printed length before each road
var _road_len_total := 0.0
var _road_w := 0.0004
var _road_h := 0.0002
var _partial := -1
var _partial_len := 0.0
var _shown := 0
var _total := 0
var _mv_road := PackedInt32Array()
var _mv_before := PackedInt32Array()
var _mv_off := PackedFloat32Array()
var _mv_len := PackedFloat32Array()
var _base_color := Color.WHITE
var _wet_color := Color.WHITE
var _wet_m := 0.0
var _wet_from := 0                     # roads at index >= this are tinted wet
var _origin := Vector3.ZERO
var _layer_count := 0

static var _road_mesh_cache: ArrayMesh = null


func _init() -> void:
	name = "Beads"
	set_meta("skip_prop_collision", true)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


## Build the roads. `color` is the material's base; `mottle` (0..1) varies
## each road's shade (mixed flake); `origin` = work (0, 0, 0) in this node's
## frame (metres).
func lay(moves: Array, line_mm: float, layer_mm: float, color: Color, mottle: float = 0.0, origin: Vector3 = Vector3.ZERO) -> void:
	clear()
	_origin = origin
	var w := maxf(line_mm, 0.05) * 0.001
	var h := clampf(layer_mm, 0.02, maxf(line_mm, 0.05)) * 0.001
	var o := origin
	var n := moves.size()
	_mv_road = PackedInt32Array()
	_mv_road.resize(n)
	_mv_before = PackedInt32Array()
	_mv_before.resize(n)
	_mv_off = PackedFloat32Array()
	_mv_off.resize(n)
	_mv_len = PackedFloat32Array()
	_mv_len.resize(n)
	_roads = []
	var cur := -1
	var layer_zs := {}
	for i in n:
		var mv: Dictionary = moves[i]
		_mv_road[i] = -1
		_mv_before[i] = _roads.size()
		var a: Vector3 = mv["p0"]
		var b: Vector3 = mv["p1"]
		var flat := Vector2(b.x - a.x, b.y - a.y)
		if float(mv.get("e_mm", 0.0)) <= 0.0 or flat.length() < 1e-4:
			cur = -1
			continue
		var la := o + Vector3(a.x, a.z, a.y) * 0.001
		var lb := o + Vector3(b.x, b.z, b.y) * 0.001
		var dir := Vector3(lb.x - la.x, 0.0, lb.z - la.z).normalized()
		var seg_len := la.distance_to(lb)
		if cur >= 0:
			var rd: Dictionary = _roads[cur]
			var end: Vector3 = (rd["a"] as Vector3) + (rd["dir"] as Vector3) * float(rd["len"])
			if end.distance_to(la) < 1e-5 and (rd["dir"] as Vector3).dot(dir) > 0.9995 and absf(la.y - lb.y) < 1e-6:
				_mv_road[i] = cur
				_mv_off[i] = float(rd["len"])
				_mv_len[i] = seg_len
				rd["len"] = float(rd["len"]) + seg_len
				_mv_before[i] = cur
				continue
		cur = _roads.size()
		var zkey := int(round(a.z * 100.0))
		if not layer_zs.has(zkey):
			layer_zs[zkey] = layer_zs.size()
		_roads.append({"a": la, "dir": dir, "len": seg_len, "rise": (lb.y - la.y) / maxf(seg_len, 1e-9), "layer": int(layer_zs[zkey])})
		_mv_road[i] = cur
		_mv_off[i] = 0.0
		_mv_len[i] = seg_len
		_mv_before[i] = cur
	_layer_count = layer_zs.size()
	_road_w = w
	_road_h = h
	_base_color = color
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = road_mesh()
	mm.instance_count = _roads.size()
	_road_len_total = 0.0
	_road_cum = PackedFloat32Array()
	for k in _roads.size():
		var rd: Dictionary = _roads[k]
		_road_cum.append(_road_len_total)
		_road_len_total += float(rd["len"])
		mm.set_instance_transform(k, HIDDEN)
		var shade := 1.0 if int(rd["layer"]) % 2 == 0 else 0.86
		var c := Color(shade, shade, shade)
		if mottle > 0.0:
			var hsh := hash(k * 7919 + int(rd["layer"]))
			c = Color(shade * (1.0 + mottle * (float(hsh & 255) / 255.0 - 0.5)), shade * (1.0 + mottle * (float((hsh >> 8) & 255) / 255.0 - 0.5)),
				shade * (1.0 + mottle * (float((hsh >> 16) & 255) / 255.0 - 0.5)))
		rd["col"] = c
		mm.set_instance_color(k, c)
	mm.visible_instance_count = -1
	_shown = 0
	_wet_from = 0
	if not _roads.is_empty():
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for rd in _roads:
			var a: Vector3 = (rd as Dictionary)["a"]
			var b: Vector3 = a + (rd["dir"] as Vector3) * float(rd["len"]) + Vector3.UP * float(rd["rise"]) * float(rd["len"])
			lo = lo.min(a.min(b))
			hi = hi.max(a.max(b))
		var pad := Vector3.ONE * (w + h)
		mm.custom_aabb = AABB(lo - pad, hi - lo + pad * 2.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.75
	mat.metallic_specular = 0.25
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	multimesh = mm
	material_override = mat
	_total = _roads.size()
	_partial = -1


## The old point-list form: consecutive points pair into moves and
## `extruding[i]` says whether the move INTO point i prints.
func lay_points(points: PackedVector3Array, extruding: PackedInt32Array, line_mm: float, color: Color, layer_mm: float = -1.0, origin: Vector3 = Vector3.ZERO) -> void:
	var moves := moves_from_points(points, extruding)
	lay(moves, line_mm, layer_mm if layer_mm > 0.0 else layer_guess_mm(moves, line_mm), color, 0.0, origin)


static func moves_from_points(points: PackedVector3Array, extruding: PackedInt32Array) -> Array:
	var moves: Array = []
	var has_ext := extruding.size() == points.size()
	for i in range(1, points.size()):
		moves.append({"p0": points[i - 1], "p1": points[i], "e_mm": 1.0 if (not has_ext or extruding[i] != 0) else 0.0})
	return moves


## The layer height a program prints at: the most common step between the
## heights its extruding moves sit at (half the line when it cannot tell).
static func layer_guess_mm(moves: Array, line_mm: float) -> float:
	var zs := {}
	for mv in moves:
		var m: Dictionary = mv
		if float(m.get("e_mm", 0.0)) > 0.0:
			zs[snappedf(float((m["p1"] as Vector3).z), 0.001)] = true
	var ks: Array = zs.keys()
	ks.sort()
	var counts := {}
	for i in range(1, ks.size()):
		var dz := snappedf(float(ks[i]) - float(ks[i - 1]), 0.01)
		if dz > 0.0:
			counts[dz] = int(counts.get(dz, 0)) + 1
	var best := -1.0
	var bn := 0
	for k in counts:
		if int(counts[k]) > bn:
			bn = int(counts[k])
			best = float(k)
	if best <= 0.0:
		if ks.size() == 1 and float(ks[0]) > 0.0:
			return minf(float(ks[0]), line_mm)
		return line_mm * 0.5
	return minf(best, line_mm)


## A wet band behind the nozzle: roads inside the last `wet_mm` of printed
## road are tinted `wet`; 0 turns it off.
func set_wet(wet: Color, wet_mm: float) -> void:
	_wet_color = wet
	_wet_m = maxf(wet_mm, 0.0) * 0.001
	_retint()


func _road_xf(rd: Dictionary, length: float) -> Transform3D:
	var dir: Vector3 = rd["dir"]
	var side := dir.cross(Vector3.UP)
	var a: Vector3 = rd["a"]
	var x := (dir + Vector3.UP * float(rd["rise"])) * (length + _road_w)
	var origin := a - dir * (_road_w * 0.5) + Vector3.DOWN * (_road_h * 0.5)
	return Transform3D(Basis(x, Vector3.UP * _road_h, side * _road_w), origin)


## The bead's cross-section: flat on the layer below and above, rounded at
## the sides (an extruded road, not a box), capped at both ends.
static func road_mesh() -> ArrayMesh:
	if _road_mesh_cache != null:
		return _road_mesh_cache
	var prof: Array = []
	var steps := 6
	for i in steps + 1:
		var t := -PI * 0.5 + PI * float(i) / float(steps)
		prof.append(Vector2(0.5 - 0.22 + 0.22 * cos(t), 0.5 * sin(t)))
	for i in steps + 1:
		var t := PI * 0.5 + PI * float(i) / float(steps)
		prof.append(Vector2(-0.5 + 0.22 + 0.22 * cos(t), 0.5 * sin(t)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var np := prof.size()
	for i in np:
		var p0: Vector2 = prof[i]
		var p1: Vector2 = prof[(i + 1) % np]
		var e := p1 - p0
		var nrm := Vector3(0.0, -e.x, e.y).normalized()
		var v00 := Vector3(0.0, p0.y, p0.x)
		var v01 := Vector3(1.0, p0.y, p0.x)
		var v10 := Vector3(0.0, p1.y, p1.x)
		var v11 := Vector3(1.0, p1.y, p1.x)
		for v in [v00, v10, v11, v00, v11, v01]:
			st.set_normal(nrm)
			st.add_vertex(v)
	for xe in [0.0, 1.0]:
		var nrm2 := Vector3(-1.0 if xe == 0.0 else 1.0, 0, 0)
		for i in range(1, np - 1):
			var a: Vector2 = prof[0]
			var b: Vector2 = prof[i]
			var c: Vector2 = prof[i + 1]
			var tri := [Vector3(xe, a.y, a.x), Vector3(xe, b.y, b.x), Vector3(xe, c.y, c.x)]
			if xe == 0.0:
				tri = [tri[0], tri[2], tri[1]]
			for v in tri:
				st.set_normal(nrm2)
				st.add_vertex(v)
	_road_mesh_cache = st.commit()
	return _road_mesh_cache


## Show the print up to move `i`, `s` (0..1) of the way along it.
func set_progress_move(i: int, s: float) -> void:
	if multimesh == null:
		return
	_restore_partial()
	if i < 0:
		_set_shown(0)
	elif i >= _mv_road.size():
		_set_shown(_total)
	else:
		var k := _mv_road[i]
		if k < 0:
			_set_shown(clampi(_mv_before[i], 0, _total))
		else:
			var length := float(_mv_off[i]) + float(_mv_len[i]) * clampf(s, 0.0, 1.0)
			_grow(k, length)
	_retint()


## Show the print up to `frac` of its printed length.
func set_progress_frac(frac: float) -> void:
	if multimesh == null:
		return
	_restore_partial()
	var target := clampf(frac, 0.0, 1.0) * _road_len_total
	if frac >= 1.0 - 1e-6:
		_set_shown(_total)
	elif _total == 0 or target <= 0.0:
		_set_shown(0)
	else:
		var lo := 0
		var hi := _total - 1
		while lo < hi:
			var mid := (lo + hi + 1) >> 1
			if float(_road_cum[mid]) <= target:
				lo = mid
			else:
				hi = mid - 1
		_grow(lo, target - float(_road_cum[lo]))
	_retint()


func show_all() -> void:
	set_progress_frac(1.0)


func _grow(k: int, length: float) -> void:
	var rd: Dictionary = _roads[k]
	if length < float(rd["len"]) - 1e-6:
		_set_shown(k)
		multimesh.set_instance_transform(k, _road_xf(rd, maxf(length, 0.0)))
		_partial = k
		_partial_len = maxf(length, 0.0)
	else:
		_set_shown(k + 1)


func _set_shown(n: int) -> void:
	var mm := multimesh
	n = clampi(n, 0, _total)
	if n > _shown:
		for k in range(_shown, n):
			mm.set_instance_transform(k, _road_xf(_roads[k], float(_roads[k]["len"])))
	elif n < _shown:
		for k in range(n, _shown):
			mm.set_instance_transform(k, HIDDEN)
	_shown = n


func _restore_partial() -> void:
	if _partial >= 0 and _partial < _roads.size() and multimesh != null:
		multimesh.set_instance_transform(_partial, _road_xf(_roads[_partial], float(_roads[_partial]["len"])) if _partial < _shown else HIDDEN)
	_partial = -1


## Wet tint on the roads inside the band behind the nozzle; the rest dry.
func _retint() -> void:
	if multimesh == null or _total == 0:
		return
	var shown := roads_shown()
	var from := shown
	if _wet_m > 0.0:
		var printed := printed_m()
		var lo := 0
		var hi := _total - 1
		while lo < hi:
			var mid := (lo + hi + 1) >> 1
			if float(_road_cum[mid]) <= printed - _wet_m:
				lo = mid
			else:
				hi = mid - 1
		from = mini(lo, shown)
	if from == _wet_from:
		return
	var a := mini(from, _wet_from)
	var b := maxi(from, _wet_from)
	for k in range(a, mini(b, _total)):
		var base: Color = _roads[k]["col"]
		multimesh.set_instance_color(k, base if k < from else base * _wet_color)
	_wet_from = from


## Metres of road printed so far.
func printed_m() -> float:
	if _total == 0:
		return 0.0
	if _partial >= 0:
		return float(_road_cum[_partial]) + _partial_len
	if _shown >= _total:
		return _road_len_total
	return float(_road_cum[_shown])


func road_len_total_m() -> float:
	return _road_len_total


func roads_shown() -> int:
	return _shown + (1 if _partial >= _shown else 0)


func road_transform(k: int) -> Transform3D:
	if k < 0 or k >= _roads.size():
		return Transform3D.IDENTITY
	return _road_xf(_roads[k], _partial_len if k == _partial else float(_roads[k]["len"]))


func road_count() -> int:
	return _total


func layer_count() -> int:
	return _layer_count


## The middle of the print in this node's frame.
func centre_local() -> Vector3:
	if _roads.is_empty():
		return _origin
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for rd in _roads:
		var a: Vector3 = (rd as Dictionary)["a"]
		lo = lo.min(a)
		hi = hi.max(a)
	return (lo + hi) * 0.5


func bounds_local() -> AABB:
	if multimesh == null:
		return AABB()
	return multimesh.custom_aabb


func clear() -> void:
	multimesh = null
	_total = 0
	_roads = []
	_partial = -1
	_shown = 0
	_wet_from = 0
	_road_cum = PackedFloat32Array()
	_road_len_total = 0.0


## Every road as one ArrayMesh in this node's frame (a finished print handed
## to the world as a placed object). Over BAKE_MAX_ROADS the roads are
## written as their flat tops and sides only.
func bake_mesh(color: Color, offset: Vector3 = Vector3.ZERO) -> ArrayMesh:
	if _roads.is_empty():
		return null
	var src := road_mesh()
	var arrays := src.surface_get_arrays(0)
	var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var sn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	# The side walls are written first (14 profile segments × 6 vertices),
	# the two end caps after them.
	var caps_too := _roads.size() <= BAKE_MAX_ROADS
	var nv := sv.size() if caps_too else mini(sv.size(), 14 * 6)
	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	out_v.resize(_roads.size() * nv)
	out_n.resize(_roads.size() * nv)
	var k := 0
	for rd in _roads:
		var xf := _road_xf(rd as Dictionary, float((rd as Dictionary)["len"]))
		var nb := xf.basis.inverse().transposed()
		for i in nv:
			out_v[k] = xf * sv[i] - offset
			out_n[k] = (nb * sn[i]).normalized()
			k += 1
	var mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = out_v
	arr[Mesh.ARRAY_NORMAL] = out_n
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh
