extends RefCounted

## Building designer on Mount Vernon (sandbox). Opens a real OSM house, places
## a door and a porch, changes a width, undoes it, applies, then places a
## cottage and shoots it at night with the windows lit.
##
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/building_designer_check.gd -Label building_designer

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("buildingdesigner %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(vp: Viewport, path: String) -> void:
	var img := vp.get_texture().get_image()
	if img == null:
		_ok(false, "shot %s" % path.get_file())
		return
	img.save_png(path)
	_ok(img.get_width() > 8, "shot %s" % path.get_file())


func _aim(main: Node, at: Vector3) -> void:
	var cam := main.get_viewport().get_camera_3d()
	if cam == null:
		return
	cam.global_position = at + Vector3(14.0, 7.0, 16.0)
	cam.look_at(at + Vector3.UP * 2.0, Vector3.UP)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var label := str(harness.get("_shots_label"))
	if label.is_empty():
		label = "building_designer"
	var dir := "user://screenshots/%s" % label
	DirAccess.make_dir_recursive_absolute(dir)
	var loader := main.find_child("TerrainLoader", true, false)
	_ok(loader != null, "the world has a terrain loader")
	if loader == null:
		print("buildingdesigner %s" % ("PASS" if _fails.is_empty() else "FAIL"))
		return {"ok": _fails.is_empty()}
	var data: Variant = loader.get("_buildings_data")
	var idx := -1
	var centre := Vector2.ZERO
	if data is Array:
		for b in data:
			if not (b is Dictionary):
				continue
			var pts: Variant = (b as Dictionary).get("points", PackedVector2Array())
			if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
				continue
			var c := Vector2.ZERO
			for q in pts:
				c += q
			c /= float((pts as PackedVector2Array).size())
			idx = int((b as Dictionary).get("idx", -1))
			centre = c
			break
	_ok(idx >= 0, "an OSM building is on the map")
	if idx < 0:
		print("buildingdesigner FAIL")
		return {"ok": false}
	var saved: Dictionary = loader.call("get_building_style", idx)
	var hour := float(main.get("day_time"))
	var player := main.find_child("Player", true, false)
	if player != null:
		player.set_process(false)
		player.set_physics_process(false)
	loader.call("open_building_builder", idx)
	await _settle(tree, 25)
	var ui: Node = loader.get("_building_builder_ui")
	_ok(ui != null and bool(ui.get("visible")), "the designer opened on the house")
	if ui == null:
		print("buildingdesigner FAIL")
		return {"ok": false}
	var before := 0
	var style: Dictionary = ui.get("_working_style")
	var listed: Variant = style.get("elements", [])
	if listed is Array:
		before = (listed as Array).size()
	var elems: Array = []
	ui.call("place_feature", "door", 0, 2.0)
	style = ui.get("_working_style")
	elems = style.get("elements", []) if style.get("elements", []) is Array else []
	if elems.size() < before + 1:
		for trial in [1.2, 3.4, 5.5, 8.0, 11.0, 15.0]:
			ui.call("place_feature", "door", 0, float(trial))
			style = ui.get("_working_style")
			elems = style.get("elements", []) if style.get("elements", []) is Array else []
			if elems.size() >= before + 1:
				break
	ui.call("place_feature", "porch", 0, 4.0)
	style = ui.get("_working_style")
	elems = style.get("elements", []) if style.get("elements", []) is Array else []
	_ok(elems.size() >= before + 2, "a door and a porch landed on the wall")
	ui.call("set_selected_width", 1.2)
	style = ui.get("_working_style")
	elems = style.get("elements", [])
	var widened := false
	if elems.size() > 0 and elems[elems.size() - 1] is Dictionary:
		widened = is_equal_approx(float((elems[elems.size() - 1] as Dictionary).get("w_m", 0.0)), 1.2)
	_ok(widened, "the selected width changed")
	ui.call("undo_style")
	style = ui.get("_working_style")
	elems = style.get("elements", []) if style.get("elements", []) is Array else []
	var restored := true
	if elems.size() > 0 and elems[elems.size() - 1] is Dictionary:
		restored = not is_equal_approx(float((elems[elems.size() - 1] as Dictionary).get("w_m", -1.0)), 1.2)
	_ok(restored, "undo put the width back")
	await _settle(tree, 20)
	var studio: SubViewport = ui.get("_viewport")
	if studio != null:
		_shot(studio, "%s/studio.png" % dir)
	ui.call("_apply_to_map")
	await _settle(tree, 30)
	var gy := float(loader.call("ground_height_at", centre.x, centre.y))
	var house_at := Vector3(centre.x, gy, centre.y)
	_aim(main, house_at)
	await _settle(tree, 8)
	_shot(main.get_viewport(), "%s/world.png" % dir)
	var spec: Dictionary = BuildingPresets.cottage()
	var lights: Array = spec.get("elements", [])
	lights.append({"type": "light", "style": "sconce", "edge": 0, "u_m": 5.4,
		"v_m": 1.8, "lit": "on", "energy": 1.2})
	spec["elements"] = lights
	var px := centre.x + 22.0
	var pz := centre.y + 8.0
	var prop_id := PlacedPropService.place_prepped_at(main, BuildingFeatures.MODEL_ID, {
		"record_extra": {"building_spec": spec},
	}, px, pz, 0.0)
	_ok(not prop_id.is_empty(), "the cottage placed in the world")
	main.set("day_time", 22.0)
	await _settle(tree, 40)
	var py := float(loader.call("ground_height_at", px, pz))
	_aim(main, Vector3(px, py, pz))
	await _settle(tree, 8)
	_shot(main.get_viewport(), "%s/night.png" % dir)
	var glowing := false
	if not prop_id.is_empty():
		var prop := PlacedPropRuntime.find_by_prop_id(main, prop_id) if PlacedPropRuntime else null
		var root: Node = prop if prop != null else null
		if root != null:
			var mi := root.find_child("Mesh", true, false) as MeshInstance3D
			if mi != null:
				for ch in mi.get_children():
					if ch is MeshInstance3D and bool(ch.get_meta("bld_glass", false)):
						var mat := (ch as MeshInstance3D).material_override as StandardMaterial3D
						if mat != null and mat.emission_energy_multiplier > 0.5:
							glowing = true
							break
	_ok(glowing, "the cottage windows glow at night")
	if not prop_id.is_empty() and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", prop_id)
	if saved.is_empty() and loader.has_method("clear_building_style"):
		loader.call("clear_building_style", idx)
	else:
		loader.call("apply_building_style", idx, saved)
	main.set("day_time", hour)
	if player != null:
		player.set_process(true)
		player.set_physics_process(true)
	var ok := _fails.is_empty()
	print("buildingdesigner %s" % ("PASS" if ok else "FAIL"))
	return {"ok": ok}
