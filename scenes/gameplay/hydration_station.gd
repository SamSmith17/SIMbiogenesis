extends Interactable

## Hydration Station - Water bubbler/fountain that refills player hydration.
## 
## Player presses "O" (interact) when nearby to fully hydrate.
## Can be attached to water bubbler/fountain meshes.

signal player_hydrated(player: Node)

@export_group("Interaction")
## How close the player needs to be to interact
@export var interaction_radius: float = 2.0

## Display name shown in interaction prompt
@export var display_name: String = "Water Bubbler"

## How much hydration to restore (percentage of max)
@export_range(0.0, 100.0, 5.0) var hydration_restore_percent: float = 100.0

@export_group("Visuals")
## Size of the placeholder mesh (if no mesh child exists)
@export var placeholder_size: Vector3 = Vector3(0.3, 0.5, 0.3)

## Color of the placeholder mesh
@export var placeholder_color: Color = Color(0.3, 0.5, 0.9, 1.0)

## Show a subtle glow effect
@export var enable_glow: bool = true

# Internal state
var _player_in_range: Node = null
var _interaction_ui: CanvasLayer = null
var _detection_area: Area3D = null
var _placeholder_mesh: MeshInstance3D = null
var _glow_light: OmniLight3D = null

func _ready() -> void:
	super._ready()
	prompt = "Drink from %s" % display_name
	max_distance = interaction_radius + 2.0
	_setup_detection_area()
	_setup_placeholder_visuals()
	call_deferred("_find_interaction_ui")

func _find_interaction_ui() -> void:
	var tree = get_tree()
	if tree == null:
		return
	
	# Look for InteractionPromptUI in UILayer
	var ui_layer = tree.current_scene.get_node_or_null("UILayer")
	if ui_layer != null:
		_interaction_ui = ui_layer.get_node_or_null("InteractionPromptUI")

func _setup_detection_area() -> void:
	_detection_area = Area3D.new()
	_detection_area.name = "DetectionArea"
	_detection_area.collision_layer = 0
	_detection_area.collision_mask = 1  # Detect player
	
	var shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = interaction_radius
	shape.shape = sphere
	_detection_area.add_child(shape)
	
	_detection_area.body_entered.connect(_on_body_entered)
	_detection_area.body_exited.connect(_on_body_exited)
	
	add_child(_detection_area)

func _setup_placeholder_visuals() -> void:
	# Check if there's already a mesh child (user added their own model)
	for child in get_children():
		if child is MeshInstance3D:
			# User has their own mesh, don't create placeholder
			return
	
	# Create placeholder mesh (water bubbler shape)
	_placeholder_mesh = MeshInstance3D.new()
	_placeholder_mesh.name = "PlaceholderMesh"
	
	# Create a simple water bubbler shape (cylinder with sphere on top)
	var cylinder = CylinderMesh.new()
	cylinder.top_radius = placeholder_size.x * 0.4
	cylinder.bottom_radius = placeholder_size.x * 0.5
	cylinder.height = placeholder_size.y
	_placeholder_mesh.mesh = cylinder
	
	# Position so bottom is at origin
	_placeholder_mesh.position = Vector3(0, placeholder_size.y / 2.0, 0)
	
	# Create material
	var mat = StandardMaterial3D.new()
	mat.albedo_color = placeholder_color
	mat.metallic = 0.3
	mat.roughness = 0.4
	mat.emission_enabled = true
	mat.emission = placeholder_color * 0.3
	mat.emission_energy_multiplier = 0.5
	_placeholder_mesh.material_override = mat
	
	add_child(_placeholder_mesh)
	
	# Add a small "spout" on top
	var spout_mesh = MeshInstance3D.new()
	spout_mesh.name = "Spout"
	var spout = CylinderMesh.new()
	spout.top_radius = placeholder_size.x * 0.1
	spout.bottom_radius = placeholder_size.x * 0.15
	spout.height = placeholder_size.y * 0.2
	spout_mesh.mesh = spout
	spout_mesh.position = Vector3(0, placeholder_size.y + placeholder_size.y * 0.1, 0)
	
	var spout_mat = StandardMaterial3D.new()
	spout_mat.albedo_color = Color(0.7, 0.7, 0.8)
	spout_mat.metallic = 0.8
	spout_mat.roughness = 0.2
	spout_mesh.material_override = spout_mat
	
	add_child(spout_mesh)
	
	# Add glow light
	if enable_glow:
		_glow_light = OmniLight3D.new()
		_glow_light.name = "GlowLight"
		_glow_light.light_color = Color(0.4, 0.6, 1.0)
		_glow_light.light_energy = 0.5
		_glow_light.omni_range = 2.0
		_glow_light.omni_attenuation = 1.5
		_glow_light.position = Vector3(0, placeholder_size.y * 0.7, 0)
		add_child(_glow_light)

func interact(player: Node) -> void:
	_player_in_range = player as Node3D
	_hydrate_player()


func get_focus_mesh() -> MeshInstance3D:
	if _placeholder_mesh != null:
		return _placeholder_mesh
	return super.get_focus_mesh()


func _process(_delta: float) -> void:
	# Legacy proximity interact when crosshair focus is not used.
	if _player_in_range != null and Input.is_action_just_pressed("interact"):
		if CursorController.should_capture_look():
			var focus := get_tree().get_first_node_in_group("player")
			if focus != null:
				var ifocus: Node = focus.get_node_or_null("InteractionFocus")
				if ifocus != null and ifocus.has_method("get_focused") and ifocus.get_focused() == self:
					return
		_hydrate_player()

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_in_range = body
		_show_interaction_prompt()

func _on_body_exited(body: Node3D) -> void:
	if body == _player_in_range:
		_player_in_range = null
		_hide_interaction_prompt()

func _show_interaction_prompt() -> void:
	if _interaction_ui != null and _interaction_ui.has_method("show_action_prompt"):
		_interaction_ui.show_action_prompt("interact", "Drink from %s" % display_name)

func _hide_interaction_prompt() -> void:
	if _interaction_ui != null and _interaction_ui.has_method("hide_prompt"):
		_interaction_ui.hide_prompt()

func _hydrate_player() -> void:
	if _player_in_range == null:
		return
	
	# Find PlayerHealth component
	var health_system = _player_in_range.get_node_or_null("PlayerHealth")
	if health_system == null:
		push_warning("HydrationStation: No PlayerHealth found on player")
		return
	
	# Restore hydration
	if health_system.has_method("restore_hydration"):
		var amount = health_system.max_hydration * (hydration_restore_percent / 100.0)
		health_system.restore_hydration(amount)
		player_hydrated.emit(_player_in_range)
		
		# Play a quick visual feedback (pulse the glow)
		_play_hydration_effect()

func _play_hydration_effect() -> void:
	if _glow_light == null:
		return
	
	# Quick pulse effect
	var tween = create_tween()
	tween.tween_property(_glow_light, "light_energy", 2.0, 0.1)
	tween.tween_property(_glow_light, "light_energy", 0.5, 0.4)

## Get interaction prompt text (for compatibility with other systems)
func get_interaction_prompt() -> String:
	return "Drink from %s" % display_name

