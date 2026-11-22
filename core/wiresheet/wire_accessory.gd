class_name WireAccessory
extends RefCounted

## A fuse, breaker, switch, busbar, distributor or shunt as a small prop.
## The local frame is millimetres, origin on the ground under the body,
## +X right, +Y up, +Z toward the viewer. Terminals are the stud tips the
## conduit leaves from. The systems graph stays the circuit: `stamp` writes
## the routed length onto the connection the sheet already reads.

const MODEL_ID := "wire_accessory"

const BODY := {
	"fuse": Vector3(90, 32, 32),
	"breaker": Vector3(70, 100, 46),
	"switch": Vector3(64, 54, 40),
	"busbar": Vector3(220, 14, 28),
	"distributor": Vector3(200, 56, 48),
	"shunt": Vector3(84, 36, 28),
}

const _COLOR := {
	"fuse": Color("#f4d03f"),
	"breaker": Color("#e39b2b"),
	"switch": Color("#d5d8dc"),
	"busbar": Color("#b87333"),
	"distributor": Color("#b9c0c6"),
	"shunt": Color("#5d6d7e"),
}


## "" when this graph item is not one of these accessories.
static func kind_of_item(item: Dictionary) -> String:
	var sp: Dictionary = item.get("specs", {})
	if bool(sp.get("fuse", false)):
		return "fuse"
	if bool(sp.get("switch", false)):
		return "switch"
	if bool(sp.get("busbar", false)):
		return "busbar"
	if bool(sp.get("shunt", false)):
		return "shunt"
	var ty := str(item.get("type", ""))
	if ty == "combiner" and bool(sp.get("distributor", false)):
		return "distributor"
	if ty == "breaker":
		return "breaker"
	return ""


## Footprint for the site twin, metres, with the kind the mesh is built from.
static func box_spec(kind: String) -> Dictionary:
	var s: Vector3 = BODY.get(kind, BODY["breaker"])
	return {
		"w_m": s.x * 0.001, "d_m": s.z * 0.001, "h_m": s.y * 0.001,
		"accessory_kind": kind if BODY.has(kind) else "breaker",
	}


## Stud tips in the ground frame (mm) and the direction the cable leaves.
static func terminals(kind: String) -> Array:
	var k := kind if BODY.has(kind) else "breaker"
	var s: Vector3 = BODY[k]
	var y := s.y * 0.5
	if k == "busbar":
		return [
			_tip("input", Vector3(-s.x * 0.32, s.y + 6.0, 0), Vector3.UP),
			_tip("output", Vector3(s.x * 0.32, s.y + 6.0, 0), Vector3.UP),
		]
	if k == "distributor":
		return [
			_tip("input1", Vector3(-s.x * 0.5 - 10.0, y, 0), Vector3.LEFT),
			_tip("input2", Vector3(-s.x * 0.22, y, s.z * 0.5 + 10.0), Vector3.BACK),
			_tip("input3", Vector3(s.x * 0.22, y, s.z * 0.5 + 10.0), Vector3.BACK),
			_tip("output", Vector3(s.x * 0.5 + 10.0, y, 0), Vector3.RIGHT),
		]
	return [
		_tip("input", Vector3(-s.x * 0.5 - 10.0, y, 0), Vector3.LEFT),
		_tip("output", Vector3(s.x * 0.5 + 10.0, y, 0), Vector3.RIGHT),
	]


static func _tip(handle: String, pos: Vector3, dir: Vector3) -> Dictionary:
	return {"handle": handle, "pos": pos, "dir": dir}


## The stud tip in world metres. `pose` places the ground origin.
static func terminal_m(kind: String, handle: String, pose: Transform3D) -> Vector3:
	for t in terminals(kind):
		if str(t["handle"]) == handle:
			return pose * ((t["pos"] as Vector3) * 0.001)
	return pose.origin


static func build(g: BattParts.Geo, kind: String) -> void:
	var k := kind if BODY.has(kind) else "breaker"
	var s: Vector3 = BODY[k]
	var col: Color = _COLOR[k]
	var finish := "metal" if k == "busbar" or k == "shunt" else "plastic"
	BattParts.abox(g, Vector3(0, s.y * 0.5, 0), s, col, finish)
	if k == "fuse":
		var cy := s.y * 0.5
		BattParts.disc(g, Vector3(-s.x * 0.5, cy, 0), Vector3.LEFT, s.z * 0.42, 4.0, Color("#8d9399"), "metal")
		BattParts.disc(g, Vector3(s.x * 0.5, cy, 0), Vector3.RIGHT, s.z * 0.42, 4.0, Color("#8d9399"), "metal")
	elif k == "breaker":
		BattParts.abox(g, Vector3(0, s.y * 0.72, s.z * 0.5 + 3.0), Vector3(14, 22, 6), Color("#2c3e50"), "plastic")
	elif k == "switch":
		BattParts.abox(g, Vector3(0, s.y + 8.0, 0), Vector3(8, 22, 8), Color("#2c3e50"), "plastic")
	for t in terminals(k):
		var tip: Vector3 = t["pos"]
		var n: Vector3 = t["dir"]
		BattParts.disc(g, tip - n * 6.0, n, 5.0, 6.0, Color("#c9a227"), "metal")


static func build_node(extras: Dictionary) -> Node3D:
	var kind := str(extras.get("accessory_kind", ""))
	if kind.is_empty() and extras.get("box_spec") is Dictionary:
		kind = str((extras["box_spec"] as Dictionary).get("accessory_kind", ""))
	if not BODY.has(kind):
		kind = "breaker"
	var g := BattParts.Geo.new()
	build(g, kind)
	var root := Node3D.new()
	root.name = "WireAccessory"
	var mi := MeshInstance3D.new()
	mi.mesh = g.commit()
	root.add_child(mi)
	return root


## Sharp axis-aligned run between two studs, and its length on the connection.
## Returns the metres written, or -1 when the connection is missing.
static func stamp(model: GraphModel, conn_id: String, a: Vector3, b: Vector3) -> float:
	if model == null:
		return -1.0
	var c := model.get_connection(conn_id)
	if c.is_empty():
		return -1.0
	var pts := ConduitOrthoRouter.route(a, b, [], false, 0.0)
	var length := ConduitKinds.polyline_length_m(pts)
	c["route_length_m"] = length
	return length


## The placed-prop record that embodies this graph item, or {}.
static func prop_for(records: Array, item_id: String) -> Dictionary:
	if item_id.is_empty():
		return {}
	for r in records:
		if r is Dictionary and str((r as Dictionary).get("graph_item_id", "")) == item_id:
			return r
	return {}
