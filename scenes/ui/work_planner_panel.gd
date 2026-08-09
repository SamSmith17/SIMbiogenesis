extends Control

## The Work Planner: four surfaces over the settlement's labour system.
##
##   Chores   — recurring work: period, skill, crew, and the blocked_reason
##              line that says why something is not moving.
##   Tasks    — one-time work: progress, dependency chains, who is on it,
##              and "Retire finished" (prune_completed).
##   Schedule — the duty rota as a 7-day grid of NAMES: two-click swap,
##              regenerate, the fairness line, duty + on-call authoring.
##   Person   — one agent's week: hours, work by kind, skills with training
##              progress, and their on-call roles.
##
## Split out of npc_routines_panel on purpose (that file was ~1200 lines and
## keeps the roster strip / routine editor / animations). Everything here reads
## the SAME board/roster/skills objects the sim runs on — the board stays the
## single source of truth, so this panel can never disagree with the crew.
##
## Naming who is rostered is reporting, not commanding: the duty roster is a
## generator the player configures, and the no-order-verb rule survives — no
## control here tells a named person to go to a named place right now.
##
## No class_name — the ui_compile selftest sweeps scenes/ui/.

const MODAL_NAME := "work_planner"

const C_TEXT := UITheme.C_TEXT
const C_DIM := UITheme.C_TEXT_S

const PRIORITIES: Array = NpcChoreBoard.PRIORITY_BANDS
const DOW_SHORT: Array = NpcChoreBoard.DOW_SHORT
## Period choices for the duty authoring row (a rota slot must FALL on days,
## so on-demand is meaningless there).
const PERIODS: Array = [["Daily", "daily"], ["Every N days", "every_n"],
	["Weekly", "weekly"]]
## The chore editor also speaks on-demand — without it, editing an on-demand
## chore silently converted it to daily on Apply.
const EDIT_PERIODS: Array = [["Daily", "daily"], ["Every N days", "every_n"],
	["Weekly", "weekly"], ["On demand", "on_demand"]]

var _bridge = null
var _item_id := ""
var _active := false
var _accum := 0.0

var _dim: ColorRect = null
var _panel: PanelContainer = null
var _tabs: TabContainer = null
var _title: Label = null

# Chores tab
var _chore_rows: VBoxContainer = null
var _chore_sig := "<unbuilt>"
var _sel_chore := ""
var _ed_box: VBoxContainer = null
var _ed_label: LineEdit = null
var _ed_hours: SpinBox = null
var _ed_start: SpinBox = null
var _ed_end: SpinBox = null
var _ed_period: OptionButton = null
var _ed_n: SpinBox = null
var _ed_dow: Array = []          # 7 toggle Buttons
var _ed_skill: OptionButton = null
var _ed_min: SpinBox = null
var _ed_max: SpinBox = null
var _ed_priority: OptionButton = null
var _ed_exposure: OptionButton = null
var _ed_who: OptionButton = null
var _ed_where: Button = null
var _ed_target: Dictionary = {}  # staged by Where…, written on Apply
var _ed_hold: Button = null      # ❙❙/▶ mirror of the dock's pause control

# Tasks tab
var _task_rows: VBoxContainer = null
var _task_sig := "<unbuilt>"

# Schedule tab
var _sched_box: VBoxContainer = null
var _sched_sig := "<unbuilt>"
var _fair_lbl: RichTextLabel = null
var _swap_lbl: Label = null      # swap-refusal status, near the fairness line
var _swap_sel: Dictionary = {}   # {day, duty_id, agent}
var _nd_label: LineEdit = null
var _nd_hours: SpinBox = null
var _nd_start: SpinBox = null
var _nd_end: SpinBox = null
var _nd_crew: SpinBox = null
var _nd_period: OptionButton = null
var _nd_n: SpinBox = null
var _nd_dow: Array = []
var _nd_skill: OptionButton = null
var _nd_where: Button = null
## Ground point the next duty is pinned to, Vector2.INF for "wherever".
var _nd_target := Vector2.INF
## Duty the form is EDITING ("" = authoring a new one). The same form serves
## both jobs — a second row of identical fields would just be drift waiting.
var _sel_duty := ""
var _nd_title: Label = null
var _nd_add: Button = null
var _nd_cancel: Button = null
var _oncall_box: VBoxContainer = null
var _oncall_sig := "<unbuilt>"
var _new_role_name: LineEdit = null

# Person tab
var _person_pick: OptionButton = null
var _person_swatch: ColorRect = null
var _person_box: VBoxContainer = null
var _person_sig := "<unbuilt>"
var _person_roster_sig := "<unbuilt>"
var _person_id := ""


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_build_ui()


func open(bridge, item_id: String = "") -> void:
	_bridge = bridge
	if item_id.is_empty() and _bridge != null:
		var ids: Array = _bridge.call("pop_driven_item_ids")
		item_id = str(ids[0]) if not ids.is_empty() else ""
	_item_id = item_id
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	move_to_front()
	_chore_sig = "<unbuilt>"
	_task_sig = "<unbuilt>"
	_sched_sig = "<unbuilt>"
	_oncall_sig = "<unbuilt>"
	_person_sig = "<unbuilt>"
	_refresh_person_picker()
	_refresh()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


## Jump straight to one agent's Person tab (the fairness line's click-through).
func open_person(bridge, item_id: String, agent_id: String) -> void:
	open(bridge, item_id)
	_person_id = agent_id
	_person_sig = "<unbuilt>"
	_refresh_person_picker()
	if _tabs != null:
		_tabs.current_tab = 3
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# An armed shift trade eats the first Esc — closing the whole panel
		# out from under a half-made swap read as data loss.
		if not _swap_sel.is_empty():
			_swap_sel = {}
			if _swap_lbl != null:
				_swap_lbl.visible = false
			_sched_sig = "<unbuilt>"
			_refresh()
			get_viewport().set_input_as_handled()
			return
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= 0.5:
		_accum = 0.0
		_refresh()


# --- shared helpers ---------------------------------------------------------

func _board() -> NpcChoreBoard:
	if _bridge == null or _item_id.is_empty():
		return null
	return _bridge.call("chore_board_for", _item_id)


func _duty() -> NpcDutyRoster:
	return _bridge.call("duty_roster_for", _item_id) if _bridge != null else null


func _skills() -> NpcSkills:
	return _bridge.call("skills_for", _item_id) if _bridge != null else null


func _labour() -> NpcLabourLog:
	return _bridge.call("labour_for", _item_id) if _bridge != null else null


func _oncall() -> NpcOnCall:
	return _bridge.call("oncall_for", _item_id) if _bridge != null else null


func _roster_ids() -> Array:
	var out: Array = []
	if _bridge == null:
		return out
	for a in _bridge.call("roster_for", _item_id):
		out.append((a as NpcAgent).id)
	return out


## Chore ids owned by site projects, for NpcChoreBoard.system_badge — project
## tasks carry no chore_key; the project record tracks them by id.
func _project_chore_ids() -> Dictionary:
	var out: Dictionary = {}
	if _bridge == null or not _bridge.has_method("all_site_projects"):
		return out
	for r in _bridge.call("all_site_projects"):
		var prj: Dictionary = (r as Dictionary).get("project", {})
		for t in (prj.get("tasks", []) as Array):
			out[str((t as Dictionary).get("chore_id", ""))] = true
	return out


func _name_for(agent_id: String) -> String:
	if agent_id.is_empty():
		return "anyone"
	if _bridge == null:
		return NpcAgent.name_for(agent_id)
	var agent: NpcAgent = _bridge.call("find_agent", agent_id)
	# A departed person still gets their deterministic name — orphaned_from
	# and old ledger lines would otherwise print a raw internal id.
	return agent.display_name if agent != null else NpcAgent.name_for(agent_id)


func _persist() -> void:
	if _bridge != null and not _item_id.is_empty():
		_bridge.call("persist_work_config", _item_id)


func _abs_h() -> float:
	return float(_bridge.call("current_abs_hours")) if _bridge != null else 0.0


## "Read about the work → watch the work": close the planner and open the
## settlement view framed on a chore's place. Framing is looking, never
## ordering. Only pos/prop targets are resolvable here; rows without one
## simply do not offer the button.
func _frame_in_settlement(tgt: Dictionary) -> void:
	var main := get_tree().current_scene
	if main == null or not main.has_method("open_settlement_view"):
		return
	var at := Vector2.INF
	match str(tgt.get("kind", "")):
		"pos":
			at = Vector2(float(tgt.get("x", 0.0)), float(tgt.get("z", 0.0)))
		"prop":
			var rec: Dictionary = PlacedPropService.get_prop_record(main,
				str(tgt.get("id", "")))
			if not rec.is_empty():
				at = Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	if at == Vector2.INF:
		return
	close()
	var view: Variant = main.call("open_settlement_view")
	if view != null and view.has_method("camera"):
		var cam: Variant = view.call("camera")
		if cam != null:
			cam.call("look_at_xz", at)


static func _frameable(tgt: Dictionary) -> bool:
	return str(tgt.get("kind", "")) in ["pos", "prop"]


func _look_btn(tgt: Dictionary) -> Button:
	var go := Button.new()
	UITheme.style_button(go)
	go.text = "⌖"
	go.tooltip_text = "Look at this in the settlement view"
	go.pressed.connect(func() -> void: _frame_in_settlement(tgt))
	return go


func _reason_of(chore: Dictionary) -> String:
	var board := _board()
	if board == null:
		return ""
	var t := _abs_h()
	return board.blocked_reason(chore, t, fposmod(t, 24.0),
		_bridge.call("current_weather"), _roster_ids().size(),
		Callable(self, "_name_for"))


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	l.add_theme_color_override("font_color", C_TEXT)
	return l


func _small(text: String, col: Color = UITheme.C_TEXT_S) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", col)
	# Labels default to MOUSE_FILTER_IGNORE, and Godot only shows tooltips on
	# non-IGNORE controls — every tooltip_text this panel puts on a _small was
	# silently dead. PASS keeps clicks flowing to the parent.
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	return l


func _spin(step: float, min_v: float, max_v: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.step = step
	s.min_value = min_v
	s.max_value = max_v
	s.value = value
	s.custom_minimum_size.x = 68
	return s


func _labelled(text: String, control: Control) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.add_child(_small(text))
	col.add_child(control)
	return col


func _skill_option() -> OptionButton:
	var opt := OptionButton.new()
	opt.add_item("Any skill")
	opt.set_item_metadata(0, "")
	for t in NpcSkills.TAGS:
		opt.add_item(NpcSkills.label(str(t)))
		opt.set_item_metadata(opt.item_count - 1, str(t))
	return opt


func _dow_row(store: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	store.clear()
	for i in 7:
		var btn := Button.new()
		UITheme.style_button(btn)
		btn.text = str(DOW_SHORT[i])
		btn.toggle_mode = true
		btn.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		row.add_child(btn)
		store.append(btn)
	return row


static func _period_of(rec: Dictionary) -> String:
	return NpcChoreBoard.normalize_repeat(rec.get("repeat", "daily"))


## How often, in words — single-sourced on the board beside reason_glyph.
static func _repeat_text(rec: Dictionary) -> String:
	return NpcChoreBoard.repeat_text(rec)


# --- construction -----------------------------------------------------------

func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -530
	_panel.offset_right = 530
	_panel.offset_top = -340
	_panel.offset_bottom = 340
	add_child(_panel)

	var margin := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(m, 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 12)
	_panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)
	_title = Label.new()
	_title.text = "Work Planner"
	_title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_title.add_theme_color_override("font_color", C_TEXT)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	var routines_btn := Button.new()
	UITheme.style_button(routines_btn)
	routines_btn.text = "Routines…"
	routines_btn.tooltip_text = "The daily schedule, roster, animations and site rules"
	routines_btn.pressed.connect(func() -> void:
		var sgv: Node = ServiceLocator.graph()
		if sgv != null and sgv.has_method("open_npc_routines"):
			var iid := _item_id
			close()
			sgv.call("open_npc_routines", iid))
	header.add_child(routines_btn)
	var close_btn := Button.new()
	UITheme.style_button(close_btn)
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(func(_i: int) -> void: _refresh())
	root.add_child(_tabs)

	_build_chores_tab()
	_build_tasks_tab()
	_build_schedule_tab()
	_build_person_tab()


func _build_chores_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "Chores"
	tab.add_theme_constant_override("separation", 4)
	_tabs.add_child(tab)
	tab.add_child(_section("Recurring work"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)
	_chore_rows = VBoxContainer.new()
	_chore_rows.add_theme_constant_override("separation", 3)
	_chore_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_chore_rows)
	tab.add_child(HSeparator.new())

	# The editor: persistent controls (never rebuilt by the refresh), bound to
	# the selected chore. Rebuilding an editor mid-keystroke is the churn bug
	# the work dock's signature gate exists to prevent.
	_ed_box = VBoxContainer.new()
	_ed_box.add_theme_constant_override("separation", 3)
	_ed_box.visible = false
	tab.add_child(_ed_box)
	_ed_box.add_child(_section("Edit"))
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	_ed_box.add_child(row1)
	_ed_label = LineEdit.new()
	_ed_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(_labelled("Label", _ed_label))
	_ed_hours = _spin(0.25, 0.05, 12.0, 1.0)
	row1.add_child(_labelled("Hours", _ed_hours))
	_ed_start = _spin(1.0, 0.0, 23.0, 8.0)
	row1.add_child(_labelled("From", _ed_start))
	_ed_end = _spin(1.0, 1.0, 24.0, 18.0)
	row1.add_child(_labelled("To", _ed_end))
	_ed_min = _spin(1.0, 1.0, 32.0, 1.0)
	row1.add_child(_labelled("Crew min", _ed_min))
	_ed_max = _spin(1.0, 1.0, 32.0, 1.0)
	row1.add_child(_labelled("max", _ed_max))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	_ed_box.add_child(row2)
	_ed_period = OptionButton.new()
	for p in EDIT_PERIODS:
		_ed_period.add_item(str((p as Array)[0]))
	_ed_period.item_selected.connect(func(_i: int) -> void: _sync_period_vis())
	row2.add_child(_labelled("Repeats", _ed_period))
	_ed_n = _spin(1.0, 2.0, 30.0, 3.0)
	row2.add_child(_labelled("N days", _ed_n))
	row2.add_child(_labelled("Weekdays", _dow_row(_ed_dow)))
	_ed_skill = _skill_option()
	row2.add_child(_labelled("Needs", _ed_skill))
	_ed_priority = OptionButton.new()
	for p in PRIORITIES:
		_ed_priority.add_item(str((p as Array)[0]))
	row2.add_child(_labelled("Priority", _ed_priority))
	# Row 3: the fields that used to be permanent after creation — exposure,
	# assignee and place — plus the pause control both modals lacked.
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 6)
	_ed_box.add_child(row3)
	_ed_exposure = OptionButton.new()
	for e in NpcWeatherGate.EXPOSURES:
		_ed_exposure.add_item(str(e).capitalize())
	_ed_exposure.tooltip_text = "Indoor work ignores weather; sheltered is damped; outdoor is fully gated"
	row3.add_child(_labelled("Exposure", _ed_exposure))
	_ed_who = OptionButton.new()
	_ed_who.tooltip_text = "Hold this chore for one person, or leave it for anyone"
	row3.add_child(_labelled("Who", _ed_who))
	_ed_where = Button.new()
	UITheme.style_button(_ed_where)
	_ed_where.text = "Where…"
	_ed_where.tooltip_text = "Pick where this work happens — without a place it is done wherever the worker stands"
	_ed_where.pressed.connect(_on_pick_chore_where)
	row3.add_child(_labelled("Place", _ed_where))
	_ed_hold = Button.new()
	UITheme.style_button(_ed_hold)
	_ed_hold.pressed.connect(_on_toggle_hold)
	row3.add_child(_labelled(" ", _ed_hold))
	var apply := Button.new()
	UITheme.style_button(apply)
	apply.text = "Apply"
	apply.pressed.connect(_on_chore_apply)
	row3.add_child(_labelled(" ", apply))


func _build_tasks_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "Tasks"
	tab.add_theme_constant_override("separation", 4)
	_tabs.add_child(tab)
	tab.add_child(_section("One-time work"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)
	_task_rows = VBoxContainer.new()
	_task_rows.add_theme_constant_override("separation", 3)
	_task_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_task_rows)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	tab.add_child(foot)
	var retire := Button.new()
	UITheme.style_button(retire)
	retire.text = "Retire finished"
	retire.tooltip_text = "Remove completed one-time tasks from the board. Anything a delivery or build still tracks stays."
	retire.pressed.connect(func() -> void:
		var board := _board()
		if board != null:
			board.prune_completed(_abs_h(), 0)
			_task_sig = "<unbuilt>"
			_refresh())
	foot.add_child(retire)


func _build_schedule_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "Schedule"
	tab.add_theme_constant_override("separation", 4)
	_tabs.add_child(tab)

	_fair_lbl = RichTextLabel.new()
	_fair_lbl.bbcode_enabled = true
	_fair_lbl.fit_content = true
	_fair_lbl.scroll_active = false
	_fair_lbl.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	_fair_lbl.meta_clicked.connect(func(meta: Variant) -> void:
		_person_id = str(meta)
		_person_sig = "<unbuilt>"
		_refresh_person_picker()
		_tabs.current_tab = 3
		_refresh())
	var fair_row := HBoxContainer.new()
	fair_row.add_theme_constant_override("separation", 8)
	tab.add_child(fair_row)
	_fair_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fair_row.add_child(_fair_lbl)
	var regen := Button.new()
	UITheme.style_button(regen)
	regen.text = "Regenerate from today"
	regen.tooltip_text = "Re-plan the un-minted week from the live roster and ledger. Days already worked are history and stay."
	regen.pressed.connect(_on_regenerate)
	fair_row.add_child(regen)

	# A refused trade used to render identically to a successful one — the
	# roster simply didn't change, which read as the click not registering.
	_swap_lbl = Label.new()
	_swap_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_swap_lbl.add_theme_color_override("font_color", UITheme.C_WARN)
	_swap_lbl.visible = false
	tab.add_child(_swap_lbl)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)
	_sched_box = VBoxContainer.new()
	_sched_box.add_theme_constant_override("separation", 6)
	_sched_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_sched_box)

	tab.add_child(HSeparator.new())
	# Duty authoring. Without this row the rota is unreachable — nothing else
	# in the game creates a duty.
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 3)
	tab.add_child(wrap)
	_nd_title = _section("New duty")
	wrap.add_child(_nd_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	wrap.add_child(row)
	_nd_label = LineEdit.new()
	_nd_label.placeholder_text = "Lunch, bathrooms, water run…"
	_nd_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_labelled("Duty", _nd_label))
	_nd_hours = _spin(0.25, 0.25, 8.0, 2.0)
	row.add_child(_labelled("Hours", _nd_hours))
	_nd_start = _spin(1.0, 0.0, 23.0, 11.0)
	row.add_child(_labelled("From", _nd_start))
	_nd_end = _spin(1.0, 1.0, 24.0, 14.0)
	row.add_child(_labelled("To", _nd_end))
	_nd_crew = _spin(1.0, 1.0, 8.0, 2.0)
	row.add_child(_labelled("Crew", _nd_crew))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	wrap.add_child(row2)
	_nd_period = OptionButton.new()
	for p in PERIODS:
		_nd_period.add_item(str((p as Array)[0]))
	_nd_period.item_selected.connect(func(_i: int) -> void: _sync_period_vis())
	row2.add_child(_labelled("Repeats", _nd_period))
	_nd_n = _spin(1.0, 2.0, 30.0, 3.0)
	row2.add_child(_labelled("N days", _nd_n))
	row2.add_child(_labelled("Weekdays", _dow_row(_nd_dow)))
	_nd_skill = _skill_option()
	row2.add_child(_labelled("Needs", _nd_skill))
	# Without a place, duty work happens wherever the worker is standing —
	# which reads as the rota doing nothing. Same one-shot pick the Routines
	# panel's chore row uses, same view the work then happens in.
	_nd_where = Button.new()
	UITheme.style_button(_nd_where)
	_nd_where.text = "Where…"
	_nd_where.tooltip_text = "Pick the spot on the ground in the settlement view"
	_nd_where.pressed.connect(_on_pick_duty_where)
	row2.add_child(_labelled("Place", _nd_where))
	_nd_add = Button.new()
	UITheme.style_button(_nd_add)
	_nd_add.text = "Add duty"
	_nd_add.pressed.connect(_on_add_duty)
	row2.add_child(_labelled(" ", _nd_add))
	_nd_cancel = Button.new()
	UITheme.style_button(_nd_cancel)
	_nd_cancel.text = "New"
	_nd_cancel.tooltip_text = "Stop editing and go back to authoring a fresh duty"
	_nd_cancel.visible = false
	_nd_cancel.pressed.connect(func() -> void: _set_sel_duty(""))
	row2.add_child(_labelled(" ", _nd_cancel))

	tab.add_child(HSeparator.new())
	var oc_head := HBoxContainer.new()
	oc_head.add_theme_constant_override("separation", 8)
	tab.add_child(oc_head)
	oc_head.add_child(_section("On call — who answers when something breaks"))
	_new_role_name = LineEdit.new()
	_new_role_name.placeholder_text = "New role name"
	_new_role_name.custom_minimum_size.x = 160
	oc_head.add_child(_new_role_name)
	var add_role := Button.new()
	UITheme.style_button(add_role)
	add_role.text = "Add role"
	add_role.pressed.connect(_on_add_role)
	oc_head.add_child(add_role)
	_oncall_box = VBoxContainer.new()
	_oncall_box.add_theme_constant_override("separation", 4)
	tab.add_child(_oncall_box)


func _build_person_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "Person"
	tab.add_theme_constant_override("separation", 4)
	_tabs.add_child(tab)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	tab.add_child(head)
	# The way back OUT: everything jumps INTO this tab (roster names, the
	# fairness line, the settlement card), and without a return door the only
	# exits were Esc or guessing at the header — a dead end at the end of
	# every jump.
	var back := Button.new()
	UITheme.style_button(back)
	back.text = "◂ Everyone"
	back.tooltip_text = "Back to the full roster (Routines & chores)"
	back.pressed.connect(func() -> void:
		var sgv: Node = ServiceLocator.graph()
		if sgv != null and sgv.has_method("open_npc_routines"):
			var iid := _item_id
			close()
			sgv.call("open_npc_routines", iid))
	head.add_child(back)
	head.add_child(_section("Person"))
	# The same pastel as this person's dot and avatar rim — the thread that
	# ties the figure being watched to the ledger being read.
	_person_swatch = ColorRect.new()
	_person_swatch.custom_minimum_size = Vector2(12, 12)
	_person_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_person_swatch)
	_person_pick = OptionButton.new()
	_person_pick.custom_minimum_size.x = 170
	_person_pick.item_selected.connect(func(idx: int) -> void:
		_person_id = str(_person_pick.get_item_metadata(idx))
		_person_sig = "<unbuilt>"
		_refresh())
	head.add_child(_person_pick)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)
	_person_box = VBoxContainer.new()
	_person_box.add_theme_constant_override("separation", 6)
	_person_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_person_box)


# --- refresh ----------------------------------------------------------------

func _refresh() -> void:
	if not _active or _bridge == null:
		return
	var count := _roster_ids().size()
	_title.text = "Work Planner — %d people" % count
	# Re-list the person picker when roster MEMBERSHIP changes (departures,
	# resets) — it used to be filled once on open and went stale, offering
	# people who had already left.
	var rsig := ";".join(_roster_ids())
	if rsig != _person_roster_sig:
		_person_roster_sig = rsig
		_refresh_person_picker()
	match _tabs.current_tab:
		0: _refresh_chores()
		1: _refresh_tasks()
		2:
			_refresh_schedule()
			_refresh_oncall()
		3: _refresh_person()
	_sync_period_vis()


func _sync_period_vis() -> void:
	if _ed_period != null and not _ed_dow.is_empty():
		var p := str((EDIT_PERIODS[maxi(_ed_period.selected, 0)] as Array)[1])
		_ed_n.get_parent().visible = p == "every_n"
		(_ed_dow[0] as Button).get_parent().get_parent().visible = p == "weekly"
	if _nd_period != null and not _nd_dow.is_empty():
		var p2 := str((PERIODS[maxi(_nd_period.selected, 0)] as Array)[1])
		_nd_n.get_parent().visible = p2 == "every_n"
		(_nd_dow[0] as Button).get_parent().get_parent().visible = p2 == "weekly"


func _refresh_chores() -> void:
	var board := _board()
	if board == null:
		return
	var day := NpcChoreBoard.day_index(_abs_h())
	var recs: Array = []
	for c in board.chores:
		if _period_of(c as Dictionary) != "once":
			recs.append(c)
	var sig := ""
	for c in recs:
		var ch: Dictionary = c
		sig += "%s|%s|%s|%d|%d|%s|%s|%s|%s|%s|%.2f|%d|%d|%s;" % [str(ch.get("id", "")),
			str(ch.get("label", "")), _repeat_text(ch),
			int(ch.get("priority", 0)), int(ch.get("done_day", -1)),
			str(ch.get("requires_skill", "")),
			str(ch.get("assigned_to", "")), str(ch.get("covered_by", "")),
			str(ch.get("orphaned_from", "")),
			str(ch.get("target", {})) + str(ch.get("window", {})) + str(ch.get("held", false)),
			float(ch.get("chore_hours", 0.0)),
			int(ch.get("min_workers", 1)), int(ch.get("max_workers", 1)),
			_reason_of(ch)]
	sig += "|sel:%s" % _sel_chore
	if sig == _chore_sig:
		return
	_chore_sig = sig
	var prj_ids := _project_chore_ids()
	# Keep the reader's place: rebuilt lists used to snap to the top.
	UITheme.keep_scroll(_chore_rows).call()
	for c in _chore_rows.get_children():
		c.queue_free()
	if recs.is_empty():
		_chore_rows.add_child(_small(
			"No recurring chores. Add one in Routines & chores, or rota work as a duty on the Schedule tab."))
		# From empty board to living settlement in one gesture. Sensible
		# defaults the player can retune — everything here is editable above.
		var seed := Button.new()
		UITheme.style_button(seed)
		seed.text = "Seed common chores"
		seed.tooltip_text = "Cook meals · clean the bathrooms · water run — with sensible hours, all editable"
		seed.pressed.connect(func() -> void:
			var b := _board()
			if b == null:
				return
			b.add_chore("Cook meals", 2.0, {"repeat": "daily",
				"window": {"start_h": 11.0, "end_h": 14.0},
				"exposure": NpcWeatherGate.EXPOSURE_SHELTERED,
				"min_workers": 1, "max_workers": 2})
			b.add_chore("Clean the bathrooms", 0.5, {"repeat": "every_n",
				"repeat_days": 2, "window": {"start_h": 9.0, "end_h": 12.0},
				"exposure": NpcWeatherGate.EXPOSURE_SHELTERED})
			b.add_chore("Water run", 1.0, {"repeat": "daily",
				"window": {"start_h": 8.0, "end_h": 11.0},
				"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR})
			_chore_sig = "<unbuilt>"
			_refresh())
		_chore_rows.add_child(seed)
		return
	# The add affordance must survive a non-empty board — it used to render
	# only in the empty state, so the way to add a SECOND chore vanished.
	var add_btn := Button.new()
	UITheme.style_button(add_btn)
	add_btn.text = "＋ Add a chore…"
	add_btn.tooltip_text = "New chores are authored in Routines & chores"
	add_btn.pressed.connect(func() -> void:
		var sgv: Node = ServiceLocator.graph()
		if sgv != null and sgv.has_method("open_npc_routines"):
			var iid := _item_id
			close()
			sgv.call("open_npc_routines", iid))
	_chore_rows.add_child(add_btn)
	for c in recs:
		var ch: Dictionary = c
		var cid := str(ch.get("id", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_chore_rows.add_child(row)
		var done_today := int(ch.get("done_day", -1)) == day
		var lbl := Label.new()
		# The editor below binds to ONE chore; mark which, or "Edit → change →
		# Apply" reads as editing whatever row the eye happens to be on.
		var selected := cid == _sel_chore
		lbl.text = ("▸ " if selected else "") + str(ch.get("label", "?"))
		lbl.custom_minimum_size.x = 170
		lbl.clip_text = true
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		lbl.add_theme_color_override("font_color",
			UITheme.C_AMBER if selected else (UITheme.C_OK if done_today else C_TEXT))
		row.add_child(lbl)
		row.add_child(_small(_repeat_text(ch)))
		var skill := str(ch.get("requires_skill", ""))
		if not skill.is_empty():
			row.add_child(_small("🎓 %s" % NpcSkills.label(skill), UITheme.C_INFO))
		row.add_child(_small("crew %d–%d" % [int(ch.get("min_workers", 1)),
			int(ch.get("max_workers", 1))]))
		var pri := int(ch.get("priority", 0))
		if pri != 50:
			row.add_child(_small("▲ high" if pri < 50 else "▼ low",
				UITheme.C_AMBER if pri < 50 else C_DIM))
		var who := str(ch.get("assigned_to", ""))
		var covered := str(ch.get("covered_by", ""))
		var orphaned := str(ch.get("orphaned_from", ""))
		if not covered.is_empty():
			var cov := _small("→ %s" % _name_for(covered), UITheme.C_OK)
			cov.tooltip_text = "Covering%s" % (
				" for %s" % _name_for(who) if not who.is_empty() else "")
			row.add_child(cov)
		elif not who.is_empty():
			row.add_child(_small("→ %s" % _name_for(who)))
		elif not orphaned.is_empty():
			var orp := _small("anyone (was %s — left)" % _name_for(orphaned), C_DIM)
			orp.tooltip_text = "%s was assigned but left the settlement" % _name_for(orphaned)
			row.add_child(orp)
		var badge: Array = NpcChoreBoard.system_badge(ch, prj_ids)
		if not badge.is_empty():
			var sysb := _small(str(badge[0]))
			sysb.tooltip_text = str(badge[1])
			row.add_child(sysb)
		var reason := _reason_of(ch)
		if not reason.is_empty():
			var r := _small("%s %s" % [NpcChoreBoard.reason_glyph(reason), reason],
				UITheme.C_WARN)
			r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.clip_text = true
			r.tooltip_text = reason
			row.add_child(r)
		else:
			var pad := Control.new()
			pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(pad)
		if _frameable(ch.get("target", {}) as Dictionary):
			row.add_child(_look_btn(ch.get("target", {}) as Dictionary))
		var edit := Button.new()
		UITheme.style_button(edit)
		edit.text = "Editing…" if selected else "Edit"
		edit.pressed.connect(func() -> void:
			_select_chore(cid)
			_chore_sig = "<unbuilt>"   # re-render so the ▸ marker moves
			_refresh())
		row.add_child(edit)
		var del := Button.new()
		UITheme.style_button(del)
		del.text = "✕"
		if badge.is_empty():
			del.tooltip_text = "Delete this chore"
			del.pressed.connect(func() -> void:
				var b := _board()
				if b != null:
					b.remove_chore(cid)
				if _sel_chore == cid:
					_sel_chore = ""
					_ed_box.visible = false
				_chore_sig = "<unbuilt>"
				_refresh())
		else:
			# A system chore re-mints (keyed) or breaks its project's phase
			# tracking if hand-deleted — refuse and say where it is managed.
			del.disabled = true
			del.tooltip_text = str(badge[1])
		row.add_child(del)


func _select_chore(cid: String) -> void:
	var board := _board()
	if board == null:
		return
	var rec := board.find(cid)
	if rec.is_empty():
		return
	_sel_chore = cid
	_ed_box.visible = true
	_ed_label.text = str(rec.get("label", ""))
	_ed_hours.value = float(rec.get("chore_hours", 1.0))
	var w: Dictionary = rec.get("window", {})
	_ed_start.value = float(w.get("start_h", 8.0))
	_ed_end.value = float(w.get("end_h", 18.0))
	_ed_min.value = float(int(rec.get("min_workers", 1)))
	_ed_max.value = float(int(rec.get("max_workers", 1)))
	var period := _period_of(rec)
	var pidx := 0
	for i in EDIT_PERIODS.size():
		if str((EDIT_PERIODS[i] as Array)[1]) == period:
			pidx = i
	_ed_period.select(pidx)
	_ed_n.value = float(maxi(int(rec.get("repeat_days", 1)), 2))
	var dow: Array = rec.get("repeat_dow", []) as Array
	for i in 7:
		(_ed_dow[i] as Button).set_pressed_no_signal(dow.has(i))
	var skill := str(rec.get("requires_skill", ""))
	var sidx := 0
	for i in _ed_skill.item_count:
		if str(_ed_skill.get_item_metadata(i)) == skill:
			sidx = i
	_ed_skill.select(sidx)
	var pri := int(rec.get("priority", 0))
	var bidx := 1
	for i in PRIORITIES.size():
		if int((PRIORITIES[i] as Array)[1]) == pri:
			bidx = i
	_ed_priority.select(bidx)
	var expo := str(rec.get("exposure", NpcWeatherGate.EXPOSURE_OUTDOOR))
	_ed_exposure.select(maxi(NpcWeatherGate.EXPOSURES.find(expo), 0))
	_ed_who.clear()
	_ed_who.add_item("anyone")
	_ed_who.set_item_metadata(0, "")
	var assigned := str(rec.get("assigned_to", ""))
	var rids := _roster_ids()
	for i in rids.size():
		_ed_who.add_item(_name_for(str(rids[i])))
		_ed_who.set_item_metadata(i + 1, str(rids[i]))
		if str(rids[i]) == assigned:
			_ed_who.select(i + 1)
	_ed_target = (rec.get("target", {}) as Dictionary).duplicate(true)
	_sync_ed_where()
	_sync_ed_hold(bool(rec.get("held", false)))
	_sync_period_vis()


func _sync_ed_where() -> void:
	if _ed_where == null:
		return
	match str(_ed_target.get("kind", "")):
		"pos":
			_ed_where.text = "@ %d, %d" % [int(_ed_target.get("x", 0)),
				int(_ed_target.get("z", 0))]
		"prop":
			_ed_where.text = "@ object"
		"space":
			_ed_where.text = "@ space"
		_:
			_ed_where.text = "Where…"


func _sync_ed_hold(held: bool) -> void:
	if _ed_hold == null:
		return
	_ed_hold.text = "▶ Resume" if held else "❙❙ Pause"
	_ed_hold.tooltip_text = "Resume this chore" if held \
		else "Put on hold — progress is kept"


## Immediate, like the dock's ❙❙/▶ — a pause is a state, not a draft edit.
func _on_toggle_hold() -> void:
	var board := _board()
	if board == null or _sel_chore.is_empty():
		return
	var held := bool(board.find(_sel_chore).get("held", false))
	board.update_chore(_sel_chore, {"held": not held})
	_sync_ed_hold(not held)
	_chore_sig = "<unbuilt>"
	_refresh()


## Ground pick for the SELECTED chore's place (same round trip as the duty
## form's Where…). Staged into _ed_target; written on Apply.
func _on_pick_chore_where() -> void:
	var main := get_tree().current_scene
	if main == null or not main.has_method("open_settlement_view"):
		return
	var bridge = _bridge
	var iid := _item_id
	var cid := _sel_chore
	var view: Variant = main.call("open_settlement_view")
	if view == null or not view.has_method("pick_point_once"):
		return
	close()
	view.call("pick_point_once", func(p: Vector2) -> void:
		open(bridge, iid)
		if _tabs != null:
			_tabs.current_tab = 0   # Chores, where the editor lives
		if not cid.is_empty():
			_select_chore(cid)
			if p != Vector2.INF:
				_ed_target = {"kind": "pos", "x": p.x, "z": p.y}
				_sync_ed_where()
		_chore_sig = "<unbuilt>"
		_refresh())


func _on_chore_apply() -> void:
	var board := _board()
	if board == null or _sel_chore.is_empty():
		return
	var period := str((EDIT_PERIODS[maxi(_ed_period.selected, 0)] as Array)[1])
	var dow: Array = []
	for i in 7:
		if (_ed_dow[i] as Button).button_pressed:
			dow.append(i)
	var min_w := int(_ed_min.value)
	board.update_chore(_sel_chore, {
		"label": _ed_label.text.strip_edges(),
		"chore_hours": maxf(float(_ed_hours.value), 0.05),
		"window": {"start_h": float(_ed_start.value), "end_h": float(_ed_end.value)},
		"repeat": period,
		"repeat_days": maxi(int(_ed_n.value), 1),
		"repeat_dow": dow,
		"requires_skill": str(_ed_skill.get_item_metadata(maxi(_ed_skill.selected, 0))),
		"min_workers": min_w,
		"max_workers": maxi(int(_ed_max.value), min_w),
		"priority": int((PRIORITIES[maxi(_ed_priority.selected, 0)] as Array)[1]),
		"exposure": str(NpcWeatherGate.EXPOSURES[maxi(_ed_exposure.selected, 0)]),
		"assigned_to": str(_ed_who.get_item_metadata(maxi(_ed_who.selected, 0)))
			if _ed_who.item_count > 0 else "",
		"target": _ed_target.duplicate(true),
	})
	_chore_sig = "<unbuilt>"
	_refresh()


func _refresh_tasks() -> void:
	var board := _board()
	if board == null:
		return
	var day := NpcChoreBoard.day_index(_abs_h())
	var recs: Array = []
	for c in board.chores:
		if _period_of(c as Dictionary) == "once":
			recs.append(c)
	recs.sort_custom(func(a, b) -> bool:
		var da := int((a as Dictionary).get("done_day", -1)) >= 0
		var db := int((b as Dictionary).get("done_day", -1)) >= 0
		if da != db:
			return db
		return int((a as Dictionary).get("priority", 0)) \
			< int((b as Dictionary).get("priority", 0)))
	var sig := ""
	for c in recs:
		var ch: Dictionary = c
		sig += "%s|%.2f|%d|%d|%s;" % [str(ch.get("id", "")),
			float(ch.get("progress_h", 0.0)), int(ch.get("done_day", -1)),
			(ch.get("workers", []) as Array).size(), _reason_of(ch)]
	if sig == _task_sig:
		return
	_task_sig = sig
	var prj_ids := _project_chore_ids()
	# Keep the reader's place: rebuilt lists used to snap to the top.
	UITheme.keep_scroll(_task_rows).call()
	for c in _task_rows.get_children():
		c.queue_free()
	if recs.is_empty():
		_task_rows.add_child(_small(
			"No one-time tasks. Deliveries, builds and machine work land here on their own."))
		return
	for c in recs:
		var ch: Dictionary = c
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_task_rows.add_child(row)
		var done := int(ch.get("done_day", -1)) >= 0
		var lbl := Label.new()
		lbl.text = str(ch.get("label", "?"))
		lbl.custom_minimum_size.x = 200
		lbl.clip_text = true
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		lbl.add_theme_color_override("font_color", UITheme.C_OK if done else C_TEXT)
		row.add_child(lbl)
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = maxf(float(ch.get("chore_hours", 1.0)), 0.01)
		bar.value = float(ch.get("progress_h", 0.0))
		bar.custom_minimum_size = Vector2(90, 14)
		bar.show_percentage = false
		UITheme.style_progress(bar, UITheme.C_OK if done else UITheme.C_AMBER)
		row.add_child(bar)
		var deps: Array = ch.get("depends_on", []) as Array
		if not deps.is_empty():
			var names := PackedStringArray()
			for d in deps:
				var dep := board.find(str(d))
				if not dep.is_empty():
					names.append(str(dep.get("label", "?")))
			if not names.is_empty():
				var chain := _small("after: %s" % " › ".join(names))
				chain.clip_text = true
				chain.custom_minimum_size.x = 130
				chain.tooltip_text = " › ".join(names)
				row.add_child(chain)
		var workers: Array = ch.get("workers", []) as Array
		if not workers.is_empty():
			var names2 := PackedStringArray()
			for a in workers:
				names2.append(_name_for(str(a)))
			row.add_child(_small("👤 %s" % ", ".join(names2), UITheme.C_OK))
		var reason := _reason_of(ch)
		if not reason.is_empty() and not done:
			var r := _small("%s %s" % [NpcChoreBoard.reason_glyph(reason), reason],
				UITheme.C_WARN)
			r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.clip_text = true
			r.tooltip_text = reason
			row.add_child(r)
		else:
			var pad := Control.new()
			pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(pad)
		if not done and _frameable(ch.get("target", {}) as Dictionary):
			row.add_child(_look_btn(ch.get("target", {}) as Dictionary))
		if done and int(ch.get("done_day", -1)) == day:
			row.add_child(_small("done today", UITheme.C_OK))
		var badge: Array = NpcChoreBoard.system_badge(ch, prj_ids)
		if not badge.is_empty():
			var sysb := _small(str(badge[0]))
			sysb.tooltip_text = str(badge[1])
			row.add_child(sysb)
		elif workers.is_empty():
			# One-time player tasks had no way OUT — deletable only while
			# nothing system tracks it and nobody is mid-work on it.
			var del := Button.new()
			UITheme.style_button(del)
			del.text = "✕"
			del.tooltip_text = "Delete this task"
			var cid := str(ch.get("id", ""))
			del.pressed.connect(func() -> void:
				var b := _board()
				if b != null:
					b.remove_chore(cid)
				_task_sig = "<unbuilt>"
				_refresh())
			row.add_child(del)


func _refresh_schedule() -> void:
	var duty := _duty()
	var board := _board()
	if duty == null or board == null:
		return
	var day := NpcChoreBoard.day_index(_abs_h())
	var lab := _labour()
	var ids := _roster_ids()

	# The fairness line, always current (it is cheap and text-only). With no
	# hours banked yet, min and max are the same arbitrary name twice — say
	# what is actually true instead.
	if lab != null and not ids.is_empty():
		var f := NpcLabourLog.fairness(lab, ids, day - 6, day)
		if float(f.get("max_h", 0.0)) <= 0.01:
			_fair_lbl.text = "No hours banked yet this week — the ledger fills as people work."
		else:
			_fair_lbl.text = \
				"This week: [url=%s]%s[/url] %.1f h · [url=%s]%s[/url] %.1f h · mean %.1f h — %s" % [
				str(f.get("max_id", "")), _name_for(str(f.get("max_id", ""))),
				float(f.get("max_h", 0.0)),
				str(f.get("min_id", "")), _name_for(str(f.get("min_id", ""))),
				float(f.get("min_h", 0.0)), float(f.get("mean_h", 0.0)),
				str(f.get("label", ""))]
	else:
		# Without this, the line kept naming departed people forever after the
		# roster emptied.
		_fair_lbl.text = "Nobody is on the roster."

	var sig := "day:%d|sw:%s|ed:%s;" % [day, str(_swap_sel), _sel_duty]
	for d in duty.duties:
		sig += "%s|%s;" % [str((d as Dictionary).get("duty_id", "")),
			str((d as Dictionary).get("label", ""))]
	for s in duty.slots:
		var sd: Dictionary = s
		sig += "%d|%s|%s|%s;" % [int(sd.get("day", 0)), str(sd.get("duty_id", "")),
			str(sd.get("agents", [])), str(sd.get("state", ""))]
		var chore := board.find(str(sd.get("chore_id", "")))
		sig += str(chore.get("covered_by", "")) + ";"
	if sig == _sched_sig:
		return
	_sched_sig = sig
	# Keep the reader's place: rebuilt lists used to snap to the top.
	UITheme.keep_scroll(_sched_box).call()
	for c in _sched_box.get_children():
		c.queue_free()

	if duty.duties.is_empty():
		_sched_box.add_child(_small(
			"No duties yet. A duty is a rostered slot — lunch, bathrooms, a water run — that rotates through the crew fairly. Add one below."))
		return

	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	_sched_box.add_child(grid)
	grid.add_child(_small("Duty", C_TEXT))
	# Real calendar dates on the headers — "Sat 9" reads as a plan for THIS
	# week, where a bare weekday reads as a template. Pure decompose off the
	# scene clock; a scene without one (bare selftest tree) keeps weekdays.
	var clock: Variant = null
	var scene := get_tree().current_scene
	if scene != null:
		clock = scene.get("clock")
	for offset in 7:
		var d2 := day + offset
		var head_text := str(DOW_SHORT[NpcChoreBoard.weekday_of_day(d2)])
		if clock != null and clock.has_method("abs_hours_to_date"):
			var date: Dictionary = clock.call("abs_hours_to_date", float(d2) * 24.0)
			head_text += " %d" % int(date.get("day", 0))
		if offset == 0:
			head_text += " · today"
		var head := _small(head_text,
			UITheme.C_AMBER if offset == 0 else C_DIM)
		grid.add_child(head)
	for dd in duty.duties:
		var drec: Dictionary = dd
		var did := str(drec.get("duty_id", ""))
		var name_cell := HBoxContainer.new()
		name_cell.add_theme_constant_override("separation", 3)
		var editing := did == _sel_duty
		var dl := _small(("▸ " if editing else "") + str(drec.get("label", "?")),
			UITheme.C_AMBER if editing else C_TEXT)
		dl.custom_minimum_size.x = 96
		dl.clip_text = true
		var dw: Dictionary = drec.get("window", {})
		dl.tooltip_text = "%s · %.1f h · crew %d · %02d–%02d · %s" % [
			str(drec.get("label", "?")), float(drec.get("chore_hours", 1.0)),
			int(drec.get("crew", 1)), int(dw.get("start_h", 0)),
			int(dw.get("end_h", 24)), _repeat_text(drec)]
		name_cell.add_child(dl)
		if _frameable(drec.get("target", {}) as Dictionary):
			name_cell.add_child(_look_btn(drec.get("target", {}) as Dictionary))
		var ed := Button.new()
		UITheme.style_button(ed)
		ed.text = "✎"
		ed.tooltip_text = "Edit this duty in the form below"
		ed.pressed.connect(func() -> void: _set_sel_duty(did))
		name_cell.add_child(ed)
		var rm := Button.new()
		UITheme.style_button(rm)
		rm.text = "✕"
		rm.tooltip_text = "Remove this duty (its future slots go with it)"
		rm.pressed.connect(func() -> void:
			var dy := _duty()
			if dy != null:
				dy.remove_duty(did)
				_persist()
			if _sel_duty == did:
				_set_sel_duty("")
			_sched_sig = "<unbuilt>"
			_refresh())
		name_cell.add_child(rm)
		grid.add_child(name_cell)
		for offset in 7:
			grid.add_child(_slot_cell(duty, board, drec, day + offset, day))


func _slot_cell(duty: NpcDutyRoster, board: NpcChoreBoard,
		drec: Dictionary, cell_day: int, _today: int) -> Control:
	var did := str(drec.get("duty_id", ""))
	var slot := duty.slot_for(cell_day, did)
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 1)
	if slot.is_empty():
		var dot := _small("·")
		dot.tooltip_text = "Not on the rota this day"
		cell.add_child(dot)
		return cell
	var chore := board.find(str(slot.get("chore_id", "")))
	var covered := str(chore.get("covered_by", ""))
	var slot_done := str(slot.get("state", "")) == "done" \
		or int(chore.get("done_day", -1)) >= 0
	for a in (slot.get("agents", []) as Array):
		var aid := str(a)
		var btn := Button.new()
		UITheme.style_button(btn)
		btn.flat = true
		btn.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		var struck := not covered.is_empty() and aid == str(chore.get("assigned_to", ""))
		btn.text = _name_for(aid) + ("  → " + _name_for(covered) if struck else "")
		if struck:
			btn.tooltip_text = "%s did not show inside the hold — %s stepped in" % [
				_name_for(aid), _name_for(covered)]
		var selected := int(_swap_sel.get("day", -1)) == cell_day \
			and str(_swap_sel.get("duty_id", "")) == did \
			and str(_swap_sel.get("agent", "")) == aid
		var base := UITheme.C_AMBER if selected \
			else (C_DIM if slot_done or struck else C_TEXT)
		btn.add_theme_color_override("font_color", base)
		if not slot_done:
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			btn.mouse_entered.connect(func() -> void:
				btn.add_theme_color_override("font_color", UITheme.C_INFO))
			btn.mouse_exited.connect(func() -> void:
				btn.add_theme_color_override("font_color", base))
		if slot_done:
			btn.tooltip_text = "Done — a finished slot cannot be traded"
		elif selected:
			btn.tooltip_text = "Armed for a trade — click another name to swap, click again or press Esc to cancel"
		else:
			btn.tooltip_text = "Click, then click another name to trade shifts"
		btn.pressed.connect(func() -> void: _on_slot_name(cell_day, did, aid))
		cell.add_child(btn)
	return cell


## Two-click swap: first click selects, second executes the trade.
func _on_slot_name(day: int, duty_id: String, agent: String) -> void:
	if _swap_lbl != null:
		_swap_lbl.visible = false
	if _swap_sel.is_empty():
		_swap_sel = {"day": day, "duty_id": duty_id, "agent": agent}
		if _swap_lbl != null:
			_swap_lbl.text = "Trading %s's shift — click another name to swap · Esc or click again to cancel." \
				% _name_for(agent)
			_swap_lbl.add_theme_color_override("font_color", UITheme.C_AMBER)
			_swap_lbl.visible = true
		_sched_sig = "<unbuilt>"
		_refresh()
		return
	if int(_swap_sel.get("day", -1)) == day \
			and str(_swap_sel.get("duty_id", "")) == duty_id \
			and str(_swap_sel.get("agent", "")) == agent:
		_swap_sel = {}   # clicked again — deselect
		_sched_sig = "<unbuilt>"
		_refresh()
		return
	var duty := _duty()
	var board := _board()
	if duty == null:
		return
	# Name a refusal instead of silently not changing anything — swap()'s
	# empty return is ambiguous, so the reason comes from swap_refusal.
	var refusal := duty.swap_refusal(int(_swap_sel["day"]), str(_swap_sel["duty_id"]),
		str(_swap_sel["agent"]), day, duty_id, agent, _skills())
	if not refusal.is_empty():
		if _swap_lbl != null:
			_swap_lbl.text = "Swap refused — %s." % refusal
			_swap_lbl.add_theme_color_override("font_color", UITheme.C_WARN)
			_swap_lbl.visible = true
		return
	if _swap_lbl != null:
		_swap_lbl.visible = false
	var changed := duty.swap(int(_swap_sel["day"]), str(_swap_sel["duty_id"]),
		str(_swap_sel["agent"]), day, duty_id, agent, _skills())
	# A minted slot's live chore keeps assigned_to in sync with the trade.
	if board != null:
		for cid in changed:
			var rec := board.find(str(cid))
			if rec.is_empty():
				continue
			var ck := str(rec.get("chore_key", "duty||0"))
			var slot := duty.slot_for(int(ck.get_slice("|", 2)), ck.get_slice("|", 1))
			var agents: Array = slot.get("agents", []) as Array
			if not agents.is_empty():
				rec["assigned_to"] = str(agents[0])
	_swap_sel = {}
	_sched_sig = "<unbuilt>"
	_refresh()


## Bind the shared form to one duty (Edit), or back to authoring ("").
func _set_sel_duty(did: String) -> void:
	var duty := _duty()
	_sel_duty = ""
	if duty != null and not did.is_empty():
		var rec := duty.find_duty(did)
		if not rec.is_empty():
			_sel_duty = did
			_nd_label.text = str(rec.get("label", ""))
			_nd_hours.value = float(rec.get("chore_hours", 1.0))
			var w: Dictionary = rec.get("window", {})
			_nd_start.value = float(w.get("start_h", 11.0))
			_nd_end.value = float(w.get("end_h", 14.0))
			_nd_crew.value = float(int(rec.get("crew", 1)))
			var period := NpcChoreBoard.normalize_repeat(rec.get("repeat", "daily"))
			for i in PERIODS.size():
				if str((PERIODS[i] as Array)[1]) == period:
					_nd_period.select(i)
			_nd_n.value = float(maxi(int(rec.get("repeat_days", 1)), 2))
			var dow: Array = rec.get("repeat_dow", []) as Array
			for i in 7:
				(_nd_dow[i] as Button).set_pressed_no_signal(dow.has(i))
			var skill := str(rec.get("requires_skill", ""))
			for i in _nd_skill.item_count:
				if str(_nd_skill.get_item_metadata(i)) == skill:
					_nd_skill.select(i)
			var tgt: Dictionary = rec.get("target", {})
			if str(tgt.get("kind", "")) == "pos":
				_nd_target = Vector2(float(tgt.get("x", 0.0)), float(tgt.get("z", 0.0)))
				_nd_where.text = "@ %d, %d" % [int(_nd_target.x), int(_nd_target.y)]
			else:
				_nd_target = Vector2.INF
				_nd_where.text = "Where…"
	if _sel_duty.is_empty():
		_nd_label.text = ""
		_nd_target = Vector2.INF
		_nd_where.text = "Where…"
	_nd_title.text = ("Edit duty — %s" % _nd_label.text) if not _sel_duty.is_empty() \
		else "New duty"
	_nd_add.text = "Apply changes" if not _sel_duty.is_empty() else "Add duty"
	_nd_add.tooltip_text = ("Applies from the next re-plan — a slot already minted today keeps its card" \
		if not _sel_duty.is_empty() else "")
	_nd_cancel.visible = not _sel_duty.is_empty()
	_sched_sig = "<unbuilt>"
	_sync_period_vis()
	_refresh()


func _on_add_duty() -> void:
	var duty := _duty()
	if duty == null:
		return
	var label := _nd_label.text.strip_edges()
	if label.is_empty():
		label = "Duty"
	var period := str((PERIODS[maxi(_nd_period.selected, 0)] as Array)[1])
	var dow: Array = []
	for i in 7:
		if (_nd_dow[i] as Button).button_pressed:
			dow.append(i)
	var tgt: Dictionary = {}
	if _nd_target != Vector2.INF:
		tgt = {"kind": "pos", "x": _nd_target.x, "z": _nd_target.y}
	if not _sel_duty.is_empty():
		# EDIT: mutate the template in place. save_duties re-plans from today,
		# so future planned slots pick the change up on the next tick; a slot
		# already minted today keeps its card (history is history).
		var rec := duty.find_duty(_sel_duty)
		if not rec.is_empty():
			rec["label"] = label
			rec["chore_hours"] = maxf(float(_nd_hours.value), 0.01)
			rec["window"] = {"start_h": float(_nd_start.value),
				"end_h": float(_nd_end.value)}
			rec["crew"] = maxi(int(_nd_crew.value), 1)
			rec["repeat"] = period
			rec["repeat_days"] = maxi(int(_nd_n.value), 1)
			rec["repeat_dow"] = dow
			rec["requires_skill"] = str(_nd_skill.get_item_metadata(
				maxi(_nd_skill.selected, 0)))
			rec["target"] = tgt
		_persist()
		_set_sel_duty("")
		return
	var opts := {
		"window": {"start_h": float(_nd_start.value), "end_h": float(_nd_end.value)},
		"crew": int(_nd_crew.value),
		"repeat": period,
		"repeat_days": maxi(int(_nd_n.value), 1),
		"repeat_dow": dow,
		"requires_skill": str(_nd_skill.get_item_metadata(maxi(_nd_skill.selected, 0))),
	}
	if not tgt.is_empty():
		opts["target"] = tgt
	duty.add_duty(label, float(_nd_hours.value), opts)
	_nd_label.text = ""
	_nd_target = Vector2.INF
	_nd_where.text = "Where…"
	_persist()   # also re-plans from today, so the grid fills on the next tick
	_sched_sig = "<unbuilt>"
	_refresh()


## Drop into the settlement view for a one-shot ground pick, then come back on
## the Schedule tab. The new-duty fields are persistent controls, so a
## half-filled row survives the round trip.
func _on_pick_duty_where() -> void:
	var main := get_tree().current_scene
	if main == null or not main.has_method("open_settlement_view"):
		_nd_where.text = "(no settlement view)"
		return
	var bridge = _bridge
	var iid := _item_id
	# Resolve the view BEFORE closing — close-then-bail stranded the player
	# with no UI at all when the view failed to come up.
	var view: Variant = main.call("open_settlement_view")
	if view == null or not view.has_method("pick_point_once"):
		_nd_where.text = "(no settlement view)"
		return
	close()
	view.call("pick_point_once", func(p: Vector2) -> void:
		if p != Vector2.INF:
			_nd_target = p
			_nd_where.text = "@ %d, %d" % [int(p.x), int(p.y)]
		open(bridge, iid)
		if _tabs != null:
			_tabs.current_tab = 2
		_refresh(), "this duty")


func _on_regenerate() -> void:
	var duty := _duty()
	if duty == null:
		return
	duty.generate(NpcChoreBoard.day_index(_abs_h()), _roster_ids(),
		_skills(), _labour())
	_sched_sig = "<unbuilt>"
	_refresh()


## The on-call section's rebuild signature. Interaction handlers that mutate a
## role in place must RE-SYNC `_oncall_sig` to this (never set "<unbuilt>"):
## invalidating from a handler frees the very control mid-interaction — the
## members popup vanished after the first check, so a second member could
## never be added.
func _oncall_signature() -> String:
	var oc := _oncall()
	if oc == null:
		return "<none>"
	var sig := ""
	for r in oc.roles:
		var role: Dictionary = r
		sig += "%s|%s|%s|%s|%s;" % [str(role.get("role_id", "")),
			str(role.get("label", "")), str(role.get("members", [])),
			str(role.get("conditions", [])), str(role.get("requires_skill", ""))]
	sig += "|roster:%d" % _roster_ids().size()
	return sig


func _refresh_oncall() -> void:
	var oc := _oncall()
	if oc == null:
		return
	var ids := _roster_ids()
	var sig := _oncall_signature()
	if sig == _oncall_sig:
		return
	_oncall_sig = sig
	for c in _oncall_box.get_children():
		c.queue_free()
	if oc.roles.is_empty():
		_oncall_box.add_child(_small(
			"No roles. An on-call role names who answers a condition — a stalled machine gets its responder, a dry supply gets a named person on the alarm."))
		return
	for r in oc.roles:
		var role: Dictionary = r
		var rid := str(role.get("role_id", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_oncall_box.add_child(row)
		# Editable in place — duties could be renamed, roles could not.
		var name_edit := LineEdit.new()
		name_edit.text = str(role.get("label", rid))
		name_edit.custom_minimum_size.x = 110
		name_edit.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		name_edit.tooltip_text = "Rename this role"
		var commit_name := func() -> void:
			var oc3 := _oncall()
			if oc3 == null:
				return
			var role3 := oc3.find_role(rid)
			var nm := name_edit.text.strip_edges()
			if nm.is_empty() or nm == str(role3.get("label", "")):
				name_edit.text = str(role3.get("label", rid))
				return
			role3["label"] = nm
			_persist()
			_oncall_sig = _oncall_signature()
		name_edit.text_submitted.connect(func(_t: String) -> void: commit_name.call())
		name_edit.focus_exited.connect(commit_name)
		row.add_child(name_edit)
		# Conditions as toggle chips.
		for cond in NpcOnCall.CONDITIONS:
			var chip := Button.new()
			UITheme.style_button(chip)
			chip.toggle_mode = true
			chip.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			chip.text = str(NpcOnCall.CONDITION_SHORT.get(str(cond), str(cond)))
			# The feature's whole honesty (see NpcOnCall's header): a FIXABLE
			# condition mints real work; an ESCALATE one only names who looks.
			# Rendering the two identically buried that distinction.
			var fixable := (NpcOnCall.FIXABLE as Array).has(str(cond))
			chip.add_theme_color_override("font_color",
				UITheme.C_OK if fixable else UITheme.C_TEXT_S)
			chip.tooltip_text = "%s — %s" % [
				str(NpcOnCall.CONDITION_LABELS.get(str(cond), str(cond))),
				"a responder can fix this" if fixable
					else "a responder can only look; the fix is yours"]
			chip.set_pressed_no_signal((role.get("conditions", []) as Array).has(str(cond)))
			chip.toggled.connect(func(on: bool) -> void:
				var oc2 := _oncall()
				if oc2 == null:
					return
				var role2 := oc2.find_role(rid)
				var conds: Array = role2.get("conditions", []) as Array
				if on and not conds.has(str(cond)):
					conds.append(str(cond))
				elif not on:
					conds.erase(str(cond))
				_persist()
				# Re-sync, never invalidate: the chip already shows the new
				# state, and a rebuild would free it mid-interaction.
				_oncall_sig = _oncall_signature())
			row.add_child(chip)
		# Members via a checkable dropdown — a 24-person roster as inline chips
		# would swallow the row.
		var members_btn := MenuButton.new()
		var members: Array = role.get("members", []) as Array
		members_btn.text = "%d member%s ▾" % [members.size(),
			"" if members.size() == 1 else "s"]
		UITheme.style_button(members_btn)
		var pop := members_btn.get_popup()
		for i in ids.size():
			var aid := str(ids[i])
			pop.add_check_item(_name_for(aid), i)
			pop.set_item_checked(pop.item_count - 1, members.has(aid))
		pop.hide_on_checkable_item_selection = false
		pop.index_pressed.connect(func(idx: int) -> void:
			var oc2 := _oncall()
			if oc2 == null:
				return
			var role2 := oc2.find_role(rid)
			var mem: Array = role2.get("members", []) as Array
			var aid := str(ids[idx]) if idx < ids.size() else ""
			if aid.is_empty():
				return
			if mem.has(aid):
				mem.erase(aid)
				pop.set_item_checked(idx, false)
			else:
				mem.append(aid)
				pop.set_item_checked(idx, true)
			members_btn.text = "%d member%s ▾" % [mem.size(),
				"" if mem.size() == 1 else "s"]
			_persist()
			# Re-sync, never invalidate: invalidating here freed the open
			# popup on the next 0.5 s tick, so a second member could never
			# be checked in one visit.
			_oncall_sig = _oncall_signature())
		row.add_child(members_btn)
		# The model always supported requires_skill; the UI just never let
		# anyone set it.
		var skill_opt := _skill_option()
		skill_opt.tooltip_text = "Only people with this skill respond"
		var cur_skill := str(role.get("requires_skill", ""))
		for i in skill_opt.item_count:
			if str(skill_opt.get_item_metadata(i)) == cur_skill:
				skill_opt.select(i)
		skill_opt.item_selected.connect(func(i: int) -> void:
			var oc4 := _oncall()
			if oc4 == null:
				return
			var role4 := oc4.find_role(rid)
			role4["requires_skill"] = str(skill_opt.get_item_metadata(i))
			_persist()
			_oncall_sig = _oncall_signature())
		row.add_child(skill_opt)
		var rm := Button.new()
		UITheme.style_button(rm)
		rm.text = "✕"
		rm.tooltip_text = "Remove this role"
		rm.pressed.connect(func() -> void:
			var oc2 := _oncall()
			if oc2 != null:
				oc2.remove_role(rid)
				_persist()
			_oncall_sig = "<unbuilt>"
			_refresh())
		row.add_child(rm)


func _on_add_role() -> void:
	var oc := _oncall()
	if oc == null:
		return
	var label := _new_role_name.text.strip_edges()
	if label.is_empty():
		label = "Role %d" % (oc.roles.size() + 1)
	# Everyone volunteers by default — an empty role answers nothing, which
	# reads as the feature not working.
	oc.add_role(label, [], {"members": _roster_ids()})
	_new_role_name.text = ""
	_persist()
	_oncall_sig = "<unbuilt>"
	_refresh()


func _refresh_person_picker() -> void:
	if _person_pick == null or _bridge == null:
		return
	_person_pick.clear()
	var ids := _roster_ids()
	if ids.is_empty():
		return
	if _person_id.is_empty() or not ids.has(_person_id):
		_person_id = str(ids[0])
	for i in ids.size():
		_person_pick.add_item(_name_for(str(ids[i])))
		_person_pick.set_item_metadata(i, str(ids[i]))
		if str(ids[i]) == _person_id:
			_person_pick.select(i)


func _refresh_person() -> void:
	var lab := _labour()
	var sk := _skills()
	var oc := _oncall()
	if lab == null or _person_id.is_empty():
		return
	var day := NpcChoreBoard.day_index(_abs_h())
	var sig := "%s|%d|%.2f|%.2f" % [_person_id, day,
		lab.day_hours(_person_id, day), lab.week_hours(_person_id, day)]
	if sk != null:
		for t in NpcSkills.TAGS:
			sig += "|%.3f" % sk.level(_person_id, str(t))
	if oc != null:
		for r in oc.roles:
			sig += "|%s" % str(((r as Dictionary).get("members", []) as Array)
				.has(_person_id))
	if sig == _person_sig:
		return
	_person_sig = sig
	if _person_swatch != null:
		var pc := NpcPopulationEngine.color_for_agent(_person_id)
		_person_swatch.visible = pc != Color.BLACK   # colors pref off => hide
		_person_swatch.color = pc
	# Keep the reader's place: rebuilt lists used to snap to the top.
	UITheme.keep_scroll(_person_box).call()
	for c in _person_box.get_children():
		c.queue_free()

	# The three numbers.
	var nums := HBoxContainer.new()
	nums.add_theme_constant_override("separation", 18)
	_person_box.add_child(nums)
	for pair in [["Today", lab.day_hours(_person_id, day)],
			["This week", lab.week_hours(_person_id, day)],
			["This month", lab.month_hours(_person_id, day)]]:
		var col := VBoxContainer.new()
		col.add_child(_small(str((pair as Array)[0])))
		var v := Label.new()
		v.text = "%.1f h" % float((pair as Array)[1])
		v.add_theme_font_size_override("font_size", UITheme.FONT_LG)
		v.add_theme_color_override("font_color", C_TEXT)
		col.add_child(v)
		nums.add_child(col)

	# Today at a glance — the same sleep/needs/chores/free bar the Routines
	# roster carries, so "what does the day look like" sits beside "what got
	# done". Same UITheme values, so the two readings agree.
	var agent: NpcAgent = _bridge.call("find_agent", _person_id)
	var board := _board()
	if agent != null:
		_person_box.add_child(_section("Today's plan"))
		var assigned := 0.0
		if board != null:
			assigned = board.assigned_hours_for(_person_id, _abs_h())
		var strip0 := HBoxContainer.new()
		strip0.add_theme_constant_override("separation", 0)
		strip0.custom_minimum_size = Vector2(360, 16)
		_person_box.add_child(strip0)
		var sleep_h := 24.0 - NpcAgent.SLEEP_START_H + NpcAgent.SLEEP_END_H
		var free_before := agent.free_hours(0.0)
		var need_h := maxf(24.0 - sleep_h - free_before, 0.0)
		var chore_h := minf(assigned, maxf(free_before, 0.0))
		var over_h := maxf(assigned - free_before, 0.0)
		var free_h := maxf(free_before - chore_h, 0.0)
		for seg in [[sleep_h, UITheme.C_LAVENDER], [need_h, UITheme.C_PRIMARY],
				[chore_h, UITheme.C_AMBER], [free_h, UITheme.C_GREEN],
				[over_h, UITheme.C_ERROR]]:
			var hrs := float((seg as Array)[0])
			if hrs <= 0.01:
				continue
			var bar0 := ColorRect.new()
			bar0.color = (seg as Array)[1] as Color
			bar0.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bar0.size_flags_stretch_ratio = hrs
			strip0.add_child(bar0)
		strip0.tooltip_text = "sleep %.1f h · needs %.1f h · chores %.1f h · free %.1f h%s" % [
			sleep_h, need_h, chore_h, free_h,
			"  ⚠ OVER-SCHEDULED by %.1f h" % over_h if over_h > 0.01 else ""]

	# The week strip: seven bars, today rightmost.
	_person_box.add_child(_section("The week"))
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 6)
	_person_box.add_child(strip)
	var peak := 0.1
	for offset in 7:
		peak = maxf(peak, lab.day_hours(_person_id, day - 6 + offset))
	for offset in 7:
		var d := day - 6 + offset
		var h := lab.day_hours(_person_id, d)
		var col2 := VBoxContainer.new()
		col2.alignment = BoxContainer.ALIGNMENT_END
		col2.custom_minimum_size = Vector2(44, 64)
		var bar := ColorRect.new()
		bar.color = UITheme.C_AMBER if offset == 6 else UITheme.C_PRIMARY
		bar.custom_minimum_size = Vector2(28, maxf(52.0 * h / peak, 2.0))
		bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		bar.tooltip_text = "%.1f h" % h
		col2.add_child(bar)
		col2.add_child(_small(DOW_SHORT[NpcChoreBoard.weekday_of_day(d)]))
		strip.add_child(col2)

	# Work by kind — the categories are pose families, so "Sam does all the
	# hauling" is answerable with no extra bookkeeping.
	var by := lab.by_category(_person_id, day - 6, day)
	if not by.is_empty():
		_person_box.add_child(_section("What kind of work"))
		var stack := HBoxContainer.new()
		stack.add_theme_constant_override("separation", 0)
		stack.custom_minimum_size = Vector2(360, 16)
		_person_box.add_child(stack)
		var legend := HBoxContainer.new()
		legend.add_theme_constant_override("separation", 10)
		_person_box.add_child(legend)
		var keys: Array = by.keys()
		keys.sort()
		for i in keys.size():
			var k := str(keys[i])
			var col3 := Color.from_hsv(fposmod(0.09 + 0.61 * float(i)
				/ maxf(float(keys.size()), 1.0), 1.0), 0.55, 0.82)
			var seg := ColorRect.new()
			seg.color = col3
			seg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			seg.size_flags_stretch_ratio = maxf(float(by[k]), 0.01)
			seg.tooltip_text = "%s — %.1f h" % [k, float(by[k])]
			stack.add_child(seg)
			var chip := HBoxContainer.new()
			chip.add_theme_constant_override("separation", 3)
			var sw := ColorRect.new()
			sw.color = col3
			sw.custom_minimum_size = Vector2(10, 10)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			chip.add_child(sw)
			chip.add_child(_small("%s %.1f h" % [k, float(by[k])]))
			legend.add_child(chip)

	# Skills, with training progress and grant/revoke.
	if sk != null:
		_person_box.add_child(_section("Skills"))
		for t in NpcSkills.TAGS:
			var tag := str(t)
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			_person_box.add_child(row)
			var nl := Label.new()
			nl.text = NpcSkills.label(tag)
			nl.custom_minimum_size.x = 120
			nl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			nl.add_theme_color_override("font_color", C_TEXT)
			row.add_child(nl)
			var lvl := sk.level(_person_id, tag)
			var bar2 := ProgressBar.new()
			bar2.min_value = 0.0
			bar2.max_value = 1.0
			bar2.value = lvl
			bar2.custom_minimum_size = Vector2(140, 14)
			bar2.show_percentage = false
			UITheme.style_progress(bar2,
				UITheme.C_OK if lvl >= NpcSkills.QUALIFIED else UITheme.C_AMBER)
			bar2.tooltip_text = ("Qualified" if lvl >= NpcSkills.QUALIFIED
				else "%.0f%% trained — working beside somebody qualified teaches fastest"
					% (lvl * 100.0))
			row.add_child(bar2)
			var btn := Button.new()
			UITheme.style_button(btn)
			var qualified := lvl >= NpcSkills.QUALIFIED
			btn.text = "Revoke" if qualified else "Grant"
			btn.pressed.connect(func() -> void:
				var sk2 := _skills()
				if sk2 == null:
					return
				if qualified:
					sk2.revoke(_person_id, tag)
				else:
					sk2.grant(_person_id, tag)
				_persist()
				_person_sig = "<unbuilt>"
				_refresh())
			row.add_child(btn)

	# On-call membership.
	if oc != null and not oc.roles.is_empty():
		_person_box.add_child(_section("On call"))
		for r in oc.roles:
			var role: Dictionary = r
			var rid := str(role.get("role_id", ""))
			var row2 := HBoxContainer.new()
			row2.add_theme_constant_override("separation", 8)
			_person_box.add_child(row2)
			var cb := CheckBox.new()
			cb.text = str(role.get("label", rid))
			cb.add_theme_color_override("font_color", C_TEXT)
			cb.set_pressed_no_signal((role.get("members", []) as Array).has(_person_id))
			cb.toggled.connect(func(on: bool) -> void:
				var oc2 := _oncall()
				if oc2 == null:
					return
				var mem: Array = oc2.find_role(rid).get("members", []) as Array
				if on and not mem.has(_person_id):
					mem.append(_person_id)
				elif not on:
					mem.erase(_person_id)
				_persist()
				_person_sig = "<unbuilt>")
			row2.add_child(cb)
