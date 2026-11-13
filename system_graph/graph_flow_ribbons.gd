class_name GraphFlowRibbons
extends RefCounted

## Draws a flow wire as a RIBBON: one triangle array per wire (a soft glow
## strip under a three-lane body), coloured per vertex. The flow pattern
## (streaks, comets, beads, a pulse) is evaluated per sample on the CPU from
## GraphFlowStyle.pattern, so there is no shader, no texture and no second
## canvas item: the ribbon lands in the canvas's own draw order exactly where
## the old strokes did. It replaces 4 polylines + 2–6 arrows + chase dots per
## wire, and the pattern clock is continuous seconds, so nothing jumps.
##
## Pure geometry in, RenderingServer calls out. `build` returns the arrays so
## the selftest can check widths and pattern motion without a renderer.

## Arc-length spacing of samples along the ribbon (screen px). The pattern
## is interpolated between samples, so this is its resolution.
const STEP_PX := 6.0
const STEP_PX_FAR := 14.0
const MAX_SAMPLES := 220
## Joint miter cap (× half width) so a sharp corner never spikes.
const MITER_LIMIT := 2.2


## Resample a polyline at roughly `step` px. Returns
## {pts: PackedVector2Array, s: PackedFloat32Array (arc length)}.
static func resample(src: PackedVector2Array, step: float) -> Dictionary:
	var pts := PackedVector2Array()
	var arc := PackedFloat32Array()
	if src.size() < 2:
		return {"pts": pts, "s": arc}
	var total := 0.0
	for i in src.size() - 1:
		total += src[i].distance_to(src[i + 1])
	if total < 0.5:
		return {"pts": pts, "s": arc}
	var n := clampi(int(ceil(total / maxf(step, 1.0))) + 1, 2, MAX_SAMPLES)
	var seg := total / float(n - 1)
	pts.append(src[0])
	arc.append(0.0)
	var target := seg
	var acc := 0.0
	var i := 0
	while i < src.size() - 1 and pts.size() < n - 1:
		var a := src[i]
		var b := src[i + 1]
		var l := a.distance_to(b)
		if acc + l >= target and l > 0.0:
			var u := (target - acc) / l
			pts.append(a.lerp(b, u))
			arc.append(target)
			target += seg
			continue
		acc += l
		i += 1
	pts.append(src[src.size() - 1])
	arc.append(total)
	return {"pts": pts, "s": arc}


## Unit normals at each sample (left side of travel), averaged at joints and
## scaled for the miter so the ribbon keeps its width round a bend.
static func normals(pts: PackedVector2Array) -> PackedVector2Array:
	var n := pts.size()
	var out := PackedVector2Array()
	out.resize(n)
	if n < 2:
		return out
	for i in n:
		var d_in := Vector2.ZERO
		var d_out := Vector2.ZERO
		if i > 0:
			d_in = (pts[i] - pts[i - 1]).normalized()
		if i < n - 1:
			d_out = (pts[i + 1] - pts[i]).normalized()
		var d := d_in + d_out
		if d.length_squared() < 1e-6:
			d = d_out if d_out != Vector2.ZERO else d_in
		d = d.normalized()
		var nrm := Vector2(-d.y, d.x)
		var ref := d_out if d_out != Vector2.ZERO else d_in
		var ref_n := Vector2(-ref.y, ref.x)
		var cosv := absf(nrm.dot(ref_n))
		var scale := 1.0 / maxf(cosv, 1.0 / MITER_LIMIT)
		out[i] = nrm * scale
	return out


## Build the arrays for one ribbon. `o` keys:
##   width (px), color, color_end (gradient, optional), active (bool),
##   anim, t (pattern clock s), speed (px/s), reverse, blur, glow (0..1),
##   intensity (0..1, how much the pattern brightens), far (bool: coarser),
##   alpha (whole-ribbon multiplier, for dimming).
## Returns {idx, pts, cols} or {} when the path is too short.
static func build(path: PackedVector2Array, o: Dictionary) -> Dictionary:
	var step := STEP_PX_FAR if bool(o.get("far", false)) else STEP_PX
	var rs := resample(path, step)
	var pts: PackedVector2Array = rs["pts"]
	var arc: PackedFloat32Array = rs["s"]
	var n := pts.size()
	if n < 2:
		return {}
	var nrm := normals(pts)
	var w := maxf(1.0, float(o.get("width", 4.0)))
	var half := w * 0.5
	var c0: Color = o.get("color", Color.WHITE)
	var c1: Color = o.get("color_end", c0)
	var active := bool(o.get("active", false))
	var anim := str(o.get("anim", GraphFlowStyle.ANIM_STREAKS))
	var t := float(o.get("t", 0.0))
	var speed := float(o.get("speed", 0.0)) if active else 0.0
	var rev := bool(o.get("reverse", false))
	var blur := bool(o.get("blur", false))
	var glow := clampf(float(o.get("glow", 0.6)), 0.0, 1.0) if active else 0.0
	var inten := clampf(float(o.get("intensity", 0.6)), 0.0, 1.0)
	var alpha := clampf(float(o.get("alpha", 1.0)), 0.0, 1.0)
	var total := float(arc[n - 1])
	var use_glow := glow > 0.02 and w >= 2.5
	var lanes := 3
	var per := lanes * (2 if use_glow else 1)
	var vp := PackedVector2Array()
	vp.resize(n * per)
	var vc := PackedColorArray()
	vc.resize(n * per)
	var glow_w := half * (1.55 + 0.9 * glow) + 2.0
	for i in n:
		var p := pts[i]
		var nn := nrm[i]
		var u := float(arc[i]) / maxf(total, 0.001)
		var base := c0.lerp(c1, u)
		var pat := 0.0
		if active and anim != GraphFlowStyle.ANIM_NONE:
			pat = GraphFlowStyle.pattern(anim, float(arc[i]), t, speed, rev, blur)
		var lift := (0.10 if active else 0.0) + 0.55 * inten * pat
		var core := Color(
			lerpf(base.r, 1.0, lift), lerpf(base.g, 1.0, lift * 0.92),
			lerpf(base.b, 1.0, lift * 0.85),
			clampf((base.a * (0.92 if active else 0.62)) * alpha, 0.0, 1.0))
		var edge := Color(base.r * 0.55, base.g * 0.55, base.b * 0.58,
			clampf(base.a * (0.80 if active else 0.45) * alpha, 0.0, 1.0))
		var o0 := i * lanes
		if use_glow:
			var g_a := (0.10 + 0.16 * glow) * (0.75 + 0.5 * pat) * alpha * base.a
			var gc := Color(base.r, base.g, base.b, clampf(g_a, 0.0, 0.6))
			var ge := Color(base.r, base.g, base.b, 0.0)
			vp[o0] = p + nn * glow_w
			vp[o0 + 1] = p
			vp[o0 + 2] = p - nn * glow_w
			vc[o0] = ge
			vc[o0 + 1] = gc
			vc[o0 + 2] = ge
			o0 += n * lanes
		vp[o0] = p + nn * half
		vp[o0 + 1] = p
		vp[o0 + 2] = p - nn * half
		vc[o0] = edge
		vc[o0 + 1] = core
		vc[o0 + 2] = edge
	var idx := PackedInt32Array()
	var strips := 2 if use_glow else 1
	for sidx in strips:
		var off := sidx * n * lanes
		for i in n - 1:
			var a := off + i * lanes
			var b := a + lanes
			idx.append_array([a, b, a + 1, a + 1, b, b + 1,
				a + 1, b + 1, a + 2, a + 2, b + 1, b + 2])
	return {"idx": idx, "pts": vp, "cols": vc, "samples": n, "length": total}


## Draw one ribbon into a canvas item.
static func draw(ci: RID, path: PackedVector2Array, o: Dictionary) -> void:
	var r := build(path, o)
	if r.is_empty():
		return
	RenderingServer.canvas_item_add_triangle_array(ci, r["idx"], r["pts"], r["cols"])
