extends CanvasLayer

## Game Over screen with GoldenEye-style blood dripping effect

signal respawn_requested

@onready var blood_container : Control = $BloodContainer
@onready var respawn_timer : Timer = $RespawnTimer
@onready var background : ColorRect = $Background
@onready var subtitle_label : Label = $CenterContainer/VBoxContainer/SubtitleLabel

const DEFAULT_DEATH_MESSAGE : String = "You have died of dysentery"

# Blood drip parameters
const NUM_BLOOD_DRIPS : int = 50
const DRIP_MIN_WIDTH : float = 8.0
const DRIP_MAX_WIDTH : float = 45.0
const DRIP_SPEED_MIN : float = 60.0
const DRIP_SPEED_MAX : float = 180.0
const DRIP_DELAY_MIN : float = 0.0
const DRIP_DELAY_MAX : float = 2.0

# Background fade parameters
const BG_FADE_DURATION : float = 2.0
const BG_START_ALPHA : float = 0.3
const BG_END_ALPHA : float = 1.0

var blood_drips : Array[Dictionary] = []
var is_active : bool = false
var fade_elapsed : float = 0.0

func _ready() -> void:
	respawn_timer.wait_time = 5.0
	respawn_timer.timeout.connect(_on_respawn)
	_create_blood_drips()

func _create_blood_drips() -> void:
	# Clear existing drips
	for child in blood_container.get_children():
		child.queue_free()
	blood_drips.clear()
	
	# Create blood drip custom drawing controls
	var viewport_size := get_viewport().get_visible_rect().size
	
	for i in range(NUM_BLOOD_DRIPS):
		var drip := BloodDrip.new()
		var drip_width := randf_range(DRIP_MIN_WIDTH, DRIP_MAX_WIDTH)
		
		# Randomize starting position across screen width
		drip.position.x = randf() * viewport_size.x
		drip.position.y = 0.0
		drip.drip_width = drip_width
		drip.custom_minimum_size = Vector2(drip_width * 2, viewport_size.y * 1.5)
		drip.size = drip.custom_minimum_size
		
		# Blood color with slight variation
		var red_variation := randf_range(0.55, 0.85)
		var green_variation := randf_range(0.0, 0.08)
		drip.blood_color = Color(red_variation, green_variation, 0.02, 0.92)
		
		blood_container.add_child(drip)
		
		# Store drip data
		blood_drips.append({
			"node": drip,
			"speed": randf_range(DRIP_SPEED_MIN, DRIP_SPEED_MAX),
			"delay": randf_range(DRIP_DELAY_MIN, DRIP_DELAY_MAX),
			"max_length": randf_range(viewport_size.y * 0.5, viewport_size.y * 1.3),
			"elapsed": 0.0,
			"current_length": 0.0,
			"growing": true
		})

func _process(delta: float) -> void:
	if not is_active:
		return
	
	# Update background fade
	if fade_elapsed < BG_FADE_DURATION:
		fade_elapsed += delta
		var fade_progress := clampf(fade_elapsed / BG_FADE_DURATION, 0.0, 1.0)
		# Smooth ease-in fade
		fade_progress = fade_progress * fade_progress
		var current_alpha := lerpf(BG_START_ALPHA, BG_END_ALPHA, fade_progress)
		background.color.a = current_alpha
	
	# Update blood drips
	for drip_data in blood_drips:
		drip_data["elapsed"] += delta
		
		# Wait for delay before starting
		if drip_data["elapsed"] < drip_data["delay"]:
			continue
		
		var drip_node : BloodDrip = drip_data["node"]
		var speed : float = drip_data["speed"]
		var max_length : float = drip_data["max_length"]
		
		if drip_data["growing"]:
			# Grow the drip downward
			drip_data["current_length"] += speed * delta
			drip_node.drip_length = drip_data["current_length"]
			drip_node.queue_redraw()
			
			# Stop growing once max length reached
			if drip_data["current_length"] >= max_length:
				drip_data["growing"] = false

func show_game_over(death_message: String = "") -> void:
	is_active = true
	visible = true
	
	# Set death message
	if subtitle_label:
		subtitle_label.text = death_message if death_message != "" else DEFAULT_DEATH_MESSAGE
	
	# Reset background fade
	fade_elapsed = 0.0
	background.color.a = BG_START_ALPHA
	
	# Reset blood drips
	for drip_data in blood_drips:
		drip_data["current_length"] = 0.0
		drip_data["elapsed"] = 0.0
		drip_data["growing"] = true
		drip_data["node"].drip_length = 0.0
		drip_data["node"].queue_redraw()
		# Re-randomize delay for fresh effect
		drip_data["delay"] = randf_range(DRIP_DELAY_MIN, DRIP_DELAY_MAX)
	
	# Start respawn timer
	respawn_timer.start()
	
	# Release mouse so player can click
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func hide_game_over() -> void:
	is_active = false
	visible = false
	respawn_timer.stop()

func _input(event: InputEvent) -> void:
	if not is_active:
		return
	
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_on_respawn()
	elif event is InputEventJoypadButton and event.pressed:
		_on_respawn()

func _on_respawn() -> void:
	if not is_active:
		return
	hide_game_over()
	respawn_requested.emit()


# Custom Control class for drawing organic blood drips
class BloodDrip extends Control:
	var drip_width : float = 20.0
	var drip_length : float = 0.0
	var blood_color : Color = Color(0.7, 0.0, 0.02, 0.9)
	var wobble_seed : float = randf() * 100.0
	var num_sub_drips : int = randi_range(2, 5)
	var sub_drip_offsets : Array[float] = []
	var sub_drip_speeds : Array[float] = []
	var sub_drip_widths : Array[float] = []
	
	func _ready() -> void:
		# Generate sub-drip properties for organic look
		for i in range(num_sub_drips):
			sub_drip_offsets.append(randf_range(-drip_width * 0.3, drip_width * 0.3))
			sub_drip_speeds.append(randf_range(0.7, 1.3))
			sub_drip_widths.append(randf_range(0.2, 0.6))
	
	func _draw() -> void:
		if drip_length <= 0:
			return
		
		# Main drip body - tapered shape
		var main_points : PackedVector2Array = []
		var segments := 20
		
		for i in range(segments + 1):
			var t := float(i) / float(segments)
			var y := t * drip_length
			
			# Width tapers as it goes down, with some wobble
			var wobble := sin(y * 0.05 + wobble_seed) * 2.0
			var taper := 1.0 - pow(t, 0.7) * 0.6  # Gradual taper
			var current_width := drip_width * taper
			
			# Left edge
			main_points.append(Vector2(-current_width / 2 + wobble, y))
		
		# Bottom bulge (droplet effect)
		var bulge_y := drip_length
		var bulge_width := drip_width * 0.5
		main_points.append(Vector2(-bulge_width * 0.3, bulge_y + bulge_width * 0.5))
		main_points.append(Vector2(0, bulge_y + bulge_width * 0.8))
		main_points.append(Vector2(bulge_width * 0.3, bulge_y + bulge_width * 0.5))
		
		# Right edge (going back up)
		for i in range(segments, -1, -1):
			var t := float(i) / float(segments)
			var y := t * drip_length
			var wobble := sin(y * 0.05 + wobble_seed) * 2.0
			var taper := 1.0 - pow(t, 0.7) * 0.6
			var current_width := drip_width * taper
			main_points.append(Vector2(current_width / 2 + wobble, y))
		
		# Draw main drip
		if main_points.size() >= 3:
			draw_colored_polygon(main_points, blood_color)
		
		# Draw sub-drips (smaller trailing drips)
		for i in range(num_sub_drips):
			if i >= sub_drip_offsets.size():
				break
			var sub_length := drip_length * sub_drip_speeds[i] * 0.8
			if sub_length < 10:
				continue
			
			var sub_width := drip_width * sub_drip_widths[i]
			var sub_x := sub_drip_offsets[i]
			var sub_start_y := drip_length * 0.1 * (i + 1)
			
			var sub_points : PackedVector2Array = []
			var sub_segments := 10
			
			for j in range(sub_segments + 1):
				var t := float(j) / float(sub_segments)
				var y := sub_start_y + t * (sub_length - sub_start_y)
				var sub_wobble := sin(y * 0.08 + wobble_seed + i) * 1.5
				var sub_taper := 1.0 - pow(t, 0.5) * 0.7
				var sw := sub_width * sub_taper
				sub_points.append(Vector2(sub_x - sw / 2 + sub_wobble, y))
			
			# Sub-drip bottom bulge
			var sub_bulge_y := sub_start_y + (sub_length - sub_start_y)
			sub_points.append(Vector2(sub_x, sub_bulge_y + sub_width * 0.4))
			
			for j in range(sub_segments, -1, -1):
				var t := float(j) / float(sub_segments)
				var y := sub_start_y + t * (sub_length - sub_start_y)
				var sub_wobble := sin(y * 0.08 + wobble_seed + i) * 1.5
				var sub_taper := 1.0 - pow(t, 0.5) * 0.7
				var sw := sub_width * sub_taper
				sub_points.append(Vector2(sub_x + sw / 2 + sub_wobble, y))
			
			if sub_points.size() >= 3:
				var sub_color := blood_color
				sub_color.a *= 0.85
				draw_colored_polygon(sub_points, sub_color)
