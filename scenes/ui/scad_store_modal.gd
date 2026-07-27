extends Control

## Parametric Hardware Store modal (PARAMETRIC_STORE_PLAN.md Phase 3). Browse the
## seeded OpenSCAD library (ScadStore over scad_library/catalog.json), adjust a
## part's Customizer parameters through a generated panel, render it to STL by
## shelling out to OpenSCAD on a background thread (ScadRuntime, no frame hitch),
## preview the result in a SubViewport, then Export the STL or Place it in the
## world via the PlacedProp system (MODEL_ID scad_part). Script-built UI following
## building_builder_modal.gd conventions; signals wired in _ready().

const MODAL_NAME := "scad_store"

const StoreScript := preload("res://core/scad/scad_store.gd")
const RuntimeScript := preload("res://core/scad/scad_runtime.gd")
const ParserScript := preload("res://core/scad/scad_param_parser.gd")
const PartBuilderScript := preload("res://core/scad/scad_part_builder.gd")

const EXPORT_DIR := "user://exports/scad"
const RENDER_DIR := "user://scratch/scad_store"

var _store: ScadStore = null
var _loader: Node = null
var _active := false
var _selected_id := ""
var _schema: Dictionary = {}
var _param_controls: Dictionary = {}   # name -> control node
var _last_stl := ""                     # last successfully rendered STL (user://)

# Threaded render state.
var _thread: Thread = null
var _mutex: Mutex = null
var _render_result: Dictionary = {}
var _render_done := false
var _rendering := false

# UI nodes.
var _dim: ColorRect = null
var _search: LineEdit = null
var _search_debounce: Timer = null
var _cat_list: ItemList = null
var _part_list: ItemList = null
var _title_lbl: Label = null
var _meta_lbl: RichTextLabel = null
var _license_lbl: Label = null
var _param_box: VBoxContainer = null
var _status_lbl: Label = null
var _preview_container: SubViewportContainer = null
var _generate_btn: Button = null
var _export_btn: Button = null
var _place_btn: Button = null
var _viewport: SubViewport = null
var _holder: Node3D = null
var _camera: Camera3D = null
var _cat_filter := ""


func _ready() -> void:
	name = "ScadStoreModal"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_ui()
	set_process(false)


func bind_loader(loader: Node) -> void:
	_loader = loader


func open(_arg: String = "") -> void:
	if _active:
		return
	_active = true
	visible = true
	if _store == null:
		_store = StoreScript.new()
		if not _store.load_catalog():
			_set_status("Catalog not found — run scad_ingest.gd. (%s)" % _store.error())
	_populate_categories()
	_populate_parts()
	if _has_cursor_controller():
		CursorController.request_modal(MODAL_NAME)
	set_process(true)


func close() -> void:
	if not _active and not _rendering:
		return
	_active = false
	visible = false
	if _has_cursor_controller():
		CursorController.release_modal(MODAL_NAME)
	if _rendering:
		# A render is in flight. Do NOT block the main thread on wait_to_finish
		# (that froze the game for the length of a CGAL render) and do NOT free
		# the thread while it is still running (that is a hard native crash).
		# Keep processing so the worker drains in the background; _process stops
		# itself once it completes. _exit_tree() is the teardown safety net.
		return
	set_process(false)


func _exit_tree() -> void:
	# Last-resort join: the node is being freed (scene change / quit). Freeing a
	# node whose Thread is still running crashes the engine ("thread must be
	# joined"), so we block here — only on teardown, never during play.
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null


func _unhandled_key_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(UITheme.C_BG, 0.72)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 60
	panel.offset_top = 40
	panel.offset_right = -60
	panel.offset_bottom = -40
	# Opaque, bordered chrome matching the rest of the UI.
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(1.0, UITheme.C_BG))
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_MD)
	panel.add_child(root)

	# Header row.
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "⚙  Parametric Hardware Store"
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	header.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "OpenSCAD parts · adjust, render, place"
	subtitle.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	subtitle.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	subtitle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(subtitle)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_btn := Button.new()
	close_btn.text = "Close  (Esc)"
	UITheme.style_button(close_btn)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)
	root.add_child(header)

	var hsep := HSeparator.new()
	root.add_child(hsep)

	# Body: three columns.
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UITheme.SPACE_MD)
	root.add_child(body)

	body.add_child(_build_left_column())
	body.add_child(_build_center_column())
	body.add_child(_build_right_column())

	# Status bar.
	_status_lbl = Label.new()
	_status_lbl.text = ""
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	root.add_child(_status_lbl)


func _build_left_column() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(280, 0)
	col.add_theme_constant_override("separation", UITheme.SPACE_SM)

	_search = LineEdit.new()
	_search.placeholder_text = "Search parts…"
	_search.text_changed.connect(_on_search_changed)
	col.add_child(_search)
	# Debounce search: _store.search() scans + lowercases every part; running it on
	# each keystroke is wasteful. Coalesce to one repopulate after typing settles.
	_search_debounce = Timer.new()
	_search_debounce.one_shot = true
	_search_debounce.wait_time = 0.2
	_search_debounce.timeout.connect(_populate_parts)
	add_child(_search_debounce)

	col.add_child(_section_label("Categories"))
	_cat_list = ItemList.new()
	_cat_list.custom_minimum_size = Vector2(0, 170)
	_style_list(_cat_list)
	_cat_list.item_selected.connect(_on_category_selected)
	col.add_child(_cat_list)

	col.add_child(_section_label("Parts"))
	_part_list = ItemList.new()
	_part_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_list(_part_list)
	_part_list.item_selected.connect(_on_part_selected)
	col.add_child(_part_list)
	return _panel_wrap(col)


func _build_center_column() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UITheme.SPACE_SM)

	_title_lbl = Label.new()
	_title_lbl.text = "Select a part"
	_title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_title_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	col.add_child(_title_lbl)

	# 3D preview.
	var vpc := SubViewportContainer.new()
	_preview_container = vpc
	vpc.stretch = true
	vpc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc.custom_minimum_size = Vector2(0, 280)
	_viewport = SubViewport.new()
	_viewport.transparent_bg = false
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_2X
	vpc.add_child(_viewport)
	_setup_studio()
	col.add_child(vpc)

	_meta_lbl = RichTextLabel.new()
	_meta_lbl.fit_content = true
	_meta_lbl.custom_minimum_size = Vector2(0, 84)
	_meta_lbl.bbcode_enabled = true
	_meta_lbl.add_theme_color_override("default_color", UITheme.C_TEXT_S)
	col.add_child(_meta_lbl)

	_license_lbl = Label.new()
	_license_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_license_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	col.add_child(_license_lbl)
	return _panel_wrap(col, 0, true)


func _build_right_column() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(300, 0)
	col.add_theme_constant_override("separation", UITheme.SPACE_SM)

	col.add_child(_section_label("Parameters"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_param_box = VBoxContainer.new()
	_param_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_param_box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	scroll.add_child(_param_box)
	col.add_child(scroll)

	_generate_btn = Button.new()
	_generate_btn.text = "⟳  Generate"
	UITheme.style_button(_generate_btn)
	_accent_button(_generate_btn)
	_generate_btn.pressed.connect(_on_generate)
	_generate_btn.disabled = true
	col.add_child(_generate_btn)

	_export_btn = Button.new()
	_export_btn.text = "⭳  Export STL…"
	UITheme.style_button(_export_btn)
	_export_btn.pressed.connect(_on_export)
	_export_btn.disabled = true
	col.add_child(_export_btn)

	_place_btn = Button.new()
	_place_btn.text = "⊕  Place in world"
	UITheme.style_button(_place_btn)
	_place_btn.pressed.connect(_on_place)
	_place_btn.disabled = true
	col.add_child(_place_btn)
	return _panel_wrap(col)


# -- Styling helpers -----------------------------------------------------------

## Wrap a column in an opaque card panel for structure/depth.
func _panel_wrap(inner: Control, min_w: int = 0, expand: bool = false) -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.card_style())
	if min_w > 0:
		pc.custom_minimum_size = Vector2(min_w, 0)
	if expand:
		pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_child(inner)
	return pc


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	return l


func _style_list(list: ItemList) -> void:
	list.add_theme_stylebox_override("panel", UITheme.panel_style(1.0, UITheme.C_PANEL))
	list.add_theme_color_override("font_color", UITheme.C_TEXT)
	var sel := StyleBoxFlat.new()
	sel.bg_color = Color(UITheme.C_PRIMARY, 0.22)
	sel.border_color = UITheme.C_PRIMARY
	sel.set_border_width_all(1)
	sel.set_corner_radius_all(UITheme.CORNER_RADIUS)
	list.add_theme_stylebox_override("selected", sel)
	list.add_theme_stylebox_override("selected_focus", sel)


## Tint a primary/CTA button toward the accent color.
func _accent_button(btn: Button) -> void:
	var normal := UITheme.button_style("normal")
	normal.bg_color = Color(UITheme.C_PRIMARY, 0.18)
	normal.border_color = UITheme.C_PRIMARY
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)


func _setup_studio() -> void:
	var world := Node3D.new()
	_viewport.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = UITheme.C_PANEL.darkened(0.35)
	e.ambient_light_color = Color(0.55, 0.6, 0.7)
	e.ambient_light_energy = 0.7
	env.environment = e
	world.add_child(env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, -35, 0)
	key.light_energy = 1.15
	world.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 130, 0)
	fill.light_energy = 0.4
	fill.light_color = Color(0.8, 0.85, 1.0)
	world.add_child(fill)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.25, 0.2, 0.35)
	_camera.look_at_from_position(_camera.position, Vector3(0, 0.05, 0), Vector3.UP)
	world.add_child(_camera)

	_holder = Node3D.new()
	world.add_child(_holder)


# ---------------------------------------------------------------------------
# Catalog browsing
# ---------------------------------------------------------------------------

func _populate_categories() -> void:
	_cat_list.clear()
	_cat_list.add_item("All parts")
	if _store == null:
		return
	for c in _store.categories():
		_cat_list.add_item("%s (%d)" % [c["name"], c["count"]])


func _on_category_selected(idx: int) -> void:
	if idx <= 0:
		_cat_filter = ""
	else:
		var cats: Array = _store.categories()
		if idx - 1 < cats.size():
			_cat_filter = String(cats[idx - 1]["name"])
	_populate_parts()


func _on_search_changed(_t: String) -> void:
	if _search_debounce != null:
		_search_debounce.start()
	else:
		_populate_parts()


func _populate_parts() -> void:
	_part_list.clear()
	if _store == null:
		return
	var parts: Array = []
	var q := _search.text.strip_edges()
	if not q.is_empty():
		parts = _store.search(q)
	elif _cat_filter.is_empty():
		parts = _store.customizable_parts()
	else:
		parts = _store.parts_in_category(_cat_filter)
	for p in parts:
		var badge := _status_badge(String(p.get("status", "")))
		var idx := _part_list.add_item("%s %s" % [badge, p.get("title", p.get("source_file", "?"))])
		_part_list.set_item_metadata(idx, String(p.get("id", "")))


func _status_badge(status: String) -> String:
	match status:
		"ready": return "●"
		"review": return "⚠"
		"quarantined": return "✕"
		_: return "○"


func _on_part_selected(idx: int) -> void:
	var id := String(_part_list.get_item_metadata(idx))
	_select_part(id)


func _select_part(id: String) -> void:
	_selected_id = id
	var part: Dictionary = _store.get_part(id)
	if part.is_empty():
		return
	_title_lbl.text = String(part.get("title", id))

	# Meta + description.
	var desc := String(part.get("description", ""))
	var author := String(part.get("author", ""))
	var url := String(part.get("source_url", ""))
	var meta := ""
	if not author.is_empty():
		meta += "[b]By[/b] %s   " % author
	meta += "[b]Category[/b] %s   [b]Params[/b] %d\n" % [part.get("category", "?"), part.get("param_count", 0)]
	if not desc.is_empty():
		meta += desc
	if not url.is_empty():
		meta += "\n[color=#7fb0ff]%s[/color]" % url
	_meta_lbl.text = meta

	# License line with a clear restricted warning.
	var spdx := String(part.get("license_spdx", "unknown"))
	var status := String(part.get("status", ""))
	var lic := "License: %s" % spdx
	var lic_color := UITheme.C_TEXT_S
	if status == "review":
		lic += "   ⚠ RESTRICTED (NC/ND) — needs a licensing decision before shipping"
		lic_color = UITheme.C_WARN
	elif status == "usable-dev":
		lic += "   ○ license pending verification"
		lic_color = UITheme.C_TEXT_M
	elif status == "ready":
		lic += "   ● cleared"
		lic_color = UITheme.C_OK
	_license_lbl.text = lic
	_license_lbl.add_theme_color_override("font_color", lic_color)

	# Parameters — prefer the catalog's pre-parsed schema (scad_ingest wrote it into
	# catalog.json). Re-parsing the .scad from disk on every click is redundant AND
	# breaks in exported builds, where the res://scad_library/*.scad sources may not
	# be shipped (they're data) — parse_file would then return empty. Fall back to a
	# disk parse only for legacy catalogs that predate the stored params.
	var cat_params: Array = part.get("params", [])
	if not cat_params.is_empty():
		_schema = {"params": cat_params, "groups": part.get("groups", [])}
	else:
		_schema = ParserScript.parse_file(String(part.get("res_path", "")))
	_build_param_panel()

	_generate_btn.disabled = false
	_export_btn.disabled = true
	_place_btn.disabled = true
	_last_stl = ""
	_clear_preview()
	_set_status("Adjust parameters, then Generate.")


# ---------------------------------------------------------------------------
# Parameter panel
# ---------------------------------------------------------------------------

func _build_param_panel() -> void:
	for c in _param_box.get_children():
		c.queue_free()
	_param_controls.clear()
	for p in _schema.get("params", []):
		if bool(p.get("hidden", false)):
			continue
		_param_box.add_child(_build_param_row(p))


func _build_param_row(p: Dictionary) -> Control:
	var row := VBoxContainer.new()
	var pname := String(p["name"])
	var lbl := Label.new()
	lbl.text = String(p.get("label", pname))
	lbl.tooltip_text = pname
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	row.add_child(lbl)

	var widget := String(p.get("widget", "field"))
	match widget:
		"slider":
			var h := HBoxContainer.new()
			var slider := HSlider.new()
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.min_value = float(p.get("min", 0.0))
			slider.max_value = float(p.get("max", 100.0))
			slider.step = float(p.get("step", 0.0)) if float(p.get("step", 0.0)) > 0.0 else (1.0 if p.get("type") == "int" else 0.01)
			slider.value = float(p.get("default", slider.min_value))
			var val := Label.new()
			val.custom_minimum_size = Vector2(48, 0)
			val.text = str(slider.value)
			slider.value_changed.connect(func(v): val.text = ("%d" % int(v)) if p.get("type") == "int" else ("%.2f" % v))
			h.add_child(slider)
			h.add_child(val)
			row.add_child(h)
			_param_controls[pname] = slider
		"dropdown":
			var opt := OptionButton.new()
			var options: Array = p.get("options", [])
			var def_val: Variant = p.get("default")
			for i in options.size():
				opt.add_item(str(options[i].get("label", options[i].get("value", ""))))
				opt.set_item_metadata(i, options[i].get("value"))
				if str(options[i].get("value")) == str(def_val):
					opt.select(i)
			row.add_child(opt)
			_param_controls[pname] = opt
		"checkbox":
			var cb := CheckButton.new()
			cb.button_pressed = bool(p.get("default", false))
			cb.text = "on / off"
			row.add_child(cb)
			_param_controls[pname] = cb
		_:
			var le := LineEdit.new()
			le.text = str(p.get("default", ""))
			row.add_child(le)
			_param_controls[pname] = le

	var sep := HSeparator.new()
	row.add_child(sep)
	return row


func _collect_params() -> Dictionary:
	var out: Dictionary = {}
	for p in _schema.get("params", []):
		var pname := String(p["name"])
		if not _param_controls.has(pname):
			out[pname] = p.get("default")
			continue
		var ctl: Control = _param_controls[pname]
		var ptype := String(p.get("type", "float"))
		if ctl is HSlider:
			out[pname] = int((ctl as HSlider).value) if ptype == "int" else (ctl as HSlider).value
		elif ctl is OptionButton:
			var ob := ctl as OptionButton
			# Metadata holds the typed option value; index into the selected item.
			out[pname] = ob.get_item_metadata(ob.selected) if ob.selected >= 0 else p.get("default")
		elif ctl is CheckButton:
			out[pname] = (ctl as CheckButton).button_pressed
		elif ctl is LineEdit:
			out[pname] = _coerce_text((ctl as LineEdit).text, ptype)
	return out


func _coerce_text(t: String, ptype: String) -> Variant:
	match ptype:
		"int": return t.to_int()
		"float": return t.to_float()
		"bool": return t.strip_edges().to_lower() in ["true", "1", "yes"]
		"vector":
			# Parse "[1,2,3]" / "1, 2, 3" into a float Array so ScadRuntime formats it
			# as an OpenSCAD vector literal — previously a vector field round-tripped
			# as a raw string and OpenSCAD rejected it.
			var s := t.strip_edges().trim_prefix("[").trim_suffix("]")
			var arr: Array = []
			for piece in s.split(",", false):
				arr.append(piece.strip_edges().to_float())
			return arr
		_: return t


# ---------------------------------------------------------------------------
# Threaded render
# ---------------------------------------------------------------------------

func _on_generate() -> void:
	if _rendering or _selected_id.is_empty():
		return
	if RuntimeScript.find_openscad().is_empty():
		_set_status("OpenSCAD not found — install it or set [openscad] path= in user://terrain_config.cfg")
		return
	var part: Dictionary = _store.get_part(_selected_id)
	var res_path := String(part.get("res_path", ""))
	var params := _collect_params()
	var out := RENDER_DIR.path_join("%s_%d.stl" % [_selected_id, Time.get_ticks_msec()])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RENDER_DIR))
	# Bound scratch growth: each Generate wrote a new STL and never pruned, so the
	# folder grew without limit over a session. Keep only the most recent handful
	# (the current render + a few prior for re-place/export) before writing this one.
	_prune_render_scratch(6)

	_rendering = true
	_render_done = false
	_render_result = {}
	_generate_btn.disabled = true
	# Busy cue for the multi-second CGAL render: dim the stale preview so it reads
	# as "working", not "done". Restored when the render finishes (ok or fail).
	if _preview_container != null:
		_preview_container.modulate = Color(0.45, 0.45, 0.45, 1.0)
	_set_status("Rendering… (OpenSCAD) ⏳")
	_mutex = Mutex.new()
	_thread = Thread.new()
	_thread.start(_render_worker.bind(res_path, params, out))


func _render_worker(res_path: String, params: Dictionary, out: String) -> void:
	var r: Dictionary = RuntimeScript.render_to_stl(res_path, params, out)
	_mutex.lock()
	_render_result = r
	_render_done = true
	_mutex.unlock()


func _process(_dt: float) -> void:
	if not _rendering:
		return
	var done := false
	if _mutex != null:
		_mutex.lock()
		done = _render_done
		_mutex.unlock()
	if not done:
		return
	# Finish.
	_cleanup_thread(false)
	_rendering = false
	_generate_btn.disabled = false
	if _preview_container != null:
		_preview_container.modulate = Color.WHITE  # restore from the busy dim
	# The modal may have been closed while the render drained in the background;
	# if so just stop processing and drop the result.
	if not _active:
		set_process(false)
		return
	var r := _render_result
	if not bool(r.get("ok", false)):
		_set_status("Render failed: %s" % String(r.get("reason", "unknown")).left(160))
		return
	_last_stl = String(r.get("path", ""))
	_show_preview(_last_stl)
	_export_btn.disabled = false
	_place_btn.disabled = _loader == null and _find_main() == null
	_set_status("Rendered ✔  Export or place it.")


## Delete all but the `keep` most-recently-modified STLs in the render scratch dir
## so repeated Generates can't fill the disk. Best-effort; never touches non-STLs.
func _prune_render_scratch(keep: int) -> void:
	var dir_abs := ProjectSettings.globalize_path(RENDER_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		return
	var files: Array = []
	for f in DirAccess.get_files_at(dir_abs):
		if String(f).to_lower().ends_with(".stl"):
			var full := dir_abs.path_join(String(f))
			files.append({"path": full, "mtime": FileAccess.get_modified_time(full)})
	if files.size() <= keep:
		return
	files.sort_custom(func(a, b): return a["mtime"] > b["mtime"])
	for i in range(keep, files.size()):
		DirAccess.remove_absolute(String(files[i]["path"]))


func _cleanup_thread(force: bool) -> void:
	if _thread != null and _thread.is_started():
		if force or _render_done:
			_thread.wait_to_finish()
			_thread = null
	elif force:
		_thread = null


# ---------------------------------------------------------------------------
# Preview / export / place
# ---------------------------------------------------------------------------

func _clear_preview() -> void:
	if _holder == null:
		return
	for c in _holder.get_children():
		c.queue_free()


func _show_preview(stl_path: String) -> void:
	_clear_preview()
	var node := PartBuilderScript.build_node({"stl_path": stl_path})
	_holder.add_child(node)
	_frame_camera(node)


func _frame_camera(node: Node3D) -> void:
	# Rough framing from the mesh AABB.
	var mi := node.get_node_or_null("PartMesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	var aabb := mi.get_aabb()
	var size := aabb.size.length()
	if size <= 0.0:
		size = 0.3
	var center := aabb.position + aabb.size * 0.5
	var dist := maxf(size * 1.4, 0.15)
	var pos := center + Vector3(dist * 0.7, dist * 0.6, dist)
	_camera.position = pos
	_camera.look_at_from_position(pos, center, Vector3.UP)


func _on_export() -> void:
	if _last_stl.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EXPORT_DIR))
	var part: Dictionary = _store.get_part(_selected_id)
	var base := String(part.get("id", "part"))
	var dest := EXPORT_DIR.path_join("%s_%d.stl" % [base, Time.get_ticks_msec()])
	var data := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(_last_stl))
	if data.is_empty():
		_set_status("Export failed: rendered STL missing")
		return
	var f := FileAccess.open(ProjectSettings.globalize_path(dest), FileAccess.WRITE)
	if f == null:
		_set_status("Export failed: cannot write %s" % dest)
		return
	f.store_buffer(data)
	f.close()
	_set_status("Exported STL → %s" % ProjectSettings.globalize_path(dest))


func _on_place() -> void:
	if _last_stl.is_empty():
		return
	var main := _find_main()
	if main == null:
		_set_status("Place failed: no world (open a map first)")
		return
	var part: Dictionary = _store.get_part(_selected_id)
	# Copy the render into a stable per-placement location (scratch is transient).
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://scad_parts"))
	var stable := "user://scad_parts/%s_%d.stl" % [part.get("id", "part"), Time.get_ticks_msec()]
	var data := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(_last_stl))
	var f := FileAccess.open(ProjectSettings.globalize_path(stable), FileAccess.WRITE)
	if f != null:
		f.store_buffer(data)
		f.close()
	var scad_spec := {
		"stl_path": stable,
		"label": part.get("title", "SCAD part"),
		"part_id": part.get("id", ""),
	}
	var prep := {"record_extra": {"scad_spec": scad_spec}, "scad_spec": scad_spec}
	close()
	var res: Dictionary = PlacedPropService.begin_placement(main, PartBuilderScript.MODEL_ID, prep)
	if not bool(res.get("ok", false)):
		_set_status("Place failed: %s" % String(res.get("error", "?")))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _find_main() -> Node:
	if _loader != null and is_instance_valid(_loader):
		var m := _loader.get_node_or_null("/root/Main")
		if m != null:
			return m
	var n: Node = self
	while n != null:
		if n.name == "Main" or n.has_method("apply_location"):
			return n
		n = n.get_parent()
	return get_tree().current_scene


func _set_status(t: String) -> void:
	if _status_lbl != null:
		_status_lbl.text = t


func _has_cursor_controller() -> bool:
	return Engine.has_singleton("CursorController") or (get_tree() != null and get_tree().root.has_node("CursorController"))
