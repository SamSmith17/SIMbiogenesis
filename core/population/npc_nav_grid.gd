class_name NpcNavGrid
extends RefCounted

## Walkable grid for NPC pathfinding (POPULATION_PLAN.md Tier 3a).
##
## A person-scale raster over the part of the site people actually use: the
## bounding box of every tagged space plus the habitat, padded. Each cell
## stores the walkable surface height, a slope reading, and flags. Phase 3b
## runs A* over it; 3c adds building walls/doors and upper layers.
##
## THE STALL TRAP — read before changing the bake. `ConduitAStar`'s header
## records that per-cell ground fetches caused GPU TDR and multi-second
## stalls, which is why it flattened its entire grid to one Y band. We need
## real heights, so instead the bake is CHUNKED across frames via
## `bake_step(budget)` and callers must never sample terrain inside a
## population tick. Until `is_ready()`, agents keep using straight-line
## movement — the sim never blocks on the bake.
##
## SLOPE vs STEPS — the subtle bit. At 0.75 m cells, the height difference
## between two ADJACENT cells is not a terrain grade, it is a step: a 1.2 m
## step onto a deck reads as 58° across one cell, which would strand people at
## the bottom of it. So:
##   * cell slope is a CENTRAL DIFFERENCE over ±SLOPE_BASELINE_CELLS — a 3 m
##     span, roughly two strides — which measures real terrain grade and
##     smooths out local features. A single 1.2 m step reads 21.8° (walkable);
##     a genuine cliff still reads 80°+ and blocks. Props and building walls
##     are stamped explicitly, so leniency here does not let people walk
##     through solid objects.
##   * per-move step limits (STEP_UP_M / STEP_DOWN_M) are applied at
##     CONNECTION time in 3b, never as a cell flag.
## Note that widening the baseline cannot rescue a SUSTAINED steep grade: a
## ladder at 58° reads 58° at any baseline, and is correctly refused.
## Getting this backwards is exactly the "NPCs get stuck on stairs" failure.
##
## Testability: `begin_bake` takes a `height_fn: Callable(x, z) -> float` and
## plain polygons, so the whole class runs headless on synthetic terrain with
## no scene, no terrain loader and no physics.

## Person-scale. Deliberately finer than ConduitAStar.CELL_M (2.5 m): a
## doorway is ~1 m wide, and at 1.5 m cells a door either vanishes or becomes
## a 3 m hole.
const CELL_M := 0.75
const REGION_PAD_M := 30.0
const MIN_REGION_HALF_M := 20.0
const MAX_REGION_HALF_M := 300.0
const MAX_CELLS_AXIS := 900          # hard cap; 900 * 0.75 m = 675 m
const MAX_LAYERS := 3

## Bake budget per call. ~71k cells (a 200 m region) lands in ~35 frames.
const CELLS_PER_FRAME := 2000
## The layer pass scans this many cells per probe it is allowed — skipping a
## non-structure cell costs nothing, so the scan should race ahead.
const LAYER_SCAN_RATIO := 40

## A cell whose terrain grade over the baseline exceeds this is a cliff.
## NOT a step limit — see the header.
const MAX_SLOPE_DEG := 50.0
## Central difference half-width in cells: the measured span is twice this,
## i.e. 2 * 2 * 0.75 m = 3 m.
const SLOPE_BASELINE_CELLS := 2

# --- cell flags (bitmask) ---------------------------------------------------
const F_BLOCKED := 1 << 0
const F_WALL := 1 << 1        # building wall band (3c)
const F_INTERIOR := 1 << 2    # inside a building footprint (3c)
const F_DOOR := 1 << 3        # punched opening (3c)
const F_STRUCTURE := 1 << 4   # prop/building volume — where extra layers live
const F_WATER := 1 << 5
const F_STEEP := 1 << 6
## A fire's no-go perimeter (an effigy burn). Its own bit so clearing it can
## never wipe a REAL obstacle inside the circle — the perimeter used to be
## stamped as F_BLOCKED, and clearing it unblocked the structure itself and
## every prop standing within the old radius.
const F_FIRE := 1 << 7
## Anything that stops a person: the static obstacles plus a live fire.
const BLOCKING := F_BLOCKED | F_FIRE

enum Phase { IDLE, HEIGHT, SLOPE, OBSTACLES, LAYERS, DONE }

var origin := Vector2.ZERO    # world XZ of cell (0,0)'s CORNER
var cell_m := CELL_M
var nx := 0
var nz := 0
var layers := 1

var _height := PackedFloat32Array()
var _flags := PackedByteArray()
var _slope := PackedFloat32Array()   # degrees, per column (layer-independent)
var _phase: int = Phase.IDLE
var _cursor := 0
var _height_fn := Callable()
var _obstacles: Array = []
var _obstacle_i := 0
var _surfaces_fn := Callable()
var _fingerprint := ""


# --- region -----------------------------------------------------------------

## Size the grid to cover `points` (tagged spaces + the habitat home) padded by
## REGION_PAD_M. Returns false when there is nothing to cover.
func configure_for_points(points: PackedVector2Array, cell := CELL_M) -> bool:
	if points.is_empty():
		return false
	var lo := points[0]
	var hi := points[0]
	for p in points:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	var center := (lo + hi) * 0.5
	var half := maxf(maxf(hi.x - lo.x, hi.y - lo.y) * 0.5 + REGION_PAD_M, MIN_REGION_HALF_M)
	half = minf(half, MAX_REGION_HALF_M)
	return configure_region(center, half, cell)


func configure_region(center: Vector2, half_extent_m: float, cell := CELL_M) -> bool:
	cell_m = maxf(cell, 0.05)
	var n := clampi(int(ceil(half_extent_m * 2.0 / cell_m)), 2, MAX_CELLS_AXIS)
	nx = n
	nz = n
	layers = 1
	origin = center - Vector2(1.0, 1.0) * (float(n) * cell_m * 0.5)
	_height = PackedFloat32Array()
	_flags = PackedByteArray()
	_slope = PackedFloat32Array()
	_phase = Phase.IDLE
	return true


func cell_count() -> int:
	return nx * nz


# --- addressing --------------------------------------------------------------

func in_bounds(ix: int, iz: int) -> bool:
	return ix >= 0 and iz >= 0 and ix < nx and iz < nz


func idx(ix: int, iz: int, layer: int = 0) -> int:
	return (layer * nz + iz) * nx + ix


## Cell containing a world XZ point. May be out of bounds — check in_bounds.
func cell_of(world_xz: Vector2) -> Vector2i:
	return Vector2i(
		int(floor((world_xz.x - origin.x) / cell_m)),
		int(floor((world_xz.y - origin.y) / cell_m)))


## World XZ of a cell's centre.
func center_of(ix: int, iz: int) -> Vector2:
	return origin + Vector2((float(ix) + 0.5) * cell_m, (float(iz) + 0.5) * cell_m)


func contains_world(world_xz: Vector2) -> bool:
	var c := cell_of(world_xz)
	return in_bounds(c.x, c.y)


# --- bake --------------------------------------------------------------------

## `obstacles`: [{poly: PackedVector2Array, flags: int, band_m: float}].
## `band_m` > 0 stamps only a band around the polygon EDGES (walls), leaving
## the interior clear; 0 stamps the polygon solid.
## `surfaces_fn(x, z) -> PackedFloat32Array` returns any walkable surfaces
## ABOVE the ground at that point (deck levels, upper floors). Supplying it
## allocates MAX_LAYERS layers; without it the grid is single-layer.
func begin_bake(height_fn: Callable, obstacles: Array = [], fp: String = "",
		surfaces_fn: Callable = Callable()) -> void:
	if nx == 0 or nz == 0:
		return
	_surfaces_fn = surfaces_fn
	layers = MAX_LAYERS if surfaces_fn.is_valid() else 1
	var n := nx * nz * layers
	_height = PackedFloat32Array()
	_height.resize(n)
	_flags = PackedByteArray()
	_flags.resize(n)
	_slope = PackedFloat32Array()
	_slope.resize(nx * nz)
	# Upper layers start blocked; _step_layers opens the ones that turn out to
	# have a real surface. Otherwise agents could path through thin air.
	for l in range(1, layers):
		for i in range(l * nx * nz, (l + 1) * nx * nz):
			_flags[i] = F_BLOCKED
	_height_fn = height_fn
	_obstacles = obstacles
	_obstacle_i = 0
	_fingerprint = fp
	_cursor = 0
	_phase = Phase.HEIGHT
	reused_ground = false


## True when `other` covers the same cells (same origin, cell size and
## dimensions), so its height and slope arrays describe this grid's ground.
func same_lattice(other: NpcNavGrid) -> bool:
	return other != null and other.nx == nx and other.nz == nz \
			and is_equal_approx(other.cell_m, cell_m) \
			and other.origin.distance_squared_to(origin) < 1e-6


## Start a bake that REUSES a finished grid's ground: the HEIGHT and SLOPE
## phases are copied (the terrain has not moved — a prop was placed, a camp
## repainted, a space tagged) and the bake resumes at OBSTACLES. On a festival
## site the height pass is 600k terrain queries at ~2.8 ms a frame for two
## minutes; without this every placed prop paid it again. The caller decides
## the ground is unchanged (the bridge's terrain fingerprint); `prev` must be
## ready and on the same lattice, else this falls back to a full bake.
func begin_bake_reusing(prev: NpcNavGrid, height_fn: Callable, obstacles: Array = [],
		fp: String = "", surfaces_fn: Callable = Callable()) -> void:
	if prev == null or not prev.is_ready() or not same_lattice(prev):
		begin_bake(height_fn, obstacles, fp, surfaces_fn)
		return
	begin_bake(height_fn, obstacles, fp, surfaces_fn)
	reused_ground = true
	var cols := nx * nz
	for i in cols:
		_height[i] = prev._height[i]
		var deg: float = prev._slope[i]
		_slope[i] = deg
		if deg > MAX_SLOPE_DEG:
			_flags[i] = _flags[i] | F_STEEP | F_BLOCKED
	_cursor = 0
	_obstacle_i = 0
	if _obstacles.is_empty():
		_phase = Phase.LAYERS if _surfaces_fn.is_valid() else Phase.DONE
	else:
		_phase = Phase.OBSTACLES


## Whether this grid skipped its own height pass (see begin_bake_reusing).
var reused_ground := false


## Advance the bake by at most `budget` cells. Returns true once ready.
## Callers drive this from a frame/tick callback — never in a hot loop.
func bake_step(budget: int = CELLS_PER_FRAME) -> bool:
	match _phase:
		Phase.DONE:
			return true
		Phase.IDLE:
			return false
		Phase.HEIGHT:
			_step_height(budget)
		Phase.SLOPE:
			_step_slope(budget)
		Phase.OBSTACLES:
			_step_obstacles(budget)
		Phase.LAYERS:
			_step_layers(budget)
	return _phase == Phase.DONE


## Run the whole bake immediately. Offline/selftest only — this is precisely
## the call that must never appear on a per-frame path.
func bake_now(height_fn: Callable, obstacles: Array = [], fp: String = "",
		surfaces_fn: Callable = Callable()) -> void:
	begin_bake(height_fn, obstacles, fp, surfaces_fn)
	var guard := 0
	while not bake_step(1 << 20):
		guard += 1
		if guard > 64:
			push_error("NpcNavGrid.bake_now did not converge")
			return


func is_ready() -> bool:
	return _phase == Phase.DONE


func bake_progress() -> float:
	match _phase:
		Phase.DONE:
			return 1.0
		Phase.IDLE:
			return 0.0
		Phase.HEIGHT:
			return 0.5 * float(_cursor) / maxf(float(nx * nz), 1.0)
		Phase.SLOPE:
			return 0.5 + 0.35 * float(_cursor) / maxf(float(nx * nz), 1.0)
		Phase.OBSTACLES:
			return 0.85 + 0.10 * float(_obstacle_i) / maxf(float(_obstacles.size()), 1.0)
	return 0.95 + 0.05 * float(_cursor) / maxf(float(nx * nz), 1.0)


func _step_height(budget: int) -> void:
	var total := nx * nz
	var end := mini(_cursor + budget, total)
	if _height_fn.is_valid():
		while _cursor < end:
			var ix := _cursor % nx
			var iz := _cursor / nx
			var c := center_of(ix, iz)
			var y: float = _height_fn.call(c.x, c.y)
			_height[_cursor] = y if is_finite(y) else 0.0
			_cursor += 1
	else:
		_cursor = end   # no height source: flat grid, still walkable
	if _cursor >= total:
		_cursor = 0
		_phase = Phase.SLOPE


func _step_slope(budget: int) -> void:
	var total := nx * nz
	var end := mini(_cursor + budget, total)
	var b := SLOPE_BASELINE_CELLS
	var run := 2.0 * float(b) * cell_m
	while _cursor < end:
		var ix := _cursor % nx
		var iz := _cursor / nx
		# Central difference over the baseline — a terrain GRADE, not a step.
		var hx0 := _height[idx(maxi(ix - b, 0), iz)]
		var hx1 := _height[idx(mini(ix + b, nx - 1), iz)]
		var hz0 := _height[idx(ix, maxi(iz - b, 0))]
		var hz1 := _height[idx(ix, mini(iz + b, nz - 1))]
		var gx := (hx1 - hx0) / run
		var gz := (hz1 - hz0) / run
		var deg := rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
		_slope[_cursor] = deg
		if deg > MAX_SLOPE_DEG:
			_flags[_cursor] = _flags[_cursor] | F_STEEP | F_BLOCKED
		_cursor += 1
	if _cursor >= total:
		_cursor = 0
		_phase = Phase.OBSTACLES if not _obstacles.is_empty() else Phase.DONE


func _step_obstacles(budget: int) -> void:
	var spent := 0
	while _obstacle_i < _obstacles.size() and spent < budget:
		var o: Dictionary = _obstacles[_obstacle_i]
		var poly: PackedVector2Array = o.get("poly", PackedVector2Array())
		var flags := int(o.get("flags", F_BLOCKED))
		var band := float(o.get("band_m", 0.0))
		# Order matters: interior first (it must not clear the walls), then
		# the wall band, then doors punched back through it.
		if o.has("interior_flags"):
			spent += stamp_polygon_interior(poly, int(o["interior_flags"]))
		if band > 0.0:
			spent += stamp_polygon_edges(poly, band, flags)
		else:
			spent += stamp_polygon(poly, flags)
		var doors: Variant = o.get("doors", null)
		if doors is PackedVector2Array:
			var r := float(o.get("door_radius_m", 1.0))
			for d in doors as PackedVector2Array:
				clear_flags_in_circle(d, r, F_BLOCKED | F_WALL, F_DOOR)
		_obstacle_i += 1
	if _obstacle_i >= _obstacles.size():
		_cursor = 0
		_phase = Phase.LAYERS if _surfaces_fn.is_valid() else Phase.DONE


## Sample extra walkable surfaces (deck levels, upper floors) — but ONLY in
## cells flagged STRUCTURE, which is a tiny fraction of the grid. Everywhere
## else has exactly one surface and probing it would be pure waste.
##
## Nothing in the project generates walkable upper floors yet, so this mostly
## finds nothing today; the mechanism exists so that stairs, decks and ramps
## connect the moment content produces them (an inter-layer link is just a
## move whose height delta passes the normal step limit).
func _step_layers(budget: int) -> void:
	var total := nx * nz
	# Budget the EXPENSIVE work (surface probes), not the scan. Skipping a
	# non-structure cell is an array read; charging it the same as a raycast
	# made this phase take as long as the whole height pass for nothing.
	var probes := 0
	var scanned := 0
	var scan_cap := budget * LAYER_SCAN_RATIO
	while _cursor < total and probes < budget and scanned < scan_cap:
		scanned += 1
		if (int(_flags[_cursor]) & F_STRUCTURE) == 0:
			_cursor += 1
			continue
		probes += 1
		var ix := _cursor % nx
		var iz := _cursor / nx
		var c := center_of(ix, iz)
		var extra: Variant = _surfaces_fn.call(c.x, c.y)
		if extra is PackedFloat32Array:
			var arr: PackedFloat32Array = extra
			for k in mini(arr.size(), layers - 1):
				var i := idx(ix, iz, k + 1)
				_height[i] = arr[k]
				_flags[i] = int(_flags[i]) & ~F_BLOCKED
		_cursor += 1
	if _cursor >= total:
		_phase = Phase.DONE


# --- stamping ----------------------------------------------------------------

## Cell range covering a polygon's AABB, inflated by `pad_m`. Returns
## [ix0, iz0, ix1, iz1] already clamped, or an empty array when off-grid.
func _poly_cell_range(poly: PackedVector2Array, pad_m: float) -> Array:
	if poly.size() < 3:
		return []
	var lo := poly[0]
	var hi := poly[0]
	for p in poly:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	lo -= Vector2(pad_m, pad_m)
	hi += Vector2(pad_m, pad_m)
	var c0 := cell_of(lo)
	var c1 := cell_of(hi)
	if c1.x < 0 or c1.y < 0 or c0.x >= nx or c0.y >= nz:
		return []
	return [maxi(c0.x, 0), maxi(c0.y, 0), mini(c1.x, nx - 1), mini(c1.y, nz - 1)]


## Stamp every cell whose centre is inside `poly`. Returns cells visited.
func stamp_polygon(poly: PackedVector2Array, flags: int) -> int:
	var r := _poly_cell_range(poly, 0.0)
	if r.is_empty():
		return 0
	var visited := 0
	for iz in range(int(r[1]), int(r[3]) + 1):
		for ix in range(int(r[0]), int(r[2]) + 1):
			visited += 1
			if Geometry2D.is_point_in_polygon(center_of(ix, iz), poly):
				_or_flags_all_layers(ix, iz, flags)
	return visited


## Stamp a band of `band_m` around the polygon's EDGES only, leaving the
## interior untouched — walls that you can walk inside of once through a door.
func stamp_polygon_edges(poly: PackedVector2Array, band_m: float, flags: int) -> int:
	var r := _poly_cell_range(poly, band_m)
	if r.is_empty():
		return 0
	var visited := 0
	var n := poly.size()
	for iz in range(int(r[1]), int(r[3]) + 1):
		for ix in range(int(r[0]), int(r[2]) + 1):
			visited += 1
			var c := center_of(ix, iz)
			var near := false
			for i in n:
				var a := poly[i]
				var b := poly[(i + 1) % n]
				if _point_segment_dist(c, a, b) <= band_m:
					near = true
					break
			if near:
				_or_flags_all_layers(ix, iz, flags)
	return visited


## Mark the interior of a footprint (used with stamp_polygon_edges so the
## inside is flagged but stays walkable).
func stamp_polygon_interior(poly: PackedVector2Array, flags: int) -> int:
	var r := _poly_cell_range(poly, 0.0)
	if r.is_empty():
		return 0
	var visited := 0
	for iz in range(int(r[1]), int(r[3]) + 1):
		for ix in range(int(r[0]), int(r[2]) + 1):
			visited += 1
			if Geometry2D.is_point_in_polygon(center_of(ix, iz), poly):
				_or_flags_all_layers(ix, iz, flags & ~F_BLOCKED)
	return visited


## Punch an opening: clear `flags` (typically F_BLOCKED|F_WALL) inside a
## radius and mark it F_DOOR. Used for real and auto doors in 3c.
func clear_flags_in_circle(center: Vector2, radius_m: float, clear: int, set_flags: int = 0) -> void:
	var c0 := cell_of(center - Vector2(radius_m, radius_m))
	var c1 := cell_of(center + Vector2(radius_m, radius_m))
	var r2 := radius_m * radius_m
	for iz in range(maxi(c0.y, 0), mini(c1.y, nz - 1) + 1):
		for ix in range(maxi(c0.x, 0), mini(c1.x, nx - 1) + 1):
			if center_of(ix, iz).distance_squared_to(center) > r2:
				continue
			for l in layers:
				var i := idx(ix, iz, l)
				_flags[i] = (_flags[i] & ~clear) | set_flags


func _or_flags_all_layers(ix: int, iz: int, flags: int) -> void:
	for l in layers:
		var i := idx(ix, iz, l)
		_flags[i] = _flags[i] | flags


static func _point_segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# --- queries -----------------------------------------------------------------

func flags_at(ix: int, iz: int, layer: int = 0) -> int:
	if not in_bounds(ix, iz):
		return F_BLOCKED
	return int(_flags[idx(ix, iz, layer)])


func height_at(ix: int, iz: int, layer: int = 0) -> float:
	if not in_bounds(ix, iz):
		return 0.0
	return _height[idx(ix, iz, layer)]


func slope_deg_at(ix: int, iz: int) -> float:
	if not in_bounds(ix, iz):
		return 90.0
	return _slope[iz * nx + ix]


func is_walkable(ix: int, iz: int, layer: int = 0) -> bool:
	if not in_bounds(ix, iz) or not is_ready():
		return false
	return (int(_flags[idx(ix, iz, layer)]) & BLOCKING) == 0


func is_walkable_world(world_xz: Vector2, layer: int = 0) -> bool:
	var c := cell_of(world_xz)
	return is_walkable(c.x, c.y, layer)


## Ground height at a world point (nearest cell). Falls back to 0 off-grid.
func height_at_world(world_xz: Vector2, layer: int = 0) -> float:
	var c := cell_of(world_xz)
	return height_at(c.x, c.y, layer)


## Nearest walkable cell to `world_xz` within `max_radius_m`, or (-1,-1).
## Spaces sometimes resolve to a point inside a prop or wall; agents need a
## legal place to stand near it rather than a failed query.
func nearest_walkable(world_xz: Vector2, max_radius_m: float = 8.0, layer: int = 0) -> Vector2i:
	var c := cell_of(world_xz)
	if is_walkable(c.x, c.y, layer):
		return c
	var max_r := int(ceil(max_radius_m / cell_m))
	for r in range(1, max_r + 1):
		# Ring scan, deterministic order (matters for reproducible paths).
		for d in range(-r, r + 1):
			for cand in [Vector2i(c.x + d, c.y - r), Vector2i(c.x + d, c.y + r),
					Vector2i(c.x - r, c.y + d), Vector2i(c.x + r, c.y + d)]:
				if is_walkable(cand.x, cand.y, layer):
					return cand
	return Vector2i(-1, -1)


## Cells carrying a flag on layer 0 — diagnostics for the harness/inspector.
func count_flag(flag: int) -> int:
	var n := 0
	for i in nx * nz:
		if (int(_flags[i]) & flag) != 0:
			n += 1
	return n


## Cells that turned out to have a walkable surface above the ground.
func upper_surface_cells() -> int:
	var n := 0
	for l in range(1, layers):
		for i in range(l * nx * nz, (l + 1) * nx * nz):
			if (int(_flags[i]) & BLOCKING) == 0:
				n += 1
	return n


func walkable_cell_count(layer: int = 0) -> int:
	if not is_ready():
		return 0
	var n := 0
	for iz in nz:
		for ix in nx:
			if (int(_flags[idx(ix, iz, layer)]) & BLOCKING) == 0:
				n += 1
	return n


# --- invalidation ------------------------------------------------------------

func fingerprint() -> String:
	return _fingerprint


func needs_rebuild(fp: String) -> bool:
	return not is_ready() or _fingerprint != fp


## Fold the things that can move a wall into one key, in the
## ConduitAStar.obstacle_fingerprint idiom. Any change re-bakes.
static func compose_fingerprint(space_rev: int, prop_rev: int, style_rev: int,
		terrain_rev: int, center: Vector2, half_extent: float) -> String:
	return "nav|%d|%d|%d|%d|%.1f,%.1f|%.1f" % [
		space_rev, prop_rev, style_rev, terrain_rev, center.x, center.y, half_extent]
