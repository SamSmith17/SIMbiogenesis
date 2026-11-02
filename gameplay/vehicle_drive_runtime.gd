class_name VehicleDriveRuntime
extends Node

## Puts a living vehicle where its ARRIVAL says it is (VehicleDrive): not on
## site before it sets off, on the road while it drives in, in its spot after.
## Attached to every living vehicle prop; idle while the record carries no
## `arrival`. The record is never written — the pose is a function of the
## clock, so the drive scrubs backwards and survives a reload.
##
## A trailer hitched to an arriving vehicle follows it: its coupler on the
## vehicle's hitch, its axle on the road behind (VehicleDrive.point_behind).
## Crates stowed in either ride along (their nodes; the records already hold
## the parked slots).
##
## While the vehicle is away or on the road it cannot be got into
## (`META_BUSY` on the prop, read by PlacedVehicle.can_mount).

const NODE_NAME := "VehicleDriveRuntime"
const META_BUSY := "vehicle_driving_in"
const POLL_S := 0.5

var prop_id := ""
var _prop: Node3D = null
var _model: Node3D = null
var _arrival: Dictionary = {}
## The tow vehicle's arrival when this is a trailer hitched to one.
var _tow_arrival: Dictionary = {}
var _tow_id := ""
var _design: Dictionary = {}
var _tow_design: Dictionary = {}
var _poll := 99.0
var _home_pos := Vector3.ZERO
var _home_yaw := 0.0
var _have_home := false
## How far the parked prop stands above the ground under it.
var _lift := 0.0
var _state := ""
var _cargo_ids: Array = []
## Each stowed crate's transform in the vehicle's parked frame (prop id ->
## Transform3D), taken when the drive starts.
var _cargo_local: Dictionary = {}
var _wheelbase := 3.5


static func attach(prop: Node3D, model: Node3D, rec: Dictionary) -> void:
	if not VehicleBuilder.handles(str(rec.get("model_id", ""))):
		return
	if prop.get_node_or_null(NODE_NAME) != null:
		return
	var r := VehicleDriveRuntime.new()
	r.name = NODE_NAME
	r.prop_id = str(rec.get("id", ""))
	r._prop = prop
	r._model = model
	prop.add_child(r)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _main() -> Node:
	var t := get_tree()
	return t.current_scene if t != null else null


func _process(delta: float) -> void:
	if _prop == null or not is_instance_valid(_prop):
		return
	var main := _main()
	if main == null or not main.has_method("get_absolute_hours"):
		return
	_poll += delta
	if _poll >= POLL_S:
		_poll = 0.0
		_refresh(main)
	var arr := _tow_arrival if not _tow_arrival.is_empty() else _arrival
	if arr.is_empty():
		_settle(STATE_IDLE)
		return
	var veh := _prop.get_node_or_null("PlacedVehicle")
	if veh != null and bool(veh.get("is_mounted")):
		_settle(STATE_IDLE)
		return
	var pose := VehicleDrive.pose_at(arr, float(main.call("get_absolute_hours")))
	var st := str(pose["state"])
	if st == VehicleDrive.STATE_PARKED:
		_settle(STATE_IDLE)
		return
	if st == VehicleDrive.STATE_AWAY:
		_set_state(VehicleDrive.STATE_AWAY)
		_prop.visible = false
		_move_cargo(main, false)
		return
	_set_state(VehicleDrive.STATE_DRIVING)
	_prop.visible = true
	var pos: Vector2 = pose["pos"]
	var yaw := float(pose["yaw"])
	if not _tow_arrival.is_empty():
		# A trailer: coupler on the tow vehicle's hitch, axle on the road.
		var hitch := VehicleTow.world_xz(_tow_design.get("hitch", Vector3.ZERO), pos, yaw)
		var axle := VehicleDrive.point_behind(_tow_arrival, hitch, float(pose["s"]), VehicleTow.tongue_m(_design))
		var tp := VehicleTow.trailer_pose(_design, hitch, axle)
		pos = tp["origin"]
		yaw = float(tp["yaw"])
	var gy := TerrainSurfaceQuery.ground_height_at(main, pos.x, pos.y)
	var y := (gy if not is_nan(gy) else _home_pos.y) + _lift
	_prop.global_position = Vector3(pos.x, y, pos.y)
	if _model != null:
		_model.rotation.y = yaw
		# The wheels: rolled the route's arc length, steering into its bends
		# (a trailer's turn with it, unsteered).
		var s_now := float(pose["s"])
		var ahead := VehicleDrive.pose_at(arr, float(main.call("get_absolute_hours")) + 1.0 / 3600.0)
		var ds := float(ahead.get("s", s_now)) - s_now
		var steer := VehicleBuilder.steer_for(_wheelbase,
			angle_difference(float(pose["yaw"]), float(ahead["yaw"])), ds) if _tow_arrival.is_empty() else 0.0
		VehicleBuilder.spin_wheels(_model, s_now, steer)
	_move_cargo(main, true)


const STATE_IDLE := "idle"


func _set_state(st: String) -> void:
	if st == _state:
		return
	if _state == STATE_IDLE or _state == "":
		_capture_home()
	_state = st
	_prop.set_meta(META_BUSY, true)
	if _prop.has_method("set_collision_enabled"):
		_prop.call("set_collision_enabled", false)


## Back in its spot: the pose it was built at, collision as the record says.
func _settle(st: String) -> void:
	if _state == st:
		return
	var was := _state
	_state = st
	if was == "" or was == STATE_IDLE:
		return
	_prop.visible = not bool(_record().get("hidden_3d", false))
	if _have_home:
		_prop.global_position = _home_pos
		if _model != null:
			_model.rotation.y = _home_yaw
	if _prop.has_meta(META_BUSY):
		_prop.remove_meta(META_BUSY)
	if _prop.has_method("set_collision_enabled"):
		_prop.call("set_collision_enabled", bool(_record().get("collision_enabled", true)))
	var main := _main()
	if main != null:
		_move_cargo(main, true)


func _capture_home() -> void:
	_home_pos = _prop.global_position
	_home_yaw = _model.rotation.y if _model != null else 0.0
	_have_home = true
	_cargo_local.clear()
	var main := _main()
	if main == null:
		return
	_lift = _home_pos.y - _ground(main, _home_pos.x, _home_pos.z)
	var inv := _frame().affine_inverse()
	for cid in _cargo_ids:
		var node := PlacedPropRuntime.find_by_prop_id(main, str(cid)) as Node3D
		if node != null:
			_cargo_local[str(cid)] = inv * node.global_transform


## The vehicle's frame now: its position and the model's yaw.
func _frame() -> Transform3D:
	var yaw := _model.rotation.y if _model != null else 0.0
	return Transform3D(Basis(Vector3.UP, yaw), _prop.global_position)


func _record() -> Dictionary:
	var main := _main()
	return PlacedPropService.get_prop_record(main, prop_id) if main != null else {}


func _refresh(main: Node) -> void:
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	var a: Variant = rec.get("arrival", {})
	_arrival = a if a is Dictionary else {}
	if _design.is_empty():
		_design = VehicleDesign.solve(VehicleBuilder.spec_for_record(rec))
		_wheelbase = VehicleBuilder.wheelbase_of(_design)
	_tow_arrival = {}
	_tow_id = str(rec.get("hitched_to", ""))
	if not _tow_id.is_empty():
		var trec := PlacedPropService.get_prop_record(main, _tow_id)
		var ta: Variant = trec.get("arrival", {})
		if ta is Dictionary and not (ta as Dictionary).is_empty():
			_tow_arrival = ta
			if _tow_design.is_empty():
				_tow_design = VehicleDesign.solve(VehicleBuilder.spec_for_record(trec))
	if _state == STATE_IDLE or _state == "":
		_cargo_ids.clear()
		var layer := PlacedPropService._layer_for_main(main)
		if layer != null:
			for r in layer.props:
				var cr: Dictionary = r
				if str(cr.get("stowed_in", "")) == prop_id:
					_cargo_ids.append(str(cr.get("id", "")))
		_capture_home()


func _ground(main: Node, x: float, z: float) -> float:
	var g := TerrainSurfaceQuery.ground_height_at(main, x, z)
	return g if not is_nan(g) else _home_pos.y


## Stowed crates ride in the vehicle: hidden while it is away, carried at
## their place in it while it drives and when it parks.
func _move_cargo(main: Node, shown: bool) -> void:
	var f := _frame()
	for cid in _cargo_local:
		var node := PlacedPropRuntime.find_by_prop_id(main, str(cid)) as Node3D
		if node == null:
			continue
		# A crate the crew has carried out is no longer the vehicle's.
		if str(PlacedPropService.get_prop_record(main, str(cid)).get("stowed_in", "")) != prop_id:
			continue
		node.visible = shown
		if shown:
			node.global_transform = f * (_cargo_local[cid] as Transform3D)
