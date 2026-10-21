extends RefCounted

## A/B shots over a carved-channel tile boundary (sandbox, read-only):
##   tools\harness.ps1 -World <id> -RunScript res://tools/checks/channel_tile_seam_shots.gd -Label <dir>
## Frames the corner of the active tile union nearest the player from ~120 m
## up and shoots it as rendered, with the tiles' shadows off, with the tiles
## hidden (the sunk DetailGround shows), and with the DetailGround hidden.

var _dir := "user://screenshots/seam_shots"


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")) != "":
		_dir = "user://screenshots/" + str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	for _i in 240:
		await tree.process_frame
	var hf: Node3D = main.get_node_or_null("Terrain/HeightField")
	var dg := main.get_node_or_null("Terrain/DetailGround") as MeshInstance3D
	if hf == null or dg == null:
		print("seam-shots FAIL: no HeightField / DetailGround")
		return {"ok": false}
	var tiles: TerrainEditTiles = hf.get("tiles")
	var player := main.get_node_or_null("Player") as Node3D
	var pp := Vector2(player.global_position.x, player.global_position.z) if player != null else Vector2.ZERO
	# Nearest union-boundary tile corner to the player.
	var active := {}
	for key in tiles.active_tiles():
		if tiles.tile_has_edits(key):
			active[key] = true
	var best := Vector2.INF
	var best_d := INF
	for key in active.keys():
		var k: Vector2i = key
		if active.has(k + Vector2i(1, 0)) and active.has(k + Vector2i(0, 1)):
			continue
		var r := tiles.tile_world_rect(k)
		var c := r.position + r.size
		var d := c.distance_to(pp)
		if d < best_d:
			best_d = d
			best = c
	if best == Vector2.INF:
		print("seam-shots FAIL: no boundary")
		return {"ok": false}
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var gy: float = float(loader.call("ground_height_at", best.x, best.y))
	# Low sun: the case where a shadow texel spilling off a tile edge is long.
	var low_h := float(OS.get_environment("SEAM_SHOT_HOUR")) if OS.get_environment("SEAM_SHOT_HOUR") != "" else 7.4
	main.set("time_scale", 0.0)
	main.set("day_time", low_h)
	var cam := Camera3D.new()
	cam.far = 4000.0
	main.add_child(cam)
	var shots := [
		["a_low", Vector3(-160, 35, -60)],
		["b_high", Vector3(220, 260, 160)],
	]
	var out := []
	for s in shots:
		var off: Vector3 = s[1]
		cam.global_position = Vector3(best.x, gy, best.y) + off
		cam.look_at(Vector3(best.x, gy, best.y), Vector3.UP)
		if main.has_method("push_camera_claim"):
			main.call("push_camera_claim", "seam_shots", {"camera_id": cam.get_instance_id()})
		else:
			cam.make_current()
		var env: Environment = main.get_viewport().world_3d.environment
		if env == null and main.get("environment") != null:
			env = main.get("environment").environment
		var ssao0 := env.ssao_enabled if env != null else false
		var ssil0 := env.ssil_enabled if env != null else false
		var sdfgi0 := env.sdfgi_enabled if env != null else false
		var states := [
			["", func(): pass],
			["_noshadow", func(): _tiles_shadow(hf, false)],
			["_dgcast", func(): _tiles_shadow(hf, true); dg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON],
			["_noscreen", func():
				dg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				if env != null:
					env.ssao_enabled = false; env.ssil_enabled = false; env.sdfgi_enabled = false],
			["_flatnorm", func():
				if env != null:
					env.ssao_enabled = ssao0; env.ssil_enabled = ssil0; env.sdfgi_enabled = sdfgi0
				_flatten_tile_normals(hf)],
			["_notiles", func(): hf.visible = false],
			["_nodg", func(): hf.visible = true; dg.visible = false],
		]
		for st in states:
			(st[1] as Callable).call()
			for _i in 30:
				await tree.process_frame
			var img := main.get_viewport().get_texture().get_image()
			var p := "%s/%s%s.png" % [_dir, str(s[0]), str(st[0])]
			img.save_png(p)
			out.append(p)
		dg.visible = true
		hf.visible = true
		_tiles_shadow(hf, true)
		if main.has_method("pop_camera_claim"):
			main.call("pop_camera_claim", "seam_shots")
	print("seam-shots: corner (%.0f, %.0f) ground %.1f, %d shots" % [best.x, best.y, gy, out.size()])
	var env2: Environment = main.get_viewport().world_3d.environment
	if env2 != null:
		print("seam-shots: env ssao=%s ssil=%s sdfgi=%s" % [env2.ssao_enabled, env2.ssil_enabled, env2.sdfgi_enabled])
	print("seam-shots: dg cast_shadow=%d  tile material same as dg=%s" % [
		dg.cast_shadow, str(_first_tile_material(hf) == dg.material_override)])
	cam.queue_free()
	return {"ok": true}


var _saved_meshes := {}


func _flatten_tile_normals(hf: Node3D) -> void:
	for c in hf.get_children():
		var m := c.get_node_or_null("Mesh") as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		var arr: Array = m.mesh.surface_get_arrays(0)
		var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in n.size():
			n[i] = Vector3.UP
		arr[Mesh.ARRAY_NORMAL] = n
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m.mesh = am


func _tiles_shadow(hf: Node3D, on: bool) -> void:
	for c in hf.get_children():
		var m := c.get_node_or_null("Mesh") as MeshInstance3D
		if m != null:
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _first_tile_material(hf: Node3D) -> Material:
	for c in hf.get_children():
		var m := c.get_node_or_null("Mesh") as MeshInstance3D
		if m != null:
			return m.material_override
	return null
