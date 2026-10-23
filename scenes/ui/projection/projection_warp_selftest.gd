extends SceneTree
## ProjectionWarp (offline): the corner-pin homography (unit square corners
## land on the quad's corners, an interior point round-trips through the
## inverse, a parallelogram is affine, a perspective quad's centre is NOT the
## average of its corners), the layouts, quad validity, and the config: a v2
## round trip and a v1 file (absolute pixels, TL/TR/BL/BR) migrated to
## fractions — all against TEMP paths.
##   Godot --headless --path . --script scenes/ui/projection/projection_warp_selftest.gd

const EXPECTED_CHECKS := 21

var _checks := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


func _near(a: Vector2, b: Vector2, eps: float = 1e-4) -> bool:
	return a.distance_to(b) <= eps


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var unit := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	# A projector keystone: wide at the top, narrow at the bottom.
	var keystone := PackedVector2Array([Vector2(100, 50), Vector2(1800, 80), Vector2(1500, 1000), Vector2(350, 980)])
	var h := ProjectionWarp.homography(keystone)
	var corners_ok := true
	for i in 4:
		corners_ok = corners_ok and _near(ProjectionWarp.apply(h, unit[i]), keystone[i], 1e-3)
	_check(corners_ok, "unit-square corners land on the keystone's corners")
	var inv := h.inverse()
	var p := Vector2(0.3, 0.7)
	_check(_near(ProjectionWarp.apply(inv, ProjectionWarp.apply(h, p)), p), "a point round-trips through the inverse")
	var centre := ProjectionWarp.apply(h, Vector2(0.5, 0.5))
	var avg := (keystone[0] + keystone[1] + keystone[2] + keystone[3]) * 0.25
	_check(centre.distance_to(avg) > 5.0, "perspective: the centre is not the corners' average (%.1f px off)" % centre.distance_to(avg))
	# The centre of a perspective quad IS where its diagonals cross.
	var cross: Variant = Geometry2D.line_intersects_line(keystone[0], keystone[2] - keystone[0], keystone[1], keystone[3] - keystone[1])
	_check(cross != null and _near(centre, cross as Vector2, 1e-2), "the centre is where the diagonals cross")
	var para := PackedVector2Array([Vector2(10, 10), Vector2(210, 30), Vector2(230, 130), Vector2(30, 110)])
	var hp := ProjectionWarp.homography(para)
	_check(is_zero_approx(hp.x.z) and is_zero_approx(hp.y.z), "a parallelogram is affine (no perspective terms)")
	_check(_near(ProjectionWarp.apply(hp, Vector2(0.5, 0.5)), Vector2(120, 70)), "affine centre is the average")
	var flat := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(2, 0), Vector2(3, 0)])
	_check(is_zero_approx(ProjectionWarp.homography(flat).determinant()), "a collapsed quad has no homography")
	# The shader's product: a Basis is column-major like a GLSL mat3.
	var col := Basis(Vector3(1, 2, 3), Vector3(4, 5, 6), Vector3(7, 8, 9))
	_check(col * Vector3(1, 0, 0) == Vector3(1, 2, 3), "Basis * v takes the columns (the GLSL mat3 convention)")

	_check(ProjectionWarp.is_valid_quad(keystone), "the keystone is a valid quad")
	var bowtie := PackedVector2Array([Vector2(0, 0), Vector2(1, 1), Vector2(1, 0), Vector2(0, 1)])
	_check(not ProjectionWarp.is_valid_quad(bowtie), "a bow-tie is refused")
	_check(ProjectionWarp.source_region(2, 1) == Rect2(0.5, 0.0, 0.5, 1.0), "two quads: the right half")
	_check(ProjectionWarp.source_region(4, 2) == Rect2(0.0, 0.5, 0.5, 0.5), "four quads: bottom-left")
	var d4 := ProjectionWarp.default_quads(4)
	_check(d4.size() == 4 and (d4[3] as PackedVector2Array)[2] == Vector2(1, 1), "the default 2x2 layout ends at the corner")

	# Config: v2 round trip and the v1 migration.
	var tmp := OS.get_temp_dir().path_join("simbio_warp_selftest")
	DirAccess.make_dir_recursive_absolute(tmp)
	var w := ProjectionWarp.new()
	w.config_path = tmp.path_join("v2.cfg")
	w.quad_count = 2
	get_root().add_child(w)
	w.setup(null)
	_check(not w.has_saved(), "no file, nothing saved")
	w.set_corner(1, 2, Vector2(0.9, 0.8))
	w.set_corner(0, 0, Vector2(-3, 9))
	_check((w.quads()[0] as PackedVector2Array)[0] == Vector2(-0.5, 1.5), "a corner is clamped to half a screen past the edge")
	w.save_config()
	_check(w.has_saved(), "saved")
	var w2 := ProjectionWarp.new()
	w2.config_path = w.config_path
	w2.quad_count = 2
	get_root().add_child(w2)
	w2.setup(null)
	_check(_near((w2.quads()[1] as PackedVector2Array)[2], Vector2(0.9, 0.8)), "v2 round trip keeps the corner")
	var w3 := ProjectionWarp.new()
	w3.config_path = w.config_path
	w3.quad_count = 4
	get_root().add_child(w3)
	w3.setup(null)
	_check(not w3.has_saved(), "a file for another quad count is not applied")

	var v1 := ConfigFile.new()
	v1.set_value("warp", "version", 1)
	v1.set_value("warp", "canvas_size", Vector2(1920, 1080))
	v1.set_value("warp", "TL", PackedVector2Array([Vector2(10, 10), Vector2(954, 10), Vector2(954, 534), Vector2(10, 534)]))
	v1.set_value("warp", "TR", PackedVector2Array([Vector2(966, 20), Vector2(1910, 10), Vector2(1880, 534), Vector2(966, 534)]))
	var v1_path := tmp.path_join("v1.cfg")
	v1.save(v1_path)
	var w4 := ProjectionWarp.new()
	w4.config_path = tmp.path_join("missing.cfg")
	w4.quad_count = 2
	get_root().add_child(w4)
	w4.setup(null)
	w4.load_config(v1_path)
	_check(w4.has_saved(), "a v1 file is read through the legacy path")
	_check(_near((w4.quads()[1] as PackedVector2Array)[0], Vector2(966.0 / 1920.0, 20.0 / 1080.0)), "v1 pixels become fractions of the size they were saved at")
	w4.save_config()
	var back := ConfigFile.new()
	_check(back.load(w4.config_path) == OK and int(back.get_value("warp", "version", 0)) == 2, "saving writes the new file as v2")

	for n in [w, w2, w3, w4]:
		n.free()
	for f in ["v1.cfg", "v2.cfg", "missing.cfg"]:
		DirAccess.remove_absolute(tmp.path_join(f))
	DirAccess.remove_absolute(tmp)

	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("projection_warp_selftest: %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)
