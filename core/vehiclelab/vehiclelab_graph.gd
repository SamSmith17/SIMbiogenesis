class_name VehicleGraph
extends RefCounted

## A living vehicle's own power and water system as ONE graph super-node:
## the roof solar's panels, a charge controller, the house battery, an
## inverter feeding the vehicle's loads (fridge, lights, fans, AC, Starlink),
## and its fresh and grey water tanks. Built from the solved design
## (VehicleInterior.systems) as a component definition the system graph
## realizes and makes unique, the way camp compounds are
## (SystemGraphView.sync_vehicle_system). Pure.
##
## Module electricals are the typical data-sheet figures of each class
## (estimates): a 400 W 108-half-cell module Voc 37.5 / Vmp 31.4 V; a
## "12 V" 200 W module Voc 24.3 / Vmp 20.4 V; a 100 W flexible module
## Voc 21.6 / Vmp 18.0 V. Each solar item's modules are wired in SERIES
## STRINGS of up to STRING_MAX under the controller's Voc cap (strings in
## parallel onto its PV terminals), the way a van builder keeps the roof
## current down: 20 × 400 W all in parallel would be 260 A.

const DEF_PREFIX := "vehicle_"
const MODULE_EL := {
	"rigid_400": {"voc": 37.5, "vmp": 31.4},
	"rigid_200": {"voc": 24.3, "vmp": 20.4},
	"flex_100": {"voc": 21.6, "vmp": 18.0},
}
## Above this many modules each solar item is drawn as ONE panel per string
## of the item's total (the string's Voc, the summed current) so the node
## stays readable.
const MAX_PANEL_NODES := 16
## The controller's open-circuit limit and the headroom a cold morning
## takes (Voc rises ~0.3 %/°C below 25 °C: −10 °C adds ~10 %).
const CC_MAX_VOC := 150.0
const COLD_VOC_HEADROOM := 0.85
const STRING_MAX := 3


## Modules per series string for `n` modules of a module class: the longest
## of 3 / 2 / 1 that keeps the string's Voc under the cold cap AND divides n,
## so every string is the same length (unequal strings in parallel fight).
static func string_len(n: int, voc: float) -> int:
	var cap := int(floor(CC_MAX_VOC * COLD_VOC_HEADROOM / maxf(voc, 1.0)))
	for s in range(mini(STRING_MAX, cap), 0, -1):
		if n % s == 0:
			return s
	return 1
## Battery state of charge a freshly placed vehicle starts at.
const START_SOC := 0.8


static func def_id_for(prop_id: String) -> String:
	return DEF_PREFIX + prop_id


## What changes the node's contents (not its position): its signature.
static func signature(sys: Dictionary) -> String:
	return str(JSON.stringify(sys).hash())


## Has the design anything for the graph? (A bare cargo van does not.)
static func has_system(sys: Dictionary) -> bool:
	return float(sys.get("battery_kwh", 0.0)) > 0.0 or float(sys.get("solar_w", 0.0)) > 0.0 \
		or float(sys.get("water_l", 0.0)) > 0.0 or float(sys.get("grey_l", 0.0)) > 0.0


## The component definition for a solved design. {} when there is nothing to
## put on the graph.
static func definition(d: Dictionary, def_id: String) -> Dictionary:
	var sys: Dictionary = d.get("systems", VehicleInterior.systems(d))
	if not has_system(sys):
		return {}
	var items: Array = []
	var conns: Array = []
	var eps: Array = []
	var v := float(sys["voltage"])
	var kwh := float(sys["battery_kwh"])
	var solar_w := float(sys["solar_w"])
	var loads: Array = sys["loads"]
	var has_bat := kwh > 0.0
	# Panels, one row across the top, grouped into series strings: `strings`
	# is a list of panel-index lists, each one string in chain order.
	var panels: Array = []
	var strings: Array = []
	var total_modules := 0
	for s in sys["solar"]:
		total_modules += int((s as Dictionary)["count"])
	for s in sys["solar"]:
		var sd: Dictionary = s
		var el: Dictionary = MODULE_EL.get(str(sd["module"]), MODULE_EL["rigid_400"])
		var w := float(sd["watts"])
		var n := int(sd["count"])
		var slen := string_len(n, float(el["voc"]))
		var n_strings := n / slen
		var merge := total_modules > MAX_PANEL_NODES
		for k in n_strings:
			if merge:
				# One node per string: the string's voltages, its watts.
				var wmp := w * float(slen)
				panels.append({"name": "Roof solar (%d × %s)" % [slen, UiText.num(w, "W")] if slen > 1
						else "Roof solar %s" % UiText.num(w, "W"),
					"wmp": wmp, "voc": float(el["voc"]) * float(slen), "vmp": float(el["vmp"]) * float(slen),
					"imp": w / float(el["vmp"]), "isc": w / float(el["vmp"]) * 1.07, "cost": 0.0})
				strings.append([panels.size() - 1])
				continue
			var chain: Array = []
			for i in slen:
				panels.append({"name": "Roof solar %s" % UiText.num(w, "W"),
					"wmp": w, "voc": float(el["voc"]), "vmp": float(el["vmp"]),
					"imp": w / float(el["vmp"]), "isc": w / float(el["vmp"]) * 1.07, "cost": 0.0})
				chain.append(panels.size() - 1)
			strings.append(chain)
	var step := 220.0
	var off := (float(panels.size()) - 1.0) * 0.5 * step
	for i in panels.size():
		var lid := "pv_%d" % i
		items.append({"local_id": lid, "type": "panel", "dx": float(i) * step - off, "dy": -380.0,
			"specs": panels[i]})
	var has_cc := not panels.is_empty() and has_bat
	if has_cc:
		var amps := clampf(ceilf(solar_w / v * 1.25 / 5.0) * 5.0, 10.0, 150.0)
		items.append({"local_id": "cc", "type": "controller", "dx": -150.0, "dy": -120.0,
			"specs": {"name": "MPPT charge controller", "max_voc": CC_MAX_VOC,
				"max_charge_amps": amps, "max_pv_watts": maxf(solar_w * 1.1, 200.0),
				"system_voltage": v, "cost": 0.0}})
		# Series inside a string (+ of one to − of the next, the convention
		# GraphPvWiring.wire_series writes), the string's ends on the
		# controller, strings in parallel.
		for chain in strings:
			var ch: Array = chain
			for i in range(ch.size() - 1):
				conns.append({"source": "pv_%d" % int(ch[i]), "source_handle": "positive",
					"target": "pv_%d" % int(ch[i + 1]), "target_handle": "negative", "polarity": "positive"})
			conns.append({"source": "pv_%d" % int(ch[ch.size() - 1]), "source_handle": "positive",
				"target": "cc", "target_handle": "pvPositive", "polarity": "positive"})
			conns.append({"source": "pv_%d" % int(ch[0]), "source_handle": "negative",
				"target": "cc", "target_handle": "pvNegative", "polarity": "negative"})
	if has_bat:
		items.append({"local_id": "bat", "type": "battery", "dx": 150.0, "dy": -120.0,
			"specs": {"name": "House battery", "voltage": v, "ah": kwh * 1000.0 / v,
				"kwh": kwh, "soc": START_SOC, "cost": 0.0}})
		if has_cc:
			conns.append({"source": "cc", "source_handle": "batteryPositive",
				"target": "bat", "target_handle": "positive", "polarity": "positive"})
			conns.append({"source": "cc", "source_handle": "batteryNegative",
				"target": "bat", "target_handle": "negative", "polarity": "negative"})
	if has_bat and not loads.is_empty():
		var total := 0.0
		for l in loads:
			total += float((l as Dictionary)["watts"])
		var rated := maxf(ceilf(total * 1.5 / 500.0) * 500.0, 1000.0)
		items.append({"local_id": "inv", "type": "controller", "dx": 0.0, "dy": 110.0,
			"specs": {"name": "Inverter", "max_load_amps": rated / v,
				"overload_watts": rated, "system_voltage": v, "cost": 0.0}})
		conns.append({"source": "bat", "source_handle": "positive",
			"target": "inv", "target_handle": "batteryPositive", "polarity": "positive"})
		conns.append({"source": "bat", "source_handle": "negative",
			"target": "inv", "target_handle": "batteryNegative", "polarity": "negative"})
		var lstep := 220.0
		var loff := (float(loads.size()) - 1.0) * 0.5 * lstep
		for i in loads.size():
			var ld: Dictionary = loads[i]
			var lid2 := "load_%d" % i
			items.append({"local_id": lid2, "type": "appliance", "dx": float(i) * lstep - loff, "dy": 360.0,
				"specs": {"name": str(ld["name"]), "max_watts": float(ld["watts"]),
					"avg_watts": float(ld["watts"]), "requested_state": "on", "cost": 0.0,
					"vehicle_element": str(ld.get("id", ""))}})
			conns.append({"source": "inv", "source_handle": "acOutput", "target": lid2,
				"target_handle": "input", "polarity": "ac"})
	if float(sys["water_l"]) > 0.0:
		items.append({"local_id": "water", "type": "resource", "dx": -420.0, "dy": 110.0,
			"specs": _tank("Fresh water", "water", float(sys["water_l"]), 1.0)})
		eps.append({"handle_id": "water_in", "child": "water", "child_handle": "input",
			"direction": "in", "polarity": "resource", "kind": "water", "label": "Fill water", "face": "top"})
	if float(sys["grey_l"]) > 0.0:
		items.append({"local_id": "grey", "type": "resource", "dx": 420.0, "dy": 110.0,
			"specs": _tank("Grey water", "greywater", float(sys["grey_l"]), 0.0)})
		eps.append({"handle_id": "grey_out", "child": "grey", "child_handle": "output",
			"direction": "out", "polarity": "resource", "kind": "greywater", "label": "Dump grey", "face": "bottom"})
	var bits: Array = []
	if solar_w > 0.0:
		bits.append("%s solar" % UiText.num(solar_w, "W"))
	if has_bat:
		bits.append("%s battery" % UiText.num(kwh * 1000.0, "Wh"))
	if not loads.is_empty():
		bits.append(UiText.count(loads.size(), "load"))
	if float(sys["water_l"]) > 0.0:
		bits.append("%d L water" % int(round(float(sys["water_l"]))))
	return {
		"id": def_id, "name": str(d.get("name", "Vehicle")), "icon": "🚐", "rev": 1,
		"width": 220.0, "height": 150.0,
		"specs": {"summary": " · ".join(bits), "vehicle_system": true},
		"subgraph": {"items": items, "connections": conns, "exposed_ports": eps},
	}


static func _tank(name: String, kind: String, cap: float, level: float) -> Dictionary:
	return {"name": name, "resource_kind": kind, "capacity": "%.0f L" % cap,
		"capacity_qty": cap, "capacity_unit": "L", "level": level, "cost": 0.0,
		"vehicle_store": true}
