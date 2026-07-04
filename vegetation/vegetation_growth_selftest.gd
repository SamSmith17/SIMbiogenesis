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
	_test_birth_times()
	_test_reseed_population()
	_test_reseed_radius()
	_test_disabled_species()
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
	# One matured parent at a known spot; its seedlings must land within 2 m.
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
