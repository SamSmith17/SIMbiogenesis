extends Control

## Persistent extreme-weather badge + onset toasts (top-center chip).
##
## Two jobs, one component:
##  - PREVIEW badge: while ExtremeWeather.has_forced(), shows what is being
##    previewed with a live countdown ("Previewing 🌪 Dust storm · 0.7 ·
##    ends in 4.2 h — click to clear"). The settings modal auto-closes on
##    Preview so the player actually SEES the hazard; without this chip the
##    preview would be running with no indication or way to stop it short.
##  - ONSET notifications: the director's hazard_began/hazard_ended signals
##    had ZERO listeners — the "Warn me when a hazard begins" checkbox was a
##    no-op. This connects them: a toast on began (gated by the pref and the
##    catalog's per-hazard notify_threshold), a quiet one on ended, and the
##    chip stays up while any real hazard is active (no clear button — you
##    don't dismiss a dust storm).
##
## Main creates it under UILayer next to ToastUI. Polls at 2 Hz — the badge
## text carries a countdown, so it can't be purely event-driven.

const POLL_S := 0.5

var _accum := 0.0
var _chip: PanelContainer = null
var _lbl: Label = null
var _forced_showing := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_top = 8.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip = PanelContainer.new()
	_chip.add_theme_stylebox_override("panel",
		UITheme.chip_style(Color(0.14, 0.10, 0.06, 0.92)))
	_chip.mouse_filter = Control.MOUSE_FILTER_STOP
	_chip.visible = false
	_chip.gui_input.connect(_on_chip_input)
	_lbl = Label.new()
	_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_lbl.add_theme_color_override("font_color", Color(1.0, 0.82, 0.55))
	_chip.add_child(_lbl)
	add_child(_chip)
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw != null:
		if xw.has_signal("hazard_began"):
			xw.connect("hazard_began", _on_hazard_began)
		if xw.has_signal("hazard_ended"):
			xw.connect("hazard_ended", _on_hazard_ended)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < POLL_S:
		return
	_accum = 0.0
	_refresh()


func _refresh() -> void:
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw == null:
		_chip.visible = false
		return
	var forced: Dictionary = xw.call("forced_info") if xw.has_method("forced_info") else {}
	if not forced.is_empty():
		var remain := _sim_hours_remaining(float(forced.get("to_abs", 0.0)))
		var icon := HazardCatalog.icon(str(forced.get("id", "")))
		_lbl.text = "Previewing %s %s · %.2f · %s — click to clear" % [
			icon, str(forced.get("label", "")),
			float(forced.get("severity", 0.0)),
			("ends in %.1f h" % remain) if remain > 0.0 else "ending"]
		_forced_showing = true
		_chip.visible = true
		_center_chip()
		return
	_forced_showing = false
	var s: Dictionary = xw.call("current")
	var sev := float(s.get("severity", 0.0))
	var id := str(s.get("id", ""))
	if sev > 0.05 and not id.is_empty():
		_lbl.text = "%s %s · %s" % [HazardCatalog.icon(id),
			str(s.get("label", id)), _sev_word(sev)]
		_chip.visible = true
		_center_chip()
	else:
		_chip.visible = false


func _center_chip() -> void:
	# Anchored at top-center; shift the chip so its own middle sits there.
	_chip.position.x = -_chip.size.x * 0.5


static func _sev_word(sev: float) -> String:
	if sev >= 0.75:
		return "extreme"
	if sev >= 0.5:
		return "severe"
	if sev >= 0.25:
		return "moderate"
	return "light"


func _sim_hours_remaining(to_abs: float) -> float:
	var main := get_tree().get_first_node_in_group("main_scene")
	if main == null or not main.has_method("get_absolute_hours"):
		return 0.0
	return maxf(to_abs - float(main.call("get_absolute_hours")), 0.0)


func _on_chip_input(event: InputEvent) -> void:
	if not _forced_showing:
		return  # a REAL hazard is not dismissible
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var xw := get_node_or_null("/root/ExtremeWeather")
		if xw != null and xw.has_method("clear_forced"):
			xw.call("clear_forced")
		_refresh()


func _on_hazard_began(id: String, severity: float) -> void:
	_refresh()
	if not ExtremeWeatherPrefs.notify:
		return
	if severity < HazardCatalog.notify_threshold(id):
		return
	var main := get_tree().get_first_node_in_group("main_scene")
	if main != null and main.has_method("show_toast"):
		main.call("show_toast", "%s %s has begun (%s)" % [
			HazardCatalog.icon(id), HazardCatalog.display_name(id),
			_sev_word(severity)], ToastUI.Level.WARN, 6.0)


func _on_hazard_ended(id: String) -> void:
	_refresh()
	if not ExtremeWeatherPrefs.notify:
		return
	var main := get_tree().get_first_node_in_group("main_scene")
	if main != null and main.has_method("show_toast"):
		main.call("show_toast", "%s %s has ended" % [
			HazardCatalog.icon(id), HazardCatalog.display_name(id)],
			ToastUI.Level.INFO, 4.0)
