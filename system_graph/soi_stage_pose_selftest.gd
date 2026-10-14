extends SceneTree

## SoiStagePose selftest (offline, deterministic) — the lens-transition maths.
##
## Pins: the endpoints of a transition are exactly the two lens poses; the
## dolly-zoom keeps the frame height at the look point while the FOV narrows;
## at ortho_w 1 the camera is truly orthographic at the pose's size; a 0.2°
## perspective projects within half a pixel of the orthographic one (so the
## final switch is invisible); a Plan → Section move swings through
## perspective mid-way (the bulge); antipodal directions do not NaN.
## Carries EXPECTED_CHECKS.
##
##   Godot --headless --path . --script system_graph/soi_stage_pose_selftest.gd

const EXPECTED_CHECKS := 15

var _checks := 0
var _fails := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_endpoints()
	_test_dolly_zoom()
	_test_ortho_end_and_invisible_switch()
	_test_bulge_and_antipodal()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a function aborted?)" % [
				_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("SOI STAGE POSE SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SOI STAGE POSE SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _plan() -> Dictionary:
	return SoiStagePose.make(Vector3(5, 100, -3), Vector3.UP, Vector3.FORWARD, 120.0,
			true, 68.0, 60.0)


func _section() -> Dictionary:
	return SoiStagePose.make(Vector3(0, 95, 0), Vector3(0, 0, 1), Vector3.UP, 90.0,
			true, 68.0, 170.0)


func _globe() -> Dictionary:
	return SoiStagePose.make(Vector3(0, 100, 0), Vector3(0.6, 0.3, 0.5), Vector3.UP, 140.0,
			false, 68.0, 330.0)


func _test_endpoints() -> void:
	var a := _plan()
	var b := _globe()
	var p0 := SoiStagePose.lerp_pose(a, b, 0.0, 0.8)
	var p1 := SoiStagePose.lerp_pose(a, b, 1.0, 0.8)
	_check("t=0 is the source pose", (p0["look"] as Vector3).is_equal_approx(a["look"])
			and is_equal_approx(float(p0["half_h"]), float(a["half_h"]))
			and is_equal_approx(float(p0["ortho_w"]), 1.0))
	_check("t=1 is the target pose", (p1["dir"] as Vector3).is_equal_approx(b["dir"])
			and is_equal_approx(float(p1["half_h"]), float(b["half_h"]))
			and is_equal_approx(float(p1["ortho_w"]), 0.0))


func _test_dolly_zoom() -> void:
	# As ortho_w rises the FOV narrows and the camera backs off so the frame
	# height at the look point is constant.
	var p := _globe()
	var ok := true
	var last_d := 0.0
	for w in [0.0, 0.25, 0.5, 0.75, 0.95]:
		p["ortho_w"] = w
		var d := SoiStagePose.camera_distance(p)
		var h := d * tan(deg_to_rad(SoiStagePose.effective_fov(p)) * 0.5)
		if absf(h - float(p["half_h"])) > float(p["half_h"]) * 0.01:
			ok = false
		if d < last_d:
			ok = false
		last_d = d
	_check("dolly-zoom keeps the frame height (±1 %) and backs off", ok)
	p["ortho_w"] = 0.0
	_check("w=0 → the lens FOV", is_equal_approx(SoiStagePose.effective_fov(p), 68.0))


func _test_ortho_end_and_invisible_switch() -> void:
	var cam := Camera3D.new()
	var p := _section()
	SoiStagePose.apply(cam, p, 150.0)
	_check("w=1 → orthographic", cam.projection == Camera3D.PROJECTION_ORTHOGONAL)
	_check("ortho size = 2·half_h", is_equal_approx(cam.size, 180.0))
	# A 1° perspective image vs the orthographic one: project points across the
	# frame and compare in pixels at 1280×720 (pure maths — no viewport).
	var look: Vector3 = p["look"]
	var basis := SoiStagePose.basis_for(p)
	var half_h := float(p["half_h"])
	var aspect := 1280.0 / 720.0
	var worst := 0.0
	var p1 := p.duplicate()
	p1["ortho_w"] = 0.998  # just under the true-ortho switch (0.999)
	var d := SoiStagePose.camera_distance(p1)
	var eye := look + (p["dir"] as Vector3) * d
	var t := tan(deg_to_rad(SoiStagePose.effective_fov(p1)) * 0.5)
	for q: Vector3 in [Vector3(80, 60, 0), Vector3(-120, -40, 30), Vector3(10, 85, -60)]:
		var wpt := look + basis.x * q.x + basis.y * q.y + basis.z * q.z
		var v := basis.inverse() * (wpt - eye)
		var ndc_p := Vector2(v.x / (-v.z * t * aspect), v.y / (-v.z * t))
		var vo := basis.inverse() * (wpt - look)
		var ndc_o := Vector2(vo.x / (half_h * aspect), vo.y / half_h)
		worst = maxf(worst, ((ndc_p - ndc_o) * Vector2(640.0, 360.0)).length())
	_check("near-ortho perspective within 0.5 px of orthographic", worst < 0.5, "worst %.3f px" % worst)
	# Camera3D refuses fov < 1° (set_fov errors and keeps the old value), so a
	# near-ortho pose must reach the camera as an equivalent FRUSTUM: same
	# effective FOV, read back intact by from_camera. The maths above never
	# touched a camera, which is how the 0.2° dolly shipped broken.
	SoiStagePose.apply(cam, p1, 150.0)
	_check("sub-1° pose drawn as a FRUSTUM", cam.projection == Camera3D.PROJECTION_FRUSTUM)
	# (from_camera's own frustum branch uses this same size/near identity; the
	# camera is not in a tree here, so its global transform cannot be read.)
	var back_fov := rad_to_deg(2.0 * atan(cam.size * 0.5 / cam.near))
	_check("frustum carries the pose's FOV", absf(back_fov - SoiStagePose.effective_fov(p1)) < 1e-3,
		"%.4f vs %.4f" % [back_fov, SoiStagePose.effective_fov(p1)])
	var p_wide := p.duplicate()
	p_wide["ortho_w"] = 0.2
	SoiStagePose.apply(cam, p_wide, 150.0)
	_check("a >= 1° pose stays a plain perspective", cam.projection == Camera3D.PROJECTION_PERSPECTIVE
		and absf(cam.fov - SoiStagePose.effective_fov(p_wide)) < 1e-3)
	cam.free()


func _test_bulge_and_antipodal() -> void:
	var mid := SoiStagePose.lerp_pose(_plan(), _section(), 0.5, 0.8)
	_check("plan → section bulges through perspective mid-way",
			float(mid["ortho_w"]) < 0.5, "w=%.2f" % float(mid["ortho_w"]))
	_check("mid-way FOV is a real perspective (> 20°)",
			SoiStagePose.effective_fov(mid) > 20.0)
	var down := SoiStagePose.make(Vector3.ZERO, Vector3.DOWN, Vector3.FORWARD, 10.0, true, 68.0, 20.0)
	var upp := SoiStagePose.make(Vector3.ZERO, Vector3.UP, Vector3.FORWARD, 10.0, true, 68.0, 20.0)
	var m2 := SoiStagePose.lerp_pose(down, upp, 0.5)
	var dv: Vector3 = m2["dir"]
	_check("antipodal dirs interpolate without NaN", is_finite(dv.x) and is_finite(dv.y)
			and is_finite(dv.z) and absf(dv.length() - 1.0) < 1e-3)
	var b := SoiStagePose.basis_for(m2)
	_check("basis stays orthonormal", absf(b.determinant() - 1.0) < 1e-3)
	_check("ease is 0 → 1 smooth", is_equal_approx(SoiStagePose.ease_t(0.0), 0.0)
			and is_equal_approx(SoiStagePose.ease_t(1.0), 1.0)
			and is_equal_approx(SoiStagePose.ease_t(0.5), 0.5))
