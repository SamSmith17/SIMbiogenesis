extends SceneTree

## Offline self-test for ConduitKinds, GraphModel v4 migration, and ConduitMeshBuilder.
## Run: godot --headless --path . --script core/conduits/conduit_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
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
	var ac_conn := {"polarity": "ac", "resource_type": "", "conduit_type": ""}
	_check("ac -> extension_cord", ConduitKinds.derive_type_for_connection(ac_conn) == "extension_cord")
	var water_conn := {"polarity": "resource", "resource_type": "water", "conduit_type": ""}
	_check("water -> garden_hose", ConduitKinds.derive_type_for_connection(water_conn) == "garden_hose")
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
	var built: Dictionary = ConduitMeshBuilder.build(control, "extension_cord", 8)
	var mesh: ArrayMesh = built.get("mesh", null)
	_check("mesh created", mesh != null and mesh.get_surface_count() > 0)
	var arc: float = float(built.get("arc_length_m", 0.0))
	_check("arc length > 10m (sag)", arc > 10.0, "arc=%.3f" % arc)
	var rigid: Dictionary = ConduitMeshBuilder.build(control, "pvc_pipe", 4)
	var rigid_arc: float = float(rigid.get("arc_length_m", 0.0))
	_check("rigid ~10m", absf(rigid_arc - 10.0) < 0.05, "arc=%.3f" % rigid_arc)
	var samples: PackedVector3Array = ConduitMeshBuilder.sample_path(
		control, ConduitKinds.type_meta("extension_cord"), 6)
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
	_check("hot_water -> pex_red",
		ConduitKinds.derive_type_for_connection({"polarity": "resource", "resource_type": "hot_water"}) == "pex_red")


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
	# 20 m span 0.5 m above flat ground at y=0: free catenary sag would dip to
	# 0.5 - 20*0.35*0.3 = -1.6 m; drape must clamp at ground + clearance.
	var control: Array = [Vector3(0, 0.5, 0), Vector3(20, 0.5, 0)]
	var ground_fn := func(_pos: Vector3) -> float: return 0.0
	var style: Dictionary = ConduitKinds.type_meta("extension_cord")
	var free: PackedVector3Array = ConduitMeshBuilder.sample_path(control, style, 12)
	var draped: PackedVector3Array = ConduitMeshBuilder.sample_path(control, style, 12, ground_fn)
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
	# Non-drape kinds (patio lights) ignore ground_y_fn and keep their sag.
	var patio_style: Dictionary = ConduitKinds.type_meta("led_patio")
	var patio: PackedVector3Array = ConduitMeshBuilder.sample_path(control, patio_style, 12, ground_fn)
	var patio_min := 1e9
	for p: Vector3 in patio:
		patio_min = minf(patio_min, p.y)
	_check("patio still sags", patio_min < 0.0, "min=%.3f" % patio_min)


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
