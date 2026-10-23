class_name ExperimentEnergyRun
extends RefCounted

## One simulated energy timeline over a fixed span, stepped in chunks so a
## week can run in the background without a hitch. It touches NOTHING live:
## the inputs come from `inputs_at` (a Callable(abs_h) -> {solar_kw, raw_kw?,
## aux_kw, load_kw}), the battery is the same model SolarUI integrates
## (EnergyTimeline.step_soc, its efficiencies and floor) and the low-SOC
## protection is SolarUI's hysteresis (AC shed at floor_pct, back at
## resume_pct), the same accounting SiteProjection uses.
##
## Sample i of the output series holds the inputs over [t(i), t(i + 1)) and
## the battery's state AT t(i) — what a zero-order-hold observed reading at
## t(i) means — so a sim and an observed series line up sample for sample.

var series: ExperimentSeries = ExperimentSeries.new()
var inputs_at: Callable = Callable()
var ceff := 0.95
var deff := 0.95
var floor_pct := 10.0
var resume_pct := 20.0
## Optional: Callable(abs_h, soc_kwh, ac_on) -> void, called before each step
## (the sim-time automation evaluator hooks in here).
var before_step: Callable = Callable()

var _i := 0
var _soc := 0.0
var _ac_on := true
var _floor_kwh := 0.0
var _resume_kwh := 0.0


func configure(start_abs: float, end_abs: float, step_h: float, cap_kwh: float,
		start_soc_kwh: float, evaluator: Callable) -> void:
	var n := maxi(int(ceil((end_abs - start_abs) / step_h - 1e-9)), 0)
	series.setup(start_abs, step_h, n)
	series.capacity_kwh = maxf(cap_kwh, 1e-6)
	inputs_at = evaluator
	_floor_kwh = series.capacity_kwh * clampf(floor_pct, 0.0, 100.0) / 100.0
	_resume_kwh = series.capacity_kwh * clampf(resume_pct, floor_pct, 100.0) / 100.0
	_soc = clampf(start_soc_kwh, 0.0, series.capacity_kwh)
	_ac_on = _soc > _floor_kwh + 1e-6
	_i = 0


func is_done() -> bool:
	return _i >= series.size()


func progress() -> float:
	var n := series.size()
	return 1.0 if n == 0 else float(_i) / float(n)


## Step up to `max_steps` samples. Returns true when the span is complete.
func step_chunk(max_steps: int) -> bool:
	var n := series.size()
	var dt := series.step_h
	var stop := mini(n, _i + maxi(max_steps, 1))
	while _i < stop:
		var t := series.time_of(_i)
		if before_step.is_valid():
			before_step.call(t, _soc, _ac_on)
		var inp: Dictionary = inputs_at.call(t + dt * 0.5) if inputs_at.is_valid() else {}
		var solar := maxf(float(inp.get("solar_kw", 0.0)), 0.0)
		var raw := maxf(float(inp.get("raw_kw", solar)), solar)
		var aux := maxf(float(inp.get("aux_kw", 0.0)), 0.0)
		var demand := maxf(float(inp.get("load_kw", 0.0)), 0.0)
		var load := demand if _ac_on else 0.0
		# A full battery curtails the array: the charge controller takes only
		# what the loads and the remaining headroom can use (SolarUI's
		# aux-aware battery-full taper), which is also what an inverter's
		# "PV input power" sensor reports. The SOC is the same either way.
		var headroom_kw := maxf(series.capacity_kwh - _soc, 0.0) / maxf(dt * ceff, 1e-9)
		solar = minf(solar, maxf(load - aux + headroom_kw, 0.0))
		series.put("soc_kwh", _i, _soc)
		series.put("solar_kw", _i, solar)
		series.put("raw_kw", _i, raw)
		series.put("aux_kw", _i, aux)
		series.put("demand_kw", _i, demand)
		series.put("load_kw", _i, load)
		series.put("ac", _i, 1.0 if _ac_on else 0.0)
		_soc = EnergyTimeline.step_soc(_soc, solar, aux, load, dt, series.capacity_kwh,
			ceff, deff, _floor_kwh)
		# Same hysteresis as SolarUI._apply_soc_hysteresis / SiteProjection.
		if _ac_on and _soc <= _floor_kwh + 1e-6:
			_ac_on = false
		elif not _ac_on and _soc >= _resume_kwh - 1e-6:
			_ac_on = true
		_i += 1
	return _i >= n


## The battery after the last step (the state at end_abs).
func end_soc_kwh() -> float:
	return _soc
