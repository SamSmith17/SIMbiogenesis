class_name SiteReportMetrics
extends RefCounted

## Pure static math for the Site Report feature.
##
## No scene/service access — everything here is deterministic and offline-
## testable (see core/report/site_report_selftest.gd). Two responsibilities:
##   1. Calendar / absolute-hours conversion that matches CelestialClock's
##      proleptic-Gregorian epoch (so evaluate_solar_at lands on the same
##      instant the sim would).
##   2. Aggregation helpers over 8760-length hourly arrays (monthly sums/means/
##      extremes, wet-day counts) plus windrose sector binning and the small
##      derived scalars (peak-sun-hours, capacity factor).

const HOURS_PER_YEAR := 8760
const DAYS_PER_YEAR := 365
const MONTHS := 12
const WET_DAY_MM := 0.1

## Cumulative days before the 1st of each month in a NON-leap year — matches
## WeatherService's 365-day hourly indexing model (leap Feb 29 is skipped).
const DAYS_BEFORE_MONTH: Array[int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
const DAYS_BEFORE_MONTH_EXT: Array[int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365]
const MONTH_ABBR: Array[String] = [
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

const _SECTORS_16: Array[String] = [
	"N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
	"S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
]
const _SECTORS_8: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]


# ---------------------------------------------------------------------------
# Calendar / absolute-hours (mirrors CelestialClock proleptic Gregorian)
# ---------------------------------------------------------------------------

static func is_leap_year(y: int) -> bool:
	return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)


static func days_in_month(m: int, y: int) -> int:
	match clampi(m, 1, 12):
		1, 3, 5, 7, 8, 10, 12:
			return 31
		4, 6, 9, 11:
			return 30
		2:
			return 29 if is_leap_year(y) else 28
		_:
			return 31


## Days elapsed before Jan 1 of year `y` (proleptic Gregorian, year 1 = 0 days).
static func days_before_year(y: int) -> int:
	var yy := y - 1
	return 365 * yy + yy / 4 - yy / 100 + yy / 400


static func day_of_year(y: int, m: int, d: int) -> int:
	var days := 0
	for mm in range(1, clampi(m, 1, 12)):
		days += days_in_month(mm, y)
	return days + d


## Absolute hours since year 1 Jan 1 00:00 for an explicit calendar instant.
## Same epoch as CelestialClock.get_absolute_hours(), so the value can be fed to
## SolarUI.evaluate_solar_at()/clock.abs_hours_to_date() round-trip.
static func date_to_abs_hours(y: int, m: int, d: int, day_time: float) -> float:
	var doy := day_of_year(y, m, d)
	return float(days_before_year(y) + (doy - 1)) * 24.0 + day_time


## (month, day) 1-based for a 0-based non-leap day-of-year (0..364).
static func month_day_from_doy(doy: int) -> Vector2i:
	var d := clampi(doy, 0, DAYS_PER_YEAR - 1)
	for mo in range(12):
		if d < DAYS_BEFORE_MONTH_EXT[mo + 1]:
			return Vector2i(mo + 1, d - DAYS_BEFORE_MONTH[mo] + 1)
	return Vector2i(12, 31)


static func hours_in_month(month: int) -> int:
	var m := clampi(month, 1, 12)
	return (DAYS_BEFORE_MONTH_EXT[m] - DAYS_BEFORE_MONTH_EXT[m - 1]) * 24


# ---------------------------------------------------------------------------
# Aggregation over 8760-length hourly arrays (NaN-safe)
# ---------------------------------------------------------------------------

static func monthly_sum(hourly: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(12)
	for mo in range(12):
		var start := DAYS_BEFORE_MONTH_EXT[mo] * 24
		var stop := mini(DAYS_BEFORE_MONTH_EXT[mo + 1] * 24, hourly.size())
		var s := 0.0
		for i in range(start, stop):
			var v := hourly[i]
			if not is_nan(v):
				s += v
		out[mo] = s
	return out


static func monthly_mean(hourly: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(12)
	for mo in range(12):
		var start := DAYS_BEFORE_MONTH_EXT[mo] * 24
		var stop := mini(DAYS_BEFORE_MONTH_EXT[mo + 1] * 24, hourly.size())
		var s := 0.0
		var n := 0
		for i in range(start, stop):
			var v := hourly[i]
			if not is_nan(v):
				s += v
				n += 1
		out[mo] = s / float(n) if n > 0 else NAN
	return out


static func monthly_min(hourly: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(12)
	for mo in range(12):
		var start := DAYS_BEFORE_MONTH_EXT[mo] * 24
		var stop := mini(DAYS_BEFORE_MONTH_EXT[mo + 1] * 24, hourly.size())
		var lo := INF
		for i in range(start, stop):
			var v := hourly[i]
			if not is_nan(v):
				lo = minf(lo, v)
		out[mo] = lo if is_finite(lo) else NAN
	return out


static func monthly_max(hourly: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(12)
	for mo in range(12):
		var start := DAYS_BEFORE_MONTH_EXT[mo] * 24
		var stop := mini(DAYS_BEFORE_MONTH_EXT[mo + 1] * 24, hourly.size())
		var hi := -INF
		for i in range(start, stop):
			var v := hourly[i]
			if not is_nan(v):
				hi = maxf(hi, v)
		out[mo] = hi if is_finite(hi) else NAN
	return out


static func annual_sum(hourly: PackedFloat32Array) -> float:
	var s := 0.0
	for v in hourly:
		if not is_nan(v):
			s += v
	return s


static func annual_mean(hourly: PackedFloat32Array) -> float:
	var s := 0.0
	var n := 0
	for v in hourly:
		if not is_nan(v):
			s += v
			n += 1
	return s / float(n) if n > 0 else NAN


## Per-month count of days whose total precipitation (mm) meets `threshold`.
static func monthly_wet_days(precip_hourly: PackedFloat32Array,
		threshold: float = WET_DAY_MM) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(12)
	for mo in range(12):
		var wet := 0
		var d0 := DAYS_BEFORE_MONTH_EXT[mo]
		var d1 := DAYS_BEFORE_MONTH_EXT[mo + 1]
		for doy in range(d0, d1):
			var day_sum := 0.0
			for h in range(24):
				var idx := doy * 24 + h
				if idx < precip_hourly.size():
					var v := precip_hourly[idx]
					if not is_nan(v):
						day_sum += maxf(v, 0.0)
			if day_sum >= threshold:
				wet += 1
		out[mo] = wet
	return out


# ---------------------------------------------------------------------------
# Derived scalars
# ---------------------------------------------------------------------------

## Average daily insolation (peak-sun-hours) from annual kWh/m² total.
static func peak_sun_hours(annual_kwh_m2: float) -> float:
	return annual_kwh_m2 / float(DAYS_PER_YEAR)


## Annual capacity factor = produced kWh / (nameplate kW × 8760 h).
static func capacity_factor(annual_kwh: float, peak_kw: float) -> float:
	if peak_kw <= 0.0:
		return 0.0
	return clampf(annual_kwh / (peak_kw * float(HOURS_PER_YEAR)), 0.0, 1.0)


# ---------------------------------------------------------------------------
# Windrose
# ---------------------------------------------------------------------------

## Meteorological direction (0 = N, 90 = E) → sector index [0, num_sectors).
## Sectors are centred on the compass points (N spans -half..+half).
static func windrose_sector_index(dir_deg: float, num_sectors: int) -> int:
	var n := maxi(num_sectors, 1)
	var width := 360.0 / float(n)
	var a := fmod(dir_deg + width * 0.5, 360.0)
	if a < 0.0:
		a += 360.0
	return int(a / width) % n


static func sector_labels(num_sectors: int) -> PackedStringArray:
	if num_sectors == 8:
		return PackedStringArray(_SECTORS_8)
	if num_sectors == 16:
		return PackedStringArray(_SECTORS_16)
	var out := PackedStringArray()
	var width := 360.0 / float(maxi(num_sectors, 1))
	for i in range(maxi(num_sectors, 1)):
		out.append("%d°" % int(round(float(i) * width)))
	return out
