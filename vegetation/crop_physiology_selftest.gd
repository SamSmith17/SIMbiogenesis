extends SceneTree

## Offline selftest for CropPhysiology (vegetation/crop_physiology.gd): every
## GardenCrops id has a row, the factors stay in [0, 1], the temperature
## curve is 0 at base and max and 1 on the plateau, the thermal-time column
## matches the GardenCrops cycle at 20 deg C, a hand-computed tomato day, and
## determinism. Carries EXPECTED_CHECKS (a runtime error aborts a test
## function while the suite would still print PASS).
##
## Run: Godot.exe.exe --headless --path . --script vegetation/crop_physiology_selftest.gd

const EXPECTED_CHECKS := 31

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_coverage()
	_test_factor_ranges()
	_test_temp_curve()
	_test_thermal_time()
	_test_tomato_by_hand()
	_test_other_functions()
	_test_determinism()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a runtime error aborted a test?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("CROP PHYSIOLOGY SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("CROP PHYSIOLOGY SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


const FIELDS := ["base", "opt_low", "opt_high", "max", "frost_kill", "lue", "hi",
	"dli_target", "dli_min", "kc", "vpd_lo", "vpd_hi", "yield", "dm", "tt", "est"]


func _test_coverage() -> void:
	var missing: Array = []
	for id in GardenCrops.CROPS.keys():
		if not CropPhysiology.has(str(id)):
			missing.append(id)
	_check("every GardenCrops id has a row", missing.is_empty(), str(missing))
	var extra: Array = []
	for id in CropPhysiology.ids():
		if not GardenCrops.CROPS.has(id):
			extra.append(id)
	_check("no row for a crop GardenCrops lacks", extra.is_empty(), str(extra))
	var bad: Array = []
	for id in CropPhysiology.ids():
		var r: Dictionary = CropPhysiology.info(id)
		for f in FIELDS:
			if not r.has(f):
				bad.append("%s.%s" % [id, f])
	_check("every row has every column", bad.is_empty(), str(bad))
	var order: Array = []
	for id in CropPhysiology.ids():
		var r: Dictionary = CropPhysiology.info(id)
		var ok: bool = float(r["base"]) < float(r["opt_low"]) \
				and float(r["opt_low"]) <= float(r["opt_high"]) \
				and float(r["opt_high"]) < float(r["max"]) \
				and float(r["frost_kill"]) < float(r["base"]) \
				and float(r["dli_min"]) < float(r["dli_target"]) \
				and float(r["vpd_lo"]) < float(r["vpd_hi"]) \
				and float(r["hi"]) > 0.0 and float(r["hi"]) <= 1.0 \
				and float(r["dm"]) > 0.0 and float(r["dm"]) < 1.0 \
				and float(r["lue"]) > 0.5 and float(r["lue"]) < 5.0
		if not ok:
			order.append(id)
	_check("cardinal order and plausible ranges", order.is_empty(), str(order))
	var unknown: Dictionary = CropPhysiology.info("no_such_crop")
	_check("unknown id falls back to the generic leafy crop",
			unknown == CropPhysiology.CROPS[CropPhysiology.GENERIC_ID])


func _test_factor_ranges() -> void:
	var bad_t: Array = []
	var bad_v: Array = []
	var bad_l: Array = []
	var bad_f: Array = []
	for id in CropPhysiology.ids():
		for i in 121:
			var t := -30.0 + float(i) * 0.6
			var f := CropPhysiology.temp_factor(id, t)
			if f < 0.0 or f > 1.0 or is_nan(f):
				bad_t.append("%s@%.1f=%f" % [id, t, f])
			var d := CropPhysiology.frost_damage(id, t)
			if d < 0.0 or d > 1.0:
				bad_f.append("%s@%.1f" % [id, t])
		for i in 61:
			var v := float(i) * 0.1
			var f := CropPhysiology.vpd_factor(id, v)
			if f < 0.0 or f > 1.0:
				bad_v.append("%s@%.1f" % [id, v])
		for i in 81:
			var dli := float(i) * 0.75
			var f := CropPhysiology.light_factor(id, dli)
			if f < 0.0 or f > 1.0:
				bad_l.append("%s@%.1f" % [id, dli])
	_check("temp_factor in [0, 1]", bad_t.is_empty(), str(bad_t.slice(0, 5)))
	_check("vpd_factor in [0, 1]", bad_v.is_empty(), str(bad_v.slice(0, 5)))
	_check("light_factor in [0, 1]", bad_l.is_empty(), str(bad_l.slice(0, 5)))
	_check("frost_damage in [0, 1]", bad_f.is_empty(), str(bad_f.slice(0, 5)))
	var vpd_ok: Array = []
	var light_sat: Array = []
	for id in CropPhysiology.ids():
		var r: Dictionary = CropPhysiology.info(id)
		var mid := (float(r["vpd_lo"]) + float(r["vpd_hi"])) * 0.5
		if not _near(CropPhysiology.vpd_factor(id, mid), 1.0, 1e-6):
			vpd_ok.append(id)
		var tgt := float(r["dli_target"])
		if not _near(CropPhysiology.light_factor(id, tgt), 1.0, 1e-6) \
				or CropPhysiology.light_factor(id, tgt * 0.5) >= 1.0:
			light_sat.append(id)
	_check("vpd_factor is 1 inside the band", vpd_ok.is_empty(), str(vpd_ok))
	_check("light_factor reaches 1 at the target and is below it under", light_sat.is_empty(),
			str(light_sat))


func _test_temp_curve() -> void:
	var at_base: Array = []
	var below: Array = []
	var at_max: Array = []
	var plateau: Array = []
	var cont: Array = []
	for id in CropPhysiology.ids():
		var r: Dictionary = CropPhysiology.info(id)
		var base := float(r["base"])
		var lo := float(r["opt_low"])
		var hi := float(r["opt_high"])
		var mx := float(r["max"])
		if CropPhysiology.temp_factor(id, base) != 0.0:
			at_base.append(id)
		if CropPhysiology.temp_factor(id, base - 5.0) != 0.0:
			below.append(id)
		if CropPhysiology.temp_factor(id, mx) != 0.0 or CropPhysiology.temp_factor(id, mx + 3.0) != 0.0:
			at_max.append(id)
		for k in 5:
			var t := lerpf(lo, hi, float(k) / 4.0)
			if not _near(CropPhysiology.temp_factor(id, t), 1.0, 1e-9):
				plateau.append("%s@%.2f" % [id, t])
				break
		# Continuous at both plateau edges.
		if absf(CropPhysiology.temp_factor(id, lo - 0.01) - 1.0) > 0.01 \
				or absf(CropPhysiology.temp_factor(id, hi + 0.01) - 1.0) > 0.01:
			cont.append(id)
	_check("temp_factor 0 at base", at_base.is_empty(), str(at_base))
	_check("temp_factor 0 below base", below.is_empty(), str(below))
	_check("temp_factor 0 at and above max", at_max.is_empty(), str(at_max))
	_check("temp_factor 1 on the opt_low..opt_high plateau", plateau.is_empty(), str(plateau))
	_check("temp_factor continuous at the plateau edges", cont.is_empty(), str(cont))
	# Rises monotonically from base to opt_low (tomato).
	var prev := -1.0
	var mono := true
	for i in 23:
		var f := CropPhysiology.temp_factor("tomato", 10.0 + float(i) * 0.5)
		if f < prev - 1e-9:
			mono = false
		prev = f
	_check("tomato temp_factor rises from base to opt_low", mono)


func _test_thermal_time() -> void:
	var bad: Array = []
	for id in GardenCrops.CROPS.keys():
		var cycle := float((GardenCrops.CROPS[id] as Dictionary)["cycle"])
		var accum := 0.0
		for d in int(cycle):
			accum += CropPhysiology.thermal_time_rate(str(id), CropPhysiology.REF_TEMP_C)
		var tt := CropPhysiology.maturity_tt(str(id))
		if absf(accum - tt) > 0.01 * tt:
			bad.append("%s: %.0f vs %.0f" % [id, accum, tt])
	_check("cycle days at 20 C reach the maturity thermal time", bad.is_empty(), str(bad))
	_check("thermal_time_rate tomato 15 C = 5", _near(CropPhysiology.thermal_time_rate("tomato", 15.0), 5.0, 1e-9))
	_check("thermal_time_rate capped at opt_high (tomato 30 C = 16)",
			_near(CropPhysiology.thermal_time_rate("tomato", 30.0), 16.0, 1e-9))
	_check("thermal_time_rate 0 below base and at max",
			CropPhysiology.thermal_time_rate("tomato", 8.0) == 0.0
			and CropPhysiology.thermal_time_rate("tomato", 35.0) == 0.0)


func _test_tomato_by_hand() -> void:
	# On the plateau (23 C) inside the VPD band: 3.0 g/MJ x 10 MJ/m2 x 2 m2
	# x water 0.9 = 54 g.
	var g := CropPhysiology.daily_growth_kg_dm("tomato", 10.0, 2.0, 23.0, 0.8, 0.9, 1.0)
	_check("tomato 23 C day = 0.054 kg DM", _near(g, 0.054, 1e-9), "%f" % g)
	# 15 C: beta(15; 10, 21, 35 - 5 = 30) = (15/9) (5/11)^(11/9) = 0.635812
	var f := CropPhysiology.temp_factor("tomato", 15.0)
	_check("tomato temp_factor 15 C = 0.6358 by hand", _near(f, 0.635812, 1e-5), "%f" % f)
	var g15 := CropPhysiology.daily_growth_kg_dm("tomato", 10.0, 2.0, 15.0, 0.8)
	_check("tomato 15 C day = 0.0381 kg DM", _near(g15, 0.0381487, 1e-6), "%f" % g15)
	var fresh := CropPhysiology.fresh_yield_from_dm("tomato", 1.0)
	_check("tomato 1 kg DM -> 10.91 kg fruit (0.6 / 0.055)", _near(fresh, 10.909091, 1e-5), "%f" % fresh)


func _test_other_functions() -> void:
	_check("tomato frost damage: 0 well above, 0.5 at kill, 1 well below",
			CropPhysiology.frost_damage("tomato", 3.0) == 0.0
			and _near(CropPhysiology.frost_damage("tomato", -0.5), 0.5, 1e-9)
			and CropPhysiology.frost_damage("tomato", -5.0) == 1.0)
	_check("kale survives -5 C that kills a tomato",
			CropPhysiology.frost_damage("kale", -5.0) == 0.0
			and CropPhysiology.frost_damage("tomato", -5.0) == 1.0)
	_check("transpiration = Kc x ET0 at full cover (tomato 5 mm -> 5.75 L/m2)",
			_near(CropPhysiology.transpiration_l_m2_day("tomato", 5.0, 1.0), 5.75, 1e-9))
	_check("transpiration bare soil = 0.15 x ET0",
			_near(CropPhysiology.transpiration_l_m2_day("tomato", 4.0, 0.0), 0.6, 1e-9))
	# VPD at 25 C, 60 % RH: es = 3.168 kPa, VPD = 1.267 kPa.
	_check("vpd_kpa 25 C 60 % = 1.267", _near(CropPhysiology.vpd_kpa(25.0, 60.0), 1.2672, 2e-3))


func _test_determinism() -> void:
	var a: Array = []
	var b: Array = []
	for pass_i in 2:
		var out: Array = a if pass_i == 0 else b
		for id in CropPhysiology.ids():
			for t in [2.0, 12.0, 19.0, 24.0, 33.0]:
				out.append(CropPhysiology.daily_growth_kg_dm(id, 8.5, 3.0, t, 1.1, 0.8, 0.95))
				out.append(CropPhysiology.thermal_time_rate(id, t))
	_check("same inputs give the same numbers", a == b and a.size() == 18 * 5 * 2)
