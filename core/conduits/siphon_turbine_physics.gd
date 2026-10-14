class_name SiphonTurbinePhysics
extends RefCounted

## The siphon turbine as a SIPHON, not a culvert.
##
## The machine: a dip tube (6″ PVC) hangs from the turbine into the pond; the
## turbine sits on the bank at the siphon's CREST, above the water; a draft
## tube (8″ PE, "the culvert") runs from the runner down the hill to an exit
## below the pond surface. Once the pipe is full of water the pond's surface
## pushes water up the dip tube with atmospheric pressure and the column in
## the draft tube pulls it through the runner — the runner sees the pressure
## DIFFERENCE between its inlet (sub-atmospheric by the lift and the dip-tube
## losses) and its outlet (sub-atmospheric by the draft below it, less the
## draft-tube losses). Everything below follows from that one picture:
##
##   • Gross head H = pond surface − tailwater (the exit invert on a free
##     discharge). It does not matter how high the crest is — a siphon is a
##     closed conduit, the crest only costs pressure, not head.
##   • Energy balance pond → exit: H = h_dip(Q) + h_draft(Q) + v_exit²/2g + h_t.
##     The runner takes h_t; the pipes and the exit jet take the rest.
##   • Runner flow law: an axial (propeller) runner passes Q = Cq·A_r·√(2g·h_t)
##     (flow coefficient Cq ≈ 0.7 for a free-running propeller unit — Dixon &
##     Hall, Fluid Mechanics and Thermodynamics of Turbomachinery, ch. 9;
##     the exact value is a machine constant, so it is a parameter). With the
##     losses rising as Q² this closes into one monotone equation in Q.
##   • Two atmospheric-pressure limits, both in metres of water, both from
##     Bernoulli along the pipe:
##       crest (runner INLET) absolute head
##           = H_atm − lift − h_dip − v_dip²/2g,   lift = crest − pond surface.
##         Below H_ABS_MIN the dissolved air comes out of solution and the
##         siphon loses its prime — the practical ~7–8 m siphon lift limit.
##       runner OUTLET absolute head
##           = H_atm − (runner − tail) + h_draft
##         (the draft-tube losses RAISE the pressure at the runner). Thoma's
##         criterion needs it ≥ H_vapour + σ·h_t, σ ≈ 0.6 for a propeller
##         runner (Dixon & Hall; Kaplan/propeller σ 0.4–1.2 by specific
##         speed). Past that the runner cavitates: the water column separates
##         below it and any further draft is WASTED — h_t is capped at
##         (inlet abs − H_vapour) / (1 + σ) and the model reports how many
##         metres of exit drop are doing nothing. That cap is the whole lesson
##         of "run the draft pipe lower and watch": power rises with the exit
##         drop until suction, not geometry, is the limit.
##   • Prime: the pond must rise to the crest (an overflow-primed siphon —
##     the water spills over into the draft tube and the column establishes),
##     or, with a vacuum pump, the dip mouth merely has to be submerged.
##     Break: the surface falls to the dip mouth (plus the anti-vortex band
##     the reach adds) and air gets in. Hysteresis via `primed_prev`.
##   • Speed: an axial runner runs at a tip speed ratio φ = u/√(2g·h_t) of
##     about 1.6 (Kaplan/propeller 1.4–2.0 — Dixon & Hall), so
##     rpm = 60·φ·√(2g·h_t) / (π·D_runner).
##
## Pure static, selftested in siphon_hydraulics_selftest.gd.

const G := 9.80665
const WATER_DENSITY := 1000.0
## Standard atmosphere as a water column at sea level (10.33 m).
const H_ATM_SEA_M := 10.33
## Vapour head of water at ~20 °C (2.34 kPa ≈ 0.24 m).
const H_VAPOUR_M := 0.24
## Practical minimum ABSOLUTE head at the siphon crest before dissolved air
## comes out of solution and breaks the column (field practice: siphons hold
## to ~7–8 m of lift, i.e. ~2–3 m absolute at the crest).
const H_ABS_MIN_M := 2.0
## Thoma cavitation coefficient for a propeller runner (see header).
const SIGMA_PROPELLER := 0.6
## Runner flow coefficient Q = Cq·A·√(2g·h_t).
const CQ_RUNNER := 0.70
## Runner tip-speed ratio u / √(2g·h_t).
const PHI_SPEED := 1.6
## Minor-loss coefficients (velocity heads): dip tube = sharp entrance 0.5 +
## two 90° bends at 0.2; draft tube = one bend 0.2 + runner-housing exit 0.1.
const K_DIP_MINOR := 0.9
const K_DRAFT_MINOR := 0.3
## Pipe roughness defaults (m): PVC 0.0015 mm, dual-wall HDPE liner 0.5 mm.
const EPS_PVC_M := 1.5e-6
const EPS_HDPE_M := 5.0e-4
const _BISECT_ITERS := 48


## Atmospheric pressure head (m of water) at a site elevation (ISA barometric).
static func atm_head_m(site_elev_m: float) -> float:
	var z := clampf(site_elev_m, -500.0, 6000.0)
	return H_ATM_SEA_M * pow(1.0 - 2.25577e-5 * z, 5.25588)


## Darcy–Weisbach + minor losses for a run of pipe at flow q (m³/s).
static func pipe_loss_m(q_m3s: float, d_m: float, len_m: float, eps_m: float,
		k_minor: float) -> float:
	var d := maxf(d_m, 0.01)
	var a := PI * 0.25 * d * d
	var v := maxf(q_m3s, 0.0) / a
	var vh := v * v / (2.0 * G)
	var f := HydroSource.darcy_friction_factor(v, d, maxf(eps_m, 0.0))
	return (f * maxf(len_m, 0.0) / d + maxf(k_minor, 0.0)) * vh


## Solve the siphon at a pond level. `p` keys (metres unless noted):
##   pond_level_m, crest_m, dip_mouth_m, outlet_m, [tail_level_m],
##   dip_d_m, [dip_len_m], draft_d_m, draft_len_m, [draft_eps_m], [dip_eps_m],
##   [runner_d_m] (= dip_d_m), [runner_elev_m] (= crest_m), [cq], [sigma],
##   [eta_t] 0.6, [eta_g] 0.7, [max_power_w] 0 = uncapped,
##   [primed_prev] false, [prime_mode] "overflow" | "pump", [site_elev_m] 0.
## Returns the SiphonHydraulics snapshot keys (q_lps, head_m, pe_w, power_w,
## primed, regime, rpm, omega, siphon_start_m, siphon_break_m) plus the siphon
## physics: turbine_head_m, head_loss_m, h_loss_dip_m, h_loss_draft_m,
## v_dip_ms, v_draft_ms, lift_m, crest_abs_m, crest_margin_m, suction_m,
## suction_max_m, cavitating, draft_excess_m, prime_level_m, break_level_m,
## h_atm_m, runner_d_m, submergence_m.
static func solve(p: Dictionary) -> Dictionary:
	var level := float(p.get("pond_level_m", NAN))
	var crest := float(p.get("crest_m", NAN))
	var mouth := float(p.get("dip_mouth_m", NAN))
	var outlet := float(p.get("outlet_m", NAN))
	var tail := float(p.get("tail_level_m", NAN))
	var dip_d := maxf(float(p.get("dip_d_m", 0.152)), 0.02)
	var draft_d := maxf(float(p.get("draft_d_m", 0.203)), 0.02)
	var draft_len := maxf(float(p.get("draft_len_m", 20.0)), 0.5)
	var dip_eps := maxf(float(p.get("dip_eps_m", EPS_PVC_M)), 0.0)
	var draft_eps := maxf(float(p.get("draft_eps_m", EPS_HDPE_M)), 0.0)
	var runner_d := float(p.get("runner_d_m", 0.0))
	if runner_d <= 0.0:
		runner_d = dip_d
	var cq := clampf(float(p.get("cq", CQ_RUNNER)), 0.1, 1.0)
	var sigma := maxf(float(p.get("sigma", SIGMA_PROPELLER)), 0.0)
	var eta_t := clampf(float(p.get("eta_t", 0.6)), 0.05, 1.0)
	var eta_g := clampf(float(p.get("eta_g", 0.7)), 0.05, 1.0)
	var max_power_w := maxf(float(p.get("max_power_w", 0.0)), 0.0)
	var primed_prev := bool(p.get("primed_prev", false))
	var prime_mode := str(p.get("prime_mode", "overflow"))
	var h_atm := atm_head_m(float(p.get("site_elev_m", 0.0)))

	var out := {
		"q_lps": 0.0, "q_m3s": 0.0, "q_lph": 0.0,
		"head_m": 0.0, "turbine_head_m": 0.0, "head_loss_m": 0.0,
		"h_loss_dip_m": 0.0, "h_loss_draft_m": 0.0, "v_dip_ms": 0.0, "v_draft_ms": 0.0,
		"pe_w": 0.0, "power_w": 0.0, "power_kw": 0.0,
		"primed": false, "regime": "dry", "omega": 0.0, "rpm": 0.0,
		"lift_m": 0.0, "crest_abs_m": h_atm, "crest_margin_m": h_atm - H_ABS_MIN_M,
		"suction_m": 0.0, "suction_max_m": h_atm - H_VAPOUR_M, "cavitating": false,
		"draft_excess_m": 0.0, "h_atm_m": h_atm, "runner_d_m": runner_d,
		"submergence_m": 0.0,
		"siphon_start_m": crest, "siphon_break_m": mouth,
		"prime_level_m": crest, "break_level_m": mouth,
	}
	if is_nan(level) or is_nan(crest) or is_nan(mouth) or is_nan(outlet):
		out["regime"] = "unset"
		return out
	if crest < mouth:
		var t := crest
		crest = mouth
		mouth = t
		out["siphon_start_m"] = crest
		out["siphon_break_m"] = mouth
	# Where the water must reach to prime. Overflow: the crest (the pond spills
	# into the draft tube). Pump: the mouth, submerged by half a bore.
	var prime_level := crest
	if prime_mode == "pump":
		prime_level = mouth + maxf(0.5 * dip_d, 0.02)
	out["prime_level_m"] = prime_level
	out["submergence_m"] = level - mouth
	var primed := primed_prev
	if level >= prime_level:
		primed = true
	if level < mouth:
		primed = false
	out["primed"] = primed
	if not primed:
		out["regime"] = "broken" if primed_prev else "dry"
		return out
	# Tailwater: the exit invert on a free discharge, the pool surface when the
	# exit is drowned (a drowned exit still counts — the siphon ends at the pool).
	var tail_m := outlet
	if not is_nan(tail) and tail > outlet:
		tail_m = tail
	var head := level - tail_m
	out["head_m"] = maxf(head, 0.0)
	if head <= 1e-4:
		out["regime"] = "no_head"
		return out
	var runner_elev := float(p.get("runner_elev_m", crest))
	if is_nan(runner_elev):
		runner_elev = crest
	var lift := maxf(crest - level, 0.0)
	out["lift_m"] = lift
	var dip_len := float(p.get("dip_len_m", NAN))
	if is_nan(dip_len) or dip_len <= 0.0:
		# The hanging length plus the run over the bank into the housing.
		dip_len = maxf(crest - mouth, 0.1) + 0.5
	var a_r := PI * 0.25 * runner_d * runner_d
	var a_dip := PI * 0.25 * dip_d * dip_d
	var a_draft := PI * 0.25 * draft_d * draft_d

	# 1. Energy balance, uncapped, and the two atmospheric limits at that point.
	# The runner's own datum: its inlet pressure is the column's pressure AT
	# THE RUNNER (sub-atmospheric by how far it stands above the surface,
	# NEGATIVE = pressurised when it sits below it). The crest is only where
	# the air-release check applies. Mixing the two datums put a step into
	# the cavitation cap equal to crest − runner.
	var lift_runner := runner_elev - level
	var u := _uncapped(head, lift_runner, runner_elev - tail_m, dip_d, dip_len, dip_eps,
			draft_d, draft_len, draft_eps, cq, a_r, h_atm, sigma)
	var q := float(u["q"])
	var h_dip := float(u["h_dip"])
	var h_draft := float(u["h_draft"])
	var h_exit := float(u["h_exit"])
	var h_t := float(u["h_t"])
	var v_dip := float(u["v_dip"])
	var inlet_abs := float(u["inlet_abs"])
	var suction := float(u["suction"])
	var suction_max := float(u["suction_max"])

	# 2. Crest absolute head — the siphon-lift limit (the highest point of
	#    the column, where dissolved air comes out first).
	var crest_abs := h_atm - lift - h_dip - v_dip * v_dip / (2.0 * G)
	out["crest_abs_m"] = crest_abs
	out["crest_margin_m"] = crest_abs - H_ABS_MIN_M
	if crest_abs < H_ABS_MIN_M:
		# Dissolved air comes out at the crest and the column breaks. The
		# prime stays latched so a marginal lift does not flicker; nothing
		# flows until the lift (or the dip-tube losses) come down.
		out["regime"] = "lift_exceeded"
		return out

	# 3. Runner OUTLET absolute head — Thoma's cavitation limit. The draft
	#    below the runner pulls its outlet below atmosphere; the draft-tube
	#    losses give some of that back.
	var cavitating := false
	var excess := 0.0
	if suction > suction_max + 1e-6:
		cavitating = true
		# Past inception the column separates below the runner and the outlet
		# sits AT the cavitation pressure: h_t = inlet_abs − outlet_abs with
		# outlet_abs = H_v + σ·h_t, so h_t = (inlet_abs − H_v)/(1 + σ). The
		# runner then passes Q = Cq·A·√(2g·h_t); the dip losses move with Q,
		# so iterate the pair (contracting).
		# The head across the runner is pressure PLUS the velocity-head
		# change from the dip bore to the draft bore (a 6″ tube into an 8″
		# pipe is 3× the velocity head), so the cap is on the TOTAL inlet
		# head less the outlet velocity head — the same quantity the energy
		# balance closes on, which is what makes the cap continuous at
		# inception.
		for _k in 8:
			var v_e_k := q / a_draft
			var total_in := h_atm - lift_runner - h_dip - v_e_k * v_e_k / (2.0 * G)
			var h_t_cap := maxf((total_in - H_VAPOUR_M) / (1.0 + sigma), 0.0)
			h_t = minf(h_t, h_t_cap)
			q = cq * a_r * sqrt(2.0 * G * h_t)
			h_dip = pipe_loss_m(q, dip_d, dip_len, dip_eps, K_DIP_MINOR)
			v_dip = q / a_dip
			inlet_abs = h_atm - lift_runner - h_dip - v_dip * v_dip / (2.0 * G)
		h_draft = pipe_loss_m(q, draft_d, draft_len, draft_eps, K_DRAFT_MINOR)
		var v_e2 := q / a_draft
		h_exit = v_e2 * v_e2 / (2.0 * G)
		suction = (runner_elev - tail_m) - h_draft
		suction_max = h_atm - H_VAPOUR_M - sigma * h_t
		out["crest_abs_m"] = h_atm - lift - h_dip - v_dip * v_dip / (2.0 * G)
		out["crest_margin_m"] = float(out["crest_abs_m"]) - H_ABS_MIN_M
		# How much of the exit drop is doing nothing: the drop at which
		# cavitation just begins (bisection on the tail elevation between the
		# runner and the actual exit — the margin is monotone in the drop).
		var lo := 0.0                      # drop below the runner: no cavitation
		var hi := runner_elev - tail_m     # the actual drop: cavitating
		for _j in 24:
			var mid := 0.5 * (lo + hi)
			var um := _uncapped(level - (runner_elev - mid), lift_runner, mid, dip_d, dip_len, dip_eps,
					draft_d, draft_len, draft_eps, cq, a_r, h_atm, sigma)
			if float(um["suction"]) > float(um["suction_max"]):
				hi = mid
			else:
				lo = mid
		excess = maxf((runner_elev - tail_m) - 0.5 * (lo + hi), 0.0)
	out["suction_m"] = suction
	out["suction_max_m"] = suction_max
	out["inlet_abs_m"] = inlet_abs
	out["cavitating"] = cavitating
	out["draft_excess_m"] = excess
	out["useful_draft_m"] = (runner_elev - tail_m) - excess

	# 4. Flow, power, speed.
	var v_e := q / a_draft
	out["q_m3s"] = q
	out["q_lps"] = q * 1000.0
	out["q_lph"] = q * 1000.0 * 3600.0
	out["turbine_head_m"] = h_t
	out["h_loss_dip_m"] = h_dip
	out["h_loss_draft_m"] = h_draft
	out["head_loss_m"] = h_dip + h_draft + h_exit
	out["v_dip_ms"] = v_dip
	out["v_draft_ms"] = v_e
	out["pe_w"] = WATER_DENSITY * G * q * maxf(head, 0.0)
	var power_w := WATER_DENSITY * G * q * h_t * eta_t * eta_g
	if max_power_w > 1e-6:
		power_w = minf(power_w, max_power_w)
	out["power_w"] = power_w
	out["power_kw"] = power_w / 1000.0
	var u_tip := PHI_SPEED * sqrt(2.0 * G * h_t)
	var omega := u_tip / maxf(runner_d * 0.5, 0.01)
	out["omega"] = omega
	out["rpm"] = omega * 60.0 / TAU
	out["regime"] = "siphon_cavitating" if cavitating else "siphon_flow"
	return out


## The full energy balance at a gross head with the runner law closing it, and
## the two atmospheric pressures (inlet, outlet) at that operating point.
## `draft_below` = runner − tail (m). Returns q, h_t, h_dip, h_draft, h_exit,
## v_dip, inlet_abs, suction (= draft − h_draft), suction_max (Thoma).
static func _uncapped(head: float, lift: float, draft_below: float, dip_d: float,
		dip_len: float, dip_eps: float, draft_d: float, draft_len: float, draft_eps: float,
		cq: float, a_r: float, h_atm: float, sigma: float) -> Dictionary:
	var a_dip := PI * 0.25 * dip_d * dip_d
	var a_draft := PI * 0.25 * draft_d * draft_d
	var h := maxf(head, 0.0)
	var q_hi := cq * a_r * sqrt(2.0 * G * h) * 1.5 + maxf(a_dip, a_draft) * sqrt(2.0 * G * h)
	var q_lo := 0.0
	var q := 0.0
	for _i in _BISECT_ITERS:
		q = 0.5 * (q_lo + q_hi)
		if _balance(q, h, dip_d, dip_len, dip_eps, draft_d, draft_len, draft_eps, a_draft, cq, a_r) > 0.0:
			q_lo = q
		else:
			q_hi = q
	q = 0.5 * (q_lo + q_hi)
	var h_dip := pipe_loss_m(q, dip_d, dip_len, dip_eps, K_DIP_MINOR)
	var h_draft := pipe_loss_m(q, draft_d, draft_len, draft_eps, K_DRAFT_MINOR)
	var v_e := q / a_draft
	var h_exit := v_e * v_e / (2.0 * G)
	var h_t := maxf(h - h_dip - h_draft - h_exit, 0.0)
	var v_dip := q / a_dip
	var inlet_abs := h_atm - lift - h_dip - v_dip * v_dip / (2.0 * G)
	return {
		"q": q, "h_t": h_t, "h_dip": h_dip, "h_draft": h_draft, "h_exit": h_exit,
		"v_dip": v_dip, "inlet_abs": inlet_abs,
		"suction": draft_below - h_draft,
		"suction_max": h_atm - H_VAPOUR_M - sigma * h_t,
	}


## f(Q) = H − h_dip − h_draft − v_e²/2g − (Q/(Cq·A_r))²/2g; monotone decreasing.
static func _balance(q: float, head: float, dip_d: float, dip_len: float, dip_eps: float,
		draft_d: float, draft_len: float, draft_eps: float, a_draft: float,
		cq: float, a_r: float) -> float:
	var h_dip := pipe_loss_m(q, dip_d, dip_len, dip_eps, K_DIP_MINOR)
	var h_draft := pipe_loss_m(q, draft_d, draft_len, draft_eps, K_DRAFT_MINOR)
	var v_e := q / a_draft
	var vr := q / maxf(cq * a_r, 1e-9)
	return head - h_dip - h_draft - v_e * v_e / (2.0 * G) - vr * vr / (2.0 * G)


## The exit drop (runner − tail, metres) at which the runner outlet reaches the
## cavitation limit for a given turbine head — "how low is worth going".
static func max_useful_draft_m(h_t: float, h_draft_loss: float, site_elev_m: float = 0.0,
		sigma: float = SIGMA_PROPELLER) -> float:
	return atm_head_m(site_elev_m) - H_VAPOUR_M - sigma * maxf(h_t, 0.0) + maxf(h_draft_loss, 0.0)
