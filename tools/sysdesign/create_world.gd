extends SceneTree

## Make a NEW, empty world on the map of an existing world (headless):
##
##   Godot --headless --path . --script tools/sysdesign/create_world.gd -- \
##       --from=<world id> --name="<name>" [--copy=soi,water_features,channel_tiles]
##
## Only adds a folder under user://worlds; no existing world is touched.
## Prints `sysdesign world: <id>`. A world of that name on that map is reused.


func _initialize() -> void:
	var from := ""
	var world_name := "New world"
	var copy := PackedStringArray(["soi.json", "water_features.json"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--from="):
			from = a.trim_prefix("--from=")
		elif a.begins_with("--name="):
			world_name = a.trim_prefix("--name=")
		elif a.begins_with("--copy="):
			copy = a.trim_prefix("--copy=").split(",", false)
	var src := WorldStore.get_world(from)
	if src.is_empty():
		print("sysdesign world: no source world '%s'" % from)
		quit(1)
		return
	for w: Dictionary in WorldStore.list():
		if str(w.get("name", "")) == world_name:
			print("sysdesign world: %s (already there)" % str(w.get("id", "")))
			quit(0)
			return
	var rec := WorldStore.create(src.get("map", {}) as Dictionary, world_name)
	var sd := WorldStore.world_dir(str(src["id"]))
	var dd := WorldStore.world_dir(str(rec["id"]))
	for f in copy:
		if FileAccess.file_exists(sd.path_join(f)):
			DirAccess.copy_absolute(sd.path_join(f), dd.path_join(f))
			print("  copied ", f)
	print("sysdesign world: %s" % str(rec["id"]))
	quit(0)
