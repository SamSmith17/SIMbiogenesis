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
var _phase := 0.0


func setup(seed_key: String, tint: Color) -> void:
	_tint = tint
	# Desynchronise gaits so a crowd is not a chorus line, deterministically.
	_phase = fposmod(float(absi(hash(seed_key)) % 997) * 0.0063, TAU)
	_build()


## `clip` is the pose machine's chosen clip; `rate` its playback rate (so the
## figure speeds up with the world clock); `dt` real seconds.
func pose(clip: String, rate: float, dt: float) -> void:
	if _body == null:
		return
	var r := clampf(rate, 0.0, 12.0)
	_phase += dt * TAU * STRIDE_HZ * maxf(r, 0.001)
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


func set_tint(tint: Color) -> void:
	_tint = tint
	if _mat != null:
		_mat.set_shader_parameter("rim_color", tint)


# --- poses ------------------------------------------------------------------

## Contralateral gait: each arm swings opposite its leg. Knees bend on the
## recovery (leg swinging forward) and stay near-straight on the stance leg,
## which is the single cue that separates "walking" from "scissoring".
func _pose_walk(amp: float, dt: float) -> void:
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


func _pose_idle(sad: bool, dt: float) -> void:
	var breathe := sin(_phase * 0.35) * 0.02
	_place_body(HIP_Y + breathe, 0.0, dt)
	_settle(_torso, Vector3(0.12 if sad else 0.0, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.42 if sad else breathe * 2.0, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.0, 0.0, 0.04 * side), dt)
		_ease(_knee[i], Vector3(0.05, 0.0, 0.0), dt)
		# Dejected arms hang dead; relaxed arms keep a slight elbow break.
		_ease(_shoulder[i], Vector3(0.0, 0.0, (0.10 if sad else 0.16) * side), dt)
		_ease(_elbow[i], Vector3(-0.05 if sad else -0.22, 0.0, 0.0), dt)


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


func _pose_dance(dt: float) -> void:
	var sway := sin(_phase * 1.1)
	var pump := sin(_phase * 2.2)
	_place_body(HIP_Y + absf(pump) * 0.05, 0.0, dt)
	_settle(_torso, Vector3(0.0, sway * 0.22, sway * 0.10), dt)
	_ease(_head, Vector3(pump * 0.12, sway * 0.20, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var up := pump * side
		_ease(_hip[i], Vector3(sway * 0.16 * side, 0.0, 0.06 * side), dt)
		_ease(_knee[i], Vector3(0.20 + maxf(up, 0.0) * 0.30, 0.0, 0.0), dt)
		# Arms alternate overhead — the clearest read of "dancing" at this
		# level of detail.
		_ease(_shoulder[i], Vector3(-1.9 - up * 0.55, 0.0, 0.30 * side), dt)
		_ease(_elbow[i], Vector3(-0.55 + up * 0.30, 0.0, 0.0), dt)


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

	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)

	_torso = Node3D.new()
	_torso.name = "Torso"
	_torso.position = Vector3(0.0, HIP_Y, 0.0)
	_body.add_child(_torso)
	# Bottom edge overshoots the hip pivot (y=0 in torso-local space) by
	# HIP_OVERLAP so it overlaps the thigh capsules below.
	_limb(_torso, TORSO_R, TORSO_H, -HIP_OVERLAP)

	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(0.0, SHOULDER_Y - HIP_Y + 0.10, 0.0)
	_torso.add_child(_head)
	var hm := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = HEAD_R
	sph.height = HEAD_R * 2.0
	hm.mesh = sph
	hm.position = Vector3(0.0, HEAD_R * 0.9, 0.0)
	hm.material_override = _mat
	_head.add_child(hm)

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
		_shoulder.append(sh)
		_elbow.append(el)

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
		_hip.append(hp)
		_knee.append(kn)


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
