extends RefCounted

## Sandbox: what a stream re-carve costs on the main thread when only erosion
## moved. Waits a minute after load (the channels erode a few mm), then asks
## the WaterNetwork for a rebuild with the same inputs (as a water re-drape or
## any tile edit does) and prints the carve apply's sections (PerfSpan
## water_carve_apply / _reground / _areas, water_drain_apply) and the worst
## frame until the network is idle again, three times.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/carve_light_probe.gd -Timeout 900

const SECTIONS := ["water_carve_apply", "water_carve_reground", "water_carve_areas",
	"water_drain_apply", "water_find_basins"]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var net: Node = loader.find_child("WaterNetwork", true, false) if loader != null else null
	if net == null:
		return {"ok": false, "why": "no WaterNetwork"}
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if pm != null:
		pm.call("set_enabled", true)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		await tree.process_frame
	for rep in 3:
		while bool(net.call("is_busy")):
			await tree.process_frame
		var worst := {}
		var w_frame := 0.0
		net.set("_inputs_sig", 0)
		net.call("request_rebuild", false)
		# 40 s covers the carve, the apply and a drainage run it may ask for.
		t0 = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 40000:
			await tree.process_frame
			var lf: Dictionary = pm.get("last_frame") if pm != null else {}
			for s in SECTIONS:
				worst[s] = maxf(float(worst.get(s, 0.0)), float(lf.get(s, 0.0)))
			w_frame = maxf(w_frame, float(pm.get("last_frame_ms")) if pm != null else 0.0)
		var line := "carvelight rep %d: worst frame %.1f ms" % [rep, w_frame]
		for s in SECTIONS:
			line += ", %s %.1f" % [s, float(worst.get(s, 0.0))]
		print(line)
	# An ordinary rebuild request (what a water re-drape or a tile edit sends):
	# with only erosion moved it must not re-carve at all.
	while bool(net.call("is_busy")):
		await tree.process_frame
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 30000:
		await tree.process_frame
	var sigs0: Dictionary = (net.get("_sigs") as Dictionary).duplicate()
	net.call("request_rebuild", false)
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 20000:
		await tree.process_frame
	var same := sigs0 == (net.get("_sigs") as Dictionary)
	print("carvelight plain request after 30 s of erosion: %s" % ("no re-carve" if same else "RE-CARVED"))
	if pm != null:
		pm.call("set_enabled", false)
	return {"ok": true}
