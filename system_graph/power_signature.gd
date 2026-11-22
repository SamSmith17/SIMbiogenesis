class_name PowerSignature
extends RefCounted
## Time-varying draw of one electrical load, as a pure function of sim hours.
##
## GraphAcLoad used to bill every device its average watts. A compressor's
## inrush is a fraction of a second, shorter than one sim step once the clock
## is sped up, so sampling the waveform each tick misses the spike that trips
## a breaker. This evaluates a step in closed form: watt-hours for the
## battery, and the instants the draw changes so a sweep can see which
## spikes actually overlap.
##
## Families (specs.signature_family). No family, or a custom load, stays flat
## at avg_watts — today's behaviour.
##   steady            constant draw (LED, network gear)
##   inductive_cyclic  inrush, run, off, repeat (fridge, window AC). The
##                     inrush energy is taken out of the run so a whole cycle
##                     still averages to avg_watts.
##   inductive_start   one inrush when the run starts, then flat (pumps)
##   resistive_cycle   thermostat square wave, no inrush. avg == max stays flat.
##   battery           charge, taper, stop. Needs a start hour (see origin).
##   measured          a recorded polyline replaces the generic curve.
##
## Phase. Cyclic loads share phase zero at ac_restore_h, so every compressor
## inrushes together when power returns, then each item's period drifts by
## about ±10 % (a hash of its id) and they walk apart. Before that hour, or
## when no outage is recorded (restore < 0), phase is the absolute hour, so
## loading a world does not inrush the whole house.
##
## A battery's curve starts at specs.charge_started_h, else at the outage
## when the sample is after it, else at hour 0 — a device with no start on
## a real calendar date is already full and idle. Placing a new one stamps
## the start. Until a start exists in the future of hour 0, a clockless
## reading (no sim hour) still reports the charge rate.
##
## Pure. No scene tree, no wall clock. Windows longer than SWEEP_MAX_H still
## return exact watt-hours, but the fault peak falls back to the average:
## a multi-day catch-up does not replay every spike.

const FAMILY_STEADY := "steady"
const FAMILY_INDUCTIVE_CYCLIC := "inductive_cyclic"
const FAMILY_INDUCTIVE_START := "inductive_start"
const FAMILY_RESISTIVE_CYCLE := "resistive_cycle"
const FAMILY_BATTERY := "battery"
const FAMILY_MEASURED := "measured"

const DEFAULT_INRUSH_S := 0.5
const DEFAULT_INRUSH_MULT := 5.0
const DEFAULT_ON_S := 900.0
const PERIOD_DRIFT := 0.10
const SWEEP_MAX_H := 48.0
const CC_FRAC := 0.80
const TAPER_STEPS := 8
const NO_ORIGIN := -1.0


static func has_family(specs: Dictionary) -> bool:
	return not _family(specs).is_empty()


## The draw at one sim hour (W). restore_h < 0 means no outage alignment.
## level_w >= 0 replaces the nameplate mean (a processor's live watts).
static func watts_at(specs: Dictionary, abs_h: float, restore_h: float = NO_ORIGIN,
		item_id: String = "", level_w: float = -1.0) -> float:
	var shape := _resolve(specs, level_w, item_id)
	return _watts_at_shape(shape, abs_h, restore_h, item_id)


## Watt-hours, the average, and this load's own peak over [t0, t1].
## A window longer than SWEEP_MAX_H reports peak = average (fault fallback);
## watt-hours stay exact. Pass cap_peak = false to always see the real spike.
static func integrate(specs: Dictionary, t0_h: float, t1_h: float, restore_h: float = NO_ORIGIN,
		item_id: String = "", level_w: float = -1.0, cap_peak: bool = true) -> Dictionary:
	if t1_h < t0_h:
		var w := watts_at(specs, t1_h, restore_h, item_id, level_w)
		return {"watt_hours": 0.0, "mean_w": w, "peak_w": w, "now_w": w, "w0": w}
	var dt := t1_h - t0_h
	var shape := _resolve(specs, level_w, item_id)
	var now := _watts_at_shape(shape, t1_h, restore_h, item_id)
	if dt <= 1e-12:
		return {"watt_hours": 0.0, "mean_w": now, "peak_w": now, "now_w": now, "w0": now}
	var wh := _watt_hours(shape, t0_h, t1_h, restore_h, item_id)
	var mean := wh / dt
	var peak := mean
	if not cap_peak or dt <= SWEEP_MAX_H:
		peak = _window_peak(shape, t0_h, t1_h, restore_h, item_id)
	return {"watt_hours": wh, "mean_w": mean, "peak_w": peak, "now_w": now,
		"w0": _watts_at_shape(shape, t0_h, restore_h, item_id)}


## Clockless energy rate (W): the cycle average, or a battery's charge rate.
## Live play uses integrate(); this is what a reading with no sim hour bills.
static func mean_watts(specs: Dictionary, level_w: float = -1.0) -> float:
	var shape := _resolve(specs, level_w, "")
	return float(shape.get("mean_w", 0.0))


## Several loads over one window. `loads` entries:
##   {id, specs, level_w?, origin_h?, breakers?, fixed_w?}
## origin_h, when present, replaces the shared restore for that load (a pump's
## RUNNING hour, or a spread-phase test). fixed_w is a draw that does not
## follow a family (a scene device, a live meter, a light string).
## continuous_w / surge_w < 0 skip the "seconds above" totals.
static func coincide(loads: Array, t0_h: float, t1_h: float, restore_h: float = NO_ORIGIN,
		continuous_w: float = -1.0, surge_w: float = -1.0) -> Dictionary:
	var empty := {"mean_w": 0.0, "peak_w": 0.0, "watt_hours": 0.0, "now_w": 0.0,
		"above_continuous_s": 0.0, "above_surge_s": 0.0, "by_item": {}, "by_breaker": {}}
	if t1_h < t0_h:
		t0_h = t1_h
	var dt := maxf(t1_h - t0_h, 0.0)
	var capped := dt > SWEEP_MAX_H
	var wh := 0.0
	var now := 0.0
	var by_item := {}
	var by_wh := {}   # breaker id -> Wh
	# Piecewise-constant levels for the sweep. Each track: {id, w, breakers}.
	var tracks: Array = []
	var edges: Array = []   # {t, idx, w}
	for ld_v in loads:
		var ld: Dictionary = ld_v
		var id := str(ld.get("id", ""))
		var brs: Array = ld.get("breakers", []) as Array
		var fixed := ld.has("fixed_w")
		var info := {}
		var w0 := 0.0
		var w1 := 0.0
		if fixed:
			w0 = maxf(float(ld.get("fixed_w", 0.0)), 0.0)
			w1 = w0
			var fwh := w0 * dt
			info = {"watt_hours": fwh, "mean_w": w0, "peak_w": w0, "now_w": w1}
			wh += fwh
		else:
			var origin := float(ld.get("origin_h", restore_h)) if ld.has("origin_h") else restore_h
			var specs: Dictionary = ld.get("specs", {}) as Dictionary
			var level := float(ld.get("level_w", -1.0))
			var cap := capped
			var part := integrate(specs, t0_h, t1_h, origin, id, level, cap)
			w0 = float(part.get("w0", 0.0))
			w1 = float(part.get("now_w", 0.0))
			info = part
			wh += float(part.get("watt_hours", 0.0))
			if not capped:
				var ev := _edges(specs, t0_h, t1_h, origin, id, level)
				w0 = float(ev.get("w0", w0))
				for e_v in ev.get("edges", []) as Array:
					var e: Dictionary = e_v
					edges.append({"t": float(e.get("t", t0_h)), "idx": tracks.size(), "w": float(e.get("w", 0.0))})
		now += w1
		by_item[id] = info
		for b_v in brs:
			var bid := str(b_v)
			by_wh[bid] = float(by_wh.get(bid, 0.0)) + float(info.get("watt_hours", 0.0))
		tracks.append({"w": w0, "breakers": brs})
	var peak := 0.0
	var sum0 := 0.0
	for tr_v in tracks:
		sum0 += float((tr_v as Dictionary).get("w", 0.0))
	var above_c := 0.0
	var above_s := 0.0
	var surge_lim := surge_w if surge_w > 0.0 else continuous_w
	if capped or dt <= 1e-12:
		peak = sum0
		if dt > 1e-12 and continuous_w >= 0.0 and sum0 > continuous_w:
			above_c = dt * 3600.0
		if dt > 1e-12 and surge_lim >= 0.0 and sum0 > surge_lim:
			above_s = dt * 3600.0
	else:
		var swept := _sweep(tracks, edges, t0_h, t1_h, continuous_w, surge_lim)
		peak = float(swept.get("peak", sum0))
		above_c = float(swept.get("above_c", 0.0))
		above_s = float(swept.get("above_s", 0.0))
		var br_peak: Dictionary = swept.get("breaker_peak", {})
		for bid_v in by_wh.keys():
			var bid := str(bid_v)
			var bwh := float(by_wh[bid])
			var bm := bwh / dt if dt > 1e-12 else 0.0
			by_wh[bid] = {"watt_hours": bwh, "mean_w": bm,
				"peak_w": float(br_peak.get(bid, bm))}
	if capped or dt <= 1e-12:
		for bid_v2 in by_wh.keys():
			var bid2 := str(bid_v2)
			if typeof(by_wh[bid2]) == TYPE_FLOAT or typeof(by_wh[bid2]) == TYPE_INT:
				var bwh2 := float(by_wh[bid2])
				var bm2 := bwh2 / dt if dt > 1e-12 else 0.0
				by_wh[bid2] = {"watt_hours": bwh2, "mean_w": bm2, "peak_w": bm2}
	var mean := wh / dt if dt > 1e-12 else now
	return {"mean_w": mean, "peak_w": peak, "watt_hours": wh, "now_w": now,
		"above_continuous_s": above_c, "above_surge_s": above_s,
		"by_item": by_item, "by_breaker": by_wh}


## Inverter protection over one sim step. Times are sim seconds.
## Above the surge rating trips this step. Between the continuous rating and
## the surge, the hold has to elapse (a short inrush under the surge does not).
## A step that never clears the continuous rating resets the hold.
static func inverter_decision(elapsed_s: float, peak_w: float, above_cont_s: float,
		above_surge_s: float, continuous_w: float, surge_w: float, hold_s: float) -> Dictionary:
	var surge := surge_w if surge_w > 0.0 else continuous_w
	if above_surge_s > 1e-6 or (surge > 0.0 and peak_w > surge + 0.5):
		return {"tripped": true, "elapsed_s": 0.0}
	if above_cont_s > 1e-6:
		var e := elapsed_s + above_cont_s
		if hold_s >= 0.0 and e >= hold_s - 1e-6:
			return {"tripped": true, "elapsed_s": 0.0}
		return {"tripped": false, "elapsed_s": e}
	return {"tripped": false, "elapsed_s": 0.0}


## One cycle (or the charge, or the recording) as [t_seconds, watts] samples.
static func preview(specs: Dictionary, item_id: String = "") -> Dictionary:
	var shape := _resolve(specs, -1.0, item_id)
	var samples: Array = []
	var dur := 60.0
	var mode := str(shape.get("mode", "steady"))
	var mean := float(shape.get("mean_w", 0.0))
	var peak := mean
	if mode == "square":
		dur = maxf(float(shape.get("period_s", 60.0)), 1.0)
		var n := 64
		for i in n + 1:
			var u := dur * float(i) / float(n)
			var w := _square_w(shape, u)
			samples.append([u, w])
			peak = maxf(peak, w)
	elif mode == "start":
		dur = maxf(float(shape.get("inrush_s", 0.5)) * 6.0, 3.0)
		samples = [[0.0, float(shape.get("inrush_w", mean))],
			[float(shape.get("inrush_s", 0.5)), float(shape.get("run_w", mean))],
			[dur, float(shape.get("run_w", mean))]]
		peak = float(shape.get("inrush_w", mean))
	elif mode == "battery":
		var charge := float(shape.get("charge_w", mean))
		var cc_h := float(shape.get("cc_h", 0.0))
		var taper_h := float(shape.get("taper_h", 0.0))
		dur = maxf((cc_h + taper_h) * 3600.0, 1.0)
		var n2 := 48
		for i2 in n2 + 1:
			var u2 := dur * float(i2) / float(n2)
			var w2 := _battery_w(shape, u2 / 3600.0)
			samples.append([u2, w2])
			peak = maxf(peak, w2)
	elif mode == "measured":
		var trace: Array = shape.get("trace", []) as Array
		dur = maxf(float(shape.get("duration_s", 1.0)), 1.0)
		for p_v in trace:
			var t := 0.0
			var w3 := 0.0
			if p_v is Array and (p_v as Array).size() >= 2:
				t = float((p_v as Array)[0])
				w3 = float((p_v as Array)[1])
			samples.append([t, w3])
			peak = maxf(peak, w3)
	else:
		samples = [[0.0, mean], [dur, mean]]
	var avg := mean
	if mode == "measured":
		avg = float(shape.get("trace_avg", mean))
	return {"samples": samples, "duration_s": dur, "avg_w": avg, "peak_w": peak,
		"family": str(shape.get("family", ""))}


## The numbers a test pins: scaled period, run, inrush. item_id "" has no drift.
static func describe(specs: Dictionary, item_id: String = "") -> Dictionary:
	var shape := _resolve(specs, -1.0, item_id)
	return {
		"family": str(shape.get("family", "")),
		"mean_w": float(shape.get("mean_w", 0.0)),
		"run_w": float(shape.get("run_w", 0.0)),
		"inrush_w": float(shape.get("inrush_w", 0.0)),
		"inrush_s": float(shape.get("inrush_s", 0.0)),
		"on_s": float(shape.get("on_s", 0.0)),
		"period_s": float(shape.get("period_s", 0.0)),
		"standby_w": float(shape.get("standby_w", 0.0)),
	}


static func parse_csv(text: String) -> Array:
	var out: Array = []
	for line in text.split("\n"):
		var s := line.strip_edges().replace(";", ",")
		if s.is_empty() or s.begins_with("#"):
			continue
		var bits := s.split(",")
		if bits.size() < 2:
			continue
		if not bits[0].is_valid_float() or not bits[1].is_valid_float():
			continue
		out.append([float(bits[0]), maxf(float(bits[1]), 0.0)])
	out.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	return out


## Specs patch that replaces the generic curve with a recorded polyline.
## The previous family is kept so clearing the trace puts it back.
static func apply_trace(specs: Dictionary, trace: Array, loop: bool) -> Dictionary:
	var patch := {"signature_family": FAMILY_MEASURED, "power_trace": trace,
		"power_trace_loop": loop}
	if str(specs.get("signature_family", "")) != FAMILY_MEASURED:
		patch["signature_family_base"] = str(specs.get("signature_family", ""))
	elif specs.has("signature_family_base"):
		patch["signature_family_base"] = specs.get("signature_family_base")
	return patch


static func clear_trace(specs: Dictionary) -> Dictionary:
	return {"signature_family": str(specs.get("signature_family_base", "")),
		"power_trace": [], "power_trace_loop": false, "signature_family_base": ""}


# ---------------------------------------------------------------------------
# Shape
# ---------------------------------------------------------------------------

static func _family(specs: Dictionary) -> String:
	var f := str(specs.get("signature_family", ""))
	if f == FAMILY_MEASURED:
		var tr: Array = specs.get("power_trace", []) as Array
		if tr.size() >= 2:
			return FAMILY_MEASURED
		f = str(specs.get("signature_family_base", ""))
	if f in [FAMILY_STEADY, FAMILY_INDUCTIVE_CYCLIC, FAMILY_INDUCTIVE_START,
			FAMILY_RESISTIVE_CYCLE, FAMILY_BATTERY]:
		return f
	return ""


static func _base_mean(specs: Dictionary) -> float:
	var avg := float(specs.get("avg_watts", 0.0))
	if avg > 0.0:
		return avg
	var w := float(specs.get("watts", 0.0))
	if w > 0.0:
		return w
	return maxf(0.0, float(specs.get("max_watts", 0.0)))


static func _period_scale(item_id: String) -> float:
	if item_id.is_empty():
		return 1.0
	var h := item_id.hash()
	var m := h % 10000
	if m < 0:
		m += 10000
	return lerpf(1.0 - PERIOD_DRIFT, 1.0 + PERIOD_DRIFT, float(m) / 9999.0)


static func _resolve(specs: Dictionary, level_w: float, item_id: String) -> Dictionary:
	var mean := level_w if level_w >= 0.0 else _base_mean(specs)
	mean = maxf(mean, 0.0)
	var fam := _family(specs)
	var scale := _period_scale(item_id)
	var standby := maxf(float(specs.get("standby_watts", 0.0)), 0.0)
	var inrush_s := maxf(float(specs.get("inrush_s", DEFAULT_INRUSH_S)), 0.05)
	var inrush_mult := maxf(float(specs.get("inrush_mult", DEFAULT_INRUSH_MULT)), 1.0)
	var shape := {"family": fam, "mode": "steady", "mean_w": mean, "run_w": mean,
		"inrush_w": mean, "inrush_s": 0.0, "on_s": 0.0, "period_s": 0.0, "standby_w": 0.0}
	if fam == "" or fam == FAMILY_STEADY or mean <= 0.0:
		return shape
	if fam == FAMILY_RESISTIVE_CYCLE:
		var run_r := float(specs.get("max_watts", 0.0))
		if run_r <= mean + 0.5:
			return shape
		standby = minf(standby, mean)
		var duty_r := clampf((mean - standby) / (run_r - standby), 0.05, 0.98)
		var on_r := maxf(float(specs.get("cycle_on_s", DEFAULT_ON_S)), 1.0) * scale
		shape["mode"] = "square"
		shape["run_w"] = run_r
		shape["standby_w"] = standby
		shape["inrush_w"] = run_r
		shape["inrush_s"] = 0.0
		shape["on_s"] = on_r
		shape["period_s"] = on_r / duty_r
		return shape
	if fam == FAMILY_INDUCTIVE_START:
		shape["mode"] = "start"
		shape["run_w"] = mean
		shape["inrush_w"] = mean * inrush_mult
		shape["inrush_s"] = inrush_s
		return shape
	if fam == FAMILY_BATTERY:
		var cap := float(specs.get("capacity_wh", specs.get("battery_capacity_wh", 0.0)))
		if cap <= 0.0 or mean <= 0.0:
			return shape
		var cc_wh := cap * CC_FRAC
		var taper_wh := cap - cc_wh
		shape["mode"] = "battery"
		shape["charge_w"] = mean
		shape["capacity_wh"] = cap
		shape["cc_h"] = cc_wh / mean
		# Linear taper from the charge rate down to 0. Its average is half, so
		# the hours are twice the remaining watt-hours over the charge rate.
		shape["taper_h"] = 2.0 * taper_wh / mean
		return shape
	if fam == FAMILY_MEASURED:
		var trace: Array = specs.get("power_trace", []) as Array
		var dur := 1.0
		var sum_ws := 0.0
		if trace.size() >= 2:
			dur = maxf(float((trace[trace.size() - 1] as Array)[0]) - float((trace[0] as Array)[0]), 0.05)
			for i in trace.size() - 1:
				var a: Array = trace[i]
				var b: Array = trace[i + 1]
				sum_ws += float(a[1]) * maxf(float(b[0]) - float(a[0]), 0.0)
		shape["mode"] = "measured"
		shape["trace"] = trace
		shape["loop"] = bool(specs.get("power_trace_loop", true))
		shape["duration_s"] = dur
		shape["trace_avg"] = sum_ws / dur if dur > 0.0 else mean
		shape["mean_w"] = float(shape["trace_avg"])
		return shape
	# inductive_cyclic. Run at max_watts when that sits above the mean; the
	# off valley makes the average. Inrush energy comes out of the run.
	var run := float(specs.get("max_watts", 0.0))
	if run <= mean + 0.5:
		run = mean
	standby = minf(standby, mean)
	var inrush_w := run * inrush_mult
	var duty := 1.0
	if run > standby + 0.5:
		duty = clampf((mean - standby) / (run - standby), 0.05, 1.0)
	var on_nom := maxf(float(specs.get("cycle_on_s", DEFAULT_ON_S)), inrush_s + 1.0)
	var period_nom := on_nom / duty
	var off_nom := period_nom - on_nom
	var span := run - standby
	if span > 1.0:
		var trim := (inrush_w - run) * inrush_s / span
		trim = minf(maxf(trim, 0.0), maxf(on_nom - inrush_s - 0.5, 0.0))
		on_nom -= trim
		off_nom += trim
		period_nom = on_nom + off_nom
	elif on_nom > inrush_s + 1.0:
		# Nowhere to park the extra energy: lower the plateau instead.
		run = maxf(0.0, (mean * period_nom - inrush_w * inrush_s) / (on_nom - inrush_s))
		inrush_w = run * inrush_mult
	shape["mode"] = "square"
	shape["run_w"] = run
	shape["standby_w"] = standby
	shape["inrush_w"] = inrush_w
	shape["inrush_s"] = minf(inrush_s, on_nom * 0.5)
	shape["on_s"] = on_nom * scale
	shape["period_s"] = period_nom * scale
	return shape


# ---------------------------------------------------------------------------
# Point samples and exact energy
# ---------------------------------------------------------------------------

## -1 is "no origin". Anything above that, including a phase zero a fraction of
## an hour before t = 0, is a real origin.
static func _has_origin(restore_h: float) -> bool:
	return restore_h > NO_ORIGIN + 1e-6


static func _aligned(abs_h: float, restore_h: float) -> bool:
	return _has_origin(restore_h) and abs_h >= restore_h - 1e-9


static func _local_s(abs_h: float, restore_h: float, aligned: bool) -> float:
	if aligned:
		return (abs_h - restore_h) * 3600.0
	return abs_h * 3600.0


static func _to_abs(local_s: float, restore_h: float, aligned: bool) -> float:
	if aligned:
		return restore_h + local_s / 3600.0
	return local_s / 3600.0


static func _watts_at_shape(shape: Dictionary, abs_h: float, restore_h: float, item_id: String) -> float:
	var mode := str(shape.get("mode", "steady"))
	if mode == "steady":
		return float(shape.get("mean_w", 0.0))
	if mode == "start":
		return _start_w(shape, abs_h, restore_h)
	if mode == "battery":
		return _battery_w(shape, _battery_elapsed_h(shape, abs_h, restore_h))
	if mode == "measured":
		var aligned := _aligned(abs_h, restore_h)
		return _measured_w(shape, _local_s(abs_h, restore_h, aligned))
	var aligned_c := _aligned(abs_h, restore_h)
	return _square_w(shape, _local_s(abs_h, restore_h, aligned_c))


static func _square_w(shape: Dictionary, local_s: float) -> float:
	var period := float(shape.get("period_s", 0.0))
	if period <= 0.05:
		return float(shape.get("run_w", 0.0))
	var phase := fposmod(local_s, period)
	var inrush_s := float(shape.get("inrush_s", 0.0))
	if inrush_s > 0.0 and phase < inrush_s:
		return float(shape.get("inrush_w", 0.0))
	if phase < float(shape.get("on_s", period)):
		return float(shape.get("run_w", 0.0))
	return float(shape.get("standby_w", 0.0))


static func _start_w(shape: Dictionary, abs_h: float, origin_h: float) -> float:
	var run := float(shape.get("run_w", 0.0))
	if origin_h < 0.0:
		return run
	var elapsed_s := (abs_h - origin_h) * 3600.0
	if elapsed_s < 0.0:
		return run
	if elapsed_s < float(shape.get("inrush_s", 0.0)):
		return float(shape.get("inrush_w", run))
	return run


static func _battery_elapsed_h(shape: Dictionary, abs_h: float, restore_h: float) -> float:
	# The caller passes the charge origin as restore_h for a battery.
	# < 0 with no scheduled start: elapsed is huge (charged since hour 0)
	# only when restore is the NO_ORIGIN sentinel AND the shape says so.
	# integrate/watts_at pass the resolved origin. -1 means "since hour 0".
	var origin := restore_h
	if origin < 0.0:
		origin = 0.0
	return abs_h - origin


static func _battery_w(shape: Dictionary, elapsed_h: float) -> float:
	if str(shape.get("mode", "")) != "battery":
		return float(shape.get("mean_w", 0.0))
	if elapsed_h < 0.0:
		return 0.0
	var charge := float(shape.get("charge_w", 0.0))
	var cc := float(shape.get("cc_h", 0.0))
	if elapsed_h < cc:
		return charge
	var taper := float(shape.get("taper_h", 0.0))
	if taper <= 1e-9:
		return 0.0
	var u := (elapsed_h - cc) / taper
	if u >= 1.0:
		return 0.0
	return charge * (1.0 - u)


static func _measured_w(shape: Dictionary, local_s: float) -> float:
	var trace: Array = shape.get("trace", []) as Array
	if trace.is_empty():
		return float(shape.get("mean_w", 0.0))
	var t0 := float((trace[0] as Array)[0])
	var dur := float(shape.get("duration_s", 1.0))
	var u := local_s
	if bool(shape.get("loop", true)):
		u = t0 + fposmod(local_s - t0, dur)
	else:
		u = t0 + clampf(local_s - t0, 0.0, dur)
	var w := float((trace[0] as Array)[1])
	for i in trace.size():
		var p: Array = trace[i]
		if float(p[0]) <= u + 1e-9:
			w = float(p[1])
		else:
			break
	return maxf(w, 0.0)


static func _watt_hours(shape: Dictionary, t0: float, t1: float, restore_h: float, item_id: String) -> float:
	var mode := str(shape.get("mode", "steady"))
	var dt := t1 - t0
	if mode == "steady":
		return float(shape.get("mean_w", 0.0)) * dt
	if mode == "start":
		# The inrush is a fault, not extra energy: the run watts are what the
		# battery is billed, including across the spike.
		var run := float(shape.get("run_w", 0.0))
		var origin := restore_h
		if origin < 0.0:
			return run * dt
		var a := maxf(t0, origin)
		if t1 <= a:
			return run * dt
		return run * dt
	if mode == "battery":
		return _battery_wh(shape, t0, t1, restore_h)
	if mode == "measured":
		return _measured_wh(shape, t0, t1, restore_h)
	return _square_wh_span(shape, t0, t1, restore_h)


static func _square_wh_span(shape: Dictionary, t0: float, t1: float, restore_h: float) -> float:
	# A window that crosses the outage is two phases: absolute time before
	# it, shared zero after it.
	if _has_origin(restore_h) and t0 < restore_h - 1e-12 and t1 > restore_h + 1e-12:
		return _square_wh(shape, t0, restore_h, false, restore_h) \
			+ _square_wh(shape, restore_h, t1, true, restore_h)
	var aligned := _has_origin(restore_h) and t0 >= restore_h - 1e-9
	return _square_wh(shape, t0, t1, aligned, restore_h)


static func _square_wh(shape: Dictionary, t0: float, t1: float, aligned: bool, restore_h: float) -> float:
	var period := float(shape.get("period_s", 0.0))
	if period <= 0.05:
		return float(shape.get("run_w", 0.0)) * (t1 - t0)
	var local0 := _local_s(t0, restore_h, aligned)
	var local1 := _local_s(t1, restore_h, aligned)
	# fposmod(period, period) is 0, so the prefix at the boundary is not the cycle.
	var cycle_ws := _prefix_phase(shape, period)
	var n: float = floor(local1 / period) - floor(local0 / period)
	var ws := _prefix_ws(shape, local1) - _prefix_ws(shape, local0) + float(n) * cycle_ws
	return maxf(ws, 0.0) / 3600.0


static func _prefix_ws(shape: Dictionary, local_s: float) -> float:
	# Whole cycles before this phase are NOT included; the caller adds them.
	var period := float(shape.get("period_s", 1.0))
	return _prefix_phase(shape, fposmod(local_s, period))


static func _prefix_phase(shape: Dictionary, phase: float) -> float:
	var period := float(shape.get("period_s", 1.0))
	var acc := 0.0
	var inrush_s := float(shape.get("inrush_s", 0.0))
	var on_s := float(shape.get("on_s", period))
	var pieces := []
	if inrush_s > 0.0 and inrush_s < on_s:
		pieces.append([0.0, inrush_s, float(shape.get("inrush_w", 0.0))])
		pieces.append([inrush_s, on_s, float(shape.get("run_w", 0.0))])
	else:
		pieces.append([0.0, on_s, float(shape.get("run_w", 0.0))])
	pieces.append([on_s, period, float(shape.get("standby_w", 0.0))])
	for p_v in pieces:
		var p: Array = p_v
		var a := float(p[0])
		var b := float(p[1])
		if phase <= a:
			break
		var hi := minf(phase, b)
		acc += float(p[2]) * (hi - a)
	return acc


static func _battery_wh(shape: Dictionary, t0: float, t1: float, origin_h: float) -> float:
	var origin := origin_h if origin_h >= 0.0 else 0.0
	var charge := float(shape.get("charge_w", 0.0))
	var cc := float(shape.get("cc_h", 0.0))
	var taper := float(shape.get("taper_h", 0.0))
	# Elapsed hours at the window ends.
	var e0 := t0 - origin
	var e1 := t1 - origin
	if e1 <= 0.0 or charge <= 0.0:
		return 0.0
	e0 = maxf(e0, 0.0)
	var wh := 0.0
	# Constant-current overlap.
	var cc0 := clampf(e0, 0.0, cc)
	var cc1 := clampf(e1, 0.0, cc)
	wh += charge * maxf(cc1 - cc0, 0.0)
	# Linear taper. P(u) = charge * (1 - u/taper), integral over [a, b] is
	# charge * ((b - a) - (b² - a²) / (2 taper)).
	if taper > 1e-9:
		var a := clampf(e0 - cc, 0.0, taper)
		var b := clampf(e1 - cc, 0.0, taper)
		if b > a:
			wh += charge * ((b - a) - (b * b - a * a) / (2.0 * taper))
	return wh


static func _measured_wh(shape: Dictionary, t0: float, t1: float, restore_h: float) -> float:
	var trace: Array = shape.get("trace", []) as Array
	if trace.size() < 2:
		return float(shape.get("mean_w", 0.0)) * (t1 - t0)
	var dur := float(shape.get("duration_s", 1.0))
	var loop := bool(shape.get("loop", true))
	if _has_origin(restore_h) and t0 < restore_h and t1 > restore_h:
		return _measured_wh(shape, t0, restore_h, NO_ORIGIN) + _measured_wh(shape, restore_h, t1, restore_h)
	var on_restore := _has_origin(restore_h) and t0 >= restore_h
	var local0 := _local_s(t0, restore_h, on_restore)
	var local1 := _local_s(t1, restore_h, on_restore)
	# One pass of the polyline in watt-seconds, then whole loops plus a partial.
	var cycle_ws := 0.0
	for i in trace.size() - 1:
		var a: Array = trace[i]
		var b: Array = trace[i + 1]
		cycle_ws += float(a[1]) * maxf(float(b[0]) - float(a[0]), 0.0)
	if not loop:
		# A one-shot trace, played from the origin, then the last sample holds? 
		# It ends. After the recording the draw is 0 (the charge stopped, the
		# batch finished).
		var start_s := local0
		var end_s := local1
		return _trace_ws_between(trace, start_s, end_s, false, dur) / 3600.0
	var n: float = floor(local1 / dur) - floor(local0 / dur)
	var ws := _trace_prefix_ws(trace, local1, dur) - _trace_prefix_ws(trace, local0, dur) + float(n) * cycle_ws
	return maxf(ws, 0.0) / 3600.0


static func _trace_prefix_ws(trace: Array, local_s: float, dur: float) -> float:
	var phase := fposmod(local_s, dur)
	var acc := 0.0
	for i in trace.size() - 1:
		var a: Array = trace[i]
		var b: Array = trace[i + 1]
		var ta := float(a[0])
		var tb := float(b[0])
		# Trace times are seconds from the recording's own zero. Map phase,
		# which is 0..dur, onto that if the trace itself starts at 0.
		var t_first := float((trace[0] as Array)[0])
		var pa := ta - t_first
		var pb := tb - t_first
		if phase <= pa:
			break
		var hi := minf(phase, pb)
		acc += float(a[1]) * maxf(hi - pa, 0.0)
	return acc


static func _trace_ws_between(trace: Array, local0: float, local1: float, _loop: bool, dur: float) -> float:
	var t_first := float((trace[0] as Array)[0])
	var acc := 0.0
	var prev_t := t_first
	var prev_w := float((trace[0] as Array)[1])
	for i in trace.size():
		var p: Array = trace[i]
		var t := float(p[0])
		var w := float(p[1])
		if i > 0:
			var a := maxf(prev_t, t_first + maxf(local0, 0.0))
			var b := minf(t, t_first + maxf(local1, 0.0))
			# local is seconds from the origin; the trace's first t is its zero.
			a = maxf(prev_t, t_first + local0)
			b = minf(t, t_first + local1)
			if b > a:
				acc += prev_w * (b - a)
		prev_t = t
		prev_w = w
	return maxf(acc, 0.0)


static func _window_peak(shape: Dictionary, t0: float, t1: float, restore_h: float, item_id: String) -> float:
	var mode := str(shape.get("mode", "steady"))
	if mode == "steady":
		return float(shape.get("mean_w", 0.0))
	if mode == "start":
		var run := float(shape.get("run_w", 0.0))
		var inrush := float(shape.get("inrush_w", run))
		if restore_h < 0.0:
			return run
		var i0 := restore_h
		var i1 := restore_h + float(shape.get("inrush_s", 0.0)) / 3600.0
		if t1 > i0 and t0 < i1:
			return inrush
		return run
	if mode == "battery":
		var origin_b := restore_h if restore_h >= 0.0 else 0.0
		var charge_b := float(shape.get("charge_w", 0.0))
		var cc_end := origin_b + float(shape.get("cc_h", 0.0))
		if t1 > origin_b and t0 < cc_end:
			return charge_b
		return maxf(_battery_w(shape, t0 - origin_b), _battery_w(shape, t1 - origin_b))
	if mode == "square":
		var period := float(shape.get("period_s", 0.0))
		var cycle_max := maxf(float(shape.get("inrush_w", 0.0)), float(shape.get("run_w", 0.0)))
		if (t1 - t0) * 3600.0 >= period - 1e-3:
			return cycle_max
		return maxf(_watts_at_shape(shape, t0, restore_h, item_id),
			_watts_at_shape(shape, t1, restore_h, item_id))
	# measured: the max sample inside the window, or the whole trace if it loops
	# across at least one period.
	var trace: Array = shape.get("trace", []) as Array
	var peak := 0.0
	for p_v in trace:
		if p_v is Array and (p_v as Array).size() >= 2:
			peak = maxf(peak, float((p_v as Array)[1]))
	if (t1 - t0) * 3600.0 < float(shape.get("duration_s", 1.0)):
		peak = maxf(_watts_at_shape(shape, t0, restore_h, item_id),
			_watts_at_shape(shape, t1, restore_h, item_id))
	return peak


# ---------------------------------------------------------------------------
# Edges for the coincidence sweep
# ---------------------------------------------------------------------------

static func _edges(specs: Dictionary, t0: float, t1: float, restore_h: float,
		item_id: String, level_w: float) -> Dictionary:
	var shape := _resolve(specs, level_w, item_id)
	var w0 := _watts_at_shape(shape, t0, restore_h, item_id)
	var mode := str(shape.get("mode", "steady"))
	if mode == "steady" or t1 <= t0 + 1e-12:
		return {"w0": w0, "edges": []}
	if mode == "square":
		return _square_edges(shape, t0, t1, restore_h, w0)
	if mode == "start":
		return _start_edges(shape, t0, t1, restore_h, w0)
	if mode == "battery":
		return _battery_edges(shape, t0, t1, restore_h, w0)
	if mode == "measured":
		return _measured_edges(shape, t0, t1, restore_h, w0)
	return {"w0": w0, "edges": []}


static func _square_edges(shape: Dictionary, t0: float, t1: float, restore_h: float, w0: float) -> Dictionary:
	var edges: Array = []
	if _has_origin(restore_h) and t0 < restore_h and t1 > restore_h:
		var left := _square_edge_side(shape, t0, restore_h, false, restore_h, w0)
		var right := _square_edge_side(shape, restore_h, t1, true, restore_h, float(left.get("w_end", w0)))
		edges.append_array(left.get("edges", []) as Array)
		edges.append_array(right.get("edges", []) as Array)
		return {"w0": w0, "edges": edges}
	var aligned := _has_origin(restore_h) and t0 >= restore_h - 1e-9
	return _square_edge_side(shape, t0, t1, aligned, restore_h, w0)


static func _square_edge_side(shape: Dictionary, t0: float, t1: float, aligned: bool,
		restore_h: float, w0: float) -> Dictionary:
	var period := float(shape.get("period_s", 0.0))
	var edges: Array = []
	if period <= 0.05:
		return {"w0": w0, "edges": edges, "w_end": w0}
	var local0 := _local_s(t0, restore_h, aligned)
	var local1 := _local_s(t1, restore_h, aligned)
	var inrush_s := float(shape.get("inrush_s", 0.0))
	var on_s := float(shape.get("on_s", period))
	var marks := []
	if inrush_s > 0.0:
		marks.append([inrush_s, float(shape.get("run_w", 0.0))])
	marks.append([on_s, float(shape.get("standby_w", 0.0))])
	var restart_w := float(shape.get("run_w", 0.0))
	if inrush_s > 0.0:
		restart_w = float(shape.get("inrush_w", restart_w))
	marks.append([period, restart_w])
	var n0: float = floor(local0 / period)
	var n1: float = floor(local1 / period)
	var prev := w0
	var guard := 0
	# Cycle index at a real calendar date is tens of millions. Walk from the
	# window's first cycle, not from zero, and never materialise that span.
	var n: float = n0
	var limit := int(maxf(n1 - n0, 0.0)) + 3
	while n <= n1 + 0.01 and guard < limit and guard < 100000:
		guard += 1
		var base: float = n * period
		for m_v in marks:
			var m: Array = m_v
			var at: float = base + float(m[0])
			if at <= local0 + 1e-6 or at > local1 + 1e-6:
				continue
			var w := float(m[1])
			if absf(w - prev) < 0.05:
				continue
			edges.append({"t": _to_abs(at, restore_h, aligned), "w": w})
			prev = w
		n += 1.0
	return {"w0": w0, "edges": edges, "w_end": prev}


static func _start_edges(shape: Dictionary, t0: float, t1: float, origin_h: float, w0: float) -> Dictionary:
	var edges: Array = []
	if origin_h < 0.0:
		return {"w0": w0, "edges": edges}
	var run := float(shape.get("run_w", 0.0))
	var inrush := float(shape.get("inrush_w", run))
	var t_in := origin_h
	var t_run := origin_h + float(shape.get("inrush_s", 0.0)) / 3600.0
	if t_in > t0 + 1e-12 and t_in <= t1 + 1e-9:
		edges.append({"t": t_in, "w": inrush})
	if t_run > t0 + 1e-12 and t_run <= t1 + 1e-9:
		edges.append({"t": t_run, "w": run})
	return {"w0": w0, "edges": edges}


static func _battery_edges(shape: Dictionary, t0: float, t1: float, origin_h: float, w0: float) -> Dictionary:
	var edges: Array = []
	var origin := origin_h if origin_h >= 0.0 else 0.0
	var charge := float(shape.get("charge_w", 0.0))
	var cc := float(shape.get("cc_h", 0.0))
	var taper := float(shape.get("taper_h", 0.0))
	var marks: Array = []
	marks.append([origin, charge])
	for s in TAPER_STEPS:
		var u := float(s + 1) / float(TAPER_STEPS)
		marks.append([origin + cc + taper * u, charge * (1.0 - u)])
	for m_v in marks:
		var m: Array = m_v
		var at := float(m[0])
		if at <= t0 + 1e-12 or at > t1 + 1e-9:
			continue
		edges.append({"t": at, "w": float(m[1])})
	return {"w0": w0, "edges": edges}


static func _measured_edges(shape: Dictionary, t0: float, t1: float, restore_h: float, w0: float) -> Dictionary:
	# Vertices of the (possibly looped) polyline inside the window. A long
	# window still caps at SWEEP_MAX_H before this is asked.
	var edges: Array = []
	var trace: Array = shape.get("trace", []) as Array
	if trace.size() < 2:
		return {"w0": w0, "edges": edges}
	var dur := float(shape.get("duration_s", 1.0))
	var loop := bool(shape.get("loop", true))
	var aligned := _has_origin(restore_h) and t0 >= restore_h - 1e-9
	var local0 := _local_s(t0, restore_h, aligned)
	var local1 := _local_s(t1, restore_h, aligned)
	var t_first := float((trace[0] as Array)[0])
	var n0 := 0.0
	var n1 := 0.0
	if loop:
		n0 = floor(local0 / dur)
		n1 = floor(local1 / dur)
	var prev := w0
	var guard := 0
	var limit := int(maxf(n1 - n0, 0.0)) + 3
	var n := n0
	while n <= n1 + 0.01 and guard < limit and guard < 100000:
		guard += 1
		for p_v in trace:
			var p: Array = p_v
			var at_local := float(n) * dur + (float(p[0]) - t_first)
			if at_local <= local0 + 1e-6 or at_local > local1 + 1e-6:
				continue
			var w := float(p[1])
			if absf(w - prev) < 0.05:
				continue
			edges.append({"t": _to_abs(at_local, restore_h, aligned), "w": w})
			prev = w
		if not loop:
			break
		n += 1.0
	return {"w0": w0, "edges": edges}


static func _sweep(tracks: Array, edges: Array, t0: float, t1: float,
		continuous_w: float, surge_w: float) -> Dictionary:
	edges.sort_custom(func(a, b): return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	var sum := 0.0
	var bsum := {}
	for i in tracks.size():
		var tr: Dictionary = tracks[i]
		var w := float(tr.get("w", 0.0))
		sum += w
		for b_v in tr.get("breakers", []) as Array:
			var bid := str(b_v)
			bsum[bid] = float(bsum.get(bid, 0.0)) + w
	var peak := sum
	var bpeak := bsum.duplicate()
	var above_c := 0.0
	var above_s := 0.0
	var cursor := t0
	var idx := 0
	while idx < edges.size():
		var t := float((edges[idx] as Dictionary).get("t", cursor))
		if t > t1:
			break
		if t > cursor:
			var dt_s := (t - cursor) * 3600.0
			if continuous_w >= 0.0 and sum > continuous_w:
				above_c += dt_s
			if surge_w >= 0.0 and sum > surge_w:
				above_s += dt_s
			cursor = t
		# Every edge at this instant, then read the peak.
		while idx < edges.size() and absf(float((edges[idx] as Dictionary).get("t", 0.0)) - t) <= 1e-9:
			var e: Dictionary = edges[idx]
			var ti := int(e.get("idx", 0))
			if ti >= 0 and ti < tracks.size():
				var tr2: Dictionary = tracks[ti]
				var prev := float(tr2.get("w", 0.0))
				var nw := float(e.get("w", prev))
				var d := nw - prev
				tr2["w"] = nw
				tracks[ti] = tr2
				sum += d
				for b2_v in tr2.get("breakers", []) as Array:
					var bid2 := str(b2_v)
					bsum[bid2] = float(bsum.get(bid2, 0.0)) + d
					bpeak[bid2] = maxf(float(bpeak.get(bid2, 0.0)), float(bsum[bid2]))
			idx += 1
		peak = maxf(peak, sum)
	if t1 > cursor:
		var tail := (t1 - cursor) * 3600.0
		if continuous_w >= 0.0 and sum > continuous_w:
			above_c += tail
		if surge_w >= 0.0 and sum > surge_w:
			above_s += tail
	return {"peak": peak, "above_c": above_c, "above_s": above_s, "breaker_peak": bpeak}
