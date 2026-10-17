class_name AssetPackReader
extends RefCounted

## Opens a pack (all its parts) and decides whether it may be installed at
## all. Nothing is extracted here: the importer previews from the manifest.
##
## A pack is refused outright — not partly installed — when:
##   * it has no manifest, or a newer format than this build understands;
##   * a part named in the manifest is missing beside the first;
##   * ANY entry is unsafe (zip-slip, absolute path), is code, is a secret,
##     is a Godot text resource or raw .cfg outside the art section, or is
##     not listed in the manifest (AssetPackFormat.entry_allowed).
## Soft problems are warnings: a different game commit, low disk space.


## Returns {ok, error, warnings, manifest, base, parts: Array[String],
## where: {zip: part index 0-based}, hashes: {zip: sha256}, sections:
## {sec: {files, bytes}}}.
static func open(path: String, project_root: String = "res://", space_dir: String = "user://") -> Dictionary:
	var out := {"ok": false, "error": "", "warnings": [], "manifest": {}, "base": "", "parts": [],
		"where": {}, "hashes": {}, "sections": {}}
	var base := base_part(path)
	out["base"] = base
	if not FileAccess.file_exists(base):
		out["error"] = "This is part of a bigger pack — %s needs to be in the same folder." % base.get_file()
		return out
	var zr := ZIPReader.new()
	if zr.open(base) != OK:
		out["error"] = "This file is not a zip archive."
		return out
	if not zr.file_exists(AssetPackFormat.MANIFEST):
		zr.close()
		out["error"] = "This zip is not a SIMbiogenesis asset pack (no %s inside)." % AssetPackFormat.MANIFEST
		return out
	var parsed: Variant = JSON.parse_string(zr.read_file(AssetPackFormat.MANIFEST).get_string_from_utf8())
	zr.close()
	if not parsed is Dictionary:
		out["error"] = "The pack's manifest is damaged."
		return out
	var man: Dictionary = parsed
	out["manifest"] = man
	if int(man.get("format", 0)) < 1 or int(man.get("format", 0)) > AssetPackFormat.FORMAT:
		out["error"] = "This pack was made by a newer version of the game (format %s). Update the game first." \
			% str(man.get("format", "?"))
		return out
	var files: Dictionary = man.get("files", {}) if man.get("files", {}) is Dictionary else {}
	var part_names: Array = man.get("part_names", []) if man.get("part_names", []) is Array else []
	if part_names.is_empty():
		part_names = [base.get_file()]
	var parts: Array[String] = []
	for i in part_names.size():
		var pp := AssetPackFormat.part_path(base, i + 1)
		if not FileAccess.file_exists(pp):
			out["error"] = "Part %d of %d is missing: put %s in the same folder as %s." \
				% [i + 1, part_names.size(), pp.get_file(), base.get_file()]
			return out
		parts.append(pp)
	out["parts"] = parts
	var where := {}
	var hashes := {}
	for i in parts.size():
		var r := ZIPReader.new()
		if r.open(parts[i]) != OK:
			out["error"] = "%s could not be opened." % parts[i].get_file()
			return out
		for entry in r.get_files():
			if entry.ends_with("/"):
				continue
			if not AssetPackFormat.entry_allowed(entry):
				r.close()
				out["error"] = "The pack contains a file that may not be installed: %s" % entry
				return out
			if entry == AssetPackFormat.MANIFEST or entry == AssetPackFormat.HASHES:
				continue
			if not files.has(entry):
				r.close()
				out["error"] = "The pack contains a file its manifest does not list: %s" % entry
				return out
			where[entry] = i
		if r.file_exists(AssetPackFormat.HASHES):
			var hp: Variant = JSON.parse_string(r.read_file(AssetPackFormat.HASHES).get_string_from_utf8())
			if hp is Dictionary and (hp as Dictionary).get("files", {}) is Dictionary:
				hashes.merge((hp as Dictionary)["files"])
		r.close()
	for z in files:
		if not where.has(z):
			out["error"] = "The pack is incomplete: %s is missing." % str(z)
			return out
	out["where"] = where
	out["hashes"] = hashes
	var sections := {}
	for z in files:
		var sec := str(z).get_slice("/", 0)
		if not sections.has(sec):
			sections[sec] = {"files": 0, "bytes": 0}
		sections[sec]["files"] = int(sections[sec]["files"]) + 1
		sections[sec]["bytes"] = int(sections[sec]["bytes"]) + int((files[z] as Dictionary).get("size", 0))
	out["sections"] = sections
	var mine := AssetPackFormat.game_commit(project_root)
	var theirs := str(man.get("game_commit", ""))
	if not mine.is_empty() and not theirs.is_empty() and mine != theirs:
		out["warnings"].append("Made with a different version of the game (%s, you have %s). It will most likely work; if something looks wrong, update to the same version." \
			% [theirs.substr(0, 7), mine.substr(0, 7)])
	var da := DirAccess.open(space_dir)
	if da != null:
		var left := da.get_space_left()
		if left > 0 and left < int(man.get("bytes", 0)) * 1.1:
			out["warnings"].append("There may not be enough disk space (%s free, the pack is %s)." \
				% [AssetPackFormat.human_size(left), AssetPackFormat.human_size(int(man.get("bytes", 0)))])
	out["ok"] = true
	return out


## Part 1's path for any part of a pack ("x.simpack.002.zip" -> "x.simpack.zip").
static func base_part(path: String) -> String:
	var fn := path.get_file()
	var re := RegEx.new()
	re.compile("^(.*)\\.simpack\\.\\d{3}\\.zip$")
	var m := re.search(fn)
	if m != null:
		return path.get_base_dir().path_join(m.get_string(1) + AssetPackFormat.EXT)
	return path


## Quick test for a dropped file: is it a pack (has a manifest)?
static func looks_like_pack(path: String) -> bool:
	if not path.to_lower().ends_with(".zip"):
		return false
	var zr := ZIPReader.new()
	if zr.open(base_part(path)) != OK:
		return false
	var ok := zr.file_exists(AssetPackFormat.MANIFEST)
	zr.close()
	return ok
