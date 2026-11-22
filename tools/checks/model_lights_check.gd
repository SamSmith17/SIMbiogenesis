extends RefCounted

## End-to-end verification of model-attached lighting & strings across modals,
## world placement, prop moves, and J Light Studio (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/model_lights_check.gd -Label model_lights -Timeout 900

var _fails: Array = []
var _dir := "user://screenshots/model_lights"


func _ok(cond: bool, what: String) -> void:
	print("model-lights %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "_shots_label" in harness and not str(harness.get("_shots_label")).is_empty():
		_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var player := main.get_node_or_null("Player") as Node3D
	var vp := main.get_viewport()
	_ok(loader != null and player != null, "TerrainLoader world with player")
	if loader == null or player == null:
		return {"ok": false, "fails": _fails}
	if main.has_method("settlement_view_open") and bool(main.call("settlement_view_open")):
		(main.get("settlement_view") as Node).call("close")
		await _frames(tree, 15)

	main.set("time_scale", 0.0)
	main.set("day_time", 22.0)   # Night so dusk_dawn lights shine vividly!
	await _frames(tree, 15)

	var base := Vector2(player.global_position.x, player.global_position.z)
	var spot := _open_spot(main, loader, base)
	var placed_ids: Array = []

	# 1. GREENHOUSE: enable grow lights -> default blurple + dusk_dawn, night preview in modal, place in world!
	var gh_modal: Node = load("res://scenes/ui/greenhouselab_modal.gd").call("open", tree, {})
	await _frames(tree, 25)
	gh_modal.call("_set_field", "beds.lights", true)
	await _frames(tree, 10)
	var gh_lp := gh_modal.find_child("ModelLightPanel", true, false) as ModelLightPanel
	_ok(gh_lp != null and gh_lp.items().size() > 0, "Greenhouse modal populates grow lights when enabled")
	if gh_lp != null:
		_ok(str(gh_lp.items()[0]["fields"]["color"]) == "df28ff"
			and str(gh_lp.items()[0]["fields"]["schedule"]) == "dusk_dawn",
			"Greenhouse grow lights default to red/blue LED (df28ff) and sunset-to-sunrise")
		var night_chk := gh_lp.find_child("night_preview_toggle", true, false) as CheckBox
		if night_chk != null:
			night_chk.button_pressed = true
	var audit_gh := UiAudit.run(vp)
	_ok(int(audit_gh.get("errors", 0)) == 0, "Greenhouse modal with lighting passes UiAudit (%d errors)" % int(audit_gh.get("errors", 0)))
	await _frames(tree, 15)
	await _shot(main, "01_greenhouse_modal_blurple_night")
	# Test switching to full_spectrum and back to blurple
	gh_modal.call("_set_field", "lights.spectrum", "full_spectrum")
	await _frames(tree, 8)
	_ok(gh_lp != null and str(gh_lp.items()[0]["fields"]["color"]) == "fff1dc",
		"Switching greenhouse spectrum to Full spectrum updates grow lights to warm white")
	gh_modal.call("_set_field", "lights.spectrum", "blurple")
	await _frames(tree, 8)
	var gh_spec: Dictionary = gh_modal.call("current_spec")
	gh_modal.call("close")
	await _frames(tree, 10)

	var gh_pid := PlacedPropService.place_prepped_at(main, GreenhouseBuilder.MODEL_ID, {
		"record_extra": {
			GreenhouseSpec.KEY: GreenhouseSpec.to_json_safe(gh_spec),
			PropModelLights.KEY_MODEL_LIGHTS: gh_spec.get(PropModelLights.KEY_MODEL_LIGHTS, []),
			"collision_enabled": true, "walk_in": true,
		}
	}, spot.x, spot.y, 0.0)
	placed_ids.append(gh_pid)
	await _frames(tree, 30)
	var gh_lights := PropModelLights.ids_for_prop(main, gh_pid)
	_ok(gh_lights.size() >= 2, "Placed greenhouse created %d hosted J grow lights" % gh_lights.size())

	# 2. DOME: default peak omni light + add perimeter string inside Dome modal!
	var loader_dome: Control = loader.call("domelab_designer") if loader.has_method("domelab_designer") else null
	if loader.has_method("open_domelab"):
		loader.call("open_domelab")
		await _frames(tree, 20)
		loader_dome = main.find_child("DomeLabModal", true, false) as Control
	var dome_spec := DomeLabSpec.default_spec("geodesic")
	if loader_dome != null:
		var dlp := loader_dome.find_child("ModelLightPanel", true, false) as ModelLightPanel
		_ok(dlp != null and dlp.items().size() == 1 and str(dlp.items()[0]["slot"]) == "dome_peak",
			"Dome modal opens with 1 default peak omni light")
		if dlp != null:
			var qbtn := dlp.find_child("quick_dome_eave_ring", true, false) as Button
			if qbtn != null:
				qbtn.pressed.emit()
			var nchk := dlp.find_child("night_preview_toggle", true, false) as CheckBox
			if nchk != null:
				nchk.button_pressed = true
		var audit_dm := UiAudit.run(vp)
		_ok(int(audit_dm.get("errors", 0)) == 0, "Dome modal passes UiAudit (%d errors)" % int(audit_dm.get("errors", 0)))
		await _frames(tree, 15)
		await _shot(main, "02_dome_modal_peak_and_string")
		if dlp != null:
			dome_spec[PropModelLights.KEY_MODEL_LIGHTS] = dlp.serialized_items()
		loader_dome.call("close")
		await _frames(tree, 10)

	var dome_pos := spot + Vector2(18.0, 0.0)
	var dome_pid := PlacedPropService.place_prepped_at(main, DomeLabBuilder.MODEL_ID, {
		"record_extra": {
			"domelab_spec": DomeLabSpec.to_json_safe(dome_spec),
			PropModelLights.KEY_MODEL_LIGHTS: dome_spec.get(PropModelLights.KEY_MODEL_LIGHTS, []),
			"collision_enabled": true,
		}
	}, dome_pos.x, dome_pos.y, 0.0)
	placed_ids.append(dome_pid)
	await _frames(tree, 15)
	_ok(PropModelLights.count_for_prop(main, dome_pid) == 2,
		"Placed dome has peak omni + perimeter string (%d)" % PropModelLights.count_for_prop(main, dome_pid))

	# 3. SHOWER HOUSE: open ShowerHouseModal, add porch festoon string, UiAudit, place!
	var sh_modal := ShowerHouseModal.open(tree, {})
	await _frames(tree, 20)
	var sh_lp := sh_modal.find_child("ModelLightPanel", true, false) as ModelLightPanel
	_ok(sh_lp != null and sh_lp.items().size() == 4, "Shower house modal opens with 4 stall lights")
	if sh_lp != null:
		var pq := sh_lp.find_child("quick_shower_porch_string", true, false) as Button
		if pq != null:
			pq.pressed.emit()
	var sh_night := sh_modal.find_child("studio_night", true, false) as CheckButton
	if sh_night != null:
		sh_night.button_pressed = true
	var audit_sh := UiAudit.run(vp)
	if int(audit_sh.get("errors", 0)) > 0:
		for fd in audit_sh.get("findings", []):
			if str((fd as Dictionary).get("severity", "")) == "error":
				print("  audit finding: ", fd)
	_ok(int(audit_sh.get("errors", 0)) == 0, "Shower house modal passes UiAudit (%d errors)" % int(audit_sh.get("errors", 0)))
	await _frames(tree, 15)
	await _shot(main, "03_shower_house_modal_night")
	var sh_spec: Dictionary = sh_modal.call("current_spec")
	sh_modal.call("close")
	await _frames(tree, 10)

	var sh_pos := spot + Vector2(0.0, 16.0)
	var sh_pid := PlacedPropService.place_prepped_at(main, ShowerHouseBuilder.MODEL_ID, {
		"record_extra": {
			"shower_spec": sh_spec,
			PropModelLights.KEY_MODEL_LIGHTS: sh_spec.get(PropModelLights.KEY_MODEL_LIGHTS, []),
			"collision_enabled": true,
		}
	}, sh_pos.x, sh_pos.y, 0.0)
	placed_ids.append(sh_pid)
	await _frames(tree, 15)
	_ok(PropModelLights.count_for_prop(main, sh_pid) == 5,
		"Placed shower house has 4 stall lights + 1 porch string (%d)" % PropModelLights.count_for_prop(main, sh_pid))

	# 4. EARTHSHIP: 3-room Earthship -> 3 warm white ceiling bulbs!
	var es_modal: Node = load("res://scenes/ui/earthshiplab_modal.gd").call("open", tree, {})
	await _frames(tree, 25)
	var es_lp := es_modal.find_child("ModelLightPanel", true, false) as ModelLightPanel
	_ok(es_lp != null and es_lp.items().size() == 3, "Earthship modal opens with 3 room ceiling bulbs")
	var audit_es := UiAudit.run(vp)
	_ok(int(audit_es.get("errors", 0)) == 0, "Earthship modal passes UiAudit (%d errors)" % int(audit_es.get("errors", 0)))
	var es_spec: Dictionary = es_modal.call("current_spec")
	es_modal.call("close")
	await _frames(tree, 10)

	var es_pos := spot + Vector2(-28.0, 0.0)
	var es_pid := PlacedPropService.place_prepped_at(main, EarthshipBuilder.MODEL_ID, {
		"record_extra": {
			EarthshipSpec.KEY: EarthshipSpec.to_json_safe(es_spec),
			"collision_enabled": true,
		}
	}, es_pos.x, es_pos.y, 0.0)
	placed_ids.append(es_pid)
	await _frames(tree, 30)
	_ok(PropModelLights.count_for_prop(main, es_pid) == 3,
		"Placed 3-room Earthship has 3 ceiling bulbs (%d)" % PropModelLights.count_for_prop(main, es_pid))

	# 4b. TOROID & PALLET RACK modals: add ring string / bay bulbs inside modals, UiAudit!
	if loader.has_method("open_toroidlab"):
		loader.call("open_toroidlab")
		await _frames(tree, 20)
		var tor_modal := main.find_child("ToroidLabModal", true, false) as Control
		if tor_modal != null:
			var tlp := tor_modal.find_child("ModelLightPanel", true, false) as ModelLightPanel
			if tlp != null:
				var tq := tlp.find_child("quick_toroid_throat_ring", true, false) as Button
				if tq != null:
					tq.pressed.emit()
				var tn := tlp.find_child("night_preview_toggle", true, false) as CheckBox
				if tn != null:
					tn.button_pressed = true
			_ok(tlp != null and tlp.items().size() >= 1, "Toroid modal adds throat ring string")
			var audit_tr := UiAudit.run(vp)
			_ok(int(audit_tr.get("errors", 0)) == 0, "Toroid modal passes UiAudit (%d errors)" % int(audit_tr.get("errors", 0)))
			await _frames(tree, 12)
			await _shot(main, "03b_toroid_modal_night")
			tor_modal.call("close")
			await _frames(tree, 8)

	if loader.has_method("open_pallet_rack_builder"):
		loader.call("open_pallet_rack_builder")
		await _frames(tree, 20)
		var pr_modal := main.find_child("PalletRackBuilderUI", true, false) as Control
		if pr_modal == null:
			pr_modal = loader.get("_pallet_rack_builder_ui") as Control
		if pr_modal != null:
			var rlp := pr_modal.find_child("ModelLightPanel", true, false) as ModelLightPanel
			if rlp != null:
				var rq := rlp.find_child("quick_rack_bay_bulbs", true, false) as Button
				if rq != null:
					rq.pressed.emit()
				var rn := rlp.find_child("night_preview_toggle", true, false) as CheckBox
				if rn != null:
					rn.button_pressed = true
			_ok(rlp != null and rlp.items().size() >= 2, "Pallet rack modal adds bay ceiling bulbs (%d)" % (rlp.items().size() if rlp != null else 0))
			var audit_pr := UiAudit.run(vp)
			_ok(int(audit_pr.get("errors", 0)) == 0, "Pallet rack modal passes UiAudit (%d errors)" % int(audit_pr.get("errors", 0)))
			await _frames(tree, 12)
			await _shot(main, "03c_pallet_rack_modal_night")
			pr_modal.call("close")
			await _frames(tree, 8)

	# 5. Night shots of the lit structures in the world!
	var cam := Camera3D.new()
	cam.fov = 58.0
	main.add_child(cam)
	main.call("push_camera_claim", "model_lights_check", {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})
	var ui := main.get_node_or_null("UILayer") as CanvasLayer
	if ui != null:
		ui.visible = false
	var gy_sh := TerrainSurfaceQuery.ground_height_at(main, sh_pos.x, sh_pos.y)
	cam.look_at_from_position(Vector3(sh_pos.x + 2.8, gy_sh + 2.3, sh_pos.y + 6.2),
		Vector3(sh_pos.x, gy_sh + 1.4, sh_pos.y), Vector3.UP)
	await _frames(tree, 25)
	await _shot(main, "04_world_night_shower_house")

	var gy_dome := TerrainSurfaceQuery.ground_height_at(main, dome_pos.x, dome_pos.y)
	cam.look_at_from_position(Vector3(dome_pos.x + 6.5, gy_dome + 4.8, dome_pos.y + 8.5),
		Vector3(dome_pos.x, gy_dome + 1.8, dome_pos.y), Vector3.UP)
	await _frames(tree, 15)
	await _shot(main, "04a_world_night_dome")

	var gy_es := TerrainSurfaceQuery.ground_height_at(main, es_pos.x, es_pos.y)
	cam.look_at_from_position(Vector3(es_pos.x + 5.0, gy_es + 2.4, es_pos.y + 11.5),
		Vector3(es_pos.x, gy_es + 0.4, es_pos.y - 2.0), Vector3.UP)
	await _frames(tree, 15)
	await _shot(main, "04b_world_night_earthship_rooms")

	# Close-up inside greenhouse showing blurple glow
	var gy := TerrainSurfaceQuery.ground_height_at(main, spot.x, spot.y)
	cam.look_at_from_position(Vector3(spot.x + 8.5, gy + 3.2, spot.y + 9.5),
		Vector3(spot.x, gy + 1.2, spot.y), Vector3.UP)
	await _frames(tree, 15)
	await _shot(main, "05_world_greenhouse_blurple")

	if ui != null:
		ui.visible = true
	main.call("pop_camera_claim", "model_lights_check")
	cam.queue_free()

	# 6. Move dome & verify both peak omni + perimeter string moved with it,
	#    then edit in J Light Studio and verify PropLightsModal reads the J edit!
	var d_ids := PropModelLights.ids_for_prop(main, dome_pid)
	var llayer := PlacedLightService.get_layer(main)
	var p_before := llayer.position_of(llayer.find_light(str(d_ids[0])))
	PlacedPropService.update_prop_record(main, dome_pid, {"x": dome_pos.x + 6.0, "yaw": 45.0}, true)
	await _frames(tree, 10)
	var p_after := llayer.position_of(llayer.find_light(str(d_ids[0])))
	_ok(absf((p_after - p_before).x - 6.0) < 0.1,
		"Moving the dome carries its attached lights (dx=%.2f m)" % (p_after - p_before).x)

	PlacedLightService.open_studio_on(main, [str(d_ids[0])])
	PlacedLightService.set_field(main, [str(d_ids[0])], "color", "33ff99", false)
	PlacedLightService.commit(main)
	var jdock := PlacedLightService.find_dock(main)
	if jdock != null and jdock.has_method("close"):
		jdock.call("close")
	await _frames(tree, 8)

	var pl_modal := PropLightsModal.open(tree, dome_pid)
	await _frames(tree, 15)
	var pl_panel := pl_modal.find_child("ModelLightPanel", true, false) as ModelLightPanel
	var j_synced := false
	if pl_panel != null:
		for it in pl_panel.items():
			if str((it as Dictionary)["fields"].get("color", "")) == "33ff99":
				j_synced = true
	_ok(j_synced, "PropLightsModal reads back colour edits made in J Light Studio")
	var audit_pl := UiAudit.run(vp)
	_ok(int(audit_pl.get("errors", 0)) == 0, "PropLightsModal passes UiAudit (%d errors)" % int(audit_pl.get("errors", 0)))
	pl_modal.call("close")
	await _frames(tree, 10)

	# Cleanup
	for pid in placed_ids:
		if not str(pid).is_empty():
			loader.call("delete_prop_by_id", str(pid))
	await _frames(tree, 10)
	_ok(PropModelLights.count_for_prop(main, dome_pid) == 0
		and PropModelLights.count_for_prop(main, sh_pid) == 0,
		"Deleting placed props cleans up their model_owned lights")

	return {"ok": _fails.is_empty(), "fails": _fails}


func _open_spot(main: Node, loader: Node, near: Vector2) -> Vector2:
	var recs: Array = loader.call("placed_prop_records") if loader.has_method("placed_prop_records") else []
	for ring in range(3, 18):
		for k in 16:
			var a := TAU * float(k) / 16.0
			var c := near + Vector2(cos(a), sin(a)) * (float(ring) * 24.0)
			var ok := true
			for r in recs:
				var q := Vector2(float((r as Dictionary).get("x", 0.0)), float((r as Dictionary).get("z", 0.0)))
				if q.distance_to(c) < 45.0:
					ok = false
					break
			if ok:
				return c
	return near + Vector2(80.0, 80.0)
