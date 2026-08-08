class_name CargoContainerBuilder
extends RefCounted
## Procedural ISO shipping-container prop — PACKING_PLAN.md Phase 1. A real
## placeable target volume for the packing gameplay: the Phase 6 "unpack a
## system" scenario opens with one of these standing on the site.
##
## Built as ONE MeshInstance3D ("Mesh") with merged surfaces (PalletRack
## pattern) so PlacedProp.setup_collision / pick-AABB consume it directly:
##   surface 0 — painted shell (corrugation ribs + corner castings),
##   surface 1 — door leaves + lock rods at the +Z end.
## Local origin: ground centre, floor at local Y = 0 (prop convention).
## Dims come from ContainerCatalog (`container_spec.container_id`, default
## the 20' box) — geometry and packing data can never drift apart.

const MODEL_ID := "cargo_container"

const SHELL_COLOR := Color(0.30, 0.36, 0.42)   # weathered marine blue-grey
const DOOR_COLOR := Color(0.24, 0.30, 0.36)
const RIB_SPACING_M := 0.30
const RIB_PROUD_M := 0.025
const RIB_WIDTH_M := 0.10
const CASTING_M := 0.18


static func build_node(spec: Dictionary = {}, node_name: String = "CargoContainer") -> Node3D:
	var container_id := str(spec.get("container_id", "container_20"))
	var entry := ContainerCatalog.find(container_id)
	if entry.is_empty() or not entry.has("exterior"):
		entry = ContainerCatalog.find("container_20")
	var e: Dictionary = entry.get("exterior", {})
	var l := float(e.get("l_m", 6.058))
	var w := float(e.get("w_m", 2.438))
	var h := float(e.get("h_m", 2.591))

	var root := Node3D.new()
	root.name = node_name
	root.set_meta("container_spec", {"container_id": container_id})

	var mesh := ArrayMesh.new()
	_build_shell_surface(mesh, l, w, h)
	_build_door_surface(mesh, l, w, h)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	return root


static func _make_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = 0.25
	m.roughness = 0.72
	return m


## Shell: body box + corrugation ribs on both long walls + 8 corner castings.
static func _build_shell_surface(mesh: ArrayMesh, l: float, w: float, h: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Body (floor at y=0, length along Z, door end at +Z).
	_add_box(st, Vector3(0.0, h * 0.5, 0.0), Vector3(w, h, l))
	# Vertical corrugation ribs (proud strips) along both X walls.
	var rib_h := h - CASTING_M * 2.0
	var z := -l * 0.5 + RIB_SPACING_M
	while z < l * 0.5 - RIB_SPACING_M * 0.5:
		for side in [-1.0, 1.0]:
			_add_box(st,
				Vector3(side * (w * 0.5 + RIB_PROUD_M * 0.5), h * 0.5, z),
				Vector3(RIB_PROUD_M, rib_h, RIB_WIDTH_M))
		z += RIB_SPACING_M
	# Corner castings.
	for sx in [-1.0, 1.0]:
		for sy in [0.0, 1.0]:
			for sz in [-1.0, 1.0]:
				_add_box(st,
					Vector3(sx * (w - CASTING_M) * 0.5,
						CASTING_M * 0.5 + sy * (h - CASTING_M),
						sz * (l - CASTING_M) * 0.5),
					Vector3(CASTING_M, CASTING_M, CASTING_M) * 1.02)
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _make_material(SHELL_COLOR))


## Doors: two leaves proud of the +Z end face, four vertical lock rods.
static func _build_door_surface(mesh: ArrayMesh, l: float, w: float, h: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leaf_w := w * 0.47
	var leaf_h := h - CASTING_M * 1.6
	var leaf_t := 0.05
	var zf := l * 0.5 + leaf_t * 0.5
	for side in [-1.0, 1.0]:
		_add_box(st, Vector3(side * (leaf_w * 0.5 + w * 0.01), h * 0.5, zf),
			Vector3(leaf_w, leaf_h, leaf_t))
		# Two lock rods per leaf.
		for rx in [0.30, 0.75]:
			_add_box(st,
				Vector3(side * leaf_w * rx, h * 0.5, zf + leaf_t * 0.5 + 0.02),
				Vector3(0.04, leaf_h * 0.96, 0.04))
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _make_material(DOOR_COLOR))


static func _add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	# 8 corners.
	var c: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				c.append(center + Vector3(sx * hx, sy * hy, sz * hz))
	# 6 faces as corner-index quads + outward normals. Godot front faces are
	# CLOCKWISE viewed from outside, so triangles emit reversed (0,2,1 / 0,3,2)
	# — the CCW version rendered every wall as a culled backface (the whole
	# box read as an unlit silhouette).
	var faces := [
		[[4, 6, 7, 5], Vector3.RIGHT],    # +X
		[[0, 1, 3, 2], Vector3.LEFT],     # -X
		[[2, 3, 7, 6], Vector3.UP],       # +Y
		[[0, 4, 5, 1], Vector3.DOWN],     # -Y
		[[1, 5, 7, 3], Vector3.BACK],     # +Z
		[[0, 2, 6, 4], Vector3.FORWARD],  # -Z
	]
	for f in faces:
		var idx: Array = f[0]
		st.set_normal(f[1])
		for tri in [[0, 2, 1], [0, 3, 2]]:
			for k in tri:
				st.add_vertex(c[idx[k]])
