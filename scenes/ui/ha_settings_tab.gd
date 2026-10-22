extends VBoxContainer

## Settings → Home Assistant. Built into its page by
## timeline_settings_panel._build_ha_tab, and offered at the launch hub too:
## the HomeAssistant autoload is up there, so a connection can be tested
## before any world loads.
##
## Pick or add a saved instance, type the address the way a browser shows it,
## paste a token, press Connect. The status card then shows each step as it
## happens, and a failure says what went wrong, with a button that fixes the
## common mistakes ("Home Assistant answers at … — use this address").

const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const C_TEXT_M := UITheme.C_TEXT_M
const ROW_LABEL_W := 120
const ADD_NEW_LABEL := "+ Add an instance…"
const TOKEN_HELP := "In Home Assistant: click your name (bottom left) → Security → Long-lived access tokens → Create token. Copy it right away; Home Assistant shows it only once."

var _panel: Control = null
var _editing_id: String = ""
var _syncing := false

var _profile_opt: OptionButton = null
var _profile_ids: Array = []
var _delete_btn: Button = null
var _default_btn: Button = null
var _name_ed: LineEdit = null
var _url_ed: LineEdit = null
var _url_preview: Label = null
var _token_ed: LineEdit = null
var _token_note: Label = null
var _connect_btn: Button = null
var _disconnect_btn: Button = null
var _auto_chk: CheckBox = null
var _world_row: Control = null
var _world_opt: OptionButton = null
var _world_ids: Array = []

var _banner: AlertBanner = null
var _steps: Array = []          # 4 Labels
var _detail_lbl: Label = null
var _fix_row: HBoxContainer = null
var _links_box: VBoxContainer = null
var _links_lbl: Label = null
var _live_row: HBoxContainer = null
var _tick := 0.0


func bind(panel: Control) -> void:
	_panel = panel


func _svc() -> Node:
	return get_node_or_null("/root/HomeAssistant")


func _ready() -> void:
	add_theme_constant_override("separation", 8)
	_build()
	var s := _svc()
	if s != null:
		s.state_changed.connect(_on_state_changed)
		s.profiles_changed.connect(_on_profiles_changed)
		s.catalog_updated.connect(_refresh_status)
	refresh()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_tick += delta
	if _tick >= 0.5:
		_tick = 0.0
		_refresh_status()   # the "retrying in Ns" countdown


func refresh() -> void:
	_load_profile_list()
	_select_profile(_initial_profile_id())
	_refresh_world_row()
	_refresh_status()


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build() -> void:
	add_child(SectionHeader.make("Home Assistant instance", "house"))

	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 6)
	add_child(prow)
	_profile_opt = OptionButton.new()
	_profile_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_profile_opt.fit_to_longest_item = false
	_profile_opt.tooltip_text = "Saved Home Assistant instances. Each keeps its own address and token."
	_profile_opt.item_selected.connect(_on_profile_picked)
	prow.add_child(_profile_opt)
	_default_btn = Button.new()
	_default_btn.text = "Make default"
	_default_btn.tooltip_text = "Worlds that have not chosen an instance use the default one."
	UITheme.style_button(_default_btn)
	_default_btn.pressed.connect(_on_make_default)
	prow.add_child(_default_btn)
	_delete_btn = IconButton.make("trash-2", "Forget this instance (its address and token)", _on_delete)
	prow.add_child(_delete_btn)

	_name_ed = _line_row("Name", "Home, the bus, the shop…", false)
	_url_ed = _line_row("Address", "192.168.1.10:8123  or  http://homeassistant.local:8123", false)
	_url_ed.text_changed.connect(func(_t: String) -> void: _update_url_preview())
	_url_ed.text_submitted.connect(func(_t: String) -> void: _on_connect())
	_url_preview = _note("")
	_token_ed = _line_row("Access token", "Paste a long-lived access token", true)
	_token_ed.text_changed.connect(func(_t: String) -> void: _update_token_note())
	_token_ed.text_submitted.connect(func(_t: String) -> void: _on_connect())
	_token_note = _note("")
	_note(TOKEN_HELP)
	_note("Saved only on this computer (user://ha_profiles.cfg). Never put in a world, a shared pack or git.")

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 8)
	add_child(brow)
	_connect_btn = Button.new()
	_connect_btn.text = "Connect"
	_connect_btn.tooltip_text = "Save this instance and connect (Enter in either field does the same)."
	UITheme.style_button(_connect_btn)
	_connect_btn.pressed.connect(_on_connect)
	brow.add_child(_connect_btn)
	_disconnect_btn = Button.new()
	_disconnect_btn.text = "Disconnect"
	UITheme.style_button(_disconnect_btn)
	_disconnect_btn.pressed.connect(func() -> void:
		var s := _svc()
		if s != null:
			s.call("disconnect_ha"))
	brow.add_child(_disconnect_btn)
	_auto_chk = CheckBox.new()
	_auto_chk.text = "Connect automatically when a world loads"
	_auto_chk.tooltip_text = "Only an instance that has connected before is connected automatically."
	_auto_chk.toggled.connect(func(on: bool) -> void:
		var s := _svc()
		if s != null and not _syncing:
			s.call("set_auto_connect", on))
	brow.add_child(_auto_chk)

	var wrow := HBoxContainer.new()
	wrow.add_theme_constant_override("separation", 6)
	add_child(wrow)
	_world_row = wrow
	var wl := Label.new()
	wl.text = "This world uses"
	wl.custom_minimum_size.x = ROW_LABEL_W
	wl.add_theme_color_override("font_color", C_TEXT_S)
	wl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	wrow.add_child(wl)
	_world_opt = OptionButton.new()
	_world_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_world_opt.fit_to_longest_item = false
	_world_opt.tooltip_text = "Which saved instance this world connects to. Links are saved with the world."
	_world_opt.item_selected.connect(_on_world_profile_picked)
	wrow.add_child(_world_opt)

	add_child(SectionHeader.make("Status", "gauge"))
	_banner = AlertBanner.new()
	add_child(_banner)
	var steps_box := VBoxContainer.new()
	steps_box.add_theme_constant_override("separation", 2)
	add_child(steps_box)
	for i in 4:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		steps_box.add_child(l)
		_steps.append(l)
	_detail_lbl = _note("")
	_fix_row = HBoxContainer.new()
	_fix_row.add_theme_constant_override("separation", 8)
	add_child(_fix_row)

	add_child(SectionHeader.make("Live links", "link"))
	_links_box = VBoxContainer.new()
	_links_box.add_theme_constant_override("separation", 6)
	add_child(_links_box)
	_build_links_box()


## Phase 2 fills this with the link summary and the Live links button.
func _build_links_box() -> void:
	for c in _links_box.get_children():
		c.queue_free()
	var s := _svc()
	var summary := ""
	if s != null and s.has_method("links_summary_text"):
		summary = str(s.call("links_summary_text"))
	var l := Label.new()
	l.text = summary if not summary.is_empty() else "Link a Home Assistant sensor to a value in the simulation (battery, solar, a load, a tank…) from the Live links window."
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", C_TEXT_S)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_links_box.add_child(l)
	_links_lbl = l
	_live_row = HBoxContainer.new()
	_live_row.add_theme_constant_override("separation", 8)
	_links_box.add_child(_live_row)
	var ll := Label.new()
	ll.text = "Live mode is off: links record readings but the simulation keeps its own values."
	ll.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ll.add_theme_color_override("font_color", UITheme.C_WARN)
	ll.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_live_row.add_child(ll)
	var lb := Button.new()
	lb.text = "Turn on Live mode"
	lb.tooltip_text = "Runs the clock at real time from now, so linked values follow your real system."
	UITheme.style_button(lb)
	lb.pressed.connect(func() -> void:
		var ssc := get_node_or_null("/root/SimSettingsController")
		if ssc != null:
			ssc.call("set_live_mode", true)
		_refresh_status())
	_live_row.add_child(lb)
	var b := Button.new()
	b.text = "Open Live links…"
	b.tooltip_text = "Pick a sensor from your Home Assistant for any value the simulation tracks."
	UITheme.style_button(b)
	b.pressed.connect(_open_links)
	_links_box.add_child(b)


func _open_links() -> void:
	var main := _main()
	if main != null and main.has_method("open_ha_links"):
		main.call("open_ha_links", "")
	elif main == null:
		_flash_detail("Load a world first: links belong to a world.")


func _line_row(label: String, placeholder: String, secret: bool) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size.x = ROW_LABEL_W
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	row.add_child(lbl)
	var ed := LineEdit.new()
	ed.placeholder_text = placeholder
	ed.secret = secret
	ed.max_length = 1024
	ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ed)
	if secret:
		var show_btn := Button.new()
		show_btn.text = "Show"
		show_btn.toggle_mode = true
		UITheme.style_button(show_btn)
		show_btn.toggled.connect(func(on: bool) -> void:
			ed.secret = not on
			show_btn.text = "Hide" if on else "Show")
		row.add_child(show_btn)
	return ed


func _note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.visible = not text.is_empty()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 380
	l.add_theme_color_override("font_color", C_TEXT_M)
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	add_child(l)
	return l


# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

func _initial_profile_id() -> String:
	var s := _svc()
	if s == null:
		return ""
	var a := str(s.call("active_profile_id"))
	if not a.is_empty() and not (s.call("profile", a) as Dictionary).is_empty():
		return a
	return str(s.call("default_profile_id"))


func _load_profile_list() -> void:
	_syncing = true
	_profile_opt.clear()
	_profile_ids.clear()
	var s := _svc()
	var def_id := str(s.call("default_profile_id")) if s != null else ""
	if s != null:
		for p in s.call("profiles"):
			var label := HaProfiles.label(p)
			var when := _ago(int(p.get("last_ok_unix", 0)))
			var extra := "  ·  %s" % HaUrl.short(str(p.get("url", "")))
			extra += ("  ·  connected %s" % when) if not when.is_empty() else "  ·  never connected"
			if str(p["id"]) == def_id:
				label += "  (default)"
			_profile_opt.add_item(label + extra)
			_profile_ids.append(str(p["id"]))
	_profile_opt.add_item(ADD_NEW_LABEL)
	_profile_ids.append("")
	_syncing = false


func _select_profile(id: String) -> void:
	_syncing = true
	var idx := _profile_ids.find(id)
	if idx < 0:
		idx = _profile_ids.size() - 1   # "add new"
	_profile_opt.select(idx)
	_editing_id = str(_profile_ids[idx])
	var s := _svc()
	var p: Dictionary = s.call("profile", _editing_id) if s != null and not _editing_id.is_empty() else {}
	_name_ed.text = str(p.get("name", ""))
	_url_ed.text = str(p.get("url", ""))
	_token_ed.text = str(p.get("token", ""))
	_delete_btn.disabled = _editing_id.is_empty()
	_default_btn.disabled = _editing_id.is_empty() or (s != null and str(s.call("default_profile_id")) == _editing_id)
	_auto_chk.button_pressed = s != null and bool(s.call("auto_connect_enabled"))
	_syncing = false
	_update_url_preview()
	_update_token_note()


func _on_profile_picked(idx: int) -> void:
	if _syncing or idx < 0 or idx >= _profile_ids.size():
		return
	_select_profile(str(_profile_ids[idx]))
	if _editing_id.is_empty():
		_name_ed.grab_focus.call_deferred()


func _on_profiles_changed() -> void:
	var keep := _editing_id
	_load_profile_list()
	_select_profile(keep if _profile_ids.has(keep) else _initial_profile_id())
	_refresh_world_row()


func _on_make_default() -> void:
	var s := _svc()
	if s != null and not _editing_id.is_empty():
		s.call("set_default_profile", _editing_id)


func _on_delete() -> void:
	var s := _svc()
	if s == null or _editing_id.is_empty():
		return
	if _delete_btn.text != "Sure?":
		_delete_btn.text = "Sure?"
		get_tree().create_timer(3.0).timeout.connect(func() -> void:
			if is_instance_valid(_delete_btn):
				_delete_btn.text = "")
		return
	_delete_btn.text = ""
	s.call("delete_profile", _editing_id)


# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------

func _on_connect() -> void:
	var s := _svc()
	if s == null:
		return
	var id := str(s.call("save_profile", _name_ed.text, _url_ed.text, _token_ed.text, _editing_id))
	_editing_id = id
	s.call("connect_profile", id, false)
	_load_profile_list()
	_select_profile(id)


func _update_url_preview() -> void:
	var raw := _url_ed.text.strip_edges()
	if raw.is_empty():
		_url_preview.visible = false
		return
	var n := HaUrl.normalize(raw)
	_url_preview.visible = true
	if bool(n.get("ok", false)):
		_url_preview.text = "Will connect to %s" % n["url"]
		_url_preview.add_theme_color_override("font_color", C_TEXT_M)
	else:
		_url_preview.text = str(n.get("error", ""))
		_url_preview.add_theme_color_override("font_color", UITheme.C_WARN)


func _update_token_note() -> void:
	var raw := _token_ed.text
	if raw.strip_edges().is_empty():
		_token_note.visible = false
		return
	var t := HaToken.clean(raw)
	var c := HaToken.check(t)
	_token_note.visible = true
	if bool(c.get("ok", false)):
		_token_note.text = "Token looks right (%d characters)." % t.length()
		_token_note.add_theme_color_override("font_color", C_TEXT_M)
	else:
		_token_note.text = str(c.get("error", ""))
		_token_note.add_theme_color_override("font_color", UITheme.C_WARN)


# ---------------------------------------------------------------------------
# This world's instance
# ---------------------------------------------------------------------------

func _refresh_world_row() -> void:
	var s := _svc()
	var in_world := s != null and not WorldPaths.active_world_id().is_empty()
	_world_row.visible = in_world
	if not in_world:
		return
	_syncing = true
	_world_opt.clear()
	_world_ids.clear()
	var def := s.call("profile", str(s.call("default_profile_id"))) as Dictionary
	_world_opt.add_item("Default instance (%s)" % (HaProfiles.label(def) if not def.is_empty() else "none yet"))
	_world_ids.append("")
	for p in s.call("profiles"):
		_world_opt.add_item(HaProfiles.label(p))
		_world_ids.append(str(p["id"]))
	var own := str(s.call("world_profile_id"))
	_world_opt.select(maxi(0, _world_ids.find(own)))
	_syncing = false


func _on_world_profile_picked(idx: int) -> void:
	if _syncing or idx < 0 or idx >= _world_ids.size():
		return
	var s := _svc()
	if s == null:
		return
	s.call("set_world_profile", str(_world_ids[idx]))
	var id := str(_world_ids[idx])
	if id.is_empty():
		id = str(s.call("default_profile_id"))
	if not id.is_empty():
		s.call("connect_profile", id, false)
		_select_profile(id)


# ---------------------------------------------------------------------------
# Status card
# ---------------------------------------------------------------------------

func _on_state_changed(_state: int, _info: Dictionary) -> void:
	_refresh_status()


func _refresh_status() -> void:
	var s := _svc()
	if s == null or _banner == null:
		return
	var st := int(s.get("state"))
	var info: Dictionary = s.call("info")
	const E := HomeAssistantService.State
	match st:
		HomeAssistantService.State.IDLE:
			_banner.show_alert(AlertBanner.INFO, "Not connected")
		HomeAssistantService.State.CONNECTING:
			_banner.show_alert(AlertBanner.INFO, str(s.call("status_text")))
		HomeAssistantService.State.AUTHENTICATING:
			_banner.show_alert(AlertBanner.INFO, "Reached Home Assistant — logging in…")
		HomeAssistantService.State.CONNECTED:
			_banner.show_alert(AlertBanner.OK, str(s.call("status_text")))
		HomeAssistantService.State.FAILED:
			_banner.show_alert(AlertBanner.ERROR, str(s.call("status_text")))
	var reason := str(info.get("reason", "")) if st == E.FAILED else ""
	var started := st != E.IDLE
	_set_step(0, "Address", started and bool(info.get("address_ok", false)),
		reason == HaFailure.BAD_URL, started, str(info.get("url", "")))
	var reached := bool(info.get("reached", false))
	var ver := str(info.get("ha_version", ""))
	_set_step(1, "Reached Home Assistant", reached,
		reason in [HaFailure.REFUSED, HaFailure.UNREACHABLE, HaFailure.NOT_HA],
		started and bool(info.get("address_ok", false)), ver)
	_set_step(2, "Token accepted", bool(info.get("authed", false)),
		reason in [HaFailure.AUTH_INVALID, HaFailure.AUTH_TIMEOUT, HaFailure.BAD_TOKEN], reached or reason == HaFailure.BAD_TOKEN, "")
	var n := int(info.get("entity_count", 0))
	_set_step(3, "Entities", n > 0, false, bool(info.get("authed", false)),
		UiText.count(n, "entity", "entities") if n > 0 else ("loading…" if st == E.CONNECTED else ""))
	var detail := str(info.get("detail", "")) if st == E.FAILED else ""
	if bool(info.get("finding", false)):
		detail += ("\n" if not detail.is_empty() else "") + "Looking for Home Assistant on the usual ports…"
	_detail_lbl.text = detail
	_detail_lbl.visible = not detail.is_empty()
	_refresh_fixes(st, info)
	if _links_lbl != null:
		var sm := str(s.call("links_summary_text"))
		if not sm.is_empty():
			_links_lbl.text = sm
	if _live_row != null:
		var ssc := get_node_or_null("/root/SimSettingsController")
		_live_row.visible = _main() != null and ssc != null and not bool(ssc.get("live_mode_enabled"))
	if _disconnect_btn != null:
		_disconnect_btn.disabled = st == E.IDLE


func _set_step(i: int, label: String, done: bool, failed: bool, reached: bool, extra: String) -> void:
	var l: Label = _steps[i]
	var mark := "○"
	var col := C_TEXT_M
	if failed:
		mark = "✕"
		col = UITheme.C_ERROR
	elif done:
		mark = "✓"
		col = UITheme.C_OK
	elif reached:
		mark = "…"
		col = C_TEXT_S
	var t := "%s  %s" % [mark, label]
	if not extra.is_empty() and (done or failed or i == 3):
		t += "  —  " + (("Home Assistant %s" % extra) if i == 1 else extra)
	l.text = t
	l.add_theme_color_override("font_color", col)


var _fix_sig := ""

func _refresh_fixes(st: int, info: Dictionary) -> void:
	var sug := str(info.get("suggestion_url", ""))
	var fix := str(info.get("fix", "")) if st == HomeAssistantService.State.FAILED else ""
	var sig := "%d|%s|%s" % [st, fix, sug]
	if sig == _fix_sig:
		return
	_fix_sig = sig
	for c in _fix_row.get_children():
		c.queue_free()
	if not sug.is_empty():
		var v := str(info.get("suggestion_version", ""))
		_fix_button("Use %s%s" % [HaUrl.short(sug), (" (Home Assistant %s)" % v) if not v.is_empty() else ""],
			"Home Assistant answered at %s. Save that address on this instance and connect." % sug,
			func() -> void:
				var s := _svc()
				if s != null and bool(s.call("use_suggestion")):
					_select_profile(_editing_id))
	if fix in ["retry", "find"]:
		_fix_button("Try again", "", func() -> void:
			var s := _svc()
			if s != null:
				s.call("retry_now"))
	if fix == "token_help":
		_fix_button("Open Home Assistant's security page", "Opens your Home Assistant profile page in the browser, where tokens are made.", func() -> void:
			var u := HaUrl.browser_url(str(info.get("url", "")))
			if not u.is_empty():
				OS.shell_open(u + "/profile/security"))
	if fix == "edit_url":
		_fix_button("Edit the address", "", func() -> void: _url_ed.grab_focus())
	if st == HomeAssistantService.State.CONNECTED:
		_fix_button("Open in browser", "Open this Home Assistant in your web browser.", func() -> void:
			OS.shell_open(HaUrl.browser_url(str(info.get("url", "")))))


func _fix_button(text: String, tip: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	UITheme.style_button(b)
	b.pressed.connect(cb)
	_fix_row.add_child(b)


func _flash_detail(text: String) -> void:
	_detail_lbl.text = text
	_detail_lbl.visible = true


func _main() -> Node:
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("open_ha_links"):
		return scene
	return null


static func _ago(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := int(Time.get_unix_time_from_system()) - unix
	if d < 90:
		return "just now"
	if d < 3600 * 2:
		return "%d min ago" % (d / 60)
	if d < 86400 * 2:
		return "%d h ago" % (d / 3600)
	return "%d days ago" % (d / 86400)
