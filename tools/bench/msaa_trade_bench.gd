extends RefCounted

## Sandbox, read-only: what MSAA costs on the High preset, and what it looks
## like. Sets graphics quality High in memory (nothing is saved), parks the
## clock at noon, then from the player's view and from spots spread through
## the trees measures the renderer's GPU time with MSAA 4x (High's), 2x and
## off, each level in turn at the same view. Shots of every view at each
## level go to screenshots\msaa_trade\ (view_NN_<level>.png) for a side by
## side look. MSAA_SPOTS sets the spot count (default 6; two directions each).
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/msaa_trade_bench.gd -Timeout 900

const SETTLE_S := 1.0
const SAMPLE_S := 1.5
const PARK_HOUR := 12.0
const CLAIM := "msaa_trade_bench"
const LEVELS := [[2, "4x"], [1, "2x"], [0, "off"]]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	var q0 := int(main.get("graphics_quality"))
	var msaa0 := int(main.get("msaa_level"))
	var follows0 := bool(main.get("msaa_follows_preset"))
	# MSAA_DEFAULTS=1: what a new player sees, not the copied prefs: the
	# realistic style and full render scale (the sandbox's style file only).
	var defaults := OS.get_environment("MSAA_DEFAULTS") == "1"
	var scale0 := float(main.get("render_scale_3d"))
	var style0 := RenderStylePrefs.style()
	if defaults:
		RenderStylePrefs.set_style(RenderStyle.REALISTIC)
		main.set("render_scale_3d", 1.0)
	main.call("set_graphics_quality_level", 2)
	main.call("set_msaa_follows_preset", true)
	main.call("_apply_graphics_quality")
	main.call("_apply_msaa_level")
	# The preset change rebuilds the vegetation: wait for the trees.
	var trees := PackedVector3Array()
	for _w in 60:
		for _i in 20:
			await tree.process_frame
		trees = _tree_positions(main)
		if trees.size() > 0 and (loader == null or not bool(loader.call("is_busy") if loader.has_method("is_busy") else false)):
			break
	await _wait(tree, 4.0)
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", PARK_HOUR)
	var vp := main.get_viewport()
	var rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	print("msaatrade: window %s · scale_3d %.2f · quality %d · taa %s · msaa now %d · %d trees" % [
		str(vp.size), vp.scaling_3d_scale, int(main.get("graphics_quality")), str(vp.use_taa),
		int(vp.msaa_3d), trees.size()])
	var player_cam := vp.get_camera_3d()
	var cam := Camera3D.new()
	cam.fov = player_cam.fov if player_cam != null else 75.0
	cam.near = player_cam.near if player_cam != null else 0.05
	cam.far = player_cam.far if player_cam != null else 4000.0
	if player_cam != null:
		cam.environment = player_cam.environment
		cam.attributes = player_cam.attributes
		cam.cull_mask = player_cam.cull_mask
	main.add_child(cam)
	main.call("push_camera_claim", CLAIM, {"camera_id": cam.get_instance_id()})
	var poses: Array = []
	if player_cam != null:
		poses.append(player_cam.global_transform)
	var spots := int(OS.get_environment("MSAA_SPOTS")) if OS.get_environment("MSAA_SPOTS") != "" else 6
	var stride := maxi(1, trees.size() / maxi(spots, 1))
	var k := 0
	var view := 0
	while k < trees.size() and view < spots * 2 and loader != null:
		var p := trees[k]
		k += stride
		var x := p.x + 3.0
		var z := p.z + 3.0
		var gy := float(loader.call("ground_height_at", x, z))
		for turn in 2:
			var yaw := float(view) * 2.399 + float(turn) * PI
			var fwd := Vector3(sin(yaw), -0.07, cos(yaw)).normalized()
			poses.append(Transform3D(Basis.looking_at(fwd, Vector3.UP), Vector3(x, gy + 1.7, z)))
			view += 1
	var dir := "user://screenshots/msaa_trade" + ("_defaults" if defaults else "")
	DirAccess.make_dir_recursive_absolute(dir)
	var tot := {}
	var rows := 0
	for vi in poses.size():
		cam.global_transform = poses[vi]
		var line := "msaatrade view %2d" % vi
		for lv in LEVELS:
			main.set("msaa_level", int(lv[0]))
			main.call("_apply_msaa_level")
			await _wait(tree, SETTLE_S)
			var s := await _sample(tree, rid)
			tot[lv[1]] = float(tot.get(lv[1], 0.0)) + float(s["gpu"])
			line += "  %s %6.2f ms" % [lv[1], float(s["gpu"])]
			var img := vp.get_texture().get_image()
			if img != null:
				img.save_png("%s/view_%02d_%s.png" % [dir, vi, lv[1]])
		rows += 1
		print(line)
	var mean := "msaatrade MEAN over %d views:" % rows
	for lv in LEVELS:
		mean += "  %s %.2f ms" % [lv[1], float(tot.get(lv[1], 0.0)) / maxf(float(rows), 1.0)]
	print(mean)
	main.call("pop_camera_claim", CLAIM)
	cam.queue_free()
	if defaults:
		RenderStylePrefs.set_style(style0)
		main.set("render_scale_3d", scale0)
	main.call("set_graphics_quality_level", q0)
	main.set("msaa_follows_preset", follows0)
	main.set("msaa_level", msaa0)
	main.call("_apply_msaa_level")
	return {"ok": rows > 0}


func _sample(tree: SceneTree, rid: RID) -> Dictionary:
	var gpu: Array = []
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(SAMPLE_S * 1000.0):
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	gpu.sort()
	return {"gpu": gpu[gpu.size() / 2]}


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _tree_positions(main: Node) -> PackedVector3Array:
	var seen := {}
	_collect(main, seen)
	var keys := seen.keys()
	keys.sort()
	var out := PackedVector3Array()
	for key in keys:
		out.append(seen[key])
	return out


func _collect(n: Node, seen: Dictionary) -> void:
	for ch in n.get_children():
		_collect(ch, seen)
	if not (n is MultiMeshInstance3D) or not n.has_meta(&"veg_species"):
		return
	var mi := n as MultiMeshInstance3D
	if mi.multimesh == null:
		return
	var fam := VegSpeciesCatalog.mesh_family(str(mi.get_meta(&"veg_species")))
	if fam != "pine" and fam != "deciduous":
		return
	var xf := mi.global_transform
	for i in mi.multimesh.instance_count:
		var p := xf * mi.multimesh.get_instance_transform(i).origin
		seen[Vector2i(roundi(p.x * 10.0), roundi(p.z * 10.0))] = p
