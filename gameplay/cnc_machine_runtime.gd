class_name CncMachineRuntime
extends Node3D

## A placed GLB machine (the Trash Printer, the Mud Printer, the CNC router,
## anything the player imports and tags in Machine Setup) running its job
## in the world. Attached by PlacedPropRuntime to a PlacedProp whose record
## kind is "cartesian_machine". It reads the CartesianMachineProfile (which
## sub-node is each axis, its direction, soft limits, home) and the bound
## graph node's job, and moves the tagged axes in TRUE MILLIMETRES: the
## tool at work (x, y, z) is the nozzle over the bed at that point, through
## the metres-per-local-unit of each axis node. The print grows on the bed
## as PrintRoads, move by move, under the nozzle.
##
## The motion is the planned one: `PrintJobPlayer` plans the job with the
## same planner the gantry designer's Simulate tab runs, and the graph's
## clock-derived progress (SystemGraphView._tick_graph_tools) maps to a
## time on that plan — so the head decelerates into corners, rapids between
## islands, and the whole thing scrubs with the timeline.
##
## The work frame: X and Y across the bed with (0, 0) at the bed's
## front-left corner (work_x / 2, work_y / 2 is where the tool sits with
## every axis at its calibrated centre), Z up from the bed top. A fixed bed
## (mud) lifts the head in Z; a lowering bed (trash) drops the bed and the
## print rides it (the roads are a child of the bed node).
##
## A mud print (print_persist) is handed to the terrain loader as a placed
## object when the job completes, baked from its roads; a trash print stays
## on the bed until the next job (the graph credits the part).

const _POS_TAU_REAL := 0.10
const _POS_TAU_SIM := 0.02
const _SNAP_SIM_HOURS := 0.4
const _LABEL_FADE_M := 60.0
const PREVIEW_ALPHA := 0.35

var model_id: String = ""
var graph_item_id: String = ""
var _profile: CartesianMachineProfile = null

var _model_root: Node3D = null
var _axis_nodes: Dictionary = {}       # key -> Node3D
var _axis_rest: Dictionary = {}        # key -> Vector3 (rest local position)
var _rest_by_node: Dictionary = {}     # node_name -> Vector3 (original rest, survives re-tag)
var _axis_dir: Dictionary = {}         # key -> Vector3 (signed unit dir, parent frame)
var _soft_min: Dictionary = {}
var _soft_max: Dictionary = {}
var _axis_home: Dictionary = {}
var _mpl: Dictionary = {}              # key -> metres per local unit
var _centre_u: Dictionary = {}         # key -> local units: tool over the bed centre (x, y), at the bed (z)
var _work := Vector3(600.0, 600.0, 600.0)
var _bed_lowering := false
var _frame_valid := false
var _frame_root_pos := Vector3.ZERO
var _frame_work := Vector3.ZERO
var _work_xf := Transform3D.IDENTITY  # the roads' transform under their parent

var _player: PrintJobPlayer = null
var _job_id := ""
var _roads: PrintRoads = null
var _ghost: PrintRoads = null
var _ghost_job: Dictionary = {}
var _preview_mm := Vector3(NAN, NAN, NAN)
var _label: Label3D = null
var _pos_mm := Vector3(NAN, NAN, NAN)
var _park_mm := Vector3.ZERO
var _last_abs_hours := INF
var _persisted_job := ""
var _last_state: Dictionary = {}
var _ready_ok := false
var _label_acc := 0.0


func configure(mid: String, profile_dict: Dictionary, item_id: String) -> void:
	model_id = mid
	graph_item_id = item_id
	_profile = CartesianMachineProfile.new()
	if profile_dict.is_empty():
		_profile = CartesianMachineProfile.get_profile(mid)
	else:
		_profile.model_id = mid
		_profile._apply_raw(profile_dict)


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	_model_root = _find_model_root()
	if _model_root == null:
		return
	if _profile == null:
		_profile = CartesianMachineProfile.get_profile(model_id)
	_resolve_axes()


## Re-resolve the tagged axis nodes / directions / soft limits from the
## profile. Rest positions are cached per node NAME so they survive a re-tag.
func _resolve_axes() -> void:
	_axis_nodes.clear()
	_axis_dir.clear()
	_soft_min.clear()
	_soft_max.clear()
	_axis_home.clear()
	for key: String in CartesianMachineProfile.AXIS_KEYS:
		var node_name := _profile.axis_node(key)
		if node_name.is_empty():
			continue
		var node := _model_root.find_child(node_name, true, false) as Node3D
		if node == null:
			continue
		if not _rest_by_node.has(node_name):
			_rest_by_node[node_name] = node.position
		_axis_nodes[key] = node
		_axis_rest[key] = _rest_by_node[node_name]
		_axis_dir[key] = _profile.axis_dir(key)
		var lo := _profile.axis_min_local(key)
		var hi := _profile.axis_max_local(key)
		var home := _profile.axis_home_local(key)
		var fallback := _default_travel_for(node)
		if hi <= lo:
			# Uncalibrated: the work volume decides the window (_calibrate_frame).
			lo = NAN
			hi = NAN
			home = 0.0
		elif fallback > 0.05 and (hi - lo) > fallback * 4.0:
			# Soft-heal inflated legacy travels (the old print-span calibration).
			var mid := lerpf(lo, hi, 0.5)
			lo = mid - fallback * 0.5
			hi = mid + fallback * 0.5
			home = clampf(home, lo, hi)
		_soft_min[key] = lo
		_soft_max[key] = hi
		_axis_home[key] = home
	_ready_ok = not _axis_nodes.is_empty()
	_frame_valid = false


## Live-apply an edited profile (Machine Setup's Save): snap the tagged
## nodes back to rest, reload the profile, re-resolve, re-measure the frame.
func reload_profile() -> void:
	if _model_root == null:
		_model_root = _find_model_root()
	if _model_root == null:
		return
	for node_name: String in _rest_by_node.keys():
		var node := _model_root.find_child(node_name, true, false) as Node3D
		if is_instance_valid(node):
			node.position = _rest_by_node[node_name]
	_profile = CartesianMachineProfile.get_profile(model_id)
	_resolve_axes()
	_reseat_roads()


# ---------------------------------------------------------------------------
# The work frame: where work (x, y, z) is on this machine
# ---------------------------------------------------------------------------

func _calibrate_frame() -> void:
	if _model_root == null or not _ready_ok:
		return
	for key: String in _axis_nodes.keys():
		var n := _axis_nodes[key] as Node3D
		if is_instance_valid(n) and _axis_rest.has(key):
			n.position = _axis_rest[key] as Vector3
	_bed_lowering = _is_bed_lowering()
	var tip := _tool_tip_world()
	var bed := _bed_plate_world_origin() if _bed_lowering else _bed_world_origin()
	var delta := bed - tip
	_mpl.clear()
	_centre_u.clear()
	for key: String in _axis_nodes.keys():
		var node := _axis_nodes[key] as Node3D
		var dir: Vector3 = _axis_dir[key]
		if not is_instance_valid(node) or dir.length_squared() < 1e-8:
			_mpl[key] = 1.0
			_centre_u[key] = 0.0
			continue
		# `node.position` lives in the PARENT's frame: the metres per local unit
		# and the world direction come from the parent's basis (the node's own
		# basis carries the GLB sub-node's scale, which is not the axis's).
		var dir_w := _axis_parent_basis(node) * dir.normalized()
		var mpl := maxf(dir_w.length(), 1e-6)
		_mpl[key] = mpl
		if key == "z" and _bed_lowering:
			# The bed starts AT the nozzle (work z = 0) and drops from there;
			# the GLB's rest pose may park it a metre below the tip.
			_centre_u[key] = (tip - bed).dot(dir_w.normalized()) / mpl
		else:
			_centre_u[key] = delta.dot(dir_w.normalized()) / mpl
	# An uncalibrated axis takes its window from the work volume.
	for key: String in _axis_nodes.keys():
		if is_nan(float(_soft_min.get(key, NAN))):
			var mpl := float(_mpl[key])
			var span := _work_axis(key) * 0.001 / mpl
			var c := float(_centre_u[key])
			if key == "z":
				_soft_min[key] = c
				_soft_max[key] = c + span
				_axis_home[key] = c
			else:
				_soft_min[key] = c - span * 0.5
				_soft_max[key] = c + span * 0.5
				_axis_home[key] = c
	# The roads' frame: X = the x axis's world direction, Y up, Z = the y
	# axis's, origin at the bed's front-left corner; under the bed node when
	# the bed moves (the print rides it), else under this node.
	var ex := _axis_world_dir("x")
	var ez := _axis_world_dir("y")
	var up := Vector3.UP
	if _axis_nodes.has("z"):
		var zd := _axis_world_dir("z")
		up = -zd if _bed_lowering else zd
		if up.y < 0.0:
			up = -up
	var origin := bed - ex * (_work.x * 0.0005) - ez * (_work.y * 0.0005)
	var world := Transform3D(Basis(ex, up, ez), origin)
	var parent := _roads_parent()
	_work_xf = parent.global_transform.affine_inverse() * world
	if _bed_lowering and _axis_nodes.has("z"):
		# Measured with the bed at rest; the roads ride the bed node, so the
		# frame is right wherever the bed goes.
		pass
	_frame_valid = true
	_frame_root_pos = _model_root.global_position
	_frame_work = _work
	_park_mm = Vector3(_work.x * 0.5, _work.y * 0.5, 0.0) if not _bed_lowering else Vector3(_work.x * 0.5, _work.y * 0.5, 0.0)
	if is_nan(_pos_mm.x):
		_pos_mm = _park_mm


func _work_axis(key: String) -> float:
	match key:
		"x": return _work.x
		"y": return _work.y
	return _work.z


func _axis_world_dir(key: String) -> Vector3:
	if not _axis_nodes.has(key):
		match key:
			"x": return _model_root.global_transform.basis.x.normalized()
			"y": return _model_root.global_transform.basis.z.normalized()
		return Vector3.UP
	var node := _axis_nodes[key] as Node3D
	var d := _axis_parent_basis(node) * (_axis_dir[key] as Vector3).normalized()
	return d.normalized() if d.length_squared() > 1e-12 else Vector3.RIGHT


static func _axis_parent_basis(node: Node3D) -> Basis:
	var p := node.get_parent()
	if p is Node3D:
		return (p as Node3D).global_transform.basis
	return node.global_transform.basis


func _roads_parent() -> Node3D:
	if _bed_lowering and _axis_nodes.has("z") and is_instance_valid(_axis_nodes["z"]):
		return _axis_nodes["z"] as Node3D
	return self


## Put the tool at work mm (clamped to the soft limits).
func _pose_tool(mm: Vector3) -> void:
	for key: String in _axis_nodes.keys():
		var node := _axis_nodes[key] as Node3D
		if not is_instance_valid(node):
			continue
		var mpl := float(_mpl.get(key, 1.0))
		var c := float(_centre_u.get(key, 0.0))
		var along := c
		match key:
			"x": along = c + (mm.x - _work.x * 0.5) * 0.001 / mpl
			"y": along = c + (mm.y - _work.y * 0.5) * 0.001 / mpl
			"z": along = c + mm.z * 0.001 / mpl
		# The work volume is the truth (the slicer centred the print on it);
		# Machine Setup's soft window is often an old print-span calibration
		# narrower than the bed, so it does not clamp the print pose.
		node.position = (_axis_rest[key] as Vector3) + (_axis_dir[key] as Vector3) * along


## Where the tool is now (work mm), for probes.
func tool_mm() -> Vector3:
	return _pos_mm


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _ready_ok:
		return
	var abs_hours := _read_abs_hours()
	var sim_dh := 0.0
	if is_finite(_last_abs_hours):
		sim_dh = abs_hours - _last_abs_hours
	_last_abs_hours = abs_hours

	var state := _job_state()
	_last_state = state
	_work = Vector3(maxf(float(state.get("work_x_mm", _work.x)), 10.0), maxf(float(state.get("work_y_mm", _work.y)), 10.0), maxf(float(state.get("work_z_mm", _work.z)), 10.0))
	if state.has("bed_lowering") and bool(state.get("bed_lowering")) != _bed_lowering:
		_frame_valid = false
	if _frame_valid and _model_root.global_position.distance_squared_to(_frame_root_pos) > 1e-4:
		_frame_valid = false
	# The graph node's work volume can land after the first frames (the bind
	# is deferred): a frame measured on the default 600 mm bed put a 3 m mud
	# print's roads 1.2 m off its nozzle.
	if _frame_valid and _frame_work.distance_squared_to(_work) > 1e-6:
		_frame_valid = false
	if not _frame_valid:
		_calibrate_frame()
		_reseat_roads()

	var active := bool(state.get("active", false))
	var completed := bool(state.get("completed", false))
	var progress := clampf(float(state.get("progress", 0.0)), 0.0, 1.0)
	var new_job := str(state.get("job_id", ""))
	if new_job != _job_id:
		if new_job.is_empty():
			_clear_job()
		else:
			_load_job(new_job, state)

	var target := _park_mm
	var smp: Dictionary = {}
	if _player != null and _player.is_loaded() and (active or completed):
		smp = _player.sample(progress if active else 1.0)
		target = smp["pos"]
		if completed and not active:
			target.z = minf(float(target.z) + maxf(_work.z * 0.05, 5.0), _work.z)
	if _ghost != null and not active and not is_nan(_preview_mm.x):
		# The print setup's studio is scrubbing: the real tool follows it.
		target = _preview_mm
	var snap := absf(sim_dh) > _SNAP_SIM_HOURS
	var x := delta / _POS_TAU_REAL + absf(sim_dh) / _POS_TAU_SIM
	var k := 1.0 if snap else clampf(1.0 - exp(-x), 0.0, 1.0)
	_pos_mm = _pos_mm.lerp(target, k)
	_pose_tool(_pos_mm)

	if _roads != null and not smp.is_empty():
		if active:
			_roads.set_progress_move(int(smp["i"]), float(smp["s"]))
		else:
			_roads.show_all()
	if completed and progress >= 0.99 and _persisted_job != _job_id and not _job_id.is_empty():
		_finish_job(state)
	_label_acc += delta
	if _label_acc >= 0.25:
		_label_acc = 0.0
		_update_label(state, smp, active, completed, progress)


# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

func _job_state() -> Dictionary:
	var sgv := _system_graph_view()
	if sgv != null and sgv.has_method("get_cnc_job_state"):
		return sgv.call("get_cnc_job_state", graph_item_id) as Dictionary
	return {}


func _load_job(job_id: String, state: Dictionary) -> void:
	_clear_job()
	_job_id = job_id
	_player = PrintJobPlayer.new()
	if not _player.load(job_id, state):
		_player = null
		return
	_free_ghost()
	_lay_roads(state)


func _lay_roads(state: Dictionary) -> void:
	if _player == null or not _player.is_loaded():
		return
	if not _frame_valid:
		_calibrate_frame()
	_free_roads()
	var wet := _color_from(state.get("wet_color"), Color(0.85, 0.55, 0.2))
	var dry := _color_from(state.get("dry_color"), wet)
	var mud := str(state.get("machine_kind", "")) == "mud" or bool(state.get("print_persist", false))
	var additive := _player.additive
	_roads = PrintRoads.new()
	var col := dry if mud else wet
	var mottle := 0.0
	if str(state.get("machine_kind", "")) == "trash":
		mottle = 0.45
	if not additive:
		col = Color(0.35, 0.3, 0.25)
	_roads.lay(_player.moves(), _player.line_mm, _player.layer_mm if additive else minf(_player.layer_mm, 1.0), col, mottle, Vector3.ZERO)
	_roads_parent().add_child(_roads)
	_roads.transform = _work_xf
	if mud:
		# Fresh mud is dark and dries behind the nozzle over a few metres.
		_roads.set_wet(Color(wet.r / maxf(dry.r, 0.01), wet.g / maxf(dry.g, 0.01), wet.b / maxf(dry.b, 0.01)), _player.line_mm * 60.0)


func _reseat_roads() -> void:
	for r in [_roads, _ghost]:
		if r != null and is_instance_valid(r):
			var parent := _roads_parent()
			if r.get_parent() != parent:
				r.get_parent().remove_child(r)
				parent.add_child(r)
			r.transform = _work_xf


func _clear_job() -> void:
	_job_id = ""
	_player = null
	_free_roads()


func _free_roads() -> void:
	if _roads != null and is_instance_valid(_roads):
		_roads.get_parent().remove_child(_roads)
		_roads.queue_free()
	_roads = null


## The job is done: a mud print becomes a placed object on the map (once);
## anything else stays on the bed until the next job.
func _finish_job(state: Dictionary) -> void:
	_persisted_job = _job_id
	if not bool(state.get("print_persist", false)) or _roads == null:
		return
	var loader := _terrain_loader()
	if loader == null or not loader.has_method("register_printed_object"):
		return
	_roads.show_all()
	var dry := _color_from(state.get("dry_color"), Color(0.68, 0.56, 0.42))
	var box := _roads.bounds_local()
	var centre := Vector3(box.position.x + box.size.x * 0.5, box.position.y, box.position.z + box.size.z * 0.5)
	var mesh := _roads.bake_mesh(dry, centre)
	if mesh == null:
		return
	var xf := _roads.global_transform * Transform3D(Basis.IDENTITY, centre)
	xf.basis = xf.basis.orthonormalized()
	var stl := _write_print_stl(mesh, _job_id)
	loader.call("register_printed_object", {
		"job_id": _job_id, "mesh_path": stl, "xform": xf, "mesh": mesh,
		"dry_color": [dry.r, dry.g, dry.b], "source": model_id,
	})
	_free_roads()


func _write_print_stl(mesh: ArrayMesh, job_id: String) -> String:
	var dir := "user://machines/prints"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := "%s/%s.stl" % [dir, job_id]
	return path if MudWallMesher._write_mesh_as_stl_mm(mesh, path) else ""


# ---------------------------------------------------------------------------
# Preview (the print setup's in-world ghost on the bed)
# ---------------------------------------------------------------------------

## Show a job (not yet started) as translucent roads on the bed.
func begin_print_preview(job: Dictionary, wet: Color = Color(0.45, 0.9, 1.0)) -> void:
	_free_ghost()
	if job.is_empty() or not bool(job.get("ok", false)):
		return
	if _model_root == null or not _ready_ok:
		return
	if not _frame_valid:
		_calibrate_frame()
	_ghost_job = job
	_ghost = PrintRoads.new()
	_ghost.name = "PrintPreviewGhost"
	var line := maxf(float(job.get("line_width_mm", 0.4)), 0.05)
	var layer := float(job.get("layer_height_mm", -1.0))
	if layer <= 0.0:
		layer = PrintRoads.layer_guess_mm(job["moves"], line)
	_ghost.lay(job["moves"], line, layer, Color(wet.r, wet.g, wet.b, PREVIEW_ALPHA), 0.0, Vector3.ZERO)
	var mat := _ghost.material_override as StandardMaterial3D
	if mat != null:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = wet * 0.5
		mat.emission_energy_multiplier = 0.4
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_roads_parent().add_child(_ghost)
	_ghost.transform = _work_xf
	_ghost.show_all()


## Pose the tool for the preview (the studio's scrub, mirrored in the world).
func preview_tool_mm(mm: Vector3) -> void:
	if not _frame_valid:
		_calibrate_frame()
	_preview_mm = mm
	_pos_mm = mm
	_pose_tool(mm)


func clear_print_preview() -> void:
	_free_ghost()


func has_print_preview() -> bool:
	return _ghost != null


func _free_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.get_parent().remove_child(_ghost)
		_ghost.queue_free()
	_ghost = null
	_ghost_job = {}
	_preview_mm = Vector3(NAN, NAN, NAN)


## The work volume (mm) this machine runs, from its graph node.
func work_mm() -> Vector3:
	return _work


func roads() -> PrintRoads:
	return _roads


## For probes: the job, the tool position (work mm), roads laid.
func debug_state() -> Dictionary:
	return {
		"job_id": _job_id, "loaded": _player != null and _player.is_loaded(),
		"pos_mm": _pos_mm, "roads": _roads.road_count() if _roads != null else 0,
		"roads_shown": _roads.roads_shown() if _roads != null else 0,
		"bed_lowering": _bed_lowering, "work": _work, "frame_valid": _frame_valid,
		"total_s": _player.total_s if _player != null else 0.0,
		"mpl": _mpl.duplicate(), "centre_u": _centre_u.duplicate(), "soft_min": _soft_min.duplicate(), "soft_max": _soft_max.duplicate(),
		"tip": _tool_tip_world(), "work_xf": _work_xf, "axes": _debug_axes(),
	}


func _debug_axes() -> Dictionary:
	var out := {}
	var tool: Node = null
	if _profile != null and _model_root != null and not _profile.tool_node.is_empty():
		tool = _model_root.find_child(_profile.tool_node, true, false)
	for key: String in _axis_nodes.keys():
		var n := _axis_nodes[key] as Node3D
		if not is_instance_valid(n):
			continue
		var under := false
		var t := tool
		while t != null:
			if t == n:
				under = true
			t = t.get_parent()
		out[key] = {"node": n.name, "parent": n.get_parent().name, "pos": n.position, "rest": _axis_rest.get(key), "world_dir": _axis_world_dir(key), "gpos": n.global_position, "tool_under": under}
	out["tool"] = {"name": _profile.tool_node if _profile != null else "", "gpos": tool.global_position if tool is Node3D else Vector3.INF}
	return out


# ---------------------------------------------------------------------------
# The status over the machine
# ---------------------------------------------------------------------------

func _update_label(state: Dictionary, smp: Dictionary, active: bool, completed: bool, progress: float) -> void:
	var text := ""
	if active and _player != null and not smp.is_empty():
		var layer := int(smp.get("layer", 0))
		var layers := int(smp.get("layers", 0))
		var v := float(smp.get("v", 0.0))
		var what := "travel" if bool(smp.get("rapid", false)) else ("printing" if bool(smp.get("extruding", false)) else "feed")
		text = "%s · %d %%\n%s%s · %.0f mm/s %s\n%s left" % [
			str(state.get("name", "Printing")), int(progress * 100.0),
			("layer %d of %d · " % [layer, layers]) if layers > 0 else "",
			GantryLabMotion.fmt_duration(float(smp.get("t", 0.0))), v, what,
			GantryLabMotion.fmt_duration(float(smp.get("remaining_s", 0.0)) / maxf(float(state.get("speed_factor", 1.0)), 0.05))]
	elif completed and not _job_id.is_empty():
		text = "%s · done" % str(state.get("job_name", "Print"))
	if _label == null:
		if text.is_empty():
			return
		_label = Label3D.new()
		_label.name = "PrintStatus"
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.fixed_size = false
		_label.pixel_size = 0.004
		_label.font_size = 44
		_label.outline_size = 10
		_label.modulate = Color(0.95, 0.97, 1.0)
		_label.outline_modulate = Color(0.02, 0.04, 0.08, 0.9)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(_label)
		var top := _model_top_local()
		_label.position = top + Vector3(0.0, 0.4, 0.0)
	_label.text = text
	_label.visible = not text.is_empty()
	if _label.visible:
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null:
			var d := cam.global_position.distance_to(_label.global_position)
			_label.modulate.a = clampf(1.0 - (d - _LABEL_FADE_M * 0.6) / (_LABEL_FADE_M * 0.4), 0.0, 1.0)
			_label.visible = _label.modulate.a > 0.01


func _model_top_local() -> Vector3:
	var box := AABB()
	var found := false
	if _model_root != null:
		for n in _model_root.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi == null or mi.mesh == null:
				continue
			var b := mi.global_transform * mi.mesh.get_aabb()
			if not found:
				box = b
				found = true
			else:
				box = box.merge(b)
	if not found:
		return Vector3(0.0, 1.5, 0.0)
	var c := box.get_center()
	return to_local(Vector3(c.x, box.end.y, c.z))


# ---------------------------------------------------------------------------
# Measuring the model
# ---------------------------------------------------------------------------

## The nozzle's mouth: the profile's tool node when it rides a moving axis
## (its meshes' lowest point), else the lowest point of the deepest X / Y
## carriage — a saved profile may name a static part as the tool, and a tip
## that never moves can never sit on the road.
func _tool_tip_world() -> Vector3:
	if _profile != null and not _profile.tool_node.is_empty() and _model_root != null:
		var tool := _model_root.find_child(_profile.tool_node, true, false) as Node3D
		if tool != null and (_axis_nodes.is_empty() or _rides_an_axis(tool)):
			var box := _subtree_aabb(tool)
			if box.size.length_squared() > 0.0:
				var c := box.get_center()
				return Vector3(c.x, box.position.y, c.z)
			return tool.global_position
	var carriage: Node3D = null
	for key in ["x", "y"]:
		if _axis_nodes.has(key) and is_instance_valid(_axis_nodes[key]):
			var n := _axis_nodes[key] as Node3D
			if carriage == null or n.is_ancestor_of(carriage) == false and carriage.is_ancestor_of(n):
				carriage = n
	if carriage != null:
		var box := _subtree_aabb(carriage)
		if box.size.length_squared() > 0.0:
			var c := box.get_center()
			return Vector3(c.x, box.position.y, c.z)
		return carriage.global_position
	if _model_root != null:
		return _model_root.global_position
	return global_position


## True for a bed that drops as the print grows (the Trash Printer):
## job-state flag → the model → a Z node named like a bed.
func _is_bed_lowering() -> bool:
	if _last_state.has("bed_lowering"):
		return bool(_last_state.get("bed_lowering"))
	if has_meta("fdm_bed_lowering"):
		return bool(get_meta("fdm_bed_lowering"))
	if model_id == "trash_printer":
		return true
	var z_name := ""
	if _profile != null:
		z_name = _profile.axis_node("z").to_lower()
	return z_name.contains("bed")


## Top-centre of the Z-bed's own meshes (world metres).
func _bed_plate_world_origin() -> Vector3:
	var bed := _axis_nodes.get("z") as Node3D if _axis_nodes.has("z") else null
	if bed == null or not is_instance_valid(bed):
		return _bed_world_origin()
	var box := _subtree_aabb(bed)
	if box.size.length_squared() <= 0.0:
		return bed.global_position
	var c := box.get_center()
	return Vector3(c.x, box.end.y, c.z)


## The horizontal centre of the machine FRAME at its base (world): every mesh
## not under a tagged axis node or the tool.
func _bed_world_origin() -> Vector3:
	if _model_root == null:
		var p := get_parent()
		return (p as Node3D).global_position if p is Node3D else global_position
	var box := AABB()
	var found := false
	for n in _model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if _node_under_axis(mi):
			continue
		var b := mi.global_transform * mi.mesh.get_aabb()
		if not found:
			box = b
			found = true
		else:
			box = box.merge(b)
	if not found:
		box = _subtree_aabb(_model_root)
		found = box.size.length_squared() > 0.0
	if not found:
		var pp := get_parent()
		return (pp as Node3D).global_position if pp is Node3D else global_position
	var c := box.get_center()
	# A fixed-bed gantry (the mud printer) prints on the GROUND inside its
	# frame: the terrain's height there, not the frame's lowest mesh (feet
	# seated into a slope sit under the surface).
	var m := _main_node()
	if m != null:
		var gy := TerrainSurfaceQuery.ground_height_at(m, c.x, c.z)
		if is_finite(gy) and absf(gy - box.position.y) < 3.0:
			return Vector3(c.x, gy, c.z)
	return Vector3(c.x, box.position.y, c.z)


func _subtree_aabb(root: Node3D) -> AABB:
	var box := AABB()
	var found := false
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var b := mi.global_transform * mi.mesh.get_aabb()
		if not found:
			box = b
			found = true
		else:
			box = box.merge(b)
	if not found and root is MeshInstance3D and (root as MeshInstance3D).mesh != null:
		box = root.global_transform * (root as MeshInstance3D).mesh.get_aabb()
	return box


## True when `node` is a descendant of a tagged axis node (it moves).
func _rides_an_axis(node: Node) -> bool:
	var n := node.get_parent()
	while n != null and n != _model_root:
		for key: String in _axis_nodes.keys():
			if n == _axis_nodes[key]:
				return true
		n = n.get_parent()
	return false


func _node_under_axis(node: Node) -> bool:
	var n := node
	while n != null and n != _model_root:
		for key: String in _axis_nodes.keys():
			if n == _axis_nodes[key]:
				return true
		if _profile != null:
			var tname := _profile.tool_node
			if not tname.is_empty() and n.name == tname:
				return true
		n = n.get_parent()
	return false


static func _color_from(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback


## Default travel magnitude (local units) when the profile has none: half the
## moving sub-tree's largest local dimension.
static func _default_travel_for(node: Node3D) -> float:
	var aabb := AABB()
	var found := false
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box := _xform_rel(node, mi) * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	if not found:
		return 1.0
	var m := maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z)
	return maxf(m * 0.5, 0.01)


static func _xform_rel(ancestor: Node3D, descendant: Node3D) -> Transform3D:
	var t := descendant.transform
	var p := descendant.get_parent()
	while p != null and p != ancestor and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


func _find_model_root() -> Node3D:
	var p := get_parent()
	if p == null:
		return null
	var mr := p.get_node_or_null("ModelRoot") as Node3D
	return mr if mr != null else p as Node3D


func _terrain_loader() -> Node:
	var m := _main_node()
	if m == null:
		return null
	return m.find_child("TerrainLoader", true, false)


func _read_abs_hours() -> float:
	var m := _main_node()
	if m != null and m.has_method("get_absolute_hours"):
		return float(m.call("get_absolute_hours"))
	return 0.0


func _system_graph_view() -> Node:
	var m := _main_node()
	if m == null:
		return null
	return ServiceLocator.graph()


func _main_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var m := tree.get_first_node_in_group("main_scene")
	if m != null:
		return m
	return tree.current_scene
