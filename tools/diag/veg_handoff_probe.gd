extends RefCounted

## Sandbox, read-only: how many full-detail trees does the mesh / impostor
## handoff draw, and how near do impostors come?
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/veg_handoff_probe.gd
##
## Godot decides a MultiMesh's visibility range from the distance to the
## node's AABB centre, and tree batches are cut into 256 m chunks, so the
## detail ring is ragged: trees far past the detail distance draw as meshes
## when their chunk's centre is near, and trees well inside it draw as
## impostors when it is not. From camera spots spread through the forest
## this prints, per spot, the mesh trees drawn now, with an exact per-tree
## ring at the same distance, and with 64 m cells; their triangles; a
## screen-area proxy (sum of 1/r^2); and the nearest impostor drawn.
## Fade bands are ignored (a node counts while its centre is inside the range).

const SPOTS := 320
var SUB_M := float(OS.get_environment("VEGPROBE_SUB")) if OS.get_environment("VEGPROBE_SUB") != "" else 64.0


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var meshes: Array = []
	var imps: Array = []
	for _w in 40:
		for _i in 15:
			await tree.process_frame
		meshes.clear()
		imps.clear()
		_scan(main, meshes, imps)
		if not meshes.is_empty():
			break
	if meshes.is_empty():
		return {"ok": false, "why": "no mesh-tier tree batches"}
	var detail := 0.0
	var n_inst := 0
	for m in meshes:
		detail = maxf(detail, float(m["end"]))
		n_inst += (m["pos"] as PackedVector3Array).size()
	var n_imp := 0
	for m in imps:
		n_imp += (m["pos"] as PackedVector3Array).size()
	print("vegprobe nodes: %d mesh, %d impostor; trees %d mesh-tier, %d impostor-tier; detail %.1f m" % [
		meshes.size(), imps.size(), n_inst, n_imp, detail])
	var ends := {}
	for m in meshes:
		var key := "%s end %.0f" % [str(m["name"]).get_slice("_", 1), float(m["end"])]
		ends[key] = int(ends.get(key, 0)) + (m["pos"] as PackedVector3Array).size()
	for m in imps:
		var key := "%s begin %.0f end %.0f" % [str(m["name"]).get_slice("_", 1), float(m["begin"]), float(m["end"])]
		ends[key] = int(ends.get(key, 0)) + (m["pos"] as PackedVector3Array).size()
	for key in ends:
		print("vegprobe band %-40s trees %d" % [key, int(ends[key])])
	var st: Dictionary = loader.call("_auto_veg_runtime_settings")
	print("vegprobe settings detail %s eff %s budget %s auto_end %s" % [
		str(st.get("tree_detail_distance_m")), str(st.get("tree_detail_eff_m")),
		str(st.get("tree_near_budget")), str(st.get("auto_visibility_end_m"))])
	# Camera spots: beside trees, eye height above the ground.
	var all_pos := PackedVector3Array()
	for m in meshes:
		all_pos.append_array(m["pos"])
	var spots: Array = []
	var stride := maxi(1, all_pos.size() / SPOTS)
	var k := 0
	while k < all_pos.size() and spots.size() < SPOTS:
		var p := all_pos[k]
		var ang := float(k) * 2.399
		var x := p.x + cos(ang) * 4.0
		var z := p.z + sin(ang) * 4.0
		var gy := float(loader.call("ground_height_at", x, z))
		spots.append(Vector3(x, gy + 1.7, z))
		k += stride
	var rows := {"now": [], "exact": [], "sub": [], "tri_now": [], "tri_exact": [],
		"tri_sub": [], "area_now": [], "area_exact": [], "near_imp": [], "far_mesh": []}
	for c_v in spots:
		var c: Vector3 = c_v
		var n_now := 0
		var n_ex := 0
		var n_sub := 0
		var t_now := 0.0
		var t_ex := 0.0
		var t_sub := 0.0
		var a_now := 0.0
		var a_ex := 0.0
		var far_mesh := 0.0
		for m in meshes:
			var vis := c.distance_to(m["centre"]) < float(m["end"])
			var tris := float(m["tris"])
			var cy := (m["centre"] as Vector3).y
			for p in (m["pos"] as PackedVector3Array):
				var r := c.distance_to(p)
				var a := 1.0 / maxf(r * r, 25.0)
				if vis:
					n_now += 1
					t_now += tris
					a_now += a
					far_mesh = maxf(far_mesh, r)
				if r < float(m["end"]):
					n_ex += 1
					t_ex += tris
					a_ex += a
				var cell := Vector3((floor(p.x / SUB_M) + 0.5) * SUB_M, cy,
					(floor(p.z / SUB_M) + 0.5) * SUB_M)
				if c.distance_to(cell) < float(m["end"]):
					n_sub += 1
					t_sub += tris
		var near_imp := INF
		for m in imps:
			if c.distance_to(m["centre"]) < float(m["begin"]):
				continue
			for p in (m["pos"] as PackedVector3Array):
				near_imp = minf(near_imp, c.distance_to(p))
		rows["now"].append(n_now)
		rows["exact"].append(n_ex)
		rows["sub"].append(n_sub)
		rows["tri_now"].append(t_now)
		rows["tri_exact"].append(t_ex)
		rows["tri_sub"].append(t_sub)
		rows["area_now"].append(a_now)
		rows["area_exact"].append(a_ex)
		rows["near_imp"].append(near_imp if near_imp < INF else 9999.0)
		rows["far_mesh"].append(far_mesh)
	_frustum_pass(main, spots, meshes, imps, rows)
	for key in rows:
		var arr: Array = rows[key]
		arr.sort()
		var sum := 0.0
		for v in arr:
			sum += float(v)
		print("vegprobe %-10s mean %10.1f  p05 %10.1f  p50 %10.1f  p95 %10.1f  max %10.1f" % [
			key, sum / maxf(arr.size(), 1.0), float(arr[int(arr.size() * 0.05)]),
			float(arr[arr.size() / 2]), float(arr[int(arr.size() * 0.95)]),
			float(arr[arr.size() - 1])])
	return {"ok": true, "spots": spots.size()}


func _scan(n: Node, meshes: Array, imps: Array) -> void:
	for ch in n.get_children():
		_scan(ch, meshes, imps)
	if not (n is MultiMeshInstance3D) or not n.has_meta(&"veg_species"):
		return
	var mi := n as MultiMeshInstance3D
	if not mi.is_visible_in_tree() or mi.multimesh == null:
		return
	var fam := VegSpeciesCatalog.mesh_family(str(mi.get_meta(&"veg_species")))
	if fam != "pine" and fam != "deciduous":
		return
	var mm := mi.multimesh
	var xf := mi.global_transform
	var pos := PackedVector3Array()
	var boxes: Array = []
	var maabb := mm.mesh.get_aabb() if mm.mesh != null else AABB()
	for i in mm.instance_count:
		var ixf := xf * mm.get_instance_transform(i)
		pos.append(ixf.origin)
		boxes.append(ixf * maabb)
	var aabb := xf * mi.get_aabb()
	var tris := 0
	var am := mm.mesh as ArrayMesh
	if am != null:
		for s in am.get_surface_count():
			var idx: int = am.surface_get_array_index_len(s)
			tris += idx / 3 if idx > 0 else am.surface_get_array_len(s) / 3
	var rec := {"centre": aabb.get_center(), "begin": mi.visibility_range_begin,
		"end": mi.visibility_range_end, "pos": pos, "tris": tris, "name": str(mi.name),
		"aabb": aabb, "boxes": boxes}
	if mi.visibility_range_begin > 0.0:
		imps.append(rec)
	elif mi.visibility_range_end > 0.0 and mi.visibility_range_end < 2000.0:
		meshes.append(rec)


## Frustum-culled draw: tree triangles and draw calls the camera really
## submits, with the 256 m chunks as built and with 64 m cells.
func _frustum_pass(main: Node, spots: Array, meshes: Array, imps: Array, rows: Dictionary) -> void:
	var cam := main.get_viewport().get_camera_3d()
	var fov := cam.fov if cam != null else 75.0
	var probe := Camera3D.new()
	probe.fov = fov
	probe.near = 0.1
	probe.far = 3000.0
	main.add_child(probe)
	var sub_mesh := _split(meshes)
	var sub_imp := _split(imps)
	for key in ["ftri_now", "ftri_sub", "fdraw_now", "fdraw_sub", "fimp_now", "fimp_sub"]:
		rows[key] = []
	var k := 0
	for c_v in spots:
		var c: Vector3 = c_v
		var yaw := float(k) * 2.399
		k += 1
		var fwd := Vector3(sin(yaw), -0.08, cos(yaw)).normalized()
		probe.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), c)
		var planes: Array = probe.get_frustum()
		var ahead := c + fwd * 30.0
		var flip := 0
		for pl in planes:
			if (pl as Plane).distance_to(ahead) > 0.0:
				flip += 1
		var sg := -1.0 if flip > planes.size() / 2 else 1.0
		var r1 := _count(c, planes, sg, meshes, true)
		var r2 := _count(c, planes, sg, sub_mesh, true)
		var r3 := _count(c, planes, sg, imps, false)
		var r4 := _count(c, planes, sg, sub_imp, false)
		rows["ftri_now"].append(r1.x)
		rows["ftri_sub"].append(r2.x)
		rows["fdraw_now"].append(r1.y)
		rows["fdraw_sub"].append(r2.y)
		rows["fimp_now"].append(r3.y)
		rows["fimp_sub"].append(r4.y)
	probe.queue_free()


func _count(c: Vector3, planes: Array, sg: float, nodes: Array, mesh_tier: bool) -> Vector2:
	var tris := 0.0
	var draws := 0.0
	for m in nodes:
		var d := c.distance_to(m["centre"])
		if d >= float(m["end"]) or (not mesh_tier and d < float(m["begin"])):
			continue
		if not _in_frustum(m["aabb"], planes, sg):
			continue
		tris += float(m["tris"]) * float((m["pos"] as PackedVector3Array).size())
		draws += 1.0
	return Vector2(tris, draws)


## Outward planes (sg 1): the box is outside when its most-inside corner is
## in front of any plane.
func _in_frustum(b: AABB, planes: Array, sg: float) -> bool:
	for pl_v in planes:
		var pl: Plane = pl_v
		var n := pl.normal * sg
		var dd := pl.d * sg
		var q := Vector3(b.position.x if n.x > 0.0 else b.end.x,
			b.position.y if n.y > 0.0 else b.end.y,
			b.position.z if n.z > 0.0 else b.end.z)
		if n.dot(q) - dd > 0.0:
			return false
	return true


## The same instances regrouped by 64 m cell: one node per (batch, cell).
func _split(nodes: Array) -> Array:
	var out: Array = []
	for m in nodes:
		var groups := {}
		var pos: PackedVector3Array = m["pos"]
		var boxes: Array = m["boxes"]
		for i in pos.size():
			var key := Vector2i(int(floor(pos[i].x / SUB_M)), int(floor(pos[i].z / SUB_M)))
			if not groups.has(key):
				groups[key] = {"pos": PackedVector3Array(), "aabb": boxes[i]}
			var g: Dictionary = groups[key]
			var pa: PackedVector3Array = g["pos"]
			pa.append(pos[i])
			g["pos"] = pa
			g["aabb"] = (g["aabb"] as AABB).merge(boxes[i])
		for key in groups:
			var g: Dictionary = groups[key]
			out.append({"centre": (g["aabb"] as AABB).get_center(), "begin": m["begin"],
				"end": m["end"], "pos": g["pos"], "tris": m["tris"], "aabb": g["aabb"]})
	return out
