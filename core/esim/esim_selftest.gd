extends SceneTree

## Offline deterministic checks for the .esim portable site package (Phases 0–1).
## Run: Godot.exe.exe --headless --path . --import
##      Godot.exe.exe --headless --path . --script core/esim/esim_selftest.gd

const EsimPackageScript := preload("res://core/esim/esim_package.gd")


func _init() -> void:
	var checks := 0
	var fails := 0
	fails += _run("validate_rejects_bad", _test_validate_rejects_bad)
	checks += 1
	fails += _run("build_and_validate", _test_build_and_validate)
	checks += 1
	fails += _run("strip_esim_ghosts", _test_strip_esim_ghosts)
	checks += 1
	fails += _run("ghost_overlay_remap", _test_ghost_overlay_remap)
	checks += 1
	fails += _run("share_code_roundtrip", _test_share_code_roundtrip)
	checks += 1
	fails += _run("file_roundtrip", _test_file_roundtrip)
	checks += 1
	fails += _run("summary_counts", _test_summary_counts)
	checks += 1
	fails += _run("location_mismatch", _test_location_mismatch)
	checks += 1
	if fails == 0:
		print("esim_selftest: PASS (%d checks)" % checks)
	else:
		push_error("esim_selftest: FAIL (%d / %d)" % [fails, checks])
	quit(1 if fails > 0 else 0)


func _run(name: String, fn: Callable) -> int:
	var err: int = fn.call()
	if err != 0:
		push_error("esim_selftest.%s failed" % name)
	return err


func _minimal_graph_state() -> Dictionary:
	return {
		"graph": {
			"version": 7,
			"items": [
				{
					"id": "panel_a",
					"type": "panel",
					"x": 40.0, "y": 60.0,
					"width": 120.0, "height": 100.0,
					"scope_id": "root",
					"specs": {"name": "Panel A", "wmp": 400.0, "voc": 45.0},
					"handles": [
						{"id": "positive", "polarity": "positive", "rx": 0.5, "ry": 1.0, "connected_to": []},
						{"id": "negative", "polarity": "negative", "rx": 0.5, "ry": 0.0, "connected_to": []},
					],
				},
				{
					"id": "ctrl_b",
					"type": "controller",
					"x": 40.0, "y": 220.0,
					"width": 140.0, "height": 120.0,
					"scope_id": "root",
					"specs": {"name": "MPPT", "max_voc": 150.0},
					"handles": [
						{"id": "pvPositive", "polarity": "positive", "rx": 0.5, "ry": 0.0, "connected_to": []},
						{"id": "pvNegative", "polarity": "negative", "rx": 0.5, "ry": 1.0, "connected_to": []},
					],
				},
			],
			"connections": [
				{
					"id": "c1",
					"scope_id": "root",
					"source_item_id": "panel_a",
					"source_handle_id": "positive",
					"target_item_id": "ctrl_b",
					"target_handle_id": "pvPositive",
					"polarity": "positive",
				},
			],
			"scopes": {"root": {"id": "root", "parent_scope_id": "", "owner_compound_id": "", "title": "Root"}},
			"definitions": {},
			"item_counter": 2,
			"connection_counter": 1,
			"last_line_style": "bezier",
		},
		"mode": "build",
		"active_scope_id": "root",
	}


func _minimal_package() -> Dictionary:
	return EsimPackageScript.build(
		{
			"latitude": 33.3561,
			"longitude": -115.7322,
			"label": "Selftest Site",
			"half_extent_m": 15000.0,
			"detail_half_extent_m": 500.0,
			"osm_half_extent_m": 500.0,
		},
		_minimal_graph_state(),
		{
			"soi": {"version": 1, "center_x": 10.0, "center_z": -5.0, "radius_m": 200.0},
			"placed_props": {
				"version": 1,
				"props": [
					{"id": "prop_1", "model_id": "csp_trough", "x": 1.0, "z": 2.0, "yaw": 0.0, "type": "free"},
				],
			},
			"building_styles": {"version": 1, "styles": {"12_34": {"roof_shape": "gabled", "roof_pitch_deg": 28.0}}},
			"vegetation": {},
			"vegetation_style": {},
			"auto_veg_edits": {},
			"user_water": {
				"version": 1,
				"ponds": [
					{"tag": "pond_1", "points": [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0]], "capacity_l": 5000.0},
				],
			},
		},
		{"name": "Selftest Site"},
	)


func _test_validate_rejects_bad() -> int:
	var bad := EsimPackageScript.validate({"exportType": "nope"})
	if bool(bad.get("ok", true)):
		push_error("should reject wrong exportType")
		return 1
	var missing := EsimPackageScript.validate({
		"exportType": EsimPackageScript.EXPORT_TYPE,
		"schema_version": EsimPackageScript.SCHEMA_VERSION,
	})
	if bool(missing.get("ok", true)):
		push_error("should reject missing location/graph")
		return 1
	return 0


func _test_build_and_validate() -> int:
	var pkg := _minimal_package()
	var v := EsimPackageScript.validate(pkg)
	if not bool(v.get("ok", false)):
		push_error("valid package rejected: %s" % str(v.get("error")))
		return 1
	if str(pkg.get("exportType", "")) != EsimPackageScript.EXPORT_TYPE:
		push_error("exportType mismatch")
		return 1
	if str(pkg.get("schema_version", "")) != EsimPackageScript.SCHEMA_VERSION:
		push_error("schema_version mismatch")
		return 1
	return 0


func _test_strip_esim_ghosts() -> int:
	var state := _minimal_graph_state()
	var graph: Dictionary = state["graph"]
	var items: Array = graph["items"]
	items.append({
		"id": "esim_ghost_x",
		"type": "panel",
		"esim_ghost": true,
		"is_ghost": true,
		"scope_id": "root",
		"specs": {"name": "ghost"},
	})
	var conns: Array = graph["connections"]
	conns.append({
		"id": "esim_ghost_c",
		"esim_ghost": true,
		"source_item_id": "esim_ghost_x",
		"target_item_id": "panel_a",
	})
	var cleaned := EsimPackageScript.strip_esim_ghosts_from_graph_state(state)
	var g2: Dictionary = cleaned.get("graph", {}) as Dictionary
	for it in g2.get("items", []) as Array:
		if it is Dictionary and bool((it as Dictionary).get("esim_ghost", false)):
			push_error("ghost item survived strip")
			return 1
	for c in g2.get("connections", []) as Array:
		if c is Dictionary and bool((c as Dictionary).get("esim_ghost", false)):
			push_error("ghost connection survived strip")
			return 1
	if (g2.get("items", []) as Array).size() != 2:
		push_error("expected 2 real items after strip")
		return 1
	return 0


func _test_ghost_overlay_remap() -> int:
	var overlay := EsimPackageScript.make_ghost_overlay(_minimal_graph_state())
	var items: Array = overlay.get("items", []) as Array
	var conns: Array = overlay.get("connections", []) as Array
	if items.size() != 2:
		push_error("expected 2 ghost items, got %d" % items.size())
		return 1
	if conns.size() != 1:
		push_error("expected 1 ghost connection, got %d" % conns.size())
		return 1
	for it in items:
		var d: Dictionary = it as Dictionary
		if not bool(d.get("esim_ghost", false)) or not bool(d.get("is_ghost", false)):
			push_error("ghost flags missing")
			return 1
		if not str(d.get("id", "")).begins_with(EsimPackageScript.ESIM_GHOST_PREFIX):
			push_error("ghost id prefix missing")
			return 1
		if str(d.get("specs", {}).get("name", "")).find("👻") < 0:
			push_error("ghost name marker missing")
			return 1
	var c0: Dictionary = conns[0] as Dictionary
	if not str(c0.get("source_item_id", "")).begins_with(EsimPackageScript.ESIM_GHOST_PREFIX):
		push_error("connection source not remapped")
		return 1
	return 0


func _test_share_code_roundtrip() -> int:
	var pkg := _minimal_package()
	var enc := EsimPackageScript.encode_share_code(pkg)
	if not bool(enc.get("ok", false)):
		push_error("encode failed: %s" % str(enc.get("error")))
		return 1
	var code := str(enc.get("code", ""))
	if not code.begins_with(EsimPackageScript.PASTE_PREFIX):
		push_error("missing paste prefix")
		return 1
	var dec := EsimPackageScript.decode_share_code(code)
	if not bool(dec.get("ok", false)):
		push_error("decode failed: %s" % str(dec.get("error")))
		return 1
	var again: Dictionary = dec.get("package", {}) as Dictionary
	var items_a: Array = ((pkg.get("system_graph", {}) as Dictionary).get("graph", {}) as Dictionary).get("items", []) as Array
	var items_b: Array = ((again.get("system_graph", {}) as Dictionary).get("graph", {}) as Dictionary).get("items", []) as Array
	if items_a.size() != items_b.size():
		push_error("share-code item count mismatch")
		return 1
	var soi_a: Dictionary = pkg.get("soi", {}) as Dictionary
	var soi_b: Dictionary = again.get("soi", {}) as Dictionary
	if absf(float(soi_a.get("radius_m", 0.0)) - float(soi_b.get("radius_m", -1.0))) > 0.01:
		push_error("share-code SoI radius mismatch")
		return 1
	return 0


func _test_file_roundtrip() -> int:
	var pkg := _minimal_package()
	var path := "user://esim_selftest_roundtrip.esim"
	var saved := EsimPackageScript.save_to_path(pkg, path)
	if not bool(saved.get("ok", false)):
		push_error("save failed: %s" % str(saved.get("error")))
		return 1
	var loaded := EsimPackageScript.load_from_path(path)
	if not bool(loaded.get("ok", false)):
		push_error("load failed: %s" % str(loaded.get("error")))
		return 1
	var again: Dictionary = loaded.get("package", {}) as Dictionary
	var props_a: Array = (pkg.get("placed_props", {}) as Dictionary).get("props", []) as Array
	var props_b: Array = (again.get("placed_props", {}) as Dictionary).get("props", []) as Array
	if props_a.size() != props_b.size():
		push_error("prop count mismatch after file round-trip")
		return 1
	var styles_a: Dictionary = (pkg.get("building_styles", {}) as Dictionary).get("styles", {}) as Dictionary
	var styles_b: Dictionary = (again.get("building_styles", {}) as Dictionary).get("styles", {}) as Dictionary
	if styles_a.size() != styles_b.size():
		push_error("building style count mismatch")
		return 1
	var ponds_a: Array = (pkg.get("user_water", {}) as Dictionary).get("ponds", []) as Array
	var ponds_b: Array = (again.get("user_water", {}) as Dictionary).get("ponds", []) as Array
	if ponds_a.size() != ponds_b.size():
		push_error("pond count mismatch")
		return 1
	# Cleanup
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return 0


func _test_summary_counts() -> int:
	var pkg := _minimal_package()
	var s: Dictionary = EsimPackageScript.summary_of(pkg)
	if int(s.get("item_count", 0)) != 2:
		push_error("summary item_count expected 2")
		return 1
	if int(s.get("prop_count", 0)) != 1:
		push_error("summary prop_count expected 1")
		return 1
	if int(s.get("pond_count", 0)) != 1:
		push_error("summary pond_count expected 1")
		return 1
	if int(s.get("building_style_count", 0)) != 1:
		push_error("summary building_style_count expected 1")
		return 1
	return 0


func _test_location_mismatch() -> int:
	var loc := {"latitude": 33.3561, "longitude": -115.7322}
	var near := EsimPackageScript.location_mismatch_m(loc, 33.3561, -115.7322)
	if near > 1.0:
		push_error("same coords should be ~0 m apart")
		return 1
	var far := EsimPackageScript.location_mismatch_m(loc, 34.0, -115.7322)
	if far < 1000.0:
		push_error("1° lat should be tens of km")
		return 1
	return 0
