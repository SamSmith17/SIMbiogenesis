extends Node

## Host-side Discord admission: "is this joiner a member of our Discord server,
## with one of the roles we require?"
##
## This file only FETCHES. Every verdict comes from `DiscordGateRules`, which is
## pure and fed canned bodies by `discord_selftest.gd` — a security decision
## that can only be exercised against a live Discord app is a security decision
## nobody ever tests.
##
## Two calls, in this order:
##   1. `GET /oauth2/@me` — proves the presented token was issued to OUR
##      application. Without this, a token the guest granted to any of the
##      thousands of other Discord apps would be accepted here.
##   2. `GET /users/@me/guilds/{guild}/member` — membership and roles.
##
## Privacy: the host briefly holds a guest's bearer token. It is never
## persisted, never logged (`MpHardening.redact` strips it at the telemetry
## choke point), and the verification cache keys on a HASH of it, never the
## token. The scope set is minimal by design (`identify` +
## `guilds.members.read`), so the worst a leak reveals is identity and
## membership of this one server. `DiscordBridge` removes the trade-off
## entirely once someone runs a bot.

signal verified(peer_id: int, result: Dictionary)

const CACHE_SEC := 600.0

## Set by whoever runs a bot. Null in v1 — see discord_bridge.gd.
var bridge: DiscordBridge = null

var _http: Node = null
var _cache: Dictionary = {}  # token_hash -> {at, result}


func _ready() -> void:
	name = "DiscordGate"


func _http_client() -> Node:
	if _http != null and is_instance_valid(_http):
		return _http
	# Reuse the identity autoload's client so per-route rate limiting and the
	# discord.com-only Authorization allowlist stay in one place.
	var id := get_node_or_null("/root/DiscordIdentity")
	if id != null:
		_http = id.get("http")
	return _http


## Verify `token` against `community`, then emit `verified(peer_id, result)`.
## result: {ok, user_id, username, nick, avatar, roles} / {ok:false, error, fatal}
func verify(peer_id: int, token: String, community: Dictionary) -> void:
	var guild := str(community.get("guild_id", "")).strip_edges()
	var roles: Array = community.get("role_ids", []) as Array
	if not DiscordConfig.is_snowflake(guild):
		_finish(peer_id, {"ok": false, "error": "This host's community is misconfigured", "fatal": false})
		return

	# A bot, if one exists, answers without any token changing hands.
	if bridge != null and bridge.is_ready():
		bridge.verify_member(str(community.get("user_id", "")), guild, roles,
			func(res: Dictionary) -> void: _finish(peer_id, res))
		return

	if token.strip_edges().is_empty():
		_finish(peer_id, {"ok": false,
			"error": "This session needs a Discord sign-in — sign in and rejoin", "fatal": true})
		return

	var key := _token_key(token)
	var cached: Dictionary = _cache.get(key, {}) as Dictionary
	if not cached.is_empty() and Time.get_ticks_msec() / 1000.0 - float(cached["at"]) < CACHE_SEC:
		# A reconnect loop must not hammer Discord on the host's rate budget.
		_finish(peer_id, (cached["result"] as Dictionary).duplicate(true))
		return

	var http := _http_client()
	if http == null:
		_finish(peer_id, {"ok": false, "error": "Discord check unavailable on this host", "fatal": false})
		return

	var want_client := DiscordConfig.resolve_client_id(community)
	http.call("get_json", DiscordConfig.OAUTH_ME_URL, func(res: Dictionary) -> void:
		_on_oauth_me(peer_id, token, guild, roles, want_client, res), token)


func _on_oauth_me(peer_id: int, token: String, guild: String, roles: Array,
		want_client: String, res: Dictionary) -> void:
	if not bool(res.get("ok", false)):
		var mapped: Dictionary = DiscordGateRules.error_for_status(int(res.get("code", 0)), "me")
		_finish(peer_id, {"ok": false, "error": str(mapped["error"]), "fatal": bool(mapped["fatal"])})
		return
	var verdict: Dictionary = DiscordGateRules.check_oauth_me(
		res.get("body", {}) as Dictionary, want_client, int(Time.get_unix_time_from_system()))
	if not bool(verdict.get("ok", false)):
		_finish(peer_id, verdict)
		return

	var http := _http_client()
	if http == null:
		_finish(peer_id, {"ok": false, "error": "Discord check unavailable on this host", "fatal": false})
		return
	var url := "%s/guilds/%s/member" % [DiscordConfig.USERS_ME_URL, guild]
	http.call("get_json", url, func(res2: Dictionary) -> void:
		_on_member(peer_id, token, roles, verdict, res2), token)


func _on_member(peer_id: int, token: String, roles: Array, identity: Dictionary,
		res: Dictionary) -> void:
	var out: Dictionary
	if bool(res.get("ok", false)):
		out = DiscordGateRules.check_member(res.get("body", {}) as Dictionary, roles)
		if bool(out.get("ok", false)):
			out["user_id"] = str(identity.get("user_id", out.get("user_id", "")))
			out["username"] = str(identity.get("username", ""))
			out["global_name"] = str(identity.get("global_name", ""))
			out["avatar"] = str(identity.get("avatar", ""))
		else:
			out["fatal"] = true
	else:
		var mapped: Dictionary = DiscordGateRules.error_for_status(int(res.get("code", 0)), "member")
		out = {"ok": false, "error": str(mapped["error"]), "fatal": bool(mapped["fatal"])}

	# Only cache decisive answers — a transient Discord outage must not pin a
	# rejection for ten minutes.
	if bool(out.get("ok", false)) or bool(out.get("fatal", false)):
		_cache[_token_key(token)] = {"at": Time.get_ticks_msec() / 1000.0, "result": out.duplicate(true)}
	_finish(peer_id, out)


func clear_cache() -> void:
	_cache.clear()


func _finish(peer_id: int, result: Dictionary) -> void:
	verified.emit(peer_id, result)


## The cache key is a hash so the token itself never sits in a dictionary that
## could end up in a debug dump.
static func _token_key(token: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(token.to_utf8_buffer())
	return ctx.finish().hex_encode()
