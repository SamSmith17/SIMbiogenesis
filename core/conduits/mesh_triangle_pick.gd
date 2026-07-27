class_name MeshTrianglePick
extends RefCounted

## Pure-math triangle raycast against MeshInstance3D children (no physics).
## Used by the Connection Port studio modal.


## Cast a ray against all MeshInstance3D under `root`. Returns:
## {valid, position, normal, mesh_path, distance} or {valid: false}.
static func pick(root: Node3D, origin: Vector3, direction: Vector3,
		max_tris: int = 0) -> Dictionary:
	var best := {"valid": false}
	if root == null or direction.length_squared() < 1e-12:
		return best
	var dir := direction.normalized()
	var best_t := INF
	var budget := max_tris
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var hit := pick_mesh_instance(mi, origin, dir, budget)
		if bool(hit.get("valid", false)) and float(hit.get("distance", INF)) < best_t:
			best_t = float(hit["distance"])
			best = hit
		if budget > 0 and int(hit.get("tris_tested", 0)) > 0:
			budget = maxi(0, budget - int(hit.get("tris_tested", 0)))
			if budget <= 0:
				break
	return best


## Approximate triangle count (indexed or non-indexed) for budget gates.
static func estimate_triangle_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for s: int in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(s)
		if arrays.is_empty():
			continue
		var idxs: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if not idxs.is_empty():
			total += idxs.size() / 3
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		total += verts.size() / 3
	return total


## max_tris: 0 = unlimited; >0 aborts after that many tests (may return miss).
static func pick_mesh_instance(mi: MeshInstance3D, origin: Vector3,
		direction: Vector3, max_tris: int = 0) -> Dictionary:
	var out := {"valid": false, "tris_tested": 0}
	if mi == null or mi.mesh == null:
		return out
	var mesh: Mesh = mi.mesh
	var xform: Transform3D = _node_xform(mi)
	var inv := xform.affine_inverse()
	var local_o: Vector3 = inv * origin
	var local_d: Vector3 = inv.basis * direction
	if local_d.length_squared() < 1e-12:
		return out
	local_d = local_d.normalized()
	var best_t := INF
	var best_pos := Vector3.ZERO
	var best_n := Vector3.UP
	var tested := 0
	var budget := max_tris if max_tris > 0 else 0x3fffffff
	for s: int in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(s)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idxs: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if verts.is_empty():
			continue
		if idxs.is_empty():
			var i := 0
			while i + 2 < verts.size():
				tested += 1
				if tested > budget:
					out["tris_tested"] = tested
					return out
				var hit := _ray_tri(local_o, local_d, verts[i], verts[i + 1], verts[i + 2])
				if hit.t < best_t:
					best_t = hit.t
					best_pos = hit.pos
					best_n = hit.n
				i += 3
		else:
			var j := 0
			while j + 2 < idxs.size():
				tested += 1
				if tested > budget:
					out["tris_tested"] = tested
					# Return best-so-far if we already have a hit.
					if best_t < INF:
						break
					return out
				var a: Vector3 = verts[idxs[j]]
				var b: Vector3 = verts[idxs[j + 1]]
				var c: Vector3 = verts[idxs[j + 2]]
				var hit2 := _ray_tri(local_o, local_d, a, b, c)
				if hit2.t < best_t:
					best_t = hit2.t
					best_pos = hit2.pos
					best_n = hit2.n
				j += 3
		if tested > budget and best_t < INF:
			break
	out["tris_tested"] = tested
	if best_t >= INF:
		return out
	var world_pos: Vector3 = xform * best_pos
	var world_n: Vector3 = (xform.basis * best_n).normalized()
	# Face the ray if winding put the normal away from the camera.
	if world_n.dot(direction) > 0.0:
		world_n = -world_n
	var path_str := mi.name
	if mi.is_inside_tree():
		path_str = str(mi.get_path())
	return {
		"valid": true,
		"position": world_pos,
		"normal": world_n,
		"local_position": best_pos,
		"local_normal": (inv.basis * world_n).normalized(),
		"mesh_path": path_str,
		"distance": origin.distance_to(world_pos),
		"tris_tested": tested,
	}


static func _node_xform(node: Node3D) -> Transform3D:
	if node == null:
		return Transform3D.IDENTITY
	if node.is_inside_tree():
		return node.global_transform
	var xf := node.transform
	var p := node.get_parent()
	while p is Node3D:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


## Möller–Trumbore. Returns {t, pos, n}; t=INF on miss.
static func _ray_tri(o: Vector3, d: Vector3, v0: Vector3, v1: Vector3, v2: Vector3) -> Dictionary:
	const EPS := 1e-8
	var e1 := v1 - v0
	var e2 := v2 - v0
	var pvec := d.cross(e2)
	var det := e1.dot(pvec)
	if absf(det) < EPS:
		return {"t": INF, "pos": Vector3.ZERO, "n": Vector3.UP}
	var inv_det := 1.0 / det
	var tvec := o - v0
	var u := tvec.dot(pvec) * inv_det
	if u < 0.0 or u > 1.0:
		return {"t": INF, "pos": Vector3.ZERO, "n": Vector3.UP}
	var qvec := tvec.cross(e1)
	var v := d.dot(qvec) * inv_det
	if v < 0.0 or u + v > 1.0:
		return {"t": INF, "pos": Vector3.ZERO, "n": Vector3.UP}
	var t := e2.dot(qvec) * inv_det
	if t < EPS:
		return {"t": INF, "pos": Vector3.ZERO, "n": Vector3.UP}
	var n := e1.cross(e2).normalized()
	return {"t": t, "pos": o + d * t, "n": n}
