class_name ForkliftBuilder
extends RefCounted

## A 2.5 t electric counterbalance forklift, drawn procedurally in metres.
## Origin on the ground under the middle of the drive axle's span; the forks
## point toward -Z (the rider's forward, PlacedVehicle profile "forklift").
##
## Node tree (ForkliftRig drives the moving parts by name):
##   Forklift (Node3D)
##     Mesh        chassis, counterweight, wheels, seat, overhead guard
##     Mast        the outer uprights; tilts about X at the front axle
##       Carriage  rides up the mast (position.y = lift height)
##         Forks   the two tines + backrest; a pallet sits at Forks/Load

const MODEL_ID := "vehicle_forklift"

## Published numbers for a typical 2.5 t (5000 lb) class IV/V truck.
const LENGTH_M := 3.6          # overall, tines included
const BODY_LENGTH_M := 2.5     # to the face of the forks
const WIDTH_M := 1.15
const GUARD_H_M := 2.1
const MAST_H_M := 2.15         # lowered mast
const MAX_LIFT_M := 3.0
const FORK_LEN_M := 1.07       # 42" tines
const FORK_SPREAD_M := 0.70    # outside to outside
const CAPACITY_KG := 2500.0
const FRONT_AXLE_Z := -0.75    # drive axle, under the mast
const MAST_Z := -1.05          # the mast's face

const C_BODY := Color(0.93, 0.62, 0.08)
const C_DARK := Color(0.12, 0.12, 0.13)
const C_STEEL := Color(0.42, 0.43, 0.45)
const C_TYRE := Color(0.07, 0.07, 0.07)


## The player's forklift model (gitignored art). Already in metres (SimLab
## inches under a 0.0254 node); its forks point toward +Z, so it is turned half
## a turn. Its tines + carriage plate + backrest are the "Forks" node, the
## carriage plate's twin is Geom3D5 and the mast channel is Geom3D13.
const GLB_PATH := "res://Imported Models/Vehicles/forklift.glb"
const GLB_FORK_NODES := ["Forks", "Geom3D5"]
const GLB_MAST_NODES := ["Geom3D13"]
const GLB_MAST_PIVOT_Y := 0.32

static var _glb_tip_z := NAN


static func build_node(_spec: Dictionary = {}, node_name: String = "Forklift") -> Node3D:
	if ResourceLoader.exists(GLB_PATH):
		var from_glb := _build_from_glb(node_name)
		if from_glb != null:
			return from_glb
	return _build_procedural(node_name)


static func _build_procedural(node_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = node_name

	var body := IntermodalMeshKit.new()
	var dark := IntermodalMeshKit.new()
	var tyre := IntermodalMeshKit.new()
	var steel := IntermodalMeshKit.new()

	# Chassis + battery compartment.
	body.box(Vector3(0, 0.55, 0.15), Vector3(WIDTH_M, 0.7, 1.8))
	# Counterweight at the back, rounded with a cylinder.
	body.box(Vector3(0, 0.75, 1.05), Vector3(WIDTH_M, 1.1, 0.45))
	body.cylinder(Vector3(0, 0.2, 1.22), 0.3, 1.1, Vector3.UP, 16)
	# Front cowl.
	body.box(Vector3(0, 0.45, -0.72), Vector3(WIDTH_M * 0.9, 0.5, 0.3))
	# Seat, steering column and wheel.
	dark.box(Vector3(0, 1.0, 0.45), Vector3(0.5, 0.12, 0.45))
	dark.box(Vector3(0, 1.3, 0.68), Vector3(0.5, 0.5, 0.1))
	dark.obox(Vector3(0, 1.15, -0.35), Vector3(0.04, 0, 0), Vector3(0, 0.3, 0.12), Vector3(0, -0.05, 0.04))
	dark.cylinder(Vector3(0, 1.38, -0.28), 0.17, 0.04, Vector3(0, 0.6, 0.8).normalized(), 16)
	# Overhead guard: four posts and a slatted roof.
	for sx in [-1.0, 1.0]:
		var x: float = sx * (WIDTH_M * 0.5 - 0.05)
		dark.box(Vector3(x, 1.5, -0.55), Vector3(0.06, 1.2, 0.06))
		dark.box(Vector3(x, 1.5, 0.85), Vector3(0.06, 1.2, 0.06))
	for i in 5:
		dark.box(Vector3(0, GUARD_H_M - 0.02, -0.55 + i * 0.35), Vector3(WIDTH_M - 0.04, 0.04, 0.06))
	dark.box(Vector3(-(WIDTH_M * 0.5 - 0.05), GUARD_H_M - 0.02, 0.15), Vector3(0.06, 0.04, 1.46))
	dark.box(Vector3(WIDTH_M * 0.5 - 0.05, GUARD_H_M - 0.02, 0.15), Vector3(0.06, 0.04, 1.46))
	# Wheels: big drive tyres up front, smaller steer tyres at the back.
	for sx in [-1.0, 1.0]:
		tyre.cylinder(Vector3(sx * (WIDTH_M * 0.5 - 0.12), 0.32, FRONT_AXLE_Z), 0.32, 0.24, Vector3.RIGHT, 20)
		tyre.cylinder(Vector3(sx * (WIDTH_M * 0.5 - 0.14), 0.24, 0.8), 0.24, 0.2, Vector3.RIGHT, 18)

	var mesh := ArrayMesh.new()
	body.commit(mesh, C_BODY, 0.1, 0.55)
	dark.commit(mesh, C_DARK, 0.2, 0.6)
	tyre.commit(mesh, C_TYRE, 0.0, 0.95)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)

	# Mast: pivots at the front axle height, its uprights just ahead of it.
	var mast := Node3D.new()
	mast.name = "Mast"
	mast.position = Vector3(0, 0.32, MAST_Z)
	root.add_child(mast)
	for sx in [-1.0, 1.0]:
		steel.box(Vector3(sx * 0.33, MAST_H_M * 0.5, 0), Vector3(0.08, MAST_H_M, 0.12))
	steel.box(Vector3(0, MAST_H_M - 0.05, 0), Vector3(0.74, 0.08, 0.1))
	steel.box(Vector3(0, 0.15, 0), Vector3(0.74, 0.08, 0.1))
	var mm := ArrayMesh.new()
	steel.commit(mm, C_STEEL, 0.6, 0.45)
	var mast_mi := MeshInstance3D.new()
	mast_mi.name = "MastMesh"
	mast_mi.mesh = mm
	mast.add_child(mast_mi)

	# Carriage: its origin is the top of the tines; position.y = lift above the ground.
	var carriage := Node3D.new()
	carriage.name = "Carriage"
	carriage.position = Vector3(0, -0.32 + 0.05, -0.1)
	carriage.set_meta("rest_y", carriage.position.y)
	mast.add_child(carriage)
	var ck := IntermodalMeshKit.new()
	ck.box(Vector3(0, 0.25, 0.03), Vector3(0.9, 0.42, 0.06))
	for i in 5:
		ck.box(Vector3(-0.4 + i * 0.2, 0.75, 0.03), Vector3(0.04, 0.6, 0.04))
	ck.box(Vector3(0, 1.05, 0.03), Vector3(0.9, 0.05, 0.05))
	var cm := ArrayMesh.new()
	ck.commit(cm, C_DARK, 0.3, 0.5)
	var c_mi := MeshInstance3D.new()
	c_mi.name = "CarriageMesh"
	c_mi.mesh = cm
	carriage.add_child(c_mi)

	var forks := Node3D.new()
	forks.name = "Forks"
	carriage.add_child(forks)
	var fk := IntermodalMeshKit.new()
	for sx in [-1.0, 1.0]:
		var x: float = sx * (FORK_SPREAD_M * 0.5 - 0.05)
		fk.box(Vector3(x, -0.025, -FORK_LEN_M * 0.5), Vector3(0.1, 0.05, FORK_LEN_M))
		fk.box(Vector3(x, 0.25, 0.0), Vector3(0.1, 0.5, 0.05))
	var fm := ArrayMesh.new()
	fk.commit(fm, C_STEEL, 0.7, 0.4)
	var f_mi := MeshInstance3D.new()
	f_mi.name = "ForksMesh"
	f_mi.mesh = fm
	forks.add_child(f_mi)
	# Where a carried load's base centre sits.
	var load_node := Node3D.new()
	load_node.name = "Load"
	load_node.position = Vector3(0, 0.0, -FORK_LEN_M * 0.5)
	forks.add_child(load_node)
	return root


## The forks' tips in the forklift's own frame at a given lift (metres above the
## ground) — used by the planner to place the truck so the tines reach a load.
static func fork_reach_z() -> float:
	if is_nan(_glb_tip_z) and ResourceLoader.exists(GLB_PATH):
		var probe := _build_from_glb("Probe")
		if probe != null:
			probe.free()
	if not is_nan(_glb_tip_z):
		return _glb_tip_z
	return MAST_Z - 0.1 - FORK_LEN_M


## The GLB rebuilt into the tree ForkliftRig drives: the model under "Body"
## (turned so the forks face -Z), the mast channel under "Mast", and the forks,
## carriage plate and backrest under "Carriage" with "Load" at the tines'
## middle. Every moved node keeps where it was drawn. Null if the file does not
## hold the expected parts (the caller falls back to the procedural truck).
static func _build_from_glb(node_name: String) -> Node3D:
	var packed := load(GLB_PATH) as PackedScene
	if packed == null:
		return null
	var model := packed.instantiate() as Node3D
	if model == null:
		return null
	var root := Node3D.new()
	root.name = node_name
	var body := Node3D.new()
	body.name = "Body"
	body.rotation.y = PI
	root.add_child(body)
	body.add_child(model)

	var forks: Array[Node3D] = []
	for n in GLB_FORK_NODES:
		var f := model.find_child(n, true, false) as Node3D
		if f != null:
			forks.append(f)
	if forks.is_empty():
		root.free()
		return null
	var mast_parts: Array[Node3D] = []
	for n in GLB_MAST_NODES:
		var m := model.find_child(n, true, false) as Node3D
		if m != null:
			mast_parts.append(m)

	# Measure the forks in the root frame: the carriage face is their highest
	# z, the tips their lowest; a tine's top is the highest point of the blades
	# (everything more than 0.3 m out from the carriage face).
	var pts := PackedVector3Array()
	for f in forks:
		_collect_points(f, root, pts)
	if pts.is_empty():
		root.free()
		return null
	var face_z := -INF
	var tip_z := INF
	for p in pts:
		face_z = maxf(face_z, p.z)
		tip_z = minf(tip_z, p.z)
	var tine_top := -INF
	for p in pts:
		if p.z < face_z - 0.3:
			tine_top = maxf(tine_top, p.y)
	if not is_finite(tine_top):
		tine_top = 0.05
	_glb_tip_z = tip_z

	var mast_z := face_z + 0.05
	if not mast_parts.is_empty():
		var mpts := PackedVector3Array()
		for m in mast_parts:
			_collect_points(m, root, mpts)
		if not mpts.is_empty():
			var lo := INF
			var hi := -INF
			for p in mpts:
				lo = minf(lo, p.z)
				hi = maxf(hi, p.z)
			mast_z = (lo + hi) * 0.5

	var mast := Node3D.new()
	mast.name = "Mast"
	mast.position = Vector3(0, GLB_MAST_PIVOT_Y, mast_z)
	root.add_child(mast)
	var carriage := Node3D.new()
	carriage.name = "Carriage"
	carriage.position = Vector3(0, tine_top - GLB_MAST_PIVOT_Y, face_z - mast_z)
	carriage.set_meta("rest_y", carriage.position.y)
	mast.add_child(carriage)
	var carriage_xf := mast.transform * carriage.transform
	for m in mast_parts:
		_reparent_keep(m, mast, mast.transform, root)
	for f in forks:
		_reparent_keep(f, carriage, carriage_xf, root)
	var load_node := Node3D.new()
	load_node.name = "Load"
	load_node.position = Vector3(0, 0, (tip_z - face_z) * 0.5)
	carriage.add_child(load_node)
	return root


## `node`'s transform relative to `ancestor` (works outside the scene tree).
static func _rel(node: Node, ancestor: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n := node
	while n != null and n != ancestor:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


static func _reparent_keep(node: Node3D, new_parent: Node3D, parent_rel: Transform3D, root: Node) -> void:
	var was := _rel(node, root)
	_clear_owners(node)
	node.get_parent().remove_child(node)
	new_parent.add_child(node)
	node.transform = parent_rel.affine_inverse() * was


static func _clear_owners(node: Node) -> void:
	node.owner = null
	for c in node.get_children():
		_clear_owners(c)


static func _collect_points(node: Node, root: Node, out: PackedVector3Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mi := node as MeshInstance3D
		var xf := _rel(mi, root)
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for v in verts:
				out.append(xf * v)
	for c in node.get_children():
		_collect_points(c, root, out)


static func packed_spec() -> Dictionary:
	return {"w_m": LENGTH_M, "d_m": WIDTH_M, "h_m": GUARD_H_M, "mass_kg": 4100.0,
		"form": "folded", "this_side_up": true, "stackable": false}
