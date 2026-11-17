class_name NpcRowWork
extends RefCounted

## A crew working a field in a line (pure static). Transplanting, weeding and
## cutting a paddy are done by people standing side by side across it and
## moving down its length together; terrace excavation is a line working
## along the step. A chore that carries `row_spine` ([[x, z], …] down the
## middle of the plot) and `row_half_w` (m either side) puts worker k of n at
## its own place across the line, at the share of the length the chore's
## progress has reached. NpcAgent re-reads it while the work goes on, so the
## line moves down the plot as the job gets done.

## Never closer than this across the line (m): a transplanting crew stands
## about an arm's span apart.
const MIN_GAP_M := 0.9


## The spine's length (m).
static func spine_length(spine: Array) -> float:
	var l := 0.0
	for i in range(1, spine.size()):
		l += _pt(spine[i]).distance_to(_pt(spine[i - 1]))
	return l


## {pos, dir} at a share u (0..1) of the way along the spine.
static func along(spine: Array, u: float) -> Dictionary:
	if spine.is_empty():
		return {"pos": Vector2.ZERO, "dir": Vector2(1, 0)}
	if spine.size() == 1:
		return {"pos": _pt(spine[0]), "dir": Vector2(1, 0)}
	var total := spine_length(spine)
	var want := clampf(u, 0.0, 1.0) * total
	for i in range(1, spine.size()):
		var a := _pt(spine[i - 1])
		var b := _pt(spine[i])
		var seg := a.distance_to(b)
		if want <= seg or i == spine.size() - 1:
			var d := (b - a).normalized() if seg > 1e-6 else Vector2(1, 0)
			return {"pos": a.lerp(b, clampf(want / maxf(seg, 1e-6), 0.0, 1.0)), "dir": d}
		want -= seg
	return {"pos": _pt(spine[spine.size() - 1]), "dir": Vector2(1, 0)}


## Worker k of n: where they stand when the job is p done. The crew spreads
## across the plot's width (no wider than MIN_GAP_M apart allows) and moves
## down the length; a crew wider than the plot doubles up into a second line
## a metre and a half behind.
static func slot(spine: Array, half_w: float, k: int, n: int, p: float) -> Vector2:
	var n_eff := maxi(n, 1)
	var a := along(spine, p)
	var across := Vector2(-(a["dir"] as Vector2).y, (a["dir"] as Vector2).x)
	var width := maxf(half_w * 2.0 - 0.6, 0.0)
	var per_line := maxi(1, mini(n_eff, int(floor(width / MIN_GAP_M)) + 1))
	var line := k / per_line
	var idx := k % per_line
	var off := 0.0
	if per_line > 1:
		off = (float(idx) / float(per_line - 1) - 0.5) * width
	var back := float(line) * 1.5
	return (a["pos"] as Vector2) + across * off - (a["dir"] as Vector2) * back


## The point a worker faces: a step further down the line.
static func facing(spine: Array, p: float) -> Vector2:
	var a := along(spine, p)
	return (a["pos"] as Vector2) + (a["dir"] as Vector2) * 3.0


static func _pt(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO
