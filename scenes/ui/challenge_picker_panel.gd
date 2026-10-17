extends Control

## Challenge picker + win/fail result cards for the playable puzzle loop.
## Lazy-instantiated by TimelineUI; signals wired from Main → ChallengeRunner.

const ChallengeCatalogScript := preload("res://gameplay/challenge_catalog.gd")
const HighScoreStoreScript := preload("res://core/high_score_store.gd")
const ChallengeDefScript := preload("res://gameplay/challenge_def.gd")
const MODAL_NAME := "challenge_picker"
const PANEL_SIZE := Vector2(640.0, 520.0)

const C_BG := UITheme.C_BG
const C_PANEL := UITheme.C_PANEL
const C_BORDER := UITheme.C_BORDER
const C_PRIMARY := UITheme.C_PRIMARY
const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const C_TEXT_M := UITheme.C_TEXT_M

var _timeline: Node = null
var _main_node: Node = null

var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _cards_root: VBoxContainer = null
var _header_lbl: Label = null
var _active_lbl: Label = null
var _abort_btn: Button = null

var _result_backdrop: ColorRect = null
var _result_panel: PanelContainer = null
var _result_title: Label = null
var _result_body: RichTextLabel = null
var _result_retry_btn: Button = null
var _result_close_btn: Button = null
var _last_result_id: String = ""


func bind_timeline(tl: Node) -> void:
	_timeline = tl
	_main_node = tl.get("_main") if tl != null else null
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build_ui()
	var layer := tl.get_parent() if tl != null else null
	if layer != null:
		layer.add_child(self)
	else:
		tl.add_child(self)


func toggle() -> void:
	if _result_backdrop != null and _result_backdrop.visible:
		close_result()
	elif visible and _backdrop != null and _backdrop.visible:
		close()
	else:
		open()


func open() -> void:
	_main_node = _timeline.get("_main") if _timeline != null else _main_node
	_refresh_cards()
	_set_picker_visible(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	HudLayout.claim_modal(MODAL_NAME)


func close() -> void:
	_set_picker_visible(false)
	HudLayout.release(MODAL_NAME)
	if _result_backdrop == null or not _result_backdrop.visible:
		CursorController.release_modal(MODAL_NAME)


func show_result(challenge_id: String, won: bool, payload: Dictionary) -> void:
	_last_result_id = challenge_id
	_set_picker_visible(false)
	_build_result_content(challenge_id, won, payload)
	_result_backdrop.visible = true
	_result_panel.visible = true
	visible = true
	CursorController.request_modal("challenge_result", Callable(self, "close_result"))
	HudLayout.claim_modal("challenge_result")


func close_result() -> void:
	if _result_backdrop != null:
		_result_backdrop.visible = false
	if _result_panel != null:
		_result_panel.visible = false
	if _backdrop == null or not _backdrop.visible:
		visible = false
	CursorController.release_modal("challenge_result")
	HudLayout.release("challenge_result")


func refresh_active_label() -> void:
	if _active_lbl == null:
		return
	var runner := _runner()
	if runner == null or not bool(runner.call("is_active")):
		_active_lbl.text = "Pick a mission for this location."
		if _abort_btn != null:
			_abort_btn.visible = false
		return
	var def: Variant = runner.call("active_def")
	var title := str(def.title) if def != null else str(runner.call("active_challenge_id"))
	var metrics: Dictionary = runner.call("last_metrics") as Dictionary
	var elapsed := 0.0
	if runner.has_method("evaluate_now"):
		var ev: Dictionary = runner.call("evaluate_now") as Dictionary
		elapsed = float(ev.get("elapsed_h", 0.0))
	var dur := float(def.duration_hours) if def != null else 0.0
	_active_lbl.text = "Running: %s — %.0f / %.0f h" % [title, elapsed, dur]
	if _abort_btn != null:
		_abort_btn.visible = true


func _build_ui() -> void:
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.visible = false
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.98))
	add_child(_panel)
	UiScreenLayout.clamped_center(_panel, PANEL_SIZE)

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left", UITheme.SPACE_LG)
	outer.add_theme_constant_override("margin_right", UITheme.SPACE_LG)
	outer.add_theme_constant_override("margin_top", UITheme.SPACE_MD)
	outer.add_theme_constant_override("margin_bottom", UITheme.SPACE_MD)
	_panel.add_child(outer)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_MD)
	outer.add_child(root)

	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	_header_lbl = Label.new()
	_header_lbl.text = "🎯  Challenges"
	_header_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_lbl.add_theme_color_override("font_color", C_PRIMARY)
	_header_lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	title_row.add_child(_header_lbl)
	var close_btn := IconButton.close(close)
	title_row.add_child(close_btn)

	_active_lbl = Label.new()
	_active_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_active_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_active_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(_active_lbl)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 340.0)
	root.add_child(scroll)

	_cards_root = VBoxContainer.new()
	_cards_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_root.add_theme_constant_override("separation", UITheme.SPACE_SM)
	scroll.add_child(_cards_root)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(footer)
	_abort_btn = Button.new()
	_abort_btn.text = "Abort mission"
	_abort_btn.tooltip_text = "Stop the active challenge"
	UITheme.style_button(_abort_btn)
	_abort_btn.visible = false
	_abort_btn.pressed.connect(_on_abort_pressed)
	footer.add_child(_abort_btn)

	_result_backdrop = ColorRect.new()
	_result_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result_backdrop.color = Color(0.0, 0.0, 0.0, 0.65)
	_result_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_backdrop.visible = false
	add_child(_result_backdrop)

	_result_panel = PanelContainer.new()
	_result_panel.visible = false
	_result_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_panel.custom_minimum_size = Vector2(420.0, 0.0)
	_result_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.98))
	add_child(_result_panel)
	UiScreenLayout.clamped_center(_result_panel, Vector2(440.0, 280.0))

	var r_outer := MarginContainer.new()
	r_outer.add_theme_constant_override("margin_left", UITheme.SPACE_LG)
	r_outer.add_theme_constant_override("margin_right", UITheme.SPACE_LG)
	r_outer.add_theme_constant_override("margin_top", UITheme.SPACE_LG)
	r_outer.add_theme_constant_override("margin_bottom", UITheme.SPACE_LG)
	_result_panel.add_child(r_outer)

	var r_root := VBoxContainer.new()
	r_root.add_theme_constant_override("separation", UITheme.SPACE_MD)
	r_outer.add_child(r_root)

	_result_title = Label.new()
	_result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	r_root.add_child(_result_title)

	_result_body = RichTextLabel.new()
	_result_body.bbcode_enabled = true
	_result_body.fit_content = true
	_result_body.scroll_active = false
	_result_body.custom_minimum_size = Vector2(0.0, 80.0)
	_result_body.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	r_root.add_child(_result_body)

	var r_btns := HBoxContainer.new()
	r_btns.alignment = BoxContainer.ALIGNMENT_CENTER
	r_btns.add_theme_constant_override("separation", UITheme.SPACE_SM)
	r_root.add_child(r_btns)

	_result_retry_btn = Button.new()
	_result_retry_btn.text = "Try again"
	UITheme.style_button(_result_retry_btn)
	_result_retry_btn.pressed.connect(_on_result_retry)
	r_btns.add_child(_result_retry_btn)

	_result_close_btn = Button.new()
	_result_close_btn.text = "Close"
	UITheme.style_button(_result_close_btn)
	_result_close_btn.pressed.connect(close_result)
	r_btns.add_child(_result_close_btn)


func _refresh_cards() -> void:
	if _cards_root == null:
		return
	for c in _cards_root.get_children():
		c.queue_free()
	var lat_lon := _lat_lon()
	var runner := _runner()
	var active_id := ""
	if runner != null and bool(runner.call("is_active")):
		active_id = str(runner.call("active_challenge_id"))
	for def: ChallengeDef in ChallengeCatalogScript.all_challenges():
		_cards_root.add_child(_make_card(def, lat_lon, active_id))
	refresh_active_label()


func _make_card(def: ChallengeDef, lat_lon: Dictionary, active_id: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_right", UITheme.SPACE_MD)
	margin.add_theme_constant_override("margin_top", UITheme.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", UITheme.SPACE_SM)
	card.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UITheme.SPACE_XS)
	margin.add_child(col)

	var head := HBoxContainer.new()
	col.add_child(head)
	var title := Label.new()
	title.text = def.title
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", C_TEXT)
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	head.add_child(title)

	var best := HighScoreStoreScript.best_score(
			float(lat_lon.get("lat", 0.0)),
			float(lat_lon.get("lon", 0.0)),
			def.id)
	var best_lbl := Label.new()
	best_lbl.text = ("Best: %s" % UiText.thousands(int(round(best)))) if best > 0.01 else "Best: —"
	best_lbl.add_theme_color_override("font_color", C_TEXT_M)
	best_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	head.add_child(best_lbl)

	var desc := Label.new()
	desc.text = def.description
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", C_TEXT_S)
	desc.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	col.add_child(desc)

	var meta := Label.new()
	var meta_txt := "%s · %s · %s" % [
			_format_duration(def.resolved_duration_hours()),
			UiText.count(def.occupants, "occupant"),
			_win_hint(def),
	]
	if def.is_prebake():
		meta_txt += " · pre-computed, replay on failure"
	meta.text = meta_txt
	meta.add_theme_color_override("font_color", C_TEXT_M)
	meta.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	col.add_child(meta)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	col.add_child(row)

	var start := Button.new()
	var is_active := def.id == active_id
	start.text = "Running…" if is_active else "▶  Start mission"
	start.disabled = not active_id.is_empty() and not is_active
	UITheme.style_button(start)
	if not is_active and active_id.is_empty():
		start.add_theme_color_override("font_color", C_PRIMARY)
	start.pressed.connect(_on_start_pressed.bind(def.id))
	row.add_child(start)
	return card


func _build_result_content(challenge_id: String, won: bool, payload: Dictionary) -> void:
	var def: ChallengeDef = ChallengeCatalogScript.by_id(challenge_id)
	var title := def.title if def != null else challenge_id
	var metrics: Dictionary = payload.get("metrics", {}) as Dictionary
	if metrics.is_empty():
		var runner := _runner()
		if runner != null:
			metrics = runner.call("last_metrics") as Dictionary

	if won:
		_result_title.text = "★  Challenge complete"
		_result_title.add_theme_color_override("font_color", UITheme.C_OK)
	else:
		_result_title.text = "■  Challenge failed"
		_result_title.add_theme_color_override("font_color", UITheme.C_ERROR)

	var lines: PackedStringArray = PackedStringArray()
	lines.append("[b]%s[/b]" % title)
	if won:
		var score := float(payload.get("score", metrics.get("score", 0.0)))
		lines.append("")
		lines.append("[center][font_size=28][color=#22d3ee]%.0f[/color][/font_size][/center]" % score)
		lines.append("[center][color=#94a3b8]PUZZLE SCORE[/color][/center]")
		if bool(payload.get("new_best", false)):
			lines.append("[center][color=#26e577]New personal best![/color][/center]")
		lines.append("")
		lines.append("Mean closure: [b]%.0f%%[/b]" % (float(metrics.get("mean_closure_pct", 0.0)) * 100.0))
		lines.append("Autonomy: [b]%.1f[/b] person-days" % float(metrics.get("autonomy_person_days", 0.0)))
		if payload.has("utilization_pct"):
			lines.append("PV utilization: [b]%.0f%%[/b] of what the sky offered" %
				float(payload.get("utilization_pct", 0.0)))
		if int(payload.get("attempts", 0)) > 1:
			lines.append("Cleared on attempt [b]%d[/b]" % int(payload.get("attempts", 1)))
	else:
		var reason := str(payload.get("reason", ""))
		lines.append(ChallengeDefScript.reason_label(reason))
		if metrics.has("mean_closure_pct"):
			lines.append("Closure at fail: %.0f%%" % (float(metrics.get("mean_closure_pct", 0.0)) * 100.0))
		if def != null and def.is_prebake():
			lines.append("")
			lines.append("[color=#94a3b8]The timeline is parked at the breakpoint. " +
				"Fix your system in the graph, then Try again to replay the same " +
				"stretch of time.[/color]")

	_result_body.text = "\n".join(lines)
	_result_retry_btn.visible = true


func _on_start_pressed(challenge_id: String) -> void:
	if _main_node == null:
		_main_node = _timeline.get("_main") if _timeline != null else null
	if _main_node != null and _main_node.has_method("start_challenge"):
		if bool(_main_node.call("start_challenge", challenge_id)):
			close()


func _on_abort_pressed() -> void:
	if _main_node != null and _main_node.has_method("abort_challenge"):
		_main_node.call("abort_challenge")
	refresh_active_label()
	_refresh_cards()


func _on_result_retry() -> void:
	close_result()
	if not _last_result_id.is_empty() and _main_node != null \
			and _main_node.has_method("start_challenge"):
		_main_node.call("start_challenge", _last_result_id)


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close()


func _set_picker_visible(on: bool) -> void:
	visible = on or (_result_backdrop != null and _result_backdrop.visible)
	if _backdrop != null:
		_backdrop.visible = on
	if _panel != null:
		_panel.visible = on
	if on:
		UiScreenLayout.clamped_center(_panel, PANEL_SIZE)


func _runner() -> Node:
	if _main_node == null:
		_main_node = _timeline.get("_main") if _timeline != null else null
	if _main_node != null:
		return _main_node.get_node_or_null("ChallengeRunner") as Node
	return null


func _lat_lon() -> Dictionary:
	if _main_node == null:
		_main_node = _timeline.get("_main") if _timeline != null else null
	if _main_node == null:
		return {"lat": 0.0, "lon": 0.0}
	return {
		"lat": float(_main_node.get("latitude")) if _main_node.get("latitude") != null else 0.0,
		"lon": float(_main_node.get("longitude")) if _main_node.get("longitude") != null else 0.0,
	}


static func _format_duration(hours: float) -> String:
	if hours >= 24.0 and int(hours) % 24 == 0:
		return UiText.count(int(hours / 24.0), "day")
	return "%.0f h" % hours


static func _win_hint(def: ChallengeDef) -> String:
	if def.min_water_closure_pct > 0.0:
		return "Win: water closure ≥ %.0f%%" % (def.min_water_closure_pct * 100.0)
	if def.track_ac_availability:
		return "Win: keep AC up · no starvation"
	if not def.fail_on_kinds.is_empty():
		return "Win: no %s stockout" % ", ".join(def.fail_on_kinds)
	return "Win: survive the window"
