extends Control

## What multiplayer is doing, on screen, while you play:
## - the SYNC LINE (top centre): "Waiting for Sam to approve your change",
##   "Sam accepted your change · Moved Shiftpod 12 m", "Getting the host's
##   world… 40 %" — every state a change goes through, so nothing happens
##   silently (the old sync gave no sign at all for 5–12 s);
## - for the HOST, the REVIEW CARDS (top right): each guest change in plain
##   words, its ghosts in the world, Accept / Decline / Show / Always accept,
##   and Alt+Y / Alt+N to take the oldest without freeing the cursor;
## - EDGE ARROWS for other players who are off screen or behind you, with
##   their name and distance (their x-ray name tag covers the on-screen case).
##
## Pure presentation: every decision is MultiplayerSession.design's.

const HUD_SYNC := "mp_sync"
const HUD_REVIEW := "mp_review"
const REVIEW_W := 360.0
const MAX_CARDS := 4
const EDGE_MARGIN := 46.0

var _sync_chip: PanelContainer = null
var _sync_icon: TextureRect = null
var _sync_text: Label = null
var _sync_detail: Label = null
var _sync_bar: ProgressBar = null
var _review_panel: PanelContainer = null
var _review_box: VBoxContainer = null
var _review_sig := "\u0001"
var _built := false
var _spin := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	set_process_unhandled_input(true)
	if MultiplayerSession == null:
		return
	MultiplayerSession.session_changed.connect(_on_session_changed)
	var d: Node = MultiplayerSession.design
	if d != null:
		if d.has_signal("review_changed"):
			d.review_changed.connect(_rebuild_review)
		if d.has_signal("activity_changed"):
			d.activity_changed.connect(_refresh_sync)
	_on_session_changed()


func _on_session_changed() -> void:
	var active := MultiplayerSession != null and MultiplayerSession.is_active()
	if active and not _built:
		_build()
	visible = active
	if _built:
		_refresh_sync()
		_rebuild_review()


func _build() -> void:
	_built = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_sync_chip = PanelContainer.new()
	_sync_chip.name = "MpSyncChip"
	_sync_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# chip_style is a 16 % tint — over bright foliage the detail line washed out.
	var chip_sb := UITheme.chip_style(UITheme.C_PRIMARY)
	chip_sb.bg_color = Color(UITheme.C_BG, 0.9)
	_sync_chip.add_theme_stylebox_override("panel", chip_sb)
	_sync_chip.visible = false
	add_child(_sync_chip)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sync_chip.add_child(row)
	_sync_icon = TextureRect.new()
	_sync_icon.texture = UiIcons.icon("refresh-cw", 16)
	_sync_icon.custom_minimum_size = Vector2(16, 16)
	# The icon texture is drawn at a higher resolution than 16 px; without
	# IGNORE_SIZE it spilled over the first letters of the line.
	_sync_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sync_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_sync_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_sync_icon.pivot_offset = Vector2(8, 8)
	_sync_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_sync_icon)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	_sync_text = Label.new()
	_sync_text.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	col.add_child(_sync_text)
	_sync_detail = Label.new()
	_sync_detail.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_sync_detail.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	col.add_child(_sync_detail)
	_sync_bar = ProgressBar.new()
	_sync_bar.custom_minimum_size = Vector2(160, 4)
	_sync_bar.show_percentage = false
	_sync_bar.max_value = 1.0
	UITheme.style_progress(_sync_bar)
	col.add_child(_sync_bar)
	HudLayout.register(_sync_chip, HUD_SYNC, "top_center", {"order": 3, "tuckable": false,
		"size": func() -> Vector2: return _sync_chip.get_combined_minimum_size()})

	_review_panel = PanelContainer.new()
	_review_panel.name = "MpReviewPanel"
	_review_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.94))
	_review_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_review_panel.visible = false
	add_child(_review_panel)
	_review_box = VBoxContainer.new()
	_review_box.add_theme_constant_override("separation", 6)
	_review_panel.add_child(_review_box)
	# First in the right column: a decision somebody is waiting on goes above
	# the always-there panels.
	HudLayout.register(_review_panel, HUD_REVIEW, "top_right", {"order": -10, "priority": 9,
		"tuckable": false,
		"size": func() -> Vector2:
			return Vector2(REVIEW_W, _review_panel.get_combined_minimum_size().y)})


func _design() -> Node:
	return MultiplayerSession.design if MultiplayerSession != null else null


# ── sync line ────────────────────────────────────────────────────────────────

func _refresh_sync() -> void:
	if not _built:
		return
	var d := _design()
	var a: Dictionary = d.call("activity_now") if d != null else {}
	if a.is_empty():
		_sync_chip.visible = false
		return
	var tone := str(a.get("tone", "info"))
	var col := UITheme.C_INFO
	var icon := "refresh-cw"
	match tone:
		"ok":
			col = UITheme.C_OK
			icon = "check"
		"warn":
			col = UITheme.C_WARN
			icon = "x"
		"busy":
			col = UITheme.C_PRIMARY
	_sync_icon.texture = UiIcons.icon(icon, 16)
	_sync_icon.modulate = col
	_sync_icon.rotation = 0.0
	_sync_text.text = str(a.get("text", ""))
	_sync_text.add_theme_color_override("font_color", col.lerp(UITheme.C_TEXT, 0.35))
	var detail := str(a.get("detail", ""))
	_sync_detail.text = UiText.fit(UITheme.font("regular"), detail, UITheme.FONT_XS, 520.0, "mp_sync")
	_sync_detail.visible = not detail.is_empty()
	var prog := float(a.get("progress", -1.0))
	_sync_bar.visible = prog >= 0.0
	if prog >= 0.0:
		_sync_bar.value = prog
	_sync_chip.visible = true


func _process(delta: float) -> void:
	if not _built or not visible:
		return
	# The line expires on its own (activity_now() reads the clock).
	if _sync_chip.visible:
		var d := _design()
		var a: Dictionary = d.call("activity_now") if d != null else {}
		if a.is_empty():
			_sync_chip.visible = false
		elif str(a.get("tone", "")) == "busy":
			_spin += delta * 5.0
			_sync_icon.rotation = _spin
	else:
		var d2 := _design()
		if d2 != null and not (d2.call("activity_now") as Dictionary).is_empty():
			_refresh_sync()
	queue_redraw()


# ── review cards (host) ─────────────────────────────────────────────────────

func _rebuild_review() -> void:
	if not _built:
		return
	var d := _design()
	var host := MultiplayerSession.is_host()
	var review: Array = d.get("review") if d != null and host else []
	var sig := ""
	for e in review:
		sig += str((e as Dictionary).get("pid", "")) + ","
	sig += str(d.get("auto_peers").size() if d != null else 0)
	if sig == _review_sig:
		_review_panel.visible = not review.is_empty()
		return
	_review_sig = sig
	for c in _review_box.get_children():
		_review_box.remove_child(c)
		c.queue_free()
	if review.is_empty():
		_review_panel.visible = false
		return
	var head := HBoxContainer.new()
	_review_box.add_child(head)
	var title := Label.new()
	title.text = "Changes waiting for you (%d)" % review.size()
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var hint := Label.new()
	hint.text = "Alt+Y accept · Alt+N decline the oldest · Esc frees the cursor to click"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_review_box.add_child(hint)
	for i in mini(review.size(), MAX_CARDS):
		_review_box.add_child(_make_card(review[i] as Dictionary))
	if review.size() > MAX_CARDS:
		var more := Label.new()
		more.text = "… and %s" % UiText.count(review.size() - MAX_CARDS, "more change")
		more.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_review_box.add_child(more)
	if review.size() > 1:
		var all_row := HBoxContainer.new()
		all_row.add_theme_constant_override("separation", 6)
		_review_box.add_child(all_row)
		var acc_all := _btn("Accept all", func() -> void: d.call("accept_all"))
		all_row.add_child(acc_all)
		var rej_all := _btn("Decline all", func() -> void: d.call("reject_all"))
		all_row.add_child(rej_all)
	_review_panel.visible = true


func _make_card(e: Dictionary) -> Control:
	var d := _design()
	var pid := str(e.get("pid", ""))
	var peer := int(e.get("peer", 0))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	card.add_child(v)
	var who := Label.new()
	var age := (Time.get_ticks_msec() - int(e.get("ms", 0))) / 1000.0
	who.text = "%s%s" % [str(e.get("name", "A guest")),
		"" if age < 5.0 else "  ·  %s ago" % UiText.duration(age / 3600.0)]
	who.add_theme_color_override("font_color", RemotePlayerAvatar.color_for_peer(peer).lightened(0.2))
	who.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	v.add_child(who)
	var lines: Array = e.get("lines", []) as Array
	for i in mini(lines.size(), 3):
		var l := Label.new()
		l.text = "• " + str(lines[i])
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(l)
	if lines.size() > 3:
		var more := Label.new()
		more.text = "• … and %s" % UiText.count(lines.size() - 3, "more")
		more.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		v.add_child(more)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	var acc := _btn("Accept", func() -> void: d.call("accept_proposal", pid))
	acc.add_theme_color_override("font_color", UITheme.C_OK)
	row.add_child(acc)
	row.add_child(_btn("Decline", func() -> void: d.call("reject_proposal", pid, "")))
	var at: Vector3 = d.call("proposal_focus_point", pid)
	if at != Vector3.INF:
		row.add_child(_btn("Look", func() -> void: _look_at(at)))
	var always := _btn("Always accept", func() -> void: d.call("set_auto_accept_peer", peer, true))
	always.tooltip_text = "Accept this player's changes from now on without asking"
	row.add_child(always)
	return card


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	b.pressed.connect(cb)
	return b


## Turn the player toward a proposed change (yaw only — no teleport).
func _look_at(at: Vector3) -> void:
	var main := get_tree().current_scene
	var player := main.get_node_or_null("Player") as Node3D if main != null else null
	if player == null:
		return
	var to := at - player.global_position
	player.rotation.y = atan2(-to.x, -to.z)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not MultiplayerSession.is_host():
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := event as InputEventKey
	if not k.alt_pressed or k.ctrl_pressed:
		return
	if k.keycode != KEY_Y and k.keycode != KEY_N:
		return
	var d := _design()
	var review: Array = d.get("review") if d != null else []
	if review.is_empty():
		return
	var pid := str((review[0] as Dictionary).get("pid", ""))
	if k.keycode == KEY_Y:
		d.call("accept_proposal", pid)
	else:
		d.call("reject_proposal", pid, "")
	get_viewport().set_input_as_handled()


# ── edge arrows ─────────────────────────────────────────────────────────────

func _draw() -> void:
	if MultiplayerSession == null or not MultiplayerSession.is_active():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var vp := get_viewport_rect().size
	var centre := vp * 0.5
	var inner := Rect2(Vector2(EDGE_MARGIN, EDGE_MARGIN), vp - Vector2(EDGE_MARGIN, EDGE_MARGIN) * 2.0)
	inner.size.y -= HudLayout.timeline_height()
	var font := UITheme.font("medium")
	for av in MultiplayerSession.remote_avatars():
		var a := av as RemotePlayerAvatar
		var head := a.global_position + Vector3(0.0, RemotePlayerAvatar.BODY_HEIGHT_M, 0.0)
		# Camera space first: unproject_position errors for a point on (or
		# just in front of) the camera plane, and a player standing beside
		# you is exactly that.
		var local := cam.global_transform.affine_inverse() * head
		var in_front := -local.z > maxf(cam.near, 0.05) * 2.0
		var dir := Vector2(local.x, -local.y)
		if in_front:
			var sp := cam.unproject_position(head)
			if inner.has_point(sp):
				continue   # on screen: its own name tag says who it is
			dir = sp - centre
		if dir.length() < 1.0:
			dir = Vector2(0, 1)
		dir = dir.normalized()
		# Where the ray from the centre leaves the inner rect.
		var half := inner.size * 0.5
		var tx := half.x / maxf(absf(dir.x), 1e-4)
		var ty := half.y / maxf(absf(dir.y), 1e-4)
		var p := inner.get_center() + dir * minf(tx, ty)
		var col := a.rim
		var tip := p + dir * 14.0
		var side := Vector2(-dir.y, dir.x) * 9.0
		draw_colored_polygon(PackedVector2Array([tip, p - dir * 4.0 + side, p - dir * 4.0 - side]), col)
		var dist := cam.global_position.distance_to(a.global_position)
		var label := "%s · %s" % [a.display_name, UiText.num(dist, "m", 2)]
		if font != null:
			var sz := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS)
			var lp := p - dir * 18.0 - Vector2(sz.x * 0.5, -sz.y * 0.3)
			lp.x = clampf(lp.x, 4.0, vp.x - sz.x - 4.0)
			lp.y = clampf(lp.y, 14.0, vp.y - 4.0)
			draw_string_outline(font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, 4,
				Color(0, 0, 0, 0.85))
			draw_string(font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, col.lightened(0.3))
