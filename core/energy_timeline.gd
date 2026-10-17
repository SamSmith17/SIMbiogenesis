class_name EnergyTimeline
extends RefCounted

## Reversible energy "render cache" — the substrate that makes scrubbing the
## battery behave like a video-editor timeline.
##
## The battery is a path-dependent forward integrator (charge/discharge
## efficiency losses + 0/100% + SOC-floor clamps), so it cannot be reversed
## analytically. Instead we sample its state into a fixed-step buffer keyed by
## absolute hours. Scrubbing then *reads SOC back from the buffer* — so moving
## backward "uncharges" exactly along the curve it charged up.
##
## Channels stored per sample: solar_kw, aux_kw, load_kw, soc_kwh.
## Sample i covers global step (_base_step + i); its absolute time is
## (_base_step + i) * step_hours. This is the same epoch CelestialClock and
## TimeDirector use (absolute hours since year 1 Jan 1 00:00).
##
## Owned by SolarUI. The pure battery-step math (`step_soc`) mirrors
## solar_ui.gd:_integrate_power_step exactly so cached and live agree.

# ---- Battery configuration (kept in sync with SolarUI by the owner) ----
var capacity_kwh: float = 16.0
var charge_eff: float = 0.95
var discharge_eff: float = 0.95
var min_soc_kwh: float = 1.6   # MIN_BATTERY_PERCENT (10%) of 16 kWh

# ---- Buffer ----
var step_hours: float = 1.0 / 60.0          # 1 sample per sim-minute
const MAX_SAMPLES: int = 20160              # ~14 days at 1-min steps

var _base_step: int = 0                      # global step index of element 0
var _soc: PackedFloat32Array = PackedFloat32Array()
var _solar: PackedFloat32Array = PackedFloat32Array()
var _aux: PackedFloat32Array = PackedFloat32Array()
var _load: PackedFloat32Array = PackedFloat32Array()

## Optional evaluator: Callable(abs_hours: float) -> Dictionary
## {solar_kw, aux_kw, load_kw}. Lets the timeline fill instant-scrub gaps with
## pure functions of time (weather + sun). When unset, gaps hold the last
## known inputs constant.
var _eval: Callable = Callable()


# ---------------------------------------------------------------------------
# Pure battery model (mirrors solar_ui.gd:_integrate_power_step)
# ---------------------------------------------------------------------------

## SOC after a forward step. dt_hours must be >= 0.
static func step_soc(soc: float, solar_kw: float, aux_kw: float, load_kw: float,
		dt_hours: float, cap: float, ceff: float, deff: float, min_kwh: float) -> float:
	if dt_hours <= 0.0:
		return soc
	var net := solar_kw + aux_kw - load_kw
	if net > 0.0:
		var charge := net * dt_hours * ceff
		charge = minf(charge, maxf(cap - soc, 0.0))
		return soc + charge
	else:
		var discharge := absf(net) * dt_hours / deff
		var avail := soc - min_kwh
		discharge = minf(discharge, maxf(avail, 0.0))
		return soc - discharge


static func unstep_soc(soc: float, solar_kw: float, aux_kw: float, load_kw: float,
		dt_hours: float, _cap: float, ceff: float, deff: float, _min_kwh: float) -> float:
	if dt_hours <= 0.0:
		return soc
	var net := solar_kw + aux_kw - load_kw
	if net > 0.0:
		return soc - net * dt_hours * ceff
	else:
		if soc <= _min_kwh + 1e-4:
			# If we are currently at the floor, the forward step was clamped.
			# Un-stepping the full discharge would falsely over-restore the SOC (often to 100%).
			return soc
		return soc + absf(net) * dt_hours / deff
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

func configure(cap: float, ceff: float, deff: float, min_kwh: float) -> void:
	capacity_kwh = cap
	charge_eff = ceff
	discharge_eff = deff
	min_soc_kwh = min_kwh


func set_evaluator(cb: Callable) -> void:
	_eval = cb


func clear() -> void:
	_soc = PackedFloat32Array()
	_solar = PackedFloat32Array()
	_aux = PackedFloat32Array()
	_load = PackedFloat32Array()
	_base_step = 0


func is_empty() -> bool:
	return _soc.is_empty()


func count() -> int:
	return _soc.size()


# ---------------------------------------------------------------------------
# Step <-> time mapping
# ---------------------------------------------------------------------------

func _step_of(abs_hours: float) -> int:
	return int(floor(abs_hours / step_hours))

## Public global-step index for an absolute-hours value (batch-render targeting).
func step_of(abs_hours: float) -> int:
	return _step_of(abs_hours)

func time_of_step(g: int) -> float:
	return float(g) * step_hours

func first_step() -> int:
	return _base_step

func last_step() -> int:
	return _base_step + _soc.size() - 1

func start_abs_hours() -> float:
	return time_of_step(_base_step)

func end_abs_hours() -> float:
	if is_empty():
		return 0.0
	return time_of_step(last_step())


# ---------------------------------------------------------------------------
# Anchor / recording
# ---------------------------------------------------------------------------

## Establish the known initial condition. Resets the buffer to a single sample.
func init_anchor(abs_hours: float, soc_kwh: float, solar_kw: float = 0.0,
		aux_kw: float = 0.0, load_kw: float = 0.0) -> void:
	clear()
	_base_step = _step_of(abs_hours)
	_soc.append(clampf(soc_kwh, 0.0, capacity_kwh))
	_solar.append(solar_kw)
	_aux.append(aux_kw)
	_load.append(load_kw)


## Advance the cache to `abs_hours` using the supplied instantaneous inputs,
## integrating SOC from the last cached sample. Inputs are held constant across
## the step (small per-tick dt). Forward-only; ignores backward calls (use
## seek() to move the playhead backward — that reads the existing curve).
##
## At high time_scale a single call can cover thousands of sim-minutes (one
## real-time SolarUI tick advances the sim clock by delta*time_scale). Rather
## than calling step_soc() once per minute — a function call plus two clamp
## branches per sample, the dominant per-iteration cost — _append_exact_run()
## fills the whole span with an inlined closed form. This is not an
## approximation: with inputs held constant, step_soc()'s charge branch
## algebraically reduces to exactly `min(soc + net*dt*ceff, cap)` and the
## discharge branch to exactly `max(soc - |net|*dt/deff, min_kwh)` (both
## verified by direct substitution — the inner clamps in step_soc are
## redundant once cap/min_kwh bound soc from the previous call, as they always
## do here). So soc(t) is a straight ramp toward the full/empty clamp, then
## flat once clamped, and the inlined loop below reproduces every intermediate
## per-minute value bit-for-bit with the old per-minute step_soc() loop — same
## curve, same integrated kWh, just without the redundant function-call/branch
## overhead per sample.
func record_step(abs_hours: float, solar_kw: float, aux_kw: float, load_kw: float) -> void:
	if is_empty():
		init_anchor(abs_hours, clampf(capacity_kwh * 0.5, 0.0, capacity_kwh), solar_kw, aux_kw, load_kw)
		return
	var target_g := _step_of(abs_hours)
	var cur_g := last_step()
	if target_g <= cur_g:
		# Already cached (paused or moving back) — record() does not rewrite history.
		return
	var soc := _soc[_soc.size() - 1]
	var steps := target_g - cur_g

	# A gap wider than the buffer's own retention window would have its
	# earliest portion trimmed off immediately below anyway — skip straight
	# past it with one exact closed-form step (step_soc already handles an
	# arbitrary dt_hours correctly; see the class-level note above) instead of
	# filling and then discarding samples nobody will ever read.
	var skip_steps := maxi(0, steps - MAX_SAMPLES)
	if skip_steps > 0:
		soc = step_soc(soc, solar_kw, aux_kw, load_kw, float(skip_steps) * step_hours,
			capacity_kwh, charge_eff, discharge_eff, min_soc_kwh)
		steps -= skip_steps

	_append_exact_run(soc, solar_kw, aux_kw, load_kw, steps)
	_trim_if_needed()


## Densely appends `steps` per-minute samples starting after `soc0`, exactly
## reproducing what `steps` sequential step_soc() calls would produce (see the
## note above record_step for why this is exact, not approximate). Uses
## resize() + indexed writes instead of append() to avoid incremental
## PackedArray reallocation across a large fast-forward run.
func _append_exact_run(soc0: float, solar_kw: float, aux_kw: float, load_kw: float,
		steps: int) -> void:
	if steps <= 0:
		return
	var start := _soc.size()
	var n := start + steps
	_soc.resize(n)
	_solar.resize(n)
	_aux.resize(n)
	_load.resize(n)

	var net := solar_kw + aux_kw - load_kw
	if net > 0.0:
		var per_step := net * step_hours * charge_eff
		var clamp_step := steps
		if per_step > 0.0:
			var headroom := maxf(capacity_kwh - soc0, 0.0)
			clamp_step = mini(steps, _steps_to_cover(headroom, per_step))
		var soc := soc0
		for k in clamp_step:
			soc = minf(soc + per_step, capacity_kwh)
			_soc[start + k] = soc
		for k in range(clamp_step, steps):
			_soc[start + k] = capacity_kwh
	elif net < 0.0:
		var per_step := (-net) * step_hours / discharge_eff
		var clamp_step := steps
		if per_step > 0.0:
			var avail := maxf(soc0 - min_soc_kwh, 0.0)
			clamp_step = mini(steps, _steps_to_cover(avail, per_step))
		var soc := soc0
		for k in clamp_step:
			soc = maxf(soc - per_step, min_soc_kwh)
			_soc[start + k] = soc
		for k in range(clamp_step, steps):
			_soc[start + k] = min_soc_kwh
	else:
		for k in steps:
			_soc[start + k] = soc0

	for k in steps:
		_solar[start + k] = solar_kw
		_aux[start + k] = aux_kw
		_load[start + k] = load_kw


## Smallest step count k (>= 0) such that k*per_step covers `amount`, i.e. the
## integer ceiling of amount/per_step. Written as an explicit search rather
## than `int(ceil(amount/per_step))` because float division/ceil can land a
## hair under the true integer (e.g. 4.999999994), silently truncating to one
## step short — which would clamp the ramp loop one minute later than the
## per-minute reference computation. per_step must be > 0.
func _steps_to_cover(amount: float, per_step: float) -> int:
	var k := int(amount / per_step)
	if float(k) * per_step < amount - 1e-6:
		k += 1
	return k


## Append a directly-measured SOC sample (e.g. live HA reading) rather than an
## integrated one. Lets LIVE mode build a real history buffer the user can
## later scrub back through. The measured value is held flat across the step.
func record_measured(abs_hours: float, soc_kwh: float, solar_kw: float,
		aux_kw: float, load_kw: float) -> void:
	var soc := clampf(soc_kwh, 0.0, capacity_kwh)
	if is_empty():
		init_anchor(abs_hours, soc, solar_kw, aux_kw, load_kw)
		return
	var target_g := _step_of(abs_hours)
	var cur_g := last_step()
	if target_g <= cur_g:
		# Same step — refresh the latest sample in place with the newest reading.
		var n := _soc.size() - 1
		_soc[n] = soc
		_solar[n] = solar_kw
		_aux[n] = aux_kw
		_load[n] = load_kw
		return
	while cur_g < target_g:
		cur_g += 1
		_soc.append(soc)
		_solar.append(solar_kw)
		_aux.append(aux_kw)
		_load.append(load_kw)
	_trim_if_needed()


# ---------------------------------------------------------------------------
# Seeking (reversible reads + instant-jump gap fill)
# ---------------------------------------------------------------------------

## Move the playhead to `abs_hours` and return the sample there. Reads cached
## history when possible (the "uncharge" on rewind). Fills gaps beyond the
## buffer via the evaluator when set; otherwise clamps to the nearest end.
func seek(abs_hours: float) -> Dictionary:
	if is_empty():
		return {"soc_kwh": clampf(capacity_kwh * 0.5, 0.0, capacity_kwh),
			"solar_kw": 0.0, "aux_kw": 0.0, "load_kw": 0.0}
	var target_g := _step_of(abs_hours)
	if target_g > last_step():
		_fill_forward_to(target_g)
	elif target_g < first_step():
		_fill_backward_to(target_g)
	return sample_at(abs_hours)


## Interpolated read at `abs_hours` (no gap fill). Clamps to buffer range.
func sample_at(abs_hours: float) -> Dictionary:
	if is_empty():
		return {"soc_kwh": 0.0, "solar_kw": 0.0, "aux_kw": 0.0, "load_kw": 0.0}
	var g_lo := first_step()
	var g_hi := last_step()
	var pos := (abs_hours / step_hours) - float(_base_step)   # fractional index
	var i := int(floor(pos))
	if i < 0:
		return _sample_index(0)
	if i >= _soc.size() - 1:
		return _sample_index(_soc.size() - 1)
	var frac := pos - float(i)
	return {
		"soc_kwh":  lerp(float(_soc[i]),   float(_soc[i + 1]),   frac),
		"solar_kw": lerp(float(_solar[i]), float(_solar[i + 1]), frac),
		"aux_kw":   lerp(float(_aux[i]),   float(_aux[i + 1]),   frac),
		"load_kw":  lerp(float(_load[i]),  float(_load[i + 1]),  frac),
	}


func soc_at(abs_hours: float) -> float:
	return float(sample_at(abs_hours).get("soc_kwh", 0.0))


func _sample_index(i: int) -> Dictionary:
	return {
		"soc_kwh":  float(_soc[i]),
		"solar_kw": float(_solar[i]),
		"aux_kw":   float(_aux[i]),
		"load_kw":  float(_load[i]),
	}


func _inputs_at(abs_hours: float, fallback: Dictionary) -> Dictionary:
	if _eval.is_valid():
		var r: Variant = _eval.call(abs_hours)
		if r is Dictionary:
			return r
	return fallback


func _fill_forward_to(target_g: int) -> void:
	var soc := float(_soc[_soc.size() - 1])
	var last := _sample_index(_soc.size() - 1)
	var g := last_step()
	while g < target_g and _soc.size() < MAX_SAMPLES:
		g += 1
		var inp := _inputs_at(time_of_step(g), last)
		var s := float(inp.get("solar_kw", last["solar_kw"]))
		var a := float(inp.get("aux_kw", last["aux_kw"]))
		var l := float(inp.get("load_kw", last["load_kw"]))
		soc = step_soc(soc, s, a, l, step_hours,
			capacity_kwh, charge_eff, discharge_eff, min_soc_kwh)
		_soc.append(soc)
		_solar.append(s)
		_aux.append(a)
		_load.append(l)
	_trim_if_needed()


## Bounded forward integration toward `target_g`, at most `max_steps` per call.
## Lets a batch render spread work across frames with progress. Requires the
## evaluator to be set (the render's pure inputs source). Returns true when the
## buffer reaches target_g (or the MAX_SAMPLES cap).
func fill_forward_chunk(target_g: int, max_steps: int) -> bool:
	if is_empty():
		return true
	var soc := float(_soc[_soc.size() - 1])
	var last := _sample_index(_soc.size() - 1)
	var g := last_step()
	var done := 0
	while g < target_g and _soc.size() < MAX_SAMPLES and done < max_steps:
		g += 1
		var inp := _inputs_at(time_of_step(g), last)
		var s := float(inp.get("solar_kw", last["solar_kw"]))
		var a := float(inp.get("aux_kw", last["aux_kw"]))
		var l := float(inp.get("load_kw", last["load_kw"]))
		soc = step_soc(soc, s, a, l, step_hours,
			capacity_kwh, charge_eff, discharge_eff, min_soc_kwh)
		_soc.append(soc)
		_solar.append(s)
		_aux.append(a)
		_load.append(l)
		done += 1
	_trim_if_needed()
	return last_step() >= target_g or _soc.size() >= MAX_SAMPLES


func _fill_backward_to(target_g: int) -> void:
	# Build prepended samples in forward order, then concat once (O(n)).
	var first := _sample_index(0)
	var soc := float(_soc[0])
	var g := first_step()
	var pre_soc := PackedFloat32Array()
	var pre_solar := PackedFloat32Array()
	var pre_aux := PackedFloat32Array()
	var pre_load := PackedFloat32Array()
	while g > target_g and (pre_soc.size() + _soc.size()) < MAX_SAMPLES:
		g -= 1
		var inp := _inputs_at(time_of_step(g), first)
		var s := float(inp.get("solar_kw", first["solar_kw"]))
		var a := float(inp.get("aux_kw", first["aux_kw"]))
		var l := float(inp.get("load_kw", first["load_kw"]))
		# Recover SOC at the earlier step (inverse of the step that led to `soc`).
		soc = clampf(unstep_soc(soc, s, a, l, step_hours,
			capacity_kwh, charge_eff, discharge_eff, min_soc_kwh), 0.0, capacity_kwh)
		# Prepend in forward order: insert at front of temp arrays.
		pre_soc = PackedFloat32Array([soc]) + pre_soc
		pre_solar = PackedFloat32Array([s]) + pre_solar
		pre_aux = PackedFloat32Array([a]) + pre_aux
		pre_load = PackedFloat32Array([l]) + pre_load
	if pre_soc.is_empty():
		return
	_base_step = g
	_soc = pre_soc + _soc
	_solar = pre_solar + _solar
	_aux = pre_aux + _aux
	_load = pre_load + _load


## Drop every sample after the step that holds `abs_hours` (that step and the
## history before it stay). The cache ahead of the playhead exists only after a
## backward scrub; it was integrated with the inputs of THAT pass, so once the
## live inputs differ (a load switched on, a turbine stopped) it predicts a
## battery that is no longer true. Always keeps at least one sample.
func truncate_after(abs_hours: float) -> void:
	if is_empty():
		return
	var g := maxi(_step_of(abs_hours), first_step())
	var keep := g - _base_step + 1
	if keep >= _soc.size():
		return
	_soc.resize(keep)
	_solar.resize(keep)
	_aux.resize(keep)
	_load.resize(keep)


func _trim_if_needed() -> void:
	var over := _soc.size() - MAX_SAMPLES
	if over <= 0:
		return
	_soc = _soc.slice(over)
	_solar = _solar.slice(over)
	_aux = _aux.slice(over)
	_load = _load.slice(over)
	_base_step += over


# ---------------------------------------------------------------------------
# Range queries (derived daily counters / graph views)
# ---------------------------------------------------------------------------

## kWh in a channel ("solar"/"aux"/"load") over [abs_start, abs_end].
func integrate_channel(abs_start: float, abs_end: float, channel: String) -> float:
	if is_empty() or abs_end <= abs_start:
		return 0.0
	var arr := _channel(channel)
	if arr.is_empty():
		return 0.0
	var g0 := maxi(_step_of(abs_start), first_step())
	var g1 := mini(_step_of(abs_end), last_step())
	var total := 0.0
	var g := g0
	while g < g1:
		var i := g - _base_step
		total += float(arr[i]) * step_hours
		g += 1
	return total


func _channel(channel: String) -> PackedFloat32Array:
	match channel:
		"solar": return _solar
		"aux":   return _aux
		"load":  return _load
		"soc":   return _soc
	return PackedFloat32Array()


# ---------------------------------------------------------------------------
# Waveform downsampling (NLE track strips)
# ---------------------------------------------------------------------------

## Downsample a channel into `bin_count` buckets over [abs_start, abs_end].
## mode: "peak" for power-like channels, "avg" for SOC/smooth channels.
func waveform_bins(abs_start: float, abs_end: float, bin_count: int, channel: String,
		mode: String = "peak") -> PackedFloat32Array:
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
		out[i] = _bin_aggregate(t0, t1, channel, mode)
	return out


static func channel_value(sample: Dictionary, channel: String, cap_kwh: float = 16.0) -> float:
	match channel:
		"solar_kw":
			return float(sample.get("solar_kw", 0.0))
		"load_kw":
			return float(sample.get("load_kw", 0.0))
		"aux_kw":
			return float(sample.get("aux_kw", 0.0))
		"soc_kwh":
			return float(sample.get("soc_kwh", 0.0))
		"soc_pct":
			return 100.0 * float(sample.get("soc_kwh", 0.0)) / maxf(cap_kwh, 0.001)
		"net_kw":
			return float(sample.get("solar_kw", 0.0)) + float(sample.get("aux_kw", 0.0)) \
				- float(sample.get("load_kw", 0.0))
	return 0.0


func _bin_aggregate(t0: float, t1: float, channel: String, mode: String) -> float:
	if t1 <= t0:
		return channel_value(sample_at(t0), channel, capacity_kwh)
	var g0 := maxi(_step_of(t0), first_step())
	var g1 := mini(_step_of(t1), last_step())
	if g1 < g0:
		return channel_value(sample_at((t0 + t1) * 0.5), channel, capacity_kwh)
	var count := g1 - g0 + 1
	var stride := maxi(1, count / 64)
	var acc := 0.0
	var peak := -INF
	var n := 0
	var g := g0
	while g <= g1:
		var v := channel_value(_sample_index(g - _base_step), channel, capacity_kwh)
		if mode == "peak":
			peak = maxf(peak, v)
		else:
			acc += v
			n += 1
		g += stride
	if mode == "peak":
		return 0.0 if peak == -INF else peak
	return acc / maxf(n, 1)

