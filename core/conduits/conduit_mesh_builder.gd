class_name ConduitMeshBuilder
extends RefCounted

## Builds a tube ArrayMesh along a 3D path with optional catenary sag (flexible
## conduits) or straight/elbowed segments (rigid). Pure geometry — headless-testable.

const DEFAULT_RADIAL_SEGMENTS := 8
const DEFAULT_SEGMENTS_PER_SPAN := 12


## Full build: control points → {mesh, material, arc_length_m, sample_points}.
static func build(control_points: Array, type_id: String,
		segments_per_span: int = DEFAULT_SEGMENTS_PER_SPAN) -> Dictionary:
	var style: Dictionary = ConduitKinds.type_meta(type_id)
	var samples := sample_path(control_points, style, segments_per_span)
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
static func sample_path(control_points: Array, style: Dictionary,
		segments_per_span: int = DEFAULT_SEGMENTS_PER_SPAN) -> PackedVector3Array:
	var out := PackedVector3Array()
	if control_points.is_empty():
		return out
	if control_points.size() == 1:
		out.append(control_points[0] as Vector3)
		return out
	var flexible: bool = bool(style.get("flexible", true))
	var sag_amount: float = float(style.get("sag_amount", 0.3))
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
			out.append(pos)
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
