extends SceneTree

## Offline deterministic selftest for `core/multimonitor/`:
##   - MultiMonitorCatalog (every entry valid, groups covered, singleton/3D flags)
##   - MultiMonitorDisplay (5-monitor rig: 4 landscape + 1 portrait, fingerprint
##     matching across OS screen index shuffles, unique portrait fallback when
##     virtual-desktop coordinates shift, DWM-safe 1px anti-DirectFlip rect,
##     portrait 1080x1920 logical base canvas, off-screen window rescue,
##     proportional layout diagram rects)
##   - MultiMonitorPrefs (defaults, add/remove/clamp, placement persistence,
##     detect-populate assigning Biochar Reactor to Portrait and Systems Graph
##     to Landscape, session overrides not touching disk, AssetPackPrefs
##     exclusion so monitor configs never leak into shared packs).
##
## Carries EXPECTED_CHECKS so a runtime error aborting a test function fails.

const EXPECTED_CHECKS := 50
const TMP_DIR := "user://selftest_tmp_multimonitor"

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_catalog()
	_test_five_monitor_matching()
	_test_rects_and_portrait_canvas()
	_test_prefs_round_trip()
	_cleanup_tmp()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("MULTI-MONITOR SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("MULTI-MONITOR SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


## Representative 5-monitor setup: 4 landscape (one primary, one left, one right,
## one touchscreen below) + 1 portrait (1080x1920 on the far right).
func _five_monitors() -> Array[Dictionary]:
	return [
		MultiMonitorDisplay.make_screen_dict(0, 0, 0, 2560, 1440, true),        # Main 3D
		MultiMonitorDisplay.make_screen_dict(1, -1920, 180, 1920, 1080, false), # Left landscape
		MultiMonitorDisplay.make_screen_dict(2, 2560, 180, 1920, 1080, false),  # Right landscape
		MultiMonitorDisplay.make_screen_dict(3, 320, 1440, 1920, 1080, false),  # Touchscreen landscape
		MultiMonitorDisplay.make_screen_dict(4, 4480, -240, 1080, 1920, false), # Portrait monitor
	]


func _test_catalog() -> void:
	var all := MultiMonitorCatalog.entries()
	_check("catalog non-empty", all.size() >= 15, str(all.size()))
	_check("has system_graph", MultiMonitorCatalog.has_view(MultiMonitorCatalog.VIEW_SYSTEM_GRAPH))
	_check("has tclab_biochar", MultiMonitorCatalog.has_view(MultiMonitorCatalog.VIEW_TCLAB_BIOCHAR))
	_check("has window_wall_slot", MultiMonitorCatalog.has_view(MultiMonitorCatalog.VIEW_WINDOW_WALL_SLOT))
	_check("bogus view not in catalog", not MultiMonitorCatalog.has_view("no_such_view"))
	var bio := MultiMonitorCatalog.entry(MultiMonitorCatalog.VIEW_TCLAB_BIOCHAR)
	_check("biochar preset is biochar_reactor + process_mode",
		str(bio.get("preset", "")) == "biochar_reactor" and bool(bio.get("process_mode", false)))
	_check("system_graph is singleton reparent & 2D",
		MultiMonitorCatalog.is_singleton_reparent(MultiMonitorCatalog.VIEW_SYSTEM_GRAPH)
		and not MultiMonitorCatalog.shares_world_3d(MultiMonitorCatalog.VIEW_SYSTEM_GRAPH))
	_check("overhead_3d shares World3D",
		MultiMonitorCatalog.shares_world_3d(MultiMonitorCatalog.VIEW_OVERHEAD_3D))
	for g in MultiMonitorCatalog.GROUPS:
		_check("group '%s' has entries" % g, not MultiMonitorCatalog.entries_in_group(g).is_empty())


func _test_five_monitor_matching() -> void:
	var screens := _five_monitors()
	_check("primary screen is 0", MultiMonitorDisplay.primary_screen_index(screens) == 0)
	_check("portrait detected on screen 4", bool(screens[4]["is_portrait"]) and not bool(screens[0]["is_portrait"]))
	var fp_touch := MultiMonitorDisplay.fingerprint_of(screens[3])
	var fp_port := MultiMonitorDisplay.fingerprint_of(screens[4])
	_check("fingerprint format", fp_port == "4480,-240,1080x1920", fp_port)

	# Simulate Windows shuffling DisplayServer screen indices after sleep/wake!
	var shuffled: Array[Dictionary] = [
		MultiMonitorDisplay.make_screen_dict(0, 4480, -240, 1080, 1920, false),
		MultiMonitorDisplay.make_screen_dict(1, 320, 1440, 1920, 1080, false),
		MultiMonitorDisplay.make_screen_dict(2, 0, 0, 2560, 1440, true),
		MultiMonitorDisplay.make_screen_dict(3, 2560, 180, 1920, 1080, false),
		MultiMonitorDisplay.make_screen_dict(4, -1920, 180, 1920, 1080, false),
	]
	_check("fingerprint finds touchscreen at new index 1",
		MultiMonitorDisplay.resolve_screen(fp_touch, 3, shuffled) == 1)
	_check("fingerprint finds portrait at new index 0",
		MultiMonitorDisplay.resolve_screen(fp_port, 4, shuffled) == 0)

	# Minor coordinate nudge (e.g. 20 px in Windows Display Settings) still matches.
	var nudged: Array[Dictionary] = [
		MultiMonitorDisplay.make_screen_dict(0, 0, 0, 2560, 1440, true),
		MultiMonitorDisplay.make_screen_dict(1, 340, 1440, 1920, 1080, false),
		MultiMonitorDisplay.make_screen_dict(2, 2560, 180, 1920, 1080, false),
	]
	_check("nudged touchscreen still resolves by proximity",
		MultiMonitorDisplay.resolve_screen(fp_touch, 3, nudged) == 1)

	# Portrait moved to the left side of the desk — unique 1080x1920 resolution still resolves!
	var moved_portrait: Array[Dictionary] = [
		MultiMonitorDisplay.make_screen_dict(0, 0, 0, 2560, 1440, true),
		MultiMonitorDisplay.make_screen_dict(1, -1080, -200, 1080, 1920, false),
	]
	_check("unique portrait resolution resolves even if moved across desk",
		MultiMonitorDisplay.resolve_screen(fp_port, 4, moved_portrait) == 1)

	# Unplugged monitor returns -1 instead of blindly landing on wrong screen.
	var unplugged: Array[Dictionary] = [screens[0]]
	_check("unplugged monitor returns -1",
		MultiMonitorDisplay.resolve_screen(fp_port, 4, unplugged) == -1)

	# Screen containing a dragged window rect.
	var dragged := Rect2i(4520, 100, 840, 1240)
	_check("dragged rect detected on portrait screen 4",
		MultiMonitorDisplay.screen_containing_rect(dragged, screens) == 4)


func _test_rects_and_portrait_canvas() -> void:
	var screens := _five_monitors()
	var safe := MultiMonitorDisplay.dwm_safe_fullscreen_rect(screens[4], true)
	_check("DWM-safe rect keeps x,y,w and subtracts 1 px from h",
		safe == Rect2i(4480, -240, 1080, 1919), str(safe))
	var exact := MultiMonitorDisplay.dwm_safe_fullscreen_rect(screens[4], false)
	_check("exact rect when anti_directflip=false",
		exact == Rect2i(4480, -240, 1080, 1920), str(exact))

	_check("portrait canvas is 1080x1920",
		MultiMonitorDisplay.logical_canvas_size(Vector2i(1080, 1919)) == Vector2i(1080, 1920))
	_check("landscape canvas is 1920x1080",
		MultiMonitorDisplay.logical_canvas_size(Vector2i(2560, 1440)) == Vector2i(1920, 1080))
	_check("portrait override forces portrait on square/landscape",
		MultiMonitorDisplay.logical_canvas_size(Vector2i(1280, 800), MultiMonitorPrefs.PORTRAIT_PORTRAIT) == Vector2i(1080, 1920))

	var def_p := MultiMonitorDisplay.default_windowed_rect(screens[4], true, 0)
	var port_rect := Rect2i(4480, -240, 1080, 1920)
	_check("default portrait windowed rect sits inside portrait monitor",
		port_rect.encloses(def_p) and def_p.size.y > def_p.size.x, str(def_p))

	# Off-screen window rescue when a monitor was unplugged.
	var stranded := Rect2i(9000, 9000, 1280, 800)
	var rescued := MultiMonitorDisplay.rescue_window_rect(stranded, [screens[0]], 0)
	var prim_rect := Rect2i(0, 0, 2560, 1440)
	_check("stranded off-screen window rescued onto primary monitor",
		prim_rect.encloses(rescued), str(rescued))

	# Valid window on negative-X left monitor is NOT falsely rescued.
	var valid_left := Rect2i(-1700, 260, 1280, 800)
	var kept := MultiMonitorDisplay.rescue_window_rect(valid_left, screens, 0)
	_check("valid negative-coord window kept in place", kept.position == valid_left.position, str(kept))

	# Diagram rects fit inside box.
	var diag := MultiMonitorDisplay.layout_diagram_rects(screens, Vector2(480, 160), 10.0)
	var all_inside := diag.size() == 5
	var box := Rect2(Vector2.ZERO, Vector2(480, 160))
	for d in diag:
		if not box.encloses(d["rect"] as Rect2):
			all_inside = false
	_check("5-monitor diagram rects all fit inside settings preview box", all_inside)


func _test_prefs_round_trip() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))
	var path := TMP_DIR + "/multi_monitor.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	MultiMonitorPrefs.cfg_path = path
	MultiMonitorPrefs.reset_for_test()

	_check("default disabled", not MultiMonitorPrefs.enabled())
	_check("default 0 slots", MultiMonitorPrefs.slot_count() == 0)
	_check("default DWM-safe fullscreen method",
		MultiMonitorPrefs.fullscreen_method() == MultiMonitorPrefs.FS_METHOD_DWM_SAFE)
	_check("not shareable in AssetPackPrefs",
		not AssetPackPrefs.is_shareable("multi_monitor.cfg"))

	# Populate from the 5-monitor setup: skips primary (0), creates 4 secondary slots!
	var screens := _five_monitors()
	var added := MultiMonitorPrefs.populate_from_detected_screens(screens)
	_check("populate adds 4 secondary monitors from 5-screen rig", added == 4 and MultiMonitorPrefs.slot_count() == 4, str(added))
	# Calling again is idempotent (same fingerprints already present).
	_check("populate idempotent for existing screens",
		MultiMonitorPrefs.populate_from_detected_screens(screens) == 0)

	# Portrait monitor (screen 4 -> slot index 3) auto-picked tclab_biochar!
	var port_slot := MultiMonitorPrefs.slot(3)
	_check("portrait monitor auto-assigned Biochar Reactor",
		str(port_slot["starting_view"]) == MultiMonitorCatalog.VIEW_TCLAB_BIOCHAR, str(port_slot))
	_check("new slots start placed=false & is_fullscreen=false (draggable first)",
		not bool(port_slot["placed"]) and not bool(port_slot["is_fullscreen"]))

	# Configure touchscreen slot (screen 3 -> slot index 2) and record placement.
	MultiMonitorPrefs.set_value("enabled", true)
	MultiMonitorPrefs.set_slot_value(2, "label", "Touchscreen")
	MultiMonitorPrefs.set_slot_value(2, "starting_view", MultiMonitorCatalog.VIEW_SYSTEM_GRAPH)
	MultiMonitorPrefs.set_slot_value(2, "touchscreen", true)
	var touch_id := str(MultiMonitorPrefs.slot(2)["id"])
	MultiMonitorPrefs.record_placement(touch_id, 3, MultiMonitorDisplay.fingerprint_of(screens[3]),
		Vector2i(400, 1500), Vector2i(1280, 800), true)

	# Bogus values clamp safely.
	MultiMonitorPrefs.set_slot_value(2, "starting_view", "nonexistent_view")
	_check("bogus starting_view falls back to default",
		str(MultiMonitorPrefs.slot(2)["starting_view"]) == MultiMonitorCatalog.DEFAULT_VIEW)
	MultiMonitorPrefs.set_slot_value(2, "render_scale_3d", 99.0)
	_check("render_scale_3d clamps to 1.0", is_equal_approx(float(MultiMonitorPrefs.slot(2)["render_scale_3d"]), 1.0))

	MultiMonitorPrefs.save()
	MultiMonitorPrefs.reset_for_test()

	_check("reload enabled", MultiMonitorPrefs.enabled())
	_check("reload slot count 4", MultiMonitorPrefs.slot_count() == 4)
	var reloaded_touch := MultiMonitorPrefs.slot_by_id(touch_id)
	_check("reload touchscreen label & touch flag",
		str(reloaded_touch.get("label", "")) == "Touchscreen" and bool(reloaded_touch.get("touchscreen", false)))
	_check("reload placement placed + fullscreen + fingerprint",
		bool(reloaded_touch.get("placed", false))
		and bool(reloaded_touch.get("is_fullscreen", false))
		and str(reloaded_touch.get("screen_fingerprint", "")) == "320,1440,1920x1080")
	_check("reload windowed_pos preserved",
		(reloaded_touch.get("windowed_pos") as Vector2i) == Vector2i(400, 1500))

	# Session override does not write to disk.
	var mtime := FileAccess.get_modified_time(path)
	MultiMonitorPrefs.override_for_session({"enabled": false})
	_check("session override applies in memory", not MultiMonitorPrefs.enabled())
	_check("session override did not touch disk", FileAccess.get_modified_time(path) == mtime)

	# Remove a slot and re-save: stale section is erased.
	MultiMonitorPrefs.reset_for_test()
	_check("remove_slot succeeds", MultiMonitorPrefs.remove_slot(0) and MultiMonitorPrefs.slot_count() == 3)
	MultiMonitorPrefs.save()
	var cf := ConfigFile.new()
	cf.load(path)
	_check("stale monitor_3 section erased on save", not cf.has_section("monitor_3"))

	# Clear all fullscreen resets is_fullscreen on remaining slots.
	MultiMonitorPrefs.clear_all_fullscreen()
	var any_fs := false
	for s in MultiMonitorPrefs.slots():
		if bool(s["is_fullscreen"]):
			any_fs = true
	_check("clear_all_fullscreen clears every slot", not any_fs)

	MultiMonitorPrefs.reset_for_test()
	MultiMonitorPrefs.cfg_path = MultiMonitorPrefs.CFG_PATH


func _cleanup_tmp() -> void:
	var dir := DirAccess.open(TMP_DIR)
	if dir != null:
		for f in dir.get_files():
			dir.remove(f)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(TMP_DIR)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR))
