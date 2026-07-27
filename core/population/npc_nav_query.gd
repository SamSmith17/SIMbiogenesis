class_name NpcNavQuery
extends RefCounted

## A* over an NpcNavGrid, plus the space-pair path cache
## (POPULATION_PLAN.md Tier 3b).
##
## WHY HAND-ROLLED RATHER THAN AStar3D. ConduitAStar wraps AStar3D, but its
## grid is ~7k points; ours is ~71k. Feeding those to AStar3D costs ~71k
## add_point + ~280k connect_points binding calls on EVERY rebuild — and the
## grid rebuilds whenever a prop moves. A uniform grid needs no graph at all:
## neighbours are arithmetic. So the search runs directly over the grid's
## packed arrays, rebuilds cost nothing, and the only per-query state is a
## generation-stamped scratch buffer.
##
## STEP LIMITS LIVE HERE, not on the grid. NpcNavGrid flags cells by terrain
## GRADE; whether you can actually get from this cell to that one is a
## property of the MOVE, and is checked at connection time below. This is the
## split that lets people climb stairs and steps without getting stuck (see
## the NpcNavGrid header).
##
## Deterministic: neighbours are visited in a fixed order and ties break on
## the lower cell index, so identical inputs give byte-identical paths and the
## population sim's replay determinism survives.

## Deliberately lenient — the brief is "climb stairs and steps without getting
## stuck". The player's own step_height is 1.1 m.
const STEP_UP_M := 1.2
const STEP_DOWN_M := 2.5

## Heights live in a PackedFloat32Array, so a height authored as exactly 1.2
## reads back as 1.20000004768. Without slack, a step built to precisely the
## limit is refused by a rounding error — the tolerance makes "at the limit"
## mean passable, which is what a lenient climb model should do.
const STEP_EPS := 0.01

## Climb is penalised beyond its raw 3D length so people prefer the flat way
## round — but never so much that they refuse a reachable destination.
const CLIMB_COST_PER_M := 2.5

## Pathological-search guard. Typical site paths expand a few hundred nodes;
## this only trips on a genuinely unreachable target in a large open region.
const MAX_EXPANSIONS := 12000

## Space-pair route cache. Small: a site has ~10 tagged spaces.
const MAX_CACHE := 128

## Per-agent lateral offset applied to a shared cached route, so sixteen
## people do not walk one single-pixel line — and so a desire line has a
## natural width in 3e.
const LANE_JITTER_M := 0.4

var grid: NpcNavGrid = null

var _g := PackedFloat32Array()      # best cost to reach each node
var _came := PackedInt32Array()     # predecessor node index
var _stamp := PackedInt32Array()    # generation marker (avoids clearing)
var _closed := PackedByteArray()
var _gen := 0

# Binary min-heap over (priority, node).
var _heap_node := PackedInt32Array()
var _heap_pri := PackedFloat32Array()
var _heap_n := 0

var _cache: Dictionary = {}
var _cache_order: Array = []
var _cache_fp := ""
var _hits := 0
var _misses := 0
var _fails := 0


func setup(g: NpcNavGrid) -> void:
	grid = g
	var n := 0
	if g != null:
		n = g.nx * g.nz * g.layers
	_g = PackedFloat32Array()
	_g.resize(n)
	_came = PackedInt32Array()
	_came.resize(n)
	_stamp = PackedInt32Array()
	_stamp.resize(n)
	_closed = PackedByteArray()
	_closed.resize(n)
	_gen = 0
	invalidate()


## Drop every cached route (grid re-baked, or geometry moved).
func invalidate() -> void:
	_cache.clear()
	_cache_order.clear()
	_cache_fp = grid.fingerprint() if grid != null else ""


func is_ready() -> bool:
	return grid != null and grid.is_ready()


func stats() -> Dictionary:
	return {"hits": _hits, "misses": _misses, "fails": _fails, "cached": _cache.size()}


# --- public queries ----------------------------------------------------------

## World-space route from `from_xz` to `to_xz`, INCLUDING the destination.
## Empty when the grid is not ready or nothing is reachable — callers fall
## back to straight-line movement rather than freezing.
func find_path(from_xz: Vector2, to_xz: Vector2) -> PackedVector2Array:
	if not is_ready():
		return PackedVector2Array()
	var start := grid.nearest_walkable(from_xz)
	var goal := grid.nearest_walkable(to_xz)
	if start.x < 0 or goal.x < 0:
		_fails += 1
		return PackedVector2Array()
	var si := grid.idx(start.x, start.y, 0)
	var gi := grid.idx(goal.x, goal.y, 0)
	if si == gi:
		return PackedVector2Array([to_xz])
	var nodes := _search(si, gi)
	if nodes.is_empty():
		_fails += 1
		return PackedVector2Array()
	var pts := _smooth(nodes)
	# The caller asked for a specific point, not a cell centre.
	if pts.size() > 0:
		pts[pts.size() - 1] = to_xz
	return pts


## Route between two tagged spaces, cached. `lane_seed` shifts the shared
## route sideways per agent. Falls back to an uncached query when either key
## is empty (an agent mid-walk, not standing at a space).
func path_between_spaces(from_key: String, to_key: String, from_xz: Vector2,
		to_xz: Vector2, lane_seed: int = 0) -> PackedVector2Array:
	if not is_ready():
		return PackedVector2Array()
	if grid.fingerprint() != _cache_fp:
		invalidate()
	if from_key.is_empty() or to_key.is_empty():
		_misses += 1
		return find_path(from_xz, to_xz)
	var key := "%s>%s" % [from_key, to_key]
	var base: PackedVector2Array
	if _cache.has(key):
		_hits += 1
		base = _cache[key]
	else:
		_misses += 1
		base = find_path(from_xz, to_xz)
		if base.is_empty():
			return base
		_cache_store(key, base)
	return _lane_offset(base, lane_seed, to_xz)


func _cache_store(key: String, path: PackedVector2Array) -> void:
	_cache[key] = path
	_cache_order.append(key)
	while _cache_order.size() > MAX_CACHE:
		var oldest: String = _cache_order.pop_front()
		_cache.erase(oldest)


## Shift a shared route sideways by a stable per-agent amount. The endpoint is
## never shifted — everyone still arrives at the actual space.
func _lane_offset(path: PackedVector2Array, lane_seed: int, dest: Vector2) -> PackedVector2Array:
	if path.size() < 2 or lane_seed == 0:
		var exact := path.duplicate()
		if exact.size() > 0:
			exact[exact.size() - 1] = dest
		return exact
	var amt := (float(absi(lane_seed) % 200) / 200.0 - 0.5) * 2.0 * LANE_JITTER_M
	var out := PackedVector2Array()
	out.resize(path.size())
	for i in path.size():
		if i == 0 or i == path.size() - 1:
			out[i] = path[i]
			continue
		var a := path[i - 1]
		var b := path[i + 1]
		var dir := (b - a)
		if dir.length_squared() < 0.0001:
			out[i] = path[i]
			continue
		var nrm := Vector2(dir.y, -dir.x).normalized()
		var shifted := path[i] + nrm * amt
		# Only spread out where there is room to. In a doorway or a gap in a
		# wall, testing the shifted POINT alone is not enough — the segments
		# either side can still clip the jamb — so require open ground around
		# the original waypoint before moving it at all.
		out[i] = shifted if _has_clearance(path[i], LANE_JITTER_M + grid.cell_m) \
				and grid.is_walkable_world(shifted) else path[i]
	out[out.size() - 1] = dest
	# Verify the whole polyline, not just its vertices. Anything that still
	# clips reverts to the centreline; if that is not enough, take the
	# unjittered route. Lane variety is cosmetic — walking through a wall is
	# not, so it never wins.
	for i in range(1, out.size() - 1):
		if _segment_clear(out[i - 1], out[i]) and _segment_clear(out[i], out[i + 1]):
			continue
		out[i] = path[i]
	for i in range(1, out.size()):
		if not _segment_clear(out[i - 1], out[i]):
			var exact := path.duplicate()
			exact[exact.size() - 1] = dest
			return exact
	return out


## Walkable in every direction within `r` — i.e. open ground, not a pinch point.
func _has_clearance(p: Vector2, r: float) -> bool:
	for k in 8:
		var d := Vector2(float(_NDX[k]), float(_NDZ[k])).normalized() * r
		if not grid.is_walkable_world(p + d):
			return false
	return true


## Every sample along a world-space segment is walkable.
func _segment_clear(a: Vector2, b: Vector2) -> bool:
	var steps := maxi(int(ceil(a.distance_to(b) / (grid.cell_m * 0.5))), 1)
	for s in range(steps + 1):
		if not grid.is_walkable_world(a.lerp(b, float(s) / float(steps))):
			return false
	return true


static func path_length(path: PackedVector2Array, from_xz: Vector2) -> float:
	if path.is_empty():
		return 0.0
	var total := from_xz.distance_to(path[0])
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


# --- A* ----------------------------------------------------------------------

## Returns the node-index chain start..goal, or empty.
func _search(start_i: int, goal_i: int) -> PackedInt32Array:
	_gen += 1
	_heap_n = 0
	_heap_node.resize(0)
	_heap_pri.resize(0)
	_g[start_i] = 0.0
	_came[start_i] = -1
	_stamp[start_i] = _gen
	_closed[start_i] = 0
	_heap_push(start_i, _heuristic(start_i, goal_i))
	var expansions := 0

	while _heap_n > 0:
		var cur := _heap_pop()
		if _closed[cur] == 1 and _stamp[cur] == _gen:
			continue
		_closed[cur] = 1
		if cur == goal_i:
			return _reconstruct(cur)
		expansions += 1
		if expansions > MAX_EXPANSIONS:
			break
		_expand(cur, goal_i)
	return PackedInt32Array()


func _expand(cur: int, goal_i: int) -> void:
	var nx := grid.nx
	var nz := grid.nz
	var per_layer := nx * nz
	var layer := cur / per_layer
	var rem := cur % per_layer
	var iz := rem / nx
	var ix := rem % nx
	var h_cur := grid.height_at(ix, iz, layer)
	var cell := grid.cell_m

	# Fixed neighbour order — determinism depends on it.
	for k in 8:
		var dx := _NDX[k]
		var dz := _NDZ[k]
		var jx := ix + dx
		var jz := iz + dz
		if jx < 0 or jz < 0 or jx >= nx or jz >= nz:
			continue
		var diagonal := dx != 0 and dz != 0
		if diagonal:
			# No cutting the corner of a wall junction.
			if not grid.is_walkable(ix + dx, iz, layer) or not grid.is_walkable(ix, iz + dz, layer):
				continue
		var flat := cell * (1.41421356 if diagonal else 1.0)
		# Consider every layer at the target cell — this is what makes stairs
		# and decks connect once 3c populates upper surfaces.
		for l2 in grid.layers:
			if not grid.is_walkable(jx, jz, l2):
				continue
			var h_next := grid.height_at(jx, jz, l2)
			var dh := h_next - h_cur
			if dh > STEP_UP_M + STEP_EPS or dh < -(STEP_DOWN_M + STEP_EPS):
				continue
			var step_cost := sqrt(flat * flat + dh * dh)
			if dh > 0.0:
				step_cost += dh * CLIMB_COST_PER_M
			var ni: int = (l2 * nz + jz) * nx + jx
			var tentative: float = _g[cur] + step_cost
			var seen := _stamp[ni] == _gen
			if seen and _closed[ni] == 1:
				continue
			if seen and tentative >= _g[ni]:
				continue
			_g[ni] = tentative
			_came[ni] = cur
			_stamp[ni] = _gen
			_closed[ni] = 0
			_heap_push(ni, tentative + _heuristic(ni, goal_i))


const _NDX: Array[int] = [1, -1, 0, 0, 1, 1, -1, -1]
const _NDZ: Array[int] = [0, 0, 1, -1, 1, -1, 1, -1]


## Octile distance — admissible for 8-connected movement, so paths are optimal.
func _heuristic(a: int, b: int) -> float:
	var per_layer := grid.nx * grid.nz
	var ra := a % per_layer
	var rb := b % per_layer
	var dx := absi((ra % grid.nx) - (rb % grid.nx))
	var dz := absi((ra / grid.nx) - (rb / grid.nx))
	var lo := mini(dx, dz)
	var hi := maxi(dx, dz)
	return grid.cell_m * (1.41421356 * float(lo) + float(hi - lo))


func _reconstruct(goal_i: int) -> PackedInt32Array:
	var rev := PackedInt32Array()
	var n := goal_i
	var guard := 0
	while n != -1 and guard < 1 << 20:
		rev.append(n)
		n = _came[n]
		guard += 1
	rev.reverse()
	return rev


# --- smoothing ---------------------------------------------------------------

## Raw grid paths staircase along cell edges. String-pulling collapses them to
## the corners that matter.
##
## Crucially it is COST-AWARE, not just visibility-aware. A shortcut that is
## walkable can still be worse than the route A* chose: on a hill, the straight
## line is shorter but climbs the summit, and naive string-pulling would
## straighten the deliberate detour back over the top — silently undoing the
## climb avoidance the search just paid for. So a shortcut is only taken when
## it is no more expensive than the run of edges it replaces.
func _smooth(nodes: PackedInt32Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	if nodes.is_empty():
		return out
	var anchor := 0
	out.append(_node_xz(nodes[0]))
	var run_cost := 0.0
	var i := 1
	while i < nodes.size():
		var leg := _edge_cost(nodes[i - 1], nodes[i])
		run_cost += leg
		if _line_cost(nodes[anchor], nodes[i]) > run_cost + 0.01:
			# Straightening here would cost more than the path already does:
			# the previous node is a real corner, keep it.
			anchor = i - 1
			out.append(_node_xz(nodes[anchor]))
			run_cost = leg
		i += 1
	out.append(_node_xz(nodes[nodes.size() - 1]))
	return out


## Cost of one grid move, matching what _expand charges.
func _edge_cost(a: int, b: int) -> float:
	var pa := _node_xz(a)
	var pb := _node_xz(b)
	var dh := _node_height(b) - _node_height(a)
	var flat := pa.distance_to(pb)
	var c := sqrt(flat * flat + dh * dh)
	return c + (dh * CLIMB_COST_PER_M if dh > 0.0 else 0.0)


func _node_height(node: int) -> float:
	var per_layer := grid.nx * grid.nz
	var layer := node / per_layer
	var rem := node % per_layer
	return grid.height_at(rem % grid.nx, rem / grid.nx, layer)


func _node_xz(node: int) -> Vector2:
	var per_layer := grid.nx * grid.nz
	var rem := node % per_layer
	return grid.center_of(rem % grid.nx, rem / grid.nx)


## Cost of the straight line between two nodes, or INF when it is not
## traversable. Uses the same step limits and climb penalty as the search, so
## smoothing and searching agree on what a route costs.
func _line_cost(a: int, b: int) -> float:
	if not _line_clear(a, b):
		return INF
	var pa := _node_xz(a)
	var pb := _node_xz(b)
	var flat := pa.distance_to(pb)
	# Charge the climb actually incurred along the line, not just end-to-end,
	# so a shortcut over a bump is priced honestly.
	var per_layer := grid.nx * grid.nz
	var la := a / per_layer
	var ra := a % per_layer
	var rb := b % per_layer
	var ax := ra % grid.nx
	var az := ra / grid.nx
	var bx := rb % grid.nx
	var bz := rb / grid.nx
	var steps := maxi(maxi(absi(bx - ax), absi(bz - az)), 1)
	var climb := 0.0
	var prev_h := grid.height_at(ax, az, la)
	for s in range(1, steps + 1):
		var t := float(s) / float(steps)
		var cx := int(round(lerpf(float(ax), float(bx), t)))
		var cz := int(round(lerpf(float(az), float(bz), t)))
		var h := grid.height_at(cx, cz, la)
		if h > prev_h:
			climb += h - prev_h
		prev_h = h
	var total_dh := grid.height_at(bx, bz, la) - grid.height_at(ax, az, la)
	return sqrt(flat * flat + total_dh * total_dh) + climb * CLIMB_COST_PER_M


## Walkable straight line between two nodes, respecting the same step limits
## the search used — otherwise smoothing would cheerfully cut across a drop.
func _line_clear(a: int, b: int) -> bool:
	var per_layer := grid.nx * grid.nz
	var la := a / per_layer
	var lb := b / per_layer
	if la != lb:
		return false     # never smooth across a layer change
	var ra := a % per_layer
	var rb := b % per_layer
	var ax := ra % grid.nx
	var az := ra / grid.nx
	var bx := rb % grid.nx
	var bz := rb / grid.nx
	var steps := maxi(absi(bx - ax), absi(bz - az))
	if steps == 0:
		return true
	var prev_h := grid.height_at(ax, az, la)
	for s in range(1, steps + 1):
		var t := float(s) / float(steps)
		var cx := int(round(lerpf(float(ax), float(bx), t)))
		var cz := int(round(lerpf(float(az), float(bz), t)))
		if not grid.is_walkable(cx, cz, la):
			return false
		var h := grid.height_at(cx, cz, la)
		var dh := h - prev_h
		if dh > STEP_UP_M + STEP_EPS or dh < -(STEP_DOWN_M + STEP_EPS):
			return false
		prev_h = h
	return true


# --- binary min-heap ---------------------------------------------------------

func _heap_push(node: int, pri: float) -> void:
	_heap_node.append(node)
	_heap_pri.append(pri)
	var i := _heap_n
	_heap_n += 1
	while i > 0:
		var parent := (i - 1) >> 1
		if _heap_pri[parent] <= _heap_pri[i]:
			break
		_heap_swap(parent, i)
		i = parent


func _heap_pop() -> int:
	var top := _heap_node[0]
	_heap_n -= 1
	if _heap_n > 0:
		_heap_node[0] = _heap_node[_heap_n]
		_heap_pri[0] = _heap_pri[_heap_n]
	_heap_node.resize(_heap_n)
	_heap_pri.resize(_heap_n)
	var i := 0
	while true:
		var l := 2 * i + 1
		var r := l + 1
		var small := i
		if l < _heap_n and _heap_pri[l] < _heap_pri[small]:
			small = l
		if r < _heap_n and _heap_pri[r] < _heap_pri[small]:
			small = r
		if small == i:
			break
		_heap_swap(small, i)
		i = small
	return top


func _heap_swap(a: int, b: int) -> void:
	var tn := _heap_node[a]
	_heap_node[a] = _heap_node[b]
	_heap_node[b] = tn
	var tp := _heap_pri[a]
	_heap_pri[a] = _heap_pri[b]
	_heap_pri[b] = tp
