extends SceneTree
## Offline selftest for the fabrication swarm's figure layer (phase B1 + B2):
## NpcLimbIk (analytic two-bone IK), NpcAnimClip (keyframe clips: JSON, track
## sampling, events, mirroring), NpcSimpleFigure's wrist / clip / IK / tool
## layer, and FabToolCatalog's tools + sockets.
##
## Run: Godot.exe.exe --headless --path . --script core/population/npc_anim_selftest.gd

## A Godot runtime error aborts the enclosing test function while the suite
## still prints PASS; the count catches a silently skipped function.
const EXPECTED_CHECKS := 44

var _fails := 0
var _checks := 0


func _initialize() -> void:
	# Figures need the tree (global transforms); run on the first frame.
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	_test_ik()
	_test_clip()
	_test_figure_ik()
	_test_figure_clip_restores()
	_test_tools()
	_test_clip_editing()
	_test_context_rig()
	var count_ok := EXPECTED_CHECKS == 0 or _checks == EXPECTED_CHECKS
	if not count_ok:
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _fails == 0 and count_ok:
		print("NPC ANIM SELFTEST: PASS (%d checks)" % _checks)
	else:
		print("NPC ANIM SELFTEST: FAIL (%d/%d)" % [_fails, _checks])
	quit(0 if _fails == 0 and count_ok else 1)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", label)


# ---------------------------------------------------------------------------

func _test_ik() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst := 0.0
	var pole_ok := true
	for k in 200:
		var root := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.3
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var target := root + dir * rng.randf_range(0.08, 0.57)
		var pole := root + Vector3(0.3, -0.2, -0.5)
		var sol := NpcLimbIk.solve(root, target, pole, 0.30, 0.28, -1.0)
		var fk := NpcLimbIk.forward(root, sol["root_basis"], float(sol["mid_angle"]), 0.30, 0.28)
		worst = maxf(worst, (fk["end_pos"] as Vector3).distance_to(target))
		# The middle joint sits on the pole's side of the reach line.
		var d := (target - root).normalized()
		var pp := (pole - root) - d * (pole - root).dot(d)
		var mm := ((fk["mid_pos"] as Vector3) - root) - d * ((fk["mid_pos"] as Vector3) - root).dot(d)
		if pp.length() > 1e-3 and mm.length() > 1e-3 and pp.dot(mm) <= 0.0:
			pole_ok = false
	_check(worst < 1e-4, "IK lands the hand on every reachable target (worst %.6f m)" % worst)
	_check(pole_ok, "IK bends the middle joint toward the pole")
	var arm := NpcLimbIk.solve(Vector3.ZERO, Vector3(0, -0.3, 0.3), Vector3(0, 0, -1), 0.30, 0.28, -1.0)
	_check(float(arm["mid_angle"]) < 0.0, "an elbow bends with a negative X rotation (forearm forward)")
	var leg := NpcLimbIk.solve(Vector3.ZERO, Vector3(0, -0.7, -0.1), Vector3(0, 0, 1), 0.44, 0.42, 1.0)
	_check(float(leg["mid_angle"]) > 0.0, "a knee bends with a positive X rotation (shin back)")
	var far := NpcLimbIk.solve(Vector3.ZERO, Vector3(0, -2, 0), Vector3(0, 0, -1), 0.30, 0.28, -1.0)
	_check(not bool(far["reached"]) and absf((far["end_pos"] as Vector3).length() - 0.58) < 1e-3,
		"out of reach: a straight arm toward the target")
	_check((far["root_basis"] as Basis).is_conformal() and absf((far["root_basis"] as Basis).determinant() - 1.0) < 1e-4,
		"IK root basis is a proper rotation")


func _test_clip() -> void:
	var d := {"id": "t", "label": "Test", "length_s": 2.0, "loop": true,
		"keys": [
			{"t": 0.0, "ease": "linear", "joints": {"shoulder_r": [-90, 0, 0], "knee_l": [20, 0, 0]}, "body": {"y": 0.0, "pitch": 0}},
			{"t": 1.0, "ease": "linear", "joints": {"shoulder_r": [0, 0, 0]}, "body": {"y": -0.2}},
		],
		"ik": {"hand_r": "grip", "hand_l": "bogus"}, "tool": {"id": "drill", "hand": "r"},
		"events": [{"t": 0.5, "name": "contact"}]}
	var c := NpcAnimClip.from_dict(d)
	_check(c.ik["hand_l"] == "none" and c.ik["hand_r"] == "grip", "bad IK values fall back to none")
	var back := NpcAnimClip.from_dict(JSON.parse_string(JSON.stringify(c.to_dict())))
	_check(back.to_dict() == c.to_dict(), "clip JSON round-trip")
	var s0 := c.sample(0.0)
	var q0: Quaternion = s0["joints"]["shoulder_r"]
	_check(q0.is_equal_approx(NpcAnimClip.euler_deg_to_quat(Vector3(-90, 0, 0))), "sample at a key = the key")
	var s_half := c.sample(0.5)
	var ang := (s_half["joints"]["shoulder_r"] as Quaternion).get_angle()
	_check(absf(ang - deg_to_rad(45.0)) < 1e-3, "linear halfway = half the arc (%.4f rad)" % ang)
	_check(absf(float(s_half["body"]["y"]) + 0.1) < 1e-6, "body track interpolates")
	# A track with one key holds it; looping wraps 2.0 -> 0.
	_check((c.sample(1.7)["joints"]["knee_l"] as Quaternion).is_equal_approx(NpcAnimClip.euler_deg_to_quat(Vector3(20, 0, 0))),
		"a one-key track holds")
	var wrap := (c.sample(1.5)["joints"]["shoulder_r"] as Quaternion).get_angle()
	_check(absf(wrap - deg_to_rad(45.0)) < 1e-3, "looping wraps back to the first key")
	_check(c.events_between(0.4, 0.6) == ["contact"] and c.events_between(2.4, 2.6) == ["contact"]
		and c.events_between(0.6, 2.4).is_empty(), "events fire once per pass")
	var m := c.mirror()
	_check(m.ik["hand_l"] == "grip" and m.tool["hand"] == "l", "mirror swaps the IK hands and the tool hand")
	_check((m.keys[0]["joints"] as Dictionary).has("shoulder_l") and (m.keys[0]["joints"] as Dictionary).has("knee_r"),
		"mirror swaps left and right")
	var mm := m.mirror()
	_check((mm.keys[0]["joints"]["shoulder_r"] as Vector3).is_equal_approx(Vector3(-90, 0, 0)), "mirror twice = identity")
	var step := NpcAnimClip.from_dict({"length_s": 1.0, "loop": false, "keys": [
		{"t": 0.0, "ease": "step", "joints": {"head": [0, 0, 0]}},
		{"t": 1.0, "joints": {"head": [30, 0, 0]}}]})
	_check((step.sample(0.9)["joints"]["head"] as Quaternion).is_equal_approx(Quaternion()), "step ease holds until the next key")
	# Shipped clips parse and carry their tool.
	var ids := NpcAnimClip.list_ids()
	_check(ids.size() >= 4, "shipped clips found (%d)" % ids.size())
	var bad: Array = []
	for cid in ids:
		var sc := NpcAnimClip.load_clip(cid)
		if sc == null or sc.keys.is_empty():
			bad.append(cid)
		elif not sc.tool.is_empty() and not FabToolCatalog.TOOLS.has(str(sc.tool["id"])):
			bad.append(cid + " (tool " + str(sc.tool["id"]) + ")")
	_check(bad.is_empty(), "every shipped clip loads with a known tool: %s" % str(bad))


func _figure() -> NpcSimpleFigure:
	var f := NpcSimpleFigure.new()
	f.hi_detail = true
	root.add_child(f)
	f.setup("test_person", Color(0.6, 0.7, 0.8))
	return f


func _test_figure_ik() -> void:
	var f := _figure()
	f.position = Vector3(1, 0, 2)
	f.pose("idle", 1.0, 0.016)
	# A palm placement in front of the chest, hand turned palm-down.
	var want := Transform3D(Basis(Vector3(1, 0, 0), deg_to_rad(-80.0)), f.global_position + Vector3(-0.15, 1.1, 0.35))
	f.set_hand_target(0, want)
	f.pose("idle", 1.0, 0.016)
	var got := f.palm_global(0)
	_check(got.origin.distance_to(want.origin) < 0.002, "the palm reaches its target (%.4f m)" % got.origin.distance_to(want.origin))
	_check(got.basis.orthonormalized().is_equal_approx(want.basis.orthonormalized()), "the hand turns to the grip's basis")
	# Left hand untouched by the right's IK.
	var f2 := _figure()
	f2.position = f.position
	f2.pose("idle", 1.0, 0.016)
	f2.pose("idle", 1.0, 0.016)
	var jl := f.joint_map()
	var jl2 := f2.joint_map()
	_check((jl["shoulder_l"] as Node3D).basis.is_equal_approx((jl2["shoulder_l"] as Node3D).basis),
		"the other arm keeps its procedural pose")
	# Release: the next frame is the plain procedural pose again.
	f.set_hand_target(0, null)
	f.pose("idle", 1.0, 0.016)
	f2.pose("idle", 1.0, 0.016)
	_check((jl["shoulder_r"] as Node3D).rotation.is_equal_approx((jl2["shoulder_r"] as Node3D).rotation),
		"released: the arm is back on the procedural pose")
	# Planted foot.
	var ankle := f.global_position + Vector3(-0.1, 0.12, 0.25)
	f.set_foot_target(0, ankle)
	f.pose("idle", 1.0, 0.016)
	var foot_world := (jl["knee_r"] as Node3D).global_transform * Vector3(0, -NpcSimpleFigure.SHIN, 0)
	_check(foot_world.distance_to(ankle) < 0.002, "a planted foot lands on its target (%.4f m)" % foot_world.distance_to(ankle))
	f.queue_free()
	f2.queue_free()


## A clip layered on and then cleared must leave the body exactly where the
## procedural pose has it (the mo-cap spice rule).
func _test_figure_clip_restores() -> void:
	var a := _figure()
	var b := _figure()
	var clip := NpcAnimClip.from_dict({"length_s": 1.0, "keys": [
		{"t": 0.0, "joints": {"shoulder_r": [-120, 10, 0], "elbow_r": [-60, 0, 0], "torso": [20, 0, 0]}, "body": {"y": -0.1}}]})
	for k in 5:
		a.pose("work", 1.0, 0.05)
		b.pose("work", 1.0, 0.05)
	a.set_clip(clip, 0.0, 1.0)
	a.pose("work", 1.0, 0.05)
	b.pose("work", 1.0, 0.05)
	var ja := a.joint_map()
	_check((ja["shoulder_r"] as Node3D).basis.is_equal_approx(Basis(NpcAnimClip.euler_deg_to_quat(Vector3(-120, 10, 0)))),
		"a clip at full weight owns its joints")
	a.clear_clip()
	for k in 3:
		a.pose("work", 1.0, 0.05)
		b.pose("work", 1.0, 0.05)
	var jb := b.joint_map()
	var worst := 0.0
	for name in ja:
		worst = maxf(worst, ((ja[name] as Node3D).rotation - (jb[name] as Node3D).rotation).length())
	_check(worst < 1e-4, "after the clip the procedural pose is exactly back (worst %.6f rad)" % worst)
	a.queue_free()
	b.queue_free()


func _test_tools() -> void:
	var bad: Array = []
	for id in FabToolCatalog.ids():
		var t := FabToolCatalog.build(id, false)
		if t == null:
			bad.append(id + " did not build")
			continue
		var s: Dictionary = t.get_meta("sockets", {})
		var grip = s.get("grip")
		if not (grip is Transform3D) or not (grip as Transform3D).basis.is_conformal():
			bad.append(id + " grip")
		if t.get_node_or_null("Grip") == null or t.get_node_or_null("Tip") == null:
			bad.append(id + " markers")
		if not str(s.get("spin_node", "")).is_empty() and FabToolCatalog.spin_node(t) == null:
			bad.append(id + " spin node")
		var meshes := t.find_children("*", "MeshInstance3D", true, false)
		if meshes.is_empty():
			bad.append(id + " no meshes")
		t.free()
	_check(bad.is_empty(), "every tool builds with sound sockets: %s" % str(bad))
	_check(FabToolCatalog.tool_for_op("cut") == "circular_saw" and FabToolCatalog.tool_for_op("drill") == "drill"
		and FabToolCatalog.tool_for_op("fasten") == "impact_driver", "tools for the ops")
	var saw := FabToolCatalog.build("circular_saw", false)
	FabToolCatalog.set_spin(saw, 1.0)
	var blade := FabToolCatalog.spin_node(saw)
	_check(blade != null and absf(blade.basis.get_rotation_quaternion().get_angle() - 1.0) < 1e-4, "set_spin turns the blade")
	# Held in hand: the grip socket sits on the palm.
	var f := _figure()
	f.pose("idle", 1.0, 0.016)
	f.attach_tool(0, saw)
	var grip_world := saw.global_transform * ((saw.get_meta("sockets") as Dictionary)["grip"] as Transform3D)
	var palm := f.palm_global(0)
	_check(grip_world.origin.distance_to(palm.origin) < 1e-4 and grip_world.basis.is_equal_approx(palm.basis),
		"an attached tool's grip is the palm")
	_check(f.detach_tool(0) == saw and saw.get_parent() == null, "detach returns the tool unparented")
	saw.free()
	f.queue_free()
	var parsed := FabToolCatalog.parse_sockets({"grip": [0, 0.1, 0, 0, 90, 0], "tip": [0, 0, 0], "spin_node": "Bit", "spin_axis": [0, 1, 0]})
	_check((parsed["grip"] as Transform3D).origin == Vector3(0, 0.1, 0) and parsed["spin_node"] == "Bit", "override sockets parse")
	_check(FabToolCatalog.parse_sockets({"tip": [0, 0, 0]}).is_empty(), "an override with no grip is refused")


## The editor's write path (NpcAnimClip editing helpers).
func _test_clip_editing() -> void:
	var c := NpcAnimClip.from_dict({"id": "e", "length_s": 2.0, "keys": []})
	c.set_joint_at(0.5, "elbow_r", Vector3(-40, 0, 0))
	c.set_joint_at(0.5 + 0.002, "knee_l", Vector3(15, 0, 0))
	_check(c.keys.size() == 1 and (c.keys[0]["joints"] as Dictionary).size() == 2, "keys within 1/120 s merge")
	c.set_joint_at(1.5, "elbow_r", Vector3(-80, 0, 0))
	c.set_joint_at(0.2, "elbow_r", Vector3(-10, 0, 0))
	_check(c.key_times() == [0.2, 0.5, 1.5], "keys stay sorted")
	_check(c.key_times("knee_l") == [0.5], "per-joint key times")
	c.set_body_at(1.0, "y", -0.1)
	var pose := c.pose_at(1.0)
	_check(absf(float(pose["body"]["y"]) + 0.1) < 1e-6 and (pose["joints"] as Dictionary).has("elbow_r"), "pose_at reads every keyed track")
	var d := NpcAnimClip.from_dict({"id": "d", "length_s": 2.0, "keys": []})
	d.paste_pose(0.0, pose)
	var round_trip := d.pose_at(0.0)
	_check((round_trip["joints"]["elbow_r"] as Vector3).is_equal_approx(pose["joints"]["elbow_r"]), "paste then read gives the pose back")
	var m := NpcAnimClip.mirror_pose(pose)
	_check((m["joints"] as Dictionary).has("elbow_l") and not (m["joints"] as Dictionary).has("elbow_r"), "mirror_pose swaps sides")
	_check(c.remove_at(0.5, "knee_l") and c.key_times("knee_l").is_empty() and c.key_times().has(0.5),
		"removing one joint keeps the rest of the key")
	_check(c.remove_at(0.5, "elbow_r") and not c.key_times().has(0.5), "an emptied key goes")
	_check(not c.remove_at(0.77), "nothing to remove off a key")


## Every op context keeps its tool within the figure's reach for the WHOLE op,
## with the context's own clip playing (what the editor shows and the swarm
## plays).
func _test_context_rig() -> void:
	var bad: Array = []
	for kind in FabContextRig.CLIP_FOR:
		var rig := FabContextRig.setup(kind)
		var c := NpcAnimClip.load_clip(str(FabContextRig.CLIP_FOR[kind]))
		var tool_id := str(rig["tool_id"])
		var sockets: Dictionary = FabToolCatalog.sockets(tool_id) if not tool_id.is_empty() else FabContextRig.beam_sockets()
		var f := _figure()
		for u in [0.0, 0.5, 1.0]:
			var tp := FabContextRig.tool_at(rig, u)
			var xf: Transform3D = tp["xform"]
			f.set_clip(c, u * c.length_s, 1.0)
			for i in 2:
				var sock := str(c.ik.get("hand_r" if i == 0 else "hand_l", "none"))
				f.set_hand_target(i, xf * (sockets[sock] as Transform3D) if sockets.get(sock) is Transform3D else null)
			f.pose("idle", 0.0, 1.0 / 60.0)
			for i in 2:
				var sock2 := str(c.ik.get("hand_r" if i == 0 else "hand_l", "none"))
				if sockets.get(sock2) is Transform3D:
					var err := f.palm_global(i).origin.distance_to((xf * (sockets[sock2] as Transform3D)).origin)
					if err > 0.005:
						bad.append("%s u=%.1f hand %d off by %.3f m" % [kind, u, i, err])
		f.queue_free()
	_check(bad.is_empty(), "every context's tool stays within reach of its clip: %s" % str(bad))
