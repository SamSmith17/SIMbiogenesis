class_name HazardRiskProfile
extends RefCounted

## "What is this site actually at risk for?" — computed from the site's own
## record rather than guessed.
##
## Primary source: the NWS/IEM VTEC alert history for the site's UGC zone, which
## NwsAlertService already fetches back to 1986 (it was display-only until now).
## Forty years of "this zone got 14 Dense Smoke advisories" is a far better
## answer than any heuristic, and it is data the project already pays to load.
##
## Fallback: climatology derived from WeatherService's loaded year. This is NOT
## an edge case — the location picker puts maps anywhere on Earth, and every
## non-US site takes this path, so it is built and tested alongside the primary
## one. It is labelled as an estimate everywhere it surfaces, so it never
## masquerades as observed record.
##
## Pure static over plain arrays/dicts: the caller hands in already-fetched
## alert rows, so the whole thing runs in an offline selftest against a canned
## IEM fixture with no HTTP, no autoload and no scene tree.

## IEM's VTEC record effectively begins here.
const HIST_FIRST_YEAR := 1986

## An alert shorter than this is a bookkeeping artifact (an amended or
## immediately-cancelled product), not an event someone lived through.
const MIN_EVENT_HOURS := 0.5

## Guards a pathological fixture from dominating the per-decade rate.
const MAX_EVENT_HOURS := 24.0 * 14.0


## events_by_year: {int year -> Array[Dictionary]} exactly as
## NwsAlertService.get_alert_events_for_year returns.
## Each row is expected to carry `onset_abs`, `expires_abs`, `event`, and —
## after the additive fix to _parse_iem_event — `phenomena`/`significance`.
##
## Returns {hazard_id -> {count, hours_total, events_per_decade, worst_year,
##          worst_hours, last_year, month_histogram (12 ints), level, source}}
## for EVERY catalog hazard, including those with no history: the settings tab
## must be able to say "not observed here" rather than omitting the row.
static func from_vtec_history(events_by_year: Dictionary,
		from_year: int = HIST_FIRST_YEAR, to_year: int = 0) -> Dictionary:
	var out := _empty_profile("vtec")
	if events_by_year.is_empty():
		return out

	var years: Array = events_by_year.keys()
	years.sort()
	var lo := from_year
	var hi := to_year
	if hi <= 0:
		hi = int(years[years.size() - 1])
	if lo <= 0:
		lo = int(years[0])
	var span_years := maxf(1.0, float(hi - lo + 1))

	# Per-year hour tallies, so "worst year" means the year with the most
	# hours under this hazard rather than the most separate advisories — one
	# 200-hour smoke siege matters more than ten brief ones.
	var per_year: Dictionary = {}   # hazard_id -> {year -> hours}

	for year_v: Variant in events_by_year.keys():
		var year := int(year_v)
		var rows: Variant = events_by_year[year_v]
		if not (rows is Array):
			continue
		for row_v: Variant in (rows as Array):
			if not (row_v is Dictionary):
				continue
			var row := row_v as Dictionary
			var id := HazardCatalog.id_for_alert(
				str(row.get("phenomena", "")), str(row.get("event", "")))
			if id.is_empty() or not out.has(id):
				continue
			var hours := _event_hours(row)
			if hours < MIN_EVENT_HOURS:
				continue

			var e: Dictionary = out[id]
			e["count"] = int(e["count"]) + 1
			e["hours_total"] = float(e["hours_total"]) + hours
			e["last_year"] = maxi(int(e["last_year"]), year)

			var m := _event_month(row)
			if m >= 1 and m <= 12:
				var hist: Array = e["month_histogram"]
				hist[m - 1] = int(hist[m - 1]) + 1

			if not per_year.has(id):
				per_year[id] = {}
			var py: Dictionary = per_year[id]
			py[year] = float(py.get(year, 0.0)) + hours

	for id: String in out.keys():
		var e: Dictionary = out[id]
		var count := int(e["count"])
		e["events_per_decade"] = (float(count) / span_years) * 10.0
		e["level"] = HazardCatalog.risk_level_for_rate(float(e["events_per_decade"]))
		if per_year.has(id):
			var worst_year := 0
			var worst_hours := 0.0
			for y_v: Variant in (per_year[id] as Dictionary).keys():
				var h := float((per_year[id] as Dictionary)[y_v])
				if h > worst_hours:
					worst_hours = h
					worst_year = int(y_v)
			e["worst_year"] = worst_year
			e["worst_hours"] = worst_hours
	return out


## Climatology fallback for sites with no NWS zone (everywhere outside the US)
## or with the alert history unavailable. `stats` is a plain dict so this stays
## offline-testable:
##   {annual_precip_mm, max_month_wind_ms, longest_dry_days, summer_max_c,
##    winter_min_c, annual_snow_cm, max_rain_24h_mm, hours_above_35c,
##    latitude, min_elevation_m}
## Missing keys degrade to RISK_UNKNOWN for the hazards that need them, which
## the UI renders as an empty bar plus "unknown", never as "safe".
static func from_climatology(stats: Dictionary) -> Dictionary:
	var out := _empty_profile("climatology")
	for id: String in out.keys():
		(out[id] as Dictionary)["level"] = HazardCatalog.RISK_UNKNOWN

	# Dust: arid ground plus wind strong enough to lift it. Saltation threshold
	# for loose dry soil is ~6-8 m/s at 10 m (Bagnold 1941; Shao 2008).
	var precip := _num(stats, "annual_precip_mm")
	var wind := _num(stats, "max_month_wind_ms")
	if is_finite(precip) and is_finite(wind):
		_set_level(out, "dust_storm", _band(
			precip < 250.0 and wind > 8.0, precip < 500.0 and wind > 6.5))

	# Wildfire smoke: a long dry spell plus real summer heat.
	var dry := _num(stats, "longest_dry_days")
	var smax := _num(stats, "summer_max_c")
	if is_finite(dry) and is_finite(smax):
		_set_level(out, "wildfire_smoke", _band(
			dry > 30.0 and smax > 30.0, dry > 18.0 and smax > 26.0))

	if is_finite(wind):
		_set_level(out, "damaging_winds", _band(wind > 14.0, wind > 9.0))

	var hot_hours := _num(stats, "hours_above_35c")
	if is_finite(hot_hours):
		_set_level(out, "heatwave", _band(hot_hours > 200.0, hot_hours > 40.0))

	var wmin := _num(stats, "winter_min_c")
	var snow := _num(stats, "annual_snow_cm")
	if is_finite(wmin):
		_set_level(out, "cold_snap", _band(wmin < -20.0, wmin < -10.0))
		if is_finite(snow):
			_set_level(out, "blizzard", _band(
				snow > 100.0 and wmin < -10.0, snow > 25.0 and wmin < -2.0))
		# Ice storms need a freeze/thaw straddle, not deep cold — the coldest
		# places get snow instead of freezing rain.
		_set_level(out, "ice_storm", _band(
			wmin < -5.0 and wmin > -20.0, wmin < 0.0 and wmin > -25.0))

	var rain24 := _num(stats, "max_rain_24h_mm")
	if is_finite(rain24):
		_set_level(out, "flooding", _band(rain24 > 100.0, rain24 > 50.0))

	# Tropical cyclones need warm ocean AND a coast. Latitude alone is not
	# enough, and we only have elevation as a weak coastal proxy — so this stays
	# UNKNOWN unless both agree, rather than telling an inland desert site it is
	# at hurricane risk because it happens to sit at 25 degrees.
	var lat := _num(stats, "latitude")
	var min_elev := _num(stats, "min_elevation_m")
	if is_finite(lat) and is_finite(min_elev):
		var tropical := absf(lat) >= 8.0 and absf(lat) <= 35.0
		var coastal := min_elev < 10.0
		if tropical and coastal:
			_set_level(out, "damaging_winds", HazardCatalog.RISK_HIGH)
			_set_level(out, "storm_surge", HazardCatalog.RISK_HIGH)
		elif coastal:
			_set_level(out, "storm_surge", HazardCatalog.RISK_LOW)
		else:
			_set_level(out, "storm_surge", HazardCatalog.RISK_NONE)

	# A blackout is a consequence, never an observation. Every grid-connected
	# site carries some risk, so this is derived rather than measured.
	_set_level(out, "blackout", HazardCatalog.RISK_MODERATE)
	# Severe convective hail is not derivable from the monthly aggregates we
	# have; saying "unknown" is honest, and guessing would not be.
	return out


## Merge: VTEC where the record actually observed something, climatology to
## fill hazards the alert record cannot speak to. A zone with 40 years of
## history genuinely showing zero dust storms is evidence, so an OBSERVED
## zero is kept — climatology only fills RISK_UNKNOWN rows and hazards with no
## VTEC codes at all (blackout, and hail, whose SV code sweeps in every severe
## thunderstorm).
static func merge(vtec: Dictionary, climo: Dictionary) -> Dictionary:
	if vtec.is_empty():
		return climo
	if climo.is_empty():
		return vtec
	var out := vtec.duplicate(true)
	for id: String in out.keys():
		if not climo.has(id):
			continue
		var e: Dictionary = out[id]
		var no_codes := (HazardCatalog.get_def(id).get("vtec", []) as Array).is_empty()
		if str(e.get("level", "")) == HazardCatalog.RISK_UNKNOWN or no_codes:
			e["level"] = str((climo[id] as Dictionary).get("level", HazardCatalog.RISK_UNKNOWN))
			e["source"] = "climatology"
	return out


## One-line summary for the settings row, e.g.
## "14.2/decade · worst 2020 (218 h)" or "not observed here".
static func summary_line(entry: Dictionary) -> String:
	var level := str(entry.get("level", HazardCatalog.RISK_UNKNOWN))
	if level == HazardCatalog.RISK_UNKNOWN:
		return "no local record"
	var count := int(entry.get("count", 0))
	if count <= 0:
		if str(entry.get("source", "")) == "climatology":
			return "estimated from climate"
		return "not observed here"
	var parts: Array[String] = ["%.1f/decade" % float(entry.get("events_per_decade", 0.0))]
	var worst_year := int(entry.get("worst_year", 0))
	if worst_year > 0:
		parts.append("worst %d (%d h)" % [worst_year, int(round(float(entry.get("worst_hours", 0.0))))])
	elif int(entry.get("last_year", 0)) > 0:
		parts.append("last %d" % int(entry.get("last_year", 0)))
	return " · ".join(parts)


## Hazards ordered for display: riskiest first, then alphabetical by label so
## the list is stable between refreshes.
static func sorted_ids(profile: Dictionary) -> Array[String]:
	var ids := HazardCatalog.ids()
	ids.sort_custom(func(a: String, b: String) -> bool:
		var fa := HazardCatalog.risk_fill(str((profile.get(a, {}) as Dictionary).get("level", "")))
		var fb := HazardCatalog.risk_fill(str((profile.get(b, {}) as Dictionary).get("level", "")))
		if not is_equal_approx(fa, fb):
			return fa > fb
		return HazardCatalog.display_name(a) < HazardCatalog.display_name(b))
	return ids


## --- internals ---------------------------------------------------------------

static func _empty_profile(source: String) -> Dictionary:
	var out: Dictionary = {}
	for id: String in HazardCatalog.ids():
		out[id] = {
			"count": 0,
			"hours_total": 0.0,
			"events_per_decade": 0.0,
			"worst_year": 0,
			"worst_hours": 0.0,
			"last_year": 0,
			"month_histogram": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
			"level": HazardCatalog.RISK_NONE,
			"source": source,
		}
	return out


static func _event_hours(row: Dictionary) -> float:
	var a := float(row.get("onset_abs", NAN))
	var b := float(row.get("expires_abs", NAN))
	if not is_finite(a) or not is_finite(b):
		return 0.0
	return clampf(b - a, 0.0, MAX_EVENT_HOURS)


## Month of onset, for the seasonality histogram that shapes climatology
## synthesis. Prefers a precomputed key so the selftest can hand in fixtures
## without constructing a clock.
static func _event_month(row: Dictionary) -> int:
	if row.has("month"):
		return int(row["month"])
	var a := float(row.get("onset_abs", NAN))
	if not is_finite(a):
		return 0
	var clk := CelestialClock.new()
	var dd: Dictionary = clk.abs_hours_to_date(a)
	return int(dd.get("month", 0))


static func _num(stats: Dictionary, key: String) -> float:
	var v := float(stats.get(key, NAN))
	return v if is_finite(v) else NAN


static func _band(high: bool, moderate: bool) -> String:
	if high:
		return HazardCatalog.RISK_HIGH
	if moderate:
		return HazardCatalog.RISK_MODERATE
	return HazardCatalog.RISK_LOW


static func _set_level(profile: Dictionary, id: String, level: String) -> void:
	if profile.has(id):
		(profile[id] as Dictionary)["level"] = level
