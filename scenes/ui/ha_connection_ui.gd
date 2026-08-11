extends Control

## Home Assistant Connection UI
## Allows users to configure and manage WebSocket connection to Home Assistant

var ha_client: Node
var time_ui: Control

@onready var panel: Panel = $Panel
@onready var url_input: LineEdit = $Panel/MarginContainer/VBoxContainer/ConnectionSection/URLInput
@onready var token_input: LineEdit = $Panel/MarginContainer/VBoxContainer/ConnectionSection/TokenInput
@onready var connect_button: Button = $Panel/MarginContainer/VBoxContainer/ConnectionSection/ButtonContainer/ConnectButton
@onready var disconnect_button: Button = $Panel/MarginContainer/VBoxContainer/ConnectionSection/ButtonContainer/DisconnectButton
@onready var status_label: Label = $Panel/MarginContainer/VBoxContainer/ConnectionSection/StatusLabel
@onready var entity_list_input: TextEdit = $Panel/MarginContainer/VBoxContainer/EntitySection/EntityListInput
@onready var subscribe_button: Button = $Panel/MarginContainer/VBoxContainer/EntitySection/SubscribeButton

var is_connected: bool = false
var is_authenticated: bool = false

func _ready() -> void:
	# Find the HA client node (should be added to main scene)
	# UILayer -> main -> HAClient
	var main_node = get_parent().get_parent()
	if main_node:
		ha_client = main_node.get_node_or_null("HAClient")
		if ha_client:
			# Connect to HA client signals
			ha_client.connection_status_changed.connect(_on_connection_status_changed)
			ha_client.authentication_status_changed.connect(_on_authentication_status_changed)
			ha_client.sensor_updated.connect(_on_sensor_updated)
		else:
			pass
	
	# Find TimeUI to sync visibility (TimeUI is a sibling in UILayer)
	time_ui = get_node_or_null("../TimeUI")
	if time_ui:
		# Sync visibility with TimeUI
		_update_visibility()
	
	# Start hidden (will show when TimeUI is visible)
	if panel:
		panel.visible = false
	
	# Load saved settings after UI is ready
	await get_tree().process_frame
	_load_settings()
	
	# Update UI state after a frame to ensure all @onready nodes are initialized
	await get_tree().process_frame
	_update_ui_state()

func _load_settings() -> void:
	"""Load saved connection settings from config file"""
	# Try to get UI elements if @onready hasn't set them yet
	if not url_input:
		url_input = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/URLInput")
	if not token_input:
		token_input = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/TokenInput")
	if not entity_list_input:
		entity_list_input = get_node_or_null("Panel/MarginContainer/VBoxContainer/EntitySection/EntityListInput")
	
	if not url_input or not token_input:
		return
	
	var config = ConfigFile.new()
	var err = config.load("user://ha_connection.cfg")
	var saved_url = ""
	var saved_token = ""
	var saved_entities = ""
	
	if err == OK:
		saved_url = config.get_value("connection", "url", "ws://YOUR_HA_IP:8123/api/websocket")
		saved_token = config.get_value("connection", "token", "YOUR_LONG_LIVED_TOKEN")
		saved_entities = config.get_value("connection", "entities", "")
		
		if url_input:
			url_input.text = saved_url
		if token_input:
			token_input.text = saved_token
		if entity_list_input:
			entity_list_input.text = saved_entities
		
		# Auto-connect if we have valid saved credentials
		if _is_valid_url(saved_url) and _is_valid_token(saved_token):
			call_deferred("_auto_connect", saved_entities)
	else:
		# Use defaults
		if url_input:
			url_input.text = "ws://YOUR_HA_IP:8123/api/websocket"
		if token_input:
			token_input.text = "YOUR_LONG_LIVED_TOKEN"

func _is_valid_url(url: String) -> bool:
	"""Check if URL is valid (not default placeholder)"""
	return url != "" and url != "ws://YOUR_HA_IP:8123/api/websocket" and url.begins_with("ws")

func _is_valid_token(token: String) -> bool:
	"""Check if token is valid (not default placeholder)"""
	return token != "" and token != "YOUR_LONG_LIVED_TOKEN" and token.length() > 10

func _auto_connect(entities_to_subscribe: String) -> void:
	"""Auto-connect and subscribe to saved entities"""
	if not ha_client:
		return
	
	if not url_input or not token_input:
		return
	
	# Update status
	if status_label:
		status_label.text = "Status: Auto-connecting..."
		status_label.modulate = Color.YELLOW
	
	# Connect
	ha_client.connect_to_ha(url_input.text, token_input.text)
	
	# Wait for authentication then subscribe
	if entities_to_subscribe != "":
		# Connect to auth signal to auto-subscribe after connection
		if not ha_client.authentication_status_changed.is_connected(_on_auto_subscribe):
			ha_client.authentication_status_changed.connect(_on_auto_subscribe.bind(entities_to_subscribe), CONNECT_ONE_SHOT)

func _on_auto_subscribe(authenticated: bool, entities_text: String) -> void:
	"""Called after auto-connect authentication to subscribe to entities"""
	if not authenticated:
		return
	
	# Parse and subscribe to entities
	var raw_entities: PackedStringArray
	if "\n" in entities_text:
		raw_entities = entities_text.split("\n", false)
	else:
		raw_entities = entities_text.split(",", false)
	
	var cleaned_entities: Array[String] = []
	for entity in raw_entities:
		var trimmed = entity.strip_edges()
		if trimmed != "":
			cleaned_entities.append(trimmed)
	
	if not cleaned_entities.is_empty() and ha_client:
		ha_client.subscribe_to_entities(cleaned_entities)
		
		# Also request initial states for subscribed entities
		if ha_client.has_method("get_entity_states"):
			ha_client.get_entity_states(cleaned_entities)
		
		if status_label:
			status_label.text = "Status: Connected ✓ | Subscribed to " + str(cleaned_entities.size()) + " entities"
			status_label.modulate = Color.GREEN
		

func _save_settings() -> void:
	"""Save connection settings to config file"""
	# Try to get UI elements if @onready hasn't set them yet
	if not url_input:
		url_input = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/URLInput")
	if not token_input:
		token_input = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/TokenInput")
	if not entity_list_input:
		entity_list_input = get_node_or_null("Panel/MarginContainer/VBoxContainer/EntitySection/EntityListInput")
	
	if not url_input or not token_input:
		return
	
	var config = ConfigFile.new()
	if url_input:
		config.set_value("connection", "url", url_input.text)
	if token_input:
		config.set_value("connection", "token", token_input.text)
	if entity_list_input:
		config.set_value("connection", "entities", entity_list_input.text)
	config.save("user://ha_connection.cfg")

func _update_visibility() -> void:
	"""Update visibility based on TimeUI visibility"""
	if time_ui:
		if "ui_visible" in time_ui:
			panel.visible = time_ui.ui_visible
		else:
			# Fallback: check if TimeUI panel is visible
			var time_panel = time_ui.get_node_or_null("Panel")
			if time_panel:
				panel.visible = time_panel.visible
	else:
		# Default to hidden if we can't determine TimeUI state
		panel.visible = false

## Visibility mirror of TimeUI. Throttled rather than run every frame: this is
## a panel show/hide, nothing here is animated, and the fallback branch did a
## get_node_or_null() per frame. Same accumulator shape as
## scenes/ui/weather_card_ui.gd.
const _VIS_POLL_INTERVAL := 0.25
var _vis_poll_accum: float = 0.0

func _process(delta: float) -> void:
	"""Update visibility based on TimeUI state"""
	_vis_poll_accum += delta
	if _vis_poll_accum < _VIS_POLL_INTERVAL:
		return
	_vis_poll_accum = 0.0
	if time_ui:
		if "ui_visible" in time_ui:
			panel.visible = time_ui.ui_visible
		else:
			# Fallback: check if TimeUI panel is visible
			var time_panel = time_ui.get_node_or_null("Panel")
			if time_panel:
				panel.visible = time_panel.visible

func _ensure_ui_elements() -> bool:
	"""Ensure UI elements are loaded, return true if all essential elements exist"""
	# Try to get UI elements if @onready hasn't set them yet
	if not status_label:
		status_label = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/StatusLabel")
	if not connect_button:
		connect_button = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/ButtonContainer/ConnectButton")
	if not disconnect_button:
		disconnect_button = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/ButtonContainer/DisconnectButton")
	if not subscribe_button:
		subscribe_button = get_node_or_null("Panel/MarginContainer/VBoxContainer/EntitySection/SubscribeButton")
	if not url_input:
		url_input = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/URLInput")
	if not token_input:
		token_input = get_node_or_null("Panel/MarginContainer/VBoxContainer/ConnectionSection/TokenInput")
	
	# Check if we have the essential elements
	return status_label != null and connect_button != null and disconnect_button != null and subscribe_button != null

func _update_ui_state() -> void:
	"""Update UI elements based on connection state"""
	# Ensure UI elements are loaded
	if not _ensure_ui_elements():
		return
	
	if is_connected and is_authenticated:
		status_label.text = "Status: Connected & Authenticated ✓"
		status_label.modulate = Color.GREEN
		if connect_button:
			connect_button.disabled = true
		if disconnect_button:
			disconnect_button.disabled = false
		if url_input:
			url_input.editable = false
		if token_input:
			token_input.editable = false
		if subscribe_button:
			subscribe_button.disabled = false
	elif is_connected:
		status_label.text = "Status: Connected (Authenticating...)"
		status_label.modulate = Color.YELLOW
		if connect_button:
			connect_button.disabled = true
		if disconnect_button:
			disconnect_button.disabled = false
		if url_input:
			url_input.editable = false
		if token_input:
			token_input.editable = false
		if subscribe_button:
			subscribe_button.disabled = true
	else:
		# Check if we're in the process of connecting (button disabled but not connected yet)
		if connect_button and connect_button.disabled and not is_connected:
			status_label.text = "Status: Connecting..."
			status_label.modulate = Color.YELLOW
		else:
			status_label.text = "Status: Disconnected"
			status_label.modulate = Color.RED
		if connect_button:
			connect_button.disabled = false
		if disconnect_button:
			disconnect_button.disabled = true
		if url_input:
			url_input.editable = true
		if token_input:
			token_input.editable = true
		if subscribe_button:
			subscribe_button.disabled = true

func _on_connection_status_changed(connected: bool) -> void:
	"""Handle connection status change from HA client"""
	is_connected = connected
	# Defer UI update to next frame if UI isn't ready
	if not _ensure_ui_elements():
		await get_tree().process_frame
	_update_ui_state()

func _on_authentication_status_changed(authenticated: bool) -> void:
	"""Handle authentication status change from HA client"""
	is_authenticated = authenticated
	# Defer UI update to next frame if UI isn't ready
	if not _ensure_ui_elements():
		await get_tree().process_frame
	_update_ui_state()

func _on_sensor_updated(entity_id: String, state: Dictionary) -> void:
	"""Handle sensor updates from Home Assistant"""
	pass

func _on_connect_button_pressed() -> void:
	"""Connect to Home Assistant"""
	if not ha_client:
		if status_label:
			status_label.text = "Status: Error - HA Client not found"
			status_label.modulate = Color.RED
		return
	
	# Validate inputs
	if not url_input or not token_input:
		return
	
	if url_input.text == "" or url_input.text == "ws://YOUR_HA_IP:8123/api/websocket":
		if status_label:
			status_label.text = "Status: Please enter a valid WebSocket URL"
			status_label.modulate = Color.RED
		return
	
	if token_input.text == "" or token_input.text == "YOUR_LONG_LIVED_TOKEN":
		if status_label:
			status_label.text = "Status: Please enter a valid access token"
			status_label.modulate = Color.RED
		return
	
	# Save settings
	_save_settings()
	
	# Set initial connecting state before connecting
	is_connected = false
	is_authenticated = false
	if connect_button:
		connect_button.disabled = true
	if disconnect_button:
		disconnect_button.disabled = true
	if status_label:
		status_label.text = "Status: Connecting..."
		status_label.modulate = Color.YELLOW
	
	# Connect (status will be updated by signal handlers)
	ha_client.connect_to_ha(url_input.text, token_input.text)

func _on_disconnect_button_pressed() -> void:
	"""Disconnect from Home Assistant"""
	if ha_client:
		ha_client.disconnect_from_ha()
	if status_label:
		status_label.text = "Status: Disconnected"
		status_label.modulate = Color.RED
	_update_ui_state()

func _on_subscribe_button_pressed() -> void:
	"""Subscribe to entities listed in the text field"""
	if not ha_client or not is_authenticated:
		return
	
	if not entity_list_input:
		return
	
	var entity_text = entity_list_input.text.strip_edges()
	if entity_text == "":
		return
	
	# Parse entity list (one per line or comma-separated)
	var raw_entities: PackedStringArray
	if "\n" in entity_text:
		raw_entities = entity_text.split("\n", false)
	else:
		raw_entities = entity_text.split(",", false)
	
	# Clean up entities (remove whitespace, filter empty)
	var cleaned_entities: Array[String] = []
	for entity in raw_entities:
		var trimmed = entity.strip_edges()
		if trimmed != "":
			cleaned_entities.append(trimmed)
	
	if cleaned_entities.is_empty():
		return
	
	# Subscribe
	ha_client.subscribe_to_entities(cleaned_entities)
	_save_settings()
	
	# Request initial states for all subscribed entities
	if ha_client.has_method("get_entity_states"):
		ha_client.get_entity_states(cleaned_entities)
	
	# Update UI to show subscription status
	if status_label:
		status_label.text = "Status: Connected ✓ | Subscribed to " + str(cleaned_entities.size()) + " entities"
		status_label.modulate = Color.GREEN
