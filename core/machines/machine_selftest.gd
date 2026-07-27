extends SceneTree

## Offline deterministic self-test for the Cartesian machine + crafting substrate.
## Run with:
##   godot --headless --path . --script core/machines/machine_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise. Run --import first so the new
## class_names register.

const ToolpathScript := preload("res://core/machines/toolpath.gd")
const StlLoaderScript := preload("res://core/machines/stl_loader.gd")
const ProfileScript := preload("res://core/machines/cartesian_machine_profile.gd")
const SourceScript := preload("res://power_system/sources/cartesian_machine_source.gd")
const InventoryScript := preload("res://core/machines/part_inventory.gd")
const RecipeScript := preload("res://core/machines/recipe_catalog.gd")
const JobStoreScript := preload("res://core/machines/machine_job_store.gd")
const PresetsScript := preload("res://system_graph/data/component_presets.gd")
const DomePartsScript := preload("res://core/machines/dome_parts.gd")
const DomeBuilderScript := preload("res://core/machines/geodesic_dome_builder.gd")
const CutPresetsScript := preload("res://core/machines/cnc_cut_presets.gd")
const MudSpecScript := preload("res://core/machines/mud_building/mud_building_spec.gd")
const MudPlanOpsScript := preload("res://core/machines/mud_building/mud_plan_ops.gd")
const MudSlicerScript := preload("res://core/machines/mud_building/mud_wall_slicer.gd")
const MudMesherScript := preload("res://core/machines/mud_building/mud_wall_mesher.gd")
const MudDialectScript := preload("res://core/machines/mud_building/mud_grbl_dialect.gd")
const MudGrblScript := preload("res://core/machines/mud_building/mud_grbl_export.gd")
const MudStructScript := preload("res://core/machines/mud_building/mud_building_structure_builder.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_gcode()
	_test_decimation()
	_test_stl()
	_test_profile()
	_test_source()
	_test_inventory()
	_test_recipes()
	_test_jobstore()
	_test_presets()
	_test_mud_print()
	_test_trash_and_dome()
	_test_mud_building()
	if _failures == 0:
		print("MACHINE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("MACHINE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _approx(v: float, lo: float, hi: float) -> bool:
	return v >= lo and v <= hi


func _ring_max_abs_x(ring: PackedVector2Array) -> float:
	var m := 0.0
	for p: Vector2 in ring:
		m = maxf(m, absf(p.x))
	return m


func _test_gcode() -> void:
	var gcode := "G21\nG90\nG1 X0 Y0 Z0 F600\nG1 X10 Y0 E5 ; extrude\nG1 X10 Y10 E10\nG0 X0 Y10\n"
	var r := ToolpathScript.parse_gcode(gcode)
	_check("gcode ok", bool(r.get("ok", false)), str(r))
	_check("gcode points>=3", int(r.get("point_count", 0)) >= 3, str(r.get("point_count")))
	var bmax: Vector3 = r.get("bounds_max", Vector3.ZERO)
	_check("gcode bounds x", _approx(bmax.x, 9.9, 10.1), str(bmax))
	_check("gcode bounds y", _approx(bmax.y, 9.9, 10.1), str(bmax))
	_check("gcode extrusion ~10", _approx(float(r.get("extrusion_mm", 0.0)), 9.9, 10.1),
		str(r.get("extrusion_mm")))
	_check("gcode time>0", float(r.get("est_time_hr", 0.0)) > 0.0, str(r.get("est_time_hr")))
	# G20 inch units: X1 -> 25.4 mm.
	var r2 := ToolpathScript.parse_gcode("G20\nG90\nG1 X0 Y0 F100\nG1 X1 Y0\n")
	var b2: Vector3 = r2.get("bounds_max", Vector3.ZERO)
	_check("gcode inch units", _approx(b2.x, 25.3, 25.5), str(b2))


func _test_decimation() -> void:
	var pts := PackedVector3Array()
	var ext := PackedInt32Array()
	for i in 5000:
		pts.append(Vector3(float(i), float(i % 2) * 5.0, 0.0))
		ext.append(1)
	var dec := ToolpathScript.decimate(pts, ext, ToolpathScript.MAX_SEGMENTS)
	var out: PackedVector3Array = dec.get("points", PackedVector3Array())
	_check("decimate cap", out.size() <= ToolpathScript.MAX_SEGMENTS + 1, str(out.size()))
	_check("decimate keeps start", out[0].distance_to(pts[0]) < 0.001, str(out[0]))
	_check("decimate keeps end", out[out.size() - 1].distance_to(pts[pts.size() - 1]) < 2.0,
		"%s vs %s" % [out[out.size() - 1], pts[pts.size() - 1]])


func _test_stl() -> void:
	var bytes := _make_binary_cube_stl(1.0)
	var r := StlLoaderScript.parse_bytes(bytes)
	_check("stl ok", bool(r.get("ok", false)), str(r))
	_check("stl triangles", int(r.get("triangles", 0)) == 12, str(r.get("triangles")))
	_check("stl volume ~1", _approx(float(r.get("volume_mm3", 0.0)), 0.9, 1.1),
		str(r.get("volume_mm3")))
	var bmax: Vector3 = r.get("bounds_max", Vector3.ZERO)
	_check("stl bbox", _approx(bmax.x, 0.99, 1.01) and _approx(bmax.z, 0.99, 1.01), str(bmax))
	_check("stl scan path", int(r.get("point_count", 0)) > 0, str(r.get("point_count")))


func _test_profile() -> void:
	var trash := ProfileScript.default_for("trash_printer")
	_check("trash profile z bed", trash.axis_node("z").to_lower().contains("bed"),
		trash.axis_node("z"))
	_check("trash profile invert z", bool((trash.axes.get("z", {}) as Dictionary).get("invert", false)))
	trash.set_axis_limits("x", "X Assembly", Vector3(1, 0, 0), -2.0, 8.0, 0.0, false)
	_check("profile min", _approx(trash.axis_min_local("x"), -2.01, -1.99),
		str(trash.axis_min_local("x")))
	_check("profile max", _approx(trash.axis_max_local("x"), 7.99, 8.01),
		str(trash.axis_max_local("x")))
	_check("profile home", _approx(trash.axis_home_local("x"), -0.01, 0.01),
		str(trash.axis_home_local("x")))
	_check("profile travel = max-min",
		_approx(trash.axis_travel_local("x"), 9.99, 10.01),
		str(trash.axis_travel_local("x")))
	# Legacy travel-only → min=0, max=travel.
	trash.set_axis("y", "Y Axis", Vector3(0, 0, 1), 5.0, false)
	_check("legacy travel min0", _approx(trash.axis_min_local("y"), -0.01, 0.01))
	_check("legacy travel max", _approx(trash.axis_max_local("y"), 4.99, 5.01))
	var d := trash.to_dict()
	var axes_d: Dictionary = d.get("axes", {})
	var xd: Dictionary = axes_d.get("x", {})
	_check("to_dict has home", xd.has("home_local"))
	_check("to_dict has min", xd.has("min_local"))

	var p := ProfileScript.default_for("cnc_router")
	_check("profile configured", p.is_configured(), str(p.to_dict()))
	_check("profile x node", p.axis_node("x") == "X Axis", p.axis_node("x"))
	# Round-trip through dict.
	var q := ProfileScript.new()
	q.model_id = "cnc_router"
	q._apply_raw(p.to_dict())
	_check("profile round-trip x", q.axis_node("x") == p.axis_node("x"), q.axis_node("x"))
	_check("profile round-trip z node", q.axis_node("z") == "Z Axis", q.axis_node("z"))
	# Inverted axis flips sign.
	var pr := ProfileScript.default_for("trash_printer")
	_check("printer z inverted", pr.axis_dir("z").y < 0.0, str(pr.axis_dir("z")))
	# Auto-detect on a synthetic tree.
	var root := Node3D.new()
	for nm in ["Frame", "X Axis", "Y axis", "Z Axis"]:
		var c := Node3D.new()
		c.name = nm
		root.add_child(c)
	var det := ProfileScript.auto_detect_axes(root)
	_check("autodetect x", str(det.get("x", "")) == "X Axis", str(det))
	_check("autodetect y", str(det.get("y", "")) == "Y axis", str(det))
	_check("autodetect z", str(det.get("z", "")) == "Z Axis", str(det))
	root.free()


func _test_source() -> void:
	var specs := {
		"machine_role": "fdm_printer", "speed_factor": 1.0, "watts": 900.0,
		"filament_diameter_mm": 3.0, "flake_density_g_cm3": 0.95,
		"inputs": [{"kind": "plastic_flake", "rate": 0.0}],
	}
	var parse := {"est_time_hr": 2.0, "extrusion_mm": 1000.0, "kind": "gcode",
		"bounds_min": Vector3.ZERO, "bounds_max": Vector3(50, 50, 50)}
	var job := SourceScript.derive_job(parse, specs)
	_check("source duration", _approx(float(job.get("duration_hr", 0.0)), 1.99, 2.01),
		str(job.get("duration_hr")))
	_check("source material kind", str(job.get("material_kind", "")) == "plastic_flake",
		str(job.get("material_kind")))
	# vol = 1000 * pi*1.5^2 = 7068.6 mm3 -> 7.0686 cm3 * 0.95 g/cm3 = 6.715 g = 0.006715 kg
	_check("source material qty", _approx(float(job.get("material_qty", 0.0)), 0.0060, 0.0075),
		str(job.get("material_qty")))
	_check("source energy", _approx(float(job.get("energy_kwh", 0.0)), 1.7, 1.9),
		str(job.get("energy_kwh")))
	# Speed factor halves duration.
	specs["speed_factor"] = 2.0
	var job2 := SourceScript.derive_job(parse, specs)
	_check("source speed factor", _approx(float(job2.get("duration_hr", 0.0)), 0.99, 1.01),
		str(job2.get("duration_hr")))
	# Scrub-safe progress.
	var jspecs := {"job_active": true, "job_start_abs_hours": 100.0, "job_duration_hr": 2.0}
	_check("progress mid", _approx(SourceScript.progress_at(jspecs, 101.0), 0.49, 0.51))
	_check("progress clamp", SourceScript.progress_at(jspecs, 105.0) == 1.0)
	_check("progress start", SourceScript.progress_at(jspecs, 100.0) == 0.0)
	var mrate := SourceScript.material_rate_per_hr({"job_material_qty": 4.0, "job_duration_hr": 2.0})
	_check("material rate", _approx(mrate, 1.99, 2.01), str(mrate))


func _test_inventory() -> void:
	var inv := InventoryScript.create_empty()
	inv.add_part("dome_hub_4way", 10, {"label": "4-way Dome Hub", "material_kind": "plastic_flake"})
	inv.add_part("dome_hub_4way", 5)
	_check("inv count", inv.count("dome_hub_4way") == 15, str(inv.count("dome_hub_4way")))
	_check("inv has", inv.has_part("dome_hub_4way", 15))
	_check("inv remove ok", inv.remove_part("dome_hub_4way", 5))
	_check("inv count after remove", inv.count("dome_hub_4way") == 10)
	_check("inv remove too many", not inv.remove_part("dome_hub_4way", 100))
	_check("inv label", inv.label_for("dome_hub_4way") == "4-way Dome Hub")
	var data := inv.serialize()
	var inv2 := InventoryScript.create_empty()
	inv2.deserialize(data)
	_check("inv round-trip", inv2.count("dome_hub_4way") == 10, str(inv2.count("dome_hub_4way")))


func _test_recipes() -> void:
	var inv := InventoryScript.create_empty()
	_check("recipe not craftable empty", not RecipeScript.can_craft(inv, "geodesic_dome"))
	var miss := RecipeScript.missing(inv, "geodesic_dome")
	_check("recipe missing 4way", int(miss.get("dome_hub_4way", 0)) == 10, str(miss))
	_check("recipe missing 5way", int(miss.get("dome_hub_5way", 0)) == 6, str(miss))
	_check("recipe missing 6way", int(miss.get("dome_hub_6way", 0)) == 10, str(miss))
	_check("recipe missing A", int(miss.get("dome_strut_a", 0)) == 35, str(miss))
	_check("recipe missing B", int(miss.get("dome_strut_b", 0)) == 30, str(miss))
	inv.add_part("dome_hub_4way", 10)
	inv.add_part("dome_hub_5way", 6)
	inv.add_part("dome_hub_6way", 10)
	inv.add_part("dome_strut_a", 35)
	inv.add_part("dome_strut_b", 30)
	_check("recipe craftable", RecipeScript.can_craft(inv, "geodesic_dome"))
	_check("recipe spend ok", RecipeScript.spend(inv, "geodesic_dome"))
	_check("recipe consumed 4way", inv.count("dome_hub_4way") == 0, str(inv.count("dome_hub_4way")))
	_check("recipe consumed A", inv.count("dome_strut_a") == 0, str(inv.count("dome_strut_a")))
	_check("recipe not craftable after", not RecipeScript.can_craft(inv, "geodesic_dome"))


func _test_trash_and_dome() -> void:
	# Trash printer preset: inventory credit, no map persist, FDM role.
	var found_trash := false
	for p: Dictionary in PresetsScript.TOOLS:
		var specs: Dictionary = p.get("specs", {})
		if str(specs.get("model_id", "")) == "trash_printer":
			found_trash = true
			_check("trash kind", str(specs.get("machine_kind", "")) == "trash")
			_check("trash no persist", not bool(specs.get("print_persist", true)))
			_check("trash bed lowering", bool(specs.get("bed_lowering", false)))
			_check("trash bed 600", int(specs.get("work_x_mm", 0)) == 600, str(specs.get("work_x_mm")))
			_check("trash nozzle ~6", _approx(float(specs.get("filament_diameter_mm", 0.0)), 5.5, 6.5),
				str(specs.get("filament_diameter_mm")))
			_check("trash layer ~0.8", _approx(float(specs.get("layer_height_mm", 0.0)), 0.7, 0.9),
				str(specs.get("layer_height_mm")))
	_check("trash preset present", found_trash)

	# Shared FDM caps: trash ranges + mud design flag.
	var CapsScript = load("res://core/machines/fdm_printer_caps.gd")
	var trash_caps = CapsScript.from_specs({
		"model_id": "trash_printer", "machine_kind": "trash",
		"filament_diameter_mm": 6.0, "work_x_mm": 600.0,
	})
	_check("fdm caps trash bed", trash_caps.is_bed_lowering())
	_check("fdm caps trash presets", trash_caps.show_part_presets)
	# Bed-lowering kinematics: a ~0.5" (12.7 mm) part must map to a small local
	# Z drop (height / metres_per_local), NOT the full soft-rail stroke.
	var height_m := 0.0127
	var mpl := 0.0254  # 1 local unit = 1 inch (typical SketchUp trash GLB)
	var soft_span := 24.0  # 24" of soft Z travel
	var needed := height_m / mpl
	_check("trash z drop ~0.5 local in", _approx(needed, 0.49, 0.51), str(needed))
	_check("trash z drop << soft span", needed < soft_span * 0.1,
		"needed=%.3f soft=%.1f" % [needed, soft_span])
	var span_xy_m := 0.08  # 80 mm part
	var needed_xy := span_xy_m / mpl
	_check("trash xy travel ~part", _approx(needed_xy, 3.0, 3.3), str(needed_xy))
	_check("trash xy << soft 600mm", needed_xy < (0.6 / mpl) * 0.5,
		str(needed_xy))
	_check("fdm caps trash layer band",
		trash_caps.layer_lo <= 0.3 and trash_caps.layer_hi >= 1.5,
		"lo=%.2f hi=%.2f" % [trash_caps.layer_lo, trash_caps.layer_hi])
	_check("fdm caps trash layer suggest",
		_approx(trash_caps.suggested_layer_for_nozzle(6.0), 0.6, 1.0),
		str(trash_caps.suggested_layer_for_nozzle(6.0)))
	var mud_caps = CapsScript.from_specs({
		"model_id": "mud_printer", "machine_kind": "mud", "print_persist": true,
	})
	_check("fdm caps mud design", mud_caps.show_design_building)
	_check("fdm caps mud fixed bed", not mud_caps.is_bed_lowering())

	# Dome part STLs + print presets.
	var presets: Array = DomePartsScript.print_presets()
	_check("dome presets count", presets.size() == 5, str(presets.size()))
	for p2: Dictionary in presets:
		var path := str(p2.get("stl_path", ""))
		_check("stl exists %s" % str(p2.get("part_id", "?")), FileAccess.file_exists(path), path)
		var mesh: ArrayMesh = StlLoaderScript.build_mesh(path)
		_check("stl mesh %s" % str(p2.get("part_id", "?")), mesh != null and mesh.get_surface_count() > 0)

	_check("standable radius", DomePartsScript.TARGET_RADIUS_M >= 2.0,
		str(DomePartsScript.TARGET_RADIUS_M))
	_check("A strut length", _approx(DomePartsScript.strut_a_length_m(), 1.47, 1.50),
		str(DomePartsScript.strut_a_length_m()))
	_check("B strut length", _approx(DomePartsScript.strut_b_length_m(), 1.30, 1.32),
		str(DomePartsScript.strut_b_length_m()))

	var counts: Dictionary = DomeBuilderScript.geometry_counts()
	_check("dome hub total", int(counts.get("hubs", 0)) == 26, str(counts))
	_check("dome hub4", int(counts.get("hub4", 0)) == 10, str(counts))
	_check("dome hub5", int(counts.get("hub5", 0)) == 6, str(counts))
	_check("dome hub6", int(counts.get("hub6", 0)) == 10, str(counts))
	_check("dome strut total", int(counts.get("struts", 0)) == 65, str(counts))
	_check("dome strut A", int(counts.get("strut_a", 0)) == 35, str(counts))
	_check("dome strut B", int(counts.get("strut_b", 0)) == 30, str(counts))

	var node: Node3D = DomeBuilderScript.build_node({
		"radius_m": DomePartsScript.TARGET_RADIUS_M, "ghost_highlight": true})
	_check("dome node built", node != null)
	if node != null:
		var hubs := node.get_node_or_null("Hubs")
		var struts := node.get_node_or_null("Struts")
		_check("dome hubs child", hubs != null and hubs.get_child_count() == 26,
			str(hubs.get_child_count() if hubs != null else -1))
		_check("dome struts child", struts != null and struts.get_child_count() == 65,
			str(struts.get_child_count() if struts != null else -1))
		node.free()

	# Beam feedstock + CNC cut presets (alternate strut pathway).
	var binv := InventoryScript.create_empty()
	binv.add_part("pp_beam", 3, {"label": "Recycled Plastic Beam"})
	binv.add_part("recycled_plastic_beam_1_50_m", 2, {"label": "Recycled Plastic Beam (1.50 m)"})
	_check("beam feedstock count", binv.count_beam_feedstock() == 5, str(binv.count_beam_feedstock()))
	_check("beam pick prefers pp_beam", binv.pick_beam_feedstock(1) == "pp_beam")
	_check("beam consume", binv.consume_beam_feedstock(1) == "pp_beam")
	_check("beam after consume", binv.count_beam_feedstock() == 4, str(binv.count_beam_feedstock()))
	_check("strut not feedstock", not InventoryScript.is_beam_feedstock("dome_strut_a", "Dome A-Strut (long)"))
	var cuts: Array = CutPresetsScript.all()
	_check("cut presets", cuts.size() >= 2, str(cuts.size()))
	var ca: Dictionary = CutPresetsScript.find("cut_dome_strut_a")
	_check("cut A produces strut", str(ca.get("produce_part_id", "")) == "dome_strut_a")
	_check("cut A stl", FileAccess.file_exists(str(ca.get("stl_path", ""))), str(ca.get("stl_path")))
	var found_beam_ex := false
	for p3: Dictionary in PresetsScript.TOOLS:
		var sp3: Dictionary = p3.get("specs", {})
		if str(sp3.get("model_id", "")) == "pp_beam_extruder":
			found_beam_ex = true
			_check("extruder credits beams", str(sp3.get("job_part_id", "")) == "pp_beam",
				str(sp3.get("job_part_id")))
	_check("beam extruder preset", found_beam_ex)


func _test_mud_building() -> void:
	var spec: MudBuildingSpec = MudSpecScript.new()
	spec.nozzle_mm = 76.2
	spec.line_width_mm = 76.2
	spec.shell_gap_mm = 100.0
	spec.thickness_base_mm = 176.2
	spec.thickness_top_mm = 176.2
	spec.wall_thickness_mm = 176.2
	spec.camber_mode = MudBuildingSpec.CamberMode.NONE
	spec.fill_enabled = false
	spec.layer_height_mm = 50.0
	spec.height_mm = 500.0
	spec.work_x_mm = 3048.0
	spec.work_y_mm = 3048.0
	spec.print_speed_mm_s = 120.0
	spec.loops = [MudSpecScript.make_rect(0.0, 0.0, 1800.0, 1400.0)]
	var val: Dictionary = MudPlanOpsScript.validate_spec(spec)
	_check("mud plan ok", bool(val.get("ok", false)), str(val.get("error", "")))
	_check("mud shell gap", _approx(spec.shell_gap_at(0.0), 99.0, 101.0), str(spec.shell_gap_at(0.0)))
	_check("mud centerline sep", _approx(spec.centerline_sep_at(0.0), 175.0, 177.0),
		str(spec.centerline_sep_at(0.0)))
	var slice: Dictionary = MudSlicerScript.slice(spec)
	_check("mud slice ok", bool(slice.get("ok", false)), str(slice.get("error", "")))
	_check("mud slice points", int(slice.get("point_count", 0)) >= 8, str(slice.get("point_count")))
	_check("mud slice layers", int(slice.get("layer_count", 0)) == 10, str(slice.get("layer_count")))
	_check("mud slice volume", float(slice.get("volume_mm3", 0.0)) > 1.0e6, str(slice.get("volume_mm3")))
	_check("mud slice time", float(slice.get("est_time_hr", 0.0)) > 0.0, str(slice.get("est_time_hr")))
	var bmin: Vector3 = slice.get("bounds_min", Vector3.ZERO)
	var bmax: Vector3 = slice.get("bounds_max", Vector3.ZERO)
	_check("mud bounds z", bmax.z > bmin.z, "%s .. %s" % [bmin, bmax])
	# Dual perimeter: outer larger than plan half-size.
	_check("mud outer extent", bmax.x > 900.0, str(bmax.x))
	var mesh: ArrayMesh = MudMesherScript.build_mesh(spec)
	_check("mud mesh", mesh != null and mesh.get_surface_count() > 0)
	if mesh != null:
		var maabb := mesh.get_aabb()
		_check("mud mesh solid height", maabb.size.y > 0.2, str(maabb.size))
		_check("mud mesh seated", maabb.position.y > -0.05, str(maabb.position))
	# Too-wide shell gap must fail offset.
	var thick: MudBuildingSpec = spec.duplicate_spec()
	thick.shell_gap_mm = 2000.0
	var bad: Dictionary = MudSlicerScript.slice(thick)
	_check("mud thick fail", not bool(bad.get("ok", true)), str(bad))
	# Tiny loop rejected.
	var tiny := MudSpecScript.make_rect(0.0, 0.0, 40.0, 40.0)
	var tv: Dictionary = MudPlanOpsScript.validate_loop(tiny, 76.2, 3048.0, 3048.0)
	_check("mud tiny reject", not bool(tv.get("ok", true)), str(tv))

	# --- Phase 1: seam stagger keeps a valid slice + ~same material volume ---
	var seam0: MudBuildingSpec = spec.duplicate_spec()
	seam0.seam_stagger_frac = 0.0
	var seam1: MudBuildingSpec = spec.duplicate_spec()
	seam1.seam_stagger_frac = 0.2
	var ss0: Dictionary = MudSlicerScript.slice(seam0)
	var ss1: Dictionary = MudSlicerScript.slice(seam1)
	_check("mud seam stagger ok", bool(ss1.get("ok", false)), str(ss1.get("error", "")))
	var v0 := float(ss0.get("volume_mm3", 0.0))
	_check("mud seam stagger vol", _approx(float(ss1.get("volume_mm3", 0.0)),
		v0 * 0.9, v0 * 1.1), "s0=%.0f s1=%.0f" % [v0, ss1.get("volume_mm3")])

	# --- Phase B: camber thickness lerp + OUTER mode extent ---
	_check("mud thickness_at base", _approx(spec.thickness_at(0.0), 175.0, 177.0),
		str(spec.thickness_at(0.0)))
	var camber: MudBuildingSpec = spec.duplicate_spec()
	camber.thickness_base_mm = 200.0
	camber.thickness_top_mm = 80.0
	camber.sync_thickness_alias()
	_check("mud camber mid", _approx(camber.thickness_at(0.5), 139.0, 141.0),
		str(camber.thickness_at(0.5)))
	var ring := MudSpecScript.make_rect(0.0, 0.0, 1800.0, 1400.0)
	var base_pair: Dictionary = MudSlicerScript.dual_perimeters_camber(
		ring, camber.thickness_at(0.0), MudBuildingSpec.CamberMode.BOTH, 76.2)
	var top_pair: Dictionary = MudSlicerScript.dual_perimeters_camber(
		ring, camber.thickness_at(1.0), MudBuildingSpec.CamberMode.BOTH, 76.2)
	_check("mud camber pairs", not base_pair.is_empty() and not top_pair.is_empty())
	if not base_pair.is_empty() and not top_pair.is_empty():
		var base_outer: PackedVector2Array = base_pair["outer"]
		var top_outer: PackedVector2Array = top_pair["outer"]
		var base_ext := _ring_max_abs_x(base_outer)
		var top_ext := _ring_max_abs_x(top_outer)
		_check("mud camber taper out", base_ext > top_ext + 10.0,
			"base=%.1f top=%.1f" % [base_ext, top_ext])
	var outer_mode: Dictionary = MudSlicerScript.dual_perimeters_camber(
		ring, 150.0, MudBuildingSpec.CamberMode.OUTER, 76.2)
	_check("mud outer camber", not outer_mode.is_empty())
	if not outer_mode.is_empty():
		# Plan is inner face — outer extent grows past plan half-width.
		_check("mud outer grows", _ring_max_abs_x(outer_mode["outer"]) > 900.0 + 40.0,
			str(_ring_max_abs_x(outer_mode["outer"])))

	# --- Phase B: sine fill adds continuous extruding length ---
	var no_fill: MudBuildingSpec = spec.duplicate_spec()
	no_fill.fill_enabled = false
	var with_fill: MudBuildingSpec = spec.duplicate_spec()
	with_fill.fill_enabled = true
	with_fill.fill_mode = MudBuildingSpec.FillMode.SINE
	with_fill.sync_fill_alias()
	with_fill.fill_pitch_mm = 200.0
	var sf0: Dictionary = MudSlicerScript.slice(no_fill)
	var sf1: Dictionary = MudSlicerScript.slice(with_fill)
	_check("mud fill slice ok", bool(sf1.get("ok", false)), str(sf1.get("error", "")))
	_check("mud fill longer",
		float(sf1.get("extrude_length_mm", 0.0)) > float(sf0.get("extrude_length_mm", 0.0)) * 1.15,
		"fill=%.0f bare=%.0f" % [sf1.get("extrude_length_mm"), sf0.get("extrude_length_mm")])
	_check("mud fill mode", str(sf1.get("mode", "")) == "dual_perimeter_fill", str(sf1.get("mode")))
	# Single-layer: travel into/out of cavity (no extruded spokes into the shells).
	var fill1: MudBuildingSpec = with_fill.duplicate_spec()
	fill1.height_mm = fill1.layer_height_mm
	var sf1l: Dictionary = MudSlicerScript.slice(fill1)
	_check("mud fill 1-layer cavity travel",
		int(sf1l.get("travel_segments", 0)) >= 1 and int(sf1l.get("travel_segments", 99)) <= 4,
		str(sf1l.get("travel_segments")))
	# Fill path stays inset: sample a mid-layer fill point distance from outer.
	var pair_f: Dictionary = MudSlicerScript.dual_perimeters_camber(
		ring, with_fill.centerline_sep_at(0.0), MudBuildingSpec.CamberMode.NONE, 76.2)
	_check("mud fill pair", not pair_f.is_empty())

	# --- Phase B: multi-island nearest-neighbor travels ---
	var multi: MudBuildingSpec = spec.duplicate_spec()
	multi.fill_enabled = false
	multi.loops = [
		MudSpecScript.make_rect(-700.0, 0.0, 600.0, 600.0),
		MudSpecScript.make_rect(700.0, 0.0, 600.0, 600.0),
	]
	var ms: Dictionary = MudSlicerScript.slice(multi)
	_check("mud multi ok", bool(ms.get("ok", false)), str(ms.get("error", "")))
	_check("mud multi islands", int(ms.get("island_count", 0)) == 2, str(ms.get("island_count")))
	_check("mud multi travels", int(ms.get("travel_segments", 0)) >= 2,
		str(ms.get("travel_segments")))
	var multi_mesh: ArrayMesh = MudMesherScript.build_mesh(multi)
	_check("mud multi mesh", multi_mesh != null and multi_mesh.get_surface_count() > 0)

	# Round-trip Phase B fields + shell gap / camber-off.
	var d := camber.to_dict()
	var back: MudBuildingSpec = MudSpecScript.from_dict(d)
	_check("mud dict camber", back.camber_mode == camber.camber_mode)
	_check("mud dict top thick", _approx(back.thickness_top_mm, 79.0, 81.0),
		str(back.thickness_top_mm))
	_check("mud dict fill", back.fill_enabled == camber.fill_enabled)
	var gap_rt: MudBuildingSpec = spec.duplicate_spec()
	gap_rt.shell_gap_mm = 120.0
	gap_rt.camber_mode = MudBuildingSpec.CamberMode.NONE
	var gap_back: MudBuildingSpec = MudSpecScript.from_dict(gap_rt.to_dict())
	_check("mud dict shell gap", _approx(gap_back.shell_gap_mm, 119.0, 121.0),
		str(gap_back.shell_gap_mm))
	_check("mud dict camber off", gap_back.camber_mode == MudBuildingSpec.CamberMode.NONE)

	# --- Phase C: GRBL export + parse parity ---
	var exp_spec: MudBuildingSpec = spec.duplicate_spec()
	exp_spec.fill_enabled = false
	exp_spec.height_mm = 200.0  # keep file modest for selftest
	exp_spec.layer_height_mm = 50.0
	var dialect: MudGrblDialect = MudDialectScript.default_dialect()
	dialect.prelude = "; test prelude\nM3 S1000\n"
	dialect.epilogue = "G0 Z{safe_z}\nM5\nM2\n"
	var grbl: Dictionary = MudGrblScript.from_spec(exp_spec, dialect)
	_check("grbl ok", bool(grbl.get("ok", false)), str(grbl.get("error", "")))
	var gtxt := str(grbl.get("gcode", ""))
	_check("grbl has G21", gtxt.find("G21") >= 0)
	_check("grbl has G90", gtxt.find("G90") >= 0)
	_check("grbl prelude", gtxt.find("M3 S1000") >= 0)
	# Default dialect = RELAY: pump on/off M-codes, NO E axis, NO G92 E0.
	_check("grbl relay no E", gtxt.find(" E") < 0, "found E word in relay g-code")
	_check("grbl relay no G92", gtxt.find("G92 E0") < 0)
	_check("grbl relay pump on", gtxt.find("\nM3\n") >= 0 or gtxt.find("\nM3") >= 0)
	_check("grbl relay pump off", gtxt.find("M5") >= 0)
	_check("grbl relay purge dwell", gtxt.find("G4 P") >= 0)
	_check("grbl e_total", float(grbl.get("e_total_mm3", 0.0)) > 1.0e5,
		str(grbl.get("e_total_mm3")))
	# Corner origin: reparsed min corner sits at the work origin (non-negative).
	var rp: Dictionary = ToolpathScript.parse_gcode(gtxt)
	var rp_min: Vector3 = rp.get("bounds_min", Vector3.ZERO)
	_check("grbl corner origin", rp_min.x >= -1.0 and rp_min.y >= -1.0,
		"min=%s" % rp_min)
	var parity: Dictionary = MudGrblScript.parity_check(grbl)
	_check("grbl parity", bool(parity.get("ok", false)), str(parity))
	_check("grbl parity bounds", bool(parity.get("bounds_ok", false)), str(parity))
	_check("grbl parity vol", bool(parity.get("vol_ok", false)),
		"e=%.1f parsed=%.1f" % [parity.get("e_total"), parity.get("e_parsed")])
	_check("grbl parity len", bool(parity.get("len_ok", false)),
		"src=%.1f parsed=%.1f" % [parity.get("src_path_len"), parity.get("parsed_path_len")])
	# E_AXIS mode still emits volumetric E + G92 E0 for grblHAL-style controllers.
	var e_dialect: MudGrblDialect = dialect.duplicate_dialect()
	e_dialect.extrusion_mode = MudGrblDialect.ExtrusionMode.E_AXIS
	var egrbl: Dictionary = MudGrblScript.from_spec(exp_spec, e_dialect)
	var etxt := str(egrbl.get("gcode", ""))
	_check("grbl e-axis G92", etxt.find("G92 E0") >= 0)
	_check("grbl e-axis E word", etxt.find(" E") >= 0)
	var eparity: Dictionary = MudGrblScript.parity_check(egrbl)
	_check("grbl e-axis parity", bool(eparity.get("ok", false)), str(eparity))
	# user:// write + dialect round-trip
	var upath := MudGrblScript.write_user(grbl, "selftest_mud.gcode")
	_check("grbl user write", not upath.is_empty() and FileAccess.file_exists(upath), upath)
	var ddict := dialect.to_dict()
	var dback: MudGrblDialect = MudDialectScript.from_dict(ddict)
	_check("grbl dialect rt", dback.prelude.find("M3") >= 0 and dback.e_scale == dialect.e_scale)
	# XY swap shifts axes in export bounds when reparsed.
	var swap_d: MudGrblDialect = dialect.duplicate_dialect()
	swap_d.xy_swap = true
	var swapped: Dictionary = MudGrblScript.from_spec(exp_spec, swap_d)
	_check("grbl swap ok", bool(swapped.get("ok", false)))
	if bool(swapped.get("ok", false)):
		var sp: Dictionary = ToolpathScript.parse_gcode(str(swapped.get("gcode", "")))
		var sp_span: Vector3 = sp.get("bounds_max", Vector3.ZERO) - sp.get("bounds_min", Vector3.ZERO)
		var src_bmin: Vector3 = grbl.get("bounds_min", Vector3.ZERO)
		var src_bmax: Vector3 = grbl.get("bounds_max", Vector3.ZERO)
		var src_span: Vector3 = src_bmax - src_bmin
		# After XY swap the exported X span should match the source Y span (corner
		# origin translates absolute position, so compare spans not positions).
		_check("grbl swap axes", _approx(sp_span.x, src_span.y - 3.0, src_span.y + 3.0),
			"sx_span=%.1f sy_span=%.1f" % [sp_span.x, src_span.y])

	# --- Phase D: gyroid, open walls, bezier, doorway, place builder ---
	var gyro: MudBuildingSpec = spec.duplicate_spec()
	gyro.fill_mode = MudBuildingSpec.FillMode.GYROID
	gyro.fill_enabled = true
	gyro.sync_fill_alias()
	gyro.height_mm = 150.0
	var gyro_bare: MudBuildingSpec = gyro.duplicate_spec()
	gyro_bare.fill_mode = MudBuildingSpec.FillMode.NONE
	gyro_bare.fill_enabled = false
	gyro_bare.sync_fill_alias()
	var gs: Dictionary = MudSlicerScript.slice(gyro)
	var gs0: Dictionary = MudSlicerScript.slice(gyro_bare)
	_check("mud gyroid ok", bool(gs.get("ok", false)), str(gs.get("error", "")))
	_check("mud gyroid mode", str(gs.get("mode", "")) == "dual_perimeter_gyroid",
		str(gs.get("mode")))
	_check("mud gyroid longer",
		float(gs.get("extrude_length_mm", 0.0)) > float(gs0.get("extrude_length_mm", 0.0)) * 1.05,
		"g=%.0f bare=%.0f" % [gs.get("extrude_length_mm"), gs0.get("extrude_length_mm")])
	var open_spec: MudBuildingSpec = spec.duplicate_spec()
	open_spec.loops = []
	open_spec.fill_mode = MudBuildingSpec.FillMode.NONE
	open_spec.sync_fill_alias()
	open_spec.open_paths = [PackedVector2Array([
		Vector2(-800.0, 0.0), Vector2(0.0, 0.0), Vector2(800.0, 200.0),
	])]
	open_spec.height_mm = 200.0
	var ov: Dictionary = MudPlanOpsScript.validate_spec(open_spec)
	_check("mud open plan ok", bool(ov.get("ok", false)), str(ov.get("error", "")))
	var os: Dictionary = MudSlicerScript.slice(open_spec)
	_check("mud open slice ok", bool(os.get("ok", false)), str(os.get("error", "")))
	_check("mud open count", int(os.get("open_path_count", 0)) == 1, str(os.get("open_path_count")))
	var om: ArrayMesh = MudMesherScript.build_mesh(open_spec)
	_check("mud open mesh", om != null and om.get_surface_count() > 0)

	var anchors := PackedVector2Array([
		Vector2(-400.0, -200.0), Vector2(-100.0, 300.0),
		Vector2(200.0, -100.0), Vector2(500.0, 250.0),
	])
	var bez := MudSpecScript.make_bezier_chain(anchors, false, 6)
	_check("mud bezier denser", bez.size() > anchors.size(), str(bez.size()))
	var bez_v: Dictionary = MudPlanOpsScript.validate_open_path(bez, 76.2, 3048.0, 3048.0)
	_check("mud bezier valid", bool(bez_v.get("ok", false)), str(bez_v.get("error", "")))

	var door: MudBuildingSpec = spec.duplicate_spec()
	door.fill_mode = MudBuildingSpec.FillMode.NONE
	door.sync_fill_alias()
	door.height_mm = 2400.0
	door.layer_height_mm = 50.0
	door.openings = [{"loop_index": 0, "t0": 0.05, "t1": 0.14, "lintel_mm": 2100.0}]
	var ds_low: Dictionary = MudSlicerScript.slice(door)
	_check("mud door slice ok", bool(ds_low.get("ok", false)), str(ds_low.get("error", "")))
	_check("mud door openings", int(ds_low.get("opening_count", 0)) == 1,
		str(ds_low.get("opening_count")))
	# Below lintel there should be extra travels across the gap vs solid room.
	var solid: MudBuildingSpec = door.duplicate_spec()
	solid.openings = []
	var ds_solid: Dictionary = MudSlicerScript.slice(solid)
	_check("mud door more travel",
		int(ds_low.get("travel_segments", 0)) >= int(ds_solid.get("travel_segments", 0)),
		"door=%d solid=%d" % [ds_low.get("travel_segments"), ds_solid.get("travel_segments")])
	# Doorway + sine fill must still slice (jambs + wall-only cavity path).
	var door_fill: MudBuildingSpec = door.duplicate_spec()
	door_fill.fill_mode = MudBuildingSpec.FillMode.SINE
	door_fill.fill_enabled = true
	door_fill.sync_fill_alias()
	door_fill.height_mm = 400.0
	var door_bare: MudBuildingSpec = door_fill.duplicate_spec()
	door_bare.fill_mode = MudBuildingSpec.FillMode.NONE
	door_bare.fill_enabled = false
	door_bare.sync_fill_alias()
	var ds_fill: Dictionary = MudSlicerScript.slice(door_fill)
	var ds_bare: Dictionary = MudSlicerScript.slice(door_bare)
	_check("mud door+fill ok", bool(ds_fill.get("ok", false)), str(ds_fill.get("error", "")))
	_check("mud door+fill longer",
		float(ds_fill.get("extrude_length_mm", 0.0)) > float(ds_bare.get("extrude_length_mm", 0.0)) * 1.1,
		"df=%.0f bare=%.0f" % [ds_fill.get("extrude_length_mm"), ds_bare.get("extrude_length_mm")])
	# Door+fill must still remove bead length vs a solid filled wall (gap open).
	var door_fill_solid: MudBuildingSpec = door_fill.duplicate_spec()
	door_fill_solid.openings = []
	var ds_fill_solid: Dictionary = MudSlicerScript.slice(door_fill_solid)
	_check("mud door+fill less extrude",
		float(ds_fill.get("extrude_length_mm", 0.0))
			< float(ds_fill_solid.get("extrude_length_mm", 1.0)) * 0.98,
		"door=%.0f solid=%.0f" % [
			ds_fill.get("extrude_length_mm"), ds_fill_solid.get("extrude_length_mm")])

	var place_node: Node3D = MudStructScript.build_node({"mud_spec": door.to_dict()})
	_check("mud place node", place_node != null)
	if place_node != null:
		_check("mud place mesh child", place_node.get_node_or_null("Walls") != null)
		place_node.free()

	# --- Camber + fill / camber + doorway must not invent door-filling solids ---
	var cam_fill: MudBuildingSpec = spec.duplicate_spec()
	cam_fill.camber_mode = MudBuildingSpec.CamberMode.BOTH
	cam_fill.thickness_base_mm = 220.0
	cam_fill.thickness_top_mm = 100.0
	cam_fill.sync_thickness_alias()
	cam_fill.fill_mode = MudBuildingSpec.FillMode.SINE
	cam_fill.fill_enabled = true
	cam_fill.sync_fill_alias()
	cam_fill.height_mm = 300.0
	var cf: Dictionary = MudSlicerScript.slice(cam_fill)
	_check("mud camber+fill ok", bool(cf.get("ok", false)), str(cf.get("error", "")))
	var cam_bare: MudBuildingSpec = cam_fill.duplicate_spec()
	cam_bare.fill_mode = MudBuildingSpec.FillMode.NONE
	cam_bare.fill_enabled = false
	cam_bare.sync_fill_alias()
	var cf0: Dictionary = MudSlicerScript.slice(cam_bare)
	_check("mud camber+fill longer",
		float(cf.get("extrude_length_mm", 0.0)) > float(cf0.get("extrude_length_mm", 0.0)) * 1.1,
		"f=%.0f bare=%.0f" % [cf.get("extrude_length_mm"), cf0.get("extrude_length_mm")])
	# Paired dual perimeters: same vertex count (centerline offset).
	var pair_c: Dictionary = MudSlicerScript.dual_perimeters_camber(
		ring, cam_fill.centerline_sep_at(0.0), MudBuildingSpec.CamberMode.BOTH, 76.2)
	_check("mud camber paired", not pair_c.is_empty()
		and (pair_c["outer"] as PackedVector2Array).size()
			== (pair_c["inner"] as PackedVector2Array).size(),
		"o=%d i=%d" % [
			(pair_c.get("outer", PackedVector2Array()) as PackedVector2Array).size(),
			(pair_c.get("inner", PackedVector2Array()) as PackedVector2Array).size()])
	var cam_door: MudBuildingSpec = cam_bare.duplicate_spec()
	cam_door.openings = [{"loop_index": 0, "t0": 0.05, "t1": 0.14, "lintel_mm": 2100.0}]
	cam_door.height_mm = 2400.0
	var cd: Dictionary = MudSlicerScript.slice(cam_door)
	_check("mud camber+door ok", bool(cd.get("ok", false)), str(cd.get("error", "")))
	# Doorway layers should travel more than a solid camber wall (jamb hops).
	var cam_solid: MudBuildingSpec = cam_door.duplicate_spec()
	cam_solid.openings = []
	var cds: Dictionary = MudSlicerScript.slice(cam_solid)
	_check("mud camber+door travels",
		int(cd.get("travel_segments", 0)) >= int(cds.get("travel_segments", 0)),
		"door=%d solid=%d" % [cd.get("travel_segments"), cds.get("travel_segments")])
	# Gap must remove bead length — a door-shaped solid wall would be ~equal or longer.
	_check("mud camber+door less extrude",
		float(cd.get("extrude_length_mm", 0.0)) < float(cds.get("extrude_length_mm", 1.0)) * 0.98,
		"door=%.0f solid=%.0f" % [cd.get("extrude_length_mm"), cds.get("extrude_length_mm")])
	var cam_door_fill: MudBuildingSpec = cam_door.duplicate_spec()
	cam_door_fill.fill_mode = MudBuildingSpec.FillMode.SINE
	cam_door_fill.fill_enabled = true
	cam_door_fill.sync_fill_alias()
	cam_door_fill.height_mm = 400.0
	var cdf: Dictionary = MudSlicerScript.slice(cam_door_fill)
	_check("mud camber+door+fill ok", bool(cdf.get("ok", false)), str(cdf.get("error", "")))


func _test_jobstore() -> void:
	var pts := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 2, 3), Vector3(4, 5, 6)])
	var parse := {"points": pts, "extruding": PackedInt32Array([0, 1, 1]),
		"bounds_min": Vector3(0, 0, 0), "bounds_max": Vector3(4, 5, 6), "kind": "gcode"}
	var jid := JobStoreScript.save(parse)
	_check("jobstore id", not jid.is_empty(), jid)
	var loaded := JobStoreScript.load(jid)
	var lpts: PackedVector3Array = loaded.get("points", PackedVector3Array())
	_check("jobstore points", lpts.size() == 3, str(lpts.size()))
	_check("jobstore point val", lpts.size() == 3 and lpts[1].distance_to(Vector3(1, 2, 3)) < 0.01,
		str(lpts))
	_check("jobstore bounds", (loaded.get("bounds_max", Vector3.ZERO) as Vector3)
		.distance_to(Vector3(4, 5, 6)) < 0.01, str(loaded.get("bounds_max")))


func _test_presets() -> void:
	var found_printer := false
	var found_router := false
	for p: Dictionary in PresetsScript.TOOLS:
		var specs: Dictionary = p.get("specs", {})
		if str(specs.get("model_id", "")) == "trash_printer":
			found_printer = true
			_check("printer role", str(specs.get("role", "")) == "cartesian_machine")
			_check("printer input flake", (specs.get("inputs", []) as Array).size() > 0)
		if str(specs.get("model_id", "")) == "cnc_router":
			found_router = true
			_check("router role", str(specs.get("role", "")) == "cartesian_machine")
	_check("preset printer present", found_printer)
	_check("preset router present", found_router)
	var cat_found := false
	for c: Dictionary in PresetsScript.CATEGORIES:
		if str(c.get("id", "")) == "tools":
			cat_found = true
	_check("tools category present", cat_found)


## Mud printer: STL -> renderable mesh, reveal shader loads, profile + preset +
## resource kind wired for the print-object flow.
func _test_mud_print() -> void:
	# build_mesh: cube of 1 mm -> ~0.001 m, base seated at y=0.
	var mesh: ArrayMesh = StlLoaderScript.build_mesh_from_bytes(_make_binary_cube_stl(1.0))
	_check("mud mesh built", mesh != null)
	if mesh != null:
		var a := mesh.get_aabb()
		_check("mud mesh metric scale", _approx(a.size.y, 0.0009, 0.0011), str(a.size))
		_check("mud mesh base y=0", _approx(a.position.y, -0.0001, 0.0001), str(a.position))
	# Reveal shader loads + compiles enough to be a Shader resource.
	var sh: Shader = load("res://gameplay/print_reveal.gdshader")
	_check("reveal shader loads", sh != null and sh is Shader)
	# Mud printer profile: fixed-bed gantry, Z rises (not inverted).
	var mp := ProfileScript.default_for("mud_printer")
	_check("mud profile configured", mp.is_configured(), str(mp.to_dict()))
	_check("mud tool node", mp.tool_node == "Fog Nozzle", mp.tool_node)
	_check("mud z up", mp.axis_dir("z").y > 0.0, str(mp.axis_dir("z")))
	# Preset present + persist flag + mud material.
	var found := false
	for p: Dictionary in PresetsScript.TOOLS:
		var specs: Dictionary = p.get("specs", {})
		if str(specs.get("model_id", "")) == "mud_printer":
			found = true
			_check("mud persist flag", bool(specs.get("print_persist", false)))
			_check("mud kind", str(specs.get("machine_kind", "")) == "mud")
			_check("mud material", str(specs.get("job_material_kind", "")) == "mud")
	_check("mud preset present", found)
	_check("mud resource kind", ResourceKinds.has_kind("mud"))

	# Slicer opts: solid vs spiral-vase deposited volume + scaling + rising spiral.
	var cube := _make_binary_cube_stl(10.0)   # 10 mm cube, solid vol 1000 mm3
	var solid := StlLoaderScript.parse_bytes(cube, {"mode": "solid", "scale": 2.0})
	_check("solid vol scale^3", _approx(float(solid.get("volume_mm3", 0.0)), 7900.0, 8100.0),
		str(solid.get("volume_mm3")))
	var vase := StlLoaderScript.parse_bytes(cube,
		{"mode": "vase", "scale": 1.0, "line_width_mm": 2.0, "layer_height_mm": 5.0})
	_check("vase mode echoed", str(vase.get("mode", "")) == "vase", str(vase.get("mode")))
	_check("vase vol < solid", float(vase.get("volume_mm3", 0.0)) < float(solid.get("volume_mm3", 1.0)),
		"%s vs %s" % [vase.get("volume_mm3"), solid.get("volume_mm3")])
	_check("vase shell ~800", _approx(float(vase.get("volume_mm3", 0.0)), 700.0, 900.0),
		str(vase.get("volume_mm3")))
	var vp: PackedVector3Array = vase.get("points", PackedVector3Array())
	_check("vase path points", vp.size() >= 2, str(vp.size()))
	if vp.size() >= 2:
		_check("vase spiral rises", vp[vp.size() - 1].z > vp[0].z + 1.0,
			"%s -> %s" % [vp[0].z, vp[vp.size() - 1].z])


## Builds a minimal binary STL of an axis-aligned cube [0..size]^3 (12 triangles).
func _make_binary_cube_stl(size: float) -> PackedByteArray:
	var v := [
		Vector3(0, 0, 0), Vector3(size, 0, 0), Vector3(size, size, 0), Vector3(0, size, 0),
		Vector3(0, 0, size), Vector3(size, 0, size), Vector3(size, size, size), Vector3(0, size, size),
	]
	# 12 triangles (2 per face), consistent-ish winding (magnitude is what we test).
	var tris := [
		[0, 1, 2], [0, 2, 3],   # bottom z=0
		[4, 6, 5], [4, 7, 6],   # top z=size
		[0, 4, 5], [0, 5, 1],   # y=0
		[3, 2, 6], [3, 6, 7],   # y=size
		[0, 3, 7], [0, 7, 4],   # x=0
		[1, 5, 6], [1, 6, 2],   # x=size
	]
	var buf := PackedByteArray()
	buf.resize(80)  # header
	var count_bytes := PackedByteArray()
	count_bytes.resize(4)
	count_bytes.encode_u32(0, tris.size())
	buf.append_array(count_bytes)
	for t in tris:
		var tri := PackedByteArray()
		tri.resize(50)
		# normal (0..12) left zero; vertices at 12..48; attr 48..50 zero.
		var off := 12
		for idx in t:
			var p: Vector3 = v[idx]
			tri.encode_float(off, p.x)
			tri.encode_float(off + 4, p.y)
			tri.encode_float(off + 8, p.z)
			off += 12
		buf.append_array(tri)
	return buf
