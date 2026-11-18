extends RefCounted

## The timeline bar's size controls and modals over it, with REAL input
## (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/timeline_bar_modes_check.gd -Label tl_modes
## Ctrl+wheel over a data track makes it taller / shorter (and does not zoom);
## a plain wheel still zooms; the ▼ button goes full → compact → hidden, the
## "Timeline" tab and ▲ bring it back, F2 cycles; the HUD's timeline height
## follows each size; a modal (Settings) covers the bar, full screen.
## Shots under screenshots\tl_modes\.

const HI := preload("res://core/terrain/harness/harness_input.gd")

var _fails: Array = []
var _dir := "user://screenshots/tl_modes"


func _ok(cond: bool, what: String) -> void:
	print("tl-modes %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _shot(main: Node, name: String) -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wheel(vp: Viewport, pos: Vector2, up: bool, ctrl: bool) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
		ev.pressed = pressed
		ev.ctrl_pressed = ctrl
		ev.factor = 1.0
		ev.position = pos
		ev.global_position = pos
		vp.push_input(ev, true)
	await HI._tree().process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var tl: Control = main.get_node_or_null("UILayer/TimelineUI")
	_ok(tl != null, "TimelineUI found")
	if tl == null:
		return {"ok": false, "fails": _fails}
	if is_instance_valid(CursorController):
		CursorController.set_paused(true)   # free cursor, like a player reaching for the bar
	tl.call("set_bar_mode", 0, false)
	await _frames(tree, 4)
	var layout: Object = tl.get("_track_layout")
	var track: Control = tl.get("_track")
	var view: Object = tl.get("_track_view")

	# A waveform track to resize (add one if the player's prefs show none).
	var y := -1.0
	for yy in range(0, int(track.size.y)):
		if int(layout.call("track_index_at", float(yy))) >= 0:
			y = float(yy) + 4.0
			break
	if y < 0.0:
		layout.call("add_weather_track", "temperature")
		tl.call("_sync_scrubber_row_height")
		tl.call("_request_bar_layout")
		await _frames(tree, 4)
		for yy in range(0, int(track.size.y)):
			if int(layout.call("track_index_at", float(yy))) >= 0:
				y = float(yy) + 4.0
				break
	_ok(y >= 0.0, "a data track to resize")
	var idx := int(layout.call("track_index_at", y))
	var td: Object = layout.get("tracks")[idx]
	var h0 := float(td.get("height"))
	var stack0 := float(tl.call("get_stack_height"))
	var span0 := float(view.get("span"))
	var pos := track.get_global_transform() * Vector2(track.size.x * 0.5, y)
	_shot(main, "00_full")
	for _i in 3:
		await _wheel(vp, pos, true, true)
	await _frames(tree, 3)
	var h1 := float(td.get("height"))
	_ok(absf(h1 - h0 - 18.0) < 0.01 or h1 >= 180.0, "Ctrl+wheel up ×3 grows the track %.0f → %.0f px" % [h0, h1])
	_ok(float(view.get("span")) == span0, "Ctrl+wheel over a track does not zoom")
	_ok(float(tl.call("get_stack_height")) > stack0 + 1.0, "the bar grows with it (%.0f → %.0f)" % [stack0, float(tl.call("get_stack_height"))])
	_ok(absf(HudLayout.timeline_height() - float(tl.call("get_stack_height"))) < 0.5, "the HUD reads the new height")
	_shot(main, "01_track_taller")
	for _i in 8:
		await _wheel(vp, pos, false, true)
	await _frames(tree, 3)
	var h2 := float(td.get("height"))
	# Measured against the grown height: a saved track already at the 12 px
	# floor (both test worlds' are) can only come back down to it.
	_ok(h2 < h1 and h2 >= 12.0, "Ctrl+wheel down shrinks it (%.0f → %.0f px, floor 12)" % [h1, h2])
	_ok(h2 <= maxf(h0, 12.0), "8 notches down are back at or under the start (%.0f px)" % h0)
	_shot(main, "02_track_shorter")
	# Plain wheel still zooms.
	await _wheel(vp, pos, true, false)
	await _frames(tree, 2)
	if float(view.get("span")) == span0:   # already at the closest zoom
		await _wheel(vp, pos, false, false)
		await _frames(tree, 2)
	_ok(float(view.get("span")) != span0, "plain wheel still zooms the time span (%.1f → %.1f h)" % [span0, float(view.get("span"))])
	view.call("set_span", span0)
	td.set("height", h0)
	tl.call("_sync_scrubber_row_height")
	tl.call("_request_bar_layout")
	await _frames(tree, 4)

	# ▼ → compact.
	var full_h := float(tl.call("get_stack_height"))
	var down: Button = tl.get("_bar_down_btn")
	var up: Button = tl.get("_bar_up_btn")
	_ok(down != null and up != null and down.is_visible_in_tree(), "the size buttons are on the bar")
	_ok(up.disabled, "▲ is disabled at full size")
	await HI.click(vp, HI.center_of(down))
	await _frames(tree, 4)
	_ok(int(tl.call("get_bar_mode")) == 1, "▼ makes it compact")
	var comp_h := float(tl.call("get_stack_height"))
	_ok(comp_h < full_h, "compact is shorter (%.0f → %.0f)" % [full_h, comp_h])
	_ok(absf(tl.size.y - comp_h) < 1.5, "the bar's rect follows (%.0f)" % tl.size.y)
	_shot(main, "03_compact")
	# Ctrl+wheel over the clips lane in compact does not resize anything.
	_ok(int(layout.call("track_index_at", y)) < 0, "no data track is laid out in compact")
	# ▼ → hidden.
	await HI.click(vp, HI.center_of(down))
	await _frames(tree, 4)
	_ok(int(tl.call("get_bar_mode")) == 2, "▼ again hides it")
	var bg: Control = tl.get("_bar_bg")
	var tab: Button = tl.get("_bar_tab")
	_ok(bg != null and not bg.visible, "the bar is hidden")
	_ok(tab != null and tab.is_visible_in_tree(), "the Timeline tab shows")
	_ok(float(tl.call("get_stack_height")) <= 30.0, "hidden leaves only the tab (%.0f)" % float(tl.call("get_stack_height")))
	_ok(tl.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the empty strip lets clicks through")
	var tr := tab.get_global_rect()
	var vr := vp.get_visible_rect()
	_ok(tr.end.y <= vr.end.y + 0.5 and tr.position.y >= vr.end.y - 32.0, "the tab sits at the bottom of the screen")
	_shot(main, "04_hidden")
	# The tab restores the last shown size (compact).
	await HI.click(vp, HI.center_of(tab))
	await _frames(tree, 4)
	_ok(int(tl.call("get_bar_mode")) == 1, "the tab brings the bar back (compact)")
	await HI.click(vp, HI.center_of(up))
	await _frames(tree, 4)
	_ok(int(tl.call("get_bar_mode")) == 0, "▲ restores the full bar")
	_ok(absf(float(tl.call("get_stack_height")) - full_h) < 0.5, "full height is back")
	# F2 cycles.
	await HI.key(vp, KEY_F2)
	await _frames(tree, 2)
	_ok(int(tl.call("get_bar_mode")) == 1, "F2: full → compact")
	await HI.key(vp, KEY_F2)
	await HI.key(vp, KEY_F2)
	await _frames(tree, 2)
	_ok(int(tl.call("get_bar_mode")) == 0, "F2 ×2 more: hidden → full")

	# A modal covers the timeline.
	var sp: Node = tl.get("_settings_panel")
	_ok(sp != null, "settings panel")
	if sp != null:
		sp.call("open")
		await _frames(tree, 6)
		var cp: Control = sp.get("_center_panel")
		var r := cp.get_global_rect()
		var bar_top := tl.get_global_rect().position.y
		_ok(UiFit.draws_over_timeline(cp), "the settings panel draws over the bar")
		_ok(r.end.y > bar_top + 20.0, "the modal reaches over the timeline (bottom %.0f, bar top %.0f)" % [r.end.y, bar_top])
		# Modals fill the screen edge to edge since UiFit.fill (2026-11-10);
		# the old rule kept them UiFit.MARGIN inside it.
		var inner := UiFit.MARGIN if not UiFit.FULLSCREEN else 0.0
		_ok(r.end.y <= vr.end.y - inner + 1.0, "and stays on the screen (bottom %.0f, screen %.0f)" % [r.end.y, vr.end.y])
		_ok(r.size.y > vr.size.y - HudLayout.timeline_height() - UiFit.MARGIN * 2.0 + 1.0 or r.size.y >= 879.0,
			"it is taller than the old above-the-bar area (%.0f px)" % r.size.y)
		_shot(main, "05_modal_over_timeline")
		sp.call("close")
		await _frames(tree, 3)
	var rb_tl := tl.get_global_rect()
	_ok(rb_tl.size.y > 40.0, "the bar is still there after the modal")
	print("tl-modes RESULT %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
