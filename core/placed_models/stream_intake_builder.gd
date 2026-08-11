class_name StreamIntakeBuilder
extends RefCounted

## Procedural stream / spring intake — the small screened box a penstock draws
## from. It exists because a conduit has NO free endpoints: every connection
## needs an item at each end that resolves to a 3D anchor, so "drop the pipe
## here to tap this spring" has to mint a real prop + graph node at that spot.
##
## Deliberately small and readable at a glance: a low concrete-ish sump with a
## sloped screen face and a stub outlet collar on +Z (where the penstock
## attaches — see ConnectionPortDefs.default_ports_for_model).
##
## Geometry gotcha inherited from BedBuilder / CargoContainerBuilder: Godot
## front faces wind CLOCKWISE viewed from outside, so _add_box emits reversed
## triangles. A CCW box renders as culled backfaces — an unlit silhouette.

const MODEL_ID := "stream_intake"

## Footprint + heights (metres). Sized like a real small-hydro intake box.
const WIDTH_M := 0.70    # X
const DEPTH_M := 0.50    # Z (outlet collar on +Z)
const BODY_H_M := 0.42
const WALL_M := 0.06
const COLLAR_D_M := 0.12
const COLLAR_LEN_M := 0.14

const BODY_COLOR := Color(0.44, 0.45, 0.43)     # weathered concrete
const SCREEN_COLOR := Color(0.30, 0.34, 0.36)   # dark steel mesh
const COLLAR_COLOR := Color(0.12, 0.12, 0.13)   # black poly fitting


static func build_node(_spec: Dictionary = {}, node_name: String = "StreamIntake") -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var mesh := ArrayMesh.new()
	_build_body_surface(mesh)
	_build_screen_surface(mesh)
	_build_collar_surface(mesh)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	return root


static func footprint_xz() -> Vector2:
	return Vector2(WIDTH_M, DEPTH_M + COLLAR_LEN_M)


## Sump: three walls + a floor, open at the top (water falls in).
static func _build_body_surface(mesh: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx := WIDTH_M * 0.5
	var hz := DEPTH_M * 0.5
	# Floor.
	_add_box(st, Vector3(0.0, WALL_M * 0.5, 0.0),
		Vector3(WIDTH_M, WALL_M, DEPTH_M))
	# Side walls (X faces).
	for sx in [-1.0, 1.0]:
		_add_box(st, Vector3(sx * (hx - WALL_M * 0.5), BODY_H_M * 0.5, 0.0),
			Vector3(WALL_M, BODY_H_M, DEPTH_M))
	# Downstream wall (+Z, carries the outlet collar).
	_add_box(st, Vector3(0.0, BODY_H_M * 0.5, hz - WALL_M * 0.5),
		Vector3(WIDTH_M - WALL_M * 2.0, BODY_H_M, WALL_M))
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1,
		_make_material(BODY_COLOR, 0.92))


## Sloped trash screen across the upstream (−Z) opening.
static func _build_screen_surface(mesh: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hz := DEPTH_M * 0.5
	# A thin slab tilted back over the inlet mouth.
	var slab := Node3D.new()
	slab.position = Vector3(0.0, BODY_H_M * 0.62, -(hz - WALL_M * 0.8))
	slab.rotation = Vector3(deg_to_rad(-32.0), 0.0, 0.0)
	_add_box_xform(st, slab.transform,
		Vector3.ZERO, Vector3(WIDTH_M - WALL_M * 2.0, 0.035, BODY_H_M * 0.95))
	slab.free()
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1,
		_make_material(SCREEN_COLOR, 0.6, 0.35))


## Poly outlet collar on +Z — the penstock's attach point.
static func _build_collar_surface(mesh: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hz := DEPTH_M * 0.5
	_add_box(st,
		Vector3(0.0, BODY_H_M * 0.34, hz + COLLAR_LEN_M * 0.5),
		Vector3(COLLAR_D_M, COLLAR_D_M, COLLAR_LEN_M))
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1,
		_make_material(COLLAR_COLOR, 0.55))


static func _make_material(color: Color, roughness := 0.85,
		metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


static func _add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	_add_box_xform(st, Transform3D.IDENTITY, center, size)


static func _add_box_xform(st: SurfaceTool, xform: Transform3D,
		center: Vector3, size: Vector3) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var c: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				c.append(xform * (center + Vector3(sx * hx, sy * hy, sz * hz)))
	var faces := [
		[[4, 6, 7, 5], Vector3.RIGHT],
		[[0, 1, 3, 2], Vector3.LEFT],
		[[2, 3, 7, 6], Vector3.UP],
		[[0, 4, 5, 1], Vector3.DOWN],
		[[1, 5, 7, 3], Vector3.BACK],
		[[0, 2, 6, 4], Vector3.FORWARD],
	]
	for f in faces:
		var idx: Array = f[0]
		st.set_normal((xform.basis * (f[1] as Vector3)).normalized())
		# Clockwise-from-outside winding (see the header note).
		for tri in [[0, 2, 1], [0, 3, 2]]:
			for k in tri:
				st.add_vertex(c[idx[k]])
