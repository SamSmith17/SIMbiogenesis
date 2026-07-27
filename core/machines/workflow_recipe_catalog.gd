class_name WorkflowRecipeCatalog
extends RefCounted

## Multi-machine workflow recipes: ordered steps that run process recipes,
## chore transfers (human as inventory conduit), and machine jobs.
## User workflows persist at user://workflow_recipes.json.

const USER_PATH := "user://workflow_recipes.json"
const VERSION := 1

static var _user_cache: Array = []
static var _user_loaded: bool = false

const BUILTINS: Array = [
	{
		"id": "sheet_to_inventory",
		"label": "Press sheet → inventory",
		"note": "Run an 8 mm sheet recipe, then confirm unload into inventory.",
		"steps": [
			{
				"type": "run_recipe",
				"recipe_id": "pp_sheet_8mm",
				"machine_role": "pp_sheet_press",
				"label": "Press 8 mm sheet",
			},
			{
				"type": "chore_transfer",
				"from": "inventory",
				"part_id": "pp_sheet_8mm",
				"qty": 1,
				"to_machine_role": "",
				"action": "confirm_unload",
				"chore_hours": 0.10,
				"require_confirm": true,
				"label": "Unload sheet to inventory",
			},
		],
		"builtin": true,
	},
]


static func normalize(raw: Dictionary) -> Dictionary:
	var r: Dictionary = raw.duplicate(true)
	r["id"] = str(r.get("id", "")).strip_edges()
	r["label"] = str(r.get("label", r.get("id", "Workflow"))).strip_edges()
	r["note"] = str(r.get("note", ""))
	r["builtin"] = bool(r.get("builtin", false))
	var steps: Array = []
	for s: Variant in r.get("steps", []) as Array:
		if not (s is Dictionary):
			continue
		var d: Dictionary = (s as Dictionary).duplicate(true)
		d["type"] = str(d.get("type", "run_recipe"))
		d["label"] = str(d.get("label", d.get("type", "step")))
		d["chore_hours"] = maxf(float(d.get("chore_hours", 0.0)), 0.0)
		d["require_confirm"] = bool(d.get("require_confirm", false))
		steps.append(d)
	r["steps"] = steps
	return r


static func all_workflows() -> Array:
	_ensure_user_loaded()
	var out: Array = []
	for w: Variant in BUILTINS:
		out.append(normalize(w as Dictionary))
	for w2: Variant in _user_cache:
		out.append(normalize(w2 as Dictionary))
	return out


static func find(workflow_id: String) -> Dictionary:
	if workflow_id.is_empty():
		return {}
	for w: Variant in all_workflows():
		if str((w as Dictionary).get("id", "")) == workflow_id:
			return (w as Dictionary).duplicate(true)
	return {}


static func save_user_workflow(workflow: Dictionary) -> Dictionary:
	_ensure_user_loaded()
	var w := normalize(workflow)
	w["builtin"] = false
	if str(w.get("id", "")).is_empty():
		w["id"] = "workflow_%d" % (Time.get_unix_time_from_system() as int)
	var replaced := false
	for i in _user_cache.size():
		if str((_user_cache[i] as Dictionary).get("id", "")) == str(w.get("id", "")):
			_user_cache[i] = w
			replaced = true
			break
	if not replaced:
		_user_cache.append(w)
	_persist()
	return w.duplicate(true)


static func delete_user_workflow(workflow_id: String) -> bool:
	_ensure_user_loaded()
	for i in _user_cache.size():
		if str((_user_cache[i] as Dictionary).get("id", "")) == workflow_id:
			_user_cache.remove_at(i)
			_persist()
			return true
	return false


static func _ensure_user_loaded() -> void:
	if _user_loaded:
		return
	_user_loaded = true
	_user_cache.clear()
	if not FileAccess.file_exists(USER_PATH):
		return
	var f := FileAccess.open(USER_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	var arr: Variant = (parsed as Dictionary).get("workflows", [])
	if arr is Array:
		for e: Variant in arr as Array:
			if e is Dictionary:
				_user_cache.append(normalize(e as Dictionary))


static func _persist() -> void:
	var f := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"version": VERSION, "workflows": _user_cache}))
