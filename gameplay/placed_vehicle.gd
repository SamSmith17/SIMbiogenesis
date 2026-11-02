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
	# A 2.5 t electric counterbalance forklift: walking pace on a loaded site,
	# rear-wheel steer (tight turns), the forks toward the model's -Z.
	# ForkliftRig drives the mast and the forks while it is ridden.
	"forklift": {
		"display_name": "Forklift", "prompt": "Drive the forklift",
		"speed_multiplier": 0.6, "max_speed": 3.5, "max_camera_tilt": 0.0,
		"tilt_speed": 0.0, "camera_shake_intensity": 0.006, "camera_shake_speed": 7.0,
		"min_shake_speed": 0.3, "camera_offset": Vector3(0.0, 0.55, 0.35), "is_golf_cart": true,
		"use_cart_steering": true, "min_turn_radius": 1.8, "max_turn_rate": 80.0,
		"yaw_deg": 0.0, "radius": 3.0, "battery_wh": 20000.0, "wh_per_mile": 600.0,
		"charge_w": 3000.0, "chase_m": 6.0, "chase_h": 2.6,
	},
}

## A living vehicle (core/vehiclelab/): its profile comes from its design
## (VehicleDesign.riding_profile), not from PROFILES.
const LIVING := "living"

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
## Liquid fuel (a living vehicle on a gasoline / diesel chassis). An empty tank
## is filled from a can on the next get-in — never a dead end — and every
## litre burned is counted (`vehicle_fuel_used_l`) so the cost of driving it
## round the site is known.
var fuel_l := 0.0
var fuel_capacity_l := 0.0
var fuel_used_l := 0.0
## Litres poured in from a can because no fuel store was in reach (bought off
## site: the trip's running cost).
var fuel_bought_l := 0.0
## How far a fuel store may stand from the vehicle to fill it.
const REFUEL_REACH_M := 12.0
## Towing (VehicleTow): the trailer's prop id (record key `towing`, the
## trailer's `hitched_to`), its design, where its axle is, its height over the
## ground, and the half-second scan for a trailer to back up to.
var _tow_id := ""
var _tow_node: Node3D = null
var _tow_design: Dictionary = {}
var _tow_axle := Vector2.ZERO
var _tow_dy := 0.0
var _tow_ready := false
var _hitch_scan := 0.0
## Crates stowed in the cargo bay (record `stowed_in` = this vehicle, with
## `stow_local`): they ride along. Re-scanned every couple of seconds.
var _cargo_ids: Array = []
var _cargo_scan := 9.0
var _design: Dictionary = {}

var _prop: Node3D = null
var _model: Node3D = null
var _dy := 0.0
var _last_pos := Vector3.ZERO
## Wheels: metres rolled (signed) and the smoothed steering angle.
var _roll_m := 0.0
var _steer := 0.0
var _last_yaw := 0.0
var _record_accum := 0.0
var _charge_accum := 0.0
## Watts the charger draws right now (0 parked-full, driving, or with the
## graph's AC off). GraphAcLoad reads it through the load's scene_device_path.
var _charging_w := 0.0
var _load_gid := ""
var _load_gid_accum := 9.0
var _area: Area3D = null
var _freeing_for_handover := false


## Which profile a catalog model drives with ("" = not a vehicle).
static func profile_for_model(mid: String) -> String:
	var p := str(ModelCatalog.find(mid).get("vehicle", ""))
	if p == LIVING:
		return p
	return p if PROFILES.has(p) else ""


## A living vehicle's riding profile from its record ({} = it cannot be
## driven: a trailer).
static func living_profile(rec: Dictionary) -> Dictionary:
	return VehicleDesign.riding_profile(VehicleDesign.solve(VehicleBuilder.spec_for_record(rec)))


func setup(prop: Node3D, model: Node3D, rec: Dictionary, pid: String) -> void:
	_prop = prop
	_model = model
	profile_id = pid
	profile = PROFILES.get(pid, {})
	if pid == LIVING:
		_design = VehicleDesign.solve(VehicleBuilder.spec_for_record(rec))
		profile = VehicleDesign.riding_profile(_design)
		fuel_capacity_l = float(profile.get("fuel_l", 0.0))
		fuel_l = clampf(float(rec.get("vehicle_fuel_l", fuel_capacity_l)), 0.0, fuel_capacity_l)
		fuel_used_l = float(rec.get("vehicle_fuel_used_l", 0.0))
		fuel_bought_l = float(rec.get("vehicle_fuel_bought_l", 0.0))
		_tow_id = str(rec.get("towing", ""))
	prop_id = str(rec.get("id", ""))
	model_id = str(rec.get("model_id", ""))
	var entry := ModelCatalog.find(model_id)
	display_name = str(entry.get("vehicle_name", profile.get("display_name", "Vehicle")))
	interaction_prompt = str(profile.get("prompt", "Drive"))
	battery_capacity_wh = float(profile.get("battery_wh", 0.0))
	wh_per_mile = float(profile.get("wh_per_mile", 0.0))
	battery_wh = clampf(float(rec.get("vehicle_battery_wh", battery_capacity_wh)), 0.0, battery_capacity_wh)
	distance_traveled_meters = float(rec.get("vehicle_odo_m", 0.0))
	_load_gid = str(rec.get("graph_item_id", ""))
	if battery_capacity_wh > 0.0 and float(profile.get("charge_w", 0.0)) > 0.0:
		call_deferred("_ensure_graph_load")


## An electric vehicle's charger is an AC load on the graph (an appliance
## bound to this prop, drawing what the charger draws), made once on
## placement; without a graph it keeps charging for free, as before.
func _ensure_graph_load() -> void:
	if not _load_gid.is_empty() or _prop == null or prop_id.is_empty():
		return
	var gv := ServiceLocator.graph()
	if gv == null or not gv.has_method("add_placed_vehicle_load"):
		return
	var gid := str(gv.call("add_placed_vehicle_load", prop_id, display_name,
		float(profile.get("charge_w", 0.0)), str(get_path()), _prop.global_position))
	if gid.is_empty():
		return
	_load_gid = gid
	var main := _main()
	if main != null:
		PlacedPropService.update_prop_record(main, prop_id, {"graph_item_id": gid}, false)


## What the charger draws right now, for the graph's AC load.
func get_current_power() -> float:
	return _charging_w


## With a graph load the charger runs only while that load is on and the
## site's AC is up (the same rule a placed light follows).
func _charger_powered() -> bool:
	if _load_gid.is_empty():
		return true
	return PlacedLightPower.graph_item_on(_load_gid) and PlacedLightPower.ac_available(_main())


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
	if profile_id == LIVING:
		return r
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
		var mv := Vector2(p.x - _last_pos.x, p.z - _last_pos.z)
		var step := mv.length()
		if profile_id == LIVING:
			var yw := _yaw()
			var ds := mv.dot(VehicleDrive.forward(yw))
			_roll_m += ds
			var want := VehicleBuilder.steer_for(VehicleBuilder.wheelbase_of(_design), angle_difference(_last_yaw, yw), ds)
			_last_yaw = yw
			_steer = lerpf(_steer, want, clampf(delta * 6.0, 0.0, 1.0))
			VehicleBuilder.spin_wheels(_model, _roll_m, _steer)
		_last_pos = p
		current_speed_mps = step / delta if delta > 0.0 else 0.0
		distance_traveled_meters += step
		if battery_capacity_wh > 0.0:
			battery_wh = maxf(battery_wh - step / 1609.344 * wh_per_mile, 0.0)
		_tick_tow(delta)
		_tick_cargo(delta)
		if fuel_capacity_l > 0.0 and step > 0.0:
			var burned := float(VehicleDesign.energy_for_distance(_design, step, current_speed_mps,
				_tow_design if not _tow_id.is_empty() else {})["litres"])
			fuel_l = maxf(fuel_l - burned, 0.0)
			fuel_used_l += burned
		_record_accum += delta
		if _record_accum >= RECORD_EVERY_S:
			_record_accum = 0.0
			_patch_record(false)
	elif battery_capacity_wh > 0.0 and battery_wh < battery_capacity_wh:
		# Parked: on the charger at camp. Sim time, so a fast clock charges fast.
		_load_gid_accum += delta
		if _load_gid_accum >= 3.0:
			_load_gid_accum = 0.0
			_load_gid = str(_record().get("graph_item_id", _load_gid))
		if _charger_powered():
			var hours := delta * _time_scale()
			_charging_w = float(profile.get("charge_w", 0.0))
			battery_wh = minf(battery_wh + _charging_w * hours, battery_capacity_wh)
			_charge_accum += hours
			if _charge_accum >= 0.25:
				_charge_accum = 0.0
				_patch_record(false)
		else:
			_charging_w = 0.0
	else:
		_charging_w = 0.0


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
	# Driven by the player, it is simply here: its drive in through the gate
	# (VehicleDrive) is over and forgotten.
	var main_m := _main()
	if main_m != null and _record().has("arrival"):
		PlacedPropService.update_prop_record(main_m, prop_id, {"arrival": null}, false)
	refuel()
	if fuel_capacity_l > 0.0 and fuel_l <= 0.01:
		fuel_bought_l += fuel_capacity_l - fuel_l
		fuel_l = fuel_capacity_l   # filled from a can: see the fuel note above
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
	_last_yaw = _yaw()
	current_speed_mps = 0.0
	if profile_id == LIVING:
		VehicleBuilder.set_inside_view(_model, true)
	mounted.emit(player)
	return true


func dismount() -> void:
	if not is_mounted:
		return
	var rider := current_rider
	is_mounted = false
	current_rider = null
	current_speed_mps = 0.0
	if profile_id == LIVING:
		VehicleBuilder.set_inside_view(_model, false)
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
	refuel()
	_patch_record(true)
	_park_trailer()
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
	# Not while it is still on its way in through the gate (VehicleDriveRuntime).
	if _prop != null and _prop.has_meta(VehicleDriveRuntime.META_BUSY):
		return false
	return not is_mounted and (battery_capacity_wh <= 0.0 or battery_wh > 0.0)


func get_speed_mps() -> float:
	return current_speed_mps


func get_speed_mph() -> float:
	return current_speed_mps * 2.237


## Litres left and the tank's size (0 / 0 for anything that does not burn fuel).
func get_fuel_litres() -> Vector2:
	return Vector2(fuel_l, fuel_capacity_l)


## Miles left at 55 mph (-1 when the profile does not know: the old vehicles).
func get_range_mi() -> float:
	if _design.is_empty():
		return -1.0
	return VehicleDesign.range_mi(_design, fuel_l, battery_wh / 1000.0,
		_tow_design if not _tow_id.is_empty() else {})


## Top the tank up from a fuel store of the right kind within reach (the graph's
## "Fuel Store" tanks). Returns the litres taken.
func refuel() -> float:
	if fuel_capacity_l <= 0.0 or _prop == null or _design.is_empty():
		return 0.0
	var want := fuel_capacity_l - fuel_l
	if want < 0.5:
		return 0.0
	var main := _main()
	if main == null:
		return 0.0
	var sgv := PlacedPropService._system_graph_view(main)
	if sgv == null or not sgv.has_method("draw_fuel_near"):
		return 0.0
	var r: Dictionary = sgv.call("draw_fuel_near", _prop.global_position, str(_design.get("fuel", "")), want, REFUEL_REACH_M)
	var got := float(r.get("litres", 0.0))
	if got <= 0.0:
		return 0.0
	fuel_l = minf(fuel_l + got, fuel_capacity_l)
	if main.has_method("show_toast"):
		main.call("show_toast", "Filled up: %.0f L of %s from %s" % [got, str(_design.get("fuel", "fuel")), str(r.get("name", "the fuel store"))])
	_patch_record(false)
	return got


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
	if profile.has("half_width"):
		return clampf(float(profile["half_width"]) * _user_scale(), 0.2, 2.0)
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
	if fuel_capacity_l > 0.0:
		patch["vehicle_fuel_l"] = fuel_l
		patch["vehicle_fuel_used_l"] = fuel_used_l
		patch["vehicle_fuel_bought_l"] = fuel_bought_l
	var layer0 := PlacedPropService._layer_for_main(main)
	var cargo_patches := {}
	if layer0 != null and not _cargo_ids.is_empty():
		var vrec := {"id": prop_id, "x": p.x, "z": p.z, "yaw": float(patch.get("yaw", 0.0))}
		cargo_patches = VehicleCargo.reseat_patches(layer0.props, vrec)
	var tpatch := {}
	if _tow_ready and _tow_node != null and is_instance_valid(_tow_node):
		var tp := _tow_node.global_position
		tpatch = {"x": tp.x, "z": tp.z, "ground_y": tp.y - _tow_dy}
		var tm := _tow_node.get_node_or_null("ModelRoot") as Node3D
		if tm != null:
			tpatch["yaw"] = fposmod(rad_to_deg(tm.rotation.y), 360.0)
	if save:
		PlacedPropService.update_prop_record(main, prop_id, patch, false)
		if not tpatch.is_empty():
			PlacedPropService.update_prop_record(main, _tow_id, tpatch, false)
		for cid in cargo_patches:
			PlacedPropService.update_prop_record(main, str(cid), cargo_patches[cid], false)
		return
	var layer := PlacedPropService._layer_for_main(main)
	if layer != null:
		layer.update_prop(prop_id, patch)
		if not tpatch.is_empty():
			layer.update_prop(_tow_id, tpatch)
		for cid2 in cargo_patches:
			layer.update_prop(str(cid2), cargo_patches[cid2])


# --- cargo ----------------------------------------------------------------------

## Stowed crates move with the vehicle (their nodes every frame; their records
## with the vehicle's own, in _patch_record).
func _tick_cargo(delta: float) -> void:
	_cargo_scan += delta
	var main := _main()
	if main == null:
		return
	if _cargo_scan >= 2.0:
		_cargo_scan = 0.0
		_cargo_ids.clear()
		var layer := PlacedPropService._layer_for_main(main)
		if layer != null:
			for r in layer.props:
				var rec: Dictionary = r
				if str(rec.get("stowed_in", "")) == prop_id and rec.get("stow_local") is Array:
					_cargo_ids.append(str(rec.get("id", "")))
	if _cargo_ids.is_empty() or _prop == null:
		return
	var origin := Vector2(_prop.global_position.x, _prop.global_position.z)
	var base_y := _prop.global_position.y - _dy
	for cid in _cargo_ids:
		var node := PlacedPropRuntime.find_by_prop_id(main, str(cid)) as Node3D
		var rec2 := PlacedPropService.get_prop_record(main, str(cid))
		if node == null or not (rec2.get("stow_local") is Array):
			continue
		var sl: Array = rec2["stow_local"]
		var w := VehicleTow.world_xz(Vector3(float(sl[0]), float(sl[1]), float(sl[2])), origin, _yaw())
		node.global_position = Vector3(w.x, base_y + float(sl[1]), w.y)
		var m := node.get_node_or_null("ModelRoot") as Node3D
		if m != null:
			m.rotation.y = _yaw() + deg_to_rad(float(sl[3]))


# --- towing --------------------------------------------------------------------

func _yaw() -> float:
	return _model.rotation.y if _model != null else 0.0


## The trailer's prop node (re-found after a prop rebuild).
func _tow_prop() -> Node3D:
	if _tow_node != null and is_instance_valid(_tow_node) and _tow_node.is_inside_tree():
		return _tow_node
	_tow_node = null
	var main := _main()
	if main == null or _tow_id.is_empty():
		return null
	_tow_node = PlacedPropRuntime.find_by_prop_id(main, _tow_id)
	_tow_ready = false
	return _tow_node


## Move the hitched trailer behind the hitch; with none, hitch one the
## driver has backed up to.
func _tick_tow(delta: float) -> void:
	if _design.is_empty() or not _design.has("hitch") or _prop == null:
		return
	var origin := Vector2(_prop.global_position.x, _prop.global_position.z)
	var hitch := VehicleTow.world_xz(_design["hitch"], origin, _yaw())
	if _tow_id.is_empty():
		_hitch_scan += delta
		if _hitch_scan >= 0.25 and current_speed_mps < VehicleTow.HITCH_MAX_SPEED:
			_hitch_scan = 0.0
			_try_hitch(hitch)
		return
	var node := _tow_prop()
	if node == null:
		return
	if not _tow_ready:
		var rec := PlacedPropService.get_prop_record(_main(), _tow_id)
		if rec.is_empty():
			_tow_id = ""
			return
		_tow_design = VehicleDesign.solve(VehicleBuilder.spec_for_record(rec))
		var p := node.global_position
		_tow_axle = VehicleTow.axle_at(_tow_design, Vector2(p.x, p.z), deg_to_rad(float(rec.get("yaw", 0.0))))
		_tow_dy = p.y - _ground_at(p.x, p.z, p.y)
		if node.has_method("set_collision_enabled"):
			node.call("set_collision_enabled", false)
		_tow_ready = true
	var fwd := Vector2(-sin(_yaw()), -cos(_yaw()))
	_tow_axle = VehicleTow.step_axle_limited(hitch, _tow_axle, VehicleTow.tongue_m(_tow_design), fwd)
	var pose := VehicleTow.trailer_pose(_tow_design, hitch, _tow_axle)
	var o: Vector2 = pose["origin"]
	node.global_position = Vector3(o.x, _ground_at(o.x, o.y, node.global_position.y) + _tow_dy, o.y)
	var m := node.get_node_or_null("ModelRoot") as Node3D
	if m != null:
		m.rotation.y = float(pose["yaw"])


## A parked trailer whose coupler is within reach of the hitch ball.
func _try_hitch(hitch: Vector2) -> void:
	var main := _main()
	var layer := PlacedPropService._layer_for_main(main) if main != null else null
	if layer == null:
		return
	for r in layer.props:
		var rec: Dictionary = r
		var id := str(rec.get("id", ""))
		if id == prop_id or not VehicleBuilder.handles(str(rec.get("model_id", ""))):
			continue
		if not str(rec.get("hitched_to", "")).is_empty():
			continue
		var at := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
		if at.distance_to(hitch) > 20.0:
			continue
		var td := VehicleDesign.solve(VehicleBuilder.spec_for_record(rec))
		if bool(td.get("drivable", true)) or not td.has("coupler"):
			continue
		var c := VehicleTow.world_xz(td["coupler"], at, deg_to_rad(float(rec.get("yaw", 0.0))))
		if c.distance_to(hitch) <= VehicleTow.HITCH_TOL_M:
			hitch_to(id)
			return


## Hitch the trailer with this prop id.
func hitch_to(trailer_id: String) -> void:
	var main := _main()
	if main == null or trailer_id.is_empty():
		return
	_tow_id = trailer_id
	_tow_ready = false
	PlacedPropService.update_prop_record(main, prop_id, {"towing": trailer_id}, false)
	PlacedPropService.update_prop_record(main, trailer_id, {"hitched_to": prop_id}, false)
	if main.has_method("show_toast"):
		var rec := PlacedPropService.get_prop_record(main, trailer_id)
		var nm := str(VehicleBuilder.spec_for_record(rec).get("name", "the trailer"))
		# What the ratings say about the pair (VehicleTow.tow_check): the
		# first two notes ride the toast.
		var notes := VehicleTow.tow_check(_design, VehicleDesign.solve(VehicleBuilder.spec_for_record(rec)))
		var text := "Hitched: %s" % nm
		for i in mini(notes.size(), 2):
			text += "\n" + str((notes[i] as Dictionary)["text"])
		main.call("show_toast", text)


## Leave the trailer standing where it is.
func unhitch() -> void:
	if _tow_id.is_empty():
		return
	_park_trailer()
	var main := _main()
	var tid := _tow_id
	_tow_id = ""
	_tow_ready = false
	_tow_node = null
	if main != null:
		PlacedPropService.update_prop_record(main, prop_id, {"towing": null}, false)
		PlacedPropService.update_prop_record(main, tid, {"hitched_to": null}, false)


## The trailer stops: its record saved and its collision baked again.
func _park_trailer() -> void:
	if _tow_id.is_empty():
		return
	var node := _tow_prop() if _tow_ready or _tow_node != null else null
	if node != null and _tow_ready:
		var main := _main()
		var tp := node.global_position
		var tpatch := {"x": tp.x, "z": tp.z, "ground_y": tp.y - _tow_dy}
		var tm := node.get_node_or_null("ModelRoot") as Node3D
		if tm != null:
			tpatch["yaw"] = fposmod(rad_to_deg(tm.rotation.y), 360.0)
		if main != null:
			PlacedPropService.update_prop_record(main, _tow_id, tpatch, false)
		if node.has_method("setup_collision"):
			node.call_deferred("setup_collision")
	_tow_ready = false


## Unhitch whatever `pid` tows or is hitched to (the prop editor's button).
static func unhitch_prop(main: Node, pid: String) -> void:
	var rec := PlacedPropService.get_prop_record(main, pid)
	var tow_id := pid if not str(rec.get("towing", "")).is_empty() else str(rec.get("hitched_to", ""))
	if tow_id.is_empty():
		return
	var tow := PlacedPropRuntime.find_by_prop_id(main, tow_id)
	var pv := tow.get_node_or_null("PlacedVehicle") if tow != null else null
	if pv != null and pv.has_method("unhitch"):
		pv.call("unhitch")
		return
	var trec := PlacedPropService.get_prop_record(main, tow_id)
	var tid := str(trec.get("towing", ""))
	PlacedPropService.update_prop_record(main, tow_id, {"towing": null}, false)
	if not tid.is_empty():
		PlacedPropService.update_prop_record(main, tid, {"hitched_to": null}, false)
