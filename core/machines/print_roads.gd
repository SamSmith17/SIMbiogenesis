class_name PrintRoads
extends MultiMeshInstance3D

## The print as ROADS: one rounded bead per extruding move (straight runs of
## short moves merged), `line_mm` wide and `layer_mm` tall, its top at the
## nozzle tip's height, laid in path order at true scale. Every printer in
## the game draws its print with this — the designed gantry's builder, the
## GLB machines' runtime and the print setup studio — so a road laid in the
## world is the road the planner moved the nozzle along.
##
## `moves` = PrintMoves (or an Array of {p0, p1, e_mm}) in work mm (X, Y on
## the bed, Z up); this node's own frame is the work frame in metres with
## `origin` where work (0, 0, 0) sits: road local = origin + (x, z, y) · 0.001.
## That map is a REFLECTION (work is right-handed with Z up, (x, z, y) is
## left-handed in Godot), so a caller that wants the print the right way
## round puts a mirrored transform on this node (`work_basis()`), as the
## print setup studio and the runtimes do. Progress is by MOVE
## (`set_progress_move(i, s)`: every road before move i whole and the current
## one grown to the nozzle) or by printed length (`set_progress_frac`).
##
## Rows are packed arrays and the GPU buffer is written in bulk: a large
## print is hundreds of thousands of roads. Past DISPLAY_MAX_ROADS the curves
## are merged into chords (a sagitta tolerance that grows with the overflow)
## so the draw stays bounded; progress still runs move by move.
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
## Roads the GPU is asked to draw (see the header).
const DISPLAY_MAX_ROADS := 250000
## Above this many instance writes in one call the CPU copy of the buffer is
## uploaded whole instead of one instance at a time.
const BULK_WRITE := 2048

# One row per road.
var _ra := PackedVector3Array()       # start, this node's frame (m)
var _rdir := PackedVector3Array()     # horizontal unit direction
var _rlen := PackedFloat32Array()     # chord length (m, horizontal)
var _rarc := PackedFloat32Array()     # printed length along its moves (m)
var _rrise := PackedFloat32Array()    # rise per metre of chord
var _rlayer := PackedInt32Array()
var _rcol := PackedColorArray()
var _road_cum := PackedFloat32Array()  # printed length before each road
var _road_len_total := 0.0
var _road_w := 0.0004
var _road_h := 0.0002
var _partial := -1
var _partial_len := 0.0               # printed (arc) length of the partial road
var _shown := 0
var _total := 0
var _mv_road := PackedInt32Array()
var _mv_before := PackedInt32Array()
var _mv_off := PackedFloat32Array()   # arc length into its road where move i starts
var _mv_len := PackedFloat32Array()   # arc length of move i
var _base_color := Color.WHITE
var _wet_color := Color.WHITE
var _wet_m := 0.0
var _wet_from := 0                     # roads at index >= this are tinted wet
var _origin := Vector3.ZERO
var _layer_count := 0
var _merged := false
var _buf := PackedFloat32Array()      # CPU copy of the MultiMesh buffer (16 floats a road)
## This instance's draw budget (DISPLAY_MAX_ROADS; tests lower it).
var display_max := DISPLAY_MAX_ROADS

static var _road_mesh_cache: ArrayMesh = null


func _init() -> void:
	name = "Beads"
	set_meta("skip_prop_collision", true)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


## The basis that turns this node's (x, z, y) map into a right-handed work
## frame: work +Y goes to −Z. Put it on the node (with the origin at the
## bed's FRONT-left corner) and a printed part is not a mirror image of its
## model.
static func work_basis() -> Basis:
	return Basis(Vector3.RIGHT, Vector3.UP, Vector3.FORWARD)


## Build the roads. `color` is the material's base; `mottle` (0..1) varies
## each road's shade (mixed flake); `origin` = work (0, 0, 0) in this node's
## frame (metres).
func lay(moves_in: Variant, line_mm: float, layer_mm: float, color: Color, mottle: float = 0.0, origin: Vector3 = Vector3.ZERO) -> void:
	clear()
	var pm := PrintMoves.from_any(moves_in)
	_origin = origin
	var w := maxf(line_mm, 0.05) * 0.001
	var h := clampf(layer_mm, 0.02, maxf(line_mm, 0.05)) * 0.001
	var o := origin
	var n := pm.size()
	_mv_road.resize(n)
	_mv_before.resize(n)
	_mv_off.resize(n)
	_mv_len.resize(n)
	var n_ext := 0
	for i in n:
		if pm.e[i] > 0.0:
			n_ext += 1
	# Exact (collinear runs) while the roads fit the budget, else chords.
	_merged = n_ext > display_max
	# Sagitta tolerance in line widths, from the overflow (measured: a 3.3 M
	# move gyroid at 0.45 mm still drew 615 k roads at 2 w; it needs ~5 w).
	var sag_tol := w * clampf(0.4 * float(n_ext) / float(maxi(display_max, 1)), 0.25, 8.0) if _merged else 0.0
	var cur := -1
	var layer_zs := {}
	var a_cur := Vector3.ZERO   # current road: start, end, printed length, direction
	var e_cur := Vector3.ZERO
	var arc_cur := 0.0
	var dir_cur := Vector3.ZERO
	var seg_dir_last := Vector3.ZERO
	for i in n:
		_mv_road[i] = -1
		_mv_before[i] = _ra.size()
		var a: Vector3 = pm.p0[i]
		var b: Vector3 = pm.p1[i]
		if pm.e[i] <= 0.0 or Vector2(b.x - a.x, b.y - a.y).length() < 1e-4:
			cur = -1
			continue
		var la := o + Vector3(a.x, a.z, a.y) * 0.001
		var lb := o + Vector3(b.x, b.z, b.y) * 0.001
		var seg_dir := Vector3(lb.x - la.x, 0.0, lb.z - la.z).normalized()
		var seg_len := la.distance_to(lb)
		var level := absf(la.y - lb.y) < 1e-6
		if cur >= 0 and level and _rrise[cur] == 0.0 and e_cur.distance_to(la) < 1e-5 and absf(la.y - a_cur.y) < 1e-6:
			var take := false
			if not _merged:
				take = dir_cur.dot(seg_dir) > 0.9995
			else:
				var chord := lb - a_cur
				var chord_len := chord.length()
				if chord_len > 1e-9 and seg_dir.dot(seg_dir_last) > 0.5:
					# The run's sagitta against its new chord, from arc − chord
					# (a smooth arc: arc − chord ≈ 8 s² / 3 L), and the last
					# vertex's own distance off it.
					var sag := sqrt(maxf(3.0 * chord_len * (arc_cur + seg_len - chord_len) / 8.0, 0.0))
					var cd := chord / chord_len
					var off := (e_cur - a_cur) - cd * (e_cur - a_cur).dot(cd)
					take = sag <= sag_tol and off.length() <= sag_tol
			if take:
				_mv_road[i] = cur
				_mv_off[i] = arc_cur
				_mv_len[i] = seg_len
				_mv_before[i] = cur
				arc_cur += seg_len
				e_cur = lb
				var ch := Vector2(lb.x - a_cur.x, lb.z - a_cur.z)
				var chl := ch.length()
				if chl > 1e-12:
					dir_cur = Vector3(ch.x, 0.0, ch.y) / chl
				_rdir[cur] = dir_cur
				_rlen[cur] = chl
				_rarc[cur] = arc_cur
				seg_dir_last = seg_dir
				continue
		cur = _ra.size()
		var zkey := int(round(a.z * 100.0))
		if not layer_zs.has(zkey):
			layer_zs[zkey] = layer_zs.size()
		var hl := Vector2(lb.x - la.x, lb.z - la.z).length()
		_ra.append(la)
		_rdir.append(seg_dir)
		_rlen.append(hl)
		_rarc.append(seg_len)
		_rrise.append(0.0 if level else (lb.y - la.y) / maxf(hl, 1e-9))
		_rlayer.append(int(layer_zs[zkey]))
		a_cur = la
		e_cur = lb
		arc_cur = seg_len
		dir_cur = seg_dir
		seg_dir_last = seg_dir
		_mv_road[i] = cur
		_mv_off[i] = 0.0
		_mv_len[i] = seg_len
		_mv_before[i] = cur
	_layer_count = layer_zs.size()
	_road_w = w
	_road_h = h
	_base_color = color
	var nr := _ra.size()
	_total = nr
	_road_cum.resize(nr)
	_rcol.resize(nr)
	_road_len_total = 0.0
	_buf.resize(nr * 16)
	_buf.fill(0.0)
	for k in nr:
		_road_cum[k] = _road_len_total
		_road_len_total += _rarc[k]
		var shade := 1.0 if _rlayer[k] % 2 == 0 else 0.86
		var c := Color(shade, shade, shade)
		if mottle > 0.0:
			var hsh := hash(k * 7919 + _rlayer[k])
			c = Color(shade * (1.0 + mottle * (float(hsh & 255) / 255.0 - 0.5)), shade * (1.0 + mottle * (float((hsh >> 8) & 255) / 255.0 - 0.5)),
				shade * (1.0 + mottle * (float((hsh >> 16) & 255) / 255.0 - 0.5)))
		_rcol[k] = c
		_put_col(k, c)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = road_mesh()
	mm.instance_count = nr
	if nr > 0:
		mm.buffer = _buf
	mm.visible_instance_count = -1
	_shown = 0
	_wet_from = 0
	if nr > 0:
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for k in nr:
			var a: Vector3 = _ra[k]
			var b: Vector3 = a + _rdir[k] * _rlen[k] + Vector3.UP * _rrise[k] * _rlen[k]
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
	_partial = -1


## The material's colour (the roads' shades multiply it): a recolour that
## does not re-lay a large print.
func set_base_color(c: Color) -> void:
	_base_color = c
	var mat := material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = c


## True when the curves were merged into chords to fit the draw budget.
func is_merged() -> bool:
	return _merged


## The old point-list form: consecutive points pair into moves and
## `extruding[i]` says whether the move INTO point i prints.
func lay_points(points: PackedVector3Array, extruding: PackedInt32Array, line_mm: float, color: Color, layer_mm: float = -1.0, origin: Vector3 = Vector3.ZERO) -> void:
	var moves := moves_from_points(points, extruding)
	lay(moves, line_mm, layer_mm if layer_mm > 0.0 else layer_guess_mm(moves, line_mm), color, 0.0, origin)


static func moves_from_points(points: PackedVector3Array, extruding: PackedInt32Array) -> PrintMoves:
	var moves := PrintMoves.new()
	var has_ext := extruding.size() == points.size()
	for i in range(1, points.size()):
		var on := not has_ext or extruding[i] != 0
		moves.append(points[i - 1], points[i], 30.0, 1.0 if on else 0.0, not on, i)
	return moves


## The layer height a program prints at: the most common step between the
## heights its extruding moves sit at (half the line when it cannot tell).
static func layer_guess_mm(moves_in: Variant, line_mm: float) -> float:
	var moves := PrintMoves.from_any(moves_in)
	var zs := {}
	for i in moves.size():
		if moves.e[i] > 0.0:
			zs[snappedf(float(moves.p1[i].z), 0.001)] = true
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


## Road k drawn `arc` metres of its printed length along (the chord scaled
## to match when curves were merged).
func _road_xf(k: int, arc: float) -> Transform3D:
	var dir: Vector3 = _rdir[k]
	var length := _rlen[k] * (arc / _rarc[k]) if _rarc[k] > 1e-12 else 0.0
	var side := dir.cross(Vector3.UP)
	var a: Vector3 = _ra[k]
	var x := (dir + Vector3.UP * _rrise[k]) * (length + _road_w)
	var origin := a - dir * (_road_w * 0.5) + Vector3.DOWN * (_road_h * 0.5)
	return Transform3D(Basis(x, Vector3.UP * _road_h, side * _road_w), origin)


func _put_xf(k: int, xf: Transform3D) -> void:
	var j := k * 16
	var bs := xf.basis
	_buf[j] = bs.x.x
	_buf[j + 1] = bs.y.x
	_buf[j + 2] = bs.z.x
	_buf[j + 3] = xf.origin.x
	_buf[j + 4] = bs.x.y
	_buf[j + 5] = bs.y.y
	_buf[j + 6] = bs.z.y
	_buf[j + 7] = xf.origin.y
	_buf[j + 8] = bs.x.z
	_buf[j + 9] = bs.y.z
	_buf[j + 10] = bs.z.z
	_buf[j + 11] = xf.origin.z


func _put_col(k: int, c: Color) -> void:
	var j := k * 16 + 12
	_buf[j] = c.r
	_buf[j + 1] = c.g
	_buf[j + 2] = c.b
	_buf[j + 3] = c.a


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
			_grow(k, float(_mv_off[i]) + float(_mv_len[i]) * clampf(s, 0.0, 1.0))
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
	if length < _rarc[k] - 1e-6:
		_set_shown(k)
		var xf := _road_xf(k, maxf(length, 0.0))
		multimesh.set_instance_transform(k, xf)
		_put_xf(k, xf)
		_partial = k
		_partial_len = maxf(length, 0.0)
	else:
		_set_shown(k + 1)


func _set_shown(n: int) -> void:
	var mm := multimesh
	n = clampi(n, 0, _total)
	if n == _shown:
		return
	var bulk := absi(n - _shown) > BULK_WRITE
	if n > _shown:
		for k in range(_shown, n):
			var xf := _road_xf(k, _rarc[k])
			_put_xf(k, xf)
			if not bulk:
				mm.set_instance_transform(k, xf)
	else:
		for k in range(n, _shown):
			_put_xf(k, HIDDEN)
			if not bulk:
				mm.set_instance_transform(k, HIDDEN)
	_shown = n
	if bulk:
		mm.buffer = _buf


func _restore_partial() -> void:
	if _partial >= 0 and _partial < _total and multimesh != null:
		var xf := _road_xf(_partial, _rarc[_partial]) if _partial < _shown else HIDDEN
		multimesh.set_instance_transform(_partial, xf)
		_put_xf(_partial, xf)
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
	var b := mini(maxi(from, _wet_from), _total)
	var bulk := b - a > BULK_WRITE
	for k in range(a, b):
		var base: Color = _rcol[k]
		var c := base if k < from else base * _wet_color
		_put_col(k, c)
		if not bulk:
			multimesh.set_instance_color(k, c)
	if bulk:
		multimesh.buffer = _buf
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
	if k < 0 or k >= _total:
		return Transform3D.IDENTITY
	return _road_xf(k, _partial_len if k == _partial else _rarc[k])


func road_count() -> int:
	return _total


func layer_count() -> int:
	return _layer_count


## The middle of the print in this node's frame.
func centre_local() -> Vector3:
	if _total == 0:
		return _origin
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for k in _total:
		var a: Vector3 = _ra[k]
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
	_ra = PackedVector3Array()
	_rdir = PackedVector3Array()
	_rlen = PackedFloat32Array()
	_rarc = PackedFloat32Array()
	_rrise = PackedFloat32Array()
	_rlayer = PackedInt32Array()
	_rcol = PackedColorArray()
	_buf = PackedFloat32Array()
	_mv_road = PackedInt32Array()
	_mv_before = PackedInt32Array()
	_mv_off = PackedFloat32Array()
	_mv_len = PackedFloat32Array()
	_partial = -1
	_shown = 0
	_wet_from = 0
	_road_cum = PackedFloat32Array()
	_road_len_total = 0.0
	_merged = false


## Every road as one ArrayMesh in this node's frame (a finished print handed
## to the world as a placed object). Over BAKE_MAX_ROADS the roads are
## written as their flat tops and sides only. `post` turns the result
## (PrintRoads.work_basis() takes a reflected roads frame to a proper one;
## a reflection also reverses each triangle so the faces stay outward).
func bake_mesh(color: Color, offset: Vector3 = Vector3.ZERO, post: Basis = Basis.IDENTITY) -> ArrayMesh:
	if _total == 0:
		return null
	var src := road_mesh()
	var arrays := src.surface_get_arrays(0)
	var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var sn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	# The side walls are written first (14 profile segments × 6 vertices),
	# the two end caps after them.
	var caps_too := _total <= BAKE_MAX_ROADS
	var nv := sv.size() if caps_too else mini(sv.size(), 14 * 6)
	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	out_v.resize(_total * nv)
	out_n.resize(_total * nv)
	var flip := post.determinant() < 0.0
	var k := 0
	for r in _total:
		var xf := _road_xf(r, _rarc[r])
		var nb := xf.basis.inverse().transposed()
		for i in nv:
			# A reflection swaps each triangle's last two corners.
			var src_i := i
			if flip and i % 3 != 0:
				src_i = i + (1 if i % 3 == 1 else -1)
			out_v[k] = post * (xf * sv[src_i] - offset)
			out_n[k] = (post * (nb * sn[src_i])).normalized()
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
