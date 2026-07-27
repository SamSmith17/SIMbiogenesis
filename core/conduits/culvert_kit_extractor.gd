extends SceneTree

## Bake corrugated PE culvert ring module from the 8″ reference GLB → per-size kits.
## Run (after --import):
##   Godot.exe.exe --headless --path . --script core/conduits/culvert_kit_extractor.gd

const SRC_GLB := "res://Imported Models/PipeFittings/culvert_pe_8in.glb"
const OUT_DIR := "res://core/conduits/data/"
const FAMILY := "pe_culvert"
const REF_SIZE_IN := 8.0
const REVISION := 1
const SIZES_IN := [4.0, 6.0, 8.0, 10.0, 12.0, 15.0, 18.0, 21.0, 24.0]


func _initialize() -> void:
	if not ResourceLoader.exists(SRC_GLB):
		push_error("CulvertKitExtractor: missing %s — run --import first" % SRC_GLB)
		quit(1)
		return
	var packed := load(SRC_GLB) as PackedScene
	if packed == null:
		push_error("CulvertKitExtractor: failed to load PackedScene")
		quit(1)
		return
	var root := packed.instantiate() as Node3D
	var host := Node3D.new()
	get_root().add_child(host)
	host.add_child(root)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var rings := _collect_ring_groups(root)
	if rings.is_empty():
		push_error("CulvertKitExtractor: no corrugation rings found")
		quit(1)
		return
	rings.sort_custom(func(a, b): return float(a["axis_t"]) < float(b["axis_t"]))
	print("CulvertKitExtractor: found %d rings" % rings.size())

	# Pitch from median spacing along the pipe axis (world metres).
	var pitch_ref := _median_pitch(rings)
	if pitch_ref < 1e-4:
		push_error("CulvertKitExtractor: bad pitch %.6f" % pitch_ref)
		quit(1)
		return
	print("CulvertKitExtractor: ref pitch=%.5f m" % pitch_ref)

	# Bake a single mid-ring (both Geom3D halves) into +Z canonical frame.
	var mid_i := rings.size() / 2
	var ring0: Dictionary = rings[mid_i]
	var canon := _canonicalize_ring(ring0)
	if canon.is_empty():
		push_error("CulvertKitExtractor: canonicalize failed")
		quit(1)
		return
	var od_ref := float(canon["od_m"])
	var ring_len := float(canon["length_m"])
	print("CulvertKitExtractor: ref OD=%.4f m ring_len=%.4f m" % [od_ref, ring_len])

	var shared_mesh_path := OUT_DIR + "pipe_kit_%s_ring_ref.res" % FAMILY
	var save_err := ResourceSaver.save(canon["mesh"], shared_mesh_path)
	if save_err != OK:
		push_error("CulvertKitExtractor: save ring failed (%d)" % save_err)
		quit(1)
		return
	print("CulvertKitExtractor: wrote %s" % shared_mesh_path)

	var baked := 0
	for size_in: float in SIZES_IN:
		var scale := size_in / REF_SIZE_IN
		var token := _size_token(size_in)
		var kit_id := "%s_%s" % [FAMILY, token]
		# Per-size mesh = uniformly scaled copy of the reference ring.
		var scaled := _scale_mesh(canon["mesh"] as ArrayMesh, scale)
		var mesh_path := OUT_DIR + "pipe_kit_%s_part_ring.res" % kit_id
		save_err = ResourceSaver.save(scaled, mesh_path)
		if save_err != OK:
			push_error("CulvertKitExtractor: save %s failed (%d)" % [mesh_path, save_err])
			continue
		var kit := {
			"kit_id": kit_id,
			"family": FAMILY,
			"size_in": size_in,
			"revision": REVISION,
			"source_glb": SRC_GLB,
			"ref_size_in": REF_SIZE_IN,
			"nominal_od_m": od_ref * scale,
			"pitch_m": pitch_ref * scale,
			"ring_length_m": ring_len * scale,
			"ring_mesh_res": mesh_path,
			"parts": {
				"ring": {
					"mesh_res": mesh_path,
					"od_m": od_ref * scale,
					"pitch_m": pitch_ref * scale,
					"length_m": ring_len * scale,
				}
			},
		}
		var json_path := OUT_DIR + "pipe_kit_%s.json" % kit_id
		var jf := FileAccess.open(json_path, FileAccess.WRITE)
		if jf == null:
			push_error("CulvertKitExtractor: cannot write %s" % json_path)
			continue
		jf.store_string(JSON.stringify(kit, "\t"))
		jf.close()
		print("CulvertKitExtractor: wrote %s (OD=%.3f pitch=%.4f)" % [
			json_path, od_ref * scale, pitch_ref * scale])
		baked += 1

	host.queue_free()
	if baked < SIZES_IN.size():
		push_error("CulvertKitExtractor: baked %d/%d" % [baked, SIZES_IN.size()])
		quit(1)
		return
	print("CulvertKitExtractor: DONE — %d culvert kits" % baked)
	quit(0)


func _size_token(size_in: float) -> String:
	var whole := int(floor(size_in + 1e-6))
	if absf(size_in - float(whole)) < 0.01:
		return str(whole)
	return str(size_in).replace(".", "_")


## Group Geom3D meshes that share a corrugation ring (same 33_* ancestor).
func _collect_ring_groups(root: Node3D) -> Array:
	var groups: Dictionary = {}  ## key → {axis_t, nodes: Array[MeshInstance3D], xforms}
	_walk_rings(root, Transform3D.IDENTITY, groups)
	var out: Array = []
	for k: Variant in groups.keys():
		out.append(groups[k])
	return out


func _walk_rings(n: Node, xf: Transform3D, groups: Dictionary) -> void:
	var next := xf
	if n is Node3D:
		next = xf * (n as Node3D).transform
	if n is MeshInstance3D and n.name.begins_with("Geom3D"):
		# Ring key = nearest ancestor named like "33" / "33_1" / "33_12".
		var key := _ring_key(n)
		var world_c := next.origin
		# Pipe length is along world Y for this asset.
		var axis_t := world_c.y
		if not groups.has(key):
			groups[key] = {
				"key": key,
				"axis_t": axis_t,
				"meshes": [],
				"xforms": [],
			}
		(groups[key]["meshes"] as Array).append(n)
		(groups[key]["xforms"] as Array).append(next)
		# Keep mean axis_t.
		var g: Dictionary = groups[key]
		var nmesh: int = (g["meshes"] as Array).size()
		g["axis_t"] = (float(g["axis_t"]) * float(nmesh - 1) + axis_t) / float(nmesh)
	for c: Node in n.get_children():
		_walk_rings(c, next, groups)


func _ring_key(n: Node) -> String:
	var cur: Node = n
	while cur != null:
		var nm := str(cur.name)
		if nm.begins_with("33"):
			return nm
		cur = cur.get_parent()
	return str(n.get_path())


func _median_pitch(rings: Array) -> float:
	if rings.size() < 2:
		return 0.0
	var gaps: Array = []
	for i: int in range(1, rings.size()):
		var d := absf(float(rings[i]["axis_t"]) - float(rings[i - 1]["axis_t"]))
		if d > 1e-4:
			gaps.append(d)
	if gaps.is_empty():
		return 0.0
	gaps.sort()
	return float(gaps[gaps.size() / 2])


func _canonicalize_ring(ring: Dictionary) -> Dictionary:
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var meshes: Array = ring.get("meshes", []) as Array
	var xforms: Array = ring.get("xforms", []) as Array
	for i: int in range(meshes.size()):
		var mi: MeshInstance3D = meshes[i] as MeshInstance3D
		var xf: Transform3D = xforms[i] as Transform3D
		if mi == null or mi.mesh == null:
			continue
		_append_mesh(mi.mesh, xf, verts, indices)
	if verts.size() < 9:
		return {}
	# Centroid → origin; pipe axis was world Y → map to +Z.
	var c := Vector3.ZERO
	for v: Vector3 in verts:
		c += v
	c /= float(verts.size())
	var mapped := PackedVector3Array()
	mapped.resize(verts.size())
	for i: int in range(verts.size()):
		var p: Vector3 = verts[i] - c
		# (x, y, z)_world → (x, z, y) so former Y length becomes +Z.
		mapped[i] = Vector3(p.x, p.z, p.y)
	var mn := mapped[0]
	var mx := mapped[0]
	for v: Vector3 in mapped:
		mn = mn.min(v)
		mx = mx.max(v)
	var size := mx - mn
	var od_m := maxf(size.x, size.y)
	var length_m := size.z
	# Center in XY, keep Z span about 0.
	var mid_xy := Vector2((mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5)
	var mid_z := (mn.z + mx.z) * 0.5
	for i: int in range(mapped.size()):
		mapped[i] = Vector3(mapped[i].x - mid_xy.x, mapped[i].y - mid_xy.y,
			mapped[i].z - mid_z)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var i := 0
	while i + 2 < indices.size():
		st.add_vertex(mapped[indices[i]])
		st.add_vertex(mapped[indices[i + 1]])
		st.add_vertex(mapped[indices[i + 2]])
		i += 3
	st.generate_normals()
	var am := st.commit()
	am = PipeKit.crease_normals(am, 40.0)
	return {
		"mesh": am,
		"od_m": od_m,
		"length_m": length_m,
	}


func _append_mesh(mesh: Mesh, xform: Transform3D,
		verts: PackedVector3Array, indices: PackedInt32Array) -> void:
	for s: int in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var base := verts.size()
		for p: Vector3 in v:
			verts.append(xform * p)
		var ind: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
				if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if ind.is_empty():
			for i: int in range(v.size()):
				indices.append(base + i)
		else:
			for ii: int in ind:
				indices.append(base + ii)


func _scale_mesh(src: ArrayMesh, s: float) -> ArrayMesh:
	if src == null:
		return null
	if absf(s - 1.0) < 1e-6:
		return src.duplicate(true) as ArrayMesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for surf: int in range(src.get_surface_count()):
		var arr := src.surface_get_arrays(surf)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] \
				if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var ind: PackedInt32Array = arr[Mesh.ARRAY_INDEX] \
				if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if ind.is_empty():
			for i: int in range(v.size()):
				if i < nrm.size():
					st.set_normal(nrm[i])
				st.add_vertex(v[i] * s)
		else:
			for ii: int in ind:
				if ii < nrm.size():
					st.set_normal(nrm[ii])
				st.add_vertex(v[ii] * s)
	return st.commit()
