extends Control

## Multiplayer lobby — host/join, design share/merge, live sync, chat/Discord,
## Phase 6 hardening (password, code TTL, trusted keys).

const MODAL_NAME := "multiplayer_lobby"

var _built := false
var _name_edit: LineEdit = null
var _port_spin: SpinBox = null
var _code_edit: TextEdit = null
var _join_edit: LineEdit = null
var _status_lbl: Label = null
var _peers_box: VBoxContainer = null
var _lan_box: VBoxContainer = null
var _offers_box: VBoxContainer = null
var _host_btn: Button = null
var _leave_btn: Button = null
var _copy_btn: Button = null
var _share_btn: Button = null
var _live_sync_btn: CheckButton = null
var _preview_lbl: Label = null
var _discord_edit: LineEdit = null
var _host_pw_edit: LineEdit = null
var _join_pw_edit: LineEdit = null
var _friend_key_edit: LineEdit = null
var _trusted_edit: TextEdit = null
var _require_trusted: CheckButton = null
var _ttl_spin: SpinBox = null
var _exp_lbl: Label = null


func open() -> void:
	if not _built:
		_build_ui()
		_built = true
	_sync_from_session()
	MultiplayerSession.start_lan_listen(true)
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	visible = false
	CursorController.release_modal(MODAL_NAME)
	# Keep LAN listen while modal closed only if not in session? Stop to save noise.
	if not MultiplayerSession.is_active():
		MultiplayerSession.start_lan_listen(false)


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if MultiplayerSession == null or not is_instance_valid(MultiplayerSession):
		return
	if not MultiplayerSession.session_changed.is_connected(_sync_from_session):
		MultiplayerSession.session_changed.connect(_sync_from_session)
	if not MultiplayerSession.peer_list_changed.is_connected(_refresh_peers):
		MultiplayerSession.peer_list_changed.connect(_refresh_peers)
	if not MultiplayerSession.lan_hosts_changed.is_connected(_refresh_lan):
		MultiplayerSession.lan_hosts_changed.connect(_refresh_lan)
	if not MultiplayerSession.status_message.is_connected(_on_status):
		MultiplayerSession.status_message.connect(_on_status)
	if MultiplayerSession.design != null:
		var d: Node = MultiplayerSession.design
		if d.has_signal("offer_changed") and not d.offer_changed.is_connected(_refresh_offers):
			d.offer_changed.connect(_refresh_offers)
		if d.has_signal("sync_changed") and not d.sync_changed.is_connected(_sync_from_session):
			d.sync_changed.connect(_sync_from_session)


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 20

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			close())
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 640)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title := Label.new()
	title.text = "Multiplayer (private beta)"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 18)
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.pressed.connect(close)
	title_row.add_child(close_btn)

	var hint := Label.new()
	hint.text = "Private beta · max %d players. Join codes expire. Optional password + trusted keys. Enter to chat; Discord for voice." % MultiplayerSession.MAX_PEERS
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(hint)

	# Display name
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	root.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "Display name"
	name_lbl.custom_minimum_size.x = 110
	name_row.add_child(name_lbl)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.placeholder_text = "Player"
	_name_edit.text_submitted.connect(func(_t: String) -> void:
		MultiplayerSession.set_display_name(_name_edit.text))
	name_row.add_child(_name_edit)
	var name_apply := Button.new()
	name_apply.text = "Set"
	name_apply.pressed.connect(func() -> void:
		MultiplayerSession.set_display_name(_name_edit.text))
	name_row.add_child(name_apply)

	# Discord voice (Phase 5 — out-of-band)
	var discord_row := HBoxContainer.new()
	discord_row.add_theme_constant_override("separation", 8)
	root.add_child(discord_row)
	var discord_lbl := Label.new()
	discord_lbl.text = "Discord"
	discord_lbl.custom_minimum_size.x = 110
	discord_row.add_child(discord_lbl)
	_discord_edit = LineEdit.new()
	_discord_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_discord_edit.placeholder_text = "https://discord.gg/…"
	_discord_edit.text_submitted.connect(func(t: String) -> void:
		MultiplayerSession.set_discord_url(t))
	discord_row.add_child(_discord_edit)
	var discord_save := Button.new()
	discord_save.text = "Save"
	discord_save.pressed.connect(func() -> void:
		MultiplayerSession.set_discord_url(_discord_edit.text)
		_status_lbl.text = "Discord invite saved")
	discord_row.add_child(discord_save)
	var discord_open := Button.new()
	discord_open.text = "Open"
	discord_open.tooltip_text = "Open Discord invite in browser (voice/text fallback)"
	discord_open.pressed.connect(_on_discord_open)
	discord_row.add_child(discord_open)

	# Host row
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 8)
	root.add_child(host_row)
	var port_lbl := Label.new()
	port_lbl.text = "Port"
	host_row.add_child(port_lbl)
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65535
	_port_spin.value = MultiplayerSession.DEFAULT_PORT
	_port_spin.custom_minimum_size.x = 100
	host_row.add_child(_port_spin)
	_host_btn = Button.new()
	_host_btn.text = "Host session"
	_host_btn.pressed.connect(_on_host_pressed)
	host_row.add_child(_host_btn)
	_leave_btn = Button.new()
	_leave_btn.text = "Leave"
	_leave_btn.pressed.connect(func() -> void:
		MultiplayerSession.leave_session())
	host_row.add_child(_leave_btn)

	# Host security (Phase 6)
	var sec_hdr := Label.new()
	sec_hdr.text = "Host security (optional)"
	sec_hdr.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(sec_hdr)
	var pw_row := HBoxContainer.new()
	pw_row.add_theme_constant_override("separation", 8)
	root.add_child(pw_row)
	var pw_lbl := Label.new()
	pw_lbl.text = "Password"
	pw_lbl.custom_minimum_size.x = 110
	pw_row.add_child(pw_lbl)
	_host_pw_edit = LineEdit.new()
	_host_pw_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_pw_edit.secret = true
	_host_pw_edit.placeholder_text = "Optional session password"
	pw_row.add_child(_host_pw_edit)
	var ttl_lbl := Label.new()
	ttl_lbl.text = "Code TTL (h)"
	pw_row.add_child(ttl_lbl)
	_ttl_spin = SpinBox.new()
	_ttl_spin.min_value = 1
	_ttl_spin.max_value = 168
	_ttl_spin.value = 4
	_ttl_spin.custom_minimum_size.x = 80
	pw_row.add_child(_ttl_spin)

	var trusted_lbl := Label.new()
	trusted_lbl.text = "Trusted friend keys (one per line) — when Require is on, joiners must paste a key"
	trusted_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	trusted_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(trusted_lbl)
	_trusted_edit = TextEdit.new()
	_trusted_edit.custom_minimum_size = Vector2(0, 56)
	_trusted_edit.placeholder_text = "abcd-1234"
	root.add_child(_trusted_edit)
	var trusted_row := HBoxContainer.new()
	trusted_row.add_theme_constant_override("separation", 8)
	root.add_child(trusted_row)
	_require_trusted = CheckButton.new()
	_require_trusted.text = "Require trusted key"
	trusted_row.add_child(_require_trusted)
	var mint_btn := Button.new()
	mint_btn.text = "Mint key"
	mint_btn.tooltip_text = "Generate a friend key and copy it"
	mint_btn.pressed.connect(_on_mint_key)
	trusted_row.add_child(mint_btn)
	var apply_sec := Button.new()
	apply_sec.text = "Apply security"
	apply_sec.tooltip_text = "Update password / allowlist / TTL (while hosting refreshes the join code)"
	apply_sec.pressed.connect(_on_apply_security)
	trusted_row.add_child(apply_sec)

	# Join code display
	var code_lbl := Label.new()
	code_lbl.text = "Your join code (share with friends)"
	code_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(code_lbl)
	_code_edit = TextEdit.new()
	_code_edit.custom_minimum_size = Vector2(0, 72)
	_code_edit.editable = false
	_code_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_code_edit.placeholder_text = "Host a session to generate a code…"
	root.add_child(_code_edit)
	_exp_lbl = Label.new()
	_exp_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_exp_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	root.add_child(_exp_lbl)
	var copy_row := HBoxContainer.new()
	root.add_child(copy_row)
	_copy_btn = Button.new()
	_copy_btn.text = "Copy join code"
	_copy_btn.pressed.connect(func() -> void:
		MultiplayerSession.copy_join_code_to_clipboard())
	copy_row.add_child(_copy_btn)
	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh code"
	refresh_btn.tooltip_text = "Remint token + expiry — old codes stop working"
	refresh_btn.pressed.connect(_on_refresh_code)
	copy_row.add_child(refresh_btn)

	# Join
	var join_lbl := Label.new()
	join_lbl.text = "Join with code or ip:port"
	join_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(join_lbl)
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	root.add_child(join_row)
	_join_edit = LineEdit.new()
	_join_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_edit.placeholder_text = "SMB2:… or 192.168.1.10:34197"
	join_row.add_child(_join_edit)
	var join_btn := Button.new()
	join_btn.text = "Join"
	join_btn.pressed.connect(_on_join_pressed)
	join_row.add_child(join_btn)
	var paste_btn := Button.new()
	paste_btn.text = "Paste"
	paste_btn.pressed.connect(func() -> void:
		_join_edit.text = DisplayServer.clipboard_get().strip_edges())
	join_row.add_child(paste_btn)

	var join_cred := HBoxContainer.new()
	join_cred.add_theme_constant_override("separation", 8)
	root.add_child(join_cred)
	var join_pw_lbl := Label.new()
	join_pw_lbl.text = "Join password"
	join_cred.add_child(join_pw_lbl)
	_join_pw_edit = LineEdit.new()
	_join_pw_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_pw_edit.secret = true
	_join_pw_edit.placeholder_text = "If host set one"
	join_cred.add_child(_join_pw_edit)
	var fk_lbl := Label.new()
	fk_lbl.text = "Friend key"
	join_cred.add_child(fk_lbl)
	_friend_key_edit = LineEdit.new()
	_friend_key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friend_key_edit.placeholder_text = "If host requires allowlist"
	join_cred.add_child(_friend_key_edit)

	# Two columns: peers + LAN
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cols)

	var peers_col := VBoxContainer.new()
	peers_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	peers_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(peers_col)
	var peers_hdr := Label.new()
	peers_hdr.text = "In session"
	peers_col.add_child(peers_hdr)
	var peers_scroll := ScrollContainer.new()
	peers_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	peers_scroll.custom_minimum_size.y = 120
	peers_col.add_child(peers_scroll)
	_peers_box = VBoxContainer.new()
	_peers_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	peers_scroll.add_child(_peers_box)

	var lan_col := VBoxContainer.new()
	lan_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(lan_col)
	var lan_hdr := Label.new()
	lan_hdr.text = "LAN hosts"
	lan_col.add_child(lan_hdr)
	var lan_scroll := ScrollContainer.new()
	lan_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lan_scroll.custom_minimum_size.y = 120
	lan_col.add_child(lan_scroll)
	_lan_box = VBoxContainer.new()
	_lan_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_scroll.add_child(_lan_box)

	# Design collaboration
	var design_hdr := Label.new()
	design_hdr.text = "Design collaboration"
	design_hdr.add_theme_font_size_override("font_size", 15)
	root.add_child(design_hdr)

	var design_row := HBoxContainer.new()
	design_row.add_theme_constant_override("separation", 8)
	root.add_child(design_row)
	_share_btn = Button.new()
	_share_btn.text = "Share my .esim"
	_share_btn.tooltip_text = "Push your current site package to everyone in the session as a reviewable offer"
	_share_btn.pressed.connect(_on_share_pressed)
	design_row.add_child(_share_btn)
	_live_sync_btn = CheckButton.new()
	_live_sync_btn.text = "Live sync graph + props"
	_live_sync_btn.tooltip_text = "Host-canonical debounced snapshots of the system graph and placed props"
	_live_sync_btn.toggled.connect(func(on: bool) -> void:
		MultiplayerSession.set_live_design_sync(on))
	design_row.add_child(_live_sync_btn)

	_preview_lbl = Label.new()
	_preview_lbl.text = "No ghost preview"
	_preview_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_preview_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	root.add_child(_preview_lbl)

	var merge_row := HBoxContainer.new()
	merge_row.add_theme_constant_override("separation", 6)
	root.add_child(merge_row)
	var apply_all := Button.new()
	apply_all.text = "Apply all"
	apply_all.pressed.connect(func() -> void:
		MultiplayerSession.apply_design_preview("replace")
		_sync_from_session())
	merge_row.add_child(apply_all)
	var apply_graph := Button.new()
	apply_graph.text = "Apply graph"
	apply_graph.pressed.connect(func() -> void:
		MultiplayerSession.apply_design_preview("graph_only")
		_sync_from_session())
	merge_row.add_child(apply_graph)
	var apply_props := Button.new()
	apply_props.text = "Apply props"
	apply_props.pressed.connect(func() -> void:
		MultiplayerSession.apply_design_preview("props_only")
		_sync_from_session())
	merge_row.add_child(apply_props)
	var discard_btn := Button.new()
	discard_btn.text = "Discard ghost"
	discard_btn.pressed.connect(func() -> void:
		MultiplayerSession.discard_design_preview()
		_sync_from_session())
	merge_row.add_child(discard_btn)

	var offers_hdr := Label.new()
	offers_hdr.text = "Incoming design offers"
	offers_hdr.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(offers_hdr)
	var offers_scroll := ScrollContainer.new()
	offers_scroll.custom_minimum_size.y = 90
	root.add_child(offers_scroll)
	_offers_box = VBoxContainer.new()
	_offers_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	offers_scroll.add_child(_offers_box)

	_status_lbl = Label.new()
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(_status_lbl)


func _sync_from_session() -> void:
	if not _built:
		return
	_name_edit.text = MultiplayerSession.display_name
	_code_edit.text = MultiplayerSession.join_code
	if _discord_edit != null:
		_discord_edit.text = MultiplayerSession.get_discord_url()
	if _require_trusted != null:
		_require_trusted.set_pressed_no_signal(MultiplayerSession.require_trusted)
	if _trusted_edit != null and MultiplayerSession.is_host():
		_trusted_edit.text = "\n".join(MultiplayerSession.trusted_keys)
	if _exp_lbl != null:
		var exp := int(MultiplayerSession.session_expires_unix)
		if MultiplayerSession.is_host() and exp > 0:
			var left := exp - int(Time.get_unix_time_from_system())
			var hrs := maxi(0, left) / 3600.0
			_exp_lbl.text = "Expires in ~%.1fh · password %s · trusted %s" % [
				hrs,
				"ON" if MultiplayerSession.has_host_password() else "off",
				"ON" if MultiplayerSession.require_trusted else "off",
			]
		else:
			_exp_lbl.text = ""
	var active := MultiplayerSession.is_active()
	_host_btn.disabled = active
	_leave_btn.disabled = not active
	_copy_btn.disabled = MultiplayerSession.join_code.is_empty()
	_port_spin.editable = not active
	if active and MultiplayerSession.is_host():
		_status_lbl.text = "Hosting · %s:%d · %s" % [
			MultiplayerSession.host_address,
			MultiplayerSession.host_port,
			MultiplayerSession.status_label(),
		]
	elif active:
		_status_lbl.text = "Connected · %s" % MultiplayerSession.status_label()
	elif MultiplayerSession.is_joining():
		_status_lbl.text = "Loading host map / connecting…"
	_share_btn.disabled = not active
	_live_sync_btn.disabled = not active
	_live_sync_btn.set_pressed_no_signal(MultiplayerSession.is_live_design_sync())
	if MultiplayerSession.design != null and not str(MultiplayerSession.design.get("active_offer_id")).is_empty():
		_preview_lbl.text = "Ghost preview active · %d prop ghosts" % int(
			MultiplayerSession.design.get("ghost_prop_count"))
		_preview_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	else:
		_preview_lbl.text = "No ghost preview"
		_preview_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_refresh_peers()
	_refresh_lan()
	_refresh_offers()


func _refresh_peers() -> void:
	if _peers_box == null:
		return
	for c in _peers_box.get_children():
		c.queue_free()
	if not MultiplayerSession.is_active() and MultiplayerSession.peers.is_empty():
		var empty := Label.new()
		empty.text = "No active session"
		empty.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_peers_box.add_child(empty)
		return
	var ids: Array = MultiplayerSession.peers.keys()
	ids.sort()
	var my_id := multiplayer.get_unique_id() if MultiplayerSession.is_active() else 0
	for id in ids:
		var info: Dictionary = MultiplayerSession.peers[id] as Dictionary
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var tags: PackedStringArray = PackedStringArray()
		if int(id) == 1:
			tags.append("host")
		if int(id) == my_id:
			tags.append("you")
		var tag_s := (" (" + ", ".join(tags) + ")") if not tags.is_empty() else ""
		var lbl := Label.new()
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.text = "%s · peer %d%s" % [str(info.get("name", "Player")), int(id), tag_s]
		row.add_child(lbl)
		if int(id) != my_id and MultiplayerSession.is_active():
			var mute_btn := Button.new()
			var muted := MultiplayerSession.is_peer_muted(int(id))
			mute_btn.text = "Unmute" if muted else "Mute"
			mute_btn.pressed.connect(_on_mute_peer.bind(int(id), not muted))
			row.add_child(mute_btn)
		_peers_box.add_child(row)


func _refresh_lan() -> void:
	if _lan_box == null:
		return
	for c in _lan_box.get_children():
		c.queue_free()
	if MultiplayerSession.lan_hosts.is_empty():
		var empty := Label.new()
		empty.text = "Listening for LAN hosts…"
		empty.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_lan_box.add_child(empty)
		return
	for entry in MultiplayerSession.lan_hosts:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry as Dictionary
		var btn := Button.new()
		btn.text = "%s — %s:%d (%d)" % [
			str(e.get("name", "Session")),
			str(e.get("ip", "")),
			int(e.get("port", 0)),
			int(e.get("peers", 1)),
		]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_on_lan_join.bind(e))
		_lan_box.add_child(btn)


func _on_host_pressed() -> void:
	MultiplayerSession.set_display_name(_name_edit.text)
	var ttl_h := int(_ttl_spin.value) if _ttl_spin != null else 4
	var result: Dictionary = MultiplayerSession.host_session(int(_port_spin.value), "", {
		"password": _host_pw_edit.text if _host_pw_edit != null else "",
		"trusted_keys": _trusted_edit.text if _trusted_edit != null else "",
		"require_trusted": _require_trusted.button_pressed if _require_trusted != null else false,
		"ttl_sec": ttl_h * 3600,
	})
	if not bool(result.get("ok", false)):
		_status_lbl.text = str(result.get("error", "Host failed"))
		return
	_sync_from_session()


func _on_join_pressed() -> void:
	MultiplayerSession.set_display_name(_name_edit.text)
	var code := _join_edit.text.strip_edges()
	if code.is_empty():
		_status_lbl.text = "Paste a join code or ip:port first"
		return
	MultiplayerSession.set_join_credentials(
		_join_pw_edit.text if _join_pw_edit != null else "",
		_friend_key_edit.text if _friend_key_edit != null else "")
	var result: Dictionary = MultiplayerSession.join_with_code(code)
	if not bool(result.get("ok", false)):
		_status_lbl.text = str(result.get("error", "Join failed"))
		return
	_sync_from_session()


func _on_apply_security() -> void:
	var ttl_h := int(_ttl_spin.value) if _ttl_spin != null else 4
	MultiplayerSession.set_host_security(
		_host_pw_edit.text if _host_pw_edit != null else "",
		_trusted_edit.text if _trusted_edit != null else "",
		_require_trusted.button_pressed if _require_trusted != null else false,
		ttl_h * 3600)
	_status_lbl.text = "Security settings applied"
	_sync_from_session()


func _on_mint_key() -> void:
	var key := MultiplayerSession.mint_trusted_key()
	DisplayServer.clipboard_set(key)
	if _trusted_edit != null:
		_trusted_edit.text = "\n".join(MultiplayerSession.trusted_keys)
	if _require_trusted != null:
		_require_trusted.set_pressed_no_signal(true)
	_status_lbl.text = "Minted friend key (copied): %s" % key
	_sync_from_session()


func _on_refresh_code() -> void:
	var result: Dictionary = MultiplayerSession.refresh_join_code()
	if not bool(result.get("ok", false)):
		_status_lbl.text = str(result.get("error", "Refresh failed"))
		return
	_status_lbl.text = "Join code refreshed — share the new code"
	_sync_from_session()


func _on_lan_join(entry: Dictionary) -> void:
	MultiplayerSession.set_display_name(_name_edit.text)
	MultiplayerSession.set_join_credentials(
		_join_pw_edit.text if _join_pw_edit != null else "",
		_friend_key_edit.text if _friend_key_edit != null else "")
	var code := str(entry.get("code", ""))
	var result: Dictionary
	if not code.is_empty():
		result = MultiplayerSession.join_with_code(code)
	else:
		result = MultiplayerSession.join_decoded({
			"ok": true,
			"ip": str(entry.get("ip", "")),
			"port": int(entry.get("port", MultiplayerSession.DEFAULT_PORT)),
			"token": str(entry.get("token", "")),
			"name": str(entry.get("name", "Session")),
			"map": entry.get("map", {}),
			"bare": false,
		})
	if not bool(result.get("ok", false)):
		_status_lbl.text = str(result.get("error", "Join failed"))
		return
	_sync_from_session()


func _refresh_offers() -> void:
	if _offers_box == null:
		return
	for c in _offers_box.get_children():
		c.queue_free()
	var offers: Array = MultiplayerSession.list_design_offers()
	if offers.is_empty():
		var empty := Label.new()
		empty.text = "No offers yet — ask a friend to Share my .esim"
		empty.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_offers_box.add_child(empty)
		return
	for entry in offers:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry as Dictionary
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var summary: Dictionary = e.get("summary", {}) as Dictionary
		var lbl := Label.new()
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.text = "%s · %d nodes · %d props" % [
			str(e.get("from_name", "Peer")),
			int(summary.get("item_count", 0)),
			int(summary.get("prop_count", 0)),
		]
		row.add_child(lbl)
		var tid := str(e.get("id", ""))
		var prev := Button.new()
		prev.text = "Preview"
		prev.disabled = not bool(e.get("ready", false))
		prev.pressed.connect(_on_preview_offer.bind(tid))
		row.add_child(prev)
		var dismiss := Button.new()
		dismiss.text = "✕"
		dismiss.pressed.connect(func() -> void:
			MultiplayerSession.dismiss_design_offer(tid)
			_refresh_offers())
		row.add_child(dismiss)
		_offers_box.add_child(row)


func _on_share_pressed() -> void:
	var result: Dictionary = MultiplayerSession.share_my_design()
	if not bool(result.get("ok", false)):
		_status_lbl.text = str(result.get("error", "Share failed"))
		return
	_status_lbl.text = "Shared design with session"


func _on_preview_offer(transfer_id: String) -> void:
	var result: Dictionary = MultiplayerSession.preview_design_offer(transfer_id)
	if not bool(result.get("ok", false)):
		_status_lbl.text = str(result.get("error", "Preview failed"))
		return
	_sync_from_session()
	_status_lbl.text = "Ghost preview ready — Apply or Discard"


func _on_mute_peer(peer_id: int, muted: bool) -> void:
	MultiplayerSession.mute_peer(peer_id, muted)
	_refresh_peers()
	_status_lbl.text = ("%s muted" if muted else "%s unmuted") % ("Peer %d" % peer_id)


func _on_discord_open() -> void:
	MultiplayerSession.set_discord_url(_discord_edit.text)
	var result: Dictionary = MultiplayerSession.open_discord()
	if not bool(result.get("ok", false)):
		_status_lbl.text = str(result.get("error", "Could not open Discord"))
		return
	_status_lbl.text = "Opened Discord invite"


func _on_status(text: String, _level: String) -> void:
	if _status_lbl != null and visible:
		_status_lbl.text = text
