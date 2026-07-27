extends SceneTree

## Offline self-test for corrugated PE culvert kits + wide-arc routing.
## Run (after --import and culvert_kit_extractor):
##   Godot.exe.exe --headless --path . --script core/conduits/culvert_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_kind()
	_test_sizes()
	_test_kits_load()
	_test_router_fillet()
	_test_assembler()
	if _failures == 0:
		print("CULVERT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CULVERT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
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


func _test_kind() -> void:
	_check("has culvert_pipe", ConduitKinds.has_type("culvert_pipe"))
	_check("culvert uses kit", ConduitKinds.uses_pipe_kit("culvert_pipe"))
	_check("culvert family", ConduitKinds.uses_culvert_kit("culvert_pipe"))
	_check("not sch40 pin edit", not ConduitKinds.supports_pipe_pin_edit("culvert_pipe"))
	_check("flex pin edit", ConduitKinds.supports_flex_pin_edit("culvert_pipe"))
	_check("route mode culvert", ConduitKinds.normalize_route_mode(
		str(ConduitKinds.type_meta("culvert_pipe").get("route_mode", ""))) == "culvert")
	_check("default size 8", is_equal_approx(
		ConduitKinds.pipe_size_in("culvert_pipe", {}), 8.0))
	_check("kit id 8", ConduitKinds.pipe_kit_id("culvert_pipe", {}) == "pe_culvert_8")
	_check("kit id 24", ConduitKinds.pipe_kit_id("culvert_pipe",
		{"pipe_size_in": 24.0}) == "pe_culvert_24")
	_check("display name sized", ConduitKinds.display_name_with_size(
		"culvert_pipe", {"pipe_size_in": 12.0}).contains("12"))


func _test_sizes() -> void:
	var sizes: Array = ConduitKinds.pipe_kit_sizes_in("culvert_pipe")
	_check("size count", sizes.size() == CulvertKit.SIZES_IN.size(),
		"n=%d" % sizes.size())
	_check("has 4in", 4.0 in sizes)
	_check("has 24in", 24.0 in sizes)
	_check("nearest 7.5→8", is_equal_approx(CulvertKit.nearest_size_in(7.5), 8.0))
	_check("nearest 14→15", is_equal_approx(CulvertKit.nearest_size_in(14.0), 15.0))


func _test_kits_load() -> void:
	var n_ok := 0
	for sz: float in CulvertKit.SIZES_IN:
		var kit := CulvertKit.load_kit(CulvertKit.kit_id_for_size(sz))
		if kit == null:
			_check("load %s" % CulvertKit.kit_id_for_size(sz), false)
			continue
		n_ok += 1
		_check("od scales %g" % sz, kit.nominal_od_m > 0.05,
			"od=%.3f" % kit.nominal_od_m)
		_check("pitch scales %g" % sz, kit.pitch_m > 0.01,
			"pitch=%.4f" % kit.pitch_m)
		_check("ring mesh %g" % sz, kit.ring_mesh != null)
		var r := kit.bend_radius_m({})
		_check("bend R ≥ 3×OD %g" % sz, r >= kit.nominal_od_m * 2.9,
			"R=%.3f OD=%.3f" % [r, kit.nominal_od_m])
	_check("all sizes load", n_ok == CulvertKit.SIZES_IN.size(), "ok=%d" % n_ok)
	# 24″ should be ~3× the 8″ OD.
	var k8 := CulvertKit.load_kit("pe_culvert_8")
	var k24 := CulvertKit.load_kit("pe_culvert_24")
	if k8 != null and k24 != null:
		var ratio := k24.nominal_od_m / k8.nominal_od_m
		_check("24/8 OD ~3", absf(ratio - 3.0) < 0.05, "ratio=%.3f" % ratio)


func _test_router_fillet() -> void:
	# Sharp L → filleted arc with no hard 90° corner sample at the tip.
	var a := Vector3(0, 0, 0)
	var corner := Vector3(4, 0, 0)
	var b := Vector3(4, 0, 4)
	var path := CulvertRouter.expand([a, corner, b], 1.2)
	_check("fillet samples", path.size() > 6, "n=%d" % path.size())
	_check("fillet starts", path[0].distance_to(a) < 0.05)
	_check("fillet ends", path[path.size() - 1].distance_to(b) < 0.05)
	# Sharp corner should be rounded away (no sample within 0.15 m of tip).
	var near_tip := 1e9
	for p: Vector3 in path:
		near_tip = minf(near_tip, p.distance_to(corner))
	_check("fillet cuts corner", near_tip > 0.2, "d=%.3f" % near_tip)
	# Max turn between consecutive samples stays gentle.
	var max_turn := 0.0
	for i: int in range(1, path.size() - 1):
		var d0 := (path[i] - path[i - 1]).normalized()
		var d1 := (path[i + 1] - path[i]).normalized()
		max_turn = maxf(max_turn, acos(clampf(d0.dot(d1), -1.0, 1.0)))
	_check("fillet smooth", max_turn < deg_to_rad(25.0),
		"turn=%.1f°" % rad_to_deg(max_turn))


func _test_assembler() -> void:
	var kit := CulvertKit.load_kit("pe_culvert_8")
	if kit == null:
		_check("assembler kit", false)
		return
	var host := Node3D.new()
	get_root().add_child(host)
	var path := CulvertRouter.expand([
		Vector3(0, 0.2, 0), Vector3(3, 0.2, 0), Vector3(3, 0.2, 3),
	], kit.bend_radius_m({}))
	var mat := ConduitKinds.make_pipe_kit_material("culvert_pipe")
	var applied := CulvertAssembler.apply(host, "t", path, kit, mat)
	_check("assemble ok", bool(applied.get("ok", false)))
	_check("ring count", int(applied.get("ring_count", 0)) >= 4,
		"n=%d" % int(applied.get("ring_count", 0)))
	var cl: PackedVector3Array = applied.get("centerline", PackedVector3Array())
	_check("centerline", cl.size() >= 2)
	var parts := host.get_node_or_null("CulvertParts_t") as Node3D
	_check("has barrel", parts != null and parts.get_node_or_null("Barrel") != null)
	_check("has ribs", parts != null and parts.get_node_or_null("MM_rings") != null)
	_check("short run under tris budget",
		int(applied.get("approx_tris", 0)) <= CulvertAssembler.MAX_TRIS_BUDGET,
		"tris=%d" % int(applied.get("approx_tris", 0)))
	# Procedural path must not require the baked GLB ring mesh.
	var kit_no_mesh := CulvertKit.load_kit("pe_culvert_8")
	if kit_no_mesh != null:
		kit_no_mesh.ring_mesh = null
		var no_mesh := CulvertAssembler.apply(host, "nomesh", path, kit_no_mesh, mat)
		_check("ok without GLB ring_mesh", bool(no_mesh.get("ok", false)))
		CulvertAssembler.clear(host, "nomesh")
	CulvertAssembler.clear(host, "t")
	_check("cleared", host.get_node_or_null("CulvertParts_t") == null)
	# Long run must not stamp unbounded rings (world FPS bomb).
	var long_path := PackedVector3Array()
	for i in 200:
		long_path.append(Vector3(float(i) * 2.0, 0.2, 0.0))
	var long_applied := CulvertAssembler.apply(host, "long", long_path, kit, mat)
	_check("long run capped",
		int(long_applied.get("ring_count", 0)) <= CulvertAssembler.MAX_RINGS,
		"n=%d" % int(long_applied.get("ring_count", 0)))
	_check("long run under tris budget",
		int(long_applied.get("approx_tris", 0)) <= CulvertAssembler.MAX_TRIS_BUDGET,
		"tris=%d" % int(long_applied.get("approx_tris", 0)))
	CulvertAssembler.clear(host, "long")
	host.queue_free()
