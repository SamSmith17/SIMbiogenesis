extends Control
## Hardware Detail — the parametric assembly editor behind every joint.
##
## Four assemblies describe a whole structure: the outer and inner V-beam
## joints, the H-beam centre linkage and the V-beam centre. Each is an ordered
## stack of real parts along the bolt through that joint, and because the stack
## is ordered, it doubles as the assembly instruction the Build Guide prints
## and the NPC crew works from.
##
## Port of the editor half of `js/linkage/hardware-detail.js` — pick a part in
## 3D, drag it along its axis, watch it snap flush; explode the stack to see
## the order; swap in a library preset. The maths lives in `LinkageHwLayout`,
## the meshes in `LinkageHwParts`; this file is interaction only.
##
## No `class_name` on purpose — lazily loaded by main.gd, so `ui_compile_selftest`
## and the linkage selftest are what force-compile it.

signal closed

const MODAL_NAME := "linkage_hardware"
const SIDEBAR_W := 330
const RIGHT_W := 260
const TOPBAR_H := 52
const NUDGE_IN := 0.01

const C_BG := UITheme.C_BG
const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const C_TEXT_M := UITheme.C_TEXT_M
const C_PRIMARY := UITheme.C_PRIMARY

var params: LinkageParams = LinkageParams.new()

## What one edit costs. A part offset moves ONE node; a preset swap rebuilds the
## stack; only a handful of edits can move the STRUCTURE, and re-solving the
## frame three times per mouse-motion event (which is what a single
## `_after_edit()` used to do) is why dragging crawled.
const EDIT_TRANSFORM := 1   ## one part moved — no mesh, no layout, no solve
const EDIT_MESH := 2        ## a part's geometry changed — rebuild the stack
const EDIT_LIST := 4        ## the sidebar/inspector is stale
const EDIT_SPACING := 8     ## LinkageHardwareSpacing inputs changed — re-solve

## Structure re-solves are debounced: the player is still dragging, and the
## intermediate frames are never looked at.
const SPACING_DEBOUNCE_S := 0.15

## How solid the surrounding frame is drawn in the part view. Low enough to see
## the stack through a beam, high enough that the members still read as members
## — the web fades its own to 0.26 (scene-render.js:113).
const GHOST_ALPHA := 0.22

## Both drag modifiers are advertised here, because neither is discoverable and
## the cross axis is the only way to place a part off the bolt line by hand.
const HINT_IDLE := "Click a part to select · drag to slide it along the bolt · " \
	+ "Shift-drag to offset across · Ctrl-drag ignores snap · " \
	+ "Del removes · Ctrl+D duplicates · arrows nudge"

var _active_id := "outerVBeam"
var _selected := ""
var _selected_copy := 0
var _dragging := false
var _suppress := false

## Drag gesture state. `_drag_grab` is the inches between where the pointer
## landed on the axis and where the part's centre actually was — held constant
## for the gesture so the part moves WITH the cursor instead of teleporting its
## centre under it (which is what the web does).
var _drag_ctx: Dictionary = {}
var _drag_render_axis := ""
var _drag_grab := 0.0
var _drag_cross := false     ## Shift: drive crossOffset instead of the stack axis
var _drag_no_snap := false   ## Ctrl: ignore snap planes for this gesture
var _drag_snapped := false
## The bracket is not on a stack; it drags its own local posX/posY nudge.
var _drag_bracket := false

var _pending_flags := 0
var _flush_queued := false
var _spacing_timer: Timer = null
var _ctx_key := ""
var _lift := 0.0

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _builder: LinkageHwAssemblyBuilder = null
var _sun: DirectionalLight3D = null
var _yaw := 0.9
var _pitch := 0.25
var _dist := 14.0
var _orbiting := false
var _panning := false
var _target := Vector3.ZERO

## The part view IS the in-structure view, as in the web app: the joint on the
## real frame, every joint of every detailed assembly dressed, camera parked on
## the focused one. The toggle drops to a standalone studio for close work.
var _in_structure := true
var _structure: LinkageStructureBuilder = null
var _placements: Array = []
var _ring_center := Vector3.ZERO      # metres — mean of every joint on the frame
var _context_builders: Dictionary = {}   # assembly_id -> LinkageHwAssemblyBuilder

var _tab_btns: Dictionary = {}
var _context_chk: CheckBox = null
var _explode_slider: HSlider = null
var _snap_chk: CheckBox = null
var _ghost_chk: CheckBox = null
var _parts_box: VBoxContainer = null
var _inspector_box: VBoxContainer = null
var _readout: RichTextLabel = null
var _hint: Label = null

## "part_id|key" -> the widget editing it, so a value the model changed on the
## player's behalf (a snap, a clamp, a coupled beam) can be echoed back.
var _field_widgets: Dictionary = {}
## Inspector section name -> open. Lives here rather than on the section nodes
## because those are rebuilt on every selection change.
var _section_open: Dictionary = {}

## Selection gizmo + snap ghosts. Parented to the BUILDER, never to its
## `_stack_root` — `set_instances` duplicates that subtree, so a gizmo living
## inside it would be cloned onto every joint on the frame.
var _axis_gizmo: Node3D = null
var _snap_ghosts: Node3D = null
var _hover_id := ""
var _hover_frame := 0
var _vpc: SubViewportContainer = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_spacing_timer = Timer.new()
	_spacing_timer.one_shot = true
	_spacing_timer.timeout.connect(_on_spacing_timeout)
	add_child(_spacing_timer)
	visible = false


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func open(p: LinkageParams) -> void:
	params = p if p != null else LinkageParams.new()
	params.hardware_assemblies = LinkageHardware.ensure(params.hardware_assemblies)
	# Re-cut the preview timber from THIS design before drawing anything: the
	# joint is only meaningful against the members it actually clamps.
	LinkageHardware.sync_beams_from_structure(params.hardware_assemblies, params)
	_active_id = str(params.hardware_assemblies.get("activeId", "outerVBeam"))
	_selected = ""
	_refresh_all()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	if not visible:
		return
	visible = false
	CursorController.release_modal(MODAL_NAME)
	closed.emit()


## The edited assembly graph, for the Lab to write back.
func hardware_assemblies() -> Dictionary:
	return params.hardware_assemblies


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	match k.keycode:
		KEY_ESCAPE:
			close()
		KEY_DELETE:
			_delete_selected()
		KEY_D:
			if k.ctrl_pressed:
				_duplicate_selected()
			else:
				return
		KEY_LEFT, KEY_DOWN:
			_nudge_selected(-NUDGE_IN)
		KEY_RIGHT, KEY_UP:
			_nudge_selected(NUDGE_IN)
		_:
			return
	get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(C_BG.r, C_BG.g, C_BG.b, 0.94)
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
	main.add_child(_build_center())
	main.add_child(_build_right())


func _build_topbar() -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	wrap.custom_minimum_size.y = TOPBAR_H
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	wrap.add_child(bar)

	var title := Label.new()
	title.text = "🔩  HARDWARE DETAIL"
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	bar.add_child(title)

	for id in LinkageHardware.ASSEMBLY_IDS:
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.text = _short_label(id)
		b.tooltip_text = "Edit the %s stack" % id
		UITheme.style_button(b)
		b.pressed.connect(_on_tab_pressed.bind(id))
		bar.add_child(b)
		_tab_btns[id] = b

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var ex_lbl := Label.new()
	ex_lbl.text = "Explode"
	ex_lbl.add_theme_color_override("font_color", C_TEXT_S)
	ex_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	bar.add_child(ex_lbl)
	_explode_slider = HSlider.new()
	_explode_slider.min_value = 0.0
	_explode_slider.max_value = 1.0
	_explode_slider.step = 0.01
	_explode_slider.custom_minimum_size.x = 140
	_explode_slider.value_changed.connect(_on_explode_changed)
	bar.add_child(_explode_slider)

	_context_chk = CheckBox.new()
	_context_chk.text = "In structure"
	_context_chk.button_pressed = true
	_context_chk.focus_mode = Control.FOCUS_NONE
	_context_chk.tooltip_text = "Show this joint on the real frame, with the same hardware ghosted at every other joint that uses it"
	_context_chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_context_chk.toggled.connect(_on_context_toggled)
	bar.add_child(_context_chk)

	_snap_chk = CheckBox.new()
	_snap_chk.text = "Snap"
	_snap_chk.button_pressed = true
	_snap_chk.focus_mode = Control.FOCUS_NONE
	_snap_chk.tooltip_text = "Pull a dragged part flush against its neighbour's face"
	_snap_chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_snap_chk.toggled.connect(func(on: bool) -> void:
		params.hardware_assemblies["snap"] = on)
	bar.add_child(_snap_chk)

	_ghost_chk = CheckBox.new()
	_ghost_chk.text = "X-ray"
	_ghost_chk.button_pressed = true
	_ghost_chk.focus_mode = Control.FOCUS_NONE
	_ghost_chk.tooltip_text = "Ghost the surrounding timber so the joint inside it is readable"
	_ghost_chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_ghost_chk.toggled.connect(func(on: bool) -> void:
		if _structure != null:
			_structure.set_ghost_alpha(GHOST_ALPHA if on else 1.0))
	bar.add_child(_ghost_chk)

	var reset := Button.new()
	reset.text = "Reset assembly"
	reset.focus_mode = Control.FOCUS_NONE
	reset.tooltip_text = "Restore this assembly to the shipped default"
	UITheme.style_button(reset)
	reset.pressed.connect(_on_reset_assembly)
	bar.add_child(reset)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(close_btn)
	close_btn.pressed.connect(close)
	bar.add_child(close_btn)
	return wrap


func _build_sidebar() -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	wrap.custom_minimum_size.x = SIDEBAR_W
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	wrap.add_child(scroll)
	_parts_box = VBoxContainer.new()
	_parts_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_parts_box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	scroll.add_child(_parts_box)
	return wrap


func _build_center() -> Control:
	var vpc := SubViewportContainer.new()
	vpc.stretch = true
	vpc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc.gui_input.connect(_on_viewport_input)
	_vpc = vpc
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(900, 700)
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	_viewport.own_world_3d = true
	vpc.add_child(_viewport)

	var studio := Node3D.new()
	studio.name = "Studio"
	_viewport.add_child(studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.035, 0.043, 0.063)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.65)
	e.ambient_light_energy = 0.6
	env.environment = e
	studio.add_child(env)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	_sun.light_energy = 1.5
	studio.add_child(_sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, 140.0, 0.0)
	fill.light_energy = 0.45
	studio.add_child(fill)

	# The solved frame, drawn behind the joint so the hardware reads in place —
	# and ghosted, because a joint lives INSIDE the members it clamps and solid
	# timber at reading range is simply an opaque wall in front of the subject.
	_structure = LinkageStructureBuilder.new()
	_structure.name = "Structure"
	_structure.collision_mesh_enabled = false
	studio.add_child(_structure)
	_structure.set_ghost_alpha(GHOST_ALPHA)

	_builder = LinkageHwAssemblyBuilder.new()
	_builder.name = "Assembly"
	studio.add_child(_builder)

	_axis_gizmo = Node3D.new()
	_axis_gizmo.name = "AxisGizmo"
	_axis_gizmo.visible = false
	_builder.add_child(_axis_gizmo)
	_snap_ghosts = Node3D.new()
	_snap_ghosts.name = "SnapGhosts"
	_builder.add_child(_snap_ghosts)

	_camera = Camera3D.new()
	_camera.near = 0.01
	_camera.far = 200.0
	studio.add_child(_camera)
	_update_camera()

	var overlay := VBoxContainer.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint = Label.new()
	_hint.text = HINT_IDLE
	_hint.add_theme_color_override("font_color", C_TEXT_M)
	_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	overlay.add_child(_hint)
	vpc.add_child(overlay)
	return vpc


## The right rail is the INSPECTOR for whatever is selected — every field the
## part has, in collapsible sections.
##
## It used to be a read-only readout while the left rail carried four SpinBoxes
## per part and hid the other ~30 fields behind the preset dropdown. Putting all
## of them on every card would be 300+ widgets; putting them here, one part at a
## time, is an ordinary inspector. The assembly readout moves into its own
## (collapsed) section at the bottom.
func _build_right() -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	wrap.custom_minimum_size.x = RIGHT_W
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	wrap.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, UITheme.SPACE_SM)
	scroll.add_child(margin)
	_inspector_box = VBoxContainer.new()
	_inspector_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	margin.add_child(_inspector_box)
	return wrap


## A collapsible section. Open/closed state is remembered per NAME on the modal,
## not on the node, so it survives the rebuilds that selection changes cause —
## a section that snapped shut every time you clicked a different part would be
## worse than no sections at all.
func _section(title: String, default_open: bool) -> VBoxContainer:
	var open := bool(_section_open.get(title, default_open))
	var head := Button.new()
	head.flat = true
	head.focus_mode = Control.FOCUS_NONE
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.text = "%s  %s" % ["▾" if open else "▸", title]
	head.add_theme_color_override("font_color", C_PRIMARY)
	head.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_inspector_box.add_child(head)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UITheme.SPACE_XS)
	body.visible = open
	_inspector_box.add_child(body)

	head.pressed.connect(func() -> void:
		var now := not bool(_section_open.get(title, default_open))
		_section_open[title] = now
		body.visible = now
		head.text = "%s  %s" % ["▾" if now else "▸", title])
	return body


## One editable field, wired live. `flags` says what the edit costs — see the
## EDIT_* constants; getting this wrong is only a performance bug, but it is the
## performance bug this modal had.
func _add_field(box: VBoxContainer, part_id: String, key: String,
		spec: Dictionary, value, on_change: Callable,
		flags: int = EDIT_MESH) -> void:
	var kind := str(spec.get("kind", "num"))
	var label := str(spec.get("label", key))
	match kind:
		"bool":
			var chk := CheckBox.new()
			chk.text = label
			chk.button_pressed = bool(value)
			chk.focus_mode = Control.FOCUS_NONE
			chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			chk.toggled.connect(func(on: bool) -> void:
				if not _suppress:
					on_change.call(on))
			box.add_child(chk)
			_field_widgets["%s|%s" % [part_id, key]] = chk
		"enum":
			var row := HBoxContainer.new()
			var l := Label.new()
			l.text = label
			l.add_theme_color_override("font_color", C_TEXT_S)
			l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(l)
			var opt := OptionButton.new()
			opt.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			var options: Array = spec.get("options", [])
			for i in options.size():
				opt.add_item(str(options[i]), i)
				if str(options[i]) == str(value):
					opt.select(i)
			opt.item_selected.connect(func(i: int) -> void:
				if not _suppress:
					on_change.call(str(options[i])))
			row.add_child(opt)
			box.add_child(row)
			_field_widgets["%s|%s" % [part_id, key]] = opt
		"text":
			var row2 := HBoxContainer.new()
			var l2 := Label.new()
			l2.text = label
			l2.add_theme_color_override("font_color", C_TEXT_S)
			l2.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			l2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row2.add_child(l2)
			var le := LineEdit.new()
			le.text = str(value)
			le.custom_minimum_size.x = 96
			le.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			le.text_changed.connect(func(t: String) -> void:
				if not _suppress:
					on_change.call(t))
			row2.add_child(le)
			box.add_child(row2)
			_field_widgets["%s|%s" % [part_id, key]] = le
		_:
			var f := UIScrubField.make(label,
				float(spec.get("min", -100.0)), float(spec.get("max", 100.0)),
				float(spec.get("step", 0.01)), float(value),
				int(spec.get("dec", 3)), bool(spec.get("slider", true)))
			# Live while scrubbing/sliding/typing; the expensive consequences
			# ride `committed` instead.
			f.value_changed.connect(func(v: float) -> void:
				if not _suppress:
					on_change.call(v))
			f.committed.connect(func(_v: float) -> void:
				if flags & EDIT_SPACING:
					_flush_spacing_now())
			box.add_child(f)
			_field_widgets["%s|%s" % [part_id, key]] = f


func _rebuild_inspector() -> void:
	if _inspector_box == null:
		return
	for child in _inspector_box.get_children():
		child.queue_free()
	_field_widgets.clear()

	var asm := _active()
	var part := LinkageHardware.find_part(asm, _selected) if _selected != "" else {}
	if part.is_empty():
		var idle := Label.new()
		idle.text = "Select a part to edit it."
		idle.add_theme_color_override("font_color", C_TEXT_M)
		idle.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		idle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_inspector_box.add_child(idle)
		_build_assembly_section()
		return

	var pid := str(part["id"])
	var type := str(part.get("type", ""))
	var head := Label.new()
	head.text = "%s  ·  %s" % [str(part.get("label", pid)), type]
	head.add_theme_color_override("font_color", C_TEXT)
	head.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_box.add_child(head)

	if type != "bracket":
		_build_placement_section(part, pid)
	_build_params_section(part, pid, type)
	_build_counts_section(part, pid)
	_build_assembly_section()


func _build_placement_section(part: Dictionary, pid: String) -> void:
	var box := _section("Placement", true)
	var asm := _active()
	var axis := str(part.get("axis", "right"))
	var layout := LinkageHwLayout.compute_axis_layout(asm, axis)
	# Slider range from the stack this part lives on, so the sweep covers the
	# positions that are actually reachable rather than a fixed ±12".
	var span := maxf(float(layout.get("span", 0.0)), 4.0)
	var lo := clampf(-span, -12.0, 0.0)
	var hi := clampf(span * 2.0, 1.0, 12.0)

	_add_field(box, pid, "posAssembled",
		{"label": "Offset along stack (in)", "kind": "num",
			"min": lo, "max": hi, "step": 0.01, "dec": 4},
		float(part.get("posAssembled", 0.0)),
		func(v: float) -> void: _set_offset(pid, v), EDIT_SPACING)
	_add_field(box, pid, "crossOffset",
		{"label": "Offset across (in)", "kind": "num",
			"min": -6.0, "max": 6.0, "step": 0.01, "dec": 4},
		float(part.get("crossOffset", 0.0)),
		func(v: float) -> void: _set_part_field(pid, "crossOffset", v, EDIT_TRANSFORM))
	_add_field(box, pid, "posExploded",
		{"label": "Offset when exploded (in)", "kind": "num",
			"min": -24.0, "max": 24.0, "step": 0.05, "dec": 3},
		float(part.get("posExploded", 0.0)),
		func(v: float) -> void: _set_part_field(pid, "posExploded", v, EDIT_TRANSFORM))
	_add_field(box, pid, "flipAxis",
		{"label": "Flip head/tail", "kind": "bool"},
		bool(part.get("flipAxis", false)),
		func(v: bool) -> void: _set_part_field(pid, "flipAxis", v, EDIT_TRANSFORM))
	# All six axes, including front/back — the layout has always supported them
	# and the web's own add-dropdown simply never offered them.
	_add_field(box, pid, "axis",
		{"label": "Axis", "kind": "enum", "options": LinkageHwLayout.AXES},
		str(part.get("axis", "right")),
		func(v: String) -> void: _set_part_field(pid, "axis", v,
			EDIT_MESH | EDIT_LIST | EDIT_SPACING))


func _build_params_section(part: Dictionary, pid: String, type: String) -> void:
	var rows := LinkageHwParamFields.for_type(type)
	if rows.is_empty():
		return
	var box := _section("Parameters", true)
	var pr: Dictionary = part.get("params", {})
	for row in rows:
		var spec := row as Dictionary
		var key := str(spec["key"])
		if not pr.has(key):
			continue
		_add_field(box, pid, key, spec, pr[key],
			func(v) -> void: _set_param(pid, key, v))


func _build_counts_section(part: Dictionary, pid: String) -> void:
	var box := _section("Counts, cost & preset", false)
	_add_field(box, pid, "qty",
		{"label": "Qty in stack", "kind": "num",
			"min": 1.0, "max": 12.0, "step": 1.0, "dec": 0},
		float(LinkageHardware.part_qty(part)),
		func(v: float) -> void: _set_part_field(pid, "qty", int(round(v)),
			EDIT_MESH | EDIT_SPACING))
	_add_field(box, pid, "perModule",
		{"label": "Per module (BOM)", "kind": "num",
			"min": 0.0, "max": 48.0, "step": 1.0, "dec": 0},
		float(part.get("perModule", 0)),
		func(v: float) -> void: _set_part_field(pid, "perModule", int(round(v)),
			EDIT_LIST))
	_add_field(box, pid, "cost",
		{"label": "Unit cost ($)", "kind": "num",
			"min": 0.0, "max": 500.0, "step": 0.05, "dec": 2},
		float(part.get("cost", 0.0)),
		func(v: float) -> void: _set_part_field(pid, "cost", v, EDIT_LIST))
	_add_field(box, pid, "qtyExplodeGap",
		{"label": "Gap between copies (in)", "kind": "num",
			"min": 0.0, "max": 6.0, "step": 0.01, "dec": 3},
		float(part.get("qtyExplodeGap", 0.0)),
		func(v: float) -> void: _set_part_field(pid, "qtyExplodeGap", v,
			EDIT_TRANSFORM))
	_add_field(box, pid, "label",
		{"label": "Name", "kind": "text"}, str(part.get("label", pid)),
		func(v: String) -> void: _set_part_field(pid, "label", v, EDIT_LIST))

	var presets := LinkageHwPresets.for_type(str(part.get("type", "")))
	if presets.is_empty():
		return
	var opt := OptionButton.new()
	opt.add_item("— preset —", 0)
	opt.set_item_metadata(0, "")
	var cur := str(part.get("presetId", ""))
	var idx := 1
	for e in presets:
		var d := e as Dictionary
		opt.add_item(str(d.get("name", d["id"])), idx)
		opt.set_item_metadata(idx, str(d["id"]))
		if str(d["id"]) == cur:
			opt.select(idx)
		idx += 1
	opt.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	opt.item_selected.connect(_on_preset_selected.bind(pid, opt))
	box.add_child(opt)


func _build_assembly_section() -> void:
	var box := _section("Assembly & spacing", false)
	_readout = RichTextLabel.new()
	_readout.bbcode_enabled = true
	_readout.fit_content = true
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readout.add_theme_color_override("default_color", C_TEXT_S)
	_readout.add_theme_font_size_override("normal_font_size", UITheme.FONT_XS)
	box.add_child(_readout)
	_update_readout()


## The bracket's local nudge, on the light path.
##
## `EDIT_SPACING` because the nudge genuinely moves the assembly SEAT as well as
## the bracket mesh (`LinkageHwPlacement.transform_for` applies it, and so does
## the builder — deliberately, see that function). The mesh follows every frame
## via `refresh_bracket`; the seat catches up on the debounce and on release,
## which is the right split — re-solving the frame per motion event is what this
## whole edit-classification exists to avoid.
func _set_bracket_nudge(part: Dictionary, key: String, value: float) -> void:
	var pr: Dictionary = part.get("params", {})
	if is_equal_approx(float(pr.get(key, 0.0)), value):
		return
	pr[key] = value
	if _builder != null:
		_builder.refresh_bracket()
	_sync_field(str(part.get("id", "")), key, value)
	# Not gated on `show_hardware_full_detail`: unlike the spacing inputs, the
	# nudge moves the seat through `transform_for` whether or not the hardware
	# is driving the structure's own dimensions.
	_after_edit(EDIT_TRANSFORM | EDIT_SPACING)


## A `params` write. Routed separately from top-level fields because the
## spacing classifier keys on the params key, not on the literal "params".
func _set_param(part_id: String, key: String, value) -> void:
	var part := LinkageHardware.find_part(_active(), part_id)
	if part.is_empty():
		return
	var pr: Dictionary = part.get("params", {})
	pr[key] = value
	var flags := EDIT_MESH
	if LinkageHardware.edit_requires_respacing(_active_id, part, key) \
			and params.show_hardware_full_detail:
		flags |= EDIT_SPACING
	# Editing a beam's dimensions by hand means the player no longer wants it
	# re-cut from the design on every open (`hwSyncBeamPartFromState`'s own
	# rule) — otherwise the next sync silently discards the edit.
	if str(part.get("type", "")) == "beam" and key != "syncStructure":
		pr["syncStructure"] = false
	_after_edit(flags)


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

func _refresh_all() -> void:
	_suppress = true
	for id in _tab_btns:
		(_tab_btns[id] as Button).button_pressed = str(id) == _active_id
	if _explode_slider != null:
		_explode_slider.value = float(params.hardware_assemblies.get("explode", 0.0))
	if _snap_chk != null:
		_snap_chk.button_pressed = bool(params.hardware_assemblies.get("snap", true))
	_suppress = false
	_rebuild_3d(true)
	_rebuild_part_list()


func _active() -> Dictionary:
	return LinkageHardware.assembly(params.hardware_assemblies, _active_id)


## `reframe` only on open and on an assembly switch — re-aiming the camera
## every time the player nudges a part would fight them for control of the view.
func _rebuild_3d(reframe: bool = false) -> void:
	if _builder == null:
		return
	# On the real frame the structure supplies the timber, so the preview
	# beams are suppressed rather than stacked on top of the actual members.
	_builder.set_assembly(_active(),
		float(params.hardware_assemblies.get("explode", 0.0)), _in_structure)
	if _selected != "":
		_builder.set_selected(_selected, _selected_copy)
	_rebuild_context()
	if reframe:
		_frame_assembly()


## Draw the solved frame around the joint, and repeat the joint's hardware at
## every other pivot that uses it.
##
## The editable stack is moved onto the FIRST placement so it sits in its real
## seat on the structure rather than at the world origin — which is what makes
## "the part in context of the rest of the structure" true rather than a
## picture of a joint next to a picture of a frame.
func _rebuild_context() -> void:
	if _builder == null or _structure == null:
		return
	if not _in_structure:
		_structure.visible = false
		_builder.transform = Transform3D.IDENTITY
		_builder.set_instances([])
		_clear_context_builders()
		_placements = []
		_ctx_key = ""
		return
	_structure.visible = true

	# Two full solves and a MultiMesh realloc live below, and almost no edit in
	# this modal can change their result — only the handful
	# `LinkageHardware.edit_requires_respacing` names, and only with full detail
	# on. Key on everything the solve reads and re-seat from the cached
	# placements otherwise. `_active_id` is in the key because it decides which
	# placements are the editable ones.
	var key := "%d|%d|%s" % [params.to_config().hash(), int(_in_structure), _active_id]
	if key == _ctx_key and not _placements.is_empty():
		_builder.transform = LinkageHwAssemblyBuilder.seat_transform(
			_placements[0], _lift)
		_builder.set_instances(_placements, _lift)
		_builder.sync_instances()
		return
	_ctx_key = key

	# The DISPLAY frame hides the simple brackets and bolts — the detailed
	# assemblies replace them, and drawing both stacks two brackets at every
	# joint (`hideLegacyHardware`, scene-render.js:63).
	var display := params.duplicate_params()
	display.show_brackets = false
	display.show_bolts = false
	_structure.set_params(display)
	_structure.set_fold_angle(_structure.closed_angle())

	# The PLACEMENT frame needs both flags ON: brackets seat the V-beam
	# joints, and the centre bolts mark the crossing joints.
	var pp := params.duplicate_params()
	pp.show_brackets = true
	pp.show_bolts = true
	var closed := LinkageKinematics.optimal_closed_angle(pp)
	var pframe := LinkageSolver.solve(pp, closed)
	# Match the structure's own ground lift, or every joint floats off it.
	# The lift comes from the DISPLAY frame — that is the mesh on screen.
	var lift := LinkageStructureBuilder.ground_offset_for_frame(
		_structure.last_frame())
	_lift = lift

	var all := LinkageHwPlacement.placements(params, pframe)
	_placements = []
	var others: Dictionary = {}          # assembly_id -> Array[Transform3D]
	# The ring's centre, for camera framing: the solver builds module 0 AT the
	# world origin and chains outward, so the structure's middle is nowhere
	# near (0,0,0) — aim-from-origin maths would bury the eye inside the ring.
	var centre_sum := Vector3.ZERO
	for entry in all:
		var e := entry as Dictionary
		var aid := str(e["assembly_id"])
		centre_sum += (e["transform"] as Transform3D).origin
		if aid == _active_id:
			_placements.append(e["transform"])
		else:
			if not others.has(aid):
				others[aid] = []
			(others[aid] as Array).append(e["transform"])
	_ring_center = Vector3.ZERO
	if not all.is_empty():
		_ring_center = centre_sum / float(all.size()) 			* LinkageHwAssemblyBuilder.INCH_TO_M

	# The ACTIVE assembly: editable stack seated on its first joint, clones on
	# the rest. An assembly nothing uses falls back to the standalone pose —
	# the web frames a detailed-but-empty assembly the same way so the player
	# can build it in place (hwResolveDetailFocus, scene-render.js:46).
	if _placements.is_empty():
		_builder.transform = Transform3D.IDENTITY
		_builder.set_instances([])
	else:
		_builder.transform = LinkageHwAssemblyBuilder.seat_transform(_placements[0], lift)
		_builder.set_instances(_placements, lift)
		_builder.sync_instances()

	# EVERY other detailed assembly renders at its own joints too — the web
	# stamps them all in part view (scene-render.js:180-185), which is what
	# makes the frame read as fully hardwared rather than one joint dressed
	# and the rest bare.
	_sync_context_builders(others, lift)


## One static builder per non-active assembly, seated + cloned across its
## placements. No pick bodies — a click must always land on the editable stack.
func _sync_context_builders(others: Dictionary, lift: float) -> void:
	for aid in _context_builders:
		if not others.has(aid):
			(_context_builders[aid] as LinkageHwAssemblyBuilder).visible = false
	for aid in others:
		var asm := LinkageHardware.assembly(params.hardware_assemblies, str(aid))
		var seats: Array = others[aid]
		if asm.is_empty() or (asm.get("parts", []) as Array).is_empty() or seats.is_empty():
			if _context_builders.has(aid):
				(_context_builders[aid] as LinkageHwAssemblyBuilder).visible = false
			continue
		var cb: LinkageHwAssemblyBuilder = _context_builders.get(aid)
		if cb == null:
			cb = LinkageHwAssemblyBuilder.new()
			cb.name = "Context_%s" % str(aid)
			_structure.get_parent().add_child(cb)
			_context_builders[aid] = cb
		cb.visible = true
		cb.set_assembly(asm, 0.0, true)
		cb.strip_pick_bodies()
		cb.transform = LinkageHwAssemblyBuilder.seat_transform(seats[0], lift)
		cb.set_instances(seats, lift)


func _clear_context_builders() -> void:
	for aid in _context_builders:
		var cb := _context_builders[aid] as LinkageHwAssemblyBuilder
		if is_instance_valid(cb):
			cb.visible = false


func _on_context_toggled(on: bool) -> void:
	_in_structure = on
	_rebuild_3d(true)


## Aim the camera at the HARDWARE's own extent (metres — the beams' eight-foot
## members are deliberately excluded, see `hardware_aabb`), then apply the
## assembly's authored camera preset. A bare joint and a fully-loaded one both
## fill the view.
func _frame_assembly() -> void:
	var asm := _active()
	var cam: Dictionary = asm.get("detailCam", {})
	var box := _builder.hardware_aabb() if _builder != null else AABB()
	var extent := maxf(box.size.length(), 0.05)
	if extent <= 0.05:
		# Nothing built yet: fall back to the stack's own span, converted out of
		# inches. Mixing the two units here put the camera 20x too far away.
		var span := maxf(LinkageHwLayout.assembly_sandwich_gap(asm), 1.0)
		for axis in LinkageHwLayout.AXES:
			span = maxf(span, float(LinkageHwLayout.compute_axis_layout(asm, axis)["span"]))
		extent = span * LinkageHwAssemblyBuilder.INCH_TO_M
	_target = box.get_center()
	if _builder != null:
		_target = _builder.transform * _target
	# Standing the joint on the real frame puts its neighbours right beside it,
	# so sitting as close as the standalone view lands the camera INSIDE a
	# member. Back off far enough to read a span either side of the joint.
	var mul := float(cam.get("distMul", 2.0))
	# `hwFrameDetailInstance` (scene-render.js:255), in the inches it was
	# written in: `max(16, radius * distMul + 8)`. The 16" floor is what keeps a
	# SPARSE assembly framed — hCenter is one gap washer, and scaling purely off
	# its extent would put the camera inside it.
	var radius_in := extent / LinkageHwAssemblyBuilder.INCH_TO_M
	var dist_in := maxf(16.0, radius_in * mul + 8.0)
	_dist = clampf(dist_in * LinkageHwAssemblyBuilder.INCH_TO_M, 0.15, 12.0)
	if _in_structure and not _placements.is_empty():
		# Approach from OUTSIDE the ring, along the joint's own radial FROM THE
		# RING'S CENTRE — otherwise whatever yaw the last orbit left behind can
		# bury the eye inside a beam two modules over.
		var radial := Vector2(_target.x - _ring_center.x, _target.z - _ring_center.z)
		if radial.length() > 0.05:
			_yaw = atan2(radial.x, radial.y)
		# Slightly BELOW the ring plane looking up: the deployed V-beams lean
		# outward over the eye line, so the standalone presets' downward pitch
		# puts the camera inside one.
		_pitch = -0.12
	else:
		_pitch = deg_to_rad(float(cam.get("pitchDeg", 14.0)))
	_update_camera()


# ---------------------------------------------------------------------------
# Part list (left rail)
# ---------------------------------------------------------------------------

## One compact row per part, grouped by axis — the ORDER of the stack, which is
## the thing this list is for. Editing moved to the inspector: four SpinBoxes on
## every card made an eleven-part assembly a scrolling wall while still hiding
## most of what a part has.
func _rebuild_part_list() -> void:
	if _parts_box == null:
		return
	for child in _parts_box.get_children():
		child.queue_free()
	var asm := _active()
	var head := Label.new()
	head.text = str(asm.get("label", _active_id))
	head.add_theme_color_override("font_color", C_PRIMARY)
	head.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_parts_box.add_child(head)

	var bracket := LinkageHardware.bracket_part(asm)
	if not bracket.is_empty():
		_add_part_row(bracket, "anchor")
	for axis in LinkageHwLayout.AXES:
		var parts := LinkageHardware.parts_on_axis(asm, str(axis))
		var axis_head := Label.new()
		axis_head.text = "%s axis" % str(axis)
		axis_head.add_theme_color_override("font_color", C_TEXT_M)
		axis_head.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		_parts_box.add_child(axis_head)
		for part in parts:
			_add_part_row(part as Dictionary, str(axis))
		var add := Button.new()
		add.text = "+ Add part to %s" % str(axis)
		add.focus_mode = Control.FOCUS_NONE
		add.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		add.pressed.connect(_on_add_part.bind(str(axis)))
		_parts_box.add_child(add)
	_rebuild_inspector()


func _add_part_row(part: Dictionary, axis: String) -> void:
	var pid := str(part.get("id", ""))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.custom_minimum_size.y = 24
	_parts_box.add_child(row)

	var sel := Button.new()
	sel.flat = true
	sel.focus_mode = Control.FOCUS_NONE
	sel.alignment = HORIZONTAL_ALIGNMENT_LEFT
	sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	sel.add_theme_color_override("font_color",
		C_PRIMARY if pid == _selected else C_TEXT)
	var qty := LinkageHardware.part_qty(part)
	sel.text = "%s   %.3f\"%s" % [str(part.get("label", pid)),
		LinkageHwLayout.part_axial_length(part),
		"  ×%d" % qty if qty > 1 else ""]
	sel.tooltip_text = "%s · %d/module · $%.2f" % [str(part.get("type", "")),
		int(part.get("perModule", 0)), float(part.get("cost", 0.0))]
	sel.pressed.connect(func() -> void: _select(pid, 0))
	row.add_child(sel)

	# The bracket anchors the stack rather than sitting in it, so it has no
	# order and no delete. (It is still pickable in 3D — see `_delete_selected`,
	# which refuses it for the same reason.)
	if axis == "anchor":
		return
	for spec in [["↑", -1], ["↓", 1]]:
		var mv := Button.new()
		mv.text = str(spec[0])
		mv.flat = true
		mv.focus_mode = Control.FOCUS_NONE
		mv.custom_minimum_size.x = 18
		mv.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		mv.pressed.connect(_on_reorder.bind(pid, int(spec[1])))
		row.add_child(mv)
	var dup := Button.new()
	dup.text = "⧉"
	dup.tooltip_text = "Duplicate"
	dup.flat = true
	dup.focus_mode = Control.FOCUS_NONE
	dup.custom_minimum_size.x = 18
	dup.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	dup.pressed.connect(func() -> void: _select(pid, 0); _duplicate_selected())
	row.add_child(dup)
	var del := Button.new()
	del.text = "✕"
	del.tooltip_text = "Delete"
	del.flat = true
	del.focus_mode = Control.FOCUS_NONE
	del.custom_minimum_size.x = 18
	del.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	del.pressed.connect(func() -> void: _select(pid, 0); _delete_selected())
	row.add_child(del)


func _update_readout() -> void:
	if _readout == null:
		return
	var asm := _active()
	var gap := LinkageHwLayout.assembly_sandwich_gap(asm)
	var lines: Array = []
	lines.append("[b]%s[/b]" % str(asm.get("label", _active_id)))
	lines.append("Sandwich gap  [b]%.4f\"[/b]" % gap)
	if params.show_hardware_full_detail:
		var sp := LinkageHardwareSpacing.resolve(params)
		if not sp.is_empty():
			lines.append("→ V stack gap  [b]%.4f\"[/b]" % float(sp["v_stack_gap"]))
			lines.append("→ H stack gap  [b]%.4f\"[/b]" % float(sp["h_stack_gap"]))
			var br: Dictionary = sp.get("bracket", {})
			if not br.is_empty():
				lines.append("→ bracket %.2f x %.2f x %.2f\"" % [
					float(br["width"]), float(br["depth"]), float(br["height"])])
	else:
		lines.append("[color=#%s]Hardware Full Detail is off — these parts are "
			% C_TEXT_M.to_html(false)
			+ "shown but do not drive the structure's spacing.[/color]")
	# What this assembly contributes to the bill of materials.
	var items := LinkageBom.assembly_hardware_items(params)
	if not items.is_empty():
		lines.append("")
		lines.append("[b]Hardware in the BOM[/b]")
		for item in items:
			lines.append("%d x %s" % [int(item["qty"]), str(item["item"])])
	if _selected != "":
		var part := LinkageHardware.find_part(asm, _selected)
		if not part.is_empty():
			lines.append("")
			lines.append("[b]Selected[/b] %s" % str(part.get("label", _selected)))
			lines.append("axis %s · seq %d · offset %.3f\"" % [
				str(part.get("axis", "")), int(part.get("seq", 0)),
				float(part.get("posAssembled", 0.0))])
	_readout.text = "\n".join(lines)


# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

func _on_tab_pressed(id: String) -> void:
	_active_id = id
	params.hardware_assemblies["activeId"] = id
	_selected = ""
	_refresh_all()


func _on_explode_changed(v: float) -> void:
	if _suppress:
		return
	params.hardware_assemblies["explode"] = v
	if _builder != null:
		# set_explode carries the pose onto the context clones as well — before
		# that, fanning the stack open left every OTHER joint on the frame shut.
		_builder.set_explode(v)


## Reset must re-cut the preview timber from THIS design. Dropping in the raw
## defaults left the beam parts at the shipped 96" / 3.5x1.5, so the joint
## silently started describing lumber the structure does not use, and stayed
## wrong until the modal was closed and reopened (`open` does the sync).
func _on_reset_assembly() -> void:
	var defaults := LinkageHardware.default_assemblies()
	var fresh: Dictionary = ((defaults["assemblies"] as Dictionary)[_active_id]
		as Dictionary).duplicate(true)
	(params.hardware_assemblies["assemblies"] as Dictionary)[_active_id] = fresh
	LinkageHardware.sync_beams_from_structure(params.hardware_assemblies, params)
	LinkageHardwareSpacing.clear_cache()
	_ctx_key = ""
	_selected = ""
	_refresh_all()


func _select(part_id: String, copy_index: int) -> void:
	_selected = part_id
	_selected_copy = copy_index
	if _builder != null:
		_builder.set_selected(part_id, copy_index)
	_rebuild_axis_gizmo()
	_rebuild_part_list()


# ---------------------------------------------------------------------------
# Selection feedback
# ---------------------------------------------------------------------------

## A rod along the selected part's stack axis, spanning the stack it belongs to.
##
## The tint alone says "this is selected"; it does not say "and it slides along
## THAT line", which is the one thing a player has to know before a drag makes
## any sense. Nothing in the modal used to say it at all.
func _rebuild_axis_gizmo() -> void:
	if _axis_gizmo == null:
		return
	for child in _axis_gizmo.get_children():
		child.queue_free()
	_axis_gizmo.visible = false
	if _selected == "":
		return
	var asm := _active()
	var part := LinkageHardware.find_part(asm, _selected)
	if part.is_empty() or str(part.get("type", "")) == "bracket":
		return
	var ctx := LinkageHwLayout.part_stack_context(part, asm,
		float(params.hardware_assemblies.get("explode", 0.0)), _selected_copy)
	if ctx.is_empty():
		return
	var render := str(ctx["render_axis"])
	var dir: Vector3 = LinkageHwLayout.AXIS_DIRS.get(render, Vector3.RIGHT)
	var cross: Vector3 = LinkageHwLayout.AXIS_CROSS.get(render, Vector3.UP)
	var layout := LinkageHwLayout.compute_axis_layout(asm, str(ctx["axis_key"]))
	var lo := float(layout["origin"]) - 0.5
	var hi := lo + maxf(float(layout.get("span", 0.0)), 2.0) + 1.0

	var cross_in := float(part.get("crossOffset", 0.0))
	if LinkageHwLayout.HORIZONTAL_AXES.has(render):
		var bracket := LinkageHardware.bracket_part(asm)
		if not bracket.is_empty():
			cross_in += LinkageHwLayout.bracket_hole_y(bracket)

	var rod := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.03
	cyl.bottom_radius = 0.03
	cyl.height = (hi - lo)
	cyl.radial_segments = 6
	rod.mesh = cyl
	rod.material_override = _gizmo_material()
	rod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Cylinders are built along +Y; aim it down the axis, then park it at the
	# stack's midpoint offset onto the part's own cross line.
	var mid := (lo + hi) * 0.5
	var basis := _aim_y_along(dir)
	rod.transform = Transform3D(basis.scaled(Vector3.ONE
		* LinkageHwAssemblyBuilder.INCH_TO_M),
		(dir * mid + cross * cross_in) * LinkageHwAssemblyBuilder.INCH_TO_M)
	_axis_gizmo.add_child(rod)
	_axis_gizmo.visible = true


## Basis mapping local +Y onto `dir`. Same job as the builder's `_basis_for`,
## kept local because the gizmo has no reason to reach into it.
func _aim_y_along(dir: Vector3) -> Basis:
	var d := dir.normalized()
	if d.is_equal_approx(Vector3.UP):
		return Basis.IDENTITY
	if d.is_equal_approx(Vector3.DOWN):
		return Basis(Vector3.RIGHT, PI)
	var axis := Vector3.UP.cross(d)
	if axis.length() < 1e-5:
		return Basis.IDENTITY
	return Basis(axis.normalized(), Vector3.UP.angle_to(d))


static var _giz_mat: StandardMaterial3D = null

static func _gizmo_material() -> StandardMaterial3D:
	if _giz_mat == null:
		_giz_mat = StandardMaterial3D.new()
		_giz_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_giz_mat.albedo_color = Color(UITheme.C_PRIMARY.r, UITheme.C_PRIMARY.g,
			UITheme.C_PRIMARY.b, 0.55)
		_giz_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_giz_mat.no_depth_test = true
	return _giz_mat


static var _ghost_mat: StandardMaterial3D = null

static func _ghost_material() -> StandardMaterial3D:
	if _ghost_mat == null:
		_ghost_mat = StandardMaterial3D.new()
		_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mat.albedo_color = Color(UITheme.C_AMBER.r, UITheme.C_AMBER.g,
			UITheme.C_AMBER.b, 0.25)
		_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _ghost_mat


## Amber discs on the planes the dragged part is about to sit flush against.
##
## Snapping is otherwise invisible: the number jumps and the part stops
## following the cursor, which reads as the drag being broken rather than as the
## part clicking onto a face.
func _update_snap_ghosts() -> void:
	if _snap_ghosts == null:
		return
	for child in _snap_ghosts.get_children():
		child.queue_free()
	if not _dragging or _drag_cross or _drag_no_snap or _selected == "":
		return
	if not LinkageHwLayout.snap_active(params.hardware_assemblies):
		return
	var asm := _active()
	var part := LinkageHardware.find_part(asm, _selected)
	if part.is_empty() or _drag_ctx.is_empty():
		return
	var plen := LinkageHwLayout.part_axial_length(part)
	var start := LinkageHwLayout.axis_pos_from_part(part, _drag_ctx) - plen / 2.0
	var planes := LinkageHwLayout.collect_axis_snap_planes(asm,
		str(_drag_ctx["axis_key"]), _selected, _selected_copy, part)
	var render := str(_drag_render_axis if _drag_render_axis != ""
		else _drag_ctx["render_axis"])
	var dir: Vector3 = LinkageHwLayout.AXIS_DIRS.get(render, Vector3.RIGHT)
	for plane in planes:
		var p := float(plane)
		if minf(absf(start - p), absf(start + plen - p)) > 0.35:
			continue
		var disc := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.9, 0.9)
		disc.mesh = quad
		disc.material_override = _ghost_material()
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Quads face +Z; turn one to face down the stack axis.
		var basis := Basis()
		var z := dir.normalized()
		var up := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.9 else Vector3.BACK
		var x := up.cross(z).normalized()
		basis = Basis(x, z.cross(x).normalized(), z)
		disc.transform = Transform3D(
			basis.scaled(Vector3.ONE * LinkageHwAssemblyBuilder.INCH_TO_M),
			dir * (p * LinkageHwAssemblyBuilder.INCH_TO_M))
		_snap_ghosts.add_child(disc)


func _set_part_field(part_id: String, key: String, value,
		flags: int = EDIT_MESH) -> void:
	var part := LinkageHardware.find_part(_active(), part_id)
	if part.is_empty():
		return
	part[key] = value
	if LinkageHardware.edit_requires_respacing(_active_id, part, key) \
			and params.show_hardware_full_detail:
		flags |= EDIT_SPACING
	if flags & EDIT_TRANSFORM and _builder != null:
		# crossOffset moves the body without changing the layout, so it is a
		# transform-only edit — but the builder recomputes it from the part, so
		# a plain reposition is enough.
		_builder.refresh_part(part_id)
	_after_edit(flags)


## Offset writes go through the mirror-coupling rule, so typing a number and
## dragging to it land in the same place.
##
## [b]Typed input is not snapped.[/b] The snap-plane list always contains the
## layout origin, so with a 0.18" threshold and a 0.01" spin step a typed 0.05
## was pulled straight back to 0 — and because the sidebar was not refreshed
## afterwards, the field went on displaying the number the model had rejected.
## That is the whole of "changing the offsets does nothing". A typed number is
## an explicit intent and is taken literally; a drag is a gesture and still
## snaps (hold Ctrl to suppress it). Deliberate divergence from
## `hwApplyPartAssembledPos`, which snaps both.
func _set_offset(part_id: String, value: float, snap: bool = false) -> void:
	var asm := _active()
	var part := LinkageHardware.find_part(asm, part_id)
	if part.is_empty():
		return
	var want := value
	if snap and LinkageHwLayout.snap_active(params.hardware_assemblies):
		var ctx := _drag_ctx if not _drag_ctx.is_empty() \
			else LinkageHwLayout.part_stack_context(part, asm,
				float(params.hardware_assemblies.get("explode", 0.0)),
				_selected_copy)
		if not ctx.is_empty():
			want = LinkageHwLayout.snap_part_assembled_pos(part, asm, ctx, value, true)
	_drag_snapped = snap and not is_equal_approx(want, value)
	part["posAssembled"] = want
	var coupled := LinkageHwLayout.apply_sandwich_beam_coupling(asm, part, want)

	var flags := EDIT_TRANSFORM
	if LinkageHardware.edit_requires_respacing(_active_id, part, "posAssembled") \
			and params.show_hardware_full_detail:
		flags |= EDIT_SPACING
	if _builder != null:
		_builder.set_part_offset(part_id, want)
		if coupled != "":
			_builder.set_part_offset(coupled,
				float(LinkageHardware.find_part(asm, coupled).get("posAssembled", 0.0)))
	_sync_offset_field(part_id, want)
	_after_edit(flags)
	if _dragging:
		_update_hint()


func _nudge_selected(delta: float) -> void:
	if _selected == "":
		return
	var part := LinkageHardware.find_part(_active(), _selected)
	if part.is_empty():
		return
	_set_offset(_selected, float(part.get("posAssembled", 0.0)) + delta)


## Echo a value the model actually stored back into its widget, without
## re-firing the widget's own signal.
##
## Snapping and clamping mean the stored value is not always the typed one, and
## a field left showing a number the model rejected is indistinguishable from an
## edit that did nothing — which is precisely how the old snap-everything
## behaviour presented itself.
func _sync_field(part_id: String, key: String, value: float) -> void:
	var w = _field_widgets.get("%s|%s" % [part_id, key])
	if w == null or not is_instance_valid(w):
		return
	var was := _suppress
	_suppress = true
	if w is UIScrubField:
		(w as UIScrubField).set_value_silent(value)
	elif w is SpinBox:
		(w as SpinBox).value = value
	_suppress = was


func _sync_offset_field(part_id: String, value: float) -> void:
	_sync_field(part_id, "posAssembled", value)


## During a drag the hint line becomes a readout — what is moving, where it is,
## and whether it just snapped. Otherwise it advertises the controls.
func _update_hint() -> void:
	if _hint == null:
		return
	if not _dragging or _selected == "":
		_hint.text = HINT_IDLE
		_hint.add_theme_color_override("font_color", C_TEXT_M)
		return
	var part := LinkageHardware.find_part(_active(), _selected)
	if part.is_empty():
		return
	var label := str(part.get("label", _selected))
	if _drag_bracket:
		var n := _bracket_nudge(part)
		_hint.text = "%s · nudge X %+.3f\"  Y %+.3f\" (moves the whole joint)" \
			% [label, n.x, n.y]
		_hint.add_theme_color_override("font_color", C_TEXT)
		return
	if _drag_cross:
		_hint.text = "%s · across %+.3f\"" % [label, float(part.get("crossOffset", 0.0))]
		_hint.add_theme_color_override("font_color", C_TEXT)
		return
	var suffix := "  ·  SNAP" if _drag_snapped else ""
	_hint.text = "%s · offset %+.3f\"%s" % [
		label, float(part.get("posAssembled", 0.0)), suffix]
	_hint.add_theme_color_override("font_color",
		UITheme.C_WARN if _drag_snapped else C_TEXT)


## Delete refuses the bracket. The list gives it no ✕, but it IS pickable in 3D,
## so before this a click plus Del silently removed the thing every offset in
## the assembly is measured from — zeroing the centre offset, dropping the
## cross-axis hole lift, re-seating every joint, with no undo and no way to put
## it back from the UI.
func _delete_selected() -> void:
	if _selected == "":
		return
	var asm := _active()
	var sel := LinkageHardware.find_part(asm, _selected)
	if str(sel.get("type", "")) == "bracket":
		if _hint != null:
			_hint.text = "The bracket anchors this joint — it cannot be deleted."
			_hint.add_theme_color_override("font_color", UITheme.C_WARN)
		return
	var parts: Array = asm.get("parts", [])
	for i in parts.size():
		if str((parts[i] as Dictionary).get("id", "")) == _selected:
			parts.remove_at(i)
			break
	_selected = ""
	_after_edit(EDIT_MESH | EDIT_LIST | EDIT_SPACING)


func _duplicate_selected() -> void:
	if _selected == "":
		return
	var asm := _active()
	var part := LinkageHardware.find_part(asm, _selected)
	if part.is_empty():
		return
	var copy := part.duplicate(true)
	copy["id"] = _unique_id(asm, str(part.get("id", "part")))
	copy["seq"] = int(part.get("seq", 0)) + 1
	copy.erase("sharedKey")
	(asm["parts"] as Array).append(copy)
	_renumber(asm, str(part.get("axis", "right")))
	_selected = str(copy["id"])
	_after_edit(EDIT_MESH | EDIT_LIST | EDIT_SPACING)


func _on_add_part(axis: String) -> void:
	var asm := _active()
	# Default to a washer: it is the least opinionated shim and the one most
	# often added to close a gap.
	var part := LinkageHardware.make_part(_unique_id(asm, "washer"), "washer",
		LinkageHardware.TYPE_LABELS["washer"], axis, 99, 1, 0, 0.10,
		LinkageHardware.default_part_params("washer"))
	(asm["parts"] as Array).append(part)
	_renumber(asm, axis)
	_selected = str(part["id"])
	_after_edit(EDIT_MESH | EDIT_LIST | EDIT_SPACING)


func _on_reorder(part_id: String, delta: int) -> void:
	var asm := _active()
	var part := LinkageHardware.find_part(asm, part_id)
	if part.is_empty():
		return
	var axis := str(part.get("axis", "right"))
	var ordered := LinkageHardware.parts_on_axis(asm, axis)
	var idx := -1
	for i in ordered.size():
		if str((ordered[i] as Dictionary).get("id", "")) == part_id:
			idx = i
	var swap := idx + delta
	if idx < 0 or swap < 0 or swap >= ordered.size():
		return
	var other := ordered[swap] as Dictionary
	var tmp := int(part.get("seq", 0))
	part["seq"] = int(other.get("seq", 0))
	other["seq"] = tmp
	_after_edit(EDIT_MESH | EDIT_LIST | EDIT_SPACING)


func _on_preset_selected(index: int, part_id: String, opt: OptionButton) -> void:
	if _suppress:
		return
	var preset_id := str(opt.get_item_metadata(index))
	if preset_id == "":
		return
	var asm := _active()
	var parts: Array = asm.get("parts", [])
	for i in parts.size():
		if str((parts[i] as Dictionary).get("id", "")) != part_id:
			continue
		parts[i] = LinkageHwPresets.apply_to_part(parts[i] as Dictionary, preset_id)
		break
	_after_edit(EDIT_MESH | EDIT_LIST | EDIT_SPACING)


## Queue one edit's consequences. Work is COALESCED to the end of the frame:
## a drag delivers many motion events per frame and each used to trigger a full
## `set_params` + `set_fold_angle` + `LinkageSolver.solve` — three solves per
## mouse-move, with nothing looking at the intermediate results.
func _after_edit(flags: int = EDIT_MESH | EDIT_LIST) -> void:
	_pending_flags |= flags
	if flags & EDIT_SPACING:
		# Structure re-solves wait for the player to stop moving. A drag that
		# changes a sandwich standoff genuinely does move the frame, but only
		# the pose they settle on is worth solving for.
		if _spacing_timer != null:
			_spacing_timer.start(SPACING_DEBOUNCE_S)
	if _flush_queued:
		return
	_flush_queued = true
	call_deferred("_flush_edits")


func _flush_edits() -> void:
	_flush_queued = false
	var flags := _pending_flags
	# The spacing bit stays pending until its timer fires (or a mouse-up forces
	# it); everything else is consumed now.
	_pending_flags &= EDIT_SPACING
	if flags == 0:
		return
	if flags & EDIT_MESH and _builder != null:
		_builder.set_assembly(_active(),
			float(params.hardware_assemblies.get("explode", 0.0)), _in_structure)
		if _selected != "":
			_builder.set_selected(_selected, _selected_copy)
	if flags & EDIT_LIST:
		_rebuild_part_list()
	_update_readout()


## The deferred structure re-solve. `_ctx_key` makes it a no-op when nothing
## the solver reads has actually changed.
func _on_spacing_timeout() -> void:
	_flush_spacing_now()


func _flush_spacing_now() -> void:
	if _spacing_timer != null:
		_spacing_timer.stop()
	if not (_pending_flags & EDIT_SPACING):
		return
	_pending_flags &= ~EDIT_SPACING
	LinkageHardwareSpacing.clear_cache()
	_ctx_key = ""
	_rebuild_context()
	_update_readout()


func _unique_id(asm: Dictionary, base: String) -> String:
	var n := 1
	var candidate := "%s-%d" % [base, n]
	while not LinkageHardware.find_part(asm, candidate).is_empty():
		n += 1
		candidate = "%s-%d" % [base, n]
	return candidate


## Compact an axis's seq values back to 0..n-1 so reordering stays stable.
func _renumber(asm: Dictionary, axis: String) -> void:
	var ordered := LinkageHardware.parts_on_axis(asm, axis)
	for i in ordered.size():
		(ordered[i] as Dictionary)["seq"] = i


func _short_label(id: String) -> String:
	match id:
		"outerVBeam":
			return "Outer V"
		"innerVBeam":
			return "Inner V"
		"hCenter":
			return "H centre"
		"vCenter":
			return "V centre"
	return id


# ---------------------------------------------------------------------------
# Viewport interaction
# ---------------------------------------------------------------------------

func _on_viewport_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					# Modifiers are read once, at grab time: changing them
					# mid-gesture would swap axes under a moving pointer.
					_drag_cross = mb.shift_pressed
					_drag_no_snap = mb.ctrl_pressed
					_begin_pick(mb.position)
				else:
					if _dragging:
						# The structure re-solve was deferred for the whole
						# gesture; settle it now rather than on a timer.
						_flush_spacing_now()
						_rebuild_part_list()
						_rebuild_axis_gizmo()
					_dragging = false
					_orbiting = false
					_drag_ctx = {}
					_drag_bracket = false
					_drag_snapped = false
					_update_snap_ghosts()
					_update_hint()
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_dist = maxf(0.2, _dist * 0.9)
					_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_dist = minf(80.0, _dist * 1.1)
					_update_camera()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _dragging:
			_drag_to(mm.position)
			_update_snap_ghosts()
		elif mm.button_mask == 0:
			_update_hover(mm.position)
		elif _orbiting:
			_yaw -= mm.relative.x * 0.01
			_pitch = clampf(_pitch - mm.relative.y * 0.01, -1.4, 1.4)
			_update_camera()
		elif _panning:
			var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
			var k := _dist * 0.0016
			_target += right * (-mm.relative.x * k) + Vector3.UP * (mm.relative.y * k)
			_update_camera()


## Change the cursor over a draggable part.
##
## The single highest-value affordance here: before this, nothing whatsoever
## distinguished a part you can grab from the scenery behind it, so the drag —
## which is the modal's main verb — was undiscoverable. Throttled, because the
## raycast is cheap but re-tinting on every motion event is not.
func _update_hover(pos: Vector2) -> void:
	if _vpc == null or _camera == null or _dragging:
		return
	_hover_frame += 1
	if _hover_frame % 2 != 0:
		return
	var body := _pick_body(pos)
	var id := ""
	if body != null and body.has_meta("part_id"):
		# Brackets included: they drag their own nudge, so they are grabbable
		# too and the cursor should say so.
		if not LinkageHardware.find_part(_active(),
				str(body.get_meta("part_id"))).is_empty():
			id = str(body.get_meta("part_id"))
	if id == _hover_id:
		return
	_hover_id = id
	_vpc.mouse_default_cursor_shape = Control.CURSOR_MOVE if id != "" \
		else Control.CURSOR_ARROW


## The pick body under the pointer, or null.
func _pick_body(pos: Vector2) -> Node:
	if _camera == null:
		return null
	var space := _camera.get_world_3d().direct_space_state
	if space == null:
		return null
	var from := _camera.project_ray_origin(pos)
	var to := from + _camera.project_ray_normal(pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	return space.intersect_ray(query).get("collider") as Node


## Ray-pick against the per-part collision bodies the builder spawned. This is
## Godot's answer to three.js `Raycaster.intersectObjects` — a mesh with no
## body is invisible to the physics server, which is exactly why
## LinkageHwAssemblyBuilder gives every part one.
func _begin_pick(pos: Vector2) -> void:
	if _camera == null or _viewport == null:
		_orbiting = true
		return
	var body := _pick_body(pos)
	if body == null or not body.has_meta("part_id"):
		# Nothing under the cursor: fall through to an orbit drag, which is
		# what a click on empty space should do in a turntable view.
		_orbiting = true
		return
	_select(str(body.get_meta("part_id")), int(body.get_meta("copy_index", 0)))
	var part := LinkageHardware.find_part(_active(), _selected)
	if part.is_empty():
		return

	# The BRACKET is the biggest, most obvious thing to grab, and it is not on
	# any stack — it is what the stacks hang off. Rather than refusing in
	# silence (which reads as the drag being broken, since the part highlights
	# and then does nothing), it drags its own local nudge: exactly the
	# posX/posY/posZ the inspector already edits, written with the mouse.
	_drag_bracket = str(part.get("type", "")) == "bracket"
	if _drag_bracket:
		_drag_ctx = {}
		_drag_render_axis = ""
		var bhere := _project_pointer(pos, _bracket_move_axis(),
			_bracket_other_axis(), _bracket_nudge(part))
		if is_nan(bhere):
			return
		_drag_grab = bhere - _bracket_nudge(part).dot(_bracket_move_axis())
		_dragging = true
		_drag_snapped = false
		_update_hint()
		return

	# The axis the picked BODY was drawn along — the mirror of a `right` stack
	# renders on `left`, and measuring along the stored axis would run it
	# backwards under the cursor.
	_drag_render_axis = str(body.get_meta("render_axis", ""))
	_drag_ctx = LinkageHwLayout.part_stack_context(part, _active(),
		float(params.hardware_assemblies.get("explode", 0.0)), _selected_copy)
	if _drag_ctx.is_empty():
		# No stack context means no axis to slide along — say so rather than
		# leaving the player pressing a part that will not move.
		_flash_hint("%s is not on a stack axis — set its axis in the inspector."
			% str(part.get("label", _selected)))
		return
	if _drag_render_axis == "":
		_drag_render_axis = str(_drag_ctx["render_axis"])
	var here := _project_pointer_to_axis(pos, part, _drag_ctx, _drag_render_axis,
		_drag_cross)
	if is_nan(here):
		_flash_hint("Turn the view a little — that axis is edge-on to the camera.")
		return
	# Grab offset: how far the pointer landed from the part's current position.
	# Holding it constant is what makes the part follow the cursor rather than
	# jump its own centre under it on mouse-down.
	var current := float(part.get("crossOffset", 0.0)) if _drag_cross \
		else LinkageHwLayout.axis_pos_from_part(part, _drag_ctx)
	_drag_grab = here - current
	_dragging = true
	_drag_snapped = false


## The bracket's nudge axes, in the ASSEMBLY's local frame — the same frame
## `posX/posY/posZ` are expressed in. Shift swaps to the vertical, matching the
## axis/cross split every other part uses.
func _bracket_move_axis() -> Vector3:
	return Vector3.UP if _drag_cross else Vector3.RIGHT


func _bracket_other_axis() -> Vector3:
	return Vector3.RIGHT if _drag_cross else Vector3.UP


func _bracket_nudge(part: Dictionary) -> Vector3:
	var pr: Dictionary = part.get("params", {})
	return Vector3(float(pr.get("posX", 0.0)), float(pr.get("posY", 0.0)),
		float(pr.get("posZ", 0.0)))


## Say something, briefly, when an interaction declines. Silence is what makes
## a refusal indistinguishable from a bug.
func _flash_hint(text: String) -> void:
	if _hint == null:
		return
	_hint.text = text
	_hint.add_theme_color_override("font_color", UITheme.C_WARN)


## Project the pointer onto one of the part's two editable axes: build a plane
## that CONTAINS that axis and faces the camera as squarely as possible,
## intersect the pointer ray with it, and measure along the axis. Port of
## `hwProjectPointerToAxisPos` (hardware-detail.js:732).
##
## Returns NAN when the ray is parallel to the plane — the caller must check,
## because 0.0 is a perfectly ordinary answer here.
func _project_pointer_to_axis(pos: Vector2, part: Dictionary, ctx: Dictionary,
		render_axis: String, cross_mode: bool) -> float:
	if ctx.is_empty():
		return NAN
	var axis_l: Vector3 = LinkageHwLayout.AXIS_DIRS.get(render_axis,
		ctx.get("dir", Vector3.RIGHT))
	var cross_l: Vector3 = LinkageHwLayout.AXIS_CROSS.get(render_axis,
		ctx.get("cross", Vector3.UP))
	# Anchor the plane on the PART, not on the assembly origin. A plane through
	# the origin is the right orientation at the wrong depth, so the projection
	# drifts with the viewing angle and the part slides as the camera turns.
	var cross_in := float(part.get("crossOffset", 0.0))
	if LinkageHwLayout.HORIZONTAL_AXES.has(render_axis):
		var bracket := LinkageHardware.bracket_part(_active())
		if not bracket.is_empty():
			cross_in += LinkageHwLayout.bracket_hole_y(bracket)
	var anchor_in := axis_l * LinkageHwLayout.axis_pos_from_part(part, ctx) \
		+ cross_l * cross_in
	# Shift-drag swaps which of the two the pointer drives.
	return _project_pointer(pos, cross_l if cross_mode else axis_l,
		axis_l if cross_mode else cross_l, anchor_in)


## Pointer position along one local axis, in inches from the assembly origin.
##
## Builds a plane that CONTAINS `move_l` and faces the camera as squarely as
## possible, passing through `anchor_in` (the thing being dragged, in local
## inches), and measures the ray hit along `move_l`. Strictly 1-DOF.
##
## Returns NAN when the ray is parallel to the plane — callers MUST check,
## because 0.0 is a perfectly ordinary answer here.
func _project_pointer(pos: Vector2, move_l: Vector3, other_l: Vector3,
		anchor_in: Vector3) -> float:
	if _camera == null or _builder == null:
		return NAN
	var xform := _builder.global_transform
	var basis := xform.basis.orthonormalized()
	var move := (basis * move_l).normalized()
	var cam_fwd := -_camera.global_transform.basis.z
	var normal := move.cross(cam_fwd)
	if normal.length() < 1e-4:
		normal = move.cross(basis * other_l)
	if normal.length() < 1e-4:
		return NAN
	normal = normal.cross(move).normalized()
	var anchor: Vector3 = xform * (anchor_in * LinkageHwAssemblyBuilder.INCH_TO_M)
	var plane := Plane(normal, anchor)
	var from := _camera.project_ray_origin(pos)
	var hit = plane.intersects_ray(from, _camera.project_ray_normal(pos))
	if hit == null:
		return NAN
	# Back to inches, measured along the moving axis from the assembly origin.
	# `seat_transform` carries no scale, so this is a clean local coordinate.
	return ((hit as Vector3) - xform.origin).dot(move) \
		/ LinkageHwAssemblyBuilder.INCH_TO_M


func _drag_to(pos: Vector2) -> void:
	if _selected == "":
		return
	var asm := _active()
	var part := LinkageHardware.find_part(asm, _selected)
	if part.is_empty():
		return

	if _drag_bracket:
		var move_l := _bracket_move_axis()
		var bhere := _project_pointer(pos, move_l, _bracket_other_axis(),
			_bracket_nudge(part))
		if is_nan(bhere):
			return
		# posX on the bolt axis, posY on the vertical — the two the local frame
		# actually has room for. posZ stays inspector-only: nothing on screen
		# distinguishes it from posX at most viewing angles.
		_set_bracket_nudge(part, "posY" if _drag_cross else "posX",
			clampf(bhere - _drag_grab, -6.0, 6.0))
		_update_hint()
		return

	if _drag_ctx.is_empty():
		return
	var here := _project_pointer_to_axis(pos, part, _drag_ctx,
		_drag_render_axis, _drag_cross)
	if is_nan(here):
		return
	var want := here - _drag_grab
	if _drag_cross:
		# The cross axis has no snap planes — nothing is stacked along it.
		_set_part_field(_selected, "crossOffset", clampf(want, -6.0, 6.0),
			EDIT_TRANSFORM)
		return
	_set_offset(_selected,
		LinkageHwLayout.pos_assembled_for_axis_pos(part, _drag_ctx, want),
		not _drag_no_snap)


func _update_camera() -> void:
	if _camera == null:
		return
	var cp := Vector3(
		_dist * cos(_pitch) * sin(_yaw),
		_dist * sin(_pitch),
		_dist * cos(_pitch) * cos(_yaw))
	# look_at_from_position works before the camera enters the tree; look_at
	# does not, and errors during headless construction.
	_camera.look_at_from_position(_target + cp, _target)
