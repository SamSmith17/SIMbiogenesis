extends RefCounted

## Power Scoreboard daily counters (sandbox, read-only on the world's files).
##
## Runs the clock from before dawn into the next day and checks the TODAY
## column: solar / wind & hydro / max capture / generated / consumed count up
## through the day, max capture is never below solar, and every counter goes
## back to zero at midnight with yesterday's solar carried into YESTERDAY.
## Shoots the panel at dawn, midday, evening and just after midnight.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/solar_scoreboard_probe.gd

const SHOTS := "user://screenshots/solar_scoreboard/"

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("scoreboard-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _counters(su: Node) -> Dictionary:
	return {
		"solar": float(su.get("daily_solar_generated_kwh")),
		"aux": float(su.get("daily_aux_generated_kwh")),
		"possible": float(su.get("daily_potential_kwh")),
		"load": float(su.get("daily_load_consumed_kwh")),
		"yesterday": float(su.get("yesterday_solar_kwh")),
	}


func _line(main: Node, c: Dictionary) -> String:
	return "h=%5.2f solar=%.3f aux=%.3f possible=%.3f load=%.3f yesterday=%.3f" % [
		fposmod(float(main.call("get_absolute_hours")), 24.0), c["solar"], c["aux"],
		c["possible"], c["load"], c["yesterday"]]


## Run the clock at `ts` sim-hours per second until the clock reads `hour`
## (wrapping past midnight when `hour` is earlier than now), then stop it.
func _run_to(tree: SceneTree, main: Node, hour: float, ts: float = 1.5) -> void:
	var start := float(main.call("get_absolute_hours"))
	var target: float = floorf(start / 24.0) * 24.0 + hour
	if target <= start:
		target += 24.0
	main.set("time_scale", ts)
	while float(main.call("get_absolute_hours")) < target:
		await tree.process_frame
	main.set("time_scale", 0.0)
	for _f in 8:   # let the 4 Hz UI tick land
		await tree.process_frame
	await tree.create_timer(0.35).timeout


func _shot(main: Node, name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOTS))
	var img := main.get_viewport().get_texture().get_image()
	img.save_png(SHOTS + name + ".png")
	print("scoreboard-check shot ", SHOTS + name + ".png")


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var su: Node = ServiceLocator.solar_ui()
	if su == null:
		return {"ok": false, "why": "no SolarUI"}
	su.visible = true
	# A fresh half-full battery so the day shows charging, not a flat floor.
	main.set("time_scale", 0.0)
	main.set("day_time", 4.0)
	for _f in 6:
		await tree.process_frame
	su.call("reanchor_live_battery", float(su.get("BATTERY_CAPACITY_KWH")) * 0.5)
	su.set("_soc_protect_active", false)
	su.set("_ac_shutdown_reason", "")

	await _run_to(tree, main, 6.0)
	var dawn := _counters(su)
	print("scoreboard-check dawn    ", _line(main, dawn))
	_shot(main, "a_dawn")

	await _run_to(tree, main, 12.5)
	var noon := _counters(su)
	print("scoreboard-check midday  ", _line(main, noon))
	_shot(main, "b_midday")
	_ok(noon["solar"] > dawn["solar"] + 0.01, "solar kWh counts up through the morning")
	_ok(noon["possible"] >= noon["solar"] - 1e-4, "max capture is never below solar")
	_ok(noon["load"] >= dawn["load"], "consumed never counts down while the clock runs forward")

	await _run_to(tree, main, 23.8)
	var eve := _counters(su)
	print("scoreboard-check evening ", _line(main, eve))
	_shot(main, "c_evening")
	_ok(eve["solar"] >= noon["solar"], "solar kWh holds after sunset")
	_ok(eve["aux"] >= noon["aux"] and eve["load"] >= noon["load"], "aux and load keep counting")

	await _run_to(tree, main, 0.4)
	var night := _counters(su)
	print("scoreboard-check midnight", _line(main, night))
	_shot(main, "d_after_midnight")
	_ok(night["solar"] < 0.01 and night["possible"] < 0.01, "solar + possible reset at midnight")
	_ok(night["load"] < eve["load"] * 0.5 + 0.01, "consumed resets at midnight")
	_ok(absf(night["yesterday"] - eve["solar"]) < 0.05,
		"yesterday = the day's solar (%.3f vs %.3f)" % [night["yesterday"], eve["solar"]])

	# Scrub back into yesterday afternoon: the counters rewind with the clock.
	var now_h := float(main.call("get_absolute_hours"))
	main.call("set_absolute_hours", floorf(now_h / 24.0) * 24.0 - 24.0 + 15.0)
	for _f in 8:
		await tree.process_frame
	await tree.create_timer(0.35).timeout
	var back := _counters(su)
	print("scoreboard-check scrubbed", _line(main, back))
	_ok(back["solar"] >= noon["solar"] - 0.01 and back["solar"] <= eve["solar"] + 0.01,
		"a scrub back reads the day's counters off the timeline")
	return {"ok": _fails.is_empty(), "fails": _fails}
