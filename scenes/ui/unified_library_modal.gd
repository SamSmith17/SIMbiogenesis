extends Control
class_name UnifiedLibraryModal

## Unified Library browser (Wave 7) — Buildings / Graph nodes / Vegetation /
## Structures. Aggregates ModelCatalog, ComponentPresets, and veg/building
## entry points. Selecting an item routes into the existing placement or
## editor flow. Open via timeline 📦 or input action `toggle_library` (U).

const MODAL_NAME := "unified_library"
const SCRIPT_PATH := "res://scenes/ui/unified_library_modal.gd"

const C_BG := UITheme.C_BG
const C_PANEL := UITheme.C_PANEL
const C_BORDER := UITheme.C_BORDER
const C_PRIMARY := UITheme.C_PRIMARY
const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S

var _loader: Node = null
var _active := false
var _dim: ColorRect = null
var _panel: PanelContainer = null
var _tabs: TabContainer = null
var _search: LineEdit = null
var _lists: Dictionary = {}   # tab_name -> ItemList
var _entries: Dictionary = {} # tab_name -> Array[Dictionary] (full)
var _filtered: Dictionary = {} # tab_name -> Array[Dictionary] (visible)
var _status: Label = null
var _detail: Label = null
var _use_btn: Button = null
var _place_btn: Button = null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	process_mode = Node.PROCESS_MODE_ALWAYS


func _unhandled_input(event: InputEvent) -> void:
	if not InputMap.has_action("toggle_library"):
		return
	if not event.is_action_pressed("toggle_library"):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is CodeEdit:
		return
	toggle()
	get_viewport().set_input_as_handled()


func bind_loader(loader: Node) -> void:
	_loader = loader


func toggle() -> void:
	if _active:
		close()
	else:
		open()


func open(tab: String = "") -> void:
	_resolve_loader()
	_populate()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	if not tab.is_empty() and _tabs != null:
		for i in _tabs.get_tab_count():
			if _tabs.get_tab_title(i).to_lower().begins_with(tab.to_lower()):
				_tabs.current_tab = i
				break
	_refresh_action_buttons()
	if _search != null:
		_search.grab_focus()


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	CursorController.release_modal(MODAL_NAME)


func _resolve_loader() -> void:
	if is_instance_valid(_loader):
		return
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		return
	_loader = main.get_node_or_null("TerrainLoader")
	if _loader == null:
		_loader = TerrainSurfaceQuery.find_terrain_loader(main)


func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(C_BG, 0.85)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			close())
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(720, 520)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_panel.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(header)
	var title := Label.new()
	title.text = "Library"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", C_TEXT)
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.tooltip_text = "Close library (Esc / U)"
	UITheme.style_button(close_btn)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_search = LineEdit.new()
	_search.placeholder_text = "Filter… (name, type, model id)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String) -> void: _apply_filter())
	root.add_child(_search)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.custom_minimum_size.y = 340
	_tabs.tab_changed.connect(func(_i: int) -> void: _refresh_action_buttons())
	root.add_child(_tabs)

	for tab_name in ["Building", "Graph nodes", "Vegetation", "Structures"]:
		var page := VBoxContainer.new()
		page.name = tab_name
		page.add_theme_constant_override("separation", UITheme.SPACE_SM)
		_tabs.add_child(page)
		var list := ItemList.new()
		list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		list.custom_minimum_size.y = 280
		list.allow_reselect = true
		list.item_selected.connect(func(_i: int) -> void: _refresh_action_buttons())
		list.item_activated.connect(func(i: int) -> void: _activate_entry(tab_name, i, false, true))
		page.add_child(list)
		_lists[tab_name] = list

	_detail = Label.new()
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_theme_color_override("font_color", C_TEXT_S)
	_detail.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_detail.custom_minimum_size.y = 36
	root.add_child(_detail)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(actions)
	_use_btn = Button.new()
	_use_btn.text = "Use selected"
	_use_btn.focus_mode = Control.FOCUS_NONE
	_use_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(_use_btn)
	_use_btn.add_theme_color_override("font_color", C_PRIMARY)
	_use_btn.pressed.connect(func() -> void: _activate_selected(false))
	actions.add_child(_use_btn)
	_place_btn = Button.new()
	_place_btn.text = "Place in world"
	_place_btn.focus_mode = Control.FOCUS_NONE
	_place_btn.visible = false
	UITheme.style_button(_place_btn)
	_place_btn.pressed.connect(func() -> void: _activate_selected(true))
	actions.add_child(_place_btn)

	_status = Label.new()
	_status.add_theme_color_override("font_color", C_TEXT_S)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	root.add_child(_status)


func _populate() -> void:
	_entries.clear()

	var buildings: Array = [
		{
			"kind": "building_library",
			"label": "Building library (styles & models)…",
			"detail": "Open the OSM building style browser / model catalog.",
		},
		{
			"kind": "building_key",
			"label": "Edit focused building (B)",
			"detail": "Customize the building under the crosshair (or open the library if none).",
		},
	]
	_entries["Building"] = buildings

	var graph: Array = []
	for cat in ComponentPresets.CATEGORIES:
		var cid := str(cat.get("id", ""))
		var clabel := str(cat.get("label", cid))
		for p in ComponentPresets.presets_for_category(cid):
			if not (p is Dictionary):
				continue
			var pd: Dictionary = p
			var specs: Dictionary = pd.get("specs", {}) as Dictionary
			var mid := str(specs.get("model_id", ""))
			var label := "%s — %s" % [clabel, str(pd.get("label", "?"))]
			if not mid.is_empty():
				label += "  ·  3D"
			graph.append({
				"kind": "graph_preset",
				"label": label,
				"detail": _graph_detail(pd),
				"preset": pd,
				"model_id": mid,
			})
	_entries["Graph nodes"] = graph

	var veg: Array = [
		{
			"kind": "veg_paint",
			"label": "Open vegetation paint (V)…",
			"detail": "Paint / place / clear vegetation on the map.",
		},
		{
			"kind": "veg_tune",
			"label": "Tune look…",
			"detail": "Live SubViewport studio for species shape, tint, and shaders.",
		},
	]
	for sid in VegetationCardFactory.SPECS.keys():
		veg.append({
			"kind": "veg_species",
			"label": "Species: %s" % sid,
			"detail": "Open Tune look with this species in mind.",
			"species": sid,
		})
	_entries["Vegetation"] = veg

	var structs: Array = [
		{
			"kind": "pallet_rack",
			"label": "Pallet rack builder…",
			"detail": "Parametric rack → place as a structure.",
		},
		{
			"kind": "linkage_lab",
			"label": "Linkage Lab… (N)",
			"detail": "Design folding scissor-linkage structures (StarShade designer).",
		},
		{
			"kind": "mud_building",
			"label": "Mud Building Designer…",
			"detail": "Sketch wall plans → dual-perimeter mud print on the gantry.",
		},
		{
			"kind": "starshade_place",
			"label": "Place StarShade",
			"detail": "Ghost-place the default StarShade canopy.",
			"model_id": "starshade",
		},
		{
			"kind": "structure",
			"label": "Grow Bed",
			"detail": "Procedural raised bed — also available under Graph → Grow Beds (Place).",
			"model_id": GrowBed.MODEL_ID,
		},
	]
	var seen: Dictionary = {GrowBed.MODEL_ID: true, "starshade": true,
		ModelCatalog.GENERIC_BOX_ID: true}
	for m in ModelCatalog.all_models():
		var mid := str(m.get("id", ""))
		if mid.is_empty() or seen.has(mid):
			continue
		seen[mid] = true
		var cat := str(m.get("category", ""))
		var prefix := ""
		if cat == "nature":
			prefix = "Nature: "
		elif str(m.get("source", "")) == "user" or mid.begins_with("user_"):
			prefix = "User: "
		elif cat != "structures":
			prefix = "%s: " % cat.capitalize() if not cat.is_empty() else ""
		structs.append({
			"kind": "structure",
			"label": "%s%s" % [prefix, str(m.get("label", mid))],
			"detail": "Place %s in the world (move/edit like other props)." % mid,
			"model_id": mid,
		})
	_entries["Structures"] = structs

	_apply_filter()
	_status.text = "Pick an item → Use selected (double-click). 3D-linked graph nodes also offer Place in world."


func _graph_detail(preset: Dictionary) -> String:
	var specs: Dictionary = preset.get("specs", {}) as Dictionary
	var bits: PackedStringArray = []
	bits.append("type=%s" % str(preset.get("type", "?")))
	var mid := str(specs.get("model_id", ""))
	if not mid.is_empty():
		bits.append("model=%s" % mid)
	var name := str(specs.get("name", ""))
	if not name.is_empty():
		bits.append(name)
	return " · ".join(bits)


func _apply_filter() -> void:
	var q := ""
	if _search != null:
		q = _search.text.strip_edges().to_lower()
	_filtered.clear()
	for tab_name in _entries.keys():
		var src: Array = _entries[tab_name] as Array
		var out: Array = []
		for it in src:
			if not (it is Dictionary):
				continue
			var d: Dictionary = it
			if q.is_empty() or _entry_matches(d, q):
				out.append(d)
		_filtered[tab_name] = out
		var list: ItemList = _lists.get(tab_name) as ItemList
		if list == null:
			continue
		list.clear()
		for it2 in out:
			list.add_item(str((it2 as Dictionary).get("label", "?")))
	_refresh_action_buttons()


func _entry_matches(e: Dictionary, q: String) -> bool:
	for key in ["label", "detail", "model_id", "species", "kind"]:
		if q in str(e.get(key, "")).to_lower():
			return true
	var preset: Variant = e.get("preset", {})
	if preset is Dictionary:
		var p: Dictionary = preset
		if q in str(p.get("label", "")).to_lower():
			return true
		if q in str(p.get("type", "")).to_lower():
			return true
		var specs: Dictionary = p.get("specs", {}) as Dictionary
		if q in str(specs.get("name", "")).to_lower():
			return true
		if q in str(specs.get("model_id", "")).to_lower():
			return true
	return false


func _current_tab_name() -> String:
	if _tabs == null or _tabs.get_tab_count() <= 0:
		return ""
	return _tabs.get_tab_title(_tabs.current_tab)


func _selected_entry() -> Dictionary:
	var tab_name := _current_tab_name()
	var list: ItemList = _lists.get(tab_name) as ItemList
	if list == null:
		return {}
	var sel := list.get_selected_items()
	if sel.is_empty():
		return {}
	var items: Array = _filtered.get(tab_name, []) as Array
	var idx: int = sel[0]
	if idx < 0 or idx >= items.size():
		return {}
	return items[idx] as Dictionary


func _refresh_action_buttons() -> void:
	if _detail == null or _use_btn == null or _place_btn == null:
		return  # tab_changed can fire mid-_build_ui before widgets exist
	var e := _selected_entry()
	if e.is_empty():
		_detail.text = "Select an entry to see details."
		_use_btn.disabled = true
		_place_btn.visible = false
		return
	_use_btn.disabled = false
	_detail.text = str(e.get("detail", e.get("label", "")))
	var can_place := _entry_can_place(e)
	_place_btn.visible = can_place
	if can_place and str(e.get("kind", "")) == "graph_preset":
		_use_btn.text = "Add to graph"
		_place_btn.text = "Place in world"
	elif can_place:
		_use_btn.text = "Place in world"
		_place_btn.visible = false
	else:
		_use_btn.text = "Use selected"


func _entry_can_place(e: Dictionary) -> bool:
	var kind := str(e.get("kind", ""))
	if kind in ["structure", "starshade_place", "pallet_rack"]:
		return true
	if kind == "graph_preset":
		# Any non-component graph preset can be placed (a bespoke GLB if it has
		# one, else a gray-box placeholder — F).
		return not _preset_is_component(e.get("preset", {}) as Dictionary)
	return false


## True for a compound/super-node preset (spawns a subgraph, not a single prop).
func _preset_is_component(preset: Dictionary) -> bool:
	if str(preset.get("type", "")) == "compound":
		return true
	return preset.has("component_tree") or preset.has("definition_id") \
			or preset.has("def_id")


func _activate_selected(force_place: bool) -> void:
	var tab_name := _current_tab_name()
	var list: ItemList = _lists.get(tab_name) as ItemList
	if list == null:
		return
	var sel := list.get_selected_items()
	if sel.is_empty():
		_status.text = "Select an item first."
		return
	_activate_entry(tab_name, sel[0], force_place, false)


func _activate_entry(tab_name: String, idx: int, force_place: bool, from_double_click: bool) -> void:
	var items: Array = _filtered.get(tab_name, []) as Array
	if idx < 0 or idx >= items.size():
		return
	var e: Dictionary = items[idx]
	var kind := str(e.get("kind", ""))
	match kind:
		"building_library":
			_open_building(-1)
		"building_key":
			var bidx := -1
			if _loader != null and _loader.has_method("get_building_focus_idx"):
				bidx = int(_loader.call("get_building_focus_idx"))
			_open_building(bidx if bidx >= 0 else -1)
		"graph_preset":
			var preset: Dictionary = e.get("preset", {}) as Dictionary
			# Place button, or double-click on any placeable preset (bespoke GLB
			# or gray-box placeholder) → world placement.
			if force_place or (from_double_click and _entry_can_place(e)):
				_place_graph_preset(preset)
			else:
				_spawn_graph_preset(preset)
		"veg_paint":
			_open_veg_paint()
		"veg_tune", "veg_species":
			_open_veg_tune(str(e.get("species", "")))
		"pallet_rack":
			if _loader != null and _loader.has_method("open_pallet_rack_builder"):
				_loader.call("open_pallet_rack_builder")
				close()
			else:
				_status.text = "Pallet rack builder needs a location map (TerrainLoader)."
		"linkage_lab":
			var main_node := get_tree().current_scene if get_tree() != null else null
			if main_node != null and main_node.has_method("open_linkage_lab"):
				main_node.call("open_linkage_lab")
				close()
			else:
				_status.text = "Linkage Lab unavailable on this scene."
		"mud_building":
			var sgv := get_tree().root.find_child("SystemGraphView", true, false) if get_tree() != null else null
			if sgv != null and sgv.has_method("open_mud_building_designer"):
				sgv.call("open_mud_building_designer", "")
				close()
			else:
				_status.text = "Mud Building Designer unavailable on this scene."
		"starshade_place", "structure":
			_place_structure(str(e.get("model_id", "")))
		_:
			_status.text = "Unknown entry"


func _open_building(building_idx: int) -> void:
	if _loader != null and _loader.has_method("open_building_builder"):
		_loader.call("open_building_builder", building_idx)
		close()
		return
	_status.text = "Building tools need a location map with OSM buildings."


func _open_veg_paint() -> void:
	if _loader != null:
		var vui = _loader.get("_vegetation_edit_ui")
		if vui != null and vui.has_method("toggle_mode"):
			if not bool(vui.visible):
				vui.toggle_mode()
			close()
			return
	_status.text = "Vegetation paint needs a location map (press V when TerrainLoader is present)."


func _open_veg_tune(species_hint: String) -> void:
	if _loader != null and _loader.has_method("open_vegetation_preview_editor"):
		_loader.call("open_vegetation_preview_editor", -1)
		if not species_hint.is_empty():
			_status.text = "Opened Tune look (%s)" % species_hint
		close()
		return
	_status.text = "Tune look needs a location map."


func _place_structure(model_id: String) -> void:
	if model_id.is_empty():
		_status.text = "Missing model id"
		return
	if model_id == PalletRackBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_pallet_rack_builder"):
			_loader.call("open_pallet_rack_builder")
			close()
			return
	if _loader != null and _loader.has_method("begin_structure_placement"):
		if bool(_loader.call("begin_structure_placement", model_id)):
			close()
			return
	# Fallback without TerrainLoader UI: start ghost placement via service.
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		_status.text = "No scene to place into"
		return
	var r: Dictionary = PlacedPropService.begin_placement(main, model_id)
	if not bool(r.get("ok", false)):
		_status.text = "Could not start placement: %s" % str(r.get("error", "?"))
		return
	var ppui := main.get_node_or_null("UILayer/PlacedPropsUI")
	if ppui != null and ppui.has_method("notify_bundle_imported"):
		ppui.call("notify_bundle_imported", r)
	elif _loader != null and _loader.has_method("notify_external_placement_started"):
		_loader.call("notify_external_placement_started", r)
	close()


func _spawn_graph_preset(preset: Dictionary) -> void:
	if preset.is_empty():
		return
	var sgv := _find_system_graph()
	if sgv == null:
		_status.text = "System graph missing from scene"
		return
	if not bool(sgv.visible):
		if sgv.has_method("toggle"):
			sgv.call("toggle")
		elif sgv.has_method("set_open"):
			sgv.call("set_open", true)
	if sgv.has_method("_spawn_at_canvas_center"):
		sgv.call("_spawn_at_canvas_center", preset)
		_status.text = "Spawned %s on the graph" % str(preset.get("label", "?"))
		close()
		return
	_status.text = "Could not spawn graph preset"


func _place_graph_preset(preset: Dictionary) -> void:
	if preset.is_empty():
		return
	# Components can't be placed as a single prop — spawn the subgraph instead.
	if _preset_is_component(preset):
		_spawn_graph_preset(preset)
		return
	var sgv := _find_system_graph()
	# Route through the graph view (defaults an empty model_id to a gray-box
	# placeholder + binds the spawned node to the placed prop — F/D).
	if sgv != null and sgv.has_method("_on_lib_place_model_requested"):
		sgv.call("_on_lib_place_model_requested", preset)
		close()
		return
	# Fallback: only a real GLB can be placed without the graph view.
	var specs: Dictionary = preset.get("specs", {}) as Dictionary
	if str(specs.get("model_id", "")).is_empty():
		_spawn_graph_preset(preset)
		return
	_place_structure(str(specs.get("model_id", "")))


func _find_system_graph() -> Node:
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		return null
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	return sgv
