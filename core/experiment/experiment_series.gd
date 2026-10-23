class_name ExperimentSeries
extends RefCounted

## One timeline of an experiment — simulated or observed — on a fixed grid of
## absolute hours on the site's clock. Sample i holds from t(i) = start_abs +
## i · step_h to t(i + 1). Unknown values are NAN (an observed gap, a channel
## the source does not have), so every reader skips them instead of reading 0.
##
## Channels (CHANNELS): soc_kwh, solar_kw (delivered to the battery bus),
## raw_kw (what the array could have made before curtailment and DC caps),
## aux_kw (hydro / wind / other DC), demand_kw (what the loads asked for),
## load_kw (what was served), ac (1 = inverter on, 0 = shed).
##
## Pure data; the experiment's sims and its observed builder both fill one,
## the score and the charts both read one, so they compare like for like.

const CHANNELS := ["soc_kwh", "solar_kw", "raw_kw", "aux_kw", "demand_kw", "load_kw", "ac"]

var label := ""
var start_abs := 0.0
var step_h := 1.0 / 60.0
var capacity_kwh := 16.0
## channel -> PackedFloat32Array (only the channels this source has)
var data: Dictionary = {}
## channel -> note shown beside it ("hourly statistics", "held at today's rate")
var notes: Dictionary = {}


func setup(start: float, step: float, n: int, channels: Array = CHANNELS) -> void:
	start_abs = start
	step_h = maxf(step, 1.0 / 3600.0)
	data.clear()
	for ch in channels:
		var a := PackedFloat32Array()
		a.resize(maxi(n, 0))
		a.fill(NAN)
		data[str(ch)] = a


func size() -> int:
	for ch in data:
		return (data[ch] as PackedFloat32Array).size()
	return 0


func end_abs() -> float:
	return start_abs + float(size()) * step_h


func has(channel: String) -> bool:
	if channel == "soc_pct":
		return data.has("soc_kwh")
	if channel == "net_kw":
		return data.has("solar_kw") and data.has("load_kw")
	return data.has(channel)


func time_of(i: int) -> float:
	return start_abs + float(i) * step_h


func index_of(abs_h: float) -> int:
	return int(floor((abs_h - start_abs) / step_h + 1e-9))


func put(channel: String, i: int, v: float) -> void:
	if not data.has(channel):
		return
	var a: PackedFloat32Array = data[channel]
	if i >= 0 and i < a.size():
		a[i] = v
		data[channel] = a


## A sample's value; derived channels: soc_pct, net_kw (solar + aux − load).
func value(channel: String, i: int) -> float:
	match channel:
		"soc_pct":
			var s := value("soc_kwh", i)
			return NAN if is_nan(s) else 100.0 * s / maxf(capacity_kwh, 1e-6)
		"net_kw":
			var so := value("solar_kw", i)
			var lo := value("load_kw", i)
			if is_nan(so) or is_nan(lo):
				return NAN
			var au := value("aux_kw", i)
			return so + (0.0 if is_nan(au) else au) - lo
	if not data.has(channel):
		return NAN
	var a: PackedFloat32Array = data[channel]
	if i < 0 or i >= a.size():
		return NAN
	return a[i]


func value_at(channel: String, abs_h: float) -> float:
	return value(channel, index_of(abs_h))


## The whole channel as one array (derived channels computed).
func values(channel: String) -> PackedFloat32Array:
	if data.has(channel):
		return data[channel]
	var out := PackedFloat32Array()
	var n := size()
	out.resize(n)
	for i in n:
		out[i] = value(channel, i)
	return out


## Share of the samples in [a, b) that are known (0..1).
func coverage(channel: String, a: float = -INF, b: float = INF) -> float:
	var n := size()
	var i0 := maxi(0, index_of(a)) if a > -INF else 0
	var i1 := mini(n, index_of(b)) if b < INF else n
	if i1 <= i0:
		return 0.0
	var k := 0
	for i in range(i0, i1):
		if not is_nan(value(channel, i)):
			k += 1
	return float(k) / float(i1 - i0)


## kWh of a power channel over [a, b) (known samples only).
func integrate(channel: String, a: float = -INF, b: float = INF) -> float:
	var n := size()
	var i0 := maxi(0, index_of(a)) if a > -INF else 0
	var i1 := mini(n, index_of(b)) if b < INF else n
	var total := 0.0
	for i in range(i0, i1):
		var v := value(channel, i)
		if not is_nan(v):
			total += v * step_h
	return total


## TimelineBinning bins of a channel (zoom-stable charts).
func bins(channel: String, w: float, i0: int, n: int) -> Dictionary:
	return TimelineBinning.from_regular(values(channel), start_abs, step_h, w, i0, n)
