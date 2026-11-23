class_name CirclePackWindow
extends Node

## The circle-pack window: one or more nested sources seen as zoomable
## circles (CirclePackView), with tabs between the sources, a "Size by"
## choice, a breadcrumb back up the levels, and a side panel naming what is
## under the pointer (or chosen): its amount, its share of the level above
## and of the whole, what is inside it, and the source's actions for it
## ("Show on the graph", "Edit…"). Sources can refresh live: the circles
## then glide to their new sizes.
##
##   CirclePackWindow.open_for(tree, {
##       title, subtitle,
##       sources: [{id, label, build: Callable(size_by) -> tree,
##                  sizes: [[id, label]], size: default id,
##                  actions: Callable(node) -> [[label, Callable]],
##                  live_s: seconds between refreshes (0 = never)}],
##       source: id to start on, focus_id: a node to open on})

const HINT := "Click a circle to go in · right-click or Backspace to go out · wheel zooms · drag pans · double-click opens it"

static var _inst: CirclePackWindow = null

var _frame: ModalFrame = null
var _view: CirclePackView = null
var _spec: Dictionary = {}
var _src: Dictionary = {}
var _size_by := ""
var _src_btns: Dictionary = {}
var _src_row: HBoxContainer = null
var _size_opt: OptionButton = null
var _crumbs: HBoxContainer = null
var _side_title: Label = null
var _side_value: Label = null
var _side_share: Label = null
var _side_detail: Label = null
var _side_kids: VBoxContainer = null
var _side_actions: VBoxContainer = null
var _note: Label = null
var _live_acc := 0.0
var _shown := -2


static func open_for(tree: SceneTree, spec: Dictionary) -> CirclePackWindow:
	if _inst == null or not is_instance_valid(_inst):
		_inst = CirclePackWindow.new()
		_inst.name = "CirclePackWindow"
		tree.root.add_child(_inst)
	_inst.open(spec)
	return _inst


static func current() -> CirclePackWindow:
	return _inst if _inst != null and is_instance_valid(_inst) else null


func open(spec: Dictionary) -> void:
	if _frame == null:
		_build()
	_spec = spec
	_frame.set_title(str(spec.get("title", "Inside")), str(spec.get("subtitle", "")))
	for c in _src_row.get_children():
		c.queue_free()
	_src_btns.clear()
	var sources: Array = spec.get("sources", []) as Array
	for s in sources:
		var sd: Dictionary = s
		var b := Button.new()
		b.text = str(sd.get("label", sd.get("id", "")))
		b.name = "src_" + str(sd.get("id", ""))
		b.toggle_mode = true
		UITheme.style_button(b)
		var sid := str(sd.get("id", ""))
		b.pressed.connect(func() -> void: set_source(sid))
		_src_row.add_child(b)
		_src_btns[sid] = b
	_src_row.visible = sources.size() > 1
	var start := str(spec.get("source", ""))
	if start.is_empty() and not sources.is_empty():
		start = str((sources[0] as Dictionary).get("id", ""))
	_frame.open()
	set_process(true)
	set_source(start, str(spec.get("focus_id", "")))


func is_open() -> bool:
	return _frame != null and _frame.is_open()


func close() -> void:
	if _frame != null:
		_frame.close()


func view() -> CirclePackView:
	return _view


func source_id() -> String:
	return str(_src.get("id", ""))


func set_source(id: String, focus_id: String = "") -> void:
	for s in (_spec.get("sources", []) as Array):
		if str((s as Dictionary).get("id", "")) == id:
			_src = s
			break
	for k in _src_btns:
		(_src_btns[k] as Button).set_pressed_no_signal(str(k) == id)
	_size_opt.clear()
	var sizes: Array = _src.get("sizes", []) as Array
	for i in sizes.size():
		_size_opt.add_item(str(sizes[i][1]), i)
		_size_opt.set_item_metadata(i, str(sizes[i][0]))
	_size_opt.get_parent().visible = sizes.size() > 1
	_size_by = str(_src.get("size", sizes[0][0] if not sizes.is_empty() else ""))
	FormRow.select_meta(_size_opt, _size_by)
	_rebuild(focus_id, true)


func set_size_by(id: String) -> void:
	_size_by = id
	FormRow.select_meta(_size_opt, id)
	_rebuild("", false)


func _rebuild(focus_id: String, fresh: bool) -> void:
	var build: Callable = _src.get("build", Callable())
	var tree: Dictionary = build.call(_size_by) if build.is_valid() else {}
	if fresh:
		_view.nodes = []   # grow in from the middle, not a glide
	_view.set_tree(tree, {"fmt": Callable(CirclePackSources, "fmt"), "focus_id": focus_id})
	var hid := int(_view.lay.get("hidden", 0))
	var bits: Array = []
	if hid > 0:
		bits.append("%s left out (nothing to size them by)" % UiText.count(hid, "thing"))
	if str(tree.get("detail", "")) != "":
		bits.append(str(tree["detail"]))
	_note.text = " · ".join(bits) if not bits.is_empty() else HINT
	_live_acc = 0.0
	_shown = -2
	_refresh_side()
	_refresh_crumbs()


func _build() -> void:
	_frame = ModalFrame.create("Inside", "", Vector2(1480, 940), "circle_pack")
	_frame.content_max_w = 0.0
	add_child(_frame)
	var b := _frame.body
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	b.add_child(top)
	_src_row = HBoxContainer.new()
	_src_row.add_theme_constant_override("separation", 4)
	top.add_child(_src_row)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	var szbox := HBoxContainer.new()
	var szl := Label.new()
	szl.text = "Size by"
	szl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	szbox.add_child(szl)
	_size_opt = OptionButton.new()
	_size_opt.name = "pack_size_by"
	_size_opt.item_selected.connect(func(i: int) -> void: set_size_by(str(_size_opt.get_item_metadata(i))))
	szbox.add_child(_size_opt)
	top.add_child(szbox)
	top.add_child(IconButton.make("house", "The whole (Home)", func() -> void: _view.zoom_home()))
	top.add_child(IconButton.make("arrow-up", "Up a level (right-click, Backspace)", func() -> void: _view.zoom_out()))

	_crumbs = HBoxContainer.new()
	_crumbs.add_theme_constant_override("separation", 2)
	b.add_child(_crumbs)

	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b.add_child(main)
	_view = CirclePackView.new()
	_view.name = "pack_view"
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.custom_minimum_size = Vector2(760, 660)
	main.add_child(_view)
	_view.focus_changed.connect(func(_i: int) -> void:
		_refresh_crumbs()
		_refresh_side())
	_view.hovered.connect(func(_i: int) -> void: _refresh_side())
	_view.selected.connect(func(_i: int) -> void: _refresh_side())
	_view.activated.connect(_on_activated)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(320, 0)
	side.add_theme_constant_override("separation", 6)
	main.add_child(side)
	_side_title = Label.new()
	_side_title.add_theme_font_size_override("font_size", UITheme.FONT_LG + 2)
	_side_title.add_theme_color_override("font_color", UITheme.C_TEXT)
	_side_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_side_title)
	_side_value = Label.new()
	_side_value.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_side_value.add_theme_color_override("font_color", UITheme.C_TEXT)
	side.add_child(_side_value)
	_side_share = Label.new()
	_side_share.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_side_share.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_side_share)
	_side_detail = Label.new()
	_side_detail.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_side_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_side_detail)
	_side_actions = VBoxContainer.new()
	side.add_child(_side_actions)
	side.add_child(SectionHeader.make("Inside", "circle-dot"))
	var ks := ScrollContainer.new()
	ks.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ks.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(ks)
	_side_kids = VBoxContainer.new()
	_side_kids.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ks.add_child(_side_kids)

	_note = Label.new()
	_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	b.add_child(_note)
	_frame.add_button("Close", ModalFrame.PRIMARY, func() -> void: _frame.close())
	set_process(false)
	_frame.closed.connect(func() -> void: set_process(false))


func _process(delta: float) -> void:
	if not is_open():
		set_process(false)
		return
	var live := float(_src.get("live_s", 0.0))
	if live <= 0.0:
		return
	_live_acc += delta
	if _live_acc >= live and not _view.is_flying():
		_live_acc = 0.0
		var build: Callable = _src.get("build", Callable())
		if build.is_valid():
			_view.set_tree(build.call(_size_by))
			_shown = -2
			_refresh_side()


func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		set_process(false)


func _on_activated(i: int) -> void:
	var acts := _actions_for(i)
	if not acts.is_empty():
		var cb: Callable = acts[0][1]
		if cb.is_valid():
			cb.call()


func _actions_for(i: int) -> Array:
	var fn: Callable = _src.get("actions", Callable())
	if not fn.is_valid() or i < 0:
		return []
	var r: Variant = fn.call(_view.node(i))
	return r if r is Array else []


func _refresh_crumbs() -> void:
	if _crumbs == null:
		return
	for c in _crumbs.get_children():
		c.queue_free()
	if _view.is_empty():
		return
	var path := CirclePack.path_to(_view.nodes, _view.focus)
	for k in path.size():
		var i := path[k]
		if k > 0:
			var sep := Label.new()
			sep.text = "›"
			sep.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			_crumbs.add_child(sep)
		var bt := Button.new()
		bt.text = UiText.fit(ThemeDB.fallback_font, str(_view.node(i)["name"]), UITheme.FONT_SM, 220.0)
		bt.name = "crumb_%d" % k
		bt.flat = true
		bt.add_theme_color_override("font_color", UITheme.C_TEXT if k == path.size() - 1 else UITheme.C_PRIMARY)
		bt.pressed.connect(func() -> void: _view.zoom_to(i))
		_crumbs.add_child(bt)


func _refresh_side() -> void:
	if _side_title == null or _view.is_empty():
		if _side_title != null:
			_side_title.text = "Nothing to show"
			_side_value.text = ""
			_side_share.text = ""
			_side_detail.text = ""
		return
	var i := _view.hover if _view.hover >= 0 else (_view.sel if _view.sel >= 0 else _view.focus)
	if i == _shown:
		return
	_shown = i
	var n := _view.node(i)
	_side_title.text = str(n["name"])
	_side_value.text = _view.value_text(i)
	var bits: Array = []
	var p := int(n["parent"])
	if p >= 0:
		var pv := float(_view.node(p)["value"])
		if pv > 0.0:
			bits.append("%s of %s" % [UiText.pct(float(n["value"]) / pv, 1), str(_view.node(p)["name"])])
		var tot := float(_view.node(0)["value"])
		if p != 0 and tot > 0.0:
			bits.append("%s of the whole" % UiText.pct(float(n["value"]) / tot, 1))
	if not bool(n["leaf"]) and str(n["unit"]) != "node":
		bits.append("%s inside" % UiText.count(CirclePack.leaf_count(_view.nodes, i), "thing"))
	_side_share.text = " · ".join(bits)
	_side_detail.text = str(n.get("detail", ""))
	for c in _side_actions.get_children():
		c.queue_free()
	for a in _actions_for(i):
		var ab := Button.new()
		ab.text = str(a[0])
		ab.name = "act_" + str(a[0]).to_snake_case()
		UITheme.style_button(ab)
		var cb: Callable = a[1]
		ab.pressed.connect(func() -> void:
			if cb.is_valid():
				cb.call())
		_side_actions.add_child(ab)
	for c in _side_kids.get_children():
		c.queue_free()
	var kids: Array = Array(n["kids"] as PackedInt32Array)
	kids.sort_custom(func(a: int, b: int) -> bool: return float(_view.node(a)["value"]) > float(_view.node(b)["value"]))
	var shown := 0
	for k in kids:
		if shown >= 14:
			var more := Label.new()
			more.text = I18n.f("and {shown} more", {"shown": UiText.count(kids.size() - shown, "other")})
			more.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			_side_kids.add_child(more)
			break
		var row := Button.new()
		row.flat = true
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var vt := _view.value_text(k)
		row.text = str(_view.node(k)["name"]) if vt.is_empty() else "%s  ·  %s" % [str(_view.node(k)["name"]), vt]
		row.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		row.clip_text = true
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.tooltip_text = row.text
		var kk := int(k)
		row.pressed.connect(func() -> void: _view.zoom_to(kk))
		row.mouse_entered.connect(func() -> void:
			_view.hover = kk
			_view.queue_redraw())
		var sw := ColorRect.new()
		sw.color = _view.node(k)["color"]
		sw.custom_minimum_size = Vector2(4, 0)
		var hb := HBoxContainer.new()
		hb.add_child(sw)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(row)
		_side_kids.add_child(hb)
		shown += 1
	if kids.is_empty():
		var lone := Label.new()
		lone.text = "Nothing further inside"
		lone.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_side_kids.add_child(lone)
