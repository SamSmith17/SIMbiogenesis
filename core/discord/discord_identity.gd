extends Node

## "Sign in with Discord", entirely in GDScript.
##
## Discord supports the OAuth2 authorization-code grant with **PKCE and no
## client_secret** once the application's "Public Client" toggle is enabled in
## the developer portal, so nothing secret ships in the binary and no backend of
## ours is involved. The authorization code arrives in the redirect's QUERY
## STRING (unlike the implicit grant, which puts the token in the URL fragment
## and would need a JavaScript shim to get it back), so a ~60-line loopback
## TCPServer is enough to catch it.
##
## One-time human setup is in LOCAL_CONFIG.md. The two things that fail opaquely
## if missed: "Public Client" must be ON, and every redirect URI in
## `DiscordConfig.REDIRECT_PORTS` must be registered verbatim.
##
## Everything here fails soft. No key, no network, not signed in, user pressed
## Cancel — the existing password / friend-key join path is untouched.

signal sign_in_started()
signal sign_in_completed(user: Dictionary)
signal sign_in_failed(reason: String)
signal signed_out()
signal token_refreshed()
signal membership_checked(guild_id: String, result: Dictionary)

## The browser round-trip includes a human reading a consent screen.
const SIGN_IN_TIMEOUT_SEC := 180.0
## Hold the callback socket open long enough for the browser to actually render
## the "you can close this tab" page. Closing in the same frame produces a
## connection-reset error page at exactly the moment the user needs reassurance.
const CALLBACK_FLUSH_SEC := 0.75
const REQUEST_HEADER_MAX := 8192
## Refresh when the access token has less than this left.
const REFRESH_MARGIN_SEC := 24 * 3600
const USER_CACHE_SEC := 3600
const MEMBER_CACHE_SEC := 300

var http: Node = null

var _auth: Dictionary = {}          # {access_token, refresh_token, expires_at, user, scopes, client_id}
var _client_id := ""
var _server: TCPServer = null
var _redirect := ""
var _verifier := ""
var _state := ""
var _deadline_ms := 0
var _in_flight := false
var _sockets: Array = []            # [{peer: StreamPeerTCP, close_at: float, buf: String}]
var _member_cache: Dictionary = {}  # guild_id -> {at, result}


func _ready() -> void:
	name = "DiscordIdentity"
	http = preload("res://core/discord/discord_http.gd").new()
	add_child(http)
	_load_auth()
	set_process(false)
	if has_refresh_token() and _expires_in() < REFRESH_MARGIN_SEC:
		refresh_token_now()


# ── Public API ───────────────────────────────────────────────────────────────

func is_signed_in() -> bool:
	return not str(_auth.get("access_token", "")).is_empty()


func is_signing_in() -> bool:
	return _in_flight


func user() -> Dictionary:
	return (_auth.get("user", {}) as Dictionary).duplicate(true)


func display_name() -> String:
	var u := user()
	var name := str(u.get("global_name", "")).strip_edges()
	if name.is_empty():
		name = str(u.get("username", "")).strip_edges()
	return name


func scopes() -> Array:
	return (_auth.get("scopes", []) as Array).duplicate()


func has_refresh_token() -> bool:
	return not str(_auth.get("refresh_token", "")).is_empty()


## The bearer a joiner presents to a host. Empty when not signed in, or when the
## token has already expired — sending a dead token just produces a confusing
## rejection on the host side.
func present_token() -> String:
	if not is_signed_in() or _expires_in() <= 0:
		return ""
	return str(_auth["access_token"])


## Which application this build authenticates as. "" means sign-in is not
## offered at all (no community imported and no dev override configured).
func client_id(community: Dictionary = {}) -> String:
	var resolved := DiscordConfig.resolve_client_id(community)
	if not resolved.is_empty():
		_client_id = resolved
	return resolved


func is_available(community: Dictionary = {}) -> bool:
	return not client_id(community).is_empty()


## {ok} / {ok:false, error}. Progress arrives on the signals.
func begin_sign_in(community: Dictionary = {}, extra_scopes: Array = []) -> Dictionary:
	if _in_flight:
		return {"ok": false, "error": "A Discord sign-in is already in progress"}
	var cid := client_id(community)
	if cid.is_empty():
		return {"ok": false, "error":
			"No Discord application configured — import a community file, or set [discord] client_id in %s"
			% DiscordConfig.CONFIG_PATH}

	var bound := _bind_loopback()
	if not bool(bound.get("ok", false)):
		return bound
	_redirect = str(bound["redirect"])

	var pkce: Dictionary = DiscordPkce.mint()
	_verifier = str(pkce["verifier"])
	_state = str(pkce["state"])

	var want: Array = DiscordConfig.SCOPES_DEFAULT.duplicate()
	for s in extra_scopes:
		if not want.has(str(s)):
			want.append(str(s))

	var url: String = DiscordPkce.authorize_url(cid, _redirect, want,
		str(pkce["challenge"]), _state)
	_in_flight = true
	_deadline_ms = Time.get_ticks_msec() + int(SIGN_IN_TIMEOUT_SEC * 1000.0)
	set_process(true)
	sign_in_started.emit()
	OS.shell_open(url)
	return {"ok": true}


func cancel_sign_in() -> void:
	if not _in_flight:
		return
	_end_sign_in()
	sign_in_failed.emit("Sign-in cancelled")


## Clears local state only. Discord-side authorization stays until the user
## revokes it in their Discord settings — say so in the UI rather than implying
## this is a full revoke.
func sign_out() -> void:
	_auth = {}
	_member_cache.clear()
	if FileAccess.file_exists(DiscordConfig.AUTH_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DiscordConfig.AUTH_PATH))
	signed_out.emit()


func refresh_token_now() -> void:
	if not has_refresh_token():
		return
	var cid := str(_auth.get("client_id", _client_id))
	if cid.is_empty():
		cid = client_id()
	if cid.is_empty():
		return
	http.call("post_form", DiscordConfig.TOKEN_URL,
		DiscordPkce.token_refresh_body(cid, str(_auth["refresh_token"])),
		_on_refresh_response)


## Membership + roles in one guild, cached briefly. Result is delivered on
## `membership_checked` as {ok, roles, nick, user_id} / {ok:false, error}.
func fetch_membership(guild_id: String, force: bool = false) -> void:
	if not DiscordConfig.is_snowflake(guild_id):
		membership_checked.emit(guild_id, {"ok": false, "error": "Invalid guild id"})
		return
	if not force:
		var cached: Dictionary = _member_cache.get(guild_id, {}) as Dictionary
		if not cached.is_empty() and Time.get_unix_time_from_system() - float(cached["at"]) < MEMBER_CACHE_SEC:
			membership_checked.emit(guild_id, (cached["result"] as Dictionary).duplicate(true))
			return
	var token := present_token()
	if token.is_empty():
		membership_checked.emit(guild_id, {"ok": false, "error": "Not signed in to Discord"})
		return
	var url := "%s/guilds/%s/member" % [DiscordConfig.USERS_ME_URL, guild_id]
	http.call("get_json", url, func(res: Dictionary) -> void:
		var out: Dictionary
		if bool(res.get("ok", false)):
			out = DiscordGateRules.check_member(res.get("body", {}) as Dictionary, [])
		else:
			var mapped: Dictionary = DiscordGateRules.error_for_status(int(res.get("code", 0)), "member")
			out = {"ok": false, "error": str(mapped["error"])}
		_member_cache[guild_id] = {"at": Time.get_unix_time_from_system(), "result": out}
		membership_checked.emit(guild_id, out.duplicate(true)), token)


## Does the signed-in user hold at least one of these roles? Reads the cache
## only — call `fetch_membership` first.
func cached_roles(guild_id: String) -> Array:
	var cached: Dictionary = _member_cache.get(guild_id, {}) as Dictionary
	if cached.is_empty():
		return []
	return ((cached["result"] as Dictionary).get("roles", []) as Array).duplicate()


func status_text() -> String:
	if _in_flight:
		return "Waiting for Discord in your browser…"
	if not is_signed_in():
		return "Not signed in to Discord"
	if http != null and bool(http.get("offline")):
		return "Signed in as %s (Discord unreachable)" % display_name()
	return "Signed in as %s" % display_name()


# ── Loopback callback server ─────────────────────────────────────────────────

func _bind_loopback() -> Dictionary:
	_close_server()
	_server = TCPServer.new()
	for port in DiscordConfig.REDIRECT_PORTS:
		if _server.listen(int(port), "127.0.0.1") == OK:
			return {"ok": true, "redirect": DiscordConfig.redirect_uri(int(port))}
	_server = null
	# There is no runtime workaround: the redirect URI must be one Discord
	# already has on file, so an unregistered port would fail with an opaque
	# `invalid_request` after the user had already consented.
	return {"ok": false, "error":
		"Ports %s are all busy — close any other copy of SIMbiogenesis and try again"
		% str(DiscordConfig.REDIRECT_PORTS)}


func _process(_delta: float) -> void:
	_pump_sockets()
	if not _in_flight:
		if _sockets.is_empty():
			set_process(false)
		return
	if _server != null and _server.is_connection_available():
		var peer := _server.take_connection()
		if peer != null:
			_sockets.append({"peer": peer, "close_at": 0.0, "buf": ""})
	if Time.get_ticks_msec() > _deadline_ms:
		_end_sign_in()
		sign_in_failed.emit("Timed out waiting for Discord — the browser tab was never completed")


func _pump_sockets() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var keep: Array = []
	for entry_v in _sockets:
		var entry: Dictionary = entry_v
		var peer: StreamPeerTCP = entry["peer"]
		if peer == null:
			continue
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		# Already answered — hold briefly so the response actually flushes.
		if float(entry["close_at"]) > 0.0:
			if now >= float(entry["close_at"]):
				peer.disconnect_from_host()
				continue
			keep.append(entry)
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			var chunk: Array = peer.get_partial_data(mini(avail, REQUEST_HEADER_MAX))
			if chunk.size() == 2 and chunk[0] == OK:
				entry["buf"] = str(entry["buf"]) + (chunk[1] as PackedByteArray).get_string_from_utf8()
		var buf := str(entry["buf"])
		if buf.length() > REQUEST_HEADER_MAX:
			peer.disconnect_from_host()
			continue
		var line_end := buf.find("\r\n")
		if line_end < 0:
			keep.append(entry)
			continue
		var parsed: Dictionary = DiscordPkce.parse_callback(buf.substr(0, line_end))
		if str(parsed.get("path", "")) != DiscordConfig.REDIRECT_PATH:
			# favicon probes and the like — never mistake these for the callback.
			_respond(peer, 404, "Not found")
			entry["close_at"] = now + 0.1
			keep.append(entry)
			continue
		_respond(peer, 200, _callback_page(bool(parsed.get("ok", false))
			and str(parsed.get("error", "")).is_empty()))
		entry["close_at"] = now + CALLBACK_FLUSH_SEC
		keep.append(entry)
		_handle_callback(parsed)
	_sockets = keep


func _handle_callback(parsed: Dictionary) -> void:
	if not _in_flight:
		return
	var err := str(parsed.get("error", ""))
	if not err.is_empty():
		_end_sign_in()
		sign_in_failed.emit("Discord sign-in declined (%s)" % err)
		return
	if str(parsed.get("state", "")) != _state:
		# CSRF guard: a callback we did not initiate.
		_end_sign_in()
		sign_in_failed.emit("Sign-in response did not match this request")
		return
	var code := str(parsed.get("code", ""))
	if code.is_empty():
		_end_sign_in()
		sign_in_failed.emit("Discord returned no authorization code")
		return
	var cid := _client_id if not _client_id.is_empty() else client_id()
	http.call("post_form", DiscordConfig.TOKEN_URL,
		DiscordPkce.token_exchange_body(cid, code, _redirect, _verifier),
		_on_token_response)


func _respond(peer: StreamPeerTCP, code: int, body: String) -> void:
	var bytes := body.to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
		code, "OK" if code == 200 else "Not Found", bytes.size()]
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(bytes)


func _callback_page(ok: bool) -> String:
	var title := "Signed in" if ok else "Sign-in cancelled"
	var msg := "You can close this tab and go back to SIMbiogenesis." if ok \
		else "Nothing was changed. You can close this tab."
	return """<!doctype html><meta charset="utf-8"><title>SIMbiogenesis</title>
<body style="margin:0;display:grid;place-items:center;height:100vh;background:#0b1020;color:#e6edf3;font:16px/1.5 system-ui,sans-serif">
<div style="text-align:center;max-width:32rem;padding:2rem">
<div style="font-size:2rem;margin-bottom:.5rem">%s</div>
<p style="color:#9fb0c0">%s</p></div></body>""" % [title, msg]


func _end_sign_in() -> void:
	_in_flight = false
	_verifier = ""
	_state = ""
	_deadline_ms = 0
	_close_server()


func _close_server() -> void:
	if _server != null:
		_server.stop()
		_server = null


# ── Token handling ───────────────────────────────────────────────────────────

func _on_token_response(res: Dictionary) -> void:
	_end_sign_in()
	if not bool(res.get("ok", false)):
		var why := str(res.get("error", "Token exchange failed"))
		if int(res.get("code", 0)) == 401:
			# Overwhelmingly the most common setup mistake, and Discord's own
			# error text does not mention it.
			why += " — check that 'Public Client' is enabled for this application"
		sign_in_failed.emit(why)
		return
	_store_token(res.get("body", {}) as Dictionary)
	_fetch_self(func() -> void:
		sign_in_completed.emit(user()))


func _on_refresh_response(res: Dictionary) -> void:
	if not bool(res.get("ok", false)):
		# invalid_grant means the refresh token is dead — clear it rather than
		# retrying forever, and let the UI prompt one clean re-authorization.
		if int(res.get("code", 0)) == 400:
			_auth = {}
			_save_auth()
			signed_out.emit()
		return
	_store_token(res.get("body", {}) as Dictionary)
	token_refreshed.emit()


func _store_token(body: Dictionary) -> void:
	var access := str(body.get("access_token", "")).strip_edges()
	if access.is_empty():
		return
	var expires_in := int(body.get("expires_in", 0))
	_auth["access_token"] = access
	_auth["refresh_token"] = str(body.get("refresh_token", _auth.get("refresh_token", "")))
	_auth["expires_at"] = int(Time.get_unix_time_from_system()) + maxi(60, expires_in)
	# Store as a plain Array: `String.split` hands back a PackedStringArray,
	# which does not survive the `as Array` casts every consumer uses.
	var granted: Array = []
	for s in str(body.get("scope", "")).split(" ", false):
		granted.append(str(s))
	_auth["scopes"] = granted
	_auth["client_id"] = _client_id if not _client_id.is_empty() else client_id()
	_member_cache.clear()
	_save_auth()


func _fetch_self(then: Callable = Callable()) -> void:
	var token := present_token()
	if token.is_empty():
		if then.is_valid():
			then.call()
		return
	http.call("get_json", DiscordConfig.USERS_ME_URL, func(res: Dictionary) -> void:
		if bool(res.get("ok", false)):
			var b: Dictionary = res.get("body", {}) as Dictionary
			_auth["user"] = {
				"id": str(b.get("id", "")),
				"username": str(b.get("username", "")),
				"global_name": str(b.get("global_name", "")),
				"avatar": str(b.get("avatar", "")),
			}
			_auth["user_at"] = int(Time.get_unix_time_from_system())
			_save_auth()
		if then.is_valid():
			then.call(), token)


func _expires_in() -> int:
	var at := int(_auth.get("expires_at", 0))
	if at <= 0:
		return 0
	return at - int(Time.get_unix_time_from_system())


# ── Persistence ──────────────────────────────────────────────────────────────
#
# Plain ConfigFile under user://, matching every other credential in this
# project (see LOCAL_CONFIG.md). It holds a real refresh token, so it is named
# explicitly in .gitignore even though user:// is outside the repo.

func _load_auth() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(DiscordConfig.AUTH_PATH) != OK:
		return
	_auth = {
		"access_token": str(cfg.get_value("auth", "access_token", "")),
		"refresh_token": str(cfg.get_value("auth", "refresh_token", "")),
		"expires_at": int(cfg.get_value("auth", "expires_at", 0)),
		"scopes": cfg.get_value("auth", "scopes", []),
		"client_id": str(cfg.get_value("auth", "client_id", "")),
		"user": {
			"id": str(cfg.get_value("user", "id", "")),
			"username": str(cfg.get_value("user", "username", "")),
			"global_name": str(cfg.get_value("user", "global_name", "")),
			"avatar": str(cfg.get_value("user", "avatar", "")),
		},
	}
	_client_id = str(_auth.get("client_id", ""))


func _save_auth() -> void:
	var cfg := ConfigFile.new()
	if _auth.is_empty():
		cfg.save(DiscordConfig.AUTH_PATH)
		return
	cfg.set_value("auth", "access_token", str(_auth.get("access_token", "")))
	cfg.set_value("auth", "refresh_token", str(_auth.get("refresh_token", "")))
	cfg.set_value("auth", "expires_at", int(_auth.get("expires_at", 0)))
	cfg.set_value("auth", "scopes", _auth.get("scopes", []))
	cfg.set_value("auth", "client_id", str(_auth.get("client_id", "")))
	var u: Dictionary = _auth.get("user", {}) as Dictionary
	for k in ["id", "username", "global_name", "avatar"]:
		cfg.set_value("user", k, str(u.get(k, "")))
	cfg.save(DiscordConfig.AUTH_PATH)
