class_name DiscordPkce
extends RefCounted

## PKCE (RFC 7636) code verifier / challenge, plus the OAuth2 `state` nonce.
##
## Discord supports authorization-code + PKCE with NO client_secret once the
## application's "Public Client" toggle is enabled in the developer portal, so
## the whole sign-in flow fits in GDScript with nothing secret shipped in the
## binary. Without that toggle every token exchange returns 401 — see
## LOCAL_CONFIG.md for the one-time portal checklist.
##
## Pure and deterministic apart from `mint()`; `challenge_for()` is pinned
## against the RFC 7636 Appendix B vector in discord_selftest.gd because a
## base64url or padding slip here fails as an opaque `invalid_grant` at the
## token endpoint rather than as anything diagnosable.

## RFC 7636 §4.1: 43-128 chars from unreserved [A-Za-z0-9-._~].
## 32 random bytes -> 43 base64url chars, the shortest legal verifier.
const VERIFIER_BYTES := 32
const MIN_VERIFIER_LEN := 43
const MAX_VERIFIER_LEN := 128
const CHALLENGE_METHOD := "S256"


## A fresh {verifier, challenge, method, state} for one sign-in attempt.
static func mint() -> Dictionary:
	var verifier := _random_b64url(VERIFIER_BYTES)
	return {
		"verifier": verifier,
		"challenge": challenge_for(verifier),
		"method": CHALLENGE_METHOD,
		"state": _random_b64url(VERIFIER_BYTES),
	}


## base64url(SHA-256(ascii(verifier))), unpadded. The only method Discord's own
## SDK uses, and the only one we offer — `plain` would defeat the point.
static func challenge_for(verifier: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(verifier.to_ascii_buffer())
	return DiscordConfig.b64url(ctx.finish())


## Shape check for a verifier we generated or read back from disk.
static func is_valid_verifier(verifier: String) -> bool:
	var n := verifier.length()
	if n < MIN_VERIFIER_LEN or n > MAX_VERIFIER_LEN:
		return false
	for i in n:
		if not _is_unreserved(verifier.unicode_at(i)):
			return false
	return true


## The authorize URL the browser is sent to. Every value is uri-encoded because
## `state` and `challenge` are base64url (which is URL-safe) but `redirect_uri`
## and the scope separator are not.
static func authorize_url(client_id: String, redirect: String, scopes: Array,
		challenge: String, state: String) -> String:
	var scope_list := PackedStringArray()
	for s in scopes:
		scope_list.append(str(s))
	var q := PackedStringArray([
		"client_id=%s" % client_id.uri_encode(),
		"response_type=code",
		"redirect_uri=%s" % redirect.uri_encode(),
		"scope=%s" % " ".join(scope_list).uri_encode(),
		"code_challenge=%s" % challenge.uri_encode(),
		"code_challenge_method=%s" % CHALLENGE_METHOD,
		"state=%s" % state.uri_encode(),
		"prompt=consent",
	])
	return "%s?%s" % [DiscordConfig.AUTHORIZE_URL, "&".join(q)]


## Form body for POST /oauth2/token. No client_secret: that is the whole point
## of the public-client + PKCE combination.
static func token_exchange_body(client_id: String, code: String, redirect: String,
		verifier: String) -> String:
	return _form({
		"client_id": client_id,
		"grant_type": "authorization_code",
		"code": code,
		"redirect_uri": redirect,
		"code_verifier": verifier,
	})


static func token_refresh_body(client_id: String, refresh_token: String) -> String:
	return _form({
		"client_id": client_id,
		"grant_type": "refresh_token",
		"refresh_token": refresh_token,
	})


## Parse the request line of the loopback callback: extracts `code`/`state`, or
## `error`/`error_description` when the user pressed Cancel.
## Returns {ok, path, code, state, error}. `ok` only means "this is our
## callback path and it carried something we understand".
static func parse_callback(request_line: String) -> Dictionary:
	# "GET /cb?code=…&state=… HTTP/1.1"
	var parts := request_line.strip_edges().split(" ", false)
	if parts.size() < 2:
		return {"ok": false, "path": "", "error": "malformed request"}
	var target := parts[1]
	var qi := target.find("?")
	var path := target if qi < 0 else target.substr(0, qi)
	var out := {"ok": false, "path": path, "code": "", "state": "", "error": ""}
	if path != DiscordConfig.REDIRECT_PATH:
		# favicon probes and the like — 404 them, never treat as the callback.
		return out
	if qi < 0:
		out["error"] = "no query"
		return out
	for pair in target.substr(qi + 1).split("&", false):
		var eq := pair.find("=")
		if eq <= 0:
			continue
		var k := pair.substr(0, eq)
		var v := pair.substr(eq + 1).uri_decode()
		match k:
			"code": out["code"] = v
			"state": out["state"] = v
			"error": out["error"] = v
			"error_description":
				if str(out["error"]).is_empty():
					out["error"] = v
	out["ok"] = not (str(out["code"]).is_empty() and str(out["error"]).is_empty())
	return out


static func _form(fields: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in fields:
		parts.append("%s=%s" % [str(k).uri_encode(), str(fields[k]).uri_encode()])
	return "&".join(parts)


static func _random_b64url(n: int) -> String:
	var crypto := Crypto.new()
	return DiscordConfig.b64url(crypto.generate_random_bytes(n))


static func _is_unreserved(c: int) -> bool:
	if c >= 65 and c <= 90:   # A-Z
		return true
	if c >= 97 and c <= 122:  # a-z
		return true
	if c >= 48 and c <= 57:   # 0-9
		return true
	return c == 45 or c == 46 or c == 95 or c == 126  # - . _ ~
