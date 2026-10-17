extends Control
## NPC animation editor (fabrication swarm, phase B3): pose and keyframe the
## stick figure, with a tool in its hands, and save the clip the swarm plays.
##
## The studio shows one hi-detail NpcSimpleFigure in an op CONTEXT
## (FabContextRig: a saw crossing a bench, a drill plunging, a driver into a
## post, a beam carried / set down / lifted). The tool follows the op's own
## path (the same LinkageBuildOps timing the swarm uses) and the hands IK to
## its grips, so the author keys the BODY around real tool motion.
##
## Editing:
##   - click a limb to select its joint (or pick it in the joint list);
##   - drag the gizmo rings to rotate it — the value is keyed at the playhead
##     (a key is made when there is none there; only that joint's track moves);
##   - "Body": move arrow (height) + rings (pitch, yaw);
##   - a hand NOT on a tool has an IK handle (the orange ball): drag it and the
##     arm's solution is baked into shoulder + elbow keys;
##   - timeline: click / drag to scrub, keys shown as diamonds (the selected
##     joint's in amber), Space plays, K keys the selected joint, Delete
##     removes it at the playhead, Ctrl+C / Ctrl+V copy and paste the pose,
##     M mirrors it;
##   - right-drag orbits, middle-drag pans, wheel zooms.
## Clips save to user://npc_anims/<id>.json (shipped clips are never
## overwritten; "Revert" deletes the user copy).

signal closed

const MODAL_NAME := "npc_anim_editor"
const SIDEBAR_W := 300
const TIMELINE_H := 96
const TOPBAR_H := 48
const SNAP_DEG := 5.0
const PICK_LIMB_M := 0.07
const IK_HANDLE_R := 0.045

const C_BG := UITheme.C_BG
const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const C_TEXT_M := UITheme.C_TEXT_M
const C_PRIMARY := UITheme.C_PRIMARY
const C_AMBER := UITheme.C_AMBER

var clip: NpcAnimClip = null
var _saved_json := ""          # the clip as last loaded/saved, for "unsaved"
var _t := 0.0
var _playing := false
var _sel := ""                 # joint name, "body", or ""
var _context := "none"
var _rig: Dictionary = {}
var _clipboard: Dictionary = {}
var _onion := false

var _viewport: SubViewport = null
var _vpc: SubViewportContainer = null
var _camera: Camera3D = null
var _studio: Node3D = null
var _figure: NpcSimpleFigure = null
var _ghosts: Array = []        # onion-skin figures [before, after]
var _tool: Node3D = null       # tool or carried part currently shown
var _tool_attached := false    # hanging off the hand (no context)
var _workpieces: Node3D = null
var _gizmo: LightGizmo = null
var _ik_balls: Array = []      # MeshInstance3D per hand
var _yaw := 0.7
var _pitch := 0.18
var _dist := 3.2
var _target := Vector3(0.0, 1.0, 0.2)
var _orbiting := false
var _panning := false
var _drag: Dictionary = {}
## Mouse events the viewport has seen (the harness checks real input lands).
var viewport_events := 0

var _clip_pick: OptionButton = null
var _label_edit: LineEdit = null
var _len_spin: SpinBox = null
var _loop_chk: CheckBox = null
var _feet_opt: OptionButton = null
var _tool_opt: OptionButton = null
var _tool_hand_opt: OptionButton = null
var _ik_opts: Array = []       # [hand_r, hand_l]
var _ctx_opt: OptionButton = null
var _joint_box: VBoxContainer = null
var _joint_btns: Dictionary = {}
var _euler_spins: Array = []
var _euler_lbl: Label = null
var _timeline: Control = null
var _hint: Label = null
var _status: Label = null
var _play_btn: Button = null
var _onion_chk: CheckBox = null
var _confirm: PanelContainer = null
var _suppress := false

const HINT := "Click a limb to select · drag the rings to rotate (Shift snaps 5°) · orange balls drag a free hand by IK · " \
	+ "Space play · K key · Del remove · Ctrl+C / Ctrl+V pose · M mirror · right-drag orbit · wheel zoom"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	visible = false


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Open on a clip id ("" = the first clip; an unknown id starts a new clip).
func open(clip_id: String = "") -> void:
	_refresh_clip_list()
	var ids := NpcAnimClip.list_ids()
	var id := clip_id if not clip_id.is_empty() else (str(ids[0]) if not ids.is_empty() else "")
	_load_clip(id)
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "request_close"))
	HudLayout.claim_modal(MODAL_NAME)


## Close, asking first when there are unsaved changes.
func request_close() -> void:
	if is_dirty():
		_show_confirm()
		return
	close()


func close() -> void:
	if not visible:
		return
	_playing = false
	visible = false
	if _confirm != null:
		_confirm.visible = false
	CursorController.release_modal(MODAL_NAME)
	HudLayout.release(MODAL_NAME)
	closed.emit()


func is_dirty() -> bool:
	return clip != null and JSON.stringify(clip.to_dict()) != _saved_json


func playhead() -> float:
	return _t


func set_playhead(t: float) -> void:
	_t = clampf(t, 0.0, clip.length_s if clip != null else 1.0)
	_refresh_inspector()
	if _timeline != null:
		_timeline.queue_redraw()


func select_joint(name: String) -> void:
	_sel = name
	for k in _joint_btns:
		UITheme.style_toggle(_joint_btns[k], k == name)
	_refresh_inspector()
	if _timeline != null:
		_timeline.queue_redraw()


func selected_joint() -> String:
	return _sel


func set_context(kind: String) -> void:
	_context = kind if kind in FabContextRig.KINDS else "none"
	if _ctx_opt != null:
		_ctx_opt.select(FabContextRig.KINDS.find(_context))
	_rebuild_context()


## Save the clip to the user library; returns the path.
func save() -> String:
	if clip == null:
		return ""
	if clip.id.is_empty():
		clip.id = _slug(clip.label)
	var path := NpcAnimClip.save_user(clip)
	if not path.is_empty():
		_saved_json = JSON.stringify(clip.to_dict())
		_refresh_clip_list()
		_set_status("Saved %s" % path.get_file())
	return path


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(C_BG.r, C_BG.g, C_BG.b, 0.96)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	root.add_child(_build_topbar())
	var main := HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 0)
	root.add_child(main)
	main.add_child(_build_sidebar())
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.add_theme_constant_override("separation", 0)
	main.add_child(center)
	center.add_child(_build_viewport())
	center.add_child(_build_timeline())
	_build_confirm()


func _build_topbar() -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	wrap.custom_minimum_size.y = TOPBAR_H
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	wrap.add_child(bar)
	var title := Label.new()
	title.text = "🎬  NPC ANIMATION"
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	bar.add_child(title)
	_clip_pick = OptionButton.new()
	_clip_pick.custom_minimum_size.x = 200
	_clip_pick.item_selected.connect(func(i: int) -> void:
		if not _suppress:
			_load_clip(_clip_pick.get_item_text(i)))
	bar.add_child(_clip_pick)
	for spec in [["New", _on_new], ["Duplicate", _on_duplicate], ["Save", func(): save()],
			["Revert", _on_revert]]:
		var b := Button.new()
		b.text = spec[0]
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		b.pressed.connect(spec[1])
		bar.add_child(b)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_status = Label.new()
	_status.add_theme_color_override("font_color", C_TEXT_S)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	bar.add_child(_status)
	var close_btn := IconButton.close(request_close)
	bar.add_child(close_btn)
	return wrap


func _row(parent: Control, label: String, control: Control) -> void:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 92
	l.add_theme_color_override("font_color", C_TEXT_S)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	r.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(control)
	parent.add_child(r)


func _section_label(parent: Control, text: String) -> void:
	parent.add_child(SectionHeader.make(text))


func _build_sidebar() -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	wrap.custom_minimum_size.x = SIDEBAR_W
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	wrap.add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", UITheme.SPACE_SM)
	scroll.add_child(v)

	_section_label(v, "Clip")
	_label_edit = LineEdit.new()
	_label_edit.text_changed.connect(func(s: String) -> void:
		if clip != null and not _suppress:
			clip.label = s)
	_row(v, "Label", _label_edit)
	_len_spin = SpinBox.new()
	_len_spin.min_value = 0.1
	_len_spin.max_value = 30.0
	_len_spin.step = 0.05
	_len_spin.suffix = "s"
	_len_spin.value_changed.connect(func(val: float) -> void:
		if clip != null and not _suppress:
			clip.length_s = val
			_t = minf(_t, val)
			_timeline.queue_redraw())
	_row(v, "Length", _len_spin)
	_loop_chk = CheckBox.new()
	_loop_chk.text = "Loop"
	_loop_chk.toggled.connect(func(on: bool) -> void:
		if clip != null and not _suppress:
			clip.loop = on)
	v.add_child(_loop_chk)
	_feet_opt = OptionButton.new()
	_feet_opt.add_item("keyed")
	_feet_opt.add_item("planted")
	_feet_opt.item_selected.connect(func(i: int) -> void:
		if clip != null and not _suppress:
			clip.feet = "planted" if i == 1 else "keyed")
	_row(v, "Feet", _feet_opt)

	_section_label(v, "Tool")
	_tool_opt = OptionButton.new()
	_tool_opt.add_item("(none)")
	for id in FabToolCatalog.ids():
		_tool_opt.add_item(str(id))
	_tool_opt.item_selected.connect(func(i: int) -> void:
		if clip == null or _suppress:
			return
		if i == 0:
			clip.tool = {}
		else:
			clip.tool = {"id": _tool_opt.get_item_text(i), "hand": str(clip.tool.get("hand", "r"))}
		_rebuild_context())
	_row(v, "Tool", _tool_opt)
	_tool_hand_opt = OptionButton.new()
	_tool_hand_opt.add_item("right")
	_tool_hand_opt.add_item("left")
	_tool_hand_opt.item_selected.connect(func(i: int) -> void:
		if clip != null and not _suppress and not clip.tool.is_empty():
			clip.tool["hand"] = "l" if i == 1 else "r"
			_rebuild_context())
	_row(v, "In hand", _tool_hand_opt)
	for pair in [["hand_r", "Right hand"], ["hand_l", "Left hand"]]:
		var o := OptionButton.new()
		for s in ["none", "grip", "grip2"]:
			o.add_item(s)
		var key: String = pair[0]
		o.item_selected.connect(func(i: int) -> void:
			if clip != null and not _suppress:
				clip.ik[key] = o.get_item_text(i))
		o.tooltip_text = "Which socket of the tool (or carried part) this hand reaches for by IK. none = the keyed arm."
		_row(v, pair[1], o)
		_ik_opts.append(o)
	_ctx_opt = OptionButton.new()
	for k in FabContextRig.KINDS:
		_ctx_opt.add_item(str(k))
	_ctx_opt.tooltip_text = "Play the clip against an operation: the tool (or the carried beam) follows the op's own path, the same timing the build swarm uses."
	_ctx_opt.item_selected.connect(func(i: int) -> void:
		if not _suppress:
			set_context(_ctx_opt.get_item_text(i)))
	_row(v, "Context", _ctx_opt)

	_section_label(v, "Joints")
	_joint_box = VBoxContainer.new()
	_joint_box.add_theme_constant_override("separation", 2)
	v.add_child(_joint_box)
	var grid := GridContainer.new()
	grid.columns = 3
	_joint_box.add_child(grid)
	for name in ["body"] + NpcAnimClip.JOINTS:
		var b := Button.new()
		# "shoulder_r" -> "Shoulder R": the joint's id stays in the tooltip.
		var words := str(name).split("_")
		for i in words.size():
			words[i] = words[i].to_upper() if words[i].length() == 1 else words[i].capitalize()
		b.text = " ".join(words)
		b.tooltip_text = "Select the %s joint (%s)" % [b.text.to_lower(), str(name)]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(88, 26)
		UITheme.style_toggle(b, false)
		var jn: String = name
		b.pressed.connect(func() -> void: select_joint(jn))
		grid.add_child(b)
		_joint_btns[jn] = b
	_euler_lbl = Label.new()
	_euler_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_euler_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	v.add_child(_euler_lbl)
	var eh := HBoxContainer.new()
	for i in 3:
		var sp := SpinBox.new()
		sp.min_value = -360.0
		sp.max_value = 360.0
		sp.step = 0.5
		sp.custom_minimum_size.x = 86
		sp.tooltip_text = ["X (pitch)", "Y (yaw)", "Z (roll)"][i] + " in degrees, keyed at the playhead. Body: height (m), pitch, yaw."
		var idx := i
		sp.value_changed.connect(func(val: float) -> void: _on_euler_edited(idx, val))
		eh.add_child(sp)
		_euler_spins.append(sp)
	v.add_child(eh)
	return wrap


func _build_viewport() -> Control:
	var vpc := SubViewportContainer.new()
	vpc.stretch = true
	vpc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc.gui_input.connect(_on_viewport_input)
	_vpc = vpc
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(900, 640)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	vpc.add_child(_viewport)
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.11, 0.13, 0.17)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.85)
	e.ambient_light_energy = 0.7
	env.environment = e
	_studio.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	sun.light_energy = 1.2
	_studio.add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(8, 8)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.3, 0.3, 0.33)
	floor_mi.material_override = fm
	_studio.add_child(floor_mi)
	_workpieces = Node3D.new()
	_workpieces.name = "Workpieces"
	_studio.add_child(_workpieces)
	_figure = NpcSimpleFigure.new()
	_figure.hi_detail = true
	_figure.name = "Figure"
	_studio.add_child(_figure)
	_figure.setup("anim_editor", Color(0.55, 0.75, 0.95))
	for k in 2:
		var g := NpcSimpleFigure.new()
		g.name = "Onion%d" % k
		_studio.add_child(g)
		g.setup("anim_editor_onion", Color(0.4, 0.4, 0.45))
		g.visible = false
		_ghosts.append(g)
	for i in 2:
		var ball := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = IK_HANDLE_R
		sm.height = IK_HANDLE_R * 2.0
		ball.mesh = sm
		var bm := StandardMaterial3D.new()
		bm.albedo_color = Color(1.0, 0.55, 0.15, 0.85)
		bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		bm.no_depth_test = true
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ball.material_override = bm
		ball.visible = false
		_studio.add_child(ball)
		_ik_balls.append(ball)
	_gizmo = LightGizmo.new()
	_gizmo.world_space = false
	_gizmo.size_mult = 0.7
	_studio.add_child(_gizmo)
	_camera = Camera3D.new()
	_camera.near = 0.02
	_camera.far = 100.0
	_camera.fov = 45.0
	_studio.add_child(_camera)
	_update_camera()
	var overlay := VBoxContainer.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint = Label.new()
	_hint.text = HINT
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", C_TEXT_M)
	_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	overlay.add_child(_hint)
	vpc.add_child(overlay)
	return vpc


func _build_timeline() -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	wrap.custom_minimum_size.y = TIMELINE_H
	var v := VBoxContainer.new()
	wrap.add_child(v)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	v.add_child(bar)
	_play_btn = Button.new()
	_play_btn.text = "▶"
	_play_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(_toggle_play)
	bar.add_child(_play_btn)
	# Plain glyphs: the UI font has no media-control symbols.
	for spec in [["|◀", func(): _step_key(-1)], ["▶|", func(): _step_key(1)],
			["◆ Key", _key_selected], ["✕ Key", _delete_key], ["Copy", _copy_pose],
			["Paste", _paste_pose], ["Mirror", _mirror_pose]]:
		var b := Button.new()
		b.text = spec[0]
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		b.pressed.connect(spec[1])
		bar.add_child(b)
	_onion_chk = CheckBox.new()
	_onion_chk.text = "Onion skin"
	_onion_chk.focus_mode = Control.FOCUS_NONE
	_onion_chk.toggled.connect(func(on: bool) -> void: _onion = on)
	bar.add_child(_onion_chk)
	_timeline = Control.new()
	_timeline.custom_minimum_size.y = 46
	_timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline.mouse_filter = Control.MOUSE_FILTER_STOP
	_timeline.draw.connect(_draw_timeline)
	_timeline.gui_input.connect(_on_timeline_input)
	v.add_child(_timeline)
	return wrap


func _build_confirm() -> void:
	_confirm = PanelContainer.new()
	_confirm.add_theme_stylebox_override("panel", UITheme.card_style())
	_confirm.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_confirm.visible = false
	var v := VBoxContainer.new()
	_confirm.add_child(v)
	var l := Label.new()
	l.text = "This clip has unsaved changes."
	l.add_theme_color_override("font_color", C_TEXT)
	v.add_child(l)
	var h := HBoxContainer.new()
	v.add_child(h)
	for spec in [["Save", func(): save(); close()], ["Discard", close],
			["Cancel", func(): _confirm.visible = false]]:
		var b := Button.new()
		b.text = spec[0]
		UITheme.style_button(b)
		b.pressed.connect(spec[1])
		h.add_child(b)
	add_child(_confirm)


func _show_confirm() -> void:
	_confirm.visible = true
	_confirm.position = (size - _confirm.get_combined_minimum_size()) / 2.0


# ---------------------------------------------------------------------------
# Clips
# ---------------------------------------------------------------------------

func _refresh_clip_list() -> void:
	_suppress = true
	_clip_pick.clear()
	var ids := NpcAnimClip.list_ids()
	for id in ids:
		_clip_pick.add_item(str(id))
	if clip != null:
		if not ids.has(clip.id):
			# A new / duplicated clip not saved yet: list it so the picker
			# never names a different clip than the one being edited.
			_clip_pick.add_item(clip.id)
			_clip_pick.set_item_tooltip(_clip_pick.item_count - 1, "Not saved yet")
		for i in _clip_pick.item_count:
			if _clip_pick.get_item_text(i) == clip.id:
				_clip_pick.select(i)
	_suppress = false


func _load_clip(id: String) -> void:
	var c := NpcAnimClip.load_clip(id) if not id.is_empty() else null
	if c == null:
		c = NpcAnimClip.from_dict({"id": id if not id.is_empty() else "new_clip", "label": "New clip",
			"length_s": 1.0, "loop": true, "keys": []})
	clip = c
	_saved_json = JSON.stringify(clip.to_dict())
	_t = 0.0
	_playing = false
	# The clip's natural context: its op, else none.
	var ctx := "none"
	for k in FabContextRig.CLIP_FOR:
		if FabContextRig.CLIP_FOR[k] == clip.id:
			ctx = k
	_context = ctx
	_sync_clip_widgets()
	_rebuild_context()
	select_joint("")
	_set_status("Loaded %s" % clip.id)


func _sync_clip_widgets() -> void:
	_suppress = true
	_refresh_clip_list()
	_label_edit.text = clip.label
	_len_spin.value = clip.length_s
	_loop_chk.button_pressed = clip.loop
	_feet_opt.select(1 if clip.feet == "planted" else 0)
	var ti := 0
	if not clip.tool.is_empty():
		for i in _tool_opt.item_count:
			if _tool_opt.get_item_text(i) == str(clip.tool.get("id", "")):
				ti = i
	_tool_opt.select(ti)
	_tool_hand_opt.select(1 if str(clip.tool.get("hand", "r")) == "l" else 0)
	for i in 2:
		var key := "hand_r" if i == 0 else "hand_l"
		(_ik_opts[i] as OptionButton).select(["none", "grip", "grip2"].find(str(clip.ik.get(key, "none"))))
	_ctx_opt.select(FabContextRig.KINDS.find(_context))
	_suppress = false
	_timeline.queue_redraw()


func _on_new() -> void:
	var n := 1
	while NpcAnimClip.list_ids().has("new_clip_%d" % n):
		n += 1
	clip = NpcAnimClip.from_dict({"id": "new_clip_%d" % n, "label": "New clip %d" % n,
		"length_s": 1.0, "loop": true, "keys": []})
	_saved_json = ""
	_t = 0.0
	_context = "none"
	_sync_clip_widgets()
	_rebuild_context()
	_set_status("New clip — key a joint to begin")


func _on_duplicate() -> void:
	if clip == null:
		return
	var c := clip.duplicate_clip()
	c.id = clip.id + "_copy"
	c.label = clip.label + " (copy)"
	clip = c
	_saved_json = ""
	_sync_clip_widgets()
	_set_status("Duplicated as %s (unsaved)" % c.id)


## Revert to the shipped clip: delete the user copy and reload.
func _on_revert() -> void:
	if clip == null:
		return
	var path := NpcAnimClip.USER_DIR + clip.id + ".json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_load_clip(clip.id)
	_set_status("Reverted %s" % clip.id)


static func _slug(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	return out.strip_edges() if not out.is_empty() else "clip"


func _set_status(s: String) -> void:
	if _status != null:
		_status.text = s + ("   • unsaved" if is_dirty() else "")


# ---------------------------------------------------------------------------
# Context (tool + workpieces)
# ---------------------------------------------------------------------------

func _rebuild_context() -> void:
	for c in _workpieces.get_children():
		c.queue_free()
	if _tool != null:
		if _tool_attached:
			for i in 2:
				_figure.detach_tool(i)
		_tool.queue_free()
		_tool = null
	_tool_attached = false
	_rig = FabContextRig.setup(_context) if _context != "none" else {}
	for wp in _rig.get("workpieces", []):
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = wp["size"]
		mi.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = wp["color"]
		mi.material_override = m
		mi.transform = wp["xform"]
		_workpieces.add_child(mi)
	var tool_id := str(_rig.get("tool_id", "")) if not _rig.is_empty() else str(clip.tool.get("id", "")) if clip != null else ""
	if _context in ["place", "carry", "lift"]:
		_tool = _beam_part()
	elif not tool_id.is_empty():
		_tool = FabToolCatalog.build(tool_id)
	if _tool == null:
		return
	if _rig.is_empty():
		# No context: the tool hangs off its hand (a carried tool).
		var hand := 1 if str(clip.tool.get("hand", "r")) == "l" else 0
		_figure.attach_tool(hand, _tool)
		_tool_attached = true
	else:
		_studio.add_child(_tool)


func _beam_part() -> Node3D:
	var root3 := Node3D.new()
	root3.name = "Beam"
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(1.4, 0.089, 0.038)
	mi.mesh = b
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.86, 0.7, 0.5)
	mi.material_override = m
	root3.add_child(mi)
	root3.set_meta("sockets", FabContextRig.beam_sockets())
	return root3


# ---------------------------------------------------------------------------
# Per frame
# ---------------------------------------------------------------------------

func _process(dt: float) -> void:
	if not visible or clip == null:
		return
	if _playing:
		_t += dt
		if _t > clip.length_s:
			_t = fposmod(_t, clip.length_s) if clip.loop else clip.length_s
			if not clip.loop:
				_playing = false
				_play_btn.text = "▶"
		_timeline.queue_redraw()
	_apply_pose(_figure, _t)
	if _onion:
		var step := minf(0.15, clip.length_s * 0.15)
		for k in 2:
			var g: NpcSimpleFigure = _ghosts[k]
			g.visible = true
			_apply_pose(g, _t + (-step if k == 0 else step), false)
	else:
		for g in _ghosts:
			(g as Node3D).visible = false
	_update_gizmo()


## Pose one figure at clip time t: the tool / carried part along its op path,
## hands IK'd to its sockets, the clip over a still procedural idle.
func _apply_pose(fig: NpcSimpleFigure, t: float, drive_tool: bool = true) -> void:
	var tl := clip.length_s
	var u := clampf(t / tl, 0.0, 1.0) if tl > 0.0 else 0.0
	var tool_xf := Transform3D()
	var in_context := _tool != null and not _rig.is_empty()
	if in_context:
		# Where the tool is at THIS figure's time (an onion ghost's differs);
		# only the live figure moves the real tool.
		var tp := FabContextRig.tool_at(_rig, u)
		tool_xf = tp["xform"]
		if drive_tool:
			_tool.global_transform = tool_xf
			FabToolCatalog.set_spin(_tool, float(tp["spin"]))
	fig.set_clip(clip, t, 1.0)
	var sockets: Dictionary = _tool.get_meta("sockets", {}) if in_context else {}
	for i in 2:
		var sock := str(clip.ik.get("hand_r" if i == 0 else "hand_l", "none"))
		if sock != "none" and sockets.get(sock) is Transform3D:
			fig.set_hand_target(i, tool_xf * (sockets[sock] as Transform3D))
		else:
			fig.set_hand_target(i, null)
	fig.pose("idle", 0.0, 1.0 / 60.0)


## A hand is FREE (keyed, draggable by its IK ball) unless the context puts
## it on a tool / carried-part socket.
func _hand_free(i: int) -> bool:
	if _tool == null or _rig.is_empty():
		return true
	var sock := str(clip.ik.get("hand_r" if i == 0 else "hand_l", "none"))
	return sock == "none" or not (_tool.get_meta("sockets", {}) as Dictionary).has(sock)


func _update_gizmo() -> void:
	var node := _sel_node()
	if node == null:
		_gizmo.hide_gizmo()
	else:
		_gizmo.show_move = _sel == "body"
		_gizmo.show_rotate = true
		_gizmo.set_target(node.global_position + (Vector3(0, 0.9, 0) if _sel == "body" else Vector3.ZERO),
			node.global_basis, _camera)
	for i in 2:
		var ball: MeshInstance3D = _ik_balls[i]
		ball.visible = _hand_free(i)
		if ball.visible:
			ball.global_position = _figure.palm_global(i).origin


func _sel_node() -> Node3D:
	if _sel.is_empty():
		return null
	if _sel == "body":
		return _figure.get_node_or_null("Body") as Node3D
	return _figure.joint_map().get(_sel) as Node3D


# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

## The selected joint's current LOCAL rotation, Euler degrees (what is keyed).
func _joint_euler(name: String) -> Vector3:
	var n: Node3D = _figure.joint_map().get(name)
	if n == null:
		return Vector3.ZERO
	var e := n.basis.orthonormalized().get_euler()
	return Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))


func _key_joint_basis(name: String, local: Basis) -> void:
	var e := local.orthonormalized().get_euler()
	clip.set_joint_at(_t, name, Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)))
	_after_edit()


func _after_edit() -> void:
	_timeline.queue_redraw()
	_refresh_inspector()
	_set_status("Edited %s" % clip.id)


func _key_selected() -> void:
	if clip == null or _sel.is_empty():
		return
	if _sel == "body":
		var b := _figure.get_node("Body") as Node3D
		clip.set_body_at(_t, "y", b.position.y)
		clip.set_body_at(_t, "pitch", rad_to_deg(b.rotation.x))
		clip.set_body_at(_t, "yaw", rad_to_deg(b.rotation.y))
	else:
		clip.set_joint_at(_t, _sel, _joint_euler(_sel))
	_after_edit()


func _delete_key() -> void:
	if clip == null:
		return
	if clip.remove_at(_t, "" if _sel.is_empty() or _sel == "body" else _sel):
		_after_edit()


func _copy_pose() -> void:
	if clip != null:
		_clipboard = clip.pose_at(_t)
		_set_status("Copied the pose at %.2f s" % _t)


func _paste_pose() -> void:
	if clip != null and not _clipboard.is_empty():
		clip.paste_pose(_t, _clipboard)
		_after_edit()


func _mirror_pose() -> void:
	if clip != null:
		clip.paste_pose(_t, NpcAnimClip.mirror_pose(clip.pose_at(_t)))
		_after_edit()


func _step_key(dir: int) -> void:
	if clip == null:
		return
	var times := clip.key_times("" if _sel.is_empty() or _sel == "body" else _sel)
	var best := _t
	if dir > 0:
		for kt in times:
			if float(kt) > _t + 1e-4:
				best = float(kt)
				break
	else:
		for i in range(times.size() - 1, -1, -1):
			if float(times[i]) < _t - 1e-4:
				best = float(times[i])
				break
	set_playhead(best)


func _toggle_play() -> void:
	_playing = not _playing
	_play_btn.text = "⏸" if _playing else "▶"


func _refresh_inspector() -> void:
	if _euler_lbl == null or clip == null:
		return
	_suppress = true
	if _sel.is_empty():
		_euler_lbl.text = "Select a joint (click a limb or a button above)."
		for sp in _euler_spins:
			(sp as SpinBox).editable = false
	elif _sel == "body":
		var b := _figure.get_node("Body") as Node3D
		_euler_lbl.text = "Body: height (m), pitch, yaw (°) at %.2f s" % _t
		var vals := [b.position.y, rad_to_deg(b.rotation.x), rad_to_deg(b.rotation.y)]
		for i in 3:
			(_euler_spins[i] as SpinBox).editable = true
			(_euler_spins[i] as SpinBox).step = 0.005 if i == 0 else 0.5
			(_euler_spins[i] as SpinBox).value = vals[i]
	else:
		var keyed := clip.key_times(_sel).any(func(kt): return absf(float(kt) - _t) <= NpcAnimClip.KEY_TOL_S)
		_euler_lbl.text = "%s at %.2f s%s" % [_sel, _t, "  ◆ keyed" if keyed else ""]
		var ev := _joint_euler(_sel)
		for i in 3:
			(_euler_spins[i] as SpinBox).editable = true
			(_euler_spins[i] as SpinBox).step = 0.5
			(_euler_spins[i] as SpinBox).value = [ev.x, ev.y, ev.z][i]
	_suppress = false


func _on_euler_edited(idx: int, val: float) -> void:
	if _suppress or clip == null or _sel.is_empty():
		return
	if _sel == "body":
		clip.set_body_at(_t, ["y", "pitch", "yaw"][idx], val)
	else:
		var ev := _joint_euler(_sel)
		ev[idx] = val
		clip.set_joint_at(_t, _sel, ev)
	_after_edit()


# ---------------------------------------------------------------------------
# Timeline
# ---------------------------------------------------------------------------

const TL_PAD := 14.0


func _t_to_x(t: float) -> float:
	var w := _timeline.size.x - TL_PAD * 2.0
	return TL_PAD + (t / maxf(clip.length_s, 1e-3)) * w


func _x_to_t(x: float) -> float:
	var w := maxf(_timeline.size.x - TL_PAD * 2.0, 1.0)
	return clampf((x - TL_PAD) / w * clip.length_s, 0.0, clip.length_s)


func _draw_timeline() -> void:
	if clip == null:
		return
	var h := _timeline.size.y
	_timeline.draw_rect(Rect2(Vector2.ZERO, _timeline.size), Color(0.06, 0.08, 0.12))
	var n := int(ceil(clip.length_s / 0.1))
	for i in n + 1:
		var tt := minf(i * 0.1, clip.length_s)
		var x := _t_to_x(tt)
		var major := i % 10 == 0
		_timeline.draw_line(Vector2(x, 0), Vector2(x, h * (0.35 if major else 0.18)), C_TEXT_M, 1.0)
		if major:
			_timeline.draw_string(get_theme_default_font(), Vector2(x + 2, 12), "%.0fs" % tt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, C_TEXT_M)
	var sel_times := clip.key_times(_sel) if not _sel.is_empty() and _sel != "body" else []
	for kt in clip.key_times():
		var x2 := _t_to_x(float(kt))
		var c := C_AMBER if sel_times.has(kt) else C_TEXT_S
		var y := h * 0.65
		var d := 6.0
		_timeline.draw_colored_polygon(PackedVector2Array([Vector2(x2, y - d), Vector2(x2 + d, y),
			Vector2(x2, y + d), Vector2(x2 - d, y)]), c)
	var xp := _t_to_x(_t)
	_timeline.draw_line(Vector2(xp, 0), Vector2(xp, h), C_PRIMARY, 2.0)


func _on_timeline_input(e: InputEvent) -> void:
	if clip == null:
		return
	var mb := e as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		# Snap to a key diamond under the click.
		var t := _x_to_t(mb.position.x)
		for kt in clip.key_times():
			if absf(_t_to_x(float(kt)) - mb.position.x) <= 7.0:
				t = float(kt)
		set_playhead(t)
		_timeline.accept_event()
	var mm := e as InputEventMouseMotion
	if mm != null and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		set_playhead(_x_to_t(mm.position.x))
		_timeline.accept_event()


# ---------------------------------------------------------------------------
# Viewport input: orbit / pan / zoom, joint picking, gizmo + IK drags
# ---------------------------------------------------------------------------

## The studio root sits at the origin, so the camera's LOCAL transform is its
## world one — set without needing the tree (it is built before it is in it).
func _update_camera() -> void:
	var dir := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch))
	var pos := _target + dir * _dist
	_camera.transform = Transform3D(Basis.looking_at(_target - pos, Vector3.UP), pos)


func _ray(pos: Vector2) -> Array:
	return [_camera.project_ray_origin(pos), _camera.project_ray_normal(pos)]


func _on_viewport_input(e: InputEvent) -> void:
	viewport_events += 1
	var mb := e as InputEventMouseButton
	if mb != null:
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_dist = maxf(0.6, _dist * 0.9)
					_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_dist = minf(12.0, _dist / 0.9)
					_update_camera()
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_press(mb.position, mb.shift_pressed)
				else:
					_release()
		_vpc.accept_event()
		return
	var mm := e as InputEventMouseMotion
	if mm == null:
		return
	if _orbiting:
		_yaw -= mm.relative.x * 0.008
		_pitch = clampf(_pitch + mm.relative.y * 0.006, -1.2, 1.4)
		_update_camera()
	elif _panning:
		var right := _camera.global_basis.x
		var up := _camera.global_basis.y
		_target += (-right * mm.relative.x + up * mm.relative.y) * _dist * 0.0016
		_update_camera()
	elif not _drag.is_empty():
		_drag_to(mm.position, mm.shift_pressed)
	else:
		var r := _ray(mm.position)
		_gizmo.set_hot(_gizmo.pick(r[0], r[1]))
	_vpc.accept_event()


func _press(pos: Vector2, shift: bool) -> void:
	var r := _ray(pos)
	var ro: Vector3 = r[0]
	var rd: Vector3 = r[1]
	# 1. A gizmo handle on the selected joint.
	var h := _gizmo.pick(ro, rd)
	var node := _sel_node()
	if not h.is_empty() and node != null:
		var o := _gizmo.global_position
		if h.begins_with("r"):
			var n := _gizmo.axis(h)
			var hit = LightGizmoMath.ray_plane(ro, rd, o, n)
			if hit == null:
				return
			_drag = {"kind": "ring", "axis": n, "origin": o, "ref": (hit as Vector3) - o,
				"start": node.global_basis.orthonormalized(),
				"parent": (node.get_parent() as Node3D).global_basis.orthonormalized(),
				"start_rot": node.rotation}
		elif h == "y" and _sel == "body":
			_drag = {"kind": "lift", "origin": o, "axis": Vector3.UP,
				"start_param": LightGizmoMath.axis_param(ro, rd, o, Vector3.UP),
				"start_y": (node as Node3D).position.y}
		return
	# 2. An IK ball on a free hand.
	for i in 2:
		var ball: MeshInstance3D = _ik_balls[i]
		if ball.visible and float(LightGizmoMath.ray_point(ro, rd, ball.global_position)["dist"]) < IK_HANDLE_R * 1.6:
			_drag = {"kind": "ik", "hand": i, "plane_o": ball.global_position,
				"plane_n": -_camera.global_basis.z}
			select_joint("shoulder_r" if i == 0 else "shoulder_l")
			return
	# 3. A limb.
	var picked := pick_joint(ro, rd)
	select_joint(picked)


func _release() -> void:
	if not _drag.is_empty():
		_drag = {}
		_after_edit()


func _drag_to(pos: Vector2, shift: bool) -> void:
	var r := _ray(pos)
	var ro: Vector3 = r[0]
	var rd: Vector3 = r[1]
	match str(_drag.get("kind", "")):
		"ring":
			var n: Vector3 = _drag["axis"]
			var o: Vector3 = _drag["origin"]
			var hit = LightGizmoMath.ray_plane(ro, rd, o, n)
			if hit == null:
				return
			var ang := LightGizmoMath.ring_angle(hit, o, n, _drag["ref"])
			if shift:
				ang = deg_to_rad(LightGizmoMath.snap(rad_to_deg(ang), SNAP_DEG))
			if _sel == "body":
				var b := _figure.get_node("Body") as Node3D
				var r0: Vector3 = _drag["start_rot"]
				# Body: the X ring is pitch, the Y ring is yaw.
				var ax := _gizmo.axis("rx")
				if n.dot(ax) > 0.9 or n.dot(ax) < -0.9:
					clip.set_body_at(_t, "pitch", rad_to_deg(r0.x + ang * signf(n.dot(ax))))
				else:
					clip.set_body_at(_t, "yaw", rad_to_deg(r0.y + ang))
				_after_edit()
				return
			var new_global := Basis(n, ang) * (_drag["start"] as Basis)
			var local := (_drag["parent"] as Basis).inverse() * new_global
			_key_joint_basis(_sel, local)
		"lift":
			var p := LightGizmoMath.axis_param(ro, rd, _drag["origin"], Vector3.UP)
			clip.set_body_at(_t, "y", float(_drag["start_y"]) + (p - float(_drag["start_param"])))
			_after_edit()
		"ik":
			var hit2 = LightGizmoMath.ray_plane(ro, rd, _drag["plane_o"], _drag["plane_n"])
			if hit2 == null:
				return
			bake_hand_ik(int(_drag["hand"]), hit2 as Vector3)


## Solve hand i's arm so its PALM reaches `palm_world`, and key the solution
## into the shoulder + elbow tracks at the playhead (IK baked to FK).
func bake_hand_ik(i: int, palm_world: Vector3) -> void:
	var sfx := "_r" if i == 0 else "_l"
	var jm := _figure.joint_map()
	var torso: Node3D = jm["torso"]
	var sh: Node3D = jm["shoulder" + sfx]
	# The palm hangs PALM_OFFSET below the wrist in the wrist's own frame.
	var wb := (jm["wrist" + sfx] as Node3D).global_basis.orthonormalized()
	var wrist_world := palm_world - wb * NpcSimpleFigure.PALM_OFFSET
	var inv := torso.global_transform.affine_inverse()
	var side := -1.0 if i == 0 else 1.0
	var root := sh.position
	var pole := root + Vector3(0.35 * side, -0.25, -0.55)
	var sol := NpcLimbIk.solve(root, inv * wrist_world, pole, NpcSimpleFigure.UPPER_ARM, NpcSimpleFigure.FOREARM, -1.0)
	var e := (sol["root_basis"] as Basis).get_euler()
	clip.set_joint_at(_t, "shoulder" + sfx, Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)))
	clip.set_joint_at(_t, "elbow" + sfx, Vector3(rad_to_deg(float(sol["mid_angle"])), 0.0, 0.0))
	_after_edit()


## The joint whose limb the ray passes closest to (within PICK_LIMB_M), or "".
func pick_joint(ro: Vector3, rd: Vector3) -> String:
	var jm := _figure.joint_map()
	var segs := {}
	for i in 2:
		var sfx := "_r" if i == 0 else "_l"
		segs["shoulder" + sfx] = [jm["shoulder" + sfx], jm["elbow" + sfx]]
		segs["elbow" + sfx] = [jm["elbow" + sfx], jm["wrist" + sfx]]
		segs["hip" + sfx] = [jm["hip" + sfx], jm["knee" + sfx]]
	var best := ""
	var best_d := PICK_LIMB_M
	for name in segs:
		var a: Vector3 = (segs[name][0] as Node3D).global_position
		var b: Vector3 = (segs[name][1] as Node3D).global_position
		var d := float(LightGizmoMath.ray_segment(ro, rd, a, b)["dist"])
		if d < best_d:
			best_d = d
			best = name
	# Ends with no child pivot: forearm tip -> wrist, shin -> knee, torso, head.
	var extra := {}
	for i in 2:
		var sfx := "_r" if i == 0 else "_l"
		var kn: Node3D = jm["knee" + sfx]
		extra["knee" + sfx] = [kn.global_position, kn.global_transform * Vector3(0, -NpcSimpleFigure.SHIN, 0)]
		var wr: Node3D = jm["wrist" + sfx]
		extra["wrist" + sfx] = [wr.global_position, _figure.palm_global(i).origin]
	var torso: Node3D = jm["torso"]
	extra["torso"] = [torso.global_position, torso.global_transform * Vector3(0, NpcSimpleFigure.TORSO_H, 0)]
	var head: Node3D = jm["head"]
	extra["head"] = [head.global_position, head.global_transform * Vector3(0, NpcSimpleFigure.HEAD_R * 2.0, 0)]
	for name in extra:
		var d2 := float(LightGizmoMath.ray_segment(ro, rd, extra[name][0], extra[name][1])["dist"])
		if d2 < best_d:
			best_d = d2
			best = name
	return best


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is SpinBox or (focus != null and focus.get_parent() is SpinBox):
		return
	match k.keycode:
		KEY_ESCAPE:
			if _confirm.visible:
				_confirm.visible = false
			else:
				request_close()
		KEY_SPACE:
			_toggle_play()
		KEY_K:
			_key_selected()
		KEY_DELETE:
			_delete_key()
		KEY_M:
			_mirror_pose()
		KEY_C:
			if k.ctrl_pressed:
				_copy_pose()
			else:
				return
		KEY_V:
			if k.ctrl_pressed:
				_paste_pose()
			else:
				return
		KEY_S:
			if k.ctrl_pressed:
				save()
			else:
				return
		_:
			return
	get_viewport().set_input_as_handled()
