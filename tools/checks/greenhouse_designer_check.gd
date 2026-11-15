extends RefCounted

## The greenhouse designer on a real world (sandbox, REAL clicks on the Plan):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/greenhouse_designer_check.gd -Label greenhouse -Timeout 1200
## Opens the designer (UiAudit), picks the keyhole dome and the gable, clicks
## a bed on the Plan, drags it, draws a new bed, turns its lights on; places
## the gable through the designer's prep and checks every bed / light rack
## stands inside it as its own prop mounted on it; moves and turns the house
## (update_prop_record, move_prop_at) and checks every part followed; Apply
## with gantries on every bed swaps the beds for FarmBot beds; packs and
## unpacks it; a sunk walipini gets its earthworks; deleting a house takes its
## parts with it. Shots under screenshots\<label>\. Removes what it placed.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("greenhouse %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _parts(main: Node, host: String) -> Array:
	return GreenhouseWorld.parts_of(main, host).values()


## Worst distance between a part's record frame and host × its local frame.
func _follow_err(main: Node, host: String) -> float:
	var hrec := PlacedPropService.get_prop_record(main, host)
	var hxf := PvSurfaceAim.record_xf(main, hrec)
	var worst := 0.0
	for r in _parts(main, host):
		var rec: Dictionary = r
		var mh: Dictionary = rec["mount_host"]
		var want := hxf * PlacedPropService._xf_from_array(mh["local"])
		var got := PvSurfaceAim.record_xf(main, rec)
		worst = maxf(worst, want.origin.distance_to(got.origin))
	return worst


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("day_time", 11.0)
	main.set("time_scale", 0.0)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as CharacterBody3D
	_ok(loader != null and player != null, "a TerrainLoader world with a player")
	if loader == null or player == null:
		return {"ok": false, "fails": _fails}
	if main.has_method("settlement_view_open") and bool(main.call("settlement_view_open")):
		(main.get("settlement_view") as Node).call("close")
		await _frames(tree, 20)
	var vp := main.get_viewport()

	# --- the designer ---------------------------------------------------------
	var modal: Node = load("res://scenes/ui/greenhouselab_modal.gd").call("open", tree, {})
	await _frames(tree, 40)
	_ok(modal != null and bool(modal.call("is_open")), "the designer opens")
	var audit := UiAudit.run(vp)
	print("greenhouse: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the designer passes the UI audit")
	await _shot(main, "0_designer_hoop")
	_ok(bool(modal.call("select_design", "keyhole_dome")), "the keyhole dome is in the gallery")
	await _frames(tree, 30)
	await _shot(main, "1_designer_dome")
	_ok(bool(modal.call("select_design", "gable_pc")), "the gable is in the gallery")
	await _frames(tree, 20)
	var tabs := modal.find_child("views", true, false) as TabBar
	tabs.current_tab = 1
	await _frames(tree, 10)
	var plan := modal.find_child("plan_view", true, false) as GreenhousePlanView
	var d0: Dictionary = modal.call("design")
	var b0: Dictionary = d0["beds"][0]
	var p_bed := plan.get_global_transform() * plan.to_screen(Vector2(float(b0["x"]), float(b0["z"])))
	await HarnessInput.click(vp, p_bed)
	await _frames(tree, 6)
	_ok(str(modal.call("selected_bed")) == str(b0["id"]), "a click on the Plan selects the bed")
	var p_to := plan.get_global_transform() * plan.to_screen(Vector2(float(b0["x"]) + 1.0, float(b0["z"])))
	await HarnessInput.drag(vp, p_bed, p_to)
	await _frames(tree, 10)
	var d1: Dictionary = modal.call("design")
	var moved := false
	for b in d1["beds"]:
		var hl0 := float(d1["spec"]["length_m"]) * 0.5
		if str(b["id"]) == str(b0["id"]) and float(b["x"]) - float(b0["x"]) > 0.5 				and float(b["x"]) + float(b["length_m"]) * 0.5 <= hl0 + 1e-3:
			moved = true
	_ok(moved, "dragging the bed moves it along the house and it stops at the end wall")
	var n_before := (d1["beds"] as Array).size()
	var hl := float(d1["spec"]["length_m"]) * 0.5
	var a := plan.get_global_transform() * plan.to_screen(Vector2(-hl + 0.3, -0.4))
	var b2 := plan.get_global_transform() * plan.to_screen(Vector2(-hl + 0.85, 0.4))
	await HarnessInput.drag(vp, a, b2)
	await _frames(tree, 10)
	_ok((modal.call("design")["beds"] as Array).size() == n_before + 1, "dragging on the floor draws a new bed")
	modal.call("set_bed_field", str(b0["id"]), "lights", true)
	await _frames(tree, 10)
	var lit := false
	for b in modal.call("design")["beds"]:
		if str(b["id"]) == str(b0["id"]) and (b as Dictionary).has("light"):
			lit = true
	_ok(lit, "a bed's lights switch on from its card")
	await _shot(main, "2_plan")
	tabs.current_tab = 2
	var yr: Dictionary = {}
	for _i in 900:
		await tree.process_frame
		yr = modal.call("year_result")
		if not yr.is_empty():
			break
	_ok(not yr.is_empty() and (yr["months"] as Array).size() == 12, "the Climate tab runs a year at the site")
	if not yr.is_empty():
		var yt: Dictionary = yr["total"]
		print("greenhouse: year — coldest in %.1f °C (out %.1f), vents %.0f h, harvest %.0f kg, rain %.0f L" % [
			float(yt["coldest_in"]), float(yt["coldest_out"]), float(yt["vent_h"]), float(yt["yield_kg"]), float(yt["rain_l"])])
		_ok(float(yt["coldest_in"]) > float(yt["coldest_out"]), "inside never gets as cold as outside")
	await _frames(tree, 10)
	await _shot(main, "2b_climate")
	tabs.current_tab = 0
	await _frames(tree, 20)
	await _shot(main, "3_designer_gable_edited")
	var spec: Dictionary = modal.call("current_spec")
	modal.call("close")
	await _frames(tree, 10)

	# --- placed -----------------------------------------------------------------
	var p0 := player.global_position
	var at := _clear_spot(main, Vector2(p0.x, p0.z))
	var pid := PlacedPropService.place_prepped_at(main, GreenhouseBuilder.MODEL_ID,
		{"record_extra": {GreenhouseSpec.KEY: GreenhouseSpec.to_json_safe(spec), "collision_enabled": true, "walk_in": true}},
		at.x, at.y, 0.0)
	_ok(not pid.is_empty(), "placed through the designer's prep")
	await _frames(tree, 30)
	var d := GreenhouseDesign.solve(spec)
	var want := GreenhouseParts.parts(d).size()
	var parts := _parts(main, pid)
	_ok(parts.size() == want, "every bed and light rack stands in it as its own prop (%d of %d)" % [parts.size(), want])
	var owned := true
	for r in parts:
		if not bool((r as Dictionary)["mount_host"].get("owned", false)):
			owned = false
	_ok(owned and not parts.is_empty(), "each part is mounted on the house, owned")
	_ok(_follow_err(main, pid) < 0.02, "the parts stand where the design puts them")
	player.global_position = Vector3(at.x + 12.0, float(loader.call("ground_height_at", at.x, at.y)) + 7.0, at.y + 14.0)
	var cam := player.get_viewport().get_camera_3d()
	player.look_at(Vector3(at.x, player.global_position.y, at.y), Vector3.UP)
	if cam != null:
		cam.rotation.x = -0.4
	await _frames(tree, 30)
	await _shot(main, "4_placed")

	# Move and turn it by the editor's path, then by the Site Plan's path.
	PlacedPropService.update_prop_record(main, pid, {"x": at.x + 6.0, "yaw": 30.0}, true)
	await _frames(tree, 20)
	_ok(_follow_err(main, pid) < 0.02, "moved + turned (update_prop_record): every part followed (%.3f m)" % _follow_err(main, pid))
	PlacedPropService.move_prop_at(main, pid, at.x + 3.0, at.y + 2.0)
	await _frames(tree, 20)
	_ok(_follow_err(main, pid) < 0.02, "moved (move_prop_at): every part followed (%.3f m)" % _follow_err(main, pid))
	await _shot(main, "5_moved")

	# Apply with a FarmBot on every bed.
	var m2: Node = load("res://scenes/ui/greenhouselab_modal.gd").call("open", tree, {"prop_id": pid})
	await _frames(tree, 20)
	m2.call("_set_field", "beds.gantry", true)
	await _frames(tree, 5)
	m2.call("_on_apply")
	m2.call("close")
	await _frames(tree, 30)
	var fb := 0
	for r in _parts(main, pid):
		if str((r as Dictionary).get("model_id", "")) == FarmBotBuilder.MODEL_ID:
			fb += 1
	_ok(fb > 0, "Apply with gantries puts FarmBot beds in (%d)" % fb)
	_ok(_follow_err(main, pid) < 0.02, "the new parts stand in the moved house")

	# Pack / unpack.
	loader.call("set_prop_packed", pid, true)
	await _frames(tree, 20)
	var all_packed := true
	for r in _parts(main, pid):
		if not bool((r as Dictionary).get("packed", false)):
			all_packed = false
	_ok(all_packed, "packing the house packs its parts")
	loader.call("set_prop_packed", pid, false)
	await _frames(tree, 20)
	var none_packed := true
	for r in _parts(main, pid):
		if bool((r as Dictionary).get("packed", false)):
			none_packed = false
	_ok(none_packed, "unpacking it unpacks them")

	# Sunk: a walipini.
	var wal: Dictionary = GreenhousePresets.builtin("walipini")["spec"]
	var at2 := _clear_spot(main, Vector2(at.x + 60.0, at.y))
	var wid := PlacedPropService.place_prepped_at(main, GreenhouseBuilder.MODEL_ID,
		{"record_extra": {GreenhouseSpec.KEY: GreenhouseSpec.to_json_safe(wal), "collision_enabled": true, "walk_in": true}},
		at2.x, at2.y, 0.0)
	await _frames(tree, 60)
	var wrec := PlacedPropService.get_prop_record(main, wid)
	_ok(StructureEarthworks.is_on(wrec), "the walipini carries its earthworks")
	var grade := float(loader.call("ground_without_structures", at2.x, at2.y))
	var inside := float(loader.call("ground_height_at", at2.x, at2.y))
	_ok(grade - inside > 1.5, "the floor inside is down in the earth (%.2f m below grade)" % (grade - inside))
	player.global_position = Vector3(at2.x + 8.0, grade + 4.0, at2.y + 10.0)
	player.look_at(Vector3(at2.x, grade, at2.y), Vector3.UP)
	await _frames(tree, 30)
	await _shot(main, "6_walipini")

	# Delete: the parts go with the house.
	var part_ids: Array = []
	for r in _parts(main, pid):
		part_ids.append(str((r as Dictionary)["id"]))
	loader.call("delete_prop_by_id", pid)
	loader.call("delete_prop_by_id", wid)
	await _frames(tree, 10)
	var left := 0
	for i in part_ids:
		if not PlacedPropService.get_prop_record(main, str(i)).is_empty():
			left += 1
	_ok(left == 0, "deleting the house deletes its parts (%d left)" % left)
	return {"ok": _fails.is_empty(), "fails": _fails}


func _clear_spot(main: Node, from: Vector2) -> Vector2:
	var recs: Array = []
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.has_method("placed_prop_records"):
		recs = loader.call("placed_prop_records")
	for ring in range(3, 20):
		for k in 16:
			var a := TAU * float(k) / 16.0
			var c := from + Vector2(cos(a), sin(a)) * (float(ring) * 25.0)
			var ok := true
			for r in recs:
				var q := Vector2(float(r.get("x", 0.0)), float(r.get("z", 0.0)))
				if q.distance_to(c) < 40.0:
					ok = false
			if ok:
				return c
	return from + Vector2(0.0, -60.0)
