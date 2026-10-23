extends CanvasLayer

## The bar across the top while an experiment fork is on the graph:
## "Editing fork <name>" + Done / Discard. It owns the session from start to
## finish: SystemGraphView.begin_fork_edit with the fork's graph, the graph
## view opened on it, and on Done the edited graph written back into the
## world's ExperimentStore and the Compare window reopened on the fork
## (Main.open_compare_view). A game load that replaces the graph meanwhile
## (fork_edit_interrupted) still saves the fork's edits.

signal finished(kept: bool)

var _main: Node = null
var _gv: Node = null
var _store_path := ""
var _fork_id := ""
var _label: Label = null

const TOP_Y := 72.0


func start(main: Node, gv: Node, fork_id: String) -> bool:
	_main = main
	_gv = gv
	_fork_id = fork_id
	_store_path = ExperimentStore.path_for_view(gv)
	var store := ExperimentStore.load_from(_store_path)
	var f := store.get_fork(fork_id)
	if f.is_empty() or gv == null or not gv.has_method("begin_fork_edit"):
		return false
	if not bool(gv.call("begin_fork_edit", fork_id, str(f["name"]), f["graph"] as Dictionary)):
		return false
	gv.connect("fork_edit_interrupted", _on_interrupted)
	_build(str(f["name"]))
	if gv.has_method("open_graph_view"):
		gv.call("open_graph_view")
	return true


func _build(fork_name: String) -> void:
	layer = UITheme.LAYER_TOAST - 1
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.97))
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	# Below the graph view's top bar (its clusters run the full width).
	panel.offset_top = TOP_Y
	add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)
	var ic := TextureRect.new()
	ic.texture = UiIcons.icon("workflow", 16)
	ic.modulate = UITheme.C_AMBER
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(ic)
	_label = Label.new()
	_label.text = "Editing fork: %s — your world is set aside and the clock is held." % fork_name
	_label.add_theme_font_override("font", UITheme.font("semibold"))
	_label.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_label.add_theme_color_override("font_color", UITheme.C_AMBER)
	_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_label)
	var discard := Button.new()
	discard.text = "Discard changes"
	discard.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(discard)
	discard.pressed.connect(func() -> void: finish(false))
	row.add_child(discard)
	var done := Button.new()
	done.text = "Done — back to Compare"
	done.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(done)
	done.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	done.pressed.connect(func() -> void: finish(true))
	row.add_child(done)
	# Centre the panel on its own width.
	panel.resized.connect(func() -> void:
		panel.offset_left = -panel.size.x * 0.5
		panel.offset_right = panel.size.x * 0.5)


## Leave the fork: keep (write its graph back) or discard; back to Compare.
func finish(keep: bool) -> void:
	if _gv == null or not is_instance_valid(_gv) or str(_gv.call("fork_edit_id")) != _fork_id:
		queue_free()
		return
	if _gv.is_connected("fork_edit_interrupted", _on_interrupted):
		_gv.disconnect("fork_edit_interrupted", _on_interrupted)
	var graph: Dictionary = _gv.call("end_fork_edit", keep)
	if keep and not graph.is_empty():
		_save_graph(graph)
	finished.emit(keep)
	if _main != null and _main.has_method("open_compare_view"):
		_main.call("open_compare_view", Vector2(NAN, NAN), {"mode": "ab", "b": _fork_id})
	queue_free()


func _on_interrupted(fork_id: String, graph: Dictionary) -> void:
	if fork_id == _fork_id and not graph.is_empty():
		_save_graph(graph)
	if _main != null and _main.has_method("show_toast"):
		_main.call("show_toast", "The fork's edits were saved; a load replaced the graph.")
	finished.emit(true)
	queue_free()


func _save_graph(graph: Dictionary) -> void:
	var store := ExperimentStore.load_from(_store_path)
	if store.set_fork_graph(_fork_id, graph):
		store.save_to(_store_path)
