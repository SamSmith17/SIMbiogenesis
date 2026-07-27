class_name MudWallSlicer
extends RefCounted

## Mud wall path generator (Phase D): dual perimeters with camber, sine/gyroid
## fill, open wall runs, doorway gaps with lintels, multi-island order.
## Machine mm: X/Y bed, Z up.


static func slice(spec: MudBuildingSpec, opts: Dictionary = {}) -> Dictionary:
	var val := MudPlanOps.validate_spec(spec)
	if not bool(val.get("ok", false)):
		return {"ok": false, "error": str(val.get("error", "invalid plan"))}
	var loops: Array = val.get("loops", [])
	var open_paths: Array = val.get("open_paths", [])
	var layer_h := maxf(spec.layer_height_mm, 5.0)
	var height := maxf(spec.height_mm, layer_h)
	var line_w := maxf(spec.line_width_mm, spec.nozzle_mm * 0.5)
	var speed := maxf(spec.print_speed_mm_s, 10.0)
	var layer_count := maxi(int(ceil(height / layer_h)), 1)
	var fill_mode := spec.fill_mode
	if not spec.fill_enabled:
		fill_mode = MudBuildingSpec.FillMode.NONE

	var openings: Array = []
	for o: Variant in spec.openings:
		if o is Dictionary:
			var n := MudPlanOps.normalize_opening(o as Dictionary, loops.size(), height)
			if not n.is_empty():
				openings.append(n)

	var pts := PackedVector3Array()
	var ext := PackedInt32Array()
	var travel_segments := 0

	for li in layer_count:
		var z := minf((float(li) + 0.5) * layer_h, height)
		var t := 0.0 if height <= layer_h else clampf(z / height, 0.0, 1.0)
		var sep := spec.centerline_sep_at(t)
		var ordered := _order_islands(loops, pts)
		for loop: Variant in ordered:
			var ring: PackedVector2Array = loop as PackedVector2Array
			var loop_idx := _find_loop_index(loops, ring)
			var pair := dual_perimeters_camber(ring, sep, spec.camber_mode, line_w)
			if pair.is_empty():
				return {"ok": false, "error": "wall offset failed (widen shell gap or simplify plan)"}
			var outer: PackedVector2Array = pair["outer"]
			var inner: PackedVector2Array = pair["inner"]
			var gap := _opening_for_loop(openings, loop_idx, z)
			# Spiral the seam: rotate each solid layer's start point around the ring
			# so the layer-start blob doesn't stack into one weak vertical seam.
			# (Doorway layers keep their seam fixed at the reveal.)
			if gap.is_empty() and spec.seam_stagger_frac > 0.0001:
				var frac := fposmod(float(li) * spec.seam_stagger_frac, 1.0)
				outer = _rotate_ring(outer, frac)
				inner = _rotate_ring(inner, frac)
			if pts.size() > 0 and outer.size() > 0:
				var dest := Vector3(outer[0].x, outer[0].y, z)
				if not gap.is_empty():
					dest = _sample_ring_v3(outer, float(gap.get("t1", 0.0)), z)
				if pts[pts.size() - 1].distance_to(dest) > 0.5:
					_append_point(pts, ext, dest, false)
					travel_segments += 1
			if gap.is_empty():
				_append_closed_loop(pts, ext, outer, z, true)
				if fill_mode != MudBuildingSpec.FillMode.NONE:
					travel_segments += _append_cavity_fill(pts, ext, outer, inner, z, li,
						fill_mode, spec.fill_pitch_mm, spec.fill_amplitude, line_w, true)
				else:
					if pts.size() > 0 and inner.size() > 0:
						_append_point(pts, ext, Vector3(inner[0].x, inner[0].y, z), false)
						travel_segments += 1
				_append_closed_loop(pts, ext, inner, z, true)
			else:
				travel_segments += _append_doorway_layer(pts, ext, outer, inner, z, li, gap,
					fill_mode, spec.fill_pitch_mm, spec.fill_amplitude, line_w)

		var ordered_open := _order_open_paths(open_paths, pts)
		for path: Variant in ordered_open:
			var run: PackedVector2Array = path as PackedVector2Array
			var sides := open_wall_sides(run, sep, spec.camber_mode, line_w)
			if sides.is_empty():
				return {"ok": false, "error": "open wall offset failed"}
			var left: PackedVector2Array = sides["left"]
			var right: PackedVector2Array = sides["right"]
			if pts.size() > 0 and left.size() > 0:
				var dest2 := Vector3(left[0].x, left[0].y, z)
				if pts[pts.size() - 1].distance_to(dest2) > 0.5:
					_append_point(pts, ext, dest2, false)
					travel_segments += 1
			_append_polyline(pts, ext, left, z, true)
			if fill_mode != MudBuildingSpec.FillMode.NONE:
				travel_segments += _append_open_zigzag(pts, ext, left, right, z,
					spec.fill_pitch_mm, line_w, true)
			else:
				if pts.size() > 0 and right.size() > 0:
					_append_point(pts, ext, Vector3(right[right.size() - 1].x,
						right[right.size() - 1].y, z), false)
					travel_segments += 1
			# Walk right side reverse for continuous dual wall.
			var rev := PackedVector2Array()
			for i in range(right.size() - 1, -1, -1):
				rev.append(right[i])
			_append_polyline(pts, ext, rev, z, true)

	if pts.size() < 2:
		return {"ok": false, "error": "empty toolpath"}

	var extrude_len := 0.0
	var bmin := pts[0]
	var bmax := pts[0]
	for i in pts.size():
		var p := pts[i]
		bmin = Vector3(minf(bmin.x, p.x), minf(bmin.y, p.y), minf(bmin.z, p.z))
		bmax = Vector3(maxf(bmax.x, p.x), maxf(bmax.y, p.y), maxf(bmax.z, p.z))
		if i > 0 and i < ext.size() and ext[i] != 0:
			extrude_len += pts[i].distance_to(pts[i - 1])

	var volume_mm3 := extrude_len * line_w * layer_h
	var path_len_mm := _path_length(pts)
	var est_time_hr := maxf((path_len_mm / speed) / 3600.0, 0.0025)
	var out_pts := pts
	var out_ext := ext
	if bool(opts.get("decimate", true)):
		# Mud jobs need denser paths than generic G-code preview (sine/gyroid).
		var cap := int(opts.get("max_segments", Toolpath.MAX_SEGMENTS))
		if str(opts.get("kind_hint", "")) == "mud_building" or fill_mode != MudBuildingSpec.FillMode.NONE:
			cap = maxi(cap, 12000)
		cap = clampi(cap, 500, 48000)
		var dec := Toolpath.decimate(pts, ext, cap)
		out_pts = dec.get("points", PackedVector3Array())
		out_ext = dec.get("extruding", PackedInt32Array())
	var mode := "dual_perimeter"
	match fill_mode:
		MudBuildingSpec.FillMode.SINE:
			mode = "dual_perimeter_fill"
		MudBuildingSpec.FillMode.GYROID:
			mode = "dual_perimeter_gyroid"
	return {
		"ok": true,
		"kind": "mud_building",
		"mode": mode,
		"points": out_pts,
		"extruding": out_ext,
		"bounds_min": bmin,
		"bounds_max": bmax,
		"volume_mm3": volume_mm3,
		"extrusion_mm": volume_mm3,
		"layer_height_mm": layer_h,
		"line_width_mm": line_w,
		"print_speed_mm_s": speed,
		"path_length_mm": path_len_mm,
		"est_time_hr": est_time_hr,
		"point_count": out_pts.size(),
		"raw_point_count": pts.size(),
		"layer_count": layer_count,
		"extrude_length_mm": extrude_len,
		"travel_segments": travel_segments,
		"island_count": loops.size(),
		"open_path_count": open_paths.size(),
		"opening_count": openings.size(),
		"fill_enabled": fill_mode != MudBuildingSpec.FillMode.NONE,
		"fill_mode": fill_mode,
	}


## `sep` is centerline separation between outer and inner shells.
## Builds *paired* polylines (same vertex count / parameterization) by offsetting
## a densified centerline along its outward normals. Same-t samples on outer and
## inner stay radially aligned — required for camber + fill + doorways.
static func dual_perimeters_camber(ring: PackedVector2Array, sep: float,
		camber_mode: int, line_w: float) -> Dictionary:
	var open := MudPlanOps.open_ring(ring)
	if open.size() < 3:
		return {}
	var th := maxf(sep, maxf(line_w, 1.0))
	var d_out := th * 0.5
	var d_in := -th * 0.5
	match camber_mode:
		MudBuildingSpec.CamberMode.OUTER:
			d_out = th
			d_in = 0.0
		MudBuildingSpec.CamberMode.INNER:
			d_out = 0.0
			d_in = -th
		_:
			pass
	var spacing := clampf(line_w * 0.35, 12.0, 40.0)
	var center := MudPlanOps.densify_ring(open, spacing)
	if center.size() < 3:
		return {}
	# Shell gap / camber thicker than the room collapses the cavity — reject
	# (same failure mode Geometry2D.offset used to give on absurd thicknesses).
	var min_extent := _ring_min_extent(center)
	if th > min_extent * 0.45:
		return {}
	# Ensure CCW so outward normals point outside the room.
	if _signed_area(center) < 0.0:
		center = _reverse_ring(center)
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	outer.resize(center.size())
	inner.resize(center.size())
	for i in center.size():
		var n := _outward_normal_closed(center, i)
		outer[i] = center[i] + n * d_out
		inner[i] = center[i] + n * d_in
	if outer.size() < 3 or inner.size() < 3:
		return {}
	if MudPlanOps.area_mm2(inner) >= MudPlanOps.area_mm2(outer) * 0.98:
		# Degenerate / collapsed — fall back to clipper offsets (unpaired).
		return _dual_perimeters_clipper_fallback(open, th, camber_mode, spacing)
	return {"outer": outer, "inner": inner}


static func _ring_min_extent(ring: PackedVector2Array) -> float:
	var open := MudPlanOps.open_ring(ring)
	if open.is_empty():
		return 0.0
	var bmin := open[0]
	var bmax := open[0]
	for p: Vector2 in open:
		bmin = Vector2(minf(bmin.x, p.x), minf(bmin.y, p.y))
		bmax = Vector2(maxf(bmax.x, p.x), maxf(bmax.y, p.y))
	return minf(bmax.x - bmin.x, bmax.y - bmin.y)


static func _dual_perimeters_clipper_fallback(open: PackedVector2Array, th: float,
		camber_mode: int, spacing: float) -> Dictionary:
	var outer: PackedVector2Array
	var inner: PackedVector2Array
	match camber_mode:
		MudBuildingSpec.CamberMode.OUTER:
			outer = _largest_offset(open, th)
			inner = open.duplicate()
		MudBuildingSpec.CamberMode.INNER:
			outer = open.duplicate()
			inner = _largest_offset(open, -th)
		_:
			outer = _largest_offset(open, th * 0.5)
			inner = _largest_offset(open, -th * 0.5)
	if outer.is_empty() or inner.is_empty():
		return {}
	if outer.size() < 3 or inner.size() < 3:
		return {}
	if MudPlanOps.area_mm2(inner) >= MudPlanOps.area_mm2(outer) * 0.98:
		return {}
	return {
		"outer": MudPlanOps.densify_ring(outer, spacing),
		"inner": MudPlanOps.densify_ring(inner, spacing),
	}


static func _signed_area(ring: PackedVector2Array) -> float:
	var open := MudPlanOps.open_ring(ring)
	if open.size() < 3:
		return 0.0
	var a := 0.0
	for i in open.size():
		var j := (i + 1) % open.size()
		a += open[i].x * open[j].y - open[j].x * open[i].y
	return a * 0.5


static func _reverse_ring(ring: PackedVector2Array) -> PackedVector2Array:
	var open := MudPlanOps.open_ring(ring)
	var out := PackedVector2Array()
	out.resize(open.size())
	for i in open.size():
		out[i] = open[open.size() - 1 - i]
	return out


## Unit outward normal at vertex i of a CCW closed ring.
static func _outward_normal_closed(ring: PackedVector2Array, i: int) -> Vector2:
	var n := ring.size()
	var prev := ring[(i - 1 + n) % n]
	var cur := ring[i]
	var nxt := ring[(i + 1) % n]
	var d0 := (cur - prev).normalized()
	var d1 := (nxt - cur).normalized()
	# For CCW, right-of-edge = outward: (dy, -dx).
	var n0 := Vector2(d0.y, -d0.x)
	var n1 := Vector2(d1.y, -d1.x)
	var nrm := (n0 + n1)
	if nrm.length_squared() < 1e-10:
		nrm = n0
	return nrm.normalized()


static func dual_perimeters(ring: PackedVector2Array, half_t: float) -> Dictionary:
	return dual_perimeters_camber(ring, half_t * 2.0, MudBuildingSpec.CamberMode.BOTH, 1.0)


## Left/right offsets of an open centerline (BOTH/NONE = ±half, OUTER/INNER bias).
## Paired vertices (same count) so fill zigzags stay inside the wall cavity.
static func open_wall_sides(path: PackedVector2Array, sep: float,
		camber_mode: int, line_w: float) -> Dictionary:
	if path.size() < 2:
		return {}
	var th := maxf(sep, maxf(line_w, 1.0))
	var left_d := th * 0.5
	var right_d := -th * 0.5
	match camber_mode:
		MudBuildingSpec.CamberMode.OUTER:
			left_d = th
			right_d = 0.0
		MudBuildingSpec.CamberMode.INNER:
			left_d = 0.0
			right_d = -th
	var spacing := clampf(line_w * 0.35, 12.0, 40.0)
	var center := MudPlanOps.densify_open(path, spacing)
	if center.size() < 2:
		return {}
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	left.resize(center.size())
	right.resize(center.size())
	for i in center.size():
		var n := _side_normal_open(center, i)
		left[i] = center[i] + n * left_d
		right[i] = center[i] + n * right_d
	if left.size() < 2 or right.size() < 2:
		return {}
	return {"left": left, "right": right}


## Unit "left" normal of an open polyline (consistent along the run).
static func _side_normal_open(path: PackedVector2Array, i: int) -> Vector2:
	var n := path.size()
	var d: Vector2
	if i <= 0:
		d = path[1] - path[0]
	elif i >= n - 1:
		d = path[n - 1] - path[n - 2]
	else:
		d = (path[i] - path[i - 1]).normalized() + (path[i + 1] - path[i]).normalized()
	if d.length_squared() < 1e-10:
		d = Vector2(1, 0)
	else:
		d = d.normalized()
	# Left normal of travel direction.
	return Vector2(-d.y, d.x)


static func _offset_polyline(path: PackedVector2Array, delta: float) -> PackedVector2Array:
	if absf(delta) < 0.01:
		return path.duplicate()
	var arr: Array = Geometry2D.offset_polyline(path, delta, Geometry2D.JOIN_ROUND,
		Geometry2D.END_BUTT)
	if arr.is_empty():
		return PackedVector2Array()
	# Pick the longest polyline (most faithful to the run).
	var best: PackedVector2Array = arr[0]
	for o: Variant in arr:
		if o is PackedVector2Array and MudPlanOps.path_length_mm(o) > MudPlanOps.path_length_mm(best):
			best = o as PackedVector2Array
	return best


static func _largest_offset(open: PackedVector2Array, delta: float) -> PackedVector2Array:
	var arr: Array = Geometry2D.offset_polygon(open, delta, Geometry2D.JOIN_ROUND)
	if arr.is_empty():
		return PackedVector2Array()
	var best: PackedVector2Array = arr[0]
	for o: Variant in arr:
		if o is PackedVector2Array and MudPlanOps.area_mm2(o) > MudPlanOps.area_mm2(best):
			best = o as PackedVector2Array
	return best


## Fractional inset so fill beads stay inside the clear cavity (not on shell centers).
static func _cavity_u_range(outer: PackedVector2Array, inner: PackedVector2Array,
		line_w: float) -> Vector2:
	var sep := _sample_ring(outer, 0.0).distance_to(_sample_ring(inner, 0.0))
	# Sample a few stations for a stable average separation.
	var acc := sep
	for i in 7:
		var tt := float(i + 1) / 8.0
		acc += _sample_ring(outer, tt).distance_to(_sample_ring(inner, tt))
	sep = maxf(acc / 8.0, line_w * 0.5)
	var margin := clampf((line_w * 0.55) / sep, 0.08, 0.42)
	return Vector2(margin, 1.0 - margin)


## Travel into cavity, extrude fill, travel to inner — returns travel count added.
static func _append_cavity_fill(pts: PackedVector3Array, ext: PackedInt32Array,
		outer: PackedVector2Array, inner: PackedVector2Array, z: float, layer_i: int,
		fill_mode: int, pitch_mm: float, amplitude: float, line_w: float,
		closed: bool) -> int:
	var travels := 0
	var ur := _cavity_u_range(outer, inner, line_w)
	var start_t := 0.0
	if pts.size() > 0:
		var last := Vector2(pts[pts.size() - 1].x, pts[pts.size() - 1].y)
		start_t = _nearest_ring_t(outer, last)
	var first := _sample_ring(outer, start_t).lerp(_sample_ring(inner, start_t), ur.x)
	if pts.size() > 0 and pts[pts.size() - 1].distance_to(Vector3(first.x, first.y, z)) > 0.5:
		_append_point(pts, ext, Vector3(first.x, first.y, z), false)
		travels += 1
	match fill_mode:
		MudBuildingSpec.FillMode.SINE:
			_append_sine_fill(pts, ext, outer, inner, z, pitch_mm, amplitude, ur, start_t)
		MudBuildingSpec.FillMode.GYROID:
			_append_gyroid_fill(pts, ext, outer, inner, z, layer_i, pitch_mm, amplitude, ur,
				start_t)
		_:
			pass
	if closed and inner.size() > 0:
		var idest := Vector3(inner[0].x, inner[0].y, z)
		# Prefer the inner point nearest the fill end.
		if pts.size() > 0:
			var last2 := Vector2(pts[pts.size() - 1].x, pts[pts.size() - 1].y)
			var it := _nearest_ring_t(inner, last2)
			var ip := _sample_ring(inner, it)
			idest = Vector3(ip.x, ip.y, z)
		if pts[pts.size() - 1].distance_to(idest) > 0.5:
			_append_point(pts, ext, idest, false)
			travels += 1
	return travels


## Doorway layer: outer wall → jamb → (optional cavity fill) → inner wall → jamb.
## Door occupies [t0, t1]; wall fraction is `1 - door_span`. Both shells walk the
## WALL with the same +span so the gap stays open (never extrude t0→t1 short way).
static func _append_doorway_layer(pts: PackedVector3Array, ext: PackedInt32Array,
		outer: PackedVector2Array, inner: PackedVector2Array, z: float, layer_i: int,
		gap: Dictionary, fill_mode: int, pitch_mm: float, amplitude: float,
		line_w: float) -> int:
	var travels := 0
	var t0 := float(gap["t0"])
	var t1 := float(gap["t1"])
	var door_span := fposmod(t1 - t0, 1.0)
	if door_span < 0.02 or door_span > 0.85:
		_append_closed_loop(pts, ext, outer, z, true)
		if fill_mode != MudBuildingSpec.FillMode.NONE:
			travels += _append_cavity_fill(pts, ext, outer, inner, z, layer_i,
				fill_mode, pitch_mm, amplitude, line_w, true)
		else:
			if pts.size() > 0 and inner.size() > 0:
				_append_point(pts, ext, Vector3(inner[0].x, inner[0].y, z), false)
				travels += 1
		_append_closed_loop(pts, ext, inner, z, true)
		return travels
	var wall_span := 1.0 - door_span
	# Outer wall starting at t1 (door's far reveal), walking +wall_span → t0.
	# IMPORTANT: fill must use the SAME t1 → t1+wall_span parameterization.
	# Starting fill at t0 with +wall_span walks INTO the door first (t0→t1),
	# which erased the perimeter beads and left only cavity fill in the gap.
	_append_arc_span(pts, ext, outer, z, t1, wall_span, true)
	# Jamb at t0: outer → inner (paired radial).
	var o0 := _sample_ring_v3(outer, t0, z)
	var i0 := _sample_ring_v3(inner, t0, z)
	var o1 := _sample_ring_v3(outer, t1, z)
	var i1 := _sample_ring_v3(inner, t1, z)
	if pts.size() > 0 and pts[pts.size() - 1].distance_to(o0) > 0.5:
		_append_point(pts, ext, o0, false)
		travels += 1
	_append_point(pts, ext, i0, true)
	var ur := _cavity_u_range(outer, inner, line_w)
	if fill_mode != MudBuildingSpec.FillMode.NONE:
		# Travel to cavity at t1 (start of wall), fill t1 → t0 along the wall only.
		var c1 := _sample_ring(outer, t1).lerp(_sample_ring(inner, t1), ur.x)
		if pts[pts.size() - 1].distance_to(Vector3(c1.x, c1.y, z)) > 0.5:
			_append_point(pts, ext, Vector3(c1.x, c1.y, z), false)
			travels += 1
		match fill_mode:
			MudBuildingSpec.FillMode.GYROID:
				_append_gyroid_fill_arc(pts, ext, outer, inner, z, layer_i, t1,
					t1 + wall_span, pitch_mm, amplitude, ur)
			_:
				_append_sine_fill_arc(pts, ext, outer, inner, z, t1, t1 + wall_span,
					pitch_mm, amplitude, ur)
		# Fill ends near t0; join inner at t0 then walk the wall to t1.
		if pts[pts.size() - 1].distance_to(i0) > 0.5:
			_append_point(pts, ext, i0, false)
			travels += 1
		_append_arc_span(pts, ext, inner, z, t0, wall_span, true)
		# Closing jamb at t1: inner → outer.
		if pts[pts.size() - 1].distance_to(i1) > 0.5:
			_append_point(pts, ext, i1, false)
			travels += 1
		_append_point(pts, ext, o1, true)
	else:
		# Inner wall t0 → t1 (wall), then jamb at t1 back to outer.
		_append_arc_span(pts, ext, inner, z, t0, wall_span, true)
		if pts.size() > 0 and pts[pts.size() - 1].distance_to(i1) > 0.5:
			_append_point(pts, ext, i1, false)
			travels += 1
		_append_point(pts, ext, o1, true)
	return travels


## Arc of fractional length `span` (may wrap) starting at `t_a`.
static func _append_arc_span(pts: PackedVector3Array, ext: PackedInt32Array,
		ring: PackedVector2Array, z: float, t_a: float, span: float, extrude: bool) -> void:
	if absf(span) <= 0.001:
		return
	var n := clampi(int(ceil(absf(span) * MudPlanOps.perimeter_mm(ring) / 40.0)), 4, 256)
	for i in n + 1:
		var tt := t_a + span * (float(i) / float(n))
		var p := _sample_ring(ring, fposmod(tt, 1.0))
		_append_point(pts, ext, Vector3(p.x, p.y, z), extrude and (pts.size() > 0 and i > 0))


static func _append_sine_fill(pts: PackedVector3Array, ext: PackedInt32Array,
		outer: PackedVector2Array, inner: PackedVector2Array, z: float,
		pitch_mm: float, amplitude: float, u_range: Vector2, start_t: float) -> void:
	var o := MudPlanOps.open_ring(outer)
	var inn := MudPlanOps.open_ring(inner)
	if o.size() < 3 or inn.size() < 3:
		return
	var perim := maxf(MudPlanOps.perimeter_mm(o), 1.0)
	var pitch := maxf(pitch_mm, 20.0)
	# Sample several points per pitch so the sine reads as a curve, not a zig-zag.
	var step := clampf(pitch * 0.22, 12.0, 45.0)
	var n := clampi(int(ceil(perim / step)), 24, 720)
	var amp := clampf(amplitude, 0.05, 1.0)
	var u_lo := u_range.x
	var u_hi := u_range.y
	var u_mid := (u_lo + u_hi) * 0.5
	var u_half := (u_hi - u_lo) * 0.5
	var waves := maxf(perim / pitch, 1.0)
	var start_i := clampi(int(round(start_t * float(n))) % n, 0, n - 1)
	for k in n:
		var i := (start_i + k) % n
		var tt := float(i) / float(n)
		var op := _sample_ring(o, tt)
		var ip := _sample_ring(inn, tt)
		var wave := sin(tt * TAU * waves)
		var u := clampf(u_mid + wave * u_half * amp, u_lo, u_hi)
		var p := op.lerp(ip, u)
		_append_point(pts, ext, Vector3(p.x, p.y, z), pts.size() > 0)


## 2D gyroid-ish fill: continuous cavity path with layer-phased TPMS field.
static func _append_gyroid_fill(pts: PackedVector3Array, ext: PackedInt32Array,
		outer: PackedVector2Array, inner: PackedVector2Array, z: float, layer_i: int,
		pitch_mm: float, amplitude: float, u_range: Vector2, start_t: float) -> void:
	var o := MudPlanOps.open_ring(outer)
	var inn := MudPlanOps.open_ring(inner)
	if o.size() < 3 or inn.size() < 3:
		return
	var perim := maxf(MudPlanOps.perimeter_mm(o), 1.0)
	var pitch := maxf(pitch_mm, 20.0)
	var step := clampf(pitch * 0.18, 10.0, 36.0)
	var n := clampi(int(ceil(perim / step)), 32, 900)
	var amp := clampf(amplitude, 0.05, 1.0)
	var k := TAU / pitch
	var phase := float(layer_i) * 0.85
	var u_lo := u_range.x
	var u_hi := u_range.y
	var u_mid := (u_lo + u_hi) * 0.5
	var u_half := (u_hi - u_lo) * 0.5
	var start_i := clampi(int(round(start_t * float(n))) % n, 0, n - 1)
	for kk in n:
		var i := (start_i + kk) % n
		var tt := float(i) / float(n)
		var op := _sample_ring(o, tt)
		var ip := _sample_ring(inn, tt)
		var mid := op.lerp(ip, 0.5)
		var field := sin(k * mid.x + phase) * cos(k * mid.y) \
			+ sin(k * mid.y + phase) * cos(k * z * 0.02)
		var u := clampf(u_mid + 0.9 * amp * u_half * field, u_lo, u_hi)
		var p := op.lerp(ip, u)
		_append_point(pts, ext, Vector3(p.x, p.y, z), pts.size() > 0)


static func _append_sine_fill_arc(pts: PackedVector3Array, ext: PackedInt32Array,
		outer: PackedVector2Array, inner: PackedVector2Array, z: float,
		t_start: float, t_end: float, pitch_mm: float, amplitude: float,
		u_range: Vector2) -> void:
	var span := t_end - t_start
	if absf(span) <= 0.02:
		return
	var perim := maxf(MudPlanOps.perimeter_mm(outer), 1.0) * absf(span)
	var pitch := maxf(pitch_mm, 20.0)
	var step := clampf(pitch * 0.22, 12.0, 45.0)
	var n := clampi(int(ceil(perim / step)), 12, 720)
	var amp := clampf(amplitude, 0.05, 1.0)
	var u_lo := u_range.x
	var u_hi := u_range.y
	var u_mid := (u_lo + u_hi) * 0.5
	var u_half := (u_hi - u_lo) * 0.5
	var waves := maxf(perim / pitch, 1.0)
	for i in n + 1:
		var tt := t_start + span * (float(i) / float(n))
		var tu := fposmod(tt, 1.0)
		var op := _sample_ring(outer, tu)
		var ip := _sample_ring(inner, tu)
		var wave := sin(float(i) / float(maxi(n, 1)) * TAU * waves)
		var u := clampf(u_mid + wave * u_half * amp, u_lo, u_hi)
		var p := op.lerp(ip, u)
		_append_point(pts, ext, Vector3(p.x, p.y, z), pts.size() > 0)


static func _append_gyroid_fill_arc(pts: PackedVector3Array, ext: PackedInt32Array,
		outer: PackedVector2Array, inner: PackedVector2Array, z: float, layer_i: int,
		t_start: float, t_end: float, pitch_mm: float, amplitude: float,
		u_range: Vector2) -> void:
	var span := t_end - t_start
	if absf(span) <= 0.02:
		return
	var perim := maxf(MudPlanOps.perimeter_mm(outer), 1.0) * absf(span)
	var pitch := maxf(pitch_mm, 20.0)
	var step := clampf(pitch * 0.18, 10.0, 36.0)
	var n := clampi(int(ceil(perim / step)), 16, 900)
	var amp := clampf(amplitude, 0.05, 1.0)
	var k := TAU / pitch
	var phase := float(layer_i) * 0.85
	var u_lo := u_range.x
	var u_hi := u_range.y
	var u_mid := (u_lo + u_hi) * 0.5
	var u_half := (u_hi - u_lo) * 0.5
	for i in n + 1:
		var tt := t_start + span * (float(i) / float(n))
		var tu := fposmod(tt, 1.0)
		var op := _sample_ring(outer, tu)
		var ip := _sample_ring(inner, tu)
		var mid := op.lerp(ip, 0.5)
		var field := sin(k * mid.x + phase) * cos(k * mid.y) \
			+ sin(k * mid.y + phase) * cos(k * z * 0.02)
		var u := clampf(u_mid + 0.9 * amp * u_half * field, u_lo, u_hi)
		var p := op.lerp(ip, u)
		_append_point(pts, ext, Vector3(p.x, p.y, z), pts.size() > 0)


static func _append_open_zigzag(pts: PackedVector3Array, ext: PackedInt32Array,
		left: PackedVector2Array, right: PackedVector2Array, z: float,
		pitch_mm: float, line_w: float, extrude: bool) -> int:
	var travels := 0
	var n := clampi(int(ceil(MudPlanOps.path_length_mm(left) / maxf(pitch_mm, 20.0))), 4, 128)
	var sep := left[0].distance_to(_sample_polyline(right, 0.0))
	var margin := clampf((line_w * 0.55) / maxf(sep, line_w * 0.5), 0.08, 0.42)
	# Travel to first inset stroke start.
	var a0 := _sample_polyline(left, 0.0).lerp(_sample_polyline(right, 0.0), margin)
	if pts.size() > 0 and pts[pts.size() - 1].distance_to(Vector3(a0.x, a0.y, z)) > 0.5:
		_append_point(pts, ext, Vector3(a0.x, a0.y, z), false)
		travels += 1
	for i in n:
		var t := float(i) / float(n - 1) if n > 1 else 0.0
		var L := _sample_polyline(left, t)
		var R := _sample_polyline(right, t)
		var a := L.lerp(R, margin)
		var b := L.lerp(R, 1.0 - margin)
		if i % 2 == 0:
			_append_point(pts, ext, Vector3(a.x, a.y, z), extrude and pts.size() > 0)
			_append_point(pts, ext, Vector3(b.x, b.y, z), extrude)
		else:
			_append_point(pts, ext, Vector3(b.x, b.y, z), extrude and pts.size() > 0)
			_append_point(pts, ext, Vector3(a.x, a.y, z), extrude)
	# Travel to right-side end for the reverse perimeter.
	if right.size() > 0:
		var rend := Vector3(right[right.size() - 1].x, right[right.size() - 1].y, z)
		if pts[pts.size() - 1].distance_to(rend) > 0.5:
			_append_point(pts, ext, rend, false)
			travels += 1
	return travels


static func _nearest_ring_t(ring: PackedVector2Array, p: Vector2) -> float:
	var n := 64
	var best_t := 0.0
	var best_d := INF
	for i in n:
		var tt := float(i) / float(n)
		var d := _sample_ring(ring, tt).distance_squared_to(p)
		if d < best_d:
			best_d = d
			best_t = tt
	return best_t


static func _sample_ring(ring: PackedVector2Array, t: float) -> Vector2:
	var n := ring.size()
	if n == 0:
		return Vector2.ZERO
	var lengths: PackedFloat32Array = PackedFloat32Array()
	lengths.resize(n + 1)
	lengths[0] = 0.0
	for i in n:
		var nxt := ring[(i + 1) % n]
		lengths[i + 1] = lengths[i] + ring[i].distance_to(nxt)
	var total := lengths[n]
	if total <= 0.001:
		return ring[0]
	var target := clampf(t, 0.0, 0.999999) * total
	for i in n:
		if lengths[i + 1] >= target:
			var seg := lengths[i + 1] - lengths[i]
			var f := 0.0 if seg < 1e-6 else (target - lengths[i]) / seg
			return ring[i].lerp(ring[(i + 1) % n], f)
	return ring[0]


static func _sample_polyline(path: PackedVector2Array, t: float) -> Vector2:
	if path.size() == 0:
		return Vector2.ZERO
	if path.size() == 1:
		return path[0]
	var lengths: PackedFloat32Array = PackedFloat32Array()
	lengths.resize(path.size())
	lengths[0] = 0.0
	for i in range(1, path.size()):
		lengths[i] = lengths[i - 1] + path[i].distance_to(path[i - 1])
	var total := lengths[path.size() - 1]
	if total <= 0.001:
		return path[0]
	var target := clampf(t, 0.0, 1.0) * total
	for i in range(1, path.size()):
		if lengths[i] >= target:
			var seg := lengths[i] - lengths[i - 1]
			var f := 0.0 if seg < 1e-6 else (target - lengths[i - 1]) / seg
			return path[i - 1].lerp(path[i], f)
	return path[path.size() - 1]


static func _sample_ring_v3(ring: PackedVector2Array, t: float, z: float) -> Vector3:
	var p := _sample_ring(ring, fposmod(t, 1.0))
	return Vector3(p.x, p.y, z)


## Append arc from t_a → t_b (t_b may be > 1 to wrap).
static func _append_arc(pts: PackedVector3Array, ext: PackedInt32Array,
		ring: PackedVector2Array, z: float, t_a: float, t_b: float, extrude: bool) -> void:
	var span := t_b - t_a
	if span <= 0.001:
		return
	var n := clampi(int(ceil(absf(span) * MudPlanOps.perimeter_mm(ring) / 40.0)), 4, 256)
	for i in n + 1:
		var tt := t_a + span * (float(i) / float(n))
		var p := _sample_ring(ring, fposmod(tt, 1.0))
		_append_point(pts, ext, Vector3(p.x, p.y, z), extrude and (pts.size() > 0 and i > 0))


static func _opening_for_loop(openings: Array, loop_idx: int, z: float) -> Dictionary:
	for o: Variant in openings:
		if not (o is Dictionary):
			continue
		var d: Dictionary = o
		if int(d.get("loop_index", -1)) != loop_idx:
			continue
		if z >= float(d.get("lintel_mm", 0.0)):
			continue  # above lintel → solid wall again
		return d
	return {}


static func _find_loop_index(loops: Array, ring: PackedVector2Array) -> int:
	for i in loops.size():
		if loops[i] == ring:
			return i
	# Fallback: centroid match.
	var c := _ring_centroid(ring)
	var best := 0
	var best_d := INF
	for i in loops.size():
		var d := _ring_centroid(loops[i] as PackedVector2Array).distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = i
	return best


static func _order_islands(loops: Array, pts: PackedVector3Array) -> Array:
	if loops.size() <= 1:
		return loops.duplicate()
	var remaining: Array = loops.duplicate()
	var ordered: Array = []
	var cursor := Vector2.ZERO
	if pts.size() > 0:
		cursor = Vector2(pts[pts.size() - 1].x, pts[pts.size() - 1].y)
	while not remaining.is_empty():
		var best_i := 0
		var best_d := INF
		for i in remaining.size():
			var ring: PackedVector2Array = remaining[i] as PackedVector2Array
			var d := _ring_centroid(ring).distance_squared_to(cursor)
			if d < best_d:
				best_d = d
				best_i = i
		var chosen: PackedVector2Array = remaining[best_i] as PackedVector2Array
		ordered.append(chosen)
		cursor = _ring_centroid(chosen)
		remaining.remove_at(best_i)
	return ordered


static func _order_open_paths(paths: Array, pts: PackedVector3Array) -> Array:
	if paths.size() <= 1:
		return paths.duplicate()
	var remaining: Array = paths.duplicate()
	var ordered: Array = []
	var cursor := Vector2.ZERO
	if pts.size() > 0:
		cursor = Vector2(pts[pts.size() - 1].x, pts[pts.size() - 1].y)
	while not remaining.is_empty():
		var best_i := 0
		var best_d := INF
		for i in remaining.size():
			var run: PackedVector2Array = remaining[i] as PackedVector2Array
			var d := run[0].distance_squared_to(cursor)
			if d < best_d:
				best_d = d
				best_i = i
		var chosen: PackedVector2Array = remaining[best_i] as PackedVector2Array
		ordered.append(chosen)
		cursor = chosen[chosen.size() - 1]
		remaining.remove_at(best_i)
	return ordered


## Rotate a (closed) ring's start point by `frac` of its vertex count so the seam
## walks around the perimeter layer-to-layer. Returns an open ring (no dup end).
static func _rotate_ring(ring: PackedVector2Array, frac: float) -> PackedVector2Array:
	var open := MudPlanOps.open_ring(ring)
	var n := open.size()
	if n < 3:
		return open
	var k := int(fposmod(frac, 1.0) * float(n)) % n
	if k == 0:
		return open
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		out[i] = open[(i + k) % n]
	return out


static func _ring_centroid(ring: PackedVector2Array) -> Vector2:
	var open := MudPlanOps.open_ring(ring)
	if open.is_empty():
		return Vector2.ZERO
	var s := Vector2.ZERO
	for p: Vector2 in open:
		s += p
	return s / float(open.size())


static func _append_closed_loop(pts: PackedVector3Array, ext: PackedInt32Array,
		ring: PackedVector2Array, z: float, extrude: bool) -> void:
	if ring.size() < 3:
		return
	var closed := MudPlanOps.close_loop(ring)
	for i in closed.size():
		var p := Vector3(closed[i].x, closed[i].y, z)
		var is_ext := extrude and i > 0
		if pts.is_empty():
			is_ext = false
		_append_point(pts, ext, p, is_ext)


static func _append_polyline(pts: PackedVector3Array, ext: PackedInt32Array,
		path: PackedVector2Array, z: float, extrude: bool) -> void:
	for i in path.size():
		var p := Vector3(path[i].x, path[i].y, z)
		_append_point(pts, ext, p, extrude and pts.size() > 0 and i > 0)


static func _append_point(pts: PackedVector3Array, ext: PackedInt32Array, p: Vector3,
		extruding: bool) -> void:
	if pts.is_empty():
		pts.append(p)
		ext.append(0)
		return
	pts.append(p)
	ext.append(1 if extruding else 0)


static func _path_length(points: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return total
