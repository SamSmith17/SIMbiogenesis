extends Node

## "Where it goes" (resource composition plan Phase 4): one element followed
## through the site as a Sankey, over a window of sim time the systems graph
## recorded (ElementHistory) or as it flows right now. Opened from the graph's
## Show ▾ → Where it goes…, and from the dashboard's water & nutrients card.
##
##   open_for(view, lens, scope)  view = SystemGraphView

const SankeyView := preload("res://scenes/ui/element_sankey_view.gd")
const LoopView := preload("res://scenes/ui/loop_sankey_view.gd")
const WINDOWS := [
	{"id": "now", "label": "Right now (per hour)", "h": 0.0},
	{"id": "24h", "label": "The last 24 hours", "h": 24.0},
	{"id": "7d", "label": "The last 7 days", "h": 168.0},
	{"id": "all", "label": "Everything recorded", "h": -1.0},
]

var _view: Node = null
var _scope := "root"
var _lens := "N"
var _window := "24h"
var _frame: ModalFrame = null
var _lens_opt: OptionButton = null
var _win_opt: OptionButton = null
var _summary: Label = null
var _note: Label = null
var _hover: Label = null
var _sankey: Control = null
## The loop picture (LoopSankeyLayout): material cycles drawn as loops.
var _loops: Control = null
var _picture := "loops"
var _pic_opt: OptionButton = null


func open_for(view: Node, lens: String, scope: String = "root") -> void:
	_view = view
	_lens = lens if ElementLens.is_lens(lens) else "N"
	_scope = scope
	_build()
	_frame.open()
	_refresh()


func _build() -> void:
	_frame = ModalFrame.create("Where it goes", "Follow one element through the site",
		Vector2(1180, 760), "element_sankey")
	_frame.content_max_w = 0.0
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_frame.body.add_child(row)
	var l1 := Label.new()
	l1.text = "Follow"
	row.add_child(l1)
	_lens_opt = OptionButton.new()
	for i in ElementLens.LENSES.size():
		_lens_opt.add_item(str(ElementLens.LENSES[i]["label"]), i)
		if str(ElementLens.LENSES[i]["id"]) == _lens:
			_lens_opt.select(i)
	_lens_opt.name = "lens"
	_lens_opt.item_selected.connect(func(i: int) -> void:
		_lens = str(ElementLens.LENSES[i]["id"])
		_refresh())
	row.add_child(_lens_opt)
	var l2 := Label.new()
	l2.text = "over"
	row.add_child(l2)
	_win_opt = OptionButton.new()
	for j in WINDOWS.size():
		_win_opt.add_item(str(WINDOWS[j]["label"]), j)
		if str(WINDOWS[j]["id"]) == _window:
			_win_opt.select(j)
	_win_opt.name = "window"
	_win_opt.item_selected.connect(func(j: int) -> void:
		_window = str(WINDOWS[j]["id"])
		_refresh())
	row.add_child(_win_opt)
	var l3 := Label.new()
	l3.text = "as"
	row.add_child(l3)
	_pic_opt = OptionButton.new()
	_pic_opt.name = "picture"
	_pic_opt.add_item("Loops (cycles come back up the sides)", 0)
	_pic_opt.add_item("Columns (from → through → to)", 1)
	_pic_opt.select(0 if _picture == "loops" else 1)
	_pic_opt.item_selected.connect(func(k: int) -> void:
		_picture = "loops" if k == 0 else "columns"
		_refresh())
	row.add_child(_pic_opt)
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_color_override("font_color", UITheme.C_TEXT)
	_frame.body.add_child(_summary)
	_sankey = SankeyView.new()
	_sankey.name = "sankey"
	_sankey.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sankey.custom_minimum_size = Vector2(900, 480)
	_frame.body.add_child(_sankey)
	_loops = LoopView.new()
	_loops.name = "loops"
	_loops.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_loops.custom_minimum_size = Vector2(900, 480)
	_frame.body.add_child(_loops)
	_frame.body.move_child(_loops, _sankey.get_index())
	_hover = Label.new()
	_hover.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hover.text = "Point at a bar or a ribbon to see what it carries."
	_frame.body.add_child(_hover)
	_sankey.connect("hovered", func(t: String) -> void:
		_hover.text = t if not t.is_empty() else "Point at a bar or a ribbon to see what it carries.")
	_loops.connect("hovered", func(t: String) -> void:
		_hover.text = t if not t.is_empty() else "Point at a ribbon: what cycles back runs up the sides.")
	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_note.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_frame.body.add_child(_note)
	_frame.add_button("Close", ModalFrame.PRIMARY, _frame.close)


func _refresh() -> void:
	if _view == null or not is_instance_valid(_view):
		return
	var led: Dictionary = _view.call("element_ledger", _scope)
	var hist: ElementHistory = _view.call("element_history")
	var w: Dictionary = {}
	var rate := true
	var note := ""
	var span := 0.0
	for wd in WINDOWS:
		if str(wd["id"]) == _window:
			span = float(wd["h"])
	if span != 0.0 and hist != null and not is_nan(hist.last_hour()):
		var t1 := hist.last_hour()
		var t0 := t1 - span if span > 0.0 else -INF
		w = hist.window(t0, t1 + 1e-6)
		rate = false
		if float(w["hours"]) < 0.05:
			w = {}
			note = "Nothing recorded over that window yet (the record runs while the clock does), so this is what flows right now."
		elif span > 0.0 and float(w["hours"]) < span * 0.95:
			note = "Recorded over %s of sim time so far." % UiText.duration(float(w["hours"]))
	if w.is_empty():
		w = ElementHistory.from_ledger(led)
		rate = true
	if _scope != "root":
		note = ("Inside this system only. " + note).strip_edges()
	var names: Dictionary = hist.names.duplicate() if hist != null else {}
	for id in (led.get("nodes", {}) as Dictionary).keys():
		names[str(id)] = str(led["nodes"][id].get("name", id))
	for s in led.get("stores", []):
		names[str(s["id"])] = str(s["name"])
	# Inside a camp or a vehicle, name the system too: ten "Blackwater Tank"
	# rows say nothing.
	var model: GraphModel = _view.get("model")
	if model != null:
		for id2 in names.keys():
			var it := model.get_item(str(id2))
			if it.is_empty():
				continue
			var isl := GraphSystems.island_of(model, it)
			if isl.is_empty():
				continue
			var owner := model.get_item(isl)
			var sys_name := str((owner.get("specs", {}) as Dictionary).get("name", ""))
			if not sys_name.is_empty() and not str(names[id2]).begins_with(sys_name):
				names[id2] = "%s · %s" % [sys_name, str(names[id2])]
	var node_ids: Dictionary = led.get("nodes", {})
	var cross := {}
	if _scope != "root" and not rate:
		# The history is the whole site's: keep what touches this system.
		var root_led: Dictionary = _view.call("element_ledger", "root")
		node_ids = root_led.get("nodes", {})
		var r := _scope_window(w)
		w = r["w"]
		cross = r["cross"]
	var sk := ElementSankey.build(w, _lens, node_ids, names)
	_sankey.call("set_data", sk, _lens, rate)
	_sankey.visible = _picture == "columns"
	_loops.visible = _picture == "loops"
	if _picture == "loops":
		var lens_id := _lens
		var li := ElementSankey.loop_input(w, _lens, names)
		_loops.call("set_input", li,
			func(_k: String, v: float) -> String:
				return ElementLens.fmt_rate(v, lens_id) if rate else ElementLens.fmt_amount(v, lens_id),
			func(_k: String) -> Color: return ElementLens.color(lens_id),
			func(_k: String) -> String: return ElementLens.label(lens_id))
		var lay: Dictionary = (_loops.get("lens") as GraphFlowLens).cur
		var m: Dictionary = lay.get("metrics", {})
		for mk in m:
			var fci := float((m[mk] as Dictionary).get("fci", 0.0))
			var nl := int((m[mk] as Dictionary).get("loops", 0))
			note = ("%s: %d %% of what flows cycles back (Finn's cycling index)%s. " % [
				ElementLens.label(_lens), int(round(fci * 100.0)),
				(", " + UiText.count(nl, "loop")) if nl > 0 else ", no loops"]) + note
	_summary.text = _summary_text(w, rate) if _scope == "root" or rate else _cross_text(cross)
	_note.text = note + ("\n" if not note.is_empty() else "") \
		+ "Stores drawn on the left give it out; on the right they take it in. Amounts come from each kind's listed make-up; estimates are marked in the inspector."
	_frame.set_title("Where the %s goes" % ElementLens.label(_lens).to_lower(),
		"The whole site" if _scope == "root" else "Inside this system")


## A site-wide window cut down to the items inside this system (and the
## wires that cross its edge); `cross` = what crosses that edge, in / out.
func _scope_window(w: Dictionary) -> Dictionary:
	var model: GraphModel = _view.get("model")
	var inside: Dictionary = {}
	for it in GraphNesting.walk_items(model, _scope):
		inside[str((it as Dictionary).get("id", ""))] = true
	var out := w.duplicate()
	var edges: Dictionary = {}
	var ends: Dictionary = {}
	var li := int(ElementLens.INDEX[_lens])
	var c_in := 0.0
	var c_out := 0.0
	for k in (w.get("edges", {}) as Dictionary).keys():
		var e: Array = w["ends"][k]
		var a_in := inside.has(str(e[0]))
		var b_in := inside.has(str(e[1]))
		if not a_in and not b_in:
			continue
		edges[k] = w["edges"][k]
		ends[k] = e
		var v := float((w["edges"][k] as PackedFloat64Array)[li])
		if b_in and not a_in:
			c_in += v
		elif a_in and not b_in:
			c_out += v
	out["edges"] = edges
	out["ends"] = ends
	for key in ["node_air_out", "node_air_in", "node_dumped"]:
		var d: Dictionary = {}
		for id in (w.get(key, {}) as Dictionary).keys():
			if inside.has(str(id)):
				d[id] = w[key][id]
		out[key] = d
	return {"w": out, "cross": {"in": c_in, "out": c_out}}


func _cross_text(cross: Dictionary) -> String:
	var ci := float(cross.get("in", 0.0))
	var co := float(cross.get("out", 0.0))
	if ci <= 1e-9 and co <= 1e-9:
		return "Nothing crosses this system's edge in %s." % ElementLens.label(_lens).to_lower()
	return "Across this system's edge: %s in · %s out." % [ElementLens.fmt_amount(ci, _lens),
		ElementLens.fmt_amount(co, _lens)]


func _summary_text(w: Dictionary, rate: bool) -> String:
	var li := int(ElementLens.INDEX[_lens])
	var parts := PackedStringArray()
	var fmt := func(v: float) -> String:
		return ElementLens.fmt_rate(v, _lens) if rate else ElementLens.fmt_amount(v, _lens)
	var pairs := [["rain", "with the rain"], ["imports", "brought in"], ["air_in", "taken from the air"],
		["air_out", "given to the air"], ["dumped", "drained off site"], ["exports", "sent off site"]]
	for p in pairs:
		var v := float((w.get(p[0], PackedFloat64Array()) as PackedFloat64Array)[li]) \
			if (w.get(p[0], PackedFloat64Array()) as PackedFloat64Array).size() > li else 0.0
		if v > 1e-9:
			parts.append("%s %s" % [fmt.call(v), p[1]])
	if parts.is_empty():
		return "Nothing crosses the site's edge in %s: it moves between stores and machines." % ElementLens.label(_lens).to_lower()
	return "Across the site's edge: " + " · ".join(parts) + "."
