extends SceneTree

## Headless self-test for festival mode's pure data layer
## (core/camps/festival_seed_layout.gd + the PopTestPrefs easy override):
## painted-camp headcounts (monotonic in area, style-aware, clamped), the
## lot-shaped records the graph sync consumes (free camps and orphans only),
## the venue plan (a sleep + kitchen per camp as DISTINCT area targets, every
## shared venue clear of every camp and past the world veto, counts sized
## from CampProvisioning, the stage carrying its evening set, the label
## prefix on everything), the cluster + inset geometry, and the easy-mode
## override reading ON for every guardrail without touching the saved flags.
## Carries EXPECTED_CHECKS: a runtime error aborts a test function while the
## suite still prints PASS. Run --import first.
##   godot --headless --path . --script core/camps/festival_seed_layout_selftest.gd

const EXPECTED_CHECKS := 87

var _failures := 0
var _checks := 0


func _init() -> void:
	PopTestPrefs.reset_defaults()
	_test_headcount()
	_test_camp_lots()
	_test_geometry()
	_test_venue_plan()
	_test_missing_types()
	_test_easy_override()
	_test_population_target()
	_test_setup_layout()
	_test_camp_linked_spaces()
	_test_supply_modes()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("FESTIVAL SEED LAYOUT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("FESTIVAL SEED LAYOUT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


static func _rect(x0: float, z0: float, x1: float, z1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)])


static func _rec(id: String, poly: PackedVector2Array, style: String = "mixed",
		group := "", headcount := 0) -> Dictionary:
	return {"id": id, "name": id, "polygon": poly, "holes": [], "style": style,
		"group_id": group, "headcount": headcount}


func _test_headcount() -> void:
	var small := FestivalSeedLayout.camp_headcount(_rec("a", _rect(0, 0, 30, 20)))
	var big := FestivalSeedLayout.camp_headcount(_rec("b", _rect(0, 0, 120, 90)))
	_check("a bigger camp sleeps more people", big > small, "%d vs %d" % [small, big])
	_check("headcount is never below the floor", small >= FestivalSeedLayout.MIN_HEADCOUNT)
	var huge := FestivalSeedLayout.camp_headcount(_rec("c", _rect(0, 0, 2000, 2000)))
	_check("headcount is clamped at the ceiling", huge == FestivalSeedLayout.MAX_HEADCOUNT)
	_check("a degenerate outline sleeps nobody",
		FestivalSeedLayout.camp_headcount(_rec("d", PackedVector2Array())) == 0)
	# The same ground at the placement tool's own density, so a painted camp
	# and an assigned lot of equal area agree on their headcount.
	var area := CampAreaLayer.record_area(_rec("e", _rect(0, 0, 120, 90)))
	_check("headcount == the assigner's default for the same area + style",
		big == clampi(FestivalAssigner.default_headcount(area, "mixed"),
			FestivalSeedLayout.MIN_HEADCOUNT, FestivalSeedLayout.MAX_HEADCOUNT))
	var rv := FestivalSeedLayout.camp_headcount(_rec("f", _rect(0, 0, 120, 90), "rv_park"))
	var tents := FestivalSeedLayout.camp_headcount(_rec("g", _rect(0, 0, 120, 90), "tent_village"))
	_check("style changes the density (an RV park and a tent village differ)", rv != tents,
		"%d vs %d" % [rv, tents])


func _test_camp_lots() -> void:
	var areas := [
		_rec("camp_1", _rect(0, 0, 50, 40), "mixed", "", 12),
		_rec("camp_2", _rect(100, 0, 150, 40), "rv_park", "", 0),       # unpopulated
		_rec("camp_3", _rect(200, 0, 250, 40), "mixed", "zone_1", 9),   # live lot
		_rec("camp_4", _rect(300, 0, 350, 40), "mixed", "zone_9", 7),   # orphan lot camp
	]
	var lots := FestivalSeedLayout.camp_lots(areas, {"zone_1": true})
	_check("populated free camps and orphans become lots; live lots and empty camps do not",
		lots.size() == 2, str(lots.size()))
	var ids: Array = []
	for l in lots:
		ids.append(str(l["lot_id"]))
	_check("lot ids are prefixed camp ids", ids == ["camp:camp_1", "camp:camp_4"], str(ids))
	var l0: Dictionary = lots[0]
	var ac: Dictionary = l0["assigned_camp"]
	_check("the assignment carries name, style, headcount and manual",
		str(ac["name"]) == "camp_1" and str(ac["style"]) == "mixed" and int(ac["headcount"]) == 12
		and bool(ac["manual"]))
	_check("the lot keeps the camp outline + its record id",
		(l0["polygon"] as PackedVector2Array).size() == 4 and str(l0["camp_area_id"]) == "camp_1")
	_check("camp_id_for_lot inverts lot_id_for_camp",
		FestivalSeedLayout.camp_id_for_lot(FestivalSeedLayout.lot_id_for_camp("camp_7")) == "camp_7"
		and FestivalSeedLayout.camp_id_for_lot("lot_3") == "")


func _test_geometry() -> void:
	var ra := _rect(-100, -50, -60, -10)
	var rb := _rect(60, 10, 100, 50)
	var cl := FestivalSeedLayout.cluster([ra, rb])
	var want_c := (CampAreaLayer._inner_point(ra) + CampAreaLayer._inner_point(rb)) * 0.5
	_check("cluster centre is the mean of the camps' interior points",
		(cl["centre"] as Vector2).distance_to(want_c) < 1e-3, str(cl["centre"]))
	var want_r := 0.0
	for v in ra + rb:
		want_r = maxf(want_r, (cl["centre"] as Vector2).distance_to(v))
	_check("cluster radius reaches the farthest vertex",
		absf(float(cl["radius"]) - want_r) < 1e-3, str(cl["radius"]))
	_check("an empty cluster is the origin at radius 0",
		FestivalSeedLayout.cluster([]) == {"centre": Vector2.ZERO, "radius": 0.0})
	var poly := _rect(0, 0, 100, 60)
	var inner := FestivalSeedLayout.inset_polygon(poly, 0.45)
	var inside := true
	for v in inner:
		inside = inside and Geometry2D.is_point_in_polygon(v, poly)
	_check("the inset polygon lies inside the original", inside)
	_check("the inset polygon is a different target than the outline", inner != poly)
	_check("clear_of_camps vetoes a square over a camp",
		not FestivalSeedLayout.clear_of_camps(Vector2(50, 30), 6.0, [poly]))
	_check("clear_of_camps vetoes a square whose edge crosses a camp corner",
		not FestivalSeedLayout.clear_of_camps(Vector2(103, 63), 6.0, [poly]))
	_check("clear_of_camps passes a square well away from every camp",
		FestivalSeedLayout.clear_of_camps(Vector2(150, 30), 6.0, [poly]))


func _test_venue_plan() -> void:
	var camps := [
		{"id": "camp_1", "name": "Kidsville", "poly": _rect(-120, -80, -40, -20), "headcount": 40},
		{"id": "camp_2", "name": "Dustfish", "poly": _rect(40, -80, 120, -20), "headcount": 60},
		{"id": "camp_3", "name": "Nap Camp", "poly": _rect(-40, 40, 40, 100), "headcount": 20},
	]
	var polys: Array = []
	for c in camps:
		polys.append(c["poly"])
	# The world veto: the ground within VETO_R of the cluster centre is a
	# pond — every bearing's first candidates sit on it, so the search MUST
	# consult the veto and step past it.
	var cl0 := FestivalSeedLayout.cluster(polys)
	var veto_r := 60.0
	# A lambda captures locals BY VALUE, so the counter lives in an Array.
	var veto_hits: Array = [0]
	var free_fn := func(p: Vector2, _half: float) -> bool:
		if p.distance_to(cl0["centre"]) < veto_r:
			veto_hits[0] = int(veto_hits[0]) + 1
			return false
		return true
	var plan := FestivalSeedLayout.venue_plan(camps, free_fn)
	var plan_free := FestivalSeedLayout.venue_plan(camps)
	var by_type: Dictionary = {}
	var all_prefixed := true
	for v in plan:
		var vd: Dictionary = v
		by_type[str(vd["type"])] = int(by_type.get(str(vd["type"]), 0)) + 1
		all_prefixed = all_prefixed and str(vd["label"]).begins_with(FestivalSeedLayout.LABEL_PREFIX)
	_check("one sleep area per camp", int(by_type.get("sleep", 0)) == 3, str(by_type))
	_check("one kitchen per camp", int(by_type.get("kitchen", 0)) == 3)
	_check("every required type is present", FestivalSeedLayout.missing_types(by_type.keys()).is_empty(),
		str(FestivalSeedLayout.missing_types(by_type.keys())))
	_check("every label carries the festival prefix", all_prefixed)
	var specs := FestivalSeedLayout.shared_venue_specs(120)
	var want: Dictionary = {}
	for s in specs:
		want[str(s["type"])] = int(s["count"])
	var counts_ok := true
	for t in want.keys():
		counts_ok = counts_ok and int(by_type.get(t, 0)) == int(want[t])
	_check("shared venue counts match shared_venue_specs for the summed headcount", counts_ok,
		"%s vs %s" % [str(by_type), str(want)])
	var req := CampProvisioning.requirements(120)
	_check("portapotty banks are sized from the provisioning requirement",
		int(want["restroom"]) == maxi(int(ceil(float(req["portapotty_units"])
			/ float(FestivalSeedLayout.PORTAPOTTY_UNITS_PER_BANK))), 1))
	# Distinct targets per camp, and the sleep area IS the camp outline.
	var sleep_polys: Array = []
	var kitchen_polys: Array = []
	for v in plan:
		var vd: Dictionary = v
		if str(vd["type"]) == "sleep":
			sleep_polys.append(vd["poly"])
		elif str(vd["type"]) == "kitchen":
			kitchen_polys.append(vd["poly"])
	_check("sleep and kitchen targets differ for every camp", sleep_polys[0] != kitchen_polys[0]
		and sleep_polys[1] != kitchen_polys[1] and sleep_polys[2] != kitchen_polys[2])
	_check("the sleep area is the camp outline",
		sleep_polys[0] == FestivalSeedLayout.poly_to_array(camps[0]["poly"]))
	var sleep_cap_ok := true
	for v in plan:
		var vd: Dictionary = v
		if str(vd["type"]) == "sleep":
			for c in camps:
				if str(c["id"]) == str(vd["camp_id"]):
					sleep_cap_ok = sleep_cap_ok and int(vd["cap"]) == int(c["headcount"])
	_check("each sleep area's capacity is its camp's headcount", sleep_cap_ok)
	# Every shared venue clear of every camp, and never on the vetoed band.
	var clear := true
	var vetoed := false
	var stage: Dictionary = {}
	for v in plan:
		var vd: Dictionary = v
		if not str(vd["camp_id"]).is_empty():
			continue
		var pts := SpaceRegistry.poly_points(vd["poly"])
		var c := (pts[0] + pts[2]) * 0.5
		var half := absf(pts[2].x - pts[0].x) * 0.5
		clear = clear and FestivalSeedLayout.clear_of_camps(c, half, polys)
		vetoed = vetoed or c.distance_to(cl0["centre"]) < veto_r
		if str(vd["type"]) == "stage":
			stage = vd
	_check("every shared venue is clear of every camp", clear)
	_check("the world veto is consulted and obeyed", int(veto_hits[0]) > 0 and not vetoed,
		"veto hits %d" % int(veto_hits[0]))
	_check("the stage carries its evening set", not stage.is_empty()
		and (stage["fields"] as Dictionary).has("program")
		and float(((stage["fields"] as Dictionary)["program"] as Array)[0]["start_h"]) == 20.0)
	_check("the stage's capacity is AUTO (as big as the crowd)", int(stage["cap"]) == SpaceRegistry.CAPACITY_AUTO)
	# Spots are searched from the cluster CENTRE outward: with free ground in
	# the middle, the nearest shared venue sits well inside the hull radius.
	var cl := FestivalSeedLayout.cluster(polys)
	var nearest := INF
	for v in plan_free:
		var vd: Dictionary = v
		if str(vd["camp_id"]).is_empty():
			var pts := SpaceRegistry.poly_points(vd["poly"])
			nearest = minf(nearest, ((pts[0] + pts[2]) * 0.5).distance_to(cl["centre"]))
	_check("utilities land in the ground between camps, not on a far ring",
		nearest < float(cl["radius"]) * 0.5, "%.1f vs radius %.1f" % [nearest, float(cl["radius"])])
	_check("a plan over no camps is empty", FestivalSeedLayout.venue_plan([]).is_empty())
	# Determinism: the same camps give the same plan.
	_check("the plan is deterministic", FestivalSeedLayout.venue_plan(camps, free_fn) == plan)
	# Labels for repeated venues are lettered, single ones are not.
	var labels: Array = []
	for v in plan:
		labels.append(str(v["label"]))
	_check("the single stage is unlettered",
		labels.has(FestivalSeedLayout.LABEL_PREFIX + "Bass stage"))
	_check("two portapotty banks are lettered A and B when there are two", int(want["restroom"]) < 2
		or (labels.has(FestivalSeedLayout.LABEL_PREFIX + "Portapotties A")
			and labels.has(FestivalSeedLayout.LABEL_PREFIX + "Portapotties B")))


func _test_missing_types() -> void:
	_check("missing_types names what is absent",
		FestivalSeedLayout.missing_types(["sleep", "kitchen"]) == ["restroom", "water_point", "shower", "stage"])
	_check("missing_types is empty when everything is tagged",
		FestivalSeedLayout.missing_types(FestivalSeedLayout.REQUIRED_TYPES.duplicate()).is_empty())
	# Per-camp types: one tagged bed elsewhere does not stop a camp getting its own.
	var camp_a := {"type": "sleep", "camp_id": "a", "poly": [[0, 0], [20, 0], [20, 20], [0, 20]]}
	var camp_b := {"type": "sleep", "camp_id": "b", "poly": [[100, 0], [120, 0], [120, 20], [100, 20]]}
	var one_pod := [{"type": "sleep", "pos": Vector2(10, 10)}]
	_check("a camp whose outline holds a tagged bed is left alone",
		not FestivalSeedLayout.needs_seeding(camp_a, [], one_pod))
	_check("every OTHER camp still gets its beds though the type is present",
		FestivalSeedLayout.needs_seeding(camp_b, [], one_pod))
	_check("a kitchen in the camp does not count as beds",
		FestivalSeedLayout.needs_seeding(camp_a, [], [{"type": "kitchen", "pos": Vector2(10, 10)}]))
	_check("a shared type is seeded only when the site has none",
		FestivalSeedLayout.needs_seeding({"type": "restroom", "poly": []}, ["restroom"], [])
		and not FestivalSeedLayout.needs_seeding({"type": "restroom", "poly": []}, [], []))


func _test_easy_override() -> void:
	PopTestPrefs.reset_defaults()
	_check("defaults: no guardrail off", not PopTestPrefs.any_active())
	var g0 := PopTestPrefs.generation()
	PopTestPrefs.set_easy_override(true)
	_check("easy override: ideal supply reads on", PopTestPrefs.ideal_supply())
	_check("easy override: ignore capacity reads on", PopTestPrefs.ignore_capacity())
	_check("easy override: no departures reads on", PopTestPrefs.no_departures())
	_check("easy override: mute alarms reads on", PopTestPrefs.mute_alarms())
	_check("easy override counts as active", PopTestPrefs.any_active() and PopTestPrefs.easy_override())
	_check("the override bumps the generation so pollers notice", PopTestPrefs.generation() > g0)
	var saved := PopTestPrefs.saved_flags()
	_check("the SAVED flags are untouched by the override",
		not bool(saved["ideal_supply"]) and not bool(saved["ignore_capacity"])
		and not bool(saved["no_departures"]) and not bool(saved["mute_alarms"]))
	var g1 := PopTestPrefs.generation()
	PopTestPrefs.set_easy_override(true)
	_check("re-setting the same override is a no-op", PopTestPrefs.generation() == g1)
	PopTestPrefs.set_easy_override(false)
	_check("clearing the override hands every guardrail back", not PopTestPrefs.any_active()
		and not PopTestPrefs.ideal_supply() and not PopTestPrefs.no_departures())
	# A player's own saved flag survives the override round trip.
	PopTestPrefs.set_no_departures(true)
	PopTestPrefs.set_easy_override(true)
	PopTestPrefs.set_easy_override(false)
	_check("a saved flag the player set stays set after the override is cleared",
		PopTestPrefs.no_departures() and not PopTestPrefs.ideal_supply())
	_check("reset_defaults clears the override too",
		(func() -> bool:
			PopTestPrefs.set_easy_override(true)
			PopTestPrefs.reset_defaults()
			return not PopTestPrefs.easy_override()).call())


## The festival population target: the camps' natural split scaled to an
## exact total, floors kept, 0 = unchanged — and the pref round-trips.
func _test_population_target() -> void:
	var natural := [120, 40, 300, 7, 2, 55]
	var same := FestivalSeedLayout.scale_headcounts(natural, 0)
	_check("target 0 leaves the natural split alone", same == natural)
	var t400 := FestivalSeedLayout.scale_headcounts(natural, 400)
	var sum := 0
	var floors_ok := true
	for v in t400:
		sum += int(v)
		if int(v) < FestivalSeedLayout.MIN_SCALED_HEADCOUNT:
			floors_ok = false
	_check("scaled to EXACTLY the target (%d)" % sum, sum == 400)
	_check("no camp below the floor", floors_ok)
	_check("the biggest camp stays the biggest", int(t400[2]) > int(t400[0]) and int(t400[0]) > int(t400[1]))
	var t100 := FestivalSeedLayout.scale_headcounts(natural, 100)
	var s100 := 0
	for v in t100:
		s100 += int(v)
	_check("scaling down twice as hard still lands exactly", s100 == 100)
	var tiny := FestivalSeedLayout.scale_headcounts(natural, 5)
	_check("floors win when the target is below them", int(tiny[0]) == 2 and tiny.size() == natural.size())
	var path := "user://_selftest_pop_testing.cfg"
	PopTestPrefs.reset_defaults()
	PopTestPrefs.set_festival_target_people(420)
	PopTestPrefs.save_to(path)
	PopTestPrefs.reset_defaults()
	PopTestPrefs.load_from(path)
	_check("the target round-trips through the prefs file", PopTestPrefs.festival_target_people() == 420)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	PopTestPrefs.reset_defaults()


## The setup card: N named camps of M people round the marker — every camp
## sized to sleep its headcount, none overlapping, all clear of the plaza,
## centred on the marker, a vetoed spot pushed outward, names kept.
func _test_setup_layout() -> void:
	var marker := Vector2(1247.4, -706.5)
	var spec := {"camps": []}
	for i in 6:
		(spec["camps"] as Array).append({"name": "Camp %s" % char(65 + i), "people": 10 + (i % 3), "style": "mixed"})
	var plan := FestivalSeedLayout.setup_layout(spec, marker)
	_check("setup: one camp per row", plan.size() == 6)
	var people := 0
	var fits := true
	var polys: Array = []
	var c := Vector2.ZERO
	for p in plan:
		var d: Dictionary = p
		people += int(d["people"])
		var area := CampAreaLayer.polygon_area(d["polygon"])
		if area * FestivalAssigner.people_per_m2("mixed") < float(d["people"]) - 0.01:
			fits = false
		polys.append(d["polygon"])
		c += CampAreaLayer._inner_point(d["polygon"])
	c /= float(plan.size())
	_check("setup: the headcounts are exact (%d)" % people, people == 66)
	_check("setup: every outline sleeps its headcount at its style's density", fits)
	var overlap := false
	for i in polys.size():
		for j in range(i + 1, polys.size()):
			if not Geometry2D.intersect_polygons(polys[i], polys[j]).is_empty():
				overlap = true
	_check("setup: no two camps overlap", not overlap)
	_check("setup: centred on the marker (%.1f m off)" % c.distance_to(marker), c.distance_to(marker) < 25.0)
	var plaza_clear := true
	for poly in polys:
		for v in (poly as PackedVector2Array):
			if v.distance_to(marker) < FestivalSeedLayout.SETUP_PLAZA_R_M - 1.0:
				plaza_clear = false
	_check("setup: the plaza in the middle stays open", plaza_clear)
	_check("setup: names kept", str((plan[2] as Dictionary)["name"]) == "Camp C")
	# A veto on the north spot pushes that camp outward along its bearing.
	# Ground 30..200 m north of the marker is unusable (a building, water).
	var veto := func(pc: Vector2, _half: float) -> bool:
		return not (pc.y < marker.y - 30.0 and pc.y > marker.y - 200.0 and absf(pc.x - marker.x) < 60.0)
	var pushed := FestivalSeedLayout.setup_layout(spec, marker, veto)
	var p0: Vector2 = (pushed[0] as Dictionary)["centre"]
	var q0: Vector2 = (plan[0] as Dictionary)["centre"]
	_check("setup: a vetoed spot is pushed outward", p0.distance_to(marker) > q0.distance_to(marker) + 1.0)
	var clean := FestivalSeedLayout.clean_setup({"camps": [{"name": "  ", "people": 1, "style": "nope"}]})
	_check("setup: rows are cleaned (name, people floor, style)", clean.size() == 1
		and str((clean[0] as Dictionary)["name"]) == "Camp 1" and int((clean[0] as Dictionary)["people"]) == 2
		and str((clean[0] as Dictionary)["style"]) == CampStyles.DEFAULT_STYLE)


## A camp's seeded beds + kitchen follow its outline; an area space can be
## retargeted / retyped / translated; seeded spaces are found by flag or by
## the legacy label prefix.
func _test_camp_linked_spaces() -> void:
	var reg := SpaceRegistry.create_empty()
	var poly := _rect(0, 0, 20, 20)
	var beds := reg.set_space_type({"kind": "area", "poly": FestivalSeedLayout.poly_to_array(poly)}, "sleep", 10, "beds")
	var kit := reg.set_space_type({"kind": "area", "poly": FestivalSeedLayout.poly_to_array(
		FestivalSeedLayout.inset_polygon(poly, FestivalSeedLayout.KITCHEN_INSET))}, "kitchen", 0, "kitchen")
	reg.set_space_fields(beds, {"camp_id": "camp:camp_1", "festival_seeded": true})
	reg.set_space_fields(kit, {"camp_id": "camp:camp_1"})
	var rev0 := reg.revision
	var moved := _rect(100, 50, 120, 70)
	var n := FestivalSeedLayout.follow_camp(reg, "camp:camp_1", moved)
	_check("follow: both linked spaces moved", n == 2)
	_check("follow: the registry revision moved", reg.revision > rev0)
	var bp := SpaceRegistry.poly_points((reg.find_by_id(beds).get("target", {}) as Dictionary).get("poly", []))
	_check("follow: beds = the new outline", bp == moved)
	var kp := SpaceRegistry.poly_points((reg.find_by_id(kit).get("target", {}) as Dictionary).get("poly", []))
	_check("follow: kitchen = the inset outline", Geometry2D.is_point_in_polygon(CampAreaLayer._inner_point(kp), moved)
		and CampAreaLayer.polygon_area(kp) < CampAreaLayer.polygon_area(moved) * 0.5)
	_check("seeded: by flag", FestivalSeedLayout.is_seeded_space(reg.find_by_id(beds)))
	_check("seeded: by legacy prefix", FestivalSeedLayout.is_seeded_space({"label": FestivalSeedLayout.LABEL_PREFIX + "x"}))
	_check("seeded: not the player's own", not FestivalSeedLayout.is_seeded_space(reg.find_by_id(kit)))
	_check("retype keeps the id", reg.set_space_type_of(kit, "restroom") and str(reg.find_by_id(kit)["space_type"]) == "restroom")
	_check("retype refuses an unknown type", not reg.set_space_type_of(kit, "nope"))
	_check("retarget refuses a target another space holds",
		not reg.set_space_target(kit, (reg.find_by_id(beds)["target"] as Dictionary)))
	var t := reg.translate_areas(Vector2(5, -5), func(r: Dictionary) -> bool: return str(r.get("id", "")) == beds)
	var bp2 := SpaceRegistry.poly_points((reg.find_by_id(beds).get("target", {}) as Dictionary).get("poly", []))
	_check("translate: only the picked area moved, by the delta", t == 1 and bp2[0].is_equal_approx(moved[0] + Vector2(5, -5)))


## habitat_ideal: infinite always meets the need; own / shared follow only
## the player's SAVED switch (never festival mode's session override); unset
## follows the global switch.
func _test_supply_modes() -> void:
	PopTestPrefs.reset_defaults()
	PopTestPrefs.set_easy_override(true)
	_check("supply: infinite meets the need", PopTestPrefs.habitat_ideal("infinite"))
	_check("supply: own tanks ignore the festival override", not PopTestPrefs.habitat_ideal("own"))
	_check("supply: shared ignores it too", not PopTestPrefs.habitat_ideal("shared"))
	_check("supply: unset follows the override", PopTestPrefs.habitat_ideal(""))
	PopTestPrefs.set_easy_override(false)
	_check("supply: unset is off without it", not PopTestPrefs.habitat_ideal(""))
	PopTestPrefs.reset_defaults()
