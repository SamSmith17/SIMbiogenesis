class_name StreamHydraulics
extends RefCounted

## Open-channel hydraulics for the stream network — pure static, no scene.
##
## Discharge is STEADY STATE and a function of inputs only (base flow, the area
## draining to a point, and the rain rate at the clock's instant), so the flow
## view scrubs backwards and time-lapses like everything else on the world
## clock. Nothing here integrates over time.
##
## Sources:
##   Rational method  Q = C · i · A           (Kuichling 1889; ASCE MOP 77)
##   Manning          Q = (1/n) · A · R^(2/3) · S^(1/2)   (SI form; Chow,
##                    "Open-Channel Hydraulics", 1959, eq. 6-1)
##   Trapezoid        A = (b + z·y)·y,  P = b + 2·y·√(1+z²),  T = b + 2·z·y
##                    (Chow 1959, Table 2-1), z = horizontal : vertical bank.

## Manning roughness for a clean, natural, winding channel with some pools
## (Chow 1959, Table 5-6, "minor streams, clean, winding, some pools": 0.033–
## 0.045; normal 0.040). Culverts use CulvertHydraulics' own n.
const MANNING_N_NATURAL := 0.040
## Rational-method runoff coefficient for undeveloped ground — the ASCE MOP 77
## table gives 0.10–0.25 for lawns / woodland on average soils and 0.30–0.60
## for unimproved steep ground; 0.25 is the middle of the vegetated range.
const RUNOFF_C_DEFAULT := 0.25
## A channel bed is never modelled flatter than this (m/m). The carved profile
## can legitimately go flat (a running minimum), and Manning with S = 0 has no
## solution; 0.0005 is the slope floor commonly used for lowland streams.
const MIN_SLOPE := 0.0005
const MAX_DEPTH_M := 25.0


## Rain-driven runoff (m³/s) from `area_m2` of catchment at `rain_mmh`.
static func runoff_m3s(rain_mmh: float, area_m2: float, c: float = RUNOFF_C_DEFAULT) -> float:
	if rain_mmh <= 0.0 or area_m2 <= 0.0:
		return 0.0
	return clampf(c, 0.0, 1.0) * (rain_mmh / 1000.0 / 3600.0) * area_m2


## Total discharge (L/s) at a point: authored base flow + rain runoff.
static func discharge_lps(base_lps: float, area_m2: float, rain_mmh: float,
		c: float = RUNOFF_C_DEFAULT) -> float:
	return maxf(base_lps, 0.0) + runoff_m3s(rain_mmh, area_m2, c) * 1000.0


## Trapezoid flow area (m²) at depth y.
static func area_m2(b: float, z: float, y: float) -> float:
	return (b + z * y) * y


static func wetted_perimeter_m(b: float, z: float, y: float) -> float:
	return b + 2.0 * y * sqrt(1.0 + z * z)


static func top_width_m(b: float, z: float, y: float) -> float:
	return b + 2.0 * z * y


## Manning discharge (m³/s) of a trapezoid flowing at depth y.
static func manning_q_m3s(b: float, z: float, y: float, slope: float,
		n: float = MANNING_N_NATURAL) -> float:
	if y <= 0.0:
		return 0.0
	var a := area_m2(b, z, y)
	var p := wetted_perimeter_m(b, z, y)
	if p <= 0.0:
		return 0.0
	var r := a / p
	return (1.0 / n) * a * pow(r, 2.0 / 3.0) * sqrt(maxf(slope, MIN_SLOPE))


## Normal depth (m) carrying q_m3s in a trapezoid — Manning's Q(y) is strictly
## increasing in y, so bisection always converges. Returns 0 for no flow.
static func normal_depth_m(q_m3s: float, b: float, z: float, slope: float,
		n: float = MANNING_N_NATURAL) -> float:
	if q_m3s <= 0.0:
		return 0.0
	var bw := maxf(b, 0.05)
	var lo := 0.0
	var flo := -q_m3s
	var hi := 1.0
	var fhi := manning_q_m3s(bw, z, hi, slope, n) - q_m3s
	while fhi < 0.0 and hi < MAX_DEPTH_M:
		lo = hi
		flo = fhi
		hi = minf(hi * 2.0, MAX_DEPTH_M)
		fhi = manning_q_m3s(bw, z, hi, slope, n) - q_m3s
	if fhi < 0.0:
		return hi
	# Illinois (modified regula falsi) on the bracket: Q(y) is smooth and
	# monotone, so it converges in a handful of steps where plain bisection
	# took 48 — this runs at every station of every stream on each re-mesh.
	var side := 0
	for _i in 60:
		var mid := (lo * fhi - hi * flo) / (fhi - flo)
		if not (mid > lo and mid < hi):
			mid = 0.5 * (lo + hi)
		var fm := manning_q_m3s(bw, z, mid, slope, n) - q_m3s
		if absf(fm) <= q_m3s * 1e-7 or hi - lo < 1e-7:
			return mid
		if fm > 0.0:
			hi = mid
			fhi = fm
			if side == 1:
				flo *= 0.5
			side = 1
		else:
			lo = mid
			flo = fm
			if side == -1:
				fhi *= 0.5
			side = -1
	return 0.5 * (lo + hi)


## Everything the renderer and readouts need at one station.
## { q_lps, depth_m, top_w_m, velocity_ms, froude }
static func state(q_lps: float, b: float, z: float, slope: float,
		n: float = MANNING_N_NATURAL) -> Dictionary:
	var q := maxf(q_lps, 0.0) / 1000.0
	var y := normal_depth_m(q, b, z, slope, n)
	var a := area_m2(maxf(b, 0.05), z, y)
	var v := q / a if a > 1e-9 else 0.0
	var t := top_width_m(maxf(b, 0.05), z, y)
	# Froude number on the hydraulic depth A/T (Chow 1959 eq. 3-2): > 1 reads
	# as white water — the renderer foams it.
	var dh := a / t if t > 1e-9 else 0.0
	var fr := v / sqrt(9.80665 * dh) if dh > 1e-9 else 0.0
	return {"q_lps": q * 1000.0, "depth_m": y, "top_w_m": t if y > 0.0 else 0.0,
		"velocity_ms": v, "froude": fr}


# ---------------------------------------------------------------------------
# Bed erosion — the excess-shear-stress model (Partheniades 1965; jet-test
# erodibilities of Hanson & Simon 2001): the bed lowers at
#     ε = k_d · (τ − τc)      for τ > τc,
# τ = ρ g R S the mean bed shear stress. k_d 2e-6 m³/(N·s) and τc 4 Pa sit in
# Hanson & Simon's range for loose, weakly cohesive alluvium — erodible enough
# that a desert wash's floods cut it, firm enough that a trickle does not.
# ---------------------------------------------------------------------------

const ERODE_KD := 2.0e-6
const ERODE_TAU_C_PA := 4.0
const RHO_W := 1000.0
const G := 9.80665


## Mean bed shear stress (Pa) of a trapezoid flowing at depth y on slope S.
static func bed_shear_pa(b: float, z: float, y: float, slope: float) -> float:
	if y <= 0.0:
		return 0.0
	var p := wetted_perimeter_m(maxf(b, 0.05), z, y)
	var r := area_m2(maxf(b, 0.05), z, y) / maxf(p, 1e-6)
	return RHO_W * G * r * maxf(slope, MIN_SLOPE)


## Bed lowering rate (m/s) under shear `tau_pa`.
static func erosion_rate_mps(tau_pa: float) -> float:
	return ERODE_KD * maxf(tau_pa - ERODE_TAU_C_PA, 0.0)
