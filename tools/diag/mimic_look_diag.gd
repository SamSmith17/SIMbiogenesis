extends SceneTree

## Process picture look sheet (WINDOWED, not a selftest): a tri-clamp
## built-in's P&ID drawn by MimicCanvas at a moment of its batch, one PNG.
## How the symbols and the layout are reviewed (plans/SCADA_PROCESS_PLAN.md).
##   set APPDATA to a scratch folder, then:
##   godot --path . --windowed --resolution 1600x1000 --script res://tools/diag/mimic_look_diag.gd -- --design=biochar_reactor --hours=2 --out=<png>
## --design=<builtin id> (default biochar_genset), --hours=<lab hours run
## before the shot> (default 2), --zoom=<factor on the fit> (default 1),
## --select=<cv index>, --out=<png> (default user://mimic_look.png).

var _frame := 0
var _canvas: Control = null
var _out := "user://mimic_look.png"
var _zoom := 1.0


func _arg(name: String, dflt: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.get_slice("=", 1)
	return dflt


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 2:
		_build()
	elif _frame == 12 and _zoom != 1.0:
		_canvas.call("_zoom_at", _canvas.size * 0.5, _zoom)
	elif _frame == 24:
		var img := root.get_texture().get_image()
		img.save_png(_out)
		print("mimic look: wrote %s (%dx%d), draw %.2f ms" % [ProjectSettings.globalize_path(_out), img.get_width(), img.get_height(),
			float(_canvas.call("draw_cost_ms"))])
		quit(0)
	return false


func _build() -> void:
	var id := _arg("design", "biochar_genset")
	_out = _arg("out", _out)
	_zoom = float(_arg("zoom", "1"))
	var spec := TcPresets.builtin(id)
	if spec.is_empty():
		print("mimic look: no built-in '%s'" % id)
		quit(1)
		return
	var d := TcDesign.solve(spec)
	var sim := TcProcSim.create(d)
	var hours := float(_arg("hours", "2"))
	var t0 := Time.get_ticks_msec()
	sim.run_for(hours * 3600.0)
	var doc := MimicTcSource.build(d, sim.net)
	print("mimic look: %s — %d volumes, %d pipes, %d elements; ran %.1f h in %d ms" % [id, sim.n_cv,
		(doc["pipes"] as Array).size(), (doc["elements"] as Array).size(), hours, Time.get_ticks_msec() - t0])
	for e in doc["elements"]:
		print("  %-10s %-6s cv %-3d %s  at %s size %s" % [e["kind"], e["id"], int(e["cv"]), e["label"], e["pos"], e["size"]])
	_canvas = Control.new()
	_canvas.set_script(load("res://scenes/ui/scada/mimic_canvas.gd"))
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(_canvas)
	_canvas.call("set_doc", doc)
	_canvas.call("set_state", MimicTcSource.state(sim, doc))
	var signs := {}
	for p in doc["pipes"]:
		signs[str(p["id"])] = MimicTcSource.flow_sign(sim, doc, p)
	_canvas.call("set_flow_signs", signs)
	var sel := int(_arg("select", "-1"))
	if sel >= 0:
		_canvas.set("selected_cv", sel)
