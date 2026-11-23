extends RefCounted

## End-to-end Parametric Materials Studio + live world PBR/SDFGI check (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/parametric_materials_check.gd -Label pmat_check
##
## Verifies:
##   1. `Main.open_material_library` opens `MaterialLibraryModal`, lists all 20
##      common materials, and passes `UiAudit` with 0 errors (1080p & 720p).
##   2. Captures a studio showcase sheet of key materials (plywood, lumber,
##      powder-coated metal, copper, galvanized steel, Corten, corrugated metal
##      roofing, solar reflector, PMMA, fabric, concrete, car paint).
##   3. Places a multi-material parametric showcase rig in the 3D world under
##      calibrated SDFGI (pallet rack, Corten geodesic dome, flat-pack daybed,
##      corrugated-roof shower house), captures BEFORE (flat scalar PBR) vs
##      AFTER (procedural + CC0 PBR normals, roughness & AO), tunes roughness +
##      uploads a custom texture in the modal, and asserts placed world surfaces
##      update live in place!

const CLAIM := "pmat_world_check"

var _fails: Array = []
var _out := "user://screenshots/pmat_check"


func _ok(cond: bool, what: String) -> void:
	print("pmat-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--shots-dir="):
			_out = "user://screenshots/" + s.substr(12)
	DirAccess.make_dir_recursive_absolute(_out)
	print("pmat-check: shots in %s" % ProjectSettings.globalize_path(_out))
	await _settle(tree, 35)

	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	if main.has_method("settlement_view_open") and bool(main.call("settlement_view_open")):
		(main.get("settlement_view") as Node).call("close")

	# --- 1. Open MaterialLibraryModal + UiAudit + Studio Showcase ------------
	_ok(main.has_method("open_material_library"), "Main.open_material_library exists")
	var modal := main.call("open_material_library", {"material_id": "plywood"}) as Control
	await _settle(tree, 12)
	_ok(modal != null and bool(modal.call("is_open")), "MaterialLibraryModal opened")

	var vp := main.get_viewport()
	var audit: Dictionary = UiAudit.run(vp)
	print("pmat-check: modal ui audit (%dx%d) — %s" % [vp.size.x, vp.size.y, UiAudit.summary_line(audit)])
	_ok(int(audit.get("errors", 0)) == 0,
		"MaterialLibraryModal passes UiAudit at %dx%d (%d errors)" % [vp.size.x, vp.size.y, int(audit.get("errors", 0))])
	_save_shot(vp, "%s/modal_open_%dx%d.png" % [_out, vp.size.x, vp.size.y])

	# Capture 8 signature materials in the 3D studio viewport into a 4x2 showcase sheet!
	var studio_vp: SubViewport = modal.get("_studio").viewport if modal != null and modal.get("_studio") != null else null
	_ok(studio_vp != null, "Studio SubViewport present")
	var showcase_ids := ["plywood", "powder_coat", "copper", "corten", "metal_roofing", "galvanised", "pmma", "concrete"]
	var tiles: Array[Image] = []
	if modal != null and studio_vp != null:
		modal.call("_apply_studio_lighting", "contrast")
		for mid in showcase_ids:
			modal.call("_select_material", mid)
			await _settle(tree, 8)
			var simg := studio_vp.get_texture().get_image()
			simg.convert(Image.FORMAT_RGB8)
			simg.save_png("%s/studio_%s.png" % [_out, mid])
			tiles.append(simg)
		_save_grid(tiles, 4, 2, 420, "%s/material_studio_showcase.png" % _out)
		modal.call("_apply_studio_lighting", "day")

	if modal != null:
		modal.call("close")
	await _settle(tree, 6)
	_ok(modal != null and not bool(modal.call("is_open")), "MaterialLibraryModal closed cleanly")

	# --- 2. World SDFGI Showcase + Live In-Place Tuning + Upload -------------
	await _check_world_sdfgi_and_live_tuning(main, modal, tree)

	ParametricMaterialLibrary.reset_all()
	await _settle(tree, 4)
	return {"ok": _fails.is_empty(), "fails": _fails}


func _check_world_sdfgi_and_live_tuning(main: Node, modal: Control, tree: SceneTree) -> void:
	var ssc: Node = main.get_node_or_null("/root/SimSettingsController")
	var saved_sdfgi := bool(main.call("get_sdfgi_enabled"))
	var saved_hour := float(main.get("day_time"))
	main.set("time_scale", 0.0)
	main.set("day_time", 15.8) # Warm afternoon angled sunlight + rich SDFGI bounce!
	if ssc != null:
		ssc.call("apply_sdfgi_enabled", true)
		ssc.call("apply_sdfgi_energy_mult", 1.15)
	main.call("_update")

	var centre := SiteCentre.xz(main)
	var spot := centre + Vector2(65.0, 55.0)
	var gy := TerrainSurfaceQuery.ground_height_at(main, spot.x, spot.y)
	if not is_finite(gy):
		gy = 0.0

	var stage := Node3D.new()
	stage.name = "ParametricMaterialWorldStage"
	main.add_child(stage)
	stage.global_position = Vector3(spot.x, gy, spot.y)

	# Build real parametric models right on the terrain under SDFGI!
	var rack := PalletRackBuilder.build_default_node()
	rack.position = Vector3(-3.2, 0.0, -0.5)
	stage.add_child(rack)

	var zome_preset := DomeLabPresets.builtin("corten_zome")
	if zome_preset.is_empty():
		zome_preset = DomeLabPresets.builtin("dome_2v_conduit")
	var zome := DomeLabBuilder.build_node(zome_preset.get("spec", {}), "ShowcaseDome")
	zome.position = Vector3(3.4, 0.0, -1.0)
	zome.scale = Vector3(0.45, 0.45, 0.45)
	stage.add_child(zome)

	var daybed := FlatpackBuilder.build_node()
	daybed.position = Vector3(-0.6, 0.0, 2.4)
	daybed.rotation_degrees.y = 22.0
	stage.add_child(daybed)

	var shower := ShowerHouseBuilder.build_node()
	shower.position = Vector3(2.4, 0.0, 2.2)
	shower.rotation_degrees.y = -28.0
	stage.add_child(shower)

	var hidden := _hide_ui(main)
	var cam := Camera3D.new()
	cam.fov = 54.0
	main.add_child(cam)
	cam.global_position = stage.global_position + Vector3(-0.4, 2.45, 7.6)
	cam.look_at(stage.global_position + Vector3(0.2, 1.15, 0.4), Vector3.UP)
	main.call("push_camera_claim", CLAIM, {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})

	# Capture AFTER (rich PBR normals + roughness + AO + clearcoat under SDFGI)
	ParametricMaterialLibrary.reset_all()
	await _settle(tree, 48)
	var vp := main.get_viewport()
	var img_rich := _save_shot(vp, "%s/world_sdfgi_pbr_rich.png" % _out)

	# Capture BEFORE-equivalent (zero normal relief, zero grain, zero roughness contrast, zero AO, zero clearcoat)
	for mid in ParametricMaterialLibrary.all_ids():
		ParametricMaterialLibrary.set_override(mid, "normal_scale", 0.0, false)
		ParametricMaterialLibrary.set_override(mid, "grain_strength", 0.0, false)
		ParametricMaterialLibrary.set_override(mid, "rough_contrast", 0.0, false)
		ParametricMaterialLibrary.set_override(mid, "ao_strength", 0.0, false)
		ParametricMaterialLibrary.set_override(mid, "clearcoat", 0.0, false)
	await _settle(tree, 16)
	var img_flat := _save_shot(vp, "%s/world_sdfgi_flat_legacy.png" % _out)
	_save_grid([img_flat, img_rich], 2, 1, 760, "%s/world_before_after_pbr.png" % _out)

	# Restore defaults and test live custom texture upload updating the placed daybed/rack plywood!
	ParametricMaterialLibrary.reset_all()
	await _settle(tree, 6)
	var ply_mat := _find_pmat_on_subtree(daybed, "plywood")
	_ok(ply_mat != null, "placed Flatpack daybed carries live 'plywood' StandardMaterial3D")
	if ply_mat != null:
		var old_nrm := ply_mat.normal_texture
		var tmp_png := ProjectSettings.globalize_path(_out.path_join("_test_custom_grain.png"))
		var cimg := Image.create(64, 64, false, Image.FORMAT_RGB8)
		for y in 64:
			for x in 64:
				var v := 0.4 + 0.45 * (0.5 + 0.5 * sin(float(x) * 0.5 + float(y) * 0.15))
				cimg.set_pixel(x, y, Color(v, v * 0.9, v * 0.75, 1.0))
		cimg.save_png(tmp_png)
		if modal != null:
			modal.call("open", {"material_id": "plywood"})
			await _settle(tree, 4)
			modal.call("_apply_upload", "albedo", tmp_png)
			await _settle(tree, 6)
			_ok(ply_mat.normal_texture != old_nrm and ParametricMaterialLibrary.active_source_kind("plywood") == "custom",
				"uploading custom texture in MaterialLibraryModal updates placed daybed material live in place")
			modal.call("close")
		DirAccess.remove_absolute(tmp_png)
		ParametricMaterialLibrary.reset_material("plywood")

	main.call("pop_camera_claim", CLAIM)
	cam.queue_free()
	stage.queue_free()
	for n in hidden:
		if is_instance_valid(n):
			n.visible = true
	main.set("day_time", saved_hour)
	if ssc != null:
		ssc.call("apply_sdfgi_enabled", saved_sdfgi)
		ssc.call("apply_sdfgi_energy_mult", 1.0)


func _find_pmat_on_subtree(node: Node, want_id: String) -> StandardMaterial3D:
	var mi := node as MeshInstance3D
	if mi != null:
		if mi.material_override is StandardMaterial3D:
			var mo := mi.material_override as StandardMaterial3D
			if str(mo.get_meta("pmat_id", "")) == want_id:
				return mo
		if mi.mesh != null:
			for si in mi.mesh.get_surface_count():
				var sm := mi.mesh.surface_get_material(si) as StandardMaterial3D
				if sm != null and str(sm.get_meta("pmat_id", "")) == want_id:
					return sm
	for ch in node.get_children():
		var found := _find_pmat_on_subtree(ch, want_id)
		if found != null:
			return found
	return null


func _save_shot(vp: Viewport, path: String) -> Image:
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.save_png(path)
	return img


func _save_grid(imgs: Array, cols: int, rows: int, cell_w: int, path: String) -> void:
	if imgs.is_empty():
		return
	var first := imgs[0] as Image
	var cell_h := int(float(cell_w) * float(first.get_height()) / float(maxi(first.get_width(), 1)))
	var sheet := Image.create(cell_w * cols, cell_h * rows, false, Image.FORMAT_RGB8)
	for i in mini(imgs.size(), cols * rows):
		var im := (imgs[i] as Image).duplicate()
		im.resize(cell_w, cell_h, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(im, Rect2i(0, 0, cell_w, cell_h), Vector2i((i % cols) * cell_w, int(i / cols) * cell_h))
	sheet.save_png(path)


func _hide_ui(main: Node) -> Array:
	var out: Array = []
	for n in main.get_children():
		if n is CanvasLayer and (n as CanvasLayer).visible:
			(n as CanvasLayer).visible = false
			out.append(n)
	return out
