extends RefCounted

## Sandbox, read-only: what the placed lights' shadows cost on the GPU at
## night. Stands a camera 12 m from 6 lit placed lights at 22:00 and measures
## the renderer's GPU time with every placed light's shadow as built and with
## shadow_enabled off, twice each way (put back after).
##   tools\harness.ps1 -World walton -RunScript res://tools/bench/light_shadow_bench.gd -Timeout 900

const VIEWS := 6
const CLAIM := "light_shadow_bench"


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	for _i in 300:
		await tree.process_frame
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", 22.0)
	for _i in 60:
		await tree.process_frame
	var lights: Array = []
	var shadowed: Array = []
	for n in main.find_children("*", "Light3D", true, false):
		var l := n as Light3D
		if l is DirectionalLight3D:
			continue
		var p := l.get_parent()
		var placed := false
		while p != null:
			if p.name == "PlacedLights":
				placed = true
				break
			p = p.get_parent()
		if not placed:
			continue
		lights.append(l)
		if l.shadow_enabled and l.is_visible_in_tree():
			shadowed.append(l)
	print("lightshadow: %d placed light nodes, %d lit with shadows" % [lights.size(), shadowed.size()])
	if shadowed.is_empty():
		return {"ok": true}
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
	var stride := maxi(1, shadowed.size() / VIEWS)
	var res := {"on": [], "off": []}
	for rep in 2:
		for mode in ["on", "off"]:
			for l in shadowed:
				(l as Light3D).shadow_enabled = mode == "on"
			for v in VIEWS:
				var s: Vector3 = (shadowed[(v * stride) % shadowed.size()] as Light3D).global_position
				var eye := s + Vector3(12.0 * cos(float(v)), 1.0, 12.0 * sin(float(v)))
				cam.global_position = eye
				cam.look_at(s, Vector3.UP)
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
	for l in shadowed:
		(l as Light3D).shadow_enabled = true
	main.call("pop_camera_claim", CLAIM)
	cam.queue_free()
	var mean := func(a: Array) -> float:
		var t := 0.0
		for x in a:
			t += float(x)
		return t / maxf(float(a.size()), 1.0)
	print("lightshadow: GPU near lights at 22:00, mean of %d views x 2: shadows on %.2f ms, off %.2f ms" % [
		VIEWS, mean.call(res["on"]), mean.call(res["off"])])
	return {"ok": true}
