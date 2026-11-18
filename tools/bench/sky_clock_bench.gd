extends RefCounted

## Sandbox, read-only: what the sky shader's use of TIME costs. A sky shader
## that reads TIME has its radiance (the reflections and ambient from the sky)
## marked dirty by Godot every frame, so in INCREMENTAL mode the cubemap is
## re-rendered every frame even with nothing in the sky moving. Measures the
## renderer's GPU time at noon and at 23:00, clock paused and running at 60x,
## with the shader as shipped and with TIME replaced by 0.0 (a variant built
## at run time; nothing is saved), alternating twice so drift averages out.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/sky_clock_bench.gd -Timeout 900

const SETTLE_S := 1.5
const SAMPLE_S := 3.0


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	for _i in 240:
		await tree.process_frame
	var we = main.get("environment")
	var env: Environment = (we as WorldEnvironment).environment if we is WorldEnvironment else null
	if env == null or env.sky == null or not (env.sky.sky_material is ShaderMaterial):
		return {"ok": false, "why": "no sky shader material"}
	var mat := env.sky.sky_material as ShaderMaterial
	var ship: Shader = mat.shader
	var code := ship.code
	var n_time := code.count("TIME")
	var vcode := code.replace("TIME", "0.0")
	var variant := Shader.new()
	variant.code = vcode
	print("skyclock: process mode %d, radiance %d, %d TIME use(s) in the shader" % [
		int(env.sky.process_mode), int(env.sky.radiance_size), n_time])
	var vp := main.get_viewport()
	var rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var clock: Object = main.get("clock")
	var ts0 := float(main.get("time_scale"))
	var dt0 := float(clock.get("day_time")) if clock != null else 12.0
	var rows := {}
	for hour in [12.0, 23.0]:
		for speed in [0.0, 60.0 / 3600.0]:
			for rep in 2:
				for vid in ["ship", "no_time"]:
					mat.shader = ship if vid == "ship" else variant
					if clock != null:
						clock.set("day_time", hour)
					main.set("time_scale", speed)
					await _wait(tree, SETTLE_S)
					var g := await _sample(tree, rid)
					var key := "%02d h %s %s" % [int(hour), "paused" if speed == 0.0 else "60x", vid]
					var a: Array = rows.get(key, [])
					a.append(g)
					rows[key] = a
	mat.shader = ship
	main.set("time_scale", ts0)
	if clock != null:
		clock.set("day_time", dt0)
	var keys := rows.keys()
	keys.sort()
	for k in keys:
		var a: Array = rows[k]
		var m := 0.0
		for v in a:
			m += float(v)
		print("skyclock: %-24s GPU %.2f ms (runs %s)" % [k, m / a.size(), str(a)])
	return {"ok": true}


func _sample(tree: SceneTree, rid: RID) -> float:
	var gpu: Array = []
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(SAMPLE_S * 1000.0):
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	gpu.sort()
	return snappedf(float(gpu[gpu.size() / 2]), 0.01)


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout
