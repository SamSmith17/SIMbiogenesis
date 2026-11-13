class_name WaterfallChart
extends Control

## A waterfall / budget chart (plans/FLOW_VIZ_PLAN.md Part D): a starting
## amount, what was added and taken away step by step, and where it ended.
## Horizontal rows so the step names read in full. Start and total bars are
## neutral; additions and losses take the diverging pair (blue, red) and
## every bar is labelled with its signed value, so colour is never the only
## carrier. A thin connector carries the running total from row to row.
##
##   set_steps([{label, value, kind start|add|sub|total}], fmt: Callable(v))

const ROW_H := 24.0
const LABEL_W := 168.0
const VALUE_W := 74.0
const C_NEUTRAL := Color("#8f9bb0")
const C_ADD := Color("#3987e5")
const C_SUB := Color("#d03b3b")

var steps: Array = []
var fmt: Callable = Callable()
var _spans: Array = []
var _hover := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(func() -> void:
		_hover = -1
		queue_redraw())


func set_steps(s: Array, f: Callable = Callable()) -> void:
	steps = s
	fmt = f
	_spans = PatternData.waterfall_spans(s)
	custom_minimum_size.y = maxf(ROW_H * float(maxi(s.size(), 1)) + 8.0, 40.0)
	update_minimum_size()
	queue_redraw()


func _value_text(v: float) -> String:
	return str(fmt.call(v)) if fmt.is_valid() else "%.3g" % v


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var i := int(((event as InputEventMouseMotion).position.y - 4.0) / ROW_H)
		var h := i if i >= 0 and i < steps.size() else -1
		if h != _hover:
			_hover = h
			queue_redraw()


func _draw() -> void:
	var font := UITheme.font("regular", true)
	if steps.is_empty():
		draw_string(font, Vector2(8, 18), "Nothing to show yet.", HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_SM, UITheme.C_TEXT_M)
		return
	var top := 0.0
	for sp in _spans:
		top = maxf(top, maxf(float(sp["from"]), float(sp["to"])))
	top = maxf(top, 1e-9)
	var x0 := LABEL_W
	var w := maxf(size.x - LABEL_W - VALUE_W - 8.0, 20.0)
	var px := func(v: float) -> float: return x0 + clampf(v / top, 0.0, 1.0) * w
	for i in steps.size():
		var s: Dictionary = steps[i]
		var sp: Dictionary = _spans[i]
		var y := 4.0 + float(i) * ROW_H
		var kind := str(s.get("kind", "add"))
		if i == _hover:
			draw_rect(Rect2(0.0, y, size.x, ROW_H), Color(UITheme.C_PANEL_RAISED, 0.6))
		var col := C_NEUTRAL
		var sg := ""
		if kind == "add":
			col = C_ADD
			sg = "+"
		elif kind == "sub":
			col = C_SUB
			sg = "−"
		var a := float(px.call(minf(float(sp["from"]), float(sp["to"]))))
		var b := float(px.call(maxf(float(sp["from"]), float(sp["to"]))))
		var bar := Rect2(a, y + 4.0, maxf(b - a, 2.0), ROW_H - 8.0)
		draw_rect(bar, col)
		var ink := UITheme.C_TEXT if kind == "start" or kind == "total" else UITheme.C_TEXT_S
		draw_string(font, Vector2(4.0, y + ROW_H * 0.5 + 5.0), str(s.get("label", "")),
			HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 10.0, UITheme.FONT_SM, ink)
		draw_string(font, Vector2(x0 + w + 8.0, y + ROW_H * 0.5 + 5.0),
			sg + _value_text(float(s.get("value", 0.0))), HORIZONTAL_ALIGNMENT_LEFT, VALUE_W,
			UITheme.FONT_SM, ink)
		# The running total carried down to the next row.
		if i + 1 < steps.size():
			var run_x := float(px.call(float(sp["to"]) if kind != "sub" else float(sp["from"])))
			draw_line(Vector2(run_x, y + ROW_H - 4.0), Vector2(run_x, y + ROW_H + 4.0),
				Color(UITheme.C_TEXT_M, 0.8), 1.0)
	draw_line(Vector2(x0, 2.0), Vector2(x0, 4.0 + ROW_H * float(steps.size())), Color(UITheme.C_BORDER, 0.8), 1.0)
