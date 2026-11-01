class_name WindLabDesign
extends RefCounted

## A solved wind turbine: the rotor (its shape, swept area, Cp curve), the
## drive and generator, the operating point at every wind speed (the rotor's
## torque meeting the generator's), the power curve and the year's energy,
## the start-up wind, the parts to cut, score and print, the masses, the bill
## of materials and the checks. Pure static; solve() caches by the spec's key.
##
## Frames: the MODEL frame is the placed prop's — metres, +Y up, the ground at
## y = 0. A vertical axis rotor turns about +Y over the mast; a propeller's
## hub is on the mast top, its axis along +Z (downwind), the rotor facing −Z.
## Blade sections and cut parts are in millimetres (WindLabMesh / the cut
## files' own frames).
##
## THE OPERATING POINT at wind v: the rotor gives T_a(ω) = Cq(λ)·½ρv²·A·R,
## the drive and generator take T_l(ω) = G·T_gen(G·ω)/η_drive + T_bearings.
## The rotor settles where they meet, coming up from rest (a rotor that
## cannot break the generator's cogging never turns). Air density from the
## ISA at the site's altitude; hub-height wind from the log profile — both
## WindTurbineSource's own, so the graph's wind node reads the same air.

const SURVIVAL_MS := 40.0       ## parked survival wind for the mast check
const CURVE_DV := 0.5
const CURVE_TOP := 30.0
const SCAN_N := 40

static var _cache: Dictionary = {}


static func solve(spec: Dictionary) -> Dictionary:
	var s := WindLabSpec.resolve(spec)
	var key := WindLabSpec.key_of(s)
	if _cache.has(key):
		return _cache[key]
	if _cache.size() > 48:
		_cache.clear()
	var d := _solve(s)
	_cache[key] = d
	return d


static func clear_cache() -> void:
	_cache.clear()
	WindLabGen.clear_cache()


static func _solve(s: Dictionary) -> Dictionary:
	var d := {"spec": s}
	var t := str(s["type"])
	d["info"] = WindLabParts.type_info(t)
	d["vawt"] = WindLabParts.is_vawt(t)
	d["R_m"] = WindLabAero.radius_m(s)
	d["area_m2"] = WindLabAero.area_m2(s)
	d["rho"] = WindTurbineSource.air_density_at_altitude(float(s["site"]["altitude_m"]))
	d["cp"] = WindLabAero.cp_model(s, float(s["site"]["design_wind_ms"]))
	d["spin_dir"] = -1.0 if t == "savonius" else 1.0
	_geometry(d)
	_drive(d)
	_hub_height(d)
	_curve(d)
	_parts(d)
	_prints(d)
	_masses(d)
	d["bom"] = _bom(d)
	d["checks"] = _checks(d)
	_extent(d)
	return d


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

static func _geometry(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var r: Dictionary = s["rotor"]
	var t := str(s["type"])
	var sheet := WindLabParts.sheet(str(s["build"]["sheet"]))
	d["sheet_t_mm"] = float(sheet["t_mm"])
	d["blades"] = []
	d["ugr"] = {}
	if t in ["ugrinsky", "savonius", "lenz2"]:
		d["blades"] = WindLabAero.vawt_blades(s)
		if t == "ugrinsky":
			d["ugr"] = WindLabAero.ugrinsky_geom(s)
		var mr := 0.0
		for b in d["blades"]:
			mr = maxf(mr, WindLabAero._max_r(b["pts"]))
		d["tip_r_mm"] = mr
	else:
		d["tip_r_mm"] = float(r["d_mm"]) * 0.5
	d["stations"] = WindLabAero.hawt_blade(s) if t in ["hawt", "multiblade"] else []
	if t == "multiblade":
		# A farm windmill's plates: the optimum-rotor layout at its slow tip
		# speed, on a curved plate.
		var s2 := s.duplicate(true)
		s2["rotor"]["tsr"] = float(d["cp"]["lam_opt"])
		s2["rotor"]["construction"] = "pvc_pipe"
		d["stations"] = WindLabAero.hawt_blade(s2)


## Drive: the step-up ratio G (generator turns G times per rotor turn) and
## its efficiency; pulley / gear pitch diameters for the builder.
static func _drive(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var dr: Dictionary = s["drive"]
	var ty := str(dr["type"])
	var info: Dictionary = WindLabParts.DRIVES[ty]
	var g := 1.0
	match ty:
		"gt2", "htd5", "spur":
			g = float(dr["driver_teeth"]) / float(dr["driven_teeth"])
		"planetary":
			g = float(dr["planetary_ratio"])
	d["ratio"] = g
	d["drive_eff"] = float(info["eff"])
	d["driver_pd_mm"] = WindLabParts.pulley_pitch_d_mm(ty, int(dr["driver_teeth"])) if ty in ["gt2", "htd5", "spur"] else 0.0
	d["driven_pd_mm"] = WindLabParts.pulley_pitch_d_mm(ty, int(dr["driven_teeth"])) if ty in ["gt2", "htd5", "spur"] else 0.0
	var bear_t := 0.0
	if str(s["mount"]["style"]) == "bearings":
		var b := WindLabParts.bearing_for(float(s["mount"]["shaft_d_mm"]))
		bear_t = 2.0 * float(b["friction_nm"])
		d["bearing"] = b
	else:
		d["bearing"] = {}
	d["bearing_nm"] = bear_t
	d["gen"] = WindLabParts.generator(str(s["generator"]["id"]))
	d["gen_count"] = int(s["generator"]["count"])


static func _hub_height(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var mh := float(s["mount"]["mast_h_mm"]) * 0.001
	var hub := mh + (float(s["rotor"]["h_mm"]) * 0.0005 if bool(d["vawt"]) else 0.0)
	d["hub_h_m"] = hub
	d["v_mean_hub"] = WindTurbineSource.shear_correct_ms(float(s["site"]["mean_wind_ms"]), 10.0,
		maxf(hub, 0.3), float(s["site"]["roughness_m"]))


# ---------------------------------------------------------------------------
# Operating points
# ---------------------------------------------------------------------------

static func _gen_table(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	return WindLabGen.table(str(s["generator"]["id"]), s["load"], int(d["gen_count"]))


## The load torque at the rotor at angular speed w (rad/s).
static func _load_torque(d: Dictionary, tab: Dictionary, w: float) -> float:
	if w <= 0.0:
		return 0.0
	var g := float(d["ratio"])
	var gen_rpm := w * g * 60.0 / TAU
	return g * WindLabGen.lookup(tab, gen_rpm, "torque") / float(d["drive_eff"]) + float(d["bearing_nm"])


## What it takes to start turning (N·m at the rotor): the generator's cogging
## and friction through the drive, and the bearings.
static func start_torque_nm(d: Dictionary) -> float:
	var gen: Dictionary = d["gen"]
	var c := float(d["gen_count"])
	return float(d["ratio"]) * (float(gen["detent_nm"]) + float(gen["friction_nm"])) * c / float(d["drive_eff"]) \
		+ float(d["bearing_nm"])


## The lowest wind that breaks the cogging from rest (m/s): the rotor's worst
## static torque Cq_start·½ρv²·A·R must reach start_torque_nm.
static func start_wind_ms(d: Dictionary) -> float:
	var cq := float(d["cp"]["cq_start"])
	var k := cq * 0.5 * float(d["rho"]) * float(d["area_m2"]) * float(d["R_m"])
	if k <= 1e-9:
		return INF
	return sqrt(start_torque_nm(d) / k)


## The operating point at a hub-height wind (m/s). {v, w (rad/s), rpm,
## gen_rpm, lam, cp, p_wind, p_aero, p_elec, torque_nm, v_dc, i_dc, i_ph,
## running, assisted}.
static func op_point(d: Dictionary, v: float, tab: Dictionary = {}) -> Dictionary:
	var s: Dictionary = d["spec"]
	if tab.is_empty():
		tab = _gen_table(d)
	var out := {"v": v, "w": 0.0, "rpm": 0.0, "gen_rpm": 0.0, "lam": 0.0, "cp": 0.0,
		"p_wind": 0.5 * float(d["rho"]) * float(d["area_m2"]) * v * v * v, "p_aero": 0.0, "p_elec": 0.0,
		"torque_nm": 0.0, "v_dc": 0.0, "i_dc": 0.0, "i_ph": 0.0, "running": false, "assisted": false}
	if v <= 0.05:
		return out
	var cp: Dictionary = d["cp"]
	var R := float(d["R_m"])
	var q := 0.5 * float(d["rho"]) * v * v * float(d["area_m2"]) * R
	var w_run := float(cp["lam_run"]) * v / R
	var starts := float(cp["cq_start"]) * q > start_torque_nm(d)
	var assist := bool(s["rotor"].get("start_assist", false))
	var f := func(w: float) -> float:
		return WindLabAero.cq_at(cp, w * R / v) * q - _load_torque(d, tab, w)
	var w_eq := 0.0
	var up_stuck := false
	if starts:
		# Up from rest: the first place the rotor's torque falls below the
		# load's.
		var prev := float(cp["cq_start"]) * q - start_torque_nm(d)
		var lo := 0.0
		for k in range(1, SCAN_N + 1):
			var w := w_run * float(k) / float(SCAN_N)
			var fk: float = f.call(w)
			if fk < 0.0 and prev >= 0.0:
				w_eq = _bisect(f, lo, w)
				break
			prev = fk
			lo = w
		# A lift rotor can start and then hang in its dead band, crawling.
		up_stuck = w_eq * R / v < 0.5 * float(cp["lam_opt"]) and str(cp["family"]) == "lift"
	if assist and (w_eq <= 0.0 or up_stuck):
		# Pushed up to speed: the fastest stable crossing.
		var prev2: float = f.call(w_run * 0.999)
		for k in range(SCAN_N - 1, 0, -1):
			var w2 := w_run * float(k) / float(SCAN_N)
			var fk2: float = f.call(w2)
			if fk2 > 0.0 and prev2 <= 0.0:
				var w_top := _bisect(f, w2, w_run * float(k + 1) / float(SCAN_N))
				if w_top > w_eq:
					w_eq = w_top
					out["assisted"] = true
				break
			prev2 = fk2
	if bool(tab.get("mppt", false)) and (starts or assist):
		# An MPPT controller chooses where to hold the rotor: the speed that
		# puts the most into the battery (it hunts for it — perturb and
		# observe — so the operating point is the system's best, not the
		# generator's).
		var mp := _mppt_point(d, tab, v, q, w_run, out, not starts)
		if bool(mp["running"]):
			return mp
		# Below the controller's window it freewheels (the friction alone).
	if w_eq <= 0.0:
		return out
	var g := float(d["ratio"])
	var gen_rpm := w_eq * g * 60.0 / TAU
	var lam := w_eq * R / v
	var c := WindLabAero.cp_at(cp, lam)
	out["w"] = w_eq
	out["rpm"] = w_eq * 60.0 / TAU
	out["gen_rpm"] = gen_rpm
	out["lam"] = lam
	out["cp"] = c
	out["p_aero"] = c * float(out["p_wind"])
	out["torque_nm"] = c * float(out["p_wind"]) / maxf(w_eq, 1e-6)
	out["p_elec"] = WindLabGen.lookup(tab, gen_rpm, "p_load")
	out["v_dc"] = WindLabGen.lookup(tab, gen_rpm, "v_dc")
	out["i_dc"] = WindLabGen.lookup(tab, gen_rpm, "i_dc")
	out["i_ph"] = WindLabGen.lookup(tab, gen_rpm, "i_ph")
	out["running"] = true
	return out


## The MPPT operating point at wind v: over the rotor's speeds, the rotor's
## torque less the bearings, through the drive, less the generator's friction
## is what the magnets take (capped at what they can take at the controller's
## lowest input voltage); WindLabGen.mppt_from_em turns it into battery power.
static func _mppt_point(d: Dictionary, tab: Dictionary, v: float, q: float, w_run: float, out: Dictionary,
		assisted: bool) -> Dictionary:
	var cp: Dictionary = d["cp"]
	var R := float(d["R_m"])
	var g := float(d["ratio"])
	var eta := float(d["drive_eff"])
	var gen: Dictionary = tab["gen"]
	var load: Dictionary = tab["load"]
	var cnt := int(tab["count"])
	var eval := func(w: float) -> Dictionary:
		var lam := w * R / v
		var ta := WindLabAero.cq_at(cp, lam) * q
		var n := w * g * 60.0 / TAU
		var t_em := (ta - float(d["bearing_nm"])) * eta / g - float(gen["friction_nm"]) * float(cnt)
		var p_em := minf(maxf(t_em, 0.0) * n * TAU / 60.0, WindLabGen.lookup(tab, n, "p_em_max"))
		var r := WindLabGen.mppt_from_em(gen, load, n, p_em, cnt)
		r["w"] = w
		r["lam"] = lam
		r["gen_rpm"] = n
		return r
	var best := {}
	var best_p := 0.0
	var best_k := -1
	for k in range(1, SCAN_N):
		var w := w_run * float(k) / float(SCAN_N)
		var r: Dictionary = eval.call(w)
		if float(r["p_load"]) > best_p:
			best_p = float(r["p_load"])
			best = r
			best_k = k
	if best_k < 0:
		return out
	# Golden refine between the neighbours.
	var a := w_run * float(best_k - 1) / float(SCAN_N)
	var b := w_run * float(best_k + 1) / float(SCAN_N)
	var gr := 0.6180339887
	for _i in 12:
		var c1 := b - gr * (b - a)
		var c2 := a + gr * (b - a)
		var r1: Dictionary = eval.call(c1)
		var r2: Dictionary = eval.call(c2)
		if float(r1["p_load"]) > float(r2["p_load"]):
			b = c2
			if float(r1["p_load"]) > best_p:
				best_p = float(r1["p_load"])
				best = r1
		else:
			a = c1
			if float(r2["p_load"]) > best_p:
				best_p = float(r2["p_load"])
				best = r2
	var w_eq := float(best["w"])
	var lam_b := float(best["lam"])
	var c := WindLabAero.cp_at(cp, lam_b)
	out["w"] = w_eq
	out["rpm"] = w_eq * 60.0 / TAU
	out["gen_rpm"] = float(best["gen_rpm"])
	out["lam"] = lam_b
	out["cp"] = c
	out["p_aero"] = c * float(out["p_wind"])
	out["torque_nm"] = c * float(out["p_wind"]) / maxf(w_eq, 1e-6)
	out["p_elec"] = best_p
	out["v_dc"] = float(best["v_dc"])
	out["i_dc"] = best_p / maxf(float(load["battery_v"]), 1e-6)
	out["i_ph"] = float(best["i_ph"])
	out["running"] = true
	out["assisted"] = assisted
	return out


static func _bisect(f: Callable, a: float, b: float) -> float:
	var lo := a
	var hi := b
	var flo: float = f.call(maxf(lo, 1e-6))
	for _i in 30:
		var m := (lo + hi) * 0.5
		var fm: float = f.call(m)
		if (fm >= 0.0) == (flo >= 0.0):
			lo = m
			flo = fm
		else:
			hi = m
	return (lo + hi) * 0.5


## The power curve 0.5 … 30 m/s, the year's energy over a Rayleigh wind at
## the hub's mean, cut-in / rated / cut-out, the design point.
static func _curve(d: Dictionary, dv: float = CURVE_DV) -> void:
	var s: Dictionary = d["spec"]
	var tab := _gen_table(d)
	var curve: Array = []
	var v := dv
	while v <= CURVE_TOP + 1e-6:
		curve.append(op_point(d, v, tab))
		v += dv
	d["curve"] = curve
	d["curve_dv"] = dv
	var gen: Dictionary = d["gen"]
	var cut_out := float(s["site"]["cut_out_ms"])
	# Auto cut-out: past the generator's top speed, or past half again its
	# rating — a real machine is braked or furled there.
	var auto_out := CURVE_TOP
	var p_cap := float(gen["rated_w"]) * float(d["gen_count"]) * 1.5
	d["cut_out_why"] = ""
	for p in curve:
		if float(p["gen_rpm"]) > float(gen["max_rpm"]):
			auto_out = float(p["v"]) - dv
			d["cut_out_why"] = "rpm"
			break
		if float(p["p_elec"]) > p_cap:
			auto_out = float(p["v"]) - dv
			d["cut_out_why"] = "power"
			break
	d["auto_cut_out_ms"] = maxf(auto_out, dv)
	d["cut_out_ms"] = cut_out if cut_out > 0.0 else float(d["auto_cut_out_ms"])
	var cut_in := INF
	var rated := 0.0
	var rated_v := 0.0
	for p in curve:
		if float(p["v"]) > float(d["cut_out_ms"]) + 1e-6:
			break
		if float(p["p_elec"]) > 0.05 and cut_in == INF:
			cut_in = float(p["v"])
		if float(p["p_elec"]) > rated:
			rated = float(p["p_elec"])
			rated_v = float(p["v"])
	d["cut_in_ms"] = cut_in
	d["peak_w"] = rated
	d["peak_v"] = rated_v
	d["start_ms"] = start_wind_ms(d)
	d["design"] = op_point(d, float(s["site"]["design_wind_ms"]), tab)
	d["aep_kwh"] = annual_energy_kwh(d, float(d["v_mean_hub"]))
	d["mean_w"] = float(d["aep_kwh"]) * 1000.0 / 8760.0
	d["capacity_factor"] = float(d["mean_w"]) / maxf(rated, 1e-6) if rated > 0.0 else 0.0


## The Rayleigh probability density of wind speed v at mean vm:
## f(v) = (π/2)(v/vm²)·exp(−(π/4)(v/vm)²) (Manwell et al. 2009 §2.4).
static func rayleigh(v: float, vm: float) -> float:
	if vm <= 0.0:
		return 0.0
	return PI * 0.5 * v / (vm * vm) * exp(-PI * 0.25 * pow(v / vm, 2.0))


## kWh a year at a hub-height mean wind: ∫ P(v)·f(v) dv × 8760 h over the
## power curve read between its points (0.1 m/s steps, so a coarse curve —
## the generator ranking's — integrates to the same year as a fine one), held
## at zero past cut-out.
static func annual_energy_kwh(d: Dictionary, vm: float) -> float:
	var pts: Array = []
	for p in d["curve"]:
		pts.append([float(p["v"]), float(p["p_elec"])])
	var top := float(d["cut_out_ms"])
	var e := 0.0
	var v := 0.05
	while v <= top + 1e-6:
		e += WindTurbineSource.curve_at(pts, v) * rayleigh(v, vm) * 0.1
		v += 0.1
	return e * 8760.0 / 1000.0


# ---------------------------------------------------------------------------
# Matching the drive and the generator
# ---------------------------------------------------------------------------

## The year's energy and design-wind power for one generator at one ratio
## (used by the ratio search and the generator ranking; a light re-solve).
static func evaluate(spec: Dictionary, gen_id: String, ratio: float) -> Dictionary:
	var s := WindLabSpec.resolve(spec)
	s["generator"]["id"] = gen_id
	var d := {"spec": s}
	d["R_m"] = WindLabAero.radius_m(s)
	d["area_m2"] = WindLabAero.area_m2(s)
	d["rho"] = WindTurbineSource.air_density_at_altitude(float(s["site"]["altitude_m"]))
	d["cp"] = WindLabAero.cp_model(s, float(s["site"]["design_wind_ms"]))
	d["vawt"] = WindLabParts.is_vawt(str(s["type"]))
	_drive(d)
	d["ratio"] = ratio
	if absf(ratio - 1.0) > 1e-6 and str(s["drive"]["type"]) == "direct":
		d["drive_eff"] = 0.97
	_hub_height(d)
	# The design's own step: a coarser curve smears the start-up step and
	# overstates a small rotor's year by a third.
	_curve(d, CURVE_DV)
	return {"gen": gen_id, "ratio": ratio, "aep_kwh": float(d["aep_kwh"]), "design_w": float(d["design"]["p_elec"]),
		"start_ms": float(d["start_ms"]), "cut_in_ms": float(d["cut_in_ms"]), "peak_w": float(d["peak_w"]),
		"design_gen_rpm": float(d["design"]["gen_rpm"]), "cut_out_ms": float(d["cut_out_ms"])}


## The ratio that makes the most energy in a year for a generator (searched
## over 0.5 … 40 on a geometric ladder, then refined).
static func best_ratio(spec: Dictionary, gen_id: String) -> Dictionary:
	var best := {}
	var lo := 0.5
	var hi := 40.0
	var n := 12
	var k_best := 0
	var list: Array = []
	for k in n:
		var g := lo * pow(hi / lo, float(k) / float(n - 1))
		var e := evaluate(spec, gen_id, g)
		list.append(e)
		if best.is_empty() or float(e["aep_kwh"]) > float(best["aep_kwh"]):
			best = e
			k_best = k
	# Refine between the neighbours.
	var g0 := lo * pow(hi / lo, float(maxi(k_best - 1, 0)) / float(n - 1))
	var g1 := lo * pow(hi / lo, float(mini(k_best + 1, n - 1)) / float(n - 1))
	for k in 4:
		var g2 := g0 * pow(g1 / g0, float(k + 1) / 5.0)
		var e2 := evaluate(spec, gen_id, g2)
		if float(e2["aep_kwh"]) > float(best["aep_kwh"]):
			best = e2
	best["ladder"] = list
	return best


## Every generator at its best ratio, best first (the "which motor" table).
## A rotor without its own shaft and drive (clamped to the motor body or on
## the generator's shaft) can only turn its generator 1 : 1.
static func rank_generators(spec: Dictionary) -> Array:
	var s := WindLabSpec.resolve(spec)
	var geared := str(s["mount"]["style"]) == "bearings"
	var out: Array = []
	for id in WindLabParts.GENERATORS:
		var b := best_ratio(s, str(id)) if geared else evaluate(s, str(id), 1.0)
		b["label"] = str(WindLabParts.generator(str(id))["label"])
		b["cost"] = float(WindLabParts.generator(str(id))["cost"])
		out.append(b)
	out.sort_custom(func(a, b): return float(a["aep_kwh"]) > float(b["aep_kwh"]))
	return out


## The drive settings that give a ratio: a timing belt / gear pair from the
## stock tooth counts, or the nearest planetary ratio. Returns a drive dict
## patch {type, driver_teeth, driven_teeth, planetary_ratio, ratio}.
static func drive_for_ratio(spec: Dictionary, ratio: float) -> Dictionary:
	var s := WindLabSpec.resolve(spec)
	var dr: Dictionary = (s["drive"] as Dictionary).duplicate()
	var ty := str(dr["type"])
	if ty == "direct":
		ty = "gt2" if ratio <= 6.0 else "planetary"
	dr["type"] = ty
	if ty == "planetary":
		var best := 1.0
		for p in WindLabParts.PLANETARY_RATIOS:
			if absf(log(float(p) / ratio)) < absf(log(best / ratio)):
				best = float(p)
		dr["planetary_ratio"] = best
		dr["ratio"] = best
		return dr
	var min_t := int(WindLabParts.DRIVES[ty].get("min_teeth", 16))
	var best_err := INF
	for a in WindLabParts.PULLEY_TEETH:
		for b in WindLabParts.PULLEY_TEETH:
			if int(b) < min_t or int(a) < min_t:
				continue
			var r := float(a) / float(b)
			var err := absf(log(r / ratio))
			if err < best_err - 1e-9:
				best_err = err
				dr["driver_teeth"] = int(a)
				dr["driven_teeth"] = int(b)
				dr["ratio"] = r
	return dr


# ---------------------------------------------------------------------------
# Parts to cut and score
# ---------------------------------------------------------------------------

## A NEMA face's pattern: pilot boss Ø and the 4-hole square (mm), screw.
const NEMA_FACE := {42.3: {"boss": 22.0, "sq": 31.0, "hole": 3.4, "screw": "M3"},
	57.0: {"boss": 38.1, "sq": 47.14, "hole": 5.2, "screw": "M5"},
	86.0: {"boss": 73.0, "sq": 69.6, "hole": 5.5, "screw": "M5"}}


static func nema_face(frame_mm: float) -> Dictionary:
	var best: float = 42.3
	for k in NEMA_FACE:
		if absf(float(k) - frame_mm) < absf(best - frame_mm):
			best = float(k)
	return NEMA_FACE[best]


## Score lines across one arc so each facet sits within tol of the curve:
## a facet of arc a on radius r leaves a sagitta r(1 − cos(a/2r)), so the
## facet length is a = 2r·acos(1 − tol/r).
static func score_count(r_mm: float, len_mm: float, tol_mm: float) -> int:
	if r_mm <= tol_mm:
		return maxi(int(ceil(len_mm / maxf(tol_mm, 0.5))) - 1, 1)
	var a := 2.0 * r_mm * acos(1.0 - tol_mm / r_mm)
	return maxi(int(ceil(len_mm / maxf(a, 0.1))) - 1, 0)


static func _parts(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var t := str(s["type"])
	var r: Dictionary = s["rotor"]
	var bd: Dictionary = s["build"]
	var sheet := WindLabParts.sheet(str(bd["sheet"]))
	var tsh := float(sheet["t_mm"])
	var parts: Array = []
	var scored := 0
	var too_tight := false
	var hub: Dictionary = r["hub"]
	var hub_style := str(hub["style"])
	var tabs := bool(bd["tabs"]) and hub_style == "end_plates"
	var tab_h := tsh + 1.0
	if t in ["ugrinsky", "savonius", "lenz2"]:
		var b0: Dictionary = (d["blades"] as Array)[0]
		var dev := WindLabAero.poly_len(b0["pts"])
		var h := float(r["h_mm"]) / float(r["stages"])
		var folds: Array = []
		var x0 := 0.0
		for seg in b0["segs"]:
			var rr := float(seg["r_mm"])
			var ln := float(seg["len_mm"])
			if rr < float(sheet["free_r_mm"]):
				if bool(sheet["scoreable"]):
					var n := score_count(rr, ln, float(bd["score_tol_mm"]))
					var ang := rad_to_deg(ln / maxf(rr, 1e-6)) / float(n + 1)
					for i in n:
						var x := x0 + ln * float(i + 1) / float(n + 1)
						folds.append({"a": Vector2(x, 0.0), "b": Vector2(x, h + (2.0 * tab_h if tabs else 0.0)),
							"text": "SCORE %.0f°" % ang})
					scored += n
				else:
					too_tight = true
			x0 += ln
		var outline := _blade_strip_outline(dev, h, tabs, tab_h)
		var lbl := "BLADE %s %.0f x %.0f MM" % [str(WindLabParts.type_info(t)["label"]).get_slice(" ", 0).to_upper(), dev, h]
		parts.append({"id": "blade", "label": "Blade", "qty": int(r["blades"]) * int(r["stages"]), "w": dev,
			"h": h + (2.0 * tab_h if tabs else 0.0), "outside": [FlatpackProfile.make_ring(outline)], "inside": [],
			"fold": folds, "labels": [{"p": Vector2(dev * 0.5, h * 0.5), "text": lbl, "size": clampf(dev * 0.04, 3.0, 14.0), "rot": 90.0}],
			"note": "Corrugations run along the blade's height (parallel to the shaft); score one skin along the green lines and bend toward the score." if bool(sheet["scoreable"]) else ""})
		if hub_style == "spokes":
			parts.append(_arm_part(d, "Wing arm", int(r["blades"]) * 2, float(d["tip_r_mm"]) - _foil_hub_r_mm(d),
				maxf(float(r["d_mm"]) * 0.04, 30.0)))
			parts.append(_hub_plate(d, false, false))
		else:
			parts.append(_hub_plate(d, hub_style == "mid_discs", tabs))
	elif t in ["darrieus_h", "helical"]:
		parts.append(_arm_part(d, "Blade arm", int(r["blades"]) * int(r["arms"]),
			float(r["d_mm"]) * 0.5 - _foil_hub_r_mm(d), maxf(float(r["chord_mm"]) * 0.5, 25.0)))
		parts.append(_hub_plate(d, false, false))
	else:
		parts.append(_hub_plate(d, false, false))
		if t == "hawt" and str(r["construction"]) == "pvc_pipe":
			parts.append(_pipe_template(d))
		if t == "multiblade":
			var st: Array = d["stations"]
			var pts := PackedVector2Array()
			for e in st:
				pts.append(Vector2(float(e["r_m"]) * 1000.0, -float(e["c_m"]) * 500.0))
			for i in range(st.size() - 1, -1, -1):
				pts.append(Vector2(float(st[i]["r_m"]) * 1000.0, float(st[i]["c_m"]) * 500.0))
			var bb := _bbox2(pts)
			var moved := PackedVector2Array()
			for p in pts:
				moved.append(p - bb.position)
			parts.append({"id": "plate_blade", "label": "Blade plate", "qty": int(r["blades"]), "w": bb.size.x, "h": bb.size.y,
				"outside": [FlatpackProfile.make_ring(moved)], "inside": [], "fold": [], "labels": [], "note": "Roll each plate to its camber after cutting."})
	d["parts"] = parts
	d["scores"] = scored
	d["too_tight"] = too_tight
	d["nest"] = _nest(d)


## A flat arm from the hub plate out to a blade: two bolt holes each end.
static func _arm_part(d: Dictionary, label: String, qty: int, ln: float, w: float) -> Dictionary:
	var arm := FlatpackProfile.make_ring(PackedVector2Array([Vector2(0, 0), Vector2(ln, 0), Vector2(ln, w), Vector2(0, w)]))
	var hb := 6.5
	var holes: Array = [FlatpackProfile.circle_ring(Vector2(12.0, w * 0.5), hb * 0.5),
		FlatpackProfile.circle_ring(Vector2(30.0, w * 0.5), hb * 0.5),
		FlatpackProfile.circle_ring(Vector2(ln - 12.0, w * 0.5), hb * 0.5),
		FlatpackProfile.circle_ring(Vector2(ln - 30.0, w * 0.5), hb * 0.5)]
	return {"id": "arm", "label": label, "qty": qty, "w": ln, "h": w, "outside": [arm], "inside": holes, "fold": [],
		"labels": [{"p": Vector2(ln * 0.5, w * 0.5), "text": label.to_upper(), "size": clampf(w * 0.2, 3.0, 8.0), "rot": 0.0}], "note": ""}


## The developed blade strip (mm): the centreline's length by the blade's
## height, with three tabs top and bottom when it ends in slotted end plates.
static func _blade_strip_outline(dev: float, h: float, tabs: bool, tab_h: float) -> PackedVector2Array:
	var y0 := tab_h if tabs else 0.0
	var pts := PackedVector2Array()
	pts.append(Vector2(0.0, y0))
	if tabs:
		for u in [1.0 / 6.0, 0.5, 5.0 / 6.0]:
			var c := dev * float(u)
			var tw := dev / 5.0 * 0.5
			pts.append(Vector2(c - tw, y0))
			pts.append(Vector2(c - tw, 0.0))
			pts.append(Vector2(c + tw, 0.0))
			pts.append(Vector2(c + tw, y0))
	pts.append(Vector2(dev, y0))
	pts.append(Vector2(dev, y0 + h))
	if tabs:
		for u in [5.0 / 6.0, 0.5, 1.0 / 6.0]:
			var c2 := dev * float(u)
			var tw2 := dev / 5.0 * 0.5
			pts.append(Vector2(c2 + tw2, y0 + h))
			pts.append(Vector2(c2 + tw2, y0 + h + tab_h))
			pts.append(Vector2(c2 - tw2, y0 + h + tab_h))
			pts.append(Vector2(c2 - tw2, y0 + h))
	pts.append(Vector2(0.0, y0 + h))
	return pts


## The radius of a foil rotor's hub plate (mm).
static func _foil_hub_r_mm(d: Dictionary) -> float:
	var s: Dictionary = d["spec"]
	if str(s["type"]) in ["hawt", "multiblade"]:
		return maxf(float(s["rotor"]["hub_frac"]) * float(s["rotor"]["d_mm"]) * 0.5 * 0.9, 30.0)
	return clampf(float(s["rotor"]["d_mm"]) * 0.06, 35.0, 150.0)


## The hub disc / end plate: the outline, the blade slots (whole curved
## slots for mid discs or no-tab end plates, a slot under each tab when the
## blades are tabbed) and the centre's mounting holes.
static func _hub_plate(d: Dictionary, mid: bool, tabs: bool) -> Dictionary:
	var s: Dictionary = d["spec"]
	var r: Dictionary = s["rotor"]
	var t := str(s["type"])
	var bd: Dictionary = s["build"]
	var tsh := float(WindLabParts.sheet(str(bd["sheet"]))["t_mm"])
	var clear := float(bd["slot_clear_mm"])
	var sheet_rotor := t in ["ugrinsky", "savonius", "lenz2"]
	var spokes := str(r["hub"]["style"]) == "spokes"
	var R := float(d["tip_r_mm"]) * float(r["hub"]["overhang"]) if sheet_rotor and not spokes else _foil_hub_r_mm(d)
	var c := Vector2(R, R)
	var inside: Array = []
	if sheet_rotor and not spokes:
		for b in d["blades"]:
			var pts: PackedVector2Array = b["pts"]
			if tabs:
				var dev := WindLabAero.poly_len(pts)
				for u in [1.0 / 6.0, 0.5, 5.0 / 6.0]:
					var seg := _sub_polyline(pts, dev * (float(u) - 0.1), dev * (float(u) + 0.1))
					inside.append(FlatpackProfile.make_ring(_shift(WindLabMesh.band_outline(seg, tsh + 2.0 * clear), c)))
			else:
				inside.append(FlatpackProfile.make_ring(_shift(WindLabMesh.band_outline(pts, tsh + 2.0 * clear), c)))
	# The centre: what the rotor is fastened to.
	var gen: Dictionary = d["gen"]
	var style := str(s["mount"]["style"])
	var note := ""
	if style == "body_spins" and str(gen["body"]) == "nema":
		var f := nema_face(float(gen["frame_mm"]))
		inside.append(FlatpackProfile.circle_ring(c, float(f["boss"]) * 0.5 + 0.3))
		var hs := float(f["sq"]) * 0.5
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				inside.append(FlatpackProfile.circle_ring(c + Vector2(sx * hs, sy * hs), float(f["hole"]) * 0.5))
		note = "Clamp the disc to the motor's face with its four %s screws; the motor body turns with the rotor." % str(f["screw"])
	else:
		var bore := float(gen["shaft_mm"]) if style != "bearings" else float(s["mount"]["shaft_d_mm"])
		# A flanged shaft hub (set-screw collar): four bolts round the bore.
		inside.append(FlatpackProfile.circle_ring(c, bore * 0.5 + 0.2))
		var pcd := maxf(bore * 2.6 + 12.0, 28.0)
		for i in 4:
			var a := TAU * (float(i) + 0.5) / 4.0
			inside.append(FlatpackProfile.circle_ring(c + Vector2(cos(a), sin(a)) * pcd * 0.5, 2.2))
		note = "Bolt to a flanged shaft hub (Ø %.0f bore, 4 × M4 on Ø %.0f)." % [bore, pcd]
	var label := "HUB DISC" if mid else ("END PLATE" if sheet_rotor else "HUB PLATE")
	var qty := 2
	if spokes:
		label = "HUB PLATE"
		qty = 2
	elif mid:
		qty = int(r["hub"]["count"])
	elif sheet_rotor:
		qty = int(r["stages"]) + 1
	elif t in ["darrieus_h", "helical"]:
		qty = int(r["arms"])
	return {"id": "hub", "label": label.capitalize(), "qty": qty, "w": 2.0 * R, "h": 2.0 * R,
		"outside": [FlatpackProfile.circle_ring(c, R)], "inside": inside, "fold": [],
		"labels": [{"p": c + Vector2(0.0, -R * 0.6), "text": "%s Ø%.0f" % [label, 2.0 * R], "size": clampf(R * 0.08, 3.0, 12.0), "rot": 0.0}],
		"note": note}


## The PVC-pipe blade's cut template: the planform drawn on the pipe's
## unrolled surface (span along the pipe, chord round it).
static func _pipe_template(d: Dictionary) -> Dictionary:
	var st: Array = d["stations"]
	var pts := PackedVector2Array()
	for e in st:
		pts.append(Vector2(float(e["r_m"]) * 1000.0, 0.0))
	for i in range(st.size() - 1, -1, -1):
		pts.append(Vector2(float(st[i]["r_m"]) * 1000.0, float(st[i]["c_m"]) * 1000.0))
	var bb := _bbox2(pts)
	var moved := PackedVector2Array()
	for p in pts:
		moved.append(p - bb.position)
	var pd := float(d["spec"]["rotor"]["pipe_d_mm"])
	return {"id": "pipe_template", "label": "Pipe cut template", "qty": int(d["spec"]["rotor"]["blades"]), "w": bb.size.x, "h": bb.size.y,
		"outside": [FlatpackProfile.make_ring(moved)], "inside": [], "fold": [], "labels": [{"p": Vector2(bb.size.x * 0.5, bb.size.y * 0.3),
			"text": "WRAP ON %.0f MM PIPE, STRAIGHT EDGE ALONG THE PIPE" % pd, "size": 5.0, "rot": 0.0}],
		"note": "Print at 100 %%, wrap round the %.0f mm pipe with the straight edge along it, trace, cut." % pd}


static func _sub_polyline(pts: PackedVector2Array, a: float, b: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var acc := 0.0
	var aa := maxf(a, 0.0)
	for i in range(1, pts.size()):
		var l := pts[i].distance_to(pts[i - 1])
		var s0 := acc
		var s1 := acc + l
		if s1 >= aa and s0 <= b:
			var u0 := clampf((aa - s0) / maxf(l, 1e-9), 0.0, 1.0)
			var u1 := clampf((b - s0) / maxf(l, 1e-9), 0.0, 1.0)
			if out.is_empty():
				out.append(pts[i - 1].lerp(pts[i], u0))
			out.append(pts[i - 1].lerp(pts[i], u1))
		acc = s1
	if out.size() < 2:
		out = PackedVector2Array([pts[0], pts[1]])
	return out


static func _shift(pts: PackedVector2Array, c: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(p + c)
	return out


static func _bbox2(pts: PackedVector2Array) -> Rect2:
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r


## Nest the sheet parts onto the chosen sheet size (MaxRects on bounding
## boxes — FlatpackNesting). The pipe template is printed, not nested.
static func _nest(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var bd: Dictionary = s["build"]
	var sz := WindLabParts.sheet_size(str(bd["sheet_size"]))
	var items: Array = []
	for p in d["parts"]:
		if str(p["id"]) == "pipe_template":
			continue
		# A blade's height runs along a corrugated sheet's flutes (the bends are
		# round the flutes): it is laid turned when the flutes run along the
		# sheet's width, and never turned again by the nesting.
		var fluted := str(p["id"]) == "blade" and bool(WindLabParts.sheet(str(bd["sheet"]))["scoreable"])
		var turn := fluted and str(sz.get("flutes", "h")) == "w"
		for k in int(p["qty"]):
			var w := float(p["h"]) if turn else float(p["w"])
			var h := float(p["w"]) if turn else float(p["h"])
			items.append({"id": "%s#%d" % [str(p["id"]), k], "w": w, "h": h, "rot_ok": not fluted, "turn": turn})
	var kerf := float(bd.get("kerf_mm", 3.0))
	var margin := float(bd.get("margin_mm", 5.0))
	var res := FlatpackNesting.nest(items, float(sz["w"]), float(sz["h"]), kerf, margin)
	res["sheet_label"] = str(sz["label"])
	var turned := {}
	for it in items:
		if bool(it["turn"]):
			turned[str(it["id"])] = true
	res["turned"] = turned
	return res


# ---------------------------------------------------------------------------
# Printed / routed solids
# ---------------------------------------------------------------------------

## The parts made as solids (STL): propeller blades and their hub, Darrieus
## blade sections. {id, label, qty, tris (mm), pieces (how many sections
## a long one is printed in), length_mm, volume_cm3}.
static func _prints(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var r: Dictionary = s["rotor"]
	var t := str(s["type"])
	var out: Array = []
	var pmax := float(s["build"]["print_max_mm"])
	if t == "hawt" and str(r["construction"]) != "pvc_pipe":
		var af := WindLabAero.airfoil_points(WindLabAero.hawt_airfoil(s), 18)
		var tris := WindLabMesh.hawt_blade(d["stations"], af)
		var span := (float(r["d_mm"]) * 0.5) * (1.0 - float(r["hub_frac"]))
		out.append({"id": "hawt_blade", "label": "Blade", "qty": int(r["blades"]), "tris": tris, "length_mm": span,
			"pieces": maxi(int(ceil(span / pmax)), 1), "volume_cm3": WindLabMesh.signed_volume(tris) / 1000.0})
	if t in ["darrieus_h", "helical"]:
		var af2 := WindLabAero.airfoil_points(WindLabParts.airfoil(str(r["airfoil"])), 18)
		var h := float(r["h_mm"])
		var R := float(r["d_mm"]) * 0.5
		var hel := deg_to_rad(float(r["helix_deg"])) if t == "helical" else 0.0
		var pcs := maxi(int(ceil(h / pmax)), 1)
		var seg_h := h / float(pcs)
		var layers := 1 if hel == 0.0 else maxi(int(ceil(rad_to_deg(absf(hel)) / float(pcs) / 5.0)), 2)
		var tris2 := WindLabMesh.vawt_foil_blade(af2, float(r["chord_mm"]), R, 0.0, 0.0, seg_h, hel / float(pcs), layers)
		out.append({"id": "foil_section", "label": "Blade section", "qty": int(r["blades"]) * pcs, "tris": tris2, "length_mm": seg_h,
			"pieces": 1, "volume_cm3": WindLabMesh.signed_volume(tris2) / 1000.0})
	if t in ["hawt", "darrieus_h", "helical"] and _foil_hub_r_mm(d) <= 120.0:
		var hr := _foil_hub_r_mm(d)
		var gen: Dictionary = d["gen"]
		var bore := float(gen["shaft_mm"]) if str(s["mount"]["style"]) != "bearings" else float(s["mount"]["shaft_d_mm"])
		var tris3 := WindLabMesh.ring(hr, bore * 0.5 + 0.2, 0.0, maxf(hr * 0.35, 12.0))
		out.append({"id": "hub", "label": "Hub", "qty": 1, "tris": tris3, "length_mm": hr * 2.0, "pieces": 1,
			"volume_cm3": WindLabMesh.signed_volume(tris3) / 1000.0})
	d["prints"] = out


# ---------------------------------------------------------------------------
# Masses, bill of materials
# ---------------------------------------------------------------------------

static func _masses(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var sheet := WindLabParts.sheet(str(s["build"]["sheet"]))
	var solid := WindLabParts.solid(str(s["build"]["solid"]))
	var sheet_kg := 0.0
	for p in d["parts"]:
		if str(p["id"]) == "pipe_template":
			continue
		var a := float(p["w"]) * float(p["h"]) * 1e-6
		if str(p["id"]) == "hub":
			a *= PI / 4.0
		sheet_kg += a * float(p["qty"]) * float(sheet["kg_m2"])
	var solid_kg := 0.0
	for p in d["prints"]:
		solid_kg += absf(float(p["volume_cm3"])) * 1e-6 * float(p["qty"]) * float(solid["density"]) * 0.45
	var t := str(s["type"])
	var pipe_kg := 0.0
	if t == "hawt" and str(s["rotor"]["construction"]) == "pvc_pipe":
		# A blade cut from Sch 40-class pipe: the planform area × the wall.
		var area := 0.0
		var st: Array = d["stations"]
		for i in range(1, st.size()):
			area += (float(st[i]["r_m"]) - float(st[i - 1]["r_m"])) * (float(st[i]["c_m"]) + float(st[i - 1]["c_m"])) * 0.5
		pipe_kg = area * float(s["rotor"]["blades"]) * 0.0045 * 1400.0
	var gen: Dictionary = d["gen"]
	var gen_kg := float(gen["mass_kg"]) * float(d["gen_count"])
	var mast_kg := WindLabParts.mast_kg_m(str(s["mount"]["mast"])) * float(s["mount"]["mast_h_mm"]) * 0.001
	var rotor_kg := sheet_kg + solid_kg + pipe_kg
	var misc := 0.05 + rotor_kg * 0.15 + (0.6 if str(s["mount"]["style"]) == "bearings" else 0.0) + (2.5 if not bool(d["vawt"]) else 0.0)
	d["mass"] = {"rotor": rotor_kg, "generator": gen_kg, "mast": mast_kg, "misc": misc,
		"total": rotor_kg + gen_kg + mast_kg + misc}


static func _row(item: String, qty: int, spec: String, cost: float, kg: float) -> Dictionary:
	return {"item": item, "qty": qty, "spec": spec, "cost": cost, "kg": kg}


static func _bom(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var out: Array = []
	var sheet := WindLabParts.sheet(str(s["build"]["sheet"]))
	var sz := WindLabParts.sheet_size(str(s["build"]["sheet_size"]))
	var nsheets := (d["nest"]["sheets"] as Array).size()
	if nsheets > 0:
		var a := float(sz["w"]) * float(sz["h"]) * 1e-6
		out.append(_row("Sheet", nsheets, "%s, %s" % [str(sheet["label"]), str(sz["label"])], a * float(sheet["cost_m2"]) * float(nsheets),
			a * float(sheet["kg_m2"]) * float(nsheets)))
	var solid := WindLabParts.solid(str(s["build"]["solid"]))
	for p in d["prints"]:
		var kg := absf(float(p["volume_cm3"])) * 1e-6 * float(solid["density"]) * 0.45 * float(p["qty"])
		out.append(_row(str(p["label"]), int(p["qty"]), "%s, %.0f cm³ each (45 %% infill)" % [str(solid["label"]), absf(float(p["volume_cm3"]))],
			kg * float(solid["cost_kg"]), kg))
	var t := str(s["type"])
	if t == "hawt" and str(s["rotor"]["construction"]) == "pvc_pipe":
		var len_m := float(s["rotor"]["d_mm"]) * 0.0005 * float(s["rotor"]["blades"]) / 3.0
		out.append(_row("PVC pipe", 1, "%.0f mm, %.2f m (cut %d blades from it)" % [float(s["rotor"]["pipe_d_mm"]), len_m * 1.1, int(s["rotor"]["blades"])],
			12.0 * len_m, float(d["mass"]["rotor"])))
	var gen: Dictionary = d["gen"]
	out.append(_row("Generator", int(d["gen_count"]), str(gen["label"]), float(gen["cost"]) * float(d["gen_count"]), float(d["mass"]["generator"])))
	var dr: Dictionary = s["drive"]
	match str(dr["type"]):
		"gt2", "htd5":
			out.append(_row("Timing pulleys", 2, "%d T and %d T, %s" % [int(dr["driver_teeth"]), int(dr["driven_teeth"]),
				str(WindLabParts.DRIVES[str(dr["type"])]["label"])], 14.0, 0.1))
			out.append(_row("Timing belt", 1, "%s, closed loop" % str(WindLabParts.DRIVES[str(dr["type"])]["label"]), 8.0, 0.03))
		"spur":
			out.append(_row("Spur gears", 2, "%d T and %d T, module %.1f" % [int(dr["driver_teeth"]), int(dr["driven_teeth"]),
				float(WindLabParts.DRIVES["spur"]["module_mm"])], 18.0, 0.2))
		"planetary":
			out.append(_row("Planetary gearbox", 1, "%.0f : 1" % float(dr["planetary_ratio"]), 45.0, 0.6))
	var b: Dictionary = d["bearing"]
	if not b.is_empty():
		out.append(_row("Bearings", 2, "%s (%.0f mm)" % [str(b["id"]), float(b["bore"])], 6.0, 0.06))
		out.append(_row("Shaft", 1, "%.0f mm steel, %s" % [float(s["mount"]["shaft_d_mm"]), WindLabSpec.fmt_len(float(s["rotor"]["h_mm"]) + 200.0)],
			8.0, 0.3))
	var mast := WindLabParts.mast(str(s["mount"]["mast"]))
	out.append(_row("Mast", 1, "%s, %s" % [str(mast["label"]), WindLabSpec.fmt_len(float(s["mount"]["mast_h_mm"]))],
		maxf(float(s["mount"]["mast_h_mm"]) * 0.001 * 6.0, 2.0), float(d["mass"]["mast"])))
	if str(s["mount"]["style"]) == "body_spins":
		out.append(_row("Shaft coupler", 1, "%.0f mm to the mast's %.0f mm" % [float(gen["shaft_mm"]), float(mast["od"])], 3.0, 0.02))
	out.append(_row("Rectifier", 1, "%s" % str(WindLabParts.DIODES[str(s["load"]["diode"])]["label"]), 4.0, 0.02))
	if str(s["load"]["type"]) == "mppt":
		out.append(_row("MPPT controller", 1, "for %.0f V" % float(s["load"]["battery_v"]), 35.0, 0.2))
	out.append(_row("Fasteners", 1, "screws, nuts, washers", 4.0 + float(d["mass"]["rotor"]) * 2.0, float(d["mass"]["misc"]) * 0.3))
	if not bool(d["vawt"]):
		out.append(_row("Nacelle, yaw bearing, tail", 1, "boom %.0f mm, vane %.0f cm²" % [_tail(d)["boom_mm"], _tail(d)["vane_cm2"]], 25.0, 2.0))
	return out


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


## The tail of a propeller: boom ≈ 0.6 D back from the yaw axis, vane area
## ≈ 6 % of the swept area — the usual small-turbine rule of thumb (Piggott,
## A Wind Turbine Recipe Book, 2014 ed., tail sizing).
static func _tail(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var dd := float(s["rotor"]["d_mm"])
	return {"boom_mm": 0.6 * dd, "vane_cm2": 0.06 * float(d["area_m2"]) * 1e4}


static func tail(d: Dictionary) -> Dictionary:
	return _tail(d)


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

static func _check(out: Array, level: String, text: String) -> void:
	out.append({"level": level, "text": text})


static func _checks(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var t := str(s["type"])
	var r: Dictionary = s["rotor"]
	var out: Array = []
	var gen: Dictionary = d["gen"]
	var vm := float(d["v_mean_hub"])
	# Starting.
	var vs := float(d["start_ms"])
	var assist := bool(r.get("start_assist", false))
	if assist and (is_inf(vs) or vs > vm * 1.4):
		_check(out, "warn", "It only starts by itself above %s (cogging %.3f N·m at the rotor): the numbers assume it is pushed or motored up to speed, then it runs on." % [
			"%.1f m/s" % vs if not is_inf(vs) else "any wind", start_torque_nm(d)])
	elif is_inf(vs) or vs > 25.0:
		_check(out, "error", "It will not start on its own: the generator's cogging (%.3f N·m at the rotor) is more than the rotor's standing torque in any wind. Choose a lower-cogging generator or ratio, or tick Start assist." % start_torque_nm(d))
	elif vs > vm * 1.4:
		_check(out, "warn", "Starts at %.1f m/s — above the site's mean of %.1f m/s at the hub, so it sits still much of the time." % [vs, vm])
	else:
		_check(out, "ok", "Starts turning at %.1f m/s (mean at the hub %.1f m/s)." % [vs, vm])
	# Charging.
	var ci := float(d["cut_in_ms"])
	if is_inf(ci):
		_check(out, "error", "It never puts power into the load below %.0f m/s: at its best speed the generator's voltage does not reach the %s. Raise the ratio, choose a higher-voltage generator, or a lower battery / an MPPT." % [float(d["cut_out_ms"]), _load_word(s)])
	else:
		_check(out, "ok" if ci <= maxf(vm * 1.2, 4.0) else "warn", "Charges from %.1f m/s; %s a year (%.1f W average) at a %.1f m/s mean." % [ci, _fmt_kwh(float(d["aep_kwh"])), float(d["mean_w"]), vm])
	# Over-speed.
	var dp: Dictionary = d["design"]
	if float(d["auto_cut_out_ms"]) < 20.0:
		if str(d["cut_out_why"]) == "power":
			_check(out, "warn", "Above %.1f m/s it would make more than half again the generator's %s rating — it needs a brake, a dump load or furling there." % [float(d["auto_cut_out_ms"]), UiText.num(float(gen["rated_w"]), "W")])
		else:
			_check(out, "warn", "The generator passes its %d rpm limit above %.1f m/s — it needs a brake, a dump load or furling there." % [int(gen["max_rpm"]), float(d["auto_cut_out_ms"])])
	# Current.
	if str(gen["kind"]) == "stepper":
		var ceil_a := WindLabGen.current_ceiling(gen)
		_check(out, "info", "A stepper's current levels off at about %.1f A per phase however fast it turns (its inductance) — rated %.1f A, so it cannot overheat as a generator." % [ceil_a, float(gen["amps"])])
	var max_w := 0.0
	for p in d["curve"]:
		if float(p["v"]) <= float(d["cut_out_ms"]):
			max_w = maxf(max_w, float(p["p_elec"]))
	if max_w > float(gen["rated_w"]) * float(d["gen_count"]) * 1.05 and str(d["cut_out_why"]) != "power":
		_check(out, "warn", "At its peak it makes %s, past the generator's %s rating." % [UiText.num(max_w, "W"), UiText.num(float(gen["rated_w"]), "W")])
	# Gearing: where the generator runs at the design wind.
	if bool(dp["running"]) and float(dp["gen_rpm"]) > 0.0:
		_check(out, "info", "At %.0f m/s: rotor %d rpm (λ %.2f, Cp %.2f), generator %d rpm, %.1f V, %s." % [float(s["site"]["design_wind_ms"]),
			int(round(float(dp["rpm"]))), float(dp["lam"]), float(dp["cp"]), int(round(float(dp["gen_rpm"]))), float(dp["v_dc"]),
			UiText.num(float(dp["p_elec"]), "W")])
		var lam_ratio := float(dp["lam"]) / maxf(float(d["cp"]["lam_opt"]), 1e-6)
		if lam_ratio < 0.7:
			_check(out, "warn", "The generator holds the rotor back (λ %.2f, its best is %.2f): a lower ratio or a lighter load lets it run at its best speed." % [float(dp["lam"]), float(d["cp"]["lam_opt"])])
		elif lam_ratio > 1.4:
			_check(out, "warn", "The rotor runs away from its best speed (λ %.2f vs %.2f): the generator takes too little — a higher ratio or more load." % [float(dp["lam"]), float(d["cp"]["lam_opt"])])
	# Geometry.
	if t in ["ugrinsky", "savonius", "lenz2"]:
		if WindLabAero.blades_clash(d["blades"], float(d["sheet_t_mm"]) + 1.0):
			_check(out, "error", "The blades run into each other — reduce the tail sweep or the overlap.")
		if t == "ugrinsky":
			var g: Dictionary = d["ugr"]
			if float(g["tip_r"]) > float(g["R"]) * 1.02:
				_check(out, "warn", "The tail arc ends %.0f mm outside the rotor's circle — the rotor is really Ø %.0f mm." % [float(g["tip_r"]) - float(g["R"]), float(g["tip_r"]) * 2.0])
			if float(g["e"]) < 0.0:
				_check(out, "error", "The semicircle is wider than the radius: its inner end crosses the shaft.")
		if bool(d["too_tight"]):
			_check(out, "error", "%s will not bend to the blade's tightest curve (needs ≥ %.0f mm radius) and cannot be scored — use corrugated plastic or a thinner sheet." % [str(WindLabParts.sheet(str(s["build"]["sheet"]))["label"]), float(WindLabParts.sheet(str(s["build"]["sheet"]))["free_r_mm"])])
		elif int(d["scores"]) > 0:
			_check(out, "ok", "%d score lines per blade set bend the tight curves (facets within %.1f mm of the curve)." % [int(d["scores"]), float(s["build"]["score_tol_mm"])])
	# Sheets.
	var un: Array = d["nest"]["unplaced"]
	if not un.is_empty():
		_check(out, "error", "%s too big for a %s: choose a bigger sheet or a smaller rotor." % [UiText.count(un.size(), "part"), str(d["nest"]["sheet_label"])])
	elif (d["nest"]["sheets"] as Array).size() > 0:
		_check(out, "ok", "Cut from %s." % UiText.count((d["nest"]["sheets"] as Array).size(), str(d["nest"]["sheet_label"])))
	# Mounting.
	var style := str(s["mount"]["style"])
	if style == "body_spins":
		if str(gen["body"]) != "nema":
			_check(out, "error", "Clamping the rotor to the motor body needs a stepper's square face; choose a NEMA stepper or another mount.")
		else:
			_check(out, "info", "The motor's shaft is fixed to the mast and its body turns with the rotor, so its leads twist: use a slip ring (or a few turns of slack for a demo).")
		if float(d["mass"]["rotor"]) > 1.5:
			_check(out, "warn", "A %s rotor hangs on the stepper's own small bearings — put it on its own shaft and bearings." % WindLabSpec.fmt_kg(float(d["mass"]["rotor"])))
	# Tip speed of sheet rotors and blade root of printed propellers.
	var w_max := 0.0
	for p in d["curve"]:
		if float(p["v"]) <= float(d["cut_out_ms"]):
			w_max = maxf(w_max, float(p["w"]))
	var tip := w_max * float(d["R_m"])
	if t in ["ugrinsky", "savonius", "lenz2"] and tip > 25.0:
		_check(out, "warn", "The blade tips reach %.0f m/s before cut-out — sheet blades flutter and tear past ~25 m/s; brake it lower." % tip)
	if t == "hawt" and not (d["prints"] as Array).is_empty():
		var blade: Dictionary = (d["prints"] as Array)[0]
		var solid := WindLabParts.solid(str(s["build"]["solid"]))
		var st: Array = d["stations"]
		var c0 := float(st[0]["c_m"])
		var tt := float(WindLabAero.hawt_airfoil(s)["t"]) * c0
		var a_root := 0.68 * c0 * tt
		var m_b := absf(float(blade["volume_cm3"])) * 1e-6 * float(solid["density"]) * 0.45
		var sig := m_b * w_max * w_max * float(d["R_m"]) * 0.4 / maxf(a_root, 1e-9) / 1e6
		_check(out, "ok" if sig < float(solid["stress_mpa"]) else "warn", "Blade root: %.1f MPa pull at %d rpm against %.0f MPa allowed in %s." % [sig, int(round(w_max * 60.0 / TAU)), float(solid["stress_mpa"]), str(solid["label"])])
	for p in d["prints"]:
		if int(p["pieces"]) > 1:
			_check(out, "info", "%s is %.0f mm long: print it in %d pieces and join them." % [str(p["label"]), float(p["length_mm"]), int(p["pieces"])])
	# The mast, parked, in a storm: the wind on the rotor (drag coefficient
	# 1.2 on its projected area — the swept area for a vertical axis rotor,
	# a quarter of it for a propeller's blades and nacelle) and on the mast,
	# bending it at the foot; guy wires carry most of that (taken here as a
	# quarter of the free-standing moment — an estimate). Reported as the
	# strongest wind it holds at 2/3 of the steel's yield.
	var sx := mast_survival_ms(d)
	var surv := float(s["site"].get("survival_ms", 30.0))
	var how := "guyed" if bool(s["mount"].get("guyed", false)) else "free-standing"
	if sx < surv:
		_check(out, "error" if sx < 0.6 * surv else "warn", "The %s mast only holds a %.0f m/s storm (the site's survival wind is %.0f m/s): a stiffer mast, guy wires, or take it down before a storm." % [how, sx, surv])
	else:
		_check(out, "ok", "The %s mast holds a %.0f m/s storm (site survival %.0f m/s)." % [how, sx, surv])
	for n in d["cp"]["notes"]:
		_check(out, "info", str(n))
	return out


## The strongest parked wind (m/s) the mast holds at 2/3 of yield.
static func mast_survival_ms(d: Dictionary) -> float:
	var s: Dictionary = d["spec"]
	var mast_id := str(s["mount"]["mast"])
	var sec := WindLabParts.mast_section(mast_id)
	var proj := float(d["area_m2"]) * (1.0 if bool(d["vawt"]) else 0.25)
	var mh := float(s["mount"]["mast_h_mm"]) * 0.001
	var od := float(WindLabParts.mast(mast_id)["od"]) * 0.001
	# Moment per unit dynamic pressure (N·m per Pa).
	var m_per_q := 1.2 * proj * float(d["hub_h_m"]) + 1.0 * od * mh * mh * 0.5
	if bool(s["mount"].get("guyed", false)):
		m_per_q *= 0.25
	var allow := WindLabParts.STEEL_YIELD_MPA / 1.5 * 1e6 * float(sec["Z"])
	var q := allow / maxf(m_per_q, 1e-9)
	return sqrt(2.0 * q / float(d["rho"]))


static func _load_word(s: Dictionary) -> String:
	match str(s["load"]["type"]):
		"battery":
			return "%.0f V battery" % float(s["load"]["battery_v"])
		"mppt":
			return "controller's %.0f V minimum" % float(s["load"]["mppt_min_v"])
	return "load"


static func _fmt_kwh(e: float) -> String:
	if e < 10.0:
		return "%.1f kWh" % e
	return "%d kWh" % int(round(e))


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
# Layout in the model frame (the builder's numbers), extent, ports
# ---------------------------------------------------------------------------

## Heights (m, model frame): the rotor's bottom and top, the generator.
static func layout(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var mh := float(s["mount"]["mast_h_mm"]) * 0.001
	var gen: Dictionary = d["gen"]
	var glen := float(gen["len_mm"]) * 0.001
	var style := str(s["mount"]["style"])
	var out := {"mast_top": mh}
	if bool(d["vawt"]):
		var h := float(s["rotor"]["h_mm"]) * 0.001
		var bottom := mh
		match style:
			"on_shaft":
				# The generator stands on the mast, the rotor on its shaft.
				out["gen_face"] = mh + glen
				bottom = mh + glen + 0.02
			"bearings":
				bottom = mh + 0.08
				out["gen_face"] = mh
			_:
				# Body spins: the motor sits in the rotor's middle, its shaft
				# down into a coupler on the mast top.
				bottom = mh - h * 0.5 + glen * 0.5 + 0.03
				out["gen_face"] = mh + 0.03
		out["rotor_bottom"] = bottom
		out["rotor_top"] = bottom + h
		out["hub"] = bottom + h * 0.5
	else:
		out["hub"] = mh + 0.15
		out["rotor_bottom"] = out["hub"] - float(d["R_m"])
		out["rotor_top"] = out["hub"] + float(d["R_m"])
	return out


static func _extent(d: Dictionary) -> void:
	var lay := layout(d)
	var R := maxf(float(d["R_m"]), float(d["tip_r_mm"]) * 0.001)
	if bool(d["vawt"]):
		R = maxf(R * float(d["spec"]["rotor"]["hub"]["overhang"]), R)
		d["aabb"] = AABB(Vector3(-R, 0.0, -R), Vector3(2.0 * R, float(lay["rotor_top"]) + 0.02, 2.0 * R))
	else:
		var tl := _tail(d)
		d["aabb"] = AABB(Vector3(-R, 0.0, -0.4), Vector3(2.0 * R, float(lay["rotor_top"]), 0.5 + float(tl["boom_mm"]) * 0.001 + 0.2))
	d["layout"] = lay


## Connection ports (model frame): the generator's DC leads at the mast foot.
static func ports(d: Dictionary) -> Array:
	var mast_r := float(WindLabParts.mast(str(d["spec"]["mount"]["mast"]))["od"]) * 0.0005
	var y := 0.35
	var out: Array = []
	out.append({"id": "dc_pos", "label": "DC +", "pos": Vector3(mast_r + 0.02, y, 0.02), "normal": Vector3.RIGHT,
		"handle": "positive", "role": "positive", "kind": "dc_electricity", "conduit": ""})
	out.append({"id": "dc_neg", "label": "DC −", "pos": Vector3(mast_r + 0.02, y, -0.02), "normal": Vector3.RIGHT,
		"handle": "negative", "role": "negative", "kind": "dc_electricity", "conduit": ""})
	return out


## The kit as the parts a crew handles: cut sheets flat, printed parts,
## pipe blades, the mast, the generator and a bag of hardware.
static func parts_for_packing(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var out: Array = []
	var sheet := WindLabParts.sheet(str(s["build"]["sheet"]))
	var t_m := maxf(float(d.get("sheet_t_mm", 4.0)) * 0.001, 0.001)
	for p in d.get("parts", []):
		if str(p["id"]) == "pipe_template":
			continue
		var a := float(p["w"]) * float(p["h"]) * 1e-6
		if str(p["id"]) == "hub":
			a *= PI / 4.0
		var l := maxf(float(p["w"]), float(p["h"])) * 0.001
		var w := minf(float(p["w"]), float(p["h"])) * 0.001
		out.append(PackKitter.part(str(p.get("label", p["id"])), "sheet", l, w, t_m,
			a * float(sheet["kg_m2"]), int(p["qty"]), {"group": "sheets"}))
	var m: Dictionary = d["mass"]
	var solid := WindLabParts.solid(str(s["build"]["solid"]))
	var built_kg := 0.0
	for r in out:
		built_kg += float(r["mass_kg"]) * int(r["qty"])
	for p in d.get("prints", []):
		var q := maxi(int(p["qty"]), 1)
		var vol := absf(float(p["volume_cm3"])) * 1e-6
		var kg := vol * float(solid["density"]) * 0.45
		var l := maxf(float(p.get("length_mm", 100.0)) * 0.001, 0.03)
		var side := clampf(sqrt(maxf(vol, 1e-6) / l) * 2.0, 0.02, l)
		out.append(PackKitter.part(str(p.get("label", p["id"])), "piece", l, side, side, kg, q,
			{"group": "prints", "fragile": true}))
		built_kg += kg * q
	var pipe_kg := maxf(float(m["rotor"]) - built_kg, 0.0)
	if pipe_kg > 0.001 and str(s["type"]) == "hawt" and str(s["rotor"]["construction"]) == "pvc_pipe":
		var st: Array = d["stations"]
		var span := float(st[st.size() - 1]["r_m"]) - float(st[0]["r_m"]) if st.size() > 1 else 0.5
		var chord := 0.0
		for e in st:
			chord = maxf(chord, float(e["c_m"]))
		var nb := maxi(int(s["rotor"]["blades"]), 1)
		out.append(PackKitter.part("Pipe blade", "sheet", maxf(span, 0.1), maxf(chord, 0.03), 0.03,
			pipe_kg / nb, nb, {"group": "blades"}))
	var mast := WindLabParts.mast(str(s["mount"]["mast"]))
	var mast_len := float(s["mount"]["mast_h_mm"]) * 0.001
	if mast_len > 0.05 and float(m["mast"]) > 0.0:
		var od := maxf(float(mast["od"]) * 0.001, 0.01)
		out.append(PackKitter.part("Mast", "stick", mast_len, od, od, float(m["mast"]), 1, {"round": true}))
	var gen: Dictionary = d["gen"]
	var gn := maxi(int(d.get("gen_count", 1)), 1)
	var gs := maxf(float(gen.get("frame_mm", gen.get("dia_mm", 100.0))) * 0.001, 0.04)
	out.append(PackKitter.part(str(gen.get("label", "Generator")), "piece", gs * 1.4, gs, gs,
		float(gen["mass_kg"]), gn, {"group": "generator"}))
	if float(m["misc"]) > 0.0:
		out.append(PackKitter.part("Hardware", "loose", 0.3, 0.2, 0.1, float(m["misc"]), 1, {}))
	return out


## The knocked-down kit, kitted into the units a crew carries.
static func packed_spec(d: Dictionary) -> Dictionary:
	var env := PackKitter.envelope(PackKitter.kit(parts_for_packing(d)), "crate")
	if not env.is_empty():
		return env
	return _legacy_packed_spec(d)


static func _legacy_packed_spec(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var sz := WindLabParts.sheet_size(str(s["build"]["sheet_size"]))
	var n := maxi((d["nest"]["sheets"] as Array).size(), 1)
	var long_m := maxf(float(s["mount"]["mast_h_mm"]) * 0.001, float(sz["w"]) * 0.001)
	var wide := float(sz["h"]) * 0.001
	if not bool(d["vawt"]) or str(s["type"]) in ["darrieus_h", "helical"]:
		long_m = maxf(long_m, float(s["rotor"]["d_mm"]) * 0.0005 + 0.05)
		wide = maxf(wide, 0.3)
	var gen: Dictionary = d["gen"]
	var tall := float(n) * float(d["sheet_t_mm"]) * 0.001 + maxf(float(gen.get("frame_mm", gen.get("dia_mm", 100.0))) * 0.001, 0.05) + 0.06
	return {"w_m": long_m + 0.05, "d_m": wide + 0.05, "h_m": tall, "mass_kg": float(d["mass"]["total"]) + 1.0,
		"form": "crate", "stackable": true, "this_side_up": false, "source": "computed"}


## What the graph's wind node reads (WindTurbineSource.power_kw_from_graph_
## specs): the power curve itself, the speed curve the 3D spin follows, and
## the summary numbers the inspector shows.
static func graph_patch(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var pc: Array = []
	var rc: Array = []
	for p in d["curve"]:
		var v := float(p["v"])
		var on := v <= float(d["cut_out_ms"]) + 1e-6
		pc.append([v, float(p["p_elec"]) if on else 0.0])
		rc.append([v, float(p["rpm"]) if on else 0.0])
	var gen: Dictionary = d["gen"]
	var dp: Dictionary = d["design"]
	return {
		"kind": "vawt" if bool(d["vawt"]) else "hawt",
		"windlab_spec": WindLabSpec.to_json_safe(s),
		"power_curve_w": pc,
		"rpm_curve": rc,
		"rotor_diameter_m": float(s["rotor"]["d_mm"]) * 0.001,
		"rotor_radius_m": float(d["R_m"]),
		"rotor_height_m": float(s["rotor"]["h_mm"]) * 0.001 if bool(d["vawt"]) else 0.0,
		"swept_area_m2": float(d["area_m2"]),
		"rated_w": maxf(float(d["peak_w"]), 0.1),
		"cp_peak": float(d["cp"]["cp_max"]),
		"tip_speed_ratio": float(d["cp"]["lam_opt"]),
		"cut_in_ms": float(d["cut_in_ms"]) if not is_inf(float(d["cut_in_ms"])) else float(d["cut_out_ms"]),
		"rated_ms": maxf(float(d["peak_v"]), 1.0),
		"cut_out_ms": float(d["cut_out_ms"]),
		"hub_height_m": float(d["hub_h_m"]),
		"surface_roughness_m": float(s["site"]["roughness_m"]),
		"site_altitude_m": float(s["site"]["altitude_m"]),
		"site_mean_wind_ms": float(s["site"]["mean_wind_ms"]),
		"generator_efficiency": clampf(float(dp["p_elec"]) / maxf(float(dp["p_aero"]), 1e-6), 0.0, 1.0) if bool(dp["running"]) else 0.5,
		"generator": str(gen["label"]),
		"aep_kwh": float(d["aep_kwh"]),
		"model_id": WindLabBuilder.MODEL_ID,
	}


## Interpolate a [[v, value], …] curve (the graph's power / rpm curves).
static func curve_at(curve: Array, v: float) -> float:
	if curve.is_empty() or v <= float(curve[0][0]):
		return 0.0 if curve.is_empty() else float(curve[0][1]) * clampf(v / maxf(float(curve[0][0]), 1e-6), 0.0, 1.0)
	for i in range(1, curve.size()):
		var b: Array = curve[i]
		if v <= float(b[0]):
			var a: Array = curve[i - 1]
			return lerpf(float(a[1]), float(b[1]), (v - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-9))
	return 0.0
