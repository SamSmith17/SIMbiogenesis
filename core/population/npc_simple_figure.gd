class_name NpcSimpleFigure
extends Node3D

## An articulated stick-figure body: head, torso, arms with elbows, legs with
## knees — posed procedurally rather than by animation clips.
##
## ## Why this exists
##
## The Mixamo body is photoreal enough that any imperfection in how it is
## driven reads as uncanny; a stylised figure has no such contract with the
## viewer, so the same approximate motion reads as deliberate. This is
## therefore not a fallback for missing art — it is a style the player can
## choose, and on that setting it is the *preferred* body.
##
## ## How it stays honest
##
## It is posed from the SAME `NpcPoseMachine` output the rigged body uses, so
## behaviour is identical between the two styles: people walk the whole way,
## lie down on arrival, sit for the bathroom, dance at the fire. Only the
## rendering differs. There is deliberately no second behaviour system here —
## the machine already answers "what should this person be doing", and
## duplicating that judgement is how the two styles would drift apart.
##
## Everything is a capsule under a joint hierarchy, so a pose is a handful of
## Euler angles. No skinning, no skeleton, no animation player.

const HEIGHT_M := 1.7
const HEAD_R := 0.115
const TORSO_H := 0.58
const TORSO_R := 0.15
const HIP_Y := 0.86            # hip pivot height when standing
const SHOULDER_Y := 1.40
const UPPER_ARM := 0.30
const FOREARM := 0.28
const ARM_R := 0.052
const THIGH := 0.44
const SHIN := 0.42
const LEG_R := 0.066
const SHOULDER_X := 0.19
const HIP_X := 0.10

## Capsules deliberately overshoot their joint pivots and overlap their
## neighbour so a joint reads as one contiguous limb rather than two capsules
## floating end-to-end. Each pivot node stays exactly where it was (the pose
## rotates about the real anatomical joint) — only the mesh geometry extends
## past it.
const HIP_OVERLAP := 0.05     # torso extends down / thigh extends up
const KNEE_OVERLAP := 0.05    # thigh extends down / shin extends up
const ELBOW_OVERLAP := 0.04   # upper arm extends down / forearm extends up

## The head pivot's height when standing (the avatar lowers its labels by
## how far below this the head is — head_height()).
const STANDING_HEAD_Y := SHOULDER_Y + 0.10


## The head pivot's height above this figure's feet right now.
func head_height() -> float:
	if _head == null:
		return STANDING_HEAD_Y
	return to_local(_head.global_position).y


## Gait cadence at the sim's nominal walking speed. Scaled by the playback rate
## the avatar passes in, so the simplified body time-lapses with the clock
## exactly as the rigged one does.
const STRIDE_HZ := 0.95

var _tint := Color(0.6, 0.65, 0.8)
var _mat: ShaderMaterial = null
var _body: Node3D = null           # everything below the world transform
var _torso: Node3D = null
var _head: Node3D = null
var _hip: Array[Node3D] = []       # [L, R] thigh pivots
var _knee: Array[Node3D] = []      # [L, R] shin pivots
var _shoulder: Array[Node3D] = []  # [L, R] upper-arm pivots
var _elbow: Array[Node3D] = []     # [L, R] forearm pivots
## [L, R] wrist pivots at the end of each forearm: the hand hangs off it, a
## held tool hangs off its "ToolMount", and the IK turns it to a tool's grip.
var _wrist: Array[Node3D] = []

# --- authored clip + IK layer (the fabrication swarm, phase B2) ------------
## The palm centre in the wrist's frame (the hand hangs along -Y).
const PALM_OFFSET := Vector3(0.0, -0.075, 0.0)
var _clip: NpcAnimClip = null
var _clip_t := 0.0
var _clip_w := 0.0
## [i] = the PALM's world transform the hand must reach (FabToolCatalog's
## hand frame), or null.
var _hand_target: Array = [null, null]
## [i] = the ankle's world position for a planted foot, or null.
var _foot_target: Array = [null, null]
var _layered := false
## Carried-crate visual (Site Projects haul leg). Child of the TORSO on the
## same side the arms reach (the clap-hold direction), so box and hands stay
## coherent whatever the world yaw. Shown only while the pose machine plays
## the logical carry gait.
var _carry_box: MeshInstance3D = null
## True while the REAL prop node is riding this carrier's hands (host-side
## follow) — the internal generic box would double-draw the load.
var _carry_box_suppressed := false


func set_carry_box_suppressed(suppressed: bool) -> void:
	_carry_box_suppressed = suppressed


## HIGH-DETAIL build (the PLAYER's own body — set before setup()). Same
## silhouette style and the same procedural poses, with more anatomy (waist,
## pelvis and shoulder girdle, neck, hands, feet that stay level) and two extra
## pivots the player's driver writes directly: a LEAN pivot at the hips (lean
## into a run, into a turn — layered on top of whatever the pose eases the
## torso to, so the two never fight) and a NECK pivot (the head follows where
## the camera looks). NPCs never set it: a crowd does not need the triangles.
var hi_detail := false

## The music this figure dances to (StageBeat.at, set by the avatar every
## frame while it dances; {} = none — the poses keep their own clock).
var _beat: Dictionary = {}


func set_beat(b: Dictionary) -> void:
	_beat = b


## The dance clock in radians when on the beat: one PI per beat (so a
## |sin| bounce lands once a beat and a sway takes two), half of all people a
## beat out from the other half. NAN when there is no music.
func _beat_rad() -> float:
	if _beat.is_empty():
		return NAN
	return float(_beat.get("beat", 0.0)) * PI + (PI if _mirror < 0.0 else 0.0)


## How hard to throw it on the music: the energy (a breakdown is half a
## dance), and a big kick on the drop.
func _beat_hype() -> float:
	if _beat.is_empty():
		return 1.0
	return (0.5 + 0.5 * clampf(float(_beat.get("energy", 1.0)), 0.0, 1.0)) \
		* (1.0 + 1.6 * float(_beat.get("drop_pulse", 0.0)))


## Hands up for the drop: 0..1 through the run-up (three in four dancers).
func _beat_hands_up() -> float:
	# _lean is uniform in ±0.06: the top quarter keep dancing as they were.
	if _beat.is_empty() or _lean > 0.03:
		return 0.0
	# Up through the run-up and still up as the drop lands (the jump).
	return maxf(smoothstep(0.0, 0.35, StageBeat.anticipation(_beat)),
		smoothstep(0.15, 0.6, float(_beat.get("drop_pulse", 0.0))))

var _lean_pivot: Node3D = null
var _neck: Node3D = null
var _feet: Array[Node3D] = []
var _head_meshes: Array[MeshInstance3D] = []
var _phase := 0.0
## Per-agent flavour, all set once in setup(). Applied ONLY in the asymmetric
## work families: mirroring a contralateral gait just phase-shifts it, and
## mirroring the lying/sitting poses risks fighting _place_body's cos(pitch)
## correction for no visible gain.
var _mirror := 1.0     ## handedness, ±1
var _amp := 1.0        ## limb throw, ~0.85..1.15
var _stance := 1.0     ## feet apart, ~0.90..1.15
var _tempo := 1.0      ## cycle rate WITHIN a pose, ~0.85..1.15
var _lean := 0.0       ## resting torso pitch, ±0.06 rad
var _variant := 0      ## discrete pick inside a family
var _flavor := ""      ## per-frame rendering hint from the avatar (see pose())
var _seed_key := ""

## Glow sticks: the same carrier rule, styles and six-colour palette as
## crowd_figure.gdshader (seed = NpcHash.unit01(id, "pose")), so a person's
## bands keep their colour when they move between the two renderers.
const GLOW_PALETTE: Array = [Color(0.25, 1.0, 0.35), Color(1.0, 0.22, 0.72), Color(0.2, 0.85, 1.0),
	Color(1.0, 0.92, 0.22), Color(1.0, 0.5, 0.12), Color(0.62, 0.32, 1.0)]
static var _glow_shader: Shader = null


## {carries, wrists, neck, head, color} for a person — pure, the shader's rule.
static func glow_for(agent_id: String) -> Dictionary:
	var seed := NpcHash.unit01(agent_id, "pose")
	var style := fposmod(seed * 3.1, 1.0)
	var carries := fposmod(seed * 13.7, 1.0) < 0.72
	var ci := int(floor(fposmod(seed * 5.3, 1.0) * 6.0)) % 6
	# Wristbands only — the BODY glow (mood / peak experience) is the
	# headline; necklaces and headbands made a night crowd unreadable.
	return {"carries": carries, "wrists": carries, "neck": false,
		"head": false, "color": GLOW_PALETTE[ci], "style": style}


func setup(seed_key: String, tint: Color) -> void:
	_tint = tint
	_seed_key = seed_key
	# Desynchronise gaits so a crowd is not a chorus line, deterministically.
	# NpcHash, not `hash() % n` — over 64 sequential ids the naive form leaves
	# five of eight buckets EMPTY, which is a chorus line with extra steps.
	_phase = NpcHash.unit01(seed_key) * TAU
	# Per-agent FLAVOUR, cached once. It lives here rather than on the dot
	# payload because it is pure rendering: the pose machine decides the
	# family (behaviour, and identical across both body styles), the figure
	# decides how this particular person does it. Caching also keeps
	# agent_dots() from hashing six strings per agent per tick.
	_mirror = -1.0 if NpcHash.unit01(seed_key, "hand") < 0.5 else 1.0
	_amp = 0.85 + 0.30 * NpcHash.unit01(seed_key, "amp")
	_stance = 0.90 + 0.25 * NpcHash.unit01(seed_key, "stance")
	# ⚠ Tempo scales each pose's OWN frequency constant, never `_phase`'s
	# advance in pose() — that advance is what rate-matches the walk to the
	# body's apparent speed, and scaling it reproduces exactly the foot-skating
	# NpcAvatar._refresh_speed_scale exists to remove.
	_tempo = 0.85 + 0.30 * NpcHash.unit01(seed_key, "tempo")
	_lean = (NpcHash.unit01(seed_key, "lean") - 0.5) * 0.12
	_variant = NpcHash.pick(seed_key, "var", 2)
	_build()


# --- mo-cap spice ---------------------------------------------------------
# A real motion-captured clip, now and then, on these same capsules (see
# NpcMocapSpice for when, NpcStickMocap for how). The procedural pose still
# runs EVERY frame underneath; its result is cached and the clip's pose is
# cross-faded over it, so fading back out lands exactly on whatever the
# procedural body is doing by then — seamless both ways — and a missing clip
# simply means the procedural pose is all there is.

var _mc: NpcStickMocap = null
var _mc_allowed := false
var _mc_playing := false
var _mc_w := 0.0
var _mc_moment := ""
var _mc_t := 0.0
var _mc_window := -1
var _mc_epoch := 0
var _mc_hold := 0.0
var _mc_rate := 1.0
var _mc_idle_s := 0.0
## The procedural pose of the last frame (restored before the next one so the
## procedural easing never starts from a blended pose).
var _proc: Array = []
## Seconds a hidden skeleton is kept after its last clip before it is freed.
const MC_KEEP_S := 30.0


## The host's budget: only the nearest few stick figures may break into
## mo-cap (each needs a hidden skeleton).
func set_mocap_allowed(on: bool) -> void:
	_mc_allowed = on
	if not on and _mc_playing:
		_mc_playing = false


## True while a mo-cap clip has (any share of) the body — harness/diagnostics.
func mocap_clip() -> String:
	return _mc.clip if _mc != null and _mc_w > 0.0 else ""


func mocap_weight() -> float:
	return _mc_w


## Start a mo-cap clip now (the diagnostics studio; normally NpcMocapSpice
## decides). False when the clip is not installed.
func force_mocap(clip_name: String, moment: String = "dance", rate: float = 1.0) -> bool:
	return _mc_begin(clip_name, moment, rate)


func _joints() -> Array:
	var js: Array = [_torso, _head, _shoulder[0], _shoulder[1], _elbow[0], _elbow[1],
		_hip[0], _hip[1], _knee[0], _knee[1]]
	# Everything a layer may write must be restored before the next procedural
	# step too: the wrists always, the hi-detail pivots when they exist.
	js.append_array(_wrist)
	for n in [_lean_pivot, _neck]:
		if n != null:
			js.append(n)
	js.append_array(_feet)
	return js


## Euler ROTATIONS, not bases: the procedural easing lerps Euler angles, and a
## basis written back re-decomposes to whichever equivalent angles Godot
## picks, which can send a limb the long way round.
func _save_proc() -> void:
	_proc = [_body.position, _body.rotation]
	for n in _joints():
		_proc.append((n as Node3D).rotation)


func _restore_proc() -> void:
	if _proc.size() < 2:
		return
	_body.position = _proc[0]
	_body.rotation = _proc[1]
	var js := _joints()
	for i in js.size():
		(js[i] as Node3D).rotation = _proc[i + 2]


func _update_spice(clip: String, rate: float, dt: float, flavor: String) -> void:
	var moment := NpcMocapSpice.moment_for(clip, flavor) if _mc_allowed else ""
	if moment != _mc_moment:
		_mc_moment = moment
		_mc_t = 0.0
		_mc_window = -1
		_mc_epoch += 1
		# The context changed (they started walking, sat down, the set
		# ended): hand the body back.
		_mc_playing = false
	_mc_t += dt
	if _mc_playing:
		_mc_hold -= dt
		if _mc_hold <= 0.0:
			_mc_playing = false
		return
	var level := NpcDisplayPrefs.mocap_spice()
	if moment.is_empty() or level <= 0.0 or rate <= 0.0 or _mc_w > 0.0:
		return
	var spec: Dictionary = NpcMocapSpice.MOMENTS.get(moment, {})
	var per := float(spec.get("period_s", 0.0))
	var window := 0 if per <= 0.0 else int(floor(_mc_t / per))
	if window == _mc_window:
		return
	_mc_window = window
	# A periodic moment rolls from its SECOND window: the procedural pose
	# establishes the scene, the clip is the break in it.
	if per > 0.0 and window == 0:
		return
	var pick := NpcMocapSpice.pick(_seed_key, moment, window + _mc_epoch * 1000, level,
		NpcRig.moment_clips(moment))
	if not pick.is_empty():
		_mc_begin(pick, moment, rate)


func _mc_begin(clip_name: String, moment: String, rate: float) -> bool:
	if _mc == null:
		_mc = NpcStickMocap.new()
		_mc.name = "Mocap"
		add_child(_mc)
	if not _mc.play(clip_name):
		return false
	_mc_rate = minf(maxf(rate, 0.05), NpcMocapSpice.MAX_RATE)
	_mc_hold = NpcMocapSpice.hold_s(moment, _mc.clip_length(), _mc_rate)
	_mc_playing = true
	_mc_idle_s = 0.0
	return true


func _apply_mocap(rate: float, dt: float) -> void:
	_mc_w = move_toward(_mc_w, 1.0 if _mc_playing else 0.0, dt / NpcMocapSpice.FADE_S)
	if _mc == null:
		_mc_w = 0.0
		return
	_mc_rate = minf(maxf(rate, 0.0), NpcMocapSpice.MAX_RATE)
	_mc.advance(dt * _mc_rate)
	if _mc_w <= 0.0:
		_mc.stop()
		return
	var sol := NpcStickMocap.solve_points(_mc.sample(), {
		"hip_y": HIP_Y, "scale": HIP_Y / NpcRig.native_hips_y()})
	if sol.is_empty():
		return
	var w := smoothstep(0.0, 1.0, _mc_w)
	_body.position = _body.position.lerp(sol["body_pos"], w)
	_body.basis = _slerp_basis(_body.basis, sol["body_basis"], w)
	_torso.basis = _slerp_basis(_torso.basis, sol["torso"], w)
	_head.basis = _slerp_basis(_head.basis, sol["head"], w)
	for i in 2:
		_shoulder[i].basis = _slerp_basis(_shoulder[i].basis, (sol["shoulder"] as Array)[i], w)
		_elbow[i].basis = _slerp_basis(_elbow[i].basis, (sol["elbow"] as Array)[i], w)
		_hip[i].basis = _slerp_basis(_hip[i].basis, (sol["hip"] as Array)[i], w)
		_knee[i].basis = _slerp_basis(_knee[i].basis, (sol["knee"] as Array)[i], w)


static func _slerp_basis(a: Basis, b: Basis, w: float) -> Basis:
	var qa := a.orthonormalized().get_rotation_quaternion()
	var qb := b.orthonormalized().get_rotation_quaternion()
	return Basis(qa.slerp(qb, w))


# --- authored clips, held tools and IK (fabrication swarm, B2) --------------

## NpcAnimClip joint name -> this figure's pivot (absent pivots are skipped:
## the plain build has no lean, neck or feet).
func joint_map() -> Dictionary:
	var m := {"torso": _torso, "head": _head, "lean": _lean_pivot, "neck": _neck}
	for i in 2:
		var sfx := "_r" if i == 0 else "_l"
		if i < _shoulder.size():
			m["shoulder" + sfx] = _shoulder[i]
			m["elbow" + sfx] = _elbow[i]
			m["wrist" + sfx] = _wrist[i]
			m["hip" + sfx] = _hip[i]
			m["knee" + sfx] = _knee[i]
		if i < _feet.size():
			m["foot" + sfx] = _feet[i]
	var out := {}
	for k in m:
		if m[k] != null:
			out[k] = m[k]
	return out


## Play an authored clip at time `t` (seconds) with blend weight `w` over the
## procedural pose. The caller owns the clock (a build timeline scrubs it);
## null clears.
func set_clip(clip: NpcAnimClip, t: float, w: float = 1.0) -> void:
	_clip = clip
	_clip_t = t
	_clip_w = clampf(w, 0.0, 1.0)


func clear_clip() -> void:
	_clip = null
	_clip_w = 0.0


func _clip_layer_on() -> bool:
	return _clip != null and _clip_w > 0.0


func _apply_clip() -> void:
	var smp := _clip.sample(_clip_t)
	var w := _clip_w
	var jm := joint_map()
	var joints: Dictionary = smp["joints"]
	for name in joints:
		var n: Node3D = jm.get(name)
		if n == null:
			continue
		n.basis = _slerp_basis(n.basis, Basis(joints[name] as Quaternion), w)
	var body: Dictionary = smp["body"]
	if body.has("y"):
		_body.position.y = lerpf(_body.position.y, float(body["y"]), w)
	if body.has("pitch"):
		_body.rotation.x = lerp_angle(_body.rotation.x, float(body["pitch"]), w)
	if body.has("yaw"):
		_body.rotation.y = lerp_angle(_body.rotation.y, float(body["yaw"]), w)


## Reach hand `i` (0 = right) for a palm placement in WORLD space (a tool's
## grip socket: FabToolCatalog's hand frame). null releases it.
func set_hand_target(i: int, palm_world) -> void:
	if i >= 0 and i < 2:
		_hand_target[i] = palm_world if palm_world is Transform3D else null


## Plant foot `i` (0 = right) at a WORLD ankle position. null releases it.
func set_foot_target(i: int, ankle_world) -> void:
	if i >= 0 and i < 2:
		_foot_target[i] = ankle_world if ankle_world is Vector3 else null


func _ik_on() -> bool:
	return _hand_target[0] != null or _hand_target[1] != null \
		or _foot_target[0] != null or _foot_target[1] != null


## The elbow points out, back and a little down; the knee forward.
const _ELBOW_POLE := Vector3(0.35, -0.25, -0.55)
const _KNEE_POLE := Vector3(0.05, -0.2, 0.6)


func _apply_ik() -> void:
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		if _hand_target[i] != null and i < _shoulder.size():
			var palm: Transform3D = _hand_target[i]
			var wrist_world := palm * Transform3D(Basis(), PALM_OFFSET).affine_inverse()
			var tw := _torso.global_transform
			var inv := tw.affine_inverse()
			var root := _shoulder[i].position
			var target := inv * wrist_world.origin
			var pole := root + Vector3(_ELBOW_POLE.x * side, _ELBOW_POLE.y, _ELBOW_POLE.z)
			var sol := NpcLimbIk.solve(root, target, pole, UPPER_ARM, FOREARM, -1.0)
			_shoulder[i].basis = sol["root_basis"]
			_elbow[i].basis = Basis(Vector3(1, 0, 0), float(sol["mid_angle"]))
			_wrist[i].basis = NpcLimbIk.hand_local(_elbow[i].global_basis, wrist_world.basis)
		if _foot_target[i] != null and i < _hip.size():
			var bw := _body.global_transform
			var root2 := _hip[i].position
			var target2: Vector3 = bw.affine_inverse() * (_foot_target[i] as Vector3)
			var pole2 := root2 + Vector3(_KNEE_POLE.x * side, _KNEE_POLE.y, _KNEE_POLE.z)
			var sol2 := NpcLimbIk.solve(root2, target2, pole2, THIGH, SHIN, 1.0)
			_hip[i].basis = sol2["root_basis"]
			_knee[i].basis = Basis(Vector3(1, 0, 0), float(sol2["mid_angle"]))


## Hold a tool in hand `i`: the tool hangs off the wrist so its grip socket
## sits on the palm (the tool moves WITH the hand — a carried tool, or a keyed
## clip with no IK). For a tool that follows its own path (LinkageBuildOps),
## place the tool in the world and use set_hand_target(tool grip) instead.
func attach_tool(i: int, tool: Node3D, socket: String = "grip") -> void:
	if i < 0 or i >= _wrist.size() or tool == null:
		return
	detach_tool(i)
	var s: Dictionary = tool.get_meta("sockets", {})
	var grip = s.get(socket)
	var mount := _wrist[i].get_node("ToolMount") as Node3D
	if tool.get_parent() != null:
		tool.get_parent().remove_child(tool)
	mount.add_child(tool)
	tool.transform = (grip as Transform3D).affine_inverse() if grip is Transform3D else Transform3D()


## Let go of hand i's tool (returned, still alive, unparented).
func detach_tool(i: int) -> Node3D:
	if i < 0 or i >= _wrist.size():
		return null
	var mount := _wrist[i].get_node("ToolMount") as Node3D
	if mount.get_child_count() == 0:
		return null
	var tool := mount.get_child(0) as Node3D
	mount.remove_child(tool)
	return tool


## The palm's world transform for hand i (hand frame: see FabToolCatalog).
func palm_global(i: int) -> Transform3D:
	if i < 0 or i >= _wrist.size():
		return Transform3D()
	return _wrist[i].global_transform * Transform3D(Basis(), PALM_OFFSET)


## The pose for this frame: the procedural pose, with any mo-cap spice
## cross-faded over it (see "mo-cap spice" above).
func pose(clip: String, rate: float, dt: float, flavor: String = "") -> void:
	if _body == null:
		return
	# Layers (mo-cap spice, an authored clip, hand / foot IK) write over the
	# procedural pose; the procedural pose is restored before its next step
	# so its easing never starts from a layered pose.
	if _layered:
		_restore_proc()
	_pose_procedural(clip, rate, dt, flavor)
	_update_spice(clip, rate, dt, flavor)
	var mocap := _mc_w > 0.0 or _mc_playing
	_layered = mocap or _clip_layer_on() or _ik_on()
	if _layered:
		_save_proc()
	if mocap:
		_apply_mocap(rate, dt)
	elif _mc != null:
		_mc_idle_s += dt
		if _mc_idle_s > MC_KEEP_S:
			_mc.queue_free()
			_mc = null
	if _clip_layer_on():
		_apply_clip()
	if _ik_on():
		_apply_ik()


## `clip` is the pose machine's chosen clip; `rate` its playback rate (so the
## figure speeds up with the world clock); `dt` real seconds. `flavor` is an
## optional rendering hint from the avatar ("urgent" = hurrying to the
## bathroom: the walk keeps its legs but pulls the arms in and shortens the
## neck — the classic pee-walk, now used ONLY where it is true).
func _pose_procedural(clip: String, rate: float, dt: float, flavor: String = "") -> void:
	if _body == null:
		return
	var r := clampf(rate, 0.0, 12.0)
	_phase += dt * TAU * STRIDE_HZ * maxf(r, 0.001)
	_flavor = flavor
	# Matched on the LOGICAL clip, before the file mapping collapses it onto
	# the plain walk/idle (which is only right for the rigged body).
	if _carry_box != null:
		_carry_box.visible = (clip == NpcRig.CLIP_CARRY
			or clip == NpcRig.CLIP_CARRY_IDLE) and not _carry_box_suppressed
	if clip == NpcRig.CLIP_CARRY:
		_pose_carry(dt)
		return
	if clip == NpcRig.CLIP_CARRY_IDLE:
		_pose_carry_idle(dt)
		return
	# FUCK YES!!!: the peak samba wins over the venue's flavour.
	if clip == NpcRig.CLIP_PEAK_DANCE:
		_pose_samba(dt)
		return
	# Ground poses and the burn's roles (logical clips — see NpcRig).
	match clip:
		NpcRig.CLIP_SIT_CROSS:
			_pose_sit_cross(dt)
			return
		NpcRig.CLIP_LOUNGE:
			_pose_lounge(dt)
			return
		NpcRig.CLIP_KNEEL:
			_pose_kneel(dt)
			return
		NpcRig.CLIP_REDIRECT:
			_pose_redirect(dt)
			return
		NpcRig.CLIP_FIREFLOW:
			_pose_fire_flow(dt)
			return
		NpcRig.CLIP_GAZE:
			_pose_gaze(dt)
			return
	# Shared moments and the decks (venue hints the avatar passes as flavour).
	if _flavor == "cheer":
		_pose_cheer(dt)
		return
	if _flavor == "dj":
		_pose_dj(dt)
		return
	# Work FAMILIES, also matched on the logical name — _clip_file_for collapses
	# every one of them onto CLIP_WORK for the rigged body, which is right there
	# and wrong here. This is the whole reason the stick figure can be more
	# expressive than the (single-work-clip, gitignored) Mixamo body.
	match clip:
		NpcWorkPose.CLIP_WORK_ENTER:
			_pose_work_enter(dt)
			return
		NpcWorkPose.CLIP_WORK_EXIT:
			_pose_work_exit(dt)
			return
		"work_lift":
			_pose_lift(dt)
			return
		"work_dig":
			_pose_dig(dt)
			return
		"work_overhead":
			_pose_overhead(dt)
			return
		"work_drill":
			_pose_drill(dt)
			return
		"work_bench":
			_pose_bench(dt)
			return
		"work_inspect":
			_pose_inspect(dt)
			return
	match NpcPoseMachine._clip_file_for(clip):
		NpcRig.CLIP_WALK, NpcRig.CLIP_WALK_ALT, NpcRig.CLIP_WALK_ALT2:
			_pose_walk(1.0, dt)
		NpcRig.CLIP_WALK_SAD:
			_pose_walk(0.55, dt)      # trudging: shorter stride, less swing
		NpcRig.CLIP_WALK_START, NpcRig.CLIP_WALK_STOP:
			_pose_walk(0.7, dt)
		NpcRig.CLIP_SLEEP, NpcRig.CLIP_SLEEP_ENTER, NpcRig.CLIP_SLEEP_EXIT:
			_pose_lying(dt)
		NpcRig.CLIP_SIT, NpcRig.CLIP_SIT_EXIT, NpcRig.CLIP_CLAP_SIT:
			_pose_sitting(clip == NpcRig.CLIP_CLAP_SIT, dt)
		NpcRig.CLIP_WORK, NpcRig.CLIP_EXERCISE:
			_pose_squat(dt)
		NpcRig.CLIP_DANCE:
			_pose_dance(dt)
		NpcRig.CLIP_CLAP:
			_pose_clap(dt)
		NpcRig.CLIP_IDLE_SAD:
			_pose_idle(true, dt)
		_:
			_pose_idle(false, dt)


## Mood glow / PEAK EXPERIENCE (see npc_silhouette.gdshader).
func set_mood(mood: float, peak: float, flash: float, buzz: float = 0.0) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("buzz", buzz)
	_mat.set_shader_parameter("mood", mood)
	_mat.set_shader_parameter("peak", peak)
	_mat.set_shader_parameter("peak_flash", flash)


func set_tint(tint: Color) -> void:
	_tint = tint
	if _mat != null:
		_mat.set_shader_parameter("rim_color", tint)


# --- poses ------------------------------------------------------------------

## Contralateral gait: each arm swings opposite its leg. Knees bend on the
## recovery (leg swinging forward) and stay near-straight on the stance leg,
## which is the single cue that separates "walking" from "scissoring".
func _pose_walk(amp: float, dt: float) -> void:
	# The URGENT walk: hurrying somewhere with the arms pulled in tight and a
	# clipped, faster-feeling stride — the pee-walk, played only on the way to
	# the bathroom, where it is both funny and true. This is the arms-in shape
	# the ordinary idle USED to have by accident.
	if _flavor == "urgent":
		_pose_walk_urgent(amp, dt)
		return
	if _flavor == "run":
		_pose_run(dt)
		return
	var s := sin(_phase)
	var body_y := HIP_Y + absf(sin(_phase * 2.0)) * 0.022 * amp
	_settle(_torso, Vector3(0.0, 0.0, 0.0), dt)
	_place_body(body_y, 0.0, dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var swing := s * side * 0.62 * amp
		_ease(_hip[i], Vector3(swing, 0.0, 0.0), dt)
		# Knee only bends when the leg is travelling forward.
		var lift := maxf(-s * side, 0.0)
		_ease(_knee[i], Vector3(lift * 0.95 * amp, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-swing * 0.75, 0.0, 0.0), dt)
		_ease(_elbow[i], Vector3(-(0.25 + maxf(s * side, 0.0) * 0.35) * amp, 0.0, 0.0), dt)
	# Trudging drops the head and rounds the shoulders.
	_ease(_head, Vector3(0.30 * (1.0 - amp), 0.0, 0.0), dt)


func _pose_walk_urgent(amp: float, dt: float) -> void:
	var s := sin(_phase)
	_settle(_torso, Vector3(0.14, 0.0, 0.0), dt)
	_place_body(HIP_Y - 0.03 + absf(sin(_phase * 2.0)) * 0.014, 0.0, dt)
	_ease(_head, Vector3(0.08, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		# Short quick steps, knees a touch together.
		var swing := s * side * 0.44 * amp
		_ease(_hip[i], Vector3(swing, 0.0, -0.03 * side), dt)
		_ease(_knee[i], Vector3(maxf(-s * side, 0.0) * 0.75, 0.0, 0.0), dt)
		# Arms clamped in across the front — the tell.
		_ease(_shoulder[i], Vector3(-0.55, 0.0, 0.30 * side), dt)
		_ease(_elbow[i], Vector3(-1.05, 0.0, 0.0), dt)


## Running: a longer stride with a real flight phase (the body rises on each
## push-off), the recovery knee tucked high, arms bent at the elbow and
## pumping, the torso pitched forward and the head kept level against it.
func _pose_run(dt: float) -> void:
	var s := sin(_phase)
	var bounce := absf(sin(_phase))
	_place_body(HIP_Y - 0.05 + bounce * 0.06, 0.0, dt)
	_ease(_torso, Vector3(0.20, -s * 0.10, 0.0), dt, 12.0)
	_ease(_head, Vector3(-0.16, s * 0.08, 0.0), dt, 12.0)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var swing := s * side * 0.95
		_ease(_hip[i], Vector3(swing - 0.10, 0.0, 0.0), dt, 14.0)
		var tuck := maxf(-s * side, 0.0)
		_ease(_knee[i], Vector3(0.25 + tuck * 1.55, 0.0, 0.0), dt, 14.0)
		_ease(_shoulder[i], Vector3(-swing * 0.85 - 0.15, 0.0, -0.06 * side), dt, 14.0)
		_ease(_elbow[i], Vector3(-1.45 + maxf(s * side, 0.0) * 0.25, 0.0, 0.0), dt, 14.0)


## --- the PLAYER's own poses (pose_player) --------------------------------

## In the air: rising out of a jump the knees tuck and the arms come up;
## falling, the legs reach for the ground and the arms spread for balance.
## `vy` m/s, positive up.
func _pose_air(vy: float, dt: float) -> void:
	var up := clampf((vy + 1.0) / 5.0, 0.0, 1.0)    # 1 rising hard .. 0 falling
	_place_body(HIP_Y, 0.0, dt)
	_ease(_torso, Vector3(lerpf(-0.05, 0.12, up), 0.0, 0.0), dt, 12.0)
	_ease(_head, Vector3(lerpf(0.18, -0.10, up), 0.0, 0.0), dt, 12.0)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var stagger := 0.18 * side          # one leg leads
		_ease(_hip[i], Vector3(lerpf(-0.22, -0.75, up) + stagger, 0.0, 0.05 * side), dt, 12.0)
		_ease(_knee[i], Vector3(lerpf(0.30, 1.25, up) - stagger * 0.5, 0.0, 0.0), dt, 12.0)
		_ease(_shoulder[i], Vector3(lerpf(-0.55, -2.1, up), 0.0, lerpf(-0.95, -0.30, up) * side), dt, 12.0)
		_ease(_elbow[i], Vector3(lerpf(-0.25, -0.55, up), 0.0, 0.0), dt, 12.0)


## Seated at the wheel: thighs forward, hands out on the wheel, a little
## steering in the arms from `steer` (-1..1, positive = turning left).
func _pose_drive(steer: float, dt: float) -> void:
	_place_body(HIP_Y * 0.42, 0.0, dt)
	_settle(_torso, Vector3(0.06, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.0, steer * 0.25, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(-1.35, 0.0, 0.08 * side), dt)
		_ease(_knee[i], Vector3(1.20, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-1.10 - steer * side * 0.22, 0.0, 0.10 * side), dt)
		_ease(_elbow[i], Vector3(-0.70, 0.0, 0.0), dt)


## Riding the EUC: standing tall on the pedals, knees soft, arms a little out
## for balance; leaning into a turn is the lean pivot's job (the driver).
func _pose_euc(dt: float) -> void:
	var trim := sin(_phase * 0.6) * 0.04
	_place_body(HIP_Y - 0.04, 0.0, dt)
	_settle(_torso, Vector3(0.06, 0.0, 0.0), dt)
	_ease(_head, Vector3(-0.04, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(-0.14, 0.0, 0.03 * side), dt)
		_ease(_knee[i], Vector3(0.30, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-0.30 + trim * side, 0.0, -0.42 * side), dt)
		_ease(_elbow[i], Vector3(-0.45, 0.0, 0.0), dt)


## Both arms forward at chest height — holding the extinguisher on target.
## Applied OVER the base pose (legs keep walking).
func _pose_aim_arms(dt: float) -> void:
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_shoulder[i], Vector3(-1.40, 0.0, 0.16 * side), dt, 14.0)
		_ease(_elbow[i], Vector3(-0.40, 0.0, 0.0), dt, 14.0)


## The player's body, one frame. `st` = {mode: idle | walk | run | air |
## drive | euc | sit, rate, vy, steer, aim (bool), lean (Vector2: forward,
## roll — radians), look (Vector2: pitch down+, yaw left+)}. The modes the
## NPCs share go through pose() — the same gait, idle and sit — and the rest
## are the player's own. Then the hi-detail layers: lean, head look, feet.
func pose_player(st: Dictionary, dt: float) -> void:
	if _body == null:
		return
	var mode := str(st.get("mode", "idle"))
	var rate := float(st.get("rate", 1.0))
	match mode:
		"walk":
			pose(NpcRig.CLIP_WALK, rate, dt)
		"run":
			pose(NpcRig.CLIP_WALK, rate, dt, "run")
		"sit":
			pose(NpcRig.CLIP_SIT, 1.0, dt)
		"air", "drive", "euc":
			_phase += dt * TAU * STRIDE_HZ
			_flavor = ""
			if _carry_box != null:
				_carry_box.visible = false
			if mode == "air":
				_pose_air(float(st.get("vy", 0.0)), dt)
			elif mode == "drive":
				_pose_drive(float(st.get("steer", 0.0)), dt)
			else:
				_pose_euc(dt)
		_:
			pose(NpcRig.CLIP_IDLE, 1.0, dt)
	if bool(st.get("aim", false)):
		_pose_aim_arms(dt)
	if not hi_detail:
		return
	var lean: Vector2 = st.get("lean", Vector2.ZERO)
	if _lean_pivot != null:
		var k := minf(dt * 6.0, 1.0)
		_lean_pivot.rotation = _lean_pivot.rotation.lerp(Vector3(lean.x, 0.0, lean.y), k)
	var look: Vector2 = st.get("look", Vector2.ZERO)
	if _neck != null:
		var k2 := minf(dt * 10.0, 1.0)
		_neck.rotation = _neck.rotation.lerp(Vector3(clampf(look.x, -0.6, 0.6),
			clampf(look.y, -1.1, 1.1), 0.0), k2)
	# Feet stay level with the ground: undo the leg's own swing at the ankle
	# (and the body's pitch, lying or seated), so a sole never points at the
	# sky mid-stride.
	for i in _feet.size():
		var ft: Node3D = _feet[i]
		var tilt := _hip[i].rotation.x + _knee[i].rotation.x + _body.rotation.x
		ft.rotation.x = clampf(-tilt, -1.2, 1.2)


## First person: the head (and neck) still cast their shadow but are not
## drawn — the camera sits inside them.
func set_head_shown(shown: bool) -> void:
	for mi in _head_meshes:
		if is_instance_valid(mi):
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shown \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY


## Walking while hugging a load to the chest: walk legs with a shortened
## stride, arms locked in the forward hold (the clap shape without its
## oscillation) so they never swing through the carried box, torso leaned
## slightly back as a counterweight.
##
## Flavor "heavy" = a shared TEAM lift: the load rides low between the crew,
## so the arms hang nearly straight down to it, the knees stay bent under the
## weight, the stride shortens further, and the torso leans back harder.
func _pose_carry(dt: float) -> void:
	var heavy := _flavor == "heavy"
	var s := sin(_phase)
	var crouch := 0.05 if heavy else 0.0
	_place_body(HIP_Y - crouch + absf(sin(_phase * 2.0)) * (0.010 if heavy else 0.016),
		0.0, dt)
	_settle(_torso, Vector3(-0.13 if heavy else -0.07, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.16 if heavy else 0.10, 0.0, 0.0), dt)
	var stride := 0.34 if heavy else 0.48
	var sh_pitch := -0.38 if heavy else -1.05
	var el_pitch := -0.30 if heavy else -1.15
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var swing := s * side * stride
		_ease(_hip[i], Vector3(swing, 0.0, 0.0), dt)
		var lift := maxf(-s * side, 0.0)
		_ease(_knee[i], Vector3((0.18 if heavy else 0.0) + lift * 0.8, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(sh_pitch, 0.0, 0.14 * side), dt)
		_ease(_elbow[i], Vector3(el_pitch, 0.0, 0.0), dt)


## The brigade station hold: standing, load hugged to the chest, a light
## breathe — the walk-carry pose with the legs planted. Flavor "heavy" plants
## the same low-hold stance the walking team lift uses.
func _pose_carry_idle(dt: float) -> void:
	var heavy := _flavor == "heavy"
	var breathe := sin(_phase * 0.5) * 0.015
	_place_body(HIP_Y - (0.05 if heavy else 0.0) + breathe, 0.0, dt)
	_settle(_torso, Vector3(-0.12 if heavy else -0.06, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.14 if heavy else 0.08, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.0, 0.0, 0.05 * side), dt)
		_ease(_knee[i], Vector3(0.20 if heavy else 0.08, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-0.38 if heavy else -1.05, 0.0, 0.14 * side), dt)
		_ease(_elbow[i], Vector3(-0.30 if heavy else -1.15, 0.0, 0.0), dt)


func _pose_idle(sad: bool, dt: float) -> void:
	var breathe := sin(_phase * 0.35) * 0.02
	# Standing is never still (unless dejected): a slow weight shift from
	# foot to foot — the loaded leg straight, the other knee eased — the
	# torso countering it, a glance round now and then, and every so often
	# a fidget (hands to the hips, or crossed). Per-person phases.
	var shift := 0.0 if sad else sin(_phase * 0.11 * _tempo + _lean * 20.0)
	var look := 0.0 if sad else sin(_phase * 0.07 * _tempo + float(_variant) * 1.7 + _lean * 9.0)
	var fidget := 0.0 if sad else smoothstep(0.7, 0.95, sin(_phase * 0.045 * _tempo + _lean * 33.0))
	_place_body(HIP_Y + breathe - absf(shift) * 0.015, 0.0, dt)
	_settle(_torso, Vector3(0.12 if sad else breathe, look * 0.22, -shift * 0.06), dt)
	_ease(_head, Vector3(0.42 if sad else breathe * 2.0, look * 0.45, shift * 0.04), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var off_leg := maxf(-shift * side, 0.0)      # this leg unloaded
		_ease(_hip[i], Vector3(-off_leg * 0.08, 0.0, 0.04 * side + shift * 0.05), dt)
		_ease(_knee[i], Vector3(0.05 + off_leg * 0.32, 0.0, 0.0), dt)
		# Arms hang slightly OUT from the body (negative z = away), with a
		# relaxed elbow break. The old +0.16 turned both arms INWARD across
		# the front, which at a glance read as needing the bathroom — that
		# shape now belongs to _pose_walk_urgent, where it is the point.
		var hang := Vector3(shift * side * 0.05, 0.0, (-0.04 if sad else -0.09) * side)
		var elbow := -0.05 if sad else -0.16
		if fidget > 0.0:
			if _variant == 0:
				# Hands on hips: elbows out, forearms back in.
				hang = hang.lerp(Vector3(0.15, 0.0, -0.55 * side), fidget)
				elbow = lerpf(elbow, -1.6, fidget)
			else:
				# Arms crossed in front.
				hang = hang.lerp(Vector3(-0.55, 0.0, 0.25 * side), fidget)
				elbow = lerpf(elbow, -1.9, fidget)
		_ease(_shoulder[i], hang, dt)
		_ease(_elbow[i], Vector3(elbow, 0.0, 0.0), dt)
	if _flavor == "talk" and not sad:
		# In a conversation circle: people take TURNS (speaking ~45 % of the
		# time — the crowd shader's POSE_TALK uses the same shape), the
		# speaker gestures with both hands, listeners nod, and now and then
		# the circle laughs (head back, a bounce).
		var turn := smoothstep(0.1, 0.5, sin(_phase * 0.32 * _tempo + float(_variant) * 2.3 + _lean * 40.0))
		var beat := sin(_phase * 3.1 * _tempo)
		var beat2 := sin(_phase * 2.3 * _tempo + 1.3)
		var laugh := smoothstep(0.9, 1.0, sin(_phase * 0.21 + _lean * 17.0))
		var lead := 0 if _mirror > 0.0 else 1
		var other := 1 - lead
		var ls := 1.0 if lead == 0 else -1.0
		_ease(_shoulder[lead], Vector3(-turn * (0.85 + 0.3 * beat) * _amp, 0.0, -0.12 * ls), dt)
		_ease(_elbow[lead], Vector3(-0.16 - turn * 0.9, 0.0, 0.0), dt)
		_ease(_shoulder[other], Vector3(-turn * (0.35 + 0.3 * beat2) * _amp, 0.0, 0.12 * ls), dt)
		_ease(_elbow[other], Vector3(-0.16 - turn * 0.6, 0.0, 0.0), dt)
		var nod := (1.0 - turn) * maxf(sin(_phase * 1.7 * _tempo + _lean * 5.0), 0.0) * 0.22
		_ease(_head, Vector3(nod - laugh * 0.3, sin(_phase * 0.21 * _tempo) * 0.35, 0.0), dt)
		if laugh > 0.0:
			_place_body(HIP_Y - absf(sin(_phase * 7.0)) * 0.03 * laugh, 0.0, dt)


## Hips drop to seat height, thighs forward, shins down. Reused for the
## seated-clap pose with the arms overridden.
func _pose_sitting(clapping: bool, dt: float) -> void:
	_place_body(HIP_Y * 0.42, 0.0, dt)
	_settle(_torso, Vector3(0.10, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.0, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(-1.35, 0.0, 0.06 * side), dt)
		_ease(_knee[i], Vector3(1.45, 0.0, 0.0), dt)
		if clapping:
			var c := absf(sin(_phase * 2.2)) * 0.30
			_ease(_shoulder[i], Vector3(-1.05, 0.0, (0.32 - c) * side), dt)
			_ease(_elbow[i], Vector3(-1.15, 0.0, 0.0), dt)
		else:
			_ease(_shoulder[i], Vector3(-0.35, 0.0, 0.20 * side), dt)
			_ease(_elbow[i], Vector3(-0.75, 0.0, 0.0), dt)


## Flat on the ground. The body pitches a quarter turn and the whole figure
## drops to lie ON the terrain rather than pivoting about a standing hip.
func _pose_lying(dt: float) -> void:
	# Rest height for the body origin while flat (pitch -90deg): torso radius
	# clears the ground, plus a touch more since the hip/knee bend below pulls
	# the shin's resting point slightly lower than a perfectly straight lie.
	_place_body(0.22, -PI * 0.5, dt)
	_settle(_torso, Vector3(0.0, 0.0, 0.0), dt)
	_ease(_head, Vector3(-0.15, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.10, 0.0, 0.07 * side), dt)
		_ease(_knee[i], Vector3(0.18, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(0.0, 0.0, 0.22 * side), dt)
		_ease(_elbow[i], Vector3(-0.18, 0.0, 0.0), dt)


func _pose_squat(dt: float) -> void:
	var d := (sin(_phase * 1.5) * 0.5 + 0.5)     # 0 = standing, 1 = deep
	_place_body(HIP_Y - d * 0.34, 0.0, dt)
	_settle(_torso, Vector3(d * 0.35, 0.0, 0.0), dt)
	_ease(_head, Vector3(-d * 0.15, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(-d * 0.95, 0.0, 0.12 * side), dt)
		_ease(_knee[i], Vector3(d * 1.5, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-d * 1.4, 0.0, 0.18 * side), dt)
		_ease(_elbow[i], Vector3(-0.30, 0.0, 0.0), dt)


# --- work families (NpcWorkPose) ---------------------------------------------
#
# Each one has to read at ~60 m, where a figure is a few dozen pixels tall and
# only the SILHOUETTE survives: how low the body is, where the arms are, and
# whether the stance is square or staggered. Detail below that threshold costs
# the same to maintain and renders as noise, which is why there are seven of
# these and not twenty. Every one is modulated by the per-agent flavour set in
# setup(), so a crew reads as individuals doing the same job rather than as one
# animation played six times.


## Squat down, grip, stand. The crate family: unloading, packing, fold tests.
func _pose_lift(dt: float) -> void:
	var d := (sin(_phase * 1.1 * _tempo) * 0.5 + 0.5)
	_place_body(HIP_Y - d * 0.40 * _amp, 0.0, dt)
	_settle(_torso, Vector3(_lean + d * 0.55, 0.0, 0.0), dt)
	_ease(_head, Vector3(-d * 0.25, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(-d * 1.05 * _amp, 0.0, 0.14 * side * _stance), dt)
		_ease(_knee[i], Vector3(d * 1.6 * _amp, 0.0, 0.0), dt)
		# Arms hang to the load and rise with the body — the read is "lifting
		# something heavy", so they stay in front and close together.
		_ease(_shoulder[i], Vector3(-0.30 - d * 0.55, 0.0, 0.08 * side), dt)
		_ease(_elbow[i], Vector3(-0.35 - d * 0.55, 0.0, 0.0), dt)


## Stooped over the ground, staggered feet, rocking. The default — most work
## that has no better name looks like this from a distance.
func _pose_dig(dt: float) -> void:
	var s := sin(_phase * 1.35 * _tempo)
	var pull := maxf(s, 0.0)
	# Variant 0 scoops (a deeper stoop on the down-beat), variant 1 pulls
	# (a shallower stoop with more shoulder). Same silhouette family, visibly
	# different rhythm in a group.
	var stoop := (0.95 if _variant == 0 else 0.75) + pull * 0.25
	_place_body(HIP_Y - 0.10 * _amp, 0.0, dt)
	_settle(_torso, Vector3(_lean + stoop, 0.0, 0.0), dt)
	_ease(_head, Vector3(-0.30, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		# Staggered stance — one foot forward. This is the cue that separates
		# digging from the old symmetric squat at any distance.
		var fore := 0.30 * _mirror * side * _stance
		_ease(_hip[i], Vector3(-stoop + fore, 0.0, 0.10 * side * _stance), dt)
		_ease(_knee[i], Vector3(0.35 + maxf(-fore, 0.0), 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-stoop * 0.55 - pull * 0.45 * _amp,
			0.0, 0.10 * side), dt)
		_ease(_elbow[i], Vector3(-0.45 - pull * 0.30, 0.0, 0.0), dt)


## Arms up and working above the head — raises, bolting a ring, mounting panels.
## The one family that is unmistakable in silhouette at any distance.
func _pose_overhead(dt: float) -> void:
	var s := sin(_phase * 1.6 * _tempo)
	_place_body(HIP_Y + absf(s) * 0.035 * _amp, 0.0, dt)
	_settle(_torso, Vector3(_lean - 0.14, 0.0, 0.0), dt)
	_ease(_head, Vector3(-0.32, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		# Variant 0 works both arms together, variant 1 alternates.
		var beat := s if _variant == 0 else s * side * _mirror
		_ease(_hip[i], Vector3(0.0, 0.0, 0.07 * side * _stance), dt)
		_ease(_knee[i], Vector3(0.10, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-2.05 - beat * 0.28 * _amp, 0.0, 0.22 * side), dt)
		_ease(_elbow[i], Vector3(-0.45 + beat * 0.35, 0.0, 0.0), dt)


## Braced push with a recoil: drilling, cutting, anything you lean your weight
## into. Staggered, whole body committed forward, periodic kick back.
func _pose_drill(dt: float) -> void:
	var press := absf(sin(_phase * 2.6 * _tempo))
	var recoil := press * 0.12
	_place_body(HIP_Y - 0.06 - recoil * 0.4, 0.0, dt)
	_settle(_torso, Vector3(_lean + 0.42 - recoil, 0.0, 0.0), dt)
	_ease(_head, Vector3(-0.18, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		# One foot planted well back — the brace is the read.
		var back := 0.42 * _mirror * side * _stance
		_ease(_hip[i], Vector3(-0.30 + back, 0.0, 0.12 * side), dt)
		_ease(_knee[i], Vector3(0.45 - back * 0.5, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-0.95 - press * 0.20 * _amp, 0.0, 0.09 * side), dt)
		_ease(_elbow[i], Vector3(-0.85 + press * 0.30, 0.0, 0.0), dt)


## Upright at a bench with the forearms level: tending a machine, fine work.
## The calm one — its whole job is to NOT look like heavy labour.
func _pose_bench(dt: float) -> void:
	var fidget := sin(_phase * 3.1 * _tempo)
	_place_body(HIP_Y + sin(_phase * 0.5) * 0.012, 0.0, dt)
	_settle(_torso, Vector3(_lean + 0.16, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.26, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.0, 0.0, 0.05 * side * _stance), dt)
		_ease(_knee[i], Vector3(0.07, 0.0, 0.0), dt)
		# Forearms out flat in front; only the hands move, and only a little.
		_ease(_shoulder[i], Vector3(-0.75 - fidget * 0.06 * _amp, 0.0, 0.13 * side), dt)
		_ease(_elbow[i], Vector3(-1.35 + fidget * 0.14 * side * _mirror, 0.0, 0.0), dt)


## Standing and looking it over, one hand shading the brow. Honest for a
## checkpoint chore — three seconds of digging for a 3-minute inspection would
## read as busywork.
func _pose_inspect(dt: float) -> void:
	var scan := sin(_phase * 0.45 * _tempo)
	_place_body(HIP_Y, 0.0, dt)
	_settle(_torso, Vector3(_lean, scan * 0.20, 0.0), dt)
	_ease(_head, Vector3(-0.08, scan * 0.28, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.0, 0.0, 0.05 * side * _stance), dt)
		_ease(_knee[i], Vector3(0.05, 0.0, 0.0), dt)
		# One hand to the brow (the handedness side), the other resting.
		if side * _mirror > 0.0:
			_ease(_shoulder[i], Vector3(-1.55, 0.0, 0.30 * side), dt)
			_ease(_elbow[i], Vector3(-1.90, 0.0, 0.0), dt)
		else:
			_ease(_shoulder[i], Vector3(-0.05, 0.0, 0.16 * side), dt)
			_ease(_elbow[i], Vector3(-0.28, 0.0, 0.0), dt)


## Squaring up to start. Half a beat — the _ease system already blends, so the
## point is a distinguishable intermediate TARGET, not covering a cut.
func _pose_work_enter(dt: float) -> void:
	_place_body(HIP_Y - 0.05, 0.0, dt)
	_settle(_torso, Vector3(_lean + 0.20, 0.0, 0.0), dt)
	_ease(_head, Vector3(-0.10, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(-0.12, 0.0, 0.14 * side * _stance), dt)
		_ease(_knee[i], Vector3(0.22, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-0.42, 0.0, 0.14 * side), dt)
		_ease(_elbow[i], Vector3(-0.50, 0.0, 0.0), dt)


## Straighten up and step back. The one that pays: without it a worker snaps
## out of a deep stoop straight into a stride, which is the most visible
## artefact in the whole set.
func _pose_work_exit(dt: float) -> void:
	_place_body(HIP_Y + 0.02, 0.0, dt)
	_settle(_torso, Vector3(_lean - 0.10, 0.0, 0.0), dt)
	_ease(_head, Vector3(-0.14, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.05, 0.0, 0.06 * side), dt)
		_ease(_knee[i], Vector3(0.02, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(0.10, 0.0, 0.20 * side), dt)
		_ease(_elbow[i], Vector3(-0.15, 0.0, 0.0), dt)


## Dancing has to look like JOY, not labour — the old version bobbed in a
## half-squat with both arms in one plane, which at 60 m read as another work
## family. Three fixes: the body BOUNCES off the beat and leans back a touch
## (work leans forward, that lean is most of the difference), the hips swing
## wide, and the arms live ABOVE the shoulders with the elbows opening and
## closing so the silhouette keeps changing. Two per-agent variants: raise-the-
## roof pumps vs a side-to-side wave, plus everyone turning slowly in place.
func _pose_dance(dt: float) -> void:
	if _flavor == "sway":
		_pose_sway(dt)
		return
	# "rave" (the bass stage, a set on): the same dance thrown harder and
	# faster — bigger hop, wider arms, quicker beat. What separates the
	# front of the stage from a fire circle at any distance.
	var hype := (1.5 if _flavor == "rave" else 1.0) * _beat_hype()
	var beat := _phase * 1.15 * _tempo * (1.3 if _flavor == "rave" else 1.0)
	var on_beat := _beat_rad()
	if not is_nan(on_beat):
		beat = on_beat
	var hands := _beat_hands_up()
	var sway := sin(beat)                    # side-to-side, the groove
	var pump := sin(beat * 2.0)              # double-time, the bounce
	var turn := sin(beat * 0.23) * 0.85      # slow drift around, ±~50°
	var hop := maxf(pump, 0.0) * hype
	_place_body(HIP_Y + hop * 0.10 * _amp, 0.0, dt)
	# Lean BACK, roll with the sway, and keep turning — three axes moving at
	# once is what separates a dancer from a worker at any distance.
	_settle(_torso, Vector3(-0.12 + pump * 0.06, turn + sway * 0.30, sway * 0.16), dt)
	_ease(_head, Vector3(-0.10 + pump * 0.16, sway * 0.30, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var up := pump * side * _mirror
		# Hips swing wide and the free leg kicks on the beat.
		_ease(_hip[i], Vector3(sway * 0.22 * side - hop * 0.18, 0.0, 0.10 * side), dt)
		_ease(_knee[i], Vector3(0.15 + maxf(up, 0.0) * 0.55 * _amp, 0.0, 0.0), dt)
		if _variant == 0:
			# Raise the roof: both hands high, elbows pumping with the beat.
			_ease(_shoulder[i], Vector3(-2.35 - pump * 0.25 * _amp, 0.0,
				(-0.35 - hop * 0.15) * side), dt)
			_ease(_elbow[i], Vector3(-0.85 + pump * 0.65 * _amp, 0.0, 0.0), dt)
		else:
			# The wave: arms out wide, rolling opposite each other.
			_ease(_shoulder[i], Vector3(-1.65 - up * 0.55, 0.0,
				(-0.85 + sway * side * 0.35) * side), dt)
			_ease(_elbow[i], Vector3(-0.55 + up * 0.50 * _amp, 0.0, 0.0), dt)
	_hands_up_over(hands, dt)


## Through the run-up to a drop: both arms straight up, a small wave on top.
func _hands_up_over(hands: float, dt: float) -> void:
	if hands <= 0.0:
		return
	var wave := sin(_beat_rad() * 2.0) * 0.06 if not _beat.is_empty() else 0.0
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_shoulder[i], _shoulder[i].rotation.lerp(Vector3(-3.0 + wave, 0.0, -0.16 * side), hands), dt, 16.0)
		_ease(_elbow[i], _elbow[i].rotation.lerp(Vector3(-0.12, 0.0, 0.0), hands), dt, 16.0)


## Dancing LIGHTLY (a fire with a stage's music drifting over): weight
## rolling from foot to foot, a soft knee bounce, hands loose at the hips or
## a drink held at the chest, the head nodding along — on the spot. Nothing
## goes above the shoulders, which is what keeps it from reading as the
## dance at any distance.
func _pose_sway(dt: float) -> void:
	var beat := _phase * 0.85 * _tempo
	var on_beat := _beat_rad()
	if not is_nan(on_beat):
		beat = on_beat
	var sway := sin(beat)
	var bob := sin(beat * 2.0)
	_place_body(HIP_Y - 0.02 - absf(bob) * 0.025 * _amp * _beat_hype(), 0.0, dt)
	_settle(_torso, Vector3(-0.04, sin(beat * 0.31) * 0.30 + sway * 0.12, sway * 0.09), dt)
	_ease(_head, Vector3(0.06 + bob * 0.09, sway * 0.18, -sway * 0.06), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var load := maxf(sway * side, 0.0)
		_ease(_hip[i], Vector3(-0.05 + load * 0.08, 0.0, 0.05 * side), dt)
		_ease(_knee[i], Vector3(0.12 + (1.0 - load) * 0.22 * _amp, 0.0, 0.0), dt)
		if _variant == 0 or i == 1:
			# Loose arms, elbows bent, swinging a little with the hips.
			_ease(_shoulder[i], Vector3(-0.35 - bob * 0.10, 0.0, (-0.18 - sway * side * 0.10) * side), dt)
			_ease(_elbow[i], Vector3(-1.05 + bob * 0.18 * _amp, 0.0, 0.0), dt)
		else:
			# One hand up at the chest (a cup, a beat being counted).
			_ease(_shoulder[i], Vector3(-0.95 + bob * 0.08, 0.0, -0.25 * side), dt)
			_ease(_elbow[i], Vector3(-1.75, 0.0, 0.0), dt)
	# The run-up to a drop reaches even the fire: arms half up (the crowd
	# shader's sway does the same).
	_hands_up_over(_beat_hands_up() * 0.6, dt)


## FUCK YES!!! — the peak samba. Unmistakable next to the rave at any
## distance: quick little steps (the only dance where the FEET work: a
## step-ball-change on alternating legs), hips rocking and the body TWISTING
## against them, elbows bent with the forearms rolling at chest height
## instead of punching overhead, a light bounce on the double-time, and the
## head up and back — joy, not effort.
func _pose_samba(dt: float) -> void:
	var beat := _phase * 1.55 * _tempo
	var on_beat := _beat_rad()
	if not is_nan(on_beat):
		beat = on_beat
	var step := sin(beat)                     # which foot is stepping
	var bounce := absf(sin(beat * 2.0))       # the double-time "and-a"
	var twist := sin(beat) * 0.45 * _amp
	_place_body(HIP_Y - bounce * 0.05 + 0.02, 0.0, dt)
	_settle(_torso, Vector3(-0.10 - bounce * 0.05, -twist, sin(beat + 0.6) * 0.22), dt)
	_ease(_head, Vector3(-0.22, twist * 0.5, -sin(beat + 0.6) * 0.12), dt, 16.0)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var mine := step * side * _mirror        # > 0: this foot is stepping
		# Step-ball-change: the stepping leg lifts and reaches, the other
		# stays under the body with a soft knee.
		_ease(_hip[i], Vector3(-maxf(mine, 0.0) * 0.38 + minf(mine, 0.0) * 0.10, 0.0,
			0.06 * side + mine * 0.08), dt, 18.0)
		_ease(_knee[i], Vector3(0.18 + maxf(mine, 0.0) * 0.55, 0.0, 0.0), dt, 18.0)
		# Arms: elbows bent ~100 deg, forearms rolling in front of the chest,
		# opposite to the hips.
		var roll := sin(beat + (0.0 if i == 0 else PI))
		_ease(_shoulder[i], Vector3(-0.95 - roll * 0.45, 0.0, (0.35 + roll * 0.18) * side), dt, 16.0)
		_ease(_elbow[i], Vector3(-1.55 + roll * 0.35, 0.0, 0.0), dt, 16.0)


## Cross-legged ON THE GROUND (meals, venues, a cold pit): hips down on the
## ground, thighs out and forward, shins folded in across each other, hands
## resting on the knees, the torso up and the head turning now and then.
func _pose_sit_cross(dt: float) -> void:
	var breathe := sin(_phase * 0.35) * 0.015
	var look := sin(_phase * 0.07 * _tempo + _lean * 9.0)
	_place_body(0.17 + breathe, 0.0, dt)
	_settle(_torso, Vector3(0.06 + _lean, look * 0.18, 0.0), dt)
	_ease(_head, Vector3(0.04 + breathe * 2.0, look * 0.4, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(-1.3, 0.25 * side, -0.85 * side), dt)
		_ease(_knee[i], Vector3(2.45, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-0.5, 0.0, -0.28 * side), dt)
		_ease(_elbow[i], Vector3(-0.75, 0.0, 0.0), dt)


## Sitting back on the ground: legs out (one knee up for some), propped on
## straight arms behind, the torso leaning back but the head UP and looking
## out — relaxed, never flat (lying at a venue read as dead).
func _pose_lounge(dt: float) -> void:
	var breathe := sin(_phase * 0.33) * 0.012
	var look := sin(_phase * 0.06 * _tempo + _lean * 7.0)
	_place_body(0.14 + breathe, 0.0, dt)
	_settle(_torso, Vector3(-0.5, look * 0.15, 0.0), dt)
	_ease(_head, Vector3(0.38, look * 0.45, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var knee_up := _variant == 1 and i == (0 if _mirror > 0.0 else 1)
		_ease(_hip[i], Vector3(-0.85 if knee_up else -1.52, 0.0, -0.12 * side), dt)
		_ease(_knee[i], Vector3(1.25 if knee_up else 0.08, 0.0, 0.0), dt)
		# Arms straight back to the ground behind the hips.
		_ease(_shoulder[i], Vector3(0.9, 0.0, -0.32 * side), dt)
		_ease(_elbow[i], Vector3(-0.05, 0.0, 0.0), dt)


## A SANDMAN at the burn's line: kneeling upright, hands on the thighs,
## watching the crowd (the head sweeps slowly along the line).
func _pose_kneel(dt: float) -> void:
	var breathe := sin(_phase * 0.33) * 0.012
	var watch := sin(_phase * 0.09 * _tempo + _lean * 11.0)
	_place_body(0.5 + breathe, 0.0, dt)
	_settle(_torso, Vector3(0.04, watch * 0.15, 0.0), dt)
	_ease(_head, Vector3(0.08, watch * 0.5, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.0, 0.0, -0.06 * side), dt)
		_ease(_knee[i], Vector3(1.55, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-0.32, 0.0, -0.12 * side), dt)
		_ease(_elbow[i], Vector3(-0.55, 0.0, 0.0), dt)


## A sandman turning someone back: standing close, the lead arm out toward
## the crowd in a slow guiding sweep, the other hand open, leaning in a little.
func _pose_redirect(dt: float) -> void:
	var sweep := sin(_phase * 0.6 * _tempo)
	_place_body(HIP_Y, 0.0, dt)
	_settle(_torso, Vector3(0.1, sweep * 0.12, 0.0), dt)
	_ease(_head, Vector3(0.05, sweep * 0.2, 0.0), dt)
	var lead := 0 if _mirror > 0.0 else 1
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.0, 0.0, 0.05 * side), dt)
		_ease(_knee[i], Vector3(0.06, 0.0, 0.0), dt)
		if i == lead:
			_ease(_shoulder[i], Vector3(-1.25 + sweep * 0.25, 0.0, (-0.75 - sweep * 0.2) * side), dt)
			_ease(_elbow[i], Vector3(-0.15, 0.0, 0.0), dt)
		else:
			_ease(_shoulder[i], Vector3(-0.45, 0.0, -0.35 * side), dt)
			_ease(_elbow[i], Vector3(-0.6, 0.0, 0.0), dt)


## FIRE FLOW: spinning poi — both arms swinging big circles out in front and
## to the sides, opposite in phase, the body turning slowly against them, a
## light step (the lane carries them round the effigy).
func _pose_fire_flow(dt: float) -> void:
	var beat := _phase * 1.4 * _tempo
	var step := sin(beat * 0.5)
	_place_body(HIP_Y - absf(sin(beat)) * 0.03, 0.0, dt)
	_settle(_torso, Vector3(0.02, sin(beat * 0.25) * 0.45, sin(beat * 0.5) * 0.06), dt)
	_ease(_head, Vector3(-0.05, sin(beat * 0.25) * 0.2, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var ph := beat * 2.0 + (0.0 if i == 0 else PI)
		_ease(_shoulder[i], Vector3(-1.4 + cos(ph) * 0.95, 0.0, -(0.55 + sin(ph) * 0.4) * side), dt, 16.0)
		_ease(_elbow[i], Vector3(-0.2, 0.0, 0.0), dt, 16.0)
		var mine := step * side
		_ease(_hip[i], Vector3(-maxf(mine, 0.0) * 0.22, 0.0, 0.06 * side), dt)
		_ease(_knee[i], Vector3(0.12 + maxf(mine, 0.0) * 0.3, 0.0, 0.0), dt)


## Standing, looking UP at the effigy (weight shifting as in idle).
func _pose_gaze(dt: float) -> void:
	_pose_idle(false, dt)
	var drift := sin(_phase * 0.05 * _tempo + _lean * 13.0)
	_settle(_torso, Vector3(-0.08, drift * 0.1, 0.0), dt)
	_ease(_head, Vector3(-0.55, drift * 0.25, 0.0), dt)


## Arms straight up and waving, a hop on the beat: the effigy coming down,
## a set's closer.
func _pose_cheer(dt: float) -> void:
	var beat := _phase * 1.3 * _tempo
	var hop := maxf(sin(beat * 2.0), 0.0)
	_place_body(HIP_Y + hop * 0.12 * _amp, 0.0, dt)
	_settle(_torso, Vector3(-0.14, 0.0, sin(beat) * 0.08), dt)
	_ease(_head, Vector3(-0.30, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_shoulder[i], Vector3(-2.95 + sin(beat * 1.7 + float(i) * 1.9) * 0.18, 0.0,
			(-0.22 + sin(beat * 1.7 + float(i)) * 0.15) * side), dt, 12.0)
		_ease(_elbow[i], Vector3(-0.15, 0.0, 0.0), dt)
		_ease(_hip[i], Vector3(-hop * 0.2, 0.0, 0.06 * side), dt)
		_ease(_knee[i], Vector3(0.1 + hop * 0.35, 0.0, 0.0), dt)


## At the decks: leaning in, hands forward at waist height working the
## mixer, a steady head-nod bounce, and every so often one arm thrown up.
func _pose_dj(dt: float) -> void:
	var beat := _phase * 1.05
	var nod := absf(sin(beat * 2.0))
	var lift := smoothstep(0.7, 0.95, sin(_phase * 0.11 + float(_variant) * 2.0))
	var both := 0.0
	var jump := 0.0
	if not _beat.is_empty():
		# On the music: the nod IS the beat. Through the run-up to a drop the
		# left arm goes up and HOLDS there (the crowd watches for it), the
		# last moment and the drop itself both arms, and the drop is a jump.
		beat = float(_beat.get("beat", 0.0)) * PI * 0.5
		nod = absf(sin(beat * 2.0))
		var ant := StageBeat.anticipation(_beat)
		var drop := float(_beat.get("drop_pulse", 0.0))
		lift = maxf(lift * (1.0 - smoothstep(0.0, 0.1, ant)), smoothstep(0.0, 0.12, ant))
		both = clampf(smoothstep(0.85, 1.0, ant) + drop * 1.5, 0.0, 1.0)
		jump = drop
	_place_body(HIP_Y - nod * 0.04 + jump * absf(sin(beat * 2.0)) * 0.22, 0.0, dt)
	_settle(_torso, Vector3(0.16 + nod * 0.04, sin(beat * 0.5) * 0.12, 0.0), dt)
	_ease(_head, Vector3(0.12 + nod * 0.22, 0.0, 0.0), dt, 14.0)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var reach := Vector3(-0.85 + sin(beat * 2.0 + float(i)) * 0.08, 0.0, 0.18 * side)
		if i == 0 and lift > 0.0:
			reach = reach.lerp(Vector3(-2.8, 0.0, -0.2), lift)
		var elbow := Vector3(-0.9 + (0.6 if i == 0 else 0.0) * lift, 0.0, 0.0)
		if both > 0.0:
			reach = reach.lerp(Vector3(-2.95, 0.0, -0.22 * side), both)
			elbow = elbow.lerp(Vector3(-0.1, 0.0, 0.0), both)
		_ease(_shoulder[i], reach, dt, 12.0 if both > 0.0 else 9.0)
		_ease(_elbow[i], elbow, dt)
		_ease(_hip[i], Vector3(0.0, 0.0, 0.08 * side), dt)
		_ease(_knee[i], Vector3(0.12 + nod * 0.12, 0.0, 0.0), dt)


func _pose_clap(dt: float) -> void:
	var c := absf(sin(_phase * 2.4))
	_place_body(HIP_Y, 0.0, dt)
	_settle(_torso, Vector3(0.04, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.0, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.0, 0.0, 0.05 * side), dt)
		_ease(_knee[i], Vector3(0.06, 0.0, 0.0), dt)
		# Hands meet in front: the closer the clap, the smaller the roll.
		_ease(_shoulder[i], Vector3(-1.15, 0.0, (0.10 + c * 0.26) * side), dt)
		_ease(_elbow[i], Vector3(-1.25, 0.0, 0.0), dt)


# --- helpers ----------------------------------------------------------------

## Critically-damped-ish approach. Every pose is expressed as a target rather
## than a jump, so switching activity reads as a movement instead of a cut —
## which is what keeps a figure with no blend system from looking snappy.
func _ease(n: Node3D, target: Vector3, dt: float, rate: float = 9.0) -> void:
	if n == null:
		return
	var k := minf(dt * rate, 1.0)
	n.rotation = n.rotation.lerp(target, k)


func _settle(n: Node3D, target: Vector3, dt: float) -> void:
	_ease(n, target, dt, 7.0)


func _place_body(y: float, pitch: float, dt: float) -> void:
	var k := minf(dt * 7.0, 1.0)
	# HIP_Y is the hip's vertical offset from the body origin while standing
	# (pitch 0). As the body pitches toward horizontal (lying down), that
	# offset rotates out of the vertical axis too, so it must scale by
	# cos(pitch) — otherwise `y` stops meaning "target body-origin height" at
	# any pitch other than 0. Without this, lying (pitch -PI/2, cos ~= 0)
	# unconditionally subtracted the full standing HIP_Y (0.86 m) and drove
	# the whole figure that far into the ground. Rotation is eased first so
	# the Y target tracks the CURRENT lean every frame, not just the final one.
	_body.rotation.x = lerp_angle(_body.rotation.x, pitch, k)
	_body.position.y = lerpf(_body.position.y, y - HIP_Y * cos(_body.rotation.x), k)


# --- construction -----------------------------------------------------------

func _build() -> void:
	if _body != null:
		return
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://core/population/npc_silhouette.gdshader")
	_mat.set_shader_parameter("rim_color", _tint)
	_mat.set_shader_parameter("pulse_seed", NpcHash.unit01(_seed_key, "pose"))

	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)

	_torso = Node3D.new()
	_torso.name = "Torso"
	if hi_detail:
		# The lean pivot sits where the torso used to; the torso hangs off it
		# at zero, so every pose's torso target is unchanged.
		_lean_pivot = Node3D.new()
		_lean_pivot.name = "Lean"
		_lean_pivot.position = Vector3(0.0, HIP_Y, 0.0)
		_body.add_child(_lean_pivot)
		_lean_pivot.add_child(_torso)
		# A waist: a narrower abdomen under a broader chest.
		_limb(_torso, TORSO_R * 0.86, 0.30, -HIP_OVERLAP)
		_limb(_torso, TORSO_R * 1.08, TORSO_H - 0.02, 0.24)
		# Shoulder girdle and pelvis read as a frame, not a stick.
		_limb_across(_torso, 0.068, Vector3(0.0, SHOULDER_Y - HIP_Y - 0.02, 0.0), SHOULDER_X * 2.0 + 0.04)
		_limb_across(_body, 0.088, Vector3(0.0, HIP_Y + 0.02, 0.0), HIP_X * 2.0 + 0.12)
	else:
		_torso.position = Vector3(0.0, HIP_Y, 0.0)
		_body.add_child(_torso)
		# Bottom edge overshoots the hip pivot (y=0 in torso-local space) by
		# HIP_OVERLAP so it overlaps the thigh capsules below.
		_limb(_torso, TORSO_R, TORSO_H, -HIP_OVERLAP)

	# The carried crate rides the torso where the clap-hold hands meet (+Z in
	# torso space — see _pose_carry's shoulder targets), under the same
	# silhouette material so it reads as part of the figure.
	_carry_box = MeshInstance3D.new()
	_carry_box.name = "CarryBox"
	var box := BoxMesh.new()
	box.size = Vector3(0.42, 0.32, 0.30)
	_carry_box.mesh = box
	_carry_box.position = Vector3(0.0, 0.32, 0.34)
	_carry_box.material_override = _mat
	_carry_box.visible = false
	_torso.add_child(_carry_box)

	_head = Node3D.new()
	_head.name = "Head"
	var head_at := Vector3(0.0, SHOULDER_Y - HIP_Y + 0.10, 0.0)
	if hi_detail:
		_neck = Node3D.new()
		_neck.name = "Neck"
		_neck.position = head_at
		_torso.add_child(_neck)
		_neck.add_child(_head)
		_limb(_neck, 0.048, 0.05, -0.09)
		_head_meshes.append(_neck.get_child(_neck.get_child_count() - 1) as MeshInstance3D)
	else:
		_head.position = head_at
		_torso.add_child(_head)
	var hm := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = HEAD_R
	sph.height = HEAD_R * 2.0
	if hi_detail:
		# A touch taller than wide, and a jaw: a head, not a ball.
		sph.height = HEAD_R * 2.2
		sph.radial_segments = 48
		sph.rings = 24
	hm.mesh = sph
	hm.position = Vector3(0.0, HEAD_R * 0.9, 0.0)
	hm.material_override = _mat
	_head.add_child(hm)
	_head_meshes.append(hm)
	if hi_detail:
		var jaw := MeshInstance3D.new()
		var js := SphereMesh.new()
		js.radius = HEAD_R * 0.72
		js.height = HEAD_R * 1.2
		jaw.mesh = js
		jaw.position = Vector3(0.0, HEAD_R * 0.35, HEAD_R * 0.32)
		jaw.material_override = _mat
		_head.add_child(jaw)
		_head_meshes.append(jaw)

	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		# Arm: shoulder -> upper arm -> elbow -> forearm.
		var sh := Node3D.new()
		sh.name = "Shoulder%d" % i
		sh.position = Vector3(SHOULDER_X * side, SHOULDER_Y - HIP_Y, 0.0)
		_torso.add_child(sh)
		# Top edge stays right at the shoulder pivot (floats relative to the
		# torso, unchanged); bottom edge overshoots the elbow by ELBOW_OVERLAP.
		_limb(sh, ARM_R, 0.0, -(UPPER_ARM + ELBOW_OVERLAP))
		var el := Node3D.new()
		el.name = "Elbow%d" % i
		el.position = Vector3(0.0, -UPPER_ARM, 0.0)
		sh.add_child(el)
		# Top edge overshoots the elbow pivot upward to meet the upper arm;
		# bottom edge (wrist) is unchanged.
		_limb(el, ARM_R * 0.92, ELBOW_OVERLAP, -FOREARM)
		# The wrist pivot: hands, held tools and the IK all hang off it.
		var wr := Node3D.new()
		wr.name = "Wrist%d" % i
		wr.position = Vector3(0.0, -FOREARM, 0.0)
		el.add_child(wr)
		var mount := Node3D.new()
		mount.name = "ToolMount"
		mount.position = PALM_OFFSET
		wr.add_child(mount)
		if hi_detail:
			# A hand: a flattened capsule past the wrist.
			var hand := MeshInstance3D.new()
			var hc := CapsuleMesh.new()
			hc.radius = 0.04
			hc.height = 0.15
			hand.mesh = hc
			hand.position = Vector3(0.0, -0.06, 0.0)
			hand.scale = Vector3(1.0, 1.0, 0.62)
			hand.material_override = _mat
			wr.add_child(hand)
		_shoulder.append(sh)
		_elbow.append(el)
		_wrist.append(wr)

		# Leg: hip -> thigh -> knee -> shin. Hips hang off the BODY, not the
		# torso, so a torso lean does not drag the legs with it.
		var hp := Node3D.new()
		hp.name = "Hip%d" % i
		hp.position = Vector3(HIP_X * side, HIP_Y, 0.0)
		_body.add_child(hp)
		# Top edge overshoots the hip pivot upward to meet the torso; bottom
		# edge overshoots the knee downward to meet the shin.
		_limb(hp, LEG_R, HIP_OVERLAP, -(THIGH + KNEE_OVERLAP))
		var kn := Node3D.new()
		kn.name = "Knee%d" % i
		kn.position = Vector3(0.0, -THIGH, 0.0)
		hp.add_child(kn)
		# Top edge overshoots the knee pivot upward to meet the thigh; bottom
		# edge (ankle) is unchanged.
		_limb(kn, LEG_R * 0.9, KNEE_OVERLAP, -SHIN)
		if hi_detail:
			# A foot pointing forward (+Z, the figure's front), on an ankle
			# pivot the driver keeps level with the ground.
			var ft := Node3D.new()
			ft.name = "Foot%d" % i
			ft.position = Vector3(0.0, -SHIN, 0.0)
			kn.add_child(ft)
			var fm := MeshInstance3D.new()
			var fc := CapsuleMesh.new()
			fc.radius = 0.045
			fc.height = 0.25
			fm.mesh = fc
			fm.rotation = Vector3(PI * 0.5, 0.0, 0.0)
			fm.position = Vector3(0.0, -0.03, 0.065)
			fm.material_override = _mat
			ft.add_child(fm)
			_feet.append(ft)
		_hip.append(hp)
		_knee.append(kn)
	_build_glow()


## Glow-stick bands (see glow_for): rings round the wrists, the neck and the
## head, under one tiny unshaded material that blooms at night.
func _build_glow() -> void:
	var g := glow_for(_seed_key)
	if not bool(g["carries"]):
		return
	if _glow_shader == null:
		_glow_shader = load("res://core/population/npc_glow.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = _glow_shader
	var col: Color = g["color"]
	if bool(g["wrists"]):
		for el in _elbow:
			_glow_ring(el, Vector3(0.0, -FOREARM * 0.86, 0.0), ARM_R * 0.92, mat, col)
	if bool(g["neck"]):
		_glow_ring(_torso, Vector3(0.0, SHOULDER_Y - HIP_Y + 0.04, 0.0), 0.075, mat, col)
	if bool(g["head"]):
		_glow_ring(_head, Vector3(0.0, HEAD_R * 1.25, 0.0), HEAD_R * 0.98, mat, col)


func _glow_ring(parent: Node3D, at: Vector3, r: float, mat: ShaderMaterial, col: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Glow"
	var t := TorusMesh.new()
	t.inner_radius = r
	t.outer_radius = r + 0.018
	t.rings = 12
	t.ring_segments = 4
	mi.mesh = t
	mi.position = at
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_instance_shader_parameter("glow_col", Vector3(col.r, col.g, col.b))
	parent.add_child(mi)


## A capsule lying ACROSS the body (along X), centred at `at` — a pelvis or a
## shoulder girdle on the hi-detail build.
func _limb_across(parent: Node3D, radius: float, at: Vector3, length: float) -> void:
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = maxf(length, radius * 2.05)
	mi.mesh = cap
	mi.rotation = Vector3(0.0, 0.0, PI * 0.5)
	mi.position = at
	mi.material_override = _mat
	parent.add_child(mi)


## `top_y`/`bottom_y` are the capsule's two end-cap centres in parent-local Y
## (top_y > bottom_y). Neither has to land on the parent's own origin (0) —
## that's how a limb overshoots its pivot to overlap its neighbour.
func _limb(parent: Node3D, radius: float, top_y: float, bottom_y: float) -> void:
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = radius
	var length := top_y - bottom_y
	cap.height = maxf(length, radius * 2.05)
	mi.mesh = cap
	mi.position = Vector3(0.0, (top_y + bottom_y) * 0.5, 0.0)
	mi.material_override = _mat
	parent.add_child(mi)
