extends RefCounted

## The closed-loop world, watched (sandbox ONLY, never -Persist): builds the
## design into the world (tools/fixes/closed_loop_world.gd), then lets the
## clock run and checks what the player is meant to see: the vehicles drive in
## through the gate and park, the people arrive with them, the deploy event
## fires, the crew carries the kits out of the container and builds every one,
## and afterwards the machines run and chores get done.
##
##   $env:SYSDESIGN = "bombay_ten"
##   tools\harness.ps1 -World <world id> -RunScript res://tools/checks/closed_loop_world_check.gd -Label closed_loop_world -Timeout 2400
##
## CLW_HOURS = sim hours to watch after the deploy (default 30).

const Build := preload("res://tools/fixes/closed_loop_world.gd")

var _fails := 0
var _dir := "user://screenshots/closed_loop_world"


func _ok(cond: bool, what: String) -> void:
	print("closed-loop-world %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	img.save_png("%s/%s.png" % [_dir, name])


func _aim(main: Node, at: Vector2, h: float) -> void:
	var view: Variant = main.get("settlement_view")
	var cam: Variant = view.get("_cam") if view != null else null
	if cam == null:
		return
	cam.set("_h_target", h)
	cam.set("_h", h)
	cam.set("focus", at)
	cam.set("_focus_target", at)


func _packed_left(loader: Node) -> int:
	var n := 0
	for r in (loader.call("placed_prop_records") as Array):
		var rec: Dictionary = r
		if bool(rec.get("sysdesign", false)) and bool(rec.get("packed", false)):
			n += 1
	return n


func _vehicle_states(main: Node, loader: Node) -> Dictionary:
	var out := {"away": 0, "driving": 0, "parked": 0}
	var now := float(main.call("get_absolute_hours"))
	for r in (loader.call("placed_prop_records") as Array):
		var rec: Dictionary = r
		if not VehicleBuilder.handles(str(rec.get("model_id", ""))):
			continue
		var st := "parked"
		if rec.get("arrival") is Dictionary:
			st = str(VehicleDrive.pose_at(rec["arrival"], now).get("state", "parked"))
		out[st] = int(out.get(st, 0)) + 1
	return out


func run(main: Node, harness: Node) -> Dictionary:
	if harness != null and not str(harness.get("_shots_label")).is_empty():
		_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	var b := Build.new()
	var res: Dictionary = await b.run(main, harness)
	_ok(bool(res.get("ok", false)), "the world was built (%d kits, %d stowed, %d vehicles)" % [
		int(res.get("kits", 0)), int(res.get("stowed", 0)), int(res.get("vehicles", 0))])
	if not bool(res.get("ok", false)):
		return {"ok": false}
	var tree := main.get_tree()
	var sgv: Node = ServiceLocator.graph()
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var bridge: Object = sgv.call("npc_population_bridge")
	var sd: Object = sgv.call("site_deploy")
	var model: GraphModel = sgv.get("model")
	var t0 := float(res["t0"])
	var deploy_h := float(res["deploy_h"])
	var hab_id := "hab"
	var centre: Vector2 = SiteCentre.xz(main)
	var kits0 := _packed_left(loader)
	_ok(kits0 >= int(res.get("kits", 0)) - 1, "%d kits are packed at the start" % kits0)
	var v0 := _vehicle_states(main, loader)
	_ok(int(v0["away"]) == int(res.get("vehicles", 0)), "every vehicle is still on its way at the start (%s)" % str(v0))
	var s0: Dictionary = bridge.call("summary_for", hab_id)
	print("closed-loop-world: start people summary count=%s away=%s" % [str(s0.get("count", "?")),
		str(bridge.call("is_away", hab_id)) if bridge.has_method("is_away") else "?"])

	if main.has_method("open_settlement_view"):
		main.call("open_settlement_view", centre + Vector2(0, 30), 160.0)
		await tree.create_timer(1.0).timeout
	_aim(main, centre + Vector2(0, 40), 170.0)
	await _shot(main, "00_before_arrival")

	# Drive in: a sim minute a second.
	main.set("time_scale", 1.0 / 60.0)
	var saw_driving := false
	var t_wall := 0.0
	while float(main.call("get_absolute_hours")) < deploy_h - 0.02 and t_wall < 240.0:
		await tree.create_timer(0.5).timeout
		t_wall += 0.5
		var vs := _vehicle_states(main, loader)
		if int(vs["driving"]) > 0 and not saw_driving:
			saw_driving = true
			_aim(main, centre + Vector2(0, 60), 120.0)
			await _shot(main, "01_driving_in")
	_ok(saw_driving, "vehicles were seen on the road in")
	var v1 := _vehicle_states(main, loader)
	_ok(int(v1["parked"]) == int(res.get("vehicles", 0)), "every vehicle parked before the deploy (%s)" % str(v1))
	_aim(main, centre + Vector2(0, 0), 90.0)
	await _shot(main, "02_parked")

	# The deploy: faster clock, watch the kits go up.
	main.set("time_scale", 0.05)
	var fired := false
	var built_at := -1.0
	var half_shot := false
	t_wall = 0.0
	var last_print := -1.0
	while t_wall < 900.0:
		await tree.create_timer(1.0).timeout
		t_wall += 1.0
		var now := float(main.call("get_absolute_hours"))
		var left := _packed_left(loader)
		if not fired and now > deploy_h:
			fired = true
		if now - last_print >= 1.0:
			last_print = now
			var st: Dictionary = sd.call("status")
			var sm: Dictionary = bridge.call("summary_for", hab_id)
			print("closed-loop-world: +%.1f h  kits left %d  deploy %s  people %s  acts %s" % [now - t0, left,
				str(st.get("line", "")), str(sm.get("count", "?")), str(sm.get("activities", {}))])
		if not half_shot and left * 2 <= kits0:
			half_shot = true
			_aim(main, centre + Vector2(0, 10), 110.0)
			await _shot(main, "03_half_built")
		if left == 0 and not bool((sd.call("status") as Dictionary).get("active", false)):
			built_at = now
			break
		if now - deploy_h > 60.0:
			break
	_ok(fired, "the clock crossed the deploy event")
	_ok(built_at > 0.0, "every kit was built by the crew (%.1f h after the deploy; %d left)" % [
		built_at - deploy_h, _packed_left(loader)])
	_aim(main, centre + Vector2(0, 10), 130.0)
	await _shot(main, "04_built")
	var sm1: Dictionary = bridge.call("summary_for", hab_id)
	_ok(int(sm1.get("count", 0)) == 10, "ten people are on site (%s)" % str(sm1.get("count", "?")))

	# Life after the build.
	var watch_h := 30.0
	if not OS.get_environment("CLW_HOURS").is_empty():
		watch_h = float(OS.get_environment("CLW_HOURS"))
	var t_end := float(main.call("get_absolute_hours")) + watch_h
	main.set("time_scale", 0.1)
	var ran := {}
	var chores_done := 0
	t_wall = 0.0
	while float(main.call("get_absolute_hours")) < t_end and t_wall < 900.0:
		await tree.create_timer(1.0).timeout
		t_wall += 1.0
		for it: Dictionary in model.items_of_type("processor"):
			var sp: Dictionary = it.get("specs", {})
			if str(sp.get("node_state", "")) == GraphNodeState.RUNNING:
				ran[str(sp.get("sysdesign_id", it.get("id", "")))] = true
	var board: Object = bridge.call("chore_board_for", hab_id)
	if board != null:
		for ch in (board.get("chores") as Array):
			if int((ch as Dictionary).get("done_day", -1)) >= 0:
				chores_done += 1
	for dump_id in ["kitchen", "reactor", "shredder"]:
		var dsp: Dictionary = model.get_item(dump_id).get("specs", {})
		var keep := {}
		for k in dsp.keys():
			var ks := str(k)
			if (ks.begins_with("recipe_") and ks != "recipe_def") or ks.begins_with("node_state") 					or ks in ["requested_state", "current_state", "packed_3d", "bound_prop_id"]:
				keep[ks] = dsp[k]
		print("closed-loop-world: %s %s" % [dump_id, JSON.stringify(keep).substr(0, 700)])
	if board != null:
		for ch2 in (board.get("chores") as Array):
			var cd: Dictionary = ch2
			if int(cd.get("done_day", -1)) < 0:
				print("closed-loop-world: open chore: %s key=%s" % [str(cd.get("label", "")), str(cd.get("chore_key", ""))])
	print("closed-loop-world: nodes seen running: ", ran.keys())
	for want in ["gh", "kitchen", "gfilter", "compost"]:
		_ok(ran.has(want), "%s ran after the build" % want)
	_ok(chores_done >= 2, "%d chores on the board were finished" % chores_done)
	var sm2: Dictionary = bridge.call("summary_for", hab_id)
	_ok(int(sm2.get("count", 0)) == 10 and float(sm2.get("mean_morale", 0.0)) > 0.5,
		"a day later: %s people, morale %.2f" % [str(sm2.get("count", "?")), float(sm2.get("mean_morale", 0.0))])
	for it2: Dictionary in model.items_of_type("resource"):
		var tsp: Dictionary = it2.get("specs", {})
		if str(tsp.get("sysdesign_id", "")) in ["cistern", "food", "meals", "black", "grey"]:
			print("closed-loop-world: %s %.0f %%" % [str(tsp.get("name", "")), 100.0 * float(tsp.get("level", 0.0))])
	_aim(main, centre + Vector2(0, 10), 60.0)
	await _shot(main, "05_next_day")
	main.set("time_scale", 0.0)
	print("closed-loop-world: %d failure(s)" % _fails)
	return {"ok": _fails == 0}
