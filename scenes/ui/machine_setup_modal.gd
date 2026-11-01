extends Control

## Machine Setup modal — the generalized axis-tagging UI. Shows the machine model
## in a SubViewport studio and lets the player bind each X/Y/Z axis to a model
## sub-node, flip its direction (invert), set soft min/max travel + home/origin,
## and JOG each axis live to verify the motion before saving. Writes to the shared
## CartesianMachineProfile store (user://machines/profiles.json), so the same
## kinematics engine (CncMachineRuntime) then animates that machine — and any
## other machine the player imports and tags the same way.
##
## On the designer kit, the same layout as the connection ports modal (its
## sibling: that one tags a GLB's ports, this one its axes): the machine and
## its tool on the left, the StudioViewport in the centre, one section per
## axis on the right, Save in the footer.

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
var _shell: DesignerShell = null
var _studio_view: StudioViewport = null
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
	_shell.open()


func close() -> void:
	visible = false
	_shell.close()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shell = DesignerShell.create("Machine setup", "cpu", {
		"name_id": MODAL_NAME, "want": Vector2(1400, 860),
		"left_label": "Machine", "left_w": 240.0, "right_w": 400.0})
	add_child(_shell)
	_shell.closed.connect(close)

	# Left: the machine, its tool, the auto-detect.
	var left := _shell.left
	left.add_child(SectionHeader.make("Machine", "cpu"))
	var hint := Label.new()
	hint.text = "Pick the sub-node for each axis, jog to the rail ends, then Set min and Set max. " \
		+ "Set home for the park pose. Invert flips the direction."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	left.add_child(hint)
	left.add_child(SectionHeader.make("Tool", "", "the node that cuts or prints"))
	_tool_opt = OptionButton.new()
	_tool_opt.name = "tool_node"
	_tool_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tool_opt.fit_to_longest_item = false
	_tool_opt.clip_text = true
	left.add_child(_tool_opt)
	var auto_btn := Button.new()
	auto_btn.text = "Auto-detect axes"
	auto_btn.tooltip_text = "Guess the axis nodes from how the model's parts can move"
	UITheme.style_button(auto_btn)
	auto_btn.pressed.connect(_on_auto_detect)
	left.add_child(auto_btn)
	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status_lbl)

	# Centre: the studio (the kit orbits and zooms it).
	_studio_view = StudioViewport.create({"ground": true, "size": Vector2i(900, 700), "fov": 50.0})
	_studio_view.name = "Studio"
	_studio_view.set_home(0.7, 0.3)
	_shell.centre.add_child(_studio_view)
	_viewport = _studio_view.viewport
	_studio = _studio_view.world
	_holder = _studio_view.holder
	_camera = _studio_view.camera

	# Right: one section per axis.
	for key: String in CartesianMachineProfile.AXIS_KEYS:
		_shell.right.add_child(_build_axis_row(key))

	_shell.set_hint("Drag to orbit · wheel to zoom · jog an axis to see it move · Esc")
	_shell.add_button("Save", DesignerShell.PRIMARY, _on_save,
		"Write the profile and apply it to every placed machine of this model")
	_shell.add_button("Close", DesignerShell.SECONDARY, close)


func _build_axis_row(key: String) -> Control:
	var sec := Collapsible.make("%s axis" % key.to_upper(), true)
	var box := sec.body
	box.add_theme_constant_override("separation", 2)
	var opt := OptionButton.new()
	opt.fit_to_longest_item = false
	opt.clip_text = true
	opt.item_selected.connect(func(_i): _apply_all_jogs())
	box.add_child(FormRow.make("Node", opt, "The model sub-node that slides along this axis", "", "%s_node" % key))
	_node_opt[key] = opt
	var dir := OptionButton.new()
	for i in AXIS_CHOICES.size():
		dir.add_item(str((AXIS_CHOICES[i] as Dictionary).get("label", "")), i)
	dir.item_selected.connect(func(_i): _apply_all_jogs())
	box.add_child(FormRow.make("Travels", dir, "The node's local direction of travel", "", "%s_dir" % key))
	_dir_opt[key] = dir
	var inv := CheckBox.new()
	inv.text = "Flip the direction"
	inv.toggled.connect(func(_v): _apply_all_jogs())
	box.add_child(FormRow.make("Invert", inv, "Flip the direction", "", "%s_invert" % key))
	_invert_chk[key] = inv
	# Min / Max / Home (local displacement from the GLB's rest pose).
	var min_s := _limit_spin()
	min_s.value_changed.connect(func(_v): _on_limit_changed(key))
	box.add_child(FormRow.make("Min", min_s, "Soft minimum, in the model's own units", "", "%s_min" % key))
	_min_spin[key] = min_s
	var max_s := _limit_spin()
	max_s.value_changed.connect(func(_v): _on_limit_changed(key))
	box.add_child(FormRow.make("Max", max_s, "Soft maximum", "", "%s_max" % key))
	_max_spin[key] = max_s
	var home_s := _limit_spin()
	home_s.value_changed.connect(func(_v): _apply_all_jogs())
	box.add_child(FormRow.make("Home", home_s, "The park / origin pose", "", "%s_home" % key))
	_home_spin[key] = home_s
	var jog := FormRow.slider("Jog", 0.0, 1.0, 0.0, 0.005, "",
		func(_v: float) -> void: _apply_all_jogs(), "Slide the axis between its min and max", "%s_jog" % key)
	box.add_child(jog)
	_jog_slider[key] = jog.control as HSlider
	var pos := FormRow.value("Position", "0.00", "Where the node is now (its home in brackets)")
	box.add_child(pos)
	_jog_lbl[key] = pos.control as Label
	var set_row := HBoxContainer.new()
	set_row.add_theme_constant_override("separation", UITheme.SPACE_XS)
	for which: String in ["min", "max", "home"]:
		var b := Button.new()
		b.text = "Set %s" % which
		b.tooltip_text = "Capture the current jog pose as the soft %s" % which if which != "home" \
			else "Capture the current jog pose as home / origin"
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(b)
		var captured := which
		b.pressed.connect(func(): _capture_limit(key, captured))
		set_row.add_child(b)
	box.add_child(set_row)
	return sec





func _limit_spin() -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = -100000.0
	spin.max_value = 100000.0
	spin.step = 0.01
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.select_all_on_focus = true
	return spin


func _rebuild_studio() -> void:
	if _studio_view == null:
		return
	_studio_view.clear()
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
	if _studio_view == null or _model_inst == null:
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
	_studio_view.target = center
	_studio_view.set_orbit(0.7, 0.3, clampf(msize * 1.1, 3.0, 200.0))


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
			jv.text = "%s  (home %s)" % [String.num(along, 2), String.num(float((_home_spin[key] as SpinBox).value), 2)]


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
			_status_lbl.text = "%s min ← %s" % [key.to_upper(), String.num(along, 2)]
		"max":
			(_max_spin[key] as SpinBox).set_value_no_signal(along)
			if along < lo:
				(_min_spin[key] as SpinBox).set_value_no_signal(along)
			(_jog_slider[key] as HSlider).set_value_no_signal(1.0)
			_status_lbl.text = "%s max ← %s" % [key.to_upper(), String.num(along, 2)]
		"home":
			(_home_spin[key] as SpinBox).set_value_no_signal(along)
			_status_lbl.text = "%s home ← %s" % [key.to_upper(), String.num(along, 2)]
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
