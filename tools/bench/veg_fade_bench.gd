extends RefCounted

## Sandbox, read-only: what the vegetation's distance fades cost. Godot draws
## a batch inside its fade band (visibility range + margin) through the
## alpha-blended pass, so near a handoff whole 64 m cells of trees lose the
## depth prepass. From spots spread through the forest (as veg_spots_bench
## picks them), at noon with the graph closed, measures the renderer's GPU
## time with the fades as built (FADE_SELF) and with them off, alternating
## twice; each switch sets VegetationRuntime.fade_mode and REBUILDS the
## vegetation (never a live change on built nodes). Also counts the batches
## inside a fade band from each view. Shots per view to
## screenshots\veg_fade\ (view_NN_<mode>.png).
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/veg_fade_bench.gd -Timeout 1500

const SPOTS := 10
const SETTLE_S := 1.0
const SAMPLE_S := 1.5
const PARK_HOUR := 12.0
const CLAIM := "veg_fade_bench"
const MODES := [[GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF, "fade"],
	[GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED, "nofade"]]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	var trees := PackedVector3Array()
	for _w in 40:
		for _i in 15:
			await tree.process_frame
		trees = _tree_positions(main)
		if trees.size() > 0:
			break
	if trees.is_empty():
		return {"ok": false, "why": "no tree batches"}
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", PARK_HOUR)
	var vp := main.get_viewport()
	var rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
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
	var stride := maxi(1, trees.size() / SPOTS)
	var k := 0
	var view := 0
	while k < trees.size() and view < SPOTS * 2:
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
	var dir := "user://screenshots/veg_fade"
	DirAccess.make_dir_recursive_absolute(dir)
	var tot := {}
	var fading_tot := 0
	var mode0: int = VegetationRuntime.fade_mode
	for rep in 2:
		for mode in MODES:
			VegetationRuntime.fade_mode = int(mode[0])
			loader.call("_rebuild_vegetation")
			await _wait(tree, 3.0)
			for vi in poses.size():
				cam.global_transform = poses[vi]
				await _wait(tree, SETTLE_S)
				var s := await _sample(tree, rid)
				var key: String = mode[1]
				tot[key] = float(tot.get(key, 0.0)) + float(s["gpu"])
				tot[key + "_draws"] = float(tot.get(key + "_draws", 0.0)) + float(s["draws"])
				var nf := _fading(main, cam.global_position) if key == "fade" and rep == 0 else -1
				if nf >= 0:
					fading_tot += nf
				print("vegfade rep %d view %2d %-6s gpu %6.2f ms  draws %5d%s" % [rep, vi, key,
					float(s["gpu"]), int(s["draws"]), ("  batches in a fade band %d" % nf) if nf >= 0 else ""])
				if rep == 0:
					var img := vp.get_texture().get_image()
					if img != null:
						img.save_png("%s/view_%02d_%s.png" % [dir, vi, key])
	VegetationRuntime.fade_mode = mode0
	loader.call("_rebuild_vegetation")
	await _wait(tree, 2.0)
	main.call("pop_camera_claim", CLAIM)
	cam.queue_free()
	var n := float(poses.size() * 2)
	print("vegfade MEAN over %d views x 2: fade gpu %.2f ms (draws %.0f)  nofade gpu %.2f ms (draws %.0f)  batches fading per view %.1f" % [
		poses.size(), float(tot.get("fade", 0.0)) / n, float(tot.get("fade_draws", 0.0)) / n,
		float(tot.get("nofade", 0.0)) / n, float(tot.get("nofade_draws", 0.0)) / n,
		float(fading_tot) / maxf(float(poses.size()), 1.0)])
	return {"ok": true}


## Vegetation batches whose centre distance from the camera is inside a fade
## band of their visibility range.
func _fading(main: Node, cam_pos: Vector3) -> int:
	var n := 0
	var stack: Array = [main]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for ch in node.get_children():
			stack.append(ch)
		if not (node is GeometryInstance3D) or not node.has_meta(&"veg_species"):
			continue
		var gi := node as GeometryInstance3D
		if not gi.is_visible_in_tree():
			continue
		var aabb := gi.get_aabb()
		var c := gi.global_transform * aabb.get_center()
		var d := c.distance_to(cam_pos)
		var b := gi.visibility_range_begin
		var e := gi.visibility_range_end
		if b > 0.0 and d >= b - gi.visibility_range_begin_margin and d <= b + gi.visibility_range_begin_margin:
			n += 1
		elif e > 0.0 and d >= e - gi.visibility_range_end_margin and d <= e + gi.visibility_range_end_margin:
			n += 1
	return n


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


func _wait(tree: SceneTree, secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		await tree.process_frame


func _sample(tree: SceneTree, rid: RID) -> Dictionary:
	var gpu: Array = []
	var draws := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(SAMPLE_S * 1000.0):
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		draws += float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		frames += 1
	gpu.sort()
	return {"gpu": float(gpu[gpu.size() / 2]), "draws": draws / maxf(float(frames), 1.0)}
