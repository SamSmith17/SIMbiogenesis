extends SceneTree

## Microclimate selftest (offline, deterministic).
##
##   Godot --headless --path . --script core/microclimate/microclimate_selftest.gd
##
## The fixture (testdata/walton_2026-10-02.json) is REAL Open-Meteo data for
## Walton OR, frozen on 2026-10-06, over two nights the user stood in a valley
## fog that settled ~22–23 h and cleared ~10–11 h. Both feeds are pinned:
## ERA5 (archive — the fog shows up as 100 % low cloud at RH 100 %) and HRRR
## (the forecast feed the game read — T/RH never saturated; only its visibility
## and the valley cold-pool correction find the fog).
##
## Carries EXPECTED_CHECKS: a Godot runtime error aborts the enclosing test
## function while the suite still prints PASS.

const FIXTURE := "res://core/microclimate/testdata/walton_2026-10-02.json"
const EXPECTED_CHECKS := 77

var _pass := 0
var _fail := 0
var _fx: Dictionary = {}


func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: %s %s" % [name, detail])


func _initialize() -> void:
	print("== microclimate selftest ==")
	var f := FileAccess.open(FIXTURE, FileAccess.READ)
	if f != null:
		_fx = JSON.parse_string(f.get_as_text())
		f.close()
	_check("fixture loads", _fx is Dictionary and not _fx.is_empty())
	_test_fog_optics()
	_test_dew_point()
	_test_era5_fog()
	_test_hrrr_fog()
	_test_scrub_determinism()
	_test_conditions()
	_test_suggest_rule_generalises()
	_test_nearest_and_pinned()
	_test_blend()
	_test_round_trip()
	_test_corrections()
	_test_hazard_identity()
	var total := _pass + _fail
	_check("check count", total + 1 == EXPECTED_CHECKS,
		"ran %d, expected %d — a test function aborted or the count is stale" % [total + 1, EXPECTED_CHECKS])
	print("microclimate selftest: %d passed, %d failed" % [_pass, _fail])
	print("PASS" if _fail == 0 else "FAIL")
	quit(0 if _fail == 0 else 1)


# --- fixture → rows -----------------------------------------------------------

## Hourly rows for one source, with the sun from SolarPosition at the real UTC
## instant (fixture times are local PDT, UTC−7).
func _rows(src: String) -> Array:
	var h: Dictionary = _fx["sources"][src]["hourly"]
	var times: Array = h["time"]
	var lat := float(_fx["lat"])
	var lon := float(_fx["lon"])
	var off := float(_fx["utc_offset_h"])
	var out: Array = []
	for i in times.size():
		var unix := Time.get_unix_time_from_datetime_string(str(times[i]) + ":00") - off * 3600.0
		var jd := unix / 86400.0 + 2440587.5
		var sp := SolarPosition.get_position(lat, lon, jd)
		var vis_arr: Array = h.get("visibility", [])
		var vis: Variant = vis_arr[i] if i < vis_arr.size() else null
		var t := float(h["temperature_2m"][i])
		var td := float(h["dew_point_2m"][i])
		out.append({
			"time": str(times[i]),
			"t_c": t, "td_c": td, "dep_c": t - td,
			"rh": float(h["relative_humidity_2m"][i]),
			"wind_ms": float(h["wind_speed_10m"][i]) / 3.6,
			"cloud": float(h["cloud_cover"][i]) / 100.0,
			"low": float(h["cloud_cover_low"][i]) / 100.0,
			"vis_m": float(vis) if vis != null else NAN,
			"sun_el": float(sp["elevation_deg"]),
		})
	return out


func _idx(rows: Array, ts: String) -> int:
	for i in rows.size():
		if str(rows[i]["time"]) == ts:
			return i
	return -1


## Local hour (fractional, relative to the evening's midnight) of the first
## hour from `from_ts` on with fog > 0.5, and the first after that without.
func _onset_clear(rows: Array, fog: PackedFloat32Array, from_ts: String) -> Vector2:
	var i0 := _idx(rows, from_ts)
	var onset := -1
	var clear := -1
	for i in range(i0, rows.size()):
		if onset < 0 and fog[i] > 0.5:
			onset = i
		elif onset >= 0 and fog[i] <= 0.5:
			clear = i
			break
	return Vector2(float(onset - i0), float(clear - i0))


# --- tests --------------------------------------------------------------------

func _test_fog_optics() -> void:
	_check("slider 0 = no volumetric fog, exactly", FogOptics.volumetric_density_for_amount(0.0) == 0.0)
	_check("slider NaN = no fog", FogOptics.volumetric_density_for_amount(NAN) == 0.0)
	var prev := 0.0
	var mono := true
	for i in range(1, 21):
		var d := FogOptics.volumetric_density_for_amount(float(i) / 20.0)
		if d <= prev:
			mono = false
		prev = d
	_check("slider density strictly increases", mono)
	_check("slider 1.0 ≈ 40 m visibility",
		absf(FogOptics.visibility_for_amount(1.0) - 40.0) < 0.5, str(FogOptics.visibility_for_amount(1.0)))
	_check("Koschmieder round trip",
		absf(FogOptics.visibility_for_sigma(FogOptics.sigma_for_visibility(250.0)) - 250.0) < 0.01)
	_check("old scene density 0.2546 is ~15 m (why the bug looked so dense)",
		absf(FogOptics.visibility_for_sigma(0.2546) - 15.4) < 0.2)


func _test_dew_point() -> void:
	# Magnus (Alduchov & Eskridge 1996): T 20 °C, RH 50 % → 9.26 °C.
	var td := _magnus(20.0, 50.0)
	_check("Magnus dew point 20 °C / 50 %", absf(td - 9.26) < 0.05, str(td))
	_check("Magnus at saturation = T", absf(_magnus(12.0, 100.0) - 12.0) < 0.01)


## Same formula as WeatherService.dew_point_from_rh — referenced through the
## script so the selftest does not need the autoload instance.
func _magnus(t: float, rh: float) -> float:
	var ws_script: GDScript = load("res://core/weather_service.gd")
	return float(ws_script.call("dew_point_from_rh", t, rh))


func _test_era5_fog() -> void:
	var rows := _rows("era5")
	var fog := FogDiagnosis.series(rows)
	var n1 := _onset_clear(rows, fog, "2026-10-02T18:00")
	var n2 := _onset_clear(rows, fog, "2026-10-03T18:00")
	# Offsets from 18:00 → onset 20–23 h is offset 2..5; clear 09–11 h is 15..17.
	_check("ERA5 night 1 onset 20–23 h", n1.x >= 2 and n1.x <= 5, str(n1))
	_check("ERA5 night 1 clears 09–11 h", n1.y >= 15 and n1.y <= 17, str(n1))
	_check("ERA5 night 2 onset 20–23 h", n2.x >= 2 and n2.x <= 5, str(n2))
	_check("ERA5 night 2 clears 09–11 h", n2.y >= 15 and n2.y <= 17, str(n2))
	_check("ERA5 Oct 3 15 h is clear", fog[_idx(rows, "2026-10-03T15:00")] < 0.05)
	_check("ERA5 Oct 2 15 h is clear", fog[_idx(rows, "2026-10-02T15:00")] < 0.05)
	var inst := FogDiagnosis.instant(rows[_idx(rows, "2026-10-03T02:00")])
	_check("ERA5 02 h fog is GROUND CLOUD (100 % low at RH 100 %)",
		str(inst["source"]) == "ground_cloud", str(inst))
	# The 05 h dip in ERA5 low cloud (35 %) must not punch a hole in the fog.
	_check("ERA5 05 h low-cloud dip held", fog[_idx(rows, "2026-10-03T05:00")] > 0.5)


func _test_hrrr_fog() -> void:
	var rows := _rows("hrrr")
	var raw := FogDiagnosis.series(rows)
	var n1 := _onset_clear(rows, raw, "2026-10-02T18:00")
	# Without the valley correction HRRR only finds it via visibility, hours late.
	_check("HRRR uncorrected onset is late (≥ 01 h)", n1.x >= 7, str(n1))
	_check("HRRR uncorrected still clears ~10–11 h", n1.y >= 16 and n1.y <= 18, str(n1))
	var corr := FogDiagnosis.series(rows, {"cold_pool_bias_c": 2.0})
	var c1 := _onset_clear(rows, corr, "2026-10-02T18:00")
	var c2 := _onset_clear(rows, corr, "2026-10-03T18:00")
	_check("HRRR + 2 °C cold pool: night 1 onset 20–24 h", c1.x >= 2 and c1.x <= 6, str(c1))
	_check("HRRR + 2 °C cold pool: night 2 onset 20–24 h", c2.x >= 2 and c2.x <= 6, str(c2))
	_check("HRRR + cold pool: night 1 clears 10–12 h", c1.y >= 16 and c1.y <= 18, str(c1))
	_check("HRRR + cold pool: night 2 clears 10–12 h", c2.y >= 16 and c2.y <= 18, str(c2))
	_check("HRRR + cold pool: afternoon clear", corr[_idx(rows, "2026-10-03T15:00")] < 0.05)
	# 03 h vis 800 m, 04 h a one-hour 18.9 km glitch, 05 h 500 m: the hole is
	# filled rather than the fog blinking off for an hour.
	_check("HRRR 18.9 km one-hour glitch filled",
		raw[_idx(rows, "2026-10-03T04:00")] >= raw[_idx(rows, "2026-10-03T03:00")] - 1e-6
		and raw[_idx(rows, "2026-10-03T04:00")] > 0.3, str(raw[_idx(rows, "2026-10-03T04:00")]))
	_check("cold-pool bias from TPI −60 m = 1.8 °C",
		absf(FogDiagnosis.cold_pool_bias_for_tpi(-60.0) - 1.8) < 0.001)
	_check("no cold pool on a ridge", FogDiagnosis.cold_pool_bias_for_tpi(40.0) == 0.0)
	_check("cold-pool bias capped at 3 °C", FogDiagnosis.cold_pool_bias_for_tpi(-500.0) == 3.0)


## The resolver evaluates each hour over its own 18 h look-back window. The
## answer must not depend on where the window started — that is what makes a
## backward scrub land on exactly what the forward pass showed.
func _test_scrub_determinism() -> void:
	var rows := _rows("era5")
	var full := FogDiagnosis.series(rows)
	var ok := true
	for ts in ["2026-10-03T02:00", "2026-10-03T09:00", "2026-10-03T10:00", "2026-10-04T07:00"]:
		var i := _idx(rows, ts)
		var win := rows.slice(i - 18, i + 4)
		var w := FogDiagnosis.series(win)
		if absf(w[18] - full[i]) > 1e-6:
			ok = false
			print("    window %s: %f vs %f" % [ts, w[18], full[i]])
	_check("windowed series == full series (scrub determinism)", ok)


func _test_conditions() -> void:
	var c := {"f": "wind_ms", "min": NAN, "max": 2.0, "soft": 1.0}
	_check("cond inside = 1", MicroclimateProfile.cond_weight(c, {"wind_ms": 1.0}) == 1.0)
	_check("cond soft edge = 0.5", absf(MicroclimateProfile.cond_weight(c, {"wind_ms": 2.5}) - 0.5) < 1e-6)
	_check("cond outside = 0", MicroclimateProfile.cond_weight(c, {"wind_ms": 4.0}) == 0.0)
	_check("cond missing feature = 0", MicroclimateProfile.cond_weight(c, {}) == 0.0)
	_check("cond NaN feature = 0", MicroclimateProfile.cond_weight(c, {"wind_ms": NAN}) == 0.0)
	_check("empty cond list matches", MicroclimateProfile.conds_weight([], {}) == 1.0)
	# Hold: fires on a match, persists while hold matches, drops after.
	var rule := {"enabled": true, "strength": 1.0, "max_hold_h": 5,
		"when": [{"f": "x", "min": NAN, "max": 1.0, "soft": 0.0}],
		"hold": [{"f": "y", "min": NAN, "max": 1.0, "soft": 0.0}]}
	var rows := [{"x": 5, "y": 0}, {"x": 0, "y": 0}, {"x": 5, "y": 0}, {"x": 5, "y": 0}, {"x": 5, "y": 5}, {"x": 5, "y": 0}]
	var s := MicroclimateProfile.rule_series(rule, rows)
	_check("rule off before trigger", s[0] == 0.0)
	_check("rule on at trigger", s[1] == 1.0)
	_check("rule held while hold matches", s[2] == 1.0 and s[3] == 1.0)
	_check("rule releases when hold fails", s[4] == 0.0)
	_check("rule does not re-latch after release", s[5] == 0.0)
	rule["enabled"] = false
	_check("disabled rule is silent", MicroclimateProfile.rule_series(rule, rows)[1] == 0.0)


## "Make rule from this moment" on night 1 must fire on night 2 — that is the
## whole point of a rule — and not on the sunny afternoon between.
func _test_suggest_rule_generalises() -> void:
	var rows := _rows("hrrr")
	var stamped: Array = []
	for r in rows:
		var d: Dictionary = r.duplicate()
		d["dep_eff_c"] = FogDiagnosis.dep_eff(r, {"cold_pool_bias_c": 2.0})
		stamped.append(d)
	var seed: Dictionary = stamped[_idx(rows, "2026-10-03T00:00")]
	var rule := MicroclimateProfile.suggest_rule(seed, "valley_fog", "Valley fog")
	_check("suggested rule has conditions", (rule["when"] as Array).size() >= 3)
	var s := MicroclimateProfile.rule_series(rule, stamped)
	_check("suggested rule fires at its own moment", s[_idx(rows, "2026-10-03T00:00")] >= 0.5)
	_check("suggested rule fires next night (00 h)", s[_idx(rows, "2026-10-04T00:00")] >= 0.5,
		str(s[_idx(rows, "2026-10-04T00:00")]))
	_check("suggested rule holds into the morning (08 h)", s[_idx(rows, "2026-10-04T08:00")] >= 0.5,
		str(s[_idx(rows, "2026-10-04T08:00")]))
	_check("suggested rule is off in the afternoon", s[_idx(rows, "2026-10-03T15:00")] < 0.1,
		str(s[_idx(rows, "2026-10-03T15:00")]))


func _test_nearest_and_pinned() -> void:
	var rows := _rows("era5")
	var p := MicroclimateProfile.new()
	var night := rows[_idx(rows, "2026-10-03T03:00")] as Dictionary
	var feat := night.duplicate()
	feat["dep_eff_c"] = feat["dep_c"]
	p.observations.append({"id": "o1", "abs_h": 100.0, "features": feat,
		"look": {"fog_vis_m": 120.0}, "pin": true, "radius_h": 2.0})
	var next: Dictionary = (rows[_idx(rows, "2026-10-04T03:00")] as Dictionary).duplicate()
	next["dep_eff_c"] = next["dep_c"]
	var aft: Dictionary = (rows[_idx(rows, "2026-10-03T15:00")] as Dictionary).duplicate()
	aft["dep_eff_c"] = aft["dep_c"]
	_check("nearest: next night matches", not p.nearest_contributions(next).is_empty())
	_check("nearest: sunny afternoon = no match", p.nearest_contributions(aft).is_empty())
	_check("nearest: <3 shared features is no match",
		MicroclimateProfile.feature_distance({"rh": 99}, {"rh": 99}) == INF)
	_check("pinned: full at its instant", absf(float(p.pinned_contributions(100.0)[0]["w"]) - 1.0) < 1e-6)
	_check("pinned: fades by the radius", p.pinned_contributions(102.5).is_empty())
	_check("pinned: half-way is partial",
		float(p.pinned_contributions(101.5)[0]["w"]) > 0.0 and float(p.pinned_contributions(101.5)[0]["w"]) < 1.0)


func _test_blend() -> void:
	var b := MicroclimateProfile.blend([
		{"look": {"fog_vis_m": 100.0}, "w": 1.0},
		{"look": {"fog_vis_m": 1000.0}, "w": 1.0}])
	_check("blend: worst fog wins", absf(FogOptics.visibility_for_sigma(float(b["fog_sigma"])) - 100.0) < 0.01)
	var c := MicroclimateProfile.blend([{"look": {"cloud_add": 0.4}, "w": 0.5}])
	_check("blend: cloud scales by weight", absf(float(c["cloud_add"]) - 0.2) < 1e-6)
	var e := MicroclimateProfile.blend([])
	_check("blend: empty is the identity",
		float(e["fog_sigma"]) == 0.0 and float(e["light_mult"]) == 1.0 and float(e["wind_vis_mult"]) == 1.0)


func _test_round_trip() -> void:
	var p := MicroclimateProfile.new()
	p.set_look("fog", {"fog_vis_m": 150.0, "fog_color": Color(0.8, 0.82, 0.85), "suppress_auto": false,
		"haze_vis_m": INF})
	p.rules.append({"id": "r1", "look": "fog", "when": [{"f": "wind_ms", "min": NAN, "max": 2.0, "soft": 1.0}]})
	p.observations.append({"id": "o1", "abs_h": 17760000.5, "features": {"rh": 99.0},
		"look": {"fog_vis_m": 90.0}, "pin": true})
	p.corrections.append({"id": "c1", "var": "wind_ms", "mult": 1.5, "add": 0.0, "physics": true})
	p.settings["cold_pool_bias_c"] = 2.0
	var path := "user://microclimate_selftest_tmp.json"
	_check("profile saves", p.save_to(path))
	var q := MicroclimateProfile.load_from(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check("look round-trips", absf(float(q.looks["fog"]["fog_vis_m"]) - 150.0) < 1e-6)
	_check("colour round-trips", (q.looks["fog"]["fog_color"] as Color).is_equal_approx(Color(0.8, 0.82, 0.85)))
	_check("INF visibility survives JSON", is_inf(float(q.looks["fog"]["haze_vis_m"])))
	_check("NaN condition bound survives JSON", not is_finite(float(q.rules[0]["when"][0]["min"] if q.rules[0]["when"][0]["min"] != null else NAN)))
	_check("observation time round-trips", absf(float(q.observations[0]["abs_h"]) - 17760000.5) < 1e-3)
	_check("settings round-trip", absf(float(q.settings["cold_pool_bias_c"]) - 2.0) < 1e-6)
	_check("missing file → empty profile", MicroclimateProfile.load_from("user://does_not_exist_mc.json").is_empty())


func _test_corrections() -> void:
	MicroclimateCorrections.clear()
	_check("no corrections = identity", MicroclimateCorrections.apply("wind_ms", 5.0) == 5.0)
	MicroclimateCorrections.set_physics([
		{"var": "wind_ms", "mult": 1.5, "add": 0.0, "physics": true},
		{"var": "t_c", "mult": 1.0, "add": -2.0, "physics": true,
			"when": [{"f": "wind_ms", "max": 2.0}]},
		{"var": "rh", "mult": 1.0, "add": 5.0, "physics": false}])
	_check("physics wind ×1.5", absf(MicroclimateCorrections.apply("wind_ms", 4.0) - 6.0) < 1e-6)
	_check("conditional physics correction is NOT applied in the accessor",
		MicroclimateCorrections.apply("t_c", 10.0) == 10.0)
	_check("visual-only correction is NOT applied in the accessor",
		MicroclimateCorrections.apply("rh", 50.0) == 50.0)
	_check("NaN stays NaN", is_nan(MicroclimateCorrections.apply("wind_ms", NAN)))
	MicroclimateCorrections.clear()
	var p := MicroclimateProfile.new()
	p.corrections = [{"var": "t_c", "mult": 1.0, "add": -3.0, "physics": false,
		"when": [{"f": "wind_ms", "min": NAN, "max": 2.0, "soft": 0.0}]}]
	var calm := p.apply_corrections({"t_c": 12.0, "td_c": 10.0, "wind_ms": 1.0}, "visual")
	_check("visual cold-pool correction cools a calm night", absf(float(calm["t_c"]) - 9.0) < 1e-6)
	_check("dew point clamped to the corrected T", float(calm["td_c"]) <= float(calm["t_c"]) and float(calm["dep_c"]) == 0.0)
	var windy := p.apply_corrections({"t_c": 12.0, "td_c": 10.0, "wind_ms": 5.0}, "visual")
	_check("…and leaves a windy one alone", float(windy["t_c"]) == 12.0)


func _test_hazard_identity() -> void:
	var blank := MicroclimateResolver.blank_state()
	_check("inactive state → visual hazard is the identity",
		MicroclimateResolver.visual_hazard(blank) == HazardState.blank())
	_check("inactive state → physics hazard is the identity",
		MicroclimateResolver.physics_hazard(blank) == HazardState.blank())
	var fog := blank.duplicate()
	fog["active"] = true
	fog["fog_sigma"] = FogOptics.sigma_for_visibility(100.0)
	fog["fog_depth_m"] = 60.0
	_check("ground fog without the physics flag never touches energy",
		MicroclimateResolver.physics_hazard(fog) == HazardState.blank())
	fog["physics"] = true
	var ph := MicroclimateResolver.physics_hazard(fog)
	# τ = σ·Δz = (3.912/100)·60 = 2.35
	_check("physics fog → AOD = σ·depth", absf(float(ph["aod"]) - 2.347) < 0.01, str(ph["aod"]))
	var dust := blank.duplicate()
	dust["active"] = true
	dust["dust"] = 0.7
	var vh := MicroclimateResolver.visual_hazard(dust)
	_check("dust look drives the dust particles", str(vh["particle_kind"]) == "dust"
		and DustSmokeVfx.dust_intensity_t(float(vh["severity"]), float(vh["wind_mult"])) > 0.2)
