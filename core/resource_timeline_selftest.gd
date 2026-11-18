extends SceneTree

## ResourceTimeline against a frozen copy of the version before the head-offset
## trim (RefTL below, copied from core/resource_timeline.gd at e9029f9): the
## same random operations on both, every answer compared exactly. Offline.
##   Godot --headless --path . --script core/resource_timeline_selftest.gd

const EXPECTED_CHECKS := 6

var _checks := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL: " + what)


func _initialize() -> void:
	for seed_v in [1, 2, 3]:
		_check(_run(seed_v, false), "random run %d (no evaluator) matches the frozen copy" % seed_v)
		_check(_run(seed_v + 10, true), "random run %d (evaluator) matches the frozen copy" % (seed_v + 10))
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("RESOURCE TIMELINE SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _eval_at(h: float) -> Dictionary:
	return {"net_qty_per_hour": 40.0 * sin(h * 0.7), "inflow_rate": 3.0 + sin(h), "outflow_rate": 1.5}


func _run(seed_v: int, with_eval: bool) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var a := ResourceTimeline.new()
	var b := RefTL.new()
	var ev := Callable(self, "_eval_at")
	if with_eval:
		a.set_evaluator(ev)
		b.set_evaluator(ev)
	a.configure(500.0)
	b.configure(500.0)
	var h := 1000.0 + rng.randf() * 10.0
	a.init_anchor(h, 0.4)
	b.init_anchor(h, 0.4)
	var bad := ""
	for op in 6000:
		var r := rng.randi_range(0, 99)
		if r < 45:
			var gap := 1
			var g := rng.randi_range(0, 99)
			if g < 50:
				gap = rng.randi_range(1, 3)
			elif g < 85:
				gap = rng.randi_range(4, 60)
			elif g < 98:
				gap = rng.randi_range(61, 6000)
			else:
				gap = rng.randi_range(20000, 30000)
			h += float(gap) / 60.0 + rng.randf() * 0.01
			var net := rng.randf_range(-300.0, 300.0)
			var infl := maxf(net, 0.0)
			var outf := maxf(-net, 0.0)
			a.record_step(h, net, infl, outf)
			b.record_step(h, net, infl, outf)
		elif r < 60:
			var span := float(b.last_step() - b.first_step() + 1) / 60.0
			var t := float(b.first_step()) / 60.0 + rng.randf_range(-0.5, span + 0.5)
			if a.sample_at(t) != b.sample_at(t) or a.level_at(t) != b.level_at(t) \
					or a.is_overflowing_at(t) != b.is_overflowing_at(t):
				bad = "sample_at %.4f" % t
		elif r < 68:
			var span2 := float(b.last_step() - b.first_step() + 1) / 60.0
			var t2 := float(b.first_step()) / 60.0 + rng.randf_range(-3.0, span2 + 3.0)
			var sa := a.seek(t2)
			var sb := b.seek(t2)
			if sa != sb:
				bad = "seek %.4f" % t2
			if rng.randf() < 0.3:
				h = maxf(h, t2)
		elif r < 72:
			var span3 := float(b.last_step() - b.first_step() + 1) / 60.0
			var t3 := float(b.first_step()) / 60.0 + rng.randf() * span3
			a.truncate_after(t3)
			b.truncate_after(t3)
			h = float(b.last_step()) / 60.0 + 0.001
		elif r < 76:
			var lv := rng.randf()
			h += rng.randf() * 0.05
			a.set_current_level(h, lv)
			b.set_current_level(h, lv)
		elif r < 84:
			var span4 := float(b.last_step() - b.first_step() + 1) / 60.0
			var t4 := float(b.first_step()) / 60.0 + rng.randf_range(-1.0, span4 + 1.0)
			var t5 := t4 + rng.randf() * 50.0
			if a.pct_slice(t4, t5) != b.pct_slice(t4, t5):
				bad = "pct_slice %.3f..%.3f" % [t4, t5]
			for ch in ["inflow", "outflow", "net"]:
				if a.integrate_channel(t4, t5, ch) != b.integrate_channel(t4, t5, ch):
					bad = "integrate_channel %s" % ch
		elif r < 86:
			a.configure(rng.randf_range(50.0, 5000.0))
			b.capacity_qty = a.capacity_qty
		elif r < 87:
			var lv2 := rng.randf()
			a.init_anchor(h, lv2)
			b.init_anchor(h, lv2)
		if a.first_step() != b.first_step() or a.last_step() != b.last_step() \
				or a.total_overflow_qty != b.total_overflow_qty or a.is_empty() != b.is_empty():
			bad = "extent / overflow after op %d (%d..%d vs %d..%d)" % [op, a.first_step(), a.last_step(), b.first_step(), b.last_step()]
		if not bad.is_empty():
			print("  run %d: first difference at op %d: %s" % [seed_v, op, bad])
			return false
	return true


class RefTL:
	extends RefCounted

	## Reversible resource-level buffer for graph resource containers.
	## Mirrors EnergyTimeline: forward-integrate on record_step(), read-back on scrub.
	## At high sim speeds, large gaps use strided fills (fewer integrations) while
	## keeping the 1-minute index grid for scrub — net endpoint / overflow for a
	## constant rate match a single closed-form step over the full dt.

	var capacity_qty: float = 100.0
	var step_hours: float = 1.0 / 60.0
	const MAX_SAMPLES: int = 20160
	## Above this many pending minute-steps, integrate in chunks (see record_step).
	const COARSE_THRESHOLD_STEPS: int = 10
	const COARSE_STRIDE_STEPS: int = 5

	var _base_step: int = 0
	var _level: PackedFloat32Array = PackedFloat32Array()
	var _inflow: PackedFloat32Array = PackedFloat32Array()
	var _outflow: PackedFloat32Array = PackedFloat32Array()

	## Cumulative quantity lost to the full-tank clamp during forward integration
	## (record_step / _fill_forward_to). Mass is NOT silently conserved on overflow —
	## this counter lets the flow engine surface the loss instead of hiding it.
	var total_overflow_qty: float = 0.0

	var _eval: Callable = Callable()


	static func step_level(level: float, net_qty_per_hour: float, capacity: float,
			dt_hours: float) -> float:
		if capacity <= 0.0 or dt_hours <= 0.0:
			return clampf(level, 0.0, 1.0)
		var delta := (net_qty_per_hour * dt_hours) / capacity
		return clampf(level + delta, 0.0, 1.0)


	## Quantity (same units as capacity) that step_level would discard to the
	## 0..1 clamp on THIS step when the tank tops out. 0 when capacity invalid.
	static func step_overflow_qty(level: float, net_qty_per_hour: float, capacity: float,
			dt_hours: float) -> float:
		if capacity <= 0.0 or dt_hours <= 0.0:
			return 0.0
		var raw := level + (net_qty_per_hour * dt_hours) / capacity
		return maxf(raw - 1.0, 0.0) * capacity


	static func unstep_level(level: float, net_qty_per_hour: float, capacity: float,
			dt_hours: float) -> float:
		if capacity <= 0.0 or dt_hours <= 0.0:
			return clampf(level, 0.0, 1.0)
		var delta := (net_qty_per_hour * dt_hours) / capacity
		return clampf(level - delta, 0.0, 1.0)


	func configure(capacity: float) -> void:
		capacity_qty = maxf(capacity, 0.001)


	func set_evaluator(cb: Callable) -> void:
		_eval = cb


	func clear() -> void:
		_level = PackedFloat32Array()
		_inflow = PackedFloat32Array()
		_outflow = PackedFloat32Array()
		_base_step = 0
		total_overflow_qty = 0.0


	func is_empty() -> bool:
		return _level.is_empty()


	func _step_of(abs_hours: float) -> int:
		return int(floor(abs_hours / step_hours))


	func step_of(abs_hours: float) -> int:
		return _step_of(abs_hours)


	func time_of_step(g: int) -> float:
		return float(g) * step_hours


	func first_step() -> int:
		return _base_step


	func last_step() -> int:
		return _base_step + _level.size() - 1


	func init_anchor(abs_hours: float, level: float, inflow: float = 0.0,
			outflow: float = 0.0) -> void:
		clear()
		_base_step = _step_of(abs_hours)
		_level.append(clampf(level, 0.0, 1.0))
		_inflow.append(inflow)
		_outflow.append(outflow)


	## Overwrite the level at the current (last) step WITHOUT discarding prior history
	## — for an external driver that sets a tank's level while the sim clock is frozen
	## (paused Hydro Lab test-inflow). Unlike clear()+init_anchor (which nuked every
	## earlier sample, so scrubbing back over pre-pause history was lost), this keeps
	## the recorded past intact and just re-points the present level.
	func set_current_level(abs_hours: float, level: float) -> void:
		if is_empty():
			init_anchor(abs_hours, level)
			return
		var g := _step_of(abs_hours)
		if g > last_step():
			record_step(abs_hours, 0.0)
		_level[_level.size() - 1] = clampf(level, 0.0, 1.0)


	func record_step(abs_hours: float, net_qty_per_hour: float,
			inflow: float = 0.0, outflow: float = 0.0) -> void:
		if is_empty():
			init_anchor(abs_hours, 0.0, inflow, outflow)
			return
		var target_g := _step_of(abs_hours)
		var cur_g := last_step()
		if target_g <= cur_g:
			return
		var lvl := float(_level[_level.size() - 1])
		var steps := target_g - cur_g

		# Gap wider than retention — closed-form skip (trimmed immediately anyway).
		var skip_steps := maxi(0, steps - MAX_SAMPLES)
		if skip_steps > 0:
			var skip_dt := float(skip_steps) * step_hours
			total_overflow_qty += step_overflow_qty(lvl, net_qty_per_hour, capacity_qty, skip_dt)
			lvl = step_level(lvl, net_qty_per_hour, capacity_qty, skip_dt)
			steps -= skip_steps

		if steps <= 0:
			return

		# Large fast-forward: strided integrate (fewer clamp steps) then stamp each
		# minute slot so scrub indices stay contiguous. Endpoint + total overflow
		# match a single closed-form over the full remaining dt for constant rate.
		if steps > COARSE_THRESHOLD_STEPS:
			_append_strided_run(lvl, net_qty_per_hour, inflow, outflow, steps, COARSE_STRIDE_STEPS)
		else:
			_append_exact_run(lvl, net_qty_per_hour, inflow, outflow, steps)
		_trim_if_needed()


	## Dense per-minute fill via resize (matches sequential step_level / overflow).
	func _append_exact_run(lvl0: float, net: float, inflow: float, outflow: float,
			steps: int) -> void:
		if steps <= 0:
			return
		var start := _level.size()
		var n := start + steps
		_level.resize(n)
		_inflow.resize(n)
		_outflow.resize(n)
		var lvl := lvl0
		var dt := step_hours
		for k in steps:
			total_overflow_qty += step_overflow_qty(lvl, net, capacity_qty, dt)
			lvl = step_level(lvl, net, capacity_qty, dt)
			_level[start + k] = lvl
			_inflow[start + k] = inflow
			_outflow[start + k] = outflow


	## Integrate in `stride`-minute chunks; replicate each chunk endpoint across
	## the minute slots it covers. Overflow + final level use one closed-form over
	## the full span (constant-rate exact); mid-chunk scrub is stair-stepped.
	func _append_strided_run(lvl0: float, net: float, inflow: float, outflow: float,
			steps: int, stride: int) -> void:
		if steps <= 0:
			return
		stride = maxi(1, stride)
		var full_dt := float(steps) * step_hours
		total_overflow_qty += step_overflow_qty(lvl0, net, capacity_qty, full_dt)
		var start := _level.size()
		var n := start + steps
		_level.resize(n)
		_inflow.resize(n)
		_outflow.resize(n)
		var lvl := lvl0
		var written := 0
		while written < steps:
			var chunk := mini(stride, steps - written)
			var dt := float(chunk) * step_hours
			lvl = step_level(lvl, net, capacity_qty, dt)
			for k in chunk:
				var idx := start + written + k
				_level[idx] = lvl
				_inflow[idx] = inflow
				_outflow[idx] = outflow
			written += chunk
		# Guard against float drift vs closed-form endpoint.
		_level[n - 1] = step_level(lvl0, net, capacity_qty, full_dt)


	## Drop every sample after the step that holds `abs_hours` (mirror of
	## EnergyTimeline.truncate_after). A pre-rendered future is only valid for the
	## graph it was rendered with: a player edit cuts the tank's cache at the
	## playhead and the live step continues from there. Always keeps one sample.
	## `total_overflow_qty` is cumulative and deliberately left alone.
	func truncate_after(abs_hours: float) -> void:
		if is_empty():
			return
		var g := maxi(_step_of(abs_hours), first_step())
		var keep := g - _base_step + 1
		if keep >= _level.size():
			return
		_level.resize(keep)
		_inflow.resize(keep)
		_outflow.resize(keep)


	func seek(abs_hours: float) -> Dictionary:
		if is_empty():
			return {"level": 0.0, "inflow_rate": 0.0, "outflow_rate": 0.0}
		var target_g := _step_of(abs_hours)
		if target_g > last_step():
			_fill_forward_to(target_g)
		elif target_g < first_step():
			_fill_backward_to(target_g)
		return sample_at(abs_hours)


	func sample_at(abs_hours: float) -> Dictionary:
		if is_empty():
			return {"level": 0.0, "inflow_rate": 0.0, "outflow_rate": 0.0}
		var pos := (abs_hours / step_hours) - float(_base_step)
		var i := int(floor(pos))
		if i < 0:
			return _sample_index(0)
		if i >= _level.size() - 1:
			return _sample_index(_level.size() - 1)
		var frac := pos - float(i)
		return {
			"level": lerp(float(_level[i]), float(_level[i + 1]), frac),
			"inflow_rate": lerp(float(_inflow[i]), float(_inflow[i + 1]), frac),
			"outflow_rate": lerp(float(_outflow[i]), float(_outflow[i + 1]), frac),
		}


	func level_at(abs_hours: float) -> float:
		return float(sample_at(abs_hours).get("level", 0.0))


	## Fill percent (0–100) over [abs_start, abs_end], the same shape as
	## EnergyTimeline.channel_slice so the timeline can bin it.
	func pct_slice(abs_start: float, abs_end: float) -> Dictionary:
		var vals := PackedFloat32Array()
		if is_empty() or abs_end < abs_start:
			return {"base_t": 0.0, "step": step_hours, "values": vals}
		var g0 := maxi(_step_of(abs_start), first_step())
		var g1 := mini(_step_of(abs_end), last_step())
		if g1 < g0:
			return {"base_t": 0.0, "step": step_hours, "values": vals}
		var a := g0 - _base_step
		var n := g1 - g0 + 1
		vals.resize(n)
		for k in n:
			vals[k] = 100.0 * float(_level[a + k])
		return {"base_t": time_of_step(g0), "step": step_hours, "values": vals}


	## Scrub-safe instantaneous overflow test: tank pinned at full while inflow
	## exceeds outflow. Derived from the sample buffers, so rewinding clears it.
	func is_overflowing_at(abs_hours: float) -> bool:
		var s := sample_at(abs_hours)
		return float(s.get("level", 0.0)) >= 0.999 \
			and float(s.get("inflow_rate", 0.0)) > float(s.get("outflow_rate", 0.0)) + 0.001


	## Integrate a flow channel over [abs_start, abs_end] → quantity (same units as rates).
	## Channels: "inflow", "outflow", "net" (inflow − outflow).
	func integrate_channel(abs_start: float, abs_end: float, channel: String) -> float:
		if is_empty() or abs_end <= abs_start:
			return 0.0
		var g0 := maxi(_step_of(abs_start), first_step())
		var g1 := mini(_step_of(abs_end), last_step())
		if g1 <= g0:
			return 0.0
		var total := 0.0
		for g: int in range(g0, g1):
			var idx := g - _base_step
			if idx < 0 or idx >= _level.size():
				continue
			var rate := 0.0
			match channel:
				"inflow":
					rate = float(_inflow[idx])
				"outflow":
					rate = float(_outflow[idx])
				"net":
					rate = float(_inflow[idx]) - float(_outflow[idx])
				_:
					rate = 0.0
			total += rate * step_hours
		return total


	func _sample_index(i: int) -> Dictionary:
		return {
			"level": float(_level[i]),
			"inflow_rate": float(_inflow[i]),
			"outflow_rate": float(_outflow[i]),
		}


	func _inputs_at(abs_hours: float, fallback: Dictionary) -> Dictionary:
		if _eval.is_valid():
			var r: Variant = _eval.call(abs_hours)
			if r is Dictionary:
				return r
		return fallback


	func _fill_forward_to(target_g: int) -> void:
		var lvl := float(_level[_level.size() - 1])
		var last := _sample_index(_level.size() - 1)
		var g := last_step()
		var need := target_g - g
		if need <= 0:
			return
		# Prefer bulk fill when the evaluator is idle (constant last rates).
		if not _eval.is_valid() and need > 1:
			var net: float = float(last.get("inflow_rate", 0.0)) - float(last.get("outflow_rate", 0.0))
			# Prefer net from evaluator fallback keys if present.
			if last.has("net_qty_per_hour"):
				net = float(last["net_qty_per_hour"])
			var infl: float = float(last["inflow_rate"])
			var outf: float = float(last["outflow_rate"])
			if need > COARSE_THRESHOLD_STEPS:
				_append_strided_run(lvl, net, infl, outf, need, COARSE_STRIDE_STEPS)
			else:
				_append_exact_run(lvl, net, infl, outf, need)
			_trim_if_needed()
			return
		while g < target_g and _level.size() < MAX_SAMPLES:
			g += 1
			var inp := _inputs_at(time_of_step(g), last)
			var net2: float = float(inp.get("net_qty_per_hour", 0.0))
			var infl2: float = float(inp.get("inflow_rate", last["inflow_rate"]))
			var outf2: float = float(inp.get("outflow_rate", last["outflow_rate"]))
			total_overflow_qty += step_overflow_qty(lvl, net2, capacity_qty, step_hours)
			lvl = step_level(lvl, net2, capacity_qty, step_hours)
			_level.append(lvl)
			_inflow.append(infl2)
			_outflow.append(outf2)
		_trim_if_needed()


	func _fill_backward_to(target_g: int) -> void:
		var first := _sample_index(0)
		var lvl := float(_level[0])
		var g := first_step()
		var pre_level := PackedFloat32Array()
		var pre_in := PackedFloat32Array()
		var pre_out := PackedFloat32Array()
		while g > target_g and (pre_level.size() + _level.size()) < MAX_SAMPLES:
			g -= 1
			var inp := _inputs_at(time_of_step(g), first)
			var net: float = float(inp.get("net_qty_per_hour", 0.0))
			var infl: float = float(inp.get("inflow_rate", first["inflow_rate"]))
			var outf: float = float(inp.get("outflow_rate", first["outflow_rate"]))
			lvl = clampf(unstep_level(lvl, net, capacity_qty, step_hours), 0.0, 1.0)
			pre_level = PackedFloat32Array([lvl]) + pre_level
			pre_in = PackedFloat32Array([infl]) + pre_in
			pre_out = PackedFloat32Array([outf]) + pre_out
		if pre_level.is_empty():
			return
		_base_step = g
		_level = pre_level + _level
		_inflow = pre_in + _inflow
		_outflow = pre_out + _outflow


	func _trim_if_needed() -> void:
		var over := _level.size() - MAX_SAMPLES
		if over <= 0:
			return
		_level = _level.slice(over)
		_inflow = _inflow.slice(over)
		_outflow = _outflow.slice(over)
		_base_step += over
