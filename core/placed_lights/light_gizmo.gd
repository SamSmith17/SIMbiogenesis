class_name LightGizmo
extends Node3D

## The Light Studio gumball: move arrows (X/Y/Z), plane squares (XY/YZ/XZ),
## rotate rings (pitch about X, yaw about Y, roll about Z), and — for spots —
## a wire cone of the real angle out to the real range.
##
## Drawn unshaded and depth-test-free at a constant on-screen size. Picking is
## pure ray maths (LightGizmoMath) against the handle geometry, so it works on
## every map with no colliders. The dock owns the drag; this node only answers
## "which handle is under the mouse" and "what are its axes right now".

const SCREEN_SCALE := 0.11      # handle length as a fraction of camera distance
const PICK_AXIS := 0.13
const PICK_RING := 0.09
const RING_R := 0.78
const PLANE_OFF := 0.32
const PLANE_HALF := 0.11

const COLORS := {
	"x": Color(0.95, 0.3, 0.3), "y": Color(0.4, 0.9, 0.35), "z": Color(0.35, 0.55, 1.0),
}

var world_space := true
## Handle size multiplier (a string's centre handle is drawn smaller).
var size_mult := 1.0
var show_move := true
var show_rotate := true
## Handle ids never shown or picked (e.g. ["rz"] for a camera that does not roll).
var hidden: Array = []

var _basis := Basis.IDENTITY     # axes the handles use (world or the light's own)
var _scale := 1.0
var _parts: Dictionary = {}      # handle id -> MeshInstance3D
var _mats: Dictionary = {}
var _orig: Dictionary = {}       # handle id -> its resting colour
var _cone: MeshInstance3D = null
var _cone_mesh: ImmediateMesh = null
var _hot := ""


func _ready() -> void:
	top_level = true
	for ax in ["x", "y", "z"]:
		_add_arrow(ax)
		_add_ring("r" + ax, ax)
	for pl in ["xy", "yz", "xz"]:
		_add_plane(pl)
	_cone_mesh = ImmediateMesh.new()
	_cone = MeshInstance3D.new()
	_cone.mesh = _cone_mesh
	_cone.material_override = _mat(Color(1.0, 0.9, 0.4, 0.55))
	_cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cone)
	visible = false


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.render_priority = 20
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = c
	return m


func _axis_vec(ax: String) -> Vector3:
	match ax:
		"x": return Vector3.RIGHT
		"y": return Vector3.UP
		_: return Vector3.BACK


func _add_arrow(ax: String) -> void:
	var root := Node3D.new()
	var shaft := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.018
	cyl.bottom_radius = 0.018
	cyl.height = 0.8
	cyl.radial_segments = 8
	shaft.mesh = cyl
	shaft.position = Vector3(0, 0.4, 0)
	var head := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.06
	cone.height = 0.2
	cone.radial_segments = 10
	head.mesh = cone
	head.position = Vector3(0, 0.9, 0)
	var m := _mat(COLORS[ax])
	shaft.material_override = m
	head.material_override = m
	root.add_child(shaft)
	root.add_child(head)
	# Cylinder meshes stand on +Y; turn them onto their axis.
	match ax:
		"x": root.rotation = Vector3(0, 0, -PI / 2.0)
		"z": root.rotation = Vector3(PI / 2.0, 0, 0)
	add_child(root)
	_parts[ax] = root
	_mats[ax] = m
	_orig[ax] = m.albedo_color


func _add_ring(id: String, ax: String) -> void:
	var mi := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = RING_R - 0.012
	t.outer_radius = RING_R + 0.012
	t.rings = 48
	t.ring_segments = 6
	mi.mesh = t
	var m := _mat(Color(COLORS[ax].r, COLORS[ax].g, COLORS[ax].b, 0.75))
	mi.material_override = m
	# TorusMesh lies in XZ (normal +Y); turn its normal onto the axis.
	match ax:
		"x": mi.rotation = Vector3(0, 0, PI / 2.0)
		"z": mi.rotation = Vector3(PI / 2.0, 0, 0)
	add_child(mi)
	_parts[id] = mi
	_mats[id] = m
	_orig[id] = m.albedo_color


func _add_plane(id: String) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2.ONE * PLANE_HALF * 2.0
	mi.mesh = q
	var a := _axis_vec(id[0])
	var b := _axis_vec(id[1])
	var c := Color(1.0, 0.85, 0.3, 0.35)
	var m := _mat(c)
	mi.material_override = m
	# QuadMesh faces +Z in XY; orient its normal to a×b and centre it off-axis.
	var n := a.cross(b)
	mi.transform = Transform3D(Basis(a, b, n), (a + b) * PLANE_OFF)
	add_child(mi)
	_parts[id] = mi
	_mats[id] = m
	_orig[id] = m.albedo_color


## pos: handle origin. rot_basis: the light's basis (used in local mode).
## spot: {angle, range} draws the cone; {} hides it.
func set_target(pos: Vector3, rot_basis: Basis, camera: Camera3D, spot: Dictionary = {}) -> void:
	_basis = Basis.IDENTITY if world_space else rot_basis.orthonormalized()
	_scale = 1.0
	if camera != null:
		_scale = maxf(camera.global_position.distance_to(pos) * SCREEN_SCALE * size_mult, 0.05)
	global_transform = Transform3D(_basis.scaled(Vector3.ONE * _scale), pos)
	for ax in ["x", "y", "z"]:
		(_parts[ax] as Node3D).visible = show_move and not hidden.has(ax)
		(_parts["r" + ax] as Node3D).visible = show_rotate and not hidden.has("r" + ax)
	for pl in ["xy", "yz", "xz"]:
		(_parts[pl] as Node3D).visible = show_move and not hidden.has(pl)
	_draw_cone(rot_basis.orthonormalized(), spot)
	visible = true


func _draw_cone(light_basis: Basis, spot: Dictionary) -> void:
	_cone_mesh.clear_surfaces()
	if spot.is_empty():
		return
	# The cone is in the LIGHT's frame at real size: undo this node's transform.
	_cone.global_transform = Transform3D(light_basis, global_position)
	var ang := deg_to_rad(clampf(float(spot.get("angle", 35.0)), 1.0, 89.0))
	var rng := float(spot.get("range", 10.0))
	var r := tan(ang) * rng
	var seg := 32
	_cone_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		_cone_mesh.surface_add_vertex(Vector3(cos(a0) * r, sin(a0) * r, -rng))
		_cone_mesh.surface_add_vertex(Vector3(cos(a1) * r, sin(a1) * r, -rng))
	for i in 4:
		var a := TAU * float(i) / 4.0
		_cone_mesh.surface_add_vertex(Vector3.ZERO)
		_cone_mesh.surface_add_vertex(Vector3(cos(a) * r, sin(a) * r, -rng))
	_cone_mesh.surface_add_vertex(Vector3.ZERO)
	_cone_mesh.surface_add_vertex(Vector3(0, 0, -rng))
	_cone_mesh.surface_end()


func hide_gizmo() -> void:
	visible = false
	set_hot("")


## World-space axis of a handle ("x", "rx", "xy" → its first axis…).
func axis(id: String) -> Vector3:
	return (_basis * _axis_vec(id.trim_prefix("r")[0])).normalized()


## Normal of a plane handle.
func plane_normal(id: String) -> Vector3:
	return axis(id[0]).cross(axis(id[1])).normalized()


func handle_scale() -> float:
	return _scale


func pick(ray_o: Vector3, ray_d: Vector3) -> String:
	if not visible:
		return ""
	var o := global_position
	var best := ""
	var best_d := INF
	if show_move:
		for ax in ["x", "y", "z"]:
			if hidden.has(ax):
				continue
			var r := LightGizmoMath.ray_segment(ray_o, ray_d, o, o + axis(ax) * _scale)
			var d := float(r["dist"]) / _scale
			if d < PICK_AXIS and d < best_d:
				best_d = d
				best = ax
		for pl in ["xy", "yz", "xz"]:
			if hidden.has(pl):
				continue
			var a := axis(pl[0])
			var b := axis(pl[1])
			var hit: Variant = LightGizmoMath.ray_plane(ray_o, ray_d, o, a.cross(b))
			if hit == null:
				continue
			var local: Vector3 = ((hit as Vector3) - o) / _scale
			var u := local.dot(a) - PLANE_OFF
			var v := local.dot(b) - PLANE_OFF
			if absf(u) <= PLANE_HALF and absf(v) <= PLANE_HALF and 0.05 < best_d:
				best_d = 0.05
				best = pl
	if show_rotate and best.is_empty():
		for ax in ["x", "y", "z"]:
			if hidden.has("r" + ax):
				continue
			var rr := LightGizmoMath.ray_ring(ray_o, ray_d, o, axis(ax), RING_R * _scale)
			var d2 := float(rr["dist"]) / _scale
			if d2 < PICK_RING and d2 < best_d:
				best_d = d2
				best = "r" + ax
	return best


func set_hot(id: String) -> void:
	if _hot == id:
		return
	if _mats.has(_hot):
		(_mats[_hot] as StandardMaterial3D).albedo_color = _orig[_hot]
	_hot = id
	if _mats.has(id):
		var m2: StandardMaterial3D = _mats[id]
		m2.albedo_color = Color(1.0, 0.95, 0.4, 1.0)
