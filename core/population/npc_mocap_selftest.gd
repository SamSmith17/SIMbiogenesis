extends SceneTree

## MO-CAP SPICE self-test: NpcMocapSpice (when a stick figure breaks into a
## clip), NpcStickMocap.solve_points (a mo-cap pose -> the stick figure's
## joints, on synthetic poses — no art needed), and, when the NPC pack is
## installed, the figure itself: a forced clip fades IN, and when it ends the
## body fades back to EXACTLY the pose an identical figure that never left
## procedural is in — the seamless-return contract. Carries EXPECTED_CHECKS
## (a runtime error aborts a test function while PASS still prints).
##   Godot --headless --path . --script core/population/npc_mocap_selftest.gd

const EXPECTED_CHECKS := 14

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_spice()
	_test_solver()
	await _test_figure_return()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("NPC MOCAP SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("NPC MOCAP SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_spice() -> void:
	_check("moments come from what the figure is doing (walking never)",
		NpcMocapSpice.moment_for(NpcRig.CLIP_PEAK_DANCE, "") == "peak"
		and NpcMocapSpice.moment_for(NpcRig.CLIP_IDLE, "cheer") == "cheer"
		and NpcMocapSpice.moment_for(NpcRig.CLIP_DANCE, "rave") == "dance"
		and NpcMocapSpice.moment_for(NpcRig.CLIP_IDLE, "talk") == "talk"
		and NpcMocapSpice.moment_for(NpcRig.CLIP_SIT, "") == "sit"
		and NpcMocapSpice.moment_for(NpcRig.CLIP_WALK, "") == ""
		and NpcMocapSpice.moment_for(NpcRig.CLIP_SLEEP, "") == "")
	_check("spice 0 = never; 0.5 = the table; 1 = twice as often, capped",
		NpcMocapSpice.chance_at("dance", 0.0) == 0.0
		and is_equal_approx(NpcMocapSpice.chance_at("dance", 0.5), float(NpcMocapSpice.MOMENTS["dance"]["chance"]))
		and NpcMocapSpice.chance_at("peak", 1.0) == 1.0)
	_check("no clip for a moment = no spice (the procedural pose carries on)",
		NpcMocapSpice.pick("a_npc_1", "peak", 0, 1.0, []) == "")
	var hits := 0
	var same := true
	for i in 400:
		var c := NpcMocapSpice.pick("sp_npc_%d" % i, "dance", 3, 0.5, ["x", "y"])
		if not c.is_empty():
			hits += 1
		same = same and c == NpcMocapSpice.pick("sp_npc_%d" % i, "dance", 3, 0.5, ["x", "y"])
	var rate := float(hits) / 400.0
	_check("rolls are deterministic per person and land near the chance (%.2f)" % rate,
		same and absf(rate - NpcMocapSpice.chance_at("dance", 0.5)) < 0.08)
	_check("a looping moment holds for its max; a one-shot for its length",
		NpcMocapSpice.hold_s("dance", 3.0, 1.0) == float(NpcMocapSpice.MOMENTS["dance"]["max_s"])
		and is_equal_approx(NpcMocapSpice.hold_s("cheer", 3.0, 1.0), 3.0)
		and is_equal_approx(NpcMocapSpice.hold_s("cheer", 3.0, 2.0), 1.5))


## A synthetic pose in FIGURE space: standing, arms out to the sides (a
## T-pose), at the stick figure's own hip height.
func _t_pose() -> Dictionary:
	var hy := 0.86
	return {"points": {
		"Hips": Vector3(0, hy, 0), "Neck": Vector3(0, 1.45, 0), "Head": Vector3(0, 1.55, 0),
		"LeftArm": Vector3(0.2, 1.4, 0), "LeftForeArm": Vector3(0.5, 1.4, 0), "LeftHand": Vector3(0.78, 1.4, 0),
		"RightArm": Vector3(-0.2, 1.4, 0), "RightForeArm": Vector3(-0.5, 1.4, 0), "RightHand": Vector3(-0.78, 1.4, 0),
		"LeftUpLeg": Vector3(0.1, hy, 0), "LeftLeg": Vector3(0.1, 0.44, 0), "LeftFoot": Vector3(0.1, 0.05, 0),
		"RightUpLeg": Vector3(-0.1, hy, 0), "RightLeg": Vector3(-0.1, 0.44, 0), "RightFoot": Vector3(-0.1, 0.05, 0)},
		"hips_delta": Basis(), "head_delta": Basis()}


func _test_solver() -> void:
	var s := NpcStickMocap.solve_points(_t_pose(), {"hip_y": 0.86, "scale": 1.0})
	_check("a standing pose puts the body where the stick figure stands",
		(s["body_pos"] as Vector3).length() < 1e-4 and (s["body_basis"] as Basis).is_equal_approx(Basis()))
	var r_up: Basis = (s["shoulder"] as Array)[0]
	var l_up: Basis = (s["shoulder"] as Array)[1]
	_check("T-pose arms: the RIGHT arm (index 0) points -X, the LEFT +X",
		(r_up * Vector3.DOWN).distance_to(Vector3(-1, 0, 0)) < 1e-3
		and (l_up * Vector3.DOWN).distance_to(Vector3(1, 0, 0)) < 1e-3)
	var el: Basis = (s["elbow"] as Array)[1]
	_check("...and the forearm carries straight on (elbow local = identity)",
		(el * Vector3.DOWN).distance_to(Vector3.DOWN) < 1e-3)
	var thigh: Basis = (s["hip"] as Array)[0]
	_check("straight legs hang straight down", (thigh * Vector3.DOWN).distance_to(Vector3.DOWN) < 1e-3)
	# A bow: hips pitched forward 30 degrees, spine following it.
	var bow := _t_pose()
	var pitch := Basis(Vector3.RIGHT, deg_to_rad(30.0))
	bow["hips_delta"] = pitch
	var pts: Dictionary = bow["points"]
	pts["Neck"] = Vector3(0, 0.86, 0) + pitch * Vector3(0, 0.59, 0)
	var s2 := NpcStickMocap.solve_points(bow, {"hip_y": 0.86, "scale": 1.0})
	var torso_up: Vector3 = ((s2["body_basis"] as Basis) * (s2["torso"] as Basis)) * Vector3.UP
	_check("a bow tips the torso with the spine (%.2f)" % torso_up.angle_to(pitch * Vector3.UP),
		torso_up.angle_to(pitch * Vector3.UP) < 0.02)
	_check("the shortest arc is antiparallel-safe",
		(Basis(NpcStickMocap.arc(Vector3.DOWN, Vector3.UP)) * Vector3.DOWN).distance_to(Vector3.UP) < 1e-4)


## With the pack installed: fade in, play, fade back to the procedural pose.
func _test_figure_return() -> void:
	await process_frame
	var clip := ""
	for m in ["peak", "dance", "cheer"]:
		var cl: Array = NpcRig.moment_clips(m)
		if not cl.is_empty():
			clip = str(cl[0])
			break
	if clip.is_empty():
		print("  SKIP: NPC pack not installed — the figure checks run with Imported Models/NPC present")
		for i in 3:
			_check("(skipped: no NPC pack)", true)
		return
	var a := NpcSimpleFigure.new()
	var b := NpcSimpleFigure.new()
	root.add_child(a)
	root.add_child(b)
	a.setup("mcret_npc_0", Color.WHITE)
	b.setup("mcret_npc_0", Color.WHITE)
	var dt := 1.0 / 60.0
	for i in 30:
		a.pose(NpcRig.CLIP_DANCE, 1.0, dt, "")
		b.pose(NpcRig.CLIP_DANCE, 1.0, dt, "")
	var forced: bool = b.force_mocap(clip, "cheer", 1.0)
	var peak_w := 0.0
	var moved := 0.0
	for i in 60:
		a.pose(NpcRig.CLIP_DANCE, 1.0, dt, "")
		b.pose(NpcRig.CLIP_DANCE, 1.0, dt, "")
		peak_w = maxf(peak_w, b.mocap_weight())
		moved = maxf(moved, _pose_gap(a, b))
	_check("a forced clip takes the body (weight %.2f, gap from procedural %.2f rad)" % [peak_w, moved],
		forced and peak_w > 0.99 and moved > 0.1)
	# Let it run out and fade.
	for i in 60 * 14:
		a.pose(NpcRig.CLIP_DANCE, 1.0, dt, "")
		b.pose(NpcRig.CLIP_DANCE, 1.0, dt, "")
	_check("the clip ends and hands the body back (weight %.2f)" % b.mocap_weight(), b.mocap_weight() == 0.0)
	var gap := _pose_gap(a, b)
	_check("...landing EXACTLY on the procedural pose (gap %.5f rad)" % gap, gap < 1e-4)
	a.queue_free()
	b.queue_free()


## Largest joint rotation difference between two figures (radians).
func _pose_gap(a: NpcSimpleFigure, b: NpcSimpleFigure) -> float:
	var ja: Array = a.call("_joints")
	var jb: Array = b.call("_joints")
	var worst := 0.0
	for i in ja.size():
		var qa := (ja[i] as Node3D).basis.get_rotation_quaternion()
		var qb := (jb[i] as Node3D).basis.get_rotation_quaternion()
		worst = maxf(worst, qa.angle_to(qb))
	return worst
