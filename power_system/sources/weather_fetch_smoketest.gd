extends SceneTree

## Live Open-Meteo fetch smoke test (requires network — NOT part of the
## standard self-test). Fetches a real year for the SOAK map location (Oregon
## Cascades, 45.0,-121.0), confirms the data has real cloud/rain variety, and
## prints the cloudiest and rainiest days so they can be verified in-editor.
## Run: godot --headless --path . --script power_system/sources/weather_fetch_smoketest.gd

const LAT := 45.0
const LON := -121.0

const MONTH_NAMES := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const DAYS_BEFORE := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


func _initialize() -> void:
	var ws: Node = load("res://core/weather_service.gd").new()
	root.add_child(ws)
	# In --script mode nodes only enter the tree once the main loop starts;
	# HTTPRequest needs to be inside the tree before it can fire.
	await process_frame
	var year: int = ws.effective_year(int(Time.get_date_dict_from_system().year))
	print("SMOKETEST fetching %.4f,%.4f year %d ..." % [LAT, LON, year])
	# Connect before requesting so a synchronous/deferred cache-hit emit is
	# never missed.
	var pending: Array = _arm_listener(ws)
	ws.request_weather(LAT, LON, year)

	var outcome: Array = await _await_listener(pending)
	if outcome[0] != "ready":
		print("SMOKETEST FAIL: %s" % str(outcome[1]))
		quit(1)
		return

	# Monthly average cloud cover + rainy-hour counts; track extremes.
	var cloudiest_cover := -1.0
	var cloudiest := [1, 1, 12.0]
	var rainiest_rate := -1.0
	var rainiest := [1, 1, 12.0]
	var months_over_half := 0
	for mo in range(1, 13):
		var days: int = (DAYS_BEFORE[mo] - DAYS_BEFORE[mo - 1]) if mo < 12 else 31
		var sum_cover := 0.0
		var n := 0
		var rainy_hours := 0
		for d in range(1, days + 1):
			for h in range(0, 24):
				var c: float = ws.cloud_cover_frac(mo, d, float(h))
				if not is_nan(c):
					sum_cover += c
					n += 1
					if c > cloudiest_cover:
						cloudiest_cover = c
						cloudiest = [mo, d, float(h)]
				var r: float = ws.rain_rate_mmh(mo, d, float(h))
				if not is_nan(r):
					if r > 0.1:
						rainy_hours += 1
					if r > rainiest_rate:
						rainiest_rate = r
						rainiest = [mo, d, float(h)]
		var avg := (sum_cover / float(n)) if n > 0 else 0.0
		if avg > 0.5:
			months_over_half += 1
		print("  %s: avg cloud %.0f%%, %d rainy hours" % [MONTH_NAMES[mo - 1], avg * 100.0, rainy_hours])

	print("SMOKETEST cloudiest: %s %d hr%02d (%.0f%% cover)" %
		[MONTH_NAMES[int(cloudiest[0]) - 1], int(cloudiest[1]), int(cloudiest[2]), cloudiest_cover * 100.0])
	print("SMOKETEST rainiest:  %s %d hr%02d (%.2f mm/h)" %
		[MONTH_NAMES[int(rainiest[0]) - 1], int(rainiest[1]), int(rainiest[2]), rainiest_rate])

	# A PNW year must contain heavily clouded months and real rain, otherwise
	# either the data or the parsing is wrong.
	var ok := months_over_half >= 2 and cloudiest_cover > 0.8 and rainiest_rate > 0.5
	print("SMOKETEST %s" % ("PASS" if ok else "FAIL: insufficient weather variety"))
	quit(0 if ok else 1)


## Connect listeners up front and return the shared result holder.
func _arm_listener(ws: Node) -> Array:
	var result: Array = ["pending", null]
	ws.weather_data_ready.connect(func(_la: float, _lo: float, _y: int) -> void:
		if result[0] == "pending":
			result[0] = "ready")
	ws.weather_fetch_failed.connect(func(reason: String) -> void:
		if result[0] == "pending":
			result[0] = "failed"
			result[1] = reason)
	return result


func _await_listener(result: Array) -> Array:
	var waited := 0.0
	while result[0] == "pending" and waited < 60.0:
		await create_timer(0.25).timeout
		waited += 0.25
	if result[0] == "pending":
		result[0] = "failed"
		result[1] = "timeout after 60s"
	return result
