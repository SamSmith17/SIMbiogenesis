extends RefCounted

## Which UI swallows the pointer while the edit toolbar is open (sandbox,
## read-only):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/toolbar_input_probe.gd
## Opens the toolbar on each section, pushes a pointer move to a grid of
## screen points and asks the viewport which Control is under each one.
## Every point not over the toolbar's own strip / options bar must reach the
## world (no Control hovered, or a mouse-IGNORE overlay). FAILs listing the
## Controls that block, with their rects.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("tb-input %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var tb: Control = main.find_child("EditToolbarUI", true, false)
	_ok(tb != null, "edit toolbar found")
	if tb == null:
		return {"ok": false}
	var vp := main.get_viewport()
	for section in ["veg", "terrain", "water"]:
		tb.call("open_with_section", section)
		for _i in 20:
			await tree.process_frame
		var strip: Control = tb.get("_strip")
		var options: Control = tb.get("_options")
		var size := vp.get_visible_rect().size
		var blockers := {}
		var probed := 0
		for gy in 9:
			for gx in 17:
				var p := Vector2((float(gx) + 0.5) / 17.0 * size.x, (float(gy) + 0.5) / 9.0 * size.y)
				if strip != null and strip.is_visible_in_tree() and strip.get_global_rect().has_point(p):
					continue
				if options != null and options.is_visible_in_tree() and options.get_global_rect().has_point(p):
					continue
				var ev := InputEventMouseMotion.new()
				ev.position = p
				ev.global_position = p
				vp.push_input(ev, true)
				await tree.process_frame
				probed += 1
				var c := vp.gui_get_hovered_control()
				if c == null or c == tb or c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
					continue
				# The timeline at the bottom is a real panel the player clicks.
				if str(c.get_path()).contains("TimelineUI"):
					continue
				# A tucked HUD panel's pill is a real button.
				if str(c.get_path()).contains("HudPills"):
					continue
				var key := str(c.get_path())
				if not blockers.has(key):
					blockers[key] = {"rect": c.get_global_rect(), "filter": c.mouse_filter,
						"vis": c.visible, "pts": []}
				(blockers[key]["pts"] as Array).append(p)
		for k in blockers.keys():
			var b: Dictionary = blockers[k]
			print("tb-input: [%s] %s rect=%s filter=%d hits=%d e.g. %s" % [
				section, k, str(b["rect"]), int(b["filter"]), (b["pts"] as Array).size(), str((b["pts"] as Array)[0])])
		_ok(blockers.is_empty(), "%s: every world point reaches the world (%d probed, %d blockers)" % [
			section, probed, blockers.size()])
		tb.call("_exit_mode")
		for _i in 5:
			await tree.process_frame
	return {"ok": _fails.is_empty(), "failures": _fails}
