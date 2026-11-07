extends SceneTree

## Every ESP board in the designer's wiring diagram, one PNG each (WINDOWED,
## not a selftest; point APPDATA at a scratch folder):
##   Godot --path . --windowed --resolution 1600x1000 --script res://tools/diag/esplab_board_sheet.gd -- --out=<dir> [--board=<id>] [--preset=<id>]
## Each board gets a small common set (a BME280, a relay, a soil probe) so the
## pinout chips, wires and part cards show; --preset draws a built-in design.

const Diagram := preload("res://scenes/ui/esplab_diagram.gd")

var _out := "user://esplab_board_sheet"
var _only := ""
var _preset := ""


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--board="):
			_only = a.substr(8)
		elif a.begins_with("--preset="):
			_preset = a.substr(9)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	UiThemeBuilder.install(root)
	var dg: Control = Diagram.new()
	root.add_child(dg)
	dg.position = Vector2.ZERO
	dg.size = root.size
	var jobs: Array = []
	if _preset != "":
		for b in EspPresets.builtins():
			if _preset == "all" or str(b["id"]) == _preset:
				jobs.append(["preset_" + str(b["id"]), (b["spec"] as Dictionary).duplicate(true)])
	else:
		for id in EspBoards.ids():
			if _only != "" and id != _only:
				continue
			var spec := EspSpec.empty("Garden probe")
			spec["board"] = id
			for pid in ["bme280", "relay_1ch", "soil_cap"]:
				(spec["parts"] as Array).append({"part": pid})
			jobs.append([str(id), spec])
	for j in jobs:
		var d := EspDesign.solve(j[1])
		dg.call("set_design", d, d["spec"])
		var rd := {}
		for e in d["entities"]:
			if str(e["iid"]) == "":
				continue
			if not rd.has(str(e["iid"])):
				rd[str(e["iid"])] = PackedStringArray()
			(rd[str(e["iid"])] as PackedStringArray).append("%s  21.4 %s" % [str(e["short"]), str(e["unit"])])
		dg.call("set_readings", rd)
		dg.call("fit")
		for _i in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := "%s/%s.png" % [_out, str(j[0])]
		root.get_texture().get_image().save_png(path)
		print("esplab sheet: %s (%d errors in the design)" % [path, EspDesign.count_level(d, "error")])
	quit(0)
