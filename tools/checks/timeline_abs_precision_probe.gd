extends RefCounted

## Absolute hours (~1.8e7) must never pass through a Vector2: float32 holds
## them only to the nearest 2 h. Sandbox probe on a real world:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/timeline_abs_precision_probe.gd
## An ODD-hour selection (the case a Vector2 rounds) must arrive unchanged in
## SolarUI's getter, the timeline's video-export range, the video-export
## dialog's prefilled range, and the 📈 render target end; the track window's
## start must be the view's own start, not a 2-hour step.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("abs64-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var su: Node = main.get_node_or_null("UILayer/SolarUI")
	var tl: Node = main.get_node_or_null("UILayer/TimelineUI")
	_ok(su != null and tl != null, "SolarUI + TimelineUI")
	if su == null or tl == null:
		return {"ok": false, "fails": _fails}
	var ph := float(main.call("get_absolute_hours"))
	var a := floorf(ph) + 1.0
	if int(a) % 2 == 0:
		a += 1.0   # odd: a Vector2 rounds it to the next even hour
	var b := a + 5.0
	# Exact compare: is_equal_approx is RELATIVE (1e-5 ≈ 177 h at this scale).
	_ok(float(Vector2(a, b).x) != a, "the test hour is one a Vector2 cannot hold (%.1f → %.1f)" % [a, Vector2(a, b).x])
	su.call("set_selection_abs", a, b)
	var sel: PackedFloat64Array = su.call("get_selection_abs")
	_ok(sel[0] == a and sel[1] == b, "SolarUI.get_selection_abs is exact")
	var cr: PackedFloat64Array = tl.call("_climelapse_selection_range")
	_ok(cr[0] == a and cr[1] == b, "the timeline's video-export range is exact")
	var rt := float(tl.call("_render_target_end"))
	_ok(rt == b, "the 📈 render ends at the selection's end (%.3f vs %.3f)" % [rt, b])
	var win: PackedFloat64Array = tl.call("_track_window")
	var view: Object = tl.get("_track_view")
	_ok(win[0] == float(view.get("start")) and win[1] == float(view.get("span")),
		"the track window is the view's own start and span")
	# The video-export dialog, opened as the 🎬 button does, prefilled.
	tl.call("_on_export_clim_mp4_pressed")
	for _i in 5:
		await tree.process_frame
	var dlg: Node = tl.get("_clim_options_dialog")
	if dlg != null and is_instance_valid(dlg):
		var opts: Dictionary = dlg.get("_opts")
		_ok(float(opts.get("start_abs", NAN)) == a and float(opts.get("end_abs", NAN)) == b,
			"the video-export dialog is prefilled with the exact selection")
		var fr: Variant = dlg.get("_frame")
		if fr != null:
			fr.call("close")
		for _i in 3:
			await tree.process_frame
	else:
		_ok(false, "the video-export dialog opened")
	su.call("set_selection_abs", NAN, NAN)
	return {"ok": _fails.is_empty(), "fails": _fails}
