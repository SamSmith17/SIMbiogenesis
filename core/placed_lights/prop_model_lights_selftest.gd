extends SceneTree

## Offline selftest for PropModelLights (core/placed_lights/prop_model_lights.gd):
##   - Dome default peak omni light (geodesic + crafted dome), resize tracking, toggle off
##   - Earthship warm white ceiling bulb in every room, room-count scaling, earthworks lights off
##   - Shower house warm ceiling light in every stall (single-row & two-row)
##   - Greenhouse grow lights: off -> 0; enabled -> hydroponic red/blue LED ("blurple", df28ff)
##     + sunset-to-sunrise ("dusk_dawn") by default + GrowLightRack red/blue diodes wound CW;
##     switching to "full_spectrum" -> fff1dc
##   - Quick-add presets across Dome, Toroid, PalletRack, Greenhouse, Earthship, ShowerHouse
##   - World sync: host_id, model_owned, LightHosts follow on move+turn, J edit read back into
##     modal (two-way sync), J deletion respected across reload, packed host hides lights,
##     prop deletion removes model_owned lights while keeping hand-placed J lights
##   - Pure-mesh studio raycaster hit + normal accuracy
##
##   Godot --headless --path . --script core/placed_lights/prop_model_lights_selftest.gd

const EXPECTED_CHECKS := 41

var _checks := 0
var _fails := 0
var _ran := false


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if cond:
		print("PASS  ", what)
	else:
		_fails += 1
		print("FAIL  ", what, ("  (" + detail + ")") if not detail.is_empty() else "")


func _near(a: float, b: float, tol: float = 0.02) -> bool:
	return absf(a - b) <= tol


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_test_dome_defaults()
	_test_earthship_defaults()
	_test_shower_defaults()
	_test_greenhouse_growlights()
	_test_quick_presets_and_raycast()
	_test_world_sync_and_j_roundtrip()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL  check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("PROP MODEL LIGHTS SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)
	return true


func _test_dome_defaults() -> void:
	var s := DomeLabSpec.default_spec("geodesic")
	var d := DomeLabDesign.solve(s)
	var h := float(d["stats"]["height_m"])
	var slots := PropModelLights.default_slots_for(DomeLabBuilder.MODEL_ID, s)
	_ok(slots.size() == 1 and str(slots[0]["slot"]) == "dome_peak" and str(slots[0]["kind"]) == "omni",
		"dome has 1 peak omni light by default")
	_ok(_near(float(slots[0]["x"]), 0.0) and _near(float(slots[0]["z"]), 0.0)
		and float(slots[0]["y"]) > h * 0.75 and float(slots[0]["y"]) < h,
		"dome peak light hangs just inside the apex (y=%.2f, h=%.2f)" % [float(slots[0]["y"]), h])
	_ok(str(slots[0]["fields"]["schedule"]) == "dusk_dawn" and bool(slots[0]["fields"]["show_body"]),
		"dome peak light defaults to dusk-to-dawn with visible bulb")

	var big := s.duplicate(true)
	big["radius_m"] = 9.0
	var synced := PropModelLights.sync_parametric_slots(slots, DomeLabBuilder.MODEL_ID, big)
	_ok(synced.size() == 1 and float(synced[0]["y"]) > float(slots[0]["y"]) + 1.5,
		"resizing dome moves peak light up to the new apex")

	var off_spec := s.duplicate(true)
	off_spec["peak_light"] = false
	off_spec = DomeLabSpec.resolve(off_spec)
	_ok(PropModelLights.default_slots_for(DomeLabBuilder.MODEL_ID, off_spec).is_empty(),
		"peak_light=false disables the default dome peak light")
	_ok(DomeLabSpec.key_of(s) == DomeLabSpec.key_of(off_spec),
		"DomeLabSpec.key_of ignores lighting fields (geometry cache preserved)")

	var cd := PropModelLights.default_slots_for(GeodesicDomeBuilder.MODEL_ID, {"radius_m": 3.0})
	_ok(cd.size() == 1 and str(cd[0]["slot"]) == "dome_peak",
		"crafted 2V geodesic_dome also gets a peak omni light by default")


func _test_earthship_defaults() -> void:
	var s3 := EarthshipSpec.resolve({"modules": 3})
	var d3 := EarthshipDesign.solve(s3)
	_ok(not bool(d3["earthworks_simple"].get("lights", true)),
		"EarthshipDesign disables generic earthworks grid lights in favour of room bulbs")
	var slots3 := PropModelLights.default_slots_for(EarthshipBuilder.MODEL_ID, s3)
	_ok(slots3.size() == 3, "3-room Earthship gets 3 ceiling bulbs (%d)" % slots3.size())
	var in_rooms := true
	var warm_bulbs := true
	var want_y := float(d3["frame"]["yc"]) - float(s3["viga_d"]) - 0.08
	for i in 3:
		var r: Dictionary = d3["rooms"][i]
		var sl: Dictionary = slots3[i]
		var rx := (float(r["x0"]) + float(r["x1"])) * 0.5
		var rz := (float(r["z0"]) + float(r["z1"])) * 0.5
		if not (_near(float(sl["x"]), rx) and _near(float(sl["z"]), rz) and _near(float(sl["y"]), want_y)):
			in_rooms = false
		var f: Dictionary = sl["fields"]
		if not (bool(f["show_body"]) and str(f["color"]) == "ffd194"):
			warm_bulbs = false
	_ok(in_rooms, "each Earthship bulb sits at the ceiling centre of its room")
	_ok(warm_bulbs, "each Earthship room light is a visible warm white bulb")

	var s5 := EarthshipSpec.resolve({"modules": 5})
	var slots5 := PropModelLights.sync_parametric_slots(slots3, EarthshipBuilder.MODEL_ID, s5)
	_ok(slots5.size() == 5, "growing Earthship to 5 rooms yields 5 ceiling bulbs")


func _test_shower_defaults() -> void:
	var sh4 := PropModelLights.default_slots_for(ShowerHouseBuilder.MODEL_ID, {"stalls": 4})
	_ok(sh4.size() == 4, "4-stall shower house has 4 stall lights")
	var s8 := ShowerHouseBuilder.resolve({"stalls": 8, "rows": 2})
	var sh8 := PropModelLights.default_slots_for(ShowerHouseBuilder.MODEL_ID, s8)
	var row0 := 0
	var row1 := 0
	for k in sh8.size():
		var sl: Dictionary = sh8[k]
		if float(sl["z"]) > 0.1:
			row0 += 1
		elif float(sl["z"]) < -0.1:
			row1 += 1
	_ok(sh8.size() == 8 and row0 == 4 and row1 == 4,
		"8-stall two-row shower house places 4 lights per row inside each stall")
	_ok(_near(float(sh4[0]["y"]), ShowerHouseBuilder.FLOOR_Y + ShowerHouseBuilder.WALL_H - 0.06)
		and bool(sh4[0]["fields"]["show_body"]),
		"stall lights hang under the shed roof above the shower head")


func _winding_ok(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for si in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if idx.size() > 0 else v.size()
		for k in range(0, count, 3):
			var i0 := idx[k] if idx.size() > 0 else k
			var i1 := idx[k + 1] if idx.size() > 0 else k + 1
			var i2 := idx[k + 2] if idx.size() > 0 else k + 2
			var cr := (v[i1] - v[i0]).cross(v[i2] - v[i0])
			if cr.length() > 1e-9 and cr.dot(nn[i0]) > 0.0:
				return false
	return true


func _test_greenhouse_growlights() -> void:
	var s_off := GreenhouseSpec.default_spec("gable")
	_ok(PropModelLights.default_slots_for(GreenhouseBuilder.MODEL_ID, s_off).is_empty(),
		"greenhouse with grow lights disabled has 0 default grow lights")
	_ok(str(s_off["lights"]["spectrum"]) == "blurple" and str(s_off["lights"]["schedule"]) == "dusk_dawn",
		"greenhouse spec defaults to blurple (red/blue LED) and sunset-to-sunrise (dusk_dawn)")

	var s_on := s_off.duplicate(true)
	s_on["beds"]["lights"] = true
	var d_on := GreenhouseDesign.solve(s_on)
	var slots_on := PropModelLights.default_slots_for(GreenhouseBuilder.MODEL_ID, s_on)
	_ok(slots_on.size() >= (d_on["beds"] as Array).size(),
		"greenhouse with grow lights enabled places lights over every lit bed (%d lights for %d beds)" % [
			slots_on.size(), (d_on["beds"] as Array).size()])
	_ok(str(slots_on[0]["fields"]["color"]) == "df28ff" and str(slots_on[0]["fields"]["schedule"]) == "dusk_dawn"
		and str(slots_on[0]["preset"]) == "grow_blurple",
		"grow lights default to hydroponic red/blue LED colour (df28ff) and dusk_dawn schedule")

	var rack_b := GrowLightRack.build_node({"length_m": 4.0, "width_m": 1.2, "hang_m": 1.0, "spectrum": "blurple"})
	var red_d := rack_b.get_node_or_null("RedDiodes") as MeshInstance3D
	var blue_d := rack_b.get_node_or_null("BlueDiodes") as MeshInstance3D
	_ok(red_d != null and blue_d != null and _winding_ok(red_d.mesh) and _winding_ok(blue_d.mesh),
		"blurple GrowLightRack builds CW-wound RedDiodes and BlueDiodes strips")
	GrowLightRack.set_lit(rack_b, true)
	_ok((red_d.material_override as StandardMaterial3D).emission_energy_multiplier > 1.0
		and (blue_d.material_override as StandardMaterial3D).emission_energy_multiplier > 1.0,
		"GrowLightRack.set_lit illuminates both red and blue LED strips")
	rack_b.free()

	var s_full := s_on.duplicate(true)
	s_full["lights"]["spectrum"] = "full_spectrum"
	var synced_full := PropModelLights.sync_parametric_slots(slots_on, GreenhouseBuilder.MODEL_ID, s_full, [], true)
	_ok(str(synced_full[0]["fields"]["color"]) == "fff1dc" and str(synced_full[0]["preset"]) == "grow_full",
		"switching spectrum to full_spectrum updates grow lights to warm white fff1dc")
	var rack_f := GrowLightRack.build_node({"length_m": 4.0, "width_m": 1.2, "hang_m": 1.0, "spectrum": "full_spectrum"})
	_ok(rack_f.get_node_or_null("RedDiodes") == null, "full_spectrum GrowLightRack omits red/blue diode strips")
	rack_f.free()


func _test_quick_presets_and_raycast() -> void:
	for pair in [
		[DomeLabBuilder.MODEL_ID, DomeLabSpec.default_spec("geodesic")],
		[ToroidLabBuilder.MODEL_ID, ToroidLabSpec.default_spec()],
		[PalletRackBuilder.MODEL_ID, PalletRackBuilder.default_spec()],
		[GreenhouseBuilder.MODEL_ID, GreenhouseSpec.default_spec("gable")],
		[EarthshipBuilder.MODEL_ID, EarthshipSpec.default_spec()],
		[ShowerHouseBuilder.MODEL_ID, ShowerHouseBuilder.resolve({})],
	]:
		var mid := str(pair[0])
		var sp: Dictionary = pair[1]
		var qp := PropModelLights.quick_presets_for(mid, sp)
		var items: Array = (qp[0]["make"] as Callable).call() if not qp.is_empty() else []
		_ok(not qp.is_empty() and not items.is_empty(),
			"quick_presets_for(%s) builds valid local lights/strings" % mid)

	var house := ShowerHouseBuilder.build_node({"stalls": 4})
	root.add_child(house)
	var hit := PropModelLights.raycast_model(house, Vector3(0.0, 6.0, 0.0), Vector3.DOWN)
	_ok(bool(hit["valid"]) and float((hit["position"] as Vector3).y) > 2.0
		and float((hit["normal"] as Vector3).y) > 0.5,
		"raycast_model hits the shower house roof from above with upward normal")
	var miss := PropModelLights.raycast_model(house, Vector3(50.0, 6.0, 50.0), Vector3.DOWN)
	_ok(not bool(miss["valid"]), "raycast_model misses cleanly off the model")
	house.free()


func _test_world_sync_and_j_roundtrip() -> void:
	var main := Node3D.new()
	main.name = "SelftestPropModelLightsMain"
	root.add_child(main)
	var terrain := Node3D.new()
	terrain.name = "Terrain"
	main.add_child(terrain)

	# Back up any bare-scene prop / light files so nothing leaks to disk.
	var lpath := PlacedLightLayer.path_for_key(PlacedLightService.map_key(main))
	var lhad := FileAccess.file_exists(lpath)
	var lbak := FileAccess.get_file_as_bytes(lpath) if lhad else PackedByteArray()
	var player_layer := PlacedPropService._layer_for_main(main)
	var ppath := player_layer.save_path_for_scene(PlacedPropService._layer_key(main)) if player_layer != null else ""
	var phad := FileAccess.file_exists(ppath)
	var pbak := FileAccess.get_file_as_bytes(ppath) if phad else PackedByteArray()
	var saved_props := player_layer.serialize() if player_layer != null else {}
	if player_layer != null:
		player_layer.props.clear()
	var llayer := PlacedLightService.get_layer(main)
	llayer.lights.clear()
	llayer.styles.clear()
	llayer.groups.clear()
	PlacedLightService.rebuild_all(main)

	# 1. Place a 4-stall shower house -> 4 hosted stall lights created automatically!
	var res := PlacedPropService.place_model_at_xz(main, ShowerHouseBuilder.MODEL_ID, 10.0, 20.0,
		{"yaw": 0.0, "shower_spec": {"stalls": 4}})
	var pid := str(res.get("prop_id", ""))
	_ok(not pid.is_empty(), "placed a 4-stall shower house in test world")
	_ok(PropModelLights.count_for_prop(main, pid) == 4,
		"placing the shower house attaches 4 stall lights (%d)" % PropModelLights.count_for_prop(main, pid))

	var ids := PropModelLights.ids_for_prop(main, pid)
	var rec0 := llayer.find_light(str(ids[0]))
	_ok(str(rec0.get("host_id", "")) == pid and bool(rec0.get("model_owned", false)),
		"stall lights carry host_id == prop_id and model_owned == true")
	var pos_before := llayer.position_of(rec0)

	# 2. Move and rotate the prop -> attached lights follow!
	PlacedPropService.update_prop_record(main, pid, {"x": 18.0, "z": 25.0, "yaw": 90.0}, true)
	var pos_after := llayer.position_of(llayer.find_light(str(ids[0])))
	_ok(pos_after.distance_to(pos_before) > 7.0,
		"moving and rotating the shower house carries its stall lights (moved %.2f m)" % pos_after.distance_to(pos_before))

	# 3. Edit one stall light in J (change colour to cyan) + add a J string hosted on the prop!
	PlacedLightService.set_field(main, [str(ids[0])], "color", "00ffee", false)
	var s_id := PlacedLightService.add_string(main, [Vector3(18.0, 2.4, 23.5), Vector3(18.0, 2.4, 26.5)])
	var prec_now := PlacedPropService.get_prop_record(main, pid)
	var mxf := PlacedPropRuntime.model_world_xf(prec_now, TerrainSurfaceQuery.ground_y_callable(main))
	llayer.find_light(s_id)["host_id"] = pid
	llayer.find_light(s_id)["host_xf"] = LightHosts.xf_to_array(mxf)

	# 4. Read back into modal (two-way sync!)
	var modal_items := PropModelLights.read_for_modal(main, pid, ShowerHouseBuilder.MODEL_ID, prec_now.get("shower_spec", {}))
	var saw_cyan := false
	var saw_string := false
	for it in modal_items:
		var itd := it as Dictionary
		if str(itd.get("kind", "")) == "string":
			saw_string = true
		if str((itd.get("fields", {}) as Dictionary).get("color", "")) == "00ffee":
			saw_cyan = true
	_ok(modal_items.size() == 5 and saw_cyan and saw_string,
		"read_for_modal reads back J colour edit + J-added string in local coordinates")

	# 5. Delete one stall light in J -> world re-sync does NOT resurrect it!
	PlacedLightService.delete_ids(main, [str(ids[1])])
	PropModelLights.sync_prop(main, pid)
	_ok(PropModelLights.count_for_prop(main, pid) == 4,
		"deleting a default light in J is respected across sync_prop (not resurrected)")

	# 6. Packing the prop turns host_packed true (lights off while crated)!
	PlacedPropService.update_prop_record(main, pid, {"packed": true}, false)
	_ok(PlacedLightPower.host_packed(main, llayer.find_light(str(ids[0])))
		and not PlacedLightPower.is_lit(main, llayer.find_light(str(ids[0])), llayer.resolved(llayer.find_light(str(ids[0])))),
		"packing the host prop turns its model_owned lights off")
	PlacedPropService.update_prop_record(main, pid, {"packed": false}, false)
	_ok(not PlacedLightPower.host_packed(main, llayer.find_light(str(ids[0]))),
		"unpacking restores the host prop's lights")

	# 7. Hand-placed J light (model_owned == false) stays on world when prop is deleted,
	#    while model_owned stall lights are deleted with the prop!
	PlacedLightService.release_prop(main, pid)
	_ok(llayer.find_light(str(ids[0])).is_empty(),
		"release_prop removes model_owned stall lights when the prop is deleted")
	_ok(not llayer.find_light(s_id).is_empty() and str(llayer.find_light(s_id).get("host_id", "x")).is_empty(),
		"release_prop leaves hand-placed J string on the world")

	# Restore clean disk state.
	llayer.lights.clear()
	if lhad:
		var f := FileAccess.open(lpath, FileAccess.WRITE)
		f.store_buffer(lbak)
		f.close()
	elif FileAccess.file_exists(lpath):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lpath))
	if player_layer != null:
		player_layer.deserialize(saved_props)
	if phad:
		var pf := FileAccess.open(ppath, FileAccess.WRITE)
		pf.store_buffer(pbak)
		pf.close()
	elif FileAccess.file_exists(ppath):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ppath))
	main.queue_free()
