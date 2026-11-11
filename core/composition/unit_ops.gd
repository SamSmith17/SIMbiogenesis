class_name UnitOps
extends RefCounted

## Unit operations: the CLASSES of process a machine can be (resource
## composition plan Phase 5). A preset names its classes in `unit_ops`; a
## class says what it can pull out of what, how much it typically recovers
## and what it costs in energy, with the thermodynamic minimum beside the
## typical figure where there is one. When the library has no machine for a
## job, a class still answers "what could separate this?" (and is what a
## later gap node is sized from).
##
## A class row:
##   label, what     words for the player
##   accepts         what it takes in: "kind:<id>", "family:<f>" or
##                   "water_grade<=n" (CompositionCatalog grades)
##   gives           [{target, to, recovery}]: target "water" | an element
##                   (C N P K), `to` the kind (or "air") the target leaves
##                   in, recovery the typical share of it that does
##   kwh_per_kg      typical electrical (or heat) energy, kWh per kg of
##                   `per`; kwh_min the thermodynamic floor (NAN = none)
##   per             "feed" (kg in) or "water" (kg of water recovered)
##   reject          the kind the rest of the feed leaves as (brine from a
##                   still, digestate from a digester); none = an open residue
##   src             where the numbers come from; est = estimate
## Classes with no `gives` transform without separating (shredding, mixing,
## molding …): they are listed so every preset tag resolves.

const TARGETS := ["water", "N", "P", "K", "C"]
const TARGET_LABELS := {"water": "Water", "N": "Nitrogen", "P": "Phosphorus", "K": "Potassium", "C": "Carbon"}

const CLASSES := {
	"distillation": {"reject": "brine", "label": "Distillation", "what": "Boil the water off and condense it; the solids stay behind.",
		"accepts": ["family:water", "kind:urine", "kind:wood_vinegar"],
		"gives": [{"target": "water", "to": "distilled_water", "recovery": 0.90}],
		"kwh_per_kg": 0.80, "kwh_min": 0.627, "per": "water",
		"src": "latent heat 2257 kJ/kg = 0.627 kWh/kg (steam tables); 0.7–1.0 typical for a single-effect still"},
	"vapour_compression_distillation": {"reject": "brine", "label": "Vapour-compression distillation",
		"what": "Distil, then compress the vapour to reuse its heat (the ISS urine processor).",
		"accepts": ["kind:urine", "kind:brine", "kind:greywater", "kind:seawater", "kind:wash_water"],
		"gives": [{"target": "water", "to": "distilled_water", "recovery": 0.85}],
		"kwh_per_kg": 0.10, "kwh_min": 0.00106, "per": "water",
		"src": "ISS UPA: ~85 % of urine water recovered at ~0.1 kWh/L class (Carter 2009); floor = seawater minimum work (Elimelech & Phillip 2011)"},
	"reverse_osmosis": {"reject": "brine", "label": "Reverse osmosis", "what": "Push water through a membrane that stops the salts.",
		"accepts": ["kind:seawater", "kind:brine", "kind:greywater", "kind:rainwater", "kind:wash_water", "kind:irrigation_water"],
		"gives": [{"target": "water", "to": "water", "recovery": 0.50}],
		"kwh_per_kg": 0.003, "kwh_min": 0.00106, "per": "water",
		"src": "seawater RO ~3 kWh/m³ at ~50 % recovery; minimum 1.06 kWh/m³ (Elimelech & Phillip 2011)"},
	"filtration": {"label": "Filtration", "what": "Strain out the solids (sand, media, a membrane).",
		"accepts": ["kind:greywater", "kind:rainwater", "kind:wash_water", "kind:stormwater", "kind:liquid_fertilizer"],
		"gives": [{"target": "water", "to": "irrigation_water", "recovery": 0.90}],
		"kwh_per_kg": 0.0002, "kwh_min": NAN, "per": "feed",
		"src": "pumping through a media filter, est"},
	"disinfection": {"label": "Disinfection", "what": "Kill what lives in it (UV, chlorine, heat). Separates nothing.",
		"accepts": ["family:water"], "gives": [], "kwh_per_kg": 0.00004, "kwh_min": NAN, "per": "feed",
		"src": "UV ~40 Wh/m³, est"},
	"drying": {"label": "Drying", "what": "Drive the water off into the air with heat.",
		"accepts": ["family:organic", "family:carbon", "family:mineral", "kind:food_waste", "kind:manure"],
		"gives": [{"target": "water", "to": "air", "recovery": 0.90}],
		"kwh_per_kg": 1.0, "kwh_min": 0.627, "per": "water",
		"src": "latent heat of the water removed; dryers ~60 % efficient, est"},
	"condensation": {"label": "Condensation from air", "what": "Cool air below its dew point and collect the water.",
		"accepts": ["kind:air"], "gives": [{"target": "water", "to": "water", "recovery": 1.0}],
		"kwh_per_kg": 0.6, "kwh_min": NAN, "per": "water",
		"src": "atmospheric water generators 0.4–0.8 kWh/L (Bagheri 2018)"},
	"struvite_precipitation": {"reject": "liquid_fertilizer", "label": "Struvite precipitation",
		"what": "Dose magnesium; phosphate and ammonium settle out as struvite, a slow fertiliser.",
		"accepts": ["kind:urine", "kind:liquid_fertilizer", "kind:brownwater", "kind:blackwater"],
		"gives": [{"target": "P", "to": "nutrients", "recovery": 0.90}, {"target": "N", "to": "nutrients", "recovery": 0.05}],
		"kwh_per_kg": 0.0005, "kwh_min": NAN, "per": "feed",
		"src": "> 90 % of urine P, a few % of its N (Etter et al. 2011)"},
	"nitrification": {"reject": "liquid_fertilizer", "label": "Nitrification", "what": "Bacteria turn ammonia into nitrate so it can be kept.",
		"accepts": ["kind:urine", "kind:liquid_fertilizer", "kind:brownwater", "kind:blackwater"],
		"gives": [{"target": "N", "to": "liquid_fertilizer", "recovery": 0.90}],
		"kwh_per_kg": 0.002, "kwh_min": NAN, "per": "feed",
		"src": "aerated nitrification of urine (Udert & Wächter 2012), aeration est"},
	"anaerobic_digestion": {"reject": "liquid_fertilizer", "label": "Anaerobic digestion",
		"what": "Microbes without air turn organic matter into biogas; the nutrients stay in the digestate.",
		"accepts": ["family:organic", "kind:blackwater", "kind:brownwater", "kind:manure", "kind:food_waste"],
		"gives": [{"target": "C", "to": "biogas", "recovery": 0.50}, {"target": "N", "to": "liquid_fertilizer", "recovery": 0.95},
			{"target": "P", "to": "liquid_fertilizer", "recovery": 0.80}, {"target": "K", "to": "liquid_fertilizer", "recovery": 0.90}],
		"kwh_per_kg": 0.01, "kwh_min": NAN, "per": "feed",
		"src": "~50 % of degradable C to biogas; N, P, K kept (Möller & Müller 2012), mixing est"},
	"composting": {"reject": "compost", "label": "Composting", "what": "Aerobic decay; carbon leaves as CO₂, the nutrients stay in the compost.",
		"accepts": ["family:organic", "kind:manure", "kind:food_waste", "kind:green_waste"],
		"gives": [{"target": "C", "to": "air", "recovery": 0.50}, {"target": "N", "to": "compost", "recovery": 0.75},
			{"target": "P", "to": "compost", "recovery": 0.95}, {"target": "K", "to": "compost", "recovery": 0.90}],
		"kwh_per_kg": 0.0, "kwh_min": NAN, "per": "feed",
		"src": "C and 10–40 % of N lost to the air (Bernal et al. 2009)"},
	"pyrolysis": {"label": "Pyrolysis", "what": "Heat without air: char, oil and burnable gas.",
		"accepts": ["family:organic", "family:plastic", "kind:biomass", "kind:green_waste"],
		"gives": [{"target": "C", "to": "biochar", "recovery": 0.45}, {"target": "P", "to": "biochar", "recovery": 0.90},
			{"target": "K", "to": "biochar", "recovery": 0.90}],
		"kwh_per_kg": 0.5, "kwh_min": NAN, "per": "feed",
		"src": "slow pyrolysis keeps ~45 % of the C in char (Lehmann & Joseph 2015); 1.2 kW × 4 h / 10 kg from the TC Process Lab batch"},
	"combustion": {"reject": "air", "label": "Combustion", "what": "Burn it for heat or power. Separates nothing worth keeping.",
		"accepts": ["family:fuel"], "gives": [{"target": "C", "to": "air", "recovery": 1.0}],
		"kwh_per_kg": 0.0, "kwh_min": NAN, "per": "feed", "src": "complete combustion"},
	"cooking": {"label": "Cooking", "what": "Turn food into meals.", "accepts": ["kind:food"], "gives": [],
		"kwh_per_kg": 0.3, "kwh_min": NAN, "per": "feed", "src": "est"},
	"growing": {"label": "Growing", "what": "Plants turn water, nutrients and CO₂ into crop.", "accepts": ["kind:water", "kind:nutrients"],
		"gives": [], "kwh_per_kg": 0.0, "kwh_min": NAN, "per": "feed", "src": ""},
	"heating": {"label": "Heating", "what": "Raise a temperature.", "accepts": ["family:water"], "gives": [],
		"kwh_per_kg": 0.07, "kwh_min": NAN, "per": "feed", "src": "4.19 kJ/kg·K × 60 K"},
	"condensation_column": {"label": "Fractional condensation", "what": "Cool a vapour in steps to split its liquids.",
		"accepts": ["kind:woodgas"], "gives": [], "kwh_per_kg": 0.0, "kwh_min": NAN, "per": "feed", "src": ""},
	"shredding": {"label": "Shredding", "what": "Cut into pieces.", "accepts": ["family:plastic"], "gives": [],
		"kwh_per_kg": 0.1, "kwh_min": NAN, "per": "feed", "src": "est"},
	"sorting": {"label": "Sorting", "what": "Separate mixed things by hand.", "accepts": ["kind:packaged_food"], "gives": [],
		"kwh_per_kg": 0.0, "kwh_min": NAN, "per": "feed", "src": ""},
	"molding": {"label": "Molding", "what": "Melt and shape.", "accepts": ["family:plastic"], "gives": [],
		"kwh_per_kg": 0.6, "kwh_min": NAN, "per": "feed", "src": "est"},
	"mixing": {"label": "Mixing", "what": "Blend.", "accepts": [], "gives": [], "kwh_per_kg": 0.0, "kwh_min": NAN,
		"per": "feed", "src": ""},
	"pumping": {"label": "Pumping", "what": "Move it.", "accepts": ["family:water"], "gives": [],
		"kwh_per_kg": 0.0003, "kwh_min": NAN, "per": "feed", "src": "est"},
}


static func has(id: String) -> bool:
	return CLASSES.has(id)


static func label(id: String) -> String:
	return str((CLASSES.get(id, {}) as Dictionary).get("label", id.capitalize()))


static func target_label(t: String) -> String:
	return str(TARGET_LABELS.get(t, t))


## Whether a class takes `kind` in.
static func accepts(id: String, kind: String) -> bool:
	var row: Dictionary = CLASSES.get(id, {})
	var k := CompositionCatalog.canonical(kind)
	var fam := CompositionCatalog.family_of(k)
	var grade := CompositionCatalog.grade_of(k)
	for a in row.get("accepts", []):
		var s := str(a)
		if s == "kind:" + k:
			return true
		if s.begins_with("family:") and s.substr(7) == fam and not fam.is_empty():
			return true
		if s.begins_with("water_grade<=") and fam == "water" and grade >= 0 and grade <= int(s.substr(13)):
			return true
	return false


## Classes that pull `target` out of `kind`: [{class, label, to, recovery,
## kwh_per_kg, kwh_min, per, src}].
static func classes_for(kind: String, target: String) -> Array:
	var out: Array = []
	var ids := CLASSES.keys()
	ids.sort()
	for id in ids:
		if not accepts(str(id), kind):
			continue
		var row: Dictionary = CLASSES[id]
		for g in row.get("gives", []):
			var gd: Dictionary = g
			if str(gd["target"]) != target or str(gd["to"]) == CompositionCatalog.canonical(kind):
				continue
			out.append({"class": str(id), "label": str(row["label"]), "to": str(gd["to"]),
				"recovery": float(gd["recovery"]), "kwh_per_kg": float(row["kwh_per_kg"]),
				"kwh_min": float(row.get("kwh_min", NAN)), "per": str(row.get("per", "feed")),
				"src": str(row.get("src", "")), "what": str(row.get("what", ""))})
	return out
