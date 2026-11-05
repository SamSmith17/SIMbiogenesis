extends RefCounted

## What placed solar concentrators cost a frame (the CSP performance pass).
##
## Sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/csplab_bench.gd -Timeout 900
##
## Places one of each built-in kind (dishes, troughs, a linear Fresnel field,
## two heliostat towers, the water lens…) in a row ahead of the player, then:
##   - CPU at 1x / 60x / 1440x: the frame median and peak, and the
##     concentrator sections (csp_runtime and its parts csp_pose / csp_drives /
##     csp_glow / csp_ha, the graph's csp_graph), averaged per frame and their
##     2 s peaks;
##   - GPU from a camera looking at the row: with the concentrators shown,
##     hidden, and with their mirrors drawn as a plain material, so the
##     mirror shader's own cost is the difference.
## Prints `cspbench …` lines. CSPB_QUICK=1 skips the GPU part.

const PRESETS := ["dish_cooker", "stirling_dish", "diy_trough", "eurotrough", "cpc_pipe",
	"lfr_small", "tower_poleward", "tower_surround", "water_lens", "fresnel_cooker"]
const SAMPLE_S := 6.0
const SAMPLE_DT := 0.1
const SECTIONS: Array[String] = ["csp_runtime", "csp_pose", "csp_drives", "csp_glow", "csp_ha", "csp_graph"]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	var sgv := ServiceLocator.graph()
	if pm == null or sgv == null:
		return {"ok": false, "why": "no PerfMonitor / graph"}
	main.set("time_scale", 0.0)
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 10.0)
	pm.call("set_enabled", true)
	main.set("time_scale", 1.0 / 3600.0)
	await _wait(tree, 2.0)
	_print("none placed 1x", await _sample(tree, pm))
	main.set("time_scale", 0.0)
	var player := ServiceLocator.player() as Node3D
	var at0 := player.global_position + Vector3(0.0, 0.0, -30.0) if player != null else Vector3(0, 0, -30)
	var props: Array = []
	var t0 := Time.get_ticks_msec()
	var x := 0.0
	for id in PRESETS:
		var src := CspLabPresets.by_id(str(id))
		if src.is_empty():
			continue
		var before := _prop_ids(main)
		var preset := ComponentPresets.designed_csp_preset(src)
		var ta := Time.get_ticks_msec()
		sgv.call("_on_lib_place_model_requested", preset, "", at0 + Vector3(x, 0.0, 0.0))
		await tree.process_frame
		var pid := ""
		for p in _prop_ids(main):
			if not before.has(p):
				pid = str(p)
		var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
		if prop != null:
			props.append(prop)
		print("cspbench: placed %-15s in %4d ms" % [id, Time.get_ticks_msec() - ta])
		var span := 6.0
		if str(id).begins_with("tower"):
			span = 60.0
		elif str(id) in ["eurotrough", "lfr_small", "stirling_dish"]:
			span = 16.0
		x += span
	print("cspbench: %d concentrators placed in %d ms" % [props.size(), Time.get_ticks_msec() - t0])
	await _wait(tree, 3.0)
	for ts in [1.0, 60.0, 1440.0]:
		main.call("set_absolute_hours", day0 + 10.0)
		main.set("time_scale", ts / 3600.0)
		await _wait(tree, 1.5)
		_print("%dx" % int(ts), await _sample(tree, pm))
	main.set("time_scale", 0.0)
	if OS.get_environment("CSPB_QUICK").is_empty() and not props.is_empty():
		await _gpu(main, tree, props, at0, x)
	pm.call("set_enabled", false)
	return {"ok": true}


func _gpu(main: Node, tree: SceneTree, props: Array, at0: Vector3, span: float) -> void:
	var cam := Camera3D.new()
	main.add_child(cam)
	var mid := at0 + Vector3(span * 0.4, 0.0, 0.0)
	cam.look_at_from_position(mid + Vector3(0.0, 18.0, 55.0), mid + Vector3(0, 2.0, 0), Vector3.UP)
	main.call("push_camera_claim", "csp_bench", {"camera_id": cam.get_instance_id()})
	await _wait(tree, 1.0)
	var shown := await _gpu_ms(tree)
	# Mirrors as a plain grey metal (what the shader adds over it).
	var plain := StandardMaterial3D.new()
	plain.albedo_color = Color(0.8, 0.82, 0.85)
	plain.metallic = 0.6
	plain.roughness = 0.2
	var swapped: Array = []
	for p in props:
		for mi in (p as Node).find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			for i in m.get_surface_override_material_count():
				var om := m.get_surface_override_material(i)
				if om is ShaderMaterial and (om as ShaderMaterial).shader != null \
						and str((om as ShaderMaterial).shader.resource_path).ends_with("csplab_mirror.gdshader"):
					swapped.append([m, i, om])
					m.set_surface_override_material(i, plain)
	await _wait(tree, 0.5)
	var plain_ms := await _gpu_ms(tree)
	for s in swapped:
		(s[0] as MeshInstance3D).set_surface_override_material(int(s[1]), s[2] as Material)
	for p in props:
		(p as Node3D).visible = false
	await _wait(tree, 0.5)
	var hidden := await _gpu_ms(tree)
	for p in props:
		(p as Node3D).visible = true
	print("cspbench GPU: shown %.2f ms · mirrors plain %.2f ms · hidden %.2f ms (%d mirror surfaces) → concentrators %.2f ms, mirror shader %.2f ms" % [
		shown, plain_ms, hidden, swapped.size(), shown - hidden, shown - plain_ms])
	main.call("pop_camera_claim", "csp_bench")
	cam.queue_free()


func _gpu_ms(tree: SceneTree) -> float:
	var rid := tree.root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var v: Array = []
	for i in 60:
		await tree.process_frame
		v.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	v.sort()
	return float(v[v.size() / 2])


func _sample(tree: SceneTree, pm: Node) -> Dictionary:
	var acc := {}
	var peak := {}
	var frames: Array = []
	var frame_peak := 0.0
	var n := int(SAMPLE_S / SAMPLE_DT)
	for i in n:
		await _wait(tree, SAMPLE_DT)
		var snap: Dictionary = pm.call("snapshot")
		var sec: Dictionary = snap.get("sections_ms", {})
		var pk: Dictionary = snap.get("sections_peak_ms", {})
		for s in sec.keys():
			acc[s] = float(acc.get(s, 0.0)) + float(sec[s])
			peak[s] = maxf(float(peak.get(s, 0.0)), float(pk.get(s, 0.0)))
		frames.append(float(snap.get("frame_ms", 0.0)))
		frame_peak = maxf(frame_peak, float(snap.get("frame_ms_peak", 0.0)))
	frames.sort()
	for s in acc.keys():
		acc[s] = float(acc[s]) / float(n)
	return {"acc": acc, "peak": peak, "frame": frames[frames.size() / 2], "frame_peak": frame_peak}


func _print(label: String, s: Dictionary) -> void:
	print("cspbench %s: frame %.1f ms (median) / %.1f ms (peak)" % [label, float(s["frame"]), float(s["frame_peak"])])
	var acc: Dictionary = s["acc"]
	var peak: Dictionary = s["peak"]
	for key in SECTIONS:
		if acc.has(key) or peak.has(key):
			print("cspbench %s: %-12s avg %6.3f ms · peak %7.2f ms" % [label, key, float(acc.get(key, 0.0)), float(peak.get(key, 0.0))])


func _prop_ids(main: Node) -> Array:
	var out: Array = []
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("placed_prop_records"):
		for r in loader.call("placed_prop_records"):
			out.append(str((r as Dictionary).get("id", "")))
	return out


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout
