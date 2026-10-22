class_name HaToken
extends RefCounted
## Long-lived access token checks (pure).
##
## A Home Assistant long-lived token is a JWT: three base64url parts joined by
## dots, ~180 characters. Most "the token does not work" cases are a paste
## that picked up a quote, a "Bearer " prefix, a line break or only part of
## the token; clean() fixes the first three, check() names the fourth before
## a connection attempt is wasted on it.


static func clean(raw: String) -> String:
	var s := raw.strip_edges()
	s = s.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'").strip_edges()
	if s.to_lower().begins_with("bearer "):
		s = s.substr(7).strip_edges()
	return s.replace("\n", "").replace("\r", "").replace(" ", "").replace("\t", "")


## {ok, error}. Called on a CLEANED token.
static func check(tok: String) -> Dictionary:
	if tok.is_empty():
		return {"ok": false, "error": "Paste a long-lived access token. Make one in Home Assistant: your profile → Security → Long-lived access tokens → Create token."}
	if tok == "YOUR_LONG_LIVED_TOKEN":
		return {"ok": false, "error": "That is the placeholder, not a token."}
	var parts := tok.split(".")
	if parts.size() != 3:
		return {"ok": false, "error": "This does not look like a Home Assistant token (it should have three parts separated by dots). Copy the whole token — Home Assistant shows it only once."}
	for p in parts:
		if p.is_empty() or not _is_b64url(p):
			return {"ok": false, "error": "The token has characters a Home Assistant token never contains. Copy it again."}
	if tok.length() < 100:
		return {"ok": false, "error": "The token looks cut short (%d characters; usually about 180). Copy the whole token." % tok.length()}
	return {"ok": true, "error": ""}


## "eyJh…X2s" for display.
static func masked(tok: String) -> String:
	if tok.length() <= 10:
		return "•••"
	return "%s…%s" % [tok.substr(0, 4), tok.substr(tok.length() - 3)]


static func _is_b64url(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		var ok := (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) \
			or c == 45 or c == 95 or c == 61
		if not ok:
			return false
	return true
