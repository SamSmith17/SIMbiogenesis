extends RefCounted

## The terrain toolbar's Ramp with Height / Top width / Side slope, driven
## with REAL clicks through the viewport (sandbox):
##   tools\harness.ps1 -World <id> -RunScript res://tools/checks/ramp_tool_check.gd -Label <dir>
## Looks down on open ground near the player from a fixed camera, builds a
## +2 m berm (8 m top, 1:2 sides) by clicking its two ends, measures the cross
## section on the ground (top, side, toe, untouched beyond), undoes it, then a
## -1.5 m channel the same way, and undoes that. Clicks are placed at the
## bottom-left and right of the screen on purpose: the old TimeUI /
## HAConnectionUI roots swallowed exactly those. Shots: berm.png, channel.png.

const HarnessInputScript := preload("res://core/terrain/harness/harness_input.gd")

var _fails: Array = []
var _dir := "user://screenshots/ramp_tool"


func _ok(cond: bool, what: String) -> void:
	print("ramp-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var tb: Control = main.find_child("EditToolbarUI", true, false)
	_ok(loader != null and tb != null, "loader + toolbar")
	if loader == null or tb == null:
		return {"ok": false}
	main.set("time_scale", 0.0)
	main.set("day_time", 15.0)
	var player := main.get_node("Player") as Node3D
	# Open ground 40 m north of the player; the ramp runs east-west across it.
	var c := Vector2(player.global_position.x, player.global_position.z - 40.0)
	var gy := float(loader.call("ground_height_at", c.x, c.y))
	var cam := Camera3D.new()
	cam.far = 3000.0
	main.add_child(cam)
	cam.global_position = Vector3(c.x, gy + 70.0, c.y + 45.0)
	cam.look_at(Vector3(c.x, gy, c.y), Vector3.UP)
	main.call("push_camera_claim", "ramp_check", {"camera_id": cam.get_instance_id()})
	await _frames(tree, 10)
	tb.call("open_with_section", "terrain")
	tb.call("_set_active_tool", "ramp")
	await _frames(tree, 5)
	var vp := main.get_viewport()
	var st: Object = tb.get("_state")
	for spec in [["berm", 2.0, 8.0], ["channel", -1.5, 6.0]]:
		var label: String = spec[0]
		var h: float = spec[1]
		var w: float = spec[2]
		st.call("set_tool_param", "ramp", "height_m", h)
		st.call("set_tool_param", "ramp", "width_m", w)
		st.call("set_tool_param", "ramp", "side_run", 2.0)
		# Ends inside the two former dead zones: bottom-left (the HA panel
		# root) and the right-hand column (the TimeUI root), clear of the strip.
		var size := vp.get_visible_rect().size
		var pa := Vector2(size.x * 0.12, size.y * 0.6)
		var pb := Vector2(size.x * 0.90, size.y * 0.6)
		var wa: Variant = tb.call("_pick_at", pa)
		var wb: Variant = tb.call("_pick_at", pb)
		_ok(wa is Vector3 and wb is Vector3, "%s: both screen edges hit the ground" % label)
		if not (wa is Vector3 and wb is Vector3):
			continue
		var a := Vector2((wa as Vector3).x, (wa as Vector3).z)
		var b := Vector2((wb as Vector3).x, (wb as Vector3).z)
		var ya := float(loader.call("ground_height_at", a.x, a.y))
		var yb := float(loader.call("ground_height_at", b.x, b.y))
		var mid := (a + b) * 0.5
		var nrm := (b - a).normalized().orthogonal()
		var before := []
		for off in [0.0, w * 0.5 - 0.5, w * 0.5 + 2.0, w * 0.5 + absf(h) * 2.0 + 3.0]:
			var q: Vector2 = mid + nrm * float(off)
			before.append(float(loader.call("ground_height_at", q.x, q.y)))
		await HarnessInputScript.mouse_move(vp, pa)
		await _frames(tree, 3)
		await HarnessInputScript.click(vp, pa)
		await _frames(tree, 3)
		await HarnessInputScript.mouse_move(vp, pb)
		await _frames(tree, 3)
		await HarnessInputScript.click(vp, pb)
		await _frames(tree, 30)
		var top_want := lerpf(ya, yb, 0.5) + h
		var at := func(off: float) -> float:
			var q: Vector2 = mid + nrm * off
			return float(loader.call("ground_height_at", q.x, q.y))
		var top := float(at.call(0.0))
		var edge := float(at.call(w * 0.5 - 0.5))
		var side := float(at.call(w * 0.5 + 2.0))
		var beyond := float(at.call(w * 0.5 + absf(h) * 2.0 + 3.0))
		print("ramp-check: %s ends (%.1f, %.1f)->(%.1f, %.1f) ground %.2f / %.2f; top %.2f (want %.2f) edge %.2f side %.2f (was %.2f) beyond %.2f (was %.2f)" % [
			label, a.x, a.y, b.x, b.y, ya, yb, top, top_want, edge, side, float(before[2]), beyond, float(before[3])])
		_ok(absf(top - top_want) < 0.2, "%s: the top sits %+.1f m off the grade line" % [label, h])
		_ok(absf(edge - top_want) < 0.3, "%s: flat across the top width" % label)
		var side_want := top_want - signf(h) * 1.0   # 2 m out at 1:2
		_ok(absf(side - side_want) < 0.4 or absf(side - float(before[2])) < 0.3,
			"%s: the side slopes at 1:2 (or has met the ground)" % label)
		_ok(absf(beyond - float(before[3])) < 0.25, "%s: ground past the toe untouched" % label)
		await _frames(tree, 20)
		vp.get_texture().get_image().save_png("%s/%s.png" % [_dir, label])
		loader.call("undo_terrain_sculpt")
		await _frames(tree, 20)
		_ok(absf(float(at.call(0.0)) - float(before[0])) < 0.05, "%s: undo restores the ground" % label)
	tb.call("_exit_mode")
	main.call("pop_camera_claim", "ramp_check")
	cam.queue_free()
	return {"ok": _fails.is_empty(), "failures": _fails}
