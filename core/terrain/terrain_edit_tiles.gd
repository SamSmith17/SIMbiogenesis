class_name TerrainEditTiles
extends RefCounted

## Sparse, high-resolution terrain edit layer (ROADMAP Pillar 1 — the "grade a
## site" substrate). Stores per-vertex height DELTAS (metres, added on top of the
## composed detail DEM) on a fixed world grid at CELL_M spacing, bucketed into
## TILE_CELLS-square tiles that are only allocated where the player actually
## edits. This is what lets us level a house pad or shape a pond bank at ~1.5 m
## resolution WITHOUT paying for a dense 2000² grid over the whole 3 km patch.
##
## Storage model: each tile owns (TILE_CELLS+1)² corner samples; tiles overlap
## by one sample so a shared edge is written to BOTH neighbours (see
## _owning_axis) and their independently-built meshes line up seamlessly.
##
## The class is pure data + meshing helpers (no scene nodes), so it is fully
## covered by terrain_selftest.gd.

## Edit resolution in metres per cell (the real precision lever).
const CELL_M := 1.5
## Cells per tile edge. Tile world span = TILE_CELLS * CELL_M (96 m at 1.5 m).
const TILE_CELLS := 64
const SAVE_VERSION := 1

var cell_m: float = CELL_M
var tile_cells: int = TILE_CELLS
## Vector2i(tx, tz) -> PackedFloat32Array of (tile_cells+1)² corner deltas.
var _tiles: Dictionary = {}
## Vector2i(tx, tz) -> true; tiles whose geometry changed since consume_dirty().
var _dirty: Dictionary = {}
## Region-scoped undo: while a session is active, the pre-edit state of every tile
## touched is captured lazily (key -> PackedFloat32Array copy, or null when the
## tile did not exist yet). Only touched tiles are snapshotted — cheap even for a
## huge level op, since undo memory scales with edited area, not the whole patch.
var _session_active: bool = false
var _session_before: Dictionary = {}


func _samples_per_edge() -> int:
	return tile_cells + 1


func _tile_array_size() -> int:
	var e := _samples_per_edge()
	return e * e


## True when nothing has ever been edited (all tiles absent).
func is_empty() -> bool:
	return _tiles.is_empty()


func clear() -> void:
	for key in _tiles.keys():
		_dirty[key] = true
	_tiles.clear()


## World XZ -> fractional global sample coordinate (continuous).
func _world_to_sample(x: float, z: float) -> Vector2:
	return Vector2(x / cell_m, z / cell_m)


## Global sample index -> world XZ of that sample.
func sample_to_world(gi: int, gj: int) -> Vector2:
	return Vector2(float(gi) * cell_m, float(gj) * cell_m)


## The (tile, local index) owners of a single global sample on one axis. A sample
## on a tile boundary belongs to two adjacent tiles (local 0 and local N).
func _owning_axis(g: int) -> Array:
	var n := tile_cells
	var tp := floori(float(g) / float(n))
	var li := g - tp * n
	var out := [[tp, li]]
	if li == 0:
		out.append([tp - 1, n])
	return out


func _tile_of_sample_axis(g: int) -> int:
	return floori(float(g) / float(tile_cells))


## Read the delta at a global sample (0 where no tile is allocated).
func get_delta_sample(gi: int, gj: int) -> float:
	var tx := _tile_of_sample_axis(gi)
	var tz := _tile_of_sample_axis(gj)
	var key := Vector2i(tx, tz)
	if not _tiles.has(key):
		return 0.0
	var arr: PackedFloat32Array = _tiles[key]
	var li := gi - tx * tile_cells
	var lj := gj - tz * tile_cells
	var e := _samples_per_edge()
	return arr[lj * e + li]


## Write the delta at a global sample into every owning tile (allocating tiles as
## needed) and mark those tiles dirty.
func set_delta_sample(gi: int, gj: int, value: float) -> void:
	var e := _samples_per_edge()
	for ox in _owning_axis(gi):
		for oz in _owning_axis(gj):
			var key := Vector2i(ox[0], oz[0])
			_snapshot_tile(key)
			var arr: PackedFloat32Array = _ensure_tile(key)
			arr[oz[1] * e + ox[1]] = value
			_dirty[key] = true


func add_delta_sample(gi: int, gj: int, value: float) -> void:
	set_delta_sample(gi, gj, get_delta_sample(gi, gj) + value)


func _ensure_tile(key: Vector2i) -> PackedFloat32Array:
	if _tiles.has(key):
		return _tiles[key]
	var arr := PackedFloat32Array()
	arr.resize(_tile_array_size())
	_tiles[key] = arr
	return arr


## Bilinear delta at an arbitrary world XZ (0 outside all tiles).
func sample_delta(x: float, z: float) -> float:
	if _tiles.is_empty():
		return 0.0
	var g := _world_to_sample(x, z)
	var gi0 := floori(g.x)
	var gj0 := floori(g.y)
	var tx := g.x - float(gi0)
	var tz := g.y - float(gj0)
	var d00 := get_delta_sample(gi0, gj0)
	var d10 := get_delta_sample(gi0 + 1, gj0)
	var d01 := get_delta_sample(gi0, gj0 + 1)
	var d11 := get_delta_sample(gi0 + 1, gj0 + 1)
	return lerpf(lerpf(d00, d10, tx), lerpf(d01, d11, tx), tz)


## Global sample-index bounds (inclusive) covering a world AABB, padded by
## `pad_cells` samples so brush/feather skirts are included.
func sample_bounds_for_aabb(aabb: Rect2, pad_cells: int = 1) -> Vector4i:
	var lo := _world_to_sample(aabb.position.x, aabb.position.y)
	var hi := _world_to_sample(aabb.end.x, aabb.end.y)
	return Vector4i(
		floori(lo.x) - pad_cells, floori(lo.y) - pad_cells,
		ceili(hi.x) + pad_cells, ceili(hi.y) + pad_cells)


# ---------------------------------------------------------------------------
# Dirty tracking
# ---------------------------------------------------------------------------

func has_dirty() -> bool:
	return not _dirty.is_empty()


## Return the dirty tile keys and clear the set (caller re-meshes just these).
func consume_dirty() -> Array:
	var out := _dirty.keys()
	_dirty.clear()
	return out


func mark_all_dirty() -> void:
	for key in _tiles.keys():
		_dirty[key] = true


func active_tiles() -> Array:
	return _tiles.keys()


## Estimated cut (soil removed) and fill (soil added) volumes in m³, integrating
## each unique global sample's delta over one cell area. Shared tile-edge samples
## are counted once. { "cut_m3": float, "fill_m3": float, "net_m3": float }.
func volume_estimate() -> Dictionary:
	var cell_area := cell_m * cell_m
	var e := _samples_per_edge()
	var seen := {}
	var cut := 0.0
	var fill := 0.0
	for key in _tiles.keys():
		var k: Vector2i = key
		var arr: PackedFloat32Array = _tiles[key]
		var gi0 := k.x * tile_cells
		var gj0 := k.y * tile_cells
		for lj in e:
			for li in e:
				var gkey := Vector2i(gi0 + li, gj0 + lj)
				if seen.has(gkey):
					continue
				seen[gkey] = true
				var d := arr[lj * e + li]
				if d > 0.0:
					fill += d * cell_area
				elif d < 0.0:
					cut += -d * cell_area
	return {"cut_m3": cut, "fill_m3": fill, "net_m3": fill - cut}


# ---------------------------------------------------------------------------
# Region-scoped undo sessions
# ---------------------------------------------------------------------------

## Begin capturing pre-edit tile state for undo. Nesting is a no-op (the outer
## session owns the snapshot).
func begin_session() -> void:
	if _session_active:
		return
	_session_active = true
	_session_before = {}


func _snapshot_tile(key: Vector2i) -> void:
	if not _session_active or _session_before.has(key):
		return
	if _tiles.has(key):
		_session_before[key] = (_tiles[key] as PackedFloat32Array).duplicate()
	else:
		_session_before[key] = null  # tile did not exist before the edit


## Close the session and return an undo snapshot { key -> PackedFloat32Array|null }
## of exactly the tiles that changed (empty when nothing was touched).
func end_session() -> Dictionary:
	_session_active = false
	var snap := _session_before
	_session_before = {}
	return snap


## Restore tiles from an undo/redo snapshot and return the inverse snapshot so the
## caller can push it onto the redo/undo stack. Touched tiles are marked dirty.
func apply_snapshot(snap: Dictionary) -> Dictionary:
	var inverse := {}
	for key in snap.keys():
		if _tiles.has(key):
			inverse[key] = (_tiles[key] as PackedFloat32Array).duplicate()
		else:
			inverse[key] = null
		var prev: Variant = snap[key]
		if prev == null:
			_tiles.erase(key)
		else:
			_tiles[key] = (prev as PackedFloat32Array).duplicate()
		_dirty[key] = true
	return inverse


# ---------------------------------------------------------------------------
# Meshing / footing
# ---------------------------------------------------------------------------

## World-XZ AABB a tile covers (its corner samples span [origin, origin+span]).
func tile_world_rect(key: Vector2i) -> Rect2:
	var span := float(tile_cells) * cell_m
	var ox := float(key.x * tile_cells) * cell_m
	var oz := float(key.y * tile_cells) * cell_m
	return Rect2(ox, oz, span, span)


## True when the edit layer has a non-trivial delta anywhere in the tile — used
## to drop tiles that were allocated but then fully undone back to flat.
func tile_has_edits(key: Vector2i, eps: float = 1e-4) -> bool:
	if not _tiles.has(key):
		return false
	var arr: PackedFloat32Array = _tiles[key]
	for v in arr:
		if absf(v) > eps:
			return true
	return false


## Lowest delta in a tile (0 when absent) — how deep its deepest cut goes.
func tile_min_delta(key: Vector2i) -> float:
	if not _tiles.has(key):
		return 0.0
	var arr: PackedFloat32Array = _tiles[key]
	var min_d := 0.0
	for v in arr:
		min_d = minf(min_d, v)
	return min_d


## Drop tiles whose deltas are all ~0 (keeps them dirty so their mesh is removed).
func prune_flat_tiles(eps: float = 1e-4) -> void:
	for key in _tiles.keys():
		if not tile_has_edits(key, eps):
			_tiles.erase(key)
			_dirty[key] = true


## Build ArrayMesh surface arrays for one tile, in TERRAIN-LOCAL space (world XZ,
## Y = AMSL − center_elev). `height_fn` is Callable(x, z) -> AMSL metres of the
## COMPOSED BASE surface (detail DEM etc.) WITHOUT this edit layer; the tile adds
## its own delta on top. `uv_scale`/`uv_origin` map world XZ → detail-drape UV so
## the patch samples the same aerial imagery as the surrounding ground.
func build_tile_arrays(key: Vector2i, height_fn: Callable, center_elev: float,
		uv_scale: float, uv_origin: float) -> Array:
	var e := _samples_per_edge()
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	verts.resize(e * e)
	uvs.resize(e * e)
	normals.resize(e * e)
	var gi0 := key.x * tile_cells
	var gj0 := key.y * tile_cells
	for lj in e:
		var gj := gj0 + lj
		var z := float(gj) * cell_m
		for li in e:
			var gi := gi0 + li
			var x := float(gi) * cell_m
			var h := _surface_height(x, z, height_fn)
			var idx := lj * e + li
			verts[idx] = Vector3(x, h - center_elev, z)
			uvs[idx] = Vector2(x * uv_scale + uv_origin, z * uv_scale + uv_origin)
	# Normals from the composed surface (base + delta) via central differences —
	# seamless across tile edges because it samples the shared height function.
	for lj in e:
		var gj2 := gj0 + lj
		var z2 := float(gj2) * cell_m
		for li in e:
			var gi2 := gi0 + li
			var x2 := float(gi2) * cell_m
			var hl := _surface_height(x2 - cell_m, z2, height_fn)
			var hr := _surface_height(x2 + cell_m, z2, height_fn)
			var hd := _surface_height(x2, z2 - cell_m, height_fn)
			var hu := _surface_height(x2, z2 + cell_m, height_fn)
			var n := Vector3(hl - hr, 2.0 * cell_m, hd - hu).normalized()
			normals[lj * e + li] = n
	var indices := PackedInt32Array()
	indices.resize((e - 1) * (e - 1) * 6)
	var ii := 0
	for r in e - 1:
		for c in e - 1:
			var i := r * e + c
			indices[ii] = i
			indices[ii + 1] = i + 1
			indices[ii + 2] = i + e
			indices[ii + 3] = i + 1
			indices[ii + 4] = i + e + 1
			indices[ii + 5] = i + e
			ii += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## HeightMapShape3D map_data for one tile (row-major, AMSL − center_elev). The
## owning CollisionShape3D is scaled by cell_m and positioned at the tile centre.
func build_tile_heightmap(key: Vector2i, height_fn: Callable,
		center_elev: float) -> PackedFloat32Array:
	var e := _samples_per_edge()
	var data := PackedFloat32Array()
	data.resize(e * e)
	var gi0 := key.x * tile_cells
	var gj0 := key.y * tile_cells
	for lj in e:
		var z := float(gj0 + lj) * cell_m
		for li in e:
			var x := float(gi0 + li) * cell_m
			data[lj * e + li] = _surface_height(x, z, height_fn) - center_elev
	return data


func _surface_height(x: float, z: float, height_fn: Callable) -> float:
	return float(height_fn.call(x, z)) + sample_delta(x, z)


## Mesh arrays AND collider heightmap for one tile from ONE pass over the
## surface: an (e+2)² height grid (one-sample border for the normals) instead of
## the five `height_fn` calls per vertex `build_tile_arrays` + `build_tile_heightmap`
## make between them. Same output, ~5x fewer base-height evaluations — what keeps
## a hundred carved channel tiles from stalling a load.
## Returns { "arrays": Array, "heightmap": PackedFloat32Array }.
## `base_cache` (optional): this tile's base heights from an earlier build
## (the result's "base"). The base surface does not move when only the deltas
## do (a channel re-carve, a brush stroke), so it is reused — after checking
## five probe samples against height_fn, so a new DEM still rebuilds it.
func build_tile_mesh_data(key: Vector2i, height_fn: Callable, center_elev: float,
		uv_scale: float, uv_origin: float,
		base_cache: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var e := _samples_per_edge()
	var g := e + 2
	var gi0 := key.x * tile_cells
	var gj0 := key.y * tile_cells
	var base := base_cache
	if base.size() == g * g:
		for pr in [Vector2i(0, 0), Vector2i(g - 1, 0), Vector2i(0, g - 1), Vector2i(g - 1, g - 1),
				Vector2i(g / 2, g / 2)]:
			var pv: Vector2i = pr
			var want := float(height_fn.call(float(gi0 + pv.x - 1) * cell_m, float(gj0 + pv.y - 1) * cell_m))
			if absf(want - base[pv.y * g + pv.x]) > 1e-4:
				base = PackedFloat32Array()
				break
	if base.size() != g * g:
		base = PackedFloat32Array()
		base.resize(g * g)
		for bj in g:
			var z := float(gj0 + bj - 1) * cell_m
			for bi in g:
				base[bj * g + bi] = float(height_fn.call(float(gi0 + bi - 1) * cell_m, z))
	# The deltas at the samples themselves: x / cell_m is the exact sample
	# index there, so sample_delta's bilinear blend IS that one sample — read
	# it straight from this tile's array (the 1-sample ring from the neighbours).
	var own: PackedFloat32Array = _tiles.get(key, PackedFloat32Array())
	var has_own := own.size() == e * e
	var h := PackedFloat32Array()
	h.resize(g * g)
	for bj in g:
		for bi in g:
			var d := 0.0
			if has_own and bi >= 1 and bi <= e and bj >= 1 and bj <= e:
				d = own[(bj - 1) * e + (bi - 1)]
			else:
				d = get_delta_sample(gi0 + bi - 1, gj0 + bj - 1)
			h[bj * g + bi] = base[bj * g + bi] + d
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var hm := PackedFloat32Array()
	verts.resize(e * e)
	uvs.resize(e * e)
	normals.resize(e * e)
	hm.resize(e * e)
	for lj in e:
		var z2 := float(gj0 + lj) * cell_m
		for li in e:
			var x2 := float(gi0 + li) * cell_m
			var b := (lj + 1) * g + (li + 1)
			var hy := h[b] - center_elev
			var idx := lj * e + li
			verts[idx] = Vector3(x2, hy, z2)
			hm[idx] = hy
			uvs[idx] = Vector2(x2 * uv_scale + uv_origin, z2 * uv_scale + uv_origin)
			normals[idx] = Vector3(h[b - 1] - h[b + 1], 2.0 * cell_m, h[b - g] - h[b + g]).normalized()
	# Each quad splits along the diagonal whose two corners are CLOSEST in
	# height, so a crease (a carved channel, a road cut, a ridge) that runs
	# diagonally across the grid follows quad diagonals instead of zig-zagging
	# through them — the fixed split drew every diagonal channel as a sawtooth.
	var indices := PackedInt32Array()
	indices.resize((e - 1) * (e - 1) * 6)
	var ii := 0
	for r in e - 1:
		for c in e - 1:
			var i := r * e + c
			var b00 := (r + 1) * g + (c + 1)
			var d_main := absf(h[b00] - h[b00 + g + 1])     # i ↔ i+e+1
			var d_anti := absf(h[b00 + 1] - h[b00 + g])     # i+1 ↔ i+e
			if d_main < d_anti:
				indices[ii] = i
				indices[ii + 1] = i + 1
				indices[ii + 2] = i + e + 1
				indices[ii + 3] = i
				indices[ii + 4] = i + e + 1
				indices[ii + 5] = i + e
			else:
				indices[ii] = i
				indices[ii + 1] = i + 1
				indices[ii + 2] = i + e
				indices[ii + 3] = i + 1
				indices[ii + 4] = i + e + 1
				indices[ii + 5] = i + e
			ii += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	return {"arrays": arrays, "heightmap": hm, "base": base}


# ---------------------------------------------------------------------------
# Layer composition (the delta STACK: procedural channels + player sculpt)
# ---------------------------------------------------------------------------

## A deep copy (tiles only — no dirty set, no undo session) for a worker
## thread to sample while the main thread keeps editing the original.
func clone() -> TerrainEditTiles:
	var t := TerrainEditTiles.new()
	t.cell_m = cell_m
	t.tile_cells = tile_cells
	for k in _tiles.keys():
		t._tiles[k] = (_tiles[k] as PackedFloat32Array).duplicate()
	return t


func has_tile(key: Vector2i) -> bool:
	return _tiles.has(key)


## The raw corner-delta array of a tile (empty when absent). Read-only use.
func tile_data(key: Vector2i) -> PackedFloat32Array:
	return _tiles.get(key, PackedFloat32Array())


## Replace one tile's whole delta array (dirty-marked; an all-zero or empty
## array removes the tile). Used by the channel carver to install a tile it
## rasterised off the main thread.
func set_tile_data(key: Vector2i, arr: PackedFloat32Array, eps: float = 1e-4) -> void:
	_snapshot_tile(key)
	var keep := false
	if arr.size() == _tile_array_size():
		for v in arr:
			if absf(v) > eps:
				keep = true
				break
	if keep:
		_tiles[key] = arr
	else:
		_tiles.erase(key)
	_dirty[key] = true


## Recompute `keys` of THIS store as the per-sample SUM of `layers` (each a
## TerrainEditTiles on the same grid). A key every layer lacks (or that sums to
## ~0) is removed. Every recomputed key is marked dirty, so a HeightField bound
## to this store re-meshes exactly what changed. Layers must share cell_m /
## tile_cells with this store.
func compose_from(layers: Array, keys: Array, eps: float = 1e-4) -> void:
	var n := _tile_array_size()
	for key_v in keys:
		var key: Vector2i = key_v
		var sum := PackedFloat32Array()
		var any := false
		for layer_v in layers:
			var layer := layer_v as TerrainEditTiles
			if layer == null or not layer._tiles.has(key):
				continue
			var src: PackedFloat32Array = layer._tiles[key]
			if not any:
				sum = src.duplicate()
				any = true
			else:
				for i in n:
					sum[i] += src[i]
		if any:
			set_tile_data(key, sum, eps)
		elif _tiles.has(key):
			_tiles.erase(key)
			_dirty[key] = true
		else:
			_dirty[key] = true


# ---------------------------------------------------------------------------
# Persistence (binary — replaces the 65k-float JSON array format)
# ---------------------------------------------------------------------------

func to_bytes() -> PackedByteArray:
	var tiles_out := {}
	for key in _tiles.keys():
		var k: Vector2i = key
		tiles_out["%d,%d" % [k.x, k.y]] = _tiles[key]
	return var_to_bytes({
		"version": SAVE_VERSION,
		"cell_m": cell_m,
		"tile_cells": tile_cells,
		"tiles": tiles_out,
	})


func from_bytes(bytes: PackedByteArray) -> bool:
	if bytes.is_empty():
		return false
	var parsed: Variant = bytes_to_var(bytes)
	if not (parsed is Dictionary):
		return false
	var d: Dictionary = parsed
	cell_m = float(d.get("cell_m", CELL_M))
	tile_cells = int(d.get("tile_cells", TILE_CELLS))
	_tiles.clear()
	_dirty.clear()
	var want := _tile_array_size()
	var tiles_in: Variant = d.get("tiles", {})
	if tiles_in is Dictionary:
		for k in (tiles_in as Dictionary).keys():
			var parts := str(k).split(",")
			if parts.size() != 2:
				continue
			var arr_v: Variant = (tiles_in as Dictionary)[k]
			if not (arr_v is PackedFloat32Array):
				continue
			var arr: PackedFloat32Array = arr_v
			if arr.size() != want:
				continue
			var key := Vector2i(int(parts[0]), int(parts[1]))
			_tiles[key] = arr
			_dirty[key] = true
	return true


func save_to_file(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(to_bytes())


func load_from_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	return from_bytes(f.get_buffer(f.get_length()))


# ---------------------------------------------------------------------------
# Migration — bake legacy edits into the tile layer
# ---------------------------------------------------------------------------

## Import a legacy detail_delta grid (res × res over `extent_m`, centred at world
## origin) by resampling it onto the tile grid. Values are ADDED to existing
## deltas so migration can run over baked earthworks.
func bake_delta_grid(delta: PackedFloat32Array, res: int, extent_m: float,
		eps: float = 1e-4) -> void:
	if delta.is_empty() or res < 2:
		return
	var half := extent_m * 0.5
	var bounds := sample_bounds_for_aabb(
		Rect2(-half, -half, extent_m, extent_m), 0)
	for gj in range(bounds.y, bounds.w + 1):
		var z := float(gj) * cell_m
		for gi in range(bounds.x, bounds.z + 1):
			var x := float(gi) * cell_m
			var d := _bilinear_grid(delta, res, extent_m, x, z)
			if absf(d) > eps:
				add_delta_sample(gi, gj, d)


## Import an arbitrary surface delta by sampling `delta_fn(x, z) -> float` (metres
## to add) over a world AABB. Used to bake earthwork berms/cuts into the layer.
func bake_delta_fn(aabb: Rect2, delta_fn: Callable, eps: float = 1e-4) -> void:
	var bounds := sample_bounds_for_aabb(aabb, 1)
	for gj in range(bounds.y, bounds.w + 1):
		var z := float(gj) * cell_m
		for gi in range(bounds.x, bounds.z + 1):
			var x := float(gi) * cell_m
			var d := float(delta_fn.call(x, z))
			if is_finite(d) and absf(d) > eps:
				add_delta_sample(gi, gj, d)


func _bilinear_grid(grid: PackedFloat32Array, res: int, extent_m: float,
		x: float, z: float) -> float:
	var half := extent_m * 0.5
	var u := clampf((x + half) / extent_m, 0.0, 1.0) * float(res - 1)
	var v := clampf((z + half) / extent_m, 0.0, 1.0) * float(res - 1)
	var c0 := int(floor(u))
	var r0 := int(floor(v))
	var c1 := mini(c0 + 1, res - 1)
	var r1 := mini(r0 + 1, res - 1)
	var tx := u - float(c0)
	var tz := v - float(r0)
	var d00 := grid[r0 * res + c0]
	var d10 := grid[r0 * res + c1]
	var d01 := grid[r1 * res + c0]
	var d11 := grid[r1 * res + c1]
	return lerpf(lerpf(d00, d10, tx), lerpf(d01, d11, tx), tz)
