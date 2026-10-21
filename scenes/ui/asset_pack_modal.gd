class_name AssetPackModal
extends Node

## Share — export your worlds, models and settings as one zip for a friend,
## and install one a friend sent you. One modal, two tabs:
##
##   Export   tick what goes (worlds, each with its map data; your content
##            libraries; settings, off by default; the gitignored game art,
##            when running from the project folder), see the size, pick
##            where to save. Packs past 3.5 GB are split into numbered parts
##            (AssetPackWriter).
##   Install  choose a pack (or drop it on the window), preview who made it
##            and what is inside, untick what you do not want, install.
##            Game art makes Godot import it in a separate process; then the
##            game restarts.
##
## The work happens in core/sharing/ on a worker thread (AssetPackJob); this
## file is only the UI. Open it with open_export / open_import.

const NODE_NAME := "AssetPackModal"
const PREFS := "user://ui_prefs.cfg"
const SECTION_LABELS := {
	"worlds": "Worlds", "mapcache": "Map data", "library": "Your content",
	"settings": "Settings", "project": "Game art",
}

enum View { EXPORT, IMPORT, PROGRESS, DONE }

var _frame: ModalFrame = null
var _tab_export: Button = null
var _tab_import: Button = null
var _boxes := {}
var _view := View.EXPORT
var _tab := View.EXPORT
var _job: AssetPackJob = null
var _close_when_idle := false

# Export
var _catalog: AssetPackCatalog = null
var _sel := {}
var _checks := {}                  # item id -> Array[CheckBox]
var _mapcache_checks := {}         # world item id -> CheckBox of its map data
var _art_auto := true
var _preselect_world := ""
var _creator_edit: LineEdit = null
var _total_lbl: Label = null
var _export_btn: Button = null
var _file_dialog: FileDialog = null

# Import
var _info := {}
var _imp_world_checks := {}        # old world id -> CheckBox
var _imp_sec_checks := {}          # section -> CheckBox
var _installer: AssetPackInstaller = null
var _reimport_pid := -1
var _reimport_t0 := 0
var _reopen_when_imported := false

# Progress / done
var _prog_title: Label = null
var _prog_bar: ProgressBar = null
var _prog_detail: Label = null
var _done_box: VBoxContainer = null
var _reimport_lbl: Label = null
var _reimport_bar: ProgressBar = null


## Open on the Export tab; `world_id` ticks just that world.
static func open_export(host: Node, world_id: String = "") -> AssetPackModal:
	var m := _instance(host)
	if m == null:
		return null
	m._preselect_world = world_id
	m._show_tab(View.EXPORT)
	return m


## Open on the Install tab; with a path, preview that pack straight away.
static func open_import(host: Node, path: String = "") -> AssetPackModal:
	var m := _instance(host)
	if m == null:
		return null
	m._show_tab(View.IMPORT)
	if not path.is_empty():
		m._open_pack(path)
	return m


static func _instance(host: Node) -> AssetPackModal:
	if host == null or host.get_tree() == null:
		return null
	var t := host.get_tree()
	var parent: Node = t.current_scene if t.current_scene != null else t.root
	var ex := parent.get_node_or_null(NODE_NAME)
	if ex is AssetPackModal:
		(ex as AssetPackModal)._frame.open()
		return ex
	var m := AssetPackModal.new()
	m.name = NODE_NAME
	parent.add_child(m)
	return m


func _ready() -> void:
	_frame = ModalFrame.create("Share", "Pass your worlds, models and settings to a friend as one zip",
		Vector2(1080, 800), "asset_pack")
	add_child(_frame)
	_frame.closed.connect(_on_frame_closed)
	_job = AssetPackJob.new()
	add_child(_job)
	_job.finished.connect(_on_job_finished)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	_frame.body.add_child(tabs)
	var group := ButtonGroup.new()
	_tab_export = _tab_button(tabs, "Export a pack", "upload", group)
	_tab_export.pressed.connect(_show_tab.bind(View.EXPORT))
	_tab_import = _tab_button(tabs, "Install a pack", "download", group)
	_tab_import.pressed.connect(_show_tab.bind(View.IMPORT))
	for v in [View.EXPORT, View.IMPORT, View.PROGRESS, View.DONE]:
		var b := VBoxContainer.new()
		b.add_theme_constant_override("separation", 8)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.visible = false
		_frame.body.add_child(b)
		_boxes[v] = b
	_build_progress(_boxes[View.PROGRESS])
	_done_box = _boxes[View.DONE]
	_build_import_empty()
	_frame.open()
	set_process(false)


func _tab_button(parent: Control, text: String, icon: String, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(150, 32)
	UITheme.style_button(b)
	UiIcons.apply(b, icon, "", 16)
	b.text = text
	parent.add_child(b)
	return b


func _show_tab(tab: int) -> void:
	if _job != null and _job.running():
		return
	_tab = tab
	if _tab_export != null:
		_tab_export.set_pressed_no_signal(tab == View.EXPORT)
		_tab_import.set_pressed_no_signal(tab == View.IMPORT)
	if tab == View.EXPORT and _catalog == null:
		_scan_catalog()
	elif tab == View.EXPORT and not _preselect_world.is_empty():
		_apply_preselect()
	_set_view(tab)


func _set_view(v: int) -> void:
	_view = v
	for k in _boxes:
		(_boxes[k] as Control).visible = k == v
	if _tab_export != null:
		_tab_export.disabled = v == View.PROGRESS
		_tab_import.disabled = v == View.PROGRESS
	_frame.close_on_backdrop = v != View.PROGRESS
	_rebuild_footer()


func _rebuild_footer() -> void:
	for c in _frame.footer.get_children():
		_frame.footer.remove_child(c)
		c.queue_free()
	match _view:
		View.EXPORT:
			_total_lbl = Label.new()
			_total_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_total_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
			_total_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			_frame.footer.add_child(_total_lbl)
			_frame.add_button("Close", ModalFrame.SECONDARY, _frame.close)
			_export_btn = _frame.add_button("Export…", ModalFrame.PRIMARY, _on_export_pressed,
				"Choose where to save the pack.")
			_refresh_totals()
		View.IMPORT:
			_frame.add_button("Close", ModalFrame.SECONDARY, _frame.close)
			if not _info.is_empty() and bool(_info.get("ok", false)):
				_frame.add_button("Install", ModalFrame.PRIMARY, _on_install_pressed,
					"Add the ticked parts of this pack to your game.")
		View.PROGRESS:
			_frame.add_button("Cancel", ModalFrame.DESTRUCTIVE, func() -> void: _job.cancel())
		View.DONE:
			_frame.add_button("Close", ModalFrame.PRIMARY, _frame.close)
	_frame.footer.visible = true


# -- Export ---------------------------------------------------------------------------

func _scan_catalog() -> void:
	var box: VBoxContainer = _boxes[View.EXPORT]
	_clear(box)
	box.add_child(_muted("Looking through your worlds, models and settings…"))
	var pr := ProjectSettings.globalize_path("res://").trim_suffix("/") \
		if AssetPackFormat.running_from_source() else ""
	_job.set_meta("kind", "catalog")
	_job.start(func(_p: AssetPackProgress) -> Variant:
		return AssetPackCatalog.build({"project_root": pr}))


func _build_export(cat: AssetPackCatalog) -> void:
	_catalog = cat
	_sel = cat.default_selection()
	_checks.clear()
	_mapcache_checks.clear()
	var box: VBoxContainer = _boxes[View.EXPORT]
	_clear(box)

	var who := HBoxContainer.new()
	who.add_theme_constant_override("separation", 8)
	box.add_child(who)
	var wl := Label.new()
	wl.text = "From"
	wl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	who.add_child(wl)
	_creator_edit = LineEdit.new()
	_creator_edit.custom_minimum_size = Vector2(260, 0)
	_creator_edit.placeholder_text = "Your name (shown to your friend)"
	_creator_edit.text = _default_creator()
	who.add_child(_creator_edit)

	# Worlds
	var worlds := cat.items_in(AssetPackFormat.SEC_WORLDS)
	var wh := SectionHeader.make("Worlds", "globe", "Each world arrives on their machine as a new world")
	box.add_child(wh)
	if worlds.is_empty():
		box.add_child(_muted("You have no worlds yet."))
	else:
		var allrow := HBoxContainer.new()
		allrow.add_theme_constant_override("separation", 6)
		box.add_child(allrow)
		allrow.add_child(_small_button("All worlds", func() -> void: _set_all_worlds(true)))
		allrow.add_child(_small_button("None", func() -> void: _set_all_worlds(false)))
		for it in worlds:
			box.add_child(_world_row(it))

	# Content
	var lib := cat.items_in(AssetPackFormat.SEC_LIBRARY)
	if not lib.is_empty():
		box.add_child(SectionHeader.make("Your content", "package",
			"Added beside your friend's own; nothing of theirs is replaced"))
		for it in lib:
			box.add_child(_item_row(it))

	# Settings
	var sets := cat.items_in(AssetPackFormat.SEC_SETTINGS)
	if not sets.is_empty():
		box.add_child(SectionHeader.make("Settings", "sliders-horizontal",
			"Off unless you tick them; your friend is asked again"))
		var col := Collapsible.make("Choose settings to include", false)
		box.add_child(col)
		for it in sets:
			col.body.add_child(_item_row(it))

	# Game art
	box.add_child(SectionHeader.make("Game art", "box",
		"The models and maps that are not on GitHub"))
	if cat.project_root.is_empty():
		var al := AlertBanner.new()
		box.add_child(al)
		al.show_alert(AlertBanner.INFO, "Game art can only be shared from a copy of the game opened from its project folder (a GitHub clone). Worlds, your content and settings still travel.")
	else:
		var art := cat.items_in(AssetPackFormat.SEC_ART)
		var arow := HBoxContainer.new()
		arow.add_theme_constant_override("separation", 6)
		box.add_child(arow)
		arow.add_child(_small_button("Tick what my worlds need", func() -> void:
			_art_auto = true
			_apply_art_auto()))
		arow.add_child(_small_button("All art", func() -> void:
			_art_auto = false
			for it2 in art:
				_set_sel(str(it2["id"]), true)))
		arow.add_child(_small_button("None", func() -> void:
			_art_auto = false
			for it3 in art:
				_set_sel(str(it3["id"]), false)))
		arow.add_child(_muted("Your friend's game imports it, then restarts."))
		for it in art:
			box.add_child(_item_row(it))

	# Never
	box.add_child(SectionHeader.make("Never included", "lock"))
	var never := _muted("API keys and accounts (OpenTopography, Gemini, Mapillary, Copernicus), Home Assistant, Discord and multiplayer sign-ins, your home location, downloaded tools, and caches and logs the game rebuilds.")
	never.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(never)

	if not _preselect_world.is_empty():
		_apply_preselect()
	else:
		_apply_art_auto()
	_refresh_checks()
	_refresh_totals()


func _world_row(it: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	panel.add_child(h)
	var cb := CheckBox.new()
	cb.focus_mode = Control.FOCUS_NONE
	_bind_check(cb, str(it["id"]))
	h.add_child(cb)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(96, 54)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var tp := str(it.get("thumb", ""))
	if not tp.is_empty():
		var img := Image.load_from_file(tp)
		if img != null and not img.is_empty():
			thumb.texture = ImageTexture.create_from_image(img)
	h.add_child(thumb)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 2)
	h.add_child(v)
	var nm := Label.new()
	nm.text = str(it["label"])
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.tooltip_text = nm.text
	nm.mouse_filter = Control.MOUSE_FILTER_PASS
	nm.add_theme_color_override("font_color", UITheme.C_TEXT)
	v.add_child(nm)
	var mc_id := ""
	for n in it.get("needs", []):
		if str(n).begins_with("mapcache:"):
			mc_id = str(n)
	if not mc_id.is_empty():
		var mc := _catalog.item(mc_id)
		var mcb := CheckBox.new()
		mcb.focus_mode = Control.FOCUS_NONE
		mcb.text = "Map data · %s" % AssetPackFormat.human_size(int(mc.get("size", 0)))
		mcb.tooltip_text = ("Elevation, aerial imagery, buildings, vegetation and weather for this place, "
			+ "so it looks exactly the same and loads without internet. Without it, your friend's "
			+ "game downloads the map again (today's map data may differ slightly).")
		mcb.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		_bind_check(mcb, mc_id)
		_mapcache_checks[str(it["id"])] = mcb
		v.add_child(mcb)
	else:
		v.add_child(_muted(str(it.get("sub", ""))))
	var size := Label.new()
	size.text = AssetPackFormat.human_size(int(it.get("size", 0)))
	size.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	size.add_theme_font_override("font", UITheme.font("regular", true))
	h.add_child(size)
	return panel


func _item_row(it: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var cb := CheckBox.new()
	cb.focus_mode = Control.FOCUS_NONE
	cb.text = str(it["label"])
	cb.tooltip_text = str(it.get("sub", ""))
	cb.custom_minimum_size = Vector2(260, 0)
	_bind_check(cb, str(it["id"]))
	h.add_child(cb)
	var sub := _muted(str(it.get("sub", "")))
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.tooltip_text = sub.text
	sub.mouse_filter = Control.MOUSE_FILTER_PASS
	h.add_child(sub)
	var size := Label.new()
	size.text = AssetPackFormat.human_size(int(it.get("size", 0)))
	size.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	size.add_theme_font_override("font", UITheme.font("regular", true))
	h.add_child(size)
	return h


func _bind_check(cb: CheckBox, id: String) -> void:
	if not _checks.has(id):
		_checks[id] = []
	(_checks[id] as Array).append(cb)
	cb.button_pressed = bool(_sel.get(id, false))
	cb.toggled.connect(func(on: bool) -> void:
		if id.begins_with("art:"):
			_art_auto = false
		_set_sel(id, on)
		if id.begins_with("world:") and _art_auto:
			_apply_art_auto())


func _set_sel(id: String, on: bool) -> void:
	_sel[id] = on
	for cb in _checks.get(id, []):
		(cb as CheckBox).set_pressed_no_signal(on)
	_refresh_checks()
	_refresh_totals()


func _set_all_worlds(on: bool) -> void:
	for it in _catalog.items_in(AssetPackFormat.SEC_WORLDS):
		_sel[str(it["id"])] = on
	if _art_auto:
		_apply_art_auto()
	_refresh_checks()
	_refresh_totals()


func _apply_preselect() -> void:
	if _catalog == null:
		return
	for it in _catalog.items_in(AssetPackFormat.SEC_WORLDS):
		_sel[str(it["id"])] = str(it.get("world_id", "")) == _preselect_world
	_preselect_world = ""
	_art_auto = true
	_apply_art_auto()


func _apply_art_auto() -> void:
	if _catalog == null:
		return
	var need := _catalog.art_needed_by(_sel)
	for it in _catalog.items_in(AssetPackFormat.SEC_ART):
		_sel[str(it["id"])] = need.has(str(it["id"]))
	_refresh_checks()
	_refresh_totals()


func _refresh_checks() -> void:
	for id in _checks:
		for cb in _checks[id]:
			(cb as CheckBox).set_pressed_no_signal(bool(_sel.get(id, false)))
	for wid in _mapcache_checks:
		var on := bool(_sel.get(wid, false))
		var mcb: CheckBox = _mapcache_checks[wid]
		mcb.disabled = not on
		mcb.modulate.a = 1.0 if on else 0.35


func _refresh_totals() -> void:
	if _total_lbl == null or not is_instance_valid(_total_lbl):
		return
	if _catalog == null:
		_total_lbl.text = ""
		if _export_btn != null:
			_export_btn.disabled = true
		return
	var bytes := _catalog.size_of_selection(_sel)
	var worlds := 0
	for it in _catalog.items_in(AssetPackFormat.SEC_WORLDS):
		if _sel.get(str(it["id"]), false):
			worlds += 1
	var parts := int(ceil(float(bytes) / float(AssetPackFormat.PART_MAX_BYTES)))
	var txt := "%s · %s" % [UiText.count(worlds, "world"), AssetPackFormat.human_size(bytes)]
	if parts > 1:
		txt += " · saved as %d files (send all of them)" % parts
	_total_lbl.text = txt
	if _export_btn != null and is_instance_valid(_export_btn):
		_export_btn.disabled = bytes <= 0


func _default_creator() -> String:
	var cf := ConfigFile.new()
	if cf.load(PREFS) == OK and not str(cf.get_value("share", "creator", "")).is_empty():
		return str(cf.get_value("share", "creator", ""))
	var mp := ConfigFile.new()
	if mp.load("user://mp_prefs.cfg") == OK:
		var n := str(mp.get_value("mp", "display_name", ""))
		if not n.is_empty():
			return n
	return ""


func _on_export_pressed() -> void:
	var fd := _dialog(FileDialog.FILE_MODE_SAVE_FILE)
	var who := _creator_edit.text.strip_edges() if _creator_edit != null else ""
	var stem := (who if not who.is_empty() else "SIMbiogenesis").validate_filename().replace(" ", "_")
	fd.current_file = "%s-%s%s" % [stem, Time.get_date_string_from_system(), AssetPackFormat.EXT]
	fd.file_selected.connect(_start_export, CONNECT_ONE_SHOT)
	fd.popup_centered_ratio(0.6)


func _start_export(path: String) -> void:
	var p := path
	if not p.to_lower().ends_with(AssetPackFormat.EXT):
		p = p.trim_suffix(".zip").trim_suffix(".simpack") + AssetPackFormat.EXT
	var creator := _creator_edit.text.strip_edges() if _creator_edit != null else ""
	var cf := ConfigFile.new()
	cf.load(PREFS)
	cf.set_value("share", "creator", creator)
	cf.save(PREFS)
	# The running world first, then every ticked world's library copies.
	var main := _main()
	var active := WorldSession.active_id()
	for it in _catalog.items_in(AssetPackFormat.SEC_WORLDS):
		if not _sel.get(str(it["id"]), false):
			continue
		if str(it.get("world_id", "")) == active and main != null:
			WorldSession.save_now(main, true, false)
		else:
			WorldAssets.collect(it.get("rec", {}))
	var resolved := _catalog.resolve(_sel)
	var meta := AssetPackWriter.build_meta(resolved, creator)
	var entries: Array = resolved["entries"]
	_show_progress("Packing %s…" % AssetPackFormat.human_size(int(resolved["bytes"])))
	_job.set_meta("kind", "export")
	_job.start(func(prog: AssetPackProgress) -> Variant:
		return AssetPackWriter.write(p, entries, meta, prog))


func _export_done(r: Dictionary) -> void:
	_clear(_done_box)
	if not bool(r.get("ok", false)):
		_done_box.add_child(_alert(AlertBanner.ERROR if str(r.get("error", "")) != "Cancelled" else AlertBanner.INFO,
			"Not saved: %s" % str(r.get("error", "unknown error"))))
		_set_view(View.DONE)
		return
	var parts: Array = r.get("parts", [])
	_done_box.add_child(_alert(AlertBanner.OK, "Saved %s (%s)." % [UiText.count(parts.size(), "file"),
		AssetPackFormat.human_size(int(r.get("bytes", 0)))]))
	for pth in parts:
		var l := Label.new()
		l.text = ProjectSettings.globalize_path(str(pth))
		l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		l.add_theme_font_override("font", UITheme.font("regular", true))
		_done_box.add_child(l)
	var how := _muted(("Send %s to your friend. In SIMbiogenesis they press Share → Install a pack, "
		+ "or drop the zip onto the game window.") % ("this file" if parts.size() == 1 else "all of these files, in one folder,"))
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_done_box.add_child(how)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_done_box.add_child(row)
	var first := str(parts[0]) if not parts.is_empty() else ""
	row.add_child(_small_button("Show in folder", func() -> void:
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path(first))))
	row.add_child(_small_button("Export something else", func() -> void: _show_tab(View.EXPORT)))
	_set_view(View.DONE)


# -- Import ---------------------------------------------------------------------------

func _build_import_empty() -> void:
	var box: VBoxContainer = _boxes[View.IMPORT]
	_clear(box)
	var drop := PanelContainer.new()
	drop.add_theme_stylebox_override("panel", UITheme.card_style())
	drop.custom_minimum_size = Vector2(0, 160)
	box.add_child(drop)
	var c := VBoxContainer.new()
	c.alignment = BoxContainer.ALIGNMENT_CENTER
	c.add_theme_constant_override("separation", 10)
	drop.add_child(c)
	var l := Label.new()
	l.text = "Drop a .simpack.zip onto this window, or"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	c.add_child(l)
	var b := Button.new()
	b.text = "Choose pack…"
	UITheme.style_button(b)
	UiIcons.apply(b, "folder-open", "Find the pack your friend sent you.", 16)
	b.text = "Choose pack…"
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(func() -> void:
		var fd := _dialog(FileDialog.FILE_MODE_OPEN_FILE)
		fd.file_selected.connect(_open_pack, CONNECT_ONE_SHOT)
		fd.popup_centered_ratio(0.6))
	c.add_child(b)


func _open_pack(path: String) -> void:
	if _job.running():
		return
	_show_tab(View.IMPORT)
	var box: VBoxContainer = _boxes[View.IMPORT]
	_clear(box)
	box.add_child(_muted("Reading %s…" % path.get_file()))
	_job.set_meta("kind", "read")
	_job.start(func(_p: AssetPackProgress) -> Variant:
		return AssetPackReader.open(path))


func _build_import_preview(info: Dictionary) -> void:
	_info = info
	_imp_world_checks.clear()
	_imp_sec_checks.clear()
	var box: VBoxContainer = _boxes[View.IMPORT]
	_clear(box)
	if not bool(info.get("ok", false)):
		box.add_child(_alert(AlertBanner.ERROR, str(info.get("error", "This pack cannot be installed."))))
		box.add_child(_small_button("Choose another pack…", _build_import_empty))
		_rebuild_footer()
		return
	var man: Dictionary = info["manifest"]
	var who := str(man.get("creator", "")).strip_edges()
	var when := Time.get_datetime_string_from_unix_time(int(man.get("created_unix", 0)), true)
	var head := Label.new()
	head.text = "From %s · %s · %s" % [who if not who.is_empty() else "someone", when.substr(0, 16),
		AssetPackFormat.human_size(int(man.get("bytes", 0)))]
	head.add_theme_font_override("font", UITheme.font("semibold"))
	head.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	box.add_child(head)
	for w in info.get("warnings", []):
		box.add_child(_alert(AlertBanner.WARN, str(w)))
	var secs: Dictionary = info.get("sections", {})
	var worlds: Array = man.get("worlds", [])
	if not worlds.is_empty():
		box.add_child(SectionHeader.make("Worlds", "globe", "Each arrives as a new world; yours are never touched"))
		for w in worlds:
			box.add_child(_import_world_row(w))
	var notes := {
		"mapcache": "So these places look the same and load offline. Only what you do not already have is added.",
		"library": "Their models, music, presets and designs. Added beside yours; nothing of yours is replaced.",
		"settings": "Their graphics, display and other settings. Replaces yours; yours are backed up first.",
		"project": "Models and maps that are not on GitHub, written into the game folder. Godot then imports them (this can take several minutes) and the game restarts.",
	}
	var any_sec := false
	for sec in ["mapcache", "library", "settings", "project"]:
		if not secs.has(sec):
			continue
		if not any_sec:
			box.add_child(SectionHeader.make("Also in this pack", "package"))
			any_sec = true
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		box.add_child(h)
		var cb := CheckBox.new()
		cb.focus_mode = Control.FOCUS_NONE
		cb.text = str(SECTION_LABELS.get(sec, sec))
		cb.custom_minimum_size = Vector2(160, 0)
		cb.button_pressed = sec != "settings"
		if sec == "project" and not AssetPackFormat.running_from_source():
			cb.button_pressed = false
			cb.disabled = true
			cb.tooltip_text = ("This copy of the game gets its art from the art add-on: the "
				+ "simbiogenesis-art-*.pck files from the release page, placed next to the game "
				+ "(%s). The pack's art is only needed by a copy opened from its project folder."
				% ("art add-on loaded" if ArtPackMount.has_art() else "not found yet"))
		_imp_sec_checks[sec] = cb
		h.add_child(cb)
		var n := _muted(str(notes.get(sec, "")))
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(n)
		var s := Label.new()
		s.text = AssetPackFormat.human_size(int((secs[sec] as Dictionary).get("bytes", 0)))
		s.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		s.add_theme_font_override("font", UITheme.font("regular", true))
		h.add_child(s)
	box.add_child(_small_button("Choose a different pack…", _build_import_empty))
	_rebuild_footer()


func _import_world_row(w: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	panel.add_child(h)
	var cb := CheckBox.new()
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = true
	_imp_world_checks[str(w.get("id", ""))] = cb
	h.add_child(cb)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(96, 54)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.texture = _pack_thumb(str(w.get("thumb", "")))
	h.add_child(thumb)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	var nm := Label.new()
	nm.text = str(w.get("name", "World"))
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.add_theme_color_override("font_color", UITheme.C_TEXT)
	v.add_child(nm)
	var site := str(w.get("site", ""))
	if site.is_empty():
		site = str(w.get("scene", "")).get_file().get_basename()
	var hours := float(w.get("playtime_s", 0.0)) / 3600.0
	var bits: Array[String] = []
	if site != nm.text:
		bits.append(site)
	if hours >= 0.1:
		bits.append("%.1f h played" % hours)
	if not bits.is_empty():
		var sub := _muted(" · ".join(PackedStringArray(bits)))
		sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.add_child(sub)
	return panel


func _pack_thumb(zip_path: String) -> Texture2D:
	if zip_path.is_empty() or not (_info.get("where", {}) as Dictionary).has(zip_path):
		return null
	var parts: Array = _info.get("parts", [])
	var zr := ZIPReader.new()
	if zr.open(str(parts[int(_info["where"][zip_path])])) != OK:
		return null
	var data := zr.read_file(zip_path)
	zr.close()
	var img := Image.new()
	if img.load_png_from_buffer(data) != OK:
		return null
	return ImageTexture.create_from_image(img)


func _on_install_pressed() -> void:
	var worlds: Array = []
	for id in _imp_world_checks:
		if (_imp_world_checks[id] as CheckBox).button_pressed:
			worlds.append(str(id))
	var pick := func(sec: String) -> bool:
		return _imp_sec_checks.has(sec) and (_imp_sec_checks[sec] as CheckBox).button_pressed \
			and not (_imp_sec_checks[sec] as CheckBox).disabled
	var choices := {"worlds": worlds, "mapcache": pick.call("mapcache"), "library": pick.call("library"),
		"settings": pick.call("settings"), "art": pick.call("project")}
	var pr := ProjectSettings.globalize_path("res://").trim_suffix("/") \
		if AssetPackFormat.running_from_source() else ""
	_installer = AssetPackInstaller.create(_info, choices, {"project_root": pr})
	var main := _main()
	if main != null and WorldPaths.has_active_world():
		WorldSession.save_now(main, true, false)
	_show_progress("Installing…")
	_job.set_meta("kind", "install")
	var ins := _installer
	_job.start(func(prog: AssetPackProgress) -> Variant:
		return ins.extract(prog))


func _install_done(_extract_result: Variant) -> void:
	var r := _installer.finish()
	_clear(_done_box)
	if not bool(r.get("ok", false)):
		_done_box.add_child(_alert(AlertBanner.ERROR if str(r.get("error", "")) != "Cancelled" else AlertBanner.INFO,
			"Not installed: %s" % str(r.get("error", "unknown error"))))
		_set_view(View.DONE)
		return
	get_tree().call_group("world_list_listeners", "refresh_world_list")
	var lines: Array[String] = []
	var worlds: Array = r.get("worlds", [])
	lines.append("Installed %s." % UiText.count(worlds.size(), "world"))
	if int(r.get("catalog_added", 0)) > 0:
		lines.append("%s added to your library." % UiText.count(int(r["catalog_added"]), "model"))
	if int(r.get("kept_both", 0)) > 0:
		lines.append("%s you both had but that differ: theirs were saved beside yours." \
			% UiText.count(int(r["kept_both"]), "file"))
	if int(r.get("kept_yours", 0)) > 0:
		lines.append("Kept your own %s (their worlds still carry their copy)." \
			% UiText.count(int(r["kept_yours"]), "preset library", "preset libraries"))
	if int(r.get("settings", 0)) > 0:
		lines.append("Applied %s; your previous ones are in %s." % [UiText.count(int(r["settings"]), "settings file"),
			ProjectSettings.globalize_path(str(r.get("backup_dir", "")))])
	_done_box.add_child(_alert(AlertBanner.OK, " ".join(PackedStringArray(lines))))
	var damaged: Array = r.get("damaged", [])
	if not damaged.is_empty():
		_done_box.add_child(_alert(AlertBanner.WARN, "%s in the pack were damaged and skipped: %s" \
			% [UiText.count(damaged.size(), "file"), ", ".join(PackedStringArray(damaged.slice(0, 5).map(func(x): return str(x).get_file())))]))
	var need_restart := _installer.needs_reimport()
	for w in worlds:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_done_box.add_child(row)
		var l := Label.new()
		l.text = str(w["name"])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(l)
		var play := _small_button("Play", _play_world.bind(str(w["id"])))
		play.disabled = need_restart
		if need_restart:
			play.tooltip_text = "Restart the game first so the new art is loaded."
		row.add_child(play)
		# Imagery made at another quality than this computer's: keep it, or
		# download it at this computer's (the saved copy stays as the fallback).
		var wrec := WorldStore.get_world(str(w["id"]))
		var isum := TerrainImageryPlan.summary_for_record(wrec, WorldStore.read_snapshot(str(w["id"])))
		if TerrainImageryChoice.has_choice(isum):
			var choice := TerrainImageryChoice.create()
			choice.show_summary(isum)
			choice.mode_chosen.connect(_set_world_imagery_mode.bind(str(w["id"])))
			_done_box.add_child(choice)
	if need_restart:
		_start_reimport()
	_set_view(View.DONE)


func _set_world_imagery_mode(mode: String, id: String) -> void:
	var rec := WorldStore.get_world(id)
	if rec.is_empty():
		return
	var ti: Dictionary = rec.get("terrain_imagery", {}) if rec.get("terrain_imagery", {}) is Dictionary else {}
	ti["mode"] = "saved" if mode == "saved" else "local"
	rec["terrain_imagery"] = ti
	WorldStore.save_record(rec)


func _play_world(id: String) -> void:
	var rec := WorldStore.get_world(id)
	if rec.is_empty():
		return
	var main := _main()
	if main != null and WorldPaths.has_active_world():
		WorldSession.save_now(main, true, true)
	_frame.close()
	WorldSession.launch(rec)


# -- Game art: import + restart --------------------------------------------------------

func _start_reimport() -> void:
	var sh := SectionHeader.make("Game art", "box")
	_done_box.add_child(sh)
	_reimport_lbl = Label.new()
	_reimport_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reimport_lbl.text = "Godot is importing %s of new art. This can take several minutes…" \
		% UiText.count(int(_installer.result.get("art_files", 0)), "file")
	_done_box.add_child(_reimport_lbl)
	_reimport_bar = ProgressBar.new()
	_reimport_bar.indeterminate = true
	_reimport_bar.custom_minimum_size = Vector2(0, 10)
	UITheme.style_progress(_reimport_bar)
	_done_box.add_child(_reimport_bar)
	_reimport_pid = AssetPackInstaller.start_reimport()
	_reimport_t0 = Time.get_ticks_msec()
	if _reimport_pid < 0:
		_reimport_finished(false)
		return
	set_process(true)


func _reimport_finished(ok: bool) -> void:
	_reimport_pid = -1
	if _reopen_when_imported:
		_reopen_when_imported = false
		_frame.open()
	if _reimport_bar != null:
		_reimport_bar.visible = false
	if ok:
		_reimport_lbl.text = "The new art is imported. Restart the game to load it."
	else:
		_reimport_lbl.text = ("Godot could not import the art from here. Open the project in the Godot "
			+ "editor once (it imports new files when it starts), then run the game again.")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_done_box.add_child(row)
	var rb := _small_button("Restart now", func() -> void:
		AssetPackInstaller.restart_game(get_tree()))
	rb.disabled = not ok
	row.add_child(rb)
	row.add_child(_muted("Your worlds are saved; nothing is lost by restarting."))


func _process(_dt: float) -> void:
	if _view == View.PROGRESS:
		var s := _job.progress.snapshot()
		_prog_bar.value = float(s["fraction"])
		_prog_detail.text = "%s of %s · %s" % [AssetPackFormat.human_size(int(s["done"])),
			AssetPackFormat.human_size(int(s["total"])), str(s["label"])]
	if _reimport_pid >= 0:
		if OS.is_process_running(_reimport_pid):
			var secs := (Time.get_ticks_msec() - _reimport_t0) / 1000
			_reimport_lbl.text = "Godot is importing %s of new art (%d:%02d so far). This can take several minutes…" \
				% [UiText.count(int(_installer.result.get("art_files", 0)), "file"), secs / 60, secs % 60]
		else:
			_reimport_finished(OS.get_process_exit_code(_reimport_pid) == 0)
	if _view != View.PROGRESS and _reimport_pid < 0:
		set_process(false)


# -- Jobs ------------------------------------------------------------------------------

func _show_progress(title: String) -> void:
	_prog_title.text = title
	_prog_bar.value = 0.0
	_prog_detail.text = ""
	_set_view(View.PROGRESS)
	set_process(true)


func _build_progress(box: VBoxContainer) -> void:
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_prog_title = Label.new()
	_prog_title.add_theme_font_override("font", UITheme.font("semibold"))
	_prog_title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	box.add_child(_prog_title)
	_prog_bar = ProgressBar.new()
	_prog_bar.max_value = 1.0
	_prog_bar.custom_minimum_size = Vector2(0, 14)
	_prog_bar.show_percentage = false
	UITheme.style_progress(_prog_bar)
	box.add_child(_prog_bar)
	_prog_detail = _muted("")
	_prog_detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_prog_detail.add_theme_font_override("font", UITheme.font("regular", true))
	box.add_child(_prog_detail)


func _on_job_finished(result: Variant) -> void:
	var kind := str(_job.get_meta("kind", ""))
	if _close_when_idle:
		queue_free()
		return
	match kind:
		"catalog":
			_build_export(result as AssetPackCatalog)
		"export":
			_export_done(result as Dictionary)
		"read":
			_build_import_preview(result as Dictionary)
		"install":
			_install_done(result)


func _on_frame_closed() -> void:
	if _job != null and _job.running():
		_job.cancel()
		_close_when_idle = true
		return
	if _reimport_pid >= 0:
		# Game art is still importing. Stay alive (hidden) and come back with the
		# Restart button when it is done: closed now, nothing would tell the
		# player that the worlds they are about to play need a restart first.
		_reopen_when_imported = true
		return
	queue_free()


# -- Helpers ---------------------------------------------------------------------------

func _dialog(mode: int) -> FileDialog:
	if _file_dialog != null and is_instance_valid(_file_dialog):
		_file_dialog.queue_free()
	var fd := FileDialog.new()
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.file_mode = mode
	fd.filters = PackedStringArray(["*.zip ; SIMbiogenesis asset pack"])
	fd.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	fd.title = "Save asset pack" if mode == FileDialog.FILE_MODE_SAVE_FILE else "Open asset pack"
	add_child(fd)
	_file_dialog = fd
	return fd


func _main() -> Node:
	var cs := get_tree().current_scene
	return cs if cs != null and cs.has_method("build_save_snapshot") else null


func _muted(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	return l


func _small_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _alert(level: int, text: String) -> AlertBanner:
	var a := AlertBanner.new()
	a.show_alert(level, text)
	return a


func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
