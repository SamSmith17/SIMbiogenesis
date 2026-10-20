extends CanvasLayer

## The FUCK YES! toast: a big green headline, upper centre, every time people
## hit PEAK EXPERIENCE — "+7 Peak Experience · Kit, Juno and 5 more at the
## Bass Stage". Brief: pops in (0.15 s), holds ~1.4 s, floats up and fades.
##
## A spreading peak can fire hundreds of onsets in a minute, so this never
## stacks: onsets that arrive while a toast is up MERGE into it (the count
## climbs, the headline re-pops, the hold is extended up to MAX_HOLD_S), and
## a NEW toast starts at most every MIN_GAP_S — a ripple through a crowd
## reads as a few escalating bursts, not a wall. Drains the population
## bridge's take_peak_events() at 4 Hz in real time; off-able (Settings ->
## NPCs, NpcDisplayPrefs.peak_toasts) — the score counts either way.

const POLL_S := 0.25
const POP_S := 0.15
const HOLD_S := 1.4
const MAX_HOLD_S := 3.2
const OUT_S := 0.4
const MIN_GAP_S := 5.0
const GREEN := Color(0.45, 1.0, 0.55)

var shown_onsets := 0           ## every onset this toast has displayed (harness)
var toasts_started := 0

var _root: Control = null
var _box: VBoxContainer = null
var _head: Label = null
var _detail: Label = null
var _accum := 0.0
var _phase := ""                ## "", "in", "hold", "out"
var _t := 0.0
var _hold_total := 0.0
var _since_start := 999.0
var _pending: Array = []
var _repop := 0.0
var _count := 0
var _names: Array = []
var _venues: Dictionary = {}
## The toast's headline peaker ({id, name, pos}), for click-to-look.
var _first: Dictionary = {}
var _hint: Label = null


func _ready() -> void:
	layer = UITheme.LAYER_TOAST
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_box = VBoxContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_box.add_theme_constant_override("separation", 2)
	_root.add_child(_box)
	_head = Label.new()
	_head.text = NpcPeak.LABEL
	_head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_head.add_theme_font_size_override("font_size", 44)
	_head.add_theme_color_override("font_color", Color(0.78, 1.0, 0.8))
	_head.add_theme_color_override("font_outline_color", Color(0.05, 0.35, 0.12, 0.95))
	_head.add_theme_constant_override("outline_size", 10)
	_head.add_theme_color_override("font_shadow_color", Color(0.3, 1.0, 0.45, 0.55))
	_head.add_theme_constant_override("shadow_offset_x", 0)
	_head.add_theme_constant_override("shadow_offset_y", 0)
	_head.add_theme_constant_override("shadow_outline_size", 22)
	_box.add_child(_head)
	_detail = Label.new()
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.add_theme_font_size_override("font_size", 15)
	_detail.add_theme_color_override("font_color", Color(0.9, 1.0, 0.92))
	_detail.add_theme_color_override("font_outline_color", Color(0.02, 0.12, 0.05, 0.9))
	_detail.add_theme_constant_override("outline_size", 5)
	_box.add_child(_detail)
	_hint = Label.new()
	_hint.text = "click to look"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75, 0.85))
	_hint.visible = false
	_box.add_child(_hint)
	# Clickable in the settlement view (the mouse is free there): fly to the
	# person the headline names.
	_box.gui_input.connect(_on_box_input)
	_box.modulate.a = 0.0
	_box.visible = false


func _process(delta: float) -> void:
	_since_start += delta
	_accum += delta
	if _accum >= POLL_S:
		_accum = 0.0
		_drain()
	if _phase.is_empty() and not _pending.is_empty() and _since_start >= MIN_GAP_S:
		_start(_pending)
		_pending = []
	_animate(delta)


func _drain() -> void:
	var b := _bridge()
	if b == null or not b.has_method("take_peak_events"):
		return
	var ev: Array = b.call("take_peak_events")
	if ev.is_empty():
		return
	if not NpcDisplayPrefs.peak_toasts():
		# No toast, but the beacon still marks where it happened (it folds
		# pings closer than its own gap).
		_beacon_ping(ev)
		return
	if (_phase == "in" or _phase == "hold") and _since_start < MAX_HOLD_S - 0.6:
		# Merge into the toast on screen: the count climbs and it re-pops,
		# its stay extended — but never past MAX_HOLD_S from its start (a
		# steady stream of onsets used to keep ONE toast up forever).
		_merge(ev)
		_repop = 1.0
		_hold_total = minf(_hold_total + 0.6, MAX_HOLD_S)
	else:
		_pending.append_array(ev)


func _start(ev: Array) -> void:
	_count = 0
	_names = []
	_venues = {}
	_merge(ev)
	_phase = "in"
	_t = 0.0
	_hold_total = HOLD_S
	_since_start = 0.0
	toasts_started += 1
	_box.visible = true
	# WHERE: a beacon over the person the headline names (PeakBeacon).
	_beacon_ping(ev)
	_first = ev[0] if not ev.is_empty() and ev[0] is Dictionary else {}
	_hint.visible = _settlement_open()
	# Only catches the mouse where clicking it means something (elsewhere a
	# free cursor — a tool dock — must not lose clicks under the toast).
	_box.mouse_filter = Control.MOUSE_FILTER_STOP if _hint.visible else Control.MOUSE_FILTER_IGNORE
	var sfx := get_node_or_null("/root/UiSound")
	if sfx != null:
		sfx.call("play_ui", UiSfx.SUCCESS, 2000)


func _merge(ev: Array) -> void:
	for e in ev:
		var d: Dictionary = e
		_count += 1
		shown_onsets += 1
		if _names.size() < 2:
			_names.append(str(d.get("name", "")))
		var v := str(d.get("venue", ""))
		if not v.is_empty():
			_venues[v] = int(_venues.get(v, 0)) + 1
	_detail.text = _detail_text()


func _detail_text() -> String:
	var top := ""
	var top_n := 0
	for v in _venues:
		if int(_venues[v]) > top_n:
			top_n = int(_venues[v])
			top = str(v)
	var at := (" at " + top) if not top.is_empty() else ""
	if _count == 1:
		return "%s hit %s%s" % [str(_names[0]) if not _names.is_empty() else "Someone", NpcPeak.LABEL, at]
	var who := ""
	if _names.size() >= 2:
		who = "%s, %s and %d more" % [_names[0], _names[1], _count - 2] if _count > 2 \
			else "%s and %s" % [_names[0], _names[1]]
	return "+%d Peak Experience · %s%s" % [_count, who, at]


func _animate(delta: float) -> void:
	if _phase.is_empty():
		return
	_t += delta
	var vp := _root.get_viewport_rect().size
	_box.reset_size()
	var base_y := vp.y * 0.16
	match _phase:
		"in":
			var k := clampf(_t / POP_S, 0.0, 1.0)
			var e := 1.0 - pow(1.0 - k, 3.0)
			_box.modulate.a = e
			_box.scale = Vector2.ONE * lerpf(0.8, 1.0, e)
			_box.position = Vector2((vp.x - _box.size.x) * 0.5, base_y)
			if k >= 1.0:
				_phase = "hold"
				_t = 0.0
		"hold":
			_box.modulate.a = 1.0
			_repop = maxf(_repop - delta * 5.0, 0.0)
			_box.scale = Vector2.ONE * (1.0 + 0.08 * _repop)
			_box.position = Vector2((vp.x - _box.size.x) * 0.5, base_y)
			if _since_start >= POP_S + _hold_total:
				_phase = "out"
				_t = 0.0
		"out":
			var k2 := clampf(_t / OUT_S, 0.0, 1.0)
			_box.modulate.a = 1.0 - k2
			_box.position = Vector2((vp.x - _box.size.x) * 0.5, base_y - 24.0 * k2)
			if k2 >= 1.0:
				_phase = ""
				_box.visible = false
	_box.pivot_offset = _box.size * 0.5


func _beacon_ping(ev: Array) -> void:
	var scene := get_tree().current_scene if get_tree() != null else null
	var beacon := scene.get_node_or_null("PeakBeacon") if scene != null else null
	if beacon != null and beacon.has_method("ping"):
		beacon.call("ping", ev)


func _settlement_open() -> bool:
	var scene := get_tree().current_scene if get_tree() != null else null
	var sv: Variant = scene.get("settlement_view") if scene != null and "settlement_view" in scene else null
	return sv is Node and is_instance_valid(sv) and (sv as Node).call("is_open")


## Click the toast (settlement view): fly there and pick the person.
func _on_box_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed \
			or (event as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
		return
	if _first.is_empty() or not _settlement_open():
		return
	var scene := get_tree().current_scene
	var sv: Node = scene.get("settlement_view")
	if sv.has_method("look_at_person"):
		sv.call("look_at_person", str(_first.get("id", "")), _first.get("pos", Vector2.ZERO))
	_box.accept_event()


func _bridge() -> Object:
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return null
	return sgv.call("npc_population_bridge")


## Is a toast on screen right now? (harness)
func showing() -> bool:
	return not _phase.is_empty()
