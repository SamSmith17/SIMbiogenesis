class_name GraphCardSpecs
extends RefCounted

## What each freeform card SAYS (GraphCard draws it). Pure: node specs + a
## small live context → a card spec dict, so the selftest can pin every line a
## player reads. Types that keep their own renderer (the planetary inputs,
## catchments, plants, breakers) return {}.
##
## ctx: {
##   wired: {"<item_id>|<handle_id>": true} — ports with a wire;
##   battery_w: float — the bank's net flow, + charging / − discharging;
##   battery_count: int — batteries sharing that flow;
##   live_w: float — THIS item's live draw (machines, load groups), when known;
##   agg_soc: float — a battery-bank group's energy-weighted SOC (< 0 = unknown);
##   selected: bool,
## }
##
## `media` (wind / hydro / machines / groups): which picture the CANVAS draws in
## the card's media zone — "preview" (the GLB thumbnail), "miniature" (a
## group's child canvas), "banner" (a super-node's subject), "array" (the panel
## grid). GraphCard reserves the zone and returns its rect; the hero still
## shows below it, so a card without its picture loaded reads the same.
## `hub: true` (resource tanks): drawn round by GraphCard.draw_hub, so the hub
## ports keep their places on the circle.

const TYPES := ["panel", "battery", "smartbattery", "controller", "appliance", "acload",
	"wind", "hydro", "processor", "resource", "compound"]


static func handles(itype: String) -> bool:
	return itype in TYPES


static func for_item(item: Dictionary, ctx: Dictionary) -> Dictionary:
	var itype := str(item.get("type", ""))
	if not handles(itype):
		return {}
	var specs: Dictionary = item.get("specs", {}) if item.get("specs", {}) is Dictionary else {}
	var spec := {
		"accent": GraphTheme.accent(itype),
		"icon": GraphTheme.icon(itype),
		"title": GraphPortLabels.node_name(item),
		"chip": GraphTheme.chip(itype),
		"selected": bool(ctx.get("selected", false)),
	}
	if bool(specs.get("destroyed", false)):
		spec["alert"] = {"title": "Destroyed", "text": str(specs.get("destroyed_reason",
			"Electrical fault")), "action": "RESET"}
		spec["footer"] = ""
		return spec
	match itype:
		"panel":
			_panel(spec, item, specs, ctx)
		"battery", "smartbattery":
			_battery(spec, specs, ctx)
		"controller":
			_controller(spec, specs)
		"appliance", "acload":
			_load(spec, specs)
		"wind":
			_wind(spec, specs)
		"hydro":
			_hydro(spec, specs)
		"processor":
			_machine(spec, item, specs, ctx)
		"resource":
			_tank(spec, item, specs)
		"compound":
			_group(spec, specs, ctx)
	return spec


static func _wired(ctx: Dictionary, iid: String, handle: String) -> bool:
	return (ctx.get("wired", {}) as Dictionary).has(iid + "|" + handle)


static func _panel(spec: Dictionary, item: Dictionary, specs: Dictionary, ctx: Dictionary) -> void:
	var iid := str(item.get("id", ""))
	var rated := float(specs.get("wmp", specs.get("watts", 0.0)))
	var live := maxf(0.0, float(specs.get("current_output_kw", 0.0)) * 1000.0)
	# What the sun offers this panel right now; live is what it is actually
	# delivering (a full battery backs the whole array off).
	var offered := maxf(live, float(specs.get("pv_offered_kw", 0.0)) * 1000.0)
	var wired := _wired(ctx, iid, "positive") and _wired(ctx, iid, "negative")
	spec["hero"] = UiText.num(live, "W")
	spec["sub"] = "of %s peak" % UiText.num(rated, "W") if rated > 0.0 else ""
	var held := offered - live
	spec["bar"] = {"frac": live / rated if rated > 0.0 else 0.0, "color": GraphTheme.accent("panel"),
		"ghost": offered / rated if rated > 0.0 and held > 1.0 else 0.0,
		"ghost_color": GraphTheme.TEXT_MUTED}
	var voc := float(specs.get("voc", 0.0))
	var why := str(specs.get("pv_curtail", ""))
	if not wired:
		spec["footer"] = "Not wired — connect + and −"
		spec["footer_color"] = GraphTheme.TEXT_MUTED
		spec["dim"] = true
	elif held > 1.0 and not why.is_empty():
		spec["footer"] = "%s · %s unused" % [_curtail_reason(why), UiText.num(held, "W")]
		spec["footer_color"] = GraphTheme.WARN if why == "clipping" else GraphTheme.TEXT_DIM
	elif live <= 0.5:
		spec["footer"] = "No sun on the panel" if voc > 0.0 else "Idle"
	else:
		spec["footer"] = "%s open-circuit" % UiText.num(voc, "V") if voc > 0.0 else "Generating"


## The player-facing reason an array is delivering less than the sun offers.
static func _curtail_reason(why: String) -> String:
	match why:
		"battery_full":
			return "Battery full"
		"battery_topping":
			return "Battery topping off"
		"clipping":
			return "Controller at its limit"
		_:
			return "Held back"


static func _battery(spec: Dictionary, specs: Dictionary, ctx: Dictionary) -> void:
	var soc := clampf(float(specs.get("soc", 0.5)), 0.0, 1.0)
	var v := float(specs.get("voltage", 0.0))
	var kwh := float(specs.get("kwh", 0.0))
	if kwh <= 0.0 and float(specs.get("ah", 0.0)) > 0.0 and v > 0.0:
		kwh = float(specs.get("ah", 0.0)) * v / 1000.0
	var chem := BatteryChemistry.label(BatteryChemistry.infer(specs))
	if not chem.is_empty():
		spec["chip"] = chem
	spec["hero"] = UiText.pct(soc)
	var bits: PackedStringArray = PackedStringArray()
	if v > 0.0:
		bits.append(UiText.num(v, "V"))
	if kwh > 0.0:
		bits.append(UiText.num(kwh * 1000.0, "Wh"))
	spec["sub"] = " · ".join(bits)
	var low := soc <= 0.2
	spec["fill"] = {"frac": soc, "color": GraphTheme.WARN if low else GraphTheme.OK}
	var n := maxi(1, int(ctx.get("battery_count", 1)))
	var w := float(ctx.get("battery_w", 0.0)) / float(n)
	if absf(w) < 5.0:
		spec["footer"] = "Full" if soc >= 0.995 else "Idle"
	elif w > 0.0:
		var to_full := (1.0 - soc) * kwh * 1000.0 / w if kwh > 0.0 else 0.0
		spec["footer"] = "▲ %s%s" % [UiText.num(w, "W"),
			(" · full in " + UiText.duration(to_full)) if to_full > 0.0 and soc < 0.995 else ""]
		spec["footer_color"] = GraphTheme.OK
	else:
		var to_empty := soc * kwh * 1000.0 / -w if kwh > 0.0 else 0.0
		spec["footer"] = "▼ %s%s" % [UiText.num(-w, "W"),
			(" · empty in " + UiText.duration(to_empty)) if to_empty > 0.0 else ""]
		spec["footer_color"] = GraphTheme.WARN if low else GraphTheme.TEXT_DIM


static func _controller(spec: Dictionary, specs: Dictionary) -> void:
	var name := str(specs.get("name", "")).to_lower()
	spec["chip"] = "MPPT" if name.contains("mppt") else ("PWM" if name.contains("pwm") else "CONTROLLER")
	var delivered := maxf(0.0, float(specs.get("dc_delivered_w", 0.0)))
	var offered := maxf(delivered, float(specs.get("dc_array_w", 0.0)))
	# What the current limit lets through (offered when not clipping); older
	# saves have no dc_cap_w — then delivered is the cap.
	var cap := clampf(float(specs.get("dc_cap_w", delivered)), delivered, offered)
	var bus := float(specs.get("dc_bus_v", 0.0))
	var amps := float(specs.get("max_charge_amps", 0.0))
	var why := str(specs.get("dc_curtail", ""))
	spec["hero"] = UiText.num(delivered, "W")
	if offered > delivered + 1.0:
		spec["sub"] = "of %s offered" % UiText.num(offered, "W")
	elif offered > 0.0:
		spec["sub"] = "all the array offers"
	else:
		spec["sub"] = "no array power"
	var scale := maxf(offered, 1.0)
	spec["bar"] = {"frac": delivered / scale, "color": GraphTheme.accent("controller"),
		"ghost": offered / scale if offered > delivered + 1.0 else 0.0,
		"ghost_color": GraphTheme.WARN if cap < offered - 1.0 else GraphTheme.TEXT_MUTED}
	if not why.is_empty() and cap > delivered + 1.0:
		# Taking less than it could: the battery is full, so the array is backed
		# off to what the loads use. Not a fault — the sun is simply not needed.
		spec["footer"] = "%s · %s not needed" % [_curtail_reason(why), UiText.num(cap - delivered, "W")]
		if bool(specs.get("dc_clipped", false)) and cap < offered - 1.0:
			spec["footer"] += " · %s cap" % UiText.num(cap, "W")
		spec["footer_color"] = GraphTheme.TEXT_DIM
	elif bool(specs.get("dc_clipped", false)) and offered > delivered + 1.0:
		spec["footer"] = "Clipping %s · %s × %s cap" % [UiText.num(offered - delivered, "W"),
			UiText.num(bus, "V"), UiText.num(amps, "A")]
		spec["footer_color"] = GraphTheme.WARN
	elif bus > 0.0:
		spec["footer"] = "%s battery bus%s" % [UiText.num(bus, "V"),
			(" · " + UiText.num(amps, "A") + " max") if amps > 0.0 else ""]
	else:
		spec["footer"] = "Wire a battery to the bottom terminals"
		spec["footer_color"] = GraphTheme.TEXT_MUTED


static func _load(spec: Dictionary, specs: Dictionary) -> void:
	var state := str(specs.get("current_state", "")).to_lower()
	var on := state == "on" or (state.is_empty() and str(specs.get("requested_state", "on")).to_lower() != "off")
	var w := float(specs.get("avg_watts", specs.get("watts", specs.get("max_watts", 0.0))))
	spec["hero"] = UiText.num(w if on else 0.0, "W")
	var rated := float(specs.get("max_watts", 0.0))
	spec["sub"] = ("up to " + UiText.num(rated, "W")) if rated > w + 0.5 else ""
	spec["pill"] = {"text": "ON" if on else "OFF", "color": GraphTheme.OK if on else GraphTheme.TEXT_MUTED}
	if on:
		spec["footer"] = "Powered"
	elif str(specs.get("requested_state", "")).to_lower() == "on":
		spec["footer"] = "Waiting for AC power"
		spec["footer_color"] = GraphTheme.WARN
	else:
		spec["footer"] = "Switched off"
		spec["dim"] = true


static func _has_model(specs: Dictionary) -> bool:
	return not str(specs.get("model_id", "")).is_empty() or not str(specs.get("icon_path", "")).is_empty()


## Live watts as the hero, against the nameplate.
static func _generator_hero(spec: Dictionary, live_w: float, rated_w: float, accent_type: String) -> void:
	spec["hero"] = UiText.num(maxf(0.0, live_w), "W")
	spec["sub"] = ("of %s max" % UiText.num(rated_w, "W")) if rated_w > 0.0 else ""
	spec["bar"] = {"frac": clampf(live_w / rated_w, 0.0, 1.0) if rated_w > 0.0 else 0.0,
		"color": GraphTheme.accent(accent_type)}


static func _wind(spec: Dictionary, specs: Dictionary) -> void:
	var w := float(specs.get("current_output_kw", 0.0)) * 1000.0
	_generator_hero(spec, w, float(specs.get("rated_w", 0.0)), "wind")
	var rotor := "⌀ %s rotor · hub %s" % [UiText.num(float(specs.get("rotor_diameter_m", 2.1)), "m"),
		UiText.num(float(specs.get("hub_height_m", 10.0)), "m")]
	if w > 0.5:
		spec["footer"] = rotor
	else:
		spec["footer"] = "Waiting for wind · " + rotor
		spec["footer_color"] = GraphTheme.TEXT_MUTED
	if _has_model(specs):
		spec["media"] = "preview"


## Legacy `hydro` estimator items and `siphon_hydro` machines read the same.
static func _hydro(spec: Dictionary, specs: Dictionary) -> void:
	spec["accent"] = GraphTheme.accent("hydro")
	spec["icon"] = GraphTheme.icon("hydro")
	spec["chip"] = GraphTheme.chip("hydro")
	var siphon := str(specs.get("role", "")) == "siphon_hydro"
	var w := float(specs.get("live_power_w", float(specs.get("current_output_kw", 0.0)) * 1000.0)) \
		if siphon else float(specs.get("current_output_kw", 0.0)) * 1000.0
	var rated := float(specs.get("max_power_w", specs.get("rated_w", 0.0)))
	_generator_hero(spec, w, rated, "hydro")
	if siphon:
		var st: Dictionary = SiphonStateRing.state_for(specs)
		spec["footer"] = str(st.get("text", ""))
		spec["footer_color"] = SiphonStateRing.color_for(str(st.get("state", "")))
		if str(st.get("state", "")) == "fault":
			spec["hero_color"] = GraphTheme.ERROR
		elif str(st.get("state", "")) == "off":
			spec["chip"] = "OFF"
			spec["footer"] = "Off — double-click to start"
	else:
		spec["footer"] = "head %s · %s" % [UiText.num(float(specs.get("gross_head_m", 25.0)), "m"),
			"%s L/s" % UiText.num(float(specs.get("design_flow_lps", 3.0)), "")]
	if _has_model(specs):
		spec["media"] = "preview"


static func _machine(spec: Dictionary, item: Dictionary, specs: Dictionary, ctx: Dictionary) -> void:
	var role := str(specs.get("role", ""))
	if role == "siphon_hydro":
		_hydro(spec, specs)
		return
	if _has_model(specs):
		spec["media"] = "preview"
	if role == "habitat":
		spec["icon"] = "users"
		spec["chip"] = "HABITAT"
		spec["accent"] = Color(0.62, 0.74, 0.44)
		var n := int(specs.get("pop_present", specs.get("occupants", 0)))
		spec["hero"] = UiText.count(n, "person", "people")
		if specs.has("pop_morale") and n > 0:
			var m := float(specs.get("pop_morale", 0.5))
			spec["sub"] = NpcMorale.label(m)
			spec["sub_color"] = NpcMorale.color(m)
		var starved: Array = specs.get("starved_kinds", []) as Array
		if not starved.is_empty():
			spec["footer"] = "Short of " + ResourceKinds.display_name(str(starved[0])).to_lower()
			spec["footer_color"] = GraphTheme.ERROR
		else:
			spec["footer"] = "Every need met" if n > 0 else "Nobody here"
		return
	if role == "csp_concentrator":
		spec["chip"] = "CSP"
		spec["icon"] = "sun"
		spec["accent"] = GraphTheme.accent("panel")
		var kw := float(specs.get("thermal_output_kw", 0.0))
		spec["hero"] = UiText.num(kw * 1000.0, "W")
		spec["sub"] = "%s/h steam" % UiText.num(float(specs.get("steam_kg_h", 0.0)), "kg")
		spec["footer"] = "%s DNI" % UiText.num(float(specs.get("dni_wm2", 0.0)), "W/m²") if kw > 0.0 \
			else "No direct sun on the trough"
		if kw <= 0.0:
			spec["footer_color"] = GraphTheme.TEXT_MUTED
		return
	# A machine: what it draws, what it turns into what, and whether it runs.
	var rated := float(specs.get("watts", specs.get("max_watts", 0.0)))
	var live := float(ctx.get("live_w", -1.0))
	var running := str(specs.get("node_state", "")) == GraphNodeState.RUNNING or live > 0.5
	spec["hero"] = UiText.num(live if live >= 0.0 else (rated if running else 0.0), "W")
	var ins: PackedStringArray = PackedStringArray()
	for inp: Variant in specs.get("inputs", []) as Array:
		if inp is Dictionary:
			ins.append(ResourceKinds.display_name(str((inp as Dictionary).get("kind", ""))))
	var outs: PackedStringArray = PackedStringArray()
	for outp: Variant in specs.get("outputs", []) as Array:
		if outp is Dictionary:
			outs.append(ResourceKinds.display_name(str((outp as Dictionary).get("kind", ""))))
	if not ins.is_empty() or not outs.is_empty():
		spec["sub"] = "%s → %s" % [", ".join(ins) if not ins.is_empty() else "—",
			", ".join(outs) if not outs.is_empty() else "—"]
	elif rated > 0.0:
		spec["sub"] = "up to " + UiText.num(rated, "W")
	if str(item.get("batch_error", "")) == "missing_inputs":
		spec["footer"] = "Stalled — missing inputs"
		spec["footer_color"] = GraphTheme.ERROR
		spec["hero_color"] = GraphTheme.ERROR
	elif running:
		spec["footer"] = "Running"
		spec["footer_color"] = GraphTheme.OK
	else:
		var st := str(specs.get("node_state", ""))
		spec["footer"] = "Ready" if st == GraphNodeState.READY else "Idle"
		spec["footer_color"] = GraphTheme.TEXT_MUTED


## A round tank: the quantity in its own unit, the net flow, the level fill.
static func _tank(spec: Dictionary, item: Dictionary, specs: Dictionary) -> void:
	spec["hub"] = true
	spec["chip"] = ""
	var kind := str(specs.get("resource_kind", "water"))
	var accent := ResourceKinds.wire_color(kind)
	if bool(item.get("is_ghost", false)):
		accent = Color(accent.r, accent.g, accent.b, 0.42)
	var raw := float(specs.get("level", 0.5))
	var deficit := bool(specs.get("allow_negative", false)) and raw < 0.0
	if deficit:
		accent = UITheme.C_WARN
	spec["accent"] = accent
	spec["title"] = str(specs.get("name", ResourceKinds.display_name(kind)))
	var level := clampf(raw, 0.0, 1.0)
	var cap_qty := float(specs.get("capacity_qty", 100.0))
	var unit := str(specs.get("capacity_unit", ""))
	if deficit:
		spec["hero"] = "−" + UiText.num(float(specs.get("deficit_qty", -raw * cap_qty)), "")
		spec["sub"] = "⚠ " + unit
		spec["hero_color"] = UITheme.C_WARN
	elif bool(specs.get("unlimited_capacity", false)):
		spec["hero"] = "∞"
		spec["sub"] = unit
	else:
		# Three significant figures, the SI prefix moving onto the unit line:
		# 1473946.5 L reads "1.47" over "ML".
		var nice := UiText.num(level * cap_qty, unit)
		var cut := nice.rfind(" ")
		if cut > 0:
			spec["hero"] = nice.left(cut)
			spec["sub"] = nice.substr(cut + 1)
		else:
			spec["hero"] = nice
			spec["sub"] = ""
	spec["fill"] = {"frac": level, "color": Color(accent.r, accent.g, accent.b,
		0.35 if bool(item.get("is_ghost", false)) else 0.88)}
	var net := float(specs.get("inflow_rate", 0.0)) - float(specs.get("outflow_rate", 0.0))
	if absf(net) > 0.001:
		spec["footer"] = "%s%s/h" % ["+" if net > 0.0 else "−", UiText.num(absf(net), unit)]
		spec["footer_color"] = Color(0.6, 1.0, 0.6) if net > 0.0 else Color(1.0, 0.7, 0.7)
	else:
		spec["footer"] = ""


## Super-nodes: arrays, battery banks, load groups, camps, and generic groups.
static func _group(spec: Dictionary, specs: Dictionary, ctx: Dictionary) -> void:
	var kind := str(specs.get("compound_kind", ""))
	var children := int(specs.get("child_count", 0))
	if specs.has("camp_lot_id"):
		spec["icon"] = "tent"
		spec["chip"] = "CAMP"
		spec["accent"] = Color(0.94, 0.62, 0.36)
		var n := int(specs.get("camp_headcount", 0))
		var present := int(specs.get("camp_present", n))
		spec["hero"] = UiText.count(present, "person", "people")
		var bits: PackedStringArray = PackedStringArray()
		var morale := float(specs.get("camp_morale", -1.0))
		if present != n:
			bits.append("of %d" % n)
		if morale >= 0.0:
			bits.append(NpcMorale.label(morale))
			spec["hero_color"] = NpcMorale.color(morale)
		if specs.has("camp_soc"):
			bits.append("⚡ " + UiText.pct(float(specs.get("camp_soc", 0.0))))
		spec["sub"] = " · ".join(bits)
		var open: Array = specs.get("camp_open", []) as Array
		if open.is_empty():
			spec["footer"] = "All loops closed"
			spec["footer_color"] = GraphTheme.OK
		else:
			var names: PackedStringArray = PackedStringArray()
			for k: Variant in open:
				var ks := str(k)
				var out := ks == "greywater" or ks == "blackwater" or ks == "food_waste"
				names.append("%s %s" % [ResourceKinds.display_name(ks).to_lower(), "out" if out else "in"])
			spec["footer"] = "⚠ " + ", ".join(names)
			spec["footer_color"] = GraphTheme.WARN
		return
	if kind == "array":
		spec["icon"] = "sun"
		spec["accent"] = GraphTheme.accent("panel")
		var units := int(specs.get("array_panel_units", children))
		spec["title"] = str(specs.get("name", "")) if not str(specs.get("name", "")).is_empty() \
			else "Solar array"
		spec["chip"] = str(specs.get("array_topology", "ARRAY")).replace(" x ", "×").replace(" X ", "×")
		var peak := float(specs.get("array_equiv_wmp", 0.0))
		var live := float(specs.get("current_output_kw", -1.0)) * 1000.0
		if live >= 0.0:
			_generator_hero(spec, live, peak, "panel")
		else:
			spec["hero"] = UiText.num(peak, "W")
			spec["sub"] = "peak"
		spec["footer"] = UiText.count(units, "panel")
		if bool(specs.get("array_stowed", false)):
			spec["footer"] = "Stowed · " + str(spec["footer"])
			spec["dim"] = true
		spec["media"] = "array"
		return
	if kind == "load_group":
		spec["icon"] = "plug"
		spec["chip"] = "LOADS"
		spec["accent"] = GraphTheme.accent("acload")
		spec["hero"] = UiText.num(maxf(0.0, float(ctx.get("live_w", specs.get("avg_watts", 0.0)))), "W")
		spec["sub"] = UiText.count(children, "load") + " grouped"
		spec["footer"] = "Enter to see each load"
		spec["footer_color"] = GraphTheme.TEXT_MUTED
		return
	var soc := float(ctx.get("agg_soc", -1.0))
	if kind == "battery_bank" or bool(specs.get("display_as_battery", false)) \
			or str(specs.get("definition_id", "")).to_lower().contains("battery_bank"):
		spec["icon"] = "battery"
		spec["chip"] = "BANK"
		spec["accent"] = GraphTheme.accent("battery")
		if soc < 0.0:
			soc = clampf(float(specs.get("soc", 0.5)), 0.0, 1.0)
		spec["hero"] = UiText.pct(soc)
		spec["sub"] = UiText.count(children, "battery", "batteries")
		spec["fill"] = {"frac": soc, "color": GraphTheme.WARN if soc <= 0.2 else GraphTheme.OK}
		spec["footer"] = "Enter to see each battery"
		spec["footer_color"] = GraphTheme.TEXT_MUTED
		return
	# A generic group / component instance.
	spec["chip"] = "COMPONENT" if not str(specs.get("definition_id", "")).is_empty() else "GROUP"
	if bool(specs.get("node_banner", false)) and not str(specs.get("model_id", "")).is_empty():
		spec["media"] = "banner"
		spec["hero"] = ""
	else:
		spec["media"] = "miniature"
		spec["hero"] = UiText.count(children, "node")
	spec["footer"] = "%d in · %d out" % [int(specs.get("port_in_count", 0)), int(specs.get("port_out_count", 0))]
	spec["footer_color"] = GraphTheme.TEXT_MUTED
	if bool(specs.get("array_stowed", false)):
		spec["footer"] = "Stowed · " + str(spec["footer"])
		spec["dim"] = true
