class_name TimeUseBars
extends Control

## How a camp spends its day (NpcTimeUse.summary), drawn two ways:
##   - "groups": one row per ATUS-style group, hours a day, with the American
##     Time Use Survey's average as a tick (a reference, not a target);
##   - "people": one 24-hour stacked bar per person, by category.
## Both start with the camp's average day as one stacked bar and its key.
## Hover a segment for its hours.

const ROW_H := 22.0
const BAR_H := 14.0
const LABEL_W := 170.0
const VALUE_W := 150.0
const HEAD_H := 54.0
const GROUP_MAX_H := 12.0

var mode := "groups"
## Draw the average day and its key above the rows.
var show_head := true
var _s: Dictionary = {}
var _hover := ""
var _font: Font = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	_font = UITheme.font("regular", true)


func set_summary(s: Dictionary) -> void:
	_s = s
	var rows := (s.get("groups", []) as Array).size() if mode == "groups" else (s.get("per_person", []) as Array).size()
	custom_minimum_size = Vector2(420, _head_h() + rows * ROW_H + 6)
	queue_redraw()


func _head_h() -> float:
	return HEAD_H if show_head else 0.0


func _bar_x0() -> float:
	return LABEL_W


func _bar_w() -> float:
	return maxf(size.x - LABEL_W - VALUE_W, 60.0)


func _draw() -> void:
	if _s.is_empty():
		return
	var f := _font if _font != null else get_theme_default_font()
	var fs := UITheme.FONT_XS
	# The camp's average day.
	var mean: Dictionary = _s.get("mean", {})
	var y := _head_h()
	if not show_head:
		_draw_rows(f, fs, mean, y)
		return
	draw_string(f, Vector2(0, 14), "Average day", HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 6, fs, UITheme.C_TEXT_S)
	_draw_stack(mean, Rect2(_bar_x0(), 3, _bar_w(), BAR_H), "avg")
	# Key.
	var kx := 0.0
	for c in NpcTimeUse.CATS:
		if float(mean.get(c, 0.0)) < 0.05:
			continue
		var t := "%s %s" % [NpcTimeUse.LABELS[c], UiText.duration(float(mean[c]))]
		var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if kx + w + 18 > size.x:
			break
		draw_rect(Rect2(kx, 26, 9, 9), NpcTimeUse.COLORS[c])
		draw_string(f, Vector2(kx + 12, 35), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_S)
		kx += w + 22
	_draw_rows(f, fs, mean, y)


func _draw_rows(f: Font, fs: int, mean: Dictionary, y: float) -> void:
	if mode == "groups":
		for g in _s.get("groups", []):
			var gd: Dictionary = g
			draw_string(f, Vector2(0, y + 14), str(gd["label"]), HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 6, fs, UITheme.C_TEXT)
			var r := Rect2(_bar_x0(), y + 3, _bar_w(), BAR_H)
			draw_rect(r, Color(1, 1, 1, 0.05))
			var x := r.position.x
			for c in gd["cats"]:
				var w := r.size.x * float(mean.get(c, 0.0)) / GROUP_MAX_H
				draw_rect(Rect2(x, r.position.y, minf(w, r.end.x - x), BAR_H), NpcTimeUse.COLORS[c])
				x += w
			var ref := float(gd["ref"])
			var val := UiText.duration(float(gd["h"]))
			if ref >= 0.0:
				var rx := r.position.x + r.size.x * minf(ref / GROUP_MAX_H, 1.0)
				draw_line(Vector2(rx, r.position.y - 3), Vector2(rx, r.end.y + 3), UITheme.C_TEXT, 2.0)
				val += "  (ATUS %s)" % UiText.duration(ref)
			draw_string(f, Vector2(r.end.x + 8, y + 14), val, HORIZONTAL_ALIGNMENT_LEFT, VALUE_W - 8, fs, UITheme.C_TEXT_S)
			y += ROW_H
	else:
		for p in _s.get("per_person", []):
			var pd: Dictionary = p
			draw_string(f, Vector2(0, y + 14), str(pd.get("name", pd["id"])), HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 6, fs, UITheme.C_TEXT)
			_draw_stack(pd["hours"], Rect2(_bar_x0(), y + 3, _bar_w(), BAR_H), str(pd["id"]))
			var h: Dictionary = pd["hours"]
			draw_string(f, Vector2(_bar_x0() + _bar_w() + 8, y + 14), "work %s · sleep %s" % [
				UiText.duration(float(h.get("work", 0.0))), UiText.duration(float(h.get("sleep", 0.0)))],
				HORIZONTAL_ALIGNMENT_LEFT, VALUE_W - 8, fs, UITheme.C_TEXT_S)
			y += ROW_H


func _draw_stack(hours: Dictionary, r: Rect2, key: String) -> void:
	draw_rect(r, Color(1, 1, 1, 0.05))
	var x := r.position.x
	for c in NpcTimeUse.CATS:
		var w := r.size.x * float(hours.get(c, 0.0)) / 24.0
		if w <= 0.0:
			continue
		var col: Color = NpcTimeUse.COLORS[c]
		if _hover == "%s|%s" % [key, c]:
			col = col.lightened(0.3)
		draw_rect(Rect2(x, r.position.y, w, r.size.y), col)
		x += w


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		var hit := _hit((ev as InputEventMouseMotion).position)
		if hit != _hover:
			_hover = hit
			tooltip_text = _tip(hit)
			queue_redraw()


func _hit(p: Vector2) -> String:
	if p.x < _bar_x0() or p.x > _bar_x0() + _bar_w():
		return ""
	var hours: Dictionary = {}
	var key := ""
	if show_head and p.y < HEAD_H:
		if p.y > 3.0 + BAR_H:
			return ""
		hours = _s.get("mean", {})
		key = "avg"
	elif mode == "people":
		var i := int((p.y - _head_h()) / ROW_H)
		var pp: Array = _s.get("per_person", [])
		if i < 0 or i >= pp.size():
			return ""
		hours = pp[i]["hours"]
		key = str(pp[i]["id"])
	else:
		return ""
	var x := _bar_x0()
	for c in NpcTimeUse.CATS:
		x += _bar_w() * float(hours.get(c, 0.0)) / 24.0
		if p.x <= x:
			return "%s|%s" % [key, c]
	return ""


func _tip(hit: String) -> String:
	if hit.is_empty():
		return ""
	var key := hit.get_slice("|", 0)
	var c := hit.get_slice("|", 1)
	var hours: Dictionary = _s.get("mean", {})
	var who := "Average"
	if key != "avg":
		for p in _s.get("per_person", []):
			if str(p["id"]) == key:
				hours = p["hours"]
				who = str(p.get("name", key))
	return "%s: %s %s a day" % [who, NpcTimeUse.LABELS[c], UiText.duration(float(hours.get(c, 0.0)))]
