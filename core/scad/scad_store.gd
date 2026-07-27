class_name ScadStore
extends RefCounted

## In-game read model for the parametric hardware store: loads scad_library/
## catalog.json (produced by scad_ingest.gd) and answers the queries the store UI
## needs — categories, parts per category, search, and per-part schema/license/
## description. Pure data + query; no rendering. See PARAMETRIC_STORE_PLAN.md
## Phase 3.

const CATALOG_PATH := "res://scad_library/catalog.json"

var _parts: Array = []
var _by_id: Dictionary = {}
var _loaded := false
var _error := ""


func load_catalog(path: String = CATALOG_PATH) -> bool:
	_parts.clear()
	_by_id.clear()
	_loaded = false
	_error = ""
	var abs := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs):
		_error = "catalog not found: %s (run scad_ingest.gd)" % path
		return false
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null:
		_error = "cannot open catalog"
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		_error = "catalog is not valid JSON"
		return false
	_parts = parsed.get("parts", [])
	for p in _parts:
		if p is Dictionary and p.has("id"):
			_by_id[String(p["id"])] = p
	_loaded = true
	return true


func is_loaded() -> bool:
	return _loaded


func error() -> String:
	return _error


func part_count() -> int:
	return _parts.size()


## All category display names present, sorted, each with its part count.
func categories() -> Array:
	var counts: Dictionary = {}
	for p in _parts:
		var c := String(p.get("category", "Uncategorized"))
		counts[c] = int(counts.get(c, 0)) + 1
	var names := counts.keys()
	names.sort()
	var out: Array = []
	for n in names:
		out.append({"name": n, "count": counts[n]})
	return out


func parts_in_category(category: String) -> Array:
	var out: Array = []
	for p in _parts:
		if String(p.get("category", "")) == category:
			out.append(p)
	out.sort_custom(_by_title)
	return out


func all_parts() -> Array:
	var out := _parts.duplicate()
	out.sort_custom(_by_title)
	return out


func get_part(id: String) -> Dictionary:
	return _by_id.get(id, {})


## Case-insensitive match over title, category, source file, and description.
func search(query: String) -> Array:
	var q := query.strip_edges().to_lower()
	if q.is_empty():
		return all_parts()
	var out: Array = []
	for p in _parts:
		var hay := "%s %s %s %s" % [
			p.get("title", ""), p.get("category", ""),
			p.get("source_file", ""), p.get("description", "")]
		if hay.to_lower().contains(q):
			out.append(p)
	out.sort_custom(_by_title)
	return out


## Parts filtered by ship status ("ready"/"review"/"usable-dev"/"quarantined").
func parts_with_status(status: String) -> Array:
	var out: Array = []
	for p in _parts:
		if String(p.get("status", "")) == status:
			out.append(p)
	return out


## Only parts a player can meaningfully customize (have parameters and aren't
## render-broken) — the store's default listing.
func customizable_parts() -> Array:
	var out: Array = []
	for p in _parts:
		if int(p.get("param_count", 0)) > 0 and String(p.get("status", "")) != "quarantined":
			out.append(p)
	out.sort_custom(_by_title)
	return out


func _by_title(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("title", "")).naturalnocasecmp_to(String(b.get("title", ""))) < 0
