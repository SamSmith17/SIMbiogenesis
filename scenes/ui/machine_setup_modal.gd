extends Control

## Machine Setup modal — the generalized axis-tagging UI. Shows the machine model
## in a SubViewport studio and lets the player bind each X/Y/Z axis to a model
## sub-node, flip its direction (invert), set soft min/max travel + home/origin,
## and JOG each axis live to verify the motion before saving. Writes to the shared
## CartesianMachineProfile store (user://machines/profiles.json), so the same
## kinematics engine (CncMachineRuntime) then animates that machine — and any
## other machine the player imports and tags the same way.
##
## Mirrors the building_builder_modal SubViewport-studio + dim-backdrop pattern.

const MODAL_NAME := "machine_setup"

## Travel-direction choices offered per axis (the local base direction the node
## slides along; the Invert toggle flips its sign). Lets the player match the
## model's real kinematics — e.g. swap which world direction the Y vs Z carriage
## actually moves.
const AXIS_CHOICES: Array = [
	{"label": "Local X (→)", "vec": Vector3(1, 0, 0)},
	{"label": "Local Y (↑)", "vec": Vector3(0, 1, 0)},
	{"label": "Local Z (↗)", "vec": Vector3(0, 0, 1)},
]

var _model_id: String = ""
var _item_id: String = ""
var _profile: CartesianMachineProfile = null

var _built := false
var _viewport: SubViewport = null
var _studio: Node3D = null
var _holder: Node3D = null
var _camera: Camera3D = null
var _model_inst: Node3D = null

var _node_names: PackedStringArray = PackedStringArray()
var _rest_by_name: Dictionary = {}          # node name -> rest local position

# Per-axis controls (key -> control).
var _node_opt: Dictionary = {}
var _dir_opt: Dictionary = {}
var _invert_chk: Dictionary = {}
var _min_spin: Dictionary = {}
var _max_spin: Dictionary = {}
var _home_spin: Dictionary = {}
var _jog_slider: Dictionary = {}
var _jog_lbl: Dictionary = {}
var _tool_opt: OptionButton = null
var _status_lbl: Label = null


func open(model_id: String, item_id: String) -> void:
	_model_id = model_id
	_item_id = item_id
	_profile = CartesianMachineProfile.get_profile(model_id)
	if not _built:
		_build_ui()
		_built = true
	_rebuild_studio()
	_populate_controls()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	visible = false
	CursorController.release_modal(MODAL_NAME)


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(980, 640)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	center.add_child(panel)
	UiFit.adopt(panel)  # above the timeline, inside the screen at any size

	var root_v := VBoxContainer.new()
	root_v.add_theme_constant_override("separation", 8)
	panel.add_child(root_v)

	var title := Label.new()
	title.text = "Machine Setup — tag X / Y / Z axes"
	title.add_theme_font_size_override("font_size", 18)
	root_v.add_child(title)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_v.add_child(hbox)

	var vpc := SubViewportContainer.new()
	vpc.stretch = true
	vpc.custom_minimum_size = Vector2(580, 560)
	vpc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(vpc)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.size = Vector2i(580, 560)
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	vpc.add_child(_viewport)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 560)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(scroll)
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(340, 0)
	side.add_theme_constant_override("separation", 8)
	scroll.add_child(side)

	var hint := Label.new()
	hint.text = "Pick the sub-node for each axis, jog to the rail ends, then Set min / Set max. Set home for the park/origin pose. Invert flips direction."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(0.75, 0.82, 0.9)
	side.add_child(hint)

	for key: String in CartesianMachineProfile.AXIS_KEYS:
		side.add_child(_build_axis_row(key))

	var tool_row := HBoxContainer.new()
	var tool_lbl := Label.new()
	tool_lbl.text = "Tool node"
	tool_lbl.custom_minimum_size = Vector2(70, 0)
	tool_row.add_child(tool_lbl)
	_tool_opt = OptionButton.new()
	_tool_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tool_row.add_child(_tool_opt)
	side.add_child(tool_row)

	var auto_btn := Button.new()
	auto_btn.text = "✨ Auto-detect axes"
	auto_btn.pressed.connect(_on_auto_detect)
	side.add_child(auto_btn)

	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", 12)
	_status_lbl.modulate = Color(0.7, 0.85, 0.7)
	side.add_child(_status_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	side.add_child(btn_row)
	var save_btn := Button.new()
	save_btn.text = "💾 Save"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_save)
	btn_row.add_child(save_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(close)
	btn_row.add_child(close_btn)


func _build_axis_row(key: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var hdr := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "%s axis" % key.to_upper()
	lbl.custom_minimum_size = Vector2(70, 0)
	lbl.add_theme_font_size_override("font_size", 14)
	hdr.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.item_selected.connect(func(_i): _apply_all_jogs())
	hdr.add_child(opt)
	box.add_child(hdr)
	_node_opt[key] = opt

	var dir_row := HBoxContainer.new()
	var dir_lbl := Label.new()
	dir_lbl.text = "Travels"
	dir_lbl.custom_minimum_size = Vector2(70, 0)
	dir_row.add_child(dir_lbl)
	var dir := OptionButton.new()
	dir.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in AXIS_CHOICES.size():
		dir.add_item(str((AXIS_CHOICES[i] as Dictionary).get("label", "")), i)
	dir.item_selected.connect(func(_i): _apply_all_jogs())
	dir_row.add_child(dir)
	box.add_child(dir_row)
	_dir_opt[key] = dir

	var inv := CheckBox.new()
	inv.text = "Invert"
	inv.toggled.connect(func(_v): _apply_all_jogs())
	box.add_child(inv)
	_invert_chk[key] = inv

	# Min / Max / Home spinboxes (local displacement from GLB rest pose).
	var lim := GridContainer.new()
	lim.columns = 2
	lim.add_theme_constant_override("h_separation", 6)
	lim.add_theme_constant_override("v_separation", 2)
	lim.add_child(_cap("Min"))
	var min_s := _limit_spin()
	min_s.value_changed.connect(func(_v): _on_limit_changed(key))
	lim.add_child(min_s)
	_min_spin[key] = min_s
	lim.add_child(_cap("Max"))
	var max_s := _limit_spin()
	max_s.value_changed.connect(func(_v): _on_limit_changed(key))
	lim.add_child(max_s)
	_max_spin[key] = max_s
	lim.add_child(_cap("Home"))
	var home_s := _limit_spin()
	home_s.value_changed.connect(func(_v): _apply_all_jogs())
	lim.add_child(home_s)
	_home_spin[key] = home_s
	box.add_child(lim)

	var jog_hdr := HBoxContainer.new()
	var jl := Label.new()
	jl.text = "Jog"
	jl.custom_minimum_size = Vector2(40, 0)
	jog_hdr.add_child(jl)
	var jv := Label.new()
	jv.text = "0.00"
	jv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jv.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	jv.add_theme_font_size_override("font_size", 12)
	jv.modulate = Color(0.75, 0.85, 0.95)
	jog_hdr.add_child(jv)
	_jog_lbl[key] = jv
	box.add_child(jog_hdr)

	var jog := HSlider.new()
	jog.min_value = 0.0
	jog.max_value = 1.0
	jog.step = 0.005
	jog.value = 0.0
	jog.value_changed.connect(func(_v): _apply_all_jogs())
	box.add_child(jog)
	_jog_slider[key] = jog

	var set_row := HBoxContainer.new()
	set_row.add_theme_constant_override("separation", 4)
	var bmin := Button.new()
	bmin.text = "Set min"
	bmin.tooltip_text = "Capture the current jog pose as the soft minimum."
	bmin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bmin.pressed.connect(func(): _capture_limit(key, "min"))
	set_row.add_child(bmin)
	var bmax := Button.new()
	bmax.text = "Set max"
	bmax.tooltip_text = "Capture the current jog pose as the soft maximum."
	bmax.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bmax.pressed.connect(func(): _capture_limit(key, "max"))
	set_row.add_child(bmax)
	var bhome := Button.new()
	bhome.text = "Set home"
	bhome.tooltip_text = "Capture the current jog pose as home / origin."
	bhome.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bhome.pressed.connect(func(): _capture_limit(key, "home"))
	set_row.add_child(bhome)
	box.add_child(set_row)

	var sep := HSeparator.new()
	box.add_child(sep)
	return box


func _cap(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(48, 0)
	return l


func _limit_spin() -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = -100000.0
	spin.max_value = 100000.0
	spin.step = 0.01
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.custom_minimum_size = Vector2(110, 0)
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spin


func _rebuild_studio() -> void:
	if _studio != null:
		_studio.queue_free()
	_studio = Node3D.new()
	_viewport.add_child(_studio)

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-42, 40, 0)
	key_light.light_energy = 1.1
	_studio.add_child(key_light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, -135, 0)
	fill.light_energy = 0.3
	_studio.add_child(fill)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.28, 0.30, 0.34)
	gmat.roughness = 0.95
	ground.material_override = gmat
	_studio.add_child(ground)

	_holder = Node3D.new()
	_studio.add_child(_holder)

	_camera = Camera3D.new()
	_camera.fov = 50.0
	_camera.current = true
	_studio.add_child(_camera)

	_model_inst = ModelCatalog.instantiate(_model_id)
	_node_names = PackedStringArray()
	_rest_by_name = {}
	if _model_inst != null:
		var ws := ModelCatalog.resolved_scale(_model_id, 1.0)
		_model_inst.scale = Vector3.ONE * ws
		_holder.add_child(_model_inst)
		for n in _model_inst.find_children("*", "Node3D", true, false):
			var nm := str((n as Node).name)
			if not _rest_by_name.has(nm):
				_node_names.append(nm)
				_rest_by_name[nm] = (n as Node3D).position
		_fit_camera()


func _fit_camera() -> void:
	if _camera == null or _model_inst == null:
		return
	var aabb := AABB()
	var found := false
	for n in _model_inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box := mi.global_transform * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	var center := aabb.get_center() if found else Vector3(0, 1, 0)
	var msize := maxf(aabb.size.length(), 2.0) if found else 4.0
	var dist := clampf(msize * 1.1, 3.0, 200.0)
	_camera.position = center + Vector3(sin(0.7) * dist, msize * 0.4, cos(0.7) * dist)
	_camera.look_at(center)


func _populate_controls() -> void:
	for key: String in CartesianMachineProfile.AXIS_KEYS:
		var opt := _node_opt[key] as OptionButton
		opt.clear()
		opt.add_item("(none)", -1)
		var sel := 0
		var want := _profile.axis_node(key)
		for i in _node_names.size():
			opt.add_item(_node_names[i], i)
			if _node_names[i] == want:
				sel = i + 1
		opt.select(sel)
		(_dir_opt[key] as OptionButton).select(_dir_index_for(key))
		(_invert_chk[key] as CheckBox).button_pressed = _axis_invert(key)
		var lo := _profile.axis_min_local(key)
		var hi := _profile.axis_max_local(key)
		var home := _profile.axis_home_local(key)
		if hi <= lo and not want.is_empty():
			hi = _fallback_travel(want)
			lo = 0.0
			home = 0.0
		(_min_spin[key] as SpinBox).set_value_no_signal(lo)
		(_max_spin[key] as SpinBox).set_value_no_signal(hi)
		(_home_spin[key] as SpinBox).set_value_no_signal(home)
		var span := hi - lo
		var t := 0.0 if span <= 1e-6 else clampf((home - lo) / span, 0.0, 1.0)
		(_jog_slider[key] as HSlider).set_value_no_signal(t)
	# Tool node dropdown.
	_tool_opt.clear()
	_tool_opt.add_item("(none)", -1)
	var tsel := 0
	for i in _node_names.size():
		_tool_opt.add_item(_node_names[i], i)
		if _node_names[i] == _profile.tool_node:
			tsel = i + 1
	_tool_opt.select(tsel)
	_apply_all_jogs()


## Resets every candidate node to its rest position, then applies the current
## jog offset for each mapped axis (nested hierarchy compounds automatically).
func _apply_all_jogs() -> void:
	if _model_inst == null:
		return
	for n in _model_inst.find_children("*", "Node3D", true, false):
		var nm := str((n as Node).name)
		if _rest_by_name.has(nm):
			(n as Node3D).position = _rest_by_name[nm]
	for key: String in CartesianMachineProfile.AXIS_KEYS:
		var node_name := _selected_node(key)
		if node_name.is_empty():
			continue
		var node := _model_inst.find_child(node_name, true, false) as Node3D
		if node == null:
			continue
		var dir := _selected_dir(key)
		if (_invert_chk[key] as CheckBox).button_pressed:
			dir = -dir
		var lo := float((_min_spin[key] as SpinBox).value)
		var hi := float((_max_spin[key] as SpinBox).value)
		var t := float((_jog_slider[key] as HSlider).value)
		var along := lerpf(lo, hi, t)
		node.position = (_rest_by_name[node_name] as Vector3) + dir * along
		var jv := _jog_lbl.get(key) as Label
		if jv != null:
			jv.text = "%.3f  (home %.3f)" % [along, float((_home_spin[key] as SpinBox).value)]


func _on_limit_changed(key: String) -> void:
	# Keep home inside the new min/max window; jog stays as a 0..1 fraction.
	var lo := float((_min_spin[key] as SpinBox).value)
	var hi := float((_max_spin[key] as SpinBox).value)
	var home_s := _home_spin[key] as SpinBox
	if hi > lo:
		home_s.set_value_no_signal(clampf(float(home_s.value), minf(lo, hi), maxf(lo, hi)))
	_apply_all_jogs()


func _capture_limit(key: String, which: String) -> void:
	var lo := float((_min_spin[key] as SpinBox).value)
	var hi := float((_max_spin[key] as SpinBox).value)
	var t := float((_jog_slider[key] as HSlider).value)
	var along := lerpf(lo, hi, t)
	match which:
		"min":
			(_min_spin[key] as SpinBox).set_value_no_signal(along)
			if along > hi:
				(_max_spin[key] as SpinBox).set_value_no_signal(along)
			(_jog_slider[key] as HSlider).set_value_no_signal(0.0)
			_status_lbl.text = "%s min ← %.3f" % [key.to_upper(), along]
		"max":
			(_max_spin[key] as SpinBox).set_value_no_signal(along)
			if along < lo:
				(_min_spin[key] as SpinBox).set_value_no_signal(along)
			(_jog_slider[key] as HSlider).set_value_no_signal(1.0)
			_status_lbl.text = "%s max ← %.3f" % [key.to_upper(), along]
		"home":
			(_home_spin[key] as SpinBox).set_value_no_signal(along)
			_status_lbl.text = "%s home ← %.3f" % [key.to_upper(), along]
	_on_limit_changed(key)


func _selected_node(key: String) -> String:
	var opt := _node_opt[key] as OptionButton
	var id := opt.get_item_id(opt.selected)
	if id < 0 or id >= _node_names.size():
		return ""
	return _node_names[id]


func _axis_invert(key: String) -> bool:
	var a: Variant = _profile.axes.get(key, {})
	return bool((a as Dictionary).get("invert", false)) if a is Dictionary else false


## The AXIS_CHOICES index whose base vector best matches the profile's stored
## (unsigned) travel direction for this axis.
func _dir_index_for(key: String) -> int:
	var base := _base_vec(key).abs()
	var best := 0
	var best_dot := -1.0
	for i in AXIS_CHOICES.size():
		var v: Vector3 = (AXIS_CHOICES[i] as Dictionary).get("vec", Vector3.ZERO)
		var d := base.dot(v)
		if d > best_dot:
			best_dot = d
			best = i
	return best


## The profile's stored raw (base, pre-sign) travel vector for an axis.
func _base_vec(key: String) -> Vector3:
	var a: Variant = _profile.axes.get(key, {})
	if a is Dictionary and (a as Dictionary).has("axis"):
		var v: Variant = (a as Dictionary)["axis"]
		if v is Vector3:
			return v
		if v is Array and (v as Array).size() >= 3:
			return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return CartesianMachineProfile._default_axis_vec(key)


## Currently selected base travel vector for an axis (from the direction dropdown).
func _selected_dir(key: String) -> Vector3:
	var opt := _dir_opt[key] as OptionButton
	var idx := opt.selected if opt != null else 0
	if idx < 0 or idx >= AXIS_CHOICES.size():
		idx = 0
	return (AXIS_CHOICES[idx] as Dictionary).get("vec", Vector3(1, 0, 0))


func _fallback_travel(node_name: String) -> float:
	if _model_inst == null:
		return 1.0
	var node := _model_inst.find_child(node_name, true, false) as Node3D
	if node == null:
		return 1.0
	return CncMachineRuntime._default_travel_for(node)


func _on_auto_detect() -> void:
	var found := CartesianMachineProfile.auto_detect_axes(_model_inst)
	for key: String in CartesianMachineProfile.AXIS_KEYS:
		if not found.has(key):
			continue
		var want := str(found[key])
		var opt := _node_opt[key] as OptionButton
		for i in _node_names.size():
			if _node_names[i] == want:
				opt.select(i + 1)
				break
	_apply_all_jogs()
	_status_lbl.text = "Auto-detected %s" % UiText.count(found.size(), "axis", "axes")


func _on_save() -> void:
	for key: String in CartesianMachineProfile.AXIS_KEYS:
		var node_name := _selected_node(key)
		var dir := _selected_dir(key)
		var lo := float((_min_spin[key] as SpinBox).value)
		var hi := float((_max_spin[key] as SpinBox).value)
		var home := float((_home_spin[key] as SpinBox).value)
		var invert := (_invert_chk[key] as CheckBox).button_pressed
		_profile.set_axis_limits(key, node_name, dir, lo, hi, home, invert)
	var tid := _tool_opt.get_item_id(_tool_opt.selected)
	_profile.tool_node = _node_names[tid] if tid >= 0 and tid < _node_names.size() else ""
	CartesianMachineProfile.save_profile(_profile)
	_reload_placed_runtimes()
	_status_lbl.text = "Saved. Applied to placed machines of this model."


## Live-apply the just-saved profile to any already-placed machine of this model
## (so calibration takes effect without re-placing).
func _reload_placed_runtimes() -> void:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return
	for n in tree.root.find_children("*", "CncMachineRuntime", true, false):
		var rt := n as CncMachineRuntime
		if rt != null and rt.model_id == _model_id and rt.has_method("reload_profile"):
			rt.reload_profile()
