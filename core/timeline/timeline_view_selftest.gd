extends SceneTree

## Offline self-test for TimelineView zoom/pan/tick math.
## Run: godot --headless --path . --script core/timeline/timeline_view_selftest.gd

const TimelineViewScript := preload("res://core/timeline/timeline_view.gd")
const ClockScript := preload("res://core/celestial_clock.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_mapping()
	_test_zoom_anchor()
	_test_pan()
	_test_playhead_follow()
	_test_tick_ladder()
	_test_calendar_ticks()
	if _failures == 0:
		print("TIMELINE VIEW SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("TIMELINE VIEW SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label : String, ok : bool, detail : String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _make_view(start : float, span : float, width : float) -> RefCounted:
	var v : RefCounted = TimelineViewScript.new()
	v.start = start
	v.span = span
	v.width_px = width
	return v


func _test_mapping() -> void:
	var v := _make_view(1000.0, 168.0, 840.0)
	_check("map: left edge", absf(v.time_to_x(1000.0)) < 1e-6)
	_check("map: right edge", absf(v.time_to_x(1168.0) - 840.0) < 1e-3)
	var t : float = v.x_to_time(420.0)
	_check("map: inverse midpoint", absf(t - 1084.0) < 0.01, "got %.3f" % t)


func _test_zoom_anchor() -> void:
	var v := _make_view(1000.0, 168.0, 800.0)
	v.zoom_at_cursor(TimelineViewScript.ZOOM_IN_FACTOR, 400.0)
	var anchor_before := 1000.0 + 0.5 * 168.0
	var anchor_after : float = v.x_to_time(400.0)
	_check("zoom: cursor time preserved", absf(anchor_after - anchor_before) < 0.05,
		"before %.3f after %.3f" % [anchor_before, anchor_after])
	_check("zoom: span shrinks", v.span < 168.0, "span %.3f" % v.span)
	_check("zoom: disables follow", not v.follow_playhead)


func _test_pan() -> void:
	var v := _make_view(1000.0, 24.0, 480.0)
	v.pan_by_hours(6.0)
	_check("pan: shifts start", absf(v.start - 994.0) < 1e-6, "start %.3f" % v.start)
	v.pan_by_pixels(240.0)
	_check("pan: pixel drag", absf(v.start - 982.0) < 0.05, "start %.3f" % v.start)


func _test_playhead_follow() -> void:
	var v := _make_view(1000.0, 168.0, 800.0)
	var ph := 1084.0
	_check("contains: mid-window playhead", v.contains_time(ph))
	v.pan_by_hours(500.0)
	_check("contains: playhead outside after pan", not v.contains_time(ph))
	v.follow_playhead = true
	v.apply_playhead_follow(ph)
	_check("follow: recenters off-screen playhead", v.contains_time(ph))


func _test_tick_ladder() -> void:
	var v := _make_view(0.0, 24.0, 480.0)
	_check("ticks: 1 day → hour major", absf(v.choose_major_interval_hours() - 1.0) < 1e-6)
	v.span = 168.0
	v.width_px = 700.0
	_check("ticks: 1 week → day major", absf(v.choose_major_interval_hours() - 24.0) < 1e-6)
	v.span = TimelineViewScript.HOURS_PER_YEAR
	v.width_px = 900.0
	_check("ticks: 1 year → month-ish major",
		v.choose_major_interval_hours() >= 30.0 * 24.0)


func _test_calendar_ticks() -> void:
	var clk := ClockScript.new()
	clk.year = 2026
	clk.month = 6
	clk.day = 15
	clk.day_time = 12.0
	var h := float(clk.get_absolute_hours())
	var v := _make_view(h - 48.0, 96.0, 640.0)
	var ticks : Dictionary = v.collect_ticks(clk)
	var major : Array = ticks.get("major", [])
	_check("calendar: major ticks non-empty", major.size() >= 2, "count %d" % major.size())
	var lbl : String = v.format_tick_label(h, 24.0, clk)
	_check("calendar: day label", lbl.find("Jun") >= 0 or lbl.find("15") >= 0, lbl)
