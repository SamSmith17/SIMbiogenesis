extends RefCounted

## A crew building a pallet rack (PalletRackBuildSite) on a real world, sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pallet_rack_build_check.gd -Label rack_build
## Places the "Build a rack bay" design (the Mars build lab's bay) ahead of the
## player, opens it in the rack builder, clicks Plan and "Rehearse the build",
## then moves a held clock through the build and asserts what a PNG cannot:
## the rack's own mesh hidden and every piece in the piles at the start, six
## builders, a frame lying then standing while its raisers hold it, beams only
## on standing frames, the crew on the ground (and a climber up), a tool in a
## fixer's hands, the pieces only ever going in, a scrub back drawing the same
## rack, the visitor on the deck, then the rack's own mesh back after the
## linger and "End rehearsal" taking the record away. A shot per phase.

const OWNER := "rack_build_check"

var _fails: Array = []
var _dir := ""
var _tree: SceneTree = null
var _main: Node = null
var _cam: Camera3D = null


func _ok(cond: bool, what: String) -> void:
	print("rack-build %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(frames: int) -> void:
	for _i in frames:
		await _tree.process_frame


func _shot(name: String) -> void:
	await _settle(4)
	_main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	_main = main
	_tree = main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null, "a TerrainLoader map")
	if loader == null:
		return _finish()
	var P := PalletRackBuilder
	var spec: Dictionary = P.design_preset("build_bay")["spec"]
	var player: Node3D = main.get_node_or_null("Player") as Node3D
	var fwd := -player.global_transform.basis.z if player != null else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.1 else Vector3.FORWARD
	var base := (player.global_position if player != null else Vector3.ZERO) + fwd * 14.0
	var res := PlacedPropService.place_model_at_xz(main, P.MODEL_ID, base.x, base.z)
	var pid := str(res.get("prop_id", ""))
	_ok(not pid.is_empty(), "placed the bay")
	if pid.is_empty():
		return _finish()
	PlacedPropService.update_prop_record(main, pid, {"rack_spec": P.resolve_spec(spec)}, true)
	await _settle(10)

	# The rack builder: Plan, then Rehearse.
	main.call("push_clock_claim", OWNER, {"time_scale": 0.0})
	# Build by daylight: noon today.
	var now_h := float(main.call("get_absolute_hours"))
	main.call("set_absolute_hours", floorf(now_h / 24.0) * 24.0 + 11.5)
	loader.call("open_pallet_rack_builder_for_prop", pid)
	await _settle(25)
	var ui: Control = loader.get("_pallet_rack_builder_ui")
	_ok(await _press(ui, "Plan"), "the Plan button is there")
	var plan_txt := (ui.get("_crew_lbl") as Label).text
	_ok(plan_txt.contains("6 people") and plan_txt.contains("min"), "Plan says how long six take: %s" % plan_txt)
	_ok(await _press(ui, "Rehearse the build"), "Rehearse the build is there")
	await _settle(15)
	_ok(not ui.visible, "the editor closed for the rehearsal")
	var site := PalletRackBuildSite.site_for(main, pid)
	_ok(site != null and site.is_running(), "a build site stands on the rack")
	if site == null:
		return await _cleanup(pid)
	var rec := PlacedPropService.get_prop_record(main, pid)
	var run: Dictionary = rec.get("build_run", {})
	var start_h := float(run.get("start_h", 0.0))
	var tl := site.timeline()
	var mk := float(tl["makespan"])
	print("rack-build plan: %s" % PalletRackBuildPlan.summary(tl))
	var model := (site.get_parent() as Node3D).get_node("ModelRoot") as Node3D

	# A camera on the bay.
	_cam = Camera3D.new()
	_cam.fov = 55.0
	main.add_child(_cam)
	var b: AABB = tl["bounds"]
	var centre := site.global_transform * b.get_center()
	_aim(centre + Vector3(9.0, 6.0, -13.0), centre)
	main.call("push_camera_claim", OWNER, {"camera_id": _cam.get_instance_id()})

	# t = 0.
	await _at(site, start_h, 0.5)
	_ok(not model.visible, "the rack's own mesh is hidden while it is built")
	var st := site.last_state()
	var in_pile := 0
	var units: Dictionary = st["units"]
	for id in units:
		if not (units[id]["xf"] as Transform3D).is_equal_approx(Transform3D()):
			in_pile += 1
	_ok(in_pile == units.size() and in_pile > 20, "every piece starts in the piles (%d)" % in_pile)
	_ok(site.crew_figures().size() == 6, "six builders")
	await _shot("00_start")

	# Find the moments: a frame being raised, beams being seated, a fixer, the visit.
	var jobs: Array = tl["jobs"]
	var t_raise := -1.0
	var t_seat := -1.0
	var t_fix := -1.0
	var t_high := -1.0
	var t_visit := -1.0
	for j in jobs:
		var k := str(j["kind"])
		var mid := (float(j["t0"]) + float(j["t1"])) * 0.5
		if k == "raise" and t_raise < 0.0:
			t_raise = mid
		elif k == "seat" and t_seat < 0.0:
			t_seat = mid
		elif k == "seat" and int(j["min"]) >= 4 and t_high < 0.0:
			t_high = mid
		elif k == "fix" and t_fix < 0.0:
			t_fix = mid
		elif k == "visit":
			t_visit = float(j["t1"]) - 2.0

	# Carrying.
	var t_carry := -1.0
	for k in 120:
		var tt := mk * 0.25 * float(k) / 120.0
		var s2 := PalletRackBuildPlan.state_at(tl, tt, false)
		for w in s2["workers"]:
			if str(w["activity"]) == "carry":
				t_carry = tt
				break
		if t_carry >= 0.0:
			break
	await _at(site, start_h, t_carry)
	_ok(_activities(site).has("carry"), "a piece being carried")
	var grounded := true
	for f in site.crew_figures():
		var gp: Vector3 = (f as Node3D).global_position
		var gy := TerrainSurfaceQuery.ground_height_at(main, gp.x, gp.z)
		if is_finite(gy) and absf(gp.y - gy) > 0.35:
			grounded = false
			print("rack-build   %s at %.2f, ground %.2f" % [f.name, gp.y, gy])
	_ok(grounded, "the crew stands on the ground")
	await _shot("01_carrying")

	await _at(site, start_h, t_raise)
	var acts := _activities(site)
	_ok(acts.has("raise"), "a frame being raised (%s)" % str(acts))
	var tilted := false
	for id in site.last_state()["units"]:
		var xf: Transform3D = site.last_state()["units"][id]["xf"]
		if str(id).begins_with("post:") and absf(xf.basis.y.dot(Vector3.UP)) < 0.98 and absf(xf.basis.y.dot(Vector3.UP)) > 0.05:
			tilted = true
	_ok(tilted, "a frame part-way up")
	await _shot("02_raising")

	await _at(site, start_h, t_seat)
	acts = _activities(site)
	_ok(acts.has("hold") and acts.has("seat"), "frames held while a beam is seated (%s)" % str(acts))
	await _shot("03_seating")

	await _at(site, start_h, t_high)
	var top := 0.0
	for f in site.crew_figures():
		top = maxf(top, (site.global_transform.affine_inverse() * (f as Node3D).global_position).y)
	_ok(top > 1.0, "a climber up the frame for the high beams (%.2f m)" % top)
	await _shot("04_high_beams")

	await _at(site, start_h, t_fix)
	var tool_shown := false
	for c in site.get_children():
		if c is Node3D and (c as Node3D).visible and c.has_meta("sockets"):
			tool_shown = true
	_ok(tool_shown, "a fixer holds a tool")
	_aim(centre + Vector3(4.5, 3.0, -6.0), centre)
	await _shot("05_fixing")
	_aim(centre + Vector3(9.0, 6.0, -13.0), centre)

	# Only grows; the drawn nodes follow the state.
	var prev := -1
	var grows := true
	for k in 13:
		await _at(site, start_h, mk * float(k) / 12.0, 2)
		var n := 0
		for id in site.last_state()["units"]:
			if (site.last_state()["units"][id]["xf"] as Transform3D).is_equal_approx(Transform3D()):
				n += 1
		if n < prev:
			grows = false
		prev = n
	_ok(grows, "the pieces only go in")
	await _at(site, start_h, mk * 0.5)
	var probe := ""
	for id in site.last_state()["units"]:
		probe = str(id)
	var xa := site.unit_node(probe).transform
	await _at(site, start_h, mk * 0.9)
	await _at(site, start_h, mk * 0.5)
	_ok(site.unit_node(probe).transform.is_equal_approx(xa), "a scrub back draws the same rack")
	await _shot("06_half_built")

	await _at(site, start_h, t_visit)
	top = 0.0
	for f in site.crew_figures():
		top = maxf(top, (site.global_transform.affine_inverse() * (f as Node3D).global_position).y)
	_ok(top > 1.5, "the visitor stands on the new deck (%.2f m)" % top)
	await _shot("07_visitor")

	# Frame cost while the clock runs.
	main.call("pop_clock_claim", OWNER)
	main.call("set_absolute_hours", start_h + mk * 0.4 / 3600.0)
	main.call("push_clock_claim", OWNER, {"time_scale": 60.0 / 3600.0})
	await _settle(30)
	var t0 := Time.get_ticks_usec()
	await _settle(60)
	var ms := float(Time.get_ticks_usec() - t0) / 60000.0
	var u0 := Time.get_ticks_usec()
	for _i in 30:
		site.call("_update", 1.0 / 60.0)
	var site_ms := float(Time.get_ticks_usec() - u0) / 30000.0
	print("rack-build frame: %.1f ms average while building at 60x; the site's own update %.2f ms" % [ms, site_ms])
	_ok(site_ms < 6.0, "the site costs under 6 ms a frame (%.2f ms)" % site_ms)
	main.call("pop_clock_claim", OWNER)
	main.call("push_clock_claim", OWNER, {"time_scale": 0.0})

	await _at(site, start_h, mk + PalletRackBuildSite.LINGER_S + 5.0)
	_ok(model.visible, "after the linger the rack's own mesh is back")
	await _shot("08_done")

	loader.call("open_pallet_rack_builder_for_prop", pid)
	await _settle(25)
	_ok(await _press(ui, "End rehearsal"), "End rehearsal is offered")
	_ok(not (PlacedPropService.get_prop_record(main, pid).get("build_run") is Dictionary), "the rehearsal record is gone")
	ui.call("close")
	return await _cleanup(pid)


func _aim(eye: Vector3, at: Vector3) -> void:
	_cam.global_transform = Transform3D(Basis.looking_at(at - eye, Vector3.UP), eye)


func _at(site: PalletRackBuildSite, start_h: float, t: float, frames: int = 6) -> void:
	_main.call("set_absolute_hours", start_h + t / 3600.0)
	await _settle(frames)


func _activities(site: PalletRackBuildSite) -> Array:
	var out: Array = []
	for w in site.last_state()["workers"]:
		if not out.has(str(w["activity"])):
			out.append(str(w["activity"]))
	return out


func _press(ui: Control, text: String) -> bool:
	var btn := HarnessInput.find_button(ui, text, false)
	if btn == null:
		return false
	var p: Node = btn.get_parent()
	while p != null and not (p is ScrollContainer):
		p = p.get_parent()
	if p is ScrollContainer:
		(p as ScrollContainer).ensure_control_visible(btn)
		await _settle(3)
	await HarnessInput.click(_main.get_viewport(), HarnessInput.center_of(btn))
	await _settle(10)
	return true


func _cleanup(pid: String) -> Dictionary:
	_main.call("pop_camera_claim", OWNER)
	_main.call("pop_clock_claim", OWNER)
	if _cam != null:
		_cam.queue_free()
	var loader := TerrainSurfaceQuery.find_terrain_loader(_main)
	if loader != null:
		loader.call("delete_prop_by_id", pid)
	return _finish()


func _finish() -> Dictionary:
	print("rack-build %s (%d failure(s))" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "failures": _fails}
