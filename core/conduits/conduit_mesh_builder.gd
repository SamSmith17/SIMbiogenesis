class_name ConduitMeshBuilder
extends RefCounted

## Builds a tube ArrayMesh along a 3D path with optional catenary sag (flexible
## conduits) or straight/elbowed segments (rigid). Pure geometry — headless-testable.

const DEFAULT_RADIAL_SEGMENTS := 8
const DEFAULT_SEGMENTS_PER_SPAN := 12
const MAX_RADIAL_SEGMENTS := 24
## Target facet edge length (m) — radial count is chosen so a ring facet is
## roughly this long, keeping thin cords cheap and fat pipes round.
const RADIAL_FACET_TARGET_M := 0.035


## Radial sides for a tube of the given radius: ~circumference / facet target,
## clamped to [DEFAULT, MAX] and rounded to an even count (clean top/bottom seam).
static func radial_segments_for_radius(radius: float) -> int:
	var circ := TAU * maxf(radius, 0.001)
	var n := int(round(circ / RADIAL_FACET_TARGET_M))
	n = clampi(n, DEFAULT_RADIAL_SEGMENTS, MAX_RADIAL_SEGMENTS)
	if n % 2 == 1:
		n += 1
	return mini(n, MAX_RADIAL_SEGMENTS)


## Extra clearance kept above the ground when a draped run rests on it.
const DRAPE_CLEARANCE_M := 0.02

## Full build: control points → {mesh, material, arc_length_m, sample_points}.
## ground_y_fn: optional Callable(Vector3) -> float returning terrain height at
## a world position; when supplied and the kind has ground_drape, flexible sag
## is clamped so the run rests on (never sinks below) the ground.
static func build(control_points: Array, type_id: String,
		segments_per_span: int = DEFAULT_SEGMENTS_PER_SPAN,
		ground_y_fn: Callable = Callable(),
		style_override: Dictionary = {}) -> Dictionary:
	var style: Dictionary = ConduitKinds.type_meta(type_id)
	for k: Variant in style_override.keys():
		style[k] = style_override[k]
	var samples := sample_path(control_points, style, segments_per_span, ground_y_fn)
	var radius: float = float(style.get("radius_m", 0.01))
	# Fat pipes (4"/6" PVC, ducting) need more radial sides or they read as faceted
	# prisms; thin cords stay cheap at 8. Scales ~ circumference at a fixed facet size.
	var radial: int = radial_segments_for_radius(radius)
	var mesh: ArrayMesh
	if bool(style.get("dashed", false)):
		mesh = _build_dashed_tube_mesh(samples, radius, radial, 0.32, 0.18)
	else:
		mesh = _build_tube_mesh(samples, radius, radial)
	var mat := ConduitKinds.make_material(type_id)
	var arc_len := ConduitKinds.polyline_length_m(samples)
	return {
		"mesh": mesh,
		"material": mat,
		"arc_length_m": arc_len,
		"sample_points": samples,
	}


## Legacy hanging service-loop inject (non-drape flexible only). Prefer
## `sample_ground_snake` for extension cords / hoses on terrain.
static func inject_end_slack(control_points: Array, slack_m: float) -> Array:
	if control_points.size() < 2 or slack_m <= 0.01:
		return control_points
	var a: Vector3 = control_points[0] as Vector3
	var b: Vector3 = control_points[control_points.size() - 1] as Vector3
	var hz := Vector2(b.x - a.x, b.z - a.z)
	if hz.length() < 0.4:
		return control_points
	var dir := hz.normalized()
	var leave := clampf(slack_m * 0.85, 0.12, 0.55)
	var droop := clampf(slack_m, 0.15, 0.55)
	var a1 := Vector3(a.x + dir.x * leave, a.y - droop * 0.35, a.z + dir.y * leave)
	var a2 := Vector3(a.x + dir.x * leave * 1.6, a.y - droop, a.z + dir.y * leave * 1.6)
	var b2 := Vector3(b.x - dir.x * leave * 1.6, b.y - droop, b.z - dir.y * leave * 1.6)
	var b1 := Vector3(b.x - dir.x * leave, b.y - droop * 0.35, b.z - dir.y * leave)
	var out: Array = [a, a1, a2]
	for i: int in range(1, control_points.size() - 1):
		out.append(control_points[i])
	out.append(b2)
	out.append(b1)
	out.append(b)
	return out


## Sample a path through control points.
## Ground-drape flexible (extension cord / hose): ground-snake — drop to terrain
## with a smooth bend, meander along the ground, rise to the far plug. No
## mid-air catenary stacked on end-slack (that produced the kinked look).
## Non-drape flexible: classic parabolic sag between control points.
## With terrain_clamp + ground_y_fn: sag that would go under the mesh rests on
## the ground for that section (hang → ground-drape handoff).
## Rigid: straight spans.
static func sample_path(control_points: Array, style: Dictionary,
		segments_per_span: int = DEFAULT_SEGMENTS_PER_SPAN,
		ground_y_fn: Callable = Callable()) -> PackedVector3Array:
	var pts: Array = control_points
	var out := PackedVector3Array()
	if pts.is_empty():
		return out
	if pts.size() == 1:
		out.append(pts[0] as Vector3)
		return out
	var flexible: bool = bool(style.get("flexible", true))
	var drape: bool = bool(style.get("ground_drape", false)) and ground_y_fn.is_valid()
	if flexible and drape:
		return sample_ground_snake(pts, style, segments_per_span, ground_y_fn)
	var sag_amount: float = float(style.get("sag_amount", 0.3))
	for span: int in range(pts.size() - 1):
		var start: Vector3 = pts[span] as Vector3
		var end: Vector3 = pts[span + 1] as Vector3
		var segs: int = maxi(segments_per_span, 1)
		for i: int in range(segs + 1):
			if span > 0 and i == 0:
				continue
			var t: float = float(i) / float(segs)
			var pos: Vector3 = start.lerp(end, t)
			if flexible:
				var hz: float = Vector2(end.x - start.x, end.z - start.z).length()
				var sag: float = hz * sag_amount * 0.3
				pos.y -= sag * 4.0 * t * (1.0 - t)
			out.append(pos)
	if bool(style.get("terrain_clamp", false)) and ground_y_fn.is_valid():
		out = clamp_samples_to_ground(out, ground_y_fn)
	return out


## Lift any sample below terrain to ground + clearance so hang sag never tunnels.
static func clamp_samples_to_ground(samples: PackedVector3Array,
		ground_y_fn: Callable) -> PackedVector3Array:
	if samples.is_empty() or not ground_y_fn.is_valid():
		return samples
	var out := PackedVector3Array()
	out.resize(samples.size())
	for i: int in range(samples.size()):
		var p: Vector3 = samples[i]
		var floor_y := float(ground_y_fn.call(p)) + DRAPE_CLEARANCE_M
		if p.y < floor_y:
			p.y = floor_y
		out[i] = p
	return out


## Extension-cord / hose: leave each plug, rest on terrain, snake laterally.
## One continuous snake along the full XZ polyline (endpoints + mid pins).
## Per-span snakes used to zigzag on short approach stubs into tall ports.
static func sample_ground_snake(control_points: Array, style: Dictionary,
		segments_per_span: int, ground_y_fn: Callable) -> PackedVector3Array:
	var out := PackedVector3Array()
	if control_points.size() < 2 or not ground_y_fn.is_valid():
		return out
	var pts := _collapse_drape_controls(control_points, ground_y_fn)
	if pts.size() < 2:
		return out
	var a: Vector3 = pts[0] as Vector3
	var b: Vector3 = pts[pts.size() - 1] as Vector3
	# XZ polyline through mid pins (projected to ground for pathing).
	var xz_poly: PackedVector2Array = PackedVector2Array()
	xz_poly.append(Vector2(a.x, a.z))
	for i: int in range(1, pts.size() - 1):
		var m: Vector3 = pts[i] as Vector3
		xz_poly.append(Vector2(m.x, m.z))
	xz_poly.append(Vector2(b.x, b.z))
	var cum: PackedFloat32Array = PackedFloat32Array()
	cum.append(0.0)
	var run_len := 0.0
	for i: int in range(1, xz_poly.size()):
		run_len += xz_poly[i].distance_to(xz_poly[i - 1])
		cum.append(run_len)
	run_len = maxf(run_len, 0.05)
	var slack := clampf(float(style.get("end_slack_m", 0.3)), 0.0, 1.5)
	var sag_amt := clampf(float(style.get("sag_amount", 0.35)), 0.0, 1.0)
	var floor_a := float(ground_y_fn.call(a)) + DRAPE_CLEARANCE_M
	var floor_b := float(ground_y_fn.call(b)) + DRAPE_CLEARANCE_M
	var h_drop := maxf(a.y - floor_a, 0.0)
	var h_rise := maxf(b.y - floor_b, 0.0)
	# Longer ground linger before tall risers (tank/cylinder ports).
	var bend_a := clampf(0.35 + slack * 0.7 + h_drop * 1.15, 0.3, 4.5)
	var bend_b := clampf(0.35 + slack * 0.7 + h_rise * 1.15, 0.3, 4.5)
	bend_a = minf(bend_a, run_len * 0.42)
	bend_b = minf(bend_b, run_len * 0.42)
	if bend_a + bend_b > run_len * 0.85:
		var scale := (run_len * 0.85) / maxf(bend_a + bend_b, 0.01)
		bend_a *= scale
		bend_b *= scale
	var amp_m := clampf(0.04 + sag_amt * 0.22 + slack * 0.35, 0.04, 0.75)
	amp_m = minf(amp_m, run_len * 0.18)
	var waves := 1.15 + sag_amt * 1.35 + slack * 1.1
	var phase := fmod(absf(a.x * 12.9898 + a.z * 78.233 + b.x * 37.719), TAU)
	var n := clampi(segments_per_span * maxi(pts.size(), 2), 28, 96)
	var t_drop := bend_a / run_len
	var t_rise := 1.0 - bend_b / run_len
	for i: int in range(n + 1):
		var t := float(i) / float(n)
		var along := t * run_len
		var base_xz := _point_on_xz_poly(xz_poly, cum, along)
		var tang := _tangent_on_xz_poly(xz_poly, cum, along)
		var perp := Vector2(-tang.y, tang.x)
		var snake_fade := _smoothstep(0.0, t_drop, t) * (1.0 - _smoothstep(t_rise, 1.0, t))
		var snake := sin(t * waves * TAU + phase) * amp_m * snake_fade
		snake += sin(t * waves * 2.0 * TAU + phase * 0.5) * amp_m * 0.22 * snake_fade
		var xz := base_xz + perp * snake
		var floor_y := float(ground_y_fn.call(Vector3(xz.x, 0.0, xz.y))) + DRAPE_CLEARANCE_M
		var y: float
		if t < t_drop:
			var u := clampf(t / maxf(t_drop, 1e-4), 0.0, 1.0)
			var e := 1.0 - (1.0 - u) * (1.0 - u)
			y = lerpf(a.y, floor_y, e)
		elif t > t_rise:
			var u2 := clampf((t - t_rise) / maxf(1.0 - t_rise, 1e-4), 0.0, 1.0)
			var e2 := u2 * u2
			y = lerpf(floor_y, b.y, e2)
		else:
			y = floor_y
		y = maxf(y, floor_y)
		out.append(Vector3(xz.x, y, xz.y))
	if out.size() >= 2:
		out[0] = a
		out[out.size() - 1] = b
	return out


## Drop near-duplicates and near-vertical approach stubs (XZ≈0, large ΔY) that
## used to spawn tiny snake spans → accordion zigzags into tank ports.
static func _collapse_drape_controls(control_points: Array,
		ground_y_fn: Callable) -> Array:
	var raw: Array = []
	for v: Variant in control_points:
		if v is Vector3:
			raw.append(v)
	if raw.size() < 2:
		return raw
	var pts: Array = [raw[0]]
	for i: int in range(1, raw.size()):
		var p: Vector3 = raw[i] as Vector3
		var prev: Vector3 = pts[pts.size() - 1] as Vector3
		if prev.distance_to(p) <= 0.05:
			continue
		var hz := Vector2(p.x - prev.x, p.z - prev.z).length()
		var dy := absf(p.y - prev.y)
		# Vertical seat stub: keep the far endpoint only (overwrite last).
		if hz < 0.12 and dy > 0.18:
			pts[pts.size() - 1] = p
			continue
		pts.append(p)
	# Ensure true endpoints survive.
	if pts.size() >= 1:
		pts[0] = raw[0]
		pts[pts.size() - 1] = raw[raw.size() - 1]
	# Mid pins: use ground Y for pathing (surface aim); ends keep plug height.
	for i: int in range(1, pts.size() - 1):
		var m: Vector3 = pts[i] as Vector3
		m.y = float(ground_y_fn.call(m)) + DRAPE_CLEARANCE_M
		pts[i] = m
	return pts


static func _point_on_xz_poly(poly: PackedVector2Array, cum: PackedFloat32Array,
		along: float) -> Vector2:
	if poly.size() < 2:
		return poly[0] if not poly.is_empty() else Vector2.ZERO
	var target := clampf(along, 0.0, cum[cum.size() - 1])
	for i: int in range(1, cum.size()):
		if target <= cum[i] + 1e-6:
			var span := maxf(cum[i] - cum[i - 1], 1e-6)
			var u := (target - cum[i - 1]) / span
			return poly[i - 1].lerp(poly[i], u)
	return poly[poly.size() - 1]


static func _tangent_on_xz_poly(poly: PackedVector2Array, cum: PackedFloat32Array,
		along: float) -> Vector2:
	if poly.size() < 2:
		return Vector2(1, 0)
	var target := clampf(along, 0.0, cum[cum.size() - 1])
	for i: int in range(1, cum.size()):
		if target <= cum[i] + 1e-6:
			var d: Vector2 = poly[i] - poly[i - 1]
			if d.length_squared() < 1e-12:
				continue
			return d.normalized()
	var d2: Vector2 = poly[poly.size() - 1] - poly[poly.size() - 2]
	return d2.normalized() if d2.length_squared() > 1e-12 else Vector2(1, 0)


static func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	if edge1 <= edge0 + 1e-8:
		return 0.0 if x < edge0 else 1.0
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Light-string build: tube mesh plus evenly spaced bulb transforms along the
## sampled catenary. Returns {mesh, material, arc_length_m, sample_points,
## bulb_positions: PackedVector3Array}. Continuous strips (bulb_spacing_m == 0)
## return no bulb positions — the strip itself is made emissive by the caller.
static func build_light_string(control_points: Array, type_id: String,
		segments_per_span: int = DEFAULT_SEGMENTS_PER_SPAN,
		ground_y_fn: Callable = Callable(),
		style_override: Dictionary = {}) -> Dictionary:
	var built := build(control_points, type_id, segments_per_span, ground_y_fn, style_override)
	var style: Dictionary = ConduitKinds.type_meta(type_id)
	var spacing: float = float(style.get("bulb_spacing_m", 0.0))
	var samples: PackedVector3Array = built.get("sample_points", PackedVector3Array())
	built["bulb_positions"] = bulb_positions_along(samples, spacing)
	return built


## Evenly spaced points along a sampled polyline (arc-length parameterized).
## First bulb sits half a spacing in from the start so ends stay bulb-free.
static func bulb_positions_along(samples: PackedVector3Array,
		spacing_m: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if spacing_m <= 0.001 or samples.size() < 2:
		return out
	var next_at: float = spacing_m * 0.5
	var walked: float = 0.0
	for i: int in range(1, samples.size()):
		var a: Vector3 = samples[i - 1]
		var b: Vector3 = samples[i]
		var seg_len: float = a.distance_to(b)
		if seg_len <= 1e-9:
			continue
		while next_at <= walked + seg_len:
			var t: float = (next_at - walked) / seg_len
			out.append(a.lerp(b, t))
			next_at += spacing_m
		walked += seg_len
	return out


## Build separate dash capsules along the polyline (real visual gaps).
static func _build_dashed_tube_mesh(samples: PackedVector3Array, radius: float,
		radial_segments: int, dash_m: float, gap_m: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if samples.size() < 2 or dash_m <= 0.01:
		return _build_tube_mesh(samples, radius, radial_segments)
	var total := ConduitKinds.polyline_length_m(samples)
	if total < 0.05:
		return _build_tube_mesh(samples, radius, radial_segments)
	var period := dash_m + gap_m
	var at := 0.0
	while at < total - 0.01:
		var dash_end := minf(at + dash_m, total)
		var span := _slice_polyline(samples, at, dash_end)
		if span.size() >= 2:
			_append_tube_surface(mesh, span, radius, radial_segments)
		at += period
	if mesh.get_surface_count() == 0:
		return _build_tube_mesh(samples, radius, radial_segments)
	return mesh


static func _slice_polyline(samples: PackedVector3Array, d0: float,
		d1: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if d1 <= d0 + 1e-4 or samples.size() < 2:
		return out
	var walked := 0.0
	var started := false
	for i: int in range(samples.size() - 1):
		var a: Vector3 = samples[i]
		var b: Vector3 = samples[i + 1]
		var seg := a.distance_to(b)
		if seg < 1e-8:
			continue
		var s0 := walked
		var s1 := walked + seg
		if s1 < d0:
			walked = s1
			continue
		if s0 > d1:
			break
		if not started:
			var t0 := clampf((d0 - s0) / seg, 0.0, 1.0)
			out.append(a.lerp(b, t0))
			started = true
		if s1 <= d1:
			out.append(b)
		else:
			var t1 := clampf((d1 - s0) / seg, 0.0, 1.0)
			out.append(a.lerp(b, t1))
			break
		walked = s1
	return out


static func _append_tube_surface(mesh: ArrayMesh, path: PackedVector3Array,
		radius: float, radial_segments: int) -> void:
	var part := _build_tube_mesh(path, radius, radial_segments)
	for si: int in part.get_surface_count():
		var arrs := part.surface_get_arrays(si)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)


## Public tube over an arbitrary world-space path (used for elbow-collar sleeves
## that follow the pipe through a bend). Verts are in the path's own space.
static func build_tube(path: PackedVector3Array, radius: float,
		radial_segments: int = DEFAULT_RADIAL_SEGMENTS) -> ArrayMesh:
	return _build_tube_mesh(path, radius, radial_segments)


static func _build_tube_mesh(path: PackedVector3Array, radius: float,
		radial_segments: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if path.size() < 2 or radius <= 0.0:
		return mesh
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var ring_count: int = path.size()
	for ring: int in range(ring_count):
		var p: Vector3 = path[ring]
		var forward: Vector3
		if ring == 0:
			forward = (path[1] - path[0]).normalized()
		elif ring == ring_count - 1:
			forward = (path[ring] - path[ring - 1]).normalized()
		else:
			forward = (path[ring + 1] - path[ring - 1]).normalized()
		if forward.length_squared() < 1e-8:
			forward = Vector3.UP
		var right: Vector3 = forward.cross(Vector3.UP)
		if right.length_squared() < 1e-8:
			right = forward.cross(Vector3.RIGHT)
		right = right.normalized()
		var up: Vector3 = right.cross(forward).normalized()
		for seg: int in range(radial_segments):
			var ang: float = TAU * float(seg) / float(radial_segments)
			var offset: Vector3 = right * cos(ang) * radius + up * sin(ang) * radius
			verts.append(p + offset)
			norms.append(offset.normalized())
			var u: float = float(ring) / float(maxi(ring_count - 1, 1))
			uvs.append(Vector2(float(seg) / float(radial_segments), u))
	for ring: int in range(ring_count - 1):
		for seg: int in range(radial_segments):
			var sn: int = (seg + 1) % radial_segments
			var a: int = ring * radial_segments + seg
			var b: int = ring * radial_segments + sn
			var c: int = (ring + 1) * radial_segments + seg
			var d: int = (ring + 1) * radial_segments + sn
			idx.append_array([a, c, b, b, c, d])
	_add_cap(mesh, path, 0, radius, radial_segments, true, verts, norms, uvs, idx)
	_add_cap(mesh, path, ring_count - 1, radius, radial_segments, false, verts, norms, uvs, idx)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _add_cap(_mesh: ArrayMesh, path: PackedVector3Array, ring_idx: int,
		radius: float, radial_segments: int, flip: bool,
		verts: PackedVector3Array, norms: PackedVector3Array,
		uvs: PackedVector2Array, idx: PackedInt32Array) -> void:
	if path.is_empty():
		return
	var center: Vector3 = path[ring_idx]
	var forward: Vector3
	if ring_idx == 0:
		forward = (path[1] - path[0]).normalized()
	elif ring_idx == path.size() - 1:
		forward = (path[ring_idx] - path[ring_idx - 1]).normalized()
	else:
		forward = (path[ring_idx + 1] - path[ring_idx - 1]).normalized()
	if forward.length_squared() < 1e-8:
		forward = Vector3.UP
	if not flip:
		forward = -forward
	var right: Vector3 = forward.cross(Vector3.UP)
	if right.length_squared() < 1e-8:
		right = forward.cross(Vector3.RIGHT)
	right = right.normalized()
	var up: Vector3 = right.cross(forward).normalized()
	var base: int = verts.size()
	verts.append(center)
	norms.append(forward)
	uvs.append(Vector2(0.5, 0.5))
	for seg: int in range(radial_segments):
		var ang: float = TAU * float(seg) / float(radial_segments)
		var offset: Vector3 = right * cos(ang) * radius + up * sin(ang) * radius
		verts.append(center + offset)
		norms.append(forward)
		uvs.append(Vector2(cos(ang) * 0.5 + 0.5, sin(ang) * 0.5 + 0.5))
	for seg: int in range(radial_segments):
		var sn: int = (seg + 1) % radial_segments
		if flip:
			idx.append_array([base, base + 1 + seg, base + 1 + sn])
		else:
			idx.append_array([base, base + 1 + sn, base + 1 + seg])
