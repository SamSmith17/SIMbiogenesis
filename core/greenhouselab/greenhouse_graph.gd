class_name GreenhouseGraph
extends RefCounted

## A placed greenhouse as ONE graph super-node (pure): inside it, a grow-bed
## node per bed (bound to that bed's prop), the grow lights over the lit beds,
## the fans, the vent motors and an electric heater on a breaker panel, the
## water barrels (their litres ARE the thermal mass), the roof catchment
## filling the water tank the beds drink from, a harvest crate and a residue
## bin. Outside it shows four ports: AC in (the panel), water in (the tank),
## food out (the crate), biomass out (the bin). Built as a component
## definition the system graph realizes and makes unique, the way vehicle and
## camp compounds are (SystemGraphView.sync_greenhouse_system). It is NOT a
## power island: its loads draw the site's AC through the panel.
##
## The flow engine runs the house's climate on the compound
## (ResourceFlowEngine._process_greenhouse) and grows each bed from it; the
## bed nodes keep the ordinary plant ports so the player can rewire them.

const DEF_PREFIX := "greenhouse_"
## A house with no cistern still gets a small tank for its beds' water.
const DEFAULT_TANK_L := 300.0
const HARVEST_KG := 500.0
## A fed house (spec beds.feed) keeps this much N + P + K for its beds.
const NUTRIENT_KG := 25.0
const RESIDUE_KG := 1000.0
## Above this many lit beds, one "Grow lights" load stands for all of them.
const MAX_LIGHT_NODES := 5
const ROLE_KEY := "gh_role"


static func def_id_for(prop_id: String) -> String:
	return DEF_PREFIX + prop_id


## What changes the node's contents (not its position or its tank levels).
static func signature(d: Dictionary, parts: Dictionary = {}) -> String:
	var s: Dictionary = d["spec"]
	var bits := [GreenhouseSpec.key_of(s), parts.keys()]
	var pv := []
	for k in parts:
		pv.append(str(parts[k]))
	pv.sort()
	bits.append(pv)
	return str(JSON.stringify(bits).hash())


## The definition. `parts` = {gh_part key: prop id} of the placed beds and
## light racks (GreenhouseWorld.parts_of), so each bed / light node is bound
## to its prop.
static func definition(d: Dictionary, def_id: String, parts: Dictionary = {}) -> Dictionary:
	var s: Dictionary = d["spec"]
	var st: Dictionary = d["stats"]
	var items: Array = []
	var conns: Array = []
	var eps: Array = []
	var beds: Array = d.get("beds", [])
	# --- water: the roof into the tank, the tank to every bed ---------------
	var cistern := float(s["rain"]["cistern_l"])
	var tank_l := cistern if cistern > 1.0 else DEFAULT_TANK_L
	items.append({"local_id": "tank", "type": "resource", "dx": -460.0, "dy": -60.0,
		"specs": _tank("Cistern" if cistern > 1.0 else "Watering tank", "water", tank_l, "L", 0.5, "tank")})
	eps.append({"handle_id": "water_in", "child": "tank", "child_handle": "input", "direction": "in",
		"polarity": "resource", "kind": "water", "label": "Water in", "face": "top"})
	if bool(s["rain"]["gutters"]) and float(st["roof_plan_m2"]) > 0.0:
		items.append({"local_id": "roof", "type": "catchment", "dx": -460.0, "dy": -300.0,
			"specs": {"name": "Roof", "catchment_kind": "roof", "use_soi_area": false,
				"area_m2": float(st["roof_plan_m2"]), "runoff_coeff": 0.9, "cost": 0.0, ROLE_KEY: "roof"}})
		conns.append(_rc("roof", "output", "tank", "input", "water"))
	if int(st["barrels"]) > 0:
		items.append({"local_id": "barrels", "type": "resource", "dx": -460.0, "dy": 200.0,
			"specs": _tank("Water barrels (%d)" % int(st["barrels"]), "water", float(st["water_mass_l"]), "L", 1.0, "barrels")})
	# --- harvest + residue -------------------------------------------------
	items.append({"local_id": "harvest", "type": "resource", "dx": 0.0, "dy": 380.0,
		"specs": _tank("Harvest", "food", HARVEST_KG, "kg", 0.0, "harvest")})
	eps.append({"handle_id": "food_out", "child": "harvest", "child_handle": "output", "direction": "out",
		"polarity": "resource", "kind": "food", "label": "Food", "face": "bottom"})
	items.append({"local_id": "residue", "type": "resource", "dx": 260.0, "dy": 380.0,
		"specs": _tank("Stalks and leaves", "biomass", RESIDUE_KG, "kg", 0.0, "residue")})
	eps.append({"handle_id": "biomass_out", "child": "residue", "child_handle": "output", "direction": "out",
		"polarity": "resource", "kind": "biomass", "label": "Residue", "face": "bottom"})
	# --- fed beds: a nutrient store the site tops up --------------------------
	var feed := bool(s["beds"].get("feed", false))
	if feed:
		items.append({"local_id": "nutrients", "type": "resource", "dx": -460.0, "dy": 440.0,
			"specs": _tank("Nutrients", "nutrients", NUTRIENT_KG, "kg", 0.5, "nutrients")})
		eps.append({"handle_id": "nutrients_in", "child": "nutrients", "child_handle": "input", "direction": "in",
			"polarity": "resource", "kind": "nutrients", "label": "Nutrients in", "face": "top"})
	# --- the beds ----------------------------------------------------------
	var step := 210.0
	var off := (float(beds.size()) - 1.0) * 0.5 * step
	var lit: Array = []
	for i in beds.size():
		var b: Dictionary = beds[i]
		var lid := "bed_%d" % i
		var bid := str(b["id"])
		var specs := {"name": _bed_name(b), "area_m2": float(b["area_m2"]), "use_soi_area": false,
			"lue_g_per_mj": 2.0, "water_l_per_kg": 50.0, "nutrient_kg_per_kg": 0.015,
			"sunlight_factor": 1.0, "food_fraction": 0.6, "establish_days": 45.0, "cost": 0.0,
			"gh_bed": bid, "gh_crops": b["crops"], ROLE_KEY: "bed",
			"model_id": FarmBotBuilder.MODEL_ID if bool(b.get("gantry", false)) else "grow_bed"}
		var pid := str(parts.get("bed:" + bid, ""))
		if not pid.is_empty():
			specs["bound_prop_id"] = pid
		items.append({"local_id": lid, "type": "plant", "dx": float(i) * step - off, "dy": 120.0, "specs": specs})
		conns.append(_rc("tank", "output", lid, "water_in", "water"))
		if feed:
			conns.append(_rc("nutrients", "output", lid, "nutrients_in", "nutrients"))
		conns.append(_rc(lid, "biomass_out", "harvest", "input", "food"))
		conns.append(_rc(lid, "residue_out", "residue", "input", "biomass"))
		if b.has("light"):
			lit.append(b)
	# --- electric loads on a panel -----------------------------------------
	var loads: Array = []
	if int(st.get("fans", 0)) > 0 or float(st["fan_w"]) > 0.0:
		loads.append({"local_id": "fans", "name": "Exhaust fans", "w": float(st["fan_w"]), "role": "fans"})
	if not (d["frame"]["vents"] as Array).is_empty():
		loads.append({"local_id": "vents", "name": "Vent motors", "w": GreenhouseMaterials.VENT_MOTOR_W, "role": "vents"})
	var heater: Dictionary = GreenhouseMaterials.heater(str(s["heater"]))
	if float(heater.get("w", 0.0)) > 0.0 and str(heater.get("fuel", "")) == "electric":
		loads.append({"local_id": "heater", "name": "Heater", "w": float(heater["w"]), "role": "heater"})
	if lit.size() > MAX_LIGHT_NODES:
		var w := 0.0
		for b in lit:
			w += float((b as Dictionary)["light"]["w"])
		loads.append({"local_id": "lights", "name": "Grow lights (%d beds)" % lit.size(), "w": w, "role": "lights"})
	else:
		for b in lit:
			var bd: Dictionary = b
			var e := {"local_id": "lights_%s" % str(bd["id"]), "name": "Grow lights %s" % str(bd["id"]),
				"w": float(bd["light"]["w"]), "role": "lights", "bed": str(bd["id"])}
			var lp := str(parts.get("lights:" + str(bd["id"]), ""))
			if not lp.is_empty():
				e["prop"] = lp
			loads.append(e)
	if not loads.is_empty():
		items.append({"local_id": "panel", "type": "breaker_panel", "dx": 380.0, "dy": -320.0,
			"specs": {"name": "Greenhouse panel", "passthrough": true, "channel_count": 8, "main_on": true,
				"main_amps": 60.0, "max_amps_per_circuit": 20.0, "cost": 0.0}})
		eps.append({"handle_id": "ac_in", "child": "panel", "child_handle": "ac_in", "direction": "in",
			"polarity": "ac", "kind": "", "label": "AC in", "face": "top"})
		var lstep := 200.0
		var loff := (float(loads.size()) - 1.0) * 0.5 * lstep
		for i in mini(loads.size(), 8):
			var ld: Dictionary = loads[i]
			var specs2 := {"name": str(ld["name"]), "max_watts": float(ld["w"]), "avg_watts": float(ld["w"]),
				"requested_state": "off", "cost": 0.0, ROLE_KEY: str(ld["role"])}
			if ld.has("bed"):
				specs2["gh_bed"] = str(ld["bed"])
			if ld.has("prop"):
				specs2["bound_prop_id"] = str(ld["prop"])
			items.append({"local_id": str(ld["local_id"]), "type": "appliance",
				"dx": 380.0 + float(i) * lstep - loff, "dy": -100.0, "specs": specs2})
			conns.append({"source": "panel", "source_handle": "circuit_%d" % i, "target": str(ld["local_id"]),
				"target_handle": "input", "polarity": "ac"})
	var bits: Array = []
	bits.append(UiText.num(float(st["floor_area_m2"]), "m²", 3))
	bits.append(UiText.count(beds.size(), "bed"))
	if not lit.is_empty():
		bits.append("lights")
	if int(st["barrels"]) > 0:
		bits.append(UiText.count(int(st["barrels"]), "barrel"))
	return {
		"id": def_id, "name": str(s["name"]), "icon": "🌿", "rev": 1, "width": 230.0, "height": 160.0,
		"specs": {"summary": " · ".join(bits), "greenhouse_system": true},
		"subgraph": {"items": items, "connections": conns, "exposed_ports": eps},
	}


static func _bed_name(b: Dictionary) -> String:
	var ids := GreenhouseSpec.mix_crops(b["crops"])
	var what := "Garden"
	if b["crops"] is Array and ids.size() <= 2:
		var names: Array = []
		for id in ids:
			names.append(str(GardenCrops.CROPS.get(str(id), {}).get("label", UiText.from_id(str(id)))))
		what = " + ".join(names)
	return "Bed %s · %s" % [str(b["id"]), what]


static func _tank(name: String, kind: String, cap: float, unit: String, level: float, role: String) -> Dictionary:
	return {"name": name, "resource_kind": kind, "capacity": "%.0f %s" % [cap, unit], "capacity_qty": cap,
		"capacity_unit": unit, "level": level, "cost": 0.0, ROLE_KEY: role}


static func _rc(src: String, sh: String, dst: String, dh: String, kind: String) -> Dictionary:
	return {"source": src, "source_handle": sh, "target": dst, "target_handle": dh,
		"polarity": "resource", "resource_type": kind}


## The realized compound's children by role: {role: [item]}.
static func children_by_role(model: Object, comp_id: String) -> Dictionary:
	var out := {}
	var it: Dictionary = model.call("get_item", comp_id)
	var scope := str(it.get("child_scope_id", ""))
	if scope.is_empty():
		return out
	for c in model.call("get_items_in_scope", scope):
		var r := str(((c as Dictionary).get("specs", {}) as Dictionary).get(ROLE_KEY, ""))
		if r.is_empty():
			continue
		if not out.has(r):
			out[r] = []
		(out[r] as Array).append(c)
	return out
