class_name MeshCollisionUtil
extends RefCounted

## Sanitizes a triangle-soup PackedVector3Array (as returned by Mesh.get_faces(),
## or assembled by hand) before it is handed to ConcavePolygonShape3D.set_faces().
##
## Feeding non-finite (NaN/inf) vertices or zero-area triangles to the physics
## server is a known hard-crash vector in Godot — and procedural meshes
## (conduits, linkage frames) or imported STL parts (OpenSCAD hardware store)
## can produce exactly those. This filter drops the offending triangles and
## returns a clean soup; if nothing survives it returns an empty array so the
## caller can skip building a shape at all.

const MIN_TRI_EDGE_CROSS := 1e-6  ## |(b-a)×(c-a)| threshold ≈ 2·area (m²)


## Returns a copy of `faces` with every non-finite or degenerate triangle removed.
## Input length is truncated to a multiple of 3.
static func sanitize_faces(faces: PackedVector3Array) -> PackedVector3Array:
	var n := faces.size()
	if n < 3:
		return PackedVector3Array()
	var out := PackedVector3Array()
	out.resize(n - (n % 3))
	var w := 0
	var i := 0
	while i + 2 < n:
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		if _finite(a) and _finite(b) and _finite(c) \
				and (b - a).cross(c - a).length() > MIN_TRI_EDGE_CROSS:
			out[w] = a
			out[w + 1] = b
			out[w + 2] = c
			w += 3
		i += 3
	out.resize(w)
	return out


static func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)
