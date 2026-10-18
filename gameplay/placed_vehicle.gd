class_name PlacedVehicle
extends Node3D

## A driveable vehicle placed from the library (ModelCatalog entries carrying
## a `vehicle` profile id). Attached under its PlacedProp by
## PlacedPropRuntime._maybe_attach_vehicle and speaks the same duck-typed API
## as the scene vehicles (euc_vehicle.gd / golf_cart_vehicle.gd /
## skid_steer_vehicle.gd): mount / dismount / get_riding_params / can_mount /
## get_interaction_prompt plus the range signals, so the player's riding code
## drives it unchanged.
##
## Rules this file holds:
##   - The PLAYER moves; the vehicle follows (as every scene vehicle does). The
##     prop node follows the rider and ModelRoot takes the rider's yaw plus the
##     profile's `yaw_deg` (the art's own forward).
##   - Getting IN snaps the rider onto the parked vehicle facing its way (the
##     scene vehicles snap to the rider instead — a placed vehicle stays where
##     it was parked until somebody drives it).
##   - The prop's collision is OFF while ridden (the rider's capsule stands
##     inside it) and re-baked on dismount, AFTER the rider has stepped out to
##     the side — its StaticBody bakes ModelRoot's rotation into its shapes.
##   - The record is patched in memory every RECORD_EVERY_S while driving
##     (a full prop rebuild elsewhere respawns the vehicle under its rider
##     instead of back where it started) and saved once on dismount.
##   - Freed while ridden (a prop rebuild): the rider is handed to the new
##     node (`_handover`), not dumped on the ground.
##   - Electric vehicles drain their battery with distance and trickle-charge
##     while parked (a charger at camp is assumed), so a flat battery is a
##     wait, never a dead end. Fuel vehicles show "fuel" on the dashboard.

signal player_entered_range(vehicle: Node3D)
signal player_exited_range(vehicle: Node3D)
signal mounted(player: Node3D)
signal dismounted(player: Node3D)

## Riding profiles. Numbers for the three original vehicles are copied from
## their scene scripts (euc_vehicle.gd, golf_cart_vehicle.gd with the SOAK
## scene's camera override, skid_steer_vehicle.gd) so a placed Appa drives
## exactly like the one in the scene. yaw_deg: the art's forward relative to
## the rider (the scene scripts' model offsets; the skid steer's 91.145 RAD
## is ~182.2 deg). battery_wh 0 = a fuel vehicle. chase_m / chase_h: the
## third-person camera's distance and height behind it.
const PROFILES := {
	"euc": {
		"display_name": "Electric Unicycle", "prompt": "Ride the EUC",
		"speed_multiplier": 3.0, "max_speed": 25.0, "max_camera_tilt": 25.0,
		"tilt_speed": 5.0, "camera_shake_intensity": 0.015, "camera_shake_speed": 15.0,
		"min_shake_speed": 1.0, "camera_offset": Vector3.ZERO, "is_golf_cart": false,
		"use_cart_steering": false, "min_turn_radius": 0.0, "max_turn_rate": 0.0,
		"yaw_deg": 90.0, "radius": 2.0, "battery_wh": 1000.0, "wh_per_mile": 30.0,
		"charge_w": 500.0, "chase_m": 3.6, "chase_h": 1.2,
	},
	"golf_cart": {
		"display_name": "Appa", "prompt": "Appa, Yip Yip!",
		"speed_multiplier": 1.5, "max_speed": 5.36, "max_camera_tilt": 0.0,
		"tilt_speed": 0.0, "camera_shake_intensity": 0.025, "camera_shake_speed": 12.0,
		"min_shake_speed": 0.5, "camera_offset": Vector3(-0.65, -0.43, 0.0), "is_golf_cart": true,
		"use_cart_steering": true, "min_turn_radius": 3.0, "max_turn_rate": 60.0,
		"yaw_deg": -90.0, "radius": 3.0, "battery_wh": 5200.0, "wh_per_mile": 250.0,
		"charge_w": 1000.0, "chase_m": 5.5, "chase_h": 1.8,
	},
	"skid_steer": {
		"display_name": "Skid Steer", "prompt": "Drive the skid steer",
		"speed_multiplier": 0.8, "max_speed": 2.24, "max_camera_tilt": 0.0,
		"tilt_speed": 0.0, "camera_shake_intensity": 0.008, "camera_shake_speed": 8.0,
		"min_shake_speed": 0.3, "camera_offset": Vector3(0.0, 0.3, 0.2), "is_golf_cart": true,
		"use_cart_steering": true, "min_turn_radius": 0.5, "max_turn_rate": 90.0,
		"yaw_deg": 182.22, "radius": 3.5, "battery_wh": 0.0, "wh_per_mile": 0.0,
		"charge_w": 0.0, "chase_m": 5.5, "chase_h": 2.0,
	},
	# A school-bus conversion: 25 mph on site roads, a wide turn, the driver's
	# seat up front on the left (the model's front is toward -Z).
	"bus": {
		"display_name": "Tool Bus", "prompt": "Drive the bus",
		"speed_multiplier": 0.7, "max_speed": 11.2, "max_camera_tilt": 0.0,
		"tilt_speed": 0.0, "camera_shake_intensity": 0.01, "camera_shake_speed": 6.0,
		"min_shake_speed": 0.5, "camera_offset": Vector3(-0.75, 0.75, -4.4), "is_golf_cart": true,
		"use_cart_steering": true, "min_turn_radius": 10.0, "max_turn_rate": 22.0,
		"yaw_deg": 0.0, "radius": 7.0, "battery_wh": 0.0, "wh_per_mile": 0.0,
		"charge_w": 0.0, "chase_m": 14.0, "chase_h": 4.5,
	},
	"van": {
		"display_name": "Camper Van", "prompt": "Drive the van",
		"speed_multiplier": 0.9, "max_speed": 15.6, "max_camera_tilt": 0.0,
		"tilt_speed": 0.0, "camera_shake_intensity": 0.012, "camera_shake_speed": 8.0,
		"min_shake_speed": 0.5, "camera_offset": Vector3(-0.45, 0.3, -1.2), "is_golf_cart": true,
		"use_cart_steering": true, "min_turn_radius": 6.0, "max_turn_rate": 35.0,
		"yaw_deg": 0.0, "radius": 4.5, "battery_wh": 0.0, "wh_per_mile": 0.0,
		"charge_w": 0.0, "chase_m": 8.0, "chase_h": 2.8,
	},
}

const RECORD_EVERY_S := 0.5
## Where a dismounting rider steps to: beside the vehicle, this far past its
## half-width (its left, the driver's door on a bus or a van).
const STEP_OUT_M := 0.7

## Riders being handed from a vehicle node that is being freed to the node
## that replaces it (prop id -> rider). See _exit_tree / _ready.
static var _handover: Dictionary = {}

var profile_id := ""
var profile: Dictionary = {}
var display_name := ""
var interaction_prompt := ""
var prop_id := ""
var model_id := ""

var is_mounted := false
var current_rider: CharacterBody3D = null
var player_in_range: CharacterBody3D = null

# Dashboard fields (scenes/ui/euc_ui.gd reads these by name).
var battery_wh := 0.0
var battery_capacity_wh := 0.0
var wh_per_mile := 0.0
var distance_traveled_meters := 0.0
var current_speed_mps := 0.0

var _prop: Node3D = null
var _model: Node3D = null
var _dy := 0.0
var _last_pos := Vector3.ZERO
var _record_accum := 0.0
var _charge_accum := 0.0
var _area: Area3D = null
var _freeing_for_handover := false


## Which profile a catalog model drives with ("" = not a vehicle).
static func profile_for_model(mid: String) -> String:
	var p := str(ModelCatalog.find(mid).get("vehicle", ""))
	return p if PROFILES.has(p) else ""


func setup(prop: Node3D, model: Node3D, rec: Dictionary, pid: String) -> void:
	_prop = prop
	_model = model
	profile_id = pid
	profile = PROFILES.get(pid, {})
	prop_id = str(rec.get("id", ""))
	model_id = str(rec.get("model_id", ""))
	var entry := ModelCatalog.find(model_id)
	display_name = str(entry.get("vehicle_name", profile.get("display_name", "Vehicle")))
	interaction_prompt = str(profile.get("prompt", "Drive"))
	battery_capacity_wh = float(profile.get("battery_wh", 0.0))
	wh_per_mile = float(profile.get("wh_per_mile", 0.0))
	battery_wh = clampf(float(rec.get("vehicle_battery_wh", battery_capacity_wh)), 0.0, battery_capacity_wh)
	distance_traveled_meters = float(rec.get("vehicle_odo_m", 0.0))


func _ready() -> void:
	add_to_group("vehicles")
	_area = Area3D.new()
	_area.name = "InteractionArea"
	_area.collision_layer = 0
	_area.collision_mask = 1
	_area.monitorable = false
	var cs := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = _range_radius()
	cs.shape = sphere
	_area.add_child(cs)
	add_child(_area)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)
	if _handover.has(prop_id):
		var rider: Variant = _handover[prop_id]
		_handover.erase(prop_id)
		if rider is CharacterBody3D and is_instance_valid(rider):
			_remount_after_rebuild.call_deferred(rider)


func _range_radius() -> float:
	var r := float(profile.get("radius", 3.0))
	if _prop != null and not model_id.is_empty():
		var rec := _record()
		var fp := PlacedPropService.footprint_from_model(model_id, float(rec.get("scale", 1.0)))
		r = maxf(r, maxf(fp.x, fp.y) * 0.5 + 1.2)
	return r


func _remount_after_rebuild(rider: CharacterBody3D) -> void:
	if not is_inside_tree() or not is_instance_valid(rider):
		return
	if rider.has_method("request_mount"):
		rider.call("request_mount", self)


func _exit_tree() -> void:
	# Only a prop REBUILD hands the rider over — never the map unloading
	# (then the player, the UI and the layer are all going too).
	var main := _main()
	if main == null or main.is_queued_for_deletion() or not main.is_inside_tree():
		return
	if is_mounted and current_rider != null and is_instance_valid(current_rider) \
			and current_rider.is_inside_tree() and not current_rider.is_queued_for_deletion() \
			and not prop_id.is_empty():
		# The prop is being rebuilt under its rider: keep the record where the
		# vehicle is now and hand the rider to the replacement node.
		_patch_record(false)
		_handover[prop_id] = current_rider
		_freeing_for_handover = true
		if current_rider.has_method("_dismount_vehicle"):
			current_rider.call("_dismount_vehicle")


func _process(delta: float) -> void:
	PerfSpan.begin("prop_ticks")
	_perf_tick(delta)
	PerfSpan.end("prop_ticks")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	if is_mounted and current_rider != null and is_instance_valid(current_rider) and _prop != null:
		_prop.global_position = current_rider.global_position + Vector3(0.0, _dy, 0.0)
		if _model != null:
			_model.rotation.y = current_rider.rotation.y + deg_to_rad(float(profile.get("yaw_deg", 0.0)))
		var p := _prop.global_position
		var step := Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
		_last_pos = p
		current_speed_mps = step / delta if delta > 0.0 else 0.0
		distance_traveled_meters += step
		if battery_capacity_wh > 0.0:
			battery_wh = maxf(battery_wh - step / 1609.344 * wh_per_mile, 0.0)
		_record_accum += delta
		if _record_accum >= RECORD_EVERY_S:
			_record_accum = 0.0
			_patch_record(false)
	elif battery_capacity_wh > 0.0 and battery_wh < battery_capacity_wh:
		# Parked: on the charger at camp. Sim time, so a fast clock charges fast.
		var hours := delta * _time_scale()
		battery_wh = minf(battery_wh + float(profile.get("charge_w", 0.0)) * hours, battery_capacity_wh)
		_charge_accum += hours
		if _charge_accum >= 0.25:
			_charge_accum = 0.0
			_patch_record(false)


func _time_scale() -> float:
	var main := _main()
	if main != null and "time_scale" in main:
		return maxf(float(main.get("time_scale")), 0.0)
	return 1.0 / 3600.0


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player") and body is CharacterBody3D:
		player_in_range = body
		player_entered_range.emit(self)
		if body.has_method("on_vehicle_nearby"):
			body.on_vehicle_nearby(self)


func _on_body_exited(body: Node3D) -> void:
	if body == player_in_range:
		player_in_range = null
		player_exited_range.emit(self)
		if body.has_method("on_vehicle_left_range"):
			body.on_vehicle_left_range(self)


# --- the vehicle API ---------------------------------------------------------

func mount(player: CharacterBody3D) -> bool:
	if is_mounted or player == null or _prop == null:
		return false
	if battery_capacity_wh > 0.0 and battery_wh <= 0.0:
		return false
	is_mounted = true
	current_rider = player
	if _prop.has_method("set_collision_enabled"):
		_prop.call("set_collision_enabled", false)
	# Get IN where it is parked, facing its way.
	var p := _prop.global_position
	# The footing the prop was seated on (its record), not a fresh ray.
	var gy := float(_record().get("ground_y", NAN))
	if is_nan(gy):
		gy = _ground_at(p.x, p.z, p.y)
	_dy = p.y - gy
	player.global_position = Vector3(p.x, gy + 0.05, p.z)
	player.velocity = Vector3.ZERO
	if _model != null:
		player.rotation.y = _model.rotation.y - deg_to_rad(float(profile.get("yaw_deg", 0.0)))
	_last_pos = p
	current_speed_mps = 0.0
	mounted.emit(player)
	return true


func dismount() -> void:
	if not is_mounted:
		return
	var rider := current_rider
	is_mounted = false
	current_rider = null
	current_speed_mps = 0.0
	if _freeing_for_handover:
		dismounted.emit(rider)
		return
	if rider != null and is_instance_valid(rider):
		# Step out on the left, clear of the body, then re-bake the collision.
		var half := _half_width()
		var left := -rider.global_transform.basis.x
		left.y = 0.0
		left = left.normalized() if left.length() > 1e-4 else Vector3.LEFT
		var out := rider.global_position + left * (half + STEP_OUT_M)
		out.y = _ground_at(out.x, out.z, rider.global_position.y) + 0.05
		rider.global_position = out
		rider.velocity = Vector3.ZERO
	_patch_record(true)
	if _prop != null and _prop.has_method("setup_collision"):
		_prop.call_deferred("setup_collision")
	dismounted.emit(rider)


func get_riding_params() -> Dictionary:
	var keys := ["speed_multiplier", "max_speed", "max_camera_tilt", "tilt_speed",
		"camera_shake_intensity", "camera_shake_speed", "camera_offset", "min_shake_speed",
		"is_golf_cart", "use_cart_steering", "min_turn_radius", "max_turn_rate"]
	var out := {}
	for k in keys:
		out[k] = profile.get(k)
	out["chase_m"] = float(profile.get("chase_m", 5.0)) * _user_scale()
	out["chase_h"] = float(profile.get("chase_h", 1.8)) * _user_scale()
	return out


func get_interaction_prompt() -> String:
	if battery_capacity_wh > 0.0 and battery_wh <= 0.0:
		return "%s — battery flat, charging" % display_name
	return interaction_prompt


func can_mount() -> bool:
	return not is_mounted and (battery_capacity_wh <= 0.0 or battery_wh > 0.0)


func get_speed_mps() -> float:
	return current_speed_mps


func get_speed_mph() -> float:
	return current_speed_mps * 2.237


func get_battery_percent() -> float:
	return 100.0 * battery_wh / battery_capacity_wh if battery_capacity_wh > 0.0 else 100.0


# --- helpers -------------------------------------------------------------------

func _main() -> Node:
	var n: Node = self
	while n != null:
		if n.has_method("get_absolute_hours"):
			return n
		n = n.get_parent()
	return get_tree().root.find_child("Main", true, false) if get_tree() != null else null


func _record() -> Dictionary:
	var main := _main()
	if main == null or prop_id.is_empty():
		return {}
	return PlacedPropService.get_prop_record(main, prop_id)


func _user_scale() -> float:
	return clampf(float(_record().get("scale", 1.0)), 0.2, 5.0)


func _half_width() -> float:
	var fp := PlacedPropService.footprint_from_model(model_id, _user_scale())
	return clampf(minf(fp.x, fp.y) * 0.5, 0.2, 2.0)


func _ground_at(x: float, z: float, fallback: float) -> float:
	var main := _main()
	if main == null:
		return fallback
	var gy := TerrainSurfaceQuery.ground_height_at(main, x, z)
	return gy if not is_nan(gy) else fallback


## Where the vehicle is now -> its prop record. `save` writes the layer to
## disk (dismount); otherwise only the in-memory record moves, so a rebuild
## respawns the vehicle under its rider without a disk write every half second.
func _patch_record(save: bool) -> void:
	var main := _main()
	if main == null or prop_id.is_empty() or _prop == null:
		return
	var p := _prop.global_position
	var patch := {"x": p.x, "z": p.z, "ground_y": p.y - _dy if is_mounted else _ground_at(p.x, p.z, p.y),
		"vehicle_odo_m": distance_traveled_meters}
	if _model != null:
		patch["yaw"] = fposmod(rad_to_deg(_model.rotation.y), 360.0)
	if battery_capacity_wh > 0.0:
		patch["vehicle_battery_wh"] = battery_wh
	if save:
		PlacedPropService.update_prop_record(main, prop_id, patch, false)
		return
	var layer := PlacedPropService._layer_for_main(main)
	if layer != null:
		layer.update_prop(prop_id, patch)
