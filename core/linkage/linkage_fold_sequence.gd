class_name LinkageFoldSequence
extends RefCounted
## Sequential fold (port of `js/linkage/fold-sequence.js`, A3).
##
## With a radial array the structures can fold and unfold one at a time
## instead of all at once. The fold angle then acts as a MASTER progress p in
## [0, 1] across the sweep range: copy j (in deploy order) has local progress
## clamp(p·K − j, 0, 1), so unfolding runs copy 0, then copy 1, … and folding
## packs the last copy first. Deploy order: the centre structure first when
## present and visible, then the ring copies in slot order.
##
## Pure. Config key: `mode.sequentialFold` (rides `LinkageParams.extra`).
## The builder turns the schedule into one solve per distinct angle (at most
## three: folded, deployed and the moving copy).
##
## Not ported: per-segment sequential fold of an ARCH TUNNEL array (the web
## solves those with arrayCount 1 and replicates each segment at its own
## angle); the game's tunnel copies still fold together.


static func is_sequential(p: LinkageParams) -> bool:
	var mode = p.extra.get("mode", {})
	return mode is Dictionary and bool((mode as Dictionary).get("sequentialFold", false))


static func set_sequential(p: LinkageParams, on: bool) -> void:
	var mode = p.extra.get("mode", {})
	if not (mode is Dictionary):
		mode = {}
	(mode as Dictionary)["sequentialFold"] = on
	p.extra["mode"] = mode


## The sweep every fold animation uses (`getFoldSweepRange`): from the
## effective minimum fold angle to the stop angle or the closed angle,
## whichever is smaller. Radians.
static func sweep_range(p: LinkageParams) -> Dictionary:
	var mn := LinkageKinematics.effective_min_fold_angle(p)
	var closed := LinkageKinematics.optimal_closed_angle(p)
	var stop := deg_to_rad(p.animation_stop_angle) if p.animation_stop_angle >= 0.0 else closed
	var mx := minf(stop, closed)
	if not (mx > mn):
		mx = maxf(mn + deg_to_rad(1.0), p.fold_angle if p.fold_angle > mn else mn)
	return {"min": mn, "max": mx}


## Deploy order of the copies (`deployOrder`, radial only): centre first,
## then the ring copies by slot.
static func deploy_order(radial_plan: Dictionary) -> Array:
	var slots: Array = []
	if radial_plan.is_empty():
		slots = [{"slot": 0, "is_center": true}]
	else:
		for sl in radial_plan.get("slots", []):
			if not bool(sl.get("hidden", false)):
				slots.append(sl)
	var ordered: Array = []
	for sl in slots:
		if bool(sl.get("is_center", false)):
			ordered.append(sl)
	var ring: Array = []
	for sl in slots:
		if not bool(sl.get("is_center", false)):
			ring.append(sl)
	ring.sort_custom(func(a, b): return int(a["slot"]) < int(b["slot"]))
	ordered.append_array(ring)
	var multi := slots.size() > 1
	var out: Array = []
	for sl in ordered:
		var label := "Structure"
		if multi:
			label = "Center" if bool(sl.get("is_center", false)) \
				else "Copy %d" % (int(sl.get("ring_index", sl["slot"])) + 1)
		out.append({"order": out.size(), "slot": int(sl["slot"]),
			"is_center": bool(sl.get("is_center", false)), "label": label})
	return out


static func master_progress(angle: float, mn: float, mx: float) -> float:
	if not (mx > mn):
		return 1.0
	return clampf((angle - mn) / (mx - mn), 0.0, 1.0)


static func copy_progress(p: float, j: int, k: int) -> float:
	return clampf(p * k - j, 0.0, 1.0)


## Per-copy fold angles for a master angle (`computeFoldSchedule`).
## Returns {sequential, k, p, min, max, copies:[{slot, label, progress,
## angle}], distinct_angles, active_index, angle_of: {slot: angle}}.
static func schedule(master_angle: float, mn: float, mx: float, order: Array, sequential: bool) -> Dictionary:
	var list := order if not order.is_empty() else deploy_order({})
	var k := list.size()
	var seq := sequential and k > 1
	var p := master_progress(master_angle, mn, mx)
	var copies: Array = []
	var distinct: Array = []
	var angle_of := {}
	for j in k:
		var e: Dictionary = (list[j] as Dictionary).duplicate()
		var prog := copy_progress(p, j, k) if seq else p
		var ang := mn + prog * (mx - mn) if seq else master_angle
		e["progress"] = prog
		e["angle"] = ang
		copies.append(e)
		angle_of[int(e["slot"])] = ang
		var seen := false
		for a in distinct:
			if absf(float(a) - ang) < 1e-9:
				seen = true
		if not seen:
			distinct.append(ang)
	var active := -1
	if seq:
		for j in k:
			var pr := float(copies[j]["progress"])
			if pr > 0.0 and pr < 1.0:
				active = j
				break
		if active < 0:
			if p <= 0.0:
				active = 0
			elif p >= 1.0:
				active = k - 1
			else:
				active = mini(k - 1, int(floor(p * k)))
	return {"sequential": seq, "k": k, "p": p, "min": mn, "max": mx, "copies": copies,
		"distinct_angles": distinct, "active_index": active, "angle_of": angle_of}


## The schedule for a design at `master_angle`, or {} when it does not fold
## in sequence (option off, no radial array, or a single copy).
static func for_params(p: LinkageParams, master_angle: float) -> Dictionary:
	if not is_sequential(p):
		return {}
	var pl := LinkageRadialArray.deployed_plan(p)
	if pl.is_empty():
		return {}
	var order := deploy_order(pl)
	if order.size() <= 1:
		return {}
	var r := sweep_range(p)
	return schedule(master_angle, float(r["min"]), float(r["max"]), order, true)
