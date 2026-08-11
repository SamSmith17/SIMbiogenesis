extends SceneTree

## Offline self-test for SiphonHydraulics (prime / break / power cap).
## Run (after --import so class_names register):
##   Godot.exe.exe --headless --path . --script core/conduits/siphon_hydraulics_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_prime_break()
	_test_flow_and_power()
	_test_no_head()
	_test_graded_culvert_router()
	_test_start_break_keys()
	_test_rpm_and_pe()
	_test_modal_script_compiles()
	_test_direct_intake_visibility()
	_test_powerspout_model()
	_test_powerspout_spin()
	_test_elevation_cross_section_drawer()
	_test_elevation_profile_bake()
	_test_lab_engine_step()
	_test_outlet_sink_format()
	_test_contiguous_wet_interval()
	_test_eight_inch_orifice()
	_test_lab_dt_no_flood()
	_test_start_break_follow_module()
	if _failures == 0:
		print("SIPHON HYDRAULICS SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SIPHON HYDRAULICS SELFTEST FAIL  (%d of %d checks failed)" % [
			_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	if detail.is_empty():
		print("  FAIL: %s" % label)
	else:
		print("  FAIL: %s  (%s)" % [label, detail])


func _test_prime_break() -> void:
	var inv := 100.0
	var crown := 100.15  # 6″ ≈ 0.15 m
	var out_inv := 91.0
	var dry := SiphonHydraulics.simulate(99.9, inv, crown, out_inv, 0.15, 0.20,
			20.0, 0.012, false)
	_check("dry below invert not primed", not bool(dry.get("primed", true)))
	_check("dry Q zero", float(dry.get("q_lps", 1.0)) < 1e-6)
	var between := SiphonHydraulics.simulate(100.08, inv, crown, out_inv, 0.15, 0.20,
			20.0, 0.012, false)
	_check("between invert and crown stays dry until primed",
			not bool(between.get("primed", true)))
	var prime := SiphonHydraulics.simulate(100.20, inv, crown, out_inv, 0.15, 0.20,
			20.0, 0.012, false)
	_check("above crown primes", bool(prime.get("primed", false)))
	_check("primed has flow", float(prime.get("q_lps", 0.0)) > 0.1,
			"Q=%.3f" % float(prime.get("q_lps", 0.0)))
	# Latch: still flowing between invert and crown while primed.
	var hold := SiphonHydraulics.simulate(100.05, inv, crown, out_inv, 0.15, 0.20,
			20.0, 0.012, true)
	_check("latched siphon holds mid-band", bool(hold.get("primed", false)))
	_check("latched mid-band flows", float(hold.get("q_lps", 0.0)) > 0.01)
	var brk := SiphonHydraulics.simulate(99.95, inv, crown, out_inv, 0.15, 0.20,
			20.0, 0.012, true)
	_check("below invert breaks", not bool(brk.get("primed", true)))
	_check("broken Q zero", float(brk.get("q_lps", 1.0)) < 1e-6)


func _test_flow_and_power() -> void:
	var uncapped := SiphonHydraulics.simulate(100.40, 100.0, 100.15, 91.0, 0.15, 0.20,
			20.0, 0.012, true, 0.0, 0.6, 0.7)
	_check("uncapped power positive", float(uncapped.get("power_w", 0.0)) > 1.0,
			"P=%.1f" % float(uncapped.get("power_w", 0.0)))
	_check("uncapped tracks η·PE",
			absf(float(uncapped.get("power_w", 0.0))
				- float(uncapped.get("pe_w", 0.0)) * 0.6 * 0.7) < 1.0,
			"P=%.1f pe=%.1f" % [float(uncapped.get("power_w", 0.0)),
				float(uncapped.get("pe_w", 0.0))])
	var r := SiphonHydraulics.simulate(100.40, 100.0, 100.15, 91.0, 0.15, 0.20,
			20.0, 0.012, true, 250.0, 0.6, 0.7)
	_check("power positive", float(r.get("power_w", 0.0)) > 1.0,
			"P=%.1f" % float(r.get("power_w", 0.0)))
	_check("power capped at 250 W", float(r.get("power_w", 999.0)) <= 250.01,
			"P=%.1f" % float(r.get("power_w", 0.0)))
	_check("kw matches watts",
			absf(float(r.get("power_kw", 0.0)) * 1000.0 - float(r.get("power_w", 0.0))) < 0.1)
	var tiny := SiphonHydraulics.simulate(100.40, 100.0, 100.15, 91.0, 0.15, 0.20,
			20.0, 0.012, true, 50.0, 0.9, 0.9)
	_check("lower max_power_w caps", float(tiny.get("power_w", 999.0)) <= 50.01)


func _test_no_head() -> void:
	var r := SiphonHydraulics.simulate(100.20, 100.0, 100.15, 100.20, 0.15, 0.20,
			20.0, 0.012, true)
	_check("flat head no Q", float(r.get("q_lps", 1.0)) < 1e-6)
	_check("flat head still primed", bool(r.get("primed", false)))
	_check("crown helper",
			absf(SiphonHydraulics.crown_from_invert(10.0, 0.15) - 10.15) < 1e-6)


func _test_graded_culvert_router() -> void:
	# Bare A→B downhill should be a short graded chain (not leave-then-drop L).
	var a := Vector3(0.0, 100.0, 0.0)
	var b := Vector3(20.0, 91.0, 0.0)
	var chain := CulvertRouter.expand([a, b], 1.5)
	_check("router expands downhill", chain.size() >= 2)
	var min_y := INF
	for p in chain:
		min_y = minf(min_y, p.y)
	_check("router does not dive below outlet", min_y >= b.y - 0.05,
			"min_y=%.2f out=%.2f" % [min_y, b.y])
	# No mid elbow below both ends.
	var below_both := false
	for p in chain:
		if p.y < minf(a.y, b.y) - 0.1:
			below_both = true
	_check("no deep U below grade", not below_both)


func _test_start_break_keys() -> void:
	# Explicit siphon_start_m / siphon_break_m override legacy crown/invert.
	var r := SiphonHydraulics.simulate(
		100.25, 99.0, 99.1, 91.0, 0.15, 0.20, 20.0, 0.012, false,
		250.0, 0.6, 0.7, 100.20, 100.05)
	_check("start/break primes at start", bool(r.get("primed", false)))
	_check("start/break echoes keys",
			absf(float(r.get("siphon_start_m", 0.0)) - 100.20) < 1e-4)
	var hold := SiphonHydraulics.simulate(
		100.10, 99.0, 99.1, 91.0, 0.15, 0.20, 20.0, 0.012, true,
		250.0, 0.6, 0.7, 100.20, 100.05)
	_check("latched between start and break", bool(hold.get("primed", false)))
	var brk := SiphonHydraulics.simulate(
		100.00, 99.0, 99.1, 91.0, 0.15, 0.20, 20.0, 0.012, true,
		250.0, 0.6, 0.7, 100.20, 100.05)
	_check("breaks below break level", not bool(brk.get("primed", true)))
	var from_specs := SiphonHydraulics.simulate_from_specs(100.30, {
		"siphon_start_m": 100.20,
		"siphon_break_m": 100.05,
		"outlet_invert_m": 91.0,
		"intake_diameter_mm": 150.0,
		"outlet_diameter_mm": 200.0,
		"barrel_length_m": 20.0,
		"siphon_primed": false,
		"max_power_w": 250.0,
		"hydraulic_efficiency": 0.6,
		"generator_efficiency": 0.7,
	})
	_check("simulate_from_specs primes", bool(from_specs.get("primed", false)))
	_check("module elev independent of latch",
			absf(SiphonHydraulics.crown_from_invert(10.0, 0.15) - 10.15) < 1e-6)


func _test_rpm_and_pe() -> void:
	var r := SiphonHydraulics.simulate(100.40, 100.0, 100.15, 91.0, 0.15, 0.20,
			20.0, 0.012, true, 250.0, 0.6, 0.7)
	_check("pe_w present and positive", float(r.get("pe_w", 0.0)) > float(r.get("power_w", 0.0)) - 1.0,
			"pe=%.1f p=%.1f" % [float(r.get("pe_w", 0.0)), float(r.get("power_w", 0.0))])
	_check("rpm scales with PE", float(r.get("rpm", 0.0)) > 1.0,
			"rpm=%.1f" % float(r.get("rpm", 0.0)))
	# Nameplate clamp must NOT freeze RPM — ω tracks PE. Use a short head so PE
	# stays below the overspeed ceiling (otherwise both sit at 1.25× rated).
	var lo := SiphonHydraulics.simulate(100.22, 100.0, 100.15, 99.5, 0.15, 0.20,
			20.0, 0.012, true, 50.0, 0.6, 0.7)
	var hi := SiphonHydraulics.simulate(100.40, 100.0, 100.15, 99.5, 0.15, 0.20,
			20.0, 0.012, true, 50.0, 0.6, 0.7)
	_check("rpm rises with PE under nameplate",
			float(hi.get("pe_w", 0.0)) > float(lo.get("pe_w", 0.0)) + 1.0 \
			and float(hi.get("rpm", 0.0)) > float(lo.get("rpm", 0.0)) + 0.5,
			"lo_rpm=%.0f hi_rpm=%.0f lo_pe=%.0f hi_pe=%.0f" % [
				float(lo.get("rpm", 0.0)), float(hi.get("rpm", 0.0)),
				float(lo.get("pe_w", 0.0)), float(hi.get("pe_w", 0.0))])
	_check("nameplate clamps electrical not PE",
			float(hi.get("power_w", 999.0)) <= 50.01 \
			and float(hi.get("pe_w", 0.0)) > 50.0)
	var dry_w := SiphonHydraulics.omega_from_pe_w(0.0)
	_check("omega zero when dry", dry_w < 1e-6)
	var full := SiphonHydraulics.omega_from_pe_w(SiphonHydraulics.PE_AT_RATED_W)
	_check("omega at PE rated", absf(full - SiphonHydraulics.OMEGA_AT_RATED) < 0.1)
	var named := SiphonHydraulics.omega_from_power_w(250.0, 250.0)
	_check("omega_from_power_w at nameplate", absf(named - SiphonHydraulics.OMEGA_AT_RATED) < 0.1)


func _test_modal_script_compiles() -> void:
	var scr: GDScript = load("res://scenes/ui/siphon_hydro_modal.gd") as GDScript
	_check("siphon_hydro_modal.gd loads", scr != null)
	if scr == null:
		return
	var inst = scr.new()
	_check("siphon_hydro_modal instantiates", inst != null)
	_check("modal has enter_as_view", inst != null and inst.has_method("enter_as_view"))
	_check("modal has close", inst != null and inst.has_method("close"))
	if inst is Node:
		(inst as Node).free()
	var spin_scr: GDScript = load("res://gameplay/siphon_turbine_spin.gd") as GDScript
	_check("siphon_turbine_spin.gd loads", spin_scr != null)


func _test_direct_intake_visibility() -> void:
	_check("direct_intake conn hidden in 3d",
			not ConduitKinds.resolve_visible_3d({
				"direct_intake": true, "conduit_type": "garden_hose"}, true))
	_check("direct_intake force visible wins",
			ConduitKinds.resolve_visible_3d({
				"direct_intake": true, "visible_3d": true}, false))
	_check("bind-style visible_3d false",
			not ConduitKinds.resolve_visible_3d({"visible_3d": false}, true))


func _test_elevation_cross_section_drawer() -> void:
	var scr: GDScript = load("res://system_graph/elevation_cross_section.gd") as GDScript
	_check("elevation_cross_section.gd loads", scr != null)
	# Early-return paths only (draw_* needs a live _draw context).
	var dummy := Control.new()
	ElevationCrossSection.draw_terrain(dummy, PackedVector2Array(), Vector2.ZERO, Vector2.ONE)
	ElevationCrossSection.draw_outflow_streaks(dummy, Vector2.ZERO, Vector2(10, 0), 0.0, false, 0.0)
	_check("drawer early-return smoke ok", true)
	dummy.free()


func _test_elevation_profile_bake() -> void:
	var n_lo := ElevationProfile.sample_count_for_r_px(40.0)
	var n_hi := ElevationProfile.sample_count_for_r_px(8000.0)
	_check("profile samples floor", n_lo == ElevationProfile.MIN_SAMPLES)
	_check("profile samples cap", n_hi == ElevationProfile.MAX_SAMPLES)
	var along := PackedFloat32Array()
	var elev := PackedFloat32Array()
	ElevationProfile.bake(null, Vector3(0, 100, 0), 0.0, 0.0, 50.0, 48, along, elev)
	_check("bake length", along.size() == 49 and elev.size() == 49)
	_check("bake datum fallback", elev.size() > 0 and absf(elev[0] - 100.0) < 1e-3)
	var along2 := PackedFloat32Array()
	var elev2 := PackedFloat32Array()
	ElevationProfile.bake_window(null, Vector3(0, 50, 0), 0.5, 0.0, -10.0, 20.0, 32,
			along2, elev2)
	_check("window bake endpoints", along2.size() == 33 \
			and absf(along2[0] + 10.0) < 1e-3 and absf(along2[32] - 20.0) < 1e-3)


## Engine wiring: an explicit-time step (step_at) advances stock / outlet /
## culvert live_q. Production drives the same path off the world clock via tick().
func _test_lab_engine_step() -> void:
	const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
	const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")
	var model = GraphModelScript.new()
	model.add_item({
		"id": "pond", "type": "resource", "x": 0.0, "y": 0.0,
		"width": 80.0, "height": 80.0,
		"specs": {
			"name": "Test Pond", "resource_kind": "water",
			"pond_storage": true, "fill_mode": "auto",
			"capacity_qty": 10000.0, "capacity_unit": "L",
			"level": 0.10, "stock_l": 1000.0,
			"floor_m": 100.0, "rim_m": 101.0, "level_m": 100.10,
		},
	})
	model.add_item({
		"id": "siphon", "type": "processor", "x": 120.0, "y": 0.0,
		"width": 150.0, "height": 130.0,
		"elevation_m": 100.0,
		"specs": {
			"name": "Siphon", "role": "siphon_hydro", "kind": "siphon_hydro",
			"energy_source": "", "efficiency": 1.0,
			"intake_diameter_mm": 203.0, "outlet_diameter_mm": 203.0,
			"barrel_length_m": 20.0, "manning_n": 0.012,
			"max_power_w": 250.0, "hydraulic_efficiency": 0.6,
			"generator_efficiency": 0.7,
			"siphon_start_m": 100.15, "siphon_break_m": 100.0,
			"module_elev_m": 100.0, "outlet_invert_m": 91.0,
			"siphon_primed": false, "live_q_lps": 0.0,
			"lab_sim_inflow_enabled": true, "lab_sim_inflow_lps": 0.5,
			"inputs": [{"kind": "water", "rate": 0.0, "unit": "L/h"}],
			"outputs": [
				{"kind": "water", "rate": 0.0, "unit": "L/h"},
				{"kind": "dc_electricity", "rate": 0.0, "unit": "kW"},
			],
		},
	})
	model.add_item({
		"id": "outlet", "type": "resource", "x": 280.0, "y": 0.0,
		"width": 72.0, "height": 72.0,
		"specs": {
			"name": "Culvert Outlet", "resource_kind": "water",
			"capacity_qty": 1.0e12, "capacity_unit": "L", "level": 0.0,
			"unlimited_capacity": true, "outlet_sink": true,
			"cumulative_l": 0.0, "live_in_lps": 0.0, "stock_l": 0.0,
		},
	})
	model.add_connection({
		"polarity": "resource", "resource_type": "water",
		"source_item_id": "pond", "source_handle_id": "output",
		"target_item_id": "siphon", "target_handle_id": "res_in_0",
		"conduit_type": "garden_hose", "direct_intake": true,
	})
	model.add_connection({
		"polarity": "resource", "resource_type": "water",
		"source_item_id": "siphon", "source_handle_id": "res_out_0",
		"target_item_id": "outlet", "target_handle_id": "input",
		"conduit_type": "culvert_pipe",
		"invert_in_m": 99.8, "invert_out_m": 91.0,
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	_check("step_at exists", engine.has_method("step_at"))
	var level0 := float(model.get_item("pond").get("specs", {}).get("level", 0.0))
	# One minute of 0.5 L/s → 30 L into 10 kL (+0.003 level).
	engine.step_at(1.0 / 60.0, 1.0 / 60.0)
	var pond_specs: Dictionary = model.get_item("pond").get("specs", {}) as Dictionary
	var level1 := float(pond_specs.get("level", 0.0))
	_check("lab sim inflow raises pond level", level1 > level0 + 0.002,
			"level0=%.4f level1=%.4f" % [level0, level1])
	# Prime: raise pond above start and run a flowing lab step.
	pond_specs = pond_specs.duplicate(true)
	pond_specs["level"] = 0.55
	pond_specs["level_m"] = 100.55
	pond_specs["stock_l"] = 5500.0
	model.update_item("pond", {"specs": pond_specs})
	var siphon_specs: Dictionary = (model.get_item("siphon").get("specs", {}) as Dictionary).duplicate(true)
	siphon_specs["lab_sim_inflow_enabled"] = false
	siphon_specs["siphon_primed"] = false
	model.update_item("siphon", {"specs": siphon_specs})
	# Fresh engine so timelines anchor at t0 (host-less reanchor uses -1).
	engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	engine.step_at(1.0 / 60.0, 1.0 / 60.0)
	siphon_specs = model.get_item("siphon").get("specs", {}) as Dictionary
	_check("lab step stamps siphon live_q", float(siphon_specs.get("live_q_lps", 0.0)) > 0.05,
			"q=%.3f" % float(siphon_specs.get("live_q_lps", 0.0)))
	var out_specs: Dictionary = model.get_item("outlet").get("specs", {}) as Dictionary
	_check("lab step credits outlet cumulative_l",
			float(out_specs.get("cumulative_l", 0.0)) > 1.0,
			"cum=%.2f" % float(out_specs.get("cumulative_l", 0.0)))
	var culvert_q := 0.0
	for conn: Dictionary in model.connections:
		if str(conn.get("conduit_type", "")) == "culvert_pipe":
			culvert_q = float(conn.get("live_q_lps", 0.0))
	_check("lab step stamps culvert live_q_lps", culvert_q > 0.05,
			"culvert_q=%.3f" % culvert_q)


func _test_outlet_sink_format() -> void:
	var specs := {
		"outlet_sink": true,
		"cumulative_l": 1234.5,
		"live_in_lps": 2.5,
		"capacity_unit": "L",
		"resource_kind": "water",
		"level": 0.0,
		"unlimited_capacity": true,
		"capacity_qty": 1.0e12,
	}
	var stock := ResourceKinds.tank_stock_qty(specs)
	_check("outlet_sink stock uses cumulative", absf(stock - 1234.5) < 0.01,
			"stock=%.2f" % stock)
	var fmt := ResourceKinds.format_tank_stock(specs)
	_check("outlet_sink format mentions L/s", fmt.contains("L/s") or fmt.contains("out"),
			"fmt=%s" % fmt)


func _test_contiguous_wet_interval() -> void:
	# Two pits separated by a berm; pond sits in the left pit.
	const GraphCanvasScript := preload("res://system_graph/graph_canvas.gd")
	var alongs := PackedFloat32Array([-10, -8, -6, -4, -2, 0, 2, 4, 6, 8, 10])
	var elevs := PackedFloat32Array([5, 3, 2, 3, 5, 6, 5, 3, 2, 3, 5])
	var wet: Vector2 = GraphCanvasScript.elev_contiguous_wet_interval(
			alongs, elevs, 4.0, -6.0, 8.0)
	_check("wet run stays in left pit", wet.x > -11.0 and wet.y < 0.5,
			"wet=%s" % wet)
	_check("wet run excludes right pit", wet.y < 2.0, "wet_max=%.2f" % wet.y)


func _test_eight_inch_orifice() -> void:
	# 8″ orifice under ~9 m head should move more than a garden hose, less than flood.
	var r := SiphonHydraulics.simulate(100.40, 100.0, 100.203, 91.0, 0.203, 0.203,
			20.0, 0.012, true, 250.0, 0.6, 0.7)
	var q := float(r.get("q_lps", 0.0))
	_check("8in orifice flows", q > 5.0, "Q=%.2f" % q)
	_check("8in orifice not absurd", q < 500.0, "Q=%.2f" % q)
	_check("power still capped", float(r.get("power_w", 999.0)) <= 250.01)


func _test_start_break_follow_module() -> void:
	# Offsets stay fixed; absolutes track module elev (3D prop move).
	var specs := {
		"module_elev_m": 100.0,
		"siphon_break_offset_m": -0.4,
		"siphon_start_offset_m": -0.2,
		"intake_diameter_mm": 203.0,
	}
	var a := SiphonHydraulics.resolve_siphon_levels(specs, 100.0)
	_check("resolve start @100", absf(float(a.get("siphon_start_m", 0.0)) - 99.8) < 1e-4,
			"start=%.3f" % float(a.get("siphon_start_m", 0.0)))
	_check("resolve break @100", absf(float(a.get("siphon_break_m", 0.0)) - 99.6) < 1e-4,
			"break=%.3f" % float(a.get("siphon_break_m", 0.0)))
	var b := SiphonHydraulics.resolve_siphon_levels(specs, 102.5)
	_check("module +2.5 → start +2.5",
			absf(float(b.get("siphon_start_m", 0.0)) - 102.3) < 1e-4,
			"start=%.3f" % float(b.get("siphon_start_m", 0.0)))
	_check("module +2.5 → break +2.5",
			absf(float(b.get("siphon_break_m", 0.0)) - 102.1) < 1e-4,
			"break=%.3f" % float(b.get("siphon_break_m", 0.0)))
	# Legacy absolute migrate → offsets once module is known.
	var legacy := {
		"module_elev_m": 50.0,
		"siphon_start_m": 50.2,
		"siphon_break_m": 49.8,
		"outlet_invert_m": 41.0,
		"intake_diameter_mm": 150.0,
	}
	var m := SiphonHydraulics.resolve_siphon_levels(legacy, 50.0)
	_check("migrate start offset",
			absf(float(m.get("siphon_start_offset_m", 0.0)) - 0.2) < 1e-4)
	_check("migrate break offset",
			absf(float(m.get("siphon_break_offset_m", 0.0)) - (-0.2)) < 1e-4)
	SiphonHydraulics.apply_resolved_levels(legacy, 51.0)
	_check("apply stamps start after move",
			absf(float(legacy.get("siphon_start_m", 0.0)) - 51.2) < 1e-4,
			"start=%.3f" % float(legacy.get("siphon_start_m", 0.0)))
	# Prime/break still trip on pond level vs resolved absolutes.
	var primed := SiphonHydraulics.simulate_from_specs(51.25, legacy)
	_check("prime at resolved start", bool(primed.get("primed", false)))
	legacy["siphon_primed"] = true
	var held := SiphonHydraulics.simulate_from_specs(51.0, legacy)
	_check("latched mid-band after module move", bool(held.get("primed", false)))
	var broken := SiphonHydraulics.simulate_from_specs(50.7, legacy)
	_check("break below resolved break", not bool(broken.get("primed", true)))


func _test_lab_dt_no_flood() -> void:
	const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
	const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")
	var model = GraphModelScript.new()
	model.add_item({
		"id": "pond", "type": "resource", "x": 0.0, "y": 0.0,
		"width": 80.0, "height": 80.0,
		"specs": {
			"name": "Pond", "resource_kind": "water", "pond_storage": true,
			"capacity_qty": 10000.0, "level": 0.5, "stock_l": 5000.0,
			"floor_m": 100.0, "rim_m": 101.0, "level_m": 100.5, "fill_mode": "auto",
		},
	})
	model.add_item({
		"id": "siphon", "type": "processor", "x": 100.0, "y": 0.0,
		"width": 100.0, "height": 100.0,
		"specs": {
			"role": "siphon_hydro",
			"lab_sim_inflow_enabled": true, "lab_sim_inflow_lps": 0.5,
			"siphon_start_m": 100.9, "siphon_break_m": 100.0,
			"module_elev_m": 100.0, "outlet_invert_m": 91.0,
			"intake_diameter_mm": 203.0, "outlet_diameter_mm": 203.0,
			"barrel_length_m": 20.0, "manning_n": 0.012,
			"max_power_w": 250.0, "hydraulic_efficiency": 0.6,
			"generator_efficiency": 0.7,
			"inputs": [{"kind": "water", "rate": 0.0}],
			"outputs": [{"kind": "water", "rate": 0.0}],
		},
	})
	model.add_connection({
		"polarity": "resource", "resource_type": "water",
		"source_item_id": "pond", "source_handle_id": "output",
		"target_item_id": "siphon", "target_handle_id": "res_in_0",
	})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	# 60 one-second steps of 0.5 L/s test inflow = 30 L into a 10 kL pond.
	var frame_dt_h := 1.0 / 3600.0  # 1 sim-second per step
	var t := 0.0
	for _i in 60:
		t += frame_dt_h
		engine.step_at(t, frame_dt_h)
	var specs: Dictionary = model.get_item("pond").get("specs", {}) as Dictionary
	# Overflow is honest now (no Lab suppression) — a tiny inflow simply can't fill it.
	_check("small test inflow does not overflow", not bool(specs.get("overflowing", false)))
	var lvl := float(specs.get("level", 1.0))
	# 0.5 L/s × 60 s = 30 L → +0.003 on 10 kL — nowhere near full.
	_check("small dt does not flood 10kL pond", lvl < 0.55,
			"level=%.4f" % lvl)


## Round 2 / Phase F: the PowerSpout PLT model is registered as a hydro turbine,
## names its runner node + spin axis, ships default connection ports (a turbine
## used to have NONE until the player authored them, so there was nothing to
## attach a penstock to), and the kind→model mapping is complete. Geometry
## assertions are skipped when the gitignored GLB is absent (fresh clone).
func _test_powerspout_model() -> void:
	_check("powerspout entry exists",
		not ModelCatalog.find("powerspout_plt").is_empty())
	_check("powerspout is a hydro turbine",
		ModelCatalog.is_hydro_turbine("powerspout_plt"))
	_check("siphon hydroturbine still a hydro turbine",
		ModelCatalog.is_hydro_turbine("hydroturbine"))
	_check("non-hydro model is not", not ModelCatalog.is_hydro_turbine("vawt"))
	_check("powerspout names its runner node",
		ModelCatalog.turbine_node_for("powerspout_plt") == "Pelton Wheel, 24 Spoon")
	_check("powerspout declares its X spin axis",
		ModelCatalog.spin_axis_for("powerspout_plt") == "x")
	_check("siphon turbine keeps the default (+Z) axis",
		ModelCatalog.spin_axis_for("hydroturbine").is_empty())
	# Every turbine kind names the 3D model it wears.
	for k: String in HydroSource.KINDS.keys():
		var mid := str((HydroSource.KINDS[k] as Dictionary).get("model_id", ""))
		_check("kind '%s' names a real model" % k,
			not mid.is_empty() and not ModelCatalog.find(mid).is_empty(), mid)
	_check("powerspout kind wears the powerspout model",
		str(HydroSource.kind_meta("powerspout_pelton").get("model_id", "")) == "powerspout_plt")
	# Default ports: a penstock inlet that advertises poly tubing, a tailrace,
	# and the DC pair matching the preset's res_out_1 dc_electricity port.
	var ports := ConnectionPortDefs.default_ports_for_model("powerspout_plt")
	_check("powerspout ships 4 default ports", ports.size() == 4, str(ports.size()))
	var by_handle: Dictionary = {}
	for p_v in ports:
		by_handle[str((p_v as Dictionary).get("handle_id", ""))] = p_v
	_check("penstock inlet on res_in_0", by_handle.has("res_in_0"))
	_check("tailrace on res_out_0", by_handle.has("res_out_0"))
	_check("DC pair on res_out_1_pos/neg",
		by_handle.has("res_out_1_pos") and by_handle.has("res_out_1_neg"))
	if by_handle.has("res_in_0"):
		var inlet: Dictionary = by_handle["res_in_0"]
		_check("inlet prefers poly penstock",
			str(inlet.get("preferred_conduit_type", "")) == "poly_penstock")
		_check("inlet carries the water kind",
			str(inlet.get("resource_kind", "")) == "water")
	# Ports must sit ON the machine, not scattered by the generic 1.0/1.2 dims
	# fallback — this GLB is only ~0.35 x 0.38 x 0.59 m.
	if ResourceLoader.exists(str(ModelCatalog.find("powerspout_plt").get("path", ""))):
		var m := ModelCatalog.mesh_metrics("powerspout_plt")
		var half := maxf(maxf(float(m.get("width", 1.0)), float(m.get("depth", 1.0))), 0.2)
		var top := float(m.get("foot_local_y", 0.0)) + float(m.get("unit_height", 1.0))
		for p2_v in ports:
			var p2: Dictionary = p2_v
			var pos := Vector3(float(p2.get("x", 0.0)), float(p2.get("y", 0.0)),
					float(p2.get("z", 0.0)))
			_check("port '%s' within the body footprint" % str(p2.get("id", "")),
				absf(pos.x) <= half and absf(pos.z) <= half,
				"%.3f,%.3f (half %.3f)" % [pos.x, pos.z, half])
			_check("port '%s' between foot and top" % str(p2.get("id", "")),
				pos.y >= float(m.get("foot_local_y", 0.0)) - 0.05 and pos.y <= top + 0.05,
				"%.3f" % pos.y)


## Phase F: the runner actually turns, about the RIGHT axis. Builds the real
## model under a ModelRoot, binds SiphonTurbineSpin, and checks the resolved
## axis + that a published live_rpm produces rotation about it. A wrong axis
## renders as the wheel tumbling end-over-end, which no static screenshot
## catches — hence a mechanical check. Skipped when the gitignored GLB is
## absent (fresh clone).
func _test_powerspout_spin() -> void:
	var path := str(ModelCatalog.find("powerspout_plt").get("path", ""))
	if not ResourceLoader.exists(path):
		print("  (skip powerspout spin — GLB not installed)")
		return
	var host := Node3D.new()
	var model_root := Node3D.new()
	model_root.name = "ModelRoot"
	host.add_child(model_root)
	var inst := ModelCatalog.instantiate("powerspout_plt")
	_check("powerspout instantiates", inst != null)
	if inst == null:
		host.free()
		return
	model_root.add_child(inst)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)

	# Declared axis ("x").
	var spin := SiphonTurbineSpin.new()
	spin.configure("", ModelCatalog.turbine_node_for("powerspout_plt"),
			ModelCatalog.spin_axis_for("powerspout_plt"))
	host.add_child(spin)
	spin.call("_bind_turbine")
	_check("spin bound to the runner", bool(spin.get("_ready_ok")))
	var axis: Vector3 = spin.get("_axis_p")
	_check("declared axis resolves to model X",
		absf(axis.x) > 0.95 and absf(axis.y) < 0.2 and absf(axis.z) < 0.2, str(axis))

	# With NO hint the geometric fallback must find the same axis — that is what
	# keeps a re-export (or a future hydro model) working without a hand-written
	# spin_axis key.
	var spin2 := SiphonTurbineSpin.new()
	spin2.configure("", ModelCatalog.turbine_node_for("powerspout_plt"), "")
	host.add_child(spin2)
	spin2.call("_bind_turbine")
	var axis2: Vector3 = spin2.get("_axis_p")
	_check("measured axis agrees with the declared one",
		axis2.normalized().dot(axis.normalized()) > 0.98 \
			or axis2.normalized().dot(-axis.normalized()) > 0.98, str(axis2))

	# Rotation: drive the target directly and step _process; the runner's
	# transform must change, and about the resolved axis (its basis Z, which is
	# perpendicular to an X axis, must swing).
	var runner: Node3D = spin.get("_turbine")
	_check("runner node resolved", runner != null)
	if runner != null:
		var before := runner.transform
		spin.set("_target_omega", 40.0)
		spin.set("_omega", 40.0)
		spin.set("_parked", false)
		for i in 6:
			spin.call("_process", 0.05)
		var after := runner.transform
		_check("runner rotated", not after.is_equal_approx(before))
		# Probe with a basis column PERPENDICULAR to the spin axis — the runner's
		# own local Z IS its shaft direction here, so it is invariant under the
		# rotation and would read as "didn't move".
		var ax := axis.normalized()
		var probe := before.basis.x.normalized()
		if absf(probe.dot(ax)) > 0.5:
			probe = before.basis.y.normalized()
		var probe_after := (after.basis * (before.basis.inverse() * probe)).normalized()
		var swing := probe.angle_to(probe_after)
		_check("rotation is about the resolved axis (perp vector swung)",
			swing > 0.05, "%.4f rad" % swing)
		var moved_along_axis := absf((after.origin - before.origin).dot(axis.normalized()))
		_check("runner did not translate along its own axis",
			moved_along_axis < 0.01, "%.4f" % moved_along_axis)

	tree.root.remove_child(host)
	host.free()
