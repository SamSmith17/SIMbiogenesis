class_name DiscordGateRules
extends RefCounted

## The host-side admission verdicts, as PURE functions over canned response
## bodies. No HTTP lives in this file on purpose: the security decision is the
## one thing that must be exhaustively testable offline, so `discord_gate.gd`
## does nothing but fetch and hand the bodies to these.
##
## Flow: a joiner presents its own Discord access token; the host asks Discord
## two questions.
##   1. GET /oauth2/@me  — WHICH APPLICATION was this token issued to? This is
##      the anti-replay defence. Without it a token farmed by any other Discord
##      app (there are thousands, and users grant them freely) would be accepted
##      here.
##   2. GET /users/@me/guilds/{guild}/member — is the bearer in this guild, and
##      do they hold one of the required roles?
##
## Privacy note that belongs next to the code, not only in a doc: the host does
## see a live bearer token. That is why `DiscordConfig.SCOPES_DEFAULT` omits the
## broad `guilds` scope — a leaked token then reveals identity and membership of
## THIS guild, and nothing else. The token is never persisted and never logged
## (`MpHardening.redact`). A future bot bridge removes the trade-off entirely by
## answering yes/no without any token changing hands.

## Everything the gate needs to be able to answer.
const REQUIRED_SCOPES := ["guilds.members.read"]


## {ok, user_id, username, global_name, avatar, scopes} / {ok:false, error, fatal}
##
## `fatal` distinguishes "this guest may not join" from "we could not tell" —
## the caller fails CLOSED on both by default, but only the former is worth
## showing the guest as a rejection reason.
static func check_oauth_me(body: Dictionary, our_client_id: String, now_unix: int) -> Dictionary:
	if body.is_empty():
		return {"ok": false, "error": "Discord did not recognise that sign-in", "fatal": true}

	var app: Dictionary = body.get("application", {}) as Dictionary
	var app_id := str(app.get("id", "")).strip_edges()
	var want := our_client_id.strip_edges()
	if want.is_empty():
		return {"ok": false, "error": "This build has no Discord application configured", "fatal": false}
	if app_id != want:
		# The single most important line in this file.
		return {"ok": false, "error": "That sign-in belongs to a different application", "fatal": true}

	var scopes := _string_array(body.get("scopes", []))
	for need in REQUIRED_SCOPES:
		if not scopes.has(str(need)):
			return {"ok": false, "error": "Sign-in is missing the '%s' permission — sign in again" % need, "fatal": true}

	var exp := parse_iso8601(str(body.get("expires", "")))
	if exp > 0 and exp <= now_unix:
		return {"ok": false, "error": "That Discord sign-in has expired — sign in again", "fatal": true}

	var user: Dictionary = body.get("user", {}) as Dictionary
	return {
		"ok": true,
		"user_id": str(user.get("id", "")),
		"username": str(user.get("username", "")),
		"global_name": str(user.get("global_name", "")),
		"avatar": str(user.get("avatar", "")),
		"scopes": scopes,
		"expires": exp,
	}


## {ok, roles, nick, user_id} / {ok:false, error}
##
## An EMPTY `role_ids` means membership alone suffices — that is a deliberate
## configuration statement by the host, not an oversight, and it mirrors how
## `MpHardening.trusted_key_allowed` treats an empty allowlist.
static func check_member(body: Dictionary, role_ids: Array) -> Dictionary:
	if body.is_empty():
		return {"ok": false, "error": "Not a member of this Discord server"}
	var roles := _string_array(body.get("roles", []))
	var user: Dictionary = body.get("user", {}) as Dictionary
	if role_ids.is_empty():
		return {"ok": true, "roles": roles, "nick": str(body.get("nick", "")), "user_id": str(user.get("id", ""))}
	for want in role_ids:
		if roles.has(str(want)):
			return {"ok": true, "roles": roles, "nick": str(body.get("nick", "")), "user_id": str(user.get("id", ""))}
	return {"ok": false, "error": "You need one of this community's member roles to join"}


## Map an HTTP status from either call onto a guest-facing reason.
static func error_for_status(code: int, stage: String) -> Dictionary:
	match code:
		401:
			return {"error": "Your Discord sign-in is no longer valid — sign in again", "fatal": true}
		403:
			return {"error": "Discord refused the membership check — sign in again to grant it", "fatal": true}
		404:
			if stage == "member":
				return {"error": "You are not a member of this Discord server", "fatal": true}
			return {"error": "Discord could not find that sign-in", "fatal": true}
		429:
			return {"error": "Discord is rate-limiting this host — try again in a moment", "fatal": false}
		_:
			if code >= 500:
				return {"error": "Discord is having problems (HTTP %d) — try again" % code, "fatal": false}
	return {"error": "Discord check failed (HTTP %d)" % code, "fatal": false}


## Discord timestamps look like "2026-08-12T20:07:11.898000+00:00". Godot's
## Time.get_unix_time_from_datetime_string does not accept the fractional part
## or the offset, so take the leading "YYYY-MM-DDTHH:MM:SS" and treat it as UTC
## (Discord always emits +00:00 here). Returns 0 when unparseable, which callers
## read as "no expiry information" rather than "expired".
static func parse_iso8601(s: String) -> int:
	var t := s.strip_edges()
	if t.length() < 19:
		return 0
	var head := t.substr(0, 19)
	if head[10] != "T":
		return 0
	var unix := int(Time.get_unix_time_from_datetime_string(head))
	return maxi(0, unix)


static func _string_array(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for s in (v as Array):
			out.append(str(s))
	elif v is PackedStringArray:
		for s in (v as PackedStringArray):
			out.append(str(s))
	return out
