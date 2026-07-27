extends Node

## Phase 2–6 listen-server co-presence: host/join, remote avatars, host clock,
## design share/live sync, session chat, and private-beta hardening (Phase 6).

signal session_changed()
signal peer_list_changed()
signal lan_hosts_changed()
signal status_message(text: String, level: String)

const MpJoinCodeScript := preload("res://core/multiplayer/mp_join_code.gd")
const RemoteAvatarScript := preload("res://core/multiplayer/remote_player_avatar.gd")
const MapDefinitionScript := preload("res://maps/map_definition.gd")
const DesignControllerScript := preload("res://core/multiplayer/mp_design_controller.gd")
const ChatControllerScript := preload("res://core/multiplayer/mp_chat_controller.gd")
const MpHardeningScript := preload("res://core/multiplayer/mp_hardening.gd")

const DEFAULT_PORT := 34197
const LAN_DISCOVERY_PORT := 34198
const MAX_PEERS := 10
## Bumped in Phase 6 (hello dict, join-code v2, hardening fields).
const PROTOCOL_VERSION := 2
const PREFS_PATH := "user://mp_prefs.cfg"
const PRESENCE_HZ := 12.0
const CLOCK_HZ := 2.0
const LAN_BROADCAST_HZ := 0.5
const CLOCK_SNAP_HOURS := 0.002  # ~7 s of sim time
## Max distance (m) for 3D proximity chat bubbles above remote avatars.
const CHAT_BUBBLE_RANGE_M := 45.0
const DEFAULT_CODE_TTL_SEC := 4 * 3600

enum Role { NONE, HOST, CLIENT }

var role: int = Role.NONE
var display_name: String = "Player"
var session_token: String = ""
var join_code: String = ""
var host_port: int = DEFAULT_PORT
var host_address: String = ""
var session_name: String = "SIMbiogenesis"
## Host-side session settings (Phase 6).
var session_expires_unix: int = 0
var code_ttl_sec: int = DEFAULT_CODE_TTL_SEC
var host_password_hash: String = ""
## Plain host password kept only in host memory so join-code refresh can re-hash.
var _host_password_plain: String = ""
var require_trusted: bool = false
var trusted_keys: PackedStringArray = PackedStringArray()
## Client credentials used on the next hello.
var pending_password: String = ""
var pending_friend_key: String = ""

## peer_id -> {name, ready}
var peers: Dictionary = {}
## Discovered LAN hosts: [{ip, port, name, code, token, map}]
var lan_hosts: Array = []

var _pending_join: Dictionary = {}
var _avatars: Dictionary = {}  # peer_id -> RemotePlayerAvatar
var _presence_accum := 0.0
var _clock_accum := 0.0
var _lan_accum := 0.0
var _udp_broadcast: PacketPeerUDP = null
var _udp_listen: PacketPeerUDP = null
var _lan_listen_enabled := false
var _awaiting_map_load := false
var _clock_sync_guard := false
var _remote_root: Node3D = null
## Phase 3–4 design collaboration (child node so RPCs share a stable path).
var design: Node = null
## Phase 5 session chat.
var chat: Node = null
## Phase 6 per-peer rate buckets (peer_id -> {t, c}).
var _rate_buckets: Dictionary = {}


func _ready() -> void:
	display_name = _load_display_name()
	design = DesignControllerScript.new()
	design.name = "Design"
	add_child(design)
	chat = ChatControllerScript.new()
	chat.name = "Chat"
	add_child(chat)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	get_tree().scene_changed.connect(_on_scene_changed)
	set_process(true)


func _process(delta: float) -> void:
	_poll_lan_packets()
	if role == Role.NONE:
		return
	_presence_accum += delta
	if _presence_accum >= 1.0 / PRESENCE_HZ:
		_presence_accum = 0.0
		_send_local_presence()
	if role == Role.HOST:
		_clock_accum += delta
		if _clock_accum >= 1.0 / CLOCK_HZ:
			_clock_accum = 0.0
			_broadcast_clock()
		_lan_accum += delta
		if _lan_accum >= 1.0 / LAN_BROADCAST_HZ:
			_lan_accum = 0.0
			_broadcast_lan_beacon()


func is_active() -> bool:
	return role != Role.NONE and multiplayer.multiplayer_peer != null


func is_host() -> bool:
	return role == Role.HOST


func is_joining() -> bool:
	return not _pending_join.is_empty() or _awaiting_map_load


func peer_count() -> int:
	return peers.size()


func status_label() -> String:
	if not is_active():
		return "Multiplayer"
	var n := maxi(peers.size(), 1)
	if role == Role.HOST:
		return "HOST · %d" % n
	return "JOINED · %d" % n


func set_display_name(name_: String) -> void:
	display_name = name_.strip_edges()
	if display_name.is_empty():
		display_name = "Player"
	_save_display_name(display_name)
	if is_active():
		var my_id := multiplayer.get_unique_id()
		peers[my_id] = {"name": display_name, "ready": true}
		rpc_peer_info.rpc(my_id, display_name, true)
		peer_list_changed.emit()
		session_changed.emit()


# ── Host / Join / Leave ──────────────────────────────────────────────────────

func host_session(port: int = DEFAULT_PORT, p_session_name: String = "",
		opts: Dictionary = {}) -> Dictionary:
	if is_active():
		return {"ok": false, "error": "Already in a session — leave first"}
	leave_session(false)
	host_port = clampi(port, 1024, 65535)
	session_name = p_session_name.strip_edges()
	if session_name.is_empty():
		session_name = "SIMbiogenesis"
	code_ttl_sec = clampi(int(opts.get("ttl_sec", code_ttl_sec)), 60, 7 * 24 * 3600)
	_host_password_plain = str(opts.get("password", "")).strip_edges()
	session_token = _mint_token()
	host_password_hash = MpHardeningScript.hash_password(_host_password_plain, session_token) \
			if not _host_password_plain.is_empty() else ""
	if opts.has("trusted_keys"):
		trusted_keys = MpHardeningScript.parse_trusted_keys(str(opts.get("trusted_keys", "")))
	elif opts.get("trusted_keys_array") is PackedStringArray:
		trusted_keys = opts.get("trusted_keys_array") as PackedStringArray
	require_trusted = bool(opts.get("require_trusted", false)) and not trusted_keys.is_empty()
	session_expires_unix = MpHardeningScript.expiry_unix(code_ttl_sec)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(host_port, MAX_PEERS - 1)
	if err != OK:
		return {"ok": false, "error": "Could not bind port %d (err %d)" % [host_port, err]}
	multiplayer.multiplayer_peer = peer
	role = Role.HOST
	host_address = pick_lan_ipv4()
	peers.clear()
	_rate_buckets.clear()
	peers[1] = {"name": display_name, "ready": true}
	_refresh_join_code()
	_start_lan_broadcast()
	_ensure_remote_root()
	_wire_map_load_signal()
	if design != null and design.has_method("on_session_started"):
		design.call("on_session_started")
	if chat != null and chat.has_method("push_system"):
		chat.call("push_system", "Hosting — press Enter to chat · Discord for voice")
	MpHardeningScript.log_event("host_start", {
		"port": host_port,
		"has_pw": not host_password_hash.is_empty(),
		"require_trusted": require_trusted,
		"trusted_n": trusted_keys.size(),
		"ttl_sec": code_ttl_sec,
	})
	_emit_status("Hosting on %s:%d" % [host_address, host_port], "ok")
	session_changed.emit()
	peer_list_changed.emit()
	return {
		"ok": true,
		"port": host_port,
		"address": host_address,
		"join_code": join_code,
		"token": session_token,
		"exp": session_expires_unix,
	}


func join_with_code(code: String) -> Dictionary:
	var decoded: Dictionary = MpJoinCodeScript.decode(code)
	if not bool(decoded.get("ok", false)):
		return decoded
	return join_decoded(decoded)


func join_decoded(decoded: Dictionary) -> Dictionary:
	if is_active():
		return {"ok": false, "error": "Already in a session — leave first"}
	leave_session(false)
	_pending_join = decoded.duplicate(true)
	var map_info: Dictionary = decoded.get("map", {}) as Dictionary
	if _map_needs_switch(map_info):
		_awaiting_map_load = true
		_begin_map_switch(map_info)
		_emit_status("Loading host map…", "info")
		session_changed.emit()
		return {"ok": true, "loading_map": true, "pending": true}
	return _connect_pending()


func leave_session(announce: bool = true) -> void:
	var was_active := is_active()
	_stop_lan_broadcast()
	_clear_avatars()
	if design != null and design.has_method("clear_session_state"):
		design.call("clear_session_state")
	if chat != null and chat.has_method("clear_session_state"):
		chat.call("clear_session_state")
	_pending_join.clear()
	_awaiting_map_load = false
	join_code = ""
	session_token = ""
	host_address = ""
	session_expires_unix = 0
	host_password_hash = ""
	_host_password_plain = ""
	pending_password = ""
	pending_friend_key = ""
	_rate_buckets.clear()
	peers.clear()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	role = Role.NONE
	if was_active:
		MpHardeningScript.log_event("session_leave", {})
	if announce:
		_emit_status("Left multiplayer session", "info")
	session_changed.emit()
	peer_list_changed.emit()


func set_join_credentials(password: String = "", friend_key: String = "") -> void:
	pending_password = password.strip_edges()
	pending_friend_key = friend_key.strip_edges()


func set_host_security(password: String, trusted_text: String, require: bool,
		ttl_sec: int = -1) -> void:
	## Apply before hosting, or while hosting (updates password/allowlist + join code).
	if ttl_sec > 0:
		code_ttl_sec = clampi(ttl_sec, 60, 7 * 24 * 3600)
	trusted_keys = MpHardeningScript.parse_trusted_keys(trusted_text)
	require_trusted = require and not trusted_keys.is_empty()
	_host_password_plain = password.strip_edges()
	if role == Role.HOST:
		host_password_hash = MpHardeningScript.hash_password(_host_password_plain, session_token) \
				if not _host_password_plain.is_empty() else ""
		session_expires_unix = MpHardeningScript.expiry_unix(code_ttl_sec)
		_refresh_join_code()
		session_changed.emit()


func mint_trusted_key() -> String:
	var key := MpHardeningScript.mint_friend_key()
	var keys: PackedStringArray = trusted_keys.duplicate()
	keys.append(MpHardeningScript.normalize_trusted_key(key))
	trusted_keys = keys
	require_trusted = true
	if role == Role.HOST:
		_refresh_join_code()
		session_changed.emit()
	return key


func refresh_join_code() -> Dictionary:
	## Remint token + expiry so old codes stop working.
	if role != Role.HOST:
		return {"ok": false, "error": "Only the host can refresh the join code"}
	session_token = _mint_token()
	session_expires_unix = MpHardeningScript.expiry_unix(code_ttl_sec)
	host_password_hash = MpHardeningScript.hash_password(_host_password_plain, session_token) \
			if not _host_password_plain.is_empty() else ""
	_refresh_join_code()
	MpHardeningScript.log_event("join_code_refresh", {"exp": session_expires_unix})
	session_changed.emit()
	return {"ok": true, "join_code": join_code, "exp": session_expires_unix}


func has_host_password() -> bool:
	return not host_password_hash.is_empty()


func note_peer_traffic(peer_id: int, cost: int) -> bool:
	## Returns false if the peer was disconnected for abuse.
	if role != Role.HOST or peer_id <= 1:
		return true
	var result: Dictionary = MpHardeningScript.rate_note(_rate_buckets, peer_id, cost)
	if bool(result.get("ok", true)):
		return true
	MpHardeningScript.log_event("peer_rate_kick", {
		"peer_id": peer_id,
		"cost": int(result.get("cost_total", 0)),
	})
	_emit_status("Kicked peer %d — abusive packet rate" % peer_id, "warn")
	_disconnect_peer(peer_id)
	return false


func log_telemetry(kind: String, detail: Dictionary = {}) -> void:
	MpHardeningScript.log_event(kind, detail)


# ── Phase 5 chat API ─────────────────────────────────────────────────────────

func send_chat(text: String) -> Dictionary:
	if chat == null:
		return {"ok": false, "error": "Chat missing"}
	return chat.call("send_chat", text)


func mute_peer(peer_id: int, muted: bool = true) -> void:
	if chat != null:
		chat.call("mute_peer", peer_id, muted)


func is_peer_muted(peer_id: int) -> bool:
	if chat == null:
		return false
	return bool(chat.call("is_muted", peer_id))


func set_discord_url(url: String) -> void:
	if chat != null:
		chat.call("set_discord_url", url)


func get_discord_url() -> String:
	if chat == null:
		return ""
	return str(chat.get("discord_url"))


func open_discord() -> Dictionary:
	if chat == null:
		return {"ok": false, "error": "Chat missing"}
	return chat.call("open_discord")


func show_peer_chat_bubble(peer_id: int, text: String) -> void:
	var av: RemotePlayerAvatar = _avatars.get(peer_id) as RemotePlayerAvatar
	if av == null or not is_instance_valid(av) or not av.has_method("show_chat_bubble"):
		return
	var local := _local_player_node()
	if local == null:
		av.show_chat_bubble(text)
		return
	if av.global_position.distance_to(local.global_position) <= CHAT_BUBBLE_RANGE_M:
		av.show_chat_bubble(text)


func _local_player_node() -> Node3D:
	var main := _find_main()
	if main == null:
		return null
	return main.get_node_or_null("Player") as Node3D



# ── Phase 3–4 design API (forwarded to Design child) ──────────────────────────

func share_my_design() -> Dictionary:
	if design == null:
		return {"ok": false, "error": "Design controller missing"}
	return design.call("share_my_design")


func preview_design_offer(transfer_id: String) -> Dictionary:
	if design == null:
		return {"ok": false, "error": "Design controller missing"}
	return design.call("preview_offer", transfer_id)


func discard_design_preview() -> void:
	if design != null:
		design.call("discard_preview")


func apply_design_preview(mode: String = "replace") -> Dictionary:
	if design == null:
		return {"ok": false, "error": "Design controller missing"}
	return design.call("apply_pending", mode)


func dismiss_design_offer(transfer_id: String) -> void:
	if design != null:
		design.call("dismiss_offer", transfer_id)


func list_design_offers() -> Array:
	if design == null:
		return []
	return design.call("list_offers")


func set_live_design_sync(on: bool) -> void:
	if design != null:
		design.call("set_live_sync_enabled", on)


func is_live_design_sync() -> bool:
	if design == null:
		return false
	return bool(design.get("live_sync_enabled"))


func notify_graph_edited(reason: String = "") -> void:
	if design != null and design.has_method("notify_graph_edited"):
		design.call("notify_graph_edited", reason)


func notify_props_edited() -> void:
	if design != null and design.has_method("notify_props_edited"):
		design.call("notify_props_edited")


func start_lan_listen(enabled: bool = true) -> void:
	_lan_listen_enabled = enabled
	if not enabled:
		if _udp_listen != null:
			_udp_listen.close()
			_udp_listen = null
		lan_hosts.clear()
		lan_hosts_changed.emit()
		return
	if _udp_listen != null:
		return
	_udp_listen = PacketPeerUDP.new()
	var err := _udp_listen.bind(LAN_DISCOVERY_PORT)
	if err != OK:
		_udp_listen = null
		_emit_status("LAN discovery bind failed (%d)" % err, "warn")
		return
	_udp_listen.set_broadcast_enabled(true)


func copy_join_code_to_clipboard() -> bool:
	if join_code.is_empty():
		return false
	DisplayServer.clipboard_set(join_code)
	_emit_status("Join code copied", "ok")
	return true


# ── Map identity ─────────────────────────────────────────────────────────────

func collect_map_info() -> Dictionary:
	var main := _find_main()
	if main == null:
		return {}
	var info := {
		"kind": "scene",
		"scene_path": str(main.get_tree().current_scene.scene_file_path) if main.get_tree() != null and main.get_tree().current_scene != null else "",
		"latitude": float(main.get("latitude")),
		"longitude": float(main.get("longitude")),
		"label": "",
		"half_extent_m": 0.0,
		"detail_half_extent_m": 0.0,
		"osm_half_extent_m": 0.0,
	}
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and loader.has_method("get_terrain_extents"):
		var ext: Dictionary = loader.call("get_terrain_extents")
		info["half_extent_m"] = float(ext.get("half_extent_m", 0.0))
		info["detail_half_extent_m"] = float(ext.get("detail_half_extent_m", 0.0))
		info["osm_half_extent_m"] = float(ext.get("osm_half_extent_m", 0.0))
		info["kind"] = "generated"
	var scene_path := str(info.get("scene_path", ""))
	if scene_path.contains("generated_location"):
		info["kind"] = "generated"
	return info


func _refresh_join_code() -> void:
	if session_expires_unix <= 0:
		session_expires_unix = MpHardeningScript.expiry_unix(code_ttl_sec)
	var enc: Dictionary = MpJoinCodeScript.encode({
		"ip": host_address if not host_address.is_empty() else pick_lan_ipv4(),
		"port": host_port,
		"token": session_token,
		"name": session_name,
		"map": collect_map_info(),
		"exp": session_expires_unix,
		"has_pw": not host_password_hash.is_empty(),
	})
	join_code = str(enc.get("code", "")) if bool(enc.get("ok", false)) else ""


func _map_needs_switch(map_info: Dictionary) -> bool:
	if map_info.is_empty():
		return false
	var main := _find_main()
	if main == null:
		return true
	var kind := str(map_info.get("kind", "generated"))
	if kind == "generated" or map_info.has("latitude"):
		var lat := float(map_info.get("latitude", 0.0))
		var lon := float(map_info.get("longitude", 0.0))
		var dlat := absf(float(main.get("latitude")) - lat)
		var dlon := absf(float(main.get("longitude")) - lon)
		# ~100 m threshold in degrees at mid-latitudes.
		return dlat > 0.001 or dlon > 0.001
	var want_scene := str(map_info.get("scene_path", ""))
	if want_scene.is_empty():
		return false
	var cur := ""
	if main.get_tree() != null and main.get_tree().current_scene != null:
		cur = str(main.get_tree().current_scene.scene_file_path)
	return cur != want_scene


func _begin_map_switch(map_info: Dictionary) -> void:
	var kind := str(map_info.get("kind", "generated"))
	var tree := get_tree()
	if tree == null:
		return
	if kind == "scene":
		var path := str(map_info.get("scene_path", ""))
		if path.is_empty() or not path.begins_with("res://"):
			_emit_status("Host map scene path invalid", "error")
			_pending_join.clear()
			return
		tree.change_scene_to_file(path)
		return
	var lat := float(map_info.get("latitude", 0.0))
	var lon := float(map_info.get("longitude", 0.0))
	var label := str(map_info.get("label", "Multiplayer site"))
	var he := float(map_info.get("half_extent_m", 0.0))
	var dhe := float(map_info.get("detail_half_extent_m", 0.0))
	var ohe := float(map_info.get("osm_half_extent_m", 0.0))
	var map_ctx := get_node_or_null("/root/MapContext")
	if map_ctx != null and map_ctx.has_method("set_pending"):
		map_ctx.call("set_pending", lat, lon, label, he, false, dhe, ohe, false)
	tree.change_scene_to_file(MapDefinitionScript.GENERATED_SCENE)


func _connect_pending() -> Dictionary:
	if _pending_join.is_empty():
		return {"ok": false, "error": "No pending join"}
	var ip := str(_pending_join.get("ip", ""))
	var port := int(_pending_join.get("port", DEFAULT_PORT))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		_pending_join.clear()
		return {"ok": false, "error": "Connect failed (err %d)" % err}
	multiplayer.multiplayer_peer = peer
	role = Role.CLIENT
	host_address = ip
	host_port = port
	session_token = str(_pending_join.get("token", ""))
	session_name = str(_pending_join.get("name", "Session"))
	_ensure_remote_root()
	_wire_map_load_signal()
	_emit_status("Connecting to %s:%d…" % [ip, port], "info")
	session_changed.emit()
	return {"ok": true, "connecting": true}


# ── Presence / clock ─────────────────────────────────────────────────────────

func _send_local_presence() -> void:
	if not is_active():
		return
	var main := _find_main()
	if main == null:
		return
	var player := main.get_node_or_null("Player") as Node3D
	if player == null:
		return
	var pos := player.global_position
	var yaw := player.rotation.y
	if role == Role.HOST:
		# Host → all clients (no local avatar for self).
		rpc_presence_apply.rpc(multiplayer.get_unique_id(), pos, yaw, display_name)
	else:
		# Client → host; host relays to everyone else.
		rpc_presence_to_host.rpc_id(1, pos, yaw, display_name)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func rpc_presence_to_host(pos: Vector3, yaw: float, p_name: String) -> void:
	if role != Role.HOST:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	if not note_peer_traffic(sender, MpHardeningScript.COST_PRESENCE):
		return
	_apply_remote_presence(sender, p_name, pos, yaw)
	# Relay to all clients (call_remote skips host local).
	rpc_presence_apply.rpc(sender, pos, yaw, p_name)


@rpc("authority", "unreliable_ordered", "call_remote")
func rpc_presence_apply(peer_id: int, pos: Vector3, yaw: float, p_name: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	_apply_remote_presence(peer_id, p_name, pos, yaw)


func _apply_remote_presence(peer_id: int, p_name: String, pos: Vector3, yaw: float) -> void:
	if not peers.has(peer_id):
		peers[peer_id] = {"name": p_name, "ready": true}
		peer_list_changed.emit()
	elif str((peers[peer_id] as Dictionary).get("name", "")) != p_name and not p_name.is_empty():
		(peers[peer_id] as Dictionary)["name"] = p_name
		peer_list_changed.emit()
	_upsert_avatar(peer_id, p_name, pos, yaw)


func _broadcast_clock() -> void:
	if role != Role.HOST:
		return
	var main := _find_main()
	if main == null or not main.has_method("get_absolute_hours"):
		return
	var abs_h := float(main.call("get_absolute_hours"))
	var scale := float(main.get("time_scale"))
	rpc_clock.rpc(abs_h, scale)


@rpc("authority", "unreliable_ordered", "call_remote")
func rpc_clock(abs_h: float, scale: float) -> void:
	if role != Role.CLIENT:
		return
	var main := _find_main()
	if main == null:
		return
	_clock_sync_guard = true
	if main.has_method("get_absolute_hours") and main.has_method("set_absolute_hours"):
		var cur := float(main.call("get_absolute_hours"))
		if absf(cur - abs_h) > CLOCK_SNAP_HOURS:
			main.call("set_absolute_hours", abs_h)
	main.set("time_scale", scale)
	_clock_sync_guard = false


@rpc("any_peer", "reliable", "call_remote")
func rpc_peer_info(peer_id: int, p_name: String, ready: bool) -> void:
	peers[peer_id] = {"name": p_name, "ready": ready}
	if _avatars.has(peer_id):
		var av: RemotePlayerAvatar = _avatars[peer_id] as RemotePlayerAvatar
		if av != null:
			av.set_display_name(p_name)
	peer_list_changed.emit()


@rpc("authority", "reliable", "call_remote")
func rpc_welcome(info: Dictionary) -> void:
	# Host → joining client: roster + map confirmation.
	var roster: Dictionary = info.get("peers", {}) as Dictionary
	for k in roster.keys():
		peers[int(k)] = roster[k]
	session_name = str(info.get("session_name", session_name))
	session_token = str(info.get("token", session_token))
	var my_id := multiplayer.get_unique_id()
	peers[my_id] = {"name": display_name, "ready": true}
	rpc_peer_info.rpc(my_id, display_name, true)
	_emit_status("Joined %s" % session_name, "ok")
	session_changed.emit()
	peer_list_changed.emit()


@rpc("any_peer", "reliable", "call_remote")
func rpc_hello(hello: Dictionary) -> void:
	if role != Role.HOST:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not note_peer_traffic(sender, MpHardeningScript.COST_HELLO):
		return
	var p_name := str(hello.get("name", "Player")).strip_edges()
	if p_name.is_empty():
		p_name = "Player"
	var token := str(hello.get("token", ""))
	var client_proto := int(hello.get("proto", 0))
	var password := str(hello.get("password", ""))
	var friend_key := str(hello.get("friend_key", ""))
	if client_proto != PROTOCOL_VERSION:
		_reject_peer(sender, "protocol mismatch", {"proto": client_proto})
		return
	if MpHardeningScript.is_expired(session_expires_unix):
		_reject_peer(sender, "session join code expired", {})
		return
	if peers.size() >= MAX_PEERS:
		_reject_peer(sender, "session full", {"peers": peers.size()})
		return
	if not session_token.is_empty() and not token.is_empty() and token != session_token:
		_reject_peer(sender, "bad session token", {})
		return
	# Bare ip:port joins may omit token — still require password/allowlist when set.
	if not session_token.is_empty() and token.is_empty() and not host_password_hash.is_empty():
		# Allow bare join only when password proves knowledge of the session.
		pass
	elif not session_token.is_empty() and token.is_empty():
		# Direct LAN/ip join without code token — ok for private beta unless allowlist on.
		pass
	if not host_password_hash.is_empty():
		if not MpHardeningScript.password_matches(password, session_token, host_password_hash):
			_reject_peer(sender, "bad password", {})
			return
	if require_trusted:
		if not MpHardeningScript.trusted_key_allowed(friend_key, trusted_keys):
			_reject_peer(sender, "not on trusted allowlist", {})
			return
	peers[sender] = {"name": p_name, "ready": true}
	var welcome := {
		"session_name": session_name,
		"token": session_token,
		"peers": peers.duplicate(true),
		"map": collect_map_info(),
		"exp": session_expires_unix,
	}
	rpc_welcome.rpc_id(sender, welcome)
	rpc_peer_info.rpc(sender, p_name, true)
	# Push host's current design so the joiner converges quickly.
	if design != null and design.has_method("rpc_request_full_sync"):
		design.call("_flush_graph_snapshot")
		design.call("_flush_props_snapshot")
	MpHardeningScript.log_event("join_ok", {"peer_id": sender, "name": p_name})
	_emit_status("%s joined" % p_name, "ok")
	if chat != null and chat.has_method("push_system"):
		chat.call("push_system", "%s joined the session" % p_name)
	peer_list_changed.emit()
	session_changed.emit()


func _reject_peer(peer_id: int, reason: String, detail: Dictionary) -> void:
	var d := detail.duplicate(true)
	d["peer_id"] = peer_id
	d["reason"] = reason
	MpHardeningScript.log_event("join_reject", d)
	_emit_status("Rejected peer %d — %s" % [peer_id, reason], "warn")
	_disconnect_peer(peer_id)


func _disconnect_peer(peer_id: int) -> void:
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_peer(peer_id)
	peers.erase(peer_id)


# ── Peer callbacks ───────────────────────────────────────────────────────────

func _on_peer_connected(id: int) -> void:
	if role == Role.HOST:
		# Wait for rpc_hello from client (carries display name / token).
		peers[id] = {"name": "Player %d" % id, "ready": false}
		peer_list_changed.emit()
	session_changed.emit()


func _on_peer_disconnected(id: int) -> void:
	var left_name := str((peers.get(id, {}) as Dictionary).get("name", "Peer %d" % id))
	peers.erase(id)
	_remove_avatar(id)
	if design != null:
		var lock_keys: Array = []
		for k in design.locks.keys():
			var info: Dictionary = design.locks[k] as Dictionary
			if int(info.get("peer_id", 0)) == id:
				lock_keys.append(k)
		for k in lock_keys:
			design.locks.erase(k)
		if not lock_keys.is_empty() and design.has_signal("locks_changed"):
			design.locks_changed.emit()
	if chat != null and chat.has_method("push_system"):
		chat.call("push_system", "%s left the session" % left_name)
	_emit_status("Peer %d left" % id, "info")
	peer_list_changed.emit()
	session_changed.emit()


func _on_connected_to_server() -> void:
	var my_id := multiplayer.get_unique_id()
	peers[my_id] = {"name": display_name, "ready": true}
	rpc_hello.rpc_id(1, {
		"name": display_name,
		"token": session_token,
		"proto": PROTOCOL_VERSION,
		"password": pending_password,
		"friend_key": pending_friend_key,
	})
	MpHardeningScript.log_event("join_attempt", {
		"has_pw": not pending_password.is_empty(),
		"has_friend_key": not pending_friend_key.is_empty(),
	})
	_pending_join.clear()
	_awaiting_map_load = false
	if design != null and design.has_method("on_joined_as_client"):
		design.call("on_joined_as_client")
	if chat != null and chat.has_method("push_system"):
		chat.call("push_system", "Connected — press Enter to chat")
	_emit_status("Connected to host", "ok")
	session_changed.emit()
	peer_list_changed.emit()


func _on_connection_failed() -> void:
	_emit_status("Connection failed", "error")
	leave_session(false)


func _on_server_disconnected() -> void:
	_emit_status("Host disconnected", "warn")
	leave_session(false)


func _on_scene_changed() -> void:
	call_deferred("_after_scene_changed")


func _after_scene_changed() -> void:
	_remote_root = null
	_avatars.clear()
	if role != Role.NONE:
		_ensure_remote_root()
		_wire_map_load_signal()
	if not _pending_join.is_empty() and _awaiting_map_load:
		_wire_map_load_signal()


func _wire_map_load_signal() -> void:
	var main := _find_main()
	if main == null:
		return
	var loader := main.get_node_or_null("TerrainLoader")
	if loader == null:
		# Baked maps without TerrainLoader — connect immediately if pending.
		if not _pending_join.is_empty() and _awaiting_map_load and role == Role.NONE:
			call_deferred("_finish_pending_after_load")
		return
	if loader.has_signal("map_load_complete"):
		if not loader.map_load_complete.is_connected(_on_map_load_complete):
			loader.map_load_complete.connect(_on_map_load_complete, CONNECT_ONE_SHOT)
	# If already built, finish now.
	if loader.get("_built") == true and not _pending_join.is_empty() and _awaiting_map_load:
		call_deferred("_finish_pending_after_load")


func _on_map_load_complete() -> void:
	if role == Role.HOST:
		_refresh_join_code()
		session_changed.emit()
	_finish_pending_after_load()


func _finish_pending_after_load() -> void:
	if _pending_join.is_empty() or not _awaiting_map_load:
		return
	if role != Role.NONE:
		return
	_awaiting_map_load = false
	var result := _connect_pending()
	if not bool(result.get("ok", false)):
		_emit_status(str(result.get("error", "Join failed")), "error")


# ── Avatars ──────────────────────────────────────────────────────────────────

func _ensure_remote_root() -> void:
	var main := _find_main()
	if main == null:
		return
	_remote_root = main.get_node_or_null("RemotePlayers") as Node3D
	if _remote_root == null:
		_remote_root = Node3D.new()
		_remote_root.name = "RemotePlayers"
		main.add_child(_remote_root)


func _upsert_avatar(peer_id: int, p_name: String, pos: Vector3, yaw: float) -> void:
	_ensure_remote_root()
	if _remote_root == null:
		return
	var av: RemotePlayerAvatar = _avatars.get(peer_id) as RemotePlayerAvatar
	if av == null or not is_instance_valid(av):
		av = RemoteAvatarScript.new() as RemotePlayerAvatar
		av.setup(peer_id, p_name)
		_remote_root.add_child(av)
		_avatars[peer_id] = av
	else:
		av.set_display_name(p_name)
	av.apply_pose(pos, yaw)


func _remove_avatar(peer_id: int) -> void:
	if not _avatars.has(peer_id):
		return
	var av: RemotePlayerAvatar = _avatars[peer_id] as RemotePlayerAvatar
	_avatars.erase(peer_id)
	if av != null and is_instance_valid(av):
		av.queue_free()


func _clear_avatars() -> void:
	for k in _avatars.keys():
		var av: RemotePlayerAvatar = _avatars[k] as RemotePlayerAvatar
		if av != null and is_instance_valid(av):
			av.queue_free()
	_avatars.clear()
	if _remote_root != null and is_instance_valid(_remote_root):
		_remote_root.queue_free()
	_remote_root = null


# ── LAN discovery ────────────────────────────────────────────────────────────

func _start_lan_broadcast() -> void:
	if _udp_broadcast != null:
		return
	_udp_broadcast = PacketPeerUDP.new()
	_udp_broadcast.set_broadcast_enabled(true)
	_udp_broadcast.set_dest_address("255.255.255.255", LAN_DISCOVERY_PORT)


func _stop_lan_broadcast() -> void:
	if _udp_broadcast != null:
		_udp_broadcast.close()
		_udp_broadcast = null


func _broadcast_lan_beacon() -> void:
	if role != Role.HOST or _udp_broadcast == null:
		return
	_refresh_join_code()
	var beacon := {
		"v": PROTOCOL_VERSION,
		"ip": host_address,
		"port": host_port,
		"token": session_token,
		"name": session_name,
		"code": join_code,
		"map": collect_map_info(),
		"peers": peers.size(),
	}
	var bytes := JSON.stringify(beacon).to_utf8_buffer()
	_udp_broadcast.put_packet(bytes)


func _poll_lan_packets() -> void:
	if _udp_listen == null:
		return
	var changed := false
	while _udp_listen.get_available_packet_count() > 0:
		var packet := _udp_listen.get_packet()
		var sender_ip := _udp_listen.get_packet_ip()
		var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if not (parsed is Dictionary):
			continue
		var d: Dictionary = parsed as Dictionary
		if int(d.get("v", 0)) != PROTOCOL_VERSION:
			continue
		var ip := str(d.get("ip", sender_ip))
		if ip.is_empty():
			ip = sender_ip
		var port := int(d.get("port", DEFAULT_PORT))
		var token := str(d.get("token", ""))
		var entry := {
			"ip": ip,
			"port": port,
			"token": token,
			"name": str(d.get("name", "Session")),
			"code": str(d.get("code", "")),
			"map": d.get("map", {}),
			"peers": int(d.get("peers", 1)),
		}
		var idx := _find_lan_host(ip, port, token)
		if idx < 0:
			lan_hosts.append(entry)
			changed = true
		else:
			lan_hosts[idx] = entry
			changed = true
	# Drop stale? keep list; refreshed while listening.
	if changed:
		lan_hosts_changed.emit()


func _find_lan_host(ip: String, port: int, token: String) -> int:
	for i in lan_hosts.size():
		var e: Dictionary = lan_hosts[i] as Dictionary
		if str(e.get("ip", "")) == ip and int(e.get("port", 0)) == port:
			if token.is_empty() or str(e.get("token", "")) == token:
				return i
	return -1


# ── Helpers ──────────────────────────────────────────────────────────────────

static func pick_lan_ipv4() -> String:
	var addrs := IP.get_local_addresses()
	var fallback := "127.0.0.1"
	for a in addrs:
		var s := str(a)
		if s.contains(":"):
			continue  # skip IPv6
		if s.begins_with("127."):
			continue
		if s.begins_with("169.254."):
			continue
		# Prefer private LAN ranges.
		if s.begins_with("192.168.") or s.begins_with("10.") \
				or s.begins_with("172.16.") or s.begins_with("172.17.") \
				or s.begins_with("172.18.") or s.begins_with("172.19.") \
				or s.begins_with("172.2") or s.begins_with("172.30.") \
				or s.begins_with("172.31."):
			return s
		fallback = s
	return fallback


func _mint_token() -> String:
	return "%x%x" % [Time.get_ticks_msec() & 0xffff, randi() & 0xffff]


func _find_main() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene == null:
		return null
	if str(scene.name) == "Main":
		return scene
	var nested := scene.find_child("Main", true, false)
	return nested if nested != null else scene


func _emit_status(text: String, level: String = "info") -> void:
	status_message.emit(text, level)
	var main := _find_main()
	if main != null and main.has_method("show_toast"):
		# ToastUI.Level: INFO=0, OK=1, WARN=2, ERROR=3
		var toast_level := 0
		match level:
			"ok":
				toast_level = 1
			"warn":
				toast_level = 2
			"error":
				toast_level = 3
		main.call("show_toast", text, toast_level, 3.5)


func _load_display_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return "Player"
	var n := str(cfg.get_value("mp", "display_name", "Player")).strip_edges()
	return n if not n.is_empty() else "Player"


func _save_display_name(name_: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("mp", "display_name", name_)
	cfg.save(PREFS_PATH)
