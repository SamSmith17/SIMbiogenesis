extends Node

## Main/HAClient — a facade over the HomeAssistant autoload
## (core/ha/ha_service.gd), which owns the one WebSocket connection.
##
## Kept because a dozen scripts find Home Assistant by node path
## (Main/HAClient) or through ServiceLocator.HA_CLIENT and read these names:
## the signals are re-emitted from the service and the methods forward to it,
## so none of those consumers had to change. New code should use the
## HomeAssistant autoload directly.

signal sensor_updated(entity_id: String, state: Dictionary)
signal connection_status_changed(connected: bool)
signal authentication_status_changed(authenticated: bool)
signal initial_states_received()
signal history_statistics_received(statistic_id: String, statistics: Array)
signal raw_history_received(entity_id: String, history: Array)

var is_connected: bool:
	get:
		var s := _svc()
		return s != null and bool(s.call("is_ws_open"))
	set(_v):
		pass

var is_authenticated: bool:
	get:
		var s := _svc()
		return s != null and bool(s.call("is_authed"))
	set(_v):
		pass

var subscribed_entities: Array:
	get:
		var s := _svc()
		return (s.get("subscribed_entities") as Array).duplicate() if s != null else []
	set(_v):
		pass


func _ready() -> void:
	ServiceLocator.provide(ServiceLocator.HA_CLIENT, self)
	var s := _svc()
	if s == null:
		return
	s.sensor_updated.connect(func(eid: String, st: Dictionary) -> void: sensor_updated.emit(eid, st))
	s.connection_status_changed.connect(func(on: bool) -> void: connection_status_changed.emit(on))
	s.authentication_status_changed.connect(func(on: bool) -> void: authentication_status_changed.emit(on))
	s.initial_states_received.connect(func() -> void: initial_states_received.emit())
	s.history_statistics_received.connect(func(sid: String, a: Array) -> void: history_statistics_received.emit(sid, a))
	s.raw_history_received.connect(func(eid: String, a: Array) -> void: raw_history_received.emit(eid, a))


func _svc() -> Node:
	return get_node_or_null("/root/HomeAssistant")


func connect_to_ha(url: String = "", token: String = "") -> void:
	var s := _svc()
	if s == null:
		return
	if url.is_empty() and token.is_empty():
		s.call("retry_now")
	else:
		s.call("connect_with", url, token, "", true)


func disconnect_from_ha() -> void:
	var s := _svc()
	if s != null:
		s.call("disconnect_ha")


func subscribe_to_entities(entity_ids: Array) -> void:
	var s := _svc()
	if s != null:
		s.call("subscribe_to_entities", entity_ids)


func get_entity_states(entity_ids: Array) -> void:
	var s := _svc()
	if s != null:
		s.call("get_entity_states", entity_ids)


func get_single_entity_state(entity_id: String) -> void:
	var s := _svc()
	if s != null:
		s.call("get_single_entity_state", entity_id)


func get_states() -> void:
	var s := _svc()
	if s != null:
		s.call("refresh_catalog")


func call_service(domain: String, service: String, entity_id: String,
		service_data: Dictionary = {}, force: bool = false) -> void:
	var s := _svc()
	if s != null:
		s.call("call_service", domain, service, entity_id, service_data, force)


func call_service_no_target(domain: String, service: String, service_data: Dictionary = {}) -> void:
	var s := _svc()
	if s != null:
		s.call("call_service_no_target", domain, service, service_data)


func get_history_statistics(statistic_id: String, start_time: String, end_time: String, period: String = "hour") -> void:
	var s := _svc()
	if s != null:
		s.call("get_history_statistics", statistic_id, start_time, end_time, period)


func get_entity_history(entity_id: String, start_time: String, end_time: String, minimal_response: bool = true) -> void:
	var s := _svc()
	if s != null:
		s.call("get_entity_history", entity_id, start_time, end_time, minimal_response)


func get_today_hourly_statistics(statistic_id: String) -> void:
	var r := _today_range()
	get_history_statistics(statistic_id, r[0], r[1], "hour")


func get_today_entity_history(entity_id: String) -> void:
	var r := _today_range()
	get_entity_history(entity_id, r[0], r[1])


## [start, end] of today in local time, ISO with offset.
static func _today_range() -> Array:
	var dt := Time.get_datetime_dict_from_system()
	var tz := Time.get_time_zone_from_system()
	var off_min := int(tz.get("bias", 0))
	var sgn := "+" if off_min >= 0 else "-"
	var tzs := "%s%02d:%02d" % [sgn, absi(off_min) / 60, absi(off_min) % 60]
	var start := "%04d-%02d-%02dT00:00:00%s" % [dt.year, dt.month, dt.day, tzs]
	var end := "%04d-%02d-%02dT%02d:%02d:%02d%s" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, tzs]
	return [start, end]


func toggle_light(entity_id: String) -> void:
	call_service("light", "toggle", entity_id)


func set_light_brightness(entity_id: String, brightness: int) -> void:
	call_service("light", "turn_on", entity_id, {"brightness": brightness})


func turn_on_light(entity_id: String) -> void:
	call_service("light", "turn_on", entity_id)


func turn_off_light(entity_id: String) -> void:
	call_service("light", "turn_off", entity_id)


func set_switch_state(entity_id: String, on: bool) -> void:
	call_service("switch", "turn_on" if on else "turn_off", entity_id)
