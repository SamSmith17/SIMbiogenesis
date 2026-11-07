extends SceneTree

## Writes the ESP board designer's YAML for a spread of designs, for
## tools/checks/esphome_validate.py to run through `esphome config`.
##   Godot --headless --path . --script tools/checks/esplab_dump_yaml.gd -- --out=<dir>
## Every part on every chip family, every board with a common set, and the
## one big design. Each design gets <out>/<node>/<node>.yaml and a
## secrets.yaml with dummy values (the template's keys, never real ones).

const DUMMY_SECRETS := """wifi_ssid: "test-ssid"
wifi_password: "test-password"
fallback_ap_password: "fallback123"
api_encryption_key: "dGhpcyBpcyBhIDMyIGJ5dGUgdGVzdCBrZXkhISEhISE="
ota_password: "otapass"
"""


func _initialize() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	if out == "":
		print("esplab dump: pass --out=<dir>")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var designs: Array = []
	# Every part alone, on one board of each platform family.
	var fam := ["esp32_devkit_v1", "esp32s3_devkitc1", "esp32c3_supermini", "esp32c6_devkitc1", "wemos_d1_mini", "pico_w", "lolin_s2_mini"]
	for bi in fam.size():
		for pid in EspParts.ids():
			designs.append(["f%d %s" % [bi, pid], fam[bi], [pid]])
	# Every board with a common set.
	var boards := EspBoards.ids()
	for bi in boards.size():
		designs.append(["common %d" % bi, boards[bi], ["bme280", "ssd1306", "ds18b20", "relay_1ch", "button"]])
	designs.append(["big esp32", "esp32_devkit_v1", ["bme280", "ssd1306", "ds18b20", "pms5003", "soil_cap", "pir_sr501",
		"relay_1ch", "ws2812", "servo_sg90", "yfs201", "hx711", "max6675", "float_switch", "button"]])
	designs.append(["hubs s3", "esp32s3_devkitc1", ["mcp23017", "pcf8574", "ads1115", "ld2410", "max485", "sn65hvd230",
		"inmp441", "rain_gauge", "anemometer", "sen55", "lcd1602"]])
	designs.append(["screens c6", "esp32c6_devkitc1", ["epaper_29", "bme680", "sh1106", "mosfet", "leak_sensor"]])
	# Every built-in design as the player gets it.
	for b in EspPresets.builtins():
		designs.append(["preset %s" % str(b["id"]), str(b["spec"]["board"]), b["spec"]["parts"]])
	# Compare's calibration filters, as the Compare tab writes them.
	designs.append(["calibrated", "esp32_devkit_v1", [{"part": "bme280", "filters": {
		"temperature": [{"offset": -0.8, "cal": true}],
		"humidity": [{"calibrate_linear": [[40.0, 38.0], [80.0, 79.0]], "cal": true}]}}, "bh1750"]])
	var n := 0
	var bad := 0
	for row in designs:
		var spec := EspSpec.empty(str(row[0]))
		spec["board"] = str(row[1])
		for pid in row[2]:
			(spec["parts"] as Array).append(pid if pid is Dictionary else {"part": pid})
		var d := EspDesign.solve(spec)
		if EspDesign.count_level(d, "error") > 0:
			bad += 1
			print("esplab dump: %s has wiring errors, skipped" % row[0])
			continue
		var dir := out.path_join(str(d["node"]))
		DirAccess.make_dir_recursive_absolute(dir)
		var f := FileAccess.open(dir.path_join(str(d["node"]) + ".yaml"), FileAccess.WRITE)
		f.store_string(str(d["yaml"]))
		f.close()
		f = FileAccess.open(dir.path_join("secrets.yaml"), FileAccess.WRITE)
		f.store_string(DUMMY_SECRETS)
		f.close()
		n += 1
	print("esplab dump: wrote %d designs to %s (%d skipped for wiring errors)" % [n, out, bad])
	quit(0)
