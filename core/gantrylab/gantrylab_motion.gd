class_name GantryLabMotion
extends RefCounted

## The motion planner every printer firmware carries, in its simplest honest
## form (the one Marlin calls "classic jerk" — Marlin planner.cpp, grbl
## planner.c): each move is a trapezoid of velocity, limited by the move's
## feed, the machine's max feed, each motor's step-rate cap along that
## direction, and the acceleration; at a corner the speed is capped so the
## instantaneous velocity change stays under the jerk setting
## (v_junction = jerk / |d₂ − d₁|), then a backward pass makes every move
## able to brake to its exit speed and a forward pass makes every move able
## to reach its entry speed. sample(t) gives the position, speed and segment
## at any time, so a job can be played, scrubbed and timed exactly.
##
## plan(parse, limits) → {ok, n, len, v_in, v_out, v_peak, t0, t_acc, t_cruise,
##   t_dec, total_s, peak_step_hz, peak_motor, max_feed_hit, accel_limited_share,
##   layers, extrusion_mm}
## limits = {max_feed_mm_s, accel_mm_s2, junction_mm_s, axis_caps: {x, y, z}
##           (tool mm/s each), motor_caps: PackedFloat32Array mm/s per motor,
##           spec (for motor_velocity), steps_per_mm: PackedFloat32Array}


static func plan(parse: Dictionary, limits: Dictionary) -> Dictionary:
	if not bool(parse.get("ok", false)):
		return {"ok": false, "total_s": 0.0, "n": 0}
	# Either form: an Array of move dicts (a G-code parse) or PrintMoves (a
	# slice). The plan keeps both: "moves" as handed in, "pm" packed.
	var moves: Variant = parse["moves"]
	var pm := PrintMoves.from_any(moves)
	var n := pm.size()
	var max_feed := maxf(float(limits.get("max_feed_mm_s", 150.0)), 0.1)
	var accel := maxf(float(limits.get("accel_mm_s2", 1000.0)), 1.0)
	var jerk := maxf(float(limits.get("junction_mm_s", 8.0)), 0.01)
	var caps: Dictionary = limits.get("axis_caps", {})
	var motor_caps: PackedFloat32Array = limits.get("motor_caps", PackedFloat32Array())
	var spm: PackedFloat32Array = limits.get("steps_per_mm", PackedFloat32Array())
	var spec: Dictionary = limits.get("spec", {})
	var len := PackedFloat32Array()
	var vmax := PackedFloat32Array()
	var dirs := PackedVector3Array()
	dirs.resize(n)
	var step_hz := PackedFloat32Array()
	var motor_of := PackedInt32Array()
	len.resize(n)
	vmax.resize(n)
	step_hz.resize(n)
	motor_of.resize(n)
	var feed_hit := 0
	var cap_x := float(caps.get("x", INF))
	var cap_y := float(caps.get("y", INF))
	var cap_z := float(caps.get("z", INF))
	var by_motor := not spec.is_empty()
	for i in n:
		var p0: Vector3 = pm.p0[i]
		var p1: Vector3 = pm.p1[i]
		var l := p0.distance_to(p1)
		len[i] = l
		var d := (p1 - p0) / l if l > 1e-9 else Vector3.ZERO
		dirs[i] = d
		var fd := float(pm.feed[i])
		var v := minf(fd, max_feed)
		if absf(fd - max_feed) < 1e-6 or fd > max_feed:
			feed_hit += 1
		# Per-axis tool-speed caps.
		if absf(d.x) > 1e-6 and is_finite(cap_x):
			v = minf(v, cap_x / absf(d.x))
		if absf(d.y) > 1e-6 and is_finite(cap_y):
			v = minf(v, cap_y / absf(d.y))
		if absf(d.z) > 1e-6 and is_finite(cap_z):
			v = minf(v, cap_z / absf(d.z))
		# Per-motor caps along this direction.
		var mv_fac := PackedFloat32Array()
		if by_motor and l > 1e-9:
			mv_fac = GantryLabKinematics.motor_velocity(spec, d, (p0 + p1) * 0.5)
			for m in mini(mv_fac.size(), motor_caps.size()):
				var f := float(mv_fac[m])
				if f > 1e-6:
					v = minf(v, float(motor_caps[m]) / f)
		vmax[i] = maxf(v, 0.1)
		# Step rate at that speed (for the peak readout).
		var best := 0.0
		var best_m := 0
		for m in mini(mv_fac.size(), spm.size()):
			var hz := vmax[i] * float(mv_fac[m]) * float(spm[m])
			if hz > best:
				best = hz
				best_m = m
		step_hz[i] = best
		motor_of[i] = best_m
	# Junction speeds: v_in[i] = min over the corner of the jerk rule.
	var v_in := PackedFloat32Array()
	var v_out := PackedFloat32Array()
	v_in.resize(n)
	v_out.resize(n)
	for i in n:
		v_in[i] = 0.0
		v_out[i] = 0.0
	for i in range(1, n):
		var d0 := dirs[i - 1]
		var d1 := dirs[i]
		var dv := (d1 - d0).length()
		var vj := INF if dv < 1e-6 else jerk / dv
		var v := minf(minf(vmax[i - 1], vmax[i]), vj)
		# A rapid into a cut (or back) stops like a corner would.
		v_out[i - 1] = v
		v_in[i] = v
	# Backward pass: can we brake from v_in to v_out over len?
	for i in range(n - 1, -1, -1):
		var allowed := sqrt(v_out[i] * v_out[i] + 2.0 * accel * len[i])
		if v_in[i] > allowed:
			v_in[i] = allowed
			if i > 0:
				v_out[i - 1] = allowed
	# Forward pass: can we reach v_out from v_in?
	for i in n:
		var allowed := sqrt(v_in[i] * v_in[i] + 2.0 * accel * len[i])
		if v_out[i] > allowed:
			v_out[i] = allowed
			if i + 1 < n:
				v_in[i + 1] = allowed
	# Profiles.
	var v_peak := PackedFloat32Array()
	var t_acc := PackedFloat32Array()
	var t_cruise := PackedFloat32Array()
	var t_dec := PackedFloat32Array()
	var t0 := PackedFloat32Array()
	v_peak.resize(n)
	t_acc.resize(n)
	t_cruise.resize(n)
	t_dec.resize(n)
	t0.resize(n)
	var t := 0.0
	var accel_limited := 0
	var peak_hz := 0.0
	var peak_motor := 0
	for i in n:
		t0[i] = t
		var l := len[i]
		var vi := v_in[i]
		var vo := v_out[i]
		var vm := vmax[i]
		# Peak speed reachable with accel then decel over l.
		var v_tri := sqrt(maxf((2.0 * accel * l + vi * vi + vo * vo) * 0.5, 0.0))
		var vp := minf(vm, v_tri)
		if vp < vm - 1e-6:
			accel_limited += 1
		vp = maxf(vp, maxf(vi, vo))
		var ta := maxf((vp - vi) / accel, 0.0)
		var td := maxf((vp - vo) / accel, 0.0)
		var da := (vp + vi) * 0.5 * ta
		var dd := (vp + vo) * 0.5 * td
		var dc := maxf(l - da - dd, 0.0)
		var tc := dc / maxf(vp, 1e-6)
		v_peak[i] = vp
		t_acc[i] = ta
		t_cruise[i] = tc
		t_dec[i] = td
		t += ta + tc + td
		var hz := step_hz[i] * (vp / maxf(vm, 1e-6))
		if hz > peak_hz:
			peak_hz = hz
			peak_motor = motor_of[i]
	return {
		"ok": true, "n": n, "len": len, "v_in": v_in, "v_out": v_out, "v_peak": v_peak,
		"t0": t0, "t_acc": t_acc, "t_cruise": t_cruise, "t_dec": t_dec, "total_s": t,
		"peak_step_hz": peak_hz, "peak_motor": peak_motor,
		"max_feed_hit_share": float(feed_hit) / maxf(float(n), 1.0),
		"accel_limited_share": float(accel_limited) / maxf(float(n), 1.0),
		"layers": int(parse.get("layers", 0)), "extrusion_mm": float(parse.get("extrusion_mm", 0.0)),
		"moves": moves, "pm": pm,
	}


## Where the tool is `t` seconds into the plan.
## → {i, s (0..1 along the move), pos, v, extruding, feed, rapid, line, t_in_move}
static func sample(pl: Dictionary, t: float) -> Dictionary:
	var n := int(pl.get("n", 0))
	if n == 0:
		return {"i": -1, "s": 0.0, "pos": Vector3.ZERO, "v": 0.0, "extruding": false, "feed": 0.0, "rapid": false, "line": 0}
	var t0: PackedFloat32Array = pl["t0"]
	if not pl.has("pm"):
		pl["pm"] = PrintMoves.from_any(pl.get("moves", []))
	var pm: PrintMoves = pl["pm"]
	t = clampf(t, 0.0, float(pl["total_s"]))
	# Binary search the move whose t0 <= t.
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if float(t0[mid]) <= t:
			lo = mid
		else:
			hi = mid - 1
	var i := lo
	var p0: Vector3 = pm.p0[i]
	var p1: Vector3 = pm.p1[i]
	var l := float((pl["len"] as PackedFloat32Array)[i])
	var tt := t - float(t0[i])
	var vi := float((pl["v_in"] as PackedFloat32Array)[i])
	var vp := float((pl["v_peak"] as PackedFloat32Array)[i])
	var vo := float((pl["v_out"] as PackedFloat32Array)[i])
	var ta := float((pl["t_acc"] as PackedFloat32Array)[i])
	var tc := float((pl["t_cruise"] as PackedFloat32Array)[i])
	var td := float((pl["t_dec"] as PackedFloat32Array)[i])
	var dist := 0.0
	var v := vp
	if tt <= ta and ta > 0.0:
		var a := (vp - vi) / ta
		dist = vi * tt + 0.5 * a * tt * tt
		v = vi + a * tt
	elif tt <= ta + tc:
		dist = (vi + vp) * 0.5 * ta + vp * (tt - ta)
		v = vp
	else:
		var tdd := clampf(tt - ta - tc, 0.0, td)
		var a := (vp - vo) / td if td > 0.0 else 0.0
		dist = (vi + vp) * 0.5 * ta + vp * tc + vp * tdd - 0.5 * a * tdd * tdd
		v = vp - a * tdd
	var s := clampf(dist / l, 0.0, 1.0) if l > 1e-9 else 1.0
	return {"i": i, "s": s, "pos": p0.lerp(p1, s), "v": v, "extruding": pm.e[i] > 0.0,
		"feed": float(pm.feed[i]), "rapid": pm.rapid[i] != 0, "line": int(pm.line[i]), "t_in_move": tt}


## The time (s) at which move i starts — the scrub bar's layer marks.
static func move_start_s(pl: Dictionary, i: int) -> float:
	var t0: PackedFloat32Array = pl.get("t0", PackedFloat32Array())
	if i < 0 or i >= t0.size():
		return 0.0
	return float(t0[i])


static func fmt_duration(s: float) -> String:
	if s < 60.0:
		return "%.1f s" % s
	if s < 3600.0:
		return "%d min %02d s" % [int(s / 60.0), int(fmod(s, 60.0))]
	return "%d h %02d min" % [int(s / 3600.0), int(fmod(s, 3600.0) / 60.0)]
