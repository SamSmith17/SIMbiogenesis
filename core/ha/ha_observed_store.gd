class_name HaObservedStore
extends RefCounted
## Recorded Home Assistant readings per tracked value (pure, in memory).
##
## Every reading a link sees is kept here in the TARGET's unit, stamped with
## the REAL time it was measured (absolute hours on the clock's epoch, local
## wall time — the same axis as the timeline's NOW marker), whatever the sim
## clock is doing. HA's own recorder fills in the hours before the game was
## running (history/history_during_period), so the timeline can show "what
## really happened" next to the simulation for the last few days.
##
## Per key: sorted times + values, capped at MAX_SAMPLES (oldest dropped).

const MAX_SAMPLES := 20000

var _t: Dictionary = {}   # key -> PackedFloat64Array (abs hours)
var _v: Dictionary = {}   # key -> PackedFloat32Array


func add(key: String, t_abs: float, v: float) -> void:
	if not _t.has(key):
		_t[key] = PackedFloat64Array()
		_v[key] = PackedFloat32Array()
	var ts: PackedFloat64Array = _t[key]
	var vs: PackedFloat32Array = _v[key]
	var n := ts.size()
	if n == 0 or t_abs > ts[n - 1]:
		ts.append(t_abs)
		vs.append(v)
	else:
		var i := ts.bsearch(t_abs)
		if i < n and absf(ts[i] - t_abs) < 1e-6:
			vs[i] = v
		else:
			ts.insert(i, t_abs)
			vs.insert(i, v)
	if ts.size() > MAX_SAMPLES:
		var drop := ts.size() - MAX_SAMPLES
		ts = ts.slice(drop)
		vs = vs.slice(drop)
	_t[key] = ts
	_v[key] = vs


func size(key: String) -> int:
	return (_t.get(key, PackedFloat64Array()) as PackedFloat64Array).size()


func clear_key(key: String) -> void:
	_t.erase(key)
	_v.erase(key)


func keys() -> Array:
	return _t.keys()


## Value held at `t_abs` (the last reading at or before it), NAN before the
## first reading or after `max_gap_h` without one.
func value_at(key: String, t_abs: float, max_gap_h: float = 6.0) -> float:
	var ts: PackedFloat64Array = _t.get(key, PackedFloat64Array())
	if ts.is_empty():
		return NAN
	var i := ts.bsearch(t_abs, false) - 1
	if i < 0:
		return NAN
	if t_abs - ts[i] > max_gap_h:
		return NAN
	return float((_v[key] as PackedFloat32Array)[i])


## [first, last] abs hours recorded, or [NAN, NAN].
func range_of(key: String) -> Vector2:
	var ts: PackedFloat64Array = _t.get(key, PackedFloat64Array())
	if ts.is_empty():
		return Vector2(NAN, NAN)
	return Vector2(ts[0], ts[ts.size() - 1])


## `n` bins over [t0, t1): each the mean of the readings in it, else the value
## held from before (zero-order hold, up to `max_gap_h`), else NAN.
func bins(key: String, t0: float, t1: float, n: int, max_gap_h: float = 6.0) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(maxi(n, 0))
	out.fill(NAN)
	var ts: PackedFloat64Array = _t.get(key, PackedFloat64Array())
	if ts.is_empty() or n <= 0 or t1 <= t0:
		return out
	var vs: PackedFloat32Array = _v[key]
	var w := (t1 - t0) / float(n)
	var i := maxi(ts.bsearch(t0, true) - 1, 0)
	var held := NAN
	var held_t := -INF
	if ts[i] < t0:
		held = vs[i]
		held_t = ts[i]
		i += 1
	for b in n:
		var b1 := t0 + w * float(b + 1)
		var sum := 0.0
		var cnt := 0
		while i < ts.size() and ts[i] < b1:
			sum += vs[i]
			cnt += 1
			held = vs[i]
			held_t = ts[i]
			i += 1
		if cnt > 0:
			out[b] = sum / float(cnt)
		elif not is_nan(held) and (t0 + w * float(b)) - held_t <= max_gap_h:
			out[b] = held
	return out


## Absolute hours (local wall time, the timeline's axis) of a Unix time.
static func abs_hours_local(t_unix: float) -> float:
	var tz := Time.get_time_zone_from_system()
	var whole: float = floorf(t_unix)
	var local: int = int(whole) + int(tz.get("bias", 0)) * 60
	var dt := Time.get_datetime_dict_from_unix_time(local)
	var frac: float = t_unix - whole
	var y: int = int(dt["year"])
	var hours: float = float(dt["hour"]) + float(dt["minute"]) / 60.0 + (float(dt["second"]) + frac) / 3600.0
	var yy := y - 1
	var days_before := 365 * yy + yy / 4 - yy / 100 + yy / 400
	var doy := _doy(int(dt["month"]), int(dt["day"]), y)
	return float(days_before + doy - 1) * 24.0 + hours


static func now_abs_hours() -> float:
	return abs_hours_local(Time.get_unix_time_from_system())


static func _doy(m: int, d: int, y: int) -> int:
	var dim := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if (y % 4 == 0 and y % 100 != 0) or y % 400 == 0:
		dim[1] = 29
	var out := d
	for i in m - 1:
		out += int(dim[i])
	return out


## Parse a history row's time: minimal_response rows carry "lu"/"lc" as Unix
## seconds (float) or "last_changed" as ISO text. NAN when neither parses.
static func row_unix(row: Dictionary) -> float:
	for k in ["lu", "lc"]:
		if row.has(k):
			var v: Variant = row[k]
			if v is float or v is int:
				return float(v)
	for k in ["last_changed", "last_updated"]:
		var s := str(row.get(k, ""))
		if not s.is_empty():
			var u := iso_to_unix(s)
			if not is_nan(u):
				return u
	return NAN


## "2026-10-22T12:34:56.123+00:00" / "...Z" → Unix seconds.
static func iso_to_unix(s: String) -> float:
	if s.length() < 19:
		return NAN
	var base := s.substr(0, 19)
	var t := float(Time.get_unix_time_from_datetime_string(base))
	var rest := s.substr(19)
	var frac := 0.0
	if rest.begins_with("."):
		var j := 1
		while j < rest.length() and rest[j].is_valid_int():
			j += 1
		frac = ("0" + rest.substr(0, j)).to_float()
		rest = rest.substr(j)
	if rest.begins_with("+") or rest.begins_with("-"):
		var sgn := 1.0 if rest[0] == "+" else -1.0
		var hh := rest.substr(1, 2).to_int()
		var mm := rest.substr(4, 2).to_int()
		t -= sgn * float(hh * 3600 + mm * 60)
	return t + frac


## ISO text (UTC, "+00:00") for a Unix time — HA's history API wants it.
static func unix_to_iso(t_unix: float) -> String:
	return Time.get_datetime_string_from_unix_time(int(t_unix)) + "+00:00"
