class_name TcSpecies
extends RefCounted

## The chemical species the TC Process Lab tracks (Phase 1). Pure data;
## every number carries its source in the comment beside its row, and rows
## that are estimates say so (`est: true`, listed by `estimates()`).
##
## Units: molar mass M g/mol; cp_g / cp_l J/mol·K (gas at 500 K from the
## NIST WebBook Shomate fits, liquid at 25–100 °C); h_vap J/mol at the
## normal boiling point; LHV J/mol (water vapour product); rho_l kg/m³.
## Vapour pressure is either Antoine {a, b, c} (log10 P[mmHg] = a − b /
## (c + T[°C]), with its T range) or Clausius–Clapeyron from {tb_c, h_vap}.
##
## Solids (the charge) use J/kg·K and are tracked by mass, not moles.
##
## `mol` is the molecule for the ball-and-stick lens: atoms [[element,
## Vector3 Å]] and bonds [[i, j, order]]. Polymers carry a short repeating
## unit (`unit`), drawn as a chain.

const R := 8.314462618          # J/mol·K (CODATA 2018)
const P_ATM := 101325.0         # Pa
const MMHG_PA := 133.322368     # Pa per mmHg

## CPK-style atom colours and van der Waals-ish display radii (Å).
const ATOMS := {
	"H": {"color": Color(0.95, 0.95, 0.95), "r": 0.31, "name": "hydrogen"},
	"C": {"color": Color(0.25, 0.25, 0.27), "r": 0.70, "name": "carbon"},
	"N": {"color": Color(0.20, 0.35, 0.95), "r": 0.65, "name": "nitrogen"},
	"O": {"color": Color(0.95, 0.15, 0.12), "r": 0.60, "name": "oxygen"},
	"Si": {"color": Color(0.85, 0.70, 0.45), "r": 1.10, "name": "silicon"},
}

const GASES := ["H2O", "CO", "CO2", "H2", "CH4", "N2", "O2", "C3H6", "tar", "acetic", "ethanol", "oil", "wax"]
const SOLIDS := ["cellulose", "hemicellulose", "lignin", "moisture", "char", "ash", "desiccant", "pe", "pp"]

const DATA := {
	# --- permanent gases ---------------------------------------------------
	"H2O": {"name": "Water", "formula": "H₂O", "M": 18.015, "cp_g": 35.2, "cp_l": 75.3, "rho_l": 958.0,
		# Antoine, two ranges (NIST / Lange's Handbook): 1–100 °C and 99–374 °C.
		"antoine": [{"a": 8.07131, "b": 1730.63, "c": 233.426, "t0": 1.0, "t1": 100.0},
			{"a": 8.14019, "b": 1810.94, "c": 244.485, "t0": 99.0, "t1": 374.0}],
		"h_vap": 40660.0, "lhv": 0.0, "color": Color(0.92, 0.95, 1.0), "role": "steam",
		"mol": {"atoms": [["O", Vector3(0, 0, 0)], ["H", Vector3(0.757, 0.586, 0)], ["H", Vector3(-0.757, 0.586, 0)]],
			"bonds": [[0, 1, 1], [0, 2, 1]]}},
	"CO": {"name": "Carbon monoxide", "formula": "CO", "M": 28.010, "cp_g": 29.8, "lhv": 283.0e3,
		"color": Color(0.85, 0.80, 0.55), "role": "fuel",
		"mol": {"atoms": [["C", Vector3(-0.564, 0, 0)], ["O", Vector3(0.564, 0, 0)]], "bonds": [[0, 1, 3]]}},
	"CO2": {"name": "Carbon dioxide", "formula": "CO₂", "M": 44.009, "cp_g": 44.6, "lhv": 0.0,
		"color": Color(0.80, 0.82, 0.85), "role": "inert",
		"mol": {"atoms": [["C", Vector3.ZERO], ["O", Vector3(1.16, 0, 0)], ["O", Vector3(-1.16, 0, 0)]],
			"bonds": [[0, 1, 2], [0, 2, 2]]}},
	"H2": {"name": "Hydrogen", "formula": "H₂", "M": 2.016, "cp_g": 29.3, "lhv": 241.8e3,
		"color": Color(0.95, 0.85, 0.65), "role": "fuel",
		"mol": {"atoms": [["H", Vector3(-0.37, 0, 0)], ["H", Vector3(0.37, 0, 0)]], "bonds": [[0, 1, 1]]}},
	"CH4": {"name": "Methane", "formula": "CH₄", "M": 16.043, "cp_g": 46.3, "lhv": 802.3e3,
		"color": Color(0.90, 0.75, 0.45), "role": "fuel",
		"mol": {"atoms": [["C", Vector3.ZERO], ["H", Vector3(0.629, 0.629, 0.629)], ["H", Vector3(-0.629, -0.629, 0.629)],
			["H", Vector3(-0.629, 0.629, -0.629)], ["H", Vector3(0.629, -0.629, -0.629)]],
			"bonds": [[0, 1, 1], [0, 2, 1], [0, 3, 1], [0, 4, 1]]}},
	"N2": {"name": "Nitrogen", "formula": "N₂", "M": 28.013, "cp_g": 29.6, "lhv": 0.0,
		"color": Color(0.75, 0.80, 0.95), "role": "inert",
		"mol": {"atoms": [["N", Vector3(-0.55, 0, 0)], ["N", Vector3(0.55, 0, 0)]], "bonds": [[0, 1, 3]]}},
	"O2": {"name": "Oxygen", "formula": "O₂", "M": 31.999, "cp_g": 31.1, "lhv": 0.0,
		"color": Color(0.70, 0.85, 1.0), "role": "oxidiser",
		"mol": {"atoms": [["O", Vector3(-0.60, 0, 0)], ["O", Vector3(0.60, 0, 0)]], "bonds": [[0, 1, 2]]}},
	# Propylene, the light-hydrocarbon surrogate for plastic cracking gas.
	# LHV 45.8 MJ/kg (Engineering Toolbox / NIST ΔcH − water).
	"C3H6": {"name": "Light hydrocarbons", "formula": "C₃H₆", "M": 42.081, "cp_g": 85.0, "lhv": 1927.0e3,
		"color": Color(0.85, 0.70, 0.45), "role": "fuel",
		"mol": {"atoms": [["C", Vector3(-1.25, 0, 0)], ["C", Vector3(0, 0.45, 0)], ["C", Vector3(1.28, -0.3, 0)],
			["H", Vector3(-2.1, 0.6, 0)], ["H", Vector3(-1.3, -1.05, 0)], ["H", Vector3(0.05, 1.5, 0)],
			["H", Vector3(1.3, -1.0, 0.85)], ["H", Vector3(1.3, -1.0, -0.85)], ["H", Vector3(2.15, 0.35, 0)]],
			"bonds": [[0, 1, 2], [1, 2, 1], [0, 3, 1], [0, 4, 1], [1, 5, 1], [2, 6, 1], [2, 7, 1], [2, 8, 1]]}},
	# --- condensables --------------------------------------------------------
	# Primary pyrolysis tar, lumped onto levoglucosan C6H10O5 (the main
	# cellulose tar compound, Shafizadeh 1982). Vapour pressure from
	# Clausius–Clapeyron through a lumped boiling point of 300 °C and 70 kJ/mol
	# — an estimate standing in for a mixture that boils over 150–400 °C.
	# LHV ~16 MJ/kg (bio-oil, Bridgwater 2012).
	"tar": {"name": "Tar (lumped)", "formula": "C₆H₁₀O₅", "M": 162.14, "cp_g": 200.0, "cp_l": 300.0, "rho_l": 1200.0,
		"cc": {"tb_c": 300.0, "h_vap": 70000.0}, "h_vap": 70000.0, "lhv": 2594.0e3, "est": true,
		"color": Color(0.55, 0.35, 0.12), "role": "tar",
		"mol": {"atoms": [["C", Vector3(0, 0, 0)], ["C", Vector3(1.4, 0.3, 0)], ["C", Vector3(2.1, -0.9, 0.4)],
			["C", Vector3(1.3, -2.0, 0)], ["C", Vector3(-0.1, -1.8, 0.5)], ["C", Vector3(-0.8, -0.6, -0.4)],
			["O", Vector3(-0.7, 0.9, 0.5)], ["O", Vector3(2.0, 1.4, -0.3)], ["O", Vector3(3.4, -1.0, -0.1)],
			["O", Vector3(1.9, -3.2, 0.3)], ["O", Vector3(-0.8, -2.9, 0.1)]],
			"bonds": [[0, 1, 1], [1, 2, 1], [2, 3, 1], [3, 4, 1], [4, 5, 1], [5, 0, 1], [0, 6, 1], [1, 7, 1], [2, 8, 1], [3, 9, 1], [4, 10, 1]]}},
	# Acetic acid, the main acid of wood vinegar (pyroligneous acid).
	# Antoine (Lange's): bp 118.1 °C; ΔHvap 23.7 kJ/mol at the bp (low:
	# the vapour is largely dimerised); LHV 14.5 MJ/kg.
	"acetic": {"name": "Acetic acid", "formula": "CH₃COOH", "M": 60.052, "cp_g": 80.0, "cp_l": 123.1, "rho_l": 1049.0,
		"antoine": [{"a": 7.38782, "b": 1533.313, "c": 222.309, "t0": 29.8, "t1": 126.5}],
		"h_vap": 23700.0, "lhv": 871.0e3, "color": Color(0.85, 0.60, 0.30), "role": "vinegar",
		"mol": {"atoms": [["C", Vector3(-0.75, 0, 0)], ["C", Vector3(0.75, 0, 0)], ["O", Vector3(1.4, 1.05, 0)],
			["O", Vector3(1.35, -1.15, 0)], ["H", Vector3(2.3, -1.1, 0)], ["H", Vector3(-1.15, 1.0, 0)],
			["H", Vector3(-1.15, -0.5, 0.88)], ["H", Vector3(-1.15, -0.5, -0.88)]],
			"bonds": [[0, 1, 1], [1, 2, 2], [1, 3, 1], [3, 4, 1], [0, 5, 1], [0, 6, 1], [0, 7, 1]]}},
	# Ethanol. Antoine (Lange's, −57 to 80 °C): bp 78.37 °C. ΔHvap
	# 38.56 kJ/mol; LHV 26.8 MJ/kg.
	"ethanol": {"name": "Ethanol", "formula": "C₂H₅OH", "M": 46.069, "cp_g": 85.0, "cp_l": 112.3, "rho_l": 789.0,
		"antoine": [{"a": 8.20417, "b": 1642.89, "c": 230.300, "t0": -57.0, "t1": 80.0},
			{"a": 7.68117, "b": 1332.04, "c": 199.200, "t0": 77.0, "t1": 243.0}],
		"h_vap": 38560.0, "lhv": 1235.0e3, "color": Color(0.80, 0.90, 1.0), "role": "spirit",
		"mol": {"atoms": [["C", Vector3(-1.2, -0.2, 0)], ["C", Vector3(0.3, 0.2, 0)], ["O", Vector3(1.05, -0.95, 0)],
			["H", Vector3(1.95, -0.65, 0)], ["H", Vector3(-1.75, 0.75, 0)], ["H", Vector3(-1.45, -0.8, 0.88)],
			["H", Vector3(-1.45, -0.8, -0.88)], ["H", Vector3(0.55, 0.8, 0.88)], ["H", Vector3(0.55, 0.8, -0.88)]],
			"bonds": [[0, 1, 1], [1, 2, 1], [2, 3, 1], [0, 4, 1], [0, 5, 1], [0, 6, 1], [1, 7, 1], [1, 8, 1]]}},
	# Plastic cracking liquids, on n-alkane surrogates: oil = n-dodecane
	# (bp 216.3 °C, ΔHvap 61.5 kJ/mol, NIST), wax = n-pentacosane
	# (bp 402 °C, ΔHvap ~100 kJ/mol, an estimate). LHV 44 MJ/kg.
	"oil": {"name": "Pyrolysis oil", "formula": "C₁₂H₂₆", "M": 170.33, "cp_g": 380.0, "cp_l": 376.0, "rho_l": 750.0,
		"cc": {"tb_c": 216.3, "h_vap": 61500.0}, "h_vap": 61500.0, "lhv": 7495.0e3,
		"color": Color(0.75, 0.55, 0.20), "role": "oil", "unit": "CH2", "chain": 12},
	"wax": {"name": "Wax", "formula": "C₂₅H₅₂", "M": 352.69, "cp_g": 780.0, "cp_l": 760.0, "rho_l": 800.0,
		"cc": {"tb_c": 402.0, "h_vap": 100000.0}, "h_vap": 100000.0, "lhv": 15520.0e3, "est": true,
		"color": Color(0.90, 0.85, 0.65), "role": "wax", "unit": "CH2", "chain": 25},
	# --- solids (per kg) -----------------------------------------------------
	# Dry wood ~1.5 kJ/kg·K at 300–500 K (Ragland, Aerts & Baker 1991);
	# char ~1.0 kJ/kg·K (Gupta et al. 2003). Softwood composition (Sjöström
	# 1993): cellulose 42 %, hemicellulose 27 %, lignin 28 %, ash/extractives 3 %.
	"cellulose": {"name": "Cellulose", "formula": "(C₆H₁₀O₅)ₙ", "cp_s": 1500.0, "solid": true,
		"color": Color(0.85, 0.72, 0.50), "unit": "glucose", "chain": 4},
	"hemicellulose": {"name": "Hemicellulose", "formula": "(C₅H₈O₄)ₙ", "cp_s": 1500.0, "solid": true,
		"color": Color(0.80, 0.65, 0.42), "unit": "xylose", "chain": 4},
	"lignin": {"name": "Lignin", "formula": "(C₁₀H₁₂O₃)ₙ", "cp_s": 1500.0, "solid": true,
		"color": Color(0.60, 0.45, 0.28), "unit": "phenylpropane", "chain": 3},
	"moisture": {"name": "Moisture", "formula": "H₂O (in the wood)", "cp_s": 4186.0, "solid": true,
		"color": Color(0.40, 0.55, 0.85), "of": "H2O"},
	"char": {"name": "Char", "formula": "C (mostly)", "cp_s": 1000.0, "solid": true, "lhv_kg": 32.0e6,
		"color": Color(0.10, 0.09, 0.08), "unit": "graphene", "chain": 6},
	"ash": {"name": "Ash", "formula": "minerals", "cp_s": 800.0, "solid": true, "color": Color(0.75, 0.73, 0.70)},
	"desiccant": {"name": "Silica gel", "formula": "SiO₂", "cp_s": 920.0, "solid": true,
		"color": Color(0.85, 0.85, 0.95)},
	"pe": {"name": "Polyethylene", "formula": "(C₂H₄)ₙ", "cp_s": 2300.0, "solid": true,
		"color": Color(0.92, 0.92, 0.88), "unit": "CH2", "chain": 8},
	"pp": {"name": "Polypropylene", "formula": "(C₃H₆)ₙ", "cp_s": 1920.0, "solid": true,
		"color": Color(0.90, 0.88, 0.80), "unit": "CH2", "chain": 8},
}


static func has(id: String) -> bool:
	return DATA.has(id)


static func row(id: String) -> Dictionary:
	return DATA.get(id, {})


static func molar_mass_kg(id: String) -> float:
	return float(row(id).get("M", 28.0)) * 0.001


static func is_gas(id: String) -> bool:
	return id in GASES


static func is_solid(id: String) -> bool:
	return bool(row(id).get("solid", false))


static func is_condensable(id: String) -> bool:
	var r := row(id)
	return r.has("antoine") or r.has("cc")


static func color(id: String) -> Color:
	return row(id).get("color", Color.GRAY)


static func display_name(id: String) -> String:
	return str(row(id).get("name", id))


static func lhv_j_per_mol(id: String) -> float:
	return float(row(id).get("lhv", 0.0))


## The rows that are estimates (for the selftest's list).
static func estimates() -> Array:
	var out: Array = []
	for k in DATA.keys():
		if bool((DATA[k] as Dictionary).get("est", false)):
			out.append(k)
	return out
