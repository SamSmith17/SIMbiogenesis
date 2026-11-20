extends SceneTree

## Toilets, stalls, queues and sitting (NPC life pass, Phases 2-3):
##   NpcSeatPose — a chair pose only ON a seat; ground poses elsewhere.
##   ToiletBankBuilder — stall spots face the door, sit inside the stall, one
##     door per stall, a line in front, two rows past eight.
##   ShowerHouseBuilder — a standing spot per stall facing its shower head,
##     a curtain and a spray per stall, a line in front of the porch; the full
##     tier showering one to a stall, on the deck, facing the head.
##   SpaceRegistry — stalls cap a restroom at one person per stall, ONE
##     first-come line, the expected wait priced into the choice of restroom.
##   Both tiers on a synthetic site with a 2-stall bank: never more than two
##     inside, never two in one stall, a line that forms and drains, everyone
##     inside seated facing out of the door, and nobody in a chair pose
##     without a seat under them.
## Offline, deterministic. Carries EXPECTED_CHECKS (a runtime error aborts a
## test function while PASS still prints).
##   Godot --headless --path . --script core/population/sanitation_selftest.gd

const EXPECTED_CHECKS := 65

var _checks := 0
var _failures := 0


func _initialize() -> void:
	PopTestPrefs.reset_defaults()
	NpcDisplayPrefs.reset_custom_names_for_test()
	_test_seat_pose()
	_test_bank_geometry()
	_test_registry_stalls()
	_test_full_tier_stalls()
	_test_light_tier_stalls()
	_test_bathroom_physiology()
	_test_shower_house_geometry()
	_test_shower_house_stalls()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("SANITATION SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SANITATION SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


# --- NpcSeatPose ------------------------------------------------------------------

func _test_seat_pose() -> void:
	_check("a toilet visit on a toilet is a chair pose",
		NpcSeatPose.for_activity("bladder", "", "toilet", 0.56, "a") == NpcSeatPose.CHAIR)
	_check("a toilet visit with no seat stands",
		NpcSeatPose.for_activity("bladder", "", "", 0.0, "a") == NpcSeatPose.STAND)
	_check("a meal on a bench sits on it",
		NpcSeatPose.for_activity("hunger", "", "sit", 0.46, "a") == NpcSeatPose.CHAIR)
	_check("a low seat (< 0.3 m) is the ground",
		NpcSeatPose.for_activity("hunger", "", "sit", 0.1, "a") != NpcSeatPose.CHAIR)
	var cross := 0
	var kneel := 0
	var other := 0
	for k in 400:
		var w := NpcSeatPose.for_activity("hunger", "", "", 0.0, "p_%d" % k)
		if w == NpcSeatPose.CROSS:
			cross += 1
		elif w == NpcSeatPose.KNEEL:
			kneel += 1
		else:
			other += 1
	_check("a meal on the ground: mostly cross-legged, some kneel, never a chair",
		cross > 240 and kneel > 80 and other == 0, "cross %d kneel %d other %d" % [cross, kneel, other])
	_check("the same person sits the same way at a meal",
		NpcSeatPose.for_activity("hunger", "", "", 0.0, "p_7") == NpcSeatPose.for_activity("hunger", "", "", 0.0, "p_7"))
	_check("a venue sit off a seat is a ground pose",
		NpcSeatPose.for_activity("enrichment", VenueCrowd.POSE_SIT, "", 0.0, "a")
			in [NpcSeatPose.CROSS, NpcSeatPose.LOUNGE, NpcSeatPose.KNEEL])
	_check("dancing has no sitting opinion",
		NpcSeatPose.for_activity("enrichment", VenueCrowd.POSE_DANCE, "", 0.0, "a") == "")
	_check("pose words map to the crowd codes",
		NpcSeatPose.crowd_code_for(NpcSeatPose.CHAIR) == CrowdCohort.POSE_SIT
			and NpcSeatPose.crowd_code_for(NpcSeatPose.SQUAT) == CrowdCohort.POSE_SQUAT
			and NpcSeatPose.crowd_code_for("") == -1)


# --- ToiletBankBuilder -----------------------------------------------------------

func _test_bank_geometry() -> void:
	var spots := ToiletBankBuilder.stall_spots({"stalls": 4})
	_check("one seat per stall", spots.size() == 4)
	var faces_door := true
	var inside := true
	var door_ahead := true
	for sp: Dictionary in spots:
		var yaw := float(sp["yaw"])
		var facing := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var pos: Vector3 = sp["pos"]
		var door: Vector3 = sp["door"]
		var to_door := Vector3(door.x - pos.x, 0.0, door.z - pos.z).normalized()
		if facing.dot(to_door) < 0.95:
			faces_door = false
		if absf(pos.z) > ToiletBankBuilder.STALL_D * 0.5:
			inside = false
		if door.z <= pos.z:
			door_ahead = false
	_check("every seat faces its door", faces_door)
	_check("every seat is inside its stall", inside)
	_check("every door is in front of its seat", door_ahead)
	_check("seat height = a toilet seat over the stall floor",
		is_equal_approx(float((spots[0] as Dictionary)["pos"].y), ToiletBankBuilder.SEAT_TOP))
	var xs: Array = []
	for sp: Dictionary in spots:
		xs.append(snappedf(float((sp["pos"] as Vector3).x), 0.01))
	var uniq: Dictionary = {}
	for x in xs:
		uniq[x] = true
	_check("stalls stand apart along the row", uniq.size() == 4)
	var big := ToiletBankBuilder.resolve({"stalls": 12})
	_check("twelve stalls stand in two rows of six", int(big["rows"]) == 2
		and ToiletBankBuilder.row_count(big, 0) == 6 and ToiletBankBuilder.row_count(big, 1) == 6)
	var big_spots := ToiletBankBuilder.stall_spots({"stalls": 12})
	var back_faces := 0
	for sp: Dictionary in big_spots:
		if int(sp["row"]) == 1 and float((sp["door"] as Vector3).z) < float((sp["pos"] as Vector3).z):
			back_faces += 1
	_check("the back row's doors face the other way", back_faces == 6)
	var line := ToiletBankBuilder.queue_line({"stalls": 4})
	var q0 := ToiletBankBuilder.queue_point(line, 0)
	var q9 := ToiletBankBuilder.queue_point(line, 9)
	_check("the line starts in front of the doors", q0.z > (spots[0] as Dictionary)["door"].z)
	_check("a long line bends sideways", absf(q9.x - q0.x) > 1.0)


# --- SpaceRegistry ------------------------------------------------------------------

func _square(c: Vector2, half: float) -> Array:
	return [[c.x - half, c.y - half], [c.x + half, c.y - half], [c.x + half, c.y + half], [c.x - half, c.y + half]]


func _test_registry_stalls() -> void:
	var reg := SpaceRegistry.create_empty()
	var sid := reg.set_space_type({"kind": "area", "poly": _square(Vector2(10, 0), 3)}, "restroom", 0)
	reg.set_stalls(sid, 2)
	_check("stalls cap a restroom", reg.claim(sid, "a") and reg.claim(sid, "b") and not reg.claim(sid, "c"))
	reg.queue_join(sid, "c")
	reg.queue_join(sid, "d")
	reg.release(sid, "a")
	_check("only the head of the line takes the free stall", not reg.claim(sid, "d") and reg.claim(sid, "c"))
	_check("the line moved up", reg.queue_index(sid, "d") == 0 and reg.queue_len(sid) == 1)
	var w1 := reg.expected_wait_h(sid)
	reg.queue_join(sid, "e")
	reg.queue_join(sid, "f")
	_check("the expected wait grows with the line", reg.expected_wait_h(sid) > w1)
	# Choice: a restroom 40 m further with free stalls beats a long line here.
	var reg2 := SpaceRegistry.create_empty()
	var near := reg2.set_space_type({"kind": "area", "poly": _square(Vector2(10, 0), 3)}, "restroom", 0)
	var far := reg2.set_space_type({"kind": "area", "poly": _square(Vector2(50, 0), 3)}, "restroom", 0)
	reg2.set_stalls(near, 2)
	reg2.set_stalls(far, 2)
	reg2.refresh_positions(func(space: Dictionary) -> Variant:
		return reg2.resolve_position(space, null))
	_check("an empty restroom: the nearest wins",
		str(reg2.nearest_space_by("restroom", Vector2.ZERO, Callable(), true).get("id", "")) == near)
	reg2.claim(near, "x1")
	reg2.claim(near, "x2")
	for k in 6:
		reg2.queue_join(near, "q%d" % k)
	_check("a line of six beats a 40 m walk to free stalls",
		str(reg2.nearest_space_by("restroom", Vector2.ZERO, Callable(), true).get("id", "")) == far)
	_check("a full restroom with stalls is still a choice (you queue)",
		not reg2.nearest_space_by("restroom", Vector2(10, 0), Callable(), true).is_empty())
	reg.release_all_for_agent("e")
	_check("leaving drops a person from the line", reg.queue_index(sid, "e") < 0)


# --- both tiers on a 2-stall bank ----------------------------------------------------

const BANK_AT := Vector2(-60.0, 30.0)


func _site() -> SpaceRegistry:
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(60, 0), 8)}, "kitchen", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, 70), 8)}, "water_point", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, -80), 12)}, "sleep", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-45, -45), 8)}, "shower", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(55, 55), 8)}, "fire_circle", 0)
	var sid := reg.set_space_type({"kind": "area", "poly": _square(BANK_AT, 4)}, "restroom", 0)
	reg.set_stalls(sid, 2)
	reg.refresh_positions(func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null))
	return reg


func _restroom_id(reg: SpaceRegistry) -> String:
	return str((reg.spaces_of_type("restroom")[0] as Dictionary)["id"])


func _bank_spots() -> Array:
	var out: Array = []
	for sp: Dictionary in ToiletBankBuilder.stall_spots({"stalls": 2}):
		var p: Vector3 = sp["pos"]
		var d: Vector3 = sp["door"]
		out.append({"pos": BANK_AT + Vector2(p.x, p.z), "yaw": float(sp["yaw"]), "elev": p.y,
			"kind": NpcSeatPose.KIND_TOILET, "door": BANK_AT + Vector2(d.x, d.z)})
	return out


func _ctx_extras(reg: SpaceRegistry) -> Dictionary:
	var spots := _bank_spots()
	var rid := _restroom_id(reg)
	var line := ToiletBankBuilder.queue_line({"stalls": 2})
	return {
		"seat_spot_of": func(sid: String, k: int) -> Dictionary:
			return spots[k % spots.size()] if sid == rid else {},
		"queue_spot_of": func(sid: String, k: int) -> Variant:
			if sid != rid:
				return null
			var q := ToiletBankBuilder.queue_point(line, k)
			return BANK_AT + Vector2(q.x, q.z),
	}


class StallTally:
	var max_inside := 0
	var max_line := 0
	var two_in_one := 0
	var inside_samples := 0
	var not_on_seat := 0
	var not_facing := 0
	var chair_no_seat := 0
	var visits := 0


func _tally_stalls(t: StallTally, reg: SpaceRegistry, sid: String, people: Array) -> void:
	# people: [{pos, activity, doing, seat, elev, face}] for this instant.
	var spots := _bank_spots()
	t.max_inside = maxi(t.max_inside, reg.occupant_count(sid))
	t.max_line = maxi(t.max_line, reg.queue_len(sid))
	var at_stall: Array = [0, 0]
	for p: Dictionary in people:
		if not bool(p["doing"]) or str(p["activity"]) != "bladder":
			continue
		t.inside_samples += 1
		var best := -1
		var best_d := INF
		for k in spots.size():
			var d := (p["pos"] as Vector2).distance_to((spots[k] as Dictionary)["pos"])
			if d < best_d:
				best_d = d
				best = k
		if best_d > 0.3:
			t.not_on_seat += 1
		else:
			at_stall[best] = int(at_stall[best]) + 1
			var yaw := float((spots[best] as Dictionary)["yaw"])
			var want := Vector2(-sin(yaw), -cos(yaw))
			var face: Vector2 = p["face"]
			if face.length() > 0.1 and face.normalized().dot(want) < 0.9:
				t.not_facing += 1
		if str(p["seat"]) != NpcSeatPose.KIND_TOILET or float(p["elev"]) < NpcSeatPose.CHAIR_MIN_ELEV:
			t.chair_no_seat += 1
	for c in at_stall:
		if int(c) > 1:
			t.two_in_one += 1


func _report(tier: String, t: StallTally) -> void:
	print("  %s: inside max %d, line max %d, samples %d, off-seat %d, not facing %d, no-seat %d"
		% [tier, t.max_inside, t.max_line, t.inside_samples, t.not_on_seat, t.not_facing, t.chair_no_seat])
	_check("%s: never more inside than stalls" % tier, t.max_inside <= 2)
	_check("%s: a line forms when both stalls are taken" % tier, t.max_line >= 1)
	_check("%s: never two people in one stall" % tier, t.two_in_one == 0)
	_check("%s: everyone using a toilet is on its seat" % tier, t.inside_samples > 0 and t.not_on_seat == 0,
		"%d of %d" % [t.not_on_seat, t.inside_samples])
	_check("%s: seated facing out of the door" % tier, t.not_facing == 0, "%d" % t.not_facing)
	_check("%s: a toilet visit always has a toilet seat under it" % tier, t.chair_no_seat == 0)


func _test_full_tier_stalls() -> void:
	var reg := _site()
	var rid := _restroom_id(reg)
	var e := NpcPopulationEngine.new()
	e.configure(24, "stall", Vector2.ZERO)
	e.routine = NpcRoutine.default_day()
	var pos_of := func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null)
	var extras := _ctx_extras(reg)
	var tally := StallTally.new()
	var t := 7.0
	var step := 1.0 / 60.0
	while t < 7.0 + 24.0:
		var ctx := {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(t, 24.0),
			"abs_hours": t, "camp_home": Vector2.ZERO, "camp_seed": "stall", "routine": e.routine}
		ctx.merge(extras)
		e.tick(t, ctx)
		var people: Array = []
		for a: NpcAgent in e.agents:
			var face := Vector2.ZERO
			if a.face_anchor != Vector2.INF:
				face = a.face_anchor - a.pos
			people.append({"pos": a.pos, "activity": a.activity, "doing": a.state == NpcAgent.State.DOING,
				"seat": a.seat_kind, "elev": a.seat_elev, "face": face})
		_tally_stalls(tally, reg, rid, people)
		t += step
	_report("full tier", tally)


func _test_light_tier_stalls() -> void:
	var reg := _site()
	var rid := _restroom_id(reg)
	var c := CrowdCohort.new()
	c.configure(24, "stall", Vector2.ZERO)
	c.routine = NpcRoutine.default_day()
	var extras := _ctx_extras(reg)
	var tally := StallTally.new()
	var t := 7.0
	var step := 1.0 / 60.0
	var pose_ok := true
	while t < 7.0 + 24.0:
		var ctx := {"registry": reg, "hour_of_day": fposmod(t, 24.0), "abs_hours": t, "routine": c.routine}
		ctx.merge(extras)
		c.tick(t, ctx)
		var people: Array = []
		for i in c.count():
			if c.alive[i] != 1:
				continue
			var doing := int(c.state[i]) == CrowdCohort.S_DOING
			var p := c.pos_at(i, t)
			var face := Vector2.ZERO
			if not is_nan(c.fx[i]):
				face = Vector2(c.fx[i], c.fz[i]) - p
			people.append({"pos": p, "activity": str(CrowdCohort.ACT_NAMES[c.act[i]]), "doing": doing,
				"seat": c.seat_kind_of(i), "elev": c.elev_of(i), "face": face})
			if doing and int(c.act[i]) == CrowdCohort.A_BLADDER and c.pose_code(i) != CrowdCohort.POSE_SIT:
				pose_ok = false
		_tally_stalls(tally, reg, rid, people)
		t += step
	_report("light tier", tally)
	_check("light tier: a toilet visit is drawn seated", pose_ok)


## NpcBathroom: per-person counts in the design ranges, the camp spread over
## them, poo hours after waking, poop_due / next_poop agreeing, visit lengths.
func _test_bathroom_physiology() -> void:
	var pees := {}
	var two := 0
	var lo := 99
	var hi := 0
	for k in 400:
		var id := "camp_npc_%d" % k
		var n := NpcBathroom.pees_per_day(id)
		lo = mini(lo, n)
		hi = maxi(hi, n)
		pees[n] = int(pees.get(n, 0)) + 1
		if NpcBathroom.poops_per_day(id) == 2:
			two += 1
	_check("pee count inside 3-6", lo >= NpcBathroom.PEES_MIN and hi <= NpcBathroom.PEES_MAX, "%d..%d" % [lo, hi])
	_check("every pee count 3-6 occurs", pees.size() == 4, str(pees))
	var share := float(two) / 400.0
	_check("share with two poos near the table", absf(share - NpcBathroom.TWO_POOP_SHARE) < 0.08, "%.2f" % share)
	# A faster pee count fills faster, and the fill gives the count over a day.
	var a := ""
	var b := ""
	for k in 400:
		var id := "camp_npc_%d" % k
		if a == "" and NpcBathroom.pees_per_day(id) == 3:
			a = id
		if b == "" and NpcBathroom.pees_per_day(id) == 6:
			b = id
	_check("six-a-day fills faster than three-a-day",
		NpcBathroom.bladder_rise(b) > NpcBathroom.bladder_rise(a) * 1.5)
	var trips := NpcBathroom.bladder_rise(b) * NpcBathroom.AWAKE_H / NpcBathroom.THRESHOLD + NpcBathroom.DRINK_TRIPS
	_check("fill rate gives the person's count", absf(trips - 6.0) < 0.01, "%.2f" % trips)
	# Poo hours: the first after waking, the second (if any) later; days differ.
	var hrs: Array = NpcBathroom.poop_hours(b, 10, 7.0)
	_check("first poo within 2 h of waking", float(hrs[0]) >= 7.3 and float(hrs[0]) <= 9.0, str(hrs))
	var differ := false
	for d in range(11, 18):
		if absf(float(NpcBathroom.poop_hours(b, d, 7.0)[0]) - float(hrs[0])) > 0.05:
			differ = true
	_check("poo hour changes day to day", differ)
	# poop_due over a span finds exactly what next_poop predicts.
	var start := 24.0 * 100.0 + 3.0
	var nxt := NpcBathroom.next_poop(b, start, 7.0)
	var due := NpcBathroom.poop_due(b, start, nxt + 0.01, 7.0)
	_check("poop_due finds next_poop", absf(due - nxt) < 1e-6, "%f vs %f" % [due, nxt])
	# Visit lengths: a pee is short, a poo 6-11 min.
	var pee := NpcBathroom.visit_h(b, false, "1")
	var poo := NpcBathroom.visit_h(b, true, "1")
	_check("pee shorter than poo, poo 6-11 min",
		pee < poo and poo * 60.0 >= 6.0 and poo * 60.0 <= 11.0 + 1e-6, "%.1f / %.1f min" % [pee * 60.0, poo * 60.0])


# --- ShowerHouseBuilder ------------------------------------------------------------

func _test_shower_house_geometry() -> void:
	var spots := ShowerHouseBuilder.stall_spots({"stalls": 4})
	_check("shower house: one standing spot per stall", spots.size() == 4)
	var ok_kind := true
	var faces_head := true
	var inside := true
	var door_ahead := true
	for sp: Dictionary in spots:
		var pos: Vector3 = sp["pos"]
		var door: Vector3 = sp["door"]
		if str(sp["kind"]) != NpcSeatPose.KIND_STAND or not bool(sp.get("shower", false)):
			ok_kind = false
		var yaw := float(sp["yaw"])
		var facing := Vector3(-sin(yaw), 0.0, -cos(yaw))
		# The head is on the back wall: row 0's back is -Z.
		if facing.dot(Vector3(0.0, 0.0, -1.0)) < 0.95:
			faces_head = false
		if absf(pos.z) > ShowerHouseBuilder.STALL_D * 0.5:
			inside = false
		if door.z <= pos.z + ShowerHouseBuilder.STALL_D * 0.5:
			door_ahead = false
	_check("shower house: spots are standing shower spots", ok_kind)
	_check("shower house: everyone faces the shower head", faces_head)
	_check("shower house: every spot is inside its stall", inside)
	_check("shower house: every door point is out past the porch", door_ahead)
	_check("shower house: standing on the deck", is_equal_approx(
		float(((spots[0] as Dictionary)["pos"] as Vector3).y), ShowerHouseBuilder.FLOOR_Y))
	var big := ShowerHouseBuilder.resolve({"stalls": 9})
	_check("shower house: nine stalls stand in two rows (5 + 4)", int(big["rows"]) == 2
		and ShowerHouseBuilder.row_count(big, 0) == 5 and ShowerHouseBuilder.row_count(big, 1) == 4)
	var back := 0
	for sp: Dictionary in ShowerHouseBuilder.stall_spots({"stalls": 9}):
		if int(sp["row"]) == 1 and float((sp["door"] as Vector3).z) < float((sp["pos"] as Vector3).z):
			back += 1
	_check("shower house: the back row faces the other way", back == 4)
	var node := ShowerHouseBuilder.build_node({"stalls": 4})
	var curtains := node.get_node_or_null("Curtains")
	var sprays := node.get_node_or_null("Sprays")
	var sprays_off := sprays != null and sprays.get_child_count() == 4
	if sprays != null:
		for c in sprays.get_children():
			if not (c is GPUParticles3D) or (c as GPUParticles3D).emitting:
				sprays_off = false
	_check("shower house: a curtain and a spray per stall, the water off",
		curtains != null and curtains.get_child_count() == 4 and sprays_off)
	var cloth := node.get_node_or_null("Curtains/C0/Cloth")
	_check("shower house: curtains never collide", cloth != null and bool(cloth.get_meta("skip_prop_collision", false)))
	var line := ShowerHouseBuilder.queue_line({"stalls": 4})
	_check("shower house: the line starts in front of the porch",
		float((line["origin"] as Vector3).z) > ShowerHouseBuilder.STALL_D * 0.5 + ShowerHouseBuilder.PORCH)
	node.free()


const SHOWER_AT := Vector2(-45.0, -45.0)


func _shower_spots() -> Array:
	var out: Array = []
	for sp: Dictionary in ShowerHouseBuilder.stall_spots({"stalls": 2}):
		var p: Vector3 = sp["pos"]
		var d: Vector3 = sp["door"]
		out.append({"pos": SHOWER_AT + Vector2(p.x, p.z), "yaw": float(sp["yaw"]), "elev": p.y,
			"kind": NpcSeatPose.KIND_STAND, "door": SHOWER_AT + Vector2(d.x, d.z)})
	return out


func _test_shower_house_stalls() -> void:
	var reg := _site()
	var shid := str((reg.spaces_of_type("shower")[0] as Dictionary)["id"])
	reg.set_stalls(shid, 2)
	var base := _ctx_extras(reg)
	var rid := _restroom_id(reg)
	var spots := _shower_spots()
	var line := ShowerHouseBuilder.queue_line({"stalls": 2})
	var seat_toilet: Callable = base["seat_spot_of"]
	var queue_toilet: Callable = base["queue_spot_of"]
	var extras := {
		"seat_spot_of": func(sid: String, k: int) -> Dictionary:
			if sid == shid:
				return spots[k % spots.size()]
			return seat_toilet.call(sid, k),
		"queue_spot_of": func(sid: String, k: int) -> Variant:
			if sid == shid:
				var q := ShowerHouseBuilder.queue_point(line, k)
				return SHOWER_AT + Vector2(q.x, q.z)
			return queue_toilet.call(sid, k),
	}
	var e := NpcPopulationEngine.new()
	e.configure(24, "shower", Vector2.ZERO)
	e.routine = NpcRoutine.default_day()
	var pos_of := func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null)
	var t := 7.0
	var step := 1.0 / 60.0
	var max_inside := 0
	var visits := 0
	var off_spot := 0
	var not_facing := 0
	var wrong_elev := 0
	var two_in_one := 0
	while t < 7.0 + 26.0:
		var ctx := {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(t, 24.0),
			"abs_hours": t, "camp_home": Vector2.ZERO, "camp_seed": "shower", "routine": e.routine}
		ctx.merge(extras)
		e.tick(t, ctx)
		max_inside = maxi(max_inside, reg.occupant_count(shid))
		var at: Array = [0, 0]
		for a: NpcAgent in e.agents:
			if a.state != NpcAgent.State.DOING or a.activity != "hygiene":
				continue
			visits += 1
			var best := -1
			var best_d := INF
			for k in spots.size():
				var d := a.pos.distance_to((spots[k] as Dictionary)["pos"])
				if d < best_d:
					best_d = d
					best = k
			if best_d > 0.3:
				off_spot += 1
				continue
			at[best] = int(at[best]) + 1
			var yaw := float((spots[best] as Dictionary)["yaw"])
			var face := a.face_anchor - a.pos if a.face_anchor != Vector2.INF else Vector2.ZERO
			if face.length() > 0.1 and face.normalized().dot(Vector2(-sin(yaw), -cos(yaw))) < 0.9:
				not_facing += 1
			if not is_equal_approx(a.seat_elev, ShowerHouseBuilder.FLOOR_Y):
				wrong_elev += 1
		for c in at:
			if int(c) > 1:
				two_in_one += 1
		t += step
	print("  shower house: inside max %d, samples %d, off-spot %d, not facing %d, elev %d"
		% [max_inside, visits, off_spot, not_facing, wrong_elev])
	_check("shower house: never more showering than stalls", max_inside <= 2)
	_check("shower house: people shower in it", visits > 0)
	_check("shower house: never two in one stall", two_in_one == 0)
	_check("shower house: everyone showering stands on a stall's spot", off_spot == 0,
		"%d of %d" % [off_spot, visits])
	_check("shower house: facing the head, on the deck", not_facing == 0 and wrong_elev == 0,
		"facing %d elev %d" % [not_facing, wrong_elev])
