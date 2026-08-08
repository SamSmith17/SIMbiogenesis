class_name MpReachability
extends RefCounted

## Makes the listen-server reachable from outside the LAN, and tells the host
## the truth when it cannot be.
##
## Why this exists: `MultiplayerSession.pick_lan_ipv4()` deliberately returns an
## RFC1918 address (correct, and load-bearing for LAN discovery), so the address
## baked into every join code has always been a LAN address. Internet play
## simply did not work unless a tester hand-edited an `ip:port`.
##
## Godot ships UPnP in standard desktop templates, so this needs no addon. But
## `UPNP.discover()` BLOCKS for ~2 s per attempt, so it must never run on the
## main thread — `probe_async` puts it on a WorkerThreadPool task and delivers
## the result with `call_deferred`.
##
## Honest limitation stated up front: there is no way to VERIFY inbound
## reachability without an external server, and we deliberately run none. A
## created mapping is reported as "created — not verified" until a real remote
## peer connects from a public address, at which point the caller flips it.

## ENet is UDP-only. Do not map TCP "just in case" — a stray mapping on a
## shared router is rude and can collide with something else.
const PROTO := "UDP"
const MAPPING_DESC := "SIMbiogenesis"
const LEASE_FALLBACK_SEC := 7200

var _task_id: int = -1
var _upnp: UPNP = null


# ── Pure classification ──────────────────────────────────────────────────────

static func is_private_ipv4(ip: String) -> bool:
	var o := _octets(ip)
	if o.is_empty():
		return false
	if o[0] == 10:
		return true
	if o[0] == 172 and o[1] >= 16 and o[1] <= 31:
		return true
	if o[0] == 192 and o[1] == 168:
		return true
	if o[0] == 127:
		return true
	if o[0] == 169 and o[1] == 254:
		return true
	return false


## 100.64.0.0/10 — carrier-grade NAT. Easy to miss and important to catch: a
## host behind CGNAT (common on mobile, 5G home internet and Starlink) CANNOT
## be port-forwarded at all, so the correct advice is "someone else should host
## or use a VPN", not "check your router".
static func is_cgnat(ip: String) -> bool:
	var o := _octets(ip)
	if o.is_empty():
		return false
	return o[0] == 100 and o[1] >= 64 and o[1] <= 127


static func is_routable_public(ip: String) -> bool:
	var o := _octets(ip)
	if o.is_empty():
		return false
	if o[0] == 0 or o[0] >= 224:
		return false
	return not is_private_ipv4(ip) and not is_cgnat(ip)


## Do two IPv4 addresses look like the same /16? Used to decide whether trying
## the LAN candidate first is worth a timeout.
static func same_subnet16(a: String, b: String) -> bool:
	var oa := _octets(a)
	var ob := _octets(b)
	if oa.is_empty() or ob.is_empty():
		return false
	return oa[0] == ob[0] and oa[1] == ob[1]


## Order the candidate addresses a joining client should try.
##
## The naive "LAN first, then public" costs EVERY internet player a pointless
## ~6 s timeout on an address that can never work. So LAN goes first only when
## our own LAN address shares a /16 with the host's — otherwise public first.
static func candidate_order(addrs: Array, my_lan_ip: String) -> Array:
	var lan: Array = []
	var pub: Array = []
	var other: Array = []
	for a_v in addrs:
		if not (a_v is Dictionary):
			continue
		var a: Dictionary = a_v
		var host := str(a.get("h", "")).strip_edges()
		if host.is_empty() or int(a.get("p", 0)) <= 0:
			continue
		match str(a.get("k", "")):
			"lan": lan.append(a)
			"pub": pub.append(a)
			_: other.append(a)
	var lan_is_plausible := false
	for a_v2 in lan:
		if same_subnet16(str((a_v2 as Dictionary).get("h", "")), my_lan_ip):
			lan_is_plausible = true
			break
	var out: Array = []
	if lan_is_plausible:
		out.append_array(lan)
		out.append_array(pub)
	else:
		out.append_array(pub)
		out.append_array(lan)
	out.append_array(other)
	return out


## Human text for every UPNP result code. Table-driven and selftest-swept so a
## new engine constant cannot silently render as a bare number to a player.
static func upnp_error_text(code: int) -> String:
	match code:
		UPNP.UPNP_RESULT_SUCCESS:
			return "Port mapping created."
		UPNP.UPNP_RESULT_NOT_AUTHORIZED:
			return "The router refused: UPnP is present but not authorized."
		UPNP.UPNP_RESULT_PORT_MAPPING_NOT_FOUND:
			return "No such port mapping on the router."
		UPNP.UPNP_RESULT_INCONSISTENT_PARAMETERS:
			return "The router rejected the mapping parameters."
		UPNP.UPNP_RESULT_NO_SUCH_ENTRY_IN_ARRAY:
			return "The router has no matching mapping entry."
		UPNP.UPNP_RESULT_ACTION_FAILED:
			return "The router refused the mapping (generic failure)."
		UPNP.UPNP_RESULT_SRC_IP_WILDCARD_NOT_PERMITTED:
			return "The router will not accept a wildcard source address."
		UPNP.UPNP_RESULT_EXT_PORT_WILDCARD_NOT_PERMITTED:
			return "The router will not accept a wildcard external port."
		UPNP.UPNP_RESULT_INT_PORT_WILDCARD_NOT_PERMITTED:
			return "The router will not accept a wildcard internal port."
		UPNP.UPNP_RESULT_REMOTE_HOST_MUST_BE_WILDCARD:
			return "The router requires a wildcard remote host."
		UPNP.UPNP_RESULT_EXT_PORT_MUST_BE_WILDCARD:
			return "The router requires a wildcard external port."
		UPNP.UPNP_RESULT_NO_PORT_MAPS_AVAILABLE:
			return "The router has no free port-mapping slots."
		UPNP.UPNP_RESULT_CONFLICT_WITH_OTHER_MECHANISM:
			return "Another mechanism on the router already owns this port."
		UPNP.UPNP_RESULT_CONFLICT_WITH_OTHER_MAPPING:
			return "Another device already forwards this port."
		UPNP.UPNP_RESULT_SAME_PORT_VALUES_REQUIRED:
			return "The router requires identical internal and external ports."
		UPNP.UPNP_RESULT_ONLY_PERMANENT_LEASE_SUPPORTED:
			return "The router only supports permanent leases."
		UPNP.UPNP_RESULT_INVALID_GATEWAY:
			return "The discovered gateway is not a valid UPnP gateway."
		UPNP.UPNP_RESULT_INVALID_PORT:
			return "Invalid port."
		UPNP.UPNP_RESULT_INVALID_PROTOCOL:
			return "Invalid protocol."
		UPNP.UPNP_RESULT_INVALID_DURATION:
			return "Invalid lease duration."
		UPNP.UPNP_RESULT_INVALID_ARGS:
			return "Invalid UPnP arguments."
		UPNP.UPNP_RESULT_INVALID_RESPONSE:
			return "The router sent an invalid UPnP response."
		UPNP.UPNP_RESULT_INVALID_PARAM:
			return "Invalid UPnP parameter."
		UPNP.UPNP_RESULT_HTTP_ERROR:
			return "HTTP error talking to the router."
		UPNP.UPNP_RESULT_SOCKET_ERROR:
			return "Network socket error talking to the router."
		UPNP.UPNP_RESULT_MEM_ALLOC_ERROR:
			return "Out of memory during UPnP discovery."
		UPNP.UPNP_RESULT_NO_GATEWAY:
			return "No UPnP gateway found — UPnP may be disabled on the router."
		UPNP.UPNP_RESULT_NO_DEVICES:
			return "No UPnP devices responded on this network."
		UPNP.UPNP_RESULT_UNKNOWN_ERROR:
			return "Unknown UPnP error."
	return "UPnP error %d." % code


## The one-line diagnostic the lobby shows, plus the actionable next step.
## `result` is what `probe_async` delivers.
static func diagnosis(result: Dictionary, port: int) -> String:
	var external := str(result.get("external_ip", "")).strip_edges()
	var mapped := bool(result.get("mapped", false))
	var code := int(result.get("code", UPNP.UPNP_RESULT_UNKNOWN_ERROR))

	if not bool(result.get("gateway", false)):
		return "%s Others on your LAN can still join. For internet play, forward UDP %d manually, or put everyone on a VPN like Tailscale." % [
			upnp_error_text(code), port]
	if is_cgnat(external):
		return "Your internet connection is behind carrier-grade NAT (%s), so port forwarding cannot work at all. Ask someone else to host, or put everyone on a VPN like Tailscale." % external
	if is_private_ipv4(external):
		return "The router reports a private external address (%s), so this connection cannot accept inbound players. Ask someone else to host, or use a VPN like Tailscale." % external
	if mapped:
		return "UPnP mapped UDP %d · public %s (created — not verified until someone joins)." % [port, external]
	return "%s Public address looks like %s — forward UDP %d manually if joins fail." % [
		upnp_error_text(code), external if not external.is_empty() else "unknown", port]


# ── Threaded probe ───────────────────────────────────────────────────────────

## Discover the gateway, learn the external address and map `port`, off the main
## thread. `on_done` is called deferred with
## {gateway, code, mapped, external_ip, lease}.
func probe_async(port: int, on_done: Callable) -> void:
	if _task_id != -1:
		return  # one probe at a time; the lobby's Retry waits for the current one
	_task_id = WorkerThreadPool.add_task(func() -> void:
		var res := _probe_blocking(port)
		_task_id = -1
		if on_done.is_valid():
			on_done.call_deferred(res))


## Best-effort teardown. Safe to call when nothing was mapped.
func release(port: int) -> void:
	if _upnp == null:
		return
	_upnp.delete_port_mapping(port, PROTO)
	_upnp = null


func _probe_blocking(port: int) -> Dictionary:
	var upnp := UPNP.new()
	var code := upnp.discover()
	var out := {
		"gateway": false,
		"code": code,
		"mapped": false,
		"external_ip": "",
		"lease": 0,
	}
	if code != UPNP.UPNP_RESULT_SUCCESS:
		return out
	var gw := upnp.get_gateway()
	if gw == null or not gw.is_valid_gateway():
		out["code"] = UPNP.UPNP_RESULT_INVALID_GATEWAY
		return out
	out["gateway"] = true
	out["external_ip"] = upnp.query_external_address()

	# Duration 0 = permanent. Some routers reject it, some reject anything else,
	# so try permanent first and fall back to a long lease.
	var add := upnp.add_port_mapping(port, port, MAPPING_DESC, PROTO, 0)
	var lease := 0
	if add != UPNP.UPNP_RESULT_SUCCESS:
		add = upnp.add_port_mapping(port, port, MAPPING_DESC, PROTO, LEASE_FALLBACK_SEC)
		lease = LEASE_FALLBACK_SEC
	out["code"] = add
	out["mapped"] = add == UPNP.UPNP_RESULT_SUCCESS
	out["lease"] = lease if out["mapped"] else 0
	if out["mapped"]:
		_upnp = upnp
	return out


static func _octets(ip: String) -> Array:
	var parts := ip.strip_edges().split(".")
	if parts.size() != 4:
		return []
	var out: Array = []
	for p in parts:
		if p.is_empty() or not p.is_valid_int():
			return []
		var n := int(p)
		if n < 0 or n > 255:
			return []
		out.append(n)
	return out
