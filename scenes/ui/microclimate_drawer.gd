extends CanvasLayer

## 🌫 Microclimate drawer — calibrate how THIS site looks against the weather
## data. Docked on the right above the timeline, NOT a full-screen modal: the
## point is to scrub the timeline, look at the world, tweak, and save, all with
## the drawer open.
##
## Workflow it is built for (Walton OR, Oct 2026): scrub to 23:00 on a night
## you stood in valley fog, drag "Fog visibility" until the world matches what
## you saw, then
##   * 📌 Pin here            — ground truth for that exact time;
##   * Make rule from now      — the game proposes the conditions (dew-point
##                               gap, wind, sky, night) and holds the fog until
##                               it burns off; the timeline strip shows every
##                               hour it fires, so you can see it recur;
##   * Save as example         — a nearest-match point: any hour whose weather
##                               resembles this one borrows its look.
## Corrections fix the INPUT data (playa wind ×1.5, valley nights colder).
##
## Everything lives in MicroclimateProfile (one JSON per map); the resolver
## (autoload `Microclimate`) evaluates it. Built by TimelineUI (🌫 button).

const MODAL_NAME := "microclimate_drawer"
const PANEL_W := 430.0
const REFRESH_S := 0.25

## Rule/correction variables offered in the UI.
const CORRECTION_VARS := [["wind_ms", "Wind"], ["t_c", "Temperature"], ["rh", "Humidity"], ["cloud", "Cloud cover"]]

var _timeline: Node = null
var _root: PanelContainer
var _readout: RichTextLabel
var _site_lbl: Label
var _enable_chk: CheckBox
var _auto_chk: CheckBox
var _nearest_chk: CheckBox
var _bias_spin: SpinBox
var _bias_auto_chk: CheckBox
var _depth_spin: SpinBox
var _depth_auto_chk: CheckBox
var _preview_chk: CheckBox
var _look_name: LineEdit
var _look_pick: OptionButton
var _sliders: Dictionary = {}       # key → HSlider
var _value_lbls: Dictionary = {}    # key → Label
var _suppress_chk: CheckBox
var _physics_chk: CheckBox
var _rules_box: VBoxContainer
var _obs_box: VBoxContainer
var _corr_box: VBoxContainer
var _status: Label
var _acc := 0.0
var _syncing := false
var _look: Dictionary = {}


func bind_timeline(tl: Node) -> void:
	_timeline = tl


func _ready() -> void:
	layer = UITheme.LAYER_PANEL
	visible = false
	_build()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	# A right dock: the HUD's right column tucks beside it (Terrain options sat
	# under its top), and its bottom follows the live timeline height.
	HudLayout.claim_right_dock(MODAL_NAME, _root, PANEL_W)
	_load_settings()
	_start_from_current()
	_rebuild_lists()
	_refresh_readout()


func close() -> void:
	if not visible:
		return
	visible = false
	var mc := _mc()
	if mc != null:
		mc.call("clear_preview")
	CursorController.release_modal(MODAL_NAME)
	HudLayout.release(MODAL_NAME)


func _process(delta: float) -> void:
	if not visible:
		return
	_acc += delta
	if _acc < REFRESH_S:
		return
	_acc = 0.0
	_refresh_readout()


# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

func _mc() -> Node:
	return get_node_or_null("/root/Microclimate")


func _profile() -> MicroclimateProfile:
	var mc := _mc()
	return mc.get("profile") if mc != null else null


func _main() -> Node:
	for c in get_tree().root.get_children():
		if "day_time" in c and "sun" in c:
			return c
	return null


func _now_h() -> float:
	var m := _main()
	if m != null and m.has_method("get_absolute_hours"):
		return float(m.call("get_absolute_hours"))
	return NAN


func _commit(msg: String = "") -> void:
	var mc := _mc()
	if mc != null:
		mc.call("profile_edited", true)
	_rebuild_lists()
	if not msg.is_empty():
		_status.text = msg
	if _timeline != null and _timeline.get("_track") != null:
		(_timeline.get("_track") as Control).queue_redraw()


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build() -> void:
	_root = PanelContainer.new()
	_root.add_theme_stylebox_override("panel", UITheme.panel_style(0.96))
	_root.anchor_left = 1.0
	_root.anchor_right = 1.0
	_root.anchor_top = 0.0
	_root.anchor_bottom = 1.0
	_root.offset_left = -PANEL_W - 12.0
	_root.offset_right = -12.0
	_root.offset_top = 12.0
	_root.offset_bottom = -176.0   # clears the timeline bar (BAR_HEIGHT 164)
	add_child(_root)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	_root.add_child(outer)

	_enable_chk = CheckBox.new()
	_enable_chk.text = "On"
	_enable_chk.button_pressed = true
	_enable_chk.tooltip_text = "Master switch for this site's microclimate layer (auto fog + your calibration)."
	_enable_chk.toggled.connect(func(on: bool) -> void:
		var mc := _mc()
		if mc != null:
			mc.call("set_enabled", on))
	var head := DockShell.header("Microclimate", "", close, [_enable_chk])
	outer.add_child(head["row"])

	_site_lbl = _small("", UITheme.C_TEXT_M)
	outer.add_child(_site_lbl)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	scroll.add_child(body)

	# --- at playhead -------------------------------------------------------
	body.add_child(_section("At the playhead"))
	_readout = RichTextLabel.new()
	_readout.bbcode_enabled = true
	_readout.fit_content = true
	_readout.scroll_active = false
	_readout.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	_readout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_readout)

	# --- site settings -----------------------------------------------------
	body.add_child(_section("Site"))
	_auto_chk = _check(body, "Automatic fog from the weather data",
		"Diagnose fog from humidity, low cloud, model visibility, wind and sky — no calibration needed.",
		func(on: bool) -> void: _set_setting("auto_fog", on))
	_nearest_chk = _check(body, "Nearest-match from saved examples",
		"Any hour whose weather resembles a saved example borrows that example's look.",
		func(on: bool) -> void: _set_setting("nearest", on))
	var bias_row := _row(body, "Valley cold pool (°C)",
		"How much colder this site gets than the weather grid on calm, clear nights. A valley floor saturates hours before its 10–30 km grid cell does. Auto = from the terrain's depth.")
	_bias_auto_chk = CheckBox.new()
	_bias_auto_chk.text = "Auto"
	bias_row.add_child(_bias_auto_chk)
	_bias_spin = _spin(bias_row, 0.0, 6.0, 0.25)
	_bias_auto_chk.toggled.connect(func(on: bool) -> void:
		_bias_spin.editable = not on
		_set_setting("cold_pool_bias_c", NAN if on else _bias_spin.value))
	_bias_spin.value_changed.connect(func(v: float) -> void:
		if not _bias_auto_chk.button_pressed:
			_set_setting("cold_pool_bias_c", v))
	var depth_row := _row(body, "Fog layer depth (m)",
		"How deep the fog lies above the valley floor. Auto = from the terrain.")
	_depth_auto_chk = CheckBox.new()
	_depth_auto_chk.text = "Auto"
	depth_row.add_child(_depth_auto_chk)
	_depth_spin = _spin(depth_row, 5.0, 400.0, 5.0)
	_depth_auto_chk.toggled.connect(func(on: bool) -> void:
		_depth_spin.editable = not on
		_set_setting("fog_depth_m", NAN if on else _depth_spin.value))
	_depth_spin.value_changed.connect(func(v: float) -> void:
		if not _depth_auto_chk.button_pressed:
			_set_setting("fog_depth_m", v))

	# --- look editor -------------------------------------------------------
	body.add_child(_section("How the site looks now"))
	body.add_child(_small("Scrub to a moment you saw, match it, then save it below.", UITheme.C_TEXT_S))
	_preview_chk = _check(body, "Preview live (not saved)", "Show these sliders in the world while you edit.",
		func(_on: bool) -> void: _push_preview())
	_preview_chk.button_pressed = true
	var pick_row := HBoxContainer.new()
	body.add_child(pick_row)
	_look_pick = OptionButton.new()
	_look_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_look_pick.item_selected.connect(_on_look_picked)
	pick_row.add_child(_look_pick)
	var cur_btn := _button(pick_row, "From now", "Reset the sliders to what the site shows at the playhead.")
	cur_btn.pressed.connect(_start_from_current)

	_slider(body, "fog_vis", "Ground fog", "Fog visibility on the valley floor. Left = none.")
	_slider(body, "fog_depth", "Fog depth", "How high the fog reaches above the valley floor.")
	_slider(body, "haze_vis", "Haze", "Whole-scene haze (smoke, dust, humidity). Left = none.")
	_slider(body, "cloud_add", "Clouds ±", "Add or remove overhead cloud versus the data.")
	_slider(body, "dust", "Blowing dust", "Dust particles in the air.")
	_slider(body, "wind_vis", "Wind (visual) ×", "How hard vegetation and dust move, versus the data.")
	_slider(body, "light", "Sunlight", "Dim the sun (thick haze, high fog deck).")
	_suppress_chk = _check(body, "This look means NO automatic fog",
		"Use for 'this is what clear looks like here' — it switches the automatic fog off wherever it applies.",
		func(_on: bool) -> void: _on_slider_changed())
	_physics_chk = _check(body, "Also affects physics (PV yield)",
		"Fog and haze from this look also cut solar output (as aerosol optical depth). Off = purely visual.",
		func(_on: bool) -> void: _on_slider_changed())

	var name_row := HBoxContainer.new()
	body.add_child(name_row)
	_look_name = LineEdit.new()
	_look_name.placeholder_text = "Look name (e.g. Valley fog)"
	_look_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_look_name)
	_button(name_row, "Save look", "Store these sliders as a named look rules can use.").pressed.connect(_on_save_look)

	var act := HFlowContainer.new()
	body.add_child(act)
	_button(act, "📌 Pin here", "Ground truth for this exact time: shown as-is, cross-faded over ±1.5 h.").pressed.connect(
		func() -> void: _on_add_observation(true))
	_button(act, "Make rule from now", "Propose conditions from the weather at the playhead; this look recurs whenever they recur.").pressed.connect(_on_make_rule)
	_button(act, "Save as example", "A nearest-match example: hours with similar weather borrow this look.").pressed.connect(
		func() -> void: _on_add_observation(false))
	_status = _small("", UITheme.C_PRIMARY)
	body.add_child(_status)

	# --- lists ------------------------------------------------------------
	body.add_child(_section("Rules"))
	_rules_box = VBoxContainer.new()
	body.add_child(_rules_box)
	body.add_child(_section("Pinned moments & examples"))
	_obs_box = VBoxContainer.new()
	body.add_child(_obs_box)
	body.add_child(_section("Data corrections"))
	body.add_child(_small("Fix the INPUT weather (e.g. playa wind ×1.5 vs the Gerlach grid cell).", UITheme.C_TEXT_S))
	_corr_box = VBoxContainer.new()
	body.add_child(_corr_box)
	var add_corr := _button(body, "+ Add correction", "")
	add_corr.pressed.connect(_on_add_correction)


# --- small widget helpers ----------------------------------------------------

func _section(text: String) -> Control:
	return SectionHeader.make(text)


func _small(text: String, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", col)
	return l


func _button(parent: Control, text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	UITheme.style_button(b)
	parent.add_child(b)
	return b


func _check(parent: Control, text: String, tip: String, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	c.toggled.connect(func(on: bool) -> void:
		if not _syncing:
			cb.call(on))
	parent.add_child(c)
	return c


func _row(parent: Control, text: String, tip: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.tooltip_text = tip
	var l := Label.new()
	l.text = text
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(l)
	parent.add_child(r)
	return r


func _spin(parent: Control, lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size.x = 90
	parent.add_child(s)
	return s


func _slider(parent: Control, key: String, text: String, tip: String) -> void:
	var r := _row(parent, text, tip)
	var v := Label.new()
	v.custom_minimum_size.x = 78
	v.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	v.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	r.add_child(v)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.001
	s.custom_minimum_size.x = 150
	s.tooltip_text = tip
	s.value_changed.connect(func(_x: float) -> void: _on_slider_changed())
	r.add_child(s)
	_sliders[key] = s
	_value_lbls[key] = v


# ---------------------------------------------------------------------------
# Slider ↔ look mapping. Visibility sliders are logarithmic: equal steps look
# like equal steps in density.
# ---------------------------------------------------------------------------

const FOG_VIS_FAR := 2000.0
const FOG_VIS_NEAR := 25.0
const HAZE_VIS_FAR := 60000.0
const HAZE_VIS_NEAR := 400.0


static func _log_vis(t: float, far: float, near: float) -> float:
	if t <= 0.001:
		return INF
	return exp(lerpf(log(far), log(near), t))


static func _log_vis_inv(v: float, far: float, near: float) -> float:
	if not is_finite(v) or v >= far:
		return 0.0
	return clampf((log(v) - log(far)) / (log(near) - log(far)), 0.0, 1.0)


func _look_from_sliders() -> Dictionary:
	var l := {}
	var fv := _log_vis(_sv("fog_vis"), FOG_VIS_FAR, FOG_VIS_NEAR)
	if is_finite(fv):
		l["fog_vis_m"] = fv
		l["fog_depth_m"] = lerpf(5.0, 300.0, pow(_sv("fog_depth"), 1.6))
	var hv := _log_vis(_sv("haze_vis"), HAZE_VIS_FAR, HAZE_VIS_NEAR)
	if is_finite(hv):
		l["haze_vis_m"] = hv
	var ca := lerpf(-1.0, 1.0, _sv("cloud_add"))
	if absf(ca) > 0.01:
		l["cloud_add"] = ca
	if _sv("dust") > 0.005:
		l["dust"] = _sv("dust")
	var wv := lerpf(0.5, 3.0, _sv("wind_vis"))
	if absf(wv - 1.0) > 0.01:
		l["wind_vis_mult"] = wv
	var li := lerpf(0.3, 1.0, _sv("light"))
	if li < 0.995:
		l["light_mult"] = li
	if _suppress_chk.button_pressed:
		l["suppress_auto"] = true
	if _physics_chk.button_pressed:
		l["physics"] = true
	return l


func _sv(key: String) -> float:
	return float((_sliders[key] as HSlider).value)


func _set_sliders_from_look(l: Dictionary) -> void:
	_syncing = true
	(_sliders["fog_vis"] as HSlider).value = _log_vis_inv(float(l.get("fog_vis_m", INF)), FOG_VIS_FAR, FOG_VIS_NEAR)
	var d := float(l.get("fog_depth_m", 40.0))
	(_sliders["fog_depth"] as HSlider).value = pow(clampf((d - 5.0) / 295.0, 0.0, 1.0), 1.0 / 1.6) if is_finite(d) else 0.3
	(_sliders["haze_vis"] as HSlider).value = _log_vis_inv(float(l.get("haze_vis_m", INF)), HAZE_VIS_FAR, HAZE_VIS_NEAR)
	(_sliders["cloud_add"] as HSlider).value = (float(l.get("cloud_add", 0.0)) + 1.0) * 0.5
	(_sliders["dust"] as HSlider).value = float(l.get("dust", 0.0))
	(_sliders["wind_vis"] as HSlider).value = (float(l.get("wind_vis_mult", 1.0)) - 0.5) / 2.5
	(_sliders["light"] as HSlider).value = (float(l.get("light_mult", 1.0)) - 0.3) / 0.7
	_suppress_chk.button_pressed = bool(l.get("suppress_auto", false))
	_physics_chk.button_pressed = bool(l.get("physics", false))
	_syncing = false
	_on_slider_changed()


func _on_slider_changed() -> void:
	if _syncing:
		return
	_look = _look_from_sliders()
	var fv := float(_look.get("fog_vis_m", INF))
	_value_lbls["fog_vis"].text = "none" if not is_finite(fv) else "%d m" % int(fv)
	_value_lbls["fog_depth"].text = "%d m" % int(float(_look.get("fog_depth_m", lerpf(5.0, 300.0, pow(_sv("fog_depth"), 1.6)))))
	var hv := float(_look.get("haze_vis_m", INF))
	_value_lbls["haze_vis"].text = "none" if not is_finite(hv) else ("%.1f km" % (hv / 1000.0))
	_value_lbls["cloud_add"].text = "%+d %%" % int(round(lerpf(-100.0, 100.0, _sv("cloud_add"))))
	_value_lbls["dust"].text = "%d %%" % int(_sv("dust") * 100.0)
	_value_lbls["wind_vis"].text = "×%.2f" % lerpf(0.5, 3.0, _sv("wind_vis"))
	_value_lbls["light"].text = "%d %%" % int(lerpf(30.0, 100.0, _sv("light")))
	_push_preview()


func _push_preview() -> void:
	var mc := _mc()
	if mc == null:
		return
	if _preview_chk.button_pressed:
		mc.call("set_preview", _look)
	else:
		mc.call("clear_preview")


## Seed the sliders from what the resolver shows now (without the preview).
func _start_from_current() -> void:
	var mc := _mc()
	if mc == null:
		return
	mc.call("clear_preview")
	var st: Dictionary = mc.call("resolve_at", _now_h())
	var l := {}
	if float(st.get("fog_sigma", 0.0)) > 1e-5:
		l["fog_vis_m"] = float(st["fog_vis_m"])
		l["fog_depth_m"] = float(st["fog_depth_m"])
	else:
		l["fog_depth_m"] = float(mc.call("site_context").get("default_depth_m", 30.0))
	if float(st.get("haze_sigma", 0.0)) > 1e-6:
		l["haze_vis_m"] = FogOptics.visibility_for_sigma(float(st["haze_sigma"]))
	_set_sliders_from_look(l)


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _set_setting(key: String, v: Variant) -> void:
	var p := _profile()
	if p == null:
		return
	p.settings[key] = v
	_commit()


func _load_settings() -> void:
	var p := _profile()
	var mc := _mc()
	if p == null or mc == null:
		return
	_syncing = true
	_enable_chk.button_pressed = bool(mc.get("enabled"))
	_auto_chk.button_pressed = bool(p.settings.get("auto_fog", true))
	_nearest_chk.button_pressed = bool(p.settings.get("nearest", true))
	var ctx: Dictionary = mc.call("site_context")
	var b := float(p.settings.get("cold_pool_bias_c", NAN))
	_bias_auto_chk.button_pressed = not is_finite(b)
	_bias_spin.value = b if is_finite(b) else float(ctx.get("cold_pool_bias_c", 0.0))
	_bias_spin.editable = is_finite(b)
	var d := float(p.settings.get("fog_depth_m", NAN))
	_depth_auto_chk.button_pressed = not is_finite(d)
	_depth_spin.value = d if is_finite(d) else float(ctx.get("default_depth_m", 30.0))
	_depth_spin.editable = is_finite(d)
	var path := str(mc.call("profile_path"))
	_site_lbl.text = "Saved per map → %s  ·  valley index %.0f m" % [path.get_file(), float(ctx.get("tpi_m", 0.0))]
	_syncing = false


func _on_save_look() -> void:
	var p := _profile()
	if p == null:
		return
	var name := _look_name.text.strip_edges()
	if name.is_empty():
		name = "Look %d" % (p.looks.size() + 1)
	p.set_look(name, _look)
	_commit("Saved look “%s”." % name)


func _ensure_named_look() -> String:
	var p := _profile()
	var name := _look_name.text.strip_edges()
	if name.is_empty():
		name = "Look %d" % (p.looks.size() + 1)
		_look_name.text = name
	p.set_look(name, _look)
	return name


func _on_add_observation(pin: bool) -> void:
	var p := _profile()
	var mc := _mc()
	var h := _now_h()
	if p == null or mc == null or not is_finite(h):
		return
	var feats: Dictionary = mc.call("features_at", h)
	p.observations.append({
		"id": MicroclimateProfile.new_id("obs"),
		"abs_h": h,
		"features": _plain_features(feats),
		"look": _look.duplicate(),
		"pin": pin,
		"radius_h": 1.5,
		"note": str(feats.get("label", "")),
	})
	_commit(("📌 Pinned %s." if pin else "Saved example at %s.") % str(feats.get("label", "")))


func _on_make_rule() -> void:
	var p := _profile()
	var mc := _mc()
	var h := _now_h()
	if p == null or mc == null or not is_finite(h):
		return
	var look_id := _ensure_named_look()
	var feats: Dictionary = mc.call("features_at", h)
	var rule := MicroclimateProfile.suggest_rule(feats, look_id, "%s (from %s)" % [look_id, str(feats.get("label", ""))])
	p.rules.append(rule)
	_commit("Rule added — the lavender strip on the timeline shows every hour it fires.")


## Only the numeric features a nearest-match compares — strings and the label
## do not belong in a saved snapshot.
static func _plain_features(f: Dictionary) -> Dictionary:
	var out := {}
	for k in MicroclimateProfile.FEATURES.keys():
		if f.has(k) and (f[k] is float or f[k] is int) and is_finite(float(f[k])):
			out[k] = float(f[k])
	return out


func _on_look_picked(idx: int) -> void:
	var p := _profile()
	if p == null or idx <= 0:
		return
	var id := _look_pick.get_item_text(idx)
	if p.looks.has(id):
		_look_name.text = id
		_set_sliders_from_look(p.looks[id])


func _on_add_correction() -> void:
	var p := _profile()
	if p == null:
		return
	p.corrections.append({"id": MicroclimateProfile.new_id("corr"), "var": "wind_ms",
		"mult": 1.0, "add": 0.0, "when": [], "physics": false, "enabled": true})
	_commit()


# ---------------------------------------------------------------------------
# Lists
# ---------------------------------------------------------------------------

func _rebuild_lists() -> void:
	var p := _profile()
	if p == null:
		return
	_clear(_rules_box)
	_clear(_obs_box)
	_clear(_corr_box)
	# Look picker.
	_look_pick.clear()
	_look_pick.add_item("— saved looks —")
	for id in p.looks.keys():
		_look_pick.add_item(str(id))
	# Rules.
	if p.rules.is_empty():
		_rules_box.add_child(_small("None yet. Scrub to a moment, match the look, then “Make rule from now”.", UITheme.C_TEXT_M))
	for i in p.rules.size():
		_rules_box.add_child(_rule_card(p, i))
	# Observations.
	if p.observations.is_empty():
		_obs_box.add_child(_small("None yet.", UITheme.C_TEXT_M))
	for i in p.observations.size():
		_obs_box.add_child(_obs_row(p, i))
	# Corrections.
	for i in p.corrections.size():
		_corr_box.add_child(_corr_row(p, i))


func _clear(box: Control) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _card() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.card_style())
	return pc


func _rule_card(p: MicroclimateProfile, i: int) -> Control:
	var rule: Dictionary = p.rules[i]
	var pc := _card()
	var v := VBoxContainer.new()
	pc.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var en := CheckBox.new()
	en.button_pressed = bool(rule.get("enabled", true))
	en.toggled.connect(func(on: bool) -> void:
		rule["enabled"] = on
		_commit())
	head.add_child(en)
	var nm := LineEdit.new()
	nm.text = str(rule.get("name", "Rule"))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_submitted.connect(func(t: String) -> void:
		rule["name"] = t
		_commit())
	head.add_child(nm)
	var look_opt := OptionButton.new()
	var sel := 0
	var n := 0
	for id in p.looks.keys():
		look_opt.add_item(str(id))
		if str(id) == str(rule.get("look", "")):
			sel = n
		n += 1
	if n > 0:
		look_opt.select(sel)
	look_opt.item_selected.connect(func(k: int) -> void:
		rule["look"] = look_opt.get_item_text(k)
		_commit())
	head.add_child(look_opt)
	var del := Button.new()
	del.text = "🗑"
	del.tooltip_text = "Delete rule"
	del.pressed.connect(func() -> void:
		p.rules.remove_at(i)
		_commit())
	head.add_child(del)
	v.add_child(_small("When:", UITheme.C_TEXT_S))
	for c in rule.get("when", []):
		v.add_child(_cond_row(c))
	if not (rule.get("hold", []) as Array).is_empty():
		v.add_child(_small("…and keeps holding while:", UITheme.C_TEXT_S))
		for c in rule.get("hold", []):
			v.add_child(_cond_row(c))
	var strength := HBoxContainer.new()
	var sl := Label.new()
	sl.text = "Strength"
	sl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	strength.add_child(sl)
	var hs := HSlider.new()
	hs.min_value = 0.0
	hs.max_value = 1.0
	hs.step = 0.05
	hs.value = float(rule.get("strength", 1.0))
	hs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hs.drag_ended.connect(func(_c: bool) -> void:
		rule["strength"] = hs.value
		_commit())
	strength.add_child(hs)
	var count_btn := Button.new()
	count_btn.text = "Count"
	count_btn.tooltip_text = "How many nights this rule fires over the loaded weather year."
	count_btn.pressed.connect(func() -> void: count_btn.text = _count_rule_nights(str(rule.get("id", ""))))
	strength.add_child(count_btn)
	v.add_child(strength)
	return pc


## One condition: feature label, min and max (blank = open), soft margin.
func _cond_row(c: Dictionary) -> Control:
	var r := HBoxContainer.new()
	var f := str(c.get("f", ""))
	var l := Label.new()
	l.text = str(MicroclimateProfile.FEATURES.get(f, {}).get("label", f))
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(l)
	for key in ["min", "max"]:
		var e := LineEdit.new()
		e.placeholder_text = "any" if key == "min" else "any"
		e.custom_minimum_size.x = 56
		var val: Variant = c.get(key, null)
		e.text = "" if val == null or not is_finite(float(val)) else ("%.2f" % float(val)).rstrip("0").rstrip(".")
		e.tooltip_text = "%s bound — blank = no limit" % key
		e.text_submitted.connect(func(t: String) -> void:
			c[key] = NAN if t.strip_edges().is_empty() or not t.is_valid_float() else t.to_float()
			_commit())
		e.focus_exited.connect(func() -> void:
			var t := e.text
			var nv: float = NAN if t.strip_edges().is_empty() or not t.is_valid_float() else t.to_float()
			var ov := float(c.get(key, NAN)) if c.get(key, null) != null else NAN
			if not (is_nan(nv) and is_nan(ov)) and nv != ov:
				c[key] = nv
				_commit())
		var tag := Label.new()
		tag.text = "≥" if key == "min" else "≤"
		tag.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		r.add_child(tag)
		r.add_child(e)
	return r


func _count_rule_nights(rule_id: String) -> String:
	var mc := _mc()
	var h := _now_h()
	if mc == null or not is_finite(h):
		return "?"
	var start := floorf(h / 24.0) * 24.0 - 180.0 * 24.0
	var nights := {}
	var months := {}
	# Two sweeps of ~180 days around the playhead: one year of evidence.
	for s in [start, start + 180.0 * 24.0]:
		var rows: Array = mc.call("sweep_rule", rule_id, s, s + 180.0 * 24.0)
		for r in rows:
			if float(r["w"]) >= 0.5:
				# Attribute an after-midnight hour to the evening before.
				var night := int(floor((float(r["h"]) - 12.0) / 24.0))
				nights[night] = true
				var dd: Dictionary = (_main().get("clock") as CelestialClock).abs_hours_to_date(float(r["h"]))
				months[int(dd["month"])] = int(months.get(int(dd["month"]), 0)) + 1
	var top := ""
	var best := 0
	for m in months:
		if int(months[m]) > best:
			best = int(months[m])
			top = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][int(m)]
	return "%s/yr%s" % [UiText.count(nights.size(), "night"), (" · most in " + top) if not top.is_empty() else ""]


func _obs_row(p: MicroclimateProfile, i: int) -> Control:
	var o: Dictionary = p.observations[i]
	var r := HBoxContainer.new()
	var pin := CheckBox.new()
	pin.text = "📌" if bool(o.get("pin", false)) else "≈"
	pin.button_pressed = bool(o.get("pin", false))
	pin.tooltip_text = "Pinned = exact time ground truth. Unpinned = nearest-match example only."
	pin.toggled.connect(func(on: bool) -> void:
		o["pin"] = on
		_commit())
	r.add_child(pin)
	var l := Label.new()
	var look: Dictionary = o.get("look", {})
	var fv := float(look.get("fog_vis_m", INF))
	l.text = "%s  %s" % [str(o.get("note", "")), ("fog %d m" % int(fv)) if is_finite(fv) else "no fog"]
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(l)
	var go := Button.new()
	go.text = "Go"
	go.tooltip_text = "Move the playhead here"
	go.pressed.connect(func() -> void:
		var m := _main()
		if m != null:
			m.call("set_absolute_hours", float(o.get("abs_h", 0.0))))
	r.add_child(go)
	var use := Button.new()
	use.text = "Edit"
	use.tooltip_text = "Load this look into the sliders"
	use.pressed.connect(func() -> void: _set_sliders_from_look(look))
	r.add_child(use)
	var del := Button.new()
	del.text = "🗑"
	del.pressed.connect(func() -> void:
		p.observations.remove_at(i)
		_commit())
	r.add_child(del)
	return r


func _corr_row(p: MicroclimateProfile, i: int) -> Control:
	var c: Dictionary = p.corrections[i]
	var pc := _card()
	var v := VBoxContainer.new()
	pc.add_child(v)
	var r := HBoxContainer.new()
	v.add_child(r)
	var opt := OptionButton.new()
	var sel := 0
	for k in CORRECTION_VARS.size():
		opt.add_item(CORRECTION_VARS[k][1])
		if CORRECTION_VARS[k][0] == str(c.get("var", "")):
			sel = k
	opt.select(sel)
	opt.item_selected.connect(func(k: int) -> void:
		c["var"] = CORRECTION_VARS[k][0]
		_commit())
	r.add_child(opt)
	var times := Label.new()
	times.text = "×"
	r.add_child(times)
	var mult := SpinBox.new()
	mult.min_value = 0.0
	mult.max_value = 5.0
	mult.step = 0.05
	mult.value = float(c.get("mult", 1.0))
	mult.value_changed.connect(func(x: float) -> void:
		c["mult"] = x
		_commit())
	r.add_child(mult)
	var plus := Label.new()
	plus.text = "+"
	r.add_child(plus)
	var add := SpinBox.new()
	add.min_value = -20.0
	add.max_value = 20.0
	add.step = 0.25
	add.value = float(c.get("add", 0.0))
	add.value_changed.connect(func(x: float) -> void:
		c["add"] = x
		_commit())
	r.add_child(add)
	var del := Button.new()
	del.text = "🗑"
	del.pressed.connect(func() -> void:
		p.corrections.remove_at(i)
		_commit())
	r.add_child(del)
	var r2 := HBoxContainer.new()
	v.add_child(r2)
	var calm := CheckBox.new()
	calm.text = "Calm clear nights only"
	calm.tooltip_text = "Only on nights with wind ≤ 2 m/s and cloud ≤ 30 % — the valley cold pool."
	calm.button_pressed = not (c.get("when", []) as Array).is_empty()
	var phys := CheckBox.new()
	phys.text = "Affects physics"
	phys.tooltip_text = "Also feeds turbines, PV, NPC comfort and the extreme-weather triggers. Only unconditional corrections can — a 'calm nights only' one stays visual."
	phys.button_pressed = bool(c.get("physics", false))
	phys.disabled = calm.button_pressed
	calm.toggled.connect(func(on: bool) -> void:
		c["when"] = [{"f": "wind_ms", "min": NAN, "max": 2.0, "soft": 1.0},
			{"f": "cloud", "min": NAN, "max": 0.3, "soft": 0.2},
			{"f": "sun_el", "min": NAN, "max": 0.0, "soft": 4.0}] if on else []
		_commit())
	phys.toggled.connect(func(on: bool) -> void:
		c["physics"] = on
		_commit())
	r2.add_child(calm)
	r2.add_child(phys)
	return pc


# ---------------------------------------------------------------------------
# Readout
# ---------------------------------------------------------------------------

func _refresh_readout() -> void:
	var mc := _mc()
	if mc == null:
		_readout.text = "[color=#ef4444]Microclimate service not loaded.[/color]"
		return
	var st: Dictionary = mc.call("current")
	var f: Dictionary = st.get("features", {})
	var lines: Array = []
	var src := str(f.get("source", "?"))
	lines.append("[color=#94a3b8]Data:[/color] %s" % {"archive_current": "ERA5 archive (this year)",
		"archive": "ERA5 archive (last year)", "forecast": "Forecast model", "generated": "Generated weather"}.get(src, src))
	lines.append("T %s  ·  dew pt %s  ·  gap %s  [color=#94a3b8](valley %s)[/color]" % [
		_fmt(f.get("t_c"), "%.1f°"), _fmt(f.get("td_c"), "%.1f°"), _fmt(f.get("dep_c"), "%.1f°"), _fmt(f.get("dep_eff_c"), "%.1f°")])
	lines.append("RH %s  ·  wind %s  ·  sun %s" % [_fmt(f.get("rh"), "%.0f%%"), _fmt(f.get("wind_ms"), "%.1f m/s"), _fmt(f.get("sun_el"), "%.0f°")])
	lines.append("cloud %s  ·  low %s  ·  model vis %s" % [_fmt_pct(f.get("cloud")), _fmt_pct(f.get("low")),
		_fmt(f.get("vis_km"), "%.1f km")])
	var auto_f := float(st.get("auto_fog", 0.0))
	var why := {"ground_cloud": "low cloud on the ground", "model_visibility": "model visibility",
		"radiation": "calm clear saturated night", "held": "holding until it burns off", "none": "—"}
	lines.append("[color=#22d3ee]Auto fog[/color] %d%%  [color=#94a3b8](%s)[/color]" % [int(auto_f * 100.0),
		why.get(str(st.get("auto_source", "none")), str(st.get("auto_source", "")))])
	var vis := float(st.get("fog_vis_m", INF))
	lines.append("[b]Showing:[/b] %s" % (("ground fog %d m, %d m deep" % [int(vis), int(float(st.get("fog_depth_m", 0.0)))]) if is_finite(vis) else "no ground fog"))
	var names: Array = []
	for c in st.get("contributors", []):
		var w := float(c.get("w", 0.0))
		if w < 0.02:
			continue
		names.append("%s %s %d%%" % [{"rule": "rule", "nearest": "≈", "pinned": "📌", "preview": "preview"}.get(str(c.get("kind", "")), ""),
			str(c.get("name", c.get("id", ""))) if str(c.get("kind", "")) == "rule" else "", int(w * 100.0)])
	if not names.is_empty():
		lines.append("[color=#94a3b8]From:[/color] " + ", ".join(names))
	_readout.text = "\n".join(lines)


static func _fmt(v: Variant, f: String) -> String:
	if v == null or not (v is float or v is int) or not is_finite(float(v)):
		return "—"
	return f % float(v)


static func _fmt_pct(v: Variant) -> String:
	if v == null or not is_finite(float(v)):
		return "—"
	return "%d%%" % int(float(v) * 100.0)
