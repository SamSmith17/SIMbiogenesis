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

## file (under DIR) -> [clip name, should_loop]. The mapping from *activity* to
## clip lives in NpcAvatar; this is only "what is in the box".
const SOURCES := {
	"Walking.fbx": [CLIP_WALK, true],
	"Laying Sleeping.fbx": [CLIP_SLEEP, true],
	"Overhead Squat.fbx": [CLIP_WORK, true],
	"Sitting Idle.fbx": [CLIP_SIT, true],
	"Arms Hip Hop Dance.fbx": [CLIP_DANCE, true],
}

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
	for file in SOURCES.keys():
		var spec: Array = SOURCES[file]
		var anim := _extract(DIR + String(file))
		if anim == null:
			push_warning("NpcRig: missing clip source %s" % file)
			continue
		var clip_name := String(spec[0])
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
		_lib.add_animation(clip_name, anim)

	var idle := _retarget_idle(bones)
	if idle != null:
		_lib.add_animation(CLIP_IDLE, idle)
	elif _lib.has_animation(CLIP_SIT):
		# Better a wrong-but-alive pose than a rigid T-pose; recorded so the
		# selftest can tell a real idle from this fallback.
		_load_error = "no standing idle; falling back to seated"
		_lib.add_animation(CLIP_IDLE, _lib.get_animation(CLIP_SIT).duplicate(true))


static func _extract(path: String) -> Animation:
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var root := packed.instantiate()
	var ap := find_anim_player(root)
	var out: Animation = null
	if ap != null:
		for lib_name in ap.get_animation_library_list():
			var lib := ap.get_animation_library(lib_name)
			for a in lib.get_animation_list():
				if String(a) == TAKE_NAME:
					# Duplicate: the imported Animation is a shared resource and
					# flattening it in place would mutate every other user.
					out = lib.get_animation(a).duplicate(true) as Animation
					break
			if out != null:
				break
	root.free()
	return out


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
