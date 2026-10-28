extends SceneTree
## Slice an STL headless and print what the slicer made per setting — the
## numbers behind "it only prints part of the height":
##   Godot --headless --path . --script tools/diag/slice_probe.gd -- --stl=<path> [--scale=1] [--line=6] [--layer=0.8] [--infill=0,20] [--walls=2]
## Prints per infill: layers, the top layer reached, moves, roads, ms, warnings.


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var path := str(args.get("stl", ""))
	var t0 := Time.get_ticks_msec()
	var tris := StlLoader.load_triangles(path)
	print("slice-probe: %d triangles read in %d ms" % [tris.size(), Time.get_ticks_msec() - t0])
	if tris.is_empty():
		quit(1)
		return
	for inf in str(args.get("infill", "0,20")).split(","):
		var s := {
			"scale": float(args.get("scale", "1")), "line_width_mm": float(args.get("line", "6")),
			"layer_height_mm": float(args.get("layer", "0.8")), "infill_pct": float(inf),
			"walls": int(args.get("walls", "2")), "filament_mm": float(args.get("line", "6")),
			"centre_xy": Vector2(300, 300),
		}
		if args.has("pattern"):
			s["infill_pattern"] = str(args["pattern"])
		t0 = Time.get_ticks_msec()
		var p := StlSlicer.slice_triangles(tris, s)
		var ms := Time.get_ticks_msec() - t0
		if not bool(p.get("ok", false)):
			print("slice-probe infill %s: FAILED %s" % [inf, str(p.get("error"))])
			continue
		var moves: PrintMoves = p["moves"]
		var top := 0.0
		for i in moves.size():
			if moves.e[i] > 0.0:
				top = maxf(top, moves.p1[i].z)
		var mm: Vector3 = p["model_max"]
		print("slice-probe infill %s%%: %d layers, top road at %.1f of %.1f mm (%.0f %%), %d moves, %.1f m of road, %d ms, warnings %s" % [
			inf, int(p["layers"]), top, mm.z, 100.0 * top / maxf(mm.z, 1e-6), moves.size(), float(p["road_mm"]) / 1000.0, ms, str(p["warnings"])])
		if args.has("plan"):
			t0 = Time.get_ticks_msec()
			var job := PrintJob.from_parse(p, {"machine_kind": "trash", "filament_diameter_mm": float(args.get("line", "6"))})
			print("slice-probe   planned %s in %d ms, memory %d MB" % [GantryLabMotion.fmt_duration(float(job.get("total_s", 0.0))), Time.get_ticks_msec() - t0, OS.get_static_memory_usage() / 1048576])
			t0 = Time.get_ticks_msec()
			var roads := PrintRoads.new()
			roads.lay(job["moves"], float(args.get("line", "6")), float(args.get("layer", "0.8")), Color.WHITE)
			print("slice-probe   laid %d roads (merged %s) in %d ms" % [roads.road_count(), str(roads.is_merged()), Time.get_ticks_msec() - t0])
			t0 = Time.get_ticks_msec()
			roads.set_progress_frac(1.0)
			roads.set_progress_frac(0.5)
			print("slice-probe   show all + half in %d ms" % (Time.get_ticks_msec() - t0))
			roads.free()
	quit(0)
