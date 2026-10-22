extends RefCounted

## Leap-year weather indexing on a real world (sandbox, read-only).
##
## A leap-year Open-Meteo archive has 8784 hours; WeatherService used to read
## it with the common-year month table, so every date after Feb 29 read the
## day before. On Bombay Beach's 2024 archive the clock's Apr 14 15:00 showed
## Apr 13's 5.5 mph instead of the 28.5 mph dust storm. Parks the clock on the
## dates below and checks the wind the game reads.
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/weather_leap_probe.gd

## [year, month, day, hour, expected mph] read off the archive by hand.
const CASES := [
	[2024, 2, 7, 15.0, 19.1],
	[2024, 4, 14, 12.0, 6.3],
	[2024, 4, 14, 15.0, 28.5],
	[2024, 4, 14, 22.0, 14.9],
]
const MPH_PER_MS := 2.23694

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("leap-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var ws: Node = tree.root.get_node_or_null("WeatherService")
	if ws == null:
		return {"ok": false, "why": "no WeatherService"}
	main.set("time_scale", 0.0)
	for c in CASES:
		main.set("year", int(c[0]))
		main.set("month", int(c[1]))
		main.set("day", int(c[2]))
		main.set("day_time", float(c[3]))
		# The service polls the sim year / location and loads that archive.
		var waited := 0.0
		while waited < 20.0:
			await tree.create_timer(0.5).timeout
			waited += 0.5
			if ws.call("has_data") and is_finite(float(ws.call("wind_speed_ms",
					int(c[1]), int(c[2]), float(c[3])))):
				break
		var ms := float(ws.call("wind_speed_ms", int(c[1]), int(c[2]), float(c[3])))
		var mph := ms * MPH_PER_MS
		print("leap-check %04d-%02d-%02d %05.2f  wind %.1f mph (want %.1f)  archive year %d" % [
			int(c[0]), int(c[1]), int(c[2]), float(c[3]), mph, float(c[4]),
			int(ws.get("_data_year"))])
		_ok(absf(mph - float(c[4])) < 0.3,
			"%04d-%02d-%02d %02d:00 reads %.1f mph (want %.1f)" % [
				int(c[0]), int(c[1]), int(c[2]), int(c[3]), mph, float(c[4])])
	return {"ok": _fails.is_empty(), "fails": _fails}
