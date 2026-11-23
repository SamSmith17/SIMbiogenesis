extends SceneTree

## Offline deterministic selftest for SdfgiPolicy (core/env/sdfgi_policy.gd).
##
## Run: Godot.exe.exe --headless --path . --script core/env/sdfgi_policy_selftest.gd

const EXPECTED_CHECKS := 39

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_cascade_geometry()
	_test_altitude_hysteresis()
	_test_calibrated_energy_and_matching()
	_test_terrain_custom_ambient()
	_test_environment_apply()
	_check("expected check count (%d == %d)" % [_checks, EXPECTED_CHECKS - 1], _checks == EXPECTED_CHECKS - 1)
	if _fails == 0:
		print("SDFGI POLICY SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SDFGI POLICY SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_cascade_geometry() -> void:
	for q in [0, 1, 2, 3]:
		var p := SdfgiPolicy.cascade_profile(q)
		var h_half := SdfgiPolicy.horizontal_half_extent_m(p)
		var v_half := SdfgiPolicy.vertical_half_extent_m(p)
		_check("q%d horizontal half-extent > 200 m (got %.1f)" % [q, h_half], h_half > 200.0)
		_check("q%d vertical half-extent > 150 m (got %.1f)" % [q, v_half], v_half > 150.0)
		_check("q%d suspend_agl_m < vertical half-extent (%.1f < %.1f)" % [
			q, float(p["suspend_agl_m"]), v_half], float(p["suspend_agl_m"]) < v_half)
	var hi := SdfgiPolicy.cascade_profile(RenderProfile.QUALITY_HIGH)
	_check("High cascades == 6", int(hi["cascades"]) == 6)
	_check("High max_distance == 1228.8 m", is_equal_approx(SdfgiPolicy.max_distance_m(hi), 1228.8))
	_check("High horizontal_half_extent == 614.4 m", is_equal_approx(SdfgiPolicy.horizontal_half_extent_m(hi), 614.4))


func _test_altitude_hysteresis() -> void:
	_check("eye level (1.7 m) enables SDFGI", SdfgiPolicy.should_enable_at_agl(1.7, 210.0, false))
	_check("low FPV drone (60 m) enables SDFGI", SdfgiPolicy.should_enable_at_agl(60.0, 210.0, true))
	# Climbing from enabled: stays on at 200 m, suspends at 210 m.
	_check("climbing at 200 m stays enabled", SdfgiPolicy.should_enable_at_agl(200.0, 210.0, true))
	_check("climbing to 210 m suspends", not SdfgiPolicy.should_enable_at_agl(210.0, 210.0, true))
	# Descending from suspended: stays suspended inside deadband (195 m), re-enables at <= 185 m.
	_check("descending at 195 m stays suspended (hysteresis)", not SdfgiPolicy.should_enable_at_agl(195.0, 210.0, false))
	_check("descending to 185 m re-enables", SdfgiPolicy.should_enable_at_agl(185.0, 210.0, false))
	_check("non-finite AGL safe fallback true", SdfgiPolicy.should_enable_at_agl(NAN, 210.0, false))


func _test_calibrated_energy_and_matching() -> void:
	var noon := SdfgiPolicy.calibrated_energy(1.0, 0.0, 1.0, 1.0)
	_check("noon calibrated energy == DAY_SDFGI_ENERGY (0.18)", is_equal_approx(noon, SdfgiPolicy.DAY_SDFGI_ENERGY))
	# Civil twilight (`sky_light = 0.25`): smoothly tapers against sunset horizon glare while staying substantial.
	var twi := SdfgiPolicy.calibrated_energy(0.25, 0.0, 1.0, 1.0)
	_check("civil twilight tapers smoothly between night and noon", twi > 0.05 and twi < noon)
	# Strength slider scales linearly; 0 disables.
	_check("strength 2x doubles energy", is_equal_approx(SdfgiPolicy.calibrated_energy(1.0, 0.0, 2.0, 1.0), noon * 2.0))
	_check("strength 0x yields 0", SdfgiPolicy.calibrated_energy(1.0, 0.0, 0.0, 1.0) == 0.0)
	# Moonless night tapers down against star/Milky-Way cubemap floor while keeping local bounce alive.
	var night_dark := SdfgiPolicy.calibrated_energy(0.0, 0.0, 1.0, 1.0)
	var night_moon := SdfgiPolicy.calibrated_energy(0.0, 0.008, 1.0, 1.0)
	_check("moonless night tapers below day gain (%.3f < %.3f)" % [night_dark, noon],
		night_dark > 0.01 and night_dark < noon * 0.3)
	_check("full moon night > moonless night", night_moon > night_dark)
	# Matched outside sky ambient accounts for SDFGI_TO_CUBEMAP_RATIO + sun-bounce allowance.
	var out_noon := SdfgiPolicy.matched_sky_ambient_energy(noon, 1.0)
	var out_dusk := SdfgiPolicy.matched_sky_ambient_energy(twi, 0.25)
	_check("noon matched outside ambient == noon * ratio * 1.12",
		is_equal_approx(out_noon, noon * SdfgiPolicy.SDFGI_TO_CUBEMAP_RATIO * (1.0 + SdfgiPolicy.SUN_BOUNCE_OPEN_FRAC)))
	_check("dusk matched outside ambient == twi * ratio",
		is_equal_approx(out_dusk, twi * SdfgiPolicy.SDFGI_TO_CUBEMAP_RATIO))


func _test_terrain_custom_ambient() -> void:
	# When SDFGI is enabled (`sky_contrib = 1.0`, `ambient = matched_amb ~ 0.454`),
	# custom terrain ambient matches `0.454 * ~0.25 ≈ 0.11` cubemap sky radiance.
	var sdfgi_rgb := SdfgiPolicy.terrain_custom_ambient_color(0.454, 1.0, 0.0, Color(0.40, 0.45, 0.56), 1.0, Color.BLACK)
	var sdfgi_mean := (sdfgi_rgb.x + sdfgi_rgb.y + sdfgi_rgb.z) / 3.0
	_check("custom terrain ambient with sky_contrib=1 matches cubemap sky radiance (~0.11)", sdfgi_mean > 0.07 and sdfgi_mean < 0.16)
	_check("custom terrain ambient sky-tinted slightly cool at noon", sdfgi_rgb.z >= sdfgi_rgb.x)
	var zero_rgb := SdfgiPolicy.terrain_custom_ambient_color(0.0, 1.0, 0.0, Color.WHITE, 0.15, Color.BLACK)
	_check("custom terrain ambient zero when ambient is 0", zero_rgb == Vector3.ZERO)


func _test_environment_apply() -> void:
	var env := Environment.new()
	var p := SdfgiPolicy.apply_cascade_profile(env, RenderProfile.QUALITY_HIGH)
	_check("env.sdfgi_cascades applied", env.sdfgi_cascades == int(p["cascades"]))
	_check("env.sdfgi_min_cell_size applied", is_equal_approx(env.sdfgi_min_cell_size, float(p["min_cell_size"])))
	_check("env.sdfgi_y_scale applied", env.sdfgi_y_scale == int(p["y_scale"]))
	_check("env.sdfgi_bounce_feedback applied", is_equal_approx(env.sdfgi_bounce_feedback, float(p["bounce_feedback"])))
	_check("Godot Environment.sdfgi_max_distance matches formula (%.2f == %.2f)" % [
		env.sdfgi_max_distance, SdfgiPolicy.max_distance_m(p)],
		is_equal_approx(env.sdfgi_max_distance, SdfgiPolicy.max_distance_m(p)))
