extends RefCounted

## What another player looks like (sandbox, no network): a RemotePlayerAvatar
## fed walking presence 3.5 m in front of the camera, shot from there, with
## its placement and every mesh's visibility dumped.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/mp_figure_probe.gd -Label mp_figure

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("mp-figure %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	main.set("day_time", 13.0)
	main.set("time_scale", 0.0)
	var player := main.get_node("Player") as Node3D
	var cam := main.get_viewport().get_camera_3d()
	cam.rotation.x = -0.15
	await tree.process_frame
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var spot := cam.global_position + fwd * 3.5
	var gy := TerrainSurfaceQuery.ground_height_at(main, spot.x, spot.z)
	print("mp-figure: cam %s  player %s  spot %s  ground %s" % [cam.global_position, player.global_position, spot, gy])
	# The player may stand on a deck above the terrain: use their own foot height.
	spot.y = player.global_position.y
	var av := RemotePlayerAvatar.new()
	main.add_child(av)
	av.setup(7, "Guestie")
	av.set_rim(Color(0.95, 0.55, 0.2))
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var yaw := atan2(-side.x, -side.z)
	for i in 40:
		av.push_snapshot(spot + side * (float(i) * 0.03 - 0.6), yaw, {"mode": "walk", "rate": 1.0})
		await tree.create_timer(1.0 / 12.0).timeout
	print("mp-figure: avatar at %s visible_in_tree=%s  screen=%s behind=%s" % [av.global_position,
		av.is_visible_in_tree(), cam.unproject_position(av.global_position + Vector3.UP),
		cam.is_position_behind(av.global_position)])
	var meshes := 0
	for n in av.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		meshes += 1
		if meshes <= 4:
			print("mp-figure:   mesh %s visible=%s layers=%d aabb=%s gpos=%s" % [mi.name,
				mi.is_visible_in_tree(), mi.layers, mi.get_aabb(), mi.global_position])
	_ok(meshes > 5, "the figure has its body parts (%d meshes)" % meshes)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://screenshots/mp_probe"))
	main.get_viewport().get_texture().get_image().save_png("user://screenshots/mp_probe/figure_walking.png")
	av.queue_free()
	return {"ok": _fails.is_empty()}
