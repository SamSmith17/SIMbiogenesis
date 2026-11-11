class_name EarthworksRuntime
extends Node3D

## Keeps the terrain shaped round every placed structure that asks for it
## (record key `earthworks`, StructureEarthworks). A TerrainLoader child
## ("Earthworks"); it owns no data of its own: everything is re-derived from
## the prop records, so moving, turning or deleting a structure moves or
## restores its earthworks, and nothing is saved besides the records.
##
## What it maintains:
##   * the loader's STRUCTURE tile layer (berms, cuts, ramps, the hidden
##     interior pushed down) — a third layer beside the player's sculpting
##     and the stream channels, never in player undo;
##   * the hole list the loader's ground query reads (floor inside a hole)
##     and the water sampler reads (roof inside a hole);
##   * the hole mask on the terrain material (TerrainHoleMask);
##   * per hole: an edge collar collider following the real ground outside
##     the wall (the heightfield collider is sunk a cell beyond the wall,
##     which is coarser than the drawn cut), and when asked, a floor slab and
##     retaining walls for a model that has none of its own.
##
## It polls the records (4 Hz, a signature over the few that carry
## earthworks) instead of hooking the half-dozen paths a prop can move by.

const POLL_S := 0.25
## The lift on padding tiles round a structure (m; above the tile store's
## 1e-4 "flat" threshold, far below anything visible).
const PAD_LIFT_M := 0.0015
const COLLAR_OUT_M := 2.4
const COLLAR_STEP_M := 0.4
const SLAB_T_M := 0.2
const WALL_T_M := 0.18
const WALL_BELOW_M := 0.3
## Nav obstacles for the people (NpcBuildingNav's shape): every opening is a
## walled room, its door where the daylight side meets the entry ramp (the
## middle of that side without one). An opening with no daylight side has no
## way in for people.
func nav_entries() -> Array:
	var out: Array = []
	for pl in _placements:
		var hole: Dictionary = pl.get("hole", {})
		if hole.is_empty():
			continue
		var doors := PackedVector2Array()
		var d: Variant = door_point(pl)
		if d is Vector2:
			doors.append(d)
		var e := {"poly": hole["poly"], "doors": doors, "door_radius_m": NpcBuildingNav.DOOR_RADIUS_M,
			"band_m": NpcBuildingNav.WALL_BAND_M,
			"flags": NpcNavGrid.F_BLOCKED | NpcNavGrid.F_WALL | NpcNavGrid.F_STRUCTURE,
			"interior_flags": NpcNavGrid.F_INTERIOR | NpcNavGrid.F_STRUCTURE}
		if doors.is_empty():
			e.erase("band_m")
			e.erase("interior_flags")
			e["flags"] = NpcNavGrid.F_BLOCKED | NpcNavGrid.F_STRUCTURE
		out.append(e)
	return out


## Where people walk in (world XZ), or null: on the daylight side's wall line,
## at the entry ramp (`ramp_at`) or the side's middle.
static func door_point(pl: Dictionary) -> Variant:
	var spec: Dictionary = pl.get("spec", {})
	var sm: Dictionary = spec.get("simple", {}) if spec.get("simple", null) is Dictionary else {}
	var side := str(sm.get("daylight", ""))
	if not StructureEarthworks.SIDES.has(side):
		return null
	var r: Array = spec["rect"]
	var c := Vector2((float(r[0]) + float(r[2])) * 0.5, (float(r[1]) + float(r[3])) * 0.5)
	var half := Vector2((float(r[2]) - float(r[0])) * 0.5, (float(r[3]) - float(r[1])) * 0.5)
	var o: Vector2 = StructureEarthworks.OUTWARD[side]
	var p := c + Vector2(o.x * half.x, o.y * half.y)
	var at_v: Variant = sm.get("ramp_at", null)
	if at_v is float or at_v is int:
		if absf(o.y) > 0.5:
			p.x = float(at_v)
		else:
			p.y = float(at_v)
	return StructureEarthworks.to_world(p, pl["origin"], float(pl["yaw"]))


## Ceiling lights in a sunken space (the world's own ambient may be ~0, and a
## room under the ground gets no sky): a warm grid, no shadows, faded far off.
const LIGHT_SPACING_M := 5.0
const LIGHT_MAX := 8
const LIGHT_HANG_M := 2.0
const LIGHT_RANGE_M := 6.5
const LIGHT_ENERGY := 0.9
const LIGHT_MIN_DEPTH_M := 0.8

var loader: Node = null

var _poll := 0.0
var _sig := ""
## Bumped by the loader when player sculpting or a channel re-carve lands on
## a tile a structure covers (the structure's targets are absolute, so its
## deltas must be measured again against the new ground).
var ground_rev := 0
var _placements: Array = []
var holes: Array = []
var _keys: Dictionary = {}          ## structure-layer tile keys currently set
var _mask: Dictionary = {"count": 0}
var _hole_sigs: Dictionary = {}     ## hole id -> polygon signature (veg clears)
var rebuild_count := 0
## Bumped when the structure layer's content changes: the loader's sink
## signature folds it in, so the DetailGround re-sinks round a new opening.
var sink_rev := 0
var last_rebuild_ms := 0.0


func _ready() -> void:
	name = "Earthworks"


func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = POLL_S
	if loader == null or not bool(loader.get("_built")):
		return
	var s := signature()
	if s != _sig:
		rebuild()


## The records that carry earthworks, as one string: a change in any of them
## (or in the ground under them) is a rebuild.
func signature() -> String:
	var layer: PlacedPropLayer = loader.get("_placed_prop_layer")
	if layer == null:
		return "none|%d" % ground_rev
	var parts := PackedStringArray([str(ground_rev)])
	for item in layer.props:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		if bool(d.get("packed", false)):
			continue
		var es := StructureEarthworks.spec_for_record(d)
		if es.is_empty():
			continue
		parts.append("%s|%.3f|%.3f|%.2f|%.3f|%s" % [str(d.get("id", "")),
			float(d.get("x", 0.0)), float(d.get("z", 0.0)), float(d.get("yaw", 0.0)),
			float(d.get("y_offset", 0.0)), JSON.stringify(es)])
	return ";".join(parts)


func placements() -> Array:
	return _placements


## Tile keys a structure covers (the loader re-measures when the ground there
## changes under it).
func covers_tile(key: Vector2i) -> bool:
	return _keys.has(key)


func rebuild() -> void:
	var t0 := Time.get_ticks_usec()
	_sig = signature()
	var layer: PlacedPropLayer = loader.get("_placed_prop_layer")
	var surf := Callable(loader, "ground_without_structures")
	_placements = []
	if layer != null:
		for item in layer.props:
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			if not StructureEarthworks.is_on(d) or bool(d.get("packed", false)):
				continue
			var grade := float(surf.call(float(d.get("x", 0.0)), float(d.get("z", 0.0))))
			_placements.append(StructureEarthworks.placement(d, grade))
	var store: TerrainEditTiles = loader.call("structure_tile_layer")
	var deltas := StructureEarthworks.solve(_placements, surf, store.cell_m)
	var t_solve := Time.get_ticks_usec()
	var fresh := TerrainEditTiles.new()
	fresh.cell_m = store.cell_m
	fresh.tile_cells = store.tile_cells
	for k in deltas.keys():
		var key: Vector2i = k
		fresh.set_delta_sample(key.x, key.y, float(deltas[k]))
	# Pad every tile the structures touch with its eight neighbours (a 1.5 mm
	# lift, invisible): the DetailGround is only sunk under tiles whose
	# neighbours are tiles too, and its coarse collider would otherwise chord
	# straight across a pit or a sunken room near a tile edge.
	var real_keys := fresh.active_tiles()
	var have := {}
	for k in real_keys:
		have[k] = true
	var pad := PackedFloat32Array()
	pad.resize((store.tile_cells + 1) * (store.tile_cells + 1))
	pad.fill(PAD_LIFT_M)
	for k in real_keys:
		var kk: Vector2i = k
		for oz in [-1, 0, 1]:
			for ox in [-1, 0, 1]:
				var nk := kk + Vector2i(ox, oz)
				if not have.has(nk):
					have[nk] = true
					fresh.set_tile_data(nk, pad.duplicate())
	var new_keys := {}
	for k in fresh.active_tiles():
		new_keys[k] = true
	var touched: Array = []
	var union := _keys.duplicate()
	for k in new_keys.keys():
		union[k] = true
	for k in union.keys():
		var key2: Vector2i = k
		var now_arr := fresh.tile_data(key2)
		var was := store.tile_data(key2)
		if now_arr == was:
			continue
		store.set_tile_data(key2, now_arr)
		touched.append(key2)
	_keys = new_keys
	holes = StructureEarthworks.holes_of(_placements)
	StructureEarthworks.index_holes(holes)
	var t_tiles := Time.get_ticks_usec()
	_mask = TerrainHoleMask.build(holes)
	push_mask()
	var t_mask := Time.get_ticks_usec()
	if not touched.is_empty():
		sink_rev += 1
		loader.call("commit_structure_tiles", touched)
	var t_commit := Time.get_ticks_usec()
	_rebuild_nodes()
	var t_nodes := Time.get_ticks_usec()
	_clear_vegetation_in_new_holes()
	if OS.is_debug_build() and (Time.get_ticks_usec() - t0) > 250000:
		print("earthworks rebuild slow: solve %.0f, tiles %.0f, mask %.0f, commit %.0f, nodes %.0f, veg %.0f ms (%d samples)" % [
		(t_solve - t0) / 1000.0, (t_tiles - t_solve) / 1000.0, (t_mask - t_tiles) / 1000.0,
		(t_commit - t_mask) / 1000.0, (t_nodes - t_commit) / 1000.0,
		(Time.get_ticks_usec() - t_nodes) / 1000.0, deltas.size()])
	rebuild_count += 1
	last_rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0


## Re-push the mask onto the terrain materials (a drape swap replaces them).
func push_mask() -> void:
	var main: Node = loader.get("_main")
	if main == null:
		return
	var terrain := main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	for nm in ["Ground", "DetailGround"]:
		var mi := terrain.get_node_or_null(nm) as MeshInstance3D
		if mi != null:
			TerrainHoleMask.push(mi.material_override as ShaderMaterial, _mask)


func mask_count() -> int:
	return int(_mask.get("count", 0))


## True when this terrain material carries the current mask (the loader's
## tick checks after imagery swaps the drape).
func mask_current_on(sm: ShaderMaterial) -> bool:
	if sm == null:
		return true
	var v: Variant = sm.get_shader_parameter("hole_count")
	return v != null and int(v) == mask_count()


# ---------------------------------------------------------------------------
# Collars, slabs, walls
# ---------------------------------------------------------------------------

func _rebuild_nodes() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var surf := Callable(loader, "surface_height_at")
	for h in holes:
		var poly: PackedVector2Array = h["poly"]
		var id := str(h.get("id", ""))
		var body := StaticBody3D.new()
		body.name = "Collar_%s" % id
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(collar_faces(poly, surf))
		cs.shape = shape
		body.add_child(cs)
		add_child(body)
		if bool(h.get("slab", false)):
			_add_slab(poly, float(h["floor"]), id)
		if bool(h.get("lights", true)):
			_add_lights(h, id)
		if bool(h.get("walls", false)):
			var sides: Array = h.get("wall_sides", [])
			var only: Array = []
			if bool(h.get("rect_edges", false)) and not sides.is_empty():
				for i in 4:
					only.append(sides.has(StructureEarthworks.RECT_EDGE_SIDES[i]))
			_add_walls(poly, float(h["floor"]), surf, id, only)


## Where an opening's ceiling lights hang (world XZ + Y): a grid every
## LIGHT_SPACING_M inside the footprint, at most LIGHT_MAX, under the ceiling.
## None for an opening whose floor is barely below grade (daylight reaches it).
static func light_points(h: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	var poly: PackedVector2Array = h.get("poly", PackedVector2Array())
	var fl := float(h.get("floor", 0.0))
	var grade := float(h.get("grade", fl))
	if poly.size() < 3 or grade - fl < LIGHT_MIN_DEPTH_M:
		return out
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	var y := fl + minf(LIGHT_HANG_M, maxf(0.6, float(h.get("roof", fl + 2.5)) - fl - 0.3))
	var nx := maxi(1, roundi(r.size.x / LIGHT_SPACING_M))
	var nz := maxi(1, roundi(r.size.y / LIGHT_SPACING_M))
	for iz in nz:
		for ix in nx:
			var p := r.position + Vector2((ix + 0.5) * r.size.x / nx, (iz + 0.5) * r.size.y / nz)
			if Geometry2D.is_point_in_polygon(p, poly):
				out.append(Vector3(p.x, y, p.y))
	# Too many for one opening: keep an even spread.
	if out.size() > LIGHT_MAX:
		var keep := PackedVector3Array()
		for k in LIGHT_MAX:
			keep.append(out[int(float(k) * out.size() / LIGHT_MAX)])
		out = keep
	return out


func _add_lights(h: Dictionary, id: String) -> void:
	var pts := light_points(h)
	for i in pts.size():
		var l := OmniLight3D.new()
		l.name = "Light_%s_%d" % [id, i]
		l.position = pts[i]
		l.light_color = Color(1.0, 0.86, 0.68)
		l.light_energy = LIGHT_ENERGY
		l.omni_range = LIGHT_RANGE_M
		l.omni_attenuation = 1.2
		l.shadow_enabled = false
		l.light_indirect_energy = 0.3
		l.distance_fade_enabled = true
		l.distance_fade_begin = 45.0
		l.distance_fade_length = 15.0
		add_child(l)


## The unit normal of edge a→b pointing out of the polygon.
static func outward(poly: PackedVector2Array, a: Vector2, b: Vector2) -> Vector2:
	return StructureEarthworks.outward(poly, a, b)


## A strip of triangles along each wall, from the wall line out COLLAR_OUT_M,
## on the drawn ground: what you stand on beside the building, where the
## heightfield collider has been pulled down with the opening.
static func collar_faces(poly: PackedVector2Array, surf: Callable) -> PackedVector3Array:
	var faces := PackedVector3Array()
	var n := poly.size()
	if n < 3:
		return faces
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var dir := (b - a)
		var elen := dir.length()
		if elen < 0.05:
			continue
		dir /= elen
		var out := outward(poly, a, b)
		var along := maxi(1, ceili((elen + 2.0 * COLLAR_OUT_M) / COLLAR_STEP_M))
		var across := maxi(1, ceili(COLLAR_OUT_M / COLLAR_STEP_M))
		var start := a - dir * COLLAR_OUT_M
		var step_a := (elen + 2.0 * COLLAR_OUT_M) / float(along)
		var step_o := COLLAR_OUT_M / float(across)
		var grid: Array = []
		for r in across + 1:
			var row := PackedVector3Array()
			for c in along + 1:
				var p := start + dir * (float(c) * step_a) + out * (float(r) * step_o)
				row.append(Vector3(p.x, float(surf.call(p.x, p.y)) + 0.02, p.y))
			grid.append(row)
		for r in across:
			for c in along:
				var p00: Vector3 = grid[r][c]
				var p10: Vector3 = grid[r][c + 1]
				var p01: Vector3 = grid[r + 1][c]
				var p11: Vector3 = grid[r + 1][c + 1]
				faces.append_array([p00, p10, p11, p00, p11, p01])
	return faces


func _concrete() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.62, 0.6, 0.56)
	m.roughness = 0.9
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _add_slab(poly: PackedVector2Array, floor_y: float, id: String) -> void:
	var idx := Geometry2D.triangulate_polygon(poly)
	if idx.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := PackedVector3Array()
	for k in range(0, idx.size(), 3):
		var tri := [poly[idx[k]], poly[idx[k + 1]], poly[idx[k + 2]]]
		for p in tri:
			var v := Vector3(p.x, floor_y, p.y)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(p.x, p.y) * 0.5)
			st.add_vertex(v)
			faces.append(v)
	var mi := MeshInstance3D.new()
	mi.name = "Slab_%s" % id
	mi.mesh = st.commit()
	mi.material_override = _concrete()
	add_child(mi)
	var body := StaticBody3D.new()
	body.name = "SlabBody_%s" % id
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


## Retaining walls round a hole, from under the floor up to the ground at the
## wall line (for a model with none of its own: a pit, a buried container).
func _add_walls(poly: PackedVector2Array, floor_y: float, surf: Callable, id: String,
		only: Array = []) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := PackedVector3Array()
	var n := poly.size()
	for i in n:
		if not only.is_empty() and not bool(only[i]):
			continue
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var elen := a.distance_to(b)
		if elen < 0.05:
			continue
		var dir := (b - a) / elen
		var inward := -outward(poly, a, b)
		var steps := maxi(1, ceili(elen / 0.5))
		for s in steps:
			var p0 := a + dir * (elen * float(s) / float(steps))
			var p1 := a + dir * (elen * float(s + 1) / float(steps))
			var t0 := float(surf.call(p0.x, p0.y)) + 0.05
			var t1 := float(surf.call(p1.x, p1.y)) + 0.05
			var bot := floor_y - WALL_BELOW_M
			for face: float in [0.0, WALL_T_M]:
				var o: Vector2 = inward * face
				var q0: Vector2 = p0 + o
				var q1: Vector2 = p1 + o
				var v := [Vector3(q0.x, bot, q0.y), Vector3(q1.x, bot, q1.y),
					Vector3(q1.x, t1, q1.y), Vector3(q0.x, t0, q0.y)]
				var nrm := Vector3(inward.x, 0.0, inward.y) * (1.0 if face > 0.0 else -1.0)
				for tri in [[0, 1, 2], [0, 2, 3]]:
					for k in tri:
						st.set_normal(nrm)
						st.add_vertex(v[k])
						faces.append(v[k])
			# Cap along the top.
			var c0 := Vector3(p0.x, t0, p0.y)
			var c1 := Vector3(p1.x, t1, p1.y)
			var c2 := Vector3(p1.x + inward.x * WALL_T_M, t1, p1.y + inward.y * WALL_T_M)
			var c3 := Vector3(p0.x + inward.x * WALL_T_M, t0, p0.y + inward.y * WALL_T_M)
			for v2 in [c0, c1, c2, c0, c2, c3]:
				st.set_normal(Vector3.UP)
				st.add_vertex(v2)
	var mi := MeshInstance3D.new()
	mi.name = "Walls_%s" % id
	mi.mesh = st.commit()
	mi.material_override = _concrete()
	add_child(mi)
	var body := StaticBody3D.new()
	body.name = "WallsBody_%s" % id
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


## Digging a building out removes the plants that stood in its footprint
## (the auto-vegetation clear is a saved patch, so the next scatter keeps out
## too; moving the building leaves the clearing, as digging one would).
func _clear_vegetation_in_new_holes() -> void:
	var seen := {}
	for h in holes:
		var id := str(h.get("id", ""))
		var poly: PackedVector2Array = h["poly"]
		var sig := str(hash(var_to_str(poly)))
		seen[id] = sig
		if str(_hole_sigs.get(id, "")) == sig:
			continue
		if loader.has_method("clear_auto_vegetation_in_polygon"):
			loader.call("clear_auto_vegetation_in_polygon", poly)
		if loader.has_method("count_manual_bulk_in_polygon") \
				and int(loader.call("count_manual_bulk_in_polygon", poly)) > 0 \
				and loader.has_method("clear_vegetation_in_polygon"):
			loader.call("clear_vegetation_in_polygon", poly)
	_hole_sigs = seen


## Debug line for probes.
func debug_line() -> String:
	return "earthworks: %d structures, %d holes, %d tiles, %d rebuilds (last %.1f ms)" % [
		_placements.size(), holes.size(), _keys.size(), rebuild_count, last_rebuild_ms]
