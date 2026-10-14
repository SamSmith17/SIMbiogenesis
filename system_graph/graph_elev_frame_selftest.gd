extends SceneTree

## GraphElevFrame selftest (offline, deterministic).
##
## Pins the one property the Elevation view lost: the circle that bounds the 3D
## section is where the SoI centre actually projects, after every way the
## camera moves — pan, cursor-anchored zoom, and the siphon auto-framing — and
## the section camera's look point is the exact inverse at the container
## centre. Also the silhouette / chord radii for slices on either side of the
## centre, and the ortho floor at maximum zoom.
##
## Carries EXPECTED_CHECKS: a Godot runtime error aborts the enclosing test
## function while the suite would still print PASS.
##
##   Godot --headless --path . --script system_graph/graph_elev_frame_selftest.gd

const EXPECTED_CHECKS := 28

var _checks := 0
var _fails := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps


func _near2(a: Vector2, b: Vector2, eps: float = 1e-3) -> bool:
	return a.distance_to(b) <= eps


func _initialize() -> void:
	_test_identity_frame()
	_test_round_trip()
	_test_pan_moves_soi()
	_test_cursor_zoom_keeps_metre()
	_test_siphon_framing()
	_test_radii()
	_test_container_look()
	_test_ortho_floor()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a function aborted?)" % [
				_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("GRAPH ELEV FRAME SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("GRAPH ELEV FRAME SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


const CANVAS := Vector2(1280.0, 720.0)
const CY := 112.0
const R := 150.0


func _frame(s: float, aa: float, ae: float, d: float = 0.0, ex: float = 1.0) -> Dictionary:
	return GraphElevFrame.make(CANVAS, s, aa, ae, ex, CY, R, d)


func _test_identity_frame() -> void:
	# Anchor = SoI centre → the SoI lands on the canvas centre (the only case
	# the old pinned-to-centre disc was ever right in).
	var f := _frame(4.0, 0.0, CY)
	_check("anchor at SoI centre → SoI at canvas centre",
			_near2(f["soi_px"] as Vector2, CANVAS * 0.5))


func _test_round_trip() -> void:
	var f := _frame(13.7, 42.0, 101.5, 0.0, 5.0)
	for p in [Vector2(0, 0), Vector2(640, 360), Vector2(1279, 3), Vector2(-50, 900)]:
		var m := GraphElevFrame.to_metres(f, p)
		_check("to_screen(to_metres(p)) == p at %s" % str(p),
				_near2(GraphElevFrame.to_screen(f, m.x, m.y), p))


func _test_pan_moves_soi() -> void:
	# A pan is an anchor change; the SoI's screen point must move by exactly
	# the panned pixels (the bug: it stayed put while the image moved).
	var s := 4.0
	var f0 := _frame(s, 0.0, CY)
	var pan_px := Vector2(120.0, -60.0)
	# The canvas's _elev_pan_by_pixels: aa -= dx/s, ae += dy/(s·ex).
	var f1 := _frame(s, 0.0 - pan_px.x / s, CY + pan_px.y / s)
	var moved := (f1["soi_px"] as Vector2) - (f0["soi_px"] as Vector2)
	_check("pan moves the SoI by the panned pixels", _near2(moved, pan_px),
			"moved %s want %s" % [str(moved), str(pan_px)])


func _test_cursor_zoom_keeps_metre() -> void:
	# The canvas's _elev_zoom_at keeps the metre under the cursor fixed; the
	# frame must agree, and the SoI must land where to_screen says.
	var s0 := 4.0
	var s1 := 4.0 * 1.5
	var aa0 := 10.0
	var ae0 := CY + 5.0
	var cursor := Vector2(900.0, 200.0)
	var f0 := _frame(s0, aa0, ae0)
	var m := GraphElevFrame.to_metres(f0, cursor)
	var vc := CANVAS * 0.5
	var aa1 := m.x - (cursor.x - vc.x) / s1
	var ae1 := m.y + (cursor.y - vc.y) / s1
	var f1 := _frame(s1, aa1, ae1)
	_check("cursor metre fixed through zoom",
			_near2(GraphElevFrame.to_screen(f1, m.x, m.y), cursor))
	var want_soi := GraphElevFrame.to_screen(f1, 0.0, CY)
	_check("SoI px follows the zoom", _near2(f1["soi_px"] as Vector2, want_soi))
	_check("off-centre zoom moved the SoI off the canvas centre",
			(f1["soi_px"] as Vector2).distance_to(vc) > 10.0)


func _test_siphon_framing() -> void:
	# frame_elevation_window centres a turbine at along 37 m, elev 96 m: the
	# SoI centre is then well off-screen-centre, exactly the case that broke.
	var s := 40.0
	var f := _frame(s, 37.0, 96.0)
	var soi: Vector2 = f["soi_px"]
	_check("siphon framing: SoI x = vc.x − 37·s", _near(soi.x, 640.0 - 37.0 * s, 1e-3))
	_check("siphon framing: SoI y = vc.y − (CY − 96)·s", _near(soi.y, 360.0 - (CY - 96.0) * s, 1e-3))


func _test_radii() -> void:
	var f0 := _frame(4.0, 0.0, CY, 0.0)
	_check("slice at centre: chord == R", _near(float(f0["chord_m"]), R))
	_check("slice at centre: silhouette == R", _near(float(f0["sil_m"]), R))
	var fp := _frame(4.0, 0.0, CY, 90.0)
	_check("slice toward camera: chord = √(R²−d²)", _near(float(fp["chord_m"]), 120.0))
	_check("slice toward camera: kept half has the equator → silhouette R",
			_near(float(fp["sil_m"]), R))
	var fn := _frame(4.0, 0.0, CY, -90.0)
	_check("slice away from camera: chord = √(R²−d²)", _near(float(fn["chord_m"]), 120.0))
	_check("slice away from camera: a cap → silhouette == chord",
			_near(float(fn["sil_m"]), 120.0))
	_check("sil_px = sil_m · s", _near(GraphElevFrame.sil_px(fn), 480.0))
	_check("chord_px = chord_m · s", _near(GraphElevFrame.chord_px(fp), 480.0))
	var fx := _frame(4.0, 0.0, CY, 9999.0)
	_check("slice clamps to R (chord 0, no NaN)", _near(float(fx["chord_m"]), 0.0))
	_check("clamped d == R", _near(float(fx["d"]), R))


func _test_container_look() -> void:
	# The section camera looks at to_metres(container centre). Disc mode: the
	# container is centred on soi_px → the look point is the SoI centre itself.
	var f := _frame(6.0, -22.0, CY + 14.0)
	var m := GraphElevFrame.to_metres(f, f["soi_px"] as Vector2)
	_check("disc mode: look along == 0", _near(m.x, 0.0, 1e-3))
	_check("disc mode: look elevation == SoI centre", _near(m.y, CY, 1e-3))
	# Crop mode: the container is the canvas → the look point is the anchor.
	var mc := GraphElevFrame.to_metres(f, CANVAS * 0.5)
	_check("crop mode: look along == anchor", _near(mc.x, -22.0, 1e-3))
	_check("crop mode: look elevation == anchor", _near(mc.y, CY + 14.0, 1e-3))
	# Exaggeration only scales the vertical axis.
	var f5 := _frame(6.0, 0.0, CY, 0.0, 5.0)
	var p5 := GraphElevFrame.to_screen(f5, 0.0, CY + 10.0)
	_check("5× exaggeration scales vertical px", _near(p5.y, 360.0 - 10.0 * 6.0 * 5.0, 1e-3))


func _test_ortho_floor() -> void:
	# At ZOOM_MAX (512) px/m = 2048: a 720 px container is 0.35 m tall — above
	# the Lab floor, so 2D and 3D zoom stay locked all the way in.
	var f := _frame(GraphSiteLayout.px_per_m(512.0), 0.0, CY)
	var h := GraphElevFrame.ortho_height_m(f, 720.0)
	_check("ortho height tracks the canvas at max zoom", _near(h, 720.0 / GraphSiteLayout.px_per_m(512.0), 1e-5))
	_check("ortho height never under the Lab floor",
			GraphElevFrame.ortho_height_m(_frame(1e9, 0.0, CY), 720.0) >= GraphSiteLayout.LAB_MIN_ORTHO_H_M)
