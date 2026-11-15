class_name CropPhysiology
extends RefCounted

## How each garden crop responds to temperature, light, humidity and water.
## Pure static, no autoloads. One row per GardenCrops.CROPS id; the visual
## fields (spacing, cycle, height) stay in GardenCrops, this file holds the
## physiology a greenhouse climate model needs.
##
## Columns (per row):
##   base, opt_low, opt_high, max   cardinal temperatures, deg C. Growth is 0 at
##                                  and below base and at and above max, 1 on
##                                  the opt_low..opt_high plateau.
##   frost_kill    deg C at which about half the plants die (LT50).
##   lue           g dry matter per MJ PAR intercepted (Monteith 1977).
##   hi            harvest index: edible share of the dry matter.
##   dli_target    mol/m2/day for full-quality growth; dli_min the least for
##                 a marketable crop.
##   kc            FAO-56 Kc mid-season.
##   vpd_lo/vpd_hi kPa band with no humidity penalty.
##   yield         kg fresh edible per m2 per cycle in an intensive bed.
##   dm            dry-matter share of the fresh edible part.
##   tt            thermal time to maturity, deg C day, = cycle x the
##                 thermal_time_rate at a 20 deg C mean (GardenCrops cycle).
##   est           columns in that row that are estimates (see below).
##
## Sources:
##   Temperature response: the beta function of Yan & Hunt (1999, Annals of
##     Botany 84:607), with the plateau between opt_low and opt_high taken out
##     (see temp_factor). Cardinal temperatures rounded from the compilations
##     in Luo (2011, Climatic Change 109:583) and Hatfield et al. (2011,
##     Agronomy J. 103:351) and from extension growing guides. The plateau
##     ends (opt_low, opt_high) are estimates for every row: the sources give
##     one optimum or a range, not a plateau.
##   Frost: extension frost-tolerance classes (hardy / half-hardy / tender,
##     e.g. Univ. of Minnesota / Penn State planting guides). Every
##     frost_kill value is an estimate within its class.
##   LUE: Sinclair & Muchow (1999, Adv. Agronomy 65:215) review, C3 crops
##     ~1.5-3 g/MJ PAR, C4 higher; tomato 3.0 after Heuvelink (1995,
##     Annals of Botany 75:369); potato 2.8 after Haverkort & Harris (1987).
##     Other crops: estimates in that range (marked).
##   Harvest index: Heuvelink 1995 (tomato fruit share ~0.6); potato 0.75
##     (field HI 0.7-0.85); the rest estimates (marked).
##   DLI: Faust (2002, "Light", Ball RedBook), Runkle ("Daily light integral
##     defined", GPN 2006), Torres & Lopez (Purdue HO-238), lettuce 17 mol
##     from Albright et al. (2000, JASHS 125:5). Crops not named there are
##     estimates from the leafy (12-17) / fruiting (20-30) ranges (marked).
##   Kc: FAO-56 (Allen et al. 1998) Table 12, mid-season. Basil and willow
##     have no FAO-56 row (marked).
##   VPD: common greenhouse targets (0.4-1.2 kPa leafy, 0.5-1.2 fruiting);
##     every band is an estimate.
##   Yields: rough intensive-bed figures (biointensive tables, e.g. Jeavons,
##     "How to Grow More Vegetables"); every yield is an estimate. Willow is
##     fuel, not food: its "edible" part is the harvested stems.
##   Dry matter: 1 - water content from USDA FoodData Central (SR Legacy),
##     raw; willow wood at harvest ~50 % moisture (estimate).
##
## Note: daily_growth_kg_dm treats the bed as a closed canopy (interception
## 1, PlantGrowth's convention), so it overstates growth early in a cycle.
## The yield column is the realistic per-cycle figure to compare against.

## Reference mean temperature the tt column is computed at.
const REF_TEMP_C := 20.0
## McCree (1972): sunlight PAR ~4.57 umol per J.
const MOL_PER_MJ_PAR := 4.57
## FAO-56 eq. 97: Kc of bare, dry-surfaced soil (Kc min 0.15-0.20).
const KC_SOIL := 0.15
## VPD response outside the band (estimates): saturated air at 0 kPa keeps
## this share (low transpiration, disease, tipburn); above the band growth
## falls linearly over VPD_CLOSE_SPAN_KPA to VPD_HIGH_FLOOR (stomata closing).
const VPD_LOW_FLOOR := 0.7
const VPD_HIGH_FLOOR := 0.3
const VPD_CLOSE_SPAN_KPA := 2.0
## Frost: damage is 0.5 at frost_kill and runs linearly from 0 to 1 over
## this span centred on it (estimate).
const FROST_SPAN_C := 3.0
## light_factor reaches 0.95 of saturation at dli_target before scaling.
const LIGHT_K_AT_TARGET := 3.0

const GENERIC_ID := "_generic_leafy"

const CROPS := {
	"lettuce": {"base": 4.0, "opt_low": 15.0, "opt_high": 22.0, "max": 30.0,
		"frost_kill": -3.0, "lue": 1.8, "hi": 0.85, "dli_target": 17.0, "dli_min": 12.0,
		"kc": 1.00, "vpd_lo": 0.4, "vpd_hi": 1.0, "yield": 3.5, "dm": 0.05, "tt": 880.0,
		"est": ["lue", "hi"]},
	"lettuce_red": {"base": 4.0, "opt_low": 15.0, "opt_high": 22.0, "max": 30.0,
		"frost_kill": -3.0, "lue": 1.7, "hi": 0.85, "dli_target": 17.0, "dli_min": 12.0,
		"kc": 1.00, "vpd_lo": 0.4, "vpd_hi": 1.0, "yield": 3.0, "dm": 0.05, "tt": 880.0,
		"est": ["lue", "hi"]},
	"romaine": {"base": 4.0, "opt_low": 15.0, "opt_high": 22.0, "max": 30.0,
		"frost_kill": -3.0, "lue": 1.8, "hi": 0.85, "dli_target": 17.0, "dli_min": 12.0,
		"kc": 1.00, "vpd_lo": 0.4, "vpd_hi": 1.0, "yield": 4.0, "dm": 0.054, "tt": 1040.0,
		"est": ["lue", "hi"]},
	"kale": {"base": 4.0, "opt_low": 15.0, "opt_high": 21.0, "max": 30.0,
		"frost_kill": -10.0, "lue": 2.0, "hi": 0.6, "dli_target": 14.0, "dli_min": 10.0,
		"kc": 1.05, "vpd_lo": 0.4, "vpd_hi": 1.2, "yield": 5.0, "dm": 0.10, "tt": 2400.0,
		"est": ["lue", "hi", "dli_target", "dli_min"]},
	"chard": {"base": 4.0, "opt_low": 15.0, "opt_high": 24.0, "max": 32.0,
		"frost_kill": -5.0, "lue": 1.9, "hi": 0.6, "dli_target": 14.0, "dli_min": 10.0,
		"kc": 1.00, "vpd_lo": 0.4, "vpd_hi": 1.2, "yield": 5.0, "dm": 0.073, "tt": 1920.0,
		"est": ["lue", "hi", "dli_target", "dli_min", "kc"]},
	"tomato": {"base": 10.0, "opt_low": 21.0, "opt_high": 26.0, "max": 35.0,
		"frost_kill": -0.5, "lue": 3.0, "hi": 0.6, "dli_target": 25.0, "dli_min": 15.0,
		"kc": 1.15, "vpd_lo": 0.5, "vpd_hi": 1.2, "yield": 10.0, "dm": 0.055, "tt": 1500.0,
		"est": []},
	"pepper_red": {"base": 10.0, "opt_low": 21.0, "opt_high": 27.0, "max": 35.0,
		"frost_kill": 0.0, "lue": 2.4, "hi": 0.5, "dli_target": 22.0, "dli_min": 15.0,
		"kc": 1.05, "vpd_lo": 0.5, "vpd_hi": 1.2, "yield": 4.0, "dm": 0.078, "tt": 1500.0,
		"est": ["lue", "hi", "dli_target", "dli_min"]},
	"pepper_yellow": {"base": 10.0, "opt_low": 21.0, "opt_high": 27.0, "max": 35.0,
		"frost_kill": 0.0, "lue": 2.4, "hi": 0.5, "dli_target": 22.0, "dli_min": 15.0,
		"kc": 1.05, "vpd_lo": 0.5, "vpd_hi": 1.2, "yield": 4.0, "dm": 0.08, "tt": 1500.0,
		"est": ["lue", "hi", "dli_target", "dli_min"]},
	"zucchini": {"base": 10.0, "opt_low": 18.0, "opt_high": 27.0, "max": 35.0,
		"frost_kill": 0.0, "lue": 2.6, "hi": 0.5, "dli_target": 22.0, "dli_min": 15.0,
		"kc": 0.95, "vpd_lo": 0.5, "vpd_hi": 1.3, "yield": 6.0, "dm": 0.052, "tt": 1000.0,
		"est": ["lue", "hi", "dli_target", "dli_min"]},
	"squash": {"base": 10.0, "opt_low": 18.0, "opt_high": 27.0, "max": 35.0,
		"frost_kill": 0.0, "lue": 2.6, "hi": 0.5, "dli_target": 22.0, "dli_min": 15.0,
		"kc": 1.00, "vpd_lo": 0.5, "vpd_hi": 1.3, "yield": 3.5, "dm": 0.136, "tt": 1200.0,
		"est": ["lue", "hi", "dli_target", "dli_min"]},
	"beans": {"base": 10.0, "opt_low": 18.0, "opt_high": 26.0, "max": 32.0,
		"frost_kill": 0.0, "lue": 2.0, "hi": 0.4, "dli_target": 20.0, "dli_min": 12.0,
		"kc": 1.05, "vpd_lo": 0.5, "vpd_hi": 1.2, "yield": 2.5, "dm": 0.097, "tt": 900.0,
		"est": ["lue", "hi", "dli_target", "dli_min"]},
	"carrot": {"base": 4.0, "opt_low": 16.0, "opt_high": 21.0, "max": 30.0,
		"frost_kill": -6.0, "lue": 2.0, "hi": 0.65, "dli_target": 17.0, "dli_min": 12.0,
		"kc": 1.05, "vpd_lo": 0.4, "vpd_hi": 1.2, "yield": 4.5, "dm": 0.117, "tt": 1280.0,
		"est": ["lue", "hi", "dli_target", "dli_min"]},
	"onion": {"base": 5.0, "opt_low": 13.0, "opt_high": 24.0, "max": 32.0,
		"frost_kill": -6.0, "lue": 1.8, "hi": 0.75, "dli_target": 17.0, "dli_min": 12.0,
		"kc": 1.05, "vpd_lo": 0.4, "vpd_hi": 1.3, "yield": 4.0, "dm": 0.109, "tt": 1800.0,
		"est": ["lue", "hi", "dli_target", "dli_min"]},
	"potato": {"base": 5.0, "opt_low": 15.0, "opt_high": 20.0, "max": 30.0,
		"frost_kill": -2.0, "lue": 2.8, "hi": 0.75, "dli_target": 20.0, "dli_min": 14.0,
		"kc": 1.15, "vpd_lo": 0.4, "vpd_hi": 1.2, "yield": 4.0, "dm": 0.20, "tt": 1650.0,
		"est": ["dli_target", "dli_min"]},
	"sweet_potato": {"base": 12.0, "opt_low": 24.0, "opt_high": 30.0, "max": 38.0,
		"frost_kill": 0.0, "lue": 2.2, "hi": 0.6, "dli_target": 22.0, "dli_min": 14.0,
		"kc": 1.15, "vpd_lo": 0.6, "vpd_hi": 1.5, "yield": 3.0, "dm": 0.23, "tt": 1120.0,
		"est": ["base", "lue", "hi", "dli_target", "dli_min"]},
	"basil": {"base": 10.0, "opt_low": 21.0, "opt_high": 28.0, "max": 35.0,
		"frost_kill": 1.0, "lue": 1.8, "hi": 0.6, "dli_target": 17.0, "dli_min": 12.0,
		"kc": 1.00, "vpd_lo": 0.5, "vpd_hi": 1.2, "yield": 2.0, "dm": 0.08, "tt": 900.0,
		"est": ["lue", "hi", "dli_target", "dli_min", "kc"]},
	"willow": {"base": 5.0, "opt_low": 18.0, "opt_high": 25.0, "max": 35.0,
		"frost_kill": -30.0, "lue": 1.4, "hi": 0.85, "dli_target": 20.0, "dli_min": 10.0,
		"kc": 1.20, "vpd_lo": 0.5, "vpd_hi": 1.8, "yield": 6.0, "dm": 0.50, "tt": 16425.0,
		"est": ["base", "lue", "hi", "dli_target", "dli_min", "kc", "dm"]},
	"sorghum": {"base": 10.0, "opt_low": 27.0, "opt_high": 34.0, "max": 42.0,
		"frost_kill": -1.5, "lue": 3.0, "hi": 0.9, "dli_target": 30.0, "dli_min": 18.0,
		"kc": 1.05, "vpd_lo": 1.0, "vpd_hi": 2.5, "yield": 5.0, "dm": 0.20, "tt": 1000.0,
		"est": ["hi", "dli_target", "dli_min", "dm"]},
	GENERIC_ID: {"base": 4.0, "opt_low": 15.0, "opt_high": 22.0, "max": 30.0,
		"frost_kill": -3.0, "lue": 1.8, "hi": 0.8, "dli_target": 15.0, "dli_min": 10.0,
		"kc": 1.00, "vpd_lo": 0.4, "vpd_hi": 1.2, "yield": 3.0, "dm": 0.07, "tt": 960.0,
		"est": ["lue", "hi", "dli_target", "dli_min", "yield", "dm"]},
}


## The row for a crop id; an unknown id gets the generic leafy crop.
static func info(id: String) -> Dictionary:
	return CROPS.get(id, CROPS[GENERIC_ID]) as Dictionary


static func has(id: String) -> bool:
	return CROPS.has(id) and id != GENERIC_ID


## The beta function of Yan & Hunt (1999), 1 at t_opt:
##   ((t_max - t) / (t_max - t_opt)) * ((t - t_min) / (t_opt - t_min))^c,
##   c = (t_opt - t_min) / (t_max - t_opt). 0 outside t_min..t_max.
static func yan_hunt_beta(t: float, t_min: float, t_opt: float, t_max: float) -> float:
	if t <= t_min or t >= t_max:
		return 0.0
	var c: float = (t_opt - t_min) / (t_max - t_opt)
	var f: float = ((t_max - t) / (t_max - t_opt)) * pow((t - t_min) / (t_opt - t_min), c)
	return clampf(f, 0.0, 1.0)


## Temperature factor in [0, 1]: the Yan & Hunt beta with a plateau. The
## plateau's width w = opt_high - opt_low is taken out of the curve: below
## opt_low it is beta(t; base, opt_low, max - w), above opt_high the same
## curve at t - w. Continuous, 1 on the plateau, 0 at base and at max.
static func temp_factor(id: String, t_c: float) -> float:
	var r := info(id)
	var base: float = float(r["base"])
	var lo: float = float(r["opt_low"])
	var hi: float = float(r["opt_high"])
	var mx: float = float(r["max"])
	if t_c <= base or t_c >= mx:
		return 0.0
	if t_c >= lo and t_c <= hi:
		return 1.0
	var w: float = hi - lo
	var t_eff: float = t_c if t_c < lo else t_c - w
	return yan_hunt_beta(t_eff, base, lo, mx - w)


## Humidity factor in [0, 1] from the leaf-air vapour pressure deficit.
static func vpd_factor(id: String, vpd_kpa: float) -> float:
	var r := info(id)
	var lo: float = float(r["vpd_lo"])
	var hi: float = float(r["vpd_hi"])
	var v: float = maxf(vpd_kpa, 0.0)
	if v < lo:
		return clampf(lerpf(VPD_LOW_FLOOR, 1.0, v / lo), 0.0, 1.0)
	if v <= hi:
		return 1.0
	var s: float = clampf((v - hi) / VPD_CLOSE_SPAN_KPA, 0.0, 1.0)
	return lerpf(1.0, VPD_HIGH_FLOOR, s)


## Light factor in [0, 1]: saturating in the daily light integral,
## (1 - exp(-k dli)) / (1 - exp(-k dli_target)), k = 3 / dli_target, so 1 at
## and above the target. A growth-quality factor for the designer's readout;
## the amount of light is already in daily_growth_kg_dm through the PAR.
static func light_factor(id: String, dli: float) -> float:
	var target: float = float(info(id)["dli_target"])
	if dli <= 0.0 or target <= 0.0:
		return 0.0
	var k: float = LIGHT_K_AT_TARGET / target
	return clampf((1.0 - exp(-k * dli)) / (1.0 - exp(-k * target)), 0.0, 1.0)


## True when the light is enough for a marketable crop.
static func light_ok(id: String, dli: float) -> bool:
	return dli >= float(info(id)["dli_min"])


## Development rate, deg C day per day: the mean above base, capped at
## opt_high; 0 at or above max (no development at lethal heat).
static func thermal_time_rate(id: String, t_c: float) -> float:
	var r := info(id)
	var base: float = float(r["base"])
	if t_c >= float(r["max"]):
		return 0.0
	return maxf(0.0, minf(t_c, float(r["opt_high"])) - base)


## Thermal time to maturity, deg C day.
static func maturity_tt(id: String) -> float:
	return float(info(id)["tt"])


## Share of the plants a night at t_c kills, 0..1 (0.5 at frost_kill).
static func frost_damage(id: String, t_c: float) -> float:
	var kill: float = float(info(id)["frost_kill"])
	return clampf(0.5 + (kill - t_c) / FROST_SPAN_C, 0.0, 1.0)


## Dry matter grown in one day, kg: LUE x PAR x area x the temperature,
## humidity, water and nutrient factors. par_mj_m2 = PAR MJ/m2 that day.
static func daily_growth_kg_dm(id: String, par_mj_m2: float, area_m2: float, t_mean_c: float,
		vpd_kpa: float, water_f: float = 1.0, nutrient_f: float = 1.0) -> float:
	var lue: float = float(info(id)["lue"])
	var g: float = lue * maxf(par_mj_m2, 0.0) * maxf(area_m2, 0.0)
	g *= temp_factor(id, t_mean_c) * vpd_factor(id, vpd_kpa)
	g *= clampf(water_f, 0.0, 1.0) * clampf(nutrient_f, 0.0, 1.0)
	return g / 1000.0


## Fresh edible yield (kg) from total dry matter (kg).
static func fresh_yield_from_dm(id: String, dm_kg: float) -> float:
	var r := info(id)
	return maxf(dm_kg, 0.0) * float(r["hi"]) / maxf(float(r["dm"]), 0.001)


## Crop water use, L/m2/day = mm/day: Kc x ET0 (FAO-56 single crop
## coefficient), Kc rising from bare soil (KC_SOIL) to Kc mid with the share
## of full canopy cover.
static func transpiration_l_m2_day(id: String, et0_mm: float, lai_share: float = 1.0) -> float:
	var kc_mid: float = float(info(id)["kc"])
	var kc: float = lerpf(KC_SOIL, kc_mid, clampf(lai_share, 0.0, 1.0))
	return kc * maxf(et0_mm, 0.0)


## DLI (mol/m2/day) from PAR energy (MJ/m2/day), sunlight spectrum.
static func dli_from_par_mj(par_mj_m2: float) -> float:
	return maxf(par_mj_m2, 0.0) * MOL_PER_MJ_PAR


## Air VPD (kPa) from temperature and relative humidity (0..100), Tetens
## saturation pressure as in FAO-56 eq. 11.
static func vpd_kpa(t_c: float, rh_pct: float) -> float:
	var es: float = 0.6108 * exp(17.27 * t_c / (t_c + 237.3))
	return maxf(0.0, es * (1.0 - clampf(rh_pct, 0.0, 100.0) / 100.0))


## Crop ids in the table (without the generic fallback).
static func ids() -> Array:
	var out: Array = []
	for k in CROPS.keys():
		if str(k) != GENERIC_ID:
			out.append(str(k))
	return out
