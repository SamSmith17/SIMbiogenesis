class_name ConduitRunSolver
extends RefCounted

## One router for every rigid or routed run (pipe, conduit, cable, tube):
##
## 1. A run LEAVES each port along its normal for the port fitting's stub plus
##    the run's bend radius, and further if the stub would still be inside its
##    own machine. The host stays an obstacle; only the stub is carved out.
## 2. Between the stub ends it searches a sparse orthogonal visibility (Hanan)
##    grid: lines through the stub ends, the vias and every nearby obstacle
##    face (grown by the pipe's half-OD plus clearance), and height levels at
##    the ports, the vias, the preferred run height, the ground and the tops of
##    low obstacles, so a run steps OVER a crate and goes ROUND a building.
## 3. A* on that grid costs length, a penalty per bend (scaled by the bend
##    radius), climbing, distance from the run height, and a discount along
##    walls, so runs come out short, square, few-bended and wall-hugging.
## 4. Vias are visited in order, each keeping its height.
##
## Deterministic: coordinates are sorted, obstacle entries are sorted, the heap
## breaks ties on insertion order. Bounded: per leg at most MAX_AXIS x MAX_AXIS
## x MAX_Y nodes and MAX_EXPAND expansions; past either it falls back to a
## plain L route and says so (flags.budget). Pure static over a
## ConduitObstacleField.

const MAX_AXIS := 96
const MAX_Y := 10
const MAX_EXPAND := 12000
## Local index cell inside one search (m): an edge only tests the obstacles
## in the cells it crosses.
const LOCAL_BIN := 2.0
## Grid lines closer than this merge (obstacle faces a few cm apart).
const MERGE_M := 0.08
## Weighted A*: a little greed finds long runs far sooner, at most a few
## percent longer than the best (Pohl 1970).
const H_WEIGHT := 1.25
const REGION_PAD_M := 10.0
## Clearance beyond the pipe's half OD.
const CLEAR_M := 0.06
## Stubs are pushed out of their own machine this far at most.
const MAX_STUB_M := 2.0
## How high a run will climb to step over an obstacle instead of going round.
const MAX_CLIMB_M := 3.0
const VERT_MULT := 1.35
## A leg under the ground is a trench: allowed (a level run through a slope),
## but it costs this much more per metre than one in the open.
const BURY_MULT := 2.5
## Distance-from-run-height cost per metre of horizontal run, per metre off.
const HEIGHT_PREF := 0.12
## Along-a-wall discount (runs within WALL_NEAR_M of an obstacle side).
const WALL_FACTOR := 0.75
const WALL_FACTOR_HUG := 0.55
const WALL_NEAR_M := 0.35
## Port normals within this many degrees of an axis snap to it.
const AXIS_SNAP_DEG := 15.0

const _DIRS := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


## req: {a, b: Vector3 port seats; na, nb: Vector3 outward normals (ZERO = no
## stub); stub_a, stub_b: fitting stub lengths (m); host_a, host_b: prop ids;
## vias: Array[Vector3]; od: float; bend_r: float; field:
## ConduitObstacleField (or null); run_height: float (NAN = none);
## wall_hug: bool; ground_fn: Callable(Vector3) -> float (optional);
## allow_45: bool}
## -> {corners: PackedVector3Array (sharp, port to port), stub_a, stub_b:
## Vector3, flags: {stub_extended, stub_blocked, budget, no_path, tight},
## cost: float}
static var _memo: Dictionary = {}
static var _memo_order: Array = []
const MEMO_MAX := 256
static var memo_hits: int = 0
static var memo_misses: int = 0


## solve() with the last MEMO_MAX answers kept: a run rebuilt for a reason
## that does not move it (a glow change, a follow tick) never searches again.
static func solve(req: Dictionary) -> Dictionary:
	var field: ConduitObstacleField = req.get("field") as ConduitObstacleField
	var key := [req.get("a"), req.get("b"), req.get("na"), req.get("nb"),
		req.get("stub_a"), req.get("stub_b"), req.get("host_a"), req.get("host_b"),
		req.get("vias", []), req.get("od"), req.get("bend_r"), req.get("run_height"),
		req.get("wall_hug"), req.get("allow_45"),
		field.get_instance_id() if field != null else 0,
		field.revision if field != null else 0,
		(req.get("ground_fn", Callable()) as Callable).is_valid()].hash()
	if _memo.has(key):
		memo_hits += 1
		return (_memo[key] as Dictionary).duplicate(true)
	memo_misses += 1
	var res := _solve_now(req)
	_memo[key] = res.duplicate(true)
	_memo_order.append(key)
	if _memo_order.size() > MEMO_MAX:
		_memo.erase(_memo_order.pop_front())
	return res


static func clear_memo() -> void:
	_memo.clear()
	_memo_order.clear()


static func _solve_now(req: Dictionary) -> Dictionary:
	var a: Vector3 = req.get("a", Vector3.ZERO)
	var b: Vector3 = req.get("b", Vector3.ZERO)
	var od := maxf(float(req.get("od", 0.03)), 0.002)
	var bend_r := maxf(float(req.get("bend_r", od)), od * 0.5)
	var c := od * 0.5 + CLEAR_M
	var field: ConduitObstacleField = req.get("field") as ConduitObstacleField
	var flags := {}
	var sa := _stub_end(a, req.get("na", Vector3.ZERO) as Vector3,
		float(req.get("stub_a", 0.15)) + maxf(bend_r, 0.22),
		str(req.get("host_a", "")), field, c, flags)
	var sb := _stub_end(b, req.get("nb", Vector3.ZERO) as Vector3,
		float(req.get("stub_b", 0.15)) + maxf(bend_r, 0.22),
		str(req.get("host_b", "")), field, c, flags)
	var stops: Array = [sa]
	for v: Variant in req.get("vias", []) as Array:
		if v is Vector3:
			stops.append(v as Vector3)
	stops.append(sb)
	# A run whose end stands inside a building (a machine in a shed) is routed
	# inside it: that building is not an obstacle to this run.
	# So is anything a stub end is jammed against (a machine set hard up
	# against its neighbour): with the end inside it no edge could leave, and
	# the search would spend its whole budget proving there is no way out.
	var skip := {}
	if field != null:
		for p: Vector3 in [a, b]:
			for e: int in field.query_xz(Vector2(p.x, p.z), Vector2(p.x, p.z)):
				if e < 0 and field.point_blocked(p, 0.0, PackedInt32Array([e])):
					skip[e] = true
		for p: Vector3 in [sa, sb]:
			for e: int in field.query_xz(Vector2(p.x - c, p.z - c), Vector2(p.x + c, p.z + c)):
				if field.point_blocked(p, c, PackedInt32Array([e])):
					skip[e] = true
					flags["end_jammed"] = true
	var ctx := {
		"skip": skip,
		"field": field, "c": c, "bend_pen": maxf(0.6, 3.0 * bend_r),
		"run_height": float(req.get("run_height", NAN)),
		"wall_factor": WALL_FACTOR_HUG if bool(req.get("wall_hug", false)) else WALL_FACTOR,
		"ground_fn": req.get("ground_fn", Callable()),
	}
	var corners := PackedVector3Array()
	_append(corners, a)
	var dir_in := _axis_dir(sa - a)
	var cost := 0.0
	for i: int in range(stops.size() - 1):
		var leg := _search(stops[i] as Vector3, stops[i + 1] as Vector3, dir_in, ctx)
		if leg.is_empty():
			flags["budget"] = true
			leg = {"path": _l_route(stops[i] as Vector3, stops[i + 1] as Vector3), "cost": 0.0}
		var path: PackedVector3Array = leg["path"]
		cost += float(leg.get("cost", 0.0))
		for p: Vector3 in path:
			_append(corners, p)
		if path.size() >= 2:
			dir_in = _axis_dir(path[path.size() - 1] - path[path.size() - 2])
	_append(corners, b)
	corners = collapse(corners)
	if bool(req.get("allow_45", false)) and field != null:
		corners = _chamfer(corners, field, c)
	return {"corners": corners, "stub_a": sa, "stub_b": sb, "flags": flags, "cost": cost}


## Out of the port along its (axis-snapped) normal, far enough to clear the
## host's own box.
static func _stub_end(p: Vector3, n: Vector3, stub: float, host: String,
		field: ConduitObstacleField, c: float, flags: Dictionary) -> Vector3:
	if n.length_squared() < 1e-8:
		return p
	var dir := snap_axis(n.normalized())
	var box := AABB()
	if field != null and not host.is_empty():
		box = field.box_of(host).grow(c)
	var length := stub
	var end := p + dir * length
	if box.size != Vector3.ZERO:
		while box.has_point(end) and length < MAX_STUB_M:
			length += 0.05
			end = p + dir * length
		if length > stub + 1e-4:
			flags["stub_extended"] = true
		if box.has_point(end):
			flags["stub_blocked"] = true
	return end


static func snap_axis(n: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var best_dot := -2.0
	for d: Vector3i in _DIRS:
		var v := Vector3(d)
		var dot := n.dot(v)
		if dot > best_dot:
			best_dot = dot
			best = v
	if best_dot >= cos(deg_to_rad(AXIS_SNAP_DEG)):
		return best
	return n


## One leg on the sparse grid. {} when there is no path inside the budget.
static func _search(from: Vector3, to: Vector3, dir_in: int, ctx: Dictionary) -> Dictionary:
	if from.distance_to(to) < 1e-4:
		return {"path": PackedVector3Array([from]), "cost": 0.0}
	var field: ConduitObstacleField = ctx["field"]
	var c := float(ctx["c"])
	var mn := Vector2(minf(from.x, to.x), minf(from.z, to.z)) - Vector2.ONE * REGION_PAD_M
	var mx := Vector2(maxf(from.x, to.x), maxf(from.z, to.z)) + Vector2.ONE * REGION_PAD_M
	var entries := PackedInt32Array()
	if field != null:
		var skip: Dictionary = ctx.get("skip", {})
		for e: int in field.query_xz(mn, mx):
			if not skip.has(e):
				entries.append(e)
	var y_lo := minf(from.y, to.y) - 2.0
	var y_hi := maxf(from.y, to.y) + MAX_CLIMB_M
	var xs: Array = [from.x, to.x, mn.x, mx.x]
	var zs: Array = [from.z, to.z, mn.y, mx.y]
	var ys: Array = [from.y, to.y]
	var rh := float(ctx["run_height"])
	if is_finite(rh):
		ys.append(rh)
	var gfn: Callable = ctx["ground_fn"]
	if gfn.is_valid():
		var g := minf(float(gfn.call(from)), float(gfn.call(to)))
		ys.append(g + c)
	if field != null:
		for e: int in entries:
			if e >= 0:
				var bx: Dictionary = field.boxes[e]
				var bmn: Vector3 = bx["min"]
				var bmx: Vector3 = bx["max"]
				xs.append(bmn.x - c)
				xs.append(bmx.x + c)
				zs.append(bmn.z - c)
				zs.append(bmx.z + c)
				var top := bmx.y + c
				if top > y_lo and top < y_hi:
					ys.append(top)
			else:
				var pr: Dictionary = field.prisms[-e - 1]
				var pmn: Vector2 = pr["min"]
				var pmx: Vector2 = pr["max"]
				xs.append(pmn.x - c)
				xs.append(pmx.x + c)
				zs.append(pmn.y - c)
				zs.append(pmx.y + c)
	var lb := _local_bins(field, entries, c + WALL_NEAR_M)
	var X := _coords(xs, mn.x, mx.x)
	var Z := _coords(zs, mn.y, mx.y)
	var Y := _coords(ys, y_lo, y_hi)
	X = _trim(X, [from.x, to.x], MAX_AXIS)
	Z = _trim(Z, [from.z, to.z], MAX_AXIS)
	Y = _trim(Y, [from.y, to.y] + ([rh] if is_finite(rh) else []), MAX_Y)
	var nx := X.size()
	var nz := Z.size()
	var ny := Y.size()
	var n := nx * nz * ny
	var s_ix := _index_of(X, from.x)
	var s_iz := _index_of(Z, from.z)
	var s_iy := _index_of(Y, from.y)
	var t_ix := _index_of(X, to.x)
	var t_iz := _index_of(Z, to.z)
	var t_iy := _index_of(Y, to.y)
	var start := (s_iy * nz + s_iz) * nx + s_ix
	var goal := (t_iy * nz + t_iz) * nx + t_ix
	var node_state := PackedByteArray()
	node_state.resize(n)
	node_state[start] = 1
	node_state[goal] = 1
	var ground := PackedFloat32Array()
	if gfn.is_valid():
		ground.resize(nx * nz)
		ground.fill(NAN)
	# Edge caches: each grid edge is tested once, not once per arriving direction.
	# edge_state: 0 unknown, 1 free, 2 blocked. edge_wall: 1 = along a wall.
	var edge_state := PackedByteArray()
	edge_state.resize(n * 3)
	var edge_wall := PackedByteArray()
	edge_wall.resize(n * 3)
	var g_score := PackedFloat64Array()
	g_score.resize(n * 7)
	g_score.fill(INF)
	var came := PackedInt32Array()
	came.resize(n * 7)
	came.fill(-1)
	var heap_f := PackedFloat64Array()
	var heap_s := PackedInt32Array()
	var heap_v := PackedInt32Array()
	var seq := 0
	var s0 := start * 7 + (dir_in if dir_in >= 0 else 6)
	g_score[s0] = 0.0
	_heap_push(heap_f, heap_s, heap_v, _h(X[s_ix], Y[s_iy], Z[s_iz], to, ctx), seq, s0)
	seq += 1
	var expanded := 0
	var wall_factor := float(ctx["wall_factor"])
	var bend_pen := float(ctx["bend_pen"])
	var best_goal := -1
	while heap_v.size() > 0:
		var st := _heap_pop(heap_f, heap_s, heap_v)
		var node := st / 7
		var d_prev := st % 7
		if node == goal:
			best_goal = st
			break
		expanded += 1
		if expanded > MAX_EXPAND:
			return {}
		var g0 := g_score[st]
		var ix := node % nx
		var iz := (node / nx) % nz
		var iy := node / (nx * nz)
		var p0 := Vector3(X[ix], Y[iy], Z[iz])
		for d: int in range(6):
			if d_prev < 6 and d == (d_prev ^ 1):
				continue  # no doubling back
			var dv: Vector3i = _DIRS[d]
			var jx := ix + dv.x
			var jy := iy + dv.y
			var jz := iz + dv.z
			if jx < 0 or jx >= nx or jy < 0 or jy >= ny or jz < 0 or jz >= nz:
				continue
			var nb := (jy * nz + jz) * nx + jx
			var p1 := Vector3(X[jx], Y[jy], Z[jz])
			if node_state[nb] == 0:
				node_state[nb] = 2 if _node_blocked(p1, jx, jz, nx, field, c,
					_local(lb, p1, p1), gfn, ground) else 1
			if node_state[nb] == 2:
				continue
			var ek := mini(node, nb) * 3 + (d >> 1)
			if edge_state[ek] == 0:
				var near := _local(lb, p0, p1) if field != null else PackedInt32Array()
				var blocked := field != null and field.segment_blocked(p0, p1, c * 0.98, near)
				edge_state[ek] = 2 if blocked else 1
				if not blocked and dv.y == 0 and field != null \
						and field.distance_to_side((p0 + p1) * 0.5, WALL_NEAR_M + c,
							_local(lb, (p0 + p1) * 0.5, (p0 + p1) * 0.5)) < WALL_NEAR_M + c - 1e-6:
					edge_wall[ek] = 1
			if edge_state[ek] == 2:
				continue
			var length := p0.distance_to(p1)
			var step := length
			if gfn.is_valid() and (_buried(ix, iz, nx, p0.y, p0, gfn, ground)
					or _buried(jx, jz, nx, p1.y, p1, gfn, ground)):
				step *= BURY_MULT
			if dv.y != 0:
				step *= VERT_MULT
			else:
				if is_finite(rh):
					step += length * HEIGHT_PREF * minf(absf(p1.y - rh), 5.0)
				if edge_wall[ek] == 1:
					step *= wall_factor
			if d_prev < 6 and d != d_prev:
				step += bend_pen
			var s1 := nb * 7 + d
			var g1 := g0 + step
			if g1 < g_score[s1] - 1e-9:
				g_score[s1] = g1
				came[s1] = st
				_heap_push(heap_f, heap_s, heap_v,
					g1 + _h(p1.x, p1.y, p1.z, to, ctx), seq, s1)
				seq += 1
	if best_goal < 0:
		return {}
	var rev: Array = []
	var cur := best_goal
	while cur >= 0:
		var nd := cur / 7
		rev.append(Vector3(X[nd % nx], Y[nd / (nx * nz)], Z[(nd / nx) % nz]))
		cur = came[cur]
	var path := PackedVector3Array()
	for i: int in range(rev.size() - 1, -1, -1):
		path.append(rev[i] as Vector3)
	# The search runs on the grid's copies of the end points; put the exact ones back.
	if path.size() > 0:
		path[0] = from
		path[path.size() - 1] = to
	return {"path": collapse(path), "cost": g_score[best_goal]}


static func _h(x: float, y: float, z: float, to: Vector3, ctx: Dictionary) -> float:
	var f := minf(float(ctx["wall_factor"]), 1.0)
	return ((absf(to.x - x) + absf(to.z - z)) * f + absf(to.y - y) * VERT_MULT) * H_WEIGHT


## The search's own small index: obstacle entries by LOCAL_BIN cell, each grown
## by `grow` so a wall's discount band falls in the cells next to it.
static func _local_bins(field: ConduitObstacleField, entries: PackedInt32Array,
		grow: float) -> Dictionary:
	var bins := {}
	if field == null:
		return bins
	for e: int in entries:
		var mn := Vector2.ZERO
		var mx := Vector2.ZERO
		if e >= 0:
			var b: Dictionary = field.boxes[e]
			mn = Vector2((b["min"] as Vector3).x, (b["min"] as Vector3).z)
			mx = Vector2((b["max"] as Vector3).x, (b["max"] as Vector3).z)
		else:
			var p: Dictionary = field.prisms[-e - 1]
			mn = p["min"]
			mx = p["max"]
		var b0 := Vector2i(int(floor((mn.x - grow) / LOCAL_BIN)), int(floor((mn.y - grow) / LOCAL_BIN)))
		var b1 := Vector2i(int(floor((mx.x + grow) / LOCAL_BIN)), int(floor((mx.y + grow) / LOCAL_BIN)))
		for bx: int in range(b0.x, b1.x + 1):
			for bz: int in range(b0.y, b1.y + 1):
				var k := Vector2i(bx, bz)
				if not bins.has(k):
					bins[k] = PackedInt32Array()
				var arr: PackedInt32Array = bins[k]
				arr.append(e)
				bins[k] = arr
	return bins


## Entries in the cells a segment's XZ box touches.
static func _local(bins: Dictionary, a: Vector3, b: Vector3) -> PackedInt32Array:
	var x0 := int(floor(minf(a.x, b.x) / LOCAL_BIN))
	var x1 := int(floor(maxf(a.x, b.x) / LOCAL_BIN))
	var z0 := int(floor(minf(a.z, b.z) / LOCAL_BIN))
	var z1 := int(floor(maxf(a.z, b.z) / LOCAL_BIN))
	if x0 == x1 and z0 == z1:
		return bins.get(Vector2i(x0, z0), PackedInt32Array()) as PackedInt32Array
	var seen := {}
	for bx: int in range(x0, x1 + 1):
		for bz: int in range(z0, z1 + 1):
			var k := Vector2i(bx, bz)
			if bins.has(k):
				for e: int in (bins[k] as PackedInt32Array):
					seen[e] = true
	return PackedInt32Array(seen.keys())


static func _node_blocked(p: Vector3, _ix: int, _iz: int, _nx: int,
		field: ConduitObstacleField, c: float, entries: PackedInt32Array,
		_gfn: Callable, _ground: PackedFloat32Array) -> bool:
	return field != null and field.point_blocked(p, c * 0.98, entries)


## Is the grid point under the ground? The ground is read once per column.
static func _buried(ix: int, iz: int, nx: int, y: float, p: Vector3, gfn: Callable,
		ground: PackedFloat32Array) -> bool:
	if not gfn.is_valid():
		return false
	var k := iz * nx + ix
	if is_nan(ground[k]):
		ground[k] = float(gfn.call(p))
	return y < ground[k] - 0.05


## Sorted coordinates inside [lo, hi], merged within 2 cm.
static func _coords(vals: Array, lo: float, hi: float) -> PackedFloat64Array:
	var arr: Array = []
	for v: Variant in vals:
		var f := float(v)
		if is_finite(f) and f >= lo - 1e-6 and f <= hi + 1e-6:
			arr.append(f)
	arr.sort()
	var out := PackedFloat64Array()
	for f: float in arr:
		if out.is_empty() or f - out[out.size() - 1] > MERGE_M:
			out.append(f)
	return out


## Over the cap, drop the coordinates farthest from the ones that must stay.
static func _trim(coords: PackedFloat64Array, keep: Array, cap: int) -> PackedFloat64Array:
	if coords.size() <= cap:
		return coords
	var scored: Array = []
	for f: float in coords:
		var d := INF
		for k: Variant in keep:
			d = minf(d, absf(f - float(k)))
		scored.append([d, f])
	scored.sort_custom(func(p: Array, q: Array) -> bool:
		return float(p[0]) < float(q[0]) or (is_equal_approx(float(p[0]), float(q[0]))
			and float(p[1]) < float(q[1])))
	var kept: Array = []
	for i: int in range(cap):
		kept.append(float(scored[i][1]))
	kept.sort()
	return PackedFloat64Array(kept)


static func _index_of(coords: PackedFloat64Array, v: float) -> int:
	var best := 0
	for i: int in range(coords.size()):
		if absf(coords[i] - v) < absf(coords[best] - v):
			best = i
	return best


## A plain route when the search gives up: up or down to the higher end, then
## X, then Z.
static func _l_route(from: Vector3, to: Vector3) -> PackedVector3Array:
	var h := maxf(from.y, to.y)
	var out := PackedVector3Array()
	for p: Vector3 in [from, Vector3(from.x, h, from.z), Vector3(to.x, h, from.z),
			Vector3(to.x, h, to.z), to]:
		_append(out, p)
	return out


## Replace a square horizontal corner with two 45s where the cut-off is clear.
static func _chamfer(pts: PackedVector3Array, field: ConduitObstacleField,
		c: float) -> PackedVector3Array:
	if pts.size() < 5:
		return pts
	var out := PackedVector3Array()
	out.append(pts[0])
	out.append(pts[1])
	for i: int in range(2, pts.size() - 2):
		var p := pts[i]
		var d0 := p - pts[i - 1]
		var d1 := pts[i + 1] - p
		if absf(d0.y) > 1e-4 or absf(d1.y) > 1e-4 \
				or absf(d0.normalized().dot(d1.normalized())) > 0.05:
			out.append(p)
			continue
		var cut := minf(minf(d0.length(), d1.length()) * 0.5, 1.2)
		var q0 := p - d0.normalized() * cut
		var q1 := p + d1.normalized() * cut
		var mn := Vector2(minf(q0.x, q1.x), minf(q0.z, q1.z))
		var mx := Vector2(maxf(q0.x, q1.x), maxf(q0.z, q1.z))
		if cut > 0.1 and not field.segment_blocked(q0, q1, c, field.query_xz(mn, mx)):
			out.append(q0)
			out.append(q1)
		else:
			out.append(p)
	out.append(pts[pts.size() - 2])
	out.append(pts[pts.size() - 1])
	return out


## Drop repeated and collinear points.
static func collapse(pts: PackedVector3Array) -> PackedVector3Array:
	var a := PackedVector3Array()
	for p: Vector3 in pts:
		if a.is_empty() or a[a.size() - 1].distance_to(p) > 1e-4:
			a.append(p)
	if a.size() < 3:
		return a
	var out := PackedVector3Array()
	out.append(a[0])
	for i: int in range(1, a.size() - 1):
		var d0 := (a[i] - out[out.size() - 1]).normalized()
		var d1 := (a[i + 1] - a[i]).normalized()
		if d0.dot(d1) < 0.9999:
			out.append(a[i])
	out.append(a[a.size() - 1])
	return out


static func _append(arr: PackedVector3Array, p: Vector3) -> void:
	if arr.is_empty() or arr[arr.size() - 1].distance_to(p) > 1e-4:
		arr.append(p)


static func _axis_dir(v: Vector3) -> int:
	if v.length_squared() < 1e-10:
		return -1
	var av := v.abs()
	if av.x >= av.y and av.x >= av.z:
		return 0 if v.x > 0.0 else 1
	if av.y >= av.z:
		return 2 if v.y > 0.0 else 3
	return 4 if v.z > 0.0 else 5


# --- binary heap keyed on (f, seq) -----------------------------------------

static func _heap_push(f: PackedFloat64Array, s: PackedInt32Array, v: PackedInt32Array,
		key: float, sq: int, val: int) -> void:
	f.append(key)
	s.append(sq)
	v.append(val)
	var i := f.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if f[p] < f[i] or (f[p] == f[i] and s[p] < s[i]):
			break
		_swap(f, s, v, i, p)
		i = p


static func _heap_pop(f: PackedFloat64Array, s: PackedInt32Array, v: PackedInt32Array) -> int:
	var top := v[0]
	var last := f.size() - 1
	_swap(f, s, v, 0, last)
	f.resize(last)
	s.resize(last)
	v.resize(last)
	var i := 0
	var n := f.size()
	while true:
		var l := i * 2 + 1
		var r := l + 1
		var m := i
		if l < n and (f[l] < f[m] or (f[l] == f[m] and s[l] < s[m])):
			m = l
		if r < n and (f[r] < f[m] or (f[r] == f[m] and s[r] < s[m])):
			m = r
		if m == i:
			break
		_swap(f, s, v, i, m)
		i = m
	return top


static func _swap(f: PackedFloat64Array, s: PackedInt32Array, v: PackedInt32Array,
		i: int, j: int) -> void:
	var tf := f[i]
	f[i] = f[j]
	f[j] = tf
	var ts := s[i]
	s[i] = s[j]
	s[j] = ts
	var tv := v[i]
	v[i] = v[j]
	v[j] = tv
