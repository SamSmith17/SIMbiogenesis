class_name VehicleEnergy
extends RefCounted

## Road load → fuel or electricity, for a solved living vehicle (pure).
##
##   F = m·g·C_rr + ½·ρ·C_d·A·v²                      (Gillespie, "Fundamentals
##   fuel energy per metre = (F + P_acc / v) / η        of Vehicle Dynamics", ch. 4)
##
## C_rr by weight class: light-truck tyres 0.008–0.012 (we take 0.0095),
## medium-duty 0.0075, Class 8 0.0065 (US EPA SmartWay tyre testing ~0.0065 for
## standard line-haul tyres). ρ = 1.225 kg/m³ (ISA sea level). A = the frontal
## box W × H times SHAPE_FILL (the gap under the body and the rounded edges).
## η = on-road average brake efficiency × drivetrain: well under a modern
## engine's peak (gasoline ~35 %, diesel ~45 %; Heywood, "Internal Combustion
## Engine Fundamentals") because a road load is mostly part load.
## Lower heating values: gasoline 32.0 MJ/L (E10 ~31.5), diesel 35.8 MJ/L
## (US DOE Alternative Fuels Data Center, fuel properties comparison).
## EV: battery-to-wheel 0.82 (motor + inverter + gearbox), regen ignored at a
## steady cruise. P_acc: alternator, fans, power steering — 1.2 kW light,
## 2.5 kW heavy.
## vehiclelab_selftest holds every chassis preset's default vehicle inside the
## owner-reported mpg band VehicleCatalog quotes (at 55 mph).

const G := 9.80665
const RHO_AIR := 1.225
const SHAPE_FILL := 0.88
const LHV_GASOLINE_MJ_L := 32.0
const LHV_DIESEL_MJ_L := 35.8
const ETA_GASOLINE := 0.215
const ETA_DIESEL := 0.27
const ETA_EV := 0.82
const MPS_55MPH := 24.587
const MI_M := 1609.344


static func crr_for(mass_kg: float) -> float:
	if mass_kg < 5500.0:
		return 0.0095
	if mass_kg < 12000.0:
		return 0.0075
	return 0.0065


static func accessory_w(mass_kg: float) -> float:
	return 1200.0 if mass_kg < 8000.0 else 2500.0


## Force at the wheels to hold `v` (m/s) on the level.
static func road_load_n(mass_kg: float, cd: float, area_m2: float, v: float) -> float:
	return mass_kg * G * crr_for(mass_kg) + 0.5 * RHO_AIR * cd * area_m2 * v * v


## Energy drawn from the tank or the battery per metre at `v`, in joules.
static func source_j_per_m(mass_kg: float, cd: float, area_m2: float, v: float, fuel: String) -> float:
	var vv := maxf(v, 4.0)
	var f := road_load_n(mass_kg, cd, area_m2, vv) + accessory_w(mass_kg) / vv
	match fuel:
		"diesel":
			return f / ETA_DIESEL
		"electric":
			return f / ETA_EV
		"none":
			return 0.0
	return f / ETA_GASOLINE


## {l_per_km, kwh_per_km, mpg, mi_per_kwh} at `v` for a solved design
## (VehicleDesign.solve): the laden mass, its drag and its fuel.
static func at_speed(d: Dictionary, v: float) -> Dictionary:
	var mass := float(d.get("laden_kg", 3000.0))
	var cd := float(d.get("cd", 0.6))
	var area := float(d.get("frontal_m2", 6.0))
	var fuel := str(d.get("fuel", "gasoline"))
	var j := source_j_per_m(mass, cd, area, v, fuel)
	var out := {"fuel": fuel, "l_per_km": 0.0, "kwh_per_km": 0.0, "mpg": 0.0, "mi_per_kwh": 0.0}
	if fuel == "electric":
		var kwh_km := j * 1000.0 / 3.6e6
		out["kwh_per_km"] = kwh_km
		out["mi_per_kwh"] = 1000.0 / MI_M / kwh_km if kwh_km > 0.0 else 0.0
	elif fuel == "gasoline" or fuel == "diesel":
		var lhv := LHV_DIESEL_MJ_L if fuel == "diesel" else LHV_GASOLINE_MJ_L
		var l_km := j * 1000.0 / (lhv * 1.0e6)
		out["l_per_km"] = l_km
		# miles per km over gallons per km.
		out["mpg"] = (1000.0 / MI_M) / (l_km / VehicleCatalog.GAL) if l_km > 0.0 else 0.0
	return out


## The cost of getting it to site: one-way miles typed by the player, there
## and back at a 55 mph cruise, at the spec's fuel / electricity price.
static func trip(d: Dictionary, one_way_mi: float, round_trip: bool = true) -> Dictionary:
	var e := at_speed(d, MPS_55MPH)
	var km := maxf(one_way_mi, 0.0) * MI_M / 1000.0 * (2.0 if round_trip else 1.0)
	var trip_d: Dictionary = d.get("trip", {})
	var out := {"km": km, "mi": km * 1000.0 / MI_M, "fuel": e["fuel"], "litres": 0.0,
		"gallons": 0.0, "kwh": 0.0, "cost": 0.0, "range_km": 0.0}
	if str(e["fuel"]) == "electric":
		out["kwh"] = km * float(e["kwh_per_km"])
		out["cost"] = float(out["kwh"]) * float(trip_d.get("kwh_price", 0.35))
		if float(e["kwh_per_km"]) > 0.0:
			out["range_km"] = float(d.get("battery_kwh", 0.0)) / float(e["kwh_per_km"])
	elif float(e["l_per_km"]) > 0.0:
		out["litres"] = km * float(e["l_per_km"])
		out["gallons"] = float(out["litres"]) / VehicleCatalog.GAL
		out["cost"] = float(out["gallons"]) * float(trip_d.get("fuel_price_per_gal", 4.5))
		out["range_km"] = float(d.get("tank_l", 0.0)) / float(e["l_per_km"])
	return out
