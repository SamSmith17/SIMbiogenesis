class_name TcReactions
extends RefCounted

## The TC Process Lab's reaction library (Phase 1). Rows are data; a rate
## kind says how a row runs, so a new process is new rows, not new code:
##
##   arrhenius   first order: k = A·exp(−E/RT) (1/s) on the `from` pool
##   evaporation a condensable's p_sat against its partial pressure
##               (TcThermo.p_sat_pa); the stepper limits it by heat
##   vle         ethanol / water by modified Raoult (TcThermo)
##   combustion  complete and O2-limited (TcThermo.O2_PER_MOL), LHV out
##   filter      a capture fraction of entrained fines / mist per pass
##   adsorb      a Langmuir-style capacity of water vapour on a desiccant
##
## Heats `h` are J/kg of the pool reacted, positive = endothermic.
##
## Wood pyrolysis is the three-component scheme of Miller & Bellan 1997
## (Combust. Sci. Tech. 126:97–137), each of cellulose, hemicellulose and
## lignin following Broido–Shafizadeh: virgin → active (k1); active → tar
## (k2) or → X char + (1 − X) gas (k3), with secondary tar cracking in the
## vapour (Liden et al. 1988). Heats from the same paper.

const R := TcSpecies.R

## Miller & Bellan 1997, Table 1: [A k1, E k1, A k2, E k2, A k3, E k3, X].
## A in 1/s, E in J/mol.
const WOOD := {
	"cellulose":     [2.8e19, 242.4e3, 3.28e14, 196.5e3, 1.30e10, 150.5e3, 0.35],
	"hemicellulose": [2.1e16, 186.7e3, 8.75e15, 202.4e3, 2.60e11, 145.7e3, 0.60],
	"lignin":        [9.6e8, 107.6e3, 1.50e9, 143.8e3, 7.70e6, 111.4e3, 0.75],
}
## Heats (J/kg): active formation 0, tar formation +255 kJ/kg (endothermic),
## char formation −20 kJ/kg, tar cracking −42 kJ/kg (Miller & Bellan 1997).
const H_ACTIVE := 0.0
const H_TAR := 255.0e3
const H_CHAR := -20.0e3
const H_CRACK := -42.0e3
## Share of the primary tar that is the light acids of wood vinegar
## (acetic acid is the largest single compound of slow-pyrolysis liquor,
## ~5–15 % of bio-oil, Bridgwater 2012): an estimate.
const TAR_ACID_SHARE := 0.15
## Tar cracking in the vapour (Liden, Berruti & Scott 1988).
const CRACK := [4.28e6, 107.5e3]

## Molar make-up of the char-step volatiles against temperature (K): the
## water of dehydration falls and CO / H2 rise as the bed gets hotter —
## the trend in slow-pyrolysis gas data reviewed by Neves et al. 2011
## (Prog. Energy Combust. Sci. 37:611). Interpolated; an estimate.
const GAS_SPLIT := [
	[673.15, {"H2O": 0.45, "CO2": 0.30, "CO": 0.17, "CH4": 0.05, "H2": 0.03}],
	[873.15, {"H2O": 0.30, "CO2": 0.25, "CO": 0.25, "CH4": 0.12, "H2": 0.08}],
	[1073.15, {"H2O": 0.20, "CO2": 0.18, "CO": 0.30, "CH4": 0.14, "H2": 0.18}],
]
## What cracked tar becomes (mass fractions; Boroson et al. 1989 report
## mostly CO with CH4, CO2 and H2): an estimate.
const CRACK_SPLIT := {"CO": 0.56, "CH4": 0.12, "CO2": 0.17, "H2": 0.02, "H2O": 0.13}

## Plastics, one global first-order step each (estimates: E in the range
## Ceamanos et al. 2002 report for HDPE, A set so half reacts in 30 min at
## the stated temperature). Product mass fractions: wax / oil / light gas.
const PLASTIC := {
	"pe": {"E": 240.0e3, "t_half_c": 450.0, "split": {"wax": 0.50, "oil": 0.35, "C3H6": 0.15}, "h": 1.0e6},
	"pp": {"E": 220.0e3, "t_half_c": 430.0, "split": {"wax": 0.35, "oil": 0.45, "C3H6": 0.20}, "h": 0.9e6},
}

## Filters: capture fraction per pass of [char fines, tar mist] (estimates).
const FILTERS := {
	"inline_strainer": [0.30, 0.02], "y_strainer": [0.30, 0.02], "cartridge_housing": [0.90, 0.60],
	"strainer_basket": [0.50, 0.0],
}

## Silica gel: ~0.35 kg water per kg at high relative humidity (Ng et al.
## 2001, type A gel); Langmuir shape q = q_max·b·RH / (1 + b·RH), b 3.0 (est).
const DESICCANT := {"q_max": 0.35, "b": 3.0, "h_ads": 2800.0e3}


static func arrhenius(A: float, E: float, t_k: float) -> float:
	return A * exp(-E / (R * maxf(t_k, 1.0)))


## Molar fractions of the char-step volatiles at t_k.
static func gas_split_molar(t_k: float) -> Dictionary:
	if t_k <= float(GAS_SPLIT[0][0]):
		return (GAS_SPLIT[0][1] as Dictionary).duplicate()
	for i in range(1, GAS_SPLIT.size()):
		var t1 := float(GAS_SPLIT[i][0])
		if t_k <= t1:
			var t0 := float(GAS_SPLIT[i - 1][0])
			var u := (t_k - t0) / (t1 - t0)
			var a: Dictionary = GAS_SPLIT[i - 1][1]
			var b: Dictionary = GAS_SPLIT[i][1]
			var out := {}
			for k in a.keys():
				out[k] = lerpf(float(a[k]), float(b[k]), u)
			return out
	return (GAS_SPLIT[-1][1] as Dictionary).duplicate()


## The same as mass fractions (sum 1).
static func gas_split_mass(t_k: float) -> Dictionary:
	var x := gas_split_molar(t_k)
	var m := 0.0
	for k in x.keys():
		m += float(x[k]) * float(TcSpecies.row(k)["M"])
	var out := {}
	for k in x.keys():
		out[k] = float(x[k]) * float(TcSpecies.row(k)["M"]) / m
	return out


## A wood cell's state: {cellulose, hemicellulose, lignin, cellulose_a,
## hemicellulose_a, lignin_a, char} (kg). Steps it dt seconds at t_k with
## each first-order pool decayed exactly (stable at any dt) and returns
## {q_j (heat taken, + = absorbed), tar_kg, gas: {species: kg}, char_kg}.
static func wood_step(m: Dictionary, t_k: float, dt: float) -> Dictionary:
	var tar := 0.0
	var gas_kg := 0.0
	var char := 0.0
	var q := 0.0
	for comp in WOOD.keys():
		var p: Array = WOOD[comp]
		var k1 := arrhenius(float(p[0]), float(p[1]), t_k)
		var k2 := arrhenius(float(p[2]), float(p[3]), t_k)
		var k3 := arrhenius(float(p[4]), float(p[5]), t_k)
		var x := float(p[6])
		var akey: String = comp + "_a"
		var v := float(m.get(comp, 0.0))
		var a := float(m.get(akey, 0.0))
		var dv := v * (1.0 - exp(-k1 * dt))
		v -= dv
		a += dv
		var ks := k2 + k3
		var da := a * (1.0 - exp(-ks * dt))
		a -= da
		var to_tar := da * k2 / maxf(ks, 1e-30)
		var to_cg := da - to_tar
		tar += to_tar
		char += to_cg * x
		gas_kg += to_cg * (1.0 - x)
		q += dv * H_ACTIVE + to_tar * H_TAR + to_cg * H_CHAR
		m[comp] = v
		m[akey] = a
	m["char"] = float(m.get("char", 0.0)) + char
	var split := gas_split_mass(t_k)
	var gas := {}
	for k in split.keys():
		gas[k] = gas_kg * float(split[k])
	return {"q_j": q, "tar_kg": tar, "gas": gas, "char_kg": char}


## Tar vapour cracking over dt at t_k: the kg cracked and what it became.
static func tar_crack(tar_kg: float, t_k: float, dt: float) -> Dictionary:
	var k := arrhenius(float(CRACK[0]), float(CRACK[1]), t_k)
	var d := tar_kg * (1.0 - exp(-k * dt))
	var gas := {}
	for s in CRACK_SPLIT.keys():
		gas[s] = d * float(CRACK_SPLIT[s])
	return {"cracked_kg": d, "gas": gas, "q_j": d * H_CRACK}


## A plastic's rate constant (1/s) at t_k.
static func plastic_k(id: String, t_k: float) -> float:
	var r: Dictionary = PLASTIC.get(id, {})
	if r.is_empty():
		return 0.0
	var E := float(r["E"])
	var th := float(r["t_half_c"]) + 273.15
	var A := log(2.0) / 1800.0 * exp(E / (R * th))
	return arrhenius(A, E, t_k)


## Plastic cracking over dt: {reacted_kg, products: {species: kg}, q_j}.
static func plastic_step(id: String, kg: float, t_k: float, dt: float) -> Dictionary:
	var d := kg * (1.0 - exp(-plastic_k(id, t_k) * dt))
	var r: Dictionary = PLASTIC.get(id, {})
	var out := {}
	for s in (r.get("split", {}) as Dictionary).keys():
		out[s] = d * float(r["split"][s])
	return {"reacted_kg": d, "products": out, "q_j": d * float(r.get("h", 0.0))}


## Complete combustion of a composition {species: mol} with o2_mol of
## oxygen available: {burned (mol per fuel), o2_used, co2, h2o, heat_j}.
## Burns every fuel by the same fraction when O2 is short.
static func combust(mols: Dictionary, o2_mol: float) -> Dictionary:
	var need := 0.0
	for k in mols.keys():
		need += float(mols[k]) * float(TcThermo.O2_PER_MOL.get(k, 0.0))
	var f := 1.0 if need <= o2_mol or need <= 0.0 else o2_mol / need
	var co2 := 0.0
	var h2o := 0.0
	var heat := 0.0
	var burned := {}
	for k in mols.keys():
		if not TcThermo.O2_PER_MOL.has(k):
			continue
		var b := float(mols[k]) * f
		burned[k] = b
		co2 += b * float(TcThermo.PRODUCTS[k][0])
		h2o += b * float(TcThermo.PRODUCTS[k][1])
		heat += b * TcSpecies.lhv_j_per_mol(k)
	return {"burned": burned, "o2_used": need * f, "co2": co2, "h2o": h2o, "heat_j": heat}


## Equilibrium water loading (kg/kg) on silica gel at relative humidity rh.
static func desiccant_capacity(rh: float) -> float:
	var b := float(DESICCANT["b"])
	var x := clampf(rh, 0.0, 1.0)
	return float(DESICCANT["q_max"]) * b * x / (1.0 + b * x) * (1.0 + b) / b


static func filter_capture(type: String) -> Array:
	return FILTERS.get(type, [0.0, 0.0])


## The rows the lab's legend and the molecule lens show (what happens
## where): {id, name, kind, equation, where}.
const CATALOG := [
	{"id": "drying", "name": "Drying", "kind": "evaporation", "equation": "H₂O (in the wood) → H₂O (steam)",
		"where": "The charge, from 100 °C at 1 atm"},
	{"id": "boiling", "name": "Boiling", "kind": "evaporation", "equation": "H₂O (liquid) → H₂O (steam)",
		"where": "Any liquid at its boiling point"},
	{"id": "pyrolysis", "name": "Pyrolysis", "kind": "arrhenius",
		"equation": "cellulose / hemicellulose / lignin → tar + char + CO, CO₂, CH₄, H₂, H₂O",
		"where": "The charge, from about 250 °C"},
	{"id": "cracking", "name": "Tar cracking", "kind": "arrhenius", "equation": "tar vapour → CO + CH₄ + CO₂ + H₂",
		"where": "Hot vapour, above about 500 °C"},
	{"id": "condensing", "name": "Condensing", "kind": "evaporation", "equation": "steam, tar, acids → liquid on a cold wall",
		"where": "Cooled walls below the dew point"},
	{"id": "distilling", "name": "Distilling", "kind": "vle", "equation": "ethanol + water → vapour richer in ethanol",
		"where": "A boiling wash"},
	{"id": "depolymerizing", "name": "Depolymerizing", "kind": "arrhenius", "equation": "(C₂H₄)ₙ → wax + oil + C₃H₆",
		"where": "Plastic above about 400 °C"},
	{"id": "burning", "name": "Combustion", "kind": "combustion",
		"equation": "CH₄ + 2 O₂ → CO₂ + 2 H₂O; 2 CO + O₂ → 2 CO₂; 2 H₂ + O₂ → 2 H₂O", "where": "A burner or an engine intake"},
	{"id": "filtering", "name": "Filtering", "kind": "filter", "equation": "fines and mist caught on a screen",
		"where": "Strainers and cartridges"},
	{"id": "drying_gas", "name": "Gas drying", "kind": "adsorb", "equation": "H₂O (vapour) → H₂O on silica gel",
		"where": "A desiccant column"},
]
