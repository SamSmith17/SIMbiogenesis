extends SceneTree
## Offline selftest for the Lab's build-step player (LINKAGE_PARITY.md A5):
## LinkageStepScene frames (status staging, parked parts, bench steps, the
## tool on its op path) and LinkageStepPlayer (playback engine, rendering
## onto a real LinkageStructureBuilder, exit restores the design).
##
## Run: Godot.exe.exe --headless --path . --script core/linkage/build/linkage_step_player_selftest.gd

const EXPECTED_CHECKS := 21

var _fails := 0
var _checks := 0


func _initialize() -> void:
	var p := _soak()
	var steps := LinkageBuildSteps.generate_for(p)
	_test_frames(p, steps)
	_test_player(p, steps)
	var count_ok := EXPECTED_CHECKS == 0 or _checks == EXPECTED_CHECKS
	if not count_ok:
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _fails == 0 and count_ok:
		print("LINKAGE STEP PLAYER SELFTEST: PASS (%d checks)" % _checks)
	else:
		print("LINKAGE STEP PLAYER SELFTEST: FAIL (%d/%d)" % [_fails, _checks])
	quit(0 if _fails == 0 and count_ok else 1)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", label)


func _soak() -> LinkageParams:
	var f := FileAccess.open("res://core/linkage/presets/ll_starshade_v1_soak_2026.json", FileAccess.READ)
	var p := LinkageParams.new()
	p.from_config(JSON.parse_string(f.get_as_text()))
	return p


func _first(steps: Array, kind: String) -> int:
	for i in steps.size():
		if str(steps[i]["kind"]) == kind:
			return i
	return -1


func _visible_count(fr: Dictionary) -> int:
	var n := 0
	for k in fr["parts"]:
		if bool(fr["parts"][k]["visible"]):
			n += 1
	return n


func _test_frames(p: LinkageParams, steps: Array) -> void:
	var dep := rad_to_deg(LinkageKinematics.optimal_closed_angle(p))
	var ctx_cache := {}
	var ctx_for := func(i: int) -> Dictionary:
		var fold := LinkageStepScene.fold_for_step(steps, i, dep)
		var k := int(roundf(fold * 100.0))
		if not ctx_cache.has(k):
			ctx_cache[k] = LinkageStepScene.make_context(p, fold, dep)
		return ctx_cache[k]
	# Cut: a bench step, saw over the stock, rows on the bench.
	var ci := _first(steps, "cut")
	var fc := LinkageStepScene.frame(steps, ci, 0.4, ctx_for.call(ci))
	_check(bool(fc["bench"]) and str(fc["tool"].get("id", "")) == "circular_saw" and bool(fc["tool"]["visible"]),
		"a cut step is a bench step with the saw out")
	_check(not (fc["bench_boxes"] as Array).is_empty() and not (fc["bench_plane"] as Dictionary).is_empty(),
		"the cut shows its stock on the bench plane")
	var fc1 := LinkageStepScene.frame(steps, ci, 1.0, ctx_for.call(ci))
	var keeps := 0
	for b in fc1["bench_boxes"]:
		if str(b["kind"]) == "keep":
			keeps += 1
	_check(keeps > 0 and not bool(fc1["tool"]["visible"]), "at the end of the cut every row is kept and the saw put away")
	# Drill: holes appear as the bit works.
	var di := _first(steps, "drill")
	var fd0 := LinkageStepScene.frame(steps, di, 0.0, ctx_for.call(di))
	var fd1 := LinkageStepScene.frame(steps, di, 1.0, ctx_for.call(di))
	_check(str(fd0["tool"].get("id", "")) == "drill" and (fd0["holes"] as Array).size() < (fd1["holes"] as Array).size(),
		"drilling adds holes (%d -> %d)" % [(fd0["holes"] as Array).size(), (fd1["holes"] as Array).size()])
	# Place: the step's parts come in from away and seat.
	var pi := _first(steps, "place")
	var fp0 := LinkageStepScene.frame(steps, pi, 0.0, ctx_for.call(pi))
	var fp1 := LinkageStepScene.frame(steps, pi, 1.0, ctx_for.call(pi))
	var moved := 0
	var seated := 0
	for k in fp0["parts"]:
		if bool(fp0["parts"][k]["active"]):
			if (fp0["parts"][k]["offset"] as Vector3).length() > 1.0:
				moved += 1
			if (fp1["parts"][k]["offset"] as Vector3).length() < 1e-3 or (fp1["parts"][k]["offset"] as Vector3).is_equal_approx(fp0["parts"][k]["offset"] as Vector3):
				seated += 1
	_check(moved > 0, "a place step starts with its parts away from their seats (%d)" % moved)
	_check(not bool(fp0["bench"]) and fp0["tool"].is_empty(), "a place step shows the structure and no tool")
	# Parts only ever appear (assembly steps: a bench step hides the whole
	# structure, and marks the beams it cuts active).
	_check(_visible_count(LinkageStepScene.frame(steps, pi, 0.0, ctx_for.call(pi))) <= _visible_count(fp1)
		and _visible_count(fp1) < (fp1["parts"] as Dictionary).size(),
		"the first place step stands part of the structure, not all of it")
	var mono := true
	var last := -1
	for r in LinkageBuildSteps.representative_steps(steps):
		var i: int = r["index"]
		if LinkageStepScene.is_bench(steps[i]):
			continue
		var v := _visible_count(LinkageStepScene.frame(steps, i, 1.0, ctx_for.call(i)))
		var fold_i := LinkageStepScene.fold_for_step(steps, i, dep)
		# (A fold change re-solves: panels appear past their angle, so counts
		# are compared only at one pose.)
		if v < last and absf(fold_i - LinkageStepScene.fold_for_step(steps, maxi(0, i - 1), dep)) < 0.01:
			mono = false
		last = v
	_check(mono, "parts only appear as the sequence plays")
	var fl := LinkageStepScene.frame(steps, steps.size() - 1, 1.0, ctx_for.call(steps.size() - 1))
	_check(_visible_count(fl) == (fl["parts"] as Dictionary).size(), "at the end everything stands")
	# Fasten: the driver on a bolt of the joint being worked.
	var fi := _first(steps, "fasten")
	var ff := LinkageStepScene.frame(steps, fi, 0.3, ctx_for.call(fi))
	var tool: Dictionary = ff["tool"]
	var near := false
	if not tool.is_empty():
		var d := ((tool["xform"] as Transform3D).origin).distance_to(ff["focus"]["center"])
		near = d < float(ff["focus"]["radius"]) * 1.5
	_check(str(tool.get("id", "")) == "impact_driver" and near, "fastening puts the driver at the joint")
	# Parked: a lift step's parts start at the park offset and end seated.
	var li := -1
	for i in steps.size():
		if str((steps[i].get("op", {}) as Dictionary).get("from", "")) == "parked":
			li = i
			break
	if li >= 0:
		var fl0 := LinkageStepScene.frame(steps, li, 0.0, ctx_for.call(li))
		var fl1 := LinkageStepScene.frame(steps, li, 1.0, ctx_for.call(li))
		var far := 0
		var home := 0
		for k in fl0["parts"]:
			if bool(fl0["parts"][k]["active"]):
				if (fl0["parts"][k]["offset"] as Vector3).length() > 24.0:
					far += 1
				if (fl1["parts"][k]["offset"] as Vector3).length() < 1e-3:
					home += 1
		_check(far > 0 and home == far, "the lift carries the parked ring home (%d parked, %d home)" % [far, home])
	else:
		_check(false, "SOAK has a lift from the parked spot")


func _test_player(p: LinkageParams, steps: Array) -> void:
	var b := LinkageStructureBuilder.new()
	b.params = p
	b.collision_mesh_enabled = false
	get_root().add_child(b)
	b.set_fold_angle(LinkageKinematics.optimal_closed_angle(p))
	var design_fold := b.get_fold_angle()
	var pl := LinkageStepPlayer.new()
	get_root().add_child(pl)
	pl.setup(b, p)
	pl.set_steps(steps, {"repeatMode": "skip"})
	pl.enter(_first(steps, "cut"))
	_check(not b.visible and pl.tool_node("circular_saw") != null and pl.tool_node("circular_saw").visible,
		"on a cut step the structure is hidden and the saw is out")
	pl.go_to(_first(steps, "place"))
	var hidden := 0
	for k in b.part_keys():
		var s := b.part_state(k)
		if not s.is_empty() and not bool(s.get("visible", true)):
			hidden += 1
	_check(b.visible and hidden > 0, "on the first place step the structure shows with future parts hidden (%d)" % hidden)
	_check(absf(rad_to_deg(b.get_fold_angle()) - LinkageStepScene.fold_for_step(steps, pl.index, 0.0)) < 0.02,
		"the builder takes the step's pose")
	# Joint hardware the builder draws its own way (simple brackets, bolts,
	# washers) must not hang over the empty site before its joint is built.
	var floating := 0
	var jo := b.part_joint_keys()
	for k in b.part_keys():
		if not jo.has(k):
			continue
		var s3 := b.part_state(k)
		if s3.is_empty() or bool(s3.get("visible", true)):
			floating += 1
	_check(floating == 0, "no joint hardware shows before any joint is built (%d)" % floating)
	# The saw is placed where the frame says (bench inches -> metres).
	pl.go_to(_first(steps, "cut"))
	pl.scrub(0.4)
	var fr := pl.last_frame()
	var want: Vector3 = pl.bench_transform(fr) * (fr["tool"]["xform"] as Transform3D).origin
	_check((pl.tool_node("circular_saw").position).distance_to(want) < 1e-4, "the saw sits where the cut puts it")
	# Play to the end: skip mode visits one step per group.
	pl.go_to(0)
	pl.play()
	var visited := {}
	var guard := 0
	while pl.playing and guard < 20000:
		guard += 1
		visited[pl.index] = true
		pl._process(0.25)
	_check(pl.phase == "done" and not pl.playing, "playing runs to the end (%d ticks)" % guard)
	_check(visited.size() == LinkageBuildSteps.representative_steps(steps).size(),
		"skip mode plays each group once (%d of %d steps, %d groups)" % [visited.size(), steps.size(),
		LinkageBuildSteps.representative_steps(steps).size()])
	var at_end := 0
	for k in b.part_keys():
		var s2 := b.part_state(k)
		if not s2.is_empty() and not bool(s2.get("visible", true)):
			at_end += 1
	_check(at_end == 0, "after the last step nothing is hidden (%d)" % at_end)
	# Exit restores the design.
	pl.go_to(_first(steps, "place"))
	pl.exit()
	var states := 0
	for k in b.part_keys():
		if not b.part_state(k).is_empty():
			states += 1
	_check(states == 0 and b.visible and absf(b.get_fold_angle() - design_fold) < 1e-4,
		"exit seats every part, shows the structure and restores the fold")
	_check(pl.tool_node("circular_saw") == null or not pl.tool_node("circular_saw").visible, "and puts the tools away")
	pl.queue_free()
	b.queue_free()
