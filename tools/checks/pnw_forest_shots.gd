extends RefCounted

## Sandbox look + LOD check for the Mount Vernon PNW forest pass:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pnw_forest_shots.gd -Label <dir>
##
## 1. Applies tools/fixes/mtvernon_pnw_forest_v2.gd (in the sandbox — never
##    persisted from here), then shoots each species' three variants and the
##    Tune-look Mixed-woodland page.
## 2. Parks the clock on a mid-October afternoon (the reference photos'
##    season) and shoots the painted forest: eye level at the edge, inside the
##    stand, a 30 m drone view and a high oblique; one summer shot for contrast.
## 3. Opens the graph's Globe lens and, at several orbit yaws and zooms,
##    counts tree batches inside the SoI sphere that the preview camera would
##    CULL by visibility range (distance to the batch AABB centre past
##    visibility_range_end + margin). That is the "trees pop in and out in the
##    Globe" bug; it must read 0. Shoots each step.

## The current Mount Vernon fix (idempotent — on the converted world it only
## re-checks). The first pass (mtvernon_pnw_forest.gd) is history: re-running
## it would re-add the per-species overrides v2 removed.
const FIXES := ["res://tools/fixes/mtvernon_pnw_forest_v2.gd"]
const PORTRAITS := ["douglas_fir", "cedar", "hemlock", "spruce", "fir", "pine",
	"maple", "alder", "sword_fern", "bracken", "salal", "blackberry"]


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var res: Variant = null
	for fp in FIXES:
		var fix: Object = (load(fp) as Script).new()
		res = await fix.call("run", main, harness)
		if not (res is Dictionary) or not bool((res as Dictionary).get("ok", false)):
			return {"ok": false, "why": "fix %s failed: %s" % [fp, JSON.stringify(res)]}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var loader: Node = main.get_node_or_null("TerrainLoader")
	await _portraits(main, loader, dir)
	await _modal_shot(main, loader, dir)
	var layer: VegetationLayer = loader.get("_vegetation_layer")

	main.set("time_scale", 0.0)
	_set_date(main, 2026, 10, 15, 15.5)
	for _i in 20:
		await tree.process_frame
	# Let the new looks' impostor bakes finish and their debounced rebuild
	# land, or the far tier is still the crossed-card stand-in.
	var baker: Node = loader.get("_impostor_baker")
	var waited := 0.0
	while waited < 90.0:
		await tree.create_timer(0.5).timeout
		waited += 0.5
		var busy := baker != null and bool(baker.call("is_busy"))
		if not busy and not bool(loader.get("_impostor_rebuild_pending")) and waited > 3.0:
			break
	for _i in 30:
		await tree.process_frame
	print("pnw_forest_shots: waited %.1f s for impostor bakes" % waited)

	# Where the painted forest is: densest 40 m cell of trees.
	var cells := {}
	var all_trees: Array = []
	for sid in ["fir", "cedar", "hemlock", "maple", "alder"]:
		for r in layer.bulk.get(sid, []):
			all_trees.append(r)
			var k := Vector2i(int(floor(float(r["x"]) / 40.0)), int(floor(float(r["z"]) / 40.0)))
			cells[k] = int(cells.get(k, 0)) + 1
	var best := Vector2i.ZERO
	for k in cells:
		if int(cells[k]) > int(cells.get(best, 0)):
			best = k
	var c := (Vector2(best) + Vector2(0.5, 0.5)) * 40.0
	var gy := func(x: float, z: float) -> float: return float(loader.call("_ground_height_at", x, z))
	var maple_spot := c
	for r in layer.bulk.get("maple", []):
		maple_spot = Vector2(float(r["x"]), float(r["z"]))
		break

	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.far = 6000.0
	main.add_child(cam)
	main.call("push_camera_claim", "pnw_shots", {"camera_id": cam.get_instance_id(),
		"hide_player_mesh": true})
	var ui: Node = main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false
	var shots := []
	# Eye level, 30 m out from the dense cell, looking in.
	var out := c + Vector2(30.0, 18.0)
	shots.append(await _shot(cam, dir, "01_edge_eye",
		Vector3(out.x, gy.call(out.x, out.y) + 1.7, out.y),
		Vector3(c.x, gy.call(c.x, c.y) + 9.0, c.y)))
	shots.append(await _shot(cam, dir, "02_inside_stand",
		Vector3(c.x + 3.0, gy.call(c.x + 3.0, c.y) + 1.7, c.y),
		Vector3(c.x - 20.0, gy.call(c.x - 20.0, c.y + 12.0) + 12.0, c.y + 12.0)))
	shots.append(await _shot(cam, dir, "03_look_up",
		Vector3(c.x, gy.call(c.x, c.y) + 1.6, c.y),
		Vector3(c.x + 4.0, gy.call(c.x, c.y) + 40.0, c.y + 2.0)))
	shots.append(await _shot(cam, dir, "04_maple_patch",
		Vector3(maple_spot.x + 26.0, gy.call(maple_spot.x + 26.0, maple_spot.y + 10.0) + 2.0,
			maple_spot.y + 10.0),
		Vector3(maple_spot.x, gy.call(maple_spot.x, maple_spot.y) + 10.0, maple_spot.y)))
	shots.append(await _shot(cam, dir, "05_drone_30m",
		Vector3(c.x + 60.0, gy.call(c.x, c.y) + 30.0, c.y + 60.0),
		Vector3(c.x, gy.call(c.x, c.y), c.y)))
	shots.append(await _shot(cam, dir, "06_high_oblique",
		Vector3(c.x + 260.0, gy.call(c.x, c.y) + 160.0, c.y + 260.0),
		Vector3(c.x, gy.call(c.x, c.y), c.y)))
	_set_date(main, 2026, 7, 15, 15.5)
	for _i in 10:
		await tree.process_frame
	shots.append(await _shot(cam, dir, "07_edge_eye_july",
		Vector3(out.x, gy.call(out.x, out.y) + 1.7, out.y),
		Vector3(c.x, gy.call(c.x, c.y) + 9.0, c.y)))
	_set_date(main, 2026, 10, 15, 15.5)
	# Deadwood close-up: the nearest piece to the dense cell.
	var dw: Node = main.get_node_or_null("Terrain/" + VegDeadwood.ROOT_NAME)
	var piece := Vector3.INF
	var piece_kinds := {}
	if dw != null:
		for mmi in dw.get_children():
			if not (mmi is MultiMeshInstance3D):
				continue
			var mm := (mmi as MultiMeshInstance3D).multimesh
			piece_kinds[str(mmi.name).get_slice("_", 0)] = int(piece_kinds.get(
				str(mmi.name).get_slice("_", 0), 0)) + mm.instance_count
			for i in mm.instance_count:
				var o := mm.get_instance_transform(i).origin
				if piece == Vector3.INF or Vector2(o.x, o.z).distance_to(c) < Vector2(piece.x, piece.z).distance_to(c):
					piece = o
	if piece != Vector3.INF:
		shots.append(await _shot(cam, dir, "08_deadwood",
			piece + Vector3(5.0, 2.2, 4.0), piece + Vector3(0, 0.6, 0)))
	main.call("pop_camera_claim", "pnw_shots")
	cam.queue_free()
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = true

	var globe := await _globe_check(main, dir)
	return {"ok": int(globe.get("culled_max", 1)) == 0, "shots": shots,
		"deadwood": piece_kinds, "globe": globe, "fix": res}


func _set_date(main: Node, y: int, m: int, d: int, h: float) -> void:
	main.set("year", y)
	main.set("month", m)
	main.set("day", d)
	main.set("day_time", h)


func _shot(cam: Camera3D, dir: String, name: String, from: Vector3, at: Vector3) -> String:
	cam.global_position = from
	cam.look_at(at, Vector3.UP)
	for _i in 18:
		await cam.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := cam.get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [dir, name]
	img.save_png(path)
	print("pnw_forest_shots: %s" % path)
	return name


## Globe lens: at each orbit step, how many tree batches whose AABB reaches
## inside the SoI sphere are past their visibility range from the preview
## camera (= drawn as nothing).
func _globe_check(main: Node, dir: String) -> Dictionary:
	var tree := main.get_tree()
	var graph: Node = ServiceLocator.graph()
	if graph == null:
		return {"why": "no graph", "culled_max": 1}
	graph.call("open_graph_view")
	for _i in 4:
		await tree.process_frame
	graph.call("_on_mode_chip_pressed", "globe")
	for _i in 30:
		await tree.process_frame
	var canvas: Object = graph.get("_graph_canvas")
	var svc: Object = canvas.get("soi_preview_service") if canvas != null else null
	if svc == null:
		return {"why": "no preview service", "culled_max": 1}
	var soi := tree.root.get_node_or_null("SoiService")
	var centre: Vector3 = soi.call("world_center")
	var r := float(soi.call("radius_m"))
	var steps: Array = []
	var culled_max := 0
	var i := 0
	for zoom_out in [0, 6, 14]:
		for _z in zoom_out:
			svc.call("apply_zoom_step", false)
		for _w in 40:
			await tree.process_frame
		for yaw_step in 3:
			svc.call("apply_orbit_delta", Vector2(260.0, 0.0))
			for _w in 12:
				await tree.process_frame
			var cam: Camera3D = svc.get("_camera")
			var n := _culled_inside(main, cam.global_position, centre, r)
			culled_max = maxi(culled_max, int(n["culled"]))
			n["cam_dist"] = snappedf(cam.global_position.distance_to(centre), 1.0)
			steps.append(n)
			await RenderingServer.frame_post_draw
			var img := main.get_viewport().get_texture().get_image()
			img.save_png("%s/globe_%02d.png" % [dir, i])
			i += 1
	graph.call("close_graph_view")
	print("pnw_forest_shots: globe %s" % JSON.stringify(steps))
	return {"steps": steps, "culled_max": culled_max, "radius": r}


func _culled_inside(main: Node, cam_pos: Vector3, centre: Vector3, r: float) -> Dictionary:
	var culled := 0
	var seen := 0
	var stack: Array = [main.get_node_or_null("Terrain")]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == null:
			continue
		for ch in n.get_children():
			stack.append(ch)
		if not (n is MultiMeshInstance3D) or not str(n.name).begins_with("Bulk_"):
			continue
		var mi := n as MultiMeshInstance3D
		# Species ids can hold underscores (grass_field, sword_fern): match the
		# longest known id after "Bulk_", never the first slice ("grass" reads
		# as an unknown id and fell through to the tree families).
		var rest := str(n.name).substr(5)
		var fam := ""
		var best_len := 0
		for sid in VegetationCardFactory.SPECS:
			var sk := str(sid)
			if rest.begins_with(sk + "_") and sk.length() > best_len:
				best_len = sk.length()
				fam = VegSpeciesCatalog.mesh_family(sk)
		if fam != "pine" and fam != "deciduous":
			continue
		if mi.visibility_range_end <= 0.0:
			continue
		var box := mi.global_transform * mi.get_aabb()
		var nearest := Vector3(clampf(centre.x, box.position.x, box.end.x),
			clampf(centre.y, box.position.y, box.end.y), clampf(centre.z, box.position.z, box.end.z))
		if nearest.distance_to(centre) > r:
			continue
		# Only the FAR tier must reach the whole sphere; the near mesh tier
		# (begins at 0, ends at the detail distance) hands over to it by design.
		if mi.visibility_range_begin <= 0.0 and mi.visibility_range_end < 420.0:
			continue
		seen += 1
		var d := cam_pos.distance_to(box.get_center())
		if d > mi.visibility_range_end + mi.visibility_range_end_margin:
			culled += 1
			if culled <= 4:
				print("pnw_forest_shots: culled %s path=%s begin=%.0f end=%.0f d=%.0f" % [
					n.name, str(n.get_path()), mi.visibility_range_begin,
					mi.visibility_range_end, d])
	return {"far_batches_in_sphere": seen, "culled": culled}


## Three variants of each species side by side in the sky (no terrain behind),
## with the map's live style — the look the world renders.
func _portraits(main: Node, loader: Node, dir: String) -> void:
	var tree := main.get_tree()
	main.set("time_scale", 0.0)
	_set_date(main, 2026, 7, 15, 13.0)
	var style: Dictionary = loader.call("_auto_veg_runtime_settings")
	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.far = 4000.0
	main.add_child(cam)
	main.call("push_camera_claim", "pnw_portraits", {"camera_id": cam.get_instance_id(),
		"hide_player_mesh": true})
	var ui: Node = main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false
	var base := Vector3(0.0, 2500.0, 0.0)
	for sid in PORTRAITS:
		var fam := VegSpeciesCatalog.mesh_family(sid)
		var is_tree := fam == "pine" or fam == "deciduous"
		var row: Array = []
		var h := 1.0
		var w := 1.0
		for k in 3:
			var sk := style.duplicate()
			sk["%s_variant_index" % fam] = k
			var m: ArrayMesh = null
			if is_tree:
				m = VegetationCardFactory.mesh_for_canopy_lod(sid, sk,
					VegetationCardFactory.CanopyLodTier.NEAR)
			else:
				m = VegetationCardFactory.mesh_for_species(sid, sk)
			if m == null:
				continue
			h = maxf(h, m.get_aabb().size.y)
			w = maxf(w, maxf(m.get_aabb().size.x, m.get_aabb().size.z))
			var mi := MeshInstance3D.new()
			mi.mesh = m
			main.add_child(mi)
			row.append(mi)
		for k in row.size():
			(row[k] as Node3D).global_position = base + Vector3((float(k) - 1.0) * w * 1.1, 0.0, 0.0)
		var d := maxf(h * 1.25, w * 3.6) * 1.2
		cam.global_position = base + Vector3(0.0, h * 0.45, d)
		cam.look_at(base + Vector3(0.0, h * 0.5, 0.0), Vector3.UP)
		for _i in 10:
			await tree.process_frame
		await RenderingServer.frame_post_draw
		cam.get_viewport().get_texture().get_image().save_png("%s/p_%s.png" % [dir, sid])
		print("pnw_forest_shots: portrait %s %.1f m tall, %.1f m wide" % [sid, h, w])
		for mi in row:
			(mi as Node).queue_free()
	main.call("pop_camera_claim", "pnw_portraits")
	cam.queue_free()
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = true


## The Tune-look Mixed-woodland page with its preview, as the player sees it.
func _modal_shot(main: Node, loader: Node, dir: String) -> void:
	var tree := main.get_tree()
	_set_date(main, 2026, 10, 15, 14.0)
	loader.call("open_vegetation_preview_editor", int(VegetationPaint.Preset.MIX), "")
	for _i in 90:
		await tree.process_frame
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/modal_mix.png" % dir)
	var ed: Node = loader.get("_vegetation_preview_ui")
	if ed != null and ed.has_method("close"):
		ed.call("close")
	print("pnw_forest_shots: modal shot")
