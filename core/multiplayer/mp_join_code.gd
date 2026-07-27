class_name MpJoinCode
extends RefCounted

## Compact join-code codec for listen-server sessions.
## Embeds host address, port, session token, map identity, expiry, and whether
## a host password is required (password itself is never in the code).

const PREFIX := "SMB2:"
## Phase 6: v2 adds exp (unix) + has_pw. Older v1 codes are rejected.
const PROTOCOL_VERSION := 2


static func encode(payload: Dictionary) -> Dictionary:
	var body := {
		"v": PROTOCOL_VERSION,
		"ip": str(payload.get("ip", "")),
		"port": int(payload.get("port", 0)),
		"token": str(payload.get("token", "")),
		"name": str(payload.get("name", "Session")),
		"map": (payload.get("map", {}) as Dictionary).duplicate(true),
		"exp": int(payload.get("exp", 0)),
		"has_pw": bool(payload.get("has_pw", false)),
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
				"token": "",
				"name": "Direct",
				"map": {},
				"exp": 0,
				"has_pw": false,
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
	if ver != PROTOCOL_VERSION:
		return {"ok": false, "error": "Incompatible protocol version %d (need %d)" % [
			ver, PROTOCOL_VERSION]}
	var ip := str(body.get("ip", ""))
	var port := int(body.get("port", 0))
	if ip.is_empty() or port <= 0:
		return {"ok": false, "error": "Join code missing host address"}
	var exp := int(body.get("exp", 0))
	if MpHardening.is_expired(exp, now_unix):
		return {"ok": false, "error": "Join code expired — ask the host for a fresh code"}
	return {
		"ok": true,
		"ip": ip,
		"port": port,
		"token": str(body.get("token", "")),
		"name": str(body.get("name", "Session")),
		"map": (body.get("map", {}) as Dictionary).duplicate(true),
		"exp": exp,
		"has_pw": bool(body.get("has_pw", false)),
		"bare": false,
	}


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
