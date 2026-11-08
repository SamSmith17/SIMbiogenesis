class_name CargoDoors
extends RefCounted
## The cargo door of a host standing OPEN while a crew unloads it.
##
## Doors are baked into the host's one mesh (CargoContainerBuilder,
## VehicleBuilder._doors), so "open" is an overlay under ModelRoot: a dark
## opening over the closed door face and the leaves where an opened door
## stands — a container's two leaves swung round against its sides, a van's
## barn doors the same, a roll-up's curtain gone into the roof, a lift gate
## raised, a slider pushed back along the body, a hinged / bus door swung out.
## Pure geometry in the host's own frame (the same frame its builder draws
## in); TerrainLoader shows it while the host's unload project is active.

const NODE_NAME := "DoorsOpen"
## A container's leaves open the whole way round (270°), stopped a little off
## the side wall; a van's barn doors open to the same stop.
const LEAF_SWING_DEG := 250.0
const HINGED_SWING_DEG := 100.0
const LIFT_SWING_DEG := 80.0
const LEAF_T := 0.05
const OPENING_COLOR := Color(0.03, 0.03, 0.035)
const VEHICLE_DOOR_COLOR := Color(0.82, 0.82, 0.8)


## Everything the overlay needs, from the record alone: {kind container |
## barn | roll_up | lift | slider | hinged, ...geometry}. {} = no door.
static func plan(rec: Dictionary) -> Dictionary:
	if VehicleCargo.is_container(rec):
		var e := VehicleCargo.container_entry(rec)
		var ext: Dictionary = e.get("exterior", e.get("interior", {}))
		var l := float(ext.get("l_m", 6.058))
		var w := float(ext.get("w_m", 2.438))
		var h := float(ext.get("h_m", 2.591))
		# The opening between the corner posts, from the sill to the header
		# (CargoContainerBuilder's door end), in the box's own paint.
		var ow := w - 2.0 * CargoContainerBuilder.POST_X
		var sill := 0.015 + CargoContainerBuilder.BOTTOM_RAIL_H
		var paint: Variant = (rec.get("container_spec", {}) as Dictionary).get("paint",
			(rec.get("intermodal_spec", {}) as Dictionary).get("params", {}).get("paint",
				CargoContainerBuilder.DEFAULT_PAINT))
		return {"kind": "container", "where": "rear", "z": l * 0.5, "x0": -ow * 0.5,
			"x1": ow * 0.5, "y0": sill, "y1": h - CargoContainerBuilder.CAST.y,
			"color": CargoContainerBuilder.paint_color(paint).darkened(0.1)}
	if not VehicleBuilder.handles(str(rec.get("model_id", ""))):
		return {}
	var d := VehicleDesign.solve(VehicleBuilder.spec_for_record(rec))
	var bay := VehicleCargo.bay(d)
	if bay.is_empty():
		return {}
	var where := str(bay.get("door_where", "rear"))
	var b: Dictionary = d["body"]
	# The bay's door: the rear one, or the widest side one (VehicleCargo.bay).
	var spans: Array = VehicleDesign.door_spans(d).filter(func(sp): return str((sp as Dictionary)["where"]) == where)
	if where == "side":
		spans.sort_custom(func(a, c): return float(a["z1"]) - float(a["z0"]) > float(c["z1"]) - float(c["z0"]) + 1e-4)
	for sp in spans:
		var sd: Dictionary = sp
		if where == "rear":
			return {"kind": str(b.get("rear_door", "barn")), "where": "rear", "z": float(sd["z"]),
				"x0": float(sd["x0"]), "x1": float(sd["x1"]), "y0": float(sd["y0"]),
				"y1": float(sd["y1"]), "color": VEHICLE_DOOR_COLOR}
		var side := str(sd.get("kind", b.get("side_door", "slider")))
		return {"kind": "slider" if side == "slider" or side == "sliding_step" else "hinged",
			"where": "side", "x": float(sd["x"]), "z0": float(sd["z0"]), "z1": float(sd["z1"]),
			"y0": float(sd["y0"]), "y1": float(sd["y1"]), "color": VEHICLE_DOOR_COLOR}
	return {}


## The overlay node for a plan ({} plan = null).
static func build(p: Dictionary) -> Node3D:
	if p.is_empty():
		return null
	var root := Node3D.new()
	root.name = NODE_NAME
	var dark := _mat(OPENING_COLOR, true)
	var leaf_mat := _mat(p.get("color", VEHICLE_DOOR_COLOR), false)
	var y0 := float(p["y0"])
	var y1 := float(p["y1"])
	var hh := y1 - y0
	var kind := str(p["kind"])
	if str(p["where"]) == "rear":
		var z := float(p["z"])
		var x0 := float(p["x0"])
		var x1 := float(p["x1"])
		var w := x1 - x0
		_box(root, Vector3((x0 + x1) * 0.5, (y0 + y1) * 0.5, z + 0.012), Vector3(w, hh, 0.004), dark)
		match kind:
			"container", "barn":
				for side in [-1.0, 1.0]:
					var hinge := Node3D.new()
					hinge.position = Vector3(x1 if side > 0.0 else x0, 0.0, z + LEAF_T)
					hinge.rotation.y = deg_to_rad(side * LEAF_SWING_DEG)
					root.add_child(hinge)
					_box(hinge, Vector3(-side * w * 0.25, (y0 + y1) * 0.5, 0.0),
						Vector3(w * 0.5, hh, LEAF_T), leaf_mat)
			"roll_up":
				# The curtain is up under the roof: a slim roll at the head.
				_box(root, Vector3((x0 + x1) * 0.5, y1 + 0.06, z - 0.12), Vector3(w, 0.12, 0.2), leaf_mat)
			"lift":
				var top := Node3D.new()
				top.position = Vector3((x0 + x1) * 0.5, y1, z + LEAF_T)
				top.rotation.x = deg_to_rad(-LIFT_SWING_DEG)
				root.add_child(top)
				_box(top, Vector3(0.0, -hh * 0.5, 0.0), Vector3(w, hh, LEAF_T), leaf_mat)
		return root
	var x := float(p["x"])
	var z0 := float(p["z0"])
	var z1 := float(p["z1"])
	var dl := z1 - z0
	_box(root, Vector3(x + 0.012, (y0 + y1) * 0.5, (z0 + z1) * 0.5), Vector3(0.004, hh, dl), dark)
	if kind == "slider":
		# Slid back along the body, standing just proud of it.
		_box(root, Vector3(x + 0.06, (y0 + y1) * 0.5, z1 + dl * 0.5), Vector3(LEAF_T, hh, dl), leaf_mat)
	else:
		var hinge := Node3D.new()
		hinge.position = Vector3(x + LEAF_T, 0.0, z1)
		hinge.rotation.y = deg_to_rad(-HINGED_SWING_DEG)
		root.add_child(hinge)
		_box(hinge, Vector3(0.0, (y0 + y1) * 0.5, -dl * 0.5), Vector3(LEAF_T, hh, dl), leaf_mat)
	return root


static func _box(parent: Node3D, at: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	mi.set_meta("skip_prop_collision", true)
	parent.add_child(mi)


static func _mat(c: Color, unshaded: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.7
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


## Show / hide the overlay on a host's built node. Idempotent: a rebuilt
## prop gets it back on the next call.
## Is a host's cargo door standing open (the overlay, or a living vehicle's
## own door leaves)?
static func is_open(prop: Node) -> bool:
	if prop == null:
		return false
	var walk := prop.get_node_or_null("VehicleWalkIn")
	if walk != null and walk.has_method("any_open"):
		return bool(walk.call("any_open"))
	return prop.get_node_or_null("ModelRoot/" + NODE_NAME) != null


static func set_open(prop: Node, rec: Dictionary, open: bool) -> void:
	if prop == null:
		return
	# A living vehicle's doors are real leaves (VehicleBuilder, VehicleWalkIn):
	# the crew's door simply opens.
	var walk := prop.get_node_or_null("VehicleWalkIn")
	if walk != null and walk.has_method("set_cargo_open"):
		walk.call("set_cargo_open", open)
		return
	var mr := prop.get_node_or_null("ModelRoot") as Node3D
	if mr == null:
		return
	var cur := mr.get_node_or_null(NODE_NAME)
	if not open:
		if cur != null:
			cur.queue_free()
			cur.name = NODE_NAME + "_gone"
		return
	if cur != null:
		return
	var n := build(plan(rec))
	if n != null:
		mr.add_child(n)
