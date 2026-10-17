class_name GraphForceLayout
extends RefCounted

## Force-directed freeform layout: nodes space themselves out without
## overlapping, wires pull connected nodes together, and — because every card
## takes its inputs on the TOP edge and gives its outputs on the BOTTOM edge —
## a flow force stacks the graph top to bottom: panels, then controllers, then
## storage, then loads. Pure and deterministic (no engine calls, no RNG), so the
## selftest can pin it and the same graph always settles the same way.
##
## A d3-force style simulation over card CENTRES:
##   - link springs whose rest length is measured between card EDGES (a 640 px
##     array and a 120 px battery keep the same visible gap);
##   - a flow force on every directed wire (source above target), plus an
##     optional "rows" force that pulls nodes of one layer onto one line;
##   - many-body repulsion (inverse square) so components spread;
##   - rectangle collision with `spacing` padding — the term that guarantees no
##     two cards overlap at rest;
##   - weak gravity toward the starting centroid so the graph stays in view;
##   - cooling via `alpha`, d3's 300-step schedule, with a velocity decay.
## Pinned nodes never move: a node the player pinned, or the one being dragged.
##
## Usage (one-shot "Tidy"): GraphForceLayout.tidy(items, conns, port_side)
## → {id: top-left Vector2}. Live: new(), setup(), then step() per frame within
## a time budget; reheat() when the graph changes.

const ALPHA_MIN := 0.001
## d3's default: alpha reaches ALPHA_MIN in ~300 steps.
const ALPHA_DECAY := 0.0228
const VELOCITY_DECAY := 0.4
const MAX_STEP_PX := 48.0
## Above this many nodes repulsion and collision use a uniform grid.
const GRID_THRESHOLD := 150

## Tunables (also the Layout settings sliders). Graph units = px at zoom 1.
var spacing := 56.0          ## minimum gap between card edges
var link_length := 150.0     ## rest gap between the edges of wired cards
var flow_strength := 0.6     ## 0 = organic web … 1 = strict layers
var gravity := 0.04
var charge := 60000.0        ## many-body repulsion strength
var keep_rows := true        ## pull each layer onto one horizontal line

var alpha := 1.0

var _ids: PackedStringArray = PackedStringArray()
var _index := {}
var _pos: PackedVector2Array = PackedVector2Array()   ## centres
var _vel: PackedVector2Array = PackedVector2Array()
var _size: PackedVector2Array = PackedVector2Array()
var _pinned: PackedByteArray = PackedByteArray()
var _edges: Array = []          ## [a, b, dir] — dir +1: a above b, 0: no order
var _degree: PackedInt32Array = PackedInt32Array()
var _layer: PackedInt32Array = PackedInt32Array()
## Nodes in a connected piece that has at least one DIRECTED wire — only these
## are put on rows (an unordered graph has no layers to line up, and pulling it
## onto one line crams every node into a single row). The middle panel of a
## series string has no directed wire of its own but belongs to the panels'
## row all the same.
var _directed: PackedByteArray = PackedByteArray()
## Target centre height per node (its layer's row), used with keep_rows.
var _row_y: PackedFloat32Array = PackedFloat32Array()
var _centroid := Vector2.ZERO


## Settings dict → this instance (keys as the vars above). Unknown keys ignored.
func configure(params: Dictionary) -> GraphForceLayout:
	spacing = float(params.get("spacing", spacing))
	link_length = float(params.get("link_length", link_length))
	flow_strength = clampf(float(params.get("flow_strength", flow_strength)), 0.0, 1.0)
	gravity = float(params.get("gravity", gravity))
	charge = float(params.get("charge", charge))
	keep_rows = bool(params.get("keep_rows", keep_rows))
	return self


static func default_params() -> Dictionary:
	var f := GraphForceLayout.new()
	return {"spacing": f.spacing, "link_length": f.link_length, "flow_strength": f.flow_strength,
		"gravity": f.gravity, "charge": f.charge, "keep_rows": f.keep_rows}


## `items`: graph item dicts (id, x, y = TOP-LEFT, width, height).
## `connections`: {source_item_id, source_handle_id, target_item_id, target_handle_id}.
## `port_side`: Callable(item: Dictionary, handle_id: String) -> float giving the
## port's vertical position on the card (0 = top edge, 1 = bottom, else side);
## an invalid Callable treats every wire as unordered.
## `pinned`: {id: true}.
func setup(items: Array, connections: Array, port_side: Callable = Callable(),
		pinned: Dictionary = {}) -> void:
	_ids = PackedStringArray()
	_index = {}
	_pos = PackedVector2Array()
	_vel = PackedVector2Array()
	_size = PackedVector2Array()
	_pinned = PackedByteArray()
	_edges = []
	var by_id := {}
	for it in items:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		var iid := str(d.get("id", ""))
		if iid.is_empty() or _index.has(iid):
			continue
		var sz := Vector2(maxf(float(d.get("width", 120.0)), 8.0), maxf(float(d.get("height", 90.0)), 8.0))
		_index[iid] = _ids.size()
		_ids.append(iid)
		_size.append(sz)
		_pos.append(Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0))) + sz * 0.5)
		_vel.append(Vector2.ZERO)
		_pinned.append(1 if bool(pinned.get(iid, false)) else 0)
		by_id[iid] = d
	_separate_coincident()
	_degree = PackedInt32Array()
	_degree.resize(_ids.size())
	var seen := {}
	for c in connections:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = c
		var sa := str(cd.get("source_item_id", ""))
		var tb := str(cd.get("target_item_id", ""))
		if sa == tb or not _index.has(sa) or not _index.has(tb):
			continue
		var a: int = _index[sa]
		var b: int = _index[tb]
		var dir := 0
		if port_side.is_valid():
			var ys := float(port_side.call(by_id[sa], str(cd.get("source_handle_id", ""))))
			var yt := float(port_side.call(by_id[tb], str(cd.get("target_handle_id", ""))))
			dir = edge_direction(ys, yt)
		if dir < 0:
			var t := a
			a = b
			b = t
			dir = 1
		# Parallel wires between one pair count once (six wires into a
		# controller's PV port are one relationship, not six springs).
		var key := "%d>%d" % [mini(a, b), maxi(a, b)]
		if seen.has(key):
			var prev: Array = _edges[int(seen[key])]
			if int(prev[2]) == 0 and dir != 0:
				_edges[int(seen[key])] = [a, b, dir]
			continue
		seen[key] = _edges.size()
		_edges.append([a, b, dir])
		_degree[a] += 1
		_degree[b] += 1
	_layer = layers_for(_ids.size(), _edges)
	_directed = PackedByteArray()
	_directed.resize(_ids.size())
	var comp := _components()
	var comp_dir := {}
	for e in _edges:
		if int(e[2]) != 0:
			comp_dir[comp[int(e[0])]] = true
	for i in _ids.size():
		if comp_dir.has(comp[i]):
			_directed[i] = 1
	_compute_rows()
	_centroid = Vector2.ZERO
	for p in _pos:
		_centroid += p
	if not _pos.is_empty():
		_centroid /= float(_pos.size())
	alpha = 1.0


## A wire leaving a card's bottom edge (an output) into another card's top edge
## (an input) puts the source ABOVE the target: +1. The reverse (someone dragged
## the wire from the input end) is -1. Same-edge pairs — two batteries wired top
## to top in series — set no vertical order: 0.
static func edge_direction(src_ry: float, tgt_ry: float) -> int:
	if is_nan(src_ry) or is_nan(tgt_ry):
		return 0
	var s_bottom := src_ry >= 0.75
	var s_top := src_ry <= 0.25
	var t_bottom := tgt_ry >= 0.75
	var t_top := tgt_ry <= 0.25
	if s_bottom and t_top:
		return 1
	if s_top and t_bottom:
		return -1
	if s_bottom and not t_bottom and not t_top:
		return 1   # bottom output into a side input still flows down
	if t_top and not s_top and not s_bottom:
		return 1
	return 0


## Union-find component id per node (over every wire).
func _components() -> PackedInt32Array:
	var parent := PackedInt32Array()
	parent.resize(_ids.size())
	for i in _ids.size():
		parent[i] = i
	for e in _edges:
		var ra := _uf_find(parent, int(e[0]))
		var rb := _uf_find(parent, int(e[1]))
		if ra != rb:
			parent[ra] = rb
	var out := PackedInt32Array()
	out.resize(_ids.size())
	for i in _ids.size():
		out[i] = _uf_find(parent, i)
	return out


## (A lambda would capture `parent` by value — packed arrays copy — and never
## see the unions, so this is a plain function.)
static func _uf_find(parent: PackedInt32Array, x: int) -> int:
	var r := x
	while parent[r] != r:
		r = parent[r]
	return r


## Row heights: layer k's row sits a link's gap below the tallest card of
## layer k-1. Anchored so the rows' mean is where the directed nodes started.
func _compute_rows() -> void:
	_row_y = PackedFloat32Array()
	_row_y.resize(_ids.size())
	var max_l := 0
	var tallest := {}
	var cur_sum := 0.0
	var n_dir := 0
	for i in _ids.size():
		if _directed[i] == 0:
			continue
		var l := int(_layer[i])
		max_l = maxi(max_l, l)
		tallest[l] = maxf(float(tallest.get(l, 0.0)), _size[i].y)
		cur_sum += _pos[i].y
		n_dir += 1
	if n_dir == 0:
		return
	var ly := {0: 0.0}
	for l in range(1, max_l + 1):
		ly[l] = float(ly[l - 1]) + float(tallest.get(l - 1, 0.0)) * 0.5 + link_length \
			+ float(tallest.get(l, 0.0)) * 0.5
	var tgt_sum := 0.0
	for i in _ids.size():
		if _directed[i] == 1:
			tgt_sum += float(ly[int(_layer[i])])
	var off := cur_sum / float(n_dir) - tgt_sum / float(n_dir)
	for i in _ids.size():
		if _directed[i] == 1:
			_row_y[i] = float(ly[int(_layer[i])]) + off


## Longest-path layer of every node over the ordered edges (cycles broken by
## capping relaxation at n passes). Sources are layer 0.
static func layers_for(n: int, edges: Array) -> PackedInt32Array:
	var layer := PackedInt32Array()
	layer.resize(n)
	if n == 0:
		return layer
	for _pass in n:
		var changed := false
		for e in edges:
			if int(e[2]) == 0:
				continue
			var a := int(e[0])
			var b := int(e[1])
			if layer[b] < layer[a] + 1 and layer[a] + 1 < n:
				layer[b] = layer[a] + 1
				changed = true
		if not changed:
			break
	# Unordered neighbours share a layer (series batteries sit side by side).
	for _pass2 in 4:
		for e in edges:
			if int(e[2]) != 0:
				continue
			var a2 := int(e[0])
			var b2 := int(e[1])
			var m := maxi(layer[a2], layer[b2])
			layer[a2] = m
			layer[b2] = m
	return layer


func node_count() -> int:
	return _ids.size()


func set_pinned(iid: String, on: bool) -> void:
	if _index.has(iid):
		_pinned[int(_index[iid])] = 1 if on else 0


## Move one node (the dragged one) — its centre — and pin it there.
func set_center(iid: String, center: Vector2) -> void:
	if not _index.has(iid):
		return
	var i: int = _index[iid]
	_pos[i] = center
	_vel[i] = Vector2.ZERO


func reheat(to_alpha: float = 0.5) -> void:
	alpha = maxf(alpha, to_alpha)


func is_settled() -> bool:
	return alpha < ALPHA_MIN


## One simulation step. Returns the largest distance any node moved.
func step() -> float:
	var n := _ids.size()
	if n == 0:
		alpha = 0.0
		return 0.0
	alpha += (0.0 - alpha) * ALPHA_DECAY
	var force := PackedVector2Array()
	force.resize(n)
	# With no wires there is nothing to organise: only remove overlaps, so an
	# authored arrangement (a row of panels over a controller, before any wire
	# exists) keeps its shape instead of being blown into a ring by repulsion.
	if not _edges.is_empty():
		_apply_links(force)
		_apply_flow(force)
		_apply_charge(force)
		_apply_gravity(force)
	var moved := 0.0
	for i in n:
		if _pinned[i] == 1:
			_vel[i] = Vector2.ZERO
			continue
		var v := (_vel[i] + force[i]) * (1.0 - VELOCITY_DECAY)
		if v.length() > MAX_STEP_PX:
			v = v.normalized() * MAX_STEP_PX
		_vel[i] = v
		_pos[i] += v
		moved = maxf(moved, v.length())
	# Layering is a CONSTRAINT, not a soft force: with springs pulling every
	# panel toward its controller, a force-only flow term let the panels fan
	# out level with the controller instead of sitting above it.
	_project_flow()
	# Collision last and at full strength: overlap is never acceptable, at any
	# temperature.
	moved = maxf(moved, _apply_collision(2))
	return moved


## Step until cool (or `max_steps`), then remove any overlap that is left.
func run_to_rest(max_steps: int = 400) -> int:
	var steps := 0
	while steps < max_steps and not is_settled():
		step()
		steps += 1
	_apply_collision(64)
	return steps


## {id: top-left Vector2} for every node.
func positions() -> Dictionary:
	var out := {}
	for i in _ids.size():
		out[_ids[i]] = _pos[i] - _size[i] * 0.5
	return out


func center_of(iid: String) -> Vector2:
	return _pos[int(_index[iid])] if _index.has(iid) else Vector2.INF


func layer_of(iid: String) -> int:
	return _layer[int(_index[iid])] if _index.has(iid) else -1


## One-shot layout: run to rest and return {id: top-left}.
static func tidy(items: Array, connections: Array, port_side: Callable = Callable(),
		params: Dictionary = {}, pinned: Dictionary = {}, max_steps: int = 400) -> Dictionary:
	var f := GraphForceLayout.new()
	f.configure(params)
	f.setup(items, connections, port_side, pinned)
	f.run_to_rest(max_steps)
	return f.positions()


# ---- forces --------------------------------------------------------------------

## Half the card's extent along `dir` (a unit vector) — the distance from its
## centre to its edge in that direction.
static func half_extent(sz: Vector2, dir: Vector2) -> float:
	return 0.5 * (absf(dir.x) * sz.x + absf(dir.y) * sz.y)


func _apply_links(force: PackedVector2Array) -> void:
	for e in _edges:
		var a := int(e[0])
		var b := int(e[1])
		var d := _pos[b] - _pos[a]
		var dist := d.length()
		if dist < 1e-3:
			continue
		var dir := d / dist
		var rest := link_length + half_extent(_size[a], dir) + half_extent(_size[b], dir)
		# d3's link force: strength 1/min(degree), bias by degree so a hub
		# moves less than a leaf.
		var k := 1.0 / float(maxi(1, mini(_degree[a], _degree[b])))
		var f := d * ((dist - rest) / dist) * alpha * k * 0.5
		var bias := float(_degree[a]) / float(maxi(1, _degree[a] + _degree[b]))
		force[b] -= f * bias
		force[a] += f * (1.0 - bias)


## Position-based flow: every directed wire's target is pushed to at least a
## link's gap below its source (by `flow_strength` of the shortfall per step),
## and with keep_rows each node moves toward its layer's mean height.
func _project_flow() -> void:
	if flow_strength <= 0.0:
		return
	for _pass in 2:
		for e in _edges:
			if int(e[2]) == 0:
				continue
			var a := int(e[0])
			var b := int(e[1])
			var need := (_size[a].y + _size[b].y) * 0.5 + link_length
			var dy := _pos[b].y - _pos[a].y
			if dy >= need:
				continue
			var corr := (need - dy) * flow_strength * 0.5
			var wa := 0.0 if _pinned[a] == 1 else (2.0 if _pinned[b] == 1 else 1.0)
			var wb := 0.0 if _pinned[b] == 1 else (2.0 if _pinned[a] == 1 else 1.0)
			_pos[a] = _pos[a] - Vector2(0.0, corr * wa * 0.5)
			_pos[b] = _pos[b] + Vector2(0.0, corr * wb * 0.5)
	if not keep_rows or _row_y.is_empty():
		return
	for i in _ids.size():
		if _directed[i] == 0 or _pinned[i] == 1:
			continue
		_pos[i] = _pos[i] + Vector2(0.0, (_row_y[i] - _pos[i].y) * flow_strength * 0.5)


## Soft part of the flow (a velocity nudge so the constraint is not fighting
## the springs every step). The projection above does the real work.
func _apply_flow(force: PackedVector2Array) -> void:
	if flow_strength <= 0.0:
		return
	for e in _edges:
		if int(e[2]) == 0:
			continue
		var a := int(e[0])
		var b := int(e[1])
		var need := (_size[a].y + _size[b].y) * 0.5 + link_length
		var dy := _pos[b].y - _pos[a].y
		if dy < need:
			var corr := (need - dy) * flow_strength * alpha * 0.5
			force[a] = force[a] - Vector2(0.0, corr * 0.5)
			force[b] = force[b] + Vector2(0.0, corr * 0.5)
	if not keep_rows:
		return
	var sum := {}
	var cnt := {}
	for i in _ids.size():
		if _directed[i] == 0:
			continue
		var l := int(_layer[i])
		sum[l] = float(sum.get(l, 0.0)) + _pos[i].y
		cnt[l] = int(cnt.get(l, 0)) + 1
	for i in _ids.size():
		var l := int(_layer[i])
		if _directed[i] == 0 or int(cnt.get(l, 0)) < 2:
			continue
		var mean := float(sum[l]) / float(cnt[l])
		force[i] = force[i] + Vector2(0.0, (mean - _pos[i].y) * flow_strength * alpha * 0.12)


func _apply_charge(force: PackedVector2Array) -> void:
	var n := _ids.size()
	if charge <= 0.0:
		return
	var cutoff := 1.0e12
	var grid := {}
	var cell := 0.0
	if n > GRID_THRESHOLD:
		cell = _grid_cell()
		cutoff = cell * 3.0
		grid = _build_grid(cell)
	for i in n:
		var others: Array = range(i + 1, n) if grid.is_empty() else _neighbours(grid, cell, i, 2)
		for jv in others:
			var j := int(jv)
			if grid.size() > 0 and j <= i:
				continue
			var d := _pos[j] - _pos[i]
			var dist2 := d.length_squared()
			if dist2 > cutoff * cutoff:
				continue
			if dist2 < 1.0:
				d = _tiebreak(i, j)
				dist2 = 1.0
			var f := d / sqrt(dist2) * (charge * alpha / dist2)
			force[i] -= f
			force[j] += f


func _apply_gravity(force: PackedVector2Array) -> void:
	for i in _ids.size():
		force[i] += (_centroid - _pos[i]) * gravity * alpha


## Push overlapping cards (grown by spacing) apart along the axis of least
## overlap. Pinned cards stay; their partner takes the whole move. Returns the
## largest single correction.
func _apply_collision(iterations: int) -> float:
	var n := _ids.size()
	var worst := 0.0
	var pad := spacing
	var grid := {}
	var cell := 0.0
	for _it in iterations:
		var moved := false
		if n > GRID_THRESHOLD:
			cell = _grid_cell()
			grid = _build_grid(cell)
		for i in n:
			var others: Array = range(i + 1, n) if grid.is_empty() else _neighbours(grid, cell, i, 1)
			for jv in others:
				var j := int(jv)
				if grid.size() > 0 and j <= i:
					continue
				if _pinned[i] == 1 and _pinned[j] == 1:
					continue
				var d := _pos[j] - _pos[i]
				var ox := (_size[i].x + _size[j].x) * 0.5 + pad - absf(d.x)
				var oy := (_size[i].y + _size[j].y) * 0.5 + pad - absf(d.y)
				if ox <= 0.0 or oy <= 0.0:
					continue
				var push := Vector2.ZERO
				if ox < oy:
					push.x = ox * (1.0 if d.x > 0.0 or (d.x == 0.0 and j > i) else -1.0)
				else:
					push.y = oy * (1.0 if d.y > 0.0 or (d.y == 0.0 and j > i) else -1.0)
				var wi := 0.0 if _pinned[i] == 1 else (1.0 if _pinned[j] == 1 else 0.5)
				var wj := 0.0 if _pinned[j] == 1 else (1.0 if _pinned[i] == 1 else 0.5)
				_pos[i] -= push * wi
				_pos[j] += push * wj
				worst = maxf(worst, push.length())
				moved = true
		if not moved:
			break
	return worst


# ---- helpers -------------------------------------------------------------------

## Nodes that start on the same spot get a deterministic nudge apart (a fresh
## seed graph can stack items).
func _separate_coincident() -> void:
	for i in _pos.size():
		for j in range(i + 1, _pos.size()):
			if _pos[i].distance_squared_to(_pos[j]) < 1.0:
				_pos[j] += _tiebreak(i, j) * 12.0


static func _tiebreak(i: int, j: int) -> Vector2:
	var ang := float((i * 73856093) ^ (j * 19349663)) * 0.000123
	return Vector2(cos(ang), sin(ang))


func _grid_cell() -> float:
	var m := 0.0
	for s in _size:
		m = maxf(m, maxf(s.x, s.y))
	return m + spacing


func _build_grid(cell: float) -> Dictionary:
	var g := {}
	for i in _pos.size():
		var k := Vector2i(floori(_pos[i].x / cell), floori(_pos[i].y / cell))
		if not g.has(k):
			g[k] = []
		(g[k] as Array).append(i)
	return g


func _neighbours(grid: Dictionary, cell: float, i: int, r: int) -> Array:
	var out: Array = []
	var k := Vector2i(floori(_pos[i].x / cell), floori(_pos[i].y / cell))
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			var kk := Vector2i(k.x + dx, k.y + dy)
			if grid.has(kk):
				out.append_array(grid[kk])
	return out
