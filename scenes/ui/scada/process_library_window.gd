extends Node
## The process Templates window (plans/SCADA_PROCESS_PLAN.md, Phase 9):
## built-in processes and the player's saved ones; add one to the graph, save
## the selection, copy a share code, paste one, write a `.simproc` file.
## Opened by SystemGraphView.open_process_library (the lens's Templates button).
##
##   open(view)
##   button(name), field(name), status_text(), is_open(), close(), rows()
##   names for checks: add_t<i> / add_u<i> (Add to the graph), copy_u<i>,
##   file_u<i>, remove_u<i>, save_sel, sel_name, code_edit, paste_btn, status

var _view: Node = null
var _frame: ModalFrame = null
var _box: VBoxContainer = null
var _status: Label = null
var _sel_name: LineEdit = null
var _code: LineEdit = null
var _rows: Array = []


func open(view: Node) -> void:
	_view = view
	_frame = ModalFrame.create("Process templates", "Whole processes to drop into the graph: parts, pipes, control blocks, alarms and widgets together.",
		Vector2(980, 700), "scada_process_library")
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	_frame.body.add_child(top)
	_sel_name = LineEdit.new()
	_sel_name.name = "sel_name"
	_sel_name.placeholder_text = "Name for what is selected…"
	_sel_name.custom_minimum_size.x = 240
	top.add_child(_sel_name)
	var sv := _btn("save_sel", "Save the selection", _save_selection)
	sv.tooltip_text = "Save the parts selected in the graph (or everything in this part of it, if nothing is selected) with the control blocks, alarms and widgets that belong only to them."
	top.add_child(sv)
	top.add_child(VSeparator.new())
	_code = LineEdit.new()
	_code.name = "code_edit"
	_code.placeholder_text = "Paste a share code (SMPR1:…)"
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_code)
	top.add_child(_btn("paste_btn", "Add from code", _paste))
	_status = Label.new()
	_status.name = "status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_frame.body.add_child(_status)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 6)
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_frame.body.add_child(_box)
	_frame.add_button("Close", ModalFrame.SECONDARY, _frame.close)
	_frame.open()
	_rebuild()


func _btn(id: String, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.name = id
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func button(id: String) -> Button:
	return _frame.find_child(id, true, false) as Button if _frame != null else null


func field(id: String) -> LineEdit:
	return _frame.find_child(id, true, false) as LineEdit if _frame != null else null


func status_text() -> String:
	return _status.text if _status != null else ""


func is_open() -> bool:
	return _frame != null and _frame.is_open()


func close() -> void:
	if _frame != null:
		_frame.close()


## [{name, mine}] in the order shown.
func rows() -> Array:
	return _rows


func _say(text: String, bad: bool = false) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", UITheme.C_WARN if bad else UITheme.C_TEXT_M)


func _rebuild() -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	_rows = []
	_box.add_child(SectionHeader.make("Built in"))
	for i in ProcessPack.TEMPLATES.size():
		var p := ProcessPack.template(str(ProcessPack.TEMPLATES[i][0]))
		_box.add_child(_row(p, "t%d" % i, false))
		_rows.append({"name": str(p["name"]), "mine": false})
	_box.add_child(SectionHeader.make("Yours"))
	var mine := ProcessLibrary.load_all()
	if mine.is_empty():
		_box.add_child(EmptyState.row("package", "Nothing saved yet. Select a few parts in the graph and press Save the selection, or paste a share code."))
	for i in mine.size():
		_box.add_child(_row(mine[i], "u%d" % i, true))
		_rows.append({"name": str(mine[i]["name"]), "mine": true})


func _row(p: Dictionary, key: String, mine: bool) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	var nm := Label.new()
	nm.text = str(p["name"])
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(nm)
	var d := Label.new()
	d.text = ProcessPack.describe(p) + (("  ·  " + str(p["note"])) if not str(p.get("note", "")).is_empty() else "")
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	d.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	col.add_child(d)
	var pack := p
	row.add_child(_btn("add_%s" % key, "Add to the graph", func() -> void: _add(pack)))
	var cp := _btn("copy_%s" % key, "Copy code", func() -> void:
		DisplayServer.clipboard_set(ProcessPack.encode(pack))
		_say("Share code for \"%s\" copied. Anyone can paste it into this window." % str(pack["name"])))
	cp.tooltip_text = "A share code: text you can paste in a chat."
	row.add_child(cp)
	if mine:
		var fb := _btn("file_%s" % key, "Save file", func() -> void: _write_file(pack))
		fb.tooltip_text = "Write it as a .simproc file."
		row.add_child(fb)
		var rm := IconButton.make("trash-2", "Remove it from your list", func() -> void:
			ProcessLibrary.remove(str(pack["name"]))
			_say("Removed \"%s\"." % str(pack["name"]))
			_rebuild())
		rm.name = "remove_%s" % key
		row.add_child(rm)
	return card


func _add(pack: Dictionary) -> void:
	if _view == null or not _view.has_method("process_insert"):
		return
	var res: Dictionary = _view.call("process_insert", pack)
	if bool(res.get("ok", false)):
		_frame.close()
	else:
		_say(str(res.get("why", "That could not be added.")), true)


func _save_selection() -> void:
	if _view == null or not _view.has_method("process_capture"):
		return
	var nm := _sel_name.text.strip_edges()
	var pack: Dictionary = _view.call("process_capture", nm if not nm.is_empty() else "My process")
	if (pack.get("items", []) as Array).is_empty():
		_say("There is nothing to save here: select some parts in the graph first.", true)
		return
	var took := ProcessLibrary.add(pack)
	if took.is_empty():
		_say("It could not be written to disk.", true)
		return
	_sel_name.text = ""
	_say("Saved \"%s\": %s." % [took, ProcessPack.describe(pack)])
	_rebuild()


func _paste() -> void:
	var res := ProcessPack.decode(_code.text)
	if not bool(res["ok"]):
		_say(str(res["why"]), true)
		return
	var took := ProcessLibrary.add(res["pack"])
	_code.text = ""
	_say("Added \"%s\" to your list: %s. Nothing is in the graph until you press Add to the graph." % [took, ProcessPack.describe(res["pack"])])
	_rebuild()


func _write_file(pack: Dictionary) -> void:
	var dir := "user://process_export"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/%s.simproc" % [dir, ScadaTags.slug(str(pack["name"]))]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_say("The file could not be written.", true)
		return
	f.store_string(ProcessPack.encode(pack))
	_say("Written to %s" % ProjectSettings.globalize_path(path))
