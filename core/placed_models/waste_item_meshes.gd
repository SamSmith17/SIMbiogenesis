class_name WasteItemMeshes
extends RefCounted
## Low-poly meshes of the common packaging waste items — bottles, cans,
## jars, cartons, boxes, wads (plans/FOOD_WASTE_REALISM_PLAN.md Phase 8).
## One cached ArrayMesh per PackagingArchetypes `mesh_id`, built ONCE from
## Godot primitives composited with SurfaceTool.append_from (correct
## winding by construction — no hand-wound triangles), each with its own
## material. The waste bins' MultiMeshes draw thousands of them.
##
## Items are CENTRED on the origin (they tumble in a bin, so there is no
## canonical "up"); `half_h(id)` is the half-extent the pile layout lifts
## an item by. Sizes are real-world metres (a 355 ml can is 66 x 122 mm).

static var _meshes: Dictionary = {}


static func ids() -> Array:
	var seen: Dictionary = {}
	for aid in PackagingArchetypes.ids():
		seen[PackagingArchetypes.mesh_id(aid)] = true
	var out := seen.keys()
	out.sort()
	return out


static func mesh(mesh_id: String) -> ArrayMesh:
	if _meshes.has(mesh_id):
		return _meshes[mesh_id]
	var m := _build(mesh_id)
	_meshes[mesh_id] = m
	return m


## The vertical half-extent the layout stacks by (the item's smallest
## half-dimension: a tumbled item lies on its side).
static func half_h(mesh_id: String) -> float:
	match mesh_id:
		"pet_bottle": return 0.033
		"pet_bottle_large": return 0.043
		"hdpe_jug": return 0.075
		"hdpe_bottle": return 0.036
		"alu_can": return 0.033
		"steel_can": return 0.038
		"steel_can_large": return 0.050
		"glass_jar": return 0.038
		"glass_bottle": return 0.036
		"carton": return 0.036
		"card_flat": return 0.015
		"card_box": return 0.100
		"paper_wad": return 0.055
		"film_wad": return 0.040
		"plastic_tub": return 0.040
	return 0.04


static func _build(mesh_id: String) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match mesh_id:
		"pet_bottle":
			_cyl(st, 0.033, 0.033, 0.15, Vector3(0, -0.015, 0))
			_cyl(st, 0.013, 0.028, 0.045, Vector3(0, 0.0825, 0))
			_cyl(st, 0.014, 0.014, 0.02, Vector3(0, 0.105, 0))
		"pet_bottle_large":
			_cyl(st, 0.043, 0.043, 0.22, Vector3(0, -0.025, 0))
			_cyl(st, 0.014, 0.038, 0.06, Vector3(0, 0.115, 0))
			_cyl(st, 0.015, 0.015, 0.022, Vector3(0, 0.151, 0))
		"hdpe_jug":
			_box(st, Vector3(0.15, 0.2, 0.15), Vector3(0, -0.02, 0))
			_cyl(st, 0.02, 0.02, 0.03, Vector3(0, 0.095, 0))
		"hdpe_bottle":
			_cyl(st, 0.036, 0.036, 0.13, Vector3(0, -0.015, 0))
			_cyl(st, 0.016, 0.016, 0.035, Vector3(0, 0.0725, 0))
		"alu_can":
			_cyl(st, 0.033, 0.033, 0.115, Vector3.ZERO)
			_cyl(st, 0.027, 0.033, 0.007, Vector3(0, 0.061, 0))
		"steel_can":
			_cyl(st, 0.0375, 0.0375, 0.11, Vector3.ZERO)
		"steel_can_large":
			_cyl(st, 0.05, 0.05, 0.115, Vector3.ZERO)
		"glass_jar":
			_cyl(st, 0.038, 0.038, 0.1, Vector3(0, -0.01, 0))
			_cyl(st, 0.033, 0.033, 0.02, Vector3(0, 0.05, 0))
		"glass_bottle":
			_cyl(st, 0.036, 0.036, 0.17, Vector3(0, -0.045, 0))
			_cyl(st, 0.012, 0.032, 0.06, Vector3(0, 0.07, 0))
			_cyl(st, 0.013, 0.013, 0.03, Vector3(0, 0.115, 0))
		"carton":
			_box(st, Vector3(0.072, 0.2, 0.072), Vector3(0, -0.005, 0))
			_box(st, Vector3(0.072, 0.012, 0.03), Vector3(0, 0.1, 0))
		"card_flat":
			_box(st, Vector3(0.3, 0.03, 0.2), Vector3.ZERO)
		"card_box":
			_box(st, Vector3(0.34, 0.2, 0.24), Vector3.ZERO)
		"paper_wad":
			_ball(st, 0.055, Vector3.ZERO, Vector3(1.0, 0.85, 0.95))
		"film_wad":
			_ball(st, 0.055, Vector3.ZERO, Vector3(1.0, 0.65, 0.85))
		"plastic_tub":
			_cyl(st, 0.055, 0.045, 0.08, Vector3.ZERO)
		_:
			_box(st, Vector3(0.08, 0.08, 0.08), Vector3.ZERO)
	# append_from copies the primitives' OWN normals — generate_normals()
	# here would smooth-merge by position (the DomeLab "bubble" trap).
	var m := st.commit()
	m.surface_set_material(0, _material(mesh_id))
	return m


static func _cyl(st: SurfaceTool, r_top: float, r_bot: float, h: float, at: Vector3) -> void:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = 10
	c.rings = 1
	st.append_from(c, 0, Transform3D(Basis.IDENTITY, at))


static func _box(st: SurfaceTool, size: Vector3, at: Vector3) -> void:
	var b := BoxMesh.new()
	b.size = size
	st.append_from(b, 0, Transform3D(Basis.IDENTITY, at))


static func _ball(st: SurfaceTool, r: float, at: Vector3, squash: Vector3) -> void:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 8
	s.rings = 5
	st.append_from(s, 0, Transform3D(Basis.IDENTITY.scaled(squash), at))


static func _material(mesh_id: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.roughness = 0.6
	match mesh_id:
		"pet_bottle", "pet_bottle_large":
			m.albedo_color = Color(0.62, 0.78, 0.86)
			m.roughness = 0.25
		"hdpe_jug", "hdpe_bottle":
			m.albedo_color = Color(0.92, 0.92, 0.9)
		"alu_can":
			m.albedo_color = Color(0.78, 0.8, 0.84)
			m.metallic = 0.9
			m.roughness = 0.3
		"steel_can", "steel_can_large":
			m.albedo_color = Color(0.68, 0.68, 0.7)
			m.metallic = 0.8
			m.roughness = 0.4
		"glass_jar":
			m.albedo_color = Color(0.72, 0.78, 0.68)
			m.roughness = 0.1
		"glass_bottle":
			m.albedo_color = Color(0.25, 0.4, 0.25)
			m.roughness = 0.1
		"carton":
			m.albedo_color = Color(0.88, 0.86, 0.8)
		"card_flat", "card_box":
			m.albedo_color = Color(0.62, 0.48, 0.32)
			m.roughness = 0.9
		"paper_wad":
			m.albedo_color = Color(0.85, 0.83, 0.78)
			m.roughness = 0.9
		"film_wad":
			m.albedo_color = Color(0.6, 0.62, 0.68)
			m.roughness = 0.45
		"plastic_tub":
			m.albedo_color = Color(0.9, 0.88, 0.84)
		_:
			m.albedo_color = Color(0.7, 0.7, 0.7)
	return m
