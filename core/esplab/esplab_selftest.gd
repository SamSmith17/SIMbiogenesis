extends SceneTree

## ESP board lab self-test (offline). Run --import first:
##   Godot --headless --path . --script core/esplab/esplab_selftest.gd
## The board and part data against the chips' rules, HA's entity-id rule,
## the auto-wire solver (I2C addresses and second buses, shared SPI, UARTs,
## 1-Wire, ADC on ADC1, input-only pins for inputs only, pull-ups, locked
## wires, RP2040 fixed pin sets, determinism), the electrical checks and the
## YAML (a golden file, secrets only by reference).

const EXPECTED_CHECKS := 1590

var _pass := 0
var _fail := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: ", what)


func _initialize() -> void:
	EspDesign.clear_cache()
	_test_data()
	_test_names()
	_test_i2c()
	_test_spi_uart_onewire()
	_test_pins()
	_test_locks()
	_test_rp2040()
	_test_checks()
	_test_yaml()
	_test_spec()
	_test_twin()
	_test_probe()
	_test_builder()
	_test_bindings()
	_test_compare()
	_test_breadth()
	var total := _pass + _fail
	print("esplab selftest: %d passed, %d failed (%d checks)" % [_pass, _fail, total])
	if EXPECTED_CHECKS > 0 and total != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [total, EXPECTED_CHECKS])
		_fail += 1
	print("esplab selftest: ", "PASS" if _fail == 0 else "FAILED")
	quit(0 if _fail == 0 else 1)


func _design(board: String, parts: Array, extra: Dictionary = {}) -> Dictionary:
	var spec := EspSpec.empty("Garden probe")
	spec["board"] = board
	spec["diagnostics"] = false
	for p in parts:
		if p is String:
			(spec["parts"] as Array).append({"part": p})
		else:
			(spec["parts"] as Array).append(p)
	spec.merge(extra, true)
	return EspDesign.solve(spec)


func _assign(d: Dictionary, iid: String, label: String) -> Variant:
	return ((d["wire"]["assign"] as Dictionary).get(iid, {}) as Dictionary).get(label, null)


func _has_check(d: Dictionary, level: String, needle: String) -> bool:
	for c in d["checks"]:
		if str(c["level"]) == level and str(c["text"]).find(needle) >= 0:
			return true
	return false


func _errors(d: Dictionary) -> int:
	return EspDesign.count_level(d, "error")


# ------------------------------------------------------------------ data

func _test_data() -> void:
	for id in EspBoards.ids():
		var b := EspBoards.get_board(id)
		var chip := EspBoards.chip_of(b)
		_ok(not chip.is_empty(), "%s: chip %s known" % [id, b["chip"]])
		_ok(EspBoards.has_rail(b, "gnd") and EspBoards.has_rail(b, "3v3"), "%s: has GND and 3V3" % id)
		for g in EspBoards.header_gpios(b):
			_ok(EspChips.has_gpio(chip, int(g)), "%s: GPIO%d exists on %s" % [id, g, chip["label"]])
		for g in (b.get("i2c", []) as Array):
			_ok(EspBoards.header_gpios(b).has(int(g)), "%s: default I2C pin %d is on the header" % [id, g])
		for k in (b.get("spi", {}) as Dictionary):
			_ok(EspBoards.header_gpios(b).has(int(b["spi"][k])), "%s: default SPI %s is on the header" % [id, k])
	for cid in EspChips.ALL:
		var c := EspChips.get_chip(cid)
		for g in c["input_only"]:
			_ok(EspChips.has_gpio(c, int(g)), "%s: input-only %d exists" % [cid, g])
		for g in c["adc1"]:
			_ok(EspChips.has_gpio(c, int(g)), "%s: ADC1 %d exists" % [cid, g])
	var roles := ["vcc", "gnd", "nc", "sda", "scl", "sck", "miso", "mosi", "cs", "tx", "rx", "out", "in",
		"data", "aout", "pulse", "led", "pwm"]
	for pid in EspParts.ids():
		var p := EspParts.get_part(pid)
		var has_vcc := false
		var has_gnd := false
		for pin in p["pins"]:
			_ok(roles.has(str(pin[1])), "%s: pin role %s known" % [pid, pin[1]])
			has_vcc = has_vcc or str(pin[1]) == "vcc"
			has_gnd = has_gnd or str(pin[1]) == "gnd"
		_ok(has_gnd, "%s: has a GND pin" % pid)
		_ok(has_vcc or pid in ["float_switch", "button", "buzzer", "rain_gauge", "anemometer", "mosfet"], "%s: has a supply pin" % pid)
		_ok(str(p.get("cat", "")) != "" and EspParts.CATEGORIES.any(func(c): return c[0] == p["cat"]), "%s: category known" % pid)
		if str(p["iface"]) == "i2c":
			_ok(not (p.get("addr", []) as Array).is_empty(), "%s: has I2C addresses" % pid)
		var keys := {}
		for e in p["ents"]:
			_ok(not keys.has(e["k"]), "%s: entity key %s unique" % [pid, e["k"]])
			keys[e["k"]] = true
			_ok(str(e.get("src", "")) != "", "%s.%s: twin source set" % [pid, e["k"]])
	_ok(EspChips.pin_name("esp8266", 17) == "A0", "ESP8266 analog pin is A0")
	_ok(EspChips.pin_name("esp32", 21) == "GPIO21", "pin names are GPIOn")
	_ok(EspChips.functions_of("esp32", 34).has("input only"), "GPIO34 reads as input only")
	_ok(not EspChips.is_adc(EspChips.get_chip("esp32"), 25, true), "ESP32 ADC2 is off with Wi-Fi")
	_ok(EspChips.is_adc(EspChips.get_chip("esp32"), 25, false), "ESP32 ADC2 works without Wi-Fi")


# ------------------------------------------------------------------ names

func _test_names() -> void:
	_ok(EspEntityNames.ha_slug("Garden probe BME280 Temperature") == "garden_probe_bme280_temperature", "slug: plain words")
	_ok(EspEntityNames.ha_slug("PM2.5") == "pm2_5", "slug: PM2.5")
	_ok(EspEntityNames.ha_slug("Küche  CO₂ (eCO2)") == "kuche_co2_eco2", "slug: umlaut, subscript, brackets (%s)" % EspEntityNames.ha_slug("Küche  CO₂ (eCO2)"))
	_ok(EspEntityNames.ha_slug("--x--") == "x", "slug: no leading / trailing _")
	_ok(EspEntityNames.node_name("Garden Probe #2") == "garden-probe-2", "node name")
	_ok(EspEntityNames.node_name("A very long name for a little board indeed").length() <= EspEntityNames.NODE_MAX, "node name length")
	_ok(EspEntityNames.entity_name("BME280", "Temperature") == "BME280 Temperature", "entity name joins")
	_ok(EspEntityNames.entity_name("Relay", "Relay") == "Relay", "entity name no doubling")
	_ok(EspEntityNames.entity_name("LED Strip", "LED Strip") == "LED Strip", "entity name no doubling 2")
	_ok(EspEntityNames.entity_id("sensor", "Garden probe", "BME280 Temperature") == "sensor.garden_probe_bme280_temperature", "entity id")
	_ok(EspEntityNames.esphome_id("p1", "pm_2_5") == "p1_pm_2_5", "esphome id")


# ------------------------------------------------------------------ I2C

func _test_i2c() -> void:
	var d := _design("esp32_devkit_v1", ["bme280", "ssd1306"])
	var buses: Array = d["wire"]["buses"]["i2c"]
	_ok(buses.size() == 1, "one I2C bus for two parts")
	_ok(int(buses[0]["sda"]) == 21 and int(buses[0]["scl"]) == 22, "I2C on the board's 21 / 22")
	_ok(int(d["wire"]["addr"]["p1"]) == 0x76 and int(d["wire"]["addr"]["p2"]) == 0x3C, "addresses 0x76 / 0x3C")
	_ok(_assign(d, "p1", "SDA") == 21 and _assign(d, "p2", "SCL") == 22, "both parts' SDA / SCL on the bus")
	_ok(_assign(d, "p1", "VIN") == "3V3" and _assign(d, "p1", "GND") == "GND", "power pins")
	_ok(_errors(d) == 0, "BME280 + OLED: no errors")
	# Two of the same: the second takes its other address.
	d = _design("esp32_devkit_v1", ["bme280", "bme280"])
	_ok(int(d["wire"]["addr"]["p1"]) == 0x76 and int(d["wire"]["addr"]["p2"]) == 0x77, "second BME280 at 0x77")
	_ok((d["wire"]["buses"]["i2c"] as Array).size() == 1, "two BME280s share one bus")
	# Three: a second bus on its own pins.
	d = _design("esp32_devkit_v1", ["bme280", "bme280", "bme280"])
	var b2: Array = d["wire"]["buses"]["i2c"]
	_ok(b2.size() == 2, "third BME280 opens a second bus")
	if b2.size() == 2:
		_ok(int(b2[1]["sda"]) != 21 and int(b2[1]["scl"]) != 22 and int(b2[1]["sda"]) != int(b2[1]["scl"]), "second bus on other pins")
		_ok(not EspChips.is_input_only(EspChips.get_chip("esp32"), int(b2[1]["sda"])), "second bus SDA can drive")
		_ok(str(d["wire"]["i2c_of"]["p3"]) == "bus_b", "third part on bus_b")
	_ok(_errors(d) == 0, "three BME280s on an ESP32: no errors")
	# A single-bus chip: an error naming the address.
	d = _design("esp32c3_supermini", ["bme280", "bme280", "bme280"])
	_ok(_errors(d) == 1 and _has_check(d, "error", "no free I2C address"), "C3: third BME280 is an error")
	# A fixed-address part twice.
	d = _design("esp32c3_supermini", ["aht20", "aht20"])
	_ok(_has_check(d, "error", "AHT20 2 has no free I2C address"), "two AHT20s on one bus: error names the second")
	# A requested address is honoured.
	d = _design("esp32_devkit_v1", [{"part": "bme280", "addr": 0x77}, "bmp280"])
	_ok(int(d["wire"]["addr"]["p1"]) == 0x77 and int(d["wire"]["addr"]["p2"]) == 0x76, "requested 0x77 kept, BMP280 takes 0x76")
	# Many breakouts: the pull-up note.
	d = _design("esp32_devkit_v1", ["bme280", "ssd1306", "bh1750", "ina219", "vl53l0x"])
	_ok(_has_check(d, "info", "I2C breakouts share the bus"), "five breakouts: pull-up note")


# ------------------------------------------------------------------ SPI / UART / 1-Wire

func _test_spi_uart_onewire() -> void:
	var d := _design("esp32_devkit_v1", ["max6675", "max6675"])
	var spi: Array = d["wire"]["buses"]["spi"]
	_ok(spi.size() == 1, "one SPI bus")
	_ok(int(spi[0]["sck"]) == 18 and int(spi[0]["miso"]) == 19 and not spi[0].has("mosi"), "SPI on 18 / 19, no MOSI needed")
	var cs1: Variant = _assign(d, "p1", "CS")
	var cs2: Variant = _assign(d, "p2", "CS")
	_ok(cs1 is int and cs2 is int and cs1 != cs2, "each MAX6675 has its own CS")
	_ok(_assign(d, "p1", "SO") == 19 and _assign(d, "p2", "SCK") == 18, "parts' bus pins")
	# UARTs: an ESP32 has two for parts.
	d = _design("esp32_devkit_v1", ["pms5003", "mhz19b", "neo6m"])
	_ok((d["wire"]["buses"]["uart"] as Array).size() == 2, "two UARTs placed")
	_ok(_has_check(d, "error", "No UART left for GPS"), "third serial part is an error")
	for b in d["wire"]["buses"]["uart"]:
		for r in ["tx", "rx"]:
			if b.has(r):
				_ok(int(b[r]) != 1 and int(b[r]) != 3, "UART %s avoids the console pins" % r)
	_ok(_assign(d, "p1", "TX") is int and _assign(d, "p1", "RX") is int, "PMS5003: both serial pins wired")
	var gd := _design("esp32_devkit_v1", ["neo6m"])
	var gps_rx: Variant = _assign(gd, "p1", "RX")
	_ok(_assign(gd, "p1", "TX") is int and gps_rx is String and gps_rx == "", "GPS: only its TX is wired (read only)")
	# ESP8266: software serial note.
	d = _design("wemos_d1_mini", ["pms5003"])
	_ok(_errors(d) == 0 and _has_check(d, "info", "software serial"), "D1 mini PMS5003: software serial note")
	# 1-Wire: one pin for every probe.
	d = _design("esp32_devkit_v1", ["ds18b20", "ds18b20", "ds18b20"])
	var ow: Array = d["wire"]["buses"]["one_wire"]
	_ok(ow.size() == 1 and (ow[0]["members"] as Array).size() == 3, "three DS18B20 on one 1-Wire bus")
	_ok(_assign(d, "p1", "DQ") == _assign(d, "p3", "DQ"), "same DQ pin")
	_ok(not (EspChips.get_chip("esp32")["no_pull"] as Array).has(int(ow[0]["pin"])), "1-Wire not on a pin without pull-up")
	_ok(_has_check(d, "info", "4.7 kΩ"), "pull-up resistor note")
	_ok(_has_check(d, "info", "DS18B20s share one wire"), "addresses note")
	_ok(str(d["yaml"]).find("# address:") >= 0, "YAML asks for addresses")


# ------------------------------------------------------------------ pins

func _test_pins() -> void:
	var esp32 := EspChips.get_chip("esp32")
	# Analog on ADC1 with Wi-Fi on.
	var d := _design("esp32_devkit_v1", ["soil_cap"])
	var g: Variant = _assign(d, "p1", "AOUT")
	_ok(g is int and (esp32["adc1"] as Array).has(g), "soil sensor on ADC1 (%s)" % str(g))
	d = _design("esp32c3_supermini", ["soil_cap"])
	g = _assign(d, "p1", "AOUT")
	_ok(g is int and int(g) <= 4, "C3 soil sensor on ADC1 0-4")
	d = _design("wemos_d1_mini", ["soil_cap", "soil_cap"])
	_ok(_assign(d, "p1", "AOUT") == 17, "D1 mini soil on A0")
	_ok(_has_check(d, "error", "No pin for Soil 2"), "a second analog part on an ESP8266 is an error")
	_ok(str(d["yaml"]).find("pin: A0") >= 0 and str(d["yaml"]).find("multiply: 3.2") >= 0, "ESP8266 ADC: A0 and the divider")
	# Input-only pins: fine for a PIR, never for an output or a pulled-up input.
	d = _design("esp32_devkit_v1", ["pir_sr501"])
	g = _assign(d, "p1", "OUT")
	_ok(g is int and EspChips.is_input_only(esp32, int(g)), "PIR output uses an input-only pin first (%s)" % str(g))
	d = _design("esp32_devkit_v1", ["button", "relay_1ch", "dht22", "hcsr04"])
	for pin in [["p1", "A"], ["p2", "IN"], ["p3", "DATA"], ["p4", "Trig"]]:
		g = _assign(d, pin[0], pin[1])
		_ok(g is int and not EspChips.is_input_only(esp32, int(g)), "%s %s not on an input-only pin (%s)" % [pin[0], pin[1], str(g)])
	# Never flash, never the console, never a strapping pin when a free one exists.
	d = _design("esp32_devkit_v1", ["relay_1ch", "relay_1ch", "relay_1ch", "relay_1ch"])
	for i in 4:
		g = _assign(d, "p%d" % (i + 1), "IN")
		_ok(g is int and not EspChips.is_flash(esp32, int(g)) and int(g) != 1 and int(g) != 3, "relay %d avoids flash and console" % (i + 1))
		_ok(EspChips.strapping_note(esp32, int(g)) == "", "relay %d avoids strapping pins" % (i + 1))
	# Fill a small board until strapping pins must be used: a warning per pin.
	var many: Array = []
	for i in 14:
		many.append("relay_1ch")
	d = _design("esp32c3_supermini", many)
	_ok(_has_check(d, "warn", "is a strapping pin"), "C3 full of relays: strapping warnings")
	_ok(_has_check(d, "error", "No pin for"), "C3 out of pins: an error")
	# Screen boards keep their display pins.
	d = _design("cyd_2432s028r", ["bme280", "relay_1ch"])
	var cyd := EspBoards.get_board("cyd_2432s028r")
	for gg in d["wire"]["used"]:
		_ok(not (cyd["reserved"] as Dictionary).has(int(gg)), "CYD: nothing on reserved GPIO%d" % int(gg))
	_ok(int(d["wire"]["buses"]["i2c"][0]["sda"]) == 27 and int(d["wire"]["buses"]["i2c"][0]["scl"]) == 22, "CYD I2C on 27 / 22")


# ------------------------------------------------------------------ locks

func _test_locks() -> void:
	var d := _design("esp32_devkit_v1", ["relay_1ch"], {"locks": {"p1:IN": 23}})
	_ok(_assign(d, "p1", "IN") == 23, "a locked pin is kept")
	d = _design("esp32_devkit_v1", ["relay_1ch"], {"locks": {"p1:IN": 34}})
	var g: Variant = _assign(d, "p1", "IN")
	_ok(_has_check(d, "error", "can't go on D34") and g is int and int(g) != 34, "a lock on an input-only pin is refused, wired elsewhere")
	d = _design("esp32_devkitc_38", ["relay_1ch"], {"locks": {"p1:IN": 9}})
	_ok(_has_check(d, "error", "can't go on SD2"), "a lock on a flash pin is refused")
	d = _design("esp32_devkit_v1", ["bme280"], {"locks": {"p1:SDA": 25, "p1:SCL": 26}})
	var bus: Dictionary = d["wire"]["buses"]["i2c"][0]
	_ok(int(bus["sda"]) == 25 and int(bus["scl"]) == 26, "locked I2C pins move the bus")
	d = _design("esp32_devkit_v1", ["relay_1ch", "relay_1ch"], {"locks": {"p1:IN": 23, "p2:IN": 23}})
	_ok(_has_check(d, "error", "wired twice"), "two locks on one pin: error")
	# The same spec solves the same.
	EspDesign.clear_cache()
	var a := _design("esp32s3_devkitc1", ["bme280", "pms5003", "ds18b20", "relay_1ch", "soil_cap", "ws2812"])
	EspDesign.clear_cache()
	var b := _design("esp32s3_devkitc1", ["bme280", "pms5003", "ds18b20", "relay_1ch", "soil_cap", "ws2812"])
	_ok(JSON.stringify(a["wire"]["assign"]) == JSON.stringify(b["wire"]["assign"]), "solve is deterministic")
	_ok(str(a["yaml"]) == str(b["yaml"]), "YAML is deterministic")
	var s3 := EspChips.get_chip("esp32s3")
	for gg in a["wire"]["used"]:
		_ok(not EspChips.is_usb(s3, int(gg)) and not EspChips.is_flash(s3, int(gg)), "S3: GPIO%d is not USB / flash" % int(gg))
		_ok(not [35, 36, 37].has(int(gg)), "S3: GPIO%d is not the octal PSRAM" % int(gg))


# ------------------------------------------------------------------ RP2040

func _test_rp2040() -> void:
	var rp := EspChips.get_chip("rp2040")
	var d := _design("pico_w", ["bme280", "pms5003", "mhz19b", "max6675"])
	var bus: Dictionary = d["wire"]["buses"]["i2c"][0]
	var ctrl := int(bus["ctrl"])
	_ok(ctrl >= 0, "Pico I2C picks a controller")
	_ok(((rp["i2c_pins"][ctrl]["sda"]) as Array).has(int(bus["sda"])) and ((rp["i2c_pins"][ctrl]["scl"]) as Array).has(int(bus["scl"])),
		"Pico SDA / SCL from one controller")
	var ctrls := {}
	for u in d["wire"]["buses"]["uart"]:
		var c := int(u["ctrl"])
		ctrls[c] = true
		for r in ["tx", "rx"]:
			if u.has(r):
				_ok(((rp["uart_pins"][c][r]) as Array).has(int(u[r])), "Pico UART%d %s on a legal pin" % [c, r])
	_ok(ctrls.size() == 2, "two serial parts use both Pico UARTs")
	var spi: Dictionary = d["wire"]["buses"]["spi"][0]
	var sc := int(spi["ctrl"])
	_ok(((rp["spi_pins"][sc]["sck"]) as Array).has(int(spi["sck"])) and ((rp["spi_pins"][sc]["miso"]) as Array).has(int(spi["miso"])),
		"Pico SPI SCK / MISO from one controller")
	_ok(_errors(d) == 0, "Pico design: no errors")
	_ok(str(d["yaml"]).find("rp2:\n  board: rpipicow") >= 0, "Pico YAML platform")
	_ok(str(d["yaml"]).find("captive_portal") < 0, "Pico YAML has no captive portal")


# ------------------------------------------------------------------ checks

func _test_checks() -> void:
	var d := _design("esp32_devkit_v1", ["hcsr04"])
	_ok(_has_check(d, "warn", "Echo sends 5 V"), "HC-SR04 echo: 5 V warning")
	_ok(_assign(d, "p1", "VCC") == "5V", "HC-SR04 on 5 V")
	d = _design("esp32_devkit_v1", ["ws2812"])
	_ok(_has_check(d, "info", "3.3 V into a 5 V strip"), "WS2812 level note")
	d = _design("esp32_devkit_v1", ["ws2812", "ws2812"])
	_ok(_has_check(d, "warn", "More than a USB port"), "two strips: USB budget warning")
	var p: Dictionary = d["power"]
	_ok(is_equal_approx(float(p["ma_5v"]), 240.0 + 960.0), "5 V budget = board + strips (%s)" % str(p["ma_5v"]))
	d = _design("esp32_devkit_v1", ["relay_1ch"])
	_ok(_has_check(d, "info", "onboard LED") == false, "a free pin exists: the LED pin is not used")
	d = _design("esp32_devkit_v1", [{"part": "dht22", "update_s": 1}])
	_ok(_has_check(d, "warn", "faster than every 2 s"), "DHT22 at 1 s: warning")
	d = _design("esp32c3_supermini", ["yfs201"])
	_ok(_has_check(d, "info", "counts pulses in software") and str(d["yaml"]).find("use_pcnt: false") >= 0, "C3 pulse counter in software")
	var errs := 0
	for c in d["checks"]:
		_ok(str(c.get("why", "")) != "", "every check says why (%s)" % c["text"])
		errs += 1
	_ok(errs > 0, "checks exist")


# ------------------------------------------------------------------ YAML

const GOLDEN := """# Garden probe, written by SIMbiogenesis' board designer.
# Wiring: ESP32 DevKit V1 (30-pin). Secrets live in secrets.yaml beside this file.

esphome:
  name: "garden-probe"
  friendly_name: "Garden probe"

esp32:
  board: esp32dev
  framework:
    type: "esp-idf"

logger:

api:
  encryption:
    key: !secret api_encryption_key

ota:
  - platform: esphome
    encryption: {}

wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
  ap:
    ssid: "Garden probe Fallback"
    password: !secret fallback_ap_password

captive_portal:

i2c:
  - id: bus_a
    sda: GPIO21
    scl: GPIO22

sensor:
  - platform: bme280_i2c
    i2c_id: bus_a
    address: 0x76
    update_interval: 60s
    temperature:
      name: "BME280 Temperature"
      id: p1_temperature
    pressure:
      name: "BME280 Pressure"
      id: p1_pressure
    humidity:
      name: "BME280 Humidity"
      id: p1_humidity
"""


func _test_yaml() -> void:
	var d := _design("esp32_devkit_v1", ["bme280"])
	var y := str(d["yaml"])
	_ok(y == GOLDEN, "golden YAML for one BME280")
	if y != GOLDEN:
		print(y)
	var ids: Array = []
	for e in d["entities"]:
		ids.append(e["entity_id"])
	_ok(ids == ["sensor.garden_probe_bme280_temperature", "sensor.garden_probe_bme280_pressure", "sensor.garden_probe_bme280_humidity"],
		"entity ids (%s)" % str(ids))
	# A design with everything: secrets by reference only, every entity named.
	var spec := EspSpec.empty("Shed node")
	spec["board"] = "esp32_devkit_v1"
	for pid in ["bme280", "ssd1306", "ds18b20", "pms5003", "soil_cap", "pir_sr501", "relay_1ch", "ws2812", "servo_sg90",
			"yfs201", "hx711", "max6675", "float_switch", "button"]:
		(spec["parts"] as Array).append({"part": pid})
	d = EspDesign.solve(spec)
	y = str(d["yaml"])
	_ok(_errors(d) == 0, "the big design has no errors (%s)" % str(d["checks"].filter(func(c): return c["level"] == "error")))
	for line in y.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("password:") or t.begins_with("key:") or (t.begins_with("ssid:") and t.find("Fallback") < 0):
			_ok(t.find("!secret") >= 0, "no literal secret: %s" % t)
	for e in d["entities"]:
		if str(e["iid"]) != "":
			_ok(y.find("name: \"%s\"" % str(e["name"])) >= 0, "YAML names %s" % e["name"])
	_ok(y.find("platform: uptime") >= 0 and y.find("platform: status") >= 0, "diagnostics present")
	_ok(y.find("esp32_rmt_led_strip") >= 0 and y.find("num_leds: 8") >= 0, "LED strip block")
	_ok(y.find("servo.write") >= 0 and y.find("frequency: \"50 Hz\"") < 0 and y.find("frequency: 50 Hz") >= 0, "servo blocks")
	_ok(y.find("it.printf(0, 0, id(font_small), \"Shed node\");") >= 0, "OLED shows the board's name")
	_ok(y.find("calibrate_linear:\n          - 2.6 -> 0.0") >= 0, "soil calibrate_linear rows (%s)" % y.substr(y.find("calibrate_linear"), 80))
	_ok(y.find("mode:\n        input: true\n        pullup: true\n      inverted: true") >= 0, "button pin object")
	_ok(y.count("\t") == 0, "no tabs in YAML")
	_ok(str(d["secrets"]).find("api_encryption_key:") >= 0, "secrets template")
	# The other platforms' headers.
	y = str(_design("wemos_d1_mini", ["bme280"])["yaml"])
	_ok(y.find("esp8266:\n  board: d1_mini") >= 0 and y.find("sda: GPIO4") >= 0, "D1 mini header and I2C")
	y = str(_design("esp32c6_devkitc1", ["bme280"])["yaml"])
	_ok(y.find("variant: \"esp32c6\"") >= 0, "C6 variant")


func _test_spec() -> void:
	var spec := EspSpec.empty("x")
	spec = EspSpec.with_part(spec, "bme280")
	spec = EspSpec.with_part(spec, "bme280")
	spec = EspSpec.with_part(spec, "nope")
	var r := EspSpec.resolve(spec)
	_ok((r["parts"] as Array).size() == 2, "unknown part dropped")
	_ok(str(r["parts"][1]["label"]) == "BME280 2", "second instance labelled 2")
	_ok(str(r["parts"][0]["iid"]) == "p1" and str(r["parts"][1]["iid"]) == "p2", "instance ids")
	spec["locks"] = {"p2:SDA": 21}
	spec = EspSpec.without_part(spec, "p2")
	_ok((spec["locks"] as Dictionary).is_empty(), "removing a part drops its locks")
	var k1 := EspSpec.key_of(EspSpec.resolve(spec))
	var round_trip: Variant = JSON.parse_string(JSON.stringify(EspSpec.resolve(spec)))
	_ok(EspSpec.key_of(EspSpec.resolve(round_trip)) == k1, "key survives a JSON round trip")
	_ok(str(EspSpec.resolve({"board": "nope"})["board"]) == EspSpec.DEFAULT_BOARD, "unknown board falls back")
	# The diagram's card layout rides the spec but never its key.
	var with_lay := EspSpec.resolve(spec)
	with_lay["layout"] = {"p1": [10.0, 20.0], "gone": [1.0, 1.0]}
	var rl := EspSpec.resolve(with_lay)
	_ok((rl.get("layout", {}) as Dictionary).has("p1") and not (rl["layout"] as Dictionary).has("gone"), "layout kept for live parts only")
	_ok(EspSpec.key_of(rl) == k1, "layout is not part of the key")
	# Every built-in design wires without an error.
	for b in EspPresets.builtins():
		var d := EspDesign.solve(b["spec"])
		_ok(EspDesign.count_level(d, "error") == 0, "built-in %s has no wiring errors" % b["id"])
	# Names: a relay called "Fan" is "Fan"; a soil probe is "Soil Moisture".
	var g := EspDesign.solve(EspPresets.builtin("greenhouse"))
	var ids: Array = g["entities"].map(func(e): return str(e["entity_id"]))
	_ok(ids.has("switch.greenhouse_fan"), "relay named Fan -> switch.greenhouse_fan")
	_ok(ids.has("sensor.greenhouse_soil_moisture") and ids.has("sensor.greenhouse_soil_2_moisture"), "soil probes -> soil_moisture, soil_2_moisture")


# ------------------------------------------------------------------ the twin

## A world for the twin: smooth weather, a step in distance at hour 100.
func _fake(src: String, t: float) -> Variant:
	match src:
		"air.temp_c", "probe.temp_c":
			return 20.0 + 5.0 * sin(t * 0.26)
		"air.rh_pct":
			return 55.0
		"air.pressure_hpa":
			return 1009.0
		"soil.moisture_pct":
			return 50.0
		"motion.present":
			return 1.0
		"dist.m":
			return 1.0 if t < 100.0 else 3.0
		"rain.mmh":
			return 3.0
		"air.wind_ms":
			return 5.0
		"elec.current_a":
			return 1.2
		"presence.cm":
			return 150.0
		"flow.lpm":
			return 6.0
		"diag.boot_h":
			return 90.0
	return NAN


func _ent(d: Dictionary, part: String, k: String) -> Dictionary:
	for e in d["entities"]:
		if str(e["part"]) == part and str(e["k"]) == k:
			return e
	return {}


func _test_twin() -> void:
	var src := Callable(self, "_fake")
	var d := _design("esp32_devkit_v1", ["bme280", "soil_cap", "pir_sr501", "yfs201", "ds18b20", "hcsr04"], {"diagnostics": true})
	var temp := _ent(d, "bme280", "temperature")
	var unit := EspSim.unit_key(str(d["node"]), temp)
	# The tick: at or before the asked hour, within one update interval.
	var tk := EspSim.tick_of(temp, unit, 123.456)
	_ok(float(tk["t"]) <= 123.456 and float(tk["t"]) > 123.456 - 60.0 / 3600.0, "the tick is the last one before t")
	var r1 := EspSim.reading(temp, unit, float(tk["t"]) + 1.0 / 3600.0, src)
	var r2 := EspSim.reading(temp, unit, float(tk["t"]) + 50.0 / 3600.0, src)
	_ok(r1["value"] == r2["value"], "a reading holds until the next tick")
	# Pure in time: a later read does not change an earlier one.
	var early := EspSim.reading(temp, unit, 110.0, src)
	EspSim.reading(temp, unit, 500.0, src)
	_ok(EspSim.reading(temp, unit, 110.0, src)["value"] == early["value"], "scrubbing back reads the same value")
	_ok(EspSim.format(temp, early).ends_with(" °C") and EspSim.format(temp, early).find(".") > 0, "formatted like HA (%s)" % EspSim.format(temp, early))
	# Units differ by their own bias; every one inside the datasheet accuracy.
	var worst := 0.0
	var spread := {}
	for i in 60:
		var u := "board%d|p1|temperature" % i
		var t := 200.0 + float(i) * 0.37
		var tt := float(EspSim.tick_of(temp, u, t)["t"])
		var err := float(EspSim.reading(temp, u, t, src)["value"]) - float(_fake("air.temp_c", tt))
		worst = maxf(worst, absf(err))
		spread[snappedf(err, 0.1)] = true
	_ok(worst <= 1.0 * EspSim.BIAS_SHARE + 4.0 * 0.02 + 0.06, "60 units all within half the spec plus noise (%.3f)" % worst)
	_ok(spread.size() > 5, "units do not all read alike")
	# Resolution and range.
	var sim := {"res": 0.0625, "acc": 0.5, "noise": 0.02, "lo": -55.0, "hi": 125.0}
	for i in 10:
		var v := EspSim.with_error(sim, "u%d" % i, i, 21.3)
		var m := fposmod(v, 0.0625)
		_ok(m < 1e-6 or absf(m - 0.0625) < 1e-6, "DS18B20 steps of 1/16 C (%f)" % v)
	_ok(EspSim.with_error(sim, "u", 0, 400.0) <= 125.0, "range limit")
	# Filters both ways: the soil probe's volts to % and back.
	var soil := _ent(d, "soil_cap", "moisture")
	_ok(int(soil["part_filters"]) == 2, "the soil probe's own filters are known")
	var raw := EspSim.invert_filters(soil["filters"], 50.0)
	_ok(raw > 1.2 and raw < 2.6, "50 percent soil is %.2f V at the pin" % raw)
	_ok(absf(EspSim.apply_filters(soil["filters"], raw) - 50.0) < 1e-6, "volts back to 50 percent")
	var sv := float(EspSim.reading(soil, EspSim.unit_key("n", soil), 150.0, src)["value"])
	_ok(absf(sv - 50.0) <= 5.0 * EspSim.BIAS_SHARE + 3.0, "soil reads about 50 percent (%.1f)" % sv)
	# A player's offset filter shifts the twin exactly as it shifts the board.
	var spec2: Dictionary = d["spec"].duplicate(true)
	for p in spec2["parts"]:
		if str(p["part"]) == "bme280":
			p["filters"] = {"temperature": [{"offset": -0.8}]}
	var d2 := EspDesign.solve(spec2)
	var temp2 := _ent(d2, "bme280", "temperature")
	var a := float(EspSim.reading(temp, unit, 150.0, src)["value"])
	var b := float(EspSim.reading(temp2, unit, 150.0, src)["value"])
	_ok(absf((a - b) - 0.8) < 0.051, "an offset filter moves the twin by -0.8 (%.2f)" % (a - b))
	_ok(str(d2["yaml"]).find("- offset: -0.8") >= 0, "and the YAML carries it")
	var fit := EspSim.linear_fit([[0.0, 1.0], [2.0, 5.0]])
	_ok(is_equal_approx(fit.x, 2.0) and is_equal_approx(fit.y, 1.0), "calibrate_linear line through two points")
	# Pulses: the flow meter's raw signal is pulses per minute.
	var flow := _ent(d, "yfs201", "flow")
	_ok(absf(EspSim.invert_filters((flow["filters"] as Array).slice(0, 1), 6.0) - 6.0 / 0.00222) < 1.0, "6 L/min is about 2700 pulses per minute")
	# Binary sensors and availability.
	var pir := _ent(d, "pir_sr501", "motion")
	var pr := EspSim.reading(pir, "x", 150.0, src)
	_ok(pr["value"] == true and EspSim.format(pir, pr) == "detected", "PIR reads detected")
	var dist := _ent(d, "hcsr04", "distance")
	var none := EspSim.reading(dist, "x", 150.0, func(_s, _t): return NAN)
	_ok(not bool(none["available"]) and EspSim.format(dist, none) == "unavailable", "no source means unavailable")
	# Response lag: a slow part reaches a step over several ticks.
	var slow := dist.duplicate(true)
	slow["sim"] = {"tau": 300.0}
	slow["update_s"] = 60.0
	var first := float(EspSim.reading(slow, "lag", 100.0 + 61.0 / 3600.0, src)["value"])
	var later := float(EspSim.reading(slow, "lag", 100.5, src)["value"])
	_ok(first > 1.0 and first < 3.0, "the first tick after a step is partway (%.2f)" % first)
	_ok(is_equal_approx(later, 3.0), "and it settles (%.2f)" % later)
	# History as HA records it: a new point only when the value changes.
	var nd := dist.duplicate(true)
	nd["sim"] = {}
	var hist := EspSim.series(nd, "h", 99.0, 101.0, src)
	_ok(hist.size() == 2, "a step makes two history points (%d)" % hist.size())
	for i in range(1, hist.size()):
		_ok(hist[i][1] != hist[i - 1][1], "history point %d differs from the last" % i)
	var th := EspSim.series(temp, unit, 100.0, 104.0, src)
	_ok(th.size() > 20 and th.size() <= 241, "temperature history over 4 h (%d points)" % th.size())
	var ok_order := true
	for i in range(1, th.size()):
		ok_order = ok_order and float(th[i][0]) > float(th[i - 1][0])
	_ok(ok_order, "history in time order")
	# Diagnostics.
	var up := {}
	var st := {}
	for e in d["entities"]:
		if str(e["src"]) == "diag.uptime":
			up = e
		elif str(e["src"]) == "diag.status":
			st = e
	var u1 := float(EspSim.reading(up, "d", 92.0, src)["value"])
	var u2 := float(EspSim.reading(up, "d", 93.0, src)["value"])
	_ok(u1 > 6000.0 and absf((u2 - u1) - 3600.0) < 61.0, "uptime counts seconds since boot (%d to %d)" % [int(u1), int(u2)])
	_ok(EspSim.reading(st, "d", 92.0, src)["value"] == true, "status is connected")


func _test_probe() -> void:
	_ok(absf(EspWorldProbe.isa_pressure_hpa(0.0) - 1013.25) < 0.01, "ISA at sea level")
	_ok(absf(EspWorldProbe.isa_pressure_hpa(1000.0) - 898.75) < 0.5, "ISA at 1000 m (%.1f)" % EspWorldProbe.isa_pressure_hpa(1000.0))
	_ok(EspWorldProbe.soil_moisture_pct(0.0) < EspWorldProbe.soil_moisture_pct(5.0) and EspWorldProbe.soil_moisture_pct(50.0) <= 70.0, "soil wetter with rain, capped")
	var p := EspWorldProbe.new().setup(48.42, -122.33, 300.0)
	var pr := p.value("air.pressure_hpa", 300000.0)
	_ok(absf(pr - EspWorldProbe.isa_pressure_hpa(300.0)) < 0.01 and p.note_of("air.pressure_hpa") != "", "no weather: pressure from the standard atmosphere, said so")
	p.bindings["elec.current_a"] = func(t: float) -> float: return t * 0.001
	_ok(is_equal_approx(p.value("elec.current_a", 2000.0), 2.0), "a binding is read at the asked time")
	p.bindings["level.float"] = true
	_ok(is_equal_approx(p.value("level.float", 1.0), 1.0), "a constant binding")
	_ok(p.value("mass.kg", 1.0) == 0.0, "unbound reads 0")
	p.people_fn = func(_pos: Vector3, _r: float, _t: float) -> int: return 3
	_ok(is_equal_approx(p.value("air.co2_ppm", 5.0), 420.0 + 3.0 * 35.0), "CO2 rises with people nearby")
	_ok(p.value("motion.present", 5.0) == 1.0, "people means motion")
	_ok(p.value("dist.m", 5.0) == 1.0, "bench distance without a ray")
	_ok(is_equal_approx(p.value("gps.lat", 5.0), 48.42), "GPS latitude")
	# The probe feeds the twin end to end.
	var d := _design("esp32_devkit_v1", ["bme280", "scd40", "neo6m"])
	for e in d["entities"]:
		var r := EspSim.reading(e, EspSim.unit_key("n", e), 300000.0, p.source())
		_ok(bool(r["available"]), "%s reads from the probe (%s)" % [e["entity_id"], EspSim.format(e, r)])


# ------------------------------------------------------------------ the world

class FakeModel:
	var items := {}

	func get_item(id: String) -> Dictionary:
		return items.get(id, {})


func _test_builder() -> void:
	for b in EspPresets.builtins():
		var spec: Dictionary = b["spec"]
		var node := EspBuilder.build_node(spec)
		var sp: Dictionary = node.get_meta("sensor_points", {})
		var r := EspSpec.resolve(spec)
		for inst in r["parts"]:
			_ok(sp.has(str(inst["iid"])), "%s: %s has a place on the model" % [b["id"], inst["label"]])
		var meshes := node.find_children("*", "MeshInstance3D", true, false)
		_ok(meshes.size() >= 6, "%s: the model is drawn (%d meshes)" % [b["id"], meshes.size()])
		var top := 0.0
		for m in meshes:
			top = maxf(top, (m as MeshInstance3D).position.y)
		_ok(top > 1.0 and top < 1.6, "%s: the board stands on its stake (top %.2f m)" % [b["id"], top])
		node.free()
	var tank := EspBuilder.build_node(EspPresets.builtin("tank_level"))
	var dp: Dictionary = tank.get_meta("distance_points", {})
	_ok(dp.size() == 1, "the tank board's ultrasonic has a ray point")
	for k in dp:
		_ok((dp[k] as Vector3).y > 0.5, "the ultrasonic hangs on its arm, looking down")
	tank.free()
	_ok(EspBuilder.power_w(EspPresets.builtin("weather_station")) > 0.5 and EspBuilder.power_w(EspPresets.builtin("weather_station")) < 3.0,
		"a weather station draws about a watt (%.2f W)" % EspBuilder.power_w(EspPresets.builtin("weather_station")))


func _test_bindings() -> void:
	var items: Array = [
		{"id": "t1", "type": "resource", "specs": {"name": "Rain tank", "level": 0.4, "capacity_qty": 1000.0, "stock_l": 400.0}},
		{"id": "b1", "type": "battery", "specs": {"name": "Bank", "voltage": 51.2, "soc": 0.8}},
		{"id": "l1", "type": "appliance", "specs": {"name": "Pump", "avg_watts": 240.0, "current_state": "on"}},
		{"id": "l2", "type": "appliance", "specs": {"name": "Fan", "avg_watts": 60.0, "current_state": "off"}},
		{"id": "virtual_x", "type": "resource", "specs": {}},
	]
	var m := FakeModel.new()
	for it in items:
		m.items[it["id"]] = it
	var dist := EspBindings.choices("dist.m", items)
	_ok(dist.size() == 1 and str(dist[0][0]) == "tank.t1.distance_m", "an ultrasonic can measure the tank (not a virtual one)")
	_ok(str(dist[0][1]).find("Rain tank") >= 0, "the choice names the tank")
	_ok(EspBindings.choices("air.temp_c", items).is_empty(), "a thermometer has no graph choices")
	_ok(EspBindings.choices("actuator.switch", items).size() == 2, "a relay can switch either load")
	_ok(absf(EspBindings.read(m, "tank.t1.distance_m") - 0.6) < 1e-6, "a 1000 L tank 40 %% full: 0.6 m down to the water (%.3f)" % EspBindings.read(m, "tank.t1.distance_m"))
	_ok(EspBindings.read(m, "tank.t1.high") == 0.0, "the float is down at 40 %")
	_ok(EspBindings.read(m, "tank.t1.mass_kg") == 400.0, "400 L of water is 400 kg")
	_ok(EspBindings.read(m, "item.b1.voltage") == 51.2, "the battery's voltage")
	_ok(absf(EspBindings.read(m, "load.l1.current_ac", -122.0) - 2.0) < 1e-6, "240 W on 120 V mains is 2 A")
	_ok(EspBindings.read(m, "load.l1.ac_v", 8.0) == 230.0 and EspBindings.read(m, "load.l1.ac_hz", 8.0) == 50.0, "230 V / 50 Hz in Europe")
	_ok(EspBindings.read(m, "load.l2.power_w") == 0.0, "a load that is off draws nothing")
	_ok(EspBindings.read(m, "item.l1.switch") == 1.0 and EspBindings.read(m, "item.l2.switch") == 0.0, "relays follow their loads")
	_ok(is_nan(EspBindings.read(m, "tank.gone.distance_m")), "a deleted item reads NAN")
	_ok(EspBindings.item_of("tank.t1.distance_m") == "t1" and EspBindings.item_of("air.temp_c") == "", "item_of")
	# Through the probe and the twin: the ultrasonic over the tank.
	var spec := EspPresets.builtin("tank_level")
	(spec["parts"] as Array)[0]["measures"] = {"distance": "tank.t1.distance_m"}
	var d := EspDesign.solve(spec)
	var e := _ent(d, "jsnsr04t", "distance")
	_ok(str(e["src"]) == "tank.t1.distance_m", "the binding reaches the entity")
	var p := EspWorldProbe.new().setup(48.0, -122.0, 20.0)
	p.graph_model = m
	var r := EspSim.reading(e, "u", 1000.0, p.source())
	_ok(bool(r["available"]) and absf(float(r["value"]) - 0.6) < 0.05, "the twin's ultrasonic reads the water 0.6 m down (%s)" % EspSim.format(e, r))
	m.items["t1"]["specs"]["level"] = 0.7
	var r2 := EspSim.reading(e, "u", 1000.0, p.source())
	_ok(absf(float(r2["value"]) - 0.3) < 0.05, "fill it to 70 %% and it reads 0.3 m (%s)" % EspSim.format(e, r2))
	m.items["t1"]["specs"]["level"] = 0.95
	var r3 := EspSim.reading(e, "u", 1000.0, p.source())
	_ok(absf(float(r3["value"]) - 0.25) < 0.011, "nearly full: the JSN-SR04T's 25 cm blind zone (%s)" % EspSim.format(e, r3))


func _test_compare() -> void:
	var src := Callable(self, "_fake")
	var d := _design("esp32_devkit_v1", ["bme280", "pir_sr501"])
	var temp := _ent(d, "bme280", "temperature")
	var motion := _ent(d, "pir_sr501", "motion")
	var teid := str(temp["entity_id"])
	# Matching: the predicted id first.
	var cat := [{"entity_id": teid, "unit": "°C"}, {"entity_id": str(motion["entity_id"]), "unit": ""}]
	var m := EspCompare.match_entities(d, cat)
	_ok(str(m.get(teid, "")) == teid, "the predicted entity id matches itself")
	_ok(m.size() >= 2, "every entity the catalog holds is matched (%d)" % m.size())
	# Else the one entity of the domain whose id ends with the entity's slug.
	var tail := "_" + EspEntityNames.ha_slug(str(temp["name"]))
	var other := "sensor.old_board_name" + tail
	m = EspCompare.match_entities(d, [{"entity_id": other, "unit": "°C"}])
	_ok(str(m.get(teid, "")) == other, "a renamed board is found by the entity's own name (%s)" % other)
	m = EspCompare.match_entities(d, [{"entity_id": other, "unit": "°F"}])
	_ok(str(m.get(teid, "")) == other, "°F agrees with °C (same family)")
	m = EspCompare.match_entities(d, [{"entity_id": other, "unit": "%"}])
	_ok(not m.has(teid), "a unit of another family is not a match")
	m = EspCompare.match_entities(d, [{"entity_id": other, "unit": "°C"}, {"entity_id": "sensor.another" + tail, "unit": "°C"}])
	_ok(not m.has(teid), "two candidates: no guess")
	m = EspCompare.match_entities(d, [{"entity_id": other, "unit": "°C"}, {"entity_id": "sensor.another" + tail, "unit": "°C"}], {teid: "sensor.another" + tail})
	_ok(str(m.get(teid, "")) == "sensor.another" + tail, "a saved choice is kept")
	# States.
	_ok(EspCompare.state_value("21.5") == 21.5 and EspCompare.state_value("on") == 1.0 and EspCompare.state_value("off") == 0.0, "states as numbers")
	_ok(is_nan(EspCompare.state_value("unavailable")) and is_nan(EspCompare.state_value("unknown")), "unavailable is a gap")
	# History rows onto the site's clock, both shapes, sorted.
	var clock := CelestialClock.new()
	clock.set("longitude", -122.0)
	var u0 := 1_762_000_000.0
	var rows := [{"s": "20.5", "lu": u0 + 600.0}, {"state": "20.0", "last_updated": HaObservedStore.unix_to_iso(u0)}, {"s": "unavailable", "lu": u0 + 1200.0}]
	var h := EspCompare.parse_history(rows, clock)
	_ok(h.size() == 3 and float(h[0][1]) == 20.0 and float(h[1][1]) == 20.5 and is_nan(float(h[2][1])), "history parsed and sorted")
	_ok(absf(float(h[0][0]) - SiteTime.unix_to_site_abs(clock, u0)) < 1e-6 and absf(float(h[1][0]) - float(h[0][0]) - 600.0 / 3600.0) < 1e-6, "on the site's clock")
	# Stats: real = the ideal twin + 0.8.
	var unit := EspSim.unit_key(str(d["node"]), temp)
	var t0 := 1000.0
	var t1 := 1024.0
	var twin := EspCompare.numeric(EspSim.series(temp, unit, t0, t1, src, 4000, true))
	_ok(twin.size() > 20, "the twin's ideal series has its changes (%d)" % twin.size())
	var real: Array = []
	for r in twin:
		real.append([float(r[0]) + 0.5 / 3600.0, float(r[1]) + 0.8])
	var st := EspCompare.stats(real, twin, t0, t1, 0.05)
	_ok(absf(float(st["bias"]) - 0.8) < 0.05, "bias ~0.8 (%.3f)" % float(st["bias"]))
	_ok(float(st["r"]) > 0.99, "r ~1 (%.4f)" % float(st["r"]))
	_ok(absf(float(st["a"]) - 1.0) < 0.05, "slope ~1 (%.3f)" % float(st["a"]))
	_ok(float(st["coverage"]) > 0.95, "coverage (%.2f)" % float(st["coverage"]))
	_ok(EspCompare.verdict(st, temp) == "good", "0.8 °C is inside a BME280's ±1 °C")
	var real_bad: Array = []
	for r in twin:
		real_bad.append([float(r[0]), float(r[1]) + 4.0])
	_ok(EspCompare.verdict(EspCompare.stats(real_bad, twin, t0, t1, 0.05), temp) == "poor", "4 °C off is poor")
	_ok(EspCompare.verdict(EspCompare.stats([], twin, t0, t1, 0.05), temp) == "no data", "no readings: no verdict")
	# Calibration: an offset, and a line.
	var cal := EspCompare.calibration(st, "offset")
	_ok(absf(float(cal.get("offset", 0.0)) + 0.8) < 0.05 and bool(cal.get("cal", false)), "offset calibration = -bias (%s)" % str(cal))
	var real_lin: Array = []
	for r in twin:
		real_lin.append([float(r[0]), 2.0 * float(r[1]) + 1.0])
	var sl := EspCompare.stats(real_lin, twin, t0, t1, 0.05)
	var lin := EspCompare.calibration(sl, "linear")
	var pts: Array = lin.get("calibrate_linear", [])
	_ok(pts.size() == 2 and absf(float(pts[0][0]) - (2.0 * float(pts[0][1]) + 1.0)) < 0.05, "calibrate_linear maps the real reading back (%s)" % str(pts))
	# Written into the spec: replaces an earlier calibration, keeps the player's own.
	var spec: Dictionary = d["spec"].duplicate(true)
	var iid := str(temp["iid"])
	for p in spec["parts"]:
		if str(p["iid"]) == iid:
			p["filters"] = {"temperature": [{"multiply": 1.0}]}
	spec = EspCompare.with_calibration(spec, iid, "temperature", {"offset": -0.5, "cal": true})
	spec = EspCompare.with_calibration(spec, iid, "temperature", cal)
	var fl: Array = []
	for p in spec["parts"]:
		if str(p["iid"]) == iid:
			fl = p["filters"]["temperature"]
	_ok(fl.size() == 2 and fl[0].has("multiply") and absf(float(fl[1]["offset"]) + 0.8) < 0.05, "one calibration, the player's filter kept (%s)" % str(fl))
	# The YAML carries it (without the marker); the twin ignores it.
	var d2 := EspDesign.solve(spec)
	var y := str(d2["yaml"])
	_ok(y.contains("- offset: -0.8"), "the calibration is in the YAML")
	_ok(not y.contains("cal:"), "the marker never reaches the YAML")
	var temp2 := _ent(d2, "bme280", "temperature")
	var same := true
	for i in 12:
		var t := 1000.0 + float(i) * 0.7
		if EspSim.reading(temp, unit, t, src)["value"] != EspSim.reading(temp2, unit, t, src)["value"]:
			same = false
	_ok(same, "the twin reads the same with the calibration as without")
	# Ideal = the source at the tick, through the part's resolution only.
	var tk := EspSim.tick_of(temp, unit, 1003.3)
	var iv := float(EspSim.reading(temp, unit, 1003.3, src, true)["value"])
	_ok(absf(iv - float(_fake("air.temp_c", float(tk["t"])))) < 0.06, "the ideal reading is the world's value (%.3f)" % iv)
	var nv := float(EspSim.reading(temp, unit, 1003.3, src)["value"])
	_ok(absf(nv - iv) <= 0.5 + 0.1, "the unit's own bias stays inside its spec")
	_ok(EspCompare.held_at([[1.0, 5.0], [2.0, 6.0]], 1.5) == 5.0 and is_nan(EspCompare.held_at([[1.0, 5.0]], 0.5)), "held values")


# ------------------------------------------------------------------ phase 7: breadth

func _test_breadth() -> void:
	_ok(EspBoards.ids().size() >= 18, "at least 18 boards (%d)" % EspBoards.ids().size())
	_ok(EspParts.ids().size() >= 60, "at least 60 parts (%d)" % EspParts.ids().size())
	# Every board takes a small I2C weather set with no wiring error.
	for id in EspBoards.ids():
		var d := _design(str(id), ["bme280", "bh1750"])
		_ok(EspDesign.count_level(d, "error") == 0, "%s: BME280 + BH1750 wire with no error" % id)
	# The ESP8266's A0 reads a voltage and nothing else.
	var d8 := _design("wemos_d1_mini", ["pir_sr501", "button", "float_switch", "relay_1ch", "leak_sensor", "rcwl0516"])
	var on_a0 := false
	for iid in d8["wire"]["assign"]:
		for lab in d8["wire"]["assign"][iid]:
			if d8["wire"]["assign"][iid][lab] is int and int(d8["wire"]["assign"][iid][lab]) == 17:
				on_a0 = true
	_ok(not on_a0, "no digital signal is put on the ESP8266's A0")
	var da := _design("wemos_d1_mini", ["pir_sr501"], {"locks": {"p1:OUT": 17}})
	_ok(_has_check(da, "error", "can't go on A0") and _assign(da, "p1", "OUT") != 17, "a digital lock on A0 is refused")
	var ds := _design("wemos_d1_mini", ["soil_cap"])
	_ok(_assign(ds, "p1", "AOUT") == 17, "an analog part still takes A0")
	# ESP32-family-only parts.
	_ok(_has_check(_design("wemos_d1_mini", ["sn65hvd230"]), "error", "ESP32-family"), "CAN on an ESP8266: error")
	_ok(_has_check(_design("pico_w", ["inmp441"]), "error", "ESP32-family"), "I2S mic on a Pico: error")
	_ok(EspDesign.count_level(_design("esp32c3_supermini", ["sn65hvd230"]), "error") == 0, "CAN on a C3: fine")
	# Hubs and the new blocks in the YAML.
	var dh := _design("esp32s3_devkitc1", ["mcp23017", "pcf8574", "ads1115", "ld2410", "max485", "sn65hvd230", "inmp441", "lcd1602"])
	_ok(EspDesign.count_level(dh, "error") == 0, "the hub board wires")
	var y := str(dh["yaml"])
	for want in ["\nmcp23017:", "\npcf8574:", "\nads1115:", "multiplexer: A0_GND", "\nld2410:", "has_target:",
			"detection_distance:", "\nmodbus:", "flow_control_pin:", "\ncanbus:", "platform: esp32_can",
			"\ni2s_audio:", "\nmicrophone:", "i2s_din_pin:", "dimensions: 16x2", "platform: lcd_pcf8574"]:
		_ok(y.contains(want), "hub YAML has %s" % want.strip_edges())
	_ok(y.contains("address: 0x20") and y.contains("address: 0x21"), "MCP23017 and PCF8574 share 0x20..0x27 without a clash")
	_ok(y.find("\nmcp23017:") < y.find("\nsensor:"), "hubs come before the sensors that use them")
	var dc6 := _design("xiao_esp32c6", ["bme280"])
	_ok(str(dc6["yaml"]).contains("flash_size: 4MB"), "a board's flash size reaches the YAML")
	_ok(str(_design("lolin_s2_mini", ["bme280"])["yaml"]).contains("variant: \"esp32s2\""), "the S2 variant")
	# Screens never print a reading without an id (the diagnostics have none).
	for parts in [["ssd1306", "bme280"], ["sh1106"], ["epaper_29", "sht40"], ["lcd1602", "bme280"]]:
		var dd := _design("esp32_devkit_v1", parts, {"diagnostics": true})
		_ok(not str(dd["yaml"]).contains("id()"), "%s: every printed reading has an id" % str(parts))
	_ok(str(_design("esp32_devkit_v1", ["sh1106"])["yaml"]).contains("SH1106 128x64"), "the SH1106 model")
	# The twin through the new parts' filters.
	var src := Callable(self, "_fake")
	var dt := _design("esp32_devkit_v1", ["rain_gauge", "anemometer", "a02yyuw", "acs712", "ld2410", "bme680", "sen55"])
	var cases := [["rain_gauge", "rain", 3.0, 0.4], ["anemometer", "wind", 5.0, 0.9], ["a02yyuw", "distance", 1.0, 0.02],
		["acs712", "current", 1.2, 0.2], ["ld2410", "detection_distance", 150.0, 60.0]]
	for c in cases:
		var e := _ent(dt, str(c[0]), str(c[1]))
		var r := EspSim.reading(e, EspSim.unit_key(str(dt["node"]), e), 50.0, src)
		var v := float(r["value"])
		_ok(absf(v - float(c[2])) <= float(c[3]), "%s %s reads the world through its filters (%.3f vs %.3f)" % [c[0], c[1], v, float(c[2])])
	var gas := _ent(dt, "bme680", "gas_resistance")
	_ok(not gas.is_empty() and str(gas["unit"]) == "Ω", "the BME680 gas resistance is in ohms")
	_ok(not _ent(dt, "sen55", "pm_4_0").is_empty(), "the SEN55 has PM4.0")
	# The world probe has every new source.
	var p := EspWorldProbe.new().setup(48.42, -122.33, 30.0)
	for s in ["air.gas_ohm", "air.voc_index", "air.nox_index", "air.pm4_ugm3", "rain.mmh", "air.wind_ms",
			"leak.wet", "accel.z", "input.encoder", "adc.v", "presence.cm"]:
		var v := p.value(s, 300000.0)
		_ok(not is_nan(v), "the probe reads %s (%.2f)" % [s, v])
	# Every twin source of every part is one the probe answers.
	var known := {}
	for pid in EspParts.ids():
		for e in EspParts.get_part(pid)["ents"]:
			var s := str(e["src"])
			if s.begins_with("actuator.") or s == "input.button" or s == "probe.temp_c":
				continue
			known[s] = true
	for s in known:
		_ok(not is_nan(p.value(str(s), 300000.0)), "the probe answers %s" % s)
