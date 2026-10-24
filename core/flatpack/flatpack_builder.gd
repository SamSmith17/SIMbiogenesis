class_name FlatpackBuilder
extends RefCounted

## The 3D model of a flat-pack design: every part a slab extruded from its
## finished outline (slots, dogbones, arches and mortises all visible), faces
## in plywood and edges showing their plies. Built from FlatpackDesign, so the
## model, the cut files and the cut list cannot disagree.
##
## Node contract (the PalletRack / Bed pattern): ONE MeshInstance3D "Mesh"
## under the root, so PlacedProp's trimesh collision and pick AABB just work.
## The root's origin is the centre of the footprint at floor level; the
## furniture's front faces local +Z.
##
## opts:
##   pose        which pose to build (default: the design's)
##   explode     0..1, parts pushed apart from the middle (the modal)
##   assembly    0..1, parts appear in build order and drop into place
##   highlight   a part id drawn in the highlight colour
##   record      keep per-part triangles as meta "part_tris" for picking

const MODEL_ID := "flatpack_furniture"
const IN := 0.0254
const PLY_COLOR := Color(0.80, 0.66, 0.42)
const HIGHLIGHT_COLOR := Color(1.0, 0.72, 0.25)
const TESS := 0.2
const EXPLODE_IN := 14.0
const DROP_IN := 18.0

## Build order: frame first, then what sits on it.
const ROLE_ORDER := ["rail", "leg", "side", "arm", "stretcher", "wedge", "deck", "top", "seat",
	"brace", "back"]

static var _edge_shader: Shader = null


static func build_node(spec: Dictionary = {}, node_name: String = "FlatpackFurniture",
		opts: Dictionary = {}) -> Node3D:
	var design := FlatpackDesign.solve(spec)
	return build_from_design(design, node_name, opts)


static func build_from_design(design: Dictionary, node_name: String = "FlatpackFurniture",
		opts: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("flatpack_spec", FlatpackSpec.to_json_safe(design["spec"]))
	var pose := str(opts.get("pose", design.get("pose", "")))
	var explode := clampf(float(opts.get("explode", 0.0)), 0.0, 1.0)
	var assembly := clampf(float(opts.get("assembly", 1.0)), 0.0, 1.0)
	var highlight := str(opts.get("highlight", ""))
	var record := bool(opts.get("record", false))
	var box := FlatpackDesign.assembled_aabb(design, pose)
	var centre := box.get_center()
	var offset := Vector3(-centre.x, 0.0, -centre.z)   # inches; floor stays at y = 0

	var faces := SurfaceTool.new()
	faces.begin(Mesh.PRIMITIVE_TRIANGLES)
	var edges := SurfaceTool.new()
	edges.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hl := SurfaceTool.new()
	hl.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any_face := false
	var any_hl := false
	var tris := {}
	var entries := build_order(FlatpackDesign.parts_in_pose(design, pose))
	var n := entries.size()
	for k in n:
		var e: Dictionary = entries[k]
		var p: Dictionary = e["part"]
		if bool(p.get("hidden", false)):
			continue
		# Assembly scrub: part k shows once the scrub passes k / n and drops
		# the last DROP_IN inches into place.
		var shown := assembly * float(n) - float(k)
		if shown <= 0.0:
			continue
		var fr: Transform3D = e["frame"]
		var lift := Vector3.ZERO
		if shown < 1.0:
			lift = Vector3(0, DROP_IN * (1.0 - shown), 0)
		if explode > 0.0:
			var pc := fr * _ring_centre(p)
			var dir := pc - centre
			dir.y = maxf(dir.y, 0.0) * 0.5
			if dir.length() < 0.01:
				dir = Vector3.UP
			lift += dir.normalized() * EXPLODE_IN * explode
		var xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * IN), (offset + lift) * IN) * fr
		var target := hl if str(p["id"]) == highlight else faces
		var tri := PackedVector3Array()
		_emit_slab(p, xf, target, edges if str(p["id"]) != highlight else hl, tri)
		if target == hl:
			any_hl = true
		else:
			any_face = true
		if record:
			tris[str(p["id"])] = tri

	var mesh := ArrayMesh.new()
	if any_face:
		faces.generate_tangents()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, faces.commit_to_arrays())
		mesh.surface_set_material(mesh.get_surface_count() - 1, face_material())
		var ea := edges.commit_to_arrays()
		if ea[Mesh.ARRAY_VERTEX] != null and (ea[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ea)
			mesh.surface_set_material(mesh.get_surface_count() - 1, edge_material(design))
	if any_hl:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, hl.commit_to_arrays())
		mesh.surface_set_material(mesh.get_surface_count() - 1, highlight_material())
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	if record:
		root.set_meta("part_tris", tris)
	root.set_meta("seat_spots", seat_spots(design, pose, offset))
	root.set_meta("size_m", box.size * IN)
	return root


## Parts in the order they are put together.
static func build_order(entries: Array) -> Array:
	var out := entries.duplicate()
	out.sort_custom(func(a, b):
		var ra := ROLE_ORDER.find(str(a["part"].get("role", "")))
		var rb := ROLE_ORDER.find(str(b["part"].get("role", "")))
		if ra < 0:
			ra = ROLE_ORDER.size()
		if rb < 0:
			rb = ROLE_ORDER.size()
		if ra != rb:
			return ra < rb
		return str(a["part"]["id"]) < str(b["part"]["id"]))
	return out


static func _ring_centre(p: Dictionary) -> Vector3:
	var bb: Rect2 = p["bbox"]
	var c := bb.get_center()
	return Vector3(c.x, c.y, 0.0)


## Where people sit / lie, in the root's frame (metres): [{pos, yaw, kind,
## length_m}]. yaw turns -Z (Godot's forward) to the direction faced.
static func seat_spots(design: Dictionary, pose: String, offset_in: Vector3) -> Array:
	var out: Array = []
	for st in FlatpackDesign.seats_in_pose(design, pose):
		var pos: Vector3 = (st["pos"] as Vector3) + offset_in
		var face: Vector3 = st.get("face", Vector3(0, 0, 1))
		out.append({"pos": pos * IN, "yaw": atan2(-face.x, -face.z), "kind": str(st.get("kind", "sit")),
			"length_m": float(st.get("length", 0.0)) * IN})
	return out


# ---------------------------------------------------------------------------
# Slabs
# ---------------------------------------------------------------------------

static func _emit_slab(p: Dictionary, xf: Transform3D, faces: SurfaceTool, edges: SurfaceTool,
		tri_out: PackedVector3Array) -> void:
	var t := float(p.get("thickness", 0.5))
	var outer := FlatpackProfile.tessellate(p["ring"], TESS)
	if outer.size() < 3:
		return
	if not FlatpackProfile.is_ccw(outer):
		outer.reverse()
	var holes: Array = []
	for h in p.get("hole_rings", []):
		var hp := FlatpackProfile.tessellate(h, TESS)
		if hp.size() < 3:
			continue
		if FlatpackProfile.is_ccw(hp):
			hp.reverse()
		holes.append(hp)
	var merged := bridge_holes(outer, holes)
	var idx := Geometry2D.triangulate_polygon(merged)
	if idx.is_empty():
		merged = outer
		idx = Geometry2D.triangulate_polygon(outer)
	var nrm := xf.basis.z.normalized()
	var top_z := t * 0.5
	var bot_z := -t * 0.5
	for i in range(0, idx.size(), 3):
		var a := merged[idx[i]]
		var b := merged[idx[i + 1]]
		var c := merged[idx[i + 2]]
		# Top: viewed from +z the triangle is CCW; Godot's front faces wind
		# clockwise, so reverse it. Bottom keeps the order.
		_tri(faces, xf, [Vector3(a.x, a.y, top_z), Vector3(c.x, c.y, top_z), Vector3(b.x, b.y, top_z)],
			nrm, tri_out)
		_tri(faces, xf, [Vector3(a.x, a.y, bot_z), Vector3(b.x, b.y, bot_z), Vector3(c.x, c.y, bot_z)],
			-nrm, tri_out)
	_walls(outer, xf, t, edges, tri_out)
	for hp in holes:
		_walls(hp, xf, t, edges, tri_out)


static func _tri(st: SurfaceTool, xf: Transform3D, v: Array, n: Vector3, tri_out: PackedVector3Array) -> void:
	for p in v:
		var w: Vector3 = xf * (p as Vector3)
		st.set_normal(n)
		st.set_uv(Vector2(w.x, w.z) * 4.0)
		st.add_vertex(w)
		tri_out.append(w)


## Side walls of a closed ring (material on the left of travel). UV.x runs
## along the edge in inches, UV.y across the thickness.
static func _walls(ring: PackedVector2Array, xf: Transform3D, t: float, st: SurfaceTool,
		tri_out: PackedVector3Array) -> void:
	var n := ring.size()
	var run := 0.0
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		var d := b - a
		var L := d.length()
		if L < 1e-6:
			continue
		var out2 := Vector2(d.y, -d.x) / L
		var nrm := (xf.basis * Vector3(out2.x, out2.y, 0.0)).normalized()
		var at := Vector3(a.x, a.y, t * 0.5)
		var bt := Vector3(b.x, b.y, t * 0.5)
		var ab := Vector3(a.x, a.y, -t * 0.5)
		var bb := Vector3(b.x, b.y, -t * 0.5)
		var u0 := run
		var u1 := run + L
		run = u1
		for q in [[at, u0, 1.0], [bt, u1, 1.0], [bb, u1, 0.0], [at, u0, 1.0], [bb, u1, 0.0], [ab, u0, 0.0]]:
			var w: Vector3 = xf * (q[0] as Vector3)
			st.set_normal(nrm)
			st.set_uv(Vector2(float(q[1]), float(q[2])))
			st.add_vertex(w)
			tri_out.append(w)


## Join each hole into the outer ring with a zero-width cut ("keyhole") so a
## plain polygon triangulator can mesh a part with mortises. The bridge runs
## from the hole's rightmost point to the nearest outer vertex it can see.
static func bridge_holes(outer: PackedVector2Array, holes: Array) -> PackedVector2Array:
	var ring := outer.duplicate()
	var sorted_holes := holes.duplicate()
	sorted_holes.sort_custom(func(a, b): return _max_x(a) > _max_x(b))
	for h in sorted_holes:
		var hole: PackedVector2Array = h
		var hi := 0
		for i in hole.size():
			if hole[i].x > hole[hi].x:
				hi = i
		var hp := hole[hi]
		var best := -1
		var best_d := INF
		for i in ring.size():
			var d := ring[i].distance_squared_to(hp)
			if d >= best_d:
				continue
			if _segment_clear(hp, ring[i], ring, sorted_holes):
				best_d = d
				best = i
		if best < 0:
			continue
		var merged := PackedVector2Array()
		for i in range(0, best + 1):
			merged.append(ring[i])
		for k in hole.size() + 1:
			merged.append(hole[(hi + k) % hole.size()])
		merged.append(ring[best])
		for i in range(best + 1, ring.size()):
			merged.append(ring[i])
		ring = merged
	return ring


static func _max_x(poly: PackedVector2Array) -> float:
	var m := -INF
	for p in poly:
		m = maxf(m, p.x)
	return m


static func _segment_clear(a: Vector2, b: Vector2, ring: PackedVector2Array, holes: Array) -> bool:
	for poly in [ring] + holes:
		var pts: PackedVector2Array = poly
		var n := pts.size()
		for i in n:
			var c := pts[i]
			var d := pts[(i + 1) % n]
			if c.is_equal_approx(a) or c.is_equal_approx(b) or d.is_equal_approx(a) or d.is_equal_approx(b):
				continue
			if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
				return false
	return true


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

static func face_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.PLYWOOD, PLY_COLOR)


static func edge_material(design: Dictionary) -> ShaderMaterial:
	if _edge_shader == null:
		_edge_shader = load("res://core/flatpack/flatpack_ply_edge.gdshader") as Shader
	var m := ShaderMaterial.new()
	m.shader = _edge_shader
	m.set_shader_parameter("face_color", PLY_COLOR)
	var t := float((design.get("bom", {}) as Dictionary).get("thickness", 0.5))
	# Roughly one ply per 3/32" (5-ply 1/2", 7-ply 3/4"; Baltic birch more).
	m.set_shader_parameter("plies", clampi(int(round(t / 0.094)), 3, 13) | 1)
	return m


static func highlight_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = HIGHLIGHT_COLOR
	m.emission_enabled = true
	m.emission = HIGHLIGHT_COLOR * 0.35
	m.roughness = 0.7
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ---------------------------------------------------------------------------
# Picking (the modal's studio)
# ---------------------------------------------------------------------------

## The part whose triangles a ray (in the node's local frame) hits first.
static func pick_part(node: Node3D, origin: Vector3, dir: Vector3) -> String:
	var tris: Dictionary = node.get_meta("part_tris", {})
	var best := ""
	var best_t := INF
	for id in tris:
		var arr: PackedVector3Array = tris[id]
		for i in range(0, arr.size() - 2, 3):
			var hit: Variant = Geometry3D.ray_intersects_triangle(origin, dir, arr[i], arr[i + 1], arr[i + 2])
			if hit == null:
				continue
			var d := origin.distance_to(hit as Vector3)
			if d < best_t:
				best_t = d
				best = str(id)
	return best
