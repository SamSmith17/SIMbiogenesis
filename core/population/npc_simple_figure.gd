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
## Carried-crate visual (Site Projects haul leg). Child of the TORSO on the
## same side the arms reach (the clap-hold direction), so box and hands stay
## coherent whatever the world yaw. Shown only while the pose machine plays
## the logical carry gait.
var _carry_box: MeshInstance3D = null
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


func setup(seed_key: String, tint: Color) -> void:
	_tint = tint
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


## `clip` is the pose machine's chosen clip; `rate` its playback rate (so the
## figure speeds up with the world clock); `dt` real seconds.
func pose(clip: String, rate: float, dt: float) -> void:
	if _body == null:
		return
	var r := clampf(rate, 0.0, 12.0)
	_phase += dt * TAU * STRIDE_HZ * maxf(r, 0.001)
	# Matched on the LOGICAL clip, before the file mapping collapses it onto
	# the plain walk/idle (which is only right for the rigged body).
	if _carry_box != null:
		_carry_box.visible = clip == NpcRig.CLIP_CARRY or clip == NpcRig.CLIP_CARRY_IDLE
	if clip == NpcRig.CLIP_CARRY:
		_pose_carry(dt)
		return
	if clip == NpcRig.CLIP_CARRY_IDLE:
		_pose_carry_idle(dt)
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


## Walking while hugging a load to the chest: walk legs with a shortened
## stride, arms locked in the forward hold (the clap shape without its
## oscillation) so they never swing through the carried box, torso leaned
## slightly back as a counterweight.
func _pose_carry(dt: float) -> void:
	var s := sin(_phase)
	_place_body(HIP_Y + absf(sin(_phase * 2.0)) * 0.016, 0.0, dt)
	_settle(_torso, Vector3(-0.07, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.10, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var swing := s * side * 0.48
		_ease(_hip[i], Vector3(swing, 0.0, 0.0), dt)
		var lift := maxf(-s * side, 0.0)
		_ease(_knee[i], Vector3(lift * 0.8, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-1.05, 0.0, 0.14 * side), dt)
		_ease(_elbow[i], Vector3(-1.15, 0.0, 0.0), dt)


## The brigade station hold: standing, load hugged to the chest, a light
## breathe — the walk-carry pose with the legs planted.
func _pose_carry_idle(dt: float) -> void:
	var breathe := sin(_phase * 0.5) * 0.015
	_place_body(HIP_Y + breathe, 0.0, dt)
	_settle(_torso, Vector3(-0.06, 0.0, 0.0), dt)
	_ease(_head, Vector3(0.08, 0.0, 0.0), dt)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_ease(_hip[i], Vector3(0.0, 0.0, 0.05 * side), dt)
		_ease(_knee[i], Vector3(0.08, 0.0, 0.0), dt)
		_ease(_shoulder[i], Vector3(-1.05, 0.0, 0.14 * side), dt)
		_ease(_elbow[i], Vector3(-1.15, 0.0, 0.0), dt)


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
