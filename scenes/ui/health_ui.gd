extends CanvasLayer

## Health UI with bars and damage feedback (red fog effect)
## 
## Shows:
## - Health bar: "Fuck This" (0%) to "Fuck Yes!" (100%)
## - Hydration bar with activity indicators
## - Red fog vignette when taking damage

@export_group("UI Settings")
## Show status text labels
@export var show_status_text: bool = true

## Bar width in pixels
@export var bar_width: float = 250.0

## Bar height in pixels  
@export var bar_height: float = 16.0

## Padding from screen edge
@export var padding: float = 20.0

## UI position preset
enum UIPosition { TOP_LEFT, TOP_CENTER, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_CENTER, BOTTOM_RIGHT }
@export var ui_position: UIPosition = UIPosition.BOTTOM_CENTER

@export_group("Colors")
## Health bar gradient colors
@export var health_color_high: Color = UITheme.C_OK
@export var health_color_mid: Color = UITheme.C_WARN
@export var health_color_low: Color = UITheme.C_ERROR

## Hydration bar color
@export var hydration_color: Color = Color(0.3, 0.6, 0.95, 1.0)  # Blue

## Background color for bars
@export var bar_bg_color: Color = Color(0.15, 0.15, 0.15, 0.8)

@export_group("Damage Feedback")
## Maximum opacity of red fog when taking heavy damage
@export var max_fog_opacity: float = 0.5

## How fast the fog fades in
@export var fog_fade_in_speed: float = 8.0

## How fast the fog fades out
@export var fog_fade_out_speed: float = 2.0

## Pulse speed when at critical health
@export var critical_pulse_speed: float = 3.0

# UI Nodes
var _health_bar_bg: ColorRect
var _health_bar_fill: ColorRect
var _health_label: Label
var _health_status_left: Label   # "FUCK THIS" on left side (fixed)
var _health_status_right: Label  # "FUCK YES!" on right side (fixed)
var _health_status_center: Label # Current state in center of bar (dynamic)

var _hydration_bar_bg: ColorRect
var _hydration_bar_fill: ColorRect
var _hydration_label: Label
var _hydration_status_left: Label   # "DEHYDRATED" on left side (fixed)
var _hydration_status_right: Label  # "HYDRATED" on right side (fixed)
var _hydration_status_center: Label # Current state in center of bar (dynamic)
var _hydration_indicator: Label     # Shows activity icons

var _damage_fog: ColorRect  # Full-screen red vignette

var _health_container: Control = null

var _health_system: Node = null
var _current_fog_opacity: float = 0.0
var _target_fog_opacity: float = 0.0
var _pulse_time: float = 0.0
var _activity_update_timer: float = 0.0
const _ACTIVITY_UPDATE_INTERVAL: float = 0.1
## GameplayRules visibility flag changes rarely; avoid autoload/tree walks every frame.
const _RULES_VIS_POLL_SEC: float = 0.2
var _rules_vis_poll_left: float = 0.0
var _cached_show_survival_ui: bool = true

func _ready() -> void:
	layer = UITheme.LAYER_HUD
	_create_ui()
	call_deferred("_find_health_system")

func _find_health_system() -> void:
	# Look for PlayerHealth node (usually child of Player)
	var tree = get_tree()
	if tree == null:
		return
	
	# Find player first
	var players = tree.get_nodes_in_group("player")
	if players.size() > 0:
		var player = players[0]
		_health_system = player.get_node_or_null("PlayerHealth")
		
		if _health_system:
			# Connect signals
			if _health_system.has_signal("health_changed"):
				_health_system.health_changed.connect(_on_health_changed)
			if _health_system.has_signal("hydration_changed"):
				_health_system.hydration_changed.connect(_on_hydration_changed)
			if _health_system.has_signal("damage_taken"):
				_health_system.damage_taken.connect(_on_damage_taken)
			
			# Initial update
			_on_health_changed(_health_system.current_health, _health_system.max_health)
			_on_hydration_changed(_health_system.current_hydration, _health_system.max_hydration)
		else:
			push_warning("HealthUI: PlayerHealth node not found on player")

func _create_ui() -> void:
	var panel_padding: float = 16.0
	var title_height: float = 24.0
	var bar_spacing: float = 10.0
	var side_label_width: float = 105.0  # Width for left/right labels (bigger text needs more space)
	
	# Calculate total content size (with side labels)
	var content_height: float = title_height + bar_height + bar_spacing + title_height + bar_height
	var content_width: float = side_label_width + bar_width + side_label_width + 20
	var total_height: float = content_height + panel_padding * 2
	var total_width: float = content_width + panel_padding * 2
	
	# Create main container
	var container = Control.new()
	container.name = "HealthContainer"
	container.custom_minimum_size = Vector2(total_width, total_height)
	container.size = Vector2(total_width, total_height)
	add_child(container)
	
	# Position based on selected preset
	_position_container(container, total_width, total_height)
	_health_container = container
	
	# === BACKGROUND PANEL WITH ROUNDED CORNERS ===
	var panel_bg = Panel.new()
	panel_bg.name = "PanelBackground"
	panel_bg.size = Vector2(total_width, total_height)
	panel_bg.position = Vector2.ZERO
	
	# Create StyleBoxFlat for rounded corners
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.1, 0.85)  # Dark blue-tinted
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.3, 0.5, 0.7, 0.6)  # Blue-ish border
	panel_bg.add_theme_stylebox_override("panel", style)
	container.add_child(panel_bg)
	
	var y_offset: float = panel_padding
	var bar_x: float = panel_padding + side_label_width + 10
	
	# === HEALTH SECTION ===
	_health_label = Label.new()
	_health_label.text = "HEALTH"
	_health_label.position = Vector2(bar_x, y_offset)
	_health_label.add_theme_font_size_override("font_size", 16)
	_health_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))  # White text
	container.add_child(_health_label)
	y_offset += title_height
	
	# Left label: "FUCK THIS" - Red
	_health_status_left = Label.new()
	_health_status_left.text = "FUCK THIS"
	_health_status_left.position = Vector2(panel_padding, y_offset)
	_health_status_left.add_theme_font_size_override("font_size", 15)
	_health_status_left.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))  # Bright red
	_health_status_left.visible = show_status_text
	container.add_child(_health_status_left)
	
	# Health bar background
	_health_bar_bg = ColorRect.new()
	_health_bar_bg.color = bar_bg_color
	_health_bar_bg.size = Vector2(bar_width, bar_height)
	_health_bar_bg.position = Vector2(bar_x, y_offset)
	container.add_child(_health_bar_bg)
	
	# Health bar fill
	_health_bar_fill = ColorRect.new()
	_health_bar_fill.color = health_color_high
	_health_bar_fill.size = Vector2(bar_width, bar_height)
	_health_bar_fill.position = Vector2(bar_x, y_offset)
	container.add_child(_health_bar_fill)
	
	# Center label: current state (overlaid on bar)
	_health_status_center = Label.new()
	_health_status_center.text = "FUCK YES!"
	_health_status_center.position = Vector2(bar_x + bar_width / 2 - 40, y_offset - 1)
	_health_status_center.add_theme_font_size_override("font_size", 14)
	_health_status_center.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))  # White
	_health_status_center.visible = show_status_text
	container.add_child(_health_status_center)
	
	# Right label: "FUCK YES!" - Green
	_health_status_right = Label.new()
	_health_status_right.text = "FUCK YES!"
	_health_status_right.position = Vector2(bar_x + bar_width + 10, y_offset)
	_health_status_right.add_theme_font_size_override("font_size", 15)
	_health_status_right.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3, 1.0))  # Bright green
	_health_status_right.visible = show_status_text
	container.add_child(_health_status_right)
	
	y_offset += bar_height + bar_spacing
	
	# === HYDRATION SECTION ===
	_hydration_label = Label.new()
	_hydration_label.text = "HYDRATION"
	_hydration_label.position = Vector2(bar_x, y_offset)
	_hydration_label.add_theme_font_size_override("font_size", 16)
	_hydration_label.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0, 1.0))  # Light blue
	container.add_child(_hydration_label)
	
	_hydration_indicator = Label.new()
	_hydration_indicator.text = ""
	_hydration_indicator.position = Vector2(bar_x + 110, y_offset)
	_hydration_indicator.add_theme_font_size_override("font_size", 16)
	_hydration_indicator.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4, 1.0))  # Bright gold
	container.add_child(_hydration_indicator)
	
	y_offset += title_height
	
	# Left label: "DEHYDRATED" - Orange
	_hydration_status_left = Label.new()
	_hydration_status_left.text = "DEHYDRATED"
	_hydration_status_left.position = Vector2(panel_padding - 8, y_offset)
	_hydration_status_left.add_theme_font_size_override("font_size", 14)
	_hydration_status_left.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2, 1.0))  # Bright orange
	_hydration_status_left.visible = show_status_text
	container.add_child(_hydration_status_left)
	
	# Hydration bar background
	_hydration_bar_bg = ColorRect.new()
	_hydration_bar_bg.color = bar_bg_color
	_hydration_bar_bg.size = Vector2(bar_width, bar_height)
	_hydration_bar_bg.position = Vector2(bar_x, y_offset)
	container.add_child(_hydration_bar_bg)
	
	# Hydration bar fill
	_hydration_bar_fill = ColorRect.new()
	_hydration_bar_fill.color = hydration_color
	_hydration_bar_fill.size = Vector2(bar_width, bar_height)
	_hydration_bar_fill.position = Vector2(bar_x, y_offset)
	container.add_child(_hydration_bar_fill)
	
	# Center label: current state (overlaid on bar)
	_hydration_status_center = Label.new()
	_hydration_status_center.text = "HYDRATED"
	_hydration_status_center.position = Vector2(bar_x + bar_width / 2 - 40, y_offset - 1)
	_hydration_status_center.add_theme_font_size_override("font_size", 14)
	_hydration_status_center.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))  # White
	_hydration_status_center.visible = show_status_text
	container.add_child(_hydration_status_center)
	
	# Right label: "HYDRATED" - Blue
	_hydration_status_right = Label.new()
	_hydration_status_right.text = "HYDRATED"
	_hydration_status_right.position = Vector2(bar_x + bar_width + 10, y_offset)
	_hydration_status_right.add_theme_font_size_override("font_size", 15)
	_hydration_status_right.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0, 1.0))  # Bright blue
	_hydration_status_right.visible = show_status_text
	container.add_child(_hydration_status_right)
	
	# === DAMAGE FOG (full screen red vignette) ===
	_damage_fog = ColorRect.new()
	_damage_fog.name = "DamageFog"
	_damage_fog.color = Color(0.8, 0.0, 0.0, 0.0)
	_damage_fog.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_fog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_damage_fog)
	
	# Create vignette shader for the fog
	_setup_vignette_shader()

func _position_container(container: Control, content_width: float, content_height: float) -> void:
	# Get viewport size
	var viewport_size = get_viewport().get_visible_rect().size
	
	var pos_x: float = 0.0
	var pos_y: float = 0.0
	
	match ui_position:
		UIPosition.TOP_LEFT:
			pos_x = padding
			pos_y = padding
		UIPosition.TOP_CENTER:
			pos_x = (viewport_size.x - content_width) / 2.0
			pos_y = padding
		UIPosition.TOP_RIGHT:
			pos_x = viewport_size.x - content_width - padding
			pos_y = padding
		UIPosition.BOTTOM_LEFT:
			pos_x = padding
			pos_y = viewport_size.y - content_height - padding
		UIPosition.BOTTOM_CENTER:
			pos_x = (viewport_size.x - content_width) / 2.0
			pos_y = viewport_size.y - content_height - padding
		UIPosition.BOTTOM_RIGHT:
			pos_x = viewport_size.x - content_width - padding
			pos_y = viewport_size.y - content_height - padding
	
	container.position = Vector2(pos_x, pos_y)

func _setup_vignette_shader() -> void:
	var shader = Shader.new()
	shader.code = """
shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec4 fog_color : source_color = vec4(0.8, 0.0, 0.0, 1.0);
uniform float vignette_size : hint_range(0.0, 1.0) = 0.4;
uniform float vignette_softness : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec2 uv = UV;
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(uv, center);
	
	// Create vignette effect (darker at edges)
	float vignette = smoothstep(vignette_size, vignette_size + vignette_softness, dist);
	
	// Apply fog color with vignette
	COLOR = vec4(fog_color.rgb, vignette * intensity);
}
"""
	
	var material = ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("intensity", 0.0)
	material.set_shader_parameter("fog_color", Color(0.8, 0.0, 0.0, 1.0))
	material.set_shader_parameter("vignette_size", 0.3)
	material.set_shader_parameter("vignette_softness", 0.5)
	
	_damage_fog.material = material

func _process(delta: float) -> void:
	_rules_vis_poll_left -= delta
	if _rules_vis_poll_left <= 0.0:
		_rules_vis_poll_left = _RULES_VIS_POLL_SEC
		var gr_poll := GameplayRulesImpl.from_node(self)
		if gr_poll != null:
			_cached_show_survival_ui = gr_poll.should_show_survival_ui()
		else:
			_cached_show_survival_ui = true
	var show_hud: bool = _cached_show_survival_ui
	if _health_container != null and _health_container.visible != show_hud:
		_health_container.visible = show_hud
	if _damage_fog != null and _damage_fog.visible != show_hud:
		_damage_fog.visible = show_hud
	if not show_hud:
		return
	_update_fog(delta)
	_activity_update_timer += delta
	if _activity_update_timer >= _ACTIVITY_UPDATE_INTERVAL:
		_activity_update_timer -= _ACTIVITY_UPDATE_INTERVAL
		_update_activity_indicators()
	_update_critical_pulse(delta)

func _update_fog(delta: float) -> void:
	# Determine target fog opacity based on damage state
	if _health_system != null:
		if _health_system.is_taking_damage():
			# More intense fog for fire
			if _health_system.is_near_fire():
				_target_fog_opacity = max_fog_opacity
			elif _health_system.is_dehydrated():
				_target_fog_opacity = max_fog_opacity * 0.5
			else:
				_target_fog_opacity = max_fog_opacity * 0.3
		else:
			_target_fog_opacity = 0.0
		
		# Low health adds persistent fog
		var health_percent = _health_system.get_health_percent()
		if health_percent < 30:
			var low_health_fog = (30.0 - health_percent) / 30.0 * 0.3
			_target_fog_opacity = maxf(_target_fog_opacity, low_health_fog)
	
	# Smoothly interpolate fog opacity
	if _current_fog_opacity < _target_fog_opacity:
		_current_fog_opacity = move_toward(_current_fog_opacity, _target_fog_opacity, fog_fade_in_speed * delta)
	else:
		_current_fog_opacity = move_toward(_current_fog_opacity, _target_fog_opacity, fog_fade_out_speed * delta)
	
	# Apply to shader
	if _damage_fog.material is ShaderMaterial:
		var mat = _damage_fog.material as ShaderMaterial
		mat.set_shader_parameter("intensity", _current_fog_opacity)

func _update_activity_indicators() -> void:
	if _health_system == null:
		return
	
	var indicators: PackedStringArray = []
	
	if _health_system._is_running:
		indicators.append("🏃")
	elif _health_system._is_walking:
		indicators.append("🚶")
	
	if _health_system._is_in_sunlight:
		indicators.append("☀")
	
	if _health_system.is_dehydrated():
		indicators.append("⚠")
	
	if _health_system.is_near_fire():
		indicators.append("🔥")
	
	_hydration_indicator.text = " ".join(indicators)

func _update_critical_pulse(delta: float) -> void:
	if _health_system == null:
		return
	
	var health_percent = _health_system.get_health_percent()
	
	# Pulse effect at critical health
	if health_percent < 20:
		_pulse_time += delta * critical_pulse_speed
		var pulse = (sin(_pulse_time) + 1.0) / 2.0  # 0 to 1
		var pulse_color = health_color_low.lerp(Color(1, 0.3, 0.3), pulse * 0.5)
		_health_bar_fill.color = pulse_color
	else:
		_pulse_time = 0.0

func _on_health_changed(new_health: float, max_health_val: float) -> void:
	var percent = new_health / max_health_val
	
	# Update bar width
	_health_bar_fill.size.x = bar_width * percent
	
	# Update color based on health level
	var color: Color
	if percent > 0.6:
		color = health_color_high.lerp(health_color_mid, (1.0 - percent) / 0.4)
	elif percent > 0.3:
		color = health_color_mid.lerp(health_color_low, (0.6 - percent) / 0.3)
	else:
		color = health_color_low
	
	_health_bar_fill.color = color
	
	# Update CENTER status text (current state displayed on the bar)
	if _health_system != null and _health_status_center != null:
		_health_status_center.text = _health_system.get_health_status().to_upper()

func _on_hydration_changed(new_hydration: float, max_hydration_val: float) -> void:
	var percent = new_hydration / max_hydration_val
	
	# Update bar width
	_hydration_bar_fill.size.x = bar_width * percent
	
	# Change color when below 50% (warning threshold)
	if percent < 0.5:
		_hydration_bar_fill.color = Color(0.9, 0.5, 0.2)  # Orange warning
		_hydration_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.3))
	else:
		_hydration_bar_fill.color = hydration_color
		_hydration_label.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	
	# Update CENTER status text (current state displayed on the bar)
	if _health_system != null and _hydration_status_center != null:
		_hydration_status_center.text = _health_system.get_hydration_status().to_upper()

func _on_damage_taken(amount: float, source: String) -> void:
	# Flash the fog more intensely on damage
	_current_fog_opacity = minf(_current_fog_opacity + 0.2, max_fog_opacity)
	
	# Could add screen shake here too
	pass

## Show/hide the health UI
func set_ui_visible(is_visible: bool) -> void:
	for child in get_children():
		if child is Control:
			child.visible = is_visible

