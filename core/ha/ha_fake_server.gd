class_name HaFakeServer
extends Node
## A tiny stand-in for Home Assistant's WebSocket API on 127.0.0.1, for the
## selftest and harness probes: auth_required → auth → auth_ok/auth_invalid,
## get_states, get_config, subscribe_events (state_changed), ping/pong,
## call_service (recorded), history/history_during_period and
## recorder/statistics_during_period. push_state() sends a state_changed to
## every subscriber; drop_all() closes every client (a "lost" connection).
##
## Only what the game's client uses; never exposed beyond loopback.

var token: String = ""
var ha_version: String = "2026.10.1"
var location_name: String = "Test Home"
## Never say auth_required (an HTTP server that is not HA's WebSocket API).
var silent: bool = false
## Ignore the auth message (HA that never answers the login).
var mute_auth: bool = false
## entity_id -> {state: String, attributes: Dictionary}
var entities: Dictionary = {}
## history replies: entity_id -> Array of {s, lu} (minimal_response rows)
var history: Dictionary = {}

var port: int = 0
var service_calls: Array = []        # [{domain, service, target, service_data}]
var subscribe_count: int = 0
var get_states_count: int = 0
var auth_attempts: int = 0
var connections: int = 0

var _tcp: TCPServer = null
var _clients: Array = []             # [{ws, authed, subs: Array[int]}]


## Listen on the first free port from `from_port`; returns the port or 0.
func start(from_port: int = 38123) -> int:
	_tcp = TCPServer.new()
	for p in range(from_port, from_port + 40):
		if _tcp.listen(p, "127.0.0.1") == OK:
			port = p
			set_process(true)
			return p
	_tcp = null
	return 0


func stop() -> void:
	drop_all()
	if _tcp != null:
		_tcp.stop()
	_tcp = null


func url() -> String:
	return "ws://127.0.0.1:%d/api/websocket" % port


func set_entity(eid: String, st: String, attrs: Dictionary = {}) -> void:
	entities[eid] = {"state": st, "attributes": attrs}


## Change an entity and tell every subscriber.
func push_state(eid: String, st: String, attrs: Dictionary = {}) -> void:
	var old: Dictionary = entities.get(eid, {})
	if attrs.is_empty():
		attrs = old.get("attributes", {})
	set_entity(eid, st, attrs)
	var ns := _state_dict(eid)
	for c in _clients:
		for sid in c["subs"]:
			_send(c, {"id": sid, "type": "event", "event": {"event_type": "state_changed",
				"data": {"entity_id": eid, "old_state": old, "new_state": ns}}})


func drop_all() -> void:
	for c in _clients:
		(c["ws"] as WebSocketPeer).close()
	_clients.clear()


func _process(_delta: float) -> void:
	if _tcp != null:
		while _tcp.is_connection_available():
			var stream := _tcp.take_connection()
			var ws := WebSocketPeer.new()
			if ws.accept_stream(stream) == OK:
				_clients.append({"ws": ws, "authed": false, "subs": [], "hello": false})
				connections += 1
	for i in range(_clients.size() - 1, -1, -1):
		var c: Dictionary = _clients[i]
		var ws: WebSocketPeer = c["ws"]
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_CLOSED:
			_clients.remove_at(i)
			continue
		if st != WebSocketPeer.STATE_OPEN:
			continue
		if not bool(c["hello"]):
			c["hello"] = true
			if not silent:
				_send(c, {"type": "auth_required", "ha_version": ha_version})
		while ws.get_available_packet_count() > 0:
			var m: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if m is Dictionary:
				_on_message(c, m)


func _on_message(c: Dictionary, m: Dictionary) -> void:
	var t := str(m.get("type", ""))
	var id := int(m.get("id", 0))
	if t == "auth":
		auth_attempts += 1
		if mute_auth:
			return
		if str(m.get("access_token", "")) == token:
			c["authed"] = true
			_send(c, {"type": "auth_ok", "ha_version": ha_version})
		else:
			_send(c, {"type": "auth_invalid", "message": "Invalid access token or password"})
		return
	if not bool(c["authed"]):
		return
	match t:
		"ping":
			_send(c, {"id": id, "type": "pong"})
		"get_states":
			get_states_count += 1
			var arr: Array = []
			for eid in entities.keys():
				arr.append(_state_dict(eid))
			_result(c, id, arr)
		"get_config":
			_result(c, id, {"location_name": location_name, "version": ha_version,
				"unit_system": {"temperature": "°C", "length": "km"}})
		"subscribe_events":
			subscribe_count += 1
			(c["subs"] as Array).append(id)
			_result(c, id, null)
		"call_service":
			service_calls.append({"domain": m.get("domain", ""), "service": m.get("service", ""),
				"target": m.get("target", {}), "service_data": m.get("service_data", {})})
			_result(c, id, {"context": {"id": "fake"}})
		"history/history_during_period":
			var out := {}
			for eid in m.get("entity_ids", []):
				out[str(eid)] = history.get(str(eid), [])
			_result(c, id, out)
		"recorder/statistics_during_period":
			_result(c, id, {})
		_:
			_send(c, {"id": id, "type": "result", "success": false,
				"error": {"code": "unknown_command", "message": "Unknown command."}})


func _state_dict(eid: String) -> Dictionary:
	var e: Dictionary = entities.get(eid, {})
	return {"entity_id": eid, "state": str(e.get("state", "unknown")),
		"attributes": e.get("attributes", {}),
		"last_changed": "2026-10-22T12:00:00+00:00", "last_updated": "2026-10-22T12:00:00+00:00"}


func _result(c: Dictionary, id: int, res: Variant) -> void:
	_send(c, {"id": id, "type": "result", "success": true, "result": res})


func _send(c: Dictionary, msg: Dictionary) -> void:
	var ws: WebSocketPeer = c["ws"]
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(msg))
