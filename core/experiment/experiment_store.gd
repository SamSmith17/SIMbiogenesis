class_name ExperimentStore
extends RefCounted

## A world's experiment FORKS: named copies of its graph you can change and
## then simulate side by side with the real one (⧉ Compare → A vs B).
## Saved per world (WorldPaths kind "experiments", so a fork travels with the
## world in a Share pack); never touches the world's own graph file.
##
## A fork is {id, name, note, created_unix, graph} — `graph` is a
## GraphModel.serialize() blob. "current" is not stored: it is the live
## world, copied when a run starts.
## `last` remembers the window's A / B / span / metric between openings.

const KIND := "experiments"
const VERSION := 1
const CURRENT := "current"

var forks: Array = []
var last: Dictionary = {}
var _next := 1


static func path_for_view(view: Node) -> String:
	if view == null or not view.has_method("_resolve_map_graph_key"):
		return ""
	var key := str(view.call("_resolve_map_graph_key"))
	if key.is_empty():
		return ""
	return WorldPaths.keyed_file(KIND, key.trim_prefix("map_"), "json")


static func load_from(path: String) -> ExperimentStore:
	var s := ExperimentStore.new()
	if path.is_empty() or not FileAccess.file_exists(path):
		return s
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		return s
	for f in data.get("forks", []):
		if f is Dictionary and not str(f.get("id", "")).is_empty() and f.get("graph", null) is Dictionary:
			s.forks.append(f)
	s.last = data.get("last", {}) if data.get("last", {}) is Dictionary else {}
	s._next = maxi(int(data.get("next", 1)), s.forks.size() + 1)
	return s


func save_to(path: String) -> bool:
	if path.is_empty():
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": VERSION, "next": _next, "forks": forks, "last": last}))
	return true


## A new fork holding `graph`; returns its id. The name is made unique.
func add_fork(name: String, graph: Dictionary, note: String = "") -> String:
	var id := "fork_%d" % _next
	while not get_fork(id).is_empty():
		_next += 1
		id = "fork_%d" % _next
	_next += 1
	forks.append({"id": id, "name": unique_name(name), "note": note,
		"created_unix": int(Time.get_unix_time_from_system()), "graph": graph.duplicate(true)})
	return id


func get_fork(id: String) -> Dictionary:
	for f in forks:
		if str(f["id"]) == id:
			return f
	return {}


func find_by_name(name: String) -> String:
	for f in forks:
		if str(f["name"]) == name:
			return str(f["id"])
	return ""


func set_fork_graph(id: String, graph: Dictionary) -> bool:
	var f := get_fork(id)
	if f.is_empty():
		return false
	f["graph"] = graph.duplicate(true)
	return true


func rename(id: String, name: String) -> bool:
	var f := get_fork(id)
	if f.is_empty() or name.strip_edges().is_empty():
		return false
	f["name"] = unique_name(name.strip_edges(), id)
	return true


func remove(id: String) -> bool:
	var n := forks.size()
	forks = forks.filter(func(f: Dictionary) -> bool: return str(f["id"]) != id)
	return forks.size() != n


func unique_name(name: String, except_id: String = "") -> String:
	var base := name.strip_edges()
	if base.is_empty():
		base = "Fork"
	var taken := {}
	for f in forks:
		if str(f["id"]) != except_id:
			taken[str(f["name"])] = true
	if not taken.has(base):
		return base
	var k := 2
	while taken.has("%s (%d)" % [base, k]):
		k += 1
	return "%s (%d)" % [base, k]


## A copy of `graph` with one automation switched off (the "without it" side
## of an A/B). Returns {} when the automation is not there.
static func without_automation(graph: Dictionary, item_id: String, auto_id: String) -> Dictionary:
	var g := graph.duplicate(true)
	for it in g.get("items", []):
		if str(it.get("id", "")) != item_id:
			continue
		var sp: Dictionary = it.get("specs", {})
		for a in sp.get("graph_automations", []):
			if str(a.get("id", "")) == auto_id:
				a["enabled"] = false
				return g
	return {}


## The alias of one automation in `graph` ("" when not found).
static func automation_alias(graph: Dictionary, item_id: String, auto_id: String) -> String:
	for it in graph.get("items", []):
		if str(it.get("id", "")) != item_id:
			continue
		for a in (it.get("specs", {}) as Dictionary).get("graph_automations", []):
			if str(a.get("id", "")) == auto_id:
				return str(a.get("alias", "Automation"))
	return ""


## Enabled automations in a graph blob (for the variant pickers' tooltips).
static func automation_count(graph: Dictionary) -> int:
	var n := 0
	for it in graph.get("items", []):
		for a in (it.get("specs", {}) as Dictionary).get("graph_automations", []):
			if bool(a.get("enabled", true)):
				n += 1
	return n
