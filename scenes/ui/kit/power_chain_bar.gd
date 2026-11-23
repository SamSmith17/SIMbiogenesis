class_name PowerChainBar
extends HBoxContainer

## "Panels › Controller › Battery": the solar chain the lab's item is part of
## on the graph (PowerChain), as three chips in the lab's header. The lab you
## are in is lit; a click on another opens that lab bound to that item (the
## lab you leave applies its changes first, then closes); a missing link is
## "+ Add …", which puts a library part on the graph wired in. A notes chip
## counts the checks between the links and lists them.
##
## The host lab connects `hop_requested(kind, unit)` and `add_requested(what)`
## and calls `PowerChainBar.go` after leaving (see the three lab modals).
## Sheet opens the wiring diagram of this chain over the lab.

signal hop_requested(kind: String, unit: Dictionary)
signal add_requested(what: String)

const KINDS := ["panels", "controller", "battery"]
const ICONS := {"panels": "sun", "controller": "cpu", "battery": "battery"}
const WORDS := {"panels": "Panels", "controller": "Controller", "battery": "Battery"}

var lab := ""
## Icons only (a short screen: the header row also carries the footer).
var compact := false
var _item_id := ""
var _chain: Dictionary = {}
var _checks: Array = []
var _notes_btn: Button = null
var _pop: PopupPanel = null
var _menu: PopupMenu = null

const SHEET_MODAL := preload("res://scenes/ui/wiresheet_modal.gd")


static func create(for_lab: String) -> PowerChainBar:
	var b := PowerChainBar.new()
	b.name = "PowerChainBar"
	b.lab = for_lab
	b.add_theme_constant_override("separation", 4)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return b


func set_compact(on: bool) -> void:
	if on == compact:
		return
	compact = on
	_rebuild()


## Follow a DesignerShell: compact while its footer shares the header row.
func follow(shell: DesignerShell) -> void:
	shell.layout_changed.connect(func(_f: bool, short: bool) -> void: set_compact(short))
	compact = shell.is_short()


func chain() -> Dictionary:
	return _chain


func checks() -> Array:
	return _checks


## Rebuild from the graph for this item ("" = not on the graph yet).
func refresh(item_id: String) -> void:
	_item_id = item_id
	var model := _model()
	_chain = PowerChain.find(model, item_id) if model != null else {}
	_checks = []
	if model != null and not (_chain.get("controller", {}) as Dictionary).is_empty():
		var win := PvElectrical.string_window_report(model, str(_chain["controller"]["id"]),
			GraphNesting.flat_connections_cached(model))
		_checks = PowerChain.checks(model, _chain, win)
	_rebuild()
	_sync_sheet()


func _model() -> GraphModel:
	var gv := ServiceLocator.graph()
	return gv.get("model") as GraphModel if gv != null else null


func _rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_notes_btn = null
	if _item_id.is_empty() or _chain.is_empty() or str(_chain.get("start", "")).is_empty():
		var l := Label.new()
		l.text = "Not on the graph yet: place it to join a solar chain"
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		add_child(l)
		return
	for i in KINDS.size():
		var k: String = KINDS[i]
		if i > 0:
			var sep := Label.new()
			sep.text = "›"
			sep.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			add_child(sep)
		add_child(_chip(k))
	if not _checks.is_empty():
		var errs := _checks.filter(func(c): return str(c["level"]) == "error").size()
		var warns := _checks.filter(func(c): return str(c["level"]) == "warn").size()
		_notes_btn = Button.new()
		_notes_btn.name = "chain_notes"
		_notes_btn.focus_mode = Control.FOCUS_NONE
		_notes_btn.text = str(_checks.size()) if compact else UiText.count(_checks.size(), "note")
		var col := UITheme.C_ERROR if errs > 0 else (UITheme.C_AMBER if warns > 0 else UITheme.C_INFO)
		_notes_btn.add_theme_stylebox_override("normal", UITheme.chip_style(col))
		_notes_btn.add_theme_stylebox_override("hover", UITheme.chip_style(col.lightened(0.15)))
		_notes_btn.add_theme_color_override("font_color", col)
		_notes_btn.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		_notes_btn.tooltip_text = "\n".join(PackedStringArray(_checks.map(func(c): return str(c["text"]))))
		_notes_btn.pressed.connect(_show_notes)
		add_child(_notes_btn)
	_add_sheet()


func _add_sheet() -> void:
	var b := Button.new()
	b.name = "chain_sheet"
	b.focus_mode = Control.FOCUS_NONE
	IconButton.style(b, "workflow", "Open the wiring diagram of this chain", "" if compact else "Sheet", 14)
	b.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	b.add_theme_stylebox_override("normal", UITheme.chip_style(UITheme.C_INFO))
	b.add_theme_stylebox_override("hover", UITheme.chip_style(UITheme.C_INFO.lightened(0.15)))
	b.add_theme_color_override("font_color", UITheme.C_INFO)
	b.pressed.connect(_open_sheet)
	add_child(b)


func _open_sheet() -> void:
	var m := _sheet_modal()
	if m != null:
		m.call("open", _item_id)


## A hop to the next lab keeps an open page on the chain it is showing.
func _sync_sheet() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var ui := tree.root.get_node_or_null("WireSheetLayer/WireSheetModal") as Control
	if ui != null and bool(ui.call("is_open")):
		ui.call("open", _item_id, false)


func _sheet_modal() -> Control:
	var tree := get_tree()
	if tree == null:
		return null
	var layer := tree.root.get_node_or_null("WireSheetLayer")
	if layer == null:
		var made := CanvasLayer.new()
		made.name = "WireSheetLayer"
		made.layer = UITheme.LAYER_MODAL + 2
		tree.root.add_child(made)
		layer = made
	var ui := layer.get_node_or_null("WireSheetModal") as Control
	if ui == null:
		ui = Control.new()
		ui.name = "WireSheetModal"
		ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ui.set_script(SHEET_MODAL)
		layer.add_child(ui)
	return ui


func _chip(k: String) -> Button:
	var b := Button.new()
	b.name = "chain_" + k
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	var units: Array = _units(k)
	var here := k == lab
	if units.is_empty():
		b.name = "chain_add_" + k
		b.text = {"panels": "+ Design panels", "controller": "+ Add a controller", "battery": "+ Add a battery"}[k]
		if compact:
			IconButton.style(b, str(ICONS[k]), "", "+", 14)
		b.tooltip_text = {
			"panels": "Open the solar designer with this controller's window as its target",
			"controller": "Put a controller on the graph wired to this",
			"battery": "Put a battery bank at this controller's voltage on the graph, wired to it"}[k]
		b.disabled = k == "battery" and (_chain.get("controller", {}) as Dictionary).is_empty()
		b.add_theme_stylebox_override("normal", UITheme.chip_style(UITheme.C_TEXT_M))
		b.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		b.pressed.connect(func() -> void: add_requested.emit(k))
		return b
	IconButton.style(b, str(ICONS[k]), "", "" if compact else _chip_text(k, units), 14)
	var col := UITheme.C_AMBER if here else UITheme.C_TEXT_S
	b.add_theme_stylebox_override("normal", UITheme.chip_style(col))
	b.add_theme_stylebox_override("hover", UITheme.chip_style(col.lightened(0.2)))
	b.add_theme_color_override("font_color", UITheme.C_TEXT if here else UITheme.C_TEXT_S)
	if here:
		b.tooltip_text = I18n.f("{units} (you are designing this one)", {"units": _chip_text(k, units)})
		b.mouse_default_cursor_shape = Control.CURSOR_ARROW
		return b
	b.tooltip_text = I18n.f("{units}\nOpen {k} in its lab\n{name}", {
		"units": _chip_text(k, units),
		"k": str(WORDS[k]).to_lower(),
		"name": "\n".join(PackedStringArray(units.map(func(u): return str(u["name"])))),
	})
	b.pressed.connect(func() -> void: _on_chip(k, b))
	return b


func _chip_text(k: String, units: Array) -> String:
	var first: Dictionary = units[0]
	var t := "%s: %s" % [WORDS[k], UiText.fit(UITheme.font("regular"), str(first["name"]), UITheme.FONT_XS, 170.0)] \
		if units.size() == 1 else "%s: %s" % [WORDS[k], UiText.count(units.size(), "array")]
	return t


func _units(k: String) -> Array:
	match k:
		"panels":
			return _chain.get("arrays", []) as Array
		_:
			var u: Dictionary = _chain.get(k, {})
			return [] if u.is_empty() else [u]


func _on_chip(k: String, b: Button) -> void:
	var units := _units(k)
	if units.size() == 1:
		hop_requested.emit(k, units[0])
		return
	if _menu == null:
		_menu = PopupMenu.new()
		_menu.name = "chain_menu"
		add_child(_menu)
	_menu.clear()
	for i in units.size():
		_menu.add_item(str(units[i]["name"]), i)
	for c in _menu.id_pressed.get_connections():
		_menu.id_pressed.disconnect(c["callable"])
	_menu.id_pressed.connect(func(id: int) -> void: hop_requested.emit(k, units[id]))
	var r := b.get_global_rect()
	_menu.popup(Rect2i(Vector2i(r.position + Vector2(0, r.size.y)), Vector2i.ZERO))


func _show_notes() -> void:
	if _pop == null:
		_pop = PopupPanel.new()
		_pop.name = "chain_notes_popup"
		add_child(_pop)
	for c in _pop.get_children():
		_pop.remove_child(c)
		c.queue_free()
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(420, 0)
	box.add_theme_constant_override("separation", 6)
	_pop.add_child(box)
	for cv in _checks:
		var c: Dictionary = cv
		var l := Label.new()
		l.text = str(c["text"])
		l.tooltip_text = str(c["why"])
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color",
			{"error": UITheme.C_ERROR, "warn": UITheme.C_AMBER}.get(str(c["level"]), UITheme.C_TEXT))
		box.add_child(l)
		var w := Label.new()
		w.text = str(c["why"])
		w.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		w.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		w.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		box.add_child(w)
	var r := _notes_btn.get_global_rect() if _notes_btn != null else Rect2()
	_pop.popup(Rect2i(Vector2i(r.position + Vector2(0, r.size.y + 4)), Vector2i(440, 0)))


## Open `kind`'s lab on `unit` (after the host lab has left). Panels with no
## design of their own open the solar designer fresh, aimed at the chain's
## controller.
static func go(main: Node, kind: String, unit: Dictionary, chain: Dictionary = {}) -> bool:
	if main == null:
		return false
	var pid := str(unit.get("prop_id", ""))
	var gid := str(unit.get("id", ""))
	match kind:
		"controller":
			var opts := {"prop_id": pid} if not pid.is_empty() else {"graph_item_id": gid}
			return main.call("open_ctrllab", opts) != null
		"battery":
			var opts2 := {"prop_id": pid} if not pid.is_empty() else {"graph_item_id": gid}
			return main.call("open_batterylab", opts2) != null
		"panels":
			var loader := main.get_node_or_null("TerrainLoader")
			if loader == null or not loader.has_method("open_pvlab"):
				return false
			if bool(unit.get("designed", false)) and not pid.is_empty():
				loader.call("open_pvlab_for_prop", pid)
				return true
			var spec := PvLabPresets.builtin("backyard_2x4")["spec"] as Dictionary
			spec = spec.duplicate(true)
			var c: Dictionary = chain.get("controller", {})
			var gv := ServiceLocator.graph()
			var model: GraphModel = gv.get("model") as GraphModel if gv != null else null
			if not c.is_empty() and model != null:
				var t := PowerChain.pv_target(model.get_item(str(c["id"])).get("specs", {}) as Dictionary)
				for k in t:
					(spec["target"] as Dictionary)[k] = t[k]
			loader.call("open_pvlab", spec)
			return true
	return false
