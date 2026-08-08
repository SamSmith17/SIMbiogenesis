extends Node

## Player Health and Hydration System
## 
## Health: "Fuck This" (0%) to "Fuck Yes!" (100%)
## Hydration: Decreases over time, increases with activity and sun exposure
## Dehydration causes health damage when below 10%
## Fire proximity causes damage with red fog feedback

signal health_changed(new_health: float, max_health: float)
signal hydration_changed(new_hydration: float, max_hydration: float)
signal player_died(cause: String)
signal damage_taken(amount: float, source: String)

# ===== HEALTH SETTINGS =====

@export_group("Health")
## Maximum health points
@export var max_health: float = 100.0

## Current health (0 = "Fuck This", 100 = "Fuck Yes!")
@export var current_health: float = 100.0:
	set(value):
		var old_health = current_health
		current_health = clampf(value, 0.0, max_health)
		if current_health != old_health:
			health_changed.emit(current_health, max_health)
			if current_health <= 0:
				_on_player_death()

## Health regeneration rate per second (when not taking damage)
@export var health_regen_rate: float = 1.0

## Delay before health starts regenerating after taking damage
@export var health_regen_delay: float = 5.0

# ===== HYDRATION SETTINGS =====

@export_group("Hydration")
## Maximum hydration
@export var max_hydration: float = 100.0

## Current hydration level
@export var current_hydration: float = 75.0:
	set(value):
		var old_hydration = current_hydration
		current_hydration = clampf(value, 0.0, max_hydration)
		if current_hydration != old_hydration:
			hydration_changed.emit(current_hydration, max_hydration)

## Base hydration drain per second (idle)
@export var hydration_drain_rate: float = 0.1

## Extra hydration drain per second while walking (adds to base)
@export var hydration_walk_drain: float = 0.15

## Extra hydration drain per second while running (adds to base)
@export var hydration_run_drain: float = 0.4

## Extra hydration drain per second in direct sunlight (sweat!)
@export var hydration_sun_drain: float = 0.1

## Hydration threshold that triggers health damage (percentage)
@export_range(0.0, 75.0, 1.0) var dehydration_damage_threshold: float = 50.0

## Health damage per second when dehydrated
@export var dehydration_damage_rate: float = 3.0

# ===== FIRE DAMAGE SETTINGS =====

@export_group("Fire Damage")
## Distance in meters that fire starts doing damage (3ft = ~0.91m)
@export var fire_damage_distance: float = 0.91

## Damage per second when too close to fire
@export var fire_damage_rate: float = 15.0

## How often to check for nearby fires (seconds)
@export var fire_check_interval: float = 0.2

## Damage per second at FULL breathing hazard (extreme weather). Two orders of
## magnitude below fire damage on purpose: smoke is a slow cumulative harm you
## are meant to be able to work through for a while and then retreat from, not
## a thing that kills you for walking past it.
@export var air_damage_rate: float = 0.35

## Fraction of air-quality damage still taken under cover. Not zero — an
## unfiltered building during a Hazardous smoke event fills with smoke, and
## "walls do not solve this one" is the whole character of the hazard.
const AIR_SHELTER_RELIEF := 0.35

## Overhead-cover raycast: how far up to look, and how often (seconds). Cached
## because it is a physics query with two per-frame callers.
const COVER_RAY_M := 40.0
const COVER_CHECK_INTERVAL := 0.5

# ===== INTERNAL STATE =====

var _player: CharacterBody3D = null
var _main_node: Node = null
var _time_since_damage: float = 999.0
var _fire_check_timer: float = 0.0
var _is_near_fire: bool = false
var _current_fire_damage: float = 0.0  # Scaled by proximity
var _last_damage_source: String = "unknown"
var _cover_cached: bool = false
var _cover_checked_at: float = -999.0

# Movement tracking for hydration
var _is_walking: bool = false
var _is_running: bool = false
var _is_in_sunlight: bool = false

func _ready() -> void:
	# Find player (parent should be player)
	_player = get_parent() as CharacterBody3D
	if _player == null:
		push_warning("PlayerHealth: Not attached to a CharacterBody3D")
	else:
		# Get fire damage distance from player if set
		if "fire_damage_distance" in _player:
			fire_damage_distance = _player.fire_damage_distance
	
	# Find main node for sun/time info
	call_deferred("_find_main_node")
	
	# Emit initial values
	health_changed.emit(current_health, max_health)
	hydration_changed.emit(current_hydration, max_hydration)

func _find_main_node() -> void:
	var tree = get_tree()
	if tree == null:
		return
	
	for child in tree.root.get_children():
		if "day_time" in child:
			_main_node = child
			return
	
	if tree.current_scene and "day_time" in tree.current_scene:
		_main_node = tree.current_scene

func _process(delta: float) -> void:
	if _main_node != null and not is_instance_valid(_main_node):
		_main_node = null
		_find_main_node()
	var gr := GameplayRulesImpl.from_node(self)
	if gr == null or not gr.is_survival_active():
		return
	_update_movement_state()
	if gr.is_hydration_enabled():
		_update_hydration(delta)
	if gr.is_health_enabled():
		_update_health_regen(delta)
		_check_dehydration_damage(delta)
	if gr.is_fire_damage_enabled():
		_check_fire_damage(delta)
	else:
		_fire_check_timer = 0.0
		_is_near_fire = false
		_current_fire_damage = 0.0

# ===== MOVEMENT STATE =====

func _update_movement_state() -> void:
	if _player == null:
		return
	
	var horizontal_speed = Vector2(_player.velocity.x, _player.velocity.z).length()
	
	# Determine movement state
	_is_walking = horizontal_speed > 0.5 and horizontal_speed < 6.0
	_is_running = horizontal_speed >= 6.0
	
	# Check sunlight exposure
	_is_in_sunlight = _check_sunlight()

func _check_sunlight() -> bool:
	if _main_node == null:
		return false
	
	# Check if it's daytime (sun is up)
	var current_time: float = _main_node.get("day_time") if "day_time" in _main_node else 12.0
	var sunrise: float = _main_node.get("sunrise_hour") if "sunrise_hour" in _main_node else 6.0
	var sunset: float = _main_node.get("sunset_hour") if "sunset_hour" in _main_node else 18.0
	
	var is_daytime = current_time >= sunrise and current_time <= sunset
	
	if not is_daytime:
		return false

	# Under cover counts as out of the sun. This closes a long-standing TODO,
	# and the same test is what tells the air-quality model whether the player
	# is sheltered from smoke — one implementation, two consumers.
	return not _is_under_cover()


## True when something solid is directly overhead. Cached at ~2 Hz because it is
## a physics query and both callers run every frame.
func _is_under_cover() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _cover_checked_at < COVER_CHECK_INTERVAL:
		return _cover_cached
	_cover_checked_at = now
	_cover_cached = false
	if _player == null or not _player.is_inside_tree():
		return _cover_cached
	var space := _player.get_world_3d().direct_space_state
	if space == null:
		return _cover_cached
	var from: Vector3 = _player.global_position + Vector3(0.0, 0.5, 0.0)
	var params := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, COVER_RAY_M, 0.0))
	params.exclude = [_player.get_rid()] if _player is CollisionObject3D else []
	var hit := space.intersect_ray(params)
	_cover_cached = not hit.is_empty()
	return _cover_cached

# ===== HYDRATION =====

func _update_hydration(delta: float) -> void:
	var hydration_change: float = 0.0
	
	# Base drain (always happening - even at rest you lose hydration)
	hydration_change -= hydration_drain_rate * delta
	
	# Check if player is riding a vehicle (not strenuous, no extra drain)
	var is_riding: bool = false
	if _player != null and "is_riding" in _player:
		is_riding = _player.is_riding
	
	# Activity DRAINS hydration (you sweat when active!) - but NOT when riding
	if not is_riding:
		if _is_running:
			hydration_change -= hydration_run_drain * delta
		elif _is_walking:
			hydration_change -= hydration_walk_drain * delta
	
	# Sunlight DRAINS hydration (you sweat more in the sun!)
	if _is_in_sunlight:
		hydration_change -= hydration_sun_drain * delta
	
	current_hydration += hydration_change

func _check_dehydration_damage(delta: float) -> void:
	var hydration_percent = (current_hydration / max_hydration) * 100.0
	
	if hydration_percent <= dehydration_damage_threshold:
		# Scale damage based on how dehydrated (worse = more damage)
		var severity = 1.0 - (hydration_percent / dehydration_damage_threshold)
		var damage = dehydration_damage_rate * severity * delta
		take_damage(damage, "dehydration")

# ===== HEALTH REGEN =====

func _update_health_regen(delta: float) -> void:
	_time_since_damage += delta
	
	# Only regen if not at max and enough time has passed
	if current_health < max_health and _time_since_damage >= health_regen_delay:
		# Don't regen while dehydrated
		var hydration_percent = (current_hydration / max_hydration) * 100.0
		if hydration_percent > dehydration_damage_threshold:
			current_health += health_regen_rate * delta

# ===== FIRE DAMAGE =====

func _check_fire_damage(delta: float) -> void:
	_fire_check_timer += delta
	if _fire_check_timer < fire_check_interval:
		return
	_fire_check_timer = 0.0
	
	if _player == null:
		return
	
	var player_pos = _player.global_position
	var closest_fire_distance: float = INF
	
	# Find all active fires (fire_nodes group from fire_node.gd)
	var fires = get_tree().get_nodes_in_group("fire_nodes")
	
	for fire in fires:
		if fire is Node3D:
			var fire_pos = fire.global_position
			var distance = player_pos.distance_to(fire_pos)
			if distance < closest_fire_distance:
				closest_fire_distance = distance
	
	# Check if within damage range
	_is_near_fire = closest_fire_distance <= fire_damage_distance
	
	if _is_near_fire:
		# Scale damage by proximity (closer = more damage)
		var proximity_factor = 1.0 - (closest_fire_distance / fire_damage_distance)
		proximity_factor = clampf(proximity_factor, 0.0, 1.0)
		_current_fire_damage = fire_damage_rate * proximity_factor
	else:
		_current_fire_damage = 0.0

## ===== AIR QUALITY =====
##
## Breathing hazardous air is a slow, cumulative harm, unlike standing in a fire
## — so the rate is small and it is meant to be survivable for a while. Shelter
## helps but does not save you: an unfiltered building during a Hazardous smoke
## event still fills with smoke, which is the point of the hazard.
func _air_quality_damage_rate() -> float:
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw == null:
		return 0.0
	var hz: Dictionary = xw.call("current")
	var breath := float(hz.get("breath_hazard", 0.0))
	if not is_finite(breath) or breath <= 0.05:
		return 0.0
	var shelter := AIR_SHELTER_RELIEF if _is_under_cover() else 1.0
	return air_damage_rate * breath * shelter


func _physics_process(delta: float) -> void:
	var gr := GameplayRulesImpl.from_node(self)
	if gr == null or not gr.is_survival_active():
		return
	if gr.is_fire_damage_enabled() and _is_near_fire and _current_fire_damage > 0:
		take_damage(_current_fire_damage * delta, "fire")
	# Gated separately from fire so a player can run extreme weather visually
	# with survival on but hazard damage off.
	if gr.is_air_hazard_enabled():
		var air := _air_quality_damage_rate()
		if air > 0.0:
			take_damage(air * delta, "smoke")

# ===== DAMAGE & HEALING =====

func take_damage(amount: float, source: String = "unknown") -> void:
	if amount <= 0:
		return
	
	_last_damage_source = source
	current_health -= amount
	_time_since_damage = 0.0
	damage_taken.emit(amount, source)

func heal(amount: float) -> void:
	if amount <= 0:
		return
	current_health += amount

func restore_hydration(amount: float) -> void:
	if amount <= 0:
		return
	current_hydration += amount

func _on_player_death() -> void:
	var cause = "unknown causes"
	
	# Determine cause based on last damage source
	match _last_damage_source:
		"fire":
			cause = "You have been burned alive. Fuck."
		"dehydration":
			cause = "You have died of severe dehydration. Fuck This."
		"fall":
			cause = "You have died of an OSHA violation. Fuck."
		_:
			var hydration_percent = (current_hydration / max_hydration) * 100.0
			if hydration_percent <= dehydration_damage_threshold:
				cause = "You have died of severe dehydration. Fuck This."
			elif _is_near_fire:
				cause = "You have been burned alive. Fuck."
			else:
				cause = "You have died. Fuck This."
	
	player_died.emit(cause)
	
	# Also emit to player's signal for game_over_ui compatibility
	if _player != null and _player.has_signal("player_died"):
		_player.player_died.emit(cause)

# ===== GETTERS =====

func get_health_percent() -> float:
	return (current_health / max_health) * 100.0

func get_hydration_percent() -> float:
	return (current_hydration / max_hydration) * 100.0

func is_dehydrated() -> bool:
	return get_hydration_percent() <= dehydration_damage_threshold

func is_near_fire() -> bool:
	return _is_near_fire

func is_taking_damage() -> bool:
	return _time_since_damage < 0.5 or _is_near_fire or is_dehydrated()

## Get health status text
func get_health_status() -> String:
	var percent = get_health_percent()
	if percent >= 90:
		return "Fuck Yes!"
	elif percent >= 70:
		return "Feeling Good"
	elif percent >= 50:
		return "Meh"
	elif percent >= 30:
		return "Not Great"
	elif percent >= 10:
		return "Fuck..."
	else:
		return "Fuck This"


## Get hydration status text
func get_hydration_status() -> String:
	var percent = get_hydration_percent()
	if percent >= 80:
		return "Hydrated"
	elif percent >= 50:
		return "Okay"
	elif percent >= 30:
		return "Thirsty"
	elif percent >= 10:
		return "Parched"
	else:
		return "Dying"

