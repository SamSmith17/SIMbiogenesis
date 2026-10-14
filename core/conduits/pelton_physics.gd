class_name PeltonPhysics
extends RefCounted

## Impulse-turbine (Pelton / Turgo) nozzle physics for the unified hydro reach.
## A Pelton's flow is set by its NOZZLE, not by a "design flow" knob: the jet
## velocity follows the net head (v = Cv·√(2·g·h_net)), the nozzle area turns
## that into a flow, and that flow's pipe friction feeds back into the net
## head — the operating point is where the penstock delivery curve meets the
## nozzle demand curve. Pure static + deterministic (bisection, fixed
## iteration count) so it selftests offline and bakes reproducibly.
##
## Sources (cited per project physics convention):
##  - Thake, "The Micro-Hydro Pelton Turbine Manual" (ITDG 2000): nozzle
##    velocity coefficient Cv ≈ 0.97, ideal bucket speed ratio x = u/v_jet
##    with peak efficiency near x ≈ 0.46, runner efficiency well approximated
##    by a parabola vanishing at x = 0 (stalled) and x = 2·x_opt (runaway).
##  - Friction: HydroSource.pipe_friction_head_loss_m (Darcy–Weisbach /
##    Swamee–Jain) — the same kernel the rest of the hydro path uses.

const CV_NOZZLE := 0.97          ## nozzle velocity coefficient (Thake)
const SPEED_RATIO_OPT := 0.46    ## u/v_jet at peak runner efficiency (Thake)
const G := 9.80665
const WATER_DENSITY := 1000.0
const _BISECT_ITERS := 40


## Jet velocity (m/s) at a net head (m).
static func jet_velocity_ms(h_net_m: float) -> float:
	return CV_NOZZLE * sqrt(2.0 * G * maxf(h_net_m, 0.0))


## Total nozzle demand (m³/s) at a net head: n jets of diameter d_j.
static func nozzle_flow_m3s(h_net_m: float, nozzle_d_m: float,
		nozzle_count: int = 1) -> float:
	var n := maxi(nozzle_count, 1)
	var area := PI * 0.25 * maxf(nozzle_d_m, 0.0) * maxf(nozzle_d_m, 0.0)
	return float(n) * area * jet_velocity_ms(h_net_m)


## Net head (m) a flow Q REQUIRES at the nozzle (inverse of nozzle_flow_m3s):
## h = (Q / (n·A·Cv))² / 2g.
static func nozzle_head_required_m(q_m3s: float, nozzle_d_m: float,
		nozzle_count: int = 1) -> float:
	var n := maxi(nozzle_count, 1)
	var area := PI * 0.25 * maxf(nozzle_d_m, 1e-4) * maxf(nozzle_d_m, 1e-4)
	var v := q_m3s / maxf(float(n) * area, 1e-9)
	return (v / CV_NOZZLE) * (v / CV_NOZZLE) / (2.0 * G)


## Operating point where penstock delivery meets nozzle demand: the Q where
## h_gross = h_f(Q) + h_nozzle(Q). Both terms grow monotonically with Q, so
## f(Q) = h_gross − h_f − h_nozzle is monotone decreasing and bisection is
## robust regardless of how over- or under-sized the nozzle is for the pipe.
## Returns {q_m3s, q_lps, h_net_m (jet head), head_loss_m, v_jet_ms}.
static func operating_point(h_gross_m: float, pipe_len_m: float,
		pipe_d_m: float, roughness_m: float, nozzle_d_m: float,
		nozzle_count: int = 1) -> Dictionary:
	var out := {
		"q_m3s": 0.0, "q_lps": 0.0, "h_net_m": 0.0,
		"head_loss_m": 0.0, "v_jet_ms": 0.0,
	}
	var h := maxf(h_gross_m, 0.0)
	if h <= 1e-4 or nozzle_d_m <= 1e-4:
		return out
	# Upper bracket: frictionless nozzle flow at full gross head (delivery can
	# only be less once pipe friction bites).
	var q_hi := nozzle_flow_m3s(h, nozzle_d_m, nozzle_count)
	if q_hi <= 1e-9:
		return out
	var q_lo := 0.0
	for _i in _BISECT_ITERS:
		var q := (q_lo + q_hi) * 0.5
		var h_f := HydroSource.pipe_friction_head_loss_m(
				q, pipe_d_m, pipe_len_m, roughness_m)
		var h_req := nozzle_head_required_m(q, nozzle_d_m, nozzle_count)
		if h_f + h_req > h:
			q_hi = q
		else:
			q_lo = q
	var q_op := (q_lo + q_hi) * 0.5
	var h_f_op := HydroSource.pipe_friction_head_loss_m(
			q_op, pipe_d_m, pipe_len_m, roughness_m)
	var h_net := maxf(h - h_f_op, 0.0)
	out["q_m3s"] = q_op
	out["q_lps"] = q_op * 1000.0
	out["h_net_m"] = h_net
	out["head_loss_m"] = h_f_op
	out["v_jet_ms"] = jet_velocity_ms(h_net)
	return out


## Operating point when the SUPPLY is finite — a spring or creek that simply does
## not run as hard as the nozzle would pass at this head.
##
## Q = min(Q_nozzle(h_gross), Q_supply). When the supply is the binding limit, the
## nozzle only converts the head its OWN flow demands: h_jet =
## nozzle_head_required_m(Q, d, n), which is strictly less than h_gross − h_f. The
## penstock is then not running full / the valve is throttled, and the surplus head
## is never turned into jet velocity. That is why bolting a big nozzle onto a small
## spring makes far less power than the gross head suggests, and why the honest fix
## is a SMALLER jet (see nozzle_d_for_supply_m).
##
## Returns operating_point()'s keys plus {supply_limited, q_supply_m3s,
## unused_head_m}.
##
## ⚠ `supply_m3s` NAN (or negative) means UNCONSTRAINED; 0.0 means DRY. Those are
## opposite answers and both are reachable: a nozzle kind with no design flow is
## unlimited, while a spring that has stopped running supplies exactly zero. Do not
## "simplify" this to a `<= 0` guard — that silently turns a dry spring back into a
## nozzle running at full bore.
static func operating_point_supply_limited(h_gross_m: float, pipe_len_m: float,
		pipe_d_m: float, roughness_m: float, nozzle_d_m: float,
		nozzle_count: int, supply_m3s: float) -> Dictionary:
	var op := operating_point(h_gross_m, pipe_len_m, pipe_d_m, roughness_m,
			nozzle_d_m, nozzle_count)
	op["supply_limited"] = false
	op["q_supply_m3s"] = supply_m3s
	op["unused_head_m"] = 0.0
	if is_nan(supply_m3s) or supply_m3s < 0.0 or supply_m3s >= float(op["q_m3s"]):
		return op
	if supply_m3s <= 0.0:
		# Dry: no water, no jet, no head converted.
		op["q_m3s"] = 0.0
		op["q_lps"] = 0.0
		op["h_net_m"] = 0.0
		op["head_loss_m"] = 0.0
		op["v_jet_ms"] = 0.0
		op["supply_limited"] = true
		op["unused_head_m"] = maxf(h_gross_m, 0.0)
		return op
	var q := supply_m3s
	var h_f := HydroSource.pipe_friction_head_loss_m(
			q, pipe_d_m, pipe_len_m, roughness_m)
	var h_avail := maxf(maxf(h_gross_m, 0.0) - h_f, 0.0)
	# min() is a monotonicity guard only: Q < Q_op implies h_jet(Q) < h_avail(Q).
	var h_net := minf(nozzle_head_required_m(q, nozzle_d_m, nozzle_count), h_avail)
	op["q_m3s"] = q
	op["q_lps"] = q * 1000.0
	op["h_net_m"] = h_net
	op["head_loss_m"] = h_f
	op["v_jet_ms"] = jet_velocity_ms(h_net)
	op["supply_limited"] = true
	op["unused_head_m"] = maxf(h_avail - h_net, 0.0)
	return op


## Nozzle diameter (m) whose operating point passes exactly `supply_m3s` at this
## head and pipe — the "your nozzle is oversized, fit this one" recommendation.
## Q is monotone increasing in d (bigger orifice, more flow, lower net head but
## never enough to reverse it), so bisection is well-posed.
static func nozzle_d_for_supply_m(h_gross_m: float, pipe_len_m: float,
		pipe_d_m: float, roughness_m: float, nozzle_count: int,
		supply_m3s: float) -> float:
	if is_nan(supply_m3s) or supply_m3s <= 0.0 or h_gross_m <= 1e-4:
		return 0.0
	var d_lo := 0.0005   ## 0.5 mm — below any real pico-hydro jet
	var d_hi := 0.050    ## 50 mm — above the PowerSpout's whole range
	if float(operating_point(h_gross_m, pipe_len_m, pipe_d_m, roughness_m,
			d_hi, nozzle_count)["q_m3s"]) < supply_m3s:
		return d_hi
	for _i in _BISECT_ITERS:
		var d := (d_lo + d_hi) * 0.5
		if float(operating_point(h_gross_m, pipe_len_m, pipe_d_m, roughness_m,
				d, nozzle_count)["q_m3s"]) < supply_m3s:
			d_lo = d
		else:
			d_hi = d
	return (d_lo + d_hi) * 0.5


## Runner efficiency vs speed ratio x = u/v_jet: parabola through 0 at x = 0
## (stalled — jet does no work on a stopped bucket) and x = 2·x_opt (runaway —
## buckets outrun the jet), peaking at η_peak at x_opt (Thake §runner design).
static func runner_efficiency(x: float, eta_peak: float) -> float:
	var span := 2.0 * SPEED_RATIO_OPT
	if x <= 0.0 or x >= span:
		return 0.0
	return clampf(eta_peak, 0.0, 1.0) * 4.0 * x * (span - x) / (span * span)


## Shaft speed at an ARBITRARY speed ratio x = u/v_jet, for a runner of pitch-
## circle diameter PCD: u = x·v_jet and ω = 2u / PCD.
static func omega_rad_s_at_ratio(v_jet_ms: float, runner_pcd_m: float,
		x: float) -> float:
	var pcd := maxf(runner_pcd_m, 0.02)
	return 2.0 * maxf(x, 0.0) * maxf(v_jet_ms, 0.0) / pcd


static func rpm_at_ratio(v_jet_ms: float, runner_pcd_m: float, x: float) -> float:
	return omega_rad_s_at_ratio(v_jet_ms, runner_pcd_m, x) * 60.0 / TAU


## Absolute speed (m/s) the water leaves the bucket at, for an ideal 180° bucket:
## the relative velocity `v_jet − u` is reversed by the bucket, so the ground-frame
## exit speed is |v_jet − 2u| = v_jet·|1 − 2x|.
##
## This is the Euler turbine equation's other half, and it is why a well-matched
## Pelton looks like it merely DRIBBLES: at x = x_opt = 0.46 the exit speed is only
## 0.08·v_jet, because nearly all the jet's momentum went into the shaft. Shed the
## load and the buckets outrun the jet, carrying the water round and flinging it —
## the machine visibly throws water everywhere precisely when it is making nothing.
static func bucket_exit_speed_ms(v_jet_ms: float, x: float) -> float:
	return maxf(v_jet_ms, 0.0) * absf(1.0 - 2.0 * maxf(x, 0.0))


## Bucket deflection angle. A Pelton bucket turns the relative flow through
## about 165°, not 180°: the exit lip is cut back so the leaving water clears
## the back of the next bucket (Thake, The Micro-Hydro Pelton Turbine Manual,
## bucket design; textbook ideal 180° is the limit case).
const BUCKET_DEFLECTION_DEG := 165.0


## Absolute (ground-frame) velocity of the water leaving ONE half of a bucket
## splitter, as {tangential, axial, speed} in m/s, for jet speed v_jet, speed
## ratio x = u/v_jet and a bucket that turns the RELATIVE flow through
## `deflect_deg`. Tangential is measured along the JET direction (+ = carried on
## with the wheel, − = thrown back toward the nozzle); axial is the sideways
## component, which the other half of the splitter mirrors. In the bucket frame
## the water arrives at w = v_jet − u and leaves at the same speed turned
## through the deflection; adding u back gives the ground-frame vector.
## With deflect_deg = 180 the axial term vanishes and |tangential| reduces to
## bucket_exit_speed_ms — that identity is pinned in source_physics_selftest.
static func bucket_exit_velocity(v_jet_ms: float, x: float,
		deflect_deg: float = BUCKET_DEFLECTION_DEG) -> Dictionary:
	var v := maxf(v_jet_ms, 0.0)
	var u := maxf(x, 0.0) * v
	var w := v - u
	var turn := deg_to_rad(180.0 - clampf(deflect_deg, 90.0, 180.0))
	var tangential := u - w * cos(turn)
	var axial := absf(w) * sin(turn)
	return {"tangential": tangential, "axial": axial,
		"speed": sqrt(tangential * tangential + axial * axial)}


## Speed ratio for a fractional electrical load. It is the GENERATOR that sets a
## Pelton's speed: at the matched load the runner settles at x_opt, and as the load
## is shed there is less torque to resist the jet so it accelerates toward runaway
## at x = 2·x_opt — exactly where runner_efficiency() already vanishes, so the
## "spins fastest, makes nothing" reading falls out of the existing curve rather
## than needing a second model. load_frac 1.0 = matched, 0.0 = open circuit.
static func speed_ratio_for_load(load_frac: float) -> float:
	var f := clampf(load_frac, 0.0, 1.0)
	return lerpf(2.0 * SPEED_RATIO_OPT, SPEED_RATIO_OPT, f)


## Steady-state shaft speed at the DESIGN point (matched load, x = x_opt).
static func omega_rad_s(v_jet_ms: float, runner_pcd_m: float) -> float:
	return omega_rad_s_at_ratio(v_jet_ms, runner_pcd_m, SPEED_RATIO_OPT)


static func rpm(v_jet_ms: float, runner_pcd_m: float) -> float:
	return omega_rad_s(v_jet_ms, runner_pcd_m) * 60.0 / TAU
