class_name GlobeZoneBar
extends Control

## Compact 16 px horizontal spark-bar showing humanity's distribution across
## the 6 Solar Energy Zones, plus static helpers for concise, low-clutter
## Energy Zone summaries in GlobeMode.

signal zone_clicked(zone_id: int)

const DIFFICULTY := [
	"",
	"Extremely Difficult",
	"Difficult",
	"Hard",
	"Average",
	"Easy",
	"Easy · Very Hot",
]

const SHORT_HINTS := [
	"",
	"Heavy seasonal storage or backup power needed",
	"Cloudy winters make storage & efficiency key",
	"Four seasons — size arrays for winter dips",
	"Balanced year-round sun for daily cycling",
	"Abundant sun; modest batteries close the loop",
	"Peak desert sun, paired with cooling & water loads",
]

var active_zone_id := 0
var _hovered_zone := 0
var _rects: Array[Rect2] = []
var _zones: Array = []
var _shares: PackedFloat32Array = PackedFloat32Array()


func _init() -> void:
	custom_minimum_size = Vector2(0, 18)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _ready() -> void:
	mouse_exited.connect(func() -> void:
		if _hovered_zone != 0:
			_hovered_zone = 0
			queue_redraw())
	refresh(active_zone_id)


static func difficulty_of(zone_id: int) -> String:
	return DIFFICULTY[zone_id] if zone_id >= 1 and zone_id < DIFFICULTY.size() else ""


static func short_hint_of(zone_id: int) -> String:
	return SHORT_HINTS[zone_id] if zone_id >= 1 and zone_id < SHORT_HINTS.size() else ""


static func compact_pop(n: int) -> String:
	if n >= 1_000_000_000:
		return "%.2fB" % (float(n) / 1_000_000_000.0)
	if n >= 1_000_000:
		return "%.0fM" % (float(n) / 1_000_000.0)
	return UiText.thousands(n)


static func pop_summary_line(ghi: Node, zone_id: int) -> String:
	var hint := short_hint_of(zone_id)
	if ghi == null or zone_id < 1 or not bool(ghi.call("is_population_data_loaded")):
		return hint
	var count := int(ghi.call("zone_population_by_id", zone_id))
	var total := int(ghi.call("world_population_total"))
	if total <= 0:
		return hint
	var pct := roundi(100.0 * float(count) / float(total))
	return "%s people (%d%% of Earth) · %s" % [compact_pop(count), pct, hint]


func refresh(zone_id: int) -> void:
	active_zone_id = zone_id
	var ghi := get_node_or_null("/root/GhiService")
	_zones = []
	_shares.clear()
	if ghi != null and ghi.has_method("get_zones"):
		_zones = (ghi.call("get_zones") as Array).duplicate()
		var loaded := bool(ghi.call("is_population_data_loaded"))
		var total := int(ghi.call("world_population_total")) if loaded else 0
		var by_z: Dictionary = ghi.call("get_population_by_zone") if loaded else {}
		for z in _zones:
			var zid := int((z as Dictionary).get("id", 0))
			if total > 0:
				var p := float(int(by_z.get(str(zid), 0))) / float(total)
				_shares.append(maxf(p, 0.035))
			else:
				_shares.append(1.0 / 6.0)
		if loaded and total > 0:
			var parts := PackedStringArray()
			for z2 in _zones:
				var zd: Dictionary = z2
				var zid2 := int(zd.get("id", 0))
				var cnt := int(by_z.get(str(zid2), 0))
				var pct := roundi(100.0 * float(cnt) / float(total))
				parts.append("Zone %d (%s): %s (%d%%)" % [zid2, difficulty_of(zid2), compact_pop(cnt), pct])
			tooltip_text = "World population by Solar Energy Zone — click a band to inspect:\n" + "\n".join(parts)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var p := (event as InputEventMouseMotion).position
		var h := _zone_at_pos(p)
		if h != _hovered_zone:
			_hovered_zone = h
			queue_redraw()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var z := _zone_at_pos(mb.position)
			if z >= 1:
				zone_clicked.emit(z)
				accept_event()


func _zone_at_pos(p: Vector2) -> int:
	for i in _rects.size():
		if _rects[i].grow(2.0).has_point(p) and i < _zones.size():
			return int((_zones[i] as Dictionary).get("id", 0))
	return 0


func _draw() -> void:
	_rects.clear()
	if _zones.is_empty() or size.x < 20.0:
		return
	var sum_s := 0.0
	for s in _shares:
		sum_s += s
	if sum_s <= 0.0:
		return
	var gap := 2.0
	var avail_w := maxf(size.x - gap * float(_zones.size() - 1), 12.0)
	var x := 0.0
	for i in _zones.size():
		var zd: Dictionary = _zones[i]
		var zid := int(zd.get("id", 0))
		var col: Color = zd.get("color", Color.GRAY)
		var w := avail_w * (_shares[i] / sum_s)
		var is_act := zid == active_zone_id
		var is_hov := zid == _hovered_zone
		var h := 14.0 if (is_act or is_hov) else 8.0
		var y := (size.y - h) * 0.5
		var r := Rect2(Vector2(x, y), Vector2(maxf(w, 4.0), h))
		_rects.append(r)
		var draw_col := col if (is_act or is_hov) else Color(col.r, col.g, col.b, 0.68)
		draw_rect(r, draw_col, true)
		if is_act:
			draw_rect(r.grow(1.0), Color.WHITE, false, 1.5)
		elif is_hov:
			draw_rect(r.grow(0.5), Color(UITheme.C_PRIMARY, 0.9), false, 1.0)
		x += w + gap
