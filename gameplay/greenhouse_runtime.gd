class_name GreenhouseRuntime
extends Node3D

## A placed greenhouse in the world, following its graph node (the flow
## engine's climate, ResourceFlowEngine._process_greenhouse): the vents open to
## the controller's share, the fans spin while they run, the grow-light racks
## mounted in it glow while the lamps are on, the glazing mists over when water
## condenses on it, and a status label over the door reads the air inside
## ("27 °C · 68 % · vents 40 %"). With no graph (or before the clock has run)
## it rests: vents shut, fans still, lamps off. Polls twice a second; the vents
## and the mist ease toward their targets every frame.

const NODE_NAME := "GreenhouseRuntime"
const POLL_S := 0.5
const EASE_S := 1.5
const FAN_RAD_S := 24.0
const LABEL_FAR_M := 45.0
const MIST_LPH := 0.5

var prop_id := ""
var _model: Node = null
var _main: Node = null
var _label: Label3D = null
var _poll := 999.0
var _vent := 0.0
var _vent_target := 0.0
var _fans := false
var _lights := false
var _mist := 0.0
var _mist_target := 0.0
var _glaze_base := {}


static func attach(prop: Node3D, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != GreenhouseBuilder.MODEL_ID or bool(rec.get("packed", false)):
		return
	var model := prop.get_node_or_null("ModelRoot")
	if model == null or model.get_node_or_null(NODE_NAME) != null:
		return
	var rt := GreenhouseRuntime.new()
	rt.name = NODE_NAME
	rt.prop_id = str(rec.get("id", ""))
	model.add_child(rt)


func _ready() -> void:
	_model = get_parent()
	var n: Node = self
	while n != null:
		if n.has_method("get_absolute_hours"):
			_main = n
			break
		n = n.get_parent()
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = false
	_label.font_size = 40
	_label.pixel_size = 0.006
	_label.outline_size = 10
	_label.modulate = Color(0.85, 1.0, 0.88)
	_label.visible = false
	add_child(_label)


## What the graph says now: {} without a node or before the clock has run.
func state() -> Dictionary:
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("greenhouse_system_item_id"):
		return {}
	var cid := str(sgv.call("greenhouse_system_item_id", prop_id))
	if cid.is_empty():
		return {}
	var gm: Object = sgv.get("model")
	if gm == null:
		return {}
	var it: Dictionary = gm.call("get_item", cid)
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	return sp if sp.has("gh_t_air") else {}


func _process(delta: float) -> void:
	_poll += delta
	if _poll >= POLL_S:
		_poll = 0.0
		_refresh()
	var k := clampf(delta / EASE_S, 0.0, 1.0)
	var paused := _main != null and SimFxRate.is_paused(_main)
	if not paused:
		_vent = lerpf(_vent, _vent_target, k)
		GreenhouseBuilder.set_vents(_model, _vent)
		if _fans:
			GreenhouseBuilder.spin_fans(_model, FAN_RAD_S * delta)
	_mist = lerpf(_mist, _mist_target, k * 0.5)
	_apply_mist()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null and _label.visible:
		_label.modulate.a = clampf(1.0 - (cam.global_position.distance_to(_label.global_position) - LABEL_FAR_M * 0.6) / (LABEL_FAR_M * 0.4), 0.0, 1.0)


func _refresh() -> void:
	var sp := state()
	if sp.is_empty():
		_vent_target = 0.0
		_fans = false
		_set_lights(false)
		_mist_target = 0.0
		_label.visible = false
		return
	_vent_target = clampf(float(sp.get("gh_vent_pct", 0.0)) / 100.0, 0.0, 1.0)
	_fans = bool(sp.get("gh_fans", false))
	_set_lights(bool(sp.get("gh_lights", false)))
	_mist_target = clampf(float(sp.get("gh_cond_lph", 0.0)) / MIST_LPH, 0.0, 1.0)
	var bits: PackedStringArray = PackedStringArray()
	bits.append("%.0f °C · %d %%" % [float(sp["gh_t_air"]), int(sp.get("gh_rh", 0))])
	var vent := int(sp.get("gh_vent_pct", 0))
	if vent > 0:
		bits.append("vents %d %%" % vent)
	if _fans:
		bits.append("fans")
	if bool(sp.get("gh_heater", false)):
		bits.append("heater")
	if _lights:
		bits.append("lamps")
	_label.text = " · ".join(bits)
	_label.visible = true
	var aabb := _model_height()
	_label.position = Vector3(0.0, aabb + 0.6, 0.0)


func _model_height() -> float:
	var rec := PlacedPropService.get_prop_record(_main, prop_id) if _main != null else {}
	var d := GreenhouseDesign.solve(GreenhouseWorld.spec_of(rec))
	return float(d["stats"].get("height_m", 3.0))


## The light racks mounted in this house glow with its lamps.
func _set_lights(on: bool) -> void:
	if on == _lights:
		return
	_lights = on
	if _main == null:
		return
	var parts := GreenhouseWorld.parts_of(_main, prop_id)
	for k in parts:
		if not str(k).begins_with("lights:"):
			continue
		var node := PlacedPropRuntime.find_by_prop_id(_main, str((parts[k] as Dictionary).get("id", "")))
		if node != null:
			GrowLightRack.set_lit(node.get_node_or_null("ModelRoot") if node.get_node_or_null("ModelRoot") != null else node, on)


## Condensation: the glazing turns milky (its albedo whitens, its alpha rises).
func _apply_mist() -> void:
	var g := _model.find_child("Glazing", true, false) as MeshInstance3D if _model != null else null
	if g == null or g.mesh == null:
		return
	for i in g.mesh.get_surface_count():
		var m := g.get_active_material(i) as StandardMaterial3D
		if m == null:
			continue
		if not _glaze_base.has(i):
			# A per-instance copy so one house's mist is its own.
			m = m.duplicate() as StandardMaterial3D
			g.set_surface_override_material(i, m)
			_glaze_base[i] = m.albedo_color
		var base: Color = _glaze_base[i]
		var c := base.lerp(Color(0.92, 0.95, 0.97, maxf(base.a, 0.75)), _mist * 0.8)
		if not m.albedo_color.is_equal_approx(c):
			m.albedo_color = c
