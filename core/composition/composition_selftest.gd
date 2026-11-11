extends SceneTree

## Resource composition, Phase 1 (plans/RESOURCE_COMPOSITION_PLAN.md):
## CompositionData + CompositionCatalog + MassBalance, offline:
##   Godot --headless --path . --script core/composition/composition_selftest.gd
## (run --import first so the class_names register).
##
## Pins: the formula parser (fractions, parentheses, bad input), molar
## masses; every builtin material kind composed and every composition row a
## real kind; fractions summing to 1; rows citing a source or saying they
## are estimates; hand numbers (urine N, seawater salts, food N, a person's
## N in vs out, gas densities and heating values); the water grade ladder;
## embodied totals; aliases; MassBalance on a balanced preset, a burner
## with its air side declared, an unbalanced process and an unknown kind.
## Carries EXPECTED_CHECKS: a Godot runtime error aborts the enclosing test
## function while the suite still prints PASS.

const EXPECTED_CHECKS := 88

var _checks := 0
var _fails := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


static func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _initialize() -> void:
	_test_formulas()
	_test_coverage()
	_test_fractions()
	_test_sources()
	_test_hand_numbers()
	_test_grades()
	_test_embodied()
	_test_mass_balance()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	var est := CompositionCatalog.estimates()
	print("composition: %d components, %d kinds, %d rows marked est" % [CompositionData.COMPONENTS.size(),
		CompositionData.KINDS.size(), est.size()])
	if _fails == 0:
		print("COMPOSITION SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("COMPOSITION SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _test_formulas() -> void:
	var w := CompositionCatalog.formula_elements("H2O")
	_check("water H 11.19 %", _near(float(w.get("H", 0.0)), 0.1119, 0.0002), str(w))
	var u := CompositionCatalog.formula_elements("CH4N2O")
	_check("urea N 46.65 %", _near(float(u.get("N", 0.0)), 0.4665, 0.0003), str(u))
	var cb := CompositionCatalog.formula_counts("Ca(HCO3)2")
	_check("parentheses: Ca(HCO3)2 = Ca1 H2 C2 O6",
		_near(float(cb.get("Ca", 0)), 1.0, 1e-9) and _near(float(cb.get("H", 0)), 2.0, 1e-9)
		and _near(float(cb.get("C", 0)), 2.0, 1e-9) and _near(float(cb.get("O", 0)), 6.0, 1e-9), str(cb))
	var fr := CompositionCatalog.formula_counts("C4.43H7O1.44")
	_check("fractional subscripts", _near(float(fr.get("C", 0)), 4.43, 1e-9) and _near(float(fr.get("O", 0)), 1.44, 1e-9), str(fr))
	_check("unreadable formula gives {}", CompositionCatalog.formula_counts("h2o").is_empty()
		and CompositionCatalog.formula_counts("C(H2").is_empty())
	_check("molar mass H2O 18.015", _near(CompositionCatalog.molar_mass("H2O"), 18.015, 0.002))
	_check("molar mass CO2 44.009", _near(CompositionCatalog.molar_mass("CO2"), 44.009, 0.002))
	var br := CompositionCatalog.formula_elements("NaBr")
	_check("untracked element (Br) counts as X", float(br.get("X", 0.0)) > 0.7 and not br.has("Br"), str(br))


func _test_coverage() -> void:
	var missing := CompositionCatalog.uncomposed_builtin_kinds()
	_check("every builtin material kind has a composition", missing.is_empty(), str(missing))
	for k in CompositionData.NON_MATERIAL:
		if not CompositionCatalog.is_material(str(k)) and ResourceKinds.BUILTIN.has(str(k)):
			continue
		_check("non-material %s is a builtin and not material" % k, false)
	_check("non-material kinds are not material", not CompositionCatalog.is_material("electric")
		and not CompositionCatalog.is_material("thermal") and CompositionCatalog.is_material("water"))
	var strays: Array = []
	for k2 in CompositionData.KINDS.keys():
		var r: Dictionary = CompositionData.KINDS[k2]
		if not bool(r.get("internal", false)) and not ResourceKinds.BUILTIN.has(str(k2)):
			strays.append(str(k2))
	_check("every composition row is a ResourceKinds builtin (or internal)", strays.is_empty(), str(strays))
	var bad_refs: Array = []
	for k3 in CompositionData.KINDS.keys():
		var r3: Dictionary = CompositionData.KINDS[k3]
		for cid in (r3.get("mix", {}) as Dictionary).keys():
			if not CompositionCatalog.has_component(str(cid)):
				bad_refs.append("%s→%s" % [k3, cid])
		for cid2 in (r3.get("moles", {}) as Dictionary).keys():
			if not CompositionCatalog.has_component(str(cid2)):
				bad_refs.append("%s→%s" % [k3, cid2])
		for sub in (r3.get("kinds", {}) as Dictionary).keys():
			if not CompositionData.KINDS.has(str(sub)):
				bad_refs.append("%s→kind %s" % [k3, sub])
		if r3.has("rest") and not CompositionCatalog.has_component(str(r3["rest"])):
			bad_refs.append("%s→rest %s" % [k3, r3["rest"]])
	for cid3 in CompositionData.COMPONENTS.keys():
		var c: Dictionary = CompositionData.COMPONENTS[cid3]
		for sub2 in (c.get("mix", {}) as Dictionary).keys():
			if not CompositionCatalog.has_component(str(sub2)):
				bad_refs.append("component %s→%s" % [cid3, sub2])
		if c.has("formula") and CompositionCatalog.formula_counts(str(c["formula"])).is_empty():
			bad_refs.append("component %s formula" % cid3)
	_check("every reference resolves (components, sub-kinds, formulas)", bad_refs.is_empty(), str(bad_refs))


func _test_fractions() -> void:
	var bad_comp: Array = []
	for cid in CompositionData.COMPONENTS.keys():
		var s := 0.0
		for v in CompositionCatalog.component_elements(str(cid)).values():
			s += float(v)
		if not _near(s, 1.0, 0.005):
			bad_comp.append("%s %.4f" % [cid, s])
	_check("every component's elements sum to 1", bad_comp.is_empty(), str(bad_comp))
	var over: Array = []
	var short: Array = []
	var bad_kind: Array = []
	for k in CompositionData.KINDS.keys():
		var r: Dictionary = CompositionData.KINDS[k]
		var listed := CompositionCatalog.listed_fraction(str(k))
		if r.has("rest"):
			if listed > 1.0 + 1e-6:
				over.append("%s %.4f" % [k, listed])
		elif not _near(listed, 1.0, 0.005):
			short.append("%s %.4f" % [k, listed])
		var cs := 0.0
		for v2 in CompositionCatalog.components_of(str(k)).values():
			cs += float(v2)
		var es := 0.0
		for v3 in CompositionCatalog.elements_of(str(k)).values():
			es += float(v3)
		if not _near(cs, 1.0, 0.005) or not _near(es, 1.0, 0.006):
			bad_kind.append("%s comps %.4f elements %.4f" % [k, cs, es])
	_check("no row with `rest` lists more than 1", over.is_empty(), str(over))
	_check("rows without `rest` list exactly 1", short.is_empty(), str(short))
	_check("every kind's components and elements sum to 1", bad_kind.is_empty(), str(bad_kind))
	_check("element_vector is over ELEMENTS", CompositionCatalog.element_vector("water").size()
		== CompositionCatalog.ELEMENTS.size())


func _test_sources() -> void:
	var unsourced: Array = []
	for k in CompositionData.KINDS.keys():
		var r: Dictionary = CompositionData.KINDS[k]
		var derived := r.has("kinds") and not r.has("mix") and not r.has("moles")
		if str(r.get("src", "")).is_empty() and not bool(r.get("est", false)) and not derived:
			unsourced.append(str(k))
	_check("every kind row cites a source, is marked est, or derives from other kinds", unsourced.is_empty(), str(unsourced))
	var est := CompositionCatalog.estimates()
	var has_lignin := false
	for e in est:
		if str((e as Dictionary).get("id", "")) == "lignin":
			has_lignin = true
	_check("estimates() lists the judgement calls (lignin)", has_lignin and est.size() > 10, "%d" % est.size())
	_check("an estimate kind reads as one", CompositionCatalog.is_estimate("greywater")
		and not CompositionCatalog.is_estimate("seawater"))


func _test_hand_numbers() -> void:
	var urine_n := float(CompositionCatalog.elements_of("urine").get("N", 0.0)) * 1000.0
	_check("urine N 7.27 g/kg (Vinnerås 2006)", _near(urine_n, 7.27, 0.08), "%.3f" % urine_n)
	var urine_p := float(CompositionCatalog.elements_of("urine").get("P", 0.0)) * 1000.0
	_check("urine P 0.60 g/kg", _near(urine_p, 0.60, 0.02), "%.3f" % urine_p)
	var urine_k := float(CompositionCatalog.elements_of("urine").get("K", 0.0)) * 1000.0
	_check("urine K 1.82 g/kg", _near(urine_k, 1.82, 0.03), "%.3f" % urine_k)
	_check("urine is ~97 % water", _near(CompositionCatalog.water_fraction("urine"), 0.970, 0.005))
	var feces := CompositionCatalog.elements_of("feces")
	_check("feces N 10.8 g/kg wet", _near(float(feces.get("N", 0.0)) * 1000.0, 10.8, 0.3),
		"%.2f" % (float(feces.get("N", 0.0)) * 1000.0))
	_check("feces P 3.5, K 7.1 g/kg", _near(float(feces.get("P", 0.0)) * 1000.0, 3.53, 0.15)
		and _near(float(feces.get("K", 0.0)) * 1000.0, 7.06, 0.2))
	_check("feces 78.4 % water", _near(CompositionCatalog.water_fraction("feces"), 0.784, 0.003))
	var sea := CompositionCatalog.elements_of("seawater")
	_check("seawater Cl 19.35 g/kg", _near(float(sea.get("Cl", 0.0)) * 1000.0, 19.35, 0.05),
		"%.3f" % (float(sea.get("Cl", 0.0)) * 1000.0))
	_check("seawater Na 10.78 g/kg", _near(float(sea.get("Na", 0.0)) * 1000.0, 10.78, 0.05))
	_check("seawater salinity 35.165 g/kg", _near((1.0 - CompositionCatalog.water_fraction("seawater")) * 1000.0, 35.165, 0.01))
	var food_n := float(CompositionCatalog.elements_of("food").get("N", 0.0)) * 1000.0
	_check("food N 10.4 g/kg (65 g protein)", _near(food_n, 10.4, 0.1), "%.3f" % food_n)
	# A person in nitrogen balance: 1.5 kg food a day, a fifth of it left as
	# scraps, so 1.2 kg eaten; 1.42 L urine (the habitat's urine yield) +
	# 0.14 kg feces out, within sweat / hair losses.
	var n_in := float(CompositionCatalog.embodied("food", 1.2)["elements"].get("N", 0.0))
	var n_out := float(CompositionCatalog.embodied("urine", 1.42)["elements"].get("N", 0.0)) \
		+ float(CompositionCatalog.embodied_kg("feces", 0.14)["elements"].get("N", 0.0))
	_check("a person excretes 90–100 % of the N they eat", n_out / n_in > 0.90 and n_out / n_in <= 1.0,
		"in %.2f g, out %.2f g" % [n_in * 1000.0, n_out * 1000.0])
	_check("biogas 1.215 kg/Nm³", _near(CompositionCatalog.kg_per_unit("biogas"), 1.215, 0.005),
		"%.4f" % CompositionCatalog.kg_per_unit("biogas"))
	_check("woodgas 1.132 kg/Nm³", _near(CompositionCatalog.kg_per_unit("woodgas"), 1.132, 0.005),
		"%.4f" % CompositionCatalog.kg_per_unit("woodgas"))
	var wg_mj_m3 := CompositionCatalog.lhv_mj_per_kg("woodgas") * CompositionCatalog.kg_per_unit("woodgas")
	_check("woodgas ~12 MJ/Nm³ (TC lab 7–13)", _near(wg_mj_m3, 12.01, 0.05), "%.3f" % wg_mj_m3)
	var bg_mj_m3 := CompositionCatalog.lhv_mj_per_kg("biogas") * CompositionCatalog.kg_per_unit("biogas")
	_check("biogas 21.5 MJ/Nm³ (60 % CH4)", _near(bg_mj_m3, 21.49, 0.05), "%.3f" % bg_mj_m3)
	_check("mixed plant matter LHV 13.5 MJ/kg", _near(CompositionCatalog.lhv_mj_per_kg("biomass"), 13.51, 0.01))
	_check("diesel 0.832 kg/L, 42.6 MJ/kg", _near(CompositionCatalog.kg_per_unit("diesel"), 0.832, 1e-6)
		and _near(CompositionCatalog.lhv_mj_per_kg("diesel"), 42.6, 1e-6))
	var bm_c := float(CompositionCatalog.elements_of("biomass").get("C", 0.0)) / 0.8
	_check("dry wood ~50 % C (Phyllis2)", bm_c > 0.47 and bm_c < 0.53, "%.3f" % bm_c)
	var bio_oil_c := float(CompositionCatalog.elements_of("tar").get("C", 0.0)) / 0.75
	_check("bio-oil dry C ~56 % (Bridgwater 2012)", bio_oil_c > 0.53 and bio_oil_c < 0.60, "%.3f" % bio_oil_c)
	var po := CompositionCatalog.elements_of("plastic_oil")
	_check("plastic oil is a hydrocarbon (no O)", float(po.get("O", 0.0)) < 1e-9
		and _near(float(po.get("C", 0.0)), 0.856, 0.002))
	_check("hot water carries 0.188 MJ/kg", _near(CompositionCatalog.sensible_mj_per_kg("hot_water"), 0.188, 1e-9))
	_check("steam carries 2.613 MJ/kg", _near(CompositionCatalog.sensible_mj_per_kg("steam"), 2.613, 1e-9))
	_check("a meal is 0.5 kg of food", _near(CompositionCatalog.kg_per_unit("meal"), 0.5, 1e-9)
		and _near(CompositionCatalog.water_fraction("meal"), CompositionCatalog.water_fraction("food"), 1e-9))
	_check("blackwater holds urine's N plus feces'", float(CompositionCatalog.elements_of("blackwater").get("N", 0.0))
		> float(CompositionCatalog.elements_of("brownwater").get("N", 0.0)))
	_check("nutrients are N + P + K by definition", _near(float(CompositionCatalog.elements_of("nutrients").get("N", 0.0))
		+ float(CompositionCatalog.elements_of("nutrients").get("P", 0.0))
		+ float(CompositionCatalog.elements_of("nutrients").get("K", 0.0)), 1.0, 1e-9))
	var pvc_cl := float(CompositionCatalog.elements_of("plastic_waste").get("Cl", 0.0))
	_check("plastic waste carries PVC's chlorine", pvc_cl > 0.01 and pvc_cl < 0.03, "%.4f" % pvc_cl)
	_check("flake is the waste it was shredded from", _near(float(CompositionCatalog.elements_of("plastic_flake").get("C", 0.0)),
		float(CompositionCatalog.elements_of("plastic_waste").get("C", 0.0)), 1e-9))


func _test_grades() -> void:
	var ladder := ["seawater", "blackwater", "greywater", "irrigation_water", "wash_water", "water", "distilled_water"]
	var ok := true
	for i in range(1, ladder.size()):
		if CompositionCatalog.grade_of(ladder[i]) <= CompositionCatalog.grade_of(ladder[i - 1]):
			ok = false
	_check("water grades climb seawater → distilled", ok)
	_check("rainwater is washing grade, below drinking", CompositionCatalog.grade_of("rainwater") == 4
		and CompositionCatalog.grade_of("water") == 5)
	_check("urine and brownwater are sewage grade", CompositionCatalog.grade_of("urine") == 1
		and CompositionCatalog.grade_of("brownwater") == 1)
	_check("non-water kinds have no grade", CompositionCatalog.grade_of("food") == -1
		and CompositionCatalog.grade_of("electric") == -1)
	var fam_ok := true
	for k in ladder:
		if CompositionCatalog.family_of(str(k)) != "water":
			fam_ok = false
	_check("the ladder is all family water", fam_ok)
	_check("every grade has a label", CompositionData.GRADES.has(0) and CompositionData.GRADES.has(6))
	_check("the new water kinds are ResourceKinds builtins",
		ResourceKinds.BUILTIN.has("rainwater") and ResourceKinds.BUILTIN.has("seawater")
		and ResourceKinds.BUILTIN.has("distilled_water") and ResourceKinds.BUILTIN.has("wash_water")
		and ResourceKinds.BUILTIN.has("brownwater"))
	_check("the residue and plastic-oil kinds are builtins", ResourceKinds.BUILTIN.has("green_waste")
		and ResourceKinds.BUILTIN.has("plastic_oil"))
	_check("new kinds have a show-only domain", GraphDomainFilter.kind_domain("seawater") == GraphDomainFilter.WATER
		and GraphDomainFilter.kind_domain("plastic_oil") == GraphDomainFilter.FUEL
		and GraphDomainFilter.kind_domain("green_waste") == GraphDomainFilter.FOOD)
	_check("m³ reads as a volume again (encoding fix)", ResourceKinds.dimension_for_kind("woodgas") == "volume"
		and ResourceKinds.default_unit("woodgas") == "m³")


func _test_embodied() -> void:
	var e := CompositionCatalog.embodied("urine", 10.0)
	_check("10 L urine = 10.2 kg", _near(float(e["kg"]), 10.2, 1e-6))
	_check("10 L urine holds 9.9 kg water", _near(float(e["water_kg"]), 10.2 * 0.970, 0.06))
	_check("10 L urine holds 74 g N", _near(float((e["elements"] as Dictionary).get("N", 0.0)), 0.0741, 0.001))
	var g := CompositionCatalog.embodied("woodgas", 2.0)
	_check("2 Nm³ woodgas holds ~24 MJ", _near(float(g["energy_mj"]), 24.02, 0.1), "%.3f" % float(g["energy_mj"]))
	var el := CompositionCatalog.embodied("electric", 5.0)
	_check("electricity embodies no mass", bool(el["known"]) and float(el["kg"]) == 0.0)
	var unk := CompositionCatalog.embodied("no_such_kind_xyz", 3.0)
	_check("an unknown kind says so", not bool(unk["known"]))
	_check("aliases resolve (rain → rainwater, potable_water → water)", CompositionCatalog.canonical("rain") == "rainwater"
		and CompositionCatalog.canonical("potable_water") == "water")
	_check("an alias carries the kind's composition", _near(CompositionCatalog.kg_per_unit("potable_water"), 1.0, 1e-9))
	var part := CompositionCatalog.part_embodied("plastic_flake", 2.0)
	_check("a part of its own mass", _near(float(part["kg"]), 2.0, 1e-9))
	var part2 := CompositionCatalog.part_embodied("", 0.0)
	_check("a part with no mass falls back to finished_part", _near(float(part2["kg"]), 0.15, 1e-9))
	var lumber := CompositionCatalog.embodied_kg("lumber", 3.6)
	_check("a 3.6 kg 2×4 holds ~1.6 kg C", _near(float((lumber["elements"] as Dictionary).get("C", 0.0)), 1.60, 0.12),
		"%.3f" % float((lumber["elements"] as Dictionary).get("C", 0.0)))
	_check("… and ~58 MJ", _near(float(lumber["energy_mj"]), 57.96, 0.1), "%.2f" % float(lumber["energy_mj"]))


func _test_mass_balance() -> void:
	var shred := MassBalance.check([{"kind": "plastic_waste", "rate": 5.0}], [{"kind": "plastic_flake", "rate": 5.0}])
	_check("a shredder balances", str(shred["verdict"]) == "estimate" or str(shred["verdict"]) == "ok", str(shred["verdict"]))
	_check("… and is an estimate (the waste mix is)", str(shred["verdict"]) == "estimate")
	# Burning 1 Nm³ biogas: CH4 + 2 O2 → CO2 + 2 H2O, O2 from the air.
	var ch4_kg := 0.6 * CompositionCatalog.molar_mass("CH4") / 22.414
	var o2 := ch4_kg * 2.0 * CompositionCatalog.molar_mass("O2") / CompositionCatalog.molar_mass("CH4")
	var co2 := 0.4 * CompositionCatalog.molar_mass("CO2") / 22.414 + ch4_kg * CompositionCatalog.molar_mass("CO2") / CompositionCatalog.molar_mass("CH4")
	var h2o := ch4_kg * 2.0 * CompositionCatalog.molar_mass("H2O") / CompositionCatalog.molar_mass("CH4")
	var burn := MassBalance.check([{"kind": "biogas", "rate": 1.0}, {"kind": "electric", "rate": 2.0}], [],
		[{"component": "CO2", "rate": co2}, {"component": "H2O", "rate": h2o}], [{"component": "O2", "rate": o2}])
	_check("a burner balances with its air side declared", str(burn["verdict"]) == "ok", "%s %s" % [burn["verdict"], burn["rel"]])
	_check("… mass in = out", _near(float(burn["mass_delta_kg"]), 0.0, 1e-6))
	var bare := MassBalance.check([{"kind": "biogas", "rate": 1.0}], [])
	_check("the same burner undeclared is a sink losing C, H, O", (bare["loses"] as Array).has("C")
		and (bare["loses"] as Array).has("H") and str(bare["verdict"]) == "sink")
	var made := MassBalance.check([{"kind": "biomass", "rate": 10.0}, {"kind": "water", "rate": 5.0}],
		[{"kind": "biochar", "rate": 12.0}])
	_check("12 kg biochar from 10 kg biomass creates carbon", (made["creates"] as Array).has("C"))
	var unk := MassBalance.check([{"kind": "unobtainium_xyz", "rate": 1.0}], [{"kind": "water", "rate": 1.0}])
	_check("an unknown kind gives verdict unknown", str(unk["verdict"]) == "unknown"
		and (unk["unknown"] as Array).has("unobtainium_xyz"))
	var batch := MassBalance.check([{"kind": "plastic_flake", "qty": 7.2}], [{"kind": "plastic_sheet", "qty": 1}])
	_check("per-batch qty works (7.2 kg flake → one 8 mm sheet)", str(batch["verdict"]) != "unbalanced", str(batch["verdict"]))
	var water_d := MassBalance.check([{"kind": "greywater", "rate": 20.0}], [{"kind": "water", "rate": 17.0}])
	_check("a filter that drops 3 L reports the water it lost", _near(float(water_d["water_delta_kg"]), -2.97, 0.03),
		"%.3f" % float(water_d["water_delta_kg"]))
	var specs := {"inputs": [{"kind": "urine", "rate": 1.0}], "outputs": [{"kind": "urine", "rate": 1.0}]}
	_check("of_specs reads a preset's lists", str(MassBalance.of_specs(specs)["verdict"]) == "ok")

	# Phase 3: the air side, retained elements, sources and sinks.
	var air_burn := MassBalance.check([{"kind": "biogas", "rate": 1.0}], [], [], [], 0.05, "burn")
	_check("air mode burn closes a biogas burner", str(air_burn["verdict"]) == "ok" or str(air_burn["verdict"]) == "estimate",
		"%s %s" % [air_burn["verdict"], air_burn["air"]])
	_check("… giving off CO2 and taking in O2", float((air_burn["air"] as Dictionary).get("CO2", 0.0)) > 0.0
		and float((air_burn["air"] as Dictionary).get("O2", 0.0)) < 0.0)
	var salts := ["Na", "Cl", "Mg", "S", "Ca", "K"]
	var still_r := MassBalance.check([{"kind": "seawater", "rate": 1.0}],
		[{"kind": "distilled_water", "rate": CompositionCatalog.water_fraction("seawater")}], [], [], 0.05, "",
		{"retain": salts})
	_check("a still keeps the salt it leaves behind (retain)", str(still_r["verdict"]) != "unbalanced",
		"%s mass %.4f" % [still_r["verdict"], float(still_r["mass_rel"])])
	var still_n := MassBalance.check([{"kind": "seawater", "rate": 1.0}],
		[{"kind": "distilled_water", "rate": CompositionCatalog.water_fraction("seawater")}])
	_check("… without retain the salt shows as a minor loss", (still_n["minor"] as Array).has("Na"))
	_check("material out of nothing is a source", str(MassBalance.check([], [{"kind": "water", "rate": 1.0}])["verdict"]) == "source")
	_check("material into nothing is a sink", str(MassBalance.check([{"kind": "water", "rate": 1.0}], [])["verdict"]) == "sink")
	var pure_ch4 := MassBalance.check([{"kind": "woodgas", "rate": 1.0, "composition": {"CH4": 1.0}}], [], [], [], 0.05, "burn")
	var co2_1 := CompositionCatalog.molar_mass("CO2") / 22.414
	_check("a gas's own mix overrides its kind (1 Nm³ CH4 → 1.96 kg CO2)",
		_near(float((pure_ch4["air"] as Dictionary).get("CO2", 0.0)), co2_1, 0.01),
		"%.4f" % float((pure_ch4["air"] as Dictionary).get("CO2", 0.0)))
	var soil_c := float(CompositionCatalog.elements_of("soil").get("C", 0.0))
	var mix_c := 0.9 * float(CompositionCatalog.elements_of("compost").get("C", 0.0)) + 0.1 * float(CompositionCatalog.elements_of("biochar").get("C", 0.0))
	_check("soil is 90 % compost + 10 % biochar", _near(soil_c, mix_c, 1e-6), "%.4f vs %.4f" % [soil_c, mix_c])
