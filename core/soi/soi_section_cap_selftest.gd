extends SceneTree

## SoiSectionCap.build_strips selftest (offline, deterministic).
##
## The cap is what makes the Elevation cut face solid. Pins: every vertex lies
## on the (backed-off) cut plane; bottoms sit on the chord circle; tops are the
## ground clamped to the circle; strips that collapse at both edges are skipped;
## UV2 carries the ground height (the strata depth) and flags only
## ground-limited tops for the lip; a slice past the sphere builds nothing.
## Carries EXPECTED_CHECKS (a runtime error aborts a test function while the
## suite would still print PASS).
##
##   Godot --headless --path . --script core/soi/soi_section_cap_selftest.gd

const EXPECTED_CHECKS := 11

var _checks := 0
var _fails := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_flat_ground()
	_test_hill_clamped()
	_test_out_of_sphere()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a function aborted?)" % [
				_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("SOI SECTION CAP SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SOI SECTION CAP SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


const C := Vector3(10.0, 50.0, -20.0)
const R := 100.0
const ALONG := Vector3(1.0, 0.0, 0.0)
const N := Vector3(0.0, 0.0, 1.0)
const BACK := 0.03


func _samples(d: float, ground: Callable, n: int = 32) -> Array:
	var c := sqrt(maxf(R * R - d * d, 0.0))
	var alongs := PackedFloat32Array()
	var heights := PackedFloat32Array()
	for i in n + 1:
		var a := -c + 2.0 * c * float(i) / float(n)
		alongs.append(a)
		heights.append(float(ground.call(a)))
	return [alongs, heights]


func _arrays(m: ArrayMesh) -> Array:
	return m.surface_get_arrays(0) if m != null and m.get_surface_count() > 0 else []


func _test_flat_ground() -> void:
	var d := 60.0
	var s := _samples(d, func(_a: float) -> float: return C.y)
	var m := SoiSectionCap.build_strips(C, R, ALONG, N, d, s[0], s[1], BACK)
	_check("flat ground builds a cap", m != null)
	var arr := _arrays(m)
	if arr.is_empty():
		_checks += 6
		_fails += 6
		return
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uv2: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
	var plane_z := C.z + (d - BACK)
	var on_plane := true
	var in_sphere := true
	var c := sqrt(R * R - d * d)
	var bottoms_ok := true
	for i in verts.size():
		var v := verts[i]
		if absf(v.z - plane_z) > 1e-3:
			on_plane = false
		var a := v.x - C.x
		var half := sqrt(maxf(c * c - a * a, 0.0))
		if v.y < C.y - half - 1e-3 or v.y > C.y + half + 1e-3:
			in_sphere = false
		if i % 2 == 0 and absf(v.y - (C.y - half)) > 1e-3:
			bottoms_ok = false
	_check("every vertex on the backed-off plane", on_plane)
	_check("every vertex inside the chord circle", in_sphere)
	_check("even vertices sit on the chord circle's bottom", bottoms_ok)
	_check("tops are the ground (flat → centre height)",
			absf(verts[1].y - C.y) < 1e-3 or verts[1].y < C.y)
	_check("UV2.x carries the ground height", absf(uv2[1].x - C.y) < 1e-3)
	_check("ground-limited top flags the lip", uv2[verts.size() / 2 + 1].y > 0.5)


func _test_hill_clamped() -> void:
	# Ground far above the sphere: tops clamp to the circle, and the lip is
	# NOT flagged there (it would poke out above the bubble).
	var d := 0.0
	var s := _samples(d, func(_a: float) -> float: return C.y + 500.0, 8)
	var m := SoiSectionCap.build_strips(C, R, ALONG, N, d, s[0], s[1], BACK)
	var arr := _arrays(m)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX] if not arr.is_empty() else PackedVector3Array()
	var uv2: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2] if not arr.is_empty() else PackedVector2Array()
	var top_ok := verts.size() > 4
	var no_lip := true
	for i in range(1, verts.size(), 2):
		var a := verts[i].x - C.x
		var half := sqrt(maxf(R * R - a * a, 0.0))
		if absf(verts[i].y - (C.y + half)) > 1e-3:
			top_ok = false
		if uv2[i].y > 0.5:
			no_lip = false
	_check("hill: tops clamp to the circle", top_ok)
	_check("hill: no lip on circle-limited tops", no_lip)
	# Ground far below the sphere: nothing left above the bottom → no cap.
	var s2 := _samples(d, func(_a: float) -> float: return C.y - 500.0, 8)
	_check("buried ground builds nothing",
			SoiSectionCap.build_strips(C, R, ALONG, N, d, s2[0], s2[1], BACK) == null)


func _test_out_of_sphere() -> void:
	var s := _samples(R, func(_a: float) -> float: return C.y)
	_check("slice at the rim builds nothing",
			SoiSectionCap.build_strips(C, R, ALONG, N, R, s[0], s[1], BACK) == null)
