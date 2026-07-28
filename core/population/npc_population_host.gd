class_name NpcPopulationHost
extends Node3D

## 3D presence for the simulated NPC population (Phase B): one NpcAvatar per
## agent, kinematically snapped to the terrain each frame (the
## MultiplayerSession spawn/despawn/pose loop pattern — no CharacterBody3D
## physics; the sim owns positions, this node only renders them).
## Created by SystemGraphView when a pop-driven habitat is active; ticks off
## the same NpcPopulationBridge the flow engine uses, so 2D dots and 3D
## figures are always the same people in the same places.

## Above this (m per frame-step) the sim jumped (high time-scale / catch-up):
## hard-snap instead of gliding across the map.
const TELEPORT_SNAP_M := 25.0
const SMOOTH_RATE := 8.0
const MOVE_EPS_M := 0.05

## LOD. Ground height is the expensive part (a terrain query per avatar per
## frame — 50 of those, and on scenes with no TerrainLoader each is a
## raycast), so re-sample it only when the agent actually moved in XZ or the
## refresh interval lapses. Beyond CULL_DIST_M the figure is hidden and
## skipped entirely; between VISIBLE and CULL it poses at a reduced rate.
const CULL_DIST_M := 220.0
const FAR_DIST_M := 90.0
const FAR_POSE_INTERVAL_S := 0.25
const GROUND_REFRESH_S := 0.5
const GROUND_MOVE_EPS_M := 0.35

## Rigged-figure budget. A skinned 16k-vertex mesh with its own skeleton and
## animation tree is a different cost class from the primitive figure, and a
## 50-person camp would pay it 50 times over — so only the nearest few get the
## real body and everyone else keeps the cheap one. Both read as the same
## silhouette at distance, which is what makes the swap invisible.
const RIG_DIST_M := 45.0
const MAX_RIGGED := 12
## Hysteresis on the distance test so someone hovering at the boundary does not
## rebuild/rebind their rig every frame.
const RIG_DIST_HYSTERESIS_M := 6.0

var _bridge = null                 # NpcPopulationBridge (RefCounted)
var _main: Node = null
var _avatars: Dictionary = {}      # agent_id -> NpcAvatar
var _last_pos: Dictionary = {}     # agent_id -> Vector2 (sim pos last frame)
var _ground: Dictionary = {}       # agent_id -> {y: float, at: Vector2, t: float}
var _far_accum: Dictionary = {}    # agent_id -> float (seconds since last far pose)
var _focus_id: String = ""         # agent the crosshair is on (nametag shown)


func setup(bridge, main: Node) -> void:
	_bridge = bridge
	_main = main
	name = "NpcPopulationHost"


func _process(delta: float) -> void:
	if _bridge == null or _main == null or not is_instance_valid(_main):
		return
	var dots: Array = _bridge.agent_dots()
	var seen: Dictionary = {}
	var near: Array = []   # [dist, agent_id] candidates for the rigged body
	var eye := _viewer_xz()
	for dot_v in dots:
		if not (dot_v is Dictionary):
			continue
		var dot: Dictionary = dot_v
		var aid := str(dot.get("id", ""))
		if aid.is_empty():
			continue
		seen[aid] = true
		var av: NpcAvatar = _avatars.get(aid)
		if av == null:
			av = NpcAvatar.new()
			av.setup(aid, dot.get("color", Color.WHITE) as Color, str(dot.get("name", "")))
			add_child(av)
			_avatars[aid] = av
		av.status_text = str(dot.get("status", ""))
		av.morale_label = str(dot.get("morale_label", ""))
		var sim_pos: Vector2 = dot.get("pos", Vector2.ZERO)
		var dist := (sim_pos - eye).length()
		if dist > CULL_DIST_M:
			if av.visible:
				av.visible = false
				av.set_process(false)
			_last_pos[aid] = sim_pos  # keep movement continuity for when it returns
			continue
		if not av.visible:
			av.visible = true
			av.set_process(true)
		# Already-rigged figures keep their body a little past the threshold so
		# walking the boundary does not thrash the swap.
		var rig_reach := RIG_DIST_M + (RIG_DIST_HYSTERESIS_M if av.is_rigged() else 0.0)
		if dist <= rig_reach:
			near.append([dist, aid])
		else:
			av.set_detail(false)
		if dist > FAR_DIST_M:
			# Distant figures don't need per-frame smoothing; batch their pose.
			var acc := float(_far_accum.get(aid, 0.0)) + delta
			if acc < FAR_POSE_INTERVAL_S:
				_far_accum[aid] = acc
				continue
			_far_accum[aid] = 0.0
			_pose_avatar(av, aid, dot, acc)
		else:
			_pose_avatar(av, aid, dot, delta)
		av.set_tag_visible(aid == _focus_id)
	_apply_rig_budget(near)
	# Despawn agents that left the roster (count change / pop_driven off).
	for aid in _avatars.keys():
		if not seen.has(aid):
			var av2: NpcAvatar = _avatars[aid]
			if is_instance_valid(av2):
				av2.queue_free()
			_avatars.erase(aid)
			_last_pos.erase(aid)
			_ground.erase(aid)
			_far_accum.erase(aid)


## Give the rigged body to the MAX_RIGGED nearest candidates and the primitive
## to everyone else. Nearest-first rather than first-come so the detailed
## figures are always the ones actually being looked at; ties break on agent id
## so the choice is stable frame to frame.
func _apply_rig_budget(near: Array) -> void:
	near.sort_custom(func(a, b):
		if is_equal_approx(float(a[0]), float(b[0])):
			return str(a[1]) < str(b[1])
		return float(a[0]) < float(b[0]))
	for i in range(near.size()):
		var av: NpcAvatar = _avatars.get(str(near[i][1]))
		if av != null and is_instance_valid(av):
			av.set_detail(i < MAX_RIGGED)


## Highlight one agent's nametag (called by InteractionFocus on crosshair hit;
## "" clears).
func set_focus_agent(agent_id: String) -> void:
	if _focus_id == agent_id:
		return
	var prev: NpcAvatar = _avatars.get(_focus_id)
	if prev != null and is_instance_valid(prev):
		prev.set_tag_visible(false)
	_focus_id = agent_id
	var now: NpcAvatar = _avatars.get(agent_id)
	if now != null and is_instance_valid(now):
		now.set_tag_visible(true)


func _viewer_xz() -> Vector2:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return Vector2.ZERO
	var p := cam.global_position
	return Vector2(p.x, p.z)


## Cached terrain height: only re-query when the agent moved meaningfully in
## XZ or the cache went stale (terrain can be sculpted under them).
func _ground_y(aid: String, xz: Vector2) -> float:
	var rec: Dictionary = _ground.get(aid, {})
	var now := float(Time.get_ticks_msec()) * 0.001
	if not rec.is_empty():
		var at: Vector2 = rec.get("at", Vector2.ZERO)
		if (at - xz).length() < GROUND_MOVE_EPS_M and now - float(rec.get("t", 0.0)) < GROUND_REFRESH_S:
			return float(rec.get("y", 0.0))
	var y := TerrainSurfaceQuery.ground_height_at(_main, xz.x, xz.y)
	_ground[aid] = {"y": y, "at": xz, "t": now}
	return y


func _pose_avatar(av: NpcAvatar, aid: String, dot: Dictionary, delta: float) -> void:
	var sim_pos: Vector2 = dot.get("pos", Vector2.ZERO)
	var prev: Vector2 = _last_pos.get(aid, sim_pos)
	_last_pos[aid] = sim_pos
	var moving := (sim_pos - prev).length() > MOVE_EPS_M
	var gy := _ground_y(aid, sim_pos)
	var target := Vector3(sim_pos.x, gy, sim_pos.y)
	var cur := av.global_position
	var next := target
	if cur.distance_to(target) < TELEPORT_SNAP_M and cur != Vector3.ZERO:
		next = cur.lerp(target, minf(delta * SMOOTH_RATE, 1.0))
	var yaw := av.rotation.y
	var dir := sim_pos - Vector2(cur.x, cur.z)
	if dir.length() > MOVE_EPS_M:
		# CelestialClock convention: north −Z, east +X; atan2 gives the
		# heading of travel in world yaw.
		yaw = atan2(-dir.x, -dir.y)
	av.apply_state(next, yaw, moving, str(dot.get("activity", "")))
