extends RefCounted

## Sandbox: the V toolbar's Select (hover / glow / one-tree Tune look) and
## Detect (plants from the satellite photo) on a real world.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/veg_select_detect_check.gd
##
## Stands a camera in front of a painted tree (and an OSM-forest tree when the
## generated forest is on), resolves the crown through the SAME screen ray the
## pointer uses, and asserts: the pick names that record; the hover marker
## shows; every batch of its species — and only those — carries the glow
## uniform; Tune look opens in one-tree mode; "This tree" re-meshes that tree
## at the new height (the batch AABB says so, exact-size meshes); "This world"
## lands a map species override and drops the per-tree look; an OSM tree's
## look survives a full regeneration of the generated forest. Then Detect
## previews and plants over a patch near the site centre, and Undo takes it
## back. Shots under screenshots\veg_select_detect\.

const SHOTS := "user://screenshots/veg_select_detect/"

var _fails: Array = []
var _cam: Camera3D = null
var _prev_cam: Camera3D = null


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOTS))
	for _i in 120:
		await tree.process_frame
	var painted: VegetationLayer = loader.get("_vegetation_layer")
	if painted == null:
		return {"ok": false, "why": "no painted layer"}
	_prev_cam = main.get_viewport().get_camera_3d()
	_cam = Camera3D.new()
	_cam.far = 4000.0
	main.add_child(_cam)
	# The pick casts from the VIEWPORT's camera; Main's claim stack decides it.
	main.call("push_camera_claim", "veg_select_check",
		{"camera_id": _cam.get_instance_id(), "hide_player_mesh": true})
	# --- painted tree ---------------------------------------------------------
	var rec := _pick_record(painted.bulk, loader)
	if rec.is_empty():
		_fail("no painted tree on this world to test")
	else:
		await _test_tree(main, loader, rec, "painted")
	# --- OSM forest tree ------------------------------------------------------
	var auto_layer: Variant = loader.get("_auto_veg_layer")
	if auto_layer == null or not bool(loader.get("_auto_veg_generated")):
		print("veg_select: OSM forest not generated on this world — OSM part skipped")
	else:
		var arec := _pick_record((auto_layer as AutoVegetationLayer).bulk, loader,
			painted.all_placement_points())
		if arec.is_empty():
			print("veg_select: no OSM tree near the site — OSM part skipped")
		else:
			await _test_tree(main, loader, arec, "auto")
	# --- Detect ----------------------------------------------------------------
	await _test_detect(main, loader)
	main.call("pop_camera_claim", "veg_select_check")
	_cam.queue_free()
	var ok := _fails.is_empty()
	print("veg_select_detect: %s (%d problem%s)" % ["PASS" if ok else "FAIL",
		_fails.size(), "" if _fails.size() == 1 else "s"])
	return {"ok": ok, "fails": _fails}


func _fail(why: String) -> void:
	_fails.append(why)
	print("veg_select FAIL: " + why)


func _ok(what: String) -> void:
	print("veg_select ok: " + what)


## The tree nearest the site centre (inside the hi-res patch).
## `avoid`: points no candidate may stand within 10 m of (an OSM tree under a
## painted one is not the tree the ray should find first).
func _pick_record(bulk: Dictionary, loader: Node, avoid: Array = []) -> Dictionary:
	var best := {}
	var best_d := INF
	for slot in bulk:
		var fam := VegSpeciesCatalog.mesh_family(AutoVegetationRuntime._resolve_species(str(slot)) \
			if not VegSpeciesCatalog.is_paintable(str(slot)) else str(slot))
		if fam != "pine" and fam != "deciduous":
			continue
		var arr: Array = bulk[slot]
		for i in arr.size():
			var r: Dictionary = arr[i]
			var d := Vector2(float(r["x"]), float(r["z"])).length()
			if d >= best_d:
				continue
			var clear := true
			for a in avoid:
				if (a as Vector2).distance_to(Vector2(float(r["x"]), float(r["z"]))) < 10.0:
					clear = false
					break
			if clear:
				best_d = d
				best = {"slot": str(slot), "index": i, "x": float(r["x"]), "z": float(r["z"])}
	return best


## Stand just outside the crown at mid height, looking at the trunk: nothing
## else can be nearer along that ray than the tree itself.
func _aim_at(main: Node, loader: Node, x: float, z: float, h: float) -> Vector2:
	var gy := float(loader.call("ground_height_at", x, z))
	var dist := clampf(h * 0.28, 0.5, 9.0) + 2.5
	var mid := Vector3(x, gy + h * 0.5, z)
	_cam.global_position = mid + Vector3(0.6, 0.0, 1.0).normalized() * dist
	_cam.look_at(mid, Vector3.UP)
	return _cam.unproject_position(mid)


func _test_tree(main: Node, loader: Node, rec: Dictionary, source: String) -> void:
	var tree := main.get_tree()
	var layer: Variant = loader.get("_vegetation_layer") if source == "painted" \
		else loader.get("_auto_veg_layer")
	var h := float(loader.call("_veg_plant_height", rec["slot"],
		(layer.bulk[rec["slot"]] as Array)[int(rec["index"])]))
	var px := _aim_at(main, loader, rec["x"], rec["z"], h)
	for _i in 30:
		await tree.process_frame
	var desc: Dictionary = loader.call("veg_pick_at_screen", px)
	if desc.is_empty():
		_fail("%s: the screen ray through the crown picked nothing" % source)
		return
	var same := str(desc["slot"]) == str(rec["slot"]) and int(desc["index"]) == int(rec["index"])
	if not same:
		var off := Vector2(float(desc["x"]) - float(rec["x"]), float(desc["z"]) - float(rec["z"])).length()
		_fail("%s: picked %s %.1f m from the aimed tree (camera at its crown)" % [source, desc["label"], off])
		return
	_ok("%s pick → %s (%s) %.1f m tall" % [source, desc["label"], desc["source_label"], desc["height_m"]])
	if str(desc["source"]) != source:
		_fail("%s: pick reports source %s" % [source, desc["source"]])
	loader.call("set_veg_hover", desc)
	await tree.process_frame
	# A rebuild (impostor bake, chunk re-mesh) can have the batches detached
	# for a moment; the glow re-walks every half second, so poll the same way.
	for _try in 20:
		if not (loader.get("_veg_glow_nodes") as Array).is_empty():
			break
		for _i in 30:
			await tree.process_frame
		loader.set("_veg_glow_walked_ms", 0)
		loader.call("set_veg_species_glow", str(desc["species"]))
	var marker: Node3D = loader.get("_veg_hover_marker")
	if marker == null or not marker.visible:
		_fail("%s: hover marker not shown" % source)
	var glow: Array = loader.get("_veg_glow_nodes")
	var species := str(desc["species"])
	var lit_ok := not glow.is_empty()
	for n in glow:
		if str((n as Node).get_meta(&"veg_species", "")) != species \
				or not _glow_lit(loader, n as GeometryInstance3D):
			lit_ok = false
	if not lit_ok:
		_fail("%s: species glow missing (%d nodes)" % [source, glow.size()])
		var terrain := main.get_node_or_null("Terrain")
		var kids: Array = []
		for c in terrain.get_children():
			kids.append("%s(%d)" % [c.name, c.get_child_count()])
		print("veg_select diag: terrain children ", kids)
		var ar := terrain.get_node_or_null(NodePath(AutoVegetationRuntime.ROOT_NAME))
		if ar != null:
			var metas := {}
			for g in ar.find_children("*", "GeometryInstance3D", true, false):
				var m := str(g.get_meta(&"veg_species", "<none>"))
				metas[m] = int(metas.get(m, 0)) + 1
			print("veg_select diag: AutoVegetation geometry by species ", metas,
				" visible=", (ar as Node3D).visible)
	else:
		_ok("%s glow on %d batches of %s" % [source, glow.size(), species])
	for _i in 8:
		await tree.process_frame
	_shot(main, "%s_hover.png" % source)
	# --- one-tree Tune look ---------------------------------------------------
	if not bool(loader.call("open_vegetation_instance_editor", desc)):
		_fail("%s: Tune look did not open in one-tree mode" % source)
		return
	var ed: Node = loader.get("_vegetation_preview_ui")
	var fam := VegSpeciesCatalog.mesh_family(species)
	# Through the slider handler: in one-tree mode the Height row is THIS
	# tree's metres, so the drawn tree must come out exactly target_h tall.
	var target_h := snappedf(float(desc["height_m"]) * 0.6, 0.1) if fam != "shrub" else 2.0
	var hkey := "%s_height_m" % fam if fam != "shrub" else "shrub_card_h"
	ed.call("_record_slider_edit", hkey, target_h)
	ed.call("_queue_rebuild", true)
	for _i in 10:
		await tree.process_frame
	_shot(main, "%s_tune_one_tree.png" % source)
	ed.call("_apply_instance_scope", "tree")
	for _i in 40:
		await tree.process_frame
	loader.call("clear_veg_hover")
	var look: Dictionary = loader.call("veg_instance_look", desc)
	var stored_h := target_h / maxf(float(desc.get("scale", 1.0)), 0.05)
	if absf(float(look.get("height_m", look.get("card_h", 0.0))) - stored_h) > 0.01:
		_fail("%s: 'This tree' did not store the look (%s)" % [source, str(look)])
	else:
		_ok("%s 'This tree' stored height %.1f m" % [source, target_h])
	var drawn := -1.0
	for _try in 40:
		drawn = _batch_height_at(main, species, float(desc["x"]), float(desc["z"]))
		if drawn > 0.0:
			break
		for _i in 15:
			await tree.process_frame
	if absf(drawn - target_h) / target_h > 0.03:
		var r2: Dictionary = layer.record_for(desc)
		var settings: Dictionary = loader.call("_auto_veg_runtime_settings")
		var parts: Array = VegetationRuntime._partition_bulk_batches([r2], settings)
		var bs := VegSpeciesCatalog.settings_with_variant(species,
			(parts[0] as Dictionary)["settings"], VegetationCardFactory.SPECS)
		var near: Array = []
		for nd in main.get_node("Terrain").find_children("Bulk_*", "MultiMeshInstance3D", true, false):
			if str(nd.get_meta(&"veg_species", "")) != species:
				continue
			var mmx := (nd as MultiMeshInstance3D).multimesh
			var bd := INF
			for i in mmx.instance_count:
				var tt := mmx.get_instance_transform(i)
				bd = minf(bd, Vector2(tt.origin.x - float(desc["x"]), tt.origin.z - float(desc["z"])).length())
			if bd < 5.0:
				near.append("%s n=%d d=%.2f" % [nd.name, mmx.instance_count, bd])
		print("veg_select diag: %s batches near the tree: %s" % [species, str(near)])
		_fail("%s: the tree is drawn %.2f m tall, wanted %.1f (record scale %.3f, card %s, resolves to %s m)"
			% [source, drawn, target_h, float(r2.get("scale", 1.0)), str(r2.get("card_settings", {})),
			str(bs.get("%s_height_m" % fam, bs.get("shrub_card_h")))])
	else:
		_ok("%s tree re-meshed: drawn %.2f m tall" % [source, drawn])
	if source == "auto":
		# The look must survive the generated forest being regenerated.
		await loader.call("_full_regenerate_auto_vegetation_async")
		for _i in 30:
			await tree.process_frame
		var again: Dictionary = loader.call("veg_pick_near", Vector2(desc["x"], desc["z"]), 0.6)
		var look2: Dictionary = loader.call("veg_instance_look", again) if not again.is_empty() else {}
		if absf(float(look2.get("height_m", 0.0)) - stored_h) > 0.01:
			_fail("auto: the per-tree look did not survive regeneration (%s)" % str(look2))
		else:
			_ok("auto per-tree look survived a full regeneration")
		desc = again if not again.is_empty() else desc
	# --- this world ----------------------------------------------------------------
	var edits: Dictionary = ed.get("_species_edits")
	edits[species] = {"%s_crown_base_pct" % fam: 33.0} if fam != "shrub" else {"shrub_card_w": 1.7}
	ed.set("_species_edits", edits)
	ed.call("_apply_instance_scope", "world")
	for _i in 20:
		await tree.process_frame
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var store := VegStyleStore.load_map_store(lat, lon)
	var sp_entry: Dictionary = (store.get("species", {}) as Dictionary).get(species, {})
	if sp_entry.is_empty():
		_fail("%s: 'This world' wrote no map species override" % source)
	else:
		_ok("%s 'This world' → map override %s" % [source, str(sp_entry.keys())])
	if not (loader.call("veg_instance_look", desc) as Dictionary).is_empty():
		_fail("%s: 'This world' left the per-tree look in place" % source)
	ed.call("close")
	for _i in 10:
		await tree.process_frame


## Drawn height of the NEAR-mesh instance standing at (x, z), -1 if none.
func _batch_height_at(main: Node, species: String, x: float, z: float) -> float:
	var terrain := main.get_node_or_null("Terrain")
	if terrain == null:
		return -1.0
	for n in terrain.find_children("Bulk_*", "MultiMeshInstance3D", true, false):
		if str(n.get_meta(&"veg_species", "")) != species or "_imp_" in str(n.name) \
				or "photo" in str(n.name):
			continue
		var mm := (n as MultiMeshInstance3D).multimesh
		if mm == null or mm.mesh == null:
			continue
		for i in mm.instance_count:
			var t := mm.get_instance_transform(i)
			if Vector2(t.origin.x - x, t.origin.z - z).length() < 0.3:
				return mm.mesh.get_aabb().size.y * t.basis.get_scale().y
	return -1.0


func _test_detect(main: Node, loader: Node) -> void:
	var tree := main.get_tree()
	var whole: PackedVector2Array = loader.call("veg_detect_whole_area")
	if whole.size() < 3:
		_fail("detect: no imagery layers")
		return
	var half := minf(absf(whole[0].x), 90.0)
	var poly := PackedVector2Array([Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half)])
	var params := {"species": "shrub", "density": 1.0, "scale": 1.0, "size_var": 0.15,
		"sensitivity": 0.0, "max_luma": 0.62, "min_patch_m2": 1.0, "single_max_d_m": 8.0,
		"shrub_below_m": 2.5}
	var t0 := Time.get_ticks_msec()
	var st: Dictionary = loader.call("preview_veg_detect", poly, params)
	var ms := Time.get_ticks_msec() - t0
	print("veg_detect preview %d ms: %s" % [ms, str(st)])
	if st.has("error"):
		_fail("detect: " + str(st["error"]))
		return
	var ov: Node3D = loader.get("_veg_detect_overlay")
	if ov == null or not ov.visible:
		_fail("detect: no preview overlay")
	var gy := float(loader.call("ground_height_at", 0.0, 0.0))
	_cam.global_position = Vector3(0.0, gy + half * 1.6, half * 1.1)
	_cam.look_at(Vector3(0.0, gy, 0.0), Vector3.UP)
	for _i in 12:
		await tree.process_frame
	_shot(main, "detect_preview.png")
	var painted: VegetationLayer = loader.get("_vegetation_layer")
	var before := painted.all_bulk_points().size()
	loader.call("push_vegetation_undo", "detect check")
	var res: Dictionary = loader.call("place_detected_vegetation", poly, params)
	var after := painted.all_bulk_points().size()
	print("veg_detect placed: %s" % str(res))
	if int(res.get("added", 0)) != after - before:
		_fail("detect: reported %d added, layer grew by %d" % [int(res.get("added", 0)), after - before])
	elif int(st.get("plants", 0)) > 0 and int(res.get("added", 0)) == 0:
		_fail("detect: preview found plants but none were planted")
	else:
		_ok("detect planted %d (%d skipped)" % [int(res.get("added", 0)), int(res.get("skipped", 0))])
	for _i in 20:
		await tree.process_frame
	_shot(main, "detect_planted.png")
	loader.call("undo_vegetation")
	if painted.all_bulk_points().size() != before:
		_fail("detect: Undo did not remove the detected plants")
	else:
		_ok("detect undone")


func _shot(main: Node, name: String) -> void:
	var img := main.get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(SHOTS + name)


## A batch reads as lit when every vegetation material it draws with has the
## glow up (the glow lives on the species' shared materials).
func _glow_lit(loader: Node, gi: GeometryInstance3D) -> bool:
	var mats: Array = loader.call("veg_glow_materials_of", gi)
	if mats.is_empty():
		return false
	for m in mats:
		if float((m as ShaderMaterial).get_shader_parameter(&"veg_hl")) < 0.99:
			return false
	return true
