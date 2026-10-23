extends RefCounted

## The projection canvas (I) after the 2026-10-23 split, on a real world:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/projection_warp_probe.gd -Label projection
## 1. No dashboard left (the BL/BR "sim vs live" quadrants, the divider, the
##    old Polygon2D warp); two sources (sim camera | live feed), one
##    ProjectionWarp with two quads.
## 2. Hidden: the canvas's SubViewports do not render and F9 does nothing.
## 3. Shown: they render; F9 turns the warp on (calibration opens on a fresh
##    file); a dragged corner pins quad 2 into a keystone; the warped frame is
##    black outside the quads and drawn inside them, and the pixel at the
##    keystone's centre (where its diagonals cross) shows the source.
## 4. The POV overlay (Z) is made on demand, renders only while warped, and has
##    four quads.
## Shots under screenshots\projection\. Nothing is saved (sandbox).

var _fails: Array = []
var _dir := "user://screenshots/projection"


func _ok(cond: bool, what: String) -> void:
	print("projection-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _shot(main: Node, name: String) -> Image:
	DirAccess.make_dir_recursive_absolute(_dir)
	var img := main.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_dir, name])
	return img


func _key_action(target: Node, action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	target.call("_unhandled_input", ev)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var pc: Control = main.call("ensure_projection_canvas")
	_ok(pc != null, "the canvas exists")
	if pc == null:
		return {"ok": false, "fails": _fails}
	await _frames(tree, 2)
	var gone := true
	for n in ["QuadrantBL_Comparison", "QuadrantBR_Comparison", "DividerOverlay", "WarpOutputLayer", "CalibrationOverlay"]:
		if pc.find_child(n, true, false) != null:
			gone = false
			print("projection-check: still there: ", n)
	_ok(gone, "no dashboard or old warp nodes left")
	_ok(pc.find_child("QuadrantTL_SimulatedView", true, false) != null and pc.find_child("QuadrantTR_LiveWebcam", true, false) != null,
		"both sources are there")
	var warp: ProjectionWarp = pc.get("warp")
	_ok(warp != null and warp.quads().size() == 2, "one ProjectionWarp, two quads")
	if warp == null:
		return {"ok": false, "fails": _fails}
	for p in ["ha_client_path", "simulated_battery_soc", "device_names", "warp_enabled"]:
		_ok(not (p in pc), "no '%s' property" % p)

	var sv: SubViewport = pc.get("source_subviewport")
	var tl: SubViewport = pc.get("tl_subviewport")
	pc.visible = false
	await _frames(tree, 2)
	_ok(sv.render_target_update_mode == SubViewport.UPDATE_DISABLED and tl.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"hidden: the canvas's viewports do not render")
	_key_action(warp, &"toggle_projection_warp")
	_ok(not warp.active, "hidden: F9 does nothing")

	pc.visible = true
	await _frames(tree, 6)
	_ok(sv.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "shown: the viewports render")
	_shot(main, "01_canvas")
	_key_action(warp, &"toggle_projection_warp")
	await _frames(tree, 2)
	_ok(warp.active, "shown: F9 turns the warp on")
	_ok(warp.calibrating == (not warp.has_saved()), "a fresh calibration opens on the handles")
	if not warp.calibrating:
		warp.toggle_calibration()
	var key := PackedVector2Array([Vector2(0.55, 0.08), Vector2(0.95, 0.15), Vector2(0.90, 0.85), Vector2(0.58, 0.95)])
	for k in 4:
		warp.set_corner(1, k, key[k])
	warp.select_quad(1)
	await _frames(tree, 4)
	var cimg := _shot(main, "02_calibrating")
	var hp := Vector2i(key[1] * Vector2(cimg.get_width(), cimg.get_height()))
	var hc := cimg.get_pixelv(hp)
	_ok(hc.r > 0.8 and hc.g > 0.4 and hc.b < 0.3, "the active quad's corner handle draws over the quad (%s)" % str(hc))
	# key[0] sits where the panel stood: the panel moves out of its way.
	var panel_rect := (warp.get("_panel") as Control).get_global_rect()
	_ok(not panel_rect.has_point(key[0] * Vector2(cimg.get_width(), cimg.get_height())), "the panel never covers a corner")
	var audit := UiAudit.run(main.get_viewport())
	print("projection-check: audit calibrating — %s" % UiAudit.summary_line(audit))
	for f in audit.get("findings", []):
		if str(f.get("severity", "")) == "error":
			print("projection-check:   %s %s \"%s\" %s" % [f.get("kind"), f.get("path"), str(f.get("text", "")).left(40), str(f.get("rect"))])
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit: no errors while calibrating")
	_ok(HudLayout.has_claim("projection_canvas"), "the canvas hides the HUD while shown")
	warp.toggle_calibration()
	await _frames(tree, 4)
	_ok(not warp.calibrating, "Done leaves calibration with the warp on")
	var img := _shot(main, "03_warped")
	var sz := Vector2(img.get_width(), img.get_height())
	var outside := img.get_pixelv(Vector2i(Vector2(0.52, 0.03) * sz))
	_ok(outside.r < 0.02 and outside.g < 0.02 and outside.b < 0.02, "black outside the quads (%s)" % str(outside))
	var px := PackedVector2Array()
	for v in key:
		px.append(v * sz)
	var c: Variant = Geometry2D.line_intersects_line(px[0], px[2] - px[0], px[1], px[3] - px[1])
	var inside := img.get_pixelv(Vector2i(c as Vector2)) if c != null else Color.BLACK
	_ok(inside.r + inside.g + inside.b > 0.05, "the source is drawn inside the keystone (%s)" % str(inside))
	# The sim pane's frame (not its 3D view, which is black at night).
	var left := img.get_pixelv(Vector2i(Vector2(0.1, 0.92) * sz))
	_ok(left.r + left.g + left.b > 0.05, "quad 1 still draws the sim camera's half (%s)" % str(left))
	warp.set_active(false)
	pc.visible = false
	await _frames(tree, 2)
	_ok(not HudLayout.has_claim("projection_canvas"), "hidden: the HUD is back")

	# The POV overlay, made on demand on a map that does not ship one.
	var pov: Control = main.call("ensure_pov_warp_overlay")
	_ok(pov != null, "the POV overlay exists")
	if pov != null:
		await _frames(tree, 2)
		var pw: ProjectionWarp = pov.get("warp")
		var psv: SubViewport = pov.get("source_subviewport")
		_ok(pw != null and pw.quads().size() == 4, "POV: four quads")
		_ok(psv.render_target_update_mode == SubViewport.UPDATE_DISABLED, "POV: no mirror render while off")
		pov.call("toggle_warp_mode")
		await _frames(tree, 6)
		_ok(pov.visible and psv.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "POV: on and rendering")
		_ok(HudLayout.has_claim("pov_warp"), "POV: the HUD is hidden under it")
		_shot(main, "04_pov")
		pov.call("toggle_warp_mode")
		await _frames(tree, 2)
		_ok(not pov.visible and psv.render_target_update_mode == SubViewport.UPDATE_DISABLED, "POV: off again")
	return {"ok": _fails.is_empty(), "fails": _fails}
