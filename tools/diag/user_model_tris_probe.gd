extends RefCounted

## Sandbox, read-only: the player's own (user://) models placed on this world:
## triangles per model (LOD 0, and how many LOD levels each surface has),
## distance from the player, and the frame's drawn primitives / GPU time with
## them shown and hidden, from the player's view at noon.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/user_model_tris_probe.gd

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	for _i in 300:
		await tree.process_frame
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", 12.0)
	var vp := main.get_viewport()
	var rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var cam := vp.get_camera_3d()
	var eye := cam.global_position if cam != null else Vector3.ZERO
	var props: Array = []
	var stack: Array = [main]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		var mid := str(n.get("model_id")) if "model_id" in n else ""
		if mid.begins_with("user_"):
			props.append(n)
	var total := 0
	var rows: Array = []
	for p in props:
		var tris := 0
		var lods := 0
		var surf := 0
		var mstack: Array = [p]
		while not mstack.is_empty():
			var m: Node = mstack.pop_back()
			for ch in m.get_children():
				mstack.append(ch)
			if m is MeshInstance3D and (m as MeshInstance3D).mesh is ArrayMesh:
				var am := (m as MeshInstance3D).mesh as ArrayMesh
				for s in am.get_surface_count():
					var idx := am.surface_get_array_index_len(s)
					tris += (idx if idx > 0 else am.surface_get_array_len(s)) / 3
					surf += 1
					var sd: Dictionary = RenderingServer.mesh_get_surface(am.get_rid(), s)
					lods += (sd.get("lods", []) as Array).size()
		total += tris
		rows.append([str(p.get("model_id")), tris, surf, lods, (p as Node3D).global_position.distance_to(eye)])
	rows.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	for r in rows:
		print("usermodels: %-28s %9d tris  %3d surfaces  %3d LOD levels  %6.0f m away" % [r[0], r[1], r[2], r[3], r[4]])
	print("usermodels: %d placed, %d triangles at LOD 0" % [rows.size(), total])
	# Sub-meshes under a pixel at 4K (75 deg FOV: a pixel is d / 1408 m wide
	# at 1080 lines, d / 2816 m at 2160): how many of the draws they are.
	var subs := 0
	var tiny := {1408.0: 0, 2816.0: 0}
	for p in props:
		var model := (p as Node).get_node_or_null("ModelRoot") as Node3D
		if model == null:
			continue
		var d := (p as Node3D).global_position.distance_to(eye)
		for node in model.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			var r: float = PropRenderTuning._mesh_prop_local_radius(mi, model)
			var sc := (p as Node3D).global_transform.basis.get_scale()
			r *= maxf(sc.x, maxf(sc.y, sc.z))
			subs += mi.mesh.get_surface_count()
			for k in tiny.keys():
				if d > float(k) * r:
					tiny[k] = int(tiny[k]) + mi.mesh.get_surface_count()
	print("usermodels: %d sub-mesh surfaces; under a pixel at 1080p: %d, at 4K: %d" % [subs, int(tiny[1408.0]), int(tiny[2816.0])])
	var shown := await _sample(tree, rid)
	var shot := vp.get_texture().get_image()
	if shot != null:
		DirAccess.make_dir_recursive_absolute("user://screenshots/user_models")
		shot.save_png("user://screenshots/user_models/player_view.png")
	for p in props:
		(p as Node3D).visible = false
	await _wait(tree, 1.0)
	var hidden := await _sample(tree, rid)
	for p in props:
		(p as Node3D).visible = true
	print("usermodels: player view, shown: gpu %.2f ms, cpu %.2f ms, %d draws, %d primitives; hidden: gpu %.2f ms, cpu %.2f ms, %d draws, %d primitives" % [
		float(shown["gpu"]), float(shown["cpu"]), int(shown["draws"]), int(shown["prims"]),
		float(hidden["gpu"]), float(hidden["cpu"]), int(hidden["draws"]), int(hidden["prims"])])
	return {"ok": true}


func _sample(tree: SceneTree, rid: RID) -> Dictionary:
	await _wait(tree, 1.0)
	var gpu: Array = []
	var cpu: Array = []
	var draws := 0.0
	var prims := 0.0
	var n := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2000:
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid)
			+ RenderingServer.get_frame_setup_time_cpu())
		draws += float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		prims += float(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		n += 1
	gpu.sort()
	cpu.sort()
	return {"gpu": float(gpu[gpu.size() / 2]), "cpu": float(cpu[cpu.size() / 2]),
		"draws": draws / maxf(float(n), 1.0), "prims": prims / maxf(float(n), 1.0)}


func _wait(tree: SceneTree, s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(s * 1000.0):
		await tree.process_frame
