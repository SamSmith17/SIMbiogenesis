extends Node

## 🎬 Export video: everything the export will do, set before it starts —
## range, speed (sim-hours per second of video), file, size, frame rate,
## render settings and the camera — with a live summary of what that makes and
## a Preview that plays the shot in the game window first.
##
## Opened by TimelineUI._on_export_clim_mp4_pressed(); emits `export_requested`
## with a ClimelapseExportOptions dictionary. The choices are remembered in
## user://climelapse_export.cfg (not the range or the file name).

signal export_requested(opts: Dictionary)

var _loader: Node = null
var _main: Node = null
var _frame: ModalFrame = null
var _opts: Dictionary = {}
## [start, end] absolute hours (64-bit; a Vector2 rounds them to 2 h).
var _selection := PackedFloat64Array([NAN, NAN])
var _window_size := Vector2i(1920, 1080)
var _updating := false
var _waiting_on_preview := false

var _start_edit: LineEdit = null
var _end_edit: LineEdit = null
var _range_note: Label = null
var _speed_opt: OptionButton = null
var _speed_spin: SpinBox = null
var _folder_edit: LineEdit = null
var _file_edit: LineEdit = null
var _res_opt: OptionButton = null
var _w_spin: SpinBox = null
var _h_spin: SpinBox = null
var _fps_opt: OptionButton = null
var _quality_opt: OptionButton = null
var _shadow_opt: OptionButton = null
var _msaa_opt: OptionButton = null
var _taa_opt: OptionButton = null
var _settle_spin: SpinBox = null
var _crf_spin: SpinBox = null
var _timecode_chk: CheckBox = null
var _smooth_chk: CheckBox = null
var _analemma_opt: OptionButton = null
var _analemma_days: SpinBox = null
var _clouds_opt: OptionButton = null
var _trails_opt: OptionButton = null
var _follow_opt: OptionButton = null
var _sky_note: Label = null
var _cam_note: Label = null
var _summary: Label = null
var _export_btn: Button = null
var _dir_dialog: FileDialog = null


## `selection` is the Ctrl-drag range (NAN = none: the next 24 h from `playhead`).
func open_on(loader: Node, main: Node, selection: PackedFloat64Array, playhead: float, current_rate: float) -> void:
	_loader = loader
	_main = main
	_selection = selection
	_opts = ClimelapseExportOptions.load_prefs()
	# First export ever: start from the bar's speed when it makes a sane video
	# (a real-time day would be 24 h of footage); otherwise Max.
	if not _has_saved_rate() and current_rate >= 0.08 and not is_inf(current_rate):
		_opts["hours_per_second"] = current_rate
	if is_nan(selection[0]):
		_opts["start_abs"] = playhead
		_opts["end_abs"] = playhead + 24.0
	else:
		_opts["start_abs"] = selection[0]
		_opts["end_abs"] = selection[1]
	_opts["file_name"] = ClimelapseExportOptions.default_file_name(float(_opts["start_abs"]))
	var vp := get_viewport()
	if vp != null:
		_window_size = Vector2i(vp.get_visible_rect().size)
	_build()
	_load_into_controls()
	_frame.open()
	_refresh()


func _has_saved_rate() -> bool:
	var cfg := ConfigFile.new()
	return cfg.load(ClimelapseExportOptions.CFG_PATH) == OK and cfg.has_section_key("export", "hours_per_second")


func _build() -> void:
	_frame = ModalFrame.create("Export video",
		"Renders the range one frame at a time with the clock held, then encodes an MP4 with ffmpeg.",
		Vector2(780, 760), "climelapse_export")
	add_child(_frame)
	_frame.closed.connect(_on_frame_closed)
	var b := _frame.body

	b.add_child(SectionHeader.make("Range", "clock"))
	var rr := _row(b)
	_start_edit = _line(rr, "YYYY-MM-DD HH:MM")
	_lbl(rr, "to")
	_end_edit = _line(rr, "YYYY-MM-DD HH:MM")
	var use_sel := _button(rr, "Use selection", _on_use_selection)
	use_sel.disabled = is_nan(_selection[0])
	use_sel.tooltip_text = "The range you Ctrl-dragged on the timeline"
	_start_edit.text_submitted.connect(func(_t: String) -> void: _on_changed())
	_end_edit.text_submitted.connect(func(_t: String) -> void: _on_changed())
	_start_edit.focus_exited.connect(_on_changed)
	_end_edit.focus_exited.connect(_on_changed)
	_range_note = _note(b, "")

	b.add_child(SectionHeader.make("Speed", "gauge", "sim-hours per second of video"))
	var sr := _row(b)
	_speed_opt = OptionButton.new()
	_speed_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in ClimelapseExportOptions.TIME_PRESETS:
		_speed_opt.add_item(str(p[0]))
	_speed_opt.add_item("Custom")
	_speed_opt.item_selected.connect(_on_speed_preset)
	sr.add_child(_speed_opt)
	_speed_spin = _spin(sr, 0.0001, 10000.0, 0.0001, " h/s")
	_speed_spin.custom_minimum_size = Vector2(150, 0)
	_speed_spin.value_changed.connect(func(_v: float) -> void: _on_changed())
	_button(sr, "Max", func() -> void:
		_speed_spin.value = float(ClimelapseExportOptions.TIME_PRESETS[ClimelapseExportOptions.MAX_PRESET][1]))

	b.add_child(SectionHeader.make("File", "folder-open"))
	var fr := _row(b)
	_folder_edit = _line(fr, "Folder")
	_folder_edit.text_changed.connect(func(_t: String) -> void: _on_changed())
	_button(fr, "Browse…", _on_browse)
	var nr := _row(b)
	_lbl(nr, "File name")
	_file_edit = _line(nr, "climelapse.mp4")
	_file_edit.text_changed.connect(func(_t: String) -> void: _on_changed())

	b.add_child(SectionHeader.make("Video", "layout-grid"))
	var vr := _row(b)
	_res_opt = OptionButton.new()
	_res_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in ClimelapseExportOptions.RES_PRESETS:
		_res_opt.add_item(str(p[0]))
	_res_opt.add_item("Game window (%d × %d)" % [_window_size.x, _window_size.y])
	_res_opt.add_item("Custom")
	_res_opt.item_selected.connect(_on_res_preset)
	vr.add_child(_res_opt)
	_w_spin = _spin(vr, ClimelapseExportOptions.MIN_SIDE, ClimelapseExportOptions.MAX_SIDE, 2, " px")
	_lbl(vr, "×")
	_h_spin = _spin(vr, ClimelapseExportOptions.MIN_SIDE, ClimelapseExportOptions.MAX_SIDE, 2, " px")
	_w_spin.value_changed.connect(func(_v: float) -> void: _on_changed())
	_h_spin.value_changed.connect(func(_v: float) -> void: _on_changed())
	var fr2 := _row(b)
	_lbl(fr2, "Frame rate")
	_fps_opt = OptionButton.new()
	for f in ClimelapseExportOptions.FPS_CHOICES:
		_fps_opt.add_item("%d fps" % int(f))
	_fps_opt.item_selected.connect(func(_i: int) -> void: _on_changed())
	fr2.add_child(_fps_opt)
	_lbl(fr2, "Quality (CRF)")
	_crf_spin = _spin(fr2, 0, 51, 1, "")
	_crf_spin.tooltip_text = "x264 quality: lower is sharper and bigger. 18 looks lossless; 23 is the usual default."
	_crf_spin.value_changed.connect(func(_v: float) -> void: _on_changed())
	_timecode_chk = CheckBox.new()
	_timecode_chk.text = "Date and time strip"
	_timecode_chk.toggled.connect(func(_on: bool) -> void: _on_changed())
	fr2.add_child(_timecode_chk)

	b.add_child(SectionHeader.make("Rendering", "sun", "only for the export; your settings come back after"))
	var q := _row(b)
	_lbl(q, "Graphics")
	_quality_opt = _preset_opt(q, _main.call("get_graphics_quality_name") if _main != null and _main.has_method("get_graphics_quality_name") else "")
	_lbl(q, "Shadows")
	_shadow_opt = _preset_opt(q, _main.call("get_shadow_quality_name") if _main != null and _main.has_method("get_shadow_quality_name") else "")
	var aa := _row(b)
	_lbl(aa, "MSAA")
	_msaa_opt = OptionButton.new()
	for m in ClimelapseExportOptions.MSAA_CHOICES:
		_msaa_opt.add_item("As in game" if int(m) < 0 else ("Off" if int(m) == 0 else "%d×" % int(m)))
	_msaa_opt.item_selected.connect(func(_i: int) -> void: _on_changed())
	aa.add_child(_msaa_opt)
	_lbl(aa, "TAA")
	_taa_opt = OptionButton.new()
	for t in ["As in game", "Off", "On"]:
		_taa_opt.add_item(t)
	_taa_opt.item_selected.connect(func(_i: int) -> void: _on_changed())
	aa.add_child(_taa_opt)
	_lbl(aa, "Settle frames")
	_settle_spin = _spin(aa, 1, 8, 1, "")
	_settle_spin.tooltip_text = "Frames rendered per video frame before it is kept. More lets TAA and the volumetric fog catch up with the jump in time (cleaner, slower)."
	_settle_spin.value_changed.connect(func(_v: float) -> void: _on_changed())

	b.add_child(SectionHeader.make("Sky", "moon", "the preview shows these too"))
	var an := _row(b)
	_lbl(an, "Analemma")
	_analemma_opt = _choice(an, ["Off", "Sun: one frame a day at the same time", "Moon: one frame a day at its transit"])
	_analemma_opt.tooltip_text = "One frame per day instead of a steady clock: the sun (or the moon) is caught at the same moment each day, and the figure-eight it traces is drawn on the sky as the video plays."
	_lbl(an, "every")
	_analemma_days = _spin(an, 1, 7, 1, " d")
	_analemma_days.tooltip_text = "Days between frames"
	_analemma_days.value_changed.connect(func(_v: float) -> void: _on_changed())
	var cl := _row(b)
	_lbl(cl, "Clouds")
	_clouds_opt = _choice(cl, ["As the weather had them", "None (a clear sky)"])
	_clouds_opt.tooltip_text = "A clear sky hides the cloud layers and their shadows for the video only. The weather data and the energy figures do not change."
	_lbl(cl, "Star trails")
	_trails_opt = _choice(cl, ["As in the game", "Off", "Grow through the night"])
	_trails_opt.tooltip_text = "Grow through the night: a long exposure that opens at dusk and lengthens at the sky's own rate (15 degrees an hour) until dawn."
	_sky_note = _note(b, "")

	b.add_child(SectionHeader.make("Camera", "camera"))
	_cam_note = _note(b, "")
	var fo := _row(b)
	_lbl(fo, "Aim")
	var labels: Array = []
	for c in ClimelapseExportOptions.FOLLOW_CHOICES:
		labels.append(str(c[1]))
	_follow_opt = _choice(fo, labels)
	_follow_opt.tooltip_text = "Follow the sun or moon: the camera keeps it centred with the horizon level. Follow the stars: the camera turns with the sky like a tracking mount, so the stars hold still and the ground wheels round."
	var cr := _row(b)
	_smooth_chk = CheckBox.new()
	_smooth_chk.text = "Smooth path between keyframes"
	_smooth_chk.toggled.connect(func(on: bool) -> void:
		if _updating or _loader == null:
			return
		_loader.call("set_climelapse_keys_smooth", on))
	cr.add_child(_smooth_chk)
	var edit_btn := _button(cr, "Edit camera path…", _on_edit_path)
	edit_btn.tooltip_text = "See the keyframes as a path in the world, with each one's view, and fine-tune pan, tilt and position"

	b.add_child(SectionHeader.make("Result", "check"))
	_summary = _note(b, "")
	_summary.add_theme_color_override("font_color", UITheme.C_TEXT)

	_frame.add_button("Preview", ModalFrame.SECONDARY, _on_preview,
		"Play the shot in the game window at the export's speed (nothing is saved)")
	_frame.add_button("Cancel", ModalFrame.SECONDARY, _frame.close)
	_export_btn = _frame.add_button("Export", ModalFrame.PRIMARY, _on_export)


# --- controls -------------------------------------------------------------------

func _row(parent: Control) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	parent.add_child(r)
	return r


func _lbl(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	parent.add_child(l)
	return l


func _note(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	parent.add_child(l)
	return l


func _line(parent: Control, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(e)
	return e


func _spin(parent: Control, lo: float, hi: float, step: float, suffix: String) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.suffix = suffix
	s.allow_greater = false
	parent.add_child(s)
	return s


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var bt := Button.new()
	bt.text = text
	bt.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(bt)
	bt.pressed.connect(cb)
	parent.add_child(bt)
	return bt


func _choice(parent: Control, items: Array) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	o.item_selected.connect(func(_i: int) -> void: _on_changed())
	parent.add_child(o)
	return o


func _preset_opt(parent: Control, current_name: String) -> OptionButton:
	var o := OptionButton.new()
	o.add_item("As in game" + (" (%s)" % current_name if not current_name.is_empty() else ""))
	for n in ["Low", "Medium", "High", "Ultra"]:
		o.add_item(n)
	o.item_selected.connect(func(_i: int) -> void: _on_changed())
	parent.add_child(o)
	return o


# --- values ----------------------------------------------------------------------

func _load_into_controls() -> void:
	_updating = true
	_start_edit.text = _fmt_abs(float(_opts["start_abs"]))
	_end_edit.text = _fmt_abs(float(_opts["end_abs"]))
	var rate := float(_opts["hours_per_second"])
	_speed_spin.value = rate
	var pi := ClimelapseExportOptions.preset_for_rate(rate)
	_speed_opt.select(pi if pi >= 0 else ClimelapseExportOptions.TIME_PRESETS.size())
	_folder_edit.text = str(_opts["folder"])
	_file_edit.text = str(_opts["file_name"])
	_w_spin.value = int(_opts["width"])
	_h_spin.value = int(_opts["height"])
	_res_opt.select(_res_index(int(_opts["width"]), int(_opts["height"])))
	_fps_opt.select(maxi(0, ClimelapseExportOptions.FPS_CHOICES.find(int(_opts["fps"]))))
	_crf_spin.value = int(_opts["crf"])
	_timecode_chk.button_pressed = bool(_opts["timecode"])
	_quality_opt.select(int(_opts["quality"]) + 1)
	_shadow_opt.select(int(_opts["shadows"]) + 1)
	_msaa_opt.select(maxi(0, ClimelapseExportOptions.MSAA_CHOICES.find(int(_opts["msaa"]))))
	_taa_opt.select(int(_opts["taa"]) + 1)
	_settle_spin.value = int(_opts["settle_frames"])
	_analemma_opt.select(int(_opts["analemma"]))
	_analemma_days.value = int(_opts["analemma_days"])
	_clouds_opt.select(0 if bool(_opts["clouds"]) else 1)
	_trails_opt.select(int(_opts["star_trails"]) + 1)
	var fi := 0
	for i in ClimelapseExportOptions.FOLLOW_CHOICES.size():
		if str(ClimelapseExportOptions.FOLLOW_CHOICES[i][0]) == str(_opts["follow"]):
			fi = i
	_follow_opt.select(fi)
	var keys: ClimelapseKeyframes = _loader.call("climelapse_keys") if _loader != null else null
	_smooth_chk.button_pressed = keys == null or keys.smooth
	_updating = false


func _res_index(w: int, h: int) -> int:
	for i in ClimelapseExportOptions.RES_PRESETS.size():
		var p: Array = ClimelapseExportOptions.RES_PRESETS[i]
		if int(p[1]) == w and int(p[2]) == h:
			return i
	if w == ClimelapseExportOptions.even_size(_window_size.x) and h == ClimelapseExportOptions.even_size(_window_size.y):
		return ClimelapseExportOptions.RES_PRESETS.size()
	return ClimelapseExportOptions.RES_PRESETS.size() + 1


func _on_speed_preset(i: int) -> void:
	if i < ClimelapseExportOptions.TIME_PRESETS.size():
		_speed_spin.value = float(ClimelapseExportOptions.TIME_PRESETS[i][1])
	_on_changed()


func _on_res_preset(i: int) -> void:
	_updating = true
	if i < ClimelapseExportOptions.RES_PRESETS.size():
		var p: Array = ClimelapseExportOptions.RES_PRESETS[i]
		_w_spin.value = int(p[1])
		_h_spin.value = int(p[2])
	elif i == ClimelapseExportOptions.RES_PRESETS.size():
		_w_spin.value = ClimelapseExportOptions.even_size(_window_size.x)
		_h_spin.value = ClimelapseExportOptions.even_size(_window_size.y)
	_updating = false
	_on_changed()


func _on_use_selection() -> void:
	if is_nan(_selection[0]):
		return
	_start_edit.text = _fmt_abs(_selection[0])
	_end_edit.text = _fmt_abs(_selection[1])
	_on_changed()


func _on_changed() -> void:
	if _updating:
		return
	_read_controls()
	_refresh()


func _read_controls() -> void:
	var s := _parse_abs(_start_edit.text)
	var e := _parse_abs(_end_edit.text)
	if not is_nan(s):
		_opts["start_abs"] = s
	if not is_nan(e):
		_opts["end_abs"] = e
	_opts["hours_per_second"] = _speed_spin.value
	var pi := ClimelapseExportOptions.preset_for_rate(_speed_spin.value)
	_updating = true
	_speed_opt.select(pi if pi >= 0 else ClimelapseExportOptions.TIME_PRESETS.size())
	_res_opt.select(_res_index(int(_w_spin.value), int(_h_spin.value)))
	_updating = false
	_opts["folder"] = _folder_edit.text.strip_edges()
	_opts["file_name"] = _file_edit.text
	_opts["width"] = int(_w_spin.value)
	_opts["height"] = int(_h_spin.value)
	_opts["fps"] = int(ClimelapseExportOptions.FPS_CHOICES[maxi(_fps_opt.selected, 0)])
	_opts["crf"] = int(_crf_spin.value)
	_opts["timecode"] = _timecode_chk.button_pressed
	_opts["quality"] = _quality_opt.selected - 1
	_opts["shadows"] = _shadow_opt.selected - 1
	_opts["msaa"] = int(ClimelapseExportOptions.MSAA_CHOICES[maxi(_msaa_opt.selected, 0)])
	_opts["taa"] = _taa_opt.selected - 1
	_opts["settle_frames"] = int(_settle_spin.value)
	_opts["analemma"] = maxi(_analemma_opt.selected, 0)
	_opts["analemma_days"] = int(_analemma_days.value)
	_opts["clouds"] = _clouds_opt.selected != 1
	_opts["star_trails"] = _trails_opt.selected - 1
	_opts["follow"] = str(ClimelapseExportOptions.FOLLOW_CHOICES[maxi(_follow_opt.selected, 0)][0])


func _refresh() -> void:
	var o := ClimelapseExportOptions.normalize(_opts)
	var span := float(o["end_abs"]) - float(o["start_abs"])
	_range_note.text = ("%s of sim time." % ClimelapseExportOptions.span_label(span)) if span > 0.0 \
		else "The end must be after the start."
	if is_nan(_selection[0]):
		_range_note.text += " (No Ctrl-drag selection — this is the next 24 h from the playhead.)"
	var keys: ClimelapseKeyframes = _loader.call("climelapse_keys") if _loader != null else null
	var n := keys.size() if keys != null else 0
	if n == 0:
		_cam_note.text = "No camera keyframes: the camera stays where you are looking now. Add keyframes with 📍 on the timeline (they sit on the CLIM lane; drag to retime, right-click to edit)."
	elif n == 1:
		_cam_note.text = "1 camera keyframe: the shot is locked on that view."
	else:
		var inside := 0
		for t in keys.times():
			if t >= float(o["start_abs"]) and t <= float(o["end_abs"]):
				inside += 1
		_cam_note.text = "%s: the camera flies between them, %d inside this range." % [
			UiText.count(n, "camera keyframe"), inside]
	_smooth_chk.disabled = n < 3
	var ana := int(o["analemma"]) > 0
	_speed_opt.disabled = ana
	_speed_spin.editable = not ana
	_analemma_days.editable = ana
	var sky_bits: Array = []
	if ana:
		sky_bits.append("Analemma: one frame every %s, %s. The speed above does not apply." % [
			UiText.count(int(o["analemma_days"]), "day"),
			"the sun at the same time each day (Settings, Stars & Planets sets the time)" if int(o["analemma"]) == 1
				else "the moon at its daily transit"])
	if not bool(o["clouds"]):
		sky_bits.append("A clear sky for the video.")
	if int(o["star_trails"]) == 1:
		sky_bits.append("Star trails open at dusk and lengthen through each night.")
	_sky_note.text = " ".join(sky_bits)
	_sky_note.visible = not sky_bits.is_empty()
	var frames := ClimelapseExportOptions.frame_count(o)
	var ok := frames > 0 and frames <= ClimelapseExportOptions.MAX_FRAMES \
		and not str(o["folder"]).is_empty()
	var text := ClimelapseExportOptions.summary(o)
	var step_txt := UiText.count(int(o["analemma_days"]), "day") if ana \
		else _step_label(ClimelapseExportOptions.hours_per_frame(o))
	text += "\nOne frame every %s of sim time. Saves to %s" % [step_txt, ClimelapseExportOptions.output_path(o)]
	if frames > ClimelapseExportOptions.MAX_FRAMES:
		text += "\nToo many frames — pick a faster speed or a shorter range."
	elif str(o["folder"]).is_empty():
		text += "\nPick a folder."
	elif frames > 1800:
		text += "\nThat is a long render: the world stays frozen until it is done (Cancel keeps nothing)."
	if FileAccess.file_exists(ClimelapseExportOptions.output_path(o)):
		text += "\nA file with that name exists and will be replaced."
	_summary.text = text
	if _export_btn != null:
		_export_btn.disabled = not ok


static func _step_label(h: float) -> String:
	if h < 1.0 / 60.0:
		return "%.1f s" % (h * 3600.0)
	if h < 1.0:
		return "%.1f min" % (h * 60.0)
	return "%.2f h" % h


func _fmt_abs(abs_h: float) -> String:
	var dt: Dictionary = CelestialClock.new().abs_hours_to_date(abs_h)
	var mins := int(round(float(dt.get("day_time", 0.0)) * 60.0))
	return "%04d-%02d-%02d %02d:%02d" % [int(dt["year"]), int(dt["month"]), int(dt["day"]),
		mins / 60 % 24, mins % 60]


## "2024-04-18 13:30" (time optional) → absolute hours, NAN if unreadable.
static func _parse_abs(text: String) -> float:
	var t := text.strip_edges().replace("T", " ")
	var parts := t.split(" ", false)
	if parts.is_empty():
		return NAN
	var d := parts[0].split("-")
	if d.size() != 3 or not d[0].is_valid_int() or not d[1].is_valid_int() or not d[2].is_valid_int():
		return NAN
	var hours := 0.0
	if parts.size() > 1:
		var hm := parts[1].split(":")
		if hm.is_empty() or not hm[0].is_valid_int():
			return NAN
		hours = float(int(hm[0]))
		if hm.size() > 1 and hm[1].is_valid_int():
			hours += float(int(hm[1])) / 60.0
	var c := CelestialClock.new()
	c.year = int(d[0])
	c.month = clampi(int(d[1]), 1, 12)
	c.day = clampi(int(d[2]), 1, c.get_days_in_month(c.month, c.year))
	c.day_time = clampf(hours, 0.0, 23.999)
	return c.get_absolute_hours()


func _on_browse() -> void:
	if _dir_dialog == null:
		_dir_dialog = FileDialog.new()
		_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dir_dialog.title = "Folder for the video"
		_dir_dialog.dir_selected.connect(func(dir: String) -> void:
			_folder_edit.text = dir.replace("\\", "/")
			_on_changed())
		add_child(_dir_dialog)
	if DirAccess.dir_exists_absolute(_folder_edit.text):
		_dir_dialog.current_dir = _folder_edit.text
	_dir_dialog.popup_centered_ratio(0.6)


func _on_export() -> void:
	_read_controls()
	var o := ClimelapseExportOptions.normalize(_opts)
	ClimelapseExportOptions.save_prefs(o)
	_frame.close()
	export_requested.emit(o)


func _on_preview() -> void:
	_read_controls()
	if _loader == null or not _loader.has_method("start_climelapse_preview"):
		return
	var o := ClimelapseExportOptions.normalize(_opts)
	_waiting_on_preview = true
	_frame.visible = false
	_frame.close_on_backdrop = false
	if not bool(_loader.call("start_climelapse_preview", o)):
		_waiting_on_preview = false
		_frame.visible = true
		_frame.close_on_backdrop = true


## The camera-path editor: the dialog hides while it is open and comes back
## when it closes (its Preview plays these options).
func _on_edit_path() -> void:
	_read_controls()
	if _loader == null or not _loader.has_method("open_climelapse_path_editor"):
		return
	_waiting_on_preview = true
	_frame.visible = false
	_frame.close_on_backdrop = false
	if not bool(_loader.call("open_climelapse_path_editor", -1, ClimelapseExportOptions.normalize(_opts))):
		_waiting_on_preview = false
		_frame.visible = true
		_frame.close_on_backdrop = true


func _process(_delta: float) -> void:
	if not _waiting_on_preview or _loader == null:
		return
	if not bool(_loader.call("is_climelapse_previewing")) \
			and not bool(_loader.call("is_climelapse_path_editing")):
		_waiting_on_preview = false
		_frame.visible = true
		_frame.close_on_backdrop = true
		_refresh()


func _on_frame_closed() -> void:
	if _waiting_on_preview:
		return
	queue_free()


## Harness hook: the options as the dialog would export them now.
func current_options() -> Dictionary:
	_read_controls()
	return ClimelapseExportOptions.normalize(_opts)
