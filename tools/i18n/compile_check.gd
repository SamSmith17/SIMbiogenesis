extends SceneTree

## Recompiles every .gd listed in a file (one res-relative path a line) and
## reports the ones that fail. Used after tools/i18n/codemod.py:
##   Godot --headless --path . --script tools/i18n/compile_check.gd -- --list=<file>

func _initialize() -> void:
	var list := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--list="):
			list = a.substr(7)
	var bad := 0
	var n := 0
	for ln in FileAccess.get_file_as_string(list).split("\n"):
		var p := ln.strip_edges()
		if p.is_empty() or not p.ends_with(".gd"):
			continue
		n += 1
		var s := GDScript.new()
		s.source_code = FileAccess.get_file_as_string("res://" + p)
		s.resource_path = "res://" + p
		var err := s.reload(true)
		if err != OK:
			bad += 1
			print("compile FAIL: ", p, " (", error_string(err), ")")
	print("compile_check: %d scripts, %d failed — %s" % [n, bad, "PASS" if bad == 0 else "FAIL"])
	quit(1 if bad else 0)
