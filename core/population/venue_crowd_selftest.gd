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

const EXPECTED_CHECKS := 134

var _failures := 0
var _checks := 0


func _init() -> void:
	# The player's saved testing switches (user://pop_testing.cfg — "no
	# departures", "ideal supply" …) must not leak into the assertions.
	PopTestPrefs.reset_defaults()
	_test_effigy_phases()
	_test_fire_ring()
	_test_stage_music()
	_test_preroll_and_standoff()
	_test_burn_ring()
	_test_circle()
	_test_spiral_and_poses()
	_test_stage_fan()
	_test_venue_state()
	_test_auto_capacity()
	_test_venue_choice()
	_test_layouts_and_dj()
	_test_shared_moments()
	_test_friend_groups()
	_test_comfort_and_firepit()
	_test_burn_sequence()
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


## The pre-roll (ignition -> first flame) reads as BURNING for the crowd, so
## the rings form before anything is alight; and an IDLE crowd already stands
## outside the burning radius, so lighting the effigy strands nobody inside it.
func _test_preroll_and_standoff() -> void:
	var rec := FireTimeline.make(100.0, {"climb_h": 0.75, "bonfire_h": 2.0, "ember_h": 1.0,
		"preroll_h": 0.25, "height_m": 12.0, "footprint_r_m": 3.0, "mass_kg": 800.0})
	var burning_r := 12.0 + VenueCrowd.PERIMETER_STANDING_M
	var p := VenueCrowd.effigy_phase(rec, 100.1)
	_check("pre-roll reads as BURNING for the crowd", int(p["phase"]) == VenueCrowd.EffigyPhase.BURNING
		and bool(p["preroll"]))
	_check("... at the BURNING radius", absf(float(p["safe_r"]) - burning_r) < 1e-4)
	_check("... with no flame drawn yet", int(FireTimeline.state_at(rec, 100.1)["phase"]) == FireTimeline.Phase.NONE
		and not FireTimeline.has_flame(rec, 100.1))
	_check("... flames in 0.15 h", absf(float(p["flame_in_h"]) - 0.15) < 1e-6)
	_check("... and the event lasts through the climb", absf(float(p["ends_in_h"])
		- (0.15 + 0.75 + FireTimeline.COLLAPSE_H)) < 1e-6)
	_check("after the pre-roll it simply burns", int(VenueCrowd.effigy_phase(rec, 100.3)["phase"])
		== VenueCrowd.EffigyPhase.BURNING and not bool(VenueCrowd.effigy_phase(rec, 100.3)["preroll"]))
	var called_off := rec.duplicate(true)
	called_off["out_h"] = 100.1
	_check("a burn called off in the pre-roll is idle again",
		int(VenueCrowd.effigy_phase(called_off, 100.2)["phase"]) == VenueCrowd.EffigyPhase.IDLE)
	# A tall effigy that has never been lit: only its size is known.
	var tall := {"height_m": 20.0, "footprint_r_m": 3.0}
	var idle := VenueCrowd.effigy_phase(tall, 0.0)
	_check("an unlit effigy's idle perimeter is its BURNING one",
		absf(float(idle["safe_r"]) - (20.0 + VenueCrowd.PERIMETER_STANDING_M)) < 1e-4)
	var inside := 0
	for i in 300:
		var q := VenueCrowd.effigy_slot(Vector2.ZERO, i, VenueCrowd.EffigyPhase.IDLE, 0.0, NAN,
			NpcHash.unit01("g%d" % i, "venue"), float(idle["safe_r"]))
		if q.length() < 20.0 + VenueCrowd.PERIMETER_STANDING_M:
			inside += 1
	_check("nobody in an idle crowd stands inside the fall zone (%d of 300)" % inside, inside == 0)


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
	_check("the front row lounges or sits cross-legged (never flat)",
		VenueCrowd.effigy_pose(0, ph, 0.2) == VenueCrowd.POSE_LOUNGE
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
		near >= VenueCrowd.EFFIGY_SAFE_R_M + VenueCrowd.EFFIGY_GATHER_GAP_M - 1e-6 and far > near + 5.0)
	_check("after/idle people gaze, sit, lounge, talk or dance",
		VenueCrowd.effigy_pose(3, ph, 0.1) == VenueCrowd.POSE_GAZE
		and VenueCrowd.effigy_pose(3, ph, 0.4) == VenueCrowd.POSE_SIT
		and VenueCrowd.effigy_pose(3, ph, 0.6) == VenueCrowd.POSE_LOUNGE
		and VenueCrowd.effigy_pose(3, ph, 0.8) == VenueCrowd.POSE_TALK
		and VenueCrowd.effigy_pose(3, ph, 0.95) == VenueCrowd.POSE_DANCE)
	_check("venue_pose dispatches an effigy's slot", VenueCrowd.venue_pose("effigy", 0,
		{"phase": VenueCrowd.EffigyPhase.BURNING}, 0.1) == VenueCrowd.POSE_LOUNGE)
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
	# A stage FACES one way whether or not a set is on: off-set its crowd
	# still stands in front of it (never on it, never behind the speakers),
	# just without the rave.
	var dark := VenueCrowd.venue_spot("stage", centre, 3, {"active": false, "programmed": true}, 0.0, 0.5,
		{"front": front, "fwd": fwd})
	_check("a dark stage's crowd still stands in front, without raving",
		dark != Vector2.INF and (dark - front).dot(fwd) >= 1.0
		and VenueCrowd.venue_pose("stage", 3, {"active": false, "programmed": true}, 0.5) == "")
	_check("a stage with no camps faces south", VenueCrowd.stage_facing(centre, centre) == Vector2(0.0, 1.0))
	# The fan is ONE even crowd, not two spiral arms: the first 40 seats cover
	# every eighth of the span (folding the golden angle onto 130 degrees
	# stepped each seat only 7.5 degrees from the last).
	var bins := {}
	for i in 40:
		var p := VenueCrowd.stage_slot(front, fwd, i, 0.5)
		var d := p - (front + fwd * VenueCrowd.STAGE_FAN_GAP_M)   # from the fan's apex
		bins[clampi(int((atan2(d.x, d.y) / VenueCrowd.STAGE_FAN_SPAN + 0.5) * 8.0), 0, 7)] = true
	_check("the first 40 fan seats spread across the whole span (%d of 8 eighths)" % bins.size(), bins.size() == 8)
	# Close but realistic: nobody on anybody, and a crowd, not a queue.
	var pts: Array = []
	for i in 200:
		pts.append(VenueCrowd.stage_slot(front, fwd, i, fposmod(float(i) * 0.6180339, 1.0)))
	var min_d := INF
	var sum_nn := 0.0
	for a in pts.size():
		var nn := INF
		for b in pts.size():
			if a != b:
				nn = minf(nn, (pts[a] as Vector2).distance_to(pts[b]))
		min_d = minf(min_d, nn)
		sum_nn += nn
	var mean_nn := sum_nn / float(pts.size())
	_check("fan spacing is close but physical (closest %.2f m, mean nearest %.2f m)" % [min_d, mean_nn],
		min_d >= 0.35 and mean_nn > 0.75 and mean_nn < 1.3)
	# The crowd distance the player sets: the front row stands that far out.
	var near_r := INF
	for i in 60:
		near_r = minf(near_r, (VenueCrowd.stage_slot(front, fwd, i, 0.5, 6.0) - front).dot(fwd))
	_check("the crowd distance sets where the front row stands (%.2f m at 6 m)" % near_r,
		near_r >= 6.0 and near_r < 6.6)
	var gap_spot := VenueCrowd.venue_spot("stage", centre, 0, active, 0.0, 0.5,
		{"layout": SpaceRegistry.LAYOUT_DIRECTIONAL, "front": front, "fwd": fwd, "gap": 3.0})
	_check("...and reaches the venue through its geometry entry", (gap_spot - front).dot(fwd) >= 3.0)


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
	_check("an unlit effigy is an attractor: raised draw, a gentle pull, no event",
		float(idle["draw"]) == VenueCrowd.EFFIGY_IDLE_DRAW and float(idle["pull"]) == VenueCrowd.EFFIGY_IDLE_PULL
		and not bool(idle["event"]))
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


## Round vs facing-one-way layouts for any venue, the compass maths, and the
## DJ's mark on the deck.
func _test_layouts_and_dj() -> void:
	_check("by type: a stage faces one way, a fire circle is gathered round",
		VenueCrowd.layout_of("stage", "") == SpaceRegistry.LAYOUT_DIRECTIONAL
		and VenueCrowd.layout_of("fire_circle", "") == SpaceRegistry.LAYOUT_RING)
	_check("an explicit layout wins over the type",
		VenueCrowd.layout_of("stage", SpaceRegistry.LAYOUT_RING) == SpaceRegistry.LAYOUT_RING
		and VenueCrowd.layout_of("art", SpaceRegistry.LAYOUT_DIRECTIONAL) == SpaceRegistry.LAYOUT_DIRECTIONAL)
	var north := VenueCrowd.fwd_from_deg(0.0)
	var east := VenueCrowd.fwd_from_deg(90.0)
	_check("compass: 0 deg is north (-Z), 90 deg is east (+X)",
		north.distance_to(Vector2(0.0, -1.0)) < 1e-5 and east.distance_to(Vector2(1.0, 0.0)) < 1e-5)
	var rt := true
	for d in [0.0, 45.0, 137.0, 270.0, 359.0]:
		rt = rt and absf(angle_difference(deg_to_rad(VenueCrowd.deg_from_fwd(VenueCrowd.fwd_from_deg(d))), deg_to_rad(d))) < 1e-4
	_check("compass degrees round-trip through a direction", rt)
	var c := Vector2(100.0, 50.0)
	var fwd := VenueCrowd.fwd_from_deg(200.0)
	var front := VenueCrowd.stage_front(c, PackedVector2Array(), fwd)
	var ahead := true
	for i in 60:
		var p := VenueCrowd.venue_spot("art", c, i, {}, 0.0, fposmod(float(i) * 0.37, 1.0),
			{"layout": SpaceRegistry.LAYOUT_DIRECTIONAL, "front": front, "fwd": fwd})
		ahead = ahead and (p - c).dot(fwd) >= 1.0
	_check("ANY venue set to face one way gathers its crowd only in front", ahead)
	var ring_ok := true
	var bearings := {}
	for i in 60:
		var p2 := VenueCrowd.venue_spot("stage", c, i, {"active": true, "programmed": true}, 0.0, 0.5,
			{"layout": SpaceRegistry.LAYOUT_RING, "r": 5.0})
		ring_ok = ring_ok and p2.distance_to(c) >= 5.0 + VenueCrowd.STAGE_FAN_GAP_M - VenueCrowd.SEAT_JITTER_M
		bearings[int(fposmod(atan2(p2.y - c.y, p2.x - c.x), TAU) / (TAU / 8.0))] = true
	_check("a stage turned ROUND rings its crowd outside its footprint, all the way round",
		ring_ok and bearings.size() == 8)
	_check("a ring venue with no choreography falls back to group clusters (INF)",
		VenueCrowd.venue_spot("art", c, 2, {}, 0.0, 0.5, {"layout": SpaceRegistry.LAYOUT_RING}) == Vector2.INF)
	var dj := VenueCrowd.perform_spot(c, fwd, 1.05)
	_check("the DJ stands in the middle of the stage, on its deck, facing the speakers' way",
		(dj["pos"] as Vector2) == c and absf(float(dj["elev"]) - 1.05) < 1e-6
		and ((dj["face"] as Vector2) - c).normalized().dot(fwd) > 0.999)
	var reg := SpaceRegistry.create_empty()
	var sid := reg.set_space_type({"kind": "prop", "prop_id": "p1"}, "stage", 0)
	reg.set_space_fields(sid, {"layout": "directional", "facing_deg": 135.0, "perform_h_m": 1.2})
	var rec := reg.find_by_id(sid)
	_check("the registry keeps layout, facing and deck height",
		str(rec["layout"]) == "directional" and float(rec["facing_deg"]) == 135.0
		and float(rec["perform_h_m"]) == 1.2)
	reg.set_space_fields(sid, {"layout": "sideways"})
	_check("an unknown layout normalises to by-type", str(reg.find_by_id(sid)["layout"]) == "")


## Shared moments: the last minutes before the effigy comes down, and a set's
## closer — arms go up for most of the crowd.
func _test_shared_moments() -> void:
	var rec := FireTimeline.make(100.0, {"climb_h": 1.0, "bonfire_h": 1.0, "ember_h": 0.5})
	var collapse := 100.0 + FireTimeline.preroll_h(rec) + FireTimeline.climb_h(rec)
	var early := VenueCrowd.effigy_phase(rec, collapse - 0.5)
	var late := VenueCrowd.effigy_phase(rec, collapse - 0.02)
	_check("no cheer mid-burn; a cheer in the last minutes before the collapse",
		not bool(early["cheer"]) and bool(late["cheer"]) and int(late["phase"]) == VenueCrowd.EffigyPhase.BURNING)
	var st_late := {"phase": VenueCrowd.EffigyPhase.BURNING, "cheer": true, "safe_r": 14.0}
	var cheering := 0
	for k in 100:
		if VenueCrowd.venue_pose("effigy", k, st_late, float(k) / 100.0) == VenueCrowd.POSE_CHEER:
			cheering += 1
	_check("most of the ring cheers (%d of 100), front rows included" % cheering,
		cheering >= 75 and cheering <= 95)
	var slot := {"start_h": 20.0, "end_h": 2.0, "draw": 1.0}
	var stage := {"space_type": "stage", "draw": 0.5, "program": [slot]}
	var mid := NpcVenueState.resolve(stage, 22.0, 22.0)
	var closer := NpcVenueState.resolve(stage, 1.85, 1.85)
	_check("a set's closer is its PEAK; mid-set is not", bool(closer["peak"]) and not bool(mid["peak"]))
	var up := 0
	for k in 100:
		if VenueCrowd.venue_pose("stage", k, closer, float(k) / 100.0) == VenueCrowd.POSE_CHEER:
			up += 1
	_check("at the peak arms go up (%d of 100) and the rest rave" % up, up >= 45 and up <= 75)


## Friend groups: a pure partition of each camp, friends make the same
## leisure choice and stand together.
func _test_friend_groups() -> void:
	NpcFriends.clear_cache()
	var seen := {}
	var ok := true
	var sizes := {}
	for i in 200:
		var g := NpcFriends.group_of("camp_npc_%d" % i)
		var key := str(g["key"])
		var arr: Array = seen.get(key, [])
		arr.append(int(g["k"]))
		seen[key] = arr
		ok = ok and int(g["size"]) >= 1 and int(g["size"]) <= NpcFriends.MAX_SIZE and int(g["k"]) < int(g["size"])
		sizes[int(g["size"])] = true
	var whole := true
	for key in seen:
		var ks: Array = seen[key]
		ks.sort()
		for j in ks.size():
			whole = whole and int(ks[j]) == j
	_check("every person is in exactly one group of 1-5, members numbered 0..n-1", ok and whole)
	_check("groups come in several sizes", sizes.size() >= 4)
	var before := NpcFriends.group_of("camp_npc_57")
	NpcFriends.clear_cache()
	var after := NpcFriends.group_of("camp_npc_57")
	_check("the partition is a pure function of the id",
		str(before["key"]) == str(after["key"]) and int(before["k"]) == int(after["k"]))
	# Find a group of at least 3 and check its members.
	var mates: Array = []
	for i in 200:
		var g2 := NpcFriends.group_of("camp_npc_%d" % i)
		if int(g2["size"]) >= 3:
			for j in 200:
				if str(NpcFriends.group_of("camp_npc_%d" % j)["key"]) == str(g2["key"]):
					mates.append("camp_npc_%d" % j)
			break
	var same_choice := true
	for h in 24:
		var ch := NpcSocial.choice(str(mates[0]), 100.0 + float(h))
		for m in mates:
			same_choice = same_choice and NpcSocial.choice(str(m), 100.0 + float(h)) == ch
	_check("friends make the same hourly SOCIAL choice (%d in the group)" % mates.size(), same_choice)
	var spots: Array = []
	for m in mates:
		spots.append(NpcSocial.mingle_spot(str(m), "camp", Vector2.ZERO, 103.4))
	var tight := true
	var face0: Vector2 = spots[0]["face"]
	for s in spots:
		tight = tight and (s["pos"] as Vector2).distance_to(face0) < 2.0 and (s["face"] as Vector2) == face0
	var apart := true
	for a in spots.size():
		for b in range(a + 1, spots.size()):
			apart = apart and (spots[a]["pos"] as Vector2).distance_to(spots[b]["pos"]) > 0.35
	_check("a friend group in a circle holds its own F-formation (tight, facing its middle)", tight)
	_check("... with nobody standing on anybody", apart)
	var gs: Array = []
	for m in mates:
		gs.append(VenueCrowd.group_spot("center_camp", Vector2(50, 50), 6.0, str(m)))
	var together := true
	for s in gs:
		together = together and (s["pos"] as Vector2).distance_to(gs[0]["pos"]) < 3.5
	_check("friends at a venue stand together and face each other at center camp",
		together and (gs[0]["face"] as Vector2) != Vector2(50, 50))
	var art := VenueCrowd.group_spot("art", Vector2(50, 50), 6.0, str(mates[0]))
	_check("...and face the piece at an art venue", (art["face"] as Vector2) == Vector2(50, 50))


## Venue music plays when the set does (StageMusic.should_play).
func _test_stage_music() -> void:
	var stage := {"id": "sm", "space_type": "stage", "draw": 1.0,
		"program": FestivalProgram.normalize([{"start_h": 20.0, "end_h": 2.0, "draw": 1.0}])}
	var on := NpcVenueState.resolve(stage, 21.5, 21.5)
	var off := NpcVenueState.resolve(stage, 15.0, 15.0)
	_check("a stage's track plays during its set and not outside it",
		StageMusic.should_play("stage", on) and not StageMusic.should_play("stage", off))
	_check("a fire's track plays while it burns; nothing plays with no state",
		StageMusic.should_play("fire_circle", {"lit": true}) and not StageMusic.should_play("fire_circle", {"lit": false})
		and not StageMusic.should_play("stage", {}))
	_check("a missing track loads as nothing (no crash, no sound)",
		StageMusic.load_track("") == null and StageMusic.load_track("no_such_track_xyz.mp3") == null)


## A fire is gathered ROUND: a still ring outside the pit — chat, a few sit,
## and a light sway when a stage's music carries over.
func _test_fire_ring() -> void:
	var c := Vector2(10.0, 10.0)
	var lit := {"lit": true}
	var cold := {"lit": false}
	var extra := {"layout": SpaceRegistry.LAYOUT_RING, "r": 0.6}
	var r_in := 0.6 + VenueCrowd.FIRE_RING_GAP_M
	var pts: Array = []
	var outside := true
	for i in 40:
		var p := VenueCrowd.venue_spot("fire_circle", c, i, cold, 100.0, fposmod(float(i) * 0.37, 1.0), extra)
		outside = outside and p.distance_to(c) >= r_in - 0.35
		pts.append(p)
	var min_d := INF
	for a in pts.size():
		for b in range(a + 1, pts.size()):
			min_d = minf(min_d, (pts[a] as Vector2).distance_to(pts[b]))
	_check("forty people ring a fire, nobody in the pit (front ring %.1f m)" % r_in, outside)
	_check("...shoulder to shoulder but never on each other (closest %.2f m)" % min_d, min_d > 0.4)
	# The ring STANDS STILL, lit or cold: a fire is where people warm up and
	# chat (it used to lap the fire as a dance ring).
	var still := true
	for i in 20:
		still = still and VenueCrowd.venue_spot("fire_circle", c, i, lit, 100.0, 0.5, extra) \
			== VenueCrowd.venue_spot("fire_circle", c, i, lit, 100.0 + VenueCrowd.FIRE_LAP_H * 0.5, 0.5, extra)
	_check("a burning fire's ring stands still (people chat there, they do not lap it)", still)
	_check("...and a cold pit's ring stands still",
		VenueCrowd.venue_spot("fire_circle", c, 3, cold, 100.0, 0.5, extra)
		== VenueCrowd.venue_spot("fire_circle", c, 3, cold, 101.0, 0.5, extra))
	var music := {"lit": true, "music_near": true}
	_check("nobody circles a fire, lit, cold or with music",
		not VenueCrowd.is_circling("fire_circle", lit) and not VenueCrowd.is_circling("fire_circle", cold)
		and not VenueCrowd.is_circling("fire_circle", music)
		and not VenueCrowd.is_circling("stage", {"active": true}))
	var talking := 0
	var sitting := 0
	var swaying := 0
	var talking_m := 0
	for i in 40:
		var u := float(i) / 40.0
		var pl := VenueCrowd.venue_pose("fire_circle", i, lit, u)
		if pl == VenueCrowd.POSE_TALK:
			talking += 1
		elif pl == VenueCrowd.POSE_SIT:
			sitting += 1
		var pm := VenueCrowd.venue_pose("fire_circle", i, music, u)
		if pm == VenueCrowd.POSE_SWAY:
			swaying += 1
		elif pm == VenueCrowd.POSE_TALK:
			talking_m += 1
	_check("round a lit fire with no music people chat (%d talk, %d sit, nobody dances)" % [talking, sitting],
		talking >= 20 and sitting >= 10 and talking + sitting == 40)
	_check("with a stage's music in earshot most sway lightly, the rest keep talking (%d / %d)" % [swaying, talking_m],
		swaying >= 25 and talking_m >= 8 and swaying + talking_m == 40)
	_check("round a cold pit they sit and talk; no music without a stamp",
		VenueCrowd.venue_pose("fire_circle", 0, cold, 0.1) == VenueCrowd.POSE_SIT
		and VenueCrowd.venue_pose("fire_circle", 0, cold, 0.9) == VenueCrowd.POSE_TALK
		and not VenueCrowd.fire_music(lit))
	_check("music reaches a fire within earshot of a playing stage and not beyond it",
		VenueCrowd.music_reaches(Vector2.ZERO, [Vector2(150.0, 0.0)])
		and not VenueCrowd.music_reaches(Vector2.ZERO, [Vector2(VenueCrowd.MUSIC_EARSHOT_M + 5.0, 0.0)])
		and not VenueCrowd.music_reaches(Vector2.ZERO, []))
	# The heat draws people: more the colder it is, more at night, never
	# negative, nothing on a hot day.
	var w_hot_day := NpcComfort.fire_warmth(30.0, false)
	var w_cool_day := NpcComfort.fire_warmth(10.0, false)
	var w_mild_night := NpcComfort.fire_warmth(20.0, true)
	var w_cold_night := NpcComfort.fire_warmth(3.0, true)
	_check("a fire's heat pull: 0 on a hot day, some on a cool one, more on a mild night, most on a cold night (%.2f %.2f %.2f %.2f)"
		% [w_hot_day, w_cool_day, w_mild_night, w_cold_night],
		w_hot_day == 0.0 and w_cool_day > 0.15 and w_mild_night >= NpcComfort.FIRE_NIGHT_BASE
		and w_cold_night > 0.95 and w_cold_night <= 1.0 and w_cool_day < w_cold_night)
	_check("unknown temperature: the night base after dark, nothing by day",
		NpcComfort.fire_warmth(NAN, true) == NpcComfort.FIRE_NIGHT_BASE and NpcComfort.fire_warmth(NAN, false) == 0.0)
	_check("pulls() carries the fire's warmth alongside the comfort shares",
		float(NpcComfort.pulls({"temp_c": 3.0, "ghi_wm2": 0.0}, 23.0).get("warmth", 0.0)) > 0.95)
	_check("people warming at a fire on a comfort stint sit or TALK, never stand mute",
		NpcComfort.pose_for(NpcComfort.KIND_WARM, "w0_npc_0") in [VenueCrowd.POSE_SIT, VenueCrowd.POSE_TALK]
		and NpcComfort.pose_for(NpcComfort.KIND_WARM, "w0_npc_7") in [VenueCrowd.POSE_SIT, VenueCrowd.POSE_TALK])
	_check("the crowd distance moves the ring",
		VenueCrowd.venue_spot("fire_circle", c, 0, cold, 0.0, 0.5, {"r": 0.6, "gap": 4.0}).distance_to(c) > 4.3)


## NpcComfort's pulls from the weather, its share-not-switch response, and
## the firepit's lighting rule.
func _test_comfort_and_firepit() -> void:
	var mild := NpcComfort.pulls({"temp_c": 22.0, "ghi_wm2": 900.0, "rain_mmh": 0.0}, 14.0)
	var warm := NpcComfort.pulls({"temp_c": 31.0, "ghi_wm2": 900.0, "rain_mmh": 0.0}, 14.0)
	var scorch := NpcComfort.pulls({"temp_c": 40.0, "ghi_wm2": 900.0, "rain_mmh": 0.0}, 14.0)
	var hot_dull := NpcComfort.pulls({"temp_c": 40.0, "ghi_wm2": 120.0, "rain_mmh": 0.0}, 14.0)
	_check("heat: none at 22 C, some at 31 C, most at 40 C in full sun (%.2f / %.2f)" % [float(warm["heat"]), float(scorch["heat"])],
		float(mild["heat"]) == 0.0 and float(warm["heat"]) > 0.05 and float(warm["heat"]) < float(scorch["heat"])
		and float(scorch["heat"]) > 0.7)
	_check("heat needs SUN: a hot overcast afternoon pulls nobody", float(hot_dull["heat"]) == 0.0)
	var cold_night := NpcComfort.pulls({"temp_c": 4.0, "ghi_wm2": 0.0, "rain_mmh": 0.0}, 23.0)
	var mild_night := NpcComfort.pulls({"temp_c": 18.0, "ghi_wm2": 0.0, "rain_mmh": 0.0}, 23.0)
	var cold_day := NpcComfort.pulls({"temp_c": 4.0, "ghi_wm2": 500.0, "rain_mmh": 0.0}, 13.0)
	_check("cold pulls at NIGHT only (4 C night %.2f, 18 C night 0, 4 C day 0)" % float(cold_night["cold"]),
		float(cold_night["cold"]) > 0.5 and float(mild_night["cold"]) == 0.0 and float(cold_day["cold"]) == 0.0)
	var drizzle := NpcComfort.pulls({"temp_c": 15.0, "ghi_wm2": 100.0, "rain_mmh": 1.0}, 13.0)
	var pour := NpcComfort.pulls({"temp_c": 15.0, "ghi_wm2": 100.0, "rain_mmh": 10.0}, 13.0)
	_check("light rain and fog send nobody in; heavy rain nearly everyone (%.2f)" % float(pour["rain"]),
		float(drizzle["rain"]) == 0.0 and float(pour["rain"]) > 0.9)
	_check("unknown weather pulls nobody", NpcComfort.is_calm(NpcComfort.pulls({}, 14.0)))
	var groups := {}
	var resp := 0
	for i in 600:
		var aid := "w%d_npc_%d" % [i % 7, i]
		var g := NpcFriends.key_of(aid)
		if groups.has(g):
			continue
		groups[g] = true
		if NpcComfort.respond(aid, 500.0, {"heat": 0.5}) == NpcComfort.KIND_SHADE:
			resp += 1
	var share := float(resp) / float(groups.size())
	_check("a pull is a SHARE of groups, not a switch (0.5 -> %.2f)" % share, absf(share - 0.5) < 0.1)
	_check("rain outranks the heat", NpcComfort.respond("x_npc_1", 10.0, {"heat": 1.0, "rain": 1.0}) == NpcComfort.KIND_SHELTER)
	var seat := NpcComfort.seat_around(Vector2(10, 10), 1.7, "w0_npc_0")
	_check("a seat round the fire is on its ring, facing it",
		absf((seat["pos"] as Vector2).distance_to(Vector2(10, 10)) - 1.7) < 0.45 and (seat["face"] as Vector2) == Vector2(10, 10))
	var under := NpcComfort.seat_under({"pos": Vector2(0, 0), "yaw": 0.7, "size": Vector3(6.0, 3.0, 3.0)}, "w0_npc_0")
	_check("a seat under shade lies within the footprint", (under["pos"] as Vector2).length() < 3.5)
	var night_cold := {"night": true, "temp_c": 6.0}
	_check("firepit auto: lit on a cold night, out by day and on a warm night",
		FirepitBuilder.lit_for({}, night_cold) and not FirepitBuilder.lit_for({}, {"night": false, "temp_c": 6.0})
		and not FirepitBuilder.lit_for({}, {"night": true, "temp_c": 22.0}))
	_check("firepit: its own threshold, always and out",
		FirepitBuilder.lit_for({"firepit_below_c": 25.0}, {"night": true, "temp_c": 22.0})
		and FirepitBuilder.lit_for({"firepit_mode": "on"}, {"night": false})
		and not FirepitBuilder.lit_for({"firepit_mode": "off"}, night_cold))
	_check("firepit: an unknown temperature at night counts as cold",
		FirepitBuilder.lit_for({}, {"night": true, "temp_c": NAN}))


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
	effigy_idle["pull"] = VenueCrowd.EFFIGY_IDLE_PULL
	effigy_idle["draw"] = VenueCrowd.EFFIGY_IDLE_DRAW
	_check("an unlit effigy 140 m away does not beat a quiet person's temple next door",
		str(NpcVenueChoice.pick({"music": 0.1, "quiet": 1.0, "social": 0.1, "art": 0.1},
		here, [quiet_near, effigy_idle])["id"]) == "t")
	# ...but at the same distance it out-draws an ordinary art piece.
	var art := {"id": "r", "type": "art", "pos": Vector2(40, 0), "draw": 0.55, "occupants": 0, "capacity": 0}
	var effigy_mid := effigy_idle.duplicate()
	effigy_mid["pos"] = Vector2(40, 0)
	_check("an unlit effigy out-draws an art piece at the same distance",
		NpcVenueChoice.score(taste, here, effigy_mid) > NpcVenueChoice.score(taste, here, art))


## The burn's sequence inside the pre-roll (gather -> fire flow -> sandmen ->
## the burn), the fire flow's lane, the sandmen's posts, the breach test, the
## circle's tangent, and the turnout share.
func _test_burn_sequence() -> void:
	var rec := FireTimeline.make(100.0, {"climb_h": 0.75, "bonfire_h": 2.0, "ember_h": 1.0,
		"preroll_h": 0.75, "height_m": 10.0, "footprint_r_m": 3.0, "mass_kg": 800.0})
	var g := VenueCrowd.effigy_phase(rec, 100.1)
	var f := VenueCrowd.effigy_phase(rec, 100.4)
	var sm := VenueCrowd.effigy_phase(rec, 100.7)
	var bn := VenueCrowd.effigy_phase(rec, 101.0)
	_check("pre-roll stages run gather -> flow -> sandmen, then the burn",
		str(g["stage"]) == VenueCrowd.STAGE_GATHER and str(f["stage"]) == VenueCrowd.STAGE_FLOW
		and str(sm["stage"]) == VenueCrowd.STAGE_SANDMEN and str(bn["stage"]) == VenueCrowd.STAGE_BURN,
		"%s %s %s %s" % [g["stage"], f["stage"], sm["stage"], bn["stage"]])
	_check("the perimeter holds only from the sandmen on",
		not bool(g["perimeter"]) and not bool(f["perimeter"]) and bool(sm["perimeter"]) and bool(bn["perimeter"]))
	_check("the flow began at GATHER_FRAC of the pre-roll",
		absf(float(f["flow_t0"]) - (100.0 + VenueCrowd.GATHER_FRAC * 0.75)) < 1e-6)
	_check("every stage of one burn carries the same burn key",
		str(g["burn_key"]) == str(bn["burn_key"]) and not str(g["burn_key"]).is_empty())
	var safe_r := float(sm["safe_r"])
	# Fire flow: a slow CCW lane inside the line.
	var orbit := VenueCrowd.flow_orbit(Vector2(5, 5), safe_r, 2, 12, 100.26)
	var q0 := VenueCrowd.orbit_point(orbit, 100.3)
	var q1 := VenueCrowd.orbit_point(orbit, 100.301)
	_check("the flow lane keeps its radius, inside the line",
		absf(q0.distance_to(Vector2(5, 5)) - q1.distance_to(Vector2(5, 5))) < 1e-4
		and q0.distance_to(Vector2(5, 5)) < safe_r)
	var da := wrapf(atan2(-(q1.y - 5.0), q1.x - 5.0) - atan2(-(q0.y - 5.0), q0.x - 5.0), -PI, PI)
	_check("the flow runs counter-clockwise from above", da > 0.0, "%.4f" % da)
	var step := (q1 - q0).normalized()
	_check("ccw_tangent points along the motion", step.dot(VenueCrowd.ccw_tangent(Vector2(5, 5), q0)) > 0.99)
	_check("the flow gets 10-20 performers",
		VenueCrowd.flow_count(0) == VenueCrowd.FLOW_MIN and VenueCrowd.flow_count(100000) == VenueCrowd.FLOW_MAX
		and VenueCrowd.flow_count(450) == 15)
	# Sandmen: posts just inside the line, facing out, spread round it.
	var n := VenueCrowd.sandman_count(safe_r)
	_check("sandmen count is within bounds (%d)" % n, n >= VenueCrowd.SANDMAN_MIN and n <= VenueCrowd.SANDMAN_MAX)
	var ok_posts := true
	var min_gap := INF
	var prev := Vector2.INF
	for k in n:
		var post: Dictionary = VenueCrowd.sandman_post(Vector2.ZERO, safe_r, k, n)
		var pp: Vector2 = post["pos"]
		var face: Vector2 = post["face"]
		if pp.length() >= safe_r or pp.length() < safe_r - 1.0:
			ok_posts = false
		if (face - pp).normalized().dot(pp.normalized()) < 0.99:
			ok_posts = false
		if prev != Vector2.INF:
			min_gap = minf(min_gap, prev.distance_to(pp))
		prev = pp
	_check("every sandman kneels just inside the line, facing out", ok_posts)
	_check("sandmen are spread round the line (min gap %.1f m)" % min_gap, min_gap > 2.0)
	_check("a sandman's own post is not a breach; a step past it is",
		not VenueCrowd.breaches(Vector2.ZERO, safe_r, Vector2(safe_r - VenueCrowd.BREACH_INSET_M * 0.5, 0))
		and VenueCrowd.breaches(Vector2.ZERO, safe_r, Vector2(safe_r - 2.0, 0)))
	# Turnout: about BURN_TURNOUT of the site, deterministically.
	var yes := 0
	for i in 2000:
		if VenueCrowd.attends("p%d" % i, str(bn["burn_key"])):
			yes += 1
	_check("about 85 percent attend the burn (%d of 2000)" % yes, yes > 1600 and yes < 1800)
	_check("attendance is deterministic and needs a burn key",
		VenueCrowd.attends("p7", "1.0") == VenueCrowd.attends("p7", "1.0") and not VenueCrowd.attends("p7", ""))
	var lbls := [NpcVenueState.resolve({"id": "e", "space_type": "effigy", "draw": 0.5}, 21.0, 100.1, rec),
		NpcVenueState.resolve({"id": "e", "space_type": "effigy", "draw": 0.5}, 21.0, 100.4, rec)]
	_check("the venue state names the stage", str(lbls[0]["label"]) != str(lbls[1]["label"])
		and str(lbls[1].get("stage", "")) == VenueCrowd.STAGE_FLOW)
