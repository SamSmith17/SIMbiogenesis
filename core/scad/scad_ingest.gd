extends SceneTree

## Library ingestion + license triage for the parametric store (Phase 2). Walks a
## folder of .scad files, parses each Customizer schema, detects external library
## dependencies, does a validation render with default params (if OpenSCAD is
## present), reconciles against credits/credits.json (auto-adding a
## pending-verification stub for any part with NO ledger entry so nothing ships
## uncredited), writes <library>/catalog.json, and prints the clean/needs-dep/
## render-failed/no-license split so the true scope of a large library is visible
## before any store UI is built.
##
## Run with:
##   Godot.exe.exe --headless --path . --script core/scad/scad_ingest.gd
##   Godot.exe.exe --headless --path . --script core/scad/scad_ingest.gd -- --dir=res://scad_library
##
## Non-destructive except: writes <dir>/catalog.json and appends missing stubs to
## credits/credits.json (existing entries are never modified).

const CatalogScript := preload("res://core/scad/scad_catalog.gd")
const RuntimeScript := preload("res://core/scad/scad_runtime.gd")
const ParserScript := preload("res://core/scad/scad_param_parser.gd")
const StlLoaderScript := preload("res://core/machines/stl_loader.gd")

const CREDITS_JSON := "res://credits/credits.json"
const DEFAULT_DIR := "res://scad_library"


func _initialize() -> void:
	var dir := _arg("--dir", DEFAULT_DIR)
	var do_render := not _has_flag("--no-render")
	# Wall-clock budget for the whole render-validation pass (full CGAL renders can
	# take tens of seconds each). Once exceeded, remaining parts are left
	# unvalidated (render.ok = null) rather than blocking the pass. 0 = unlimited.
	var render_budget_ms := int(_arg("--render-budget", "240").to_int()) * 1000
	var render_start := Time.get_ticks_msec()
	print("== SCAD ingest: %s ==" % dir)

	var files := _scan_scad(dir)
	if files.is_empty():
		print("No .scad files found in %s" % dir)
		quit(0)
		return

	var credits := _load_credits()
	var credits_entries: Array = credits.get("entries", [])
	var docs := _load_docs(dir)
	var bin := RuntimeScript.find_openscad()
	print("OpenSCAD: %s" % ("<none — renders skipped>" if bin.is_empty() else bin))

	var parts: Array = []
	var stubs_added: Array = []
	for res_path in files:
		var entry := CatalogScript.build_entry(res_path, credits_entries)

		# Enrich with importer docs (real category from the source folder + readme).
		var doc: Dictionary = docs.get(res_path.get_file(), {})
		if not doc.is_empty():
			entry["category"] = doc.get("category", entry["category"])
			entry["description"] = doc.get("description", "")
			entry["author"] = doc.get("author", "")
			entry["source_url"] = doc.get("source_url", "")
			entry["license_spdx"] = doc.get("license_spdx", "unknown")
			entry["restricted"] = doc.get("restricted", false)

		# Auto-stub credits for parts with no ledger entry at all.
		if entry["license_status"] == "missing":
			var stub := CatalogScript.make_credits_stub(entry)
			credits_entries.append(stub)
			stubs_added.append(stub["id"])
			entry["license_status"] = "pending-verification"

		# Validation render with parsed defaults (coarse for speed), within budget.
		if do_render and not bin.is_empty() and entry["parse_ok"]:
			var over_budget: bool = render_budget_ms > 0 and (Time.get_ticks_msec() - render_start) > render_budget_ms
			if over_budget:
				entry["render"] = {"ok": null, "reason": "skipped (render budget reached)"}
			else:
				entry["render"] = _validate_render(res_path)
		entry["status"] = CatalogScript.finalize_status(entry)
		parts.append(entry)
		_print_part_line(entry)

	# Persist catalog next to the library.
	var catalog := {
		"generated_at": Time.get_datetime_string_from_system(true),
		"library_dir": dir,
		"openscad": bin,
		"parts": parts,
		"summary": _summarize(parts),
	}
	_write_json(dir.path_join("catalog.json"), catalog)

	# Persist any new credits stubs (existing entries untouched).
	if not stubs_added.is_empty():
		credits["entries"] = credits_entries
		_write_json(CREDITS_JSON, credits)

	_print_report(catalog, stubs_added)
	quit(0)


# -- Validation render ---------------------------------------------------------

func _validate_render(res_path: String) -> Dictionary:
	var schema: Dictionary = ParserScript.parse_file(res_path)
	var params: Dictionary = ParserScript.default_params(schema)
	# Coarse where the file exposes a facet count, to keep CGAL fast.
	for k in ["sides", "sides_holes", "fn", "$fn", "resolution"]:
		if params.has(k) and typeof(params[k]) in [TYPE_INT, TYPE_FLOAT] and float(params[k]) > 12.0:
			params[k] = 12
	var out := "user://scratch/ingest_%s.stl" % res_path.get_file().get_basename()
	var t0 := Time.get_ticks_msec()
	var r := RuntimeScript.render_to_stl(res_path, params, out)
	var ms := Time.get_ticks_msec() - t0
	if not r.get("ok", false):
		return {"ok": false, "reason": String(r.get("reason", "render failed")).left(200), "ms": ms}
	var mesh := StlLoaderScript.build_mesh(out)
	var tris := 0
	if mesh != null and mesh.get_surface_count() > 0:
		var arrays := mesh.surface_get_arrays(0)
		tris = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out))
	return {"ok": true, "reason": "", "ms": ms, "triangles": tris}


# -- Reporting -----------------------------------------------------------------

func _print_part_line(e: Dictionary) -> void:
	var render: Dictionary = e.get("render", {})
	var rtxt := "no-render"
	if render.get("ok", null) == true:
		rtxt = "%d tris/%dms" % [render.get("triangles", 0), render.get("ms", 0)]
	elif render.get("ok", null) == false:
		rtxt = "RENDER FAIL"
	var deps: Array = e.get("dependencies", [])
	print("  [%s] %-22s %-12s params=%-3d %s%s license=%s -> %s" % [
		_status_glyph(e["status"]), e["source_file"], e["category"], e["param_count"],
		rtxt, ("  deps=%s" % str(deps)) if not deps.is_empty() else "",
		e["license_status"], e["status"],
	])


func _print_report(catalog: Dictionary, stubs_added: Array) -> void:
	var s: Dictionary = catalog["summary"]
	print("\n== Ingest summary ==")
	print("  total:            %d" % s["total"])
	print("  ready (shippable):%d" % s["ready"])
	print("  review (NC/ND):   %d  (renders, license needs a decision)" % s["review"])
	print("  usable in dev:    %d  (renders, license pending)" % s["usable_dev"])
	print("  quarantined:      %d" % s["quarantined"])
	print("    - parse failed:    %d" % s["parse_failed"])
	print("    - needs dependency:%d" % s["needs_dependency"])
	print("    - render failed:   %d" % s["render_failed"])
	print("  wrote %s" % catalog["library_dir"].path_join("catalog.json"))
	if not stubs_added.is_empty():
		print("  added %d pending-verification credits stub(s): %s" % [stubs_added.size(), str(stubs_added)])
		print("  ACTION: confirm each part's Thingiverse/Printables license and update")
		print("          CREDITS.md + credits/credits.json before shipping. No license = quarantined.")


func _summarize(parts: Array) -> Dictionary:
	var out := {"total": parts.size(), "ready": 0, "review": 0, "usable_dev": 0, "quarantined": 0,
		"parse_failed": 0, "needs_dependency": 0, "render_failed": 0}
	for e in parts:
		match e["status"]:
			"ready": out["ready"] += 1
			"review": out["review"] += 1
			"usable-dev": out["usable_dev"] += 1
			_: out["quarantined"] += 1
		if not e.get("parse_ok", true):
			out["parse_failed"] += 1
		if not (e.get("dependencies", []) as Array).is_empty():
			out["needs_dependency"] += 1
		if e.get("render", {}).get("ok", null) == false:
			out["render_failed"] += 1
	return out


func _status_glyph(status: String) -> String:
	match status:
		"ready": return "OK"
		"usable-dev": return "~~"
		_: return "!!"


# -- IO helpers ----------------------------------------------------------------

## Recursively collect every .scad under dir (the imported library nests parts in
## <category>/<project>/ subfolders so sibling includes resolve).
func _scan_scad(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var abs := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs):
		return out
	var stack: Array = [dir]
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		var cabs := ProjectSettings.globalize_path(cur)
		for f in DirAccess.get_files_at(cabs):
			if f.to_lower().ends_with(".scad"):
				out.append(cur.path_join(f))
		for sub in DirAccess.get_directories_at(cabs):
			stack.append(cur.path_join(sub))
	out.sort()
	return out


func _load_docs(dir: String) -> Dictionary:
	var abs := ProjectSettings.globalize_path(dir.path_join("part_docs.json"))
	if not FileAccess.file_exists(abs):
		return {}
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _load_credits() -> Dictionary:
	var abs := ProjectSettings.globalize_path(CREDITS_JSON)
	if not FileAccess.file_exists(abs):
		return {"entries": []}
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null:
		return {"entries": []}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"entries": []}
	if not parsed.has("entries"):
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


func _has_flag(key: String) -> bool:
	return OS.get_cmdline_user_args().has(key)
