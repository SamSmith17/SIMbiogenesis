extends RefCounted

## Sandbox, read-only: GPU and CPU frame cost from camera spots spread
## through the forest, at noon with the graph closed.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/veg_spots_bench.gd
##
## The spots come from the trees themselves (every tree position, de-duplicated
## and sorted, then every k-th), so a build that groups the same trees into
## different batches is measured from the same places. Each spot is looked at
## in two directions. Prints a line per view and the means; compare a run
## before and after a vegetation change on the same world.

const SPOTS := 16
const SETTLE_S := 0.8
const SAMPLE_S := 1.2
const PARK_HOUR := 12.0
const CLAIM := "veg_spots_bench"


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
	var stride := maxi(1, trees.size() / SPOTS)
	var rows: Array = []
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
			cam.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP),
				Vector3(x, gy + 1.7, z))
			await _wait(tree, SETTLE_S)
			var s := await _sample(tree, rid)
			rows.append(s)
			print("vegspots view %2d  gpu %6.2f ms  cpu %6.2f ms  draws %5d  prims %9d" % [
				view, float(s["gpu"]), float(s["cpu"]), int(s["draws"]), int(s["prims"])])
			view += 1
	main.call("pop_camera_claim", CLAIM)
	cam.queue_free()
	var mean := {"gpu": 0.0, "cpu": 0.0, "draws": 0.0, "prims": 0.0}
	for s in rows:
		for key in mean:
			mean[key] = float(mean[key]) + float((s as Dictionary)[key])
	for key in mean:
		mean[key] = float(mean[key]) / maxf(float(rows.size()), 1.0)
	var gpus: Array = []
	for s in rows:
		gpus.append(float((s as Dictionary)["gpu"]))
	gpus.sort()
	print("vegspots MEAN  gpu %.2f ms (p50 %.2f, p90 %.2f)  cpu %.2f ms  draws %.0f  prims %.0f over %d views" % [
		float(mean["gpu"]), float(gpus[gpus.size() / 2]), float(gpus[int(gpus.size() * 0.9)]),
		float(mean["cpu"]), float(mean["draws"]), float(mean["prims"]), rows.size()])
	return {"ok": true, "views": rows.size()}


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
	var cpu: Array = []
	var draws := 0.0
	var prims := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(SAMPLE_S * 1000.0):
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid)
			+ RenderingServer.get_frame_setup_time_cpu())
		draws += float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		prims += float(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		frames += 1
	gpu.sort()
	cpu.sort()
	var nf := maxf(float(frames), 1.0)
	return {"gpu": gpu[gpu.size() / 2], "cpu": cpu[cpu.size() / 2],
		"draws": draws / nf, "prims": prims / nf}
