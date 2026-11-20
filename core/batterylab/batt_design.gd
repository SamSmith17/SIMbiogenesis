class_name BattDesign
extends RefCounted

## A solved battery pack: the layout plus every number the designer shows,
## worked from the cells up. `solve(spec)` is cached by BattSpec.key_of.
##
## Electrical:
##  - Voltages: series units × the cell's voltages (a monoblock counts its
##    2 V cells). Capacity: P × the cell's Ah; energy V × Ah; usable energy at
##    the chemistry's recommended depth of discharge.
##  - Continuous current: the smallest of the cells (P × C-rate × Ah), the
##    BMS, the weakest link (busbar / nickel / cable), the main leads and the
##    breaker. `limit_by` says which.
##  - Resistance: cells S × IR / P, plus each link ρL/A, plus the main leads,
##    plus 0.05 mΩ per bolted or welded contact (an estimate; two per link
##    for each of P cells in parallel).
## Mass and cost of the parts round the cells are ESTIMATES (see `_mass` and
## `_cost`); the cells' own come from their data sheets.

const CONTACT_MOHM := 0.05
const COST_PER_WH := {
	"LFP/prismatic": 0.07, "LFP/cylindrical": 0.12, "NMC/cylindrical": 0.15, "NMC/pouch": 0.12,
	"FLA/monoblock": 0.15, "AGM/monoblock": 0.22, "GEL/monoblock": 0.25, "SLA/monoblock": 0.25,
}
const ENCLOSURE_USD := {"automotive": 25.0, "rack": 120.0, "wall": 180.0, "rolling": 220.0, "diy": 60.0}
const SELV_V := 60.0   # IEC 61140 / NEC 480: above 60 V DC is no longer "low voltage" to touch

static var _cache: Dictionary = {}
static var _order: Array = []


static func clear_cache() -> void:
	_cache.clear()
	_order.clear()


static func solve(spec: Dictionary) -> Dictionary:
	var key := BattSpec.key_of(spec)
	if _cache.has(key):
		return _cache[key]
	var d := _solve(BattSpec.resolve(spec))
	_cache[key] = d
	_order.append(key)
	if _order.size() > 32:
		_cache.erase(_order.pop_front())
	return d


static func _solve(sp: Dictionary) -> Dictionary:
	var cell := BattCells.get_cell(str(sp["cell_id"]))
	var chem := str(cell["chem"])
	var row := BattChem.row(chem)
	var s := int(sp["series"])
	var p := int(sp["parallel"])
	var fmt := str(cell["format"])
	var lithium := BattChem.is_lithium(chem)
	var single_block := fmt == "monoblock" and s * p == 1
	# Interconnect.
	var ic := str(sp["interconnect"])
	if ic == "auto":
		ic = "nickel" if fmt == "cylindrical" else ("link" if fmt == "monoblock" else "busbar")
	# Currents the cells can give.
	var cell_dis := float(p) * BattCells.max_discharge_a(cell)
	var cell_chg := float(p) * BattCells.max_charge_a(cell)
	var cell_peak := float(p) * BattCells.peak_a(cell)
	# BMS.
	var bms_id := str((sp["bms"] as Dictionary).get("id", ""))
	if bms_id.is_empty():
		bms_id = _auto_bms(chem, s, cell_dis, single_block)
	var bms := BattBms.get_bms(bms_id)
	var protected := not bms.is_empty() and bool(bms.get("protection", false))
	var target := cell_dis
	if protected:
		target = minf(target, float(bms["cont_a"]))
	# Conductors sized for the target current.
	var bus := {}
	var bb: Dictionary = sp["busbar"]
	var material := str(bb.get("material", "copper"))
	if ic == "nickel":
		var per_cell := target / float(p)
		bus = {"material": "nickel", "strips": BattElectrical.strips_for(per_cell),
			"w": float(BattElectrical.STRIP[0]), "t": float(BattElectrical.STRIP[1]) * float(BattElectrical.strips_for(per_cell))}
	else:
		var box := BattCells.box_mm(cell)
		var max_w := clampf(box.x * 0.25, 15.0, 60.0)
		var pick := BattElectrical.busbar_for(target, material, max_w)
		var w := float(bb.get("w_mm", 0.0))
		var t := float(bb.get("t_mm", 0.0))
		bus = {"material": material, "w": w if w > 0.0 else float(pick[0]),
			"t": t if t > 0.0 else float(pick[1])}
	var comp: Dictionary = sp["compression"]
	var plates := bool(comp.get("on", true)) and fmt == "prismatic" and lithium \
			and float(cell.get("compression_kgf", 0.0)) > 0.0
	var ar := BattLayout.choose(sp, cell, plates)
	var L := BattLayout.place(sp, cell, ar, ic, bus, bms if not single_block else {}, target, plates)
	# Electrical numbers.
	var units_in := BattCells.cells_inside(cell)
	var ncs := s * units_in
	var v_nom := float(s) * float(cell["nominal_v"])
	var v_max := float(ncs) * float(row["cell_max_v"])
	var v_absorb := float(ncs) * float(row["cell_absorb_v"])
	var v_float := float(ncs) * float(row["cell_float_v"])
	var v_min := float(ncs) * float(row["cell_min_v"])
	var ah := float(p) * float(cell["ah"])
	var wh := v_nom * ah
	var dod := float(row["recommended_dod"])
	var usable_wh := wh * dod
	# Conductor limits and resistance.
	var link_amps := INF
	var link_r := 0.0
	var weakest_link := ""
	for lk in (L["links"] as Array):
		var a := float((lk as Dictionary).get("amps", INF))
		if (lk as Dictionary).get("kind", "") == "cable":
			a = BattElectrical.wire_amps(float(lk["area_mm2"]))
		if a < link_amps:
			link_amps = a
			weakest_link = str(lk["id"])
		link_r += BattElectrical.resistance(str(lk["material"]), float(lk["len_mm"]), float(lk["area_mm2"]))
	var lead_r := 0.0
	var lead_amps := INF
	for ld in (L["leads"] as Array):
		lead_r += BattElectrical.resistance("copper", float(ld["len_mm"]), float(ld["mm2"]))
		if str(ld.get("kind", "")) == "main":
			lead_amps = minf(lead_amps, BattElectrical.wire_amps(float(ld["mm2"])))
	var cells_r := float(s) * float(cell["ir_mohm"]) * 0.001 / float(p)
	var contact_r := float((L["links"] as Array).size()) * 2.0 * CONTACT_MOHM * 0.001 / float(p)
	var pack_r := cells_r + link_r + lead_r + contact_r
	var breaker_a := float((L["terminals"] as Dictionary).get("breaker_a", INF))
	# Order matters on a tie: the leads and breaker are sized FROM the BMS
	# and cells, so a tie is theirs.
	var limits := {}
	if protected:
		limits["bms"] = float(bms["cont_a"])
	limits["cells"] = cell_dis
	limits["breaker"] = breaker_a
	limits["links"] = link_amps
	limits["leads"] = lead_amps
	var cont_dis := INF
	var limit_by := ""
	for k in limits:
		if float(limits[k]) < cont_dis:
			cont_dis = float(limits[k])
			limit_by = str(k)
	var cont_chg := cell_chg
	for k in limits:
		if str(k) != "cells":
			cont_chg = minf(cont_chg, float(limits[k]))
	var peak := cell_peak
	if protected:
		peak = minf(peak, float(bms["peak_a"]))
	var sag := cont_dis * pack_r
	var heat := cont_dis * cont_dis * pack_r
	var mass := _mass(L, cell, s, p, bms, protected)
	var cost := _cost(sp, cell, chem, wh, L, bms, protected, single_block)
	var cycles := BattCells.cycles_at_dod(cell, dod)
	var e := {
		"v_nom": v_nom, "v_max": v_max, "v_absorb": v_absorb, "v_float": v_float, "v_min": v_min,
		"cells_series": ncs, "ah": ah, "wh": wh, "usable_wh": usable_wh, "dod": dod,
		"cont_discharge_a": cont_dis, "cont_charge_a": cont_chg, "peak_a": peak,
		"limit_by": limit_by, "limits": limits, "weakest_link": weakest_link,
		"r_ohm": pack_r, "r_cells": cells_r, "r_links": link_r, "r_leads": lead_r,
		"r_contacts": contact_r, "sag_v": sag, "heat_w": heat,
		"cont_kw": cont_dis * v_nom * 0.001, "c_rate": cont_dis / maxf(ah, 1e-9),
		"cycles": cycles, "lifetime_kwh": cycles * usable_wh * 0.001,
		"round_trip_eff": float(row["round_trip_eff"]),
	}
	if BattChem.is_lead(chem):
		e["peukert_c5_ah"] = BattChem.peukert_capacity(chem, ah, ah / 5.0,
				float(cell.get("rate_h", 20.0)))
	var d := {
		"spec": sp, "cell": cell, "chem": chem, "chem_row": row, "lithium": lithium,
		"interconnect": ic, "bus": bus, "plates": plates, "arrange": ar,
		"bms_id": bms_id, "bms": bms, "protected": protected,
		"bms_params": BattBms.params(bms_id, chem, (sp["bms"] as Dictionary).get("overrides", {})),
		"layout": L, "electrical": e, "mass_kg": mass["total"], "mass": mass,
		"cost_usd": cost["total"], "cost": cost,
		"usd_per_kwh": cost["total"] / maxf(wh * 0.001, 1e-9),
		"explain": _explain(s, p, cell, v_nom, ah, wh, dod, limit_by, cont_dis),
	}
	d["checks"] = _checks(d)
	d["stats"] = {"v_nom": v_nom, "kwh": wh * 0.001, "kwh_usable": usable_wh * 0.001,
		"cont_a": cont_dis, "mass_kg": mass["total"], "usd_per_kwh": d["usd_per_kwh"],
		"cells": s * p, "size_mm": (L["bounds"] as AABB).size}
	return d


static func _auto_bms(chem: String, s: int, need_a: float, single_block: bool) -> String:
	if BattChem.is_lead(chem):
		return "" if single_block else "shunt_monitor"
	var fits := BattBms.fitting(chem, s)
	var best := ""
	var best_a := INF
	var biggest := ""
	var biggest_a := -1.0
	for b in fits:
		var d: Dictionary = b
		if not bool(d["protection"]):
			continue
		var a := float(d["cont_a"])
		if a >= need_a and a < best_a:
			best_a = a
			best = str(d["id"])
		if a > biggest_a:
			biggest_a = a
			biggest = str(d["id"])
	return best if not best.is_empty() else biggest


static func _box_vol(e: Dictionary) -> float:
	var sz: Vector3 = e.get("s", Vector3.ZERO)
	return sz.x * sz.y * sz.z


static func _mass(L: Dictionary, cell: Dictionary, s: int, p: int, bms: Dictionary,
		protected: bool) -> Dictionary:
	var m := {}
	m["cells"] = float(cell["mass_kg"]) * float(s * p)
	var links := 0.0
	for lk in (L["links"] as Array) + (L["ends"] as Array):
		var k := str((lk as Dictionary).get("kind", ""))
		if k == "busbar" or k == "nickel":
			links += _box_vol(lk) * 1e-9 * float(BattElectrical.DENSITY_KG_M3.get(str(lk.get("material", "copper")), 8960.0))
	m["links"] = links
	var wires := 0.0
	for ld in (L["leads"] as Array) + (L["links"] as Array).filter(func(x): return x.get("kind", "") == "link"):
		wires += BattElectrical.mass_kg("copper", float(ld["len_mm"]), float(ld.get("mm2", ld.get("area_mm2", 0.0)))) * 1.25
	for h in (L["harness"] as Array):
		wires += BattElectrical.mass_kg("copper", float(h["len_mm"]), BattElectrical.BALANCE_MM2) * 1.6
	m["wires"] = wires
	var frame := 0.0
	for h in (L["holders"] as Array):
		frame += _box_vol(h) * 1e-9 * 1050.0 * 0.35
	for t in (L["trays"] as Array):
		frame += _box_vol(t) * 1e-9 * 1050.0
	for pl in (L["plates"] as Array):
		frame += _box_vol(pl) * 1e-9 * 2700.0
	for r in (L["rods"] as Array):
		var rr := float(r["d"]) * 0.5
		frame += PI * rr * rr * (r["a"] as Vector3).distance_to(r["b"]) * 1e-9 * 7850.0
	m["frame"] = frame
	m["bms"] = (0.15 + float(bms.get("cont_a", 0.0)) * 0.002) if protected else 0.0
	var case := 0.0
	var en: Dictionary = L["enclosure"]
	if not en.is_empty():
		var dens := float(BattElectrical.DENSITY_KG_M3.get(str(en["material"]), 7850.0))
		for pn in (en["panels"] as Array):
			case += _box_vol(pn) * 1e-9 * dens
	var fit_kg := {"breaker": 0.35, "display": 0.08, "term_pos": 0.1, "term_neg": 0.1,
		"handle": 0.15, "wheel": 0.4, "ear": 0.2, "bracket": 0.9, "port": 0.01, "shunt": 0.25,
		"post_pos": 0.05, "post_neg": 0.05}
	for f in (L["fittings"] as Array):
		case += float(fit_kg.get(str(f["kind"]), 0.05))
	m["case"] = case
	var total := 0.0
	for k in m:
		total += float(m[k])
	m["total"] = total
	return m


static func _cost(sp: Dictionary, cell: Dictionary, chem: String, wh: float, L: Dictionary,
		bms: Dictionary, protected: bool, single_block: bool) -> Dictionary:
	var c := {}
	var key := "%s/%s" % [chem, str(cell["format"])]
	c["cells"] = wh * float(COST_PER_WH.get(key, 0.15))
	c["bms"] = (25.0 + float(bms.get("cont_a", 0.0)) * 0.5) if protected else (100.0 if not bms.is_empty() else 0.0)
	var cu := 0.0
	for lk in (L["links"] as Array) + (L["ends"] as Array):
		if str((lk as Dictionary).get("kind", "")) in ["busbar", "nickel"]:
			cu += _box_vol(lk) * 1e-9 * 8960.0
	c["links"] = cu * 18.0
	var wire := 0.0
	for ld in (L["leads"] as Array):
		wire += float(ld["len_mm"]) * 0.001 * float(ld["mm2"]) * 0.12 + 2.0
	c["wires"] = wire + float((L["harness"] as Array).size()) * 0.3
	c["case"] = 0.0 if single_block else float(ENCLOSURE_USD.get(str(sp["form"]), 60.0))
	if (L["terminals"] as Dictionary).has("breaker_a"):
		c["case"] += 35.0
	c["est"] = true
	var total := 0.0
	for k in c:
		if k != "est":
			total += float(c[k])
	c["total"] = total
	return c


static func _explain(s: int, p: int, cell: Dictionary, v_nom: float, ah: float, wh: float,
		dod: float, limit_by: String, amps: float) -> Dictionary:
	var words := {"cells": "the cells", "bms": "the BMS", "links": "the busbars / links",
		"leads": "the main cables", "breaker": "the breaker"}
	return {
		"voltage": "%d in series × %.1f V = %.1f V" % [s, float(cell["nominal_v"]), v_nom],
		"capacity": "%d in parallel × %.0f Ah = %.0f Ah" % [p, float(cell["ah"]), ah],
		"energy": "%.1f V × %.0f Ah = %.2f kWh" % [v_nom, ah, wh * 0.001],
		"usable": "%.2f kWh × %d %% depth of discharge = %.2f kWh" % [wh * 0.001, int(roundf(dod * 100.0)), wh * dod * 0.001],
		"current": "%.0f A, set by %s" % [amps, words.get(limit_by, limit_by)],
	}


static func _check(level: String, text: String, why: String, ids: Array = []) -> Dictionary:
	return {"level": level, "text": text, "why": why, "ids": ids}


static func _checks(d: Dictionary) -> Array:
	var out: Array = []
	var sp: Dictionary = d["spec"]
	var cell: Dictionary = d["cell"]
	var chem := str(d["chem"])
	var e: Dictionary = d["electrical"]
	var L: Dictionary = d["layout"]
	var s := int(sp["series"])
	var en: Dictionary = L["enclosure"]
	if d["lithium"] and not bool(d["protected"]):
		out.append(_check("error", "No BMS in the list fits %d %s cells in series." % [s, chem],
			"A lithium pack must have a BMS: nothing else stops a cell being charged past its top voltage or drained below its bottom one.", ["bms"]))
	if bool(d["protected"]):
		var b: Dictionary = d["bms"]
		if s < int(b["s_min"]) or s > int(b["s_max"]):
			out.append(_check("error", "%s handles %d–%d cells in series, not %d." % [b["label"], int(b["s_min"]), int(b["s_max"]), s],
				"A BMS has one balance lead per series cell; it cannot read cells it has no lead for.", ["bms"]))
		if not (b["chems"] as Array).has(chem):
			out.append(_check("error", "%s is not set up for %s." % [b["label"], chem],
				"Each chemistry has its own voltage limits.", ["bms"]))
		for msg in BattBms.check_params(d["bms_params"]):
			out.append(_check("error", str(msg), "A protection must release on the safe side of its trip, or it chatters on and off.", ["bms"]))
	if not en.is_empty() and not bool(en["fits"]):
		out.append(_check("error", "The cells do not fit the %s case." % BattSpec.FORM_WORDS[str(sp["form"])],
			"The case's size is fixed (a BCI group, a 19\" rack, or a size you typed); try another arrangement, fewer cells or a bigger case.", ["case_lid"]))
	if str(cell["format"]) == "prismatic" and BattChem.is_lithium(chem) and float(cell.get("compression_kgf", 0.0)) > 0.0 			and not bool(d["plates"]) and str(sp["form"]) != "automotive":
		out.append(_check("warn", "Prismatic LFP cells without a compression fixture.",
			"Prismatic cells swell as they charge; the maker rates their cycle life with the cells held at about %.0f kgf." % float(cell["compression_kgf"]), []))
	if str(e["limit_by"]) == "links":
		out.append(_check("warn", "The busbars / links limit the pack to %.0f A." % float(e["cont_discharge_a"]),
			"The cells and the BMS could carry more; a thicker busbar or more nickel strip lets them.", [str(e["weakest_link"])]))
	if str(e["limit_by"]) == "leads":
		out.append(_check("warn", "The main cables limit the pack to %.0f A." % float(e["cont_discharge_a"]),
			"Use a heavier gauge.", []))
	if float(e["v_max"]) > SELV_V:
		out.append(_check("info", "Above 60 V DC when full (%.1f V)." % float(e["v_max"]),
			"Over 60 V DC is no longer extra-low voltage: touching both ends can drive a dangerous current. Insulate the busbars and cover the terminals.", []))
	if BattChem.field(chem, "runaway") == "high":
		out.append(_check("info", "NMC can go into thermal runaway.",
			"An NMC cell that is crushed, overcharged or shorted can heat itself until it burns. Keep NMC packs out of living space.", []))
	if BattChem.is_lead(chem):
		out.append(_check("info", "Lead-acid has no BMS.",
			"Nothing disconnects a lead-acid battery: the charger's voltages protect it, and a shunt monitor tells you its charge. Keep it above 50 % for its rated life.", []))
		if bool(BattChem.field(chem, "vented")):
			out.append(_check("info", "Flooded batteries give off hydrogen when charging.",
				"Vent the space: about %.2f m³/h for this pack on a boost charge (IEC 62485-2)." % BattChem.ventilation_m3h(chem, int(e["cells_series"]), float(e["ah"])), []))
	if BattChem.is_lithium(chem) and float((BattChem.row(chem)["charge_temp_c"] as Array)[0]) >= 0.0:
		out.append(_check("info", "%s will not charge below freezing." % BattChem.label(chem),
			"Lithium plates metal on its anode if charged cold; the BMS blocks charging under 0 °C.", []))
	return out


## The graph battery node's specs from this design.
static func graph_specs(d: Dictionary) -> Dictionary:
	var e: Dictionary = d["electrical"]
	var sp: Dictionary = d["spec"]
	var row: Dictionary = d["chem_row"]
	return {
		"name": str(sp["name"]), "chemistry": BattChem.label(str(d["chem"])),
		"chem_detail": str(d["chem"]), "voltage": snappedf(float(e["v_nom"]), 0.01),
		"ah": snappedf(float(e["ah"]), 0.01), "kwh": snappedf(float(e["wh"]) * 0.001, 0.001),
		"max_charge_a": snappedf(float(e["cont_charge_a"]), 0.1),
		"max_discharge_a": snappedf(float(e["cont_discharge_a"]), 0.1),
		"charge_temp_min_c": float((row["charge_temp_c"] as Array)[0]),
		"cells_s": int(e["cells_series"]), "bms_id": str(d["bms_id"]),
		"round_trip_eff": float(row["round_trip_eff"]), "cost": snappedf(float(d["cost_usd"]), 1.0),
		"soc": 0.8,
	}


## Shipping size and mass (PackedSpec shape, metres).
static func packed_spec(d: Dictionary) -> Dictionary:
	var b: AABB = (d["layout"] as Dictionary)["bounds"]
	return PackedSpec.normalize({
		"w_m": b.size.x * 0.001 + 0.05, "d_m": b.size.z * 0.001 + 0.05, "h_m": b.size.y * 0.001 + 0.05,
		"form": "crate", "mass_kg": float(d["mass_kg"]) * 1.05 + 1.0, "this_side_up": true,
		"stackable": str((d["spec"] as Dictionary)["form"]) == "rack", "source": "computed",
	})
