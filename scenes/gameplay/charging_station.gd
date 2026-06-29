extends Node3D

## Charging station / outlet for electric vehicles (EUC, golf cart, etc.)
## Player can approach and plug in their vehicle to charge from the main power system

signal euc_entered_range(station: Node3D, euc: Node3D)
signal euc_exited_range(station: Node3D)
signal charging_started(station: Node3D, euc: Node3D)
signal charging_stopped(station: Node3D, euc: Node3D)

## Interaction range in meters (30 feet = ~9 meters) - large enough for golf carts
@export var interaction_radius : float = 9.0

## Display name for UI
@export var display_name : String = "Charging Station"

# State
var euc_in_range : Node3D = null
var player_in_range : CharacterBody3D = null
var is_charging : bool = false
var current_euc : Node3D = null

const _EUC_SCAN_INTERVAL : float = 0.5
var _euc_scan_timer : float = 0.0

# Detection areas
var interaction_area : Area3D

func _ready() -> void:
	_setup_interaction_area()

func _setup_interaction_area() -> void:
	# Create Area3D for detection
	interaction_area = Area3D.new()
	interaction_area.name = "InteractionArea"
	interaction_area.collision_layer = 0
	interaction_area.collision_mask = 1  # Detect player and objects on layer 1
	add_child(interaction_area)
	
	# Create collision shape (sphere with 6ft radius)
	var collision_shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = interaction_radius
	collision_shape.shape = sphere_shape
	interaction_area.add_child(collision_shape)
	
	# Connect signals
	interaction_area.body_entered.connect(_on_body_entered)
	interaction_area.body_exited.connect(_on_body_exited)

func _process(delta: float) -> void:
	if euc_in_range != null and is_instance_valid(euc_in_range):
		var distance := global_position.distance_to(euc_in_range.global_position)
		if distance > interaction_radius * 1.5:
			_on_euc_left_range(euc_in_range)
	
	if player_in_range != null and euc_in_range == null and not is_charging:
		_euc_scan_timer += delta
		if _euc_scan_timer >= _EUC_SCAN_INTERVAL:
			_euc_scan_timer -= _EUC_SCAN_INTERVAL
			_check_for_euc_nearby()
	else:
		_euc_scan_timer = 0.0

func _on_body_entered(body: Node3D) -> void:
	# Check if it's the player
	if body.is_in_group("player") and body is CharacterBody3D:
		player_in_range = body
		# Check for EUC nearby when player enters
		call_deferred("_check_for_euc_nearby")
	
func _on_body_exited(body: Node3D) -> void:
	if body == player_in_range:
		player_in_range = null
		# If player leaves but EUC stays, keep charging
		if not is_charging:
			euc_exited_range.emit(self)
			euc_in_range = null

func _check_for_euc_nearby() -> void:
	var tree := get_tree()
	if tree == null:
		return
	
	var vehicles := tree.get_nodes_in_group("chargeable_vehicles")
	for vehicle in vehicles:
		if vehicle is Node3D and "battery_wh" in vehicle and "is_mounted" in vehicle:
			if not vehicle.is_mounted:
				var distance := global_position.distance_to(vehicle.global_position)
				if distance <= interaction_radius:
					if player_in_range != null:
						_on_euc_entered_range(vehicle)
					return

func _on_euc_entered_range(euc: Node3D) -> void:
	if euc_in_range == euc:
		return
	
	euc_in_range = euc
	euc_entered_range.emit(self, euc)

func _on_euc_left_range(euc: Node3D) -> void:
	if euc_in_range != euc:
		return
	
	# Stop charging if it was charging
	if is_charging and current_euc == euc:
		stop_charging()
	
	euc_in_range = null
	euc_exited_range.emit(self)

# ==================== PUBLIC API ====================

## Start charging the EUC
func start_charging(euc: Node3D) -> bool:
	if euc == null or not is_instance_valid(euc):
		return false
	
	if not "plug_in" in euc or not euc.has_method("plug_in"):
		return false
	
	# Check if EUC is mounted (can't charge while riding)
	if "is_mounted" in euc and euc.is_mounted:
		return false
	
	is_charging = true
	current_euc = euc
	euc.plug_in()
	
	# Start the charging visual effect on EUC
	if euc.has_method("start_charging_effect"):
		euc.start_charging_effect()
	
	charging_started.emit(self, euc)
	return true

## Stop charging the EUC
func stop_charging() -> void:
	if current_euc != null and is_instance_valid(current_euc):
		if current_euc.has_method("unplug"):
			current_euc.unplug()
		if current_euc.has_method("stop_charging_effect"):
			current_euc.stop_charging_effect()
		
		charging_stopped.emit(self, current_euc)
	
	is_charging = false
	current_euc = null

## Check if can start charging
func can_charge() -> bool:
	if euc_in_range == null or not is_instance_valid(euc_in_range):
		_check_for_euc_nearby()  # Re-check
	
	if euc_in_range == null:
		return false
	
	# Check if EUC is not mounted and not fully charged
	if "is_mounted" in euc_in_range and euc_in_range.is_mounted:
		return false
	
	if "battery_wh" in euc_in_range and "battery_capacity_wh" in euc_in_range:
		if euc_in_range.battery_wh >= euc_in_range.battery_capacity_wh:
			return false  # Already fully charged
	
	return true

## Check if currently charging
func is_currently_charging() -> bool:
	return is_charging

## Get the EUC in range (if any)
func get_euc_in_range() -> Node3D:
	return euc_in_range

