extends CanvasLayer
class_name StarCalibrationUI

## In-game UI for calibrating star field alignment
## Shows when reference stars are enabled (HOME key)
## Settings are automatically saved to user://star_calibration.cfg

signal calibration_changed(north_offset: float, declination_offset: float, brightness: float)

const CONFIG_PATH := "user://star_calibration.cfg"

var _star_system : StarSystem = null
var is_visible: bool = false

@onready var panel: PanelContainer = $Panel
@onready var north_slider: HSlider = $Panel/VBox/NorthContainer/NorthSlider
@onready var north_value: Label = $Panel/VBox/NorthContainer/NorthValue
@onready var dec_slider: HSlider = $Panel/VBox/DecContainer/DecSlider
@onready var dec_value: Label = $Panel/VBox/DecContainer/DecValue
@onready var brightness_slider: HSlider = $Panel/VBox/BrightnessContainer/BrightnessSlider
@onready var brightness_value: Label = $Panel/VBox/BrightnessContainer/BrightnessValue
@onready var polaris_info: Label = $Panel/VBox/PolarisInfo
@onready var flip_vertical: CheckBox = $Panel/VBox/FlipContainer/FlipVertical
@onready var flip_horizontal: CheckBox = $Panel/VBox/FlipContainer/FlipHorizontal

func _ready() -> void:
	_find_star_system()
	
	north_slider.value_changed.connect(_on_north_changed)
	dec_slider.value_changed.connect(_on_dec_changed)
	brightness_slider.value_changed.connect(_on_brightness_changed)
	
	load_calibration()
	
	panel.visible = false
	_update_labels()

func _find_star_system() -> void:
	# StarSystem is our parent when instantiated by star_system.gd
	var parent = get_parent()
	if parent is StarSystem:
		_star_system = parent
		return
	# Fallback: search scene tree
	var tree := get_tree()
	if tree:
		for node in tree.root.get_children():
			var ss = node.get_node_or_null("StarSystem")
			if ss is StarSystem:
				_star_system = ss
				return

func _process(delta: float) -> void:
	if is_visible and _star_system != null:
		_update_polaris_info()
	
	if _needs_save:
		_save_timer -= delta
		if _save_timer <= 0.0:
			save_calibration()
			_needs_save = false

func show_ui() -> void:
	is_visible = true
	panel.visible = true
	if _star_system != null:
		north_slider.set_value_no_signal(_star_system.stars_north_offset)
		dec_slider.set_value_no_signal(_star_system.stars_declination_offset)
		brightness_slider.set_value_no_signal(_star_system.stars_brightness)
		flip_vertical.set_pressed_no_signal(_star_system.stars_flip_vertical)
		flip_horizontal.set_pressed_no_signal(_star_system.stars_flip_horizontal)
	_update_labels()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func hide_ui() -> void:
	is_visible = false
	panel.visible = false
	# Re-capture mouse for game
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func toggle_ui() -> void:
	if is_visible:
		hide_ui()
	else:
		show_ui()

func _on_north_changed(value: float) -> void:
	if _star_system != null:
		_star_system.stars_north_offset = value
	_update_labels()
	_auto_save()

func _on_dec_changed(value: float) -> void:
	if _star_system != null:
		_star_system.stars_declination_offset = value
	_update_labels()
	_auto_save()

func _on_brightness_changed(value: float) -> void:
	if _star_system != null:
		_star_system.stars_brightness = value
	_update_labels()
	_auto_save()

func _on_flip_vertical_toggled(toggled_on: bool) -> void:
	if _star_system != null:
		_star_system.stars_flip_vertical = toggled_on
	_auto_save()

func _on_flip_horizontal_toggled(toggled_on: bool) -> void:
	if _star_system != null:
		_star_system.stars_flip_horizontal = toggled_on
	_auto_save()

# Timer for debounced auto-save
var _save_timer: float = 0.0
var _needs_save: bool = false

func _auto_save() -> void:
	_needs_save = true
	_save_timer = 1.0  # Save after 1 second of no changes

func _update_labels() -> void:
	north_value.text = "%.1f°" % north_slider.value
	dec_value.text = "%.1f°" % dec_slider.value
	brightness_value.text = "%.2f" % brightness_slider.value

func _update_polaris_info() -> void:
	if _star_system == null:
		return
	var polaris : Dictionary = _star_system.get_reference_star_position("polaris")
	if not polaris.is_empty():
		var status : String = "VISIBLE" if polaris.visible else "Below Horizon"
		var lst_hours : float = _star_system.current_lst / 15.0
		var lst_h : int = int(lst_hours)
		var lst_m : int = int((lst_hours - lst_h) * 60.0)
		polaris_info.text = "Polaris: Alt %.1f (%s) | LST: %02d:%02d\nFlip V=%s H=%s" % [
			polaris.altitude, status, lst_h, lst_m,
			"ON" if flip_vertical.button_pressed else "off",
			"ON" if flip_horizontal.button_pressed else "off"
		]

func _on_reset_pressed() -> void:
	north_slider.value = 0.0
	dec_slider.value = 0.0
	flip_vertical.button_pressed = false
	flip_horizontal.button_pressed = false
	if _star_system != null:
		_star_system.stars_flip_vertical = false
		_star_system.stars_flip_horizontal = false

func _on_north_minus() -> void:
	north_slider.value -= 1.0

func _on_north_plus() -> void:
	north_slider.value += 1.0

func _on_north_minus_big() -> void:
	north_slider.value -= 10.0

func _on_north_plus_big() -> void:
	north_slider.value += 10.0

func _on_dec_minus() -> void:
	dec_slider.value -= 1.0

func _on_dec_plus() -> void:
	dec_slider.value += 1.0

func _on_dec_minus_big() -> void:
	dec_slider.value -= 10.0

func _on_dec_plus_big() -> void:
	dec_slider.value += 10.0

func _on_quick_align_pressed() -> void:
	# If the starmap has SCP centered instead of equator, shifting Dec by +90° might help
	dec_slider.value = 90.0

## Save calibration settings to config file
func save_calibration() -> void:
	var config := ConfigFile.new()
	config.set_value("stars", "north_offset", north_slider.value)
	config.set_value("stars", "declination_offset", dec_slider.value)
	config.set_value("stars", "brightness", brightness_slider.value)
	config.set_value("stars", "flip_vertical", flip_vertical.button_pressed)
	config.set_value("stars", "flip_horizontal", flip_horizontal.button_pressed)
	var err := config.save(CONFIG_PATH)
	if err == OK:
		pass
	else:
		pass

## Load calibration settings from config file
func load_calibration() -> void:
	var config := ConfigFile.new()
	var err := config.load(CONFIG_PATH)
	if err == OK:
		var north : float = float(config.get_value("stars", "north_offset", 0.0))
		var dec : float = float(config.get_value("stars", "declination_offset", 0.0))
		var bright : float = float(config.get_value("stars", "brightness", 0.1))
		var flip_v : bool = bool(config.get_value("stars", "flip_vertical", false))
		var flip_h : bool = bool(config.get_value("stars", "flip_horizontal", false))
		
		north_slider.value = north
		dec_slider.value = dec
		brightness_slider.value = bright
		flip_vertical.button_pressed = flip_v
		flip_horizontal.button_pressed = flip_h
		
		if _star_system != null:
			_star_system.stars_flip_vertical = flip_v
			_star_system.stars_flip_horizontal = flip_h
	else:
		pass
