extends RefCounted

## Sandbox, nothing saved: what the tree detail distance and the full-mesh
## species cost, and what the options look like.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/veg_detail_options.gd -Label <dir> -Timeout 1800
##
## Prints the detail budget's arithmetic (the distance VegLodPolicy picks, the
## true worst-case number of full trees round a viewpoint at that distance,
## and a tighter 64 m estimate), then rebuilds the painted forest IN MEMORY
## four ways and, for each, measures 32 forest views (GPU / primitives /
## draws, as tools/bench/veg_spots_bench.gd) and saves six of them as PNGs:
##   A  as saved
##   B  the full-mesh species get the default mesh -> impostor chain
##   C  chains as saved, detail distance from the tighter estimate
##   D  B and C together
## The loader's own rebuilds are held off while it runs; the world is rebuilt
## as saved at the end.

const SPOTS := 16
const SHOTS := [0, 3, 6, 9, 12, 20]
const SETTLE_S := 0.8
const SAMPLE_S := 1.2
const CELL := 64.0
const SHRINK := 0.85


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var terrain := main.get_node_or_null("Terrain") as Node3D
	if loader == null or terrain == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	var trees := PackedVector3Array()
	for _w in 40:
		for _i in 15:
			await tree.process_frame
		trees = _tree_positions(main)
		if trees.size() > 0:
			break
	if trees.is_empty():
		return {"ok": false, "why": "no tree batches"}
	var layer: VegetationLayer = loader.get("_vegetation_layer")
	var ground := Callable(loader, "_ground_height_at")
	main.set("time_scale", 0.0)
	main.set("day_time", 12.0)
	await _wait_bakes(tree, loader)
	loader.set("_impostor_rebuild_pending", true)
	var s0: Dictionary = loader.call("_auto_veg_runtime_settings")
	var requested := float(s0.get("tree_detail_distance_m", 220.0))
	var budget := int(s0.get("tree_near_budget", 1500))

	# ── The budget's arithmetic ──
	var bulks: Array = [layer.bulk]
	var auto_layer: Variant = loader.get("_auto_veg_layer")
	if auto_layer != null:
		bulks.append((auto_layer as AutoVegetationLayer).bulk)
	var full_mesh: Array = []
	for b in bulks:
		for slot in (b as Dictionary):
			var sp := str(slot)
			var fam := VegSpeciesCatalog.mesh_family(sp)
			if fam != "pine" and fam != "deciduous":
				continue
			var chain := VegetationCardFactory.lod_chain(sp, s0)
			if chain == [VegLodPolicy.REP_MESH] or not VegetationCardFactory.canopy_lod_enabled(sp, s0):
				if sp not in full_mesh:
					full_mesh.append(sp)
	var d_cur := VegLodPolicy.effective_detail_distance(
		VegLodPolicy.chunk_tree_counts(bulks), requested, budget)
	var pts_all := _points(bulks, [])
	var pts_handoff := _points(bulks, full_mesh)
	print("vegopt requested %.0f m, budget %d, policy picks %.0f m; full-mesh species %s" % [
		requested, budget, d_cur, str(full_mesh)])
	print("vegopt trees: %d handoff, %d full-mesh" % [pts_handoff.size(),
		pts_all.size() - pts_handoff.size()])
	for d in [60.0, 100.0, 150.0, 220.0, 360.0]:
		print("vegopt true worst near set at %3.0f m: all species %5d  handoff species %5d" % [
			d, _worst_near(pts_all, d), _worst_near(pts_handoff, d)])
	var d_keep := _tight_distance(pts_handoff, requested, budget)
	var d_all := _tight_distance(pts_all, requested, budget)
	print("vegopt tighter 64 m estimate: %.0f m counting handoff species, %.0f m counting all" % [
		d_keep, d_all])

	# ── Options ──
	var d_true_keep := _true_distance(pts_handoff, requested, budget)
	var d_true_all := _true_distance(pts_all, requested, budget)
	print("vegopt measured worst case fits the budget at: %.0f m counting handoff species, %.0f m counting all" % [
		d_true_keep, d_true_all])
	var opts := [
		{"id": "A", "why": "as saved", "d": d_cur, "chains": false},
		{"id": "B", "why": "full-mesh species get impostors", "d": d_cur, "chains": true},
		{"id": "C", "why": "tighter budget, chains as saved", "d": d_keep, "chains": false},
		{"id": "D", "why": "both", "d": d_all, "chains": true},
		{"id": "E", "why": "measured budget, chains as saved", "d": d_true_keep, "chains": false},
		{"id": "F", "why": "measured budget, impostors for all", "d": d_true_all, "chains": true},
	]
	var only := OS.get_environment("VEGOPT_SET")
	if not only.is_empty():
		var keep: Array = []
		for o in opts:
			if str(o["id"]) in only.split(","):
				keep.append(o)
		opts = keep
	var hidden: Array = []
	for ch in main.get_children():
		if ch is CanvasLayer and (ch as CanvasLayer).visible:
			(ch as CanvasLayer).visible = false
			hidden.append(ch)
	var rid := main.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var cam := _make_cam(main)
	for o in opts:
		var s := s0.duplicate(true)
		s["tree_detail_eff_m"] = float(o["d"])
		if bool(o["chains"]):
			var ov: Dictionary = s.get(VegStyleStore.KEY_SPECIES_OVERRIDES, {})
			for sp in full_mesh:
				if ov.get(sp) is Dictionary:
					(ov[sp] as Dictionary).erase("detail_chain")
		VegetationRuntime.rebuild(terrain, layer, ground, false, s)
		await _wait_bakes(tree, loader)
		VegetationRuntime.rebuild(terrain, layer, ground, false, s)
		for _i in 30:
			await tree.process_frame
		var chains := {}
		for sp in full_mesh:
			chains[sp] = ",".join(VegetationCardFactory.lod_chain(str(sp), s))
		var rows: Array = []
		var view := 0
		var stride := maxi(1, trees.size() / SPOTS)
		var k := 0
		while k < trees.size() and view < SPOTS * 2:
			var p := trees[k]
			k += stride
			var x := p.x + 3.0
			var z := p.z + 3.0
			var gy := float(loader.call("ground_height_at", x, z))
			for turn in 2:
				var yaw := float(view) * 2.399 + float(turn) * PI
				var fwd := Vector3(sin(yaw), -0.07, cos(yaw)).normalized()
				cam.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP),
					Vector3(x, gy + 1.7, z))
				await _wait(tree, SETTLE_S)
				rows.append(await _sample(tree, rid))
				if view in SHOTS:
					await RenderingServer.frame_post_draw
					main.get_viewport().get_texture().get_image().save_png(
						"%s/opt%s_view_%02d.png" % [dir, str(o["id"]), view])
				view += 1
		var m := {"gpu": 0.0, "cpu": 0.0, "draws": 0.0, "prims": 0.0}
		var gpus: Array = []
		for r in rows:
			for key in m:
				m[key] = float(m[key]) + float((r as Dictionary)[key])
			gpus.append(float((r as Dictionary)["gpu"]))
		gpus.sort()
		var n := maxf(float(rows.size()), 1.0)
		print("vegopt %s (%s): detail %.0f m  gpu %.2f ms (p50 %.2f, p90 %.2f)  cpu %.2f  draws %.0f  prims %.0f  chains %s" % [
			str(o["id"]), str(o["why"]), float(o["d"]), float(m["gpu"]) / n,
			float(gpus[gpus.size() / 2]), float(gpus[int(gpus.size() * 0.9)]),
			float(m["cpu"]) / n, float(m["draws"]) / n, float(m["prims"]) / n, str(chains)])
	for ch in hidden:
		(ch as CanvasLayer).visible = true
	main.call("pop_camera_claim", "veg_detail_options")
	cam.queue_free()
	loader.set("_impostor_rebuild_pending", false)
	VegetationRuntime.rebuild(terrain, layer, ground, false, s0)
	return {"ok": true}


## Tree positions on the ground plane, leaving out the given species.
func _points(bulks: Array, skip: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for b in bulks:
		for slot in (b as Dictionary):
			var sp := str(slot)
			var fam := VegSpeciesCatalog.mesh_family(sp)
			if fam != "pine" and fam != "deciduous" or sp in skip:
				continue
			for item in (b as Dictionary)[slot]:
				if item is Dictionary:
					out.append(Vector2(float(item.get("x", 0.0)), float(item.get("z", 0.0))))
	return out


func _grid(pts: PackedVector2Array) -> Dictionary:
	var g := {}
	for p in pts:
		var key := Vector2i(int(floor(p.x / CELL)), int(floor(p.y / CELL)))
		if not g.has(key):
			g[key] = PackedVector2Array()
		var a: PackedVector2Array = g[key]
		a.append(p)
		g[key] = a
	return g


## The most trees within d of any viewpoint, viewpoints at every 8th tree.
func _worst_near(pts: PackedVector2Array, d: float) -> int:
	var g := _grid(pts)
	var r := int(ceil(d / CELL))
	var worst := 0
	var i := 0
	while i < pts.size():
		var c := pts[i]
		var ck := Vector2i(int(floor(c.x / CELL)), int(floor(c.y / CELL)))
		var n := 0
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var key := ck + Vector2i(dx, dz)
				if not g.has(key):
					continue
				for p in (g[key] as PackedVector2Array):
					if p.distance_squared_to(c) <= d * d:
						n += 1
		worst = maxi(worst, n)
		i += 8
	return worst


## The largest distance whose measured worst case fits the budget
## (bisection on _worst_near, 5 m resolution).
func _true_distance(pts: PackedVector2Array, requested: float, budget: int) -> float:
	var lo := VegLodPolicy.MIN_DETAIL_M
	var hi := maxf(requested, lo)
	if _worst_near(pts, hi) <= budget:
		return hi
	while hi - lo > 5.0:
		var mid := (lo + hi) * 0.5
		if _worst_near(pts, mid) <= budget:
			lo = mid
		else:
			hi = mid
	return lo


## The budget rule on 64 m cells: a viewpoint anywhere in cell C sees full
## trees only in cells whose centre is within d + 2 half-diagonals of C's.
func _tight_distance(pts: PackedVector2Array, requested: float, budget: int) -> float:
	var g := _grid(pts)
	var counts := {}
	for key in g:
		counts[key] = (g[key] as PackedVector2Array).size()
	var hd := CELL * 0.7072
	var d := maxf(requested, VegLodPolicy.MIN_DETAIL_M)
	while d > VegLodPolicy.MIN_DETAIL_M:
		var reach := d + 2.0 * hd
		var r := int(ceil(reach / CELL))
		var worst := 0
		for key in counts:
			var c: Vector2i = key
			var total := 0
			for dz in range(-r, r + 1):
				for dx in range(-r, r + 1):
					var o := c + Vector2i(dx, dz)
					if counts.has(o) and Vector2(dx, dz).length() * CELL <= reach:
						total += int(counts[o])
			worst = maxi(worst, total)
			if worst > budget:
				break
		if worst <= budget:
			return d
		d *= SHRINK
	return VegLodPolicy.MIN_DETAIL_M


func _make_cam(main: Node) -> Camera3D:
	var player_cam := main.get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.fov = player_cam.fov if player_cam != null else 75.0
	cam.near = player_cam.near if player_cam != null else 0.05
	cam.far = player_cam.far if player_cam != null else 4000.0
	if player_cam != null:
		cam.environment = player_cam.environment
		cam.attributes = player_cam.attributes
		cam.cull_mask = player_cam.cull_mask
	main.add_child(cam)
	main.call("push_camera_claim", "veg_detail_options", {"camera_id": cam.get_instance_id()})
	return cam


func _wait_bakes(tree: SceneTree, loader: Node) -> void:
	var baker: Node = loader.get("_impostor_baker")
	var waited := 0.0
	while waited < 120.0:
		await tree.create_timer(0.5).timeout
		waited += 0.5
		if waited > 2.0 and (baker == null or not bool(baker.call("is_busy"))):
			break


func _tree_positions(main: Node) -> PackedVector3Array:
	var seen := {}
	_collect(main, seen)
	var keys := seen.keys()
	keys.sort()
	var out := PackedVector3Array()
	for key in keys:
		out.append(seen[key])
	return out


func _collect(n: Node, seen: Dictionary) -> void:
	for ch in n.get_children():
		_collect(ch, seen)
	if not (n is MultiMeshInstance3D) or not n.has_meta(&"veg_species"):
		return
	var mi := n as MultiMeshInstance3D
	if mi.multimesh == null:
		return
	var fam := VegSpeciesCatalog.mesh_family(str(mi.get_meta(&"veg_species")))
	if fam != "pine" and fam != "deciduous":
		return
	var xf := mi.global_transform
	for i in mi.multimesh.instance_count:
		var p := xf * mi.multimesh.get_instance_transform(i).origin
		seen[Vector2i(roundi(p.x * 10.0), roundi(p.z * 10.0))] = p


func _wait(tree: SceneTree, secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		await tree.process_frame


func _sample(tree: SceneTree, rid: RID) -> Dictionary:
	var gpu: Array = []
	var cpu: Array = []
	var draws := 0.0
	var prims := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(SAMPLE_S * 1000.0):
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid)
			+ RenderingServer.get_frame_setup_time_cpu())
		draws += float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		prims += float(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		frames += 1
	gpu.sort()
	cpu.sort()
	var nf := maxf(float(frames), 1.0)
	return {"gpu": gpu[gpu.size() / 2], "cpu": cpu[cpu.size() / 2],
		"draws": draws / nf, "prims": prims / nf}
