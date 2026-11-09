extends SceneTree

## The molecule lens's worked examples, one PNG per step (NOT a selftest):
## runs the biochar reactor's batch to a few moments, points the lens at the
## vessel (then a condenser) and shoots each storyboard before / while the
## bonds break / after. How the ball-and-stick look is reviewed.
## WINDOWED; APPDATA at a scratch folder.
##   Godot --path . --windowed --resolution 1000x800 --script res://tools/diag/tclab_lens_look_diag.gd -- --out=<dir>

const LensScript := preload("res://scenes/ui/tclab_molecule_lens.gd")

var _out := "user://tclab_lens"
var _lens: Control
var _sim: TcProcSim
var _plan: Array = []          # [[label, cv, lens seconds to advance]]
var _i := 0
var _wait := 0
var _left := 0.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			_out = str(a).substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.13, 0.15)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	_lens = LensScript.new()
	_lens.position = Vector2(40, 40)
	root.add_child(_lens)
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	_sim = TcProcSim.create(d)
	# Hours into the batch, then every example the lens offers there.
	for h in [0.6, 1.6, 2.6, 3.2]:
		_plan.append(["seek", h])
		for k in 4:
			for step in [["before", 0.6], ["break", 2.3], ["after", 5.2]]:
				_plan.append(["shot", "%.1fh_%d_%s" % [h, k, step[0]], float(step[1])])
			_plan.append(["next"])
	_plan.append(["cond"])
	for step2 in [["before", 0.6], ["after", 5.2]]:
		_plan.append(["shot", "condenser_%s" % step2[0], float(step2[1])])


func _process(_dt: float) -> bool:
	if _wait > 0:
		_wait -= 1
		return false
	if _left > 0.0:
		var st: float = minf(_left, 0.1)
		_lens.call("update_lens", st / 1.29, true, 60.0)
		_left -= st
		return false
	if _i >= _plan.size():
		print("lens look: done, %s" % ProjectSettings.globalize_path(_out))
		return true
	var p: Array = _plan[_i]
	match str(p[0]):
		"seek":
			_sim.run_for(float(p[1]) * 3600.0 - _sim.t_s)
			_lens.call("show_cv", _sim, _sim.vessel_cv)
			print("lens look: %.1f h, wood rates %s, reactions %s" % [float(p[1]), _lens.call("wood_rates"), _sim.react_rate[_sim.vessel_cv]])
			_i += 1
		"cond":
			var c := TcProcNet.cv_of_part(_sim.net, "p11", "product")
			_lens.call("show_cv", _sim, c)
			print("lens look: condenser reactions %s" % [_sim.react_rate[c]])
			_i += 1
		"next":
			# Run this example out so the lens moves to its next one.
			_left = 3.2
			_i += 1
		"shot":
			var t_now := float((_lens.call("debug_state") as Dictionary)["t"])
			if t_now < float(p[2]) - 0.05 and int(p.size()) == 3:
				_left = float(p[2]) - t_now
				p.append(true)
				return false
			_wait = 2
			p[0] = "grab"
		"grab":
			var img := root.get_texture().get_image()
			var r := Rect2i(Vector2i(_lens.position), Vector2i(_lens.size))
			img.get_region(r).save_png("%s/%s.png" % [_out, str(p[1])])
			print("lens look: %s %s" % [str(p[1]), _lens.call("debug_state")])
			_i += 1
	return false
