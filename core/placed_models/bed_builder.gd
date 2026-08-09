class_name BedBuilder
extends RefCounted

## Procedural single bed — a wooden frame, mattress, pillow and blanket as ONE
## MeshInstance3D named "Mesh" (the PalletRack/CargoContainer pattern, so
## PlacedProp collision + pick AABB just work).
##
## ORIENTATION CONTRACT (the lying-yaw math depends on this): the bed's LONG
## axis runs along local Z with the HEAD (pillow) at −Z. A sleeper aligned to
## the bed therefore takes the prop's yaw directly — the avatar's lying body
## also extends along its local Z after the lie-down pitch. If a re-model ever
## rotates the mesh, fix the mesh, not the sim's BED_YAW_OFFSET.
##
## Geometry gotcha inherited from CargoContainerBuilder: Godot front faces
## wind CLOCKWISE viewed from outside — _add_box emits reversed triangles.

const MODEL_ID := "bed"

## Footprint + heights (metres). Single bed, slightly generous.
const WIDTH_M := 0.95      # X
const LENGTH_M := 2.05     # Z (long axis; head at -Z)
const FRAME_H_M := 0.32    # top of the side rails
const LEG_M := 0.09        # square leg side
const RAIL_H_M := 0.14     # side rail face height
const MATTRESS_H_M := 0.16
const HEADBOARD_H_M := 0.75

const FRAME_COLOR := Color(0.45, 0.32, 0.20)     # warm wood
const MATTRESS_COLOR := Color(0.92, 0.90, 0.84)  # off-white
const PILLOW_COLOR := Color(0.97, 0.97, 0.95)
const BLANKET_COLOR := Color(0.42, 0.52, 0.64)   # muted blue


static func build_node(_spec: Dictionary = {}, node_name: String = "Bed") -> Node3D:
	var root := Node3D.new()
	root.name = node_name

	var mesh := ArrayMesh.new()
	_build_frame_surface(mesh)
	_build_mattress_surface(mesh)
	_build_pillow_surface(mesh)
	_build_blanket_surface(mesh)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	return root


static func footprint_xz() -> Vector2:
	return Vector2(WIDTH_M, LENGTH_M)


static func _make_material(color: Color, roughness := 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


## Frame: four legs, two side rails, foot rail, and a headboard at -Z.
static func _build_frame_surface(mesh: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx := WIDTH_M * 0.5
	var hz := LENGTH_M * 0.5
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_add_box(st,
				Vector3(sx * (hx - LEG_M * 0.5), FRAME_H_M * 0.5, sz * (hz - LEG_M * 0.5)),
				Vector3(LEG_M, FRAME_H_M, LEG_M))
	# Side rails along Z.
	for sx in [-1.0, 1.0]:
		_add_box(st,
			Vector3(sx * (hx - LEG_M * 0.5), FRAME_H_M - RAIL_H_M * 0.5, 0.0),
			Vector3(LEG_M * 0.8, RAIL_H_M, LENGTH_M - LEG_M * 2.0))
	# Foot rail across X at +Z.
	_add_box(st,
		Vector3(0.0, FRAME_H_M - RAIL_H_M * 0.5, hz - LEG_M * 0.5),
		Vector3(WIDTH_M - LEG_M * 2.0, RAIL_H_M, LEG_M * 0.8))
	# Headboard at -Z (the head end).
	_add_box(st,
		Vector3(0.0, HEADBOARD_H_M * 0.5, -(hz - LEG_M * 0.4)),
		Vector3(WIDTH_M, HEADBOARD_H_M, LEG_M * 0.7))
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _make_material(FRAME_COLOR))


static func _build_mattress_surface(mesh: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_box(st,
		Vector3(0.0, FRAME_H_M + MATTRESS_H_M * 0.5, 0.0),
		Vector3(WIDTH_M - LEG_M, MATTRESS_H_M, LENGTH_M - LEG_M))
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1,
		_make_material(MATTRESS_COLOR, 0.95))


static func _build_pillow_surface(mesh: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hz := LENGTH_M * 0.5
	_add_box(st,
		Vector3(0.0, FRAME_H_M + MATTRESS_H_M + 0.045, -(hz - 0.34)),
		Vector3(WIDTH_M * 0.62, 0.09, 0.42))
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1,
		_make_material(PILLOW_COLOR, 0.98))


## Blanket over the lower two thirds (foot end), a hair proud of the mattress.
static func _build_blanket_surface(mesh: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hz := LENGTH_M * 0.5
	var blanket_len := (LENGTH_M - LEG_M) * 0.62
	_add_box(st,
		Vector3(0.0, FRAME_H_M + MATTRESS_H_M + 0.015, hz - LEG_M * 0.5 - blanket_len * 0.5),
		Vector3(WIDTH_M - LEG_M * 0.4, 0.05, blanket_len))
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1,
		_make_material(BLANKET_COLOR, 0.9))


static func _add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var c: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				c.append(center + Vector3(sx * hx, sy * hy, sz * hz))
	# Front faces are CLOCKWISE viewed from outside — triangles emit reversed
	# (0,2,1 / 0,3,2); the CCW version renders every wall as a culled backface.
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
