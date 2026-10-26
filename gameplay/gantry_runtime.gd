class_name GantryRuntime
extends Node3D

## The designed gantry running a job in the world. Attached by
## PlacedPropRuntime to a placed `gantry_machine` prop (never the shared
## CncMachineRuntime: that one stretches a toolpath over the GLB's axis
## window and shrinks the ghost to 40 % of the footprint, which is right
## for an imported model with unknown travel and wrong for a machine whose
## travel we designed). It reads the SAME job the graph scheduled —
## SystemGraphView.get_cnc_job_state + MachineJobStore — and moves the
## builder's drivers in TRUE millimetres, laying the extruding points as
## beads on the bed at true scale. Progress is the clock-derived fraction
## the graph computes, so it scrubs and survives a reload; the carriages
## ease toward the sampled point so a 0.2 s poll never reads as stepping.

const _POS_TAU_REAL := 0.10
const _POS_TAU_SIM := 0.02
const _SNAP_SIM_HOURS := 0.4

var graph_item_id := ""
var _builder: GantryLabBuilder = null
var _job_id := ""
var _path := PackedVector3Array()
var _ext := PackedInt32Array()
var _cum := PackedFloat32Array()
var _path_total := 0.0
var _pos_mm := Vector3.ZERO
var _last_abs_hours := INF
var _park := Vector3.ZERO
var _line_mm := 0.4
var _bead_color := Color(0.85, 0.55, 0.2)


func configure(item_id: String) -> void:
	graph_item_id = item_id


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	var p := get_parent()
	if p == null:
		return
	var root := p.get_node_or_null("ModelRoot")
	var search: Node = root if root != null else p
	if search is GantryLabBuilder:
		_builder = search
	else:
		for n in search.find_children("*", "GantryLabBuilder", true, false):
			_builder = n
			break
	if _builder == null:
		return
	var spec := _builder.spec()
	var v: Dictionary = spec["volume"]
	var kin := str(spec["kinematics"])
	_park = Vector3(0.0 if kin == "delta" else 0.0, 0.0, float(v["z_mm"]) * 0.3) if kin == "delta" else Vector3(0.0, 0.0, minf(float(v["z_mm"]), 20.0))
	if kin == "delta":
		_park = Vector3(0.0, 0.0, float(v["z_mm"]) * 0.3)
	var tool := GantryLabParts.tool(str(spec["tool"]["id"]))
	_line_mm = maxf(float(tool["nozzle_mm"]), 0.4)
	_pos_mm = _park
	_builder.set_drivers_mm(_pos_mm)


func _process(delta: float) -> void:
	if _builder == null or not is_instance_valid(_builder):
		return
	var abs_hours := _read_abs_hours()
	var sim_dh := 0.0
	if is_finite(_last_abs_hours):
		sim_dh = abs_hours - _last_abs_hours
	_last_abs_hours = abs_hours
	var state := _job_state()
	var active := bool(state.get("active", false))
	var completed := bool(state.get("completed", false))
	var progress := clampf(float(state.get("progress", 0.0)), 0.0, 1.0)
	var new_job := str(state.get("job_id", ""))
	if new_job != _job_id:
		if new_job.is_empty():
			_clear_job()
		else:
			_load_job(new_job, state)
	var target := _park
	if (active or (completed and progress < 1.0)) and not _path.is_empty():
		target = _sample_path(progress)
	elif completed and not _path.is_empty():
		target = _sample_path(1.0)
		target.z += 10.0
	var snap := absf(sim_dh) > _SNAP_SIM_HOURS
	var x := delta / _POS_TAU_REAL + absf(sim_dh) / _POS_TAU_SIM
	var k := 1.0 if snap else clampf(1.0 - exp(-x), 0.0, 1.0)
	_pos_mm = _pos_mm.lerp(target, k)
	_builder.set_drivers_mm(_pos_mm)
	if not _path.is_empty():
		_builder.set_preview_progress(progress if active or completed else 0.0)


func _job_state() -> Dictionary:
	if graph_item_id.is_empty():
		return {}
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("get_cnc_job_state"):
		return {}
	return sgv.call("get_cnc_job_state", graph_item_id) as Dictionary


func _load_job(job_id: String, state: Dictionary) -> void:
	_job_id = job_id
	_path = PackedVector3Array()
	_ext = PackedInt32Array()
	_cum = PackedFloat32Array()
	_path_total = 0.0
	_builder.clear_toolpath_preview()
	var data := MachineJobStore.load(job_id)
	if data.is_empty():
		return
	_path = data.get("points", PackedVector3Array())
	_ext = data.get("extruding", PackedInt32Array())
	var n := _path.size()
	if n < 2:
		return
	_cum.resize(n)
	_cum[0] = 0.0
	for i in range(1, n):
		_cum[i] = _cum[i - 1] + _path[i].distance_to(_path[i - 1])
	_path_total = _cum[n - 1]
	if bool(state.get("additive", false)):
		var wc: Variant = state.get("wet_color", [0.85, 0.55, 0.2])
		if wc is Array and (wc as Array).size() >= 3:
			_bead_color = Color(float(wc[0]), float(wc[1]), float(wc[2]))
		_builder.set_toolpath_preview(_path, _ext, maxf(float(state.get("line_width_mm", _line_mm)), _line_mm), _bead_color)


func _clear_job() -> void:
	_job_id = ""
	_path = PackedVector3Array()
	_ext = PackedInt32Array()
	_cum = PackedFloat32Array()
	_path_total = 0.0
	if _builder != null:
		_builder.clear_toolpath_preview()


func _sample_path(progress: float) -> Vector3:
	var n := _path.size()
	if n == 0:
		return _park
	if n == 1 or _path_total <= 0.0:
		return _path[n - 1]
	var target_len := _path_total * progress
	var lo := 1
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _cum[mid] < target_len:
			lo = mid + 1
		else:
			hi = mid
	var i := lo
	var a := i - 1
	var span := _cum[i] - _cum[a]
	var t := 0.0 if span <= 0.0 else (target_len - _cum[a]) / span
	return _path[a].lerp(_path[i], clampf(t, 0.0, 1.0))


func _read_abs_hours() -> float:
	var m := get_tree().current_scene if get_tree() != null else null
	if m != null and m.has_method("get_absolute_hours"):
		return float(m.call("get_absolute_hours"))
	return 0.0


## For probes: where the tool is now (work mm) and the job loaded.
func debug_state() -> Dictionary:
	return {"job_id": _job_id, "points": _path.size(), "pos_mm": _pos_mm, "total_mm": _path_total}
