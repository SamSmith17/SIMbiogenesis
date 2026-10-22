extends RefCounted

## Frame cost of the rain + stream systems at speed (sandbox, a world with
## streams â€” Bombay Beach is w6ad922917357):
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/bench/stream_rain_bench.gd -Label stream_bench
## Three phases, each at 600x with the graph closed and "dry between storms" on:
##   A  a Rain-tool storm (100 mm/h, an hour, 400 m circle at the head of the
##      longest stream) â€” the front, erosion and its re-carves;
##   B  the same with a basin dug across the stream (the fill-and-spill series);
##   C  weather rain: Tropical Storm Hilary, 2023-08-20 10:00 on.
## Per phase: frame-time p50 / p95 / max, frames over 50 and 100 ms, every
## water_* section's average and worst 2 s peak, and (from a camera over the
## stream) the frames whose picture went black â€” the "flash". Prints
## `wbench â€¦` lines.

var SPEED_X := 600.0
const PHASE_S := 25.0
const SECTIONS := ["water_poll", "water_hist", "water_basins", "water_remesh",
	"water_states", "water_mesh_build", "water_remesh_prep", "water_remesh_swap", "water_erosion", "water_carve_apply",
	"water_carve_commit", "water_carve_reground", "water_carve_areas",
	"water_drain_apply", "water_storm_areas", "water_find_basins", "terrain_tiles", "terrain_tick",
	"main_fx", "solar_ui", "flow_engine"]
const GW := 48
const GH := 27

var _cam: Camera3D
var _rebuilt := 0
var _dir := "user://screenshots/stream_bench"
var _saved := 0


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _settle(main: Node, wn: Node) -> void:
	var tree := main.get_tree()
	await _frames(tree, 20)
	var t0 := Time.get_ticks_msec()
	while (bool(wn.call("is_busy")) or bool(wn.get("_drain_pending")) or int(wn.get("_drain_task")) >= 0) \
			and Time.get_ticks_msec() - t0 < 90000:
		await tree.process_frame
	await _frames(tree, 30)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if OS.get_environment("WBENCH_X") != "":
		SPEED_X = float(OS.get_environment("WBENCH_X"))
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var wn: Node = loader.call("water_network")
	wn.connect("network_rebuilt", func() -> void: _rebuilt += 1)
	if _harness != null and "shots_dir" in _harness and str(_harness.get("shots_dir")).begins_with("user://"):
		_dir = str(_harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	wn.call("set_display_mode", "all")
	wn.call("set_dry_between_storms", true)
	main.set("time_scale", 0.0)
	main.set("day_time", 13.0)
	await _settle(main, wn)
	var feats: Array = wn.call("features")
	var f: Dictionary = feats[0]
	for g in feats:
		if StreamNetwork.polyline_length((g as Dictionary)["points"]) > StreamNetwork.polyline_length(f["points"]):
			f = g
	var prof: Dictionary = wn.call("profile", str(f["id"]))
	var ppts: PackedVector2Array = prof["points"]
	var head := ppts[mini(ppts.size() - 1, int(ppts.size() * 0.08))]
	var mid := ppts[mini(ppts.size() - 1, int(ppts.size() * 0.3))]
	var gy := float(loader.call("ground_height_at", mid.x, mid.y))
	_cam = Camera3D.new()
	_cam.far = 4000.0
	main.add_child(_cam)
	_cam.global_position = Vector3(mid.x - 120.0, gy + 70.0, mid.y + 120.0)
	_cam.look_at(Vector3(mid.x, gy, mid.y), Vector3.UP)
	main.call("push_camera_claim", "wbench", {"camera_id": _cam.get_instance_id()})
	print("wbench: %d features, stream %s %.0f m, %d stations" % [feats.size(), f["id"],
		StreamNetwork.polyline_length(f["points"]), ppts.size()])
	if pm != null:
		pm.call("set_enabled", true)

	if OS.get_environment("WBENCH_ONLY") == "E":
		main.call("pop_camera_claim", "wbench")
		await _flash_hunt(main, tree)
		return {"ok": true}
	await _redrape_probe(main, loader, tree)
	if OS.get_environment("WBENCH_ONLY") == "D":
		main.call("pop_camera_claim", "wbench")
		return {"ok": true}
	# A: a storm.
	var circle := PackedVector2Array()
	for k in 32:
		var a := TAU * float(k) / 32.0
		circle.append(head + Vector2(cos(a), sin(a)) * 400.0)
	var t0 := float(wn.call("_now_h"))
	wn.call("add_storm", circle, 100.0, t0 + 0.02, t0 + 1.02)
	await _phase("A_storm", main, pm, tree)

	# B: a basin across the stream, then the same storm again (on the beds as
	# drawn — Reset erosion — so the bowl is deeper than the channel).
	main.set("time_scale", 0.0)
	wn.call("reset_erosion")
	await _settle(main, wn)
	var at := ChannelProfile.station_index(prof, 1500.0)
	var c := ppts[at]
	var poly := PackedVector2Array([c + Vector2(-12.5, -12.5), c + Vector2(12.5, -12.5),
		c + Vector2(12.5, 12.5), c + Vector2(-12.5, 12.5)])
	loader.call("pond_command", poly, 3.5, "Bench swale", 0.85, false)
	await _settle(main, wn)
	print("wbench: basins %d" % (wn.call("basins") as Dictionary).size())
	var t1 := float(wn.call("_now_h"))
	wn.call("add_storm", circle, 100.0, t1 + 0.02, t1 + 1.02)
	await _phase("B_basin", main, pm, tree)

	# C: weather rain (Hilary).
	main.set("time_scale", 0.0)
	wn.call("clear_storms")
	var ws: Node = main.get_node_or_null("/root/WeatherService")
	main.set("year", 2023)
	main.set("month", 8)
	main.set("day", 20)
	main.set("day_time", 10.0)
	if ws != null:
		ws.call("notify_location_changed", float(main.get("latitude")), float(main.get("longitude")))
		var waited := 0.0
		while waited < 90.0 and not (int(ws.get("_data_year")) == 2023 and not bool(ws.get("_fetching"))):
			await tree.create_timer(0.5).timeout
			waited += 0.5
		print("wbench: 2023 weather %s (%.0f s), rain at 12:00 %.1f mm/h" % [
			"loaded" if int(ws.get("_data_year")) == 2023 else "MISSING", waited,
			float(ws.call("rain_rate_mmh", 8, 20, 12.0))])
	await _settle(main, wn)
	await _phase("C_weather", main, pm, tree)

	main.set("time_scale", 0.0)
	main.call("pop_camera_claim", "wbench")
	_cam.queue_free()
	if pm != null:
		pm.call("set_enabled", false)
	return {"ok": true}


func _phase(label: String, main: Node, pm: Node, tree: SceneTree) -> void:
	main.set("time_scale", SPEED_X / 3600.0)
	var frames := PackedFloat32Array()
	var acc := {}
	var peak := {}
	var n_snap := 0
	var slow := {}
	var black := 0
	var black_at: Array = []
	var prev_grid := PackedFloat32Array()
	var watch_until := -1
	var seen_rebuilt := _rebuilt
	var start := Time.get_ticks_usec()
	var last := start
	var next_snap := 0.25
	var next_lum := 0
	var fi := 0
	var vp := main.get_viewport()
	while float(Time.get_ticks_usec() - start) / 1e6 < PHASE_S:
		await tree.process_frame
		var now := Time.get_ticks_usec()
		var fms := float(now - last) / 1000.0
		frames.append(fms)
		last = now
		if fms > 80.0 and pm != null:
			var lf: Dictionary = pm.get("last_frame")
			var top: Array = []
			for k in lf.keys():
				if float(lf[k]) >= 5.0:
					top.append("%s %.0f" % [k, float(lf[k])])
			var r: Dictionary = (pm.call("render_snapshot") as Dictionary)
			var key := " | ".join(PackedStringArray(top)) if not top.is_empty() \
				else "(no section) gpu %.0f" % float(r.get("render_gpu_ms", 0.0))
			slow[key] = int(slow.get(key, 0)) + 1
		fi += 1
		var el := float(now - start) / 1e6
		if pm != null and el >= next_snap:
			next_snap += 0.25
			n_snap += 1
			var snap: Dictionary = pm.call("snapshot")
			var sec: Dictionary = snap.get("sections_ms", {})
			var pk: Dictionary = snap.get("sections_peak_ms", {})
			for s in SECTIONS:
				acc[s] = float(acc.get(s, 0.0)) + float(sec.get(s, 0.0))
				peak[s] = maxf(float(peak.get(s, 0.0)), float(pk.get(s, 0.0)))
		# The picture: every frame for 40 frames after a carve lands, else every
		# 3rd (a readback stalls; the frame clock restarts after it). A flash is
		# a region going dark: ≥ 3 % of a 48×27 grid dropping under 40 % of the
		# previous sample.
		if _rebuilt != seen_rebuilt:
			seen_rebuilt = _rebuilt
			watch_until = fi + 40
		if OS.get_environment("WBENCH_NOREAD") != "1" and (fi >= next_lum or fi <= watch_until):
			next_lum = fi + 3
			var full := vp.get_texture().get_image()
			var img := full.duplicate() as Image
			img.resize(GW, GH, Image.INTERPOLATE_BILINEAR)
			var grid := PackedFloat32Array()
			grid.resize(GW * GH)
			for y in GH:
				for x in GW:
					var col := img.get_pixel(x, y)
					grid[y * GW + x] = col.r * 0.2126 + col.g * 0.7152 + col.b * 0.0722
			if prev_grid.size() == grid.size():
				var dark := 0
				for k in grid.size():
					if prev_grid[k] > 0.06 and grid[k] < prev_grid[k] * 0.4:
						dark += 1
				if dark >= int(0.03 * GW * GH):
					black += 1
					black_at.append("%.1fs %d cells%s" % [el, dark, " (after carve)" if fi <= watch_until else ""])
					if _saved < 6:
						_saved += 1
						full.save_png("%s/flash_%s_%d.png" % [_dir, label, _saved])
			prev_grid = grid
			last = Time.get_ticks_usec()
	main.set("time_scale", 0.0)
	var sorted := frames.duplicate()
	sorted.sort()
	var over50 := 0
	var over100 := 0
	for v in frames:
		if v > 50.0:
			over50 += 1
		if v > 100.0:
			over100 += 1
	var n := sorted.size()
	print("wbench %s: %d frames, p50 %.1f ms, p95 %.1f ms, max %.1f ms, >50ms %d, >100ms %d, sim %.2f h" % [
		label, n, sorted[n / 2], sorted[int(n * 0.95)], sorted[n - 1], over50, over100,
		PHASE_S * SPEED_X / 3600.0])
	for s in SECTIONS:
		if n_snap > 0 and (float(acc.get(s, 0.0)) > 0.0 or float(peak.get(s, 0.0)) > 0.0):
			print("wbench %s:   %-18s avg %6.2f ms   peak %7.1f ms" % [label, s,
				float(acc[s]) / n_snap, float(peak[s])])
	var keys := slow.keys()
	for k in keys.slice(0, 14):
		print("wbench %s:   slow frame: %s" % [label, k])
	print("wbench %s: dark flashes %d %s, carves landed %d" % [label, black, str(black_at.slice(0, 8)), _rebuilt])


## D: what a still-water re-drape (TerrainLoader._attach_water, which every
## channel re-carve used to queue) does to the picture: the camera on the
## largest lake, the re-drape, then every frame for 45 frames — the share of a
## 48x27 grid that went dark against the frame before it.
func _redrape_probe(main: Node, loader: Node, tree: SceneTree) -> void:
	var water := loader.get("_water_root") as Node3D
	var best: ReflectionProbe = null
	if water != null:
		for p in water.find_children("*", "ReflectionProbe", true, false):
			var rp := p as ReflectionProbe
			if best == null or rp.size.x * rp.size.z > best.size.x * best.size.z:
				best = rp
	if best == null:
		print("wbench D_redrape: no lake probe")
		return
	var c := best.global_position
	var bsize := best.size
	var gy := c.y - bsize.y * 0.5
	var saved := _cam.global_transform
	_cam.global_position = Vector3(c.x + 260.0, gy + 60.0, c.z + 260.0)
	_cam.look_at(Vector3(c.x, gy, c.z), Vector3.UP)
	await _frames(tree, 90)
	var vp := main.get_viewport()
	var prev := _grid(vp.get_texture().get_image())
	loader.call("_attach_water")
	var worst := 0
	var worst_f := -1
	for f in 45:
		await tree.process_frame
		var full := vp.get_texture().get_image()
		var g := _grid(full)
		var dark := 0
		for k in g.size():
			if prev[k] > 0.06 and g[k] < prev[k] * 0.4:
				dark += 1
		if dark > worst:
			worst = dark
			worst_f = f
			full.save_png("%s/redrape_worst.png" % _dir)
		if f == 0:
			full.save_png("%s/redrape_f0.png" % _dir)
		prev = g
	print("wbench D_redrape: lake probe %.0f x %.0f m, worst frame %d with %d of %d cells gone dark" % [
		bsize.x, bsize.z, worst_f, worst, GW * GH])
	_cam.global_transform = saved


func _grid(full: Image) -> PackedFloat32Array:
	var img := full.duplicate() as Image
	img.resize(GW, GH, Image.INTERPOLATE_BILINEAR)
	var grid := PackedFloat32Array()
	grid.resize(GW * GH)
	for y in GH:
		for x in GW:
			var col := img.get_pixel(x, y)
			grid[y * GW + x] = col.r * 0.2126 + col.g * 0.7152 + col.b * 0.0722
	return grid


## E: first person through Hilary (2023-08-20 08:00 on) at 600x, EVERY frame
## read back and compared with the one before: frames where a region went
## dark (and came back) are saved with the frame before them.
func _flash_hunt(main: Node, tree: SceneTree) -> void:
	var ws: Node = main.get_node_or_null("/root/WeatherService")
	main.set("time_scale", 0.0)
	main.set("year", 2023)
	main.set("month", 8)
	main.set("day", 20)
	main.set("day_time", 8.0)
	if ws != null:
		ws.call("notify_location_changed", float(main.get("latitude")), float(main.get("longitude")))
		var waited := 0.0
		while waited < 90.0 and not (int(ws.get("_data_year")) == 2023 and not bool(ws.get("_fetching"))):
			await tree.create_timer(0.5).timeout
			waited += 0.5
	await _frames(tree, 120)
	var vp := main.get_viewport()
	main.set("time_scale", SPEED_X / 3600.0)
	var prev := PackedFloat32Array()
	var prev_img: Image = null
	var start := Time.get_ticks_msec()
	var n := 0
	var hits := 0
	var mean_lo := 9.0
	var mean_hi := 0.0
	var heavy := OS.get_environment("WBENCH_HEAVY") == "1"
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var keys: Array = []
	if heavy:
		var ch: Object = loader.call("channel_tile_layer")
		keys = ch.call("active_tiles") if ch != null else []
		print("wbench E_flash: replaying the old full re-carve side effects every 3 s (%d tiles)" % keys.size())
	var next_heavy := 3000
	var hunt_ms := int(OS.get_environment("WBENCH_HUNT_S")) * 1000 if OS.get_environment("WBENCH_HUNT_S") != "" else 40000
	# A FLASH: frame k is darker than k-1 over a region AND frame k+1 is back
	# up over that region — a dusk or a cloud is a ramp, not a blink.
	var pend := PackedInt32Array()
	var pend_img: Image = null
	var pend_prev: Image = null
	var pend_h := 0.0
	var pend_ref := PackedFloat32Array()
	while Time.get_ticks_msec() - start < hunt_ms:
		await tree.process_frame
		n += 1
		if heavy and Time.get_ticks_msec() - start >= next_heavy:
			next_heavy += 3000
			loader.call("commit_channel_tiles", keys)
			loader.call("on_channels_carved", keys, false)
		var full := vp.get_texture().get_image()
		var g := _grid(full)
		var mean := 0.0
		for v in g:
			mean += v
		mean /= float(g.size())
		mean_lo = minf(mean_lo, mean)
		mean_hi = maxf(mean_hi, mean)
		if not pend.is_empty():
			var back := 0
			for k in pend:
				if g[k] > pend_ref[k] * 0.6:
					back += 1
			if back >= int(pend.size() * 0.6):
				hits += 1
				print("wbench E_flash: FLASH at frame %d, %.2f h — %d cells dark for one frame" % [
					n - 1, pend_h, pend.size()])
				if hits <= 4:
					pend_img.save_png("%s/flash_%d.png" % [_dir, hits])
					if pend_prev != null:
						pend_prev.save_png("%s/flash_%d_before.png" % [_dir, hits])
					full.save_png("%s/flash_%d_after.png" % [_dir, hits])
			pend = PackedInt32Array()
		if prev.size() == g.size():
			var dark := PackedInt32Array()
			for k in g.size():
				if prev[k] > 0.05 and g[k] < prev[k] * 0.45:
					dark.append(k)
			if dark.size() >= 20:
				pend = dark
				pend_ref = prev
				pend_img = full
				pend_prev = prev_img
				pend_h = float(main.get("day_time"))
		prev = g
		prev_img = full
	main.set("time_scale", 0.0)
	print("wbench E_flash: %d frames, %d flashes, mean luminance %.3f..%.3f, ended %.2f h" % [
		n, hits, mean_lo, mean_hi, float(main.get("day_time"))])
