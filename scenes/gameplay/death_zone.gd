@tool
extends Area3D

## Death zone that triggers game over when the player enters
## Attach this script to an Area3D with a CollisionShape3D child

signal player_died(death_message: String)

## Show a visible debug box in the editor and game
@export var show_debug_visual : bool = true :
	set(value):
		show_debug_visual = value
		_update_debug_visual()

## Color of the debug visualization box
@export var debug_color : Color = Color(0.9, 0.1, 0.1, 0.4) :
	set(value):
		debug_color = value
		_update_debug_visual()

## Size of the death zone (updates collision shape too)
@export var zone_size : Vector3 = Vector3(1.2, 2.5, 1.2) :
	set(value):
		zone_size = value
		_update_collision_shape()
		_update_debug_visual()

## Message shown on the game over screen when this zone kills the player.
@export_multiline var death_message : String = "You have died of dysentery"

var _debug_mesh : MeshInstance3D = null

func _ready() -> void:
	# Add to death_zone group for easy finding
	add_to_group("death_zone")
	
	# Connect to body entered signal
	body_entered.connect(_on_body_entered)
	
	# Don't block movement (Area only detects). Player uses layers 1+2 (mask 3).
	collision_layer = 0
	collision_mask = 3
	monitoring = true
	
	# Create debug visualization
	_update_debug_visual()
	_update_collision_shape()

func _update_debug_visual() -> void:
	# Remove existing debug mesh if any
	if _debug_mesh:
		_debug_mesh.queue_free()
		_debug_mesh = null
	
	if not show_debug_visual:
		return
	
	# Create debug mesh
	_debug_mesh = MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = zone_size
	_debug_mesh.mesh = box_mesh
	
	# Create semi-transparent material
	var material := StandardMaterial3D.new()
	material.albedo_color = debug_color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_debug_mesh.material_override = material
	
	# Position at center of zone (half height up from base)
	_debug_mesh.position.y = zone_size.y / 2.0
	
	add_child(_debug_mesh)
	
	# Don't save the debug mesh to the scene
	_debug_mesh.set_meta("_edit_lock_", true)

func _update_collision_shape() -> void:
	# Find and update the collision shape
	for child in get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			child.shape.size = zone_size
			child.position.y = zone_size.y / 2.0
			break

func _on_body_entered(body: Node3D) -> void:
	# Don't trigger in editor
	if Engine.is_editor_hint():
		return
	var gr := GameplayRulesImpl.from_node(self)
	if gr == null or not gr.is_death_zones_enabled() or not gr.is_survival_active():
		return
	# Check if it's the player
	if body.is_in_group("player") or body.name == "Player":
		var msg := death_message
		if msg == null:
			msg = ""
		if msg.strip_edges() == "" and String(name).to_lower().contains("river"):
			msg = "You have died attempting to ford the river."
		print("[DeathZone] Triggered: zone=%s player_pos=%s zone_pos=%s zone_size=%s message=%s" % [
			String(name), str(body.global_position), str(global_position), str(zone_size), msg
		])
		player_died.emit(msg)
