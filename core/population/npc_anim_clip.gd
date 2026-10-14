class_name NpcAnimClip
extends RefCounted
## An authored keyframe clip for the stick figure (NpcSimpleFigure) — what the
## NPC animation editor writes and the fabrication swarm plays (sawing,
## drilling, fastening, carrying, lifting). Pure data + sampling; JSON on disk.
##
## Shipped clips: res://core/population/anims/<id>.json. A player's edits:
## user://npc_anims/<id>.json, which win over the shipped clip of the same id.
##
## Format:
##   {id, label, length_s, loop,
##    keys: [{t, ease: "linear"|"ease"|"step",
##            joints: {<joint>: [x, y, z] degrees, Euler YXZ like Node3D.rotation},
##            body: {y, pitch, yaw}}],        (y in metres; angles in degrees)
##    ik: {hand_r, hand_l: "grip" | "grip2" | "none"},   which tool socket each
##        hand reaches for by IK while the clip plays ("none" = the keyed arm)
##    feet: "planted" | "keyed",
##    tool: {id, hand: "r" | "l"},
##    events: [{t, name}]}                    e.g. "contact", "release"
##
## Joints are TRACKS: a key lists only the joints it sets, and each joint is
## interpolated between its own neighbouring keys, so posing the right arm
## never disturbs a leg. Between keys a joint is slerped as a quaternion (a
## lerp of Euler angles can swing a limb the long way round — the trap the
## mo-cap spice notes describe).

## Joint names. "_r" is the figure's index 0 (its right, -X), "_l" index 1.
const JOINTS := ["lean", "torso", "neck", "head",
	"shoulder_r", "elbow_r", "wrist_r", "shoulder_l", "elbow_l", "wrist_l",
	"hip_r", "knee_r", "foot_r", "hip_l", "knee_l", "foot_l"]

const EASES := ["linear", "ease", "step"]
const SHIPPED_DIR := "res://core/population/anims/"
const USER_DIR := "user://npc_anims/"

var id := ""
var label := ""
var length_s := 1.0
var loop := true
var keys: Array = []          # sorted by t
var ik := {"hand_r": "none", "hand_l": "none"}
var feet := "keyed"
var tool := {}
var events: Array = []


static func from_dict(d: Dictionary) -> NpcAnimClip:
	var c := NpcAnimClip.new()
	c.id = str(d.get("id", ""))
	c.label = str(d.get("label", c.id))
	c.length_s = maxf(0.05, float(d.get("length_s", 1.0)))
	c.loop = bool(d.get("loop", true))
	for k in d.get("keys", []):
		if not (k is Dictionary):
			continue
		var joints := {}
		var src = k.get("joints", {})
		if src is Dictionary:
			for j in src:
				var v = src[j]
				if str(j) in JOINTS and v is Array and (v as Array).size() >= 3:
					joints[str(j)] = Vector3(float(v[0]), float(v[1]), float(v[2]))
		var body := {}
		var b = k.get("body", {})
		if b is Dictionary:
			for f in ["y", "pitch", "yaw"]:
				if b.has(f):
					body[f] = float(b[f])
		var ease_name := str(k.get("ease", "ease"))
		c.keys.append({"t": clampf(float(k.get("t", 0.0)), 0.0, c.length_s),
			"ease": ease_name if ease_name in EASES else "ease", "joints": joints, "body": body})
	c.keys.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))
	var ikd = d.get("ik", {})
	if ikd is Dictionary:
		for h in ["hand_r", "hand_l"]:
			var v := str(ikd.get(h, "none"))
			c.ik[h] = v if v in ["grip", "grip2", "none"] else "none"
	c.feet = "planted" if str(d.get("feet", "keyed")) == "planted" else "keyed"
	if d.get("tool") is Dictionary and not str(d["tool"].get("id", "")).is_empty():
		c.tool = {"id": str(d["tool"]["id"]), "hand": "l" if str(d["tool"].get("hand", "r")) == "l" else "r"}
	for e in d.get("events", []):
		if e is Dictionary:
			c.events.append({"t": float(e.get("t", 0.0)), "name": str(e.get("name", ""))})
	return c


func to_dict() -> Dictionary:
	var ks: Array = []
	for k in keys:
		var joints := {}
		for j in k["joints"]:
			var v: Vector3 = k["joints"][j]
			joints[j] = [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]
		var e := {"t": snappedf(float(k["t"]), 0.0001), "ease": k["ease"], "joints": joints}
		if not (k["body"] as Dictionary).is_empty():
			e["body"] = (k["body"] as Dictionary).duplicate()
		ks.append(e)
	var out := {"id": id, "label": label, "length_s": length_s, "loop": loop, "keys": ks,
		"ik": ik.duplicate(), "feet": feet, "events": events.duplicate(true)}
	if not tool.is_empty():
		out["tool"] = tool.duplicate()
	return out


func duplicate_clip() -> NpcAnimClip:
	return NpcAnimClip.from_dict(to_dict())


# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

static func _shape(u: float, ease_name: String) -> float:
	match ease_name:
		"linear":
			return u
		"step":
			return 0.0 if u < 1.0 else 1.0
	return u * u * (3.0 - 2.0 * u)   # smoothstep


func _wrap(t: float) -> float:
	if loop:
		return fposmod(t, length_s)
	return clampf(t, 0.0, length_s)


## The two keys around `t` for a track (keys that set `has(k)`), and the shaped
## blend between them. Wraps on a looping clip.
func _bracket(t: float, has: Callable) -> Dictionary:
	var ks: Array = []
	for k in keys:
		if has.call(k):
			ks.append(k)
	if ks.is_empty():
		return {}
	if ks.size() == 1:
		return {"a": ks[0], "b": ks[0], "w": 0.0}
	var tt := _wrap(t)
	for i in ks.size():
		if float(ks[i]["t"]) > tt:
			if i == 0:
				if not loop:
					return {"a": ks[0], "b": ks[0], "w": 0.0}
				var prev: Dictionary = ks[ks.size() - 1]
				var span := float(ks[0]["t"]) + length_s - float(prev["t"])
				var u := (tt + length_s - float(prev["t"])) / maxf(span, 1e-6)
				return {"a": prev, "b": ks[0], "w": _shape(clampf(u, 0.0, 1.0), str(prev["ease"]))}
			var a: Dictionary = ks[i - 1]
			var b: Dictionary = ks[i]
			var u2 := (tt - float(a["t"])) / maxf(float(b["t"]) - float(a["t"]), 1e-6)
			return {"a": a, "b": b, "w": _shape(clampf(u2, 0.0, 1.0), str(a["ease"]))}
	var last: Dictionary = ks[ks.size() - 1]
	if not loop:
		return {"a": last, "b": last, "w": 0.0}
	var span2 := float(ks[0]["t"]) + length_s - float(last["t"])
	var u3 := (tt - float(last["t"])) / maxf(span2, 1e-6)
	return {"a": last, "b": ks[0], "w": _shape(clampf(u3, 0.0, 1.0), str(last["ease"]))}


static func euler_deg_to_quat(v: Vector3) -> Quaternion:
	return Basis.from_euler(Vector3(deg_to_rad(v.x), deg_to_rad(v.y), deg_to_rad(v.z))).get_rotation_quaternion()


## The pose at time t: {joints: {name: Quaternion}, body: {y, pitch, yaw}
## (radians for angles, metres for y; only the fields some key sets)}.
func sample(t: float) -> Dictionary:
	var joints := {}
	for j in JOINTS:
		var br := _bracket(t, func(k): return (k["joints"] as Dictionary).has(j))
		if br.is_empty():
			continue
		var qa := euler_deg_to_quat(br["a"]["joints"][j])
		var qb := euler_deg_to_quat(br["b"]["joints"][j])
		joints[j] = qa.slerp(qb, float(br["w"]))
	var body := {}
	for f in ["y", "pitch", "yaw"]:
		var brb := _bracket(t, func(k): return (k["body"] as Dictionary).has(f))
		if brb.is_empty():
			continue
		var va := float(brb["a"]["body"][f])
		var vb := float(brb["b"]["body"][f])
		var v := lerpf(va, vb, float(brb["w"]))
		body[f] = v if f == "y" else deg_to_rad(v)
	return {"joints": joints, "body": body}


## Events crossed going from t0 to t1 (forward, wrapping on a loop).
func events_between(t0: float, t1: float) -> Array:
	var out: Array = []
	if t1 <= t0:
		return out
	for e in events:
		var et := float(e["t"])
		if loop:
			var n0 := floorf((t0 - et) / length_s)
			var n1 := floorf((t1 - et) / length_s)
			if n1 > n0:
				out.append(e["name"])
		elif et > t0 and et <= t1:
			out.append(e["name"])
	return out


## The clip played by the OTHER hand: left and right swapped, mirrored across
## the figure's YZ plane (an Euler (x, y, z) becomes (x, -y, -z)).
func mirror() -> NpcAnimClip:
	var c := duplicate_clip()
	for k in c.keys:
		var src: Dictionary = k["joints"]
		var swapped := {}
		for j in src:
			var v: Vector3 = src[j]
			swapped[_other_side(str(j))] = Vector3(v.x, -v.y, -v.z)
		k["joints"] = swapped
		if (k["body"] as Dictionary).has("yaw"):
			k["body"]["yaw"] = -float(k["body"]["yaw"])
	var r = c.ik.get("hand_r", "none")
	c.ik["hand_r"] = c.ik.get("hand_l", "none")
	c.ik["hand_l"] = r
	if not c.tool.is_empty():
		c.tool["hand"] = "l" if str(c.tool.get("hand", "r")) == "r" else "r"
	c.id = id + "_mirror"
	return c


static func _other_side(j: String) -> String:
	if j.ends_with("_r"):
		return j.trim_suffix("_r") + "_l"
	if j.ends_with("_l"):
		return j.trim_suffix("_l") + "_r"
	return j


# ---------------------------------------------------------------------------
# Editing (the animation editor writes through these)
# ---------------------------------------------------------------------------

## Two keys closer than this are the same key.
const KEY_TOL_S := 1.0 / 120.0


## Index of the key at time t (within KEY_TOL_S), or -1.
func key_index_at(t: float) -> int:
	for i in keys.size():
		if absf(float(keys[i]["t"]) - t) <= KEY_TOL_S:
			return i
	return -1


## The key at t, created (empty) when there is none. Keeps keys sorted.
func ensure_key(t: float) -> Dictionary:
	var i := key_index_at(t)
	if i >= 0:
		return keys[i]
	var k := {"t": clampf(t, 0.0, length_s), "ease": "ease", "joints": {}, "body": {}}
	keys.append(k)
	keys.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))
	return k


## Key one joint (Euler degrees) at t. Only that joint's track changes.
func set_joint_at(t: float, joint: String, euler_deg: Vector3) -> void:
	if not (joint in JOINTS):
		return
	ensure_key(t)["joints"][joint] = euler_deg


## Key a body field (y metres; pitch / yaw degrees) at t.
func set_body_at(t: float, field: String, value: float) -> void:
	if field in ["y", "pitch", "yaw"]:
		ensure_key(t)["body"][field] = value


## Remove one joint from the key at t (the key goes when it is empty), or the
## whole key when `joint` is "".
func remove_at(t: float, joint: String = "") -> bool:
	var i := key_index_at(t)
	if i < 0:
		return false
	if joint.is_empty():
		keys.remove_at(i)
		return true
	(keys[i]["joints"] as Dictionary).erase(joint)
	if (keys[i]["joints"] as Dictionary).is_empty() and (keys[i]["body"] as Dictionary).is_empty():
		keys.remove_at(i)
	return true


## Every keyed joint's value at t, as Euler degrees (what "copy pose" copies):
## {joints: {name: Vector3}, body: {y, pitch, yaw (degrees)}}.
func pose_at(t: float) -> Dictionary:
	var s := sample(t)
	var joints := {}
	for j in s["joints"]:
		var e := Basis(s["joints"][j] as Quaternion).get_euler()
		joints[j] = Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))
	var body := {}
	for f in s["body"]:
		body[f] = float(s["body"][f]) if f == "y" else rad_to_deg(float(s["body"][f]))
	return {"joints": joints, "body": body}


## Key a whole pose (from pose_at) at t.
func paste_pose(t: float, pose: Dictionary) -> void:
	var k := ensure_key(t)
	for j in pose.get("joints", {}):
		k["joints"][j] = pose["joints"][j]
	for f in pose.get("body", {}):
		k["body"][f] = pose["body"][f]


## The pose for the other side (left <-> right, mirrored across YZ).
static func mirror_pose(pose: Dictionary) -> Dictionary:
	var joints := {}
	for j in pose.get("joints", {}):
		var v: Vector3 = pose["joints"][j]
		joints[_other_side(str(j))] = Vector3(v.x, -v.y, -v.z)
	var body: Dictionary = (pose.get("body", {}) as Dictionary).duplicate()
	if body.has("yaw"):
		body["yaw"] = -float(body["yaw"])
	return {"joints": joints, "body": body}


## Key times (sorted) — all keys, or only those setting `joint`.
func key_times(joint: String = "") -> Array:
	var out: Array = []
	for k in keys:
		if joint.is_empty() or (k["joints"] as Dictionary).has(joint):
			out.append(float(k["t"]))
	return out


# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

## Load a clip by id: the player's copy (user://npc_anims/) over the shipped one.
static func load_clip(clip_id: String) -> NpcAnimClip:
	for dir in [USER_DIR, SHIPPED_DIR]:
		var path: String = dir + clip_id + ".json"
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f != null else null
		if d is Dictionary:
			var c := NpcAnimClip.from_dict(d)
			if c.id.is_empty():
				c.id = clip_id
			return c
	return null


## Ids of every clip (shipped + user), sorted.
static func list_ids() -> Array:
	var ids := {}
	for dir in [SHIPPED_DIR, USER_DIR]:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for f in d.get_files():
			if f.ends_with(".json"):
				ids[f.get_basename()] = true
	var out: Array = ids.keys()
	out.sort()
	return out


## Save to the user library (never the shipped folder). Returns the path.
static func save_user(clip: NpcAnimClip, dir: String = USER_DIR) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir + clip.id + ".json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(clip.to_dict(), "\t"))
	return path
