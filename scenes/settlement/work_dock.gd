extends CanvasLayer

## The chore board, inside the settlement view.
##
## Before this, editing the work and watching the work were mutually exclusive:
## the board lived in a full-screen modal over the 2D graph, so the loop
## "retune a priority → see the crew re-form around it" required closing the
## only surface that shows the crew. This dock closes that loop. It is
## deliberately NOT the whole Routines panel — authoring a chore from scratch,
## editing a daily routine and picking animation bindings all stay in the
## modal, reachable from the button at the bottom. What lives here is what you
## want while WATCHING: what is queued, who is on it, and the three knobs that
## change the answer.
##
## ⚠ It inherits the view's rules verbatim, and the important one is: **no
## order verb, ever.** Every control here changes a CONDITION — how important
## a job is, whether it is on hold, where it happens. None of them tells a
## named person to do a named thing. If a future control would read as "you,
## go there", it belongs somewhere else, or nowhere.
##
## No class_name — the ui_compile selftest sweeps scenes/settlement/.

const REFRESH_S := 0.5
const WIDTH := 330

## Priority is an uncapped int where LOWER sorts first. Same three bands the
## Routines panel authors with, deliberately — two vocabularies for one field
## would be worse than none.
const PRIORITIES: Array = [["High", 0], ["Normal", 50], ["Low", 100]]

var _view: SettlementView = null
var _bridge: Variant = null
var _accum := 0.0
var _collapsed := false

var _panel: PanelContainer = null
var _rows: VBoxContainer = null
var _title: Label = null
var _summary: Label = null
var _today_lbl: Label = null
var _toggle: Button = null


func _ready() -> void:
	layer = UITheme.LAYER_PANEL
	_build()
	set_process(false)


func bind(view: SettlementView, bridge: Variant) -> void:
	_view = view
	_bridge = bridge


func show_dock() -> void:
	visible = true
	set_process(true)
	_refresh()


func hide_dock() -> void:
	visible = false
	set_process(false)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH_S:
		return
	_accum = 0.0
	_refresh()


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.9))
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -(WIDTH + 16)
	_panel.offset_right = -16
	_panel.offset_top = 330
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_panel.add_child(col)

	var head := HBoxContainer.new()
	col.add_child(head)
	_title = Label.new()
	_title.text = "🔨 Work"
	_title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_toggle = Button.new()
	UITheme.style_button(_toggle)
	_toggle.text = "▾"
	_toggle.tooltip_text = "Collapse"
	_toggle.pressed.connect(func() -> void:
		_collapsed = not _collapsed
		_toggle.text = "▸" if _collapsed else "▾"
		_rows.visible = not _collapsed
		_summary.visible = not _collapsed
		if _today_lbl != null:
			_today_lbl.visible = not _collapsed)
	head.add_child(_toggle)

	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_summary.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.custom_minimum_size.x = WIDTH - 24
	col.add_child(_summary)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 3)
	col.add_child(_rows)

	# Who is rostered today — reporting, not commanding. Folded into _sig so
	# the signature-gated rebuild refreshes it when the rota changes.
	_today_lbl = Label.new()
	_today_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_today_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_today_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_today_lbl.custom_minimum_size.x = WIDTH - 24
	col.add_child(_today_lbl)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 4)
	col.add_child(btns)
	var plan := Button.new()
	UITheme.style_button(plan)
	plan.text = "Plan work…"
	plan.tooltip_text = "Work Planner: recurring chores, tasks, the duty rota, per-person hours and skills"
	plan.pressed.connect(func() -> void: _open_modal("open_work_planner"))
	btns.add_child(plan)
	var deep := Button.new()
	UITheme.style_button(deep)
	deep.text = "Routines…"
	deep.tooltip_text = "Full editor: add chores, edit the daily routine, site rules"
	deep.pressed.connect(_open_full_editor)
	btns.add_child(deep)


## The dock is a live view, so it rebuilds — but only when the CONTENT changed.
## A blind rebuild every 0.5 s dismisses tooltips mid-hover and makes the
## priority buttons impossible to click twice, which is most of why the modal
## panels feel unresponsive.
## Sentinel, not "": an EMPTY board produces an empty signature, so a plain ""
## initial value makes the first refresh compare equal to itself and return
## before it ever builds the empty-state row.
var _sig := "<unbuilt>"


func _refresh() -> void:
	if _bridge == null or _rows == null:
		return
	var board: Variant = _first_board()
	if board == null:
		_summary.text = "No crew on site."
		_sig = "none"
		for c in _rows.get_children():
			c.queue_free()
		return
	var abs_h: float = _bridge.call("current_abs_hours")
	var day := int(floor(abs_h / 24.0))
	var ordered: Array = (board.get("chores") as Array).duplicate()
	ordered.sort_custom(func(a, b) -> bool:
		var da := int((a as Dictionary).get("done_day", -1)) == day
		var db := int((b as Dictionary).get("done_day", -1)) == day
		if da != db:
			return db
		return int((a as Dictionary).get("priority", 0)) \
			< int((b as Dictionary).get("priority", 0)))

	var working := 0
	var waiting := 0
	var done := 0
	var sig := ""
	for c in ordered:
		var ch: Dictionary = c
		var w := (ch.get("workers", []) as Array).size()
		var mn := int(ch.get("min_workers", 1))
		if int(ch.get("done_day", -1)) == day:
			done += 1
		elif w >= mn and w > 0:
			working += w
		elif w > 0:
			waiting += w
		sig += "%s|%d|%d|%d;" % [str(ch.get("id", "")), w,
			int(ch.get("priority", 0)), int(ch.get("done_day", -1))]
	_summary.text = "%d working · %d gathering · %d done today" % [
		working, waiting, done]
	# Who is rostered today, straight off the duty rota. Part of the signature,
	# or the gate would freeze this line at whatever it said on first build.
	var today_text := ""
	var duty: Variant = _bridge.call("duty_roster_for", _first_iid())
	if duty != null:
		today_text = str(duty.call("today_text", day,
			func(aid: String) -> String: return _name_of(aid)))
	sig += "|today:%s" % today_text
	if sig == _sig:
		return   # nothing moved; leave the rows (and any hover) alone
	_sig = sig
	_today_lbl.text = ("Today: %s" % today_text) if not today_text.is_empty() else ""
	_today_lbl.visible = not today_text.is_empty() and not _collapsed

	for c in _rows.get_children():
		c.queue_free()
	if ordered.is_empty():
		var none := Label.new()
		none.text = "Nothing queued."
		none.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		none.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_rows.add_child(none)
		return
	for c in ordered:
		_rows.add_child(_chore_row(board, c as Dictionary, day))


func _chore_row(board: Variant, chore: Dictionary, day: int) -> Control:
	var cid := str(chore.get("id", ""))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_XS)

	var w := (chore.get("workers", []) as Array).size()
	var mn := int(chore.get("min_workers", 1))
	var done_today := int(chore.get("done_day", -1)) == day
	var held := bool(chore.get("held", false))

	var dot := Label.new()
	dot.text = "●" if (w >= mn and w > 0) else ("◐" if w > 0 else "○")
	if done_today:
		dot.text = "✓"
	dot.add_theme_color_override("font_color",
		UITheme.C_OK if done_today or (w >= mn and w > 0)
		else (UITheme.C_WARN if w > 0 else UITheme.C_TEXT_M))
	row.add_child(dot)

	var lbl := Label.new()
	lbl.text = str(chore.get("label", "?"))
	lbl.clip_text = true
	lbl.custom_minimum_size.x = 132
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	var left := maxf(float(chore.get("chore_hours", 0.0))
		- float(chore.get("progress_h", 0.0)), 0.0)
	# blocked_reason in the tooltip: the dock is where the player WATCHES, so
	# "why is this not moving" must be answerable without leaving it.
	var reason := ""
	if board != null and board.has_method("blocked_reason"):
		var abs_h: float = _bridge.call("current_abs_hours")
		reason = str(board.call("blocked_reason", chore, abs_h,
			fposmod(abs_h, 24.0), _bridge.call("current_weather"),
			int(_bridge.call("roster_size_for", _first_iid())),
			func(aid: String) -> String: return _name_of(aid)))
	lbl.tooltip_text = "%.1f h left · %d of %d people%s" % [left, w, mn,
		("\n⚠ " + reason) if not reason.is_empty() else ""]
	row.add_child(lbl)

	var crew := Label.new()
	crew.text = "done" if done_today else ("hold" if held else "%d/%d" % [w, mn])
	crew.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	crew.add_theme_color_override("font_color",
		UITheme.C_OK if done_today else UITheme.C_TEXT_S)
	crew.custom_minimum_size.x = 34
	row.add_child(crew)

	# --- the three condition knobs ---------------------------------------
	var pri := Button.new()
	UITheme.style_button(pri)
	var pv := int(chore.get("priority", 0))
	pri.text = "▲" if pv < 50 else ("▼" if pv > 50 else "–")
	pri.tooltip_text = "Priority: %s (click to cycle). Lower sorts first." % _band_name(pv)
	pri.pressed.connect(func() -> void:
		board.call("update_chore", cid, {"priority": _next_band(pv)})
		_sig = "<unbuilt>"
		_refresh())
	row.add_child(pri)

	var hold := Button.new()
	UITheme.style_button(hold)
	hold.text = "▶" if held else "❙❙"
	hold.tooltip_text = "Resume" if held else "Put on hold — progress is kept"
	hold.pressed.connect(func() -> void:
		board.call("update_chore", cid, {"held": not held})
		_sig = "<unbuilt>"
		_refresh())
	row.add_child(hold)

	var go := Button.new()
	UITheme.style_button(go)
	go.text = "⌖"
	go.tooltip_text = "Look at this job"
	go.pressed.connect(func() -> void: _frame(chore))
	row.add_child(go)
	return row


static func _band_name(v: int) -> String:
	return "High" if v < 50 else ("Low" if v > 50 else "Normal")


## Cycle Normal -> High -> Low -> Normal.
static func _next_band(v: int) -> int:
	if v == 50:
		return 0
	return 100 if v == 0 else 50


## Point the camera at a job. Framing is not commanding — nobody is told to go
## anywhere, the viewer just looks.
func _frame(chore: Dictionary) -> void:
	if _view == null:
		return
	var tgt: Dictionary = chore.get("target", {})
	if str(tgt.get("kind", "")) != "pos":
		return
	var cam := _view.camera()
	if cam != null:
		cam.look_at_xz(Vector2(float(tgt.get("x", 0.0)), float(tgt.get("z", 0.0))))


func _open_full_editor() -> void:
	_open_modal("open_npc_routines")


## Close the settlement view and open one of the graph view's work modals —
## they live on the UI layer the view sits under, so the view must yield first.
func _open_modal(method: String) -> void:
	var main := get_tree().current_scene
	if main == null:
		return
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null or not sgv.has_method(method):
		return
	var iid := _first_iid()
	if iid.is_empty():
		return
	if _view != null:
		_view.close()
	sgv.call(method, iid)


func _name_of(agent_id: String) -> String:
	if _bridge == null:
		return agent_id
	var agent: Variant = _bridge.call("find_agent", agent_id)
	return str(agent.get("display_name")) if agent != null else agent_id


func _first_iid() -> String:
	if _bridge == null or not _bridge.has_method("pop_driven_item_ids"):
		return ""
	var ids: Array = _bridge.call("pop_driven_item_ids")
	return str(ids[0]) if not ids.is_empty() else ""


func _first_board() -> Variant:
	var iid := _first_iid()
	if iid.is_empty():
		return null
	return _bridge.call("chore_board_for", iid)
