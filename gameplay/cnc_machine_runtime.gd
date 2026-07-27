class_name CncMachineRuntime
extends Node3D

## Generalized Cartesian (X/Y/Z) motion driver for any placed CNC machine — CNC
## router/mill, laser, FDM/flake 3D printer, earth printer. Attached by
## PlacedPropRuntime to a PlacedProp whose record has kind == "cartesian_machine"
## (mirrors CspTroughTracker's pattern). It reads a CartesianMachineProfile (the
## user-taggable axis bindings) and the bound graph node's live job state, then
## translates each tagged axis sub-node along its calibrated local direction so
## the head visibly traces the decimated real toolpath as the job runs.
##
## Progress is a PURE FUNCTION of the simulation clock (job_start_abs_hours +
## duration), computed centrally by SystemGraphView._tick_graph_tools, so the
## motion scrubs correctly forward/backward at any time-scale — the same
## reversible principle the sun-tracking machines use. This script owns only the
## visual kinematics; energy/material/inventory accounting lives in the graph.

const _POS_TAU_REAL := 0.12
const _POS_TAU_SIM := 0.02
const _SNAP_SIM_HOURS := 0.4
const _GHOST_MAX_INSTANCES := 2000

var model_id: String = ""
var graph_item_id: String = ""
var _profile: CartesianMachineProfile = null

var _model_root: Node3D = null
var _axis_nodes: Dictionary = {}       # key -> Node3D
var _axis_rest: Dictionary = {}        # key -> Vector3 (rest local position)
var _rest_by_node: Dictionary = {}     # node_name -> Vector3 (original rest, survives re-tag)
var _axis_dir: Dictionary = {}         # key -> Vector3 (signed unit dir, parent frame)
var _axis_min: Dictionary = {}         # key -> float (job window at norm 0)
var _axis_max: Dictionary = {}         # key -> float (job window at norm 1)
var _axis_home: Dictionary = {}        # key -> float (park / origin local units)
var _axis_travel: Dictionary = {}      # key -> float (= max − min)
var _axis_soft_min: Dictionary = {}    # key -> Machine Setup soft min (restored between jobs)
var _axis_soft_max: Dictionary = {}    # key -> Machine Setup soft max
var _axis_norm: Dictionary = {}        # key -> float (current eased 0..1)
## Bed-local seating for bed-lowering prints (rides the Z bed; do not re-pin world).
var _print_seat_local := Transform3D.IDENTITY
var _print_seat_key := ""

var _job_id: String = ""
var _path: PackedVector3Array = PackedVector3Array()
var _ext: PackedInt32Array = PackedInt32Array()
var _cum: PackedFloat32Array = PackedFloat32Array()
var _path_total: float = 0.0
var _bmin: Vector3 = Vector3.ZERO
var _bmax: Vector3 = Vector3.ZERO

# Additive-print ghost (bead mode, e.g. trash printer): a MultiMesh of beads at
# the extruding toolpath points, revealed progressively so the printed object
# materializes on the bed layer by layer.
var _additive := false
var _print_ghost: MultiMeshInstance3D = null
var _ghost_total := 0
var _ghost_job := ""

# Print-object mode (mud/clay/concrete printer): render the uploaded STL mesh
# itself — a translucent placement ghost before the job, then a solid mesh
# sliced by a shader that reveals bottom-up as the nozzle rises, drying to a
# solid color on completion and persisting on the map (handed to terrain loader).
const _REVEAL_SHADER := preload("res://gameplay/print_reveal.gdshader")
var _mesh_mode := false                 # true when this machine prints a mesh
var _preview_mesh: ArrayMesh = null     # STL mesh set by the Print modal
var _preview_path: String = ""
var _preview_offset := Vector2.ZERO     # bed-plane offset (metres, machine frame)
var _preview_scale := 1.0
var _preview_wet := Color(0.36, 0.26, 0.17)
var _preview_dry := Color(0.68, 0.56, 0.42)
var _ghost_mi: MeshInstance3D = null     # translucent pre-print placement ghost
var _reveal_mi: MeshInstance3D = null    # in-progress sliced solid
var _reveal_mat: ShaderMaterial = null
var _reveal_height := 0.0                # model-space Y span of the reveal mesh
var _reveal_job := ""
var _persisted_job := ""
var _bed_origin_cache := Vector3.ZERO    # cached footprint-center world anchor
var _bed_origin_valid := false
var _bed_origin_root_pos := Vector3.ZERO # invalidate cache when the machine moves
## Local axis units from rest → pose that puts the tool over bed center (mud XY).
var _mud_axis_center_u: Dictionary = {}  # key -> float

var _last_abs_hours: float = INF
var _ready_ok := false


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


## Re-resolve the tagged axis nodes/directions/travel from the current profile.
## Rest positions are cached per node NAME so they survive a re-tag; _axis_norm is
## preserved so the head doesn't jump when the player recalibrates mid-job.
func _resolve_axes() -> void:
	_axis_nodes.clear()
	_axis_dir.clear()
	_axis_min.clear()
	_axis_max.clear()
	_axis_home.clear()
	_axis_travel.clear()
	_axis_soft_min.clear()
	_axis_soft_max.clear()
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
			# Uncalibrated: fall back to AABB half-extent as a soft max from 0.
			lo = 0.0
			hi = fallback
			home = 0.0
		elif fallback > 0.05 and (hi - lo) > fallback * 4.0:
			# Soft-heal inflated legacy travels (old print-span calibration) that
			# launched carriages past the rails into free air.
			var mid := lerpf(lo, hi, 0.5)
			lo = mid - fallback * 0.5
			hi = mid + fallback * 0.5
			home = clampf(home, lo, hi)
		_axis_soft_min[key] = lo
		_axis_soft_max[key] = hi
		_axis_min[key] = lo
		_axis_max[key] = hi
		_axis_home[key] = home
		_axis_travel[key] = hi - lo
		if not _axis_norm.has(key):
			# Start at home (normalized into 0..1 of the min→max span).
			var span := hi - lo
			_axis_norm[key] = 0.0 if span <= 1e-6 else clampf((home - lo) / span, 0.0, 1.0)
	_ready_ok = not _axis_nodes.is_empty()
	_print_seat_key = ""


## Live-apply an edited CartesianMachineProfile to an already-placed machine
## (invoked by the Machine Setup modal on Save). Snaps tagged nodes back to their
## original rest, reloads the profile from the store, then re-resolves.
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
	# Force the ghost to rebuild against the (possibly new) bed anchor.
	_ghost_job = ""


func _process(delta: float) -> void:
	if not _ready_ok:
		return
	var abs_hours := _read_abs_hours()
	var sim_dh := 0.0
	if is_finite(_last_abs_hours):
		sim_dh = abs_hours - _last_abs_hours
	_last_abs_hours = abs_hours

	var state := _job_state()
	var active := bool(state.get("active", false))
	var progress := clampf(float(state.get("progress", 0.0)), 0.0, 1.0)
	_additive = bool(state.get("additive", false))
	# Mud + trash printers share STL reveal simulation; mud persists, trash credits inventory.
	var mk := str(state.get("machine_kind", ""))
	_mesh_mode = mk == "mud" or mk == "trash" \
			or (not str(state.get("print_mesh_path", "")).is_empty() and bool(state.get("additive", false)))
	var new_job := str(state.get("job_id", ""))
	if new_job != _job_id:
		if new_job.is_empty():
			_clear_job()
		else:
			_load_job(new_job)

	# Keep bed anchor fresh if the player dragged the machine.
	_invalidate_bed_origin_if_moved()

	# Target normalized 0..1 per axis from the toolpath (or home).
	# Job windows (_axis_min/max) are calibrated to the PRINT span — not the full
	# soft rail travel — so a 12 mm tall part only drops the bed ~12 mm.
	var bed_lowering := _mesh_mode and _is_bed_lowering()
	var fdm_xy := _mesh_mode  # mud + trash: XY tracks print footprint about bed center
	var target := {
		"x": _home_norm("x"), "y": _home_norm("y"), "z": _home_norm("z"),
	}
	if fdm_xy and not bed_lowering:
		# Fixed-bed (mud): park XY mid-stroke when idle.
		target["x"] = 0.5
		target["y"] = 0.5
	elif bed_lowering:
		# Bed-lowering: Z parks at home (top of drop); XY mid when idle.
		target["x"] = 0.5
		target["y"] = 0.5
		target["z"] = _home_norm("z")
	var completed_job := bool(state.get("completed", false))
	if (active or (completed_job and progress < 1.0)) and not _path.is_empty():
		var p := _sample_path(progress)
		target["x"] = _norm_axis(p.x, _bmin.x, _bmax.x)
		target["y"] = _norm_axis(p.y, _bmin.y, _bmax.y)
		# Job Z window is home→home+height, so path-norm 0..1 is the drop fraction.
		target["z"] = _norm_axis(p.z, _bmin.z, _bmax.z)
	elif completed_job:
		if _persisted_job == _job_id or _job_id.is_empty():
			target = {
				"x": 0.5 if fdm_xy else _home_norm("x"),
				"y": 0.5 if fdm_xy else _home_norm("y"),
				"z": _home_norm("z"),
			}
		elif not _path.is_empty():
			var pend := _sample_path(1.0)
			target["x"] = _norm_axis(pend.x, _bmin.x, _bmax.x)
			target["y"] = _norm_axis(pend.y, _bmin.y, _bmax.y)
			target["z"] = _norm_axis(pend.z, _bmin.z, _bmax.z)

	if fdm_xy and (active or not _path.is_empty()):
		_ensure_mud_axis_centers()

	var snap := absf(sim_dh) > _SNAP_SIM_HOURS
	var x := delta / _POS_TAU_REAL + absf(sim_dh) / _POS_TAU_SIM
	var k := 1.0 if snap else clampf(1.0 - exp(-x), 0.0, 1.0)
	for key: String in _axis_nodes.keys():
		var cur := float(_axis_norm.get(key, 0.0))
		cur = lerpf(cur, float(target.get(key, _home_norm(key))), k)
		_axis_norm[key] = cur
		var node := _axis_nodes[key] as Node3D
		if not is_instance_valid(node):
			continue
		var dir: Vector3 = _axis_dir[key] as Vector3
		var lo := float(_axis_min.get(key, 0.0))
		var hi := float(_axis_max.get(key, float(_axis_travel.get(key, 0.0))))
		var along := lerpf(lo, hi, cur)
		if fdm_xy and key != "z":
			# Mid-stroke at bed center + (norm-0.5)*calibrated PRINT span.
			var center_u := float(_mud_axis_center_u.get(key, lerpf(lo, hi, 0.5)))
			var travel := maxf(hi - lo, 1e-4)
			var du := (0.5 - cur) if key == "y" else (cur - 0.5)
			along = center_u + travel * du
		node.position = (_axis_rest[key] as Vector3) + dir * along

	if _mesh_mode:
		_update_print_reveal(state, active, progress)
	elif _additive:
		_update_print_ghost(progress)


# ---------------------------------------------------------------------------
# Print-object mode (mud/clay/concrete printer): STL ghost -> sliced reveal.
# ---------------------------------------------------------------------------

## Called by the in-world Print modal to show/update the translucent placement
## ghost of the STL before the job starts.
func begin_print_preview(mesh: ArrayMesh, path: String) -> void:
	_mesh_mode = true
	_preview_mesh = mesh
	_preview_path = path
	if _model_root == null:
		_model_root = _find_model_root()
	# Ensure bed-lowering seating even before a job is scheduled.
	if model_id == "trash_printer" or (_profile != null \
			and _profile.axis_node("z").to_lower().contains("bed")):
		set_meta("fdm_bed_lowering", true)
	_bed_origin_valid = false   # re-anchor in case the machine was repositioned
	_rebuild_preview_ghost()


func update_print_preview(offset: Vector2, sc: float, wet: Color, dry: Color) -> void:
	_preview_offset = offset
	_preview_scale = maxf(sc, 0.01)
	_preview_wet = wet
	_preview_dry = dry
	_rebuild_preview_ghost()


func clear_print_preview() -> void:
	_free_preview_ghost()


func has_print_preview() -> bool:
	return _preview_mesh != null


## AABB (metres) of the current preview mesh — lets the modal size a sane default
## scale relative to the machine's work volume.
func preview_mesh_aabb() -> AABB:
	if _preview_mesh == null:
		return AABB()
	return _preview_mesh.get_aabb()


func _rebuild_preview_ghost() -> void:
	if _preview_mesh == null or _model_root == null:
		_free_preview_ghost()
		return
	if _ghost_mi == null or not is_instance_valid(_ghost_mi):
		_ghost_mi = MeshInstance3D.new()
		_ghost_mi.name = "PrintPreviewGhost"
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.45, 0.9, 1.0, 0.32)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.emission_enabled = true
		mat.emission = Color(0.3, 0.7, 0.95)
		mat.emission_energy_multiplier = 0.5
		_ghost_mi.material_override = mat
		_ghost_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost_mi.mesh = _preview_mesh
	_seat_print_mesh(_ghost_mi, _preview_offset, _preview_scale)


func _free_preview_ghost() -> void:
	if _ghost_mi != null and is_instance_valid(_ghost_mi):
		_ghost_mi.queue_free()
	_ghost_mi = null


## Per-frame reveal update: build the sliced solid when the job starts, raise the
## reveal cut with the toolpath Z (not path-length progress — otherwise the head
## jumps a full layer while the mesh barely grows), dry lower layers as the tip
## advances, and on completion hand the finished object to the terrain loader
## then clear the local reveal so the machine can be moved away.
func _update_print_reveal(state: Dictionary, active: bool, progress: float) -> void:
	var completed := bool(state.get("completed", false))
	# Build the sliced solid as soon as the job is running — or on completion if a
	# very short print finished before the first active tick — so it's always ready
	# to reveal and later persist.
	if _job_id != "" and _reveal_job != _job_id and (active or (completed and _persisted_job != _job_id)):
		_build_reveal(state)
	if _reveal_mi != null and is_instance_valid(_reveal_mi) and _reveal_mat != null:
		var reveal_y := _reveal_height_from_path(progress, state)
		if completed or progress >= 0.995:
			reveal_y = _reveal_height
		_reveal_mat.set_shader_parameter("reveal_y", reveal_y)
		# Force full dry on completion; otherwise tip stays wet, lower layers auto-dry in shader.
		var dry_u := 1.0 if (completed or progress >= 0.995) else clampf(progress * 0.35, 0.0, 0.25)
		_reveal_mat.set_shader_parameter("dryness", dry_u)
		# Bed-lowering: keep parented to the Z bed with a FIXED local seat so the
		# print rides down with the bed (re-pinning world Y every frame un-parents
		# the motion visually when the plate origin is noisy).
		if _is_bed_lowering():
			var off := Vector2(float(state.get("print_offset_x", _preview_offset.x)),
				float(state.get("print_offset_z", _preview_offset.y)))
			var sc := maxf(float(state.get("print_scale", _preview_scale)), 0.01)
			_ensure_bed_print_parent(_reveal_mi, off, sc)
	if completed and progress >= 0.99 and _persisted_job != _job_id:
		_persist_print(state)


## Map the current toolpath sample's Z onto mesh-local Y so the nozzle and the
## growing solid stay locked layer-for-layer (path-length progress alone races).
func _reveal_height_from_path(progress: float, state: Dictionary) -> float:
	if _path.is_empty() or _reveal_height <= 0.0:
		return clampf(progress, 0.0, 1.0) * _reveal_height
	var p := _sample_path(progress)
	var layer_h := maxf(float(state.get("layer_height_mm", 50.0)), 0.05)
	var z_span := maxf(_bmax.z - _bmin.z, layer_h)
	# Bead top at current layer midpoint + half layer, normalized into mesh height.
	var z_top := p.z - _bmin.z + layer_h * 0.5
	var frac := clampf(z_top / (z_span + layer_h), 0.0, 1.0)
	# Near the end of the job, finish the reveal even if Z sits on the last midpoint.
	if progress >= 0.995:
		frac = 1.0
	return frac * _reveal_height


func _build_reveal(state: Dictionary) -> void:
	_free_reveal()
	_reveal_job = _job_id
	_bed_origin_valid = false   # re-anchor to the machine's current footprint
	if _model_root == null:
		_model_root = _find_model_root()
	if _model_root == null:
		return
	var mesh: ArrayMesh = _preview_mesh
	var path := str(state.get("print_mesh_path", ""))
	if mesh == null and not path.is_empty():
		mesh = StlLoader.build_mesh(path)
	if mesh == null:
		return
	if not path.is_empty():
		_preview_path = path
	var off := Vector2(float(state.get("print_offset_x", 0.0)), float(state.get("print_offset_z", 0.0)))
	var sc := maxf(float(state.get("print_scale", 1.0)), 0.01)
	_preview_offset = off
	_preview_scale = sc
	var wet := _color_from(state.get("wet_color"), _preview_wet)
	var dry := _color_from(state.get("dry_color"), _preview_dry)
	_reveal_height = maxf(mesh.get_aabb().size.y, 0.001)
	# Ensure bed-lowering kinematics even if the modal closed before the job.
	if bool(state.get("bed_lowering", false)) or model_id == "trash_printer":
		set_meta("fdm_bed_lowering", true)
	_print_seat_key = ""
	_calibrate_travels_to_print(sc)
	_reveal_mat = ShaderMaterial.new()
	_reveal_mat.shader = _REVEAL_SHADER
	_reveal_mat.set_shader_parameter("wet_color", Vector3(wet.r, wet.g, wet.b))
	_reveal_mat.set_shader_parameter("dry_color", Vector3(dry.r, dry.g, dry.b))
	_reveal_mat.set_shader_parameter("dryness", 0.0)
	_reveal_mat.set_shader_parameter("reveal_y", 0.0)
	_reveal_mi = MeshInstance3D.new()
	_reveal_mi.name = "PrintReveal"
	_reveal_mi.mesh = mesh
	_reveal_mi.material_override = _reveal_mat
	# The reveal material uses `discard` (hard slice cut) + cull_disabled, which is
	# fill-heavy; letting it also render into the 4 directional shadow splits every
	# frame is what makes standing next to an active printer sag. The animated,
	# temporary print doesn't need to cast a shadow — skip the shadow pass entirely.
	_reveal_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_seat_print_mesh(_reveal_mi, off, sc)
	_free_preview_ghost()


## Match gantry X/Y/Z travel to the PRINT footprint/height (clamped inside Machine
## Setup soft limits). Bed-lowering Z drops from home by print height only — a
## 12 mm part must not drive the bed through its full soft stroke.
func _calibrate_travels_to_print(sc: float) -> void:
	_restore_soft_limits()
	var s := maxf(sc, 0.01)
	var span_x_m := maxf((_bmax.x - _bmin.x) * 0.001 * s, 0.005)
	var span_y_m := maxf((_bmax.y - _bmin.y) * 0.001 * s, 0.005)
	var height_m := maxf(_reveal_height * s, 0.0)
	if height_m < 0.0005:
		height_m = maxf((_bmax.z - _bmin.z) * 0.001 * s, 0.0005)
	# Pad XY by roughly one line width so the nozzle reaches outer beads.
	var line_mm := 6.0
	var st := _job_state()
	if not st.is_empty():
		line_mm = maxf(float(st.get("line_width_mm", line_mm)), 0.2)
	var pad := maxf(line_mm * 0.001 * s, 0.001)

	if _is_bed_lowering():
		_calibrate_axis_travel_centered("x", span_x_m + pad)
		_calibrate_axis_travel_centered("y", span_y_m + pad)
		_calibrate_axis_travel_from_home("z", height_m)
		# Start the drop from the top of the job window (home).
		_axis_norm["x"] = 0.5
		_axis_norm["y"] = 0.5
		_axis_norm["z"] = 0.0
	else:
		_calibrate_axis_travel_centered("x", span_x_m + pad)
		_calibrate_axis_travel_centered("y", span_y_m + pad)
		_calibrate_axis_travel_centered("z", height_m)
	_mud_axis_center_u.clear()
	_ensure_mud_axis_centers()
	# Snap axes to the freshly calibrated start pose before seating the print,
	# so the bed-local capture happens at home/top (not a leftover mid-stroke).
	_snap_axes_to_norm()


func _restore_soft_limits() -> void:
	for key: String in _axis_soft_min.keys():
		_axis_min[key] = float(_axis_soft_min[key])
		_axis_max[key] = float(_axis_soft_max[key])
		_axis_travel[key] = float(_axis_max[key]) - float(_axis_min[key])


## Shrink the job window to `span_m` world metres, centered in the soft limits.
func _calibrate_axis_travel_centered(key: String, span_m: float) -> void:
	if not _axis_nodes.has(key) or span_m <= 1e-6:
		return
	var mpl := _metres_per_local(key)
	if mpl <= 1e-9:
		return
	var soft_lo := float(_axis_soft_min.get(key, _axis_min.get(key, 0.0)))
	var soft_hi := float(_axis_soft_max.get(key, _axis_max.get(key, 0.0)))
	var soft_span := maxf(soft_hi - soft_lo, 0.0)
	var needed := span_m / mpl
	if soft_span > 1e-6:
		needed = minf(needed, soft_span)
	needed = maxf(needed, 1e-4)
	var mid := lerpf(soft_lo, soft_hi, 0.5) if soft_span > 1e-6 else 0.0
	_axis_min[key] = mid - needed * 0.5
	_axis_max[key] = mid + needed * 0.5
	_axis_travel[key] = needed


## Bed-lowering Z: path-norm 0 at home (bed up), 1 at home+print_height (bed down).
## Positive along already points down when the axis is Invert-tagged.
func _calibrate_axis_travel_from_home(key: String, span_m: float) -> void:
	if not _axis_nodes.has(key) or span_m <= 1e-6:
		return
	var mpl := _metres_per_local(key)
	if mpl <= 1e-9:
		return
	var soft_lo := float(_axis_soft_min.get(key, 0.0))
	var soft_hi := float(_axis_soft_max.get(key, 0.0))
	var home := float(_axis_home.get(key, soft_lo))
	if soft_hi > soft_lo:
		home = clampf(home, soft_lo, soft_hi)
	var needed := maxf(span_m / mpl, 1e-4)
	var avail := maxf(soft_hi - home, 0.0)
	if avail < 1e-6:
		# No room past home — drop from soft_lo across the soft span instead.
		home = soft_lo
		avail = maxf(soft_hi - soft_lo, 1e-4)
	needed = minf(needed, avail)
	_axis_min[key] = home
	_axis_max[key] = home + needed
	_axis_travel[key] = needed


func _metres_per_local(key: String) -> float:
	if not _axis_nodes.has(key):
		return 0.0
	var node := _axis_nodes[key] as Node3D
	if not is_instance_valid(node):
		return 0.0
	var dir: Vector3 = _axis_dir.get(key, Vector3.ZERO) as Vector3
	if dir.length_squared() < 1e-8:
		return 0.0
	# Includes ModelRoot / inch→metre scale in the ancestor chain.
	return maxf((node.global_transform.basis * dir.normalized()).length(), 1e-6)


## Apply current `_axis_norm` poses immediately (no easing) — used after job
## calibration so bed-local print seating is captured at the start pose.
func _snap_axes_to_norm() -> void:
	for key: String in _axis_nodes.keys():
		var node := _axis_nodes[key] as Node3D
		if not is_instance_valid(node):
			continue
		var dir: Vector3 = _axis_dir[key] as Vector3
		var lo := float(_axis_min.get(key, 0.0))
		var hi := float(_axis_max.get(key, 0.0))
		var cur := float(_axis_norm.get(key, 0.0))
		var along := lerpf(lo, hi, cur)
		if key != "z":
			var center_u := float(_mud_axis_center_u.get(key, lerpf(lo, hi, 0.5)))
			var travel := maxf(absf(hi - lo), 1e-4)
			var du := (0.5 - cur) if key == "y" else (cur - 0.5)
			along = center_u + travel * du
		node.position = (_axis_rest[key] as Vector3) + dir * along


func _home_norm(key: String) -> float:
	var lo := float(_axis_min.get(key, 0.0))
	var hi := float(_axis_max.get(key, 0.0))
	var home := float(_axis_home.get(key, lo))
	var span := hi - lo
	if absf(span) <= 1e-6:
		return 0.0
	return clampf((home - lo) / span, 0.0, 1.0)


## Measure how far (in axis travel units) each XY axis must move from rest so the
## tool tip sits over the bed center. Cached until travels are recalibrated.
func _ensure_mud_axis_centers() -> void:
	if not _mud_axis_center_u.is_empty():
		return
	if _model_root == null or not _axis_nodes.has("x"):
		return
	# Snap axes to rest so tip measurement matches _axis_rest.
	for key2: String in _axis_nodes.keys():
		var n2 := _axis_nodes[key2] as Node3D
		if is_instance_valid(n2) and _axis_rest.has(key2):
			n2.position = _axis_rest[key2] as Vector3
	var tip := _tool_tip_world()
	# Bed-lowering: aim the nozzle at the Z-bed plate; mud: frame bed center.
	var bed := _bed_plate_world_origin() if _is_bed_lowering() else _bed_world_origin()
	var delta := bed - tip
	for key: String in ["x", "y"]:
		if not _axis_nodes.has(key):
			continue
		var node := _axis_nodes[key] as Node3D
		var dir: Vector3 = _axis_dir.get(key, Vector3.ZERO) as Vector3
		if not is_instance_valid(node) or dir.length_squared() < 1e-8:
			_mud_axis_center_u[key] = 0.0
			continue
		var dir_w := (node.global_transform.basis * dir.normalized()).normalized()
		var metres_per_local := _metres_per_local(key)
		# Project bed←tip onto the axis; convert world metres → local travel units.
		_mud_axis_center_u[key] = delta.dot(dir_w) / metres_per_local


func _tool_tip_world() -> Vector3:
	if _profile != null and not _profile.tool_node.is_empty() and _model_root != null:
		var tool := _model_root.find_child(_profile.tool_node, true, false) as Node3D
		if tool != null:
			return tool.global_position
	# Fallback: deepest X-axis child (carriage) or model origin.
	if _axis_nodes.has("x") and is_instance_valid(_axis_nodes["x"]):
		return (_axis_nodes["x"] as Node3D).global_position
	if _model_root != null:
		return _model_root.global_position
	return global_position


func _persist_print(state: Dictionary) -> void:
	if _persisted_job == _job_id and _job_id != "":
		_free_reveal()
		return
	_persisted_job = _job_id
	# Extinguish wet glow before handoff (night-visible emission otherwise sticks).
	if _reveal_mat != null:
		_reveal_mat.set_shader_parameter("dryness", 1.0)
		_reveal_mat.set_shader_parameter("reveal_y", _reveal_height)
	# Trash / inventory prints: reveal completes visually then clears — graph tick
	# credits the part. Mud (print_persist) registers a durable map object at the
	# CURRENT world pose so the machine can be moved away afterward.
	if bool(state.get("print_persist", false)):
		var loader := _terrain_loader()
		if loader != null and loader.has_method("register_printed_object") \
				and _reveal_mi != null and is_instance_valid(_reveal_mi) \
				and _reveal_mi.mesh != null:
			var dry := _color_from(state.get("dry_color"), _preview_dry)
			# Re-seat from the stable frame bed origin (not a possibly-stale
			# global_transform) and hand the live mesh so the placed prop matches
			# the in-progress reveal exactly (STL reload can re-center differently).
			var off := Vector2(float(state.get("print_offset_x", _preview_offset.x)),
				float(state.get("print_offset_z", _preview_offset.y)))
			var sc := maxf(float(state.get("print_scale", _preview_scale)), 0.01)
			_bed_origin_valid = false
			var xf := _print_world_xform(off, sc)
			loader.call("register_printed_object", {
				"job_id": _job_id,
				"mesh_path": _preview_path,
				"xform": xf,
				"mesh": _reveal_mi.mesh,
				"dry_color": [dry.r, dry.g, dry.b],
				"source": model_id,
			})
	_free_reveal()
	_bed_origin_valid = false
	_mud_axis_center_u.clear()


func _free_reveal() -> void:
	if _reveal_mi != null and is_instance_valid(_reveal_mi):
		_reveal_mi.queue_free()
	_reveal_mi = null
	_reveal_mat = null
	_reveal_job = ""
	_print_seat_key = ""


## True for bed-lowering FDM: nozzle stays fixed, Z bed drops, and the print
## mesh is parented to the bed so it rides the reveal. Preference order:
## job-state / modal meta flag → model_id trash → Z axis node name contains "bed".
func _is_bed_lowering() -> bool:
	if has_meta("fdm_bed_lowering"):
		return bool(get_meta("fdm_bed_lowering"))
	var state := _job_state()
	if state.has("bed_lowering"):
		return bool(state.get("bed_lowering"))
	if model_id == "trash_printer":
		return true
	var z_name := ""
	if _profile != null:
		z_name = _profile.axis_node("z").to_lower()
	return z_name.contains("bed")


## Parent + seat a print mesh. Bed-lowering → child of Z bed with a captured
## bed-local transform (rides the drop). Mud / fixed-bed → runtime child at the
## frame footprint center.
func _seat_print_mesh(mi: MeshInstance3D, off: Vector2, sc: float) -> void:
	if mi == null:
		return
	var s := maxf(sc, 0.01)
	if _is_bed_lowering():
		_capture_bed_print_seat(mi, off, s)
		return
	if mi.get_parent() != self:
		if mi.get_parent() != null:
			mi.get_parent().remove_child(mi)
		add_child(mi)
	mi.global_transform = _print_world_xform(off, s)


## Keep a bed-lowering print parented with its captured local seat (no world re-pin).
func _ensure_bed_print_parent(mi: MeshInstance3D, off: Vector2, sc: float) -> void:
	if mi == null:
		return
	var bed := _ghost_anchor_node()
	if bed == null:
		_seat_print_mesh(mi, off, sc)
		return
	var s := maxf(sc, 0.01)
	var key := "%d|%.5f|%.5f|%.5f" % [bed.get_instance_id(), off.x, off.y, s]
	if _print_seat_key != key or mi.get_parent() != bed:
		_capture_bed_print_seat(mi, off, s)
		return
	# Re-assert local seat so nothing else nudges it into world space.
	mi.transform = _print_seat_local


## Pose once in world metres at the plate top, then freeze the resulting bed-local
## transform so subsequent Z motion carries the print with the bed.
func _capture_bed_print_seat(mi: MeshInstance3D, off: Vector2, sc: float) -> void:
	var bed := _ghost_anchor_node()
	if bed == null:
		if mi.get_parent() != self:
			if mi.get_parent() != null:
				mi.get_parent().remove_child(mi)
			add_child(mi)
		mi.global_transform = _bed_print_world_xform(off, sc)
		_print_seat_key = ""
		return
	if mi.get_parent() != bed:
		if mi.get_parent() != null:
			mi.get_parent().remove_child(mi)
		bed.add_child(mi)
	# Seat with Z at its current pose (usually home/top at capture time).
	mi.global_transform = _bed_print_world_xform(off, sc)
	_print_seat_local = mi.transform
	_print_seat_key = "%d|%.5f|%.5f|%.5f" % [bed.get_instance_id(), off.x, off.y, sc]


## World transform for fixed-bed prints (mud): footprint center + bed-plane offset.
func _print_world_xform(off: Vector2, sc: float) -> Transform3D:
	var b := Basis.IDENTITY
	if _model_root != null:
		b = _model_root.global_transform.basis.orthonormalized()
	var origin := _bed_world_origin() + b * Vector3(off.x, 0.0, off.y)
	return Transform3D(b.scaled(Vector3.ONE * sc), origin)


## World transform for bed-lowering prints (trash): top-center of the Z-bed plate
## + player offset in metres. Mesh base (y=0) sits on the plate with a tiny lift.
func _bed_print_world_xform(off: Vector2, sc: float) -> Transform3D:
	var b := Basis.IDENTITY
	if _model_root != null:
		b = _model_root.global_transform.basis.orthonormalized()
	var origin := _bed_plate_world_origin() + b * Vector3(off.x, 0.002, off.y)
	return Transform3D(b.scaled(Vector3.ONE * sc), origin)


## Top-center of the Z-bed mesh (world metres). Falls back to frame bed origin.
func _bed_plate_world_origin() -> Vector3:
	var bed := _ghost_anchor_node()
	if bed == null:
		return _bed_world_origin()
	var aabb := AABB()
	var found := false
	for n in bed.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if mi.name == "PrintReveal" or mi.name == "PrintPreviewGhost":
			continue
		var box := mi.global_transform * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	if not found and bed is MeshInstance3D and (bed as MeshInstance3D).mesh != null:
		aabb = bed.global_transform * (bed as MeshInstance3D).mesh.get_aabb()
		found = true
	if not found:
		return bed.global_position
	var c := aabb.get_center()
	# Sit on the TOP of the bed plate (not the AABB center / bottom).
	return Vector3(c.x, aabb.position.y + aabb.size.y, c.z)


## World point the print sits on: the HORIZONTAL CENTER of the machine FRAME at
## its base (min Y). Excludes moving axis carriages / toolhead — those park at a
## rail extreme and would bias the bed center (and the finished prop) sideways.
## Cache invalidates when the machine is moved.
func _bed_world_origin() -> Vector3:
	_invalidate_bed_origin_if_moved()
	if _bed_origin_valid:
		return _bed_origin_cache
	if _model_root == null:
		_model_root = _find_model_root()
	if _model_root == null:
		var p := get_parent()
		return (p as Node3D).global_position if p is Node3D else global_position
	var aabb := AABB()
	var found := false
	for n in _model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		# Skip in-progress / preview print meshes — they shouldn't shift the bed center.
		if mi.name == "PrintReveal" or mi.name == "PrintPreviewGhost":
			continue
		# Skip anything under a tagged axis node (gantry / bed / tool carriage).
		if _node_under_axis(mi):
			continue
		var box := mi.global_transform * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	if not found:
		# Fallback: full model AABB (better than nothing on odd rigs).
		for n2 in _model_root.find_children("*", "MeshInstance3D", true, false):
			var mi2 := n2 as MeshInstance3D
			if mi2 == null or mi2.mesh == null:
				continue
			if mi2.name == "PrintReveal" or mi2.name == "PrintPreviewGhost":
				continue
			var box2 := mi2.global_transform * mi2.mesh.get_aabb()
			if not found:
				aabb = box2
				found = true
			else:
				aabb = aabb.merge(box2)
	if not found:
		var pp := get_parent()
		return (pp as Node3D).global_position if pp is Node3D else global_position
	var c := aabb.get_center()
	_bed_origin_cache = Vector3(c.x, aabb.position.y, c.z)
	_bed_origin_valid = true
	_bed_origin_root_pos = _model_root.global_position
	return _bed_origin_cache


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


func _invalidate_bed_origin_if_moved() -> void:
	if _model_root == null:
		return
	if not _bed_origin_valid:
		_bed_origin_root_pos = _model_root.global_position
		return
	if _model_root.global_position.distance_squared_to(_bed_origin_root_pos) > 0.0001:
		_bed_origin_valid = false


static func _color_from(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback


func _terrain_loader() -> Node:
	var m := _main_node()
	if m == null:
		return null
	return m.find_child("TerrainLoader", true, false)


## Grow the additive-print ghost with job progress and keep it anchored on the
## bed. Reveals the full object at completion (alpha firms up), clears when the
## job is removed / a new job starts.
func _update_print_ghost(progress: float) -> void:
	if _additive and not _job_id.is_empty() and _ghost_job != _job_id:
		_build_print_ghost()
	if _print_ghost == null or _ghost_total <= 0:
		return
	var mm := _print_ghost.multimesh
	if mm != null:
		mm.visible_instance_count = clampi(int(round(progress * float(_ghost_total))), 0, _ghost_total)
	# Follow the bed (or model root) so completed layers ride the Z carriage.
	var anchor := _ghost_anchor_node()
	if anchor != null:
		_print_ghost.global_transform = Transform3D(
			anchor.global_transform.basis.orthonormalized(), anchor.global_position)
	# Firm up from translucent ghost -> revealed solid as it finishes.
	var mat := _print_ghost.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color.a = lerpf(0.5, 0.95, progress)
		mat.emission_energy_multiplier = lerpf(0.8, 0.15, progress)


func _job_state() -> Dictionary:
	var sgv := _system_graph_view()
	if sgv != null and sgv.has_method("get_cnc_job_state"):
		return sgv.call("get_cnc_job_state", graph_item_id) as Dictionary
	return {}


func _load_job(job_id: String) -> void:
	_job_id = job_id
	_path = PackedVector3Array()
	_ext = PackedInt32Array()
	_cum = PackedFloat32Array()
	_path_total = 0.0
	var data := MachineJobStore.load(job_id)
	if data.is_empty():
		return
	_path = data.get("points", PackedVector3Array())
	_ext = data.get("extruding", PackedInt32Array())
	_bmin = data.get("bounds_min", Vector3.ZERO)
	_bmax = data.get("bounds_max", Vector3.ZERO)
	var n := _path.size()
	if n < 2:
		return
	_cum.resize(n)
	_cum[0] = 0.0
	for i in range(1, n):
		_cum[i] = _cum[i - 1] + _path[i].distance_to(_path[i - 1])
	_path_total = _cum[n - 1]
	# Pre-size gantry travel from path bounds so XY tracking is right even before
	# the reveal mesh builds (mud prints are often larger than the default half-AABB).
	if _mesh_mode or str(data.get("kind", "")) == "mud_building":
		_calibrate_travels_to_print(maxf(_preview_scale, 1.0))


func _clear_job() -> void:
	_job_id = ""
	_path = PackedVector3Array()
	_ext = PackedInt32Array()
	_cum = PackedFloat32Array()
	_path_total = 0.0
	_free_ghost()
	_free_reveal()
	_restore_soft_limits()
	_mud_axis_center_u.clear()
	_print_seat_key = ""


func _free_ghost() -> void:
	if _print_ghost != null and is_instance_valid(_print_ghost):
		_print_ghost.queue_free()
	_print_ghost = null
	_ghost_total = 0
	_ghost_job = ""


## The node the print visually sits on: the Z (bed) node if tagged, else the
## model root. Anchoring to the bed makes finished layers ride the dropping bed.
func _ghost_anchor_node() -> Node3D:
	if _axis_nodes.has("z") and is_instance_valid(_axis_nodes["z"]):
		return _axis_nodes["z"] as Node3D
	return _model_root


## Build the bead MultiMesh for the current additive job: one small box per
## extruding toolpath point (order preserved so visible_instance_count reveals it
## in print order), scaled to sit within the machine footprint on the bed.
func _build_print_ghost() -> void:
	_free_ghost()
	_ghost_job = _job_id
	if _path.size() < 2 or _model_root == null:
		return
	# Collect extruding points in path order (fall back to all points).
	var idx: PackedInt32Array = PackedInt32Array()
	var has_ext := _ext.size() == _path.size()
	for i in _path.size():
		if not has_ext or _ext[i] != 0:
			idx.append(i)
	if idx.size() < 2:
		idx = PackedInt32Array()
		for i in _path.size():
			idx.append(i)
	# Sample down to the instance cap, preserving order.
	var stride := int(ceil(float(idx.size()) / float(_GHOST_MAX_INSTANCES)))
	stride = maxi(stride, 1)
	var sel: PackedInt32Array = PackedInt32Array()
	var j := 0
	while j < idx.size():
		sel.append(idx[j])
		j += stride
	var count := sel.size()
	if count < 2:
		return

	# Metric scale: fit the toolpath footprint into ~40% of the machine footprint.
	var span := _bmax - _bmin
	var horiz_mm := maxf(maxf(span.x, span.y), 1e-3)
	var world_size := _model_world_size()
	var footprint_m := 0.4 * maxf(minf(world_size.x, world_size.z), 0.2)
	var s := clampf(footprint_m / horiz_mm, 1e-5, 1.0)
	var cx := (_bmin.x + _bmax.x) * 0.5
	var cy := (_bmin.y + _bmax.y) * 0.5
	var cell := clampf(s * 2.5, 0.01, 0.25)

	var box := BoxMesh.new()
	box.size = Vector3(cell, cell, cell)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = count
	for n in count:
		var p := _path[sel[n]]
		# gcode X -> local X, gcode Y -> local Z (depth), gcode Z -> local Y (up)
		var local := Vector3((p.x - cx) * s, (p.z - _bmin.z) * s, (p.y - cy) * s)
		mm.set_instance_transform(n, Transform3D(Basis(), local))
	mm.visible_instance_count = 0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.85, 1.0, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.6, 0.9)
	mat.emission_energy_multiplier = 0.8

	_print_ghost = MultiMeshInstance3D.new()
	_print_ghost.name = "PrintGhost"
	_print_ghost.multimesh = mm
	_print_ghost.material_override = mat
	_print_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_print_ghost)
	_ghost_total = count


## Machine bounding-box size in world metres (local AABB scaled by the model
## root's world scale) — used to size the print onto the bed.
func _model_world_size() -> Vector3:
	if _model_root == null:
		return Vector3(1, 1, 1)
	var aabb := AABB()
	var found := false
	for n in _model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box := _xform_rel(_model_root, mi) * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	if not found:
		return Vector3(1, 1, 1)
	var ws := _model_root.global_transform.basis.get_scale().abs()
	return Vector3(aabb.size.x * ws.x, aabb.size.y * ws.y, aabb.size.z * ws.z)


func _sample_path(progress: float) -> Vector3:
	var n := _path.size()
	if n == 0:
		return Vector3.ZERO
	if n == 1 or _path_total <= 0.0:
		return _path[n - 1]
	var target_len := _path_total * progress
	# Binary-ish forward scan (path is small, <= MAX_SEGMENTS).
	var i := 1
	while i < n - 1 and _cum[i] < target_len:
		i += 1
	var a := i - 1
	var span := _cum[i] - _cum[a]
	var t := 0.0 if span <= 0.0 else (target_len - _cum[a]) / span
	return _path[a].lerp(_path[i], clampf(t, 0.0, 1.0))


static func _norm_axis(v: float, lo: float, hi: float) -> float:
	var range_v := hi - lo
	if absf(range_v) < 1e-4:
		return 0.0
	return clampf((v - lo) / range_v, 0.0, 1.0)


## Default travel magnitude (local units) when the profile has none: half the
## moving sub-tree's largest local dimension, so uncalibrated motion is visible.
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


func _read_abs_hours() -> float:
	var m := _main_node()
	if m != null and m.has_method("get_absolute_hours"):
		return float(m.call("get_absolute_hours"))
	return 0.0


func _system_graph_view() -> Node:
	var m := _main_node()
	if m == null:
		return null
	return m.get_node_or_null("UILayer/SystemGraphView")


func _main_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var m := tree.get_first_node_in_group("main_scene")
	if m != null:
		return m
	return tree.current_scene
