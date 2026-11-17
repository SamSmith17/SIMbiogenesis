extends SceneTree

## TC Process Lab self-test (offline). Run --import first:
##   Godot --headless --path . --script core/tclab/process/tc_proc_selftest.gd
## Phase 0 — the fluid network: every part type has a flow-path rule (the
## coverage guard), every fluid port sits in exactly one circuit, and on the
## biochar reactor + condenser the vapour reaches "Woodgas out" through BOTH
## dephlegmator columns, the cooling water is its own circuit, the drains
## are the condenser's low points, the closing joint links the two columns,
## and the CV volumes add up to the BOM's wetted volume. Plus merging (a
## run of pipes is one CV, a closed loop of elbows too) and the filter /
## column roles.
## Phase 1: species, thermo, reactions. Boiling points against steam
## tables, the LHVs of CO / H2 / CH4, woodgas per Nm3, the CH4 flame, the
## ethanol / water azeotrope, natural-convection and condensing h in their
## textbook ranges, the shared CSP boil-off budget, Miller & Bellan wood
## pyrolysis on a slow ramp landing in slow-pyrolysis yield bands
## (Bridgwater 2012: char ~35 %, liquids ~30 %, gas ~35 %), tar cracking,
## plastic half-lives, O2-limited combustion and the desiccant.

const EXPECTED_CHECKS := 583

var _pass := 0
var _fail := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (%.4f vs %.4f)" % [what, a, b])


func _initialize() -> void:
	TcDesign.clear_cache()
	TcParts.clear_cache()
	TcProcNet.clear_cache()
	_test_coverage()
	_test_reactor_net()
	_test_merging()
	_test_roles()
	_test_species_thermo()
	_test_vle_heat()
	_test_reactions()
	_test_batch()
	_test_kettle()
	_test_pressure()
	_test_determinism()
	_test_control()
	_test_molecules()
	_test_summary()
	_test_units()
	_test_results_and_board()
	_test_scenarios()
	_test_liquid_lines()
	_test_liquid_plant()
	var total := _pass + _fail
	print("tc_proc selftest: %d passed, %d failed (%d checks)" % [_pass, _fail, total])
	if EXPECTED_CHECKS > 0 and total != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [total, EXPECTED_CHECKS])
		_fail += 1
	print("tc_proc selftest: ", "PASS" if _fail == 0 else "FAILED")
	quit(0 if _fail == 0 else 1)


## Ports that are deliberately not fluid.
func _non_fluid(type: String, port: Dictionary) -> bool:
	var id := str(port["id"])
	if str(port["kind"]) == "stem" or id.begins_with("air"):
		return true
	return type == "thermowell" and id == "b"


func _test_coverage() -> void:
	var missing: Array = []
	for t in TcParts.TYPES.keys():
		if not TcFlowPaths.TYPE_RULES.has(t):
			missing.append(t)
	_ok(missing.is_empty(), "every part type has a flow-path rule (missing %s)" % [missing])
	for t in TcParts.TYPE_ORDER:
		var size := "2" if t == "vessel" else "1.5"
		var built := TcParts.build(t, size, TcParts.default_params(t, size))
		var cs := TcFlowPaths.circuits(built)
		var seen := {}
		var dup := false
		var bad_role := false
		for c in cs:
			var r := str(c["role"])
			if not (TcFlowPaths.is_volume(r) or TcFlowPaths.is_link(r) or TcFlowPaths.is_attach(r)):
				bad_role = true
			for p in c["ports"]:
				if seen.has(p):
					dup = true
				seen[p] = true
		_ok(not dup, "%s: no port in two circuits" % t)
		_ok(not bad_role, "%s: every circuit has a known role" % t)
		var stray: Array = []
		for p in built["ports"]:
			if not seen.has(str(p["id"])) and not _non_fluid(t, p):
				stray.append(str(p["id"]))
		_ok(stray.is_empty(), "%s: every fluid port is in a circuit (stray %s)" % [t, stray])


func _reactor() -> Array:
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	return [d, TcProcNet.build(d)]


func _test_reactor_net() -> void:
	var dn := _reactor()
	var d: Dictionary = dn[0]
	var net: Dictionary = dn[1]
	var cvs: Array = net["cvs"]
	print("reactor net: %d CVs, %d links, %d boundaries, %d thermal" % [cvs.size(), (net["links"] as Array).size(),
		(net["boundaries"] as Array).size(), (net["thermal"] as Array).size()])
	for i in cvs.size():
		var cv: Dictionary = cvs[i]
		print("  cv%d %-10s %-40s V %.2f L  y %.0f..%.0f mm  %s" % [i, cv["role"], cv["label"], float(cv["volume_m3"]) * 1000.0,
			float(cv["y_low_mm"]), float(cv["y_high_mm"]), cv["parts"]])
	var finite := true
	for cv in cvs:
		finite = finite and is_finite(float(cv["y_low_mm"])) and is_finite(float(cv["y_high_mm"]))
	_ok(finite, "every control volume has a height range")
	_ok(cvs.size() >= 8 and cvs.size() <= 24, "the reactor is a few control volumes, not one per part (%d)" % cvs.size())
	_ok(TcProcNet.build(d) == net, "the net is cached per design")
	var vessel := TcProcNet.cv_of_part(net, "p1", "main")
	_ok(vessel >= 0 and str(cvs[vessel]["role"]) == "vessel", "the vessel is a CV")
	_ok((cvs[vessel]["heaters"] as Array).size() >= 1, "the heating element heats the vessel")
	var probe_parts: Array = []
	for pr in cvs[vessel]["probes"]:
		probe_parts.append(str(pr["part"]))
	_ok("p7" in probe_parts and "p8" in probe_parts, "the thermometer and gauge read the vessel (%s)" % [probe_parts])
	_ok((cvs[vessel]["heaters"] as Array).size() == 2, "two elements come up through the bottom into the charge")
	# Boundaries.
	var gas := TcProcNet.boundary_of_ref(net, "p20:b")
	_ok(str(gas.get("role", "")) == "product", "Woodgas out is the product outlet")
	for ref in ["p17:b", "p18:b"]:
		_ok(str(TcProcNet.boundary_of_ref(net, ref).get("role", "")) == "drain", "%s drains the condensate" % ref)
	_ok(str(TcProcNet.boundary_of_ref(net, "p1:crown").get("role", "")) == "feed", "the crown is the feed")
	var drain_b := TcProcNet.boundary_of_ref(net, "p5:b")
	_ok(str(drain_b.get("role", "")) == "drain", "the butterfly train drains the vessel")
	var bfly_closed := false
	for l in net["links"]:
		if str(l["part"]) == "p4":
			bfly_closed = not bool(l["open"])
	_ok(bfly_closed, "the closed butterfly is a shut link")
	var cool_roles := {}
	for b in net["boundaries"]:
		if str(b["role"]).begins_with("coolant"):
			cool_roles[str(b["role"])] = int(cool_roles.get(str(b["role"]), 0)) + 1
	_ok(int(cool_roles.get("coolant_in", 0)) == 3 and int(cool_roles.get("coolant_out", 0)) == 3,
		"three cooling-water circuits, each with an in and an out (%s)" % [cool_roles])
	# The vapour path.
	var out_cv := int(gas.get("cv", -1))
	var left := TcProcNet.cv_of_part(net, "p11", "product")
	var right := TcProcNet.cv_of_part(net, "p14", "product")
	var mid := TcProcNet.cv_of_part(net, "p19", "product")
	_ok(TcProcNet.reachable(net, vessel, out_cv), "the vapour reaches Woodgas out")
	_ok(TcProcNet.reachable(net, vessel, out_cv, [left]), "through the right column with the left blocked")
	_ok(TcProcNet.reachable(net, vessel, out_cv, [right]), "through the left column with the right blocked")
	_ok(not TcProcNet.reachable(net, vessel, out_cv, [left, right]), "and not with both columns blocked")
	_ok(not TcProcNet.reachable(net, vessel, out_cv, [mid]), "every path leaves through the gas column")
	# Cooling water is separate.
	var reg := TcProcNet.region(net, vessel)
	for pid in ["p11", "p14", "p19"]:
		var w := TcProcNet.cv_of_part(net, pid, "coolant")
		_ok(w >= 0 and not (w in reg), "%s's water jacket is not in the gas" % pid)
	var cond_links := 0
	var jacket_links := 0
	for t in net["thermal"]:
		if str(t["kind"]) == "condenser":
			cond_links += 1
			_ok(float(t["area_m2"]) > 0.01, "a condenser cools through its tube wall (%.3f m²)" % float(t["area_m2"]))
		elif str(t["kind"]) == "jacket":
			jacket_links += 1
	_ok(cond_links == 3, "three condensers cooled by their jackets (%d)" % cond_links)
	_ok(jacket_links == 1, "the boiler's jacket is a thermal layer (%d)" % jacket_links)
	# The closing joint p16:b ↔ p15:a links the columns' bottoms.
	var c16 := TcProcNet.cv_of_part(net, "p16")
	var c15 := TcProcNet.cv_of_part(net, "p15")
	var closing := false
	for l in net["links"]:
		var a := int(l["a"])
		var b := int(l["b"])
		if (a == c16 and b == c15) or (a == c15 and b == c16):
			closing = true
	_ok(closing, "the closing joint links the bottom tees")
	# Drains at the condenser's low points.
	var adj_skip := TcProcNet.neighbours(net, [vessel])
	var seen := {left: true}
	var q: Array = [left]
	var low := INF
	while not q.is_empty():
		var c := int(q.pop_front())
		low = minf(low, float(cvs[c]["y_low_mm"]))
		for n in adj_skip[c]:
			if not seen.has(n):
				seen[n] = true
				q.append(n)
	for ref in ["p17:b", "p18:b"]:
		var by := (TcProcNet.boundary_of_ref(net, ref)["pos_mm"] as Vector3).y
		_ok(by <= low + 40.0, "%s sits at the condenser's low point (%.0f vs %.0f mm)" % [ref, by, low])
	_ok((gas["pos_mm"] as Vector3).y > low + 200.0, "the gas leaves high, above the traps")
	# Volumes: the CVs hold the BOM's wetted volume (valves are links).
	var v := 0.0
	for cv in cvs:
		if not (str(cv["role"]) in ["coolant", "jacket"]):
			v += float(cv["volume_m3"])
	var bom_l := float(d["bom"]["volume_l"])
	_ok(v * 1000.0 <= bom_l + 0.01 and v * 1000.0 >= bom_l * 0.97, "the CVs hold the wetted volume (%.2f L vs BOM %.2f L)" % [v * 1000.0, bom_l])
	_near(float(cvs[vessel]["volume_m3"]) * 1000.0, PI * pow(170.0 - 2.0, 2) * 650.0 * 1e-6, 4.0, "the boiler holds about π r² h")


func _test_merging() -> void:
	var d := TcDesign.solve(TcPresets.builtin("elbow_run"))
	var net := TcProcNet.build(d)
	var vols := 0
	for cv in net["cvs"]:
		vols += 1
	_ok(vols == 1, "a run of spools and elbows is one control volume (%d)" % vols)
	var cv0: Dictionary = net["cvs"][0]
	_ok((cv0["parts"] as Array).size() >= 4, "it holds every pipe in the run (%d)" % (cv0["parts"] as Array).size())
	var blinds := 0
	for a in cv0["attach"]:
		if str(a["role"]) == "blind":
			blinds += 1
	_ok(blinds == 1, "the cap closes the run's end")
	_ok(float(cv0["length_m"]) > 0.3, "its centre line runs the whole length (%.2f m)" % float(cv0["length_m"]))
	var d2 := TcDesign.solve(TcPresets.builtin("square_loop"))
	var net2 := TcProcNet.build(d2)
	_ok((net2["cvs"] as Array).size() == 1, "a closed loop of elbows is one volume")
	_ok((net2["links"] as Array).is_empty(), "with no link inside it")


func _test_roles() -> void:
	var d := TcDesign.solve(TcPresets.builtin("filter_train"))
	var net := TcProcNet.build(d)
	var filters := 0
	for cv in net["cvs"]:
		if str(cv["role"]) == "filter":
			filters += 1
	_ok(filters >= 2, "the filter train's strainer and cartridge are filter volumes (%d)" % filters)
	var d2 := TcDesign.solve(TcPresets.builtin("pot_still"))
	var net2 := TcProcNet.build(d2)
	var packed := false
	for cv in net2["cvs"]:
		if str(cv["role"]) == "column" and cv.has("packing"):
			packed = true
	_ok(packed, "the pot still's column carries its packing")
	var vessel := -1
	for i in (net2["cvs"] as Array).size():
		if str(net2["cvs"][i]["role"]) == "vessel":
			vessel = i
	var outs := 0
	for b in net2["boundaries"]:
		if int(b["cv"]) >= 0 and TcProcNet.reachable(net2, vessel, int(b["cv"])):
			outs += 1
	_ok(outs >= 1, "the pot still's vapour has a way out (%d)" % outs)



func _test_species_thermo() -> void:
	for g in TcSpecies.GASES:
		var r := TcSpecies.row(g)
		_ok(float(r.get("M", 0.0)) > 0.0 and float(r.get("cp_g", 0.0)) > 0.0, "%s has a molar mass and cp" % g)
		_ok((r.get("mol", {}) as Dictionary).has("atoms") or r.has("unit"), "%s has a molecule to draw" % g)
	for s in TcSpecies.SOLIDS:
		_ok(float(TcSpecies.row(s).get("cp_s", 0.0)) > 0.0, "%s has a heat capacity" % s)
	var est := TcSpecies.estimates()
	_ok("tar" in est and "wax" in est, "the lumped tar and wax are flagged estimates (%s)" % [est])
	print("tc_species estimates: %s" % [est])
	_near(TcThermo.boiling_point_k("H2O", TcSpecies.P_ATM) - 273.15, 100.0, 0.3, "water boils at 100 C at 1 atm")
	_near(TcThermo.boiling_point_k("H2O", 150000.0) - 273.15, 111.4, 1.0, "and at 111 C at 1.5 bar (steam tables)")
	_near(TcThermo.boiling_point_k("H2O", 200000.0) - 273.15, 120.2, 1.0, "and at 120 C at 2 bar")
	_near(TcThermo.p_sat_pa("H2O", 298.15), 3169.0, 60.0, "water's vapour pressure at 25 C")
	_near(TcThermo.boiling_point_k("ethanol", TcSpecies.P_ATM) - 273.15, 78.37, 0.5, "ethanol boils at 78.4 C")
	var lo := TcThermo.p_sat_pa("ethanol", 273.15 + 78.0)
	var hi := TcThermo.p_sat_pa("ethanol", 273.15 + 81.0)
	_ok(hi > lo and hi / lo < 1.2, "ethanol's two Antoine ranges join smoothly")
	_near(TcThermo.boiling_point_k("acetic", TcSpecies.P_ATM) - 273.15, 118.1, 1.0, "acetic acid boils at 118 C")
	_near(TcThermo.boiling_point_k("oil", TcSpecies.P_ATM) - 273.15, 216.3, 0.2, "the dodecane oil cut boils at 216 C")
	_ok(TcThermo.dew_point_k("H2O", 20000.0) < TcThermo.dew_point_k("H2O", 60000.0), "more steam, a higher dew point")
	for k in [["CO", 10.10], ["H2", 119.96], ["CH4", 50.0]]:
		var mj := TcSpecies.lhv_j_per_mol(k[0]) / float(TcSpecies.row(k[0])["M"]) * 1e-3
		_near(mj, float(k[1]), float(k[1]) * 0.01, "%s LHV %.2f MJ/kg" % [k[0], float(k[1])])
	var producer := {"CO": 0.20, "H2": 0.18, "CH4": 0.02, "CO2": 0.10, "N2": 0.50}
	_near(TcThermo.lhv_mj_per_nm3(producer), 5.18, 0.1, "air-blown producer gas is about 5 MJ/Nm3")
	var electric := {"CO": 0.30, "H2": 0.25, "CH4": 0.15, "CO2": 0.25, "H2O": 0.05}
	_ok(TcThermo.lhv_mj_per_nm3(electric) > 9.0, "undiluted (electric) woodgas is far richer (%.1f MJ/Nm3)" % TcThermo.lhv_mj_per_nm3(electric))
	var tf := TcThermo.adiabatic_flame_k({"CH4": 1.0})
	_ok(tf > 2200.0 and tf < 2450.0, "methane burns at about 2300 K in air without dissociation (%.0f K)" % tf)
	_ok(TcThermo.adiabatic_flame_k({"CH4": 1.0}, 0.5) < tf - 200.0, "excess air cools the flame")
	_near(TcThermo.stoich_air_mol({"CH4": 1.0}), 9.55, 0.05, "methane takes 9.55 mol of air")
	_near(TcThermo.pressure_pa(1.0, 273.15, 0.022414), TcSpecies.P_ATM, 30.0, "a mole of gas at STP fills 22.4 L")
	_near(WaterSteam.boiloff_kj_per_kg(20.0), 4.186 * 80.0 + 2257.0, 0.001, "the shared boil-off budget")
	_near(WaterSteam.steam_kg_h(1.0, 100.0), 3600.0 / 2257.0, 1e-6, "1 kW boils 1.6 kg/h at 100 C")


func _test_vle_heat() -> void:
	var az := -1.0
	var prev := 1.0
	for i in range(60, 99):
		var x := float(i) / 100.0
		var b := TcThermo.ethanol_water_bubble(x)
		var dlt := float(b["y1"]) - x
		if prev > 0.0 and dlt <= 0.0:
			az = x
		prev = dlt
	print("ethanol/water azeotrope at x = %.2f" % az)
	_ok(az > 0.84 and az < 0.95, "the ethanol / water azeotrope sits near 0.89 mole fraction (%.2f)" % az)
	var b10 := TcThermo.ethanol_water_bubble(0.0966)
	print("x 0.0966: y %.3f at %.1f C" % [float(b10["y1"]), float(b10["t_k"]) - 273.15])
	_near(float(b10["y1"]), 0.4375, 0.07, "a 10 percent wash boils off vapour about 44 percent ethanol")
	_near(float(b10["t_k"]) - 273.15, 86.7, 2.5, "and boils at about 87 C")
	var baz := TcThermo.ethanol_water_bubble(0.894)
	_near(float(baz["t_k"]) - 273.15, 78.15, 0.8, "the azeotrope boils at 78.2 C")
	var h := TcThermo.h_natural(0.5, 50.0, 325.0)
	_ok(h > 3.0 and h < 7.5, "free convection off a warm wall is a few W/m2K (%.1f)" % h)
	_ok(TcThermo.h_natural(0.5, 200.0, 400.0) > h, "a hotter wall loses heat faster per degree")
	var hc := TcThermo.h_condensing(0.4, 20.0)
	_ok(hc > 4000.0 and hc < 14000.0, "condensing steam is thousands of W/m2K (%.0f)" % hc)
	_ok(TcThermo.q_radiation(773.15, 293.15, 0.8) > 15000.0, "a 500 C wall radiates over 15 kW/m2")


func _wood() -> Dictionary:
	# Softwood, dry ash-free (Sjostrom 1993: 42 / 27 / 28 of 97).
	return {"cellulose": 0.42 / 0.97, "hemicellulose": 0.27 / 0.97, "lignin": 0.28 / 0.97}


func _test_reactions() -> void:
	_near(TcReactions.arrhenius(2.8e19, 242.4e3, 600.0), 2.8e19 * exp(-242.4e3 / (TcSpecies.R * 600.0)), 1e-9, "Arrhenius form")
	var k600 := TcReactions.arrhenius(2.8e19, 242.4e3, 600.0)
	_ok(k600 > 0.01 and k600 < 0.05, "cellulose activates in under a minute at 327 C (k %.3f/s)" % k600)
	_ok(TcReactions.arrhenius(2.8e19, 242.4e3, 500.0) < 1e-5, "and barely at 227 C")
	# A slow ramp, 5 K/min to 500 C and an hour's soak.
	var m := _wood()
	var t := 300.0
	var tar := 0.0
	var gas := 0.0
	var char := 0.0
	var water := 0.0
	var dt := 5.0
	var steps := int((773.15 - 300.0) / (5.0 / 60.0) / dt) + int(3600.0 / dt)
	for _i in steps:
		t = minf(t + 5.0 / 60.0 * dt, 773.15)
		var r := TcReactions.wood_step(m, t, dt)
		tar += float(r["tar_kg"])
		char += float(r["char_kg"])
		for g in (r["gas"] as Dictionary).keys():
			gas += float(r["gas"][g])
			if g == "H2O":
				water += float(r["gas"][g])
	var left := float(m["cellulose"]) + float(m["hemicellulose"]) + float(m["lignin"]) + float(m["cellulose_a"]) + float(m["hemicellulose_a"]) + float(m["lignin_a"])
	print("slow pyrolysis: char %.2f tar %.2f gas %.2f (water %.2f) unreacted %.4f" % [char, tar, gas, water, left])
	_near(char + tar + gas + left, 1.0, 1e-6, "pyrolysis conserves mass")
	_ok(left < 0.01, "an hour at 500 C finishes the charge (%.3f left)" % left)
	_ok(char > 0.28 and char < 0.42, "slow pyrolysis leaves about a third as char (%.2f)" % char)
	_ok(tar + water > 0.25 and tar + water < 0.50, "about a third condenses (tar + water %.2f)" % (tar + water))
	_ok(gas - water > 0.10 and gas - water < 0.35, "and the rest is permanent gas (%.2f)" % (gas - water))
	var fast := _wood()
	var tarf := 0.0
	var charf := 0.0
	for _i in 200:
		var r2 := TcReactions.wood_step(fast, 873.15, 0.05)
		tarf += float(r2["tar_kg"])
		charf += float(r2["char_kg"])
	_ok(tarf > tar and charf < char, "flash heating makes more tar and less char (fast pyrolysis)")
	var s7 := TcReactions.gas_split_molar(700.0)
	var s10 := TcReactions.gas_split_molar(1000.0)
	_ok(float(s7["CO2"]) > float(s7["CO"]), "cool pyrolysis gas is CO2-rich")
	_ok(float(s10["H2"]) > float(s7["H2"]) and float(s10["CO"]) > float(s7["CO"]), "hotter gas carries more H2 and CO")
	var sm := TcReactions.gas_split_mass(800.0)
	var ssum := 0.0
	for k in sm.keys():
		ssum += float(sm[k])
	_near(ssum, 1.0, 1e-9, "the gas split's mass fractions sum to one")
	var c5 := TcReactions.tar_crack(1.0, 773.15, 10.0)
	var c3 := TcReactions.tar_crack(1.0, 600.0, 10.0)
	_ok(float(c5["cracked_kg"]) > 0.5 and float(c3["cracked_kg"]) < 0.05, "tar cracks in seconds at 500 C but not at 330 C (%.2f vs %.3f)" % [float(c5["cracked_kg"]), float(c3["cracked_kg"])])
	for pl in ["pe", "pp"]:
		var th := float(TcReactions.PLASTIC[pl]["t_half_c"]) + 273.15
		var ps := TcReactions.plastic_step(pl, 1.0, th, 1800.0)
		_near(float(ps["reacted_kg"]), 0.5, 1e-6, "%s: half cracks in 30 min at %.0f C" % [pl, th - 273.15])
		var psum := 0.0
		for k in (ps["products"] as Dictionary).keys():
			psum += float(ps["products"][k])
		_near(psum, float(ps["reacted_kg"]), 1e-9, "%s cracking conserves mass" % pl)
	var c1 := TcReactions.combust({"CH4": 1.0}, 2.0)
	_near(float(c1["co2"]), 1.0, 1e-9, "CH4 + 2 O2 gives CO2")
	_near(float(c1["h2o"]), 2.0, 1e-9, "and 2 H2O")
	_near(float(c1["heat_j"]), 802.3e3, 1.0, "releasing 802 kJ")
	var c2 := TcReactions.combust({"CH4": 1.0, "CO": 2.0}, 1.5)
	_near(float(c2["o2_used"]), 1.5, 1e-9, "a lean O2 supply is all used")
	_near(float(c2["burned"]["CO"]), 1.0, 1e-9, "and burns every fuel by the same share")
	_near(TcReactions.desiccant_capacity(1.0), 0.35, 1e-9, "silica gel holds 35 percent at saturation")
	_ok(TcReactions.desiccant_capacity(0.3) < TcReactions.desiccant_capacity(0.6), "and less in drier gas")
	_ok(float(TcReactions.filter_capture("cartridge_housing")[0]) > float(TcReactions.filter_capture("inline_strainer")[0]),
		"a cartridge catches more fines than a strainer")



func _event_t(sim: TcProcSim, id: String) -> float:
	for e in sim.events:
		if str(e["id"]) == id:
			return float(e["t_s"])
	return INF


func _event_prefix_t(sim: TcProcSim, prefix: String) -> float:
	var t := INF
	for e in sim.events:
		if str(e["id"]).begins_with(prefix):
			t = minf(t, float(e["t_s"]))
	return t


func _test_batch() -> void:
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	var sim := TcProcSim.create(d)
	_ok(sim.bed != null and sim.bed.domains.size() == 2, "two bottom elements make two charge domains")
	_near(sim.bed.initial_moisture_kg, 2.0, 1e-6, "10 kg of chips at 20 percent carries 2 kg of water")
	var fronts: Array = []
	var t0 := Time.get_ticks_usec()
	var lhv_max := 0.0
	var p_max := 0.0
	for h in 10:
		for _k in 12:
			sim.run_for(300.0)
			var r := sim.readings()
			lhv_max = maxf(lhv_max, float(r["gas_lhv_mj_nm3"]) if float(r["gas_out_dry_l_min"]) > 0.2 else 0.0)
			p_max = maxf(p_max, float(r["vessel_p_kpa_g"]))
		var rh := sim.readings()
		fronts.append([float(rh["dry_front_mm"]), float(rh["pyro_front_mm"])])
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("batch: 10 h in %.0f ms (%.3f ms/step)" % [ms, ms / 7200.0])
	var r := sim.readings()
	var lg := sim.energy_ledger()
	var resid := float(lg["in"]) - float(lg["stored"]) - float(lg["loss"]) - float(lg["coolant"]) - float(lg["reaction"]) - float(lg["out"])
	print("batch energy: in %.1f MJ stored %.1f loss %.1f coolant %.1f reaction %.1f out %.1f (resid %.2f%%)" % [
		float(lg["in"]) / 1e6, float(lg["stored"]) / 1e6, float(lg["loss"]) / 1e6, float(lg["coolant"]) / 1e6,
		float(lg["reaction"]) / 1e6, float(lg["out"]) / 1e6, resid / float(lg["in"]) * 100.0])
	_ok(absf(resid) < 0.01 * float(lg["in"]), "the energy ledger closes within 1 percent (%.2f%%)" % (resid / float(lg["in"]) * 100.0))
	var ml := sim.mass_ledger()
	print("batch mass: start %.3f kg, held %.3f, out %.3f, error %.4f" % [float(ml["start_kg"]), float(ml["now_kg"]), float(ml["out_kg"]), float(ml["error_kg"])])
	_ok(absf(float(ml["error_kg"])) < 0.005 * float(ml["start_kg"]), "mass is conserved within 0.5 percent (%.4f kg)" % float(ml["error_kg"]))
	var t_dry := _event_t(sim, "drying")
	var t_pyro := _event_t(sim, "pyrolysis")
	var t_gas := _event_t(sim, "gas_out")
	var t_all_dry := _event_t(sim, "dry")
	var t_done := _event_t(sim, "done")
	print("batch events: drying %.2f h, pyrolysis %.2f, gas out %.2f, all dry %.2f, done %.2f" % [t_dry / 3600.0, t_pyro / 3600.0,
		t_gas / 3600.0, t_all_dry / 3600.0, t_done / 3600.0])
	_ok(t_dry < t_pyro and t_pyro < t_gas, "water boils off first, then pyrolysis, then burnable gas reaches the outlet")
	_ok(t_all_dry < t_done and t_done < 10.0 * 3600.0, "the charge dries out before it is all char, inside the batch")
	_ok(t_done > 2.0 * 3600.0, "and two 600 W elements take hours, not minutes (%.1f h)" % (t_done / 3600.0))
	_ok(float(fronts[0][0]) < float(fronts[2][0]) or float(fronts[0][0]) >= 90.0, "the drying front moves out from the elements")
	_ok(float(fronts[0][1]) <= float(fronts[2][1]), "and the pyrolysis front follows it (%s)" % [fronts.slice(0, 4)])
	# After the charge is done the preset's rule switches the elements off:
	# the charge cools below the glow (black char) and has settled.
	var all_off := true
	for hp in sim.heater_parts:
		all_off = all_off and not bool(sim.heater_on.get(hp, true))
	_ok(all_off, "the elements are off at the end (the charge-is-done rule)")
	var t_end_c := float(sim.bed.totals()["t_max_k"]) - 273.15
	print("batch end: hottest charge %.0f °C, volume %.0f %% of loaded, mass %.2f of %.2f kg" % [t_end_c,
		sim.bed.volume_frac() * 100.0, sim.bed.mass_kg(), sim.bed.initial_dry_kg + sim.bed.initial_moisture_kg])
	_ok(t_end_c < 420.0, "and the charge has cooled below the glow by the end (%.0f °C)" % t_end_c)
	_ok(sim.bed.volume_frac() > 0.4 and sim.bed.volume_frac() < 0.62, "the char takes about half the room the chips did (%.2f)" % sim.bed.volume_frac())
	_ok(sim.bed.mass_kg() < 0.4 * (sim.bed.initial_dry_kg + sim.bed.initial_moisture_kg), "and weighs about a third (%.2f kg)" % sim.bed.mass_kg())
	var fresh := TcProcSim.create(TcDesign.solve(TcPresets.builtin("biochar_reactor")))
	_near(fresh.bed.volume_frac(), 1.0, 1e-6, "a fresh charge fills what was loaded")
	var char_frac := float(r["char_kg"]) / sim.bed.initial_dry_kg
	_ok(char_frac > 0.25 and char_frac < 0.40, "about a third of the dry wood is left as char (%.2f)" % char_frac)
	var cond: Dictionary = r["condensate_total"]
	var ckg := 0.0
	for k in cond.keys():
		ckg += float(cond[k])
	_ok(ckg > 2.0, "the traps collect the water and the tar (%.2f kg)" % ckg)
	_ok(float(cond.get("tar", 0.0)) > 0.3 and float(cond.get("acetic", 0.0)) > 0.05, "the condensate carries tar and wood vinegar")
	var by: Array = []
	for bk in sim.drained_by.keys():
		if str(sim.net["boundaries"][int(bk)]["role"]) == "drain":
			by.append(sim.drained_by[bk])
	_ok(by.size() == 2 and float(by[0]) > 0.2 * ckg and float(by[1]) > 0.2 * ckg, "both columns' traps drain their share (%s)" % [by])
	_ok(lhv_max > 6.0, "the dry gas at the outlet burns (best %.1f MJ/Nm3)" % lhv_max)
	_ok(p_max < 10.0, "with the outlet open the vessel stays near atmospheric (%.2f kPa)" % p_max)
	var gas: Dictionary = r["product_total"]
	_ok(float(gas.get("CO", 0.0)) > float(gas.get("H2", 0.0)) and float(gas.get("CO2", 0.0)) > 0.0, "slow pyrolysis gas: CO and CO2, little H2")
	_ok(float(gas.get("N2", 0.0)) < 0.1, "an electric retort's gas carries almost no nitrogen (%.3f kg)" % float(gas.get("N2", 0.0)))


func _test_kettle() -> void:
	var spec := TcPresets.builtin("brew_kettle")
	var pr := TcProcSpec.defaults()
	pr["charge"] = {"feed": "water", "mass_kg": 40.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	pr["heaters"]["default_w"] = 3000.0
	var sim := TcProcSim.create(TcDesign.solve(spec), pr)
	sim.run_for(2.5 * 3600.0, 10.0)
	var t := _event_prefix_t(sim, "boil_")
	var hand := 40.0 * 4186.0 * 80.0 / 3000.0
	print("kettle: boils after %.2f h (hand, no losses %.2f h)" % [t / 3600.0, hand / 3600.0])
	_ok(t >= hand * 0.98 and t <= hand * 1.25, "a 3 kW element boils 40 L about when the hand sum says, plus its losses")
	var r := sim.readings()
	var steam := float((r["product_total"] as Dictionary).get("H2O", 0.0)) + float(sim.vented_mol[0]) * 0.018015
	_ok(steam > 0.5, "and then boils water off out of the vent (%.2f kg)" % steam)


func _test_pressure() -> void:
	# Cap the gas outlet: the vessel pressurises.
	var spec := TcPresets.builtin("biochar_reactor")
	var r := TcAssembly.add_part(spec, "cap", "2", {}, Transform3D.IDENTITY, {"target": "p20:b", "own": "a"})
	var sim := TcProcSim.create(TcDesign.solve(r[0]))
	sim.run_for(1800.0)
	var p_closed := float(sim.readings()["vessel_p_kpa_g"])
	print("capped outlet: %.0f kPa gauge after 30 min" % p_closed)
	_ok(p_closed > 50.0, "a sealed retort pressurises (%.0f kPa)" % p_closed)
	# A relief valve on the crown holds it near its set pressure.
	var r2 := TcAssembly.add_part(r[0], "relief_valve", "1.5", {}, Transform3D.IDENTITY, {"target": "p1:crown", "own": "a"})
	var pr := TcProcSpec.resolve(r2[0].get("process", {}))
	pr["relief_bar"] = 0.5
	var sim2 := TcProcSim.create(TcDesign.solve(r2[0]), pr)
	sim2.run_for(1800.0)
	var p_relief := float(sim2.readings()["vessel_p_kpa_g"])
	print("with a 0.5 bar relief: %.0f kPa gauge" % p_relief)
	_ok(p_relief < 60.0 and p_relief > 20.0, "a relief valve holds it near its set pressure (%.0f kPa)" % p_relief)
	_ok(_event_prefix_t(sim2, "relief_") < INF, "and says when it lifted")


func _test_determinism() -> void:
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	var a := TcProcSim.create(d)
	var b := TcProcSim.create(d)
	a.run_for(3600.0)
	b.run_for(3600.0)
	_near(float(a.readings()["bed_t_max_c"]), float(b.readings()["bed_t_max_c"]), 0.0, "two runs are identical")
	var c := TcProcSim.create(d)
	c.run_for(7200.0)
	c.seek(3600.0)
	_near(c.t_s, 3600.0, 1e-6, "seek lands on the time asked")
	_near(float(c.readings()["bed_t_max_c"]), float(a.readings()["bed_t_max_c"]), 1e-6, "seeking back gives the state a run to that time had")
	_near(float(c.readings()["char_kg"]), float(a.readings()["char_kg"]), 1e-9, "char too")
	_ok(c.keyframes.size() >= 60, "keyframes every two minutes (%d)" % c.keyframes.size())


## Phase 5b: the design's sensors and actuators, and its automations run in
## the model on its own clock.
func _test_control() -> void:
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	var sim := TcProcSim.create(d)
	var sl := TcProcControl.design_slug(d)
	_ok(sl == "biochar_reactor_condenser", "the design's entity prefix is its name as a slug (%s)" % sl)
	var keys := {}
	for e in sim.control_sensors:
		keys[str(e["key"])] = e
	for k in ["charge_max_temp", "charge_mean_temp", "vessel_temp", "vessel_pressure", "gas_out", "gas_lhv", "condensate", "energy_in", "cooling_out_temp"]:
		_ok(keys.has("sensor.%s_%s" % [sl, k]), "sensor %s" % k)
	var el := 0
	var lv := 0
	for k2 in keys.keys():
		if str(k2).ends_with("_temp") and str((keys[k2] as Dictionary)["src"]["kind"]) == "element":
			el += 1
		if str(k2).ends_with("_level"):
			lv += 1
	_ok(el == 2, "a temperature for each element (%d)" % el)
	_ok(lv >= 2, "a level for each trap (%d)" % lv)
	var akeys := {}
	for a in sim.control_acts:
		akeys[str(a["key"])] = a
	_ok(akeys.has("switch.%s_p2" % sl) and akeys.has("number.%s_p2_power" % sl), "an element is a switch and a power number")
	_ok(akeys.has("switch.%s_heaters" % sl), "and every element together")
	_ok(akeys.has("number.%s_cooling_flow" % sl) and akeys.has("switch.%s_cooling" % sl), "cooling water: flow and on / off")
	var drains := 0
	for k3 in akeys.keys():
		if str(k3).ends_with("_drain"):
			drains += 1
	_ok(drains >= 2, "each drain is a switch (%d)" % drains)
	var vals := TcProcControl.read_all(sim, sim.control_sensors)
	_near(float(vals["sensor.%s_charge_max_temp" % sl]), 20.0, 0.5, "the charge starts at room temperature")
	# Commands.
	var w0 := float(sim.heater_w["p2"])
	TcProcControl.apply(sim, sim.control_acts, {"cmd": "turn_off", "target": "switch.%s_p2" % sl}, 2.0, {"p2": w0})
	_ok(not TcProcControl.is_on(sim, "heater:p2") and TcProcControl.is_on(sim, "heater:p21"), "a targeted switch turns one element off")
	TcProcControl.apply(sim, sim.control_acts, "turn_off", 2.0, {})
	_ok(not TcProcControl.is_on(sim, "heaters"), "an untargeted one switches every element")
	TcProcControl.apply(sim, sim.control_acts, {"cmd": "toggle", "target": "switch.%s_heaters" % sl}, 2.0, {"p2": w0, "p21": w0})
	_ok(TcProcControl.is_on(sim, "heater:p2") and TcProcControl.is_on(sim, "heater:p21"), "toggle turns them back on")
	var txt := TcProcControl.apply(sim, sim.control_acts, {"cmd": "set_value", "entity_id": "number.%s_p2_power" % sl, "value": 450.0}, 2.0, {})
	_near(float(sim.heater_w["p2"]), 450.0, 1e-9, "set_value sets an element's watts (%s)" % txt)
	TcProcControl.apply(sim, sim.control_acts, {"cmd": "set_value", "entity_id": "number.%s_cooling_flow" % sl, "value": 99.0}, 2.0, {})
	var lpm := 0.0
	for c in sim.cool_lpm.keys():
		lpm = float(sim.cool_lpm[c])
	_near(lpm, 20.0, 1e-9, "set_value clamps to the number's range")
	TcProcControl.apply(sim, sim.control_acts, {"cmd": "turn_off", "target": "switch.%s_cooling" % sl}, 2.0, {})
	_ok(not TcProcControl.is_on(sim, "cooling_switch"), "the cooling switch stops the water")
	# The hold-at-450 preset, run in the model.
	var tpl: Array = TcProcControl.templates(sim, d)
	_ok(tpl.size() >= 3, "presets for this design (%d)" % tpl.size())
	var hold: Array = (tpl[0] as Dictionary)["specs"]
	var proc := TcProcSpec.resolve(TcProcSpec.biochar_default())
	proc["automations"] = hold
	var sa := TcProcSim.create(d, proc)
	_ok(sa.automations != null and sa.automations.rules.size() == 2, "the design's automations become rules in the model")
	var peak := 0.0
	var after_cross := false
	var low_after := INF
	for _k in 6 * 120:
		sa.run_for(30.0)
		var t_hot := float(sa.bed.totals()["t_max_k"]) - 273.15
		if t_hot > 450.0:
			after_cross = true
		if after_cross:
			peak = maxf(peak, t_hot)
			low_after = minf(low_after, t_hot)
	var offs := 0
	var ons := 0
	for e2 in sa.automations.log:
		if str(e2["command"]) == "turn_off":
			offs += 1
		elif str(e2["command"]) == "turn_on":
			ons += 1
	print("hold 450: peak %.0f °C, low after %.0f, %d off / %d on" % [peak, low_after, offs, ons])
	_ok(after_cross, "the charge reaches 450 °C")
	_ok(offs >= 2 and ons >= 1, "the elements cycle off and on (%d off, %d on)" % [offs, ons])
	_ok(peak < 560.0, "the charge is held near 450 °C, not the ~860 °C of a free run (peak %.0f)" % peak)
	var auto_ev := 0
	for ev in sa.events:
		if str(ev["id"]) == "auto":
			auto_ev += 1
	_ok(auto_ev == offs + ons, "each switch is in the event log (%d)" % auto_ev)
	# Seek replays the rules the same way.
	var sb := TcProcSim.create(d, proc)
	sb.run_for(4.0 * 3600.0)
	var lg_full := sb.automations.log.size()
	var t_full := float(sb.bed.totals()["t_max_k"])
	sb.seek(2.0 * 3600.0)
	sb.run_for(2.0 * 3600.0)
	_ok(sb.automations.log.size() == lg_full, "seeking back and running again switches the same times (%d)" % lg_full)
	_near(float(sb.bed.totals()["t_max_k"]), t_full, 1e-6, "and lands on the same state")
	# A time rule fires at the lab's clock time.
	var p2 := TcProcSpec.resolve(TcProcSpec.biochar_default())
	p2["start_hour"] = 8.0
	p2["automations"] = [{"alias": "Cooling up at 9", "enabled": true, "triggers": [{"kind": "time", "at_hour": 9.0}],
		"conditions": [], "actions": [{"kind": "set_value", "entity_id": "number.%s_cooling_flow" % sl, "value": 5.0}]}]
	var sc := TcProcSim.create(d, p2)
	sc.run_for(50.0 * 60.0)
	var l1 := 0.0
	for c2 in sc.cool_lpm.keys():
		l1 = float(sc.cool_lpm[c2])
	sc.run_for(20.0 * 60.0)
	var l2 := 0.0
	for c3 in sc.cool_lpm.keys():
		l2 = float(sc.cool_lpm[c3])
	_ok(absf(l1 - 2.0) < 1e-9 and absf(l2 - 5.0) < 1e-9, "a 9:00 rule fires an hour into an 8:00 batch (%.1f → %.1f L/min)" % [l1, l2])
	# Home Assistant YAML.
	var y := TcProcControl.ha_yaml(d, hold)
	_ok(y.contains("trigger: numeric_state") and y.contains("entity_id: sensor.%s_charge_max_temp" % sl), "the YAML reads the sensor")
	_ok(y.contains("action: switch.turn_off") and y.contains("switch.%s_heaters" % sl), "and switches the elements")
	var y2 := TcProcControl.ha_yaml(d, p2["automations"])
	_ok(y2.contains("at: \"09:00:00\"") and y2.contains("action: number.set_value"), "a time rule and set_value in YAML")
	# AutomationSim's snapshot.
	var a_s := AutomationSim.from_specs(hold, "tc")
	var snap := a_s.snapshot()
	a_s.log.append({"t": 1.0})
	a_s.restore(snap)
	_ok(a_s.log.is_empty(), "AutomationSim restores its state")


## Phase 6: the molecule lens's data.
func _test_molecules() -> void:
	for sp in TcProcSim.SP:
		_ok(not TcMolecules.layout(str(sp)).is_empty(), "%s has a molecule to draw" % sp)
	var tar := TcMolecules.element_count("tar")
	_ok(tar == {"C": 6, "O": 5, "H": 10}, "levoglucosan is C6H10O5 in the lens (%s)" % [tar])
	_ok(TcMolecules.element_count("glucose") == tar, "a glucose unit has the same atoms")
	_ok(TcMolecules.element_count("char") == {"C": 6}, "char is a carbon hexagon")
	var oil := TcMolecules.element_count("oil")
	_ok(int(oil.get("H", 0)) == 2 * int(oil.get("C", 0)) + 2, "the oil chain is an alkane CnH2n+2 (%s)" % [oil])
	var n_st := 0
	var stories := TcMolecules.stories()
	for kind in stories.keys():
		for st in stories[kind]:
			n_st += 1
			_ok(TcMolecules.balanced(st), "%s keeps every atom (%s)" % [kind, str(st["text"]).get_slice(":", 0)])
	_ok(n_st >= 7, "storyboards for every reaction the model reports (%d)" % n_st)
	for k in ["drying", "boiling", "condensing", "pyrolysis", "cracking"]:
		_ok(stories.has(k), "a storyboard for %s" % k)
	# The wood examples: what each piece is, and that the link that stays
	# does not move.
	_ok(TcMolecules.element_count("xylan") == {"C": 5, "H": 8, "O": 4}, "a xylose link is C5H8O4 (%s)" % [TcMolecules.element_count("xylan")])
	_ok(TcMolecules.element_count("xylan2") == {"C": 10, "H": 16, "O": 8}, "two links of hemicellulose are C10H16O8")
	_ok(TcMolecules.element_count("furfural") == {"C": 5, "H": 4, "O": 2}, "furfural is C5H4O2")
	_ok(TcMolecules.element_count("cellulose2") == {"C": 12, "H": 20, "O": 10}, "two links of cellulose are C12H20O10")
	_ok(TcMolecules.element_count("lignin") == {"C": 10, "H": 12, "O": 3}, "the lignin unit is C10H12O3")
	_ok(TcMolecules.element_count("guaiacol") == {"C": 7, "H": 8, "O": 2}, "guaiacol is C7H8O2")
	_ok(TcMolecules.element_count("ethylene") == {"C": 2, "H": 4}, "ethylene is C2H4")
	var ids := {}
	for st2 in stories["pyrolysis"]:
		ids[str(st2["id"])] = st2
	_ok(ids.has("hemicellulose") and ids.has("cellulose") and ids.has("lignin") and ids.has("charring"),
		"pyrolysis has an example for hemicellulose, cellulose, lignin and charring")
	var hs: Dictionary = ids["hemicellulose"]
	var stay: Vector3 = hs["to"][0][2]
	var a0: Vector3 = (TcMolecules.raw("xylan2")["atoms"][0][1] as Vector3) - TcMolecules.centroid("xylan2")
	var a1: Vector3 = (TcMolecules.raw("xylan")["atoms"][0][1] as Vector3) - TcMolecules.centroid("xylan") + stay
	_ok(a0.distance_to(a1) < 1e-4, "the link that stays in the chain stands where it stood (%.4f Å)" % a0.distance_to(a1))
	# Bonds are bond-length: nothing drawn across a molecule.
	for sp2 in ["xylan2", "cellulose2", "furfural", "lignin", "guaiacol", "ethylene", "tar"]:
		var lay := TcMolecules.layout(sp2)
		var worst := 0.0
		var least := INF
		for bd in lay["bonds"]:
			var bl: float = (lay["atoms"][int(bd[0])][1] as Vector3).distance_to(lay["atoms"][int(bd[1])][1])
			worst = maxf(worst, bl)
			least = minf(least, bl)
		_ok(worst < 1.75 and least > 0.9, "%s: every bond is a bond's length (%.2f–%.2f Å)" % [sp2, least, worst])
	var c := TcMolecules.sample_counts({"H2O": 0.6, "CO": 0.25, "CO2": 0.14, "H2": 0.01}, 30)
	var tot := 0
	for k2 in c.keys():
		tot += int(c[k2])
	_ok(tot == 30, "sampling draws exactly n molecules (%d)" % tot)
	_ok(int(c.get("H2O", 0)) == 18 and int(c.get("CO", 0)) >= 7, "in proportion (%s)" % [c])
	_ok(int(c.get("H2", 0)) == 1, "a 1 % species still shows once")
	_ok(TcMolecules.sample_counts({"H2O": 0.0}, 10).is_empty(), "nothing sampled from nothing")
	_ok(TcMolecules.display_speed("H2", 373.0) > TcMolecules.display_speed("H2O", 373.0) * 2.5, "lighter molecules move faster (√(1/M))")
	_near(TcMolecules.display_speed("H2O", 4.0 * 373.0) / TcMolecules.display_speed("H2O", 373.0), 2.0, 0.01, "four times the temperature, twice the speed")
	# The model reports the reactions the lens plays.
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	var sim := TcProcSim.create(d)
	var seen := {}
	for _k in 40:
		sim.run_for(300.0)
		for i in sim.n_cv:
			for kind2 in (sim.react_rate[i] as Dictionary).keys():
				if float(sim.react_rate[i][kind2]) > 0.0:
					seen[kind2] = true
	_ok(seen.has("drying") and seen.has("pyrolysis") and seen.has("condensing"), "a batch reports drying, pyrolysis and condensing (%s)" % [seen.keys()])


## Phase 7: a finished run fitted into the graph node's batch recipe.
func _test_summary() -> void:
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	var proc := TcProcSpec.resolve(TcProcSpec.biochar_default())
	var sim := TcProcSim.create(d, proc)
	var hist: Array = []
	var end := float(proc["duration_h"]) * 3600.0
	while sim.t_s < end - 1e-6:
		var r := sim.readings()
		var ck := 0.0
		for k in (r.get("condensate_total", {}) as Dictionary).keys():
			ck += float(r["condensate_total"][k])
		hist.append({"t_h": sim.t_s / 3600.0, "gas_dry": float(r.get("gas_out_dry_l_min", 0.0)), "cond": ck,
			"e_kwh": float(r.get("energy_in_kwh", 0.0))})
		sim.run_for(120.0)
	var preset := TcDesign.bound_preset(d["spec"])
	var ps: Dictionary = preset["specs"]
	var rc := TcProcSummary.fit(d, proc, sim, hist, sim.events, ps["inputs"], ps["outputs"])
	print("summary: %s" % str(rc["note"]))
	_ok(ProcessRecipe.is_valid(rc), "the fit is a valid process recipe")
	var bh := float(rc["batch_time_hrs"])
	_ok(bh > 3.0 and bh < 10.0, "the batch ends when the gas has tailed off (%.1f h)" % bh)
	var ins: Array = rc["inputs"]
	_ok(str(ins[0]["kind"]) == "biomass" and absf(float(ins[0]["qty"]) - 10.0) < 1e-9 and str(ins[0]["mode"]) == "frontloaded",
		"the charge goes in at the start (10 kg biomass)")
	var kinds: Array = []
	for o in rc["outputs"]:
		kinds.append(str(o["kind"]))
	_ok(kinds == ["biochar", "hot_water", "woodgas", "wood_vinegar", "tar"], "the outputs keep the node's port order (%s)" % [kinds])
	var by := {}
	for o2 in rc["outputs"]:
		by[str(o2["kind"])] = o2
	var ch := float(sim.bed.totals()["char_kg"])
	_near(float(by["biochar"]["qty"]), ch, 1e-6, "char comes out at the end of the batch")
	_ok(str(by["biochar"]["mode"]) == "end_batch", "as one lot")
	var gas: Dictionary = by["woodgas"]
	_ok(str(gas["mode"]) == "delayed" and float(gas["delay_hrs"]) >= 0.0 and float(gas["delay_hrs"]) + float(gas["duration_hrs"]) <= bh + 1e-6,
		"the gas comes out over the window it did (%.1f h for %.1f h)" % [float(gas.get("delay_hrs", -1)), float(gas.get("duration_hrs", -1))])
	_ok(float(gas["qty"]) > 0.3, "a few cubic metres of gas (%.2f m³)" % float(gas["qty"]))
	var lhv := float(rc["gas_lhv_mj_nm3"])
	_ok(lhv > 5.0 and lhv < 16.0, "its heating value is pyrolysis gas's (%.1f MJ/Nm³)" % lhv)
	_near(float(gas["lhv_mj_nm3"]), lhv, 1e-9, "and rides on the woodgas output")
	_ok(float(by["wood_vinegar"]["qty"]) > 2.0 and float(by["tar"]["qty"]) > 0.05, "wood vinegar and tar are collected (%.2f L, %.2f kg)" % [float(by["wood_vinegar"]["qty"]), float(by["tar"]["qty"])])
	var w := float(rc["watts"])
	_ok(w > 600.0 and w <= 1250.0, "the mean draw is the elements' (%.0f W)" % w)
	var gk := 0.0
	for sp in (rc["gas_composition"] as Dictionary).keys():
		gk += float(rc["gas_composition"][sp])
		_ok(not (str(sp) in ["H2O", "tar", "acetic"]), "%s is not in the dry gas" % sp)
	_near(gk, 1.0, 1e-6, "the gas's makeup adds up")
	_ok((rc["steps"] as Array).size() >= 2, "the phase changes are steps (%d)" % (rc["steps"] as Array).size())
	# Onto a node's specs.
	var specs: Dictionary = ps.duplicate(true)
	TcProcSummary.apply_to_specs(specs, rc)
	_ok(bool(specs["batch_mode"]) and str(specs["selected_recipe_id"]) == str(rc["id"]), "the node runs it as a batch recipe")
	var ok_order := true
	for i in (ps["outputs"] as Array).size():
		if str(specs["outputs"][i]["kind"]) != str(ps["outputs"][i]["kind"]):
			ok_order = false
	_ok(ok_order, "the node's ports keep their kinds (wires stay put)")
	_near(float(specs["gas_lhv_mj_nm3"]), lhv, 1e-9, "the node carries the gas's heating value")
	_near(float(specs["watts"]), w, 1e-9, "and the draw")
	# Rules the world can run.
	var hold: Array = (TcProcControl.templates(sim, d)[0] as Dictionary)["specs"]
	var timed := {"id": "a9", "alias": "Start at 7", "enabled": true, "triggers": [{"kind": "time", "at_hour": 7.0}],
		"conditions": [], "actions": [{"kind": "scene_node", "command": "turn_on"}]}
	var wa := TcProcSummary.world_automations(hold + [timed])
	_ok((wa["world"] as Array).size() == 1 and str(wa["world"][0]["id"]) == "tc_a9", "a clock rule goes to the world")
	_ok((wa["lab_only"] as Array).size() == 2, "rules reading lab sensors stay in the lab")
	# The design keeps it.
	var p2 := proc.duplicate(true)
	p2["recipe"] = rc
	_ok(not (TcProcSpec.resolve(p2)["recipe"] as Dictionary).is_empty(), "the process block keeps the recipe")


## The batch's results (what the Results tiles show) and the controller
## board: carbon and CO2e from the char, the gas made wherever it went, the
## electricity in and out; the ESP board made from the design's sensors and
## switches carries the Process Lab's own entity ids.
func _test_results_and_board() -> void:
	var d := TcDesign.solve(TcPresets.builtin("biochar_genset"))
	var sim := TcProcSim.create(d)
	var b0 := sim.batch_stats()
	_ok(float(b0["char_kg"]) == 0.0 and float(b0["co2e_kg"]) == 0.0 and float(b0["gas_nl"]) < 0.5, "nothing made before the batch starts")
	_ok(bool(b0["has_bed"]) and bool(b0["wood"]), "a wood charge is loaded")
	sim.run_for(1.5 * 3600.0)
	var b1 := sim.batch_stats()
	sim.run_for(4.5 * 3600.0)
	var b := sim.batch_stats()
	var char_kg := float(sim.bed.totals()["char_kg"])
	_near(float(b["char_kg"]), char_kg, 1e-9, "the char is the bed's (%.2f kg)" % char_kg)
	_near(float(b["carbon_kg"]), char_kg * 0.8, 1e-9, "its carbon is 80 %% of it (%.2f kg C)" % float(b["carbon_kg"]))
	_near(float(b["co2e_kg"]), char_kg * 0.8 * 0.8 * 44.01 / 12.011, 1e-9, "CO2e = carbon × 0.8 lasting × 44/12 (%.2f kg)" % float(b["co2e_kg"]))
	_ok(float(b["co2e_kg"]) > 5.0 and float(b["co2e_kg"]) < 9.0, "a 10 kg batch keeps 5–9 kg of CO2 out of the air")
	_ok(float(b["gas_nl"]) > 500.0 and float(b["gas_nl"]) < 2500.0, "it gives off of the order of a cubic metre of gas (%.0f L)" % float(b["gas_nl"]))
	_ok(float(b["gas_nl"]) > float(b1["gas_nl"]) and float(b["heat_kwh"]) > float(b1["heat_kwh"]), "gas made and electricity in only count up")
	_ok(float(b["gas_mj"]) / (float(b["gas_nl"]) * 0.001) > 3.0 and float(b["gas_mj"]) / (float(b["gas_nl"]) * 0.001) < 14.0,
		"the gas carries a woodgas heating value (%.1f MJ/m³)" % (float(b["gas_mj"]) / (float(b["gas_nl"]) * 0.001)))
	_near(float(b["heat_kwh"]), sim.e_in / 3.6e6, 1e-9, "electricity in is the elements' energy")
	_near(float(b["gen_kwh"]), sim.engine_kwh, 1e-12, "electricity out is the generator's")
	_ok(float(b["gen_kwh"]) > 0.1 and float(b["gen_kwh"]) < float(b["heat_kwh"]), "the generator gives back part of the heat's electricity (%.2f of %.2f kWh)" % [float(b["gen_kwh"]), float(b["heat_kwh"])])
	_ok(float(b["vinegar_kg"]) > 1.0 and float(b["tar_kg"]) > 0.2, "wood vinegar and tar were collected (%.2f, %.2f kg)" % [float(b["vinegar_kg"]), float(b["tar_kg"])])
	# It is a function of the state: seeking back gives the earlier figures.
	sim.seek(1.5 * 3600.0)
	var bb := sim.batch_stats()
	_ok(absf(float(bb["gas_nl"]) - float(b1["gas_nl"])) < maxf(float(b1["gas_nl"]) * 0.05, 5.0) and float(bb["char_kg"]) <= char_kg,
		"a seek back shows the batch as it stood then")
	var pl := TcProcSim.create(TcDesign.solve(TcPresets.builtin("plastic_retort")))
	_ok(not bool(pl.batch_stats()["wood"]), "a plastic charge claims no stored carbon")
	# The controller board.
	var proc: Dictionary = sim.proc
	var rws := TcProcBoard.rows(sim, proc)
	var by := {}
	for r in rws:
		by[str(r["key"])] = r
	var slug := TcProcControl.design_slug(d)
	_ok(str(by["sensor.%s_charge_max_temp" % slug]["part"]) == "max6675" and bool(by["sensor.%s_charge_max_temp" % slug]["on"]), "the charge's temperature is a thermocouple, on the board")
	_ok(str(by["sensor.%s_charge_done" % slug]["part"]) == "" and not bool(by["sensor.%s_charge_done" % slug]["on"]), "what the model works out has no part")
	_ok(str(by["sensor.%s_cooling_out_temp" % slug]["part"]) == "ds18b20", "cooling water is a DS18B20")
	var lvl := ""
	var gen_sw := ""
	for k in by.keys():
		if str(k).ends_with("_level") and str(by[k]["part"]) == "vl53l0x":
			lvl = str(k)
		if str(by[k]["domain"]) == "switch" and str(k) != "switch.%s_cooling" % slug and not str(k).ends_with("_drain") and not str(k).ends_with("_heaters"):
			gen_sw = str(k)
	_ok(lvl != "", "the gasometer's fill is a distance sensor over the float")
	_ok(str(by["switch.%s_heaters" % slug]["part"]) == "", "the every-element group is not a pin")
	_ok(not bool(by["sensor.%s_p2_temp" % slug]["on"]), "an element's own temperature is off the board until ticked")
	var ids := TcProcBoard.entity_ids(d, sim, proc)
	var all_match := not ids.is_empty()
	var bad := ""
	for k2 in ids.keys():
		if str(ids[k2]) != str(k2):
			all_match = false
			bad = "%s → %s" % [k2, ids[k2]]
	_ok(all_match, "every part on the board gets the Process Lab's own entity id in Home Assistant (%d checked%s)" % [ids.size(), (", " + bad) if bad != "" else ""])
	var spec := TcProcBoard.esp_spec(d, sim, proc)
	_ok(str(spec["name"]) == TcProcBoard.friendly(d) and EspEntityNames.ha_slug(str(spec["name"])) == slug, "the board is named after the design")
	var ed := EspDesign.solve(spec)
	var errs := 0
	for c in ed["checks"]:
		if str(c.get("level", "")) == "error":
			errs += 1
	_ok(errs == 0, "the default board wires on one ESP32 (%d parts, %d errors)" % [(spec["parts"] as Array).size(), errs])
	var yaml := str(ed["yaml"])
	_ok(yaml.contains("platform: max6675") and yaml.contains("platform: vl53l0x") and yaml.contains("platform: gpio"), "its ESPHome YAML has the thermocouples, the distance sensor and the relays")
	_ok(yaml.contains("unit_of_measurement: \"%\"") or yaml.contains("unit_of_measurement: '%'") or yaml.contains("unit_of_measurement: %"), "the float's distance is published in %")
	# The rules name entities the board has.
	var on_board := {}
	for k3 in ids.keys():
		on_board[str(k3)] = true
	var named := 0
	var have := 0
	for a in proc.get("automations", []):
		for t in a.get("triggers", []):
			var eid := str(t.get("entity_id", ""))
			if eid == lvl:
				named += 1
				have += 1 if on_board.has(eid) else 0
		for ac in a.get("actions", []):
			var tg := str(ac.get("target", ""))
			if tg == gen_sw:
				named += 1
				have += 1 if on_board.has(tg) else 0
	_ok(named >= 4 and have == named, "the generator rules' sensor and switch are both on the board (%d of %d)" % [have, named])
	# The player's choice.
	var p2 := proc.duplicate(true)
	p2["board"] = {"on": {"sensor.%s_p2_temp" % slug: true, lvl: false}}
	p2 = TcProcSpec.resolve(p2)
	var by2 := {}
	for r2 in TcProcBoard.rows(sim, p2):
		by2[str(r2["key"])] = r2
	_ok(bool(by2["sensor.%s_p2_temp" % slug]["on"]) and not bool(by2[lvl]["on"]), "ticks are kept on the design's process block")
	_ok(TcProcBoard.summary(rws).contains("thermocouple") and TcProcBoard.summary(rws).contains("relay"), "the board is summed up in words (%s)" % TcProcBoard.summary(rws))


## Phase 8: the process units and the whole chain. The bell holds its
## weight's pressure while it fills, blows off through its seal when full; the
## genset fires only on gas rich enough, draws it through the dryer at its
## rating and makes kWh; the dryer takes water up; the chain's automations run
## the genset off the holder; the ledgers still close; the graph gets one node
## per bound part.
func _test_units() -> void:
	var spec := TcPresets.builtin("biochar_genset")
	_ok(not spec.is_empty(), "the Biochar → genset preset builds")
	var d := TcDesign.solve(spec)
	_ok((d.get("clashes", []) as Array).is_empty(), "the chain has no clash (%d)" % (d.get("clashes", []) as Array).size())
	var pb: Array = (d["spec"] as Dictionary).get("part_binds", [])
	_ok(pb.size() == 2 and str(pb[0][1]) == "holder" and str(pb[1][1]) == "genset", "the holder and the genset are bound parts (%s)" % [pb])
	var hn := TcDesign.unit_node(d, str(pb[0][0]), "holder")
	_ok(str(hn.get("node_type", "")) == "resource" and str((hn["specs"] as Dictionary)["resource_kind"]) == "woodgas"
		and absf(float(hn["specs"]["capacity_qty"]) - TcUnits.barrel_capacity_l("barrel_30") * 0.001) < 1e-9, "the gasometer becomes a woodgas tank of its float's capacity on the graph (%.3f m³)" % float(hn["specs"]["capacity_qty"]))
	var gn := TcDesign.unit_node(d, str(pb[1][0]), "genset")
	var gs: Dictionary = gn.get("specs", {})
	var wh := float(gs.get("energy_wh_per_unit", 0.0))
	_near(wh, 5.0 / 3.6 * 1000.0 * 0.18, 1e-6, "the genset node's Wh per m³ is the reference gas × its efficiency")
	_near(float((gs["inputs"] as Array)[0]["rate"]) * wh / 1000.0, 0.75, 1e-9, "at its fuel rate it makes its 750 W rating")
	_ok(str((gs["outputs"] as Array)[0]["kind"]) == "dc_electricity", "the genset puts out DC electricity")
	var proc: Dictionary = (d["spec"] as Dictionary)["process"]
	var sim := TcProcSim.create(d, proc)
	var kinds := {}
	for u in sim.units:
		kinds[str(u["kind"])] = u
	_ok(kinds.has("holder") and kinds.has("dryer") and kinds.has("engine"), "the network has the holder, dryer and engine volumes")
	var acts := TcProcControl.actuators(sim, d, sim.proc)
	var sens := TcProcControl.sensors(sim, d, sim.proc)
	var slug := TcProcControl.design_slug(d)
	var lvl := "sensor.%s_%s_level" % [slug, pb[0][0]]
	var sw := "switch.%s_%s" % [slug, pb[1][0]]
	var has_l := false
	for e in sens:
		has_l = has_l or str(e["key"]) == lvl
	var has_s := false
	for a in acts:
		has_s = has_s or str(a["key"]) == sw
	_ok(has_l and has_s, "the holder level is a sensor and the genset a switch")
	var tpl := false
	for t in TcProcControl.templates(sim, d):
		tpl = tpl or str(t["label"]) == "Run the genset from the gas holder"
	_ok(tpl, "the Control tab offers the genset-from-holder preset")
	var hu: Dictionary = kinds["holder"]
	var hi := int(hu["cv"])
	var max_fill := 0.0
	var off_hold := 0.0
	var max_kw := 0.0
	while sim.t_s < 6.0 * 3600.0:
		sim.run_for(60.0)
		var f := sim.holder_fill(hu)
		max_fill = maxf(max_fill, f)
		if f > 0.05 and f < 0.95:
			off_hold = maxf(off_hold, absf(sim.p_cv[hi] - float(hu["hold_pa"])))
		max_kw = maxf(max_kw, float(sim.engine_kw.get(str(pb[1][0]), 0.0)))
	_ok(max_fill > 0.55, "the bell rises as the gas comes in (to %.0f %%)" % (max_fill * 100.0))
	_ok(off_hold < 300.0, "while it is part full the bell holds its weight's pressure (off by %.0f Pa)" % off_hold)
	_ok(max_kw > 0.34 and max_kw <= 0.75 + 1e-6, "the small generator runs inside its 350–750 W range (%.2f kW at most)" % max_kw)
	_ok(sim.engine_kwh > 0.15 and sim.engine_kwh < 0.6, "the batch's gas makes a fraction of a kWh (%.2f kWh)" % sim.engine_kwh)
	# The governor: the floor while the gasometer is low, full output once it is well up.
	var eu: Dictionary = kinds["engine"]
	_near(float(eu["min_kw"]), 0.35, 1e-9, "the generator's floor is 350 W")
	_near(float(eu["rated_kw"]), 0.75, 1e-9, "and its full output 750 W")
	var keep_v := sim.v_free[hi]
	sim.v_free[hi] = float(hu["cap_m3"]) * (TcProcSim.HOLDER_MIN + (1.0 - TcProcSim.HOLDER_MIN) * 0.1)
	_near(sim.engine_setpoint_kw(eu), 0.35, 1e-6, "asked for 350 W with the gasometer nearly empty")
	sim.v_free[hi] = float(hu["cap_m3"]) * (TcProcSim.HOLDER_MIN + (1.0 - TcProcSim.HOLDER_MIN) * 0.45)
	_near(sim.engine_setpoint_kw(eu), 0.55, 1e-6, "550 W at 45 % full")
	sim.v_free[hi] = float(hu["cap_m3"])
	_near(sim.engine_setpoint_kw(eu), 0.75, 1e-6, "750 W with it full")
	sim.v_free[hi] = keep_v
	_near(sim.engine_setpoint_kw({"rated_kw": 2.5}), 2.5, 1e-9, "a set with no floor always runs at full output")
	var du: Dictionary = kinds["dryer"]
	_ok(sim.ads_mol[int(du["cv"])] > 0.0, "the dryer takes water out of the gas")
	var ons := 0
	var offs := 0
	var lean := false
	for e2 in sim.events:
		var tx := str(e2["text"])
		if str(e2["id"]) == "auto" and tx.ends_with(" on."):
			ons += 1
		elif str(e2["id"]) == "auto" and tx.ends_with(" off."):
			offs += 1
		lean = lean or str(e2["id"]).begins_with("engine_lean")
	_ok(ons >= 2 and offs >= 2, "the rules start and stop the genset off the holder (%d on, %d off)" % [ons, offs])
	var ml := sim.mass_ledger()
	_ok(absf(float(ml["error_kg"])) < 1e-6, "mass still closes with gas burned and water adsorbed (%s kg)" % str(float(ml["error_kg"])))
	var el := sim.energy_ledger()
	var e_in := float(el["in"])
	var bal := float(el["stored"]) + float(el["loss"]) + float(el["coolant"]) + float(el["reaction"]) + float(el["out"])
	_ok(absf(bal - e_in) / e_in < 0.01, "energy still closes within 1 %% (%.2f %%)" % (absf(bal - e_in) / e_in * 100.0))
	# With the genset never on, the full bell blows off through its seal and
	# never builds pressure.
	var p2 := proc.duplicate(true)
	p2["automations"] = []
	var sb := TcProcSim.create(d, p2)
	var p_max := 0.0
	while sb.t_s < 2.0 * 3600.0:
		sb.run_for(60.0)
		p_max = maxf(p_max, sb.p_cv[hi] - TcSpecies.P_ATM)
	var blew := false
	for e3 in sb.events:
		blew = blew or str(e3["id"]).begins_with("bell_blow")
	_ok(blew and sb.holder_fill(hu) > 0.99, "a full bell blows off through its water seal")
	_ok(p_max < float(hu["hold_pa"]) - TcSpecies.P_ATM + TcProcSim.SEAL_BLOW_PA + 3000.0,
		"so it never builds more than a few kPa (%.1f kPa; a 45 L float overshoots its seal a little inside one step)" % (p_max * 0.001))
	# A genset switched on over air does not fire.
	var p3 := proc.duplicate(true)
	p3["automations"] = []
	p3["engines"] = {str(pb[1][0]): {"on": true}}
	var sc := TcProcSim.create(d, TcProcSpec.resolve(p3))
	sc.run_for(30.0)
	var lean2 := false
	for e4 in sc.events:
		lean2 = lean2 or str(e4["id"]).begins_with("engine_lean")
	_ok(lean2 and float(sc.engine_kw.get(str(pb[1][0]), 0.0)) == 0.0, "a genset on air will not fire")


func _ledgers_close(sim: TcProcSim, what: String) -> void:
	var ml := sim.mass_ledger()
	_ok(absf(float(ml["error_kg"])) < 1e-6, "%s: mass closes (%s kg)" % [what, str(float(ml["error_kg"]))])
	var el := sim.energy_ledger()
	var e_in := maxf(float(el["in"]), 1.0)
	var bal := float(el["stored"]) + float(el["loss"]) + float(el["coolant"]) + float(el["reaction"]) + float(el["out"])
	_ok(is_finite(bal) and absf(bal - e_in) / e_in < 0.01, "%s: energy closes within 1 %% (%.2f %%)" % [what, absf(bal - e_in) / e_in * 100.0])


func _has_event(sim: TcProcSim, id: String) -> float:
	for e in sim.events:
		if str(e["id"]) == id:
			return float(e["t_s"])
	return INF


## Phase 9: the presets' own scenarios. A pot still distils a wash (bubble
## point, reflux, spirit at the product end, nothing escaping); a kettle
## comes to the boil and boils off; a plastic retort melts, cracks and drops
## oil and wax, and stays finite (an emptied plastic cell has no char to
## keep its heat — it used to go to −10⁶ K and NaN the whole run).
func _test_scenarios() -> void:
	var I_E := TcProcSim.SP.find("ethanol")
	# Pot still.
	var spec := TcPresets.builtin("pot_still")
	var d := TcDesign.solve(spec)
	var sim := TcProcSim.create(d, spec["process"])
	var bp := 0.0
	while sim.t_s < 3.0 * 3600.0:
		sim.run_for(300.0)
		if _has_event(sim, "boil_0") < INF and bp == 0.0:
			bp = sim.liq_t(sim.vessel_cv) - 273.15
	print("pot still: boils at %.1f °C, distillate %.2f kg water + %.2f kg ethanol, vented %.3f kg" % [bp,
		sim.drained_mol[0] * 0.018015, sim.drained_mol[I_E] * 0.046069, sim.vented_mol[0] * 0.018015 + sim.vented_mol[I_E] * 0.046069])
	_ok(bp > 89.0 and bp < 96.0, "a 10 %% wash boils near its bubble point (%.1f °C), not at 100" % bp)
	var w_kg := sim.drained_mol[0] * 0.018015
	var e_kg := sim.drained_mol[I_E] * 0.046069
	_ok(w_kg + e_kg > 1.0, "spirit runs out of the product end (%.2f kg)" % (w_kg + e_kg))
	var abv := (e_kg / 0.789) / maxf(e_kg / 0.789 + w_kg, 1e-9) * 100.0
	_ok(abv > 20.0 and abv < 70.0, "stronger than the wash, as a reflux pot still makes (%.0f %% ABV)" % abv)
	var vented := sim.vented_mol[0] * 0.018015 + sim.vented_mol[I_E] * 0.046069
	_ok(vented < 0.05 * (w_kg + e_kg), "the condensers take it all: little vapour escapes (%.3f kg)" % vented)
	_ledgers_close(sim, "pot still")
	# Kettle.
	spec = TcPresets.builtin("brew_kettle")
	d = TcDesign.solve(spec)
	sim = TcProcSim.create(d, spec["process"])
	sim.run_for(float(spec["process"]["duration_h"]) * 3600.0)
	var tb := _has_event(sim, "boil_0")
	_ok(tb < 2.0 * 3600.0, "40 L on 3 kW comes to the boil in under 2 h (%.2f h)" % (tb / 3600.0))
	var off_kg := (sim.vented_mol[0] + sim.product_mol[0]) * 0.018015
	_ok(off_kg > 0.5, "and boils off through its vent (%.2f kg)" % off_kg)
	_ledgers_close(sim, "kettle")
	# Plastic retort.
	spec = TcPresets.builtin("plastic_retort")
	_ok(str(TcDesign.bound_preset(spec).get("label", "")) == "Plastic-to-Fuel Retort",
		"the plastic retort's graph node is the Plastic-to-Fuel Retort preset")
	d = TcDesign.solve(spec)
	sim = TcProcSim.create(d, spec["process"])
	var finite := true
	while sim.t_s < float(spec["process"]["duration_h"]) * 3600.0:
		sim.run_for(600.0)
		finite = finite and is_finite(sim.gas_t(sim.vessel_cv)) and is_finite(float(sim.bed.totals()["t_max_k"]))
	var tot := sim.bed.totals()
	var cond: Dictionary = sim.readings().get("condensate_total", {})
	var ow := float(cond.get("oil", 0.0)) + float(cond.get("wax", 0.0))
	print("plastic retort: %.0f %% cracked, oil + wax %.2f kg, plastic left %.2f kg" % [float(tot["pyro_frac"]) * 100.0, ow, float(tot["plastic_kg"])])
	_ok(finite, "a plastic charge stays finite to the end (no empty-cell blow-up)")
	_ok(_has_event(sim, "melt") < _has_event(sim, "pyrolysis"), "the pellets melt before they crack")
	_ok(float(tot["pyro_frac"]) > 0.85, "most of the plastic cracks in 8 h (%.0f %%)" % (float(tot["pyro_frac"]) * 100.0))
	_ok(ow > 2.0, "the condensers drop oil and wax (%.2f kg)" % ow)
	_ok(float(tot["char_kg"]) < 1e-6, "and plastic leaves no char")
	_ledgers_close(sim, "plastic retort")


## Liquid lines between vessels: a pump's curve, a control valve's opening,
## gravity, one-way parts, and the level rig's PID holding its tank.
func _test_liquid_lines() -> void:
	var spec := TcPresets.builtin("level_rig")
	_ok(not spec.is_empty(), "the level rig preset builds")
	var d := TcDesign.solve(spec)
	_ok((d.get("clashes", []) as Array).is_empty(), "the rig has no clash")
	var err := 0
	for c in d.get("checks", []):
		if str(c.get("level", "")) == "error":
			err += 1
	_ok(err == 0, "the rig has no error-level check")
	var proc: Dictionary = (d["spec"] as Dictionary)["process"]
	var no_logic: Dictionary = proc.duplicate(true)
	no_logic["logic"] = []
	var sim := TcProcSim.create(d, no_logic)
	_ok(sim.lines.size() == 2, "two liquid lines between the three tanks (%d)" % sim.lines.size())
	var kinds := {}
	for l in sim.net["links"]:
		kinds[str(l["kind"])] = int(kinds.get(str(l["kind"]), 0)) + 1
	_ok(int(kinds.get("pump", 0)) == 1 and int(kinds.get("valve", 0)) == 2, "one pump and two control valves are links (%s)" % [kinds])
	var acts := TcProcControl.actuators(sim, d, sim.proc)
	var keys := {}
	for a in acts:
		keys[str(a["act"]).get_slice(":", 0)] = true
	_ok(keys.has("pump") and keys.has("pumpspeed") and keys.has("cvalve"), "the pump's switch and speed and the valves' openings are actuators")
	var sens := TcProcControl.sensors(sim, d, sim.proc)
	var n_level := 0
	var n_flow := 0
	for sx in sens:
		if str(sx["key"]).ends_with("_level"):
			n_level += 1
		if str(sx["key"]).ends_with("_flow"):
			n_flow += 1
	_ok(n_level == 3 and n_flow == 1, "a level per tank and a flow per pump are sensors (%d, %d)" % [n_level, n_flow])
	var l0: Dictionary = sim.lines[0]
	var l1: Dictionary = sim.lines[1]
	var a_cv := int(l0["a"])
	var b_cv := int(l0["b"])
	var c_cv := int(l1["b"])
	var pump_id := ""
	var valve_id := ""
	var drain_id := ""
	for li in l0["links"]:
		var lk: Dictionary = sim.net["links"][li]
		if str(lk["kind"]) == "pump":
			pump_id = str(lk["part"])
		elif str(lk["kind"]) == "valve":
			valve_id = str(lk["part"])
	for li2 in l1["links"]:
		if str(sim.net["links"][li2]["kind"]) == "valve":
			drain_id = str(sim.net["links"][li2]["part"])
	var total0 := 0.0
	var h0 := 0.0
	for i in sim.n_cv:
		total0 += sim._liq_volume(sim.liq[i])
		h0 += sim.h_liq[i]
	_ok(sim._liq_volume(sim.liq[a_cv]) > 0.1 and sim._liq_volume(sim.liq[b_cv]) < 1e-6, "the charge is in the supply tank")
	# The pump's operating point by hand: valve wide open, drain shut.
	sim.set_actuator("cvalve:%s" % drain_id, 0.0)
	sim.set_actuator("cvalve:%s" % valve_id, 100.0)
	var sa := sim.liquid_surface_m(a_cv)
	var zb := float(l0["zb"])
	var area := PI * float(l0["r_m"]) * float(l0["r_m"])
	var kk := (TcProcSim.LINE_K_ENDS + TcProcSim.LINE_F * float(l0["len_m"]) / (2.0 * float(l0["r_m"])) + TcProcSim.LINE_K_VALVE) / (2.0 * TcProcSim.GRAV * area * area)
	var qm := 10.0 / 60000.0
	var want := sqrt((sa - zb + 1.0) / (kk + 1.0 / (qm * qm))) * 60000.0
	sim.step(1.0)
	_near(float(sim.pump_lpm[pump_id]), want, want * 0.01, "the pump moves what its curve and the line's friction give (%.2f L/min)" % want)
	_ok(want < 10.0 and want > 1.0, "less than its free flow, more than a trickle")
	# Half speed: a quarter of the head, half the free flow.
	sim.set_actuator("pumpspeed:%s" % pump_id, 50.0)
	sim.step(1.0)
	var sa2 := sim.liquid_surface_m(a_cv)
	var sb2 := maxf(sim.liquid_surface_m(b_cv), zb)
	var want2 := sqrt((sa2 - sb2 + 0.25) / (kk + 0.25 / (qm * 0.5 * qm * 0.5))) * 60000.0
	_near(float(sim.pump_lpm[pump_id]), want2, want2 * 0.02, "at half speed: a quarter of the head, half the free flow (%.2f L/min)" % want2)
	sim.set_actuator("pumpspeed:%s" % pump_id, 100.0)
	# The valve nearly shut moves far less; shut, nothing.
	sim.set_actuator("cvalve:%s" % valve_id, 10.0)
	sim.step(1.0)
	var q10 := float(sim.pump_lpm[pump_id])
	_ok(q10 < want * 0.6 and q10 > 0.0, "the valve at 10 %% throttles it (%.2f L/min)" % q10)
	sim.set_actuator("cvalve:%s" % valve_id, 0.0)
	var vb := sim._liq_volume(sim.liq[b_cv])
	sim.run_for(30.0, 1.0)
	_near(sim._liq_volume(sim.liq[b_cv]), vb, 2e-6, "shut, nothing passes (to 2 mL: the open tank evaporates a little)")
	_near(float(sim.pump_lpm[pump_id]), 0.0, 1e-9, "and the pump moves nothing")
	# Pump off, valve open: the supply still runs through the stopped pump by
	# gravity while it stands higher, and nothing ever comes back.
	sim.set_actuator("pump:%s" % pump_id, false)
	sim.set_actuator("cvalve:%s" % valve_id, 100.0)
	sim.run_for(600.0, 1.0)
	var sa3 := sim.liquid_surface_m(a_cv)
	var sb3 := sim.liquid_surface_m(b_cv)
	_ok(sim._liq_volume(sim.liq[b_cv]) > vb + 1e-4, "with the pump stopped the higher tank still runs into the lower one")
	_ok(sb3 <= sa3 + 0.002, "and never past level (%.3f m vs %.3f m)" % [sb3, sa3])
	# The drain: gravity out of the process tank into the receiver's top.
	sim.set_actuator("cvalve:%s" % valve_id, 0.0)
	sim.set_actuator("cvalve:%s" % drain_id, 25.0)
	var vb4 := sim._liq_volume(sim.liq[b_cv])
	sim.step(1.0)
	var head := sim.liquid_surface_m(b_cv) - float(l1["zb"])
	var kd := (TcProcSim.LINE_K_ENDS + TcProcSim.LINE_F * float(l1["len_m"]) / (2.0 * float(l1["r_m"])) + TcProcSim.LINE_K_VALVE / (0.25 * 0.25)) / (2.0 * TcProcSim.GRAV * area * area)
	_near(absf(float(l1["lpm"])), sqrt(head / kd) * 60000.0, 0.05, "the drain runs by Torricelli through the valve's K (%.2f L/min)" % absf(float(l1["lpm"])))
	sim.run_for(7200.0, 5.0)
	_ok(sim.liquid_surface_m(b_cv) <= float(l1["za"]) + 0.004, "the tank drains down to its nozzle and stops")
	_ok(sim._liq_volume(sim.liq[c_cv]) > vb4 * 0.5, "into the receiver")
	var total1 := 0.0
	var h1 := 0.0
	for i2 in sim.n_cv:
		total1 += sim._liq_volume(sim.liq[i2])
		h1 += sim.h_liq[i2]
	_near(total1, total0, total0 * 2e-4, "no liquid is made or lost moving it (%.2f L)" % (total1 * 1000.0))
	_ok(absf(h1 - h0) < maxf(absf(h0) * 0.02, 5.0e4), "its heat goes with it (%.0f → %.0f J)" % [h0, h1])
	var pa_a := float(sim.cv_state(a_cv)["p_kpa_g"])
	var pa_c := float(sim.cv_state(c_cv)["p_kpa_g"])
	_ok(absf(pa_a) < 1.0 and absf(pa_c) < 1.0, "the open tanks breathe: no vacuum over the one emptied, no pressure over the one filled (%.2f, %.2f kPa)" % [pa_a, pa_c])
	var ml := sim.mass_ledger()
	_ok(absf(float(ml["error_kg"])) < 0.01, "the mass ledger closes with the air breathed (%.4f kg)" % float(ml["error_kg"]))
	# A positive-displacement pump: its rated flow whatever the valve.
	var sp2: Dictionary = spec.duplicate(true)
	for p in sp2["parts"]:
		if str(p["id"]) == pump_id:
			p["params"]["kind"] = "positive"
			p["params"]["flow_lpm"] = 4.0
	var d2 := TcDesign.solve(TcSpec.resolve(sp2))
	var sim2 := TcProcSim.create(d2, no_logic)
	sim2.set_actuator("cvalve:%s" % valve_id, 30.0)
	sim2.step(1.0)
	_near(float(sim2.pump_lpm[pump_id]), 4.0, 1e-6, "a positive-displacement pump gives its rated flow against a throttled valve")
	sim2.set_actuator("pump:%s" % pump_id, false)
	var vb5 := sim2._liq_volume(sim2.liq[int(sim2.lines[0]["b"])])
	sim2.run_for(60.0, 1.0)
	_near(sim2._liq_volume(sim2.liq[int(sim2.lines[0]["b"])]), vb5, 2e-6, "stopped, it passes nothing")
	# The loop: the PID holds the process tank at half while the supply lasts.
	var sim3 := TcProcSim.create(d, proc)
	var slug := TcProcControl.slug(str((d["spec"] as Dictionary).get("name", "")))
	sim3.run_for(1200.0, 5.0)
	var tank_part := str(sim3.net["cvs"][b_cv].get("vessel_part", ""))
	var rd := TcProcControl.read_all(sim3, sim3.control_sensors)
	var lvl := float((rd.get("numeric_values", rd) as Dictionary).get("sensor.%s_%s_level" % [slug, tank_part], 0.0))
	_near(lvl, 50.0, 1.0, "the PID holds the tank at half (%.1f %%)" % lvl)
	var frac := 0.0
	for li3 in (sim3.net["links"] as Array).size():
		if str(sim3.net["links"][li3]["part"]) == valve_id:
			frac = float(sim3.link_frac[li3])
	_ok(frac > 0.03 and frac < 0.6, "with the valve part open (%.0f %%)" % (frac * 100.0))
	# Scrub: a restore brings the valve and the levels back.
	var snap := sim3.snapshot()
	var vkeep := sim3._liq_volume(sim3.liq[b_cv])
	sim3.set_actuator("cvalve:%s" % valve_id, 100.0)
	sim3.run_for(60.0, 5.0)
	sim3.restore(snap)
	_near(sim3._liq_volume(sim3.liq[b_cv]), vkeep, 1e-12, "a restore puts the level back")
	var frac2 := 0.0
	for li4 in (sim3.net["links"] as Array).size():
		if str(sim3.net["links"][li4]["part"]) == valve_id:
			frac2 = float(sim3.link_frac[li4])
	_near(frac2, frac, 1e-12, "and the valve's opening")
	# A design with one vessel has no lines and is untouched.
	var one := TcProcSim.create(TcDesign.solve(TcPresets.builtin("brew_kettle")))
	_ok(one.lines.is_empty() and one.pump_on.is_empty(), "a one-vessel design has no liquid lines")

func _imbalance(sim: TcProcSim) -> float:
	var el := sim.energy_ledger()
	return float(el["in"]) - float(el["stored"]) - float(el["loss"]) - float(el["coolant"]) - float(el["reaction"]) - float(el["out"])


func _vessel_cv_of(sim: TcProcSim, part: String) -> int:
	for i in sim.n_cv:
		if str(sim.net["cvs"][i]["role"]) == "vessel" and str(sim.net["cvs"][i].get("vessel_part", "")) == part:
			return i
	return -1


func _read(sim: TcProcSim, key: String) -> float:
	var rd := TcProcControl.read_all(sim, sim.control_sensors)
	return float((rd.get("numeric_values", rd) as Dictionary).get(key, NAN))


## The rest of the liquid plant: heaters and pools in several vessels, an
## agitator, a plate chiller, a jacket fed with hot water, branched lines,
## level switch / transmitter / flow meter parts, and the three presets.
func _test_liquid_plant() -> void:
	# ---- brewhouse: a sequence through four vessels ----
	var d := TcDesign.solve(TcPresets.builtin("brewhouse"))
	_ok((d.get("clashes", []) as Array).is_empty(), "the brewhouse has no clash")
	var sim := TcProcSim.create(d)
	var slug := TcProcControl.design_slug(d)
	_ok(sim.lines.size() == 3, "three lines between its four vessels (%d)" % sim.lines.size())
	_ok(sim.heater_parts.size() == 2 and sim.n_bed_heaters == 1, "an element in the liquor tank and one in the kettle")
	var cvs_h := {}
	for hp in sim.heater_parts:
		cvs_h[int(sim.heater_cv[hp])] = true
	_ok(cvs_h.size() == 2, "each in its own vessel")
	_ok(sim.agit.size() == 1 and sim._plate_hx.size() == 1, "one agitator and one plate exchanger are in the model")
	var acts := {}
	for a in sim.control_acts:
		acts[str(a["act"]).get_slice(":", 0)] = int(acts.get(str(a["act"]).get_slice(":", 0), 0)) + 1
	_ok(acts.has("agitator") and int(acts.get("pump", 0)) == 3, "the agitator and three pumps are switches (%s)" % [acts])
	var ferm := int(sim.lines[2]["b"])
	var kettle := int(sim.lines[2]["a"])
	var hot := 0.0
	var stirred := false
	for k in 30:
		sim.run_for(300.0, 5.0)
		hot = maxf(hot, sim.liq_t(kettle) - 273.15 if sim._liq_volume(sim.liq[kettle]) > 0.001 else 0.0)
		for ap in sim.agit_on.keys():
			stirred = stirred or bool(sim.agit_on[ap])
	var st: Dictionary = sim.logic_status.get("b1", {})
	_ok(str(st.get("run", "")) == "done", "the brew-day sequence runs to its end by itself (%s)" % str(st.get("text", "")))
	_ok(hot > 99.0, "the kettle's own element brought it to the boil (%.1f °C)" % hot)
	_ok(stirred, "the sequence ran the stirrer during the rest")
	var vf := sim._liq_volume(sim.liq[ferm]) * 1000.0
	var tf := sim.liq_t(ferm) - 273.15
	_ok(vf > 8.0, "wort reached the fermenter (%.1f L)" % vf)
	_ok(tf < 30.0, "through the chiller it arrives cool (%.1f °C from a %.0f °C kettle)" % [tf, hot])
	_ok(absf(_imbalance(sim)) < float(sim.energy_ledger()["in"]) * 0.002, "the energy ledger closes with boiling, pumps, stirrer and chiller (%.0f J of %.0f)" % [_imbalance(sim), float(sim.energy_ledger()["in"])])
	_ok(absf(float(sim.mass_ledger()["error_kg"])) < 0.01, "and the mass ledger")
	_ok(not is_nan(_read(sim, "sensor.%s_%s_liquid_temp" % [slug, str(sim.net["cvs"][ferm].get("vessel_part", ""))])), "every vessel on a line has a liquid temperature sensor")
	# The chiller by hand: counter-flow effectiveness for the knock-out flow.
	var c_h := 6.0 / 60.0 * 4186.0
	var c_c := 8.0 / 60.0 * 4186.0
	var ntu := TcProcSim.U_PLATE * 0.9 / c_h
	var cr := c_h / c_c
	var eff := (1.0 - exp(-ntu * (1.0 - cr))) / (1.0 - cr * exp(-ntu * (1.0 - cr)))
	_ok(eff > 0.9 and tf < 12.0 + (100.0 - 12.0) * (1.0 - eff) + 8.0, "as the effectiveness of 30 plates says (ε %.3f)" % eff)
	# A snapshot keeps the new switches.
	var ap0 := str(sim.agit_on.keys()[0])
	sim.set_actuator("agitator:%s" % ap0, true)
	var snap := sim.snapshot()
	sim.set_actuator("agitator:%s" % ap0, false)
	sim.restore(snap)
	_ok(bool(sim.agit_on[ap0]), "a restore brings the agitator's switch back")

	# ---- CIP skid: a tee, two sources on one pump ----
	var d2 := TcDesign.solve(TcPresets.builtin("cip_skid"))
	_ok((d2.get("clashes", []) as Array).is_empty(), "the CIP skid has no clash")
	var s2 := TcProcSim.create(d2)
	_ok(s2.lines.size() == 4, "the tee gives four lines: rinse → vessel, wash → vessel, rinse ↔ wash, vessel → receiver (%d)" % s2.lines.size())
	var ids2: Dictionary = {}
	for ln in s2.lines:
		ids2[int(ln["a"])] = true
		ids2[int(ln["b"])] = true
	var recv := -1
	var total0 := 0.0
	for i in ids2.keys():
		total0 += s2._liq_volume(s2.liq[int(i)])
		if s2._liq_volume(s2.liq[int(i)]) < 1e-6 and float(s2._vessel_floor[int(i)]) < 0.1:
			recv = int(i)
	_ok(recv >= 0, "the receiver stands on the floor, empty")
	# Both solenoids shut at the start: nothing moves.
	var no_logic: Dictionary = ((d2["spec"] as Dictionary)["process"] as Dictionary).duplicate(true)
	no_logic["logic"] = []
	var s2b := TcProcSim.create(d2, no_logic)
	var before: Array = []
	for i2 in ids2.keys():
		before.append(s2b._liq_volume(s2b.liq[int(i2)]))
	for a2 in s2b.control_acts:
		if str(a2["act"]).begins_with("pump:"):
			s2b.set_actuator(str(a2["act"]), true)
	s2b.run_for(120.0, 5.0)
	var moved := 0.0
	var kk := 0
	for i3 in ids2.keys():
		moved += absf(s2b._liq_volume(s2b.liq[int(i3)]) - float(before[kk]))
		kk += 1
	_ok(moved < 1e-4, "with the solenoid valves shut the pump moves nothing (%.3f L)" % (moved * 1000.0))
	var wash_hot := 0.0
	for k2 in 18:
		s2.run_for(300.0, 5.0)
	for i4 in ids2.keys():
		wash_hot = maxf(wash_hot, s2.liq_t(int(i4)) - 273.15)
	var st2: Dictionary = s2.logic_status.get("b2", {})
	_ok(str(st2.get("run", "")) == "done", "the clean-in-place sequence runs to its end (%s)" % str(st2.get("text", "")))
	_ok(wash_hot > 58.0 and wash_hot < 70.0, "the band held the wash tank near 60–65 °C (%.1f °C)" % wash_hot)
	_ok(s2._liq_volume(s2.liq[recv]) * 1000.0 > 55.0, "two rinses and a wash ended in the receiver (%.0f L)" % (s2._liq_volume(s2.liq[recv]) * 1000.0))
	var total1 := 0.0
	for i5 in ids2.keys():
		total1 += s2._liq_volume(s2.liq[int(i5)])
	_ok(absf(total1 - total0) < total0 * 0.01, "no liquid made or lost on the way (%.1f → %.1f L)" % [total0 * 1000.0, total1 * 1000.0])
	_ok(absf(_imbalance(s2)) < float(s2.energy_ledger()["in"]) * 0.002, "its energy ledger closes")

	# ---- water filter train: band + level switch + flow meter ----
	var d3 := TcDesign.solve(TcPresets.builtin("water_filter_train"))
	_ok((d3.get("clashes", []) as Array).is_empty(), "the filter train has no clash")
	var s3 := TcProcSim.create(d3)
	var slug3 := TcProcControl.design_slug(d3)
	var clean := int(s3.lines[0]["b"])
	var clean_part := str(s3.net["cvs"][clean].get("vessel_part", ""))
	var sw_key := ""
	var fm_key := ""
	for e in s3.control_sensors:
		var src: Dictionary = e["src"]
		if str(src["kind"]) == "level_switch":
			sw_key = str(e["key"])
		elif str(src["kind"]) == "line_flow":
			fm_key = str(e["key"])
	_ok(sw_key != "" and fm_key != "", "the level switch and the flow meter are sensors")
	var lo := 100.0
	var hi := 0.0
	var starts := 0
	var was_on := false
	var metered := 0.0
	var pump3 := str(s3.pump_on.keys()[0])
	for k3 in 300:
		s3.run_for(5.0, 5.0)
		var lv := _read(s3, "sensor.%s_%s_level" % [slug3, clean_part])
		if s3.t_s > 420.0 and s3.liquid_surface_m(int(s3.lines[0]["a"])) > float(s3.lines[0]["za"]) + 0.05:
			lo = minf(lo, lv)
			hi = maxf(hi, lv)
		var on := bool(s3.pump_on[pump3])
		if on and not was_on:
			starts += 1
		was_on = on
		metered = maxf(metered, _read(s3, fm_key))
	_ok(lo > 33.0 and hi < 86.0 and hi > lo + 15.0, "the band keeps the clean tank between its marks while the raw tank lasts (%.0f to %.0f %%)" % [lo, hi])
	_ok(starts >= 2, "the pump cycles (%d starts)" % starts)
	_ok(metered > 3.0, "the flow meter reads the pump's flow (%.1f L/min at most)" % metered)
	_near(_read(s3, sw_key), 0.0, 1e-9, "the high level switch is dry at 80 %")
	# Fill past the switch: it reads wet, and the interlock holds the pump off.
	s3.logic_blocks = [s3.logic_blocks[1]]
	for a3 in s3.control_acts:
		if str(a3["act"]).begins_with("cvalve:"):
			s3.set_actuator(str(a3["act"]), 0.0)
	s3._fill_liquid(clean, {"mass_kg": 60.0}, TcProcSpec.FEEDS["water"], 293.15)
	s3.set_actuator("pump:%s" % pump3, true)
	s3.run_for(20.0, 5.0)
	_near(_read(s3, sw_key), 1.0, 1e-9, "filled past it the switch reads wet")
	_ok(not bool(s3.pump_on[pump3]), "and the interlock holds the pump off")

	# ---- a jacket fed with hot water ----
	var dj := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	var pj: Dictionary = TcProcSpec.kettle_default()
	pj["charge"]["mass_kg"] = 30.0
	pj["heaters"]["default_w"] = 0.0
	var vpart := ""
	for p in dj["spec"]["parts"]:
		if str(p["type"]) == "vessel":
			vpart = str(p["id"])
	pj["jackets"] = {vpart: {"t_c": 80.0, "lpm": 12.0, "on": true}}
	var sj := TcProcSim.create(dj, pj)
	_ok(sj.jacket.size() == 1, "a jacketed vessel takes a service medium")
	var jacts := 0
	for a4 in sj.control_acts:
		if str(a4["act"]).begins_with("jacket"):
			jacts += 1
	_ok(jacts == 2, "its jacket has a switch and a water temperature")
	sj.run_for(3.0 * 3600.0, 10.0)
	var tj := sj.liq_t(sj.vessel_cv) - 273.15
	_ok(tj > 70.0 and tj < 80.5, "hot water round the vessel warms the liquid toward its own 80 °C (%.1f °C after 3 h)" % tj)
	_ok(absf(_imbalance(sj)) < absf(float(sj.energy_ledger()["coolant"])) * 0.01 + 1.0, "booked as heat from the medium, the ledger closes")
	sj.set_actuator("jackett:%s" % vpart, 10.0)
	sj.run_for(3.0 * 3600.0, 10.0)
	_ok(sj.liq_t(sj.vessel_cv) - 273.15 < 25.0, "cold water in the jacket cools it again (%.1f °C)" % (sj.liq_t(sj.vessel_cv) - 273.15))

	# ---- design rules ----
	var bad := TcSpec.empty("bad")
	var r := TcAssembly.add_part(bad, "spool", "1.5", {"length_mm": 100.0}, Transform3D.IDENTITY)
	bad = r[0]
	r = TcAssembly.add_part(bad, "pump", "1.5", {}, Transform3D.IDENTITY)
	bad = r[0]
	var pmp: String = r[1]
	r = TcAssembly.add_part(bad, "control_valve", "1.5", {}, Transform3D.IDENTITY)
	bad = r[0]
	(bad["joints"] as Array).append({"a": pmp + ":b", "b": str(r[1]) + ":a", "roll_deg": 0.0, "gasket": "epdm", "clamp": "single_pin"})
	var db := TcDesign.solve(TcSpec.resolve(bad))
	var warned := false
	for c in db.get("checks", []):
		if str(c.get("text", "")).contains("clamped straight to"):
			warned = true
	_ok(warned, "a pump clamped straight to a valve is flagged")
	var clean_presets := true
	for id in ["level_rig", "brewhouse", "cip_skid", "water_filter_train", "biochar_reactor"]:
		for c2 in TcDesign.solve(TcPresets.builtin(id)).get("checks", []):
			if str(c2.get("text", "")).contains("clamped straight to"):
				clean_presets = false
	_ok(clean_presets, "none of the built-ins is")
	var dk := TcDesign.solve(TcPresets.builtin("brew_kettle"))
	var sk := TcProcSim.create(dk)
	var hand := 0
	for a5 in sk.control_acts:
		if bool(a5.get("hand", false)):
			hand += 1
	_ok(hand == 1, "the kettle's ball valve is a hand valve (no actuator on its stem)")
	var rows := TcProcBoard.rows(sk, sk.proc)
	var relay_for_hand := false
	for rw2 in rows:
		for a6 in sk.control_acts:
			if bool(a6.get("hand", false)) and str(rw2.get("key", "")) == str(a6["key"]) and str(rw2.get("part", "")) != "":
				relay_for_hand = true
	_ok(not relay_for_hand, "the controller board gives a hand valve no relay")
	var s2c := TcProcSim.create(d2)
	var driven := 0
	for a7 in s2c.control_acts:
		if a7.has("hand") and not bool(a7["hand"]):
			driven += 1
	_ok(driven == 3, "the skid's three solenoid valves are driven (%d)" % driven)
