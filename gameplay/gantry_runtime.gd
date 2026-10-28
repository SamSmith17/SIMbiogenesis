class_name GantryRuntime
extends Node3D

## The designed gantry running a job in the world. Attached by
## PlacedPropRuntime to a placed `gantry_machine` prop (never the GLB
## machines' CncMachineRuntime, which maps a profile's tagged sub-nodes;
## this one moves the builder's drivers directly). It plays the SAME job
## the graph scheduled through PrintJobPlayer — the planner's own time
## line, so the head accelerates and brakes as the Simulate tab showed —
## at the graph's clock-derived progress, laying the roads on the bed under
## the nozzle move by move. Scrubs and survives a reload.

const _POS_TAU_REAL := 0.10
const _POS_TAU_SIM := 0.02
const _SNAP_SIM_HOURS := 0.4

var graph_item_id := ""
var _builder: GantryLabBuilder = null
var _player: PrintJobPlayer = null
var _job_id := ""
var _pos_mm := Vector3.ZERO
var _last_abs_hours := INF
var _park := Vector3.ZERO
var _line_mm := 0.4
var _bead_color := Color(0.85, 0.55, 0.2)
var _mottle := 0.0
var _material := "filament"


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
	_park = Vector3(0.0, 0.0, float(v["z_mm"]) * 0.3) if kin == "delta" else Vector3(0.0, 0.0, minf(float(v["z_mm"]), 20.0))
	var tool := GantryLabParts.tool(str(spec["tool"]["id"]))
	_line_mm = maxf(float(tool["nozzle_mm"]), 0.1)
	_material = str(tool["material"])
	match _material:
		"plastic_flake":
			_bead_color = Color(0.16, 0.34, 0.55)
			_mottle = 0.45
		"mud":
			_bead_color = Color(0.55, 0.38, 0.26)
	if str(tool["process"]) != "additive":
		_bead_color = Color(0.35, 0.3, 0.25)
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
	var smp: Dictionary = {}
	if _player != null and _player.is_loaded() and (active or completed):
		smp = _player.sample(progress if active else 1.0)
		target = smp["pos"]
		if completed and not active:
			target.z += 10.0
	var snap := absf(sim_dh) > _SNAP_SIM_HOURS
	var x := delta / _POS_TAU_REAL + absf(sim_dh) / _POS_TAU_SIM
	var k := 1.0 if snap else clampf(1.0 - exp(-x), 0.0, 1.0)
	_pos_mm = _pos_mm.lerp(target, k)
	_builder.set_drivers_mm(_pos_mm)
	if not smp.is_empty():
		if active:
			_builder.set_print_progress(int(smp["i"]), float(smp["s"]))
		else:
			_builder.set_preview_progress(1.0)


func _job_state() -> Dictionary:
	if graph_item_id.is_empty():
		return {}
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("get_cnc_job_state"):
		return {}
	return sgv.call("get_cnc_job_state", graph_item_id) as Dictionary


func _load_job(job_id: String, state: Dictionary) -> void:
	_clear_job()
	_job_id = job_id
	_player = PrintJobPlayer.new()
	if not _player.load(job_id, state):
		_player = null
		return
	var wc: Variant = state.get("wet_color", null)
	var col := _bead_color
	if _material == "filament" and wc is Array and (wc as Array).size() >= 3:
		col = Color(float(wc[0]), float(wc[1]), float(wc[2]))
	var line := maxf(float(state.get("line_width_mm", _line_mm)), _line_mm) * 1.12
	_builder.set_print_preview(_player.moves(), line, _player.layer_mm, col, _mottle)


func _clear_job() -> void:
	_job_id = ""
	_player = null
	if _builder != null:
		_builder.clear_toolpath_preview()


func _read_abs_hours() -> float:
	var m := get_tree().current_scene if get_tree() != null else null
	if m != null and m.has_method("get_absolute_hours"):
		return float(m.call("get_absolute_hours"))
	return 0.0


# ---------------------------------------------------------------------------
# Preview (the print setup's ghost on the bed, while no job runs)
# ---------------------------------------------------------------------------

var _previewing := false


func begin_print_preview(job: Dictionary, _wet: Color = Color.WHITE) -> void:
	if _builder == null or job.is_empty() or not bool(job.get("ok", false)):
		return
	if not _job_id.is_empty():
		return
	var line := maxf(float(job.get("line_width_mm", _line_mm)), 0.05) * 1.12
	var layer := float(job.get("layer_height_mm", -1.0))
	if layer <= 0.0:
		layer = PrintRoads.layer_guess_mm(job["moves"], line)
	_builder.set_print_preview(job["moves"], line, layer, Color(_bead_color, 0.5), _mottle)
	_builder.set_preview_progress(1.0)
	var r := _builder.roads()
	if r != null and r.material_override is StandardMaterial3D:
		(r.material_override as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_previewing = true


func preview_tool_mm(mm: Vector3) -> void:
	if _builder == null or not _job_id.is_empty():
		return
	_pos_mm = mm
	_builder.set_drivers_mm(mm)


func clear_print_preview() -> void:
	if _previewing and _builder != null and _job_id.is_empty():
		_builder.clear_toolpath_preview()
	_previewing = false


func has_print_preview() -> bool:
	return _previewing


## For probes: where the tool is now (work mm) and the job loaded.
func debug_state() -> Dictionary:
	var n := (_player.moves().size() + 1) if _player != null else 0
	return {"job_id": _job_id, "points": n, "pos_mm": _pos_mm, "total_mm": 0.0,
		"total_s": _player.total_s if _player != null else 0.0, "roads": _builder.road_count() if _builder != null else 0}
