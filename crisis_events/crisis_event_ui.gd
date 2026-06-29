extends CanvasLayer
class_name CrisisEventUI

## UI for displaying crisis event alerts and tool information

const CrisisEvent = preload("res://crisis_events/crisis_event.gd")

@onready var alert_panel: PanelContainer = $AlertPanel
@onready var alert_label: Label = $AlertPanel/MarginContainer/VBoxContainer/AlertLabel
@onready var status_label: Label = $AlertPanel/MarginContainer/VBoxContainer/StatusLabel
@onready var extinguisher_panel: PanelContainer = $ExtinguisherPanel
@onready var pressure_bar: ProgressBar = $ExtinguisherPanel/MarginContainer/VBoxContainer/PressureBar
@onready var pressure_label: Label = $ExtinguisherPanel/MarginContainer/VBoxContainer/PressureLabel

var _alert_tween: Tween
var _current_event = null
var _cached_player: Node = null
var _cached_tool_manager: Node = null
var _tool_manager_connected: bool = false

func _ready() -> void:
	# Start hidden
	alert_panel.visible = false
	extinguisher_panel.visible = false
	
	# Connect to crisis event manager (deferred to ensure it exists)
	call_deferred("_connect_crisis_manager")
	call_deferred("_connect_tool_manager")

func _connect_crisis_manager() -> void:
	var manager := _find_crisis_manager()
	if manager != null:
		if not manager.event_started.is_connected(_on_event_started):
			manager.event_started.connect(_on_event_started)
		if not manager.event_updated.is_connected(_on_event_updated):
			manager.event_updated.connect(_on_event_updated)
		if not manager.event_resolved.is_connected(_on_event_resolved):
			manager.event_resolved.connect(_on_event_resolved)
		if not manager.event_failed.is_connected(_on_event_failed):
			manager.event_failed.connect(_on_event_failed)
	else:
		# Set a flag to retry in _process
		_retry_connection = true

var _retry_connection: bool = false
var _connection_retry_count: int = 0
var _connection_retry_timer: float = 0.0
var _tool_connect_retry_timer: float = 0.0
const _CONNECTION_RETRY_INTERVAL: float = 0.5
var _tool_ui_refresh_timer: float = 0.0
const _TOOL_UI_REFRESH_INTERVAL: float = 0.1

func _process(_delta: float) -> void:
	# Retry connection if needed
	if _retry_connection and _connection_retry_count < 10:
		_connection_retry_timer += _delta
		if _connection_retry_timer >= _CONNECTION_RETRY_INTERVAL:
			_connection_retry_timer = 0.0
			_connection_retry_count += 1
			var manager := _find_crisis_manager()
			if manager != null:
				if not manager.event_started.is_connected(_on_event_started):
					manager.event_started.connect(_on_event_started)
				if not manager.event_updated.is_connected(_on_event_updated):
					manager.event_updated.connect(_on_event_updated)
				if not manager.event_resolved.is_connected(_on_event_resolved):
					manager.event_resolved.connect(_on_event_resolved)
				if not manager.event_failed.is_connected(_on_event_failed):
					manager.event_failed.connect(_on_event_failed)
				_retry_connection = false
	elif _retry_connection and _connection_retry_count >= 10:
		_retry_connection = false
	
	# Refresh tool-manager connection occasionally until valid.
	if not _tool_manager_connected:
		_tool_connect_retry_timer += _delta
		if _tool_connect_retry_timer >= _CONNECTION_RETRY_INTERVAL:
			_tool_connect_retry_timer = 0.0
			_connect_tool_manager()
	
	# Update extinguisher UI at 10 Hz (no need for per-frame updates)
	_tool_ui_refresh_timer += _delta
	if _tool_ui_refresh_timer < _TOOL_UI_REFRESH_INTERVAL:
		return
	_tool_ui_refresh_timer = 0.0
	
	if _cached_player == null or not is_instance_valid(_cached_player):
		_cached_player = get_tree().get_first_node_in_group("player")
	
	if _cached_player == null:
		return
	
	if _cached_tool_manager == null or not is_instance_valid(_cached_tool_manager):
		_connect_tool_manager()
	
	if _cached_tool_manager == null:
		return
	
	var current_tool: Node3D = _cached_tool_manager.get_current_tool()
	if current_tool != null and current_tool.has_method("get_tool_id") and current_tool.get_tool_id() == "fire_extinguisher":
		_update_extinguisher_ui(current_tool)

func _connect_tool_manager() -> void:
	if _cached_player == null or not is_instance_valid(_cached_player):
		_cached_player = get_tree().get_first_node_in_group("player")
	
	if _cached_player == null:
		return
	
	# Look for tool manager in player
	var tool_manager := _cached_player.get_node_or_null("ToolManager")
	if tool_manager == null:
		# Try to find it elsewhere
		tool_manager = get_tree().get_first_node_in_group("tool_manager")
	
	if tool_manager != null:
		_cached_tool_manager = tool_manager
		if not tool_manager.tool_equipped.is_connected(_on_tool_equipped):
			tool_manager.tool_equipped.connect(_on_tool_equipped)
		if not tool_manager.tool_unequipped.is_connected(_on_tool_unequipped):
			tool_manager.tool_unequipped.connect(_on_tool_unequipped)
		_tool_manager_connected = true

func _find_crisis_manager() -> Node:
	# Look for CrisisEventManager in scene
	var manager := get_tree().get_first_node_in_group("crisis_event_manager")
	if manager == null:
		# Try to find it in main scene
		var main := get_tree().current_scene
		if main != null:
			manager = main.get_node_or_null("CrisisEventManager")
			if manager == null:
				# Try searching all children
				manager = _find_node_recursive(main, "CrisisEventManager")
	return manager

func _find_node_recursive(node: Node, name: String) -> Node:
	if node.name == name:
		return node
	for child in node.get_children():
		var found := _find_node_recursive(child, name)
		if found != null:
			return found
	return null

func _on_event_started(event) -> void:
	_current_event = event
	_show_alert("CRISIS ALERT", event.get_status_description())

func _on_event_updated(event) -> void:
	if _current_event == event:
		status_label.text = event.get_status_description()

func _on_event_resolved(event) -> void:
	if _current_event == event:
		_show_achievement("🎉 CRISIS AVERTED!", "Nice work! %s extinguished!" % event.event_name)
		_current_event = null
		_hide_alert_after_delay(4.0)
	else:
		pass

func _on_event_failed(event) -> void:
	if _current_event == event:
		_show_alert("CRISIS FAILED", "%s has caused significant damage." % event.event_name)
		_current_event = null
		_hide_alert_after_delay(3.0)

func _show_alert(title: String, message: String) -> void:
	alert_label.text = title
	status_label.text = message
	alert_panel.visible = true
	
	# Reset to normal color
	alert_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))  # Red for alerts
	
	# Fade in
	if _alert_tween:
		_alert_tween.kill()
	_alert_tween = create_tween()
	_alert_tween.tween_property(alert_panel, "modulate:a", 1.0, 0.3)

func _show_achievement(title: String, message: String) -> void:
	alert_label.text = title
	status_label.text = message
	alert_panel.visible = true
	
	# Green color for success!
	alert_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	
	# Fade in with a pop effect
	if _alert_tween:
		_alert_tween.kill()
	_alert_tween = create_tween()
	alert_panel.scale = Vector2(0.8, 0.8)
	_alert_tween.set_parallel(true)
	_alert_tween.tween_property(alert_panel, "modulate:a", 1.0, 0.2)
	_alert_tween.tween_property(alert_panel, "scale", Vector2(1.0, 1.0), 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

func _hide_alert_after_delay(delay: float) -> void:
	# Wait for any existing tween to finish, then create hide tween
	# Use a timer to not interrupt the show animation
	var timer := get_tree().create_timer(delay)
	timer.timeout.connect(func():
		if _alert_tween:
			_alert_tween.kill()
		_alert_tween = create_tween()
		_alert_tween.tween_property(alert_panel, "modulate:a", 0.0, 0.5)
		_alert_tween.tween_callback(func(): alert_panel.visible = false)
	)

func _on_tool_equipped(tool: Node3D) -> void:
	if tool.has_method("get_tool_id") and tool.get_tool_id() == "fire_extinguisher":
		extinguisher_panel.visible = true
		_update_extinguisher_ui(tool)

func _on_tool_unequipped(tool: Node3D) -> void:
	if tool.has_method("get_tool_id") and tool.get_tool_id() == "fire_extinguisher":
		extinguisher_panel.visible = false

# _process moved to above to handle retry connection

func _update_extinguisher_ui(extinguisher: Node3D) -> void:
	if extinguisher == null:
		return
	
	if extinguisher.has_method("get_pressure_percentage"):
		var pressure_pct: float = extinguisher.get_pressure_percentage()
		pressure_bar.value = pressure_pct * 100.0
		
		if extinguisher.has_method("can_spray"):
			var can_spray: bool = extinguisher.can_spray()
			if can_spray:
				pressure_label.text = "Pressure: %.0f%%" % (pressure_pct * 100.0)
			else:
				pressure_label.text = "Pressure: LOW (%.0f%%)" % (pressure_pct * 100.0)
