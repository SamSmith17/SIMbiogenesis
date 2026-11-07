class_name TcThermo
extends RefCounted

## Thermodynamics and heat transfer for the TC Process Lab (Phase 1).
## Pure static helpers over TcSpecies; SI units unless a name says
## otherwise (T in K for the physics, °C only where a name says _c).

const R := TcSpecies.R
const P_ATM := TcSpecies.P_ATM
const G := 9.80665
const SIGMA := 5.670374419e-8   # Stefan–Boltzmann, W/m²·K⁴ (CODATA 2018)


# ---------------------------------------------------------------------------
# Ideal gas
# ---------------------------------------------------------------------------

## p = nRT / V (Pa).
static func pressure_pa(n_mol: float, t_k: float, v_m3: float) -> float:
	return n_mol * R * t_k / maxf(v_m3, 1e-9)


## n = pV / RT (mol).
static func moles(p_pa: float, v_m3: float, t_k: float) -> float:
	return p_pa * v_m3 / (R * maxf(t_k, 1.0))


# ---------------------------------------------------------------------------
# Vapour pressure
# ---------------------------------------------------------------------------

## Saturation pressure (Pa) of a condensable species at t_k. Antoine where
## the species has it (the nearest range outside it), else Clausius–
## Clapeyron through its boiling point: ln(P/P_atm) = −ΔHvap/R (1/T − 1/Tb).
## 0 for a permanent gas.
static func p_sat_pa(id: String, t_k: float) -> float:
	var r := TcSpecies.row(id)
	var tc := t_k - 273.15
	if r.has("antoine"):
		var rows: Array = r["antoine"]
		var best: Dictionary = rows[0]
		for a in rows:
			if tc >= float(a["t0"]) and tc <= float(a["t1"]):
				best = a
				break
			if tc > float(a["t1"]):
				best = a
		var lg := float(best["a"]) - float(best["b"]) / (float(best["c"]) + tc)
		return pow(10.0, lg) * TcSpecies.MMHG_PA
	if r.has("cc"):
		var cc: Dictionary = r["cc"]
		var tb := float(cc["tb_c"]) + 273.15
		return P_ATM * exp(-float(cc["h_vap"]) / R * (1.0 / maxf(t_k, 1.0) - 1.0 / tb))
	return 0.0


## Boiling point (K) at pressure p_pa: the inverse of p_sat (bisection on
## the monotone curve, 200–900 K).
static func boiling_point_k(id: String, p_pa: float) -> float:
	var lo := 200.0
	var hi := 900.0
	if p_sat_pa(id, hi) < p_pa:
		return hi
	for _i in 60:
		var m := (lo + hi) * 0.5
		if p_sat_pa(id, m) < p_pa:
			lo = m
		else:
			hi = m
	return (lo + hi) * 0.5


## Dew point (K) of a species at partial pressure pp_pa (where it starts to
## condense on a cold wall).
static func dew_point_k(id: String, pp_pa: float) -> float:
	return boiling_point_k(id, maxf(pp_pa, 1.0))


# ---------------------------------------------------------------------------
# Ethanol / water VLE (the pot still)
# ---------------------------------------------------------------------------

## Wilson parameters for ethanol (1) / water (2): energy terms (λ12 − λ11,
## λ21 − λ22) in J/mol and the liquid molar volumes (cm³/mol). Fitted here
## so the model reproduces the 1 atm azeotrope (0.894 mole fraction
## ethanol at 78.15 °C) and the classic x–y curve to a few percent; they sit
## in the range DECHEMA lists for the system (estimate).
const WILSON := {"a12": 1600.0, "a21": 4000.0, "v1": 58.68, "v2": 18.07}


## Activity coefficients [γ1, γ2] of ethanol and water at x1 (ethanol
## mole fraction in the liquid), t_k (Wilson 1964).
static func wilson_gamma(x1: float, t_k: float) -> Array:
	var x2 := 1.0 - x1
	var l12 := float(WILSON["v2"]) / float(WILSON["v1"]) * exp(-float(WILSON["a12"]) / (R * t_k))
	var l21 := float(WILSON["v1"]) / float(WILSON["v2"]) * exp(-float(WILSON["a21"]) / (R * t_k))
	var d1 := x1 + l12 * x2
	var d2 := x2 + l21 * x1
	var t := l12 / maxf(d1, 1e-12) - l21 / maxf(d2, 1e-12)
	var g1 := exp(-log(maxf(d1, 1e-12)) + x2 * t)
	var g2 := exp(-log(maxf(d2, 1e-12)) - x1 * t)
	return [g1, g2]


## Bubble point of an ethanol / water liquid at p_pa: {t_k, y1 (vapour
## ethanol mole fraction)} by modified Raoult (yᵢP = xᵢγᵢPᵢsat).
static func ethanol_water_bubble(x1: float, p_pa: float = P_ATM) -> Dictionary:
	var lo := 330.0
	var hi := 380.0
	var y1 := 0.0
	for _i in 50:
		var t := (lo + hi) * 0.5
		var g := wilson_gamma(x1, t)
		var p1 := x1 * float(g[0]) * p_sat_pa("ethanol", t)
		var p2 := (1.0 - x1) * float(g[1]) * p_sat_pa("H2O", t)
		if p1 + p2 < p_pa:
			lo = t
		else:
			hi = t
		y1 = p1 / maxf(p1 + p2, 1e-9)
	return {"t_k": (lo + hi) * 0.5, "y1": y1}


# ---------------------------------------------------------------------------
# Mixtures
# ---------------------------------------------------------------------------

## Mixture molar cp (J/mol·K) of a gas composition {id: mol}.
static func mix_cp_molar(mols: Dictionary) -> float:
	var n := 0.0
	var c := 0.0
	for k in mols.keys():
		var m := float(mols[k])
		n += m
		c += m * float(TcSpecies.row(k).get("cp_g", 29.1))
	return c / n if n > 0.0 else 29.1


## Gas density (kg/m³) of a composition at p, T.
static func mix_density(mols: Dictionary, p_pa: float, t_k: float) -> float:
	var n := 0.0
	var m := 0.0
	for k in mols.keys():
		n += float(mols[k])
		m += float(mols[k]) * TcSpecies.molar_mass_kg(k)
	var mm := m / n if n > 0.0 else 0.029
	return p_pa * mm / (R * maxf(t_k, 1.0))


## Lower heating value of a gas composition per normal m³ (MJ/Nm³, 0 °C,
## 1 atm: 22.414 L/mol) — the woodgas number the genset reads.
static func lhv_mj_per_nm3(mols: Dictionary) -> float:
	var n := 0.0
	var e := 0.0
	for k in mols.keys():
		n += float(mols[k])
		e += float(mols[k]) * TcSpecies.lhv_j_per_mol(k)
	if n <= 0.0:
		return 0.0
	return e / n / 0.022414 * 1e-6


# ---------------------------------------------------------------------------
# Heat transfer
# ---------------------------------------------------------------------------

## Air near 350 K (Incropera, Table A.4): k 0.030 W/m·K, ν 2.09e-5 m²/s,
## Pr 0.70. Gas mixtures in the lab use these (an estimate for woodgas).
const AIR := {"k": 0.030, "nu": 2.09e-5, "pr": 0.70}

## Saturated liquid water near 350 K (Incropera, Table A.6).
const WATER_L := {"k": 0.668, "mu": 3.65e-4, "rho": 974.0}


## Natural convection h (W/m²·K) on a surface of height / diameter L,
## ΔT = |Ts − T∞|, film temperature t_f. Churchill & Chu (1975): vertical
## plate, or a horizontal cylinder when `cylinder`.
static func h_natural(L: float, dt: float, t_f: float, cylinder: bool = false) -> float:
	var k := float(AIR["k"])
	var nu := float(AIR["nu"])
	var pr := float(AIR["pr"])
	var ra := G * (1.0 / maxf(t_f, 200.0)) * absf(dt) * pow(maxf(L, 1e-3), 3.0) / (nu * nu) * pr
	var nusselt := 0.0
	if cylinder:
		nusselt = pow(0.60 + 0.387 * pow(ra, 1.0 / 6.0) / pow(1.0 + pow(0.559 / pr, 9.0 / 16.0), 8.0 / 27.0), 2.0)
	else:
		nusselt = pow(0.825 + 0.387 * pow(ra, 1.0 / 6.0) / pow(1.0 + pow(0.492 / pr, 9.0 / 16.0), 8.0 / 27.0), 2.0)
	return nusselt * k / maxf(L, 1e-3)


## Laminar film condensation h (W/m²·K) on a vertical wall of height L
## (Nusselt 1916, with the 0.943 coefficient): steam onto a wall dt below
## saturation.
static func h_condensing(L: float, dt: float, h_fg: float = WaterSteam.H_FG_KJ_PER_KG * 1000.0) -> float:
	var kl := float(WATER_L["k"])
	var mu := float(WATER_L["mu"])
	var rho := float(WATER_L["rho"])
	return 0.943 * pow(rho * rho * G * h_fg * pow(kl, 3.0) / (mu * maxf(L, 0.01) * maxf(dt, 0.1)), 0.25)


## Radiation between a surface at t_k and surroundings at t_amb_k (W/m²).
static func q_radiation(t_k: float, t_amb_k: float, emissivity: float) -> float:
	return emissivity * SIGMA * (pow(t_k, 4.0) - pow(t_amb_k, 4.0))


# ---------------------------------------------------------------------------
# Combustion
# ---------------------------------------------------------------------------

## Stoichiometric O2 (mol) per mol of fuel species, complete combustion.
const O2_PER_MOL := {"CO": 0.5, "H2": 0.5, "CH4": 2.0, "C3H6": 4.5, "tar": 6.0, "acetic": 2.0,
	"ethanol": 3.0, "oil": 18.5, "wax": 38.0}
## Products per mol of fuel: [CO2, H2O].
const PRODUCTS := {"CO": [1.0, 0.0], "H2": [0.0, 1.0], "CH4": [1.0, 2.0], "C3H6": [3.0, 3.0],
	"tar": [6.0, 5.0], "acetic": [2.0, 2.0], "ethanol": [2.0, 3.0], "oil": [12.0, 13.0], "wax": [25.0, 26.0]}


## Air (mol) for complete combustion of a composition (air = 20.95 % O2).
static func stoich_air_mol(mols: Dictionary) -> float:
	var o2 := 0.0
	for k in mols.keys():
		o2 += float(mols[k]) * float(O2_PER_MOL.get(k, 0.0))
	return o2 / 0.2095


## Mean cp of combustion products over 298–2000 K (J/mol·K): the JANAF
## enthalpy rises H°(2000) − H°(298) of 91.44 (CO2), 72.79 (H2O), 56.14 (N2)
## and 59.20 (O2) kJ/mol over 1702 K.
const CP_HOT := {"CO2": 53.72, "H2O": 42.77, "N2": 32.98, "O2": 34.78}


## Adiabatic flame temperature (K) of a fuel composition burned with
## `excess` extra air (0 = stoichiometric) from t0_k: the heat released
## (LHV) all goes into the products' sensible heat at their mean cp.
## Dissociation is ignored, so it reads ~100 K high near 2200 K.
static func adiabatic_flame_k(mols: Dictionary, excess: float = 0.0, t0_k: float = 298.15) -> float:
	var q := 0.0
	var prod := {"CO2": 0.0, "H2O": 0.0, "N2": 0.0, "O2": 0.0}
	var o2 := 0.0
	for k in mols.keys():
		var m := float(mols[k])
		q += m * TcSpecies.lhv_j_per_mol(k)
		o2 += m * float(O2_PER_MOL.get(k, 0.0))
		if PRODUCTS.has(k):
			prod["CO2"] = float(prod["CO2"]) + m * float(PRODUCTS[k][0])
			prod["H2O"] = float(prod["H2O"]) + m * float(PRODUCTS[k][1])
		elif k in ["CO2", "H2O", "N2"]:
			prod[k] = float(prod[k]) + m
	var air_o2 := o2 * (1.0 + excess)
	prod["O2"] = air_o2 - o2
	prod["N2"] = float(prod["N2"]) + air_o2 * 0.7905 / 0.2095
	var cp := 0.0
	for k in prod.keys():
		cp += float(prod[k]) * float(CP_HOT.get(k, 33.0))
	return t0_k + q / maxf(cp, 1e-9)
