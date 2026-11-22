class_name HelpOverlayUI
extends CanvasLayer

## Controls & tips overlay. Toggle: input action `toggle_help` (default F1).
## Auto-shows once on first boot (main.gd), otherwise opened on demand.
## Key labels are read from InputMap at open time (not hardcoded) so a future
## rebind system stays truthful; reuses InteractionPromptUI's curated
## keyboard/controller labels for the handful of actions it already covers.

const _PROMPT_SCRIPT := preload("res://scenes/ui/interaction_prompt_ui.gd")

const _TIPS := [
	"Press G to open the system graph. Add a Habitat, wire water/food/energy, then start a mission (🎯 on the timeline, which shows the running one's progress).",
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
		["interact", "Aimed at a van's, bus's or trailer's door: open it and walk inside (anywhere else on it: drive)"],
		["key:Back up", "Hitch a trailer: back the vehicle's hitch slowly onto its coupler"],
		["key:Get in", "Refuel: a vehicle tops up from a fuel tank within 12 m when you get in or out"],
		["fork_raise", "Forklift: raise the forks (lift a load as they rise)"],
		["fork_lower", "Forklift: lower the forks (set a load down)"],
		["key:Deploy chip", "Vehicles drive in / out through the site gate (Deploy chip menu)"],
		["key:Packing Lab", "Load a kit into a placed vehicle's cargo bay (pick its bay, then Load)"],
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
		["toggle_globe", "Globe: the whole Earth in 3D"],
		["terrain_edit", "Edit toolbar - terrain tools (keep moving while you edit)"],
		["vegetation_edit", "Edit toolbar - vegetation tools"],
		["key:RMB", "...hold to look around while the toolbar is open"],
		["key:[ / ]", "...shrink / grow the active brush"],
		["terrain_edit_legacy", "Terrain sculpt dock (classic)"],
		["vegetation_edit_legacy", "Vegetation paint dock (classic)"],
		["vegetation_area_edit", "Vegetation area fill"],
		["placed_props_edit", "Placed props editor"],
		["toggle_solar_ui", "Solar panel HUD"],
		["toggle_projection_canvas", "Projection canvas (sim camera | live feed)"],
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
		["toggle_timeline_size", "Timeline: full / compact / hidden (also the arrows at its right end)"],
		["toggle_third_person", "First person / third-person follow camera (Settings > Player)"],
		["toggle_window_wall", "Window wall - panoramic row mode (Settings > Multi-Monitor)"],
		["key:U", "...toggle UI while the window wall is up"],
		["key:Ctrl+S", "...save this map's window-wall viewpoint"],
		["key:I", "...identify screens (window wall)"],
		["key:Settlement", "Settlement view - watch the community work (timeline chip)"],
		["key:Festival", "Festival mode - populate the camps and watch the crowd (timeline chip)"],
		["key:E", "...edit site: move / reshape camps and spaces (settlement view, Site Plan)"],
		["key:F", "...follow the selected person (settlement view)"],
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
		["toggle_pov_warp", "POV warp (your view, corner-pinned)"],
		["toggle_star_calibration", "Reference-star markers (sky alignment check)"],
		["toggle_projection_warp", "Projection canvas: warp on / off"],
		["toggle_projection_calibration", "Projection mapping: drag the corners"],
		["reset_projection_warp", "Projection mapping: reset the corners"],
	]],
]

var _rows_container: VBoxContainer = null
var _search: LineEdit = null
var _groups_flow: HFlowContainer = null
var _no_match: Control = null
## Width of one group of keys; the page shows as many columns as fit.
const GROUP_W := 430.0
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
	UiFit.keep_fitted(_panel, Vector2(560.0, 620.0))
	UiFit.set_content_column(_panel, 1380.0)  # three columns of keys, not edge to edge
	if _search != null:
		_search.text = ""
		_search.grab_focus()
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
	var tour_btn := Button.new()
	tour_btn.text = "Show me around ▶"
	tour_btn.tooltip_text = "A guided tour of this world's features: title cards, a short demo of each, Esc ends it"
	tour_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(tour_btn)
	tour_btn.pressed.connect(_on_tour_pressed)
	title_row.add_child(tour_btn)
	var close_btn := IconButton.close(close)
	title_row.add_child(close_btn)

	_search = LineEdit.new()
	_search.name = "help_search"
	_search.placeholder_text = "Find a key (graph, drone, pause…)"
	_search.clear_button_enabled = true
	_search.right_icon = UiIcons.icon("search", 14)
	_search.custom_minimum_size.x = 360
	_search.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_search.text_changed.connect(func(_t: String) -> void: _apply_search())
	outer.add_child(_search)

	var scroll := ScrollContainer.new()
	scroll.name = "scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	_rows_container = VBoxContainer.new()
	_rows_container.add_theme_constant_override("separation", UITheme.SPACE_MD)
	_rows_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_container)


func _on_tour_pressed() -> void:
	close()
	var main := get_tree().current_scene
	if main != null and main.has_method("start_feature_tour"):
		main.call("start_feature_tour")


func _rebuild_rows() -> void:
	for child in _rows_container.get_children():
		child.queue_free()

	# The keys first, a card per group, as many columns as fit.
	_groups_flow = HFlowContainer.new()
	_groups_flow.add_theme_constant_override("h_separation", UITheme.SPACE_MD)
	_groups_flow.add_theme_constant_override("v_separation", UITheme.SPACE_MD)
	_rows_container.add_child(_groups_flow)
	for group in _GROUPS:
		var group_name: String = group[0]
		var actions: Array = group[1]
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UITheme.card_style())
		card.custom_minimum_size.x = GROUP_W
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", UITheme.SPACE_XS)
		card.add_child(col)
		col.add_child(SectionHeader.make(group_name))
		for entry in actions:
			var row := _make_row(entry[0], entry[1])
			row.set_meta("find", ("%s %s" % [str(entry[1]), group_name]).to_lower())
			col.add_child(row)
		_groups_flow.add_child(card)

	# Tips: folded, after the keys.
	var tips := Collapsible.make("Tips", false, UiText.count(_TIPS.size(), "tip"))
	tips.name = "tips"
	for tip in _TIPS:
		var tip_lbl := Label.new()
		tip_lbl.text = "• %s" % tip
		tip_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tip_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		tip_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		tips.body.add_child(tip_lbl)
	_rows_container.add_child(tips)
	_no_match = null


## Rows whose name (or group) holds every typed word; empty groups go.
func _apply_search() -> void:
	if _groups_flow == null:
		return
	var words := _search.text.strip_edges().to_lower().split(" ", false)
	var any := false
	for card in _groups_flow.get_children():
		var shown := 0
		for row in (card as Control).get_child(0).get_children():
			if not (row as Node).has_meta("find"):
				continue
			var ok := true
			for w in words:
				if not (w in str((row as Node).get_meta("find"))):
					ok = false
					break
			(row as Control).visible = ok
			if ok:
				shown += 1
		(card as Control).visible = shown > 0
		any = any or shown > 0
	if is_instance_valid(_no_match):
		_no_match.queue_free()
		_no_match = null
	if not any:
		_no_match = EmptyState.make("search", "No key matches “%s”." % _search.text.strip_edges())
		_rows_container.add_child(_no_match)
		_rows_container.move_child(_no_match, 0)


func _make_row(action: String, display_label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var lbl := Label.new()
	lbl.text = display_label
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.tooltip_text = display_label
	lbl.mouse_filter = Control.MOUSE_FILTER_STOP
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
	# A key the player rebound (Settings → Controls) wins over the curated
	# text: the InputMap is what the game fires.
	if curated.has(action) and not InputOverrides.is_overridden(action):
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
