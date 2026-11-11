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
var _search: LineEdit = null
var _chips: Dictionary = {}      # section -> Button
var _sections: Dictionary = {}   # section -> {box, header, built}
var _entries: Dictionary = {}    # section -> Array[Dictionary]
var _section := "Designers"
var _body: VBoxContainer = null
var _scroll: ScrollContainer = null
var _empty: Control = null
var _status: Label = null
var _thumbs: ThumbRenderer = null

## The page's sections, in order. `big` cards carry a picture on top.
const SECTIONS := [
	{"id": "Designers", "icon": "pencil", "big": true, "note": "Make your own, then place it"},
	{"id": "Structures", "icon": "box", "big": true, "note": "Ready-made things to place in the world"},
	{"id": "Vehicles", "icon": "truck", "big": true, "note": "Place one, walk up and drive"},
	{"id": "Graph nodes", "icon": "workflow", "big": false, "note": "Parts of the systems graph"},
	{"id": "Vegetation", "icon": "trees", "big": false, "note": "Paint plants and tune how they look"},
	{"id": "Buildings", "icon": "house", "big": false, "note": "The map's buildings"},
]
const CARD_W := 232.0
const PIC_H := 124.0
const ROW_W := 352.0

## A picture for each graph category with no 3D model.
const CATEGORY_ICONS := {
	"pbis": "globe", "my_components": "layers", "supernodes": "layers", "panels": "sun",
	"wind": "wind", "hydro": "waves", "batteries": "battery", "controllers": "cpu",
	"appliances": "plug", "habitats": "users", "processors": "workflow", "csp": "sun",
	"tools": "wrench", "resources": "droplet", "catchments": "cloud-rain", "plants": "sprout",
	"monitors": "gauge",
}


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


## `tab` names a section by its first letters ("Vehicles", "struct", "Building").
func open(tab: String = "") -> void:
	_resolve_loader()
	_populate()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	if not tab.is_empty():
		var t := tab.to_lower()
		for sec in SECTIONS:
			var sid := str(sec["id"]).to_lower()
			if sid.begins_with(t) or t.begins_with(sid.trim_suffix("s")):
				_section = str(sec["id"])
				break
	if _search != null:
		_search.text = ""
	_show_sections()
	if _search != null:
		_search.grab_focus()


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _thumbs != null:
		_thumbs.clear_queue()
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
	_panel.custom_minimum_size = Vector2(960, 620)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	add_child(_panel)
	UiFit.adopt(_panel)
	UiFit.set_content_column(_panel, 1500.0)  # a page of cards, not edge to edge

	_thumbs = ThumbRenderer.make("library")
	_panel.add_child(_thumbs)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_panel.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UITheme.SPACE_MD)
	root.add_child(header)
	var title := Label.new()
	title.text = "Library"
	title.add_theme_color_override("font_color", C_TEXT)
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	header.add_child(title)
	_search = LineEdit.new()
	_search.name = "library_search"
	_search.placeholder_text = "Search everything (dome, battery, bus, maple…)"
	_search.clear_button_enabled = true
	_search.right_icon = UiIcons.icon("search", 14)
	_search.custom_minimum_size.x = 420
	_search.text_changed.connect(func(_t: String) -> void: _show_sections())
	header.add_child(_search)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(gap)
	header.add_child(IconButton.close(close, "Close library (Esc / U)"))

	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", UITheme.SPACE_XS)
	root.add_child(chips)
	for sec in SECTIONS:
		var sid := str(sec["id"])
		var b := IconButton.make(str(sec["icon"]), str(sec["note"]), Callable(), sid)
		b.name = "section_%s" % sid.to_lower().replace(" ", "_")
		b.flat = false
		b.toggle_mode = true
		UITheme.style_button(b)
		b.pressed.connect(func() -> void:
			_section = sid
			_search.text = ""
			_show_sections())
		chips.add_child(b)
		_chips[sid] = b

	_scroll = ScrollContainer.new()
	_scroll.name = "scroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", UITheme.SPACE_MD)
	_scroll.add_child(_body)

	_status = Label.new()
	_status.add_theme_color_override("font_color", C_TEXT_S)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	root.add_child(_status)


func _designer(kind: String, label: String, detail: String, model_id: String, icon: String = "pencil") -> Dictionary:
	return {"kind": kind, "label": label, "detail": detail, "pic_model": model_id, "icon": icon, "verb": "Design…"}


func _populate() -> void:
	_entries.clear()
	for sid in _sections:
		var sec: Dictionary = _sections[sid]
		if is_instance_valid(sec.get("box")):
			(sec["box"] as Node).queue_free()
	_sections.clear()
	if _thumbs != null:
		_thumbs.clear_queue()

	_entries["Buildings"] = [
		{"kind": "building_library", "label": "Building library", "verb": "Open", "icon": "house",
			"detail": "Styles and models for the map's buildings."},
		{"kind": "building_key", "label": "Edit the building I am looking at", "verb": "Edit", "icon": "pencil",
			"detail": "The building under the crosshair (B), or start a new house."},
	]

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
			graph.append({
				"kind": "graph_preset",
				"label": str(pd.get("label", "?")),
				"group": clabel,
				"detail": _graph_detail(pd, clabel),
				"preset": pd,
				"model_id": mid,
				"pic_model": mid,
				"icon": str(CATEGORY_ICONS.get(cid, "workflow")),
				"verb": "Add to graph",
			})
	_entries["Graph nodes"] = graph

	var veg: Array = [
		{"kind": "veg_paint", "label": "Paint vegetation", "verb": "Open", "icon": "sprout",
			"detail": "Paint, place and clear plants on the map (V)."},
		{"kind": "veg_tune", "label": "Tune look", "verb": "Open", "icon": "sliders-horizontal",
			"detail": "Shape, colour and leaves of each species, in a studio."},
	]
	for sid in VegetationCardFactory.SPECS.keys():
		veg.append({
			"kind": "veg_species",
			"label": UiText.from_id(str(sid)),
			"group": "Species",
			"detail": "Open Tune look on this species.",
			"species": sid,
			"icon": "trees",
			"verb": "Tune look",
		})
	_entries["Vegetation"] = veg

	var designers: Array = [
		_designer("building_designer", "Building designer",
			"A house from a footprint: walls, roof, doors, windows, porch and lights.", "", "house"),
		_designer("pallet_rack", "Pallet rack builder",
			"Buildings from pallet racking: decks, stairs, walls, solar slopes.", PalletRackBuilder.MODEL_ID),
		_designer("flatpack", "Flat-pack furniture",
			"Slotted plywood sofas, benches, tables and chairs, with CNC cut files.", FlatpackBuilder.MODEL_ID),
		_designer("domelab", "Domes and zomes",
			"Geodesic domes, zomes and helix zomes: struts, hubs, plates, cut files.", DomeLabBuilder.MODEL_ID),
		_designer("toroidlab", "Toroids",
			"Bent-tube toroids on pipe fittings with a pleated canopy and a solar ring.", ToroidLabBuilder.MODEL_ID),
		_designer("linkage_lab", "Linkage Lab",
			"Folding scissor-linkage structures (the StarShade designer). Key: N.", "linkage_structure"),
		_designer("pvlab", "Solar arrays",
			"Your real panels on racks or a tracker, wired in strings with live output.", PvLabBuilder.MODEL_ID, "sun"),
		_designer("csplab", "Solar concentrators",
			"Lenses and mirrors: ray trace, suns, heat through a year, tracking structure.", "csplab_concentrator", "sun"),
		_designer("farmbotlab", "Garden robots (FarmBot)",
			"A gantry robot on a raised bed of any size: crop mix, packing, its day move by move, labour saved vs cost.", "farmbot", "sprout"),
		_designer("windlab", "Wind turbines",
			"Seven rotor types, generator matching, power curve, cut and print files.", "windlab_turbine", "wind"),
		_designer("peltonlab", "Pelton wheels",
			"Micro-hydro turbines round the standard cup: speed, power, strength checks.", "peltonlab_turbine", "waves"),
		_designer("gantrylab", "CNC gantries",
			"Printers, routers, lasers and plotters on V-slot, with a motion sim and BOM.", GantryLabBuilder.MODEL_ID, "cpu"),
		_designer("tclab", "Tri-clamp assemblies",
			"Sanitary fittings snapped into process runs: reactors, stills, kettles.", "tclab_biochar_reactor", "workflow"),
		_designer("esplab", "ESP sensor boards",
			"Pick a board, add sensors; it wires them and writes the ESPHome YAML.", "esplab_board", "cpu"),
		_designer("earthship", "Earthships",
			"Tyre-wall rooms sunk into the ground behind a sloped greenhouse; digs and berms the site.",
			EarthshipBuilder.MODEL_ID, "house"),
		_designer("intermodal", "Containers and pallets",
			"Containers, pallets, IBC totes, drums and rack bays to place or pack into.", "cargo_container", "package"),
		_designer("vehiclelab", "Living vehicles",
			"Vans, buses, RVs, trucks and trailers people live in. Place and drive.", "vehiclelab_van", "truck"),
		_designer("mud_building", "Mud buildings",
			"Sketch a wall plan; the gantry prints it in mud.", "", "house"),
	]
	_entries["Designers"] = designers

	var structs: Array = [
		{"kind": "starshade_place", "label": "StarShade", "detail": "The folding solar canopy.",
			"model_id": "starshade", "pic_model": "starshade", "verb": "Place"},
		{"kind": "structure", "label": "Grow Bed", "detail": "A raised bed. Also under Graph nodes, Grow Beds.",
			"model_id": GrowBed.MODEL_ID, "pic_model": GrowBed.MODEL_ID, "verb": "Place"},
	]
	var seen: Dictionary = {GrowBed.MODEL_ID: true, "starshade": true,
		ModelCatalog.GENERIC_BOX_ID: true}
	var vehicles: Array = []
	for m in ModelCatalog.listed_models():
		var mid := str(m.get("id", ""))
		if mid.is_empty() or seen.has(mid):
			continue
		seen[mid] = true
		var cat := str(m.get("category", ""))
		if not PlacedVehicle.profile_for_model(mid).is_empty():
			vehicles.append({
				"kind": "structure",
				"label": str(m.get("label", mid)).trim_prefix("Living vehicle: "),
				"detail": "Place it, walk up and Interact to drive (X gets out).",
				"model_id": mid, "pic_model": mid, "icon": "truck", "verb": "Place",
			})
			continue
		var group := "Structures"
		if cat == "nature":
			group = "Nature"
		elif str(m.get("source", "")) == "user" or mid.begins_with("user_"):
			group = "Your models"
		elif cat != "structures" and not cat.is_empty():
			group = cat.capitalize()
		structs.append({
			"kind": "structure",
			"label": str(m.get("label", mid)),
			"group": group,
			"detail": "Place in the world; click it later to move or edit.",
			"model_id": mid, "pic_model": mid, "verb": "Place",
		})
	_entries["Structures"] = structs
	_entries["Vehicles"] = vehicles
	_status.text = ""


func _graph_detail(preset: Dictionary, category: String) -> String:
	var specs: Dictionary = preset.get("specs", {}) as Dictionary
	var bits: PackedStringArray = [category]
	if not str(specs.get("model_id", "")).is_empty():
		bits.append("has a 3D model")
	return " · ".join(bits)


func _entry_matches(e: Dictionary, q: String) -> bool:
	for key in ["label", "detail", "model_id", "species", "kind", "group"]:
		if q in str(e.get(key, "")).to_lower():
			return true
	var preset: Variant = e.get("preset", {})
	if preset is Dictionary:
		var p: Dictionary = preset
		if q in str(p.get("type", "")).to_lower():
			return true
		var specs: Dictionary = p.get("specs", {}) as Dictionary
		if q in str(specs.get("name", "")).to_lower():
			return true
	return false


## One section while browsing; every section with a match while searching.
func _show_sections() -> void:
	var q := _search.text.strip_edges().to_lower() if _search != null else ""
	var words := q.split(" ", false)
	var shown := 0
	for sec in SECTIONS:
		var sid := str(sec["id"])
		(_chips[sid] as Button).set_pressed_no_signal(q.is_empty() and sid == _section)
		var want := sid == _section if q.is_empty() else true
		if not want:
			if _sections.has(sid):
				((_sections[sid] as Dictionary)["box"] as Control).visible = false
			continue
		_ensure_section(sec)
		var st: Dictionary = _sections[sid]
		var n := 0
		for card in st["cards"]:
			var e: Dictionary = (card as Control).get_meta("entry")
			var ok := true
			for w in words:
				if not _entry_matches(e, w):
					ok = false
					break
			(card as Control).visible = ok
			if ok:
				n += 1
		for g in st["groups"]:
			var any := false
			for c in ((g as Dictionary)["flow"] as Control).get_children():
				any = any or (c as Control).visible
			((g as Dictionary)["flow"] as Control).visible = any
			if (g as Dictionary)["head"] != null:
				((g as Dictionary)["head"] as Control).visible = any
		(st["box"] as Control).visible = n > 0
		shown += n
	if _empty != null:
		_empty.queue_free()
		_empty = null
	if shown == 0:
		_empty = EmptyState.make("search", "Nothing in the library matches “%s”." % q if not q.is_empty()
			else "Nothing here yet.")
		_body.add_child(_empty)
	if _scroll != null:
		_scroll.scroll_vertical = 0


func _ensure_section(sec: Dictionary) -> void:
	var sid := str(sec["id"])
	if _sections.has(sid):
		return
	var box := VBoxContainer.new()
	box.name = "sec_%s" % sid.to_lower().replace(" ", "_")
	box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_body.add_child(box)
	box.add_child(SectionHeader.make(sid, str(sec["icon"]), str(sec["note"])))
	var big := bool(sec["big"])
	var groups: Array = []
	var by_group: Dictionary = {}
	var cards: Array = []
	for e in (_entries.get(sid, []) as Array):
		var gname := str((e as Dictionary).get("group", ""))
		if not by_group.has(gname):
			var head: Label = null
			if not gname.is_empty():
				head = Label.new()
				head.text = gname
				head.add_theme_color_override("font_color", C_TEXT_S)
				head.add_theme_font_size_override("font_size", UITheme.FONT_SM)
				box.add_child(head)
			var flow := HFlowContainer.new()
			flow.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
			flow.add_theme_constant_override("v_separation", UITheme.SPACE_SM)
			box.add_child(flow)
			by_group[gname] = flow
			groups.append({"head": head, "flow": flow})
		var card := _make_card(e as Dictionary, big)
		(by_group[gname] as Container).add_child(card)
		cards.append(card)
	_sections[sid] = {"box": box, "cards": cards, "groups": groups}


func _picture(e: Dictionary, size: Vector2, icon_px: int) -> Control:
	var holder := PanelContainer.new()
	holder.custom_minimum_size = size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_BG, 0.55)
	sb.set_corner_radius_all(6)
	holder.add_theme_stylebox_override("panel", sb)
	var ico := TextureRect.new()
	ico.texture = UiIcons.icon(str(e.get("icon", "box")), icon_px, 1.5)
	ico.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	ico.modulate = Color(C_TEXT_S, 0.55)
	ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(ico)
	var mid := str(e.get("pic_model", ""))
	if not mid.is_empty() and _thumbs != null:
		var tr := TextureRect.new()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(tr)
		# The icon stays under the picture until it lands (or if nothing draws).
		tr.draw.connect(func() -> void: ico.visible = tr.texture == null)
		var build := func() -> Node3D:
			return ModelCatalog.instantiate(mid)
		_thumbs.request("model:%s" % mid, build, tr)
	return holder


func _verb_button(text: String, primary: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	if primary:
		b.add_theme_color_override("font_color", C_PRIMARY)
	b.pressed.connect(cb)
	return b


## A card: picture, name, one line, the verb. Double-click = the verb.
func _make_card(e: Dictionary, big: bool) -> Control:
	var card := PanelContainer.new()
	card.name = "card_%s" % str(e.get("label", "")).to_lower().replace(" ", "_").validate_node_name()
	card.set_meta("entry", e)
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	card.custom_minimum_size.x = CARD_W if big else ROW_W
	card.tooltip_text = str(e.get("detail", ""))
	var title := Label.new()
	title.text = str(e.get("label", "?"))
	title.add_theme_color_override("font_color", C_TEXT)
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var detail := Label.new()
	detail.text = str(e.get("detail", ""))
	detail.add_theme_color_override("font_color", C_TEXT_S)
	detail.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var verbs := HBoxContainer.new()
	verbs.add_theme_constant_override("separation", UITheme.SPACE_XS)
	var main_verb := _verb_button(str(e.get("verb", "Open")), true, func() -> void: _activate(e, false))
	main_verb.name = "verb"
	verbs.add_child(main_verb)
	if str(e.get("kind", "")) == "graph_preset" and _entry_can_place(e):
		var pb := _verb_button("Place", false, func() -> void: _activate(e, true))
		pb.name = "place"
		pb.tooltip_text = "Place it in the world; its node joins the graph"
		verbs.add_child(pb)
	if big:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", UITheme.SPACE_XS)
		card.add_child(col)
		col.add_child(_picture(e, Vector2(CARD_W - 16.0, PIC_H), 44))
		col.add_child(title)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.custom_minimum_size = Vector2(CARD_W - 16.0, 50)
		detail.max_lines_visible = 3
		detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(detail)
		col.add_child(verbs)
	else:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UITheme.SPACE_SM)
		card.add_child(row)
		row.add_child(_picture(e, Vector2(64, 44), 22))
		var col2 := VBoxContainer.new()
		col2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col2.add_theme_constant_override("separation", 0)
		row.add_child(col2)
		col2.add_child(title)
		detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col2.add_child(detail)
		verbs.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(verbs)
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).double_click \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_activate(e, false))
	return card


## Harness / tour: the card of an entry by its label ("" when not built).
func card_for(label: String) -> Control:
	for sid in _sections:
		for card in (_sections[sid] as Dictionary)["cards"]:
			if str(((card as Control).get_meta("entry") as Dictionary).get("label", "")) == label:
				return card as Control
	return null


func section_shown() -> String:
	return _section


func card_count(section_id: String) -> int:
	return ((_sections.get(section_id, {}) as Dictionary).get("cards", []) as Array).size()


func _entry_can_place(e: Dictionary) -> bool:
	var kind := str(e.get("kind", ""))
	if kind in ["structure", "starshade_place"]:
		return true
	if kind == "graph_preset":
		# Any non-component graph preset can be placed (a bespoke GLB if it has
		# one, else a gray-box placeholder).
		return not _preset_is_component(e.get("preset", {}) as Dictionary)
	return false


## True for a compound/super-node preset (spawns a subgraph, not a single prop).
func _preset_is_component(preset: Dictionary) -> bool:
	if str(preset.get("type", "")) == "compound":
		return true
	return preset.has("component_tree") or preset.has("definition_id") \
			or preset.has("def_id")


func _activate(e: Dictionary, force_place: bool) -> void:
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
			if force_place:
				_place_graph_preset(preset)
			else:
				_spawn_graph_preset(preset)
		"veg_paint":
			_open_veg_paint()
		"veg_tune", "veg_species":
			_open_veg_tune(str(e.get("species", "")))
		"building_designer":
			if _loader != null and _loader.has_method("open_building_builder"):
				_loader.call("open_building_builder", -1)
				close()
			else:
				_status.text = "Building designer needs a location map (TerrainLoader)."
		"pallet_rack":
			if _loader != null and _loader.has_method("open_pallet_rack_builder"):
				_loader.call("open_pallet_rack_builder")
				close()
			else:
				_status.text = "Pallet rack builder needs a location map (TerrainLoader)."
		"earthship":
			var esm: GDScript = load("res://scenes/ui/earthshiplab_modal.gd")
			var etree: SceneTree = get_tree()
			close()
			esm.call("open", etree)
		"intermodal":
			var ims: GDScript = load("res://scenes/ui/intermodal_unit_modal.gd")
			if ims != null:
				var tree: SceneTree = get_tree()
				close()
				ims.call("open", tree)
			else:
				_status.text = "Intermodal unit designer is missing."
		"flatpack":
			if _loader != null and _loader.has_method("open_flatpack_designer"):
				_loader.call("open_flatpack_designer")
				close()
			else:
				_status.text = "The furniture designer needs a location map (TerrainLoader)."
		"domelab":
			if _loader != null and _loader.has_method("open_domelab"):
				_loader.call("open_domelab")
				close()
			else:
				_status.text = "The dome designer needs a location map (TerrainLoader)."
		"vehiclelab":
			if _loader != null and _loader.has_method("open_vehiclelab"):
				_loader.call("open_vehiclelab")
				close()
			else:
				_status.text = "The vehicle designer needs a location map (TerrainLoader)."
		"pvlab":
			if _loader != null and _loader.has_method("open_pvlab"):
				_loader.call("open_pvlab")
				close()
			else:
				_status.text = "The Solar designer needs a location map (TerrainLoader)."
		"windlab":
			# Hosted by Main, so it opens on every map (no location needed).
			var main_wl := get_tree().current_scene if get_tree() != null else null
			if main_wl != null and main_wl.has_method("open_windlab"):
				close()
				main_wl.call("open_windlab", {})
			else:
				_status.text = "The wind turbine designer needs a world."
		"tclab":
			# Hosted by Main, so it opens on every map (no location needed).
			var main_tc := get_tree().current_scene if get_tree() != null else null
			if main_tc != null and main_tc.has_method("open_tclab"):
				close()
				main_tc.call("open_tclab", {})
			else:
				_status.text = "The tri-clamp designer needs a world."
		"esplab":
			# Hosted by Main, so it opens on every map (no location needed).
			var main_esp := get_tree().current_scene if get_tree() != null else null
			if main_esp != null and main_esp.has_method("open_esplab"):
				close()
				main_esp.call("open_esplab", {})
			else:
				_status.text = "The ESP board designer needs a world."
		"farmbotlab":
			# Hosted by Main, so it opens on every map.
			var main_fb := get_tree().current_scene if get_tree() != null else null
			if main_fb != null and main_fb.has_method("open_farmbotlab"):
				close()
				main_fb.call("open_farmbotlab", {})
			else:
				_status.text = "The FarmBot designer needs a world."
		"csplab":
			# Hosted by Main, so it opens on every map (no location needed).
			var main_cs := get_tree().current_scene if get_tree() != null else null
			if main_cs != null and main_cs.has_method("open_csplab"):
				close()
				main_cs.call("open_csplab", {})
			else:
				_status.text = "The solar concentrator designer needs a world."
		"peltonlab":
			# Hosted by Main, so it opens on every map (no location needed).
			var main_pl := get_tree().current_scene if get_tree() != null else null
			if main_pl != null and main_pl.has_method("open_peltonlab"):
				close()
				main_pl.call("open_peltonlab", {})
			else:
				_status.text = "The Pelton wheel designer needs a world."
		"toroidlab":
			if _loader != null and _loader.has_method("open_toroidlab"):
				_loader.call("open_toroidlab")
				close()
			else:
				_status.text = "The toroid designer needs a location map (TerrainLoader)."
		"gantrylab":
			if _loader != null and _loader.has_method("open_gantrylab"):
				_loader.call("open_gantrylab")
				close()
			else:
				_status.text = "The gantry designer needs a location map (TerrainLoader)."
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
		# Pass the species through so the modal opens ON that species — every
		# "Species: X" row used to open on whatever was last selected.
		_loader.call("open_vegetation_preview_editor", -1, species_hint)
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
	if model_id == FlatpackBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_flatpack_designer"):
			_loader.call("open_flatpack_designer")
			close()
			return
	if model_id == DomeLabBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_domelab"):
			_loader.call("open_domelab")
			close()
			return
	if model_id == ToroidLabBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_toroidlab"):
			_loader.call("open_toroidlab")
			close()
			return
	if model_id == PvLabBuilder.MODEL_ID or model_id == PvArrayBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_pvlab"):
			_loader.call("open_pvlab")
			close()
			return
	if model_id == GantryLabBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_gantrylab"):
			_loader.call("open_gantrylab")
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
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	return sgv
