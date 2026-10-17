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
var _reach_lbl: Label = null
var _reach_retry_btn: Button = null
var _auth_lbl: Label = null
var _auth_btn: Button = null
var _community_edit: LineEdit = null
var _community_link_btn: Button = null
var _directory_lbl: Label = null
var _play_btn: Button = null
var _voice_btn: Button = null
## Set while a Play-together election is resolving, so the button can't be
## double-fired and the label can explain the wait.
var _electing := false
var _require_discord: CheckButton = null
var _allow_offline_discord: CheckButton = null
var _relay_toggle: CheckButton = null
var _relay_lbl: Label = null
var _tabs: TabContainer = null
## Community-builder inputs, keyed by community-file field name.
var _builder_fields: Dictionary = {}
var _builder_lbl: Label = null


func open() -> void:
	if not _built:
		_build_ui()
		_built = true
		_restore_tab()
	# Directory polling is scoped to the lobby being open (or us hosting): the
	# webhook route budget is shared by everyone in the community, so a client
	# that never opens this panel must not spend any of it.
	var dir := _directory()
	if dir != null:
		if str((dir.get("community") as Dictionary).get("guild_id", "")).is_empty():
			dir.call("set_community", SimCommunity.active())
		dir.call("start_polling", true)
	_sync_from_session()
	MultiplayerSession.start_lan_listen(true)
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	visible = false
	CursorController.release_modal(MODAL_NAME)
	var dir := _directory()
	if dir != null:
		dir.call("start_polling", false)
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
	# Sign-in resolves asynchronously (browser round-trip), so the panel has to
	# be told rather than polled.
	var id := _discord_identity()
	if id != null:
		# `unbind(0)` is not valid, so the one-argument signals are wired
		# separately rather than through a clever loop.
		for sig in ["sign_in_started", "signed_out", "token_refreshed"]:
			if id.has_signal(sig):
				id.connect(sig, _on_discord_auth_changed)
		for sig in ["sign_in_completed", "sign_in_failed"]:
			if id.has_signal(sig):
				id.connect(sig, _on_discord_auth_changed.unbind(1))
	var dir := _directory()
	if dir != null:
		dir.connect("directory_changed", _refresh_directory.unbind(1))
		dir.connect("directory_error", _refresh_directory.unbind(1))
		dir.connect("election_result", _on_election_result)
	if MultiplayerSession.design != null:
		var d: Node = MultiplayerSession.design
		if d.has_signal("offer_changed") and not d.offer_changed.is_connected(_refresh_offers):
			d.offer_changed.connect(_refresh_offers)
		if d.has_signal("sync_changed") and not d.sync_changed.is_connected(_sync_from_session):
			d.sync_changed.connect(_sync_from_session)


## One scrollable page inside the TabContainer. Each tab scrolls on its own so
## a long section (Security) cannot push the peers strip off screen.
func _make_tab(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return box


func _save_tab(idx: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SimCommunity.PREFS_PATH)
	cfg.set_value("mp", "lobby_tab", idx)
	cfg.save(SimCommunity.PREFS_PATH)


func _restore_tab() -> void:
	if _tabs == null:
		return
	var cfg := ConfigFile.new()
	if cfg.load(SimCommunity.PREFS_PATH) != OK:
		return
	var idx := int(cfg.get_value("mp", "lobby_tab", 0))
	if idx >= 0 and idx < _tabs.get_tab_count():
		_tabs.current_tab = idx


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

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	# Above the timeline and inside the screen at any size (a 720 x 700 panel
	# centred on the window sat on the timeline at 720p); the tabs scroll.
	UiFit.keep_fitted(panel, Vector2(720, 700))

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
	var close_btn := IconButton.close(close)
	title_row.add_child(close_btn)

	var hint := Label.new()
	hint.text = "Private beta · max %d players. Join codes expire. Optional password + trusted keys. Enter to chat; Discord for voice." % MultiplayerSession.MAX_PEERS
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(hint)

	# The panel had grown to one ~450-line column: every control from
	# "what's my name" to "apply this design merge" stacked in a single scroll.
	# Tabs split it by WHEN you need it — Play is the whole flow for someone who
	# just wants in, and nobody should have to visit another tab to get there.
	#
	# `root` is re-pointed at each section boundary below rather than the
	# sections being rewritten, so this stayed a move rather than a rebuild.
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(func(idx: int) -> void: _save_tab(idx))
	root.add_child(_tabs)
	var play_box := _make_tab("Play")
	var manual_box := _make_tab("Manual")
	var security_box := _make_tab("Security")
	var design_box := _make_tab("Design")
	# Everything after the tabs is the persistent strip: who is here and what
	# just happened matter on every tab.
	var outer := root
	root = play_box

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

	# Discord identity. Signing in is OPTIONAL — everything below still works
	# without it — but it is what lets a host gate joins on Discord server
	# membership instead of hand-managed friend keys.
	var auth_row := HBoxContainer.new()
	auth_row.add_theme_constant_override("separation", 8)
	root.add_child(auth_row)
	var auth_hdr := Label.new()
	auth_hdr.text = "Discord"
	auth_hdr.custom_minimum_size.x = 110
	auth_row.add_child(auth_hdr)
	_auth_lbl = Label.new()
	_auth_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auth_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_auth_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	auth_row.add_child(_auth_lbl)
	_auth_btn = Button.new()
	_auth_btn.text = "Sign in"
	_auth_btn.pressed.connect(_on_discord_auth_pressed)
	auth_row.add_child(_auth_btn)

	# Community file: the one blob a server owner hands their members. It also
	# carries the Discord application id, so importing it is what makes sign-in
	# available at all.
	var comm_row := HBoxContainer.new()
	comm_row.add_theme_constant_override("separation", 8)
	root.add_child(comm_row)
	var comm_lbl := Label.new()
	comm_lbl.text = "Community"
	comm_lbl.custom_minimum_size.x = 110
	comm_row.add_child(comm_lbl)
	_community_edit = LineEdit.new()
	_community_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_community_edit.placeholder_text = "Paste SMBC1:… from your Discord server"
	_community_edit.text_submitted.connect(func(_t: String) -> void: _on_import_community())
	comm_row.add_child(_community_edit)
	var comm_import := Button.new()
	comm_import.text = "Import"
	comm_import.pressed.connect(_on_import_community)
	comm_row.add_child(comm_import)
	_community_link_btn = Button.new()
	_community_link_btn.text = "Open channel"
	_community_link_btn.tooltip_text = "Open the pinned session message in Discord"
	_community_link_btn.pressed.connect(_on_open_directory_link)
	comm_row.add_child(_community_link_btn)

	# THE button. Reads the directory and either joins whoever is live or claims
	# the session — no code to copy, no link to click.
	var play_row := HBoxContainer.new()
	play_row.add_theme_constant_override("separation", 8)
	root.add_child(play_row)
	var play_pad := Label.new()
	play_pad.custom_minimum_size.x = 110
	play_row.add_child(play_pad)
	_directory_lbl = Label.new()
	_directory_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_directory_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_directory_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	play_row.add_child(_directory_lbl)
	_play_btn = Button.new()
	_play_btn.text = "Play together"
	_play_btn.pressed.connect(_on_play_together)
	play_row.add_child(_play_btn)
	_voice_btn = Button.new()
	_voice_btn.text = "🎙 Voice"
	_voice_btn.tooltip_text = "Jump into your community's Discord voice channel"
	_voice_btn.pressed.connect(_on_join_voice)
	play_row.add_child(_voice_btn)

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

	root = manual_box
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

	# Reachability. Without this the host has no way to tell whether anyone
	# outside their LAN can actually connect — the join code looks identical
	# either way, which is exactly how internet play failed silently before.
	var reach_row := HBoxContainer.new()
	reach_row.add_theme_constant_override("separation", 8)
	root.add_child(reach_row)
	_reach_lbl = Label.new()
	_reach_lbl.text = ""
	_reach_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_reach_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reach_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reach_row.add_child(_reach_lbl)
	_reach_retry_btn = Button.new()
	_reach_retry_btn.text = "Retry UPnP"
	_reach_retry_btn.tooltip_text = "Ask the router again for a UDP port mapping"
	_reach_retry_btn.pressed.connect(func() -> void:
		MultiplayerSession.retry_reachability())
	reach_row.add_child(_reach_retry_btn)

	root = security_box
	# Community builder (server owner). Without this the only way to produce a
	# community file is to hand-write JSON, which makes the whole "hand your
	# members one code" flow unusable by the person who has to start it.
	var build_hdr := Label.new()
	build_hdr.text = "Create a community file (server owner)"
	build_hdr.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	root.add_child(build_hdr)
	var build_hint := Label.new()
	build_hint.text = "Turn on Discord Developer Mode to right-click → Copy ID. The webhook URLs are write credentials for those channels — share the finished code only with people you trust."
	build_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	build_hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	build_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	root.add_child(build_hint)
	for spec in [
		["name", "Community name", "My Camp"],
		["client_id", "Discord application ID", "Developer Portal → General Information"],
		["guild_id", "Server ID", "right-click the server → Copy Server ID"],
		["role_ids", "Role IDs (comma separated, blank = any member)", "e.g. Patreon tier role"],
		["voice_channel_id", "Voice channel ID", "right-click the voice channel → Copy Channel ID"],
		["directory_webhook", "Session-status webhook URL", "https://discord.com/api/webhooks/…"],
		["relay_webhook", "Chat-relay webhook URL (optional)", "a DIFFERENT webhook, so either can be revoked"],
		["text_channel_hint", "Chat channel name (cosmetic)", "#sim-lobby"],
	]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		root.add_child(row)
		var lbl := Label.new()
		lbl.text = str(spec[1])
		lbl.custom_minimum_size.x = 250
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		row.add_child(lbl)
		var ed := LineEdit.new()
		ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ed.placeholder_text = str(spec[2])
		row.add_child(ed)
		_builder_fields[str(spec[0])] = ed
	var build_row := HBoxContainer.new()
	build_row.add_theme_constant_override("separation", 8)
	root.add_child(build_row)
	var build_btn := Button.new()
	build_btn.text = "Create & copy code"
	build_btn.pressed.connect(_on_build_community)
	build_row.add_child(build_btn)
	var build_load := Button.new()
	build_load.text = "Load active"
	build_load.tooltip_text = "Fill these fields from the community you already have"
	build_load.pressed.connect(_on_load_community_into_builder)
	build_row.add_child(build_load)
	_builder_lbl = Label.new()
	_builder_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_builder_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_builder_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	build_row.add_child(_builder_lbl)

	# Host security (Phase 6)
	root.add_child(SectionHeader.make("Host security", "", "optional"))
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

	# Discord membership as the gate, instead of hand-managed friend keys.
	var dsc_row := HBoxContainer.new()
	dsc_row.add_theme_constant_override("separation", 8)
	root.add_child(dsc_row)
	_require_discord = CheckButton.new()
	_require_discord.text = "Require Discord membership"
	_require_discord.tooltip_text = "Joiners must be signed in and in your community's Discord server"
	_require_discord.toggled.connect(_on_discord_requirement_toggled)
	dsc_row.add_child(_require_discord)
	_allow_offline_discord = CheckButton.new()
	_allow_offline_discord.text = "…even if Discord is unreachable"
	# Fails CLOSED by default: an unreachable Discord is a runtime failure of a
	# restriction the host asked for, not a reason to drop it.
	_allow_offline_discord.tooltip_text = "Off (recommended): if Discord can't be reached, new joins are refused"
	_allow_offline_discord.toggled.connect(_on_discord_requirement_toggled)
	dsc_row.add_child(_allow_offline_discord)

	var relay_row := HBoxContainer.new()
	relay_row.add_theme_constant_override("separation", 8)
	root.add_child(relay_row)
	_relay_toggle = CheckButton.new()
	_relay_toggle.text = "Mirror chat to Discord"
	_relay_toggle.tooltip_text = "Host only. Copies in-game chat into your community's text channel — everyone in the session is told."
	_relay_toggle.toggled.connect(_on_relay_toggled)
	relay_row.add_child(_relay_toggle)
	_relay_lbl = Label.new()
	_relay_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_relay_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_relay_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	relay_row.add_child(_relay_lbl)

	root = manual_box
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

	root = outer
	# Two columns: peers + LAN
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cols)

	var peers_col := VBoxContainer.new()
	peers_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	peers_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(peers_col)
	peers_col.add_child(SectionHeader.make("In session"))
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
	lan_col.add_child(SectionHeader.make("LAN hosts"))
	var lan_scroll := ScrollContainer.new()
	lan_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lan_scroll.custom_minimum_size.y = 120
	lan_col.add_child(lan_scroll)
	_lan_box = VBoxContainer.new()
	_lan_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_scroll.add_child(_lan_box)

	root = design_box
	# Design collaboration
	root.add_child(SectionHeader.make("Design collaboration"))

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

	root.add_child(SectionHeader.make("Incoming design offers"))
	var offers_scroll := ScrollContainer.new()
	offers_scroll.custom_minimum_size.y = 90
	root.add_child(offers_scroll)
	_offers_box = VBoxContainer.new()
	_offers_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	offers_scroll.add_child(_offers_box)

	root = outer
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
	if _require_discord != null:
		_require_discord.set_pressed_no_signal(MultiplayerSession.require_discord)
		_allow_offline_discord.set_pressed_no_signal(
			MultiplayerSession.allow_when_discord_unreachable)
		_allow_offline_discord.disabled = not MultiplayerSession.require_discord
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
	_refresh_discord_auth()
	_refresh_directory()
	_refresh_relay()
	if _reach_lbl != null:
		var reach := MultiplayerSession.reachability_text()
		_reach_lbl.text = reach
		_reach_lbl.visible = not reach.is_empty()
		_reach_retry_btn.visible = MultiplayerSession.is_host()
		# Anything that mentions a VPN means inbound play cannot work as-is —
		# colour it as a warning rather than letting it read as status noise.
		_reach_lbl.add_theme_color_override("font_color",
			UITheme.C_WARN if reach.contains("Tailscale") else UITheme.C_TEXT_M)
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
		_preview_lbl.text = "Ghost preview active · %s" % UiText.count(int(
			MultiplayerSession.design.get("ghost_prop_count")), "prop ghost")
		_preview_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	else:
		_preview_lbl.text = "No ghost preview"
		_preview_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_refresh_peers()
	_refresh_lan()
	_refresh_offers()


func _discord_identity() -> Node:
	return get_node_or_null("/root/DiscordIdentity")


func _directory() -> Node:
	return get_node_or_null("/root/DiscordDirectory")


# ── Community + directory ────────────────────────────────────────────────────

func _on_import_community() -> void:
	var text := _community_edit.text.strip_edges()
	if text.is_empty():
		_status_lbl.text = "Paste the SMBC1: code your server owner shared"
		return
	var decoded: Dictionary = SimCommunity.decode(text)
	if not bool(decoded.get("ok", false)):
		_status_lbl.text = str(decoded.get("error", "Could not read that community code"))
		return
	var saved: Dictionary = SimCommunity.save_to_disk(decoded["community"] as Dictionary)
	if not bool(saved.get("ok", false)):
		_status_lbl.text = str(saved.get("error", "Could not save the community"))
		return
	var community: Dictionary = saved["community"]
	SimCommunity.set_active(community)
	_apply_community(community)
	_community_edit.text = ""
	var name := str(community.get("name", "your community"))
	var warns: PackedStringArray = SimCommunity.warnings(community)
	_status_lbl.text = "Imported %s%s" % [name,
		"" if warns.is_empty() else " · " + str(warns[0])]
	_sync_from_session()


## Push the active community into every consumer at once.
func _apply_community(community: Dictionary) -> void:
	var dir := _directory()
	if dir != null:
		dir.call("set_community", community)
		dir.call("start_polling", visible)
	if MultiplayerSession.discord_relay != null:
		MultiplayerSession.discord_relay.call("set_community", community)
	# A host that has imported a community can gate joins on server membership
	# instead of hand-managed friend keys. Off until the host opts in on the
	# security row — importing a file must not silently change who can join.
	MultiplayerSession.set_discord_requirement(community,
		MultiplayerSession.require_discord)


func _on_open_directory_link() -> void:
	var dir := _directory()
	if dir == null:
		return
	var link := str(dir.call("permanent_link"))
	if link.is_empty():
		_status_lbl.text = "No session message yet — press Play together once to create it"
		return
	OS.shell_open(link)


func _on_join_voice() -> void:
	var community: Dictionary = SimCommunity.active()
	var deep := DiscordLinks.voice_deep_link(
		str(community.get("guild_id", "")), str(community.get("voice_channel_id", "")))
	if deep.is_empty():
		# Fall back to the plain invite URL the lobby has always had.
		var res: Dictionary = MultiplayerSession.open_discord()
		_status_lbl.text = "Opening Discord…" if bool(res.get("ok", false)) \
			else str(res.get("error", "No Discord voice channel configured"))
		return
	OS.shell_open(deep)
	# ShellExecute reports success on Windows even when nothing handles
	# discord://, so failure is not reliably detectable — offer the web link
	# rather than guessing.
	_status_lbl.text = "Opening Discord voice… (didn't open? use the invite link)"


func _on_play_together() -> void:
	var dir := _directory()
	if dir == null:
		return
	if MultiplayerSession.is_active():
		_status_lbl.text = "Already in a session — leave first"
		return
	if not bool(dir.call("is_configured")):
		_status_lbl.text = "Import your community's SMBC1: code first"
		return
	_electing = true
	_status_lbl.text = "Checking who's playing…"
	_refresh_directory()
	dir.call("play_together")


func _on_election_result(won: bool, record: Dictionary) -> void:
	_electing = false
	var dir := _directory()
	if won:
		var res: Dictionary = MultiplayerSession.host_session(
			int(_port_spin.value), str(SimCommunity.active().get("name", "")))
		if not bool(res.get("ok", false)):
			_status_lbl.text = str(res.get("error", "Could not start hosting"))
			if dir != null:
				dir.call("vacate")
			return
		# Publish only now that the ENet server is really up, so the advertised
		# address is real rather than predicted.
		if dir != null:
			dir.call("publish_hosting", str(res.get("join_code", "")),
				MultiplayerSession.collect_map_info(), MultiplayerSession.peer_count())
		_status_lbl.text = "You're hosting — everyone else can now press Play together"
		_sync_from_session()
		return

	var host: Dictionary = record.get("host", {}) as Dictionary
	var code := str(host.get("code", ""))
	if code.is_empty():
		_status_lbl.text = str(dir.call("status_text")) if dir != null else "Nobody is hosting"
		return
	var decoded: Dictionary = MpJoinCode.decode(code)
	if not bool(decoded.get("ok", false)):
		_status_lbl.text = "The host's session code is stale — ask them to press Play together again"
		return
	# Prompt for sign-in BEFORE connecting rather than letting the peer connect
	# and be kicked with a confusing message.
	if not MultiplayerSession.can_satisfy_discord(decoded):
		_status_lbl.text = "%s's session needs a Discord sign-in — sign in above, then Play together" % \
			str(host.get("name", "That"))
		return
	var res2: Dictionary = MultiplayerSession.join_decoded(decoded)
	_status_lbl.text = "Joining %s…" % str(host.get("name", "the session")) \
		if bool(res2.get("ok", false)) else str(res2.get("error", "Could not join"))
	_sync_from_session()


func _on_discord_requirement_toggled(_pressed: bool) -> void:
	var community: Dictionary = SimCommunity.active()
	if _require_discord.button_pressed and community.is_empty():
		_require_discord.set_pressed_no_signal(false)
		_status_lbl.text = "Import your community's SMBC1: code first"
		return
	MultiplayerSession.set_discord_requirement(community,
		_require_discord.button_pressed, _allow_offline_discord.button_pressed)
	_status_lbl.text = "Discord membership %s" % (
		"required to join" if MultiplayerSession.require_discord else "not required")
	_sync_from_session()


func _on_build_community() -> void:
	var fields := {}
	for key in _builder_fields:
		fields[key] = (_builder_fields[key] as LineEdit).text.strip_edges()
	var roles: Array = []
	for r in str(fields.get("role_ids", "")).replace(" ", "").split(",", false):
		roles.append(str(r))
	fields["role_ids"] = roles
	fields["issued_at"] = int(Time.get_unix_time_from_system())
	var built: Dictionary = SimCommunity.encode(SimCommunity.make(fields))
	if not bool(built.get("ok", false)):
		# validate() is the security boundary, so its refusal is the message —
		# it names the offending field rather than saying "invalid".
		_builder_lbl.text = str(built.get("error", "Could not build the community file"))
		_builder_lbl.add_theme_color_override("font_color", UITheme.C_ERROR)
		return
	var code := str(built["code"])
	DisplayServer.clipboard_set(code)
	# Also drop it in the visible field: a clipboard write can fail silently
	# (headless, some Linux setups) and the owner would have nothing to paste.
	if _community_edit != null:
		_community_edit.text = code
	var community: Dictionary = built["community"]
	SimCommunity.save_to_disk(community)
	SimCommunity.set_active(community)
	_apply_community(community)
	var warns: PackedStringArray = SimCommunity.warnings(community)
	_builder_lbl.text = "Copied to clipboard — paste it in your Discord server.%s" % (
		"" if warns.is_empty() else "\n" + "\n".join(warns))
	_builder_lbl.add_theme_color_override("font_color",
		UITheme.C_WARN if not warns.is_empty() else UITheme.C_OK)
	_sync_from_session()


func _on_load_community_into_builder() -> void:
	var community: Dictionary = SimCommunity.active()
	if community.is_empty():
		_builder_lbl.text = "No community imported yet."
		return
	for key in _builder_fields:
		var value: Variant = community.get(key, "")
		if value is Array:
			value = ", ".join(PackedStringArray(value))
		(_builder_fields[key] as LineEdit).text = str(value)
	_builder_lbl.text = "Loaded %s — edit and re-create to publish an update." % \
		str(community.get("name", "your community"))
	_builder_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)


func _on_relay_toggled(pressed: bool) -> void:
	var relay: Node = MultiplayerSession.discord_relay
	if relay == null:
		return
	var res: Dictionary = relay.call("set_enabled", pressed)
	if not bool(res.get("ok", false)):
		_relay_toggle.set_pressed_no_signal(false)
		_status_lbl.text = str(res.get("error", "Could not start the chat relay"))
	_refresh_relay()


func _refresh_relay() -> void:
	if _relay_toggle == null:
		return
	var relay: Node = MultiplayerSession.discord_relay
	if relay == null:
		_relay_toggle.disabled = true
		return
	_relay_toggle.set_pressed_no_signal(bool(relay.get("enabled")))
	_relay_toggle.disabled = not (bool(relay.call("is_configured")) and MultiplayerSession.is_host())
	_relay_lbl.text = str(relay.call("status_text"))
	_relay_lbl.add_theme_color_override("font_color",
		UITheme.C_WARN if bool(relay.get("enabled")) else UITheme.C_TEXT_M)


func _refresh_directory() -> void:
	if _directory_lbl == null:
		return
	var dir := _directory()
	if dir == null:
		_directory_lbl.text = ""
		return
	var configured := bool(dir.call("is_configured"))
	_directory_lbl.text = "Resolving who hosts…" if _electing else str(dir.call("status_text"))
	_play_btn.disabled = _electing or not configured or MultiplayerSession.is_active()
	_community_link_btn.disabled = str(dir.call("permanent_link")).is_empty()
	# Voice needs either a configured community channel or the older free-text
	# invite URL; with neither there is nowhere to send the player.
	var community: Dictionary = SimCommunity.active()
	var has_channel := not DiscordLinks.voice_deep_link(
		str(community.get("guild_id", "")), str(community.get("voice_channel_id", ""))).is_empty()
	var has_invite := not MultiplayerSession.get_discord_url().strip_edges().is_empty()
	_voice_btn.disabled = not (has_channel or has_invite)
	_directory_lbl.add_theme_color_override("font_color",
		UITheme.C_WARN if not str(dir.get("last_error")).is_empty() else UITheme.C_TEXT_M)


func _on_discord_auth_changed() -> void:
	_refresh_discord_auth()
	var id := _discord_identity()
	if id != null and bool(id.call("is_signed_in")) and _name_edit != null \
			and str(id.call("display_name")) != "":
		# Your Discord name is who everyone in the community already knows you
		# as, so adopt it rather than making people retype it.
		var n := str(id.call("display_name"))
		MultiplayerSession.set_display_name(n)
		_name_edit.text = n


func _refresh_discord_auth() -> void:
	if _auth_lbl == null:
		return
	var id := _discord_identity()
	if id == null:
		_auth_lbl.text = "Discord sign-in unavailable in this build"
		_auth_btn.disabled = true
		return
	_auth_lbl.text = str(id.call("status_text"))
	var signing := bool(id.call("is_signing_in"))
	var signed := bool(id.call("is_signed_in"))
	_auth_btn.disabled = signing or (not signed and not bool(id.call("is_available", {})))
	_auth_btn.text = "Signing in…" if signing else ("Sign out" if signed else "Sign in")
	if not signed and not bool(id.call("is_available", {})):
		# Be specific: the button being dead is otherwise unexplainable.
		_auth_btn.tooltip_text = "Import a community file first — it carries the Discord application id"
	else:
		_auth_btn.tooltip_text = "Sign in with Discord so hosts can verify your server membership"
	_auth_lbl.add_theme_color_override("font_color",
		UITheme.C_OK if signed else UITheme.C_TEXT_M)


func _on_discord_auth_pressed() -> void:
	var id := _discord_identity()
	if id == null:
		return
	if bool(id.call("is_signed_in")):
		id.call("sign_out")
		_status_lbl.text = "Signed out locally — revoke access in Discord's settings to fully remove it"
		_refresh_discord_auth()
		return
	var res: Dictionary = id.call("begin_sign_in", {})
	if bool(res.get("ok", false)):
		_status_lbl.text = "Finish signing in in your browser…"
	else:
		_status_lbl.text = str(res.get("error", "Could not start Discord sign-in"))
	_refresh_discord_auth()


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
		lbl.text = "%s · %s · %s" % [
			str(e.get("from_name", "Peer")),
			UiText.count(int(summary.get("item_count", 0)), "node"),
			UiText.count(int(summary.get("prop_count", 0)), "prop"),
		]
		row.add_child(lbl)
		var tid := str(e.get("id", ""))
		var prev := Button.new()
		prev.text = "Preview"
		prev.disabled = not bool(e.get("ready", false))
		prev.pressed.connect(_on_preview_offer.bind(tid))
		row.add_child(prev)
		var dismiss := Button.new()
		IconButton.style(dismiss, "x", "Dismiss this design offer")
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
