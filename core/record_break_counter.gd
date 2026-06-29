class_name RecordBreakCounter
extends RefCounted

## Pure helpers for comparing daily weather aggregates against all-time record
## thresholds. Shared by ClimateProjectionService (ERA5@14h + CMIP6 delta) and
## WeatherService (hourly generated weather → daily max/min/sum).
##
## IMPROVE(breadcrumbs):
## - Future chart precip record bars (counts already returned in "precip").
## - CMIP6 fallback: daily min/max from full archive hourly, not 14:00 proxy.
## - Tie-break / margin reporting for near-miss days in the record-book detail panel.

const _DAYS_BEFORE_MONTH: Array[int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


## Compare one calendar day's aggregates to the record book entry for that slot.
## Returns {"highs": 0|1, "lows": 0|1, "precip": 0|1}.
static func count_day(rec: Dictionary, daily_high: float, daily_low: float,
		daily_precip: float = NAN) -> Dictionary:
	var out := {"highs": 0, "lows": 0, "precip": 0}
	if rec.is_empty():
		return out
	if rec.has("high") and is_finite(daily_high) and daily_high > float(rec["high"]):
		out["highs"] = 1
	if rec.has("low") and is_finite(daily_low) and daily_low < float(rec["low"]):
		out["lows"] = 1
	if not is_nan(daily_precip) and rec.has("precip") \
			and daily_precip > float(rec["precip"]):
		out["precip"] = 1
	return out


static func accumulate(into: Dictionary, part: Dictionary) -> void:
	into["highs"] = int(into.get("highs", 0)) + int(part.get("highs", 0))
	into["lows"] = int(into.get("lows", 0)) + int(part.get("lows", 0))
	into["precip"] = int(into.get("precip", 0)) + int(part.get("precip", 0))


## Count record-breaking days in one calendar month from hourly series.
## [param get_rec_fn] — Callable(month, day) -> Dictionary (record book slot).
## [param day_covered_fn] — Callable(month, day) -> bool; skip days outside
## generated/planned coverage (e.g. before effective_hoy on the first tranche year).
static func count_month_from_hourly(
		temp_hourly: PackedFloat32Array,
		precip_hourly: PackedFloat32Array,
		month: int,
		get_rec_fn: Callable,
		day_covered_fn: Callable,
) -> Dictionary:
	var out := {"highs": 0, "lows": 0, "precip": 0}
	var days_in_month := _days_in_month(month)
	for day in range(1, days_in_month + 1):
		if not bool(day_covered_fn.call(month, day)):
			continue
		var rec: Dictionary = get_rec_fn.call(month, day) as Dictionary
		if rec.is_empty():
			continue
		var doy := _DAYS_BEFORE_MONTH[clampi(month, 1, 12) - 1] + day - 1
		var tmm := _daily_temp_min_max(temp_hourly, doy)
		var daily_high := tmm.y
		var daily_low := tmm.x
		if is_nan(daily_high) or is_nan(daily_low):
			continue
		var daily_precip := WeatherGenMetrics.day_precip_sum(precip_hourly, doy)
		accumulate(out, count_day(rec, daily_high, daily_low, daily_precip))
	return out


static func _daily_temp_min_max(temp_hourly: PackedFloat32Array, doy: int) -> Vector2:
	var lo := INF
	var hi := -INF
	var n := 0
	for h in range(24):
		var idx := doy * 24 + h
		if idx < temp_hourly.size():
			var v := temp_hourly[idx]
			if not is_nan(v):
				lo = minf(lo, v)
				hi = maxf(hi, v)
				n += 1
	if n == 0:
		return Vector2(NAN, NAN)
	return Vector2(lo, hi)


static func _days_in_month(month: int) -> int:
	match clampi(month, 1, 12):
		2:  return 28
		4, 6, 9, 11:  return 30
		_:  return 31
