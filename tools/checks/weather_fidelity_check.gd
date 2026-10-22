extends RefCounted

## Does the game's weather match the real world, hour by hour, across sites
## and time zones? (sandbox; any world):
##   python tools/checks/weather_reference_fetch.py      (refresh the reference)
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/weather_fidelity_check.gd -Timeout 1500
##
## For every event in core/weather/testdata/weather_events_ref.json (Open-Meteo
## archive fetched in UTC, independently of the game) it moves Main to the
## site, lets WeatherService load that year exactly as play would, then parks
## the clock on each hour of the window and reads WeatherService.sample() at
## the clock's local time. The UTC instant of that local time comes from the
## clock's own zone (so it is the instant the in-game sun is drawn for), and
## the reading must equal the reference at that UTC hour.
## Also prints what the pre-fix reading (file read by wall time, no offset
## shift) would have been. Read-only apart from the sandbox's weather cache.

const REF := "res://core/weather/testdata/weather_events_ref.json"
const TOL := {"temperature_2m": 0.051, "precipitation": 0.011, "wind_speed_10m": 0.051,
	"cloud_cover": 0.51, "shortwave_radiation": 0.51}

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("wx-fidelity %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


## Absolute (clock-calendar) hours of a "YYYY-MM-DDTHH:MM" stamp.
func _abs_of(stamp: String) -> float:
	var c := CelestialClock.new()
	var dp := stamp.split("T")[0].split("-")
	c.year = int(dp[0])
	c.month = int(dp[1])
	c.day = int(dp[2])
	c.day_time = float(int(stamp.split("T")[1].split(":")[0]))
	return c.get_absolute_hours()


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var ws: Node = main.get_node_or_null("/root/WeatherService")
	_ok(ws != null, "WeatherService is up")
	var f := FileAccess.open(REF, FileAccess.READ)
	_ok(f != null, "reference file present (%s)" % REF)
	if ws == null or f == null:
		return {"ok": false}
	var ref: Dictionary = JSON.parse_string(f.get_as_text())
	var clk: Object = main.get("clock")
	var scratch := CelestialClock.new()
	var lat0 := float(main.get("latitude"))
	var lon0 := float(main.get("longitude"))
	var y0 := int(main.get("year"))
	var m0 := int(main.get("month"))
	var d0 := int(main.get("day"))
	var t0 := float(main.get("day_time"))
	main.set("time_scale", 0.0)

	var total_bad := 0
	var total_old_bad := 0
	for ev: Dictionary in ref["events"]:
		var times: Array = ev["time_utc"]
		var lat := float(ev["lat"])
		var lon := float(ev["lon"])
		var first_utc := _abs_of(str(times[0]))
		# Park on the window's first local day so WeatherService loads that year.
		main.set("latitude", lat)
		main.set("longitude", lon)
		scratch.longitude = lon
		var off0 := float(clk.call("zone_offset_hours",
			int(str(times[0]).substr(0, 4)), int(str(times[0]).substr(5, 2)),
			int(str(times[0]).substr(8, 2)), 12.0))
		var dd0: Dictionary = scratch.abs_hours_to_date(first_utc + off0)
		var year := int(dd0["year"])
		main.set("year", year)
		main.set("month", int(dd0["month"]))
		main.set("day", int(dd0["day"]))
		main.set("day_time", float(dd0["day_time"]))
		ws.call("notify_location_changed", lat, lon)
		var waited := 0.0
		while waited < 120.0:
			if bool(ws.call("has_data")) and bool(ws.call("covers", lat, lon)) \
					and int(ws.get("_data_year")) == year and not bool(ws.get("_fetching")):
				break
			await tree.create_timer(0.5).timeout
			waited += 0.5
			if fmod(waited, 3.0) < 0.01:
				ws.call("notify_location_changed", lat, lon)
		var loaded := int(ws.get("_data_year")) == year and bool(ws.call("covers", lat, lon))
		_ok(loaded, "%s: the game loaded %s %d (%.0f s)" % [ev["id"], ev["site"], year, waited])
		if not loaded:
			continue
		var data_off := float(ws.get("_data_utc_off_h"))
		var worst := {}
		var old_worst := {}
		var peaks := {}
		var bad := 0
		var old_bad := 0
		for i in times.size():
			var utc := _abs_of(str(times[i]))
			var ud: Dictionary = scratch.abs_hours_to_date(utc)
			var off := float(clk.call("zone_offset_hours", int(ud["year"]), int(ud["month"]),
				int(ud["day"]), float(ud["day_time"]) + off0))
			var local := utc + off
			var ld: Dictionary = scratch.abs_hours_to_date(local)
			var m := int(ld["month"])
			var d := int(ld["day"])
			var h := float(ld["day_time"])
			if int(ld["year"]) != year:
				continue
			# What the file read by wall time (the pre-fix behaviour) gives.
			var shift := (data_off - off) if is_finite(data_off) else 0.0
			var od: Dictionary = scratch.abs_hours_to_date(local - shift)
			for v: String in ref["vars"]:
				var want_v: Variant = (ev["values"] as Dictionary)[v][i]
				if want_v == null:
					continue
				var want := float(want_v)
				var got := float(ws.call("sample", v, m, d, h))
				var old := float(ws.call("sample", v, int(od["month"]), int(od["day"]), float(od["day_time"])))
				var err := absf(got - want) if is_finite(got) else INF
				var oerr := absf(old - want) if is_finite(old) else INF
				worst[v] = maxf(float(worst.get(v, 0.0)), err)
				old_worst[v] = maxf(float(old_worst.get(v, 0.0)), oerr)
				if err > float(TOL[v]):
					bad += 1
				if oerr > float(TOL[v]):
					old_bad += 1
				var pk: Vector2 = peaks.get(v, Vector2(-INF, -INF))
				peaks[v] = Vector2(maxf(pk.x, got), maxf(pk.y, want))
		total_bad += bad
		total_old_bad += old_bad
		print("wx-fidelity %s (%s, %s): clock offset UTC%+.0f, archive stamped UTC%+.0f" % [
			ev["id"], ev["site"], ev["what"], off0, data_off])
		for v: String in ref["vars"]:
			var pk: Vector2 = peaks.get(v, Vector2(NAN, NAN))
			print("    %-20s peak game %8.2f  real %8.2f   worst |err| %.3f   (before the fix %.3f)" % [
				v, pk.x, pk.y, float(worst.get(v, NAN)), float(old_worst.get(v, NAN))])
		_ok(bad == 0, "%s: every hour matches the reference (%d of %d readings off; %d before the fix)" % [
			ev["id"], bad, times.size() * (ref["vars"] as Array).size(), old_bad])

	print("wx-fidelity: %d readings off in total (%d before the time-zone fix)" % [total_bad, total_old_bad])
	main.set("latitude", lat0)
	main.set("longitude", lon0)
	main.set("year", y0)
	main.set("month", m0)
	main.set("day", d0)
	main.set("day_time", t0)
	ws.call("notify_location_changed", lat0, lon0)
	var ok := _fails.is_empty()
	print("wx-fidelity %s (%d failures)" % ["PASS" if ok else "FAIL", _fails.size()])
	return {"ok": ok, "failures": _fails}
