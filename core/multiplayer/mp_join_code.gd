class_name MpJoinCode
extends RefCounted

## Compact join-code codec for listen-server sessions.
## Embeds host address(es), port, session token, map identity, expiry, whether
## a host password is required (password itself is never in the code), and
## whether the host requires a Discord sign-in.

const PREFIX := "SMB2:"
## v2 added exp (unix) + has_pw.
## v3 adds `addrs` (an ordered LAN/public candidate list) + `dsc` (Discord gate
## hint). v3 STILL mirrors the LAN address into the top-level `ip`/`port`, so
## every existing consumer — `_connect_pending()` reading `_pending_join["ip"]`,
## the LAN beacon, the lobby — keeps working with no edits and the ladder is
## purely additive.
const PROTOCOL_VERSION := 3
## Codes already pasted into a Discord message must keep working, so decode
## accepts the older version too. This single line is what makes that true.
const SUPPORTED_VERSIONS := [2, 3]


static func encode(payload: Dictionary) -> Dictionary:
	var addrs := _normalize_addrs(payload)
	var lan := _first_of_kind(addrs, "lan")
	var any: Dictionary = lan if not lan.is_empty() else (addrs[0] if not addrs.is_empty() else {})
	var body := {
		"v": PROTOCOL_VERSION,
		# Kept for back-compat: the LAN address (or the only address we have).
		"ip": str(any.get("h", payload.get("ip", ""))),
		"port": int(any.get("p", payload.get("port", 0))),
		"addrs": addrs,
		"token": str(payload.get("token", "")),
		"name": str(payload.get("name", "Session")),
		"map": (payload.get("map", {}) as Dictionary).duplicate(true),
		"exp": int(payload.get("exp", 0)),
		"has_pw": bool(payload.get("has_pw", false)),
		"dsc": _normalize_dsc(payload.get("dsc", {})),
	}
	if body["ip"].is_empty() or int(body["port"]) <= 0:
		return {"ok": false, "error": "Join code needs ip and port"}
	if int(body["exp"]) <= 0:
		body["exp"] = MpHardening.expiry_unix()
	var raw := JSON.stringify(body).to_utf8_buffer()
	var compressed := raw.compress(FileAccess.COMPRESSION_GZIP)
	return {
		"ok": true,
		"code": PREFIX + Marshalls.raw_to_base64(compressed),
		"payload": body,
	}


static func decode(code: String, now_unix: int = -1) -> Dictionary:
	var trimmed := code.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "error": "Empty join code"}
	# Allow pasting "ip:port" as a bare fallback (no map / expiry hand-off).
	if not trimmed.begins_with(PREFIX):
		var bare := _parse_ip_port(trimmed)
		if bool(bare.get("ok", false)):
			return {
				"ok": true,
				"ip": str(bare.get("ip", "")),
				"port": int(bare.get("port", 0)),
				"addrs": [{"h": str(bare.get("ip", "")), "p": int(bare.get("port", 0)), "k": "any"}],
				"token": "",
				"name": "Direct",
				"map": {},
				"exp": 0,
				"has_pw": false,
				"dsc": {},
				"bare": true,
			}
		return {"ok": false, "error": "Join code must start with %s (or ip:port)" % PREFIX}
	var b64 := trimmed.substr(PREFIX.length())
	var compressed := Marshalls.base64_to_raw(b64)
	if compressed.is_empty():
		return {"ok": false, "error": "Invalid join-code encoding"}
	var raw := compressed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {"ok": false, "error": "Could not decompress join code"}
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not (parsed is Dictionary):
		return {"ok": false, "error": "Invalid join-code JSON"}
	var body: Dictionary = parsed as Dictionary
	var ver := int(body.get("v", 0))
	if not SUPPORTED_VERSIONS.has(ver):
		return {"ok": false, "error": "Incompatible protocol version %d (need %d)" % [
			ver, PROTOCOL_VERSION]}
	var ip := str(body.get("ip", ""))
	var port := int(body.get("port", 0))
	if ip.is_empty() or port <= 0:
		return {"ok": false, "error": "Join code missing host address"}
	var exp := int(body.get("exp", 0))
	if MpHardening.is_expired(exp, now_unix):
		return {"ok": false, "error": "Join code expired — ask the host for a fresh code"}
	# A v2 code carries exactly one address and no Discord hint.
	var addrs := _normalize_addrs(body)
	if addrs.is_empty():
		addrs = [{"h": ip, "p": port, "k": "lan"}]
	return {
		"ok": true,
		"ip": ip,
		"port": port,
		"addrs": addrs,
		"token": str(body.get("token", "")),
		"name": str(body.get("name", "Session")),
		"map": (body.get("map", {}) as Dictionary).duplicate(true),
		"exp": exp,
		"has_pw": bool(body.get("has_pw", false)),
		"dsc": _normalize_dsc(body.get("dsc", {})),
		"bare": false,
	}


## True when the host told us up front that a Discord sign-in is required, so
## the lobby can prompt BEFORE connecting rather than letting the peer connect
## and be kicked.
static func needs_discord(decoded: Dictionary) -> bool:
	return bool((decoded.get("dsc", {}) as Dictionary).get("need", false))


static func discord_guild(decoded: Dictionary) -> String:
	return str((decoded.get("dsc", {}) as Dictionary).get("g", ""))


static func _normalize_addrs(body: Dictionary) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	var raw: Variant = body.get("addrs", [])
	if raw is Array:
		for a_v in (raw as Array):
			if not (a_v is Dictionary):
				continue
			var a: Dictionary = a_v
			var h := str(a.get("h", "")).strip_edges()
			var p := int(a.get("p", 0))
			if h.is_empty() or p <= 0 or p > 65535:
				continue
			var key := "%s:%d" % [h, p]
			if seen.has(key):
				continue
			seen[key] = true
			var kind := str(a.get("k", "any"))
			out.append({"h": h, "p": p, "k": kind if kind in ["lan", "pub", "any"] else "any"})
	# A v2 body (or a caller that only supplied ip/port) still yields one entry.
	var ip := str(body.get("ip", "")).strip_edges()
	var port := int(body.get("port", 0))
	if not ip.is_empty() and port > 0 and not seen.has("%s:%d" % [ip, port]):
		out.append({"h": ip, "p": port, "k": "lan"})
	return out


static func _first_of_kind(addrs: Array, kind: String) -> Dictionary:
	for a_v in addrs:
		var a: Dictionary = a_v
		if str(a.get("k", "")) == kind:
			return a
	return {}


static func _normalize_dsc(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return {}
	var d: Dictionary = v
	var guild := str(d.get("g", "")).strip_edges()
	var need := bool(d.get("need", false))
	if guild.is_empty() and not need:
		return {}
	return {"g": guild, "need": need}


static func _parse_ip_port(text: String) -> Dictionary:
	var s := text.strip_edges()
	# [ipv6]:port not supported — IPv4 only.
	if s.count(":") != 1:
		return {"ok": false}
	var parts := s.split(":")
	if parts.size() != 2:
		return {"ok": false}
	var ip := parts[0].strip_edges()
	var port := int(parts[1].strip_edges())
	if ip.is_empty() or port <= 0 or port > 65535:
		return {"ok": false}
	return {"ok": true, "ip": ip, "port": port}
