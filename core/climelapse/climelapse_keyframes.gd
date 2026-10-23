class_name ClimelapseKeyframes
extends RefCounted

## Camera keyframes for a hyperlapse, each pinned to a moment on the timeline.
##
## A key is {t (absolute sim hours), pos, yaw, pitch, fov}. Between keys the
## camera follows a cubic Hermite curve in TIME, so a key that sits closer to
## its neighbour makes the camera move faster there, and two keys an hour apart
## and two keys a week apart both take exactly as long as the clock says.
## Tangents are finite differences over the neighbours (a Catmull-Rom spline
## with uneven spacing); the first and last keys get zero tangents, so the
## move eases in and out. With `smooth` off the camera moves in straight
## lines. Before the first key the camera holds the first pose, after the last
## it holds the last one.
##
## Yaw is unwrapped key to key so a turn through ±180° takes the short way.
## Pure data: the selftest drives it without a scene.

const VERSION := 1
## Two keys closer than this (sim hours) count as the same moment.
const SAME_MOMENT_H := 1.0 / 120.0

const MAX_PITCH := 1.5533430342749532  # 89°
const MIN_FOV := 5.0
const MAX_FOV := 120.0

var keys: Array = []
var smooth := true


func size() -> int:
	return keys.size()


func is_empty() -> bool:
	return keys.is_empty()


func clear() -> void:
	keys.clear()


func key(i: int) -> Dictionary:
	return keys[i] if i >= 0 and i < keys.size() else {}


static func make_key(t: float, xform: Transform3D, fov: float = 75.0) -> Dictionary:
	var e := xform.basis.get_euler()
	return {"t": t, "pos": xform.origin, "yaw": e.y, "pitch": e.x, "fov": fov}


static func key_transform(k: Dictionary) -> Transform3D:
	var p: Variant = k.get("pos", Vector3.ZERO)
	var pos: Vector3 = p if p is Vector3 else Vector3.ZERO
	return Transform3D(Basis.from_euler(Vector3(float(k.get("pitch", 0.0)), float(k.get("yaw", 0.0)), 0.0)), pos)


## Add a key at time t, or replace the pose of a key already at that moment.
## Returns the key's index after sorting.
func set_key(t: float, xform: Transform3D, fov: float = 75.0) -> int:
	var k := make_key(t, xform, fov)
	var same := index_near(t, SAME_MOMENT_H)
	if same >= 0:
		keys[same] = k
	else:
		keys.append(k)
	_sort()
	return index_of_time(t)


## Change a key's time. Returns its new index (keys stay sorted by time).
func move_key(i: int, t: float) -> int:
	if i < 0 or i >= keys.size():
		return -1
	var k: Dictionary = keys[i]
	k["t"] = t
	_sort()
	return keys.find(k)


## Replace a key's pose, keeping its time.
func repose_key(i: int, xform: Transform3D, fov: float) -> void:
	if i < 0 or i >= keys.size():
		return
	var t := float((keys[i] as Dictionary).get("t", 0.0))
	keys[i] = make_key(t, xform, fov)


## Set key i's pose directly (the camera-path editor): position, yaw and
## pitch in radians, fov in degrees. Pitch stops short of straight up / down
## (the yaw would be undefined there); the key keeps its time.
func set_pose(i: int, pos: Vector3, yaw: float, pitch: float, fov: float) -> void:
	if i < 0 or i >= keys.size():
		return
	var k: Dictionary = keys[i]
	k["pos"] = pos
	k["yaw"] = wrapf(yaw, -PI, PI)
	k["pitch"] = clampf(pitch, -MAX_PITCH, MAX_PITCH)
	k["fov"] = clampf(fov, MIN_FOV, MAX_FOV)


func remove_key(i: int) -> void:
	if i >= 0 and i < keys.size():
		keys.remove_at(i)


## Index of the key nearest t within `tol_h`, else -1.
func index_near(t: float, tol_h: float) -> int:
	var best := -1
	var best_d := tol_h
	for i in keys.size():
		var d := absf(float((keys[i] as Dictionary).get("t", 0.0)) - t)
		if d <= best_d:
			best_d = d
			best = i
	return best


func index_of_time(t: float) -> int:
	for i in keys.size():
		if absf(float((keys[i] as Dictionary).get("t", 0.0)) - t) < 1e-9:
			return i
	return index_near(t, SAME_MOMENT_H)


func times() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for k in keys:
		out.append(float((k as Dictionary).get("t", 0.0)))
	return out


func _sort() -> void:
	keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))


## The camera at absolute hour `abs_h`: {xform: Transform3D, fov: float}.
func sample(abs_h: float) -> Dictionary:
	if keys.is_empty():
		return {}
	var n := keys.size()
	var first: Dictionary = keys[0]
	var last: Dictionary = keys[n - 1]
	if n == 1 or abs_h <= float(first.get("t", 0.0)):
		return {"xform": key_transform(first), "fov": float(first.get("fov", 75.0))}
	if abs_h >= float(last.get("t", 0.0)):
		return {"xform": key_transform(last), "fov": float(last.get("fov", 75.0))}
	var i := 0
	while i < n - 2 and abs_h > float((keys[i + 1] as Dictionary).get("t", 0.0)):
		i += 1
	var ts := times()
	var yaws := _unwrapped_yaws()
	var t0 := ts[i]
	var t1 := ts[i + 1]
	var dt := maxf(t1 - t0, 1e-9)
	var u := clampf((abs_h - t0) / dt, 0.0, 1.0)
	var pos: Vector3
	var yaw: float
	var pitch: float
	if smooth:
		pos = _hermite_v(i, u, dt, ts, func(j: int) -> Vector3: return _pos(j))
		yaw = _hermite_f(i, u, dt, ts, func(j: int) -> float: return yaws[j])
		pitch = _hermite_f(i, u, dt, ts, func(j: int) -> float: return float((keys[j] as Dictionary).get("pitch", 0.0)))
	else:
		pos = _pos(i).lerp(_pos(i + 1), u)
		yaw = lerpf(yaws[i], yaws[i + 1], u)
		pitch = lerpf(float((keys[i] as Dictionary).get("pitch", 0.0)),
			float((keys[i + 1] as Dictionary).get("pitch", 0.0)), u)
	var fov := lerpf(float((keys[i] as Dictionary).get("fov", 75.0)),
		float((keys[i + 1] as Dictionary).get("fov", 75.0)), u)
	return {"xform": Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0.0)), pos), "fov": fov}


## The path the camera flies, `n` samples from the first key's moment to the
## last's: [{t, pos, fwd}]. One key gives that key; none gives [].
func sample_path(n: int) -> Array:
	var out: Array = []
	if keys.is_empty():
		return out
	var ts := times()
	var t0 := ts[0]
	var t1 := ts[ts.size() - 1]
	var m := 1 if keys.size() == 1 or t1 <= t0 else maxi(n, 2)
	for j in m:
		var t := t0 if m == 1 else lerpf(t0, t1, float(j) / float(m - 1))
		var smp := sample(t)
		var xf: Transform3D = smp["xform"]
		out.append({"t": t, "pos": xf.origin, "fwd": -xf.basis.z})
	return out


## The camera's view direction for a yaw / pitch (radians).
static func forward(yaw: float, pitch: float) -> Vector3:
	return Basis.from_euler(Vector3(pitch, yaw, 0.0)) * Vector3.FORWARD


## Compass heading (degrees clockwise from north = -Z) of a yaw, and back.
static func heading_deg(yaw: float) -> float:
	return wrapf(rad_to_deg(-yaw), 0.0, 360.0)


static func yaw_for_heading(deg: float) -> float:
	return wrapf(deg_to_rad(-deg), -PI, PI)


## The four corners of a camera's view `dist` metres out (TL, TR, BR, BL).
## `fov_deg` is the VERTICAL field of view (Godot's keep-height default).
static func frustum_corners(xf: Transform3D, fov_deg: float, aspect: float, dist: float) -> PackedVector3Array:
	var hh := tan(deg_to_rad(clampf(fov_deg, 1.0, 179.0)) * 0.5) * dist
	var hw := hh * maxf(aspect, 0.01)
	var out := PackedVector3Array()
	for c in [Vector2(-hw, hh), Vector2(hw, hh), Vector2(hw, -hh), Vector2(-hw, -hh)]:
		out.append(xf * Vector3(c.x, c.y, -dist))
	return out


func _pos(j: int) -> Vector3:
	var p: Variant = (keys[j] as Dictionary).get("pos", Vector3.ZERO)
	return p if p is Vector3 else Vector3.ZERO


func _unwrapped_yaws() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var prev := 0.0
	for j in keys.size():
		var y := float((keys[j] as Dictionary).get("yaw", 0.0))
		if j > 0:
			y = prev + wrapf(y - prev, -PI, PI)
		out.append(y)
		prev = y
	return out


## Tangent (value per hour) at key j: zero at the ends, else the slope over
## the two neighbours.
static func _slope(j: int, ts: PackedFloat64Array, val: Callable) -> Variant:
	var n := ts.size()
	if j <= 0 or j >= n - 1:
		return null
	var span := maxf(ts[j + 1] - ts[j - 1], 1e-9)
	return (val.call(j + 1) - val.call(j - 1)) / span


static func _hermite_v(i: int, u: float, dt: float, ts: PackedFloat64Array, val: Callable) -> Vector3:
	var p0: Vector3 = val.call(i)
	var p1: Vector3 = val.call(i + 1)
	var s0: Variant = _slope(i, ts, val)
	var s1: Variant = _slope(i + 1, ts, val)
	var m0: Vector3 = (s0 as Vector3) * dt if s0 != null else Vector3.ZERO
	var m1: Vector3 = (s1 as Vector3) * dt if s1 != null else Vector3.ZERO
	return _h00(u) * p0 + _h10(u) * m0 + _h01(u) * p1 + _h11(u) * m1


static func _hermite_f(i: int, u: float, dt: float, ts: PackedFloat64Array, val: Callable) -> float:
	var p0 := float(val.call(i))
	var p1 := float(val.call(i + 1))
	var s0: Variant = _slope(i, ts, val)
	var s1: Variant = _slope(i + 1, ts, val)
	var m0 := float(s0) * dt if s0 != null else 0.0
	var m1 := float(s1) * dt if s1 != null else 0.0
	return _h00(u) * p0 + _h10(u) * m0 + _h01(u) * p1 + _h11(u) * m1


static func _h00(u: float) -> float:
	return 2.0 * u * u * u - 3.0 * u * u + 1.0


static func _h10(u: float) -> float:
	return u * u * u - 2.0 * u * u + u


static func _h01(u: float) -> float:
	return -2.0 * u * u * u + 3.0 * u * u


static func _h11(u: float) -> float:
	return u * u * u - u * u


## Spread an old untimed waypoint list (pre-2026-10-22 sessions) evenly over
## [start_abs, end_abs].
static func from_uniform_path(path: Array, start_abs: float, end_abs: float, fov: float = 75.0) -> ClimelapseKeyframes:
	var kf := ClimelapseKeyframes.new()
	var n := path.size()
	for j in n:
		var wp: Dictionary = path[j]
		var t := start_abs if n <= 1 else lerpf(start_abs, end_abs, float(j) / float(n - 1))
		var pos: Variant = wp.get("pos", Vector3.ZERO)
		kf.keys.append({"t": t, "pos": pos if pos is Vector3 else Vector3.ZERO,
			"yaw": float(wp.get("yaw", 0.0)), "pitch": float(wp.get("pitch", 0.0)), "fov": fov})
	kf._sort()
	return kf


func duplicate_keys() -> ClimelapseKeyframes:
	var kf := ClimelapseKeyframes.new()
	kf.smooth = smooth
	kf.keys = keys.duplicate(true)
	return kf


func to_dict() -> Dictionary:
	var out: Array = []
	for k in keys:
		var d: Dictionary = k
		var p: Vector3 = _pos(keys.find(k))
		out.append({"t": float(d.get("t", 0.0)), "pos": [p.x, p.y, p.z],
			"yaw": float(d.get("yaw", 0.0)), "pitch": float(d.get("pitch", 0.0)),
			"fov": float(d.get("fov", 75.0))})
	return {"version": VERSION, "smooth": smooth, "keys": out}


func from_dict(data: Dictionary) -> void:
	keys.clear()
	smooth = bool(data.get("smooth", true))
	for item in data.get("keys", []):
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var p: Variant = d.get("pos", [0, 0, 0])
		var pos := Vector3.ZERO
		if p is Array and (p as Array).size() >= 3:
			pos = Vector3(float(p[0]), float(p[1]), float(p[2]))
		keys.append({"t": float(d.get("t", 0.0)), "pos": pos, "yaw": float(d.get("yaw", 0.0)),
			"pitch": float(d.get("pitch", 0.0)), "fov": float(d.get("fov", 75.0))})
	_sort()


func save_json(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(), "\t"))
	return true


static func load_json(path: String) -> ClimelapseKeyframes:
	var kf := ClimelapseKeyframes.new()
	if not FileAccess.file_exists(path):
		return kf
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return kf
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		kf.from_dict(parsed as Dictionary)
	return kf
