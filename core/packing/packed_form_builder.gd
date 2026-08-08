class_name PackedFormBuilder
extends RefCounted
## The PACKED world form of a prop — PACKING_PLAN.md Phase 5. When a placed
## prop's record carries `packed: true`, PlacedPropRuntime builds this
## instead of the deployed model: a crate/bundle/tank silhouette sized from
## the prop's honest PackedSpec, floor at local Y = 0.
##
## Built from Godot primitive meshes (BoxMesh/CylinderMesh) on purpose —
## auto-generated normals and winding, no hand-rolled triangle traps
## (see CargoContainerBuilder's clockwise-winding gotcha).

const WOOD := Color(0.62, 0.50, 0.34)
const WOOD_DARK := Color(0.45, 0.35, 0.23)
const BUNDLE := Color(0.50, 0.44, 0.36)
const STRAP := Color(0.20, 0.22, 0.25)
const PANEL_DARK := Color(0.13, 0.18, 0.30)
const TANK := Color(0.72, 0.74, 0.76)


## spec: a normalized PackedSpec dict. Returns a Node3D whose child "Mesh"
## carries the geometry (PlacedProp.setup_collision consumes MeshInstance3D
## geometry, same contract as every procedural builder).
static func build_node(spec: Dictionary, node_name: String = "PackedForm") -> Node3D:
	var w := maxf(float(spec.get("w_m", 0.5)), 0.05)
	var d := maxf(float(spec.get("d_m", 0.5)), 0.05)
	var h := maxf(float(spec.get("h_m", 0.5)), 0.05)
	var form := str(spec.get("form", "crate"))
	var root := Node3D.new()
	root.name = node_name
	var mesh_root := Node3D.new()
	mesh_root.name = "Mesh"
	root.add_child(mesh_root)
	match form:
		"tank":
			_add_cylinder(mesh_root, w * 0.5, h, TANK)
		"bundle", "roll", "folded":
			_add_box(mesh_root, Vector3(w, h, d), BUNDLE)
			_add_straps(mesh_root, w, d, h, 3)
		"panel_stack":
			_add_box(mesh_root, Vector3(w, h, d), PANEL_DARK)
			_add_straps(mesh_root, w, d, h, 2)
		"pallet":
			# Load block on a thin pallet base.
			var base_h := minf(0.145, h * 0.4)
			_add_box(mesh_root, Vector3(w, base_h, d), WOOD_DARK)
			var load := _add_box(mesh_root, Vector3(w * 0.96, h - base_h, d * 0.96), BUNDLE)
			load.position.y = base_h + (h - base_h) * 0.5
		_:
			# crate / container / loose — plank-toned box with edge battens.
			_add_box(mesh_root, Vector3(w, h, d), WOOD)
			_add_straps(mesh_root, w, d, h, 2, WOOD_DARK)
	return root


static func _material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.85
	return m


static func _add_box(parent: Node3D, size: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _material(col)
	mi.position = Vector3(0.0, size.y * 0.5, 0.0)
	parent.add_child(mi)
	return mi


static func _add_cylinder(parent: Node3D, radius: float, height: float, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 24
	mi.mesh = cm
	mi.material_override = _material(col)
	mi.position = Vector3(0.0, height * 0.5, 0.0)
	parent.add_child(mi)


## N slightly-proud strap rings across the long (X) axis.
static func _add_straps(parent: Node3D, w: float, d: float, h: float,
		count: int, col: Color = STRAP) -> void:
	var proud := 0.012
	for i in count:
		var x := -w * 0.5 + w * (float(i) + 0.75) / (float(count) + 0.5)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(minf(0.05, w * 0.1), h + proud, d + proud)
		mi.mesh = bm
		mi.material_override = _material(col)
		mi.position = Vector3(x, (h + proud) * 0.5 - proud * 0.5, 0.0)
		parent.add_child(mi)
