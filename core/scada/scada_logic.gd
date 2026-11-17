class_name ScadaLogic
extends RefCounted
## Control blocks (plans/SCADA_PROCESS_PLAN.md, Phase 4). A block reads tags
## and writes tags; the caller supplies the reading and applies the writes.
## Everything runs on SIM time and all of it is a plain dictionary, so it
## snapshots, restores and scrubs.
##
##   step(blocks, state, read, now_h) → {state, writes, status}
##     read    Callable(tag id) -> float (NAN = no reading)
##     writes  {tag id: value} to apply now (switches 0 / 1, numbers as is)
##     status  {block id: {text, level "ok" | "warn" | "off", pv, sp, out, …}}
##
## Kinds (a block is {id, kind, name, enabled, …}):
##   band       on / off with a gap. {pv, low, high, out, direction}
##              direction "fill": on below `low`, off above `high` (a pump
##              filling a tank, a heater); "drain": the other way round.
##   pid        {pv, sp, kp, ti_min, td_min, out, out_min, out_max, reverse,
##              mode "auto" | "manual", manual_out}
##              out = bias + kp·(e + ∫e/Ti + Td·de/dt), e = sp − pv (reverse:
##              pv − sp); kp in % of output per unit of pv. The derivative is
##              on the MEASUREMENT (no kick on a setpoint change) and the
##              integral stops while the output is pinned at a limit in the
##              direction it is pushing (conditional integration).
##              (Åström & Hägglund, Advanced PID Control, 2006, ch. 3.)
##   interlock  {when: [{tag, op, value}], match "any" | "all", out, safe,
##              latch} : while its condition holds, `out` is FORCED to `safe`
##              and no other block's write to it gets through. With `latch`
##              it stays tripped until reset. A condition with no reading
##              counts as true (fail safe).
##   timer      {out, on_min, off_min, offset_min}: a repeating cycle, a pure
##              function of the clock.
##   counter    {pv, op, value}: counts each time its condition becomes true.
##   sequence   {steps: [{name, set: [{tag, value}], until: {tag, op, value},
##              min_s, timeout_s}], repeat}: one step at a time. A step sets
##              its tags, waits at least `min_s`, then moves on when `until`
##              holds (no `until` = after `min_s`). Past `timeout_s` it stops
##              with "timed out". run / hold / abort through `command`.
##
##   duty       {when: [{tag, op, value}], outs: [a, b], swap_h, assist:
##              {tag, op, value}}: two machines sharing one job. While any
##              `when` condition holds the LEAD runs; the other stands by,
##              and runs too while `assist` holds. The lead changes at the
##              next start once it has run `swap_h` hours (even wear).
##
## Each block also offers tags of its own (`tags`): logic.<id>.out, .sp,
## .tripped, .step, .count: so one block can read another.
##
## Pure and autoload-free.

const KINDS := ["band", "pid", "interlock", "timer", "counter", "sequence", "duty"]
const KIND_LABELS := {"band": "On / off band", "pid": "PID loop", "interlock": "Interlock",
	"timer": "Timer", "counter": "Counter", "sequence": "Sequence", "duty": "Duty / standby pair"}
const OPS := [">", ">=", "<", "<=", "==", "!="]
## A step longer than this integrates nothing (a jump, a reload).
const MAX_DT_H := 0.5


static func compare(a: float, op: String, b: float) -> bool:
	match op:
		">":
			return a > b
		">=":
			return a >= b
		"<":
			return a < b
		"<=":
			return a <= b
		"==":
			return absf(a - b) < 1e-6
		"!=":
			return absf(a - b) >= 1e-6
	return false


static func _cond(c: Dictionary, read: Callable, when_unknown: bool) -> bool:
	var tag := str(c.get("tag", ""))
	if tag.is_empty():
		return false
	var v: float = read.call(tag)
	if is_nan(v):
		return when_unknown
	return compare(v, str(c.get("op", ">")), float(c.get("value", 0.0)))


## A new block of `kind` with sensible numbers.
static func make(kind: String, id: String, name: String = "") -> Dictionary:
	var b := {"id": id, "kind": kind, "name": name if not name.is_empty() else str(KIND_LABELS.get(kind, kind)), "enabled": true}
	match kind:
		"band":
			b.merge({"pv": "", "low": 30.0, "high": 80.0, "out": "", "direction": "fill"})
		"pid":
			b.merge({"pv": "", "sp": 50.0, "kp": 4.0, "ti_min": 10.0, "td_min": 0.0, "out": "", "out_min": 0.0,
				"out_max": 100.0, "reverse": false, "mode": "auto", "manual_out": 0.0, "bias": 0.0})
		"interlock":
			b.merge({"when": [{"tag": "", "op": ">", "value": 90.0}], "match": "any", "out": "", "safe": 0.0, "latch": false})
		"timer":
			b.merge({"out": "", "on_min": 15.0, "off_min": 45.0, "offset_min": 0.0})
		"counter":
			b.merge({"pv": "", "op": ">", "value": 0.5})
		"sequence":
			b.merge({"steps": [], "repeat": false})
		"duty":
			b.merge({"when": [{"tag": "", "op": "<", "value": 40.0}], "outs": ["", ""], "swap_h": 24.0,
				"assist": {"tag": "", "op": "<", "value": 15.0}})
	return b


## Timer: whether it is on at `now_h` (pure).
static func timer_on(b: Dictionary, now_h: float) -> bool:
	var on_m := maxf(float(b.get("on_min", 0.0)), 0.0)
	var off_m := maxf(float(b.get("off_min", 0.0)), 0.0)
	if on_m + off_m <= 0.0:
		return false
	var t := fposmod(now_h * 60.0 - float(b.get("offset_min", 0.0)), on_m + off_m)
	return t < on_m


static func step(blocks: Array, state: Dictionary, read: Callable, now_h: float) -> Dictionary:
	var st: Dictionary = state.duplicate(true)
	var last := float(st.get("_last_h", NAN))
	var dt_h := 0.0
	if not is_nan(last) and now_h > last and now_h - last <= MAX_DT_H:
		dt_h = now_h - last
	var rewound := not is_nan(last) and now_h < last
	st["_last_h"] = now_h
	var writes := {}
	var status := {}
	var forced := {}
	for b in blocks:
		if not (b is Dictionary):
			continue
		var id := str(b.get("id", ""))
		var bs: Dictionary = st.get(id, {}) as Dictionary
		if not bool(b.get("enabled", true)):
			status[id] = {"text": "Off", "level": "off"}
			st[id] = bs
			continue
		match str(b.get("kind", "")):
			"band":
				status[id] = _band(b, bs, read, writes)
			"pid":
				status[id] = _pid(b, bs, read, writes, dt_h, rewound)
			"interlock":
				status[id] = _interlock(b, bs, read, forced)
			"timer":
				var on := timer_on(b, now_h)
				if not str(b.get("out", "")).is_empty():
					writes[str(b["out"])] = 1.0 if on else 0.0
				status[id] = {"text": "On" if on else "Off", "level": "ok", "out": 1.0 if on else 0.0}
			"counter":
				var hit := _cond(b.duplicate() if b.has("tag") else {"tag": b.get("pv", ""), "op": b.get("op", ">"), "value": b.get("value", 0.5)}, read, false)
				if hit and not bool(bs.get("was", false)):
					bs["count"] = int(bs.get("count", 0)) + 1
				bs["was"] = hit
				status[id] = {"text": "%d" % int(bs.get("count", 0)), "level": "ok", "count": int(bs.get("count", 0))}
			"sequence":
				status[id] = _sequence(b, bs, read, writes, now_h, rewound)
			"duty":
				status[id] = _duty(b, bs, read, writes, dt_h)
		st[id] = bs
	# Interlocks win.
	for tag in forced:
		writes[tag] = forced[tag]
	return {"state": st, "writes": writes, "status": status, "forced": forced}


static func _band(b: Dictionary, bs: Dictionary, read: Callable, writes: Dictionary) -> Dictionary:
	var pv: float = read.call(str(b.get("pv", "")))
	var low := float(b.get("low", 0.0))
	var high := float(b.get("high", 0.0))
	var on := bool(bs.get("on", false))
	if is_nan(pv):
		return {"text": "No reading: holding %s" % ("on" if on else "off"), "level": "warn"}
	var fill := str(b.get("direction", "fill")) != "drain"
	if pv <= low:
		on = fill
	elif pv >= high:
		on = not fill
	bs["on"] = on
	if not str(b.get("out", "")).is_empty():
		writes[str(b["out"])] = 1.0 if on else 0.0
	return {"text": "%s (holding %s to %s)" % ["On" if on else "Off", _n(low), _n(high)], "level": "ok", "pv": pv, "out": 1.0 if on else 0.0}


static func _pid(b: Dictionary, bs: Dictionary, read: Callable, writes: Dictionary, dt_h: float, rewound: bool) -> Dictionary:
	var lo := float(b.get("out_min", 0.0))
	var hi := maxf(float(b.get("out_max", 100.0)), lo)
	var sp := float(bs.get("sp", b.get("sp", 0.0)))
	if not bs.has("sp_from") or float(bs.get("sp_from", NAN)) != float(b.get("sp", 0.0)):
		# The block's setpoint was edited: it wins over an operator's.
		sp = float(b.get("sp", 0.0))
		bs["sp_from"] = float(b.get("sp", 0.0))
	bs["sp"] = sp
	var out_tag := str(b.get("out", ""))
	var mode := str(bs.get("mode", b.get("mode", "auto")))
	var pv: float = read.call(str(b.get("pv", "")))
	if mode == "manual":
		var mo := clampf(float(bs.get("manual_out", b.get("manual_out", 0.0))), lo, hi)
		bs["out"] = mo
		# Bumpless back to auto: the integral is set so the output starts here.
		bs["i"] = mo - float(b.get("bias", 0.0))
		bs["pv_prev"] = pv
		if not out_tag.is_empty():
			writes[out_tag] = mo
		return {"text": "Manual · %s %%" % _n(mo), "level": "ok", "pv": pv, "sp": sp, "out": mo, "mode": "manual"}
	if is_nan(pv):
		var held := float(bs.get("out", lo))
		if not out_tag.is_empty():
			writes[out_tag] = held
		return {"text": "No reading: holding %s %%" % _n(held), "level": "warn", "sp": sp, "out": held, "mode": "auto"}
	var e := (pv - sp) if bool(b.get("reverse", false)) else (sp - pv)
	var kp := float(b.get("kp", 1.0))
	var ti_h := float(b.get("ti_min", 0.0)) / 60.0
	var td_h := float(b.get("td_min", 0.0)) / 60.0
	var integ := float(bs.get("i", 0.0))
	if rewound:
		dt_h = 0.0
	var d := 0.0
	var prev := float(bs.get("pv_prev", NAN))
	if dt_h > 0.0 and td_h > 0.0 and not is_nan(prev):
		var dpv := (pv - prev) / dt_h
		d = -kp * td_h * (dpv if not bool(b.get("reverse", false)) else -dpv)
	var p := kp * e
	var bias := float(b.get("bias", 0.0))
	var raw := bias + p + integ + d
	if dt_h > 0.0 and ti_h > 0.0:
		var di := kp * e * dt_h / ti_h
		# Stop winding up against a limit.
		if not ((raw >= hi and di > 0.0) or (raw <= lo and di < 0.0)):
			integ += di
			raw = bias + p + integ + d
	var out := clampf(raw, lo, hi)
	bs["i"] = integ
	bs["pv_prev"] = pv
	bs["out"] = out
	if not out_tag.is_empty():
		writes[out_tag] = out
	return {"text": "Auto · %s → %s · out %s %%" % [_n(pv), _n(sp), _n(out)], "level": "ok", "pv": pv, "sp": sp,
		"out": out, "mode": "auto", "saturated": out <= lo or out >= hi}


static func _interlock(b: Dictionary, bs: Dictionary, read: Callable, forced: Dictionary) -> Dictionary:
	var conds: Array = b.get("when", []) as Array
	var any := str(b.get("match", "any")) != "all"
	var hit := not any and not conds.is_empty()
	for c in conds:
		var ok := _cond(c as Dictionary, read, true)
		if any and ok:
			hit = true
		if not any and not ok:
			hit = false
	var tripped := hit
	if bool(b.get("latch", false)) and bool(bs.get("tripped", false)):
		tripped = true
	bs["tripped"] = tripped
	if tripped and not str(b.get("out", "")).is_empty():
		forced[str(b["out"])] = float(b.get("safe", 0.0))
	var text := "Ready"
	if tripped:
		text = "TRIPPED" + (" (reset it once it is clear)" if bool(b.get("latch", false)) and not hit else "")
	return {"text": text, "level": "warn" if tripped else "ok", "tripped": tripped, "clear": not hit}


static func _sequence(b: Dictionary, bs: Dictionary, read: Callable, writes: Dictionary, now_h: float, rewound: bool) -> Dictionary:
	var steps: Array = b.get("steps", []) as Array
	# "autostart": it runs from the start of the batch without a Start.
	if bool(b.get("autostart", false)) and not bs.has("run"):
		bs["run"] = "running"
	var run := str(bs.get("run", "idle"))
	if steps.is_empty():
		return {"text": "No steps yet", "level": "off", "step": -1, "run": "idle"}
	if run == "idle" or run == "done" or run == "aborted" or run == "timeout":
		var words := {"idle": "Ready", "done": "Done", "aborted": "Aborted", "timeout": "Timed out at step %d" % (int(bs.get("step", 0)) + 1)}
		return {"text": str(words[run]), "level": "warn" if run == "timeout" else "off", "step": int(bs.get("step", -1)), "run": run}
	var i := clampi(int(bs.get("step", 0)), 0, steps.size() - 1)
	if rewound or not bs.has("since_h"):
		bs["since_h"] = now_h
	var s: Dictionary = steps[i]
	var in_s := (now_h - float(bs["since_h"])) * 3600.0
	if run == "held":
		bs["since_h"] = now_h - float(bs.get("held_s", 0.0)) / 3600.0
		return {"text": "Held at step %d: %s" % [i + 1, str(s.get("name", ""))], "level": "warn", "step": i, "run": run}
	bs["held_s"] = in_s
	for a in s.get("set", []):
		if a is Dictionary and not str((a as Dictionary).get("tag", "")).is_empty():
			writes[str(a["tag"])] = float((a as Dictionary).get("value", 0.0))
	var until: Dictionary = s.get("until", {}) as Dictionary
	var min_s := maxf(float(s.get("min_s", 0.0)), 0.0)
	var timeout_s := float(s.get("timeout_s", 0.0))
	var done := in_s >= min_s and (str(until.get("tag", "")).is_empty() or _cond(until, read, false))
	if str(until.get("tag", "")).is_empty() and min_s <= 0.0:
		done = in_s > 0.0
	if done:
		if i + 1 >= steps.size():
			if bool(b.get("repeat", false)):
				bs["step"] = 0
				bs["since_h"] = now_h
				bs["runs"] = int(bs.get("runs", 0)) + 1
			else:
				bs["run"] = "done"
				bs["runs"] = int(bs.get("runs", 0)) + 1
				return {"text": "Done", "level": "off", "step": i, "run": "done"}
		else:
			bs["step"] = i + 1
			bs["since_h"] = now_h
	elif timeout_s > 0.0 and in_s > timeout_s:
		bs["run"] = "timeout"
		return {"text": "Timed out at step %d: %s" % [i + 1, str(s.get("name", ""))], "level": "warn", "step": i, "run": "timeout"}
	return {"text": "Step %d of %d: %s" % [i + 1, steps.size(), str(s.get("name", ""))], "level": "ok", "step": i, "run": "running"}


static func _duty(b: Dictionary, bs: Dictionary, read: Callable, writes: Dictionary, dt_h: float) -> Dictionary:
	var outs: Array = b.get("outs", []) as Array
	if outs.size() < 2 or str(outs[0]).is_empty() or str(outs[1]).is_empty():
		return {"text": "Needs two machines", "level": "off", "lead": 0}
	var demand := false
	for c in b.get("when", []):
		if c is Dictionary and _cond(c as Dictionary, read, false):
			demand = true
	var lead := int(bs.get("lead", 0)) % 2
	# The lead changes at a START, once it has done its hours.
	if demand and not bool(bs.get("was", false)) and float(bs.get("run_h", 0.0)) >= float(b.get("swap_h", 24.0)):
		lead = 1 - lead
		bs["run_h"] = 0.0
	if demand:
		bs["run_h"] = float(bs.get("run_h", 0.0)) + dt_h
	bs["was"] = demand
	bs["lead"] = lead
	var a: Dictionary = b.get("assist", {}) as Dictionary
	var assist := demand and not str(a.get("tag", "")).is_empty() and _cond(a, read, false)
	writes[str(outs[lead])] = 1.0 if demand else 0.0
	writes[str(outs[1 - lead])] = 1.0 if assist else 0.0
	var text := "Standing by · %s leads" % ("A" if lead == 0 else "B")
	if demand:
		text = "Both running" if assist else "%s running · %s h on this turn" % ["A" if lead == 0 else "B", _n(float(bs.get("run_h", 0.0)))]
	return {"text": text, "level": "ok", "lead": lead, "running": demand, "assist": assist}


## An operator's command on a block. → the new state.
##   pid:       "auto" | "manual" | "sp" (value) | "out" (value, manual)
##   interlock: "reset"
##   sequence:  "start" | "hold" | "resume" | "abort"
##   counter:   "reset"
static func command(blocks: Array, state: Dictionary, id: String, what: String, value: float = 0.0) -> Dictionary:
	var st: Dictionary = state.duplicate(true)
	var b := {}
	for x in blocks:
		if x is Dictionary and str((x as Dictionary).get("id", "")) == id:
			b = x
	if b.is_empty():
		return st
	var bs: Dictionary = st.get(id, {}) as Dictionary
	match str(b.get("kind", "")):
		"pid":
			if what == "auto" or what == "manual":
				if what == "manual" and str(bs.get("mode", b.get("mode", "auto"))) != "manual":
					bs["manual_out"] = float(bs.get("out", b.get("manual_out", 0.0)))
				bs["mode"] = what
			elif what == "sp":
				bs["sp"] = value
				bs["sp_from"] = float(b.get("sp", 0.0))
			elif what == "out":
				bs["manual_out"] = value
		"interlock":
			if what == "reset":
				bs["tripped"] = false
		"counter":
			if what == "reset":
				bs["count"] = 0
		"duty":
			if what == "swap":
				bs["lead"] = 1 - int(bs.get("lead", 0)) % 2
				bs["run_h"] = 0.0
		"sequence":
			match what:
				"start":
					bs["run"] = "running"
					bs["step"] = 0
					bs.erase("since_h")
				"hold":
					if str(bs.get("run", "")) == "running":
						bs["run"] = "held"
				"resume":
					if str(bs.get("run", "")) == "held":
						bs["run"] = "running"
				"abort":
					bs["run"] = "aborted"
	st[id] = bs
	return st


## The blocks' own tags (ScadaTags shape minus `make`: plain dicts so this
## file stays free of the tag class): [{id, label, unit, kind, value, group}].
static func tags(blocks: Array, status: Dictionary) -> Array:
	var out: Array = []
	for b in blocks:
		if not (b is Dictionary):
			continue
		var id := str(b.get("id", ""))
		var s: Dictionary = status.get(id, {}) as Dictionary
		var grp := str(b.get("name", id))
		match str(b.get("kind", "")):
			"pid":
				out.append({"id": "logic.%s.out" % id, "label": "Output", "unit": "%", "kind": "sensor", "value": float(s.get("out", NAN)), "group": grp})
				out.append({"id": "logic.%s.sp" % id, "label": "Setpoint", "unit": "", "kind": "sensor", "value": float(s.get("sp", NAN)), "group": grp})
			"band", "timer":
				out.append({"id": "logic.%s.out" % id, "label": "Output", "unit": "", "kind": "binary", "value": float(s.get("out", NAN)), "group": grp})
			"interlock":
				out.append({"id": "logic.%s.tripped" % id, "label": "Tripped", "unit": "", "kind": "binary", "value": 1.0 if bool(s.get("tripped", false)) else 0.0, "group": grp})
			"counter":
				out.append({"id": "logic.%s.count" % id, "label": "Count", "unit": "", "kind": "sensor", "value": float(s.get("count", 0)), "group": grp})
			"duty":
				out.append({"id": "logic.%s.lead" % id, "label": "Leading (1 or 2)", "unit": "", "kind": "sensor", "value": float(int(s.get("lead", 0)) + 1), "group": grp})
			"sequence":
				out.append({"id": "logic.%s.step" % id, "label": "Step", "unit": "", "kind": "sensor", "value": float(int(s.get("step", -1)) + 1), "group": grp})
	return out


## Every tag a block reads or writes: {reads: [..], writes: [..]}.
static func tags_used(b: Dictionary) -> Dictionary:
	var reads: Array = []
	var writes: Array = []
	for k in ["pv"]:
		if not str(b.get(k, "")).is_empty():
			reads.append(str(b[k]))
	if not str(b.get("out", "")).is_empty():
		writes.append(str(b["out"]))
	for c in b.get("when", []):
		if c is Dictionary and not str((c as Dictionary).get("tag", "")).is_empty():
			reads.append(str(c["tag"]))
	for o in b.get("outs", []):
		if not str(o).is_empty():
			writes.append(str(o))
	if b.get("assist") is Dictionary and not str((b["assist"] as Dictionary).get("tag", "")).is_empty():
		reads.append(str(b["assist"]["tag"]))
	for s in b.get("steps", []):
		if not (s is Dictionary):
			continue
		for a in (s as Dictionary).get("set", []):
			if a is Dictionary and not str((a as Dictionary).get("tag", "")).is_empty():
				writes.append(str(a["tag"]))
		var u: Dictionary = (s as Dictionary).get("until", {}) as Dictionary
		if not str(u.get("tag", "")).is_empty():
			reads.append(str(u["tag"]))
	return {"reads": reads, "writes": writes}


## Ready-made blocks. `t` = {pv, out, …} tags to fill in.
static func template(which: String, id: String, t: Dictionary = {}) -> Dictionary:
	match which:
		"hold_level_band":
			var b := make("band", id, "Hold the level (on / off)")
			b.merge({"pv": str(t.get("pv", "")), "out": str(t.get("out", "")), "low": 30.0, "high": 80.0, "direction": "fill"}, true)
			return b
		"hold_level_pid":
			var p := make("pid", id, "Hold the level (PID)")
			p.merge({"pv": str(t.get("pv", "")), "out": str(t.get("out", "")), "sp": 50.0, "kp": 6.0, "ti_min": 20.0}, true)
			return p
		"overfill":
			var k := make("interlock", id, "Stop on overfill")
			k.merge({"when": [{"tag": str(t.get("pv", "")), "op": ">=", "value": 95.0}], "out": str(t.get("out", "")), "safe": 0.0}, true)
			return k
		"dry_run":
			var d := make("interlock", id, "Dry-run protection")
			d.merge({"when": [{"tag": str(t.get("pv", "")), "op": "<=", "value": 5.0}], "out": str(t.get("out", "")), "safe": 0.0}, true)
			return d
		"hold_temp_band":
			var h := make("band", id, "Hold a temperature (on / off)")
			h.merge({"pv": str(t.get("pv", "")), "out": str(t.get("out", "")), "low": 18.0, "high": 22.0, "direction": "fill"}, true)
			return h
		"duty_standby":
			var dy := make("duty", id, "Duty / standby pumps")
			dy.merge({"when": [{"tag": str(t.get("pv", "")), "op": "<", "value": 40.0}],
				"outs": [str(t.get("out", "")), str(t.get("out2", ""))], "swap_h": 24.0,
				"assist": {"tag": str(t.get("pv", "")), "op": "<", "value": 15.0}}, true)
			return dy
		"cycle":
			var c := make("timer", id, "Run on a cycle")
			c.merge({"out": str(t.get("out", "")), "on_min": 15.0, "off_min": 45.0}, true)
			return c
		"fill_wait_drain":
			var q := make("sequence", id, "Fill, wait, drain")
			q["steps"] = [
				{"name": "Fill", "set": [{"tag": str(t.get("out", "")), "value": 1.0}, {"tag": str(t.get("out2", "")), "value": 0.0}],
					"until": {"tag": str(t.get("pv", "")), "op": ">=", "value": 80.0}, "min_s": 0.0, "timeout_s": 7200.0},
				{"name": "Wait", "set": [{"tag": str(t.get("out", "")), "value": 0.0}], "until": {}, "min_s": 600.0, "timeout_s": 0.0},
				{"name": "Drain", "set": [{"tag": str(t.get("out2", "")), "value": 1.0}],
					"until": {"tag": str(t.get("pv", "")), "op": "<=", "value": 10.0}, "min_s": 0.0, "timeout_s": 7200.0},
				{"name": "Close", "set": [{"tag": str(t.get("out2", "")), "value": 0.0}], "until": {}, "min_s": 1.0, "timeout_s": 0.0},
			]
			return q
	return make("band", id)


const TEMPLATES := [
	["hold_level_band", "Hold a level (on / off)", "Switch a pump or valve on below a low mark and off above a high one."],
	["hold_level_pid", "Hold a level (PID)", "Move a control valve a little at a time to keep a reading on its setpoint."],
	["hold_temp_band", "Hold a temperature (on / off)", "Switch a heater on below a low mark and off above a high one (pick \"drain\" for a cooler or a fan)."],
	["duty_standby", "Duty / standby pumps", "Two pumps share one job: one runs, the other stands by and helps when it is not enough; they take turns."],
	["overfill", "Stop on overfill", "Force a pump or valve off while a tank is nearly full, whatever else asks for it."],
	["dry_run", "Dry-run protection", "Force a pump off while its tank is nearly empty."],
	["cycle", "Run on a cycle", "On for so many minutes, off for so many, round the clock."],
	["fill_wait_drain", "Fill, wait, drain", "A batch: fill to a mark, hold, empty, close."],
]


static func _n(v: float) -> String:
	if is_nan(v):
		return "?"
	return str(snappedf(v, 0.1)) if absf(v) < 100.0 else str(int(round(v)))
