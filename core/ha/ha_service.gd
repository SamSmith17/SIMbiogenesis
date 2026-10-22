class_name HomeAssistantService
extends Node
## The ONE Home Assistant connection (autoload "HomeAssistant").
##
## Owns the WebSocket, the saved instances (HaProfiles), the entity catalog and
## the link runtime. The scene's Main/HAClient node is a facade over this
## (power_system/ha/ha_websocket_client.gd) so every node-path consumer —
## SolarUI, the graph's entity linker, the CSV player, scene switches — keeps
## working; new code talks to this autoload.
##
## Why an autoload: the old client lived in each map scene, so there was no
## connection at the launch hub, InverterBridge (which looks once at boot)
## never found it, and a scene change dropped the connection.
##
## Connection, step by step (state_changed carries `info` for the UI):
##   CONNECTING      socket opening, then waiting for HA's "auth_required"
##   AUTHENTICATING  auth sent ON auth_required (never on a timer)
##   CONNECTED       auth_ok; one state_changed subscription, the catalog
##   FAILED          info.reason = an HaFailure constant + words + a fix
## A failed first connect retries only while auto-connect wants this instance;
## a dropped connection always retries, backing off 2 → 60 s; a rejected token
## never retries. After a refusal / timeout the "finder" probes the usual other
## ports (HaUrl.candidates) for an HA that says auth_required — no token sent —
## and offers that address (info.suggestion_url).
##
## Autoload-free on purpose (selftests construct it under --script): other
## autoloads are reached through /root.

signal state_changed(state: int, info: Dictionary)
signal sensor_updated(entity_id: String, state: Dictionary)
signal connection_status_changed(connected: bool)
signal authentication_status_changed(authenticated: bool)
signal initial_states_received()
signal history_statistics_received(statistic_id: String, statistics: Array)
signal raw_history_received(entity_id: String, history: Array)
signal catalog_updated()
signal profiles_changed()

enum State { IDLE, CONNECTING, AUTHENTICATING, CONNECTED, FAILED }

## Timings (vars so the selftest can shorten them).
## Godot's WebSocketPeer never reports a refused port on Windows: the socket
## just stays "connecting" (measured: still connecting after 25 s). So a dead
## address is only ever found by this timer, and the finder starts early.
var connect_timeout_s := 6.0
var early_probe_s := 2.0
var auth_timeout_s := 10.0
var ping_interval_s := 30.0
var pong_timeout_s := 10.0
var backoff_min_s := 2.0
var backoff_max_s := 60.0
var probe_timeout_s := 4.0
const INBOUND_BUFFER := 16 * 1024 * 1024

## Paths: overridable for the selftest.
var profiles_path: String = HaProfiles.PATH
var legacy_path: String = HaProfiles.LEGACY_PATH
## Ports the finder tries on the same host (the selftest points it at a fake).
var probe_ports: Array = HaUrl.DEFAULT_PROBE_PORTS.duplicate()
## Off under the harness (a test run must not reach the player's real HA).
var auto_connect_allowed: bool = true
## Toasts on connect / fail / drop (off in selftests).
var toasts_enabled: bool = true

var state: int = State.IDLE
var _info: Dictionary = {}
## For callers that read the old client's flag by name.
var is_authenticated: bool:
	get:
		return state == State.CONNECTED
	set(_v):
		pass

var _profiles: Dictionary = {}
var _active_profile_id: String = ""
var _url: String = ""            # normalized URL of the current attempt
var _token: String = ""

var _ws: WebSocketPeer = null
var _phase: String = ""          # connecting | handshake | auth | connected
var _attempt_t0_ms: int = 0
var _phase_t0_ms: int = 0
var _was_connected_once: bool = false   # this attempt chain reached CONNECTED
var _auto_retry: bool = false
var _retry_at_ms: int = -1
var _backoff_s: float = 2.0
var _socket_open: bool = false

var _next_id: int = 1
var _pending: Dictionary = {}    # message id -> {kind, ...}
var _ping_due_ms: int = 0
var _pong_wait_id: int = -1
var _pong_deadline_ms: int = 0

var subscribed_entities: Array[String] = []
var _state_sub_id: int = -1

## Coalesced get_states: every entity anyone asked for this frame goes in ONE
## request (the old client sent one full get_states per caller, and a second
## call overwrote the first's filter, so its reply leaked every entity).
var _states_want: Dictionary = {}       # entity_id -> true
var _states_catalog_wanted: bool = false
var _states_flush_queued: bool = false
var _states_inflight_id: int = -1

var _catalog: Dictionary = {}           # entity_id -> entry
var _catalog_unix: int = 0
var _latest: Dictionary = {}            # entity_id -> {value(String), attributes, t_unix}

var _probes: Array = []                 # [{url, peer, t0}]
var _probe_for_url: String = ""

var _scene_profile_id: String = ""
var _last_toast_reason: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_reload_profiles()
	if _under_test_harness():
		auto_connect_allowed = false
	var tree := get_tree()
	if tree != null and tree.has_signal("scene_changed"):
		tree.scene_changed.connect(_on_scene_changed)
	_set_state(State.IDLE, {})


# =============================================================================
# Public API — profiles
# =============================================================================

func profiles() -> Array:
	return (_profiles.get("profiles", []) as Array).duplicate(true)


func profile(id: String) -> Dictionary:
	return HaProfiles.find(_profiles, id).duplicate()


func default_profile_id() -> String:
	return str(_profiles.get("default_id", ""))


func active_profile_id() -> String:
	return _active_profile_id


func auto_connect_enabled() -> bool:
	return bool(_profiles.get("auto_connect", true))


func set_auto_connect(on: bool) -> void:
	_profiles["auto_connect"] = on
	_save_profiles()


func set_default_profile(id: String) -> void:
	if HaProfiles.find(_profiles, id).is_empty():
		return
	_profiles["default_id"] = id
	_save_profiles()


## Save (insert or replace) an instance; returns its id. `id` "" = derive from
## the address (re-adding the same address replaces it).
func save_profile(name: String, url: String, token: String, id: String = "") -> String:
	var p := HaProfiles.make(url, HaToken.clean(token), name.strip_edges())
	if not id.is_empty():
		p["id"] = id
	var old := HaProfiles.find(_profiles, str(p["id"]))
	if not old.is_empty():
		for k in ["last_ok_unix", "ha_version", "location_name"]:
			p[k] = old.get(k, p[k])
		if str(old.get("url", "")) != str(p["url"]):
			p["last_ok_unix"] = 0
	var nid := HaProfiles.upsert(_profiles, p)
	_save_profiles()
	return nid


func delete_profile(id: String) -> void:
	if id == _active_profile_id:
		disconnect_ha()
		_active_profile_id = ""
	HaProfiles.remove(_profiles, id)
	_save_profiles()


## The instance a world uses: its own choice (world.json "ha_profile_id"), else
## the default.
func profile_for_world(rec: Dictionary) -> String:
	var own := str(rec.get("ha_profile_id", ""))
	if not own.is_empty() and not HaProfiles.find(_profiles, own).is_empty():
		return own
	return default_profile_id()


## Legacy "Entity Subscriptions" text from the old settings page (migrated into
## links by the link store).
func legacy_entities_text() -> String:
	return str(_profiles.get("legacy_entities", ""))


# =============================================================================
# Public API — connection
# =============================================================================

func connect_profile(id: String, auto_retry: bool = false) -> bool:
	var p := HaProfiles.find(_profiles, id)
	if p.is_empty():
		_fail(HaFailure.BAD_URL, "That saved instance no longer exists.", "")
		return false
	_active_profile_id = id
	_fresh_chain()
	return _start(str(p.get("url", "")), str(p.get("token", "")), auto_retry)


## Connect with typed values (saved as an instance first when `save`).
func connect_with(url: String, token: String, name: String = "", save: bool = true) -> bool:
	if save:
		var id := save_profile(name, url, token, _profile_id_for_url(url))
		_active_profile_id = id
	_fresh_chain()
	return _start(url, token, false)


## A new attempt chain the player started: forget the old chain's history.
func _fresh_chain() -> void:
	_was_connected_once = false
	_backoff_s = backoff_min_s
	_last_toast_reason = ""


func disconnect_ha() -> void:
	_retry_at_ms = -1
	_auto_retry = false
	_stop_probes()
	_close_socket(true)
	_set_state(State.IDLE, {"title": "Not connected"})


func retry_now() -> void:
	if _url.is_empty():
		if not _active_profile_id.is_empty():
			connect_profile(_active_profile_id, _auto_retry)
		return
	_start(_url, _token, _auto_retry)


func is_ws_open() -> bool:
	return _socket_open


func is_authed() -> bool:
	return state == State.CONNECTED


func info() -> Dictionary:
	return _info.duplicate()


## One line for chips / tooltips.
func status_text() -> String:
	match state:
		State.IDLE:
			return "Not connected"
		State.CONNECTING:
			return "Connecting to %s…" % HaUrl.short(_url)
		State.AUTHENTICATING:
			return "Logging in…"
		State.CONNECTED:
			return "Connected to %s" % str(_info.get("profile_name", HaUrl.short(_url)))
		State.FAILED:
			var t := str(_info.get("title", "Could not connect"))
			if _retry_at_ms > 0:
				t += " — retrying in %ds" % maxi(1, int(ceil((_retry_at_ms - Time.get_ticks_msec()) / 1000.0)))
			return t
	return ""


# =============================================================================
# Public API — entities (also what the facade forwards)
# =============================================================================

## Entities whose state_changed events reach sensor_updated (a union across
## every caller; ONE subscription to HA per connection).
func subscribe_to_entities(ids: Array) -> void:
	for id in ids:
		var s := str(id).strip_edges()
		if not s.is_empty() and s not in subscribed_entities:
			subscribed_entities.append(s)
	_ensure_state_subscription()


func unsubscribe_entities(ids: Array) -> void:
	for id in ids:
		subscribed_entities.erase(str(id))


## Current states for `ids` arrive as sensor_updated, then initial_states_received.
func get_entity_states(ids: Array) -> void:
	for id in ids:
		var s := str(id).strip_edges()
		if not s.is_empty():
			_states_want[s] = true
	_queue_states_flush()


func get_single_entity_state(entity_id: String) -> void:
	if entity_id.is_empty():
		return
	# Cached values answer at once; the coalesced fetch refreshes it.
	if _latest.has(entity_id):
		var l: Dictionary = _latest[entity_id]
		sensor_updated.emit.call_deferred(entity_id, {"entity_id": entity_id,
			"state": l.get("value", ""), "attributes": l.get("attributes", {})})
	get_entity_states([entity_id])


## Full entity list (the picker). catalog_updated fires when it lands.
func refresh_catalog() -> void:
	_states_catalog_wanted = true
	_queue_states_flush()


func catalog() -> Array:
	var out: Array = _catalog.values()
	out.sort_custom(func(a, b): return str(a["entity_id"]) < str(b["entity_id"]))
	return out


func catalog_entry(entity_id: String) -> Dictionary:
	return _catalog.get(entity_id, {})


func catalog_size() -> int:
	return _catalog.size()


## Latest raw state we saw for an entity: {value, attributes, t_unix} or {}.
func latest(entity_id: String) -> Dictionary:
	return _latest.get(entity_id, {})


## Gated like the old client: in SIMULATE / PLAYBACK a sim event must never
## flip a real switch. `force` = a direct player action (the load calibrator).
func call_service(domain: String, service: String, entity_id: String,
		service_data: Dictionary = {}, force: bool = false) -> void:
	if not force:
		var sm := _autoload("SimMode")
		if sm != null and sm.has_method("should_run_realworld_actions") \
				and not bool(sm.call("should_run_realworld_actions")):
			print("[HA] Suppressed %s.%s on %s (not live)" % [domain, service, entity_id])
			return
	if not is_authed():
		print("[HA] %s.%s on %s not sent: not connected" % [domain, service, entity_id])
		return
	_send({"type": "call_service", "domain": domain, "service": service,
		"target": {"entity_id": entity_id}, "service_data": service_data}, {"kind": "service"})


func call_service_no_target(domain: String, service: String, service_data: Dictionary = {}) -> void:
	if not is_authed():
		return
	_send({"type": "call_service", "domain": domain, "service": service,
		"service_data": service_data}, {"kind": "service"})


func get_history_statistics(statistic_id: String, start_time: String, end_time: String, period: String = "hour") -> void:
	if statistic_id.is_empty():
		return
	_send({"type": "recorder/statistics_during_period", "start_time": start_time,
		"end_time": end_time, "statistic_ids": [statistic_id], "period": period},
		{"kind": "stats", "id": statistic_id})


func get_entity_history(entity_id: String, start_time: String, end_time: String, minimal_response: bool = true) -> void:
	if entity_id.is_empty():
		return
	_send({"type": "history/history_during_period", "start_time": start_time,
		"end_time": end_time, "entity_ids": [entity_id], "minimal_response": minimal_response,
		"no_attributes": true, "significant_changes_only": true},
		{"kind": "history", "id": entity_id})


# =============================================================================
# Link summary (pushed by the open world's HAEntityLinker)
# =============================================================================

var _link_summary: Dictionary = {}

func set_link_summary(d: Dictionary) -> void:
	if d == _link_summary:
		return
	_link_summary = d.duplicate()
	_set_state(state, {})


func live_link_count() -> int:
	return int(_link_summary.get("live", 0)) if state == State.CONNECTED else 0


func links_summary_text() -> String:
	var total := int(_link_summary.get("total", 0))
	if total == 0:
		return ""
	var parts: Array = [UiText.count(total, "link") + " in this world"]
	if state == State.CONNECTED:
		parts.append("%d live" % int(_link_summary.get("live", 0)))
		if int(_link_summary.get("stale", 0)) > 0:
			parts.append("%d waiting for a reading" % int(_link_summary["stale"]))
		if int(_link_summary.get("warn", 0)) > 0:
			parts.append("%d with a unit problem" % int(_link_summary["warn"]))
	else:
		parts.append("not connected")
	return " · ".join(parts)


# =============================================================================
# Attempt lifecycle
# =============================================================================

func _start(url: String, token: String, auto_retry: bool) -> bool:
	_retry_at_ms = -1
	_stop_probes()
	_probe_for_url = ""
	_close_socket(false)
	_auto_retry = auto_retry
	var n := HaUrl.normalize(url)
	_info = _base_info()
	if not bool(n.get("ok", false)):
		_url = url
		_fail(HaFailure.BAD_URL, str(n.get("error", "")), url)
		return false
	_url = str(n["url"])
	_token = HaToken.clean(token)
	_info["url"] = _url
	_info["address_ok"] = true
	var tc := HaToken.check(_token)
	if not bool(tc.get("ok", false)):
		_fail(HaFailure.BAD_TOKEN, str(tc.get("error", "")), _url)
		return false
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = INBOUND_BUFFER
	_ws.outbound_buffer_size = 1024 * 1024
	_attempt_t0_ms = Time.get_ticks_msec()
	_phase_t0_ms = _attempt_t0_ms
	_phase = "connecting"
	var err := _ws.connect_to_url(_url)
	if err != OK:
		_ws = null
		_fail(HaFailure.BAD_URL, "Godot could not open %s (error %d)." % [_url, err], _url)
		return false
	print("[HA] Connecting to %s" % _url)
	_set_state(State.CONNECTING, {"title": "Connecting to %s…" % HaUrl.short(_url)})
	return true


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _ws != null:
		_poll_socket(now)
	elif _retry_at_ms > 0 and now >= _retry_at_ms:
		_retry_at_ms = -1
		retry_now()
	if not _probes.is_empty():
		_poll_probes(now)


func _poll_socket(now: int) -> void:
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _socket_open:
			_socket_open = true
			if _phase == "connecting":
				_phase = "handshake"
				_phase_t0_ms = now
			connection_status_changed.emit(true)
		while _ws != null and _ws.get_available_packet_count() > 0:
			var pkt := _ws.get_packet()
			if pkt.is_empty():
				continue
			var parsed: Variant = JSON.parse_string(pkt.get_string_from_utf8())
			if parsed is Dictionary:
				_handle(parsed)
			elif parsed is Array:
				# HA may batch messages when coalescing is negotiated.
				for m in parsed:
					if m is Dictionary:
						_handle(m)
		if _ws == null:
			return
		var elapsed := (now - _phase_t0_ms) / 1000.0
		if _phase == "handshake" and elapsed > connect_timeout_s:
			_lose(HaFailure.NOT_HA, "Opened a connection but Home Assistant never asked to log in.", true)
		elif _phase == "auth" and elapsed > auth_timeout_s:
			_lose(HaFailure.AUTH_TIMEOUT, "", true)
		elif _phase == "connected":
			if _pong_wait_id >= 0 and now > _pong_deadline_ms:
				_lose(HaFailure.LOST, "Home Assistant stopped answering.", true)
			elif _pong_wait_id < 0 and now >= _ping_due_ms:
				_pong_wait_id = _send({"type": "ping"}, {"kind": "ping"})
				_pong_deadline_ms = now + int(pong_timeout_s * 1000.0)
	elif st == WebSocketPeer.STATE_CLOSED:
		var elapsed_attempt := (now - _attempt_t0_ms) / 1000.0
		var reason := HaFailure.classify(_phase, elapsed_attempt, false, _url.begins_with("wss"))
		var code := _ws.get_close_code()
		var why := _ws.get_close_reason()
		var detail := ""
		if code > 0:
			detail = "Closed with code %d%s." % [code, (" (%s)" % why) if not why.is_empty() else ""]
		_lose(reason, detail, false)
	elif st == WebSocketPeer.STATE_CONNECTING:
		var waited := (now - _attempt_t0_ms) / 1000.0
		if waited > connect_timeout_s:
			_lose(HaFailure.UNREACHABLE, "", true)
		elif waited > early_probe_s and _probe_for_url != _url:
			_start_probes(_url)


## End the attempt (or a live connection) with `reason`.
func _lose(reason: String, detail: String, timed_out: bool) -> void:
	if timed_out and _phase == "connecting":
		reason = HaFailure.UNREACHABLE
	_close_socket(true)
	_fail(reason, detail, _url)


func _fail(reason: String, detail: String, url: String) -> void:
	var d := HaFailure.describe(reason, url, detail)
	var info := {"reason": reason, "title": d["title"], "detail": d["detail"], "fix": d["fix"], "url": url}
	if reason == HaFailure.BAD_URL:
		info["address_ok"] = false
	var retry := HaFailure.retryable(reason) and (reason == HaFailure.LOST or _was_connected_once or _auto_retry)
	if retry:
		_retry_at_ms = Time.get_ticks_msec() + int(_backoff_s * 1000.0)
		info["retry_in_s"] = _backoff_s
		_backoff_s = minf(_backoff_s * 2.0, backoff_max_s)
	print("[HA] %s: %s%s" % [reason, d["title"], ("" if detail.is_empty() else " — " + detail)])
	_set_state(State.FAILED, info)
	if reason in [HaFailure.REFUSED, HaFailure.UNREACHABLE, HaFailure.NOT_HA]:
		_start_probes(url)
	_toast_failure(reason, str(d["title"]))


func _close_socket(emit_signals: bool) -> void:
	var was_open := _socket_open
	var was_auth := state == State.CONNECTED
	if _ws != null:
		_ws.close()
	_ws = null
	_socket_open = false
	_phase = ""
	_pending.clear()
	_state_sub_id = -1
	_states_inflight_id = -1
	_pong_wait_id = -1
	if emit_signals:
		if was_open:
			connection_status_changed.emit(false)
		if was_auth:
			authentication_status_changed.emit(false)


# =============================================================================
# Messages
# =============================================================================

func _send(msg: Dictionary, pending: Dictionary = {}) -> int:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return -1
	var id := -1
	if msg.get("type", "") != "auth":
		id = _next_id
		_next_id += 1
		msg["id"] = id
		if not pending.is_empty():
			_pending[id] = pending
	if _ws.send_text(JSON.stringify(msg)) != OK:
		print("[HA] send failed (%s)" % str(msg.get("type", "")))
		_pending.erase(id)
		return -1
	return id


func _handle(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"auth_required":
			_info["reached"] = true
			_info["ha_version"] = str(data.get("ha_version", ""))
			_phase = "auth"
			_phase_t0_ms = Time.get_ticks_msec()
			_send({"type": "auth", "access_token": _token})
			_set_state(State.AUTHENTICATING, {"title": "Logging in…"})
		"auth_ok":
			_on_auth_ok(data)
		"auth_invalid":
			_lose(HaFailure.AUTH_INVALID, str(data.get("message", "")), false)
			authentication_status_changed.emit(false)
		"pong":
			if int(data.get("id", -1)) == _pong_wait_id:
				_pong_wait_id = -1
				_ping_due_ms = Time.get_ticks_msec() + int(ping_interval_s * 1000.0)
		"event":
			_handle_event(data)
		"result":
			_handle_result(data)


func _on_auth_ok(data: Dictionary) -> void:
	_phase = "connected"
	_backoff_s = backoff_min_s
	_last_toast_reason = ""
	_was_connected_once = true
	_ping_due_ms = Time.get_ticks_msec() + int(ping_interval_s * 1000.0)
	if not str(data.get("ha_version", "")).is_empty():
		_info["ha_version"] = str(data["ha_version"])
	_info["authed"] = true
	_info["connected_since_unix"] = int(Time.get_unix_time_from_system())
	_record_profile_success()
	print("[HA] Connected to %s (Home Assistant %s)" % [_url, _info.get("ha_version", "?")])
	_set_state(State.CONNECTED, {"title": "Connected"})
	authentication_status_changed.emit(true)
	_ensure_state_subscription()
	_send({"type": "get_config"}, {"kind": "config"})
	refresh_catalog()
	if not subscribed_entities.is_empty():
		get_entity_states(subscribed_entities)
	if toasts_enabled:
		_toast("Home Assistant connected: %s" % str(_info.get("profile_name", HaUrl.short(_url))), 1)


func _ensure_state_subscription() -> void:
	if not is_authed() or _state_sub_id >= 0:
		return
	_state_sub_id = _send({"type": "subscribe_events", "event_type": "state_changed"}, {"kind": "subscribe"})


func _handle_event(data: Dictionary) -> void:
	var ev: Dictionary = data.get("event", {}) if data.get("event", {}) is Dictionary else {}
	if str(ev.get("event_type", "")) != "state_changed":
		return
	var d: Dictionary = ev.get("data", {}) if ev.get("data", {}) is Dictionary else {}
	var eid := str(d.get("entity_id", ""))
	if eid.is_empty():
		return
	var ns: Variant = d.get("new_state", null)
	if not (ns is Dictionary):
		# Entity removed: drop it from the catalog, tell nobody.
		_catalog.erase(eid)
		_latest.erase(eid)
		return
	_take_state(ns, true)


## One entity state dict from HA (get_states row or state_changed new_state).
func _take_state(st: Dictionary, emit_if_subscribed: bool) -> void:
	var eid := str(st.get("entity_id", ""))
	if eid.is_empty():
		return
	var attrs: Dictionary = st.get("attributes", {}) if st.get("attributes", {}) is Dictionary else {}
	_latest[eid] = {"value": str(st.get("state", "")), "attributes": attrs,
		"t_unix": int(Time.get_unix_time_from_system())}
	if _catalog.has(eid):
		(_catalog[eid] as Dictionary)["state"] = str(st.get("state", ""))
	else:
		_catalog[eid] = catalog_row(st)
	if emit_if_subscribed and eid in subscribed_entities:
		sensor_updated.emit(eid, st)


## A picker row from an HA state dict (pure).
static func catalog_row(st: Dictionary) -> Dictionary:
	var eid := str(st.get("entity_id", ""))
	var attrs: Dictionary = st.get("attributes", {}) if st.get("attributes", {}) is Dictionary else {}
	var dot := eid.find(".")
	return {
		"entity_id": eid,
		"name": str(attrs.get("friendly_name", eid)),
		"domain": eid.substr(0, dot) if dot > 0 else "",
		"device_class": str(attrs.get("device_class", "")),
		"unit": str(attrs.get("unit_of_measurement", "")),
		"state_class": str(attrs.get("state_class", "")),
		"state": str(st.get("state", "")),
	}


func _handle_result(data: Dictionary) -> void:
	var id := int(data.get("id", -1))
	if not _pending.has(id):
		return
	var p: Dictionary = _pending[id]
	_pending.erase(id)
	var ok := bool(data.get("success", true))
	var res: Variant = data.get("result", null)
	match str(p.get("kind", "")):
		"states":
			_on_states_result(p, ok, res)
		"config":
			if ok and res is Dictionary:
				_info["location_name"] = str(res.get("location_name", ""))
				if not str(res.get("version", "")).is_empty():
					_info["ha_version"] = str(res["version"])
				_record_profile_success()
				_set_state(state, {})
		"stats":
			var sid := str(p.get("id", ""))
			var arr: Array = []
			if ok and res is Dictionary:
				var v: Variant = res.get(sid, null)
				if v == null:
					for k in res.keys():
						if sid in str(k) or str(k) in sid:
							v = res[k]
							break
				if v is Array:
					arr = v
			history_statistics_received.emit(sid, arr)
		"history":
			var eid := str(p.get("id", ""))
			var harr: Array = []
			if ok and res is Dictionary and res.get(eid, []) is Array:
				harr = res.get(eid, [])
			raw_history_received.emit(eid, harr)
		"subscribe":
			if not ok:
				_state_sub_id = -1
				print("[HA] state_changed subscription refused: %s" % str(data.get("error", {})))
		"service":
			if not ok:
				var err: Dictionary = data.get("error", {}) if data.get("error", {}) is Dictionary else {}
				print("[HA] service call refused: %s" % str(err.get("message", err)))
				if toasts_enabled:
					_toast("Home Assistant refused an action: %s" % str(err.get("message", "error")), 2)


func _queue_states_flush() -> void:
	if _states_flush_queued:
		return
	_states_flush_queued = true
	_flush_states.call_deferred()


func _flush_states() -> void:
	_states_flush_queued = false
	if not is_authed() or _states_inflight_id >= 0:
		return   # sent on auth_ok / after the in-flight one lands
	if _states_want.is_empty() and not _states_catalog_wanted:
		return
	var want := _states_want.duplicate()
	_states_want.clear()
	var cat := _states_catalog_wanted
	_states_catalog_wanted = false
	_states_inflight_id = _send({"type": "get_states"}, {"kind": "states", "want": want, "catalog": cat})


func _on_states_result(p: Dictionary, ok: bool, res: Variant) -> void:
	_states_inflight_id = -1
	var want: Dictionary = p.get("want", {})
	if ok and res is Array:
		_catalog.clear()
		for st in res:
			if st is Dictionary:
				_take_state(st, false)
				var eid := str(st.get("entity_id", ""))
				if want.has(eid):
					sensor_updated.emit(eid, st)
		_catalog_unix = int(Time.get_unix_time_from_system())
		_info["entity_count"] = _catalog.size()
		_set_state(state, {})
		catalog_updated.emit()
	if not want.is_empty():
		initial_states_received.emit()
	if not _states_want.is_empty() or _states_catalog_wanted:
		_queue_states_flush()


# =============================================================================
# Finder: is HA answering somewhere else on the same host?
# =============================================================================

func _start_probes(url: String) -> void:
	if url == _probe_for_url:
		return
	_stop_probes()
	_probe_for_url = url
	var now := Time.get_ticks_msec()
	for cand in HaUrl.candidates(url, probe_ports):
		var peer := WebSocketPeer.new()
		if peer.connect_to_url(str(cand)) == OK:
			_probes.append({"url": str(cand), "peer": peer, "t0": now})
	if not _probes.is_empty():
		_info["finding"] = true
		_set_state(state, {})


func _poll_probes(now: int) -> void:
	for i in range(_probes.size() - 1, -1, -1):
		var pr: Dictionary = _probes[i]
		var peer: WebSocketPeer = pr["peer"]
		peer.poll()
		var st := peer.get_ready_state()
		var done := false
		if st == WebSocketPeer.STATE_OPEN:
			while peer.get_available_packet_count() > 0:
				var m: Variant = JSON.parse_string(peer.get_packet().get_string_from_utf8())
				if m is Dictionary and str(m.get("type", "")) == "auth_required":
					_on_probe_found(str(pr["url"]), str(m.get("ha_version", "")))
					return
			done = (now - int(pr["t0"])) / 1000.0 > probe_timeout_s
		elif st == WebSocketPeer.STATE_CLOSED:
			done = true
		elif (now - int(pr["t0"])) / 1000.0 > probe_timeout_s:
			done = true
		if done:
			peer.close()
			_probes.remove_at(i)
	if _probes.is_empty() and bool(_info.get("finding", false)):
		_info.erase("finding")
		_set_state(state, {})


func _on_probe_found(url: String, version: String) -> void:
	_stop_probes()
	_info.erase("finding")
	_info["suggestion_url"] = url
	_info["suggestion_version"] = version
	print("[HA] Home Assistant answers at %s" % url)
	_set_state(state, {})


func _stop_probes() -> void:
	for pr in _probes:
		(pr["peer"] as WebSocketPeer).close()
	_probes.clear()


## "Use this address": save it on the active instance and connect.
func use_suggestion() -> bool:
	var s := str(_info.get("suggestion_url", ""))
	if s.is_empty():
		return false
	if not _active_profile_id.is_empty():
		var p := HaProfiles.find(_profiles, _active_profile_id)
		if not p.is_empty():
			p["url"] = s
			p["last_ok_unix"] = 0
			HaProfiles.upsert(_profiles, p)
			_save_profiles()
	return _start(s, _token, _auto_retry)


# =============================================================================
# Auto-connect per world
# =============================================================================

func _on_scene_changed() -> void:
	_auto_connect_for_scene.call_deferred()


func _auto_connect_for_scene() -> void:
	if not auto_connect_allowed or not auto_connect_enabled():
		return
	var ws := _world_record()
	if ws.is_empty() and not _scene_is_world():
		return
	var id := profile_for_world(ws)
	if id.is_empty():
		return
	var p := HaProfiles.find(_profiles, id)
	if p.is_empty() or int(p.get("last_ok_unix", 0)) <= 0:
		return   # never worked: wait for the player to press Connect
	if id == _active_profile_id and state in [State.CONNECTING, State.AUTHENTICATING, State.CONNECTED]:
		return
	_scene_profile_id = id
	connect_profile(id, true)


func _world_record() -> Dictionary:
	var wid := WorldPaths.active_world_id()
	if wid.is_empty():
		return {}
	return WorldStore.get_world(wid)


func _scene_is_world() -> bool:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return false
	return tree.current_scene.has_method("get_lunar_phase")


## Set (or clear with "") the instance the ACTIVE world uses.
func set_world_profile(id: String) -> bool:
	var wid := WorldPaths.active_world_id()
	if wid.is_empty():
		return false
	var rec := WorldStore.get_world(wid)
	if rec.is_empty():
		return false
	if id.is_empty():
		rec.erase("ha_profile_id")
	else:
		rec["ha_profile_id"] = id
	return WorldStore.save_record(rec)


func world_profile_id() -> String:
	return str(_world_record().get("ha_profile_id", ""))


# =============================================================================
# Helpers
# =============================================================================

func _set_state(s: int, extra: Dictionary) -> void:
	state = s
	for k in extra.keys():
		_info[k] = extra[k]
	_info["state"] = s
	_info["profile_id"] = _active_profile_id
	var p := HaProfiles.find(_profiles, _active_profile_id)
	_info["profile_name"] = HaProfiles.label(p) if not p.is_empty() else HaUrl.short(_url)
	if s == State.CONNECTED:
		_info.erase("reason")
		_info.erase("retry_in_s")
		_info.erase("suggestion_url")
	state_changed.emit(s, _info.duplicate())


func _base_info() -> Dictionary:
	return {"address_ok": false, "reached": false, "authed": false, "entity_count": 0}


func _record_profile_success() -> void:
	var p := HaProfiles.find(_profiles, _active_profile_id)
	if p.is_empty():
		return
	p["last_ok_unix"] = int(Time.get_unix_time_from_system())
	p["url"] = _url
	if not str(_info.get("ha_version", "")).is_empty():
		p["ha_version"] = str(_info["ha_version"])
	if not str(_info.get("location_name", "")).is_empty():
		p["location_name"] = str(_info["location_name"])
	HaProfiles.upsert(_profiles, p)
	_save_profiles()


func _profile_id_for_url(url: String) -> String:
	var n := HaUrl.normalize(url)
	if not bool(n.get("ok", false)):
		return ""
	for p in _profiles.get("profiles", []):
		var pn := HaUrl.normalize(str(p.get("url", "")))
		if bool(pn.get("ok", false)) and str(pn["url"]) == str(n["url"]):
			return str(p["id"])
	# Editing the active instance's address keeps its identity.
	return _active_profile_id


func _reload_profiles() -> void:
	_profiles = HaProfiles.load_all(profiles_path, legacy_path)
	if _active_profile_id.is_empty():
		_active_profile_id = str(_profiles.get("default_id", ""))
	profiles_changed.emit()


## Reload after the selftest changed the paths.
func reload_profiles() -> void:
	_reload_profiles()


func _save_profiles() -> void:
	HaProfiles.save_all(_profiles, profiles_path)
	profiles_changed.emit()


func _autoload(n: String) -> Node:
	var ml := Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null(n)
	return null


func _toast(text: String, level: int) -> void:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	if tree.current_scene.has_method("show_toast"):
		tree.current_scene.call("show_toast", text, level, 5.0)


func _toast_failure(reason: String, title: String) -> void:
	if not toasts_enabled:
		return
	# A retry loop must not toast every 2-60 s: once per reason per chain.
	if reason == _last_toast_reason:
		return
	_last_toast_reason = reason
	_toast("Home Assistant: %s" % title, 3 if reason != HaFailure.LOST else 2)


static func _under_test_harness() -> bool:
	var args := OS.get_cmdline_user_args()
	if args.has("--ha-autoconnect"):
		return false
	for a in args:
		var s := str(a)
		if s.begins_with("--capture") or s.begins_with("--run-script") or s.begins_with("--sculpt-test"):
			return true
	return false
