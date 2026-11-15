class_name CampKitchenBuilder
extends RefCounted

## Procedural CAMP KITCHEN (NPC life pass, Phase 7): the stations a meal is
## cooked at (MealJobPlan), so cooks have somewhere real to stand.
##   back row (counters 0.9 m high along X, cooks in front facing -Z):
##     store (crates on a shelf) · prep table (boards) · two-burner stove
##     (a pot on it, a rack of pots over it) · wash station (three basins)
##   front: the serving table (servers behind it, diners beyond)
##   a canvas shade over it all (spec `canopy`, default on)
## Frame: metres, origin on the ground in the middle, the diners' side +Z.
## Meta `stations` is MealJobPlan.default_stations() (the SAME numbers the
## counters below are built from). Built from Godot primitives only.

const MODEL_ID := "camp_kitchen"

const WOOD := Color(0.55, 0.42, 0.28)
const TOP := Color(0.72, 0.62, 0.48)
const STEEL := Color(0.62, 0.64, 0.67)
const DARK := Color(0.14, 0.14, 0.15)
const CANVAS := Color(0.86, 0.83, 0.74)
const CRATE := Color(0.62, 0.45, 0.28)
const GREENS := Color(0.36, 0.6, 0.24)

const W := 5.2
const D := 3.4
const CANOPY_H := 2.4


static func resolve(spec: Dictionary) -> Dictionary:
	return {"canopy": bool(spec.get("canopy", true))}


static func build_node(spec: Dictionary = {}, node_name: String = "CampKitchen") -> Node3D:
	var s := resolve(spec)
	var root := Node3D.new()
	root.name = node_name
	var top := MealJobPlan.COUNTER_TOP
	var cz := MealJobPlan.COUNTER_Z
	var st := MealJobPlan.default_stations()
	# Back row of counters, one per station.
	for name in ["store", "prep", "stove", "wash"]:
		var x := float((st[name]["pos"] as Vector3).x)
		var w := 1.5 if name == "prep" else 1.0
		_counter(root, Vector3(x, 0, cz), w, top)
	# Store: crates of produce on the shelf.
	var sx := float((st["store"]["pos"] as Vector3).x)
	for i in 2:
		var c := Vector3(sx - 0.22 + 0.44 * i, top, cz)
		_box(root, Vector3(0.4, 0.2, 0.32), c + Vector3(0, 0.1, 0), CRATE)
		_box(root, Vector3(0.34, 0.06, 0.26), c + Vector3(0, 0.22, 0), GREENS)
	_box(root, Vector3(0.84, 0.25, 0.32), Vector3(sx, 0.3, cz), CRATE)     # crates under it
	# Prep: two boards.
	var px := float((st["prep"]["pos"] as Vector3).x)
	for dx in [-0.35, 0.35]:
		_box(root, Vector3(0.4, 0.025, 0.28), Vector3(px + dx, top + 0.0125, cz + 0.12), Color(0.78, 0.62, 0.42))
	# Stove: two burners, a pot, a rack of pots overhead.
	var vx := float((st["stove"]["pos"] as Vector3).x)
	_box(root, Vector3(0.9, 0.08, 0.5), Vector3(vx, top + 0.04, cz), DARK)
	for dx in [-0.22, 0.22]:
		_cyl(root, 0.11, 0.02, Vector3(vx + dx, top + 0.09, cz + 0.02), DARK)
	_cyl(root, 0.16, 0.18, Vector3(vx - 0.22, top + 0.19, cz + 0.02), STEEL)
	_box(root, Vector3(0.04, 1.0, 0.04), Vector3(vx - 0.5, top + 0.5, cz - 0.28), DARK)
	_box(root, Vector3(0.04, 1.0, 0.04), Vector3(vx + 0.5, top + 0.5, cz - 0.28), DARK)
	_box(root, Vector3(1.04, 0.04, 0.04), Vector3(vx, top + 1.0, cz - 0.28), DARK)
	for i in 3:
		_cyl(root, 0.1, 0.14, Vector3(vx - 0.3 + 0.3 * i, top + 0.82, cz - 0.28), STEEL)
	# Wash station: three basins sunk in the top, a tap.
	var wx := float((st["wash"]["pos"] as Vector3).x)
	for i in 3:
		_box(root, Vector3(0.28, 0.03, 0.4), Vector3(wx - 0.32 + 0.32 * i, top + 0.005, cz), Color(0.3, 0.42, 0.5))
	_box(root, Vector3(0.03, 0.3, 0.03), Vector3(wx, top + 0.15, cz - 0.24), STEEL)
	# The serving table at the front, plates stacked on it.
	var sv: Vector3 = st["serve"]["pos"]
	_counter(root, Vector3(sv.x, 0, MealJobPlan.SERVE_TABLE_Z), 2.0, top)
	for i in 6:
		_cyl(root, 0.12, 0.012, Vector3(sv.x + 0.6, top + 0.01 + 0.012 * i, MealJobPlan.SERVE_TABLE_Z), Color(0.92, 0.9, 0.86))
	if bool(s["canopy"]):
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			var p := Vector3(corner.x * W * 0.5, CANOPY_H * 0.5, corner.y * D * 0.5 + 0.1)
			_box(root, Vector3(0.06, CANOPY_H, 0.06), p, DARK)
		var roof := _box(root, Vector3(W + 0.2, 0.03, D + 0.2), Vector3(0, CANOPY_H, 0.1), CANVAS)
		roof.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.set_meta("stations", st)
	root.set_meta("kitchen", true)
	return root


static func _counter(root: Node3D, at: Vector3, w: float, top: float) -> void:
	_box(root, Vector3(w, 0.04, 0.6), Vector3(at.x, top - 0.02, at.z), TOP)
	for dx in [-w * 0.5 + 0.05, w * 0.5 - 0.05]:
		for dz in [-0.25, 0.25]:
			_box(root, Vector3(0.05, top - 0.04, 0.05), Vector3(at.x + dx, (top - 0.04) * 0.5, at.z + dz), WOOD)
	_box(root, Vector3(w - 0.1, 0.02, 0.5), Vector3(at.x, 0.2, at.z), WOOD)       # low shelf


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.75
	return m


static func _box(root: Node3D, size: Vector3, at: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = at
	mi.material_override = _mat(c)
	root.add_child(mi)
	return mi


static func _cyl(root: Node3D, r: float, h: float, at: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = 20
	mi.mesh = cm
	mi.position = at
	mi.material_override = _mat(c)
	root.add_child(mi)
	return mi
