class_name MpPossession
extends RefCounted

## Pure rules for a remote player inhabiting one of the simulated people.
##
## Naming: this is **possession**, never "embody" — `VIEW_MODE_EMBODY_TWINS`
## already means "give a graph item a 3D twin" in system_graph_view.gd, and that
## constant has a documented id-collision history.
##
## The binding is always by `agent_id` STRING, never by object reference:
## `NpcPopulationBridge._ensure_engine` replaces every `NpcAgent` object
## whenever the authored `occupants` count changes, and ids are stable
## (`"<seed_key>_npc_<i>"`) precisely so a binding can survive that.

## A sim person walks at NpcNav.WALK_SPEED_MPS of SIM time, so at high time
## scale the camp moves past a human who is walking in real time. Per the design
## decision this WARNS rather than clamping the host's clock.
##
## `time_scale` is sim-HOURS per real second, so realtime is 1/3600. main.gd
## defaults to 0.01 — already ~36x — which is why this threshold is a tuned
## constant and not "> 1".
const REALTIME_SCALE := 1.0 / 3600.0
const WARN_MULTIPLIER := 10.0
const WARN_COOLDOWN_SEC := 30.0


## How many times faster than real time the world is running.
static func speed_multiplier(time_scale: float) -> float:
	return absf(time_scale) / REALTIME_SCALE


## Warn at most once per cooldown AND once per distinct speed bracket — the
## clock RPC arrives at 2 Hz, so a naive "warn when fast" would be a toast
## every half second.
## Returns {warn, bracket, text}.
static func time_scale_warning(time_scale: float, last_warn_unix: int,
		last_bracket: int, now_unix: int) -> Dictionary:
	var mult := speed_multiplier(time_scale)
	if mult <= WARN_MULTIPLIER:
		return {"warn": false, "bracket": 0, "text": ""}
	var bracket := int(log(mult) / log(4.0))  # ~quartering bands: 10x, 40x, 160x…
	if bracket == last_bracket and now_unix - last_warn_unix < WARN_COOLDOWN_SEC:
		return {"warn": false, "bracket": bracket, "text": ""}
	return {
		"warn": true,
		"bracket": bracket,
		"text": "The world is running about %s faster than you — everyone else will blur past." %
			_format_multiplier(mult),
	}


static func _format_multiplier(mult: float) -> String:
	if mult >= 1000.0:
		return "%.0fk×" % (mult / 1000.0)
	if mult >= 10.0:
		return "%.0f×" % mult
	return "%.1f×" % mult


## Can `peer_id` take over `agent_id` right now?
## `controlled` maps agent_id -> peer_id for everyone already possessed.
## Returns {ok} / {ok:false, error}.
static func can_possess(agent_id: String, peer_id: int, controlled: Dictionary,
		agent_exists: bool) -> Dictionary:
	if agent_id.is_empty() or peer_id <= 0:
		return {"ok": false, "error": "No one selected"}
	if not agent_exists:
		return {"ok": false, "error": "That person has left the camp"}
	var holder := int(controlled.get(agent_id, 0))
	if holder == peer_id:
		return {"ok": false, "error": "You are already playing as them"}
	if holder != 0:
		return {"ok": false, "error": "Someone else is already playing as them"}
	# One body each: a peer holding two agents would drive both to the same
	# position and there would be no way to say which one they are.
	for aid in controlled:
		if int(controlled[aid]) == peer_id:
			return {"ok": false, "error": "Leave your current person first"}
	return {"ok": true}


## The agent this peer currently holds, or "".
static func agent_of_peer(controlled: Dictionary, peer_id: int) -> String:
	for aid in controlled:
		if int(controlled[aid]) == peer_id:
			return str(aid)
	return ""


## Everything a departing peer must release. Returns the agent ids to free.
static func release_for_peer(controlled: Dictionary, peer_id: int) -> Array:
	var out: Array = []
	for aid in controlled:
		if int(controlled[aid]) == peer_id:
			out.append(str(aid))
	out.sort()
	return out
