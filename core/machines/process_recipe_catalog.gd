class_name ProcessRecipeCatalog
extends RefCounted

## Builtin + user process recipes (multi-step batch definitions for processors).
## User recipes persist at user://process_recipes.json (never committed).

const USER_PATH := "user://process_recipes.json"
const VERSION := 1

static var _user_cache: Array = []
static var _user_loaded: bool = false
## id → normalized recipe (builtin + user). Rebuilt on load/save/reload.
static var _by_id: Dictionary = {}
static var _all_cache: Array = []
static var _index_valid: bool = false


## Seed recipes — sheet press bridges + a generic compost/digester-style cycle.
const BUILTINS: Array = [
	{
		"id": "pp_sheet_8mm",
		"label": "8 mm Recycled Sheet",
		"compatible_roles": ["pp_sheet_press"],
		"batch_time_hrs": 1.0,
		"failure_mode": "pause_and_resume",
		"chore_hours": 0.15,
		"require_confirm_start": false,
		"sheet_thickness_mm": 8.0,
		"job_part_id": "pp_sheet_8mm",
		"job_part_label": "Recycled Plastic Sheet (1 m² × 8 mm)",
		"inputs": [
			{"kind": "plastic_flake", "qty": 7.2, "mode": "frontloaded"},
			{"kind": "electric", "qty": 4000.0, "mode": "continuous"},
		],
		"outputs": [
			{"kind": "part", "part_id": "pp_sheet_8mm", "qty": 1, "mode": "end_batch",
				"label": "Recycled Plastic Sheet (1 m² × 8 mm)"},
		],
		"steps": [
			{"id": "load", "label": "Load flakes into mold", "at_frac": 0.0,
				"chore_hours": 0.05, "require_confirm": false},
			{"id": "melt", "label": "Melt + press", "at_frac": 0.0,
				"chore_hours": 0.0, "require_confirm": false},
			{"id": "unload", "label": "Unload sheet", "at_frac": 1.0,
				"chore_hours": 0.10, "require_confirm": true},
		],
		"note": "Precious Plastic sheet press — 1 m² × 8 mm.",
		"builtin": true,
	},
	{
		"id": "pp_sheet_15mm",
		"label": "15 mm Recycled Sheet",
		"compatible_roles": ["pp_sheet_press"],
		"batch_time_hrs": 1.75,
		"failure_mode": "pause_and_resume",
		"chore_hours": 0.20,
		"require_confirm_start": false,
		"sheet_thickness_mm": 15.0,
		"job_part_id": "pp_sheet_15mm",
		"job_part_label": "Recycled Plastic Sheet (1 m² × 15 mm)",
		"inputs": [
			{"kind": "plastic_flake", "qty": 13.5, "mode": "frontloaded"},
			{"kind": "electric", "qty": 4500.0, "mode": "continuous"},
		],
		"outputs": [
			{"kind": "part", "part_id": "pp_sheet_15mm", "qty": 1, "mode": "end_batch",
				"label": "Recycled Plastic Sheet (1 m² × 15 mm)"},
		],
		"steps": [
			{"id": "load", "label": "Load flakes into mold", "at_frac": 0.0,
				"chore_hours": 0.05, "require_confirm": false},
			{"id": "melt", "label": "Melt + press", "at_frac": 0.0,
				"chore_hours": 0.0, "require_confirm": false},
			{"id": "unload", "label": "Unload sheet", "at_frac": 1.0,
				"chore_hours": 0.15, "require_confirm": true},
		],
		"note": "Precious Plastic sheet press — thicker panel.",
		"builtin": true,
	},
	{
		"id": "generic_batch_mix",
		"label": "Generic Batch Mix",
		"compatible_roles": ["processor"],
		"batch_time_hrs": 2.0,
		"failure_mode": "pause_and_resume",
		"chore_hours": 0.25,
		"require_confirm_start": false,
		"inputs": [
			{"kind": "biomass", "qty": 10.0, "mode": "frontloaded"},
			{"kind": "water", "qty": 5.0, "mode": "frontloaded"},
			{"kind": "electric", "qty": 500.0, "mode": "continuous"},
		],
		"outputs": [
			{"kind": "biochar", "qty": 12.0, "mode": "end_batch"},
		],
		"steps": [
			{"id": "load", "label": "Load feedstock", "at_frac": 0.0,
				"chore_hours": 0.15, "require_confirm": false},
			{"id": "process", "label": "Process batch", "at_frac": 0.0,
				"chore_hours": 0.0, "require_confirm": false},
			{"id": "unload", "label": "Unload product", "at_frac": 1.0,
				"chore_hours": 0.10, "require_confirm": false},
		],
		"note": "Starter process recipe for generic processors.",
		"builtin": true,
	},
]


static func _rebuild_index() -> void:
	_ensure_user_loaded()
	_by_id.clear()
	_all_cache.clear()
	for r: Variant in BUILTINS:
		var n := ProcessRecipe.normalize(r as Dictionary)
		_all_cache.append(n)
		var rid := str(n.get("id", ""))
		if not rid.is_empty():
			_by_id[rid] = n
	for r2: Variant in _user_cache:
		var n2 := ProcessRecipe.normalize(r2 as Dictionary)
		_all_cache.append(n2)
		var rid2 := str(n2.get("id", ""))
		if not rid2.is_empty():
			_by_id[rid2] = n2
	_index_valid = true


static func _ensure_index() -> void:
	if not _index_valid:
		_rebuild_index()


static func all_recipes() -> Array:
	_ensure_index()
	var out: Array = []
	for r: Variant in _all_cache:
		out.append((r as Dictionary).duplicate(true))
	return out


static func find(recipe_id: String) -> Dictionary:
	if recipe_id.is_empty() or recipe_id == ProcessRecipe.EPHEMERAL_ID:
		return {}
	_ensure_index()
	var hit: Variant = _by_id.get(recipe_id, null)
	if hit is Dictionary:
		return (hit as Dictionary).duplicate(true)
	return {}


static func recipes_for_role(role: String) -> Array:
	_ensure_index()
	var out: Array = []
	for r: Variant in _all_cache:
		var d: Dictionary = r as Dictionary
		if ProcessRecipe.compatible_with_role(d, role):
			out.append(d.duplicate(true))
	return out


## Resolve the active recipe for a processor item: snapshot, named catalog
## entry, or ephemeral recipe synthesized from legacy batch_mode specs.
static func resolve_for_specs(specs: Dictionary) -> Dictionary:
	var snap: Variant = specs.get("recipe_def", null)
	if snap is Dictionary and not (snap as Dictionary).is_empty():
		var snapped := ProcessRecipe.normalize(snap as Dictionary)
		if ProcessRecipe.is_valid(snapped):
			return snapped
	var rid := str(specs.get("active_recipe_id", specs.get("selected_recipe_id", "")))
	if not rid.is_empty() and rid != ProcessRecipe.EPHEMERAL_ID:
		var found := find(rid)
		if not found.is_empty():
			return found
	if bool(specs.get("batch_mode", false)) or not rid.is_empty():
		return ProcessRecipe.from_batch_specs(specs)
	return {}


static func save_user_recipe(recipe: Dictionary) -> Dictionary:
	_ensure_user_loaded()
	var r := ProcessRecipe.normalize(recipe)
	r["builtin"] = false
	if str(r.get("id", "")).is_empty():
		r["id"] = _mint_id(str(r.get("label", "recipe")))
	# Don't overwrite builtins — clone with a new id if colliding.
	for b: Variant in BUILTINS:
		if str((b as Dictionary).get("id", "")) == str(r.get("id", "")):
			r["id"] = _mint_id(str(r.get("label", r.get("id", "recipe"))))
			break
	var replaced := false
	for i in _user_cache.size():
		if str((_user_cache[i] as Dictionary).get("id", "")) == str(r.get("id", "")):
			_user_cache[i] = r
			replaced = true
			break
	if not replaced:
		_user_cache.append(r)
	_persist_user()
	_index_valid = false
	return r.duplicate(true)


static func delete_user_recipe(recipe_id: String) -> bool:
	_ensure_user_loaded()
	for i in _user_cache.size():
		if str((_user_cache[i] as Dictionary).get("id", "")) == recipe_id:
			_user_cache.remove_at(i)
			_persist_user()
			_index_valid = false
			return true
	return false


static func reload() -> void:
	_user_loaded = false
	_user_cache.clear()
	_index_valid = false
	_ensure_user_loaded()


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
	var arr: Variant = (parsed as Dictionary).get("recipes", [])
	if not (arr is Array):
		return
	for entry: Variant in arr as Array:
		if entry is Dictionary:
			_user_cache.append(ProcessRecipe.normalize(entry as Dictionary))


static func _persist_user() -> void:
	var payload := {
		"version": VERSION,
		"recipes": _user_cache.duplicate(true),
	}
	var f := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))


static func _mint_id(label: String) -> String:
	var base := label.to_lower().strip_edges()
	var out := ""
	for i in base.length():
		var ch := base[i]
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif ch == " " or ch == "-" or ch == "_":
			out += "_"
	if out.is_empty():
		out = "recipe"
	var candidate := out
	var n := 2
	while not find(candidate).is_empty() or _user_has(candidate):
		candidate = "%s_%d" % [out, n]
		n += 1
	return candidate


static func _user_has(recipe_id: String) -> bool:
	for r: Variant in _user_cache:
		if str((r as Dictionary).get("id", "")) == recipe_id:
			return true
	return false
