class_name EspYaml
extends RefCounted

## Writes the ESPHome YAML for a solved design (EspDesign.solve), and the
## secrets.yaml template that goes beside it.
##
## No secret ever goes in the file (docs/LOCAL_CONFIG.md): Wi-Fi, the API key
## and the OTA password are `!secret` references.
##
## The YAML is built as ordered dictionaries and lists, then printed by a
## small serializer:
##   - a key beginning with "#" prints a comment line;
##   - a string beginning with "!" (`!secret`, `!lambda`) prints raw;
##   - a string with a newline prints as a `|-` block.

const TOP_ORDER := ["esphome", "esp32", "esp8266", "rp2", "logger", "api", "ota", "wifi",
	"captive_portal", "i2c", "spi", "uart", "one_wire", "modbus", "canbus", "mcp23017", "pcf8574",
	"ads1115", "ld2410", "i2s_audio", "microphone", "font", "output", "servo",
	"gps", "sensor", "binary_sensor", "switch", "light", "number", "display"]

const QUOTE_KEYS := ["name", "friendly_name", "ssid", "unit_of_measurement", "model", "file", "type", "variant", "chipset", "channel_colors"]

const SECRETS := ["wifi_ssid", "wifi_password", "fallback_ap_password", "api_encryption_key"]


# ------------------------------------------------------------------ build

static func build(d: Dictionary) -> String:
	var doc := build_doc(d)
	var lines := PackedStringArray()
	lines.append("# %s, written by SIMbiogenesis' board designer." % str(d["friendly"]))
	lines.append("# Wiring: %s. Secrets live in secrets.yaml beside this file." % str(d["board_label"]))
	for k in TOP_ORDER:
		if not doc.has(k):
			continue
		lines.append("")
		_emit_key(lines, k, doc[k], 0)
	return "\n".join(lines) + "\n"


static func secrets_template(d: Dictionary) -> String:
	var l := PackedStringArray()
	l.append("# secrets.yaml for %s. Fill these in; never share this file." % str(d["node"]))
	l.append("wifi_ssid: \"your network\"")
	l.append("wifi_password: \"your wifi password\"")
	l.append("fallback_ap_password: \"at least 8 characters\"")
	l.append("# 32 random bytes, base64: the ESPHome dashboard makes one, or `openssl rand -base64 32`.")
	l.append("api_encryption_key: \"\"")
	return "\n".join(l) + "\n"


## The whole document as ordered data (top key -> value).
static func build_doc(d: Dictionary) -> Dictionary:
	var spec: Dictionary = d["spec"]
	var board := EspBoards.get_board(str(spec["board"]))
	var chip_id := str(board["chip"])
	var chip := EspChips.get_chip(chip_id)
	var wire: Dictionary = d["wire"]
	var doc := {}
	doc["esphome"] = {"name": str(d["node"]), "friendly_name": str(d["friendly"])}
	match str(chip["platform"]):
		"esp32":
			var e := {"board": str(board["board"])}
			if str(chip.get("variant", "")) != "":
				e["variant"] = str(chip["variant"])
			if str(board.get("flash_size", "")) != "":
				e["flash_size"] = str(board["flash_size"])
			e["framework"] = {"type": "esp-idf"}
			doc["esp32"] = e
		"esp8266":
			doc["esp8266"] = {"board": str(board["board"])}
		"rp2":
			doc["rp2"] = {"board": str(board["board"])}
	doc["logger"] = {}
	doc["api"] = {"encryption": {"key": "!secret api_encryption_key"}}
	# OTA uploads are encrypted with the API's key (a bare block inherits it).
	doc["ota"] = [{"platform": "esphome", "encryption": "{}"}]
	var wifi := {"ssid": "!secret wifi_ssid", "password": "!secret wifi_password"}
	if chip_id != "rp2040":
		wifi["ap"] = {"ssid": "%s Fallback" % str(d["friendly"]).substr(0, 23), "password": "!secret fallback_ap_password"}
		doc["captive_portal"] = {}
	doc["wifi"] = wifi
	var buses: Dictionary = wire["buses"]
	if not (buses["i2c"] as Array).is_empty():
		var l: Array = []
		for b in buses["i2c"]:
			l.append({"id": str(b["id"]), "sda": EspChips.pin_name(chip_id, int(b["sda"])),
				"scl": EspChips.pin_name(chip_id, int(b["scl"]))})
		doc["i2c"] = l
	if not (buses["spi"] as Array).is_empty():
		var l: Array = []
		for b in buses["spi"]:
			var e := {"id": str(b["id"])}
			if b.has("sck"):
				e["clk_pin"] = EspChips.pin_name(chip_id, int(b["sck"]))
			if b.has("miso"):
				e["miso_pin"] = EspChips.pin_name(chip_id, int(b["miso"]))
			if b.has("mosi"):
				e["mosi_pin"] = EspChips.pin_name(chip_id, int(b["mosi"]))
			l.append(e)
		doc["spi"] = l
	if not (buses["uart"] as Array).is_empty():
		var l: Array = []
		for b in buses["uart"]:
			var e := {"id": str(b["id"])}
			if b.has("tx"):
				e["tx_pin"] = EspChips.pin_name(chip_id, int(b["tx"]))
			if b.has("rx"):
				e["rx_pin"] = EspChips.pin_name(chip_id, int(b["rx"]))
			e["baud_rate"] = int(b["baud"])
			l.append(e)
		doc["uart"] = l
	if not (buses["one_wire"] as Array).is_empty():
		var l: Array = []
		for b in buses["one_wire"]:
			l.append({"platform": "gpio", "id": str(b["id"]), "pin": EspChips.pin_name(chip_id, int(b["pin"]))})
		doc["one_wire"] = l
	var dallas := 0
	for inst in spec["parts"]:
		if str(inst["part"]) == "ds18b20":
			dallas += 1
	for inst in spec["parts"]:
		_emit_part(doc, d, inst, chip_id, chip, board, wire, dallas)
	if bool(spec.get("diagnostics", true)):
		_list(doc, "sensor").append({"platform": "uptime", "name": "Uptime"})
		_list(doc, "sensor").append({"platform": "wifi_signal", "name": "WiFi Signal", "update_interval": "60s"})
		_list(doc, "binary_sensor").append({"platform": "status", "name": "Status"})
	return doc


static func _list(doc: Dictionary, key: String) -> Array:
	if not doc.has(key):
		doc[key] = []
	return doc[key]


static func _ents_of(d: Dictionary, iid: String) -> Array:
	var out: Array = []
	for e in d["entities"]:
		if str(e["iid"]) == iid:
			out.append(e)
	return out


## A pin's YAML: a bare name, or {number, mode, inverted} when it needs a
## pull-up or is active-low.
static func _pin_value(chip_id: String, g: int, pullup: bool, inverted: bool) -> Variant:
	var name := EspChips.pin_name(chip_id, g)
	if not pullup and not inverted:
		return name
	var o := {"number": name}
	if pullup:
		o["mode"] = {"input": true, "pullup": true}
	if inverted:
		o["inverted"] = true
	return o


static func _emit_part(doc: Dictionary, d: Dictionary, inst: Dictionary, chip_id: String, chip: Dictionary,
		board: Dictionary, wire: Dictionary, dallas: int) -> void:
	var part := EspParts.get_part(str(inst["part"]))
	var iid := str(inst["iid"])
	var y: Dictionary = part["yaml"]
	var special := str(y.get("special", ""))
	var a: Dictionary = (wire["assign"] as Dictionary).get(iid, {})
	var ents := _ents_of(d, iid)
	var opts: Dictionary = inst.get("opts", {})
	var update := float(inst.get("update_s", -1.0))
	if update <= 0.0:
		update = float(part.get("update", 0))
	var entry := {}
	var plat := str(y.get("platform", ""))
	if plat != "":
		entry["platform"] = plat
	# Bus ids and addresses.
	match str(part["iface"]):
		"i2c":
			if (wire["i2c_of"] as Dictionary).has(iid):
				entry["i2c_id"] = str(wire["i2c_of"][iid])
				entry["address"] = "0x%02X" % int(wire["addr"][iid])
		"spi":
			entry["spi_id"] = "spi_a"
		"uart":
			if (wire["uart_of"] as Dictionary).has(iid):
				entry["uart_id"] = str(wire["uart_of"][iid])
		"onewire":
			entry["one_wire_id"] = "ow_a"
	# Per-part pins with a YAML key.
	for p in part["pins"]:
		if p.size() < 3:
			continue
		var g: Variant = a.get(str(p[0]), "")
		if not (g is int):
			continue
		var role := str(p[1])
		var pull := (part.get("pullup", []) as Array).has(role)
		var inv := (part.get("inverted", []) as Array).has(role) or bool(opts.get("inverted", false))
		if special in ["led_strip", "servo"]:
			continue
		entry[str(p[2])] = _pin_value(chip_id, int(g), pull, inv)
	for k in (y.get("fields", {}) as Dictionary):
		entry[k] = y["fields"][k]
	if str(part["iface"]) == "onewire" and dallas > 1:
		entry["# address"] = "address: 0x...  <- read this probe's address from the board's log, then uncomment"
	match special:
		"adc":
			if chip_id.begins_with("esp") and chip_id != "esp8266":
				entry["attenuation"] = "12db"
		"pulse":
			if chip_id.begins_with("esp32") and int(chip.get("pcnt", 0)) == 0:
				entry["use_pcnt"] = false
		"modbus":
			var mid := "modbus_%s" % iid
			_list(doc, "modbus").append({"id": mid, "uart_id": str(entry.get("uart_id", ""))})
			entry.erase("uart_id")
			entry["modbus_id"] = mid
		"gps":
			_emit_gps(doc, entry, ents, update)
			return
		"ssd1306":
			entry["model"] = str(y.get("model", "SSD1306 128x64"))
			_emit_screen(doc, d, entry)
			return
		"epaper":
			entry["model"] = str(y.get("model", "2.90inv2"))
			entry["full_update_every"] = 30
			entry["update_interval"] = "60s"
			_emit_screen(doc, d, entry)
			return
		"lcd":
			_emit_lcd(doc, d, entry)
			return
		"hub":
			# A bus / expander block with no entities of its own.
			entry["id"] = "%s_%s" % [str(y["dom"]), iid]
			_list(doc, str(y["dom"])).append(entry)
			return
		"ads1115":
			_emit_ads1115(doc, entry, iid, ents, update, chip_id, board, part)
			return
		"ld2410":
			_emit_ld2410(doc, entry, iid, ents, chip_id, board, part)
			return
		"i2s_mic":
			_emit_i2s_mic(doc, entry, iid)
			return
		"led_strip":
			_emit_led(doc, part, inst, a, chip_id, ents)
			return
		"servo":
			_emit_servo(doc, part, inst, a, chip_id, ents)
			return
	if update > 0.0 and str(y["dom"]) in ["sensor"]:
		entry["update_interval"] = "%ds" % int(update)
	# Entities: under their sub-key, or on the block itself.
	for e in ents:
		var block := _entity_block(e, chip_id, board, part)
		var sub := str(e["sub"])
		if sub == "":
			for k in block:
				entry[k] = block[k]
		else:
			entry[sub] = block
	_list(doc, str(y["dom"])).append(entry)


static func _entity_block(e: Dictionary, chip_id: String, board: Dictionary, part: Dictionary) -> Dictionary:
	var b := {"name": str(e["name"]), "id": str(e["id"])}
	var sets: Array = e.get("set", [])
	if sets.has("unit"):
		b["unit_of_measurement"] = str(e["unit"])
	if sets.has("dc") and str(e.get("dc", "")) != "":
		b["device_class"] = str(e["dc"])
	if sets.has("sc") and str(e.get("sc", "")) != "":
		b["state_class"] = str(e["sc"])
	if sets.has("dec"):
		b["accuracy_decimals"] = int(e["dec"])
	var filters: Array = []
	if str(part.get("iface", "")) == "adc" and chip_id == "esp8266":
		filters.append({"multiply": float(board.get("a0_scale", 1.0))})
	for f in e.get("filters", []):
		filters.append(_filter_yaml(f))
	if not filters.is_empty():
		b["filters"] = filters
	return b


## Our filter dicts -> ESPHome's shape.
static func _filter_yaml(f: Dictionary) -> Dictionary:
	if f.has("calibrate_linear"):
		var rows: Array = []
		for pr in f["calibrate_linear"]:
			rows.append("%s -> %s" % [_num(float(pr[0])), _num(float(pr[1]))])
		return {"calibrate_linear": rows}
	if f.has("offset"):
		return {"offset": float(f["offset"])}
	if f.has("clamp"):
		var c: Array = f["clamp"]
		return {"clamp": {"min_value": float(c[0]), "max_value": float(c[1])}}
	if f.has("sliding_window_moving_average"):
		var w: Dictionary = f["sliding_window_moving_average"]
		return {"sliding_window_moving_average": {"window_size": int(w.get("window_size", 5)),
			"send_every": int(w.get("send_every", 5))}}
	var out := f.duplicate()
	out.erase("cal")
	return out


static func _emit_gps(doc: Dictionary, entry: Dictionary, ents: Array, update: float) -> void:
	var g := {"uart_id": str(entry.get("uart_id", ""))}
	for e in ents:
		g[str(e["sub"])] = {"name": str(e["name"]), "id": str(e["id"])}
	if update > 0.0:
		g["update_interval"] = "%ds" % int(update)
	doc["gps"] = g


## A graphic screen (OLED, e-paper): a font and a lambda printing the board's
## own sensor readings.
static func _emit_screen(doc: Dictionary, d: Dictionary, entry: Dictionary) -> void:
	if not doc.has("font"):
		doc["font"] = [{"file": "gfonts://Roboto", "id": "font_small", "size": 12}]
	var lam := PackedStringArray()
	lam.append("it.printf(0, 0, id(font_small), \"%s\");" % _c_escape(str(d["friendly"])))
	var row := 14
	for e in d["entities"]:
		if row > 50:
			break
		if str(e["kind"]) != "sensor" or str(e["id"]) == "":
			continue
		lam.append("it.printf(0, %d, id(font_small), \"%s %%.%df %s\", id(%s).state);" % [
			row, _c_escape(str(e["short"])), int(e["dec"]), _c_escape(str(e["unit"])).replace("%", "%%"), str(e["id"])])
		row += 12
	entry["lambda"] = "\n".join(lam)
	_list(doc, "display").append(entry)


## A 16x2 character LCD: the name on the first row, the first reading on the
## second.
static func _emit_lcd(doc: Dictionary, d: Dictionary, entry: Dictionary) -> void:
	entry["dimensions"] = "16x2"
	var lam := PackedStringArray()
	lam.append("it.print(0, 0, \"%s\");" % _c_escape(str(d["friendly"]).substr(0, 16)))
	for e in d["entities"]:
		if str(e["kind"]) != "sensor" or str(e["iid"]) == "":
			continue
		lam.append("it.printf(0, 1, \"%s %%.%df%s\", id(%s).state);" % [
			_c_escape(str(e["short"]).substr(0, 8)), int(e["dec"]), _c_escape(str(e["unit"])).replace("%", "%%"), str(e["id"])])
		break
	entry["lambda"] = "\n".join(lam)
	_list(doc, "display").append(entry)


## ADS1115: the hub, then one single-ended channel as a sensor.
static func _emit_ads1115(doc: Dictionary, entry: Dictionary, iid: String, ents: Array, update: float,
		chip_id: String, board: Dictionary, part: Dictionary) -> void:
	var hub_id := "ads1115_%s" % iid
	var hub := {"id": hub_id}
	for k in ["i2c_id", "address"]:
		if entry.has(k):
			hub[k] = entry[k]
	_list(doc, "ads1115").append(hub)
	for e in ents:
		var sen := {"platform": "ads1115", "ads1115_id": hub_id, "multiplexer": "A0_GND", "gain": 4.096}
		var b := _entity_block(e, chip_id, board, part)
		for k in b:
			sen[k] = b[k]
		if update > 0.0:
			sen["update_interval"] = "%ds" % int(update)
		_list(doc, "sensor").append(sen)


## HLK-LD2410: the hub on its UART, presence as a binary sensor, the
## distance as a sensor.
static func _emit_ld2410(doc: Dictionary, entry: Dictionary, iid: String, ents: Array,
		chip_id: String, board: Dictionary, part: Dictionary) -> void:
	var hub_id := "ld2410_%s" % iid
	_list(doc, "ld2410").append({"id": hub_id, "uart_id": str(entry.get("uart_id", ""))})
	var bs := {"platform": "ld2410", "ld2410_id": hub_id}
	var sn := {"platform": "ld2410", "ld2410_id": hub_id}
	for e in ents:
		var b := _entity_block(e, chip_id, board, part)
		if str(e["kind"]) == "binary_sensor":
			bs[str(e["sub"])] = b
		else:
			sn[str(e["sub"])] = b
	if bs.size() > 2:
		_list(doc, "binary_sensor").append(bs)
	if sn.size() > 2:
		_list(doc, "sensor").append(sn)


## INMP441: the I2S bus (word select, bit clock) and the microphone on it.
static func _emit_i2s_mic(doc: Dictionary, entry: Dictionary, iid: String) -> void:
	var bus_id := "i2s_%s" % iid
	var bus := {"id": bus_id}
	for k in ["i2s_lrclk_pin", "i2s_bclk_pin"]:
		if entry.has(k):
			bus[k] = entry[k]
	_list(doc, "i2s_audio").append(bus)
	var mic := {"platform": "i2s_audio", "id": "mic_%s" % iid, "i2s_audio_id": bus_id,
		"adc_type": "external", "channel": "left", "bits_per_sample": "32bit"}
	if entry.has("i2s_din_pin"):
		mic["i2s_din_pin"] = entry["i2s_din_pin"]
	_list(doc, "microphone").append(mic)


static func _emit_led(doc: Dictionary, part: Dictionary, inst: Dictionary, a: Dictionary, chip_id: String, ents: Array) -> void:
	var g := -1
	for p in part["pins"]:
		if str(p[1]) == "led" and a.get(str(p[0]), "") is int:
			g = int(a[str(p[0])])
	if g < 0 or ents.is_empty():
		return
	var n := int((inst.get("opts", {}) as Dictionary).get("num_leds", int(part["yaml"].get("num_leds", 8))))
	var e: Dictionary = ents[0]
	var entry := {}
	if chip_id.begins_with("esp32"):
		entry = {"platform": "esp32_rmt_led_strip", "channel_colors": "GRB", "chipset": "WS2812"}
	elif chip_id == "esp8266":
		entry = {"platform": "neopixelbus", "type": "GRB", "variant": "WS2812"}
	else:
		entry = {"platform": "rp2040_pio_led_strip", "channel_colors": "GRB", "chipset": "WS2812", "pio": 0}
	entry["pin"] = EspChips.pin_name(chip_id, g)
	entry["num_leds"] = n
	entry["name"] = str(e["name"])
	entry["id"] = str(e["id"])
	_list(doc, "light").append(entry)


static func _emit_servo(doc: Dictionary, part: Dictionary, inst: Dictionary, a: Dictionary, chip_id: String, ents: Array) -> void:
	var g := -1
	for p in part["pins"]:
		if str(p[1]) == "pwm" and a.get(str(p[0]), "") is int:
			g = int(a[str(p[0])])
	if g < 0 or ents.is_empty():
		return
	var iid := str(inst["iid"])
	var e: Dictionary = ents[0]
	var plat := "ledc" if chip_id.begins_with("esp32") else ("esp8266_pwm" if chip_id == "esp8266" else "rp2040_pwm")
	var out_id := "servo_out_%s" % iid
	var servo_id := "servo_%s" % iid
	_list(doc, "output").append({"platform": plat, "id": out_id, "pin": EspChips.pin_name(chip_id, g), "frequency": "50 Hz"})
	_list(doc, "servo").append({"id": servo_id, "output": out_id})
	_list(doc, "number").append({"platform": "template", "name": str(e["name"]), "id": str(e["id"]),
		"min_value": -100, "max_value": 100, "step": 1, "optimistic": true,
		"set_action": [{"servo.write": {"id": servo_id, "level": "!lambda 'return x / 100.0;'"}}]})


static func _c_escape(s: String) -> String:
	return s.replace("\\", "\\\\").replace("\"", "\\\"")


# ------------------------------------------------------------------ serializer

static func _emit_key(lines: PackedStringArray, key: String, v: Variant, ind: int) -> void:
	var pad := " ".repeat(ind)
	if key.begins_with("#"):
		lines.append("%s# %s" % [pad, str(v)])
		return
	if v is Dictionary:
		if (v as Dictionary).is_empty():
			lines.append("%s%s:" % [pad, key])
			return
		lines.append("%s%s:" % [pad, key])
		for k in v:
			_emit_key(lines, str(k), v[k], ind + 2)
	elif v is Array:
		if (v as Array).is_empty():
			lines.append("%s%s: []" % [pad, key])
			return
		lines.append("%s%s:" % [pad, key])
		for item in v:
			_emit_item(lines, item, ind + 2)
	elif v is String and (v as String).find("\n") >= 0:
		lines.append("%s%s: |-" % [pad, key])
		for l in (v as String).split("\n"):
			lines.append("%s  %s" % [pad, l])
	else:
		lines.append("%s%s: %s" % [pad, key, _scalar(v, key)])


static func _emit_item(lines: PackedStringArray, item: Variant, ind: int) -> void:
	var pad := " ".repeat(ind)
	if item is Dictionary and not (item as Dictionary).is_empty():
		var sub := PackedStringArray()
		for k in item:
			_emit_key(sub, str(k), item[k], ind + 2)
		# Turn the first line's indent into "- ".
		var first := sub[0]
		sub[0] = pad + "- " + first.substr(ind + 2)
		lines.append_array(sub)
	else:
		lines.append("%s- %s" % [pad, _scalar(item, "")])


static func _scalar(v: Variant, key: String) -> String:
	if v is bool:
		return "true" if v else "false"
	if v is int:
		return str(v)
	if v is float:
		return _num(float(v))
	var s := str(v)
	if s.begins_with("!") or s == "{}":
		return s
	if QUOTE_KEYS.has(key) or _needs_quote(s):
		return "\"%s\"" % s.replace("\\", "\\\\").replace("\"", "\\\"")
	return s


static func _needs_quote(s: String) -> bool:
	if s == "" or s != s.strip_edges():
		return true
	if s.find(": ") >= 0 or s.find(" #") >= 0 or s.ends_with(":"):
		return true
	return "*&%@`|>{}[],?'\"".find(s[0]) >= 0


static func _num(x: float) -> String:
	var s := String.num(x, 6)
	if s.find(".") < 0 and s.find("e") < 0:
		s += ".0"
	return s
