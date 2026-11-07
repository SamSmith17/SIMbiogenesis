class_name EspPresets
extends RefCounted

## Ready-made boards to start from, and the player's own saved designs
## (`user://esplab_library.json`, {"designs": [{id, label, spec}]}).

const LIBRARY_PATH := "user://esplab_library.json"

const BUILTINS := [
	{"id": "weather_station", "label": "Weather station", "blurb": "Temperature, humidity, pressure and light, with a little screen.",
		"spec": {"name": "Weather station", "board": "esp32_devkit_v1",
			"parts": [{"part": "bme280"}, {"part": "bh1750"}, {"part": "ssd1306"}]}},
	{"id": "tank_level", "label": "Tank level", "blurb": "Waterproof ultrasonic distance to the water, a high float and the water temperature.",
		"spec": {"name": "Tank level", "board": "esp32c3_supermini",
			"parts": [{"part": "jsnsr04t"}, {"part": "float_switch"}, {"part": "ds18b20"}]}},
	{"id": "greenhouse", "label": "Greenhouse", "blurb": "Air, CO₂, two soil probes and a relay for the fan.",
		"spec": {"name": "Greenhouse", "board": "esp32s3_devkitc1",
			"parts": [{"part": "sht40"}, {"part": "scd40"}, {"part": "soil_cap"}, {"part": "soil_cap"}, {"part": "relay_1ch", "label": "Fan"}]}},
	{"id": "power_monitor", "label": "Power monitor", "blurb": "Mains power on one circuit and a DC load on the battery.",
		"spec": {"name": "Power monitor", "board": "wemos_d1_mini",
			"parts": [{"part": "pzem004t"}, {"part": "ina219"}]}},
	{"id": "air_quality", "label": "Air quality", "blurb": "Particulates, true CO₂, VOCs and a screen.",
		"spec": {"name": "Air quality", "board": "esp32_devkit_v1",
			"parts": [{"part": "pms5003"}, {"part": "scd40"}, {"part": "sgp30"}, {"part": "ssd1306"}]}},
	{"id": "garden_pico", "label": "Garden (Pico W)", "blurb": "Air, soil and a relay for the watering valve on a Raspberry Pi Pico W.",
		"spec": {"name": "Garden", "board": "pico_w",
			"parts": [{"part": "bme280"}, {"part": "soil_cap"}, {"part": "relay_1ch", "label": "Valve"}]}},
	{"id": "flow_and_motion", "label": "Shower flow + motion", "blurb": "Water flow, motion and an LED strip that lights the way.",
		"spec": {"name": "Wash station", "board": "esp32_devkit_v1",
			"parts": [{"part": "yfs201"}, {"part": "pir_sr501"}, {"part": "ws2812"}]}},
	{"id": "rain_and_wind", "label": "Rain and wind mast", "blurb": "Rain rate, wind speed, temperature and humidity on an S2 mini.",
		"spec": {"name": "Weather mast", "board": "lolin_s2_mini",
			"parts": [{"part": "rain_gauge"}, {"part": "anemometer"}, {"part": "sht40"}]}},
	{"id": "presence_room", "label": "Room presence", "blurb": "mmWave presence that sees people sitting still, air quality, and a switched light.",
		"spec": {"name": "Living room", "board": "waveshare_s3_zero",
			"parts": [{"part": "ld2410"}, {"part": "bme680"}, {"part": "mosfet", "label": "Lamp"}]}},
	{"id": "rs485_meter", "label": "Modbus + CAN gateway", "blurb": "RS-485 for a meter or inverter, CAN for a battery BMS, four analog inputs.",
		"spec": {"name": "Power gateway", "board": "esp32s3_devkitc1",
			"parts": [{"part": "max485"}, {"part": "sn65hvd230"}, {"part": "ads1115"}, {"part": "ina260"}]}},
]


static func builtins() -> Array:
	return BUILTINS


static func builtin(id: String) -> Dictionary:
	for b in BUILTINS:
		if str(b["id"]) == id:
			return (b["spec"] as Dictionary).duplicate(true)
	return {}


static func load_library(path: String = LIBRARY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if v is Dictionary and (v as Dictionary).get("designs", []) is Array:
		return v["designs"]
	return []


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": designs}, "\t"))
	f.close()
	return true


## Save (or replace by label) a design in the library; returns the new list.
static func save_design(designs: Array, label: String, spec: Dictionary) -> Array:
	var out: Array = []
	for d in designs:
		if str(d.get("label", "")) != label:
			out.append(d)
	out.append({"id": EspEntityNames.ha_slug(label), "label": label, "spec": spec.duplicate(true)})
	return out


static func forget_design(designs: Array, label: String) -> Array:
	return designs.filter(func(d): return str(d.get("label", "")) != label)
