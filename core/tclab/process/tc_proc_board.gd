class_name TcProcBoard
extends RefCounted

## The controller board for a TC process: the design's sensors and switches
## (TcProcControl) as an ESP board the ESP board designer can wire, flash with
## ESPHome and hand to Home Assistant.
##
## The point of it is the NAMES. A rule in the Process Lab reads
## `sensor.<design>_<x>` and switches `switch.<design>_<y>`; the board made
## here is called after the design and every part on it carries the entity
## name that gives it exactly that id in Home Assistant (EspEntityNames: the
## id is the slug of the device name + the entity name). So the YAML the
## Control tab copies ("Copy Home Assistant automations") runs unchanged
## against the flashed board.
##
## Which hardware reads what (`part_for`):
##   a temperature in the reactor (charge, vessel gas, a thermometer, a
##     thermowell, a probe, an element)   MAX6675 + K thermocouple (to 1024 °C)
##   cooling water out                    DS18B20 (to 125 °C, waterproof probe)
##   a gasometer's fill                   VL53L0X looking down at the float: its
##     distance is turned into % by a calibrate_linear filter (empty → 0,
##     full → 100, from the holder's travel)
##   a pressure                           one channel of an ADS1115 with a
##     0.5–4.5 V transducer: volts → kPa by calibrate_linear over
##     `PRESSURE_SPAN_KPA` (pick a transducer of that span)
##   a switch (element, cooling water, drain valve, generator)
##                                        a relay module (it drives a contactor
##     or SSR for an element: a 10 A relay must not carry a heater directly)
## Everything else (charge converted, char made, gas LHV, energy totals…) is
## worked out by the model and has no stock sensor: it stays in the lab.
##
## The player's choice of what goes on the board is `process.board`:
## {"on": {entity key: bool}} over the defaults (`default_on`).

const PRESSURE_SPAN_KPA := 100.0     # a 0–100 kPa (0–15 psi) gauge transducer, 0.5–4.5 V
const TOF_MOUNT_M := 0.10            # the distance sensor sits this far above the float at its top
const MAX_PARTS := 14                # more than this will not wire on one ESP32

const PART_NOTES := {
	"max6675": "K thermocouple on a MAX6675",
	"ds18b20": "DS18B20 waterproof probe",
	"vl53l0x": "VL53L0X distance sensor over the float",
	"ads1115": "0.5–4.5 V pressure transducer on an ADS1115",
	"relay_1ch": "relay (drives a contactor / SSR / solenoid)",
}


## The ESP part that reads a sensor (TcProcControl.sensors entry); "" = the
## model works it out, no stock sensor.
static func part_for_sensor(e: Dictionary) -> String:
	var src: Dictionary = e.get("src", {})
	match str(src.get("kind", "")):
		"bed_max", "cv_t", "element":
			return "max6675"
		"cool_out":
			return "ds18b20"
		"holder":
			return "vl53l0x"
		"cv_p":
			return "ads1115"
	return ""


static func part_for_switch(a: Dictionary) -> String:
	if str(a.get("kind", "")) != "switch":
		return ""
	var act := str(a.get("act", ""))
	if act == "heaters":
		return ""                       # a group: in Home Assistant, not a pin
	if bool(a.get("hand", false)):
		return ""                       # a hand valve: nothing to wire a relay to
	return "relay_1ch"


## Every sensor and switch with what would read / drive it:
## [{key, label, unit, domain, part, note, on}] (`on` = on the board).
static func rows(sim: TcProcSim, proc: Dictionary) -> Array:
	var chosen := {}
	if proc.has("board") and proc["board"] is Dictionary and (proc["board"] as Dictionary).has("on") and proc["board"]["on"] is Dictionary:
		chosen = proc["board"]["on"]
	var out: Array = []
	for e in sim.control_sensors:
		var part := part_for_sensor(e)
		var key := str(e["key"])
		var on := default_on(e, part)
		if chosen.has(key):
			on = bool(chosen[key]) and part != ""
		out.append({"key": key, "label": str(e["label"]), "unit": str(e.get("unit", "")), "domain": "sensor",
			"part": part, "note": str(PART_NOTES.get(part, "")), "on": on, "src": e.get("src", {})})
	for a in sim.control_acts:
		if str(a.get("kind", "")) != "switch":
			continue
		var part2 := part_for_switch(a)
		var key2 := str(a["key"])
		var on2 := part2 != ""
		if chosen.has(key2):
			on2 = bool(chosen[key2]) and part2 != ""
		out.append({"key": key2, "label": str(a["label"]), "unit": "", "domain": "switch",
			"part": part2, "note": str(PART_NOTES.get(part2, "")), "on": on2, "src": {}})
	return out


## On the board unless the player says otherwise: every instrument but the
## elements' own surface temperatures (their high-limit is in the element).
static func default_on(e: Dictionary, part: String) -> bool:
	if part == "":
		return false
	return str((e.get("src", {}) as Dictionary).get("kind", "")) != "element"


## What the board carries, in words ("4 thermocouples, 1 distance sensor, 5 relays").
static func summary(rws: Array) -> String:
	var n := {}
	for r in rws:
		if bool(r["on"]):
			n[str(r["part"])] = int(n.get(str(r["part"]), 0)) + 1
	var bits: Array = []
	for pair in [["max6675", "thermocouple"], ["ds18b20", "water probe"], ["vl53l0x", "distance sensor"],
			["ads1115", "pressure input"], ["relay_1ch", "relay"]]:
		var c := int(n.get(str(pair[0]), 0))
		if c > 0:
			bits.append(UiText.count(c, str(pair[1])))
	return ", ".join(bits) if not bits.is_empty() else "nothing yet"


static func count_on(rws: Array) -> int:
	var c := 0
	for r in rws:
		if bool(r["on"]):
			c += 1
	return c


## The device name the board must carry so its entity ids are the design's.
static func friendly(d: Dictionary) -> String:
	var name := str((d.get("spec", {}) as Dictionary).get("name", "TC design"))
	var s := TcProcControl.design_slug(d)
	if EspEntityNames.ha_slug(name) == s:
		return name
	return s.replace("_", " ").capitalize()


## The entity name that gives `key` its id on a board called after the design.
static func entity_words(d: Dictionary, key: String) -> String:
	var s := TcProcControl.design_slug(d)
	var tail := key.get_slice(".", 1)
	if tail.begins_with(s + "_"):
		tail = tail.substr(s.length() + 1)
	return tail.replace("_", " ")


## The ESP board for the chosen rows (an EspSpec, resolved).
static func esp_spec(d: Dictionary, sim: TcProcSim, proc: Dictionary) -> Dictionary:
	var spec := EspSpec.empty(friendly(d))
	var parts: Array = []
	var n := 0
	for r in rows(sim, proc):
		if not bool(r["on"]):
			continue
		n += 1
		var words := entity_words(d, str(r["key"]))
		var inst := {"iid": "p%d" % n, "part": str(r["part"]), "label": words}
		match str(r["part"]):
			"max6675":
				inst["ents"] = {"temperature": {"name": words}}
				inst["update_s"] = 10.0
			"ds18b20":
				inst["ents"] = {"temperature": {"name": words}}
				inst["update_s"] = 10.0
			"vl53l0x":
				# Distance to the float → % full: far (empty) = 0, near (full) = 100.
				var stroke := _holder_stroke_m(d, sim, r["src"] as Dictionary)
				inst["ents"] = {"distance": {"name": words, "unit": "%", "dc": ""}}
				inst["filters"] = {"distance": [{"calibrate_linear": [[snappedf(TOF_MOUNT_M + stroke, 0.001), 0.0], [TOF_MOUNT_M, 100.0]]},
					{"clamp": [0.0, 100.0]}]}
				inst["update_s"] = 10.0
			"ads1115":
				inst["ents"] = {"a0": {"name": words, "unit": "kPa", "dc": "pressure"}}
				inst["filters"] = {"a0": [{"calibrate_linear": [[0.5, 0.0], [4.5, PRESSURE_SPAN_KPA]]}]}
				inst["update_s"] = 10.0
		parts.append(inst)
	spec["parts"] = parts
	return EspSpec.resolve(spec)


static func _holder_stroke_m(d: Dictionary, sim: TcProcSim, src: Dictionary) -> float:
	var i := int(src.get("i", -1))
	if i < 0 or i >= sim.units.size():
		return 0.4
	var pid := str(sim.units[i].get("part", ""))
	var pd: Dictionary = ((d.get("res", {}) as Dictionary).get("parts", {}) as Dictionary).get(pid, {})
	var ud: Dictionary = (pd.get("built", {}) as Dictionary).get("unit", {})
	return maxf(float(ud.get("stroke_mm", 400.0)) * 0.001, 0.05)


## Does the board's every entity carry its Process Lab id? {key: entity_id on
## the board} for the chosen rows (the selftest and the Control tab's note).
static func entity_ids(d: Dictionary, sim: TcProcSim, proc: Dictionary) -> Dictionary:
	var spec := esp_spec(d, sim, proc)
	var ents := EspDesign.entities_of(spec, str(spec["name"]))
	var by_iid := {}
	for e in ents:
		if str(e["iid"]) != "" and not by_iid.has(str(e["iid"])):
			by_iid[str(e["iid"])] = str(e["entity_id"])
	var out := {}
	var n := 0
	for r in rows(sim, proc):
		if not bool(r["on"]):
			continue
		n += 1
		out[str(r["key"])] = str(by_iid.get("p%d" % n, ""))
	return out
