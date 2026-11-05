extends SceneTree

## Concentrator designer self-test (offline). Run --import first:
##   Godot --headless --path . --script core/csplab/csplab_selftest.gd
## Pins the optics against hand-computed numbers (Snell, Fresnel at normal
## incidence, a plano-convex lens's and a ball lens's paraxial focus, a
## Fresnel facet sending its ray to the focus, the parabola's focus), the
## energy bookkeeping (losses + captured = 1 for every type), the efficiency
## trends (bigger receiver catches more, errors spill, one-axis end loss
## grows with incidence, the tower's poleward heliostats beat the
## equatorward ones), the site DNI-only model, structure sums by hand, the
## optimizer improving, every preset solving with no error-level check, and
## every builder triangle wound clockwise from its normal side.

const EXPECTED_CHECKS := 234

var _pass := 0
var _fail := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (got %.6f, want %.6f ± %.6f)" % [what, a, b, tol])


func _initialize() -> void:
	_test_vector_optics()
	_test_spec()
	_test_dish()
	_test_lenses()
	_test_line_focus()
	_test_cpc()
	_test_fields()
	_test_bookkeeping()
	_test_thermal()
	_test_site()
	_test_structure()
	_test_optimizer()
	_test_presets()
	_test_builder()
	_test_placed_type()
	_test_water_lens_level()
	_test_actuators()
	_test_mirror_and_glow()
	_test_perf_paths()
	print("csplab selftest: %d passed, %d failed (%d expected)" % [_pass, _fail, EXPECTED_CHECKS])
	if _fail == 0 and _pass == EXPECTED_CHECKS:
		print("PASS csplab_selftest")
	else:
		print("FAILURE csplab_selftest")
	quit(0 if _fail == 0 else 1)


func _test_vector_optics() -> void:
	# Normal incidence glass: R = ((n−1)/(n+1))² = 0.04 for n = 1.5.
	_near(CspLabOptics.fresnel_r(1.0, 1.0, 1.0, 1.5), 0.04, 1e-9, "Fresnel R at normal incidence")
	# Snell: 30° into n = 1.5 → sin θt = 0.5/1.5.
	var d := Vector3(sin(deg_to_rad(30.0)), -cos(deg_to_rad(30.0)), 0)
	var t := CspLabOptics.refract(d, Vector3.UP, 1.0, 1.5)
	_near(t.x, 0.5 / 1.5, 1e-6, "Snell sin θt")
	_ok(t.y < 0.0, "refracted ray keeps going down")
	# Total internal reflection past the critical angle (n 1.5 → 1, 45°).
	var d2 := Vector3(sin(deg_to_rad(45.0)), -cos(deg_to_rad(45.0)), 0)
	_ok(CspLabOptics.refract(d2, Vector3.UP, 1.5, 1.0) == Vector3.ZERO, "TIR past the critical angle")
	var r := CspLabOptics.reflect(Vector3(1, -1, 0).normalized(), Vector3.UP)
	_near(r.y, sqrt(0.5), 1e-6, "mirror reflection")
	# A Fresnel facet sends a vertical ray (inside the sheet) to the focus.
	var n := 1.494
	var al := CspLabOptics.facet_angle(0.3, 1.0, n)
	var out := CspLabOptics.refract(Vector3.DOWN, Vector3(sin(al), -cos(al), 0), n, 1.0)
	_near(atan2(-out.x, -out.y), atan2(0.3, 1.0), 1e-5, "Fresnel facet aims at the focus")
	var bw := 0.0
	for b in CspLabParts.BANDS:
		bw += float((b as Dictionary)["w"])
	_near(bw, 1.0, 1e-9, "band weights sum to 1")


func _test_spec() -> void:
	for t in CspLabSpec.TYPES:
		var s := CspLabSpec.resolve({"type": t})
		_ok(str(s["type"]) == t, "resolve keeps %s" % t)
	var s2 := CspLabSpec.resolve({"type": "lens", "optic": {"focal_m": 1.234567891}})
	var j := CspLabSpec.to_json_safe(s2)
	var back: Variant = JSON.parse_string(JSON.stringify(j))
	_ok(CspLabSpec.key_of(back as Dictionary) == CspLabSpec.key_of(s2), "key survives a JSON round trip")
	_ok(str(CspLabSpec.resolve({"type": "tower", "tracking": {"mode": "fixed"}})["tracking"]["mode"]) == "two_axis", "a tower always tracks per heliostat")
	_ok(str(CspLabSpec.resolve({"type": "nonsense"})["type"]) == "parabolic_dish", "an unknown type falls back")


func _ideal(spec: Dictionary) -> Dictionary:
	var s := CspLabSpec.resolve(spec)
	(s["trace"] as Dictionary)["slope_err_mrad"] = 0.0
	(s["trace"] as Dictionary)["sun_half_mrad"] = 0.0
	(s["tracking"] as Dictionary)["error_mrad"] = 0.0
	return s


func _test_dish() -> void:
	# A perfect dish with a point sun focuses every ray: the paraboloid's
	# focus is at f. Rays near the axis land within micrometres.
	var s := _ideal({"type": "parabolic_dish", "optic": {"aperture_m": 2.0, "focal_m": 0.9, "reflector": "silvered_glass"},
		"receiver": {"kind": "flat", "size_m": 0.004}})
	var g := CspLabOptics.geometry(s)
	var tr := CspLabOptics.trace(g, Vector3.UP, 1500, {"seed": 1})
	_near(float(tr["intercept"]), 1.0, 1e-6, "ideal dish intercepts everything")
	_near(float(tr["captured"]) + float(tr["losses"]["reflect"]) + float(tr["losses"]["shading"]), 1.0, 1e-6, "ideal dish: captured + ρ loss + shading")
	_near(float(tr["losses"]["reflect"]) / (1.0 - float(tr["losses"]["shading"])), 0.06, 1e-6, "silvered glass loses 6 %")
	# Sun shape: a 4.65 mrad sun on a dish spreads the image to ≈ 2 f θs/cos²ψ:
	# a 4 mm receiver now spills, a 3 cm one catches it.
	var s2 := CspLabSpec.resolve({"type": "parabolic_dish", "optic": {"aperture_m": 2.0, "focal_m": 0.9},
		"receiver": {"kind": "flat", "size_m": 0.004}, "trace": {"slope_err_mrad": 0.0}, "tracking": {"error_mrad": 0.0}})
	var small := float(CspLabOptics.trace(CspLabOptics.geometry(s2), Vector3.UP, 2000, {})["intercept"])
	(s2["receiver"] as Dictionary)["size_m"] = 0.03
	var big := float(CspLabOptics.trace(CspLabOptics.geometry(s2), Vector3.UP, 2000, {})["intercept"])
	_ok(small < 0.6 and big > 0.97, "the sun's disc spills a pinhole receiver (%.2f) and fills a 3 cm one (%.2f)" % [small, big])
	# Slope error spills more.
	(s2["trace"] as Dictionary)["slope_err_mrad"] = 6.0
	var rough := float(CspLabOptics.trace(CspLabOptics.geometry(s2), Vector3.UP, 2000, {})["intercept"])
	_ok(rough < big, "slope error spills (%.3f < %.3f)" % [rough, big])
	_near(float(CspLabOptics.geometry(s)["rim_deg"]), rad_to_deg(2.0 * atan(1.0 / 1.8)), 1e-6, "rim angle 2·atan(a/2f)")
	_ok(float(g["C_limit"]) > 40000.0, "point-focus limit 1/sin²θs ≈ 46 000")


func _test_lenses() -> void:
	# Plano-convex: paraxial rays meet at the back focal length f − t/n.
	var s := _ideal({"type": "lens", "optic": {"aperture_m": 0.2, "focal_m": 0.5, "material": "bk7", "thickness_mm": 3.0},
		"receiver": {"size_m": 0.002}})
	var g := CspLabOptics.geometry(s)
	var paths := CspLabOptics.trace_section(g, Vector3.UP, 12, {"bands": [0]})
	var focus := _crossing(paths, 0.08)
	_near(focus, 0.0, 0.003, "plano-convex paraxial focus at the receiver (y = 0)")
	_near(float(g["bfl"]), 0.5 - float(g["tc"]) / CspLabParts.n_of("bk7", 0), 1e-9, "BFL = f − t/n")
	# Ball lens: paraxial focus f = nR / 2(n − 1) from the centre.
	var s2 := _ideal({"type": "ball_lens", "optic": {"aperture_m": 0.3, "material": "water"}, "receiver": {"size_m": 0.002}})
	var g2 := CspLabOptics.geometry(s2)
	var nw := CspLabParts.n_of("water", 0)
	_near(float(g2["f"]), nw * 0.15 / (2.0 * (nw - 1.0)), 1e-9, "ball lens f = nR/2(n−1)")
	var focus2 := _crossing(CspLabOptics.trace_section(g2, Vector3.UP, 12, {"bands": [0]}), 0.06)
	_near(focus2, 0.0, 0.004, "ball lens paraxial focus at its BFL")
	# Spherical aberration: rim rays cross well before the paraxial focus.
	var rim := _crossing(CspLabOptics.trace_section(g2, Vector3.UP, 12, {"bands": [0]}), 0.9)
	_ok(rim > 0.02, "a ball lens's rim rays focus short (%.3f m above the paraxial focus)" % rim)
	# Water drinks the infrared: the SWIR band barely gets through 15 cm.
	var s3 := CspLabSpec.resolve({"type": "water_lens"})
	var tr3 := CspLabOptics.trace(CspLabOptics.geometry(s3), Vector3.UP, 3000, {})
	var bc: PackedFloat64Array = tr3["band_captured"]
	_ok(bc[3] < bc[0] * 0.1, "a water lens passes far less SWIR than visible light")
	_ok(float(tr3["losses"]["absorb"]) > 0.08, "a water lens absorbs > 8 %% (%.3f)" % float(tr3["losses"]["absorb"]))
	# Fresnel lens: dispersion — the visible band focuses at the design point,
	# the infrared (lower n) focuses further.
	var s4 := _ideal({"type": "fresnel_lens", "optic": {"aperture_m": 0.6, "focal_m": 0.6, "square": false}, "receiver": {"size_m": 0.002}})
	var g4 := CspLabOptics.geometry(s4)
	var f_vis := _crossing(CspLabOptics.trace_section(g4, Vector3.UP, 16, {"bands": [0]}), 0.6)
	var f_ir := _crossing(CspLabOptics.trace_section(g4, Vector3.UP, 16, {"bands": [3]}), 0.6)
	_near(f_vis, 0.0, 0.003, "Fresnel lens focuses visible light at its design focus")
	_ok(f_ir < f_vis - 0.002, "Fresnel lens: infrared focuses beyond the visible (%.4f vs %.4f)" % [f_ir, f_vis])
	var tr4 := CspLabOptics.trace(CspLabOptics.geometry(CspLabSpec.resolve({"type": "fresnel_lens"})), Vector3.UP, 3000, {})
	_ok(float(tr4["losses"]["grooves"]) > 0.005, "grooves cost something")
	_ok(bool(CspLabOptics.geometry(CspLabSpec.resolve({"type": "lens", "optic": {"aperture_m": 1.0, "focal_m": 0.3}}))["too_fast"]), "a lens faster than a hemisphere is flagged")


## Where the section rays leaving at |x| fraction ≈ `frac` of the aperture
## cross the axis (y); NAN if none. Uses the last two points of each path.
func _crossing(paths: Array, frac: float) -> float:
	var best := NAN
	var best_d := INF
	var xmax := 0.0
	for p in paths:
		var pts: PackedVector3Array = (p as Dictionary)["pts"]
		if pts.size() >= 2:
			xmax = maxf(xmax, absf(pts[1].x))
	for p in paths:
		var pts2: PackedVector3Array = (p as Dictionary)["pts"]
		if pts2.size() < 3:
			continue
		var x0 := absf(pts2[1].x)
		if absf(x0 / maxf(xmax, 1e-9) - frac) > best_d:
			continue
		var a := pts2[pts2.size() - 2]
		var b := pts2[pts2.size() - 1]
		if absf(b.x - a.x) < 1e-9 or signf(a.x) == signf(b.x) and absf(b.x) > absf(a.x):
			continue
		var tt := -a.x / (b.x - a.x)
		best = a.y + (b.y - a.y) * tt
		best_d = absf(x0 / maxf(xmax, 1e-9) - frac)
	return best


func _test_line_focus() -> void:
	var s := CspLabSpec.resolve({"type": "parabolic_trough"})
	var g := CspLabOptics.geometry(s)
	_near(float(g["C_g"]), 1.5 / (PI * 0.035), 1e-6, "trough C = W / πd")
	_ok(float(g["C_limit"]) > 200.0 and float(g["C_limit"]) < 230.0, "line-focus limit 1/sin θs ≈ 215")
	var d := CspLabDesign.solve(s)
	var e0 := CspLabDesign.iam(d, 0.0)
	var e30 := CspLabDesign.iam(d, 30.0)
	var e60 := CspLabDesign.iam(d, 60.0)
	_ok(e0 > e30 and e30 > e60, "one-axis efficiency falls with incidence (%.3f > %.3f > %.3f)" % [e0, e30, e60])
	var tr := CspLabOptics.trace(g, Vector3(0, cos(deg_to_rad(40.0)), sin(deg_to_rad(40.0))), 3000, {})
	_ok(float(tr["losses"]["end"]) > 0.005, "an off-axis sun loses light off the end of the tube")
	_near(float(tr["losses"]["cosine"]), 1.0 - cos(deg_to_rad(40.0)), 0.01, "trough cosine loss at 40°")
	# Linear Fresnel: noon at the equator, every mirror sends the centre ray
	# to the receiver (ideal surfaces, wide receiver).
	var s2 := _ideal({"type": "linear_fresnel", "receiver": {"kind": "flat", "size_m": 0.45}, "optic": {"curved": false}})
	var g2 := CspLabOptics.geometry(s2)
	var tr2 := CspLabOptics.trace(g2, Vector3.UP, 2000, {"seed": 4})
	_ok(float(tr2["intercept"]) > 0.95, "linear Fresnel rows aim at the receiver (%.3f)" % float(tr2["intercept"]))
	_ok(float(tr2["losses"]["cosine"]) > 0.0, "linear Fresnel rows pay a cosine loss at noon")


func _test_cpc() -> void:
	var r := 0.05
	var ta := deg_to_rad(15.0)
	# The two halves of the string drawing join with no jump: the involute
	# (string unwrapping off the pipe) and the parabola (the square moving).
	var tj := ta + PI * 0.5
	_near(CspLabCpc.tube_rho(r, ta, tj - 1e-7), CspLabCpc.tube_rho(r, ta, tj + 1e-7), 1e-6, "involute meets parabola")
	_near(CspLabCpc.tube_point(r, ta, 0.0).distance_to(Vector2(0, -r)), 0.0, 1e-9, "the cusp touches the bottom of the tube")
	# A full tube CPC: aperture 2πr / sin θa, so C = 1 / sin θa (Rabl 1976).
	var full := CspLabCpc.tube_profile(r, ta, 0.0)
	_near(float(full["aperture_half"]), PI * r / sin(ta), 1e-6, "full tube CPC aperture = πr / sin θa")
	var lo := 0.0
	for q in (full["right"] as PackedVector2Array):
		lo = minf(lo, q.y)
	_ok(lo < -0.1 * r, "the wall dips below the cusp beside the tube (the W)")
	# Flat CPC: starts at the absorber edge, aperture a / sin θa, the top
	# tangent parallel to the axis, the edge on its parabola (f = a(1+sin θa)).
	var fl := CspLabCpc.flat_profile(0.05, deg_to_rad(20.0), 0.0)
	var fr: PackedVector2Array = fl["right"]
	_near(fr[0].distance_to(Vector2(0.05, 0.0)), 0.0, 1e-6, "flat CPC wall starts at the absorber edge")
	_near(float(fl["aperture_half"]), 0.05 / sin(deg_to_rad(20.0)), 1e-6, "flat CPC aperture = a / sin θa")
	var tt := (fr[fr.size() - 1] - fr[fr.size() - 2]).normalized()
	_ok(absf(tt.x) < 0.03, "flat CPC top tangent parallel to the axis")
	# Truncation keeps the width/height trade honest.
	var half := CspLabCpc.tube_profile(r, ta, 0.5)
	_ok(float(half["height"]) < float(full["height"]) * 0.6 and float(half["aperture_half"]) > float(full["aperture_half"]) * 0.75,
		"cutting half the height keeps most of the aperture (%.3f of %.3f)" % [float(half["aperture_half"]), float(full["aperture_half"])])
	# Acceptance by tracing: an ideal full CPC (perfect mirror, point sun)
	# puts EVERY entering ray inside ±θa on the tube and turns most of the
	# rays well outside it back out.
	for prof in ["cpc_tube", "cpc_flat"]:
		var s := _ideal({"type": "parabolic_trough", "optic": {"profile": prof, "accept_deg": 30.0, "truncate": 0.0,
			"length_m": 200.0, "reflector": "silvered_glass"}, "receiver": {"size_m": 0.1, "gap_mm": 0.0}})
		var g := CspLabOptics.geometry(s)
		_ok(bool(g["cpc"]), "%s geometry" % prof)
		_near(float(g["C_g"]), float(g["C_ideal"]), float(g["C_ideal"]) * 0.01, "%s full: C = 1 / sin θa" % prof)
		for deg in [0.0, 8.0, 12.0]:
			var tr := CspLabOptics.trace(g, Vector3(sin(deg_to_rad(deg)), cos(deg_to_rad(deg)), 0), 1500, {"seed": 2})
			_ok(float(tr["intercept"]) > 0.985, "%s takes the sun %.0f° across (%.3f)" % [prof, deg, float(tr["intercept"])])
		var tr2 := CspLabOptics.trace(g, Vector3(sin(deg_to_rad(25.0)), cos(deg_to_rad(25.0)), 0), 1500, {"seed": 2})
		_ok(float(tr2["intercept"]) < 0.5, "%s rejects most of the sun at 25° across (%.3f)" % [prof, float(tr2["intercept"])])
		var bk := 0.0
		for k in (tr2["losses"] as Dictionary):
			bk += float((tr2["losses"] as Dictionary)[k])
		_near(bk + float(tr2["captured"]), 1.0, 1e-6, "%s: losses + captured = 1 with bounces" % prof)
	# The gap under the pipe costs light.
	var sg := CspLabSpec.resolve({"type": "parabolic_trough", "optic": {"profile": "cpc_tube"}, "receiver": {"size_m": 0.06, "gap_mm": 0.0}})
	var sg2 := CspLabSpec.resolve({"type": "parabolic_trough", "optic": {"profile": "cpc_tube"}, "receiver": {"size_m": 0.06, "gap_mm": 15.0}})
	_ok(float(CspLabDesign.solve(sg2)["eta_capture"]) < float(CspLabDesign.solve(sg)["eta_capture"]), "a gap under the pipe loses light")
	# A CPC takes part of a cloudy sky: diffuse up to 1/C.
	var dc := CspLabDesign.solve(CspLabPresets.by_id("cpc_pipe"))
	var hd := CspLabSite.heat_w(dc, 0.0, 200.0, 0.0, 25.0)
	_ok(float(hd["diffuse_w"]) > 200.0 * float(dc["A_ap"]) * 0.1, "a CPC keeps a share of the cloudy sky (%.0f W)" % float(hd["diffuse_w"]))
	_ok(CspLabSpec.opt_params(dc["spec"] as Dictionary)[0][1] == "accept_deg", "a CPC optimizes its acceptance angle")
	var svg := CspLabCpc.svg_template((dc["geo"]["cpc_prof"] as Dictionary)["right"], {"kind": "tube", "y": 0.033, "r": 0.03}, deg_to_rad(15.0), "t")
	_ok(svg.begins_with("<?xml") and svg.contains("<path"), "the template is an SVG with the profile")


func _test_fields() -> void:
	var s := CspLabSpec.resolve({"type": "tower", "site": {"lat_deg": 35.0}})
	var g := CspLabOptics.geometry(s)
	_ok(int(g["count"]) == 60, "the field places 60 heliostats")
	var poleward := 0
	for c in (g["centres"] as PackedVector3Array):
		if c.z < 0.0:
			poleward += 1
	_ok(poleward == int(g["count"]), "a poleward field in the north is north of the tower")
	# Cosine: at noon a heliostat north of the tower faces the sun more
	# squarely than one south of it would.
	var sun := CspLabSite.design_sun(35.0)
	var aim := Vector3(0, 15, 0)
	var n_n := (sun + (aim - Vector3(0, 1.6, -20)).normalized()).normalized()
	var n_s := (sun + (aim - Vector3(0, 1.6, 20)).normalized()).normalized()
	_ok(sun.dot(n_n) > sun.dot(n_s), "poleward heliostats have the better cosine")
	var d := CspLabDesign.solve(s)
	_ok(float(d["eta_capture"]) > 0.4 and float(d["eta_capture"]) < 0.95, "the field captures a plausible share (%.3f)" % float(d["eta_capture"]))
	_ok(float((d["trace"] as Dictionary)["losses"]["attenuation"]) > 0.0, "air between heliostat and receiver costs a little")
	var s2 := CspLabSpec.resolve({"type": "tower", "optic": {"row_spacing": 1.1}})
	var s3 := CspLabSpec.resolve({"type": "tower", "optic": {"row_spacing": 2.6}})
	var l2: Dictionary = CspLabDesign.solve(s2, {"light": true})["trace"]["losses"]
	var l3: Dictionary = CspLabDesign.solve(s3, {"light": true})["trace"]["losses"]
	_ok(float(l2["shading"]) + float(l2["blocking"]) > float(l3["shading"]) + float(l3["blocking"]), "tighter rows shade and block more")


func _test_bookkeeping() -> void:
	for t in CspLabSpec.TYPES:
		var d := CspLabDesign.solve({"type": t}, {"light": true, "rays": 1500})
		var tr: Dictionary = d["trace"]
		var sum := float(tr["captured"])
		for k in (tr["losses"] as Dictionary):
			sum += float((tr["losses"] as Dictionary)[k])
		_near(sum, 1.0, 1e-6, "%s: losses + captured = 1" % t)


func _test_thermal() -> void:
	var d := CspLabDesign.solve({"type": "parabolic_dish"})
	_ok(float(d["stagnation_c"]) > float(d["spec"]["site"]["op_temp_c"]), "the dish stagnates above its working temperature")
	_near(float(d["q_beam_kw"]), 0.9 * PI, 1e-6, "beam on a 2 m dish at 900 W/m²")
	_ok(float(d["q_useful_kw"]) <= float(d["q_abs_kw"]), "useful ≤ absorbed")
	var hot := CspLabSpec.resolve({"type": "parabolic_dish", "site": {"op_temp_c": 900.0}})
	_ok(float(CspLabDesign.solve(hot)["eta_th"]) < float(d["eta_th"]), "a hotter receiver loses more")
	var sel := CspLabSpec.resolve({"type": "parabolic_trough"})
	var pnt := CspLabSpec.resolve({"type": "parabolic_trough", "receiver": {"coating": "black_paint", "envelope": false}})
	_ok(float(CspLabDesign.solve(sel)["q_loss_kw"]) < float(CspLabDesign.solve(pnt)["q_loss_kw"]) * 0.3, "a selective evacuated tube loses far less than black paint in air")
	# Steam: 1 kW boils 3600 / (4.186·80 + 2257) kg/h.
	_near(CspLabSite.steam_kg_h(d, 1.0), 3600.0 / (4.186 * 80.0 + 2257.0), 1e-9, "steam per kW")
	var cold := CspLabSpec.resolve({"type": "parabolic_dish", "site": {"op_temp_c": 80.0}})
	_near(CspLabSite.steam_kg_h(CspLabDesign.solve(cold), 1.0), 0.0, 1e-9, "no steam below 100 °C")


func _test_site() -> void:
	var s := CspLabSite.sun_world(180.0, 30.0)
	_near(s.z, cos(deg_to_rad(30.0)), 1e-6, "sun due south is +Z")
	var ae := CspLabSite.az_el(CspLabSite.sun_world(123.0, 41.0))
	_near(ae.x, 123.0, 1e-4, "az round trip")
	_near(ae.y, 41.0, 1e-4, "el round trip")
	# Poses put the sun where the tracker says.
	var spec := CspLabSpec.resolve({"type": "parabolic_dish"})
	var sw := CspLabSite.sun_world(140.0, 35.0)
	var p := CspLabSite.pose(spec, sw, 40.0)
	_ok((p["sun_local"] as Vector3).distance_to(Vector3.UP) < 1e-5, "az-el pose faces the sun")
	(spec["structure"] as Dictionary)["mount"] = "polar_mount"
	var p2 := CspLabSite.pose(spec, sw, 40.0)
	_ok((p2["sun_local"] as Vector3).distance_to(Vector3.UP) < 1e-5, "polar pose faces the sun")
	var tspec := CspLabSpec.resolve({"type": "parabolic_trough"})
	var p3 := CspLabSite.pose(tspec, sw, 40.0)
	var sl: Vector3 = p3["sun_local"]
	_near(sl.x, 0.0, 1e-6, "a one-axis tracker zeroes the transverse angle")
	_near(sl.z, sw.z, 1e-6, "the longitudinal angle is the sun's along the N–S axis")
	_ok(absf((p3["basis"] as Basis).determinant() - 1.0) < 1e-5, "poses are proper rotations")
	# DNI only: an overcast day (cloud 1, no measured data) kills the beam
	# and a concentrator's output with it; the same day still has GHI.
	var d := CspLabDesign.solve({"type": "parabolic_dish"})
	var clear := CspLabSite.output_now(d, CspLabSite.sun_world(180.0, 60.0), {"cloud": 0.0}, 35.0)
	var cloudy := CspLabSite.output_now(d, CspLabSite.sun_world(180.0, 60.0), {"cloud": 1.0}, 35.0)
	_ok(float(clear["thermal_kw"]) > 1.0, "clear noon makes heat (%.2f kW)" % float(clear["thermal_kw"]))
	_ok(float(cloudy["thermal_kw"]) < float(clear["thermal_kw"]) * 0.25, "an overcast sky starves a concentrator")
	_ok(float(cloudy["dhi"]) > 0.0, "the overcast sky still has diffuse light")
	_near(float(CspLabSite.output_now(d, CspLabSite.sun_world(0.0, -5.0), {}, 35.0)["thermal_kw"]), 0.0, 1e-9, "nothing at night")
	# A low-C lens catches a little diffuse light; a dish catches none to speak of.
	var lens := CspLabDesign.solve({"type": "fresnel_lens"})
	var hl := CspLabSite.heat_w(lens, 0.0, 300.0, 0.0, 25.0)
	_ok(float(hl["diffuse_w"]) > 0.0 and float(hl["diffuse_w"]) < 300.0 * float(lens["A_ap"]) / float(lens["C_g"]) + 1e-6, "diffuse accepted ≤ 1/C")
	var yr := CspLabSite.Year.new(d, 33.0, -115.0, 2026, null)
	yr.day_step = 10
	var guard := 0
	while not yr.step(50.0) and guard < 1000:
		guard += 1
	var res := yr.result()
	_ok(float(res["annual_kwh"]) > 1000.0, "a 2 m dish makes over a MWh of heat a year in the desert (%.0f kWh)" % float(res["annual_kwh"]))
	_ok(float(res["annual_dni"]) > 1500.0 and float(res["annual_dni"]) < 4000.0, "clear-sky annual DNI is plausible (%.0f kWh/m²)" % float(res["annual_dni"]))
	_ok(CspLabSite.days_in_month(2028, 2) == 29 and CspLabSite.days_in_month(2026, 2) == 28, "leap February")


func _test_structure() -> void:
	var tp := CspLabStructure.tube_props(0.1143, 0.004)
	var di := 0.1143 - 0.008
	_near(float(tp["I"]), PI * (pow(0.1143, 4) - pow(di, 4)) / 64.0, 1e-12, "tube I by hand")
	_near(CspLabStructure.q_wind(10.0), 61.25, 1e-9, "q = ½ρv²")
	var d := CspLabDesign.solve({"type": "parabolic_dish"})
	var st: Dictionary = d["structure"]
	var loads: Dictionary = st["loads"]
	_near(float(loads["wind_force_n"]), 0.5 * 1.225 * 144.0 * 1.2 * PI, 1e-6, "face-on wind on a 2 m dish at 12 m/s")
	_ok(not (st["drive"] as Dictionary).is_empty(), "a drive is chosen")
	_ok(float((st["drive"] as Dictionary)["hold_nm"]) >= float(loads["drive_hold_nm"]), "the auto drive holds the stow moment")
	_ok(float(st["mass_kg"]) > 5.0, "the structure has mass")
	var weak := CspLabSpec.resolve({"type": "parabolic_dish", "structure": {"member_mm": 25.0, "wall_mm": 1.0}})
	var errs := 0
	for c in (CspLabDesign.solve(weak)["checks"] as Array):
		if str((c as Dictionary)["level"]) == "error":
			errs += 1
	_ok(errs > 0, "a 25 mm post under a 2 m dish fails")
	var tt := CspLabDesign.solve({"type": "parabolic_trough"})
	_ok(float(tt["structure"]["loads"]["twist_mrad"]) > 0.0, "the torque tube twists")
	_ok(int(tt["structure"]["pylons"]) >= 2, "a trough stands on pylons")
	var tw := CspLabDesign.solve({"type": "tower"})
	var helio_peds := 0
	for m in (tw["structure"]["members"] as Array):
		if str((m as Dictionary).get("label", "")) == "Heliostat pedestal":
			helio_peds += 1
	_ok(helio_peds == int(tw["geo"]["count"]), "one pedestal per heliostat")
	_test_realistic_structures()


## The supports are built the way real ones are, and the bookkeeping that
## follows from them holds.
func _test_realistic_structures() -> void:
	# A dish balances on its elevation axis: the counterweights' moment equals
	# the dish + receiver's, and they swing clear of the ground.
	var d := CspLabDesign.solve(CspLabPresets.by_id("stirling_dish"))
	var st: Dictionary = d["structure"]
	var pl: Vector3 = st["pivot_local"]
	_ok(pl.y < 0.0, "a dish's elevation axis is behind the vertex (%.2f m)" % pl.y)
	var cg := CspLabStructure.optic_cg(d)
	var moment := float(cg["kg"]) * (float(cg["y"]) - pl.y)
	_near(float(st["counterweight_kg"]) * float(st["cw_arm_m"]), moment, maxf(moment * 1e-6, 1e-6), "the counterweights balance the dish about its axis")
	var low := INF
	var ribs := 0
	for mv in (st["members"] as Array):
		var m: Dictionary = mv
		if str(m.get("mat", "")) == "counterweight":
			low = minf(low, (st["pivot_world"] as Vector3).y + minf((m["a"] as Vector3).y, (m["b"] as Vector3).y) - pl.y)
		if str(m.get("label", "")) == "Mirror rib":
			ribs += 1
			var q: Vector3 = m["b"]
			var r := Vector2(q.x, q.z).length()
			var ym := r * r / (4.0 * float(d["geo"]["f"]))
			if q.y > ym:
				_ok(false, "a dish rib point lies in front of the mirror")
				return
	_ok(low > 0.0, "a dish pointing straight up keeps its counterweights off the ground (%.2f m)" % low)
	_ok(ribs >= 8 * 6, "a dish has curved ribs behind the mirror (%d pieces)" % ribs)
	# Concrete is counted apart from the steel, and the BOM's lift total leaves it out.
	var steel := 0.0
	var conc := 0.0
	var mat := CspLabParts.struct_material(str(d["spec"]["structure"]["material"]))
	for mv2 in (st["members"] as Array):
		var m2: Dictionary = mv2
		var mk := str(m2.get("mat", ""))
		if mk == "concrete":
			conc += float(m2["mass"])
		elif mk == "counterweight":
			pass
		elif bool(m2.get("box", false)):
			steel += float(m2.get("mass", 0.0))
		else:
			steel += (m2["a"] as Vector3).distance_to(m2["b"] as Vector3) * float(CspLabStructure.tube_props(float(m2["d"]), float(m2["t"]))["A"]) * float(mat["density"])
	_near(float(st["mass_kg"]), steel, 1e-6, "steel mass leaves out the concrete and the counterweights")
	_near(float(st["concrete_kg"]), conc, 1e-6, "concrete counted on its own")
	var with_found := 0.0
	var has_found := false
	for r in (d["bom"] as Array):
		with_found += float((r as Dictionary)["kg"])
		has_found = has_found or bool((r as Dictionary).get("foundation", false))
	_ok(has_found and CspLabDesign.bom_mass(d) < with_found - conc * 0.99, "the BOM lists the footings but does not lift them")
	# Every built-in stands on footings.
	var bare: Array = []
	for b in CspLabPresets.builtins():
		var dd := CspLabDesign.solve((b as Dictionary)["spec"] as Dictionary, {"rays": 300})
		if float(dd["structure"]["concrete_kg"]) <= 0.0:
			bare.append(str((b as Dictionary)["id"]))
	_ok(bare.is_empty(), "every built-in stands on concrete footings %s" % str(bare))
	# A lens is balanced: its tilt axis goes through the lens + receiver's centre of gravity.
	var dl := CspLabDesign.solve(CspLabPresets.by_id("glass_lens"))
	_near(float((dl["structure"]["pivot_local"] as Vector3).y), float(CspLabStructure.optic_cg(dl)["y"]), 1e-6, "a lens tilts about its centre of gravity")
	# A trough's ribs follow the back of the mirror; the torque tube is behind it.
	var dt := CspLabDesign.solve(CspLabPresets.by_id("eurotrough"))
	var f := float(dt["geo"]["f"])
	var worst := -INF
	var n_rib := 0
	for mv3 in (dt["structure"]["members"] as Array):
		var m3: Dictionary = mv3
		if str(m3.get("label", "")) != "Rib":
			continue
		n_rib += 1
		for q2 in [m3["a"], m3["b"]]:
			var qv: Vector3 = q2
			worst = maxf(worst, qv.y - qv.x * qv.x / (4.0 * f))
	_ok(n_rib > 0 and worst < 0.0, "trough ribs sit behind the mirror (closest %.3f m)" % worst)
	_ok(float((dt["structure"]["pivot_local"] as Vector3).y) < 0.0, "the torque tube runs behind the trough's vertex")
	var dc := CspLabDesign.solve(CspLabPresets.by_id("cpc_pipe"))
	var hangers := 0
	for mv4 in (dc["structure"]["members"] as Array):
		if str((mv4 as Dictionary).get("label", "")) == "Pipe hanger":
			hangers += 1
	_ok(hangers == 2, "a CPC pipe trough hangs its pipe from the end ribs")
	# A fixed trough runs east–west (tilted to the latitude): its pylons stand
	# along that line, under the tube.
	var df := CspLabDesign.solve(CspLabPresets.by_id("cpc_flat"))
	var xs: Array = []
	var off_line := 0.0
	for mv5 in (df["structure"]["members"] as Array):
		var m5: Dictionary = mv5
		if str(m5.get("label", "")) == "Pylon":
			xs.append(snappedf((m5["b"] as Vector3).x, 0.01))
			off_line = maxf(off_line, absf((m5["b"] as Vector3).z))
	_ok(xs.size() >= 2 and xs[0] != xs[xs.size() - 1] and off_line < 1e-6, "a fixed east–west trough's pylons stand along its tube %s" % str(xs))


func _test_optimizer() -> void:
	var s := CspLabSpec.resolve({"type": "parabolic_dish", "receiver": {"size_m": 0.5}, "site": {"op_temp_c": 400.0}})
	var opt := CspLabOptimizer.new(s, [["receiver", "size_m", 0.02, 0.6]], "net_kw", 800)
	var guard := 0
	while not opt.step() and guard < 200:
		guard += 1
	_ok(opt.done, "the optimizer finishes")
	_ok(opt.best_value > opt.start_value, "optimizing the receiver raises net heat (%.3f → %.3f kW)" % [opt.start_value, opt.best_value])
	_ok(float(opt.best_spec["receiver"]["size_m"]) < 0.5, "a smaller receiver loses less heat")
	var opt2 := CspLabOptimizer.new(s, [["receiver", "size_m", 0.02, 0.6]], "net_kw", 800)
	while not opt2.step():
		pass
	_near(opt2.best_value, opt.best_value, 1e-9, "the search is deterministic")


func _test_presets() -> void:
	for b in CspLabPresets.builtins():
		var spec: Dictionary = (b as Dictionary)["spec"]
		var d := CspLabDesign.solve(spec, {"rays": 2000})
		var c := CspLabDesign.check_counts(d)
		_ok(int(c["error"]) == 0, "preset %s has no error-level check (%s)" % [str((b as Dictionary)["id"]),
			", ".join(PackedStringArray((d["checks"] as Array).filter(func(x): return str(x["level"]) == "error").map(func(x): return str(x["text"]))))])
		_ok(float(d["q_useful_kw"]) > 0.0, "preset %s makes heat" % str((b as Dictionary)["id"]))


func _test_builder() -> void:
	var bad := 0
	var total := 0
	var specs: Array = []
	for t in CspLabSpec.TYPES:
		specs.append(CspLabSpec.resolve({"type": t}))
	specs.append(CspLabPresets.by_id("cpc_pipe"))
	specs.append(CspLabPresets.by_id("cpc_flat"))
	for sp in specs:
		var node := CspLabBuilder.build_node(sp as Dictionary, "T", {})
		for mi in node.find_children("*", "MeshInstance3D", true, false):
			var m := (mi as MeshInstance3D).mesh
			if not (m is ArrayMesh):
				continue
			for si in (m as ArrayMesh).get_surface_count():
				var arr := (m as ArrayMesh).surface_get_arrays(si)
				if arr[Mesh.ARRAY_NORMAL] == null or (m as ArrayMesh).surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
					continue
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				var count := idx.size() if idx.size() > 0 else v.size()
				for k in range(0, count - 2, 3):
					var i0 := idx[k] if idx.size() > 0 else k
					var i1 := idx[k + 1] if idx.size() > 0 else k + 1
					var i2 := idx[k + 2] if idx.size() > 0 else k + 2
					var face := (v[i1] - v[i0]).cross(v[i2] - v[i0])
					if face.length() < 1e-12:
						continue
					total += 1
					if face.dot(nn[i0] + nn[i1] + nn[i2]) > 0.0:
						bad += 1
		node.free()
	_ok(total > 1000, "the builders make triangles (%d)" % total)
	_ok(bad == 0, "every triangle is wound clockwise from its normal (%d bad)" % bad)


## The placed prop is built from ITS design: the record's csplab_spec reaches
## the builder (it used to be dropped, and every concentrator came out the
## default dish).
func _test_placed_type() -> void:
	for id in ["diy_trough", "cpc_pipe", "water_lens", "eurotrough"]:
		var sp := CspLabSpec.to_json_safe(CspLabPresets.by_id(id))
		var rec := {"model_id": CspLabBuilder.MODEL_ID, "csplab_spec": sp}
		var ex := PlacedPropRuntime.model_extras(rec)
		_ok(ex.has("csplab_spec"), "%s: the record's design reaches the model's extras" % id)
		var model := ModelCatalog.instantiate(CspLabBuilder.MODEL_ID, ex)
		var b: CspLabBuilder = null
		if model != null:
			if model is CspLabBuilder:
				b = model as CspLabBuilder
			else:
				for n in model.find_children("*", "Node3D", true, false):
					if n is CspLabBuilder:
						b = n as CspLabBuilder
						break
		_ok(b != null and str(b.spec["type"]) == str(sp["type"]),
			"%s: placed as a %s (got %s)" % [id, str(sp["type"]), str(b.spec["type"]) if b != null else "nothing"])
		if model != null:
			model.free()


## A water lens is water lying on a film: it never tilts, the receiver is
## moved into the spot, and it works best around noon near the solstice.
func _test_water_lens_level() -> void:
	var r := CspLabSpec.resolve({"type": "water_lens", "tracking": {"mode": "two_axis"}, "structure": {"mount": "pedestal_azel"}})
	_ok(str(r["tracking"]["mode"]) == "level" and str(r["structure"]["mount"]) == "suspended_frame",
		"a water lens is always level, hung in a frame")
	_ok(str(CspLabSpec.resolve({"type": "lens", "tracking": {"mode": "level"}})["tracking"]["mode"]) == "fixed",
		"only a water lens is level")
	var tm := CspLabSpec.items_for("tracking_modes", "water_lens")
	_ok(tm.size() == 1 and str((tm[0] as Array)[0]) == "level", "the water lens offers only Level")
	var has_level := false
	for it in CspLabSpec.items_for("tracking_modes", "parabolic_dish"):
		if str((it as Array)[0]) == "level":
			has_level = true
	_ok(not has_level, "nothing else offers Level")
	var p := CspLabSite.pose(r, CspLabSite.sun_world(120.0, 40.0), 35.0)
	_ok((p["basis"] as Basis).is_equal_approx(Basis.IDENTITY), "a level lens's axis stays plumb whatever the sun")
	_ok(CspLabActuators.channels(CspLabDesign.solve(r), p).is_empty(), "nothing on it to drive")
	# The spot lands f·tan θ off the axis; the receiver is carried there.
	var g := CspLabOptics.geometry(r)
	var th := deg_to_rad(20.0)
	var rc := CspLabOptics.focus_follow(g, Vector3(sin(th), cos(th), 0.0))
	var h := float(g["y_bot"]) - float(g["rec_y"])
	_ok(rc.x < -0.8 * tan(th) * h and rc.x > -1.05 * tan(th) * h, "the receiver follows the spot along the chief ray (%.3f m)" % rc.x)
	_ok(rc.y > 0.0, "and rises to the smallest spot (%.3f m)" % rc.y)
	_ok(CspLabOptics.focus_follow(g, Vector3.UP).is_zero_approx(), "with the sun overhead it stays put")
	_ok(CspLabOptics.focus_follow(CspLabOptics.geometry(CspLabSpec.resolve({"type": "lens"})), Vector3(0.3, 0.9, 0).normalized()) == Vector3.ZERO,
		"a tracked lens's receiver stays on its axis")
	# The design point is the summer-solstice noon; the year falls away from it.
	var lat := 35.0
	var spec := CspLabPresets.by_id("water_lens")
	(spec["site"] as Dictionary)["lat_deg"] = lat
	var d := CspLabDesign.solve(spec)
	_ok(CspLabDesign.design_sun_local(d["spec"] as Dictionary).is_equal_approx(CspLabSite.solstice_noon_sun(lat)),
		"its headline numbers are at noon on the summer solstice")
	var e_sol := CspLabSite.optical_eff_at(d, CspLabSite.solstice_noon_sun(lat), lat)
	var e_eq := CspLabSite.optical_eff_at(d, CspLabSite.noon_sun(lat, 0.0), lat)
	var e_win := CspLabSite.optical_eff_at(d, CspLabSite.noon_sun(lat, -23.44), lat)
	var e_2h := CspLabSite.optical_eff_at(d, CspLabSite.sun_at_decl(lat, 23.44, 30.0), lat)
	print("  water lens at 35°N: solstice noon %.2f, ±2 h %.2f, equinox noon %.2f, midwinter noon %.2f" % [e_sol, e_2h, e_eq, e_win])
	var e_vert := float(CspLabOptics.trace(d["geo"] as Dictionary, Vector3.UP, CspLabSite.POLL_EFF_RAYS, {"seed": 3})["captured"])
	_ok(e_sol > 0.8 * e_vert and e_sol > 0.15, "at noon on the solstice it does about as well as with the sun overhead (%.2f vs %.2f)" % [e_sol, e_vert])
	_ok(e_sol > e_eq and e_eq > e_win, "noon efficiency falls from the solstice to midwinter")
	_ok(e_2h < e_sol, "and away from noon")
	var errs := 0
	var note := false
	for cv in (d["checks"] as Array):
		if str((cv as Dictionary)["level"]) == "error":
			errs += 1
		if str((cv as Dictionary)["text"]).contains("can't follow the sun"):
			note = true
	_ok(errs == 0, "the hanging water lens preset has no error")
	_ok(note, "the checks say when it works")
	var st: Dictionary = d["structure"]
	var posts := 0
	var cart := false
	for mv in (st["members"] as Array):
		var m: Dictionary = mv
		if str(m.get("label", "")) == "Corner post":
			posts += 1
		if str(m["frame"]) == "cart":
			cart = true
	_ok(posts == 4 and cart, "four posts and a receiver cart")
	_ok(float(st.get("receiver_height_m", 0.0)) > 0.12, "the receiver stands above the ground (%.2f m)" % float(st.get("receiver_height_m", 0.0)))
	var low := CspLabPresets.by_id("water_lens")
	(low["structure"] as Dictionary)["pedestal_h_m"] = 1.5
	var dl := CspLabDesign.solve(low)
	var low_err := false
	for cv in (dl["checks"] as Array):
		if str((cv as Dictionary)["level"]) == "error" and str((cv as Dictionary)["text"]).contains("Raise the frame"):
			low_err = true
	_ok(low_err, "a frame lower than the focal length is an error")
	_ok(not CspLabSpec.field_shown({"g": "tracking", "k": "fixed_tilt_deg", "skip_types": ["water_lens"]}, "water_lens"),
		"no tilt row for a water lens")


## Every tracking drive as degrees, off the pose the builder draws; the
## mapping onto a Home Assistant entity.
func _test_actuators() -> void:
	var sun := CspLabSite.sun_world(135.0, 40.0)
	var dish := CspLabSpec.resolve({"type": "parabolic_dish"})
	var cd := CspLabActuators.channels(CspLabDesign.solve(dish), CspLabSite.pose(dish, sun, 35.0))
	_ok(cd.size() == 2 and str((cd[0] as Dictionary)["id"]) == "azimuth" and str((cd[1] as Dictionary)["id"]) == "elevation",
		"a dish has an azimuth and an elevation drive")
	if cd.size() == 2:
		_near(float((cd[0] as Dictionary)["deg"]), 135.0, 0.01, "the azimuth drive faces the sun")
		_near(float((cd[1] as Dictionary)["deg"]), 40.0, 0.01, "the elevation drive faces the sun")
	var stow := CspLabActuators.channels(CspLabDesign.solve(dish), CspLabSite.pose(dish, CspLabSite.sun_world(300.0, -10.0), 35.0))
	_near(float((stow[1] as Dictionary)["deg"]), 90.0, 0.01, "at night the dish stows face up")
	var polar := CspLabSpec.resolve({"type": "parabolic_dish", "structure": {"mount": "polar_mount"}})
	var cp := CspLabActuators.channels(CspLabDesign.solve(polar), CspLabSite.pose(polar, sun, 35.0))
	_ok(cp.size() == 2 and str((cp[0] as Dictionary)["id"]) == "hour_angle", "a polar mount has hour angle + declination")
	var trough := CspLabSpec.resolve({"type": "parabolic_trough"})
	var pt := CspLabSite.pose(trough, sun, 35.0)
	var ct := CspLabActuators.channels(CspLabDesign.solve(trough), pt)
	_ok(ct.size() == 1 and is_equal_approx(float((ct[0] as Dictionary)["deg"]), float((pt["angles"] as Dictionary)["Rotation"])),
		"a trough has one rotation drive, the pose's own angle")
	var fixed := CspLabPresets.by_id("cpc_flat")
	_ok(CspLabActuators.channels(CspLabDesign.solve(fixed), CspLabSite.pose(CspLabSpec.resolve(fixed), sun, 35.0)).is_empty(),
		"a fixed trough has nothing to drive")
	var lfr := CspLabSpec.resolve({"type": "linear_fresnel"})
	var dlf := CspLabDesign.solve(lfr)
	var cl := CspLabActuators.channels(dlf, CspLabSite.pose(lfr, sun, 35.0))
	_ok(cl.size() == int((lfr["optic"] as Dictionary)["rows"]), "one tilt drive per Fresnel row")
	var tw := CspLabSpec.resolve({"type": "tower"})
	var dtw := CspLabDesign.solve(tw)
	var ctw := CspLabActuators.channels(dtw, CspLabSite.pose(tw, sun, 35.0))
	_ok(ctw.size() == int((dtw["geo"] as Dictionary)["count"]) * 2, "two drives per heliostat (%d)" % ctw.size())
	var h_el := float((ctw[1] as Dictionary)["deg"])
	_ok(h_el > 0.0 and h_el < 90.0, "a heliostat's elevation is above the horizon")
	# Mapping onto an entity.
	var ch := {"id": "elevation", "min": 0.0, "max": 90.0, "deg": 30.0}
	_near(CspLabActuators.value_for(30.0, {"entity_id": "number.m", "invert": true, "scale": 2.0, "offset": 10.0}), -50.0, 1e-6,
		"invert, then scale, then offset")
	_near(CspLabActuators.value_for(30.0, {"entity_id": "number.m", "min": 0.0, "max": 20.0}), 20.0, 1e-6, "clamped to the link's range")
	_near(CspLabActuators.value_for(45.0, {"entity_id": "cover.actuator"}, ch), 50.0, 1e-6, "a cover gets a percentage of the range")
	var sv := CspLabActuators.service_for("input_number.dish_az", 12.345)
	_ok(str(sv["domain"]) == "input_number" and str(sv["service"]) == "set_value" and is_equal_approx(float(sv["data"]["value"]), 12.35),
		"input_number.set_value")
	var cv := CspLabActuators.service_for("cover.actuator", 49.6)
	_ok(str(cv["service"]) == "set_cover_position" and int(cv["data"]["position"]) == 50, "cover.set_cover_position")
	_ok(CspLabActuators.service_for("sensor.x", 1.0).is_empty() and not CspLabActuators.supported("sensor.x"),
		"a sensor can't be driven")
	var cfg := {"enabled": true, "deadband_deg": 0.5, "min_interval_s": 2.0,
		"channels": {"azimuth": {"entity_id": "input_number.az"}, "elevation": {"entity_id": "sensor.bad"}}}
	var chans := [{"id": "azimuth", "deg": 100.0, "min": 0.0, "max": 360.0}, {"id": "elevation", "deg": 40.0, "min": 0.0, "max": 90.0}]
	var due := CspLabActuators.due(cfg, chans, {}, 10.0)
	_ok(due.size() == 1 and str((due[0] as Dictionary)["entity_id"]) == "input_number.az", "a never-sent drive goes out; an unsupported entity doesn't")
	_ok(CspLabActuators.due(cfg, chans, {"input_number.az": 100.3}, 10.0).is_empty(), "inside the deadband: nothing")
	_ok(CspLabActuators.due(cfg, chans, {"input_number.az": 99.0}, 1.0).is_empty(), "sooner than the interval: nothing")
	_ok(CspLabActuators.due(cfg, chans, {"input_number.az": 99.0}, 3.0).size() == 1, "moved past the deadband: sent")
	var off := cfg.duplicate(true)
	off["enabled"] = false
	_ok(CspLabActuators.due(off, chans, {}, 10.0).is_empty(), "switched off: nothing")
	_ok(CspLabActuators.slug("Dish cooker 1.5 m") == "dish_cooker_1_5_m", "an entity-safe name")
	var y := CspLabActuators.ha_yaml("Dish cooker", chans)
	_ok(y.contains("input_number:") and y.contains("dish_cooker_azimuth:") and y.contains("number.set_value"),
		"the YAML declares the helpers and an example automation")


## The placed mirror reads as a mirror and the receiver glows with the flux.
func _test_mirror_and_glow() -> void:
	var a := CspLabBuilder.build_node(CspLabPresets.by_id("dish_cooker"), "A", {})
	var b := CspLabBuilder.build_node(CspLabPresets.by_id("diy_trough"), "B", {})
	var ma: Material = null
	var mb: Material = null
	var mia := a.find_child("Mirror", true, false) as MeshInstance3D
	var mib := b.find_child("Mirror", true, false) as MeshInstance3D
	if mia != null:
		ma = mia.get_surface_override_material(0)
	if mib != null:
		mb = mib.get_surface_override_material(0)
	_ok(ma is ShaderMaterial and (ma as ShaderMaterial).shader.resource_path.ends_with("csplab_mirror.gdshader"),
		"the mirror is drawn with the mirror shader")
	_ok(ma != null and mb != null and ma == mb, "every concentrator in the world shares one mirror material")
	var studio := CspLabBuilder.build_node(CspLabPresets.by_id("dish_cooker"), "S", {"private_mirror": true})
	_ok(studio.mirror_material() != ma, "the designer's studio has its own (its own sun)")
	studio.free()
	a.set_glow_focus(1.0)
	var rec := a.find_child("Receiver", true, false) as MeshInstance3D
	var em := 0.0
	if rec != null and rec.mesh != null:
		var sm := rec.mesh.surface_get_material(0) as StandardMaterial3D
		if sm != null:
			em = sm.emission_energy_multiplier
	_ok(em > 10.0, "at its working flux the receiver glows (emission %.1f)" % em)
	var card := a.find_child("ReceiverGlow0", true, false) as MeshInstance3D
	var light := a.find_child("ReceiverLight0", true, false) as OmniLight3D
	_ok(card != null and card.visible and light != null and light.visible and light.light_energy > 1.0,
		"a glow card and a light on the receiver")
	a.set_glow_focus(0.0)
	_ok(card != null and not card.visible and light != null and not light.visible, "dark at night")
	var n_cards := b.glow_card_count()
	var line := b.find_child("ReceiverGlow", true, false) as MultiMeshInstance3D
	_ok(n_cards >= 2 and line != null and line.multimesh.instance_count == n_cards,
		"a line focus glows along its length (%d cards, one MultiMesh)" % n_cards)
	var wl := CspLabBuilder.build_node(CspLabPresets.by_id("water_lens"), "W", {"sun": CspLabSite.sun_world(180.0, 60.0)})
	var cart := wl.find_child("ReceiverCart", true, false) as Node3D
	_ok(cart != null and cart.find_child("Receiver", true, false) != null, "the water lens's receiver rides a cart")
	_ok(cart != null and cart.position.z < -0.1, "the cart sits north of the lens when the sun is south (z %.2f)" % (cart.position.z if cart != null else 0.0))
	a.free()
	b.free()
	wl.free()


## The performance paths: a field's mirrors turn without re-meshing, a new
## sun angle is traced live in chunks (never in one go) and lands near the
## full trace, designs of one spec share one efficiency table, and the
## world's shared mirror is only rewritten when the sun moved.
func _test_perf_paths() -> void:
	var tw := CspLabBuilder.build_node(CspLabPresets.by_id("tower_surround"), "T", {})
	var mmi := tw.find_child("Mirrors", true, false) as MultiMeshInstance3D
	var g: Dictionary = tw.design["geo"]
	var n_h := (g["centres"] as PackedVector3Array).size()
	_ok(mmi != null and mmi.multimesh.instance_count == n_h, "a field's mirrors are one MultiMesh (%d heliostats)" % n_h)
	var mesh0: Mesh = mmi.multimesh.mesh if mmi != null else null
	tw.set_sun(CspLabSite.sun_world(120.0, 30.0))
	_ok(mmi != null and mmi.multimesh.mesh == mesh0, "a new sun turns them without re-meshing")
	var xfs := tw.field_mirror_transforms()
	var sl: Vector3 = tw.last_pose["sun_local"]
	var fp := CspLabOptics.field_pose(g, sl)
	var ns: PackedVector3Array = fp["n"]
	var ok_xf := xfs.size() == n_h
	for i in xfs.size():
		var t := xfs[i] as Transform3D
		if t.basis.determinant() <= 0.0 or t.basis.z.dot(ns[i]) < 0.999:
			ok_xf = false
	_ok(ok_xf, "each heliostat faces its own normal, right-handed")
	tw.free()
	var lf := CspLabBuilder.build_node(CspLabPresets.by_id("lfr_small"), "L", {})
	var lmm := lf.find_child("Mirrors", true, false) as MultiMeshInstance3D
	_ok(lmm != null and lmm.multimesh.instance_count == (lf.design["geo"]["xs"] as PackedFloat64Array).size(),
		"a linear Fresnel field's rows are one MultiMesh too")
	lf.free()
	# One efficiency table per design, whatever the ray count.
	var sp := CspLabSpec.resolve(CspLabPresets.by_id("cpc_pipe"))
	var d1 := CspLabDesign.solve(sp, {"rays": 1500})
	var d2 := CspLabDesign.solve(sp, {"rays": 2500})
	_ok(is_same(d1["eff_cache"], d2["eff_cache"]), "two solves of one design share one efficiency table")
	# A live lookup at a new sun traces in chunks.
	var s_new := CspLabSite.sun_world(137.0, 33.0)
	var lat := CspLabDesign.lat_of(sp)
	var p := CspLabSite.pose(sp, s_new, lat)
	var full_d := CspLabDesign.solve(sp, {"rays": 1500, "no_cache": true})
	(full_d as Dictionary)["eff_cache"] = {}
	var e_full := CspLabSite.optical_eff_at(full_d, s_new, lat)
	var cache: Dictionary = d1["eff_cache"]
	var before := cache.size()
	CspLabSite._live_frame = -1
	var t0 := Time.get_ticks_usec()
	var e_first := CspLabSite.optical_eff_at(d1, s_new, lat, true)
	var first_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var pend: Dictionary = cache.get("@pending", {})
	_ok(not pend.is_empty(), "a live lookup at a new sun does not trace it in one go (%.1f ms, answer %.3f)" % [first_ms, e_first])
	_ok(e_first >= 0.0 and e_first <= 1.0, "and still answers something sensible meanwhile")
	var frames := 0
	while not pend.is_empty() and frames < 400:
		CspLabSite._live_frame = -1
		CspLabSite.advance_live(d1)
		frames += 1
	var e_live := CspLabSite.optical_eff_at(d1, s_new, lat, true)
	_ok(pend.is_empty() and cache.size() > before, "it is finished a chunk a frame (%d frames)" % frames)
	_near(e_live, e_full, 0.05, "the chunked trace lands on the full one (%.3f vs %.3f)" % [e_live, e_full])
	_ok(p.has("sun_local"), "the pose is there to trace from")
	# The shared mirror is only rewritten when the sun moved.
	var m := CspLabBuilder.shared_mirror()
	CspLabBuilder.push_world_sun(Vector3(0.3, 0.8, 0.2))
	var v1: Vector3 = m.get_shader_parameter("sun_dir")
	CspLabBuilder.push_world_sun(Vector3(0.3, 0.8, 0.2001))
	var v2: Vector3 = m.get_shader_parameter("sun_dir")
	_ok(v1 == v2, "a tiny sun move leaves the shared mirror alone")
	CspLabBuilder.push_world_sun(Vector3(0.6, 0.6, 0.2))
	var v3: Vector3 = m.get_shader_parameter("sun_dir")
	_ok(v3 != v1, "a real move updates it")
	# Read off the shader's source (headless has no renderer to ask).
	var re := RegEx.create_from_string("metallic_v[^=]*=[ ]*([0-9.]+)")
	var hit := re.search(m.shader.code)
	_ok(hit != null and float(hit.get_string(1)) < 0.9, "the mirror keeps some diffuse (never black)")
