extends RefCounted

## Lens GPU bench: what the SoI preview costs with a lens open.
##
## Opens the graph, switches through the Site Plan, Elevation and Globe lenses
## and, for each, samples the renderer's measured GPU time on the ROOT viewport
## (the frame the player sees) and on the preview SubViewport itself, the way
## gpu_toggle_bench samples (`RenderingServer.viewport_get_measured_render_time_gpu`,
## median over a sampling window). Prints the container size, the SubViewport's
## REAL size and the container's stretch_shrink beside each number, because the
## viewport caps (`MAX_VIEWPORT_PX` / `MAX_SECTION_VIEWPORT_PX`) used to be dead:
## `SubViewportContainer.stretch` resized the viewport to the container every
## frame and the hand-written `_viewport.size` was refused by the engine.
##
## Dry run only, sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/lens_gpu_bench.gd -UserArgs @("--window-size=1920x1080")
## Prints `lensbench …` lines.

const SETTLE_S := 3.0
const SAMPLE_S := 3.0
const PARK_HOUR := 12.0
const LENSES: Array[String] = ["site", "elevation", "globe"]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv == null:
		return {"ok": false, "why": "no SystemGraphView"}
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", PARK_HOUR)
	var vp := main.get_viewport()
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	await _wait(tree, 2.0)
	print("lensbench: window %s · scale_3d %.2f · msaa %d" % [
		str(vp.size), vp.scaling_3d_scale, int(vp.msaa_3d)])
	if not bool(sgv.get("visible")):
		sgv.call("open_graph_view")
	await _wait(tree, 1.0)
	var results := {}
	for lens in LENSES:
		sgv.call("_on_mode_chip_pressed", lens)
		await _wait(tree, SETTLE_S)
		# The service and its viewport are made on the first lens; the nodes
		# then persist across lenses (measuring stays on).
		var svc: Node = sgv.get("_soi_preview")
		var sub: SubViewport = svc.get("_viewport") if svc != null else null
		var cont: Control = svc.get("_container") if svc != null else null
		if sub != null:
			RenderingServer.viewport_set_measure_render_time(sub.get_viewport_rid(), true)
			await _wait(tree, 0.3)
		var s := await _sample(tree, vp, svc, sub)
		_print(lens, s, cont, sub)
		results[lens] = s
		if lens == "globe" and cont is SubViewportContainer:
			# What the cap buys when it BITES (a 1080p canvas sits under both
			# caps, so stretch_shrink stays 1 here): the same lens at ÷2.
			var k0 := int((cont as SubViewportContainer).stretch_shrink)
			(cont as SubViewportContainer).stretch_shrink = 2
			await _wait(tree, 1.0)
			var s2 := await _sample(tree, vp, svc, sub)
			_print("globe ÷2", s2, cont, sub)
			results["globe_half"] = s2
			(cont as SubViewportContainer).stretch_shrink = k0
			await _wait(tree, 0.5)
	sgv.call("_on_mode_chip_pressed", "freeform")
	await _wait(tree, 0.5)
	sgv.call("close_graph_view")
	return {"ok": true, "results": results}


func _print(name: String, s: Dictionary, cont: Control, sub: SubViewport) -> void:
	var shrink := int((cont as SubViewportContainer).stretch_shrink) if cont is SubViewportContainer else -1
	print("lensbench %-10s root GPU %6.2f ms (p90 %6.2f) · preview GPU %6.2f ms (p90 %6.2f) · container %s · viewport %s · stretch_shrink %d · %4.0f fps" % [
		name, float(s["gpu"]), float(s["gpu_p90"]), float(s["sub_gpu"]), float(s["sub_gpu_p90"]),
		str(cont.size if cont != null else Vector2.ZERO), str(sub.size if sub != null else Vector2i.ZERO),
		shrink, float(s["fps"])])


## The preview is dirty-driven (it captures on a change, not every frame),
## so each sampled frame asks for a capture: the numbers are the cost of ONE
## lens render, on the root viewport's frame and on the preview's own.
func _sample(tree: SceneTree, vp: Viewport, svc: Node, sub: SubViewport) -> Dictionary:
	var rid := vp.get_viewport_rid()
	var gpu: Array = []
	var sub_gpu: Array = []
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(SAMPLE_S * 1000.0):
		if svc != null and svc.has_method("_request_viewport_refresh"):
			svc.call("_request_viewport_refresh")
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		if sub != null and is_instance_valid(sub):
			sub_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(sub.get_viewport_rid()))
		frames += 1
	gpu.sort()
	sub_gpu.sort()
	return {"gpu": gpu[gpu.size() / 2], "gpu_p90": gpu[int(gpu.size() * 0.9)],
		"sub_gpu": sub_gpu[sub_gpu.size() / 2] if not sub_gpu.is_empty() else -1.0,
		"sub_gpu_p90": sub_gpu[int(sub_gpu.size() * 0.9)] if not sub_gpu.is_empty() else -1.0,
		"fps": float(frames) / SAMPLE_S}


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout
