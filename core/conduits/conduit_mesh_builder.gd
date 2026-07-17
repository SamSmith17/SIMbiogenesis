class_name ConduitMeshBuilder
extends RefCounted

## Builds a tube ArrayMesh along a 3D path with optional catenary sag (flexible
## conduits) or straight/elbowed segments (rigid). Pure geometry — headless-testable.

const DEFAULT_RADIAL_SEGMENTS := 8
const DEFAULT_SEGMENTS_PER_SPAN := 12


## Extra clearance kept above the ground when a draped run rests on it.
const DRAPE_CLEARANCE_M := 0.02

## Full build: control points → {mesh, material, arc_length_m, sample_points}.
## ground_y_fn: optional Callable(Vector3) -> float returning terrain height at
## a world position; when supplied and the kind has ground_drape, flexible sag
## is clamped so the run rests on (never sinks below) the ground.
static func build(control_points: Array, type_id: String,
		segments_per_span: int = DEFAULT_SEGMENTS_PER_SPAN,
		ground_y_fn: Callable = Callable()) -> Dictionary:
	var style: Dictionary = ConduitKinds.type_meta(type_id)
	var samples := sample_path(control_points, style, segments_per_span, ground_y_fn)
	var radius: float = float(style.get("radius_m", 0.01))
	var mesh := _build_tube_mesh(samples, radius, DEFAULT_RADIAL_SEGMENTS)
	var mat := ConduitKinds.make_material(type_id)
	var arc_len := ConduitKinds.polyline_length_m(samples)
	return {
		"mesh": mesh,
		"material": mat,
		"arc_length_m": arc_len,
		"sample_points": samples,
	}


## Sample a path through control points with per-span flexible sag or rigid lines.
## When ground_y_fn is valid and the style has ground_drape, sagged points are
## clamped to ground + clearance (extension cord / hose resting on terrain).
static func sample_path(control_points: Array, style: Dictionary,
		segments_per_span: int = DEFAULT_SEGMENTS_PER_SPAN,
		ground_y_fn: Callable = Callable()) -> PackedVector3Array:
	var out := PackedVector3Array()
	if control_points.is_empty():
		return out
	if control_points.size() == 1:
		out.append(control_points[0] as Vector3)
		return out
	var flexible: bool = bool(style.get("flexible", true))
	var sag_amount: float = float(style.get("sag_amount", 0.3))
	var drape: bool = bool(style.get("ground_drape", false)) and ground_y_fn.is_valid()
	for span: int in range(control_points.size() - 1):
		var start: Vector3 = control_points[span] as Vector3
		var end: Vector3 = control_points[span + 1] as Vector3
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
				if drape:
					var floor_y: float = float(ground_y_fn.call(pos)) + DRAPE_CLEARANCE_M
					if pos.y < floor_y:
						pos.y = floor_y
			out.append(pos)
	return out


## Light-string build: tube mesh plus evenly spaced bulb transforms along the
## sampled catenary. Returns {mesh, material, arc_length_m, sample_points,
## bulb_positions: PackedVector3Array}. Continuous strips (bulb_spacing_m == 0)
## return no bulb positions — the strip itself is made emissive by the caller.
static func build_light_string(control_points: Array, type_id: String,
		segments_per_span: int = DEFAULT_SEGMENTS_PER_SPAN,
		ground_y_fn: Callable = Callable()) -> Dictionary:
	var built := build(control_points, type_id, segments_per_span, ground_y_fn)
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
