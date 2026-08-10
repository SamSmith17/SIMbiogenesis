extends SceneTree

## Offline deterministic self-test for process recipes, RecipeRunner, chore
## ledger, legacy batch migration, and workflow runner groundwork.
## Run with:
##   Godot.exe.exe --headless --path . --import
##   Godot.exe.exe --headless --path . --script core/machines/process_recipe_selftest.gd

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_normalize()
	_test_catalog()
	_test_legacy_migration()
	_test_runner_progress()
	_test_chore_hybrid()
	_test_part_credits()
	_test_workflow()
	if _failures == 0:
		print("PROCESS RECIPE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("PROCESS RECIPE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _approx(v: float, lo: float, hi: float) -> bool:
	return v >= lo and v <= hi


func _test_normalize() -> void:
	var r := ProcessRecipe.normalize({
		"id": "t1",
		"label": "Test",
		"batch_time_hrs": 2.0,
		"inputs": [{"kind": "water", "rate": 5.0, "mode": "frontloaded"}],
		"outputs": [{"kind": "part", "part_id": "widget", "qty": 2, "mode": "end_batch"}],
		"steps": [
			{"id": "a", "label": "A", "at_frac": 1.0, "chore_hours": 0.1, "require_confirm": true},
			{"id": "b", "label": "B", "at_frac": 0.0, "chore_hours": 0.05},
		],
	})
	_check("normalize id", str(r.get("id", "")) == "t1")
	_check("normalize qty from rate", _approx(float((r["inputs"] as Array)[0].get("qty", 0)), 4.9, 5.1))
	_check("normalize part kind", str((r["outputs"] as Array)[0].get("kind", "")) == "part")
	_check("steps sorted", str((r["steps"] as Array)[0].get("id", "")) == "b")
	_check("chore rollup", _approx(float(r.get("chore_hours", 0)), 0.14, 0.16))
	_check("compatible sheet", ProcessRecipe.compatible_with_role(
		{"compatible_roles": ["pp_sheet_press"]}, "pp_sheet_press"))
	_check("incompatible sheet", not ProcessRecipe.compatible_with_role(
		{"compatible_roles": ["pp_sheet_press"]}, "processor"))


func _test_catalog() -> void:
	var all := ProcessRecipeCatalog.all_recipes()
	_check("builtins present", all.size() >= 3, str(all.size()))
	var sheet := ProcessRecipeCatalog.find("pp_sheet_8mm")
	_check("sheet 8mm", not sheet.is_empty())
	_check("sheet thickness", _approx(float(sheet.get("sheet_thickness_mm", 0)), 7.9, 8.1))
	var for_role := ProcessRecipeCatalog.recipes_for_role("pp_sheet_press")
	_check("recipes for sheet role", for_role.size() >= 2, str(for_role.size()))
	# User round-trip (temp id).
	var saved := ProcessRecipeCatalog.save_user_recipe({
		"id": "selftest_tmp_recipe",
		"label": "Selftest Tmp",
		"compatible_roles": ["processor"],
		"batch_time_hrs": 0.5,
		"inputs": [{"kind": "biomass", "qty": 1.0, "mode": "frontloaded"}],
		"outputs": [{"kind": "biochar", "qty": 1.0, "mode": "end_batch"}],
		"steps": [],
	})
	_check("user save", str(saved.get("id", "")) == "selftest_tmp_recipe")
	_check("user find", not ProcessRecipeCatalog.find("selftest_tmp_recipe").is_empty())
	_check("user delete", ProcessRecipeCatalog.delete_user_recipe("selftest_tmp_recipe"))
	_check("user gone", ProcessRecipeCatalog.find("selftest_tmp_recipe").is_empty())

	# The meal loop's producer half (kitchen preset + meal_prep builtin).
	var meal := ProcessRecipe.normalize(ProcessRecipeCatalog.find("meal_prep"))
	_check("meal_prep exists", not meal.is_empty())
	_check("meal_prep resolves for the kitchen role",
		ProcessRecipeCatalog.recipes_for_role("kitchen").size() >= 1)
	# Total chore_hours rolls up from the steps (0.5 prep + 0.25 serve) — the
	# normalizer's own rule; authoring both would double-count.
	_check("meal_prep chore hours roll up from steps",
		_approx(float(meal.get("chore_hours", 0.0)), 0.74, 0.76),
		str(meal.get("chore_hours")))
	var out_kinds: Array = []
	for o in (meal.get("outputs", []) as Array):
		out_kinds.append(str((o as Dictionary).get("kind", "")))
	_check("meal_prep outputs the full waste stream",
		out_kinds.has("meal") and out_kinds.has("food_waste")
			and out_kinds.has("packaging_waste"), str(out_kinds))
	# Neither crew step demands a player Confirm — with a finite ledger they
	# become real cooking chores through the labour merge instead.
	var any_confirm := false
	for st in (meal.get("steps", []) as Array):
		if bool((st as Dictionary).get("require_confirm", false)):
			any_confirm = true
	_check("meal_prep steps are crew work, not Confirm gates", not any_confirm)


func _test_legacy_migration() -> void:
	var specs := {
		"batch_mode": true,
		"batch_time_hrs": 3.0,
		"batch_failure_mode": "destroy_batch",
		"name": "Old Mixer",
		"inputs": [{"kind": "water", "rate": 10.0, "mode": "frontloaded"}],
		"outputs": [{"kind": "greywater", "rate": 9.0, "mode": "end_batch"}],
	}
	var eph := ProcessRecipe.from_batch_specs(specs)
	_check("ephemeral id", str(eph.get("id", "")) == ProcessRecipe.EPHEMERAL_ID)
	_check("ephemeral time", _approx(float(eph.get("batch_time_hrs", 0)), 2.9, 3.1))
	_check("ephemeral fail", str(eph.get("failure_mode", "")) == "destroy_batch")
	var resolved := ProcessRecipeCatalog.resolve_for_specs(specs)
	_check("resolve legacy", str(resolved.get("id", "")) == ProcessRecipe.EPHEMERAL_ID)


func _test_runner_progress() -> void:
	var recipe := ProcessRecipeCatalog.find("generic_batch_mix")
	var specs := {}
	RecipeRunner.select_recipe(specs, recipe)
	_check("select sets batch", bool(specs.get("batch_mode", false)))
	_check("select id", str(specs.get("selected_recipe_id", "")) == "generic_batch_mix")
	var begin := RecipeRunner.begin_run(specs, 100.0, recipe)
	_check("begin ok", bool(begin.get("ok", false)), str(begin))
	_check("running", bool(specs.get("recipe_running", false)))
	var mid := RecipeRunner.progress_at(specs, 101.0)
	_check("progress mid", _approx(mid, 0.45, 0.55), str(mid))
	var end := RecipeRunner.tick_state(specs, 103.0, 0.1, null)
	_check("completed", bool(end.get("completed", false)), str(end))
	_check("progress 1", _approx(float(end.get("progress", 0)), 0.99, 1.01))
	# Scrub backward after restart.
	RecipeRunner.begin_run(specs, 200.0, recipe)
	RecipeRunner.tick_state(specs, 201.0, 0.1, null)
	var back := RecipeRunner.elapsed_at(specs, 200.2)
	_check("scrub elapsed", _approx(back, 0.15, 0.25), str(back))


func _test_chore_hybrid() -> void:
	var ledger := ChoreLedger.create_default()
	_check("infinite default", ledger.infinite_labor)
	_check("auto debit infinite", ledger.try_debit(2.0))
	_check("consumed tracked", _approx(ledger.chore_hours_consumed_total, 1.9, 2.1))
	ledger.infinite_labor = false
	ledger.chore_hours_available = 0.05
	_check("scarcity blocks", not ledger.can_auto_debit(0.2))
	_check("scarcity try fail", not ledger.try_debit(0.2))
	_check("small debit ok", ledger.try_debit(0.05))

	var recipe := ProcessRecipe.normalize({
		"id": "chore_test",
		"label": "Chore Test",
		"batch_time_hrs": 1.0,
		"compatible_roles": ["processor"],
		"inputs": [],
		"outputs": [],
		"steps": [
			{"id": "gate", "label": "Confirm gate", "at_frac": 0.5,
				"chore_hours": 0.1, "require_confirm": true},
		],
	})
	var ledger_ok := ChoreLedger.create_default()  # infinite labor for confirm path
	var specs2 := {}
	RecipeRunner.begin_run(specs2, 10.0, recipe)
	# Advance past 0.5 → should wait.
	var tick := RecipeRunner.tick_state(specs2, 10.6, 0.1, ledger_ok)
	_check("waiting chore", bool(tick.get("waiting_chore", false)), str(tick))
	_check("elapsed frozen", _approx(float(tick.get("elapsed", 0)), 0.55, 0.65), str(tick.get("elapsed")))
	var conf := RecipeRunner.confirm_chore(specs2, 11.0, ledger_ok)
	_check("confirm ok", bool(conf.get("ok", false)), str(conf))
	_check("resumed", not bool(specs2.get("recipe_waiting_chore", false)))
	# After confirm, paused_total absorbs wait; progress continues from ~0.6.
	var after := RecipeRunner.tick_state(specs2, 11.5, 0.1, ledger_ok)
	_check("progress after confirm", float(after.get("progress", 0)) > 0.5, str(after))

	# Serialize scarcity ledger.
	var data := ledger.serialize()
	var ledger2 := ChoreLedger.create_default()
	ledger2.deserialize(data)
	_check("ledger round-trip infinite", ledger2.infinite_labor == ledger.infinite_labor)
	_test_crew_gated_step()


## THE LABOUR MERGE. With finite labour, a step that needs hands must announce
## itself as CREW work (so the bridge mints a real chore at the machine and
## somebody walks over), and finishing that chore must resume the step through
## the SAME confirm path the player's button uses — debiting the ledger exactly
## once, by exactly the step's hours.
func _test_crew_gated_step() -> void:
	var recipe := {
		"id": "crewtest", "batch_time_hrs": 1.0,
		"steps": [{"id": "tend", "at_frac": 0.5, "chore_hours": 0.5,
			"label": "Tend the mill"}],
	}
	var specs := {}
	var finite := ChoreLedger.create_default()
	finite.infinite_labor = false
	finite.chore_hours_available = 0.0   # no abstract pool at all
	RecipeRunner.begin_run(specs, 10.0, recipe)
	var t := RecipeRunner.tick_state(specs, 10.6, 0.1, finite)
	_check("a labour step waits", bool(t.get("waiting_chore", false)), str(t))
	# The distinction the bridge dispatches on: hands, not a decision.
	_check("it asks for CREW, not a confirm",
		str(specs.get("recipe_waiting_kind", "")) == "crew",
		str(specs.get("recipe_waiting_kind", "")))
	_check("the request names the step and its hours",
		str((t.get("chore_request", {}) as Dictionary).get("step_id", "")) == "tend"
			and _approx(float((t.get("chore_request", {}) as Dictionary).get("chore_hours", 0.0)), 0.45, 0.55))
	var before := finite.chore_hours_consumed_total
	# The crew finished — this is what the recipe_step_done effect calls.
	var conf := RecipeRunner.confirm_chore(specs, 11.0, finite)
	_check("crew work resumes the step", bool(conf.get("ok", false)), str(conf))
	_check("and it is no longer waiting",
		not bool(specs.get("recipe_waiting_chore", false)))
	# The equality that IS the merge's contract: the ledger moved by exactly
	# the step's hours, once. Any second accounting path would break this.
	_check("the ledger moved by exactly the step's hours",
		_approx(finite.chore_hours_consumed_total - before, 0.49, 0.51),
		"%.3f" % (finite.chore_hours_consumed_total - before))
	_check("the crew marker is cleared on resume",
		not specs.has("recipe_waiting_kind") and not specs.has("recipe_chore_id"))

	# A require_confirm step is a DECISION, and must never be minted as crew
	# work however finite the labour.
	var recipe2 := {
		"id": "confirmtest", "batch_time_hrs": 1.0,
		"steps": [{"id": "sign", "at_frac": 0.5, "chore_hours": 0.25,
			"require_confirm": true, "label": "Sign it off"}],
	}
	var specs2 := {}
	RecipeRunner.begin_run(specs2, 20.0, recipe2)
	RecipeRunner.tick_state(specs2, 20.6, 0.1, finite)
	_check("a require_confirm step asks for a decision",
		str(specs2.get("recipe_waiting_kind", "")) == "confirm",
		str(specs2.get("recipe_waiting_kind", "")))

	# With infinite labour nothing waits at all — the old behaviour, intact.
	var specs3 := {}
	var inf := ChoreLedger.create_default()   # infinite by default
	RecipeRunner.begin_run(specs3, 30.0, recipe)
	var t3 := RecipeRunner.tick_state(specs3, 30.6, 0.1, inf)
	_check("infinite labour never waits for hands",
		not bool(t3.get("waiting_chore", false)), str(t3))

	# New maps get the crew-gated default; a SAVED ledger keeps its own value.
	_check("new maps default to finite labour",
		ChoreLedger.DEFAULT_INFINITE_FOR_NEW_MAPS == false)


func _test_part_credits() -> void:
	var recipe := ProcessRecipeCatalog.find("pp_sheet_8mm")
	var credits := RecipeRunner._build_part_credits(recipe)
	_check("part credit count", credits.size() == 1, str(credits))
	_check("part id", str(credits[0].get("part_id", "")) == "pp_sheet_8mm")
	var specs := {}
	RecipeRunner.begin_run(specs, 0.0, recipe)
	# End-step unload requires confirm before completion.
	var t := RecipeRunner.tick_state(specs, 2.0, 0.1, null)
	_check("sheet waits unload chore", bool(t.get("waiting_chore", false)), str(t))
	var conf := RecipeRunner.confirm_chore(specs, 2.0, null)
	_check("sheet unload confirm", bool(conf.get("ok", false)), str(conf))
	var t2 := RecipeRunner.tick_state(specs, 2.1, 0.1, null)
	_check("sheet recipe complete", bool(t2.get("completed", false)), str(t2))
	var pending: Array = t2.get("part_credits", []) as Array
	_check("pending parts", pending.size() >= 1, str(pending))


func _test_workflow() -> void:
	var all := WorkflowRecipeCatalog.all_workflows()
	_check("workflow builtins", all.size() >= 1, str(all.size()))
	var wf := WorkflowRecipeCatalog.find("sheet_to_inventory")
	_check("workflow find", not wf.is_empty())
	var state := WorkflowRunner.create_state("sheet_to_inventory", {
		"pp_sheet_press": "machine_1",
	})
	var begin := WorkflowRunner.begin(state, wf)
	_check("workflow begin", bool(begin.get("ok", false)))
	var started := {"apply": false, "start": false}
	var ctx := {
		"find_machine": func(role: String) -> String: return "machine_1" if role == "pp_sheet_press" else "",
		"apply_recipe": func(_i: String, _r: String) -> bool: started["apply"] = true; return true,
		"start_recipe": func(_i: String) -> bool: started["start"] = true; return true,
		"machine_busy": func(_i: String) -> bool: return true,
		"machine_done": func(_i: String) -> bool: return false,
		"debit_chore": func(_h: float) -> bool: return true,
	}
	var t1 := WorkflowRunner.tick(state, ctx)
	_check("workflow started recipe", bool(started["apply"]) and bool(started["start"]), str(started))
	_check("workflow running", str(t1.get("status", "")) == WorkflowRunner.STATE_RUNNING)
	# Finish machine → advance to chore_transfer.
	ctx["machine_busy"] = func(_i: String) -> bool: return false
	ctx["machine_done"] = func(_i: String) -> bool: return true
	WorkflowRunner.tick(state, ctx)  # completes run_recipe
	var t2 := WorkflowRunner.tick(state, ctx)  # enters chore
	_check("workflow waiting chore", str(t2.get("status", "")) == WorkflowRunner.STATE_WAITING_CHORE,
		str(t2))
	var conf := WorkflowRunner.confirm_chore(state, ctx)
	_check("workflow confirm", bool(conf.get("ok", false)))
	# May complete immediately after confirm if no more steps.
	while str(state.get("status", "")) == WorkflowRunner.STATE_RUNNING:
		WorkflowRunner.tick(state, ctx)
	_check("workflow done", str(state.get("status", "")) == WorkflowRunner.STATE_DONE,
		str(state.get("status", "")))
