class_name NpcStickMocap
extends Node3D

## A Mixamo clip, worn by the STICK FIGURE (NpcSimpleFigure).
##
## A hidden copy of the NPC pack's character — its skinned meshes freed at
## once, so it is a bare Skeleton3D and an AnimationPlayer — plays a clip;
## every frame `solve()` reads where its joints are and turns that into the
## stick figure's own joint rotations. The stick figure's capsules are round,
## so a limb is fully described by its DIRECTION: no twist, no rest-pose
## matching, no retargeting of the rig itself — the mo-cap T-pose and the
## stick figure's arms-down rest never have to agree. The pelvis, torso and
## head DO need a full orientation (shoulder line, a bow, a nod): the pelvis
## and head take the clip bone's rotation relative to its (upright) rest, the
## torso is built from the spine's direction and the shoulder line.
##
## The figure blends the result over its procedural pose (NpcSimpleFigure
## .pose), so this node never moves a capsule itself. The AnimationPlayer is
## MANUAL: the figure advances it with its own (capped) rate, so a paused sim
## freezes the dance and a time-lapse speeds it up.
##
## Pure maths is static (`solve_points`) and selftested without any art.

## Mixamo bone suffixes this reads (matched by suffix: `mixamorig1_Hips`).
const BONES: Array = ["Hips", "Neck", "Head", "HeadTop_End",
	"LeftArm", "LeftForeArm", "LeftHand", "RightArm", "RightForeArm", "RightHand",
	"LeftUpLeg", "LeftLeg", "LeftFoot", "RightUpLeg", "RightLeg", "RightFoot"]

var clip := ""
var _rig: Node3D = null
var _skel: Skeleton3D = null
var _ap: AnimationPlayer = null
var _idx: Dictionary = {}          # suffix -> bone index
var _rest_hips := Basis()
var _rest_head := Basis()
var _ground_off := 0.0


## Build the hidden rig. False when the NPC pack is not installed.
func build() -> bool:
	if _rig != null:
		return true
	if not NpcRig.available():
		return false
	_rig = NpcRig.build_figure()
	if _rig == null:
		return false
	# The skin is never drawn: free it now (no skinning cost, no GPU mesh).
	for mi in _rig.find_children("*", "MeshInstance3D", true, false):
		(mi as Node).free()
	_rig.rotation.y = NpcRig.model_yaw_offset() - PI   # the stick figure already faces +Z
	_rig.visible = false
	add_child(_rig)
	_skel = NpcRig.find_skeleton(_rig)
	_ap = NpcRig.find_anim_player(_rig)
	if _skel == null or _ap == null:
		_rig.queue_free()
		_rig = null
		return false
	_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for i in _skel.get_bone_count():
		var bn := _skel.get_bone_name(i)
		for suffix in BONES:
			if bn.ends_with("_" + str(suffix)) or bn.ends_with(":" + str(suffix)) or bn == str(suffix):
				_idx[str(suffix)] = i
	if not _idx.has("Hips") or not _idx.has("LeftForeArm"):
		_rig.queue_free()
		_rig = null
		return false
	_rest_hips = _skel.get_bone_global_rest(int(_idx["Hips"])).basis.orthonormalized()
	if _idx.has("Head"):
		_rest_head = _skel.get_bone_global_rest(int(_idx["Head"])).basis.orthonormalized()
	return true


func play(name: String) -> bool:
	if not build() or not _ap.has_animation(name):
		return false
	clip = name
	_ap.play(name)
	_ap.seek(0.0, true)
	_ground_off = NpcRig.clip_ground_offset(name)
	return true


func clip_length() -> float:
	return _ap.get_animation(clip).length if _ap != null and not clip.is_empty() and _ap.has_animation(clip) else 0.0


func advance(dt_clip_s: float) -> void:
	if _ap != null and not clip.is_empty():
		_ap.advance(maxf(dt_clip_s, 0.0))


func stop() -> void:
	clip = ""
	if _ap != null:
		_ap.stop()


## Where the clip has the body right now, in the FIGURE's space (this node's
## parent): {points: {suffix: Vector3}, hips_delta: Basis, head_delta: Basis}
## or {} before build.
func sample() -> Dictionary:
	if _skel == null:
		return {}
	var fig := get_parent() as Node3D
	if fig == null:
		return {}
	# Skeleton space -> figure space (the rig node carries the pack's unit
	# scale and yaw; this node sits at the figure's origin).
	var xf := fig.global_transform.affine_inverse() * _skel.global_transform
	var rot := xf.basis.orthonormalized()
	var pts := {}
	for suffix in _idx:
		var p := xf * _skel.get_bone_global_pose(int(_idx[suffix])).origin
		pts[suffix] = p + Vector3(0.0, _ground_off, 0.0)
	var hb := _skel.get_bone_global_pose(int(_idx["Hips"])).basis.orthonormalized()
	var hd := rot * (hb * _rest_hips.inverse()) * rot.inverse()
	var head_d := hd
	if _idx.has("Head"):
		var hb2 := _skel.get_bone_global_pose(int(_idx["Head"])).basis.orthonormalized()
		head_d = rot * (hb2 * _rest_head.inverse()) * rot.inverse()
	return {"points": pts, "hips_delta": hd.orthonormalized(), "head_delta": head_d.orthonormalized()}


## The stick figure's joint transforms for a sampled pose — pure.
##   stick: {hip_y, hip_x, shoulder_x, shoulder_y (torso-local), head_y
##           (torso-local), scale (stick hips / mocap standing hips)}
## Returns {body_pos, body_basis, torso, head, shoulder: [R, L], elbow: [R, L],
## hip: [R, L], knee: [R, L]} — every Basis LOCAL to its node's parent, the
## stick figure's index order (0 = the person's RIGHT, -X; 1 = LEFT, +X).
static func solve_points(sample_d: Dictionary, stick: Dictionary) -> Dictionary:
	var p: Dictionary = sample_d.get("points", {})
	if not p.has("Hips"):
		return {}
	var k := float(stick.get("scale", 1.0))
	var hip_y := float(stick.get("hip_y", 0.86))
	var hips: Vector3 = (p["Hips"] as Vector3) * k
	var b_body: Basis = (sample_d.get("hips_delta", Basis()) as Basis).orthonormalized()
	var out := {}
	out["body_basis"] = b_body
	out["body_pos"] = hips - b_body * Vector3(0.0, hip_y, 0.0)
	# Torso: up along the spine, its X along the shoulder line (the person's
	# left is +X for a figure facing +Z).
	var neck: Vector3 = p.get("Neck", p["Hips"])
	var up := (neck - (p["Hips"] as Vector3))
	up = up.normalized() if up.length() > 1e-5 else b_body.y
	var side := Vector3(1.0, 0.0, 0.0)
	if p.has("LeftArm") and p.has("RightArm"):
		side = (p["LeftArm"] as Vector3) - (p["RightArm"] as Vector3)
	side = (side - up * side.dot(up))
	side = side.normalized() if side.length() > 1e-5 else b_body.x
	var b_torso := Basis(side, up, side.cross(up)).orthonormalized()
	out["torso"] = (b_body.inverse() * b_torso).orthonormalized()
	var b_head: Basis = (sample_d.get("head_delta", b_torso) as Basis).orthonormalized()
	out["head"] = (b_torso.inverse() * b_head).orthonormalized()
	var sh: Array = []
	var el: Array = []
	var hp: Array = []
	var kn: Array = []
	for side_name in ["Right", "Left"]:
		var upper := _limb_basis(p, side_name + "Arm", side_name + "ForeArm", b_torso)
		sh.append(upper)
		el.append(_limb_basis(p, side_name + "ForeArm", side_name + "Hand", b_torso * upper))
		var thigh := _limb_basis(p, side_name + "UpLeg", side_name + "Leg", b_body)
		hp.append(thigh)
		kn.append(_limb_basis(p, side_name + "Leg", side_name + "Foot", b_body * thigh))
	out["shoulder"] = sh
	out["elbow"] = el
	out["hip"] = hp
	out["knee"] = kn
	return out


## The rotation (local to a parent with global basis `parent`) that turns a
## limb hanging along -Y to point from bone `a` to bone `b`.
static func _limb_basis(p: Dictionary, a: String, b: String, parent: Basis) -> Basis:
	if not p.has(a) or not p.has(b):
		return Basis()
	var d: Vector3 = (p[b] as Vector3) - (p[a] as Vector3)
	if d.length() < 1e-5:
		return Basis()
	var local := (parent.inverse() * d.normalized()).normalized()
	return Basis(arc(Vector3.DOWN, local))


## Shortest-arc rotation from unit `from` to unit `to` (antiparallel-safe).
static func arc(from: Vector3, to: Vector3) -> Quaternion:
	var c := from.dot(to)
	if c > 0.99999:
		return Quaternion.IDENTITY
	if c < -0.99999:
		var axis := from.cross(Vector3.RIGHT)
		if axis.length() < 1e-4:
			axis = from.cross(Vector3.FORWARD)
		return Quaternion(axis.normalized(), PI)
	var axis2 := from.cross(to).normalized()
	return Quaternion(axis2, acos(clampf(c, -1.0, 1.0)))
