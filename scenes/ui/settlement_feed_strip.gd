extends Control

## The settlement log, in first person: a few quiet fading lines at the edge
## of the screen, so "what happened while I fast-forwarded" is answerable
## without opening anything. The settlement view has its own feed panel and
## the graph has toasts, so this strip shows ONLY when neither of those
## surfaces is up — it is the first-person leg of the quiet-alarm channel.
##
## Reads the log through its own named cursor ("fp_strip"), so it can never
## starve the graph toast or the challenge bake's collapse watcher. Lines
## expire on REAL time (a line that arrived during a 400× fast-forward should
## still be readable when the player drops back to 1×).
##
## Quiet by design: no sound, nothing to dismiss, mouse ignored.
## No class_name — the ui_compile selftest sweeps scenes/ui/.

const POLL_S := 0.5
const LINE_TTL_S := 24.0
const MAX_LINES := 4

var _bridge: Variant = null
## The graph view — the strip hides while it is visible (toasts own that
## surface) and while the settlement view is open (its feed panel does).
var _graph_view: CanvasItem = null
var _lines: Array = []   # [{text, sev, at_ms}]
var _box: VBoxContainer = null
var _accum := 0.0
var _sig := "<unbuilt>"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = 14
	offset_right = 434
	offset_top = -352
	offset_bottom = -186
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 1)
	_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.alignment = BoxContainer.ALIGNMENT_END
	_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_box)


func bind(bridge: Variant, graph_view: CanvasItem) -> void:
	_bridge = bridge
	_graph_view = graph_view


func _process(delta: float) -> void:
	_accum += delta
	if _accum < POLL_S:
		return
	_accum = 0.0
	if _bridge == null or not _bridge.has_method("log_since"):
		visible = false
		return
	var now := Time.get_ticks_msec()
	for e in (_bridge.call("log_since", "fp_strip") as Array):
		var ed: Dictionary = e
		_lines.append({
			"text": str(ed.get("text", "")),
			"sev": int(ed.get("severity", 0)),
			"at_ms": now,
		})
	while _lines.size() > MAX_LINES:
		_lines.pop_front()
	for i in range(_lines.size() - 1, -1, -1):
		if now - int((_lines[i] as Dictionary)["at_ms"]) > LINE_TTL_S * 1000.0:
			_lines.remove_at(i)
	# Hide wherever another surface already carries the feed.
	var covered := _graph_view != null and _graph_view.visible
	var main := get_tree().current_scene
	if not covered and main != null and main.has_method("settlement_view_open"):
		covered = bool(main.call("settlement_view_open"))
	visible = not covered and not _lines.is_empty()
	if not visible:
		return
	var sig := ""
	for l in _lines:
		sig += "%d;" % int((l as Dictionary)["at_ms"])
	if sig == _sig:
		# Content unchanged; only refresh the fades.
		var idx := 0
		for c in _box.get_children():
			if idx < _lines.size():
				(c as Control).modulate.a = _alpha_of(_lines[idx] as Dictionary, now)
			idx += 1
		return
	_sig = sig
	for c in _box.get_children():
		c.queue_free()
	for l in _lines:
		var ld: Dictionary = l
		var lbl := Label.new()
		lbl.text = str(ld["text"])
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		lbl.add_theme_color_override("font_color",
			UITheme.C_WARN if int(ld["sev"]) >= SettlementLog.ALERT else UITheme.C_TEXT_S)
		# A thin outline instead of a panel: the strip sits over the world and
		# a backing rect would read as UI chrome in the middle of a landscape.
		lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		lbl.add_theme_constant_override("outline_size", 3)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.modulate.a = _alpha_of(ld, now)
		_box.add_child(lbl)


static func _alpha_of(line: Dictionary, now_ms: int) -> float:
	var age_s := float(now_ms - int(line["at_ms"])) / 1000.0
	# Full strength for most of the life, then a gentle last-quarter fade.
	return clampf(1.0 - maxf(age_s - LINE_TTL_S * 0.75, 0.0)
		/ (LINE_TTL_S * 0.25), 0.0, 1.0)
