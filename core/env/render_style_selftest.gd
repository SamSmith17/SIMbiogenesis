extends SceneTree
## Visual styles (offline): RenderStyle's identity, blending and sub-controls,
## the environment overlay, the post pass's push-constant layout, and
## RenderStylePrefs round-tripping a TEMP file (never the player's).
##   Godot --headless --path . --script core/env/render_style_selftest.gd

const EXPECTED_CHECKS := 51

var _n := 0
var _fail := 0


func _init() -> void:
	_test_identity()
	_test_blend()
	_test_env_overlay()
	_test_post_floats()
	_test_more_styles()
	_test_prefs()
	if _n != EXPECTED_CHECKS:
		_check(false, "ran %d checks, expected %d (a test function aborted?)" % [_n, EXPECTED_CHECKS])
	print("render_style_selftest: %s (%d checks, %d failed)" % ["PASS" if _fail == 0 else "FAIL", _n, _fail])
	quit(0 if _fail == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_n += 1
	if not ok:
		_fail += 1
		print("  FAIL: ", what)


func _test_identity() -> void:
	var r := RenderStyle.resolve(RenderStyle.REALISTIC)
	_check(RenderStyle.is_identity(r), "realistic is the identity")
	_check(not bool(r["post_on"]), "realistic runs no post pass")
	var z := RenderStyle.resolve(RenderStyle.SOLARPUNK, 0.0)
	_check(RenderStyle.is_identity(z), "solarpunk at strength 0 is the identity")
	_check(not bool(z["post_on"]), "strength 0 runs no post pass")
	var u := RenderStyle.resolve("no_such_style")
	_check(String(u["id"]) == RenderStyle.REALISTIC, "an unknown style reads as realistic")
	_check(RenderStyle.is_identity(u), "an unknown style changes nothing")
	for id in RenderStyle.ORDER:
		_check(RenderStyle.LABELS.has(id) and RenderStyle.BLURBS.has(id) and RenderStyle.STYLES.has(id),
			"%s has a label, blurb and table" % id)
	for id in RenderStyle.STYLES:
		for k in RenderStyle.STYLES[id]:
			if not RenderStyle.IDENTITY.has(k):
				_check(false, "%s key %s is not in IDENTITY" % [id, k])


func _test_blend() -> void:
	var full := RenderStyle.resolve(RenderStyle.SOLARPUNK, 1.0)
	var half := RenderStyle.resolve(RenderStyle.SOLARPUNK, 0.5)
	_check(bool(full["post_on"]), "solarpunk runs the post pass")
	_check(is_equal_approx(float(half["saturation"]), lerpf(1.0, float(full["saturation"]), 0.5)),
		"strength blends numbers linearly")
	var hc: Color = half["shadow_tint"]
	var fc: Color = full["shadow_tint"]
	_check(hc.is_equal_approx(Color(1, 1, 1).lerp(fc, 0.5)), "strength blends colours")
	var no_lines := RenderStyle.resolve(RenderStyle.SOLARPUNK, 1.0, 0.0)
	_check(float(no_lines["outline_mix"]) == 0.0, "outlines 0 removes the lines")
	_check(float(no_lines["kuwahara_px"]) == float(full["kuwahara_px"]), "outlines leave painterly alone")
	var no_paint := RenderStyle.resolve(RenderStyle.SOLARPUNK, 1.0, 1.0, 0.0)
	_check(float(no_paint["kuwahara_px"]) == 0.0, "painterly 0 removes the smoothing")
	var no_cel := RenderStyle.resolve(RenderStyle.SOLARPUNK, 1.0, 1.0, 1.0, 0.0)
	_check(float(no_cel["band_mix"]) == 0.0 and float(no_cel["light_compress"]) == 0.0, "cel 0 removes the bands")
	var double := RenderStyle.resolve(RenderStyle.SOLARPUNK, 1.0, 2.0)
	_check(float(double["outline_mix"]) <= 1.0, "outline mix stays within 0..1")
	var all_off := RenderStyle.resolve(RenderStyle.SOLARPUNK, 1.0, 0.0, 0.0, 0.0)
	_check(bool(all_off["post_on"]), "with every sub-control off the grade still runs")


func _test_env_overlay() -> void:
	var env := Environment.new()
	env.ambient_light_energy = 0.3
	env.fog_density = 0.0003
	env.fog_aerial_perspective = 0.6
	env.glow_intensity = 0.3
	env.glow_hdr_threshold = 1.5
	RenderStyle.apply_env(env, RenderStyle.resolve(RenderStyle.REALISTIC), "env")
	RenderStyle.apply_env(env, RenderStyle.resolve(RenderStyle.REALISTIC), "glow")
	_check(is_equal_approx(env.ambient_light_energy, 0.3) and is_equal_approx(env.fog_density, 0.0003)
		and is_equal_approx(env.glow_intensity, 0.3), "realistic leaves the environment as computed")
	_check(not env.adjustment_enabled, "realistic leaves adjustment off")
	var p := RenderStyle.resolve(RenderStyle.SOLARPUNK)
	RenderStyle.apply_env(env, p, "env")
	_check(is_equal_approx(env.ambient_light_energy, 0.3 * float(p["ambient_mult"])), "ambient multiplied")
	_check(env.fog_density < 0.0003, "solarpunk clears the air")
	_check(env.adjustment_enabled and env.adjustment_saturation > 1.0, "solarpunk turns on the post-tonemap grade")
	RenderStyle.apply_env(env, p, "glow")
	_check(env.glow_bloom > 0.0 and env.glow_intensity > 0.3, "solarpunk glow")
	# Switching back after a styled update: Main recomputes, the overlay leaves it.
	env.ambient_light_energy = 0.3
	RenderStyle.apply_env(env, RenderStyle.resolve(RenderStyle.REALISTIC), "env")
	_check(not env.adjustment_enabled and is_equal_approx(env.ambient_light_energy, 0.3),
		"back to realistic turns the grade off")


func _test_post_floats() -> void:
	var p := RenderStyle.resolve(RenderStyle.SOLARPUNK)
	var f := RenderStyle.post_floats(p, 1.25)
	_check(f.size() == 28, "28 floats after size/mode/near (128-byte push constant)")
	_check(is_equal_approx(f[0], float(p["band_mix"])) and is_equal_approx(f[4], float(p["kuwahara_px"])),
		"p1.x band_mix, p2.x kuwahara")
	_check(is_equal_approx(f[15], 1.25), "p4.w exposure")
	var st: Color = p["shadow_tint"]
	_check(is_equal_approx(f[16], st.r) and is_equal_approx(f[19], float(p["split_mix"])), "p5 shadow tint + split")
	_check(is_equal_approx(f[27], float(p["green_push"])), "p7.w green push")
	_check(f[11] > f[10], "fade end beyond fade start")


func _test_more_styles() -> void:
	for id in [RenderStyle.WATERCOLOR, RenderStyle.INK, RenderStyle.CINEMATIC]:
		_check(bool(RenderStyle.resolve(id)["post_on"]), "%s runs the post pass" % id)
		_check(RenderStyle.is_identity(RenderStyle.resolve(id, 0.0)), "%s at strength 0 is the identity" % id)
	var w := RenderStyle.extra_floats(RenderStyle.resolve(RenderStyle.WATERCOLOR))
	_check(w.size() == 12, "12 floats in the uniform buffer (three std140 vec4)")
	_check(is_equal_approx(w[0], float(RenderStyle.STYLES[RenderStyle.WATERCOLOR]["lift"])), "e0.x lift")
	var ink := RenderStyle.extra_floats(RenderStyle.resolve(RenderStyle.INK))
	_check(is_equal_approx(ink[8], float(RenderStyle.STYLES[RenderStyle.INK]["halftone"])) and is_equal_approx(ink[9], 6.0), "e2.xy halftone + spacing")
	var cin := RenderStyle.extra_floats(RenderStyle.resolve(RenderStyle.CINEMATIC))
	_check(cin[2] > 0.5, "e0.z: cinematic grain is moving film grain")
	_check(not RenderStyle.has_sub_control(RenderStyle.CINEMATIC, "outlines"), "cinematic hides the outline slider")
	_check(RenderStyle.has_sub_control(RenderStyle.INK, "outlines"), "ink shows the outline slider")
	_check(RenderStyle.has_sub_control(RenderStyle.INK, "cel"), "the cel slider reaches the halftone")


func _test_prefs() -> void:
	var path := OS.get_user_data_dir().path_join("render_style_selftest_%d.cfg" % Time.get_ticks_usec())
	path = "user://" + path.get_file()
	RenderStylePrefs.use_path_for_test(path)
	_check(RenderStylePrefs.style() == RenderStyle.REALISTIC, "no file = realistic")
	var g0 := RenderStylePrefs.generation()
	RenderStylePrefs.set_style(RenderStyle.SOLARPUNK)
	RenderStylePrefs.set_outlines(0.5)
	_check(RenderStylePrefs.generation() > g0, "a change moves the generation")
	_check(String(RenderStylePrefs.resolved()["id"]) == RenderStyle.SOLARPUNK, "resolved follows the style")
	RenderStylePrefs.use_path_for_test(path)
	_check(RenderStylePrefs.style() == RenderStyle.SOLARPUNK and is_equal_approx(RenderStylePrefs.outlines(), 0.5),
		"the file round-trips")
	RenderStylePrefs.set_style("bogus")
	_check(RenderStylePrefs.style() == RenderStyle.REALISTIC, "a bogus id falls back to realistic")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
