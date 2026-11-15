extends RefCounted

## Meals as small crew jobs on a real world (sandbox; Closed Loop Ten: ten
## people, a Kitchen node bound to an EZ-up, the 32-serving camp recipe):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/meal_job_check.gd -Label meal_job -Timeout 1500
## The rota names the day's cooks; the meal counter is run down so the
## kitchen starts a batch; its prep step becomes a chore for three at the
## kitchen with the cooks getting first refusal; while they work it the
## KitchenSite draws them at the stations (their own bodies stood in), with
## the kitchen's tools in hand, the drawn time following their credited
## labour; the step completes; then the serve step (plating, washing up).
## Shots of each.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("mealcheck %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(main: Node, tree: SceneTree, name: String, at: Vector3, look: Vector3) -> void:
	var cam := Camera3D.new()
	cam.fov = 55.0
	main.add_child(cam)
	cam.global_position = at
	cam.look_at(look, Vector3.UP)
	main.call("push_camera_claim", "meal_check", {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})
	await _wait(tree, 0.6)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	main.call("pop_camera_claim", "meal_check")
	cam.queue_free()
	await _frames(tree, 2)


func _chore(b: Object, gid: String, step: String) -> Dictionary:
	for iid in b.call("pop_driven_item_ids"):
		var board: Object = b.call("chore_board_for", str(iid))
		if board == null:
			continue
		var c: Dictionary = board.call("find_by_key", "mach|%s|%s" % [gid, step])
		if not c.is_empty():
			return c
	return {}


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	main.set("day_time", 9.5)
	main.set("time_scale", 30.0 / 3600.0)
	var gv := ServiceLocator.graph()
	var model: Object = gv.get("model")
	var b: Object = gv.call("npc_population_bridge")
	var t0 := Time.get_ticks_msec()
	while (b == null or (b.call("pop_driven_item_ids") as Array).is_empty()) and Time.get_ticks_msec() - t0 < 60000:
		await _frames(tree, 10)
		b = gv.call("npc_population_bridge")
	_ok(b != null and not (b.call("pop_driven_item_ids") as Array).is_empty(), "a simulated camp")
	if b == null:
		return {"ok": false, "fails": _fails}
	await _frames(tree, 20)
	# The kitchen and its 3D twin.
	var gid := ""
	var meals_id := ""
	for it in model.get("items"):
		var sp: Dictionary = (it as Dictionary).get("specs", {})
		if str(sp.get("role", "")) == "kitchen":
			gid = str((it as Dictionary)["id"])
		if str((it as Dictionary).get("id", "")) == "meals" or str(sp.get("name", "")).begins_with("Meal Counter"):
			meals_id = str((it as Dictionary)["id"])
	_ok(not gid.is_empty() and not meals_id.is_empty(), "a kitchen (%s) and its meal counter (%s)" % [gid, meals_id])
	var kspecs: Dictionary = (model.call("get_item", gid) as Dictionary).get("specs", {})
	var prop_id := str(kspecs.get("bound_prop_id", ""))
	var prop: Node3D = PlacedPropRuntime.find_by_prop_id(main, prop_id) as Node3D
	var site: Node = prop.get_node_or_null(KitchenSite.NODE_NAME) if prop != null else null
	_ok(site != null, "the kitchen's twin carries a KitchenSite")
	var info := MealJobPlan.recipe_info(kspecs)
	print("mealcheck: recipe %s servings, %s crew hours, steps %s" % [str(info["servings"]), str(info["hours"]),
		str((info["steps"] as Array).map(func(s): return "%s(%s)" % [s["id"], s["kind"]]))])
	# The rota plans the day's cooking.
	var hab := str((b.call("pop_driven_item_ids") as Array)[0])
	b.call("replan_rota", hab)
	var cooks: Array = b.call("kitchen_cooks", gid, float(main.call("get_absolute_hours")))
	_ok(cooks.size() == MealJobPlan.crew_for(float(info["servings"])),
		"the rota names the day's cooks (%s)" % str(cooks))

	# Crew steps need HANDS only with finite labour (the difficulty switch):
	# this world pays them from the abstract pool. Switched in the sandbox.
	var rf: Object = gv.get("_resource_flow")
	var ledger: Object = rf.get("chore_ledger") if rf != null else null
	if ledger != null:
		print("mealcheck: the world's labour is %s; set to finite for the check" % ("infinite" if bool(ledger.get("infinite_labor")) else "finite"))
		ledger.set("infinite_labor", false)
		print("mealcheck: the pool held %.1f h; emptied" % float(ledger.get("chore_hours_available")))
		ledger.set("chore_hours_available", 0.0)
	# Run the counter down: the kitchen's own automation keeps cooking.
	var ms: Dictionary = ((model.call("get_item", meals_id) as Dictionary)["specs"] as Dictionary).duplicate()
	ms["level"] = 0.05
	model.call("update_item", meals_id, {"specs": ms})
	var tl: Object = rf.call("get_timeline", meals_id) if rf != null else null
	if tl != null:
		tl.call("set_current_level", float(main.call("get_absolute_hours")), 0.05)
	var seen_kinds := {}
	var shot_n := 0
	for round_i in 2:
		# Whichever meal step needs hands next.
		var ch: Dictionary = {}
		var step: Dictionary = {}
		main.set("time_scale", 120.0 / 3600.0)
		t0 = Time.get_ticks_msec()
		var kicked := false
		while ch.is_empty() and Time.get_ticks_msec() - t0 < 300000:
			await _wait(tree, 0.5)
			# The world's automation turns the kitchen on when the counter
			# CROSSES 60 %; already under it, nothing starts the next batch.
			var ksp: Dictionary = (model.call("get_item", gid) as Dictionary).get("specs", {})
			if round_i > 0 and not kicked and not bool(ksp.get("recipe_running", false)):
				kicked = true
				print("mealcheck: starting the next batch (the recipe's Start)")
				gv.call("start_process_recipe", gid)
			for s2 in info["steps"]:
				if seen_kinds.has(str(s2["kind"])):
					continue
				ch = _chore(b, gid, str(s2["id"]))
				if not ch.is_empty():
					step = s2
					break
		_ok(not ch.is_empty(), "round %d: a meal step became a chore at the kitchen (%s)" % [round_i + 1, str(ch.get("label", ""))])
		if ch.is_empty():
			break
		var kind := str(step["kind"])
		seen_kinds[kind] = true
		_ok(int(ch.get("max_workers", 0)) == MealJobPlan.crew_for(float(info["servings"])),
			"%s: a crew of %d may work it" % [kind, int(ch.get("max_workers", 0))])
		_ok((ch.get("assigned_crew", []) as Array) == cooks, "%s: the day's cooks get first refusal" % kind)
		_ok(str((ch.get("target", {}) as Dictionary).get("id", "")) == prop_id, "%s: at the kitchen's twin" % kind)
		main.set("time_scale", 30.0 / 3600.0)
		var max_manned := 0
		var stood := false
		var tool_seen := ""
		var prog0 := -1.0
		var prog_rise := false
		var shot_done := false
		var labels := {}
		t0 = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 420000:
			await _wait(tree, 0.25)
			var live := _chore(b, gid, str(step["id"]))
			if live.is_empty() or int(live.get("done_day", -1)) >= 0:
				break
			if int((Time.get_ticks_msec() - t0) / 250) % 80 == 0:
				print("mealcheck: %s %.0f %% left · workers %s · worked %s" % [kind,
					100.0 * (1.0 - float(live.get("progress_h", 0.0)) / maxf(float(live.get("chore_hours", 1.0)), 1e-6)) if live.has("progress_h") else -1.0,
					str(live.get("workers", [])), str(live.get("rota_worked", {}))])
			var st: Dictionary = site.call("status")
			if not bool(st.get("found", false)):
				continue
			var p := float(st.get("progress", 0.0))
			if prog0 < 0.0:
				prog0 = p
			elif p > prog0 + 0.05:
				prog_rise = true
			var m := int(site.call("manned_count"))
			max_manned = maxi(max_manned, m)
			for pr in st.get("present", []):
				if NpcStandIns.has(str(pr["id"])):
					stood = true
			for c in site.find_children("FabTool_*", "Node3D", false, false):
				if (c as Node3D).visible:
					tool_seen = str(c.get_meta("tool_id", ""))
			for l in CrewJobPlan.state_at(site.call("timeline"), float(site.call("display_time"))).get("current", []):
				labels[str(l)] = true
			if m >= 1 and not tool_seen.is_empty() and not shot_done:
				shot_done = true
				var dup := 0
				for lb in main.find_children("*", "Label3D", true, false):
					var on_marker := str(lb.get_parent().name).begins_with("CrewSiteMarker")
					if on_marker and (lb as Label3D).is_visible_in_tree() \
							and (lb as Label3D).text.contains(str(ch.get("label", "#"))):
						dup += 1
				_ok(dup == 0, "%s: only the kitchen's own label, no crew-site marker over it (%d)" % [kind, dup])
				main.set("time_scale", 0.0)
				var c3 := (site as Node3D).global_position
				var basis := (site as Node3D).global_transform.basis
				shot_n += 1
				await _shot(main, tree, "%02d_%s_front" % [shot_n, kind], c3 + basis * Vector3(0.6, 2.4, 3.6), c3 + basis * Vector3(-0.2, 0.9, -0.3))
				shot_n += 1
				await _shot(main, tree, "%02d_%s_close" % [shot_n, kind], c3 + basis * Vector3(0.3, 1.6, 1.6), c3 + basis * Vector3(0.0, 0.9, -0.5))
				# Seen it drawn: let the crew finish at a faster clock.
				main.set("time_scale", 120.0 / 3600.0)
		_ok(max_manned >= 1, "%s: cooks drawn at the kitchen while they work (up to %d at once)" % [kind, max_manned])
		_ok(stood, "%s: their own bodies are stood in while drawn there" % kind)
		_ok(not tool_seen.is_empty(), "%s: a kitchen tool in hand (%s)" % [kind, tool_seen])
		_ok(prog_rise, "%s: the drawn meal follows their labour (from %.0f %%)" % [kind, prog0 * 100.0])
		print("mealcheck: %s jobs seen %s" % [kind, str(labels.keys())])
		_ok(labels.size() >= 2, "%s: more than one kind of job seen" % kind)
		var fin := _chore(b, gid, str(step["id"]))
		_ok(fin.is_empty() or int(fin.get("done_day", -1)) >= 0, "%s: the step was finished by the crew" % kind)
		var cards := 0
		for n in main.find_children("*", "Label", true, false):
			if (n as Label).is_visible_in_tree() and (n as Label).text.begins_with(str(ch.get("label", "#")) + " ("):
				cards += 1
		_ok(cards <= 1, "%s: one confirm card, not one per tick (%d)" % [kind, cards])
	main.set("time_scale", 0.0)
	return {"ok": _fails.is_empty(), "fails": _fails}
