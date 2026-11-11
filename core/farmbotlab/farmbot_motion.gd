class_name FarmBotMotion
extends RefCounted

## How a FarmBot moves.
##
## A FarmBot does not plan coordinated lines the way a 3D printer does. Its
## Farmduino firmware takes a target (x, y, z) and starts all three axes at
## once, each on its OWN speed ramp: from a minimum speed, up to its maximum
## over a ramp distance, cruising, and back down to the minimum as it arrives.
## The axes finish at different times (a short Y hop is done long before a
## long X run), the path is a dog-leg rather than a straight line, and the
## machine stops at every target. That is what this file models.
##
## The ramp is constant acceleration a = (vmax² − vmin²) / (2·ramp), which
## reaches vmax exactly over the ramp distance. A move shorter than two ramps
## peaks at vp = sqrt(vmin² + a·d) half way. Distances in mm, times in s.
##
## FarmBot OS also lifts to a safe height before a long XY move when the
## sequence asks it to; FarmBotJobs does that with separate Z moves.

## One axis' move of distance d (mm, >= 0): the trapezoid's numbers.
static func axis_profile(d: float, vmin: float, vmax: float, ramp: float) -> Dictionary:
	d = absf(d)
	vmax = maxf(vmax, 0.1)
	vmin = clampf(vmin, 0.01, vmax)
	ramp = maxf(ramp, 0.01)
	if d <= 0.0:
		return {"d": 0.0, "t": 0.0, "a": 0.0, "vmin": vmin, "vp": vmin, "ta": 0.0, "da": 0.0, "tc": 0.0}
	var a := (vmax * vmax - vmin * vmin) / (2.0 * ramp)
	if a <= 0.0:
		# No ramp at all (vmin == vmax): constant speed.
		return {"d": d, "t": d / vmax, "a": 0.0, "vmin": vmax, "vp": vmax, "ta": 0.0, "da": 0.0, "tc": d / vmax}
	var vp := vmax
	var da := ramp
	if d < 2.0 * ramp:
		vp = sqrt(vmin * vmin + a * d)
		da = d * 0.5
	var ta := (vp - vmin) / a
	var tc := (d - 2.0 * da) / vp
	return {"d": d, "t": 2.0 * ta + tc, "a": a, "vmin": vmin, "vp": vp, "ta": ta, "da": da, "tc": tc}


## Distance covered t seconds into a profile (0 .. d).
static func axis_pos(p: Dictionary, t: float) -> float:
	var d := float(p["d"])
	var T := float(p["t"])
	if t <= 0.0 or d <= 0.0:
		return 0.0
	if t >= T:
		return d
	var a := float(p["a"])
	var v0 := float(p["vmin"])
	var ta := float(p["ta"])
	var tc := float(p["tc"])
	var vp := float(p["vp"])
	var da := float(p["da"])
	if a <= 0.0:
		return minf(t * vp, d)
	if t < ta:
		return v0 * t + 0.5 * a * t * t
	if t < ta + tc:
		return da + vp * (t - ta)
	var u := T - t
	return d - (v0 * u + 0.5 * a * u * u)


## Speed t seconds into a profile.
static func axis_speed(p: Dictionary, t: float) -> float:
	var T := float(p["t"])
	if t < 0.0 or t > T or float(p["d"]) <= 0.0:
		return 0.0
	var a := float(p["a"])
	var ta := float(p["ta"])
	var tc := float(p["tc"])
	if a <= 0.0:
		return float(p["vp"])
	if t < ta:
		return float(p["vmin"]) + a * t
	if t < ta + tc:
		return float(p["vp"])
	return float(p["vmin"]) + a * (T - t)


## The three axes' limits from a resolved spec: [[vmin, vmax, ramp] x, y, z].
static func limits(spec: Dictionary) -> Array:
	var m: Dictionary = spec["motion"]
	var xy := [float(m["xy_min_mm_s"]), float(m["xy_max_mm_s"]), float(m["xy_ramp_mm"])]
	return [xy, xy.duplicate(), [float(m["z_min_mm_s"]), float(m["z_max_mm_s"]), float(m["z_ramp_mm"])]]


## The three profiles of a move from a to b (machine mm).
static func move_profiles(lim: Array, a: Vector3, b: Vector3) -> Array:
	var out: Array = []
	for i in 3:
		var l: Array = lim[i]
		out.append(axis_profile(b[i] - a[i], float(l[0]), float(l[1]), float(l[2])))
	return out


## How long a move takes: the slowest axis (they run at once).
static func move_time(lim: Array, a: Vector3, b: Vector3) -> float:
	var t := 0.0
	for i in 3:
		var l: Array = lim[i]
		t = maxf(t, axis_time(b[i] - a[i], float(l[0]), float(l[1]), float(l[2])))
	return t


## axis_profile's time alone, with nothing allocated (the day plans ask it
## for every move of every day they average).
static func axis_time(d: float, vmin: float, vmax: float, ramp: float) -> float:
	d = absf(d)
	if d <= 0.0:
		return 0.0
	vmax = maxf(vmax, 0.1)
	vmin = clampf(vmin, 0.01, vmax)
	ramp = maxf(ramp, 0.01)
	var a := (vmax * vmax - vmin * vmin) / (2.0 * ramp)
	if a <= 0.0:
		return d / vmax
	if d < 2.0 * ramp:
		return 2.0 * (sqrt(vmin * vmin + a * d) - vmin) / a
	return 2.0 * (vmax - vmin) / a + (d - 2.0 * ramp) / vmax


## Where the tool is t seconds into the move a -> b.
static func move_pos(lim: Array, a: Vector3, b: Vector3, t: float) -> Vector3:
	var out := a
	for i in 3:
		var l: Array = lim[i]
		var d := b[i] - a[i]
		var p := axis_profile(d, float(l[0]), float(l[1]), float(l[2]))
		out[i] = a[i] + signf(d) * axis_pos(p, t)
	return out
