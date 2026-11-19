extends RefCounted

## Sandbox, read-only: what the deadwood moss overlay (a second draw of every
## textured stump batch) costs on the GPU. Stands a camera 7 m from 8 stumps
## spread over the world at noon, and measures the renderer's GPU time with
## the overlays as built and with material_overlay cleared, twice each way.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/deadwood_moss_bench.gd -Timeout 900

const VIEWS := 8
const CLAIM := "deadwood_moss_bench"


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	var batches: Array = []
	for _w in 60:
		for _i in 15:
			await tree.process_frame
		batches = main.find_children("Stumps_*", "MultiMeshInstance3D", true, false)
		if not batches.is_empty():
			break
	var with_overlay: Array = []
	var stumps := PackedVector3Array()
	var n_inst := 0
	for b in batches:
		var mi := b as MultiMeshInstance3D
		if mi.material_overlay != null:
			with_overlay.append([mi, mi.material_overlay])
		var mm := mi.multimesh
		if mm == null:
			continue
		n_inst += mm.instance_count
		for i in mm.instance_count:
			stumps.append(mi.global_transform * mm.get_instance_transform(i).origin)
	print("deadwoodmoss: %d stump batches (%d with the moss overlay), %d stumps" % [batches.size(), with_overlay.size(), n_inst])
	if stumps.is_empty() or with_overlay.is_empty():
		return {"ok": true}
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", 12.0)
	var vp := main.get_viewport()
	var rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var pc := vp.get_camera_3d()
	var cam := Camera3D.new()
	cam.fov = pc.fov if pc != null else 75.0
	cam.far = pc.far if pc != null else 4000.0
	if pc != null:
		cam.environment = pc.environment
		cam.attributes = pc.attributes
		cam.cull_mask = pc.cull_mask
	main.add_child(cam)
	main.call("push_camera_claim", CLAIM, {"camera_id": cam.get_instance_id()})
	var stride := maxi(1, stumps.size() / VIEWS)
	var res := {"on": [], "off": []}
	for rep in 2:
		for mode in ["on", "off"]:
			for e in with_overlay:
				(e[0] as MultiMeshInstance3D).material_overlay = e[1] if mode == "on" else null
			for v in VIEWS:
				var s: Vector3 = stumps[(v * stride) % stumps.size()]
				var eye := s + Vector3(7.0 * cos(float(v)), 1.7, 7.0 * sin(float(v)))
				cam.global_position = eye
				cam.look_at(s + Vector3(0, 0.4, 0), Vector3.UP)
				var t0 := Time.get_ticks_msec()
				while Time.get_ticks_msec() - t0 < 600:
					await tree.process_frame
				var g: Array = []
				t0 = Time.get_ticks_msec()
				while Time.get_ticks_msec() - t0 < 1000:
					await tree.process_frame
					g.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
				g.sort()
				(res[mode] as Array).append(float(g[g.size() / 2]))
	for e in with_overlay:
		(e[0] as MultiMeshInstance3D).material_overlay = e[1]
	main.call("pop_camera_claim", CLAIM)
	cam.queue_free()
	var mean := func(a: Array) -> float:
		var t := 0.0
		for x in a:
			t += float(x)
		return t / maxf(float(a.size()), 1.0)
	print("deadwoodmoss: GPU at stumps, mean of %d views x 2: overlay on %.2f ms, off %.2f ms" % [
		VIEWS, mean.call(res["on"]), mean.call(res["off"])])
	return {"ok": true}
