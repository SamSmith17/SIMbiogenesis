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
var _card: PanelContainer = null
var _card_title: Label = null
var _card_body: Label = null
var _card_follow: Button = null
var _feed_box: VBoxContainer = null
var _alarm_lbl: Label = null
var _speed_lbl: Label = null
var _pick_lbl: Label = null


func _ready() -> void:
	layer = UITheme.LAYER_PANEL
	_build()
	set_process(false)


func bind(view: SettlementView, bridge: Variant) -> void:
	_view = view
	_bridge = bridge
	if _view != null and not _view.selection_changed.is_connected(_on_selection):
		_view.selection_changed.connect(_on_selection)


func show_hud() -> void:
	visible = true
	set_process(true)
	_refresh()


func hide_hud() -> void:
	visible = false
	set_process(false)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH_S:
		return
	_accum = 0.0
	_refresh()


func _build() -> void:
	# Top-left: where you are on the scale, and what is wrong.
	var tl := VBoxContainer.new()
	tl.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	tl.offset_left = 16
	tl.offset_top = 120
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tl)
	_scale_lbl = Label.new()
	_scale_lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_scale_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	tl.add_child(_scale_lbl)
	_alarm_lbl = Label.new()
	_alarm_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_alarm_lbl.add_theme_color_override("font_color", UITheme.C_WARN)
	_alarm_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_alarm_lbl.custom_minimum_size = Vector2(280, 0)
	tl.add_child(_alarm_lbl)
	_speed_lbl = Label.new()
	_speed_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_speed_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	tl.add_child(_speed_lbl)
	var keys := Label.new()
	keys.text = "Wheel zoom · drag pan · right-drag orbit · F follow · G drop in · Esc leave"
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

	# Bottom-left: the settlement feed — the answer to "what happened while I
	# was fast-forwarding".
	var feed_panel := PanelContainer.new()
	feed_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.82))
	feed_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	feed_panel.offset_left = 16
	feed_panel.offset_top = -260
	feed_panel.offset_right = 430
	feed_panel.offset_bottom = -110
	feed_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(feed_panel)
	_feed_box = VBoxContainer.new()
	_feed_box.add_theme_constant_override("separation", 1)
	feed_panel.add_child(_feed_box)

	# Right: the selection card. Inspection only — there is no order verb here.
	_card = PanelContainer.new()
	_card.add_theme_stylebox_override("panel", UITheme.panel_style())
	_card.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_card.offset_left = -320
	_card.offset_right = -16
	_card.offset_top = 120
	_card.visible = false
	add_child(_card)
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
	_card_follow.text = "Follow (F)"
	_card_follow.pressed.connect(func() -> void:
		if _view != null:
			_view.set("_follow_id", str(_view.selection().get("agent_id", ""))))
	cv.add_child(_card_follow)


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
	match str(sel.get("kind", "")):
		"npc":
			var d: Dictionary = sel.get("detail", {})
			_card_title.text = str(d.get("name", "Someone"))
			_card_body.text = "%s\n%s%s" % [
				str(d.get("status", "")),
				str(d.get("morale_label", "")),
				"  · carrying a load" if bool(d.get("carrying", false)) else ""]
			_card_follow.visible = true
		"crew":
			_card_title.text = "🔨 %s" % str(sel.get("label", "Work site"))
			var w := int(sel.get("workers", 0))
			var mn := int(sel.get("min_workers", 1))
			_card_body.text = ("%d of %d — gathering" % [w, mn]) if w < mn \
				else "%d working · %d%%" % [w, int(round(float(sel.get("progress", 0.0)) * 100.0))]
			_card_follow.visible = false
		"space":
			_card_title.text = SpaceTypes.label(str(sel.get("space_type", "")))
			_card_body.text = "Tagged space"
			_card_follow.visible = false
		"prop":
			_card_title.text = str(sel.get("prop_id", "Prop"))
			_card_body.text = "Placed prop"
			_card_follow.visible = false
		_:
			_card.visible = false


func _refresh() -> void:
	if _view == null:
		return
	var cam := _view.camera()
	if cam != null and _scale_lbl != null:
		_scale_lbl.text = "%s · %s m" % [cam.scale_label(), str(int(round(cam.height())))]
	var main := get_tree().current_scene
	if _speed_lbl != null and main != null and "time_scale" in main:
		var ts := float(main.get("time_scale"))
		_speed_lbl.text = "paused" if ts <= 0.0 else "%d× · %s" % [
			int(round(ts * 3600.0)),
			("following %s" % _view.following()) if not _view.following().is_empty() else "watching"]
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
	for c in _feed_box.get_children():
		c.queue_free()
	for e in entries:
		var ed: Dictionary = e
		var l := Label.new()
		l.text = "%s  %s" % [_clock(float(ed.get("abs_h", 0.0))), str(ed.get("text", ""))]
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		var sev := int(ed.get("severity", SettlementLog.INFO))
		l.add_theme_color_override("font_color",
			UITheme.C_WARN if sev >= SettlementLog.ALERT else UITheme.C_TEXT_S)
		_feed_box.add_child(l)


static func _clock(abs_h: float) -> String:
	var h := fposmod(abs_h, 24.0)
	return "%02d:%02d" % [int(h), int(fposmod(h * 60.0, 60.0))]
