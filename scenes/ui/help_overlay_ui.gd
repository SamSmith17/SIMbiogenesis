class_name HelpOverlayUI
extends CanvasLayer

## Controls & tips overlay. Toggle: input action `toggle_help` (default F1).
## Auto-shows once on first boot (main.gd), otherwise opened on demand.
## Key labels are read from InputMap at open time (not hardcoded) so a future
## rebind system stays truthful; reuses InteractionPromptUI's curated
## keyboard/controller labels for the handful of actions it already covers.

const _PROMPT_SCRIPT := preload("res://scenes/ui/interaction_prompt_ui.gd")

const _TIPS := [
	"Press G to open the system graph. Add a Habitat, wire water/food/energy, then start a Challenge (🎯).",
	"Press U (or 📦 on the timeline) for the Library — place structures, grow beds, graph nodes, and veg tools.",
	"Interact with the SoI map pin (O) to open Snowglobe — drag the Radius slider to expand your stewardship volume.",
	"Needs chips (⚡💧🍎♻) show closure health: ● OK · ▲ warn · ■ critical. Click any chip for System Review.",
	"Terrain, imagery, and vegetation load automatically for whatever location you pick — the first visit is slower, later visits use the cache.",
	"Aim your crosshair at an OSM solar array and press Interact to add it to your power grid.",
	"Vegetation (V): hold LMB with Brush to stamp continuously; pick a subspecies under Type; Tune look… to edit H/W and Save as species default.",
	"Terrain (T): Pond — lasso the water's edge, set Dig depth, and it carves a bowl and fills to the natural rim in one action.",
	"Terrain (T): Flatten — draw a selection to level a whole pad to the ground at its centre (feathered at the edges); brushes drive a high-res edit layer.",
	"Terrain (T): Ramp — click a start then an end to grade a road/path between them; Measure — click two points for distance, elevation drop, and % grade.",
	"Terrain (T): Top-down shows live elevation contours; the dock reads out cut/fill volume as you sculpt. Ctrl+Z undoes the last edit.",
]

## [action, display_label]
const _GROUPS := [
	["Movement", [
		["move_forward", "Move forward"],
		["move_back", "Move back"],
		["move_left", "Strafe left"],
		["move_right", "Strafe right"],
		["sprint", "Sprint"],
		["toggle_camera", "Toggle camera view"],
	]],
	["Interaction", [
		["interact", "Interact / pick up / use"],
		["dismount", "Exit vehicle"],
		["charge", "Charge battery at station"],
		["repair", "Repair structure"],
		["equip_tool", "Ready tool"],
		["unequip_tool", "Put away tool"],
	]],
	["Panels", [
		["system_graph_toggle", "System graph (wire habitat + power)"],
		["toggle_library", "Unified library (buildings / graph / veg / structures)"],
		["toggle_location_picker", "Location / map picker"],
		["vegetation_edit", "Vegetation paint dock"],
		["terrain_edit", "Terrain sculpt dock"],
		["placed_props_edit", "Placed props editor"],
		["toggle_projection_canvas", "Projection canvas"],
	]],
	["Puzzle & SoI", [
		["interact", "SoI pin → Snowglobe (resize radius)"],
		["system_graph_toggle", "Graph / Challenges / System Review"],
		["toggle_help", "This help overlay"],
	]],
	["Time & Menus", [
		["sim_pause_toggle", "Pause / resume simulation"],
		["ui_cancel", "Close panel / menu"],
		["toggle_help", "Open this help"],
	]],
]

var _rows_container: VBoxContainer = null
var _panel: PanelContainer = null


func _ready() -> void:
	layer = UITheme.LAYER_MODAL
	visible = false
	_build_ui()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("toggle_help"):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is CodeEdit:
		return
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	_rebuild_rows()
	visible = true
	UiScreenLayout.clamped_center(_panel, Vector2(560.0, 620.0))
	CursorController.request_modal("help_overlay", Callable(self, "close"))


func close() -> void:
	if not visible:
		return
	visible = false
	CursorController.release_modal("help_overlay")


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITheme.SPACE_LG)
	margin.add_theme_constant_override("margin_right", UITheme.SPACE_LG)
	margin.add_theme_constant_override("margin_top", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", UITheme.SPACE_MD)
	_panel.add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", UITheme.SPACE_SM)
	margin.add_child(outer)

	var title_row := HBoxContainer.new()
	outer.add_child(title_row)
	var title_lbl := Label.new()
	title_lbl.text = "Controls & Tips"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	title_row.add_child(title_lbl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	close_btn.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	close_btn.pressed.connect(close)
	title_row.add_child(close_btn)

	outer.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	_rows_container = VBoxContainer.new()
	_rows_container.add_theme_constant_override("separation", UITheme.SPACE_MD)
	_rows_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_container)


func _rebuild_rows() -> void:
	for child in _rows_container.get_children():
		child.queue_free()

	var tips_lbl := Label.new()
	tips_lbl.text = "TIPS"
	tips_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	tips_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_rows_container.add_child(tips_lbl)
	for tip in _TIPS:
		var tip_lbl := Label.new()
		tip_lbl.text = "• %s" % tip
		tip_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tip_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		tip_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_rows_container.add_child(tip_lbl)
	_rows_container.add_child(HSeparator.new())

	for group in _GROUPS:
		var group_name: String = group[0]
		var actions: Array = group[1]
		var section_lbl := Label.new()
		section_lbl.text = group_name.to_upper()
		section_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		section_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_rows_container.add_child(section_lbl)
		for entry in actions:
			_rows_container.add_child(_make_row(entry[0], entry[1]))


func _make_row(action: String, display_label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var lbl := Label.new()
	lbl.text = display_label
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(lbl)
	row.add_child(_make_key_chip(_keyboard_label(action)))
	var controller := _controller_label(action)
	if not controller.is_empty() and controller != "—":
		row.add_child(_make_key_chip(controller))
	return row


func _make_key_chip(text: String) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", UITheme.chip_style(UITheme.C_INFO))
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.add_theme_color_override("font_color", UITheme.C_INFO)
	chip.add_child(lbl)
	return chip


func _keyboard_label(action: String) -> String:
	var curated: Dictionary = _PROMPT_SCRIPT.KEYBOARD_LABELS
	if curated.has(action):
		return curated[action]
	if not InputMap.has_action(action):
		return "—"
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			var key_ev := ev as InputEventKey
			var code := key_ev.physical_keycode if key_ev.physical_keycode != 0 else key_ev.keycode
			if code != 0:
				return OS.get_keycode_string(code)
	return "—"


func _controller_label(action: String) -> String:
	var curated: Dictionary = _PROMPT_SCRIPT.CONTROLLER_LABELS
	if curated.has(action):
		return curated[action]
	if not InputMap.has_action(action):
		return "—"
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			return "Pad %d" % (ev as InputEventJoypadButton).button_index
	return "—"
