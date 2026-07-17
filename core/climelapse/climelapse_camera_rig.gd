class_name ClimelapseCameraRig
extends RefCounted

## Snapshot of the active 3D camera (player or FPV drone) for locked-view export.
## Optional `path` waypoints enable a moving hyperlapse: interpolate pos/yaw/pitch
## across the export frame range.

var mode := "player"
var global_xform := Transform3D.IDENTITY
var fov := 75.0
var near_plane := 0.05
var far_plane := 4000.0
var valid := false
## Array of {pos: Vector3, yaw: float, pitch: float} — empty = static lock camera.
var path: Array = []


static func snapshot_from_tree(tree: SceneTree) -> ClimelapseCameraRig:
	var rig := ClimelapseCameraRig.new()
	if tree == null:
		return rig
	var vp := tree.root.get_viewport()
	if vp == null:
		return rig
	var cam := vp.get_camera_3d()
	if cam == null:
		return rig
	rig.global_xform = cam.global_transform
	rig.fov = cam.fov
	rig.near_plane = cam.near
	rig.far_plane = cam.far
	rig.valid = true
	var player: Node = tree.get_first_node_in_group("player")
	if player != null and player.get("is_fpv_drone_mode"):
		rig.mode = "drone"
	return rig


## Build a waypoint dict from a Camera3D (or Transform3D basis + origin).
static func waypoint_from_transform(xform: Transform3D) -> Dictionary:
	var euler := xform.basis.get_euler()
	return {
		"pos": xform.origin,
		"yaw": euler.y,
		"pitch": euler.x,
	}


static func transform_from_waypoint(wp: Dictionary) -> Transform3D:
	var pos: Vector3 = wp.get("pos", Vector3.ZERO) as Vector3
	var yaw := float(wp.get("yaw", 0.0))
	var pitch := float(wp.get("pitch", 0.0))
	return Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0.0)), pos)


func is_valid() -> bool:
	return valid


func has_path() -> bool:
	return path.size() >= 2


func clear_path() -> void:
	path.clear()


func add_waypoint_from_camera(cam: Camera3D) -> void:
	if cam == null:
		return
	path.append(waypoint_from_transform(cam.global_transform))
	mode = "path"


func add_waypoint(pos: Vector3, yaw: float, pitch: float) -> void:
	path.append({"pos": pos, "yaw": yaw, "pitch": pitch})
	mode = "path"


## t in [0, 1] — linear interpolate between path waypoints.
func interpolate_at(t: float) -> Transform3D:
	if path.is_empty():
		return global_xform
	if path.size() == 1:
		return transform_from_waypoint(path[0])
	var u := clampf(t, 0.0, 1.0)
	var max_i := path.size() - 1
	var f := u * float(max_i)
	var i0 := clampi(int(floor(f)), 0, max_i)
	var i1 := mini(i0 + 1, max_i)
	var local_t := f - float(i0)
	var a: Dictionary = path[i0]
	var b: Dictionary = path[i1]
	var pos_a: Vector3 = a.get("pos", Vector3.ZERO)
	var pos_b: Vector3 = b.get("pos", Vector3.ZERO)
	if typeof(pos_a) != TYPE_VECTOR3:
		pos_a = Vector3.ZERO
	if typeof(pos_b) != TYPE_VECTOR3:
		pos_b = Vector3.ZERO
	var pos := pos_a.lerp(pos_b, local_t)
	var yaw := lerpf(float(a.get("yaw", 0.0)), float(b.get("yaw", 0.0)), local_t)
	var pitch := lerpf(float(a.get("pitch", 0.0)), float(b.get("pitch", 0.0)), local_t)
	return Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0.0)), pos)


## Convenience: seed a 2-point orbit if path empty but drone mode wants motion.
func ensure_default_hyperlapse_path(radius_m: float = 40.0, height_m: float = 25.0) -> void:
	if has_path():
		return
	var origin := global_xform.origin
	var yaw0 := global_xform.basis.get_euler().y
	var pitch := deg_to_rad(-25.0)
	path = [
		{"pos": origin + Vector3(cos(yaw0) * radius_m, height_m, sin(yaw0) * radius_m),
			"yaw": yaw0 + PI, "pitch": pitch},
		{"pos": origin + Vector3(cos(yaw0 + PI) * radius_m, height_m, sin(yaw0 + PI) * radius_m),
			"yaw": yaw0, "pitch": pitch},
	]
	mode = "path"


func spawn_lock_camera(parent: Node) -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "ClimelapseLockCam"
	cam.global_transform = global_xform
	cam.fov = fov
	cam.near = near_plane
	cam.far = far_plane
	parent.add_child(cam)
	cam.make_current()
	return cam
