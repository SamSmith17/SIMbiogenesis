extends SceneTree

## Headless self-test for the venue choreography and the capacity-sharing
## rules (core/population/venue_crowd.gd, npc_venue_state.gd, the AUTO
## capacity in SpaceRegistry and NpcVenueChoice):
##  - the effigy's phases as a pure function of a FireTimeline record (idle →
##    burning → circling for CIRCLE_H → after), with the phase-end caps;
##  - the burn ring: rows fill front to back, every seat outside the safe
##    radius, rings further apart and seats looser the further out (the crowd
##    THINS with distance), no two seats on top of each other, the front row
##    sitting or lying and the back rows standing;
##  - the circle dance: constant radius per lane, angle INCREASING with time
##    (counter-clockwise seen from above: east toward north), lanes shearing,
##    about half dancing;
##  - the after/idle spiral at a stand-off distance;
##  - the stage fan: every slot in FRONT of the stage's front edge, densest at
##    the front, the front edge found from the footprint, facing toward the
##    camps;
##  - NpcVenueState: a stage's set is a pull, the burn is an EVENT;
##  - AUTO capacity: never full, claims never refused, load shared by distance
##    + crowding (two equal restrooms split 6 arrivals 3/3; a crowded nearer
##    space loses to a farther empty one), an explicit cap still refuses;
##  - NpcVenueChoice: AUTO venues pay no room penalty, pull adds to the score.
## Carries EXPECTED_CHECKS; run --import first.
##   godot --headless --path . --script core/population/venue_crowd_selftest.gd

const EXPECTED_CHECKS := 54

var _failures := 0
var _checks := 0


func _init() -> void:
	PopTestPrefs.reset_defaults()
	_test_effigy_phases()
	_test_burn_ring()
	_test_circle()
	_test_spiral_and_poses()
	_test_stage_fan()
	_test_venue_state()
	_test_auto_capacity()
	_test_venue_choice()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("VENUE CROWD SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VENUE CROWD SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


static func _fire(ignited_h: float) -> Dictionary:
	# A 45-minute climb, a 2 h bonfire, 1 h of embers.
	return FireTimeline.make(ignited_h, {"climb_h": 0.75, "bonfire_h": 2.0, "ember_h": 1.0, "mass_kg": 800.0})


func _test_effigy_phases() -> void:
	var rec := _fire(100.0)
	_check("no record = idle", int(VenueCrowd.effigy_phase({}, 50.0)["phase"]) == VenueCrowd.EffigyPhase.IDLE)
	_check("before ignition = idle", int(VenueCrowd.effigy_phase(rec, 99.0)["phase"]) == VenueCrowd.EffigyPhase.IDLE)
	var b := VenueCrowd.effigy_phase(rec, 100.25)
	_check("lit = burning", int(b["phase"]) == VenueCrowd.EffigyPhase.BURNING)
	_check("burning ends at the collapse (%.3f h left)" % float(b["ends_in_h"]),
		absf(float(b["ends_in_h"]) - (0.5 + FireTimeline.COLLAPSE_H)) < 1e-6)
	var landed := 100.0 + 0.75 + FireTimeline.COLLAPSE_H
	var c := VenueCrowd.effigy_phase(rec, landed + 0.2)
	_check("after the pile lands = circling", int(c["phase"]) == VenueCrowd.EffigyPhase.CIRCLING)
	_check("circling ends CIRCLE_H after the landing", absf(float(c["ends_in_h"]) - (VenueCrowd.CIRCLE_H - 0.2)) < 1e-6)
	_check("circle_t0 is the landing time", absf(float(c["circle_t0"]) - landed) < 1e-6)
	var a := VenueCrowd.effigy_phase(rec, landed + VenueCrowd.CIRCLE_H + 0.1)
	_check("then after", int(a["phase"]) == VenueCrowd.EffigyPhase.AFTER and float(a["ends_in_h"]) < 0.0)
	var out := rec.duplicate(true)
	out["out_h"] = 100.3
	_check("a fire put out is idle again", int(VenueCrowd.effigy_phase(out, 101.0)["phase"]) == VenueCrowd.EffigyPhase.IDLE)


func _test_burn_ring() -> void:
	var c := Vector2(500.0, -200.0)
	var ph := VenueCrowd.EffigyPhase.BURNING
	var pts: Array = []
	var min_r := INF
	var rows: Dictionary = {}
	for i in 400:
		var p := VenueCrowd.effigy_slot(c, i, ph, 0.0, NAN, 0.5)
		pts.append(p)
		min_r = minf(min_r, p.distance_to(c))
		var rw := VenueCrowd.effigy_row(i)
		rows[int(rw["row"])] = rw
	_check("every seat is outside the safe radius (nearest %.1f m)" % min_r, min_r >= VenueCrowd.EFFIGY_SAFE_R_M - 0.35)
	_check("400 people fill several rings", rows.size() >= 5, str(rows.size()))
	var gaps_grow := true
	var seats_grow := true
	var prev_r := -1.0
	var prev_gap := 0.0
	var prev_seat := 0.0
	for k in rows.size():
		var rw: Dictionary = rows[k]
		if prev_r >= 0.0:
			var gap := float(rw["r"]) - prev_r
			gaps_grow = gaps_grow and gap > prev_gap - 1e-6
			prev_gap = gap
		seats_grow = seats_grow and float(rw["seat"]) > prev_seat
		prev_seat = float(rw["seat"])
		prev_r = float(rw["r"])
	_check("rings get further apart with distance", gaps_grow)
	_check("seats get looser with distance", seats_grow)
	var front := int(rows[0]["n"])
	_check("row 0 is the first `n` indices", int(VenueCrowd.effigy_row(front - 1)["row"]) == 0
		and int(VenueCrowd.effigy_row(front)["row"]) == 1)
	# No two seats closer than two thirds of a seat.
	var nearest := INF
	for i in 120:
		for j in range(i + 1, 120):
			nearest = minf(nearest, (pts[i] as Vector2).distance_to(pts[j]))
	_check("no two seats collide (nearest pair %.2f m)" % nearest, nearest > EFFIGY_MIN_SEP)
	_check("the front row sits or lies",
		VenueCrowd.effigy_pose(0, ph, 0.2) == VenueCrowd.POSE_LIE
		and VenueCrowd.effigy_pose(0, ph, 0.9) == VenueCrowd.POSE_SIT)
	_check("the second row sits", VenueCrowd.effigy_pose(front + 1, ph, 0.9) == VenueCrowd.POSE_SIT)
	var back := int(rows[0]["n"]) + int(rows[1]["n"]) + 3
	_check("the back rows stand", VenueCrowd.effigy_pose(back, ph, 0.9) == VenueCrowd.POSE_STAND)
	_check("the ring is deterministic", VenueCrowd.effigy_slot(c, 77, ph, 0.0, NAN, 0.3)
		== VenueCrowd.effigy_slot(c, 77, ph, 5.0, NAN, 0.3))


const EFFIGY_MIN_SEP := 0.7


func _test_circle() -> void:
	var c := Vector2(0.0, 0.0)
	var ph := VenueCrowd.EffigyPhase.CIRCLING
	var t0 := 200.0
	var p0 := VenueCrowd.effigy_slot(c, 5, ph, t0, t0, 0.5)
	var p1 := VenueCrowd.effigy_slot(c, 5, ph, t0 + 0.01, t0, 0.5)
	var p2 := VenueCrowd.effigy_slot(c, 5, ph, t0 + 0.02, t0, 0.5)
	_check("the circle keeps its radius", absf(p0.distance_to(c) - p1.distance_to(c)) < 1e-3
		and absf(p1.distance_to(c) - p2.distance_to(c)) < 1e-3)
	# Counter-clockwise seen from above: the angle measured east -> north
	# (atan2(-z, x)) increases.
	var a0 := atan2(-p0.y, p0.x)
	var a1 := atan2(-p1.y, p1.x)
	var da := wrapf(a1 - a0, -PI, PI)
	_check("the circle runs counter-clockwise from above (east toward north)", da > 0.0, "%.4f" % da)
	_check("one lap takes CIRCLE_LAP_H (lane 0)",
		absf(VenueCrowd.circle_omega(0) - TAU / VenueCrowd.CIRCLE_LAP_H) < 1e-6)
	_check("outer lanes drift slower", VenueCrowd.circle_omega(3) < VenueCrowd.circle_omega(0))
	var r_lane0 := VenueCrowd.effigy_slot(c, 0, ph, t0, t0, 0.5).distance_to(c)
	var r_lane1 := VenueCrowd.effigy_slot(c, 1, ph, t0, t0, 0.5).distance_to(c)
	_check("lanes sit CIRCLE_LANE_M apart outside the safe radius",
		absf(r_lane1 - r_lane0 - VenueCrowd.CIRCLE_LANE_M) < 1e-4
		and r_lane0 >= VenueCrowd.EFFIGY_SAFE_R_M)
	var dancers := 0
	for i in 200:
		if VenueCrowd.effigy_pose(i, ph, NpcHash.unit01("p%d" % i, "venue")) == VenueCrowd.POSE_DANCE:
			dancers += 1
	_check("about half the circle dances, the rest walk (%d of 200)" % dancers, dancers > 70 and dancers < 130)


func _test_spiral_and_poses() -> void:
	var c := Vector2(10.0, 10.0)
	var ph := VenueCrowd.EffigyPhase.AFTER
	var near := VenueCrowd.effigy_slot(c, 0, ph, 0.0, NAN, 0.5).distance_to(c)
	var far := VenueCrowd.effigy_slot(c, 100, ph, 0.0, NAN, 0.5).distance_to(c)
	_check("the after spiral stands off from the pile and grows outward",
		near >= VenueCrowd.EFFIGY_SAFE_R_M * VenueCrowd.EFFIGY_GATHER_R - 1e-6 and far > near + 5.0)
	_check("after/idle people stand or clap", VenueCrowd.effigy_pose(3, ph, 0.2) == VenueCrowd.POSE_CLAP
		and VenueCrowd.effigy_pose(3, ph, 0.8) == VenueCrowd.POSE_STAND)
	_check("venue_pose dispatches an effigy's slot", VenueCrowd.venue_pose("effigy", 0,
		{"phase": VenueCrowd.EffigyPhase.BURNING}, 0.1) == VenueCrowd.POSE_LIE)
	_check("venue_pose is empty for an ordinary venue", VenueCrowd.venue_pose("temple", 0, {}, 0.5) == "")
	_check("venue_spot is INF for an ordinary venue", VenueCrowd.venue_spot("temple", c, 0, {}, 0.0, 0.5) == Vector2.INF)


func _test_stage_fan() -> void:
	var centre := Vector2(0.0, 0.0)
	var poly := PackedVector2Array([Vector2(-20, -10), Vector2(20, -10), Vector2(20, 10), Vector2(-20, 10)])
	var camps := Vector2(0.0, 300.0)   # the camps are south (+Z)
	var fwd := VenueCrowd.stage_facing(centre, camps)
	_check("the stage faces the camps", fwd.distance_to(Vector2(0.0, 1.0)) < 1e-6)
	var front := VenueCrowd.stage_front(centre, poly, fwd)
	_check("the front edge is the footprint's extent along the facing", front.distance_to(Vector2(0.0, 10.0)) < 1e-6)
	var all_front := true
	var nearest := INF
	var farthest := 0.0
	for i in 300:
		var p := VenueCrowd.stage_slot(front, fwd, i)
		var ahead := (p - front).dot(fwd)
		all_front = all_front and ahead >= 1.0
		nearest = minf(nearest, p.distance_to(front))
		farthest = maxf(farthest, p.distance_to(front))
	_check("every fan slot is in FRONT of the speakers", all_front)
	_check("the fan is densest at the front and spreads back (%.1f .. %.1f m)" % [nearest, farthest],
		nearest <= VenueCrowd.STAGE_FAN_GAP_M + 1.1 and farthest > nearest + 15.0)
	var active := {"active": true, "programmed": true}
	_check("a live set seats the fan and raves",
		VenueCrowd.venue_spot("stage", centre, 3, active, 0.0, 0.5, {"front": front, "fwd": fwd}) != Vector2.INF
		and VenueCrowd.venue_pose("stage", 3, active, 0.5) == VenueCrowd.POSE_RAVE)
	_check("a dark stage is an ordinary venue",
		VenueCrowd.venue_spot("stage", centre, 3, {"active": false, "programmed": true}, 0.0, 0.5) == Vector2.INF
		and VenueCrowd.venue_pose("stage", 3, {"active": false, "programmed": true}, 0.5) == "")
	_check("a stage with no camps faces south", VenueCrowd.stage_facing(centre, centre) == Vector2(0.0, 1.0))


func _test_venue_state() -> void:
	var stage := {"id": "s1", "space_type": "stage", "draw": 1.0,
		"program": [{"day": -1, "start_h": 20.0, "end_h": 2.0, "draw": 1.0, "label": "Set", "load_w": 0.0}]}
	var on := NpcVenueState.resolve(stage, 22.0, 0.0)
	var off := NpcVenueState.resolve(stage, 14.0, 0.0)
	_check("a live set pulls (%.2f) but is not an EVENT" % float(on["pull"]),
		float(on["pull"]) == NpcVenueState.STAGE_SET_PULL and not bool(on["event"]))
	_check("a dark stage has no pull", float(off["pull"]) == 0.0 and not bool(off["event"]))
	var effigy := {"id": "e1", "space_type": "effigy", "draw": 0.5}
	var rec := _fire(100.0)
	var idle := NpcVenueState.resolve(effigy, 12.0, 50.0, rec)
	var burn := NpcVenueState.resolve(effigy, 21.0, 100.3, rec)
	var after := NpcVenueState.resolve(effigy, 23.0, 103.0, rec)
	_check("an unlit effigy is art: base draw, no pull", float(idle["draw"]) == 0.5 and float(idle["pull"]) == 0.0)
	_check("the burn is an EVENT with full draw", bool(burn["event"]) and float(burn["draw"]) == 1.0
		and float(burn["pull"]) >= NpcVenueState.EVENT_THRESHOLD and bool(burn["programmed"]))
	_check("the embers are a social draw, no event", not bool(after["event"]) and float(after["draw"]) == NpcVenueState.EFFIGY_AFTER_DRAW)
	_check("any_event sees the burn", NpcVenueState.any_event([idle, burn]) and not NpcVenueState.any_event([idle, after]))


func _test_auto_capacity() -> void:
	var reg := SpaceRegistry.create_empty()
	var near_id := reg.set_space_type({"kind": "area", "poly": [[0, 0], [4, 0], [4, 4], [0, 4]]}, "restroom", SpaceRegistry.CAPACITY_AUTO)
	var far_id := reg.set_space_type({"kind": "area", "poly": [[30, 0], [34, 0], [34, 4], [30, 4]]}, "restroom", SpaceRegistry.CAPACITY_AUTO)
	_check("auto capacity records as 0", int(reg.find_by_id(near_id)["capacity"]) == 0 and reg.is_auto_capacity(near_id))
	_check("an auto space is never full", reg.has_free_capacity(near_id))
	var pos_of := func(space: Dictionary) -> Variant:
		return SpaceRegistry.area_interior_point((space["target"] as Dictionary)["poly"])
	# Six people from the near side: distance says near every time; sharing
	# says alternate once the near one is crowded enough.
	var picks: Dictionary = {}
	for i in 6:
		var s := reg.nearest_space_by("restroom", Vector2(2.0, 2.0), pos_of, true, "p%d" % i)
		var sid := str(s["id"])
		picks[sid] = int(picks.get(sid, 0)) + 1
		reg.claim(sid, "p%d" % i)
	_check("six arrivals share two equal restrooms (%s)" % str(picks), int(picks.get(near_id, 0)) >= 2
		and int(picks.get(far_id, 0)) >= 2)
	var crowded := SpaceRegistry.create_empty()
	var a := crowded.set_space_type({"kind": "area", "poly": [[0, 0], [4, 0], [4, 4], [0, 4]]}, "water_point", SpaceRegistry.CAPACITY_AUTO)
	var b := crowded.set_space_type({"kind": "area", "poly": [[20, 0], [24, 0], [24, 4], [20, 4]]}, "water_point", SpaceRegistry.CAPACITY_AUTO)
	for i in 3:
		crowded.claim(a, "q%d" % i)
	_check("a crowded nearer space loses to a farther empty one",
		str(crowded.nearest_space_by("water_point", Vector2(2.0, 2.0), pos_of, true, "x")["id"]) == b)
	_check("every claim on an auto space succeeds", crowded.claim(a, "y") and crowded.claim(a, "z")
		and crowded.occupant_count(a) == 5)
	var hard := SpaceRegistry.create_empty()
	var h := hard.set_space_type({"kind": "prop", "prop_id": "loo"}, "restroom", 1)
	hard.claim(h, "one")
	_check("an explicit capacity still refuses", not hard.has_free_capacity(h) and not hard.claim(h, "two"))
	_check("the API default stays a hard limit of two",
		int(hard.find_by_id(hard.set_space_type({"kind": "prop", "prop_id": "bench"}, "kitchen"))["capacity"]) == 2)


func _test_venue_choice() -> void:
	var taste := {"music": 0.5, "quiet": 0.5, "social": 0.5, "art": 0.5}
	var here := Vector2.ZERO
	var auto_full := {"id": "a", "type": "stage", "pos": Vector2(10, 0), "draw": 1.0, "occupants": 500, "capacity": 0}
	var capped := {"id": "b", "type": "stage", "pos": Vector2(10, 0), "draw": 1.0, "occupants": 500, "capacity": 600}
	_check("an AUTO venue pays no room penalty",
		NpcVenueChoice.score(taste, here, auto_full) > NpcVenueChoice.score(taste, here, capped))
	var full := {"id": "c", "type": "stage", "pos": Vector2(10, 0), "draw": 1.0, "occupants": 600, "capacity": 600}
	_check("a venue at its explicit capacity is skipped; an AUTO one never is",
		str(NpcVenueChoice.pick(taste, here, [full, auto_full])["id"]) == "a")
	var quiet_near := {"id": "t", "type": "temple", "pos": Vector2(5, 0), "draw": 0.9, "occupants": 0, "capacity": 0}
	var effigy_far := {"id": "e", "type": "effigy", "pos": Vector2(140, 0), "draw": 1.0, "occupants": 0, "capacity": 0,
		"pull": NpcVenueState.EFFIGY_BURN_PULL}
	_check("the burn's pull beats a nearer venue the person would otherwise prefer",
		str(NpcVenueChoice.pick({"music": 0.1, "quiet": 1.0, "social": 0.1, "art": 0.1}, here,
			[quiet_near, effigy_far])["id"]) == "e")
	var effigy_idle := effigy_far.duplicate()
	effigy_idle["pull"] = 0.0
	effigy_idle["draw"] = 0.5
	_check("an unlit effigy 140 m away does not", str(NpcVenueChoice.pick({"music": 0.1, "quiet": 1.0, "social": 0.1, "art": 0.1},
		here, [quiet_near, effigy_idle])["id"]) == "t")
