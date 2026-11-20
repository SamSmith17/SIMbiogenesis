extends SceneTree

## Battery Lab self-test (offline). Run --import first:
##   Godot --headless --path . --script core/batterylab/batterylab_selftest.gd
## Phase 0: the chemistry table (every field, ordered voltages, monotone OCV,
## the inverse, temperature compensation, cycle life, Peukert, IEC 62485-2
## ventilation and Faraday's hydrogen by hand), the cell catalog (V × Ah, its
## chemistry's density bands, shapes, monoblock cell counts), the BMS catalog
## (ranges, protection windows, fitting) and BatteryChemistry unchanged for
## the graph's callers.
## Phase 1: conductor sizing by hand (NEC 310.16 picks, the DIN 43671 busbar
## fit, ρL/A), every built-in pack solving with no error, its numbers from
## its cells, cells inside the case and not overlapping, one link per series
## joint touching both groups, S+1 balance taps, the rack and BCI sizes, the
## laid-down rack orientation, fixed arrangements kept, the key surviving
## JSON, graph specs read back by BatteryChemistry, the builder's parts,
## cutaway and picking.

const EXPECTED_CHECKS := 2015

var _pass := 0
var _fail := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (got %.5f, want %.5f)" % [what, a, b])


func _initialize() -> void:
	_test_chem_table()
	_test_chem_maths()
	_test_chem_infer()
	_test_cells()
	_test_bms()
	_test_battery_chemistry_unchanged()
	_test_conductors()
	_test_presets()
	_test_pack_by_hand()
	_test_spec_key()
	_test_builder()
	_test_bms_logic()
	_test_sim()
	_test_bank()
	_test_bank_bus_and_route()
	_test_bank_sim()
	var total := _pass + _fail
	print("batterylab selftest: %d passed, %d failed (%d checks)" % [_pass, _fail, total])
	if EXPECTED_CHECKS > 0 and total != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [total, EXPECTED_CHECKS])
		_fail += 1
	print("batterylab selftest: ", "PASS" if _fail == 0 else "FAILED")
	quit(0 if _fail == 0 else 1)


const ROW_KEYS := ["label", "long", "family", "cell_nominal_v", "cell_max_v", "cell_absorb_v",
	"cell_float_v", "cell_min_v", "charge_temp_c", "discharge_temp_c", "coulombic_eff",
	"round_trip_eff", "peukert", "self_discharge_pct_month", "recommended_dod", "cycles",
	"wh_per_kg", "wh_per_l", "stages", "ocv", "est"]


func _test_chem_table() -> void:
	_ok(BattChem.IDS.size() == 6, "six chemistries")
	for id in BattChem.IDS:
		var r := BattChem.row(str(id))
		for k in ROW_KEYS:
			_ok(r.has(k), "%s has %s" % [id, k])
		var nom := float(r["cell_nominal_v"])
		var mx := float(r["cell_max_v"])
		var mn := float(r["cell_min_v"])
		_ok(mn < nom and nom < mx, "%s min < nominal < max" % id)
		_ok(float(r["cell_absorb_v"]) <= mx + 1e-6, "%s absorb ≤ max" % id)
		if float(r["cell_float_v"]) > 0.0:
			_ok(float(r["cell_float_v"]) < float(r["cell_absorb_v"]) + 1e-6, "%s float ≤ absorb" % id)
			_ok(float(r["cell_float_v"]) > nom, "%s float above nominal" % id)
		var ocv: Array = r["ocv"]
		_ok(ocv.size() == 11, "%s OCV has 11 points" % id)
		var mono := true
		for i in range(1, ocv.size()):
			if float(ocv[i]) <= float(ocv[i - 1]):
				mono = false
		_ok(mono, "%s OCV rises with SOC" % id)
		_ok(float(ocv[ocv.size() - 1]) <= mx, "%s full OCV under the max charge V" % id)
		_ok(float(ocv[0]) >= mn - 0.3, "%s empty OCV near the cut-off" % id)
		var eff := float(r["round_trip_eff"])
		_ok(eff > 0.7 and eff < 1.0 and eff <= float(r["coulombic_eff"]),
				"%s round trip < coulombic < 1" % id)
		var cy: Array = r["cycles"]
		var dec := true
		for i in range(1, cy.size()):
			var a: Array = cy[i - 1]
			var b: Array = cy[i]
			if float(b[0]) <= float(a[0]) or float(b[1]) >= float(a[1]):
				dec = false
		_ok(dec, "%s cycle life falls as DoD rises" % id)
		var ct: Array = r["charge_temp_c"]
		_ok(float(ct[0]) < float(ct[1]), "%s charge window ordered" % id)
		_ok(BattChem.graph_class(str(id)) != BatteryChemistry.UNKNOWN, "%s maps to a graph class" % id)
	_ok(BattChem.is_lead(BattChem.FLA) and BattChem.is_lithium(BattChem.LFP), "families")
	_ok(BattChem.graph_class(BattChem.AGM) == BatteryChemistry.LEAD, "AGM is lead on the graph")
	_ok(BattChem.graph_class(BattChem.NMC) == BatteryChemistry.LI_ION, "NMC is Li-ion on the graph")


func _test_chem_maths() -> void:
	# OCV at the table points and between them.
	_near(BattChem.ocv(BattChem.LFP, 1.0), 3.40, 1e-6, "LFP full OCV")
	_near(BattChem.ocv(BattChem.LFP, 0.5), 3.26, 1e-6, "LFP 50 % OCV")
	_near(BattChem.ocv(BattChem.LFP, 0.55), 3.265, 1e-6, "LFP 55 % between points")
	_near(BattChem.ocv(BattChem.FLA, 1.0) * 6.0, 12.70, 0.01, "12 V flooded full = 12.70 V")
	for id in BattChem.IDS:
		for s in [0.0, 0.17, 0.5, 0.83, 1.0]:
			var v := BattChem.ocv(str(id), float(s))
			_near(BattChem.soc_from_ocv(str(id), v), float(s), 1e-4, "%s SOC from OCV round trip at %.2f" % [id, s])
	_near(BattChem.soc_from_ocv(BattChem.LFP, 2.0), 0.0, 1e-9, "below the curve = empty")
	_near(BattChem.soc_from_ocv(BattChem.LFP, 3.6), 1.0, 1e-9, "above the curve = full")
	# Temperature compensation: flooded at 15 °C absorbs 0.05 V/cell higher.
	_near(BattChem.charge_v(BattChem.FLA, "absorb", 15.0), 2.47 + 0.05, 1e-6, "FLA absorb at 15 °C")
	_near(BattChem.charge_v(BattChem.LFP, "absorb", 5.0), 3.55, 1e-6, "LFP not compensated")
	_near(BattChem.charge_v(BattChem.AGM, "equalize"), 0.0, 1e-9, "AGM has no equalize")
	# Temperature windows.
	_ok(not BattChem.can_charge_at(BattChem.LFP, -1.0), "LFP will not charge below 0 °C")
	_ok(BattChem.can_discharge_at(BattChem.LFP, -10.0), "LFP discharges at −10 °C")
	_ok(BattChem.can_charge_at(BattChem.AGM, -10.0), "AGM charges at −10 °C")
	# Cycle life: table points exact, between them log-linear and ordered.
	_near(BattChem.cycles_at_dod(BattChem.LFP, 0.8), 6000.0, 1e-6, "LFP 80 % cycles")
	var mid := BattChem.cycles_at_dod(BattChem.LFP, 0.65)
	_ok(mid < 10000.0 and mid > 6000.0, "LFP 65 % between its neighbours")
	_near(mid, exp(lerpf(log(10000.0), log(6000.0),
			(log(0.65) - log(0.5)) / (log(0.8) - log(0.5)))), 1e-3, "LFP 65 % by hand")
	_near(BattChem.cycles_at_dod(BattChem.SLA, 0.1), 1200.0, 1e-6, "below the table = first point")
	_ok(BattChem.lifetime_throughput(BattChem.LFP, 0.8) > BattChem.lifetime_throughput(BattChem.AGM, 0.5) * 5.0,
			"LFP delivers many times AGM's lifetime energy")
	# Peukert: 100 Ah flooded at 20 A (C/5) = 100 · (5/20)^0.25 = 70.71 Ah.
	_near(BattChem.peukert_capacity(BattChem.FLA, 100.0, 20.0), 70.7107, 1e-3, "Peukert C/5 flooded")
	_near(BattChem.peukert_capacity(BattChem.FLA, 100.0, 5.0), 100.0, 1e-9, "Peukert at the rated current")
	# IEC 62485-2: 24 vented cells of 200 Ah on boost: 0.05·24·20·200·10⁻³ = 4.8 m³/h.
	_near(BattChem.ventilation_m3h(BattChem.FLA, 24, 200.0, "boost"), 4.8, 1e-9, "vented boost ventilation")
	_near(BattChem.ventilation_m3h(BattChem.AGM, 24, 200.0, "float"), 0.24, 1e-9, "VRLA float ventilation")
	_near(BattChem.ventilation_m3h(BattChem.LFP, 16, 280.0), 0.0, 1e-9, "lithium needs no gas ventilation")
	# Faraday: 1 Ah per cell → 3600 / 96485 / 2 · 22.414 L.
	_near(BattChem.H2_L_PER_AH_CELL, 3600.0 / 96485.0 / 2.0 * 22.414, 0.002, "hydrogen per Ah by Faraday")
	_near(BattChem.hydrogen_l(6, 10.0), 6.0 * 10.0 * BattChem.H2_L_PER_AH_CELL, 1e-9, "hydrogen sums")
	_near(BattChem.self_discharge(BattChem.FLA, 30.0), 0.05, 1e-9, "a month of flooded self-discharge")


func _test_chem_infer() -> void:
	var cases := [
		[{"chemistry": "LFP", "name": "x"}, BattChem.LFP],
		[{"chemistry": "SLA", "name": "12V 100Ah AGM"}, BattChem.AGM],
		[{"chemistry": "SLA", "name": "Alarm battery"}, BattChem.SLA],
		[{"name": "6V Flooded golf cart"}, BattChem.FLA],
		[{"name": "Gel deep cycle"}, BattChem.GEL],
		[{"name": "13S NMC e-bike"}, BattChem.NMC],
		[{"voltage": 51.2, "name": "Server Rack"}, BattChem.LFP],
		[{"voltage": 12.0, "name": "Unlabelled"}, BattChem.AGM],
		[{"voltage": 0.0, "name": "Unlabelled"}, ""],
	]
	for c in cases:
		_ok(BattChem.infer(c[0] as Dictionary) == str(c[1]),
				"infer %s → %s (got %s)" % [c[0], c[1], BattChem.infer(c[0] as Dictionary)])
	_ok(BattChem.normalize("LiFePO4") == BattChem.LFP, "normalize LiFePO4")
	_ok(BattChem.normalize("lead-acid") == BattChem.AGM, "plain lead reads as AGM")
	_ok(BattChem.normalize("banana") == "", "unknown is empty")
	_ok(BatteryChemistry.detailed({"name": "6V flooded"}) == BattChem.FLA, "BatteryChemistry.detailed")
	# Every library preset gets a chemistry.
	for p in ComponentPresets.BATTERIES:
		var sp: Dictionary = (p as Dictionary)["specs"]
		_ok(not BattChem.infer(sp).is_empty(), "library %s has a chemistry" % sp.get("name", "?"))


func _test_cells() -> void:
	_ok(BattCells.CELLS.size() >= 20, "at least 20 cells")
	var seen := {}
	for c in BattCells.CELLS:
		var d: Dictionary = c
		var id := str(d["id"])
		_ok(not seen.has(id), "%s id unique" % id)
		seen[id] = true
		_ok(BattCells.has(id) and BattCells.get_cell(id) == d, "%s indexed" % id)
		var chem := str(d["chem"])
		_ok(BattChem.has(chem), "%s chemistry known" % id)
		_ok(BattCells.FORMATS.has(str(d["format"])), "%s format known" % id)
		for k in ["label", "maker", "model", "nominal_v", "ah", "rate_h", "mass_kg", "ir_mohm",
				"std_c", "charge_c", "discharge_c", "peak_c", "peak_s", "terminals", "source", "est"]:
			_ok(d.has(k), "%s has %s" % [id, k])
		var b := BattCells.box_mm(d)
		_ok(b.x > 0.0 and b.y > 0.0 and b.z > 0.0, "%s has a size" % id)
		# Nominal voltage = cells inside × the chemistry's cell voltage (A123's 3.3 V aside).
		var per_cell := float(d["nominal_v"]) / float(BattCells.cells_inside(d))
		_near(per_cell, BattChem.row(chem)["cell_nominal_v"], 0.11, "%s per-cell nominal" % id)
		_near(BattCells.wh(d), float(d["nominal_v"]) * float(d["ah"]), 1e-9, "%s Wh = V × Ah" % id)
		var band_kg: Array = BattChem.row(chem)["wh_per_kg"]
		var band_l: Array = BattChem.row(chem)["wh_per_l"]
		var wk := BattCells.wh_per_kg(d)
		var wl := BattCells.wh_per_l(d)
		_ok(wk >= float(band_kg[0]) and wk <= float(band_kg[1]),
				"%s %.0f Wh/kg inside %s's band %s" % [id, wk, chem, band_kg])
		_ok(wl >= float(band_l[0]) and wl <= float(band_l[1]),
				"%s %.0f Wh/L inside %s's band %s" % [id, wl, chem, band_l])
		_ok(float(d["std_c"]) <= float(d["charge_c"]) + 1e-9, "%s standard ≤ max charge" % id)
		_ok(float(d["discharge_c"]) <= float(d["peak_c"]) + 1e-9, "%s continuous ≤ peak" % id)
		if str(d["format"]) == "monoblock":
			_ok(BattChem.is_lead(chem), "%s monoblock is lead" % id)
			_ok([3, 6].has(BattCells.cells_inside(d)), "%s has 3 or 6 cells" % id)
		if str(d["format"]) == "prismatic" and chem == BattChem.LFP:
			_ok(d.has("compression_kgf"), "%s says its compression" % id)
		_ok(BattCells.cycles_at_dod(d, 0.8) > 0.0, "%s has a cycle life" % id)
	# By hand: LF280K 896 Wh, 163 Wh/kg; its own 6000 cycles at 80 %.
	var lf := BattCells.get_cell("eve_lf280k")
	_near(BattCells.wh(lf), 896.0, 1e-6, "LF280K 896 Wh")
	_near(BattCells.wh_per_kg(lf), 896.0 / 5.49, 1e-6, "LF280K Wh/kg")
	_near(BattCells.cycles_at_dod(lf, 0.8), 6000.0, 1e-6, "LF280K own cycles")
	_near(BattCells.max_charge_a(lf), 280.0, 1e-9, "LF280K 1C charge")
	# Cylinder volume is the cylinder's: 21700 → π·10.625²·70.8 mm³.
	var e50 := BattCells.get_cell("samsung_50e")
	_near(BattCells.volume_l(e50), PI * 10.625 * 10.625 * 70.8 * 1e-6, 1e-9, "21700 volume")
	_near(BattCells.unit_v(BattCells.get_cell("agm_g31_100"), 2.40), 14.4, 1e-9, "12 V AGM absorb 14.4 V")
	_ok(BattCells.by_chem(BattChem.LFP).size() >= 9, "LFP cells listed")
	_ok(BattCells.by_format("monoblock").size() >= 7, "monoblocks listed")
	_ok(BattCells.search("eve 280").size() == 1, "search eve 280")
	_ok(BattCells.search("21700").size() == 2, "search 21700")
	_ok(BattCells.get_cell("nope").is_empty(), "unknown cell is empty")
	# Every chemistry has at least one cell to build with.
	for id in BattChem.IDS:
		_ok(not BattCells.by_chem(str(id)).is_empty(), "a %s cell exists" % id)


func _test_bms() -> void:
	var seen := {}
	for b in BattBms.BMS:
		var d: Dictionary = b
		var id := str(d["id"])
		_ok(not seen.has(id), "%s unique" % id)
		seen[id] = true
		_ok(int(d["s_min"]) <= int(d["s_max"]), "%s series range" % id)
		_ok(float(d["cont_a"]) <= float(d["peak_a"]), "%s continuous ≤ peak" % id)
		_ok(["fet", "contactor", "none"].has(str(d["switch"])), "%s switch kind" % id)
		for chem in (d["chems"] as Array):
			_ok(BattChem.has(str(chem)), "%s chemistry %s known" % [id, chem])
			var p := BattBms.params(id, str(chem))
			if not bool(d["protection"]):
				_ok(p.is_empty(), "%s monitor has no protection" % id)
				continue
			if BattChem.is_lead(str(chem)):
				continue
			for k in BattBms.PROTECTIONS:
				_ok(p.has(k), "%s on %s has %s" % [id, chem, k])
				_ok(BattBms.WORDS.has(k) and BattBms.OPENS.has(k), "%s has words" % k)
			_ok(BattBms.check_params(p).is_empty(), "%s on %s settings consistent %s"
					% [id, chem, BattBms.check_params(p)])
			var bal := BattBms.balance_for(id, str(chem))
			if str(bal["kind"]) != "none":
				var ov := float((p["cell_ov"] as Dictionary)["trip"])
				var uv_rel := float((p["cell_uv"] as Dictionary)["release"])
				_ok(float(bal["start_v"]) < ov and float(bal["start_v"]) > uv_rel,
						"%s balances between the windows on %s" % [id, chem])
	# Defaults by hand.
	var lfp := BattBms.defaults_for(BattChem.LFP)
	_near(float((lfp["cell_ov"] as Dictionary)["trip"]), 3.65, 1e-9, "LFP OV trip 3.65")
	_near(float((lfp["cell_uv"] as Dictionary)["trip"]), 2.5, 1e-9, "LFP UV trip 2.5")
	_near(float((lfp["charge_ut"] as Dictionary)["trip"]), 0.0, 1e-9, "LFP no charge below 0 °C")
	_ok(BattBms.defaults_for(BattChem.AGM).is_empty(), "lead has no BMS defaults")
	# Overrides apply field by field and keep the rest.
	var ov := BattBms.params("jbd_16s_100a", BattChem.LFP, {"cell_ov": {"trip": 3.60}})
	_near(float((ov["cell_ov"] as Dictionary)["trip"]), 3.60, 1e-9, "override trip")
	_near(float((ov["cell_ov"] as Dictionary)["release"]), 3.40, 1e-9, "override keeps release")
	_near(float((BattBms.defaults_for(BattChem.LFP)["cell_ov"] as Dictionary)["trip"]), 3.65, 1e-9,
			"override did not touch the defaults")
	# Bad settings are said.
	var bad := BattBms.defaults_for(BattChem.LFP)
	(bad["cell_ov"] as Dictionary)["release"] = 3.70
	_ok(not BattBms.check_params(bad).is_empty(), "OV release above trip is caught")
	# Current trips in amps: 100 A × 1.5.
	_near(BattBms.current_trip_a("jbd_16s_100a", ov, "discharge_oc2"), 150.0, 1e-9, "fast OC in amps")
	# Fitting: a 16S LFP pack needing 150 A.
	var fit := BattBms.fitting(BattChem.LFP, 16, 150.0)
	var fit_ids: Array = []
	for f in fit:
		fit_ids.append(str((f as Dictionary)["id"]))
	_ok(fit_ids.has("jk_pb2a16s20p") and fit_ids.has("seplos_10e"), "16S 150 A fits the 200 A BMSs")
	_ok(not fit_ids.has("jbd_16s_100a"), "a 100 A BMS does not fit 150 A")
	_ok(not fit_ids.has("jbd_4s_100a"), "a 4S BMS does not fit 16S")
	_ok(BattBms.fitting(BattChem.FLA, 6).size() == 1, "lead only gets the monitor")
	# Balancing time: 5 Ah of mismatch at 50 mA = 100 h; at 2 A active = 2.5 h.
	_near(BattBms.balance_hours("jbd_16s_100a", BattChem.LFP, 5.0), 100.0, 1e-9, "passive balance time")
	_near(BattBms.balance_hours("jk_pb2a16s20p", BattChem.LFP, 5.0), 2.5, 1e-9, "active balance time")
	_ok(is_inf(BattBms.balance_hours("shunt_monitor", BattChem.AGM, 5.0)), "a monitor never balances")


## The graph's view of chemistry must not move (graph_electrical_selftest
## pins these too; repeated here so a change in this lab is caught here).
func _test_battery_chemistry_unchanged() -> void:
	_near(BatteryChemistry.charge_ceiling_v(12.8, BatteryChemistry.LFP), 14.6, 0.05, "LFP 4S ceiling")
	_near(BatteryChemistry.charge_ceiling_v(12.0, BatteryChemistry.LEAD), 14.4, 0.05, "lead 6S ceiling")
	_near(BatteryChemistry.charge_ceiling_v(51.2, BatteryChemistry.LFP), 58.4, 0.05, "LFP 16S ceiling")
	_ok(BatteryChemistry.infer({"voltage": 51.2, "name": "Server Rack"}) == BatteryChemistry.LFP,
			"graph infer unchanged")
	_ok(BatteryChemistry.label(BatteryChemistry.LEAD) == "SLA", "graph label unchanged")
	# The two tables agree on the cell voltages they share.
	_near(float(BatteryChemistry.profile(BatteryChemistry.LFP)["cell_max_v"]),
			float(BattChem.row(BattChem.LFP)["cell_max_v"]), 1e-9, "LFP max agrees")
	_near(float(BatteryChemistry.profile(BatteryChemistry.LI_ION)["cell_max_v"]),
			float(BattChem.row(BattChem.NMC)["cell_max_v"]), 1e-9, "NMC max agrees")
	_near(float(BatteryChemistry.profile(BatteryChemistry.LEAD)["cell_max_v"]),
			float(BattChem.row(BattChem.AGM)["cell_max_v"]), 1e-9, "AGM max agrees")


# ---------------------------------------------------------------------------
# Phase 1: packs
# ---------------------------------------------------------------------------

func _test_conductors() -> void:
	_ok(str(BattElectrical.wire_for(100.0)["name"]) == "3 AWG", "100 A → 3 AWG (NEC 310.16 75 °C)")
	_ok(str(BattElectrical.wire_for(200.0)["name"]) == "3/0 AWG", "200 A → 3/0 AWG")
	_ok(str(BattElectrical.wire_for(20.0)["name"]) == "14 AWG", "20 A → 14 AWG")
	_ok(bool(BattElectrical.wire_for(900.0).get("short", false)), "nothing in the table carries 900 A")
	_near(BattElectrical.wire_amps(33.6), 115.0, 1e-9, "2 AWG carries 115 A")
	_near(BattElectrical.busbar_amps(20.0, 3.0, "copper", false), 3.88 * sqrt(60.0 * 46.0), 1e-6, "20 × 3 copper by the fit")
	_near(BattElectrical.busbar_amps(20.0, 3.0, "copper", false), 204.0, 3.0, "20 × 3 near DIN 43671's 204 A")
	_near(BattElectrical.busbar_amps(20.0, 3.0), BattElectrical.busbar_amps(20.0, 3.0, "copper", false) * 0.8, 1e-6, "enclosed × 0.8")
	_ok(BattElectrical.busbar_amps(20.0, 3.0, "aluminium") < BattElectrical.busbar_amps(20.0, 3.0), "aluminium carries less")
	var b := BattElectrical.busbar_for(150.0)
	_ok(BattElectrical.busbar_amps(float(b[0]), float(b[1])) >= 150.0, "busbar_for carries the current")
	_ok(float(BattElectrical.busbar_for(400.0, "copper", 25.0)[0]) <= 25.0, "busbar_for keeps to the width")
	_near(BattElectrical.resistance("copper", 1000.0, 100.0), 1.72e-4, 1e-9, "1 m of 100 mm² copper")
	_near(BattElectrical.resistance("nickel", 10.0, 1.2), 6.99e-8 * 0.01 / 1.2e-6, 1e-12, "nickel strip")
	_ok(BattElectrical.strips_for(5.0) == 1 and BattElectrical.strips_for(7.0) == 2, "nickel strips by current")
	_near(BattElectrical.breaker_for(110.0), 125.0, 1e-9, "breaker frame above 110 A")
	_near(BattElectrical.mass_kg("copper", 1000.0, 100.0), 0.896, 1e-6, "1 m of 100 mm² copper weighs 0.896 kg")


func _box_of(e: Dictionary) -> AABB:
	return AABB((e["c"] as Vector3) - (e["s"] as Vector3) * 0.5, e["s"])


func _test_presets() -> void:
	var bs := BattPresets.builtins()
	_ok(bs.size() >= 11, "at least 11 built-ins")
	var forms := {}
	var chems := {}
	for b in bs:
		var id := str((b as Dictionary)["id"])
		var d := BattDesign.solve((b as Dictionary)["spec"])
		var sp: Dictionary = d["spec"]
		var cell: Dictionary = d["cell"]
		var e: Dictionary = d["electrical"]
		var L: Dictionary = d["layout"]
		forms[str(sp["form"])] = true
		chems[str(d["chem"])] = true
		var errs: Array = (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		_ok(errs.is_empty(), "%s has no error: %s" % [id, errs])
		var s := int(sp["series"])
		var p := int(sp["parallel"])
		_near(float(e["v_nom"]), float(s) * float(cell["nominal_v"]), 1e-6, "%s V = S × cell V" % id)
		_near(float(e["ah"]), float(p) * float(cell["ah"]), 1e-6, "%s Ah = P × cell Ah" % id)
		_near(float(e["wh"]), float(e["v_nom"]) * float(e["ah"]), 1e-3, "%s Wh = V × Ah" % id)
		_ok(float(e["v_min"]) < float(e["v_nom"]) and float(e["v_nom"]) < float(e["v_max"]), "%s voltages ordered" % id)
		_ok(float(e["cont_discharge_a"]) > 0.0 and float(e["cont_discharge_a"]) <= float(e["limits"]["cells"]) + 1e-6,
				"%s current within the cells" % id)
		_ok(float(e["cont_charge_a"]) <= float(cell["charge_c"]) * float(e["ah"]) + 1e-6, "%s charge within the cells" % id)
		_ok(float(e["r_ohm"]) >= float(e["r_cells"]) and (s * p == 1 or float(e["r_ohm"]) > float(e["r_cells"])),
				"%s resistance above the cells alone" % id)
		_ok(float(d["mass_kg"]) >= float(cell["mass_kg"]) * float(s * p), "%s weighs at least its cells" % id)
		var cells: Array = L["cells"]
		_ok(cells.size() == s * p, "%s has S × P cells" % id)
		# Inside the case, not overlapping.
		var en: Dictionary = L["enclosure"]
		if not en.is_empty():
			var o: AABB = (en["outer"] as AABB).grow(0.5)
			var inside := true
			for ce in cells:
				if not o.encloses(_box_of(ce)):
					inside = false
			_ok(inside, "%s cells inside the case" % id)
			if not (L["bms"] as Dictionary).is_empty():
				_ok(o.encloses(_box_of(L["bms"])), "%s BMS inside the case" % id)
		var overlap := false
		for i in cells.size():
			var a := _box_of(cells[i]).grow(-0.2)
			for j in range(i + 1, cells.size()):
				if a.intersects(_box_of(cells[j]).grow(-0.2)):
					overlap = true
		_ok(not overlap, "%s cells do not overlap" % id)
		# One link per series joint, touching group k's negative and k+1's positive.
		var links: Array = L["links"]
		_ok(links.size() == s - 1, "%s has S − 1 links" % id)
		var groups: Array = L["groups"]
		var touch := true
		var chain := true
		for i in links.size():
			var lk: Dictionary = links[i]
			if int(lk["from"]) != i or int(lk["to"]) != i + 1:
				chain = false
			if not lk.has("c") or str(lk["kind"]) == "cable":
				continue
			var lb := _box_of(lk).grow(1.0)
			var ga: AABB = groups[int(lk["from"])]["neg"]
			var gb: AABB = groups[int(lk["to"])]["pos"]
			if not (lb.intersects(ga.grow(0.6)) and lb.intersects(gb.grow(0.6))):
				touch = false
		_ok(touch, "%s links touch the terminals they join" % id)
		_ok(chain, "%s links run group 1 → S in order" % id)
		# Taps.
		if bool(d["protected"]):
			_ok((L["taps"] as Array).size() == s + 1, "%s has S + 1 balance taps" % id)
			_ok((L["harness"] as Array).size() == s + 1, "%s has a lead per tap" % id)
			var ok_len := true
			for h in (L["harness"] as Array):
				if float(h["len_mm"]) <= 0.0:
					ok_len = false
			_ok(ok_len, "%s every balance lead has a length" % id)
			_ok(not (L["sensors"] as Array).is_empty(), "%s has temperature sensors" % id)
		else:
			_ok((L["taps"] as Array).is_empty(), "%s (no BMS) has no taps" % id)
		_ok(not BattDesign.packed_spec(d).is_empty(), "%s packs for shipping" % id)
		var gs := BattDesign.graph_specs(d)
		_ok(BatteryChemistry.infer(gs) == BattChem.graph_class(str(d["chem"])), "%s graph reads its chemistry" % id)
		_ok(BattChem.infer(gs) == str(d["chem"]), "%s Battery Lab reads its chemistry back" % id)
		var lib := str((b as Dictionary)["library_label"])
		if not lib.is_empty():
			_ok(str(BattPresets.for_library_label(lib).get("id", "")) == id, "%s stands for library %s" % [id, lib])
		match str(sp["form"]):
			"rack":
				var o: AABB = en["outer"]
				_near(o.size.x, 440.0, 1e-3, "%s rack body 440 mm" % id)
				var u := int(en["rack_u"])
				_near(o.size.y, float(u) * 44.45 - 0.8, 1e-3, "%s height is whole rack units" % id)
				_ok(u <= 6, "%s at most 6U (%dU)" % [id, u])
			"automotive":
				if not en.is_empty():
					var g: Array = BattSpec.BCI_GROUPS[str((sp["enclosure"] as Dictionary)["group"])]
					var o: AABB = en["outer"]
					_near(o.size.x, float(g[0]), 1e-3, "%s BCI length" % id)
					_near(o.size.y, float(g[1]), 1e-3, "%s BCI height" % id)
					_near(o.size.z, float(g[2]), 1e-3, "%s BCI width" % id)
		var bnd: AABB = L["bounds"]
		_near(bnd.position.y, 0.0, 1e-3, "%s stands on the origin" % id)
		_near(bnd.get_center().x, 0.0, 1e-3, "%s centred in x" % id)
	for f in BattSpec.FORMS:
		_ok(forms.has(f), "a built-in in form %s" % f)
	for c in ["FLA", "AGM", "LFP", "NMC"]:
		_ok(chems.has(c), "a built-in of %s" % c)
	# The 105 Ah rack pack lays its cells on their side to fit 4U.
	var rk := BattDesign.solve(BattPresets.builtin("rack_48v_105"))
	_ok(str(rk["arrange"]["orient"]) == "side", "48 V 105 Ah rack lays its cells down")
	_ok(int(rk["layout"]["enclosure"]["rack_u"]) == 4, "48 V 105 Ah rack is 4U")
	var td: Vector3 = rk["layout"]["cells"][0]["term_d"]
	_ok(absf(td.y) < 0.1, "laid-down cells' terminals face sideways")


func _test_pack_by_hand() -> void:
	# DIY 16S 280 Ah: 16 × 3.2 = 51.2 V, 280 Ah, 14.336 kWh; usable at 90 %.
	var d := BattDesign.solve(BattPresets.builtin("diy_16s_280"))
	var e: Dictionary = d["electrical"]
	_near(float(e["v_nom"]), 51.2, 1e-6, "16S LFP 51.2 V")
	_near(float(e["v_max"]), 58.4, 1e-6, "16S LFP full 58.4 V")
	_near(float(e["v_min"]), 40.0, 1e-6, "16S LFP empty 40 V")
	_near(float(e["wh"]), 14336.0, 1e-3, "14.336 kWh")
	_near(float(e["usable_wh"]), 14336.0 * 0.9, 1e-3, "usable at 90 %")
	_near(float(e["r_cells"]), 16.0 * 0.25e-3, 1e-9, "cells 16 × 0.25 mΩ")
	_ok(str(e["limit_by"]) == "bms" and is_equal_approx(float(e["cont_discharge_a"]), 200.0), "the 200 A BMS sets the current")
	_near(float(e["sag_v"]), 200.0 * float(e["r_ohm"]), 1e-9, "sag = I × R")
	_ok(bool(d["plates"]), "prismatic LFP gets a compression fixture")
	_ok(not (d["layout"]["rods"] as Array).is_empty(), "the fixture has rods")
	# A 4S2P drop-in: two cells per group.
	var d2 := BattDesign.solve(BattPresets.builtin("dropin_12v_210"))
	_near(float(d2["electrical"]["ah"]), 210.0, 1e-6, "4S2P 210 Ah")
	_near(float(d2["electrical"]["r_cells"]), 4.0 * 0.5e-3 / 2.0, 1e-9, "4S2P cells' resistance halves")
	# Lead-acid block: no BMS, Peukert at C/5 below the 20 h rating.
	var d3 := BattDesign.solve(BattPresets.builtin("fla_6v_225"))
	_ok(not bool(d3["protected"]) and str(d3["bms_id"]).is_empty(), "a single flooded block has no BMS")
	_ok(float(d3["electrical"]["peukert_c5_ah"]) < 225.0, "flooded gives less at C/5")
	_ok((d3["layout"]["enclosure"] as Dictionary).is_empty(), "a block is its own case")
	# An NMC cylinder pack: nickel, holders, the strip carries each cell's share.
	var d4 := BattDesign.solve(BattPresets.builtin("diy_13s4p_21700"))
	_ok(str(d4["interconnect"]) == "nickel", "cylinders joined with nickel")
	_ok(not (d4["layout"]["holders"] as Array).is_empty(), "cylinders sit in holders")
	_ok(str(d4["electrical"]["limit_by"]) != "links", "the nickel is sized for the cells")
	_near(float(d4["electrical"]["v_max"]), 13.0 * 4.2, 1e-6, "13S NMC full 54.6 V")
	# A typed arrangement is kept.
	var sp := BattPresets.builtin("diy_16s_280")
	sp["arrange"] = {"cols": 16, "rows": 1, "layers": 1, "face": "x", "orient": "up"}
	var d5 := BattDesign.solve(sp)
	_ok(int(d5["arrange"]["cols"]) == 16 and int(d5["arrange"]["rows"]) == 1, "a typed arrangement is kept")
	var b5: AABB = d5["layout"]["cells_box"]
	_ok(b5.size.x > 16.0 * 71.0, "one long row of 16")
	# A BMS that cannot take 24S is an error.
	var sp6 := BattPresets.builtin("diy_16s_280")
	sp6["series"] = 24
	sp6["bms"] = {"id": "jbd_16s_100a"}
	var d6 := BattDesign.solve(sp6)
	_ok((d6["checks"] as Array).any(func(c): return str(c["level"]) == "error" and str(c["text"]).contains("8–16")),
			"24S on a 16S BMS is an error")
	# 40S: only the Batrium takes it.
	var sp7 := BattPresets.builtin("diy_16s_280")
	sp7["series"] = 40
	sp7["bms"] = {"id": ""}
	var d7 := BattDesign.solve(sp7)
	_ok(str(d7["bms_id"]) == "batrium_watchmon", "40S falls to the Batrium")


func _test_spec_key() -> void:
	var sp := BattPresets.builtin("rack_48v_105")
	var back: Variant = JSON.parse_string(JSON.stringify(sp))
	_ok(BattSpec.key_of(back as Dictionary) == BattSpec.key_of(sp), "key survives JSON")
	var r := BattSpec.resolve({"series": 999, "parallel": -3, "form": "nope", "cell_id": "nope"})
	_ok(int(r["series"]) == BattSpec.MAX_SERIES and int(r["parallel"]) == 1, "series and parallel clamped")
	_ok(str(r["form"]) == "diy" and str(r["cell_id"]) == "eve_lf280k", "unknown form / cell fall back")
	BattDesign.clear_cache()
	var a := BattDesign.solve(sp)
	var b := BattDesign.solve(sp)
	_ok(is_same(a, b), "solve is cached")


func _test_builder() -> void:
	var d := BattDesign.solve(BattPresets.builtin("rack_48v_105"))
	var b := BattBuilder.build_from_design(d)
	_ok(b.cell_count() == 16, "builder draws 16 cells")
	_ok(b.get_node_or_null("Links") != null and b.get_node_or_null("Harness") != null, "links and harness drawn")
	_ok(b.get_node_or_null("Bms/Board") != null, "BMS drawn")
	_ok(b.get_node_or_null("Case/case_lid") != null, "case drawn")
	_ok(b.get_node_or_null("Fittings/breaker") != null, "breaker drawn")
	var parts: Array = b.get_meta("parts")
	_ok(parts.filter(func(p): return str(p["kind"]) == "cell").size() == 16, "every cell is pickable")
	_ok(parts.any(func(p): return str(p["kind"]) == "bms"), "the BMS is pickable")
	b.set_cutaway(true)
	_ok(not (b.get_node("Case/case_lid") as Node3D).visible, "cutaway lifts the lid")
	_ok((b.get_node("Case/case_back") as Node3D).visible, "cutaway keeps the back")
	var bm: AABB = b.get_meta("bounds_m")
	var hit := b.pick(Vector3(0, bm.end.y + 1.0, 0), Vector3.DOWN)
	_ok(not hit.is_empty() and str(hit["kind"]) != "case", "a ray from above hits a part, not the case, in cutaway (%s)" % hit.get("kind", "-"))
	b.set_cutaway(false)
	var hit2 := b.pick(Vector3(0, bm.end.y + 1.0, 0), Vector3.DOWN)
	_ok(str(hit2.get("id", "")) == "case_lid", "with the lid on, the ray hits the lid")
	var lid := b.get_node("Case/case_lid") as Node3D
	b.set_explode(0.0)
	var y0 := lid.position.y
	b.set_explode(1.0)
	_near(b.get_explode(), 1.0, 1e-9, "explode set")
	_ok(lid.position.y > y0 + 0.1, "exploding lifts the lid")
	b.free()
	# A lead block shows its cells and plates in cutaway.
	var d2 := BattDesign.solve(BattPresets.builtin("agm_12v_100"))
	var b2 := BattBuilder.build_from_design(d2)
	var inner := b2.get_node_or_null("Inner") as Node3D
	_ok(inner != null and not inner.visible, "a lead block's inside is hidden")
	var ic := inner.get_node("InnerCells") as MultiMeshInstance3D
	_ok(ic.multimesh.instance_count == 6, "a 12 V block has six 2 V cells inside")
	var pl := inner.get_node("Plates") as MultiMeshInstance3D
	_ok(pl.multimesh.instance_count == 42, "seven plates in each cell")
	b2.set_cutaway(true)
	_ok(inner.visible, "cutaway shows the inside")
	b2.free()
	var b3 := BattBuilder.build_from_design(BattDesign.solve(BattPresets.builtin("fla_6v_225")))
	_ok(b3.get_node_or_null("VentCaps") != null, "a flooded block has vent caps")
	b3.free()
	for bi in BattPresets.builtins():
		var bb := BattBuilder.build_from_design(BattDesign.solve((bi as Dictionary)["spec"]))
		_ok(bb.cell_count() == int(bb.design["spec"]["series"]) * int(bb.design["spec"]["parallel"]),
				"%s builds every cell" % (bi as Dictionary)["id"])
		bb.free()


# ---------------------------------------------------------------------------
# Phase 3: the BMS logic, by hand
# ---------------------------------------------------------------------------

func _rd(cells: Array, i: float, tmax: float = 25.0, tmin: float = 25.0) -> Dictionary:
	return {"cell_v": PackedFloat64Array(cells), "i_a": i, "t_max": tmax, "t_min": tmin, "cap_ah": 100.0}


func _cells(v: float, n: int = 16, one: float = -1.0) -> Array:
	var a: Array = []
	for k in n:
		a.append(v)
	if one > 0.0:
		a[3] = one
	return a


func _test_bms_logic() -> void:
	var bms := BattBms.get_bms("jbd_16s_100a")
	var p := BattBms.params("jbd_16s_100a", "LFP")
	# Over-voltage: 1 s delay, a break resets the timer, release at 3.40 V.
	var st := BattBmsLogic.new_state(0.5)
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3, 16, 3.70), 0.0), 0.5, 0.0)
	_ok(not bool(st["trips"]["cell_ov"]), "OV not tripped after 0.5 s of a 1 s delay")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0), 0.5, 0.5)
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3, 16, 3.70), 0.0), 0.5, 1.0)
	_ok(not bool(st["trips"]["cell_ov"]), "a break in the over-voltage resets its delay")
	var ev := BattBmsLogic.step(st, p, bms, _rd(_cells(3.3, 16, 3.70), 0.0), 0.5, 1.5)
	_ok(bool(st["trips"]["cell_ov"]) and ev.size() == 1 and str(ev[0]["key"]) == "cell_ov", "OV trips after 1 s past 3.65 V")
	_ok(not bool(st["chg"]) and bool(st["dsg"]), "OV opens the charge switch only")
	_near(BattBmsLogic.allowed_current(st, 20.0), 0.0, 1e-9, "no charge with the charge switch open")
	_near(BattBmsLogic.allowed_current(st, -20.0), -20.0, 1e-9, "a load still runs with the charge switch open")
	_near(float(st["soc_est"]), 1.0, 1e-9, "an OV trip sets the counted SOC to 100 %")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3, 16, 3.45), 0.0), 0.5, 2.0)
	_ok(bool(st["trips"]["cell_ov"]), "OV holds above its 3.40 V release (hysteresis)")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3, 16, 3.39), 0.0), 0.5, 2.5)
	_ok(not bool(st["trips"]["cell_ov"]) and bool(st["chg"]), "OV releases below 3.40 V")
	# Under-voltage: opens discharge only; a charger releases it.
	st = BattBmsLogic.new_state(0.5)
	for k in 2:
		BattBmsLogic.step(st, p, bms, _rd(_cells(3.0, 16, 2.4), -5.0), 0.5, float(k) * 0.5)
	_ok(bool(st["trips"]["cell_uv"]) and bool(st["chg"]) and not bool(st["dsg"]), "UV opens the discharge switch only")
	_near(float(st["soc_est"]), 0.0, 1e-9, "a UV trip sets the counted SOC to 0 %")
	_near(BattBmsLogic.allowed_current(st, 15.0), 15.0, 1e-9, "a charger can still fill it")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.0, 16, 2.6), 0.0), 0.5, 1.5)
	_ok(bool(st["trips"]["cell_uv"]), "UV holds at rest below its 2.90 V release")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.0, 16, 2.6), 10.0), 0.5, 2.0)
	_ok(not bool(st["trips"]["cell_uv"]), "a charging current releases UV")
	# Discharge over-current: 10 s past 100 A, retry 30 s later.
	st = BattBmsLogic.new_state(0.5)
	var tripped_at := -1.0
	for k in 41:
		var t := float(k) * 0.5
		BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), -110.0), 0.5, t)
		if tripped_at < 0.0 and bool(st["trips"]["discharge_oc"]):
			tripped_at = t
	_near(tripped_at, 9.5, 1e-6, "discharge OC trips once 10 s have passed (20 steps of 0.5 s)")
	_ok(not bool(st["dsg"]) and bool(st["chg"]), "discharge OC opens the discharge switch")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0), 0.5, tripped_at + 29.0)
	_ok(bool(st["trips"]["discharge_oc"]), "still open 29 s after the trip")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0), 0.5, tripped_at + 30.0)
	_ok(not bool(st["trips"]["discharge_oc"]), "retries 30 s after the trip")
	# Short circuit: 300 µs past 5 × the rating; both switches.
	st = BattBmsLogic.new_state(0.5)
	var sc_at := -1.0
	for k in 10:
		var t := float(k) * 0.0001
		BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), -600.0), 0.0001, t)
		if sc_at < 0.0 and bool(st["trips"]["short_circuit"]):
			sc_at = t
	_near(sc_at, 0.0002, 1e-9, "a short trips once 300 µs have passed (third 100 µs step)")
	_ok(not bool(st["chg"]) and not bool(st["dsg"]), "a short opens both switches")
	# Temperatures.
	st = BattBmsLogic.new_state(0.5)
	for k in 10:
		BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0, 56.0, 30.0), 0.5, float(k) * 0.5)
	_ok(bool(st["trips"]["charge_ot"]) and not bool(st["chg"]) and bool(st["dsg"]), "56 °C stops charging, not discharging")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0, 52.0, 30.0), 0.5, 6.0)
	_ok(bool(st["trips"]["charge_ot"]), "charge OT holds above its 50 °C release")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0, 49.0, 30.0), 0.5, 6.5)
	_ok(not bool(st["trips"]["charge_ot"]), "charge OT releases below 50 °C")
	st = BattBmsLogic.new_state(0.5)
	for k in 10:
		BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0, -1.0, -1.0), 0.5, float(k) * 0.5)
	_ok(bool(st["trips"]["charge_ut"]) and not bool(st["chg"]) and bool(st["dsg"]),
		"LFP below 0 °C: charging stopped, discharging allowed")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0, 4.0, 4.0), 0.5, 5.0)
	_ok(bool(st["trips"]["charge_ut"]), "charge UT holds below its 5 °C release")
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 0.0, 6.0, 6.0), 0.5, 5.5)
	_ok(not bool(st["trips"]["charge_ut"]), "charge UT releases above 5 °C")
	_ok(BattBmsLogic.describe(st).begins_with("Both switches closed"), "describe: nothing tripped")
	# Coulomb counting.
	st = BattBmsLogic.new_state(0.5)
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 50.0), 3600.0, 0.0)
	_near(float(st["soc_est"]), 1.0, 1e-9, "50 A for an hour into 100 Ah from 50 % counts to full (clamped)")
	st = BattBmsLogic.new_state(0.5)
	BattBmsLogic.step(st, p, bms, _rd(_cells(3.3), 10.0), 3600.0, 0.0)
	_near(float(st["soc_est"]), 0.5 + 0.1 * (1.0 + BattBmsLogic.SHUNT_GAIN_ERR), 1e-9, "10 Ah counts 10 % with the shunt's gain error")
	# Balancing.
	var pb := BattBms.balance_for("jbd_16s_100a", "LFP")
	var bv := BattBmsLogic.balance(pb, PackedFloat64Array([3.42, 3.45, 3.43, 3.42]), 0.0)
	_near(bv[1], 0.05, 1e-9, "passive: the high group bleeds 50 mA")
	_near(bv[0] + bv[2] + bv[3], 0.0, 1e-9, "passive: groups within 15 mV of the lowest are left alone")
	bv = BattBmsLogic.balance(pb, PackedFloat64Array([3.42, 3.45, 3.43, 3.42]), -5.0)
	_near(bv[1], 0.0, 1e-9, "passive: no bleeding while discharging")
	bv = BattBmsLogic.balance(pb, PackedFloat64Array([3.32, 3.35, 3.33, 3.32]), 0.0)
	_near(bv[1], 0.0, 1e-9, "passive: no bleeding below the 3.40 V start")
	var ab := BattBms.balance_for("jk_b2a24s15p", "LFP")
	bv = BattBmsLogic.balance(ab, PackedFloat64Array([3.42, 3.45, 3.43, 3.41]), 0.0)
	_near(bv[1], 2.0, 1e-9, "active: 2 A out of the highest")
	_near(bv[3], -2.0 * BattBmsLogic.ACTIVE_EFF * 3.45 / 3.41, 1e-9, "active: into the lowest at 90 %")


# ---------------------------------------------------------------------------
# Phase 3: the per-cell simulation
# ---------------------------------------------------------------------------

func _gap(r: Dictionary) -> float:
	var led: Dictionary = r["ledger"]
	return float(led["in_wh"]) - float(led["out_wh"]) - float(led["stored_wh"]) - float(led["heat_wh"]) - float(led["bleed_wh"])


func _first(r: Dictionary, key: String, what: String) -> float:
	for ev in (r["events"] as Array):
		if str(ev["key"]) == key and str(ev["what"]) == what:
			return float(ev["t"])
	return -1.0


func _test_sim() -> void:
	# Every built-in through every scenario it offers: frames, the ledger.
	for b in BattPresets.builtins():
		var d := BattDesign.solve((b as Dictionary)["spec"])
		for sc in BattSim.scenarios_for(bool(d["lithium"])):
			var r := BattSim.run(d, str(sc["id"]))
			_ok((r["frames"] as Array).size() > 10, "%s / %s keeps frames" % [b["id"], sc["id"]])
			var led: Dictionary = r["ledger"]
			var scale := maxf(1.0, float(led["in_wh"]) + float(led["out_wh"]))
			_ok(absf(_gap(r)) < 1e-6 * scale + 1e-6, "%s / %s energy ledger closes (%.2e Wh)" % [b["id"], sc["id"], _gap(r)])
	var rack := BattDesign.solve(BattPresets.builtin("rack_48v_105"))
	var ah := float(rack["electrical"]["ah"])
	# Charge from 20 %: about 80 % of the capacity goes in, then the charger stops.
	var ch := BattSim.run(rack, "charge")
	_near(float(ch["ledger"]["in_ah"]) / ah, 0.79, 0.04, "a charge from 20 % puts ~80 % of the Ah in")
	_ok(float(ch["full_at"]) > 0.0, "the charger finds it full")
	var st_abs := _first(ch, "charger", "stage")
	var done := _first(ch, "charger", "done")
	_ok(st_abs > 0.0 and done > st_abs, "constant current, then constant voltage, then done")
	# Repeatable.
	var ch2 := BattSim.run(rack, "charge")
	_near(float((ch2["frames"] as Array)[-1]["v"]), float((ch["frames"] as Array)[-1]["v"]), 1e-12, "a run is repeatable")
	# Discharge from full: about the rated Ah out, stopped by UV.
	var dc := BattSim.run(rack, "discharge")
	_near(float(dc["ledger"]["out_ah"]) / ah, 0.98, 0.03, "a discharge from full gives ~the rated Ah")
	_ok(_first(dc, "cell_uv", "trip") > 0.0, "the BMS stops it at a cell's under-voltage")
	var after_uv := true
	var t_uv := _first(dc, "cell_uv", "trip")
	for f in (dc["frames"] as Array):
		if float(f["t"]) > t_uv + 30.0 and float(f["i"]) < -0.01:
			after_uv = false
	_ok(after_uv, "no current out after the UV trip")
	# A weak cell stops the whole pack sooner.
	var wk := BattSim.run(rack, "weak")
	var ratio := float(wk["ledger"]["out_ah"]) / float(dc["ledger"]["out_ah"])
	_ok(ratio > 0.7 and ratio < 0.9, "one 80 %% cell cuts the pack to about 80 %% (%.2f)" % ratio)
	# Cold morning: the charge waits for the cells to warm past 5 °C.
	var cd := BattSim.run(rack, "cold")
	var ut := _first(cd, "charge_ut", "trip")
	var ur := _first(cd, "charge_ut", "release")
	_ok(ut >= 0.0 and ut < 60.0, "charging blocked at once at −5 °C")
	_ok(ur > ut, "released once the cells warm up")
	var blocked := true
	for f in (cd["frames"] as Array):
		if float(f["t"]) > ut + 10.0 and float(f["t"]) < ur and float(f["i"]) > 0.01:
			blocked = false
	_ok(blocked, "no charge current while it is too cold")
	var warm_ok := false
	for f in (cd["frames"] as Array):
		if float(f["t"]) > ur + 60.0 and float(f["i"]) > 1.0:
			warm_ok = true
	_ok(warm_ok, "charging resumes once warm")
	# Overload: trip at 10 s, retry 30 s later, trip again.
	var ol := BattSim.run(rack, "overload")
	var oc := _first(ol, "discharge_oc", "trip")
	_near(oc, 10.0, 0.5, "1.3 × the rating trips after the 10 s delay")
	_near(_first(ol, "discharge_oc", "release"), oc + 30.0, 0.5, "and retries 30 s later")
	# Short: lithium opens in 0.3 ms; lead-acid does not stop.
	var sh := BattSim.run(rack, "short")
	var sct := _first(sh, "short_circuit", "trip")
	_near(sct - float(sh["plan"]["short_at"]), 0.0003, 0.00002, "the BMS opens 0.3 ms into the short")
	_near(float((sh["frames"] as Array)[-1]["i"]), 0.0, 1e-9, "no current after the trip")
	_ok(-float(sh["i_peak"]) > 5.0 * 100.0, "the short drew more than 5 × the BMS rating")
	var agm := BattDesign.solve(BattPresets.builtin("agm_12v_100"))
	var sh2 := BattSim.run(agm, "short")
	_ok(_first(sh2, "short", "trip") > 0.0, "lead-acid short: the log says nothing stops it")
	_ok(float((sh2["frames"] as Array)[-1]["i"]) < -1000.0, "lead-acid short: still over 1000 A at the end")
	# Lead-acid charger stages in order.
	var lc := BattSim.run(agm, "charge")
	var stages: Array = []
	for ev in (lc["events"] as Array):
		if str(ev["key"]) == "charger":
			stages.append(str(ev["text"]).contains("float"))
	_ok(stages.size() >= 2 and not bool(stages[0]) and bool(stages[1]), "lead-acid: bulk → absorb → float")
	_ok(BattSim.scenarios_for(false).size() < BattSim.scenarios_for(true).size(), "lead-acid is offered fewer scenarios")
	# Active balancing evens out a spread.
	var diy := BattDesign.solve(BattPresets.builtin("diy_16s_280"))
	var bl := BattSim.run(diy, "balance")
	var f0: Dictionary = (bl["frames"] as Array)[0]
	var f1: Dictionary = (bl["frames"] as Array)[-1]
	var s0 := BattSim._max(f0["cell_soc"]) - BattSim._min(f0["cell_soc"])
	var s1 := BattSim._max(f1["cell_soc"]) - BattSim._min(f1["cell_soc"])
	_ok(s1 < s0 * 0.4, "active balancing narrows a %.1f %% spread to %.2f %%" % [s0 * 100.0, s1 * 100.0])
	_ok(float(bl["spread_mv"]) < 15.0, "the cells end within 15 mV (%.0f)" % float(bl["spread_mv"]))
	# frame_at and time words.
	var mid := float((ch["frames"] as Array)[50]["t"])
	_near(float(BattSim.frame_at(ch, mid + 1.0)["t"]), mid, 1e-9, "frame_at finds the frame at or before")
	_ok(BattSim.time_words(0.0003) == "0.30 ms" and BattSim.time_words(45.0) == "45 s", "time words")
	# Speed: ten hours of a 16-cell pack.
	var t0 := Time.get_ticks_msec()
	BattSim.run(diy, "balance")
	_ok(Time.get_ticks_msec() - t0 < 1000, "10 h of lab time runs in under a second")


func _bank(pid: String, s: int, p: int, patch: Dictionary = {}) -> Dictionary:
	var b := BankSpec.of_pack(BattPresets.builtin(pid), s, p, "Test bank")
	for k in patch:
		b[k] = patch[k]
	return BankDesign.solve(b)


func _has_level(d: Dictionary, level: String, words: String) -> bool:
	for c in (d["checks"] as Array):
		if str(c["level"]) == level and str(c["text"]).find(words) >= 0:
			return true
	return false


func _max_mm2(d: Dictionary, kind: String) -> float:
	var m := 0.0
	for cb in (d["cables"] as Array):
		if str(cb["kind"]) == kind:
			m = maxf(m, float(cb["mm2"]))
	return m


func _test_bank() -> void:
	# Spec round trip + the key.
	var b := BankSpec.of_pack(BattPresets.builtin("rack_48v_105"), 1, 4, "K")
	var rb := BankSpec.resolve(b)
	var back: Dictionary = JSON.parse_string(JSON.stringify(rb))
	_ok(BankSpec.key_of(rb) == BankSpec.key_of(BankSpec.resolve(back)), "bank key survives JSON")
	_ok(str(rb["mount"]) in BankSpec.MOUNTS, "bank mount resolves")
	# Numbers by hand: 1S4P of 51.2 V 105 Ah.
	var d := _bank("rack_48v_105", 1, 4)
	var e: Dictionary = d["electrical"]
	_near(float(e["v_nom"]), 51.2, 0.01, "1S4P bank voltage")
	_near(float(e["ah"]), 420.0, 0.5, "1S4P bank Ah")
	_near(float(e["wh"]), 51.2 * 420.0, 2.0, "1S4P bank Wh")
	_ok(int(e["packs"]) == 4, "four packs")
	_ok(str(d["mount"]) == "cabinet", "a rack pack goes in a cabinet")
	_ok((d["packs"] as Array).size() == 4, "four pack places")
	var ok_cables := true
	for cb in (d["cables"] as Array):
		if float(cb["len_mm"]) <= 0.0 or float(cb["r_ohm"]) <= 0.0 or str(cb["gauge"]).is_empty():
			ok_cables = false
	_ok(ok_cables, "every cable measured, sized and resistive")
	var sum := 0.0
	for st in (d["strings"] as Array):
		sum += float(st["share"])
	_near(sum, 1.0, 1e-6, "string shares sum to 1")
	_ok(float(e["max_share"]) - float(e["min_share"]) < 0.05, "diagonal wiring shares evenly")
	var se := _bank("rack_48v_105", 1, 4, {"wiring": "same_end", "bus": "busbar"})
	var dg := _bank("rack_48v_105", 1, 4, {"wiring": "diagonal", "bus": "busbar"})
	var spread_se := float(se["electrical"]["max_share"]) - float(se["electrical"]["min_share"])
	var spread_dg := float(dg["electrical"]["max_share"]) - float(dg["electrical"]["min_share"])
	_ok(spread_se >= spread_dg - 1e-9, "same-end busbar shares no better than diagonal")
	var d1 := _bank("rack_48v_105", 1, 1)
	_ok(float(e["i_sc"]) > float(d1["electrical"]["i_sc"]), "four strings fault harder than one")
	_ok(float(e["i_sc"]) > 1000.0, "a 48 V rack bank can push thousands of amps into a short")
	var fz: Dictionary = d["fuse"]
	_ok(not fz.is_empty() and float(fz.get("v", 0.0)) >= float(e["v_max"]), "auto fuse rated for the bank voltage")
	_ok(float(fz.get("amps", 0.0)) >= 1.25 * float(e["string_a"]) - 0.5, "fuse at 125 % of the string current or more")
	_ok(str(fz.get("type", "")) == "class_t", "a 48 V bank with a big fault current gets Class T")
	_ok(_has_level(_bank("rack_48v_105", 1, 4, {"fuse": "anl"}), "error", "V DC"), "an ANL fuse on a 48 V bank is an error")
	_ok(_has_level(_bank("rack_48v_105", 1, 2, {"fuse": "none"}), "error", "No fuse"), "no fuse on lithium is an error")
	var lead_nf := _bank("agm_12v_100", 4, 1, {"fuse": "none"})
	_ok(_has_level(lead_nf, "warn", "No fuse"), "no fuse on lead is a warning")
	_near(float(lead_nf["electrical"]["v_nom"]), 48.0, 0.01, "4S AGM is 48 V")
	_ok(not _has_level(lead_nf, "error", "series"), "lead-acid can go in series")
	var rs := _bank("rack_48v_105", 2, 1)
	_ok(_has_level(rs, "error", "series"), "rack packs in series are an error")
	_ok(_has_level(rs, "info", "60 V"), "a 102 V bank says it is a shock hazard")
	_ok(str(_bank("wall_48v_314", 1, 2)["mount"]) == "wall", "a wall pack goes on the wall")
	_ok(str(_bank("rolling_48v_314", 1, 1)["mount"]) == "floor", "a rolling pack stands on the floor on its own wheels")
	_ok(str(_bank("agm_12v_100", 4, 2)["mount"]) in ["shelf", "floor"], "lead blocks sit on a shelf or the floor")
	_ok(_has_level(_bank("fla_6v_225", 8, 1), "info", "Ventilate"), "flooded batteries need ventilation")
	_ok(_has_level(_bank("rack_48v_105", 1, 16), "error", "42U"), "sixteen 3U packs don't fit one 42U cabinet")
	var mm_near := _max_mm2(_bank("rack_48v_105", 1, 4, {"main_run_m": 1.0}), "main")
	var mm_far := _max_mm2(_bank("rack_48v_105", 1, 4, {"main_run_m": 8.0}), "main")
	_ok(mm_far >= mm_near and mm_near > 0.0, "a longer main run never gets a thinner cable")
	# BOM.
	var bom := BattBom.bank(d)
	var tot := 0.0
	for r in (bom["rows"] as Array):
		tot += float(r["total_usd"])
	_near(float(bom["total_usd"]), tot, 0.5, "BOM total is the sum of its rows")
	_ok(BattBom.csv(bom).split("\n").size() > (bom["rows"] as Array).size(), "BOM CSV has a row per line")
	# Exports.
	var svg := BankExport.single_line_svg(d)
	_ok(svg.find("<svg") >= 0, "single-line diagram is SVG")
	_ok(svg.find("Class T") >= 0, "single-line names the fuse")
	_ok(BankExport.cables_csv(d).split("\n").size() > (d["cables"] as Array).size(), "cable CSV has every cable")
	_ok(not BankExport.slug("Shed bank #2").is_empty() and BankExport.slug("Shed bank #2").find(" ") < 0, "export slug")
	# Graph + packing.
	var g := BankDesign.graph_specs(d)
	_near(float(g["kwh"]), float(e["wh"]) * 0.001, 0.002, "graph kWh")
	_ok(float(g["max_charge_a"]) > 0.0 and float(g["max_discharge_a"]) > 0.0, "graph carries BMS current limits")
	_ok(int(g["bank_parallel"]) == 4, "graph carries the bank shape")
	_ok(int(BankDesign.packed_spec(d)["count"]) == 4, "packs ship as four crates")
	# EnergyTimeline limits: INF is the old step exactly; a limit clips.
	var a1 := EnergyTimeline.step_soc(5.0, 3.0, 0.0, 1.0, 0.25, 10.0, 0.95, 0.95, 1.0)
	var a2 := EnergyTimeline.step_soc_lim(5.0, 3.0, 0.0, 1.0, 0.25, 10.0, 0.95, 0.95, 1.0, INF, INF)
	_ok(a1 == a2, "no limits = the old step, bit for bit")
	var a3 := EnergyTimeline.step_soc_lim(5.0, 3.0, 0.0, 1.0, 0.25, 10.0, 0.95, 0.95, 1.0, 1.0, INF)
	_near(a3, 5.0 + 1.0 * 0.25 * 0.95, 1e-9, "charge clipped to the BMS limit")
	var a4 := EnergyTimeline.step_soc_lim(5.0, 0.0, 0.0, 3.0, 0.25, 10.0, 0.95, 0.95, 1.0, INF, 2.0)
	_ok(a4 > EnergyTimeline.step_soc(5.0, 0.0, 0.0, 3.0, 0.25, 10.0, 0.95, 0.95, 1.0), "discharge clipped to the BMS limit")
	_near(EnergyTimeline.clip_net(2.0, 0.0, INF), 0.0, 1e-12, "a cold block charges nothing")
	_near(EnergyTimeline.clip_net(-2.0, INF, 0.5), -0.5, 1e-12, "discharge clip")
	# Builder.
	var bb := BankBuilder.build_from_design(d)
	_ok(bb.pack_count() == 4, "builder draws four packs")
	var parts: Array = bb.get_meta("parts", [])
	var kinds := {}
	for pt in parts:
		kinds[str(pt["kind"])] = true
	_ok(kinds.has("pack") and kinds.has("cabinet"), "builder lists packs and the cabinet")
	_ok(parts.size() > 0 and not bb.part(str(parts[0]["id"])).is_empty(), "builder finds a part by id")
	var pk: Dictionary = bb.part("pack_0")
	_ok(not pk.is_empty(), "pack_0 is a part")
	if not pk.is_empty():
		var c := (pk["aabb"] as AABB).get_center()
		_ok(not bb.pick(c + Vector3(0, 0, 5), Vector3(0, 0, -1)).is_empty(), "a ray from the front picks something")
	else:
		_ok(false, "a ray from the front picks something")
	bb.highlight(["pack_0"])
	_ok(bb.highlighted_count() >= 1, "highlight lights a pack")
	bb.set_cutaway(true)
	_ok(bb.find_child("CollisionMesh", true, false) != null, "builder makes a collision mesh")
	bb.free()
	# A 100-pack bank.
	var t0 := Time.get_ticks_usec()
	var huge := _bank("agm_12v_100", 4, 25, {"mount": "floor"})
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_ok((huge["packs"] as Array).size() == 100, "a 100-pack bank lays out")
	_ok(ms < 1500.0, "a 100-pack bank solves under 1.5 s")
	var t1 := Time.get_ticks_usec()
	var hb := BankBuilder.build_from_design(huge)
	var ms_b := float(Time.get_ticks_usec() - t1) / 1000.0
	_ok(hb.pack_count() == 100, "a 100-pack bank builds")
	hb.free()
	print("  100-pack bank: solve %.0f ms, build %.0f ms" % [ms, ms_b])


func _trip_keys(res: Dictionary, what: String = "trip") -> Array:
	var out: Array = []
	for ev in (res["events"] as Array):
		if str(ev["what"]) == what:
			out.append(str(ev["key"]))
	return out


func _ledger_ok(res: Dictionary, what: String) -> void:
	var led: Dictionary = res["ledger"]
	var gap := float(led["in_wh"]) - float(led["out_wh"]) - float(led["short_wh"]) - float(led["stored_wh"]) - float(led["heat_wh"])
	var scale := maxf(1.0, maxf(float(led["in_wh"]), float(led["out_wh"]) + float(led["short_wh"])))
	_ok(absf(gap) < 0.01 * scale + 0.01, "%s: the bank's energy ledger closes (%.3f Wh)" % [what, gap])


func _test_bank_bus_and_route() -> void:
	# Bus bars: auto carries 125 % of the bank current, stacking when one is not enough.
	var d := _bank("rack_48v_105", 1, 4)
	var bars: Dictionary = d["bars"]
	var i_bank := float(d["electrical"]["cont_discharge_a"])
	_ok(float(bars["amps"]) >= 1.25 * i_bank - 1.0, "auto bus bar carries 125 % of the bank (%.0f A for %.0f A)" % [float(bars["amps"]), i_bank])
	_ok(not _has_level(d, "warn", "busbars") and not _has_level(d, "error", "busbars"), "an auto bus raises no bus check")
	var big := _bank("rack_48v_230", 1, 8)
	_ok(int(big["bars"]["n"]) > 1, "a 1600 A bank stacks bars (%d)" % int(big["bars"]["n"]))
	_near(float(big["bars"]["amps"]), BattElectrical.busbar_amps(float(big["bars"]["w"]), float(big["bars"]["t"])) * float(BankDesign.STACK_FACTOR[int(big["bars"]["n"])]), 0.01, "stacked bars carry n × one × the DIN factor")
	var thin := _bank("rack_48v_105", 1, 4, {"bus_bar": "20x3", "bus_stack": 1})
	_ok(_has_level(thin, "error", "busbars"), "a 20 × 3 bar on a 400 A bank is an error")
	_ok(int(thin["bars"]["n"]) == 1 and is_equal_approx(float(thin["bars"]["w"]), 20.0), "the player's bar is used as given")
	var stack3 := _bank("rack_48v_105", 1, 4, {"bus_bar": "20x3", "bus_stack": 3})
	_ok(int(stack3["bars"]["n"]) == 3 and float(stack3["bars"]["amps"]) > float(thin["bars"]["amps"]) * 2.0, "three bars together carry more than twice one")
	var dist := _bank("rack_48v_230", 1, 6, {"bus": "distributor"})
	_ok(_has_level(dist, "error", "distributor"), "a 1171 A bank on a 1000 A distributor is an error")
	_ok(not _has_level(_bank("rack_48v_105", 1, 2, {"bus": "distributor"}), "error", "distributor"), "a 200 A bank on a distributor is fine")
	var bom := BattBom.bank(stack3)
	var bar_rows := 0.0
	for r in (bom["rows"] as Array):
		if str(r["item"]).begins_with("Copper busbar"):
			bar_rows = float(r["qty"])
	_ok(is_equal_approx(bar_rows, 6.0), "the BOM counts three bars a pole")
	# Fuse blow times: faster the harder it is driven, never under its clearing time.
	_ok(BankDesign.fuse_blow_s("class_t", 1.05) == INF, "a fuse at 1.05 × never blows")
	_ok(BankDesign.fuse_blow_s("class_t", 2.0) > BankDesign.fuse_blow_s("class_t", 10.0), "blows faster at 10 × than at 2 ×")
	_ok(BankDesign.fuse_blow_s("anl", 10.0) > BankDesign.fuse_blow_s("class_t", 10.0), "an ANL is slower than a Class T")
	_near(BankDesign.fuse_blow_s("class_t", 100.0), 0.001, 1e-9, "a Class T never clears faster than 1 ms")
	# Withstand: S = I √t / k by hand.
	var ws: Dictionary = d["withstand"]
	var i_str := float(d["electrical"]["i_sc"]) / 4.0
	var t := BankDesign.fuse_blow_s(str(d["fuse"]["type"]), i_str / float(d["fuse"]["amps"]))
	_near(float(ws["t_clear"]), t, 1e-9, "withstand uses the fuse's blow time")
	_ok(bool(ws["ok"]), "the rack bank's cables and bars survive a bus short")
	_near(float(ws.get("bar_need_mm2", 0.0)), float(d["electrical"]["i_sc"]) * sqrt(t) / BankDesign.K_BAR, 1e-6, "bar need = I√t / 159")
	# The main run routed in 3D.
	var rt := _bank("rack_48v_105", 1, 4, {"main_routed_m": 7.5})
	var main_c: Dictionary = {}
	for cb in (rt["cables"] as Array):
		if str(cb["id"]) == "main_pos":
			main_c = cb
	_ok(bool(rt["main_routed"]) and bool(main_c.get("routed", false)), "a routed run is marked routed")
	_near(float(main_c["len_mm"]), 7500.0 + BankDesign.LUG_SLACK_MM, 0.01, "the routed length is the cable's length")
	_ok(((main_c["pts"] as Array)[1] as Vector3).distance_to((main_c["pts"] as Array)[0]) <= BankDesign.ROUTED_STUB_MM + 0.01, "the bank draws only a stub of a routed run")
	var typed := _bank("rack_48v_105", 1, 4, {"main_run_m": 2.0})
	_ok(float(main_c["r_ohm"]) > float((typed["cables"] as Array).filter(func(c: Dictionary) -> bool: return str(c["id"]) == "main_pos")[0]["r_ohm"]), "a longer routed run has more resistance")
	var r2 := BankSpec.resolve({"main_routed_m": 0.0, "bus_bar": "nonsense", "bus_stack": 9})
	_ok(float(r2["main_routed_m"]) == -1.0 and str(r2["bus_bar"]) == "auto" and int(r2["bus_stack"]) == BankSpec.MAX_STACK, "spec keys clamp")


func _test_bank_sim() -> void:
	var d := _bank("rack_48v_105", 1, 4)
	_ok(BankSim.scenarios_for(true).size() == 6 and BankSim.scenarios_for(false).size() == 5, "scenario lists (no cold for lead)")
	# Share: every string near a quarter, bank down at the end.
	var sh := BankSim.run(d, "share")
	_ledger_ok(sh, "share")
	_ok(float(sh["share_max"]) < 0.27, "diagonal wiring: no string over 27 %% of the load (%.1f %%)" % (float(sh["share_max"]) * 100.0))
	_ok(float(sh["down_t"]) > 3600.0, "share: the bank runs over an hour at 0.5 C")
	var fr: Array = sh["frames"]
	_ok(fr.size() > 50 and fr.size() <= BankSim.MAX_FRAMES + 2, "share keeps frames")
	_ok(float(fr[1]["v"]) > 48.0 and float(fr[1]["v"]) < 56.0, "the bus sits near the bank's voltage (%.1f V)" % float(fr[1]["v"]))
	# Weak cell: its string trips on under-voltage, then the rest trip on over-current.
	var wk := BankSim.run(d, "weak")
	_ledger_ok(wk, "weak")
	var first: Dictionary = {}
	for ev in (wk["events"] as Array):
		if str(ev["what"]) == "trip":
			first = ev
			break
	_ok(str(first.get("key", "")) == "cell_uv" and str(first.get("where", "")) == "pack_0", "weak: the weak pack's BMS trips first, on its weak cell")
	_ok(_trip_keys(wk).has("discharge_oc"), "weak: the others are pushed over their current and trip (a cascade)")
	_ok(float(wk["down_t"]) > 0.0 and float(wk["down_t"]) < float(sh["down_t"]), "weak: the bank goes down sooner than a healthy one")
	# Unequal strings: current flows from the full strings into the empty one, with no load.
	var un := BankSim.run(d, "unequal")
	_ledger_ok(un, "unequal")
	var f1: Dictionary = (un["frames"] as Array)[1]
	var ist: PackedFloat64Array = f1["i_str"]
	_ok(ist[0] > 1.0 and ist[1] < 0.0, "unequal: the empty string charges from the full ones (%.0f A)" % ist[0])
	_near(float(f1["i"]), 0.0, 1e-6, "with no load the strings' currents sum to zero")
	# Cold string with the comms chain: blocked, and the rest charge without tripping.
	var cd := BankSim.run(d, "cold")
	_ledger_ok(cd, "cold")
	_ok(_trip_keys(cd).has("charge_ut"), "cold: the cold string's BMS refuses the charge")
	_ok(not _trip_keys(cd).has("charge_oc"), "cold with comms: the charger stays inside the other strings' rating")
	_ok(float(cd["ledger"]["in_wh"]) > 5000.0, "cold with comms: the bank still charges")
	var cdn := BankSim.run(_bank("rack_48v_105", 1, 4, {"comms": false}), "cold")
	_ok(_trip_keys(cdn).has("charge_oc"), "cold without comms: the others are charged over their rating and trip")
	# Charge: CC, then holding the voltage, then full.
	var ch := BankSim.run(d, "charge")
	_ledger_ok(ch, "charge")
	_ok(float(ch["full_at"]) > 0.0, "charge: the bank fills")
	# Short: lithium BMSs open within ~2 ms before any fuse; lead's fuses blow.
	var st := BankSim.run(d, "short")
	_ledger_ok(st, "short")
	var sc_t := INF
	for ev in (st["events"] as Array):
		if str(ev["key"]) == "short_circuit":
			sc_t = minf(sc_t, float(ev["t"]))
	_ok(sc_t < 0.003, "short: the BMSs open within 2 ms of the short (%s)" % BattSim.time_words(sc_t))
	_ok(float(st["i_peak"]) < -1000.0, "short: thousands of amps flow first")
	var lead := _bank("agm_12v_100", 4, 2)
	var ls := BankSim.run(lead, "short")
	_ledger_ok(ls, "lead short")
	_ok(_trip_keys(ls).count("fuse") == 2, "lead short: both strings' fuses blow")
	var lsh := BankSim.run(lead, "share")
	_ledger_ok(lsh, "lead share")
	_ok(_trip_keys(lsh).has("lvd"), "lead: the inverter's low-voltage cutoff ends the run")
	_ledger_ok(BankSim.run(lead, "charge"), "lead charge (float included)")
	# A big bank runs in reasonable time.
	var t0 := Time.get_ticks_msec()
	var bigr := BankSim.run(_bank("agm_12v_100", 4, 25, {"mount": "floor"}), "share")
	var ms := Time.get_ticks_msec() - t0
	_ok(not (bigr["frames"] as Array).is_empty() and ms < 8000, "a 100-pack bank's run takes %d ms" % ms)
