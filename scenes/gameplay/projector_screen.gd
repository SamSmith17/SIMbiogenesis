extends Node3D
class_name ProjectorScreen

## Projector screen that displays the main viewport with a slight delay
## Creates an infinite feedback loop effect when the player looks at it

## Size of the projector screen in meters
@export var screen_width : float = 3.0
@export var screen_height : float = 2.0

## Delay in frames (creates the feedback lag effect)
@export var frame_delay : int = 3

## How many times per second to capture the viewport (GPU readback is expensive)
@export var captures_per_second : float = 5.0
@export var capture_only_when_nearby : bool = true
@export var capture_max_distance : float = 40.0

## Glow intensity of the screen (affects emission)
@export var glow_intensity : float = 0.5

## The sprite displaying the screen
var screen_sprite : Sprite3D = null

## Frame buffer for delay effect
var frame_buffer : Array[ImageTexture] = []
var current_frame_index : int = 0
var buffer_initialized : bool = false
var _capture_accumulator : float = 0.0

## For glow effect
var glow_light : OmniLight3D = null

func _ready() -> void:
	_create_screen_sprite()
	_create_glow_light()
	
	# Initialize frame buffer
	frame_buffer.resize(maxi(frame_delay + 1, 1))
	for i in range(frame_buffer.size()):
		frame_buffer[i] = null

func _create_screen_sprite() -> void:
	screen_sprite = Sprite3D.new()
	screen_sprite.name = "ScreenSprite"
	
	# Sprite3D settings
	screen_sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	screen_sprite.shaded = false  # Unshaded for projector look
	screen_sprite.double_sided = true  # Visible from both sides
	screen_sprite.no_depth_test = false
	screen_sprite.transparent = false
	screen_sprite.flip_h = true  # Flip to correct mirror effect
	
	# Set a reasonable default pixel_size
	screen_sprite.pixel_size = 0.005
	
	add_child(screen_sprite)

func _create_glow_light() -> void:
	# Add a subtle light to simulate projector glow
	glow_light = OmniLight3D.new()
	glow_light.name = "GlowLight"
	glow_light.light_color = Color(0.9, 0.9, 1.0)
	glow_light.light_energy = glow_intensity * 0.5
	glow_light.omni_range = maxf(screen_width, screen_height) * 2
	glow_light.omni_attenuation = 2.0
	glow_light.position = Vector3(0, 0, 0.5)  # Slightly in front of screen
	add_child(glow_light)

func _update_sprite_scale(tex_size: Vector2) -> void:
	if screen_sprite == null:
		return
	
	if tex_size.x <= 0 or tex_size.y <= 0:
		return
	
	# Calculate pixel_size to achieve desired physical dimensions
	# pixel_size * texture_width = screen_width (in meters)
	screen_sprite.pixel_size = screen_width / tex_size.x

func _process(delta: float) -> void:
	_capture_accumulator += delta
	var capture_interval := 1.0 / maxf(captures_per_second, 0.5)
	if _capture_accumulator >= capture_interval:
		_capture_accumulator -= capture_interval
		if not capture_only_when_nearby or _is_camera_nearby():
			_update_screen_texture()
	
	if glow_light != null:
		glow_light.light_energy = glow_intensity * 0.3

func _is_camera_nearby() -> bool:
	var viewport := get_viewport()
	if viewport == null:
		return true
	var camera := viewport.get_camera_3d()
	if camera == null:
		return true
	return global_position.distance_to(camera.global_position) <= capture_max_distance

func _update_screen_texture() -> void:
	if screen_sprite == null:
		return
	
	var main_viewport := get_viewport()
	if main_viewport == null:
		return
	
	var viewport_texture := main_viewport.get_texture()
	if viewport_texture == null:
		return
	
	var image := viewport_texture.get_image()
	if image == null:
		return
	
	var tex_size := Vector2(image.get_width(), image.get_height())
	
	if frame_delay <= 0:
		var img_texture := ImageTexture.create_from_image(image)
		screen_sprite.texture = img_texture
		_update_sprite_scale(tex_size)
	else:
		var img_texture := ImageTexture.create_from_image(image)
		frame_buffer[current_frame_index] = img_texture
		
		var delayed_index := (current_frame_index + 1) % frame_buffer.size()
		var delayed_texture : ImageTexture = frame_buffer[delayed_index]
		
		if delayed_texture != null:
			screen_sprite.texture = delayed_texture
			buffer_initialized = true
		elif not buffer_initialized:
			screen_sprite.texture = img_texture
		
		_update_sprite_scale(tex_size)
		current_frame_index = (current_frame_index + 1) % frame_buffer.size()

## Update screen size
func update_screen_size() -> void:
	if screen_sprite != null and screen_sprite.texture != null:
		_update_sprite_scale(screen_sprite.texture.get_size())

## Set the glow intensity
func set_glow(intensity: float) -> void:
	glow_intensity = intensity
