class_name ArtPackMount
extends Node
## Mounts the release ART ADD-ON: the gitignored game art (built-in maps,
## Imported Models, Starshade, player + NPC rigs) shipped beside an exported
## game as `simbiogenesis-art-*.pck` files (tools/release/build_release.py).
##
## FIRST autoload on purpose: every later autoload and scene may load art by
## path, and a pack mounted after that is too late for them. Runs only in an
## exported game — a project opened from its folder has the art as files.
##
## Packs mount with replace_files = false: an art pack carries copies of the
## scripts its scenes depend on, and the game's own (newer) copy must win.
##
## Search order (all of them; a file name is mounted once):
##   <folder of the executable>/ and its art/
##   macOS: <App>.app/Contents/Resources/, and the folder holding the .app + art/
##   user://art/
##   --art-dir=<folder> on the command line (after "--")

const PREFIX := "simbiogenesis-art-"

## File names mounted, in order. Read by the launch hub's footer and the
## Share modal's note.
static var mounted: PackedStringArray = PackedStringArray()


func _init() -> void:
	if not OS.has_feature("template"):
		return
	for dir in search_dirs():
		mount_from(dir)
	if mounted.is_empty():
		print("ArtPacks: no art add-on next to the game — built-in maps and art models are not available")


static func search_dirs() -> PackedStringArray:
	var out := PackedStringArray()
	var exe_dir := OS.get_executable_path().get_base_dir()
	out.append(exe_dir)
	out.append(exe_dir.path_join("art"))
	if OS.get_name() == "macOS":
		# exe = <X>.app/Contents/MacOS/<name>
		var contents := exe_dir.get_base_dir()
		out.append(contents.path_join("Resources"))
		var beside_app := contents.get_base_dir().get_base_dir()
		out.append(beside_app)
		out.append(beside_app.path_join("art"))
	out.append(ProjectSettings.globalize_path("user://art"))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--art-dir="):
			out.append(a.trim_prefix("--art-dir="))
	return out


static func mount_from(dir: String) -> int:
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	var names := PackedStringArray()
	for f in d.get_files():
		if f.begins_with(PREFIX) and f.get_extension().to_lower() == "pck":
			names.append(f)
	names.sort()
	var n := 0
	for f in names:
		if mounted.has(f):
			continue
		var path := dir.path_join(f)
		if ProjectSettings.load_resource_pack(path, false):
			mounted.append(f)
			n += 1
			var uids := _register_uids(f.get_basename().trim_prefix(PREFIX))
			print("ArtPacks: mounted %s (%d uids)" % [path, uids])
		else:
			push_warning("ArtPacks: could not mount %s" % path)
	return n


## Godot does not merge a mounted pack's uid cache, so every uid:// reference
## to the art would fall back to its text path with a warning. The build
## writes each pack's table to res://art_uids/<group>.txt ("uid<TAB>path"
## per line). A uid the game already knows is left alone.
static func _register_uids(group: String) -> int:
	var f := FileAccess.open("res://art_uids/%s.txt" % group, FileAccess.READ)
	if f == null:
		return 0
	var n := 0
	while not f.eof_reached():
		var line := f.get_line()
		var tab := line.find("\t")
		if tab <= 0:
			continue
		var id := ResourceUID.text_to_id(line.substr(0, tab))
		if id == ResourceUID.INVALID_ID or ResourceUID.has_id(id):
			continue
		ResourceUID.add_id(id, line.substr(tab + 1))
		n += 1
	return n


static func has_art() -> bool:
	return not mounted.is_empty()
