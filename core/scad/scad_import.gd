extends SceneTree

## Seeds scad_library/ from an external Thingiverse-style part library (folders of
## <Category>/<project>/[files/]*.scad with adjacent LICENSE.txt / README.txt).
## Copies ONLY .scad files (skips STLs/images/desktop.ini), preserving each file's
## directory so sibling `include <>`s resolve, classifies the nearest LICENSE.txt
## into real credits entries, and captures the README description for the store UI.
## Idempotent: existing credits entries are never overwritten.
##
## Run with:
##   Godot.exe.exe --headless --path . --script core/scad/scad_import.gd -- \
##       --src="C:/Users/notsa/Documents/OpenSCAD Part Library"
## Then build the catalog with scad_ingest.gd.

const CatalogScript := preload("res://core/scad/scad_catalog.gd")

const DEST := "res://scad_library"
const CREDITS_JSON := "res://credits/credits.json"
const DOCS_JSON := "res://scad_library/part_docs.json"
const SKIP_DIR := "ZIP Folders"


func _initialize() -> void:
	var src := _arg("--src", "")
	if src.is_empty():
		print("ERROR: pass --src=\"<path to part library>\"")
		quit(1)
		return
	src = src.replace("\\", "/").rstrip("/")
	if not DirAccess.dir_exists_absolute(src):
		print("ERROR: source not found: %s" % src)
		quit(1)
		return
	print("== SCAD import from: %s ==" % src)

	var scad_dirs := _dirs_with_scad(src)
	var credits := _load_json(CREDITS_JSON, {"entries": []})
	var existing_paths := {}
	for e in credits.get("entries", []):
		if e is Dictionary and e.has("local_path"):
			existing_paths[String(e["local_path"])] = true

	var docs := {}
	var copied := 0
	var lic_counts := {}
	var restricted: Array = []
	var unknown_lic: Array = []
	var added_credits := 0

	for sdir_raw in scad_dirs:
		var sdir := String(sdir_raw)
		var rel := sdir.substr(src.length() + 1)  # path under src
		var category := String(rel.split("/")[0])
		var lic: Dictionary = _nearest_license(sdir, src)
		var desc := _nearest_readme(sdir, src)
		var status := CatalogScript.license_status_from_classification(lic)

		for fname in _scad_files_in(sdir):
			var src_file := sdir.path_join(fname)
			var dest_rel := DEST.path_join(_sanitize_rel(rel)).path_join(fname)
			if not _copy_text(src_file, dest_rel):
				print("  WARN copy failed: %s" % src_file)
				continue
			copied += 1

			docs[fname] = {
				"category": category,
				"description": desc,
				"license_spdx": lic["spdx"],
				"author": lic["author"],
				"source_url": lic["source_url"],
				"restricted": lic["restricted"],
				"non_commercial": lic["non_commercial"],
				"no_derivatives": lic["no_derivatives"],
				"license_status": status,
				"rel_source": rel.path_join(fname),
			}
			lic_counts[lic["spdx"]] = int(lic_counts.get(lic["spdx"], 0)) + 1
			if lic["restricted"]:
				restricted.append(fname)
			if String(lic["spdx"]) == "unknown":
				unknown_lic.append(fname)

			# Credits entry (skip if this local_path already recorded).
			var local_path := _sanitize_rel(rel).path_join(fname)
			var scad_local := DEST.substr(6).path_join(local_path)  # strip "res://"
			if not existing_paths.has(scad_local):
				credits["entries"].append(_credit_entry(fname, category, lic, status, scad_local))
				existing_paths[scad_local] = true
				added_credits += 1

	_write_json(DOCS_JSON, docs)
	_write_json(CREDITS_JSON, credits)

	print("\n== Import summary ==")
	print("  .scad copied:        %d  (from %d dirs)" % [copied, scad_dirs.size()])
	print("  credits entries new: %d" % added_credits)
	print("  license breakdown:")
	var keys := lic_counts.keys()
	keys.sort()
	for k in keys:
		print("     %-18s %d" % [k, lic_counts[k]])
	print("  restricted (NC/ND, need decision): %d %s" % [restricted.size(), str(restricted) if restricted.size() <= 12 else "(%d files)" % restricted.size()])
	print("  unknown license (empty/odd docs):  %d %s" % [unknown_lic.size(), str(unknown_lic) if unknown_lic.size() <= 12 else ""])
	print("  wrote %s + credits stubs" % DOCS_JSON)
	print("  NEXT: Godot.exe.exe --headless --path . --script core/scad/scad_ingest.gd")
	quit(0)


# -- Traversal -----------------------------------------------------------------

## All directories (absolute) under src that directly contain >=1 .scad, skipping
## the ZIP Folders tree.
func _dirs_with_scad(src: String) -> Array:
	var out: Array = []
	var stack: Array = [src]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		var has_scad := false
		for f in d.get_files():
			if f.to_lower().ends_with(".scad"):
				has_scad = true
				break
		if has_scad:
			out.append(dir)
		for sub in d.get_directories():
			if sub == SKIP_DIR:
				continue
			stack.append(dir.path_join(sub))
	out.sort()
	return out


func _scad_files_in(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.to_lower().ends_with(".scad"):
			out.append(f)
	out.sort()
	return out


## Walk up from dir to src, returning the first LICENSE.* classified.
func _nearest_license(dir: String, src: String) -> Dictionary:
	var cur := dir
	while cur.length() >= src.length():
		var d := DirAccess.open(cur)
		if d != null:
			for f in d.get_files():
				if f.to_lower().begins_with("license"):
					return CatalogScript.classify_license(_read_text(cur.path_join(f)))
		if cur == src:
			break
		cur = cur.get_base_dir()
	return CatalogScript.classify_license("")


func _nearest_readme(dir: String, src: String) -> String:
	var cur := dir
	while cur.length() >= src.length():
		var d := DirAccess.open(cur)
		if d != null:
			for f in d.get_files():
				if f.to_lower().begins_with("readme"):
					return CatalogScript.extract_readme_description(_read_text(cur.path_join(f)))
		if cur == src:
			break
		cur = cur.get_base_dir()
	return ""


# -- Credits -------------------------------------------------------------------

func _credit_entry(fname: String, category: String, lic: Dictionary, status: String, local_path: String) -> Dictionary:
	var notes := "Imported from OpenSCAD Part Library (%s)." % category
	if String(lic["spdx"]) == "unknown":
		notes += " License doc empty/unrecognized — confirm on Thingiverse before shipping."
	elif lic["restricted"]:
		notes += " RESTRICTED (%s%s) — needs a licensing decision before shipping." % [
			"non-commercial " if lic["non_commercial"] else "",
			"no-derivatives" if lic["no_derivatives"] else ""]
	return {
		"id": "scad-%s" % fname.get_basename(),
		"name": fname.get_basename(),
		"category": "scad-part",
		"role": "Parametric OpenSCAD part in the in-game hardware store",
		"author": lic["author"] if String(lic["author"]) != "" else null,
		"source": lic["source_url"] if String(lic["source_url"]) != "" else null,
		"license": lic["spdx"],
		"attribution_required": lic["attribution_required"],
		"share_alike": lic["share_alike"],
		"commercial_ok": not lic["non_commercial"],
		"no_derivatives": lic["no_derivatives"],
		"local_path": local_path,
		"status": "pending-verification" if status == "pending-verification" else ("verified" if status == "verified" else "restricted"),
		"notes": notes,
	}


# -- IO helpers ----------------------------------------------------------------

func _sanitize_rel(rel: String) -> String:
	var segs := rel.split("/")
	var out := PackedStringArray()
	for s in segs:
		out.append(String(s).replace(" ", "_"))
	return "/".join(out)


func _copy_text(src_abs: String, dest_res: String) -> bool:
	var data := _read_bytes(src_abs)
	if data.is_empty():
		return false
	var dest_abs := ProjectSettings.globalize_path(dest_res)
	DirAccess.make_dir_recursive_absolute(dest_abs.get_base_dir())
	var f := FileAccess.open(dest_abs, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true


func _read_text(abs: String) -> String:
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _read_bytes(abs: String) -> PackedByteArray:
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


func _load_json(res_path: String, fallback: Dictionary) -> Dictionary:
	var abs := ProjectSettings.globalize_path(res_path)
	if not FileAccess.file_exists(abs):
		return fallback
	var parsed = JSON.parse_string(_read_text(abs))
	if typeof(parsed) != TYPE_DICTIONARY:
		return fallback
	if not parsed.has("entries") and fallback.has("entries"):
		parsed["entries"] = []
	return parsed


func _write_json(res_path: String, data: Dictionary) -> void:
	var abs := ProjectSettings.globalize_path(res_path)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % res_path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()


func _arg(key: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(key + "="):
			return a.substr(key.length() + 1)
	return fallback
