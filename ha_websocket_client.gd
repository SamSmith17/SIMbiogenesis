extends Node

## Home Assistant WebSocket Client
## Handles bidirectional communication with Home Assistant via WebSocket API

var websocket_client: WebSocketPeer
var ha_url: String = "ws://YOUR_HA_IP:8123/api/websocket"
var access_token: String = "YOUR_LONG_LIVED_TOKEN"
var message_id: int = 1
var subscribed_entities: Array[String] = []
var is_connected: bool = false
var is_authenticated: bool = false
var reconnect_timer: float = 0.0
var reconnect_delay: float = 5.0

# Track which message IDs are for specific entity state requests
var _pending_entity_state_requests: Dictionary = {}  # message_id -> entity_id
var _pending_entities_state_request_id: int = -1  # For batch entity state requests

signal sensor_updated(entity_id: String, state: Dictionary)
signal connection_status_changed(connected: bool)
signal authentication_status_changed(authenticated: bool)
signal initial_states_received()
signal history_statistics_received(statistic_id: String, statistics: Array)

func _ready():
	Services.register(Services.HA_CLIENT, self)
	# Don't auto-connect - wait for user to configure and connect
	pass

func connect_to_ha(url: String = "", token: String = ""):
	"""Connect to Home Assistant with provided URL and token"""
	if url != "":
		ha_url = url
	if token != "":
		access_token = token
	
	if ha_url == "ws://YOUR_HA_IP:8123/api/websocket" or access_token == "YOUR_LONG_LIVED_TOKEN":
		return
	
	# Close existing connection if any
	if websocket_client != null:
		websocket_client.close()
		websocket_client = null
	
	is_connected = false
	is_authenticated = false
	reconnect_timer = 0.0
	
	websocket_client = WebSocketPeer.new()
	# Increase buffer sizes to handle large HA responses (default is 64KB, HA can send MB+)
	websocket_client.inbound_buffer_size = 16 * 1024 * 1024  # 16 MB
	websocket_client.outbound_buffer_size = 1 * 1024 * 1024  # 1 MB
	
	var error = websocket_client.connect_to_url(ha_url)
	if error != OK:
		connection_status_changed.emit(false)
		return
	
	# Wait for connection and authenticate. Guard get_tree(): connect_to_ha() is
	# public and may be called before this node is inside the scene tree.
	var tree := get_tree()
	if tree == null:
		connection_status_changed.emit(false)
		return
	await tree.create_timer(0.5).timeout
	authenticate()

func disconnect_from_ha():
	"""Disconnect from Home Assistant"""
	if websocket_client != null:
		websocket_client.close()
		websocket_client = null
	is_connected = false
	is_authenticated = false
	connection_status_changed.emit(false)
	authentication_status_changed.emit(false)

func authenticate():
	"""Send authentication message to Home Assistant"""
	if websocket_client == null:
		return
	
	var auth_message = {
		"type": "auth",
		"access_token": access_token
	}
	send_message(auth_message)

func send_message(message: Dictionary):
	"""Send a message to Home Assistant"""
	if websocket_client == null:
		return
	
	var state = websocket_client.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		var json_string = JSON.stringify(message)
		var error = websocket_client.send_text(json_string)
		if error != OK:
			pass
		else:
			pass
	else:
		pass

func subscribe_to_entities(entity_ids: Array[String]):
	"""Subscribe to state changes for specific entities.
	Merges new IDs into the existing subscription list so that multiple
	callers (e.g. InverterBridge, SolarUI) do not overwrite each other.
	HA receives a single global state_changed subscription; filtering is
	applied locally via subscribed_entities."""
	for id: String in entity_ids:
		if id not in subscribed_entities:
			subscribed_entities.append(id)
	var subscribe_message = {
		"id": message_id,
		"type": "subscribe_events",
		"event_type": "state_changed"
	}
	send_message(subscribe_message)
	message_id += 1

## Call a Home Assistant service.
##
## SimMode safety gate:
##   When the game is running in SIMULATE mode (fast-forward, paused, or
##   otherwise diverged from real time) we MUST NOT toggle physical devices
##   on the user's network — a sim-only event would suddenly flip a real
##   switch and destroy the trust between the simulation and reality.
##
##   Pass `force = true` for genuinely user-driven actions that must run
##   regardless of mode (the load calibrator turning a switch on for a
##   measurement, manual debug commands, etc.).
func call_service(domain: String, service: String, entity_id: String,
		service_data: Dictionary = {}, force: bool = false):
	if not force:
		var sm: Node = get_node_or_null("/root/SimMode")
		if sm != null and not bool(sm.call("should_run_realworld_actions")):
			print("[HAClient] Suppressed %s.%s on %s (SIMULATE mode)" %
				[domain, service, entity_id])
			return
	var service_message = {
		"id": message_id,
		"type": "call_service",
		"domain": domain,
		"service": service,
		"target": {"entity_id": entity_id},
		"service_data": service_data
	}
	send_message(service_message)
	message_id += 1


func call_service_no_target(domain: String, service: String, service_data: Dictionary = {}) -> void:
	"""Call a Home Assistant service without an entity target (e.g. persistent_notification.create)."""
	var service_message := {
		"id": message_id,
		"type": "call_service",
		"domain": domain,
		"service": service,
		"service_data": service_data,
	}
	send_message(service_message)
	message_id += 1

func get_states():
	"""Get state of all entities - WARNING: Can be very large (MB+), may exceed buffer"""
	var states_message = {
		"id": message_id,
		"type": "get_states"
	}
	send_message(states_message)
	message_id += 1

func get_entity_states(entity_ids: Array[String]):
	"""Get states of specific entities by fetching all states and filtering"""
	if entity_ids.is_empty():
		return
	
	# Store which entities we want to filter for
	_requested_entity_ids = entity_ids.duplicate()
	
	# Use get_states and filter the results
	var states_message = {
		"id": message_id,
		"type": "get_states"
	}
	_pending_entities_state_request_id = message_id
	send_message(states_message)
	message_id += 1

func get_single_entity_state(entity_id: String):
	"""Get state of a single entity using render_template (much faster than get_states)"""
	if entity_id == "":
		return
	
	# Use render_template to get just this one entity's state - much more efficient
	var template = "{{ state_attr('" + entity_id + "', 'friendly_name') or '" + entity_id + "' }}|||{{ states('" + entity_id + "') }}"
	
	var render_message = {
		"id": message_id,
		"type": "render_template",
		"template": template
	}
	_pending_single_entity_requests[message_id] = entity_id
	send_message(render_message)
	message_id += 1

func get_history_statistics(statistic_id: String, start_time: String, end_time: String, period: String = "hour"):
	"""
	Get historical statistics for a sensor.
	
	statistic_id: The entity ID or statistic ID (e.g., 'sensor.solar_production')
	start_time: ISO format start time (e.g., '2024-01-29T00:00:00+00:00')
	end_time: ISO format end time (e.g., '2024-01-29T23:59:59+00:00')
	period: 'hour', 'day', 'week', or 'month'
	
	Returns hourly statistics via history_statistics_received signal.
	"""
	if statistic_id == "":
		return
	
	var history_message = {
		"id": message_id,
		"type": "recorder/statistics_during_period",
		"start_time": start_time,
		"end_time": end_time,
		"statistic_ids": [statistic_id],
		"period": period
	}
	
	_pending_history_requests[message_id] = statistic_id
	send_message(history_message)
	message_id += 1

func get_today_hourly_statistics(statistic_id: String):
	"""
	Convenience function to get today's hourly statistics for a sensor.
	Uses local timezone for the query.
	"""
	if statistic_id == "":
		return
	
	# Get current date/time info
	var datetime = Time.get_datetime_dict_from_system()
	var timezone = Time.get_time_zone_from_system()
	var tz_offset_hours = timezone.bias / -60  # bias is in minutes, negative for west
	var tz_sign = "+" if tz_offset_hours >= 0 else "-"
	var tz_string = "%s%02d:00" % [tz_sign, abs(tz_offset_hours)]
	
	# Start of today (midnight local time)
	var start_time = "%04d-%02d-%02dT00:00:00%s" % [
		datetime.year, datetime.month, datetime.day, tz_string
	]
	
	# Current time (or end of day)
	var end_time = "%04d-%02d-%02dT%02d:%02d:%02d%s" % [
		datetime.year, datetime.month, datetime.day,
		datetime.hour, datetime.minute, datetime.second, tz_string
	]
	
	get_history_statistics(statistic_id, start_time, end_time, "hour")

# Track history (raw state) requests: message_id -> entity_id
var _pending_raw_history_requests: Dictionary = {}

signal raw_history_received(entity_id: String, history: Array)

func get_entity_history(entity_id: String, start_time: String, end_time: String, minimal_response: bool = true):
	"""
	Get raw state history for an entity.
	
	entity_id: The entity ID (e.g., 'sensor.solar_power')
	start_time: ISO format start time
	end_time: ISO format end time
	minimal_response: If true, only returns state changes (not all attributes)
	
	Returns history via raw_history_received signal.
	"""
	if entity_id == "":
		return
	
	var history_message = {
		"id": message_id,
		"type": "history/history_during_period",
		"start_time": start_time,
		"end_time": end_time,
		"entity_ids": [entity_id],
		"minimal_response": minimal_response,
		"no_attributes": true,
		"significant_changes_only": true  # Only significant changes to reduce data
	}
	
	_pending_raw_history_requests[message_id] = entity_id
	send_message(history_message)
	message_id += 1

func get_today_entity_history(entity_id: String):
	"""
	Convenience function to get today's raw state history for an entity.
	"""
	if entity_id == "":
		return
	
	var datetime = Time.get_datetime_dict_from_system()
	var timezone = Time.get_time_zone_from_system()
	var tz_offset_hours = timezone.bias / -60
	var tz_sign = "+" if tz_offset_hours >= 0 else "-"
	var tz_string = "%s%02d:00" % [tz_sign, abs(tz_offset_hours)]
	
	var start_time = "%04d-%02d-%02dT00:00:00%s" % [
		datetime.year, datetime.month, datetime.day, tz_string
	]
	
	var end_time = "%04d-%02d-%02dT%02d:%02d:%02d%s" % [
		datetime.year, datetime.month, datetime.day,
		datetime.hour, datetime.minute, datetime.second, tz_string
	]
	
	get_entity_history(entity_id, start_time, end_time)

# Store entity IDs we're specifically requesting
var _requested_entity_ids: Array[String] = []
# Track single entity state requests: message_id -> entity_id
var _pending_single_entity_requests: Dictionary = {}
# Track history statistics requests: message_id -> statistic_id
var _pending_history_requests: Dictionary = {}

func _process(_delta):
	if websocket_client == null:
		return
	
	websocket_client.poll()
	
	var state = websocket_client.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not is_connected:
			is_connected = true
			connection_status_changed.emit(true)
		
		while websocket_client.get_available_packet_count() > 0:
			var packet = websocket_client.get_packet()
			if packet.size() == 0:
				continue
			
			var json = JSON.new()
			var error = json.parse(packet.get_string_from_utf8())
			if error == OK:
				handle_message(json.data)
			else:
				pass
	elif state == WebSocketPeer.STATE_CLOSED:
		var close_code = websocket_client.get_close_code()
		var close_reason = websocket_client.get_close_reason()
		if is_connected or is_authenticated:
			pass
		if is_connected:
			is_connected = false
			is_authenticated = false
			connection_status_changed.emit(false)
			authentication_status_changed.emit(false)
			# Only auto-reconnect if we were previously connected (not on initial failure)
			if reconnect_timer <= 0.0:
				reconnect_timer = reconnect_delay
		reconnect_timer -= _delta
		if reconnect_timer <= 0.0 and is_connected == false:
			connect_to_ha()
	elif state == WebSocketPeer.STATE_CONNECTING:
		# Still connecting, do nothing
		pass

func handle_message(data: Dictionary):
	"""Handle incoming messages from Home Assistant"""
	var msg_type = data.get("type", "")
	match msg_type:
		"auth_required":
			# Already sent auth, should get auth_ok next
			pass
		"auth_ok":
			is_authenticated = true
			authentication_status_changed.emit(true)
			# Subscribe to state changes if any entities are specified
			if not subscribed_entities.is_empty():
				subscribe_to_entities(subscribed_entities)
			# Note: get_states() fetches ALL entities which can be very large (MB+)
			# Call it manually only if needed, or use get_entity_state() for specific entities
		"auth_invalid":
			is_authenticated = false
			authentication_status_changed.emit(false)
		"event":
			var event_id = data.get("id", -1)
			
			# Check if this is a render_template event (for single entity state requests)
			if _pending_single_entity_requests.has(event_id):
				var entity_id = _pending_single_entity_requests[event_id]
				var result = data.get("event", {}).get("result", "")
				
				# Parse result: "friendly_name|||state"
				if "|||" in result:
					var parts = result.split("|||")
					var state_value = parts[1] if parts.size() > 1 else ""
					var state_dict = {
						"entity_id": entity_id,
						"state": state_value
					}
					sensor_updated.emit(entity_id, state_dict)
				return
			
			# Handle state_changed events
			if data.get("event", {}).get("event_type") == "state_changed":
				var event_data = data.get("event", {}).get("data", {})
				var entity_id = event_data.get("entity_id", "")
				if entity_id in subscribed_entities or subscribed_entities.is_empty():
					var new_state = event_data.get("new_state", {})
					sensor_updated.emit(entity_id, new_state)
		"result":
			# Handle responses to get_states, call_service, etc.
			handle_result(data)

func handle_result(data: Dictionary):
	"""Handle result messages from Home Assistant"""
	# IMPORTANT: JSON parser returns numbers as floats, but we use int keys
	var msg_id: int = int(data.get("id", -1))
	var success = data.get("success", true)
	# Check if this is a response to a history statistics request
	if _pending_history_requests.has(msg_id):
		var statistic_id = _pending_history_requests[msg_id]
		_pending_history_requests.erase(msg_id)
		
		if not success:
			var error_msg = data.get("error", {})
			history_statistics_received.emit(statistic_id, [])
			return
		
		var result = data.get("result", {})
		
		# Result is a dictionary with statistic_id as key, value is array of stats
		if result is Dictionary:
			# Try exact match first
			var stats_array = result.get(statistic_id, null)
			
			# If not found, try to find a matching key (sometimes statistic_id differs slightly)
			if stats_array == null:
				for key in result.keys():
					if statistic_id in key or key in statistic_id:
						stats_array = result.get(key)
						break
			
			if stats_array != null and stats_array is Array:
				history_statistics_received.emit(statistic_id, stats_array)
			else:
				history_statistics_received.emit(statistic_id, [])
		else:
			history_statistics_received.emit(statistic_id, [])
		return
	
	# Check if this is a response to a raw history request
	if _pending_raw_history_requests.has(msg_id):
		var entity_id = _pending_raw_history_requests[msg_id]
		_pending_raw_history_requests.erase(msg_id)
		
		if not success:
			var error_msg = data.get("error", {})
			raw_history_received.emit(entity_id, [])
			return
		
		var result = data.get("result", {})
		
		# Result is a dictionary with entity_id as key, value is array of state objects
		if result is Dictionary:
			var history_array = result.get(entity_id, [])
			if history_array is Array:
				if history_array.size() > 0:
					pass
				raw_history_received.emit(entity_id, history_array)
			else:
				raw_history_received.emit(entity_id, [])
		else:
			raw_history_received.emit(entity_id, [])
		return
	
	# Check if this is a response to a single entity state request (render_template)
	if _pending_single_entity_requests.has(msg_id):
		var entity_id = _pending_single_entity_requests[msg_id]
		_pending_single_entity_requests.erase(msg_id)
		
		if not success:
			return
		
		# render_template returns a "listeners" dict and we get updates via events
		# For one-shot, we need to look at the initial result or subscribe
		# Actually render_template in HA is a subscription, so we'll get an event
		return
	
	# Check if this is a response to our entity state request (get_states with filter)
	if msg_id == _pending_entities_state_request_id:
		_pending_entities_state_request_id = -1
		
		if not success:
			var error_msg = data.get("error", {})
			_requested_entity_ids.clear()
			return
		
		var result = data.get("result", [])
		
		# get_states returns an Array of all entity states
		if result is Array:
			var found_count = 0
			var total_entities = result.size()
			
			for entity_state in result:
				if entity_state is Dictionary:
					var entity_id = entity_state.get("entity_id", "")
					# If we have a filter list, only emit for those entities
					if entity_id != "" and (entity_id in _requested_entity_ids or _requested_entity_ids.is_empty()):
						sensor_updated.emit(entity_id, entity_state)
						found_count += 1
			
		else:
			pass
		
		_requested_entity_ids.clear()
		initial_states_received.emit()
		return
	
	if data.has("result"):
		# Generic result handling for other requests
		if data.get("result") is Array:
			for state in data.get("result", []):
				if state is Dictionary:
					var entity_id = state.get("entity_id", "")
					if entity_id != "":
						sensor_updated.emit(entity_id, state)

# Example helper functions for common operations

func toggle_light(entity_id: String):
	"""Toggle a light entity"""
	call_service("light", "toggle", entity_id)

func set_light_brightness(entity_id: String, brightness: int):
	"""Set light brightness (0-255)"""
	call_service("light", "turn_on", entity_id, {"brightness": brightness})

func turn_on_light(entity_id: String):
	"""Turn on a light"""
	call_service("light", "turn_on", entity_id)

func turn_off_light(entity_id: String):
	"""Turn off a light"""
	call_service("light", "turn_off", entity_id)

func set_switch_state(entity_id: String, state: bool):
	"""Set switch state"""
	var service = "turn_on" if state else "turn_off"
	call_service("switch", service, entity_id)
