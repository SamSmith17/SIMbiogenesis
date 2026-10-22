class_name HaUrl
extends RefCounted
## Home Assistant address handling (pure).
##
## Players type the address the way they see it in a browser: "192.168.1.10",
## "homeassistant.local:8123", "http://192.168.1.10/lovelace/0", a Nabu Casa
## "https://xxxx.ui.nabu.casa". The WebSocket API always lives at
## ws(s)://host[:port]/api/websocket, so normalize() turns any of those into
## that one form. A bare host keeps NO port (= 80 / 443): that is what a
## browser does, and it is what an HA install behind a proxy (or on port 80)
## needs. candidates() lists the other places HA usually answers, for the
## "find my Home Assistant" probe after a failed connect.

const WS_PATH := "/api/websocket"
## Where HA usually listens when the typed address does not answer.
const DEFAULT_PROBE_PORTS := [8123, 80]


## {ok, url, scheme ("ws"|"wss"), host, port (-1 = scheme default), error}.
static func normalize(input: String) -> Dictionary:
	var s := input.strip_edges()
	# Pasted with quotes or a trailing slash / whitespace.
	s = s.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'").strip_edges()
	if s.is_empty():
		return _err("Enter the address of your Home Assistant, e.g. 192.168.1.10:8123.")
	var scheme := "ws"
	var lower := s.to_lower()
	var rest := s
	var sep := lower.find("://")
	if sep >= 0:
		var given := lower.substr(0, sep)
		rest = s.substr(sep + 3)
		match given:
			"ws", "http":
				scheme = "ws"
			"wss", "https":
				scheme = "wss"
			_:
				return _err("\"%s://\" is not a web address. Use http://, https://, ws:// or wss://." % given)
	elif lower.ends_with(".ui.nabu.casa") or lower.contains(".ui.nabu.casa/"):
		scheme = "wss"
	# Host[:port] is everything up to the first "/", "?" or "#".
	var cut := rest.length()
	for ch in ["/", "?", "#"]:
		var i := rest.find(ch)
		if i >= 0 and i < cut:
			cut = i
	var hostport := rest.substr(0, cut)
	# user:pass@ never belongs in a WebSocket URL here.
	var at := hostport.rfind("@")
	if at >= 0:
		hostport = hostport.substr(at + 1)
	var host := hostport
	var port := -1
	if hostport.begins_with("["):
		# IPv6 literal: [::1]:8123
		var close := hostport.find("]")
		if close < 0:
			return _err("The address has an opening \"[\" with no closing \"]\".")
		host = hostport.substr(0, close + 1)
		var after := hostport.substr(close + 1)
		if after.begins_with(":"):
			if not after.substr(1).is_valid_int():
				return _err("\"%s\" is not a port number." % after.substr(1))
			port = after.substr(1).to_int()
	else:
		var colon := hostport.rfind(":")
		if colon >= 0:
			var p := hostport.substr(colon + 1)
			host = hostport.substr(0, colon)
			if p.is_empty():
				port = -1
			elif not p.is_valid_int():
				return _err("\"%s\" is not a port number." % p)
			else:
				port = p.to_int()
	host = host.strip_edges()
	if host.is_empty():
		return _err("The address has no host name or IP address.")
	if host.contains(" "):
		return _err("The address cannot contain spaces.")
	if port == 0 or port > 65535:
		return _err("Port %d is out of range (1-65535)." % port)
	# A scheme's own default port is the same as no port.
	if (scheme == "ws" and port == 80) or (scheme == "wss" and port == 443):
		port = -1
	return {
		"ok": true, "url": build(scheme, host, port), "scheme": scheme,
		"host": host, "port": port, "error": "",
	}


static func build(scheme: String, host: String, port: int) -> String:
	if port > 0:
		return "%s://%s:%d%s" % [scheme, host, port, WS_PATH]
	return "%s://%s%s" % [scheme, host, WS_PATH]


## The other addresses worth probing when `input` did not answer, in order,
## never including `input`'s own normalized URL. `ports` = plain ports to try
## on the same host (ws); a wss-on-443 candidate is added for a named host.
static func candidates(input: String, ports: Array = DEFAULT_PROBE_PORTS) -> Array:
	var n := normalize(input)
	if not bool(n.get("ok", false)):
		return []
	var host := str(n["host"])
	var own := str(n["url"])
	var out: Array = []
	for p in ports:
		var u := build("ws", host, -1 if int(p) == 80 else int(p))
		if u != own and not out.has(u):
			out.append(u)
	var tls := build("wss", host, -1)
	if tls != own and not out.has(tls) and not _is_ip(host):
		out.append(tls)
	return out


## The plain web address a person would open in a browser for `ws_url`.
static func browser_url(ws_url: String) -> String:
	var s := ws_url.trim_suffix(WS_PATH)
	if s.begins_with("wss://"):
		return "https://" + s.substr(6)
	if s.begins_with("ws://"):
		return "http://" + s.substr(5)
	return s


## Short "host:port" for status lines.
static func short(ws_url: String) -> String:
	var n := normalize(ws_url)
	if not bool(n.get("ok", false)):
		return ws_url
	var p := int(n["port"])
	var s := str(n["host"]) if p < 0 else "%s:%d" % [n["host"], p]
	return ("🔒 " + s) if str(n["scheme"]) == "wss" else s


static func _is_ip(host: String) -> bool:
	if host.begins_with("["):
		return true
	var parts := host.split(".")
	if parts.size() != 4:
		return false
	for p in parts:
		if not p.is_valid_int():
			return false
	return true


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "url": "", "scheme": "", "host": "", "port": -1, "error": msg}
