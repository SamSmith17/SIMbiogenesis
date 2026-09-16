extends SceneTree

## Offline deterministic selftest for the Window Wall data layer
## (core/windowwall/): WindowWallLayout, WindowWallPrefs, WindowWallViewpoint.
##
## The one thing this file exists to freeze is the frustum contract: with
## keep_aspect = KEEP_WIDTH, Camera3D.set_frustum's `size` is the near-plane
## WIDTH, and the corner rays of the projection Godot builds from it land
## exactly on the physical monitor's corners. That is the whole "straight lines
## stay straight across the bezels" property, and it is checked by inverting
## Projection.create_frustum_aspect — the very call Camera3D makes — rather than
## by trusting the formula that produced the numbers. A NEGATIVE pin (the same
## check with flip_fov = false must fail) freezes the decision against an
## engine or a refactor quietly swapping width for height.
##
## Carries EXPECTED_CHECKS because a Godot runtime error aborts the enclosing
## test function while the suite still prints PASS.
##
## Run: Godot.exe.exe --headless --path . --import   (once, new class_names)
##      Godot.exe.exe --headless --path . --script core/windowwall/window_wall_selftest.gd

const EXPECTED_CHECKS := 109
const TMP_DIR := "user://selftest_tmp_window_wall"

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _near_v3(a: Vector3, b: Vector3, eps: float) -> bool:
	return (a - b).length() <= eps


func _initialize() -> void:
	_test_monitor_size()
	_test_layout()
	_test_frustum_numbers()
	_test_corner_round_trip()
	_test_negative_pin()
	_test_bezel_continuity()
	_test_tilted_panel()
	_test_assign_screens()
	_test_prefs()
	_test_viewpoint()
	_cleanup_tmp()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("WINDOW WALL SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("WINDOW WALL SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


## The 3 x 27" default the whole feature was designed around.
func _default_cfg() -> Dictionary:
	var slots: Array = []
	for i in 3:
		slots.append({"diag_in": 27.0, "width_m": 0.0, "height_m": 0.0, "portrait": false, "yaw_deg": 0.0, "pitch_deg": 0.0, "screen": -1})
	return {
		"monitor_count": 3, "gap_m": 0.1016, "eye_distance_m": 0.9,
		"eye_height_offset_m": 0.0, "slots": slots,
	}


func _test_monitor_size() -> void:
	var s := WindowWallLayout.monitor_size_m(27.0)
	_check("27in 16:9 width", _near(s.x, 0.5977, 1e-3), str(s))
	_check("27in 16:9 height", _near(s.y, 0.3362, 1e-3), str(s))
	_check("diagonal round-trips", _near(sqrt(s.x * s.x + s.y * s.y), 27.0 * 0.0254, 1e-6))
	var p := WindowWallLayout.slot_size_m({"diag_in": 27.0, "portrait": true})
	_check("portrait swaps w/h", _near(p.x, 0.3362, 1e-3) and _near(p.y, 0.5977, 1e-3), str(p))
	var e := WindowWallLayout.slot_size_m({"width_m": 0.7, "height_m": 0.4})
	_check("explicit width/height overrides the diagonal", e == Vector2(0.7, 0.4), str(e))


func _test_layout() -> void:
	var slots := WindowWallLayout.build_slots(_default_cfg())
	_check("three slots", slots.size() == 3)
	var pitch := 0.5977 + 0.1016
	_check("left centre x", _near(float(slots[0]["centre"].x), -pitch, 2e-3), str(slots[0]["centre"]))
	_check("centre centre x", _near(float(slots[1]["centre"].x), 0.0, 1e-9), str(slots[1]["centre"]))
	_check("right centre x", _near(float(slots[2]["centre"].x), pitch, 2e-3), str(slots[2]["centre"]))
	_check("row centred on the eye", _near(float(slots[0]["centre"].x) + float(slots[2]["centre"].x), 0.0, 1e-9))
	_check("z = -eye distance", _near(float(slots[1]["centre"].z), -0.9, 1e-6))
	_check("y = 0 with no eye offset", _near(float(slots[1]["centre"].y), 0.0, 1e-9))
	# Eye ABOVE the row centre => row centre BELOW the eye.
	var cfg := _default_cfg()
	cfg["eye_height_offset_m"] = 0.15
	var s2 := WindowWallLayout.build_slots(cfg)
	_check("eye height offset lowers the row", _near(float(s2[1]["centre"].y), -0.15, 1e-6))
	# Mixed widths keep the gap exact between neighbours.
	cfg = _default_cfg()
	cfg["slots"][0] = {"width_m": 0.4, "height_m": 0.3}
	cfg["slots"][2] = {"width_m": 0.8, "height_m": 0.3}
	var s3 := WindowWallLayout.build_slots(cfg)
	var gap01 := (float(s3[1]["centre"].x) - float(s3[1]["w_m"]) * 0.5) - (float(s3[0]["centre"].x) + float(s3[0]["w_m"]) * 0.5)
	var gap12 := (float(s3[2]["centre"].x) - float(s3[2]["w_m"]) * 0.5) - (float(s3[1]["centre"].x) + float(s3[1]["w_m"]) * 0.5)
	_check("mixed widths keep the gap exact (0-1)", _near(gap01, 0.1016, 1e-6), str(gap01))
	_check("mixed widths keep the gap exact (1-2)", _near(gap12, 0.1016, 1e-6), str(gap12))
	var span := float(s3[2]["centre"].x) + float(s3[2]["w_m"]) * 0.5 - (float(s3[0]["centre"].x) - float(s3[0]["w_m"]) * 0.5)
	_check("mixed span = widths + gaps", _near(span, 0.4 + 0.5977 + 0.8 + 2.0 * 0.1016, 2e-3), str(span))
	# Count is clamped.
	cfg = _default_cfg()
	cfg["monitor_count"] = 99
	_check("count clamps to MAX_SLOTS", WindowWallLayout.build_slots(cfg).size() == WindowWallLayout.MAX_SLOTS)
	cfg["monitor_count"] = 0
	_check("count floors at 1", WindowWallLayout.build_slots(cfg).size() == 1)
	# Slots beyond the supplied array fall back to defaults instead of crashing.
	cfg = _default_cfg()
	cfg["slots"] = []
	_check("missing slot records default to 27in", _near(float(WindowWallLayout.build_slots(cfg)[0]["w_m"]), 0.5977, 1e-3))


func _test_frustum_numbers() -> void:
	var slots := WindowWallLayout.build_slots(_default_cfg())
	var fc := WindowWallLayout.frustum_for(slots[1], 0.05)
	_check("centre size = w*near/d", _near(float(fc["size"]), 0.033206, 5e-6), str(fc["size"]))
	_check("centre offset is zero", (fc["offset"] as Vector2).length() < 1e-9, str(fc["offset"]))
	_check("centre basis is identity", (fc["basis"] as Basis).is_equal_approx(Basis.IDENTITY))
	_check("centre d", _near(float(fc["d"]), 0.9, 1e-6))
	var fl := WindowWallLayout.frustum_for(slots[0], 0.05)
	_check("left offset.x = cx*near/d", _near(float((fl["offset"] as Vector2).x), -0.038850, 5e-6), str(fl["offset"]))
	_check("left offset.y = 0", _near(float((fl["offset"] as Vector2).y), 0.0, 1e-9))
	_check("aspect_phys is 16:9", _near(float(fc["aspect_phys"]), 16.0 / 9.0, 1e-3))
	_check("per-panel hfov ~36.7 deg", _near(WindowWallLayout.slot_hfov_deg(fc), 36.7, 0.1), str(WindowWallLayout.slot_hfov_deg(fc)))
	_check("no aspect mismatch at 1920x1080", WindowWallLayout.aspect_mismatch(fc, 1920.0 / 1080.0) < 1e-3)
	_check("16:10 viewport mismatches by 10%", _near(WindowWallLayout.aspect_mismatch(fc, 1.6), 0.10, 1e-3), str(WindowWallLayout.aspect_mismatch(fc, 1.6)))
	var bad := WindowWallLayout.frustum_for({"index": 9, "centre": Vector3(0, 0, 0.5), "w_m": 0.6, "h_m": 0.3}, 0.05)
	_check("eye behind the panel -> empty", bad.is_empty())
	_check("corner_hits of empty is empty", WindowWallLayout.corner_hits(bad).is_empty())


## The load-bearing check: invert the projection Godot itself would build.
func _test_corner_round_trip() -> void:
	var slots := WindowWallLayout.build_slots(_default_cfg())
	var aspect_px := 1920.0 / 1080.0
	for slot in slots:
		var f := WindowWallLayout.frustum_for(slot, 0.05)
		var proj := WindowWallLayout.projection_for(f, aspect_px, 0.05, 4000.0)
		var hits := WindowWallLayout.corner_hits(f)
		var c: Vector3 = slot["centre"]
		var w := float(slot["w_m"])
		var h := float(slot["h_m"])
		var want := [
			Vector3(c.x - w * 0.5, c.y - h * 0.5, c.z),
			Vector3(c.x + w * 0.5, c.y - h * 0.5, c.z),
			Vector3(c.x + w * 0.5, c.y + h * 0.5, c.z),
			Vector3(c.x - w * 0.5, c.y + h * 0.5, c.z),
		]
		var ndcs := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
		var all_ok := true
		var all_hits := true
		for i in 4:
			var p := WindowWallLayout.unproject_to_plane(proj, ndcs[i], float(f["d"]))
			if not _near_v3(p, want[i], 1e-4):
				all_ok = false
			if not _near_v3(hits[i], want[i], 1e-6):
				all_hits = false
		_check("slot %d: projection corners land on the monitor corners" % int(slot["index"]), all_ok)
		_check("slot %d: corner_hits match the rectangle" % int(slot["index"]), all_hits)


## Same check with flip_fov = false (what KEEP_HEIGHT would build) MUST fail,
## or the width/height decision has silently stopped mattering.
func _test_negative_pin() -> void:
	var slots := WindowWallLayout.build_slots(_default_cfg())
	var f := WindowWallLayout.frustum_for(slots[0], 0.05)
	var aspect_px := 1920.0 / 1080.0
	var wrong := Projection.create_frustum_aspect(float(f["size"]), aspect_px, f["offset"], 0.05, 4000.0, false)
	var c: Vector3 = slots[0]["centre"]
	var w := float(slots[0]["w_m"])
	var h := float(slots[0]["h_m"])
	var p := WindowWallLayout.unproject_to_plane(wrong, Vector2(1, 1), float(f["d"]))
	_check("flip_fov=false does NOT land on the corner (negative pin)",
			not _near_v3(p, Vector3(c.x + w * 0.5, c.y + h * 0.5, c.z), 1e-3), str(p))
	# And KEEP_HEIGHT-style size (height) is a different number entirely.
	_check("size is the WIDTH, not the height", _near(float(f["size"]), w * 0.05 / 0.9, 1e-9) and not _near(float(f["size"]), h * 0.05 / 0.9, 1e-6))


func _test_bezel_continuity() -> void:
	var slots := WindowWallLayout.build_slots(_default_cfg())
	var aspect_px := 1920.0 / 1080.0
	var projs: Array[Projection] = []
	var fs: Array[Dictionary] = []
	for slot in slots:
		var f := WindowWallLayout.frustum_for(slot, 0.05)
		fs.append(f)
		projs.append(WindowWallLayout.projection_for(f, aspect_px, 0.05, 4000.0))
	# A far point seen through ANY panel maps back to ONE point on the wall
	# plane: the ray from the eye is the same ray whichever panel it crosses.
	var far_pt := Vector3(37.0, 12.0, -1000.0)
	var wall_pts: Array[Vector3] = []
	for i in 3:
		var ndc := WindowWallLayout.project_to_ndc(projs[i], far_pt)
		wall_pts.append(WindowWallLayout.unproject_to_plane(projs[i], ndc, 0.9))
	_check("far point -> one wall point (slots 0/1)", _near_v3(wall_pts[0], wall_pts[1], 1e-6), "%s vs %s" % [wall_pts[0], wall_pts[1]])
	_check("far point -> one wall point (slots 1/2)", _near_v3(wall_pts[1], wall_pts[2], 1e-6), "%s vs %s" % [wall_pts[1], wall_pts[2]])
	_check("that wall point is the ray scaled to z=-d", _near_v3(wall_pts[1], far_pt * (0.9 / 1000.0), 1e-6))
	# The bezel: a wall point on slot 0's RIGHT edge and one on slot 1's LEFT
	# edge at the same height sit on the same pixel ROW in their own panels.
	var c0: Vector3 = slots[0]["centre"]
	var c1: Vector3 = slots[1]["centre"]
	var w := float(slots[0]["w_m"])
	var y := 0.1
	var right0 := Vector3(c0.x + w * 0.5, y, c0.z)
	var left1 := Vector3(c1.x - w * 0.5, y, c1.z)
	var n0 := WindowWallLayout.project_to_ndc(projs[0], right0)
	var n1 := WindowWallLayout.project_to_ndc(projs[1], left1)
	_check("right edge of slot 0 is ndc.x = +1", _near(n0.x, 1.0, 1e-6), str(n0))
	_check("left edge of slot 1 is ndc.x = -1", _near(n1.x, -1.0, 1e-6), str(n1))
	_check("same height -> same ndc.y across the bezel", _near(n0.y, n1.y, 1e-9), "%s vs %s" % [n0, n1])
	# The horizon (eye height, y = 0) is the centre row of every panel.
	for i in 3:
		var n := WindowWallLayout.project_to_ndc(projs[i], Vector3(float((slots[i]["centre"] as Vector3).x), 0.0, -50.0))
		_check("slot %d: horizon is the centre row" % i, _near(n.y, 0.0, 1e-9), str(n))


func _test_tilted_panel() -> void:
	var cfg := _default_cfg()
	cfg["slots"][0]["yaw_deg"] = 30.0
	cfg["slots"][0]["pitch_deg"] = 5.0
	var slots := WindowWallLayout.build_slots(cfg)
	var f := WindowWallLayout.frustum_for(slots[0], 0.05)
	_check("tilted: still solvable", not f.is_empty())
	if f.is_empty():
		_checks += 4
		return
	_check("tilted: d > 0", float(f["d"]) > 0.0)
	_check("tilted: basis is not identity", not (f["basis"] as Basis).is_equal_approx(Basis.IDENTITY))
	var hits := WindowWallLayout.corner_hits(f)
	var R: Basis = f["basis"]
	var c: Vector3 = slots[0]["centre"]
	var w := float(slots[0]["w_m"])
	var h := float(slots[0]["h_m"])
	var want := c + R * Vector3(w * 0.5, h * 0.5, 0.0)
	_check("tilted: top-right corner hit is the rotated rectangle corner", _near_v3(hits[2], want, 1e-6), "%s vs %s" % [hits[2], want])
	# Inverting the projection in the CAMERA frame and rotating out matches too.
	var proj := WindowWallLayout.projection_for(f, 16.0 / 9.0, 0.05, 4000.0)
	var p_cam := WindowWallLayout.unproject_to_plane(proj, Vector2(1, 1), float(f["d"]))
	_check("tilted: projection corner rotates onto the panel corner", _near_v3(R * p_cam, want, 1e-4), "%s vs %s" % [R * p_cam, want])
	# A panel yawed to face away from the eye is refused.
	cfg["slots"][0]["yaw_deg"] = 180.0
	var away := WindowWallLayout.frustum_for(WindowWallLayout.build_slots(cfg)[0], 0.05)
	_check("panel facing away -> empty", away.is_empty())


func _test_assign_screens() -> void:
	var screens := [
		{"index": 0, "x": 1920, "y": 0, "w": 1920, "h": 1080},
		{"index": 1, "x": 0, "y": 0, "w": 1920, "h": 1080},
		{"index": 2, "x": 3840, "y": 0, "w": 1920, "h": 1080},
	]
	var slots := WindowWallLayout.build_slots(_default_cfg())
	var a := WindowWallLayout.assign_screens(slots, screens)
	_check("auto: ordered by X", a == PackedInt32Array([1, 0, 2]), str(a))
	# Explicit wins and is removed from the auto pool.
	var cfg := _default_cfg()
	cfg["slots"][0]["screen"] = 2
	var b := WindowWallLayout.assign_screens(WindowWallLayout.build_slots(cfg), screens)
	_check("explicit assignment wins", b[0] == 2, str(b))
	_check("explicit screen is not reused", b[1] != 2 and b[2] != 2, str(b))
	_check("remaining slots still ordered by X", b[1] == 1 and b[2] == 0, str(b))
	# Explicit index that does not exist falls back to auto.
	cfg = _default_cfg()
	cfg["slots"][1]["screen"] = 7
	var c := WindowWallLayout.assign_screens(WindowWallLayout.build_slots(cfg), screens)
	_check("nonexistent explicit screen -> auto", c == PackedInt32Array([1, 0, 2]), str(c))
	# Single screen: everything lands on 0.
	var one := WindowWallLayout.assign_screens(slots, [screens[0]])
	_check("one screen: all on 0", one == PackedInt32Array([0, 0, 0]), str(one))
	# Six slots, three screens: leftovers on 0.
	cfg = _default_cfg()
	cfg["monitor_count"] = 6
	var six := WindowWallLayout.assign_screens(WindowWallLayout.build_slots(cfg), screens)
	_check("six slots / three screens", six == PackedInt32Array([1, 0, 2, 0, 0, 0]), str(six))
	# No screens at all (headless): all 0, no crash.
	var none := WindowWallLayout.assign_screens(slots, [])
	_check("no screens: all 0", none == PackedInt32Array([0, 0, 0]), str(none))


func _test_prefs() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))
	var path := TMP_DIR + "/window_wall.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	WindowWallPrefs.cfg_path = path
	WindowWallPrefs.reset_for_test()
	# Defaults with no file.
	_check("default: disabled", not WindowWallPrefs.enabled())
	_check("default: 3 monitors", WindowWallPrefs.monitor_count() == 3)
	_check("default: main slot is the centre", WindowWallPrefs.main_slot() == 1)
	_check("default: clock live", WindowWallPrefs.clock_mode() == WindowWallPrefs.CLOCK_LIVE)
	_check("default: hide ui", WindowWallPrefs.hide_ui())
	_check("default: gap 4in", _near(float(WindowWallPrefs.get_value("gap_m")), 0.1016, 1e-9))
	_check("default slot: 27in", _near(float(WindowWallPrefs.slot(0)["diag_in"]), 27.0, 1e-9))
	var snap := WindowWallPrefs.snapshot()
	_check("snapshot carries only active slots", (snap["slots"] as Array).size() == 3)
	# Writes, clamps, round-trip.
	WindowWallPrefs.set_value("enabled", true)
	WindowWallPrefs.set_value("monitor_count", 2)
	WindowWallPrefs.set_value("eye_distance_m", 1.3)
	WindowWallPrefs.set_value("clock_mode", "bogus")
	_check("bad clock mode falls back", WindowWallPrefs.clock_mode() == WindowWallPrefs.CLOCK_LIVE)
	WindowWallPrefs.set_value("clock_mode", WindowWallPrefs.CLOCK_ONE_X)
	WindowWallPrefs.set_value("main_slot", 5)
	_check("main slot clamps to the count", WindowWallPrefs.main_slot() == 1)
	WindowWallPrefs.set_value("monitor_count", 42)
	_check("count clamps to MAX_SLOTS", WindowWallPrefs.monitor_count() == WindowWallPrefs.MAX_SLOTS)
	WindowWallPrefs.set_value("monitor_count", 2)
	WindowWallPrefs.set_value("render_scale", 3.0)
	_check("render scale clamps to 1", _near(WindowWallPrefs.render_scale(), 1.0, 1e-9))
	WindowWallPrefs.set_value("render_scale", NAN)
	_check("NaN is rejected", is_finite(WindowWallPrefs.render_scale()))
	WindowWallPrefs.set_slot_value(0, "diag_in", 32.0)
	WindowWallPrefs.set_slot_value(1, "portrait", true)
	WindowWallPrefs.set_slot_value(1, "screen", 2)
	WindowWallPrefs.set_slot_value(9, "diag_in", 1.0)  # ignored, no crash
	WindowWallPrefs.set_value("no_such_key", 1)          # ignored, no crash
	var gen := WindowWallPrefs.generation()
	WindowWallPrefs.save()
	_check("save bumps the generation", WindowWallPrefs.generation() > gen)
	# A foreign section written by someone else survives a save.
	var other := ConfigFile.new()
	other.load(path)
	other.set_value("other", "keep_me", 7)
	other.save(path)
	WindowWallPrefs.set_value("gap_m", 0.05)
	WindowWallPrefs.save()
	var after := ConfigFile.new()
	after.load(path)
	_check("foreign section survives save()", int(after.get_value("other", "keep_me", 0)) == 7)
	_check("version stamped", int(after.get_value("wall", "version", 0)) == WindowWallPrefs.VERSION)
	# Reload from disk.
	WindowWallPrefs.reset_for_test()
	_check("reload: enabled", WindowWallPrefs.enabled())
	_check("reload: count 2", WindowWallPrefs.monitor_count() == 2)
	_check("reload: eye distance", _near(float(WindowWallPrefs.get_value("eye_distance_m")), 1.3, 1e-9))
	_check("reload: clock one_x", WindowWallPrefs.clock_mode() == WindowWallPrefs.CLOCK_ONE_X)
	_check("reload: gap", _near(float(WindowWallPrefs.get_value("gap_m")), 0.05, 1e-9))
	_check("reload: slot 0 diag", _near(float(WindowWallPrefs.slot(0)["diag_in"]), 32.0, 1e-9))
	_check("reload: slot 1 portrait", bool(WindowWallPrefs.slot(1)["portrait"]))
	_check("reload: slot 1 screen", int(WindowWallPrefs.slot(1)["screen"]) == 2)
	_check("slot() returns a copy", (func() -> bool:
		var s := WindowWallPrefs.slot(0)
		s["diag_in"] = 1.0
		return _near(float(WindowWallPrefs.slot(0)["diag_in"]), 32.0, 1e-9)).call())
	# Session override does not write.
	var mtime := FileAccess.get_modified_time(path)
	var size_before := FileAccess.get_file_as_bytes(path).size()
	WindowWallPrefs.override_for_session({"enabled": false, "clock_mode": WindowWallPrefs.CLOCK_LEAVE, "bogus": 1})
	_check("override applies in memory", not WindowWallPrefs.enabled() and WindowWallPrefs.clock_mode() == WindowWallPrefs.CLOCK_LEAVE)
	_check("override wrote nothing", FileAccess.get_modified_time(path) == mtime and FileAccess.get_file_as_bytes(path).size() == size_before)
	# auto_arrange writes the screen field per active slot.
	WindowWallPrefs.set_slot_value(1, "screen", -1)
	WindowWallPrefs.auto_arrange_by_x([
		{"index": 0, "x": 1920, "y": 0, "w": 1920, "h": 1080},
		{"index": 1, "x": 0, "y": 0, "w": 1920, "h": 1080},
	])
	_check("auto_arrange: slot 0 -> leftmost screen", int(WindowWallPrefs.slot(0)["screen"]) == 1)
	_check("auto_arrange: slot 1 -> next screen", int(WindowWallPrefs.slot(1)["screen"]) == 0)
	# Corrupt file -> defaults, no crash.
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("this is not a config file [[[")
	f.close()
	WindowWallPrefs.reset_for_test()
	_check("corrupt file -> defaults", WindowWallPrefs.monitor_count() == 3 and not WindowWallPrefs.enabled())
	# A file with out-of-range values is clamped on load.
	var cfg := ConfigFile.new()
	cfg.set_value("wall", "monitor_count", 40)
	cfg.set_value("wall", "main_slot", 9)
	cfg.set_value("wall", "eye_distance_m", -3.0)
	cfg.save(path)
	WindowWallPrefs.reset_for_test()
	_check("stale file: count clamped", WindowWallPrefs.monitor_count() == WindowWallPrefs.MAX_SLOTS)
	_check("stale file: main slot clamped", WindowWallPrefs.main_slot() == WindowWallPrefs.MAX_SLOTS - 1)
	_check("stale file: eye distance clamped", float(WindowWallPrefs.get_value("eye_distance_m")) >= 0.2)
	WindowWallPrefs.reset_for_test()
	WindowWallPrefs.cfg_path = WindowWallPrefs.CFG_PATH


func _test_viewpoint() -> void:
	var pm := WindowWallViewpoint.save_path_for_map(48.3252, -122.2469)
	_check("map path uses CoordToken", pm == "user://maps/window_wall_viewpoint_48p3252_n122p2469.json", pm)
	var ps := WindowWallViewpoint.save_path_for_scene("res://scenes/maps/soak_festival_2026.tscn")
	_check("scene path uses the basename", ps == "user://maps/window_wall_viewpoint_scene_soak_festival_2026.json", ps)
	_check("empty scene key is safe", WindowWallViewpoint.save_path_for_scene("").ends_with("unknown_scene.json"))
	_check("null main is safe", WindowWallViewpoint.path_for(null).ends_with("unknown_scene.json"))
	var path := TMP_DIR + "/viewpoint.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check("missing file -> null", WindowWallViewpoint.load_from(path) == null)
	var vp := WindowWallViewpoint.new()
	vp.pos = Vector3(12.5, 81.25, -7.0)
	vp.yaw_deg = 123.4
	vp.saved_at = "2026-09-04T17:00:00"
	_check("save_to writes", vp.save_to(path))
	var back := WindowWallViewpoint.load_from(path)
	_check("round-trip loads", back != null)
	if back != null:
		_check("round-trip pos", back.pos == vp.pos, str(back.pos))
		_check("round-trip yaw", _near(back.yaw_deg, 123.4, 1e-9))
		_check("round-trip saved_at", back.saved_at == vp.saved_at)
		_check("eye = pos + seat height", back.eye(1.2) == Vector3(12.5, 82.45, -7.0))
	else:
		_checks += 4
	_check("deserialize rejects a bad pos", not WindowWallViewpoint.new().deserialize({"pos": [1, 2]}))
	_check("deserialize rejects a non-finite pos", not WindowWallViewpoint.new().deserialize({"pos": [1, INF, 2]}))
	var junk := FileAccess.open(path, FileAccess.WRITE)
	junk.store_string("[not json")
	junk.close()
	_check("corrupt file -> null", WindowWallViewpoint.load_from(path) == null)


func _cleanup_tmp() -> void:
	var dir := DirAccess.open(TMP_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR))
