class_name ObservedSeries
extends RefCounted

## Resampled "observed data" track — the read-only counterpart to EnergyTimeline.
##
## Takes an uploaded HA datastream (per-role {t_unix, value} sample lists from
## CsvHistoryPlayer) and resamples it onto the SAME fixed-step absolute-hours
## grid EnergyTimeline uses, so the observed stream and a batch-rendered
## simulated stream line up sample-for-sample for split-screen comparison.
##
## Channels: soc_kwh (battery_soc % → kWh), solar_kw (W/kW), load_kw (W/kW).
## Sampling is zero-order-hold (last reading at-or-before the step time), which
## matches how a digital twin holds a sensor value until the next report.

const STEP_HOURS_DEFAULT: float = 1.0 / 60.0   # 1 sample per minute (== EnergyTimeline)

var step_hours: float = STEP_HOURS_DEFAULT
var start_abs_hours: float = 0.0
var end_abs_hours: float = 0.0

var _base_step: int = 0
var _soc: PackedFloat32Array = PackedFloat32Array()
var _solar: PackedFloat32Array = PackedFloat32Array()
var _load: PackedFloat32Array = PackedFloat32Array()
var _has_soc: bool = false
var _has_solar: bool = false
var _has_load: bool = false


func is_empty() -> bool:
	return _soc.is_empty()

func count() -> int:
	return _soc.size()

func has_soc() -> bool:
	return _has_soc

func has_solar() -> bool:
	return _has_solar

func has_load() -> bool:
	return _has_load


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

## Build from role sample lists. `role_samples` maps role id → Array of
## {"t": int(unix), "v": float}. `clock` is a CelestialClock used purely for
## unix→absolute-hours conversion (so the observed window lands on the sim axis).
func build(role_samples: Dictionary, clock: Object, capacity_kwh: float,
		values_in_watts: bool, step: float = STEP_HOURS_DEFAULT) -> void:
	step_hours = step if step > 0.0 else STEP_HOURS_DEFAULT
	_soc = PackedFloat32Array()
	_solar = PackedFloat32Array()
	_load = PackedFloat32Array()
	_has_soc = false
	_has_solar = false
	_has_load = false

	var soc_raw := _to_abs(role_samples.get("battery_soc", []) as Array, clock)
	var solar_raw := _to_abs(role_samples.get("solar", []) as Array, clock)
	var load_raw := _to_abs(role_samples.get("load", []) as Array, clock)
	_has_soc = not soc_raw.is_empty()
	_has_solar = not solar_raw.is_empty()
	_has_load = not load_raw.is_empty()
	if not (_has_soc or _has_solar or _has_load):
		return

	# Union window across all present channels.
	var lo := INF
	var hi := -INF
	for raw: Array in [soc_raw, solar_raw, load_raw]:
		if raw.is_empty():
			continue
		lo = minf(lo, float((raw[0] as Dictionary)["a"]))
		hi = maxf(hi, float((raw[raw.size() - 1] as Dictionary)["a"]))
	if hi <= lo:
		hi = lo + step_hours

	_base_step = int(floor(lo / step_hours))
	var last_step := int(floor(hi / step_hours))
	start_abs_hours = float(_base_step) * step_hours
	end_abs_hours = float(last_step) * step_hours
	var n := last_step - _base_step + 1
	if n < 1:
		n = 1
	_soc.resize(n)
	_solar.resize(n)
	_load.resize(n)

	var cap := maxf(capacity_kwh, 0.001)
	_fill_zoh(_soc, soc_raw, n, func(v: float) -> float:
		return clampf(v / 100.0, 0.0, 1.0) * cap)
	_fill_zoh(_solar, solar_raw, n, func(v: float) -> float:
		return maxf(v / 1000.0 if values_in_watts else v, 0.0))
	_fill_zoh(_load, load_raw, n, func(v: float) -> float:
		return maxf(v / 1000.0 if values_in_watts else v, 0.0))


## Convert a [{t,v}] unix list to a sorted [{a:abs_hours, v}] list.
func _to_abs(samples: Array, clock: Object) -> Array:
	var out: Array = []
	if samples.is_empty() or clock == null or not clock.has_method("unix_to_abs_hours"):
		return out
	for s_v: Variant in samples:
		var s: Dictionary = s_v as Dictionary
		var a: float = float(clock.call("unix_to_abs_hours", int(s.get("t", 0))))
		out.append({"a": a, "v": float(s.get("v", 0.0))})
	out.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return float(p["a"]) < float(q["a"]))
	return out


## Zero-order-hold resample `raw` (sorted by abs hours) onto the grid.
func _fill_zoh(out: PackedFloat32Array, raw: Array, n: int, conv: Callable) -> void:
	if raw.is_empty():
		for i in n:
			out[i] = 0.0
		return
	var ci := 0
	for i in n:
		var step_abs := float(_base_step + i) * step_hours
		while ci + 1 < raw.size() and float((raw[ci + 1] as Dictionary)["a"]) <= step_abs:
			ci += 1
		out[i] = float(conv.call(float((raw[ci] as Dictionary)["v"])))


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

## Interpolated read at abs_hours (clamped to the buffer range).
func sample_at(abs_hours: float) -> Dictionary:
	if is_empty():
		return {"soc_kwh": 0.0, "solar_kw": 0.0, "load_kw": 0.0,
			"has_soc": false, "has_solar": false, "has_load": false}
	var pos := (abs_hours / step_hours) - float(_base_step)
	var i := int(floor(pos))
	var n := _soc.size()
	if i < 0:
		i = 0
		return _index(i)
	if i >= n - 1:
		return _index(n - 1)
	var frac := pos - float(i)
	return {
		"soc_kwh":  lerp(float(_soc[i]),   float(_soc[i + 1]),   frac),
		"solar_kw": lerp(float(_solar[i]), float(_solar[i + 1]), frac),
		"load_kw":  lerp(float(_load[i]),  float(_load[i + 1]),  frac),
		"has_soc": _has_soc, "has_solar": _has_solar, "has_load": _has_load,
	}


func soc_at(abs_hours: float) -> float:
	return float(sample_at(abs_hours).get("soc_kwh", 0.0))


func _index(i: int) -> Dictionary:
	return {
		"soc_kwh":  float(_soc[i]),
		"solar_kw": float(_solar[i]),
		"load_kw":  float(_load[i]),
		"has_soc": _has_soc, "has_solar": _has_solar, "has_load": _has_load,
	}


## kWh in a channel ("solar"/"load") over [abs_start, abs_end] (for daily totals).
func integrate_channel(abs_start: float, abs_end: float, channel: String) -> float:
	if is_empty() or abs_end <= abs_start:
		return 0.0
	var arr := _solar if channel == "solar" else _load
	var g0 := maxi(int(floor(abs_start / step_hours)), _base_step)
	var g1 := mini(int(floor(abs_end / step_hours)), _base_step + arr.size() - 1)
	var total := 0.0
	var g := g0
	while g < g1:
		total += float(arr[g - _base_step]) * step_hours
		g += 1
	return total


# ---------------------------------------------------------------------------
# Waveform downsampling (NLE track strips)
# ---------------------------------------------------------------------------

func waveform_bins(abs_start: float, abs_end: float, bin_count: int, channel: String,
		capacity_kwh: float = 16.0, mode: String = "peak") -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if bin_count < 1:
		return out
	out.resize(bin_count)
	if is_empty() or abs_end <= abs_start:
		for i in bin_count:
			out[i] = 0.0
		return out
	for i in bin_count:
		var t0 := lerpf(abs_start, abs_end, float(i) / float(bin_count))
		var t1 := lerpf(abs_start, abs_end, float(i + 1) / float(bin_count))
		out[i] = _bin_aggregate(t0, t1, channel, capacity_kwh, mode)
	return out


func channel_value(sample: Dictionary, channel: String, capacity_kwh: float) -> float:
	match channel:
		"solar_kw":
			return float(sample.get("solar_kw", 0.0))
		"load_kw":
			return float(sample.get("load_kw", 0.0))
		"aux_kw":
			return 0.0
		"soc_kwh":
			return float(sample.get("soc_kwh", 0.0))
		"soc_pct":
			return 100.0 * float(sample.get("soc_kwh", 0.0)) / maxf(capacity_kwh, 0.001)
		"net_kw":
			return float(sample.get("solar_kw", 0.0)) - float(sample.get("load_kw", 0.0))
	return 0.0


func _bin_aggregate(t0: float, t1: float, channel: String, capacity_kwh: float,
		mode: String) -> float:
	if t1 <= t0:
		return channel_value(sample_at(t0), channel, capacity_kwh)
	var g0 := maxi(int(floor(t0 / step_hours)), _base_step)
	var g1 := mini(int(floor(t1 / step_hours)), _base_step + _soc.size() - 1)
	if g1 < g0:
		return channel_value(sample_at((t0 + t1) * 0.5), channel, capacity_kwh)
	var count := g1 - g0 + 1
	var stride := maxi(1, count / 64)
	var acc := 0.0
	var peak := -INF
	var n := 0
	var g := g0
	while g <= g1:
		var v := channel_value(_index(g - _base_step), channel, capacity_kwh)
		if mode == "peak":
			peak = maxf(peak, v)
		else:
			acc += v
			n += 1
		g += stride
	if mode == "peak":
		return 0.0 if peak == -INF else peak
	return acc / maxf(n, 1)

