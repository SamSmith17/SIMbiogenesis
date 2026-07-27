class_name ConduitAStar
extends RefCounted

## Axis-aligned sparse 3D A* over a *local* clearance grid between two
## endpoints (not the full SoI). Full-SoI grids (128²×Y) + per-cell terrain
## sampling were freezing / TDR-crashing GPUs when 3D wires enabled.

const CELL_M := 2.5
const MAX_CELLS_AXIS := 48
const LOCAL_PAD_M := 14.0
const MAX_LOCAL_HALF_M := 60.0
const MIN_LOCAL_HALF_M := 12.0
const DEFAULT_CLEARANCE_M := 0.35
const Y_LAYER_STEPS := [0.0, 1.5, 3.0]
const VERT_COST_MULT := 1.35
const OBSTACLE_INFLATE_M := 0.45


var _astar: AStar3D = AStar3D.new()
var _built: bool = false
var _fingerprint: String = ""
var _center: Vector3 = Vector3.ZERO
var _half_extent: float = 0.0
var _cell: float = CELL_M
var _nx: int = 0
var _nz: int = 0
var _ny: int = 0
var _clearance_m: float = DEFAULT_CLEARANCE_M
var _y_base: float = 0.0  ## flat run band — no per-cell terrain fetches


func is_built() -> bool:
	return _built


func fingerprint() -> String:
	return _fingerprint


func invalidate() -> void:
	_built = false
	_fingerprint = ""
	_astar.clear()


func needs_rebuild(fp: String) -> bool:
	return not _built or _fingerprint != fp or _astar.get_point_count() == 0


## Route A→B on a local corridor grid. Cheap enough to call per connection.
static func route_local(a: Vector3, b: Vector3, obstacles: Array = [],
		elbow_radius_frac: float = 0.5,
		clearance_m: float = DEFAULT_CLEARANCE_M) -> PackedVector3Array:
	var router := ConduitAStar.new()
	var center := Vector3((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5)
	var half := maxf(maxf(absf(a.x - b.x), absf(a.z - b.z)) * 0.5 + LOCAL_PAD_M,
		MIN_LOCAL_HALF_M)
	half = minf(half, MAX_LOCAL_HALF_M)
	var y_base := (a.y + b.y) * 0.5
	var fp := "local|%s|%s|%s" % [
		_v3k(center), snappedf(half, 0.5),
		obstacle_fingerprint(obstacles, center, half)]
	router.rebuild_flat(center, half, obstacles, y_base, fp, clearance_m, CELL_M)
	return router.find_path_soft(a, b, elbow_radius_frac)


## Flat-Y rebuild (no per-cell ground queries — those caused multi-second stalls).
func rebuild_flat(soi_center: Vector3, half_extent_m: float, obstacles: Array,
		y_base: float, fingerprint: String = "",
		clearance_m: float = DEFAULT_CLEARANCE_M,
		cell_m: float = CELL_M) -> void:
	_astar.clear()
	_built = false
	_center = soi_center
	_y_base = y_base
	_clearance_m = maxf(clearance_m, 0.05)
	_cell = maxf(cell_m, 1.0)
	_half_extent = maxf(half_extent_m, _cell)
	var max_half := float(MAX_CELLS_AXIS) * _cell * 0.5
	if _half_extent > max_half:
		_half_extent = max_half
	_nx = clampi(int(ceili(_half_extent * 2.0 / _cell)), 2, MAX_CELLS_AXIS)
	_nz = _nx
	_ny = Y_LAYER_STEPS.size()
	var blocked_xz := _blocked_xz_cells(obstacles)
	for iy: int in _ny:
		for iz: int in _nz:
			for ix: int in _nx:
				if blocked_xz.has(Vector2i(ix, iz)):
					continue
				var pos := _cell_world_flat(ix, iy, iz)
				var id := _pack_id(ix, iy, iz)
				_astar.add_point(id, pos)
				if iy > 0:
					_astar.set_point_weight_scale(id, VERT_COST_MULT)
	for iy: int in _ny:
		for iz: int in _nz:
			for ix: int in _nx:
				var id := _pack_id(ix, iy, iz)
				if not _astar.has_point(id):
					continue
				_try_connect(id, ix + 1, iy, iz)
				_try_connect(id, ix, iy, iz + 1)
				_try_connect(id, ix, iy + 1, iz)
	_built = _astar.get_point_count() > 0
	_fingerprint = fingerprint


## Legacy API used by selftests — flat Y from center, optional ground ignored for perf.
func rebuild(soi_center: Vector3, half_extent_m: float, obstacles: Array,
		ground_y_fn: Callable, fingerprint: String = "",
		clearance_m: float = DEFAULT_CLEARANCE_M,
		cell_m: float = CELL_M) -> void:
	var y_base := soi_center.y
	if ground_y_fn.is_valid():
		# One sample only (not per-cell).
		y_base = float(ground_y_fn.call(soi_center))
	rebuild_flat(soi_center, half_extent_m, obstacles, y_base, fingerprint,
		clearance_m, cell_m)


## Find axis path A→B. Returns empty on failure. Does not soften elbows.
func find_path(a: Vector3, b: Vector3) -> PackedVector3Array:
	if not _built or _astar.get_point_count() < 2:
		return PackedVector3Array()
	if not _point_in_grid_xz(a) or not _point_in_grid_xz(b):
		return PackedVector3Array()
	var id_a := _astar.get_closest_point(a)
	var id_b := _astar.get_closest_point(b)
	if id_a < 0 or id_b < 0:
		return PackedVector3Array()
	var ids: PackedInt64Array = _astar.get_id_path(id_a, id_b)
	if ids.is_empty():
		return PackedVector3Array()
	var grid := PackedVector3Array()
	for i: int in ids.size():
		grid.append(_astar.get_point_position(ids[i]))
	var out := _axis_bridge(a, grid[0])
	for i: int in range(1, grid.size()):
		var bridge := _axis_bridge(out[out.size() - 1], grid[i])
		for j: int in range(1, bridge.size()):
			out.append(bridge[j])
	var to_b := _axis_bridge(out[out.size() - 1], b)
	for j2: int in range(1, to_b.size()):
		out.append(to_b[j2])
	return _collapse_colinear(out)


static func _axis_bridge(from: Vector3, to: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(from)
	if from.distance_to(to) < 0.02:
		return out
	if absf(to.x - from.x) > 0.02:
		out.append(Vector3(to.x, from.y, from.z))
	if absf(to.z - from.z) > 0.02:
		out.append(Vector3(to.x, from.y, to.z))
	if out[out.size() - 1].distance_to(to) > 0.02:
		out.append(to)
	return out


## Path + elbow soften (pipes / ortho post-process).
func find_path_soft(a: Vector3, b: Vector3,
		elbow_radius_frac: float = 0.5) -> PackedVector3Array:
	var path := find_path(a, b)
	if path.size() < 2:
		return path
	if elbow_radius_frac <= 0.001:
		return path
	return ConduitOrthoRouter.soften_elbows(path, ConduitOrthoRouter.ELBOW_SAMPLES,
		elbow_radius_frac)


static func obstacle_fingerprint(obstacles: Array, center: Vector3,
		half_extent: float) -> String:
	var h := 0
	var n := mini(obstacles.size(), 64)
	for i: int in n:
		var obs: Variant = obstacles[i]
		if obs is AABB:
			var b: AABB = obs as AABB
			h = hash([h, snappedf(b.position.x, 0.5), snappedf(b.position.z, 0.5),
				snappedf(b.size.x, 0.5), snappedf(b.size.z, 0.5)])
	return "%s|%.1f|%d|%d" % [_v3k(center), half_extent, obstacles.size(), h]


static func _v3k(v: Vector3) -> String:
	return "%.1f,%.1f,%.1f" % [v.x, v.y, v.z]


func _try_connect(id: int, ix: int, iy: int, iz: int) -> void:
	if ix < 0 or iy < 0 or iz < 0 or ix >= _nx or iy >= _ny or iz >= _nz:
		return
	var oid := _pack_id(ix, iy, iz)
	if not _astar.has_point(oid):
		return
	if _astar.are_points_connected(id, oid):
		return
	_astar.connect_points(id, oid, true)


func _pack_id(ix: int, iy: int, iz: int) -> int:
	return ix + iz * _nx + iy * _nx * _nz


func _cell_world_flat(ix: int, iy: int, iz: int) -> Vector3:
	var x := _center.x - _half_extent + (float(ix) + 0.5) * _cell
	var z := _center.z - _half_extent + (float(iz) + 0.5) * _cell
	var y := _y_base + _clearance_m + float(Y_LAYER_STEPS[iy])
	return Vector3(x, y, z)


func _point_in_grid_xz(p: Vector3) -> bool:
	return absf(p.x - _center.x) <= _half_extent + _cell \
			and absf(p.z - _center.z) <= _half_extent + _cell


func _blocked_xz_cells(obstacles: Array) -> Dictionary:
	var blocked: Dictionary = {}
	if obstacles.is_empty():
		return blocked
	var origin_x := _center.x - _half_extent
	var origin_z := _center.z - _half_extent
	for obs: Variant in obstacles:
		if not (obs is AABB):
			continue
		var box: AABB = (obs as AABB).grow(OBSTACLE_INFLATE_M)
		# Skip obstacles far outside this local pad.
		if box.end.x < origin_x - _cell or box.position.x > origin_x + _half_extent * 2.0 + _cell \
				or box.end.z < origin_z - _cell or box.position.z > origin_z + _half_extent * 2.0 + _cell:
			continue
		var min_ix := clampi(int(floor((box.position.x - origin_x) / _cell)), 0, _nx - 1)
		var max_ix := clampi(int(floor((box.end.x - origin_x) / _cell)), 0, _nx - 1)
		var min_iz := clampi(int(floor((box.position.z - origin_z) / _cell)), 0, _nz - 1)
		var max_iz := clampi(int(floor((box.end.z - origin_z) / _cell)), 0, _nz - 1)
		for iz: int in range(min_iz, max_iz + 1):
			for ix: int in range(min_ix, max_ix + 1):
				var cx := origin_x + (float(ix) + 0.5) * _cell
				var cz := origin_z + (float(iz) + 0.5) * _cell
				if cx >= box.position.x and cx <= box.end.x \
						and cz >= box.position.z and cz <= box.end.z:
					blocked[Vector2i(ix, iz)] = true
	return blocked


static func _collapse_colinear(points: PackedVector3Array) -> PackedVector3Array:
	if points.size() < 3:
		return points
	var out := PackedVector3Array()
	out.append(points[0])
	for i: int in range(1, points.size() - 1):
		var prev: Vector3 = out[out.size() - 1]
		var cur: Vector3 = points[i]
		var nxt: Vector3 = points[i + 1]
		var d0 := (cur - prev).normalized()
		var d1 := (nxt - cur).normalized()
		if d0.dot(d1) > 0.999:
			continue
		out.append(cur)
	out.append(points[points.size() - 1])
	return out
