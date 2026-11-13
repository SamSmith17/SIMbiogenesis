class_name GraphFlowRibbons
extends RefCounted

## Draws a flow wire as a RIBBON: one triangle array per wire, coloured per
## vertex, in the canvas's own draw order (no shader, no second canvas item,
## so it stays under the cards exactly where the old strokes were).
##
## Cross-section, outside in: a soft glow strip (fades to nothing), the rim
## (darkened edge), the body (the flow's colour) and a white-hot core line
## down the middle. The flow pattern (GraphFlowStyle.pattern: streaks,
## comets, beads, a pulse) brightens the core and the body and swells the
## width a little at each streak; the pattern clock is continuous seconds,
## so nothing jumps. Every proportion comes from the style's LOOK keys
## (GraphFlowStyle.look): glow, glow width, core, core width, rim, swell,
## taper, saturation, brightness, colour mode, idle opacity.
##
## Geometry (resampled points, arc lengths, miter normals) is cached by the
## caller per wire (`o.geo`, from `geometry`): an animation frame only
## recolours. `build` returns the arrays so the selftest can check widths and
## pattern motion without a renderer.

## Arc-length spacing of samples along the ribbon (screen px). The pattern
## is interpolated between samples, so this is its resolution.
const STEP_PX := 5.0
const STEP_PX_FAR := 12.0
const MAX_SAMPLES := 260
## Joint miter cap (× half width) so a sharp corner never spikes.
const MITER_LIMIT := 2.2
## Vertices across one sample: glow (3) + body (5).
const BODY_LANES := 5
const GLOW_LANES := 3


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


## The part of a ribbon that only depends on its path: {pts, s, nrm, total}.
## Callers keep it per wire while the path does not move (`geo_key`).
static func geometry(path: PackedVector2Array, step: float) -> Dictionary:
	var rs := resample(path, step)
	var pts: PackedVector2Array = rs["pts"]
	if pts.size() < 2:
		return {}
	var arc: PackedFloat32Array = rs["s"]
	return {"pts": pts, "s": arc, "nrm": normals(pts), "total": float(arc[arc.size() - 1])}


## A cheap key for a path: its ends, middle and length in points (a wire
## whose path moves gets a new key; one that only animates keeps it).
static func geo_key(path: PackedVector2Array, step: float) -> Vector4:
	if path.is_empty():
		return Vector4.ZERO
	var a := path[0]
	var b := path[path.size() - 1]
	var m := path[path.size() / 2]
	return Vector4(a.x + b.y * 3.1 + step * 0.01, a.y + b.x * 1.7, m.x + float(path.size()) * 0.37, m.y)


## Saturation and brightness of a colour (the style's look).
static func grade(c: Color, sat: float, bright: float) -> Color:
	var l := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
	var out := Color(lerpf(l, c.r, sat), lerpf(l, c.g, sat), lerpf(l, c.b, sat), c.a)
	return Color(clampf(out.r * bright, 0.0, 1.0), clampf(out.g * bright, 0.0, 1.0),
		clampf(out.b * bright, 0.0, 1.0), c.a)


## The heat ramp (deep ember → orange → yellow → white) at 0..1.
static func heat_color(t: float, a: float = 1.0) -> Color:
	var stops := [Color(0.45, 0.06, 0.04), Color(0.92, 0.32, 0.06), Color(1.0, 0.74, 0.18), Color(1.0, 0.97, 0.86)]
	var f := clampf(t, 0.0, 1.0) * 3.0
	var i := mini(int(floor(f)), 2)
	var c: Color = (stops[i] as Color).lerp(stops[i + 1] as Color, f - float(i))
	c.a = a
	return c


## Build the arrays for one ribbon. `o` keys:
##   width (px), color, color_end (gradient end, optional), active (bool),
##   anim, t (pattern clock s), speed (px/s), reverse, blur, intensity (0..1,
##   how hard the pattern brightens), far (coarser), alpha (dimming),
##   look (GraphFlowStyle.look: glow, glow_w, core, core_w, rim, swell, taper,
##   sat, bright, colour, idle_alpha, period, duty), heat (0..1, the flow's
##   share of its scale, for the heat colour), geo (cached `geometry`),
##   glow (legacy: overrides look.glow).
## Returns {idx, pts, cols, samples, length} or {} when the path is too short.
static func build(path: PackedVector2Array, o: Dictionary) -> Dictionary:
	var lk: Dictionary = o.get("look", {}) as Dictionary
	var step := STEP_PX_FAR if bool(o.get("far", false)) else STEP_PX
	var geo: Dictionary = o.get("geo", {}) as Dictionary
	if geo.is_empty():
		geo = geometry(path, step)
	if geo.is_empty():
		return {}
	var pts: PackedVector2Array = geo["pts"]
	var arc: PackedFloat32Array = geo["s"]
	var nrm: PackedVector2Array = geo["nrm"]
	var total := float(geo["total"])
	var n := pts.size()
	var w := maxf(1.0, float(o.get("width", 4.0)))
	var half := w * 0.5
	var active := bool(o.get("active", false))
	var sat := float(lk.get("sat", 1.0))
	var bright := float(lk.get("bright", 1.0))
	var mode := str(lk.get("colour", "gradient"))
	var c0: Color = grade(o.get("color", Color.WHITE), sat, bright)
	var c1: Color = grade(o.get("color_end", o.get("color", Color.WHITE)), sat, bright)
	if mode == "heat":
		var ht := float(o.get("heat", 0.6))
		c0 = heat_color(ht * 0.8, c0.a)
		c1 = heat_color(minf(ht * 0.8 + 0.25, 1.0), c0.a)
	elif mode == "mono":
		var ac: Color = lk.get("accent", Color(0.55, 0.85, 1.0))
		c0 = Color(ac, c0.a)
		c1 = c0
	elif mode == "kind":
		c1 = c0
	var anim := str(o.get("anim", GraphFlowStyle.ANIM_STREAKS))
	var t := float(o.get("t", 0.0))
	var speed := float(o.get("speed", 0.0)) if active else 0.0
	var rev := bool(o.get("reverse", false))
	var blur := bool(o.get("blur", false))
	var glow := clampf(float(o.get("glow", lk.get("glow", 0.6))), 0.0, 1.0) if active else 0.0
	var inten := clampf(float(o.get("intensity", 0.6)), 0.0, 1.0)
	var alpha := clampf(float(o.get("alpha", 1.0)), 0.0, 1.0)
	if not active:
		alpha *= clampf(float(lk.get("idle_alpha", 0.65)), 0.0, 1.0)
	var core_k := clampf(float(lk.get("core", 0.35)), 0.0, 1.0)
	var core_w := clampf(float(lk.get("core_w", 0.3)), 0.05, 0.9)
	var rim := clampf(float(lk.get("rim", 0.45)), 0.0, 1.0)
	var swell := clampf(float(lk.get("swell", 0.15)), 0.0, 1.0) if active else 0.0
	var taper := clampf(float(lk.get("taper", 0.0)), 0.0, 1.0)
	var glow_k := clampf(float(lk.get("glow_w", 1.6)), 0.3, 5.0)
	var period := float(lk.get("period", 1.0))
	var duty := float(lk.get("duty", 0.5))
	var aurora := mode == "aurora"
	var use_glow := glow > 0.02 and w >= 2.0
	var per := BODY_LANES + (GLOW_LANES if use_glow else 0)
	var vp := PackedVector2Array()
	vp.resize(n * per)
	var vc := PackedColorArray()
	vc.resize(n * per)
	var body0 := n * GLOW_LANES if use_glow else 0
	var lift0 := 0.10 if active else 0.0
	var do_pat := active and anim != GraphFlowStyle.ANIM_NONE
	var inv_total := 1.0 / maxf(total, 0.001)
	for i in n:
		var p := pts[i]
		var nn := nrm[i]
		var s_px := float(arc[i])
		var u := s_px * inv_total
		var base := c0.lerp(c1, u)
		if aurora:
			# A slow hue shimmer travelling along the ribbon.
			var hs := 0.05 * sin(s_px * 0.018 - t * 1.3) + 0.03 * sin(s_px * 0.047 + t * 0.7)
			base = Color.from_hsv(fposmod(base.h + hs, 1.0), minf(base.s * 1.1, 1.0), base.v, base.a)
		var pat := 0.0
		if do_pat:
			pat = GraphFlowStyle.pattern_ex(anim, s_px, t, speed, rev, blur, period, duty)
		var hw := half * (1.0 + swell * pat * 0.6)
		if taper > 0.0:
			var e := clampf(minf(u, 1.0 - u) * total / maxf(w * 2.5, 12.0), 0.0, 1.0)
			hw *= lerpf(1.0 - taper * 0.85, 1.0, e * e * (3.0 - 2.0 * e))
		var lift := lift0 + 0.55 * inten * pat
		var body := Color(lerpf(base.r, 1.0, lift * 0.45), lerpf(base.g, 1.0, lift * 0.42),
			lerpf(base.b, 1.0, lift * 0.38), clampf(base.a * (0.94 if active else 0.7) * alpha, 0.0, 1.0))
		var ck := clampf(core_k * (0.55 + 0.9 * pat) + lift * 0.5, 0.0, 1.0) if active else core_k * 0.25
		var core := Color(lerpf(base.r, 1.0, ck), lerpf(base.g, 1.0, ck * 0.95),
			lerpf(base.b, 1.0, ck * 0.9), clampf(base.a * alpha, 0.0, 1.0))
		var dk := 1.0 - rim * 0.6
		var edge := Color(base.r * dk, base.g * dk, base.b * (dk + rim * 0.05),
			clampf(base.a * (0.85 - rim * 0.35) * (1.0 if active else 0.7) * alpha, 0.0, 1.0))
		if use_glow:
			var g0 := i * GLOW_LANES
			var gw := hw * glow_k + 2.0
			var g_a := (0.08 + 0.2 * glow) * (0.7 + 0.6 * pat) * alpha * base.a
			vp[g0] = p + nn * gw
			vp[g0 + 1] = p
			vp[g0 + 2] = p - nn * gw
			vc[g0] = Color(base.r, base.g, base.b, 0.0)
			vc[g0 + 1] = Color(base.r, base.g, base.b, clampf(g_a, 0.0, 0.7))
			vc[g0 + 2] = vc[g0]
		var b0 := body0 + i * BODY_LANES
		var cw := hw * core_w
		vp[b0] = p + nn * hw
		vp[b0 + 1] = p + nn * cw
		vp[b0 + 2] = p
		vp[b0 + 3] = p - nn * cw
		vp[b0 + 4] = p - nn * hw
		vc[b0] = edge
		vc[b0 + 1] = body
		vc[b0 + 2] = core
		vc[b0 + 3] = body
		vc[b0 + 4] = edge
	var idx := PackedInt32Array()
	if use_glow:
		_strip(idx, 0, n, GLOW_LANES)
	_strip(idx, body0, n, BODY_LANES)
	return {"idx": idx, "pts": vp, "cols": vc, "samples": n, "length": total}


## Triangles for a strip of `lanes` vertices across, `n` samples long.
static func _strip(idx: PackedInt32Array, off: int, n: int, lanes: int) -> void:
	var base := idx.size()
	idx.resize(base + (n - 1) * (lanes - 1) * 6)
	var k := base
	for i in n - 1:
		var a := off + i * lanes
		var b := a + lanes
		for l in lanes - 1:
			idx[k] = a + l
			idx[k + 1] = b + l
			idx[k + 2] = a + l + 1
			idx[k + 3] = a + l + 1
			idx[k + 4] = b + l
			idx[k + 5] = b + l + 1
			k += 6


## Draw one ribbon into a canvas item.
static func draw(ci: RID, path: PackedVector2Array, o: Dictionary) -> void:
	var r := build(path, o)
	if r.is_empty():
		return
	RenderingServer.canvas_item_add_triangle_array(ci, r["idx"], r["pts"], r["cols"])
