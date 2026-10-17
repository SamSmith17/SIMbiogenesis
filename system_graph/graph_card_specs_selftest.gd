extends SceneTree

## What the freeform cards and port labels SAY (GraphCardSpecs, GraphPortLabels,
## GraphCard.layout). Offline; carries EXPECTED_CHECKS.
##   godot --headless --path . --script system_graph/graph_card_specs_selftest.gd

const EXPECTED_CHECKS := 44

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_port_labels()
	_test_panel()
	_test_battery()
	_test_controller()
	_test_one_frame_consistency()
	_test_load()
	_test_destroyed()
	_test_layout_lod()
	_test_wind_and_hydro()
	_test_machines()
	_test_tank()
	_test_groups()
	_test_media_zone()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("GRAPH CARD SPECS SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _test_port_labels() -> void:
	var mppt := {"id": "item_11", "type": "controller", "specs": {"name": "Trainer MPPT 150V 30A"}}
	_ok(GraphPortLabels.port_label(mppt, "pvNegative") == "Trainer MPPT 150V 30A · PV −",
		"controller PV − reads by name, never as item_11.pvNegative (%s)" % GraphPortLabels.port_label(mppt, "pvNegative"))
	var bare := {"id": "item_1", "type": "battery", "specs": {}}
	_ok(GraphPortLabels.port_label(bare, "positive") == "Battery · + terminal", "an unnamed battery falls back to its type")
	_ok(GraphPortLabels.port_name("res_in_0", "water") == ResourceKinds.display_name("water") + " in",
		"resource ports name their kind (%s)" % GraphPortLabels.port_name("res_in_0", "water"))
	_ok(not GraphPortLabels.port_name("some_odd_port").contains("_"), "unknown ids are humanised")


func _test_panel() -> void:
	var p := {"id": "p0", "type": "panel", "specs": {"name": "Trainer 300W", "wmp": 300.0, "voc": 40.0,
		"current_output_kw": 0.093}}
	var unwired := GraphCardSpecs.for_item(p, {"wired": {}})
	_ok(str(unwired["footer"]).begins_with("Not wired") and bool(unwired.get("dim", false)),
		"an unwired panel says so and dims")
	var wired := GraphCardSpecs.for_item(p, {"wired": {"p0|positive": true, "p0|negative": true}})
	_ok(wired["hero"] == "93 W" and wired["sub"] == "of 300 W peak", "panel hero = live watts of its peak (%s · %s)" % [wired["hero"], wired["sub"]])
	_ok(absf(float((wired["bar"] as Dictionary)["frac"]) - 0.31) < 0.01, "panel bar = live / peak")


func _test_battery() -> void:
	var b := {"id": "b", "type": "battery", "specs": {"name": "48V 100Ah LiFePO4", "soc": 0.72,
		"voltage": 51.2, "kwh": 5.12, "chemistry": "lfp"}}
	var charging := GraphCardSpecs.for_item(b, {"battery_w": 1060.0, "battery_count": 1})
	_ok(charging["title"] == "48V 100Ah LiFePO4", "a battery card carries its NAME (it had none)")
	_ok(charging["hero"] == "72%", "battery hero = SOC")
	_ok(str(charging["footer"]).begins_with("▲ 1.06 kW") and str(charging["footer"]).contains("full in"),
		"charging line with rate and time to full (%s)" % charging["footer"])
	var draining := GraphCardSpecs.for_item(b, {"battery_w": -500.0, "battery_count": 2})
	_ok(str(draining["footer"]).begins_with("▼ 250 W"), "the bank's flow is shared across batteries (%s)" % draining["footer"])


func _test_controller() -> void:
	var c := {"id": "c", "type": "controller", "specs": {"name": "Trainer PWM 12V 10A", "dc_delivered_w": 120.0,
		"dc_array_w": 300.0, "dc_bus_v": 12.0, "max_charge_amps": 10.0, "dc_clipped": true}}
	var s := GraphCardSpecs.for_item(c, {})
	_ok(s["chip"] == "PWM", "controller chip names the technology")
	_ok(s["hero"] == "120 W" and s["sub"] == "of 300 W offered", "delivered of offered (%s · %s)" % [s["hero"], s["sub"]])
	_ok(str(s["footer"]).begins_with("Clipping 180 W") and str(s["footer"]).contains("12 V × 10 A"),
		"the clipped share is a number on the card (%s)" % s["footer"])
	_ok(float((s["bar"] as Dictionary)["ghost"]) == 1.0, "the bar shows what was offered as a ghost band")


## The 2026-10-14 bootcamp report: after a run, battery full at noon, six
## panel cards said 3.33 W, the controller 221 W "all the array offers", the
## battery and the dashboard 100 W. One frame, one story: the panels are what
## the controller delivered, the controller says why it takes less than it is
## offered, and delivered − load is the battery's flow (zero when full).
func _test_one_frame_consistency() -> void:
	# Six 300 W panels offered 221 W; the battery is full and a 10 W light runs.
	var caps := [{"frac": 1.0, "limit_w": 1440.0}]
	_ok(absf(GraphDcElectrical.delivered_for_caps(0.2206, caps, 0.0) - 0.2206) < 1e-9,
		"under the current limit the controller passes everything")
	_ok(absf(GraphDcElectrical.delivered_for_caps(2.0, [{"frac": 0.5, "limit_w": 120.0},
		{"frac": 0.5, "limit_w": -1.0}], 0.0) - 1.12) < 1e-9,
		"caps are per controller and a function of raw (0.12 clipped + 1.0 free)")
	var split := GraphDcElectrical.split_actual(100.0, [120.0, 200.0], 0.0)
	_ok(absf(float(split[0]) - 37.5) < 1e-6 and absf(float(split[1]) - 62.5) < 1e-6,
		"a throttled total splits over the controllers by what each could pass (%s)" % str(split))
	var delivered_w := 10.0
	var c := {"id": "c", "type": "controller", "specs": {"name": "Trainer MPPT 150/30",
		"dc_delivered_w": delivered_w, "dc_array_w": 220.6, "dc_cap_w": 220.6, "dc_bus_v": 51.2,
		"max_charge_amps": 30.0, "dc_clipped": false, "dc_curtail": "battery_full"}}
	var cs := GraphCardSpecs.for_item(c, {})
	_ok(cs["hero"] == UiText.num(delivered_w, "W") and cs["sub"] == "of 221 W offered",
		"a curtailed controller shows delivered of offered (%s · %s)" % [cs["hero"], cs["sub"]])
	_ok(str(cs["footer"]).begins_with("Battery full · 211 W not needed"),
		"and says WHY it takes less (%s)" % cs["footer"])
	_ok((cs["bar"] as Dictionary)["ghost_color"] != GraphTheme.WARN,
		"a full battery is not a warning — only clipping is")
	var panel_w := 0.0
	var ps: Dictionary = {}
	for i in 6:
		var p := {"id": "p%d" % i, "type": "panel", "specs": {"name": "Trainer 300W", "wmp": 300.0, "voc": 40.0,
			"current_output_kw": delivered_w / 6.0 / 1000.0, "pv_offered_kw": 0.2206 / 6.0,
			"pv_curtail": "battery_full"}}
		panel_w += float(p["specs"]["current_output_kw"]) * 1000.0
		ps = GraphCardSpecs.for_item(p, {"wired": {"p%d|positive" % i: true, "p%d|negative" % i: true}})
	_ok(absf(panel_w - delivered_w) < 1e-6, "the panels sum to what the controller delivered")
	_ok(str(ps["footer"]).begins_with("Battery full") and str(ps["footer"]).contains("unused")
		and float((ps["bar"] as Dictionary)["ghost"]) > float((ps["bar"] as Dictionary)["frac"]),
		"a held-back panel shows the unused share as a ghost and says why (%s)" % ps["footer"])
	var b := {"id": "b", "type": "battery", "specs": {"name": "48V 100Ah LiFePO4", "soc": 1.0,
		"voltage": 51.2, "kwh": 5.12}}
	var bs := GraphCardSpecs.for_item(b, {"battery_w": delivered_w - 10.0, "battery_count": 1})
	_ok(bs["footer"] == "Full", "delivered − load = 0 on a full battery reads Full, not ▲ 100 W (%s)" % bs["footer"])


func _test_load() -> void:
	var on := GraphCardSpecs.for_item({"id": "l", "type": "appliance", "specs": {"name": "LED Light",
		"avg_watts": 10.0, "max_watts": 15.0, "current_state": "on"}}, {})
	_ok((on["pill"] as Dictionary)["text"] == "ON" and on["hero"] == "10 W", "a powered load: ON pill and its watts")
	var waiting := GraphCardSpecs.for_item({"id": "l", "type": "appliance", "specs": {"name": "LED Light",
		"avg_watts": 10.0, "current_state": "off", "requested_state": "on"}}, {})
	_ok(waiting["footer"] == "Waiting for AC power" and waiting["hero"] == "0 W",
		"a load that wants power but has none says so")


func _test_destroyed() -> void:
	var d := GraphCardSpecs.for_item({"id": "b", "type": "battery", "specs": {"destroyed": true,
		"destroyed_reason": "Short circuit"}}, {})
	_ok((d["alert"] as Dictionary)["action"] == "RESET" and (d["alert"] as Dictionary)["text"] == "Short circuit",
		"a destroyed battery offers RESET (the v2 battery card never did)")


func _test_layout_lod() -> void:
	_ok(GraphCard.lod_for(Rect2(0, 0, 160, 110), 1.0) == GraphCard.LOD_FULL, "a normal card at 1× is full detail")
	_ok(GraphCard.lod_for(Rect2(0, 0, 60, 40), 0.3) == GraphCard.LOD_COMPACT, "zoomed out: icon + hero only")
	var lay := GraphCard.layout(Rect2(0, 0, 160, 110), 1.0)
	_ok((lay["header"] as Rect2).end.y <= (lay["body"] as Rect2).position.y + 0.01
		and (lay["body"] as Rect2).end.y <= (lay["footer"] as Rect2).position.y + 0.01,
		"header, body and footer never overlap")


func _test_wind_and_hydro() -> void:
	var w := GraphCardSpecs.for_item({"id": "w", "type": "wind", "specs": {"name": "Rooftop 1 kW",
		"current_output_kw": 0.42, "rated_w": 1000.0, "rotor_diameter_m": 2.1, "hub_height_m": 10.0,
		"model_id": "vawt"}}, {})
	_ok(w["hero"] == "420 W" and w["sub"] == "of 1 kW max" and w.get("media", "") == "preview",
		"wind: live watts of its nameplate, its model in the media zone (%s · %s)" % [w["hero"], w["sub"]])
	var calm := GraphCardSpecs.for_item({"id": "w", "type": "wind", "specs": {"current_output_kw": 0.0}}, {})
	_ok(str(calm["footer"]).begins_with("Waiting for wind"), "a becalmed turbine says why it makes nothing")
	var h := GraphCardSpecs.for_item({"id": "h", "type": "processor", "specs": {"name": "PowerSpout",
		"role": "siphon_hydro", "live_power_w": 505.0, "max_power_w": 1600.0, "live_q_lps": 4.0,
		"turbine_kind": "powerspout_pelton"}}, {})
	_ok(h["chip"] == "HYDRO" and h["hero"] == "505 W" and str(h["footer"]).contains("505 W"),
		"a siphon_hydro machine reads as hydro, the 3D state ring's own words in the footer (%s)" % h["footer"])
	var h_off := GraphCardSpecs.for_item({"id": "h", "type": "processor", "specs": {"name": "PowerSpout",
		"role": "siphon_hydro", "live_power_w": 0.0, "max_power_w": 1600.0, HydroSource.SPEC_OFF: true,
		"turbine_kind": "powerspout_pelton"}}, {})
	_ok(h_off["chip"] == "OFF" and str(h_off["footer"]).begins_with("Off")
			and str(SiphonStateRing.state_for({HydroSource.SPEC_OFF: true}).get("state", "")) == "off",
		"a turbine switched off says so on its card and its 3D ring (%s)" % h_off["footer"])


func _test_machines() -> void:
	var stalled := GraphCardSpecs.for_item({"id": "m", "type": "processor", "batch_error": "missing_inputs",
		"specs": {"name": "Shredder", "watts": 1500.0, "inputs": [{"kind": "plastic_waste"}],
		"outputs": [{"kind": "biomass"}]}}, {"live_w": 0.0})
	_ok(str(stalled["footer"]).begins_with("Stalled") and str(stalled["sub"]).contains("→"),
		"a stalled machine says what is missing and what it turns into what (%s)" % stalled["sub"])
	var hab := GraphCardSpecs.for_item({"id": "hb", "type": "processor", "specs": {"name": "Camp",
		"role": "habitat", "pop_present": 12, "pop_morale": 0.8, "starved_kinds": ["water"]}}, {})
	_ok(hab["hero"] == "12 people" and str(hab["footer"]).begins_with("Short of"),
		"a habitat counts its people and names what it is short of (%s · %s)" % [hab["hero"], hab["footer"]])


func _test_tank() -> void:
	var t := GraphCardSpecs.for_item({"id": "t", "type": "resource", "specs": {"name": "Pond",
		"resource_kind": "water", "level": 0.5, "capacity_qty": 2947893.0, "capacity_unit": "L",
		"inflow_rate": 3.0, "outflow_rate": 1.0}}, {})
	_ok(bool(t.get("hub", false)) and t["hero"] == "1.47" and t["sub"] == "ML",
		"a tank is a round hub; the SI prefix moves onto the unit line (%s / %s)" % [t["hero"], t["sub"]])
	_ok(str(t["footer"]) == "+2 L/h" and absf(float((t["fill"] as Dictionary)["frac"]) - 0.5) < 0.001,
		"net flow and the level fill (%s)" % t["footer"])


func _test_groups() -> void:
	var arr := GraphCardSpecs.for_item({"id": "a", "type": "compound", "specs": {"compound_kind": "array",
		"array_panel_units": 18, "array_topology": "3S x 6P", "array_equiv_wmp": 5400.0}}, {})
	_ok(arr["chip"] == "3S×6P" and arr.get("media", "") == "array" and arr["footer"] == "18 panels",
		"an array group: topology chip, the panel grid, the count (%s · %s)" % [arr["chip"], arr["footer"]])
	var bank := GraphCardSpecs.for_item({"id": "bk", "type": "compound", "specs": {"compound_kind": "battery_bank",
		"child_count": 4}}, {"agg_soc": 0.64})
	_ok(bank["hero"] == "64%" and bank["sub"] == "4 batteries", "a bank shows the bank's SOC, not fake cells")
	var camp := GraphCardSpecs.for_item({"id": "cp", "type": "compound", "specs": {"camp_lot_id": "A1",
		"camp_headcount": 24, "camp_present": 20, "camp_morale": 0.8, "camp_open": ["water", "blackwater"]}}, {})
	_ok(camp["hero"] == "20 people" and str(camp["footer"]).contains("blackwater out"),
		"a camp: who is there, and the loops it has not closed (%s)" % camp["footer"])
	var grp := GraphCardSpecs.for_item({"id": "g", "type": "compound", "specs": {"name": "Pump house",
		"child_count": 5, "port_in_count": 2, "port_out_count": 1}}, {})
	_ok(grp["title"] == "Pump house" and grp.get("media", "") == "miniature" and grp["hero"] == "5 nodes",
		"a generic group keeps its miniature and says how much is inside")
	var ld := GraphCardSpecs.for_item({"id": "lg", "type": "compound", "specs": {"compound_kind": "load_group",
		"child_count": 3}}, {"live_w": 240.0})
	_ok(ld["hero"] == "240 W" and ld["sub"] == "3 loads grouped", "a load group sums its draw")


func _test_media_zone() -> void:
	var rect := Rect2(0, 0, 180, 170)
	var lay := GraphCard.layout(rect, 1.0)
	var spec := {"title": "Turbine", "hero": "505 W", "sub": "of 1.6 kW max", "footer": "RUNNING",
		"media": "preview"}
	var split := GraphCard.media_split(lay["body"], 1.0, spec, GraphCard.LOD_FULL)
	var mr: Rect2 = split.get("media", Rect2())
	var hr: Rect2 = split.get("hero", Rect2())
	_ok(mr.size.y >= 22.0 and mr.position.y >= (lay["header"] as Rect2).end.y
		and hr.position.y >= mr.end.y and hr.end.y <= (lay["footer"] as Rect2).position.y + 0.01,
		"media zone, then the hero, between the header and the footer (%s / %s)" % [str(mr), str(hr)])
