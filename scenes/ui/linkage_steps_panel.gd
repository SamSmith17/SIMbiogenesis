extends PanelContainer
## The Linkage Lab's BUILD STEPS dock (LINKAGE_PARITY.md A5): the web app's
## build-step player and list, under the Lab's 3D view.
##
## Left: the sequence (a group of identical steps is one row, "× N"). Middle:
## the transport (first / previous / play / next / last), the op scrubber,
## speed and the repeat mode (skip: a group plays once; fast: repeats run at
## fastFactor), and what the step does. Right: the selected step's title,
## notes and timing, list editing, Auto-generate, "Save to design" (writes the
## sequence into the design's config — the web app's `buildSteps`, so it goes
## out with an export and comes in with an import), and "NPC animation…"
## (the clip a crew plays for this kind of step, in the animation editor).
##
## Playback is LinkageStepPlayer, a sibling of the Lab's builder; the camera
## follows the step's focus while "Follow" is on. Leaving the dock (or the
## Lab) seats every part and puts the design's fold back.

const DOCK_H := 214.0
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0]

var _lab: Control = null
var _player: LinkageStepPlayer = null
var _bs: Dictionary = {}
var _dirty := false
var _open := false
var _follow := true
var _suppress := false
var _rows: Array = []        # list row -> step index

var _list: ItemList = null
var _play_btn: Button = null
var _scrub: HSlider = null
var _speed_opt: OptionButton = null
var _repeat_opt: OptionButton = null
var _follow_chk: CheckBox = null
var _step_lbl: Label = null
var _sum_lbl: Label = null
var _title_edit: LineEdit = null
var _notes_edit: TextEdit = null
var _dur_spin: SpinBox = null
var _save_btn: Button = null
var _status_lbl: Label = null


func bind(lab: Control) -> void:
	_lab = lab


func _ready() -> void:
	visible = false
	custom_minimum_size.y = DOCK_H
	add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	_build()
	set_process(false)


func is_open() -> bool:
	return _open


## Show the dock and enter playback on the design's sequence (generated if it
## has none).
func open() -> void:
	if _lab == null:
		return
	_open = true
	visible = true
	_ensure_player()
	_load_sequence()
	_player.enter(0)
	_refresh_list()
	_select_row_for(_player.index)
	set_process(true)


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	set_process(false)
	if _player != null:
		_player.exit()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


## The design changed in the Lab: re-resolve against it, keep the place.
func on_params_changed() -> void:
	if not _open or _player == null:
		return
	_player.setup(_builder(), _params())
	_player.show_frame()


func player() -> LinkageStepPlayer:
	return _player


func sequence() -> Dictionary:
	return _bs


func _params() -> LinkageParams:
	return _lab.get("params") as LinkageParams


func _builder() -> LinkageStructureBuilder:
	return _lab.get("_builder") as LinkageStructureBuilder


func _ensure_player() -> void:
	var holder := _lab.get("_holder") as Node3D
	if _player == null or not is_instance_valid(_player):
		_player = LinkageStepPlayer.new()
		_player.name = "StepPlayer"
		holder.add_child(_player)
		_player.step_changed.connect(_on_player_step)
		_player.frame_shown.connect(_on_frame)
	_player.setup(_builder(), _params())


func _load_sequence() -> void:
	_bs = _params().get_build_steps()
	if (_bs.get("steps", []) as Array).is_empty():
		_bs = LinkageBuildSteps.create_default()
		_bs["steps"] = LinkageBuildSteps.generate_for(_params())
		_dirty = true
	else:
		_dirty = false
	_player.set_steps(_bs["steps"], _bs.get("settings", {}))
	_suppress = true
	_repeat_opt.select(maxi(0, LinkageBuildSteps.REPEAT_MODES.find(str(_player.settings.get("repeatMode", "skip")))))
	_suppress = false
	_update_status()


# ---------------------------------------------------------------------------
# Per frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _player == null:
		return
	if _player.playing:
		_suppress = true
		_scrub.value = _player.t
		_suppress = false
	_play_btn.text = "❚❚" if _player.playing else "▶"
	if _follow:
		_follow_camera(delta)


## Ease the Lab's orbit camera onto the step's focus.
func _follow_camera(delta: float) -> void:
	var fr := _player.last_frame()
	if fr.is_empty():
		return
	var f := _player.focus_local(fr)
	var holder := _lab.get("_holder") as Node3D
	var want_target: Vector3 = holder.transform * (f["center"] as Vector3)
	var want_dist := clampf(float(f["radius"]) * 3.0, 1.2, 160.0)
	var k := 1.0 - exp(-delta * 3.5)
	var cur_t: Vector3 = _lab.get("_target")
	var cur_d := float(_lab.get("_dist"))
	_lab.set("_target", cur_t.lerp(want_target, k))
	_lab.set("_dist", lerpf(cur_d, want_dist, k))
	_lab.call("_update_camera")


func _on_player_step(i: int) -> void:
	_select_row_for(i)
	_show_step_fields(i)


func _on_frame(fr: Dictionary) -> void:
	# The player's list is the one being shown (a caller may hand it a fresh
	# sequence without going through this dock).
	var steps: Array = _player.steps if _player != null else _bs.get("steps", [])
	var i := int(fr.get("index", 0))
	if steps.is_empty() or i < 0 or i >= steps.size():
		_step_lbl.text = "No steps"
		return
	var g := LinkageBuildSteps.group_of(steps, i)
	var rep := " (%d of %d alike)" % [int(g["position"]) + 1, int(g["count"])] if int(g["count"]) > 1 else ""
	_step_lbl.text = "Step %d / %d%s — %s" % [i + 1, steps.size(), rep, str(steps[i].get("title", ""))]
	_sum_lbl.text = str(fr.get("summary", "")) + ("   ·   workbench" if bool(fr.get("bench", false)) else "")
	# The Lab's FOLD readout follows the step's pose (without re-applying it).
	var fs := _lab.get("_fold_slider") as HSlider
	var fsp := _lab.get("_fold_spin") as SpinBox
	if fs != null and fsp != null:
		var deg := rad_to_deg(_builder().get_fold_angle())
		_lab.set("_suppress", true)
		fs.value = deg
		fsp.value = deg
		_lab.set("_suppress", false)


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	add_child(row)

	# The sequence.
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 300
	row.add_child(left)
	left.add_child(SectionHeader.make("Build steps"))
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_list.item_selected.connect(func(r: int) -> void:
		if r >= 0 and r < _rows.size() and _player != null:
			_player.pause()
			_player.go_to(int(_rows[r])))
	left.add_child(_list)

	# Transport + what is happening.
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 6)
	row.add_child(mid)
	_step_lbl = _label("", UITheme.FONT_MD, UITheme.C_TEXT)
	_step_lbl.clip_text = true
	mid.add_child(_step_lbl)
	_sum_lbl = _label("", UITheme.FONT_XS, UITheme.C_TEXT_S)
	_sum_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mid.add_child(_sum_lbl)
	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", 4)
	mid.add_child(tr)
	_btn(tr, "|◀", "First step", func() -> void:
		_player.pause()
		_player.go_to(0))
	_btn(tr, "◀", "Previous step", func() -> void:
		_player.pause()
		_player.prev())
	_play_btn = _btn(tr, "▶", "Play / pause", func() -> void:
		if _player.playing:
			_player.pause()
		else:
			_player.play())
	_btn(tr, "▶", "Next step", func() -> void:
		_player.pause()
		_player.next()).text = "▶|"
	_btn(tr, "▶▶|", "Last step", func() -> void:
		_player.pause()
		_player.go_to((_bs.get("steps", []) as Array).size() - 1)
		_player.scrub(1.0))
	_scrub = HSlider.new()
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.001
	_scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scrub.tooltip_text = "Scrub this step's operation"
	_scrub.value_changed.connect(func(v: float) -> void:
		if not _suppress and _player != null:
			_player.pause()
			_player.scrub(v))
	tr.add_child(_scrub)
	var opts := HBoxContainer.new()
	opts.add_theme_constant_override("separation", 8)
	mid.add_child(opts)
	opts.add_child(_label("Speed", UITheme.FONT_XS, UITheme.C_TEXT_S))
	_speed_opt = OptionButton.new()
	for s in SPEEDS:
		_speed_opt.add_item("%s×" % str(s))
	_speed_opt.select(SPEEDS.find(1.0))
	_speed_opt.item_selected.connect(func(i: int) -> void:
		if _player != null:
			_player.speed = float(SPEEDS[i]))
	UITheme.style_button(_speed_opt)
	opts.add_child(_speed_opt)
	opts.add_child(_label("Repeats", UITheme.FONT_XS, UITheme.C_TEXT_S))
	_repeat_opt = OptionButton.new()
	_repeat_opt.add_item("Show once")
	_repeat_opt.add_item("Fast")
	_repeat_opt.tooltip_text = "Show a run of identical steps once, or play every one fast"
	_repeat_opt.item_selected.connect(func(i: int) -> void:
		if _suppress or _player == null:
			return
		var s: Dictionary = _bs.get("settings", LinkageBuildSteps.default_settings())
		s["repeatMode"] = LinkageBuildSteps.REPEAT_MODES[i]
		_bs["settings"] = s
		_player.settings = LinkageBuildSteps.normalize_settings(s)
		_mark_dirty())
	UITheme.style_button(_repeat_opt)
	opts.add_child(_repeat_opt)
	_follow_chk = CheckBox.new()
	_follow_chk.text = "Follow"
	_follow_chk.button_pressed = true
	_follow_chk.tooltip_text = "The camera follows each step's parts"
	_follow_chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_follow_chk.toggled.connect(func(on: bool) -> void: _follow = on)
	opts.add_child(_follow_chk)
	_status_lbl = _label("", UITheme.FONT_XS, UITheme.C_TEXT_M)
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	opts.add_child(_status_lbl)

	# The selected step + sequence editing.
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 330
	right.add_theme_constant_override("separation", 4)
	row.add_child(right)
	var tl := HBoxContainer.new()
	right.add_child(tl)
	tl.add_child(_label("Title", UITheme.FONT_XS, UITheme.C_TEXT_S))
	_title_edit = LineEdit.new()
	_title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_edit.text_submitted.connect(func(_t: String) -> void: _commit_fields())
	_title_edit.focus_exited.connect(_commit_fields)
	tl.add_child(_title_edit)
	_notes_edit = TextEdit.new()
	_notes_edit.custom_minimum_size.y = 52
	_notes_edit.placeholder_text = "Notes for the build guide"
	_notes_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_notes_edit.focus_exited.connect(_commit_fields)
	right.add_child(_notes_edit)
	var dl := HBoxContainer.new()
	right.add_child(dl)
	dl.add_child(_label("Duration", UITheme.FONT_XS, UITheme.C_TEXT_S))
	_dur_spin = SpinBox.new()
	_dur_spin.min_value = 0.1
	_dur_spin.max_value = 60.0
	_dur_spin.step = 0.1
	_dur_spin.suffix = "s"
	_dur_spin.value_changed.connect(func(_v: float) -> void: _commit_fields())
	dl.add_child(_dur_spin)
	_btn(dl, "↑", "Move up", func() -> void: _move(-1))
	_btn(dl, "↓", "Move down", func() -> void: _move(1))
	_btn(dl, "⧉", "Duplicate", _duplicate)
	IconButton.style(_btn(dl, "", "", _delete), "trash-2", "Delete this step")
	var act := HBoxContainer.new()
	act.add_theme_constant_override("separation", 4)
	right.add_child(act)
	_btn(act, "Auto-generate", "Write a full shop sequence for this design (replaces the list)", _auto_generate)
	_save_btn = _btn(act, "Save to design", "Store the sequence in the design (exports with it)", _save_to_design)
	_btn(act, "NPC animation…", "Edit the clip a crew plays for this kind of step", _edit_animation)


func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _btn(parent: Control, text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	UITheme.style_button(b)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _refresh_list() -> void:
	_list.clear()
	_rows.clear()
	var steps: Array = _bs.get("steps", [])
	for r in LinkageBuildSteps.representative_steps(steps):
		var st: Dictionary = r["step"]
		var meta: Dictionary = LinkageBuildSteps.STEP_KIND_META.get(str(st.get("kind", "view")), {})
		var count := int(r["count"])
		_list.add_item("%d. %s %s%s" % [int(r["index"]) + 1, str(meta.get("icon", "")), str(st.get("title", "")),
			("  × %d" % count) if count > 1 else ""])
		_list.set_item_tooltip(_list.item_count - 1, LinkageBuildSteps.step_summary(st))
		_rows.append(int(r["index"]))
	_update_status()


func _select_row_for(i: int) -> void:
	var steps: Array = _bs.get("steps", [])
	if steps.is_empty():
		return
	var first := int(LinkageBuildSteps.group_of(steps, i)["first"])
	var r := _rows.find(first)
	if r >= 0 and _list.item_count > r:
		_list.select(r)
		_list.ensure_current_is_visible()


func _show_step_fields(i: int) -> void:
	var steps: Array = _bs.get("steps", [])
	if i < 0 or i >= steps.size():
		return
	var st: Dictionary = steps[i]
	_suppress = true
	_title_edit.text = str(st.get("title", ""))
	_notes_edit.text = str(st.get("notes", ""))
	_dur_spin.value = float(st.get("durationMs", 1500)) / 1000.0
	_suppress = false


func _commit_fields() -> void:
	if _suppress or _player == null:
		return
	var steps: Array = _bs.get("steps", [])
	if steps.is_empty():
		return
	var st: Dictionary = steps[_player.index]
	var changed := false
	if str(st.get("title", "")) != _title_edit.text:
		st["title"] = _title_edit.text
		changed = true
	if str(st.get("notes", "")) != _notes_edit.text:
		st["notes"] = _notes_edit.text
		changed = true
	var ms := int(roundf(_dur_spin.value * 1000.0))
	if int(st.get("durationMs", 0)) != ms:
		st["durationMs"] = ms
		changed = true
	if changed:
		_mark_dirty()
		_refresh_list()
		_select_row_for(_player.index)


func _move(d: int) -> void:
	var i := _player.index
	if LinkageBuildSteps.move_step(_bs, i, i + d):
		_after_edit(clampi(i + d, 0, (_bs["steps"] as Array).size() - 1))


func _duplicate() -> void:
	var steps: Array = _bs.get("steps", [])
	if steps.is_empty():
		return
	if LinkageBuildSteps.duplicate_step(_bs, str(steps[_player.index]["id"])) != null:
		_after_edit(_player.index + 1)


func _delete() -> void:
	var steps: Array = _bs.get("steps", [])
	if steps.is_empty():
		return
	LinkageBuildSteps.remove_step(_bs, str(steps[_player.index]["id"]))
	_after_edit(mini(_player.index, maxi(0, (_bs["steps"] as Array).size() - 1)))


func _auto_generate() -> void:
	_bs["steps"] = LinkageBuildSteps.generate_for(_params())
	_after_edit(0)


func _after_edit(select: int) -> void:
	_mark_dirty()
	_player.set_steps(_bs["steps"], _bs.get("settings", {}))
	_refresh_list()
	_player.go_to(select)


func _mark_dirty() -> void:
	_dirty = true
	_update_status()


func _update_status() -> void:
	var steps: Array = _bs.get("steps", [])
	var secs := float(LinkageBuildSteps.total_duration_ms(_bs)) / 1000.0 if not steps.is_empty() else 0.0
	_status_lbl.text = "%s · %d shown · %.0f s%s" % [UiText.count(steps.size(), "step"),
		LinkageBuildSteps.representative_steps(steps).size(), secs, "  · unsaved" if _dirty else ""]
	if _save_btn != null:
		_save_btn.disabled = not _dirty


func _save_to_design() -> void:
	_params().set_build_steps(_bs)
	_dirty = false
	_update_status()


func _edit_animation() -> void:
	var steps: Array = _bs.get("steps", [])
	var kind := str(steps[_player.index].get("kind", "")) if not steps.is_empty() else ""
	var clip := str(FabContextRig.CLIP_FOR.get(kind, "place_beam"))
	var main := get_tree().current_scene
	if main != null and main.has_method("open_npc_anim_editor"):
		main.call("open_npc_anim_editor", clip)


## Unsaved edits to the sequence (the Lab warns on close).
func is_dirty() -> bool:
	return _dirty
