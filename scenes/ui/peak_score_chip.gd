extends Control

## The PEAK EXPERIENCE score (top centre, under the festival vibe chip):
## "✦ PEAK EXPERIENCES 1,284 · 46 now · ⚡ 23 close · 120 today" ("close" =
## people more than halfway charged — the wave about to break). Every onset
## anywhere on site bumps it — the number counts up, the chip pops and
## flashes green. Polls the population bridge (peak_score()) at 4 Hz; visible
## while anybody is simulating. Main creates it under UILayer.

const POLL_S := 0.25
const COUNT_UP_S := 0.4
const GREEN := Color(0.45, 1.0, 0.55)

var _accum := 0.0
var _chip: PanelContainer = null
var _star: Label = null
var _num: Label = null
var _sub: Label = null
var _shown := 0.0
var _target := 0
var _now := 0
var _today := 0
var _flash := 0.0
var _known := -1


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_top = 66.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip = PanelContainer.new()
	_chip.add_theme_stylebox_override("panel", UITheme.chip_style(Color(0.05, 0.12, 0.07, 0.92)))
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip.visible = false
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_chip.add_child(row)
	_star = Label.new()
	_star.text = "✦ PEAK EXPERIENCES"
	_star.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_star.add_theme_color_override("font_color", GREEN)
	row.add_child(_star)
	_num = Label.new()
	_num.add_theme_font_size_override("font_size", UITheme.FONT_SM + 2)
	_num.add_theme_color_override("font_color", Color(0.85, 1.0, 0.88))
	_num.add_theme_color_override("font_outline_color", Color(0.1, 0.5, 0.2, 0.8))
	_num.add_theme_constant_override("outline_size", 4)
	row.add_child(_num)
	_sub = Label.new()
	_sub.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_sub.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	row.add_child(_sub)
	add_child(_chip)
	HudLayout.register(_chip, "peak_score", "top_center", {"order": 2, "tuckable": false,
		"size": func() -> Vector2: return _chip.get_combined_minimum_size()})


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= POLL_S:
		_accum = 0.0
		_refresh()
	if not _chip.visible:
		return
	# Count up toward the target.
	if absf(_shown - float(_target)) > 0.01:
		var step := maxf(absf(float(_target) - _shown) * delta / COUNT_UP_S, delta * 4.0)
		_shown = move_toward(_shown, float(_target), step)
		_num.text = _fmt(int(round(_shown)))
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 2.2, 0.0)
		var s := 1.0 + 0.12 * sin(_flash * PI) * _flash
		_chip.scale = Vector2(s, s)
		_chip.modulate = Color(1.0, 1.0, 1.0).lerp(Color(0.75, 1.6, 0.85), _flash)
	_chip.pivot_offset = _chip.size * 0.5
	# Placed by the HUD layout manager's top-centre row (registered in _ready).
	var h := HudLayout.get_hud()
	if h != null:
		h.queue_layout()
	else:
		_chip.position.x = -_chip.size.x * 0.5


func _refresh() -> void:
	var b := _bridge()
	if not NpcDisplayPrefs.npcs_enabled() or b == null or not b.has_method("peak_score") \
			or not bool(b.call("active")):
		_chip.visible = false
		return
	var sc: Dictionary = b.call("peak_score")
	var total := int(sc.get("total", 0))
	if _known >= 0 and total > _known:
		_flash = 1.0
	if _known < 0:
		_shown = float(total)
		_num.text = _fmt(total)
	_known = total
	_target = total
	_now = int(sc.get("now", 0))
	_today = int(sc.get("today", 0))
	var close := int(b.call("peak_building", 0.5)) if b.has_method("peak_building") else 0
	_sub.text = "·  %d now  ·  %s%s today" % [_now,
		("⚡ %d close  ·  " % close) if close > 0 else "", _fmt(_today)]
	_sub.tooltip_text = "now: at FUCK YES!!!  ·  close: more than halfway charged (the green outline)  ·  today: onsets this sim-day"
	_chip.visible = true
	_chip.reset_size()


func _bridge() -> Object:
	var scene := get_tree().current_scene if get_tree() != null else null
	var sgv := scene.get_node_or_null("UILayer/SystemGraphView") if scene != null else null
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return null
	return sgv.call("npc_population_bridge")


## 1284 -> "1,284".
static func _fmt(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
