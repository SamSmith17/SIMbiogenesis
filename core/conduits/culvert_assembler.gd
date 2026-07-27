class_name CulvertAssembler
extends RefCounted

## Procedural PE culvert: swept barrel + lightweight corrugation ribs along a
## CulvertRouter centerline. Equal arc-length pitch → ribs pack on the inside
## of wide bends (real dual-wall HDPE flex), without discrete elbow fittings.
## Replaces the heavy GLB ring MultiMesh (~950 tris/ring) that capped FPS.

const HOST_PREFIX := "CulvertParts_"
## Cheap procedural ribs (~48–64 tris each) — denser than the old GLB cap.
const MAX_RINGS := 500
const VISIBILITY_END_M := 280.0
const BARREL_RADIAL := 10
const RIB_RADIAL := 10
## Max samples for the swept barrel (independent of rib pitch).
const BARREL_MAX_SAMPLES := 64
## Soft tris budget for harness / selftest (barrel + ribs).
const MAX_TRIS_BUDGET := 50000

## Shared rib meshes keyed by "od_mm_pitch_mm" so rebuilds don't remesh.
static var _rib_mesh_cache: Dictionary = {}


static func ensure_host(parent: Node, cid: String) -> Node3D:
	var name := HOST_PREFIX + cid
	var existing := parent.get_node_or_null(name) as Node3D
	if existing != null:
		return existing
	var host := Node3D.new()
	host.name = name
	parent.add_child(host)
	return host


static func clear(parent: Node, cid: String) -> void:
	var host := parent.get_node_or_null(HOST_PREFIX + cid)
	if host != null:
		parent.remove_child(host)
		host.free()


## Build barrel + ribs. Returns {ok, centerline, ring_count, approx_tris}.
## `kit.ring_mesh` is unused (kit still supplies OD / pitch / bend).
static func apply(parent: Node, cid: String, centerline: PackedVector3Array,
		kit: CulvertKit, material: Material) -> Dictionary:
	clear(parent, cid)
	var result := {
		"ok": false, "centerline": PackedVector3Array(), "ring_count": 0, "approx_tris": 0,
	}
	if kit == null or centerline.size() < 2:
		return result
	var od := maxf(kit.nominal_od_m, 0.05)
	var radius := od * 0.5
	var pitch := maxf(kit.pitch_m, 0.02)
	var path_len := _polyline_length(centerline)
	# True pitch for look; only stretch when over the instance ceiling.
	if path_len > pitch * float(MAX_RINGS):
		pitch = path_len / float(MAX_RINGS)
	var samples := _sample_at_pitch(centerline, pitch)
	if samples.size() < 2:
		return result
	var xforms := _ring_transforms(samples)
	if xforms.is_empty():
		return result
	if xforms.size() > MAX_RINGS:
		var decimated: Array = [xforms[0]]
		var step := float(xforms.size() - 1) / float(MAX_RINGS - 1)
		for i in range(1, MAX_RINGS - 1):
			decimated.append(xforms[int(round(step * float(i)))])
		decimated.append(xforms[xforms.size() - 1])
		xforms = decimated
	var host := ensure_host(parent, cid)

	# Continuous barrel — coarsen long polylines so tube rings stay cheap.
	var barrel_path := centerline
	if centerline.size() > BARREL_MAX_SAMPLES:
		var b_pitch := maxf(path_len / float(BARREL_MAX_SAMPLES - 1), 0.25)
		barrel_path = _sample_at_pitch(centerline, b_pitch)
	var barrel_mesh := ConduitMeshBuilder.build_tube(barrel_path, radius, BARREL_RADIAL)
	var barrel_tris := _mesh_tri_count(barrel_mesh)
	if barrel_mesh.get_surface_count() > 0:
		var barrel_mi := MeshInstance3D.new()
		barrel_mi.name = "Barrel"
		barrel_mi.mesh = barrel_mesh
		barrel_mi.material_override = material
		barrel_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		barrel_mi.visibility_range_begin = 0.0
		barrel_mi.visibility_range_end = VISIBILITY_END_M
		host.add_child(barrel_mi)

	# Corrugation ribs — tiny annulus MultiMesh.
	var rib_mesh := _rib_mesh_for(od, pitch)
	var rib_tris_each := _mesh_tri_count(rib_mesh)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = rib_mesh
	mm.instance_count = xforms.size()
	for i: int in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i] as Transform3D)
	var inst := MultiMeshInstance3D.new()
	inst.name = "MM_rings"
	inst.multimesh = mm
	inst.material_override = material
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.visibility_range_begin = 0.0
	inst.visibility_range_end = VISIBILITY_END_M
	host.add_child(inst)

	var approx := barrel_tris + rib_tris_each * xforms.size()
	result["ok"] = true
	result["centerline"] = samples
	result["ring_count"] = xforms.size()
	result["approx_tris"] = approx
	return result


static func _polyline_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i: int in range(path.size() - 1):
		total += path[i].distance_to(path[i + 1])
	return total


static func _mesh_tri_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var n := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var idx: Variant = arr[Mesh.ARRAY_INDEX] if arr.size() > Mesh.ARRAY_INDEX else null
		if idx is PackedInt32Array and (idx as PackedInt32Array).size() >= 3:
			n += (idx as PackedInt32Array).size() / 3
		else:
			var verts: Variant = arr[Mesh.ARRAY_VERTEX]
			if verts is PackedVector3Array:
				n += (verts as PackedVector3Array).size() / 3
	return n


## Short annulus rib; local +Z = pipe axis (matches `_ring_transforms`).
static func _rib_mesh_for(od_m: float, pitch_m: float) -> ArrayMesh:
	var key := "%d_%d" % [int(round(od_m * 1000.0)), int(round(pitch_m * 1000.0))]
	if _rib_mesh_cache.has(key):
		return _rib_mesh_cache[key] as ArrayMesh
	var mesh := _build_rib_mesh(od_m, pitch_m)
	_rib_mesh_cache[key] = mesh
	return mesh


static func _build_rib_mesh(od_m: float, pitch_m: float) -> ArrayMesh:
	var r_mid := maxf(od_m * 0.5, 0.02)
	var r_inner := r_mid * 0.92
	var r_outer := r_mid * 1.06
	var half_w := clampf(pitch_m * 0.18, 0.006, 0.04)
	var segs := RIB_RADIAL
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	# Two rings (back/front) × outer+inner = 4 vertex rings.
	for zi in 2:
		var z := -half_w if zi == 0 else half_w
		for ri in 2:
			var r := r_outer if ri == 0 else r_inner
			for s in segs:
				var a := TAU * float(s) / float(segs)
				var nrm := Vector3(cos(a), sin(a), 0.0)
				verts.append(nrm * r + Vector3(0.0, 0.0, z))
				norms.append(nrm if ri == 0 else -nrm)
				uvs.append(Vector2(float(s) / float(segs), float(zi)))
	# Outer cylinder wall
	for s in segs:
		var s1 := (s + 1) % segs
		var a0 := s
		var a1 := s1
		var b0 := s + segs * 2
		var b1 := s1 + segs * 2
		idx.append_array([a0, b0, a1, a1, b0, b1])
	# Inner cylinder wall (wound opposite)
	var off := segs
	for s in segs:
		var s1 := (s + 1) % segs
		var a0 := off + s
		var a1 := off + s1
		var b0 := off + s + segs * 2
		var b1 := off + s1 + segs * 2
		idx.append_array([a0, a1, b0, a1, b1, b0])
	# Front/back annular faces
	for zi in 2:
		var base := zi * segs * 2
		for s in segs:
			var s1 := (s + 1) % segs
			var o0 := base + s
			var o1 := base + s1
			var i0 := base + segs + s
			var i1 := base + segs + s1
			if zi == 0:
				idx.append_array([o0, i0, o1, o1, i0, i1])
			else:
				idx.append_array([o0, o1, i0, o1, i1, i0])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## Resample polyline to approximately `pitch` spacing (includes endpoints).
static func _sample_at_pitch(path: PackedVector3Array, pitch: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if path.size() < 2:
		return out
	var total := 0.0
	var seg_lens: PackedFloat32Array = PackedFloat32Array()
	seg_lens.resize(path.size() - 1)
	for i: int in range(path.size() - 1):
		var L := path[i].distance_to(path[i + 1])
		seg_lens[i] = L
		total += L
	if total < pitch * 0.5:
		out.append(path[0])
		out.append(path[path.size() - 1])
		return out
	var n := maxi(int(round(total / pitch)), 1)
	var step := total / float(n)
	out.append(path[0])
	var along := step
	var seg_i := 0
	var seg_start := 0.0
	while along < total - step * 0.25 and out.size() < n + 2:
		while seg_i < seg_lens.size() - 1 and along > seg_start + seg_lens[seg_i]:
			seg_start += seg_lens[seg_i]
			seg_i += 1
		var sl := maxf(seg_lens[seg_i], 1e-6)
		var u := (along - seg_start) / sl
		out.append(path[seg_i].lerp(path[seg_i + 1], clampf(u, 0.0, 1.0)))
		along += step
	var last: Vector3 = path[path.size() - 1]
	if out[out.size() - 1].distance_to(last) > pitch * 0.2:
		out.append(last)
	else:
		out[out.size() - 1] = last
	return out


## Parallel-transport frames: ring +Z along tangent, minimal twist.
static func _ring_transforms(samples: PackedVector3Array) -> Array:
	var out: Array = []
	if samples.size() < 2:
		return out
	var up := Vector3.UP
	for i: int in range(samples.size()):
		var tang: Vector3
		if i == 0:
			tang = samples[1] - samples[0]
		elif i == samples.size() - 1:
			tang = samples[i] - samples[i - 1]
		else:
			tang = samples[i + 1] - samples[i - 1]
		if tang.length_squared() < 1e-12:
			continue
		tang = tang.normalized()
		var right := up.cross(tang)
		if right.length_squared() < 1e-8:
			right = Vector3.RIGHT.cross(tang)
		right = right.normalized()
		var bil := tang.cross(right).normalized()
		right = bil.cross(tang).normalized()
		var basis := Basis(right, bil, tang)
		out.append(Transform3D(basis, samples[i]))
		up = bil
	return out
