class_name HydroReach
extends RefCounted

## Unified pond → siphon module → culvert → outlet hydro reach. The single physics
## authority for the whole chain — every consumer reads THIS, none re-simulate.
##
## Three entry points, one shared physics core (evaluate()):
##   • evaluate(level) [+ static evaluate_specs] — STATELESS physics at a pond
##     level: flow / head / power / RPM / prime, incl. the effective-air-break
##     override. The Lab readouts and the flow engine both read this, so their
##     numbers can't diverge.
##   • step(dt, inflow) — self-contained INTEGRATOR (Lab / offline / tests):
##     advances pond storage, drains mass-conservingly (never below the air-break
##     dead pool), meters the outlet. Owns its own pond stock.
##   • drainable_lph(q, dt) — the flow engine keeps net_rates as the tank
##     integrator, so it doesn't call step(); instead it evaluates() the flow and
##     clamps it through this helper to the stock above the dead pool. Same
##     conservation as step(), just applied through the engine's own integrator so
##     the pond can't drain below the dead pool or over-credit the outlet.
##
## This replaced the split that made the feature buggy: the modal's own
## `SiphonHydraulics.simulate` fallback AND the flow engine's *unclamped* net_rates
## bookkeeping were two integrators that could disagree at the dead-pool crossing.
##
## Pure RefCounted — no scene/graph dependency (build it from a graph elsewhere).
## Physics delegates to the selftested SiphonHydraulics / CulvertHydraulics.

# --- Pond (prismatic storage; bathymetry can be layered on via set_pond_level) --
var pond_floor_m: float = NAN
var pond_rim_m: float = NAN
var pond_capacity_l: float = 0.0
var pond_stock_l: float = 0.0

# --- Siphon module -----------------------------------------------------------
var siphon_start_m: float = NAN        ## Prime level (water rises to here → flow).
var siphon_break_m: float = NAN        ## Air-break level (falls below → stop).
var intake_diameter_m: float = 0.203
var outlet_diameter_m: float = 0.203
var barrel_length_m: float = 20.0
var manning_n: float = CulvertHydraulics.DEFAULT_MANNING_N
var outlet_invert_m: float = NAN
var max_power_w: float = 0.0
var hydraulic_efficiency: float = 0.6
var generator_efficiency: float = 0.7

# --- Generalized turbine conveyance ------------------------------------------
## "siphon" (orifice/weir over a barrel — the original path) or "penstock" (a
## pressurized pipe feeding a pelton/turgo/run-of-river turbine). Selected from
## the turbine kind's `has_penstock` in configure_siphon(). In penstock mode the
## pond drains through a graded penstock at a rate set by gravity delivery vs.
## turbine design flow; there is NO prime/break — flow runs whenever the intake
## is submerged. `siphon_break_m` is reused as the penstock intake invert so the
## submergence dead-pool machinery works unchanged.
var conveyance: String = "siphon"
var turbine_kind: String = "siphon"
var penstock_length_m: float = 60.0
var penstock_diameter_m: float = 0.063
var pipe_roughness_m: float = 1.5e-6
var design_flow_lps: float = 3.0
var turbine_efficiency: float = 0.0   ## 0 → per-kind default from HydroSource.KINDS

# --- Persistent state --------------------------------------------------------
var primed: bool = false
var cumulative_out_l: float = 0.0
var overflow_l: float = 0.0

## Last computed snapshot (see step()/evaluate() return dict).
var last: Dictionary = {}


## ---------------------------------------------------------------------------
## Configuration helpers
## ---------------------------------------------------------------------------

## Prismatic pond geometry + current volume.
func set_pond(floor_m: float, rim_m: float, capacity_l: float, stock_l: float) -> void:
	pond_floor_m = floor_m
	pond_rim_m = rim_m
	pond_capacity_l = maxf(capacity_l, 0.0)
	pond_stock_l = clampf(stock_l, 0.0, pond_capacity_l if pond_capacity_l > 0.0 else stock_l)


## Set the pond by water-surface elevation (back-computes stock prismatically).
func set_pond_level(level_m: float) -> void:
	if is_nan(pond_floor_m) or is_nan(pond_rim_m) or pond_capacity_l <= 0.0:
		return
	pond_stock_l = clampf(_frac_at_level(level_m), 0.0, 1.0) * pond_capacity_l


## Copy siphon params from a flat graph-specs dictionary (inspector units:
## mm, m). Mirrors SiphonHydraulics.simulate_from_specs key names.
func configure_siphon(specs: Dictionary) -> void:
	intake_diameter_m = maxf(float(specs.get("intake_diameter_mm", 203.0)) / 1000.0, 0.05)
	outlet_diameter_m = maxf(float(specs.get("outlet_diameter_mm", 203.0)) / 1000.0, 0.05)
	barrel_length_m = maxf(float(specs.get("barrel_length_m", 20.0)), 0.5)
	manning_n = float(specs.get("manning_n", CulvertHydraulics.DEFAULT_MANNING_N))
	max_power_w = maxf(float(specs.get("max_power_w", 0.0)), 0.0)
	hydraulic_efficiency = float(specs.get("hydraulic_efficiency", 0.6))
	generator_efficiency = float(specs.get("generator_efficiency", 0.7))
	var levels := SiphonHydraulics.resolve_siphon_levels(specs)
	var start_m := float(levels.get("siphon_start_m", NAN))
	if is_nan(start_m):
		start_m = float(specs.get("intake_crown_m", NAN))
	var break_m := float(levels.get("siphon_break_m", NAN))
	if is_nan(break_m):
		break_m = float(specs.get("intake_invert_m", NAN))
	siphon_start_m = start_m
	siphon_break_m = break_m
	outlet_invert_m = float(specs.get("outlet_invert_m", NAN))
	primed = bool(specs.get("siphon_primed", primed))

	# Generalized turbine kind → conveyance. Absent key ("siphon") keeps every
	# existing save byte-identical to the original siphon path. NOTE: do NOT fall
	# back to the legacy `kind` key here — for siphon_hydro-role items `kind`
	# duplicates the ROLE ("siphon_hydro"), not a turbine kind, so reading it would
	# wrongly flip the conveyance. (The estimator's `kind` fallback is only for
	# type-"hydro" estimator items, where `kind` really is a turbine kind.)
	turbine_kind = str(specs.get("turbine_kind", "siphon"))
	conveyance = "penstock" if bool(HydroSource.kind_meta(turbine_kind).get(
			"has_penstock", false)) else "siphon"
	penstock_length_m = maxf(float(specs.get("penstock_length_m", 60.0)), 0.0)
	penstock_diameter_m = maxf(float(specs.get("penstock_diameter_mm", 63.0)) / 1000.0, 0.01)
	pipe_roughness_m = maxf(float(specs.get("pipe_roughness_mm", 0.0015)) / 1000.0, 0.0)
	design_flow_lps = maxf(float(specs.get("design_flow_lps", 3.0)), 0.0)
	turbine_efficiency = float(specs.get("turbine_efficiency", 0.0))


## ---------------------------------------------------------------------------
## Physics
## ---------------------------------------------------------------------------

## Current pond water-surface elevation (prismatic), or NAN if pond unset.
func pond_level_m() -> float:
	if is_nan(pond_floor_m) or is_nan(pond_rim_m):
		return NAN
	var span := maxf(pond_rim_m - pond_floor_m, 0.001)
	var frac := 0.0
	if pond_capacity_l > 1e-6:
		frac = clampf(pond_stock_l / pond_capacity_l, 0.0, 1.0)
	return pond_floor_m + frac * span


## Pure evaluation at a pond level (no state change beyond reading `primed` for
## hysteresis). `level_override` defaults to the current prismatic pond level.
## Same numbers as SiphonHydraulics.simulate, PLUS the effective-break override
## so the prime drops promptly at the air-entrainment level instead of creeping
## down the asymptotic weir-taper. This is the single physics entry point shared
## by the flow engine, the Lab readouts, and step().
func evaluate(level_override: float = NAN) -> Dictionary:
	var level := level_override if not is_nan(level_override) else pond_level_m()
	if conveyance == "penstock":
		return _penstock_evaluate(level)
	var r := SiphonHydraulics.simulate(level, siphon_break_m, siphon_start_m,
		outlet_invert_m, intake_diameter_m, outlet_diameter_m,
		barrel_length_m, manning_n, primed, max_power_w,
		hydraulic_efficiency, generator_efficiency,
		siphon_start_m, siphon_break_m)
	var eff := effective_break_level_m()
	if not is_nan(level) and not is_nan(eff) and level <= eff:
		# Below minimum submergence — air enters the intake, prime is lost.
		r["primed"] = false
		r["q_lps"] = 0.0
		r["q_m3s"] = 0.0
		r["q_lph"] = 0.0
		r["pe_w"] = 0.0
		r["power_w"] = 0.0
		r["power_kw"] = 0.0
		r["omega"] = 0.0
		r["rpm"] = 0.0
		var reg := str(r.get("regime", ""))
		if reg != "dry" and reg != "unset" and reg != "no_head":
			r["regime"] = "broken"
	# Generalized snapshot keys (siphon has no separate penstock capacity — report
	# its own numbers so consumers never branch on conveyance).
	r["conveyance"] = "siphon"
	r["q_capacity_lps"] = float(r.get("q_lps", 0.0))
	r["head_loss_m"] = 0.0
	r["net_head_m"] = float(r.get("head_m", 0.0))
	return r


## Penstock turbine draw: the pond drains through a pressurized pipe at a rate
## set by gravity delivery capacity vs. the turbine's design flow, and generates
## via the standard P = ρgQh_net·η. No prime/break — flow runs whenever the
## intake is submerged. Uses the SAME Darcy–Weisbach / Swamee–Jain relations as
## HydroSource (which powers the graph "hydro" estimator), so a pond turbine and
## a standalone estimator agree.
func _penstock_evaluate(level: float) -> Dictionary:
	var r := {
		"q_lps": 0.0, "q_m3s": 0.0, "q_lph": 0.0, "head_m": 0.0,
		"pe_w": 0.0, "power_w": 0.0, "power_kw": 0.0, "primed": false,
		"regime": "dry", "omega": 0.0, "rpm": 0.0,
		"siphon_start_m": siphon_start_m, "siphon_break_m": siphon_break_m,
		"conveyance": "penstock", "q_capacity_lps": 0.0,
		"head_loss_m": 0.0, "net_head_m": 0.0,
	}
	if is_nan(level) or is_nan(outlet_invert_m):
		r["regime"] = "unset"
		return r
	var gross_head := level - outlet_invert_m
	r["head_m"] = maxf(gross_head, 0.0)
	# Intake must stay submerged (same ½-diameter anti-vortex band as the siphon,
	# using the penstock intake diameter). Below it → no flow (the dead pool).
	var eff := effective_break_level_m()
	if not is_nan(eff) and level <= eff:
		r["regime"] = "dry"
		return r
	if gross_head <= 1e-4:
		r["regime"] = "no_head"
		return r
	var q_cap_lps := _penstock_capacity_lps(gross_head)
	r["q_capacity_lps"] = q_cap_lps
	# Operating point: the turbine draws its design flow, but never more than the
	# penstock can gravity-deliver at the current head — so as the pond draws
	# down and head falls, delivery (and power) taper naturally.
	var q_lps := minf(q_cap_lps, design_flow_lps)
	if q_lps <= 1e-6:
		r["regime"] = "no_head"
		return r
	var q_m3s := q_lps / 1000.0
	var h_f := HydroSource.pipe_friction_head_loss_m(
			q_m3s, penstock_diameter_m, penstock_length_m, pipe_roughness_m)
	var h_net := maxf(gross_head - h_f, 0.0)
	var eta_t := turbine_efficiency
	if eta_t <= 0.0:
		eta_t = HydroSource.default_turbine_efficiency(turbine_kind)
	var eta_g := clampf(generator_efficiency, 0.05, 1.0)
	var rho := CulvertHydraulics.WATER_DENSITY
	var g := CulvertHydraulics.G
	var pe_w := rho * g * q_m3s * maxf(gross_head, 0.0)
	var power_w := rho * g * q_m3s * h_net * clampf(eta_t, 0.05, 1.0) * eta_g
	if max_power_w > 0.0:
		power_w = minf(power_w, max_power_w)
	r["q_lps"] = q_lps
	r["q_m3s"] = q_m3s
	r["q_lph"] = q_lps * 3600.0
	r["pe_w"] = pe_w
	r["power_w"] = power_w
	r["power_kw"] = power_w / 1000.0
	r["head_loss_m"] = h_f
	r["net_head_m"] = h_net
	r["primed"] = true   # a submerged penstock is always "flowing" for visuals
	r["regime"] = "penstock"
	var omega := SiphonHydraulics.omega_from_pe_w(pe_w)
	r["omega"] = omega
	r["rpm"] = omega * 60.0 / TAU
	return r


## Gravity delivery capacity (L/s) of the penstock at a gross head H, from the
## free-discharge energy balance H = (1 + K_entrance + f·L/D)·v²/2g. Solves the
## friction factor by fixed-point iteration on Swamee–Jain (converges in 2–3
## passes; monotone, no bracketing needed). Guards degenerate geometry.
func _penstock_capacity_lps(gross_head: float) -> float:
	var d := maxf(penstock_diameter_m, 0.01)
	var l := maxf(penstock_length_m, 0.0)
	var eps := maxf(pipe_roughness_m, 0.0)
	var h := maxf(gross_head, 0.0)
	if h <= 0.0:
		return 0.0
	const K_ENTRANCE := 0.5   ## sharp pipe entrance, standard minor-loss coeff
	var g := CulvertHydraulics.G
	var f := 0.02
	var v := 0.0
	for _i in 5:
		var denom := 1.0 + K_ENTRANCE + f * l / d
		v = sqrt(2.0 * g * h / maxf(denom, 1e-6))
		v = clampf(v, 0.0, 10.0)   # numeric sanity cap (~unphysically fast anyway)
		var f_next := HydroSource.darcy_friction_factor(v, d, eps)
		if f_next > 1e-6:
			f = f_next
	var area := PI * d * d * 0.25
	return v * area * 1000.0


## Drop-in for SiphonHydraulics.simulate_from_specs: evaluate a siphon from a
## flat graph-specs dict at a given pond level, through the unified reach (so the
## engine and the Lab share ONE physics path). Reads `siphon_primed` for
## hysteresis; does not integrate storage (use step() for that).
static func evaluate_specs(level_m: float, specs: Dictionary) -> Dictionary:
	var reach := HydroReach.new()
	reach.configure_siphon(specs)
	return reach.evaluate(level_m)


## Advance the reach one timestep. `inflow_lps` is the catchment/test fill into
## the pond (L/s). Integrates pond storage, drains through the siphon (clamped
## to the air-break level), and meters the outlet. Returns a snapshot dict with
## the SiphonHydraulics fields plus pond/outlet accounting keys.
func step(dt_hours: float, inflow_lps: float = 0.0) -> Dictionary:
	dt_hours = maxf(dt_hours, 0.0)
	var dt_s := dt_hours * 3600.0

	# 1. Inflow into the pond (catchment rain or test fill), clamp at rim.
	pond_stock_l += maxf(inflow_lps, 0.0) * dt_s
	if pond_capacity_l > 0.0 and pond_stock_l > pond_capacity_l:
		overflow_l += pond_stock_l - pond_capacity_l
		pond_stock_l = pond_capacity_l

	# 2. Evaluate flow at the current level (carries prime hysteresis).
	var r := evaluate()
	primed = bool(r.get("primed", false))

	# 3. Drain — mass-conserving, never below the air-break stock.
	var q_lps := float(r.get("q_lps", 0.0))
	var want_l := q_lps * dt_s
	var avail_l := _stock_above_break()
	var drained_l := clampf(want_l, 0.0, avail_l)
	pond_stock_l = maxf(pond_stock_l - drained_l, 0.0)
	cumulative_out_l += drained_l

	# Break when submergence over the intake drops into the air-entrainment band.
	# A real siphon breaks abruptly once submergence falls below ~½ pipe diameter
	# (air-core vortex forms) — NOT the asymptotic weir-flow taper the raw
	# stage-discharge curve would otherwise creep down forever. Both the drain
	# floor (_stock_above_break) and this check use the same effective level so
	# the pond parks with a realistic dead pool and the prime breaks promptly.
	# Siphon-only prime break (a penstock has no prime — _penstock_evaluate
	# already returns q=0 below the submergence level, so the drain floors there
	# without any latch).
	if conveyance != "penstock":
		var eff_break := effective_break_level_m()
		if primed and not is_nan(eff_break) and pond_level_m() <= eff_break + 1e-4:
			primed = false
			r["primed"] = false
			r["regime"] = "broken"

	# Effective (mass-consistent) rate actually pulled this step — the readout
	# the outlet/culvert visual should scroll to, so a starved siphon reads honest.
	var eff_lps := q_lps
	if dt_s > 1e-9:
		eff_lps = drained_l / dt_s

	r["q_lps_effective"] = eff_lps
	r["drained_l"] = drained_l
	r["inflow_lps"] = maxf(inflow_lps, 0.0)
	r["pond_stock_l"] = pond_stock_l
	r["pond_level_m"] = pond_level_m()
	r["cumulative_out_l"] = cumulative_out_l
	r["overflow_l"] = overflow_l
	last = r
	return r


## Litres of pond storage the siphon can pull before it sucks air (public reader
## for the flow engine, which owns the tank integrator but must honor the same
## dead-pool floor step() uses).
func stock_above_break() -> float:
	return _stock_above_break()


## Mass-conserving drain rate (L/h) for an EXTERNAL tank integrator (the flow
## engine keeps net_rates as the pond integrator but must never let the siphon
## pull the pond below the air-break dead pool within one step). Pass the flow the
## reach evaluated at the current level and the step dt; returns that flow clamped
## so `rate × dt` never exceeds the stock above the effective break. Configure the
## reach + set_pond() first. At steady state (pond above the dead pool) this is a
## no-op — the clamp only bites on the crossing tick, so existing saves are
## byte-identical away from the dead pool.
func drainable_lph(q_lph: float, dt_hours: float) -> float:
	if dt_hours <= 1e-9:
		return maxf(q_lph, 0.0)
	var avail_lph := _stock_above_break() / dt_hours
	return clampf(q_lph, 0.0, maxf(avail_lph, 0.0))


## ---------------------------------------------------------------------------
## Internals
## ---------------------------------------------------------------------------

func _frac_at_level(level_m: float) -> float:
	var span := maxf(pond_rim_m - pond_floor_m, 0.001)
	return clampf((level_m - pond_floor_m) / span, 0.0, 1.0)


## Air-entrainment band above the intake invert (min submergence ≈ ½ intake
## diameter). Uses the penstock diameter in penstock mode, the siphon barrel
## intake diameter otherwise.
func _break_band() -> float:
	var d := penstock_diameter_m if conveyance == "penstock" else intake_diameter_m
	return maxf(0.5 * d, 0.02)


## Effective surface level at which the siphon loses prime (break + submergence
## band). The pond can't be siphoned below this — the realistic dead pool.
func effective_break_level_m() -> float:
	if is_nan(siphon_break_m):
		return NAN
	return siphon_break_m + _break_band()


## Litres of pond storage the siphon can actually pull before it sucks air
## (everything above the effective break level). Full stock if geometry unset.
func _stock_above_break() -> float:
	var eff := effective_break_level_m()
	if is_nan(eff) or is_nan(pond_floor_m) or is_nan(pond_rim_m) \
			or pond_capacity_l <= 0.0:
		return pond_stock_l
	var break_stock := _frac_at_level(eff) * pond_capacity_l
	return maxf(pond_stock_l - break_stock, 0.0)
