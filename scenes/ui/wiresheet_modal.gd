extends Control

## The wiring diagram over the lab that opened it. The page is a WireSheet
## of the chain the Panels › Controller › Battery bar is showing. Dragging a
## device stores its page position here and asks for a new layout; the graph
## cards stay where they are. Export writes the same drawing as SVG.

const MODAL_NAME := "wiresheet"
const WANT := Vector2(1480, 900)
const VIEW := preload("res://scenes/ui/wiresheet_view.gd")

var _item_id := ""
var _places: Dictionary = {}
var _show_data := false
var _lay: Dictionary = {}
var _dim: ColorRect = null
var _panel: PanelContainer = null
var _data: CheckButton = null
var _view: Control = null
var _title: Label = null
var _info: Label = null
var _tools: HBoxContainer = null
var _design: Button = null
var _inserts: Dictionary = {}
var _is_open := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_dim = ColorRect.new()
	_dim.color = Color(0.0, 0.0, 0.0, 0.58)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			close())
	add_child(_dim)
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.add_theme_stylebox_override("panel", UITheme.modal_panel_style(0.99))
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.set_meta("ui_modal", true)
	add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_panel.add_child(col)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	col.add_child(bar)
	var ic := TextureRect.new()
	ic.texture = UiIcons.icon("workflow", 20)
	ic.modulate = UITheme.C_PRIMARY
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	bar.add_child(ic)
	_title = Label.new()
	_title.text = "Wiring diagram"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_font_override("font", UITheme.font("semibold"))
	_title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_title.add_theme_color_override("font_color", UITheme.C_TEXT)
	bar.add_child(_title)
	_data = CheckButton.new()
	_data.name = "sheet_data"
	_data.text = "Data leads"
	_data.tooltip_text = "Show VE.Direct, VE.Bus and other comms leads"
	_data.focus_mode = Control.FOCUS_NONE
	_data.toggled.connect(_on_data)
	bar.add_child(_data)
	var exp := Button.new()
	exp.text = "Export SVG"
	exp.tooltip_text = "Write this page to user://wiresheet.svg"
	exp.focus_mode = Control.FOCUS_NONE
	UiIcons.apply(exp, "download", "Write this page to user://wiresheet.svg", 15)
	UITheme.style_primary_button(exp)
	exp.pressed.connect(_export)
	bar.add_child(exp)
	bar.add_child(IconButton.close(close))
	col.add_child(HSeparator.new())

	_tools = HBoxContainer.new()
	_tools.add_theme_constant_override("separation", 6)
	_tools.visible = false
	col.add_child(_tools)
	_design = _tool("Design this", "Open this part in its lab", _design_selected)
	UITheme.style_primary_button(_design)
	for k in [["fuse", "Fuse"], ["breaker", "Breaker"], ["switch", "Switch"], ["busbar", "Bus"], ["distributor", "Distributor"], ["shunt", "Shunt"]]:
		var key := str(k[0])
		var b := _tool(str(k[1]), "Put this in the selected run", _insert.bind(key))
		b.name = "sheet_" + key
		_inserts[key] = b

	var sheet_frame := PanelContainer.new()
	sheet_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sheet_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sheet_sb := StyleBoxFlat.new()
	sheet_sb.bg_color = Color("#f4f5f7")
	sheet_sb.border_color = UITheme.C_BORDER
	sheet_sb.set_border_width_all(1)
	sheet_sb.set_corner_radius_all(UITheme.CORNER_RADIUS)
	sheet_sb.set_content_margin_all(4)
	sheet_frame.add_theme_stylebox_override("panel", sheet_sb)
	col.add_child(sheet_frame)

	_view = Control.new()
	_view.name = "WireSheetView"
	_view.set_script(VIEW)
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.custom_minimum_size = Vector2(0, 240)
	sheet_frame.add_child(_view)
	_view.device_selected.connect(_on_selected)
	_view.device_moved.connect(_on_moved)
	_view.conductor_selected.connect(_on_conductor)

	col.add_child(HSeparator.new())
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_info.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_info.text = "Drag a device to move it on the page. Click a run to put a fuse, breaker, switch or bus in it. Data leads shows comms. Wheel zooms."
	col.add_child(_info)


func open(item_id: String, refit: bool = true) -> void:
	var changed := item_id != _item_id
	if changed:
		_places = {}
		_item_id = item_id
	if not _is_open:
		_is_open = true
		visible = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		UiFit.keep_fitted(_panel, WANT)
		CursorController.request_modal(MODAL_NAME, close)
		HudLayout.claim_modal(MODAL_NAME)
		UITheme.animate_open(_panel, _dim)
	_reload()
	if _view != null and (refit or changed):
		_view.call_deferred("fit")


func close() -> void:
	if not _is_open:
		visible = false
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		return
	_is_open = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	CursorController.release_modal(MODAL_NAME)
	HudLayout.release(MODAL_NAME)


func is_open() -> bool:
	return _is_open


func _exit_tree() -> void:
	if _is_open:
		CursorController.release_modal(MODAL_NAME)
		HudLayout.release(MODAL_NAME)


func _reload() -> void:
	var model := _model()
	if model == null or _item_id.is_empty():
		_lay = {}
	else:
		_lay = WireSheet.layout(model, _item_id, {"places": _places, "show_data": _show_data})
	if _view != null:
		_view.call("set_layout", _lay)
	_title.text = "Wiring diagram"
	_sync_tools()
	_sync_info(str(_view.get("selected")) if _view != null else "")


func _tool(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	_tools.add_child(b)
	return b


func _on_selected(id: String) -> void:
	_sync_tools()
	_sync_info(id)


func _on_conductor(_id: String) -> void:
	_sync_tools()
	_sync_info("")


func _sync_tools() -> void:
	if _tools == null or _view == null:
		return
	var dev := str(_view.get("selected"))
	var wire := str(_view.get("conductor"))
	var lab := _lab_kind(dev)
	var power_wire := wire != "" and _wire_polarity(wire) != "data"
	_design.visible = lab != ""
	for k in _inserts:
		(_inserts[k] as Button).visible = power_wire
	_tools.visible = lab != "" or power_wire


func _wire_polarity(id: String) -> String:
	for c in (_lay.get("conductors", []) as Array):
		if str(c["id"]) == id:
			return str(c.get("polarity", ""))
	return ""


func _on_data(on: bool) -> void:
	_show_data = on
	_reload()
	if _view != null:
		_view.call_deferred("fit")


func _lab_kind(id: String) -> String:
	for d in (_lay.get("devices", []) as Array):
		if str(d["id"]) == id:
			var k := str(d["kind"])
			return k if k == "panels" or k == "controller" or k == "battery" else ""
	return ""


func _design_selected() -> void:
	var id := str(_view.get("selected")) if _view != null else ""
	var lab := _lab_kind(id)
	if lab == "" or get_tree() == null:
		return
	var name := ""
	for d in (_lay.get("devices", []) as Array):
		if str(d["id"]) == id:
			name = str(d["name"])
	var bar := get_tree().root.find_child("PowerChainBar", true, false)
	if bar != null:
		if str(bar.get("lab")) == lab:
			close()
			return
		bar.hop_requested.emit(lab, {"id": id, "name": name})
		return
	var main := get_tree().current_scene
	if main != null:
		PowerChainBar.go(main, lab, {"id": id, "name": name})


func _insert(kind: String) -> void:
	var model := _model()
	var wire := str(_view.get("conductor")) if _view != null else ""
	if model == null or wire.is_empty():
		return
	var nid := WireSheet.insert(model, wire, kind)
	if nid.is_empty():
		_info.text = "That run can't take one."
		return
	if _view != null:
		_view.set("conductor", "")
	_reload()
	_sync_tools()


func _on_moved(id: String, origin: Vector2) -> void:
	_places[id] = origin
	_reload()


func _sync_info(id: String) -> void:
	if _info == null:
		return
	var parts: PackedStringArray = []
	var named := false
	for d in (_lay.get("devices", []) as Array):
		if str(d["id"]) == id and id != "":
			parts.append("%s · drag to move it on the page" % str(d["name"]))
			named = true
	if not named:
		parts.append("Drag a device to move it on the page. Click a run to protect it. Wheel zooms. Shift snaps to 1 mm, Alt is free.")
	for c in (_lay.get("checks", []) as Array):
		parts.append(str(c["text"]))
	_info.text = " · ".join(parts)


func _export() -> void:
	if _lay.is_empty():
		_info.text = "Nothing to export."
		return
	var path := "user://wiresheet.svg"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_info.text = "Could not write the SVG."
		return
	f.store_string(WireSheet.svg(_lay))
	_info.text = "Wrote %s" % path


func _model() -> GraphModel:
	var gv := ServiceLocator.graph()
	return gv.get("model") as GraphModel if gv != null else null
