extends Node

## Phase 5 session text chat — reliable host-relayed messages, mute list,
## Discord invite link for voice (WebRTC deferred).

signal message_received(msg: Dictionary)
signal history_changed()
signal mute_changed()

const MAX_HISTORY := 100
const MAX_MSG_LEN := 280
const PREFS_PATH := "user://mp_prefs.cfg"
const DEFAULT_DISCORD_HINT := "https://discord.gg/"

var history: Array = []  # [{peer_id, name, text, at_ms, system}]
var muted_peers: Dictionary = {}  # peer_id -> true
var discord_url: String = ""


func _ready() -> void:
	name = "Chat"
	discord_url = _load_discord_url()


func session() -> Node:
	return get_parent()


func clear_session_state() -> void:
	history.clear()
	history_changed.emit()


func send_chat(text: String) -> Dictionary:
	var s := session()
	if s == null or not s.has_method("is_active") or not bool(s.call("is_active")):
		return {"ok": false, "error": "Not in a session"}
	var cleaned := _sanitize(text)
	if cleaned.is_empty():
		return {"ok": false, "error": "Empty message"}
	var from_name := str(s.get("display_name"))
	var my_id := multiplayer.get_unique_id()
	if _is_host():
		_broadcast_chat(my_id, from_name, cleaned)
	else:
		rpc_chat_submit.rpc_id(1, cleaned, from_name)
	return {"ok": true}


func mute_peer(peer_id: int, muted: bool = true) -> void:
	if peer_id <= 0:
		return
	# Skip muting self when a session peer exists (null-safe for --script tests).
	var api := multiplayer
	if api != null and api.has_multiplayer_peer() and peer_id == api.get_unique_id():
		return
	if muted:
		muted_peers[peer_id] = true
	else:
		muted_peers.erase(peer_id)
	mute_changed.emit()


func is_muted(peer_id: int) -> bool:
	return bool(muted_peers.get(peer_id, false))


func set_discord_url(url: String) -> void:
	discord_url = url.strip_edges()
	_save_discord_url(discord_url)


func open_discord() -> Dictionary:
	var url := discord_url.strip_edges()
	if url.is_empty():
		return {"ok": false, "error": "Set a Discord invite URL in the Multiplayer lobby first"}
	if not is_valid_discord_url(url):
		return {"ok": false, "error": "Discord URL must start with https://discord.gg/ or https://discord.com/"}
	OS.shell_open(url)
	return {"ok": true, "url": url}


func push_system(text: String) -> void:
	_append({
		"peer_id": 0,
		"name": "System",
		"text": text,
		"at_ms": Time.get_ticks_msec(),
		"system": true,
	})


@rpc("any_peer", "reliable", "call_remote")
func rpc_chat_submit(text: String, from_name: String) -> void:
	if not _is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	var s := session()
	if s != null and s.has_method("note_peer_traffic"):
		if not bool(s.call("note_peer_traffic", sender, MpHardening.COST_CHAT)):
			return
	var cleaned := _sanitize(text)
	if cleaned.is_empty():
		return
	_broadcast_chat(sender, from_name, cleaned)


@rpc("authority", "reliable", "call_local")
func rpc_chat_deliver(peer_id: int, from_name: String, text: String) -> void:
	_append({
		"peer_id": peer_id,
		"name": from_name,
		"text": text,
		"at_ms": Time.get_ticks_msec(),
		"system": false,
	})


func _broadcast_chat(peer_id: int, from_name: String, text: String) -> void:
	rpc_chat_deliver.rpc(peer_id, from_name, text)


func _append(msg: Dictionary) -> void:
	var peer_id := int(msg.get("peer_id", 0))
	if peer_id > 0 and is_muted(peer_id):
		return
	history.append(msg)
	while history.size() > MAX_HISTORY:
		history.remove_at(0)
	history_changed.emit()
	message_received.emit(msg)


## Exposed for selftests (same rules as send path).
static func sanitize_message(text: String) -> String:
	var t := text.strip_edges()
	t = t.replace("\n", " ").replace("\r", " ")
	if t.length() > MAX_MSG_LEN:
		t = t.substr(0, MAX_MSG_LEN)
	return t


func _sanitize(text: String) -> String:
	return sanitize_message(text)


## Discord invite URL shape check (no network).
static func is_valid_discord_url(url: String) -> bool:
	var u := url.strip_edges()
	return u.begins_with("https://discord.gg/") or u.begins_with("https://discord.com/") \
			or u.begins_with("http://discord.gg/")


func _is_host() -> bool:
	var s := session()
	return s != null and s.has_method("is_host") and bool(s.call("is_host"))


func _load_discord_url() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return ""
	return str(cfg.get_value("mp", "discord_url", "")).strip_edges()


func _save_discord_url(url: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("mp", "discord_url", url)
	cfg.save(PREFS_PATH)
