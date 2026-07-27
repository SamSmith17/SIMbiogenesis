class_name WorkflowRunner
extends RefCounted

## Runs a WorkflowRecipe against bound graph machine item ids.
## State is a plain Dictionary (persistable on a future host); SystemGraphView
## owns the live instance and advances steps each tick / on chore confirm.
##
## Step types:
##   run_recipe      — apply + start process recipe on machine_role binding
##   chore_transfer  — hybrid gate; inventory is the human transport buffer
##   run_machine_job — start a role-specific job (sheet press / CNC later)

const STATE_IDLE := "idle"
const STATE_RUNNING := "running"
const STATE_WAITING_CHORE := "waiting_chore"
const STATE_DONE := "done"
const STATE_FAILED := "failed"


static func create_state(workflow_id: String, bindings: Dictionary = {}) -> Dictionary:
	return {
		"workflow_id": workflow_id,
		"status": STATE_IDLE,
		"step_index": 0,
		"bindings": bindings.duplicate(true),  # role -> item_id
		"waiting": {},
	}


static func begin(state: Dictionary, workflow: Dictionary = {}) -> Dictionary:
	var wf := workflow if not workflow.is_empty() \
			else WorkflowRecipeCatalog.find(str(state.get("workflow_id", "")))
	if wf.is_empty():
		state["status"] = STATE_FAILED
		return {"ok": false, "reason": "no_workflow"}
	state["workflow_id"] = str(wf.get("id", ""))
	state["status"] = STATE_RUNNING
	state["step_index"] = 0
	state["waiting"] = {}
	return {"ok": true, "workflow": wf}


## Advance one step if possible. `ctx` provides callables:
##   find_machine(role) -> item_id
##   apply_recipe(item_id, recipe_id) -> bool
##   start_recipe(item_id) -> bool
##   machine_busy(item_id) -> bool
##   machine_done(item_id) -> bool
##   inventory_has(part_id, qty) -> bool
##   debit_chore(hours) -> bool
## Returns {ok, status, waiting?, message?}
static func tick(state: Dictionary, ctx: Dictionary) -> Dictionary:
	if str(state.get("status", "")) == STATE_DONE:
		return {"ok": true, "status": STATE_DONE}
	if str(state.get("status", "")) == STATE_WAITING_CHORE:
		return {"ok": true, "status": STATE_WAITING_CHORE,
			"waiting": state.get("waiting", {})}
	if str(state.get("status", "")) != STATE_RUNNING:
		return {"ok": false, "status": str(state.get("status", STATE_IDLE))}

	var wf := WorkflowRecipeCatalog.find(str(state.get("workflow_id", "")))
	if wf.is_empty():
		state["status"] = STATE_FAILED
		return {"ok": false, "reason": "no_workflow"}

	var steps: Array = wf.get("steps", []) as Array
	var idx := int(state.get("step_index", 0))
	if idx >= steps.size():
		state["status"] = STATE_DONE
		return {"ok": true, "status": STATE_DONE}

	var step: Dictionary = steps[idx] as Dictionary
	var stype := str(step.get("type", ""))
	match stype:
		"run_recipe":
			return _tick_run_recipe(state, step, ctx)
		"chore_transfer":
			return _tick_chore_transfer(state, step, ctx)
		"run_machine_job":
			return _tick_run_machine_job(state, step, ctx)
		_:
			state["step_index"] = idx + 1
			return {"ok": true, "status": STATE_RUNNING, "message": "skipped unknown step"}


static func confirm_chore(state: Dictionary, ctx: Dictionary) -> Dictionary:
	if str(state.get("status", "")) != STATE_WAITING_CHORE:
		return {"ok": false, "reason": "not_waiting"}
	var waiting: Dictionary = state.get("waiting", {}) as Dictionary
	var hours := maxf(float(waiting.get("chore_hours", 0.0)), 0.0)
	var debit: Callable = ctx.get("debit_chore", Callable()) as Callable
	if debit.is_valid() and hours > 0.0:
		if not bool(debit.call(hours)):
			return {"ok": false, "reason": "no_labor"}
	state["waiting"] = {}
	state["status"] = STATE_RUNNING
	state["step_index"] = int(state.get("step_index", 0)) + 1
	return {"ok": true, "status": STATE_RUNNING}


static func cancel(state: Dictionary) -> void:
	state["status"] = STATE_IDLE
	state["step_index"] = 0
	state["waiting"] = {}


static func _binding_for(state: Dictionary, role: String, ctx: Dictionary) -> String:
	var bindings: Dictionary = state.get("bindings", {}) as Dictionary
	if bindings.has(role) and str(bindings[role]) != "":
		return str(bindings[role])
	var find_m: Callable = ctx.get("find_machine", Callable()) as Callable
	if find_m.is_valid():
		var iid := str(find_m.call(role))
		if not iid.is_empty():
			bindings[role] = iid
			state["bindings"] = bindings
			return iid
	return ""


static func _tick_run_recipe(state: Dictionary, step: Dictionary, ctx: Dictionary) -> Dictionary:
	var role := str(step.get("machine_role", "processor"))
	var recipe_id := str(step.get("recipe_id", ""))
	var iid := _binding_for(state, role, ctx)
	if iid.is_empty():
		state["status"] = STATE_FAILED
		return {"ok": false, "reason": "no_machine", "role": role}

	var busy: Callable = ctx.get("machine_busy", Callable()) as Callable
	var done: Callable = ctx.get("machine_done", Callable()) as Callable
	var flag_key := "_started_%d" % int(state.get("step_index", 0))
	var flags: Dictionary = state.get("flags", {}) as Dictionary

	if not bool(flags.get(flag_key, false)):
		var apply_r: Callable = ctx.get("apply_recipe", Callable()) as Callable
		var start_r: Callable = ctx.get("start_recipe", Callable()) as Callable
		if apply_r.is_valid():
			apply_r.call(iid, recipe_id)
		if start_r.is_valid() and not bool(start_r.call(iid)):
			# May already be running or waiting chore on the machine itself.
			pass
		flags[flag_key] = true
		state["flags"] = flags
		return {"ok": true, "status": STATE_RUNNING, "message": "started"}

	if done.is_valid() and bool(done.call(iid)):
		state["step_index"] = int(state.get("step_index", 0)) + 1
		return {"ok": true, "status": STATE_RUNNING, "message": "step_done"}
	if busy.is_valid() and bool(busy.call(iid)):
		return {"ok": true, "status": STATE_RUNNING, "message": "machine_busy"}
	# Not busy and not done — wait a tick (may be waiting chore on machine).
	return {"ok": true, "status": STATE_RUNNING, "message": "waiting_machine"}


static func _tick_chore_transfer(state: Dictionary, step: Dictionary, ctx: Dictionary) -> Dictionary:
	if bool(step.get("require_confirm", true)):
		state["status"] = STATE_WAITING_CHORE
		state["waiting"] = {
			"step_id": str(step.get("label", "transfer")),
			"label": str(step.get("label", "Move materials")),
			"chore_hours": float(step.get("chore_hours", 0.0)),
			"part_id": str(step.get("part_id", "")),
			"qty": int(step.get("qty", 1)),
			"action": str(step.get("action", "")),
		}
		return {"ok": true, "status": STATE_WAITING_CHORE, "waiting": state["waiting"]}
	# Auto path: debit chore and advance (inventory already global).
	var hours := maxf(float(step.get("chore_hours", 0.0)), 0.0)
	var debit: Callable = ctx.get("debit_chore", Callable()) as Callable
	if debit.is_valid() and hours > 0.0 and not bool(debit.call(hours)):
		state["status"] = STATE_WAITING_CHORE
		state["waiting"] = {
			"label": "Needs labor: %s" % str(step.get("label", "transfer")),
			"chore_hours": hours,
		}
		return {"ok": true, "status": STATE_WAITING_CHORE, "waiting": state["waiting"]}
	state["step_index"] = int(state.get("step_index", 0)) + 1
	return {"ok": true, "status": STATE_RUNNING}


static func _tick_run_machine_job(state: Dictionary, step: Dictionary, ctx: Dictionary) -> Dictionary:
	# Alias of run_recipe without a catalog recipe_id — start whatever is configured.
	var role := str(step.get("machine_role", ""))
	var iid := _binding_for(state, role, ctx)
	if iid.is_empty():
		state["status"] = STATE_FAILED
		return {"ok": false, "reason": "no_machine"}
	var flag_key := "_job_%d" % int(state.get("step_index", 0))
	var flags: Dictionary = state.get("flags", {}) as Dictionary
	if not bool(flags.get(flag_key, false)):
		var start_r: Callable = ctx.get("start_recipe", Callable()) as Callable
		if start_r.is_valid():
			start_r.call(iid)
		flags[flag_key] = true
		state["flags"] = flags
	var done: Callable = ctx.get("machine_done", Callable()) as Callable
	if done.is_valid() and bool(done.call(iid)):
		state["step_index"] = int(state.get("step_index", 0)) + 1
		return {"ok": true, "status": STATE_RUNNING}
	return {"ok": true, "status": STATE_RUNNING, "message": "job_running"}
