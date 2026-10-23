extends SceneTree

## Headless self-test for the experiment substrate (core/experiment/): the
## one Unix <-> site-clock conversion (SiteTime), observed readings onto the
## grid (ExperimentObserved: held states, time-weighted flows, sums, gaps),
## the isolated energy run (ExperimentEnergyRun: same battery as SolarUI,
## the AC hysteresis, the battery-full curtailment, determinism), the scores
## (ExperimentScore.energy and .calibration incl. the ASHRAE Guideline 14
## statistics, pinned by hand) and HaHistoryFetch's link resolution + units.
## Run (--import first so the class_names register):
##   Godot.exe.exe --headless --path . --script core/experiment/experiment_selftest.gd
##
## Carries EXPECTED_CHECKS: a Godot runtime error aborts the enclosing test
## function while the suite still prints PASS.

const EXPECTED_CHECKS := 55

var _checks := 0
var _failures := 0


class FakeLinker:
	extends RefCounted
	var _links: Array = []
	var _targets: Dictionary = {}
	func links() -> Array:
		return _links
	func target(tid: String) -> Dictionary:
		return _targets.get(tid, {})


func _initialize() -> void:
	_test_site_time()
	_test_observed()
	_test_energy_run()
	_test_scores()
	_test_sources()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: check count %d != EXPECTED_CHECKS %d (a runtime error aborted a test?)" % [
			_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("EXPERIMENT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("EXPERIMENT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


## A clock at Mount Vernon (zone meridian -120°: UTC-8, UTC-7 in DST).
func _clock() -> CelestialClock:
	var c := CelestialClock.new()
	c.longitude = -122.3
	c.latitude = 48.4
	return c


func _abs(c: CelestialClock, y: int, m: int, d: int, h: float) -> float:
	var k := CelestialClock.new()
	k.year = y
	k.month = m
	k.day = d
	k.day_time = h
	return k.get_absolute_hours()


func _test_site_time() -> void:
	var c := _clock()
	# 2026-07-15 19:00:00 UTC = 12:00 PDT; 2026-01-15 20:00:00 UTC = 12:00 PST.
	var summer := 1784142000.0
	var winter := 1768507200.0
	var a_s := SiteTime.unix_to_site_abs(c, summer)
	var a_w := SiteTime.unix_to_site_abs(c, winter)
	_check("site time: summer noon PDT", _near(a_s, _abs(c, 2026, 7, 15, 12.0), 1e-6),
		"%f vs %f" % [a_s, _abs(c, 2026, 7, 15, 12.0)])
	_check("site time: winter noon PST", _near(a_w, _abs(c, 2026, 1, 15, 12.0), 1e-6))
	_check("site time: round trip summer", _near(SiteTime.site_abs_to_unix(c, a_s), summer, 0.01))
	_check("site time: round trip winter", _near(SiteTime.site_abs_to_unix(c, a_w), winter, 0.01))
	_check("site time: fractional seconds kept",
		_near(SiteTime.unix_to_site_abs(c, summer + 1800.0) - a_s, 0.5, 1e-6))
	_check("site time: format", SiteTime.format_abs(c, a_s) == "2026-07-15 12:00",
		SiteTime.format_abs(c, a_s))


func _test_observed() -> void:
	var c := _clock()
	var t0 := 1784142000.0          # 12:00 local
	var a0 := SiteTime.unix_to_site_abs(c, t0)
	# Solar: 2 kW from 12:00, 4 kW from 12:30 → the 12:00–13:00 hour means 3.
	var solar := [[t0, 2.0], [t0 + 1800.0, 4.0]]
	# SOC: 50 % at 11:50, 60 % at 12:40 → held at each sample's START.
	var soc := [[t0 - 600.0, 50.0], [t0 + 2400.0, 60.0]]
	# Load from two sensors, the second starting late (unknown before 13:00).
	var load_a := [[t0, 1.0]]
	var load_b := [[t0 + 3600.0, 0.5]]
	var s := ExperimentObserved.build({"solar_kw": [solar], "soc_kwh": [soc],
		"load_kw": [load_a, load_b]}, c, a0, a0 + 3.0, 1.0, 10.0)
	_check("observed: grid size", s.size() == 3)
	_check("observed: flow is the time-weighted mean", _near(s.value("solar_kw", 0), 3.0, 1e-5),
		str(s.value("solar_kw", 0)))
	_check("observed: flow held after the last reading", _near(s.value("solar_kw", 2), 4.0, 1e-5))
	_check("observed: state held at the sample start", _near(s.value("soc_pct", 0), 50.0, 1e-4)
		and _near(s.value("soc_pct", 1), 60.0, 1e-4))
	_check("observed: % → kWh on the capacity", _near(s.value("soc_kwh", 0), 5.0, 1e-5))
	_check("observed: a sum is unknown while one stream is", is_nan(s.value("load_kw", 0)))
	_check("observed: the sum once both are known", _near(s.value("load_kw", 1), 1.5, 1e-5))
	_check("observed: coverage", _near(s.coverage("load_kw"), 2.0 / 3.0, 1e-5))
	_check("observed: integrate skips unknown", _near(s.integrate("load_kw"), 3.0, 1e-5))
	# Before the first reading: unknown; less than half an interval known → unknown.
	var late := ExperimentObserved.build({"solar_kw": [[[t0 + 2400.0, 1.0]]]}, c, a0, a0 + 2.0, 1.0, 10.0)
	_check("observed: <50 % of the interval known → unknown", is_nan(late.value("solar_kw", 0)))
	var gap := ExperimentObserved.build({"solar_kw": [[[t0, 1.0], [t0 + 600.0, NAN], [t0 + 7200.0, 2.0]]]},
		c, a0, a0 + 3.0, 1.0, 10.0)
	_check("observed: unavailable readings make a gap", is_nan(gap.value("solar_kw", 1))
		and _near(gap.value("solar_kw", 2), 2.0, 1e-5))
	# CSV roles: W → kW, unix → site clock.
	var csv := ExperimentObserved.from_csv_roles({"solar": [{"t": int(t0), "v": 1500.0}]}, c,
		a0, a0 + 1.0, 0.25, 10.0, true)
	_check("observed: CSV watts → kW on the site clock", _near(csv.value("solar_kw", 0), 1.5, 1e-5))


func _run(inputs: Callable, hours: float, step: float, cap: float, soc0: float) -> ExperimentEnergyRun:
	var r := ExperimentEnergyRun.new()
	r.floor_pct = 10.0
	r.resume_pct = 20.0
	r.configure(1000.0, 1000.0 + hours, step, cap, soc0, inputs)
	while not r.step_chunk(7):
		pass
	return r


func _test_energy_run() -> void:
	# Night: 1 kW load from 50 % of 10 kWh → the same SOC as step_soc.
	var night := func(_t: float) -> Dictionary: return {"solar_kw": 0.0, "aux_kw": 0.0, "load_kw": 1.0}
	var r := _run(night, 2.0, 0.25, 10.0, 5.0)
	var soc := 5.0
	for k in 8:
		soc = EnergyTimeline.step_soc(soc, 0.0, 0.0, 1.0, 0.25, 10.0, 0.95, 0.95, 1.0)
	_check("run: same battery as SolarUI", _near(r.end_soc_kwh(), soc, 1e-5), "%f vs %f" % [r.end_soc_kwh(), soc])
	_check("run: sample holds the state at its start", _near(r.series.value("soc_kwh", 0), 5.0, 1e-6))
	# Hysteresis: drained to the floor → AC off → back on at the resume %.
	var phase := func(t: float) -> Dictionary:
		var day := t >= 1004.0
		return {"solar_kw": 3.0 if day else 0.0, "aux_kw": 0.0, "load_kw": 2.0}
	var h := _run(phase, 8.0, 0.25, 10.0, 2.0)
	var off_seen := false
	var back_on := false
	var shed_serves := 0.0
	for i in h.series.size():
		if h.series.value("ac", i) < 0.5:
			off_seen = true
			shed_serves += h.series.value("load_kw", i)
		elif off_seen:
			back_on = true
	_check("run: shed load serves nothing", off_seen and shed_serves == 0.0)
	_check("run: AC shed at the floor", off_seen)
	_check("run: AC back after the resume %", back_on)
	var e := ExperimentScore.energy(h.series)
	_check("run: unserved demand counted while shed", float(e["unserved_kwh"]) > 0.5)
	_check("run: AC-off hours counted", float(e["ac_off_h"]) > 0.25)
	# Full battery curtails the array to the load + headroom.
	var sunny := func(_t: float) -> Dictionary: return {"solar_kw": 5.0, "aux_kw": 0.0, "load_kw": 1.0}
	var f := _run(sunny, 2.0, 0.25, 10.0, 10.0)
	_check("run: a full battery curtails solar to the load", _near(f.series.value("solar_kw", 3), 1.0, 1e-5),
		str(f.series.value("solar_kw", 3)))
	_check("run: raw keeps what the array could make", _near(f.series.value("raw_kw", 3), 5.0, 1e-5))
	_check("run: curtailed energy reported", _near(float(ExperimentScore.energy(f.series)["curtailed_kwh"]), 8.0, 1e-4))
	# Determinism: two runs, identical series.
	var wave := func(t: float) -> Dictionary:
		return {"solar_kw": maxf(0.0, 3.0 * sin((t - 1000.0) * PI / 12.0)), "aux_kw": 0.2, "load_kw": 1.2}
	var a := _run(wave, 48.0, 1.0 / 12.0, 12.0, 6.0)
	var b := _run(wave, 48.0, 1.0 / 12.0, 12.0, 6.0)
	_check("run: deterministic", a.series.values("soc_kwh") == b.series.values("soc_kwh")
		and a.series.values("solar_kw") == b.series.values("solar_kw"))
	_check("run: chunking does not matter", _near(a.end_soc_kwh(), _single_chunk(wave, 48.0, 1.0 / 12.0, 12.0, 6.0), 1e-6))


func _single_chunk(inputs: Callable, hours: float, step: float, cap: float, soc0: float) -> float:
	var r := ExperimentEnergyRun.new()
	r.configure(1000.0, 1000.0 + hours, step, cap, soc0, inputs)
	r.step_chunk(1000000)
	return r.end_soc_kwh()


func _series(vals: Array, step: float) -> ExperimentSeries:
	var s := ExperimentSeries.new()
	s.setup(1000.0, step, vals.size(), ["solar_kw", "load_kw", "soc_kwh"])
	s.capacity_kwh = 10.0
	for i in vals.size():
		s.put("solar_kw", i, float(vals[i]))
		s.put("load_kw", i, 1.0)
		s.put("soc_kwh", i, 5.0)
	return s


func _test_scores() -> void:
	# 48 hourly values of a daily shape.
	var obs_v: Array = []
	for i in 48:
		obs_v.append(maxf(0.0, 4.0 * sin(float(i % 24 - 6) * PI / 12.0)) + 0.5)
	var obs := _series(obs_v, 1.0)
	var same := ExperimentScore.calibration(obs, _series(obs_v, 1.0))
	var st: Dictionary = same["channels"]["solar_kw"]
	_check("calibration: identical → zero error", _near(float(st["mae"]), 0.0, 1e-6)
		and _near(float(st["nmbe_pct"]), 0.0, 1e-6) and _near(float(st["cvrmse_pct"]), 0.0, 1e-6))
	_check("calibration: identical → r = 1", _near(float(st["r"]), 1.0, 1e-5))
	_check("calibration: identical → good", str(st["verdict"]) == "good" and str(same["overall"]) == "good")
	# Sim 5 % high everywhere: NMBE by hand = Σ(y − 1.05y) / ((n−1)·ȳ) = −0.05·n/(n−1).
	var hi: Array = []
	for v in obs_v:
		hi.append(float(v) * 1.05)
	var c5 := ExperimentScore.calibration(obs, _series(hi, 1.0))
	var s5: Dictionary = c5["channels"]["solar_kw"]
	_check("calibration: NMBE by hand", _near(float(s5["nmbe_pct"]), -5.0 * 48.0 / 47.0, 1e-3),
		str(s5["nmbe_pct"]))
	_check("calibration: kWh error +5 %", _near(float(s5["kwh_err_pct"]), 5.0, 1e-3))
	_check("calibration: bias = sim − obs", float(s5["bias"]) > 0.0)
	_check("calibration: 5 % high is good", str(s5["verdict"]) == "good")
	# Sim shifted by 3 hours: the totals agree, the hours do not → CV(RMSE) poor.
	var shifted: Array = []
	for i in 48:
		shifted.append(obs_v[(i + 45) % 48])
	var cs := ExperimentScore.calibration(obs, _series(shifted, 1.0))
	var ss: Dictionary = cs["channels"]["solar_kw"]
	_check("calibration: a time shift keeps NMBE small", absf(float(ss["nmbe_pct"])) < 10.0)
	_check("calibration: a time shift fails CV(RMSE)", float(ss["cvrmse_pct"]) > 30.0 and str(ss["verdict"]) != "good")
	_check("calibration: per-day rows", (cs["days"] as Array).size() >= 2)
	# SOC judged in points.
	var soc_obs := _series(obs_v, 1.0)
	var soc_sim := _series(obs_v, 1.0)
	for i in soc_sim.size():
		soc_sim.put("soc_kwh", i, 5.8)      # 8 points high
	var csoc := ExperimentScore.calibration(soc_obs, soc_sim)
	_check("calibration: SOC error in points", _near(float(csoc["channels"]["soc_pct"]["mae"]), 8.0, 1e-4))
	_check("calibration: SOC 8 pts off is fair", str(csoc["channels"]["soc_pct"]["verdict"]) == "fair")
	_check("calibration: overall = worst primary", str(csoc["overall"]) == "fair")
	# Energy summary.
	var en := ExperimentScore.energy(obs)
	var sum := 0.0
	for v in obs_v:
		sum += float(v)
	_check("energy: solar kWh", _near(float(en["solar_kwh"]), sum, 1e-3))
	_check("energy: two day rows", (en["days"] as Array).size() == 2 or (en["days"] as Array).size() == 3)


func _test_sources() -> void:
	var lk := FakeLinker.new()
	lk._links = [
		{"entity_id": "sensor.soc", "target_id": "item.b1.soc", "enabled": true},
		{"entity_id": "sensor.pv1", "target_id": "item.p1.power", "enabled": true},
		{"entity_id": "sensor.pv2", "target_id": "item.p2.power", "enabled": true},
		{"entity_id": "sensor.load", "target_id": "site.load_kw", "enabled": true, "scale": 2.0},
		{"entity_id": "sensor.ac", "target_id": "item.c1.ac_power", "enabled": true},
		{"entity_id": "sensor.off", "target_id": "item.h1.power", "enabled": false},
	]
	lk._targets = {
		"item.b1.soc": {"unit": "%", "item_type": "battery", "field": "soc"},
		"item.p1.power": {"unit": "W", "item_type": "panel", "field": "power"},
		"item.p2.power": {"unit": "W", "item_type": "panel", "field": "power"},
		"site.load_kw": {"unit": "kW", "item_type": "", "field": "load_kw"},
		"item.c1.ac_power": {"unit": "W", "item_type": "controller", "field": "ac_power"},
		"item.h1.power": {"unit": "W", "item_type": "hydro", "field": "power"},
	}
	var src := HaHistoryFetch.sources_for(lk)
	_check("sources: battery from the battery node", (src["soc_kwh"] as Array).size() == 1
		and str(src["soc_kwh"][0]["entity_id"]) == "sensor.soc")
	_check("sources: solar sums the panels", (src["solar_kw"] as Array).size() == 2)
	_check("sources: a site link beats the inverter link", (src["load_kw"] as Array).size() == 1
		and str(src["load_kw"][0]["entity_id"]) == "sensor.load")
	_check("sources: disabled links ignored", (src["aux_kw"] as Array).is_empty())
	_check("sources: nothing missing", (src["_missing"] as Dictionary).is_empty())
	_check("sources: W reading → kW", _near(HaHistoryFetch._convert("1500", "W", src["solar_kw"][0]), 1.5, 1e-6))
	_check("sources: kW sensor into a W target → kW", _near(HaHistoryFetch._convert("1.2", "kW", src["solar_kw"][0]), 1.2, 1e-6))
	_check("sources: link scale applied", _near(HaHistoryFetch._convert("1.5", "kW", src["load_kw"][0]), 3.0, 1e-6))
	_check("sources: unavailable → NAN", is_nan(HaHistoryFetch._convert("unavailable", "W", src["solar_kw"][0])))
	var none := HaHistoryFetch.sources_for(FakeLinker.new())
	_check("sources: missing links named", (none["_missing"] as Dictionary).has("soc_kwh")
		and (none["_missing"] as Dictionary).has("load_kw"))
