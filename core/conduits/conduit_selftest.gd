extends SceneTree

## Offline self-test for ConduitKinds, GraphModel v4 migration, and ConduitMeshBuilder.
## Run: godot --headless --path . --script core/conduits/conduit_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	ConduitStylePresets.clear_memory_for_tests()
	_test_conduit_kinds()
	_test_graph_migration()
	_test_mesh_builder()
	_test_determinism()
	_test_new_kinds()
	_test_electrical_loss()
	_test_hydraulic_loss()
	_test_overload_ratios()
	_test_ground_drape()
	_test_light_string()
	_test_ac_load_losses()
	_test_severed_blocks_ac()
	_test_overload_burnout()
	_test_light_load_presets()
	_test_conceptual_default()
	_test_metro_ground_route()
	_test_pathfinder_lanes()
	_test_style_presets_roundtrip()
	_test_anchor_bound_prop_logic()
	_test_connection_ports()
	_test_mesh_triangle_pick()
	_test_ortho_router()
	_test_ux_visibility_and_materials()
	_test_overhaul_routing_and_style()
	_test_pipes_router_and_slack()
	_test_astar_routing_and_decouple()
	_test_fitting_router()
	_test_route_dispatch()
	_test_plug_logic()
	_test_conduit_styles_and_routing()
	_test_hang_edit()
	_test_pipe_kit_meta()
	_test_poly_penstock_kind()
	_test_contour_router()
	_test_contour_dispatch()
	_test_size_driven_tube_radius()
	_test_penstock_spec_and_design()
	_test_conduit_length()
	if _failures == 0:
		print("CONDUIT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CONDUIT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_conduit_kinds() -> void:
	_check("has extension_cord", ConduitKinds.has_type("extension_cord"))
	_check("has garden_hose", ConduitKinds.has_type("garden_hose"))
	_check("has conceptual_flow", ConduitKinds.has_type("conceptual_flow"))
	var ac_conn := {"polarity": "ac", "resource_type": "", "conduit_type": ""}
	_check("ac -> conceptual_flow", ConduitKinds.derive_type_for_connection(ac_conn) == "conceptual_flow")
	var water_conn := {"polarity": "resource", "resource_type": "water", "conduit_type": ""}
	_check("water empty -> conceptual", ConduitKinds.derive_type_for_connection(water_conn) == "conceptual_flow")
	_check("water suggested physical hose",
		ConduitKinds.suggested_physical_type(water_conn) == "garden_hose")
	var override := {"polarity": "ac", "conduit_type": "ducting"}
	_check("override ducting", ConduitKinds.derive_type_for_connection(override) == "ducting")
	var pts := PackedVector3Array([Vector3.ZERO, Vector3(3, 0, 0), Vector3(3, 4, 0)])
	_check("polyline length", absf(ConduitKinds.polyline_length_m(pts) - 7.0) < 0.001,
		"got %.3f" % ConduitKinds.polyline_length_m(pts))
	var wp := ConduitKinds.waypoint_dict(Vector3(1, 2, 3), "/Main/Terrain")
	_check("waypoint dict", absf(float(wp["y"]) - 2.0) < 0.001)


func _test_graph_migration() -> void:
	var model := GraphModel.new()
	var conn := {
		"id": "conn_test",
		"polarity": "ac",
		"source_item_id": "a",
		"target_item_id": "b",
	}
	model.connections.append(conn)
	model.call("_migrate_connection", conn)
	_check("route_3d migrated", conn.has("route_3d") and (conn["route_3d"] as Array).is_empty())
	_check("conduit_type migrated", conn.has("conduit_type"))
	_check("route_length_m migrated", conn.has("route_length_m"))
	var ser := model.serialize()
	_check("serialize v4+", int(ser.get("version", 0)) >= 4)
	model.add_item({"id": "a", "type": "panel", "specs": {"scene_device_path": "/Main/Sun"}})
	model.add_item({"id": "b", "type": "panel", "specs": {"scene_device_path": "/Main/Moon"}})
	model.add_connection({
		"id": "c1",
		"source_item_id": "a",
		"target_item_id": "b",
		"polarity": "ac",
	})
	var c := model.get_connection("c1")
	_check("routable both linked", model.connection_is_3d_routable(c))
	model.update_item("b", {"specs": {}})
	c = model.get_connection("c1")
	_check("not routable missing path", not model.connection_is_3d_routable(c))


func _test_mesh_builder() -> void:
	var control: Array = [Vector3(0, 5, 0), Vector3(10, 5, 0)]
	# Pin sag without end_slack so mid-span length stays a clean >10 m check.
	var cord_style := {
		"flexible": true, "sag_amount": 0.35, "end_slack_m": 0.0, "radius_m": 0.016,
	}
	var built: Dictionary = ConduitMeshBuilder.build(
		control, "extension_cord", 8, Callable(), cord_style)
	var mesh: ArrayMesh = built.get("mesh", null)
	_check("mesh created", mesh != null and mesh.get_surface_count() > 0)
	var arc: float = float(built.get("arc_length_m", 0.0))
	_check("arc length > 10m (sag)", arc > 10.0, "arc=%.3f" % arc)
	var rigid: Dictionary = ConduitMeshBuilder.build(control, "pvc_pipe", 4)
	var rigid_arc: float = float(rigid.get("arc_length_m", 0.0))
	_check("rigid ~10m", absf(rigid_arc - 10.0) < 0.05, "arc=%.3f" % rigid_arc)
	var samples: PackedVector3Array = ConduitMeshBuilder.sample_path(
		control, cord_style, 6)
	_check("samples count", samples.size() >= 7, "n=%d" % samples.size())


func _test_determinism() -> void:
	var control: Array = [Vector3(1, 2, 3), Vector3(4, 2, 8), Vector3(4, 6, 8)]
	var a: Dictionary = ConduitMeshBuilder.build(control, "garden_hose", 10)
	var b: Dictionary = ConduitMeshBuilder.build(control, "garden_hose", 10)
	_check("deterministic arc", absf(float(a["arc_length_m"]) - float(b["arc_length_m"])) < 1e-6)


func _test_new_kinds() -> void:
	for tid: String in ["pex_red", "pex_blue", "pex_white", "dc_solar", "romex",
			"led_strip", "led_fairy", "led_patio"]:
		_check("has %s" % tid, ConduitKinds.has_type(tid))
	_check("led_patio is light", ConduitKinds.is_light_type("led_patio"))
	_check("led_strip is light", ConduitKinds.is_light_type("led_strip"))
	_check("garden_hose not light", not ConduitKinds.is_light_type("garden_hose"))
	_check("extension_cord electrical", ConduitKinds.is_electrical_type("extension_cord"))
	_check("pex_red fluid", ConduitKinds.is_fluid_type("pex_red"))
	_check("pex_red not electrical", not ConduitKinds.is_electrical_type("pex_red"))
	_check("extension_cord drapes", ConduitKinds.is_ground_drape_type("extension_cord"))
	_check("led_patio hangs (no drape)", not ConduitKinds.is_ground_drape_type("led_patio"))
	var patio: Dictionary = ConduitKinds.type_meta("led_patio")
	_check("patio bulb spacing", float(patio.get("bulb_spacing_m", 0.0)) > 0.1)
	_check("strip continuous", absf(float(ConduitKinds.type_meta("led_strip").get("bulb_spacing_m", -1.0))) < 0.001)
	_check("hot_water suggested pex_red",
		ConduitKinds.suggested_physical_type({"polarity": "resource", "resource_type": "hot_water"}) == "pex_red")
	_check("hot_water override pex_red",
		ConduitKinds.derive_type_for_connection({"polarity": "resource", "resource_type": "hot_water",
			"conduit_type": "pex_red"}) == "pex_red")


func _test_electrical_loss() -> void:
	# 1500 W at 120 V through 30 m of 16 AWG cord: I=12.5 A,
	# R=0.0264*30=0.792 Ohm, P_loss=12.5^2*0.792=123.75 W, drop=9.9/120=8.25%.
	var r := ConduitLoss.electrical_loss(1500.0, 120.0, 30.0, 0.0264)
	_check("elec amps 12.5", absf(float(r["amps"]) - 12.5) < 0.001, "got %s" % str(r["amps"]))
	_check("elec loss ~123.75W", absf(float(r["loss_w"]) - 123.75) < 0.01, "got %s" % str(r["loss_w"]))
	_check("elec drop ~8.25%", absf(float(r["drop_pct"]) - 0.0825) < 0.0005, "got %s" % str(r["drop_pct"]))
	# Zero-power run loses nothing.
	var z := ConduitLoss.electrical_loss(0.0, 120.0, 30.0, 0.0264)
	_check("elec zero power zero loss", float(z["loss_w"]) == 0.0)
	# Longer run loses more (monotonic in length).
	var short_run := ConduitLoss.electrical_loss(1000.0, 120.0, 10.0, 0.0264)
	var long_run := ConduitLoss.electrical_loss(1000.0, 120.0, 50.0, 0.0264)
	_check("elec loss grows with length", float(long_run["loss_w"]) > float(short_run["loss_w"]))
	# Report helper honors route_length_m and flags overload vs ampacity.
	var conn := {"route_length_m": 30.0, "estimated_length": 1.0}
	var meta: Dictionary = ConduitKinds.type_meta("extension_cord")
	var rep := ConduitLoss.electrical_report_for_connection(conn, meta, 1800.0)
	_check("report uses route length", absf(float(rep["length_m"]) - 30.0) < 0.001)
	_check("report overload >1 (15A on 13A cord)", float(rep["overload_ratio"]) > 1.0,
		"got %s" % str(rep["overload_ratio"]))


func _test_hydraulic_loss() -> void:
	# 20 L/min through 30 m of 5/8in hose (C=140): sanity — positive drop,
	# derate strictly < 1, and monotonic in both flow and length.
	var r := ConduitLoss.hydraulic_drop(20.0, 30.0, 0.016, 140.0)
	_check("hyd drop positive", float(r["drop_psi"]) > 0.0, "got %s" % str(r["drop_psi"]))
	_check("hyd derate < 1", float(r["derate_frac"]) < 1.0)
	_check("hyd derate > 0", float(r["derate_frac"]) > 0.0)
	var more_flow := ConduitLoss.hydraulic_drop(40.0, 30.0, 0.016, 140.0)
	_check("hyd drop grows with flow", float(more_flow["drop_psi"]) > float(r["drop_psi"]))
	var longer := ConduitLoss.hydraulic_drop(20.0, 60.0, 0.016, 140.0)
	_check("hyd drop grows with length", float(longer["drop_psi"]) > float(r["drop_psi"]))
	# Big rigid pipe barely loses anything at the same flow.
	var pipe := ConduitLoss.hydraulic_drop(20.0, 30.0, 0.0266, 150.0)
	_check("pipe loses less than hose", float(pipe["drop_psi"]) < float(r["drop_psi"]))
	# No flow → no loss, derate stays 1.
	var z := ConduitLoss.hydraulic_drop(0.0, 30.0, 0.016, 140.0)
	_check("hyd zero flow", float(z["drop_psi"]) == 0.0 and float(z["derate_frac"]) == 1.0)
	var conn := {"route_length_m": 30.0}
	var meta: Dictionary = ConduitKinds.type_meta("garden_hose")
	var rep := ConduitLoss.hydraulic_report_for_connection(conn, meta, 20.0)
	_check("hyd report has derate", float(rep["derate_frac"]) > 0.0 and float(rep["derate_frac"]) < 1.0)


func _test_overload_ratios() -> void:
	_check("elec overload 2x", absf(ConduitLoss.electrical_overload_ratio(26.0, 13.0) - 2.0) < 0.001)
	_check("elec overload zero ampacity", ConduitLoss.electrical_overload_ratio(10.0, 0.0) == 0.0)
	_check("fluid overload by flow", absf(ConduitLoss.fluid_overload_ratio(80.0, 40.0) - 2.0) < 0.001)
	_check("fluid overload by pressure",
		absf(ConduitLoss.fluid_overload_ratio(10.0, 40.0, 700.0, 350.0) - 2.0) < 0.001)
	_check("fluid no ratings", ConduitLoss.fluid_overload_ratio(10.0, 0.0) == 0.0)


func _test_ground_drape() -> void:
	# Without a ground callback, flexible still uses hanging sag (can go below y=0).
	# With ground_y_fn, extension cords use ground-snake and rest on the floor.
	var control: Array = [Vector3(0, 0.5, 0), Vector3(20, 0.5, 0)]
	var ground_fn := func(_pos: Vector3) -> float: return 0.0
	var hang_style := {
		"flexible": true, "sag_amount": 0.35, "ground_drape": false, "end_slack_m": 0.0,
	}
	var drape_style: Dictionary = ConduitKinds.type_meta("extension_cord").duplicate(true)
	drape_style["end_slack_m"] = 0.2
	var free: PackedVector3Array = ConduitMeshBuilder.sample_path(control, hang_style, 12)
	var draped: PackedVector3Array = ConduitMeshBuilder.sample_path(
		control, drape_style, 12, ground_fn)
	var free_min := 1e9
	var draped_min := 1e9
	for p: Vector3 in free:
		free_min = minf(free_min, p.y)
	for p: Vector3 in draped:
		draped_min = minf(draped_min, p.y)
	_check("free sag dips below ground", free_min < 0.0, "min=%.3f" % free_min)
	_check("drape clamps at floor", draped_min >= 0.0, "min=%.3f" % draped_min)
	_check("drape clearance", absf(draped_min - ConduitMeshBuilder.DRAPE_CLEARANCE_M) < 0.001,
		"min=%.4f" % draped_min)
	# Tall plug: rise should linger near ground then curve up (not a taut diagonal).
	var tall: Array = [Vector3(0, 0.25, 0), Vector3(10, 2.5, 0)]
	var rise: PackedVector3Array = ConduitMeshBuilder.sample_ground_snake(
		tall, drape_style, 16, ground_fn)
	var y_at_8 := 2.5
	for p: Vector3 in rise:
		if absf(p.x - 8.0) < 0.35:
			y_at_8 = p.y
			break
	# Linear diagonal at x=8 would be ~2.05; ease-in stay lower.
	var linear_at_8 := 0.25 + (2.5 - 0.25) * 0.8
	_check("rise below taut diagonal", y_at_8 < linear_at_8 - 0.25,
		"y=%.3f linear=%.3f" % [y_at_8, linear_at_8])
	_check("rise still climbs", y_at_8 > ConduitMeshBuilder.DRAPE_CLEARANCE_M + 0.05,
		"y=%.3f" % y_at_8)
	# Mid pin-edit: hose must pass near the dragged waypoint XZ.
	var pinned: Array = [
		Vector3(0, 0.3, 0),
		Vector3(3, 0.5, 2),  # mid pin off the straight line
		Vector3(8, 0.3, 0),
	]
	var with_pin: PackedVector3Array = ConduitMeshBuilder.sample_ground_snake(
		pinned, drape_style, 12, ground_fn)
	var nearest_mid := 1e9
	var pin_xz := Vector2(3, 2)
	for p: Vector3 in with_pin:
		nearest_mid = minf(nearest_mid, Vector2(p.x, p.z).distance_to(pin_xz))
	_check("ground snake honors mid pin", nearest_mid < 0.55,
		"nearest=%.3f" % nearest_mid)
	# Tall port + short approach stub must NOT accordion-zigzag on the ground.
	var stubby: Array = [
		Vector3(-4, 0.25, 0),
		Vector3(-0.08, 0.3, 0),  # near-vertical seat into cylinder
		Vector3(0, 1.5, 0),
	]
	var hose_st := ConduitKinds.type_meta("garden_hose").duplicate(true)
	var stub_snake: PackedVector3Array = ConduitMeshBuilder.sample_ground_snake(
		stubby, hose_st, 12, ground_fn)
	var stub_max_turn := 0.0
	for i: int in range(1, stub_snake.size() - 1):
		var d0: Vector3 = (stub_snake[i] - stub_snake[i - 1]).normalized()
		var d1: Vector3 = (stub_snake[i + 1] - stub_snake[i]).normalized()
		stub_max_turn = maxf(stub_max_turn,
			acos(clampf(d0.dot(d1), -1.0, 1.0)))
	_check("hose stub no accordion", stub_max_turn < 1.25,
		"turn=%.2f rad" % stub_max_turn)
	# Patio without terrain_clamp still free-sags under y=0 (legacy path).
	var patio_style: Dictionary = ConduitKinds.type_meta("led_patio").duplicate(true)
	var patio: PackedVector3Array = ConduitMeshBuilder.sample_path(control, patio_style, 12, ground_fn)
	var patio_min := 1e9
	for p: Vector3 in patio:
		patio_min = minf(patio_min, p.y)
	_check("patio free sag dips", patio_min < 0.0, "min=%.3f" % patio_min)
	# Hang-edit path: catenary + terrain_clamp rests on ground (never under).
	var patio_clamp: Dictionary = patio_style.duplicate(true)
	patio_clamp["terrain_clamp"] = true
	var patio_rest: PackedVector3Array = ConduitMeshBuilder.sample_path(
		control, patio_clamp, 12, ground_fn)
	var patio_rest_min := 1e9
	var on_ground := 0
	for p: Vector3 in patio_rest:
		patio_rest_min = minf(patio_rest_min, p.y)
		if absf(p.y - ConduitMeshBuilder.DRAPE_CLEARANCE_M) < 0.002:
			on_ground += 1
	_check("patio clamp at floor", patio_rest_min >= 0.0, "min=%.3f" % patio_rest_min)
	_check("patio clamp clearance",
		absf(patio_rest_min - ConduitMeshBuilder.DRAPE_CLEARANCE_M) < 0.001,
		"min=%.4f" % patio_rest_min)
	_check("patio rests on ground", on_ground >= 3, "on_ground=%d" % on_ground)
	# Hang mid-pin catenary also clamps (long low span hits floor).
	var hang_hi: Array = [Vector3(0, 1.2, 0), Vector3(10, 1.2, 0), Vector3(20, 1.2, 0)]
	var hang_clamp := ConduitKinds.mesh_style_override("catenary")
	hang_clamp["terrain_clamp"] = true
	var hang_rest := ConduitMeshBuilder.sample_path(hang_hi, hang_clamp, 12, ground_fn)
	var hang_rest_min := 1e9
	for p: Vector3 in hang_rest:
		hang_rest_min = minf(hang_rest_min, p.y)
	_check("hang clamp at floor", hang_rest_min >= ConduitMeshBuilder.DRAPE_CLEARANCE_M - 1e-4,
		"min=%.3f" % hang_rest_min)


func _test_light_string() -> void:
	# 10 m straight run of patio lights (0.9 m spacing, first at 0.45): ~11 bulbs.
	var samples := PackedVector3Array([Vector3.ZERO, Vector3(10, 0, 0)])
	var bulbs := ConduitMeshBuilder.bulb_positions_along(samples, 0.9)
	_check("patio bulb count", bulbs.size() == 11, "n=%d" % bulbs.size())
	_check("first bulb at half spacing", absf(bulbs[0].x - 0.45) < 0.001,
		"x=%.3f" % bulbs[0].x)
	_check("bulb spacing even", absf((bulbs[1] - bulbs[0]).length() - 0.9) < 0.001)
	# Continuous strip: no discrete bulbs.
	var strip := ConduitMeshBuilder.bulb_positions_along(samples, 0.0)
	_check("strip no bulbs", strip.is_empty())
	# Full build carries bulb positions along the sagged catenary.
	var control: Array = [Vector3(0, 3, 0), Vector3(8, 3, 0)]
	var built: Dictionary = ConduitMeshBuilder.build_light_string(control, "led_patio", 12)
	var bp: PackedVector3Array = built.get("bulb_positions", PackedVector3Array())
	_check("light string has mesh", (built.get("mesh") as ArrayMesh).get_surface_count() > 0)
	_check("light string bulbs on curve", bp.size() >= 8, "n=%d" % bp.size())
	var mid_sagged := false
	for p: Vector3 in bp:
		if p.y < 2.99:
			mid_sagged = true
	_check("bulbs follow sag", mid_sagged)
	# Fairy lights: dense spacing on same run.
	var fairy: Dictionary = ConduitMeshBuilder.build_light_string(control, "led_fairy", 12)
	var fp: PackedVector3Array = fairy.get("bulb_positions", PackedVector3Array())
	_check("fairy denser than patio", fp.size() > bp.size() * 3, "fairy=%d patio=%d" % [fp.size(), bp.size()])
	# Determinism.
	var again: Dictionary = ConduitMeshBuilder.build_light_string(control, "led_patio", 12)
	var ap: PackedVector3Array = again.get("bulb_positions", PackedVector3Array())
	_check("light string deterministic", ap == bp)


## Controller → 1000 W load over a 30 m extension cord with per-conn
## simulate_losses=true: bus draw grows by the I²R loss of the cord.
func _make_ac_graph(conn_extra: Dictionary = {}) -> GraphModel:
	var model := GraphModel.new()
	model.add_item({
		"id": "ctrl", "type": "controller", "x": 0.0, "y": 0.0,
		"specs": {"name": "Controller"},
	})
	model.add_item({
		"id": "load", "type": "acload", "x": 200.0, "y": 0.0,
		"specs": {"name": "Heater", "watts": 1000.0, "requested_state": "on"},
	})
	var conn := {
		"id": "w1", "polarity": "ac",
		"source_item_id": "ctrl", "source_handle_id": "acOutput",
		"target_item_id": "load", "target_handle_id": "acIn",
		"route_length_m": 30.0,
		# Physical cord — conceptual default has no I²R model.
		"conduit_type": "extension_cord",
	}
	conn.merge(conn_extra, true)
	model.add_connection(conn)
	return model


func _test_ac_load_losses() -> void:
	# Losses off (no autoload, no override): plain 1000 W.
	var base := _make_ac_graph()
	var base_w: float = GraphAcLoad.compute_watts(base, self)
	_check("ac base draw 1000W", absf(base_w - 1000.0) < 0.5, "got %.1f" % base_w)
	# Per-connection override on: adds I²R loss. 1000 W @120 V = 8.33 A,
	# R = 0.0264*30 = 0.792 Ohm → ~55 W.
	var lossy := _make_ac_graph({"simulate_losses": true})
	var lossy_w: float = GraphAcLoad.compute_watts(lossy, self)
	_check("ac lossy draw ~1055W", absf(lossy_w - 1055.0) < 1.0, "got %.1f" % lossy_w)
	var conn := lossy.get_connection("w1")
	_check("loss_w written back", float(conn.get("loss_w", 0.0)) > 50.0,
		"loss=%.1f" % float(conn.get("loss_w", 0.0)))
	_check("carried amps ~8.33", absf(float(conn.get("carried_amps", 0.0)) - 8.333) < 0.01)
	_check("no overload at 8A on 13A cord", float(conn.get("overload_ratio", 0.0)) < 1.0)
	# Overload flags: 2400 W @120 V = 20 A on a 13 A cord → ratio ~1.54.
	var hot := _make_ac_graph({"simulate_losses": true})
	hot.update_item("load", {"specs": {"name": "Heater", "watts": 2400.0, "requested_state": "on"}})
	GraphAcLoad.compute_watts(hot, self)
	var hconn := hot.get_connection("w1")
	_check("overload ratio > 1.5", float(hconn.get("overload_ratio", 0.0)) > 1.5,
		"ratio=%.2f" % float(hconn.get("overload_ratio", 0.0)))


func _test_severed_blocks_ac() -> void:
	var model := _make_ac_graph({"simulate_losses": true, "severed": true})
	var w: float = GraphAcLoad.compute_watts(model, self)
	_check("severed wire drops load to 0", absf(w) < 0.001, "got %.1f" % w)
	var conn := model.get_connection("w1")
	_check("severed wire zero loss", float(conn.get("loss_w", 0.0)) == 0.0)


func _test_overload_burnout() -> void:
	# 2× overload: heat rises 1 heat-s per second → burns out at 5 s.
	var heat := 0.0
	for i in range(10):
		heat = ConduitLoss.step_overload_heat(heat, 2.0, 0.5)
	_check("2x overload hits burnout in 5s", ConduitLoss.is_burned_out(heat),
		"heat=%.2f" % heat)
	# At exactly rating (1.0×) heat never accumulates.
	var flat := 0.0
	for i in range(100):
		flat = ConduitLoss.step_overload_heat(flat, 1.0, 0.5)
	_check("at-rating never burns out", not ConduitLoss.is_burned_out(flat)
		and flat == 0.0, "heat=%.2f" % flat)
	# Brief spike then back under rating: heat cools off to zero.
	var spike := ConduitLoss.step_overload_heat(0.0, 3.0, 1.0)  # +2 heat-s
	_check("spike accumulates", spike > 1.9)
	for i in range(10):
		spike = ConduitLoss.step_overload_heat(spike, 0.5, 1.0)
	_check("cooldown clears heat", spike == 0.0, "heat=%.2f" % spike)
	# 1.2× mild overload: burns out eventually (~25 s), not instantly.
	var mild := 0.0
	var burn_s := 0
	for s in range(60):
		mild = ConduitLoss.step_overload_heat(mild, 1.2, 1.0)
		if ConduitLoss.is_burned_out(mild):
			burn_s = s + 1
			break
	_check("1.2x burns out ~25s", burn_s >= 20 and burn_s <= 30, "t=%d s" % burn_s)


## Phase 5: light-string presets are real graph loads whose wire renders as
## the string and whose draw scales with the routed 3D length.
func _test_light_load_presets() -> void:
	var found := {}
	for p: Dictionary in ComponentPresets.presets_for_category("appliances"):
		found[str(p.get("label", ""))] = p
	for label: String in ["Patio String Lights", "LED Strip (12 V)", "Fairy Lights"]:
		_check("preset '%s' in library" % label, found.has(label))
	var patio: Dictionary = found.get("Patio String Lights", {})
	var pspecs: Dictionary = patio.get("specs", {}) as Dictionary
	_check("patio preset light_conduit", str(pspecs.get("light_conduit", "")) == "led_patio")
	_check("patio preset watts_per_m", float(pspecs.get("watts_per_m", 0.0)) > 0.0)

	# Wiring a light load auto-sets the connection's conduit_type.
	var model := GraphModel.new()
	model.add_item({"id": "ctrl", "type": "controller", "x": 0.0, "y": 0.0,
		"specs": {"name": "Controller"}})
	model.add_item({"id": "lights", "type": "appliance", "x": 200.0, "y": 0.0,
		"specs": {"name": "Patio String Lights", "max_watts": 50.0, "avg_watts": 33.0,
			"watts_per_m": 3.3, "light_conduit": "led_patio", "requested_state": "on"}})
	model.add_connection({
		"id": "wl", "polarity": "ac",
		"source_item_id": "ctrl", "source_handle_id": "acOutput",
		"target_item_id": "lights", "target_handle_id": "acIn",
	})
	var conn := model.get_connection("wl")
	_check("light wire conduit auto-set", str(conn.get("conduit_type", "")) == "led_patio",
		"got '%s'" % str(conn.get("conduit_type", "")))
	# Draw before routing: rated wattage fallback.
	var w0: float = GraphAcLoad.compute_watts(model, self)
	_check("unrouted light uses rated watts", absf(w0 - 33.0) < 0.5, "got %.1f" % w0)
	# Draw after routing 20 m: watts_per_m x length = 66 W.
	conn["route_length_m"] = 20.0
	var w1: float = GraphAcLoad.compute_watts(model, self)
	_check("routed light scales with length", absf(w1 - 66.0) < 0.5, "got %.1f" % w1)
	# Losses + burnout ride the same paths as any electrical conduit.
	conn["simulate_losses"] = true
	var w2: float = GraphAcLoad.compute_watts(model, self)
	_check("light wire adds loss when enabled", w2 > w1, "w2=%.2f w1=%.2f" % [w2, w1])
	conn["severed"] = true
	var w3: float = GraphAcLoad.compute_watts(model, self)
	_check("severed light string goes dark", absf(w3) < 0.001, "got %.2f" % w3)


func _test_conceptual_default() -> void:
	_check("conceptual flag", ConduitKinds.is_conceptual_type("conceptual_flow"))
	_check("extension not conceptual", not ConduitKinds.is_conceptual_type("extension_cord"))
	_check("pvc rigid", ConduitKinds.is_rigid_type("pvc_pipe"))
	_check("hose flexible", not ConduitKinds.is_rigid_type("garden_hose"))
	_check("conceptual pipes", ConduitKinds.is_pipes_type("conceptual_flow"))
	_check("pvc pipes default", ConduitKinds.is_pipes_type("pvc_pipe"))
	_check("metro→pipes alias", ConduitKinds.normalize_route_mode("metro") == "pipes")
	_check("conceptual no sag", absf(float(ConduitKinds.type_meta("conceptual_flow").get("sag_amount", 1.0))) < 0.001)
	var mat := ConduitKinds.make_material("conceptual_flow", Color(1, 0.2, 0.2))
	_check("conceptual emissive", mat.emission_enabled)
	_check("conceptual tint applied", absf(mat.albedo_color.r - 1.0) < 0.01)
	var cord_mat := ConduitKinds.make_material("extension_cord")
	_check("cord jacket not forced emissive", not cord_mat.emission_enabled)
	_check("cord yellow visible", cord_mat.albedo_color.r > 0.85 and cord_mat.albedo_color.b < 0.3)
	_check("conceptual dashed", bool(ConduitKinds.type_meta("conceptual_flow").get("dashed", false)))
	_check("conceptual quiet emission",
		float(ConduitKinds.type_meta("conceptual_flow").get("emission_energy", 9.0)) < 1.0)
	var ac_tint := ConduitKinds.flow_tint_for_connection({"polarity": "ac"})
	_check("ac tint warm", ac_tint.r > 0.8 and ac_tint.g > 0.5)


func _test_metro_ground_route() -> void:
	var flat := func(p: Vector3) -> float: return 0.0
	var a := Vector3(0, 2, 0)
	var b := Vector3(10, 2, 8)
	var path := ConduitOrthoRouter.metro_ground_route(a, b, [], flat, 0.05)
	_check("metro has endpoints+", path.size() >= 3)
	_check("metro starts at a", path[0].distance_to(a) < 0.01)
	_check("metro ends at b", path[path.size() - 1].distance_to(b) < 0.01)
	# Mid samples sit on the ground plane (clearance), not hanging at y=2.
	var mid_on_ground := true
	for i: int in range(1, path.size() - 1):
		if path[i].y > 0.2:
			mid_on_ground = false
			break
	_check("metro mids on ground", mid_on_ground)
	# Softened elbows intentionally leave pure ortho; just ensure the run has
	# more than a straight aerial segment (risers + ground span).
	_check("metro longer than chord",
		ConduitKinds.polyline_length_m(path) > a.distance_to(b) * 0.9)


func _test_pathfinder_lanes() -> void:
	var flat := func(_p: Vector3) -> float: return 0.0
	var a := Vector3(0, 1.5, 0)
	var b := Vector3(12, 1.5, 4)
	var p0 := ConduitPathfinder.auto_metro(a, b, flat, 0, [], 0.08)
	var p5 := ConduitPathfinder.auto_metro(a, b, flat, 5, [], 0.08)
	_check("pathfinder starts at a", p0.size() >= 2 and p0[0].distance_to(a) < 0.02)
	_check("pathfinder ends at b", p0[p0.size() - 1].distance_to(b) < 0.02)
	# Different lanes should diverge mid-run (corridor fan-out).
	var mid0 := p0[p0.size() / 2]
	var mid5 := p5[p5.size() / 2]
	_check("lanes diverge", mid0.distance_to(mid5) > 0.3,
		"d=%.2f" % mid0.distance_to(mid5))
	_check("lane index stable", ConduitPathfinder.lane_index("abc") \
			== ConduitPathfinder.lane_index("abc"))


func _test_style_presets_roundtrip() -> void:
	var style := {
		"radius_m": 0.055,
		"color": Color(0.1, 0.9, 0.8),
		"emission_energy": 3.1,
		"metro_ground": true,
		"route_mode": "metro",
		"elbow_radius_frac": 0.4,
		"end_slack_m": 0.3,
	}
	# Don't write user:// in selftest — exercise serialize helpers via named API
	# only if we can round-trip in memory.
	var ser := ConduitStylePresets.style_to_raw(style)
	var back := ConduitStylePresets.style_dict_from_raw(ser)
	_check("style color roundtrip", back.get("color", Color.BLACK) is Color)
	var c: Color = back["color"] as Color
	_check("style color r", absf(c.r - 0.1) < 0.01)
	_check("style radius", absf(float(back.get("radius_m", 0.0)) - 0.055) < 0.001)
	_check("style metro migrates to pipes", str(back.get("route_mode", "")) == "pipes")
	_check("style elbow frac", absf(float(back.get("elbow_radius_frac", 0.0)) - 0.4) < 0.001)
	_check("style end slack", absf(float(back.get("end_slack_m", 0.0)) - 0.3) < 0.001)
	# Mesh build honors radius override from style.
	var built := ConduitMeshBuilder.build(
		[Vector3.ZERO, Vector3(2, 0, 0)], "extension_cord_12awg", 8, Callable(), style)
	_check("style mesh builds", built.get("mesh", null) != null)


func _test_anchor_bound_prop_logic() -> void:
	# Routable via bound_prop_id without scene path.
	var model := GraphModel.new()
	model.add_item({"id": "a", "type": "appliance",
		"specs": {"bound_prop_id": "prop_a", "model_id": "box"}})
	model.add_item({"id": "b", "type": "appliance",
		"specs": {"bound_prop_id": "prop_b", "model_id": "box"}})
	model.add_connection({
		"id": "c1", "polarity": "ac",
		"source_item_id": "a", "target_item_id": "b",
	})
	var c := model.get_connection("c1")
	_check("routable via bound props", model.connection_is_3d_routable(c))
	_check("item_has_3d_anchor bound", model.item_has_3d_anchor(model.get_item("a")))
	# Site + model_id still counts for appliances (not containers).
	model.update_item("b", {"specs": {"model_id": "box"}, "site_x_m": 1.0, "site_z_m": 2.0})
	var b := model.get_item("b")
	_check("site+model is 3d anchor", model.item_has_3d_anchor(b))
	# Resource containers need a placed twin — site+model alone is not enough.
	model.add_item({"id": "tank", "type": "resource",
		"specs": {"model_id": "generic_tank", "resource_kind": "water"},
		"site_x_m": 3.0, "site_z_m": 4.0})
	_check("resource site+model not anchor",
		not model.item_has_3d_anchor(model.get_item("tank")))
	model.update_item("tank", {"specs": {
		"model_id": "generic_tank", "resource_kind": "water",
		"bound_prop_id": "prop_tank",
	}})
	_check("resource bound prop is anchor",
		model.item_has_3d_anchor(model.get_item("tank")))
	# PBIs never get 3D anchors / conduit routes.
	model.add_item({"id": "pbi1", "type": "pbi", "specs": {
		"bound_prop_id": "prop_pbi", "model_id": "box",
	}})
	_check("pbi never 3d anchor", not model.item_has_3d_anchor(model.get_item("pbi1")))
	model.add_connection({
		"id": "c_pbi", "polarity": "resource",
		"source_item_id": "tank", "target_item_id": "pbi1",
	})
	_check("pbi conn not routable",
		not model.connection_is_3d_routable(model.get_connection("c_pbi")))
	# StarShade-style compound with bound prop is routable.
	model.add_item({"id": "ss", "type": "compound",
		"specs": {"model_id": "starshade", "bound_prop_id": "prop_ss",
			"definition_id": "starshade", "node_banner": true}})
	_check("starshade compound has 3d anchor",
		model.item_has_3d_anchor(model.get_item("ss")))
	# Graph serialize preserves conduit_style Colors through JSON.
	model.add_connection({
		"id": "c_style", "polarity": "ac", "conduit_type": "extension_cord",
		"source_item_id": "a", "target_item_id": "b",
		"conduit_style": {"color": Color(0.9, 0.8, 0.1, 1.0), "end_slack_m": 0.45},
	})
	var dumped := JSON.stringify(model.serialize())
	var parsed: Variant = JSON.parse_string(dumped)
	_check("style json roundtrip parse", parsed is Dictionary)
	var model2 := GraphModel.new()
	model2.deserialize(parsed as Dictionary)
	var st: Dictionary = (model2.get_connection("c_style")
			.get("conduit_style", {}) as Dictionary)
	_check("style color survives save", st.get("color", null) is Color,
		"got=%s" % str(st.get("color", null)))
	if st.get("color", null) is Color:
		var sc: Color = st["color"] as Color
		_check("style color yellow", sc.r > 0.8 and sc.g > 0.7 and sc.b < 0.2)
	_check("style slack survives save",
		absf(float(st.get("end_slack_m", 0.0)) - 0.45) < 0.001)


func _test_connection_ports() -> void:
	var port := ConnectionPortDefs.make_port("p1", "AC Out", Vector3(0.1, 0.5, 0.0),
		Vector3(1, 0, 0), "acOut")
	_check("port id", str(port.get("id", "")) == "p1")
	_check("port handle", str(port.get("handle_id", "")) == "acOut")
	_check("port approach default",
		absf(float(port.get("approach_m", 0.0)) - ConnectionPortDefs.DEFAULT_APPROACH_M) < 0.001)
	var ports: Array = [port, ConnectionPortDefs.make_port("", "In", Vector3.ZERO, Vector3.UP, "acIn")]
	var found := ConnectionPortDefs.find_port_for_handle(ports, "acOut")
	_check("find by handle", str(found.get("id", "")) == "p1")
	# World transform through a fake ModelRoot.
	var root := Node3D.new()
	root.position = Vector3(10, 0, 0)
	root.rotation_degrees = Vector3(0, 90, 0)
	# Don't need tree for to_global if we set transform manually — Node3D.to_global
	# works from local transform even outside the tree.
	var wp := ConnectionPortDefs.world_pos_for_port(port, root)
	_check("port world finite", is_finite(wp.x))
	var approach := ConnectionPortDefs.world_approach_point(port, root)
	var outward := ConnectionPortDefs.world_outward_for_port(port, root)
	var expected_ap := wp + outward * ConnectionPortDefs.DEFAULT_APPROACH_M
	_check("world_approach_point = pos + n*m", approach.distance_to(expected_ap) < 0.001,
		"ap=%s exp=%s" % [str(approach), str(expected_ap)])
	# Round-trip serialize normalize.
	var norm := ConnectionPortDefs.normalize_ports([{"label": "X", "x": 1.0, "y": 2.0, "z": 3.0}])
	_check("normalize mints id", not str((norm[0] as Dictionary).get("id", "")).is_empty())
	_check("normalize keeps approach",
		float((norm[0] as Dictionary).get("approach_m", 0.0)) >= ConnectionPortDefs.MIN_APPROACH_M)
	# HomeBiogas seeded defaults — four handles + unit outward.
	var hb := ConnectionPortDefs.default_ports_for_model("home_biogas_2")
	_check("home_biogas 4 ports", hb.size() == 4, "n=%d" % hb.size())
	var want_handles := ["res_in_0", "res_in_1", "res_out_0", "res_out_1"]
	for hid: String in want_handles:
		var hp := ConnectionPortDefs.find_port_for_handle(hb, hid)
		_check("home_biogas has %s" % hid, not hp.is_empty())
		if not hp.is_empty():
			var n := ConnectionPortDefs.local_outward(hp)
			_check("home_biogas %s unit outward" % hid, absf(n.length() - 1.0) < 0.001,
				"len=%.4f" % n.length())
	var funnel := ConnectionPortDefs.find_port_for_handle(hb, "res_in_0")
	_check("funnel outward +Y",
		ConnectionPortDefs.local_outward(funnel).dot(Vector3.UP) > 0.95)
	var effluent := ConnectionPortDefs.find_port_for_handle(hb, "res_out_1")
	_check("effluent outward -Y",
		ConnectionPortDefs.local_outward(effluent).dot(Vector3.DOWN) > 0.95)
	# Seating: approach stubs → mid route → true ports; end segments align ±outward.
	var port_a := ConnectionPortDefs.make_port("a", "A", Vector3(0, 1, 0), Vector3(0, 1, 0),
		"in", "", "", "", 0.5)
	var port_b := ConnectionPortDefs.make_port("b", "B", Vector3(2, 1, 0), Vector3(1, 0, 0),
		"out", "", "", "", 0.5)
	var root2 := Node3D.new()
	var a_pos := ConnectionPortDefs.world_pos_for_port(port_a, root2)
	var b_pos := ConnectionPortDefs.world_pos_for_port(port_b, root2)
	var a_ap := ConnectionPortDefs.world_approach_point(port_a, root2)
	var b_ap := ConnectionPortDefs.world_approach_point(port_b, root2)
	var mid: Array = [a_ap, Vector3(1, 1, 0), b_ap]
	var seated: Array = ConduitManager._with_port_seats(a_pos, b_pos, mid, true, true)
	_check("seated starts at port A", seated.size() >= 3
			and (seated[0] as Vector3).distance_to(a_pos) < 0.01)
	_check("seated ends at port B", seated.size() >= 3
			and (seated[seated.size() - 1] as Vector3).distance_to(b_pos) < 0.01)
	var seg0: Vector3 = (seated[1] as Vector3) - (seated[0] as Vector3)
	var seg_last: Vector3 = (seated[seated.size() - 1] as Vector3) \
			- (seated[seated.size() - 2] as Vector3)
	var out_a := ConnectionPortDefs.world_outward_for_port(port_a, root2)
	var out_b := ConnectionPortDefs.world_outward_for_port(port_b, root2)
	# Leave A along +outward; arrive at B along −outward.
	_check("seat A along +outward",
		seg0.normalized().dot(out_a) > 0.95, "dot=%.3f" % seg0.normalized().dot(out_a))
	_check("seat B along -outward",
		seg_last.normalized().dot(-out_b) > 0.95,
		"dot=%.3f" % seg_last.normalized().dot(-out_b))
	# Funnel-style +Y port: expand chain with shoulders must stay kit-legal (no 180°).
	var funnel_port := Vector3(0, 1.0, 0)
	var funnel_ap := Vector3(0, 1.45, 0)
	var peer_port := Vector3(2.0, 0.4, 0.5)
	var peer_ap := Vector3(2.0, 0.4, 0.95)
	var chain := ConduitManager._approach_chain(
		funnel_port, peer_port, funnel_ap, peer_ap, [],
		true, true, Vector3.UP, Vector3(0, 0, 1))
	var exp := PipeFittingExpander.expand(chain, 45.0)
	_check("funnel chain expands", exp.size() >= 4, "n=%d" % exp.size())
	_check("funnel chain starts at port", exp[0].distance_to(funnel_port) < 0.02)
	_check("funnel chain ends at peer", exp[exp.size() - 1].distance_to(peer_port) < 0.02)
	var max_illegal := 0.0
	for i: int in range(1, exp.size() - 1):
		var din: Vector3 = exp[i] - exp[i - 1]
		var dout: Vector3 = exp[i + 1] - exp[i]
		if din.length_squared() < 1e-8 or dout.length_squared() < 1e-8:
			continue
		var turn := rad_to_deg(din.normalized().angle_to(dout.normalized()))
		# Colinear (~0) or ~45/90 are legal; flag anything near 180 or odd angles.
		var nearest_fit := minf(absf(turn), minf(absf(turn - 45.0), absf(turn - 90.0)))
		if turn > 20.0 and nearest_fit > 12.0:
			max_illegal = maxf(max_illegal, nearest_fit)
	_check("funnel chain kit-legal turns", max_illegal < 12.0,
		"worst_off_fit=%.1f" % max_illegal)
	# Legalize-after-seat path (unlocked pipes) also keeps ±outward seats.
	var mid_bad: Array = [funnel_ap, Vector3(1.0, 0.4, 0.5), peer_ap]
	var seated_leg := ConduitManager._seat_approaches_legal(
		funnel_port, peer_port, mid_bad, true, true,
		Vector3.UP, Vector3(0, 0, 1), true, 45.0)
	_check("legal seat starts at funnel", seated_leg.size() >= 3
			and (seated_leg[0] as Vector3).distance_to(funnel_port) < 0.02)
	var s0: Vector3 = (seated_leg[1] as Vector3) - (seated_leg[0] as Vector3)
	_check("legal seat leaves +Y", s0.normalized().dot(Vector3.UP) > 0.9,
		"dot=%.3f" % s0.normalized().dot(Vector3.UP))
	# Coplanar 45°+45° zigzag collapses to one 90° corner.
	var zig := PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(1.2, 0, 0.2),  # short 45° diagonal
		Vector3(1.2, 0, 1.2),
	])
	var collapsed := PipeFittingExpander.collapse_double_45(zig)
	_check("collapse 45+45 fewer corners", collapsed.size() == 3,
		"n=%d" % collapsed.size())
	if collapsed.size() == 3:
		var din := collapsed[1] - collapsed[0]
		var dout := collapsed[2] - collapsed[1]
		var turn := rad_to_deg(din.normalized().angle_to(dout.normalized()))
		_check("collapse 45+45 → ~90°", absf(turn - 90.0) <= 14.0, "turn=%.1f" % turn)
	# Opposite-sense S-curve (45 then −45) must NOT collapse to a single corner.
	var s_curve := PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(1.2, 0, 0.2),
		Vector3(2.2, 0, 0.2),
	])
	# Second bend turns back toward +X (net ~0°, not 90°) — leave as-is.
	var s_out := PipeFittingExpander.collapse_double_45(s_curve)
	_check("S-curve not collapsed to 90", s_out.size() >= 4, "n=%d" % s_out.size())
	root.free()
	root2.free()


func _test_mesh_triangle_pick() -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	mi.mesh = box
	var root := Node3D.new()
	root.add_child(mi)
	# Ray from +Z toward origin should hit the +Z face at z=1.
	var hit := MeshTrianglePick.pick(root, Vector3(0, 0, 5), Vector3(0, 0, -1))
	_check("box pick hit", bool(hit.get("valid", false)))
	if bool(hit.get("valid", false)):
		var pos: Vector3 = hit["position"] as Vector3
		_check("box pick z~1", absf(pos.z - 1.0) < 0.05, "z=%.3f" % pos.z)
		var n: Vector3 = hit["normal"] as Vector3
		_check("box pick normal +Z", n.z > 0.9, "n=%s" % str(n))
	var miss := MeshTrianglePick.pick(root, Vector3(0, 0, 5), Vector3(0, 1, 0))
	_check("box miss", not bool(miss.get("valid", false)))
	root.free()


func _test_ortho_router() -> void:
	var a := Vector3(0, 1, 0)
	var b := Vector3(10, 1, 6)
	var path := ConduitOrthoRouter.route(a, b, [], true)
	_check("ortho has endpoints", path.size() >= 2)
	_check("ortho starts at a", path[0].distance_to(a) < 0.01)
	_check("ortho ends at b", path[path.size() - 1].distance_to(b) < 0.01)
	# Pre-soften L-path is axis-aligned / 45°.
	var sharp := PackedVector3Array([Vector3.ZERO, Vector3(4, 0, 0), Vector3(4, 0, 4)])
	_check("ortho or 45", ConduitOrthoRouter.is_ortho_or_45(sharp, 5.0))
	var soft := ConduitOrthoRouter.soften_elbows(sharp, 4)
	_check("elbow adds samples", soft.size() > sharp.size())
	# Vertical rise preserved.
	var up := ConduitOrthoRouter.route(Vector3(0, 0, 0), Vector3(0, 3, 0), [], true)
	_check("pure vertical 2 pts", up.size() >= 2)
	_check("vertical end y", absf(up[up.size() - 1].y - 3.0) < 0.01)


func _test_ux_visibility_and_materials() -> void:
	# Global × per-conn visibility matrix.
	# Conceptual (default type) stays hidden unless forced on.
	_check("vis conceptual hidden default",
		not ConduitKinds.resolve_visible_3d({}, true))
	_check("vis conceptual force on",
		ConduitKinds.resolve_visible_3d({"visible_3d": true}, false))
	var follow_phys := {"conduit_type": "extension_cord"}
	_check("vis phys follow global on",
		ConduitKinds.resolve_visible_3d(follow_phys, true))
	_check("vis phys follow global off",
		not ConduitKinds.resolve_visible_3d(follow_phys, false))
	_check("vis force on", ConduitKinds.resolve_visible_3d({"visible_3d": true}, false))
	_check("vis force off", not ConduitKinds.resolve_visible_3d({"visible_3d": false}, true))
	# Siphon direct intake: hidden unless user forces visible_3d on.
	_check("vis direct_intake flag hidden",
		not ConduitKinds.resolve_visible_3d({"direct_intake": true, "conduit_type": "garden_hose"}, true))
	_check("vis direct_intake force on wins",
		ConduitKinds.resolve_visible_3d({
			"direct_intake": true, "visible_3d": true, "conduit_type": "garden_hose"}, false))
	_check("is_direct_intake_connection flag",
		ConduitKinds.is_direct_intake_connection({"direct_intake": true}))
	# The turbine KIND decides, not the preset: every hydro preset marks its
	# water input direct_intake, but only the SIPHON drinks through a dip tube.
	# A wire into a PowerSpout stamped "direct" never became its penstock
	# (found by the harness matrix's penstock auto-restyle check, 2026-10-12).
	var dm := GraphModel.new()
	for k in ["siphon", "powerspout_pelton"]:
		dm.add_item({"id": "t_" + k, "type": "processor", "x": 0.0, "y": 0.0,
			"specs": {"role": "siphon_hydro", "turbine_kind": k,
				"inputs": [{"kind": "water", "rate": 0.0, "unit": "L/h", "direct_intake": true}]}})
	_check("a wire into a SIPHON's water input is a direct intake",
		ConduitKinds.is_direct_intake_connection({"source_item_id": "p", "source_handle_id": "output",
			"target_item_id": "t_siphon", "target_handle_id": "res_in_0"}, dm))
	_check("a wire into a PowerSpout's water input is NOT (it is the penstock)",
		not ConduitKinds.is_direct_intake_connection({"source_item_id": "p", "source_handle_id": "output",
			"target_item_id": "t_powerspout_pelton", "target_handle_id": "res_in_0"}, dm))
	# Flow glow: quiet by default for all kinds; global / force opts in.
	_check("flow conceptual quiet default",
		not ConduitKinds.resolve_flow_glow({}, "conceptual_flow", false))
	_check("flow conceptual global on",
		ConduitKinds.resolve_flow_glow({}, "conceptual_flow", true))
	_check("flow physical global off",
		not ConduitKinds.resolve_flow_glow({}, "extension_cord", false))
	_check("flow physical global on",
		ConduitKinds.resolve_flow_glow({}, "extension_cord", true))
	_check("flow force on",
		ConduitKinds.resolve_flow_glow({"flow_glow": true}, "extension_cord", false))
	_check("flow force off",
		not ConduitKinds.resolve_flow_glow({"flow_glow": false}, "conceptual_flow", true))
	# Yellow jacket + distinct red plugs.
	var jacket: Color = ConduitKinds.type_meta("extension_cord").get("color", Color.BLACK) as Color
	_check("cord yellow albedo", jacket.r > 0.85 and jacket.g > 0.7 and jacket.b < 0.25,
		"c=%s" % str(jacket))
	var fit: Color = ConduitKinds.fitting_color("extension_cord")
	_check("cord red plugs", fit.r > 0.7 and fit.g < 0.3 and fit.b < 0.3,
		"f=%s" % str(fit))
	var plug_delta := absf(fit.r - jacket.r) + absf(fit.g - jacket.g) + absf(fit.b - jacket.b)
	_check("plug != jacket", plug_delta > 0.6, "delta=%.2f" % plug_delta)
	var fmat := ConduitKinds.make_fitting_material("extension_cord")
	_check("plug emissive", fmat.emission_enabled)
	# Segment stock for >15 m runs.
	_check("seg under 15m", ConduitKinds.segment_count_for_length("extension_cord", 14.9) == 1)
	_check("seg 16m -> 2", ConduitKinds.segment_count_for_length("extension_cord", 16.0) == 2)
	_check("seg 45m -> 3", ConduitKinds.segment_count_for_length("extension_cord", 45.0) == 3)
	# Flow shader material params.
	var sh := load(ConduitKinds.FLOW_SHADER_PATH) as Shader
	_check("flow shader loads", sh != null)
	var flow_mat := ConduitKinds.make_flow_material("conceptual_flow")
	_check("flow mat has shader", flow_mat.shader != null)
	_check("flow mat base_color", flow_mat.get_shader_parameter("base_color") != null)
	_check("flow mat conceptual", float(flow_mat.get_shader_parameter("conceptual")) > 0.5)
	# Ray–polyline pick selects the nearer of two synthetic runs.
	var a_pts := PackedVector3Array([Vector3(0, 1, 0), Vector3(10, 1, 0)])
	var b_pts := PackedVector3Array([Vector3(0, 1, 2), Vector3(10, 1, 2)])
	var origin := Vector3(5, 3, 0)
	var dir := Vector3(0, -1, 0)
	var hit_a := ConduitKinds.ray_polyline_pick(origin, dir, a_pts, 0.5)
	var hit_b := ConduitKinds.ray_polyline_pick(origin, dir, b_pts, 0.5)
	_check("pick a near", float(hit_a.get("distance", INF)) < 0.15,
		"d=%.3f" % float(hit_a.get("distance", INF)))
	_check("pick b far", float(hit_b.get("distance", INF)) > 1.5,
		"d=%.3f" % float(hit_b.get("distance", INF)))
	# GraphModel null erase for Follow global.
	var model := GraphModel.new()
	model.add_connection({
		"id": "cx", "polarity": "ac",
		"source_item_id": "a", "target_item_id": "b",
		"visible_3d": false,
	})
	model.update_connection("cx", {"visible_3d": null})
	var cx := model.get_connection("cx")
	_check("null erase visible_3d", not cx.has("visible_3d"))


func _test_overhaul_routing_and_style() -> void:
	# Site autoroute must not populate dense route_3d.
	var model := GraphModel.new()
	model.add_item({"id": "a", "type": "appliance",
		"specs": {"model_id": "box"}, "site_x_m": 0.0, "site_z_m": 0.0})
	model.add_item({"id": "b", "type": "appliance",
		"specs": {"model_id": "box"}, "site_x_m": 20.0, "site_z_m": 0.0})
	model.add_connection({
		"id": "c_site", "polarity": "ac",
		"source_item_id": "a", "target_item_id": "b",
		"route_3d": [], "route_locked": false,
	})
	GraphSiteAutoroute.refresh_connection(model, "c_site", null, Vector3.ZERO)
	var c_site := model.get_connection("c_site")
	_check("site autoroute no route_3d",
		(c_site.get("route_3d", []) as Array).is_empty())
	_check("site autoroute length", float(c_site.get("route_length_m", 0.0)) > 19.0,
		"L=%.2f" % float(c_site.get("route_length_m", 0.0)))
	# Dashed conceptual mesh builds multi-surface.
	var dashed := ConduitMeshBuilder.build(
		[Vector3.ZERO, Vector3(3, 0, 0), Vector3(3, 0, 2)], "conceptual_flow", 10)
	var dmesh: ArrayMesh = dashed.get("mesh", null) as ArrayMesh
	_check("dashed mesh builds", dmesh != null and dmesh.get_surface_count() >= 1)
	# apply_flow_material_params reuses material.
	var fm := ConduitKinds.make_flow_material("conceptual_flow", Color(0.2, 0.8, 1.0), 0.0, 1.0)
	ConduitKinds.apply_flow_material_params(fm, "conceptual_flow", Color(1, 0, 0), 0.2, 1.5, 0.4)
	var bc: Color = fm.get_shader_parameter("base_color") as Color
	_check("apply_flow updates color", absf(bc.r - 1.0) < 0.01)
	_check("apply_flow updates strength",
		absf(float(fm.get_shader_parameter("flow_strength")) - 0.2) < 0.01)


func _test_pipes_router_and_slack() -> void:
	var flat := func(_p: Vector3) -> float: return 0.0
	var a := Vector3(0, 2, 0)
	var b := Vector3(12, 2, 8)
	# Sharp pipes (no elbow soften) must be axis-only.
	var sharp := ConduitPipesRouter.route(a, b, [], flat, 0.1, 0.0, [])
	_check("pipes endpoints", sharp.size() >= 2 \
			and sharp[0].distance_to(a) < 0.02 \
			and sharp[sharp.size() - 1].distance_to(b) < 0.02)
	_check("pipes axis-only", ConduitPipesRouter.is_axis_only(sharp, 0.05))
	# Soft elbows round (cut) the corners → more samples, and SHORTER than the
	# right-angle sharp path (a fillet is shorter than the corner it replaces).
	var soft := ConduitPipesRouter.route(a, b, [], flat, 0.1, 0.45, [])
	_check("pipes soft cuts corners", ConduitKinds.polyline_length_m(soft) \
			<= ConduitKinds.polyline_length_m(sharp) + 0.01)
	_check("pipes soft more samples", soft.size() >= sharp.size())
	# Elbow frac 0 vs large on a simple L.
	var L := PackedVector3Array([Vector3.ZERO, Vector3(4, 0, 0), Vector3(4, 0, 4)])
	var L0 := ConduitOrthoRouter.soften_elbows(L, 4, 0.0)
	var L1 := ConduitOrthoRouter.soften_elbows(L, 4, 0.4)
	_check("elbow 0 keeps sharp", L0.size() == L.size())
	_check("elbow 0.4 adds arc", L1.size() > L.size())
	# A rounded corner is shorter than the sharp right-angle it replaces.
	_check("elbow 0.4 shorter (rounds corner)", ConduitKinds.polyline_length_m(L1) \
			< ConduitKinds.polyline_length_m(L0) + 0.001)
	# Ground-snake draping for extension cords (no stacked catenary kinks).
	var cord := [Vector3(0, 1.5, 0), Vector3(6, 1.5, 0)]
	var flat0 := func(_p: Vector3) -> float: return 0.0
	var snake := ConduitMeshBuilder.sample_path(cord, {
		"flexible": true, "sag_amount": 0.35, "end_slack_m": 0.4,
		"ground_drape": true,
	}, 10, flat0)
	_check("ground snake samples", snake.size() > 20, "n=%d" % snake.size())
	_check("ground snake ends", snake.size() >= 2 \
			and snake[0].distance_to(cord[0] as Vector3) < 0.02 \
			and snake[snake.size() - 1].distance_to(cord[1] as Vector3) < 0.02)
	var mid_y := snake[snake.size() / 2].y
	_check("ground snake rests on ground", mid_y < 0.08, "y=%.3f" % mid_y)
	# Slack meander pulls some mid samples off the straight X axis.
	var max_lat := 0.0
	for p: Vector3 in snake:
		max_lat = maxf(max_lat, absf(p.z))
	_check("ground snake meanders", max_lat > 0.05, "lat=%.3f" % max_lat)
	# Consecutive turns stay gentle (no quasi-catenary kink spikes).
	var max_turn := 0.0
	for i: int in range(1, snake.size() - 1):
		var d0: Vector3 = (snake[i] - snake[i - 1]).normalized()
		var d1: Vector3 = (snake[i + 1] - snake[i]).normalized()
		max_turn = maxf(max_turn, acos(clampf(d0.dot(d1), -1.0, 1.0)))
	_check("ground snake smooth bends", max_turn < 1.15, "turn=%.2f rad" % max_turn)
	# Cord kind carries default end_slack_m.
	_check("cord has end_slack",
		float(ConduitKinds.type_meta("extension_cord").get("end_slack_m", 0.0)) > 0.1)
	# PVC defaults to pipes route_mode.
	_check("pvc route_mode pipes",
		ConduitKinds.normalize_route_mode(str(
			ConduitKinds.type_meta("pvc_pipe").get("route_mode", ""))) == "pipes")


func _test_astar_routing_and_decouple() -> void:
	var flat := func(_p: Vector3) -> float: return 0.0
	var astar := ConduitAStar.new()
	astar.rebuild(Vector3.ZERO, 24.0, [], flat, "open", 0.35, 2.0)
	var a := Vector3(-8.0, 0.35, 0.0)
	var b := Vector3(8.0, 0.35, 0.0)
	var open := astar.find_path(a, b)
	_check("astar open endpoints", open.size() >= 2 \
			and open[0].distance_to(a) < 0.05 \
			and open[open.size() - 1].distance_to(b) < 0.05)
	_check("astar open axis-only", ConduitPipesRouter.is_axis_only(open, 0.08))
	var wall := AABB(Vector3(-1.5, -2.0, -6.0), Vector3(3.0, 6.0, 12.0))
	astar.rebuild(Vector3.ZERO, 24.0, [wall], flat, "blocked", 0.35, 2.0)
	var detour := astar.find_path(a, b)
	_check("astar detour exists", detour.size() >= 2)
	_check("astar detour longer",
		ConduitKinds.polyline_length_m(detour) \
			> ConduitKinds.polyline_length_m(open) + 0.5,
		"open=%.2f detour=%.2f" % [
			ConduitKinds.polyline_length_m(open),
			ConduitKinds.polyline_length_m(detour)])
	var hits_core := false
	var core := AABB(Vector3(-0.8, -1.0, -4.0), Vector3(1.6, 4.0, 8.0))
	for p: Vector3 in detour:
		if core.has_point(p):
			hits_core = true
			break
	_check("astar avoids obstacle core", not hits_core)
	var sharp := astar.find_path(a, b)
	var soft := astar.find_path_soft(a, b, 0.4)
	_check("astar soft elbows", soft.size() >= sharp.size())
	# Procedural container twin helpers.
	var tank_item := {"type": "resource", "specs": {"capacity_qty": 500.0}}
	_check("default twin is tank",
		ModelCatalog.default_twin_model_id(tank_item) == ModelCatalog.GENERIC_TANK_ID)
	var box_item := {"type": "compound", "specs": {}}
	_check("default twin compound box",
		ModelCatalog.default_twin_model_id(box_item) == ModelCatalog.GENERIC_BOX_ID)
	var dims := ModelCatalog.twin_box_spec_for_item(tank_item)
	_check("twin dims positive",
		float(dims.get("w_m", 0.0)) > 0.5 and float(dims.get("h_m", 0.0)) > 0.5)
	var ports := ConnectionPortDefs.default_ports_for_model(
		ModelCatalog.GENERIC_TANK_ID, dims)
	_check("tank default ports", ports.size() >= 2)
	var tank_node := ModelCatalog.instantiate(ModelCatalog.GENERIC_TANK_ID, {
		"box_spec": dims,
	})
	_check("generic_tank builds", tank_node != null)
	if tank_node != null:
		tank_node.free()
	# Manager: unlocked autoroute ignores site_waypoints; locked honors route_3d.
	var mgr := ConduitManager.new()
	root.add_child(mgr)
	var model := GraphModel.new()
	model.add_item({
		"id": "ta", "type": "resource",
		"specs": {"model_id": ModelCatalog.GENERIC_TANK_ID},
		"site_x_m": -8.0, "site_z_m": 0.0, "elevation_m": 0.0,
	})
	model.add_item({
		"id": "tb", "type": "resource",
		"specs": {"model_id": ModelCatalog.GENERIC_TANK_ID},
		"site_x_m": 8.0, "site_z_m": 0.0, "elevation_m": 0.0,
	})
	model.add_connection({
		"id": "cw", "polarity": "resource", "resource_type": "water",
		"conduit_type": "pvc_pipe",
		"source_item_id": "ta", "target_item_id": "tb",
		"route_locked": false, "route_3d": [],
		"site_waypoints": [ConduitKinds.site_waypoint_dict(Vector2(0.0, 40.0))],
	})
	mgr.setup(model, null)
	var conn := model.get_connection("cw")
	var pts: Array = mgr.build_control_points(conn)
	_check("manager unlocked path", pts.size() >= 2)
	var pulled := false
	for pv: Variant in pts:
		if absf((pv as Vector3).z) > 20.0:
			pulled = true
			break
	_check("unlocked ignores site_waypoints", not pulled,
		"pts=%d" % pts.size())
	model.update_connection("cw", {
		"route_locked": true,
		"route_3d": [ConduitKinds.waypoint_dict(Vector3(0.0, 0.35, 6.0))],
	})
	conn = model.get_connection("cw")
	var locked_pts: Array = mgr.build_control_points(conn)
	var max_abs_z := 0.0
	for pv2: Variant in locked_pts:
		max_abs_z = maxf(max_abs_z, absf((pv2 as Vector3).z))
	# Pin at z=6 must pull the locked pipes path off the X axis.
	_check("locked route_3d honored", max_abs_z > 3.0,
		"max|z|=%.2f n=%d" % [max_abs_z, locked_pts.size()])
	mgr.queue_free()


func _test_fitting_router() -> void:
	var flat := func(_p: Vector3) -> float: return 0.0
	# A diagonal run with a 45° fitting: sharp (no soften) so bends are exact.
	var a := Vector3(0, 2, 0)
	var b := Vector3(10, 2, 6)
	var f45 := ConduitPipesRouter.route(a, b, [], flat, 0.1, 0.0, [], 45.0)
	_check("fitting endpoints", f45.size() >= 2 \
			and f45[0].distance_to(a) < 0.05 \
			and f45[f45.size() - 1].distance_to(b) < 0.05)
	var bend45 := ConduitPipesRouter.max_horizontal_bend_deg(f45)
	_check("fitting 45 bend", absf(bend45 - 45.0) < 1.5, "bend=%.2f" % bend45)
	_check("fitting not axis-only", not ConduitPipesRouter.is_axis_only(f45, 0.05))
	# 30° fittings.
	var f30 := ConduitPipesRouter.route(a, b, [], flat, 0.1, 0.0, [], 30.0)
	var bend30 := ConduitPipesRouter.max_horizontal_bend_deg(f30)
	_check("fitting 30 bend", absf(bend30 - 30.0) < 1.5, "bend=%.2f" % bend30)
	# On-lattice heading (due east) → straight run, no spurious elbow.
	var straight := ConduitPipesRouter.route(
		Vector3(0, 2, 0), Vector3(8, 2, 0), [], flat, 0.1, 0.0, [], 45.0)
	_check("fitting on-axis stays straight",
		ConduitPipesRouter.max_horizontal_bend_deg(straight) < 1.0)
	# Angle snapping.
	_check("snap 43->45", is_equal_approx(ConduitPipesRouter.snap_fitting_angle(43.0), 45.0))
	_check("snap 28->30", is_equal_approx(ConduitPipesRouter.snap_fitting_angle(28.0), 30.0))
	_check("snap 88->90", is_equal_approx(ConduitPipesRouter.snap_fitting_angle(88.0), 90.0))
	_check("snap 0->0", ConduitPipesRouter.snap_fitting_angle(0.0) == 0.0)
	# New standard pipe kinds exist with real dimensions + fitting angles.
	_check("pvc_4in exists", ConduitKinds.has_type("pvc_4in"))
	_check("pvc_6in exists", ConduitKinds.has_type("pvc_6in"))
	_check("pvc_4in radius ~2.25in",
		absf(float(ConduitKinds.type_meta("pvc_4in").get("radius_m", 0.0)) - 0.05715) < 0.005)
	_check("pvc kinds carry fitting angle",
		ConduitKinds.fitting_step_deg("pvc_4in") == 45.0 \
			and ConduitKinds.fitting_step_deg("pvc_6in") == 45.0)
	# Style override wins over kind default.
	_check("style override fitting",
		ConduitKinds.fitting_step_deg("pvc_pipe", {"fitting_step_deg": 30.0}) == 30.0)
	# Adaptive tessellation: fat pipe gets more radial sides than a thin cord.
	var thin := ConduitMeshBuilder.radial_segments_for_radius(0.005)
	var fat := ConduitMeshBuilder.radial_segments_for_radius(0.08414)  # 6"
	_check("thin tube cheap sides", thin == ConduitMeshBuilder.DEFAULT_RADIAL_SEGMENTS)
	_check("fat pipe more sides", fat > thin, "thin=%d fat=%d" % [thin, fat])
	_check("radial sides even", fat % 2 == 0)
	var fat_mesh := ConduitMeshBuilder.build(
		[Vector3(0, 1, 0), Vector3(4, 1, 0)], "pvc_6in").get("mesh") as ArrayMesh
	_check("6in mesh builds", fat_mesh != null and fat_mesh.get_surface_count() > 0)


# ConduitRouteDispatch — the shared route cascade both the committed builder and the
# drag preview now call. The core guarantee is PARITY: identical inputs -> identical
# control points (so the ghost matches the wire it commits to). Also locks the mode
# dispatch + the drift fixes (fitting override via style_ov, live-pin honoring).
func _test_route_dispatch() -> void:
	var ends := {
		"a": Vector3(0, 2, 0), "b": Vector3(10, 2, 6),
		"a_route": Vector3(0, 2, 0), "b_route": Vector3(10, 2, 6),
		"seat_a": false, "seat_b": false,
		"out_a": Vector3.ZERO, "out_b": Vector3.ZERO,
	}
	var clr := 0.6
	# Parity / determinism: identical inputs -> byte-identical output.
	var r1 := ConduitRouteDispatch.control_points(ends, "extension_cord", {}, [], false, [], true, clr)
	var r2 := ConduitRouteDispatch.control_points(ends, "extension_cord", {}, [], false, [], true, clr)
	_check("dispatch deterministic (preview==commit for same inputs)", _paths_equal(r1, r2))
	_check("dispatch direct endpoints", r1.size() >= 2 \
			and (r1[0] as Vector3).distance_to(ends["a"]) < 0.6 \
			and (r1[r1.size() - 1] as Vector3).distance_to(ends["b"]) < 0.6)
	# Live pin (preview working waypoint / ghost) is honored — route passes near it.
	var pin := Vector3(5, 2, 9)
	var rp := ConduitRouteDispatch.control_points(ends, "extension_cord", {}, [pin], false, [], true, clr)
	var near_pin := false
	for p: Vector3 in rp:
		if p.distance_to(pin) < 0.6:
			near_pin = true
	_check("dispatch honors live pin", near_pin)
	# Mode dispatch reachable via route_mode override (type-agnostic).
	var r_pipes := ConduitRouteDispatch.control_points(ends, "extension_cord", {"route_mode": "pipes"}, [], false, [], true, clr)
	_check("pipes mode returns a route", r_pipes.size() >= 2)
	var r_ortho := ConduitRouteDispatch.control_points(ends, "extension_cord", {"route_mode": "ortho"}, [], false, [], true, clr)
	_check("ortho mode returns a route", r_ortho.size() >= 2)
	# fitting-step override flows through style_ov (drift #2 guard) — 45° fit route.
	var r_fit := ConduitRouteDispatch.control_points(ends, "extension_cord",
			{"route_mode": "pipes", "fitting_step_deg": 45.0}, [], false, [], true, clr)
	_check("fit_step override returns a route", r_fit.size() >= 2)
	# Settle gate: cheap (no-A*) preview still returns a valid route.
	var r_cheap := ConduitRouteDispatch.control_points(ends, "extension_cord", {"route_mode": "pipes"}, [], false, [], false, clr)
	_check("cheap no-astar route valid", r_cheap.size() >= 2)
	# A real pipes type resolves through the cascade too.
	var r_pvc := ConduitRouteDispatch.control_points(ends, "pvc_pipe", {}, [], false, [], true, clr)
	_check("pvc_pipe routes via dispatch", r_pvc.size() >= 2)
	# resolve_route_ends pass-through when no bindings (empty items).
	var e2 := ConduitRouteDispatch.resolve_route_ends(
			Vector3(0, 0, 0), Vector3(4, 0, 0), {}, {}, "", "", "extension_cord", null)
	_check("resolve_route_ends pass-through", not bool(e2.get("seat_a", true)) \
			and (e2.get("a_route") as Vector3).distance_to(Vector3(0, 0, 0)) < 0.01)


func _paths_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if (a[i] as Vector3).distance_to(b[i] as Vector3) > 1e-5:
			return false
	return true


func _test_plug_logic() -> void:
	var out_hit := {
		"port": {"id": "p1", "handle_id": "outlet", "polarity": "output",
			"resource_kind": "water"},
		"world_pos": Vector3(0, 1, 0), "item_id": "tank_a",
	}
	var in_hit := {
		"port": {"id": "p2", "handle_id": "inlet", "polarity": "input",
			"resource_kind": "water"},
		"world_pos": Vector3(5, 1, 0), "item_id": "tank_b",
	}
	_check("plug out+in compatible", ConduitPlugLogic.ports_compatible(out_hit, in_hit))
	# Two outputs (both source) never join.
	var out_hit2 := out_hit.duplicate(true)
	(out_hit2["port"] as Dictionary)["item_id"] = "tank_b"
	out_hit2["item_id"] = "tank_c"
	_check("plug out+out incompatible", not ConduitPlugLogic.ports_compatible(out_hit, out_hit2))
	# Kind-domain mismatch (electric vs water) blocked.
	var elec_hit := in_hit.duplicate(true)
	(elec_hit["port"] as Dictionary)["resource_kind"] = "electric"
	elec_hit["item_id"] = "battery"
	_check("plug kind mismatch blocked", not ConduitPlugLogic.ports_compatible(out_hit, elec_hit))
	# Empty kind/polarity stays permissive.
	var bare_a := {"port": {"id": "a"}, "world_pos": Vector3.ZERO, "item_id": "x"}
	var bare_b := {"port": {"id": "b"}, "world_pos": Vector3(2, 0, 0), "item_id": "y"}
	_check("plug bare ports permissive", ConduitPlugLogic.ports_compatible(bare_a, bare_b))
	# Spec orients source=output even when called input-first, and auto-routes.
	var spec := ConduitPlugLogic.build_connection_spec(in_hit, out_hit, "pvc_4in", [])
	_check("spec source is output", str(spec.get("source_item_id", "")) == "tank_a")
	_check("spec target is input", str(spec.get("target_item_id", "")) == "tank_b")
	_check("spec conduit type", str(spec.get("conduit_type", "")) == "pvc_4in")
	_check("spec unlocked when no route", not bool(spec.get("route_locked", true)))
	# Port preferred style rides along on plug commit.
	var styled_out := out_hit.duplicate(true)
	(styled_out["port"] as Dictionary)["preferred_conduit_style"] = {
		"pipe_size_in": 2.0, "color": Color(1, 1, 1),
	}
	var spec_st := ConduitPlugLogic.build_connection_spec(in_hit, styled_out, "pvc_pipe", [])
	var st: Dictionary = spec_st.get("conduit_style", {}) as Dictionary
	_check("spec carries preferred style", float(st.get("pipe_size_in", 0.0)) == 2.0,
		"size=%s" % str(st.get("pipe_size_in", null)))
	# Nearest port along a ray picks the on-axis one, ignores off-axis / behind.
	var hits := [
		{"port": {"id": "near"}, "world_pos": Vector3(0, 0, 5), "item_id": "n"},
		{"port": {"id": "off"}, "world_pos": Vector3(3, 0, 5), "item_id": "o"},
		{"port": {"id": "behind"}, "world_pos": Vector3(0, 0, -5), "item_id": "b"},
	]
	var picked := ConduitPlugLogic.nearest_port_along_ray(
		Vector3.ZERO, Vector3(0, 0, 1), hits, 0.6)
	_check("nearest port picks on-axis", str((picked.get("port", {}) as Dictionary).get("id", "")) == "near")
	# Manager creates a real connection from a spec.
	var mgr := ConduitManager.new()
	root.add_child(mgr)
	var model := GraphModel.new()
	model.add_item({"id": "src", "type": "resource",
		"specs": {"model_id": ModelCatalog.GENERIC_TANK_ID}})
	model.add_item({"id": "dst", "type": "resource",
		"specs": {"model_id": ModelCatalog.GENERIC_TANK_ID}})
	mgr.setup(model, null)
	var plug_spec := {
		"source_item_id": "src", "target_item_id": "dst",
		"source_handle_id": "outlet", "target_handle_id": "inlet",
		"resource_type": "water", "conduit_type": "pvc_4in",
		"route_3d": [], "route_locked": false,
	}
	var before := model.connections.size()
	var cid := str(mgr.create_plug_connection(plug_spec))
	_check("plug connection created", not cid.is_empty() \
			and model.connections.size() == before + 1)
	_check("plug conn resolvable", not model.get_connection(cid).is_empty())
	# Self-loop / missing item rejected.
	_check("plug rejects self loop",
		str(mgr.create_plug_connection({"source_item_id": "src", "target_item_id": "src"})).is_empty())
	mgr.queue_free()


func _test_conduit_styles_and_routing() -> void:
	# Per-kind distinctive styling.
	var eth := ConduitKinds.type_meta("ethernet")
	var eth_col: Color = eth.get("color", Color.WHITE)
	_check("ethernet is blue", eth_col.b > 0.6 and eth_col.b > eth_col.r + 0.2)
	_check("ethernet thin", float(eth.get("radius_m", 1.0)) < 0.006)
	_check("ethernet routes ortho",
		ConduitKinds.normalize_route_mode(str(eth.get("route_mode", ""))) == "ortho")
	_check("kit pvc no collars", not bool(ConduitKinds.type_meta("pvc_4in").get("fitting_collars", true)))
	_check("duct has collars", bool(ConduitKinds.type_meta("ducting").get("fitting_collars", false)))
	_check("cord has no collars", not bool(ConduitKinds.type_meta("extension_cord").get("fitting_collars", false)))
	_check("led strip taut", ConduitKinds.normalize_route_mode(
		str(ConduitKinds.type_meta("led_strip").get("route_mode", ""))) == "taut")
	_check("patio catenary", ConduitKinds.normalize_route_mode(
		str(ConduitKinds.type_meta("led_patio").get("route_mode", ""))) == "catenary")
	# Clearcoat sheen on plastics.
	var pvc_mat := ConduitKinds.make_material("pvc_4in")
	# Dull Sch40 PVC — tiny clearcoat at most (wet plastic washed out day/night).
	_check("pvc dull plastic", pvc_mat.roughness >= 0.5 and pvc_mat.clearcoat <= 0.12,
		"r=%.2f cc=%.2f" % [pvc_mat.roughness, pvc_mat.clearcoat])
	var cord_mat := ConduitKinds.make_material("extension_cord")
	_check("cord no clearcoat", not cord_mat.clearcoat_enabled)
	# Route-mode mesh overrides.
	var taut_ov := ConduitKinds.mesh_style_override("taut")
	_check("taut suppresses sag", float(taut_ov.get("sag_amount", 1.0)) == 0.0 \
			and not bool(taut_ov.get("flexible", true)))
	var cat_ov := ConduitKinds.mesh_style_override("catenary")
	_check("catenary no ground drape", not bool(cat_ov.get("ground_drape", true)) \
			and float(cat_ov.get("sag_amount", 0.0)) > 0.1)
	_check("route mode options listed", ConduitKinds.route_mode_options().size() >= 5)
	# Bend detection: an L path (softened) yields exactly one elbow near the corner.
	var L := PackedVector3Array([Vector3.ZERO, Vector3(4, 0, 0), Vector3(4, 0, 4)])
	var Lsoft := ConduitOrthoRouter.soften_elbows(L, 4, 0.15)
	var bends := ConduitManager._detect_bend_points(Lsoft, 22.0)
	_check("one elbow detected", bends.size() == 1, "n=%d" % bends.size())
	if bends.size() == 1:
		var bp: Vector3 = (bends[0] as Dictionary).get("pos", Vector3.INF)
		_check("elbow near corner", bp.distance_to(Vector3(4, 0, 0)) < 1.2, "d=%.2f" % bp.distance_to(Vector3(4, 0, 0)))
	# Corrected fillet stays near the corner (radius band), never spikes outward.
	var Lsoft2 := ConduitOrthoRouter.soften_elbows(L, 4, 0.15)
	var max_corner_dist := 0.0
	for p: Vector3 in Lsoft2:
		if p.x > 3.0 and p.z < 1.0:  # arc region only
			max_corner_dist = maxf(max_corner_dist, p.distance_to(Vector3(4, 0, 0)))
	_check("fillet hugs corner (no spike)", max_corner_dist < 1.0, "max=%.2f" % max_corner_dist)
	# A straight run has no elbows.
	var straight_pl := PackedVector3Array([Vector3.ZERO, Vector3(3, 0, 0), Vector3(6, 0, 0)])
	_check("straight has no elbow",
		ConduitManager._detect_bend_points(straight_pl, 22.0).is_empty())
	# ORTHO DISPATCH regression: geometric ortho, not the coarse looping A* grid.
	var mgr := ConduitManager.new()
	root.add_child(mgr)
	var model := GraphModel.new()
	model.add_item({"id": "oa", "type": "resource",
		"specs": {"model_id": ModelCatalog.GENERIC_TANK_ID},
		"site_x_m": -8.0, "site_z_m": -6.0, "elevation_m": 0.0})
	model.add_item({"id": "ob", "type": "resource",
		"specs": {"model_id": ModelCatalog.GENERIC_TANK_ID},
		"site_x_m": 8.0, "site_z_m": 6.0, "elevation_m": 0.0})
	model.add_connection({
		"id": "oc", "polarity": "positive", "conduit_type": "romex",
		"source_item_id": "oa", "target_item_id": "ob",
		"route_locked": false, "route_3d": [],
	})
	mgr.setup(model, null)
	var oconn := model.get_connection("oc")
	var opath: Array = mgr.build_control_points(oconn)
	_check("ortho path built", opath.size() >= 2)
	if opath.size() >= 2:
		var packed_o := PackedVector3Array()
		var y_lo := INF
		var y_hi := -INF
		for pv: Variant in opath:
			var p: Vector3 = pv as Vector3
			packed_o.append(p)
			y_lo = minf(y_lo, p.y)
			y_hi = maxf(y_hi, p.y)
		# Regression: the A* grid detoured up the Y layers (up to 3 m). Geometric
		# ortho keeps a flat run — no vertical looping.
		_check("ortho stays flat (no Y loops)", (y_hi - y_lo) < 1.0,
			"dy=%.2f" % (y_hi - y_lo))
		var alen := ConduitKinds.polyline_length_m(packed_o)
		var man := absf(16.0) + absf(12.0)  # |dx|+|dz|
		# Clean ortho (with a 45° cut) is between straight-line and Manhattan length,
		# never a rambling detour.
		_check("ortho length sane", alen <= man * 1.2 + 1.0, "len=%.2f man=%.2f" % [alen, man])
	mgr.queue_free()


func _test_hang_edit() -> void:
	_check("hang edit cord", ConduitKinds.supports_hang_edit("extension_cord"))
	_check("hang edit patio", ConduitKinds.supports_hang_edit("led_patio"))
	_check("no hang pvc", not ConduitKinds.supports_hang_edit("pvc_pipe"))
	_check("no hang fairy", not ConduitKinds.supports_hang_edit("led_fairy"))
	_check("no hang conceptual", not ConduitKinds.supports_hang_edit("conceptual_flow"))
	_check("pipe pin abs", ConduitKinds.supports_pipe_pin_edit("abs_dwv"))
	_check("no pipe pin cord", not ConduitKinds.supports_pipe_pin_edit("extension_cord"))
	_check("pipe pin pvc", ConduitKinds.supports_pipe_pin_edit("pvc_pipe"))
	_check("pin edit abs+cord", ConduitKinds.supports_pin_edit("abs_dwv") \
			and ConduitKinds.supports_pin_edit("extension_cord"))
	_check("flex pin pex+hose", ConduitKinds.supports_flex_pin_edit("pex_red") \
			and ConduitKinds.supports_flex_pin_edit("garden_hose") \
			and not ConduitKinds.supports_flex_pin_edit("pvc_pipe"))
	_check("pin edit pex+hose+pvc", ConduitKinds.supports_pin_edit("pex_red") \
			and ConduitKinds.supports_pin_edit("garden_hose") \
			and ConduitKinds.supports_pin_edit("pvc_pipe"))
	_check("no flex pin abs/cord/conceptual",
		not ConduitKinds.supports_flex_pin_edit("abs_dwv") \
		and not ConduitKinds.supports_flex_pin_edit("extension_cord") \
		and not ConduitKinds.supports_flex_pin_edit("conceptual_flow"))
	_check("no pin edit conceptual", not ConduitKinds.supports_pin_edit("conceptual_flow"))
	_check("abs not hang", not ConduitKinds.supports_hang_edit("abs_dwv"))
	# Pin pick / nearest helpers (reposition + double-click delete).
	var mgr := ConduitManager.new()
	root.add_child(mgr)
	var model := GraphModel.new()
	model.add_item({"id": "ha", "type": "appliance",
		"specs": {"bound_prop_id": "p1", "model_id": "box"}})
	model.add_item({"id": "hb", "type": "appliance",
		"specs": {"bound_prop_id": "p2", "model_id": "box"}})
	model.add_connection({
		"id": "hc", "polarity": "ac", "conduit_type": "extension_cord",
		"source_item_id": "ha", "target_item_id": "hb",
		"route_locked": true,
		"route_3d": [
			{"x": 0.0, "y": 2.0, "z": 0.0},
			{"x": 5.0, "y": 2.0, "z": 0.0},
		],
	})
	mgr.setup(model, null)
	var near := mgr.nearest_hang_pin("hc", Vector3(0.1, 2.0, 0.0), 0.5)
	_check("nearest hang pin 0", int(near.get("index", -1)) == 0)
	var ray_pin := mgr.pick_hang_pin("hc", Vector3(5.0, 2.0, 2.0), Vector3(0, 0, -1), 0.6)
	_check("pick hang pin 1", int(ray_pin.get("index", -1)) == 1,
		"idx=%s" % str(ray_pin.get("index", -1)))
	var any_pin := mgr.pick_any_hang_pin(Vector3(0.0, 2.0, 2.0), Vector3(0, 0, -1), 0.6)
	_check("pick any hang pin", str(any_pin.get("conn_id", "")) == "hc" \
			and int(any_pin.get("index", -1)) == 0)
	# Hang pins keep authored XYZ even when a stale pin_path would resolve elsewhere.
	var pinned_route: Array = [{
		"x": 3.0, "y": 8.5, "z": 1.0,
		"pin_path": "/root/DoesNotMatter",
	}]
	var hang_xyz: Array = ConduitKinds.waypoints_to_vectors(pinned_route, null, false)
	_check("hang pin ignores pin_path", hang_xyz.size() == 1 \
			and (hang_xyz[0] as Vector3).distance_to(Vector3(3.0, 8.5, 1.0)) < 1e-4)
	var stripped: Array = ConduitKinds.strip_hang_pin_paths(pinned_route)
	_check("strip hang pin_path", stripped.size() == 1 \
			and not (stripped[0] as Dictionary).has("pin_path") \
			and is_equal_approx(float((stripped[0] as Dictionary).get("y", 0.0)), 8.5))
	mgr.commit_route("hc", pinned_route)
	var after := model.get_connection("hc")
	var after_route: Array = after.get("route_3d", []) as Array
	_check("commit strips hang pin_path", after_route.size() == 1 \
			and not (after_route[0] as Dictionary).has("pin_path"))
	mgr.queue_free()

	# Locked mid pin → hang sag flag.
	var hang_conn := {
		"conduit_type": "extension_cord",
		"route_locked": true,
		"route_3d": [{"x": 5.0, "y": 2.5, "z": 0.0}],
	}
	_check("conn uses hang sag", ConduitKinds.conn_uses_hang_sag(hang_conn))
	_check("unlocked no hang sag", not ConduitKinds.conn_uses_hang_sag({
		"conduit_type": "extension_cord", "route_locked": false,
		"route_3d": [{"x": 1.0, "y": 1.0, "z": 0.0}],
	}))
	# Multi-span catenary: mid sample drops below the chord (not ground-snake).
	var control: Array = [
		Vector3(0, 2.5, 0), Vector3(5, 2.5, 0), Vector3(10, 2.5, 0),
	]
	var hang_style := ConduitKinds.mesh_style_override("catenary")
	hang_style["radius_m"] = 0.01
	var samples := ConduitMeshBuilder.sample_path(control, hang_style, 12, Callable())
	_check("hang samples exist", samples.size() >= 10)
	var mid_y := 2.5
	var found_mid := false
	for p: Vector3 in samples:
		if absf(p.x - 2.5) < 0.4:
			mid_y = minf(mid_y, p.y)
			found_mid = true
	_check("hang first span sags", found_mid and mid_y < 2.35,
		"mid_y=%.3f found=%s" % [mid_y, str(found_mid)])
	# Surface aim free-air fallback when camera/main are detached (headless).
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.6, 0)
	var main := Node3D.new()
	var aim := ConduitSurfaceAim.pick(main, cam)
	_check("surface aim free valid", bool(aim.get("valid", false)))
	_check("surface aim free source", str(aim.get("source", "")) == "free")
	cam.free()
	main.free()
	# Mesh triangle pick still works (reuse for building pins).
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	mi.mesh = box
	mi.position = Vector3(0, 0, -3)
	var hit := MeshTrianglePick.pick_mesh_instance(
		mi, Vector3(0, 0, 0), Vector3(0, 0, -1))
	_check("mesh pick for hang aim", bool(hit.get("valid", false)),
		"d=%s" % str(hit.get("distance", null)))
	var tri_n := MeshTrianglePick.estimate_triangle_count(box)
	_check("tri estimate positive", tri_n > 0, "n=%d" % tri_n)
	# Budget abort must not hang — returns quickly even with a dense mesh.
	var dense := SphereMesh.new()
	dense.radial_segments = 64
	dense.rings = 32
	mi.mesh = dense
	var t0 := Time.get_ticks_msec()
	var capped := MeshTrianglePick.pick_mesh_instance(
		mi, Vector3(0, 0, 2), Vector3(0, 0, -1), 200)
	var dt := Time.get_ticks_msec() - t0
	_check("budgeted pick finishes fast", dt < 50, "dt=%d" % dt)
	_check("budget reports tris", int(capped.get("tris_tested", 0)) > 0)
	mi.free()


func _test_pipe_kit_meta() -> void:
	_check("abs_dwv uses pipe kit", ConduitKinds.uses_pipe_kit("abs_dwv"))
	_check("pvc_pipe uses pipe kit", ConduitKinds.uses_pipe_kit("pvc_pipe"))
	_check("abs kit id 2.5", ConduitKinds.pipe_kit_id("abs_dwv") == "us_sch40_2_5")
	_check("pvc kit id size",
		ConduitKinds.pipe_kit_id("pvc_pipe", {"pipe_size_in": 4.0}) == "us_sch40_4")
	_check("abs sharp elbow frac", is_equal_approx(
		float(ConduitKinds.type_meta("abs_dwv").get("elbow_radius_frac", 1.0)), 0.0))
	_check("pvc sharp elbow frac", is_equal_approx(
		float(ConduitKinds.type_meta("pvc_pipe").get("elbow_radius_frac", 1.0)), 0.0))


## Poly penstock kind + contour router (Phase C of the Hydro Lab overhaul).
func _test_poly_penstock_kind() -> void:
	_check("has poly_penstock", ConduitKinds.has_type("poly_penstock"))
	var meta := ConduitKinds.type_meta("poly_penstock")
	_check("penstock route_mode contour", str(meta.get("route_mode", "")) == "contour")
	_check("penstock bend mult 25 (PPI 20-27x OD)",
		is_equal_approx(float(meta.get("bend_radius_od_mult", 0.0)), 25.0))
	_check("penstock not a pipes/culvert kind",
		not ConduitKinds.is_pipes_type("poly_penstock")
		and not ConduitKinds.uses_culvert_kit("poly_penstock")
		and not ConduitKinds.uses_pipe_kit("poly_penstock"))
	var sizes := ConduitKinds.pipe_kit_sizes_in("poly_penstock")
	_check("penstock sizes 1/1.25/1.5/2", sizes == [1.0, 1.25, 1.5, 2.0],
		str(sizes))
	_check("penstock default size 1.5",
		is_equal_approx(ConduitKinds.pipe_size_in("poly_penstock"), 1.5))
	_check("penstock size snaps to list",
		is_equal_approx(ConduitKinds.pipe_size_in("poly_penstock", {"pipe_size_in": 1.6}), 1.5))
	# SDR-9 inner diameters, hand-computed: ID = OD_in * (7/9) * 25.4 mm.
	#   1":   1.315 * 7/9 = 1.0228" = 25.98 mm
	#   1.5": 1.900 * 7/9 = 1.4778" = 37.53 mm
	#   2":   2.375 * 7/9 = 1.8472" = 46.92 mm
	var id_1 := ConduitKinds.inner_diameter_for("poly_penstock", {"pipe_size_in": 1.0})
	var id_15 := ConduitKinds.inner_diameter_for("poly_penstock", {"pipe_size_in": 1.5})
	var id_2 := ConduitKinds.inner_diameter_for("poly_penstock", {"pipe_size_in": 2.0})
	_check("SDR-9 ID 1in ~25.98mm", absf(id_1 * 1000.0 - 25.98) < 0.05, "%.2f" % (id_1 * 1000.0))
	_check("SDR-9 ID 1.5in ~37.53mm", absf(id_15 * 1000.0 - 37.53) < 0.05, "%.2f" % (id_15 * 1000.0))
	_check("SDR-9 ID 2in ~46.92mm", absf(id_2 * 1000.0 - 46.92) < 0.05, "%.2f" % (id_2 * 1000.0))
	# Non-size kinds keep their flat inner_diameter_m (unchanged behavior).
	_check("garden hose keeps flat ID",
		is_equal_approx(ConduitKinds.inner_diameter_for("garden_hose"),
			float(ConduitKinds.type_meta("garden_hose").get("inner_diameter_m", 0.0))))
	# Min bend radius at 1.5": 25 x 1.900" OD = 25 x 0.04826 m = 1.2065 m.
	var r_bend := ConduitKinds.contour_bend_radius_m("poly_penstock", {"pipe_size_in": 1.5})
	_check("bend radius 1.5in ~1.21m", absf(r_bend - 1.2065) < 0.005, "%.4f" % r_bend)
	_check("size in display name",
		ConduitKinds.display_name_with_size("poly_penstock").contains("1"))


## The player's own pipe: SDR per run (bore, rating, bend radius from the PPI
## tables), the plan-view fillet so coiled pipe never turns a corner, the
## route report (tightest bend, high points, siphon rise) and the design
## checks — pinned to hand-computed numbers for 2" SDR 11.5 HDPE.
func _test_penstock_spec_and_design() -> void:
	var st := {"pipe_size_in": 2.0, "pipe_sdr": 11.5}
	# ID = 2.375" × (1 − 2/11.5) = 2.375 × 0.82609 = 1.9620" = 49.83 mm.
	var id_m := ConduitKinds.inner_diameter_for("poly_penstock", st)
	_check("SDR 11.5 2in ID ~49.83mm", absf(id_m * 1000.0 - 49.83) < 0.05, "%.2f" % (id_m * 1000.0))
	_check("no styled SDR → stock SDR 9 (unchanged)",
		is_equal_approx(ConduitKinds.pipe_sdr("poly_penstock", {"pipe_size_in": 2.0}), 9.0))
	# PR = 2·1000/(11.5−1) = 190.5 psi; SDR 9 → 250 (the kind's burst_pressure_psi).
	_check("SDR 11.5 rating ~190 psi", absf(ConduitKinds.pressure_rating_psi("poly_penstock", st) - 190.48) < 0.1)
	_check("SDR 9 rating 250 psi", is_equal_approx(ConduitKinds.pressure_rating_psi("poly_penstock", {"pipe_size_in": 2.0}), 250.0))
	# Wall = OD/SDR = 60.325 mm / 11.5 = 5.246 mm.
	_check("SDR 11.5 2in wall ~5.25mm", absf(ConduitKinds.wall_thickness_m("poly_penstock", st) * 1000.0 - 5.246) < 0.01)
	# PPI ch.7: DR 11–13.5 → 25×OD = 25 × 60.325 mm = 1.508 m; SDR 9 → 20× = 1.2065 m;
	# SDR 17 → 27× = 1.629 m. (Without a styled SDR the kind's 25× stays — pinned above.)
	_check("bend r SDR 11.5 2in ~1.508m", absf(ConduitKinds.contour_bend_radius_m("poly_penstock", st) - 1.508) < 0.005)
	_check("bend r SDR 9 2in 20x ~1.2065m",
		absf(ConduitKinds.contour_bend_radius_m("poly_penstock", {"pipe_size_in": 2.0, "pipe_sdr": 9.0}) - 1.2065) < 0.005)
	_check("bend r SDR 17 2in 27x ~1.629m",
		absf(ConduitKinds.contour_bend_radius_m("poly_penstock", {"pipe_size_in": 2.0, "pipe_sdr": 17.0}) - 1.6288) < 0.005)
	# Plan fillet: a 90° corner on flat ground. The sharpest plan radius of the
	# routed run must be the pipe's radius (not a 1 m-step corner), the run
	# shorter than the two legs (the arc cuts the corner), ends pinned.
	var flat := func(_p: Vector3) -> float: return 0.0
	var corner: Array = [Vector3(0, 0.05, 0), Vector3(30, 0.05, 0), Vector3(30, 0.05, 30)]
	var r_fil := ContourRouter.route_polyline(corner, flat, 1.5)
	var rep := ContourRouter.route_report(r_fil)
	_check("fillet: tightest plan radius ≈ pipe radius", absf(float(rep["min_bend_r_m"]) - 1.5) < 0.12,
		"%.3f" % float(rep["min_bend_r_m"]))
	_check("fillet: run stays ~60 m (legs shortened, arc added)",
		absf(float(rep["length_m"]) - 60.0) < 1.5, "%.2f" % float(rep["length_m"]))
	# The corner point (a player's pin / a stream vertex) is ON the pipe.
	var on_pin := false
	for q in r_fil:
		if Vector2(q.x, q.z).distance_to(Vector2(30.0, 30.0)) < 0.01 or Vector2(q.x, q.z).distance_to(Vector2(30.0, 0.0)) < 0.01:
			on_pin = true
	_check("fillet: the corner point stays on the pipe (apex arc)", on_pin)
	_check("fillet: ends pinned", r_fil[0].is_equal_approx(corner[0]) and r_fil[r_fil.size() - 1].is_equal_approx(corner[2]))
	var r_sharp := ContourRouter.route_polyline(corner, flat, 0.0)
	_check("no radius → corner kept sharp", float(ContourRouter.route_report(r_sharp)["min_bend_r_m"]) < 1.0)
	# Legs too short for the radius: the arc shrinks to fit and reads as a tight bend.
	var tight: Array = [Vector3(0, 0.05, 0), Vector3(4, 0.05, 0), Vector3(4, 0.05, 4)]
	var r_t := ContourRouter.route_polyline(tight, flat, 3.5)
	var rt := float(ContourRouter.route_report(r_t)["min_bend_r_m"])
	_check("short legs: fillet shrinks, reported as tight", rt < 3.5 and rt > 1.5, "%.3f" % rt)
	# The seated port approaches (fittings) are outside the bend report.
	var elbow_at_port: Array = [Vector3(0, 0.05, 0), Vector3(1.0, 0.05, 0), Vector3(1.0, 0.05, 20)]
	var r_e := ContourRouter.route_polyline(elbow_at_port, flat, 1.5)
	_check("a corner inside the port approach is not a reported bend",
		not is_finite(float(ContourRouter.route_report(r_e)["min_bend_r_m"])))
	# Straight run: no bend at all.
	var r_s := ContourRouter.route_polyline([Vector3(0, 0.05, 0), Vector3(40, 0.05, 0)], flat, 1.5)
	_check("straight run reports no bend", not is_finite(float(ContourRouter.route_report(r_s)["min_bend_r_m"])))
	# Route report over a crest: one high point, siphon rise above the intake.
	var hump := PackedVector3Array()
	for i in 41:
		var x := float(i)
		var y := 2.0 * exp(-pow((x - 20.0) / 5.0, 2.0))  # 2 m bump at x=20
		hump.append(Vector3(x, y, 0.0))
	var hr := ContourRouter.route_report(hump)
	_check("report: one high point on a hump", int(hr["high_points"]) == 1, str(hr["high_points"]))
	_check("report: rise above the intake ~2m", absf(float(hr["rise_above_intake_m"]) - 2.0) < 0.05)
	var slope := PackedVector3Array()
	for i in 41:
		slope.append(Vector3(float(i), 20.0 - 0.5 * float(i), 0.0))
	var sr := ContourRouter.route_report(slope)
	_check("report: a falling run has no high point and no rise",
		int(sr["high_points"]) == 0 and float(sr["rise_above_intake_m"]) < 1e-6)
	# Design checks, 2" SDR 11.5 at 4 L/s on 45 m gross, 105 m run, 350 ft on hand:
	#   A = π/4 × 0.04983² = 1.9503e-3 m² → v = 0.004 / A = 2.051 m/s
	#   wave speed a = 1/√(1000 × (1/2.2e9 + 0.04983/(1e9 × 0.005246))) = 317 m/s
	#   surge = 317 × 2.051 / 9.80665 = 66.3 m
	_check("velocity 4 L/s in 49.83 mm ~2.05 m/s", absf(PenstockDesign.velocity_ms(4.0, 0.04983) - 2.051) < 0.01)
	var a := PenstockDesign.wave_speed_ms(0.04983, 0.005246)
	_check("HDPE wave speed ~317 m/s", absf(a - 317.0) < 3.0, "%.1f" % a)
	_check("Joukowsky surge ~66 m", absf(PenstockDesign.surge_head_m(2.051, 317.0) - 66.3) < 0.5)
	_check("190 psi ≈ 134 m of head", absf(PenstockDesign.psi_to_head_m(190.48) - 133.9) < 0.3)
	var cks := PenstockDesign.checks({
		"q_lps": 4.0, "gross_head_m": 45.0, "head_loss_m": 3.0, "id_m": 0.04983,
		"od_m": 0.060325, "sdr": 11.5, "wall_m": 0.005246, "length_m": 104.8,
		"stock_m": 350.0 * 0.3048, "rating_psi": 190.48, "min_bend_r_m": 1.508,
		"route_min_bend_r_m": 2.4, "high_points": 0, "rise_above_intake_m": 0.0,
	})
	var by_key := {}
	for c in cks:
		by_key[str((c as Dictionary)["key"])] = c
	_check("checks: all eight present", by_key.has("velocity") and by_key.has("friction") and by_key.has("static")
		and by_key.has("surge") and by_key.has("bend") and by_key.has("air") and by_key.has("stock"), str(by_key.keys()))
	_check("checks: 2 m/s ok", str((by_key["velocity"] as Dictionary)["level"]) == "ok")
	_check("checks: 3 m of 45 m = 6.7 % ok", str((by_key["friction"] as Dictionary)["level"]) == "ok")
	_check("checks: 45 m static under 134 m rating", str((by_key["static"] as Dictionary)["level"]) == "ok")
	_check("checks: 45 + 66 m surge under the rating", str((by_key["surge"] as Dictionary)["level"]) == "ok")
	_check("checks: 2.4 m bend ≥ 1.508 ok", str((by_key["bend"] as Dictionary)["level"]) == "ok")
	_check("checks: 105 m run fits 350 ft", str((by_key["stock"] as Dictionary)["level"]) == "ok"
		and str((by_key["stock"] as Dictionary)["text"]).contains("spare"))
	_check("checks: worst level ok", PenstockDesign.worst_level(cks) == "ok")
	# Now the same pipe at 400 ft of run on 350 ft of stock, a 1.0 m bend and a high point.
	var bad := PenstockDesign.checks({
		"q_lps": 8.0, "gross_head_m": 120.0, "head_loss_m": 30.0, "id_m": 0.04983,
		"od_m": 0.060325, "sdr": 11.5, "wall_m": 0.005246, "length_m": 400.0 * 0.3048,
		"stock_m": 350.0 * 0.3048, "rating_psi": 190.48, "min_bend_r_m": 1.508,
		"route_min_bend_r_m": 1.0, "high_points": 2, "rise_above_intake_m": 9.5,
	})
	var bk := {}
	for c2 in bad:
		bk[str((c2 as Dictionary)["key"])] = c2
	_check("bad: 4.1 m/s fails velocity", str((bk["velocity"] as Dictionary)["level"]) != "ok")
	_check("bad: 25 % friction fails", str((bk["friction"] as Dictionary)["level"]) == "fail")
	_check("bad: surge over the rating", str((bk["surge"] as Dictionary)["level"]) != "ok")
	_check("bad: 1.0 m bend too tight", str((bk["bend"] as Dictionary)["level"]) == "warn")
	_check("bad: two high points warn", str((bk["air"] as Dictionary)["level"]) == "warn")
	_check("bad: 9.5 m siphon lift fails", str((bk["siphon"] as Dictionary)["level"]) == "fail")
	_check("bad: short of stock", str((bk["stock"] as Dictionary)["level"]) == "fail"
		and str((bk["stock"] as Dictionary)["text"]).contains("SHORT"))
	_check("bad: worst level fail", PenstockDesign.worst_level(bad) == "fail")
	var txt := PenstockDesign.summary_text("T", ["a", "b"], bad)
	_check("summary text carries every check", txt.contains("[FAIL]") and txt.contains("SHORT") and txt.begins_with("T"))
	# Closure time (Michaud): 118 m run, 0.49 m/s, a = 317 → 2L/a = 0.744 s;
	# 10 s close → ΔH = 2·118·0.49/(9.80665·10) = 1.179 m; a 0.5 s close is
	# faster than 2L/a → the full Joukowsky 15.8 m.
	_check("critical time 2L/a ~0.744 s", absf(PenstockDesign.critical_time_s(118.0, 317.0) - 0.7445) < 0.002)
	_check("Michaud 10 s close ~1.18 m", absf(PenstockDesign.surge_head_closure_m(0.49, 317.0, 118.0, 10.0) - 1.179) < 0.01)
	_check("a close faster than 2L/a is the instant stop",
		absf(PenstockDesign.surge_head_closure_m(0.49, 317.0, 118.0, 0.5) - PenstockDesign.surge_head_m(0.49, 317.0)) < 1e-6)
	var slow := PenstockDesign.checks({"q_lps": 4.0, "gross_head_m": 45.0, "id_m": 0.04983, "wall_m": 0.005246,
		"rating_psi": 190.48, "length_m": 118.0, "close_s": 10.0})
	var surge_txt := ""
	for c3 in slow:
		if str((c3 as Dictionary)["key"]) == "surge":
			surge_txt = str((c3 as Dictionary)["text"])
	_check("surge check names the closure time and the instant-stop figure",
		surge_txt.contains("over 10 s") and surge_txt.contains("instant stop would be +66 m"), surge_txt)
	# Intake works at 1 L/s through 49.83 mm: screen 0.001/(0.3·0.5) = 0.00667 m²
	# (8.2 cm square); settling 2·0.001/0.03 = 0.0667 m² → 0.129 × 0.516 m, depth
	# floored at 0.3 m; v_pipe 0.513 m/s → Gordon S = 1.7·0.513·√0.04983 = 0.195 m.
	var iw := PenstockDesign.intake_works(1.0, 0.04983)
	_check("screen side ~8.2 cm", absf(float(iw["screen_side_m"]) - 0.0816) < 0.001, "%.4f" % float(iw["screen_side_m"]))
	_check("settling box ~0.52 × 0.13 m", absf(float(iw["settle_len_m"]) - 0.516) < 0.005
		and absf(float(iw["settle_w_m"]) - 0.129) < 0.002)
	_check("settling depth floored at 0.3 m", is_equal_approx(float(iw["settle_depth_m"]), 0.3))
	_check("Gordon submergence ~0.195 m", absf(float(iw["submergence_m"]) - 0.1947) < 0.002, "%.4f" % float(iw["submergence_m"]))
	_check("settling velocity interpolates the table", absf(PenstockDesign.settling_velocity_ms(0.4) - 0.04) < 1e-6
		and absf(PenstockDesign.settling_velocity_ms(5.0) - 0.1) < 1e-6)
	# Firm flow: driest month Aug (index 7), wettest Jan; 5 months under a 1 L/s jet.
	var sup := [1.6, 1.5, 1.3, 1.1, 0.9, 0.8, 0.7, 0.6, 0.8, 1.0, 1.3, 1.5]
	var kw := [0.3, 0.3, 0.3, 0.3, 0.25, 0.2, 0.18, 0.15, 0.2, 0.28, 0.3, 0.3]
	var ff := PenstockDesign.firm_flow(sup, kw, 1.0)
	_check("firm flow: driest Aug 0.6 L/s / 150 W", int(ff["min_month"]) == 7 and is_equal_approx(float(ff["min_lps"]), 0.6)
		and is_equal_approx(float(ff["min_kw"]), 0.15))
	_check("firm flow: wettest Jan", int(ff["max_month"]) == 0)
	_check("firm flow: 5 months below a 1 L/s jet", int(ff["limited_months"]) == 5, str(ff["limited_months"]))
	_check("firm flow: 11 entries → {}", PenstockDesign.firm_flow([1.0], kw).is_empty())


## Synthetic hill for contour routing tests: smooth ridge at x=30, plus a sharp
## V-notch gully at x=70 that a pipe with a real bend radius must bridge.
func _contour_test_ground(pos: Vector3) -> float:
	var ridge := 6.0 * exp(-pow((pos.x - 30.0) / 12.0, 2.0))
	var notch := 0.0
	var d := absf(pos.x - 70.0)
	if d < 2.0:
		notch = -3.0 * (1.0 - d / 2.0)
	return ridge + notch


func _test_contour_router() -> void:
	var a := Vector3(0, 0.4, 0)
	var b := Vector3(100, 0.4, 0)
	var r1 := ContourRouter.route_polyline([a, b],
		Callable(self, "_contour_test_ground"), 1.2)
	_check("contour: sampled route", r1.size() >= 60, "n=%d" % r1.size())
	var chord := a.distance_to(b)
	var run := ContourRouter.polyline_length_m(r1)
	_check("contour: run over a hill > chord", run > chord + 0.5,
		"run=%.2f chord=%.2f" % [run, chord])
	# Endpoints pinned to the ports.
	_check("contour: start pinned", r1[0].is_equal_approx(a))
	_check("contour: end pinned", r1[r1.size() - 1].is_equal_approx(b))
	# Every interior sample sits on-or-above the ground (clearance respected;
	# smoothing only ever RAISES points).
	var below := 0
	for i in range(3, r1.size() - 3):
		var g := _contour_test_ground(r1[i])
		if r1[i].y < g + ContourRouter.CLEARANCE_M - 0.001:
			below += 1
	_check("contour: never tunnels below ground", below == 0, "below=%d" % below)
	# The sharp V-notch (walls steeper than a 1.2 m bend radius can follow at
	# this sample step) is bridged: the routed pipe at the notch centre stays
	# well above the notch floor.
	var notch_y := INF
	for p in r1:
		if absf(p.x - 70.0) < 0.8:
			notch_y = minf(notch_y, p.y)
	_check("contour: sharp gully bridged", notch_y > -2.0, "y=%.2f" % notch_y)
	# Determinism (preview==commit): identical inputs, identical output.
	var r2 := ContourRouter.route_polyline([a, b],
		Callable(self, "_contour_test_ground"), 1.2)
	_check("contour: deterministic", r1 == r2)
	# Player waypoint keeps its position (pin honored in the polyline).
	var pin := Vector3(50, 1.5, 8)
	var r3 := ContourRouter.route_polyline([a, pin, b],
		Callable(self, "_contour_test_ground"), 1.2)
	var pin_hit := false
	for p in r3:
		if p.distance_to(pin) < 0.01:
			pin_hit = true
			break
	_check("contour: waypoint pinned", pin_hit)
	# No ground callable -> straight chord samples (offline/headless fallback).
	var r4 := ContourRouter.route_polyline([a, b], Callable(), 1.2)
	_check("contour: no-ground fallback stays on chord",
		absf(ContourRouter.polyline_length_m(r4) - chord) < 0.01)


func _test_contour_dispatch() -> void:
	# Through the SAME dispatch commit + preview use, with the ground callable:
	# the returned control points must follow the terrain, and the derived
	# route length is what _write_length_back will persist as route_length_m.
	var ends := {
		"a": Vector3(0, 0.4, 0), "b": Vector3(100, 0.4, 0),
		"a_route": Vector3(0, 0.4, 0), "b_route": Vector3(100, 0.4, 0),
		"seat_a": false, "seat_b": false,
		"out_a": Vector3.ZERO, "out_b": Vector3.ZERO,
	}
	var r := ConduitRouteDispatch.control_points(ends, "poly_penstock", {}, [], false,
		[], true, 0.6, Callable(self, "_contour_test_ground"))
	_check("dispatch contour: routed", r.size() >= 60, "n=%d" % r.size())
	var over_ridge := false
	for p: Vector3 in r:
		if absf(p.x - 30.0) < 1.5 and p.y > 4.0:
			over_ridge = true
			break
	_check("dispatch contour: follows the ridge", over_ridge)
	# Without a ground callable (defaulted param) it degrades to the chord —
	# never an error (offline callers).
	var flat := ConduitRouteDispatch.control_points(ends, "poly_penstock", {}, [], false,
		[], true, 0.6)
	_check("dispatch contour: no-ground degrades to chord", flat.size() >= 2)


## Phase H: a size-listed kind renders at its STYLED bore. ConduitMeshBuilder
## reads radius_m off the kind meta, so without the manager stamping it a 2"
## poly run drew exactly as thin as a 1" one — the diameter being the main
## thing the player tunes, that made the whole size picker look inert.
func _test_size_driven_tube_radius() -> void:
	var meta_r := float(ConduitKinds.type_meta("poly_penstock").get("radius_m", 0.0))
	_check("poly kind carries a fallback radius", meta_r > 0.0)
	var r1 := ConduitKinds.outer_diameter_m("poly_penstock", {"pipe_size_in": 1.0}) * 0.5
	var r2 := ConduitKinds.outer_diameter_m("poly_penstock", {"pipe_size_in": 2.0}) * 0.5
	# IPS OD: 1" = 1.315", 2" = 2.375" → radii 0.0167 m and 0.0302 m.
	_check("1in tube radius ~16.7mm", absf(r1 - 0.016700) < 0.0002, "%.5f" % r1)
	_check("2in tube radius ~30.2mm", absf(r2 - 0.030163) < 0.0002, "%.5f" % r2)
	_check("a 2in run draws visibly fatter than a 1in run", r2 > r1 * 1.5)
	# Kinds WITHOUT a size list keep their single authored radius (unchanged).
	_check("garden hose has no size options",
		not ConduitKinds.has_size_options("garden_hose"))
	_check("kit pipes still report size options",
		ConduitKinds.has_size_options("pvc_pipe")
		and ConduitKinds.has_size_options("culvert_pipe"))
	# The builder honours an explicit radius override (the stamp path).
	var pts: Array = [Vector3.ZERO, Vector3(4.0, 0.0, 0.0)]
	var thin: Dictionary = ConduitMeshBuilder.build(pts, "poly_penstock", 2,
		Callable(), {"radius_m": r1})
	var fat: Dictionary = ConduitMeshBuilder.build(pts, "poly_penstock", 2,
		Callable(), {"radius_m": r2})
	var thin_mesh: ArrayMesh = thin.get("mesh", null)
	var fat_mesh: ArrayMesh = fat.get("mesh", null)
	_check("both tube meshes built", thin_mesh != null and fat_mesh != null)
	if thin_mesh != null and fat_mesh != null:
		var ty := thin_mesh.get_aabb().size.y
		var fy := fat_mesh.get_aabb().size.y
		_check("styled radius reaches the mesh (%.4f vs %.4f)" % [ty, fy], fy > ty * 1.5)


## ConduitLength (the readout) + RunLengthLabels' arc midpoint.
func _test_conduit_length() -> void:
	# 23 m = 75.46 ft of cord: the 100 ft cord covers it with 24.5 ft spare.
	var f := ConduitLength.stock_fit(23.0, "extension_cord")
	_check("length: 23 m cord fits a 100 ft cord", int(f.get("stock_ft", 0)) == 100 \
			and absf(float(f.get("spare_ft", 0.0)) - 24.54) < 0.05, str(f))
	# 40 m = 131.2 ft of hose: two 100 ft hoses.
	var h := ConduitLength.stock_fit(40.0, "garden_hose")
	_check("length: 40 m hose needs 2 × 100 ft", int(h.get("count", 0)) == 2 and int(h.get("stock_ft", 0)) == 100, str(h))
	# 7 m = 22.97 ft of PVC: three 10 ft sticks.
	var pv := ConduitLength.stock_fit(7.0, "pvc_pipe")
	_check("length: 7 m PVC is 3 sticks", str(pv.get("kind", "")) == "sticks" and int(pv.get("count", 0)) == 3, str(pv))
	_check("length: Ethernet past 100 m is flagged", not bool(ConduitLength.stock_fit(110.0, "ethernet").get("ok", true)))
	_check("length: format", ConduitLength.format(23.4) == "23.4 m · 76.8 ft", ConduitLength.format(23.4))
	var mid := RunLengthLabels.midpoint(PackedVector3Array([Vector3.ZERO, Vector3(10, 0, 0), Vector3(10, 0, 10)]))
	_check("length: label sits at the arc midpoint", mid.distance_to(Vector3(10, 0, 0)) < 0.001, str(mid))
