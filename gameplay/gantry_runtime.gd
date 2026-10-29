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
##
## When an additive job completes the print is baked into a placed object
## (TerrainLoader.register_printed_object), as CncMachineRuntime does: a
## machine whose bed is the Z axis (a cube) first drops it to the bottom,
## and a bed print is marked `on_bed` so the next job clears it from the
## world (the graph credited it to the inventory). A clay print stays.

const _POS_TAU_REAL := 0.10
const _POS_TAU_SIM := 0.02
const _SNAP_SIM_HOURS := 0.4
const FINISH_DROP_MM_S := CncMachineRuntime.FINISH_DROP_MM_S
const FINISH_AT_MM := CncMachineRuntime.FINISH_AT_MM

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
## The gantry frame maps work Y to local +Z (a reflection: every print came
## out a mirror image of its model). Work y is mirrored about the middle of
## the volume on the way to the machine — `_y_mid` (0 on a delta, whose work
## frame is centred) — for the drivers and the roads alike.
var _y_mid := 0.0
var _z_mm := 300.0
## True when the bed is the Z axis (it drops as the print grows).
var _bed_lowering := false
var _additive := true
var _handed_off := ""
var _snap_next := false
var _job_color := Color.WHITE


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
	_y_mid = 0.0 if kin == "delta" else float(v["y_mm"]) * 0.5
	_park = Vector3(0.0, 0.0, float(v["z_mm"]) * 0.3) if kin == "delta" else Vector3(0.0, 0.0, minf(float(v["z_mm"]), 20.0))
	_z_mm = float(v["z_mm"])
	var lay := _builder.layout()
	var bead_asm := str(lay.get("bead_parent", ""))
	var asms: Dictionary = lay.get("assemblies", {})
	_bed_lowering = kin != "delta" and not bead_asm.is_empty() and asms.has(bead_asm) \
		and str((asms[bead_asm] as Dictionary).get("axis", "")) == "z"
	var tool := GantryLabParts.tool(str(spec["tool"]["id"]))
	_additive = str(tool["process"]) == "additive"
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
	_drive(_pos_mm)


## Work mm → the machine (work y mirrored about the middle).
func _drive(mm: Vector3) -> void:
	_builder.set_drivers_mm(Vector3(mm.x, 2.0 * _y_mid - mm.y, mm.z))


## The roads node mirrored the same way (about the plane at the middle).
func _mirror_roads() -> void:
	var r := _builder.roads()
	if r == null:
		return
	var o: Vector3 = _builder.layout()["bead_origin"]
	r.transform = Transform3D(PrintRoads.work_basis(), Vector3(0.0, 0.0, 2.0 * (o.z + _y_mid * 0.001)))


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
	var finishing := false
	if _player != null and _player.is_loaded() and (active or completed):
		smp = _player.sample(progress if active else 1.0)
		target = smp["pos"]
		if completed and not active:
			finishing = true
			if _bed_lowering:
				# Done: the bed drops to the bottom of its travel.
				target.z = maxf(_z_mm, float(target.z))
			else:
				target.z += 10.0
	var snap := absf(sim_dh) > _SNAP_SIM_HOURS or _snap_next
	_snap_next = false
	var x := delta / _POS_TAU_REAL + absf(sim_dh) / _POS_TAU_SIM
	var k := 1.0 if snap else clampf(1.0 - exp(-x), 0.0, 1.0)
	var next := _pos_mm.lerp(target, k)
	if finishing and _bed_lowering and not snap:
		var step := FINISH_DROP_MM_S * maxf(delta, absf(sim_dh) * 3600.0)
		next.z = move_toward(float(_pos_mm.z), float(target.z), step)
	_pos_mm = next
	_drive(_pos_mm)
	if not smp.is_empty() and _builder.roads() != null:
		if active:
			_builder.set_print_progress(int(smp["i"]), float(smp["s"]))
		else:
			_builder.set_preview_progress(1.0)
	if finishing and progress >= 0.99 and _handed_off != _job_id and not _job_id.is_empty():
		if not _bed_lowering or absf(float(_pos_mm.z) - float(target.z)) <= FINISH_AT_MM:
			_finish_job(state)


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
	_job_color = col
	var loader := _terrain_loader()
	if loader != null and loader.has_method("has_printed_object") \
			and bool(loader.call("has_printed_object", job_id)):
		# Finished and handed off before (a reload): the print is a world
		# object already, so nothing is laid and the bed is at its bottom.
		_handed_off = job_id
		_snap_next = true
		return
	var line := maxf(float(_player.line_mm), 0.05)
	_builder.set_print_preview(_player.moves(), line, _player.layer_mm, col, _mottle)
	_mirror_roads()


func _clear_job() -> void:
	_job_id = ""
	_player = null
	if _builder != null:
		_builder.clear_toolpath_preview()


## The job is done: bake the print into a placed object the player can move
## (once per job). A clay print stays; a bed print is `on_bed`.
func _finish_job(state: Dictionary) -> void:
	_handed_off = _job_id
	var r := _builder.roads()
	if r == null or not _additive:
		return
	var loader := _terrain_loader()
	if loader == null or not loader.has_method("register_printed_object"):
		return
	var persist := bool(state.get("print_persist", false))
	var obj := r.bake_object(Color(_job_color, 1.0))
	if obj.is_empty():
		return
	var mesh := obj["mesh"] as ArrayMesh
	var stl := _write_print_stl(mesh, _job_id)
	loader.call("register_printed_object", {
		"job_id": _job_id, "mesh_path": stl, "xform": obj["xform"], "mesh": mesh,
		"dry_color": [_job_color.r, _job_color.g, _job_color.b], "source": "gantry_machine",
		"on_bed": not persist, "machine_item": graph_item_id,
		"label": str(state.get("job_name", "")),
	})
	_builder.clear_toolpath_preview()


func _write_print_stl(mesh: ArrayMesh, job_id: String) -> String:
	var dir := "user://machines/prints"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := "%s/%s.stl" % [dir, job_id]
	return path if MudWallMesher._write_mesh_as_stl_mm(mesh, path) else ""


func _terrain_loader() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var m := tree.get_first_node_in_group("main_scene")
	if m == null:
		m = tree.current_scene
	return m.find_child("TerrainLoader", true, false) if m != null else null


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
	var line := maxf(float(job.get("line_width_mm", _line_mm)), 0.05)
	var layer := float(job.get("layer_height_mm", -1.0))
	if layer <= 0.0:
		layer = PrintRoads.layer_guess_mm(job["moves"], line)
	_builder.set_print_preview(job["moves"], line, layer, Color(_bead_color, 0.5), _mottle)
	_mirror_roads()
	_builder.set_preview_progress(1.0)
	var r := _builder.roads()
	if r != null and r.material_override is StandardMaterial3D:
		(r.material_override as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_previewing = true


func preview_tool_mm(mm: Vector3) -> void:
	if _builder == null or not _job_id.is_empty():
		return
	_pos_mm = mm
	_drive(mm)


func clear_print_preview() -> void:
	if _previewing and _builder != null and _job_id.is_empty():
		_builder.clear_toolpath_preview()
	_previewing = false


func has_print_preview() -> bool:
	return _previewing


## For probes: where the tool is now (work mm) and the job loaded.
func debug_state() -> Dictionary:
	var n := (PrintMoves.count(_player.moves()) + 1) if _player != null else 0
	return {"job_id": _job_id, "points": n, "pos_mm": _pos_mm, "total_mm": 0.0,
		"total_s": _player.total_s if _player != null else 0.0, "roads": _builder.road_count() if _builder != null else 0}
