class_name WaterSteam
extends RefCounted

## Water → steam at about 1 atm: the one boil-off budget shared by the CSP
## concentrators (CspTroughSource, HeliostatSource) and the TC Process Lab.
##
## Energy per kg boiled = sensible heat to the boiling point (cp of liquid
## water 4.186 kJ/kg·K) + the latent heat of vaporization (h_fg 2257 kJ/kg,
## steam tables at 100 °C / 101.325 kPa).

const CP_WATER_KJ_PER_KG_K := 4.186
const H_FG_KJ_PER_KG := 2257.0
const BOILING_POINT_C := 100.0
const WATER_DENSITY_KG_PER_L := 1.0


## kJ to take one kg of feedwater at `feedwater_c` to steam at 100 °C.
static func boiloff_kj_per_kg(feedwater_c: float) -> float:
	return CP_WATER_KJ_PER_KG_K * (BOILING_POINT_C - feedwater_c) + H_FG_KJ_PER_KG


## Steam made (kg/h) from `thermal_kw` of useful heat into feedwater at
## `feedwater_c`.
static func steam_kg_h(thermal_kw: float, feedwater_c: float) -> float:
	return thermal_kw / maxf(boiloff_kj_per_kg(feedwater_c), 1.0) * 3600.0
