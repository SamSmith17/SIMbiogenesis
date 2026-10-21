extends Node

## Phase 2–6 listen-server co-presence: host/join, remote avatars, host clock,
## design share/live sync, session chat, and private-beta hardening (Phase 6).

signal session_changed()
signal peer_list_changed()
signal lan_hosts_changed()
signal status_message(text: String, level: String)
## Someone started or stopped inhabiting one of the simulated people.
signal possession_changed()

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
## v3: hello carries `discord_token`, welcome carries `discord`, join code gains
## `addrs` + `dsc`. Consequence to accept consciously — the strict `!=` check in
## rpc_hello AND the same constant in `_poll_lan_packets` mean old and new
## builds neither join nor SEE each other, and only the new client can print a
## useful message about it.
## v4: shared design travels as change ops + guest proposals the host approves
## (mp_design_controller), and presence carries the body's pose.
const PROTOCOL_VERSION := 4
const PREFS_PATH := "user://mp_prefs.cfg"
const PRESENCE_HZ := 12.0
const CLOCK_HZ := 2.0
const LAN_BROADCAST_HZ := 0.5
const CLOCK_SNAP_HOURS := 0.002  # ~7 s of sim time
## Max distance (m) for 3D proximity chat bubbles above remote avatars.
const CHAT_BUBBLE_RANGE_M := 45.0
const DEFAULT_CODE_TTL_SEC := 4 * 3600
## ENet's create_client() returns OK immediately and a black-holed UDP port —
## the common NAT case — may NEVER fire connection_failed, so each candidate
## address gets a wall-clock budget of its own.
const CONNECT_TIMEOUT_SEC := 6.0

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

## ── Reachability ─────────────────────────────────────────────────────────────
## `host_address` stays the LAN address (pick_lan_ipv4's RFC1918 preference is
## load-bearing for LAN discovery). The public address is ADDITIVE: UPnP learns
## it in the background and it is folded into the join code as a second
## candidate, which is what finally makes internet play work without a
## hand-edited ip:port.
var wan_address: String = ""
var _reach: MpReachability = null
var _reach_result: Dictionary = {}
var _reach_probing := false
## ── Discord admission ────────────────────────────────────────────────────────
## Host-side: when a community is imported and `require_discord` is on, a joiner
## must present a Discord token that resolves to a member of that guild.
var require_discord: bool = false
var discord_community: Dictionary = {}
## Discord being unreachable is a RUNTIME FAILURE of a restriction the host
## explicitly asked for, so it fails CLOSED by default. Note this is deliberately
## the OPPOSITE of `MpHardening.trusted_key_allowed`, which fails OPEN on an
## empty allowlist — that is a CONFIGURATION statement ("nothing configured, so
## no restriction"). Different semantics, different defaults; do not let a
## future refactor harmonise them.
var allow_when_discord_unreachable: bool = false
## peer_id -> {hello, started_ms, epoch}. Connected at the ENet level, held out
## of `peers`, RPCs dropped, until verification resolves or times out.
var _pending_admission: Dictionary = {}
var _admission_epoch: int = 0
var discord_gate: Node = null
var discord_relay: Node = null
## Host → client NPC stream. Clients render the population; they do not
## simulate it (see mp_population_controller.gd).
var population: Node = null

## ── Possession ───────────────────────────────────────────────────────────────
## agent_id -> peer_id. Host-authoritative; mirrored to clients so everyone
## knows which people are being driven by humans.
var possessed: Dictionary = {}
## The agent THIS peer is inhabiting, or "".
var my_agent_id: String = ""
var _last_speed_warn_unix: int = 0
var _last_speed_bracket: int = -1
## Client credential presented on the next hello.
var pending_discord_token: String = ""

## Client-side connect ladder over the join code's candidate addresses.
var _candidates: Array = []
var _candidate_index: int = -1
var _candidate_deadline_ms: int = 0


func _ready() -> void:
	display_name = _load_display_name()
	design = DesignControllerScript.new()
	design.name = "Design"
	add_child(design)
	chat = ChatControllerScript.new()
	chat.name = "Chat"
	add_child(chat)
	discord_gate = preload("res://core/discord/discord_gate.gd").new()
	add_child(discord_gate)
	discord_gate.connect("verified", _on_discord_verified)
	discord_relay = preload("res://core/discord/discord_relay.gd").new()
	add_child(discord_relay)
	chat.connect("message_received", discord_relay.on_chat_message)
	population = preload("res://core/multiplayer/mp_population_controller.gd").new()
	add_child(population)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	get_tree().scene_changed.connect(_on_scene_changed)
	set_process(true)


## Autoloads leave the tree on shutdown, so this is where a router mapping we
## created gets torn down if the player quits while still hosting.
func _exit_tree() -> void:
	_release_reachability()


func _process(delta: float) -> void:
	_poll_lan_packets()
	_poll_connect_deadline()
	if role == Role.NONE:
		return
	_presence_accum += delta
	if _presence_accum >= 1.0 / PRESENCE_HZ:
		_presence_accum = 0.0
		_send_local_presence()
	if is_possessing():
		_maybe_warn_time_scale()
	if role == Role.HOST:
		_sweep_pending_admissions()
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
	_begin_reachability_probe()
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
	# The guest's own world is saved, then left alone: the session plays in a
	# throwaway copy (MpGuestWorld) the host's world is written into.
	var main := _find_main()
	if main != null and WorldPaths.has_active_world() and not MpGuestWorld.is_active():
		WorldSession.save_now(main, false, false)
	if not map_info.is_empty():
		MpGuestWorld.prepare(map_info)
	if _map_needs_switch(map_info):
		_awaiting_map_load = true
		_begin_map_switch(map_info)
		_emit_status("Loading host map…", "info")
		session_changed.emit()
		return {"ok": true, "loading_map": true, "pending": true}
	if not map_info.is_empty():
		MpGuestWorld.activate(map_info)
	return _connect_pending()


func leave_session(announce: bool = true) -> void:
	var was_active := is_active()
	# Tell the community the seat is free rather than making everyone wait out
	# the directory's staleness window. Soft lookup so headless selftests and
	# the harness (which have no directory) are unaffected.
	if role == Role.HOST:
		var dir := get_node_or_null("/root/DiscordDirectory")
		if dir != null and dir.has_method("vacate"):
			dir.call("vacate")
	_stop_lan_broadcast()
	_release_reachability()
	_candidates.clear()
	_candidate_index = -1
	_candidate_deadline_ms = 0
	_clear_avatars()
	if design != null and design.has_method("clear_session_state"):
		design.call("clear_session_state")
	if chat != null and chat.has_method("clear_session_state"):
		chat.call("clear_session_state")
	if population != null and population.has_method("clear_session_state"):
		population.call("clear_session_state")
	_pending_join.clear()
	_awaiting_map_load = false
	join_code = ""
	session_token = ""
	host_address = ""
	wan_address = ""
	session_expires_unix = 0
	host_password_hash = ""
	_host_password_plain = ""
	pending_password = ""
	pending_friend_key = ""
	_rate_buckets.clear()
	_pending_admission.clear()
	if role == Role.HOST:
		for aid in possessed.keys():
			_set_agent_controller(str(aid), 0)
	possessed.clear()
	my_agent_id = ""
	peers.clear()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	var was_guest := role == Role.CLIENT
	role = Role.NONE
	if was_active:
		MpHardeningScript.log_event("session_leave", {})
	if was_active and was_guest and MpGuestWorld.is_active():
		_emit_status("Session over — this is a copy of the host's world and is not saved to your worlds. Exit to the menu to go back to yours.", "warn")
	elif announce:
		_emit_status("Left multiplayer session", "info")
	session_changed.emit()
	peer_list_changed.emit()


func set_join_credentials(password: String = "", friend_key: String = "") -> void:
	pending_password = password.strip_edges()
	pending_friend_key = friend_key.strip_edges()


## Host: require Discord server membership instead of (or alongside) the manual
## friend-key allowlist. Passing an empty community turns it off.
func set_discord_requirement(community: Dictionary, require: bool,
		allow_when_unreachable: bool = false) -> void:
	discord_community = community.duplicate(true)
	require_discord = require and DiscordConfig.is_snowflake(
		str(discord_community.get("guild_id", "")))
	allow_when_discord_unreachable = allow_when_unreachable
	if role == Role.HOST:
		_refresh_join_code()
		session_changed.emit()


## The bearer a joiner presents. `pending_discord_token` is an explicit override
## (used by tooling); normally this is the signed-in user's own token.
func _discord_token_for_join() -> String:
	if not pending_discord_token.is_empty():
		return pending_discord_token
	var id := get_node_or_null("/root/DiscordIdentity")
	if id == null:
		return ""
	return str(id.call("present_token"))


## Can this client satisfy a host that requires Discord? Lets the lobby prompt
## for sign-in BEFORE connecting, rather than letting the peer connect and be
## kicked with a confusing message.
func can_satisfy_discord(decoded: Dictionary) -> bool:
	if not MpJoinCodeScript.needs_discord(decoded):
		return true
	return not _discord_token_for_join().is_empty()


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


## Has this peer cleared every gate? Nearly every host-side inbound RPC routes
## through `note_peer_traffic`, so this one predicate is what stops a connected
## but unverified peer from acting.
func peer_admitted(peer_id: int) -> bool:
	return MpHardeningScript.peer_is_admitted(peers, peer_id)


func note_peer_traffic(peer_id: int, cost: int, require_admitted: bool = true) -> bool:
	## Returns false if the peer's message should be dropped — either because it
	## was disconnected for abuse, or because it is not admitted yet.
	##
	## `require_admitted` is false only for the hello handshake itself, which by
	## definition arrives before admission.
	if role != Role.HOST or peer_id <= 1:
		return true
	if require_admitted and not peer_admitted(peer_id):
		# DROP, never kick. Admission can take a Discord round-trip, and a
		# legitimate joiner whose presence packets arrive first must not be
		# punished for it — unlike the rate-limit path below, which does kick.
		return false
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
	# Reads CACHED addresses only. `_broadcast_lan_beacon` calls this at 0.5 Hz,
	# so re-querying UPnP here would hammer the router twice a second.
	var enc: Dictionary = MpJoinCodeScript.encode({
		"addrs": join_addresses(),
		"token": session_token,
		"name": session_name,
		"map": collect_map_info(),
		"exp": session_expires_unix,
		"has_pw": not host_password_hash.is_empty(),
		# Advertised so a joiner can be told to sign in before connecting.
		"dsc": {
			"g": str(discord_community.get("guild_id", "")),
			"need": require_discord,
		} if require_discord else {},
	})
	join_code = str(enc.get("code", "")) if bool(enc.get("ok", false)) else ""


## Ordered candidate addresses baked into the join code: LAN first (so a
## same-network peer never round-trips through the router), public second.
func join_addresses() -> Array:
	var out: Array = []
	var lan := host_address if not host_address.is_empty() else pick_lan_ipv4()
	if not lan.is_empty():
		out.append({"h": lan, "p": host_port, "k": "lan"})
	if not wan_address.is_empty() and wan_address != lan:
		out.append({"h": wan_address, "p": host_port, "k": "pub"})
	return out


# ── Reachability (UPnP) ──────────────────────────────────────────────────────

func _begin_reachability_probe() -> void:
	if _reach_probing:
		return
	# Every headless entry point in this project is a selftest or a capture
	# harness (all export presets have dedicated_server=false), and none of them
	# should be poking the player's router or leaving a port mapping behind.
	if DisplayServer.get_name() == "headless":
		return
	if _reach == null:
		_reach = MpReachability.new()
	_reach_probing = true
	_reach_result = {}
	wan_address = ""
	# UPNP.discover() blocks ~2 s, so this runs on a worker thread and comes
	# back deferred. Hosting must never stall on a router that is not listening.
	_reach.probe_async(host_port, _on_reachability_done)


func _on_reachability_done(result: Dictionary) -> void:
	_reach_probing = false
	if role != Role.HOST:
		return  # we stopped hosting while the router was thinking
	_reach_result = result
	var external := str(result.get("external_ip", "")).strip_edges()
	# Only a genuinely routable address is worth putting in a join code; a
	# private or CGNAT "external" address would just cost every joiner a
	# pointless connect timeout.
	wan_address = external if MpReachability.is_routable_public(external) else ""
	_refresh_join_code()
	MpHardeningScript.log_event("reachability", {
		"gateway": bool(result.get("gateway", false)),
		"mapped": bool(result.get("mapped", false)),
		"code": int(result.get("code", -1)),
		"public": not wan_address.is_empty(),
	})
	_emit_status(reachability_text(), "ok" if bool(result.get("mapped", false)) else "warn")
	session_changed.emit()


## Drop the router mapping we created. Leaving a stray forward on a shared
## router is rude, and a stale one collides with the next session.
func _release_reachability() -> void:
	if _reach == null:
		return
	if bool(_reach_result.get("mapped", false)):
		_reach.release(host_port)
	_reach_result = {}
	_reach_probing = false


## Re-run the probe (lobby "Retry UPnP"). No-op while one is already in flight.
func retry_reachability() -> void:
	if role != Role.HOST:
		return
	_release_reachability()
	_begin_reachability_probe()
	session_changed.emit()


## One line for the lobby: what happened, and what the host should do about it.
func reachability_text() -> String:
	if role != Role.HOST:
		return ""
	if _reach_probing:
		return "Checking router for UPnP…"
	if _reach_result.is_empty():
		return "Reachability unknown — LAN players can join."
	if bool(_reach_result.get("verified", false)):
		return "UPnP mapped UDP %d · public %s (VERIFIED — someone joined from the internet)." % [
			host_port, wan_address]
	return MpReachability.diagnosis(_reach_result, host_port)


## A peer that connected from a routable public address PROVES the port is open
## from the internet. We run no external server, so this opportunistic check is
## the only honest confirmation available.
func _note_inbound_reach(peer_id: int) -> void:
	if role != Role.HOST or _reach_result.get("verified", false):
		return
	# `get_peer` is ENet-specific; guard so a future transport swap cannot crash here.
	var api_peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if api_peer == null or not api_peer.has_method("get_peer"):
		return
	var enet_peer: ENetPacketPeer = api_peer.get_peer(peer_id)
	if enet_peer == null:
		return
	if MpReachability.is_routable_public(enet_peer.get_remote_address()):
		_reach_result["verified"] = true
		session_changed.emit()


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
		WorldSession.switch_scene(path, MpGuestWorld.record_for(map_info))
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
	WorldSession.switch_scene(MapDefinitionScript.GENERATED_SCENE, MpGuestWorld.record_for(map_info))


func _connect_pending() -> Dictionary:
	if _pending_join.is_empty():
		return {"ok": false, "error": "No pending join"}
	var addrs: Array = _pending_join.get("addrs", []) as Array
	if addrs.is_empty():
		# v2 codes and bare ip:port only ever carry one address.
		addrs = [{
			"h": str(_pending_join.get("ip", "")),
			"p": int(_pending_join.get("port", DEFAULT_PORT)),
			"k": "lan",
		}]
	_candidates = MpReachability.candidate_order(addrs, pick_lan_ipv4())
	_candidate_index = -1
	if _candidates.is_empty():
		_pending_join.clear()
		return {"ok": false, "error": "Join code has no usable address"}
	session_token = str(_pending_join.get("token", ""))
	session_name = str(_pending_join.get("name", "Session"))
	return _try_next_candidate()


## Start (or advance to) the next candidate address.
func _try_next_candidate() -> Dictionary:
	_candidate_deadline_ms = 0
	_candidate_index += 1
	if _candidate_index >= _candidates.size():
		var tried := _candidates.size()
		_candidates.clear()
		_candidate_index = -1
		_pending_join.clear()
		if multiplayer.multiplayer_peer != null:
			multiplayer.multiplayer_peer.close()
			multiplayer.multiplayer_peer = null
		role = Role.NONE
		_emit_status("Could not reach the host (tried %d address%s)" % [
			tried, "" if tried == 1 else "es"], "error")
		session_changed.emit()
		return {"ok": false, "error": "Could not reach the host"}

	var cand: Dictionary = _candidates[_candidate_index]
	var ip := str(cand.get("h", ""))
	var port := int(cand.get("p", DEFAULT_PORT))
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		# A local failure (bad address, no socket) — move straight on.
		return _try_next_candidate()
	multiplayer.multiplayer_peer = peer
	role = Role.CLIENT
	host_address = ip
	host_port = port
	_candidate_deadline_ms = Time.get_ticks_msec() + int(CONNECT_TIMEOUT_SEC * 1000.0)
	_ensure_remote_root()
	_wire_map_load_signal()
	_emit_status("Trying %s %s:%d…" % [_candidate_label(cand), ip, port], "info")
	session_changed.emit()
	return {"ok": true, "connecting": true}


func _candidate_label(cand: Dictionary) -> String:
	match str(cand.get("k", "")):
		"lan": return "LAN"
		"pub": return "public"
	return "host"


## Advance past a candidate that neither connected nor reported a failure.
## Without this a black-holed UDP port leaves the client "Connecting…" forever,
## which is the single most common NAT symptom.
func _poll_connect_deadline() -> void:
	if _candidate_deadline_ms <= 0 or role != Role.CLIENT:
		return
	if Time.get_ticks_msec() < _candidate_deadline_ms:
		return
	_candidate_deadline_ms = 0
	_try_next_candidate()


# ── Presence / clock ─────────────────────────────────────────────────────────

func _send_local_presence() -> void:
	if not is_active():
		return
	# Still joining, or the host just went away (the disconnect signal lands a
	# frame later): an RPC now is an engine error.
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	var main := _find_main()
	if main == null:
		return
	var player := main.get_node_or_null("Player") as Node3D
	if player == null:
		return
	var pos := player.global_position
	var yaw := player.rotation.y
	# What the body is doing, so other screens draw the same pose.
	var body := PackedFloat32Array()
	if player.has_method("net_body_state"):
		body = RemotePlayerAvatar.pack_body(player.call("net_body_state"))
	var tint := PlayerPrefs.tint()
	if role == Role.HOST:
		# Host → all clients (no local avatar for self).
		rpc_presence_apply.rpc(multiplayer.get_unique_id(), pos, yaw, display_name, my_agent_id,
			body, tint)
		# The host's own possession still has to reach the sim.
		_drive_possessed_agent(my_agent_id, pos, yaw)
	else:
		# Client → host; host relays to everyone else.
		rpc_presence_to_host.rpc_id(1, pos, yaw, display_name, my_agent_id, body, tint)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func rpc_presence_to_host(pos: Vector3, yaw: float, p_name: String,
		agent_id: String = "", body: PackedFloat32Array = PackedFloat32Array(),
		tint: Color = Color(0.55, 0.62, 0.78)) -> void:
	if role != Role.HOST:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	if not note_peer_traffic(sender, MpHardeningScript.COST_PRESENCE):
		return
	# Only the agent the host actually granted this peer — a client claiming an
	# arbitrary agent_id must not be able to teleport someone else's person.
	var granted := MpPossession.agent_of_peer(possessed, sender)
	if not granted.is_empty() and granted == agent_id:
		_drive_possessed_agent(agent_id, pos, yaw)
	else:
		agent_id = granted
	if body.size() > 16:
		body = PackedFloat32Array()
	_apply_remote_presence(sender, p_name, pos, yaw, agent_id, body, tint)
	# Relay to all clients (call_remote skips host local).
	rpc_presence_apply.rpc(sender, pos, yaw, p_name, agent_id, body, tint)


@rpc("authority", "unreliable_ordered", "call_remote")
func rpc_presence_apply(peer_id: int, pos: Vector3, yaw: float, p_name: String,
		agent_id: String = "", body: PackedFloat32Array = PackedFloat32Array(),
		tint: Color = Color(0.55, 0.62, 0.78)) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	_apply_remote_presence(peer_id, p_name, pos, yaw, agent_id, body, tint)


func _apply_remote_presence(peer_id: int, p_name: String, pos: Vector3, yaw: float,
		agent_id: String = "", body: PackedFloat32Array = PackedFloat32Array(),
		tint: Color = Color(0.55, 0.62, 0.78)) -> void:
	if not peers.has(peer_id):
		peers[peer_id] = {"name": p_name, "ready": true}
		peer_list_changed.emit()
	elif str((peers[peer_id] as Dictionary).get("name", "")) != p_name and not p_name.is_empty():
		(peers[peer_id] as Dictionary)["name"] = p_name
		peer_list_changed.emit()
	if agent_id.is_empty():
		_upsert_avatar(peer_id, p_name, pos, yaw, RemotePlayerAvatar.unpack_body(body), tint)
		return
	# Possessed: the person is already on screen as an NpcAvatar. Drawing the
	# capsule too would render the same player twice, standing in the same spot.
	_remove_avatar(peer_id)


## Write a possessed person's position straight onto the sim agent. Everything
## downstream — the Site Plan dots, the 3D avatar, crosshair focus, the
## replication stream — reads `NpcAgent.pos`, so this one write is the whole
## integration. Host-only; clients see the result through replication.
func _drive_possessed_agent(agent_id: String, pos: Vector3, yaw: float) -> void:
	if role != Role.HOST or agent_id.is_empty():
		return
	var agent = _find_agent(agent_id)
	if agent == null:
		return
	agent.pos = Vector2(pos.x, pos.z)
	agent.set_meta("possessed_yaw", yaw)


func _find_agent(agent_id: String):
	# Re-resolved every call, never cached: _ensure_engine replaces every
	# NpcAgent object whenever the authored occupants count changes.
	var view := _find_graph_view()
	if view == null:
		return null
	var bridge = view.get("_npc_population")
	if bridge == null or not bridge.has_method("find_agent"):
		return null
	return bridge.call("find_agent", agent_id)


func _find_graph_view() -> Node:
	var main := _find_main()
	if main == null:
		return null
	var ui := main.get_node_or_null("UILayer")
	return ui.get_node_or_null("SystemGraphView") if ui != null else null


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
	# Was completely ungated: any connected peer could rewrite the roster,
	# including marking itself ready. It bypasses note_peer_traffic, so the
	# admission check has to be explicit here.
	if role == Role.HOST:
		var sender := multiplayer.get_remote_sender_id()
		if sender != 0 and not peer_admitted(sender):
			return
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
	# The one RPC that legitimately precedes admission, so it opts out of the
	# admitted check while still paying the rate limit.
	if not note_peer_traffic(sender, MpHardeningScript.COST_HELLO, false):
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

	# Every cheap synchronous check above runs FIRST and unchanged, so a peer
	# that fails one never costs a Discord API call. Only now does admission
	# possibly become asynchronous.
	if _discord_admission_applies():
		_begin_discord_admission(sender, p_name, str(hello.get("discord_token", "")))
		return
	_admit_peer(sender, p_name)


## Everything that used to be the tail of rpc_hello. Extracted so the Discord
## path can reach it from a callback several hundred milliseconds later.
func _admit_peer(sender: int, p_name: String, extra: Dictionary = {}) -> void:
	if role != Role.HOST:
		return
	_pending_admission.erase(sender)
	peers[sender] = {"name": p_name, "ready": true}
	if not extra.is_empty():
		(peers[sender] as Dictionary)["discord"] = extra
	var welcome := {
		"session_name": session_name,
		"token": session_token,
		"peers": peers.duplicate(true),
		"map": collect_map_info(),
		"exp": session_expires_unix,
	}
	rpc_welcome.rpc_id(sender, welcome)
	rpc_peer_info.rpc(sender, p_name, true)
	# The joiner gets the whole shared world once; after that only changes.
	if design != null and design.has_method("send_full_to"):
		design.call("send_full_to", sender)
	MpHardeningScript.log_event("join_ok", {"peer_id": sender, "name": p_name,
		"discord": str(extra.get("user_id", ""))})
	_emit_status("%s joined" % p_name, "ok")
	if chat != null and chat.has_method("push_system"):
		chat.call("push_system", "%s joined the session" % p_name)
	# Someone joining mid-session must also be told their chat is leaving the
	# game, not just whoever was present when the relay was switched on.
	if discord_relay != null:
		var notice := str(discord_relay.call("notice_text"))
		if not notice.is_empty() and chat != null and chat.has_method("_broadcast_chat"):
			chat.call("_broadcast_chat", 0, "System", notice)
	peer_list_changed.emit()


func _discord_admission_applies() -> bool:
	return require_discord \
		and discord_gate != null \
		and DiscordConfig.is_snowflake(str(discord_community.get("guild_id", "")))


func _begin_discord_admission(sender: int, p_name: String, token: String) -> void:
	_admission_epoch += 1
	# NOTE the token is NOT stored here. It lives only in the local variable
	# handed to the gate, and `_pending_admission` keeps metadata alone — which
	# is also what keeps it out of `MpHardening.log_event`.
	_pending_admission[sender] = {
		"name": p_name,
		"started_ms": Time.get_ticks_msec(),
		"epoch": _admission_epoch,
	}
	peers[sender] = {"name": p_name, "ready": false, "pending": true}
	peer_list_changed.emit()
	rpc_admission_pending.rpc_id(sender)
	discord_gate.call("verify", sender, token, discord_community)


func _on_discord_verified(peer_id: int, result: Dictionary) -> void:
	if role != Role.HOST:
		return
	var entry: Dictionary = _pending_admission.get(peer_id, {}) as Dictionary
	if entry.is_empty():
		return  # timed out, disconnected, or ENet reused the id — ignore
	if bool(result.get("ok", false)):
		_admit_peer(peer_id, str(entry.get("name", "Player")), {
			"user_id": str(result.get("user_id", "")),
			"username": str(result.get("username", "")),
			"avatar": str(result.get("avatar", "")),
			"roles": result.get("roles", []),
		})
		return
	# A transient failure (Discord down, rate-limited) is not the guest's fault.
	# Fail CLOSED unless the host explicitly opted out — see the field comment.
	if not bool(result.get("fatal", false)) and allow_when_discord_unreachable:
		_admit_peer(peer_id, str(entry.get("name", "Player")))
		return
	_pending_admission.erase(peer_id)
	_reject_peer(peer_id, str(result.get("error", "Discord check failed")), {})


## Peers whose verification never came back. Swept from _process.
func _sweep_pending_admissions() -> void:
	if role != Role.HOST or _pending_admission.is_empty():
		return
	for pid in MpHardeningScript.expired_admissions(_pending_admission, Time.get_ticks_msec()):
		_pending_admission.erase(pid)
		_reject_peer(int(pid), "Discord verification timed out", {})


## Host → joiner: "you are connected, but hold on". Without this the joiner just
## looks hung for up to 12 s.
@rpc("authority", "reliable", "call_remote")
func rpc_admission_pending() -> void:
	_emit_status("Checking your Discord membership…", "info")


# ── Possession ───────────────────────────────────────────────────────────────

## Ask to inhabit one of the simulated people. Resolves on `possession_changed`.
func request_possess(agent_id: String) -> Dictionary:
	if not is_active():
		return {"ok": false, "error": "Not in a session"}
	if role == Role.HOST:
		return _grant_possession(1, agent_id)
	rpc_possess_request.rpc_id(1, agent_id)
	return {"ok": true, "pending": true}


func release_possession() -> void:
	if not is_active():
		my_agent_id = ""
		return
	if role == Role.HOST:
		_grant_possession(1, "")
		return
	rpc_possess_request.rpc_id(1, "")


func is_possessing() -> bool:
	return not my_agent_id.is_empty()


## Who is driving this person — 0 when the FSM is.
func possessor_of(agent_id: String) -> int:
	return int(possessed.get(agent_id, 0))


## Host-side authority. `agent_id` empty releases whatever this peer held.
func _grant_possession(peer_id: int, agent_id: String) -> Dictionary:
	if role != Role.HOST:
		return {"ok": false, "error": "Only the host grants possession"}
	# Always release the peer's current body first, so a swap is one operation
	# and can never leave two agents flagged for one player.
	for aid in MpPossession.release_for_peer(possessed, peer_id):
		_set_agent_controller(str(aid), 0)
		possessed.erase(aid)
	if agent_id.is_empty():
		rpc_possess_sync.rpc(possessed.duplicate())
		possession_changed.emit()
		return {"ok": true, "released": true}
	var check: Dictionary = MpPossession.can_possess(agent_id, peer_id, possessed,
		_find_agent(agent_id) != null)
	if not bool(check.get("ok", false)):
		rpc_possess_sync.rpc(possessed.duplicate())
		return check
	possessed[agent_id] = peer_id
	_set_agent_controller(agent_id, peer_id)
	rpc_possess_sync.rpc(possessed.duplicate())
	possession_changed.emit()
	return {"ok": true}


func _set_agent_controller(agent_id: String, peer_id: int) -> void:
	# Through the engine, which also hands a claimed chore back to the board
	# so the crew re-forms without the possessed body (Push 2 #4).
	var view := _find_graph_view()
	var bridge = view.get("_npc_population") if view != null else null
	if bridge != null and bridge.has_method("set_agent_controller") 			and bool(bridge.call("set_agent_controller", agent_id, peer_id)):
		return
	var agent = _find_agent(agent_id)
	if agent != null:
		agent.controlled_by_peer = peer_id


@rpc("any_peer", "reliable", "call_remote")
func rpc_possess_request(agent_id: String) -> void:
	if role != Role.HOST:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0 or not note_peer_traffic(sender, MpHardeningScript.COST_CHAT):
		return
	var res := _grant_possession(sender, agent_id)
	rpc_possess_result.rpc_id(sender, bool(res.get("ok", false)),
		str(res.get("error", "")), agent_id if bool(res.get("ok", false)) else "")


@rpc("authority", "reliable", "call_remote")
func rpc_possess_result(ok: bool, error: String, agent_id: String) -> void:
	if ok:
		my_agent_id = agent_id
		_emit_status("You are now %s" % _agent_display_name(agent_id) if not agent_id.is_empty()
			else "Back to your own body", "ok")
	else:
		_emit_status(error, "warn")
	possession_changed.emit()


@rpc("authority", "reliable", "call_remote")
func rpc_possess_sync(map: Dictionary) -> void:
	possessed = map.duplicate()
	# A client's own binding is whatever the host says it is — never a local
	# guess, or a refused request would leave the two disagreeing.
	my_agent_id = MpPossession.agent_of_peer(possessed, multiplayer.get_unique_id())
	possession_changed.emit()


func _agent_display_name(agent_id: String) -> String:
	var agent = _find_agent(agent_id)
	if agent == null:
		return "someone"
	var n := str(agent.get("display_name"))
	return n if not n.is_empty() else agent_id


## Per the design decision this WARNS and never clamps: the host keeps full
## control of the clock, and a possessing player is simply told the world is
## running past them. Throttled by cooldown AND speed bracket — the clock RPC
## lands at 2 Hz, so a naive check would toast twice a second.
func _maybe_warn_time_scale() -> void:
	var main := _find_main()
	if main == null:
		return
	var verdict: Dictionary = MpPossession.time_scale_warning(
		float(main.get("time_scale")), _last_speed_warn_unix, _last_speed_bracket,
		MpHardeningScript.now_unix())
	if not bool(verdict.get("warn", false)):
		return
	_last_speed_warn_unix = MpHardeningScript.now_unix()
	_last_speed_bracket = int(verdict.get("bracket", 0))
	_emit_status(str(verdict.get("text", "")), "warn")
	if chat != null and chat.has_method("push_system"):
		chat.call("push_system", str(verdict.get("text", "")))


## Free a departing peer's body so the FSM takes over again.
func _release_possession_for_peer(peer_id: int) -> void:
	if role != Role.HOST:
		return
	var freed := MpPossession.release_for_peer(possessed, peer_id)
	if freed.is_empty():
		return
	for aid in freed:
		_set_agent_controller(str(aid), 0)
		possessed.erase(aid)
	rpc_possess_sync.rpc(possessed.duplicate())
	possession_changed.emit()
	session_changed.emit()


func _reject_peer(peer_id: int, reason: String, detail: Dictionary) -> void:
	_pending_admission.erase(peer_id)
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
		_note_inbound_reach(id)
		peer_list_changed.emit()
	session_changed.emit()


func _on_peer_disconnected(id: int) -> void:
	var left_name := str((peers.get(id, {}) as Dictionary).get("name", "Peer %d" % id))
	# Drop any in-flight verification: ENet reuses peer ids, so a late callback
	# for a departed peer must never admit whoever inherits its id.
	_pending_admission.erase(id)
	# Hand the body back to the sim, or the person stands frozen forever.
	_release_possession_for_peer(id)
	peers.erase(id)
	_remove_avatar(id)
	if design != null:
		if design.has_method("drop_peer"):
			design.call("drop_peer", id)
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
	# This candidate won the ladder; stop the timeout and forget the rest.
	_candidate_deadline_ms = 0
	_candidates.clear()
	_candidate_index = -1
	var my_id := multiplayer.get_unique_id()
	peers[my_id] = {"name": display_name, "ready": true}
	rpc_hello.rpc_id(1, {
		"name": display_name,
		"token": session_token,
		"proto": PROTOCOL_VERSION,
		"password": pending_password,
		"friend_key": pending_friend_key,
		"discord_token": _discord_token_for_join(),
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
	# The candidate ladder must intercept BEFORE the unconditional leave_session
	# this used to do — otherwise a failed LAN attempt tears the whole join down
	# and the public address is never tried.
	if _candidate_index >= 0 and _candidate_index + 1 < _candidates.size():
		_try_next_candidate()
		return
	_candidates.clear()
	_candidate_index = -1
	_candidate_deadline_ms = 0
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


func _upsert_avatar(peer_id: int, p_name: String, pos: Vector3, yaw: float,
		body: Dictionary = {}, tint: Color = Color(0, 0, 0, 0)) -> void:
	_ensure_remote_root()
	if _remote_root == null:
		return
	var av: RemotePlayerAvatar = _avatars.get(peer_id) as RemotePlayerAvatar
	if av == null or not is_instance_valid(av):
		av = RemoteAvatarScript.new() as RemotePlayerAvatar
		av.setup(peer_id, p_name)
		_remote_root.add_child(av)
		_avatars[peer_id] = av
	elif av.display_name != p_name:
		av.set_display_name(p_name)
	if tint.a > 0.0:
		av.set_rim(Color(tint.r, tint.g, tint.b, 1.0))
	av.push_snapshot(pos, yaw, body)


## The other players' figures in this world (markers, the players list).
func remote_avatars() -> Array:
	var out: Array = []
	for k in _avatars.keys():
		var av: RemotePlayerAvatar = _avatars[k] as RemotePlayerAvatar
		if av != null and is_instance_valid(av) and av.is_inside_tree():
			out.append(av)
	return out


## Where a peer is right now (their figure, or the person they possess).
func peer_world_position(peer_id: int) -> Vector3:
	var av: RemotePlayerAvatar = _avatars.get(peer_id) as RemotePlayerAvatar
	if av != null and is_instance_valid(av) and av.is_inside_tree():
		return av.global_position
	return Vector3.INF


## Stand the local player a couple of metres from another player, facing them.
func go_to_peer(peer_id: int) -> bool:
	var at := peer_world_position(peer_id)
	var main := _find_main()
	var player := main.get_node_or_null("Player") as Node3D if main != null else null
	if at == Vector3.INF or player == null:
		return false
	var away := player.global_position - at
	away.y = 0.0
	if away.length() < 0.1:
		away = Vector3(0.0, 0.0, 1.0)
	var spot := at + away.normalized() * 2.5
	var gy := TerrainSurfaceQuery.ground_height_at(main, spot.x, spot.z)
	spot.y = (gy if not is_nan(gy) else at.y) + 0.05
	player.global_position = spot
	if "velocity" in player:
		player.set("velocity", Vector3.ZERO)
	var to := at - spot
	player.rotation.y = atan2(-to.x, -to.z)
	return true


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
