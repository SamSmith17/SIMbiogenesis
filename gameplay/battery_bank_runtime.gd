class_name BatteryBankRuntime
extends Node

## A placed battery bank (Battery Lab) in the world: twice a second it reads
## its graph battery and SolarUI, and shows over the bank its state of
## charge, whether it is charging or giving, and when the bank's BMS limits
## are holding it back (charging blocked because it is too cold; charge or
## discharge at the BMS's limit) — the live simulation's pack-level BMS.

const NODE_NAME := "BatteryBankRuntime"
const POLL_S := 0.5

var text := ""
var blocked_cold := false
var at_limit := ""
var _poll := 0.0
var _prop: Node3D = null
var _prop_id := ""
var _label: Label3D = null


static func attach(prop: Node3D, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != BankBuilder.MODEL_ID or prop.get_node_or_null(NODE_NAME) != null:
		return
	var rt := BatteryBankRuntime.new()
	rt.name = NODE_NAME
	rt._prop = prop
	rt._prop_id = str(rec.get("id", ""))
	prop.add_child(rt)


func _ready() -> void:
	_label = Label3D.new()
	_label.name = "BankLabel"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.pixel_size = 0.0025
	_label.font_size = 40
	_label.outline_size = 10
	_label.no_depth_test = true
	_label.modulate = Color(0.85, 0.95, 1.0)
	var bm := _bounds()
	_label.position = Vector3(0.0, bm.end.y + 0.25, 0.0)
	_prop.add_child.call_deferred(_label)


func _bounds() -> AABB:
	for c in _prop.find_children("*", "Node3D", true, false):
		if c.has_meta("bounds_m") and c.has_meta("bank"):
			return c.get_meta("bounds_m")
	return AABB(Vector3.ZERO, Vector3(1, 1, 1))


func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = POLL_S
	_refresh()


func _refresh() -> void:
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		return
	var rec := PlacedPropService.get_prop_record(main, _prop_id)
	var gid := str(rec.get("graph_item_id", ""))
	var gv := ServiceLocator.graph()
	var model: Variant = gv.get("model") if gv != null else null
	var specs: Dictionary = {}
	if model != null and not gid.is_empty():
		specs = (model.call("get_item", gid) as Dictionary).get("specs", {})
	var sui: Node = main.get_node_or_null("UILayer/SolarUI")
	blocked_cold = false
	at_limit = ""
	var flow := ""
	if sui != null and sui.has_method("battery_limits_now"):
		var lim: Vector2 = sui.call("battery_limits_now")
		var p_kw := float(sui.get("current_solar_kw")) - float(sui.get("current_load_kw"))
		blocked_cold = lim.x == 0.0 and float(sui.get("battery_charge_min_c")) > -INF
		if p_kw > 0.05:
			flow = "charging %.1f kW" % minf(p_kw, lim.x)
			if p_kw > lim.x + 0.01 and not blocked_cold:
				at_limit = "charge held at the BMS's %.1f kW" % lim.x
		elif p_kw < -0.05:
			flow = "giving %.1f kW" % minf(-p_kw, lim.y)
			if -p_kw > lim.y + 0.01:
				at_limit = "load over the BMS's %.1f kW" % lim.y
	var soc := float(specs.get("soc", -1.0))
	var lines: Array = [str(specs.get("name", "Battery bank"))]
	if soc >= 0.0:
		lines.append("%.0f %% · %.1f kWh%s" % [soc * 100.0, float(specs.get("kwh", 0.0)), (" · " + flow) if not flow.is_empty() else ""])
	if blocked_cold:
		lines.append("Too cold to charge: the BMS holds it off")
	elif not at_limit.is_empty():
		lines.append(at_limit)
	text = "\n".join(PackedStringArray(lines))
	if _label != null:
		_label.text = text
		_label.modulate = Color(0.55, 0.8, 1.0) if blocked_cold else (Color(1.0, 0.8, 0.4) if not at_limit.is_empty() else Color(0.85, 0.95, 1.0))
