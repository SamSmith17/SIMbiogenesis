extends RefCounted

## Settings → Environment → Horizon / Atmospheric haze on a REAL world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/horizon_settings_check.gd
## Each control reaches what it drives (sky-shader uniforms, the fog), the
## horizon colour follows the haze when matched, every value survives
## persist_settings → _load_persisted_settings, and the reset puts the
## defaults back. Writes only the sandbox's sim_settings.cfg.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("horizon-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _near(a: float, b: float, eps: float = 0.002) -> bool:
	return absf(a - b) <= eps


func _col_near(a, b: Color) -> bool:
	var c: Color = a if a is Color else Color(a.x, a.y, a.z)
	return absf(c.r - b.r) < 0.01 and absf(c.g - b.g) < 0.01 and absf(c.b - b.b) < 0.01


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var ssc: Node = main.get_node_or_null("/root/SimSettingsController")
	_ok(ssc != null, "SimSettingsController is up")
	if ssc == null:
		return {"ok": false}
	var env: Environment = main.get("environment").environment
	var sky: ShaderMaterial = env.sky.sky_material
	await _settle(tree, 10)

	# Matched by default: the sky under the line is the fog's colour.
	_ok(bool(main.call("get_horizon_match_haze")), "horizon matches the haze by default")
	_ok(_col_near(sky.get_shader_parameter("horizon_color"), env.fog_light_color),
		"horizon_color == fog_light_color (%s vs %s)" % [str(sky.get_shader_parameter("horizon_color")), str(env.fog_light_color)])

	var want := {
		"horizon_height_deg": 1.5, "horizon_softness_deg": 3.0, "horizon_haze": 0.8,
		"horizon_haze_height_deg": 9.0, "haze_density_mult": 0.5, "haze_aerial_mult": 1.2,
		"haze_sun_glow_mult": 2.0, "twilight_cool_bias": 0.3, "late_day_clearing": 0.7,
	}
	var fog0 := env.fog_density
	for k in want.keys():
		ssc.call("apply_sky_setting", k, want[k])
	ssc.call("apply_sky_setting", "horizon_match_haze", false)
	var user_col := Color(0.9, 0.2, 0.1)
	ssc.call("apply_sky_setting", "horizon_user_color", user_col)
	var zen := Color(0.1, 0.2, 0.7)
	ssc.call("apply_sky_setting", "sky_zenith_color", zen)
	await _settle(tree, 4)
	_ok(_near(float(sky.get_shader_parameter("horizon_height")), sin(deg_to_rad(1.5)), 0.0005), "horizon_height uniform = sin(1.5°)")
	_ok(_near(float(sky.get_shader_parameter("horizon_blur")), sin(deg_to_rad(3.0)), 0.0005), "horizon_blur uniform = sin(3°)")
	_ok(_near(float(sky.get_shader_parameter("horizon_haze")), 0.8), "horizon_haze uniform")
	_ok(_near(float(sky.get_shader_parameter("horizon_haze_height")), sin(deg_to_rad(9.0)), 0.0005), "horizon_haze_height uniform")
	_ok(_col_near(sky.get_shader_parameter("horizon_color"), user_col), "manual horizon colour reaches the sky")
	_ok(_col_near(sky.get_shader_parameter("day_top_color"), zen), "zenith colour reaches the sky")
	_ok(env.fog_density < fog0 * 0.75, "haze density × 0.5 thins the fog (%.6f -> %.6f)" % [fog0, env.fog_density])

	# Round trip through the settings file.
	ssc.call("persist_settings")
	var cfg := ConfigFile.new()
	cfg.load("user://sim_settings.cfg")
	_ok(cfg.has_section_key("rendering_adv", "horizon_haze") and cfg.has_section_key("rendering_adv", "sky_zenith_color"),
		"horizon keys written to [rendering_adv]")
	var defaults: Dictionary = main.call("horizon_haze_defaults")
	for k in defaults.keys():
		ssc.call("apply_sky_setting", k, defaults[k])
	await _settle(tree, 2)
	ssc.call("_load_persisted_settings")
	await _settle(tree, 4)
	for k in want.keys():
		_ok(_near(float(main.call("get_" + k)), float(want[k])), "%s reloads as %s (got %s)" % [k, str(want[k]), str(main.call("get_" + k))])
	_ok(not bool(main.call("get_horizon_match_haze")), "match-haze off reloads")
	_ok(_col_near(main.call("get_horizon_user_color"), user_col), "manual horizon colour reloads")
	_ok(_col_near(main.call("get_sky_zenith_color"), zen), "zenith colour reloads")

	# The panel's reset.
	for k in defaults.keys():
		ssc.call("apply_sky_setting", k, defaults[k])
	await _settle(tree, 4)
	_ok(bool(main.call("get_horizon_match_haze")) and _near(float(main.call("get_horizon_haze")), float(defaults["horizon_haze"])),
		"defaults restore")
	_ok(_col_near(sky.get_shader_parameter("horizon_color"), env.fog_light_color), "re-matched to the haze after reset")
	ssc.call("persist_settings")
	return {"ok": _fails.is_empty(), "fails": _fails}
