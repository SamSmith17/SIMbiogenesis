class_name NpcRig
extends RefCounted

## Loads the Mixamo NPC character + clip set once and hands out per-avatar
## figures. Everything the imported files get *wrong* for this use case is
## corrected here, at load, so `NpcAvatar` stays simple:
##
## 1. **Every clip is named `mixamo_com`.** Mixamo names the take after itself,
##    so all seven files collide. Clips are renamed by role when merged into
##    one shared `AnimationLibrary`.
## 2. **Three clips carry root motion** (Walking's hips travel 1.69 m per
##    cycle — the "In Place" box was not ticked on export). Position is owned
##    by the sim, so horizontal hip translation is flattened at load; vertical
##    motion is kept, because for a squat that IS the animation.
## 3. **Nothing loops.** Mixamo exports `loop_mode = NONE`.
## 4. **There is no standing idle.** The character's bundled `Take 001` is a
##    static bind pose held for 9 s (measured: 0.0° of rotation across every
##    track). The player character's "Breathing Idle" is retargeted instead —
##    see `_retarget_idle` for why that is safe and how it verifies itself.
##
## The rig is optional: if the FBX files are absent every entry point degrades
## to `available() == false` and `NpcAvatar` keeps its primitive figure. The
## population sim never depends on art assets being present.

const DIR := "res://Imported Models/NPC/"
const CHARACTER_PATH := DIR + "Ch36_nonPBR.fbx"
## Retarget source — a different Mixamo export with `mixamorig_` bone naming.
const IDLE_SOURCE_PATH := "res://Player Character/Breathing Idle (no skin).fbx"

const CLIP_IDLE := "idle"
const CLIP_WALK := "walk"
const CLIP_SLEEP := "sleep"
const CLIP_WORK := "work"
const CLIP_SIT := "sit"
const CLIP_DANCE := "dance"
## PEAK EXPERIENCE: the dance someone breaks into at FUCK YES!!! — a samba,
## distinct at any distance from the stage's rave. The Mixamo export comes
## off a different rig (`mixamorig:` bones, not this pack's `mixamorig1:`), so
## it is RETARGETED like the idle (RETARGET_SOURCES). Without the file the
## pose machine falls back to the plain dance; the stick figure and the crowd
## shader draw their own samba either way.
const CLIP_PEAK_DANCE := "peak_dance"
## GROUND poses and the burn's roles — LOGICAL clips (no Mixamo file): the
## stick figure draws each one procedurally, the rigged body plays the nearest
## clip it has (NpcPoseMachine._clip_file_for), and mo-cap spice may take over.
##   sit_cross   cross-legged on the ground (meals, venues — the chair sit is
##               the portapotty's)
##   sit_lounge  legs out, propped back on straight arms, torso and head UP
##   kneel       a sandman at the burn's line
##   redirect    a sandman turning someone back (arm out toward the crowd)
##   fire_flow   a fire-flow performer spinning poi
##   gaze        standing, looking up at the effigy
const CLIP_SIT_CROSS := "sit_cross"
const CLIP_LOUNGE := "sit_lounge"
const CLIP_KNEEL := "kneel"
const CLIP_REDIRECT := "redirect"
const CLIP_FIREFLOW := "fire_flow"
const CLIP_GAZE := "gaze"
const LOGICAL_CLIPS: Array = [CLIP_SIT_CROSS, CLIP_LOUNGE, CLIP_KNEEL, CLIP_REDIRECT, CLIP_FIREFLOW, CLIP_GAZE]
## The ground poses (sat or knelt on the ground — the sit transitions apply).
const GROUND_CLIPS: Array = [CLIP_SIT_CROSS, CLIP_LOUNGE, CLIP_KNEEL]

## Locomotion ends. One-shots: a walk that starts and stops instead of snapping
## into a gait is most of what makes a figure look like it decided to go.
const CLIP_WALK_START := "walk_start"
const CLIP_WALK_STOP := "walk_stop"

## LOGICAL clip only — no Mixamo carry clip exists in the pack, so the pose
## machine emits this while an agent hauls a crate (Site Projects) and
## NpcPoseMachine._clip_file_for maps it onto the plain walk for the rigged
## body (the carried box is a separate attached mesh). The simple figure
## matches on the logical name and plays a real two-hand hold. Adding a real
## clip later means: SOURCES entry (mind the role measurement — a lift
## measures as descend/ascend and would get a wrong ground-offset curve
## without an exemption) + retiring the file-clip mapping.
const CLIP_CARRY := "carry"
## Standing hold — a bucket-brigade station worker with crates flowing
## through their hands. Logical only, same contract as CLIP_CARRY: the rig
## plays plain idle under the chest box, the simple figure poses the hold.
const CLIP_CARRY_IDLE := "carry_idle"

## Posture transitions, all one-shots.
##
## Sleep has a genuine matched PAIR — "Idle To Situp" measured as a descend
## (hips 0.940 -> 0.123) and "Sleep To Idle" as the ascend back. The filename
## suggested a sit-up exercise; the measurement says lie-down, which is why
## roles are classified and not read off the filename.
##
## Sitting has only the ascend ("Sit To Stand"), so sitting DOWN is that clip
## played backwards. Safe here because the FBX import bakes dense linear keys
## (animation/fps=30, trimming on) with no ease curve to invert, and sitting is
## quasi-static -- no ballistic phase, no foot-plant that must land on a beat.
const CLIP_SLEEP_ENTER := "sleep_enter"
const CLIP_SLEEP_EXIT := "sleep_exit"
const CLIP_SIT_EXIT := "sit_exit"
## Not a file: CLIP_SIT_EXIT played backwards. Named so the pose machine and
## the avatar can talk about it, and so `_apply_clip` keys on (clip, backwards).
const CLIP_SIT_ENTER := "sit_enter"

## Mood. Swapped in below NpcMorale's "Over It" band so a community in trouble
## reads as such from across the map, before anyone actually quits.
const CLIP_IDLE_SAD := "idle_sad"
const CLIP_WALK_SAD := "walk_sad"

## Enrichment, resolved by which enrichment SPACE the agent went to.
const CLIP_EXERCISE := "exercise"      # movement / yoga block
const CLIP_CLAP := "clap"              # workshop / social
const CLIP_CLAP_SIT := "clap_sit"      # fire circle, seated

## Gait variants, picked per agent so a group walking together is not a chorus
## line. Measured at ~1.02 m/s against the primary walk's 1.64 m/s, so playback
## is rate-matched per clip rather than globally.
const CLIP_WALK_ALT := "walk_alt"
const CLIP_WALK_ALT2 := "walk_alt2"
const WALK_VARIANTS: Array = [CLIP_WALK, CLIP_WALK_ALT, CLIP_WALK_ALT2]

## file (under DIR) -> [clip name, should_loop]. The mapping from *activity* to
## clip lives in NpcAvatar; this is only "what is in the box".
## file -> [clip name, should_loop, expected role].
##
## The role is an ASSERTION, not documentation: the loader measures each clip
## and refuses to install one whose measured role disagrees, the same way
## `_retarget_idle` refuses a bad bind ratio. That is what catches a swapped
## Start/Stop export, which looks perfect by filename and walks backwards.
##
## Transitions must NOT loop, or `animation_finished` never fires and a
## lie-down repeats forever.
const SOURCES := {
	"Walking.fbx": [CLIP_WALK, true, ROLE_LOCOMOTION],
	"Walking (1).fbx": [CLIP_WALK_ALT, true, ROLE_LOCOMOTION],
	"Walking (2).fbx": [CLIP_WALK_ALT2, true, ROLE_LOCOMOTION],
	"Sad Walk.fbx": [CLIP_WALK_SAD, true, ROLE_LOCOMOTION],
	"Start Walking.fbx": [CLIP_WALK_START, false, ROLE_LOCO_START],
	"Stop Walking.fbx": [CLIP_WALK_STOP, false, ROLE_LOCO_STOP],
	"Laying Sleeping.fbx": [CLIP_SLEEP, true, ROLE_STATIC],
	"Idle To Situp.fbx": [CLIP_SLEEP_ENTER, false, ROLE_DESCEND],
	"Sleep To Idle.fbx": [CLIP_SLEEP_EXIT, false, ROLE_ASCEND],
	"Sitting Idle.fbx": [CLIP_SIT, true, ROLE_STATIC],
	"Sit To Stand.fbx": [CLIP_SIT_EXIT, false, ROLE_ASCEND],
	"Sad Idle.fbx": [CLIP_IDLE_SAD, true, ROLE_STATIC],
	"Overhead Squat.fbx": [CLIP_WORK, true, ROLE_CYCLIC],
	"Back Squat.fbx": [CLIP_EXERCISE, true, ROLE_CYCLIC],
	"Standing Clap.fbx": [CLIP_CLAP, true, ROLE_CYCLIC],
	"Sitting Clap.fbx": [CLIP_CLAP_SIT, true, ROLE_STATIC],
	"Arms Hip Hop Dance.fbx": [CLIP_DANCE, true, ROLE_CYCLIC],
	# --- carry: NOT YET SOURCED ------------------------------------------
	# Nothing in the shipped pack can serve — every file is bound above, and
	# the only spare (Male Sitting Pose.fbx) is a static seated pose. Until a
	# Mixamo lift/carry export lands, NpcPoseMachine._clip_file_for maps the
	# logical carry clips onto walk/idle under the avatar's chest box, which
	# reads acceptably at silhouette distance.
	#
	# To enable: download the FBX to Imported Models/NPC/, uncomment, and add
	# it to the ASSETS.md table. The 4th column FORCES the role — see
	# ROLE_CARRY for why measuring a lift is actively harmful.
	# "Walking With Box.fbx": [CLIP_CARRY, true, "", ROLE_CARRY],
	# "Idle With Box.fbx": [CLIP_CARRY_IDLE, true, "", ROLE_CARRY],
}

## Clips from OTHER Mixamo rigs (`mixamorig_` bone prefix after import):
## file (under DIR) -> [clip name, loops]. Retargeted by prefix, bind-ratio
## checked, hip track rescaled to this pack's standing height, horizontal
## root motion flattened (`_retarget_extra`).
const RETARGET_SOURCES := {
	"Samba Dancing.fbx": [CLIP_PEAK_DANCE, true],
}

## MO-CAP SPICE clips for the stick figure (NpcMocapSpice / NpcStickMocap):
## every FBX in MOCAP_DIR/<moment>/ is a candidate for that moment. File
## names are free — drop the closest
## clip you can find into the right folder and re-import. Clip names are
## "mc_<moment>__<file basename>". Any Mixamo rig
## (Y Bot "Without Skin" exports use `mixamorig:` bones) is retargeted onto
## this pack's skeleton by `_retarget_extra`.
const MOCAP_DIR := DIR + "mocap/"
## Base-pack clips that serve a moment until the folder has its own.
const MOMENT_DEFAULTS := {
	"peak": [CLIP_PEAK_DANCE],
	"dance": [CLIP_DANCE],
	"cheer": [CLIP_CLAP],
}
static var _moment_clips: Dictionary = {}   # moment -> Array[String]

## Mixamo's own take name, identical in every file.
const TAKE_NAME := "mixamo_com"

## Where the hips should sit above the ground for clips that are NOT standing
## on two feet, in metres.
##
## Mixamo authors each clip around its own origin rather than around the
## ground, and the results do not agree: "Laying Sleeping" puts the hips at
## 1.018 m — *higher* than the 0.87-0.95 m of a standing walk — so a figure
## playing it lies down in mid-air about a metre up. "Sitting Idle" sits at
## 0.539 m, which is chair height, and there is no chair.
##
## The correction is expressed as a TARGET rather than a fixed offset so it is
## derived from whatever the clip actually contains: re-export the clip, or
## swap in a different one, and the figure still meets the ground.
const TARGET_HIPS_Y := {
	CLIP_SLEEP: 0.16,  # lying down: hips are half a torso thickness off the floor
	CLIP_SIT: 0.26,    # seated on the ground, since nothing models furniture yet
}
## Fraction of a retargeted clip's tracks that must resolve to real bones
## before the clip is trusted. Unbound tracks are dropped silently by Godot,
## so a bad retarget looks like a T-pose rather than an error.
const MIN_RETARGET_BIND := 0.8

## Fallback facing when the walk clip cannot be measured (e.g. someone
## re-exports it with "In Place" ticked, leaving no travel to measure).
## Mixamo's own convention is +Z forward, which is what this pack measures.
const FALLBACK_MODEL_FORWARD := Vector2(0.0, 1.0)

static var _lib: AnimationLibrary = null
static var _character: PackedScene = null
static var _walk_cycle_m := 0.0
static var _walk_forward := Vector2.ZERO
static var _ground_offsets: Dictionary = {}   # clip -> metres to shift the figure
## Resting hip height of this pack's own standing clips, in metres. Used to
## rebase retargeted clips that came from a differently-scaled rig.
static var _native_stand_hips_y := 0.0
## clip -> metres of ground covered per cycle, for per-variant rate matching.
static var _clip_cycle_m: Dictionary = {}
## clip -> PackedFloat32Array of ground offsets sampled across the clip.
static var _offset_curves: Dictionary = {}
## clip -> measurement dictionary, for diagnostics and the selftest.
static var _measurements: Dictionary = {}
## clip -> seconds.
static var _clip_len: Dictionary = {}

## Hip height below which the low end of a transition is LYING rather than
## SEATED. Sits between the measured seated hip (0.539) and lying hip (0.123).
const LYING_HIP_MAX := 0.35
## Samples per offset curve. Cheap to store, and read by array index per frame.
const OFFSET_CURVE_SAMPLES := 24
## Fastest any clip may play. Beyond this the motion is indistinguishable, so
## the extra rate buys nothing and only costs sampling.
const MAX_PLAYBACK_RATE := 12.0
static var _loaded := false
static var _load_error := ""


## Vertical shift, in metres, that puts a clip's body on the ground. Zero for
## ordinary standing clips; negative for the lying and seated ones, whose
## authored origins float (see TARGET_HIPS_Y).
static func clip_ground_offset(clip: String) -> float:
	_ensure_loaded()
	return float(_ground_offsets.get(clip, 0.0))


## Yaw to apply to the imported figure so its visual front points down the
## avatar's local −Z (Godot's forward, and what NpcPopulationHost's
## `atan2(-dir.x, -dir.y)` yaw assumes).
##
## Measured rather than hardcoded: the direction the hips travel in the raw
## walk clip IS the model's forward, so a re-export with different axis
## conventions keeps working instead of silently walking backwards.
static func model_yaw_offset() -> float:
	_ensure_loaded()
	var f := _walk_forward
	if f.length() < 0.01:
		f = FALLBACK_MODEL_FORWARD
	return -atan2(-f.x, -f.y)


## Playback rate that makes the feet match the sim's ground speed. Without it
## the walk cycle runs at the clip's authored 1.64 m/s while the agent moves at
## NpcNav.WALK_SPEED_MPS, and the feet visibly skate.
static func walk_speed_scale(ground_speed_mps: float) -> float:
	_ensure_loaded()
	if _lib == null or not _lib.has_animation(CLIP_WALK):
		return 1.0
	var clip_len := _lib.get_animation(CLIP_WALK).length
	if clip_len <= 0.0 or _walk_cycle_m <= 0.01:
		return 1.0
	var clip_speed := _walk_cycle_m / clip_len
	return clampf(ground_speed_mps / clip_speed, 0.25, 4.0)


## Metres of ground covered by one full walk cycle, measured off the clip's
## hip translation BEFORE it is flattened. Used to match playback rate to the
## sim's walking speed — the difference between feet that grip and feet that
## skate.
static func walk_cycle_distance_m() -> float:
	_ensure_loaded()
	return _walk_cycle_m


static func available() -> bool:
	_ensure_loaded()
	return _character != null and _lib != null


static func load_error() -> String:
	_ensure_loaded()
	return _load_error


static func clip_names() -> PackedStringArray:
	_ensure_loaded()
	if _lib == null:
		return PackedStringArray()
	var out := PackedStringArray()
	for n in _lib.get_animation_list():
		out.append(String(n))
	return out


## One rigged figure: Skeleton3D + skinned mesh + an AnimationPlayer already
## holding the shared clip library. Returns null when assets are unavailable.
## The caller owns the node.
static func build_figure() -> Node3D:
	_ensure_loaded()
	if _character == null or _lib == null:
		return null
	var root := _character.instantiate()
	if root == null:
		return null
	var ap := _find_node(root, "AnimationPlayer") as AnimationPlayer
	if ap == null:
		ap = AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		root.add_child(ap)
	else:
		# Drop the bundled bind-pose takes so the only clips present are ours.
		for lib_name in ap.get_animation_library_list():
			ap.remove_animation_library(lib_name)
	ap.add_animation_library("", _lib)
	# The skeleton is per-figure (each agent poses independently); the mesh and
	# the clips are shared resources, so 50 avatars cost 50 skeletons, not 50
	# copies of a 16k-vertex mesh.
	return root as Node3D


static func find_skeleton(root: Node) -> Skeleton3D:
	return _find_typed(root, "Skeleton3D") as Skeleton3D


static func find_mesh(root: Node) -> MeshInstance3D:
	return _find_typed(root, "MeshInstance3D") as MeshInstance3D


static func find_anim_player(root: Node) -> AnimationPlayer:
	return _find_typed(root, "AnimationPlayer") as AnimationPlayer


# --- loading -----------------------------------------------------------------

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not ResourceLoader.exists(CHARACTER_PATH):
		_load_error = "character not found: %s" % CHARACTER_PATH
		return
	_character = load(CHARACTER_PATH) as PackedScene
	if _character == null:
		_load_error = "character failed to load"
		return

	var probe := _character.instantiate()
	var skel := find_skeleton(probe)
	var bones := _bone_names(skel)
	probe.free()
	if bones.is_empty():
		_load_error = "character has no skeleton"
		_character = null
		return

	_lib = AnimationLibrary.new()
	var _pending_curves: Dictionary = {}
	for file in SOURCES.keys():
		var spec: Array = SOURCES[file]
		var anim := _extract(DIR + String(file))
		if anim == null:
			push_warning("NpcRig: missing clip source %s" % file)
			continue
		var clip_name := String(spec[0])
		# Measure BEFORE flattening: horizontal travel is the whole signal for
		# the locomotion roles, and flattening destroys it.
		var m := measure(anim)
		var measured_role := classify(m)
		# 4th column FORCES a role classify() cannot produce (see ROLE_CARRY).
		# The measurement is kept either way: discarding it would give up the
		# swapped-export protection this whole column exists for.
		var forced_role := String(spec[3]) if spec.size() > 3 else ""
		m["measured_role"] = measured_role
		if forced_role.is_empty():
			var expected_role := String(spec[2]) if spec.size() > 2 else ""
			if not expected_role.is_empty() and measured_role != expected_role:
				push_warning("NpcRig: %s measured as '%s' but SOURCES expects '%s' — skipped"
					% [file, measured_role, expected_role])
				continue
			m["role"] = measured_role
		else:
			m["role"] = forced_role
		_measurements[clip_name] = m
		_clip_len[clip_name] = anim.length
		_clip_cycle_m[clip_name] = float(m["hip_xz_travel_m"])
		if clip_name == CLIP_WALK:
			_walk_cycle_m = _hip_travel_xz(anim)
			_walk_forward = _hip_travel_dir_xz(anim)
			_native_stand_hips_y = _hip_rest_y(anim)
		_flatten_root_motion(anim)
		if TARGET_HIPS_Y.has(clip_name):
			_ground_offsets[clip_name] = \
				float(TARGET_HIPS_Y[clip_name]) - _hip_rest_y(anim)
		if bool(spec[1]):
			anim.loop_mode = Animation.LOOP_LINEAR
		else:
			anim.loop_mode = Animation.LOOP_NONE
		_lib.add_animation(clip_name, anim)
		_pending_curves[clip_name] = anim

	# Offset curves need the standing hip height, which is measured from the
	# walk clip inside the loop above, so they are built in a second pass.
	for clip_name in _pending_curves:
		_offset_curves[clip_name] = _build_offset_curve(
			_pending_curves[clip_name] as Animation, String(clip_name))
	_pending_curves.clear()

	for file in RETARGET_SOURCES.keys():
		var rspec: Array = RETARGET_SOURCES[file]
		var ranim := _retarget_extra(DIR + String(file), bones)
		if ranim == null:
			continue
		var rname := String(rspec[0])
		ranim.loop_mode = Animation.LOOP_LINEAR if bool(rspec[1]) else Animation.LOOP_NONE
		_measurements[rname] = {"role": ROLE_CYCLIC, "measured_role": ROLE_CYCLIC, "retargeted": true}
		_clip_len[rname] = ranim.length
		_clip_cycle_m[rname] = 0.0
		_lib.add_animation(rname, ranim)

	_load_moment_clips(bones)

	var idle := _retarget_idle(bones)
	if idle != null:
		_lib.add_animation(CLIP_IDLE, idle)
	elif _lib.has_animation(CLIP_SIT):
		# Better a wrong-but-alive pose than a rigid T-pose; recorded so the
		# selftest can tell a real idle from this fallback.
		_load_error = "no standing idle; falling back to seated"
		_lib.add_animation(CLIP_IDLE, _lib.get_animation(CLIP_SIT).duplicate(true))



# --- clip measurement + role classification ---------------------------------
#
# Filenames are a claim, not evidence. Everything else about these assets is
# already derived from the files themselves (facing from hip travel, ground
# offsets from hip height, walk rate from cycle length), and roles are treated
# the same way: measured, then checked against what SOURCES expected.
#
# This catches the failure a filename map never can — a swapped Start/Stop
# export looks perfect by name and walks backwards in game.

const ROLE_LOCOMOTION := "locomotion"
const ROLE_LOCO_START := "loco_start"
const ROLE_LOCO_STOP := "loco_stop"
const ROLE_DESCEND := "descend"     # standing -> seated/lying
const ROLE_ASCEND := "ascend"       # seated/lying -> standing
const ROLE_CYCLIC := "cyclic"       # a repeating in-place motion
const ROLE_STATIC := "static"       # a held pose
const ROLE_UNKNOWN := "unknown"
## Hauling a load. FORCED via the SOURCES 4th column, never returned by
## classify() — carrying is an ARMS pose and measure() reads the hips, so a
## role the classifier can never produce must never be used as an assertion.
##
## Its real job is `role_needs_offset_curve`: a lift clip dips to grab the
## crate, which measures as DESCEND, and the offset-curve builder would then
## land the bottom of the lift at SEATED/LYING hip height — sinking the figure
## ~0.7 m into the ground mid-pickup. Being neither DESCEND nor ASCEND takes
## the constant-fill path instead, which is correct for a clip that starts and
## ends standing.
const ROLE_CARRY := "carry"

## Vertical movement below this reads as noise rather than a real rise or fall.
const Y_NOISE_M := 0.03
## Hip travel above this means the clip actually goes somewhere.
const XZ_LOCOMOTION_M := 0.5
const XZ_TRANSITION_M := 0.2
## End-to-end hip height change that distinguishes a transition from a loop.
const Y_LEVEL_CHANGE_M := 0.25
## Total end-to-start rotation across the skeleton, in radians, above which the
## clip finishes in a materially different pose than it started.
const POSE_DELTA_LARGE := 3.0


## Everything worth knowing about one clip, in one pass over its tracks.
## Call BEFORE _flatten_root_motion — horizontal travel is the whole signal for
## locomotion roles and flattening destroys it.
static func measure(anim: Animation) -> Dictionary:
	var t := _hip_position_track(anim)
	var out := {
		"len_s": anim.length,
		"hip_xz_travel_m": 0.0,
		"hip_y_start": 0.0, "hip_y_end": 0.0,
		"hip_y_min": 0.0, "hip_y_max": 0.0, "hip_y_swing": 0.0,
		"y_cycles": 0,
		"pose_delta": _pose_delta(anim),
		"speed_first_third": 0.0, "speed_last_third": 0.0,
	}
	if t < 0:
		return out
	var n := anim.track_get_key_count(t)
	if n < 2:
		return out
	var first: Vector3 = anim.track_get_key_value(t, 0)
	var last: Vector3 = anim.track_get_key_value(t, n - 1)
	out["hip_xz_travel_m"] = Vector2(last.x - first.x, last.z - first.z).length()
	out["hip_y_start"] = first.y
	out["hip_y_end"] = last.y

	var lo := INF
	var hi := -INF
	for k in range(n):
		var v: Vector3 = anim.track_get_key_value(t, k)
		lo = minf(lo, v.y)
		hi = maxf(hi, v.y)
	out["hip_y_min"] = lo
	out["hip_y_max"] = hi
	out["hip_y_swing"] = hi - lo

	# Count direction reversals in hip height. A walk bobs twice per cycle; a
	# transition rises or falls once. Only reversals that clear the noise floor
	# count, or float jitter would read as a gallop.
	var cycles := 0
	var dir := 0
	var anchor := first.y
	for k in range(1, n):
		var y: float = (anim.track_get_key_value(t, k) as Vector3).y
		var d := y - anchor
		if absf(d) < Y_NOISE_M:
			continue
		var nd := 1 if d > 0.0 else -1
		if dir != 0 and nd != dir:
			cycles += 1
		dir = nd
		anchor = y
	out["y_cycles"] = cycles

	# Horizontal speed early vs late. This is what tells a start from a stop:
	# both travel and both change pose, but one accelerates and one decelerates.
	out["speed_first_third"] = _xz_speed_over(anim, t, 0.0, 1.0 / 3.0)
	out["speed_last_third"] = _xz_speed_over(anim, t, 2.0 / 3.0, 1.0)
	return out


static func _xz_speed_over(anim: Animation, t: int, u0: float, u1: float) -> float:
	var n := anim.track_get_key_count(t)
	if n < 2 or anim.length <= 0.0:
		return 0.0
	var i0 := clampi(int(floor(float(n - 1) * u0)), 0, n - 1)
	var i1 := clampi(int(floor(float(n - 1) * u1)), 0, n - 1)
	if i1 <= i0:
		return 0.0
	var a: Vector3 = anim.track_get_key_value(t, i0)
	var b: Vector3 = anim.track_get_key_value(t, i1)
	var span := anim.length * (u1 - u0)
	if span <= 0.0:
		return 0.0
	return Vector2(b.x - a.x, b.z - a.z).length() / span


## Total rotation between the clip's first and last pose, summed over every
## rotation track. Small = it ends where it started (a loop); large = it ends
## somewhere else (a transition).
static func _pose_delta(anim: Animation) -> float:
	var total := 0.0
	for t in range(anim.get_track_count()):
		if anim.track_get_type(t) != Animation.TYPE_ROTATION_3D:
			continue
		var n := anim.track_get_key_count(t)
		if n < 2:
			continue
		var a: Quaternion = anim.track_get_key_value(t, 0)
		var b: Quaternion = anim.track_get_key_value(t, n - 1)
		total += absf(a.angle_to(b))
	return total


## Role from measurements alone. Pure and side-effect free so the selftest can
## drive it with synthetic dictionaries and no assets installed.
static func classify(m: Dictionary) -> String:
	var xz := float(m.get("hip_xz_travel_m", 0.0))
	var pose := float(m.get("pose_delta", 0.0))
	var cycles := int(m.get("y_cycles", 0))
	var swing := float(m.get("hip_y_swing", 0.0))
	var dy := float(m.get("hip_y_end", 0.0)) - float(m.get("hip_y_start", 0.0))
	var s0 := float(m.get("speed_first_third", 0.0))
	var s1 := float(m.get("speed_last_third", 0.0))

	# Level changes first: a lie-down that happens to drift is still a lie-down.
	if dy < -Y_LEVEL_CHANGE_M:
		return ROLE_DESCEND
	if dy > Y_LEVEL_CHANGE_M:
		return ROLE_ASCEND
	# Travel plus an unchanged end pose is a locomotion loop. Deliberately NOT
	# gated on hip bob: "Sad Walk" trudges with only 3.8 cm of rise, which is
	# under the noise floor, and it is still unmistakably a walk.
	if xz > XZ_LOCOMOTION_M and pose < POSE_DELTA_LARGE:
		return ROLE_LOCOMOTION
	if xz > XZ_TRANSITION_M and pose >= POSE_DELTA_LARGE:
		if s1 > s0 * 1.5:
			return ROLE_LOCO_START
		if s0 > s1 * 1.5:
			return ROLE_LOCO_STOP
		return ROLE_LOCOMOTION
	# Returns to its starting pose having moved: a repeatable in-place motion.
	# ONE reversal is enough — a squat and a clap are a single down-and-up, not
	# a gait, and requiring two classified both as unknown.
	if pose < POSE_DELTA_LARGE and (cycles >= 1 or swing >= Y_NOISE_M):
		return ROLE_CYCLIC
	if xz < 0.1:
		return ROLE_STATIC
	return ROLE_UNKNOWN


## Measure a clip straight from its FBX, without installing it. Used by the
## diagnostic and by the selftest's asset-gated role checks.
static func measure_file(file_name: String) -> Dictionary:
	var anim := _extract(DIR + file_name)
	if anim == null:
		return {}
	var m := measure(anim)
	m["role"] = classify(m)
	return m


## Does this role's clip change LEVEL, and therefore need a sampled ground
## offset rather than one constant?
##
## Extracted so the rule is pinnable offline with no assets installed. It is
## the single guard standing between a future lift/carry clip and a figure
## that sinks ~0.7 m into the ground mid-pickup: a lift dips to grab the
## crate, measures DESCEND, and the curve below would then land the bottom of
## that dip at seated or lying hip height. ROLE_CARRY is forced precisely so
## it lands here as false.
static func role_needs_offset_curve(role: String) -> bool:
	return role == ROLE_DESCEND or role == ROLE_ASCEND


## Ground offset sampled across a clip, rather than one number for the whole
## thing.
##
## A constant is right for a held pose and wrong twice for a transition: a
## stand-to-lie clip needs ~0 at the standing end and ~-0.86 m at the lying
## end, and `_hip_rest_y` (a minimum) only ever describes the lying one.
##
## The curve is parameterised on the clip's OWN hip descent rather than on
## time, so the figure meets the ground exactly when the animation puts it
## there — and a re-export with different pacing stays correct for free.
static func _build_offset_curve(anim: Animation, clip_name: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var m: Dictionary = _measurements.get(clip_name, {})
	var role := String(m.get("role", ""))
	var settled := float(_ground_offsets.get(clip_name, 0.0))
	# Only genuine level changes get a curve. A squat swings the hips 0.55 m
	# without going anywhere; treating that as a transition would try to land
	# the bottom of the rep at seated height.
	if not role_needs_offset_curve(role):
		out.resize(OFFSET_CURVE_SAMPLES)
		out.fill(settled)
		return out
	var t := _hip_position_track(anim)
	var y_min := float(m.get("hip_y_min", 0.0))
	var y_max := float(m.get("hip_y_max", 0.0))
	var span := y_max - y_min
	if t < 0 or span < 0.01:
		out.resize(OFFSET_CURVE_SAMPLES)
		out.fill(settled)
		return out
	# Whichever pose sits at the LOW end: seated or lying, decided by height.
	var target_low: float = float(TARGET_HIPS_Y.get(CLIP_SLEEP, 0.16)) if y_min < LYING_HIP_MAX \
		else float(TARGET_HIPS_Y.get(CLIP_SIT, 0.26))
	var target_high := _native_stand_hips_y
	for i in range(OFFSET_CURVE_SAMPLES):
		var u := float(i) / float(OFFSET_CURVE_SAMPLES - 1)
		var y := _hip_y_at(anim, t, u)
		var frac := clampf((y - y_min) / span, 0.0, 1.0)
		out.append(lerpf(target_low, target_high, frac) - y)
	return out


static func _hip_y_at(anim: Animation, track: int, u: float) -> float:
	var n := anim.track_get_key_count(track)
	if n <= 0:
		return 0.0
	var i := clampi(int(round(u * float(n - 1))), 0, n - 1)
	return (anim.track_get_key_value(track, i) as Vector3).y


## Ground offset at normalized clip position `u`. `play_backwards` sweeps u
## from 1 to 0, so reversed playback reads the same curve with no special case.
static func clip_ground_offset_at(clip: String, u: float) -> float:
	_ensure_loaded()
	var curve: PackedFloat32Array = _offset_curves.get(clip, PackedFloat32Array())
	if curve.is_empty():
		return clip_ground_offset(clip)
	var i := clampi(int(round(clampf(u, 0.0, 1.0) * float(curve.size() - 1))),
		0, curve.size() - 1)
	return curve[i]


## clip -> {"len", "loops"} for every installed clip. Handed to NpcPoseMachine
## so the pose logic knows how long each transition takes without reaching into
## the rig — which is what lets the machine be driven with a synthetic catalog
## in tests that run with no art installed.
static func catalog() -> Dictionary:
	_ensure_loaded()
	var out: Dictionary = {}
	if _lib == null:
		return out
	for n in _lib.get_animation_list():
		var a := _lib.get_animation(n)
		out[String(n)] = {
			"len": a.length,
			"loops": a.loop_mode != Animation.LOOP_NONE,
		}
	return out


## Is this clip installed in the rig's library? (Cheap; per-frame safe.)
static func has_clip(clip: String) -> bool:
	_ensure_loaded()
	return _lib != null and _lib.has_animation(clip)


static func clip_length(clip: String) -> float:
	_ensure_loaded()
	return float(_clip_len.get(clip, 0.0))


static func clip_measurement(clip: String) -> Dictionary:
	_ensure_loaded()
	return _measurements.get(clip, {})


## Playback rate that matches a specific gait clip to the sim's ground speed.
## Per-clip because the variants were authored at ~1.02 m/s against the primary
## walk's 1.64 m/s — one global scale would make two of the three skate.
static func walk_speed_scale_for(clip: String, ground_speed_mps: float) -> float:
	_ensure_loaded()
	var len_s := float(_clip_len.get(clip, 0.0))
	var cycle_m := float(_clip_cycle_m.get(clip, 0.0))
	if len_s <= 0.0 or cycle_m <= 0.01:
		return 1.0
	# Ceiling is generous because this now tracks APPARENT speed: at 60x the
	# body crosses ground 60x faster, and a gait pinned near 1x is exactly the
	# skating the timelapse looked wrong for. Past ~12x it is a blur either way.
	return clampf(ground_speed_mps / (cycle_m / len_s), 0.25, MAX_PLAYBACK_RATE)


## Deterministic gait for one agent, so a group walking together is not a
## chorus line. Falls back to the primary walk when variants are absent.
static func walk_variant_for(agent_id: String) -> String:
	_ensure_loaded()
	var avail: Array = []
	for c in WALK_VARIANTS:
		if _lib != null and _lib.has_animation(String(c)):
			avail.append(String(c))
	if avail.is_empty():
		return CLIP_WALK
	return String(avail[NpcHash.pick(agent_id, "gait", avail.size())])

static func _extract(path: String, any_take: bool = false) -> Animation:
	_last_source_hips_y = 0.0
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var root := packed.instantiate()
	var ap := find_anim_player(root)
	var out: Animation = null
	var first: Animation = null
	if ap != null:
		for lib_name in ap.get_animation_library_list():
			var lib := ap.get_animation_library(lib_name)
			for a in lib.get_animation_list():
				if first == null and String(a) != "RESET":
					first = lib.get_animation(a)
				if String(a) == TAKE_NAME:
					# Duplicate: the imported Animation is a shared resource and
					# flattening it in place would mutate every other user.
					out = lib.get_animation(a).duplicate(true) as Animation
					break
			if out != null:
				break
	if out == null and any_take and first != null:
		# Not a Mixamo take name (another exporter): the file's first clip.
		out = first.duplicate(true) as Animation
	# The SOURCE rig's standing hip height (its rest pose), in the units its
	# hip track is keyed in — what _retarget_extra rescales by.
	var skel := find_skeleton(root)
	if skel != null:
		for i in skel.get_bone_count():
			if skel.get_bone_name(i).to_lower().ends_with("hips"):
				_last_source_hips_y = skel.get_bone_global_rest(i).origin.y
				break
	root.free()
	return out


## Hip height of the last `_extract`ed file's skeleton at rest (0 = unknown).
static var _last_source_hips_y := 0.0


## Horizontal distance the hips cover across the clip, before flattening.
static func _hip_travel_xz(anim: Animation) -> float:
	var t := _hip_position_track(anim)
	if t < 0 or anim.track_get_key_count(t) < 2:
		return 0.0
	var first: Vector3 = anim.track_get_key_value(t, 0)
	var last: Vector3 = anim.track_get_key_value(t, anim.track_get_key_count(t) - 1)
	return Vector2(last.x - first.x, last.z - first.z).length()


## The clip's settled hip height — the LOWEST keyed value, not the first.
## A squat starts standing and drops; a lying clip barely moves. Taking the
## minimum measures where the body actually comes to rest against the ground.
static func _hip_rest_y(anim: Animation) -> float:
	var t := _hip_position_track(anim)
	if t < 0 or anim.track_get_key_count(t) == 0:
		return 0.0
	var lo := INF
	for k in range(anim.track_get_key_count(t)):
		var v: Vector3 = anim.track_get_key_value(t, k)
		lo = minf(lo, v.y)
	return lo


## Normalized XZ direction the hips travel across the clip — the model's own
## forward axis.
static func _hip_travel_dir_xz(anim: Animation) -> Vector2:
	var t := _hip_position_track(anim)
	if t < 0 or anim.track_get_key_count(t) < 2:
		return Vector2.ZERO
	var first: Vector3 = anim.track_get_key_value(t, 0)
	var last: Vector3 = anim.track_get_key_value(t, anim.track_get_key_count(t) - 1)
	var d := Vector2(last.x - first.x, last.z - first.z)
	return Vector2.ZERO if d.length() < 0.01 else d.normalized()


## Pin the hips' horizontal position to its first key, converting a
## travelling clip into an in-place one. Vertical is untouched: it is the bob
## in a walk and the whole motion in a squat.
static func _flatten_root_motion(anim: Animation) -> void:
	var t := _hip_position_track(anim)
	if t < 0:
		return
	var n := anim.track_get_key_count(t)
	if n <= 0:
		return
	var base: Vector3 = anim.track_get_key_value(t, 0)
	for k in range(n):
		var v: Vector3 = anim.track_get_key_value(t, k)
		anim.track_set_key_value(t, k, Vector3(base.x, v.y, base.z))


static func _hip_position_track(anim: Animation) -> int:
	for t in range(anim.get_track_count()):
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		if String(anim.track_get_path(t)).to_lower().ends_with("hips"):
			return t
	return -1


## The NPC pack shipped without a standing idle, so the player character's
## "Breathing Idle" is reused. Both are Mixamo skeletons with identical
## hierarchy and differ only in bone PREFIX (`mixamorig_` vs `mixamorig1_`) and
## in two extra leaf bones on the player rig, so rewriting the prefix binds the
## clip correctly and the two surplus tracks simply find no bone.
##
## Godot drops unbound tracks silently — a failed retarget would show up as a
## figure standing in bind pose, not as an error — so the bind ratio is checked
## explicitly and the clip is rejected rather than trusted.
static func _retarget_idle(bones: Dictionary) -> Animation:
	var anim := _extract(IDLE_SOURCE_PATH)
	if anim == null:
		return null
	var bound := 0
	var total := 0
	for t in range(anim.get_track_count()):
		var path := String(anim.track_get_path(t))
		if not path.contains("mixamorig_"):
			continue
		path = path.replace("mixamorig_", "mixamorig1_")
		anim.track_set_path(t, NodePath(path))
		total += 1
		var colon := path.rfind(":")
		if colon >= 0 and bones.has(path.substr(colon + 1)):
			bound += 1
	if total == 0 or float(bound) / float(total) < MIN_RETARGET_BIND:
		push_warning("NpcRig: idle retarget bound only %d/%d tracks — rejected"
			% [bound, total])
		return null
	_flatten_root_motion(anim)
	# Bone ROTATIONS are scale-free and retarget cleanly, but the hips carry the
	# one POSITION track — in the source rig's units. The player character is
	# authored at a different scale (its hips sit at 2.04 m against this pack's
	# 0.87 m), so an uncorrected retarget leaves the figure hovering over a
	# metre off the ground. Rebase the track onto the native standing height,
	# preserving the clip's own small motion (a breathing idle moves ~1 cm).
	_rebase_hip_height(anim, _native_stand_hips_y)
	anim.loop_mode = Animation.LOOP_LINEAR
	return anim


## A clip from another Mixamo rig: rewrite the `mixamorig_` prefix onto this
## pack's `mixamorig1_`, refuse it if too few tracks bind (Godot drops
## unbound tracks silently — a bad retarget is a T-pose, not an error), then
## put its hips on this pack's scale: the source rig's hip track is in ITS
## units, so the whole track is scaled by native standing height / the clip's
## first-frame hip height (a dance starts standing), which keeps the clip's
## own bounce in proportion, and the horizontal travel is pinned in place.
static func _retarget_extra(path: String, bones: Dictionary) -> Animation:
	var anim := _extract(path, true)
	if anim == null:
		return null
	var source_hips := _last_source_hips_y
	var bound := 0
	var total := 0
	for t in range(anim.get_track_count()):
		var p := String(anim.track_get_path(t))
		if p.contains("mixamorig_"):
			p = p.replace("mixamorig_", "mixamorig1_")
			anim.track_set_path(t, NodePath(p))
		if not p.contains("mixamorig1_"):
			continue
		total += 1
		var colon := p.rfind(":")
		if colon >= 0 and bones.has(p.substr(colon + 1)):
			bound += 1
	if total == 0 or float(bound) / float(total) < MIN_RETARGET_BIND:
		push_warning("NpcRig: %s retarget bound only %d/%d tracks — rejected" % [path.get_file(), bound, total])
		return null
	var ht := _hip_position_track(anim)
	if ht >= 0 and anim.track_get_key_count(ht) > 0 and _native_stand_hips_y > 0.0:
		# Scale by the source rig's REST hip height when its skeleton says;
		# the first frame only as a fallback — a clip that starts seated or
		# crouched would otherwise be blown up several times over.
		var first: Vector3 = anim.track_get_key_value(ht, 0)
		var ref := source_hips if source_hips > 0.001 else first.y
		if ref > 0.001:
			var k := _native_stand_hips_y / ref
			for i in range(anim.track_get_key_count(ht)):
				var v: Vector3 = anim.track_get_key_value(ht, i)
				anim.track_set_key_value(ht, i, v * k)
	_flatten_root_motion(anim)
	return anim


## Scan MOCAP_DIR/<moment>/ for clips (see MOCAP_DIR). A clip that fails to
## bind is skipped with a warning; a moment with none falls back to
## MOMENT_DEFAULTS that are installed.
static func _load_moment_clips(bones: Dictionary) -> void:
	_moment_clips = {}
	for moment in NpcMocapSpice.MOMENT_NAMES:
		var list: Array = []
		var dir_path: String = MOCAP_DIR + str(moment) + "/"
		var d := DirAccess.open(dir_path)
		if d != null:
			var files := PackedStringArray()
			for f in d.get_files():
				# Exported builds list "X.fbx.import" / ".remap" — the source
				# name is what load() wants either way.
				var src := str(f).trim_suffix(".import").trim_suffix(".remap")
				if src.get_extension().to_lower() in ["fbx", "glb", "gltf"] and not files.has(src):
					files.append(src)
			files.sort()
			for src in files:
				var anim := _retarget_extra(dir_path + src, bones)
				if anim == null:
					continue
				# NOT "mocap/peak/x": AnimationPlayer reads "a/b" as library
				# "a", animation "b", and the clip silently never resolves.
				var name := "mc_%s__%s" % [moment, src.get_basename().validate_node_name().replace(":", "_")]
				var spec: Dictionary = NpcMocapSpice.MOMENTS.get(str(moment), {})
				anim.loop_mode = Animation.LOOP_LINEAR if bool(spec.get("loop", false)) \
					else Animation.LOOP_NONE
				if str(moment) == "sit":
					# Seated clips sit on a chair Mixamo does not draw: put the
					# hips at the ground-sitting height the stick figure uses.
					_ground_offsets[name] = float(TARGET_HIPS_Y[CLIP_SIT]) - _hip_rest_y(anim)
				_lib.add_animation(name, anim)
				_clip_len[name] = anim.length
				_measurements[name] = {"role": ROLE_CYCLIC, "measured_role": ROLE_CYCLIC, "mocap_moment": moment}
				list.append(name)
		if list.is_empty():
			for c in MOMENT_DEFAULTS.get(moment, []):
				if _lib.has_animation(str(c)):
					list.append(str(c))
		_moment_clips[moment] = list


## The pack's standing hip height (metres) — the stick figure scales a clip's
## body height by HIP_Y / this.
static func native_hips_y() -> float:
	_ensure_loaded()
	return _native_stand_hips_y if _native_stand_hips_y > 0.01 else 0.87


## The clips a mo-cap moment can play (NpcMocapSpice), [] when none.
static func moment_clips(moment: String) -> Array:
	_ensure_loaded()
	return _moment_clips.get(moment, [])


## Shift a clip's hip-position track so its resting height becomes
## `target_rest_y`, keeping the relative motion within the clip intact.
static func _rebase_hip_height(anim: Animation, target_rest_y: float) -> void:
	if target_rest_y <= 0.0:
		return
	var t := _hip_position_track(anim)
	if t < 0:
		return
	var shift := target_rest_y - _hip_rest_y(anim)
	if absf(shift) < 0.001:
		return
	for k in range(anim.track_get_key_count(t)):
		var v: Vector3 = anim.track_get_key_value(t, k)
		anim.track_set_key_value(t, k, Vector3(v.x, v.y + shift, v.z))


static func _bone_names(skel: Skeleton3D) -> Dictionary:
	var out: Dictionary = {}
	if skel == null:
		return out
	for i in range(skel.get_bone_count()):
		out[skel.get_bone_name(i)] = true
	return out


static func _find_node(n: Node, node_name: String) -> Node:
	if n.name == node_name:
		return n
	for c in n.get_children():
		var r := _find_node(c, node_name)
		if r != null:
			return r
	return null


static func _find_typed(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find_typed(c, cls)
		if r != null:
			return r
	return null
