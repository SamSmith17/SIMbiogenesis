class_name LakeGauge
extends RefCounted

## A lake's surface level through time, from a USGS gauge (pure: parsing,
## the datum shift and the level at a date — the HTTP lives in
## ShorelineHistory).
##
## Source: USGS NWIS daily values,
##   https://waterservices.usgs.gov/nwis/dv/?sites=<id>&parameterCd=<p>&startDT=&endDT=&format=json
## Parameter 62614 is "Lake or reservoir water surface elevation above NGVD
## 1929, ft", 62615 the same above NAVD 1988. The Salton Sea's gauge
## (10254005, "Salton Sea near Westmorland") runs 1987-10-01 (-228.20 ft) to
## today (-244.00 ft on 2026-09-22) — 14 237 days.
##
## THE DATUM. US DEMs (3DEP / NED, so the Terrarium tiles and USGS 10 m too)
## are NAVD88 heights; the gauge reads NGVD29. The shift is NOT a constant
## across the country (it runs from about -0.5 m to +1.6 m), so it is asked of
## NOAA's NCAT service (VERTCON 3.0) at the GAUGE's position:
##   https://geodesy.noaa.gov/api/ncat/llh?lat=&lon=&orthoHt=0&inDatum=NAD83(1986)&outDatum=NAD83(1986)&inVertDatum=NGVD29&outVertDatum=NAVD88
## The gauge position, not the site's: a lake surface is level, so its true
## height is the gauge's reading shifted where the gauge stands. NGVD29 is the
## distorted datum — measured 2026-10-23 the shift is +0.534 m at the Salton
## Sea gauge and +0.682 m at Bombay Beach 22 km north, and only the first is
## the water's height. Offline, KNOWN carries that measured value.
##
## Time axis: whole ABSOLUTE DAYS on CelestialClock's epoch (days since year 1
## Jan 1, proleptic Gregorian) — floor(abs_hours / 24) — so the level is a
## pure function of the clock and scrubs backwards for free.

const FT_TO_M := 0.3048
const PARAM_NGVD29 := "62614"
const PARAM_NAVD88 := "62615"
const DV_URL := "https://waterservices.usgs.gov/nwis/dv/?sites=%s&parameterCd=%s&startDT=%s&endDT=%s&format=json"
## Lakes with surface-elevation daily values inside a bbox (west,south,east,north).
const SITE_URL := "https://waterservices.usgs.gov/nwis/site/?format=rdb&bBox=%.4f,%.4f,%.4f,%.4f&siteType=LK&outputDataTypeCd=dv&parameterCd=62614,62615&seriesCatalogOutput=true"
const NCAT_URL := "https://geodesy.noaa.gov/api/ncat/llh?lat=%.6f&lon=%.6f&orthoHt=0&inDatum=NAD83(1986)&outDatum=NAD83(1986)&inVertDatum=NGVD29&outVertDatum=NAVD88"
## A gauge further than this from the site is somebody else's lake.
const SEARCH_RADIUS_KM := 45.0
## The earliest day asked for (the series is usually much younger).
const START_DATE := "1900-01-01"

## Gauges known without asking, with their measured NGVD29 → NAVD88 shift.
## {id, param, name, lat, lon, shift_m (VERTCON at the gauge, metres)}
const KNOWN := [
	{"id": "10254005", "param": PARAM_NGVD29, "name": "Salton Sea near Westmorland",
		"lake": "Salton Sea", "lat": 33.15375, "lon": -115.673103, "shift_m": 0.534},
]


## Absolute day (CelestialClock's epoch) of a calendar date.
static func abs_day(y: int, m: int, d: int) -> int:
	var yy := y - 1
	var before := 365 * yy + yy / 4 - yy / 100 + yy / 400
	var leap := (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
	var cum := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
	var doy := int(cum[clampi(m, 1, 12) - 1]) + d
	if leap and m > 2:
		doy += 1
	return before + doy - 1


## Absolute day of "YYYY-MM-DD…" (the first ten characters); -1 if unreadable.
static func abs_day_of(date_str: String) -> int:
	var s := date_str.strip_edges()
	if s.length() < 10:
		return -1
	var y := s.substr(0, 4).to_int()
	var m := s.substr(5, 2).to_int()
	var d := s.substr(8, 2).to_int()
	if y <= 0 or m < 1 or m > 12 or d < 1 or d > 31:
		return -1
	return abs_day(y, m, d)


## "YYYY-MM-DD" of an absolute day.
static func date_of(day: int) -> String:
	var y := int(floor(float(day) / 365.2425)) + 1
	while abs_day(y, 1, 1) > day:
		y -= 1
	while abs_day(y + 1, 1, 1) <= day:
		y += 1
	var m := 12
	while m > 1 and abs_day(y, m, 1) > day:
		m -= 1
	return "%04d-%02d-%02d" % [y, m, day - abs_day(y, m, 1) + 1]


## The gauge's daily series from an NWIS dv JSON body:
## {ok, name, unit, param, days PackedInt32Array, ft PackedFloat64Array,
##  first, last ("YYYY-MM-DD"), provisional_from ("" when none), reason}.
## Days are ascending; missing / no-data values (-999999, "") are skipped.
static func parse_dv_json(body: String) -> Dictionary:
	var out := {"ok": false, "days": PackedInt32Array(), "ft": PackedFloat64Array(),
		"name": "", "unit": "", "param": "", "first": "", "last": "", "provisional_from": "", "reason": ""}
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		out["reason"] = "not JSON"
		return out
	var ts: Array = ((parsed as Dictionary).get("value", {}) as Dictionary).get("timeSeries", []) as Array
	if ts.is_empty():
		out["reason"] = "no time series"
		return out
	var t: Dictionary = ts[0]
	out["name"] = str((t.get("sourceInfo", {}) as Dictionary).get("siteName", ""))
	var var_d: Dictionary = t.get("variable", {})
	out["unit"] = str((var_d.get("unit", {}) as Dictionary).get("unitCode", ""))
	var codes: Array = var_d.get("variableCode", [])
	if not codes.is_empty() and codes[0] is Dictionary:
		out["param"] = str((codes[0] as Dictionary).get("value", ""))
	var no_data := float(var_d.get("noDataValue", -999999.0))
	var pairs: Array = []
	var prov := ""
	for block_v in t.get("values", []):
		if not (block_v is Dictionary):
			continue
		for v_v in (block_v as Dictionary).get("value", []):
			if not (v_v is Dictionary):
				continue
			var v: Dictionary = v_v
			var s := str(v.get("value", "")).strip_edges()
			if s.is_empty() or not s.is_valid_float():
				continue
			var x := s.to_float()
			if is_equal_approx(x, no_data) or x <= -99999.0:
				continue
			var day := abs_day_of(str(v.get("dateTime", "")))
			if day < 0:
				continue
			pairs.append([day, x])
			if prov.is_empty() and "P" in (v.get("qualifiers", []) as Array):
				prov = str(v.get("dateTime", "")).substr(0, 10)
	if pairs.is_empty():
		out["reason"] = "no values"
		return out
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	var days := PackedInt32Array()
	var ft := PackedFloat64Array()
	for p in pairs:
		if not days.is_empty() and days[days.size() - 1] == int(p[0]):
			ft[ft.size() - 1] = float(p[1])
			continue
		days.append(int(p[0]))
		ft.append(float(p[1]))
	out["days"] = days
	out["ft"] = ft
	out["first"] = date_of(days[0])
	out["last"] = date_of(days[days.size() - 1])
	out["provisional_from"] = prov
	out["ok"] = true
	return out


## The level (in the series' own unit) at an absolute day: linear between the
## two readings round it, the first / last reading held outside the record.
## {ft, inside (day within the record), gap_days (to the nearest reading)}.
static func level_at(days: PackedInt32Array, ft: PackedFloat64Array, day: float) -> Dictionary:
	var n := mini(days.size(), ft.size())
	if n == 0:
		return {"ft": NAN, "inside": false, "gap_days": INF}
	if day <= float(days[0]):
		return {"ft": ft[0], "inside": is_equal_approx(day, float(days[0])), "gap_days": float(days[0]) - day}
	if day >= float(days[n - 1]):
		return {"ft": ft[n - 1], "inside": is_equal_approx(day, float(days[n - 1])),
			"gap_days": day - float(days[n - 1])}
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if float(days[mid]) <= day:
			lo = mid
		else:
			hi = mid
	var d0 := float(days[lo])
	var d1 := float(days[hi])
	var f := (day - d0) / maxf(d1 - d0, 1.0)
	return {"ft": lerpf(ft[lo], ft[hi], f), "inside": true, "gap_days": minf(day - d0, d1 - day)}


## Metres in the DEM's datum (NAVD88) from a reading in feet: NGVD29 readings
## get the VERTCON shift, NAVD88 readings none.
static func navd88_m(reading_ft: float, param: String, shift_m: float) -> float:
	var m := reading_ft * FT_TO_M
	return m + shift_m if param == PARAM_NGVD29 else m


## The NGVD29 → NAVD88 shift (m) from an NCAT reply; NAN when unreadable.
static func parse_ncat_shift(body: String) -> float:
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return NAN
	var d: Dictionary = parsed
	var src := str(d.get("srcOrthoht", "")).replace(",", "")
	var dst := str(d.get("destOrthoht", "")).replace(",", "")
	if not src.is_valid_float() or not dst.is_valid_float():
		return NAN
	return dst.to_float() - src.to_float()


## Lake gauges in an NWIS site RDB reply (seriesCatalogOutput): one record per
## site, preferring its NAVD88 series, with the record's span.
## [{id, name, lat, lon, param, begin, end, count}]
static func parse_site_rdb(body: String) -> Array:
	var header: PackedStringArray = []
	var rows: Array = []
	var saw_header := false
	var skipped_widths := false
	for raw in body.split("\n"):
		var line := raw.strip_edges(false, true)
		if line.is_empty() or line.begins_with("#"):
			continue
		var cols := line.split("\t")
		if not saw_header:
			header = cols
			saw_header = true
			continue
		if not skipped_widths:
			skipped_widths = true   # the "5s 15s …" column-format line
			continue
		var rec := {}
		for i in mini(cols.size(), header.size()):
			rec[header[i]] = cols[i]
		rows.append(rec)
	var by_site: Dictionary = {}
	for r_v in rows:
		var r: Dictionary = r_v
		var p := str(r.get("parm_cd", ""))
		if p != PARAM_NGVD29 and p != PARAM_NAVD88:
			continue
		if str(r.get("data_type_cd", "dv")) != "dv":
			continue
		var id := str(r.get("site_no", ""))
		if id.is_empty():
			continue
		var cand := {"id": id, "name": str(r.get("station_nm", "")),
			"lat": str(r.get("dec_lat_va", "")).to_float(), "lon": str(r.get("dec_long_va", "")).to_float(),
			"param": p, "begin": str(r.get("begin_date", "")), "end": str(r.get("end_date", "")),
			"count": str(r.get("count_nu", "0")).to_int()}
		if not by_site.has(id) or (p == PARAM_NAVD88 and str((by_site[id] as Dictionary)["param"]) != PARAM_NAVD88):
			by_site[id] = cand
	return by_site.values()


## Great-circle distance (km).
static func distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	var p1 := deg_to_rad(lat1)
	var p2 := deg_to_rad(lat2)
	var dp := p2 - p1
	var dl := deg_to_rad(lon2 - lon1)
	var a := sin(dp * 0.5) * sin(dp * 0.5) + cos(p1) * cos(p2) * sin(dl * 0.5) * sin(dl * 0.5)
	return 6371.0088 * 2.0 * atan2(sqrt(a), sqrt(1.0 - a))


## The gauge for a site: the nearest candidate within SEARCH_RADIUS_KM, with the
## most days on a tie; KNOWN entries carry their shift. {} when none.
static func pick_gauge(candidates: Array, lat: float, lon: float) -> Dictionary:
	var best := {}
	var best_d := INF
	for c_v in candidates:
		if not (c_v is Dictionary):
			continue
		var c: Dictionary = c_v
		var d := distance_km(lat, lon, float(c.get("lat", 0.0)), float(c.get("lon", 0.0)))
		if d > SEARCH_RADIUS_KM:
			continue
		if d < best_d - 0.01 or (absf(d - best_d) <= 0.01 and int(c.get("count", 0)) > int(best.get("count", 0))):
			best = c.duplicate()
			best_d = d
	if best.is_empty():
		return {}
	best["distance_km"] = best_d
	for k_v in KNOWN:
		var k: Dictionary = k_v
		if str(k["id"]) == str(best["id"]):
			for key in k.keys():
				if not best.has(key) or key == "shift_m" or key == "lake":
					best[key] = k[key]
	return best


## The known gauge for a site without any network ({} when none is in range).
static func known_gauge_for(lat: float, lon: float) -> Dictionary:
	return pick_gauge(KNOWN, lat, lon)


static func dv_url(gauge: Dictionary, end_date: String) -> String:
	return DV_URL % [str(gauge.get("id", "")), str(gauge.get("param", PARAM_NGVD29)), START_DATE, end_date]


static func site_search_url(lat: float, lon: float) -> String:
	var dlat := SEARCH_RADIUS_KM / 111.0
	var dlon := dlat / maxf(cos(deg_to_rad(lat)), 0.2)
	return SITE_URL % [lon - dlon, lat - dlat, lon + dlon, lat + dlat]


static func ncat_url(lat: float, lon: float) -> String:
	return NCAT_URL % [lat, lon]
