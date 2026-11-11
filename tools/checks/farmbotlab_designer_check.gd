extends RefCounted

## The FarmBot designer on a REAL world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/farmbotlab_designer_check.gd -Label farmbotlab
## Opens the designer through Main, clicks every built-in in the gallery (a
## shot of each), runs UiAudit, adds a crop with a REAL click, switches the
## packing, plays a watering job with a REAL click on Play (the gantry moves,
## the nozzle waters), scrubs, shoots the plan view; then places a bed through
## the graph's own placement (a food node bound, FarmBotRuntime attached), sets
## the world clock to a watering time on a steady day and checks the robot is
## where its schedule says, that it moves on and comes back on a scrub back,
## and Applies a longer bed from the designer bound to it.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("farmbotlab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shoot(main: Node, path: String) -> void:
	main.get_viewport().get_texture().get_image().save_png(path)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	_ok(main.has_method("open_farmbotlab"), "Main hosts the designer")
	var ui: Control = main.call("open_farmbotlab", {})
	await _settle(tree, 20)
	_ok(ui != null and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false, "fails": _fails}
	var studio: StudioViewport = ui.call("studio")
	# --- Every built-in through a REAL click on its gallery row.
	var gallery: DesignGallery = ui.get("_gallery")
	for i in FarmBotPresets.ORDER.size():
		var id := str(FarmBotPresets.ORDER[i])
		var btn := gallery.row_button(i)
		if btn == null:
			_ok(false, "%s has a gallery row" % id)
			continue
		await HarnessInput.click(vp, HarnessInput.center_of(btn))
		await _settle(tree, 14)
		var s: Dictionary = ui.call("spec")
		_ok(str(s["name"]) == str(FarmBotPresets.spec(id)["name"]), "a click on %s loads it" % id)
		var d: Dictionary = ui.call("design")
		print("farmbotlab: %s — %d plants, %.2f h robot a day, %.0f h saved a year, payback %.1f years" % [id,
			int(d["layout"]["total"]), float(d["robot"]["busy_h_day"]), float(d["money"]["saved_h_year"]),
			float(d["money"]["payback_years"])])
		studio.viewport.get_texture().get_image().save_png("%s/studio_%s.png" % [dir, id])
	await HarnessInput.click(vp, HarnessInput.center_of(gallery.row_button(1)))
	await _settle(tree, 14)
	_shoot(main, "%s/modal.png" % dir)
	var audit := UiAudit.run(vp)
	print("farmbotlab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	# --- Add a crop with a real click.
	var n0 := ((ui.call("spec") as Dictionary)["crops"]["mix"] as Array).size()
	var add := HarnessInput.find_button_revealing(ui, "Add a crop")
	await _settle(tree, 2)
	_ok(add != null, "the Add a crop button")
	if add != null:
		var sc := add.get_parent()
		while sc != null and not (sc is ScrollContainer):
			sc = sc.get_parent()
		if sc != null:
			(sc as ScrollContainer).ensure_control_visible(add)
			await _settle(tree, 3)
		await HarnessInput.click(vp, HarnessInput.center_of(add))
		await _settle(tree, 10)
		_ok(((ui.call("spec") as Dictionary)["crops"]["mix"] as Array).size() == n0 + 1, "a click on Add a crop adds one")
	# --- Packing: square holds fewer than hex.
	var hex_n := int((ui.call("design") as Dictionary)["layout"]["total"])
	ui.call("edit", "crops", "packing", "square")
	await _settle(tree, 6)
	var sq_n := int((ui.call("design") as Dictionary)["layout"]["total"])
	_ok(sq_n <= hex_n, "square packing holds no more plants than hex (%d vs %d hex)" % [sq_n, hex_n])
	ui.call("edit", "crops", "packing", "hex")
	await _settle(tree, 6)
	# --- Play a watering job with a real click.
	var job_opt: OptionButton = ui.get("_job_opt")
	var job0: Dictionary = ui.call("job")
	_ok(str(job0.get("id", "")).begins_with("water"), "the day opens on the morning watering (%s)" % str(job0.get("label", "")))
	var b: FarmBotBuilder = ui.call("builder")
	var g0 := b.gantry.position
	var play: Button = ui.get("_play_btn")
	ui.get("_speed_opt").select(3)
	ui.set("_speed", 300.0)
	await HarnessInput.click(vp, HarnessInput.center_of(play))
	await _settle(tree, 40)
	var t1 := float(ui.call("play_time"))
	_ok(t1 > 1.0, "Play runs the job (%.0f s in)" % t1)
	b = ui.call("builder")
	_ok(not b.gantry.position.is_equal_approx(g0) or not b.cross.position.is_equal_approx(Vector3.ZERO), "the gantry moved")
	await HarnessInput.click(vp, HarnessInput.center_of(play))
	await _settle(tree, 4)
	var t2 := float(ui.call("play_time"))
	await _settle(tree, 10)
	_ok(is_equal_approx(t2, float(ui.call("play_time"))), "Play again pauses")
	# A watering dwell: the nozzle sprays at a plant.
	var aj: Dictionary = ui.call("arm_job", 0)
	var segs: Array = aj["segs"]
	var t_in := -1.0
	for sv in segs:
		if str((sv as Dictionary)["act"]) == "water":
			t_in = float(sv["t0"]) + 0.2
			break
	var tw := float(aj["start_s"]) - float(job0["start_s"]) + t_in
	ui.call("set_play_time", tw)
	await _settle(tree, 4)
	b = ui.call("builder")
	_ok(t_in > 0.0 and b.spray.visible and b.mounted == "watering", "mid-dwell the nozzle is mounted and spraying")
	var want: Vector3 = FarmBotJobs.sample_job(aj, t_in)["pos"]
	_ok(b.machine_pos.is_equal_approx(want), "the robot stands where the job says")
	studio.viewport.get_texture().get_image().save_png("%s/watering.png" % dir)
	ui.call("set_tab", 1)
	await _settle(tree, 6)
	_shoot(main, "%s/plan.png" % dir)
	ui.call("set_tab", 0)
	# The whole day option.
	job_opt.select(job_opt.item_count - 1)
	job_opt.item_selected.emit(job_opt.item_count - 1)
	await _settle(tree, 4)
	_ok(str((ui.call("job") as Dictionary).get("id", "")) == "day", "the whole day can be played")
	ui.call("close")
	await _settle(tree, 4)
	_ok(not bool(ui.call("is_open")), "the designer closes")
	# --- Placed through the graph's own placement.
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	var model: GraphModel = sgv.get("model") if sgv != null else null
	_ok(sgv != null and model != null, "the systems graph")
	if sgv == null:
		return {"ok": _fails.is_empty(), "fails": _fails}
	main.set("time_scale", 1.0 / 3600.0)
	var player := ServiceLocator.player() as Node3D
	var at := player.global_position + Vector3(9.0, 0.0, 9.0) if player != null else Vector3(9.0, 0.0, 9.0)
	var before := _prop_ids(main)
	var spec := FarmBotPresets.spec("genesis_xl")
	var preset := ComponentPresets.designed_farmbot_preset(spec)
	sgv.call("_on_lib_place_model_requested", preset, "", at)
	await _settle(tree, 60)
	var pid := _new_prop(main, before)
	_ok(not pid.is_empty(), "the bed is placed (%s)" % pid)
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(str(rec.get("kind", "")) == "farmbot" and not (rec.get("farmbot_spec", {}) as Dictionary).is_empty(), "its record carries the design")
	var item := model.get_item(str(rec.get("graph_item_id", "")))
	_ok(str(item.get("type", "")) == "plant" and is_equal_approx(float((item.get("specs", {}) as Dictionary).get("area_m2", 0.0)), 18.0),
		"a food node of the bed's 18 m², bound")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	var rt := FarmBotRuntime.of(prop)
	_ok(rt != null, "FarmBotRuntime runs it")
	await _settle(tree, 4)
	var planted := float(rec.get("plant_abs_h", -1.0))
	_ok(planted > 0.0, "it knows when it was planted")
	# A steady day, five minutes into the morning watering; the clock held
	# still so each sample is one instant.
	main.set("time_scale", 0.0)
	var day := 130
	var abs7 := floorf(planted / 24.0) * 24.0 + 24.0 * float(day) + 7.0 + 5.0 / 60.0
	main.call("set_absolute_hours", abs7)
	await _settle(tree, 6)
	var rb: FarmBotBuilder = rt.builder() if rt != null else null
	var plan := FarmBotJobs.day_plan(rb.spec, rb.design["layout"], day, true) if rb != null else {}
	var want2: Dictionary = FarmBotJobs.sample_day(plan, fposmod(float(main.call("get_absolute_hours")), 24.0) * 3600.0) if rb != null else {}
	_ok(rb != null and bool(rt.state.get("busy", false)) and str(rt.state.get("job", "")).begins_with("water"),
		"at 07:05 on day %d it is watering (%s)" % [day, str(rt.state.get("act", "?"))])
	_ok(rb != null and rb.machine_pos.distance_to(want2.get("pos", Vector3.INF)) < 1.0, "and stands where its schedule says")
	var p1 := rb.machine_pos if rb != null else Vector3.ZERO
	await _world_shot(main, tree, prop, Vector3(3.5, 7.0, 6.5), Vector3(0, 0.5, 0), "%s/world_watering.png" % dir)
	main.call("set_absolute_hours", abs7 + 0.25)
	await _settle(tree, 6)
	_ok(rb != null and not rb.machine_pos.is_equal_approx(p1), "a quarter of an hour on it has moved on")
	main.call("set_absolute_hours", abs7)
	await _settle(tree, 6)
	_ok(rb != null and rb.machine_pos.distance_to(p1) < 0.5, "scrubbed back it is where it was")
	main.call("set_absolute_hours", floorf(planted / 24.0) * 24.0 + 24.0 * float(day) + 16.0)
	await _settle(tree, 6)
	_ok(not bool(rt.state.get("busy", true)), "at 16:00, between jobs, it waits over its tool bay")
	await _world_shot(main, tree, prop, Vector3(-4.0, 6.0, 5.5), Vector3(0, 0.5, 0), "%s/world_parked.png" % dir)
	# --- Apply a longer bed from the designer bound to it.
	ui = main.call("open_farmbotlab", {"prop_id": pid})
	await _settle(tree, 16)
	ui.call("edit", "bed", "length_m", 8.0)
	await _settle(tree, 6)
	ui.call("_on_apply")
	await _settle(tree, 40)
	var rec2 := PlacedPropService.get_prop_record(main, pid)
	_ok(is_equal_approx(float((rec2.get("farmbot_spec", {}) as Dictionary).get("bed", {}).get("length_m", 0.0)), 8.0), "Apply writes the longer bed")
	var item2 := model.get_item(str(rec2.get("graph_item_id", "")))
	_ok(is_equal_approx(float((item2.get("specs", {}) as Dictionary).get("area_m2", 0.0)), 24.0), "and the food node grows to 24 m²")
	var rt2 := FarmBotRuntime.of(PlacedPropRuntime.find_by_prop_id(main, pid))
	await _settle(tree, 6)
	_ok(rt2 != null and rt2.builder() != null and is_equal_approx(float(rt2.builder().spec["bed"]["length_m"]), 8.0), "the placed robot is rebuilt to it")
	await _radial(main, harness, dir, sgv, model)
	return {"ok": _fails.is_empty(), "fails": _fails}


## The radial arm over a keyhole bed: the robot type picked in the modal, the
## 20 m greenhouse preset by a real click, its three arms played together, a
## placed one working its schedule in the world.
func _radial(main: Node, _harness: Node, dir: String, sgv: Node, model: GraphModel) -> void:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var ui: Control = main.call("open_farmbotlab", {})
	await _settle(tree, 16)
	var kind_opt := ui.find_child("__kind", true, false) as OptionButton
	_ok(kind_opt != null, "the Robot row")
	if kind_opt != null:
		kind_opt.select(1)
		kind_opt.item_selected.emit(1)
		await _settle(tree, 12)
	var s0: Dictionary = ui.call("spec")
	_ok(str(s0["kind"]) == "radial", "choosing Radial arm makes a keyhole robot")
	var arms_row := ui.find_child("keyhole_arms", true, false)
	var len_row := ui.find_child("bed_length_m", true, false)
	_ok(arms_row != null and (arms_row.get_parent() as Control).is_visible_in_tree() and len_row != null \
		and not (len_row.get_parent() as Control).visible, "the keyhole's rows show, the straight bed's hide")
	var gallery: DesignGallery = ui.get("_gallery")
	var idx := FarmBotPresets.ORDER.find("keyhole_dome_20m")
	var btn := gallery.row_button(idx)
	await HarnessInput.click(vp, HarnessInput.center_of(btn))
	await _settle(tree, 20)
	var d: Dictionary = ui.call("design")
	var b: FarmBotBuilder = ui.call("builder")
	_ok(str(d["spec"]["name"]) == "Keyhole greenhouse (20 m dome)" and b.arms.size() == 3, "a click on the 20 m keyhole: three arms")
	print("farmbotlab: keyhole — %d plants, %.1f h a day (%.1f h busiest), %.1f arm-hours, %.0f h saved a year, kit $%.0f, payback %.1f years" % [
		int(d["layout"]["total"]), float(d["robot"]["busy_h_day"]), float(d["robot"]["max_busy_h"]),
		float(d["robot"]["arm_h_day"]), float(d["money"]["saved_h_year"]), float(d["money"]["kit_usd"]),
		float(d["money"]["payback_years"])])
	var studio: StudioViewport = ui.call("studio")
	studio.viewport.get_texture().get_image().save_png("%s/keyhole_studio.png" % dir)
	_shoot(main, "%s/keyhole_modal.png" % dir)
	var audit := UiAudit.run(vp)
	_ok(int(audit.get("errors", 0)) == 0, "the radial modal has no UI audit errors (%s)" % UiAudit.summary_line(audit))
	var job: Dictionary = ui.call("job")
	_ok(str(job.get("id", "")).begins_with("water"), "it opens on the morning watering")
	var before: Array = []
	for e in b.arms:
		before.append(((e as Dictionary)["node"] as Node3D).rotation.y)
	ui.get("_speed_opt").select(3)
	ui.set("_speed", 300.0)
	var play: Button = ui.get("_play_btn")
	await HarnessInput.click(vp, HarnessInput.center_of(play))
	await _settle(tree, 50)
	await HarnessInput.click(vp, HarnessInput.center_of(play))
	await _settle(tree, 4)
	var moved := 0
	for i in b.arms.size():
		if absf(((b.arms[i] as Dictionary)["node"] as Node3D).rotation.y - float(before[i])) > 1e-4:
			moved += 1
	_ok(moved == 3, "playing, all three arms turn (%d of 3)" % moved)
	var plan: Dictionary = ui.call("plan")
	var ts := float(job["start_s"]) + float(ui.call("play_time"))
	var all := FarmBotJobs.sample_arms(plan, ts)
	var at_ok := true
	for i2 in all.size():
		if ((b.arms[i2] as Dictionary)["pos"] as Vector3).distance_to((all[i2] as Dictionary)["pos"]) > 0.5:
			at_ok = false
	_ok(at_ok, "every arm stands where its own schedule says")
	studio.viewport.get_texture().get_image().save_png("%s/keyhole_playing.png" % dir)
	ui.call("set_tab", 1)
	await _settle(tree, 6)
	_shoot(main, "%s/keyhole_plan.png" % dir)
	ui.call("close")
	await _settle(tree, 4)
	# --- A keyhole robot in the world.
	main.set("time_scale", 0.0)
	var player := ServiceLocator.player() as Node3D
	var at := player.global_position + Vector3(-30.0, 0.0, 30.0) if player != null else Vector3(-30.0, 0.0, 30.0)
	var ids0 := _prop_ids(main)
	var preset := ComponentPresets.designed_farmbot_preset(FarmBotPresets.spec("keyhole_dome_20m"))
	sgv.call("_on_lib_place_model_requested", preset, "", at)
	await _settle(tree, 60)
	var pid := _new_prop(main, ids0)
	_ok(not pid.is_empty(), "the keyhole robot is placed")
	var rec := PlacedPropService.get_prop_record(main, pid)
	var item := model.get_item(str(rec.get("graph_item_id", "")))
	_ok(absf(float((item.get("specs", {}) as Dictionary).get("area_m2", 0.0)) - GrowBed.layout_area_m2({"layout": "keyhole"})) < 0.01,
		"its food node is the keyhole's %.1f m²" % float((item.get("specs", {}) as Dictionary).get("area_m2", 0.0)))
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	var rt := FarmBotRuntime.of(prop)
	await _settle(tree, 4)
	var planted := float(rec.get("plant_abs_h", -1.0))
	var day := 130
	var abs7 := floorf(planted / 24.0) * 24.0 + 24.0 * float(day) + 7.0 + 20.0 / 60.0
	main.call("set_absolute_hours", abs7)
	await _settle(tree, 6)
	var rb: FarmBotBuilder = rt.builder() if rt != null else null
	_ok(rb != null and rb.arms.size() == 3, "the placed robot has its three arms")
	if rb == null:
		return
	var p2 := FarmBotJobs.day_plan(rb.spec, rb.design["layout"], day, true)
	var want := FarmBotJobs.sample_arms(p2, fposmod(float(main.call("get_absolute_hours")), 24.0) * 3600.0)
	var busy := 0
	var placed_ok := true
	for i3 in want.size():
		if bool((want[i3] as Dictionary)["busy"]):
			busy += 1
		if ((rb.arms[i3] as Dictionary)["pos"] as Vector3).distance_to((want[i3] as Dictionary)["pos"]) > 1.0:
			placed_ok = false
	_ok(busy == 3 and placed_ok, "at 07:20 on day %d all three arms water, each where its schedule says (%d busy)" % [day, busy])
	await _world_shot(main, tree, prop, Vector3(6.0, 14.0, 16.0), Vector3(0, 0.5, 0), "%s/world_keyhole.png" % dir)


func _prop_ids(main: Node) -> Dictionary:
	var out := {}
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("placed_prop_records"):
		for r in loader.call("placed_prop_records"):
			out[str((r as Dictionary).get("id", ""))] = true
	return out


func _new_prop(main: Node, before: Dictionary) -> String:
	var now := _prop_ids(main)
	for id in now:
		if not before.has(id):
			return str(id)
	return ""


func _world_shot(main: Node, tree: SceneTree, prop: Node3D, off: Vector3, look: Vector3, path: String) -> void:
	if prop == null:
		return
	var cam := Camera3D.new()
	main.add_child(cam)
	var a: Vector3 = prop.global_position
	cam.look_at_from_position(a + off, a + look, Vector3.UP)
	main.call("push_camera_claim", "farmbot_check", {"camera_id": cam.get_instance_id()})
	await _settle(tree, 30)
	_shoot(main, path)
	main.call("pop_camera_claim", "farmbot_check")
	cam.queue_free()
