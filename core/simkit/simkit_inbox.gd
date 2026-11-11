extends RefCounted

## Designs an AI tool sent to the game (tools/simkit_mcp "submit"): JSON files
## in user://simkit/inbox/. The game never applies one by itself. The Compare
## window lists them; importing one makes an experiment FORK of the world
## (ExperimentStore) that the player can run A vs B, open in the graph editor,
## rename or delete. Whatever is in the file is checked again here
## (SimkitGuard.clean_graph): it may have been written by anything that can
## write to this folder.

const Guard := preload("res://core/simkit/simkit_guard.gd")
const DIR := "user://simkit/inbox"
const MAX_BYTES := 12_000_000
const MAX_ITEMS := 3000


## [{id, name, note, site, summary, created, path}], newest first.
static func entries(dir: String = DIR) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if not f.ends_with(".json"):
			continue
		var path := dir.path_join(f)
		var e := _read(path)
		if e.is_empty():
			continue
		out.append({"id": str(e.get("id", f.get_basename())), "name": str(e.get("name", "AI design")).substr(0, 120),
			"note": str(e.get("note", "")).substr(0, 2000), "site": str(e.get("site", "")),
			"summary": e.get("summary", {}) if e.get("summary") is Dictionary else {},
			"created": float(e.get("created", 0.0)), "path": path})
	out.sort_custom(func(a, b): return float(a["created"]) > float(b["created"]))
	return out


static func count(dir: String = DIR) -> int:
	return entries(dir).size()


## The entry's built graph, made safe (or {} when it is not a graph).
static func graph_of(path: String) -> Dictionary:
	var e := _read(path)
	var g: Variant = e.get("graph", null)
	if not (g is Dictionary) or not ((g as Dictionary).get("items") is Array):
		return {}
	if ((g as Dictionary)["items"] as Array).size() > MAX_ITEMS:
		return {}
	return Guard.clean_graph(g as Dictionary)


## One line for the player: verdict, days, what failed, the first bottleneck.
static func describe(entry: Dictionary) -> String:
	var s: Dictionary = entry.get("summary", {})
	if s.is_empty():
		return "not run yet"
	var days: Variant = s.get("days", "?")
	if days is float and is_equal_approx(float(days), roundf(float(days))):
		days = int(days)
	var parts: Array = ["%s over %s days" % [str(s.get("verdict", "?")).replace("_", " ").to_lower(), str(days)]]
	var fails: Array = s.get("fails", []) if s.get("fails") is Array else []
	if not fails.is_empty():
		parts.append("failed: " + ", ".join(fails.map(func(x): return str(x).replace("_", " "))))
	var bn: Array = s.get("bottlenecks", []) if s.get("bottlenecks") is Array else []
	if not bn.is_empty():
		parts.append(str(bn[0]))
	return "; ".join(parts)


## Move a handled entry out of the inbox (kept under imported/ or discarded/).
static func archive(path: String, sub: String = "imported") -> void:
	var dest := path.get_base_dir().path_join(sub)
	DirAccess.make_dir_recursive_absolute(dest)
	DirAccess.rename_absolute(path, dest.path_join(path.get_file()))


static func _read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() > MAX_BYTES:
		return {}
	var j := JSON.new()
	if j.parse(f.get_as_text()) != OK:
		return {}
	return j.data if j.data is Dictionary else {}
