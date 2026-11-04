extends SceneTree

## Living-vehicle designer self-test (offline, deterministic):
##   Godot --headless --path . --script core/vehiclelab/vehiclelab_selftest.gd
## Run `--import` first after adding a class_name. Carries EXPECTED_CHECKS: a
## Godot runtime error aborts the enclosing test function while the suite
## still prints PASS, so the count is what catches it.

const EXPECTED_CHECKS := 791

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_test_catalog()
	_test_spec_round_trip()
	_test_turning_radius()
	_test_presets_solve()
	_test_beds_and_spaces()
	_test_energy_bands()
	_test_trip()
	_test_riding_profile()
	_test_builder_winding()
	_test_builder_metas()
	_test_space_roles()
	_test_exterior()
	_test_interior()
	_test_access()
	_test_vehicle_graph()
	_test_driving()
	_test_towing()
	_test_cargo()
	_test_drive_in()
	_test_driver_view()
	_test_masses_and_loads()
	_test_limits_and_elements()
	_test_tow_ratings()
	_test_design_rules()
	_test_geometry()
	_test_transport_lifecycle()
	_test_cargo_doors()
	_test_shuttle_body()
	var total := _passed + _failed
	_check("check count", total == EXPECTED_CHECKS, "ran %d, expected %d" % [total, EXPECTED_CHECKS])
	print("vehiclelab_selftest: %d passed, %d failed" % [_passed, _failed])
	print("PASS" if _failed == 0 else "FAILURE(S)")
	quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL %s %s" % [name, detail])


## The catalog held to itself: every chassis and body carries numbers a
## spec sheet would, and every type x listed chassis solves as a vehicle
## that could exist — rear overhang between 0.6 m and two thirds of the
## wheelbase, the box behind the cab. The cheapest guard for the numbers:
## the short skoolie's 4.9 m overhang (a fixed 8.4 m body on a 157" WB)
## and a Class C box at the Sprinter's front bumper both passed every
## other test here.
func _test_catalog() -> void:
	_check("eleven types", VehicleCatalog.TYPE_ORDER.size() == 11)
	for cid in VehicleCatalog.CHASSIS:
		var ch := VehicleCatalog.chassis(str(cid))
		var trailer := str(ch["cab"]) == "none"
		var electric := str(ch["fuel"]) == "electric"
		_check("%s GVWR above the curb" % cid, float(ch["gvwr_kg"]) > float(ch["curb_kg"]) * 1.1,
			"curb %.0f gvwr %.0f" % [float(ch["curb_kg"]), float(ch["gvwr_kg"])])
		_check("%s wheelbase" % cid, trailer or (float(ch["wheelbase_m"]) > 2.5 and float(ch["wheelbase_m"]) < 8.0),
			"%.2f" % float(ch["wheelbase_m"]))
		_check("%s tyres and track" % cid, float(ch["tyre_d_m"]) > 0.5 and float(ch["tyre_d_m"]) < 1.2
			and float(ch["track_m"]) > 1.5 and float(ch["track_m"]) < 2.2)
		_check("%s cab style" % cid, VehicleCatalog.CAB_STYLES.has(str(ch["cab"])))
		_check("%s fuel agrees with the tank and pack" % cid,
			electric == (float(ch["battery_kwh"]) > 0.0)
			and (trailer or electric or float(ch["tank_l"]) > 0.0)
			and (trailer == (str(ch["fuel"]) == "none")))
		# The ratings every sheet publishes: axles that together carry the
		# GVWR, a tow and combination rating, the curb's place on the wheelbase.
		_check("%s carries axle, tow and combination ratings" % cid,
			ch.has("gawr_f_kg") and ch.has("gawr_r_kg") and ch.has("tow_kg") and ch.has("gcwr_kg"))
		_check("%s axle ratings cover the GVWR" % cid,
			float(ch.get("gawr_f_kg", 0.0)) + float(ch.get("gawr_r_kg", 0.0)) >= float(ch["gvwr_kg"]) * 0.95,
			"%.0f + %.0f vs %.0f" % [float(ch.get("gawr_f_kg", 0.0)), float(ch.get("gawr_r_kg", 0.0)), float(ch["gvwr_kg"])])
		_check("%s combination rating holds the vehicle and its tow" % cid,
			trailer or float(ch.get("gcwr_kg", 0.0)) >= float(ch["gvwr_kg"]) - 1.0)
		_check("%s curb sits on the wheelbase" % cid,
			float(ch.get("cg_wb", VehicleDesign.CHASSIS_CG_WB)) > 0.3 and float(ch.get("cg_wb", 0.5)) < 0.65)
	for bid in VehicleCatalog.BODIES:
		var bd := VehicleCatalog.body(str(bid))
		_check("%s width within 102 in" % bid, float(bd["width_m"]) >= 1.8 and float(bd["width_m"]) <= 2.6,
			"%.2f" % float(bd["width_m"]))
		_check("%s room between floor and roof" % bid,
			float(bd["height_m"]) - float(bd["floor_h_m"]) >= 1.6 and float(bd["height_m"]) <= 4.4)
		_check("%s walls 3-15 cm thick, a roof rating" % bid,
			float(bd.get("wall_t_m", 0.0)) >= 0.03 and float(bd.get("wall_t_m", 0.0)) <= 0.15
			and float(bd.get("ceiling_t_m", 0.0)) >= 0.03 and float(bd.get("roof_kg", 0.0)) > 0.0)
	for t in VehicleCatalog.TYPE_ORDER:
		var ti := VehicleCatalog.type_info(t)
		_check("type %s chassis known" % t, VehicleCatalog.CHASSIS.has(str(ti["chassis"])))
		_check("type %s body known" % t, VehicleCatalog.BODIES.has(str(ti["body"])))
		var listed: Array = ti.get("chassis_ok", [ti["chassis"]])
		_check("type %s default chassis is listed" % t, listed.has(ti["chassis"]))
		for cid in listed:
			var combo := "%s on %s" % [t, cid]
			if not VehicleCatalog.CHASSIS.has(str(cid)):
				_check("%s: chassis exists" % combo, false)
				continue
			var s := VehicleSpec.default_spec(t)
			s["chassis_id"] = str(cid)
			var d := VehicleDesign.solve(s)
			var ch := VehicleCatalog.chassis(str(cid))
			var last_axle := -INF
			for a in d["axles"]:
				last_axle = maxf(last_axle, float((a as Dictionary)["zf"]))
			var ovh := float(d["length_m"]) - last_axle
			var wb := float(ch.get("wheelbase_m", 0.0))
			_check("%s: rear overhang 0.6 m to 2/3 of the wheelbase" % combo,
				ovh >= 0.6 and (wb <= 0.0 or ovh <= wb * 2.0 / 3.0), "%.2f m on a %.2f m WB" % [ovh, wb])
			if not bool(d["integral"]):
				var box_z0 := float((d["body"] as Dictionary)["z0"]) + float(d["half_len"])
				_check("%s: the box sits behind the cab" % combo, box_z0 >= float(ch.get("cab_len_m", 0.0)) - 0.1,
					"box at %.2f, cab %.2f" % [box_z0, float(ch.get("cab_len_m", 0.0))])
			_check("%s: no error" % combo, _errors_of(d).is_empty(), str(_errors_of(d)))


func _errors_of(d: Dictionary) -> Array:
	var out: Array = []
	for c in d["checks"]:
		if str((c as Dictionary)["level"]) == "error":
			out.append((c as Dictionary)["text"])
	return out


## Every check text at `level` ("" = any) that contains `needle`.
func _checks_with(d: Dictionary, needle: String, level: String = "") -> Array:
	var out: Array = []
	for c in d["checks"]:
		var cd: Dictionary = c
		if (level.is_empty() or str(cd["level"]) == level) and str(cd["text"]).contains(needle):
			out.append(cd["text"])
	return out


# --- Phase 1: physics and mass realism ---------------------------------------------

## Laden and payload by hand, masses that follow what you typed, the lever
## rule over the axles, the trailer's tongue, the walls' thickness.
func _test_masses_and_loads() -> void:
	# The camper van: Sprinter diesel, 120 L of water, two seats, the gear.
	var van := _solve("van")
	var ch: Dictionary = (van["spec"] as Dictionary)["ch"]
	var fuel_kg := float(ch["tank_l"]) * 0.84
	var want_laden := float(van["curb_kg"]) + fuel_kg + 120.0 + VehicleDesign.GEAR_KG + 2.0 * VehicleDesign.OCCUPANT_KG
	_check("laden = curb + diesel + water + gear + two aboard", absf(float(van["laden_kg"]) - want_laden) < 0.5,
		"%.1f vs %.1f" % [float(van["laden_kg"]), want_laden])
	_check("payload = GVWR - laden", absf(float(van["payload_kg"]) - (float(van["gvwr_kg"]) - float(van["laden_kg"]))) < 1e-6)
	_check("dry payload = GVWR - curb", absf(float(van["payload_dry_kg"]) - (float(van["gvwr_kg"]) - float(van["curb_kg"]))) < 1e-6)
	_check("fuel weighs 0.84 kg/L of diesel", absf(float(van["fuel_kg"]) - fuel_kg) < 1e-6)
	var sh := _solve("shuttle_bus")
	_check("the way home adds the grey and black tanks", absf(float(sh["laden_out_kg"]) - float(sh["laden_kg"])
		- (float(sh["grey_l"]) + float(sh["black_l"]))) < 1e-6, "%.1f" % (float(sh["laden_out_kg"]) - float(sh["laden_kg"])))
	var tr := _solve("trailer")
	_check("a trailer carries nobody", absf(float(tr["occupants_kg"])) < 1e-6)
	# Masses that follow what you typed.
	var s := VehicleSpec.default_spec("box_truck")
	s["interior"] = {"elements": [{"id": "b5", "type": "battery", "x": -0.6, "z": 1.0},
		{"id": "b40", "type": "battery", "x": 0.6, "z": 1.0, "kwh": 40.0},
		{"id": "t120", "type": "water_tank", "x": -0.6, "z": 3.0},
		{"id": "t800", "type": "water_tank", "x": 0.6, "z": 3.0, "litres": 800.0},
		{"id": "wide", "type": "water_tank", "x": 0.0, "z": 4.2, "litres": 800.0, "w": 0.3},
		{"id": "gas", "type": "propane", "x": 0.0, "z": 0.4}]}
	var d := VehicleDesign.solve(s)
	var b5 := VehicleInterior.element(d, "b5")
	var b40 := VehicleInterior.element(d, "b40")
	_check("a 5 kWh battery weighs 60 kg, 40 kWh 480", absf(float(b5["mass_kg"]) - 60.0) < 1e-6
		and absf(float(b40["mass_kg"]) - 480.0) < 1e-6, "%.1f / %.1f" % [float(b5["mass_kg"]), float(b40["mass_kg"])])
	var v5 := float(b5["w"]) * float(b5["l"]) * float(b5["h"])
	var v40 := float(b40["w"]) * float(b40["l"]) * float(b40["h"])
	_check("40 kWh is eight times the box of 5", absf(v40 / v5 - 8.0) < 0.05, "%.2f" % (v40 / v5))
	_check("40 kWh is 0.72 m3 of battery", absf(v40 - 40.0 * VehicleCatalog.BATTERY_M3_PER_KWH) < 0.01, "%.3f" % v40)
	var t800 := VehicleInterior.element(d, "t800")
	var t120 := VehicleInterior.element(d, "t120")
	_check("an 800 L tank's shell weighs 52 kg, bigger than 120 L", absf(float(t800["mass_kg"]) - 52.0) < 1e-6
		and float(t800["w"]) > float(t120["w"]) * 1.5)
	_check("a typed size wins over the scaled default", absf(float(VehicleInterior.element(d, "wide")["w"]) - 0.3) < 1e-6)
	_check("two 20 lb bottles weigh 34 kg", absf(float(VehicleInterior.element(d, "gas")["mass_kg"]) - 40.0 * 0.8536) < 0.01)
	_check("the interior mass is the elements' own", absf(float(d["interior_kg"]) - (60.0 + 480.0 + 52.0 * 2.0 + 7.8 + 40.0 * 0.8536)) < 0.1,
		"%.1f" % float(d["interior_kg"]))
	_check("the water aboard is 1720 L", absf(float(d["water_kg"]) - 1720.0) < 1e-6)
	_check("the propane aboard is 40 lb of gas", absf(float(d["propane_kg"]) - 40.0 * 0.4536) < 1e-3)
	# Axle loads: they sum to the laden mass, the front share is sane, and
	# moving mass back moves it to the rear axle.
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var pd := VehicleDesign.solve((b as Dictionary)["spec"])
		var sum := float(pd["axle_f_kg"]) + float(pd["axle_r_kg"]) + float(pd.get("tongue_kg", 0.0))
		_check("%s axle loads sum to the laden mass" % id, absf(sum - float(pd["laden_kg"])) < 0.5,
			"%.1f vs %.1f" % [sum, float(pd["laden_kg"])])
		if bool(pd["drivable"]):
			var share := float(pd["axle_f_kg"]) / float(pd["laden_kg"])
			_check("%s front share 25-65 %%" % id, share > 0.25 and share < 0.65, "%.2f" % share)
	var rv := VehiclePresets.builtin("rv")
	var rv_d := VehicleDesign.solve(rv)
	for e in rv["interior"]["elements"]:
		if str((e as Dictionary)["id"]) == "battery":
			(e as Dictionary)["kwh"] = 20.0
			(e as Dictionary)["z"] = -0.3
	var rv_back := VehicleDesign.solve(rv)
	_check("a bigger battery at the back loads the rear axle", float(rv_back["axle_r_kg"]) > float(rv_d["axle_r_kg"]) + 150.0
		and float(rv_back["axle_f_kg"]) < float(rv_d["axle_f_kg"]), "%.0f -> %.0f" % [float(rv_d["axle_r_kg"]), float(rv_back["axle_r_kg"])])
	# A Sprinter with 800 L of water over the rear axle: the rear GAWR warn.
	var heavy := VehiclePresets.builtin("van")
	for e in heavy["interior"]["elements"]:
		if str((e as Dictionary)["id"]) == "water":
			(e as Dictionary)["litres"] = 800.0
	var hd := VehicleDesign.solve(heavy)
	_check("800 L at the back of a Sprinter trips the rear axle warn", not _checks_with(hd, "rear axle carries", "warn").is_empty(),
		str(hd["checks"]))
	_check("...and the GVWR error", not _errors_of(hd).is_empty())
	# A trailer: the tongue a tenth or so of its mass; weight moved back lightens it.
	var pct := float(tr["tongue_pct"])
	_check("the trailer's tongue carries 10-15 %%", pct >= VehicleDesign.TONGUE_MIN and pct <= VehicleDesign.TONGUE_MAX, "%.3f" % pct)
	_check("tongue + axles = the trailer's mass", absf(float(tr["tongue_kg"]) + float(tr["axle_r_kg"]) - float(tr["laden_kg"])) < 0.5)
	var ts := VehiclePresets.builtin("trailer")
	for e in ts["interior"]["elements"]:
		if str((e as Dictionary)["id"]) == "water":
			(e as Dictionary)["z"] = -0.6
			(e as Dictionary)["litres"] = 600.0
	var td := VehicleDesign.solve(ts)
	_check("water at the trailer's tail takes weight off the tongue", float(td["tongue_pct"]) < pct)
	_check("...below %d %% it warns of sway" % int(VehicleDesign.TONGUE_MIN * 100.0),
		not _checks_with(td, "sways", "warn").is_empty(), str(td["checks"]))
	# A 20 ft travel trailer is more than a 3,500 lb axle carries.
	var single := VehicleSpec.default_spec("trailer")
	single["chassis_id"] = "trailer_single"
	var sd := VehicleDesign.solve(single)
	_check("a 20 ft trailer overloads a single 3,500 lb axle", float(sd["payload_kg"]) < 0.0 and not _errors_of(sd).is_empty())
	_check("...and wants brakes it has not got", not _checks_with(sd, "brakes", "warn").is_empty())
	_check("the tandem trailer has brakes", bool(tr["brakes"]))
	# Walls have thickness: the van's inside is 2.03 - 2 x 0.12 across and
	# loses 0.15 m of headroom to the ceiling.
	var house: Dictionary = van["house"]
	_check("a converted van loses 12 cm a side to its walls", absf(float(house["w"]) - (2.03 - 0.24)) < 1e-6, "%.3f" % float(house["w"]))
	_check("and 15 cm of headroom", absf(float(house["height"]) - (2.75 - 0.08 - 0.15 - 0.55)) < 1e-6, "%.3f" % float(house["height"]))
	_check("a dry box's plywood liner is 5 cm", absf(float((_solve("box_truck")["house"] as Dictionary)["wall_t"]) - 0.05) < 1e-6)
	# A van shell is as tall as its van: the ProMaster's 2.52 m, unless typed.
	var pm := VehicleSpec.default_spec("van")
	pm["chassis_id"] = "ram_promaster_3500"
	_check("a ProMaster shell is 2.52 m tall", absf(float(VehicleDesign.solve(pm)["height_m"]) - 2.52) < 1e-6)
	pm["body"] = {"height_m": 2.9}
	_check("a typed roof height wins", absf(float(VehicleDesign.solve(pm)["height_m"]) - 2.9) < 1e-6)
	var sp := VehicleSpec.default_spec("van")
	_check("the Sprinter shell keeps 2.75", absf(float(VehicleDesign.solve(sp)["height_m"]) - 2.75) < 1e-6)
	_check("the semi's steer axle is not judged by the lever rule", not bool(_solve("semi_container")["axle_check"]))


## Height and width limits, the roof load, and the new elements: black
## tank, propane, heater, water heater, shore inlet.
func _test_limits_and_elements() -> void:
	var iso := VehiclePresets.builtin("semi_container")
	(iso["exterior"]["elements"] as Array).append({"id": "dish", "type": "starlink", "face": "roof"})
	var d := VehicleDesign.solve(iso)
	_check("a dish on a high cube stands over 13 ft 6", float(d["overall_h_m"]) > VehicleDesign.MAX_HEIGHT_M
		and not _checks_with(d, "13' 6", "warn").is_empty(), "%.2f" % float(d["overall_h_m"]))
	var rv := _solve("rv")
	_check("the RV's AC stays under the limit", float(rv["overall_h_m"]) > float(rv["height_m"])
		and float(rv["overall_h_m"]) < VehicleDesign.MAX_HEIGHT_M and _checks_with(rv, "13' 6").is_empty())
	# The roof load: the skoolie's rack + 6 modules on a 500 kg bus roof is
	# fine; two modules, a rack, an AC and two cargo boxes on a ProMaster's
	# 150 kg roof are not (an array that would hang off the roof is cut to
	# what fits — Phase 2 — so the overload is built from what does).
	var bus := _solve("school_bus")
	_check("the skoolie's roof load is counted", float(bus["roof_load_kg"]) > 150.0 and float(bus["roof_kg_max"]) == 500.0
		and _checks_with(bus, "on the roof").is_empty())
	var van := VehiclePresets.builtin("van")
	van["chassis_id"] = "ram_promaster_3500"
	for x in van["exterior"]["elements"]:
		if str((x as Dictionary)["type"]) == "solar":
			(x as Dictionary)["rows"] = 2
			(x as Dictionary)["cols"] = 1
			(x as Dictionary)["v"] = 0.9
	(van["exterior"]["elements"] as Array).append({"id": "rack", "type": "rack", "face": "roof", "v": 0.9, "l": 5.0})
	(van["exterior"]["elements"] as Array).append({"id": "acu", "type": "ac", "face": "roof", "v": -1.0})
	(van["exterior"]["elements"] as Array).append({"id": "box", "type": "cargo_box", "face": "roof", "u": 0.6, "v": 1.5})
	(van["exterior"]["elements"] as Array).append({"id": "box2", "type": "cargo_box", "face": "roof", "u": -0.6, "v": 1.5})
	var vd := VehicleDesign.solve(van)
	_check("two modules, a rack, an AC and two boxes overload a ProMaster roof", float(vd["roof_load_kg"]) > 150.0
		and float(vd["roof_kg_max"]) == 150.0
		and not _checks_with(vd, "on the roof", "warn").is_empty(), "%.0f" % float(vd["roof_load_kg"]))
	_check("...and the roof load raises the centre of mass", float(vd["cg_rise_m"]) > 0.02
		and float(vd["cg_y"]) > float(_solve("van")["cg_y"]), "%.3f" % float(vd["cg_rise_m"]))
	# Width: an awning is an appurtenance, not body width.
	var sh := _solve("shuttle_bus")
	_check("an awning does not make the shuttle over-wide", float(sh["overall_w_m"]) > float(sh["width_m"])
		and _checks_with(sh, "wide").is_empty())
	# New elements.
	var s := VehicleSpec.default_spec("box_truck")
	s["interior"] = {"elements": [
		{"id": "bath", "type": "shoilet", "x": -0.6, "z": 1.0},
		{"id": "heat", "type": "heater", "x": 0.9, "z": 2.0},
		{"id": "hw", "type": "water_heater", "x": 0.6, "z": 3.0},
		{"id": "shore", "type": "shore_inlet", "x": 1.0, "z": 3.5},
		{"id": "gas", "type": "propane", "x": -0.6, "z": 3.5}]}
	var nd := VehicleDesign.solve(s)
	_check("a wet bath with no black tank says so", not _checks_with(nd, "black / cassette", "info").is_empty())
	var sys: Dictionary = nd["systems"]
	_check("the shore inlet is reported at 1800 W", absf(float(sys["shore_w"]) - 1800.0) < 1e-6)
	_check("the heater's fan is a load", (sys["loads"] as Array).any(func(l): return str((l as Dictionary)["id"]) == "heat"))
	var shore := VehicleInterior.element(nd, "shore")
	_check("the shore inlet hangs on the wall", float(shore["base_y"]) > float((nd["house"] as Dictionary)["floor_y"]) + 0.4
		and absf(absf(float(shore["x"])) - (float((nd["house"] as Dictionary)["w"]) * 0.5 - float(shore["fx"]) * 0.5)) < 1e-4)
	(s["interior"]["elements"] as Array).append({"id": "black", "type": "black_tank", "x": 0.0, "z": 1.0})
	var bd := VehicleDesign.solve(s)
	_check("with a black tank the note goes", _checks_with(bd, "black / cassette", "info").is_empty())
	_check("the black tank is 60 L aboard", absf(float(bd["black_l"]) - 60.0) < 1e-6)
	_check("the palette lists the new elements", VehicleInterior.tools().any(func(t): return str((t as Dictionary)["id"]) == "propane")
		and VehicleInterior.tools().any(func(t): return str((t as Dictionary)["id"]) == "shore_inlet"))
	_check("a wet bath flushes into a black tank in every preset that has one",
		VehiclePresets.builtins().all(func(b):
			var pd := VehicleDesign.solve((b as Dictionary)["spec"])
			return _checks_with(pd, "black / cassette").is_empty()))


## Towing: the trailer's load on the tow vehicle's engine, and what the
## ratings say about a pair.
func _test_tow_ratings() -> void:
	var van := _solve("van")
	var tr := _solve("trailer")
	var alone := VehicleEnergy.at_speed(van, VehicleEnergy.MPS_55MPH)
	var towing := VehicleEnergy.at_speed(van, VehicleEnergy.MPS_55MPH, tr)
	_check("towing burns more", float(towing["l_per_km"]) > float(alone["l_per_km"]) * 1.3,
		"%.3f vs %.3f" % [float(towing["l_per_km"]), float(alone["l_per_km"])])
	_check("the dashboard range shrinks with a trailer", VehicleDesign.range_mi(van, 50.0, 0.0, tr) < VehicleDesign.range_mi(van, 50.0))
	_check("the trip costs more with a trailer", float(VehicleEnergy.trip(van, 300.0, true, tr)["litres"])
		> float(VehicleEnergy.trip(van, 300.0)["litres"]))
	# The 20 ft travel trailer loaded (2.42 t, grey tank full on the way
	# home) is past a Sprinter 2500's 5,000 lb rating by ~150 kg — a real
	# finding; an E-450 pulls it.
	var notes := VehicleTow.tow_check(van, tr)
	_check("the loaded trailer is just past the Sprinter's tow rating",
		notes.any(func(n): return str((n as Dictionary)["text"]).contains("rated to tow"))
		and float(tr["laden_out_kg"]) < float(van["tow_kg"]) + 200.0, str(notes))
	var full := tr.duplicate()
	full["laden_out_kg"] = float(tr["gvwr_kg"])
	full["tongue_kg"] = float(tr["gvwr_kg"]) * 0.12
	var over := VehicleTow.tow_check(van, full)
	_check("a trailer at 7,000 lb is over the Sprinter's tow rating",
		over.any(func(n): return str((n as Dictionary)["text"]).contains("rated to tow")), str(over))
	_check("...and over its hitch class's tongue weight",
		over.any(func(n): return str((n as Dictionary)["text"]).contains("on the tongue")), str(over))
	_check("hitch classes by tow rating", str(VehicleTow.hitch_class_for(5000.0 * 0.4536)["name"]) == "Class III"
		and str(VehicleTow.hitch_class_for(10000.0 * 0.4536)["name"]) == "Class IV"
		and str(VehicleTow.hitch_class_for(1500.0)["name"]) == "Class II")
	var e450 := _solve("shuttle_bus")
	_check("the E-450 tows it with no note on the rating",
		VehicleTow.tow_check(e450, full).all(func(n): return not str((n as Dictionary)["text"]).contains("rated to tow")))
	var ev := VehicleSpec.default_spec("van")
	ev["chassis_id"] = "ford_etransit"
	_check("the E-Transit is not rated to tow", VehicleTow.tow_check(VehicleDesign.solve(ev), tr).any(
		func(n): return str((n as Dictionary)["text"]).contains("not rated")))
	_check("hitch heights follow the frames", absf((van["hitch"] as Vector3).y - 0.5) < 1e-6
		and absf((tr["coupler"] as Vector3).y - 0.55) < 1e-6)
	var box := _solve("box_truck")
	_check("a high frame's ball wants a drop hitch", VehicleTow.tow_check(box, tr).any(
		func(n): return str((n as Dictionary)["text"]).contains("drop")), str(VehicleTow.tow_check(box, tr)))
	_check("no notes for nothing", VehicleTow.tow_check({}, tr).is_empty() and VehicleTow.tow_check(van, {}).is_empty())
	# The site's running cost takes the trailer along.
	var vrec := {"id": "v1", "model_id": "vehiclelab_vehicle", "vehicle_spec": VehiclePresets.builtin("van")}
	(vrec["vehicle_spec"] as Dictionary)["trip"] = {"one_way_mi": 200.0, "fuel_price_per_gal": 4.0, "kwh_price": 0.3}
	var trec := {"id": "t1", "model_id": "vehiclelab_vehicle", "vehicle_spec": VehiclePresets.builtin("trailer")}
	var solo := SiteCost.running_for_record(vrec)
	vrec["towing"] = "t1"
	var pair := SiteCost.running_for_record(vrec, {"v1": vrec, "t1": trec})
	_check("the trip's cost rises with a trailer behind", float(pair["usd"]) > float(solo["usd"]) * 1.3,
		"%.0f vs %.0f" % [float(pair["usd"]), float(solo["usd"])])
	_check("the total takes the pair as one trip", absf(float(SiteCost.running_total([vrec, trec])["usd"]) - float(pair["usd"])) < 0.01)


func _test_spec_round_trip() -> void:
	var s := VehiclePresets.builtin("shuttle_bus")
	var json := JSON.stringify(VehicleSpec.to_json_safe(s))
	var back: Dictionary = JSON.parse_string(json)
	_check("round trip keeps the key", VehicleSpec.key_of(back) == VehicleSpec.key_of(s))
	var r := VehicleSpec.resolve(back)
	_check("resolve adds ch + bd", r.has("ch") and r.has("bd"))
	_check("to_json_safe strips ch + bd", not VehicleSpec.to_json_safe(r).has("ch"))
	var other := s.duplicate(true)
	other["chassis_id"] = "chevy_express_3500"
	_check("a chassis change moves the key", VehicleSpec.key_of(other) != VehicleSpec.key_of(s))


func _test_turning_radius() -> void:
	# E-450 176" WB, 38 deg: rear-axle radius 4.470 / tan 38 = 5.721; outer
	# front wheel = sqrt((5.721 + 0.875)^2 + 4.470^2) = 7.968 m (Ford quotes a
	# ~54-55 ft curb-to-curb circle on this wheelbase).
	var s := VehicleSpec.default_spec("shuttle_bus")
	var d := VehicleDesign.solve(s)
	_check("E-450 turning radius by hand", absf(float(d["turn_radius_m"]) - 7.968) < 0.02,
		"%.3f" % float(d["turn_radius_m"]))
	var t := VehicleDesign.solve(VehicleSpec.default_spec("trailer"))
	_check("a trailer does not steer", float(t["turn_radius_m"]) == 0.0)


func _test_presets_solve() -> void:
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var errs: Array = []
		var warns: Array = []
		for c in d["checks"]:
			if str((c as Dictionary)["level"]) == "error":
				errs.append((c as Dictionary)["text"])
			elif str((c as Dictionary)["level"]) == "warn":
				warns.append((c as Dictionary)["text"])
		_check("%s solves with no error" % id, errs.is_empty(), str(errs))
		_check("%s has no overlaps or warnings" % id, warns.is_empty(), str(warns))
		_check("%s length sane" % id, float(d["length_m"]) > 4.0 and float(d["length_m"]) < 17.0,
			"%.2f" % float(d["length_m"]))
		var house: Dictionary = d["house"]
		_check("%s living box has room" % id, float(house["len"]) > 2.5 and float(house["height"]) > 1.5,
			"len %.2f h %.2f" % [float(house["len"]), float(house["height"])])
		_check("%s rear axle inside the length" % id, _axles_inside(d))
		_check("%s payload positive" % id, float(d["payload_kg"]) > 0.0, "%.0f" % float(d["payload_kg"]))


func _axles_inside(d: Dictionary) -> bool:
	for w in d["wheels"]:
		var z: float = float(((w as Dictionary)["pos"] as Vector3).z)
		if absf(z) > float(d["half_len"]):
			return false
	return true


func _test_beds_and_spaces() -> void:
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var house: Dictionary = d["house"]
		_check("%s sleeps someone" % id, int(d["sleeps"]) >= 1)
		var ok := true
		for bed in d["beds"]:
			var p: Vector3 = (bed as Dictionary)["pos"]
			if p.y < float(house["floor_y"]) + 0.2:
				ok = false
			if absf(p.x) > float(house["w"]) * 0.5 + 0.01:
				ok = false
			if p.z < float(house["z0"]) - 2.5 or p.z > float(house["z1"]) + 0.01:
				ok = false
			var yaw := float((bed as Dictionary)["yaw"])
			if not (is_equal_approx(yaw, 0.0) or is_equal_approx(yaw, PI * 0.5)):
				ok = false
		_check("%s beds inside, raised, along an axis" % id, ok)
	var sh := VehicleDesign.solve(VehiclePresets.builtin("shuttle_bus"))
	var types := {}
	for sp in VehicleDesign.spaces(sh):
		types[str((sp as Dictionary)["space_type"])] = sp
	_check("shuttle offers sleep", types.has("sleep") and int((types["sleep"] as Dictionary)["capacity"]) == 2)
	_check("shuttle offers a kitchen", types.has("kitchen"))
	_check("shuttle offers a shower", types.has("shower"))
	_check("shuttle offers a restroom", types.has("restroom"))
	var kitchen: Vector3 = (types["kitchen"] as Dictionary)["anchor"]
	_check("kitchen spot on the floor", absf(kitchen.y - float((sh["house"] as Dictionary)["floor_y"])) < 0.01)
	# The skoolie's bunks stack two sleepers on one footprint.
	var bus := VehicleDesign.solve(VehiclePresets.builtin("school_bus"))
	var bunk_ys: Array = []
	for bed in bus["beds"]:
		if str((bed as Dictionary)["bed"]) == "bunks":
			bunk_ys.append(((bed as Dictionary)["pos"] as Vector3).y)
	_check("bunks stack", bunk_ys.size() == 2 and absf(float(bunk_ys[0]) - float(bunk_ys[1])) > 0.7)
	# A transverse bed lies across.
	var box := VehicleDesign.solve(VehiclePresets.builtin("box_truck"))
	_check("transverse bed lies across", is_equal_approx(float((box["beds"][0] as Dictionary)["yaw"]), PI * 0.5))
	# The RV's cab-over sits over the cab.
	var rv := VehicleDesign.solve(VehiclePresets.builtin("rv"))
	var cab_top := float((rv["cab_geo"] as Dictionary)["h"])
	var over := false
	for bed in rv["beds"]:
		if ((bed as Dictionary)["pos"] as Vector3).y > cab_top:
			over = true
	_check("RV cab-over bed is up over the cab", over)


func _test_energy_bands() -> void:
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var band: Array = ((d["spec"] as Dictionary)["ch"] as Dictionary).get("mpg", [])
		var e: Dictionary = d["energy_55"]
		if band.size() == 2:
			var mpg := float(e["mpg"])
			_check("%s mpg %.1f within %s" % [id, mpg, str(band)],
				mpg >= float(band[0]) and mpg <= float(band[1]))
		else:
			_check("%s has no fuel band (trailer / EV)" % id, str(d["fuel"]) in ["none", "electric"])
	# The EV van: ~0.5-0.8 kWh per mile at 55 mph (Ford's E-Transit figures).
	var ev := VehiclePresets.builtin("van")
	ev["chassis_id"] = "ford_etransit"
	var de := VehicleDesign.solve(ev)
	var kwh_mi := float((de["energy_55"] as Dictionary)["kwh_per_km"]) * VehicleEnergy.MI_M / 1000.0
	_check("E-Transit kWh/mi in range", kwh_mi > 0.45 and kwh_mi < 0.85, "%.3f" % kwh_mi)
	# More drag costs more fuel; heavier costs more fuel.
	var lo := VehicleEnergy.source_j_per_m(4000.0, 0.4, 6.0, 25.0, "gasoline")
	var hi := VehicleEnergy.source_j_per_m(4000.0, 0.7, 6.0, 25.0, "gasoline")
	_check("drag costs fuel", hi > lo)
	_check("weight costs fuel", VehicleEnergy.source_j_per_m(8000.0, 0.4, 6.0, 25.0, "gasoline") > lo)
	_check("diesel beats gasoline per joule", VehicleEnergy.source_j_per_m(4000.0, 0.4, 6.0, 25.0, "diesel") < lo)


func _test_trip() -> void:
	var s := VehiclePresets.builtin("shuttle_bus")
	s["trip"] = {"one_way_mi": 300.0, "fuel_price_per_gal": 4.0, "kwh_price": 0.3}
	var d := VehicleDesign.solve(s)
	var t: Dictionary = d["trip_estimate"]
	var mpg := float((d["energy_55"] as Dictionary)["mpg"])
	_check("trip gallons = 600 mi / mpg", absf(float(t["gallons"]) - 600.0 / mpg) < 0.5,
		"%.2f vs %.2f" % [float(t["gallons"]), 600.0 / mpg])
	_check("trip cost = gallons x price", absf(float(t["cost"]) - float(t["gallons"]) * 4.0) < 0.01)
	_check("range from the tank", float(t["range_km"]) > 300.0)


func _test_riding_profile() -> void:
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var p := VehicleDesign.riding_profile(d)
		if id == "trailer":
			_check("trailer has no riding profile", p.is_empty())
			continue
		_check("%s drivable" % id, not p.is_empty())
		for k in PlacedVehicle.PROFILES["van"]:
			if not p.has(k):
				_check("%s profile key %s" % [id, k], false)
		var cam: Vector3 = p["camera_offset"]
		_check("%s driver in front half, on the left" % id, cam.z < 0.0 and cam.x < 0.0, str(cam))
		_check("%s eye above the ground" % id, cam.y + 1.65 > 1.5, str(cam))


func _test_builder_winding() -> void:
	for id in ["van", "shuttle_bus", "school_bus", "rv", "motorhome", "trailer", "semi_container"]:
		var root := VehicleBuilder.build_node(VehiclePresets.builtin(id))
		var bad := 0
		var tris := 0
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var mesh := (mi as MeshInstance3D).mesh as ArrayMesh
			for si in mesh.get_surface_count():
				var arr := mesh.surface_get_arrays(si)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				var count := idx.size() if idx.size() > 0 else v.size()
				for t in range(0, count, 3):
					var i0 := idx[t] if idx.size() > 0 else t
					var i1 := idx[t + 1] if idx.size() > 0 else t + 1
					var i2 := idx[t + 2] if idx.size() > 0 else t + 2
					var fn := (v[i1] - v[i0]).cross(v[i2] - v[i0])
					if fn.length_squared() < 1e-14:
						continue
					tris += 1
					var avg := n[i0] + n[i1] + n[i2]
					if fn.dot(avg) >= 0.0:
						bad += 1
		_check("%s winding (clockwise from outside)" % id, bad == 0, "%d of %d" % [bad, tris])
		_check("%s has geometry" % id, tris > 300, str(tris))
		root.free()


func _test_builder_metas() -> void:
	var root := VehicleBuilder.build_node(VehiclePresets.builtin("shuttle_bus"))
	_check("living_vehicle meta", root.has_meta("living_vehicle"))
	var spots: Array = root.get_meta("seat_spots", [])
	var lie := 0
	for sp in spots:
		if str((sp as Dictionary)["kind"]) == "lie":
			lie += 1
	_check("seat_spots carry the beds", lie == 2)
	var roles: Dictionary = root.get_meta("role_spots", {})
	_check("role spots for the kitchen", not (roles.get("kitchen", []) as Array).is_empty())
	_check("a Shell node", root.get_node_or_null("Shell") != null)
	root.free()
	var cut := VehicleBuilder.build_node(VehiclePresets.builtin("shuttle_bus"), VehicleBuilder.MODEL_ID,
		{"cutaway": true})
	_check("cutaway has no shell", cut.get_node_or_null("Shell") == null)
	cut.free()
	_check("handles preset ids", VehicleBuilder.handles("vehiclelab_rv"))
	_check("preset for an id", str(VehicleBuilder.preset_for_model("vehiclelab_rv")["type"]) == "rv")


## One prop, several spaces: a role tells them apart; a role-less target is
## still the old single space; an anchor lands on the prop, turned with it.
func _test_space_roles() -> void:
	var reg := SpaceRegistry.create_empty()
	var sleep_id := reg.set_space_type({"kind": "prop", "prop_id": "p1"}, "sleep", 2, "Van")
	var kit_id := reg.set_space_type({"kind": "prop", "prop_id": "p1", "role": "kitchen",
		"anchor": [-0.5, 1.0]}, "kitchen", 1, "Van kitchen")
	_check("two spaces on one prop", not sleep_id.is_empty() and not kit_id.is_empty() and sleep_id != kit_id)
	_check("role-less target finds the sleep space",
		str(reg.space_for_target({"kind": "prop", "prop_id": "p1"}).get("id", "")) == sleep_id)
	var again := reg.set_space_type({"kind": "prop", "prop_id": "p1", "role": "kitchen"}, "kitchen", 1, "")
	_check("re-tagging a role upserts", again == kit_id and reg.spaces.size() == 2)
	var rec := {"x": 10.0, "z": 20.0, "yaw": 90.0, "scale": 1.0}
	var p := SpaceRegistry.prop_point(rec, [1.0, 0.0])
	# +X turned 90 deg about +Y lands on -Z.
	_check("anchor turns with the prop", p.distance_to(Vector2(10.0, 19.0)) < 1e-4, str(p))
	_check("no anchor = the prop's origin", SpaceRegistry.prop_point(rec, null) == Vector2(10.0, 20.0))


## Roof / side / rear items: resolve onto a face, a ray finds the face and
## the item, an item only goes where it may, the totals add up, and the
## builder draws them.
func _test_exterior() -> void:
	var s := VehiclePresets.builtin("school_bus")
	var d := VehicleDesign.solve(s)
	var ext: Array = d["exterior"]
	_check("skoolie has its roof kit", ext.size() == 5)
	var tot: Dictionary = d["exterior_totals"]
	_check("six 400 W modules = 2.4 kW", absf(float(tot["solar_w"]) - 2400.0) < 0.1 and int(tot["modules"]) == 6)
	_check("roof kit weighs something", float(tot["kg"]) > 100.0)
	# A ray straight down onto the roof's middle hits the roof at its top.
	var hit := VehicleExterior.face_hit(d, Vector3(0.0, 10.0, 0.5), Vector3.DOWN)
	_check("ray down hits the roof", str(hit.get("face", "")) == "roof"
		and absf(float(hit["point"].y) - VehicleExterior.roof_y(d, 0.0)) < 0.01, str(hit))
	var side := VehicleExterior.face_hit(d, Vector3(8.0, 1.8, 0.0), Vector3.LEFT)
	_check("ray from the right hits the right side", str(side.get("face", "")) == "right")
	var rear := VehicleExterior.face_hit(d, Vector3(0.0, 1.8, 20.0), Vector3.FORWARD)
	_check("ray from behind hits the rear", str(rear.get("face", "")) == "rear")
	var fan := VehicleExterior.candidate(d, {"type": "fan"}, hit)
	_check("a fan goes on the roof", not fan.is_empty() and str(fan["face"]) == "roof")
	_check("a fan does not go on a side", VehicleExterior.candidate(d, {"type": "fan"}, side).is_empty())
	var aw := VehicleExterior.candidate(d, {"type": "awning"}, side)
	_check("an awning goes on a side, high up", not aw.is_empty() and float(aw["v"]) > float(d["body"]["floor_y"]) + 1.0)
	# The rack is picked by a ray down onto it.
	var rack_id := VehicleExterior.pick(d, Vector3(0.8, 10.0, 0.6), Vector3.DOWN)
	_check("a ray picks a roof item", rack_id == "rack" or rack_id == "solar", rack_id)
	_check("a ray at nothing picks nothing", VehicleExterior.pick(d, Vector3(0.0, 10.0, 30.0), Vector3.DOWN).is_empty())
	# Clamped onto its face: a fan asked for far off the roof stays on it.
	var off := VehicleExterior.resolve_element(d, {"type": "fan", "face": "roof", "u": 9.0, "v": 99.0})
	var roof: Dictionary = VehicleExterior.faces(d)["roof"]
	_check("clamped onto the roof", float(off["u"]) <= float(roof["u1"]) and float(off["v"]) <= float(roof["v1"]))
	# Mass reaches the curb.
	var bare := s.duplicate(true)
	bare["exterior"] = {"elements": []}
	var db := VehicleDesign.solve(bare)
	_check("roof kit adds to the curb mass", absf(float(d["curb_kg"]) - float(db["curb_kg"]) - float(tot["kg"])) < 0.1)
	var root := VehicleBuilder.build_from_design(d)
	_check("an Exterior node", root.get_node_or_null("Exterior") != null)
	root.free()


func _solve(id: String) -> Dictionary:
	return VehicleDesign.solve(VehiclePresets.builtin(id))


func _test_interior() -> void:
	var d := _solve("van")
	var house: Dictionary = d["house"]
	var fy := float(house["floor_y"])
	var mid := (float(house["z0"]) + float(house["z1"])) * 0.5
	# A ray straight down onto the floor.
	var fh := VehicleInterior.floor_hit(d, Vector3(0.2, fy + 3.0, mid), Vector3.DOWN)
	_check("floor hit lands under the ray", not fh.is_empty() and absf(float(fh["x"]) - 0.2) < 1e-4
		and absf(float(fh["z"]) - mid) < 1e-4 and bool(fh["inside"]), str(fh))
	_check("floor hit measures from the box's front", absf(float(fh["zc"]) - (mid - float(house["z0"]))) < 1e-4)
	var out := VehicleInterior.floor_hit(d, Vector3(5.0, fy + 3.0, mid), Vector3.DOWN)
	_check("a hit outside the box is not inside", not bool(out.get("inside", true)))
	_check("a ray going up never meets the floor", VehicleInterior.floor_hit(d, Vector3(0, fy + 1.0, mid), Vector3.UP).is_empty())
	var cand := VehicleInterior.candidate(d, {"type": "fridge"}, fh)
	_check("the fridge ghost stands on the floor", not cand.is_empty() and absf(float(cand["base_y"]) - fy) < 1e-4,
		str(cand))
	_check("a ghost outside the box is nothing", VehicleInterior.candidate(d, {"type": "fridge"}, out).is_empty())
	# Pick the galley from straight above.
	var gal := VehicleInterior.element(d, "galley")
	var pid := VehicleInterior.pick(d, Vector3(float(gal["x"]), fy + 3.0, float(gal["z"])), Vector3.DOWN)
	_check("a ray down onto the galley picks it", pid == "galley", pid)
	var bat := VehicleInterior.element(d, "battery")
	var bed := VehicleInterior.element(d, "bed")
	_check("a ray down through the bed onto its battery picks the battery",
		VehicleInterior.pick(d, Vector3(float(bat["x"]), fy + 3.0, float(bat["z"])), Vector3.DOWN) == "battery")
	# (toward the front, right of the middle: nothing is stored under the
	# bed there and no wall-hung cubby or inverter is over it)
	var off_bat := Vector3(float(bed["x"]) + float(bed["fx"]) * 0.25, fy + 3.0, float(bed["z"]) - float(bed["fz"]) * 0.4)
	_check("a ray down onto the bed away from it picks the bed", VehicleInterior.pick(d, off_bat, Vector3.DOWN) == "bed",
		VehicleInterior.pick(d, off_bat, Vector3.DOWN))
	# A ray across a cabinet toward a smaller battery behind it picks the cabinet.
	var spn := VehicleSpec.default_spec("box_truck")
	spn["interior"] = {"elements": [
		{"id": "cab", "type": "cabinet", "x": 0.6, "z": 2.0, "w": 0.5, "l": 0.5, "h": 1.9},
		{"id": "bat", "type": "battery", "x": -0.6, "z": 2.0}]}
	var dp := VehicleDesign.solve(spn)
	var cabe := VehicleInterior.element(dp, "cab")
	var o2 := Vector3(2.0, float((dp["house"] as Dictionary)["floor_y"]) + 0.15, float(cabe["z"]))
	_check("the nearest box wins over a smaller one behind it", VehicleInterior.pick(dp, o2, Vector3.LEFT) == "cab",
		VehicleInterior.pick(dp, o2, Vector3.LEFT))
	var lt := VehicleInterior.element(d, "light")
	_check("a ray down through the ceiling light onto the floor picks the light",
		VehicleInterior.pick(d, Vector3(float(lt["x"]), fy + 3.0, float(lt["z"])), Vector3.DOWN) == "light")
	var sl := VehiclePresets.builtin("van")
	(sl["interior"]["elements"] as Array).append({"id": "under", "type": "fridge", "x": float(lt["x"]),
		"z": float(lt["zc"])})
	var dl := VehicleDesign.solve(sl)
	var un := VehicleInterior.element(dl, "under")
	_check("a ceiling light gives way to the fridge under it", VehicleInterior.pick(dl,
		Vector3(float(un["x"]), fy + 3.0, float(un["z"])), Vector3.DOWN) == "under")
	_check("a ray past the side picks nothing", VehicleInterior.pick(d, Vector3(3.0, fy + 3.0, mid), Vector3.DOWN) == "")
	# A quarter turn swaps the footprint.
	var s := VehiclePresets.builtin("van")
	(s["interior"]["elements"] as Array).append({"id": "t1", "type": "table", "x": 0.0, "z": 2.0, "w": 0.6, "l": 1.0, "yaw": 90.0})
	var t1 := VehicleInterior.element(VehicleDesign.solve(s), "t1")
	_check("a turned table lies across", absf(float(t1["fx"]) - 1.0) < 1e-4 and absf(float(t1["fz"]) - 0.6) < 1e-4, str(t1))
	# Tall things need shoulder room, low ones hip room.
	_check("low things need hip room", absf(VehicleInterior._clear_r(d, VehicleInterior.element(d, "bed")) - VehicleInterior.HIP_M * 0.5) < 1e-6)
	_check("tall things need shoulder room", absf(VehicleInterior._clear_r(d, VehicleInterior.element(d, "fridge")) - VehicleInterior.AISLE_M * 0.5) < 1e-6)
	# Doors: the trailer's door sits where its body override says.
	var tr := _solve("trailer")
	var side := {}
	for sp in VehicleDesign.door_spans(tr):
		if str((sp as Dictionary)["where"]) == "side":
			side = sp
	_check("the trailer's door is 4 m back", not side.is_empty()
		and absf(float(side["z0"]) - (float((tr["house"] as Dictionary)["z0"]) + 4.0)) < 1e-4, str(side))
	_check("a bus door and a lift's doors on the shuttle", VehicleDesign.door_spans(_solve("shuttle_bus")).map(
		func(sp): return str((sp as Dictionary).get("kind", ""))) == ["bus", "lift"])
	_check("the box truck's only way in is the rear", VehicleInterior.entries(_solve("box_truck")).size() == 1
		and str((VehicleInterior.entries(_solve("box_truck"))[0] as Dictionary)["where"]) == "rear")
	_check("a walk-through cab is an entry", VehicleInterior.entries(_solve("school_bus")).any(
		func(e): return str((e as Dictionary)["where"]) == "cab"))
	_check("palette has every group", VehicleInterior.tools().size() >= 20)


func _test_access() -> void:
	# Every built-in has a way in to every bed and fixture.
	for b in VehiclePresets.builtins():
		var bd: Dictionary = b
		var ac := VehicleInterior.access(VehicleDesign.solve(bd["spec"]))
		var reach: Dictionary = ac["reachable"]
		var bad: Array = []
		for k in reach:
			if not bool(reach[k]):
				bad.append(k)
		_check("%s: a way in to everything" % str(bd["id"]), bad.is_empty() and not reach.is_empty(), str(bad))
	# Wall the box truck's rear door off: nothing can be reached and it says so.
	var s := VehiclePresets.builtin("box_truck")
	var dd := VehicleDesign.solve(s)
	var hw := float((dd["house"] as Dictionary)["w"])
	(s["interior"]["elements"] as Array).append({"id": "blocker", "type": "wall", "x": 0.0, "z": -0.2,
		"w": 0.1, "l": hw, "h": 1.9, "yaw": 90.0})
	var d2 := VehicleDesign.solve(s)
	var reach2: Dictionary = VehicleInterior.access(d2)["reachable"]
	_check("a wall across the door shuts everything off", not reach2.values().has(true), str(reach2))
	var texts: Array = (d2["checks"] as Array).map(func(c): return str((c as Dictionary)["text"]))
	_check("the checks say there is no way in", texts.any(func(t): return str(t).begins_with("No way in")), str(texts))
	var named := (d2["checks"] as Array).filter(func(c): return str((c as Dictionary)["text"]).begins_with("No way in"))
	_check("each no-way-in check names its element", named.all(func(c): return ((c as Dictionary).get("ids", []) as Array).size() == 1))
	# A 0.3 m gap is too tight even beside low furniture; 0.6 m is fine.
	var s3 := VehicleSpec.default_spec("box_truck")
	s3["interior"] = {"elements": [
		{"id": "bed", "type": "bed", "x": 0.0, "z": 1.0, "w": 1.52, "l": 2.03, "yaw": 90.0},
		{"id": "left", "type": "cabinet", "x": -0.55, "z": 2.6, "w": 0.6, "l": 0.6, "h": 1.9},
		{"id": "right", "type": "cabinet", "x": 0.6, "z": 2.6, "w": 0.8, "l": 0.6, "h": 1.9}]}
	var d3 := VehicleDesign.solve(s3)
	var gap := (float(VehicleInterior.element(d3, "right")["x"]) - float(VehicleInterior.element(d3, "right")["fx"]) * 0.5) \
		- (float(VehicleInterior.element(d3, "left")["x"]) + float(VehicleInterior.element(d3, "left")["fx"]) * 0.5)
	_check("the test gap is narrower than an aisle", gap < VehicleInterior.AISLE_M, "%.2f" % gap)
	_check("a bed behind a narrow gap is unreachable", not bool((VehicleInterior.access(d3)["reachable"] as Dictionary).get("bed", true)))
	(s3["interior"]["elements"] as Array)[2]["w"] = 0.4
	var d4 := VehicleDesign.solve(s3)
	_check("widen the gap and the bed can be reached", bool((VehicleInterior.access(d4)["reachable"] as Dictionary).get("bed", false)))


func _test_vehicle_graph() -> void:
	var d := _solve("shuttle_bus")
	var sys: Dictionary = d["systems"]
	_check("the shuttle has a battery", float(sys["battery_kwh"]) > 0.0, str(sys))
	_check("the shuttle has 1.6 kW of roof solar", absf(float(sys["solar_w"]) - 1600.0) < 0.5, str(sys["solar_w"]))
	var kwh := float(sys["battery_kwh"])
	var want_v := 12.8 if kwh <= 3.0 else (25.6 if kwh <= 8.0 else 51.2)
	_check("the bank voltage follows its size", absf(float(sys["voltage"]) - want_v) < 1e-4)
	_check("the shuttle has fresh and grey water", float(sys["water_l"]) > 0.0 and float(sys["grey_l"]) > 0.0)
	var def := VehicleGraph.definition(d, "vehicle_p1")
	_check("a definition for the shuttle", not def.is_empty() and str(def["id"]) == "vehicle_p1")
	var items: Array = (def["subgraph"] as Dictionary)["items"]
	var conns: Array = (def["subgraph"] as Dictionary)["connections"]
	var by := {}
	for it in items:
		var t := str((it as Dictionary)["type"])
		by[t] = int(by.get(t, 0)) + 1
	_check("four panels for four modules", int(by.get("panel", 0)) == 4, str(by))
	_check("a charge controller and an inverter", int(by.get("controller", 0)) == 2, str(by))
	_check("one house battery", int(by.get("battery", 0)) == 1)
	_check("a load per powered thing", int(by.get("appliance", 0)) == (sys["loads"] as Array).size(), str(by))
	_check("two tanks", int(by.get("resource", 0)) == 2)
	var bat := {}
	for it in items:
		if str((it as Dictionary)["local_id"]) == "bat":
			bat = (it as Dictionary)["specs"]
	_check("the battery holds the design's kWh", absf(float(bat.get("kwh", 0.0)) - kwh) < 1e-4)
	# Four 400 W modules (Voc 37.5) = two series strings of two under the
	# 150 V cap: one series link inside each string, each string's ends on
	# the controller — six panel-sourced links, four of them to the controller.
	var pv_links := conns.filter(func(c): return str((c as Dictionary)["source"]).begins_with("pv_"))
	var to_cc := pv_links.filter(func(c): return str((c as Dictionary)["target"]) == "cc")
	var series := pv_links.filter(func(c): return str((c as Dictionary)["target"]).begins_with("pv_"))
	_check("two strings of two: 4 links to the controller, 2 in series", to_cc.size() == 4 and series.size() == 2,
		"%d to cc, %d series" % [to_cc.size(), series.size()])
	_check("a series link runs + of one panel to - of the next", series.all(func(c):
		return str((c as Dictionary)["source_handle"]) == "positive" and str((c as Dictionary)["target_handle"]) == "negative"))
	_check("string length: 3 × 37.5 V fits 150 V cold, 4 × does not", VehicleGraph.string_len(3, 37.5) == 3
		and VehicleGraph.string_len(4, 37.5) == 2 and VehicleGraph.string_len(5, 37.5) == 1
		and VehicleGraph.string_len(6, 37.5) == 3 and VehicleGraph.string_len(2, 60.0) == 2
		and VehicleGraph.string_len(4, 70.0) == 1)
	var ac_links := conns.filter(func(c): return str((c as Dictionary).get("polarity", "")) == "ac")
	_check("every load on the inverter's AC", ac_links.size() == int(by.get("appliance", 0))
		and ac_links.all(func(c): return str((c as Dictionary)["source"]) == "inv"))
	var eps: Array = (def["subgraph"] as Dictionary)["exposed_ports"]
	_check("fill and dump ports on the node", eps.size() == 2)
	_check("the signature is stable", VehicleGraph.signature(sys) == VehicleGraph.signature(_solve("shuttle_bus")["systems"]))
	var s2 := VehiclePresets.builtin("shuttle_bus")
	for e in s2["interior"]["elements"]:
		if str((e as Dictionary)["type"]) == "battery":
			(e as Dictionary)["kwh"] = kwh + 2.0
	_check("a bigger battery changes the signature",
		VehicleGraph.signature(VehicleDesign.solve(s2)["systems"]) != VehicleGraph.signature(sys))
	# Many modules: one panel node per STRING (20 flexible modules = 10
	# strings of two), each carrying the string's voltages and watts. On
	# the container's roof, the one wide and long enough for 4 x 5 flexible
	# modules (an array that hangs off a roof is cut to what fits).
	var s3 := VehiclePresets.builtin("semi_container")
	(s3["exterior"]["elements"] as Array).append({"id": "solar", "type": "solar", "face": "roof",
		"module": "flex_100", "rows": 5, "cols": 4})
	var d3 := VehicleDesign.solve(s3)
	var def3 := VehicleGraph.definition(d3, "vehicle_p3")
	var panels3 := ((def3["subgraph"] as Dictionary)["items"] as Array).filter(func(i): return str((i as Dictionary)["type"]) == "panel")
	_check("past %d modules each string is one panel node" % VehicleGraph.MAX_PANEL_NODES,
		panels3.size() == 20 / VehicleGraph.string_len(20, 21.6) and panels3.size() < 20, str(panels3.size()))
	var wmp := 0.0
	for pn in panels3:
		var sp: Dictionary = (pn as Dictionary)["specs"]
		wmp += float(sp["wmp"])
	_check("merged panels keep the array's watts", absf(wmp - float(d3["systems"]["solar_w"])) < 0.5)
	_check("a merged string node carries the string's Voc", absf(float(((panels3[0] as Dictionary)["specs"] as Dictionary)["voc"])
		- 21.6 * float(VehicleGraph.string_len(20, 21.6))) < 1e-4)
	# Nothing to put on the graph: no node.
	var s4 := VehicleSpec.default_spec("cargo_van")
	s4["interior"] = {"elements": []}
	s4["exterior"] = {"elements": []}
	var d4 := VehicleDesign.solve(s4)
	_check("a bare cargo van has no system", not VehicleGraph.has_system(d4["systems"])
		and VehicleGraph.definition(d4, "vehicle_p4").is_empty())
	# Realized into a model: a unique compound with the children inside.
	var model := GraphModel.new()
	model.put_definition(def)
	var cid := GraphComponentDefs.realize(model, "vehicle_p1", "root", Vector2.ZERO, {"vehicle_prop_id": "p1"})
	_check("the node realizes", not cid.is_empty())
	GraphComponentDefs.make_unique(model, cid)
	var kids := model.get_items_in_scope(str(model.get_item(cid).get("child_scope_id", "")))
	_check("its parts are inside it", kids.size() == items.size(), "%d vs %d" % [kids.size(), items.size()])
	_check("made unique, the definition is gone", not model.definitions.has("vehicle_p1"))


func _test_driving() -> void:
	# The turning law by hand: 5 m/s on a 10 m circle swings 0.5 rad/s.
	_check("yaw rate = v / R", absf(VehicleDesign.yaw_rate_limit_deg(5.0, 10.0) - rad_to_deg(0.5)) < 1e-6)
	_check("standing still turns nothing", VehicleDesign.yaw_rate_limit_deg(0.0, 8.0) == 0.0)
	# Driven at full lock, a bus traces its own turning circle.
	var d := _solve("school_bus")
	var R := float(d["turn_radius_m"])
	var prof := VehicleDesign.riding_profile(d)
	_check("the profile turns by its radius", bool(prof.get("turn_by_radius", false))
		and absf(float(prof["min_turn_radius"]) - maxf(R, 3.0)) < 1e-6)
	var v := 4.0
	var yaw := 0.0
	var p := Vector2.ZERO
	var dt := 0.01
	var pts: Array = []
	for i in int(TAU * R / v / dt):
		yaw += deg_to_rad(VehicleDesign.yaw_rate_limit_deg(v, R)) * dt
		p += Vector2(-sin(yaw), -cos(yaw)) * v * dt
		pts.append(p)
	var c := Vector2.ZERO
	for q in pts:
		c += q
	c /= float(pts.size())
	var rr := 0.0
	for q in pts:
		rr += (q as Vector2).distance_to(c)
	rr /= float(pts.size())
	_check("full lock drives the %.1f m turning circle" % R, absf(rr - R) < 0.05 * R, "%.2f" % rr)
	# Range: a full tank at 55 mph.
	var van := _solve("van")
	var e := VehicleEnergy.at_speed(van, VehicleEnergy.MPS_55MPH)
	var want := float(van["tank_l"]) / float(e["l_per_km"]) * 1000.0 / VehicleEnergy.MI_M
	_check("range from a full tank", absf(VehicleDesign.range_mi(van, float(van["tank_l"])) - want) < 1e-3)
	_check("an empty tank goes nowhere", VehicleDesign.range_mi(van, 0.0) == 0.0)
	# Road fuels on the graph.
	_check("gasoline and diesel are resources", ResourceKinds.has_kind("gasoline") and ResourceKinds.has_kind("diesel")
		and ResourceKinds.default_unit("diesel") == "L")
	var found := 0
	for pr in ComponentPresets.RESOURCES:
		if str(((pr as Dictionary).get("specs", {}) as Dictionary).get("resource_kind", "")) in ["gasoline", "diesel"]:
			found += 1
	_check("fuel stores in the library", found >= 2, str(found))


func _test_towing() -> void:
	var tr := _solve("trailer")
	var van := _solve("van")
	_check("a trailer has a coupler at its tongue", tr.has("coupler")
		and absf((tr["coupler"] as Vector3).z + float(tr["half_len"])) < 1e-6)
	_check("its axle is behind the coupler", float(tr["axle_z"]) > (tr["coupler"] as Vector3).z)
	_check("a van has a hitch behind its bumper", van.has("hitch")
		and (van["hitch"] as Vector3).z > float(van["half_len"]))
	_check("the semi has no ball hitch", not _solve("semi_container").has("hitch"))
	var L := VehicleTow.tongue_m(tr)
	_check("the tongue is a few metres", L > 2.0 and L < 6.0, "%.2f" % L)
	# Pose: the coupler lands on the hitch, the front faces the hitch.
	var hitch := Vector2(3.0, -2.0)
	var axle := hitch + Vector2(0.0, L)
	var pose := VehicleTow.trailer_pose(tr, hitch, axle)
	var cw := VehicleTow.world_xz(tr["coupler"], pose["origin"], float(pose["yaw"]))
	_check("the coupler sits on the hitch", cw.distance_to(hitch) < 1e-4, str(cw))
	var aw := VehicleTow.axle_at(tr, pose["origin"], float(pose["yaw"]))
	_check("the axle sits a tongue behind", aw.distance_to(axle) < 1e-4, str(aw))
	# Straight ahead: the trailer lines up behind.
	var a := Vector2(1.5, L)
	var h := Vector2.ZERO
	# The offset dies away as exp(−s / L): ten tongue lengths of road.
	for i in int(L * 10.0 / 0.01):
		h += Vector2(0.0, -0.01)
		a = VehicleTow.step_axle(h, a, L)
	_check("pulled straight, it lines up behind", absf(a.x - h.x) < 0.01 and absf(h.distance_to(a) - L) < 1e-4)
	# Round a circle: the axle settles on sqrt(R² − L²) (off-tracking).
	var Rh := 9.0
	var ah := Vector2(Rh, L)
	for i in 30000:
		var th := float(i + 1) * 0.0005
		var hp := Vector2(Rh * cos(th), Rh * sin(th))
		ah = VehicleTow.step_axle(hp, ah, L)
	_check("round a %.0f m circle the axle tracks inside, on sqrt(R²−L²)" % Rh,
		absf(ah.length() - VehicleTow.steady_axle_radius(Rh, L)) < 0.05, "%.3f vs %.3f" % [ah.length(), VehicleTow.steady_axle_radius(Rh, L)])
	# Never folded past the limit.
	var a2 := VehicleTow.step_axle_limited(Vector2.ZERO, Vector2(L, 0.1), L, Vector2(0, -1))
	var ang := rad_to_deg(Vector2(0, -1).angle_to((Vector2.ZERO - a2).normalized()))
	_check("no jackknife past %.0f°" % VehicleTow.MAX_ARTICULATION_DEG, absf(ang) <= VehicleTow.MAX_ARTICULATION_DEG + 0.01, "%.1f" % ang)


func _test_cargo() -> void:
	# The histogram rectangle by hand: a 4 × 3 grid with one blocked corner.
	var g := PackedByteArray([1, 1, 1, 0,  1, 1, 1, 1,  1, 1, 1, 1])
	var r := VehicleCargo.largest_rect(g, 4, 3)
	_check("largest clear rectangle by hand", (int(r["ix1"]) - int(r["ix0"])) * (int(r["iz1"]) - int(r["iz0"])) == 9, str(r))
	var bt := _solve("box_truck")
	var b := VehicleCargo.bay(bt)
	_check("the box truck has a bay through its roll-up", not b.is_empty() and str(b.get("door_where", "")) == "rear", str(b))
	var it: Dictionary = b.get("interior", {})
	_check("its bay is the clear floor between the fittings (≥ 1 × 2 m)", float(it.get("l_m", 0.0)) >= 2.0
		and float(it.get("w_m", 0.0)) >= 1.0, str(it))
	# Nothing stands on the bay.
	var rect: Dictionary = b.get("rect", {})
	var clear := true
	for e in bt["interior"]:
		var el: Dictionary = e
		if not VehicleInterior.blocks_floor(bt, el):
			continue
		var ex0 := float(el["x"]) - float(el["fx"]) * 0.5
		var ex1 := float(el["x"]) + float(el["fx"]) * 0.5
		var ez0 := float(el["z"]) - float(el["fz"]) * 0.5
		var ez1 := float(el["z"]) + float(el["fz"]) * 0.5
		if ex0 < float(rect["x1"]) - 1e-3 and ex1 > float(rect["x0"]) + 1e-3 				and ez0 < float(rect["z1"]) - 1e-3 and ez1 > float(rect["z0"]) + 1e-3:
			clear = false
	_check("nothing stands on the bay", clear)
	# Through a side door only, the load runs across.
	var tr := _solve("trailer")
	var tb := VehicleCargo.bay(tr)
	_check("a side-door bay runs across to the door", tb.is_empty()
		or ((tb["frame"] as Dictionary)["z_axis"] as Vector3).is_equal_approx(Vector3(1, 0, 0)))
	# The scenario packs into it like a container.
	var plan := UnpackScenario.stow_plan("starter_camp", b)
	_check("a kit packs into the bay", (plan.get("placements", []) as Array).size() > 0, str(plan.get("overflow", [])))
	var inside := true
	for pl in plan.get("placements", []):
		var p3: Vector3 = (pl as Dictionary)["pos"]
		var s3: Vector3 = (pl as Dictionary)["size"]
		if p3.x < -1e-3 or p3.z < -1e-3 or p3.x + s3.x > float(it["w_m"]) + 1e-3 or p3.z + s3.z > float(it["l_m"]) + 1e-3 				or p3.y + s3.y > float(it["h_m"]) + 1e-3:
			inside = false
	_check("every crate inside the bay", inside)
	# Stowed in a placed vehicle, they ride along.
	var layer := PlacedPropLayer.new()
	var vid := layer.add_free_prop(VehicleBuilder.MODEL_ID, 10.0, 0.0, 20.0, 0.0)
	layer.update_prop(vid, {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin("box_truck"))})
	var res := VehicleCargo.spawn_in_vehicle(layer, "starter_camp", vid)
	_check("a kit delivered into the box truck", not res.is_empty() and (res["crate_ids"] as Array).size() > 0)
	var stowed := 0
	for c in res.get("crate_ids", []):
		var crec := layer.find_by_id(str(c))
		if str(crec.get("stowed_in", "")) == vid and crec.get("stow_local") is Array and bool(crec.get("packed", false)):
			stowed += 1
	_check("its crates are stowed in it", stowed > 0, "%d" % stowed)
	var c0 := layer.find_by_id(str((res["crate_ids"] as Array)[0]))
	var sl: Array = c0["stow_local"]
	var moved := {"id": vid, "x": 50.0, "z": -5.0, "yaw": 90.0}
	var pt: Dictionary = VehicleCargo.reseat_patches(layer.props, moved)
	var want := VehicleTow.world_xz(Vector3(float(sl[0]), float(sl[1]), float(sl[2])), Vector2(50.0, -5.0), deg_to_rad(90.0))
	var got: Dictionary = pt.get(str(c0["id"]), {})
	_check("driven and turned, a crate rides at its place in the bay",
		not got.is_empty() and Vector2(float(got["x"]), float(got["z"])).distance_to(want) < 1e-4)
	_check("the vehicle carries the delivery", (layer.find_by_id(vid).get("delivery", {}) as Dictionary).has("crate_ids"))
	var door := VehicleCargo.door_near(layer.props, Vector2(10.0, 20.0), 50.0)
	_check("its door is a loadout point", not door.is_empty()
		and Vector2(float(door["x"]), float(door["z"])).distance_to(Vector2(10.0, 20.0)) > float(bt["half_len"]))


## Phase 7: a vehicle driving in through the gate, a pure function of time.
func _test_drive_in() -> void:
	var road := {"points": PackedVector2Array([Vector2(0, 200), Vector2(0, 60), Vector2(40, 20), Vector2(140, 20)])}
	var gate := Vector2(0, 195)
	var park := Vector2(120, 40)
	var park_yaw := 90.0   # facing -X (forward = (-sin, -cos))
	var pts := VehicleDrive.route_points(gate, park, park_yaw, [road])
	var has_bend := false
	for p in pts:
		if (p as Vector2).distance_to(Vector2(40, 20)) < 0.5:
			has_bend = true
	_check("the way in follows the festival road (passes its bend)", has_bend, str(pts))
	var appr := VehicleDrive.approach_point(park, park_yaw)
	_check("the last straight runs into the spot along its heading",
		absf(appr.distance_to(park) - VehicleDrive.APPROACH_M) < 1e-3
		and (park - appr).normalized().dot(VehicleDrive.forward(deg_to_rad(park_yaw))) > 0.999, str(appr))
	var entry := SiteGateBuilder.approach_xz(gate, 180.0)
	var arr := VehicleDrive.make(gate, park, park_yaw, 100.0, [road], entry)
	_check("the drive starts outside the gate", Vector2(float(arr["route"][0][0]), float(arr["route"][0][1])).distance_to(entry) < 0.02,
		str(arr["route"][0]))
	var away := VehicleDrive.pose_at(arr, 99.9)
	_check("before it sets off it is not on site", str(away["state"]) == VehicleDrive.STATE_AWAY)
	var dur := VehicleDrive.duration_h(arr)
	var pl := VehicleDrive.plan(arr)
	var length := float(pl["length"])
	_check("the drive takes a plausible time (≥ length at cruise, ≤ a crawl)",
		dur * 3600.0 >= length / VehicleDrive.CRUISE_MS and dur * 3600.0 <= length / 0.3,
		"%.0f m in %.0f s" % [length, dur * 3600.0])
	var parked := VehicleDrive.pose_at(arr, 100.0 + dur + 1e-4)
	_check("then it stands in its spot", str(parked["state"]) == VehicleDrive.STATE_PARKED
		and (parked["pos"] as Vector2).distance_to(park) < 1e-3)
	var prev: Dictionary = VehicleDrive.pose_at(arr, 100.0)
	var max_step := 0.0
	var max_v := 0.0
	var mono := true
	var last_drive := prev
	var n := int(dur * 3600.0)
	for k in range(1, n + 1):
		var p := VehicleDrive.pose_at(arr, 100.0 + float(k) / 3600.0)
		if str(p["state"]) != VehicleDrive.STATE_DRIVING:
			continue
		max_step = maxf(max_step, (p["pos"] as Vector2).distance_to(prev["pos"]))
		max_v = maxf(max_v, float(p["speed"]))
		if float(p["u"]) < float(prev["u"]) - 1e-9:
			mono = false
		prev = p
		last_drive = p
	_check("never faster than the cruise", max_v <= VehicleDrive.CRUISE_MS + 1e-3, "%.2f m/s" % max_v)
	_check("it moves smoothly (no jump over a second)", max_step <= VehicleDrive.CRUISE_MS * 1.05 + 0.1, "%.2f m" % max_step)
	_check("it only goes forward along the route", mono)
	_check("it arrives facing its parked heading",
		absf(rad_to_deg(angle_difference(float(last_drive["yaw"]), deg_to_rad(park_yaw)))) < 4.0
		and (last_drive["pos"] as Vector2).distance_to(park) < 1.5,
		"%.1f° off, %.2f m away" % [rad_to_deg(angle_difference(float(last_drive["yaw"]), deg_to_rad(park_yaw))),
			(last_drive["pos"] as Vector2).distance_to(park)])
	var a1 := VehicleDrive.pose_at(arr, 100.0 + dur * 0.6)
	VehicleDrive.pose_at(arr, 100.0 + dur * 0.9)
	var a2 := VehicleDrive.pose_at(arr, 100.0 + dur * 0.6)
	_check("scrubbing back gives the same pose (a pure function of time)",
		(a1["pos"] as Vector2).is_equal_approx(a2["pos"]) and is_equal_approx(float(a1["yaw"]), float(a2["yaw"])))
	var mid := VehicleDrive.pose_at(arr, 100.0 + dur * 0.5)
	var behind := VehicleDrive.point_behind(arr, mid["pos"], float(mid["s"]), 5.0)
	_check("a towed trailer's axle sits its tongue behind on the road",
		absf(behind.distance_to(mid["pos"]) - 5.0) < 0.02, "%.3f m" % behind.distance_to(mid["pos"]))
	_check("the default gate is the road end farthest from the site",
		VehicleDrive.default_gate(Vector2(120, 30), [road]).distance_to(Vector2(0, 200)) < 1e-3)
	_check("with no road the default gate is south of the site",
		VehicleDrive.default_gate(Vector2(5, 5), []).is_equal_approx(Vector2(5, 185)))
	# Phase 8: the wheels turn as it rolls, the front ones steer.
	var wroot := VehicleBuilder.build_node(VehiclePresets.builtin("shuttle_bus"))
	var wl: Array = wroot.get_meta("wheel_nodes", [])
	_check("every wheel is its own node", wl.size() == (_solve("shuttle_bus")["wheels"] as Array).size()
		and wroot.get_node_or_null("Wheels/W0") != null, "%d listed" % wl.size())
	var r0 := float((wl[0] as Dictionary)["r"]) if not wl.is_empty() else 0.4
	VehicleBuilder.spin_wheels(wroot, PI * r0, 0.3)
	var steer_ok := true
	var spin_ok := true
	for e in wl:
		var wn := wroot.get_node("Wheels/" + str((e as Dictionary)["name"])) as Node3D
		var fwd := wn.basis * Vector3(0, 0, -1)
		var axle := wn.basis * Vector3.RIGHT
		if bool((e as Dictionary)["steer"]):
			steer_ok = steer_ok and absf(axle.angle_to(Vector3.RIGHT) - 0.3) < 0.01
		else:
			steer_ok = steer_ok and axle.is_equal_approx(Vector3.RIGHT)
		# Half a turn: the hub's forward now points backward-ish (roll / r = PI
		# on the first axle's radius).
		if is_equal_approx(float((e as Dictionary)["r"]), r0) and not bool((e as Dictionary)["steer"]):
			spin_ok = spin_ok and fwd.dot(Vector3(0, 0, -1)) < -0.99
	_check("rolling turns the wheels, steering turns only the front ones", steer_ok and spin_ok)
	wroot.free()


## Phase 8: from the driver's eye the road ahead is clear once the panels
## draw one-sided (VehicleBuilder.set_inside_view): no front face within a
## metre on a ray 10° down, for every vehicle that can be driven. The eye is
## not pressed against the windshield either (the panel it sits behind is
## ≥ 0.2 m away).
func _test_driver_view() -> void:
	var blocked := []
	var pressed := []
	for id in ["van", "cargo_van", "shuttle_bus", "school_bus", "step_van", "ambulance", "rv", "motorhome", "box_truck", "semi_container"]:
		var spec := VehiclePresets.builtin(id)
		var d := VehicleDesign.solve(spec)
		var root := VehicleBuilder.build_node(spec)
		var eye: Vector3 = d["driver_seat"]
		var dir := Vector3(0, sin(deg_to_rad(-10.0)), -cos(deg_to_rad(-10.0)))
		var near_front := INF
		var near_any := INF
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			var xf := Transform3D.IDENTITY
			var cur: Node = m
			while cur != null and cur != root:
				xf = (cur as Node3D).transform * xf
				cur = cur.get_parent()
			for si in m.mesh.get_surface_count():
				var arr := m.mesh.surface_get_arrays(si)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var ii: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				var cnt := ii.size() if ii.size() > 0 else v.size()
				for t in range(0, cnt, 3):
					var a := xf * v[ii[t] if ii.size() > 0 else t]
					var b := xf * v[ii[t + 1] if ii.size() > 0 else t + 1]
					var c := xf * v[ii[t + 2] if ii.size() > 0 else t + 2]
					var hit = Geometry3D.ray_intersects_triangle(eye, dir, a, b, c)
					if hit == null:
						continue
					var dist := (hit as Vector3).distance_to(eye)
					near_any = minf(near_any, dist)
					# Clockwise front face: outward normal = -(b-a)x(c-a).
					if (-(b - a).cross(c - a)).dot(dir) < 0.0:
						near_front = minf(near_front, dist)
		if near_front < 1.0:
			blocked.append("%s %.2f m" % [id, near_front])
		if near_any < 0.2:
			pressed.append("%s %.2f m" % [id, near_any])
		root.free()
	_check("from every driver's seat the road ahead is clear (one-sided panels)", blocked.is_empty(), str(blocked))
	_check("no driver's eye is pressed against the windshield", pressed.is_empty(), str(pressed))


# --- Phase 2: design rules and geometry ---------------------------------------------

## The rules a real conversion is held to: rear overhang, an array that
## hangs off its roof, items over each other / the door / a window, seats
## for the sleepers, water for a shower, a battery for the loads, an
## inverter for the AC, a bed long enough, water for the days, headroom;
## the cab walk-through as an entry; the walkway flood cached; windows
## where people sit and lie; the cargo bay's doors from the one door rule.
func _test_design_rules() -> void:
	# Every built-in solves clean (presets_solve pins that); every warning
	# here carries its reason.
	for b in VehiclePresets.builtins():
		var pd := VehicleDesign.solve((b as Dictionary)["spec"])
		_check("%s: rear overhang inside two thirds of the wheelbase" % str((b as Dictionary)["id"]),
			float(pd.get("wheelbase_m", 0.0)) <= 0.0 or not bool(pd.get("axle_check", true))
			or float(pd["rear_overhang_m"]) <= float(pd["wheelbase_m"]) * VehicleDesign.OVERHANG_MAX_WB + 0.01,
			"%.2f on %.2f" % [float(pd["rear_overhang_m"]), float(pd.get("wheelbase_m", 0.0))])
	# Rear overhang: a 16 ft box stretched to 8 m on the NPR's 150" wheelbase.
	var long := VehiclePresets.builtin("box_truck")
	long["body"] = {"length_m": 8.0}
	var ld := VehicleDesign.solve(long)
	_check("a stretched box hangs past two thirds of the wheelbase",
		float(ld["rear_overhang_m"]) > float(ld["wheelbase_m"]) * VehicleDesign.OVERHANG_MAX_WB
		and not _checks_with(ld, "behind the rear axle", "warn").is_empty(), "%.2f" % float(ld["rear_overhang_m"]))
	# A roof array wider than the roof loses whole columns, keeps whole modules.
	var wide := VehiclePresets.builtin("van")
	for x in wide["exterior"]["elements"]:
		if str((x as Dictionary)["type"]) == "solar":
			(x as Dictionary)["cols"] = 3
	var wd := VehicleDesign.solve(wide)
	var arr := {}
	for e in wd["exterior"]:
		if str((e as Dictionary)["type"]) == "solar":
			arr = e
	_check("three 1.13 m modules across a van roof come down to one", int(arr.get("cols", 0)) == 1
		and int(arr.get("cut_cols", 0)) == 3, str(arr))
	_check("the array's watts follow the modules kept", absf(float((wd["systems"] as Dictionary)["solar_w"]) - 400.0) < 0.5)
	_check("and it says 2 of 3 modules were dropped", not _checks_with(wd, "2 of 3 modules", "warn").is_empty())
	_check("the module kept is still whole", absf(float(arr["w"]) - VehicleExterior.MODULES["rigid_400"]["short"]) < 1e-6)
	# Two roof items on one patch of skin; a rack is mounted on.
	var two := VehiclePresets.builtin("van")
	(two["exterior"]["elements"] as Array).append({"id": "fan2", "type": "fan", "face": "roof", "u": 0.0, "v": -0.3})
	var td := VehicleDesign.solve(two)
	var ov := (td["checks"] as Array).filter(func(c): return str((c as Dictionary)["text"]).contains("overlap on the roof"))
	_check("two fans on one spot overlap", ov.size() == 1 and ((ov[0] as Dictionary)["ids"] as Array).has("fan2"), str(ov))
	_check("a rack under the skoolie's modules is not an overlap", _checks_with(_solve("school_bus"), "overlap on the roof").is_empty())
	# A side item across the side door, or over a window.
	var van := _solve("van")
	var door := {}
	for sp in VehicleDesign.door_spans(van):
		if str((sp as Dictionary)["where"]) == "side":
			door = sp
	var over_door := VehiclePresets.builtin("van")
	(over_door["exterior"]["elements"] as Array).append({"id": "win", "type": "window", "face": "right",
		"u": (float(door["z0"]) + float(door["z1"])) * 0.5, "v": float(van["house"]["floor_y"]) + 1.2})
	_check("a window cut across the slider says so",
		not _checks_with(VehicleDesign.solve(over_door), "across the side door", "warn").is_empty())
	var panes := VehicleDesign.window_spans(van)
	var left_pane := {}
	for w in panes:
		if float((w as Dictionary)["sx"]) < 0.0:
			left_pane = w
	var over_win := VehiclePresets.builtin("van")
	(over_win["exterior"]["elements"] as Array).append({"id": "lad", "type": "ladder", "face": "left",
		"u": (float(left_pane["z0"]) + float(left_pane["z1"])) * 0.5, "v": (float(left_pane["y0"]) + float(left_pane["y1"])) * 0.5})
	_check("a ladder over the bed's window says so",
		not _checks_with(VehicleDesign.solve(over_win), "covers a window", "warn").is_empty())
	_check("the RV's awning over its door is fine", _checks_with(_solve("rv"), "across the side door").is_empty())
	# Seats for the sleepers; a trailer's people ride up front.
	var few := VehiclePresets.builtin("van")
	few["seats"] = 1
	_check("two sleepers on one seat: no seat belt", not _checks_with(VehicleDesign.solve(few), "no seat belt", "warn").is_empty())
	_check("a trailer sleeps more than it seats and says nothing", _checks_with(_solve("trailer"), "no seat belt").is_empty())
	# A shower needs fresh and grey water.
	var dry := VehiclePresets.builtin("cargo_van")
	(dry["interior"]["elements"] as Array).append({"id": "sh", "type": "shower", "x": 0.6, "z": 2.4})
	var dd := VehicleDesign.solve(dry)
	_check("a shower with no grey tank needs one", not _checks_with(dd, "needs a grey tank", "warn").is_empty(), str(dd["checks"]))
	# Loads with no house battery; an EV's pack counts.
	var nobat := VehiclePresets.builtin("cargo_van")
	nobat["interior"]["elements"] = (nobat["interior"]["elements"] as Array).filter(
		func(e): return str((e as Dictionary)["type"]) != "battery")
	_check("a light with no house battery says so", not _checks_with(VehicleDesign.solve(nobat), "no house battery", "warn").is_empty())
	nobat["chassis_id"] = "ford_etransit"
	_check("on an E-Transit the pack runs them", _checks_with(VehicleDesign.solve(nobat), "no house battery").is_empty())
	# A rooftop AC needs an inverter rated for it, or shore power.
	var rv := VehiclePresets.builtin("rv")
	rv["interior"]["elements"] = (rv["interior"]["elements"] as Array).filter(
		func(e): return str((e as Dictionary)["type"]) != "inverter")
	_check("an AC with no inverter says so", not _checks_with(VehicleDesign.solve(rv), "no inverter", "warn").is_empty())
	(rv["interior"]["elements"] as Array).append({"id": "inv", "type": "inverter", "x": -0.9, "z": 0.5, "supply_w": 1000.0})
	var small := VehicleDesign.solve(rv)
	_check("a 1 kW inverter under a 1.4 kW AC says so", not _checks_with(small, "rated 1 kW", "warn").is_empty()
		and absf(float(small["inverter_w"]) - 1000.0) < 1e-6, str(small["checks"]))
	(rv["interior"]["elements"] as Array).pop_back()
	(rv["interior"]["elements"] as Array).append({"id": "shore", "type": "shore_inlet", "x": 1.0, "z": 0.5})
	_check("shore power carries the AC instead", _checks_with(VehicleDesign.solve(rv), "inverter").is_empty())
	_check("the RV preset's 2 kW inverter carries its AC", absf(float(_solve("rv")["inverter_w"]) - 2000.0) < 1e-6)
	# A short bed.
	var short := VehiclePresets.builtin("van")
	for e in short["interior"]["elements"]:
		if str((e as Dictionary)["id"]) == "bed":
			(e as Dictionary)["l"] = 1.6
	_check("a 1.6 m bed is too short to stretch out", not _checks_with(VehicleDesign.solve(short), "stretch out", "warn").is_empty())
	# Water for the days: the van's 120 L is 1.2 days for two (a note); 60 L
	# is under a day (a warning).
	_check("the van's water is noted at 1.2 days", not _checks_with(van, "1.2 days", "info").is_empty())
	var thirsty := VehiclePresets.builtin("van")
	for e in thirsty["interior"]["elements"]:
		if str((e as Dictionary)["type"]) == "water_tank":
			(e as Dictionary)["litres"] = 60.0
	_check("60 L for two is under a day", not _checks_with(VehicleDesign.solve(thirsty), "0.6 days", "warn").is_empty())
	# Headroom: a stoop is a warning, a crawl-in a note; a trailer too.
	var low := VehiclePresets.builtin("box_truck")
	low["body"] = {"height_m": 2.72}
	var lo := VehicleDesign.solve(low)
	_check("1.8 m inside is a stoop", float(lo["house"]["height"]) < VehicleInterior.STAND_M
		and not _checks_with(lo, "stoop", "warn").is_empty(), "%.2f" % float(lo["house"]["height"]))
	low["body"] = {"height_m": 2.3}
	var crawl := VehicleDesign.solve(low)
	_check("1.4 m inside is a crawl-in", float(crawl["house"]["height"]) < VehicleInterior.CROUCH_M
		and not _checks_with(crawl, "crawl-in", "info").is_empty() and _checks_with(crawl, "stoop").is_empty())
	var low_tr := VehiclePresets.builtin("trailer")
	low_tr["body"] = {"door_at_m": 4.0, "height_m": 2.75}
	_check("a low trailer stoops too", not _checks_with(VehicleDesign.solve(low_tr), "stoop", "warn").is_empty())
	_check("the skoolie's 1.88 m stands (a stock bus's 6' 2\")", _checks_with(_solve("school_bus"), "stoop").is_empty())
	# Every warning and error says why (the banner's tooltip).
	var all_why := true
	var missing: Array = []
	for dx in [ld, wd, td, dd, small, lo, crawl, VehicleDesign.solve(nobat), VehicleDesign.solve(short)]:
		for c in dx["checks"]:
			var cd: Dictionary = c
			if str(cd["level"]) != "info" and str(cd.get("why", "")).is_empty():
				all_why = false
				missing.append(cd["text"])
	_check("every warning carries its reason", all_why, str(missing))
	# The walkway flood is cached on the design.
	_check("the access flood rides the design", van.has("access") and is_same(VehicleInterior.access(van), van["access"]))
	# Entries: the van's walk-through is a strip between the seats, the
	# skoolie's beside the driver, the step van's cab door is its side door.
	var cab_v := {}
	for en in VehicleInterior.entries(van):
		if str((en as Dictionary)["where"]) == "cab":
			cab_v = en
	_check("the van's walk-through is a 0.6 m strip on the centre line", not cab_v.is_empty()
		and absf(((cab_v["a"] as Vector2) + (cab_v["b"] as Vector2)).x * 0.5) < 1e-6
		and absf((cab_v["b"] as Vector2).x - (cab_v["a"] as Vector2).x - VehicleInterior.CAB_WALK_M) < 1e-6, str(cab_v))
	var cab_b := {}
	for en in VehicleInterior.entries(_solve("school_bus")):
		if str((en as Dictionary)["where"]) == "cab":
			cab_b = en
	_check("the skoolie's walk-through is on the curb side of the driver", not cab_b.is_empty()
		and ((cab_b["a"] as Vector2) + (cab_b["b"] as Vector2)).x * 0.5 > 0.1, str(cab_b))
	var sv_entries := VehicleInterior.entries(_solve("step_van"))
	_check("the step van's cab door is a side entry on the right, no walk-through",
		sv_entries.all(func(e): return str((e as Dictionary)["where"]) != "cab")
		and sv_entries.any(func(e): return (str((e as Dictionary)["where"]) == "side" and ((e as Dictionary)["a"] as Vector2).x > 0.0)))
	_check("a trailer has no cab entry", VehicleInterior.entries(_solve("trailer")).all(
		func(e): return str((e as Dictionary)["where"]) != "cab"))
	# Windows: over the places people sit and lie, never the door.
	var bed := VehicleInterior.element(van, "bed")
	var over_bed := panes.filter(func(w): return (float((w as Dictionary)["z0"]) < float(bed["z"]) + float(bed["fz"]) * 0.5
		and float((w as Dictionary)["z1"]) > float(bed["z"]) - float(bed["fz"]) * 0.5))
	_check("the van's panes sit beside its bed on both sides", over_bed.size() == 2, str(panes))
	var clear_door := panes.all(func(w): return (float((w as Dictionary)["sx"]) < 0.0
		or float((w as Dictionary)["z1"]) <= float(door["z0"]) + 1e-6 or float((w as Dictionary)["z0"]) >= float(door["z1"]) - 1e-6))
	_check("no pane across the slider", clear_door)
	var motor := _solve("motorhome")
	var bath := VehicleInterior.element(motor, "bath")
	var over_bath := VehicleDesign.window_spans(motor).filter(func(w): return (float((w as Dictionary)["sx"]) > 0.0
		and float((w as Dictionary)["z0"]) < float(bath["z"]) + float(bath["fz"]) * 0.5 - 0.05
		and float((w as Dictionary)["z1"]) > float(bath["z"]) - float(bath["fz"]) * 0.5 + 0.05))
	_check("no pane through the motorhome's wet bath", over_bath.is_empty(), str(over_bath))
	_check("a bus body carries a run of panes", VehicleDesign.window_spans(_solve("school_bus")).size() >= 10)
	_check("a windowless body has none", VehicleDesign.window_spans(_solve("step_van")).is_empty())
	# The cargo bay's doors are the one door rule's.
	var bt := _solve("box_truck")
	var rear := {}
	for sp in VehicleDesign.door_spans(bt):
		if str((sp as Dictionary)["where"]) == "rear":
			rear = sp
	var cdoors: Array = (bt["cargo"] as Dictionary)["doors"]
	_check("the box truck's cargo door is its roll-up span", cdoors.size() == 1
		and absf(float((cdoors[0] as Dictionary)["w_m"]) - minf(float(rear["x1"]) - float(rear["x0"]), float(bt["house"]["w"]) - 0.1)) < 1e-6
		and absf(float((cdoors[0] as Dictionary)["h_m"]) - minf(float(rear["y1"]) - float(rear["y0"]), float(bt["house"]["height"]))) < 1e-6,
		str(cdoors))


## What the builder draws: lugs by hub class, one wheel mesh per size,
## dually pairs kept apart, wheel arches on the shell, a trailer's propane
## on its tongue.
func _test_geometry() -> void:
	_check("lugs: 5 on a van, 8 on an E-450, 10 on a bus", int(_solve("van")["lug_count"]) == 5
		and int(_solve("rv")["lug_count"]) == 8 and int(_solve("school_bus")["lug_count"]) == 10
		and int(_solve("trailer")["lug_count"]) == 5)
	for pair in [["van", 2], ["school_bus", 2], ["semi_container", 2]]:
		var root := VehicleBuilder.build_node(VehiclePresets.builtin(str(pair[0])))
		var meshes := {}
		var n := 0
		for w in root.get_node("Wheels").get_children():
			meshes[((w as Node3D).get_node("Mesh") as MeshInstance3D).mesh.get_instance_id()] = true
			n += 1
		_check("%s: %d wheels share %d meshes" % [str(pair[0]), n, int(pair[1])], meshes.size() == int(pair[1]), str(meshes.size()))
		# The hub face's lugs: 12 triangles a box on the "frame" surface.
		var d := _solve(str(pair[0]))
		var w0 := (root.get_node("Wheels").get_child(0) as Node3D).get_node("Mesh") as MeshInstance3D
		var frame_tris := _surface_tris(w0.mesh as ArrayMesh, 2)
		_check("%s: the hub shows its lugs" % str(pair[0]), frame_tris == int(d["lug_count"]) * 12,
			"%d tris" % frame_tris)
		root.free()
	# A dually pair sits DUAL_GAP_M apart, pushed inside the body together.
	var bus := _solve("school_bus")
	var broot := VehicleBuilder.build_node(VehiclePresets.builtin("school_bus"))
	var pos := {}
	for w in broot.get_node("Wheels").get_children():
		pos[str(w.name)] = (w as Node3D).position
	var duals := 0
	var kept := true
	var ws: Array = bus["wheels"]
	for i in ws.size():
		for j in range(i + 1, ws.size()):
			var a: Vector3 = (ws[i] as Dictionary)["pos"]
			var b: Vector3 = (ws[j] as Dictionary)["pos"]
			if absf(a.z - b.z) < 1e-6 and a.x * b.x > 0.0:
				duals += 1
				var want := float((ws[i] as Dictionary)["w"]) + VehicleDesign.DUAL_GAP_M
				var drawn := absf((pos["W%d" % i] as Vector3).x - (pos["W%d" % j] as Vector3).x)
				if absf(absf(a.x - b.x) - want) > 1e-6 or absf(drawn - want) > 1e-6:
					kept = false
	_check("the skoolie's two dually pairs keep their gap as drawn", duals == 2 and kept)
	var hw := float(bus["body"]["w"]) * 0.5
	var inside := true
	for w in broot.get_node("Wheels").get_children():
		var p: Vector3 = (w as Node3D).position
		var wd: Dictionary = ws[int(str(w.name).substr(1))]
		if absf(p.x) + float(wd["w"]) * 0.5 > hw:
			inside = false
	_check("every wheel inside the body", inside)
	broot.free()
	# Arches: the shell carries a dark surface with a box pair per outer wheel.
	var van_root := VehicleBuilder.build_node(VehiclePresets.builtin("van"))
	var shell := van_root.get_node("Shell") as MeshInstance3D
	var dark_tris := 0
	for si in shell.mesh.get_surface_count():
		var m := shell.mesh.surface_get_material(si) as StandardMaterial3D
		if m != null and m.albedo_color.is_equal_approx(Color(0.14, 0.15, 0.17)):
			dark_tris += _surface_tris(shell.mesh as ArrayMesh, si)
	_check("the van's shell wears its rear wheel arches", dark_tris >= 2 * 24, "%d dark tris" % dark_tris)
	var cab := van_root.get_node("Cab") as MeshInstance3D
	var cab_dark := 0
	for si in cab.mesh.get_surface_count():
		var m := cab.mesh.surface_get_material(si) as StandardMaterial3D
		if m != null and m.albedo_color.is_equal_approx(Color(0.14, 0.15, 0.17)):
			cab_dark += _surface_tris(cab.mesh as ArrayMesh, si)
	_check("the van's cab wears its front arches and grille slats", cab_dark >= 2 * 24 + 3 * 12, "%d" % cab_dark)
	van_root.free()
	# A trailer's propane rides the tongue: drawn by the chassis, not inside.
	var tr := VehiclePresets.builtin("trailer")
	var plain := VehicleBuilder.build_node(tr)
	(tr["interior"]["elements"] as Array).append({"id": "gas", "type": "propane", "x": 0.0, "z": 0.2})
	var gassed := VehicleBuilder.build_node(tr)
	var ch_plain := _mesh_tris((plain.get_node("Chassis") as MeshInstance3D).mesh as ArrayMesh)
	var ch_gas := _mesh_tris((gassed.get_node("Chassis") as MeshInstance3D).mesh as ArrayMesh)
	var in_plain := _mesh_tris((plain.get_node("Interior") as MeshInstance3D).mesh as ArrayMesh)
	var in_gas := _mesh_tris((gassed.get_node("Interior") as MeshInstance3D).mesh as ArrayMesh)
	_check("a trailer's bottles are drawn on the tongue, not in the box", ch_gas > ch_plain and in_gas == in_plain,
		"chassis %d -> %d, interior %d -> %d" % [ch_plain, ch_gas, in_plain, in_gas])
	plain.free()
	gassed.free()
	# The windshield of a Class A starts ~0.9 m over the body's bottom edge.
	var mh := _solve("motorhome")
	var mroot := VehicleBuilder.build_node(VehiclePresets.builtin("motorhome"))
	var mshell := mroot.get_node("Shell") as MeshInstance3D
	var glass_lo := INF
	var glass_hi := -INF
	var zf := float(mh["body"]["z0"])
	for si in mshell.mesh.get_surface_count():
		var m := mshell.mesh.surface_get_material(si) as StandardMaterial3D
		if m == null or not m.albedo_color.is_equal_approx(VehicleBuilder.C_GLASS):
			continue
		var v: PackedVector3Array = mshell.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
		for p in v:
			if p.z < zf + 0.6:
				glass_lo = minf(glass_lo, p.y)
				glass_hi = maxf(glass_hi, p.y)
	_check("the Class A windshield runs from ~0.9 m over the body's edge", absf(glass_lo - (float(mh["body"]["y0"]) + 0.9)) < 0.02
		and glass_hi - glass_lo <= 1.31, "%.2f..%.2f" % [glass_lo, glass_hi])
	mroot.free()


func _surface_tris(mesh: ArrayMesh, si: int) -> int:
	if mesh == null or si >= mesh.get_surface_count():
		return 0
	var arr := mesh.surface_get_arrays(si)
	var idx = arr[Mesh.ARRAY_INDEX]
	if idx != null and (idx as PackedInt32Array).size() > 0:
		return (idx as PackedInt32Array).size() / 3
	return (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func _mesh_tris(mesh: ArrayMesh) -> int:
	var n := 0
	for si in mesh.get_surface_count():
		n += _surface_tris(mesh, si)
	return n


## Transport polish Phase 3: leaving through the gate, one host model, one
## door rule, one stowed-crate rule, re-stowing, the handling table.
## An open cargo door (CargoDoors): every host with a bay gets an overlay,
## the dark opening sits on its door face, and every leaf stands OUTSIDE the
## body (swung round, slid back or raised) — never through the cargo.
func _test_cargo_doors() -> void:
	var hosts: Array = [{"name": "20 ft container", "rec": {"model_id": "cargo_container",
		"container_spec": {"container_id": "container_20"}}}]
	for p in VehiclePresets.builtins():
		hosts.append({"name": str((p as Dictionary)["id"]), "rec": {"model_id": VehicleBuilder.MODEL_ID,
			"vehicle_spec": (p as Dictionary)["spec"]}})
	var planned := 0
	var outside := true
	var bad := ""
	for h in hosts:
		var rec: Dictionary = h["rec"]
		var bay := VehicleCargo.host_bay(rec)
		var pl := CargoDoors.plan(rec)
		if bay.is_empty():
			continue
		if pl.is_empty():
			bad = "%s: a bay and no door plan" % h["name"]
			outside = false
			continue
		planned += 1
		var node := CargoDoors.build(pl)
		# The body's plan rectangle the leaves must keep out of.
		var bx0 := -INF
		var bx1 := INF
		var bz0 := -INF
		var bz1 := INF
		if str(pl["where"]) == "rear":
			bx0 = float(pl["x0"]) - 0.1
			bx1 = float(pl["x1"]) + 0.1
			bz1 = float(pl["z"]) - 0.02
			bz0 = bz1 - 2.0
		else:
			bx1 = float(pl["x"]) - 0.02
			bx0 = bx1 - 1.5
			bz0 = float(pl["z0"])
			bz1 = float(pl["z1"])
		for mi in _meshes_under(node, Transform3D.IDENTITY):
			var xf: Transform3D = mi[0]
			var m: MeshInstance3D = mi[1]
			if m.material_override is StandardMaterial3D \
					and (m.material_override as StandardMaterial3D).shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
				continue   # the dark opening
			var c := xf * Vector3.ZERO
			if c.y > float(pl["y1"]):
				continue   # a roll-up's curtain, rolled up under the roof over the opening
			if c.x > bx0 and c.x < bx1 and c.z > bz0 and c.z < bz1:
				outside = false
				bad = "%s: a %s leaf at %s inside the body" % [h["name"], pl["kind"], c]
		node.free()
	_check("every host with a bay has an open-door plan", planned >= 4, "planned %d" % planned)
	_check("open door leaves stand outside the body", outside, bad)
	_check("no bay, no door", CargoDoors.plan({"model_id": "shiftpod"}).is_empty())


func _meshes_under(n: Node, xf: Transform3D) -> Array:
	var out: Array = []
	for ch in n.get_children():
		if ch is Node3D:
			var cxf: Transform3D = xf * (ch as Node3D).transform
			if ch is MeshInstance3D:
				out.append([cxf, ch])
			out.append_array(_meshes_under(ch, cxf))
	return out


func _test_transport_lifecycle() -> void:
	# --- departures ---------------------------------------------------------
	var road := {"points": PackedVector2Array([Vector2(0, 200), Vector2(0, 60), Vector2(40, 20), Vector2(140, 20)])}
	var gate := Vector2(0, 200)
	var park := Vector2(120, 26)
	var dep := VehicleDrive.make_out(gate, park, 90.0, 100.0, [road], Vector2(0, 212))
	var route: Array = dep["route"]
	_check("a departure starts at the spot and ends outside the gate",
		Vector2(float(route[0][0]), float(route[0][1])).distance_to(park) < 0.02
		and Vector2(float(route[route.size() - 1][0]), float(route[route.size() - 1][1])).distance_to(Vector2(0, 212)) < 0.02
		and bool(dep.get("out", false)))
	var ex := VehicleDrive.exit_point(park, 90.0)
	_check("it pulls out nose first (the second point is ahead of the spot)",
		Vector2(float(route[1][0]), float(route[1][1])).distance_to(ex) < 0.02
		and absf(ex.distance_to(park) - VehicleDrive.APPROACH_M) < 1e-3)
	var dur := VehicleDrive.duration_h(dep)
	var rec := {"x": park.x, "z": park.y, "yaw": 90.0, "departure": dep}
	var p0 := VehicleDrive.pose_of(rec, 99.0)
	var p1 := VehicleDrive.pose_of(rec, 100.0 + dur * 0.5)
	var p2 := VehicleDrive.pose_of(rec, 100.0 + dur + 0.01)
	_check("before it sets off it stands in its spot",
		str(p0["state"]) == VehicleDrive.STATE_PARKED and (p0["pos"] as Vector2).distance_to(park) < 1e-3)
	_check("half way it is on the road", str(p1["state"]) == VehicleDrive.STATE_DRIVING)
	_check("after the gate it is gone", str(p2["state"]) == VehicleDrive.STATE_AWAY)
	_check("parked_at / leave_h / gone_h agree with the poses",
		VehicleDrive.parked_at(rec, 99.0) and not VehicleDrive.parked_at(rec, 100.0 + dur * 0.5)
		and absf(VehicleDrive.leave_h(rec) - 100.0) < 1e-9 and absf(VehicleDrive.gone_h(rec) - 100.0 - dur) < 1e-9)
	var start := VehicleDrive.pose_of(rec, 100.0 + 1.0 / 3600.0)
	_check("it creeps out of the spot", float(start["speed"]) <= VehicleDrive.APPROACH_MS + 1e-3)
	var arr := VehicleDrive.make(gate, park, 90.0, 90.0, [road], Vector2(0, 212))
	var both := {"x": park.x, "z": park.y, "yaw": 90.0, "arrival": arr, "departure": dep}
	_check("in, parked, out: one record carries both legs",
		str(VehicleDrive.pose_of(both, 89.0)["state"]) == VehicleDrive.STATE_AWAY
		and VehicleDrive.parked_at(both, VehicleDrive.park_h(arr) + 0.1)
		and str(VehicleDrive.pose_of(both, 100.0 + dur + 0.1)["state"]) == VehicleDrive.STATE_AWAY)
	var monotone := true
	var prev_s := -1.0
	for k in 41:
		var pp := VehicleDrive.pose_at(dep, 100.0 + dur * float(k) / 40.0)
		if float(pp["s"]) < prev_s - 1e-6:
			monotone = false
		prev_s = float(pp["s"])
	_check("the way out only goes forward", monotone)
	for k2 in VehicleDrive.PLAN_CACHE_MAX + 10:
		VehicleDrive.plan(VehicleDrive.make(gate, park + Vector2(float(k2), 0.0), 0.0, 0.0, [road]))
	_check("the plan cache stays bounded", VehicleDrive._plans.size() <= VehicleDrive.PLAN_CACHE_MAX)

	# --- one host model: a container and a vehicle --------------------------
	var layer := PlacedPropLayer.new()
	var cid := layer.add_free_prop("cargo_container", 0.0, 0.0, 0.0, 30.0)
	layer.update_prop(cid, {"container_spec": {"container_id": "container_20"}})
	var crec := layer.find_by_id(cid)
	var cdoor := VehicleCargo.door_xz(crec)
	var cext: Dictionary = ContainerCatalog.find("container_20").get("exterior", {})
	var want_door := VehicleTow.world_xz(Vector3(0, 0, float(cext.get("l_m", 6.0)) * 0.5 + VehicleCargo.CONTAINER_DOOR_OUT_M),
		Vector2.ZERO, deg_to_rad(30.0))
	_check("a container's door is its local +Z end, a metre out",
		not cdoor.is_empty() and Vector2(float(cdoor["x"]), float(cdoor["z"])).distance_to(want_door) < 1e-4)
	_check("UnpackScenario.door_xz is the same rule", UnpackScenario.door_xz(crec) == cdoor)
	var res := VehicleCargo.spawn_into(layer, "starter_camp", cid, 5.0)
	var all_local := not res.is_empty()
	var poses_ok := true
	for c in res.get("crate_ids", []):
		var r := layer.find_by_id(str(c))
		if str(r.get("stowed_in", "")) != cid:
			continue
		if not (r.get("stow_local") is Array):
			all_local = false
			continue
		var ps := VehicleCargo.place_stowed(layer.find_by_id(cid), r)
		if Vector2(float(ps["x"]), float(ps["z"])).distance_to(Vector2(float(r["x"]), float(r["z"]))) > 1e-3 \
				or absf(float(ps["y_offset"]) - float(r.get("y_offset", 0.0))) > 1e-4:
			poses_ok = false
	_check("a container's crates carry stow_local too (one spawn path)", all_local)
	_check("place_stowed reproduces every spawned crate's pose", poses_ok)
	var staging_ok := true
	var dpos := Vector2(float(cdoor["x"]), float(cdoor["z"]))
	var outv: Vector2 = cdoor["out"]
	for c2 in res.get("crate_ids", []):
		var st: Dictionary = layer.find_by_id(str(c2)).get("staging", {})
		var sp := Vector2(float(st.get("x", 0.0)), float(st.get("z", 0.0)))
		if (sp - dpos).dot(outv) < VehicleCargo.STAGE_GAP_M - 1e-3:
			staging_ok = false
	_check("staging is outside the door, past the gap", staging_ok)
	# Move the host by hand: the crates follow.
	var moved := layer.find_by_id(cid).duplicate()
	moved["x"] = 40.0
	moved["yaw"] = 120.0
	var pt := VehicleCargo.reseat_patches(layer.props, moved)
	_check("a moved container re-seats its crates", pt.size() == (res["crate_ids"] as Array).size())
	# Re-stow: the load plus one more crate.
	var stowed: Array = VehicleCargo.stowed_in(layer.props, cid)
	var entries: Array = []
	for s in stowed:
		entries.append({"id": str((s as Dictionary)["id"]), "spec": PlacedPropRuntime.packed_spec_for_record(s)})
	entries.append({"id": "extra", "spec": PackedSpec.for_model("shiftpod")})
	var rs := VehicleCargo.restow_patches(layer.find_by_id(cid), entries)
	_check("a pack-up's crate is stowed with the load already in it",
		(rs["patches"] as Dictionary).has("extra")
		and str(((rs["patches"] as Dictionary)["extra"] as Dictionary).get("stowed_in", "")) == cid)
	var too_many: Array = []
	for k3 in 60:
		too_many.append({"id": "x%d" % k3, "spec": PackedSpec.for_model("shiftpod")})
	var rs2 := VehicleCargo.restow_patches(layer.find_by_id(cid), too_many)
	_check("what does not fit is handed back", not (rs2["left"] as Array).is_empty())
	# A vehicle away is no loadout host.
	var vid := layer.add_free_prop(VehicleBuilder.MODEL_ID, 300.0, 0.0, 0.0, 0.0)
	layer.update_prop(vid, {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin("box_truck")),
		"departure": VehicleDrive.make_out(gate, Vector2(300, 0), 0.0, 10.0, [road])})
	var near_parked := VehicleCargo.door_near(layer.props, Vector2(300, 0), 30.0, 9.0)
	var near_gone := VehicleCargo.door_near(layer.props, Vector2(300, 0), 30.0, 500.0)
	_check("a parked vehicle is a loadout host, a departed one is not",
		str(near_parked.get("host_id", "")) == vid and near_gone.is_empty())

	# --- forks through a vehicle door, one handling table ---------------------
	_check("the forks fit a wide door, not a narrow one",
		SiteProject.fork_fits_door({"pull_to": Vector2.ZERO, "door_w_m": 2.3, "load_w_m": 1.2})
		and not SiteProject.fork_fits_door({"pull_to": Vector2.ZERO, "door_w_m": 0.7, "load_w_m": 0.6})
		and SiteProject.fork_fits_door({}))
	_check("one handling table: hand to 23 kg, team to 60, then the forklift",
		PackKitter.handling_for(23.0) == "hand" and PackKitter.handling_for(24.0) == "team"
		and PackKitter.handling_for(61.0) == "forklift"
		and is_equal_approx(NpcHaulModel.SOLO_LIFT_KG, PackKitter.ONE_PERSON_KG)
		and PackingList._notes({"mass_kg": 40.0}).has("2-PERSON LIFT")
		and PackingList._notes({"mass_kg": 200.0}).has("FORKLIFT"))
	var bay := VehicleCargo.bay(VehicleDesign.solve(VehiclePresets.builtin("box_truck")))
	var pl := PackingList.build(bay, [{"label": "crate", "w_m": 1.0, "d_m": 1.0, "h_m": 1.0, "mass_kg": 30.0}],
		[{"unit_idx": 0, "pos": Vector3.ZERO, "size": Vector3.ONE}])
	_check("a vehicle bay's labels say V1, not C1",
		str(((pl.get("spaces", []) as Array)[0] as Dictionary).get("id", "")) == "V1")


func _side_span(d: Dictionary, kind: String) -> Dictionary:
	for sp in VehicleDesign.door_spans(d):
		if str((sp as Dictionary).get("kind", "")) == kind:
			return sp
	return {}


## The shuttle body (an Aerotech-class fiberglass box on an E-450, shaped off
## a SketchUp model of one, 2026-11-03): the skirt cut round the wheels, the
## lift's doors wherever they are asked for but never over an arch or the
## entry door, the band of windows round the doors, the livery image, and
## the Magic Tool Bus held to its owner's photos.
func _test_shuttle_body() -> void:
	var d := _solve("shuttle_bus")
	_check("the shuttle's skirt is cut round the rear wheels (the front ones are under the cab)",
		VehicleDesign.side_arches(d).size() == 1,
		str(VehicleDesign.side_arches(d)))
	_check("a van's body hangs no skirt", VehicleDesign.side_arches(_solve("van")).is_empty())
	_check("the cap rides a cutaway only", bool(d["body"]["front_cap"])
		and not bool(_solve("school_bus")["body"].get("front_cap", false)))
	for pos in ["front", "mid", "rear"]:
		var sp := VehiclePresets.builtin("shuttle_bus")
		sp["body"] = {"lift_door": pos}
		var sd := VehicleDesign.solve(sp)
		var lift := _side_span(sd, "lift")
		var entry := _side_span(sd, "bus")
		_check("a %s lift door is placed" % pos, not lift.is_empty())
		if lift.is_empty():
			continue
		var clear := true
		for a in VehicleDesign.side_arches(sd):
			if float(lift["z0"]) < float(a["z"]) + float(a["r"]) and float(lift["z1"]) > float(a["z"]) - float(a["r"]):
				clear = false
		_check("a %s lift door stays off the wheel arches" % pos, clear, str(lift))
		_check("a %s lift door stays off the entry door" % pos, float(lift["z0"]) >= float(entry["z1"]) + 0.1)
		var rear_z := float((sd["axles"][1] as Dictionary)["zf"]) - float(sd["half_len"])
		match pos:
			"front":
				_check("a front lift door is right behind the entry door", float(lift["z0"]) - float(entry["z1"]) < 0.2)
			"rear":
				_check("a rear lift door is behind the rear axle", float(lift["z0"]) > rear_z)
			_:
				_check("a mid lift door is between the doors and the rear axle", float(lift["z1"]) < rear_z)
		# The band's curb-side panes never run across a door.
		var across := false
		for w in VehicleDesign.window_spans(sd):
			var wd: Dictionary = w
			if float(wd["sx"]) > 0.0:
				for door in [lift, entry]:
					if float(wd["z0"]) < float(door["z1"]) and float(wd["z1"]) > float(door["z0"]):
						across = true
		_check("no curb-side pane across a door (%s lift)" % pos, not across)
	var typed := VehiclePresets.builtin("shuttle_bus")
	typed["body"] = {"lift_door": "front", "lift_door_at_m": 1.5}
	var td := VehicleDesign.solve(typed)
	_check("a typed lift door position is where it was typed",
		absf(float(_side_span(td, "lift")["z0"]) - (float(td["house"]["z0"]) + 1.5)) < 1e-4)
	var none := VehiclePresets.builtin("shuttle_bus")
	none["body"] = {"lift_door": "none"}
	_check("no lift: one door", VehicleDesign.door_spans(VehicleDesign.solve(none)).size() == 1)
	# The Magic Tool Bus.
	var m := _solve("magic_tool_bus")
	_check("the Magic Tool Bus is 25 ft long", absf(float(m["length_m"]) - 25.0 * 12.0 * VehicleCatalog.IN) < 0.05,
		"%.2f" % float(m["length_m"]))
	_check("on the E-450's 176 in wheelbase", absf(float(m["wheelbase_m"]) - 176.0 * VehicleCatalog.IN) < 1e-3)
	var ml := _side_span(m, "lift")
	var me := _side_span(m, "bus")
	_check("its lift doors stand right behind the entry door", not ml.is_empty()
		and float(ml["z0"]) - float(me["z1"]) > 0.05 and float(ml["z0"]) - float(me["z1"]) < 0.2)
	var side_el := {}
	for e in m["exterior"]:
		if str((e as Dictionary)["id"]) == "side_solar":
			side_el = e
	var covered := false
	for w in VehicleDesign.window_spans(m):
		var wd: Dictionary = w
		if float(wd["sx"]) > 0.0 and float(wd["z1"]) > float(side_el["u"]) - float(side_el["w"]) * 0.5 \
				and float(wd["z0"]) < float(side_el["u"]) + float(side_el["w"]) * 0.5:
			covered = true
	_check("the side array covers the curb-side windows", not covered)
	_check("1.6 kW on the roof and 600 W on the side", absf(float(m["solar_w"]) - 2200.0) < 1e-3,
		"%.0f" % float(m["solar_w"]))
	_check("it wears TriMet's livery", str(m["spec"]["paint"]["livery"]) == "transit")
	# The livery image: rear-top colour A, the swoosh B at the rear's bottom,
	# plain paint at the front; a two-tone's B under the line.
	var img := VehicleBuilder.livery_image("transit", Color.WHITE, Color.BLUE, Color.YELLOW, 0.4)
	_check("transit: A over the rear's top", img.get_pixel(10, 10).is_equal_approx(Color.BLUE))
	_check("transit: B along the rear's bottom", img.get_pixel(10, 250).is_equal_approx(Color.YELLOW))
	_check("transit: plain paint at the front", img.get_pixel(1010, 10).is_equal_approx(Color.WHITE)
		and img.get_pixel(1010, 250).is_equal_approx(Color.WHITE))
	_check("transit: the top colour sweeps up through the front third",
		img.get_pixel(700, 60).is_equal_approx(Color.BLUE) and img.get_pixel(700, 120).is_equal_approx(Color.WHITE))
	var tt := VehicleBuilder.livery_image("two_tone", Color.WHITE, Color.BLUE, Color.YELLOW, 0.4)
	_check("two-tone: B under the line, paint over it", tt.get_pixel(500, 250).is_equal_approx(Color.YELLOW)
		and tt.get_pixel(500, 20).is_equal_approx(Color.WHITE))
	_check("a livery that is not one is none", VehicleSpec.resolve({"type": "van", "paint": {"livery": "zebra"}})["paint"]["livery"] == "")
