class_name BatteryChemistry
extends RefCounted

## Battery chemistry identification and terminal-voltage behaviour.
##
## Chemistry is what actually decides how a bank behaves — how far you may
## charge it, how much of the nameplate capacity you can use, and whether
## resting voltage tells you anything about state of charge. It was previously
## unmodelled: presets carried only a nominal voltage, so a lead-acid bank and
## a lithium bank of the same size were indistinguishable on the canvas.
##
## Sources:
##  - Cell nominal/charge voltages are manufacturer datasheet convention:
##    LiFePO4 3.2 V nominal, 3.65 V max charge (4S = 12.8 / 14.6);
##    flooded/AGM lead-acid 2.0 V nominal, ~2.40 V absorb (6S = 12.0 / 14.4);
##    NMC/Li-ion 3.6-3.7 V nominal, 4.2 V max.
##  - Usable depth of discharge: lead-acid is conventionally limited to ~50 %
##    to reach rated cycle life, LiFePO4 to ~80-90 % (Battery University
##    BU-501/BU-808 cycle-life-vs-DoD guidance).
##  - The discharge-curve shape (LiFePO4 famously flat across the mid range,
##    lead-acid sloping roughly linearly) is why resting voltage is a usable
##    fuel gauge on lead-acid but nearly useless on lithium.

const LFP := "LFP"
const LI_ION := "Li-ion"
const LEAD := "SLA"
const UNKNOWN := ""

## cell_nominal_v, cell_max_v, usable_dod, and the resting-voltage swing
## (fraction of nominal) between empty and full.
const PROFILES := {
	LFP: {
		"label": "LFP", "long": "LiFePO4",
		"cell_nominal_v": 3.2, "cell_max_v": 3.65,
		"usable_dod": 0.85, "v_span": 0.10, "flat": true,
	},
	LI_ION: {
		"label": "Li-ion", "long": "Li-ion NMC",
		"cell_nominal_v": 3.6, "cell_max_v": 4.2,
		"usable_dod": 0.80, "v_span": 0.22, "flat": false,
	},
	LEAD: {
		"label": "SLA", "long": "Lead-acid (AGM/gel)",
		"cell_nominal_v": 2.0, "cell_max_v": 2.40,
		"usable_dod": 0.50, "v_span": 0.16, "flat": false,
	},
}


## Resolve a battery's chemistry from its specs. Explicit wins; then the name;
## then nominal voltage, which is a genuine discriminator because packs are
## built from whole cells — 12.8 / 51.2 V can only be 4S / 16S of 3.2 V LiFePO4,
## while 12.0 / 24.0 V is 6S / 12S of 2.0 V lead-acid. That third rule is what
## classifies presets like "Server Rack 48V 100Ah" whose name carries no
## chemistry token, and it covers legacy saves and user-authored presets.
static func infer(specs: Dictionary) -> String:
	var explicit := str(specs.get("chemistry", "")).strip_edges()
	if not explicit.is_empty():
		return normalize(explicit)
	var name := str(specs.get("name", "")).to_lower()
	if name.contains("lifepo") or name.contains("lfp"):
		return LFP
	if name.contains("agm") or name.contains("gel") or name.contains("lead") \
			or name.contains("sla") or name.contains("flooded"):
		return LEAD
	if name.contains("nmc") or name.contains("li-ion") or name.contains("lion") \
			or name.contains("lithium-ion"):
		return LI_ION
	return from_nominal_voltage(float(specs.get("voltage", 0.0)))


static func normalize(raw: String) -> String:
	var s := raw.strip_edges().to_lower()
	match s:
		"lfp", "lifepo4", "lifepo":
			return LFP
		"li-ion", "liion", "nmc", "lipo", "lithium-ion":
			return LI_ION
		"sla", "agm", "gel", "lead", "lead-acid", "flooded":
			return LEAD
	return UNKNOWN


## Classify by pack voltage alone: whichever cell size divides it evenly.
## LiFePO4 is checked first because 12.8/25.6/51.2 are unambiguous, whereas a
## round 12/24/48 can only be lead-acid in practice (a 4S LFP pack is 12.8).
static func from_nominal_voltage(v: float) -> String:
	if v <= 0.0:
		return UNKNOWN
	if _divides(v, 3.2):
		return LFP
	if _divides(v, 3.6) or _divides(v, 3.7):
		return LI_ION
	if _divides(v, 2.0):
		return LEAD
	return UNKNOWN


static func _divides(v: float, cell: float) -> bool:
	var n := roundf(v / cell)
	return n >= 1.0 and absf(v - n * cell) < 0.06


static func profile(chem: String) -> Dictionary:
	return PROFILES.get(chem, PROFILES[LFP]) as Dictionary


## Short tag for the node body ("LFP" / "SLA" / "Li-ion"); "" when unknown, so
## callers can omit the badge rather than print a guess.
static func label(chem: String) -> String:
	if chem.is_empty() or not PROFILES.has(chem):
		return ""
	return str((PROFILES[chem] as Dictionary).get("label", ""))


static func long_name(chem: String) -> String:
	if chem.is_empty() or not PROFILES.has(chem):
		return "Unknown chemistry"
	return str((PROFILES[chem] as Dictionary).get("long", ""))


## Full-charge (absorb) voltage for a pack — cells in series × cell max.
## Falls back to the generic 1.217 ratio when the chemistry is unknown, which
## is the constant GraphDcElectrical used for every pack before this existed.
static func charge_ceiling_v(nominal_v: float, chem: String) -> float:
	if nominal_v <= 0.0:
		return 0.0
	if not PROFILES.has(chem):
		return nominal_v * 1.2167
	var p: Dictionary = PROFILES[chem]
	var cells := roundf(nominal_v / float(p["cell_nominal_v"]))
	if cells < 1.0:
		return nominal_v * 1.2167
	return cells * float(p["cell_max_v"])


## Fraction of nameplate capacity it is reasonable to actually cycle.
static func usable_fraction(chem: String) -> float:
	return float(profile(chem).get("usable_dod", 0.85))


## Resting terminal voltage at a given state of charge.
##
## Deliberately shape-aware rather than a straight lerp: LiFePO4 sits nearly
## flat from ~20-90 % SOC (which is exactly why voltage is a poor fuel gauge for
## it) and only moves sharply at the extremes, while lead-acid falls close to
## linearly across the whole range. Modeled as nominal ± half the chemistry's
## voltage span, with the span applied through an S-curve for flat chemistries.
static func voltage_at_soc(nominal_v: float, chem: String, soc: float) -> float:
	if nominal_v <= 0.0:
		return 0.0
	var p := profile(chem)
	var u := clampf(soc, 0.0, 1.0)
	var shaped := u
	if bool(p.get("flat", false)):
		# Compress the middle, expand the knees: a cubic centred on 50 %.
		var c := (u - 0.5) * 2.0
		shaped = 0.5 + 0.5 * (c * c * c)
	var span := float(p.get("v_span", 0.12))
	return nominal_v * (1.0 - span * 0.5 + span * shaped)
