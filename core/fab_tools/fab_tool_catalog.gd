class_name FabToolCatalog
extends RefCounted
## Hand tools an NPC wields while fabricating and assembling a LinkageLab
## structure (LINKAGE_PARITY.md / the swarm plan, phase B1).
##
## Each tool is built from primitive meshes (no art needed, so it always
## exists) and carries SOCKETS — named transforms in the tool's own frame,
## in metres:
##   grip   where the primary hand holds it
##   grip2  where a support hand holds it ({} when one hand is enough)
##   tip    the working point: the saw blade's centre on the cut line, the
##          drill bit's tip, the driver's bit tip, the wrench's jaw centre
## and a SPIN part ({node, axis}) the op drivers rotate (blade, bit, ...).
##
## HAND FRAME (the convention every grip socket is written in): the hand's
## origin is the palm centre; the fingers wrap the handle, which runs along
## the hand's X; the forearm leaves the hand along +Y; the palm faces +Z. A
## figure puts its wrist on a grip by IK and then turns the hand to the grip's
## basis, so a socket's basis is "how the hand sits on the tool".
##
## An artist can replace any tool: `user://fab_tools/<id>.glb` plus
## `<id>.json` = {"grip": [x, y, z, rx, ry, rz], "grip2": [...], "tip": [...],
## "spin_node": "NodeName", "spin_axis": [x, y, z]} (metres, degrees). A missing
## or broken override falls back to the procedural tool.

const USER_DIR := "user://fab_tools/"

## id -> {label, ops: the build-step kinds it serves}
const TOOLS := {
	"circular_saw": {"label": "Circular saw", "ops": ["cut"]},
	"drill": {"label": "Drill", "ops": ["drill"]},
	"impact_driver": {"label": "Impact driver", "ops": ["fasten"]},
	"wrench": {"label": "Wrench", "ops": ["fasten"]},
	"mallet": {"label": "Mallet", "ops": ["place"]},
	"clamp": {"label": "Bar clamp", "ops": ["place"]},
}

const STEEL := Color(0.72, 0.74, 0.77)
const DARK := Color(0.16, 0.17, 0.19)
const BODY := Color(0.18, 0.5, 0.76)      # tool-body blue (the JS tools' 0x2f7fc1)
const GUARD := Color(0.91, 0.47, 0.17)
const WOOD := Color(0.62, 0.45, 0.28)


## The tool an op uses (fasten: the driver; a nut-only joint uses the wrench).
static func tool_for_op(kind: String) -> String:
	match kind:
		"cut":
			return "circular_saw"
		"drill":
			return "drill"
		"fasten":
			return "impact_driver"
		"place":
			return ""
	return ""


static func ids() -> Array:
	return TOOLS.keys()


## A hand basis from its X (handle axis) and Y (toward the forearm) in tool
## space; Z (palm normal) completes a right-handed frame.
static func hand_basis(handle_x: Vector3, forearm_y: Vector3) -> Basis:
	var x := handle_x.normalized()
	var y := (forearm_y - x * forearm_y.dot(x)).normalized()
	return Basis(x, y, x.cross(y))


## Sockets of the PROCEDURAL tool (metres): {grip, grip2, tip: Transform3D or
## absent, spin_node: String, spin_axis: Vector3}.
static func sockets(id: String) -> Dictionary:
	match id:
		"circular_saw":
			# Blade in the YZ plane (normal +X, like the web model), centre at
			# the origin = on the cut line; it travels along +Z through the
			# stock. Rear handle on top, a front knob for the other hand.
			return {
				"grip": Transform3D(hand_basis(Vector3(0, 0, 1), Vector3(0, 1, -0.35)), Vector3(0.04, 0.125, -0.07)),
				"grip2": Transform3D(hand_basis(Vector3(1, 0, 0), Vector3(0, 1, 0.2)), Vector3(0.05, 0.085, 0.09)),
				"tip": Transform3D(Basis(), Vector3.ZERO),
				"spin_node": "Blade", "spin_axis": Vector3(1, 0, 0),
			}
		"drill":
			# Bit along -Y with the tip at the origin (the web model's frame);
			# a pistol grip below the body, the support hand on the body top.
			# The pistol grip is VERTICAL (centred at the bit's length, 0.11 m up):
			# the fingers wrap it, so the hand's X runs up it and the forearm
			# leaves behind it. The support hand cups the top of the body.
			return {
				"grip": Transform3D(hand_basis(Vector3(0, 1, 0.15), Vector3(0, -0.3, 1)), Vector3(0, 0.11, 0.075)),
				"grip2": Transform3D(hand_basis(Vector3(0, 0, 1), Vector3(0, 1, 0.3)), Vector3(0, 0.215, 0.02)),
				"tip": Transform3D(Basis(), Vector3.ZERO),
				"spin_node": "Bit", "spin_axis": Vector3(0, 1, 0),
			}
		"impact_driver":
			return {
				"grip": Transform3D(hand_basis(Vector3(0, 1, 0.15), Vector3(0, -0.3, 1)), Vector3(0, 0.06, 0.075)),
				"tip": Transform3D(Basis(), Vector3.ZERO),
				"spin_node": "Bit", "spin_axis": Vector3(0, 1, 0),
			}
		"wrench":
			# Box end ringed round the bolt axis (+Y) at the origin; handle
			# along +Z, held at its far end.
			return {
				"grip": Transform3D(hand_basis(Vector3(0, 1, 0), Vector3(0, 0, 1)), Vector3(0, 0, 0.17)),
				"tip": Transform3D(Basis(), Vector3.ZERO),
				"spin_node": "", "spin_axis": Vector3(0, 1, 0),
			}
		"mallet":
			# Head across X at the top of a handle that runs down -Y.
			return {
				"grip": Transform3D(hand_basis(Vector3(0, 1, 0), Vector3(0, 0, -1)), Vector3(0, -0.22, 0)),
				"tip": Transform3D(Basis(), Vector3(0.06, 0, 0)),
				"spin_node": "", "spin_axis": Vector3(0, 0, 1),
			}
		"clamp":
			return {
				"grip": Transform3D(hand_basis(Vector3(0, 1, 0), Vector3(0, 0, -1)), Vector3(0, -0.08, 0.0)),
				"tip": Transform3D(Basis(), Vector3.ZERO),
				"spin_node": "", "spin_axis": Vector3(0, 1, 0),
			}
	return {}


## Build a tool: a Node3D named "FabTool_<id>" holding the meshes, a Marker3D
## per socket (Grip, Grip2, Tip) and the spin part. Metadata: "tool_id",
## "sockets" (the resolved sockets dict) and "source" ("procedural" | "glb").
static func build(id: String, allow_override: bool = true) -> Node3D:
	if allow_override:
		var over := _load_override(id)
		if over != null:
			return over
	var root := Node3D.new()
	root.name = "FabTool_" + id
	var s := sockets(id)
	match id:
		"circular_saw":
			_build_saw(root)
		"drill":
			_build_drill(root, 0.0127, 0.11)
		"impact_driver":
			_build_driver(root)
		"wrench":
			_build_wrench(root)
		"mallet":
			_build_mallet(root)
		"clamp":
			_build_clamp(root)
		_:
			return null
	_add_markers(root, s)
	root.set_meta("tool_id", id)
	root.set_meta("sockets", s)
	root.set_meta("source", "procedural")
	return root


## The spin part of a built tool (or null).
static func spin_node(tool: Node3D) -> Node3D:
	var s: Dictionary = tool.get_meta("sockets", {})
	var name := str(s.get("spin_node", ""))
	if name.is_empty():
		return null
	return tool.find_child(name, true, false) as Node3D


## Turn the spin part to `angle` radians about its axis (the op drivers' blade
## / bit angle).
static func set_spin(tool: Node3D, angle: float) -> void:
	var n := spin_node(tool)
	if n == null:
		return
	var s: Dictionary = tool.get_meta("sockets", {})
	n.basis = Basis((s.get("spin_axis", Vector3.UP) as Vector3).normalized(), angle)


# ---------------------------------------------------------------------------
# Procedural builders (primitive meshes only — Godot's primitives wind right)
# ---------------------------------------------------------------------------

static func _mat(c: Color, metal: float = 0.1, rough: float = 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	return m


static func _box(parent: Node3D, size: Vector3, at: Vector3, c: Color, name: String = "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = at
	mi.material_override = _mat(c)
	if not name.is_empty():
		mi.name = name
	parent.add_child(mi)
	return mi


## A cylinder of radius r and height h whose axis is `axis` (unit), centred at `at`.
static func _cyl(parent: Node3D, r: float, h: float, at: Vector3, axis: Vector3, c: Color, metal: float = 0.1, segments: int = 16) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = segments
	mi.mesh = cm
	mi.position = at
	mi.basis = _y_to(axis)
	mi.material_override = _mat(c, metal, 0.35 if metal > 0.5 else 0.6)
	parent.add_child(mi)
	return mi


## The rotation taking +Y to `axis`.
static func _y_to(axis: Vector3) -> Basis:
	var a := axis.normalized()
	var d := Vector3.UP.dot(a)
	if d > 0.9999:
		return Basis()
	if d < -0.9999:
		return Basis(Vector3(1, 0, 0), PI)
	return Basis(Vector3.UP.cross(a).normalized(), acos(clampf(d, -1.0, 1.0)))


static func _build_saw(root: Node3D) -> void:
	var r := 0.092   # a 7-1/4 in blade
	var blade := Node3D.new()
	blade.name = "Blade"
	root.add_child(blade)
	_cyl(blade, r, 0.0024, Vector3.ZERO, Vector3(1, 0, 0), STEEL, 0.85, 40)
	# Teeth read as a darker rim; the arbor nut in the middle.
	var rim := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = r - 0.006
	tm.outer_radius = r
	tm.rings = 40
	tm.ring_segments = 4
	rim.mesh = tm
	rim.basis = _y_to(Vector3(1, 0, 0))
	rim.material_override = _mat(DARK, 0.5)
	blade.add_child(rim)
	_cyl(root, 0.008, 0.024, Vector3.ZERO, Vector3(1, 0, 0), DARK, 0.4, 12)
	# Upper guard: a half drum over the top of the blade.
	var guard := MeshInstance3D.new()
	var gm := CylinderMesh.new()
	gm.top_radius = r + 0.009
	gm.bottom_radius = r + 0.009
	gm.height = 0.018
	gm.radial_segments = 24
	guard.mesh = gm
	guard.basis = _y_to(Vector3(1, 0, 0))
	guard.position = Vector3(0, 0.03, 0)
	guard.scale = Vector3(1.0, 1.0, 0.55)
	guard.material_override = _mat(GUARD)
	root.add_child(guard)
	# Shoe plate resting on the stock, motor on +X, handle + knob on top.
	_box(root, Vector3(0.11, 0.004, 0.25), Vector3(0.045, -0.012, 0.0), STEEL)
	_box(root, Vector3(0.07, 0.065, 0.075), Vector3(0.055, 0.03, -0.01), BODY)
	_box(root, Vector3(0.028, 0.03, 0.11), Vector3(0.04, 0.125, -0.07), DARK)   # rear handle
	_box(root, Vector3(0.014, 0.05, 0.02), Vector3(0.04, 0.092, -0.11), DARK)   # handle post
	_cyl(root, 0.016, 0.04, Vector3(0.05, 0.085, 0.09), Vector3(1, 0, 0), DARK, 0.1, 12)  # front knob


## Drill: bit along -Y with the tip at the origin (build-steps-ops createDrillMesh).
static func _build_drill(root: Node3D, bit_d: float, bit_len: float) -> void:
	var r := maxf(0.002, bit_d / 2.0)
	var bit := Node3D.new()
	bit.name = "Bit"
	root.add_child(bit)
	var tip_h := maxf(0.006, r * 1.2)
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = 0.0005
	cm.height = tip_h
	cm.radial_segments = 12
	cone.mesh = cm
	cone.position = Vector3(0, tip_h / 2.0, 0)
	cone.material_override = _mat(STEEL, 0.85)
	bit.add_child(cone)
	_cyl(bit, r, bit_len - tip_h, Vector3(0, tip_h + (bit_len - tip_h) / 2.0, 0), Vector3.UP, STEEL, 0.85, 12)
	_box(bit, Vector3(r * 2.05, (bit_len - tip_h) * 0.9, r * 0.35), Vector3(0, tip_h + (bit_len - tip_h) / 2.0, 0), DARK)
	_cyl(root, 0.016, 0.035, Vector3(0, bit_len + 0.018, 0), Vector3.UP, DARK, 0.4, 16)   # chuck
	_box(root, Vector3(0.05, 0.06, 0.17), Vector3(0, bit_len + 0.065, 0.045), BODY)        # body, motor behind
	_box(root, Vector3(0.035, 0.11, 0.04), Vector3(0, bit_len + 0.0, 0.075), DARK)         # pistol grip
	_box(root, Vector3(0.06, 0.04, 0.06), Vector3(0, bit_len - 0.065, 0.085), BODY)        # battery


static func _build_driver(root: Node3D) -> void:
	_build_drill(root, 0.0063, 0.06)
	# A shorter, stubbier body; the hex bit is the drill bit scaled down above.
	for c in root.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
			(c as MeshInstance3D).scale = Vector3(0.9, 0.85, 0.8)


static func _build_wrench(root: Node3D) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.011
	tm.outer_radius = 0.02
	tm.rings = 18
	tm.ring_segments = 6
	ring.mesh = tm
	ring.material_override = _mat(STEEL, 0.85, 0.35)
	root.add_child(ring)
	_box(root, Vector3(0.022, 0.006, 0.17), Vector3(0, 0, 0.1), STEEL)


static func _build_mallet(root: Node3D) -> void:
	_cyl(root, 0.032, 0.12, Vector3.ZERO, Vector3(1, 0, 0), Color(0.12, 0.12, 0.13), 0.0, 16)  # rubber head
	_cyl(root, 0.012, 0.3, Vector3(0, -0.15, 0), Vector3.UP, WOOD, 0.0, 10)


static func _build_clamp(root: Node3D) -> void:
	_box(root, Vector3(0.012, 0.3, 0.025), Vector3(0, 0.0, 0.0), STEEL)
	_box(root, Vector3(0.02, 0.025, 0.07), Vector3(0, 0.14, 0.035), DARK)
	_box(root, Vector3(0.02, 0.025, 0.07), Vector3(0, -0.02, 0.035), DARK)
	_box(root, Vector3(0.03, 0.09, 0.035), Vector3(0, -0.08, 0.0), Color(0.85, 0.65, 0.1))


static func _add_markers(root: Node3D, s: Dictionary) -> void:
	for pair in [["grip", "Grip"], ["grip2", "Grip2"], ["tip", "Tip"]]:
		var t = s.get(pair[0])
		if t is Transform3D:
			var m := Marker3D.new()
			m.name = pair[1]
			m.transform = t
			root.add_child(m)


# ---------------------------------------------------------------------------
# GLB override
# ---------------------------------------------------------------------------

static func override_paths(id: String) -> Dictionary:
	return {"glb": USER_DIR + id + ".glb", "json": USER_DIR + id + ".json"}


## Sockets JSON -> sockets dict. Each socket is [x, y, z, rx, ry, rz]
## (metres, degrees, Euler YXZ like Node3D.rotation). {} when malformed.
static func parse_sockets(raw) -> Dictionary:
	if not (raw is Dictionary) or not (raw.get("grip") is Array):
		return {}
	var out := {}
	for key in ["grip", "grip2", "tip"]:
		var a = raw.get(key)
		if not (a is Array) or (a as Array).size() < 3:
			continue
		var pos := Vector3(float(a[0]), float(a[1]), float(a[2]))
		var rot := Vector3.ZERO
		if (a as Array).size() >= 6:
			rot = Vector3(deg_to_rad(float(a[3])), deg_to_rad(float(a[4])), deg_to_rad(float(a[5])))
		out[key] = Transform3D(Basis.from_euler(rot), pos)
	if not out.has("grip"):
		return {}
	out["spin_node"] = str(raw.get("spin_node", ""))
	var ax = raw.get("spin_axis")
	out["spin_axis"] = Vector3(float(ax[0]), float(ax[1]), float(ax[2])) if ax is Array and (ax as Array).size() >= 3 else Vector3.UP
	return out


static func _load_override(id: String) -> Node3D:
	var paths := override_paths(id)
	if not FileAccess.file_exists(paths["glb"]) or not FileAccess.file_exists(paths["json"]):
		return null
	var f := FileAccess.open(paths["json"], FileAccess.READ)
	var s := parse_sockets(JSON.parse_string(f.get_as_text()) if f != null else null)
	if s.is_empty():
		push_warning("FabToolCatalog: %s has no usable grip socket; using the procedural tool" % paths["json"])
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(paths["glb"]), state) != OK:
		push_warning("FabToolCatalog: cannot read %s; using the procedural tool" % paths["glb"])
		return null
	var scene := doc.generate_scene(state)
	if not (scene is Node3D):
		return null
	var root := Node3D.new()
	root.name = "FabTool_" + id
	root.add_child(scene)
	_add_markers(root, s)
	root.set_meta("tool_id", id)
	root.set_meta("sockets", s)
	root.set_meta("source", "glb")
	return root
