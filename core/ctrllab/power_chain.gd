class_name PowerChain
extends RefCounted

## Panels › controller › battery: the solar power chain one graph item is
## part of, found from its wires, and the checks between the three. Pure over
## a GraphModel (no scene), so the three labs and the selftest share it.
##
## A UNIT is what a lab designs: a panel or a solar array (a panel inside an
## "array" / "pv_design" group counts as its group), a controller, a battery.
## The chain follows DC wires only: a controller's pv* terminals to its
## panels (through panel-to-panel string wires), its battery* terminals to a
## battery (through battery-to-battery series / parallel wires).

const ARRAY_KINDS := ["array", "pv_design"]
const PV_TYPES := ["panel"]
const BAT_TYPES := ["battery", "smartbattery"]

## A bank's voltage may sit this far from the controller's system voltage
## (a 51.2 V LFP bank on a "48 V" unit is right; a 25.6 V one is not).
const VOLT_TOL := 0.2
## Above this share of the BMS's charge limit a controller's charge current is
## a warning (it will be clipped, or trip the BMS on a cold morning).
const AMP_TOL := 1.0
## Inverter efficiency for the battery current at full AC load (estimate).
const INV_EFF := 0.9


## {start: kind, arrays: [unit], controller: unit, battery: unit}; a missing
## one is {}. unit = {id, kind panels|controller|battery, name, prop_id,
## designed}.
static func find(model: GraphModel, item_id: String) -> Dictionary:
	var out := {"start": "", "arrays": [], "controller": {}, "battery": {}}
	if model == null or item_id.is_empty():
		return out
	var start := unit_of(model, item_id)
	if start.is_empty():
		return out
	var kind := kind_of(model, start)
	out["start"] = kind
	var ctrl := ""
	match kind:
		"controller":
			ctrl = start
		"panels":
			ctrl = _reach(model, start, "panels", "pv")
		"battery":
			ctrl = _reach(model, start, "battery", "battery")
		_:
			return out
	if ctrl.is_empty():
		if kind == "panels":
			out["arrays"] = [describe(model, start)]
		elif kind == "battery":
			out["battery"] = describe(model, start)
		return out
	out["controller"] = describe(model, ctrl)
	for a in _neighbours(model, ctrl, "pv", "panels"):
		(out["arrays"] as Array).append(describe(model, a))
	var bats := _neighbours(model, ctrl, "battery", "battery")
	if kind == "battery":
		out["battery"] = describe(model, start)
	elif not bats.is_empty():
		out["battery"] = describe(model, bats[0])
	return out


## The unit an item belongs to: a panel inside a solar array is the array.
static func unit_of(model: GraphModel, item_id: String) -> String:
	var id := item_id
	for _i in 16:
		var it := model.get_item(id)
		if it.is_empty():
			return ""
		var sc := str(it.get("scope_id", "root"))
		if sc.is_empty() or sc == "root":
			return id
		var parent := model.get_item(sc)
		if parent.is_empty() or not ARRAY_KINDS.has(GraphNesting.compound_kind(parent)):
			return id
		id = sc
	return id


static func kind_of(model: GraphModel, unit_id: String) -> String:
	var it := model.get_item(unit_id)
	var ty := str(it.get("type", ""))
	if PV_TYPES.has(ty) or (ty == "compound" and ARRAY_KINDS.has(GraphNesting.compound_kind(it))):
		return "panels"
	if ty == "controller":
		return "controller"
	if BAT_TYPES.has(ty):
		return "battery"
	return ""


static func describe(model: GraphModel, unit_id: String) -> Dictionary:
	var it := model.get_item(unit_id)
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	var kind := kind_of(model, unit_id)
	var nm := str(sp.get("name", it.get("label", "")))
	if nm.is_empty():
		nm = str(it.get("label", unit_id))
	var prop := str(sp.get("bound_prop_id", ""))
	var designed := false
	match kind:
		"panels":
			var tag := str(sp.get("pvlab_tag", ""))
			if tag.begins_with("pvlab_"):
				prop = tag.substr(6)
				designed = true
		"controller":
			designed = sp.get("controller_spec") is Dictionary
		"battery":
			designed = sp.get("battery_bank_spec") is Dictionary
	return {"id": unit_id, "kind": kind, "name": nm, "prop_id": prop, "designed": designed}


## Every wire with its two ends as units: [{a, ha, b, hb}] both ways.
static func _edges(model: GraphModel) -> Array:
	var out: Array = []
	for c: Dictionary in model.connections:
		var pol := str(c.get("polarity", ""))
		if pol == "ac" or pol == "data":
			continue
		var a := unit_of(model, str(c.get("source_item_id", "")))
		var b := unit_of(model, str(c.get("target_item_id", "")))
		if a.is_empty() or b.is_empty() or a == b:
			continue
		var ha := str(c.get("source_handle_id", ""))
		var hb := str(c.get("target_handle_id", ""))
		out.append({"a": a, "ha": ha, "b": b, "hb": hb})
		out.append({"a": b, "ha": hb, "b": a, "hb": ha})
	return out


## From the controller's `prefix` terminals, every unit of `want` reached
## through units of that kind only (strings, series banks).
static func _neighbours(model: GraphModel, ctrl: String, prefix: String, want: String) -> Array:
	var edges := _edges(model)
	var found: Array = []
	var seen := {ctrl: true}
	var queue: Array = []
	for e in edges:
		if str(e["a"]) == ctrl and str(e["ha"]).begins_with(prefix):
			var b := str(e["b"])
			if not seen.has(b) and kind_of(model, b) == want:
				seen[b] = true
				queue.append(b)
	while not queue.is_empty():
		var u := str(queue.pop_front())
		found.append(u)
		for e in edges:
			if str(e["a"]) != u:
				continue
			var b2 := str(e["b"])
			if not seen.has(b2) and kind_of(model, b2) == want:
				seen[b2] = true
				queue.append(b2)
	return found


## From a unit of `kind`, through units of that kind, the first controller
## met on one of its `prefix` terminals.
static func _reach(model: GraphModel, start: String, kind: String, prefix: String) -> String:
	var edges := _edges(model)
	var seen := {start: true}
	var queue: Array = [start]
	while not queue.is_empty():
		var u := str(queue.pop_front())
		for e in edges:
			if str(e["a"]) != u:
				continue
			var b := str(e["b"])
			if kind_of(model, b) == "controller" and str(e["hb"]).begins_with(prefix):
				return b
			if not seen.has(b) and kind_of(model, b) == kind:
				seen[b] = true
				queue.append(b)
	return ""


## The checks between the links: [{level error|warn|info, text, why, link
## panels|battery}]. `window` = PvElectrical.string_window_report for the
## controller (passed in: it needs flat connections the caller may cache).
static func checks(model: GraphModel, chain: Dictionary, window: Dictionary = {}) -> Array:
	var out: Array = []
	var c: Dictionary = chain.get("controller", {})
	if c.is_empty():
		return out
	var cs: Dictionary = model.get_item(str(c["id"])).get("specs", {}) as Dictionary
	if not window.is_empty():
		for iss in (window.get("issues", []) as Array):
			out.append({"level": "error" if str(iss).contains("exceeds") else "warn", "link": "panels",
				"text": "Panels: %s." % str(iss),
				"why": "The strings' cold-morning Voc must stay under the controller's limit, and their working voltage inside its MPPT window."})
	var b: Dictionary = chain.get("battery", {})
	if b.is_empty():
		return out
	var bs: Dictionary = model.get_item(str(b["id"])).get("specs", {}) as Dictionary
	var sys_v := float(cs.get("system_voltage", 0.0))
	var bat_v := float(bs.get("voltage", 0.0))
	if sys_v > 0.0 and bat_v > 0.0 and absf(bat_v - sys_v) > sys_v * VOLT_TOL:
		out.append({"level": "error", "link": "battery",
			"text": "Battery: %.1f V bank on a %.0f V controller." % [bat_v, sys_v],
			"why": "A controller charges one battery voltage; the bank must match its system voltage."})
	var ch_a := float(cs.get("max_charge_amps", 0.0))
	var bms_ch := float(bs.get("max_charge_a", 0.0))
	if ch_a > 0.0 and bms_ch > 0.0 and ch_a > bms_ch * AMP_TOL:
		out.append({"level": "warn", "link": "battery",
			"text": "Battery: the controller charges at up to %.0f A, the bank's BMS takes %.0f A." % [ch_a, bms_ch],
			"why": "The charger is held to the BMS's limit (or trips it); a bigger bank or more packs in parallel takes the full current."})
	var ac_w := float(cs.get("overload_watts", 0.0))
	var bms_dis := float(bs.get("max_discharge_a", 0.0))
	var v := bat_v if bat_v > 0.0 else sys_v
	if ac_w > 0.0 and bms_dis > 0.0 and v > 0.0:
		var need := ac_w / (v * INV_EFF)
		if need > bms_dis:
			out.append({"level": "warn", "link": "battery",
				"text": "Battery: at full AC output (%s) the inverter draws %.0f A, the BMS lets out %.0f A." % [UiText.num(ac_w, "W"), need, bms_dis],
				"why": "At full load the BMS would cut off the bank; add packs in parallel or keep the AC load lower."})
	var comms: Array = (cs.get("comms", []) as Array).map(func(x): return _proto(str(x)))
	var bms_id := str(bs.get("bms_id", ""))
	var bms_c: Array = []
	if not bms_id.is_empty() and BattBms.has(bms_id):
		bms_c = (BattBms.get_bms(bms_id).get("comms", []) as Array).map(func(x): return _proto(str(x)))
	var wired := ["CAN", "RS485"]
	var shared := false
	for p in comms:
		if wired.has(p) and bms_c.has(p):
			shared = true
	var ctrl_w := comms.filter(func(p): return wired.has(p))
	var bms_w := bms_c.filter(func(p): return wired.has(p))
	if not ctrl_w.is_empty() and not bms_w.is_empty() and not shared:
		out.append({"level": "info", "link": "battery",
			"text": "Battery: its BMS talks %s; the controller talks %s." % [", ".join(PackedStringArray(bms_w)), ", ".join(PackedStringArray(ctrl_w))],
			"why": "Without a shared protocol the controller charges by voltage only (no closed-loop BMS limits)."})
	return out


static func _proto(t: String) -> String:
	var u := t.to_upper().replace("-", "").replace(" ", "")
	if u.begins_with("RS485"):
		return "RS485"
	if u.begins_with("CAN"):
		return "CAN"
	return u


## The solar designer's target window from a graph controller's specs (one
## MPPT input's limits where the unit lists them).
static func pv_target(sp: Dictionary) -> Dictionary:
	var t := {"max_voc": float(sp.get("max_voc", 150.0))}
	for pair in [["mppt_min_v", "mppt_min_v"], ["mppt_max_v", "mppt_max_v"], ["startup_v", "startup_v"],
			["max_isc_amps", "max_isc"]]:
		if float(sp.get(pair[0], 0.0)) > 0.0:
			t[pair[1]] = float(sp[pair[0]])
	var w := float(sp.get("max_pv_watts_per_mppt", sp.get("max_pv_watts", 0.0)))
	if w > 0.0:
		t["max_pv_watts"] = w
	return t


## A battery preset from the library whose voltage is nearest `volts`.
static func battery_preset_for(volts: float) -> Dictionary:
	var best: Dictionary = {}
	var bd := INF
	for p: Dictionary in ComponentPresets.BATTERIES:
		if str(p.get("type", "")) != "battery":
			continue
		var d := absf(float((p.get("specs", {}) as Dictionary).get("voltage", 0.0)) - volts)
		if d < bd:
			bd = d
			best = p
	return best


## Add the missing link next to `anchor` and wire it: "battery" (a library
## bank at the controller's voltage, on its battery terminals) or
## "controller" (a generic MPPT, the battery or panels wired to it). Returns
## the new item's id ("" = nothing added).
static func add_missing(model: GraphModel, chain: Dictionary, what: String) -> String:
	var c: Dictionary = chain.get("controller", {})
	var anchor := ""
	if not c.is_empty():
		anchor = str(c["id"])
	elif not (chain.get("battery", {}) as Dictionary).is_empty():
		anchor = str(chain["battery"]["id"])
	elif not (chain.get("arrays", []) as Array).is_empty():
		anchor = str(chain["arrays"][0]["id"])
	var at := model.get_item(anchor)
	if at.is_empty():
		return ""
	var scope := str(at.get("scope_id", "root"))
	var x := float(at.get("x", 0.0))
	var y := float(at.get("y", 0.0))
	match what:
		"battery":
			if c.is_empty():
				return ""
			var sv := float((at.get("specs", {}) as Dictionary).get("system_voltage", 48.0))
			var pre := battery_preset_for(sv if sv > 0.0 else 48.0)
			if pre.is_empty():
				return ""
			var it := _item_from(pre, scope, x, y + 180.0)
			model.add_item(it)
			_wire(model, anchor, "batteryPositive", str(it["id"]), "positive", "positive")
			_wire(model, anchor, "batteryNegative", str(it["id"]), "negative", "negative")
			return str(it["id"])
		"controller":
			var pre2: Dictionary = {}
			for p: Dictionary in ComponentPresets.CONTROLLERS:
				if str((p.get("specs", {}) as Dictionary).get("controller_preset", "")) == "generic_mppt_150_50":
					pre2 = p
			if pre2.is_empty():
				return ""
			var it2 := _item_from(pre2, scope, x, y + (180.0 if not (chain.get("arrays", []) as Array).is_empty() else -180.0))
			model.add_item(it2)
			var nid := str(it2["id"])
			var bat: Dictionary = chain.get("battery", {})
			if not bat.is_empty():
				_wire(model, nid, "batteryPositive", str(bat["id"]), "positive", "positive")
				_wire(model, nid, "batteryNegative", str(bat["id"]), "negative", "negative")
			for a: Dictionary in (chain.get("arrays", []) as Array).slice(0, 1):
				var ai := model.get_item(str(a["id"]))
				var hp := "positive" if str(ai.get("type", "")) == "compound" else "pvPositive"
				var hn := "negative" if str(ai.get("type", "")) == "compound" else "pvNegative"
				if str(ai.get("type", "")) == "panel":
					hp = "positive"
					hn = "negative"
				_wire(model, str(a["id"]), hp, nid, "pvPositive", "positive")
				_wire(model, str(a["id"]), hn, nid, "pvNegative", "negative")
			return nid
	return ""


static func _item_from(preset: Dictionary, scope: String, x: float, y: float) -> Dictionary:
	return {
		"type": str(preset.get("type", "")), "label": str(preset.get("label", "")),
		"x": x, "y": y, "width": float(preset.get("width", 120.0)), "height": float(preset.get("height", 90.0)),
		"scope_id": scope, "specs": (preset.get("specs", {}) as Dictionary).duplicate(true),
	}


static func _wire(model: GraphModel, a: String, ha: String, b: String, hb: String, pol: String) -> void:
	model.add_connection({"source_item_id": a, "source_handle_id": ha,
		"target_item_id": b, "target_handle_id": hb, "polarity": pol})
