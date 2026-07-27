class_name ProcessRecipe
extends RefCounted

## Process-recipe dict helpers: normalize, validate, migrate legacy batch_mode
## specs into an ephemeral recipe, and query step/chore anchors.
##
## Shape (see ProcessRecipeCatalog for builtins):
##   id, label, compatible_roles[], batch_time_hrs, failure_mode,
##   chore_hours, require_confirm_start,
##   inputs[{kind, qty|rate, mode, delay_hrs?, duration_hrs?, kwh?}],
##   outputs[{kind, qty|rate, mode, part_id?, label?, ...}],
##   steps[{id, label, at_frac, chore_hours, require_confirm}]

const FAILURE_MODES := ["pause_and_resume", "restart_with_penalty", "destroy_batch"]
const INPUT_MODES := ["continuous", "frontloaded"]
const OUTPUT_MODES := ["continuous", "delayed", "end_batch"]
const EPHEMERAL_ID := "_ephemeral_batch"


static func normalize(raw: Dictionary) -> Dictionary:
	var r: Dictionary = raw.duplicate(true)
	r["id"] = str(r.get("id", "")).strip_edges()
	r["label"] = str(r.get("label", r.get("id", "Recipe"))).strip_edges()
	if r["label"].is_empty():
		r["label"] = "Recipe"
	var roles: Array = []
	var raw_roles: Variant = r.get("compatible_roles", [])
	if raw_roles is Array:
		for role: Variant in raw_roles as Array:
			var s := str(role).strip_edges()
			if not s.is_empty() and not roles.has(s):
				roles.append(s)
	r["compatible_roles"] = roles
	r["batch_time_hrs"] = maxf(float(r.get("batch_time_hrs", 1.0)), 0.001)
	var fail := str(r.get("failure_mode", "pause_and_resume"))
	if not FAILURE_MODES.has(fail):
		fail = "pause_and_resume"
	r["failure_mode"] = fail
	r["chore_hours"] = maxf(float(r.get("chore_hours", 0.0)), 0.0)
	r["require_confirm_start"] = bool(r.get("require_confirm_start", false))
	r["inputs"] = _normalize_io_list(r.get("inputs", []), true)
	r["outputs"] = _normalize_io_list(r.get("outputs", []), false)
	r["steps"] = _normalize_steps(r.get("steps", []))
	# Roll-up step chores into total when author left total at 0.
	if float(r["chore_hours"]) <= 0.0:
		var sum := 0.0
		for step: Variant in r["steps"] as Array:
			sum += float((step as Dictionary).get("chore_hours", 0.0))
		r["chore_hours"] = sum
	r["builtin"] = bool(r.get("builtin", false))
	r["note"] = str(r.get("note", ""))
	# Optional bridge fields for role-specific machines (sheet press, CNC).
	if r.has("sheet_thickness_mm"):
		r["sheet_thickness_mm"] = float(r.get("sheet_thickness_mm", 8.0))
	if r.has("job_part_id"):
		r["job_part_id"] = str(r.get("job_part_id", ""))
	if r.has("job_part_label"):
		r["job_part_label"] = str(r.get("job_part_label", ""))
	return r


static func _normalize_io_list(raw: Variant, is_input: bool) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	var modes := INPUT_MODES if is_input else OUTPUT_MODES
	for entry: Variant in raw as Array:
		if not (entry is Dictionary):
			continue
		var io: Dictionary = (entry as Dictionary).duplicate(true)
		var kind := str(io.get("kind", "")).strip_edges()
		if kind.is_empty():
			continue
		io["kind"] = kind
		var mode := str(io.get("mode", "continuous"))
		if not modes.has(mode):
			mode = "continuous"
		io["mode"] = mode
		# qty preferred; fall back to rate (legacy batch editor).
		var qty := float(io.get("qty", io.get("rate", 0.0)))
		if kind == "electric" and io.has("kwh") and not io.has("qty"):
			# kWh over the batch → treat as total qty; watts derived at runtime.
			qty = float(io.get("kwh", 0.0))
		io["qty"] = maxf(qty, 0.0)
		io["rate"] = float(io.get("rate", io["qty"]))
		io["delay_hrs"] = maxf(float(io.get("delay_hrs", 0.0)), 0.0)
		io["duration_hrs"] = maxf(float(io.get("duration_hrs", 1.0)), 0.001)
		if kind == "part" or io.has("part_id"):
			io["part_id"] = str(io.get("part_id", "")).strip_edges()
			io["label"] = str(io.get("label", io.get("part_id", "Part")))
			io["kind"] = "part"
		out.append(io)
	return out


static func _normalize_steps(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	var i := 0
	for entry: Variant in raw as Array:
		if not (entry is Dictionary):
			continue
		var s: Dictionary = (entry as Dictionary).duplicate(true)
		var sid := str(s.get("id", "")).strip_edges()
		if sid.is_empty():
			sid = "step_%d" % i
		s["id"] = sid
		s["label"] = str(s.get("label", sid))
		s["at_frac"] = clampf(float(s.get("at_frac", 0.0)), 0.0, 1.0)
		s["chore_hours"] = maxf(float(s.get("chore_hours", 0.0)), 0.0)
		s["require_confirm"] = bool(s.get("require_confirm", false))
		out.append(s)
		i += 1
	out.sort_custom(func(a, b): return float(a.get("at_frac", 0.0)) < float(b.get("at_frac", 0.0)))
	return out


static func is_valid(recipe: Dictionary) -> bool:
	if recipe.is_empty():
		return false
	if str(recipe.get("id", "")).is_empty():
		return false
	if float(recipe.get("batch_time_hrs", 0.0)) <= 0.0:
		return false
	return true


static func compatible_with_role(recipe: Dictionary, role: String) -> bool:
	var roles: Array = recipe.get("compatible_roles", []) as Array
	if roles.is_empty():
		# Empty = generic processor recipes (any non-specialized processor).
		return role.is_empty() or role == "processor" \
			or not _is_specialized_role(role)
	if roles.has(role):
		return true
	if role.is_empty() and roles.has("processor"):
		return true
	return false


static func _is_specialized_role(role: String) -> bool:
	return role in [
		"cartesian_machine", "pp_sheet_press", "pp_beam_extruder",
		"pp_shredder", "csp_concentrator", "habitat",
	]


## Build an ephemeral recipe from legacy batch_mode processor specs so old
## graphs keep running until the player saves a named recipe.
static func from_batch_specs(specs: Dictionary, item_name: String = "") -> Dictionary:
	var inputs: Array = []
	for inp: Variant in specs.get("inputs", []) as Array:
		if not (inp is Dictionary):
			continue
		var d: Dictionary = (inp as Dictionary).duplicate(true)
		d["qty"] = float(d.get("qty", d.get("rate", 0.0)))
		inputs.append(d)
	var outputs: Array = []
	for outp: Variant in specs.get("outputs", []) as Array:
		if not (outp is Dictionary):
			continue
		var d2: Dictionary = (outp as Dictionary).duplicate(true)
		d2["qty"] = float(d2.get("qty", d2.get("rate", 0.0)))
		outputs.append(d2)
	var label := str(specs.get("name", item_name))
	if label.is_empty():
		label = "Batch Cycle"
	return normalize({
		"id": EPHEMERAL_ID,
		"label": "%s (legacy batch)" % label,
		"compatible_roles": [],
		"batch_time_hrs": float(specs.get("batch_time_hrs", 1.0)),
		"failure_mode": str(specs.get("batch_failure_mode", "pause_and_resume")),
		"chore_hours": 0.0,
		"require_confirm_start": false,
		"inputs": inputs,
		"outputs": outputs,
		"steps": [],
		"builtin": false,
		"note": "Migrated from Batch Cycle Mode",
	})


## Stamp recipe I/O + timing onto processor specs (keeps RFE tank wiring).
static func apply_to_specs(specs: Dictionary, recipe: Dictionary) -> void:
	var r := normalize(recipe)
	specs["selected_recipe_id"] = str(r.get("id", ""))
	# Snapshot so resolve works for ephemeral / not-yet-catalogued recipes and
	# preserves steps/part outputs that aren't tank ports.
	specs["recipe_def"] = r.duplicate(true)
	specs["batch_mode"] = true
	specs["batch_time_hrs"] = float(r.get("batch_time_hrs", 1.0))
	specs["batch_failure_mode"] = str(r.get("failure_mode", "pause_and_resume"))
	# Map recipe I/O → specs I/O (rate = qty for batch accounting).
	var mapped_in: Array = []
	for inp: Variant in r.get("inputs", []) as Array:
		var d: Dictionary = (inp as Dictionary).duplicate(true)
		if str(d.get("kind", "")) == "part":
			continue  # parts are not tank ports
		d["rate"] = float(d.get("qty", d.get("rate", 0.0)))
		mapped_in.append(d)
	var mapped_out: Array = []
	for outp: Variant in r.get("outputs", []) as Array:
		var d2: Dictionary = (outp as Dictionary).duplicate(true)
		if str(d2.get("kind", "")) == "part":
			# Keep a zero-rate marker port optional; credit happens via runner.
			continue
		d2["rate"] = float(d2.get("qty", d2.get("rate", 0.0)))
		mapped_out.append(d2)
	# Preserve electric draw from recipe continuous electric qty-as-watts if present.
	if not mapped_in.is_empty() or bool(specs.get("batch_mode", false)):
		specs["inputs"] = mapped_in if not mapped_in.is_empty() else specs.get("inputs", [])
		specs["outputs"] = mapped_out if not mapped_out.is_empty() else specs.get("outputs", [])
	if r.has("sheet_thickness_mm"):
		specs["sheet_thickness_mm"] = float(r["sheet_thickness_mm"])
	if str(r.get("job_part_id", "")) != "":
		specs["job_part_id"] = str(r["job_part_id"])
	if str(r.get("job_part_label", "")) != "":
		specs["job_part_label"] = str(r["job_part_label"])


## Steps whose at_frac was crossed moving from prev_frac → frac.
## Use prev_frac < 0 to mean "batch just started" (includes at_frac==0).
static func steps_entered(recipe: Dictionary, prev_frac: float, frac: float) -> Array:
	var hit: Array = []
	for step: Variant in recipe.get("steps", []) as Array:
		if not (step is Dictionary):
			continue
		var at := float((step as Dictionary).get("at_frac", 0.0))
		if prev_frac < 0.0:
			if at <= frac + 0.0001:
				hit.append(step)
		elif at > prev_frac and at <= frac + 0.0001:
			hit.append(step)
	return hit


## Steps at at_frac==0 (load / prep at batch start).
static func start_steps(recipe: Dictionary) -> Array:
	var hit: Array = []
	for step: Variant in recipe.get("steps", []) as Array:
		if not (step is Dictionary):
			continue
		if is_equal_approx(float((step as Dictionary).get("at_frac", -1.0)), 0.0):
			hit.append(step)
	return hit


## Steps at at_frac==1 (unload / finish).
static func end_steps(recipe: Dictionary) -> Array:
	var hit: Array = []
	for step: Variant in recipe.get("steps", []) as Array:
		if not (step is Dictionary):
			continue
		if is_equal_approx(float((step as Dictionary).get("at_frac", -1.0)), 1.0):
			hit.append(step)
	return hit


static func part_outputs(recipe: Dictionary) -> Array:
	var out: Array = []
	for o: Variant in recipe.get("outputs", []) as Array:
		if not (o is Dictionary):
			continue
		if str((o as Dictionary).get("kind", "")) == "part":
			out.append(o)
	return out


static func io_batch_qty(io: Dictionary, occupants: float = 1.0) -> float:
	return maxf(float(io.get("qty", io.get("rate", 0.0))), 0.0) * maxf(occupants, 1.0)


static func serialize(recipe: Dictionary) -> Dictionary:
	return normalize(recipe)


static func deserialize(data: Dictionary) -> Dictionary:
	return normalize(data)
