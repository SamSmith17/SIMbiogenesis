class_name ForkliftRig
extends Node
## The placed forklift's mast and forks. While the forklift is driven,
## Page Up / Page Down raise and lower the carriage. Lifting with a pallet,
## crate or forklift-handled unit over the forks picks it up (its node rides
## the forks); lowering to the ground sets it down where it is (the record
## moves, `stowed_in` is cleared, the prop is rebuilt). Lift height and the
## carried prop id are kept on the forklift's record.

const LIFT_SPEED_MPS := 0.45
const PICK_LIFT_M := 0.08
const DROP_LIFT_M := 0.05
const PICK_HALF_W_M := 0.55
const PICK_HALF_D_M := 0.75
const PICK_BASE_TOL_M := 0.30
const MAX_FOOTPRINT_M := 2.6
const TILT_BACK_RAD := 0.06
const CARRIAGE_BASE_Y := -0.27

var vehicle: PlacedVehicle = null
var lift_m := 0.0
var load_id := ""

var _model: Node3D = null
var _mast: Node3D = null
var _carriage: Node3D = null
var _load_anchor: Node3D = null
var _carry_offset := Transform3D.IDENTITY
var _restored := false
var _save_acc := 0.0
var _base_y := CARRIAGE_BASE_Y
## True while an NPC operator drives the truck (NpcPopulationHost): the
## mast follows `set_operated`, nothing is picked or set down by the rig,
## and nothing is persisted (the chore's effect moves the records).
var _operated := false
var _operated_loaded := false


func configure(v: PlacedVehicle, model: Node3D) -> void:
	vehicle = v
	_model = model
	if model != null:
		_mast = model.find_child("Mast", true, false) as Node3D
		_carriage = model.find_child("Carriage", true, false) as Node3D
		_load_anchor = model.find_child("Load", true, false) as Node3D
		if _carriage != null:
			_base_y = float(_carriage.get_meta("rest_y", _carriage.position.y))


func _process(delta: float) -> void:
	if vehicle == null or not is_instance_valid(vehicle) or _carriage == null:
		return
	if not _restored:
		_restore_from_record()
	if _operated:
		_apply_pose()
		return
	var before := lift_m
	if vehicle.is_mounted:
		if Input.is_physical_key_pressed(KEY_PAGEUP):
			lift_m += LIFT_SPEED_MPS * delta
		if Input.is_physical_key_pressed(KEY_PAGEDOWN):
			lift_m -= LIFT_SPEED_MPS * delta
	lift_m = clampf(lift_m, 0.0, ForkliftBuilder.MAX_LIFT_M)
	_apply_pose()
	if load_id.is_empty() and before <= PICK_LIFT_M and lift_m > PICK_LIFT_M:
		_try_pick()
	elif not load_id.is_empty() and lift_m < DROP_LIFT_M and before >= DROP_LIFT_M:
		_set_down()
	_follow_load()
	if absf(before - lift_m) > 0.0001:
		_save_acc += delta
		if _save_acc > 0.5:
			_save_acc = 0.0
			_persist(false)


func _apply_pose() -> void:
	var p := _carriage.position
	p.y = _base_y + lift_m
	_carriage.position = p
	if _mast != null:
		var loaded := _operated_loaded if _operated else not load_id.is_empty()
		_mast.rotation.x = TILT_BACK_RAD if loaded else 0.0


## An NPC operator holds the forks at `lift` (metres over rest), tilted back
## when `loaded`. Call every frame while operated; `release_operated` hands
## the truck back to the player's controls with the forks down.
func set_operated(lift: float, loaded: bool) -> void:
	_operated = true
	_operated_loaded = loaded
	lift_m = clampf(lift, 0.0, ForkliftBuilder.MAX_LIFT_M)
	if _carriage != null:
		_apply_pose()


func release_operated() -> void:
	if not _operated:
		return
	_operated = false
	_operated_loaded = false
	lift_m = 0.0
	if _carriage != null:
		_apply_pose()


func is_operated() -> bool:
	return _operated


## Where a load sits on the forks (the Load node under the carriage).
func load_anchor() -> Node3D:
	return _load_anchor


## Props the forks can lift: a pallet, a packed crate, an intermodal unit
## or anything with a packed spec, within capacity and fork-sized.
static func liftable(rec: Dictionary) -> bool:
	if rec.is_empty() or str(rec.get("model_id", "")) == ForkliftBuilder.MODEL_ID:
		return false
	if PlacedVehicle.profile_for_model(str(rec.get("model_id", ""))) != "":
		return false
	var spec: Dictionary = PlacedPropRuntime.packed_spec_for_record(rec)
	if spec.is_empty():
		return false
	var mass := float(spec.get("mass_kg", -1.0))
	if mass > ForkliftBuilder.CAPACITY_KG:
		return false
	var w := float(spec.get("w_m", 0.0))
	var d := float(spec.get("d_m", 0.0))
	if maxf(w, d) > MAX_FOOTPRINT_M:
		return false
	var form := str(spec.get("form", ""))
	return form == "pallet" or bool(rec.get("packed", false)) \
		or str(rec.get("model_id", "")) == "intermodal_unit" \
		or str(spec.get("handling", "")) == "forklift" or mass >= 40.0


func _try_pick() -> void:
	var main := vehicle._main()
	if main == null or _load_anchor == null:
		return
	var layer = PlacedPropService._layer_for_main(main)
	if layer == null:
		return
	var anchor := _load_anchor.global_transform
	var inv := anchor.affine_inverse()
	var best := ""
	var best_d := INF
	for rec in layer.props:
		var r: Dictionary = rec
		var id := str(r.get("id", ""))
		if id.is_empty() or id == vehicle.prop_id or not liftable(r):
			continue
		var node := PlacedPropRuntime.find_by_prop_id(main, id)
		if node == null:
			continue
		var local := inv * node.global_position
		if absf(local.x) > PICK_HALF_W_M or absf(local.z) > PICK_HALF_D_M:
			continue
		if local.y < -PICK_BASE_TOL_M - lift_m or local.y > PICK_BASE_TOL_M:
			continue
		var dd := Vector2(local.x, local.z).length()
		if dd < best_d:
			best_d = dd
			best = id
	if best.is_empty():
		return
	var n := PlacedPropRuntime.find_by_prop_id(main, best)
	load_id = best
	_carry_offset = anchor.affine_inverse() * n.global_transform
	_carry_offset.origin.y = 0.0
	_persist(false)


func _follow_load() -> void:
	if load_id.is_empty() or _load_anchor == null:
		return
	var main := vehicle._main()
	if main == null:
		return
	var n := PlacedPropRuntime.find_by_prop_id(main, load_id)
	if n == null:
		if PlacedPropService.get_prop_record(main, load_id).is_empty():
			load_id = ""
		return
	n.global_transform = _load_anchor.global_transform * _carry_offset


func _set_down() -> void:
	var main := vehicle._main()
	var id := load_id
	load_id = ""
	_apply_pose()
	if main == null:
		return
	var n := PlacedPropRuntime.find_by_prop_id(main, id)
	if n == null:
		return
	var p := n.global_position
	var yaw := fposmod(rad_to_deg(n.global_transform.basis.get_euler().y), 360.0)
	PlacedPropService.update_prop_record(main, id,
		{"x": p.x, "z": p.z, "yaw": yaw, "y_offset": 0.0, "stowed_in": null,
		"collision_enabled": true}, true)
	_persist(true)


func carried_id() -> String:
	return load_id


func _restore_from_record() -> void:
	_restored = true
	var rec := vehicle._record()
	lift_m = clampf(float(rec.get("fork_lift_m", 0.0)), 0.0, ForkliftBuilder.MAX_LIFT_M)
	var lid := str(rec.get("fork_load_id", ""))
	if lid.is_empty():
		return
	_apply_pose()
	var main := vehicle._main()
	if main != null and PlacedPropRuntime.find_by_prop_id(main, lid) != null:
		load_id = lid
		_carry_offset = Transform3D.IDENTITY


func _persist(save: bool) -> void:
	var main := vehicle._main()
	if main == null or vehicle.prop_id.is_empty():
		return
	var patch := {"fork_lift_m": lift_m, "fork_load_id": load_id}
	if save:
		PlacedPropService.update_prop_record(main, vehicle.prop_id, patch, false)
		return
	var layer = PlacedPropService._layer_for_main(main)
	if layer != null:
		layer.update_prop(vehicle.prop_id, patch)
