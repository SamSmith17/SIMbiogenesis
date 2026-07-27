extends SceneTree

## Offline self-test for multi-size US Sch40 pipe kits + planner/assembler.
## Run (after --import, and after pipe_kit_extractor if meshes missing):
##   Godot.exe.exe --headless --path . --script core/conduits/pipe_kit_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_kit_meta()
	_test_all_sizes_load()
	_test_socket_bend_angles()
	_test_elbow_xform_alignment()
	_test_inventory()
	_test_pin_edit_gates()
	_test_kit_material()
	_test_crease_normals()
	_test_morph()
	_test_procedural_straight()
	_test_planner_axis()
	_test_planner_90()
	_test_planner_riser_pin()
	_test_expander_3d()
	_test_expander_compound()
	_test_planner_45()
	_test_assembler_no_mm0()
	_test_merge_colinear()
	_test_size_extremes_plan()
	_test_legacy_abs_alias()
	if _failures == 0:
		print("PIPE KIT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("PIPE KIT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s %s" % [label, detail])


func _test_kit_meta() -> void:
	_check("abs uses kit", ConduitKinds.uses_pipe_kit("abs_dwv"))
	_check("pvc uses kit", ConduitKinds.uses_pipe_kit("pvc_pipe"))
	_check("pvc_4in uses kit", ConduitKinds.uses_pipe_kit("pvc_4in"))
	_check("abs default kit id", ConduitKinds.pipe_kit_id("abs_dwv") == "us_sch40_2_5")
	_check("pvc default kit id", ConduitKinds.pipe_kit_id("pvc_pipe") == "us_sch40_1_25")
	_check("pvc size override",
		ConduitKinds.pipe_kit_id("pvc_pipe", {"pipe_size_in": 4.0}) == "us_sch40_4")
	_check("pvc_4in kit id", ConduitKinds.pipe_kit_id("pvc_4in") == "us_sch40_4")
	_check("pvc_6in kit id", ConduitKinds.pipe_kit_id("pvc_6in") == "us_sch40_6")
	_check("abs sharp elbows", is_equal_approx(
		float(ConduitKinds.type_meta("abs_dwv").get("elbow_radius_frac", 1.0)), 0.0))
	_check("pvc sharp elbows", is_equal_approx(
		float(ConduitKinds.type_meta("pvc_pipe").get("elbow_radius_frac", 1.0)), 0.0))
	var abs_lbl := ConduitKinds.display_name_with_size("abs_dwv", {})
	_check("display with size", abs_lbl.find("½") >= 0 or abs_lbl.find("2.5") >= 0,
		abs_lbl)


func _test_all_sizes_load() -> void:
	for sz: float in PipeKit.SCH40_SIZES_IN:
		var kid := PipeKit.kit_id_for_size(PipeKit.FAMILY_US_SCH40, sz)
		var kit := PipeKit.load_kit(kid)
		_check("kit loads %s" % kid, kit != null)
		if kit == null:
			continue
		_check("%s has 0" % kid, kit.has_elbow(0.0))
		_check("%s has 45" % kid, kit.has_elbow(45.0))
		_check("%s has 90" % kid, kit.has_elbow(90.0))
		_check("%s 45 takeout" % kid, kit.elbow_takeout_m(45.0) > 0.005,
			"t=%.4f" % kit.elbow_takeout_m(45.0))
		_check("%s 90 takeout" % kid, kit.elbow_takeout_m(90.0) > 0.005,
			"t=%.4f" % kit.elbow_takeout_m(90.0))
		_check("%s od" % kid, kit.nominal_od_m > 0.01,
			"od=%.4f" % kit.nominal_od_m)
	var kit25 := PipeKit.load_kit("us_sch40_2_5")
	if kit25 != null:
		_check("classify 90", is_equal_approx(kit25.classify_bend_deg(90.0), 90.0))
		_check("classify 45", is_equal_approx(kit25.classify_bend_deg(45.0), 45.0))
		_check("classify 30 unsupported", kit25.classify_bend_deg(30.0) < 0.0)


func _test_socket_bend_angles() -> void:
	## Baked elbows must have socket_b outward at ~bend_deg from +Z (not −Z).
	## Regression: 45° kits used to pair outer/inner rim of one collar.
	for sz: float in PipeKit.SCH40_SIZES_IN:
		var kid := PipeKit.kit_id_for_size(PipeKit.FAMILY_US_SCH40, sz)
		var kit := PipeKit.load_kit(kid)
		if kit == null:
			_check("socket kit %s" % kid, false)
			continue
		for bend: float in [45.0, 90.0]:
			var part: Dictionary = kit.part(bend)
			var sb: Dictionary = part.get("socket_b", {}) as Dictionary
			var nb := _v3(sb.get("outward", []))
			var turn := rad_to_deg(Vector3(0, 0, 1).angle_to(nb))
			_check("%s %.0f° flow turn" % [kid, bend], absf(turn - bend) <= 12.0,
				"turn=%.1f nb=%s" % [turn, str(nb)])
			_check("%s %.0f° takeout" % [kid, bend],
				float(part.get("takeout_m", 0.0)) > 0.01,
				"t=%.4f" % float(part.get("takeout_m", 0.0)))


func _test_elbow_xform_alignment() -> void:
	## Planner transform must map baked socket_b outward onto d_out.
	var kit := PipeKit.load_kit("us_sch40_1_25")
	if kit == null:
		_check("xform kit", false)
		return
	var d_in := Vector3(1, 0, 0)
	var d_out_45 := Vector3(cos(deg_to_rad(45.0)), 0, sin(deg_to_rad(45.0))).normalized()
	var d_out_90 := Vector3(0, 0, 1)
	var corner := Vector3(2, 1, 0)
	for bend: float in [45.0, 90.0]:
		var d_out := d_out_45 if bend < 50.0 else d_out_90
		var take := kit.elbow_takeout_m(bend)
		var xf := PipePartsPlanner._elbow_xform(corner, d_in, d_out, take, kit, bend)
		var sb: Dictionary = kit.part(bend).get("socket_b", {}) as Dictionary
		var local_out := _v3(sb.get("outward", []))
		var world_out := (xf.basis * local_out).normalized()
		_check("xform %.0f° outlet aligns" % bend, world_out.dot(d_out) > 0.98,
			"dot=%.3f world=%s" % [world_out.dot(d_out), str(world_out)])
		var world_in := (xf.basis * Vector3(0, 0, 1)).normalized()
		_check("xform %.0f° inlet aligns" % bend, world_in.dot(d_in) > 0.98,
			"dot=%.3f" % world_in.dot(d_in))


func _v3(v: Variant) -> Vector3:
	if v is Vector3:
		return (v as Vector3).normalized()
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		var o := Vector3(float(a[0]), float(a[1]), float(a[2]))
		return o.normalized() if o.length_squared() > 1e-12 else Vector3(0, 0, 1)
	return Vector3(0, 0, 1)


func _test_inventory() -> void:
	var inv := PipeKit.load_inventory()
	_check("inventory loads", not inv.is_empty())
	if inv.is_empty():
		return
	var active: Array = inv.get("active_roles", []) as Array
	_check("active has pipe", active.has("pipe"))
	_check("active has elbow_45", active.has("elbow_45"))
	_check("active has elbow_90", active.has("elbow_90"))
	var catalog: Dictionary = inv.get("catalog", {}) as Dictionary
	for role: String in ["tee_90", "wye_45", "reducing_tee", "reducing_socket"]:
		_check("inv deferred %s" % role, catalog.has(role))
		if catalog.has(role):
			var by_sz: Dictionary = catalog[role] as Dictionary
			_check("inv %s has entries" % role, not by_sz.is_empty())
			if not by_sz.is_empty():
				var first: Dictionary = by_sz.values()[0] as Dictionary
				_check("inv %s node_name" % role,
					not str(first.get("node_name", "")).is_empty())
	var sizes: Array = inv.get("sizes_in", []) as Array
	_check("inv 12 sizes", sizes.size() == 12, "n=%d" % sizes.size())


func _test_pin_edit_gates() -> void:
	_check("pipe pin abs", ConduitKinds.supports_pipe_pin_edit("abs_dwv"))
	_check("pipe pin pvc", ConduitKinds.supports_pipe_pin_edit("pvc_pipe"))
	_check("no pipe pin cord", not ConduitKinds.supports_pipe_pin_edit("extension_cord"))
	_check("pin edit abs", ConduitKinds.supports_pin_edit("abs_dwv"))
	_check("pin edit cord", ConduitKinds.supports_pin_edit("extension_cord"))
	_check("pin edit pvc/pex", ConduitKinds.supports_pin_edit("pvc_pipe") \
			and ConduitKinds.supports_pin_edit("pex_red"))
	_check("flex pin pex not pvc kit", ConduitKinds.supports_flex_pin_edit("pex_red") \
			and not ConduitKinds.supports_flex_pin_edit("pvc_pipe") \
			and not ConduitKinds.supports_pipe_pin_edit("pex_red"))
	_check("hang still cord-only", ConduitKinds.supports_hang_edit("extension_cord") \
			and not ConduitKinds.supports_hang_edit("abs_dwv"))
	_check("no hang sag on abs", not ConduitKinds.conn_uses_hang_sag({
		"conduit_type": "abs_dwv", "route_locked": true,
		"route_3d": [{"x": 1.0, "y": 2.0, "z": 0.0}],
	}))


func _test_kit_material() -> void:
	var mat_abs := ConduitKinds.make_pipe_kit_material("abs_dwv")
	_check("abs mat dull roughness", mat_abs.roughness >= 0.55,
		"r=%.2f" % mat_abs.roughness)
	_check("abs mat soft clearcoat", (not mat_abs.clearcoat_enabled) \
			or mat_abs.clearcoat <= 0.12,
		"cc=%.2f" % mat_abs.clearcoat)
	_check("abs mat no emission", not mat_abs.emission_enabled)
	_check("abs mat dark", mat_abs.albedo_color.r < 0.2 and mat_abs.albedo_color.g < 0.2)
	var mat_pvc := ConduitKinds.make_pipe_kit_material("pvc_pipe")
	_check("pvc mat light", mat_pvc.albedo_color.r > 0.7 and mat_pvc.albedo_color.g > 0.7)
	_check("pvc mat dull roughness", mat_pvc.roughness >= 0.55,
		"r=%.2f" % mat_pvc.roughness)
	_check("pvc mat soft clearcoat", (not mat_pvc.clearcoat_enabled) \
			or mat_pvc.clearcoat <= 0.12,
		"cc=%.2f" % mat_pvc.clearcoat)
	_check("pvc mat no emission", not mat_pvc.emission_enabled)
	_check("pvc cull back", mat_pvc.cull_mode == BaseMaterial3D.CULL_BACK)


func _test_crease_normals() -> void:
	# Unit cube: adjacent faces are 90° — crease must hard-edge them.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0),
		Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1),
	]
	var faces := [
		[0, 1, 2, 0, 2, 3],  # -Z
		[4, 6, 5, 4, 7, 6],  # +Z
		[0, 4, 5, 0, 5, 1],  # -Y
	]
	for f: Array in faces:
		for idx: int in f:
			st.add_vertex(corners[idx])
	st.generate_normals()
	var soft := st.commit()
	var hard := PipeKit.crease_normals(soft, 32.0)
	_check("crease returns mesh", hard != null and hard.get_surface_count() > 0)
	if hard == null or hard.get_surface_count() == 0:
		return
	var arr := hard.surface_get_arrays(0)
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	_check("crease has normals", norms.size() >= 6, "n=%d" % norms.size())
	# Opposite face normals should exist (not one averaged mush).
	var has_neg_z := false
	var has_pos_z := false
	for n: Vector3 in norms:
		if n.z < -0.85:
			has_neg_z = true
		if n.z > 0.85:
			has_pos_z = true
	_check("crease keeps -Z faces", has_neg_z)
	_check("crease keeps +Z faces", has_pos_z)


func _test_morph() -> void:
	_check("morph 50→45", is_equal_approx(PipePartsPlanner.morph_bend_deg(50.0), 45.0))
	_check("morph 80→90", is_equal_approx(PipePartsPlanner.morph_bend_deg(80.0), 90.0))
	_check("morph 1→0", is_equal_approx(PipePartsPlanner.morph_bend_deg(1.0), 0.0))
	_check("morph via expander", is_equal_approx(
		PipeFittingExpander.morph_bend_deg(80.0), 90.0))


func _default_kit() -> PipeKit:
	return PipeKit.load_kit("us_sch40_2_5")


func _test_procedural_straight() -> void:
	var kit := _default_kit()
	if kit == null:
		_check("proc straight kit", false)
		return
	var span := 2.5
	var sharp := PackedVector3Array([Vector3.ZERO, Vector3(span, 0, 0)])
	var bom := PipePartsPlanner.plan(sharp, kit)
	_check("proc ok", bool(bom.get("ok", false)), str(bom.get("error", "")))
	var parts: Array = bom.get("parts", []) as Array
	_check("proc one straight", parts.size() == 1 \
			and str((parts[0] as Dictionary).get("kind", "")) == "straight")
	if parts.size() == 1:
		var d: Dictionary = parts[0]
		_check("proc has from/to", d.has("from") and d.has("to"))
		_check("proc length", absf(float(d.get("length_m", 0.0)) - span) < 0.02)


func _test_planner_axis() -> void:
	var kit := _default_kit()
	if kit == null:
		_check("planner axis kit", false)
		return
	var short := 0.2
	var sharp := PackedVector3Array([Vector3.ZERO, Vector3(short, 0, 0)])
	var bom := PipePartsPlanner.plan(sharp, kit)
	_check("axis ok", bool(bom.get("ok", false)), str(bom.get("error", "")))
	var parts: Array = bom.get("parts", []) as Array
	_check("axis procedural straight", parts.size() == 1 \
			and str((parts[0] as Dictionary).get("kind", "")) == "straight")
	if parts.size() == 1:
		_check("axis length", absf(float((parts[0] as Dictionary).get("length_m", 0.0)) - short) < 0.02)


func _test_planner_90() -> void:
	var kit := _default_kit()
	if kit == null:
		_check("planner 90 kit", false)
		return
	var sharp := PackedVector3Array([
		Vector3(0, 1, 0), Vector3(2, 1, 0), Vector3(2, 1, 2),
	])
	var bom := PipePartsPlanner.plan(sharp, kit)
	_check("90 ok", bool(bom.get("ok", false)), str(bom.get("error", "")))
	var parts: Array = bom.get("parts", []) as Array
	var n_straight := 0
	var n_elbow := 0
	var elbow_deg := 0.0
	for p: Variant in parts:
		var d: Dictionary = p
		if str(d.get("kind", "")) == "elbow":
			n_elbow += 1
			elbow_deg = float(d.get("bend_deg", 0.0))
		else:
			n_straight += 1
	_check("90 has elbow", n_elbow == 1 and is_equal_approx(elbow_deg, 90.0),
		"e=%d deg=%.1f" % [n_elbow, elbow_deg])
	_check("90 has straights", n_straight >= 1)
	_check("90 centerline", (bom.get("centerline", PackedVector3Array()) as PackedVector3Array).size() >= 3)


func _test_planner_riser_pin() -> void:
	var kit := _default_kit()
	if kit == null:
		_check("riser kit", false)
		return
	var a := Vector3(0, 0.5, 0)
	var pin := Vector3(2, 0.5, 0)
	var b := Vector3(2, 2.5, 0)
	var sharp := PackedVector3Array([a, pin, b])
	_check("riser pin Y differs", absf(pin.y - b.y) > 1.0)
	var bom := PipePartsPlanner.plan(sharp, kit)
	_check("riser plan ok", bool(bom.get("ok", false)), str(bom.get("error", "")))
	var has_90 := false
	for p: Variant in bom.get("parts", []) as Array:
		var d: Dictionary = p
		if str(d.get("kind", "")) == "elbow" \
				and is_equal_approx(float(d.get("bend_deg", 0.0)), 90.0):
			has_90 = true
	_check("riser has 90 elbow", has_90)
	var cl: PackedVector3Array = bom.get("centerline", PackedVector3Array()) as PackedVector3Array
	var saw_pin_y := false
	for p: Vector3 in cl:
		if absf(p.x - pin.x) < 0.05 and absf(p.z - pin.z) < 0.05 \
				and absf(p.y - pin.y) < 0.15:
			saw_pin_y = true
	_check("riser honors pin Y", saw_pin_y, "cl_n=%d" % cl.size())


func _test_expander_3d() -> void:
	## Off-lattice 3D pin (different Y) → only 45/90 turns → plans OK.
	var kit := _default_kit()
	if kit == null:
		_check("expander 3d kit", false)
		return
	var a := Vector3(0, 0.5, 0)
	var pin := Vector3(3, 2.0, 1.5)  # free-space 3D pin
	var b := Vector3(6, 0.5, 0)
	var sparse: Array = [a, pin, b]
	var expanded := PipeFittingExpander.expand(sparse, 45.0)
	_check("expander 3d points", expanded.size() >= 3, "n=%d" % expanded.size())
	_check("expander 3d legal", _polyline_turns_legal(expanded),
		"n=%d" % expanded.size())
	# Pin Y preserved somewhere on the path (riser to pin height).
	var saw_y := false
	for p: Vector3 in expanded:
		if absf(p.y - pin.y) < 0.08:
			saw_y = true
	_check("expander preserves pin height", saw_y)
	var bom := PipePartsPlanner.plan(expanded, kit)
	_check("expander 3d plans", bool(bom.get("ok", false)), str(bom.get("error", "")))
	var n_elbow := 0
	for p: Variant in bom.get("parts", []) as Array:
		if str((p as Dictionary).get("kind", "")) == "elbow":
			n_elbow += 1
	_check("expander 3d has elbows", n_elbow >= 1, "e=%d" % n_elbow)


func _test_expander_compound() -> void:
	## Two-pin S / U between elevated ports → ≥2 elbows.
	var kit := _default_kit()
	if kit == null:
		_check("compound kit", false)
		return
	var a := Vector3(0, 1.5, 0)
	var p1 := Vector3(2, 1.5, 2)
	var p2 := Vector3(4, 1.5, 0)
	var b := Vector3(6, 1.5, 2)
	var expanded := PipeFittingExpander.expand([a, p1, p2, b], 45.0)
	_check("compound legal", _polyline_turns_legal(expanded))
	var bom := PipePartsPlanner.plan(expanded, kit)
	_check("compound plans", bool(bom.get("ok", false)), str(bom.get("error", "")))
	var n_elbow := 0
	for p: Variant in bom.get("parts", []) as Array:
		if str((p as Dictionary).get("kind", "")) == "elbow":
			n_elbow += 1
	_check("compound ≥2 elbows", n_elbow >= 2, "e=%d" % n_elbow)


func _test_planner_45() -> void:
	var kit := _default_kit()
	if kit == null:
		_check("planner 45 kit", false)
		return
	var a := Vector3(0, 0.5, 0)
	var b := Vector3(4, 0.5, 2)
	var packed := ConduitPipesRouter.route(a, b, [], Callable(), 0.12, 0.0, [], 45.0)
	_check("45 route points", packed.size() >= 3, "n=%d" % packed.size())
	var bom := PipePartsPlanner.plan(packed, kit)
	_check("45 plan ok", bool(bom.get("ok", false)), str(bom.get("error", "")))
	var has_45 := false
	for p: Variant in bom.get("parts", []) as Array:
		if str((p as Dictionary).get("kind", "")) == "elbow" \
				and is_equal_approx(float((p as Dictionary).get("bend_deg", 0.0)), 45.0):
			has_45 = true
	_check("45 has 45 elbow", has_45)


func _test_assembler_no_mm0() -> void:
	## Procedural straights — host must not create MM_0 (hollow GLB rings).
	var kit := _default_kit()
	if kit == null:
		_check("asm kit", false)
		return
	var host := Node3D.new()
	root.add_child(host)
	var sharp := PackedVector3Array([
		Vector3(0, 1, 0), Vector3(2, 1, 0), Vector3(2, 1, 2),
	])
	var bom := PipePartsPlanner.plan(sharp, kit)
	_check("asm bom ok", bool(bom.get("ok", false)))
	var mat := ConduitKinds.make_pipe_kit_material("abs_dwv")
	var applied: Dictionary = PipePartsAssembler.apply(host, "t", bom, kit, mat)
	var cl: PackedVector3Array = applied.get("centerline", PackedVector3Array()) as PackedVector3Array
	_check("asm centerline", cl.size() >= 2)
	var parts_host := host.get_node_or_null("PipeParts_t")
	_check("asm host", parts_host != null)
	if parts_host != null:
		_check("asm no MM_0", parts_host.get_node_or_null("MM_0") == null)
		var n_straight := 0
		var n_elbow_mm := 0
		for c in parts_host.get_children():
			var nm := str(c.name)
			if nm.begins_with("Straight_"):
				n_straight += 1
			elif nm.begins_with("MM_"):
				n_elbow_mm += 1
		_check("asm has Straight_*", n_straight >= 1, "n=%d" % n_straight)
		_check("asm has elbow MM", n_elbow_mm >= 1, "n=%d" % n_elbow_mm)
	var elbows: Array = applied.get("elbows", []) as Array
	_check("asm elbow cache", elbows.size() >= 1, "n=%d" % elbows.size())
	host.queue_free()


func _test_merge_colinear() -> void:
	## Two colinear straights with a zero-bend should collapse to one.
	var kit := _default_kit()
	if kit == null:
		_check("merge kit", false)
		return
	# Axis-aligned run with a colinear mid sample (no turn) → one straight.
	var sharp := PackedVector3Array([
		Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(3, 1, 0),
	])
	var bom := PipePartsPlanner.plan(sharp, kit)
	_check("merge plan ok", bool(bom.get("ok", false)), str(bom.get("error", "")))
	var n_straight := 0
	var n_elbow := 0
	for p: Variant in bom.get("parts", []) as Array:
		if str((p as Dictionary).get("kind", "")) == "elbow":
			n_elbow += 1
		else:
			n_straight += 1
	_check("merge no elbows", n_elbow == 0, "e=%d" % n_elbow)
	_check("merge one straight", n_straight == 1, "s=%d" % n_straight)


func _test_size_extremes_plan() -> void:
	## Planner axis run at 0.5″ and 8″ succeeds with ≥1 elbow on a 90° path.
	for kid: String in ["us_sch40_0_5", "us_sch40_8"]:
		var kit := PipeKit.load_kit(kid)
		_check("%s loads" % kid, kit != null)
		if kit == null:
			continue
		var sharp := PackedVector3Array([
			Vector3(0, 1, 0), Vector3(2, 1, 0), Vector3(2, 1, 2),
		])
		var bom := PipePartsPlanner.plan(sharp, kit)
		_check("%s 90 plan" % kid, bool(bom.get("ok", false)), str(bom.get("error", "")))
		var n_elbow := 0
		for p: Variant in bom.get("parts", []) as Array:
			if str((p as Dictionary).get("kind", "")) == "elbow":
				n_elbow += 1
		_check("%s has elbow" % kid, n_elbow >= 1, "e=%d" % n_elbow)


func _test_legacy_abs_alias() -> void:
	var kit := PipeKit.load_kit("abs_dwv")
	_check("legacy abs_dwv alias loads", kit != null)
	if kit != null:
		_check("legacy has 90", kit.has_elbow(90.0))


func _polyline_turns_legal(pts: PackedVector3Array) -> bool:
	for i: int in range(1, pts.size() - 1):
		var d_in := pts[i] - pts[i - 1]
		var d_out := pts[i + 1] - pts[i]
		if d_in.length_squared() < 1e-12 or d_out.length_squared() < 1e-12:
			return false
		var turn := rad_to_deg(d_in.normalized().angle_to(d_out.normalized()))
		if turn < 2.0:
			continue
		if absf(turn - 45.0) > 12.0 and absf(turn - 90.0) > 12.0:
			return false
	return true
