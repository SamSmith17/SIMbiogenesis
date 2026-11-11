class_name GapMeter
extends RefCounted

## What a gap node did over sim time (resource composition plan Phase 8):
## the CampFlowMeter pattern. Fed once per flow step with the gap's rates,
## integrated into HOURLY bins for the last week (peaks, the shape of a day,
## the duty cycle) and DAILY bins for the last year (the seasons). Keys:
##   in:<kind>, out:<kind>     qty
##   el_in:<E>, el_out:<E>     kg of a tracked element (DesignGap.TRACK)
##   water_in, water_out       kg of water
##   res_kg, short_kg          kg of elements left over / lacked
##   wh                        energy drawn (with a target)
##   on                        hours it ran
##   seen                      hours metered
## A scrub back truncates both (the future is re-lived, not remembered); a
## jump over MAX_GAP_H is not metered. Pure and serializable: it rides the
## gap node as `gap_meter`, so the brief survives a reload.

const MAX_HOURS := 24 * 7
const MAX_DAYS := 400
const MAX_GAP_H := 6.0

var start_h := NAN   # absolute hour of hourly bin 0
var start_d := -1    # absolute day of daily bin 0
var last_h := NAN
var _hours: Dictionary = {}   # key -> Array[float]
var _days: Dictionary = {}    # key -> Array[float]
var _folded: Dictionary = {}  # key -> float, days older than MAX_DAYS


## One step: `rates` = {key: per-hour rate} (DesignGap.step's numbers mapped
## by rates_from_step).
func record(abs_h: float, rates: Dictionary) -> void:
	if is_nan(abs_h):
		return
	if is_nan(last_h):
		last_h = abs_h
		return
	if abs_h < last_h - 1e-6:
		truncate_after(abs_h)
		last_h = abs_h
		return
	var dt := abs_h - last_h
	last_h = abs_h
	if dt <= 0.0 or dt > MAX_GAP_H:
		return
	var mid := abs_h - dt * 0.5
	_add("seen", mid, dt)
	for k in rates.keys():
		var q := maxf(float(rates[k]), 0.0) * dt
		if q > 0.0:
			_add(str(k), mid, q)


## The meter's per-hour rates from a DesignGap.step result.
static func rates_from_step(r: Dictionary, in_kinds: Array, out_kinds: Array) -> Dictionary:
	var out := {"on": 1.0 if bool(r.get("running", false)) else 0.0,
		"water_in": float(r.get("water_in", 0.0)), "water_out": float(r.get("water_out", 0.0))}
	var take: Array = r.get("take", [])
	for i in mini(take.size(), in_kinds.size()):
		var k := "in:" + str(in_kinds[i])
		out[k] = float(out.get(k, 0.0)) + float(take[i])
	var give: Array = r.get("give", [])
	for j in mini(give.size(), out_kinds.size()):
		var k2 := "out:" + str(out_kinds[j])
		out[k2] = float(out.get(k2, 0.0)) + float(give[j])
	for e in DesignGap.TRACK:
		out["el_in:" + e] = float((r.get("el_in", {}) as Dictionary).get(e, 0.0))
		out["el_out:" + e] = float((r.get("el_out", {}) as Dictionary).get(e, 0.0))
	var res := 0.0
	for v in (r.get("residue", {}) as Dictionary).values():
		res += float(v)
	var sh := 0.0
	for v2 in (r.get("short", {}) as Dictionary).values():
		sh += float(v2)
	out["res_kg"] = res
	out["short_kg"] = sh
	if float(r.get("power_w", -1.0)) > 0.0:
		out["wh"] = float(r["power_w"])
	return out


func _add(key: String, at_h: float, qty: float) -> void:
	if is_nan(start_h):
		start_h = floorf(at_h)
	var i := int(floor(at_h - start_h))
	if i >= 0:
		var arr: Array = _hours.get(key, [])
		while arr.size() <= i:
			arr.append(0.0)
		arr[i] = float(arr[i]) + qty
		_hours[key] = arr
		_trim_hours()
	var d := int(floor(at_h / 24.0))
	if start_d < 0:
		start_d = d
	var j := d - start_d
	if j < 0:
		return
	var darr: Array = _days.get(key, [])
	while darr.size() <= j:
		darr.append(0.0)
	darr[j] = float(darr[j]) + qty
	_days[key] = darr
	_trim_days()


func _trim_hours() -> void:
	var longest := 0
	for k in _hours.keys():
		longest = maxi(longest, (_hours[k] as Array).size())
	var drop := longest - MAX_HOURS
	if drop <= 0:
		return
	for k in _hours.keys():
		_hours[k] = (_hours[k] as Array).slice(mini(drop, (_hours[k] as Array).size()))
	start_h += float(drop)


func _trim_days() -> void:
	var longest := 0
	for k in _days.keys():
		longest = maxi(longest, (_days[k] as Array).size())
	var drop := longest - MAX_DAYS
	if drop <= 0:
		return
	for k in _days.keys():
		var arr: Array = _days[k]
		var n := mini(drop, arr.size())
		var s := 0.0
		for j in n:
			s += float(arr[j])
		_folded[k] = float(_folded.get(k, 0.0)) + s
		_days[k] = arr.slice(n)
	start_d += drop


## Forget everything metered after `abs_h` (a scrub back).
func truncate_after(abs_h: float) -> void:
	if not is_nan(start_h):
		var keep := maxi(int(ceil(abs_h - start_h)), 0)
		for k in _hours.keys():
			if (_hours[k] as Array).size() > keep:
				_hours[k] = (_hours[k] as Array).slice(0, keep)
	if start_d >= 0:
		var keep_d := maxi(int(ceil(abs_h / 24.0)) - start_d, 0)
		for k2 in _days.keys():
			if (_days[k2] as Array).size() > keep_d:
				_days[k2] = (_days[k2] as Array).slice(0, keep_d)


func clear() -> void:
	start_h = NAN
	start_d = -1
	last_h = NAN
	_hours = {}
	_days = {}
	_folded = {}


func total(key: String) -> float:
	var s := float(_folded.get(key, 0.0))
	for v in (_days.get(key, []) as Array):
		s += float(v)
	return s


## Hours metered.
func hours() -> float:
	return total("seen")


## The mean per day over everything metered.
func per_day(key: String) -> float:
	var h := hours()
	return total(key) / h * 24.0 if h > 1e-6 else 0.0


## Share of the metered hours it ran.
func duty() -> float:
	var h := hours()
	return clampf(total("on") / h, 0.0, 1.0) if h > 1e-6 else 0.0


## The busiest hour in the last week: {rate (per hour), hour_of_day}.
func peak(key: String) -> Dictionary:
	var arr: Array = _hours.get(key, [])
	var best := 0.0
	var at := -1
	for i in arr.size():
		if float(arr[i]) > best:
			best = float(arr[i])
			at = i
	if at < 0:
		return {"rate": 0.0, "hour_of_day": -1}
	return {"rate": best, "hour_of_day": posmod(int(start_h) + at, 24)}


## Mean per day in each calendar month metered: 12 values, NAN = not seen.
func by_month(key: String) -> Array:
	var sums: Array = []
	var days: Array = []
	sums.resize(12)
	days.resize(12)
	for m in 12:
		sums[m] = 0.0
		days[m] = 0.0
	var arr: Array = _days.get(key, [])
	var any: Array = _days.get("seen", [])
	var n := maxi(arr.size(), any.size())
	for j in n:
		var mo := month_of_day(start_d + j) - 1
		sums[mo] = float(sums[mo]) + (float(arr[j]) if j < arr.size() else 0.0)
		days[mo] = float(days[mo]) + (float(any[j]) / 24.0 if j < any.size() else 0.0)
	var out: Array = []
	for m2 in 12:
		out.append(float(sums[m2]) / float(days[m2]) if float(days[m2]) > 0.01 else NAN)
	return out


## Calendar month (1–12) of an absolute day (the CelestialClock epoch).
static func month_of_day(abs_day: int) -> int:
	var y := maxi(int(float(abs_day) / 365.2425) + 1, 1)
	while y > 1 and SiteReportMetrics.days_before_year(y) > abs_day:
		y -= 1
	while SiteReportMetrics.days_before_year(y + 1) <= abs_day:
		y += 1
	var doy := abs_day - SiteReportMetrics.days_before_year(y)
	for m in range(1, 13):
		var dim := SiteReportMetrics.days_in_month(m, y)
		if doy < dim:
			return m
		doy -= dim
	return 12


func to_dict() -> Dictionary:
	return {"start_h": start_h if not is_nan(start_h) else -1.0, "start_d": start_d,
		"last_h": last_h if not is_nan(last_h) else -1.0, "hours": _hours.duplicate(true),
		"days": _days.duplicate(true), "folded": _folded.duplicate(true)}


static func from_dict(d: Dictionary) -> GapMeter:
	var m := GapMeter.new()
	var s := float(d.get("start_h", -1.0))
	var l := float(d.get("last_h", -1.0))
	m.start_h = s if s >= 0.0 else NAN
	m.last_h = l if l >= 0.0 else NAN
	m.start_d = int(d.get("start_d", -1))
	for src in [["hours", m._hours], ["days", m._days]]:
		var b: Variant = d.get(str(src[0]), {})
		if b is Dictionary:
			for k in (b as Dictionary).keys():
				var arr: Array = []
				for v in ((b as Dictionary)[k] as Array):
					arr.append(float(v))
				(src[1] as Dictionary)[str(k)] = arr
	var f: Variant = d.get("folded", {})
	if f is Dictionary:
		for k2 in (f as Dictionary).keys():
			m._folded[str(k2)] = float((f as Dictionary)[k2])
	return m
