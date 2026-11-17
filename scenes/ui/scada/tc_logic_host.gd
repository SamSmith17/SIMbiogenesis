extends Node
## The control logic window's "hub" for a tri-clamp Process Lab design
## (scenes/ui/scada/logic_editor.gd asks it what the graph's ScadaHub is
## asked). The blocks live on the design (`process.logic`); they run inside
## the lab's own model (TcProcSim._run_logic), so editing one restarts the
## run like editing a rule does.
##
## Tags here are the design's own sensors and switches (TcProcControl keys).

var _panel: Node = null
var _book := ScadaTags.new()
## The tri-clamp designer stands above the usual modal layer; these windows
## stand above it.
var modal_layer: int = UITheme.LAYER_MODAL + 3


func setup(panel: Node) -> void:
	_panel = panel


func _sim() -> TcProcSim:
	return _panel.get("sim") as TcProcSim if _panel != null else null


func logic_blocks() -> Array:
	return ((_panel.get("proc") as Dictionary).get("logic", []) as Array) if _panel != null else []


func logic_block(id: String) -> Dictionary:
	for b in logic_blocks():
		if str((b as Dictionary).get("id", "")) == id:
			return b
	return {}


func new_logic_id() -> String:
	var n := 1
	while not logic_block("b%d" % n).is_empty():
		n += 1
	return "b%d" % n


func set_logic_blocks(blocks: Array) -> void:
	if _panel != null:
		_panel.call("_edit", ["logic"], blocks.duplicate(true))


func logic_status() -> Dictionary:
	var s := _sim()
	return s.logic_status if s != null else {}


func logic_notes() -> Dictionary:
	return {}


## An operator's command: from now on (the run past now is recomputed).
func logic_command(id: String, what: String, value: float = 0.0) -> void:
	var s := _sim()
	if s == null:
		return
	s.logic_state = ScadaLogic.command(s.logic_blocks, s.logic_state, id, what, value)
	if _panel.has_method("cut_run_here"):
		_panel.call("cut_run_here", "Logic: %s %s." % [str(logic_block(id).get("name", id)), what])


func refresh() -> void:
	var s := _sim()
	if s == null:
		return
	var vals := TcProcControl.read_all(s, s.control_sensors)
	var sens: Array = []
	for e in s.control_sensors:
		sens.append({"key": str(e["key"]), "label": str(e.get("label", e["key"])), "unit": str(e.get("unit", "")),
			"value": float(vals.get(str(e["key"]), NAN))})
	var acts: Array = []
	for a in s.control_acts:
		var v := TcProcControl.value_of(s, a) if str(a["kind"]) == "number" else (1.0 if TcProcControl.is_on(s, str(a["act"])) else 0.0)
		acts.append({"key": str(a["key"]), "label": str(a["label"]), "unit": str(a.get("unit", "")), "kind": str(a["kind"]), "value": v})
	var d: Dictionary = _panel.get("design")
	_book.set_all(ScadaTags.tc_tags(str((d.get("spec", {}) as Dictionary).get("name", "Design")), sens, acts))


func book() -> ScadaTags:
	return _book


func command(_id: String, _v: float) -> bool:
	return false


## The tag list, on this design's tags (the editor's tag fields).
func open_tag_browser(opts: Dictionary = {}) -> Node:
	var br := Node.new()
	br.set_script(load("res://scenes/ui/scada/tag_browser.gd"))
	add_child(br)
	br.call("open", self, opts)
	return br
