class_name PenstockDesign
extends RefCounted

## Design checks for a routed poly penstock — the questions a real install
## asks before buying pipe, answered from the routed run + the live operating
## point. Pure static so the numbers are pinned in conduit_selftest.
##
## Sources (each check names its rule):
##   * PPI Handbook of Polyethylene Pipe, ch. 6 (pressure rating
##     PR = 2·HDS/(DR−1), occasional surge allowance to 2× PR for PE4710) and
##     ch. 7 (minimum long-term cold-bend radius by DR).
##   * Joukowsky surge ΔH = a·Δv/g with the pipe-elastic wave speed
##     a = 1/√(ρ(1/K + D/(E·e))) (Wylie & Streeter, Fluid Transients).
##   * Micro-hydro penstock practice (Harvey, Micro-Hydro Design Manual):
##     friction loss ≤ ~10 % of gross head, flow velocity ≤ ~3 m/s.
##   * A siphon leg over a crest is limited by atmospheric pressure (~10 m)
##     less losses and vapour — ~7–8 m is the practical lift, and any high
##     point collects air unless vented.

const WATER_K_PA := 2.2e9           # bulk modulus of water
const WATER_RHO := 1000.0
const G := 9.80665
const HDPE_E_PA := 1.0e9            # PE4710 short-term modulus (surge), ~150 ksi
const V_MAX_MS := 3.0
const FRICTION_OK_FRAC := 0.10
const FRICTION_WARN_FRAC := 0.20
const SURGE_OCCASIONAL_MULT := 1.5  # PPI allows 2×; keep a margin
const SIPHON_MAX_LIFT_M := 8.0
const HIGH_POINT_MIN_PROMINENCE_M := 0.3


static func pipe_area_m2(id_m: float) -> float:
	return PI * id_m * id_m * 0.25


static func velocity_ms(q_lps: float, id_m: float) -> float:
	var a := pipe_area_m2(id_m)
	return (q_lps / 1000.0) / a if a > 1e-9 else 0.0


## Pressure-wave speed in a water-filled plastic pipe (m/s).
static func wave_speed_ms(id_m: float, wall_m: float, e_pa: float = HDPE_E_PA) -> float:
	if id_m <= 1e-6 or wall_m <= 1e-6:
		return 0.0
	var term := 1.0 / WATER_K_PA + id_m / (e_pa * wall_m)
	return 1.0 / sqrt(WATER_RHO * term)


## Joukowsky head rise (m) for an INSTANT stop from velocity v — the worst
## case; a spear valve or deflector closing over seconds sees far less.
static func surge_head_m(v_ms: float, a_ms: float) -> float:
	return a_ms * v_ms / G


static func psi_to_head_m(psi: float) -> float:
	return psi * 6894.757 / (WATER_RHO * G)


## Critical closure time 2L/a: a valve that closes faster than the pressure
## wave can make the round trip sees the full Joukowsky rise; slower, the
## wave reflects and the rise falls off with the closure time.
static func critical_time_s(length_m: float, a_ms: float) -> float:
	return 2.0 * length_m / maxf(a_ms, 1.0)


## Head rise (m) for a valve closed over `t_close_s`: Joukowsky when the
## closure is faster than 2L/a, else Michaud ΔH = 2·L·v/(g·t) (the slow-
## closure line of the Allievi chart — what micro-hydro practice sizes to;
## Harvey, Micro-Hydro Design Manual, §4.4).
static func surge_head_closure_m(v_ms: float, a_ms: float, length_m: float, t_close_s: float) -> float:
	var instant := surge_head_m(v_ms, a_ms)
	if t_close_s <= critical_time_s(length_m, a_ms) or t_close_s <= 1e-6:
		return instant
	return minf(2.0 * length_m * v_ms / (G * t_close_s), instant)


# -- Intake works -------------------------------------------------------------------
## Settling velocity (m/s) of quartz sand in still water by grain size — the
## micro-hydro design tables (Harvey §3; ≈ Stokes below 0.1 mm, Rubey above).
const SETTLE_TABLE: Dictionary = {0.1: 0.007, 0.2: 0.02, 0.3: 0.03, 0.5: 0.05, 1.0: 0.1}
## Pelton nozzles and runners wear on sand above ~0.3 mm; smaller passes.
const SETTLE_GRAIN_MM := 0.3
## Turbulence factor on the ideal settling area (Camp): real tanks need ~2×.
const SETTLE_SAFETY := 2.0
const SETTLE_FLOW_V_MS := 0.2     # through-flow velocity ceiling in the box
const SETTLE_LW_RATIO := 4.0      # length : width
const SETTLE_MIN_DEPTH_M := 0.3   # + sediment storage under the outlet
## Trash screen: approach velocity and open-area share (ESHA Guide §5.5 —
## 0.3 m/s keeps leaves off a fine screen; 50 % open area for mesh).
const SCREEN_V_MS := 0.3
const SCREEN_OPEN_FRAC := 0.5
## Gordon's submergence S = C·v·√D (SI), C = 1.7 for an asymmetric approach.
const GORDON_C := 1.7


static func settling_velocity_ms(grain_mm: float) -> float:
	var keys: Array = SETTLE_TABLE.keys()
	keys.sort()
	if grain_mm <= float(keys[0]):
		return float(SETTLE_TABLE[keys[0]])
	for i in range(1, keys.size()):
		var k1 := float(keys[i])
		if grain_mm <= k1:
			var k0 := float(keys[i - 1])
			var t := (grain_mm - k0) / (k1 - k0)
			return lerpf(float(SETTLE_TABLE[k0]), float(SETTLE_TABLE[k1]), t)
	return float(SETTLE_TABLE[keys[keys.size() - 1]])


## Size the intake works for a DESIGN flow (the most the nozzle will take):
## {screen_area_m2, screen_side_m, settle_area_m2, settle_len_m, settle_w_m,
##  settle_depth_m, settle_time_s, submergence_m, pipe_v_ms}.
static func intake_works(q_design_lps: float, pipe_id_m: float,
		grain_mm: float = SETTLE_GRAIN_MM) -> Dictionary:
	var q := maxf(q_design_lps, 0.0) / 1000.0
	var screen_a := q / (SCREEN_V_MS * SCREEN_OPEN_FRAC)
	var w_s := settling_velocity_ms(grain_mm)
	var settle_a := SETTLE_SAFETY * q / w_s
	var width := sqrt(settle_a / SETTLE_LW_RATIO)
	var length := width * SETTLE_LW_RATIO
	var depth := maxf(SETTLE_MIN_DEPTH_M, q / (SETTLE_FLOW_V_MS * maxf(width, 1e-3)))
	var v_pipe := velocity_ms(q_design_lps, pipe_id_m)
	return {
		"screen_area_m2": screen_a,
		"screen_side_m": sqrt(screen_a),
		"settle_area_m2": settle_a,
		"settle_len_m": length,
		"settle_w_m": width,
		"settle_depth_m": depth,
		"settle_time_s": (length * width * depth) / maxf(q, 1e-9),
		"submergence_m": GORDON_C * v_pipe * sqrt(maxf(pipe_id_m, 0.0)),
		"pipe_v_ms": v_pipe,
		"grain_mm": grain_mm,
	}


# -- Firm flow ----------------------------------------------------------------------
## The year the nozzle actually sees: driest / wettest month, the share of
## months the stream runs below the nozzle's demand, and the nozzle that
## would run unlimited in the driest month. `monthly_kw` is the same month's
## output (12 entries, from the annual estimate); `nozzle_q_lps` the jet's
## demand at the design head (NAN = unknown).
static func firm_flow(monthly_supply_lps: Array, monthly_kw: Array,
		nozzle_q_lps: float = NAN) -> Dictionary:
	if monthly_supply_lps.size() != 12:
		return {}
	var lo_i := 0
	var hi_i := 0
	for i in 12:
		if float(monthly_supply_lps[i]) < float(monthly_supply_lps[lo_i]):
			lo_i = i
		if float(monthly_supply_lps[i]) > float(monthly_supply_lps[hi_i]):
			hi_i = i
	var limited := 0
	if not is_nan(nozzle_q_lps):
		for i in 12:
			if float(monthly_supply_lps[i]) < nozzle_q_lps - 1e-6:
				limited += 1
	return {
		"min_month": lo_i, "min_lps": float(monthly_supply_lps[lo_i]),
		"min_kw": float(monthly_kw[lo_i]) if monthly_kw.size() == 12 else NAN,
		"max_month": hi_i, "max_lps": float(monthly_supply_lps[hi_i]),
		"max_kw": float(monthly_kw[hi_i]) if monthly_kw.size() == 12 else NAN,
		"limited_months": limited,
	}


const MONTH_ABBR: Array = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


## Run every check. `d` keys (all optional, missing = check skipped):
##   q_lps, gross_head_m, head_loss_m, id_m, od_m, sdr, wall_m,
##   length_m, stock_m, rating_psi, min_bend_r_m, route_min_bend_r_m,
##   high_points, rise_above_intake_m.
## Returns [{key, level ("ok"|"warn"|"fail"|"info"), text}] in display order.
static func checks(d: Dictionary) -> Array:
	var out: Array = []
	var q := float(d.get("q_lps", NAN))
	var id_m := float(d.get("id_m", NAN))
	var gross := float(d.get("gross_head_m", NAN))
	var h_f := float(d.get("head_loss_m", NAN))
	var rating_psi := float(d.get("rating_psi", NAN))
	var rating_m := psi_to_head_m(rating_psi) if not is_nan(rating_psi) else NAN
	# Velocity.
	var v := NAN
	if not (is_nan(q) or is_nan(id_m)) and id_m > 0.0:
		v = velocity_ms(q, id_m)
		var lvl := "ok" if v <= V_MAX_MS else ("warn" if v <= V_MAX_MS * 1.5 else "fail")
		out.append({"key": "velocity", "level": lvl,
			"text": "Flow velocity %.2f m/s (keep ≤ %.0f m/s)" % [v, V_MAX_MS]})
	# Friction share of gross head.
	if not (is_nan(gross) or is_nan(h_f)) and gross > 0.05:
		var frac := h_f / gross
		var lvl2 := "ok" if frac <= FRICTION_OK_FRAC else ("warn" if frac <= FRICTION_WARN_FRAC else "fail")
		out.append({"key": "friction", "level": lvl2,
			"text": "Friction loss %.1f m = %.0f %% of %.1f m gross (aim ≤ %.0f %%)" % [
				h_f, frac * 100.0, gross, FRICTION_OK_FRAC * 100.0]})
	# Static pressure vs rating.
	if not (is_nan(gross) or is_nan(rating_m)):
		var lvl3 := "ok" if gross <= rating_m else "fail"
		out.append({"key": "static", "level": lvl3,
			"text": "Static head %.1f m vs pipe rating %.0f m (%.0f psi, SDR %s)" % [
				gross, rating_m, rating_psi, _fmt_sdr(float(d.get("sdr", NAN)))]})
	# Surge: for the valve closure time when known (Michaud / Allievi slow
	# line), with the instant-stop Joukowsky figure beside it.
	var wall := float(d.get("wall_m", NAN))
	var run_m := float(d.get("length_m", NAN))
	var close_s := float(d.get("close_s", NAN))
	if not (is_nan(v) or is_nan(wall) or is_nan(id_m)) and v > 0.0:
		var a := wave_speed_ms(id_m, wall)
		var instant := surge_head_m(v, a)
		var dh := instant
		var text := ""
		if not is_nan(close_s) and close_s > 0.0 and not is_nan(run_m) and run_m > 0.0:
			dh = surge_head_closure_m(v, a, run_m, close_s)
			text = "Surge closing the valve over %.0f s: +%.1f m (instant stop would be +%.0f m; 2L/a = %.1f s)" % [
				close_s, dh, instant, critical_time_s(run_m, a)]
		else:
			text = "Surge on an instant stop +%.0f m (wave %.0f m/s)" % [dh, a]
		var lvl4 := "info"
		if not (is_nan(gross) or is_nan(rating_m)):
			var total := gross + dh
			lvl4 = "ok" if total <= rating_m else ("warn" if total <= rating_m * SURGE_OCCASIONAL_MULT else "fail")
			text += " → %.0f m total vs %.0f m rating" % [total, rating_m]
			if lvl4 != "ok":
				text += " — close the spear / deflector slowly, never a ball valve"
		out.append({"key": "surge", "level": lvl4, "text": text})
	# Bends.
	var r_min := float(d.get("min_bend_r_m", NAN))
	var r_route := float(d.get("route_min_bend_r_m", NAN))
	if not is_nan(r_min):
		if is_nan(r_route) or r_route <= 0.0:
			out.append({"key": "bend", "level": "info",
				"text": "Min cold-bend radius %.2f m (%s× OD)" % [r_min, _fmt_sdr(float(d.get("bend_mult", NAN)))]})
		else:
			var ok_b := r_route >= r_min * 0.98
			out.append({"key": "bend", "level": "ok" if ok_b else "warn",
				"text": "Tightest bend on the route %.1f m (pipe needs ≥ %.2f m%s)" % [
					r_route, r_min, "" if ok_b else " — add a waypoint or an elbow fitting there"]})
	# Air / siphon.
	var hp := int(d.get("high_points", -1))
	var rise := float(d.get("rise_above_intake_m", NAN))
	if hp >= 0:
		if hp == 0:
			out.append({"key": "air", "level": "ok", "text": "No high points — the run drains and fills freely"})
		else:
			out.append({"key": "air", "level": "warn",
				"text": "%d high point%s on the run — fit an air-release valve at each, or re-route" % [
					hp, "" if hp == 1 else "s"]})
	if not is_nan(rise) and rise > 0.05:
		out.append({"key": "siphon", "level": "warn" if rise <= SIPHON_MAX_LIFT_M else "fail",
			"text": "Pipe climbs %.1f m above the intake — a siphon leg that must be primed%s" % [
				rise, "" if rise <= SIPHON_MAX_LIFT_M else " (over the ~8 m a siphon can lift)"]})
	# Stock.
	var run := float(d.get("length_m", NAN))
	var stock := float(d.get("stock_m", NAN))
	if not is_nan(run) and not is_nan(stock) and stock > 0.0:
		var over := run - stock
		out.append({"key": "stock", "level": "ok" if over <= 0.0 else "fail",
			"text": "Run %.0f m (%.0f ft) vs %.0f m (%.0f ft) on hand%s" % [
				run, run / 0.3048, stock, stock / 0.3048,
				(" — %.0f m (%.0f ft) spare" % [-over, -over / 0.3048]) if over <= 0.0
				else (" — SHORT by %.0f m (%.0f ft)" % [over, over / 0.3048])]})
	return out


static func _fmt_sdr(v: float) -> String:
	if is_nan(v):
		return "?"
	return ("%.1f" % v).trim_suffix(".0")


static func worst_level(cks: Array) -> String:
	var rank := {"info": 0, "ok": 0, "warn": 1, "fail": 2}
	var worst := 0
	for c in cks:
		worst = maxi(worst, int(rank.get(str((c as Dictionary).get("level", "ok")), 0)))
	return ["ok", "warn", "fail"][worst]


## Plain-text design summary (the clipboard export).
static func summary_text(title: String, lines: Array, cks: Array) -> String:
	var out := [title, "=".repeat(title.length())]
	for l in lines:
		out.append(str(l))
	out.append("")
	out.append("Design checks")
	for c in cks:
		var cd: Dictionary = c
		var mark: String = str({"ok": "[ok]  ", "warn": "[!]   ", "fail": "[FAIL]", "info": "[i]   "}.get(str(cd.get("level", "")), "      "))
		out.append("%s %s" % [mark, str(cd.get("text", ""))])
	return "\n".join(out)
