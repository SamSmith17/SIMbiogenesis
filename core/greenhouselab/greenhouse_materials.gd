class_name GreenhouseMaterials
extends RefCounted

## What a greenhouse is made of: glazings with their optical and thermal
## numbers, opaque walls, frame members, fans, heaters. Pure data + lookups.
##
## Glazing numbers (solar transmittance for direct beam at normal incidence,
## for diffuse light, transmittance to thermal infrared, overall U-value in
## still-ish air) are the commonly published values:
##   - Nelson, P. V. "Greenhouse Operation and Management", 7th ed., Table 3-2
##     (light transmission, U-values in Btu/h ft² °F, converted × 5.678);
##   - ASHRAE Handbook — Fundamentals, ch. 15 (glazing U);
##   - Giacomelli & Roberts 1993, "Greenhouse covering systems",
##     HortTechnology 3(1): 50-58 (thermal-IR transmittance: polyethylene
##     passes 50-80 % of long-wave radiation unless IR-treated, glass and
##     polycarbonate pass almost none — why single poly frosts on clear nights).
## Costs, masses and service lives are ESTIMATES from 2024-25 retail prices.

## id -> {label, tau (solar, normal), tau_diffuse, tau_lw (thermal IR),
##        eps (long-wave emissivity of the sheet), u (W/m²K), kg_m2,
##        usd_m2, life_y, look (DomeLab sheet id used to draw it)}
const GLAZING := {
	"poly_single": {"label": "Polyethylene film, single 6 mil", "tau": 0.87, "tau_diffuse": 0.80,
		"tau_lw": 0.70, "eps": 0.25, "u": 6.8, "kg_m2": 0.14, "usd_m2": 0.6, "life_y": 4.0,
		"look": "tarp_pe"},
	"poly_double": {"label": "Polyethylene, double inflated (IR inner)", "tau": 0.78,
		"tau_diffuse": 0.70, "tau_lw": 0.20, "eps": 0.55, "u": 4.0, "kg_m2": 0.29, "usd_m2": 1.5,
		"life_y": 4.0, "look": "tarp_pe"},
	"pc_corrugated": {"label": "Corrugated polycarbonate 0.8 mm", "tau": 0.88, "tau_diffuse": 0.80,
		"tau_lw": 0.02, "eps": 0.90, "u": 6.4, "kg_m2": 1.2, "usd_m2": 16.0, "life_y": 10.0,
		"look": "polycarb_4"},
	"pc_twin_6": {"label": "Twin-wall polycarbonate 6 mm", "tau": 0.80, "tau_diffuse": 0.72,
		"tau_lw": 0.0, "eps": 0.90, "u": 3.6, "kg_m2": 1.3, "usd_m2": 22.0, "life_y": 12.0,
		"look": "polycarb_6"},
	"pc_twin_8": {"label": "Twin-wall polycarbonate 8 mm", "tau": 0.80, "tau_diffuse": 0.72,
		"tau_lw": 0.0, "eps": 0.90, "u": 3.3, "kg_m2": 1.5, "usd_m2": 26.0, "life_y": 12.0,
		"look": "polycarb_6"},
	"pc_triple_16": {"label": "Triple-wall polycarbonate 16 mm", "tau": 0.74, "tau_diffuse": 0.66,
		"tau_lw": 0.0, "eps": 0.90, "u": 2.4, "kg_m2": 2.7, "usd_m2": 42.0, "life_y": 15.0,
		"look": "polycarb_6"},
	"glass_single": {"label": "Horticultural glass, single 4 mm", "tau": 0.90, "tau_diffuse": 0.82,
		"tau_lw": 0.0, "eps": 0.90, "u": 6.2, "kg_m2": 10.0, "usd_m2": 38.0, "life_y": 30.0,
		"look": "pmma_4"},
	"glass_double": {"label": "Double glazed (sealed units)", "tau": 0.80, "tau_diffuse": 0.72,
		"tau_lw": 0.0, "eps": 0.90, "u": 3.0, "kg_m2": 20.0, "usd_m2": 95.0, "life_y": 30.0,
		"look": "pmma_6"},
	"acrylic_twin_16": {"label": "Twin-wall acrylic 16 mm", "tau": 0.83, "tau_diffuse": 0.75,
		"tau_lw": 0.0, "eps": 0.90, "u": 3.2, "kg_m2": 5.0, "usd_m2": 60.0, "life_y": 20.0,
		"look": "pmma_6"},
}
const GLAZING_ORDER := ["poly_single", "poly_double", "pc_corrugated", "pc_twin_6", "pc_twin_8",
	"pc_triple_16", "glass_single", "glass_double", "acrylic_twin_16"]

## Opaque walls (a lean-to's back wall, a sunk house's retaining walls, a
## glazing's knee wall). `cap_kj_m2k` is the wall's own heat capacity per m²
## (ρ · c · thickness): a masonry back wall is the Chinese solar greenhouse's
## main store. Masonry: 300 mm of 1800 kg/m³ at 0.84 kJ/kg K ≈ 450 kJ/m²K;
## U of 300 mm solid masonry ≈ 1.8 W/m²K, with 100 mm of EPS outside ≈ 0.33
## (ASHRAE Fundamentals ch. 26 conductivities; estimates for a given build).
const WALLS := {
	"stud_insulated": {"label": "Insulated stud wall (R-13)", "u": 0.45, "cap_kj_m2k": 25.0,
		"kg_m2": 30.0, "usd_m2": 45.0, "color": Color(0.82, 0.78, 0.70)},
	"masonry": {"label": "Masonry / adobe 300 mm", "u": 1.8, "cap_kj_m2k": 450.0, "kg_m2": 540.0,
		"usd_m2": 70.0, "color": Color(0.70, 0.55, 0.42)},
	"masonry_insulated": {"label": "Masonry 300 mm + 100 mm insulation outside", "u": 0.33,
		"cap_kj_m2k": 450.0, "kg_m2": 545.0, "usd_m2": 95.0, "color": Color(0.70, 0.55, 0.42)},
	"earth_rammed": {"label": "Rammed earth 450 mm", "u": 1.6, "cap_kj_m2k": 720.0,
		"kg_m2": 900.0, "usd_m2": 85.0, "color": Color(0.66, 0.52, 0.38)},
}
const WALL_ORDER := ["stud_insulated", "masonry", "masonry_insulated", "earth_rammed"]

## Frame members. Hoop tubing is chain-link top rail (ASTM F1083 sizes);
## the EMT entries are DomeLab's own (`strut` names DomeLabMaterials.STRUTS
## for a dome form). kg/m from the mill tables, prices ESTIMATES.
const FRAMES := {
	"hoop_138": {"label": "1-3/8\" galvanised hoop tube", "od_mm": 34.9, "kg_m": 1.45,
		"usd_m": 3.6, "look": "galv", "strut": "emt_114", "max_span_m": 6.5},
	"hoop_158": {"label": "1-5/8\" galvanised hoop tube", "od_mm": 41.3, "kg_m": 2.0,
		"usd_m": 4.6, "look": "galv", "strut": "emt_114", "max_span_m": 9.5},
	"truss_steel": {"label": "Galvanised steel truss (gutter-connect)", "od_mm": 60.0,
		"kg_m": 4.5, "usd_m": 11.0, "look": "galv", "strut": "steel_sq_1", "max_span_m": 13.0},
	"emt_1": {"label": "1\" EMT conduit", "od_mm": 29.5, "kg_m": 0.97, "usd_m": 2.8,
		"look": "galv", "strut": "emt_1", "max_span_m": 5.0},
	"timber_2x4": {"label": "2x4 timber (38 × 89 mm)", "od_mm": 89.0, "kg_m": 1.6, "usd_m": 2.2,
		"look": "wood", "strut": "steel_sq_1", "max_span_m": 4.5},
	"timber_2x8": {"label": "2x8 timber rafters (38 × 184 mm)", "od_mm": 120.0, "kg_m": 3.3, "usd_m": 4.6,
		"look": "wood", "strut": "steel_sq_1", "max_span_m": 6.5},
	"alu_bar": {"label": "Aluminium glazing bar", "od_mm": 45.0, "kg_m": 1.2, "usd_m": 9.5,
		"look": "alu", "strut": "alu_tube_1", "max_span_m": 6.0},
}
const FRAME_ORDER := ["hoop_138", "hoop_158", "truss_steel", "emt_1", "timber_2x4", "timber_2x8", "alu_bar"]

## Exhaust fans: free-air volume at 0.05" (12 Pa) static pressure and motor
## draw, from typical box-fan catalogue rows (Schaefer / J&D, ESTIMATES).
## NGMA / ASAE EP406 sizing: ~8 cfm per ft² of floor (0.04 m³/s per m²),
## about one air change a minute, for summer cooling.
const FANS := {
	"fan_16": {"label": "16\" exhaust fan", "m3s": 0.94, "w": 180.0, "usd": 260.0, "d_m": 0.41},
	"fan_24": {"label": "24\" exhaust fan", "m3s": 2.36, "w": 375.0, "usd": 420.0, "d_m": 0.61},
	"fan_36": {"label": "36\" exhaust fan", "m3s": 4.95, "w": 560.0, "usd": 780.0, "d_m": 0.91},
	"fan_48": {"label": "48\" exhaust fan", "m3s": 9.9, "w": 1100.0, "usd": 1250.0, "d_m": 1.22},
}
const FAN_ORDER := ["fan_16", "fan_24", "fan_36", "fan_48"]
const FAN_M3S_PER_M2 := 0.04

## Heaters. An unvented propane heater puts its water vapour and CO₂ in the
## house (combustion of 1 kg C3H8 makes 1.63 kg H2O; LHV 46.4 MJ/kg).
const HEATERS := {
	"none": {"label": "No heater", "w": 0.0, "eff": 1.0, "fuel": "", "usd": 0.0},
	"electric_1500": {"label": "Electric 1.5 kW", "w": 1500.0, "eff": 1.0, "fuel": "electric", "usd": 90.0},
	"electric_5000": {"label": "Electric 5 kW (240 V)", "w": 5000.0, "eff": 1.0, "fuel": "electric", "usd": 320.0},
	"propane_9": {"label": "Propane 9 kW unvented", "w": 9000.0, "eff": 1.0, "fuel": "propane", "usd": 180.0},
	"propane_24": {"label": "Propane 24 kW vented unit", "w": 24000.0, "eff": 0.8, "fuel": "propane", "usd": 900.0},
}
const HEATER_ORDER := ["none", "electric_1500", "electric_5000", "propane_9", "propane_24"]
const PROPANE_LHV_MJ_KG := 46.4
const PROPANE_H2O_PER_KG := 1.63

## Horticultural LEDs: photon efficacy of DLC-qualified fixtures, 2.3 - 3.0
## µmol/J (DLC Horticultural Lighting QPL, 2024); 2.7 is a typical new bar.
const LED_EFFICACY_UMOL_J := 2.7
const LED_USD_PER_W := 1.1

## A 55 US gal drum (208 L) of water: the usual passive-solar store.
const BARREL_L := 208.0
const BARREL_USD := 25.0
## Roll-up side kit per metre of wall, ridge vent per metre, gutter per metre,
## cistern per litre (ESTIMATES).
const ROLLUP_USD_M := 14.0
const RIDGE_VENT_USD_M := 55.0
const LOUVRE_USD_M2 := 120.0
const VENT_MOTOR_W := 60.0
const GUTTER_USD_M := 18.0
const CISTERN_USD_L := 0.35
const DOOR_USD := 260.0


static func glazing(id: String) -> Dictionary:
	return GLAZING.get(id, GLAZING["pc_twin_8"])


static func wall(id: String) -> Dictionary:
	return WALLS.get(id, WALLS["stud_insulated"])


static func frame(id: String) -> Dictionary:
	return FRAMES.get(id, FRAMES["hoop_138"])


static func fan(id: String) -> Dictionary:
	return FANS.get(id, FANS["fan_24"])


static func heater(id: String) -> Dictionary:
	return HEATERS.get(id, HEATERS["none"])


## Beam transmittance at incidence angle `theta_deg` (0 = normal): a sheet's
## normal value times the relative Fresnel transmission of one air /
## polymer interface pair (n = 1.5), which falls off past ~50 degrees.
## (Duffie & Beckman, "Solar Engineering of Thermal Processes", §5.1.)
static func tau_at(g: Dictionary, theta_deg: float) -> float:
	var t0 := float(g.get("tau", 0.8))
	var th := deg_to_rad(clampf(theta_deg, 0.0, 89.5))
	return t0 * _fresnel_pair(th) / _fresnel_pair(0.0)


static func _fresnel_pair(th: float) -> float:
	var n := 1.5
	var tr := asin(sin(th) / n)
	var rs: float
	var rp: float
	if th < 1e-4:
		rs = pow((n - 1.0) / (n + 1.0), 2.0)
		rp = rs
	else:
		rs = pow(sin(tr - th) / sin(tr + th), 2.0)
		rp = pow(tan(tr - th) / tan(tr + th), 2.0)
	# Two surfaces, multiple reflections ignored: (1 - r)² per polarisation.
	return 0.5 * (pow(1.0 - rs, 2.0) + pow(1.0 - rp, 2.0))
