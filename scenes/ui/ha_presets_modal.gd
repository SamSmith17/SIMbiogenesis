extends Node

## Live links → Presets…: link a known device in one step (HaPresets).
## Pick the device kind, which of your devices (found in your Home
## Assistant's entity list), and which graph node each part goes to; the
## window lists exactly the links it will make, and Apply makes them.
## Opened by Main.open_ha_presets(); frees itself when closed.

## A preset's node type → the graph node types that can take it.
const TYPE_MATCH := {
	"battery": ["battery", "smartbattery"],
	"panel": ["panel"],
	"controller": ["controller"],
	"shelly4pm": ["shelly4pm"],
	"acload": ["acload", "appliance"],
}
const TYPE_LABELS := {
	"battery": "Battery node", "panel": "Solar node", "controller": "Inverter / controller node",
	"shelly4pm": "Shelly 4PM node", "acload": "Load node",
}

var _linker: Node = null
var _svc: Node = null
var _frame: ModalFrame = null
var _preset_opt: OptionButton = null
var _device_opt: OptionButton = null
var _blurb: Label = null
var _items_box: VBoxContainer = null
var _item_opts: Dictionary = {}     # preset node type -> OptionButton
var _item_ids: Dictionary = {}      # preset node type -> [item ids], index-aligned ("" first)
var _plan_box: VBoxContainer = null
var _apply_btn: Button = null
var _devices: Array = []
var _plan: Array = []


func open_on(linker: Node, _target_id: String = "") -> void:
	_linker = linker
	_svc = get_node_or_null("/root/HomeAssistant")
	_frame = ModalFrame.create("Device presets", "Link every sensor of a known device at once.", Vector2(760, 520), "ha_presets")
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_frame.body.add_child(row)
	_preset_opt = OptionButton.new()
	_preset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in HaPresets.PRESETS:
		_preset_opt.add_item(str(p["label"]))
	_preset_opt.item_selected.connect(func(_i: int) -> void: _on_preset())
	row.add_child(_preset_opt)
	_device_opt = OptionButton.new()
	_device_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_device_opt.item_selected.connect(func(_i: int) -> void: _replan())
	row.add_child(_device_opt)
	_blurb = Label.new()
	_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_blurb.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_blurb.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_frame.body.add_child(_blurb)
	_items_box = VBoxContainer.new()
	_items_box.add_theme_constant_override("separation", 6)
	_frame.body.add_child(_items_box)
	_frame.body.add_child(SectionHeader.make("Links it will make", "link"))
	_plan_box = VBoxContainer.new()
	_plan_box.add_theme_constant_override("separation", 2)
	_frame.body.add_child(_plan_box)
	_apply_btn = _frame.add_button("Make these links", ModalFrame.PRIMARY, _apply)
	_frame.add_button("Cancel", ModalFrame.SECONDARY, _frame.close)
	_frame.open()
	_on_preset()


func _preset() -> Dictionary:
	return HaPresets.PRESETS[maxi(_preset_opt.selected, 0)]


func _entity_ids() -> Array:
	var out: Array = []
	if _svc != null:
		for r in _svc.call("catalog"):
			out.append(str(r.get("entity_id", "")))
	return out


func _on_preset() -> void:
	var p := _preset()
	_blurb.text = str(p.get("blurb", ""))
	_devices = HaPresets.devices(p, _entity_ids())
	_device_opt.clear()
	if _devices.is_empty():
		_device_opt.add_item("None found in your Home Assistant")
		_device_opt.disabled = true
	else:
		_device_opt.disabled = false
		for d in _devices:
			_device_opt.add_item(str(d))
	for c in _items_box.get_children():
		_items_box.remove_child(c)
		c.queue_free()
	_item_opts.clear()
	_item_ids.clear()
	var items: Array = _linker.get("model").items if _linker != null and _linker.get("model") != null else []
	for itype in (p.get("items", {}) as Dictionary).keys():
		var r := HBoxContainer.new()
		r.add_theme_constant_override("separation", 8)
		_items_box.add_child(r)
		var l := Label.new()
		l.text = str(TYPE_LABELS.get(itype, UiText.from_id(str(itype))))
		l.custom_minimum_size.x = 200
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		r.add_child(l)
		var opt := OptionButton.new()
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.fit_to_longest_item = false
		var ids: Array = [""]
		opt.add_item("Don't link a node")
		for it in items:
			if str(it.get("type", "")) in TYPE_MATCH.get(itype, [itype]):
				opt.add_item(HaTargets.item_label(it))
				ids.append(str(it["id"]))
		if ids.size() > 1:
			opt.select(1)
		opt.item_selected.connect(func(_i: int) -> void: _replan())
		r.add_child(opt)
		_item_opts[itype] = opt
		_item_ids[itype] = ids
	_replan()


func _replan() -> void:
	for c in _plan_box.get_children():
		_plan_box.remove_child(c)
		c.queue_free()
	_plan = []
	if not _devices.is_empty():
		var choice := {}
		for itype in _item_opts.keys():
			var opt: OptionButton = _item_opts[itype]
			choice[itype] = str((_item_ids[itype] as Array)[maxi(opt.selected, 0)])
		_plan = HaPresets.plan(_preset(), str(_devices[maxi(_device_opt.selected, 0)]), choice, _entity_ids())
	if _plan.is_empty():
		var l := Label.new()
		l.text = "Nothing to link: no device of this kind in your Home Assistant, or no node chosen." \
			if _svc != null and bool(_svc.call("is_authed")) else "Connect to Home Assistant first."
		l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_plan_box.add_child(l)
	for pl in _plan:
		var t: Dictionary = _linker.call("target", str(pl["target_id"]))
		var l := Label.new()
		var replaces := not (_linker.call("link_for_target", str(pl["target_id"])) as Dictionary).is_empty()
		l.text = "%s  ←  %s%s" % [str(t.get("label", pl["target_id"])), str(pl["entity_id"]),
			"   (replaces its current link)" if replaces else ""]
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		_plan_box.add_child(l)
	_apply_btn.disabled = _plan.is_empty()
	_apply_btn.text = "Make %s" % UiText.count(_plan.size(), "link") if not _plan.is_empty() else "Make these links"


func _apply() -> void:
	for pl in _plan:
		_linker.call("link_entity", str(pl["entity_id"]), str(pl["target_id"]))
	var main := get_tree().current_scene
	if main != null and main.has_method("show_toast"):
		main.call("show_toast", "Linked %s" % UiText.count(_plan.size(), "sensor"), 1, 4.0)
	_frame.close()
