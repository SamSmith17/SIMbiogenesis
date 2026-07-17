extends SceneTree

## Headless self-test for the Site Report math (SiteReportMetrics + SiteReportData
## round-trip). Pure / offline — no network, no scene.
## Run with:
##   godot --headless --path . --script core/report/site_report_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_calendar()
	_test_abs_hours_matches_clock()
	_test_month_day_from_doy()
	_test_monthly_aggregation()
	_test_wet_days()
	_test_windrose()
	_test_derived_scalars()
	_test_data_round_trip()
	_test_ui_scripts_compile()
	if _failures == 0:
		print("SITE REPORT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SITE REPORT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _test_calendar() -> void:
	_check("leap 2024", SiteReportMetrics.is_leap_year(2024))
	_check("non-leap 2025", not SiteReportMetrics.is_leap_year(2025))
	_check("non-leap 1900", not SiteReportMetrics.is_leap_year(1900))
	_check("leap 2000", SiteReportMetrics.is_leap_year(2000))
	_check("feb non-leap 28", SiteReportMetrics.days_in_month(2, 2025) == 28)
	_check("feb leap 29", SiteReportMetrics.days_in_month(2, 2024) == 29)
	_check("doy jan1", SiteReportMetrics.day_of_year(2025, 1, 1) == 1)
	_check("doy dec31 non-leap", SiteReportMetrics.day_of_year(2025, 12, 31) == 365)
	_check("doy dec31 leap", SiteReportMetrics.day_of_year(2024, 12, 31) == 366)


func _test_abs_hours_matches_clock() -> void:
	# SiteReportMetrics.date_to_abs_hours must agree with CelestialClock's epoch.
	var clock := CelestialClock.new()
	var cases := [
		[2025, 1, 1, 0.0],
		[2025, 7, 15, 13.5],
		[2024, 2, 29, 6.25],
		[1999, 12, 31, 23.0],
	]
	for c in cases:
		clock.year = int(c[0])
		clock.month = int(c[1])
		clock.day = int(c[2])
		clock.day_time = float(c[3])
		var expected := clock.get_absolute_hours()
		var got := SiteReportMetrics.date_to_abs_hours(int(c[0]), int(c[1]), int(c[2]), float(c[3]))
		_check("abs_hours %d-%02d-%02d" % [c[0], c[1], c[2]],
			_approx(got, expected, 1e-3), "got %f want %f" % [got, expected])
	# And the round-trip back through the clock lands on the same date.
	var abs_h := SiteReportMetrics.date_to_abs_hours(2025, 7, 15, 13.5)
	var back := clock.abs_hours_to_date(abs_h)
	_check("abs round-trip month", int(back.get("month", 0)) == 7)
	_check("abs round-trip day", int(back.get("day", 0)) == 15)
	_check("abs round-trip tod", _approx(float(back.get("day_time", 0.0)), 13.5, 1e-3))


func _test_month_day_from_doy() -> void:
	_check("doy0 -> Jan1", SiteReportMetrics.month_day_from_doy(0) == Vector2i(1, 1))
	_check("doy31 -> Feb1", SiteReportMetrics.month_day_from_doy(31) == Vector2i(2, 1))
	_check("doy59 -> Mar1", SiteReportMetrics.month_day_from_doy(59) == Vector2i(3, 1))
	_check("doy364 -> Dec31", SiteReportMetrics.month_day_from_doy(364) == Vector2i(12, 31))


func _test_monthly_aggregation() -> void:
	var ones := PackedFloat32Array()
	ones.resize(SiteReportMetrics.HOURS_PER_YEAR)
	ones.fill(1.0)
	var msum := SiteReportMetrics.monthly_sum(ones)
	_check("jan sum 744", _approx(msum[0], 744.0, 0.001), "got %f" % msum[0])   # 31*24
	_check("apr sum 720", _approx(msum[3], 720.0, 0.001), "got %f" % msum[3])   # 30*24
	_check("annual sum 8760", _approx(SiteReportMetrics.annual_sum(ones), 8760.0, 0.01))

	var twos := PackedFloat32Array()
	twos.resize(SiteReportMetrics.HOURS_PER_YEAR)
	twos.fill(2.0)
	var mmean := SiteReportMetrics.monthly_mean(twos)
	_check("mean = 2", _approx(mmean[5], 2.0, 0.001), "got %f" % mmean[5])
	_check("annual mean = 2", _approx(SiteReportMetrics.annual_mean(twos), 2.0, 0.001))


func _test_wet_days() -> void:
	# 0.2 mm at hour 0 of every January day -> 31 wet days in Jan, 0 elsewhere.
	var precip := PackedFloat32Array()
	precip.resize(SiteReportMetrics.HOURS_PER_YEAR)
	precip.fill(0.0)
	for d in range(31):
		precip[d * 24] = 0.2
	var wet := SiteReportMetrics.monthly_wet_days(precip)
	_check("jan wet 31", wet[0] == 31, "got %d" % wet[0])
	_check("feb wet 0", wet[1] == 0, "got %d" % wet[1])
	# Below-threshold trace (0.05 mm) does not count.
	var trace := PackedFloat32Array()
	trace.resize(SiteReportMetrics.HOURS_PER_YEAR)
	trace.fill(0.0)
	trace[0] = 0.05
	var wet2 := SiteReportMetrics.monthly_wet_days(trace)
	_check("trace not wet", wet2[0] == 0, "got %d" % wet2[0])


func _test_windrose() -> void:
	_check("sector N (0deg)", SiteReportMetrics.windrose_sector_index(0.0, 16) == 0)
	_check("sector E (90deg)", SiteReportMetrics.windrose_sector_index(90.0, 16) == 4)
	_check("sector S (180deg)", SiteReportMetrics.windrose_sector_index(180.0, 16) == 8)
	_check("sector W (270deg)", SiteReportMetrics.windrose_sector_index(270.0, 16) == 12)
	_check("sector NE (45deg)", SiteReportMetrics.windrose_sector_index(45.0, 16) == 2)
	_check("sector wrap 350->N", SiteReportMetrics.windrose_sector_index(350.0, 16) == 0)
	_check("sector 8 E", SiteReportMetrics.windrose_sector_index(90.0, 8) == 2)
	var labels := SiteReportMetrics.sector_labels(16)
	_check("label[0] N", labels[0] == "N")
	_check("label[4] E", labels[4] == "E")
	_check("label[8] S", labels[8] == "S")
	_check("label[12] W", labels[12] == "W")


func _test_derived_scalars() -> void:
	_check("cap factor full", _approx(SiteReportMetrics.capacity_factor(8760.0, 1.0), 1.0, 1e-4))
	_check("cap factor quarter", _approx(SiteReportMetrics.capacity_factor(2190.0, 1.0), 0.25, 1e-4))
	_check("cap factor zero peak", SiteReportMetrics.capacity_factor(100.0, 0.0) == 0.0)
	_check("psh", _approx(SiteReportMetrics.peak_sun_hours(1825.0), 5.0, 1e-4))


func _test_data_round_trip() -> void:
	var d := SiteReportData.new()
	d.site_label = "Test Site"
	d.latitude = 33.3561
	d.longitude = -115.7366
	d.year = 2025
	d.pv_peak_kw = 3.96
	d.pv_annual_kwh = 6543.2
	d.pv_capacity_factor = 0.19
	d.solar_annual_kwh_m2 = 2100.0
	d.wind_turbine_count = 2
	d.precip_annual_mm = 88.0
	for i in range(12):
		d.pv_monthly_kwh[i] = float(i) * 10.0
		d.precip_wet_days[i] = i
	d.windrose_freq[3] = 0.25
	var round := SiteReportData.from_dict(d.to_dict())
	_check("rt label", round.site_label == "Test Site")
	_check("rt lat", _approx(round.latitude, 33.3561, 1e-4))
	_check("rt year", round.year == 2025)
	_check("rt pv annual", _approx(round.pv_annual_kwh, 6543.2, 0.1))
	_check("rt pv monthly", _approx(round.pv_monthly_kwh[5], 50.0, 1e-3))
	_check("rt wet days", round.precip_wet_days[7] == 7)
	_check("rt windrose", _approx(round.windrose_freq[3], 0.25, 1e-4))
	_check("rt turbine count", round.wind_turbine_count == 2)


## Force-compile the lazily-loaded UI scripts (no class_name → not parsed at
## import) so GDScript errors surface offline instead of only when opened.
func _test_ui_scripts_compile() -> void:
	var panel_script: Script = load("res://scenes/ui/site_report_panel.gd")
	_check("panel script loads", panel_script != null)
	if panel_script != null:
		var inst := Control.new()
		inst.set_script(panel_script)
		_check("panel can_instantiate", panel_script.can_instantiate())
		_check("panel has toggle", inst.has_method("toggle"))
		_check("panel has bind_timeline", inst.has_method("bind_timeline"))
		_check("panel has open", inst.has_method("open"))
		inst.free()
	var charts_script: Script = load("res://scenes/ui/site_report_charts.gd")
	_check("charts script loads", charts_script != null)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _approx(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps
