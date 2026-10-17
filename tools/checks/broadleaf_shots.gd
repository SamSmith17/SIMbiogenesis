extends RefCounted

## Sandbox look check for the broadleaf rebuild (leaf sprays, per-species
## habit, autumn colours) and the Terrain options "Show vegetation" toggle:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/broadleaf_shots.gd -Label <dir>
##
## 1. Applies tools/fixes/mtvernon_broadleaf_v3.gd in the sandbox.
## 2. Portraits: three variants of each broadleaf in July and October, plus a
##    maple close-up at eye level and from underneath.
## 3. The painted forest after the impostor bakes land: edge, maple patch,
##    drone, July and October.
## 4. Show vegetation OFF: every plant root hidden, ground moss / litter
##    strength 0 — then ON again and visible. FAILs if either is wrong.

const FIX := "res://tools/fixes/mtvernon_broadleaf_v3.gd"
const PORTRAITS := ["maple", "alder", "oak", "birch", "aspen", "cottonwood", "beech",
	"chestnut", "walnut", "apple"]


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var fix: Object = (load(FIX) as Script).new()
	var fres: Variant = await fix.call("run", main, harness)
	if not (fres is Dictionary) or not bool((fres as Dictionary).get("ok", false)):
		return {"ok": false, "why": "fix failed: %s" % JSON.stringify(fres)}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var loader: Node = main.get_node_or_null("TerrainLoader")
	main.set("time_scale", 0.0)
	var ui: Node = main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false
	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.far = 6000.0
	main.add_child(cam)
	main.call("push_camera_claim", "broadleaf_shots", {"camera_id": cam.get_instance_id(),
		"hide_player_mesh": true})

	await _portraits(main, loader, cam, dir, [2026, 7, 15], "jul")
	await _portraits(main, loader, cam, dir, [2026, 10, 18], "oct")
	await _maple_closeups(main, loader, cam, dir)

	# The painted forest, after the new looks' impostor bakes land.
	_set_date(main, 2026, 7, 15, 14.5)
	var baker: Node = loader.get("_impostor_baker")
	var waited := 0.0
	while waited < 120.0:
		await tree.create_timer(0.5).timeout
		waited += 0.5
		var busy := baker != null and bool(baker.call("is_busy"))
		if not busy and not bool(loader.get("_impostor_rebuild_pending")) and waited > 3.0:
			break
	for _i in 30:
		await tree.process_frame
	print("broadleaf_shots: waited %.1f s for impostor bakes" % waited)
	var layer: VegetationLayer = loader.get("_vegetation_layer")
	var gy := func(x: float, z: float) -> float: return float(loader.call("_ground_height_at", x, z))
	var cells := {}
	for sid in ["maple", "alder"]:
		for r in layer.bulk.get(sid, []):
			var k := Vector2i(int(floor(float(r["x"]) / 40.0)), int(floor(float(r["z"]) / 40.0)))
			cells[k] = int(cells.get(k, 0)) + 1
	var best := Vector2i.ZERO
	for k in cells:
		if int(cells[k]) > int(cells.get(best, 0)):
			best = k
	var c := (Vector2(best) + Vector2(0.5, 0.5)) * 40.0
	var out := c + Vector2(34.0, 20.0)
	cam.fov = 70.0
	var forest_shots := [
		["f01_edge_eye", Vector3(out.x, gy.call(out.x, out.y) + 1.7, out.y),
			Vector3(c.x, gy.call(c.x, c.y) + 9.0, c.y)],
		["f02_inside", Vector3(c.x + 3.0, gy.call(c.x + 3.0, c.y) + 1.7, c.y),
			Vector3(c.x - 20.0, gy.call(c.x - 20.0, c.y + 12.0) + 12.0, c.y + 12.0)],
		["f03_drone", Vector3(c.x + 55.0, gy.call(c.x, c.y) + 32.0, c.y + 55.0),
			Vector3(c.x, gy.call(c.x, c.y) + 4.0, c.y)],
	]
	for when in [["jul", [2026, 7, 15]], ["oct", [2026, 10, 18]]]:
		var d: Array = when[1]
		_set_date(main, d[0], d[1], d[2], 14.5)
		for _i in 10:
			await tree.process_frame
		for fs in forest_shots:
			await _shot(cam, dir, "%s_%s" % [fs[0], when[0]], fs[1], fs[2])

	# Tune look on the maple page (the Leaves row, Shape, Tree variants).
	main.call("pop_camera_claim", "broadleaf_shots")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = true
	loader.call("open_vegetation_preview_editor", -1, "maple")
	for _i in 90:
		await tree.process_frame
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/m01_tune_maple.png" % dir)
	var ed: Node = loader.get("_vegetation_preview_ui")
	if ed != null and ed.has_method("close"):
		ed.call("close")
	for _i in 10:
		await tree.process_frame
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false
	main.call("push_camera_claim", "broadleaf_shots", {"camera_id": cam.get_instance_id(),
		"hide_player_mesh": true})

	# Show vegetation off / on.
	var hide := await _hide_check(main, loader, cam, dir, forest_shots[2])
	main.call("pop_camera_claim", "broadleaf_shots")
	cam.queue_free()
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = true
	print("broadleaf_shots: hide check %s" % JSON.stringify(hide))
	var ok := bool(hide.get("ok", false))
	print("broadleaf_shots: %s" % ("PASS" if ok else "FAIL"))
	return {"ok": ok, "hide": hide, "fix": fres}


func _hide_check(main: Node, loader: Node, cam: Camera3D, dir: String, shot: Array) -> Dictionary:
	var tree := main.get_tree()
	var was := bool(loader.call("show_vegetation"))
	loader.call("set_show_vegetation", false)
	for _i in 6:
		await tree.process_frame
	var terrain := main.get_node_or_null("Terrain") as Node3D
	var shown_while_hidden: Array = []
	for nm in ["Vegetation", "AutoVegetation", VegDeadwood.ROOT_NAME, "VegLeafFall"]:
		var n := terrain.get_node_or_null(nm) as Node3D
		if n != null and n.visible:
			shown_while_hidden.append(nm)
	# Plants placed as models (a tree / stump GLB from the library) hide too.
	var plant_props := 0
	var plant_props_shown := 0
	var pp_root := terrain.get_node_or_null("PlacedProps")
	if pp_root != null:
		for ch in pp_root.get_children():
			if ch is PlacedProp and loader.call("prop_is_plant", (ch as PlacedProp).model_id):
				plant_props += 1
				if (ch as PlacedProp).visible:
					plant_props_shown += 1
	var moss := -1.0
	var ground := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	if ground != null and ground.material_override is ShaderMaterial:
		moss = float((ground.material_override as ShaderMaterial).get_shader_parameter("moss_strength"))
	await _shot(cam, dir, "h01_hidden", shot[1], shot[2])
	loader.call("set_show_vegetation", true)
	for _i in 6:
		await tree.process_frame
	var hidden_after: Array = []
	for nm in ["Vegetation", VegDeadwood.ROOT_NAME]:
		var n := terrain.get_node_or_null(nm) as Node3D
		if n != null and not n.visible:
			hidden_after.append(nm)
	await _shot(cam, dir, "h02_shown", shot[1], shot[2])
	loader.call("set_show_vegetation", was)
	var plant_back := 0
	if pp_root != null:
		for ch in pp_root.get_children():
			if ch is PlacedProp and (ch as PlacedProp).visible \
					and loader.call("prop_is_plant", (ch as PlacedProp).model_id):
				plant_back += 1
	return {"ok": shown_while_hidden.is_empty() and hidden_after.is_empty() and moss <= 0.0001
			and plant_props_shown == 0 and plant_back == plant_props,
		"plant_props": plant_props, "plant_props_shown_while_hidden": plant_props_shown,
		"plant_props_back": plant_back,
		"shown_while_hidden": shown_while_hidden, "hidden_after_show": hidden_after,
		"moss_while_hidden": moss}


func _portraits(main: Node, loader: Node, cam: Camera3D, dir: String, date: Array,
		tag: String) -> void:
	var tree := main.get_tree()
	_set_date(main, date[0], date[1], date[2], 13.0)
	for _i in 6:
		await tree.process_frame
	var style: Dictionary = loader.call("_auto_veg_runtime_settings")
	var base := Vector3(0.0, 2500.0, 0.0)
	cam.fov = 45.0
	for sid in PORTRAITS:
		var row: Array = []
		var h := 1.0
		var w := 1.0
		for k in 3:
			var sk := style.duplicate()
			sk["deciduous_variant_index"] = k
			var m := VegetationCardFactory.mesh_for_canopy_lod(sid, sk,
				VegetationCardFactory.CanopyLodTier.NEAR)
			h = maxf(h, m.get_aabb().size.y)
			w = maxf(w, maxf(m.get_aabb().size.x, m.get_aabb().size.z))
			var mi := MeshInstance3D.new()
			mi.mesh = m
			main.add_child(mi)
			row.append(mi)
		for k in row.size():
			(row[k] as Node3D).global_position = base + Vector3((float(k) - 1.0) * w * 1.08, 0.0, 0.0)
		var d := maxf(h * 1.25, w * 3.5) * 1.15
		cam.global_position = base + Vector3(0.0, h * 0.45, d)
		cam.look_at(base + Vector3(0.0, h * 0.5, 0.0), Vector3.UP)
		for _i in 10:
			await tree.process_frame
		await RenderingServer.frame_post_draw
		cam.get_viewport().get_texture().get_image().save_png("%s/p_%s_%s.png" % [dir, sid, tag])
		print("broadleaf_shots: portrait %s %s %.1f m tall, %.1f m wide" % [sid, tag, h, w])
		for mi in row:
			(mi as Node).queue_free()


func _maple_closeups(main: Node, loader: Node, cam: Camera3D, dir: String) -> void:
	_set_date(main, 2026, 7, 15, 13.0)
	var style: Dictionary = loader.call("_auto_veg_runtime_settings")
	var m := VegetationCardFactory.mesh_for_canopy_lod("maple", style,
		VegetationCardFactory.CanopyLodTier.NEAR)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	main.add_child(mi)
	var base := Vector3(400.0, 2500.0, 0.0)
	mi.global_position = base
	var h := m.get_aabb().size.y
	cam.fov = 60.0
	await _shot(cam, dir, "c01_maple_eye", base + Vector3(0.0, 1.7, 15.0),
		base + Vector3(0.0, h * 0.55, 0.0))
	await _shot(cam, dir, "c02_maple_under", base + Vector3(2.0, 1.6, 2.5),
		base + Vector3(-1.0, h * 0.8, -1.0))
	await _shot(cam, dir, "c03_maple_crown", base + Vector3(5.0, h * 0.75, 9.0),
		base + Vector3(0.0, h * 0.72, 0.0))
	mi.queue_free()


func _set_date(main: Node, y: int, m: int, d: int, h: float) -> void:
	main.set("year", y)
	main.set("month", m)
	main.set("day", d)
	main.set("day_time", h)


func _shot(cam: Camera3D, dir: String, name: String, from: Vector3, at: Vector3) -> void:
	cam.global_position = from
	cam.look_at(at, Vector3.UP)
	for _i in 18:
		await cam.get_tree().process_frame
	await RenderingServer.frame_post_draw
	cam.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])
	print("broadleaf_shots: %s" % name)
