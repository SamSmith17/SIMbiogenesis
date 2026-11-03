class_name CspLabCpc
extends RefCounted

## Compound parabolic concentrators (CPCs): the trough shapes that send
## every ray arriving within ±θa of the axis onto an absorber of real size —
## a round tube or a flat strip — instead of onto a focal line. The ideal
## (full) CPC reaches the 2D concentration limit C = 1/sin θa, and it takes
## light from the whole ±θa fan at once, so it works with little or no
## tracking and catches part of a cloudy sky.
##
## This is the math behind the string-and-speed-square drawing
## (NightHawkInLight, "compound parabolic mirror"): two lines crossing at the
## target set the acceptance angle 2θa; a string tied to the target and held
## parallel to the square traces the wall. While the string unwraps off a
## round target the pen draws an INVOLUTE of the circle; once the square
## starts to move it draws a PARABOLA. The two meet with a common tangent,
## and the two halves meet in a cusp under the tube — the "W".
##
## Tube CPC (Rabl 1976, "Solar concentrators with maximal concentration for
## cylindrical absorbers", Appl. Opt. 15(7); Winston, Miñano & Benítez 2005
## §4.6). Absorber radius r, contact angle θ round the tube measured from
## its bottom, ρ(θ) = the length of string from the tangent point to the
## mirror:
##   involute   |θ| ≤ θa + π/2:            ρ = r·θ
##   parabola   θa + π/2 ≤ θ ≤ 3π/2 − θa:   ρ = r·(θ + θa + π/2 − cos(θ − θa)) / (1 + sin(θ − θa))
## and the mirror point is the tangent point T = r·(sin θ, −cos θ) minus ρ
## along the tangent (cos θ, sin θ). The full aperture is 2πr / sin θa.
##
## Flat CPC (Welford & Winston 1989, "High Collection Nonimaging Optics",
## ch. 4): absorber half-width a; the right wall is a parabola whose focus
## is the LEFT absorber edge and whose axis is tilted θa, focal length
## f = a·(1 + sin θa), from the right absorber edge up to where its tangent
## is parallel to the axis; aperture half-width a / sin θa.
##
## Frames: x across the trough, y up the CPC axis, the cusp (tube) or the
## absorber (flat) at y = 0. Truncation cuts the top off: a full CPC is very
## tall for its last few percent of concentration.

const SAMPLES := 120


## The right half of a tube CPC around a circle of radius `r` (the mirror is
## drawn round this circle — the absorber plus any gap), half acceptance
## `theta_a` (rad), `trunc` = the share of the full height cut off.
## Returns {right, left, normals_r, normals_l, aperture_half, height,
## aperture_half_full, height_full, centre_y, arc_len}.
static func tube_profile(r: float, theta_a: float, trunc: float = 0.0, n: int = SAMPLES) -> Dictionary:
	var ta := clampf(theta_a, deg_to_rad(1.0), deg_to_rad(89.0))
	var t_end := 1.5 * PI - ta
	var pts := PackedVector2Array()
	for i in n + 1:
		var th := t_end * float(i) / float(n)
		pts.append(tube_point(r, ta, th) + Vector2(0, r))
	return _finish(pts, trunc, r)


## One mirror point of the tube CPC at contact angle θ (tube centre at the
## origin, so the cusp is at (0, −r)).
static func tube_point(r: float, theta_a: float, th: float) -> Vector2:
	var rho := 0.0
	if th <= theta_a + PI * 0.5:
		rho = r * th
	else:
		rho = r * (th + theta_a + PI * 0.5 - cos(th - theta_a)) / (1.0 + sin(th - theta_a))
	var tp := Vector2(r * sin(th), -r * cos(th))
	return tp - Vector2(cos(th), sin(th)) * rho


## The string's free length at contact angle θ (what the drawing's string
## holds between the target and the pen).
static func tube_rho(r: float, theta_a: float, th: float) -> float:
	if th <= theta_a + PI * 0.5:
		return r * th
	return r * (th + theta_a + PI * 0.5 - cos(th - theta_a)) / (1.0 + sin(th - theta_a))


## The right half of a flat-absorber CPC (absorber half-width `a`).
static func flat_profile(a: float, theta_a: float, trunc: float = 0.0, n: int = SAMPLES) -> Dictionary:
	var ta := clampf(theta_a, deg_to_rad(1.0), deg_to_rad(89.0))
	var s := sin(ta)
	var c := cos(ta)
	var f := a * (1.0 + s)
	var u := Vector2(-s, c)
	var xh := Vector2(c, s)
	var fpt := Vector2(-a, 0.0)
	var v := fpt - u * f
	var x0 := 2.0 * a * c
	var x1 := 2.0 * f * c / s
	var pts := PackedVector2Array()
	for i in n + 1:
		var xp := lerpf(x0, x1, float(i) / float(n))
		pts.append(v + xh * xp + u * (xp * xp / (4.0 * f)))
	return _finish(pts, trunc, 0.0)


## Truncate, mirror, measure.
static func _finish(full: PackedVector2Array, trunc: float, centre_y: float) -> Dictionary:
	var y_min := INF
	var i_min := 0
	for i in full.size():
		if full[i].y < y_min:
			y_min = full[i].y
			i_min = i
	var top_full := full[full.size() - 1]
	var y_cut := lerpf(top_full.y, maxf(full[0].y, y_min), clampf(trunc, 0.0, 0.95))
	var pts := PackedVector2Array()
	for i in full.size():
		var p := full[i]
		if i > i_min and p.y >= y_cut and i > 0:
			var q := full[i - 1]
			var k := (y_cut - q.y) / maxf(p.y - q.y, 1e-12)
			pts.append(q.lerp(p, clampf(k, 0.0, 1.0)))
			break
		pts.append(p)
	# Inward normals: the left of the direction of travel on the right half.
	var nr := PackedVector2Array()
	for i in pts.size():
		var a := pts[maxi(i - 1, 0)]
		var b := pts[mini(i + 1, pts.size() - 1)]
		var t := (b - a).normalized()
		nr.append(Vector2(-t.y, t.x))
	var left := PackedVector2Array()
	var nl := PackedVector2Array()
	for i in pts.size():
		left.append(Vector2(-pts[i].x, pts[i].y))
		nl.append(Vector2(-nr[i].x, nr[i].y))
	var arc := 0.0
	for i in range(1, pts.size()):
		arc += pts[i].distance_to(pts[i - 1])
	return {"right": pts, "left": left, "normals_r": nr, "normals_l": nl,
		"aperture_half": pts[pts.size() - 1].x, "height": pts[pts.size() - 1].y - minf(y_min, 0.0),
		"top_y": pts[pts.size() - 1].y, "bottom_y": minf(y_min, 0.0),
		"aperture_half_full": top_full.x, "height_full": top_full.y - minf(y_min, 0.0),
		"centre_y": centre_y, "arc_len": arc * 2.0}


## The mirror as 2D segments for ray intersection: {a, b, n (inward), boxes}
## — boxes are 2D bounds of runs of 12 segments, tested first.
static func segments(prof: Dictionary) -> Dictionary:
	var a := PackedVector2Array()
	var b := PackedVector2Array()
	var nn := PackedVector2Array()
	for side in [["right", "normals_r"], ["left", "normals_l"]]:
		var pts: PackedVector2Array = prof[str(side[0])]
		var ns: PackedVector2Array = prof[str(side[1])]
		for i in range(1, pts.size()):
			a.append(pts[i - 1])
			b.append(pts[i])
			nn.append(((ns[i - 1] + ns[i]) * 0.5).normalized())
	var boxes: Array = []
	var run := 12
	var k := 0
	while k < a.size():
		var hi := mini(k + run, a.size())
		var lo2 := Vector2(INF, INF)
		var hi2 := Vector2(-INF, -INF)
		for j in range(k, hi):
			lo2 = lo2.min(a[j]).min(b[j])
			hi2 = hi2.max(a[j]).max(b[j])
		boxes.append([lo2 - Vector2(1e-5, 1e-5), hi2 + Vector2(1e-5, 1e-5), k, hi])
		k = hi
	return {"a": a, "b": b, "n": nn, "boxes": boxes}


## The nearest mirror hit along the ray (origin `o`, direction `d`, 2D
## components of a 3D ray: t is in 3D units). Returns Vector2(t, index),
## t < 0 when nothing is hit.
static func hit(segs: Dictionary, o: Vector2, d: Vector2) -> Vector2:
	var a: PackedVector2Array = segs["a"]
	var b: PackedVector2Array = segs["b"]
	var best := -1.0
	var best_i := -1
	for bx in (segs["boxes"] as Array):
		var box: Array = bx
		if not _ray_box(o, d, box[0] as Vector2, box[1] as Vector2, best):
			continue
		for j in range(int(box[2]), int(box[3])):
			var e := b[j] - a[j]
			var den := d.x * e.y - d.y * e.x
			if absf(den) < 1e-14:
				continue
			var w := a[j] - o
			var t := (w.x * e.y - w.y * e.x) / den
			if t <= 1e-7 or (best > 0.0 and t >= best):
				continue
			var u := (w.x * d.y - w.y * d.x) / den
			if u < -1e-9 or u > 1.0 + 1e-9:
				continue
			best = t
			best_i = j
	return Vector2(best, best_i)


static func _ray_box(o: Vector2, d: Vector2, lo: Vector2, hi: Vector2, t_max: float) -> bool:
	var t0 := 0.0
	var t1 := INF if t_max <= 0.0 else t_max
	for ax in 2:
		var oo := o.x if ax == 0 else o.y
		var dd := d.x if ax == 0 else d.y
		var l := lo.x if ax == 0 else lo.y
		var h := hi.x if ax == 0 else hi.y
		if absf(dd) < 1e-14:
			if oo < l or oo > h:
				return false
			continue
		var ta := (l - oo) / dd
		var tb := (h - oo) / dd
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return false
	return true


## A 1:1 SVG template of a trough profile (both halves, the absorber, the
## acceptance lines through it, a 10 cm scale bar) — print it, cut it out and
## trace it onto the ribs, as the string drawing is used.
static func svg_template(prof_right: PackedVector2Array, absorber: Dictionary, theta_a: float, title: String) -> String:
	var pts: Array = []
	for p in prof_right:
		pts.append(p)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in prof_right:
		lo = lo.min(Vector2(-p.x, p.y)).min(p)
		hi = hi.max(Vector2(-p.x, p.y)).max(p)
	var pad := 0.03
	lo -= Vector2(pad, pad + 0.05)
	hi += Vector2(pad, pad)
	var w := (hi.x - lo.x) * 1000.0
	var h := (hi.y - lo.y) * 1000.0
	var sb := PackedStringArray()
	sb.append('<?xml version="1.0" encoding="UTF-8"?>')
	sb.append('<svg xmlns="http://www.w3.org/2000/svg" width="%.2fmm" height="%.2fmm" viewBox="0 0 %.3f %.3f">' % [w, h, w, h])
	sb.append('<title>%s</title>' % title.xml_escape())
	var path := PackedStringArray()
	var all := PackedVector2Array()
	for i in range(prof_right.size() - 1, -1, -1):
		all.append(Vector2(-prof_right[i].x, prof_right[i].y))
	for p in prof_right:
		all.append(p)
	for i in all.size():
		var q := _svg_pt(all[i], lo, hi)
		path.append(("M" if i == 0 else "L") + "%.3f %.3f" % [q.x, q.y])
	sb.append('<path d="%s" fill="none" stroke="#000" stroke-width="0.5"/>' % " ".join(path))
	var kind := str(absorber.get("kind", "tube"))
	if kind == "tube":
		var c := _svg_pt(Vector2(0, float(absorber["y"])), lo, hi)
		sb.append('<circle cx="%.3f" cy="%.3f" r="%.3f" fill="none" stroke="#c00" stroke-width="0.4"/>' % [c.x, c.y, float(absorber["r"]) * 1000.0])
		if float(absorber.get("r_mirror", 0.0)) > float(absorber["r"]) + 1e-6:
			sb.append('<circle cx="%.3f" cy="%.3f" r="%.3f" fill="none" stroke="#c00" stroke-width="0.2" stroke-dasharray="1 1"/>' % [c.x, c.y, float(absorber["r_mirror"]) * 1000.0])
	elif kind == "flat":
		var a0 := _svg_pt(Vector2(-float(absorber["a"]), 0), lo, hi)
		var a1 := _svg_pt(Vector2(float(absorber["a"]), 0), lo, hi)
		sb.append('<line x1="%.3f" y1="%.3f" x2="%.3f" y2="%.3f" stroke="#c00" stroke-width="0.8"/>' % [a0.x, a0.y, a1.x, a1.y])
	if theta_a > 0.0:
		var o := _svg_pt(Vector2(0, float(absorber.get("y", 0.0))), lo, hi)
		var reach := (hi.y - lo.y) * 1000.0
		for sgn in [-1.0, 1.0]:
			var e := o + Vector2(sin(theta_a) * float(sgn), -cos(theta_a)) * reach
			sb.append('<line x1="%.3f" y1="%.3f" x2="%.3f" y2="%.3f" stroke="#06c" stroke-width="0.2" stroke-dasharray="3 2"/>' % [o.x, o.y, e.x, e.y])
	var b0 := Vector2(10.0, h - 10.0)
	sb.append('<line x1="%.3f" y1="%.3f" x2="%.3f" y2="%.3f" stroke="#000" stroke-width="0.8"/>' % [b0.x, b0.y, b0.x + 100.0, b0.y])
	sb.append('<text x="%.3f" y="%.3f" font-size="4" font-family="sans-serif">100 mm — print at 100 %%. %s</text>' % [b0.x, b0.y - 2.0, title.xml_escape()])
	sb.append('</svg>')
	return "\n".join(sb)


static func _svg_pt(p: Vector2, lo: Vector2, hi: Vector2) -> Vector2:
	return Vector2((p.x - lo.x) * 1000.0, (hi.y - p.y) * 1000.0)
