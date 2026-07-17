extends CanvasLayer

## UI for showing interaction prompts - auto-detects controller vs keyboard

@onready var panel : PanelContainer = $CenterContainer/PanelContainer
@onready var key_icon : Label = $CenterContainer/PanelContainer/MarginContainer/HBoxContainer/KeyIcon
@onready var prompt_label : Label = $CenterContainer/PanelContainer/MarginContainer/HBoxContainer/PromptLabel

var _tween : Tween
var _using_controller : bool = false
var _transient_hide_timer : Timer = null

const CONTROLLER_LABELS := {
	"interact": "A",
	"dismount": "B",
	"charge": "C",
	"repair": "L1",
	"use_tool": "LT/RT",
	"toggle_camera": "RS",
	"equip_tool": "1",
	"unequip_tool": "0",
	"toggle_light_menu": "D↑",
	"toggle_tool": "R1",
	"toggle_solar_ui": "Y",
	"sim_speed_up": "D→",
	"sim_speed_down": "D←",
	"jump": "M1/M2",
}

const KEYBOARD_LABELS := {
	"interact": "O",
	"dismount": "X",
	"charge": "C",
	"repair": "R",
	"use_tool": "LMB",
	"toggle_camera": "V",
	"equip_tool": "1",
	"unequip_tool": "0",
	"toggle_light_menu": "P",
	"toggle_tool": "1/0",
	"toggle_solar_ui": "—",
	"toggle_library": "U",
	"sim_speed_up": "—",
	"sim_speed_down": "—",
	"jump": "—",
}

func _ready() -> void:
	visible = false
	panel.modulate.a = 0.0

func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_using_controller = true
	elif event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion:
		_using_controller = false

func get_action_label(action: String) -> String:
	if _using_controller:
		return CONTROLLER_LABELS.get(action, action.to_upper())
	return KEYBOARD_LABELS.get(action, action.to_upper())

func show_prompt(action_key: String, action_text: String) -> void:
	key_icon.text = "[%s]" % action_key
	prompt_label.text = action_text
	visible = true
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(panel, "modulate:a", 1.0, 0.15)

func show_action_prompt(action: String, action_text: String) -> void:
	show_prompt(get_action_label(action), action_text)

func hide_prompt() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(panel, "modulate:a", 0.0, 0.15)
	_tween.tween_callback(func(): visible = false)

func show_ride_prompt() -> void:
	show_action_prompt("interact", "Ride Electric Unicycle")

func show_dismount_prompt() -> void:
	show_action_prompt("dismount", "Dismount")


func show_dismount_prompt_transient(duration_sec: float = 4.0) -> void:
	show_dismount_prompt()
	if _transient_hide_timer == null:
		_transient_hide_timer = Timer.new()
		_transient_hide_timer.one_shot = true
		add_child(_transient_hide_timer)
		_transient_hide_timer.timeout.connect(_on_transient_dismount_prompt_hide)
	_transient_hide_timer.stop()
	_transient_hide_timer.wait_time = maxf(0.5, duration_sec)
	_transient_hide_timer.start()


func _on_transient_dismount_prompt_hide() -> void:
	hide_prompt()

func show_charge_prompt() -> void:
	show_action_prompt("charge", "Charge EUC")

func show_stop_charge_prompt() -> void:
	show_action_prompt("dismount", "Stop Charging")

func show_custom_ride_prompt(text: String) -> void:
	show_action_prompt("interact", text)

func show_custom_charge_prompt(vehicle_name: String) -> void:
	show_action_prompt("charge", "Charge %s" % vehicle_name)

func show_ride_and_charge_prompt(ride_text: String, vehicle_name: String) -> void:
	var interact_label := get_action_label("interact")
	var charge_label := get_action_label("charge")
	key_icon.text = "[%s] / [%s]" % [interact_label, charge_label]
	prompt_label.text = "%s / Charge %s" % [ride_text, vehicle_name]
	visible = true
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(panel, "modulate:a", 1.0, 0.15)

func show_repair_prompt() -> void:
	show_action_prompt("repair", "⚡ Repair Shorted EUC")
