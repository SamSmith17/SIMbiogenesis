extends SceneTree

## Home Assistant integration selftest (offline).
##
## Pure parts: HaUrl (every way a player types an address, incl. the port-80
## suggestion), HaToken, HaFailure, HaProfiles against TEMP files (incl. the
## migration of the old ha_connection.cfg).
##
## End to end: the REAL HomeAssistantService against HaFakeServer on
## 127.0.0.1 — connect OK with the steps in order, ONE state_changed
## subscription however many callers subscribe, concurrent get_entity_states
## coalesced into one get_states that answers both, a wrong token (no retry), a
## refused port (and the finder offering the port HA really answers on), a
## server that never speaks HA's protocol, and a dropped connection coming back.
##
## Run: Godot --headless --path . --import
##      Godot --headless --path . --script core/ha/ha_selftest.gd

## A Godot runtime error aborts the enclosing test function while the suite
## still prints PASS; the count catches it.
const EXPECTED_CHECKS := 189

var _checks := 0
var _fails := 0
var _tmp := ""


func _init() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", what)
	else:
		_fails += 1
		print("  FAIL  ", what)


func _run() -> void:
	_tmp = OS.get_user_data_dir().path_join("ha_selftest_tmp")
	DirAccess.make_dir_recursive_absolute(_tmp)
	print("== HaUrl")
	_test_url()
	print("== HaToken")
	_test_token()
	print("== HaFailure")
	_test_failure()
	print("== HaProfiles")
	_test_profiles()
	print("== HaUnits")
	_test_units()
	print("== HaTargets")
	_test_targets()
	print("== HaLinkStore")
	_test_link_store()
	print("== HaObservedStore")
	_test_observed()
	print("== HaPresets")
	_test_presets()
	print("== Timeline weather + tracks")
	_test_weather_channels()
	_test_track_layout()
	print("== Service against a fake Home Assistant")
	await _test_e2e_ok()
	await _test_e2e_bad_token()
	await _test_e2e_refused_and_finder()
	await _test_e2e_not_ha()
	await _test_e2e_lost_and_back()
	await _test_e2e_entity_track()
	_cleanup()
	if EXPECTED_CHECKS > 0 and _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL  ran %d checks, expected %d (a runtime error aborted a test?)" % [_checks, EXPECTED_CHECKS])
	print("ha_selftest: %d checks, %d failures — %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(1 if _fails > 0 else 0)


# ---------------------------------------------------------------------------
# Pure
# ---------------------------------------------------------------------------

func _norm(s: String) -> String:
	return str(HaUrl.normalize(s).get("url", ""))


func _test_url() -> void:
	_ok(_norm("192.168.1.10") == "ws://192.168.1.10/api/websocket", "bare IP keeps no port (= 80, like a browser)")
	_ok(_norm("192.168.1.10:8123") == "ws://192.168.1.10:8123/api/websocket", "IP:port")
	_ok(_norm("http://homeassistant.local:8123") == "ws://homeassistant.local:8123/api/websocket", "http → ws")
	_ok(_norm("https://abcd.ui.nabu.casa") == "wss://abcd.ui.nabu.casa/api/websocket", "https → wss")
	_ok(_norm("abcd.ui.nabu.casa") == "wss://abcd.ui.nabu.casa/api/websocket", "Nabu Casa without a scheme is wss")
	_ok(_norm("ws://192.168.1.10:8123/api/websocket") == "ws://192.168.1.10:8123/api/websocket", "full URL unchanged")
	_ok(_norm("http://192.168.1.10:8123/lovelace/0?edit=1") == "ws://192.168.1.10:8123/api/websocket", "browser page path dropped")
	_ok(_norm("  \"http://192.168.1.10/\"  ") == "ws://192.168.1.10/api/websocket", "quotes, spaces and slash trimmed")
	_ok(_norm("ws://192.168.1.10:80") == "ws://192.168.1.10/api/websocket", "ws on 80 = no port")
	_ok(_norm("wss://h.example:443/x") == "wss://h.example/api/websocket", "wss on 443 = no port")
	_ok(_norm("[fe80::1]:8123") == "ws://[fe80::1]:8123/api/websocket", "IPv6 literal")
	_ok(not bool(HaUrl.normalize("").get("ok", true)), "empty refused")
	_ok(not bool(HaUrl.normalize("ftp://x").get("ok", true)), "ftp refused")
	_ok(not bool(HaUrl.normalize("192.168.1.10:abc").get("ok", true)), "bad port refused")
	_ok(not bool(HaUrl.normalize("192.168.1.10:70000").get("ok", true)), "port out of range refused")
	var c := HaUrl.candidates("192.168.1.10:8123")
	_ok(c == ["ws://192.168.1.10/api/websocket"], "a refused :8123 suggests port 80 (got %s)" % str(c))
	c = HaUrl.candidates("192.168.1.10")
	_ok(c == ["ws://192.168.1.10:8123/api/websocket"], "a refused port 80 suggests :8123 (got %s)" % str(c))
	c = HaUrl.candidates("homeassistant.local:8123")
	_ok(c.has("wss://homeassistant.local/api/websocket") and c.has("ws://homeassistant.local/api/websocket"),
		"a named host also tries wss on 443")
	_ok(HaUrl.browser_url("wss://h.example/api/websocket") == "https://h.example", "browser URL")
	_ok(HaUrl.short("ws://192.168.1.10:8123/api/websocket") == "192.168.1.10:8123", "short form")


func _fake_token() -> String:
	return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIiwiaWF0IjoxNzAwMDAwMDAwfQ.abcdefghijklmnopqrstuvwxyz0123456789ABCD_-xy"


func _test_token() -> void:
	var t := _fake_token()
	_ok(bool(HaToken.check(t).get("ok", false)), "a well-formed token passes")
	_ok(HaToken.clean("  \"Bearer " + t + "\"\n") == t, "quotes, Bearer, whitespace stripped")
	_ok(HaToken.clean(t.substr(0, 50) + "\n" + t.substr(50)) == t, "a line break inside is joined")
	_ok(not bool(HaToken.check("").get("ok", true)), "empty refused")
	_ok(not bool(HaToken.check("abc.def").get("ok", true)), "two parts refused")
	_ok(not bool(HaToken.check(t.substr(0, 60)).get("ok", true)), "cut-short token refused")
	_ok(not bool(HaToken.check("aaa.b$b.ccc" + "x".repeat(120)).get("ok", true)), "foreign characters refused")


func _test_failure() -> void:
	_ok(HaFailure.classify("connecting", 0.2, false) == HaFailure.REFUSED, "closed by the OS = refused")
	_ok(HaFailure.classify("connecting", 2.4, false) == HaFailure.REFUSED, "…even after Windows' 2 s of SYN retries")
	_ok(HaFailure.classify("connecting", 9.0, true) == HaFailure.UNREACHABLE, "timeout = unreachable")
	_ok(HaFailure.classify("handshake", 1.0, false) == HaFailure.NOT_HA, "opened but no auth_required = not HA")
	_ok(HaFailure.classify("auth", 1.0, false) == HaFailure.AUTH_TIMEOUT, "no login answer")
	_ok(HaFailure.classify("connected", 100.0, false) == HaFailure.LOST, "was connected = lost")
	_ok(not HaFailure.retryable(HaFailure.AUTH_INVALID), "a rejected token is never retried")
	_ok(HaFailure.retryable(HaFailure.LOST), "a lost connection is retried")
	var d := HaFailure.describe(HaFailure.REFUSED, "ws://192.168.1.10:8123/api/websocket")
	_ok(str(d["title"]).contains("192.168.1.10:8123") and str(d["fix"]) == "find", "refused names the address and offers the finder")


func _test_profiles() -> void:
	var path := _tmp.path_join("profiles.cfg")
	var legacy := _tmp.path_join("legacy.cfg")
	DirAccess.remove_absolute(path)
	var lc := ConfigFile.new()
	lc.set_value("connection", "url", "ws://192.168.1.10:8123/api/websocket")
	lc.set_value("connection", "token", _fake_token())
	lc.set_value("connection", "entities", "sensor.a\nsensor.b")
	lc.save(legacy)
	var d := HaProfiles.load_all(path, legacy)
	_ok((d["profiles"] as Array).size() == 1, "legacy file migrated into one profile")
	var p: Dictionary = d["profiles"][0]
	_ok(str(p["url"]) == "ws://192.168.1.10:8123/api/websocket" and str(p["token"]) == _fake_token(), "url + token kept")
	_ok(str(d["default_id"]) == str(p["id"]), "the migrated profile is the default")
	_ok(str(d["legacy_entities"]).contains("sensor.b"), "old entity list kept for the link migration")
	_ok(FileAccess.file_exists(path) and FileAccess.file_exists(legacy), "new file written, old file left alone")
	var d2 := HaProfiles.load_all(path, legacy)
	_ok((d2["profiles"] as Array).size() == 1, "second load does not migrate again")
	var q := HaProfiles.make("http://10.0.0.99", "tok", "Bus")
	var qid := HaProfiles.upsert(d2, q)
	q["last_ok_unix"] = 123
	HaProfiles.upsert(d2, q)
	_ok((d2["profiles"] as Array).size() == 2, "upsert by id replaces, does not duplicate")
	_ok(HaProfiles.make("10.0.0.99", "x")["id"] == qid, "same address = same id, however typed")
	HaProfiles.save_all(d2, path)
	var d3 := HaProfiles.load_all(path, "")
	_ok(int(HaProfiles.find(d3, qid).get("last_ok_unix", 0)) == 123, "round trip keeps last_ok_unix")
	_ok(HaProfiles.label(HaProfiles.find(d3, qid)) == "Bus", "label = the player's name")
	HaProfiles.remove(d3, str(p["id"]))
	_ok(str(d3["default_id"]) == qid, "removing the default promotes the next")
	var none := HaProfiles.load_all(_tmp.path_join("nope.cfg"), _tmp.path_join("nope_legacy.cfg"))
	_ok((none["profiles"] as Array).is_empty(), "no files = no profiles")


func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps


func _cv(raw: String, fu: String, tu: String) -> float:
	var c := HaUnits.convert(raw, fu, tu)
	return float(c["value"]) if bool(c["ok"]) else NAN


func _test_units() -> void:
	_ok(_near(_cv("1500", "W", "kW"), 1.5), "W → kW")
	_ok(_near(_cv("2.5", "kW", "W"), 2500.0), "kW → W")
	_ok(_near(_cv("3.2", "kWh", "kWh"), 3.2), "same unit")
	_ok(_near(_cv("50", "°F", "°C"), 10.0), "°F → °C")
	_ok(_near(_cv("283.15", "K", "°C"), 10.0), "K → °C")
	_ok(_near(_cv("10", "mph", "m/s"), 4.4704), "mph → m/s")
	_ok(_near(_cv("36", "km/h", "m/s"), 10.0), "km/h → m/s")
	_ok(_near(_cv("0.1", "in/h", "mm/h"), 2.54), "in/h → mm/h (0.1 in = 2.54 mm exactly)")
	_ok(_near(_cv("1", "gal", "L"), 3.785411784), "gal → L")
	_ok(_near(_cv("64", "%", "frac"), 0.64), "% → fraction")
	_ok(_near(_cv("42", "", "W"), 42.0), "no unit = already the target's unit")
	_ok(_near(_cv("on", "", "bool"), 1.0) and _near(_cv("off", "", "bool"), 0.0), "on / off → 1 / 0")
	_ok(_near(_cv("raining", "", "bool"), 1.0), "a weather word → on")
	_ok(_near(_cv("12", "kw", "W"), 12000.0), "lower-case unit spellings")
	_ok(not bool(HaUnits.convert("20", "°C", "%").get("ok", true)), "temperature cannot drive a percentage")
	_ok(not bool(HaUnits.convert("unavailable", "W", "W").get("ok", true)), "unavailable is no reading")
	_ok(not bool(HaUnits.convert("abc", "W", "W").get("ok", true)), "text is no number")
	var odd := HaUnits.convert("5", "widgets", "W")
	_ok(bool(odd["ok"]) and not str(odd["warn"]).is_empty(), "an unknown unit is used as-is, with a warning")
	_ok(_near(HaUnits.adjust(10.0, 2.0, 1.0, true), -21.0), "scale, offset, flip")
	_ok(HaUnits.compatibility("kW", "numeric", {"domain": "sensor", "unit": "W"}) == 1.0, "a W sensor fits a kW value")
	_ok(HaUnits.compatibility("kW", "numeric", {"domain": "sensor", "unit": "°C"}) == 0.0, "a °C sensor does not")
	_ok(HaUnits.compatibility("bool", "binary", {"domain": "switch", "unit": ""}) == 1.0, "a switch fits on / off")
	_ok(HaUnits.compatibility("W", "numeric", {"domain": "switch", "unit": ""}) == 0.0, "a switch is no power reading")
	_ok(HaUnits.compatibility("%", "numeric", {"domain": "sensor", "unit": "", "device_class": "battery"}) >= 0.9,
		"device class rescues a sensor with no unit")


func _items() -> Array:
	return [
		{"id": "item_1", "type": "battery", "label": "House bank", "specs": {"ha_links": {"soc": "sensor.bank_soc", "voltage": ""}}},
		{"id": "item_2", "type": "acload", "label": "Fridge", "specs": {}},
		{"id": "item_3", "type": "resource", "label": "Water tank", "specs": {}},
		{"id": "virtual_solar", "type": "panel", "specs": {}},
		{"id": "item_4", "type": "compound", "specs": {}},
	]


func _test_targets() -> void:
	var all := HaTargets.all_targets(_items())
	var ids := {}
	for t in all:
		ids[str(t["id"])] = t
	_ok(ids.has("site.battery_soc") and ids.has("weather.temp_c"), "site + weather values listed")
	_ok(ids.has("item.item_1.soc") and ids.has("item.item_2.power") and ids.has("item.item_3.level_pct"), "battery, load, tank fields listed")
	_ok(not ids.has("item.virtual_solar.power") and not ids.has("item.item_4.power"), "virtual mirrors and compounds skipped")
	_ok(str(ids["item.item_2.power"]["label"]) == "Fridge — Power", "a node field is labelled with the node's name")
	var p := HaTargets.parse("item.item_1.soc")
	_ok(p["scope"] == "item" and p["item_id"] == "item_1" and p["field"] == "soc", "parse an item target")
	_ok(HaTargets.parse("weather.temp_c")["field"] == "temp_c", "parse a weather target")
	_ok(HaTargets.parse("nonsense").is_empty(), "nonsense parses to nothing")
	_ok(str(HaTargets.find("item.item_3.stock_l", _items()).get("unit", "")) == "L", "find returns the unit")
	_ok(HaTargets.find("item.gone.soc", _items()).is_empty(), "a target of a deleted node is gone")
	_ok(str(HaTargets.SOLAR_UI_KEYS["temperature"]) == "weather.temp_c", "old SolarUI fields map to targets")


func _test_link_store() -> void:
	var path := _tmp.path_join("links.json")
	var solar := _tmp.path_join("solar_ui.cfg")
	var sc := ConfigFile.new()
	sc.set_value("entities", "battery_soc", "sensor.inv_soc")
	sc.set_value("entities", "solar_energy", "sensor.pv_total")
	sc.set_value("weather_entities", "temperature", "sensor.outdoor")
	sc.save(solar)
	var st := HaLinkStore.new()
	var res := st.migrate_legacy(_items(), solar)
	_ok(int(res["added"]) == 3, "migrated a node link + two SolarUI links (%d)" % int(res["added"]))
	_ok(str(st.for_target("item.item_1.soc").get("entity_id", "")) == "sensor.bank_soc", "the node's soc link kept")
	_ok(st.for_target("item.item_1.voltage").is_empty(), "an empty old link is not migrated")
	_ok(str(st.for_target("weather.temp_c").get("entity_id", "")) == "sensor.outdoor", "SolarUI temperature → weather")
	_ok(st.for_target("site.solar_energy").is_empty(), "the history-graph sensor stays SolarUI's")
	_ok((res["cleared"] as Array) == ["item_1"], "the caller is told which nodes to strip")
	_ok(int(st.migrate_legacy(_items(), solar)["added"]) == 0, "migration runs once")
	st.link("sensor.fridge_power", "item.item_2.power")
	st.link("sensor.fridge_power_2", "item.item_2.power")
	_ok(st.for_entity("sensor.fridge_power").is_empty() and str(st.for_target("item.item_2.power")["entity_id"]) == "sensor.fridge_power_2",
		"a target takes one link: a new one replaces the old")
	st.link("sensor.bank_soc", "site.battery_soc")
	_ok(st.for_entity("sensor.bank_soc").size() == 2, "one entity can feed several targets")
	var lid := str(st.for_target("site.battery_soc")["id"])
	st.set_fields(lid, {"scale": 0.5, "enabled": false})
	_ok(st.save_to(path), "saved")
	var st2 := HaLinkStore.load_from(path)
	_ok(st2.links.size() == st.links.size() and st2.migrated, "round trip keeps every link and the migrated flag")
	_ok(_near(float(st2.for_target("site.battery_soc")["scale"]), 0.5) and not bool(st2.for_target("site.battery_soc")["enabled"]),
		"…and each link's settings")
	_ok(st2.entity_ids().has("sensor.bank_soc"), "an entity still feeding an enabled link is subscribed")
	var pruned := st2.prune_items({"item_1": true})
	_ok(pruned == 1 and st2.for_target("item.item_2.power").is_empty(), "a deleted node's links are pruned")
	_ok(not st2.for_target("weather.temp_c").is_empty(), "site links survive pruning")
	var txt := FileAccess.get_file_as_string(path)
	_ok(not txt.contains("token") and not txt.contains("ws://"), "the link file holds no address or token")


func _test_observed() -> void:
	var o := HaObservedStore.new()
	o.add("k", 10.0, 1.0)
	o.add("k", 12.0, 3.0)
	o.add("k", 11.0, 2.0)
	_ok(o.size("k") == 3 and _near(o.value_at("k", 11.5), 2.0), "out-of-order readings are sorted in")
	_ok(is_nan(o.value_at("k", 9.0)), "nothing before the first reading")
	_ok(is_nan(o.value_at("k", 30.0, 6.0)), "nothing after a long gap")
	var b := o.bins("k", 10.0, 14.0, 4)
	_ok(_near(b[0], 1.0) and _near(b[1], 2.0) and _near(b[2], 3.0) and _near(b[3], 3.0), "bins: the reading inside each, held after (%s)" % str(b))
	var b3 := o.bins("k", 10.0, 14.0, 4, 6.0, 12.5)
	_ok(_near(b3[2], 3.0) and is_nan(b3[3]), "nothing is carried past NOW (%s)" % str(b3))
	var b2 := o.bins("k", 0.0, 4.0, 2)
	_ok(is_nan(b2[0]) and is_nan(b2[1]), "bins before any reading are empty")
	var u := HaObservedStore.iso_to_unix("2026-10-22T12:00:00.500+02:00")
	_ok(_near(u, float(Time.get_unix_time_from_datetime_string("2026-10-22T10:00:00")) + 0.5, 1e-3), "ISO with an offset → Unix")
	_ok(_near(HaObservedStore.row_unix({"s": "1", "lu": 1700000000.25}), 1700000000.25), "compressed history row time")
	var now_u := Time.get_unix_time_from_system()
	_ok(absf(HaObservedStore.abs_hours_local(now_u) - HaObservedStore.now_abs_hours()) < 0.01, "real time on the timeline's axis")
	var td := Time.get_datetime_dict_from_system()
	var expect := float(td["hour"]) + float(td["minute"]) / 60.0
	var got := fmod(HaObservedStore.now_abs_hours(), 24.0)
	_ok(absf(got - expect) < 0.05 or absf(got - expect) > 23.9, "…in LOCAL wall time like the NOW marker")


func _test_presets() -> void:
	var cat := [
		"sensor.canbus_esp32_s3_pv_input_power", "sensor.canbus_esp32_s3_battery_soc_inverter",
		"sensor.canbus_esp32_s3_ac_output_power", "sensor.canbus_esp32_s3_pv_generation_today",
		"switch.shellypro4pm_ece334ed2e80_output_0", "sensor.shellypro4pm_ece334ed2e80_output_0_power",
		"switch.shellypro4pm_aa11bb22cc33_switch_0", "sensor.shellypro4pm_aa11bb22cc33_switch_0_power",
		"switch.shellyplus1pm_kitchen_switch_0", "sensor.shellyplus1pm_kitchen_switch_0_power",
		"switch.porch_light",
	]
	var eco := HaPresets.find("ecoworthy")
	_ok(HaPresets.devices(eco, cat) == ["canbus_esp32_s3"], "EcoWorthy bridge found")
	var plan := HaPresets.plan(eco, "canbus_esp32_s3", {"battery": "item_1"}, cat)
	var tids := {}
	for pl in plan:
		tids[str(pl["target_id"])] = str(pl["entity_id"])
	_ok(tids.get("site.battery_soc", "") == "sensor.canbus_esp32_s3_battery_soc_inverter", "site battery ← inverter SOC")
	_ok(tids.get("site.solar_kw", "") == "sensor.canbus_esp32_s3_pv_input_power" and tids.has("site.load_kw"), "site solar + load")
	_ok(tids.get("item.item_1.soc", "") == "sensor.canbus_esp32_s3_battery_soc_inverter", "the chosen battery node too")
	_ok(not tids.has("item.item_1.voltage"), "an entity that does not exist makes no link")
	var sh := HaPresets.find("shelly4pm")
	var devs := HaPresets.devices(sh, cat)
	_ok(devs == ["shellypro4pm_aa11bb22cc33", "shellypro4pm_ece334ed2e80"], "two Shelly 4PMs, both naming styles (%s)" % str(devs))
	var sp := HaPresets.plan(sh, "shellypro4pm_aa11bb22cc33", {"shelly4pm": "item_9"}, cat)
	var st := {}
	for pl in sp:
		st[str(pl["target_id"])] = str(pl["entity_id"])
	_ok(st.get("item.item_9.c0_switch", "") == "switch.shellypro4pm_aa11bb22cc33_switch_0"
		and st.get("item.item_9.c0_power", "") == "sensor.shellypro4pm_aa11bb22cc33_switch_0_power", "the chosen 4PM's channel 1")
	_ok(HaPresets.plan(sh, "shellypro4pm_aa11bb22cc33", {"shelly4pm": ""}, cat).is_empty(), "no node chosen = no links")
	var plug := HaPresets.find("shelly_plug")
	var pd := HaPresets.devices(plug, cat)
	_ok(pd == ["shellyplus1pm_kitchen"], "a single Shelly relay found, the 4PMs not (%s)" % str(pd))
	var pp := HaPresets.plan(plug, "shellyplus1pm_kitchen", {"acload": "item_2"}, cat)
	_ok(pp.size() == 2, "relay → load power + switch (%d)" % pp.size())


func _abs(y: int, m: int, d: int, h: float) -> float:
	var yy := y - 1
	var days := 365 * yy + yy / 4 - yy / 100 + yy / 400
	return float(days + HaObservedStore._doy(m, d, y) - 1) * 24.0 + h


func _test_weather_channels() -> void:
	var W := TimelineWeatherChannels
	var d: Dictionary = W.abs_to_date(_abs(2024, 2, 29, 12.5))
	_ok(int(d["year"]) == 2024 and int(d["month"]) == 2 and int(d["day"]) == 29 and _near(float(d["hour"]), 12.5),
		"abs hours → 29 Feb 2024 12:30 (%s)" % str(d))
	d = W.abs_to_date(_abs(2026, 12, 31, 23.75))
	_ok(int(d["year"]) == 2026 and int(d["month"]) == 12 and int(d["day"]) == 31, "…31 Dec 2026")
	d = W.abs_to_date(_abs(2027, 1, 1, 0.0))
	_ok(int(d["year"]) == 2027 and int(d["month"]) == 1 and int(d["day"]) == 1 and _near(float(d["hour"]), 0.0), "…1 Jan 2027 00:00")
	d = W.abs_to_date(0.5)
	_ok(int(d["year"]) == 1 and int(d["month"]) == 1 and int(d["day"]) == 1, "…the epoch")
	var u := 1761134400.0   # 2025-10-22 12:00 UTC
	_ok(absf(HaObservedStore.unix_from_abs_local(HaObservedStore.abs_hours_local(u)) - u) < 0.01,
		"real time ↔ timeline axis round trip")
	# A reader: temperature = 10 × month + hour / 2; rain only at 06:00–07:00.
	var reader := func(acc: String, m: int, _dd: int, h: float) -> float:
		match acc:
			"temperature_c":
				return 10.0 * float(m) + h * 0.5
			"rain_rate_mmh":
				return 8.0 if h >= 6.0 and h < 7.0 else 0.0
			"cloud_cover_frac":
				return 0.25
		return NAN
	var t0 := _abs(2026, 3, 10, 0.0)
	var b := W.bins("wx_temp_c", t0, t0 + 24.0, 24, reader)
	_ok(_near(b[0], 30.25, 0.01) and _near(b[23], 30.0 + 23.5 * 0.5, 0.01), "temperature bins follow the reader (%.2f … %.2f)" % [b[0], b[23]])
	var r := W.bins("wx_rain_mmh", t0, t0 + 24.0, 4, reader)
	_ok(_near(r[1], 8.0) and _near(r[0], 0.0), "rain bins keep the burst (peak, not mean): %s" % str(r))
	var c := W.bins("wx_cloud_pct", t0, t0 + 24.0, 4, reader)
	_ok(_near(c[0], 25.0), "cloud cover in percent")
	var g := W.bins("wx_ghi_wm2", t0, t0 + 24.0, 4, reader)
	_ok(is_nan(g[0]) and is_nan(g[3]), "no data → gaps, not zero")
	_ok(W.axis_range("wx_cloud_pct", c) == Vector2(0.0, 100.0), "cloud cover axis is 0–100 %")
	var ax := W.axis_range("wx_rain_mmh", r)
	_ok(_near(ax.x, 0.0) and ax.y > 8.0, "rain axis starts at 0")
	_ok(is_nan(W.axis_range("wx_temp_c", g).x), "an empty window has no axis")
	_ok(_near(float(W.display(10.0, "°C", true)["value"]), 50.0) and str(W.display(10.0, "°C", true)["unit"]) == "°F", "°C → °F for display")
	_ok(_near(float(W.display(4.4704, "m/s", true)["value"]), 10.0), "m/s → mph")
	_ok(_near(float(W.display(25.4, "mm/h", true)["value"]), 1.0), "mm/h → in/h")
	_ok(_near(float(W.display(10.0, "°C", false)["value"]), 10.0), "metric unchanged")
	var ids := {}
	for ch in W.CHANNELS:
		ids[str(ch["id"])] = true
	_ok(ids.has("wx_temp_c") and ids.has("wx_wind_ms") and ids.has("wx_rain_mmh") and ids.has("wx_ghi_wm2"),
		"temperature, wind, rain and radiation are offered")


func _test_track_layout() -> void:
	var L := TimelineTrackLayout.new()
	L.reset_defaults()
	var n0 := L.tracks.size()
	var a := L.add_weather_track("wx_temp_c")
	var a2 := L.add_weather_track("wx_temp_c")
	_ok(a != null and a == a2 and L.tracks.size() == n0 + 1, "a weather track is added once")
	_ok(a.source == "weather" and a.label == "Temperature", "…labelled and sourced")
	a.enabled = false
	L.add_weather_track("wx_temp_c")
	_ok(a.enabled, "re-adding a hidden track shows it again")
	var e := L.add_ha_entity_track("sensor.outdoor", "Outdoor")
	_ok(e.source == "ha_entity" and e.channel == "sensor.outdoor" and e.label == "HA: Outdoor", "any HA sensor as a track")
	var back := TimelineTrackLayout.new()
	back.load_from_array(L.to_array())
	var found := false
	for t in back.tracks:
		if t is TimelineTrackDef and (t as TimelineTrackDef).source == "ha_entity" and (t as TimelineTrackDef).channel == "sensor.outdoor":
			found = true
	_ok(found, "custom tracks survive the saved layout")
	_ok(L.remove_track(e.id) and L.tracks.size() == n0 + 1, "remove a track")
	_ok(not L.remove_track("clips"), "the clips row cannot be removed")


# ---------------------------------------------------------------------------
# End to end
# ---------------------------------------------------------------------------

func _make_service() -> HomeAssistantService:
	var svc := HomeAssistantService.new()
	svc.profiles_path = _tmp.path_join("svc_profiles_%d.cfg" % Time.get_ticks_usec())
	svc.legacy_path = ""
	svc.toasts_enabled = false
	svc.auto_connect_allowed = false
	svc.connect_timeout_s = 4.0
	svc.auth_timeout_s = 2.0
	svc.backoff_min_s = 0.3
	svc.probe_timeout_s = 2.0
	root.add_child(svc)
	return svc


func _make_server() -> HaFakeServer:
	var srv := HaFakeServer.new()
	srv.token = _fake_token()
	srv.set_entity("sensor.battery_soc", "64", {"unit_of_measurement": "%", "device_class": "battery", "friendly_name": "Battery"})
	srv.set_entity("sensor.pv_power", "1234", {"unit_of_measurement": "W", "device_class": "power", "friendly_name": "PV power"})
	srv.set_entity("switch.pump", "off", {"friendly_name": "Pump"})
	root.add_child(srv)
	srv.start(38123 + randi() % 400)
	return srv


func _until(cond: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if (Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await process_frame
	return true


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _test_e2e_ok() -> void:
	var srv := _make_server()
	var svc := _make_service()
	_ok(srv.port > 0, "fake HA listening on %d" % srv.port)
	var states: Array = []
	svc.state_changed.connect(func(s: int, _i: Dictionary) -> void:
		if states.is_empty() or states[-1] != s:
			states.append(s))
	var got: Dictionary = {}
	svc.sensor_updated.connect(func(eid: String, st: Dictionary) -> void:
		got[eid] = int(got.get(eid, 0)) + 1)
	svc.connect_with(srv.url(), "  " + _fake_token() + "\n", "Test", true)
	var ok := await _until(func() -> bool: return svc.state == HomeAssistantService.State.CONNECTED, 5.0)
	_ok(ok, "connected to the fake")
	var S := HomeAssistantService.State
	_ok(states.has(S.CONNECTING) and states.has(S.AUTHENTICATING)
		and states.find(S.CONNECTING) < states.find(S.AUTHENTICATING)
		and states.find(S.AUTHENTICATING) < states.find(S.CONNECTED), "steps in order: connecting → logging in → connected")
	var info := svc.info()
	_ok(bool(info.get("reached", false)) and bool(info.get("authed", false)), "info says reached + authed")
	_ok(str(info.get("ha_version", "")) == "2026.10.1", "HA version reported")
	await _until(func() -> bool: return svc.catalog_size() == 3, 3.0)
	_ok(svc.catalog_size() == 3, "catalog has every entity")
	_ok(str(svc.catalog_entry("sensor.pv_power").get("unit", "")) == "W", "catalog row carries the unit")
	await _until(func() -> bool: return str(svc.info().get("location_name", "")) == "Test Home", 2.0)
	_ok(str(svc.info().get("location_name", "")) == "Test Home", "location name from get_config")
	var p := svc.profile(svc.active_profile_id())
	_ok(int(p.get("last_ok_unix", 0)) > 0 and str(p.get("location_name", "")) == "Test Home", "profile records the success")
	var gs0 := srv.get_states_count
	svc.subscribe_to_entities(["sensor.battery_soc"])
	svc.subscribe_to_entities(["sensor.pv_power"])
	svc.subscribe_to_entities(["sensor.battery_soc"])
	svc.get_entity_states(["sensor.battery_soc"])
	svc.get_entity_states(["sensor.pv_power"])
	await _until(func() -> bool: return got.has("sensor.battery_soc") and got.has("sensor.pv_power"), 3.0)
	_ok(got.has("sensor.battery_soc") and got.has("sensor.pv_power"), "two concurrent get_entity_states both answered")
	_ok(srv.get_states_count - gs0 == 1, "…by ONE get_states (got %d)" % (srv.get_states_count - gs0))
	_ok(srv.subscribe_count == 1, "one state_changed subscription however many callers (got %d)" % srv.subscribe_count)
	_ok(not got.has("switch.pump"), "an entity nobody asked for is not emitted")
	got.clear()
	srv.push_state("sensor.battery_soc", "65")
	srv.push_state("switch.pump", "on")
	await _until(func() -> bool: return got.has("sensor.battery_soc"), 2.0)
	await _frames(5)
	_ok(int(got.get("sensor.battery_soc", 0)) == 1, "a state change arrives exactly once")
	_ok(not got.has("switch.pump"), "unsubscribed changes stay local")
	_ok(str(svc.catalog_entry("switch.pump").get("state", "")) == "on", "…but still refresh the catalog")
	_ok(str(svc.latest("sensor.battery_soc").get("value", "")) == "65", "latest() holds the new value")
	svc.call_service("switch", "turn_on", "switch.pump")
	await _until(func() -> bool: return srv.service_calls.size() == 1, 2.0)
	_ok(srv.service_calls.size() == 1 and str(srv.service_calls[0]["service"]) == "turn_on", "service call reaches HA")
	svc.disconnect_ha()
	_ok(svc.state == HomeAssistantService.State.IDLE, "disconnect → idle")
	svc.queue_free()
	srv.stop()
	srv.queue_free()
	await _frames(2)


func _test_e2e_bad_token() -> void:
	var srv := _make_server()
	srv.token = _fake_token().replace("abc", "zzz")
	var svc := _make_service()
	svc.connect_with(srv.url(), _fake_token(), "Test", true)
	var ok := await _until(func() -> bool: return svc.state == HomeAssistantService.State.FAILED, 5.0)
	var info := svc.info()
	_ok(ok and str(info.get("reason", "")) == HaFailure.AUTH_INVALID, "wrong token → auth_invalid")
	_ok(bool(info.get("reached", false)) and not bool(info.get("authed", false)), "reached HA, token not accepted")
	_ok(str(info.get("detail", "")).contains("Invalid access token"), "HA's own message is shown")
	_ok(not info.has("retry_in_s"), "no retry is scheduled")
	await create_timer(1.0).timeout
	_ok(srv.auth_attempts == 1, "and none happens (auth attempts %d)" % srv.auth_attempts)
	svc.queue_free()
	srv.stop()
	srv.queue_free()
	await _frames(2)


func _test_e2e_refused_and_finder() -> void:
	var srv := _make_server()
	var svc := _make_service()
	svc.probe_ports = [srv.port]
	var dead := srv.port + 401
	svc.connect_with("127.0.0.1:%d" % dead, _fake_token(), "Test", true)
	var early := await _until(func() -> bool: return not str(svc.info().get("suggestion_url", "")).is_empty(), 3.5)
	_ok(early and svc.state == HomeAssistantService.State.CONNECTING, "the finder suggests HA's real port while the dead one is still being tried")
	var ok := await _until(func() -> bool: return svc.state == HomeAssistantService.State.FAILED, 8.0)
	var why := str(svc.info().get("reason", ""))
	_ok(ok and why in [HaFailure.REFUSED, HaFailure.UNREACHABLE], "nothing listening → a failure, not silence (%s)" % why)
	_ok(not svc.info().has("retry_in_s"), "a first connect that never worked is not retried")
	ok = await _until(func() -> bool: return not str(svc.info().get("suggestion_url", "")).is_empty(), 5.0)
	_ok(ok and str(svc.info()["suggestion_url"]) == srv.url(), "the finder offers the port HA answers on")
	_ok(str(svc.info().get("suggestion_version", "")) == "2026.10.1", "…with its version")
	_ok(srv.auth_attempts == 0, "the finder sends no token")
	svc.use_suggestion()
	ok = await _until(func() -> bool: return svc.state == HomeAssistantService.State.CONNECTED, 5.0)
	_ok(ok, "Use this address connects")
	_ok(str(svc.profile(svc.active_profile_id()).get("url", "")) == srv.url(), "…and saves it on the instance")
	svc.queue_free()
	srv.stop()
	srv.queue_free()
	await _frames(2)


func _test_e2e_not_ha() -> void:
	var srv := _make_server()
	srv.silent = true
	var svc := _make_service()
	svc.probe_ports = []
	svc.connect_with(srv.url(), _fake_token(), "Test", true)
	var ok := await _until(func() -> bool: return svc.state == HomeAssistantService.State.FAILED, 6.0)
	_ok(ok and str(svc.info().get("reason", "")) == HaFailure.NOT_HA, "opens but never says auth_required → not HA's API")
	srv.silent = false
	srv.mute_auth = true
	svc.connect_with(srv.url(), _fake_token(), "Test", true)
	ok = await _until(func() -> bool: return svc.state == HomeAssistantService.State.FAILED, 6.0)
	_ok(ok and str(svc.info().get("reason", "")) == HaFailure.AUTH_TIMEOUT, "no answer to the login → auth timeout")
	svc.queue_free()
	srv.stop()
	srv.queue_free()
	await _frames(2)


func _test_e2e_lost_and_back() -> void:
	var srv := _make_server()
	var svc := _make_service()
	svc.connect_with(srv.url(), _fake_token(), "Test", true)
	await _until(func() -> bool: return svc.state == HomeAssistantService.State.CONNECTED, 5.0)
	svc.subscribe_to_entities(["sensor.battery_soc"])
	await _frames(10)
	var lost := [false]
	svc.state_changed.connect(func(s: int, i: Dictionary) -> void:
		if s == HomeAssistantService.State.FAILED and str(i.get("reason", "")) == HaFailure.LOST:
			lost[0] = true)
	srv.drop_all()
	var ok := await _until(func() -> bool: return lost[0], 3.0)
	_ok(ok, "a dropped connection reads as lost")
	ok = await _until(func() -> bool: return svc.state == HomeAssistantService.State.CONNECTED, 6.0)
	_ok(ok and srv.connections == 2, "…and reconnects on its own (connections %d)" % srv.connections)
	await _frames(10)
	_ok(srv.subscribe_count == 2, "the new connection subscribes once again (%d total)" % srv.subscribe_count)
	var got := [false]
	svc.sensor_updated.connect(func(eid: String, _st: Dictionary) -> void:
		if eid == "sensor.battery_soc":
			got[0] = true)
	srv.push_state("sensor.battery_soc", "70")
	ok = await _until(func() -> bool: return got[0], 2.0)
	_ok(ok, "subscriptions survive the reconnect")
	svc.queue_free()
	srv.stop()
	srv.queue_free()
	await _frames(2)


func _test_e2e_entity_track() -> void:
	var srv := _make_server()
	var now_u := Time.get_unix_time_from_system()
	srv.set_entity("sensor.outdoor_temp", "12.5", {"unit_of_measurement": "°C", "friendly_name": "Outdoor"})
	srv.history["sensor.outdoor_temp"] = [{"s": "10", "lu": now_u - 7200.0}, {"s": "11", "lu": now_u - 3600.0},
		{"s": "unavailable", "lu": now_u - 3000.0}, {"s": "12.5", "lu": now_u - 1800.0}]
	srv.history["switch.pump"] = [{"s": "on", "lu": now_u - 5400.0}, {"s": "off", "lu": now_u - 2700.0}]
	var svc := _make_service()
	svc.connect_with(srv.url(), _fake_token(), "Test", true)
	await _until(func() -> bool: return svc.state == HomeAssistantService.State.CONNECTED, 5.0)
	var now_h := HaObservedStore.now_abs_hours()
	var got := [0]
	svc.entity_history_received.connect(func(_e: String, n: int) -> void: got[0] += n)
	var first := svc.entity_bins("sensor.outdoor_temp", now_h - 3.0, now_h, 12)
	_ok(svc.is_tracked("sensor.outdoor_temp"), "drawing a sensor track tracks it")
	var ok := await _until(func() -> bool: return got[0] >= 3, 3.0)
	_ok(ok and srv.history_requests == 1, "the window is fetched from HA's history (%d readings, %d requests)" % [got[0], srv.history_requests])
	var b := svc.entity_bins("sensor.outdoor_temp", now_h - 3.0, now_h, 12)
	_ok(is_nan(b[0]) and _near(b[4], 10.0) and _near(b[8], 11.0) and _near(b[11], 12.5),
		"bins: nothing before the first reading, then 10, 11, 12.5 (%s)" % str(b))
	_ok(first.size() == 12, "the first call answers at once (empty until history lands)")
	await _frames(5)
	svc.entity_bins("sensor.outdoor_temp", now_h - 2.5, now_h, 12)
	await _frames(5)
	_ok(srv.history_requests == 1, "a window already fetched is not asked for again")
	svc.entity_bins("sensor.outdoor_temp", now_h - 10.0, now_h, 12)
	await _until(func() -> bool: return srv.history_requests == 2, 3.0)
	_ok(srv.history_requests == 2, "scrolling further back fetches only the new part")
	srv.push_state("sensor.outdoor_temp", "13")
	# The newest bin averages the snapshot (12.5) with the push (13).
	await _until(func() -> bool: return svc.entity_bins("sensor.outdoor_temp", now_h - 1.0, now_h + 0.1, 11)[10] > 12.6, 2.0)
	var lb := svc.entity_bins("sensor.outdoor_temp", now_h - 1.0, now_h + 0.1, 11)[10]
	_ok(lb > 12.6 and lb <= 13.0, "a live change lands on the track (%.2f)" % lb)
	got[0] = 0
	svc.entity_bins("switch.pump", now_h - 2.0, now_h, 8)
	await _until(func() -> bool: return got[0] >= 2, 3.0)
	var sb := svc.entity_bins("switch.pump", now_h - 2.0, now_h, 8)
	_ok(_near(sb[2], 1.0) and _near(sb[6], 0.0), "an on / off entity draws as 1 / 0 (%s)" % str(sb))
	_ok(is_nan(HomeAssistantService.entity_number("Sunny")) and _near(HomeAssistantService.entity_number("on"), 1.0),
		"text states are skipped, on / off are numbers")
	svc.queue_free()
	srv.stop()
	srv.queue_free()
	await _frames(2)


func _cleanup() -> void:
	var d := DirAccess.open(_tmp)
	if d != null:
		for f in d.get_files():
			d.remove(f)
	DirAccess.remove_absolute(_tmp)
