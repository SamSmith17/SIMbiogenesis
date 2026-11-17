class_name ScadaTune
extends RefCounted
## PID tuning from a step test (plans/SCADA_PROCESS_PLAN.md, Phase 4).
##
## fit(): the reading's response to one step of the output, as a simple
## process model:
##   "integrating"      the reading keeps ramping (a tank level): slope per
##                      hour per % of output, plus a delay;
##   "self_regulating"  the reading settles (a temperature): gain per %,
##                      a time constant and a delay (two-point method on the
##                      28.3 % and 63.2 % times; Smith 1972).
## gains(): SIMC rules (Skogestad, "Simple analytic rules for model reduction
## and PID controller tuning", J. Process Control 13, 2003):
##   self-regulating  Kc = τ / (k (τc + θ)),  Ti = min(τ, 4 (τc + θ))
##   integrating      Kc = 1 / (k' (τc + θ)), Ti = 4 (τc + θ)
## with τc the wanted closed-loop time constant (default: the larger of the
## delay and `min_tc_h`). The result is an ESTIMATE from one test.
##
## Units: hours, the reading's own units, output in %. Gains come back in the
## PID block's units (kp in % per unit, ti in minutes).
##
## Pure and autoload-free.


## Least-squares line y = a + b·t over the samples from index i0. → [a, b].
static func _line(t: Array, y: Array, i0: int) -> Array:
	var n := t.size() - i0
	if n < 2:
		return [float(y[y.size() - 1]) if not y.is_empty() else 0.0, 0.0]
	var st := 0.0
	var sy := 0.0
	var stt := 0.0
	var sty := 0.0
	for i in range(i0, t.size()):
		st += float(t[i])
		sy += float(y[i])
		stt += float(t[i]) * float(t[i])
		sty += float(t[i]) * float(y[i])
	var den := n * stt - st * st
	if absf(den) < 1e-12:
		return [sy / n, 0.0]
	var b := (n * sty - st * sy) / den
	return [(sy - b * st) / n, b]


## `t_h` (0 at the step), `pv`, `du` (the output step, %), `slope0` (the
## reading's drift per hour before the step). → {ok, why, kind, gain, tau_h,
## delay_h, reverse}.
static func fit(t_h: Array, pv: Array, du: float, slope0: float = 0.0) -> Dictionary:
	if t_h.size() < 6 or t_h.size() != pv.size() or absf(du) < 1e-6:
		return {"ok": false, "why": "Not enough of a test to read."}
	var y: Array = []
	for i in t_h.size():
		y.append(float(pv[i]) - float(pv[0]) - slope0 * float(t_h[i]))
	var total := float(t_h[t_h.size() - 1])
	var y_end := float(y[y.size() - 1])
	var span := 0.0
	for v in y:
		span = maxf(span, absf(float(v)))
	if span < 1e-4 or total <= 0.0:
		return {"ok": false, "why": "The reading did not move when the output did."}
	var third := int(t_h.size() * 2.0 / 3.0)
	var tail := _line(t_h, y, third)
	var tail_slope := float(tail[1])
	# Still ramping at the end → integrating.
	if absf(tail_slope) * total > 0.5 * absf(y_end):
		var delay := 0.0
		if absf(tail_slope) > 1e-9:
			delay = clampf(-float(tail[0]) / tail_slope, 0.0, total * 0.5)
		var kprime := tail_slope / du
		return {"ok": true, "why": "", "kind": "integrating", "gain": absf(kprime), "tau_h": 0.0, "delay_h": delay,
			"reverse": kprime < 0.0}
	var t28 := _time_to(t_h, y, 0.283 * y_end)
	var t63 := _time_to(t_h, y, 0.632 * y_end)
	var tau := maxf(1.5 * (t63 - t28), 1e-4)
	var th := maxf(t63 - tau, 0.0)
	var k := y_end / du
	return {"ok": true, "why": "", "kind": "self_regulating", "gain": absf(k), "tau_h": tau, "delay_h": th, "reverse": k < 0.0}


## First time the response passes `level` (linear between samples).
static func _time_to(t: Array, y: Array, level: float) -> float:
	var up := level >= 0.0
	for i in range(1, t.size()):
		var a := float(y[i - 1])
		var b := float(y[i])
		if (up and a < level and b >= level) or (not up and a > level and b <= level):
			var f := (level - a) / (b - a) if absf(b - a) > 1e-12 else 0.0
			return lerpf(float(t[i - 1]), float(t[i]), f)
	return float(t[t.size() - 1])


## SIMC gains for a fit. `min_tc_h` = the fastest loop worth asking for (a
## few of the controller's own steps). → {ok, kp, ti_min, td_min, reverse,
## tc_h, text}.
static func gains(f: Dictionary, min_tc_h: float = 1.0 / 60.0) -> Dictionary:
	if not bool(f.get("ok", false)):
		return {"ok": false, "text": str(f.get("why", "No fit."))}
	var th := float(f["delay_h"])
	var tc := maxf(th, min_tc_h)
	var k := float(f["gain"])
	if k < 1e-9:
		return {"ok": false, "text": "The reading barely answers the output."}
	var kp := 0.0
	var ti_h := 0.0
	var text := ""
	if str(f["kind"]) == "integrating":
		kp = 1.0 / (k * (tc + th))
		ti_h = 4.0 * (tc + th)
		text = "The reading ramps %s per hour for each %% of output (it never settles by itself)." % _n(k)
	else:
		var tau := float(f["tau_h"])
		kp = tau / (k * (tc + th))
		ti_h = minf(tau, 4.0 * (tc + th))
		text = "Each %% of output moves the reading %s, settling in about %s." % [_n(k), _dur(tau * 3.0)]
	if th > 1e-4:
		text += " It answers after %s." % _dur(th)
	return {"ok": true, "kp": snappedf(clampf(kp, 0.01, 1000.0), 0.01), "ti_min": snappedf(clampf(ti_h * 60.0, 0.1, 100000.0), 0.1),
		"td_min": 0.0, "reverse": bool(f.get("reverse", false)), "tc_h": tc, "text": text}


static func _n(v: float) -> String:
	var a := absf(v)
	if a >= 100.0:
		return str(int(round(v)))
	if a >= 1.0:
		return str(snappedf(v, 0.1))
	return str(snappedf(v, 0.001))


static func _dur(h: float) -> String:
	if h >= 2.0:
		return "%s h" % str(snappedf(h, 0.1))
	if h * 60.0 >= 2.0:
		return "%d min" % int(round(h * 60.0))
	return "%d s" % int(round(h * 3600.0))
