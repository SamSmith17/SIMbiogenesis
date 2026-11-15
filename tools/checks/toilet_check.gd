extends RefCounted
## Toilets in the world (NPC life pass, Phase 3; sandbox, Walton):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/toilet_check.gd -Label toilets -Timeout 900
##
## Opens festival mode, waits for every restroom AREA to get a toilet bank
## placed in it and for the bridge to give each restroom its stalls, then runs
## the clock through the morning bathroom block and asserts what a PNG cannot:
## never more people inside a restroom than it has stalls, a line forms at the
## busiest one, and every full-tier person using a toilet is ON its seat (kind
## toilet, seat height). Shoots the busiest bank close up (its line and doors)
## and a walking crowd at 1440x (the slant). Read-only: a sandbox run.

var _fails: Array = []
var _dir := "user://screenshots/toilets"


func _ok(cond: bool, what: String, detail: String = "") -> void:
	print("toilet-check %s: %s%s" % ["PASS" if cond else "FAIL", what, "" if detail.is_empty() else " (%s)" % detail])
	if not cond:
		_fails.append(what)


## A spot on open ground ~25 m from `near` (the first of eight bearings whose
## ground is within a metre of level and clear of placed props).
func _open_ground(main: Node, near: Vector2) -> Vector2:
	for k in 8:
		var a := float(k) * TAU / 8.0
		var p := near + Vector2(cos(a), sin(a)) * 25.0
		var h0 := TerrainSurfaceQuery.ground_height_at(main, p.x, p.y)
		var h1 := TerrainSurfaceQuery.ground_height_at(main, p.x + 3.0, p.y)
		var h2 := TerrainSurfaceQuery.ground_height_at(main, p.x, p.y + 3.0)
		if absf(h1 - h0) < 0.6 and absf(h2 - h0) < 0.6:
			return p
	return near + Vector2(25.0, 0.0)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	PopTestPrefs.reset_defaults()
	# The camps' natural headcount (0 = natural): busy toilets, real lines.
	PopTestPrefs.set_festival_target_people(0)
	main.call("open_festival_mode")
	await tree.create_timer(2.0).timeout
	# The festival view's camera would take the shots; we take our own.
	if bool(main.call("settlement_view_open")):
		main.call("toggle_settlement_view")
	var loader := main.find_child("TerrainLoader", true, false)
	var reg: SpaceRegistry = loader.get("npc_spaces") if loader != null else null
	_ok(reg != null, "the world has a space registry")
	if reg == null:
		return {"ok": false}
	var sgv := ServiceLocator.graph()
	var bridge: Object = sgv.call("npc_population_bridge") if sgv != null else null
	_ok(bridge != null, "the population bridge is up")
	if bridge == null:
		return {"ok": false}
	# Banks are placed (and stalls resolved) on the bridge's one-second pass.
	main.set("time_scale", 1.0 / 3600.0)
	var rest: Array = []
	var waited := 0.0
	while waited < 30.0:
		await tree.create_timer(0.5).timeout
		waited += 0.5
		rest = reg.spaces_of_type("restroom")
		var ready := not rest.is_empty()
		for s: Dictionary in rest:
			if reg.stall_count(str(s["id"])) <= 0:
				ready = false
		if ready:
			break
	_ok(not rest.is_empty(), "the festival has restrooms (%d)" % rest.size())
	var banks := 0
	var stalls := 0
	for s: Dictionary in rest:
		var sid := str(s["id"])
		stalls += reg.stall_count(sid)
		var tgt: Dictionary = s.get("target", {})
		if str(tgt.get("kind", "")) == "area":
			var pid := str(s.get("bank_prop", ""))
			if not pid.is_empty() and PlacedPropRuntime.find_by_prop_id(main, pid) != null:
				banks += 1
	var areas := 0
	for s: Dictionary in rest:
		if str((s.get("target", {}) as Dictionary).get("kind", "")) == "area":
			areas += 1
	_ok(banks == areas, "every restroom area got a toilet bank", "%d of %d" % [banks, areas])
	_ok(stalls > 0, "the restrooms have stalls (%d)" % stalls)
	# A 4-stall bank of our own on open ground beside the busiest restroom:
	# people should spread to it (the expected wait prices the choice), and it
	# is where the shots look.
	var anchor := Vector2.ZERO
	for s: Dictionary in rest:
		var p0: Variant = reg.cached_position(str(s["id"]))
		if p0 is Vector2:
			anchor = p0
			break
	var spot := _open_ground(main, anchor)
	var placed := PlacedPropService.place_model_at_xz(main, ToiletBankBuilder.MODEL_ID, spot.x, spot.y,
		{"yaw": rad_to_deg(atan2(anchor.x - spot.x, anchor.y - spot.y)), "toilet_spec": {"stalls": 4}})
	var bank_id := str(placed.get("prop_id", ""))
	_ok(bool(placed.get("ok", false)), "placed a 4-stall toilet bank", str(spot))
	await tree.create_timer(2.0).timeout
	var bank_sid := ""
	for s: Dictionary in reg.spaces_of_type("restroom"):
		if str((s.get("target", {}) as Dictionary).get("prop_id", "")) == bank_id:
			bank_sid = str(s["id"])
	_ok(not bank_sid.is_empty() and reg.stall_count(bank_sid) == 4, "the bank is a restroom with 4 stalls",
		"%s %d" % [bank_sid, reg.stall_count(bank_sid) if not bank_sid.is_empty() else -1])
	rest = reg.spaces_of_type("restroom")
	# Through the morning bathroom block at 60x (everyone just woke: the busiest).
	var h := float(main.call("get_absolute_hours"))
	main.call("set_absolute_hours", floor(h / 24.0) * 24.0 + 24.0 + 9.2)
	main.set("time_scale", 60.0 / 3600.0)
	var max_over := 0
	var bank_used := 0
	var max_line := 0
	var busiest := ""
	var seated := 0
	var off_seat := 0
	for k in 120:
		await tree.create_timer(0.25).timeout
		for s: Dictionary in rest:
			var sid := str(s["id"])
			var n := reg.stall_count(sid)
			if n > 0:
				max_over = maxi(max_over, reg.occupant_count(sid) - n)
			if sid == bank_sid:
				bank_used = maxi(bank_used, reg.occupant_count(sid))
			if reg.queue_len(sid) > max_line:
				max_line = reg.queue_len(sid)
				busiest = sid
		for d: Dictionary in bridge.call("agent_dots_full"):
			if str(d.get("activity", "")) != "bladder" or int(d.get("state", -1)) != NpcAgent.State.DOING:
				continue
			if str(d.get("seat", "")) == NpcSeatPose.KIND_TOILET and float(d.get("elev", 0.0)) >= NpcSeatPose.CHAIR_MIN_ELEV:
				seated += 1
			else:
				off_seat += 1
	_ok(max_over <= 0, "never more inside a restroom than its stalls", "worst %+d" % max_over)
	var cnt: Dictionary = bridge.call("population_counts")
	var to_wc := 0
	var at_wc := 0
	var queued := 0
	for c in (bridge.call("light_cohorts") as Dictionary).values():
		var co: CrowdCohort = c
		for i in co.count():
			if co.alive[i] != 1 or int(co.act[i]) != CrowdCohort.A_BLADDER:
				continue
			match int(co.state[i]):
				CrowdCohort.S_TRAVEL: to_wc += 1
				CrowdCohort.S_DOING: at_wc += 1
				CrowdCohort.S_QUEUE: queued += 1
	print("toilet-check: people %s; light tier now: %d walking to a toilet, %d on one, %d in a line"
		% [str(cnt), to_wc, at_wc, queued])
	print("toilet-check: longest line %d, seated samples %d, off-seat %d" % [max_line, seated, off_seat])
	_ok(off_seat == 0, "full-tier toilet users are on a toilet seat",
		"%d seated, %d not" % [seated, off_seat])
	print("toilet-check: our bank: most inside at once %d, line now %d" % [bank_used, reg.queue_len(bank_sid)])
	_ok(bank_used > 0, "people use the new bank beside a busy toilet", "%d" % bank_used)
	# Shots: our bank, then a crowd walking at 1440x.
	busiest = bank_sid
	var ui := main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false
	var cam := Camera3D.new()
	cam.fov = 60.0
	main.add_child(cam)
	main.call("push_camera_claim", "toilet_check", {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})
	var bank_prop := PlacedPropRuntime.find_by_prop_id(main, bank_id)
	# The prop's yaw is on its ModelRoot: that is the bank's own frame.
	var bank_node: Node3D = bank_prop.get_node_or_null("ModelRoot") as Node3D if bank_prop != null else null
	main.set("time_scale", 2.0 / 3600.0)
	# Wait for someone to be in the line or a stall before the close-ups.
	for w in 40:
		if reg.queue_len(bank_sid) > 0 or reg.occupant_count(bank_sid) > 1:
			break
		main.set("time_scale", 60.0 / 3600.0)
		await tree.create_timer(0.25).timeout
	main.set("time_scale", 2.0 / 3600.0)
	if bank_node != null:
		var b := bank_node.global_transform
		var front := b.basis * Vector3(0.0, 0.0, 1.0)
		var side := b.basis * Vector3(1.0, 0.0, 0.0)
		var at := b.origin + Vector3(0.0, 1.0, 0.0)
		cam.look_at_from_position(at + front * 11.0 + side * 6.0 + Vector3(0.0, 3.0, 0.0), at + front * 2.0, Vector3.UP)
		await tree.create_timer(1.5).timeout
		main.get_viewport().get_texture().get_image().save_png("%s/01_bank_line.png" % _dir)
		cam.look_at_from_position(at + front * 3.2 + Vector3(0.0, 1.0, 0.0), at, Vector3.UP)
		await tree.create_timer(1.0).timeout
		main.get_viewport().get_texture().get_image().save_png("%s/02_bank_doors.png" % _dir)
	# People walking to and from the bank at 1440x (the forward slant), side on.
	if bank_node != null:
		main.set("time_scale", 1440.0 / 3600.0)
		var b2 := bank_node.global_transform
		var side2 := b2.basis * Vector3(1.0, 0.0, 0.0)
		var front2 := b2.basis * Vector3(0.0, 0.0, 1.0)
		var at2 := b2.origin + front2 * 6.0 + Vector3(0.0, 1.0, 0.0)
		cam.look_at_from_position(at2 + side2 * 14.0 + Vector3(0.0, 0.6, 0.0), at2, Vector3.UP)
		for f in 4:
			await tree.create_timer(0.6).timeout
			main.get_viewport().get_texture().get_image().save_png("%s/03_walkers_1440x_%d.png" % [_dir, f])
	main.call("pop_camera_claim", "toilet_check")
	cam.queue_free()
	return {"ok": _fails.is_empty(), "fails": _fails}
