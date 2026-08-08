extends SceneTree

## Offline deterministic selftest for the extreme-weather subsystem
## (core/weather/).
##
## Run: Godot.exe.exe --headless --path . --script core/weather/extreme_weather_selftest.gd
##      (run --headless --path . --import first — these are new class_name scripts)
##
## Why this file exists. The subsystem's entire correctness argument rests on
## three properties that are invisible by inspection and catastrophic when
## broken:
##   * `HazardState.blank()` is the identity element, which is what guarantees
##     "feature disabled => not one pixel changes" across every existing scene;
##   * severity is a PURE function of absolute hours, which is what lets the
##     timeline scrub backwards through a smoke event instead of desyncing;
##   * every value reaching a shader uniform is finite, because `clampf` does
##     NOT filter NaN and CAMS air-quality data contains genuine null hours.
## Each is asserted below rather than trusted.
##
## Nothing here may reference an autoload by bare identifier: under `--script`
## that breaks the compile and the test aborts while still printing PASS (see
## the note in CLAUDE.md's population-selftest entry).

var _fails := 0
var _checks := 0

## Snapshot of the player's real prefs file, restored before quitting — a
## selftest must never leave a user's settings changed.
var _prefs_existed := false
var _prefs_backup := ""


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _approx(got: float, want: float, eps := 0.0001) -> bool:
	return is_finite(got) and absf(got - want) <= eps


func _initialize() -> void:
	_snapshot_prefs()

	_test_catalog_integrity()
	_test_vtec_mapping()
	_test_alert_identification()
	_test_risk_bands()
	_test_blank_identity()
	_test_combine_algebra()
	_test_combine_worst_wins()
	_test_sanitize_rejects_nan()
	_test_koschmieder()
	_test_visibility_from_pm25()
	_test_rh_growth()
	_test_prefs_roundtrip()
	_test_aqi_breakpoints()
	_test_beer_lambert()
	_test_hazard_profiles()
	_test_risk_profile_from_vtec()
	_test_risk_profile_climatology()
	_test_risk_profile_merge_and_display()
	_test_air_quality_parser()
	_test_severity_evaluators()
	_test_atmosphere_applier()
	_test_hazard_wind_for_vegetation()
	_test_forced_preview_director()

	_restore_prefs()

	if _fails == 0:
		print("EXTREME WEATHER SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("EXTREME WEATHER SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


## --- forced preview (director-level) -----------------------------------------

## The manual-preview contract on a REAL director instance (loadable here —
## the script carries no bare autoload identifiers): a forced hazard resolves
## even with the master switch OFF (so the Preview button no longer has to
## permanently flip GameplayRules + per-hazard prefs to be visible), the
## forced window is RAMPED like a real alert span (a rectangular pulse reads
## as a bug), severity retunes live without moving the window, an unresolved
## clock refuses rather than planting the window at abs hour 0, and the
## disabled+unforced identity still holds.
func _test_forced_preview_director() -> void:
	var xw: Node = load("res://core/weather/extreme_weather_director.gd").new()
	root.add_child(xw)
	# Master switch is OFF by default (GameplayRules autoload default false).
	_check("master switch reads off in the harness", not bool(xw.call("is_enabled")))
	var t0 := 1000.0
	_check("disabled + unforced resolves blank",
		float((xw.call("resolve_at", t0) as Dictionary).get("severity", 1.0)) == 0.0
			and str((xw.call("resolve_at", t0) as Dictionary).get("id", "x")) == "")
	# No main_scene node in this harness -> the clock is unresolved -> refuse.
	xw.call("force_hazard", "dust_storm", 0.8, 6.0)
	_check("unresolved clock refuses force_hazard", not bool(xw.call("has_forced")))
	# With a resolvable clock, force_hazard anchors NOW at the START OF THE
	# PLATEAU — the pulse still ramps (scrub back and see the arrival) but the
	# player pressing Preview sees full severity immediately. Starting the
	# ramp at `now` made a preview invisible for RAMP_IN_FRAC of its duration.
	var clock_src := GDScript.new()
	clock_src.source_code = "extends RefCounted\nfunc get_absolute_hours() -> float:\n\treturn 5000.0\n"
	clock_src.reload()
	var main_src := GDScript.new()
	main_src.source_code = "extends Node\nvar clock = null\n"
	main_src.reload()
	var stub_main: Node = main_src.new()
	stub_main.set("clock", clock_src.new())
	xw.set("_main_node", stub_main)
	xw.call("force_hazard", "dust_storm", 0.8, 6.0)
	_check("resolvable clock accepts force_hazard", bool(xw.call("has_forced")))
	var at_press: Dictionary = xw.call("resolve_at", 5000.01)
	_check("preview is at full severity the moment it is pressed",
		float(at_press.get("severity", 0.0)) > 0.7,
		"got %.2f" % float(at_press.get("severity", 0.0)))
	var fi: Dictionary = xw.call("forced_info")
	_check("preview still runs ~85%% of the requested duration ahead",
		float(fi.get("to_abs", 0.0)) - 5000.0 > 6.0 * 0.8,
		"to_abs %.2f" % float(fi.get("to_abs", 0.0)))
	xw.call("clear_forced")
	xw.set("_main_node", null)
	stub_main.free()
	# Plant the window directly (what force_hazard does once the clock resolves).
	xw.set("_forced", {"id": "dust_storm", "severity": 0.8,
		"from_abs": t0, "to_abs": t0 + 6.0})
	xw.call("invalidate")
	_check("forced_info reports the window",
		str((xw.call("forced_info") as Dictionary).get("id", "")) == "dust_storm")
	var mid: Dictionary = xw.call("resolve_at", t0 + 3.0)
	_check("forced hazard resolves with master OFF",
		float(mid.get("severity", 0.0)) > 0.5,
		"got %.2f" % float(mid.get("severity", 0.0)))
	_check("forced state is sourced 'forced'", str(mid.get("source", "")) == "forced")
	# Ramped envelope: early < mid, late < mid, outside = blank.
	var early: Dictionary = xw.call("resolve_at", t0 + 0.2)
	var late: Dictionary = xw.call("resolve_at", t0 + 5.9)
	_check("forced window ramps in",
		float(early.get("severity", 1.0)) < float(mid.get("severity", 0.0)),
		"%.2f !< %.2f" % [float(early.get("severity", 0.0)), float(mid.get("severity", 0.0))])
	_check("forced window ramps out",
		float(late.get("severity", 1.0)) < float(mid.get("severity", 0.0)))
	_check("outside the window is blank",
		float((xw.call("resolve_at", t0 + 12.0) as Dictionary).get("severity", 1.0)) == 0.0)
	# Live severity retune keeps the window.
	xw.call("update_forced_severity", 0.2)
	var retuned: Dictionary = xw.call("resolve_at", t0 + 3.0)
	_check("update_forced_severity takes effect",
		float(retuned.get("severity", 1.0)) < 0.3
			and float(retuned.get("severity", 0.0)) > 0.05,
		"got %.2f" % float(retuned.get("severity", 0.0)))
	_check("retune keeps the window",
		is_equal_approx(float((xw.call("forced_info") as Dictionary).get("to_abs", 0.0)),
			t0 + 6.0))
	# Clear restores the identity.
	xw.call("clear_forced")
	_check("clear_forced restores blank",
		float((xw.call("resolve_at", t0 + 3.0) as Dictionary).get("severity", 1.0)) == 0.0)
	_check("clear_forced empties forced_info",
		(xw.call("forced_info") as Dictionary).is_empty())
	xw.queue_free()


## --- hazard wind → vegetation -----------------------------------------------

## WindMath.apply_hazard_wind is the ONE place hazard wind reaches the canopy
## (VegetationWindDriver folds it in before pushing shader uniforms). Pin the
## identity — blank() must leave measured weather bit-identical — and the
## damaging-winds multipliers, so the storm sway can't silently die again
## (it shipped once with the driver never consulting ExtremeWeather at all).
func _test_hazard_wind_for_vegetation() -> void:
	# Identity on blank(): the HazardState invariant carried into the canopy.
	var idn := WindMath.apply_hazard_wind(7.0, 11.0, HazardState.blank())
	_check("blank leaves speed untouched", is_equal_approx(idn.x, 7.0))
	_check("blank leaves gust untouched", is_equal_approx(idn.y, 11.0))
	# Missing keys behave as blank too (an empty dict from a degraded source).
	var missing := WindMath.apply_hazard_wind(7.0, 11.0, {})
	_check("missing keys are identity", is_equal_approx(missing.x, 7.0)
			and is_equal_approx(missing.y, 11.0))
	# Severity-1 damaging winds: the full 2.6× / 3.0× reaches the trees.
	var storm: Dictionary = HazardEvaluators.state_for("damaging_winds", 1.0)
	var sg := WindMath.apply_hazard_wind(10.0, 14.0, storm)
	_check("storm wind 2.6x", is_equal_approx(sg.x, 26.0), "%.2f" % sg.x)
	_check("storm gust 3.0x", is_equal_approx(sg.y, 42.0), "%.2f" % sg.y)
	# Gust never falls below speed, whatever the multipliers say.
	var weird := HazardState.blank()
	weird["wind_mult"] = 3.0
	weird["gust_mult"] = 1.0
	var wg := WindMath.apply_hazard_wind(10.0, 10.5, weird)
	_check("gust floored at speed", wg.y >= wg.x, "%.2f < %.2f" % [wg.y, wg.x])
	# Turbulence lifts gusts even when the gust multiplier is idle (half-
	# weight, so a profile's own gust_mult stays the governing channel).
	var turb := HazardState.blank()
	turb["turbulence"] = 1.0
	var tg := WindMath.apply_hazard_wind(10.0, 10.0, turb)
	_check("turbulence lifts gusts", tg.y >= 14.9, "%.2f" % tg.y)
	# Monotonic in severity.
	var prev := 0.0
	for sev in [0.2, 0.5, 0.8, 1.0]:
		var st: Dictionary = HazardEvaluators.state_for("damaging_winds", float(sev))
		var v := WindMath.apply_hazard_wind(10.0, 12.0, st)
		_check("hazard wind monotonic at %.1f" % sev, v.x > prev)
		prev = v.x


## --- prefs file discipline ---------------------------------------------------

func _snapshot_prefs() -> void:
	_prefs_existed = FileAccess.file_exists(ExtremeWeatherPrefs.CFG_PATH)
	if _prefs_existed:
		_prefs_backup = FileAccess.get_file_as_string(ExtremeWeatherPrefs.CFG_PATH)


func _restore_prefs() -> void:
	if _prefs_existed:
		var f := FileAccess.open(ExtremeWeatherPrefs.CFG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_prefs_backup)
			f.close()
	elif FileAccess.file_exists(ExtremeWeatherPrefs.CFG_PATH):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(ExtremeWeatherPrefs.CFG_PATH))
	ExtremeWeatherPrefs.reset_for_test()


## --- catalog -----------------------------------------------------------------

func _test_catalog_integrity() -> void:
	var ids := HazardCatalog.ids()
	_check("catalog: 11 hazards", ids.size() == 11, "got %d" % ids.size())
	_check("catalog: HAZARDS matches HAZARD_IDS size",
		HazardCatalog.HAZARDS.size() == ids.size(),
		"%d defs vs %d ids" % [HazardCatalog.HAZARDS.size(), ids.size()])

	for id: String in ids:
		var d := HazardCatalog.get_def(id)
		_check("catalog: %s has a def" % id, not d.is_empty())
		_check("catalog: %s named" % id, not str(d.get("name", "")).is_empty())
		_check("catalog: %s has icon" % id, not str(d.get("icon", "")).is_empty())
		_check("catalog: %s has blurb" % id, str(d.get("blurb", "")).length() > 20)
		_check("catalog: %s has category" % id, not str(d.get("category", "")).is_empty())
		_check("catalog: %s notify threshold in range" % id,
			HazardCatalog.notify_threshold(id) > 0.0
				and HazardCatalog.notify_threshold(id) <= 1.0)

	# The four this pass actually simulates. If a fifth appears here without a
	# resolver, the director will silently produce nothing for it.
	var sim := HazardCatalog.simulated_ids()
	_check("catalog: 4 simulated hazards", sim.size() == 4, "got %s" % str(sim))
	for id: String in ["wildfire_smoke", "dust_storm", "damaging_winds", "heatwave"]:
		_check("catalog: %s is simulated" % id, HazardCatalog.is_simulated(id))
	# Blackout is the one hazard with no meteorological observable; it must not
	# claim VTEC codes or the risk profile will report it as never observed.
	_check("catalog: blackout has no VTEC codes",
		(HazardCatalog.get_def("blackout").get("vtec", []) as Array).is_empty())

	# Unknown ids degrade quietly — a pref file from a newer build must not spam.
	_check("catalog: unknown id -> empty def", HazardCatalog.get_def("nope").is_empty())
	_check("catalog: unknown id not simulated", not HazardCatalog.is_simulated("nope"))


func _test_vtec_mapping() -> void:
	var seen: Dictionary = {}
	for id: String in HazardCatalog.ids():
		for code: String in (HazardCatalog.get_def(id).get("vtec", []) as Array):
			_check("vtec: %s claimed once (%s)" % [code, id], not seen.has(code),
				"also claimed by %s" % str(seen.get(code, "")))
			seen[code] = id
	var vm := HazardCatalog.vtec_map()
	_check("vtec: map covers every code", vm.size() == seen.size(),
		"%d mapped vs %d declared" % [vm.size(), seen.size()])
	# Spot-check the codes this feature exists for.
	_check("vtec: SM -> wildfire_smoke", str(vm.get("SM", "")) == "wildfire_smoke")
	_check("vtec: DS -> dust_storm", str(vm.get("DS", "")) == "dust_storm")
	_check("vtec: DU -> dust_storm", str(vm.get("DU", "")) == "dust_storm")
	_check("vtec: HU -> damaging_winds", str(vm.get("HU", "")) == "damaging_winds")
	_check("vtec: EH -> heatwave", str(vm.get("EH", "")) == "heatwave")


func _test_alert_identification() -> void:
	# Code wins over name.
	_check("alert: code beats name",
		HazardCatalog.id_for_alert("DS", "Some Renamed Event") == "dust_storm")
	# Name carries cached rows that predate the service passing codes through.
	_check("alert: name fallback (smoke)",
		HazardCatalog.id_for_alert("", "Dense Smoke Advisory") == "wildfire_smoke")
	_check("alert: name fallback (red flag)",
		HazardCatalog.id_for_alert("", "Red Flag Warning") == "wildfire_smoke")
	_check("alert: name fallback (hurricane)",
		HazardCatalog.id_for_alert("", "Hurricane Warning") == "damaging_winds")
	# Wind Chill must read as cold, never as a wind hazard — the substring trap.
	_check("alert: wind chill is cold, not wind",
		HazardCatalog.id_for_alert("", "Wind Chill Advisory") == "cold_snap",
		"got %s" % HazardCatalog.id_for_alert("", "Wind Chill Advisory"))
	# Most NWS alerts are not ours and must resolve to nothing.
	_check("alert: unrelated -> empty",
		HazardCatalog.id_for_alert("MA", "Marine Weather Statement") == "")
	_check("alert: empty -> empty", HazardCatalog.id_for_alert("", "") == "")

	# A Warning must outrank an Advisory, which must outrank a Watch.
	var w := HazardCatalog.severity_for_significance("W")
	var y := HazardCatalog.severity_for_significance("Y")
	var a := HazardCatalog.severity_for_significance("A")
	_check("alert: warning > advisory > watch", w > y and y > a,
		"W=%.2f Y=%.2f A=%.2f" % [w, y, a])


func _test_risk_bands() -> void:
	_check("risk: 0/decade -> none",
		HazardCatalog.risk_level_for_rate(0.0) == HazardCatalog.RISK_NONE)
	_check("risk: 25/decade -> severe",
		HazardCatalog.risk_level_for_rate(25.0) == HazardCatalog.RISK_SEVERE)
	_check("risk: 10/decade -> high",
		HazardCatalog.risk_level_for_rate(10.0) == HazardCatalog.RISK_HIGH)
	_check("risk: 3/decade -> moderate",
		HazardCatalog.risk_level_for_rate(3.0) == HazardCatalog.RISK_MODERATE)
	_check("risk: 1/decade -> low",
		HazardCatalog.risk_level_for_rate(1.0) == HazardCatalog.RISK_LOW)
	_check("risk: NaN -> none",
		HazardCatalog.risk_level_for_rate(NAN) == HazardCatalog.RISK_NONE)

	# Monotonic: raising the rate can never lower the band's fill.
	var prev := -1.0
	for rate: float in [0.0, 0.4, 0.6, 2.5, 9.0, 30.0]:
		var fill := HazardCatalog.risk_fill(HazardCatalog.risk_level_for_rate(rate))
		_check("risk: fill monotonic at %.1f/decade" % rate, fill >= prev,
			"%.2f after %.2f" % [fill, prev])
		prev = fill
	# UNKNOWN must read as an empty bar, never as "safe with a full bar".
	_check("risk: unknown fill is 0",
		_approx(HazardCatalog.risk_fill(HazardCatalog.RISK_UNKNOWN), 0.0))


## --- HazardState -------------------------------------------------------------

func _test_blank_identity() -> void:
	var b := HazardState.blank()
	_check("blank: inactive", not HazardState.is_active(b))
	_check("blank: severity 0", _approx(float(b["severity"]), 0.0))
	# Every multiplier is 1.0 and every additive term 0.0 — this is what the
	# applier's "returns base field-for-field" guarantee rests on.
	for key: String in ["sun_energy_mult", "wind_mult", "gust_mult",
			"dni_factor", "ghi_factor"]:
		_check("blank: %s == 1" % key, _approx(float(b[key]), 1.0),
			"got %f" % float(b[key]))
	for key: String in ["aod", "haze_strength", "sky_tint_strength", "glow_boost",
			"exposure_offset", "particle_density", "turbulence", "dhi_boost",
			"wind_derate", "breath_hazard", "pm25_ugm3", "aqi", "thermal_stress"]:
		_check("blank: %s == 0" % key, _approx(float(b[key]), 0.0),
			"got %f" % float(b[key]))
	_check("blank: visibility beyond fog_depth_end",
		float(b["visibility_m"]) > 8000.0)
	_check("blank: grid available", bool(b["grid_available"]))
	_check("blank: no particles", str(b["particle_kind"]) == "")


func _test_combine_algebra() -> void:
	var b := HazardState.blank()
	var smoke := _smoke_state(0.6)

	# Identity, both ways round.
	var l := HazardState.combine(smoke, b)
	var r := HazardState.combine(b, smoke)
	for key: String in b.keys():
		_check("combine: identity right (%s)" % key, _same(l[key], smoke[key]),
			"%s vs %s" % [str(l[key]), str(smoke[key])])
		_check("combine: identity left (%s)" % key, _same(r[key], smoke[key]),
			"%s vs %s" % [str(r[key]), str(smoke[key])])

	# Commutative for two real hazards.
	var heat := _heat_state(0.4)
	var ab := HazardState.combine(smoke, heat)
	var ba := HazardState.combine(heat, smoke)
	for key: String in b.keys():
		_check("combine: commutative (%s)" % key, _same(ab[key], ba[key]),
			"%s vs %s" % [str(ab[key]), str(ba[key])])

	# Severity stays bounded and takes the worse of the two.
	_check("combine: severity is max", _approx(float(ab["severity"]), 0.6))
	_check("combine: severity bounded",
		float(HazardState.combine(_smoke_state(1.0), _heat_state(1.0))["severity"]) <= 1.0)
	# The louder hazard names the combined state.
	_check("combine: dominant id wins", str(ab["id"]) == "wildfire_smoke",
		"got %s" % str(ab["id"]))

	# combine_all over an empty list is the identity.
	_check("combine_all: empty -> blank",
		not HazardState.is_active(HazardState.combine_all([])))


func _test_combine_worst_wins() -> void:
	var a := _smoke_state(0.5)
	var c := _dust_state(0.5)
	var m := HazardState.combine(a, c)
	# Visibility takes the MIN — a second hazard never lets you see further.
	_check("combine: visibility is min",
		_approx(float(m["visibility_m"]),
			minf(float(a["visibility_m"]), float(c["visibility_m"])), 0.01))
	# Optical depth ADDS — two aerosol loads compound.
	_check("combine: aod adds",
		_approx(float(m["aod"]), float(a["aod"]) + float(c["aod"]), 0.001))
	# Energy factors MULTIPLY, so stacked hazards compound rather than plateau.
	_check("combine: dni multiplies",
		_approx(float(m["dni_factor"]), float(a["dni_factor"]) * float(c["dni_factor"]), 0.001))
	_check("combine: dni compounds below either",
		float(m["dni_factor"]) < float(a["dni_factor"]))

	# Heat and cold must not cancel into "comfortable".
	var hot := _heat_state(0.8)
	hot["thermal_stress"] = 0.8
	var cold := HazardState.blank()
	cold["id"] = "cold_snap"
	cold["severity"] = 0.5
	cold["thermal_stress"] = -0.5
	var mixed := HazardState.combine(hot, cold)
	_check("combine: thermal keeps worst sign",
		_approx(float(mixed["thermal_stress"]), 0.8),
		"got %f" % float(mixed["thermal_stress"]))


func _test_sanitize_rejects_nan() -> void:
	var bad := HazardState.blank()
	bad["severity"] = NAN
	bad["aod"] = NAN
	bad["visibility_m"] = NAN
	bad["sun_energy_mult"] = INF
	bad["haze_color"] = Color(NAN, 0.0, 0.0)
	var s := HazardState.sanitize(bad)
	for key: String in ["severity", "aod", "visibility_m", "sun_energy_mult",
			"dni_factor", "ghi_factor", "aqi"]:
		_check("sanitize: %s finite" % key, is_finite(float(s[key])),
			"got %s" % str(s[key]))
	var hc: Color = s["haze_color"]
	_check("sanitize: colour finite", is_finite(hc.r) and is_finite(hc.g) and is_finite(hc.b))
	_check("sanitize: NaN severity -> 0", _approx(float(s["severity"]), 0.0))
	# Out-of-range values clamp rather than propagate.
	var over := HazardState.blank()
	over["severity"] = 5.0
	over["aod"] = -3.0
	var o := HazardState.sanitize(over)
	_check("sanitize: severity clamps to 1", _approx(float(o["severity"]), 1.0))
	_check("sanitize: aod floors at 0", _approx(float(o["aod"]), 0.0))


func _test_koschmieder() -> void:
	# V = 3.912 / b_ext, and Godot's fog density IS b_ext.
	_check("koschmieder: 1000 m", _approx(
		HazardState.fog_density_for_visibility(1000.0), 0.003912, 0.0000001))
	_check("koschmieder: 200 m", _approx(
		HazardState.fog_density_for_visibility(200.0), 0.01956, 0.000001))
	# Round-trip.
	for v: float in [150.0, 800.0, 2500.0, 8000.0]:
		var d := HazardState.fog_density_for_visibility(v)
		_check("koschmieder: round-trip %.0f m" % v,
			_approx(HazardState.visibility_for_fog_density(d), v, 0.01))
	# Monotonic: less visibility must always mean denser fog.
	var prev := 0.0
	for v: float in [8000.0, 4000.0, 2000.0, 900.0, 300.0, 120.0]:
		var d := HazardState.fog_density_for_visibility(v)
		_check("koschmieder: monotonic at %.0f m" % v, d > prev, "%f after %f" % [d, prev])
		prev = d
	_check("koschmieder: NaN guarded",
		is_finite(HazardState.fog_density_for_visibility(NAN)))
	_check("koschmieder: zero guarded",
		is_finite(HazardState.fog_density_for_visibility(0.0)))


func _test_visibility_from_pm25() -> void:
	# Clean air stays effectively unlimited (Rayleigh floor only).
	_check("pm25: clean air is far", HazardState.visibility_from_pm25(0.0) > 50000.0)
	# More particulate must always mean less visibility.
	var prev := HazardState.CLEAR_VISIBILITY_M + 1.0
	for pm: float in [0.0, 12.0, 35.0, 55.0, 150.0, 250.0, 500.0]:
		var v := HazardState.visibility_from_pm25(pm)
		_check("pm25: monotonic at %.0f ug/m3" % pm, v < prev, "%f after %f" % [v, prev])
		_check("pm25: finite at %.0f" % pm, is_finite(v))
		prev = v
	# A "Hazardous" AQI day (PM2.5 ~250) should read as a few kilometres at most
	# — that is the real Portland/Seattle wildfire-smoke experience.
	var haz := HazardState.visibility_from_pm25(250.0)
	_check("pm25: hazardous day is km-scale", haz > 200.0 and haz < 8000.0,
		"got %.0f m" % haz)
	# Smoke extinguishes more per unit mass than generic dry fine aerosol, so
	# the same concentration must read visibly thicker under MEE_SMOKE.
	var dry := HazardState.visibility_from_pm25(250.0, 1.0, HazardState.MEE_FINE_DRY)
	var smk := HazardState.visibility_from_pm25(250.0, 1.0, HazardState.MEE_SMOKE)
	_check("pm25: smoke thicker than generic aerosol", smk < dry,
		"smoke %.0f vs dry %.0f" % [smk, dry])
	_check("pm25: MEE is bounded against absurd input",
		is_finite(HazardState.visibility_from_pm25(250.0, 1.0, NAN))
			and is_finite(HazardState.visibility_from_pm25(250.0, 1.0, 1e9)))
	# Humidity thickens the same mass of aerosol.
	_check("pm25: humid air reads thicker",
		HazardState.visibility_from_pm25(60.0, 2.5)
			< HazardState.visibility_from_pm25(60.0, 1.0))
	_check("pm25: NaN guarded", is_finite(HazardState.visibility_from_pm25(NAN)))


func _test_rh_growth() -> void:
	_check("rh: dry air is 1.0", _approx(HazardState.rh_growth_factor(30.0), 1.0))
	_check("rh: 70% is still 1.0", _approx(HazardState.rh_growth_factor(70.0), 1.0))
	var prev := 0.0
	for rh: float in [0.0, 50.0, 70.0, 80.0, 90.0, 95.0, 100.0]:
		var f := HazardState.rh_growth_factor(rh)
		_check("rh: monotonic at %.0f%%" % rh, f >= prev, "%f after %f" % [f, prev])
		_check("rh: finite at %.0f%%" % rh, is_finite(f))
		prev = f
	_check("rh: saturated air grows strongly", HazardState.rh_growth_factor(100.0) > 3.0)
	_check("rh: NaN guarded", _approx(HazardState.rh_growth_factor(NAN), 1.0))


## --- prefs -------------------------------------------------------------------

func _test_prefs_roundtrip() -> void:
	ExtremeWeatherPrefs.reset_for_test()
	# An id absent from the file falls back to the catalog default, so a hazard
	# added in a later build opts in on its own terms.
	_check("prefs: default from catalog",
		ExtremeWeatherPrefs.is_enabled("wildfire_smoke")
			== HazardCatalog.default_enabled("wildfire_smoke"))

	ExtremeWeatherPrefs.set_enabled("dust_storm", false)
	ExtremeWeatherPrefs.set_intensity(1.75)
	ExtremeWeatherPrefs.notify = false
	ExtremeWeatherPrefs.save()

	ExtremeWeatherPrefs.reset_for_test()
	ExtremeWeatherPrefs.ensure_loaded()
	_check("prefs: bool round-trips", not ExtremeWeatherPrefs.is_enabled("dust_storm"))
	_check("prefs: intensity round-trips",
		_approx(ExtremeWeatherPrefs.intensity, 1.75, 0.001),
		"got %f" % ExtremeWeatherPrefs.intensity)
	_check("prefs: notify round-trips", not ExtremeWeatherPrefs.notify)

	# The Drama slider is clamped, and NaN cannot poison it.
	ExtremeWeatherPrefs.set_intensity(99.0)
	_check("prefs: intensity clamps high",
		_approx(ExtremeWeatherPrefs.intensity, ExtremeWeatherPrefs.INTENSITY_MAX, 0.001))
	ExtremeWeatherPrefs.set_intensity(NAN)
	_check("prefs: NaN intensity -> 1.0", _approx(ExtremeWeatherPrefs.intensity, 1.0))

	# is_active gates on BOTH opt-in and "does a resolver exist" — the seven
	# unsimulated hazards stay toggleable for the risk display but never render.
	ExtremeWeatherPrefs.set_enabled("storm_surge", true)
	_check("prefs: unsimulated hazard is never active",
		not ExtremeWeatherPrefs.is_active("storm_surge"))
	ExtremeWeatherPrefs.set_enabled("wildfire_smoke", true)
	_check("prefs: simulated + enabled is active",
		ExtremeWeatherPrefs.is_active("wildfire_smoke"))
	ExtremeWeatherPrefs.set_enabled("wildfire_smoke", false)
	_check("prefs: simulated + disabled is inactive",
		not ExtremeWeatherPrefs.is_active("wildfire_smoke"))


## --- evaluators --------------------------------------------------------------

func _test_aqi_breakpoints() -> void:
	# Anchored to the published EPA breakpoints (40 CFR Part 58 App. G): if
	# these drift, the HUD is quoting a number that does not match what a
	# player would read on a real air-quality site.
	_check("aqi: clean air is 0", _approx(HazardEvaluators.us_aqi_from_pm25(0.0), 0.0))
	_check("aqi: 9.0 -> 50 (Good ceiling)",
		_approx(HazardEvaluators.us_aqi_from_pm25(9.0), 50.0, 0.5),
		"got %f" % HazardEvaluators.us_aqi_from_pm25(9.0))
	_check("aqi: 35.4 -> 100 (Moderate ceiling)",
		_approx(HazardEvaluators.us_aqi_from_pm25(35.4), 100.0, 0.5),
		"got %f" % HazardEvaluators.us_aqi_from_pm25(35.4))
	_check("aqi: 55.4 -> 150",
		_approx(HazardEvaluators.us_aqi_from_pm25(55.4), 150.0, 1.0),
		"got %f" % HazardEvaluators.us_aqi_from_pm25(55.4))
	_check("aqi: 125.4 -> 200",
		_approx(HazardEvaluators.us_aqi_from_pm25(125.4), 200.0, 1.0),
		"got %f" % HazardEvaluators.us_aqi_from_pm25(125.4))
	_check("aqi: 225.4 -> 300",
		_approx(HazardEvaluators.us_aqi_from_pm25(225.4), 300.0, 1.0),
		"got %f" % HazardEvaluators.us_aqi_from_pm25(225.4))
	_check("aqi: caps at 500", HazardEvaluators.us_aqi_from_pm25(9000.0) <= 500.0)
	_check("aqi: NaN guarded", is_finite(HazardEvaluators.us_aqi_from_pm25(NAN)))

	# Monotonic, or the breakpoint table has a gap.
	var prev := -1.0
	for pm: float in [0.0, 5.0, 9.0, 20.0, 35.4, 40.0, 55.4, 90.0, 125.4, 200.0, 225.4, 300.0, 400.0]:
		var a := HazardEvaluators.us_aqi_from_pm25(pm)
		_check("aqi: monotonic at %.1f" % pm, a >= prev, "%f after %f" % [a, prev])
		prev = a

	# Category names must match what a real report would say.
	_check("aqi: category Good", HazardEvaluators.aqi_category(25.0) == "Good")
	_check("aqi: category Unhealthy", HazardEvaluators.aqi_category(175.0) == "Unhealthy")
	_check("aqi: category Hazardous", HazardEvaluators.aqi_category(400.0) == "Hazardous")
	_check("aqi: category at 151 boundary",
		HazardEvaluators.aqi_category(151.0) == "Unhealthy")


func _test_beer_lambert() -> void:
	_check("beer: zero aod is transparent", _approx(HazardEvaluators.beer_lambert(0.0), 1.0))
	_check("beer: negative aod is transparent",
		_approx(HazardEvaluators.beer_lambert(-1.0), 1.0))
	# T = exp(-tau * m); at tau=1, m=1 that is 1/e.
	_check("beer: exp law at m=1",
		_approx(HazardEvaluators.beer_lambert(1.0, 1.0), exp(-1.0), 0.0001))
	_check("beer: exp law at m=1.5",
		_approx(HazardEvaluators.beer_lambert(2.0, 1.5), exp(-3.0), 0.0001))
	# Thicker aerosol always transmits less.
	var prev := 2.0
	for aod: float in [0.0, 0.2, 0.6, 1.2, 2.6, 3.4]:
		var t := HazardEvaluators.beer_lambert(aod)
		_check("beer: monotonic at aod %.1f" % aod, t < prev or _approx(t, 1.0),
			"%f after %f" % [t, prev])
		_check("beer: bounded at aod %.1f" % aod, t >= 0.0 and t <= 1.0)
		prev = t
	_check("beer: NaN guarded", is_finite(HazardEvaluators.beer_lambert(NAN)))
	# A severe smoke day must genuinely gut the direct beam — this is the number
	# that makes CSP and tracking PV collapse.
	_check("beer: severe smoke kills DNI",
		HazardEvaluators.beer_lambert(HazardEvaluators.SMOKE_AOD_MAX) < 0.05,
		"got %f" % HazardEvaluators.beer_lambert(HazardEvaluators.SMOKE_AOD_MAX))


func _test_hazard_profiles() -> void:
	# An unsimulated hazard has no profile and must degrade to nothing rather
	# than crash — the seven catalog-only rows all take this path.
	_check("profile: unsimulated -> blank",
		not HazardState.is_active(HazardEvaluators.state_for("storm_surge", 1.0)))
	_check("profile: unknown id -> blank",
		not HazardState.is_active(HazardEvaluators.state_for("nope", 1.0)))
	_check("profile: zero severity -> blank",
		not HazardState.is_active(HazardEvaluators.state_for("wildfire_smoke", 0.0)))
	_check("profile: NaN severity -> blank",
		not HazardState.is_active(HazardEvaluators.state_for("wildfire_smoke", NAN)))

	for id: String in HazardCatalog.simulated_ids():
		# Identity plumbed through.
		var s := HazardEvaluators.state_for(id, 0.7, "alert")
		_check("profile: %s carries id" % id, str(s["id"]) == id)
		_check("profile: %s carries label" % id,
			str(s["label"]) == HazardCatalog.display_name(id))
		_check("profile: %s carries source" % id, str(s["source"]) == "alert")
		_check("profile: %s severity plumbed" % id, _approx(float(s["severity"]), 0.7))

		# Every field finite at every severity — the NaN-into-a-shader guard.
		for sev: float in [0.01, 0.25, 0.5, 0.75, 1.0]:
			var t := HazardEvaluators.state_for(id, sev)
			for key: String in HazardState.blank().keys():
				var v: Variant = t[key]
				if v is float:
					_check("profile: %s.%s finite at %.2f" % [id, key, sev],
						is_finite(float(v)), "got %s" % str(v))

		# Monotonic in the directions that matter: worse hazard never means
		# better visibility or more sunlight.
		var prev_vis := HazardState.CLEAR_VISIBILITY_M + 1.0
		var prev_sun := 2.0
		for sev: float in [0.1, 0.3, 0.5, 0.7, 0.9, 1.0]:
			var t := HazardEvaluators.state_for(id, sev)
			var vis := float(t["visibility_m"])
			var sun := float(t["sun_energy_mult"])
			_check("profile: %s visibility non-increasing at %.1f" % [id, sev],
				vis <= prev_vis + 0.01, "%f after %f" % [vis, prev_vis])
			_check("profile: %s sun non-increasing at %.1f" % [id, sev],
				sun <= prev_sun + 0.0001, "%f after %f" % [sun, prev_sun])
			prev_vis = vis
			prev_sun = sun

	# Smoke: the defining look. Dim red sun, no distance, but still bright —
	# scattered light rises even as the direct beam dies.
	var smoke := HazardEvaluators.state_for("wildfire_smoke", 0.85)
	_check("smoke: sun reddens",
		(smoke["sun_tint"] as Color).r > (smoke["sun_tint"] as Color).b * 2.0)
	_check("smoke: sun dims", float(smoke["sun_energy_mult"]) < 0.5)
	# A severe smoke day must read as "the far side of town is gone" — a couple
	# of kilometres, not five. Anchored to the September 2020 Pacific Northwest
	# events, where visibility fell to roughly a mile at PM2.5 400-600.
	_check("smoke: visibility collapses to a couple of km",
		float(smoke["visibility_m"]) < 2500.0,
		"got %.0f m" % float(smoke["visibility_m"]))
	_check("smoke: but is not literal zero",
		float(smoke["visibility_m"]) > 300.0,
		"got %.0f m" % float(smoke["visibility_m"]))
	_check("smoke: DHI rises as DNI falls",
		float(smoke["dhi_boost"]) > 0.0 and float(smoke["dni_factor"]) < 0.3)
	_check("smoke: severe day is a real AQI emergency",
		float(smoke["aqi"]) > 200.0, "got %f" % float(smoke["aqi"]))
	# Deliberately no particle system — a drifting-ash emitter read as sparks at
	# night, and the fog/haze already carries the effect. See hazard_evaluators.gd.
	_check("smoke: emits no particles", str(smoke["particle_kind"]) == "")
	_check("smoke: zero particle density", _approx(float(smoke["particle_density"]), 0.0))

	# Dust is optically harsher than smoke at equal severity — that contrast is
	# the whole reason they read as different events.
	var dust := HazardEvaluators.state_for("dust_storm", 0.85)
	_check("dust: darker than smoke at equal severity",
		float(dust["sun_energy_mult"]) < float(smoke["sun_energy_mult"]),
		"dust %f vs smoke %f" % [float(dust["sun_energy_mult"]), float(smoke["sun_energy_mult"])])
	_check("dust: lower visibility than smoke",
		float(dust["visibility_m"]) < float(smoke["visibility_m"]))
	_check("dust: tan not red",
		(dust["haze_color"] as Color).g > (smoke["haze_color"] as Color).g)
	_check("dust: drives wind", float(dust["wind_mult"]) > 1.0)
	_check("dust: emits dust", str(dust["particle_kind"]) == "dust")

	# Wind is deliberately NOT a haze — if it dimmed the sun like smoke, the two
	# hazards would be indistinguishable on screen.
	var wind := HazardEvaluators.state_for("damaging_winds", 0.9)
	_check("wind: barely tints", float(wind["haze_strength"]) < 0.2)
	_check("wind: does not dim the sun", _approx(float(wind["sun_energy_mult"]), 1.0))
	_check("wind: derates turbines", float(wind["wind_derate"]) > 0.5)
	_check("wind: no particles", str(wind["particle_kind"]) == "")

	# Heat lives in the thermal channel only.
	var heat := HazardEvaluators.state_for("heatwave", 0.9)
	_check("heat: thermal stress positive", float(heat["thermal_stress"]) > 0.5)
	_check("heat: no aerosol", _approx(float(heat["aod"]), 0.0))
	_check("heat: does not gut the sun", float(heat["sun_energy_mult"]) > 0.9)

	# NO CLIFFS. A previous dust curve did almost nothing until severity 0.8 and
	# then collapsed from 2.4 km to 90 m in the final fifth, which reads as a
	# bug rather than as weather.
	#
	# The invariant is deliberately about the SHAPE, not the steepness: a
	# uniformly steep curve is fine (a dust front really does arrive fast), what
	# is broken is ONE anomalous step. So compare each step's visibility ratio
	# against the median step — a cliff is an outlier among its neighbours.
	# On the curve this replaced, that outlier ratio was 17x the median; a
	# healthy curve sits near 2x.
	for id: String in ["wildfire_smoke", "dust_storm"]:
		var ratios: Array[float] = []
		var prev_v := 0.0
		for step in range(1, 6):
			var v := float(HazardEvaluators.state_for(id, float(step) * 0.2)["visibility_m"])
			if prev_v > 0.0:
				ratios.append(prev_v / maxf(v, 1.0))
			prev_v = v
		var sorted_r := ratios.duplicate()
		sorted_r.sort()
		var median: float = sorted_r[sorted_r.size() / 2]
		var worst: float = sorted_r[sorted_r.size() - 1]
		_check("curve: %s has no cliff step" % id, worst <= median * 3.0,
			"worst step %.1fx vs median %.1fx" % [worst, median])
		# Every step must actually move — a flat region is its own kind of bug.
		for r: float in ratios:
			_check("curve: %s every step moves" % id, r > 1.05, "ratio %.3f" % r)
		# ...and the midpoint must already be visibly bad, or the hazard only
		# exists at its extreme.
		var mid := float(HazardEvaluators.state_for(id, 0.6)["visibility_m"])
		_check("curve: %s midpoint is already dramatic" % id, mid < 4000.0,
			"got %.0f m at severity 0.6" % mid)

	# Dust is harsher than smoke across the whole usable range, not just at the
	# top — that contrast is what makes them read as different events.
	for sev: float in [0.4, 0.6, 0.8, 1.0]:
		var sm := float(HazardEvaluators.state_for("wildfire_smoke", sev)["visibility_m"])
		var du := float(HazardEvaluators.state_for("dust_storm", sev)["visibility_m"])
		_check("curve: dust thicker than smoke at %.1f" % sev, du < sm,
			"dust %.0f vs smoke %.0f" % [du, sm])

	# NO SATURATION IN THE GAMEPLAY CHANNEL. The US AQI is defined to truncate
	# at 500, which heavy smoke reaches by roughly 0.6 severity — so a
	# breath_hazard derived from AQI made every event from 0.6 upward feel
	# identical to the player and to the NPC work gate. The displayed AQI may
	# saturate (the real index does); breath_hazard must keep discriminating all
	# the way to 1.0.
	for id: String in ["wildfire_smoke", "dust_storm"]:
		var prev_b := -1.0
		for sev: float in [0.6, 0.7, 0.8, 0.9, 1.0]:
			var b := float(HazardEvaluators.state_for(id, sev)["breath_hazard"])
			_check("breath: %s still rising at %.1f" % [id, sev], b > prev_b,
				"%f after %f" % [b, prev_b])
			prev_b = b
		_check("breath: %s reaches full hazard" % id, prev_b >= 0.99,
			"tops out at %f" % prev_b)

	# Severe hazards demand shelter; mild ones do not.
	_check("shelter: severe dust requires it",
		bool(HazardEvaluators.state_for("dust_storm", 0.9)["shelter_required"]))
	_check("shelter: mild dust does not",
		not bool(HazardEvaluators.state_for("dust_storm", 0.2)["shelter_required"]))


## --- risk profile ------------------------------------------------------------

func _test_risk_profile_from_vtec() -> void:
	# Two decades of a smoky, occasionally windy, never dusty zone.
	var events := {
		2015: [
			_alert("SM", "Dense Smoke Advisory", 100.0, 118.0, 8),
			_alert("SM", "Dense Smoke Advisory", 300.0, 306.0, 8),
		],
		2020: [
			# The siege year: one very long event.
			_alert("SM", "Dense Smoke Advisory", 1000.0, 1218.0, 9),
			_alert("FW", "Red Flag Warning", 1300.0, 1312.0, 9),
			_alert("HW", "High Wind Warning", 1400.0, 1410.0, 11),
		],
		2024: [
			_alert("HW", "High Wind Warning", 2000.0, 2012.0, 1),
			# Below MIN_EVENT_HOURS — an amended product, not a lived event.
			_alert("SM", "Dense Smoke Advisory", 2100.0, 2100.1, 7),
			# Not one of ours.
			_alert("MA", "Marine Weather Statement", 2200.0, 2210.0, 3),
		],
	}
	var p := HazardRiskProfile.from_vtec_history(events, 2015, 2024)

	_check("profile: every hazard present", p.size() == HazardCatalog.ids().size(),
		"got %d" % p.size())

	var smoke: Dictionary = p["wildfire_smoke"]
	# 2 (2015) + 2 (2020, incl. the Red Flag) = 4; the 0.1 h row is rejected.
	_check("profile: smoke counted", int(smoke["count"]) == 4,
		"got %d" % int(smoke["count"]))
	_check("profile: sub-threshold event rejected", int(smoke["count"]) != 5)
	_check("profile: worst year is the siege", int(smoke["worst_year"]) == 2020,
		"got %d" % int(smoke["worst_year"]))
	_check("profile: worst hours tallied", _approx(float(smoke["worst_hours"]), 230.0, 0.5),
		"got %f" % float(smoke["worst_hours"]))
	# The only 2024 smoke row is the 0.1 h artifact, so "last seen" must stay
	# 2020: a rejected event is rejected everywhere, not just in the count.
	_check("profile: last year skips rejected events", int(smoke["last_year"]) == 2020,
		"got %d" % int(smoke["last_year"]))
	_check("profile: last year tracked for a real event",
		int((p["damaging_winds"] as Dictionary)["last_year"]) == 2024,
		"got %d" % int((p["damaging_winds"] as Dictionary)["last_year"]))
	# 4 events over a 10-year span = 4.0 per decade -> MODERATE.
	_check("profile: per-decade rate", _approx(float(smoke["events_per_decade"]), 4.0, 0.01),
		"got %f" % float(smoke["events_per_decade"]))
	_check("profile: smoke level moderate",
		str(smoke["level"]) == HazardCatalog.RISK_MODERATE, "got %s" % str(smoke["level"]))
	# Seasonality: the smoke months are Aug/Sep, never January.
	var hist: Array = smoke["month_histogram"]
	_check("profile: month histogram is 12 long", hist.size() == 12)
	_check("profile: august counted", int(hist[7]) == 2, "got %d" % int(hist[7]))
	_check("profile: september counted", int(hist[8]) == 2, "got %d" % int(hist[8]))
	_check("profile: january empty", int(hist[0]) == 0)

	var wind: Dictionary = p["damaging_winds"]
	_check("profile: HW mapped to damaging winds", int(wind["count"]) == 2,
		"got %d" % int(wind["count"]))

	# A zone that genuinely never saw dust reads as observed-zero, not unknown.
	var dust: Dictionary = p["dust_storm"]
	_check("profile: unobserved hazard counts 0", int(dust["count"]) == 0)
	_check("profile: unobserved hazard is NONE",
		str(dust["level"]) == HazardCatalog.RISK_NONE)
	_check("profile: unobserved hazard is sourced vtec",
		str(dust["source"]) == "vtec")

	# Empty history must not crash or invent risk.
	var empty := HazardRiskProfile.from_vtec_history({}, 2015, 2024)
	_check("profile: empty history -> all NONE",
		str((empty["wildfire_smoke"] as Dictionary)["level"]) == HazardCatalog.RISK_NONE)

	# Month derived from onset_abs when not precomputed — the real path.
	var derived := HazardRiskProfile.from_vtec_history({
		2020: [_alert_no_month("SM", "Dense Smoke Advisory",
			_abs_for(2020, 9, 12, 10.0), _abs_for(2020, 9, 14, 10.0))],
	}, 2020, 2020)
	var dh: Array = (derived["wildfire_smoke"] as Dictionary)["month_histogram"]
	_check("profile: month derived from onset_abs", int(dh[8]) == 1,
		"september bucket got %d" % int(dh[8]))


func _test_risk_profile_climatology() -> void:
	# An arid, windy, hot site: Phoenix-like.
	var desert := HazardRiskProfile.from_climatology({
		"annual_precip_mm": 180.0, "max_month_wind_ms": 9.5,
		"longest_dry_days": 90.0, "summer_max_c": 45.0,
		"hours_above_35c": 900.0, "winter_min_c": 2.0,
		"annual_snow_cm": 0.0, "max_rain_24h_mm": 30.0,
		"latitude": 33.4, "min_elevation_m": 330.0,
	})
	_check("climo: desert dust is HIGH",
		str((desert["dust_storm"] as Dictionary)["level"]) == HazardCatalog.RISK_HIGH,
		"got %s" % str((desert["dust_storm"] as Dictionary)["level"]))
	_check("climo: desert heat is HIGH",
		str((desert["heatwave"] as Dictionary)["level"]) == HazardCatalog.RISK_HIGH)
	_check("climo: desert blizzard is LOW",
		str((desert["blizzard"] as Dictionary)["level"]) == HazardCatalog.RISK_LOW)
	# Inland, so no surge even though the latitude is tropical-ish.
	_check("climo: inland site has no surge risk",
		str((desert["storm_surge"] as Dictionary)["level"]) == HazardCatalog.RISK_NONE,
		"got %s" % str((desert["storm_surge"] as Dictionary)["level"]))
	_check("climo: source labelled",
		str((desert["dust_storm"] as Dictionary)["source"]) == "climatology")

	# A cold wet northern site: nothing dusty, plenty of winter.
	var north := HazardRiskProfile.from_climatology({
		"annual_precip_mm": 1100.0, "max_month_wind_ms": 7.0,
		"longest_dry_days": 12.0, "summer_max_c": 22.0,
		"hours_above_35c": 0.0, "winter_min_c": -26.0,
		"annual_snow_cm": 220.0, "max_rain_24h_mm": 60.0,
		"latitude": 61.2, "min_elevation_m": 140.0,
	})
	_check("climo: north blizzard is HIGH",
		str((north["blizzard"] as Dictionary)["level"]) == HazardCatalog.RISK_HIGH)
	_check("climo: north cold snap is HIGH",
		str((north["cold_snap"] as Dictionary)["level"]) == HazardCatalog.RISK_HIGH)
	_check("climo: north dust is LOW",
		str((north["dust_storm"] as Dictionary)["level"]) == HazardCatalog.RISK_LOW)
	# Deep cold means snow, not glaze — the ice-storm straddle must not fire.
	_check("climo: deep cold is not an ice-storm site",
		str((north["ice_storm"] as Dictionary)["level"]) != HazardCatalog.RISK_HIGH,
		"got %s" % str((north["ice_storm"] as Dictionary)["level"]))

	# A tropical coast gets both wind and surge.
	var coast := HazardRiskProfile.from_climatology({
		"annual_precip_mm": 1400.0, "max_month_wind_ms": 11.0,
		"longest_dry_days": 20.0, "summer_max_c": 33.0,
		"hours_above_35c": 60.0, "winter_min_c": 12.0,
		"annual_snow_cm": 0.0, "max_rain_24h_mm": 180.0,
		"latitude": 25.8, "min_elevation_m": 2.0,
	})
	_check("climo: tropical coast wind is HIGH",
		str((coast["damaging_winds"] as Dictionary)["level"]) == HazardCatalog.RISK_HIGH)
	_check("climo: tropical coast surge is HIGH",
		str((coast["storm_surge"] as Dictionary)["level"]) == HazardCatalog.RISK_HIGH)
	_check("climo: heavy rain floods",
		str((coast["flooding"] as Dictionary)["level"]) == HazardCatalog.RISK_HIGH)

	# No data at all: honest UNKNOWN, never a confident "safe".
	var blind := HazardRiskProfile.from_climatology({})
	_check("climo: no data -> unknown",
		str((blind["dust_storm"] as Dictionary)["level"]) == HazardCatalog.RISK_UNKNOWN)
	_check("climo: unknown renders an empty bar",
		_approx(HazardCatalog.risk_fill(HazardCatalog.RISK_UNKNOWN), 0.0))
	# Blackout is always derived, never observed.
	_check("climo: blackout always moderate",
		str((blind["blackout"] as Dictionary)["level"]) == HazardCatalog.RISK_MODERATE)


func _test_risk_profile_merge_and_display() -> void:
	var vtec := HazardRiskProfile.from_vtec_history({
		2020: [_alert("SM", "Dense Smoke Advisory", 100.0, 130.0, 9)],
	}, 2011, 2020)
	var climo := HazardRiskProfile.from_climatology({
		"annual_precip_mm": 180.0, "max_month_wind_ms": 9.5,
		"longest_dry_days": 90.0, "summer_max_c": 45.0,
		"hours_above_35c": 900.0, "winter_min_c": 2.0,
		"annual_snow_cm": 0.0, "max_rain_24h_mm": 30.0,
		"latitude": 33.4, "min_elevation_m": 330.0,
	})
	var m := HazardRiskProfile.merge(vtec, climo)
	# An OBSERVED zero survives the merge: 40 years of record showing no dust
	# storms is evidence, and climatology must not overwrite it.
	_check("merge: observed zero is kept",
		str((m["dust_storm"] as Dictionary)["level"]) == HazardCatalog.RISK_NONE,
		"got %s" % str((m["dust_storm"] as Dictionary)["level"]))
	_check("merge: observed count survives",
		int((m["wildfire_smoke"] as Dictionary)["count"]) == 1)
	# Blackout has no VTEC codes, so climatology fills it.
	_check("merge: codeless hazard filled from climatology",
		str((m["blackout"] as Dictionary)["level"]) == HazardCatalog.RISK_MODERATE)
	_check("merge: filled row is relabelled",
		str((m["blackout"] as Dictionary)["source"]) == "climatology")
	# Degenerate inputs.
	_check("merge: empty vtec -> climo", HazardRiskProfile.merge({}, climo).size() == climo.size())
	_check("merge: empty climo -> vtec", HazardRiskProfile.merge(vtec, {}).size() == vtec.size())

	# Display strings.
	_check("display: observed line mentions rate",
		HazardRiskProfile.summary_line(m["wildfire_smoke"]).contains("/decade"))
	_check("display: unobserved line is explicit",
		HazardRiskProfile.summary_line(vtec["hailstorm"]) == "not observed here",
		"got '%s'" % HazardRiskProfile.summary_line(vtec["hailstorm"]))
	_check("display: unknown line is explicit",
		HazardRiskProfile.summary_line({"level": HazardCatalog.RISK_UNKNOWN})
			== "no local record")

	# Sort order: riskiest first, and stable (every hazard present exactly once).
	var order := HazardRiskProfile.sorted_ids(m)
	_check("sort: all hazards listed", order.size() == HazardCatalog.ids().size())
	var seen: Dictionary = {}
	for id: String in order:
		_check("sort: %s listed once" % id, not seen.has(id))
		seen[id] = true
	var prev_fill := 2.0
	for id: String in order:
		var f := HazardCatalog.risk_fill(str((m[id] as Dictionary).get("level", "")))
		_check("sort: descending risk at %s" % id, f <= prev_fill + 0.0001,
			"%f after %f" % [f, prev_fill])
		prev_fill = f
	# Deterministic across calls — the tab re-sorts on every refresh.
	_check("sort: deterministic", str(HazardRiskProfile.sorted_ids(m)) == str(order))


## --- atmosphere applier ------------------------------------------------------

## main.gd's clean-air environment at midday, as _update_environment computes it.
func _clean_base() -> Dictionary:
	return {
		"fog_density": 0.00030,
		"fog_depth_end": 8000.0,
		"fog_light_color": Color(0.68, 0.78, 0.94),
		"fog_aerial_perspective": 0.62,
		"fog_sun_scatter": 0.03,
		"fog_sky_affect": 0.0,
		"ambient_energy": 0.3,
		"glow_intensity": 0.30,
		"glow_hdr_threshold": 1.5,
		"exposure_offset": 0.0,
	}


func _test_atmosphere_applier() -> void:
	var base := _clean_base()

	# THE IDENTITY GUARANTEE. This single property is what makes "extreme
	# weather disabled => not one pixel changes" true across every existing
	# scene, so it is asserted field-for-field rather than assumed.
	var idle := AtmosphereApplier.resolve(base, HazardState.blank(), 0.0, 1.0)
	for key: String in base.keys():
		_check("applier: identity preserves %s" % key, _same(idle[key], base[key]),
			"%s vs %s" % [str(idle[key]), str(base[key])])
	# ...and at every time of day, since night gating must not perturb it either.
	for night: float in [0.0, 0.5, 1.0]:
		var q := AtmosphereApplier.resolve(base, HazardState.blank(), night, 0.5)
		for key: String in base.keys():
			_check("applier: identity holds at night %.1f (%s)" % [night, key],
				_same(q[key], base[key]))
	# A sub-threshold hazard is also a no-op — no visible pop as one fades in.
	var whisper := HazardEvaluators.state_for("wildfire_smoke", 0.004)
	var w := AtmosphereApplier.resolve(base, whisper, 0.0, 1.0)
	_check("applier: sub-threshold hazard is inert",
		_same(w["fog_density"], base["fog_density"]))

	# --- the smoke look
	var smoke := HazardEvaluators.state_for("wildfire_smoke", 0.9)
	var s := AtmosphereApplier.resolve(base, smoke, 0.0, 1.0)
	_check("applier: fog thickens", float(s["fog_density"]) > float(base["fog_density"]))
	_check("applier: distance closes in",
		float(s["fog_depth_end"]) < float(base["fog_depth_end"]))
	_check("applier: fog reddens", (s["fog_light_color"] as Color).r
		> (s["fog_light_color"] as Color).b)
	_check("applier: sky is taken over", float(s["fog_sky_affect"]) > 0.2)
	_check("applier: sun dims", float(s["sun_energy_mult"]) < 0.5)
	_check("applier: exposure drops", float(s["exposure_offset"]) < 0.0)
	_check("applier: bloom rises", float(s["glow_intensity"]) > float(base["glow_intensity"]))
	_check("applier: bloom threshold falls",
		float(s["glow_hdr_threshold"]) < float(base["glow_hdr_threshold"]))
	_check("applier: ambient flattens",
		float(s["ambient_energy"]) < float(base["ambient_energy"]))

	# THE INVERSION TRAP. With fog_sky_affect at 0, aerial perspective blends the
	# RENDERED SKY COLOUR into distant geometry — so raising it under smoke would
	# push terrain toward BLUE, the opposite of the intent. It must go DOWN.
	# An earlier draft of this design had it backwards.
	_check("applier: aerial perspective DROPS under haze",
		float(s["fog_aerial_perspective"]) < float(base["fog_aerial_perspective"]),
		"got %f vs base %f" % [float(s["fog_aerial_perspective"]),
			float(base["fog_aerial_perspective"])])

	# --- night gating: a brown starless night is the failure mode.
	var night_s := AtmosphereApplier.resolve(base, smoke, 1.0, -0.2)
	_check("applier: sky untouched at night",
		_approx(float(night_s["fog_sky_affect"]), 0.0),
		"got %f" % float(night_s["fog_sky_affect"]))
	_check("applier: no exposure shift at night",
		_approx(float(night_s["exposure_offset"]), 0.0))
	# ...but ground-level haze persists — smoke does not stop existing at dusk.
	_check("applier: ground fog persists at night",
		float(night_s["fog_density"]) > float(base["fog_density"]))

	# --- never CLEARS the air. A mild hazard whose Koschmieder density lands
	# below the clean-air baseline must not make the world more transparent.
	var faint := HazardEvaluators.state_for("damaging_winds", 0.1)
	var f := AtmosphereApplier.resolve(base, faint, 0.0, 1.0)
	_check("applier: never thins fog below baseline",
		float(f["fog_density"]) >= float(base["fog_density"]) - 0.0000001,
		"got %f vs base %f" % [float(f["fog_density"]), float(base["fog_density"])])

	# --- monotonic and bounded across every hazard and time of day.
	for id: String in HazardCatalog.simulated_ids():
		var prev_d := 0.0
		var prev_e := 8001.0
		for sev: float in [0.2, 0.4, 0.6, 0.8, 1.0]:
			var o := AtmosphereApplier.resolve(
				base, HazardEvaluators.state_for(id, sev), 0.0, 1.0)
			var d := float(o["fog_density"])
			var e := float(o["fog_depth_end"])
			_check("applier: %s density non-decreasing at %.1f" % [id, sev],
				d >= prev_d - 0.0000001, "%f after %f" % [d, prev_d])
			_check("applier: %s depth non-increasing at %.1f" % [id, sev],
				e <= prev_e + 0.01, "%f after %f" % [e, prev_e])
			_check("applier: %s density within clamp at %.1f" % [id, sev],
				d >= AtmosphereApplier.FOG_DENSITY_MIN
					and d <= AtmosphereApplier.FOG_DENSITY_MAX, "got %f" % d)
			prev_d = d
			prev_e = e

	# --- finiteness sweep. clampf does NOT filter NaN, and a non-finite value
	# reaching a light energy or shader uniform hard-hangs the Vulkan driver
	# (main.gd documents this as a whole-desktop failure).
	for id: String in HazardCatalog.simulated_ids():
		for sev: float in [0.01, 0.5, 1.0]:
			for night: float in [0.0, 0.5, 1.0]:
				var o := AtmosphereApplier.resolve(
					base, HazardEvaluators.state_for(id, sev), night, 0.3)
				for key: String in o.keys():
					var v: Variant = o[key]
					if v is float:
						_check("applier: %s.%s finite (sev %.2f night %.1f)"
							% [id, key, sev, night], is_finite(float(v)))
	# Garbage in stays finite too.
	var poison := HazardState.blank()
	poison["severity"] = 0.8
	poison["visibility_m"] = NAN
	poison["haze_strength"] = NAN
	var p := AtmosphereApplier.resolve(base, poison, NAN, NAN)
	for key: String in p.keys():
		if p[key] is float:
			_check("applier: survives NaN input (%s)" % key, is_finite(float(p[key])),
				"got %s" % str(p[key]))

	# --- the emissive dust wall
	var still_dust := HazardEvaluators.state_for("dust_storm", 0.8)
	still_dust["wind_mult"] = 1.0   # dust suspended, not driven
	var v_still := AtmosphereApplier.volumetric_for(still_dust, 1.0)
	_check("volumetric: suspended dust does not glow", not bool(v_still["vol_force"]))
	var driven := HazardEvaluators.state_for("dust_storm", 0.8)
	var v_driven := AtmosphereApplier.volumetric_for(driven, 1.0)
	_check("volumetric: driven dust forces volumetric fog", bool(v_driven["vol_force"]))
	_check("volumetric: driven dust emits", float(v_driven["vol_emission_energy"]) > 0.0)
	_check("volumetric: lights the sun through the volume",
		float(v_driven["vol_sun_energy"]) > 1.0)
	# The glow is scattered SUNLIGHT, so it must fade with the sun — a wall
	# self-luminous at midnight reads as a bug.
	var v_night := AtmosphereApplier.volumetric_for(driven, -0.3)
	_check("volumetric: does not glow at night",
		_approx(float(v_night["vol_emission_energy"]), 0.0),
		"got %f" % float(v_night["vol_emission_energy"]))
	# Smoke is not a dust wall.
	_check("volumetric: smoke does not force volumetrics",
		not bool(AtmosphereApplier.volumetric_for(
			HazardEvaluators.state_for("wildfire_smoke", 1.0), 1.0)["vol_force"]))
	_check("volumetric: blank hazard is inert",
		not bool(AtmosphereApplier.volumetric_for(HazardState.blank(), 1.0)["vol_force"]))

	# --- particle gates (pure statics, so pinnable with no scene tree)
	# Wildfire smoke has NO particle emitter — see DustSmokeVfx's header for why
	# (a drifting-ash system read as sparks at night) — so dust is the only
	# gate left to pin.
	# Dust grains need wind: suspended dust is haze the fog already expresses,
	# so a still-air dust event must emit far fewer grains than a driven one.
	_check("vfx: still dust emits little",
		DustSmokeVfx.dust_intensity_t(0.8, 1.0) < DustSmokeVfx.dust_intensity_t(0.8, 2.0) * 0.5,
		"still %f vs driven %f" % [DustSmokeVfx.dust_intensity_t(0.8, 1.0),
			DustSmokeVfx.dust_intensity_t(0.8, 2.0)])
	_check("vfx: driven dust saturates",
		_approx(DustSmokeVfx.dust_intensity_t(1.0, 2.0), 1.0))
	_check("vfx: dust NaN guarded",
		is_finite(DustSmokeVfx.dust_intensity_t(NAN, NAN)))
	var pv := -0.001
	for sev: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var v := DustSmokeVfx.dust_intensity_t(sev, 1.8)
		_check("vfx: dust monotonic at %.2f" % sev, v >= pv, "%f after %f" % [v, pv])
		pv = v

	# --- sky haze uniforms
	var sh := AtmosphereApplier.sky_haze_for(smoke, 0.0)
	_check("sky haze: day tint is strong", float(sh["haze_strength"]) > 0.3)
	_check("sky haze: night tint is zero",
		_approx(float(AtmosphereApplier.sky_haze_for(smoke, 1.0)["haze_strength"]), 0.0))
	_check("sky haze: blank hazard is zero",
		_approx(float(AtmosphereApplier.sky_haze_for(HazardState.blank(), 0.0)["haze_strength"]), 0.0))


## --- severity from data ------------------------------------------------------

func _test_severity_evaluators() -> void:
	# Nothing in, nothing out. An offline site must raise no hazards rather than
	# false ones.
	for id: String in HazardCatalog.simulated_ids():
		_check("eval: %s empty sample -> 0" % id,
			_approx(HazardEvaluators.evaluate(id, {}), 0.0))
		_check("eval: %s NaN sample -> 0" % id, _approx(HazardEvaluators.evaluate(id,
			{"pm25": NAN, "pm10": NAN, "dust": NAN, "wind_ms": NAN, "temp_c": NAN}), 0.0))
	_check("eval: unknown hazard -> 0", _approx(HazardEvaluators.evaluate("nope",
		{"pm25": 400.0}), 0.0))

	# --- THE DISAMBIGUATION. Smoke and dust push PM2.5, PM10 and AOD in the
	# same direction, so without a mode test a haboob would also raise a
	# wildfire-smoke event and the player would get an orange sky with no fire.
	# Smoke is fine-mode (PM2.5/PM10 ~0.8); dust is coarse (~0.2).
	var smoky := {
		"pm25": 300.0, "pm10": 360.0, "dust": 5.0, "aod": 2.0,
		"wind_ms": 3.0, "rain_mmh": 0.0,
	}
	var dusty := {
		"pm25": 300.0, "pm10": 1500.0, "dust": 4000.0, "aod": 2.0,
		"wind_ms": 18.0, "rain_mmh": 0.0,
	}
	var smoke_on_smoke := HazardEvaluators.evaluate_wildfire_smoke(smoky)
	var smoke_on_dust := HazardEvaluators.evaluate_wildfire_smoke(dusty)
	var dust_on_dust := HazardEvaluators.evaluate_dust_storm(dusty)
	var dust_on_smoke := HazardEvaluators.evaluate_dust_storm(smoky)
	_check("eval: smoke fires on fine aerosol", smoke_on_smoke > 0.3,
		"got %f" % smoke_on_smoke)
	_check("eval: smoke does NOT fire on coarse dust", smoke_on_dust < 0.05,
		"got %f (dust event raised a smoke hazard)" % smoke_on_dust)
	_check("eval: dust fires on coarse aerosol", dust_on_dust > 0.2,
		"got %f" % dust_on_dust)
	_check("eval: dust does NOT fire on fine smoke", dust_on_smoke < 0.05,
		"got %f (smoke event raised a dust hazard)" % dust_on_smoke)

	# --- smoke
	_check("eval: clean air raises no smoke",
		_approx(HazardEvaluators.evaluate_wildfire_smoke(
			{"pm25": 4.0, "pm10": 6.0, "aod": 0.05}), 0.0, 0.05))
	var prev := -0.001
	for pm: float in [10.0, 60.0, 150.0, 300.0, 450.0, 600.0]:
		var s := HazardEvaluators.evaluate_wildfire_smoke(
			{"pm25": pm, "pm10": pm / 0.8, "aod": pm / 250.0})
		_check("eval: smoke monotonic at pm %.0f" % pm, s >= prev,
			"%f after %f" % [s, prev])
		_check("eval: smoke bounded at pm %.0f" % pm, s >= 0.0 and s <= 1.0)
		prev = s
	_check("eval: extreme smoke approaches full", prev > 0.7, "got %f" % prev)
	# A PM2.5 spike with no optical depth is a ground inversion, not a plume.
	_check("eval: no AOD damps the smoke reading",
		HazardEvaluators.evaluate_wildfire_smoke({"pm25": 300.0, "pm10": 375.0, "aod": 0.0})
			< HazardEvaluators.evaluate_wildfire_smoke({"pm25": 300.0, "pm10": 375.0, "aod": 2.5}))

	# --- dust: needs BOTH concentration and wind, and dies on wet ground.
	var base_dust := {"dust": 6000.0, "pm10": 7000.0, "pm25": 1000.0, "rain_mmh": 0.0}
	var still := base_dust.duplicate(); still["wind_ms"] = 1.0
	var blowing := base_dust.duplicate(); blowing["wind_ms"] = 20.0
	_check("eval: still-air dust is much weaker than blowing",
		HazardEvaluators.evaluate_dust_storm(still)
			< HazardEvaluators.evaluate_dust_storm(blowing) * 0.5,
		"still %f vs blowing %f" % [HazardEvaluators.evaluate_dust_storm(still),
			HazardEvaluators.evaluate_dust_storm(blowing)])
	_check("eval: transported dust aloft still hazes",
		HazardEvaluators.evaluate_dust_storm(still) > 0.0)
	var wet := blowing.duplicate(); wet["rain_mmh"] = 2.0
	_check("eval: rain suppresses dust entirely",
		_approx(HazardEvaluators.evaluate_dust_storm(wet), 0.0),
		"got %f" % HazardEvaluators.evaluate_dust_storm(wet))
	# CAMS Europe carries no `dust` column; the coarse fraction of PM10 stands in.
	var no_dust_col := {"pm10": 7000.0, "pm25": 900.0, "wind_ms": 20.0, "rain_mmh": 0.0}
	_check("eval: falls back to PM10 coarse fraction without a dust column",
		HazardEvaluators.evaluate_dust_storm(no_dust_col) > 0.1,
		"got %f" % HazardEvaluators.evaluate_dust_storm(no_dust_col))

	# --- wind: gusts are what break things, and were unread before now.
	_check("eval: calm raises nothing",
		_approx(HazardEvaluators.evaluate_damaging_winds({"wind_ms": 5.0, "gust_ms": 8.0}), 0.0))
	_check("eval: a gale registers",
		HazardEvaluators.evaluate_damaging_winds({"wind_ms": 21.0, "gust_ms": 21.0}) > 0.3)
	_check("eval: hurricane-force saturates",
		_approx(HazardEvaluators.evaluate_damaging_winds(
			{"wind_ms": 40.0, "gust_ms": 55.0}), 1.0))
	# A gusty day with a modest mean must still register — the whole reason
	# gusts are read separately.
	_check("eval: gusts alone can raise the hazard",
		HazardEvaluators.evaluate_damaging_winds({"wind_ms": 12.0, "gust_ms": 30.0}) > 0.3,
		"got %f" % HazardEvaluators.evaluate_damaging_winds({"wind_ms": 12.0, "gust_ms": 30.0}))

	# --- heat is SITE-RELATIVE: the same temperature must be an emergency in
	# one place and unremarkable in another, or Phoenix is permanently on fire.
	var portland := {"temp_c": 38.0, "heat_threshold_c": 30.0, "humidity_pct": 40.0}
	var phoenix := {"temp_c": 38.0, "heat_threshold_c": 44.0, "humidity_pct": 15.0}
	_check("eval: 38C is a heatwave in a cool climate",
		HazardEvaluators.evaluate_heatwave(portland) > 0.5,
		"got %f" % HazardEvaluators.evaluate_heatwave(portland))
	_check("eval: 38C is unremarkable in a hot climate",
		_approx(HazardEvaluators.evaluate_heatwave(phoenix), 0.0),
		"got %f" % HazardEvaluators.evaluate_heatwave(phoenix))
	_check("eval: cold weather raises no heatwave",
		_approx(HazardEvaluators.evaluate_heatwave({"temp_c": 5.0}), 0.0))
	# Humid heat is physiologically worse at equal temperature.
	_check("eval: humidity worsens heat",
		HazardEvaluators.evaluate_heatwave(
			{"temp_c": 38.0, "heat_threshold_c": 32.0, "humidity_pct": 85.0})
		> HazardEvaluators.evaluate_heatwave(
			{"temp_c": 38.0, "heat_threshold_c": 32.0, "humidity_pct": 20.0}))
	_check("eval: heat bounded at 1",
		HazardEvaluators.evaluate_heatwave(
			{"temp_c": 60.0, "heat_threshold_c": 30.0, "humidity_pct": 95.0}) <= 1.0)
	# No local threshold falls back to an absolute default rather than failing.
	_check("eval: heat without a site threshold still works",
		HazardEvaluators.evaluate_heatwave({"temp_c": 44.0}) > 0.5)


## --- air quality -------------------------------------------------------------

func _test_air_quality_parser() -> void:
	# AirQualityService is an autoload with no class_name, so the bare
	# identifier resolves to the singleton NODE, not the class — `.new()` on it
	# is a parse error under --script. Load the script explicitly instead.
	var aq_script: GDScript = load("res://core/weather/air_quality_service.gd")
	_check("aq: script loads", aq_script != null)
	if aq_script == null:
		return
	var svc: Node = aq_script.new()

	# ISO -> absolute hours must agree with the clock the rest of the sim uses,
	# or air-quality samples land at the wrong instant.
	var got: float = aq_script.iso_to_abs_hours("2026-09-12T10:00")
	var want := _abs_for(2026, 9, 12, 10.0)
	_check("aq: iso matches CelestialClock", _approx(got, want, 0.001),
		"%f vs %f" % [got, want])
	_check("aq: iso parses minutes",
		_approx(float(aq_script.iso_to_abs_hours("2026-09-12T10:30")), want + 0.5, 0.001))
	_check("aq: malformed iso -> NAN",
		is_nan(float(aq_script.iso_to_abs_hours("not-a-timestamp"))))
	_check("aq: empty iso -> NAN", is_nan(float(aq_script.iso_to_abs_hours(""))))

	# Before any data, everything is NAN — never 0, which would read as clean.
	_check("aq: no data -> has_data false", not svc.has_data())
	_check("aq: no data -> NAN sample", is_nan(svc.pm25_ugm3(want)))
	_check("aq: no data -> covers_time false", not svc.covers_time(want))

	var ok: bool = svc.parse_air_quality_json(_aq_json(), 45.52, -122.68)
	_check("aq: parses canned JSON", ok)
	_check("aq: has data after parse", svc.has_data())
	_check("aq: window start recorded",
		_approx(svc.window_start_abs(), _abs_for(2026, 9, 12, 0.0), 0.001))

	# Values land on the right hours, and interpolate between them.
	var h0 := _abs_for(2026, 9, 12, 0.0)
	_check("aq: first sample", _approx(svc.pm25_ugm3(h0), 12.0, 0.01),
		"got %f" % svc.pm25_ugm3(h0))
	_check("aq: third sample", _approx(svc.pm25_ugm3(h0 + 2.0), 180.0, 0.01),
		"got %f" % svc.pm25_ugm3(h0 + 2.0))
	_check("aq: interpolates", _approx(svc.pm25_ugm3(h0 + 0.5), 33.0, 0.5),
		"got %f" % svc.pm25_ugm3(h0 + 0.5))
	_check("aq: aod read", _approx(svc.aerosol_optical_depth(h0 + 2.0), 1.9, 0.01))

	# A null hour inside the window degrades to its neighbour rather than
	# propagating NAN — CAMS global is natively 3-hourly, so gaps are normal.
	_check("aq: null hour falls back to a neighbour",
		is_finite(svc.pm25_ugm3(h0 + 3.0)), "got %f" % svc.pm25_ugm3(h0 + 3.0))

	# Out of window is NAN and covers_time is false — the distinction callers
	# rely on to fall back to the alert/climatology layers.
	_check("aq: before window -> NAN", is_nan(svc.pm25_ugm3(h0 - 5.0)))
	_check("aq: after window -> NAN", is_nan(svc.pm25_ugm3(h0 + 5000.0)))
	_check("aq: covers_time inside", svc.covers_time(h0 + 1.0))
	_check("aq: covers_time outside", not svc.covers_time(h0 - 1.0))

	# An all-null column means the model does not carry that field here.
	# Storing it as zeroes would make "unsupported" look like "clean".
	var avail: Array = svc.available_vars()
	_check("aq: real columns kept", avail.has("pm2_5") and avail.has("aerosol_optical_depth"))
	_check("aq: all-null column dropped", not avail.has("carbon_monoxide"),
		"available: %s" % str(avail))
	_check("aq: dropped column samples NAN", is_nan(svc.sample_at_abs("carbon_monoxide", h0)))
	_check("aq: unknown var -> NAN", is_nan(svc.sample_at_abs("nonsense", h0)))

	# Location gating.
	_check("aq: covers its own site", svc.covers(45.52, -122.68))
	_check("aq: rejects a distant site", not svc.covers(40.0, -100.0))

	# THE NEW YEAR BOUNDARY. WeatherService's forecast indexing uses hour-of-year
	# with a "large negative offset means last year" heuristic, which is safe for
	# its ~21-day window but silently fails for this one (up to 99 days): a
	# January request against an October-start window lands near -283 days, not
	# negative enough to trigger the wrap, and reads as out-of-window. Indexing
	# by absolute hours has no such failure mode — this check is the proof.
	var wrap: Node = aq_script.new()
	_check("aq: parses a year-crossing window",
		bool(wrap.parse_air_quality_json(_aq_json_new_year(), 45.52, -122.68)))
	var dec := _abs_for(2025, 12, 31, 22.0)
	var jan := _abs_for(2026, 1, 1, 1.0)
	_check("aq: reads December side", _approx(wrap.pm25_ugm3(dec), 40.0, 0.01),
		"got %f" % wrap.pm25_ugm3(dec))
	_check("aq: reads across midnight into January",
		_approx(wrap.pm25_ugm3(jan), 70.0, 0.01), "got %f" % wrap.pm25_ugm3(jan))
	_check("aq: January is inside the window, not wrapped away",
		wrap.covers_time(jan))
	wrap.free()

	# Garbage in.
	var bad: Node = aq_script.new()
	_check("aq: rejects non-JSON", not bool(bad.parse_air_quality_json("<html>", 0.0, 0.0)))
	_check("aq: rejects empty hourly",
		not bool(bad.parse_air_quality_json('{"hourly":{}}', 0.0, 0.0)))
	_check("aq: rejects missing time array",
		not bool(bad.parse_air_quality_json('{"hourly":{"pm2_5":[1,2]}}', 0.0, 0.0)))
	_check("aq: rejects all-null payload", not bool(bad.parse_air_quality_json(
		'{"hourly":{"time":["2026-09-12T00:00"],"pm2_5":[null]}}', 0.0, 0.0)))
	bad.free()

	svc.free()


## Five hours from a plausible Open-Meteo air-quality response, including one
## null hour and one entirely-null column.
func _aq_json() -> String:
	return JSON.stringify({
		"hourly": {
			"time": ["2026-09-12T00:00", "2026-09-12T01:00", "2026-09-12T02:00",
				"2026-09-12T03:00", "2026-09-12T04:00"],
			"pm2_5": [12.0, 54.0, 180.0, null, 240.0],
			"pm10": [20.0, 70.0, 210.0, null, 280.0],
			"dust": [1.0, 2.0, 3.0, null, 4.0],
			"aerosol_optical_depth": [0.2, 0.9, 1.9, null, 2.4],
			"us_aqi": [51.0, 150.0, 230.0, null, 290.0],
			"carbon_monoxide": [null, null, null, null, null],
		},
	})


## A window that crosses the New Year — the case that breaks hour-of-year
## indexing.
func _aq_json_new_year() -> String:
	return JSON.stringify({
		"hourly": {
			"time": ["2025-12-31T22:00", "2025-12-31T23:00",
				"2026-01-01T00:00", "2026-01-01T01:00"],
			"pm2_5": [40.0, 50.0, 60.0, 70.0],
			"aerosol_optical_depth": [0.4, 0.5, 0.6, 0.7],
		},
	})


## --- fixtures ----------------------------------------------------------------

func _alert(ph: String, name: String, onset: float, expires: float, month: int) -> Dictionary:
	return {
		"id": "%s_%f" % [ph, onset], "event": name, "phenomena": ph,
		"significance": "W", "onset_abs": onset, "expires_abs": expires,
		"month": month,
	}


func _alert_no_month(ph: String, name: String, onset: float, expires: float) -> Dictionary:
	return {
		"id": "%s_%f" % [ph, onset], "event": name, "phenomena": ph,
		"significance": "W", "onset_abs": onset, "expires_abs": expires,
	}


## Absolute hours for a calendar instant, via the same clock the sim uses — so
## the month-derivation check exercises the real conversion rather than a
## reimplementation of it.
func _abs_for(year: int, month: int, day: int, hour: float) -> float:
	var clk := CelestialClock.new()
	clk.year = year
	clk.month = month
	clk.day = day
	clk.day_time = hour
	return clk.get_absolute_hours()



func _smoke_state(sev: float) -> Dictionary:
	var s := HazardState.blank()
	s["id"] = "wildfire_smoke"
	s["label"] = "Wildfire Smoke"
	s["severity"] = sev
	s["source"] = "aq"
	s["aod"] = 1.2 * sev
	s["visibility_m"] = lerpf(20000.0, 800.0, sev)
	s["haze_color"] = Color(0.62, 0.26, 0.10)
	s["haze_strength"] = sev
	s["dni_factor"] = lerpf(1.0, 0.2, sev)
	s["ghi_factor"] = lerpf(1.0, 0.6, sev)
	s["pm25_ugm3"] = 250.0 * sev
	# No particle_kind: wildfire smoke deliberately emits none (see
	# hazard_evaluators.gd) — this fixture mirrors the real profile shape.
	return s


func _dust_state(sev: float) -> Dictionary:
	var s := HazardState.blank()
	s["id"] = "dust_storm"
	s["label"] = "Dust Storm"
	s["severity"] = sev
	s["source"] = "aq"
	s["aod"] = 1.6 * sev
	s["visibility_m"] = lerpf(15000.0, 150.0, sev)
	s["haze_color"] = Color(0.72, 0.50, 0.26)
	s["haze_strength"] = sev
	s["dni_factor"] = lerpf(1.0, 0.1, sev)
	s["ghi_factor"] = lerpf(1.0, 0.5, sev)
	s["particle_kind"] = "dust"
	s["particle_density"] = 0.7 * sev
	return s


func _heat_state(sev: float) -> Dictionary:
	var s := HazardState.blank()
	s["id"] = "heatwave"
	s["label"] = "Heatwave"
	s["severity"] = sev
	s["source"] = "weather"
	s["thermal_stress"] = sev
	return s


func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return _approx(float(a), float(b), 0.0001)
	if a is Color and b is Color:
		return (a as Color).is_equal_approx(b as Color)
	return a == b
