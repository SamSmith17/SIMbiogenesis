extends RefCounted
## A delivery unloaded with a FORKLIFT (sandbox, Walton):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/forklift_unload_check.gd -Label forklift_unload -Timeout 900
## A forklift placed on open ground by the site marker, festival mode for a
## crew, then the "workshop_pallets" kit delivered beside it: the sheet press
## (250 kg) must go by forklift, the lighter machines by hand. Asserts the
## unload project carries a fork_move row bound to THIS forklift, that a
## person drives it (the rig reports operated), that the heavy crate lands on
## the ground at its staging slot, and that the forklift is parked with its
## forks down and empty after. Shots at each stage. Writes only the sandbox.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/forklift_unload"


func _ok(cond: bool, what: String) -> void:
	print("forklift-unload %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("forklift-unload shot: %s" % shot_name)


func _until(tree: SceneTree, secs: float, pred: Callable) -> bool:
	var t := 0.0
	while t < secs:
		if bool(pred.call()):
			return true
		await tree.create_timer(0.25).timeout
		t += 0.25
	return bool(pred.call())


func _aim(main: Node, at: Vector2, h: float) -> void:
	var view: Variant = main.get("settlement_view")
	var cam: Variant = view.get("_cam") if view != null else null
	if cam == null:
		return
	cam.set("_h_target", h)
	cam.set("_h", h)
	cam.set("focus", at)
	cam.set("_focus_target", at)


func _free_spot(loader: Node, centre: Vector2) -> Vector2:
	for r in [0.0, 30.0, 50.0, 70.0, 90.0, 120.0, 150.0]:
		for k in 12:
			var a := float(k) * TAU / 12.0
			var c: Vector2 = centre + Vector2(cos(a), sin(a)) * float(r)
			var ok := true
			for dx in [-14.0, 0.0, 14.0]:
				for dz in [-10.0, 0.0, 10.0]:
					var q: Vector2 = c + Vector2(float(dx), float(dz))
					if not str(loader.call("camp_area_at", q)).is_empty():
						ok = false
			if ok and loader.has_method("festival_ground_free") and not bool(loader.call("festival_ground_free", c, 22.0)):
				ok = false
			if ok:
				return c
	return centre


func _rec(main: Node, pid: String) -> Dictionary:
	return PlacedPropService.get_prop_record(main, pid).duplicate(true)


func _rig(main: Node, fid: String) -> Node:
	var n: Node = PlacedPropRuntime.find_by_prop_id(main, fid)
	return n.get_node_or_null("ForkliftRig") if n != null else null


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(sgv != null and loader != null, "graph view + terrain loader are up")
	if sgv == null or loader == null:
		return {"ok": false, "failures": _fails}
	var sd: SiteDeployDirector = sgv.call("site_deploy")
	sd.clear()
	main.set("time_scale", 0.001)
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 10.0)
	var spot := _free_spot(loader, SiteCentre.xz(main))
	print("forklift-unload: yard at (%.0f, %.0f)" % [spot.x, spot.y])
	var placed: Dictionary = PlacedPropService.place_model_at_xz(main,
		ForkliftBuilder.MODEL_ID, spot.x - 8.0, spot.y - 6.0, {})
	var fid := str(placed.get("prop_id", ""))
	_ok(bool(placed.get("ok", false)) and not fid.is_empty(), "forklift placed (%s)" % fid)
	if fid.is_empty():
		return {"ok": false, "failures": _fails}
	await _settle(tree, 10)
	_ok(_rig(main, fid) != null, "the placed forklift carries its ForkliftRig")
	main.call("open_festival_mode")
	for _i in 900:
		await tree.process_frame
		if bool(main.call("festival_mode_active")):
			break
	await _settle(tree, 30)
	var bridge: Variant = sgv.call("npc_population_bridge")
	_ok(bridge != null, "population bridge is up")
	if bridge == null:
		return {"ok": false, "failures": _fails}
	var iid := str(bridge.call("first_crewable_habitat"))
	_ok(not iid.is_empty(), "a crewable habitat exists (%s)" % iid)
	if iid.is_empty():
		return {"ok": false, "failures": _fails}
	bridge.call("set_all_hands", iid, true)
	await _settle(tree, 10)
	var res: Dictionary = loader.call("deliver_packed_kit", "workshop_pallets",
		spot.x + 8.0, spot.y, 0.0)
	var crates: Array = res.get("crate_ids", [])
	_ok(crates.size() == 3, "three crates delivered (%d)" % crates.size())
	await _settle(tree, 10)
	# The unload rows: the heavy crate on a fork_move bound to OUR forklift.
	var board: Variant = bridge.call("chore_board_for", iid)
	var fork_rows: Array = []
	var hand_rows := 0
	if board != null:
		for c in board.get("chores"):
			if not (c is Dictionary):
				continue
			var eff: Dictionary = c.get("effect", {})
			if str(eff.get("op", "")) == "fork_move":
				fork_rows.append(c)
			elif str(c.get("chore_key", c.get("id", ""))).contains("hand_") \
					or str(c.get("label", "")).begins_with("Carry"):
				hand_rows += 1
	_ok(fork_rows.size() >= 1, "the unload has a forklift row (%d)" % fork_rows.size())
	if fork_rows.is_empty():
		return {"ok": false, "failures": _fails}
	var row: Dictionary = fork_rows[0]
	var eff0: Dictionary = row.get("effect", {})
	_ok(str(eff0.get("forklift_id", row.get("forklift_id", ""))) == fid,
		"the row is bound to the placed forklift")
	var heavy := str(eff0.get("prop_id", ""))
	var hrec := _rec(main, heavy)
	_ok(str(hrec.get("model_id", "")) == "pp_sheet_press",
		"the forklift row moves the sheet press (%s)" % str(hrec.get("model_id", "")))
	var start := Vector2(float(hrec.get("x", 0.0)), float(hrec.get("z", 0.0)))
	var goal := Vector2(float(eff0.get("x", start.x)), float(eff0.get("z", start.y)))
	print("forklift-unload: press %s from (%.1f, %.1f) to (%.1f, %.1f), %d hand row(s)"
		% [heavy, start.x, start.y, goal.x, goal.y, hand_rows])
	_aim(main, spot, 30.0)
	await tree.create_timer(1.0).timeout
	await _shot(main, "01_delivered")
	main.set("time_scale", 0.2)
	var driven := await _until(tree, 420.0, func() -> bool:
		var rig := _rig(main, fid)
		return rig != null and bool(rig.call("is_operated")))
	_ok(driven, "somebody drives the forklift")
	if driven:
		var fr := _rec(main, fid)
		_aim(main, Vector2(float(fr.get("x", spot.x)), float(fr.get("z", spot.y))), 18.0)
		await tree.create_timer(0.5).timeout
		await _shot(main, "02_driving")
	var landed := await _until(tree, 480.0, func() -> bool:
		var r := _rec(main, heavy)
		var at := Vector2(float(r.get("x", 0.0)), float(r.get("z", 0.0)))
		return str(r.get("stowed_in", "")).is_empty() and at.distance_to(goal) < 0.6)
	var hr := _rec(main, heavy)
	_ok(landed, "the press reached its staging slot (%.1f m off)"
		% Vector2(float(hr.get("x", 0.0)), float(hr.get("z", 0.0))).distance_to(goal))
	_ok(absf(float(hr.get("y_offset", 0.0))) < 0.05, "the press is set down on the ground (y_offset %.2f)"
		% float(hr.get("y_offset", 0.0)))
	await _settle(tree, 20)
	var fr2 := _rec(main, fid)
	_ok(str(fr2.get("fork_load_id", "")).is_empty(), "the forks are empty after")
	_ok(float(fr2.get("fork_lift_m", 0.0)) < 0.05, "the forks are down after")
	var park := Vector2(float(fr2.get("x", 0.0)), float(fr2.get("z", 0.0)))
	_ok(park.distance_to(goal) < 8.0 and park.distance_to(goal) > 1.0,
		"the forklift is parked beside the drop (%.1f m)" % park.distance_to(goal))
	_aim(main, goal, 22.0)
	await tree.create_timer(1.0).timeout
	await _shot(main, "03_set_down")
	var all_off := await _until(tree, 480.0, func() -> bool:
		for pid in crates:
			if not str(_rec(main, str(pid)).get("stowed_in", "")).is_empty():
				return false
		return true)
	_ok(all_off, "every crate is out of the container")
	await _shot(main, "04_unloaded")
	main.set("time_scale", 0.001)
	bridge.call("set_all_hands", iid, false)
	return {"ok": _fails.is_empty(), "failures": _fails}
