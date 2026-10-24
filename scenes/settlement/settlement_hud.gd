extends CanvasLayer

## On-screen furniture for the settlement view: what you selected, what has
## been happening, how fast time is running, and the way out.
##
## Deliberately sparse. The view's whole point is watching the world, so the
## HUD sits at the edges and never covers the middle. No class_name — the
## ui_compile selftest sweeps scenes/settlement/ and parses it there.
##
## The feed is the quiet-alarm channel: it scrolls, it tints by severity, and
## nothing in it beeps or has to be dismissed. That was the explicit ask.

const REFRESH_S := 0.5
const FEED_LINES := 12

var _view: SettlementView = null
var _bridge: Variant = null
var _accum := 0.0

var _scale_lbl: Label = null
var _vibe_lbl: Label = null
var _card: PanelContainer = null
var _card_title: Label = null
var _card_body: Label = null
var _card_follow: Button = null
var _card_person: Button = null
var _card_task: Button = null
## Resolved once per selection, not per frame — Vector2.INF = no task site.
var _card_task_site := Vector2.INF
var _feed_box: VBoxContainer = null
var _feed_sig := "<unbuilt>"
var _alarm_lbl: Label = null
var _speed_lbl: Label = null
var _pick_lbl: Label = null
## Festival mode's panel: status, the two clock jumps, leave / clear.
var _fest_panel: PanelContainer = null
var _fest_status: Label = null
var _fest_notes: Label = null
var _fest_sig := "<unbuilt>"
var _fest_pop_slider: HSlider = null
var _fest_pop_lbl: Label = null
var _fest_pop_timer: Timer = null
const FESTIVAL_SETUP_CARD := preload("res://scenes/settlement/festival_setup_card.gd")
var _setup_card: Node = null


func _ready() -> void:
	layer = UITheme.LAYER_PANEL
	_build()
	set_process(false)


func bind(view: SettlementView, bridge: Variant) -> void:
	_view = view
	_bridge = bridge
	if _view != null and not _view.selection_changed.is_connected(_on_selection):
		_view.selection_changed.connect(_on_selection)


const STATUS_W := 360.0


func show_hud() -> void:
	visible = true
	set_process(true)
	# The first-person HUD steps aside into pills while the view is up.
	HudLayout.claim("settlement_view", {"tuck": ["top_left", "top_right", "bottom_left"]})
	_refresh()


func hide_hud() -> void:
	visible = false
	set_process(false)
	HudLayout.release("settlement_view")


func _process(delta: float) -> void:
	# The score line pulses green when it goes up.
	if _peak_lbl != null and _peak_flash > 0.0:
		_peak_flash = maxf(_peak_flash - delta * 1.8, 0.0)
		_peak_lbl.modulate = Color(1, 1, 1).lerp(Color(0.8, 1.7, 0.9), _peak_flash)
	_accum += delta
	if _accum < REFRESH_S:
		return
	_accum = 0.0
	_refresh()


var _peak_lbl: Label = null
var _peak_last := -1
var _peak_flash := 0.0


func _build() -> void:
	# Top-left: where you are on the scale, and what is wrong.
	# On a translucent panel (the text used to sit straight on the 3D scene —
	# and on the Power Scoreboard), placed by the HUD layout manager.
	var tl_panel := PanelContainer.new()
	tl_panel.name = "SettlementStatus"
	tl_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.82))
	tl_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tl_panel.custom_minimum_size = Vector2(STATUS_W, 0)
	add_child(tl_panel)
	var tl := VBoxContainer.new()
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tl.add_theme_constant_override("separation", 3)
	tl_panel.add_child(tl)
	HudLayout.register(tl_panel, "settlement_status", "top_left", {"order": 20, "priority": 9, "tuckable": false,
		"size": func() -> Vector2: return Vector2(STATUS_W, tl_panel.get_combined_minimum_size().y)})
	_scale_lbl = Label.new()
	_scale_lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_scale_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	tl.add_child(_scale_lbl)
	# The festival's overall vibe — the one number the whole mode exists to
	# let you watch move. Hidden on a map with no festival camps.
	_vibe_lbl = Label.new()
	_vibe_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_vibe_lbl.visible = false
	tl.add_child(_vibe_lbl)
	_peak_lbl = Label.new()
	_peak_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_peak_lbl.add_theme_color_override("font_color", Color(0.55, 1.0, 0.62))
	_peak_lbl.add_theme_color_override("font_outline_color", Color(0.04, 0.2, 0.08, 0.9))
	_peak_lbl.add_theme_constant_override("outline_size", 4)
	_peak_lbl.visible = false
	tl.add_child(_peak_lbl)
	_alarm_lbl = Label.new()
	_alarm_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_alarm_lbl.add_theme_color_override("font_color", UITheme.C_WARN)
	_alarm_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_alarm_lbl.custom_minimum_size = Vector2(STATUS_W - 24.0, 0)
	tl.add_child(_alarm_lbl)
	_speed_lbl = Label.new()
	_speed_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_speed_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	tl.add_child(_speed_lbl)
	var keys := Label.new()
	keys.text = "Wheel zoom · drag pan · right-drag orbit · F follow · G drop in · Esc leave"
	keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	keys.custom_minimum_size = Vector2(STATUS_W - 24.0, 0)
	keys.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	keys.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	tl.add_child(keys)
	# Shown only while the view is borrowed for a one-shot pick, so the player
	# is never left wondering why their click closed the view.
	_pick_lbl = Label.new()
	_pick_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_pick_lbl.add_theme_color_override("font_color", UITheme.C_INFO)
	_pick_lbl.visible = false
	tl.add_child(_pick_lbl)
	_build_festival_panel()

	# Bottom-left: the settlement feed — the answer to "what happened while I
	# was fast-forwarding".
	var feed_panel := PanelContainer.new()
	feed_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.82))
	feed_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feed_panel.clip_contents = true
	add_child(feed_panel)
	HudLayout.register(feed_panel, "settlement_log", "bottom_left", {"order": 5, "priority": 2,
		"title": "settlement log", "icon": "list",
		"size": func() -> Vector2: return Vector2(414, 150),
		"compact": func() -> String: return "Settlement log"})
	_feed_box = VBoxContainer.new()
	_feed_box.add_theme_constant_override("separation", 1)
	feed_panel.add_child(_feed_box)

	# Right: the selection card. Inspection only — there is no order verb here.
	_card = PanelContainer.new()
	_card.add_theme_stylebox_override("panel", UITheme.panel_style())
	_card.custom_minimum_size = Vector2(304, 0)
	_card.visible = false
	add_child(_card)
	HudLayout.register(_card, "settlement_card", "top_right", {"order": 20, "priority": 8, "tuckable": false,
		"size": func() -> Vector2: return Vector2(304, _card.get_combined_minimum_size().y)})
	var cv := VBoxContainer.new()
	_card.add_child(cv)
	_card_title = Label.new()
	_card_title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	cv.add_child(_card_title)
	_card_body = Label.new()
	_card_body.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_card_body.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_card_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cv.add_child(_card_body)
	_card_follow = Button.new()
	UITheme.style_button(_card_follow)
	_card_follow.text = "Follow (F)"
	_card_follow.tooltip_text = "Keep the camera on this person as they move"
	_card_follow.pressed.connect(func() -> void:
		if _view != null:
			_view.set("_follow_id", str(_view.selection().get("agent_id", ""))))
	cv.add_child(_card_follow)
	# Inspection, not orders: the jump opens this person's ledger in the Work
	# Planner (hours, skills, on-call). The planner is a graph-layer modal, so
	# the view yields first — same discipline as the work dock's buttons.
	_card_person = Button.new()
	UITheme.style_button(_card_person)
	_card_person.text = "Hours & skills…"
	_card_person.tooltip_text = "This person's ledger in the Work Planner: hours banked, skills, on-call roles"
	_card_person.pressed.connect(func() -> void:
		if _view == null:
			return
		var aid := str(_view.selection().get("agent_id", ""))
		if aid.is_empty():
			return
		var sgv := ServiceLocator.graph()
		if sgv == null or not sgv.has_method("open_work_planner"):
			return
		# THIS person's habitat — "" let the planner bind to whichever
		# habitat happened to be first on a two-habitat map.
		var iid := ""
		if _bridge != null and _bridge.has_method("habitat_of_agent"):
			iid = str(_bridge.call("habitat_of_agent", aid))
		_view.close()
		sgv.call("open_work_planner", iid, aid))
	cv.add_child(_card_person)
	# Looking, never ordering: frames the selected person's CURRENT job so
	# "what are they working on" is one click from the card that named it.
	_card_task = Button.new()
	UITheme.style_button(_card_task)
	_card_task.text = "⌖ Their task"
	_card_task.tooltip_text = "Look at the job this person is on — looking, never ordering"
	_card_task.pressed.connect(func() -> void:
		if _view == null or _card_task_site == Vector2.INF:
			return
		var cam: Variant = _view.camera()
		if cam != null:
			cam.call("look_at_xz", _card_task_site))
	cv.add_child(_card_task)


## Festival mode's furniture. Shown only while the mode is on; it is the
## mode's whole UI, so a tester never has to find Settings -> NPCs -> Testing or
## the timeline's date box to see the evening. Buttons change CONDITIONS
## (the clock, the mode) -- never a person.
func _build_festival_panel() -> void:
	_fest_panel = PanelContainer.new()
	_fest_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.86))
	_fest_panel.custom_minimum_size = Vector2(STATUS_W, 0)
	_fest_panel.visible = false
	add_child(_fest_panel)
	HudLayout.register(_fest_panel, "festival_panel", "top_left", {"order": 30, "priority": 7, "tuckable": false,
		"size": func() -> Vector2: return Vector2(STATUS_W, _fest_panel.get_combined_minimum_size().y)})
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	_fest_panel.add_child(v)
	var title := Label.new()
	title.text = "🎪 Festival mode"
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	title.add_theme_color_override("font_color", UITheme.C_OK)
	v.add_child(title)
	_fest_status = Label.new()
	_fest_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_fest_status.add_theme_color_override("font_color", UITheme.C_TEXT)
	_fest_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_fest_status)
	var hint := Label.new()
	hint.text = "Nobody queues or leaves. Each camp chooses its own supply (Camps & calculator): infinite and metered, its own tanks, or a shared site depot. Stage set 20:00–02:00 · camps sleep 02:30–09:30."
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	# Population: the festival's total headcount — the knob for how many
	# people this machine draws (the natural split comes from the camps'
	# areas). Applied on release (each change resizes every roster in place).
	var pop_row := HBoxContainer.new()
	pop_row.add_theme_constant_override("separation", 6)
	v.add_child(pop_row)
	var pop_cap := Label.new()
	pop_cap.text = "People"
	pop_cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	pop_cap.add_theme_color_override("font_color", UITheme.C_TEXT)
	pop_row.add_child(pop_cap)
	_fest_pop_slider = HSlider.new()
	_fest_pop_slider.min_value = 0
	_fest_pop_slider.max_value = 2000
	_fest_pop_slider.step = 20
	_fest_pop_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fest_pop_slider.custom_minimum_size.x = 150
	_fest_pop_slider.tooltip_text = "Total festival population. 0 = natural (from the camps' painted areas). Fewer people = a faster sim at high speeds."
	_fest_pop_slider.value = PopTestPrefs.festival_target_people()
	pop_row.add_child(_fest_pop_slider)
	_fest_pop_lbl = Label.new()
	_fest_pop_lbl.custom_minimum_size.x = 64
	_fest_pop_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_fest_pop_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	pop_row.add_child(_fest_pop_lbl)
	_fest_pop_timer = Timer.new()
	_fest_pop_timer.one_shot = true
	_fest_pop_timer.wait_time = 0.4
	add_child(_fest_pop_timer)
	_fest_pop_timer.timeout.connect(func() -> void:
		var fm0 := _festival_mode()
		if fm0 != null:
			fm0.call("set_target_people", int(_fest_pop_slider.value)))
	_fest_pop_slider.value_changed.connect(func(val: float) -> void:
		_fest_pop_lbl.text = "natural" if val <= 0.0 else str(int(val))
		_fest_pop_timer.start())
	_fest_pop_lbl.text = "natural" if _fest_pop_slider.value <= 0.0 else str(int(_fest_pop_slider.value))
	# FUCK YES!!! contagion (PopTestPrefs.peak_contagion, live).
	var cont_row := HBoxContainer.new()
	cont_row.add_theme_constant_override("separation", 6)
	v.add_child(cont_row)
	var cont_cap := Label.new()
	cont_cap.text = "Contagion"
	cont_cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	cont_cap.add_theme_color_override("font_color", Color(0.55, 1.0, 0.62))
	cont_row.add_child(cont_cap)
	var cont := HSlider.new()
	cont.min_value = 0.0
	cont.max_value = PopTestPrefs.MAX_PEAK_CONTAGION
	cont.step = 0.05
	cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cont.custom_minimum_size.x = 150
	cont.value = PopTestPrefs.peak_contagion()
	cont.tooltip_text = "How strongly one person at FUCK YES!!! raises the odds of the people round them. 0 = no spread, 1 = as designed, 4 = wildfire."
	cont_row.add_child(cont)
	var cont_lbl := Label.new()
	cont_lbl.custom_minimum_size.x = 64
	cont_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	cont_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	cont_lbl.text = "off" if cont.value <= 0.001 else "%.2f×" % cont.value
	cont_row.add_child(cont_lbl)
	cont.value_changed.connect(func(val: float) -> void:
		PopTestPrefs.set_peak_contagion(val)
		cont_lbl.text = "off" if val <= 0.001 else "%.2f×" % val)
	cont.drag_ended.connect(func(_c: bool) -> void: PopTestPrefs.save())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	var evening := Button.new()
	UITheme.style_button(evening)
	evening.text = "⏩ Evening 19:30"
	evening.tooltip_text = "Set the clock to 19:30 — dinner done, the stage set about to start"
	evening.pressed.connect(func() -> void:
		var fm := _festival_mode()
		if fm != null:
			fm.call("jump_to_hour", 19.5))
	row.add_child(evening)
	var morning := Button.new()
	UITheme.style_button(morning)
	morning.text = "☀ Morning 10:00"
	morning.tooltip_text = "Set the clock to 10:00 — the camps waking up"
	morning.pressed.connect(func() -> void:
		var fm := _festival_mode()
		if fm != null:
			fm.call("jump_to_hour", 10.0))
	row.add_child(morning)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	v.add_child(row2)
	var leave := Button.new()
	UITheme.style_button(leave)
	leave.text = "Leave festival mode"
	leave.tooltip_text = "Guardrails back on; the camps and venues stay"
	leave.pressed.connect(func() -> void:
		var fm := _festival_mode()
		if fm != null:
			fm.call("close"))
	row2.add_child(leave)
	var clear := Button.new()
	UITheme.style_button(clear)
	clear.text = "Clear seeded"
	clear.tooltip_text = "Remove what festival mode seeded: its venues, every painted camp's headcount, the demo zone"
	clear.pressed.connect(func() -> void:
		var fm := _festival_mode()
		if fm != null:
			fm.call("clear_seeded"))
	row2.add_child(clear)
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 6)
	v.add_child(row3)
	var setup := Button.new()
	UITheme.style_button(setup)
	setup.text = "Set up the gathering…"
	setup.tooltip_text = "Lay out named camps of a set size round the location marker"
	setup.pressed.connect(func() -> void:
		var fm := _festival_mode()
		if fm == null:
			return
		if _setup_card == null:
			_setup_card = FESTIVAL_SETUP_CARD.new()
			_setup_card.name = "FestivalSetupCard"
			add_child(_setup_card)
		_setup_card.call("open", fm))
	row3.add_child(setup)
	var edit := Button.new()
	UITheme.style_button(edit)
	edit.text = "✎ Edit site (E)"
	edit.tooltip_text = "Select, move, reshape and name camps and NPC spaces; draw new spaces; tag objects"
	edit.pressed.connect(func() -> void:
		if _view != null:
			_view.call("toggle_editing"))
	row3.add_child(edit)
	var row4 := HBoxContainer.new()
	row4.add_theme_constant_override("separation", 6)
	v.add_child(row4)
	var camps_btn := Button.new()
	UITheme.style_button(camps_btn)
	camps_btn.text = "Camps & calculator…"
	camps_btn.tooltip_text = "Each camp's water, food and waste — per day, per person, in total — its supply, and how closed its loops are"
	camps_btn.pressed.connect(func() -> void:
		var sgv := ServiceLocator.graph()
		if sgv != null:
			sgv.call("open_camps_panel", Callable(self, "_look_at_camp")))
	row4.add_child(camps_btn)
	var to_marker := Button.new()
	UITheme.style_button(to_marker)
	to_marker.text = "Move festival to marker"
	to_marker.tooltip_text = "Carry every festival camp, road, zone and seeded space so the festival is centred on the location marker"
	to_marker.pressed.connect(func() -> void:
		var fm := _festival_mode()
		if fm != null:
			var d: Variant = fm.call("move_to_marker")
			if d is Vector2 and (d as Vector2).length() > 1.0:
				var view: Node = get_parent()
				var cam: Variant = view.call("camera") if view != null and view.has_method("camera") else null
				if cam != null:
					cam.call("look_at_xz", SiteCentre.xz(self)))
	row4.add_child(to_marker)
	_fest_notes = Label.new()
	_fest_notes.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_fest_notes.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_fest_notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_fest_notes)


## The camps panel's "Look": fly the settlement camera to a camp.
func _look_at_camp(lot_key: String) -> void:
	var loader := TerrainSurfaceQuery.find_terrain_loader(get_tree().current_scene)
	if loader == null or _view == null:
		return
	var poly: PackedVector2Array = loader.call("camp_lot_polygon", lot_key)
	var cam: Variant = _view.call("camera")
	if poly.size() >= 3 and cam != null:
		cam.call("look_at_xz", CampAreaLayer._inner_point(poly))


func _festival_mode() -> Node:
	var main := get_tree().current_scene
	if main == null or not main.has_method("festival_mode_active"):
		return null
	var fm: Variant = main.get("festival_mode")
	return fm if fm is Node and is_instance_valid(fm) else null


func _refresh_festival_panel() -> void:
	if _fest_panel == null:
		return
	var fm := _festival_mode()
	var on := fm != null and bool(fm.call("is_active"))
	_fest_panel.visible = on
	if not on:
		_fest_sig = "<unbuilt>"
		return
	var st: Dictionary = fm.call("status")
	var notes: PackedStringArray = fm.call("notes")
	var sig := "%s|%s" % [str(st), ";".join(notes)]
	if sig == _fest_sig:
		return
	_fest_sig = sig
	var people := int(st.get("people", 0))
	var tiers := ""
	if int(st.get("light", 0)) > 0:
		tiers = " · %d up close, %d as crowd" % [int(st.get("full", 0)), int(st.get("light", 0))]
	_fest_status.text = "%s in %s%s · %s" % [
		UiText.count(people, "person"), UiText.count(int(st.get("camps", 0)), "camp"), tiers,
		UiText.count(int(st.get("venues", 0)), "seeded venue")]
	if int(st.get("target", 0)) > 0 and int(st.get("natural", 0)) > 0:
		_fest_status.text += "\nScaled from %d (natural) to %d." % [int(st["natural"]), int(st["target"])]
	if people == 0:
		_fest_status.text += "\nNobody yet — the sim starts on the next tick (unpause the clock if it is paused)."
	var tail := PackedStringArray()
	for i in range(maxi(notes.size() - 3, 0), notes.size()):
		tail.append(notes[i])
	_fest_notes.text = "\n".join(tail)
	_fest_notes.visible = not tail.is_empty()


func set_pick_hint(text: String) -> void:
	if _pick_lbl == null:
		return
	_pick_lbl.text = text
	_pick_lbl.visible = not text.is_empty()


func _on_selection(sel: Dictionary) -> void:
	if _card == null:
		return
	if sel.is_empty():
		_card.visible = false
		return
	_card.visible = true
	# Neutral by default; the npc branch overrides with the person's pastel —
	# without this reset a crew card inherits the last person's color.
	_card_title.add_theme_color_override("font_color", UITheme.C_TEXT)
	match str(sel.get("kind", "")):
		"npc":
			var d: Dictionary = sel.get("detail", {})
			_card_title.text = str(d.get("name", "Someone"))
			# The person's own pastel — the same one on their avatar rim, so
			# the card visibly belongs to the figure that was clicked.
			var pastel := NpcPopulationEngine.color_for_agent(
				str(sel.get("agent_id", "")))
			_card_title.add_theme_color_override("font_color",
				pastel if pastel != Color.BLACK else UITheme.C_TEXT)
			_card_body.text = "%s\n%s%s" % [
				str(d.get("status", "")),
				str(d.get("morale_label", "")),
				"  · carrying a load" if bool(d.get("carrying", false)) else ""]
			_card_follow.visible = true
			_card_person.visible = true
			_card_task_site = Vector2.INF
			if _bridge != null and _bridge.has_method("chore_site_of"):
				var site: Variant = _bridge.call("chore_site_of",
					str(sel.get("agent_id", "")), get_tree().current_scene)
				if site is Vector2:
					_card_task_site = site
			_card_task.visible = _card_task_site != Vector2.INF
		"crew":
			_card_title.text = "🔨 %s" % str(sel.get("label", "Work site"))
			var w := int(sel.get("workers", 0))
			var mn := int(sel.get("min_workers", 1))
			_card_body.text = ("%d of %d — waiting" % [w, mn]) if w < mn \
				else "%d working · %d%%" % [w, int(round(float(sel.get("progress", 0.0)) * 100.0))]
			_card_follow.visible = false
			_card_person.visible = false
			_card_task.visible = false
		"space":
			_card_title.text = SpaceTypes.label(str(sel.get("space_type", "")))
			_card_body.text = "Tagged space"
			_card_follow.visible = false
			_card_person.visible = false
			_card_task.visible = false
		"prop":
			_card_title.text = str(sel.get("prop_id", "Prop"))
			_card_body.text = "Placed prop"
			_card_follow.visible = false
			_card_person.visible = false
			_card_task.visible = false
		_:
			_card.visible = false


func _refresh() -> void:
	if _view == null:
		return
	var cam := _view.camera()
	if cam != null and _scale_lbl != null:
		_scale_lbl.text = "%s · %s m" % [cam.scale_label(), str(int(round(cam.height())))]
	var main := get_tree().current_scene
	if _vibe_lbl != null and main != null:
		var sgv := ServiceLocator.graph()
		var v: Dictionary = sgv.call("festival_vibe") if sgv != null and sgv.has_method("festival_vibe") else {}
		_vibe_lbl.visible = not v.is_empty() and int(v.get("people", 0)) > 0
		# The PEAK EXPERIENCE score: the festival's measure of success, on its
		# own line (it does not wait for the vibe summary).
		var br: Variant = sgv.call("npc_population_bridge") if sgv != null and sgv.has_method("npc_population_bridge") else null
		var on: bool = br != null and br.has_method("peak_score") and bool(br.call("active"))
		_peak_lbl.visible = on
		if on:
			var ps: Dictionary = br.call("peak_score")
			var total := int(ps.get("total", 0))
			if _peak_last >= 0 and total > _peak_last:
				_peak_flash = 1.0
			_peak_last = total
			_peak_lbl.text = "✦ %s  ·  %d %s now" % [UiText.count(total, "Peak Experience"), int(ps.get("now", 0)), NpcPeak.LABEL]
		if _vibe_lbl.visible:
			_vibe_lbl.text = str(v.get("headline", ""))
			_vibe_lbl.add_theme_color_override("font_color", v.get("color", UITheme.C_TEXT) as Color)
	if _speed_lbl != null and main != null and "time_scale" in main:
		var ts := float(main.get("time_scale"))
		_speed_lbl.text = "paused" if ts <= 0.0 else "%d× · %s" % [
			int(round(ts * 3600.0)),
			("following %s" % _view.following()) if not _view.following().is_empty() else "watching"]
		if PopTestPrefs.easy_override():
			_speed_lbl.text += "  · FESTIVAL (each camp's own supply)"
		elif PopTestPrefs.any_active():
			_speed_lbl.text += "  · TESTING (guardrails off)"
	_refresh_festival_panel()
	if _bridge == null or not _bridge.has_method("settlement_log"):
		return
	var lg: SettlementLog = _bridge.call("settlement_log")
	# Standing problems, summarised — never a popup, never a sound.
	var alarms: Array = lg.open_alarms()
	if _alarm_lbl != null:
		_alarm_lbl.text = "" if alarms.is_empty() \
			else "⚠ %s" % str((alarms[0] as Dictionary).get("text", "")) \
				+ ("  (+%d more)" % (alarms.size() - 1) if alarms.size() > 1 else "")
	if _feed_box == null:
		return
	var entries := lg.recent(FEED_LINES)
	# An empty feed is the normal state of a settlement where nothing has gone
	# wrong; drawing an empty panel over the world for it is pure noise.
	var panel := _feed_box.get_parent() as Control
	if panel != null:
		panel.visible = not entries.is_empty()
	# Signature gate, same rule as every work panel: a blind rebuild every
	# 0.5 s churns the labels for a feed that mostly has not changed.
	var fsig := ""
	for e in entries:
		fsig += "%d;" % int((e as Dictionary).get("seq", (e as Dictionary).get("abs_h", 0.0) * 1000.0))
	if fsig == _feed_sig:
		return
	_feed_sig = fsig
	for c in _feed_box.get_children():
		c.queue_free()
	for e in entries:
		var ed: Dictionary = e
		var l := Label.new()
		l.text = "%s %s %s" % [_clock(float(ed.get("abs_h", 0.0))),
			SettlementLog.icon_for(str(ed.get("kind", ""))),
			str(ed.get("text", ""))]
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		var sev := int(ed.get("severity", SettlementLog.INFO))
		l.add_theme_color_override("font_color",
			UITheme.C_WARN if sev >= SettlementLog.ALERT else UITheme.C_TEXT_S)
		_feed_box.add_child(l)


static func _clock(abs_h: float) -> String:
	var h := fposmod(abs_h, 24.0)
	return "%02d:%02d" % [int(h), int(fposmod(h * 60.0, 60.0))]
