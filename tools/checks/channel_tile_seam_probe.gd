extends RefCounted

## Carved channel tiles vs the DetailGround around them (sandbox, read-only):
##   tools\harness.ps1 -World <id> -RunScript res://tools/checks/channel_tile_seam_probe.gd
## For every tile edge on the boundary of the active tile union, compares the
## tile mesh's own edge vertices against the DetailGround surface that is drawn
## right beside them (its UNSUNK grid, triangulated exactly like build_mesh). A
## gap here is a tile hovering over (or sinking under) the ground at its edge —
## the skirt shows and the tile throws a shadow. Prints the distribution and
## FAILs past SEAM_TOL_M.

const SEAM_TOL_M := 0.10

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("seam-probe %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func run(main: Node, _harness: Node) -> Dictionary:
	var loader: Node = main.get_node_or_null("Terrain/TerrainLoader")
	if loader == null:
		for n in main.get_tree().get_nodes_in_group("terrain_loader"):
			loader = n
	if loader == null:
		loader = main.find_child("TerrainLoader", true, false)
	_ok(loader != null, "TerrainLoader found")
	if loader == null:
		return {"ok": false}
	# Let any pending channel carve land.
	for _i in 240:
		await main.get_tree().process_frame
	var hf: Node3D = main.get_node_or_null("Terrain/HeightField")
	_ok(hf != null, "HeightField exists")
	if hf == null:
		return {"ok": false}
	var tiles: TerrainEditTiles = hf.get("tiles")
	var active := {}
	for key in tiles.active_tiles():
		if tiles.tile_has_edits(key):
			active[key] = true
	print("seam-probe: %d active tiles" % active.size())
	var surf: Dictionary = loader.call("detail_render_surface") if loader.has_method("detail_render_surface") else {}
	var grid: PackedFloat32Array = surf.get("grid", PackedFloat32Array())
	var res: int = int(surf.get("res", 0))
	var ext: float = float(surf.get("extent_m", 0.0))
	var ce: float = float(surf.get("center_elev", 0.0))
	if grid.is_empty():
		# Older build: rebuild the unsunk mesh grid the way _rebuild_detail_patch does.
		var g: PackedFloat32Array = loader.get("_detail_surface_grid")
		var cols: int = int(loader.get("_detail_elev_cols"))
		var rows: int = int(loader.get("_detail_elev_rows"))
		res = cols
		grid = g
		if cols > 256 or rows > 256:
			grid = TerrainBuilder.resample(g, cols, rows, 256)
			res = 256
		ext = float(loader.call("_detail_extent_m"))
		ce = float(loader.get("_built_center_elev"))
	var gaps := PackedFloat32Array()
	var worst := 0.0
	var worst_at := Vector2.ZERO
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for key in active.keys():
		var k: Vector2i = key
		var body := hf.get_node_or_null("T_%d_%d" % [k.x, k.y])
		if body == null:
			continue
		var mi := body.get_node_or_null("Mesh") as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var e := tiles.tile_cells + 1
		for d in dirs:
			var dd: Vector2i = d
			if active.has(k + dd):
				continue
			for t in e:
				var li := 0
				var lj := 0
				if dd.x == 1:
					li = e - 1; lj = t
				elif dd.x == -1:
					li = 0; lj = t
				elif dd.y == 1:
					li = t; lj = e - 1
				else:
					li = t; lj = 0
				var v := verts[lj * e + li]
				var dg := _chord(grid, res, ext, ce, v.x, v.z)
				var gap := v.y - dg
				gaps.append(gap)
				if absf(gap) > absf(worst):
					worst = gap
					worst_at = Vector2(v.x, v.z)
	gaps.sort()
	var n := gaps.size()
	if n > 0:
		print("seam-probe: %d edge vertices  min %.3f  p05 %.3f  median %.3f  p95 %.3f  max %.3f m  worst at (%.0f, %.0f)" % [
			n, gaps[0], gaps[int(n * 0.05)], gaps[n / 2], gaps[int(n * 0.95)], gaps[n - 1],
			worst_at.x, worst_at.y])
	_ok(n > 0, "found union-boundary edge vertices")
	_ok(absf(worst) <= SEAM_TOL_M, "tile edges meet the DetailGround within %.2f m (worst %.3f m)" % [SEAM_TOL_M, worst])
	# DetailGround vertices INSIDE the active tile union must sit under the tiles.
	var dg_mi := main.get_node_or_null("Terrain/DetailGround") as MeshInstance3D
	if dg_mi != null and dg_mi.mesh != null:
		var dv: PackedVector3Array = dg_mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var span := float(tiles.tile_cells) * tiles.cell_m
		var above := 0
		var inside := 0
		var worst_up := -INF
		var worst_up_at := Vector3.ZERO
		for v in dv:
			var k := Vector2i(floori(v.x / span), floori(v.z / span))
			if not active.has(k):
				continue
			inside += 1
			var ty: float = float(loader.call("ground_height_at", v.x, v.z))
			var up := v.y - ty
			if up > worst_up:
				worst_up = up
				worst_up_at = v
			if up > 0.05:
				above += 1
		print("seam-probe: %d DetailGround verts inside the tile union, %d above the tile surface by >5 cm, worst %+.3f m at (%.0f, %.0f)" % [
			inside, above, worst_up, worst_up_at.x, worst_up_at.z])
		_ok(above == 0, "no DetailGround vertex pokes above the tiles")
		# Its normals must be the ground's, not the hidden sink's: a vertex on
		# the tile edge used to lean toward the 60 m drop and shade the strip
		# of ground beside the tiles as a cliff.
		var dn: PackedVector3Array = dg_mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
		var step := ext / float(maxi(res - 1, 1))
		var bad := 0
		var near := 0
		var worst_deg := 0.0
		for i in dv.size():
			var v := dv[i]
			var near_edge := false
			for o in [Vector2(step, 0), Vector2(-step, 0), Vector2(0, step), Vector2(0, -step)]:
				var q: Vector2 = Vector2(v.x, v.z) + o
				if active.has(Vector2i(floori(q.x / span), floori(q.y / span))):
					near_edge = true
			if not near_edge:
				continue
			near += 1
			var hx1 := _chord(grid, res, ext, ce, v.x + step, v.z)
			var hx0 := _chord(grid, res, ext, ce, v.x - step, v.z)
			var hz1 := _chord(grid, res, ext, ce, v.x, v.z + step)
			var hz0 := _chord(grid, res, ext, ce, v.x, v.z - step)
			var want := Vector3(hx0 - hx1, 2.0 * step, hz0 - hz1).normalized()
			var deg := rad_to_deg(dn[i].normalized().angle_to(want))
			worst_deg = maxf(worst_deg, deg)
			if deg > 12.0:
				bad += 1
		print("seam-probe: %d DetailGround verts at/next to the tiles, %d with a normal >12 deg off the ground's, worst %.1f deg" % [near, bad, worst_deg])
		_ok(bad == 0, "DetailGround normals beside the tiles follow the ground, not the sink")
	# Tiles must not cast shadows the ground beside them does not.
	var dg_node := main.get_node_or_null("Terrain/DetailGround") as MeshInstance3D
	var tile_cast := -1
	for c in hf.get_children():
		var m := c.get_node_or_null("Mesh") as MeshInstance3D
		if m != null:
			tile_cast = m.cast_shadow
			break
	if dg_node != null and tile_cast >= 0:
		_ok(tile_cast == dg_node.cast_shadow, "tiles cast shadows like the DetailGround (%d vs %d)" % [tile_cast, dg_node.cast_shadow])
	return {"ok": _fails.is_empty(), "failures": _fails}


## The DetailGround's own surface at (x, z): build_mesh's two triangles per
## cell (i, i+1, i+res) and (i+1, i+res+1, i+res), linear inside each.
static func _chord(grid: PackedFloat32Array, res: int, ext: float, ce: float, x: float, z: float) -> float:
	var half := ext * 0.5
	var cell := ext / float(res - 1)
	var fx := clampf((x + half) / cell, 0.0, float(res - 1) - 0.0001)
	var fz := clampf((z + half) / cell, 0.0, float(res - 1) - 0.0001)
	var c := int(floor(fx))
	var r := int(floor(fz))
	var u := fx - float(c)
	var v := fz - float(r)
	var h00 := grid[r * res + c]
	var h10 := grid[r * res + c + 1]
	var h01 := grid[(r + 1) * res + c]
	var h11 := grid[(r + 1) * res + c + 1]
	var y := 0.0
	if u + v <= 1.0:
		y = h00 + (h10 - h00) * u + (h01 - h00) * v
	else:
		y = h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v)
	return y - ce
