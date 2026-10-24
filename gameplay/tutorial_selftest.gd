extends SceneTree

## Offline self-test for the Solar Bootcamp tutorial framework.
## Part 1: ProgressStore — grandfathering, unlock grants, level completion,
## disk round-trip. Part 2: level catalog integrity (every seed/unlock/palette
## entry resolves to a real preset), def round-trip, and TutorialGoals
## predicates over synthetic graphs reproducing each level's win state.

const SCRATCH_PATH := "user://selftest_progress.json"
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_grandfathering()
	fails += _test_prompt_and_gating()
	fails += _test_grants()
	fails += _test_levels()
	fails += _test_sandbox_snapshot()
	fails += _test_disk_round_trip()
	fails += _test_unlock_all()
	fails += _test_catalog_integrity()
	fails += _test_level_def_round_trip()
	fails += _test_goal_fault_observed()
	fails += _test_goal_build_pwm()
	fails += _test_goal_build_bus_and_watts()
	fails += _test_goal_array_config()
	fails += _test_goal_ac_load_wired()
	fails += _test_goal_compound_containing()
	fails += _test_run_verdict()
	fails += _test_unlock_labels()
	_cleanup()
	if fails == 0:
		print("TUTORIAL SELFTEST PASS  (17 checks)")
		quit(0)
	else:
		print("TUTORIAL SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _fresh() -> void:
	ProgressStore.path_override = SCRATCH_PATH
	ProgressStore.reset_cache()
	if FileAccess.file_exists(SCRATCH_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_PATH))


func _cleanup() -> void:
	if FileAccess.file_exists(SCRATCH_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_PATH))
	ProgressStore.path_override = ""
	ProgressStore.reset_cache()


## No progress file → existing installs keep their full library.
func _test_grandfathering() -> int:
	_fresh()
	if not ProgressStore.is_new_player():
		push_error("no file should read as new player")
		return 1
	if not ProgressStore.is_unlocked("category", "processors") \
			or not ProgressStore.is_unlocked("preset", "EG4 6000XP"):
		push_error("no file must leave everything unlocked (grandfathering)")
		return 1
	return 0


## Gating is DISABLED: the public predicate must always answer true (full
## Library for everyone), while the preserved _would_be_unlocked rule keeps the
## original semantics alive for a possible re-enable.
func _test_prompt_and_gating() -> int:
	_fresh()
	ProgressStore.mark_prompt_seen()
	if ProgressStore.is_new_player():
		push_error("prompt seen should clear new-player state")
		return 1
	if not ProgressStore.is_unlocked("category", "controllers") \
			or not ProgressStore.is_unlocked("preset", "Victron 100/20"):
		push_error("gating is disabled — everything must read unlocked")
		return 1
	if ProgressStore._would_be_unlocked("category", "controllers"):
		push_error("preserved rule: un-granted category would be locked")
		return 1
	if not ProgressStore._would_be_unlocked("category", "batteries"):
		push_error("preserved rule: baseline batteries would stay unlocked")
		return 1
	if ProgressStore._would_be_unlocked("preset", "Victron 100/20"):
		push_error("preserved rule: un-granted preset would be locked")
		return 1
	return 0


func _test_grants() -> int:
	_fresh()
	ProgressStore.mark_prompt_seen()
	ProgressStore.grant(["cat:controllers", "preset:Victron 100/20"])
	ProgressStore.grant(["cat:controllers"])  # duplicate — must not double
	if not ProgressStore._would_be_unlocked("category", "controllers"):
		push_error("granted category should record")
		return 1
	if not ProgressStore._would_be_unlocked("preset", "Victron 100/20"):
		push_error("granted preset should record")
		return 1
	if ProgressStore._would_be_unlocked("category", "processors"):
		push_error("ungranted category leaked into the preserved rule")
		return 1
	return 0


func _test_levels() -> int:
	_fresh()
	ProgressStore.mark_prompt_seen()
	var order := ["bootcamp_01", "bootcamp_02", "bootcamp_03"]
	if ProgressStore.first_incomplete_level(order) != "bootcamp_01":
		push_error("first incomplete should be level 1")
		return 1
	ProgressStore.mark_level_complete("bootcamp_01", {"attempts": 2})
	if not ProgressStore.is_level_complete("bootcamp_01"):
		push_error("level completion did not stick")
		return 1
	if ProgressStore.first_incomplete_level(order) != "bootcamp_02":
		push_error("first incomplete should advance to level 2")
		return 1
	if int(ProgressStore.level_stats("bootcamp_01").get("attempts", 0)) != 2:
		push_error("level stats did not round-trip")
		return 1
	for lid in order:
		ProgressStore.mark_level_complete(lid)
	if ProgressStore.first_incomplete_level(order) != "":
		push_error("all-complete should return empty id")
		return 1
	return 0


## The carry_graph curriculum (levels 10-12) needs the sandbox graph to survive
## a session close, or resuming lands on the blank canvas begin_tutorial_sandbox
## always starts from. Snapshot round-trips, survives a cache drop (new
## session), and reset_tutorial_progress (the "Start Over" affordance) drops it
## while leaving unrelated unlock state untouched.
func _test_sandbox_snapshot() -> int:
	_fresh()
	if not ProgressStore.load_sandbox_snapshot().is_empty():
		push_error("fresh store should have no sandbox snapshot")
		return 1
	var blob := {"items": [{"id": "bat", "type": "battery"}], "connections": []}
	ProgressStore.save_sandbox_snapshot("bootcamp_11_optimize", blob)
	var snap := ProgressStore.load_sandbox_snapshot()
	if str(snap.get("level_id", "")) != "bootcamp_11_optimize":
		push_error("sandbox snapshot level_id did not round-trip: %s" % str(snap))
		return 1
	if not (snap.get("graph", {}) as Dictionary).get("items", []).size() == 1:
		push_error("sandbox snapshot graph did not round-trip: %s" % str(snap))
		return 1
	# Survives a cache drop the way the rest of the file does.
	ProgressStore.reset_cache()
	if (ProgressStore.load_sandbox_snapshot().get("graph", {}) as Dictionary).is_empty():
		push_error("sandbox snapshot did not survive a cache drop")
		return 1
	# The resume gate (TutorialDirector._snapshot_resumable_into): a snapshot
	# only restores into the level that saved it or the one right after — a
	# leftover from quitting mid-level-3 must never restore into level 10 as
	# if it were the level-9 build.
	var director: Node = (load("res://gameplay/tutorial_director.gd") as GDScript).new()
	if not bool(director.call("_snapshot_resumable_into", "bootcamp_11_optimize")):
		push_error("snapshot should resume into the level that saved it")
		director.free()
		return 1
	var after_11 := str(TutorialCatalog.next_after("bootcamp_11_optimize"))
	if not bool(director.call("_snapshot_resumable_into", after_11)):
		push_error("snapshot should resume into the level after the one that saved it")
		director.free()
		return 1
	ProgressStore.save_sandbox_snapshot("bootcamp_01_short", blob)
	if bool(director.call("_snapshot_resumable_into", "bootcamp_11_optimize")):
		push_error("a stale early-level snapshot must not restore into a later carry level")
		director.free()
		return 1
	director.free()
	# reset_tutorial_progress clears completion + the snapshot, but must not
	# touch unrelated unlock grants (the per-level palette, not global unlocks,
	# is what actually gates content while a level is active).
	ProgressStore.mark_prompt_seen()
	ProgressStore.grant(["cat:controllers"])
	ProgressStore.mark_level_complete("bootcamp_10_score")
	ProgressStore.reset_tutorial_progress()
	if not ProgressStore.load_sandbox_snapshot().is_empty():
		push_error("reset_tutorial_progress should drop the sandbox snapshot")
		return 1
	if ProgressStore.is_level_complete("bootcamp_10_score"):
		push_error("reset_tutorial_progress should clear level completion")
		return 1
	if not ProgressStore._would_be_unlocked("category", "controllers"):
		push_error("reset_tutorial_progress must not revoke unrelated unlocks")
		return 1
	return 0


## Values must survive a cache drop (fresh session reading the same file).
func _test_disk_round_trip() -> int:
	_fresh()
	ProgressStore.mark_prompt_seen()
	ProgressStore.grant(["cat:controllers"])
	ProgressStore.mark_level_complete("bootcamp_01")
	ProgressStore.reset_cache()
	if ProgressStore.is_new_player():
		push_error("prompt state lost across reload")
		return 1
	if not ProgressStore._would_be_unlocked("category", "controllers"):
		push_error("grant lost across reload")
		return 1
	if not ProgressStore.is_level_complete("bootcamp_01"):
		push_error("level completion lost across reload")
		return 1
	return 0


func _test_unlock_all() -> int:
	_fresh()
	ProgressStore.unlock_all()
	if ProgressStore.is_new_player():
		push_error("unlock_all should count as answering the prompt")
		return 1
	if not ProgressStore.is_unlocked("category", "processors") \
			or not ProgressStore.is_unlocked("preset", "EG4 6000XP"):
		push_error("unlock_all should open everything")
		return 1
	return 0


# ---------------------------------------------------------------------------
# Part 2 — catalog + goals
# ---------------------------------------------------------------------------

## Every level id unique + ordered; every seed label, allowed preset, and
## "preset:*" unlock resolves to a real library preset; "cat:*" unlocks name
## real categories; every non-run goal has a known kind.
func _test_catalog_integrity() -> int:
	var levels := TutorialCatalog.all_levels()
	if levels.size() < 7:
		push_error("expected at least 7 bootcamp levels, got %d" % levels.size())
		return 1
	var seen_ids: Dictionary = {}
	var cat_ids: Dictionary = {}
	for cat in ComponentPresets.CATEGORIES:
		cat_ids[str((cat as Dictionary).get("id", ""))] = true
	var prev_index := 0
	for lvl_v in levels:
		var lvl: TutorialLevelDef = lvl_v
		if lvl.id.is_empty() or seen_ids.has(lvl.id):
			push_error("duplicate/empty level id '%s'" % lvl.id)
			return 1
		seen_ids[lvl.id] = true
		if lvl.index <= prev_index:
			push_error("level indexes must ascend (%s)" % lvl.id)
			return 1
		prev_index = lvl.index
		for e in lvl.seed:
			var label := str((e as Dictionary).get("preset_label", ""))
			if TutorialCatalog.find_preset(label).is_empty():
				push_error("%s: seed preset '%s' does not resolve" % [lvl.id, label])
				return 1
		for w in lvl.seed_wires:
			var a := int((w as Dictionary).get("from", -1))
			var b := int((w as Dictionary).get("to", -1))
			if a < 0 or b < 0 or a >= lvl.seed.size() or b >= lvl.seed.size():
				push_error("%s: seed wire indexes out of range" % lvl.id)
				return 1
		for label_v in lvl.allowed_presets:
			if TutorialCatalog.find_preset(str(label_v)).is_empty():
				push_error("%s: allowed preset '%s' does not resolve" % [lvl.id, str(label_v)])
				return 1
		for u in lvl.unlocks:
			var s := str(u)
			if s.begins_with("cat:"):
				if not cat_ids.has(s.trim_prefix("cat:")):
					push_error("%s: unlock category '%s' does not exist" % [lvl.id, s])
					return 1
			elif s.begins_with("preset:"):
				if TutorialCatalog.find_preset(s.trim_prefix("preset:")).is_empty():
					push_error("%s: unlock preset '%s' does not resolve" % [lvl.id, s])
					return 1
			elif s != "unlock_all":
				push_error("%s: unlock entry '%s' has no cat:/preset: prefix" % [lvl.id, s])
				return 1
		if str(lvl.goal.get("kind", "")) not in ["fault_observed", "build",
				"run_clean", "ac_load_wired", "compound_containing"]:
			push_error("%s: unknown goal kind '%s'" % [lvl.id, str(lvl.goal.get("kind", ""))])
			return 1
		if lvl.carry_graph and lvl.index <= 1:
			push_error("%s: the first level cannot carry a previous graph" % lvl.id)
			return 1
	if TutorialCatalog.next_after(str(levels[0].id)) != str(levels[1].id):
		push_error("next_after should walk the catalog order")
		return 1
	return 0


func _test_level_def_round_trip() -> int:
	var src := TutorialCatalog.by_id("bootcamp_07_3s2p")
	if src == null:
		push_error("level 7 missing from catalog")
		return 1
	var back := TutorialLevelDef.from_dict(src.to_dict())
	if back.id != src.id or back.index != src.index \
			or back.seed.size() != src.seed.size() \
			or back.seed_wires.size() != src.seed_wires.size() \
			or back.goal != src.goal or back.unlocks != src.unlocks:
		push_error("TutorialLevelDef did not round-trip")
		return 1
	return 0


func _test_goal_fault_observed() -> int:
	var model: GraphModel = GraphModelScript.new()
	var ctx := TutorialGoals.build_ctx(model, {})
	if bool(TutorialGoals.evaluate({"kind": "fault_observed", "reason": "short_circuit"}, ctx).get("met", true)):
		push_error("fault goal met with no fault seen")
		return 1
	ctx = TutorialGoals.build_ctx(model, {"short_circuit": true})
	if not bool(TutorialGoals.evaluate({"kind": "fault_observed", "reason": "short_circuit"}, ctx).get("met", false)):
		push_error("fault goal should be met once observed")
		return 1
	return 0


## Level 3 shape: battery + 300 W panel + 10 A PWM → deliverable 120 W.
func _test_goal_build_pwm() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "bat", 12.0)
	_add_panel(model, "p1", 300.0, 40.0)
	_add_controller(model, "ctrl", 50.0, 10.0)
	# Unwired: goal must not pass.
	var ctx := TutorialGoals.build_ctx(model, {})
	var goal := {"kind": "build", "min_deliverable_w": 100.0}
	if bool(TutorialGoals.evaluate(goal, ctx).get("met", true)):
		push_error("unwired system should not meet the build goal")
		return 1
	# Half-wired must NOT pass. A circuit needs a return path: until the second
	# leg lands, no current flows and nothing is delivered. This is the bug the
	# level-3 playtest hit — the goal fired on the first positive wire.
	_wire(model, "p1", "positive", "ctrl", "pvPositive")
	ctx = TutorialGoals.build_ctx(model, {})
	if bool(TutorialGoals.evaluate(goal, ctx).get("met", true)):
		push_error("PV wired on the positive leg only should not meet the build goal")
		return 1
	_wire(model, "p1", "negative", "ctrl", "pvNegative")
	_wire(model, "ctrl", "batteryPositive", "bat", "positive")
	ctx = TutorialGoals.build_ctx(model, {})
	if bool(TutorialGoals.evaluate(goal, ctx).get("met", true)):
		push_error("battery wired on the positive leg only should not meet the build goal")
		return 1
	if float(TutorialGoals.deliverable(model, ctx["flat_conns"],
			ctx["analysis"]).get("deliverable_w", -1.0)) != 0.0:
		push_error("an open battery return leg must deliver 0 W")
		return 1
	_wire(model, "ctrl", "batteryNegative", "bat", "negative")
	ctx = TutorialGoals.build_ctx(model, {})
	var res := TutorialGoals.evaluate(goal, ctx)
	if not bool(res.get("met", false)):
		push_error("wired PWM system should meet build goal: %s" % str(res))
		return 1
	var deliv := TutorialGoals.deliverable(model, ctx["flat_conns"], ctx["analysis"])
	if absf(float(deliv.get("deliverable_w", 0.0)) - 120.0) > 0.5:
		push_error("PWM deliverable expected 120 W got %s" % str(deliv))
		return 1
	# A destroyed node anywhere blocks build goals.
	var sp: Dictionary = (model.get_item("bat").get("specs", {}) as Dictionary).duplicate(true)
	sp["destroyed"] = true
	model.update_item("bat", {"specs": sp})
	ctx = TutorialGoals.build_ctx(model, {})
	if bool(TutorialGoals.evaluate(goal, ctx).get("met", true)):
		push_error("destroyed battery should block the build goal")
		return 1
	return 0


## Level 5 shape: 2S bank (24 V) + 4 panels parallel + 30 A MPPT → 720 W.
func _test_goal_build_bus_and_watts() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "a", 12.0)
	_add_battery(model, "b", 12.0)
	_add_controller(model, "ctrl", 150.0, 30.0)
	_wire(model, "a", "positive", "b", "negative")
	for i in 4:
		_add_panel(model, "p%d" % i, 300.0, 40.0)
		_wire(model, "p%d" % i, "positive", "ctrl", "pvPositive")
		_wire(model, "p%d" % i, "negative", "ctrl", "pvNegative")
	_wire(model, "ctrl", "batteryPositive", "b", "positive")
	_wire(model, "ctrl", "batteryNegative", "a", "negative")
	var ctx := TutorialGoals.build_ctx(model, {})
	var goal := {"kind": "build", "min_bus_v": 24.0, "min_deliverable_w": 700.0}
	var res := TutorialGoals.evaluate(goal, ctx)
	if not bool(res.get("met", false)):
		push_error("24 V bank + 4-panel parallel array should meet L5 goal: %s" % str(res))
		return 1
	var deliv := TutorialGoals.deliverable(model, ctx["flat_conns"], ctx["analysis"])
	if absf(float(deliv.get("deliverable_w", 0.0)) - 720.0) > 0.5:
		push_error("24 V × 30 A deliverable expected 720 W got %s" % str(deliv))
		return 1
	return 0


## Level 7 shape: 6 panels as 3S2P matches (3,2); all-series does not.
func _test_goal_array_config() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "bat", 12.0)
	_add_controller(model, "ctrl", 150.0, 30.0)
	for i in 6:
		_add_panel(model, "p%d" % i, 300.0, 40.0)
	# String A: p0→p1→p2 in series; String B: p3→p4→p5.
	_wire(model, "p0", "positive", "p1", "negative")
	_wire(model, "p1", "positive", "p2", "negative")
	_wire(model, "p3", "positive", "p4", "negative")
	_wire(model, "p4", "positive", "p5", "negative")
	# Both strings parallel into the controller.
	_wire(model, "p2", "positive", "ctrl", "pvPositive")
	_wire(model, "p5", "positive", "ctrl", "pvPositive")
	_wire(model, "p0", "negative", "ctrl", "pvNegative")
	_wire(model, "p3", "negative", "ctrl", "pvNegative")
	_wire(model, "ctrl", "batteryPositive", "bat", "positive")
	_wire(model, "ctrl", "batteryNegative", "bat", "negative")
	var flat := GraphNesting.flat_connections(model)
	if not TutorialGoals.array_config_matches(model, flat, 3, 2):
		push_error("3S2P wiring should match (3,2)")
		return 1
	if TutorialGoals.array_config_matches(model, flat, 6, 1):
		push_error("3S2P wiring must not match (6,1)")
		return 1
	return 0


## Level 9 shape: appliance on the controller's AC output (direct or via one
## distribution hop); DC-only wiring must not count.
func _test_goal_ac_load_wired() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "bat", 48.0)
	_add_controller(model, "ctrl", 150.0, 30.0)
	model.add_item({"id": "lamp", "type": "appliance", "x": 200.0, "y": 100.0,
		"width": 160.0, "height": 104.0, "scope_id": "root",
		"specs": {"max_watts": 100.0, "avg_watts": 50.0}})
	_wire(model, "ctrl", "batteryPositive", "bat", "positive")
	_wire(model, "ctrl", "batteryNegative", "bat", "negative")
	var flat := GraphNesting.flat_connections(model)
	if TutorialGoals.ac_load_wired(model, flat):
		push_error("no AC wire yet — must not count as wired")
		return 1
	model.add_connection({"scope_id": "root", "polarity": "ac",
		"source_item_id": "ctrl", "source_handle_id": "acOutput",
		"target_item_id": "lamp", "target_handle_id": "input"})
	flat = GraphNesting.flat_connections(model)
	if not TutorialGoals.ac_load_wired(model, flat):
		push_error("appliance on controller acOutput should count as wired")
		return 1
	return 0


## Level 12 shape: a compound whose child scope holds a controller + battery.
func _test_goal_compound_containing() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "bat", 48.0)
	_add_controller(model, "ctrl", 150.0, 30.0)
	if TutorialGoals.compound_containing(model, ["controller", "battery"]):
		push_error("flat items must not read as combined")
		return 1
	model.add_item({"id": "box", "type": "compound", "x": 0.0, "y": 0.0,
		"width": 180.0, "height": 120.0, "scope_id": "root",
		"child_scope_id": "scope_box", "specs": {"compound_kind": ""}})
	model.ensure_scope("scope_box", "root", "box", "box")
	model.update_item("bat", {"scope_id": "scope_box", "parent_compound_id": "box"})
	model.update_item("ctrl", {"scope_id": "scope_box", "parent_compound_id": "box"})
	if not TutorialGoals.compound_containing(model, ["controller", "battery"]):
		push_error("compound holding controller+battery should match")
		return 1
	if TutorialGoals.compound_containing(model, ["controller", "battery", "panel"]):
		push_error("missing panel type must not match")
		return 1
	return 0


## Run-level verdicts from bake results (utilization threshold).
func _test_run_verdict() -> int:
	var goal := {"kind": "run_clean", "min_useful_utilization_pct": 60.0}
	var low := TutorialGoals.evaluate_run(goal, {"useful_utilization_pct": 35.0})
	if bool(low.get("met", true)):
		push_error("35%% utilization must not pass a 60%% bar")
		return 1
	var high := TutorialGoals.evaluate_run(goal, {"useful_utilization_pct": 71.0})
	if not bool(high.get("met", false)):
		push_error("71%% utilization should pass a 60%% bar")
		return 1
	var no_bar := TutorialGoals.evaluate_run({"kind": "run_clean"}, {"useful_utilization_pct": 5.0})
	if not bool(no_bar.get("met", false)):
		push_error("run_clean with no bar should pass any completed run")
		return 1
	return 0


## Unlocks are granted by a silent static write, so the only thing telling the
## player what they earned is this label resolution. Every grant entry in the
## whole catalog must produce a non-empty, human-readable name.
func _test_unlock_labels() -> int:
	var TutorialDirectorScript := load("res://gameplay/tutorial_director.gd") as GDScript
	if TutorialDirectorScript == null:
		push_error("could not load tutorial_director.gd")
		return 1
	var got: Array = TutorialDirectorScript.unlock_labels(
		["cat:controllers", "preset:Trainer 300W", "unlock_all"])
	if got.size() != 3:
		push_error("expected 3 labels, got %s" % str(got))
		return 1
	if str(got[0]) == "controllers":
		push_error("category should resolve to its display label, not its id")
		return 1
	if str(got[1]) != "Trainer 300W":
		push_error("preset should resolve to its label, got %s" % str(got[1]))
		return 1
	for lbl in got:
		if str(lbl).strip_edges().is_empty():
			push_error("unlock produced an empty label")
			return 1
	# Every unlock the shipped catalog can hand out must name something.
	for lvl_v in TutorialCatalog.all_levels():
		var lvl: TutorialLevelDef = lvl_v
		if lvl.unlocks.is_empty():
			continue
		var labels: Array = TutorialDirectorScript.unlock_labels(lvl.unlocks)
		if labels.size() != lvl.unlocks.size():
			push_error("%s: %d unlocks produced %d labels" % [
				lvl.id, lvl.unlocks.size(), labels.size()])
			return 1
		for lbl2 in labels:
			if str(lbl2).strip_edges().is_empty():
				push_error("%s: produced an empty unlock label" % lvl.id)
				return 1
	return 0


func _add_battery(model: GraphModel, id: String, voltage: float) -> void:
	model.add_item({"id": id, "type": "battery", "x": 0.0, "y": 200.0,
		"width": 110.0, "height": 80.0, "scope_id": "root",
		"specs": {"voltage": voltage, "ah": 100.0, "kwh": 1.2, "soc": 0.8}})


func _add_panel(model: GraphModel, id: String, wmp: float, voc: float) -> void:
	model.add_item({"id": id, "type": "panel", "x": 0.0, "y": -200.0,
		"width": 120.0, "height": 100.0, "scope_id": "root",
		"specs": {"wmp": wmp, "voc": voc, "vmp": voc * 0.8, "isc": 9.9, "imp": 9.4}})


func _add_controller(model: GraphModel, id: String, max_voc: float, amps: float) -> void:
	model.add_item({"id": id, "type": "controller", "x": 0.0, "y": 0.0,
		"width": 140.0, "height": 120.0, "scope_id": "root",
		"specs": {"max_voc": max_voc, "max_charge_amps": amps}})


func _wire(model: GraphModel, src: String, src_handle: String,
		tgt: String, tgt_handle: String) -> void:
	var pol := "negative" if src_handle.to_lower().contains("neg") else "positive"
	model.add_connection({"scope_id": "root", "polarity": pol,
		"source_item_id": src, "source_handle_id": src_handle,
		"target_item_id": tgt, "target_handle_id": tgt_handle})
