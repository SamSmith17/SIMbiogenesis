class_name CompositionData
extends RefCounted

## What every resource kind is MADE of (resource composition plan, Phase 1:
## plans/RESOURCE_COMPOSITION_PLAN.md). Pure data; CompositionCatalog reads it.
##
## Three levels:
##   KIND       a resource kind (ResourceKinds id): its mass per unit, and
##              mass fractions of COMPONENTS and/or of other KINDS. `rest`
##              names the component that fills the remainder to 1 (almost
##              always water), so a row lists only what it is not.
##   COMPONENT  a chemical species with a formula, or explicit element mass
##              fractions, or a mix of other components.
##   ELEMENT    CompositionCatalog.ELEMENTS ("X" = everything else: Br, Sr, …).
## Gas kinds list MOLE fractions (`moles`), are counted per Nm³ (0 °C,
## 101.325 kPa) and take their density from the mean molar mass.
##
## Every row says where it came from in `src`; a row that is a judgement
## call (a surrogate formula, a mix split nobody measured) carries
## `est: true` and is listed by CompositionCatalog.estimates().
##
## Sources cited below:
##   Vinnerås et al. 2006: B. Vinnerås, H. Palmquist, P. Balmér, H. Jönsson,
##     "The characteristics of household wastewater and biodegradable solid
##     waste — a proposal for new Swedish design values", Urban Water J. 3(1)
##     3–11. Per person per year: urine 550 kg, N 4.0, P 0.33, K 1.0 kg;
##     feces 51 kg wet / 11 kg dry, N 0.55, P 0.18, K 0.36 kg.
##   Rose et al. 2015: C. Rose, A. Parker, B. Jefferson, E. Cartmell, "The
##     characterization of feces and urine: a review of the literature to
##     inform advanced treatment technology", Crit. Rev. Environ. Sci.
##     Technol. 45(17) 1827–1879.
##   Putnam 1971: D. F. Putnam, "Composition and concentrative properties of
##     human urine", NASA CR-1802 (Na 1.17–4.39 g/L, Cl 1.87–8.4 g/L,
##     inorganic sulfate 0.16–1.80 g/L).
##   Kirchmann & Pettersson 1995: urea is 75–90 % of fresh urine's N
##     (Fert. Res. 40, 149–154).
##   Millero et al. 2008: the TEOS-10 Reference Composition of seawater
##     (Deep-Sea Res. I 55, 50–72), salinity 35.165 g/kg.
##   WHO 2017: Guidelines for drinking-water quality, 4th ed. (TDS below
##     ~600 mg/L is palatable; tap water is typically 100–500 mg/L).
##   Friedler 2004: E. Friedler, "Quality of individual domestic greywater
##     streams and its implication for on-site treatment and reuse
##     possibilities", Environ. Technol. 25(9) 997–1008.
##   FAO/WHO/UNU 2007: Protein and amino acid requirements in human
##     nutrition (WHO TRS 935); a 2,500 kcal day.
##   Phyllis2: ECN.TNO database of biomass composition (softwood: C ~50 %,
##     H ~6 %, O ~43 %, N ~0.1 %, ash ~0.5 % dry; LHV dry ~18.6 MJ/kg).
##   Bridgwater 2012: A. V. Bridgwater, "Review of fast pyrolysis of biomass
##     and product upgrading", Biomass Bioenergy 38, 68–94 (bio-oil water
##     20–30 %, LHV ~16–19 MJ/kg).
##   Anuar Sharuddin et al. 2016: "A review on pyrolysis of plastic wastes",
##     Energy Convers. Manag. 115, 308–326 (PE/PP oil LHV ~42–45 MJ/kg).
##   Mathew & Zakaria 2015: "Pyroligneous acid — the smoky acidic liquid
##     from plant biomass", Appl. Microbiol. Biotechnol. 99, 611–622.
##   Kossmann et al.: GTZ Biogas Digest vol. I (biogas 55–70 % CH4).
##   PlasticsEurope 2022: Plastics — the Facts (packaging demand by polymer).
##   Zhang et al. 2007: food waste TS ~31 %, VS/TS ~85 %
##     (Bioresour. Technol. 98, 929–935).
##   Stevenson 1994: Humus Chemistry (humic substances C ~55–60 %, N ~4 %).
##   Steam tables (IAPWS-IF97): saturated vapour at 100 °C, h = 2676 kJ/kg;
##     liquid water at 15 °C, h = 63 kJ/kg.
##   Engineering ToolBox: fuel densities and heating values.

## Mass fractions of the elements in one kg of each component, or a formula.
const COMPONENTS := {
	# --- water and dissolved salts ------------------------------------------
	"H2O": {"formula": "H2O", "name": "water"},
	"nacl": {"formula": "NaCl", "name": "sodium chloride"},
	"kcl": {"formula": "KCl", "name": "potassium chloride"},
	"caco3": {"formula": "CaCO3", "name": "calcium carbonate (hardness)"},
	"mgso4": {"formula": "MgSO4", "name": "magnesium sulfate"},
	"sulfate": {"formula": "SO4", "name": "sulfate"},
	"phosphate": {"formula": "H2PO4", "name": "phosphate"},
	"nitrate": {"formula": "KNO3", "name": "nitrate (as KNO3)"},
	"ammonium": {"formula": "NH4HCO3", "name": "ammonium (as NH4HCO3)"},
	# Tap water's dissolved solids: carbonate hardness, salt, sulfate. est
	"tds_tap": {"mix": {"caco3": 0.50, "nacl": 0.30, "mgso4": 0.15, "kcl": 0.05},
		"name": "dissolved solids", "est": true},
	# Rain's: mostly sea salt and dust. est
	"tds_rain": {"mix": {"nacl": 0.60, "caco3": 0.30, "sulfate": 0.10},
		"name": "dissolved solids (rain)", "est": true},
	# Sea salt per kg of salt, TEOS-10 reference composition (Millero 2008):
	# Cl 19.353, Na 10.781, SO4 2.712, Mg 1.284, Ca 0.412, K 0.399, HCO3 0.105,
	# Br 0.067, CO3 0.014, Sr 0.008 g per kg seawater, over 35.165 g.
	"sea_salts": {"elements": {"Cl": 0.55034, "Na": 0.30658, "S": 0.02574, "O": 0.05406,
		"Mg": 0.03651, "Ca": 0.01172, "K": 0.01135, "C": 0.00067, "H": 0.00005, "X": 0.00298},
		"name": "sea salts", "src": "Millero et al. 2008"},
	# --- nutrients ----------------------------------------------------------
	"urea": {"formula": "CH4N2O", "name": "urea"},
	# Every non-urea N of urine (creatinine, ammonia, uric acid, amino acids)
	# carried as creatinine. est
	"creatinine": {"formula": "C4H7N3O", "name": "creatinine (other N)", "est": true},
	# Urine's organic acids as citric acid. est
	"organic_acids": {"formula": "C6H8O7", "name": "organic acids", "est": true},
	# The game's `nutrients` unit is kg of N + P + K (2026-11-09), in fresh
	# urine's mass ratio N:P:K = 4.0 : 0.33 : 1.0 (Vinnerås 2006).
	"npk": {"elements": {"N": 0.7505, "P": 0.0619, "K": 0.1876}, "name": "N + P + K",
		"src": "Vinnerås et al. 2006 urine ratio"},
	# --- food, bodies, plants -----------------------------------------------
	"carbohydrate": {"formula": "C6H10O5", "name": "carbohydrate (starch)"},
	"fibre": {"formula": "C6H10O5", "name": "fibre"},
	"lipid": {"formula": "C57H104O6", "name": "fat (triolein)"},
	# Mean protein: C 53, H 7, O 22.5, N 16, S 1, P 0.5 % (the 6.25 N factor). est split
	"protein": {"elements": {"C": 0.530, "H": 0.070, "O": 0.225, "N": 0.160, "S": 0.010, "P": 0.005},
		"name": "protein", "est": true},
	# Minerals of food, to give a 2,500 kcal day K 3.7 g, P 1.4 g, Na 2.3 g,
	# Cl 3.5 g, Ca 1 g, Mg 0.3 g (with the protein's P). est
	"food_minerals": {"elements": {"K": 0.224, "P": 0.061, "Na": 0.136, "Cl": 0.209, "Ca": 0.061,
		"Mg": 0.018, "S": 0.018, "O": 0.273}, "name": "minerals", "est": true},
	# Feces ash per kg ash, to give Vinnerås's P and K per kg of feces. est
	"feces_ash": {"elements": {"K": 0.208, "P": 0.094, "Ca": 0.150, "Mg": 0.040, "Na": 0.020,
		"Si": 0.030, "S": 0.010, "Cl": 0.010, "O": 0.410, "C": 0.028}, "name": "ash", "est": true},
	"cellulose": {"formula": "C6H10O5", "name": "cellulose"},
	"hemicellulose": {"formula": "C5H8O4", "name": "hemicellulose (xylan)"},
	# Softwood lignin by element (Phyllis2-range). est
	"lignin": {"elements": {"C": 0.63, "H": 0.06, "O": 0.31}, "name": "lignin", "est": true},
	# Wood extractives as abietic acid (resin). est
	"extractives": {"formula": "C20H30O2", "name": "extractives (resin)", "est": true},
	# Wood / plant ash by element (oxides and carbonates). est
	"bio_ash": {"elements": {"K": 0.20, "Ca": 0.25, "Si": 0.15, "P": 0.05, "Mg": 0.05, "Na": 0.02,
		"O": 0.26, "C": 0.02}, "name": "ash", "est": true},
	# Humic matter (Stevenson 1994 typical). est
	"humus": {"elements": {"C": 0.58, "H": 0.05, "O": 0.33, "N": 0.04}, "name": "humus", "est": true},
	# Slow-pyrolysis char at ~500 °C from mixed plant matter, dry: the feed's
	# ash concentrates in it (residue / straw chars K 2–5 %, P 0.2–1.5 %). est
	"char": {"elements": {"C": 0.775, "H": 0.030, "O": 0.100, "N": 0.015, "K": 0.032, "Ca": 0.020,
		"Si": 0.0137, "Mg": 0.005, "P": 0.0093}, "name": "char", "est": true},
	# --- pyrolysis products -------------------------------------------------
	"levoglucosan": {"formula": "C6H10O5", "name": "levoglucosan (sugar tar)"},
	"guaiacol": {"formula": "C7H8O2", "name": "guaiacol (lignin tar)"},
	"acetic": {"formula": "C2H4O2", "name": "acetic acid"},
	"methanol": {"formula": "CH4O", "name": "methanol"},
	# Polyolefin pyrolysis oil, CnH2n. est
	"polyolefin_oil": {"formula": "C10H20", "name": "hydrocarbon oil", "est": true},
	# --- gases (lhv_mj_nm3: lower heating value per normal m³) --------------
	"CH4": {"formula": "CH4", "name": "methane", "lhv_mj_nm3": 35.81},
	"CO2": {"formula": "CO2", "name": "carbon dioxide"},
	"CO": {"formula": "CO", "name": "carbon monoxide", "lhv_mj_nm3": 12.63},
	"H2": {"formula": "H2", "name": "hydrogen", "lhv_mj_nm3": 10.78},
	"N2": {"formula": "N2", "name": "nitrogen"},
	"O2": {"formula": "O2", "name": "oxygen"},
	"C2H4": {"formula": "C2H4", "name": "ethylene", "lhv_mj_nm3": 59.0},
	# Light hydrocarbons from cracking plastic (TcSpecies' C3H6 surrogate).
	"C3H6": {"formula": "C3H6", "name": "light hydrocarbons", "lhv_mj_nm3": 86.0},
	"NH3": {"formula": "NH3", "name": "ammonia"},
	# --- polymers and fuels -------------------------------------------------
	"pe": {"formula": "C2H4", "name": "polyethylene"},
	"pp": {"formula": "C3H6", "name": "polypropylene"},
	"pet": {"formula": "C10H8O4", "name": "PET"},
	"ps": {"formula": "C8H8", "name": "polystyrene"},
	"pvc": {"formula": "C2H3Cl", "name": "PVC"},
	"pla": {"formula": "C3H4O2", "name": "PLA"},
	"surfactant": {"formula": "C18H29NaO3S", "name": "detergent (LAS)"},
	"diesel_hc": {"formula": "C12H23", "name": "diesel (C12H23)", "est": true},
	"gasoline_hc": {"formula": "C8H18", "name": "gasoline (iso-octane)", "est": true},
	"propane": {"formula": "C3H8", "name": "propane"},
	# --- minerals and metals ------------------------------------------------
	"sand": {"formula": "SiO2", "name": "sand"},
	# Kaolinite-rich clay with some iron and feldspar. est
	"clay": {"elements": {"Si": 0.22, "Al": 0.17, "O": 0.53, "Fe": 0.03, "K": 0.02, "Ca": 0.01,
		"Mg": 0.01, "H": 0.01}, "name": "clay", "est": true},
	"steel": {"elements": {"Fe": 0.98, "C": 0.02}, "name": "steel", "est": true},
	# --- building materials (Phase 9: what is stored in things) -------------
	"aluminium": {"elements": {"Al": 1.0}, "name": "aluminium"},
	"pc": {"formula": "C16H14O3", "name": "polycarbonate"},
	"pmma": {"formula": "C5H8O2", "name": "acrylic (PMMA)"},
	# Phenol-formaldehyde plywood glue, cured (C8H8O2 repeat unit). est
	"pf_resin": {"formula": "C8H8O2", "name": "plywood glue", "est": true},
	"silicon": {"formula": "Si", "name": "silicon"},
	"copper": {"elements": {"X": 1.0}, "name": "copper (untracked)"},
	# Soda-lime glass: 72 % SiO2, 14 % Na2O, 9 % CaO, 4 % MgO, 1 % Al2O3.
	"glass": {"elements": {"Si": 0.337, "O": 0.461, "Na": 0.104, "Ca": 0.064, "Mg": 0.024,
		"Al": 0.005, "X": 0.005}, "name": "soda-lime glass", "src": "soda-lime oxide shares"},
	# Concrete, cured: aggregate (SiO2) 70 %, cement hydrates ~25 %, water 5 %. est
	"concrete": {"elements": {"O": 0.50, "Si": 0.29, "Ca": 0.13, "Al": 0.02, "Fe": 0.015,
		"H": 0.006, "C": 0.004, "Mg": 0.01, "X": 0.025}, "name": "concrete", "est": true},
}

## waste: water or matter someone has used (greywater, urine, food scraps …):
## the water in it counts as USED water, and clean water a process wins back
## from it counts as RECOVERED (ElementLedger's water recovery ratio).
## kg_per_unit: kg per one of the kind's unit (L, kg, item …). lhv_mj_kg:
## lower heating value as received. sensible_mj_kg: heat carried above 15 °C
## water. family / grade: see GRADES.
const KINDS := {
	# --- waters ---------------------------------------------------------------
	"water": {"kg_per_unit": 1.0, "mix": {"tds_tap": 0.0003}, "rest": "H2O",
		"family": "water", "grade": 5, "src": "WHO 2017 (300 mg/L TDS)"},
	"distilled_water": {"kg_per_unit": 1.0, "mix": {"tds_tap": 0.000001}, "rest": "H2O",
		"family": "water", "grade": 6, "src": "~1 mg/L TDS"},
	"rainwater": {"kg_per_unit": 1.0, "mix": {"tds_rain": 0.00002, "carbohydrate": 0.00001},
		"rest": "H2O", "family": "water", "grade": 4, "src": "rain ~10–30 mg/L TDS, est", "est": true},
	# Clean but not drinking water: filtered greywater for washing and flushing.
	"wash_water": {"kg_per_unit": 1.0, "mix": {"tds_tap": 0.0006, "carbohydrate": 0.00003},
		"rest": "H2O", "family": "water", "grade": 4, "src": "est", "est": true},
	"irrigation_water": {"kg_per_unit": 1.0, "mix": {"tds_tap": 0.0005, "nitrate": 0.00005},
		"rest": "H2O", "family": "water", "grade": 3, "src": "est", "est": true},
	"hot_water": {"kg_per_unit": 0.983, "mix": {"tds_tap": 0.0003}, "rest": "H2O",
		"family": "water", "grade": 5, "sensible_mj_kg": 0.188,
		"src": "60 °C: density 0.983; (60 − 15) K × 4.186 kJ/kg·K"},
	"steam": {"kg_per_unit": 1.0, "rest": "H2O", "family": "steam", "sensible_mj_kg": 2.613,
		"src": "IAPWS-IF97: 2676 − 63 kJ/kg"},
	"seawater": {"kg_per_unit": 1.025, "mix": {"sea_salts": 0.035165}, "rest": "H2O",
		"family": "water", "grade": 0, "src": "Millero et al. 2008"},
	# Friedler 2004 mixed greywater: COD ~400–700 mg/L, TN ~10, TP ~5–10 mg/L.
	"greywater": {"waste": true, "kg_per_unit": 1.0, "mix": {"carbohydrate": 0.00025, "lipid": 0.00006,
		"surfactant": 0.00004, "nacl": 0.0005, "caco3": 0.0003, "urea": 0.00002, "phosphate": 0.00002},
		"rest": "H2O", "family": "water", "grade": 2, "src": "Friedler 2004, est split", "est": true},
	# Fresh urine per kg: N 7.27, P 0.60, K 1.82 g (Vinnerås 2006; 550 kg/p/yr);
	# 80 % of N as urea (Kirchmann & Pettersson 1995); Na 2.0, Cl 4.7, SO4
	# 1.2 g inside Putnam 1971's ranges.
	"urine": {"waste": true, "kg_per_unit": 1.02, "mix": {"urea": 0.01250, "creatinine": 0.00385,
		"phosphate": 0.00188, "kcl": 0.00347, "nacl": 0.00508, "sulfate": 0.00120,
		"organic_acids": 0.00200}, "rest": "H2O", "family": "water", "grade": 1,
		"src": "Vinnerås et al. 2006; Putnam 1971; Kirchmann & Pettersson 1995"},
	# The game's blackwater is ~10 L/p/d (habitat 0.417 L/h): 1.42 L urine,
	# 0.14 kg feces, ~0.03 kg toilet paper, the rest flush water. est
	"blackwater": {"waste": true, "kg_per_unit": 1.01, "kinds": {"urine": 0.145, "feces": 0.0139},
		"mix": {"cellulose": 0.003}, "rest": "H2O", "family": "water", "grade": 1,
		"src": "est from the game's per-person flows", "est": true},
	# A urine-diverting toilet's flush: feces, a fifth of the urine, paper. est
	"brownwater": {"waste": true, "kg_per_unit": 1.01, "kinds": {"urine": 0.031, "feces": 0.0156},
		"mix": {"cellulose": 0.0027}, "rest": "H2O", "family": "water", "grade": 1,
		"src": "est from the urine-diverting habitat's flows", "est": true},
	# What the urine processor leaves: urine's salts and sulfate, the K and
	# P its nutrient product did not take, concentrated ~25×. est
	"brine": {"waste": true, "kg_per_unit": 1.1, "mix": {"nacl": 0.113, "kcl": 0.011, "sulfate": 0.026,
		"phosphate": 0.007, "organic_acids": 0.01}, "rest": "H2O", "family": "water", "grade": 0,
		"src": "est (urine-processor brine)", "est": true},
	# Liquid digestate, ~3 % solids. est
	"liquid_fertilizer": {"waste": true, "kg_per_unit": 1.01, "mix": {"carbohydrate": 0.004, "protein": 0.0034,
		"lipid": 0.0005, "ammonium": 0.0073, "phosphate": 0.0003, "kcl": 0.0006, "bio_ash": 0.002},
		"rest": "H2O", "family": "water", "grade": 1,
		"src": "digestate of blackwater + plant matter at the feed's own N, P and K (~1–2 % TS), est", "est": true},
	# --- food and excreta -----------------------------------------------------
	# 1.5 kg of food a day carrying ~2,500 kcal: protein 65, fat 57,
	# carbohydrate 224, fibre 13, minerals 11 g/kg. People eat 80 % of it
	# (the habitat's 20 % scraps), so they take in 1.2 kg × 10.4 g N =
	# 12.5 g N a day, what urine + feces carry out (Vinnerås 2006); ~78 g
	# protein a day eaten (FAO/WHO/UNU 2007 range).
	"food": {"kg_per_unit": 1.0, "mix": {"protein": 0.065, "lipid": 0.057, "carbohydrate": 0.224,
		"fibre": 0.013, "food_minerals": 0.011}, "rest": "H2O", "family": "organic",
		"food_mj_kg": 6.97, "src": "FAO/WHO/UNU 2007 reference day, est split", "est": true},
	"meal": {"kg_per_unit": 0.5, "kinds": {"food": 1.0}, "family": "organic",
		"food_mj_kg": 6.97, "src": "one meal ≈ 0.5 kg of food (Kitchen preset)"},
	"packaged_food": {"kg_per_unit": 1.0, "kinds": {"food": 0.88, "plastic_waste": 0.04,
		"packaging_waste": 0.08}, "family": "organic", "src": "Unpack & Sort preset shares", "est": true},
	"food_waste": {"waste": true, "kg_per_unit": 1.0, "mix": {"carbohydrate": 0.12, "protein": 0.035, "lipid": 0.03,
		"fibre": 0.02, "food_minerals": 0.008}, "rest": "H2O", "family": "organic",
		"src": "Zhang et al. 2007 (TS ~22–31 %), est", "est": true},
	# Feces per kg wet: TS 21.6 %, N 10.8, P 3.5, K 7.1 g (Vinnerås 2006);
	# dry matter split after Rose et al. 2015. Composition-only (no port kind).
	"feces": {"kg_per_unit": 1.06, "mix": {"protein": 0.067, "lipid": 0.030, "carbohydrate": 0.025,
		"fibre": 0.060, "feces_ash": 0.034}, "rest": "H2O", "family": "organic", "internal": true,
		"src": "Vinnerås et al. 2006; Rose et al. 2015", "est": true},
	"manure": {"waste": true, "kg_per_unit": 1.0, "mix": {"fibre": 0.050, "protein": 0.028, "carbohydrate": 0.020,
		"lipid": 0.005, "bio_ash": 0.027}, "rest": "H2O", "family": "organic",
		"src": "dairy manure ~12–13 % TS, est", "est": true},
	# --- plant matter ---------------------------------------------------------
	# Air-dried mixed plant matter at 20 % moisture (wet basis): prunings,
	# crop residue, scraps and wood, the game's one `biomass` (plants grow
	# it, compost and the reactor take it, fires burn it). Dry: N 1.5 %,
	# ash 5.6 % (Phyllis2 ranges for straw / prunings: N 0.5–2 %, ash 3–8 %).
	# LHV: 17.5 MJ/kg dry × 0.8 − 2.443 × 0.2.
	"biomass": {"kg_per_unit": 1.0, "mix": {"cellulose": 0.30, "hemicellulose": 0.20, "lignin": 0.16,
		"extractives": 0.02, "protein": 0.075, "bio_ash": 0.045}, "rest": "H2O", "family": "organic",
		"lhv_mj_kg": 13.51, "src": "Phyllis2 residue / prunings ranges, est split", "est": true},
	# Fresh crop residue and trimmings, 80 % moisture, N ~2.4 % dry.
	"green_waste": {"kg_per_unit": 1.0, "mix": {"cellulose": 0.065, "hemicellulose": 0.04,
		"lignin": 0.02, "protein": 0.03, "carbohydrate": 0.025, "bio_ash": 0.02}, "rest": "H2O",
		"family": "organic", "lhv_mj_kg": 1.45, "src": "est (compost feedstock ranges)", "est": true},
	# Kiln-dried softwood lumber at 12 % moisture: a 2×4 is ~0.45 kg/ft.
	# A kind since Phase 9: salvaged structures go into a lumber store.
	"lumber": {"kg_per_unit": 1.0, "mix": {"cellulose": 0.37, "hemicellulose": 0.22, "lignin": 0.24,
		"extractives": 0.03, "protein": 0.005, "bio_ash": 0.005}, "rest": "H2O", "family": "organic",
		"lhv_mj_kg": 16.1, "src": "Phyllis2 softwood at 12 % MC, est", "est": true},
	# --- what structures are made of (Phase 9; BuiltStock) ------------------
	# Plywood: veneers + 8 % cured PF glue (typical exterior ply). est
	"mat_plywood": {"kg_per_unit": 1.0, "kinds": {"lumber": 0.92}, "mix": {"pf_resin": 0.08},
		"family": "organic", "lhv_mj_kg": 17.0, "internal": true, "src": "est (glue 6–10 %)", "est": true},
	"mat_steel": {"kg_per_unit": 1.0, "mix": {"steel": 1.0}, "family": "metal", "internal": true, "src": "the material itself"},
	"mat_aluminium": {"kg_per_unit": 1.0, "mix": {"aluminium": 1.0}, "family": "metal", "internal": true, "src": "the material itself"},
	"mat_hdpe": {"kg_per_unit": 1.0, "mix": {"pe": 1.0}, "family": "plastic", "lhv_mj_kg": 43.0,
		"internal": true, "src": "Engineering ToolBox"},
	"mat_pp": {"kg_per_unit": 1.0, "mix": {"pp": 1.0}, "family": "plastic", "lhv_mj_kg": 43.0,
		"internal": true, "src": "Engineering ToolBox"},
	"mat_pvc": {"kg_per_unit": 1.0, "mix": {"pvc": 1.0}, "family": "plastic", "lhv_mj_kg": 18.0,
		"internal": true, "src": "Engineering ToolBox"},
	"mat_pc": {"kg_per_unit": 1.0, "mix": {"pc": 1.0}, "family": "plastic", "lhv_mj_kg": 29.0,
		"internal": true, "src": "est (~31 MJ/kg HHV)", "est": true},
	"mat_pmma": {"kg_per_unit": 1.0, "mix": {"pmma": 1.0}, "family": "plastic", "lhv_mj_kg": 25.0,
		"internal": true, "src": "est (~26 MJ/kg HHV)", "est": true},
	# Tarp / tent / shade fabric: polyester (PET) with a coating. est
	"mat_fabric": {"kg_per_unit": 1.0, "mix": {"pet": 1.0}, "family": "plastic", "lhv_mj_kg": 22.0,
		"internal": true, "src": "est (polyester)", "est": true},
	"mat_glass": {"kg_per_unit": 1.0, "mix": {"glass": 1.0}, "family": "mineral", "internal": true, "src": "the material itself"},
	"mat_concrete": {"kg_per_unit": 1.0, "mix": {"concrete": 1.0}, "family": "mineral", "internal": true, "est": true},
	# A crystalline-silicon module by mass (IRENA/IEA-PVPS 2016 End-of-Life
	# Management: glass ~76 %, Al frame ~10 %, polymers ~10 %, Si ~3 %, Cu ~1 %).
	"mat_pv_module": {"kg_per_unit": 1.0, "mix": {"glass": 0.76, "aluminium": 0.10, "pe": 0.10,
		"silicon": 0.03, "copper": 0.01}, "family": "mineral", "internal": true,
		"src": "IRENA/IEA-PVPS 2016"},
	# Salvaged metal: mostly steel, some aluminium. est
	"scrap_metal": {"kg_per_unit": 1.0, "mix": {"steel": 0.85, "aluminium": 0.15}, "family": "metal",
		"src": "est (structure salvage)", "est": true},
	# Broken glass and concrete. est
	"rubble": {"kg_per_unit": 1.0, "mix": {"glass": 0.5, "concrete": 0.5}, "family": "mineral",
		"src": "est (structure salvage)", "est": true},
	"biochar": {"kg_per_unit": 1.0, "mix": {"char": 0.95}, "rest": "H2O", "family": "carbon",
		"lhv_mj_kg": 28.4, "src": "est (wood char ~30 MJ/kg dry)", "est": true},
	# Finished compost, ~41 % moisture; dry: C ~25 %, N ~1.7 %, P ~0.3 %,
	# K ~1.4 % (compost ranges: C 20–30, N 1–2, P 0.2–0.5, K 0.5–1.5 % dry).
	"compost": {"kg_per_unit": 1.0, "mix": {"humus": 0.25, "sand": 0.20, "clay": 0.10, "bio_ash": 0.049,
		"phosphate": 0.0032},
		"rest": "H2O", "family": "mineral", "src": "compost ranges, est", "est": true},
	# Growing medium: the Soil Blender's 90 % compost + 10 % biochar.
	"soil": {"kg_per_unit": 1.0, "kinds": {"compost": 0.90, "biochar": 0.10}, "family": "mineral",
		"src": "Soil Blender preset (IBI amendment band)"},
	"nutrients": {"kg_per_unit": 1.0, "mix": {"npk": 1.0}, "family": "mineral",
		"src": "kg of N + P + K by definition"},
	"mud": {"kg_per_unit": 1.8, "mix": {"sand": 0.45, "clay": 0.25, "cellulose": 0.02},
		"rest": "H2O", "family": "mineral", "src": "cob / adobe mix, est", "est": true},
	# --- pyrolysis and fuels --------------------------------------------------
	# Wood bio-oil (Bridgwater 2012): 25 % water, dry C ~56 %, LHV 16 MJ/kg.
	"tar": {"kg_per_unit": 1.0, "mix": {"levoglucosan": 0.30, "guaiacol": 0.30, "acetic": 0.10,
		"char": 0.05}, "rest": "H2O", "family": "fuel", "lhv_mj_kg": 16.0,
		"src": "Bridgwater 2012, est split", "est": true},
	"plastic_oil": {"kg_per_unit": 1.0, "mix": {"polyolefin_oil": 1.0}, "family": "fuel",
		"lhv_mj_kg": 42.0, "src": "Anuar Sharuddin et al. 2016"},
	"wood_vinegar": {"kg_per_unit": 1.02, "mix": {"acetic": 0.07, "methanol": 0.015,
		"levoglucosan": 0.04, "guaiacol": 0.015}, "rest": "H2O", "family": "water", "grade": 0,
		"src": "Mathew & Zakaria 2015, est split", "est": true},
	# Allothermal pyrolysis gas, dry, by mole: ~10 MJ/Nm³ like the TC Process
	# Lab's runs (7–13 MJ/Nm³). est
	"woodgas": {"moles": {"CO": 0.30, "CO2": 0.25, "H2": 0.20, "CH4": 0.12, "C2H4": 0.03, "N2": 0.10},
		"family": "fuel", "src": "est (TC Process Lab range)", "est": true},
	"biogas": {"moles": {"CH4": 0.60, "CO2": 0.40}, "family": "fuel", "src": "Kossmann et al. (55–70 % CH4)"},
	"diesel": {"kg_per_unit": 0.832, "mix": {"diesel_hc": 1.0}, "family": "fuel", "lhv_mj_kg": 42.6,
		"src": "EN 590 density; Engineering ToolBox LHV"},
	"gasoline": {"kg_per_unit": 0.745, "mix": {"gasoline_hc": 1.0}, "family": "fuel", "lhv_mj_kg": 43.4,
		"src": "Engineering ToolBox"},
	"propane": {"kg_per_unit": 1.0, "mix": {"propane": 1.0}, "family": "fuel", "lhv_mj_kg": 46.35,
		"src": "Engineering ToolBox"},
	# --- plastics and parts ---------------------------------------------------
	# Household plastic: PlasticsEurope 2022 packaging shares + residue and labels.
	"plastic_waste": {"kg_per_unit": 1.0, "mix": {"pe": 0.44, "pp": 0.22, "pet": 0.15, "ps": 0.06,
		"pvc": 0.03, "cellulose": 0.05}, "kinds": {"food_waste": 0.05}, "family": "plastic",
		"lhv_mj_kg": 35.0, "src": "PlasticsEurope 2022, est", "est": true},
	# The shredder neither sorts nor washes: flake is the waste it was made from.
	"plastic_shred": {"kg_per_unit": 1.0, "kinds": {"plastic_waste": 1.0}, "family": "plastic", "lhv_mj_kg": 35.0},
	"plastic_flake": {"kg_per_unit": 1.0, "kinds": {"plastic_waste": 1.0}, "family": "plastic", "lhv_mj_kg": 35.0},
	# One 1 m² × 8 mm sheet (pp_sheet_8mm takes 7.2 kg of flake); other
	# sheets carry their own mass on the part record.
	"plastic_sheet": {"kg_per_unit": 7.2, "kinds": {"plastic_flake": 1.0}, "family": "plastic",
		"lhv_mj_kg": 35.0, "src": "pp_sheet_8mm recipe"},
	# A molded part (PP Injection Molder: 1.8 kg flake → 12 parts). Parts
	# with a mass of their own use it (CompositionCatalog.part_embodied).
	"finished_part": {"kg_per_unit": 0.15, "kinds": {"plastic_flake": 1.0}, "family": "plastic",
		"lhv_mj_kg": 35.0, "src": "PP Injection Molder preset", "est": true},
	"filament": {"kg_per_unit": 1.0, "mix": {"pla": 1.0}, "family": "plastic", "lhv_mj_kg": 18.0,
		"src": "PLA ~19 MJ/kg HHV", "est": true},
	"packaging_waste": {"kg_per_unit": 1.0, "mix": {"cellulose": 0.75, "steel": 0.25},
		"family": "packaging", "src": "card + tin, est", "est": true},
}

## Kinds that carry energy or accounting, not mass.
const NON_MATERIAL := ["electric", "dc_electricity", "thermal", "sunlight", "wind", "money", "chore_hours"]

## Kinds named somewhere that are another kind's water by another name.
const ALIASES := {"rain": "rainwater"}

## Water grades: how clean a water-family kind is. A port that needs grade g
## takes any water of grade ≥ g (Phase 10). 0 hypersaline / unusable,
## 1 sewage strength, 2 greywater, 3 irrigation-safe, 4 washing,
## 5 drinking (WHO), 6 distilled.
const GRADES := {
	0: "unusable (salt, brine)", 1: "sewage", 2: "greywater", 3: "irrigation",
	4: "washing", 5: "drinking", 6: "distilled",
}
