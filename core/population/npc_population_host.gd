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
## hard-snap instead of gliding across the map. At high time scale this is a
## FLOOR, not the whole rule — a step that is exactly "walking at timelapse
## speed" (expected_step × margin) interpolates instead of snapping; only a
## step beyond what walking could cover is a genuine relocation. Before this,
## 60× sawtoothed (19.5 m per tick, just under 25) and ≥~320× hard-cut the
## pose FSM every single tick.
const TELEPORT_SNAP_M := 25.0
const TELEPORT_STEP_MARGIN := 1.6
const SMOOTH_RATE := 8.0
const MOVE_EPS_M := 0.05
## Tick-to-tick interpolation kicks in when the sim's per-tick step exceeds
## this — big enough that 1× play (≈0.33 m/tick) keeps the long-standing
## exponential-smoothing look, small enough that 10×+ becomes a glide.
const INTERP_MIN_STEP_M := 2.0
## Estimated tick intervals are biased high so the interpolation rarely parks
## at f=1 waiting for the next tick (a park reads as 4 Hz stutter); the small
## residual folds into the next segment.
const INTERP_INTERVAL_BIAS := 1.1
## Stationary yaw slew ceiling (rad per real second). NpcFacing's idle drift
## runs on the SIM clock, so at 450× its ±6.3° wander completes in under two
## wall seconds — a head-shake on every standing figure. The drift AMPLITUDE
## bound stays the far-LOD guarantee; this bounds the RATE where it renders.
const YAW_SLEW_IDLE_RAD_S := 0.6

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

## How close the RENDERED body must get to its sim target before it counts as
## arrived. The smoothing below is asymptotic, so it never literally lands.
const ARRIVE_EPS_M := 0.15
## Ceiling on how long arrival may be pending. Bounded by construction: the
## largest gap that does not hard-snap is TELEPORT_SNAP_M, and the exponential
## covers 25 m -> 0.15 m in ln(25/0.15)/8.58 = 0.60 s. This exists only so a
## smoothing residual can never leave a figure permanently "walking".
const ARRIVE_MAX_S := 0.7
## Yaw needs a coarser threshold than movement: on final approach the direction
## vector shrinks toward zero and its heading goes noisy.
const YAW_EPS_M := 0.25
const YAW_RATE := 8.0
## Fallback when a dot carries no "state": hold the last movement for this long
## rather than testing an instantaneous delta (see _pose_avatar).
const MOVE_HOLD_S := 0.6

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
var _arrive_wait: Dictionary = {}  # agent_id -> seconds the render has been catching up
var _moved_at: Dictionary = {}     # agent_id -> time of last sim movement (fallback path)
var _anchor_pos: Dictionary = {}   # agent_id -> Vector3 held while standing up
## Tick-to-tick interpolation state: agent_id -> {prev/next: Vector3 targets,
## at: wall time the dot last moved, interval: EMA of tick spacing, step_m}.
var _interp: Dictionary = {}
## HERO POOL (festival plan Phase 4): with more full-tier people than the
## quality tier's `hero_max`, only the nearest that many keep an NpcAvatar;
## the rest are handed to CrowdRenderer as segments. A roster at or under
## the budget is all heroes (no distance test), so single-camp maps are
## byte-identical. Membership has hysteresis so walking the boundary does
## not thrash avatars in and out.
const HERO_HYSTERESIS_M := 8.0
const HERO_PUSH_S := 0.2
var _crowd_renderer: Node = null
var _hero_ids: Dictionary = {}
var _hero_push_accum := 0.0
var _crowd_prev: Dictionary = {}   # id -> {pos: Vector2, h: float}
## agent_id -> size of the carry group this frame (how many hands share the
## same carried prop) — feeds the heavy-lift posture flag.
var _carry_group_of: Dictionary = {}
var _now := 0.0
var _focus_id: String = ""         # agent the crosshair is on (nametag shown)
## Props currently riding someone's hands (Site Projects carry): prop_id ->
## {xf: the original global transform, for the preempted-carry restore}.
## Node-transform only — the RECORD never moves here (the move is the chore's
## completion effect); never the persisted hidden_3d key either, which
## belongs to the placeholder-twins feature.
var _carried_state: Dictionary = {}
## In-world work-site markers (Site Projects): an amber disc + readout at each
## ACTIVE crew site, mirroring the Site Plan's crew markers so a build is
## legible from the ground too. Pooled, refreshed on a coarse cadence.
const CREW_MARKER_MAX := 5
const CREW_MARKER_REFRESH_S := 0.5
var _crew_markers: Array = []        # of {root, disc_mat, label}
var _crew_marker_accum := 0.0
## Multiplier on the LOD distances. CULL_DIST_M/FAR_DIST_M are tuned for a
## first-person camera at eye height; the settlement view sits hundreds of
## metres up, where those numbers would hide the entire camp. Raised while
## that view is open and restored on exit. MAX_RIGGED is deliberately NOT
## scaled — twelve skinned bodies is the budget whatever the viewpoint.
var _range_scale := 1.0


func set_view_range_scale(scale: float) -> void:
	_range_scale = clampf(scale, 1.0, 20.0)


func setup(bridge, main: Node) -> void:
	_bridge = bridge
	_main = main
	name = "NpcPopulationHost"


func _process(delta: float) -> void:
	if _bridge == null or _main == null or not is_instance_valid(_main):
		return
	# The avatar loop is the per-frame cost that scales with the roster (one
	# NpcAvatar subtree per person today); the bench reads this section to prove
	# a crowd renderer actually flattened it.
	# "Draw nobody" hides the full-tier avatars too; the sim is untouched.
	var draw := NpcDisplayPrefs.crowd_draw() != NpcDisplayPrefs.CROWD_NONE
	if visible != draw:
		visible = draw
	if not draw:
		return
	PerfMonitor.begin("npc_host")
	_process_avatars(delta)
	PerfMonitor.end("npc_host")


func _process_avatars(delta: float) -> void:
	_now += delta
	var dots: Array = _bridge.agent_dots()
	var seen: Dictionary = {}
	var near: Array = []   # [dist, agent_id] candidates for the rigged body
	var carried: Dictionary = {}   # prop_id -> Array of carrier agent ids
	var eye := _viewer_xz()
	# Pre-pass: carry groups, so each carrier's pose payload knows whether the
	# REAL prop is in hand (suppress the generic chest box) and whether this is
	# a team lift (low-hold posture).
	var carry_group_of: Dictionary = {}   # agent_id -> group size
	for dot_v in dots:
		if dot_v is Dictionary and bool((dot_v as Dictionary).get("carrying", false)):
			var cp0 := str((dot_v as Dictionary).get("carry_prop", ""))
			if not cp0.is_empty():
				var arr0: Array = carried.get(cp0, [])
				arr0.append(str((dot_v as Dictionary).get("id", "")))
				carried[cp0] = arr0
	for cp1 in carried:
		for aid1 in (carried[cp1] as Array):
			carry_group_of[str(aid1)] = (carried[cp1] as Array).size()
	_carry_group_of = carry_group_of
	var heroes := _pick_heroes(dots, eye)
	var crowd_entries: Array = []
	var push_crowd := false
	if _crowd_renderer != null and is_instance_valid(_crowd_renderer):
		_hero_push_accum += delta
		push_crowd = _hero_push_accum >= HERO_PUSH_S
	var now_h := float(_main.call("get_absolute_hours")) if _main != null and _main.has_method("get_absolute_hours") else 0.0
	for dot_v in dots:
		if not (dot_v is Dictionary):
			continue
		var dot: Dictionary = dot_v
		var aid := str(dot.get("id", ""))
		if aid.is_empty():
			continue
		# Light-tier people are drawn by CrowdRenderer (one MultiMesh), never
		# as NpcAvatar subtrees — that is the whole point of the tier.
		if str(dot.get("tier", "")) == "light":
			continue
		seen[aid] = true
		if not heroes.has(aid):
			# Beyond the hero budget: no NpcAvatar work at all this frame; the
			# crowd renderer draws them from their last two tick positions.
			var av0: NpcAvatar = _avatars.get(aid)
			if av0 != null and av0.visible:
				av0.visible = false
				av0.set_process(false)
			var sp0: Vector2 = dot.get("pos", Vector2.ZERO)
			var pv: Dictionary = _crowd_prev.get(aid, {})
			if pv.is_empty() or (sp0 - (pv["pos"] as Vector2)).length() > 0.001 or now_h - float(pv["h"]) > 1.0:
				_crowd_prev[aid] = {"pos": sp0, "h": now_h, "from": pv.get("pos", sp0) if not pv.is_empty() else sp0,
					"from_h": float(pv.get("h", now_h)) if not pv.is_empty() else now_h}
			if push_crowd:
				var rec: Dictionary = _crowd_prev[aid]
				crowd_entries.append({"id": aid, "prev": rec.get("from", sp0), "next": sp0,
					"t0": float(rec.get("from_h", now_h)), "t1": float(rec.get("h", now_h)),
					"pose": _crowd_pose_for(dot), "yaw": float(dot.get("face_yaw", 0.0)),
					"color": dot.get("color", Color.WHITE), "morale": float(dot.get("morale", 0.7))})
			_last_pos[aid] = sp0
			continue
		var av: NpcAvatar = _avatars.get(aid)
		if av == null:
			av = NpcAvatar.new()
			av.setup(aid, dot.get("color", Color.WHITE) as Color, str(dot.get("name", "")))
			add_child(av)
			_avatars[aid] = av
		av.status_text = str(dot.get("status", ""))
		av.morale_label = str(dot.get("morale_label", ""))
		av.set_display_name(str(dot.get("name", "")))
		av.set_morale(float(dot.get("morale", 0.0)))
		av.set_morale_trend(_morale_trend_of(aid, float(dot.get("morale", 0.0))))
		av.set_task_text(_task_text_of(dot))
		var sim_pos: Vector2 = dot.get("pos", Vector2.ZERO)
		var dist := (sim_pos - eye).length()
		# Near people carry their morale bar + task tag ambiently — the
		# monitor-the-camp-from-first-person read; far people stay clean.
		av.set_ambient_status(dist < AMBIENT_STATUS_DIST_M)
		# A person someone is PLAYING is never culled, never quarter-rate posed,
		# and always keeps the rigged body: LOD is an economy for background
		# figures, and applying it to a player would make them vanish or stutter
		# for everyone else at exactly the distance the rest of the group stands.
		if bool(dot.get("possessed", false)):
			if not av.visible:
				av.visible = true
				av.set_process(true)
			near.push_front([-1.0, aid])
			_pose_avatar(av, aid, dot, delta)
			continue
		if dist > CULL_DIST_M * _range_scale:
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
		if dist > FAR_DIST_M * _range_scale:
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
	if push_crowd:
		_hero_push_accum = 0.0
		_crowd_renderer.call("set_full_people", crowd_entries, now_h)
	_follow_carried_props(carried)
	_crew_marker_accum += delta
	if _crew_marker_accum >= CREW_MARKER_REFRESH_S:
		_crew_marker_accum = 0.0
		_update_crew_markers()
		_update_fire_rings()
	# Despawn agents that left the roster (count change / pop_driven off).
	# .keys() allocates a fresh Array every call, and the roster is unchanged on
	# the overwhelming majority of frames — if every avatar was seen this frame
	# there is nothing to despawn, and the size comparison settles that without
	# building the array at all.
	if _avatars.size() == seen.size():
		return
	for aid in _avatars.keys():
		if not seen.has(aid):
			var av2: NpcAvatar = _avatars[aid]
			if is_instance_valid(av2):
				av2.queue_free()
			_avatars.erase(aid)
			_last_pos.erase(aid)
			_ground.erase(aid)
			_far_accum.erase(aid)
			_arrive_wait.erase(aid)
			_moved_at.erase(aid)
			_anchor_pos.erase(aid)
			_interp.erase(aid)


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


## Warm night rings at tagged fire-circle spaces — the dance floor as a
## visible destination. The space drives the gathering already; this gives the
## gatherers somewhere to be SEEN heading. Same pooled pattern and cadence as
## the crew markers; visible only at night (a glow ring at noon is chrome).
const FIRE_RING_MAX := 4
var _fire_rings: Array = []   # of Node3D


func _update_fire_rings() -> void:
	var spots: Array = []
	if _bridge != null and _bridge.has_method("space_markers"):
		for m in (_bridge.space_markers(_main) as Array):
			var mark: Dictionary = m
			if str(mark.get("space_type", "")) == "fire_circle" \
					and mark.get("pos") is Vector2:
				spots.append(mark.get("pos"))
				if spots.size() >= FIRE_RING_MAX:
					break
	var night := true
	if _main != null and "day_time" in _main:
		var h := float(_main.day_time)
		night = h < 6.5 or h > 19.5
	for i in FIRE_RING_MAX:
		var have: bool = night and i < spots.size()
		if i >= _fire_rings.size():
			if not have:
				break
			_fire_rings.append(_build_fire_ring())
		var ring := _fire_rings[i] as Node3D
		if not have:
			ring.visible = false
			continue
		var pos: Vector2 = spots[i]
		ring.visible = true
		ring.position = Vector3(pos.x,
			TerrainSurfaceQuery.ground_height_at(_main, pos.x, pos.y) + 0.10, pos.y)


func _build_fire_ring() -> Node3D:
	var root := Node3D.new()
	root.name = "FireRing"
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.45
	torus.outer_radius = 1.65
	torus.rings = 32
	mi.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(1.0, 0.55, 0.22, 0.5)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(mi)
	add_child(root)
	return root


## In-world crew-site markers: pooled discs + readouts at active work sites,
## fed by the same bridge payload the Site Plan draws from. Ground queries run
## only on this coarse cadence for at most CREW_MARKER_MAX sites.
func _update_crew_markers() -> void:
	var marks: Array = []
	if _bridge != null and _bridge.has_method("crew_site_markers"):
		marks = _bridge.crew_site_markers(_main)
	for i in CREW_MARKER_MAX:
		var have := i < marks.size()
		if i >= _crew_markers.size():
			if not have:
				break
			_crew_markers.append(_build_crew_marker())
		var m: Dictionary = _crew_markers[i]
		var root := m["root"] as Node3D
		if not have:
			root.visible = false
			continue
		var mark := marks[i] as Dictionary
		var pos: Vector2 = mark.get("pos", Vector2.ZERO)
		var gy := TerrainSurfaceQuery.ground_height_at(_main, pos.x, pos.y)
		root.visible = true
		root.position = Vector3(pos.x, gy + 0.12, pos.y)
		var quorum := bool(mark.get("quorum", true))
		var col := Color(1.0, 0.72, 0.20, 0.45) if quorum \
			else Color(0.95, 0.55, 0.25, 0.35)
		(m["disc_mat"] as StandardMaterial3D).albedo_color = col
		var lbl := m["label"] as Label3D
		var crew_txt := "%d/%d — waiting" % [int(mark.get("workers", 0)),
				int(mark.get("min_workers", 1))] if not quorum \
			else "%d ppl · %d%%" % [int(mark.get("workers", 0)),
				int(round(float(mark.get("progress", 0.0)) * 100.0))]
		lbl.text = "🔨 %s\n%s" % [str(mark.get("label", "")), crew_txt]
		lbl.modulate = Color(1.0, 0.85, 0.55) if quorum else Color(1.0, 0.7, 0.45)


func _build_crew_marker() -> Dictionary:
	var root := Node3D.new()
	root.name = "CrewSiteMarker%d" % _crew_markers.size()
	add_child(root)
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 2.4
	cyl.bottom_radius = 2.4
	cyl.height = 0.05
	disc.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.72, 0.20, 0.45)
	disc.material_override = mat
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(disc)
	var lbl := Label3D.new()
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.font_size = 40
	lbl.pixel_size = 0.006
	lbl.outline_size = 10
	lbl.position = Vector3(0.0, 2.4, 0.0)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(lbl)
	return {"root": root, "disc_mat": mat, "label": lbl}


## The base of a solo-carried load rides at chest-carry height; a team lift
## rides low (arms down at the sides — the two-person furniture carry).
const CARRY_BASE_SOLO_M := 0.72
const CARRY_BASE_TEAM_M := 0.40
## Solo: the load is held out in front of the carrier.
const CARRY_AHEAD_M := 0.32


## Carried props RIDE THE CARRIERS' HANDS. The real prop node (not a proxy
## box) is repositioned every frame at its carriers' rendered position — solo:
## held out in front; team lift: at the crew's centroid, low — so the actual
## object visibly travels instead of hiding and teleporting at completion.
## Render-side only: the RECORD never moves here (the move is still the
## chore's completion effect), so a preempted carry restores the prop exactly
## where the sim says it is.
##
## Restore discipline: the original transform + collision state are
## snapshotted on first grab. On release the prop is restored ONLY if the
## record still matches the snapshot position (a completed carry has already
## moved the record and rebuilt the node at its new home — snapping THAT back
## to the container would undo the delivery). Re-asserted every frame, so a
## prop rebuild mid-carry self-heals next frame.
func _follow_carried_props(carried: Dictionary) -> void:
	if carried.is_empty() and _carried_state.is_empty():
		return
	for pid in carried:
		var node := _find_prop_node(str(pid))
		if node == null:
			continue
		if not _carried_state.has(pid):
			_carried_state[pid] = {"xf": node.global_transform}
		node.visible = true
		if node.has_method("set_collision_enabled"):
			node.set_collision_enabled(false)   # a load in arms shoves nobody
		var pts: Array = []
		var fwd := Vector2.ZERO
		for aid in (carried[pid] as Array):
			var av: NpcAvatar = _avatars.get(str(aid))
			if av != null and is_instance_valid(av) and av.visible:
				pts.append(av.global_position)
				fwd += Vector2(-sin(av.rotation.y), -cos(av.rotation.y))
		if pts.is_empty():
			# Carrier beyond the cull distance: park the prop hidden (the old
			# behaviour) rather than drawing it floating with nobody near.
			node.visible = false
			continue
		var centre := Vector3.ZERO
		for p in pts:
			centre += p as Vector3
		centre /= float(pts.size())
		var team := pts.size() >= 2
		var want_yaw := atan2(-fwd.x, -fwd.y) if fwd.length() > 0.01 else node.rotation.y
		var base_h := CARRY_BASE_TEAM_M if team else CARRY_BASE_SOLO_M
		var hold := centre
		if not team:
			hold += Vector3(fwd.x, 0.0, fwd.y).normalized() * CARRY_AHEAD_M \
				if fwd.length() > 0.01 else Vector3.ZERO
		hold.y = centre.y + base_h
		node.global_position = hold
		# Yaw the PROP so the model's world heading matches the carriers'
		# (the record's own yaw lives on ModelRoot underneath).
		var mr := node.get_node_or_null("ModelRoot")
		var model_yaw := (mr as Node3D).rotation.y if mr is Node3D else 0.0
		node.rotation = Vector3(0.0, want_yaw - model_yaw, 0.0)
	for pid in _carried_state.keys():
		if carried.has(pid):
			continue
		var st: Dictionary = _carried_state[pid]
		var node2 := _find_prop_node(str(pid))
		if node2 != null and is_instance_valid(node2):
			var rec := PlacedPropService.get_prop_record(_main, str(pid))
			var xf: Transform3D = st.get("xf", Transform3D.IDENTITY)
			var rec_at := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
			var snap_at := Vector2(xf.origin.x, xf.origin.z)
			if rec.is_empty() or (rec_at - snap_at).length() < 0.5:
				# Preempted (or record gone): put it back exactly where it was.
				node2.global_transform = xf
				node2.visible = true
				if node2.has_method("set_collision_enabled"):
					node2.set_collision_enabled(bool(rec.get("collision_enabled", true)))
			# else: the completion effect already moved + rebuilt it — the
			# fresh node is authoritative, touch nothing.
		_carried_state.erase(pid)


func _exit_tree() -> void:
	# The host dying mid-carry (view closed, map change) must not leave crates
	# floating in mid-air or non-colliding until the next full prop rebuild.
	_follow_carried_props({})


func _find_prop_node(prop_id: String) -> Node3D:
	if _main == null or not is_instance_valid(_main):
		return null
	var root := _main.find_child("PlacedProps", true, false)
	if root == null:
		return null
	for child in root.get_children():
		if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
			return child as Node3D
	return null


## Re-tint every already-spawned avatar from NpcDisplayPrefs — called when the
## player flips "show NPC tint colors" mid-session, since new avatars already
## pick up the current pref via color_for_agent() but existing ones don't
## otherwise get revisited (setup() only tints once, on first creation).
func refresh_tints() -> void:
	for aid in _avatars:
		var av: NpcAvatar = _avatars[aid]
		if av != null and is_instance_valid(av):
			av.set_tint(NpcPopulationEngine.color_for_agent(str(aid)))


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


## How near somebody has to be for their overhead bar + task tag to show
## without being aimed at. Under the 45 m rig radius: the readout is for the
## camp you are standing IN, not the whole valley.
const AMBIENT_STATUS_DIST_M := 30.0

## Morale history for the trend tick: agent_id -> [[abs_h, morale], …],
## sampled every TREND_SAMPLE_H sim-hours, kept ~TREND_WINDOW_H deep.
const TREND_SAMPLE_H := 0.25
const TREND_WINDOW_H := 1.25
var _morale_hist: Dictionary = {}


## Morale movement over roughly the last sim-hour. Positive = climbing.
## Sampled on the SIM clock, so a paused world holds its trend instead of
## decaying toward "flat".
func _morale_trend_of(aid: String, morale: float) -> float:
	if _main == null or not _main.has_method("get_absolute_hours"):
		return 0.0
	var now_h := float(_main.call("get_absolute_hours"))
	var hist: Array = _morale_hist.get(aid, [])
	if hist.is_empty() or now_h - float((hist[-1] as Array)[0]) >= TREND_SAMPLE_H \
			or now_h < float((hist[-1] as Array)[0]):   # scrubbed back: restart
		if not hist.is_empty() and now_h < float((hist[-1] as Array)[0]):
			hist = []
		hist.append([now_h, morale])
		while hist.size() > 1 and now_h - float((hist[0] as Array)[0]) > TREND_WINDOW_H:
			hist.pop_front()
		_morale_hist[aid] = hist
	return morale - float((hist[0] as Array)[1])


## One or two words under the morale bar: what this person is doing right now.
## Derived from the dot the same way the pose is, so the tag and the body can
## never tell different stories. Travelling shows where they are HEADED.
static func _task_text_of(dot: Dictionary) -> String:
	var text := ""
	if bool(dot.get("carrying", false)):
		text = "hauling"
	else:
		var wp := str(dot.get("work_pose", ""))
		match wp:
			NpcWorkPose.HAUL_HOLD: text = "hauling"
			NpcWorkPose.LIFT: text = "lifting"
			NpcWorkPose.DIG: text = "working"
			NpcWorkPose.OVERHEAD: text = "building"
			NpcWorkPose.DRILL: text = "drilling"
			NpcWorkPose.BENCH: text = "at the bench"
			NpcWorkPose.INSPECT: text = "inspecting"
	if text.is_empty():
		match str(dot.get("activity", "")):
			"hunger": text = "eating"
			"thirst": text = "drinking"
			"sleep": text = "sleeping"
			"bladder": text = "bathroom"
			"hygiene": text = "washing"
			"chore": text = "working"
			# Before the enrichment SPACE resolves (and on the walk there) the
			# dot still says "enrichment" — the missing case left a blank tag.
			"enrichment": text = "vibing"
			"fire_circle": text = "at the fire"
			"movement": text = "exercising"
			"stage": text = "at the show"
			"temple": text = "at the temple"
			"center_camp": text = "at center camp"
			"art": text = "looking at art"
			"quiet": text = "resting"
			"workshop_social": text = "socialising"
			_: text = ""
	if text.is_empty():
		# Idle is a real state, not missing data — a blank tag reads as a bug.
		return "free"
	if int(dot.get("state", 0)) == NpcAgent.State.TRAVELING:
		return "→ " + text
	return text


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


## Drive one figure for one frame: where it is, which way it faces, and what it
## should be playing.
##
## The movement test used to be `(sim_pos - prev).length() > MOVE_EPS_M`, i.e.
## this frame\'s sim position against last frame\'s. But the sim advances every
## 0.25 s while this runs every frame, so that expression was TRUE for about one
## frame in fifteen and false for the rest — which is precisely the window in
## which the body is gliding toward its target. The figure therefore played its
## arrival pose (lying down, for a trip to bed) while still sliding across the
## site. No epsilon fixes that; it is aliasing a stepped signal, so the signal
## itself has to change.
## A person a remote player is driving. Everything the normal path does to make
## a SIMULATED walk read well works against direct control:
##
##  * the SMOOTH_RATE lerp adds ~125 ms of lag — under a player's own input that
##    reads as the controls being broken, not as smoothing;
##  * `wants_anchor` deliberately PINS the body for up to 1.2 s while a stand-up
##    animation plays, which under control reads as input dropping out;
##  * `paused`/`time_mult` come from the world clock, so a possessed body would
##    go rigid the moment the host paused or scrubbed;
##  * `in_transit` comes from the sim's TRAVELING state, which a possessed agent
##    never enters — so the figure would never play a walk cycle.
##
## The yaw comes from the player's own look direction (published in the presence
## packet), not from the direction of travel: a person can look where they like
## while walking, and deriving it would fight strafing.
func _pose_possessed(av: NpcAvatar, aid: String, dot: Dictionary, delta: float,
		target: Vector3, cur: Vector3, prev: Vector2, sim_pos: Vector2) -> void:
	_arrive_wait.erase(aid)
	_anchor_pos.erase(aid)
	var moved := (sim_pos - prev).length()
	if moved > MOVE_EPS_M:
		_moved_at[aid] = _now
	var in_transit := _now - float(_moved_at.get(aid, -999.0)) < MOVE_HOLD_S
	var yaw := float(dot.get("yaw", av.rotation.y))
	# 1:1 with the incoming position, except for a teleport-scale jump which is
	# still eased so a respawn does not read as a glitch.
	var next := target
	if cur != Vector3.ZERO and cur.distance_to(target) >= TELEPORT_SNAP_M:
		next = cur.lerp(target, minf(delta * SMOOTH_RATE * 3.0, 1.0))
	var apparent := (cur.distance_to(next) / maxf(delta, 0.0001)) if cur != Vector3.ZERO else 0.0
	av.apply_pose(next, yaw, {
		"dt": delta,
		# A human keeps moving even while the world clock is paused or scrubbing.
		"paused": false,
		"apparent_speed_mps": apparent,
		"time_mult": 1.0,
		"anim_map": dot.get("anim_map", {}),
		"in_transit": in_transit,
		"activity": "",
		"space_type": "",
		"morale": float(dot.get("morale", 0.5)),
		"dwell_left_s": 0.0,
		"teleported": false,
	})


func _pose_avatar(av: NpcAvatar, aid: String, dot: Dictionary, delta: float) -> void:
	var sim_pos: Vector2 = dot.get("pos", Vector2.ZERO)
	var prev: Vector2 = _last_pos.get(aid, sim_pos)
	_last_pos[aid] = sim_pos
	var gy := _ground_y(aid, sim_pos)
	var target := Vector3(sim_pos.x, gy, sim_pos.y)
	var cur := av.global_position
	if bool(dot.get("possessed", false)):
		_pose_possessed(av, aid, dot, delta, target, cur, prev, sim_pos)
		return

	# --- tick-to-tick interpolation state -----------------------------------
	# The sim publishes positions as a step function (one jump per 0.25/0.5 s
	# wall tick). At timelapse speeds each step is metres to hundreds of
	# metres; chasing the newest step exponentially produced a sawtooth, and
	# past the snap threshold a hard teleport EVERY tick. Instead: remember
	# the previous tick's target and glide prev→next over the measured tick
	# spacing — continuous piecewise-linear motion, one tick behind the sim,
	# invisible at the speeds where it engages (see INTERP_MIN_STEP_M).
	var st: Dictionary = _interp.get(aid, {})
	if st.is_empty():
		st = {"prev": target, "next": target, "at": _now, "interval": 0.25,
			"step_m": 0.0}
	var moved := (sim_pos - prev).length() > 0.001
	if moved:
		_moved_at[aid] = _now
		var since := _now - float(st["at"])
		if since > 0.02 and since < 1.5:
			st["interval"] = lerpf(float(st["interval"]), since, 0.3)
		st["prev"] = st["next"]
		st["next"] = target
		st["at"] = _now
		st["step_m"] = (sim_pos - prev).length()
	else:
		st["next"] = target   # ground refresh may move Y under a parked dot
	_interp[aid] = st

	# What a WALK could cover in one tick at the current time scale. A step
	# beyond that (× margin) is a genuine relocation — catch-up, scrub, an
	# activity re-seat — and gets the hard snap; a step within it is just
	# timelapse walking and interpolates.
	var scale: float = float(_main.get("time_scale")) if "time_scale" in _main else 1.0
	var expected_step := NpcNav.WALK_SPEED_MPS * absf(scale) * 3600.0 \
		* float(st["interval"])
	var tp_threshold := maxf(TELEPORT_SNAP_M, expected_step * TELEPORT_STEP_MARGIN)
	var step_is_jump := float(st["step_m"]) >= tp_threshold
	var use_interp := float(st["step_m"]) > INTERP_MIN_STEP_M and not step_is_jump
	var desired := target
	if use_interp:
		var f := clampf((_now - float(st["at"]))
			/ maxf(float(st["interval"]) * INTERP_INTERVAL_BIAS, 0.05), 0.0, 1.0)
		desired = (st["prev"] as Vector3).lerp(st["next"] as Vector3, f)
	var gap := cur.distance_to(desired) if cur != Vector3.ZERO else 0.0

	# The sim's own account of whether this person is going somewhere. A LEVEL,
	# not an edge, so it cannot alias against the frame rate.
	var has_state := dot.has("state")
	var travelling := int(dot.get("state", -1)) == NpcAgent.State.TRAVELING
	if not has_state:
		# Degraded path for a dot producer that does not report state: hold the
		# last movement rather than testing an instantaneous delta.
		if (sim_pos - prev).length() > MOVE_EPS_M:
			_moved_at[aid] = _now
		travelling = _now - float(_moved_at.get(aid, -999.0)) < MOVE_HOLD_S

	# Keep walking until the RENDERED body has actually arrived, not merely
	# until the sim says so — that is the half that stops an arrival pose
	# starting mid-slide.
	var wait := float(_arrive_wait.get(aid, 0.0))
	var catching_up := gap > ARRIVE_EPS_M and wait < ARRIVE_MAX_S
	_arrive_wait[aid] = (wait + delta) if catching_up else 0.0
	# Stall veto — CHORE travellers only: a team-lift crew member holding at
	# the pickup is TRAVELING but stationary, and walking in place there
	# reads as a treadmill; with the veto they settle into the chore's own
	# work pose (the carry hold — hands on the load, which is what they are
	# doing). It must NEVER widen to other activities: `activity` is the
	# INTENT, so a stalled walker headed to bed would lie down mid-route —
	# the exact aliasing bug in_transit exists to prevent (and the travel-
	# pose capture check failed precisely that way when this was activity-
	# blind). Tick-aliasing safe: sim positions change at most every 0.5 s
	# wall, under the 0.6 s hold.
	var stalled := str(dot.get("activity", "")) == NpcAgent.CHORE_ACTIVITY \
		and _now - float(_moved_at.get(aid, _now)) > MOVE_HOLD_S
	var in_transit := (travelling and not (stalled and gap <= ARRIVE_EPS_M)) \
		or catching_up

	var teleported := cur != Vector3.ZERO \
		and ((step_is_jump and moved) or gap >= tp_threshold)
	var next := desired
	if not teleported and cur != Vector3.ZERO:
		# In interp mode the goal itself moves continuously, so track it hard
		# (the interpolation IS the smoothing); at 1× keep the long-standing
		# gentle chase.
		var rate := SMOOTH_RATE * 3.0 if use_interp else SMOOTH_RATE
		next = cur.lerp(desired, minf(delta * rate, 1.0))

	# Standing up takes ~1.2 s during which the sim has already set off. Hold
	# the body still so the world does not slide out from under the animation,
	# then let it catch up. Bounded in time AND distance, and abandoned outright
	# on a teleport.
	var held: Variant = _anchor_pos.get(aid)
	if not teleported and av.wants_anchor(
			(held as Vector3).distance_to(desired) if held is Vector3 else 0.0):
		if not (held is Vector3):
			_anchor_pos[aid] = cur
			held = cur
		next = held as Vector3
	elif _anchor_pos.has(aid):
		_anchor_pos.erase(aid)
		# Clear the debt quickly rather than drifting back over seconds.
		next = cur.lerp(desired, minf(delta * SMOOTH_RATE * 3.0, 1.0))

	# Direction of travel while GOING somewhere; the sim's facing hint once
	# stopped.
	#
	# This used to take the travel branch unconditionally and gate it on the
	# delta being big enough — so on arrival `dir` fell under YAW_EPS_M, the
	# branch stopped firing, and the yaw LATCHED on the last approach heading
	# for the entire work session. A whole crew walks one nav route to one
	# chore coordinate, so the whole crew froze on one bearing: the "everyone
	# faces the same way while working" bug. The gate is now on TRAVELLING, not
	# on the size of a vector that is designed to shrink to zero.
	var yaw := av.rotation.y
	var want := float(dot.get("face_yaw", yaw))
	if in_transit:
		# CelestialClock convention: north −Z, east +X; atan2 gives the heading
		# of travel in world yaw. In interp mode the SEGMENT direction is the
		# stable one — the per-frame render delta wobbles inside a segment.
		var dir := sim_pos - Vector2(cur.x, cur.z)
		if use_interp:
			var pv := st["prev"] as Vector3
			var nx := st["next"] as Vector3
			dir = Vector2(nx.x - pv.x, nx.z - pv.z)
		if dir.length() > YAW_EPS_M:
			want = atan2(-dir.x, -dir.y)
		# Below the epsilon we fall through to face_yaw while STILL in transit,
		# so the figure pre-turns toward the work as it arrives instead of
		# holding the corridor bearing and snapping afterwards.
	# Slewed, so a turn reads as a turn — which is also what makes the
	# start/stop walk clips legible. Beyond FAR_DIST_M the pose interval makes
	# this a hard set, which is correct now that `want` is a stable
	# anchor-derived bearing rather than a noisy shrinking delta.
	#
	# Stationary figures additionally get a RATE ceiling: face_yaw carries the
	# idle drift, which runs on the sim clock — at 450× its wander completes
	# in under two wall seconds and read as a head-shake on everyone standing.
	var slewed := lerp_angle(yaw, want, minf(delta * YAW_RATE, 1.0))
	if in_transit:
		yaw = slewed
	else:
		var max_step := YAW_SLEW_IDLE_RAD_S * delta
		yaw += clampf(angle_difference(yaw, slewed), -max_step, max_step)

	# time_scale 0 is paused; negative is a backward scrub, during which the
	# population engine freezes too, so the figures should hold either way.
	# (`scale` was read above for the teleport classification.)
	# What the body is ACTUALLY covering on screen this frame, which is what a
	# gait has to agree with. In interp mode the ANALYTIC segment speed is the
	# honest number — the rendered step inherits smoothing residue and pulses.
	var apparent := (cur.distance_to(next) / maxf(delta, 0.0001)) if cur != Vector3.ZERO else 0.0
	if use_interp:
		apparent = float(st["step_m"]) / maxf(float(st["interval"]), 0.05)
	av.apply_pose(next, yaw, {
		"dt": delta,
		"paused": scale <= 0.0,
		"apparent_speed_mps": apparent,
		# time_scale is sim-HOURS per real second; x3600 gives sim seconds per
		# real second, i.e. the multiplier the world is running at.
		"time_mult": absf(scale) * 3600.0,
		"anim_map": dot.get("anim_map", {}),
		"in_transit": in_transit,
		"activity": str(dot.get("activity", "")),
		"space_type": str(dot.get("space_type", "")),
		"morale": float(dot.get("morale", 1.0)),
		"dwell_left_s": _dwell_left_s(dot),
		"teleported": teleported,
		"carrying": bool(dot.get("carrying", false)),
		# The REAL prop rides the carriers' hands (see _follow_carried_props)
		# — the avatar suppresses its generic chest box so the load is not
		# drawn twice. Brigade station workers have no carry_prop and keep
		# the generic box.
		"carry_prop_live": bool(dot.get("carrying", false))
			and not str(dot.get("carry_prop", "")).is_empty(),
		# Two or more sets of hands on one load = the low team-lift posture.
		"carry_heavy": int(_carry_group_of.get(aid, 0)) >= 2,
		"work_pose": str(dot.get("work_pose", "")),
	})


## Real seconds left in the current activity. The engine keeps sim-hours; the
## conversion belongs here because only the presentation layer cares about wall
## clock, and it is what decides whether a sit-down is worth starting at all.
func _dwell_left_s(dot: Dictionary) -> float:
	var ends_h := float(dot.get("ends_h", 0.0))
	if is_inf(ends_h):
		return INF      # chores end when the work is done, not on a clock
	if _main == null or not _main.has_method("get_absolute_hours"):
		return INF
	var now_h := float(_main.call("get_absolute_hours"))
	var scale: float = float(_main.get("time_scale")) if "time_scale" in _main else 1.0
	if scale <= 0.0001:
		return INF      # paused: no reason to rush
	return maxf(ends_h - now_h, 0.0) / scale


## The view hands over the CrowdRenderer so full-tier people past the hero
## budget have somewhere to be drawn. Without one everybody is a hero.
func set_crowd_renderer(cr: Node) -> void:
	_crowd_renderer = cr


func hero_budget() -> int:
	var q := int(_main.get("graphics_quality")) if _main != null and _main.get("graphics_quality") != null \
		else RenderProfile.QUALITY_HIGH
	return int(RenderProfile.npc_profile(q).get("hero_max", 40))


## Which full-tier ids keep an NpcAvatar this frame: everyone when the roster
## fits the budget or there is no crowd renderer; else the nearest `hero_max`
## to the viewer (current heroes get HERO_HYSTERESIS_M of grace; possessed
## and focused people are always heroes).
func _pick_heroes(dots: Array, eye: Vector2) -> Dictionary:
	var full: Array = []
	for dot_v in dots:
		if dot_v is Dictionary and str((dot_v as Dictionary).get("tier", "")) != "light":
			full.append(dot_v)
	var budget := hero_budget()
	var out: Dictionary = {}
	if _crowd_renderer == null or not is_instance_valid(_crowd_renderer) or full.size() <= budget:
		for d in full:
			out[str((d as Dictionary).get("id", ""))] = true
		_hero_ids = out
		return out
	var ranked: Array = []
	for d in full:
		var dd: Dictionary = d
		var aid := str(dd.get("id", ""))
		if bool(dd.get("possessed", false)) or aid == _focus_id:
			out[aid] = true
			continue
		var dist := ((dd.get("pos", Vector2.ZERO) as Vector2) - eye).length()
		if _hero_ids.has(aid):
			dist -= HERO_HYSTERESIS_M
		ranked.append([dist, aid])
	ranked.sort_custom(func(a, b):
		if is_equal_approx(float(a[0]), float(b[0])):
			return str(a[1]) < str(b[1])
		return float(a[0]) < float(b[0]))
	for r in ranked:
		if out.size() >= budget:
			break
		out[str(r[1])] = true
	_hero_ids = out
	return out


## A crowd pose code for a full-tier dot (the cohort's own vocabulary).
static func _crowd_pose_for(dot: Dictionary) -> int:
	if int(dot.get("state", -1)) == NpcAgent.State.TRAVELING:
		return CrowdCohort.POSE_WALK
	var act := str(dot.get("activity", ""))
	if act == "sleep":
		return CrowdCohort.POSE_LIE
	if act in ["eat", "bathroom", "rest", "hunger"]:
		return CrowdCohort.POSE_SIT
	if act == "chore" or act == "work" or not str(dot.get("work_pose", "")).is_empty():
		return CrowdCohort.POSE_WORK
	if act == "enrichment" or act == "social":
		return CrowdCohort.POSE_DANCE
	return CrowdCohort.POSE_STAND
