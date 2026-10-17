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
	]],
	["Interaction", [
		["interact", "Interact / pick up / use"],
		["dismount", "Exit vehicle"],
		["drone_view", "Drone view from here (again to land)"],
		["charge", "Charge battery at station"],
		["repair", "Repair structure"],
		["equip_tool", "Ready tool"],
		["unequip_tool", "Put away tool"],
	]],
	["Panels", [
		["system_graph_toggle", "System graph (wire habitat + power)"],
		["toggle_library", "Unified library (buildings / graph / veg / structures)"],
		["toggle_location_picker", "Location / map picker"],
		["terrain_edit", "Edit toolbar - terrain tools (keep moving while you edit)"],
		["vegetation_edit", "Edit toolbar - vegetation tools"],
		["key:RMB", "...hold to look around while the toolbar is open"],
		["key:[ / ]", "...shrink / grow the active brush"],
		["terrain_edit_legacy", "Terrain sculpt dock (classic)"],
		["vegetation_edit_legacy", "Vegetation paint dock (classic)"],
		["vegetation_area_edit", "Vegetation area fill"],
		["placed_props_edit", "Placed props editor"],
		["toggle_solar_ui", "Solar panel HUD"],
		["toggle_projection_canvas", "Projection canvas"],
	]],
	["Design & Analysis", [
		["toggle_site_report", "Site Report (year-round site analysis)"],
		["toggle_packing_lab", "Packing Lab (fit your camp in a truck)"],
		["toggle_linkage_lab", "Linkage Lab (folding structures designer)"],
		["toggle_scad_store", "Parametric part store (OpenSCAD)"],
		["toggle_pallet_rack", "Pallet rack builder"],
		["building_builder", "Building Builder (aim at a building first)"],
		["space_edit", "NPC area spaces (draw a plaza/zone)"],
		["camp_scatter", "Camp scatter dock"],
		["place_light", "Light Studio (omni / spot / string lights)"],
		["mp_chat", "Multiplayer chat"],
	]],
	["Views", [
		["toggle_third_person", "First person / third-person follow camera (Settings > Player)"],
		["toggle_window_wall", "Window wall - the world across your monitor row (Settings > Window Wall)"],
		["key:U", "...toggle UI while the window wall is up"],
		["key:Ctrl+S", "...save this map's window-wall viewpoint"],
		["key:I", "...identify screens (window wall)"],
	]],
	["Puzzle & SoI", [
		["interact", "SoI pin → Snowglobe (resize radius)"],
		["system_graph_toggle", "Graph / Challenges / System Review"],
		["toggle_help", "This help overlay"],
	]],
	["Time & Menus", [
		["sim_pause_toggle", "Pause / resume simulation"],
		["sim_speed_up", "Speed up time"],
		["sim_speed_down", "Slow down time"],
		["ui_cancel", "Close panel / menu"],
		["toggle_help", "Open this help"],
	]],
	# `key:` rows are hardcoded keys (no InputMap action behind them) — the
	# chip shows the literal label. Everything here worked for months as pure
	# hidden knowledge; this group is its only in-game surface.
	["Debug & Performance", [
		["key:F3", "Performance HUD (per-system timings)"],
		["key:F4", "Node histogram dump (to console)"],
		["key:F7", "Vegetation shadow A/B toggle"],
		["key:Shift+F7", "Hide all trees (perf diagnosis)"],
		["key:Ctrl+F7", "Cycle 3D render scale"],
		["toggle_pov_warp", "POV warp overlay"],
		["toggle_star_calibration", "Reference-star markers (sky alignment check)"],
		["toggle_projection_warp", "Projection warp (StarShade)"],
		["toggle_projection_calibration", "Projection calibration"],
		["reset_projection_warp", "Reset projection warp"],
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
	HudLayout.claim_modal("help_overlay")


func close() -> void:
	if not visible:
		return
	visible = false
	CursorController.release_modal("help_overlay")
	HudLayout.release("help_overlay")


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
	var close_btn := IconButton.close(close)
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

	_rows_container.add_child(SectionHeader.make("Tips"))
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
		_rows_container.add_child(SectionHeader.make(group_name))
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
	if action.begins_with("key:"):
		row.add_child(_make_key_chip(action.trim_prefix("key:")))
		return row
	var kb := _keyboard_label(action)
	var controller := _controller_label(action)
	# A bare "—" chip reads as broken; controller-only actions say so.
	if kb == "—" and not controller.is_empty() and controller != "—":
		kb = "pad only"
	row.add_child(_make_key_chip(kb))
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
				# Modifiers are part of the binding: the toolbar keeps the
				# classic docks on Shift+T / Shift+V, and without this both
				# rows render as a bare "T" with different descriptions.
				var mods := ""
				if key_ev.ctrl_pressed:
					mods += "Ctrl+"
				if key_ev.shift_pressed:
					mods += "Shift+"
				if key_ev.alt_pressed:
					mods += "Alt+"
				return mods + OS.get_keycode_string(code)
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
