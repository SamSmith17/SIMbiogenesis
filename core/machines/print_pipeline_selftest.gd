extends SceneTree

## The print pipeline, offline: the slicer's geometry (every layer of a cube
## closes, a tube keeps its hole, walls are a line width apart, infill
## density lands near the dial, top / bottom layers are solid, a vase is one
## monotone spiral, the model is centred where asked, a turn turns it), the
## material book-keeping (E = w·h·L / bore area, so the job's volume IS the
## road laid), the G-code writer round-tripping through GantryLabGcode in
## both dialects, PrintJob on a sliced parse and on an old point list, the
## planner's time beating the naive length / feed figure, MachineJobStore v2
## (binary moves, written to the real jobs folder and deleted), and
## PrintJobPlayer sampling the plan (progress 0 at the start, 1 at the end,
## layers counted, a move's road grown under the nozzle in PrintRoads).
##
## Carries EXPECTED_CHECKS: a runtime error aborts a test function while PASS
## still prints.
##
##   Godot.exe.exe --headless --path . --script core/machines/print_pipeline_selftest.gd

const EXPECTED_CHECKS := 82

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_test_slicer_cube()
	_test_slicer_tube()
	_test_slicer_vase()
	_test_slicer_placement()
	_test_gcode_round_trip()
	_test_print_job()
	_test_job_store_and_player()
	_test_roads()
	print("")
	if _checks != EXPECTED_CHECKS:
		print("PRINT PIPELINE SELFTEST: ran %d checks, expected %d (a runtime error aborted a test?)" % [_checks, EXPECTED_CHECKS])
		_fails += 1
	if _fails == 0:
		print("PRINT PIPELINE SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("PRINT PIPELINE SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: %s %s" % [label, detail])


func _approx(v: float, lo: float, hi: float) -> bool:
	return v >= lo and v <= hi


# ---------------------------------------------------------------------------
# Fixtures (triangles with outward winding, mm, Z up)
# ---------------------------------------------------------------------------

static func box(size: Vector3, origin: Vector3) -> Array:
	var v := []
	for z in [0.0, size.z]:
		for y in [0.0, size.y]:
			for x in [0.0, size.x]:
				v.append(origin + Vector3(x, y, z))
	var f := [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
	var tris := []
	for q in f:
		tris.append([v[q[0]], v[q[1]], v[q[2]]])
		tris.append([v[q[0]], v[q[2]], v[q[3]]])
	return tris


static func tube(r_out: float, r_in: float, h: float, n: int) -> Array:
	var tris := []
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var o0 := Vector3(cos(a0) * r_out, sin(a0) * r_out, 0)
		var o1 := Vector3(cos(a1) * r_out, sin(a1) * r_out, 0)
		var i0 := Vector3(cos(a0) * r_in, sin(a0) * r_in, 0)
		var i1 := Vector3(cos(a1) * r_in, sin(a1) * r_in, 0)
		var up := Vector3(0, 0, h)
		tris.append([o0, o1, o1 + up])
		tris.append([o0, o1 + up, o0 + up])
		tris.append([i1, i0, i0 + up])
		tris.append([i1, i0 + up, i1 + up])
		tris.append([o1, o0, i0])
		tris.append([o1, i0, i1])
		tris.append([o0 + up, o1 + up, i1 + up])
		tris.append([o0 + up, i1 + up, i0 + up])
	return tris


static func _layer_moves(moves: Array, z: float, tol := 0.05) -> Array:
	var out := []
	for m in moves:
		if float(m["e_mm"]) > 0.0 and absf(float((m["p1"] as Vector3).z) - z) < tol:
			out.append(m)
	return out


static func _road_len(moves: Array) -> float:
	var l := 0.0
	for m in moves:
		if float(m["e_mm"]) > 0.0:
			l += (m["p0"] as Vector3).distance_to(m["p1"] as Vector3)
	return l


# ---------------------------------------------------------------------------

func _test_slicer_cube() -> void:
	var s := {"layer_height_mm": 0.2, "line_width_mm": 0.5, "walls": 2, "infill_pct": 20.0,
		"top_layers": 3, "bottom_layers": 3, "print_speed_mm_s": 50.0, "travel_speed_mm_s": 150.0,
		"centre_xy": Vector2(100.0, 100.0), "filament_mm": 1.75}
	var r := StlSlicer.slice_triangles(box(Vector3(20, 20, 10), Vector3(7, -3, 2)), s)
	_check("cube slices", bool(r.get("ok", false)), str(r.get("error", "")))
	if not bool(r.get("ok", false)):
		return
	var moves: Array = r["moves"]
	_check("cube: 50 layers at 0.2 mm", int(r["layers"]) == 50, str(r["layers"]))
	_check("cube: layer starts match", (r["layer_starts"] as PackedInt32Array).size() == 50)
	var bmin: Vector3 = r["bounds_min"]
	var bmax: Vector3 = r["bounds_max"]
	# The outer wall's centreline is half a line in from the model's edge.
	_check("cube: outer wall centreline ½ w inside the edge", absf(bmin.x - 90.25) < 0.02 and absf(bmax.x - 109.75) < 0.02, "%s %s" % [bmin, bmax])
	_check("cube: first nozzle Z = one layer, last = the top", absf(bmin.z - 0.2) < 1e-4 and absf(bmax.z - 10.0) < 1e-4, "%s %s" % [bmin.z, bmax.z])
	# A middle layer: two walls then sparse infill; a bottom layer: solid.
	var mid := _layer_moves(moves, 5.0)
	var walls_len := 0.0
	var infill_len := 0.0
	for m in mid:
		var p1: Vector3 = m["p1"]
		var on_wall := absf(absf(p1.x - 100.0) - 9.75) < 0.01 or absf(absf(p1.y - 100.0) - 9.75) < 0.01 \
			or absf(absf(p1.x - 100.0) - 9.25) < 0.01 or absf(absf(p1.y - 100.0) - 9.25) < 0.01
		var l := (m["p0"] as Vector3).distance_to(p1)
		if on_wall:
			walls_len += l
		else:
			infill_len += l
	_check("cube mid layer: two walls = 78 + 74 mm", _approx(walls_len, 150.0, 154.0), "%.1f" % walls_len)
	# Infill region 18 × 18 mm at 20 %: lines 2.5 mm apart ≈ 18²·0.2/0.5 = 130 mm of road.
	_check("cube mid layer: 20 % infill ≈ 130 mm", _approx(infill_len, 100.0, 160.0), "%.1f" % infill_len)
	var bot := _layer_moves(moves, 0.2)
	var bot_len := _road_len(bot)
	# Solid: 18 × 18 / 0.5 = 648 mm of infill + 152 of walls.
	_check("cube bottom layer: solid ≈ 800 mm", _approx(bot_len, 700.0, 860.0), "%.1f" % bot_len)
	var top := _layer_moves(moves, 10.0)
	_check("cube top layer: solid", _approx(_road_len(top), 700.0, 860.0), "%.1f" % _road_len(top))
	# Material: the job's volume IS the road laid × w × h, and E is in bore mm.
	var road := float(r["road_mm"])
	var e := float(r["extrusion_mm"])
	var area := PI * 1.75 * 1.75 * 0.25
	_check("cube: E × bore area = w·h·road", absf(e * area - road * 0.5 * 0.2) < road * 0.5 * 0.2 * 1e-3, "%.2f vs %.2f" % [e * area, road * 0.1])
	_check("cube: volume_mm3 = w·h·road", absf(float(r["volume_mm3"]) - road * 0.1) < 1e-3)
	_check("cube: solid volume 20·20·10 = 4000 mm³", absf(float(r["solid_volume_mm3"]) - 4000.0) < 1.0, str(r["solid_volume_mm3"]))
	# Infill is sparser than solid: the whole print is well under the solid body.
	_check("cube: 20 % infill prints a fraction of the body", float(r["volume_mm3"]) < 4000.0 and float(r["volume_mm3"]) > 1500.0, str(r["volume_mm3"]))
	# Alternate layers turn the infill a quarter: directions differ.
	var l10 := _layer_moves(moves, 2.0)
	var l11 := _layer_moves(moves, 2.2)
	var d10 := Vector2.ZERO
	var d11 := Vector2.ZERO
	for m in l10:
		var d := (m["p1"] as Vector3) - (m["p0"] as Vector3)
		if absf(absf(d.x) - absf(d.y)) < 0.01 * d.length():
			d10 = Vector2(d.x, d.y).normalized()
			break
	for m in l11:
		var d := (m["p1"] as Vector3) - (m["p0"] as Vector3)
		if absf(absf(d.x) - absf(d.y)) < 0.01 * d.length():
			d11 = Vector2(d.x, d.y).normalized()
			break
	_check("cube: infill turns a quarter each layer", d10 != Vector2.ZERO and d11 != Vector2.ZERO and absf(d10.dot(d11)) < 0.05, "%s %s" % [d10, d11])
	# Every move is contiguous (p1 of one = p0 of the next).
	var contiguous := true
	for i in range(1, moves.size()):
		if ((moves[i] as Dictionary)["p0"] as Vector3).distance_to((moves[i - 1] as Dictionary)["p1"] as Vector3) > 2e-3:
			contiguous = false
			break
	_check("cube: moves are contiguous", contiguous)
	# Travels are rapid at the travel speed; roads at the print speed (layer 0 at half).
	var ok_speed := true
	for m in moves:
		var p1: Vector3 = m["p1"]
		if float(m["e_mm"]) > 0.0:
			var want := 25.0 if p1.z < 0.3 else 50.0
			if absf(float(m["feed_mm_s"]) - want) > 1e-3:
				ok_speed = false
		elif absf(float(m["feed_mm_s"]) - 150.0) > 1e-3 or not bool(m["rapid"]):
			ok_speed = false
	_check("cube: print / travel / first-layer speeds", ok_speed)


func _test_slicer_tube() -> void:
	var r := StlSlicer.slice_triangles(tube(15.0, 10.0, 8.0, 72), {"layer_height_mm": 0.4, "line_width_mm": 0.6, "walls": 2, "infill_pct": 30.0, "top_layers": 2, "bottom_layers": 2})
	_check("tube slices", bool(r.get("ok", false)), str(r.get("error", "")))
	if not bool(r.get("ok", false)):
		return
	var moves: Array = r["moves"]
	_check("tube: 20 layers", int(r["layers"]) == 20, str(r["layers"]))
	var mid := _layer_moves(moves, 4.0)
	var inside := 0
	var outside := 0
	var inner_wall := 0.0
	var outer_wall := 0.0
	for m in mid:
		var p1: Vector3 = m["p1"]
		var rr := Vector2(p1.x, p1.y).length()
		if rr < 10.0 - 0.6 * 2.0 + 0.3:
			inside += 1
		if rr > 15.0 + 0.3:
			outside += 1
		var l := (m["p0"] as Vector3).distance_to(p1)
		if absf(rr - 10.3) < 0.05:
			inner_wall += l
		elif absf(rr - 14.7) < 0.05:
			outer_wall += l
	_check("tube: nothing inside the hole", inside == 0, str(inside))
	_check("tube: nothing outside the wall", outside == 0, str(outside))
	_check("tube: outer wall ½ w in (r 14.7) ≈ 2π·14.7", _approx(outer_wall, 90.0, 93.5), "%.1f" % outer_wall)
	_check("tube: hole wall ½ w out (r 10.3) ≈ 2π·10.3", _approx(inner_wall, 63.0, 66.0), "%.1f" % inner_wall)
	# The hole's wall is a CLOSED loop: its moves chain end to start.
	var ring_moves := []
	for m in mid:
		if absf(Vector2((m["p1"] as Vector3).x, (m["p1"] as Vector3).y).length() - 10.3) < 0.05:
			ring_moves.append(m)
	_check("tube: hole wall closes", ring_moves.size() > 8 and ((ring_moves[0] as Dictionary)["p0"] as Vector3).distance_to((ring_moves[ring_moves.size() - 1] as Dictionary)["p1"] as Vector3) < 1e-3)


func _test_slicer_vase() -> void:
	var r := StlSlicer.slice_triangles(box(Vector3(30, 30, 20), Vector3.ZERO), {"layer_height_mm": 0.3, "line_width_mm": 0.5, "mode": "vase", "bottom_layers": 2, "walls": 1, "centre_xy": Vector2(15.0, 15.0)})
	_check("vase slices", bool(r.get("ok", false)))
	if not bool(r.get("ok", false)):
		return
	var moves: Array = r["moves"]
	var lastz := -1.0
	var mono := true
	var travels_up := 0
	var top := 0.0
	for m in moves:
		var z: float = (m["p1"] as Vector3).z
		if float(m["e_mm"]) > 0.0:
			if z < lastz - 1e-6:
				mono = false
			lastz = z
			top = maxf(top, z)
		elif z > 1.0:
			travels_up += 1
	_check("vase: Z never steps back", mono)
	_check("vase: reaches the top", absf(top - 20.0) < 1e-3, str(top))
	_check("vase: at most one travel above the bottom", travels_up <= 1, str(travels_up))
	var spiral := _layer_moves(moves, 10.0, 0.3)
	var inner := 0
	for m in spiral:
		var p1: Vector3 = m["p1"]
		if absf(p1.x - 15.0) < 14.0 and absf(p1.y - 15.0) < 14.0:
			inner += 1
	_check("vase: one wall, no infill above the bottom", inner == 0, str(inner))
	_check("vase: a vase of 30 mm has ~60 layers", int(r["layers"]) == 67, str(r["layers"]))


func _test_slicer_placement() -> void:
	var r := StlSlicer.slice_triangles(box(Vector3(10, 20, 4), Vector3(50, 50, 50)), {"layer_height_mm": 1.0, "line_width_mm": 0.5, "walls": 1, "infill_pct": 0.0, "top_layers": 0, "bottom_layers": 0, "scale": 2.0, "rotation_deg": 90.0, "centre_xy": Vector2(300.0, 200.0)})
	_check("placed slice", bool(r.get("ok", false)))
	if not bool(r.get("ok", false)):
		return
	var bmin: Vector3 = r["bounds_min"]
	var bmax: Vector3 = r["bounds_max"]
	var c := (bmin + bmax) * 0.5
	_check("placement: centred where asked", absf(c.x - 300.0) < 0.05 and absf(c.y - 200.0) < 0.05, str(c))
	# ×2 and a quarter turn: 20 × 40 → the wall's centreline box 39.5 × 19.5.
	var sz := bmax - bmin
	_check("placement: scaled ×2 and turned 90°", absf(sz.x - 39.5) < 0.05 and absf(sz.y - 19.5) < 0.05, str(sz))
	_check("placement: base on the bed", absf(bmin.z - 1.0) < 1e-4 and absf(bmax.z - 8.0) < 1e-4, "%s %s" % [bmin.z, bmax.z])
	_check("placement: 8 layers", int(r["layers"]) == 8)


func _test_gcode_round_trip() -> void:
	var r := StlSlicer.slice_triangles(box(Vector3(12, 12, 3), Vector3.ZERO), {"layer_height_mm": 0.3, "line_width_mm": 0.5, "walls": 2, "infill_pct": 25.0, "centre_xy": Vector2(60, 60), "z_hop_mm": 0.5})
	var moves: Array = r["moves"]
	var text := PrintGcodeWriter.write(moves, {"name": "box", "hotend_c": 210.0, "bed_c": 60.0, "filament_mm": 1.75})
	_check("gcode: has the header and layer comments", text.contains("M104 S210") and text.contains(";LAYER:0") and text.contains("G92 E0"))
	var back := GantryLabGcode.parse(text)
	_check("gcode: reads back", bool(back.get("ok", false)))
	if not bool(back.get("ok", false)):
		return
	var bm: Array = back["moves"]
	# The writer adds one rapid to the first point; every other move returns.
	_check("gcode: every move returns", bm.size() == moves.size() + 1, "%d vs %d" % [bm.size(), moves.size()])
	_check("gcode: extrusion returns to 5 decimals", absf(float(back["extrusion_mm"]) - float(r["extrusion_mm"])) < 1e-3 * moves.size(), "%s vs %s" % [back["extrusion_mm"], r["extrusion_mm"]])
	_check("gcode: bounds return", ((back["bounds_min"] as Vector3) - (r["bounds_min"] as Vector3)).length() < 0.01 and ((back["bounds_max"] as Vector3) - (r["bounds_max"] as Vector3)).length() < 0.01)
	_check("gcode: reprap dialect, additive", str(back["dialect"]) == "reprap" and bool(back["additive"]))
	_check("gcode: temperatures return", absf(float(back["temps"]["hotend_c"]) - 210.0) < 0.1 and absf(float(back["temps"]["bed_c"]) - 60.0) < 0.1)
	# The feed survives: a road at 50 mm/s is written as F3000.
	var feeds_ok := true
	for i in range(1, bm.size()):
		var a: Dictionary = bm[i]
		var b: Dictionary = moves[i - 1]
		if absf(float(a["feed_mm_s"]) - float(b["feed_mm_s"])) > 0.02:
			feeds_ok = false
			break
	_check("gcode: feeds return", feeds_ok)
	# The mud printer's relay dialect: no E words, the pump on an M3 with S,
	# every road still flagged as laying material when read back.
	var grbl := PrintGcodeWriter.write(moves, {"name": "box", "dialect": "grbl_relay", "travel_hop_mm": 15.0})
	_check("grbl: no E words, relay codes", not grbl.contains(" E") and grbl.contains("M3 S1000") and grbl.contains("M5"))
	var gb := GantryLabGcode.parse(grbl)
	_check("grbl: reads back as laying material", bool(gb.get("ok", false)) and float(gb["extrusion_mm"]) > 0.0 and str(gb["dialect"]) == "grbl")
	var road_back := 0
	for m in gb["moves"]:
		if float(m["e_mm"]) > 0.0:
			road_back += 1
	var road_fwd := 0
	for m in moves:
		if float(m["e_mm"]) > 0.0:
			road_fwd += 1
	_check("grbl: every road returns flagged", road_back == road_fwd, "%d vs %d" % [road_back, road_fwd])
	# And a printer re-importing its own relay program bills w·h·L again.
	var job := PrintJob.from_parse(gb, {"machine_role": "fdm_printer", "machine_kind": "mud", "filament_diameter_mm": 76.2, "line_width_mm": 0.5, "layer_height_mm": 0.3}, {"line_width_mm": 0.5, "layer_height_mm": 0.3})
	_check("grbl: re-imported job's volume = w·h·road", absf(float(job["volume_mm3"]) - float(r["volume_mm3"])) < float(r["volume_mm3"]) * 0.01, "%s vs %s" % [job["volume_mm3"], r["volume_mm3"]])


func _test_print_job() -> void:
	var specs := {"machine_role": "fdm_printer", "machine_kind": "trash", "filament_diameter_mm": 6.0, "flake_density_g_cm3": 0.95, "speed_factor": 1.0}
	var lim := PrintJob.limits_for_specs(specs)
	_check("limits: the trash printer's defaults", absf(float(lim["max_feed_mm_s"]) - 60.0) < 1e-6 and absf(float(lim["accel_mm_s2"]) - 400.0) < 1e-6)
	var lim2 := PrintJob.limits_for_specs({"machine_kind": "trash", "accel_mm_s2": 250.0})
	_check("limits: the specs' own numbers win", absf(float(lim2["accel_mm_s2"]) - 250.0) < 1e-6)
	_check("limits: an unknown machine gets the FDM defaults", absf(float(PrintJob.limits_for_specs({})["accel_mm_s2"]) - 1000.0) < 1e-6)
	var r := StlSlicer.slice_triangles(box(Vector3(60, 60, 20), Vector3.ZERO), {"layer_height_mm": 1.0, "line_width_mm": 6.0, "walls": 2, "infill_pct": 20.0, "centre_xy": Vector2(300, 300), "filament_mm": 6.0, "print_speed_mm_s": 40.0, "travel_speed_mm_s": 100.0})
	var job := PrintJob.from_parse(r, specs, {"name": "block"})
	_check("job from a sliced parse", bool(job.get("ok", false)) and job.has("plan") and float(job["total_s"]) > 0.0)
	if not bool(job.get("ok", false)):
		return
	# The planner's time beats length / feed: corners and short infill lines
	# never reach the feed.
	var naive := float(r["total_feed_mm"]) / 40.0 + float(r["total_rapid_mm"]) / 100.0
	_check("job: planned time > naive length/feed", float(job["total_s"]) > naive * 1.05, "%.1f vs %.1f" % [job["total_s"], naive])
	_check("job: est_time_hr = total_s / 3600", absf(float(job["est_time_hr"]) * 3600.0 - float(job["total_s"])) < 1e-3)
	_check("job: volume = w·h·road", absf(float(job["volume_mm3"]) - float(r["road_mm"]) * 6.0) < 1.0, "%s" % job["volume_mm3"])
	var kg := PrintJob.material_kg(job, specs)
	_check("job: material kg = volume × density", absf(kg - float(job["volume_mm3"]) * 1e-6 * 0.95) < 1e-6, str(kg))
	# derive_job (the graph's accounting) reads the same numbers.
	var dj := CartesianMachineSource.derive_job(job, specs)
	_check("derive_job: duration = the plan's", absf(float(dj["duration_hr"]) - float(job["est_time_hr"])) < 1e-6)
	_check("derive_job: material from E × bore area = the job's", absf(float(dj["material_qty"]) - kg) < 1e-6, "%s vs %s" % [dj["material_qty"], kg])
	# A speed factor halves the sim time, not the plan.
	var slow := PrintJob.from_parse(r, {"machine_kind": "trash", "filament_diameter_mm": 6.0, "speed_factor": 0.5})
	_check("job: speed_factor scales the sim duration only", absf(float(slow["est_time_hr"]) - float(job["est_time_hr"]) * 2.0) < 1e-6 and absf(float(slow["total_s"]) - float(job["total_s"])) < 1e-6)
	# An old point list (the mud wall slicer's shape) becomes a job: travels
	# where the flags are 0, shifted onto a corner-origin bed.
	var pts := PackedVector3Array([Vector3(-10, -10, 25), Vector3(10, -10, 25), Vector3(10, 10, 25), Vector3(-10, 10, 25), Vector3(-10, -10, 25), Vector3(-10, -10, 75), Vector3(10, -10, 75)])
	var ext := PackedInt32Array([0, 1, 1, 1, 1, 0, 1])
	var tp := PrintJob.from_toolpath({"ok": true, "kind": "mud_building", "points": pts, "extruding": ext, "line_width_mm": 76.2, "layer_height_mm": 50.0, "print_speed_mm_s": 120.0},
		{"machine_role": "fdm_printer", "machine_kind": "mud", "filament_diameter_mm": 76.2}, {"shift_xy": Vector2(1524.0, 1524.0)})
	_check("toolpath job: ok, 6 moves", bool(tp.get("ok", false)) and (tp["moves"] as Array).size() == 6)
	if bool(tp.get("ok", false)):
		var mv: Array = tp["moves"]
		_check("toolpath job: shifted onto the bed", ((mv[0] as Dictionary)["p0"] as Vector3).distance_to(Vector3(1514.0, 1514.0, 25.0)) < 1e-3, str((mv[0] as Dictionary)["p0"]))
		_check("toolpath job: the lift is a rapid, the rest print", bool((mv[4] as Dictionary)["rapid"]) and float((mv[4] as Dictionary)["e_mm"]) == 0.0 and not bool((mv[0] as Dictionary)["rapid"]) and float((mv[0] as Dictionary)["e_mm"]) > 0.0)
		# 100 mm of road at 76.2 × 50: volume 381 000 mm³ = 0.381 L.
		_check("toolpath job: volume = w·h·L", absf(float(tp["volume_mm3"]) - 100.0 * 76.2 * 50.0) < 1.0, str(tp["volume_mm3"]))
		_check("toolpath job: mud limits", absf(float(tp["limits"]["accel_mm_s2"]) - 150.0) < 1e-6)


func _test_job_store_and_player() -> void:
	var specs := {"machine_role": "fdm_printer", "machine_kind": "trash", "filament_diameter_mm": 6.0}
	var r := StlSlicer.slice_triangles(box(Vector3(40, 40, 6), Vector3.ZERO), {"layer_height_mm": 1.0, "line_width_mm": 6.0, "walls": 1, "infill_pct": 30.0, "centre_xy": Vector2(300, 300), "filament_mm": 6.0, "print_speed_mm_s": 40.0})
	var job := PrintJob.from_parse(r, specs, {"name": "plate"})
	var id := MachineJobStore.save(job)
	_check("store: a v2 job is written", not id.is_empty() and FileAccess.file_exists("%s/%s.job" % [MachineJobStore.JOBS_DIR, id]))
	var back := MachineJobStore.load(id)
	_check("store: moves return", back.has("moves") and (back["moves"] as Array).size() == (job["moves"] as Array).size())
	if back.has("moves"):
		var a: Dictionary = (job["moves"] as Array)[7]
		var b: Dictionary = (back["moves"] as Array)[7]
		_check("store: a move's numbers survive", (a["p1"] as Vector3).distance_to(b["p1"] as Vector3) < 1e-5 and absf(float(a["e_mm"]) - float(b["e_mm"])) < 1e-6 and absf(float(a["feed_mm_s"]) - float(b["feed_mm_s"])) < 1e-4 and bool(a["rapid"]) == bool(b["rapid"]))
		_check("store: limits, road size, totals return", absf(float(back["limits"]["accel_mm_s2"]) - 400.0) < 1e-6 and absf(float(back["line_width_mm"]) - 6.0) < 1e-6 and absf(float(back["total_s"]) - float(job["total_s"])) < 1e-3 and int(back["layers"]) == 6)
		_check("store: old readers get points + flags", (back["points"] as PackedVector3Array).size() == (job["moves"] as Array).size() + 1)
	# The player: the same plan, sampled by progress.
	var pl := PrintJobPlayer.new()
	_check("player: loads the stored job", pl.load(id, specs) and pl.is_loaded())
	if pl.is_loaded():
		_check("player: total_s = the job's", absf(pl.total_s - float(job["total_s"])) < 1e-3)
		var s0 := pl.sample(0.0)
		var s1 := pl.sample(1.0)
		var first: Vector3 = ((job["moves"] as Array)[0] as Dictionary)["p0"]
		var last: Vector3 = ((job["moves"] as Array)[(job["moves"] as Array).size() - 1] as Dictionary)["p1"]
		_check("player: progress 0 at the first point", (s0["pos"] as Vector3).distance_to(first) < 1e-4)
		_check("player: progress 1 at the last point, layer 6 of 6", (s1["pos"] as Vector3).distance_to(last) < 1e-3 and int(s1["layer"]) == 6 and int(s1["layers"]) == 6, "%s %s/%s" % [s1["pos"], s1["layer"], s1["layers"]])
		var sh := pl.sample(0.5)
		_check("player: halfway is inside the print, remaining = half", int(sh["i"]) > 0 and int(sh["i"]) < int(pl.plan["n"]) - 1 and absf(float(sh["remaining_s"]) - pl.total_s * 0.5) < 1e-3)
		_check("player: progress_of_layer rises", pl.progress_of_layer(1) < pl.progress_of_layer(3) and pl.progress_of_layer(3) < pl.progress_of_layer(6))
	# A v1 job (points + flags) loads through from_toolpath.
	var v1 := MachineJobStore.save({"points": PackedVector3Array([Vector3(0, 0, 1), Vector3(10, 0, 1), Vector3(10, 10, 1)]), "extruding": PackedInt32Array([0, 1, 1]), "bounds_min": Vector3(0, 0, 1), "bounds_max": Vector3(10, 10, 1), "kind": "gcode"})
	var pl1 := PrintJobPlayer.new()
	_check("player: an old v1 job still plays", pl1.load(v1, {"print_speed_mm_s": 40.0, "line_width_mm": 0.5, "layer_height_mm": 0.2}) and pl1.is_loaded() and int(pl1.plan["n"]) == 2)
	for jid in [id, v1]:
		for ext in ["job", "json"]:
			var path := "%s/%s.%s" % [MachineJobStore.JOBS_DIR, jid, ext]
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check("store: test jobs removed", not MachineJobStore.exists(id) and not MachineJobStore.exists(v1))


func _test_roads() -> void:
	var r := StlSlicer.slice_triangles(box(Vector3(20, 20, 2), Vector3.ZERO), {"layer_height_mm": 1.0, "line_width_mm": 1.0, "walls": 1, "infill_pct": 0.0, "top_layers": 0, "bottom_layers": 0, "centre_xy": Vector2(10, 10)})
	var moves: Array = r["moves"]
	var roads := PrintRoads.new()
	roads.lay(moves, 1.0, 1.0, Color.WHITE, 0.0, Vector3(-0.01, 0.0, -0.01))
	_check("roads: one per wall side per layer (8)", roads.road_count() == 8, str(roads.road_count()))
	_check("roads: two layers", roads.layer_count() == 2)
	roads.set_progress_move(0, 0.5)
	var rt := roads.road_transform(0)
	# The first wall side is 19 mm long; half of it grown, plus the width's reach past each end.
	_check("roads: the current road grown to the nozzle", roads.roads_shown() == 1 and absf(rt.basis.x.length() - (0.0095 + 0.001)) < 1e-4, "%f" % rt.basis.x.length())
	roads.set_progress_frac(1.0)
	_check("roads: all shown at the end", roads.roads_shown() == 8 and absf(roads.printed_m() - roads.road_len_total_m()) < 1e-6)
	var centre := roads.centre_local()
	_check("roads: centred on the bed origin", centre.distance_to(Vector3(0.0, 0.0015, 0.0)) < 0.002, str(centre))
	var mesh := roads.bake_mesh(Color.WHITE)
	_check("roads: bake a mesh", mesh != null and mesh.get_surface_count() == 1 and (mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 8 * 156)
	var guess := PrintRoads.layer_guess_mm(moves, 1.0)
	_check("roads: layer guessed from the Z steps", absf(guess - 1.0) < 1e-6, str(guess))
	roads.free()
