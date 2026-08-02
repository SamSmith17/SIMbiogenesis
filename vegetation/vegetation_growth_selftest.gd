extends SceneTree

## Headless self-test for VegetationGrowth (age→scale curve, birth-time seeding,
## and the death+reseed generational turnover). Pure / offline.
## Run with:
##   godot --headless --path . --script vegetation/vegetation_growth_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

const HPY := VegetationGrowth.HOURS_PER_YEAR

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_scale_curve()
	_test_instance_scale()
	_test_lifecycle_senescence()
	_test_lettuce_90_days()
	_test_birth_times()
	_test_reseed_population()
	_test_reseed_radius()
	_test_reseed_zone()
	_test_seasonal_growth()
	_test_instance_map()
	_test_forest_age_profiles()
	_test_disabled_species()
	_test_settings_with_variant_non_clobber()
	_test_size_var_scales()
	if _failures == 0:
		print("VEG GROWTH SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG GROWTH SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _approx(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _test_scale_curve() -> void:
	var gy := 20.0
	_check("seedling scale at age 0",
		_approx(VegetationGrowth.scale_for_age(0.0, gy), VegetationGrowth.SEEDLING_SCALE, 1e-6),
		"got %f" % VegetationGrowth.scale_for_age(0.0, gy))
	_check("full scale at maturity",
		_approx(VegetationGrowth.scale_for_age(gy, gy), 1.0, 1e-6),
		"got %f" % VegetationGrowth.scale_for_age(gy, gy))
	_check("full scale past maturity (clamped)",
		_approx(VegetationGrowth.scale_for_age(gy * 3.0, gy), 1.0, 1e-6))
	# Monotonic increasing over the life.
	var mono := true
	var prev := -1.0
	for i in 21:
		var s := VegetationGrowth.scale_for_age(float(i), gy)
		if s < prev - 1e-6:
			mono = false
		prev = s
	_check("scale monotonic non-decreasing", mono)
	_check("gy<=0 disables growth (scale 1)",
		_approx(VegetationGrowth.scale_for_age(5.0, 0.0), 1.0, 1e-6))


func _test_instance_scale() -> void:
	var settings := {"pine_growth_years": 10.0, "growth_now_h": 10.0 * HPY}
	# Born at t=0, clock at 10 years → mature → full size.
	var mature := {"birth_h": 0.0}
	_check("instance mature full",
		_approx(VegetationGrowth.instance_scale_mult("pine", mature, settings), 1.0, 1e-6))
	# Born now → seedling.
	var seedling := {"birth_h": 10.0 * HPY}
	_check("instance seedling small",
		_approx(VegetationGrowth.instance_scale_mult("pine", seedling, settings),
			VegetationGrowth.SEEDLING_SCALE, 1e-6))
	# No birth stamp → renders full (never popped to seedling).
	_check("instance no birth → full",
		_approx(VegetationGrowth.instance_scale_mult("pine", {}, settings), 1.0, 1e-6))


func _test_birth_times() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var gy := 30.0
	var settings := {"pine_growth_years": gy}
	var bulk := {"pine": []}
	for i in 400:
		(bulk["pine"] as Array).append({"x": float(i), "z": 0.0, "scale": 1.0})
	VegetationGrowth.ensure_birth_times(bulk, 0.0, settings, rng, true)
	# Every record gets a birth_h, and every derived age sits within [0, gy].
	var all_have := true
	var all_in_range := true
	var sum_frac := 0.0
	for d in bulk["pine"]:
		if not d.has("birth_h"):
			all_have = false
			continue
		var age := (0.0 - float(d["birth_h"])) / HPY
		if age < -1e-3 or age > gy + 1e-3:
			all_in_range = false
		sum_frac += clampf(age / gy, 0.0, 1.0)
	_check("all records seeded birth_h", all_have)
	_check("ages within [0, gy]", all_in_range)
	# Distribution skews mature: mean age fraction should be well above 0.5.
	var mean_frac := sum_frac / 400.0
	_check("age distribution skews mature", mean_frac > 0.55,
		"mean age frac %f" % mean_frac)


func _test_reseed_population() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 999
	var gy := 5.0
	var settings := {"deciduous_growth_years": gy}
	var bulk := {"deciduous": []}
	var start_n := 300
	for i in start_n:
		# Spread birth times so a subset matures each tick.
		(bulk["deciduous"] as Array).append({
			"x": float(i % 20), "z": float(i / 20), "scale": 1.0,
			"birth_h": -rng.randf() * gy * HPY})
	var caps := VegetationGrowth.capture_caps(bulk)
	_check("cap captured", int(caps["deciduous"]) == start_n)
	# Advance the clock in yearly steps for a few generations; population must stay
	# bounded at the cap and never collapse to zero.
	var now := 0.0
	var min_seen := start_n
	var max_seen := start_n
	for step in 60:
		now += gy * 0.5 * HPY
		var add := func(slot: String, x: float, z: float, yaw: float, sc: float, card: Variant) -> Variant:
			var rec := {"x": x, "z": z, "yaw": yaw, "scale": sc}
			(bulk[slot] as Array).append(rec)
			return rec
		VegetationGrowth.advance_generations(bulk, now, settings, rng, caps, add)
		var n: int = (bulk["deciduous"] as Array).size()
		min_seen = mini(min_seen, n)
		max_seen = maxi(max_seen, n)
	_check("population never exceeds cap", max_seen <= start_n,
		"max %d cap %d" % [max_seen, start_n])
	_check("population does not collapse", min_seen > start_n / 2,
		"min %d" % min_seen)
	# After turnover all survivors carry a birth_h (seedlings stamped by add_cb path).
	var all_stamped := true
	for d in bulk["deciduous"]:
		if not d.has("birth_h"):
			all_stamped = false
	_check("post-turnover all stamped", all_stamped)


func _test_reseed_radius() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var gy := 2.0
	var settings := {"pine_growth_years": gy}
	# One matured parent at a known spot; its seedlings must land within 1 m.
	var bulk := {"pine": [{"x": 100.0, "z": 50.0, "scale": 1.0, "birth_h": -gy * HPY * 2.0}]}
	var caps := {"pine": 8}
	var seedling_positions: Array = []
	var add := func(slot: String, x: float, z: float, yaw: float, sc: float, card: Variant) -> Variant:
		var rec := {"x": x, "z": z, "yaw": yaw, "scale": sc}
		(bulk[slot] as Array).append(rec)
		seedling_positions.append(Vector2(x, z))
		return rec
	var changed := VegetationGrowth.advance_generations(bulk, 0.0, settings, rng, caps, add)
	_check("mature parent triggered turnover", changed)
	_check("at least one seedling", seedling_positions.size() >= 1)
	var all_near := true
	for p in seedling_positions:
		if Vector2(p.x - 100.0, p.y - 50.0).length() > VegetationGrowth.SEED_RADIUS_M + 1e-4:
			all_near = false
	_check("seedlings within SEED_RADIUS_M", all_near)


func _test_reseed_zone() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var gy := 2.0
	var settings := {"pine_growth_years": gy}
	var zone_poly := VegetationPaint.rect_to_polygon(Vector2(98.0, 48.0), Vector2(102.0, 52.0))
	var zone := GrowthZoneIndex.from_polygons([zone_poly])
	var bulk := {"pine": [{"x": 100.0, "z": 50.0, "scale": 1.0, "birth_h": -gy * HPY * 2.0}]}
	var caps := {"pine": 8}
	var seedling_positions: Array = []
	var add := func(slot: String, x: float, z: float, yaw: float, sc: float, card: Variant) -> Variant:
		var rec := {"x": x, "z": z, "yaw": yaw, "scale": sc}
		(bulk[slot] as Array).append(rec)
		seedling_positions.append(Vector2(x, z))
		return rec
	VegetationGrowth.advance_generations(bulk, 0.0, settings, rng, caps, add, zone)
	var in_zone := true
	for p in seedling_positions:
		if not zone.contains(p.x, p.y):
			in_zone = false
	_check("zone-bound seedlings inside polygon", in_zone or seedling_positions.is_empty())
	# Parent outside a distant zone → no reseeds escape into that zone from far away.
	seedling_positions.clear()
	bulk = {"pine": [{"x": 100.0, "z": 50.0, "scale": 1.0, "birth_h": -gy * HPY * 2.0}]}
	var far_zone := GrowthZoneIndex.from_polygons([
		VegetationPaint.rect_to_polygon(Vector2(0.0, 0.0), Vector2(2.0, 2.0))])
	VegetationGrowth.advance_generations(bulk, 0.0, settings, rng, caps, add, far_zone)
	_check("seedlings rejected outside distant zone", seedling_positions.is_empty())


func _doy(month: int, day: int) -> int:
	var c := CelestialClock.new()
	c.month = month
	c.day = day
	return c.day_of_year


func _test_seasonal_growth() -> void:
	var jan15 := _doy(1, 15)
	var jul15 := _doy(7, 15)
	var apr1 := _doy(4, 1)
	_check("winter structural factor low",
		VegetationGrowth.structural_growth_factor(jan15, 40.0) < VegetationGrowth.DORMANCY_THRESHOLD)
	_check("summer structural factor high",
		VegetationGrowth.structural_growth_factor(jul15, 40.0) > 0.8)
	_check("winter reseed blocked", not VegetationGrowth.reseed_allowed(jan15, 40.0))
	_check("summer reseed allowed", VegetationGrowth.reseed_allowed(jul15, 40.0))
	_check("milestone crossed spring (Mar→Apr)",
		VegetationGrowth.milestones_crossed(_doy(3, 20), apr1, 40.0))
	_check("no milestone within same week",
		not VegetationGrowth.milestones_crossed(jul15, _doy(7, 20), 40.0))
	# Southern hemisphere: January local summer → high factor at lat -40.
	_check("southern hemisphere summer factor high",
		VegetationGrowth.structural_growth_factor(jan15, -40.0) > 0.8)
	_check("generations skip when reseed disallowed", not VegetationGrowth.advance_generations(
		{"pine": [{"x": 0.0, "z": 0.0, "scale": 1.0, "birth_h": -200.0 * HPY}]},
		0.0, {"pine_growth_years": 5.0}, RandomNumberGenerator.new(), {"pine": 4},
		func(_s, _x, _z, _y, _sc, _c): return null, null, false))


func _test_instance_map() -> void:
	var map := VegetationInstanceMap.new()
	var gy := func(x: float, _z: float) -> float: return x * 0.0
	_check("empty map preserves budget", map.apply_scales({}, gy, 100) == 100)
	map.clear()
	_check("cleared map empty", map.is_empty())
	_test_instance_map_dedupe()


## Phase 9: ONE entry per plant, N slots. A NEAR-ring tree lives in two
## MultiMeshes, so the map used to hold two entries for it and a growth pass
## re-ran the terrain query and the growth curve once per SLOT.
func _test_instance_map_dedupe() -> void:
	var map := VegetationInstanceMap.new()
	var near_mmi := _stub_mmi(3)
	var far_mmi := _stub_mmi(3)
	var records: Array = []
	for i in 3:
		records.append({"x": float(i) * 10.0, "z": 0.0, "scale": 1.0, "birth_h": 0.0})
	# Register the same three plants twice — once per LOD tier, exactly as
	# _build_canopy_lod_bulk_batches does.
	for tier_mmi in [near_mmi, far_mmi]:
		for i in records.size():
			var d: Dictionary = records[i]
			map.add(tier_mmi, i, d, "pine", 1.0, 0.0, 0.0, false,
				float(d["x"]), float(d["z"]), 0.0, 0.0)
	_check("one entry per plant, not per slot", map.entry_count() == 3,
		"got %d" % map.entry_count())
	_check("both tiers registered as slots", map.slot_count() == 6,
		"got %d" % map.slot_count())

	# The ground query now runs once per PLANT. Counting the calls is the whole
	# point of the change, so count them.
	var calls := {"n": 0}
	var counting_gy := func(_x: float, _z: float) -> float:
		calls.n += 1
		return 0.0
	var st := {"pine_growth_years": 10.0, "growth_now_h": 5.0 * HPY}
	map.apply_scales(st, counting_gy, -1)
	_check("one ground query per plant", int(calls.n) == 3, "got %d" % int(calls.n))

	# NOTE: the transform WRITE itself cannot be observed here — under the
	# headless dummy renderer MultiMesh.set_instance_transform does not
	# round-trip through get_instance_transform (the buffer lives in the
	# RenderingServer, which is a stub). What is checkable offline is the value
	# the map derives per entry; the visual result is covered by --capture=veg.
	var expect := VegetationGrowth.instance_scale_mult("pine", records[1], st)
	_check("entry scale matches the growth curve",
		is_equal_approx(map.scale_mult_at(1, st), expect),
		"%.4f vs %.4f" % [map.scale_mult_at(1, st), expect])
	_check("growth actually moved the scale", expect < 0.99 and expect > 0.1,
		"%.4f" % expect)

	# Budget counts plants, so a budget of 2 leaves exactly one plant pending.
	map.reset_cursor()
	calls.n = 0
	var rem := map.apply_scales(st, counting_gy, 2)
	_check("budget counts plants", rem == 0 and int(calls.n) == 2,
		"rem=%d calls=%d" % [rem, int(calls.n)])

	# Scale-only (impostor) slots never re-sample terrain.
	var imp := VegetationInstanceMap.new()
	var imp_mmi := _stub_mmi(2)
	for i in 2:
		var d := {"x": float(i), "z": 0.0, "scale": 1.0, "birth_h": 0.0}
		imp.add(imp_mmi, i, d, "pine", 1.0, 0.0, 0.0, false, float(i), 0.0, 0.0, 0.0, false)
	calls.n = 0
	imp.apply_scales(st, counting_gy, -1)
	_check("impostor slots are scale-only", int(calls.n) == 0, "got %d" % int(calls.n))

	# A freed tier drops its slot without losing the plant (rebuilds free MMIs
	# while the growth map outlives them).
	far_mmi.free()
	map.reset_cursor()
	map.apply_scales(st, gy_zero(), -1)
	_check("freed tier drops only its slot",
		map.entry_count() == 3 and map.slot_count() == 3,
		"entries=%d slots=%d" % [map.entry_count(), map.slot_count()])
	near_mmi.free()


func gy_zero() -> Callable:
	return func(_x: float, _z: float) -> float: return 0.0


func _stub_mmi(count: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = count
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	return mi


## Phase 9: the forest-age profile decides where in the growth span a freshly
## seeded stand starts. MATURE must stay the default and keep the old behaviour.
func _test_forest_age_profiles() -> void:
	_check("default profile is mature",
		VegetationGrowth.forest_age_profile({}) == VegetationGrowth.FOREST_AGE_MATURE)
	_check("unknown profile falls back to mature",
		VegetationGrowth.forest_age_profile({"forest_age": "nonsense"})
			== VegetationGrowth.FOREST_AGE_MATURE)
	_check("profile is case-insensitive",
		VegetationGrowth.forest_age_profile({"forest_age": "YOUNG"})
			== VegetationGrowth.FOREST_AGE_YOUNG)

	# Every profile stays inside the span, and the endpoints are shared.
	for profile in [VegetationGrowth.FOREST_AGE_MATURE, VegetationGrowth.FOREST_AGE_MIXED,
			VegetationGrowth.FOREST_AGE_YOUNG]:
		for r in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var f := VegetationGrowth.age_fraction(profile, r)
			_check("%s age fraction in range at r=%.2f" % [profile, r],
				f >= 0.0 and f <= 1.0, "%.4f" % f)

	# Mean age ordering is the whole feature: young < mixed < mature.
	var means := {}
	for profile in [VegetationGrowth.FOREST_AGE_MATURE, VegetationGrowth.FOREST_AGE_MIXED,
			VegetationGrowth.FOREST_AGE_YOUNG]:
		var total := 0.0
		var n := 400
		for i in n:
			total += VegetationGrowth.age_fraction(profile, float(i) / float(n - 1))
		means[profile] = total / float(n)
	_check("young stand is younger than mixed",
		float(means[VegetationGrowth.FOREST_AGE_YOUNG])
			< float(means[VegetationGrowth.FOREST_AGE_MIXED]),
		str(means))
	_check("mixed is younger than mature",
		float(means[VegetationGrowth.FOREST_AGE_MIXED])
			< float(means[VegetationGrowth.FOREST_AGE_MATURE]),
		str(means))
	_check("mixed averages mid-span",
		absf(float(means[VegetationGrowth.FOREST_AGE_MIXED]) - 0.5) < 0.01,
		str(means[VegetationGrowth.FOREST_AGE_MIXED]))

	# ensure_birth_times honours it: a young stand is visibly smaller.
	var st := {"pine_growth_years": 20.0, "growth_now_h": 0.0}
	var sizes := {}
	for profile in [VegetationGrowth.FOREST_AGE_MATURE, VegetationGrowth.FOREST_AGE_YOUNG]:
		var rng := RandomNumberGenerator.new()
		rng.seed = 4242
		var bulk := {"pine": []}
		for i in 200:
			(bulk["pine"] as Array).append({"x": float(i), "z": 0.0, "scale": 1.0})
		var s2 := st.duplicate()
		s2["forest_age"] = profile
		VegetationGrowth.ensure_birth_times(bulk, 0.0, s2, rng, true)
		var total := 0.0
		for item in bulk["pine"]:
			total += VegetationGrowth.instance_scale_mult("pine", item, s2)
		sizes[profile] = total / 200.0
	_check("young stand renders smaller than a mature one",
		float(sizes[VegetationGrowth.FOREST_AGE_YOUNG])
			< float(sizes[VegetationGrowth.FOREST_AGE_MATURE]) - 0.05,
		str(sizes))
	# The default path must be byte-identical to "mature" — an untouched map
	# keeps exactly the forest it had before this key existed.
	var rng_a := RandomNumberGenerator.new()
	rng_a.seed = 77
	var bulk_a := {"pine": [{"x": 0.0, "z": 0.0, "scale": 1.0}]}
	VegetationGrowth.ensure_birth_times(bulk_a, 100.0, st, rng_a, true)
	var rng_b := RandomNumberGenerator.new()
	rng_b.seed = 77
	var bulk_b := {"pine": [{"x": 0.0, "z": 0.0, "scale": 1.0}]}
	var st_mature := st.duplicate()
	st_mature["forest_age"] = VegetationGrowth.FOREST_AGE_MATURE
	VegetationGrowth.ensure_birth_times(bulk_b, 100.0, st_mature, rng_b, true)
	_check("default == mature",
		is_equal_approx(float((bulk_a["pine"][0] as Dictionary)["birth_h"]),
			float((bulk_b["pine"][0] as Dictionary)["birth_h"])))
	_check("forest_age is a style default",
		str(VegetationStyleConfig.defaults().get("forest_age", ""))
			== VegetationGrowth.FOREST_AGE_MATURE)


func _test_lifecycle_senescence() -> void:
	var grow_h := 10.0 * HPY
	var sen_h := 5.0 * HPY
	_check("lifecycle seedling",
		_approx(VegetationGrowth.scale_for_lifecycle(0.0, grow_h, sen_h),
			VegetationGrowth.SEEDLING_SCALE, 1e-6))
	_check("lifecycle full at maturity",
		_approx(VegetationGrowth.scale_for_lifecycle(grow_h, grow_h, sen_h), 1.0, 1e-6))
	_check("lifecycle senescent floor",
		_approx(VegetationGrowth.scale_for_lifecycle(grow_h + sen_h, grow_h, sen_h),
			VegetationGrowth.SENESCENT_SCALE, 1e-6))
	_check("stage seed", VegetationGrowth.growth_stage(0.0, grow_h, sen_h) == "seed")
	_check("stage growing", VegetationGrowth.growth_stage(grow_h * 0.5, grow_h, sen_h) == "growing")
	_check("stage full", VegetationGrowth.growth_stage(grow_h, grow_h, sen_h) == "full")
	_check("stage senescent",
		VegetationGrowth.growth_stage(grow_h + sen_h * 0.5, grow_h, sen_h) == "senescent")


func _test_lettuce_90_days() -> void:
	var settings := {
		"lettuce_growth_days": 90.0,
		"lettuce_senescence_days": 15.0,
		"growth_now_h": 90.0 * 24.0,
	}
	var grow_h := VegetationGrowth.growth_span_hours("lettuce", settings)
	_check("lettuce grow span 90 days",
		_approx(grow_h, 90.0 * 24.0, 1e-4), "got %f" % grow_h)
	var seedling := {"birth_h": 90.0 * 24.0}
	_check("lettuce seedling at plant",
		_approx(VegetationGrowth.instance_scale_mult("lettuce", seedling, settings),
			VegetationGrowth.SEEDLING_SCALE, 1e-5))
	var mature := {"birth_h": 0.0}
	_check("lettuce full at day 90",
		_approx(VegetationGrowth.instance_scale_mult("lettuce", mature, settings), 1.0, 1e-5))
	settings["growth_now_h"] = (90.0 + 15.0) * 24.0
	_check("lettuce senescent after 105 days",
		_approx(VegetationGrowth.instance_scale_mult("lettuce", mature, settings),
			VegetationGrowth.SENESCENT_SCALE, 1e-5))
	# Pure math mirror of GrowBed (no scene tree required).
	var mid := VegetationGrowth.scale_for_lifecycle(45.0 * 24.0, 90.0 * 24.0, 15.0 * 24.0)
	_check("lettuce mid-growth between seed and full",
		mid > VegetationGrowth.SEEDLING_SCALE + 0.05 and mid < 0.99,
		"mid=%f" % mid)


func _test_disabled_species() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	# Growth disabled → ensure_birth_times leaves birth_h unset and render is full.
	var settings := {"grass_lawn_growth_years": 0.0}
	var bulk := {"grass_lawn": [{"x": 0.0, "z": 0.0, "scale": 1.0}]}
	VegetationGrowth.ensure_birth_times(bulk, 0.0, settings, rng, true)
	_check("disabled species leaves birth unset",
		not (bulk["grass_lawn"][0] as Dictionary).has("birth_h"))
	# Grass is not a tree → advance_generations never removes it.
	var caps := VegetationGrowth.capture_caps(bulk)
	var add := func(slot: String, x: float, z: float, yaw: float, sc: float, card: Variant) -> Variant:
		return null
	var changed := VegetationGrowth.advance_generations(
		{"grass_lawn": [{"x": 0.0, "z": 0.0, "scale": 1.0, "birth_h": -100.0 * HPY}]},
		0.0, {"grass_lawn_growth_years": 1.0}, rng, caps, add)
	_check("grass never dies (not a tree)", not changed)


func _test_settings_with_variant_non_clobber() -> void:
	# Phase 2 contract: a USER family edit (declared via the style store's
	# _user_family_keys provenance channel) beats the variant's SPECS dims; a
	# bare family value with NO provenance is just a default and loses to
	# SPECS — that absent-provenance case is precisely the fix that makes
	# subspecies real (the old absent-KEY test froze the placeholder bug).
	var player := {"pine_card_w": 2.5, "pine_card_h": 9.0,
		VegStyleStore.KEY_USER_FAMILY: ["pine_card_w", "pine_card_h"]}
	var merged := VegSpeciesCatalog.settings_with_variant(
		"spruce", player, VegetationCardFactory.SPECS)
	_check("variant keeps USER slider W",
		_approx(float(merged.get("pine_card_w", 0.0)), 2.5, 1e-6),
		"got %s" % str(merged.get("pine_card_w")))
	_check("variant keeps USER slider H",
		_approx(float(merged.get("pine_card_h", 0.0)), 9.0, 1e-6),
		"got %s" % str(merged.get("pine_card_h")))
	_check("variant stamps species id",
		str(merged.get("_variant_species", "")) == "spruce")
	var bare := VegSpeciesCatalog.settings_with_variant(
		"spruce", {"pine_card_w": 2.5}, VegetationCardFactory.SPECS)
	_check("no provenance -> SPECS wins",
		_approx(float(bare.get("pine_card_w", 0.0)), 0.95, 1e-6),
		"got %s" % str(bare.get("pine_card_w")))
	var empty := VegSpeciesCatalog.settings_with_variant(
		"fir", {}, VegetationCardFactory.SPECS)
	_check("variant fills missing W from SPECS",
		float(empty.get("pine_card_w", 0.0)) > 0.0)


func _test_size_var_scales() -> void:
	var identical := VegetationStyleConfig.scales_from_size_var(0.0)
	_check("size var 0 → identical scales",
		_approx(identical.x, 1.0, 1e-6) and _approx(identical.y, 1.0, 1e-6),
		"got %s" % identical)
	var wide := VegetationStyleConfig.scales_from_size_var(0.5)
	_check("size var 50% → 0.5..1.5",
		_approx(wide.x, 0.5, 1e-6) and _approx(wide.y, 1.5, 1e-6),
		"got %s" % wide)
	var mid := VegetationStyleConfig.scales_from_size_var(0.25)
	_check("size var 25% → 0.75..1.25",
		_approx(mid.x, 0.75, 1e-6) and _approx(mid.y, 1.25, 1e-6),
		"got %s" % mid)
