extends SceneTree

## ScadaTags + ScadaHistorian selftest (offline): the tag ids are the keys
## automations already read; a graph gives tank / node / wire / greenhouse
## tags; boards and Home Assistant states become tags; the registry searches
## and prints; the context is {numeric_values, device_states} with name
## aliases; the historian keeps change-only samples on the sim clock, drops
## the future on a scrub back, leaves gaps for unavailable readings, bins
## exactly, caps unwatched tags and round-trips its dict.
##
## Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script core/scada/scada_tags_selftest.gd

const EXPECTED_CHECKS := 41

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_graph_tags()
	_test_other_sources()
	_test_registry_and_context()
	_test_historian()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("SCADA TAGS SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _model() -> GraphModel:
	var m := GraphModel.new()
	m.items.append({"id": "t1", "type": "resource", "specs": {"name": "Rain Tank", "resource_kind": "water",
			"level": 0.62, "capacity_qty": 1000.0, "capacity_unit": "L"}})
	m.items.append({"id": "t2", "type": "resource", "specs": {"name": "Pond", "level": 0.4,
			"unlimited_capacity": true, "overflowing": true}})
	m.items.append({"id": "p1", "type": "processor", "specs": {"name": "Water Pump",
			"requested_state": "on", "node_state": "blocked"}})
	m.items.append({"id": "a1", "type": "appliance", "specs": {"name": "Fridge", "current_state": "off"}})
	m.items.append({"id": "g1", "type": "compound", "specs": {"name": "Dome 1", "greenhouse_system": true,
			"gh_t_air": 27.5, "gh_rh": 61.0, "gh_frost": false}})
	m.items.append({"id": "b1", "type": "battery", "specs": {"name": "Bank"}})
	m.connections.append({"id": "c1", "resource_type": "water", "flow_rate": 12.5})
	m.connections.append({"id": "c2", "polarity": "positive"})
	return m


func _by_id(tags: Array) -> Dictionary:
	var d := {}
	for t in tags:
		d[t["id"]] = t
	return d


func _test_graph_tags() -> void:
	var tags := _by_id(ScadaTags.graph_tags(_model()))
	_ok(tags.has("tank.t1.level") and absf(float(tags["tank.t1.level"]["value"]) - 62.0) < 1e-4,
		"a tank's level is a percent tag under the automation key")
	_ok(tags.has("tank.t1.stock") and absf(float(tags["tank.t1.stock"]["value"]) - 620.0) < 1e-3
		and str(tags["tank.t1.stock"]["unit"]) == "L", "a tank's amount in its own unit")
	_ok(not tags.has("tank.t2.stock"), "an unlimited store has no amount tag")
	_ok(str(tags["tank.t2"]["text"]) == "overflow" and float(tags["tank.t2"]["value"]) == 1.0,
		"overflow is a binary tag with its word")
	_ok(str(tags["tank.t1.level"]["alias"]) == "tank.rain_tank.level", "the name alias is lower_snake_case")
	_ok(str(tags["node.p1"]["kind"]) == ScadaTags.KIND_SWITCH and bool(tags["node.p1"]["writable"]),
		"a machine's run switch is writable")
	_ok(str(tags["node.p1"]["text"]) == "blocked" and float(tags["node.p1"]["value"]) == 1.0,
		"a blocked machine reads blocked while switched on")
	_ok(str(tags["node.a1"]["text"]) == "off", "an appliance off")
	_ok(not tags.has("node.b1"), "a battery has no run switch")
	_ok(absf(float(tags["greenhouse.g1.temp"]["value"]) - 27.5) < 1e-4
		and str(tags["greenhouse.g1.frost"]["text"]) == "off", "greenhouse air and frost")
	_ok(tags.has("wire.c1.flow") and not tags.has("wire.c2.flow"), "resource wires carry a flow tag, power wires none")
	_ok(str(tags["tank.t1.level"]["group"]) == "Rain Tank" and str(tags["tank.t1.level"]["item"]) == "t1",
		"tags carry their node's name and id")


func _test_other_sources() -> void:
	var site := _by_id(ScadaTags.site_tags({"battery_pct": 80.0, "solar_w": 1500.0}))
	_ok(site.has("sensor.battery_level") and site.has("sensor.solar_power") and not site.has("sensor.load_power"),
		"site power tags only for what is known")
	var ents := [
		{"entity_id": "sensor.shed_temperature", "name": "Temperature", "unit": "°C"},
		{"entity_id": "binary_sensor.shed_float", "name": "Float", "unit": ""},
		{"entity_id": "switch.shed_relay", "name": "Relay", "unit": ""},
		{"entity_id": "sensor.shed_dead", "name": "Dead", "unit": ""},
	]
	var latest := {
		"sensor.shed_temperature": {"value": 21.4, "available": true},
		"binary_sensor.shed_float": {"value": 0.9, "available": true},
		"switch.shed_relay": {"value": 0.0, "available": true},
		"sensor.shed_dead": {"value": NAN, "available": false},
	}
	var esp := _by_id(ScadaTags.esp_tags("Shed", ents, latest))
	_ok(absf(float(esp["sensor.shed_temperature"]["value"]) - 21.4) < 1e-4
		and str(esp["sensor.shed_temperature"]["source"]) == ScadaTags.SOURCE_ESP, "a board's sensor under its entity id")
	_ok(str(esp["binary_sensor.shed_float"]["kind"]) == ScadaTags.KIND_BINARY
		and float(esp["binary_sensor.shed_float"]["value"]) == 1.0, "a binary sensor is 0 or 1")
	_ok(str(esp["switch.shed_relay"]["kind"]) == ScadaTags.KIND_SWITCH and not bool(esp["switch.shed_relay"]["writable"]),
		"a board's relay is a switch that only follows (for now)")
	_ok(not bool(esp["sensor.shed_dead"]["available"]) and ScadaTags.display(esp["sensor.shed_dead"]) == "unavailable",
		"an unpowered board's reading is unavailable")
	var tc := _by_id(ScadaTags.tc_tags("Reactor", [{"key": "sensor.reactor_charge_max", "label": "Charge", "unit": "°C", "value": 450.0}],
			[{"key": "switch.reactor_element_1", "label": "Element 1", "kind": "switch", "value": 1.0},
			{"key": "number.reactor_cooling", "label": "Cooling", "kind": "number", "unit": "L/min", "value": 2.0}]))
	_ok(str(tc["number.reactor_cooling"]["kind"]) == ScadaTags.KIND_NUMBER and bool(tc["switch.reactor_element_1"]["writable"])
		and not bool(tc["sensor.reactor_charge_max"]["writable"]), "process sensors, switches and numbers")
	var ha := _by_id(ScadaTags.ha_tags({"sensor.x": "12.5", "switch.y": "on", "sensor.z": "unknown"}))
	_ok(float(ha["sensor.x"]["value"]) == 12.5 and float(ha["switch.y"]["value"]) == 1.0 and not ha.has("sensor.z"),
		"Home Assistant numbers and on / off states; text states are left out")


func _test_registry_and_context() -> void:
	var book := ScadaTags.new()
	var tags := ScadaTags.graph_tags(_model())
	book.set_all(tags)
	book.add_all([ScadaTags.make("tank.t1.level", "Other", "%", ScadaTags.KIND_SENSOR, 5.0)])
	_ok(absf(book.value("tank.t1.level") - 62.0) < 1e-4, "the first tag of an id wins")
	_ok(is_nan(book.value("nope")), "an unknown tag reads NAN")
	var hits := book.search("rain level")
	_ok(hits.size() == 1 and str(hits[0]["id"]) == "tank.t1.level", "search matches every word")
	_ok(book.search("", true).size() == 2, "only the two switches are writable")
	_ok(ScadaTags.display(book.tag("tank.t1.level")) == "62 %", "a number prints with its unit")
	_ok(ScadaTags.display(book.tag("node.a1")) == "off", "a switch prints its word")
	var ctx := ScadaTags.context(tags)
	var num: Dictionary = ctx["numeric_values"]
	var st: Dictionary = ctx["device_states"]
	_ok(absf(float(num["tank.t1.level"]) - 62.0) < 1e-4 and absf(float(num["tank.rain_tank.level"]) - 62.0) < 1e-4,
		"the context carries the id and the name alias")
	_ok(str(st["node.p1"]) == "blocked" and str(st["node.water_pump"]) == "blocked" and str(st["tank.t2"]) == "overflow",
		"states are words")
	_ok(not num.has("node.p1") and not st.has("tank.t1.level"), "switches are states, sensors are numbers")


func _test_historian() -> void:
	var h := ScadaHistorian.new()
	for i in 10:
		h.add("a", 100.0 + i * 0.1, 5.0)
	_ok(h.size("a") == 1, "an unchanged value is recorded once")
	h.add("a", 101.5, 5.0)
	_ok(h.size("a") == 2, "and again after the keep-alive hour")
	h.add("a", 102.0, 9.0)
	_ok(absf(h.value_at("a", 101.9) - 5.0) < 1e-6 and absf(h.value_at("a", 102.5) - 9.0) < 1e-6,
		"a value holds until the next one")
	_ok(is_nan(h.value_at("a", 99.0)) and is_nan(h.value_at("a", 102.0 + ScadaHistorian.MAX_GAP_H + 1.0)),
		"nothing before the first sample or long after the last")
	var b := h.bins_exact("a", 1.0, 100, 4)
	var me: PackedFloat32Array = b["mean"]
	_ok(absf(me[0] - 5.0) < 1e-5 and absf(me[2] - 9.0) < 1e-5, "bins are the held values")
	# Unavailable is a gap.
	h.add("a", 103.0, NAN)
	h.add("a", 104.0, 3.0)
	_ok(is_nan(h.value_at("a", 103.5)) and absf(h.value_at("a", 104.2) - 3.0) < 1e-6, "an unavailable stretch reads NAN")
	var b2 := h.bins_exact("a", 0.5, 206, 4)
	var me2: PackedFloat32Array = b2["mean"]
	_ok(is_nan(me2[0]) and is_nan(me2[1]) and absf(me2[2] - 3.0) < 1e-5, "and bins as a gap")
	# Scrub back.
	var tags := [ScadaTags.make("x", "X", "", ScadaTags.KIND_SENSOR, 1.0)]
	var r := ScadaHistorian.new()
	r.record(tags, 10.0)
	tags[0]["value"] = 2.0
	r.record(tags, 11.0)
	tags[0]["value"] = 3.0
	r.record(tags, 12.0)
	tags[0]["value"] = 7.0
	r.record(tags, 10.5)
	_ok(r.size("x") == 2 and absf(r.value_at("x", 10.7) - 7.0) < 1e-6, "a scrub back drops what came after")
	var rng := r.range_of("x")
	_ok(absf(rng[0] - 10.0) < 1e-9 and absf(rng[1] - 10.5) < 1e-9, "the range is 64-bit hours")
	# Caps.
	var c := ScadaHistorian.new()
	c.watched["w"] = true
	for i in ScadaHistorian.MAX_SAMPLES_UNWATCHED + 400:
		c.add("u", float(i), float(i))
		c.add("w", float(i), float(i))
	_ok(c.size("u") <= ScadaHistorian.MAX_SAMPLES_UNWATCHED and c.size("w") == ScadaHistorian.MAX_SAMPLES_UNWATCHED + 400,
		"an unwatched tag keeps a short history, a watched one a long one")
	_ok(absf(c.value_at("u", float(ScadaHistorian.MAX_SAMPLES_UNWATCHED + 399)) - float(ScadaHistorian.MAX_SAMPLES_UNWATCHED + 399)) < 1e-3,
		"the newest samples are the ones kept")
	# Round trip (through JSON, as the world's file does).
	var d: Variant = JSON.parse_string(JSON.stringify(h.to_dict()))
	var h2 := ScadaHistorian.new()
	h2.from_dict(d)
	_ok(h2.size("a") == h.size("a") and absf(h2.value_at("a", 102.5) - 9.0) < 1e-6 and is_nan(h2.value_at("a", 103.5)),
		"the dict round trip keeps values and gaps")
	_ok((ScadaHistorian.new().bins_exact("none", 1.0, 0, 3)["mean"] as PackedFloat32Array).size() == 3,
		"an unknown tag bins as empty")
