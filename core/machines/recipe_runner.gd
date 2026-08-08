class_name RecipeRunner
extends RefCounted

## Scrub-safe process-recipe runtime helpers. ResourceFlowEngine owns tank I/O;
## this module owns elapsed/progress derived from absolute hours, chore gating,
## start/cancel/confirm, and part-credit payloads on completion.
##
## Specs keys written at runtime:
##   selected_recipe_id, active_recipe_id, recipe_running,
##   recipe_start_abs_hours, recipe_pause_abs_hours, recipe_paused_total_hrs,
##   recipe_progress, recipe_step_index, recipe_waiting_chore,
##   recipe_waiting_step_id, recipe_waiting_label, recipe_waiting_chore_hrs,
##   recipe_pending_credits (Array of {part_id, qty, label, material_kind}),
##   recipe_chore_done_steps (Array of step ids already handled this run)

const STATE_IDLE := "idle"
const STATE_RUNNING := "running"
const STATE_WAITING_CHORE := "waiting_chore"


static func is_recipe_driven(specs: Dictionary) -> bool:
	if str(specs.get("active_recipe_id", "")) != "":
		return true
	if str(specs.get("selected_recipe_id", "")) != "":
		return true
	return bool(specs.get("batch_mode", false))


static func resolve_recipe(specs: Dictionary) -> Dictionary:
	return ProcessRecipeCatalog.resolve_for_specs(specs)


## Effective elapsed hours accounting for chore pauses (scrub-safe).
static func elapsed_at(specs: Dictionary, abs_hours: float) -> float:
	if not bool(specs.get("recipe_running", false)) \
			and not bool(specs.get("job_active", false)):
		# Fallback for legacy engine-local batch: use stored elapsed if present.
		return maxf(float(specs.get("recipe_elapsed_hrs", 0.0)), 0.0)
	var start := float(specs.get("recipe_start_abs_hours", abs_hours))
	var paused_total := maxf(float(specs.get("recipe_paused_total_hrs", 0.0)), 0.0)
	var elapsed := abs_hours - start - paused_total
	if bool(specs.get("recipe_waiting_chore", false)):
		var pause_at := float(specs.get("recipe_pause_abs_hours", abs_hours))
		elapsed = pause_at - start - paused_total
	return maxf(elapsed, 0.0)


static func progress_at(specs: Dictionary, abs_hours: float, batch_time_hrs: float = -1.0) -> float:
	var bt := batch_time_hrs
	if bt <= 0.0:
		var recipe := resolve_recipe(specs)
		bt = float(recipe.get("batch_time_hrs", specs.get("batch_time_hrs", 1.0)))
	bt = maxf(bt, 0.001)
	return clampf(elapsed_at(specs, abs_hours) / bt, 0.0, 1.0)


static func select_recipe(specs: Dictionary, recipe: Dictionary) -> void:
	ProcessRecipe.apply_to_specs(specs, recipe)


static func begin_run(specs: Dictionary, abs_hours: float, recipe: Dictionary = {}) -> Dictionary:
	## Returns {ok, reason, waiting_chore?, step?}
	var r := recipe if not recipe.is_empty() else resolve_recipe(specs)
	if r.is_empty() and bool(specs.get("batch_mode", false)):
		r = ProcessRecipe.from_batch_specs(specs)
	if r.is_empty():
		return {"ok": false, "reason": "no_recipe"}
	ProcessRecipe.apply_to_specs(specs, r)
	specs["active_recipe_id"] = str(r.get("id", ProcessRecipe.EPHEMERAL_ID))
	specs["recipe_running"] = true
	specs["recipe_start_abs_hours"] = abs_hours
	specs["recipe_pause_abs_hours"] = -1.0
	specs["recipe_paused_total_hrs"] = 0.0
	specs["recipe_elapsed_hrs"] = 0.0
	specs["recipe_progress"] = 0.0
	specs["recipe_step_index"] = 0
	specs["recipe_chore_done_steps"] = []
	specs["recipe_pending_credits"] = []
	specs.erase("recipe_waiting_chore")
	specs.erase("recipe_waiting_step_id")
	specs.erase("recipe_waiting_label")
	specs.erase("recipe_waiting_chore_hrs")
	specs.erase("recipe_waiting_kind")
	specs.erase("recipe_chore_id")
	specs["batch_error"] = ""

	if bool(r.get("require_confirm_start", false)):
		_enter_chore_wait(specs, abs_hours, {
			"id": "_start",
			"label": "Confirm start: %s" % str(r.get("label", "recipe")),
			"chore_hours": 0.0,
			"require_confirm": true,
		})
		return {"ok": true, "waiting_chore": true, "step": specs.get("recipe_waiting_step_id", "")}

	# Fire at_frac==0 steps immediately.
	var gate := _try_enter_steps(specs, r, -1.0, 0.0, abs_hours, null)
	if bool(gate.get("waiting_chore", false)):
		return {"ok": true, "waiting_chore": true, "step": gate.get("step", "")}
	return {"ok": true, "waiting_chore": false}


static func cancel_run(specs: Dictionary) -> void:
	specs["recipe_running"] = false
	specs["active_recipe_id"] = ""
	specs["recipe_progress"] = 0.0
	specs["recipe_elapsed_hrs"] = 0.0
	specs.erase("recipe_waiting_chore")
	specs.erase("recipe_waiting_step_id")
	specs.erase("recipe_waiting_label")
	specs.erase("recipe_waiting_chore_hrs")
	specs.erase("recipe_waiting_kind")
	specs.erase("recipe_chore_id")
	specs.erase("batch_active_watts")
	specs["batch_error"] = ""


## Player confirmed the waiting chore. Debits ledger and resumes.
static func confirm_chore(specs: Dictionary, abs_hours: float, ledger: ChoreLedger) -> Dictionary:
	if not bool(specs.get("recipe_waiting_chore", false)):
		return {"ok": false, "reason": "not_waiting"}
	var hours := maxf(float(specs.get("recipe_waiting_chore_hrs", 0.0)), 0.0)
	if ledger != null and hours > 0.0:
		if str(specs.get("recipe_waiting_kind", "")) == "crew":
			# The hours were WORKED, by a person who walked here — record them,
			# do not ask an abstract pool for permission. Asking would deadlock:
			# finite labour means the pool is empty by design.
			ledger.record_worked(hours)
		elif not ledger.try_debit(hours):
			return {"ok": false, "reason": "no_labor"}
	var step_id := str(specs.get("recipe_waiting_step_id", ""))
	var done: Array = specs.get("recipe_chore_done_steps", []) as Array
	if not step_id.is_empty() and not done.has(step_id):
		done.append(step_id)
	specs["recipe_chore_done_steps"] = done
	_exit_chore_wait(specs, abs_hours)
	return {"ok": true}


## Called each RFE tick while recipe-driven. Returns:
##   {state, elapsed, progress, prev_progress, completed, part_credits[],
##    waiting_chore, chore_request?, failure?}
## Does NOT mutate tank net_rates — RFE still does I/O using recipe I/O modes.
## Advances chore gates; when waiting, freezes elapsed via pause anchor.
static func tick_state(specs: Dictionary, abs_hours: float, dt_hours: float,
		ledger: ChoreLedger) -> Dictionary:
	var recipe := resolve_recipe(specs)
	if recipe.is_empty():
		return {"state": STATE_IDLE, "elapsed": 0.0, "progress": 0.0, "completed": false}

	if not bool(specs.get("recipe_running", false)):
		return {"state": STATE_IDLE, "elapsed": 0.0, "progress": 0.0, "completed": false,
			"recipe": recipe}

	if bool(specs.get("recipe_waiting_chore", false)):
		var elapsed_w := elapsed_at(specs, abs_hours)
		var prog_w := progress_at(specs, abs_hours, float(recipe.get("batch_time_hrs", 1.0)))
		specs["recipe_elapsed_hrs"] = elapsed_w
		specs["recipe_progress"] = prog_w
		return {
			"state": STATE_WAITING_CHORE,
			"elapsed": elapsed_w,
			"progress": prog_w,
			"completed": false,
			"waiting_chore": true,
			"chore_request": {
				"step_id": str(specs.get("recipe_waiting_step_id", "")),
				"label": str(specs.get("recipe_waiting_label", "Needs attention")),
				"chore_hours": float(specs.get("recipe_waiting_chore_hrs", 0.0)),
			},
			"recipe": recipe,
		}

	var batch_time := maxf(float(recipe.get("batch_time_hrs",
		specs.get("batch_time_hrs", 1.0))), 0.001)
	var prev_elapsed := maxf(float(specs.get("recipe_elapsed_hrs", 0.0)), 0.0)
	var elapsed := elapsed_at(specs, abs_hours)
	# Scrub backward: don't re-fire chores; just report progress.
	if elapsed + 1e-6 < prev_elapsed:
		var prog_back := clampf(elapsed / batch_time, 0.0, 1.0)
		specs["recipe_elapsed_hrs"] = elapsed
		specs["recipe_progress"] = prog_back
		return {
			"state": STATE_RUNNING,
			"elapsed": elapsed,
			"progress": prog_back,
			"prev_progress": clampf(prev_elapsed / batch_time, 0.0, 1.0),
			"completed": false,
			"recipe": recipe,
		}

	var prev_prog := clampf(prev_elapsed / batch_time, 0.0, 1.0)
	var prog := clampf(elapsed / batch_time, 0.0, 1.0)

	# Enter new steps between prev and current progress.
	var gate := _try_enter_steps(specs, recipe, prev_prog, prog, abs_hours, ledger)
	if bool(gate.get("waiting_chore", false)):
		var e2 := elapsed_at(specs, abs_hours)
		var p2 := clampf(e2 / batch_time, 0.0, 1.0)
		specs["recipe_elapsed_hrs"] = e2
		specs["recipe_progress"] = p2
		return {
			"state": STATE_WAITING_CHORE,
			"elapsed": e2,
			"progress": p2,
			"prev_progress": prev_prog,
			"completed": false,
			"waiting_chore": true,
			"chore_request": gate.get("chore_request", {}),
			"recipe": recipe,
		}

	specs["recipe_elapsed_hrs"] = elapsed
	specs["recipe_progress"] = prog

	if elapsed + 1e-9 >= batch_time:
		var credits := _build_part_credits(recipe)
		specs["recipe_pending_credits"] = credits
		specs["recipe_running"] = false
		specs["recipe_progress"] = 1.0
		# Keep selected_recipe_id; clear active run id so auto-restart can begin again.
		# active_recipe_id stays as selected for next begin.
		specs["active_recipe_id"] = str(specs.get("selected_recipe_id",
			recipe.get("id", "")))
		return {
			"state": STATE_IDLE,
			"elapsed": batch_time,
			"progress": 1.0,
			"prev_progress": prev_prog,
			"completed": true,
			"part_credits": credits,
			"recipe": recipe,
		}

	return {
		"state": STATE_RUNNING,
		"elapsed": elapsed,
		"progress": prog,
		"prev_progress": prev_prog,
		"completed": false,
		"recipe": recipe,
		"dt_hours": dt_hours,
	}


static func take_pending_credits(specs: Dictionary) -> Array:
	var credits: Array = specs.get("recipe_pending_credits", []) as Array
	specs["recipe_pending_credits"] = []
	return credits.duplicate(true)


static func _build_part_credits(recipe: Dictionary) -> Array:
	var out: Array = []
	for o: Variant in ProcessRecipe.part_outputs(recipe):
		var d: Dictionary = o as Dictionary
		var pid := str(d.get("part_id", ""))
		if pid.is_empty():
			continue
		out.append({
			"part_id": pid,
			"qty": maxi(int(round(float(d.get("qty", 1)))), 1),
			"label": str(d.get("label", pid)),
			"material_kind": str(d.get("material_kind", "")),
		})
	return out


static func _try_enter_steps(specs: Dictionary, recipe: Dictionary, prev_frac: float,
		frac: float, abs_hours: float, ledger: ChoreLedger) -> Dictionary:
	var steps := ProcessRecipe.steps_entered(recipe, prev_frac, frac)
	var done: Array = specs.get("recipe_chore_done_steps", []) as Array
	for step: Variant in steps:
		if not (step is Dictionary):
			continue
		var s: Dictionary = step as Dictionary
		var sid := str(s.get("id", ""))
		if sid.is_empty() or done.has(sid):
			continue
		var hours := maxf(float(s.get("chore_hours", 0.0)), 0.0)
		var need_confirm := bool(s.get("require_confirm", false))
		if hours <= 0.0 and not need_confirm:
			done.append(sid)
			continue
		if need_confirm:
			_enter_chore_wait(specs, abs_hours, s)
			# The designer asked for a human decision here, not for labour —
			# never mint a crew chore for it.
			specs["recipe_waiting_kind"] = "confirm"
			specs["recipe_chore_done_steps"] = done
			return {
				"waiting_chore": true,
				"step": sid,
				"chore_request": {
					"step_id": sid,
					"label": str(s.get("label", "Needs attention")),
					"chore_hours": hours,
					"kind": "confirm",
				},
			}
		# Auto debit — unless labour is finite, in which case this step needs
		# actual HANDS. `recipe_waiting_kind = "crew"` is what tells
		# NpcPopulationBridge to mint a real chore at the machine so somebody
		# walks over and does it; the player Confirm button stays as the
		# override for a machine no crew can reach.
		if ledger != null and not ledger.can_auto_debit(hours):
			_enter_chore_wait(specs, abs_hours, s)
			specs["recipe_waiting_kind"] = "crew"
			specs["recipe_chore_done_steps"] = done
			return {
				"waiting_chore": true,
				"step": sid,
				"chore_request": {
					"step_id": sid,
					"label": str(s.get("label", sid)),
					"chore_hours": hours,
					"kind": "crew",
				},
			}
		if ledger != null:
			ledger.try_debit(hours)
		done.append(sid)
	specs["recipe_chore_done_steps"] = done
	return {"waiting_chore": false}


static func _enter_chore_wait(specs: Dictionary, abs_hours: float, step: Dictionary) -> void:
	specs["recipe_waiting_chore"] = true
	specs["recipe_waiting_step_id"] = str(step.get("id", ""))
	specs["recipe_waiting_label"] = str(step.get("label", "Needs attention"))
	specs["recipe_waiting_chore_hrs"] = maxf(float(step.get("chore_hours", 0.0)), 0.0)
	specs["recipe_pause_abs_hours"] = abs_hours


static func _exit_chore_wait(specs: Dictionary, abs_hours: float) -> void:
	var pause_at := float(specs.get("recipe_pause_abs_hours", abs_hours))
	var paused_total := maxf(float(specs.get("recipe_paused_total_hrs", 0.0)), 0.0)
	paused_total += maxf(abs_hours - pause_at, 0.0)
	specs["recipe_paused_total_hrs"] = paused_total
	specs["recipe_pause_abs_hours"] = -1.0
	specs.erase("recipe_waiting_chore")
	specs.erase("recipe_waiting_step_id")
	specs.erase("recipe_waiting_label")
	specs.erase("recipe_waiting_chore_hrs")
	specs.erase("recipe_waiting_kind")
	specs.erase("recipe_chore_id")
