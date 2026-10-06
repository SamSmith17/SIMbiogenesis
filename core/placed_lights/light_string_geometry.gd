class_name LightStringGeometry
extends RefCounted

## Shape of a J-placed string light — pure, no scene access beyond the
## optional ground callable.
##
## Deliberately built on the SAME sampler the graph's lights-as-wires conduits
## use (ConduitMeshBuilder.sample_path: a parabolic sag per span between pins,
## clamped to the ground where the sag would tunnel, and bulb_positions_along:
## arc-length spacing starting half a spacing in), so a J string and a
## graph-wired patio string hang identically and there is one catenary to fix.

const SEGMENTS_PER_SPAN := 12


## points: Array[Vector3] world pins. fields: resolved style (sag, spacing…).
## ground_fn: Callable(Vector3) -> float, or invalid for free air.
## Returns {samples: PackedVector3Array, bulbs: PackedVector3Array, length_m}.
static func build(points: Array, fields: Dictionary, ground_fn: Callable = Callable()) -> Dictionary:
	var out := {"samples": PackedVector3Array(), "bulbs": PackedVector3Array(), "length_m": 0.0}
	if points.size() < 2:
		return out
	var style := {
		"flexible": true,
		"ground_drape": false,
		"sag_amount": clampf(float(fields.get("sag", 0.35)), 0.0, 2.0),
		"terrain_clamp": ground_fn.is_valid(),
	}
	var samples := ConduitMeshBuilder.sample_path(points, style, SEGMENTS_PER_SPAN, ground_fn)
	out["samples"] = samples
	out["length_m"] = ConduitKinds.polyline_length_m(samples)
	out["bulbs"] = ConduitMeshBuilder.bulb_positions_along(samples,
		maxf(float(fields.get("bulb_spacing_m", 0.9)), 0.01))
	return out


## Evenly spread `count` indices over `n` bulbs (the real OmniLights).
static func light_indices(n: int, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if n <= 0 or count <= 0:
		return out
	count = mini(count, n)
	for k in count:
		out.append(int(floor((float(k) + 0.5) * float(n) / float(count))))
	return out


## Nearest point on the polyline to a ray, for "insert a pin on the wire":
## returns {dist, span, point} where span is the index of the pin BEFORE it.
static func nearest_span(points: Array, samples: PackedVector3Array,
		ray_o: Vector3, ray_d: Vector3) -> Dictionary:
	var best := {"dist": LightGizmoMath.INF_DIST, "span": -1, "point": Vector3.ZERO, "t": 0.0}
	if samples.size() < 2 or points.size() < 2:
		return best
	for i in range(1, samples.size()):
		var r := LightGizmoMath.ray_segment(ray_o, ray_d, samples[i - 1], samples[i])
		if float(r["dist"]) < float(best["dist"]):
			var seg_dir := (samples[i] - samples[i - 1]).normalized()
			best["dist"] = r["dist"]
			best["point"] = samples[i - 1] + seg_dir * float(r.get("s", 0.0))
			best["t"] = r["t"]
			# Span = the pin interval this sample index falls in.
			best["span"] = mini(int(float(i - 1) / float(SEGMENTS_PER_SPAN)), points.size() - 2)
	return best


## A round tube along `samples` whose UV.x is the ARC LENGTH in metres (UV.y
## goes round the tube) — the continuous presets' shader places pixel i at
## i / leds_per_m along it. Parallel-transported ring frames so the tube does
## not twist at bends. Drawn cull_disabled, so winding does not matter.
static func build_tube(samples: PackedVector3Array, radius: float, sides: int = 8) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if samples.size() < 2 or radius <= 0.0:
		return mesh
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var arc := 0.0
	var t0 := (samples[1] - samples[0]).normalized()
	var ref := Vector3.UP if absf(t0.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var nrm := t0.cross(ref).normalized()
	for i in samples.size():
		if i > 0:
			arc += samples[i].distance_to(samples[i - 1])
		var tng := (samples[mini(i + 1, samples.size() - 1)] - samples[maxi(i - 1, 0)]).normalized()
		if tng.length_squared() < 1e-8:
			tng = t0
		# Parallel transport: remove the tangent component, keep the old normal.
		nrm = (nrm - tng * nrm.dot(tng)).normalized()
		if nrm.length_squared() < 1e-8:
			nrm = tng.cross(ref).normalized()
		var bin := tng.cross(nrm).normalized()
		for k in sides + 1:
			var a := TAU * float(k) / float(sides)
			var dirv := nrm * cos(a) + bin * sin(a)
			verts.append(samples[i] + dirv * radius)
			norms.append(dirv)
			uvs.append(Vector2(arc, float(k) / float(sides)))
	var ring := sides + 1
	for i in samples.size() - 1:
		for k in sides:
			var a0 := i * ring + k
			var b0 := (i + 1) * ring + k
			idx.append_array([a0, b0, a0 + 1, a0 + 1, b0, b0 + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
