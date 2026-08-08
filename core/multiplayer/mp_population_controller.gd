extends Node

## Replicates the simulated population from the host to every client.
##
## Why this has to exist: `SystemGraphView._tick_resource_flow_ambient` had NO
## host/client guard, so every client independently ran its own
## `ResourceFlowEngine` and `NpcPopulationBridge` off its synced copy of the
## graph, drifted, and got stomped by the host's snapshot every
## `SNAPSHOT_RESYNC_S` (12 s). The people on a joiner's screen were a local
## hallucination that snapped twice a minute. Clients now RENDER the population;
## they do not simulate it.
##
## **The seam is one call.** `NpcPopulationHost._process` reads
## `_bridge.agent_dots()` and nothing else, so handing it this controller's
## mirror instead of the real bridge makes the entire 3D path — avatars, LOD,
## the pose machine, nametags, crosshair focus — work unchanged.
##
## Wire format: an id TABLE sent once per roster change, then indexed frames.
## An agent id like `cap_pop_1_npc_12` is ~18 bytes; sending it 6×/s per agent
## for a 64-person camp would be ~7 kB/s of pure string. By index it is a
## Vector2 + two bytes ≈ 10 B/agent ≈ 4 kB/s, unreliable_ordered.

const STREAM_HZ := 6.0
## Roster changes are rare; re-send the table periodically anyway so a client
## that missed the reliable table (joined mid-stream, or a scene change) heals.
const TABLE_RESEND_SEC := 10.0
## Beyond this a frame is stale enough that showing it is worse than showing
## nothing — the host has stopped, or we lost the stream.
const FRAME_STALE_SEC := 5.0


class PopulationMirror extends RefCounted:
	## Duck-types the two methods `NpcPopulationHost` and the Site Plan need of
	## `NpcPopulationBridge`. Deliberately nothing else: a client has no engine,
	## no chore board and no desire map, and pretending otherwise would invite
	## callers to read state that is not replicated.
	var dots: Array = []
	var received_at := 0.0

	func agent_dots() -> Array:
		return dots

	func active() -> bool:
		return not dots.is_empty()

	func is_fresh(now: float) -> bool:
		return not dots.is_empty() and (now - received_at) < FRAME_STALE_SEC


var mirror: PopulationMirror = PopulationMirror.new()

var _accum := 0.0
var _table_accum := 0.0
var _ids: PackedStringArray = PackedStringArray()
var _id_index: Dictionary = {}          # agent_id -> int
var _table_rev := 0
## Client side: the last id table we were given, and any frames that arrived
## before it (unreliable_ordered frames can outrun a reliable table).
var _client_ids: PackedStringArray = PackedStringArray()
var _client_table_rev := -1
## Static per-agent fields are only in the table, so the client keeps them.
var _client_static: Array = []


func _ready() -> void:
	name = "Population"
	set_process(true)


func session() -> Node:
	return get_parent()


func clear_session_state() -> void:
	mirror.dots = []
	mirror.received_at = 0.0
	_ids = PackedStringArray()
	_id_index.clear()
	_client_ids = PackedStringArray()
	_client_static = []
	_table_rev = 0
	_client_table_rev = -1


## True when this peer should render replicated people instead of simulating.
func is_replica() -> bool:
	var s := session()
	if s == null:
		return false
	return bool(s.call("is_active")) and not bool(s.call("is_host"))


func _process(delta: float) -> void:
	var s := session()
	if s == null or not bool(s.call("is_active")) or not bool(s.call("is_host")):
		return
	_accum += delta
	_table_accum += delta
	if _accum < 1.0 / STREAM_HZ:
		return
	_accum = 0.0
	_broadcast()


func _broadcast() -> void:
	var dots := _host_dots()
	if dots.is_empty():
		return
	if _rebuild_table_if_needed(dots) or _table_accum >= TABLE_RESEND_SEC:
		_table_accum = 0.0
		rpc_pop_table.rpc(_table_rev, _ids, _static_rows(dots))
	rpc_pop_frame.rpc(_table_rev, _pack_frame(dots))


func _host_dots() -> Array:
	var view := _find_graph_view()
	if view == null:
		return []
	var bridge = view.get("_npc_population")
	if bridge == null:
		return []
	return bridge.call("agent_dots")


## Rebuild the id table when the roster changes. Returns true when it changed.
func _rebuild_table_if_needed(dots: Array) -> bool:
	if dots.size() == _ids.size():
		var same := true
		for i in dots.size():
			if str((dots[i] as Dictionary).get("id", "")) != _ids[i]:
				same = false
				break
		if same:
			return false
	_ids = PackedStringArray()
	_id_index.clear()
	for d in dots:
		var aid := str((d as Dictionary).get("id", ""))
		_id_index[aid] = _ids.size()
		_ids.append(aid)
	_table_rev += 1
	return true


## Fields that never change within a roster: name, colour, and the per-agent
## animation overrides. Sent with the table, not every frame.
func _static_rows(dots: Array) -> Array:
	var rows: Array = []
	for d_v in dots:
		var d: Dictionary = d_v
		rows.append({
			"n": str(d.get("name", "")),
			"c": d.get("color", Color.WHITE),
			"a": d.get("anim_map", {}),
		})
	return rows


## One agent per 5 entries: x, z, state, activity, space_type. Flat arrays keep
## the packet small and the decode allocation-free.
func _pack_frame(dots: Array) -> Array:
	var pos := PackedVector2Array()
	var state := PackedByteArray()
	var activity := PackedStringArray()
	var space := PackedStringArray()
	var morale := PackedFloat32Array()
	# Possession has to be replicated or a guest sees a player-driven person
	# animated as a wandering NPC — and, worse, lerped, which is exactly the
	# artefact _pose_possessed exists to avoid.
	var yaw := PackedFloat32Array()
	var flags := PackedByteArray()
	for d_v in dots:
		var d: Dictionary = d_v
		pos.append(d.get("pos", Vector2.ZERO))
		state.append(clampi(int(d.get("state", 0)), 0, 255))
		activity.append(str(d.get("activity", "")))
		space.append(str(d.get("space_type", "")))
		morale.append(float(d.get("morale", 0.5)))
		# One float, two meanings, discriminated by flags bit 0 below. A
		# possessed agent never runs the FSM planner, so it never has a
		# face_yaw; an unpossessed one never has a driving player. The two
		# are mutually exclusive BY CONSTRUCTION, which is what lets the NPC
		# facing ride along at zero protocol cost — no eighth array, no frame
		# shape change, no version gate.
		if bool(d.get("possessed", false)):
			yaw.append(float(d.get("yaw", 0.0)))
		else:
			yaw.append(float(d.get("face_yaw", 0.0)))
		# Bit 0 possessed, bit 1 carrying (Site Projects haul visual). Same
		# frame shape — protocol-gated builds only ever talk to themselves,
		# and the possessed READ masks bit 0, so the bits can't bleed.
		flags.append((1 if bool(d.get("possessed", false)) else 0)
			| (2 if bool(d.get("carrying", false)) else 0))
	return [pos, state, activity, space, morale, yaw, flags]


# ── RPCs ─────────────────────────────────────────────────────────────────────

@rpc("authority", "reliable", "call_remote")
func rpc_pop_table(rev: int, ids: PackedStringArray, statics: Array) -> void:
	_client_ids = ids
	_client_static = statics
	_client_table_rev = rev


@rpc("authority", "unreliable_ordered", "call_remote")
func rpc_pop_frame(rev: int, frame: Array) -> void:
	# A frame for a table we do not have yet is not an error: the reliable table
	# and the unreliable frames race, and the next frame after the table lands
	# will be usable. Dropping is correct and costs one sixth of a second.
	if rev != _client_table_rev or frame.size() != 7:
		return
	var pos: PackedVector2Array = frame[0]
	var state: PackedByteArray = frame[1]
	var activity: PackedStringArray = frame[2]
	var space: PackedStringArray = frame[3]
	var morale: PackedFloat32Array = frame[4]
	var yaw: PackedFloat32Array = frame[5]
	var flags: PackedByteArray = frame[6]
	var n := mini(pos.size(), _client_ids.size())
	var dots: Array = []
	for i in n:
		var statics: Dictionary = _client_static[i] as Dictionary if i < _client_static.size() else {}
		# Unpack the shared slot back into whichever field its owner reads.
		var is_poss := i < flags.size() and (flags[i] & 1) != 0
		var y := float(yaw[i]) if i < yaw.size() else 0.0
		dots.append({
			"id": _client_ids[i],
			"name": str(statics.get("n", "")),
			"pos": pos[i],
			"color": statics.get("c", Color.WHITE),
			"anim_map": statics.get("a", {}),
			"state": int(state[i]) if i < state.size() else 0,
			"activity": str(activity[i]) if i < activity.size() else "",
			"space_type": str(space[i]) if i < space.size() else "",
			"morale": float(morale[i]) if i < morale.size() else 0.5,
			"yaw": y if is_poss else 0.0,
			"face_yaw": 0.0 if is_poss else y,
			"possessed": is_poss,
			# Guests draw the carry box + Site Plan square; the crate-hiding
			# side stays host-only (replicas get prop sync, not carry_prop).
			"carrying": (i < flags.size() and (flags[i] & 2) != 0),
		})
	mirror.dots = dots
	mirror.received_at = Time.get_ticks_msec() / 1000.0


func _find_graph_view() -> Node:
	var s := session()
	if s == null or not s.has_method("_find_main"):
		return null
	var main: Node = s.call("_find_main")
	if main == null:
		return null
	var ui := main.get_node_or_null("UILayer")
	return ui.get_node_or_null("SystemGraphView") if ui != null else null
