extends SceneTree

## Headless self-test for the site deployment schedule (core/population/
## site_deploy_schedule.gd + site_deploy_planner.gd): the record (add /
## move / remove, the forward-crossing `due` and the backward-crossing
## `rewound`, phase_at, a JSON round trip), the planner (labour from mass,
## the rows per structure kind and action with their effects and
## dependencies, nearest-crew assignment under the board caps, the ALL
## HANDS crew pick), a real NpcChoreBoard taking a deploy plan and a
## SiteProject rolling it up, and the camp runtime's reveal count. Carries
## EXPECTED_CHECKS (a runtime error aborts a test function while PASS still
## prints). Run --import first.
##   godot --headless --path . --script core/population/site_deploy_selftest.gd

const EXPECTED_CHECKS := 78

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_schedule()
	_test_planner_rows()
	_test_planner_assign()
	_test_board_round_trip()
	_test_camp_reveal()
	_test_staging()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("SITE DEPLOY SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SITE DEPLOY SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


# ---------------------------------------------------------------------------

func _test_schedule() -> void:
	var rec := SiteDeploySchedule.empty()
	_check("empty schedule", SiteDeploySchedule.is_empty(rec) and SiteDeploySchedule.events_sorted(rec).is_empty())
	var base := 17_000_000.0   # absolute hours, a 2026-ish date
	var d := SiteDeploySchedule.add_event(rec, SiteDeploySchedule.ACTION_DEPLOY, base + 10.0)
	var p := SiteDeploySchedule.add_event(rec, SiteDeploySchedule.ACTION_PACKUP, base + 60.0)
	_check("two events with ids", d == "ev_1" and p == "ev_2")
	_check("a second deploy at the same hour is the first one",
		SiteDeploySchedule.add_event(rec, SiteDeploySchedule.ACTION_DEPLOY, base + 10.0) == d)
	_check("bad action / NAN refused",
		SiteDeploySchedule.add_event(rec, "fly", base).is_empty()
		and SiteDeploySchedule.add_event(rec, SiteDeploySchedule.ACTION_DEPLOY, NAN).is_empty())
	var sorted := SiteDeploySchedule.events_sorted(rec)
	_check("sorted by time", sorted.size() == 2 and str(sorted[0]["id"]) == d)

	# Forward crossing fires each once; nothing fires on the first (NAN) tick.
	_check("NAN prev finds nothing", SiteDeploySchedule.due(rec, NAN, base + 100.0).is_empty())
	var due := SiteDeploySchedule.due(rec, base + 5.0, base + 11.0)
	_check("deploy due when crossed", due.size() == 1 and str(due[0]["id"]) == d)
	SiteDeploySchedule.mark_fired(rec, d, base + 11.0, {"crews": ["hab_a"], "items": [{"kind": "prop", "id": "p1"}]})
	_check("fired stamp carries its info", SiteDeploySchedule.is_fired(rec, d)
		and (SiteDeploySchedule.fired_info(rec, d).get("crews", []) as Array) == ["hab_a"])
	_check("a fired event is not due again", SiteDeploySchedule.due(rec, base + 5.0, base + 12.0).is_empty())
	var both := SiteDeploySchedule.due(rec, base + 5.0, base + 70.0)
	_check("a long jump fires only the unfired one", both.size() == 1 and str(both[0]["id"]) == p)
	_check("backwards = nothing due", SiteDeploySchedule.due(rec, base + 70.0, base + 5.0).is_empty())

	# Backward crossing undoes fired events, latest first.
	SiteDeploySchedule.mark_fired(rec, p, base + 61.0)
	var rw := SiteDeploySchedule.rewound(rec, base + 70.0, base + 5.0)
	_check("rewound lists both fired events, latest first",
		rw.size() == 2 and str(rw[0]["id"]) == p and str(rw[1]["id"]) == d)
	_check("rewound past only the pack-up", SiteDeploySchedule.rewound(rec, base + 70.0, base + 30.0).size() == 1)
	SiteDeploySchedule.unmark(rec, p)
	_check("unmarked event no longer rewinds", SiteDeploySchedule.rewound(rec, base + 70.0, base + 5.0).size() == 1)

	# Phase: the last event at or before t.
	_check("phase before any event", str(SiteDeploySchedule.phase_at(rec, base)["phase"]) == SiteDeploySchedule.PHASE_NONE)
	var ph := SiteDeploySchedule.phase_at(rec, base + 30.0)
	_check("deployed between the events, next = the pack-up",
		str(ph["phase"]) == SiteDeploySchedule.PHASE_DEPLOYED and str((ph["next"] as Dictionary).get("id", "")) == p
		and bool(ph["fired"]))
	_check("packed after the pack-up", str(SiteDeploySchedule.phase_at(rec, base + 61.0)["phase"]) == SiteDeploySchedule.PHASE_PACKED)

	# Moving clears the stamp; removing drops it.
	_check("move clears the stamp", SiteDeploySchedule.move_event(rec, d, base + 20.0)
		and not SiteDeploySchedule.is_fired(rec, d)
		and absf(float(SiteDeploySchedule.event(rec, d)["at_h"]) - (base + 20.0)) < 1e-9)
	_check("remove", SiteDeploySchedule.remove_event(rec, p) and SiteDeploySchedule.events_sorted(rec).size() == 1
		and not SiteDeploySchedule.remove_event(rec, "ev_9"))

	# JSON round trip (the file on disk) keeps ids, times and stamps; junk is dropped.
	SiteDeploySchedule.mark_fired(rec, d, base + 21.0, {"pending": [{"kind": "camp", "id": "c1"}]})
	var txt := JSON.stringify(rec)
	var back := SiteDeploySchedule.normalize(JSON.parse_string(txt))
	_check("round trip", SiteDeploySchedule.events_sorted(back).size() == 1
		and SiteDeploySchedule.is_fired(back, d)
		and (SiteDeploySchedule.fired_info(back, d).get("pending", []) as Array).size() == 1
		and int(back["next_id"]) == int(rec["next_id"]))
	var junk := SiteDeploySchedule.normalize({"events": [{"id": "ev_3", "action": "x", "at_h": 1.0},
		{"id": "ev_4", "action": "deploy"}, {"id": "ev_5", "action": "packup", "at_h": 7.0}],
		"fired": {"ev_5": {"at": 7.0}, "ev_8": {"at": 1.0}}})
	_check("normalize drops a bad action, a missing time and a stamp with no event",
		SiteDeploySchedule.events_sorted(junk).size() == 1 and SiteDeploySchedule.is_fired(junk, "ev_5")
		and not SiteDeploySchedule.is_fired(junk, "ev_8") and int(junk["next_id"]) == 6)
	_check("labels", SiteDeploySchedule.action_label("deploy") == "Deploy the site"
		and SiteDeploySchedule.action_verb("packup") == "Packing up"
		and SiteDeploySchedule.describe({"action": "packup", "at_h": 1.0}) == "Pack up")


# ---------------------------------------------------------------------------

func _item(id: String, model: String, mass: float, pos: Vector2 = Vector2.ZERO) -> Dictionary:
	return {"kind": "prop", "id": id, "label": model.capitalize(), "pos": pos,
		"mass_kg": mass, "model_id": model}


func _ids(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		out.append(str((r as Dictionary).get("task_id", "")))
	return out


func _effect_ops(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		var e: Dictionary = (r as Dictionary).get("effect", {})
		out.append(str(e.get("op", "")))
	return out


func _test_planner_rows() -> void:
	_check("labour from mass: unknown = 1 h, 34 kg ≈ 1.25 h, 350 kg ≈ 9.15 h, clamped at 24",
		absf(SiteDeployPlanner.labour_hours(-1.0) - 1.0) < 1e-9
		and absf(SiteDeployPlanner.labour_hours(34.0) - 1.25) < 1e-9
		and absf(SiteDeployPlanner.labour_hours(350.0) - 9.15) < 1e-9
		and absf(SiteDeployPlanner.labour_hours(5000.0) - 24.0) < 1e-9)
	_check("camp hours: 0.12 per structure, floored", absf(SiteDeployPlanner.camp_hours(20) - 2.4) < 1e-9
		and absf(SiteDeployPlanner.camp_hours(1) - 0.3) < 1e-9)

	# Generic prop: three phases, ghost stamps, the raise unpacks.
	var pod := _item("p_pod", "shiftpod", 34.0)
	var rows := SiteDeployPlanner.rows_for(pod, SiteDeploySchedule.ACTION_DEPLOY, 6)
	_check("generic deploy = lay_out → assemble → finish", _ids(rows) == ["lay_out", "assemble", "finish"])
	_check("generic deploy effects: ghost, ghost, unpack",
		_effect_ops(rows) == ["set_build_phase", "set_build_phase", "unpack_prop"])
	_check("assemble depends on lay_out, finish on assemble",
		(rows[1]["depends_on"] as Array) == ["lay_out"] and (rows[2]["depends_on"] as Array) == ["assemble"])
	_check("assemble carries a half-way ghost stage", (rows[1].get("stage_effects", []) as Array).size() == 1)
	var total := 0.0
	for r in rows:
		total += float((r as Dictionary)["chore_hours"])
	_check("the phases add up to the labour", absf(total - SiteDeployPlanner.labour_hours(34.0)) < 1e-6, "%.3f" % total)
	_check("every row targets the prop", str((rows[0]["target"] as Dictionary).get("id", "")) == "p_pod")
	_check("a 1-person camp gets single-worker rows",
		int(SiteDeployPlanner.rows_for(pod, SiteDeploySchedule.ACTION_DEPLOY, 1)[1]["max_workers"]) == 1)

	var packup := SiteDeployPlanner.rows_for(pod, SiteDeploySchedule.ACTION_PACKUP, 6)
	_check("generic pack-up = strip → pack", _ids(packup) == ["strip", "pack"]
		and _effect_ops(packup) == ["set_build_phase", "pack_prop"])
	var ptotal := 0.0
	for r in packup:
		ptotal += float((r as Dictionary)["chore_hours"])
	_check("pack-up is PACKUP_SCALE of the deploy", absf(ptotal - total * SiteDeployPlanner.PACKUP_SCALE) < 1e-6)

	# Pallet rack: four phases, the raise needs a crew.
	var rack := _item("p_rack", PalletRackBuilder.MODEL_ID, 350.0)
	var rrows := SiteDeployPlanner.rows_for(rack, SiteDeploySchedule.ACTION_DEPLOY, 10)
	_check("rack deploy = unpack → frames → decks → finish", _ids(rrows) == ["unpack", "frames", "decks", "finish"])
	_check("raising the frames takes four; finish unpacks",
		int(rrows[1]["min_workers"]) == 4 and str((rrows[3]["effect"] as Dictionary).get("op", "")) == "unpack_prop")
	_check("a crew of two raises with two", int(SiteDeployPlanner.rows_for(rack, SiteDeploySchedule.ACTION_DEPLOY, 2)[1]["min_workers"]) == 2)

	# Linkage: the existing rebuild / breakdown rows.
	var link := _item("p_link", LinkageStructureBuilder.MODEL_ID, 150.0)
	link["counts"] = {"module_count": 6, "bolt_count": 36, "panel_count": 4}
	var lrows := SiteDeployPlanner.rows_for(link, SiteDeploySchedule.ACTION_DEPLOY, 8)
	_check("linkage deploy = the prefab raise rows", _ids(lrows) == ["erect", "bolts", "panels"])
	var lpack := SiteDeployPlanner.rows_for(link, SiteDeploySchedule.ACTION_PACKUP, 8)
	_check("linkage pack-up = the breakdown rows", _ids(lpack) == ["strip_panels", "unbolt", "fold_pack"])

	# Camp: one row, the effect sets the record.
	var camp := {"kind": "camp", "id": "camp_3", "label": "Camp Awesome", "pos": Vector2(10, 20), "structures": 25}
	var crows := SiteDeployPlanner.rows_for(camp, SiteDeploySchedule.ACTION_DEPLOY, 12)
	_check("camp pitch row", crows.size() == 1 and str(crows[0]["task_id"]) == "pitch"
		and absf(float(crows[0]["chore_hours"]) - 3.0) < 1e-9
		and bool((crows[0]["effect"] as Dictionary)["built"]) == true
		and str((crows[0]["effect"] as Dictionary)["camp_id"]) == "camp_3")
	var srows := SiteDeployPlanner.rows_for(camp, SiteDeploySchedule.ACTION_PACKUP, 12)
	_check("camp strike row", str(srows[0]["task_id"]) == "strike"
		and bool((srows[0]["effect"] as Dictionary)["built"]) == false
		and absf(float(srows[0]["chore_hours"]) - 1.8) < 1e-9)
	_check("camp row targets its centre", str((crows[0]["target"] as Dictionary)["kind"]) == "pos"
		and absf(float((crows[0]["target"] as Dictionary)["x"]) - 10.0) < 1e-9)
	_check("labels", SiteDeployPlanner.project_label(camp, "deploy") == "Deploy: Camp Awesome"
		and SiteDeployPlanner.project_label(pod, "packup") == "Pack up: Shiftpod")
	# A container in reach adds the carry to its door after the pack.
	var pod2 := _item("p_pod2", "shiftpod", 34.0)
	pod2["loadout"] = {"x": 12.0, "z": -3.0}
	var lrows2 := SiteDeployPlanner.rows_for(pod2, SiteDeploySchedule.ACTION_PACKUP, 6)
	_check("pack-up with a container = strip → pack → load_out", _ids(lrows2) == ["strip", "pack", "load_out"]
		and (lrows2[2]["depends_on"] as Array) == ["pack"]
		and str((lrows2[2]["effect"] as Dictionary).get("op", "")) == "move_prop"
		and absf(float((lrows2[2]["carry_to"] as Dictionary)["x"]) - 12.0) < 1e-9)
	link["loadout"] = {"x": 1.0, "z": 2.0}
	_check("a linkage pack-up carries its crate out too",
		_ids(SiteDeployPlanner.rows_for(link, SiteDeploySchedule.ACTION_PACKUP, 8)).has("load_out"))


# ---------------------------------------------------------------------------

func _crew(iid: String, home: Vector2, roster: int, chores: int, projects: int) -> Dictionary:
	return {"iid": iid, "home": home, "roster": roster, "free_chores": chores, "free_projects": projects}


func _test_planner_assign() -> void:
	var near := _crew("hab_near", Vector2(0, 0), 10, 160, 48)
	var far := _crew("hab_far", Vector2(500, 0), 10, 160, 48)
	var items := [_item("p1", "shiftpod", 34.0, Vector2(5, 0)), _item("p2", "shiftpod", 34.0, Vector2(480, 0)),
		_item("p3", "ez_up", 27.0, Vector2(20, 0))]
	var res := SiteDeployPlanner.assign(items, [near, far], SiteDeploySchedule.ACTION_DEPLOY)
	var a: Dictionary = res["assigned"]
	_check("nearest crew takes each item", (a.get("hab_near", []) as Array).size() == 2
		and (a.get("hab_far", []) as Array).size() == 1 and (res["unassigned"] as Array).is_empty())
	_check("deterministic item order (by id)", str((a["hab_near"] as Array)[0]["id"]) == "p1"
		and str((a["hab_near"] as Array)[1]["id"]) == "p3")

	# Board room: a crew with room for one generic item (3 rows) takes one;
	# the next goes to the far crew; with no room anywhere it is unassigned.
	var tight := _crew("hab_tight", Vector2(0, 0), 10, 4, 48)
	var res2 := SiteDeployPlanner.assign(items, [tight, far], SiteDeploySchedule.ACTION_DEPLOY)
	_check("a nearly full board takes one item, the rest spill to the next crew",
		((res2["assigned"] as Dictionary).get("hab_tight", []) as Array).size() == 1
		and ((res2["assigned"] as Dictionary).get("hab_far", []) as Array).size() == 2)
	var full := _crew("hab_full", Vector2(0, 0), 10, 160, 0)
	var res3 := SiteDeployPlanner.assign(items, [full], SiteDeploySchedule.ACTION_DEPLOY)
	_check("no project slot = unassigned", (res3["unassigned"] as Array).size() == 3
		and (res3["assigned"] as Dictionary).is_empty())
	_check("no crews at all", (SiteDeployPlanner.assign(items, [], "deploy")["unassigned"] as Array).size() == 3)

	# ALL HANDS pick: nearest to the items' centroid until the people budget.
	var crews := [_crew("a", Vector2(0, 0), 100, 0, 0), _crew("b", Vector2(50, 0), 100, 0, 0),
		_crew("c", Vector2(900, 0), 100, 0, 0)]
	var picked := SiteDeployPlanner.pick_crews(crews, [_item("x", "shiftpod", 1.0, Vector2(10, 0))], 150)
	_check("pick crews nearest first until the budget", picked == ["a", "b"])
	_check("at least one crew even over budget",
		SiteDeployPlanner.pick_crews(crews, [], 1) == ["a"] and SiteDeployPlanner.pick_crews([], []).is_empty())
	_check("default budget takes all three", SiteDeployPlanner.pick_crews(crews, []).size() == 3)


# ---------------------------------------------------------------------------

func _test_board_round_trip() -> void:
	# A real board takes a deploy plan: the rows become chores with their
	# effects, deps and targets, and a SiteProject rolls them up.
	var board := NpcChoreBoard.new()
	var pod := _item("p_pod", "shiftpod", 34.0, Vector2(3, 4))
	var rows := SiteDeployPlanner.rows_for(pod, SiteDeploySchedule.ACTION_DEPLOY, 6)
	var made: Array = board.add_plan(rows, SiteDeployPlanner.WORK_WINDOW, {"kind": "prop", "id": "p_pod"})
	_check("the board took every row", made.size() == 3)
	var finish: Dictionary = board.find(str(made[2]))
	_check("finish carries the unpack effect and depends on assemble",
		str((finish.get("effect", {}) as Dictionary).get("op", "")) == "unpack_prop"
		and (finish.get("depends_on", []) as Array) == [str(made[1])])
	var asm: Dictionary = board.find(str(made[1]))
	_check("assemble carries its stage effect", (asm.get("stage_effects", []) as Array).size() == 1)
	_check("the whole-day window", absf(float((asm["window"] as Dictionary)["end_h"]) - 24.0) < 1e-9)
	var project := SiteProject.make(SiteProject.KIND_SITE_DEPLOY, "Deploy: Shiftpod", "p_pod", Vector2(3, 4), 100.0)
	SiteProject.bind_tasks(project, rows, made)
	_check("bound task ids", (project["tasks"] as Array).size() == 3
		and str((project["tasks"] as Array)[0]["task_id"]) == "lay_out")
	_check("site deploy is a build kind, pack-up a breakdown kind",
		SiteProject.is_build_kind(SiteProject.KIND_SITE_DEPLOY) and SiteProject.is_breakdown_kind(SiteProject.KIND_SITE_PACKUP)
		and not SiteProject.is_build_kind(SiteProject.KIND_SITE_PACKUP))
	var roll := SiteProject.rollup(project, board)
	_check("rollup: nothing done yet", int(roll["done"]) == 0 and float(roll["progress"]) == 0.0)
	# Credit the first chore to completion through the board's own rule.
	var c0 := str(made[0])
	board.update_chore(c0, {"workers": ["w1"]})
	board.credit(c0, 10.0, 100.0)
	_check("sync marks the finished task", SiteProject.sync_with_board(project, board, 101.0)
		and str((project["tasks"] as Array)[0]["status"]) == "done")
	var roll2 := SiteProject.rollup(project, board)
	_check("progress is labour-weighted (0.25 of the hours)", absf(float(roll2["progress"]) - 0.25) < 1e-6, "%.3f" % float(roll2["progress"]))
	_check("stage effect not due before half-way", SiteProject.due_stage_effects(asm).is_empty())
	board.update_chore(str(made[1]), {"workers": ["w1"]})
	board.credit(str(made[1]), float(asm["chore_hours"]) * 0.6, 101.0)
	_check("stage effect due past half-way", SiteProject.due_stage_effects(board.find(str(made[1]))) == [0])
	var fr := SiteProject.task_fractions(project, board)
	_check("task fractions: lay_out done, assemble 0.6, finish 0",
		absf(float(fr["lay_out"]) - 1.0) < 1e-9 and absf(float(fr["assemble"]) - 0.6) < 1e-6
		and float(fr["finish"]) == 0.0)


# ---------------------------------------------------------------------------

func _test_staging() -> void:
	# Deploy: lay_out lays the parts out, assemble seats them.
	var st := AssemblyBuildSite.stage_state({"lay_out": 0.5, "assemble": 0.0}, SiteDeploySchedule.ACTION_DEPLOY)
	_check("half laid out, nothing up", absf(float(st["laid"]) - 0.5) < 1e-9 and float(st["assembled"]) == 0.0)
	st = AssemblyBuildSite.stage_state({"lay_out": 1.0, "assemble": 0.3}, SiteDeploySchedule.ACTION_DEPLOY)
	_check("all laid out, 30 % up", float(st["laid"]) == 1.0 and absf(float(st["assembled"]) - 0.3) < 1e-9)
	st = AssemblyBuildSite.stage_state({"lay_out": 1.0, "assemble": 0.9, "finish": 1.0}, SiteDeploySchedule.ACTION_DEPLOY)
	_check("a finished finish seats everything", float(st["assembled"]) == 1.0)
	_check("no tasks = nothing yet", float(AssemblyBuildSite.stage_state({}, "deploy")["laid"]) == 0.0)
	# Pack-up: strip takes them down, pack takes them away.
	st = AssemblyBuildSite.stage_state({"strip": 0.25, "pack": 0.0}, SiteDeploySchedule.ACTION_PACKUP)
	_check("a quarter stripped: 75 % still up, all still on site",
		absf(float(st["assembled"]) - 0.75) < 1e-9 and float(st["laid"]) == 1.0)
	st = AssemblyBuildSite.stage_state({"strip": 1.0, "pack": 0.5}, SiteDeploySchedule.ACTION_PACKUP)
	_check("stripped and half packed: nothing up, half on the ground",
		float(st["assembled"]) == 0.0 and absf(float(st["laid"]) - 0.5) < 1e-9)
	# Parts seat one at a time, bottom up: part i of n is on its way while
	# assembled × n crosses i.
	_check("part seating windows", AssemblyBuildSite.part_seat(0, 4, 0.0) == 0.0
		and absf(AssemblyBuildSite.part_seat(0, 4, 0.125) - 0.5) < 1e-9
		and AssemblyBuildSite.part_seat(0, 4, 0.25) == 1.0
		and AssemblyBuildSite.part_seat(3, 4, 0.75) == 0.0
		and AssemblyBuildSite.part_seat(3, 4, 1.0) == 1.0
		and AssemblyBuildSite.part_seat(0, 0, 0.0) == 1.0)
	_check("builder-mode models", AssemblyBuildSite.BUILDER_MODELS.has(DomeLabBuilder.MODEL_ID)
		and AssemblyBuildSite.BUILDER_MODELS.has(ToroidLabBuilder.MODEL_ID)
		and AssemblyBuildSite.BUILDER_MODELS.has(FlatpackBuilder.MODEL_ID)
		and not AssemblyBuildSite.BUILDER_MODELS.has(GantryLabBuilder.MODEL_ID))
	# The manual queue rides the schedule file.
	var rec := SiteDeploySchedule.empty()
	rec["manual"] = {"crews": ["hab_a"], "items": [{"kind": "prop", "id": "p1"}], "pending": [],
		"projects": [], "done": false, "action": "deploy"}
	var back := SiteDeploySchedule.normalize(JSON.parse_string(JSON.stringify(rec)))
	_check("the manual stamp survives the file", (back.get("manual", {}) as Dictionary).get("action", "") == "deploy"
		and ((back["manual"] as Dictionary)["crews"] as Array) == ["hab_a"])
	_check("no manual stamp = none", not SiteDeploySchedule.normalize({"events": []}).has("manual"))


# ---------------------------------------------------------------------------

func _test_camp_reveal() -> void:
	_check("reveal count: ends exact, ceil between",
		CampAreaRuntime.revealed_count(10, 0.0) == 0 and CampAreaRuntime.revealed_count(10, 1.0) == 10
		and CampAreaRuntime.revealed_count(10, 0.01) == 1 and CampAreaRuntime.revealed_count(10, 0.55) == 6
		and CampAreaRuntime.revealed_count(0, 0.5) == 0)
	# A camp record carries `built`, default true, through the layer.
	var layer := CampAreaLayer.create_empty()
	var poly := PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(40, 40), Vector2(0, 40)])
	var id := layer.add(poly, {"name": "Reveal test"})
	_check("a new camp is built", bool(layer.get_area(id).get("built", false)))
	layer.update(id, {"built": false})
	var back := CampAreaLayer.create_empty()
	back.deserialize(JSON.parse_string(JSON.stringify(layer.serialize())))
	_check("built = false survives the file", back.get_area(id).has("built") and not bool(back.get_area(id)["built"]))
	var legacy := CampAreaLayer.create_empty()
	legacy.deserialize({"version": 1, "next_id": 2, "areas": [{"id": "camp_1", "name": "Old",
		"polygon": [[0, 0], [30, 0], [30, 30], [0, 30]]}]})
	_check("a record without the key reads built", bool(legacy.get_area("camp_1").get("built", false)))
