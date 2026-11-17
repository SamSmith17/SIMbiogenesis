class_name ProcessLibrary
extends RefCounted

## The player's saved processes (ProcessPack), one JSON file. Every function
## takes the path, so a selftest uses a temp file.

const PATH := "user://process_library.json"
const MAX := 80


static func load_all(path: String = PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parser := JSON.new()
	if parser.parse(f.get_as_text()) != OK or not (parser.data is Dictionary):
		return []
	var out: Array = []
	for p in (parser.data as Dictionary).get("processes", []):
		var c := ProcessPack.clean(p)
		if bool(c["ok"]) and out.size() < MAX:
			out.append(c["pack"])
	return out


static func save_all(packs: Array, path: String = PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"v": 1, "processes": packs}, "\t"))
	return true


## Add one; a name already there gets " (2)", " (3)" … → the name it took.
static func add(pack: Dictionary, path: String = PATH) -> String:
	var packs := load_all(path)
	var names := {}
	for p in packs:
		names[str(p["name"])] = true
	var base := str(pack.get("name", "Process"))
	var nm := base
	var n := 2
	while names.has(nm):
		nm = "%s (%d)" % [base, n]
		n += 1
	var p2 := pack.duplicate(true)
	p2["name"] = nm
	packs.append(p2)
	if packs.size() > MAX:
		packs = packs.slice(packs.size() - MAX)
	return nm if save_all(packs, path) else ""


static func remove(pack_name: String, path: String = PATH) -> bool:
	var packs := load_all(path)
	var keep: Array = []
	for p in packs:
		if str(p["name"]) != pack_name:
			keep.append(p)
	if keep.size() == packs.size():
		return false
	return save_all(keep, path)


static func find(pack_name: String, path: String = PATH) -> Dictionary:
	for p in load_all(path):
		if str(p["name"]) == pack_name:
			return p
	return {}
