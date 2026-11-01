class_name PeltonLabDesign
extends RefCounted

## A solved Pelton wheel: the runner (where every cup and bolt goes), the
## rotor discs, hub and bolt pattern, the jets, the housing, the shaft with
## its bearings and drive, the generator, and the numbers — runner design
## rules, speed, power and the strength checks. Pure static; solve() caches
## by the spec's key.
##
## Frames:
##   RUNNER frame (PeltonLabCup): shaft +Y, cups in the XZ plane.
##   CANONICAL machine frame (everything else, metres): the shaft is +X with
##     the drive end (bearings, drive, generator) toward +X, +Y up for a
##     horizontal shaft, the runner's centre at the origin; the housing's
##     WINDOW is its −Z wall. runner → canonical: R.x → C.y, R.y → C.x,
##     R.z → −C.z (a proper rotation), so the first jet of a horizontal wheel
##     (θ = 180°) runs along −Z under the wheel.
##   MODEL frame (the placed prop): canonical as is for a horizontal shaft,
##     turned so +X points UP for a vertical shaft (the generator on top, the
##     open bottom of the housing at the non-drive end), and lifted so the
##     machine stands on y = 0.
##
## Design rules, with sources (the penalties built on them are this game's
## estimates, centred on the published rules — they say "this is worse", not
## a lab-measured efficiency):
##   - Jet ratio m = PCD / d_jet. Thake (The Micro-Hydro Pelton Turbine
##     Manual, 2000) and Nasir (2013, "Design of high efficiency Pelton
##     turbine for micro-hydropower plant", IJEET 4(1)): m ≥ ~10 for good
##     efficiency, small runners down to ~6.
##   - Cup width B ≈ 3.1–3.4 d_jet (Thake; Nasir B = 3.1 d). Narrower spills
##     water over the rim, wider costs windage and weight.
##   - Cup count Z = 15 + 0.5 m (Tygun's rule, quoted by Nasir 2013 and Thake).
##     Too few and part of the jet passes between cups; too many and the cups
##     crowd, interfere with the leaving water and add windage.
##   - Speed: u/v_jet = 0.46 at the best point, runaway at twice the design
##     speed (PeltonPhysics, Thake).

const RHO := 1000.0
const G := 9.80665
## A well-proportioned wheel of these cups, before the design rules' penalty:
## Thake quotes 70–85 % for small Peltons; the middle of the band.
const ETA_BASE := 0.78
## The leaving water turned through 165° (PeltonPhysics.BUCKET_DEFLECTION_DEG):
## the jet force is ρ·Q·(v − u)·(1 + cos 15°).
const FORCE_K := 1.966
const BEARING_EFF := 0.99   ## per insert bearing (grease, sealed)
const TARGET_L10_H := 20000.0

static var _cache: Dictionary = {}


static func solve(spec: Dictionary) -> Dictionary:
	var key := PeltonLabSpec.key_of(spec)
	if _cache.has(key):
		return _cache[key]
	if _cache.size() > 64:
		_cache.clear()
	var d := _solve(PeltonLabSpec.resolve(spec))
	_cache[key] = d
	return d


static func clear_cache() -> void:
	_cache.clear()


## runner → canonical.
static func runner_basis() -> Basis:
	return Basis(Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1))


static func _solve(s: Dictionary) -> Dictionary:
	var d := {"spec": s}
	_runner(d)
	_rotor(d)
	_jets(d)
	_housing(d)
	_shaft_and_drive(d)
	_base(d)
	_model_frame(d)
	d["rules"] = runner_rules(d)
	d["mass"] = _masses(d)
	d["perf"] = performance(d)
	d["checks"] = _checks(d)
	d["bom"] = _bom(d)
	return d


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

static func _runner(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var r: Dictionary = s["runner"]
	var c := PeltonLabParts.CUP
	var k := float(r["cup_width_mm"]) / float(c["width_mm"])
	var tip_r := float(r["overall_d_mm"]) * 0.5
	var pitch_r := tip_r - (float(c["pitch_z"]) - float(c["tip_z"])) * k
	var z := int(r["cups"])
	var xfs: Array = []
	var bolts: Array = []
	var bc := PeltonLabCup.bolt_points(int(r["cup_bolts"]))
	for i in z:
		var th := TAU * float(i) / float(z)
		var xf := PeltonLabCup.cup_transform(th, pitch_r * 0.001, k, float(r["cup_tilt_deg"]))
		xfs.append(xf)
		for p in bc:
			bolts.append(xf * (p as Vector3))
	d["runner"] = {
		"k": k, "cups": z, "tip_r_mm": tip_r, "pitch_r_mm": pitch_r, "pcd_mm": pitch_r * 2.0,
		"root_r_mm": PeltonLabCup.radius_at(float(c["root_z"]), pitch_r, k),
		"bowl_root_r_mm": PeltonLabCup.radius_at(float(c["bowl_root_z"]), pitch_r, k),
		"cg_r_mm": PeltonLabCup.radius_at(float(c["centroid_z"]), pitch_r, k),
		"cup_w_mm": float(r["cup_width_mm"]),
		"tab_w_mm": (float(c["tab_x1"]) - float(c["tab_x0"])) * k,
		"cup_xfs": xfs, "cup_bolts": bolts,
		"bolt_radii_mm": _bolt_radii(int(r["cup_bolts"]), pitch_r, k),
		"cup_mass_kg": PeltonLabCup.mass_kg(k, str(r["cup_material"])),
	}


static func _bolt_radii(count: int, pitch_r: float, k: float) -> Array:
	var out: Array = []
	var zs: Array = PeltonLabParts.CUP_BOLT_Z_TWO if count >= 2 else PeltonLabParts.CUP_BOLT_Z_ONE
	for zz in zs:
		out.append(PeltonLabCup.radius_at(float(zz), pitch_r, k))
	return out


# ---------------------------------------------------------------------------
# Rotor (two discs + spacer ring) and hub
# ---------------------------------------------------------------------------

static func _rotor(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var rn: Dictionary = d["runner"]
	var ro: Dictionary = s["rotor"]
	var hb: Dictionary = s["hub"]
	var k := float(rn["k"])
	var auto_disc_r := PeltonLabCup.radius_at(float(PeltonLabParts.CUP["bowl_root_z"]) + 3.0,
			float(rn["pitch_r_mm"]), k)
	var disc_r := float(ro["disc_d_mm"]) * 0.5 if float(ro["disc_d_mm"]) > 0.0 else auto_disc_r
	var gap := float(rn["tab_w_mm"])
	var t := float(ro["disc_t_mm"])
	var spacer_r := float(rn["root_r_mm"]) - 2.0
	var shaft := float(hb["shaft_d_mm"])
	var boss_d := float(hb["boss_d_mm"]) if float(hb["boss_d_mm"]) > 0.0 else maxf(shaft * 1.8, shaft + 20.0)
	var hole := float(PeltonLabParts.bolt(str(hb["bolt"]))["hole"])
	var pcd := float(hb["bolt_pcd_mm"])
	if pcd <= 0.0:
		var lo := boss_d * 0.5 + hole * 0.75 + 3.0
		var hi := spacer_r - hole * 0.75 - 3.0
		pcd = 2.0 * (lo + maxf(hi - lo, 0.0) * 0.4) if hi > lo else 2.0 * lo
	var flange_d := float(hb["flange_d_mm"]) if float(hb["flange_d_mm"]) > 0.0 else pcd + hole * 2.8
	var boss_len := float(hb["boss_len_mm"]) if float(hb["boss_len_mm"]) > 0.0 else maxf(shaft * 1.2, 30.0)
	# The stack along the shaft: [disc][tabs + spacer][disc][hub flange][boss].
	var x_in := gap * 0.5
	var flange_t := maxf(6.0, hole)
	d["rotor"] = {
		"disc_r_mm": disc_r, "auto_disc_r_mm": auto_disc_r, "disc_t_mm": t, "gap_mm": gap,
		"spacer_r_mm": spacer_r, "boss_d_mm": boss_d, "boss_len_mm": boss_len, "flange_d_mm": flange_d,
		"flange_t_mm": flange_t, "bolt_pcd_mm": pcd, "bolt_hole_mm": hole, "shaft_d_mm": shaft,
		"x_disc_a_mm": -(x_in + t * 0.5), "x_disc_b_mm": x_in + t * 0.5,
		"x_flange0_mm": x_in + t, "x_flange1_mm": x_in + t + flange_t,
		"x_boss1_mm": x_in + t + flange_t + boss_len,
		"x_min_mm": -(x_in + t),
	}


# ---------------------------------------------------------------------------
# Jets
# ---------------------------------------------------------------------------

static func jet_angles_deg(s: Dictionary) -> Array:
	var j: Dictionary = s["jets"]
	var n := int(j["count"])
	var start := float(j["start_deg"])
	var horizontal := str(s["orientation"]) == "horizontal"
	if start < 0.0:
		start = 180.0 if horizontal else 0.0
	var step := float(j["spacing_deg"])
	if step <= 0.0:
		step = 90.0 if horizontal else 360.0 / float(n)
	var out: Array = []
	for i in n:
		out.append(fposmod(start + step * float(i), 360.0))
	return out


static func _jets(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var rb := runner_basis()
	var pr := float(d["runner"]["pitch_r_mm"]) * 0.001
	var jd := float(s["jets"]["d_mm"])
	var standoff := float(s["jets"]["standoff_mm"])
	if standoff <= 0.0:
		standoff = jd * 1.5
	var out: Array = []
	for a in jet_angles_deg(s):
		var th := deg_to_rad(float(a))
		var hit := rb * (PeltonLabCup.radial(th) * pr)
		var dir := (rb * PeltonLabCup.tangent(th)).normalized()
		out.append({"deg": float(a), "hit": hit, "dir": dir, "mouth": hit - dir * standoff * 0.001,
			"d_mm": jd})
	d["jets"] = out


# ---------------------------------------------------------------------------
# Housing
# ---------------------------------------------------------------------------

static func _housing(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var hs: Dictionary = s["housing"]
	var rn: Dictionary = d["runner"]
	var cw := float(rn["cup_w_mm"])
	var clear := float(hs["clear_mm"]) if float(hs["clear_mm"]) > 0.0 else maxf(30.0, 0.6 * cw)
	var ax: float
	var hy: float
	var hz: float
	if bool(hs["auto"]):
		var plane := float(rn["tip_r_mm"]) + clear
		ax = maxf(3.0 * cw, float(rn["tab_w_mm"]) + 2.0 * float(d["rotor"]["disc_t_mm"]) + 2.0 * clear)
		hy = plane
		hz = plane
	else:
		ax = float(hs["axial_mm"])
		hy = float(hs["height_mm"]) * 0.5
		hz = float(hs["depth_mm"]) * 0.5
	var wall := float(hs["wall_mm"])
	var open_face := "-y" if str(s["orientation"]) == "horizontal" else "-x"
	# Nozzles: from the mouth back along the jet until they leave the box.
	var half := Vector3(ax * 0.5, hy, hz) * 0.001
	for j in d["jets"]:
		var mouth: Vector3 = j["mouth"]
		var back: Vector3 = -(j["dir"] as Vector3)
		var t := _ray_box_exit(mouth, back, half)
		j["inside"] = _inside(mouth, half)
		j["wall_pt"] = mouth + back * t
		j["inlet"] = mouth + back * (t + wall * 0.001 + 0.06)
		j["len_m"] = t
	d["housing"] = {"axial_mm": ax, "hy_mm": hy, "hz_mm": hz, "wall_mm": wall, "clear_mm": clear,
		"open": open_face, "window": bool(hs["window"]), "material": str(hs["material"])}


static func _inside(p: Vector3, half: Vector3) -> bool:
	return absf(p.x) < half.x and absf(p.y) < half.y and absf(p.z) < half.z


static func _ray_box_exit(o: Vector3, dir: Vector3, half: Vector3) -> float:
	var t := INF
	for a in 3:
		var dv := dir[a]
		if absf(dv) < 1e-9:
			continue
		var plane := half[a] if dv > 0.0 else -half[a]
		var ta := (plane - o[a]) / dv
		if ta >= 0.0:
			t = minf(t, ta)
	return t if t < INF else 0.0


# ---------------------------------------------------------------------------
# Shaft, bearings, drive, generator
# ---------------------------------------------------------------------------

static func _shaft_and_drive(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var dr: Dictionary = s["drive"]
	var ro: Dictionary = d["rotor"]
	var hsg: Dictionary = d["housing"]
	var shaft := float(ro["shaft_d_mm"])
	var br := PeltonLabParts.bearing_for(shaft)
	var flange := str(dr["bearings"]) == "flange"
	var bw := float(br["fA"]) if flange else float(br["A"])
	var x_wall := float(hsg["axial_mm"]) * 0.5 + float(hsg["wall_mm"])
	var b1 := x_wall + bw * 0.5 + (2.0 if flange else 15.0)
	var bearings: Array = []
	var span := float(dr["span_mm"])
	if str(dr["layout"]) == "straddle":
		bearings = [b1, -b1]
		span = 2.0 * b1
	else:
		if span <= 0.0:
			span = maxf(0.8 * b1, 100.0)
		bearings = [b1, b1 + span]
	var x_far := maxf(bearings[0], bearings[bearings.size() - 1])
	var x_drive := x_far + bw * 0.5 + 15.0
	var x_start := float(ro["x_min_mm"]) - 10.0
	if str(dr["layout"]) == "straddle":
		x_start = minf(x_start, -b1 - bw * 0.5 - 10.0)
	var gen := PeltonLabParts.generator(str(s["generator"]["id"]))
	var dtype := str(dr["type"])
	var drive := {"type": dtype, "x0_mm": x_drive, "ratio": 1.0, "reverses": false}
	var shaft_end := x_drive
	var gen_axis := Vector3.ZERO   # canonical, metres: a point on the generator's axis
	var gen_face_x := 0.0
	match dtype:
		"direct":
			# Sized for the stalled wheel's torque (the jet's full momentum on
			# stopped cups — about twice the running torque).
			var jaw := PeltonLabParts.jaw_for(maxf(shaft, float(gen["shaft_mm"])), stall_torque_nm(d))
			var clen := float(jaw["len"]) if str(dr["coupler"]) == "jaw" else maxf(2.5 * shaft, 40.0)
			drive["coupler"] = {"x0_mm": x_drive, "len_mm": clen, "od_mm": float(jaw["od"]) if str(dr["coupler"]) == "jaw" else shaft * 1.8,
				"size": str(jaw["id"]) if str(dr["coupler"]) == "jaw" else "rigid", "torque_nm": float(jaw["torque"])}
			shaft_end = x_drive + clen * 0.5
			gen_face_x = x_drive + clen + 4.0
			gen_axis = Vector3(gen_face_x, 0.0, 0.0) * 0.001
		_:
			var d1: float
			var d2: float
			var w: float
			if dtype == "vbelt":
				d1 = float(dr["driver_d_mm"])
				d2 = float(dr["driven_d_mm"])
				w = 20.0
			elif dtype == "timing":
				d1 = PeltonLabParts.timing_pitch_d_mm(int(dr["driver_teeth"]))
				d2 = PeltonLabParts.timing_pitch_d_mm(int(dr["driven_teeth"]))
				w = 22.0
			else:
				d1 = float(dr["module_mm"]) * float(dr["driver_teeth"])
				d2 = float(dr["module_mm"]) * float(dr["driven_teeth"])
				w = maxf(10.0 * float(dr["module_mm"]), 15.0)
			var cdist := float(dr["centre_mm"])
			if dtype == "gear":
				cdist = (d1 + d2) * 0.5
			elif cdist <= 0.0:
				cdist = maxf(0.9 * (d1 + d2), (d1 + d2) * 0.5 + 40.0)
			var off := Vector3(0, 1, 0) if str(dr["gen_side"]) == "above" else Vector3(0, 0, 1)
			var xp := x_drive + w * 0.5
			drive["d1_mm"] = d1
			drive["d2_mm"] = d2
			drive["w_mm"] = w
			drive["centre_mm"] = cdist
			drive["offset_dir"] = off
			drive["x_pulley_mm"] = xp
			drive["ratio"] = d1 / d2 if dtype == "vbelt" else float(dr["driver_teeth"]) / float(dr["driven_teeth"])
			drive["reverses"] = dtype == "gear"
			if dtype != "gear":
				drive["belt_len_mm"] = 2.0 * cdist + PI * (d1 + d2) * 0.5 + pow(d2 - d1, 2.0) / (4.0 * cdist)
				drive["wrap_deg"] = 180.0 - 2.0 * rad_to_deg(asin(clampf(absf(d2 - d1) / (2.0 * cdist), 0.0, 1.0)))
			shaft_end = x_drive + w
			gen_face_x = x_drive + w + 10.0
			gen_axis = (Vector3(gen_face_x, 0.0, 0.0) + off * cdist) * 0.001
	drive["eff"] = float(PeltonLabParts.DRIVES[dtype]["eff"]) * (float(PeltonLabParts.COUPLERS[str(dr["coupler"])]["eff"])
			if dtype == "direct" else 1.0)
	var glen := float(gen["len_mm"])
	var gr := (float(gen["frame_mm"]) * 0.5 * 1.41) if str(gen["body"]) == "nema" else float(gen.get("dia_mm", 100.0)) * 0.5
	d["shaft"] = {"d_mm": shaft, "x0_mm": x_start, "x1_mm": shaft_end, "bearing": br, "flange": flange,
		"bearing_w_mm": bw, "bearings_x_mm": bearings, "span_mm": span, "x_wall_mm": x_wall,
		"key": bool(s["hub"]["keyway"])}
	d["drive"] = drive
	d["generator"] = {"id": str(s["generator"]["id"]), "spec": gen, "axis": gen_axis, "face_x_mm": gen_face_x,
		"len_mm": glen, "r_mm": gr, "x1_mm": gen_face_x + glen}


## The torque the wheel makes with its cups held still and the jet on them,
## at the design site: ρ·Q·v·(1 + cos 15°)·PCD/2.
static func stall_torque_nm(d: Dictionary) -> float:
	var s: Dictionary = d["spec"]
	var st: Dictionary = s["site"]
	var supply := float(st["supply_lps"])
	var o := PeltonPhysics.operating_point_supply_limited(float(st["gross_head_m"]), float(st["pipe_len_m"]),
			float(st["pipe_d_mm"]) * 0.001, float(st["roughness_mm"]) * 0.001, float(s["jets"]["d_mm"]) * 0.001,
			int(s["jets"]["count"]), supply * 0.001 if supply >= 0.0 else NAN)
	return RHO * float(o["q_m3s"]) * float(o["v_jet_ms"]) * FORCE_K * float(d["runner"]["pitch_r_mm"]) * 0.001


# ---------------------------------------------------------------------------
# Base: steel plates on 40 mm square-tube legs
# ---------------------------------------------------------------------------
#   horizontal: two rails along the shaft under the housing; a plate across
#     the rails under each pillow block (or a plate standing across the shaft
#     for a flange unit that is not on the housing wall); a plate under the
#     generator on four legs to the ground.
#   vertical: four legs under the housing (the tailwater falls between
#     them); a bridge plate above the lid for each bearing off the lid, on four
#     posts; a plate under the generator's flange on four posts to the lid.
# Every piece is a box {a, b} (canonical, metres) in d.base.boxes.

const RAIL_H_MM := 50.0
const LEG_H_MM := 350.0
const TUBE_MM := 40.0
const PLATE_MM := 10.0


static func _box_mm(out: Array, a: Vector3, b: Vector3) -> void:
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))
	if (hi - lo).x < 0.5 or (hi - lo).y < 0.5 or (hi - lo).z < 0.5:
		return
	out.append({"a": lo * 0.001, "b": hi * 0.001})


## A plate (corner a, corner b) on four tube legs running along `axis` (0 x,
## 1 y) from the plate's face down to `to` on that axis.
static func _plate_on_legs(out: Array, a: Vector3, b: Vector3, axis: int, to: float) -> void:
	_box_mm(out, a, b)
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))
	var t := TUBE_MM
	var from := lo[axis] if to < lo[axis] else hi[axis]
	var others := [1, 2] if axis == 0 else [0, 2]
	for s0 in [0, 1]:
		for s1 in [0, 1]:
			var p := Vector3.ZERO
			var q := Vector3.ZERO
			p[axis] = to
			q[axis] = from
			var o0: int = others[0]
			var o1: int = others[1]
			p[o0] = lo[o0] if s0 == 0 else hi[o0] - t
			q[o0] = p[o0] + t
			p[o1] = lo[o1] if s1 == 0 else hi[o1] - t
			q[o1] = p[o1] + t
			_box_mm(out, p, q)


static func _base(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var hsg: Dictionary = d["housing"]
	var sh: Dictionary = d["shaft"]
	var gen: Dictionary = d["generator"]
	var br: Dictionary = sh["bearing"]
	var wall := float(hsg["wall_mm"])
	var hy := float(hsg["hy_mm"]) + wall
	var hz := float(hsg["hz_mm"]) + wall
	var hx := float(hsg["axial_mm"]) * 0.5 + wall
	var boxes: Array = []
	var flange := bool(sh["flange"])
	var bw := float(sh["bearing_w_mm"])
	var ga: Vector3 = gen["axis"] * 1000.0
	var gr := float(gen["r_mm"])
	var gx0 := float(gen["face_x_mm"])
	var gx1 := gx0 + float(gen["len_mm"])
	var with_base := bool(s["housing"]["base"])
	if str(s["orientation"]) == "horizontal":
		var y0 := -hy - RAIL_H_MM
		var x0 := minf(-hx, float(sh["x0_mm"])) - 20.0
		var x1 := maxf(gx1, float(sh["x1_mm"])) + 20.0
		var rz := hz - 25.0
		if with_base:
			for zz in [-rz, rz]:
				_box_mm(boxes, Vector3(x0, y0, float(zz) - 25.0), Vector3(x1, -hy, float(zz) + 25.0))
			for xx in [x0, x1 - 50.0]:
				_box_mm(boxes, Vector3(float(xx), y0, -rz), Vector3(float(xx) + 50.0, -hy, rz))
		for bx in sh["bearings_x_mm"]:
			var x := float(bx)
			if flange:
				# Bolted straight to the housing's end wall when it sits on it.
				if absf(absf(x) - (hx + bw * 0.5 + 2.0)) < 1.0:
					continue
				var px := x - bw * 0.5 - PLATE_MM if x > 0.0 else x + bw * 0.5
				_box_mm(boxes, Vector3(px, -hy, -rz - 25.0), Vector3(px + PLATE_MM, float(br["fB"]) * 0.5 + 25.0, rz + 25.0))
			else:
				var top := -float(br["H"])
				var hw := bw * 0.5 + 15.0
				_plate_on_legs(boxes, Vector3(x - hw, top - PLATE_MM, -rz - 25.0), Vector3(x + hw, top, rz + 25.0), 1, -hy)
		# The generator on a plate on four legs to the ground.
		var g_under := ga.y - gr
		var half := maxf(gr, 40.0) + 10.0
		_plate_on_legs(boxes, Vector3(gx0, g_under - PLATE_MM, ga.z - half), Vector3(gx1, g_under, ga.z + half), 1,
			-hy if absf(ga.z) < rz else y0)
		d["base"] = {"boxes": boxes, "ground_c": y0 * 0.001}
	else:
		var x0 := -hx - LEG_H_MM
		if with_base:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					_box_mm(boxes, Vector3(x0, sy * (hy - 20.0) - 20.0, sz * (hz - 20.0) - 20.0),
						Vector3(-hx + 1.0, sy * (hy - 20.0) + 20.0, sz * (hz - 20.0) + 20.0))
		var reach := maxf(float(br["fL"]) * 0.5 + 25.0, 90.0)
		for bx in sh["bearings_x_mm"]:
			var x := float(bx)
			if absf(absf(x) - (hx + bw * 0.5 + 2.0)) < 1.0:
				continue
			if x > hx:
				# A bridge above the lid on four posts.
				_plate_on_legs(boxes, Vector3(x - bw * 0.5 - PLATE_MM, -reach, -reach), Vector3(x - bw * 0.5, reach, reach), 0, hx)
			else:
				# Under the housing, between the legs.
				_box_mm(boxes, Vector3(x + bw * 0.5, -hy + 20.0, -hz + 20.0), Vector3(x + bw * 0.5 + PLATE_MM, hy - 20.0, hz - 20.0))
		# The generator's mounting plate under its flange, on four posts.
		var half := maxf(gr, 40.0) + 15.0
		_plate_on_legs(boxes, Vector3(gx0 - PLATE_MM, ga.y - half, ga.z - half), Vector3(gx0, ga.y + half, ga.z + half), 0, hx)
		d["base"] = {"boxes": boxes, "ground_c": x0 * 0.001}


# ---------------------------------------------------------------------------
# Canonical → model
# ---------------------------------------------------------------------------

static func _model_frame(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var g := float(d["base"]["ground_c"])
	var xf: Transform3D
	if str(s["orientation"]) == "horizontal":
		xf = Transform3D(Basis.IDENTITY, Vector3(0.0, -g, 0.0))
	else:
		xf = Transform3D(Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)), Vector3(0.0, -g, 0.0))
	d["model_xf"] = xf
	d["spin_axis"] = "x" if str(s["orientation"]) == "horizontal" else "y"
	# The whole machine's box in the model frame (for the camera, the packed
	# spec and the ports).
	var pts: Array = []
	var hsg: Dictionary = d["housing"]
	var wall := float(hsg["wall_mm"])
	var half := Vector3(float(hsg["axial_mm"]) * 0.5 + wall, float(hsg["hy_mm"]) + wall, float(hsg["hz_mm"]) + wall) * 0.001
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				pts.append(Vector3(half.x * sx, half.y * sy, half.z * sz))
	var gen: Dictionary = d["generator"]
	var ga: Vector3 = gen["axis"]
	var grm := float(gen["r_mm"]) * 0.001
	pts.append(Vector3(float(gen["x1_mm"]) * 0.001, ga.y + grm, ga.z + grm))
	pts.append(Vector3(float(gen["x1_mm"]) * 0.001, ga.y - grm, ga.z - grm))
	pts.append(Vector3(float(d["shaft"]["x0_mm"]) * 0.001, 0, 0))
	for j in d["jets"]:
		pts.append(j["inlet"])
	for r in d["base"]["boxes"]:
		pts.append(r["a"])
		pts.append(r["b"])
	var aabb := AABB(xf * (pts[0] as Vector3), Vector3.ZERO)
	for p in pts:
		aabb = aabb.expand(xf * (p as Vector3))
	d["aabb"] = aabb


# ---------------------------------------------------------------------------
# Runner design rules
# ---------------------------------------------------------------------------

## The proportions that decide how well the wheel turns its jet into work,
## and the penalty each costs. {m, z_opt, b_ratio, max_cups, f_m, f_b, f_z,
## factor, notes: [..]}.
static func runner_rules(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var rn: Dictionary = d["runner"]
	var jd := float(s["jets"]["d_mm"])
	var pcd := float(rn["pcd_mm"])
	var m := pcd / maxf(jd, 0.1)
	var z := int(rn["cups"])
	var z_opt := 15.0 + 0.5 * m
	var b := float(rn["cup_w_mm"]) / maxf(jd, 0.1)
	# Crowding: neighbouring tabs must not touch where they are thickest,
	# where they leave the bowl, nor at the root.
	var k := float(rn["k"])
	var c := PeltonLabParts.CUP
	var max_cups := MAX_INT_CUPS
	for zz in [float(c["bowl_root_z"]), float(c["root_z"])]:
		var rr := PeltonLabCup.radius_at(zz, float(rn["pitch_r_mm"]), k)
		var thick := PeltonLabCup.tab_depth_mm(zz) * k + 1.0
		if rr > 0.0:
			max_cups = mini(max_cups, int(floor(TAU * rr / thick)))
	var f_m := 1.0
	if m < 6.0:
		f_m = 1.0 - 0.04 * pow(6.0 - m, 2.0)
	elif m > 30.0:
		f_m = 1.0 - 0.005 * (m - 30.0)
	var f_b := 1.0
	if b < 2.8:
		f_b = 1.0 - 1.2 * (2.8 - b) / 2.8
	elif b > 4.0:
		f_b = 1.0 - 0.04 * (b - 4.0)
	var f_z := 1.0
	var dz := z_opt - float(z)
	if dz > 2.0:
		f_z = 1.0 - 0.025 * (dz - 2.0)
	elif -dz > 4.0:
		f_z = 1.0 - 0.01 * (-dz - 4.0)
	f_m = clampf(f_m, 0.3, 1.0)
	f_b = clampf(f_b, 0.3, 1.0)
	f_z = clampf(f_z, 0.5, 1.0)
	return {"m": m, "z_opt": z_opt, "b_ratio": b, "max_cups": max_cups,
		"best_jet_mm": float(rn["cup_w_mm"]) / 3.2,
		"f_m": f_m, "f_b": f_b, "f_z": f_z, "factor": f_m * f_b * f_z,
		"eta_runner": ETA_BASE * f_m * f_b * f_z}

const MAX_INT_CUPS := 999


# ---------------------------------------------------------------------------
# Performance
# ---------------------------------------------------------------------------

## Generator efficiency at a shaft speed: its peak at the rated speed, falling
## off either side on a log-speed parabola (copper loss dominates below rated
## speed at a given power, iron and windage above). An estimate shaped on the
## published curves of small PMGs, not a maker's map.
static func generator_eff_at(gen: Dictionary, rpm: float) -> float:
	var rated := maxf(float(gen["rated_rpm"]), 1.0)
	if rpm <= 1.0:
		return 0.0
	var l := log(rpm / rated)
	return float(gen["eff"]) * clampf(1.0 - 0.25 * l * l, 0.25, 1.0)


## The operating numbers at a site. `op` (optional) is a live operating point
## from the Hydro Lab ({q_lps, net_head_m | h_net_m, v_jet_ms}); without it the
## design's own site is solved with PeltonPhysics.
static func performance(d: Dictionary, op: Dictionary = {}, gross_head_m: float = NAN) -> Dictionary:
	var s: Dictionary = d["spec"]
	var st: Dictionary = s["site"]
	var rn: Dictionary = d["runner"]
	var rules: Dictionary = d.get("rules", runner_rules(d))
	var jd := float(s["jets"]["d_mm"]) * 0.001
	var n_jets := int(s["jets"]["count"])
	var q := 0.0
	var h_net := 0.0
	var v_jet := 0.0
	var h_gross := float(st["gross_head_m"]) if is_nan(gross_head_m) else gross_head_m
	var supply := float(st["supply_lps"])
	if not op.is_empty() and float(op.get("q_lps", 0.0)) > 0.0:
		q = float(op["q_lps"]) * 0.001
		h_net = float(op.get("net_head_m", op.get("h_net_m", 0.0)))
		v_jet = float(op.get("v_jet_ms", PeltonPhysics.jet_velocity_ms(h_net)))
	else:
		var o := PeltonPhysics.operating_point_supply_limited(h_gross, float(st["pipe_len_m"]),
				float(st["pipe_d_mm"]) * 0.001, float(st["roughness_mm"]) * 0.001, jd, n_jets,
				supply * 0.001 if supply >= 0.0 else NAN)
		q = float(o["q_m3s"])
		h_net = float(o["h_net_m"])
		v_jet = float(o["v_jet_ms"])
	var pcd := float(rn["pcd_mm"]) * 0.001
	var x := PeltonPhysics.SPEED_RATIO_OPT
	var rpm := PeltonPhysics.rpm_at_ratio(v_jet, pcd, x)
	var v_gross := PeltonPhysics.jet_velocity_ms(h_gross)
	var rpm_run := PeltonPhysics.rpm_at_ratio(v_gross, pcd, 2.0 * x)
	var omega := rpm * TAU / 60.0
	var eta_r := float(rules["eta_runner"])
	var p_hyd := RHO * G * q * h_net
	var p_shaft := p_hyd * eta_r
	var torque := p_shaft / omega if omega > 1e-6 else 0.0
	var u := x * v_jet
	var f_jet := RHO * q * maxf(v_jet - u, 0.0) * FORCE_K
	var f_stall := RHO * q * v_jet * FORCE_K
	var t_stall := f_stall * pcd * 0.5
	var drive: Dictionary = d["drive"]
	var ratio := float(drive["ratio"])
	var gen: Dictionary = d["generator"]["spec"]
	var g_rpm := rpm * ratio
	var g_eff := generator_eff_at(gen, g_rpm)
	var n_bear := (d["shaft"]["bearings_x_mm"] as Array).size()
	var drive_eff := float(drive["eff"]) * pow(BEARING_EFF, n_bear)
	var p_elec := p_shaft * drive_eff * g_eff
	var rated := float(gen["rated_w"])
	var capped := p_elec > rated
	var v_oc := float(gen["v_per_rpm"]) * g_rpm
	var batt := float(st["battery_v"])
	var charges := true
	var cut_in := float(gen.get("cut_in_rpm", 0.0))
	if cut_in > 0.0:
		charges = g_rpm >= cut_in
	elif batt > 0.0:
		charges = v_oc >= 1.2 * batt
	return {"q_lps": q * 1000.0, "h_net_m": h_net, "h_gross_m": h_gross, "v_jet_ms": v_jet,
		"rpm": rpm, "rpm_runaway": rpm_run, "omega": omega, "eta_runner": eta_r,
		"p_hyd_w": p_hyd, "p_shaft_w": p_shaft, "torque_nm": torque, "f_jet_n": f_jet,
		"f_stall_n": f_stall, "t_stall_nm": t_stall, "tip_speed_ms": omega * float(rn["tip_r_mm"]) * 0.001,
		"gen_rpm": g_rpm, "gen_rpm_runaway": rpm_run * ratio, "gen_eff": g_eff, "drive_eff": drive_eff,
		"p_elec_w": minf(p_elec, rated), "p_elec_uncapped_w": p_elec, "capped": capped,
		"v_oc": v_oc, "charges": charges, "battery_v": batt,
		"water_to_wire": (minf(p_elec, rated) / p_hyd) if p_hyd > 1e-6 else 0.0}


# ---------------------------------------------------------------------------
# Masses
# ---------------------------------------------------------------------------

static func _masses(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var rn: Dictionary = d["runner"]
	var ro: Dictionary = d["rotor"]
	var pm := PeltonLabParts.plate_material(str(s["rotor"]["material"]))
	var shaft_r := float(ro["shaft_d_mm"]) * 0.0005
	var disc_area := PI * (pow(float(ro["disc_r_mm"]) * 0.001, 2.0) - shaft_r * shaft_r)
	var discs := 2.0 * disc_area * float(ro["disc_t_mm"]) * 0.001 * float(pm["density"])
	var spacer := PI * (pow(float(ro["spacer_r_mm"]) * 0.001, 2.0) - shaft_r * shaft_r) \
		* float(ro["gap_mm"]) * 0.001 * float(pm["density"])
	var hub := (PI * pow(float(ro["flange_d_mm"]) * 0.0005, 2.0) * float(ro["flange_t_mm"]) * 0.001 \
		+ PI * pow(float(ro["boss_d_mm"]) * 0.0005, 2.0) * float(ro["boss_len_mm"]) * 0.001) * 7850.0
	var cups := float(rn["cup_mass_kg"]) * float(rn["cups"])
	var sh: Dictionary = d["shaft"]
	var shaft := PI * shaft_r * shaft_r * (float(sh["x1_mm"]) - float(sh["x0_mm"])) * 0.001 * 7850.0
	var hsg: Dictionary = d["housing"]
	var hm := PeltonLabParts.plate_material(str(hsg["material"]))
	var ax := float(hsg["axial_mm"]) * 0.001
	var hy := float(hsg["hy_mm"]) * 0.002
	var hz := float(hsg["hz_mm"]) * 0.002
	var housing_area := 2.0 * (hy * hz) + ax * hz + 2.0 * ax * hy   # two end walls, a top, two sides; bottom open
	var housing := housing_area * float(hsg["wall_mm"]) * 0.001 * float(hm["density"])
	var gen := float(d["generator"]["spec"]["mass_kg"])
	var rotating := discs + spacer + hub + cups
	return {"cups": cups, "discs": discs, "spacer": spacer, "hub": hub, "shaft": shaft, "housing": housing,
		"generator": gen, "rotating": rotating,
		"total": rotating + shaft + housing + gen + 2.5 * float((sh["bearings_x_mm"] as Array).size())}


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

static func _check(out: Array, level: String, text: String) -> void:
	out.append({"level": level, "text": text})


static func _checks(d: Dictionary) -> Array:
	var out: Array = []
	var s: Dictionary = d["spec"]
	var rn: Dictionary = d["runner"]
	var ro: Dictionary = d["rotor"]
	var rules: Dictionary = d["rules"]
	var perf: Dictionary = d["perf"]
	var jd := float(s["jets"]["d_mm"])
	var z := int(rn["cups"])
	# --- the runner's proportions
	var m := float(rules["m"])
	if m < 6.0:
		_check(out, "warn", "Jet ratio PCD/d = %.1f — the wheel is small for this jet (aim for 10 or more; Thake)." % m)
	else:
		_check(out, "ok", "Jet ratio PCD/d = %.1f." % m)
	var b := float(rules["b_ratio"])
	if b < 2.8:
		_check(out, "warn", "The jet (%.0f mm) is wide for %.0f mm cups (B/d %.2f) — water spills over the rims. A jet of %.0f mm suits them." % [jd, float(rn["cup_w_mm"]), b, float(rules["best_jet_mm"])])
	elif b > 4.0:
		_check(out, "info", "The cups are big for a %.0f mm jet (B/d %.2f): more weight and windage than it needs." % [jd, b])
	else:
		_check(out, "ok", "Cup width / jet = %.2f (3.1–3.4 is the textbook proportion)." % b)
	var z_opt := float(rules["z_opt"])
	if z > int(rules["max_cups"]):
		_check(out, "error", "%d cups do not fit: their tabs collide (at most %d on this wheel)." % [z, int(rules["max_cups"])])
	elif float(z) < z_opt - 2.0:
		_check(out, "warn", "%d cups — some of the jet slips between them (about %d suit this jet ratio: 15 + m/2)." % [z, int(round(z_opt))])
	elif float(z) > z_opt + 4.0:
		_check(out, "info", "%d cups — more than the %d the jet ratio needs; they add weight and windage." % [z, int(round(z_opt))])
	else:
		_check(out, "ok", "%d cups (the 15 + m/2 rule says %d)." % [z, int(round(z_opt))])
	# --- the rotor
	var hole_c := float(PeltonLabParts.bolt(str(s["runner"]["cup_bolt"]))["hole"])
	var outer_bolt := float((rn["bolt_radii_mm"] as Array).max())
	var inner_bolt := float((rn["bolt_radii_mm"] as Array).min())
	if float(ro["disc_r_mm"]) < outer_bolt + 1.5 * hole_c:
		_check(out, "error", "The discs (Ø %.0f mm) do not reach past the cup bolts — at least Ø %.0f mm." % [float(ro["disc_r_mm"]) * 2.0, 2.0 * (outer_bolt + 1.5 * hole_c)])
	elif float(ro["disc_r_mm"]) > float(rn["bowl_root_r_mm"]) + 1.0:
		_check(out, "error", "The discs (Ø %.0f mm) run into the bowls — at most Ø %.0f mm." % [float(ro["disc_r_mm"]) * 2.0, float(rn["bowl_root_r_mm"]) * 2.0])
	# The tab's depth at the bolt stations takes M6 (two bolts: the inner,
	# shallower station sets it) or M10 (one bolt) at the STL's own size, in
	# proportion when the cup is scaled.
	var limit_mm := (6.0 if int(s["runner"]["cup_bolts"]) >= 2 else 10.0) * float(rn["k"])
	var bolt_d := float(PeltonLabParts.bolt(str(s["runner"]["cup_bolt"]))["d"])
	if bolt_d > limit_mm * 1.15:
		_check(out, "warn", "%s bolts are big for these tabs (up to about M%d at this cup size)." % [str(s["runner"]["cup_bolt"]).to_upper(), maxi(3, int(round(limit_mm)))])
	var boss_r := float(ro["boss_d_mm"]) * 0.5
	var pcd_r := float(ro["bolt_pcd_mm"]) * 0.5
	var hole_h := float(ro["bolt_hole_mm"])
	if pcd_r - hole_h * 0.75 < boss_r + 1.0:
		_check(out, "error", "The hub bolt circle (Ø %.0f mm) cuts into the hub boss (Ø %.0f mm)." % [pcd_r * 2.0, boss_r * 2.0])
	if pcd_r + hole_h * 0.75 > float(ro["spacer_r_mm"]):
		_check(out, "error", "The hub bolt circle (Ø %.0f mm) is outside the spacer ring under the cup tabs (Ø %.0f mm)." % [pcd_r * 2.0, float(ro["spacer_r_mm"]) * 2.0])
	if boss_r > inner_bolt - hole_c:
		_check(out, "error", "The hub (Ø %.0f mm) is bigger than the space inside the cup tabs." % (boss_r * 2.0))
	if float(ro["shaft_d_mm"]) + 6.0 > float(ro["boss_d_mm"]):
		_check(out, "error", "The hub boss is too thin for a %.0f mm shaft." % float(ro["shaft_d_mm"]))
	# --- jets
	var max_j := int(PeltonLabParts.MAX_JETS[str(s["orientation"])])
	if int(s["jets"]["count"]) > max_j:
		_check(out, "warn", "A %s takes at most %d jets." % [str(PeltonLabParts.ORIENTATION_LABELS[s["orientation"]]).to_lower(), max_j])
	for j in d["jets"]:
		if not bool(j["inside"]):
			_check(out, "error", "The nozzle at %d° sits outside the housing — make the housing bigger." % int(j["deg"]))
	# --- the housing
	var hsg: Dictionary = d["housing"]
	if float(hsg["axial_mm"]) < 2.5 * float(rn["cup_w_mm"]):
		_check(out, "warn", "The housing is narrow (%.0f mm across the shaft for %.0f mm cups) — the leaving water splashes back onto the wheel; 3 × the cup width is the rule of thumb." % [float(hsg["axial_mm"]), float(rn["cup_w_mm"])])
	if float(hsg["hy_mm"]) < float(rn["tip_r_mm"]) + 10.0 or float(hsg["hz_mm"]) < float(rn["tip_r_mm"]) + 10.0:
		_check(out, "error", "The wheel (Ø %.0f mm) does not fit in the housing." % (float(rn["tip_r_mm"]) * 2.0))
	# --- speed, strength, life
	var omega_run := float(perf["rpm_runaway"]) * TAU / 60.0
	var fc := float(rn["cup_mass_kg"]) * omega_run * omega_run * float(rn["cg_r_mm"]) * 0.001
	var n_b := int(s["runner"]["cup_bolts"])
	var cap := float(n_b) * 2.0 * PeltonLabParts.bolt_shear_n(str(s["runner"]["cup_bolt"]))
	var sf_bolt := cap / maxf(fc, 1e-6)
	d["strength"] = {"f_cup_runaway_n": fc, "bolt_sf": sf_bolt}
	if sf_bolt < 1.5:
		_check(out, "error", "At runaway (%d rpm) each cup pulls %.0f N — the cup bolts carry it %.1f × over (needs 1.5): bigger or more bolts." % [int(perf["rpm_runaway"]), fc, sf_bolt])
	else:
		_check(out, "ok", "At runaway (%d rpm) each cup pulls %.0f N; the bolts hold %.1f × that." % [int(perf["rpm_runaway"]), fc, sf_bolt])
	var k := float(rn["k"])
	var tab_net := maxf(PeltonLabCup.tab_depth_mm(float(PeltonLabParts.CUP_BOLT_Z_TWO[0])) * k - hole_c, 0.1) * float(rn["tab_w_mm"])
	var sigma := fc / tab_net
	var allow := float(PeltonLabParts.cup_material(str(s["runner"]["cup_material"]))["stress_mpa"])
	d["strength"]["tab_mpa"] = sigma
	if sigma > allow:
		_check(out, "error", "The cup tabs would tear at runaway: %.1f MPa through the bolt hole, %s takes %.0f MPa." % [sigma, str(PeltonLabParts.cup_material(str(s["runner"]["cup_material"]))["label"]), allow])
	elif sigma > allow * 0.6:
		_check(out, "warn", "The cup tabs are working hard at runaway (%.1f of %.0f MPa)." % [sigma, allow])
	var disc_t := float(ro["disc_t_mm"])
	var bearing_stress := fc / (float(n_b) * 2.0 * float(PeltonLabParts.bolt(str(s["runner"]["cup_bolt"]))["d"]) * disc_t)
	var pm := PeltonLabParts.plate_material(str(s["rotor"]["material"]))
	if bearing_stress > 1.5 * float(pm["stress_mpa"]):
		_check(out, "error", "The cup bolts would tear out of %.0f mm %s discs at runaway (%.0f MPa bearing)." % [disc_t, str(pm["label"]).to_lower(), bearing_stress])
	# Hub bolts: the stall torque through the bolt circle.
	var t_stall := float(perf["t_stall_nm"])
	var hub_shear := t_stall / maxf(float(s["hub"]["bolts"]) * pcd_r * 0.001, 1e-6)
	var hub_sf := PeltonLabParts.bolt_shear_n(str(s["hub"]["bolt"])) / maxf(hub_shear, 1e-6)
	if hub_sf < 1.5:
		_check(out, "error", "The hub bolts carry the stalled torque (%.0f N·m) only %.1f × over — more or bigger bolts." % [t_stall, hub_sf])
	# Shaft: the stalled jet's force and the rotor's weight, as bending at the
	# worst section, with the stalled torque (Shigley, max-shear).
	var sh: Dictionary = d["shaft"]
	var bx: Array = sh["bearings_x_mm"]
	var f := sqrt(pow(float(perf["f_stall_n"]), 2.0) + pow(float(d["mass"]["rotating"]) * G, 2.0))
	var r1 := 0.0
	var r2 := 0.0
	var mmax := 0.0
	if str(s["drive"]["layout"]) == "straddle":
		var a := absf(float(bx[0])) * 0.001
		var bb := absf(float(bx[1])) * 0.001
		r1 = f * bb / (a + bb)
		r2 = f * a / (a + bb)
		mmax = f * a * bb / (a + bb)
	else:
		var a1 := float(bx[0]) * 0.001
		var a2 := float(bx[1]) * 0.001
		var span := maxf(a2 - a1, 1e-3)
		r1 = f * a2 / span
		r2 = f * a1 / span
		mmax = f * a1
	var ds := float(sh["d_mm"]) * 0.001
	var tau := 16.0 / (PI * ds * ds * ds) * sqrt(mmax * mmax + t_stall * t_stall) / 1e6
	d["strength"]["shaft_mpa"] = tau
	if tau > PeltonLabParts.SHAFT_TAU_ALLOW_MPA:
		_check(out, "error", "A %.0f mm shaft is over-stressed (%.0f MPa with the jet stalled; %.0f allowed) — thicker shaft or bearings closer to the wheel." % [float(sh["d_mm"]), tau, PeltonLabParts.SHAFT_TAU_ALLOW_MPA])
	else:
		_check(out, "ok", "Shaft: %.0f MPa with the jet stalled (%.0f allowed)." % [tau, PeltonLabParts.SHAFT_TAU_ALLOW_MPA])
	var br: Dictionary = sh["bearing"]
	var p_b := maxf(absf(r1), absf(r2))
	var l10 := pow(float(br["C_kN"]) * 1000.0 / maxf(p_b, 1.0), 3.0) * 1e6 / (60.0 * maxf(float(perf["rpm"]), 1.0))
	d["strength"]["l10_h"] = l10
	d["strength"]["bearing_load_n"] = p_b
	if l10 < TARGET_L10_H:
		_check(out, "warn", "The busier bearing (%.0f N) lasts about %s hours — under the %d h a turbine wants." % [p_b, _fmt_int(l10), int(TARGET_L10_H)])
	else:
		_check(out, "ok", "Bearings: %s hours (L10) at the design speed." % _fmt_int(minf(l10, 9.9e6)))
	if float(perf["rpm_runaway"]) > float(br["max_rpm"]):
		_check(out, "warn", "Runaway (%d rpm) is past the %s's %d rpm limit." % [int(perf["rpm_runaway"]), str(br["pillow"] if not bool(sh["flange"]) else br["flange"]), int(br["max_rpm"])])
	# --- drive + generator
	var dv: Dictionary = d["drive"]
	var dtype := str(dv["type"])
	var gen: Dictionary = d["generator"]["spec"]
	if dtype == "direct":
		var cpl: Dictionary = dv["coupler"]
		if str(s["drive"]["coupler"]) == "jaw" and t_stall > float(cpl["torque_nm"]):
			_check(out, "warn", "The %s jaw coupler is rated %.0f N·m; the stalled wheel makes %.0f." % [str(cpl["size"]), float(cpl["torque_nm"]), t_stall])
	else:
		var dmin := minf(float(dv["d1_mm"]), float(dv["d2_mm"]))
		if dtype == "vbelt" and dmin < float(PeltonLabParts.DRIVES["vbelt"]["min_d_mm"]):
			_check(out, "warn", "A %.0f mm V-belt pulley is under the A section's 75 mm minimum — the belt wears fast." % dmin)
		if dtype != "vbelt":
			var zmin := mini(int(s["drive"]["driver_teeth"]), int(s["drive"]["driven_teeth"]))
			var need := int(PeltonLabParts.DRIVES[dtype]["min_teeth"])
			if zmin < need:
				_check(out, "warn", "%d teeth is under the %d a %s wants." % [zmin, need, str(PeltonLabParts.DRIVES[dtype]["label"]).to_lower()])
		if dv.has("wrap_deg") and float(dv["wrap_deg"]) < 120.0:
			_check(out, "warn", "The belt wraps only %.0f° of the small pulley (120° minimum) — longer centres." % float(dv["wrap_deg"]))
		var belt_v := PI * float(dv["d1_mm"]) * 0.001 * float(perf["rpm"]) / 60.0
		if belt_v > 30.0:
			_check(out, "warn", "The belt runs at %.0f m/s (30 m/s is the limit)." % belt_v)
	var g_rpm := float(perf["gen_rpm"])
	var rated_rpm := float(gen["rated_rpm"])
	if g_rpm < 0.5 * rated_rpm:
		_check(out, "warn", "The generator turns %d rpm — slow for its %d rpm rating; gear it up %.1f : 1." % [int(g_rpm), int(rated_rpm), rated_rpm / maxf(g_rpm, 1.0)])
	elif g_rpm > 1.6 * rated_rpm:
		_check(out, "warn", "The generator turns %d rpm — fast for its %d rpm rating; gear it down." % [int(g_rpm), int(rated_rpm)])
	else:
		_check(out, "ok", "Generator at %d rpm (rated %d), %.0f %% efficient." % [int(g_rpm), int(rated_rpm), float(perf["gen_eff"]) * 100.0])
	if float(perf["gen_rpm_runaway"]) > float(gen["max_rpm"]):
		_check(out, "warn", "With the load lost the generator would reach %d rpm, past its %d rpm limit — fit a dump load." % [int(perf["gen_rpm_runaway"]), int(gen["max_rpm"])])
	if not bool(perf["charges"]):
		if float(gen.get("cut_in_rpm", 0.0)) > 0.0:
			_check(out, "warn", "The alternator only starts charging from %d rpm; it turns %d." % [int(gen["cut_in_rpm"]), int(g_rpm)])
		else:
			_check(out, "warn", "It makes %.1f V open circuit — not enough to charge a %.0f V bank (about %.0f V needed); gear up or pick a higher-voltage generator." % [float(perf["v_oc"]), float(perf["battery_v"]), 1.2 * float(perf["battery_v"])])
	if bool(perf["capped"]):
		_check(out, "info", "The water gives the shaft %.0f W but the generator is rated %.0f W." % [float(perf["p_shaft_w"]) * float(perf["drive_eff"]) * float(perf["gen_eff"]), float(gen["rated_w"])])
	return out


static func _fmt_int(v: float) -> String:
	var n := int(v)
	var t := str(n)
	var o := ""
	var c := 0
	for i in range(t.length() - 1, -1, -1):
		o = t[i] + o
		c += 1
		if c % 3 == 0 and i > 0:
			o = "," + o
	return o


static func worst_level(d: Dictionary) -> String:
	var lv := "ok"
	for c in d["checks"]:
		var l := str(c["level"])
		if l == "error":
			return "error"
		if l == "warn":
			lv = "warn"
	return lv


# ---------------------------------------------------------------------------
# Bill of materials
# ---------------------------------------------------------------------------

## Typical cost per cup by material (USD, retail, small quantities).
const CUP_COST := {"pla": 3.0, "petg": 3.5, "nylon": 8.0, "alu_cast": 15.0, "bronze": 35.0, "stainless": 45.0}
const PLATE_COST_PER_KG := {"steel": 4.0, "stainless": 9.0, "alu": 10.0, "hdpe": 6.0, "plywood": 4.0, "acrylic": 12.0}

static func _bom(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var rn: Dictionary = d["runner"]
	var ro: Dictionary = d["rotor"]
	var sh: Dictionary = d["shaft"]
	var ms: Dictionary = d["mass"]
	var rows: Array = []
	var z := int(rn["cups"])
	var cm := str(s["runner"]["cup_material"])
	rows.append({"item": "Pelton cup", "qty": z, "spec": "%.0f mm, %s" % [float(rn["cup_w_mm"]), str(PeltonLabParts.cup_material(cm)["label"])],
		"cost": float(CUP_COST.get(cm, 8.0)) * z, "kg": float(ms["cups"])})
	var dm := str(s["rotor"]["material"])
	rows.append({"item": "Rotor disc", "qty": 2, "spec": "Ø %.0f × %.0f mm %s, %d + %d holes" % [float(ro["disc_r_mm"]) * 2.0,
		float(ro["disc_t_mm"]), str(PeltonLabParts.plate_material(dm)["label"]).to_lower(), z * int(s["runner"]["cup_bolts"]), int(s["hub"]["bolts"])],
		"cost": float(ms["discs"]) * float(PLATE_COST_PER_KG.get(dm, 4.0)) + 30.0, "kg": float(ms["discs"])})
	rows.append({"item": "Spacer ring", "qty": 1, "spec": "Ø %.0f × %.1f mm, %d hub-bolt holes" % [float(ro["spacer_r_mm"]) * 2.0, float(ro["gap_mm"]), int(s["hub"]["bolts"])],
		"cost": float(ms["spacer"]) * float(PLATE_COST_PER_KG.get(dm, 4.0)) + 10.0, "kg": float(ms["spacer"])})
	rows.append({"item": "Flanged hub", "qty": 1, "spec": "%.0f mm bore%s, flange Ø %.0f, %d × %s on Ø %.0f" % [float(ro["shaft_d_mm"]),
		" keyed" if bool(s["hub"]["keyway"]) else "", float(ro["flange_d_mm"]), int(s["hub"]["bolts"]), str(s["hub"]["bolt"]).to_upper(), float(ro["bolt_pcd_mm"])],
		"cost": 35.0, "kg": float(ms["hub"])})
	var cb := str(s["runner"]["cup_bolt"]).to_upper()
	var stack := float(ro["gap_mm"]) + 2.0 * float(ro["disc_t_mm"])
	rows.append({"item": "Cup bolt + nyloc + 2 washers", "qty": z * int(s["runner"]["cup_bolts"]),
		"spec": "%s × %d" % [cb, _bolt_len(stack, float(PeltonLabParts.bolt(str(s["runner"]["cup_bolt"]))["d"]))],
		"cost": 0.35 * z * int(s["runner"]["cup_bolts"]), "kg": 0.01 * z * int(s["runner"]["cup_bolts"])})
	var hstack := stack + float(ro["flange_t_mm"])
	rows.append({"item": "Hub bolt + nyloc", "qty": int(s["hub"]["bolts"]),
		"spec": "%s × %d" % [str(s["hub"]["bolt"]).to_upper(), _bolt_len(hstack, float(PeltonLabParts.bolt(str(s["hub"]["bolt"]))["d"]))],
		"cost": 0.6 * int(s["hub"]["bolts"]), "kg": 0.02 * int(s["hub"]["bolts"])})
	var slen := float(sh["x1_mm"]) - float(sh["x0_mm"])
	rows.append({"item": "Shaft", "qty": 1, "spec": "Ø %.0f × %.0f mm 1045 steel%s" % [float(sh["d_mm"]), slen,
		", keyway" if bool(sh["key"]) else ""], "cost": 15.0 + slen * 0.02, "kg": float(ms["shaft"])})
	var br: Dictionary = sh["bearing"]
	var bname := str(br["flange"]) if bool(sh["flange"]) else str(br["pillow"])
	rows.append({"item": "Bearing", "qty": (sh["bearings_x_mm"] as Array).size(), "spec": "%s (%.0f mm insert)" % [bname, float(br["bore"])],
		"cost": 14.0 * (sh["bearings_x_mm"] as Array).size(), "kg": 1.1 * (sh["bearings_x_mm"] as Array).size()})
	var dv: Dictionary = d["drive"]
	match str(dv["type"]):
		"direct":
			var cpl: Dictionary = dv["coupler"]
			rows.append({"item": "Coupler", "qty": 1, "spec": "%s %s" % [str(cpl["size"]), str(PeltonLabParts.COUPLERS[str(s["drive"]["coupler"])]["label"]).to_lower()],
				"cost": 25.0, "kg": 0.4})
		"vbelt":
			rows.append({"item": "V-belt pulleys", "qty": 2, "spec": "A section, Ø %.0f + Ø %.0f mm" % [float(dv["d1_mm"]), float(dv["d2_mm"])], "cost": 40.0, "kg": 1.5})
			rows.append({"item": "V-belt", "qty": 1, "spec": "A section, %.0f mm pitch length" % float(dv["belt_len_mm"]), "cost": 10.0, "kg": 0.2})
		"timing":
			rows.append({"item": "Timing pulleys", "qty": 2, "spec": "HTD 5M, %dT + %dT" % [int(s["drive"]["driver_teeth"]), int(s["drive"]["driven_teeth"])], "cost": 45.0, "kg": 0.8})
			rows.append({"item": "Timing belt", "qty": 1, "spec": "HTD 5M-15, %.0f mm pitch length" % float(dv["belt_len_mm"]), "cost": 15.0, "kg": 0.1})
		"gear":
			rows.append({"item": "Spur gears", "qty": 2, "spec": "Module %.1f, %dT + %dT" % [float(s["drive"]["module_mm"]), int(s["drive"]["driver_teeth"]), int(s["drive"]["driven_teeth"])], "cost": 60.0, "kg": 1.2})
	var gen: Dictionary = d["generator"]["spec"]
	rows.append({"item": "Generator", "qty": 1, "spec": str(gen["label"]), "cost": float(gen["cost"]), "kg": float(gen["mass_kg"])})
	rows.append({"item": "Nozzle", "qty": int(s["jets"]["count"]), "spec": "%.0f mm jet" % float(s["jets"]["d_mm"]), "cost": 20.0 * int(s["jets"]["count"]), "kg": 0.4 * int(s["jets"]["count"])})
	var hsg: Dictionary = d["housing"]
	var hm := str(hsg["material"])
	rows.append({"item": "Housing", "qty": 1, "spec": "%.0f × %.0f × %.0f mm inside, %.0f mm %s%s" % [float(hsg["axial_mm"]), float(hsg["hy_mm"]) * 2.0,
		float(hsg["hz_mm"]) * 2.0, float(hsg["wall_mm"]), str(PeltonLabParts.plate_material(hm)["label"]).to_lower(), ", acrylic window" if bool(hsg["window"]) else ""],
		"cost": float(ms["housing"]) * float(PLATE_COST_PER_KG.get(hm, 4.0)) + 40.0, "kg": float(ms["housing"])})
	return rows


static func _bolt_len(grip_mm: float, d_mm: float) -> int:
	var need := grip_mm + 1.5 * d_mm + 3.0
	for l in [10, 12, 16, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 90, 100, 110, 120, 130, 140, 150]:
		if float(l) >= need:
			return l
	return int(ceil(need / 10.0) * 10.0)


static func bom_total(d: Dictionary) -> Dictionary:
	var c := 0.0
	var kg := 0.0
	for r in d["bom"]:
		c += float(r["cost"])
		kg += float(r["kg"])
	return {"cost": c, "kg": kg}


static func bom_csv(d: Dictionary) -> String:
	var o := "item,qty,spec,cost_usd,mass_kg\n"
	for r in d["bom"]:
		o += "\"%s\",%d,\"%s\",%.2f,%.3f\n" % [str(r["item"]), int(r["qty"]), str(r["spec"]).replace("\"", "'"), float(r["cost"]), float(r["kg"])]
	var t := bom_total(d)
	o += "\"Total\",,,%.2f,%.3f\n" % [float(t["cost"]), float(t["kg"])]
	return o


# ---------------------------------------------------------------------------
# What the rest of the game reads
# ---------------------------------------------------------------------------

## A crate round the assembled machine.
## The machine as it ships: the runner bolted up on its hub (one fragile
## piece), the shaft, the housing panels flat, the generator, and the small
## parts in a box.
static func parts_for_packing(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var ro: Dictionary = d["rotor"]
	var rn: Dictionary = d["runner"]
	var sh: Dictionary = d["shaft"]
	var ms: Dictionary = d["mass"]
	var out: Array = []
	var tip_d := (float(ro["disc_r_mm"]) * 2.0 + float(rn.get("cup_w_mm", 80.0)) * 2.0) * 0.001
	var width := maxf(float(rn.get("cup_w_mm", 80.0)) * 0.001, (float(ro["gap_mm"]) + 2.0 * float(ro["disc_t_mm"])) * 0.001) + 0.04
	out.append(PackKitter.part("Runner (assembled)", "piece", tip_d, tip_d, width,
		float(ms["rotating"]), 1, {"group": "runner", "fragile": true, "own_crate": tip_d > 0.6}))
	var slen := (float(sh["x1_mm"]) - float(sh["x0_mm"])) * 0.001
	var sd := float(sh["d_mm"]) * 0.001
	out.append(PackKitter.part("Shaft", "stick", maxf(slen, 0.05), sd, sd, float(ms["shaft"]), 1,
		{"group": "shaft", "round": true}))
	var hsg: Dictionary = d["housing"]
	var ax := float(hsg["axial_mm"]) * 0.001
	var hy := float(hsg["hy_mm"]) * 0.002
	var hz := float(hsg["hz_mm"]) * 0.002
	var t := maxf(float(hsg["wall_mm"]) * 0.001, 0.002)
	var area := 2.0 * (hy * hz) + ax * hz + 2.0 * ax * hy
	var kg_m2 := float(ms["housing"]) / maxf(area, 1e-4)
	out.append(PackKitter.part("Housing end wall", "sheet", maxf(hy, hz), minf(hy, hz), t, hy * hz * kg_m2, 2, {"group": "housing"}))
	out.append(PackKitter.part("Housing top", "sheet", maxf(ax, hz), minf(ax, hz), t, ax * hz * kg_m2, 1, {"group": "housing"}))
	out.append(PackKitter.part("Housing side", "sheet", maxf(ax, hy), minf(ax, hy), t, ax * hy * kg_m2, 2, {"group": "housing"}))
	var gen: Dictionary = d["generator"]["spec"]
	var gkg := float(gen["mass_kg"])
	var gside := clampf(pow(maxf(gkg, 0.5) / 3000.0, 1.0 / 3.0) * 1.3, 0.08, 0.6)
	out.append(PackKitter.part(str(gen.get("label", "Generator")), "piece", gside * 1.4, gside, gside, gkg, 1,
		{"group": "generator", "this_side_up": true}))
	var nb := (sh["bearings_x_mm"] as Array).size()
	if nb > 0:
		out.append(PackKitter.part("Bearing", "loose", 0.15, 0.1, 0.08, 2.5, nb, {"group": "hardware"}))
	var jets := int(s["jets"]["count"])
	if jets > 0:
		out.append(PackKitter.part("Nozzle", "loose", 0.15, 0.06, 0.06, 0.4, jets, {"group": "hardware"}))
	return out


static func packed_spec(d: Dictionary) -> Dictionary:
	var env := PackKitter.envelope(PackKitter.kit(parts_for_packing(d)), "crate")
	if not env.is_empty():
		return env
	return _legacy_packed_spec(d)


static func _legacy_packed_spec(d: Dictionary) -> Dictionary:
	var a: AABB = d["aabb"]
	var ext := a.size + Vector3.ONE * 0.08
	return {"w_m": ext.x, "d_m": ext.z, "h_m": ext.y, "mass_kg": float(d["mass"]["total"]) + 8.0,
		"form": "crate", "stackable": false, "this_side_up": true, "source": "computed"}


## Connection ports in the MODEL frame: the first nozzle's inlet, the open
## bottom of the housing (tailwater), the generator's DC terminals.
static func ports(d: Dictionary) -> Array:
	var xf: Transform3D = d["model_xf"]
	var out: Array = []
	var j: Dictionary = d["jets"][0]
	var inlet: Vector3 = xf * (j["inlet"] as Vector3)
	var back: Vector3 = xf.basis * (-(j["dir"] as Vector3))
	out.append({"id": "penstock_in", "label": "Nozzle inlet (%.0f mm jet)" % float(j["d_mm"]), "pos": inlet,
		"normal": back.normalized(), "handle": "res_in_0", "role": "input", "kind": "water", "conduit": "poly_penstock"})
	var hsg: Dictionary = d["housing"]
	var bottom: Vector3
	if str(hsg["open"]) == "-y":
		bottom = Vector3(0.0, -float(hsg["hy_mm"]) * 0.001, 0.0)
	else:
		bottom = Vector3(-float(hsg["axial_mm"]) * 0.0005, 0.0, 0.0)
	var b_model := xf * bottom
	out.append({"id": "tailrace", "label": "Housing bottom (tailwater)", "pos": Vector3(b_model.x, 0.02, b_model.z),
		"normal": Vector3.DOWN, "handle": "res_out_0", "role": "output", "kind": "water", "conduit": ""})
	var gen: Dictionary = d["generator"]
	var ga: Vector3 = gen["axis"]
	var rear := Vector3(float(gen["x1_mm"]) * 0.001, ga.y, ga.z)
	var rear_m := xf * rear
	var side := xf.basis * Vector3(0, 0, 1) * 0.025
	var out_dir := (xf.basis * Vector3(1, 0, 0)).normalized()
	out.append({"id": "dc_pos", "label": "DC +", "pos": rear_m + side, "normal": out_dir, "handle": "res_out_1_pos",
		"role": "positive", "kind": "dc_electricity", "conduit": ""})
	out.append({"id": "dc_neg", "label": "DC −", "pos": rear_m - side, "normal": out_dir, "handle": "res_out_1_neg",
		"role": "negative", "kind": "dc_electricity", "conduit": ""})
	return out


## The graph turbine's specs patch for this wheel, priced at `op` (the Hydro
## Lab's live operating point) when given: the runner's PCD, its efficiency
## (the design rules' penalty applied), the drive × generator efficiency at the
## speed the generator turns, the generator's nameplate, the jets.
static func turbine_patch(d: Dictionary, op: Dictionary = {}, gross_head_m: float = NAN) -> Dictionary:
	var s: Dictionary = d["spec"]
	var perf := performance(d, op, gross_head_m)
	var gen: Dictionary = d["generator"]["spec"]
	return {
		"turbine_kind": "designed_pelton",
		"pelton_spec": PeltonLabSpec.to_json_safe(s),
		"runner_pcd_m": float(d["runner"]["pcd_mm"]) * 0.001,
		"nozzle_count": int(s["jets"]["count"]),
		"nozzle_diameter_mm": float(s["jets"]["d_mm"]),
		"turbine_efficiency": float(d["rules"]["eta_runner"]),
		"generator_efficiency": clampf(float(perf["drive_eff"]) * float(perf["gen_eff"]), 0.05, 1.0),
		"max_power_w": float(gen["rated_w"]),
		"model_id": PeltonLabBuilder.MODEL_ID,
	}
