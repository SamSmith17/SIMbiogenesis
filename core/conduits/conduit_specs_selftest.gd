extends SceneTree

## Offline: ConduitSpecs (real sizes, ratings, bend radii) + ServicePalette.
##   Godot --headless --path . --script core/conduits/conduit_specs_selftest.gd

const EXPECTED_CHECKS := 54

var _checks := 0
var _failures := 0


func _initialize() -> void:
	ConduitStylePresets.clear_memory_for_tests()
	_test_every_kind()
	_test_corrected_numbers()
	_test_defaults_keep_the_sim()
	_test_sizes_reach_the_loss()
	_test_bend_rules()
	_test_run_summary()
	_test_service_palette()
	var ok := _failures == 0 and _checks == EXPECTED_CHECKS
	if _checks != EXPECTED_CHECKS:
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("CONDUIT SPECS SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if ok else "FAIL", _checks, _failures])
	quit(0 if ok else 1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s %s" % [label, detail])


func _test_every_kind() -> void:
	var bad_od: Array = []
	var bad_bend: Array = []
	var bad_style: Array = []
	for t: Variant in ConduitKinds.BUILTIN.keys():
		var tid := str(t)
		var od := ConduitSpecs.od_m(tid)
		if od <= 0.0005 or od > 0.6:
			bad_od.append("%s=%.4f" % [tid, od])
		var br := ConduitSpecs.bend_radius_m(tid)
		if br <= 0.0 or br < od * 0.9:
			bad_bend.append("%s=%.3f" % [tid, br])
		if not ["rigid_ortho", "flex_drape", "flex_route", "hang", "contour",
				"culvert"].has(ConduitSpecs.routing_style(tid)):
			bad_style.append(tid)
	_check("every kind has an OD", bad_od.is_empty(), str(bad_od))
	_check("every kind bends no tighter than its OD", bad_bend.is_empty(), str(bad_bend))
	_check("every kind has a routing style", bad_style.is_empty(), str(bad_style))
	# Every size row is complete.
	var bad_rows: Array = []
	for t: Variant in ConduitKinds.BUILTIN.keys():
		for r: Variant in ConduitSpecs.table(str(t)).get("rows", []) as Array:
			var rd: Dictionary = r
			for k: String in ["value", "label", "od_m", "id_m", "kg_m", "usd_m",
					"pressure_psi", "ampacity_a"]:
				if not rd.has(k):
					bad_rows.append("%s:%s" % [t, k])
	_check("every size row is complete", bad_rows.is_empty(), str(bad_rows))
	_check("EMT and copper are kinds", ConduitKinds.has_type("emt_conduit")
		and ConduitKinds.has_type("copper_type_l"))
	_check("EMT is electrical", ConduitKinds.is_electrical_type("emt_conduit"))
	_check("copper is fluid", ConduitKinds.is_fluid_type("copper_type_l"))


func _test_corrected_numbers() -> void:
	var cord := ConduitSpecs.od_m("extension_cord") * 1000.0
	_check("16/3 cord about 8.4 mm", cord > 7.0 and cord < 10.0, "%.1f mm" % cord)
	var pv := ConduitSpecs.od_m("dc_solar") * 1000.0
	_check("10 AWG PV wire about 6 mm", pv > 5.0 and pv < 7.0, "%.1f mm" % pv)
	_check("ABS DWV defaults to 2\"", ConduitKinds.pipe_kit_id("abs_dwv") == "us_sch40_2")
	_check("ABS DWV is not pressure rated",
		float(ConduitSpecs.for_run({"conduit_type": "abs_dwv"}, 5.0)["pressure_psi"]) < 0.0)
	_check("ABS DWV meta has no burst rating",
		not ConduitKinds.type_meta("abs_dwv").has("burst_pressure_psi"))
	_check("ducting has no psi", not ConduitKinds.type_meta("ducting").has("burst_pressure_psi"))
	var duct: Dictionary = ConduitSpecs.row("ducting")
	_check("6\" duct about 157 CFM", absf(float(duct.get("cfm", 0.0)) - 157.0) < 3.0,
		str(duct.get("cfm", 0.0)))
	_check("Cat6 PoE 960 mA a pair",
		is_equal_approx(float(ConduitKinds.type_meta("ethernet")["ampacity_a"]), 0.96))
	var od_4 := ConduitSpecs.od_m("pvc_pipe", {"pipe_size_in": 4.0})
	_check("4\" Sch40 OD 4.500\"", absf(od_4 - 4.5 * 0.0254) < 1e-4)
	_check("Sch40 sizes match the kit sizes",
		(ConduitSpecs.table("pvc_pipe")["rows"] as Array).size() == PipeKit.SCH40_SIZES_IN.size())


## The default row reproduces the numbers each kind carried before the table,
## so a saved run that was never re-sized loses exactly what it did.
func _test_defaults_keep_the_sim() -> void:
	var cord := ConduitSpecs.loss_meta("extension_cord")
	_check("cord default resistance", is_equal_approx(float(cord["resistance_ohm_per_m"]), 0.0264))
	_check("cord default ampacity", is_equal_approx(float(cord["ampacity_a"]), 13.0))
	var nm := ConduitSpecs.loss_meta("romex")
	_check("NM default 12 AWG", is_equal_approx(float(nm["resistance_ohm_per_m"]), 0.0104)
		and is_equal_approx(float(nm["ampacity_a"]), 20.0))
	var pv := ConduitSpecs.loss_meta("dc_solar")
	_check("PV default 10 AWG", is_equal_approx(float(pv["resistance_ohm_per_m"]), 0.0066))
	var hose := ConduitSpecs.loss_meta("garden_hose")
	_check("hose default bore 16 mm", absf(float(hose["inner_diameter_m"]) - 0.016) < 1e-6)
	var pvc := ConduitSpecs.loss_meta("pvc_pipe")
	_check("PVC default bore 1-1/4\"", absf(float(pvc["inner_diameter_m"]) - 0.0351) < 0.0003)
	var pvc4 := ConduitSpecs.loss_meta("pvc_4in")
	_check("4\" PVC bore unchanged", absf(float(pvc4["inner_diameter_m"]) - 0.10226) < 0.0003)
	var pex := ConduitSpecs.loss_meta("pex_blue")
	_check("PEX default bore", absf(float(pex["inner_diameter_m"]) - 0.0121) < 1e-6)
	var pen := ConduitSpecs.loss_meta("poly_penstock", {"pipe_size_in": 2.0})
	_check("penstock bore still from its SDR rule", absf(float(pen["inner_diameter_m"])
		- ConduitKinds.inner_diameter_for("poly_penstock", {"pipe_size_in": 2.0})) < 1e-9)


func _test_sizes_reach_the_loss() -> void:
	var cord12 := ConduitSpecs.loss_meta("extension_cord", {"awg": 12})
	_check("12/3 cord 20 A", is_equal_approx(float(cord12["ampacity_a"]), 20.0))
	_check("12/3 cord less resistance",
		float(cord12["resistance_ohm_per_m"]) < 0.0264 * 0.5)
	var pvc4 := ConduitSpecs.loss_meta("pvc_pipe", {"pipe_size_in": 4.0})
	_check("4\" pick reaches the bore", absf(float(pvc4["inner_diameter_m"]) - 0.1023) < 0.0003)
	_check("4\" pick carries more", float(pvc4["max_flow_lpm"])
		> float(ConduitSpecs.loss_meta("pvc_pipe")["max_flow_lpm"]))
	var emt10 := ConduitSpecs.loss_meta("emt_conduit", {"awg": 10})
	_check("EMT with 10 AWG THHN 30 A", is_equal_approx(float(emt10["ampacity_a"]), 30.0))
	var hose_big := ConduitSpecs.row("garden_hose", {"size_in": 0.74})
	_check("nearest size row", is_equal_approx(float(hose_big["value"]), 0.75))


func _test_bend_rules() -> void:
	var nm := ConduitSpecs.bend_radius_m("romex")
	_check("NM 5 x OD (NEC 334.24)",
		absf(nm - 5.0 * ConduitSpecs.od_m("romex")) < 1e-6)
	var emt := ConduitSpecs.bend_radius_m("emt_conduit", {"pipe_size_in": 0.75})
	_check("3/4\" EMT 4-1/2\" radius (NEC Ch. 9 T2)", absf(emt - 0.1143) < 1e-4, str(emt))
	var emt2 := ConduitSpecs.bend_radius_m("emt_conduit", {"pipe_size_in": 2.0})
	_check("2\" EMT 9-1/2\" radius", absf(emt2 - 0.2413) < 1e-4, str(emt2))
	var cat6 := ConduitSpecs.bend_radius_m("ethernet")
	_check("Cat6 4 x OD", absf(cat6 - 4.0 * 0.0061) < 1e-6)
	var pen := ConduitSpecs.bend_radius_m("poly_penstock", {"pipe_size_in": 2.0})
	_check("penstock radius from the PPI rule",
		is_equal_approx(pen, ConduitKinds.contour_bend_radius_m("poly_penstock", {"pipe_size_in": 2.0})))
	_check("a style radius cannot go tighter than the rule",
		is_equal_approx(ConduitSpecs.bend_radius_m("romex", {"bend_radius_m": 0.001}), nm))
	_check("a style radius may go wider",
		is_equal_approx(ConduitSpecs.bend_radius_m("romex", {"bend_radius_m": 0.5}), 0.5))
	_check("EMT field bends include 22.5",
		ConduitSpecs.allowed_angles("emt_conduit").has(22.5))
	_check("kit pipes turn 45 and 90 only", ConduitSpecs.allowed_angles("pvc_pipe") == [90.0, 45.0])
	_check("a cord turns any angle", ConduitSpecs.allowed_angles("extension_cord").is_empty())


func _test_run_summary() -> void:
	var s := ConduitSpecs.for_run({"conduit_type": "pvc_pipe",
		"conduit_style": {"pipe_size_in": 2.0}}, 12.0)
	_check("run weight", float(s["kg"]) > 10.0 and float(s["kg"]) < 14.0, str(s["kg"]))
	_check("run cost", float(s["usd"]) > 60.0, str(s["usd"]))
	_check("run supports", int(s["supports"]) == 11, str(s["supports"]))
	_check("2\" Sch40 280 psi", is_equal_approx(float(s["pressure_psi"]), 280.0))
	var e := ConduitSpecs.for_run({"conduit_type": "emt_conduit",
		"conduit_style": {"awg": 10}}, 10.0)
	_check("EMT run names its conductors", str(e.get("conductors", "")).find("10 AWG") >= 0)


func _test_service_palette() -> void:
	_check("hot water red", ServicePalette.service_for(
		{"polarity": "resource", "resource_kind": "hot_water"}) == "hot_water")
	_check("greywater is a drain", ServicePalette.service_for(
		{"polarity": "resource", "resource_kind": "greywater"}) == "drain")
	_check("AC power", ServicePalette.service_for({"polarity": "ac"}) == "power_ac")
	_check("DC power", ServicePalette.service_for({"polarity": "positive"}) == "power_dc")
	_check("data wires", ServicePalette.service_for({"polarity": "data"}) == "data")
	_check("water is blue", ServicePalette.color_for(
		{"polarity": "resource", "resource_kind": "water"}).b > 0.8)
	_check("lane order keeps power apart from water",
		ServicePalette.lane_rank("power_ac") < ServicePalette.lane_rank("cold_water"))
