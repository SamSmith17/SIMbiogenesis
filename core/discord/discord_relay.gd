extends Node

## Mirrors in-game chat into the community's Discord channel.
##
## **Host only.** `rpc_chat_deliver` is `call_local`, so `MpChatController._append`
## runs on the host for every message including its own — relaying from each
## client instead would post every message N times and would hand every client
## the webhook write credential.
##
## **Outbound only.** A webhook can only read back messages it wrote itself;
## reading a channel needs a gateway connection and therefore a bot token. That
## direction is `DiscordBridge`'s job and is deliberately out of scope here —
## nobody should lose a day rediscovering the limitation.
##
## All the batching rules (≤2 executes per flush, the 2000-char cap, the
## overflow line, 429 backoff, and `allowed_mentions.parse == []`) live in the
## pure `DiscordRelayBatcher` so they are selftested offline.
##
## Off by default, and turning it on ANNOUNCES itself in game. Mirroring
## people's chat into a semi-public channel without telling them is a trust
## violation; the notice is part of the feature, not a nicety.

signal relay_state_changed()
## Defined now, unimplemented in v1 — the seam a future bot feeds.
signal inbound_message(author: String, text: String, discord_user_id: String)

var enabled := false
var last_error := ""

var _community: Dictionary = {}
var _batcher: DiscordRelayBatcher = DiscordRelayBatcher.new()
var _http: Node = null
var _accum := 0.0
var _in_flight := false


func _ready() -> void:
	name = "Relay"
	set_process(false)


func session() -> Node:
	return get_parent()


func set_community(community: Dictionary) -> void:
	_community = community.duplicate(true)
	_batcher.configure(str(_community.get("name", "SIMbiogenesis")))
	if enabled and not is_configured():
		set_enabled(false)


func is_configured() -> bool:
	return SimCommunity.is_webhook_url(str(_community.get("relay_webhook", "")))


## {ok} / {ok:false, error}
func set_enabled(on: bool) -> Dictionary:
	if on and not is_configured():
		return {"ok": false, "error": "This community has no chat-relay webhook"}
	if on and not _is_host():
		return {"ok": false, "error": "Only the host mirrors chat to Discord"}
	if enabled == on:
		return {"ok": true}
	enabled = on
	_batcher.clear()
	set_process(enabled)
	_announce(enabled)
	relay_state_changed.emit()
	return {"ok": true}


## Called by MpChatController's `message_received`.
func on_chat_message(msg: Dictionary) -> void:
	if not enabled or not _is_host():
		return
	if bool(msg.get("system", false)):
		return  # locally-pushed join/leave noise stays in game
	var peer_id := int(msg.get("peer_id", 0))
	# A BROADCAST system line (peer 0) arrives with `system: false`, because
	# `rpc_chat_deliver` hardcodes that field — so the relay's own "chat is
	# being mirrored" notice would otherwise be copied straight into the
	# channel. Real peer ids are always >= 1.
	if peer_id <= 0:
		return
	_batcher.enqueue(str(msg.get("name", "Player")), str(msg.get("text", "")),
		_avatar_for(peer_id))


func status_text() -> String:
	if not is_configured():
		return "No chat-relay webhook in this community file."
	if not enabled:
		return "In-game chat stays in game."
	if not last_error.is_empty():
		return last_error
	return "Mirroring in-game chat to %s" % str(_community.get("text_channel_hint", "Discord"))


# ── Pump ─────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not enabled or _in_flight:
		return
	_accum += delta
	if _accum < DiscordRelayBatcher.FLUSH_SEC:
		return
	_accum = 0.0
	var now := Time.get_ticks_msec() / 1000.0
	var payloads: Array = _batcher.build_flush(now)
	if payloads.is_empty():
		return
	_send_next(payloads, 0)


func _send_next(payloads: Array, index: int) -> void:
	if index >= payloads.size():
		_in_flight = false
		return
	var http := _http_client()
	if http == null:
		_in_flight = false
		return
	_in_flight = true
	var payload: Dictionary = payloads[index]
	http.call("post_json", str(_community.get("relay_webhook", "")), payload,
		func(res: Dictionary) -> void: _on_sent(res, payloads, index))


func _on_sent(res: Dictionary, payloads: Array, index: int) -> void:
	if bool(res.get("ok", false)):
		_batcher.note_success()
		last_error = ""
		_send_next(payloads, index + 1)
		return
	var code := int(res.get("code", 0))
	if code == 429:
		# Requeue at the FRONT so ordering survives, and stop this flush.
		for i in range(payloads.size() - 1, index - 1, -1):
			_batcher.requeue_payload(payloads[i] as Dictionary)
		var wait: float = _batcher.note_429(float(res.get("retry_after", 1.0)),
			Time.get_ticks_msec() / 1000.0)
		last_error = "Discord is rate-limiting the relay — pausing %.0fs" % wait
		# Warn IN GAME, never into the channel we are being throttled by.
		_push_system(last_error)
		_in_flight = false
		return
	if code == 404:
		last_error = "The chat-relay webhook was deleted in Discord — relay off"
		_push_system(last_error)
		set_enabled(false)
		_in_flight = false
		return
	last_error = str(res.get("error", "Chat relay failed"))
	_in_flight = false


# ── helpers ──────────────────────────────────────────────────────────────────

func _http_client() -> Node:
	if _http != null and is_instance_valid(_http):
		return _http
	var id := get_node_or_null("/root/DiscordIdentity")
	if id != null:
		_http = id.get("http")
	return _http


func _is_host() -> bool:
	var s := session()
	return s != null and s.has_method("is_host") and bool(s.call("is_host"))


## A verified guest's real Discord avatar, so relayed lines read like real
## Discord messages rather than a wall of identical webhook posts.
func _avatar_for(peer_id: int) -> String:
	var s := session()
	if s == null:
		return ""
	var peers: Dictionary = s.get("peers") as Dictionary
	var entry: Dictionary = peers.get(peer_id, {}) as Dictionary
	var dsc: Dictionary = entry.get("discord", {}) as Dictionary
	return DiscordLinks.avatar_url(str(dsc.get("user_id", "")), str(dsc.get("avatar", "")))


## The line every participant must see while the relay is on — including anyone
## who joins later, which is why MultiplayerSession sends it on admission too.
func notice_text() -> String:
	if not enabled:
		return ""
	return "⚠ Chat is being mirrored to %s — anyone in that Discord channel can read it." % \
		str(_community.get("text_channel_hint", "your community's Discord channel"))


func _announce(on: bool) -> void:
	# Broadcast, not push_system: `push_system` only appends locally, so the
	# people whose messages are being copied out would never be told.
	_broadcast_system(notice_text() if on else "Chat mirroring to Discord is off.")


func _broadcast_system(text: String) -> void:
	if text.is_empty():
		return
	var s := session()
	if s == null:
		return
	var chat: Node = s.get("chat")
	if chat == null:
		return
	if _is_host() and chat.has_method("_broadcast_chat"):
		chat.call("_broadcast_chat", 0, "System", text)
		return
	_push_system(text)


func _push_system(text: String) -> void:
	var s := session()
	if s == null:
		return
	var chat: Node = s.get("chat")
	if chat != null and chat.has_method("push_system"):
		chat.call("push_system", text)
