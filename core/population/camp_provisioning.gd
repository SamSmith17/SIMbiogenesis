class_name CampProvisioning
extends RefCounted

## Starting supplies for a camp, from its headcount: the combined consumption
## a group generates, how much to stock so it runs for a preset number of
## days without the player wiring any infrastructure, and the spaces it
## would need for every need to be met without queues. Pure static — the
## camp templates, the inspector's "Provision" action and the selftest all
## read the SAME numbers, so a camp provisioned for a weekend lasts a weekend.
##
## Rates are the habitat preset's nominal per-person rates (×24): the same
## 2.083 L/h water and 0.0625 kg/h food every habitat node carries. The
## population tiers bill by ACTIVITY, so a real day lands near but not on
## these (the Walton harness measured ~49 L water/person/day); `margin` is
## what absorbs that plus a hot afternoon.

## Per person per day. Sources: habitat preset rates ×24 (water 2.083 L/h,
## food 0.0625 kg/h, greywater 1.666 L/h, blackwater 0.417 L/h, firewood
## 0.0125 kg/h + a fire circle's 0.6 kg/h share).
const RATES_PER_PERSON_DAY: Dictionary = {
	"water": 50.0,       # L
	"food": 1.5,         # kg
	"biomass": 0.5,      # kg firewood (an evening fire's share)
	"greywater": 40.0,   # L
	"blackwater": 10.0,  # L
}
const SUPPLY_KINDS: Array = ["water", "food", "biomass"]
const WASTE_KINDS: Array = ["greywater", "blackwater"]
const UNITS: Dictionary = {"water": "L", "food": "kg", "biomass": "kg", "greywater": "L", "blackwater": "L"}

## Duration presets. `margin` over-stocks the supplies (and sizes the waste
## tanks) so the camp outlasts the nominal days by that factor.
const PRESETS: Dictionary = {
	"bare": {"label": "Bare (1 day)", "days": 1.0, "margin": 1.1},
	"weekend": {"label": "Weekend (3 days)", "days": 3.0, "margin": 1.25},
	"week": {"label": "Week (7 days)", "days": 7.0, "margin": 1.25},
	"fortnight": {"label": "Fortnight (14 days)", "days": 14.0, "margin": 1.2},
}
const PRESET_ORDER: Array = ["bare", "weekend", "week", "fortnight"]

## Space sizing assumptions (see requirements()). A routine block spreads a
## camp's visits over ±NpcRoutine.MAX_PHASE_OFFSET_H, so a visit of V hours
## by N people inside a window of W hours needs N·V/W simultaneous slots.
const KITCHEN_VISIT_H := 0.5
const KITCHEN_WINDOW_H := 1.0
const SHOWER_VISIT_H := 0.2
const SHOWER_WINDOW_H := 0.5
const WATER_VISIT_H := 0.1
const WATER_WINDOW_H := 1.0
const PEAK_FACTOR := 1.3


static func preset(id: String) -> Dictionary:
	return (PRESETS.get(id, PRESETS["weekend"]) as Dictionary).duplicate()


static func preset_label(id: String) -> String:
	return str(preset(id).get("label", id))


## Combined consumption of `headcount` people, per hour, per kind.
static func rates_per_hour(headcount: int) -> Dictionary:
	var out := {}
	var n := float(maxi(headcount, 0))
	for k in RATES_PER_PERSON_DAY:
		out[k] = float(RATES_PER_PERSON_DAY[k]) * n / 24.0
	return out


## Combined consumption per day, per kind.
static func rates_per_day(headcount: int) -> Dictionary:
	var out := {}
	var n := float(maxi(headcount, 0))
	for k in RATES_PER_PERSON_DAY:
		out[k] = float(RATES_PER_PERSON_DAY[k]) * n
	return out


## What to stock: {kind: {capacity, stock, unit, days}} — supplies full,
## waste tanks empty, both sized for the preset's days × margin.
static func supply(headcount: int, preset_id: String = "weekend") -> Dictionary:
	var p := preset(preset_id)
	var days := float(p.get("days", 3.0))
	var margin := float(p.get("margin", 1.25))
	var daily := rates_per_day(headcount)
	var out := {}
	for k in SUPPLY_KINDS:
		var cap := snappedf(float(daily[k]) * days * margin, 0.5)
		out[k] = {"capacity": cap, "stock": cap, "unit": str(UNITS[k]), "days": days}
	for k in WASTE_KINDS:
		var cap := snappedf(float(daily[k]) * days * margin, 0.5)
		out[k] = {"capacity": cap, "stock": 0.0, "unit": str(UNITS[k]), "days": days}
	return out


## How long the supplies in `stocks` ({kind: qty}) last `headcount` people:
## the tightest supply kind, in days (INF with no demand or nothing listed).
static func days_remaining(stocks: Dictionary, headcount: int) -> float:
	var daily := rates_per_day(headcount)
	var worst := INF
	for k in SUPPLY_KINDS:
		if not stocks.has(k):
			continue
		var d := float(daily.get(k, 0.0))
		if d <= 1e-9:
			continue
		worst = minf(worst, float(stocks[k]) / d)
	return worst


## The spaces `headcount` people need so nobody queues: simultaneous slots
## per space type, from each need's visit length against the routine window
## its visits are spread over, × PEAK_FACTOR. Portapotty banks: 2 slots per
## unit (the SpaceRegistry capacity convention a bank is tagged with).
static func requirements(headcount: int) -> Dictionary:
	var n := float(maxi(headcount, 0))
	var window := 2.0 * NpcRoutine.MAX_PHASE_OFFSET_H
	var slots := func(visit_h: float, win_h: float) -> int:
		return int(ceil(n * visit_h / maxf(win_h, 0.05) * PEAK_FACTOR)) if n > 0.0 else 0
	var restroom: int = slots.call(NpcRoutine.BATHROOM_HOURS, window)
	return {
		"restroom_slots": restroom,
		"portapotty_units": int(ceil(float(restroom) / 2.0)),
		"kitchen_seats": slots.call(KITCHEN_VISIT_H, KITCHEN_WINDOW_H),
		"shower_slots": slots.call(SHOWER_VISIT_H, SHOWER_WINDOW_H),
		"water_point_taps": slots.call(WATER_VISIT_H, WATER_WINDOW_H),
		"beds": int(n),
		"water_l_day": float(RATES_PER_PERSON_DAY["water"]) * n,
		"food_kg_day": float(RATES_PER_PERSON_DAY["food"]) * n,
		"blackwater_l_day": float(RATES_PER_PERSON_DAY["blackwater"]) * n,
		"greywater_l_day": float(RATES_PER_PERSON_DAY["greywater"]) * n,
	}


## One line for a panel: "3 d of water · 7 d of food".
static func stock_summary(stocks: Dictionary, headcount: int) -> String:
	var daily := rates_per_day(headcount)
	var bits := PackedStringArray()
	for k in SUPPLY_KINDS:
		if not stocks.has(k) or float(daily.get(k, 0.0)) <= 1e-9:
			continue
		bits.append("%.1f d of %s" % [float(stocks[k]) / float(daily[k]), str(k)])
	return " · ".join(bits)
