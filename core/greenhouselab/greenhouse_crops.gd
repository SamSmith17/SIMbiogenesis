class_name GreenhouseCrops
extends RefCounted

## The crops in a greenhouse's beds, grown day by day from the climate the
## house makes (pure). Each bed's area is split between the crops of its mix
## by share; each crop runs one cycle after another:
##  - development in thermal time: CropPhysiology.thermal_time_rate on the
##    day's mean inside temperature, until maturity_tt;
##  - growth: CropPhysiology.daily_growth_kg_dm on the day's PAR (sun through
##    the glazing, plus the grow lights over a lit bed), the mean temperature
##    and VPD, times the canopy cover (it closes over the first COVER_TT_SHARE
##    of the cycle: daily_growth_kg_dm assumes a closed canopy) and the share
##    of the stand still alive;
##  - frost: each day's coldest inside hour kills CropPhysiology.frost_damage
##    of the plants; below LOST_STAND the planting is lost and resown;
##  - harvest at maturity: fresh_yield_from_dm, capped at YIELD_CAP × the
##    table's realistic per-cycle yield (an estimate: LUE × PAR with a closed
##    canopy overstates what a bed gives), then FALLOW_D days to resow.
## Nothing here touches the climate; GreenhouseYear and the flow engine call
## `day` once per day with what the climate model measured.

const COVER_TT_SHARE := 0.45
const COVER_MIN := 0.08
const LOST_STAND := 0.25
const YIELD_CAP := 1.5
const FALLOW_D := 4
## Canopy LAI at full cover (for the climate's transpiration), a vegetable
## crop's typical 3 (FAO-56).
const LAI_FULL := 3.0


## A fresh planting of every bed of a solved design.
static func new_state(d: Dictionary) -> Dictionary:
	var plots: Array = []
	for b in d.get("beds", []):
		var bd: Dictionary = b
		var area := float(bd.get("area_m2", 0.0))
		if area <= 0.0:
			continue
		var mix: Variant = bd.get("crops", "garden")
		var shares := {}
		if mix is Array:
			var tot := 0.0
			for e in mix:
				tot += float((e as Dictionary).get("share", 1.0))
			for e in mix:
				var id := str((e as Dictionary)["crop"])
				shares[id] = float(shares.get(id, 0.0)) + float((e as Dictionary).get("share", 1.0)) / maxf(tot, 1e-6)
		else:
			var ids := GreenhouseSpec.mix_crops(mix)
			for id in ids:
				shares[str(id)] = float(shares.get(str(id), 0.0)) + 1.0 / float(ids.size())
		for id in shares:
			var i := plots.size()
			plots.append({"bed": str(bd.get("id", "")), "crop": str(id), "area": area * float(shares[id]),
				"lit": bd.has("light"), "tt": 0.0, "dm": 0.0, "stand": 1.0, "fallow": 0,
				# Stagger the starts so a mixed bed is not all bare at once.
				"tt_start": 0.0 if i % 2 == 0 else 0.3})
	for p in plots:
		var pd: Dictionary = p
		pd["tt"] = float(pd["tt_start"]) * CropPhysiology.maturity_tt(str(pd["crop"]))
	return {"plots": plots, "harvest": {}, "harvest_kg": 0.0, "lost": 0, "cycles": 0, "frost_days": 0,
		"growth_kg_dm": 0.0}


## Canopy cover 0..1 of one planting.
static func cover(p: Dictionary) -> float:
	if int(p["fallow"]) > 0:
		return 0.0
	var mat := maxf(CropPhysiology.maturity_tt(str(p["crop"])), 1.0)
	return clampf(COVER_MIN + (1.0 - COVER_MIN) * float(p["tt"]) / (COVER_TT_SHARE * mat), COVER_MIN, 1.0) * float(p["stand"])


## The beds' canopy LAI, area-weighted (what the climate transpires through).
static func lai(st: Dictionary) -> float:
	var a := 0.0
	var l := 0.0
	for p in st["plots"]:
		a += float(p["area"])
		l += float(p["area"]) * cover(p) * LAI_FULL
	return l / a if a > 0.0 else 0.0


## One day. day: {t_mean, t_min, vpd, dli_sun, dli_lit} (mol/m²/day; a lit
## bed gets dli_lit), water_f / nutrient_f 0..1. Returns the fresh kg
## harvested today by crop id.
static func day(st: Dictionary, dy: Dictionary, water_f: float = 1.0, nutrient_f: float = 1.0) -> Dictionary:
	var out := {}
	var t_mean := float(dy.get("t_mean", 18.0))
	var t_min := float(dy.get("t_min", t_mean))
	var vpd := float(dy.get("vpd", 0.8))
	var frost := false
	for p in st["plots"]:
		var pd: Dictionary = p
		var id := str(pd["crop"])
		if int(pd["fallow"]) > 0:
			pd["fallow"] = int(pd["fallow"]) - 1
			continue
		var dmg := CropPhysiology.frost_damage(id, t_min)
		if dmg > 0.0:
			frost = true
			pd["stand"] = float(pd["stand"]) * (1.0 - dmg)
			if float(pd["stand"]) < LOST_STAND:
				st["lost"] = int(st["lost"]) + 1
				_resow(pd)
				continue
		var dli := float(dy.get("dli_lit", 0.0)) if bool(pd["lit"]) else float(dy.get("dli_sun", 0.0))
		var par := dli / CropPhysiology.MOL_PER_MJ_PAR
		var g := CropPhysiology.daily_growth_kg_dm(id, par, float(pd["area"]), t_mean, vpd, water_f, nutrient_f) * cover(pd)
		pd["dm"] = float(pd["dm"]) + g
		st["growth_kg_dm"] = float(st["growth_kg_dm"]) + g
		pd["tt"] = float(pd["tt"]) + CropPhysiology.thermal_time_rate(id, t_mean)
		if float(pd["tt"]) >= CropPhysiology.maturity_tt(id):
			var kg := minf(CropPhysiology.fresh_yield_from_dm(id, float(pd["dm"])),
				YIELD_CAP * float(CropPhysiology.info(id)["yield"]) * float(pd["area"]) * float(pd["stand"]))
			out[id] = float(out.get(id, 0.0)) + kg
			st["harvest"][id] = float(st["harvest"].get(id, 0.0)) + kg
			st["harvest_kg"] = float(st["harvest_kg"]) + kg
			st["cycles"] = int(st["cycles"]) + 1
			_resow(pd)
	if frost:
		st["frost_days"] = int(st["frost_days"]) + 1
	return out


static func _resow(pd: Dictionary) -> void:
	pd["tt"] = 0.0
	pd["dm"] = 0.0
	pd["stand"] = 1.0
	pd["fallow"] = FALLOW_D


## How far through its cycle each bed's crops are (0..1), by bed id: the
## mean over its plantings. For drawing a bed's crops at the right size.
static func progress_by_bed(st: Dictionary) -> Dictionary:
	var sum := {}
	var n := {}
	for p in st["plots"]:
		var b := str(p["bed"])
		var f := 0.0 if int(p["fallow"]) > 0 else clampf(float(p["tt"]) / maxf(CropPhysiology.maturity_tt(str(p["crop"])), 1.0), 0.0, 1.0)
		sum[b] = float(sum.get(b, 0.0)) + f
		n[b] = int(n.get(b, 0)) + 1
	var out := {}
	for b in sum:
		out[b] = float(sum[b]) / float(n[b])
	return out
