class_name ClimelapseCameraRig
extends RefCounted

## Snapshot of the active 3D camera (player or FPV drone) for locked-view export.

var mode := "player"
var global_xform := Transform3D.IDENTITY
var fov := 75.0
var near_plane := 0.05
var far_plane := 4000.0
var valid := false


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


func is_valid() -> bool:
	return valid


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
