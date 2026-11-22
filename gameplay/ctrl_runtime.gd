class_name CtrlRuntime
extends Node

## A placed Controller Lab unit in the world: twice a second its screen shows
## what the unit is doing — solar in (its graph controller's delivered watts),
## the battery's charge and whether the AC output is on — and, with no
## screen, a small label over it does. Reads the graph and SolarUI; writes
## nothing.

const NODE_NAME := "CtrlRuntime"
const POLL_S := 0.5

var text := ""
var _poll := 0.0
var _prop: Node3D = null
var _prop_id := ""
var _screen: Label3D = null


static func attach(prop: Node3D, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != CtrlBuilder.MODEL_ID or prop.get_node_or_null(NODE_NAME) != null:
		return
	var rt := CtrlRuntime.new()
	rt.name = NODE_NAME
	rt._prop = prop
	rt._prop_id = str(rec.get("id", ""))
	prop.add_child(rt)


func _ready() -> void:
	_place_screen.call_deferred()


## On the unit's LCD when it has one (in the builder's frame), else over it.
func _place_screen() -> void:
	var b: CtrlBuilder = null
	for c in _prop.find_children("*", "CtrlBuilder", true, false):
		b = c as CtrlBuilder
		break
	_screen = Label3D.new()
	_screen.name = "CtrlScreen"
	_screen.font = UITheme.font("semibold")
	_screen.outline_size = 0
	_screen.modulate = Color(0.85, 0.95, 1.0)
	if b != null:
		for p in (b.design.get("ports", []) as Array):
			if str(p["connector"]) != "lcd":
				continue
			var xf: Transform3D = p["xf"]
			var e: Dictionary = p["entry"]
			var body: Vector3 = e["body"]
			_screen.font_size = 48
			_screen.pixel_size = body.y * CtrlBuilder.MM / 48.0 / 3.6
			_screen.double_sided = false
			_screen.transform = Transform3D(xf.basis, (xf.origin + xf.basis.z * (body.z + 0.6)) * CtrlBuilder.MM)
			b.add_child(_screen)
			_refresh()
			return
		var ab := CtrlDesign.bounds(b.design)
		_screen.position = Vector3(0.0, ab.end.y * CtrlBuilder.MM + 0.15, ab.end.z * CtrlBuilder.MM)
	_screen.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_screen.pixel_size = 0.0022
	_screen.font_size = 36
	_screen.outline_size = 8
	_screen.no_depth_test = true
	_prop.add_child(_screen)
	_refresh()


func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = POLL_S
	_refresh()


func _refresh() -> void:
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	if main == null:
		return
	var rec := PlacedPropService.get_prop_record(main, _prop_id)
	var gid := str(rec.get("graph_item_id", ""))
	var gv := ServiceLocator.graph()
	var model: Variant = gv.get("model") if gv != null else null
	var specs: Dictionary = {}
	if model != null and not gid.is_empty():
		specs = (model.call("get_item", gid) as Dictionary).get("specs", {})
	var lines: Array = []
	if bool(specs.get("destroyed", false)):
		lines.append("FAULT")
		lines.append(str(specs.get("destroyed_reason", "")).left(18))
	else:
		lines.append("PV %s" % UiText.num(float(specs.get("dc_delivered_w", 0.0)), "W"))
		var sui: Node = main.get_node_or_null("UILayer/SolarUI")
		if sui != null and sui.has_method("get_battery_capacity_kwh"):
			var cap := float(sui.call("get_battery_capacity_kwh"))
			if cap > 0.0:
				lines.append("BAT %.0f %%" % (float(sui.get("battery_kwh_stored")) / cap * 100.0))
			if float(specs.get("overload_watts", 0.0)) > 0.0:
				var apb := tree.root.get_node_or_null("AcPowerBus")
				var on := true
				if apb != null:
					on = bool(apb.get("power_available")) and not bool(apb.get("shutdown_active"))
				lines.append("AC %s" % (UiText.num(float(sui.get("current_load_kw")) * 1000.0, "W") if on else "OFF"))
	text = "\n".join(PackedStringArray(lines))
	if _screen != null:
		_screen.text = text
