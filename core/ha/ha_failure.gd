class_name HaFailure
extends RefCounted
## Why a Home Assistant connection did not work, in words (pure).
##
## Godot's WebSocketPeer reports a failed connect only as "closed", with no
## HTTP status and no socket error. What it DOES tell us is how far it got
## (never opened / opened but HA never said auth_required / logged in and then
## dropped) and how long it took, and that is enough to tell the common cases
## apart: a refused port closes almost at once, an address nobody answers on
## runs into the timeout, and something that opens a socket but never speaks
## HA's protocol is not Home Assistant's WebSocket API.

const BAD_URL := "bad_url"
const BAD_TOKEN := "bad_token"
const REFUSED := "refused"
const UNREACHABLE := "unreachable"
const NOT_HA := "not_websocket"
const AUTH_INVALID := "auth_invalid"
const AUTH_TIMEOUT := "auth_timeout"
const LOST := "lost"

## Reasons a retry cannot fix: the player has to change something.
const NO_RETRY := [BAD_URL, BAD_TOKEN, AUTH_INVALID]


## phase: "connecting" (socket never opened), "handshake" (opened, no
## auth_required yet), "auth" (auth sent, no answer), "connected" (was
## logged in). elapsed_s: since the attempt started. timed_out: our own timer
## ended it. tls: the address was wss://.
static func classify(phase: String, elapsed_s: float, timed_out: bool, tls: bool = false) -> String:
	match phase:
		"connected":
			return LOST
		"auth":
			return AUTH_TIMEOUT
		"handshake":
			return NOT_HA
		_:
			# The OS ending the attempt (a reset, an ICMP "unreachable", a
			# name that does not resolve, a TLS handshake that fails) is a
			# refusal; only our own timer running out means nobody answered.
			# Elapsed time is NOT a usable signal: Windows retries a refused
			# SYN for ~2 s before giving up.
			if timed_out:
				return UNREACHABLE
			return REFUSED


static func retryable(reason: String) -> bool:
	return not NO_RETRY.has(reason)


## {title, detail, fix} for the status card. `url` is the address tried, `ha`
## an optional message HA itself sent (auth_invalid carries one).
static func describe(reason: String, url: String = "", ha: String = "") -> Dictionary:
	var where := HaUrl.short(url) if not url.is_empty() else "that address"
	match reason:
		BAD_URL:
			return {"title": "The address cannot be used",
				"detail": ha if not ha.is_empty() else "Check the address and try again.",
				"fix": "edit_url"}
		BAD_TOKEN:
			return {"title": "The token does not look right",
				"detail": ha, "fix": "token_help"}
		REFUSED:
			return {"title": "Nothing is listening at %s" % where,
				"detail": "Nothing accepted the connection on that port (or the name could not be found). Home Assistant normally listens on port 8123; behind a proxy or add-on it may be port 80 or 443. If the address uses wss://, a self-signed certificate also ends up here.",
				"fix": "find"}
		UNREACHABLE:
			return {"title": "%s did not answer" % where,
				"detail": "Nothing answered within a few seconds. Either nothing is listening on that port (Home Assistant normally uses 8123; behind a proxy or add-on, 80 or 443), the address is wrong, this computer is not on the same network, or a firewall blocks the port.",
				"fix": "find"}
		NOT_HA:
			return {"title": "That is not Home Assistant's WebSocket API",
				"detail": "Something answered at %s but it did not speak Home Assistant's protocol. Check the port, and that a reverse proxy passes WebSocket connections through." % where,
				"fix": "find"}
		AUTH_INVALID:
			return {"title": "Home Assistant rejected the token",
				"detail": ("Home Assistant said: %s. " % ha if not ha.is_empty() else "") \
					+ "Make a new long-lived access token (your profile → Security) and paste the whole of it.",
				"fix": "token_help"}
		AUTH_TIMEOUT:
			return {"title": "Home Assistant did not answer the login",
				"detail": "The connection opened but the login got no reply. Home Assistant may be starting up; try again in a minute.",
				"fix": "retry"}
		LOST:
			return {"title": "The connection to Home Assistant dropped",
				"detail": "It was working and then stopped (Home Assistant restarted, or the network went away). Reconnecting automatically.",
				"fix": "retry"}
	return {"title": "Could not connect", "detail": ha, "fix": "retry"}
