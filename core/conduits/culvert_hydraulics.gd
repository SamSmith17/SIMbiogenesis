class_name CulvertHydraulics
extends RefCounted

## Free-surface stage-discharge for corrugated PE overflow culverts.
## Inlet weir/orifice → barrel Manning capacity cap. Pure static (selftested).

const WATER_DENSITY := 1000.0
const G := 9.80665
## Dual-wall HDPE Manning n (manufacturer range ~0.010–0.013).
const DEFAULT_MANNING_N := 0.012
## Inlet discharge coefficient (orifice / weir-into-barrel).
const CD_ORIFICE := 0.62
const CD_WEIR := 0.55


## Stage-discharge for one culvert at a pond water-surface elevation.
## Returns `{q_lps, q_m3s, velocity_mps, head_m, pe_kw, regime, fill_frac}`.
static func stage_discharge(
		pond_level_m: float,
		invert_in_m: float,
		invert_out_m: float,
		diameter_m: float,
		length_m: float,
		manning_n: float = DEFAULT_MANNING_N) -> Dictionary:
	var out := {
		"q_lps": 0.0,
		"q_m3s": 0.0,
		"velocity_mps": 0.0,
		"head_m": 0.0,
		"pe_kw": 0.0,
		"regime": "dry",
		"fill_frac": 0.0,
	}
	var d := maxf(diameter_m, 0.01)
	var L := maxf(length_m, 0.5)
	var n := maxf(manning_n, 0.008)
	var d_over := pond_level_m - invert_in_m
	if d_over <= 1e-4:
		return out
	var head_out := pond_level_m - invert_out_m
	# Gravity gate: a culvert daylights downhill. If the outlet invert sits at or
	# above the pond water surface, there is no head to push water out — it can't
	# flow uphill. Without this the weir branch (which ignores the outlet
	# elevation) and the orifice branch (which clamps a negative head up to a
	# positive drive) would both keep discharging, draining the pond uphill.
	if head_out <= 1e-4:
		return out
	out["head_m"] = maxf(head_out, 0.0)
	var area_full := PI * d * d * 0.25
	var fill := clampf(d_over / d, 0.0, 1.0)
	out["fill_frac"] = fill
	var q := 0.0
	var regime := "weir"
	if d_over < d:
		# Partial inlet: circular-segment orifice / weir into barrel.
		var a_seg := circular_segment_area(d * 0.5, d_over)
		q = CD_WEIR * a_seg * sqrt(2.0 * G * d_over)
		regime = "weir"
	else:
		# Submerged inlet — orifice on full area driven by outlet head,
		# capped by Manning full-barrel capacity.
		var h_drive := maxf(head_out, d_over * 0.25)
		q = CD_ORIFICE * area_full * sqrt(2.0 * G * h_drive)
		regime = "orifice"
	var slope := maxf((invert_in_m - invert_out_m) / L, 1e-5)
	var q_manning := manning_full_m3s(d, slope, n)
	if q > q_manning:
		q = q_manning
		regime = "manning"
	out["q_m3s"] = q
	out["q_lps"] = q * 1000.0
	out["regime"] = regime
	var a_flow := area_full * clampf(fill, 0.15, 1.0)
	out["velocity_mps"] = q / maxf(a_flow, 1e-6)
	# Potential energy rate of the falling water (before turbine η).
	out["pe_kw"] = WATER_DENSITY * G * q * maxf(head_out, 0.0) / 1000.0
	return out


## Aggregate N culverts on one pond (stepped bank / multi-outlet).
static func stage_discharge_bank(pond_level_m: float, culverts: Array) -> Dictionary:
	var total_q := 0.0
	var total_pe := 0.0
	var open_n := 0
	var details: Array = []
	for c in culverts:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = c
		var r := stage_discharge(
			pond_level_m,
			float(cd.get("invert_in_m", 0.0)),
			float(cd.get("invert_out_m", 0.0)),
			float(cd.get("diameter_m", 0.203)),
			float(cd.get("length_m", 15.0)),
			float(cd.get("manning_n", DEFAULT_MANNING_N)))
		details.append(r)
		total_q += float(r.get("q_m3s", 0.0))
		total_pe += float(r.get("pe_kw", 0.0))
		if float(r.get("q_m3s", 0.0)) > 1e-8:
			open_n += 1
	return {
		"q_m3s": total_q,
		"q_lps": total_q * 1000.0,
		"q_lph": total_q * 1000.0 * 3600.0,
		"pe_kw": total_pe,
		"open_count": open_n,
		"details": details,
	}


## Full-pipe Manning: Q = (1/n)·A·R^(2/3)·S^(1/2), R = D/4.
static func manning_full_m3s(diameter_m: float, slope: float, manning_n: float) -> float:
	var d := maxf(diameter_m, 0.01)
	var n := maxf(manning_n, 0.008)
	var a := PI * d * d * 0.25
	var r_h := d * 0.25
	return (1.0 / n) * a * pow(r_h, 2.0 / 3.0) * sqrt(maxf(slope, 1e-8))


## Area of a circular segment of height h in a circle of radius r.
static func circular_segment_area(radius: float, height: float) -> float:
	var r := maxf(radius, 1e-6)
	var h := clampf(height, 0.0, 2.0 * r)
	if h <= 1e-8:
		return 0.0
	if h >= 2.0 * r - 1e-8:
		return PI * r * r
	# θ = 2·acos((r−h)/r)
	var arg := clampf((r - h) / r, -1.0, 1.0)
	var theta := 2.0 * acos(arg)
	return 0.5 * r * r * (theta - sin(theta))


## Nominal PE culvert ID (m) from size inches (approx = size for dual-wall).
static func diameter_m_from_size_in(size_in: float) -> float:
	return maxf(size_in, 1.0) * 0.0254


## Pull hydraulics fields from a graph connection (+ kind meta fallback).
static func specs_from_connection(conn: Dictionary, meta: Dictionary = {}) -> Dictionary:
	var size_in := float(conn.get("pipe_size_in", meta.get("default_pipe_size_in", 8.0)))
	var d := float(conn.get("diameter_m", meta.get("inner_diameter_m",
			diameter_m_from_size_in(size_in))))
	var length := float(conn.get("route_length_m", conn.get("estimated_length",
			conn.get("length_m", 15.0))))
	return {
		"invert_in_m": float(conn.get("invert_in_m", NAN)),
		"invert_out_m": float(conn.get("invert_out_m", NAN)),
		"diameter_m": d,
		"length_m": maxf(length, 0.5),
		"manning_n": float(conn.get("manning_n", DEFAULT_MANNING_N)),
		"inlet_pond_tag": str(conn.get("inlet_pond_tag", "")),
		"pipe_size_in": size_in,
	}
