class_name ResourceTimeline
extends RefCounted

## Reversible resource-level buffer for graph resource containers.
## Mirrors EnergyTimeline: forward-integrate on record_step(), read-back on scrub.

var capacity_qty: float = 100.0
var step_hours: float = 1.0 / 60.0
const MAX_SAMPLES: int = 20160

var _base_step: int = 0
var _level: PackedFloat32Array = PackedFloat32Array()
var _inflow: PackedFloat32Array = PackedFloat32Array()
var _outflow: PackedFloat32Array = PackedFloat32Array()

var _eval: Callable = Callable()


static func step_level(level: float, net_qty_per_hour: float, capacity: float,
		dt_hours: float) -> float:
	if capacity <= 0.0 or dt_hours <= 0.0:
		return clampf(level, 0.0, 1.0)
	var delta := (net_qty_per_hour * dt_hours) / capacity
	return clampf(level + delta, 0.0, 1.0)


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
	while cur_g < target_g:
		cur_g += 1
		lvl = step_level(lvl, net_qty_per_hour, capacity_qty, step_hours)
		_level.append(lvl)
		_inflow.append(inflow)
		_outflow.append(outflow)
	_trim_if_needed()


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
	while g < target_g and _level.size() < MAX_SAMPLES:
		g += 1
		var inp := _inputs_at(time_of_step(g), last)
		var net: float = float(inp.get("net_qty_per_hour", 0.0))
		var infl: float = float(inp.get("inflow_rate", last["inflow_rate"]))
		var outf: float = float(inp.get("outflow_rate", last["outflow_rate"]))
		lvl = step_level(lvl, net, capacity_qty, step_hours)
		_level.append(lvl)
		_inflow.append(infl)
		_outflow.append(outf)
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
