class_name TerraceFarm
extends RefCounted

## The farm work of a terrace field, paddy by paddy (pure static). Each paddy
## goes round a season: PREP (dig or plough the floor, mend the bund, puddle
## it), PLANT (transplant or sow), GROW (four rounds of TENDING: weeding,
## mending bunds, keeping the water right; a round that is not done before the
## next is due costs yield), RIPE / HARVEST (cut, carry, thresh; what waits
## too long shatters and is lost), then PREP again. Perennials (reeds,
## willow) are planted once and regrow after each cut.
##
## Every job has its person-hours, from the crop's hours per hectare and the
## paddy's area. Who does it is the field's `labour`:
##   people   — the camp's crews do it (TerraceRuntime puts each job on the
##              chore board; the engine hears how far it got through
##              `credit`), at about 80 W of useful work a person;
##   machines — a small machine and its operator (power tiller, transplanter,
##              walking reaper), far fewer hours but fuel;
##   free     — done the moment it is due (a sandbox, and the old behaviour).
## The ledger counts the hours, the work energy, the food that work costs and
## the fuel, so manual farming, machines and a FarmBot can be compared.
##
## HOURS. Person-hours per hectare for each job are estimates in the ranges
## IRRI and FAO give for small farms in Asia: transplanted rice by hand is
## ~900–1,500 h/ha a season (land preparation 200–400, transplanting 200–300,
## weeding and water 150–350, harvest and threshing 250–400). The rest are
## scaled from smallholder labour surveys; treat them as estimates.

const PlantGrowthScript := preload("res://system_graph/plant_growth.gd")

const TASKS := ["prep", "plant", "tend", "harvest"]
const TASK_LABELS := {"prep": "Prepare", "plant": "Plant", "tend": "Tend", "harvest": "Harvest"}
const TASK_VERBS := {"prep": "Prepare the beds", "plant": "Plant", "tend": "Weed and tend",
	"harvest": "Harvest"}
## Words per crop for the jobs (what a crew is doing).
const CROP_VERBS := {
	"rice": {"prep": "Puddle the paddy", "plant": "Transplant rice", "tend": "Weed the rice",
		"harvest": "Cut and thresh rice"},
	"reed": {"plant": "Plant reed rhizomes", "tend": "Clear the reed bed", "harvest": "Cut reeds"},
	"taro": {"prep": "Dig the taro bed", "plant": "Plant taro", "tend": "Weed the taro",
		"harvest": "Lift taro"},
	"willow": {"plant": "Plant willow cuttings", "tend": "Weed the willow", "harvest": "Cut the coppice"},
}

## Person-hours per hectare per job (by hand). `tend` is the whole season.
const LABOUR := {
	"rice": {"prep": 300.0, "plant": 250.0, "tend": 300.0, "harvest": 350.0},
	"taro": {"prep": 300.0, "plant": 200.0, "tend": 300.0, "harvest": 300.0},
	"potato": {"prep": 200.0, "plant": 150.0, "tend": 250.0, "harvest": 300.0},
	"sweet_potato": {"prep": 200.0, "plant": 150.0, "tend": 200.0, "harvest": 300.0},
	"sorghum": {"prep": 200.0, "plant": 60.0, "tend": 150.0, "harvest": 200.0},
	"beans": {"prep": 200.0, "plant": 80.0, "tend": 200.0, "harvest": 250.0},
	"reed": {"prep": 0.0, "plant": 400.0, "tend": 20.0, "harvest": 200.0},
	"willow": {"prep": 0.0, "plant": 300.0, "tend": 30.0, "harvest": 300.0},
	"fallow": {"prep": 0.0, "plant": 0.0, "tend": 0.0, "harvest": 0.0},
}
const PERENNIAL := ["reed", "willow"]

## Machines: the operator's hours as a share of the hand hours, and the fuel
## the machine burns while it works (L/h). Power tiller ~25–40 h/ha; walking
## transplanter ~10–15 h/ha with a helper; reaper / small thresher ~25 h/ha.
## Tending is mostly still by hand.
## The tractor (the game's own: vehicle_tractor) does the heavy jobs: a
## rotary tiller puddles the paddy (~0.2 ha/h, two passes: ~5 % of the hand
## hours), a reaper cuts the crop (~15 % with the threshing). Planting and
## weeding stay with the crew.
const MACHINE := {
	"prep": {"share": 0.05, "fuel_lph": 4.0, "machine": "tractor and rotary tiller"},
	"harvest": {"share": 0.15, "fuel_lph": 3.5, "machine": "tractor and reaper"},
}
const MACHINE_MODEL := "vehicle_tractor"
## How wide the tractor works a pass (m): it drives up and down the paddy.
const PASS_W_M := 1.6
## Crew sizes per job: the fewest who can do it together, and the most.
const CREW := {"prep": [1, 6], "plant": [2, 12], "tend": [1, 4], "harvest": [2, 12]}
## People per square metre of plot a crew uses at most.
const M2_PER_WORKER := 40.0

## The share of the cycle each tending round falls due.
const TEND_AT := [0.12, 0.3, 0.5, 0.7]
## What a missed round leaves of the yield.
const MISSED_YIELD := 0.85
## Days a ripe crop waits without loss, then the share lost per day.
const RIPE_GRACE_D := 7.0
const SHATTER_PER_D := 0.015

## Useful work one person does in an hour of farm labour (Wh). Food energy
## eaten for it, at about 25 % muscle efficiency.
const WORK_WH_PER_H := 80.0
const MUSCLE_EFF := 0.25
## Diesel's energy (kWh/L).
const DIESEL_KWH_L := 9.9

## A modelled crew's effective hours a person-hour (morale, weather, the
## walk out: an estimate; the live crews' own productivity is NpcMorale's).
const CREW_RATE := 0.8

## When machines and free work happen (hour of day).
const DAY_START_H := 7.0
const DAY_END_H := 18.0

const STAGE_UNBUILT := "unbuilt"
const STAGE_PREP := "prep"
const STAGE_PLANT := "plant"
const STAGE_GROW := "grow"
const STAGE_HARVEST := "harvest"
const STAGE_FALLOW := "fallow"


static func hours_per_ha(crop: String, task: String) -> float:
	return float((LABOUR.get(crop, LABOUR["fallow"]) as Dictionary).get(task, 0.0))


static func is_perennial(crop: String) -> bool:
	return PERENNIAL.has(crop)


static func job_verb(crop: String, task: String) -> String:
	var v: Dictionary = CROP_VERBS.get(crop, {})
	return str(v.get(task, TASK_VERBS.get(task, task)))


## Person-hours (by hand) a job takes on a plot of `area_m2`. A tending ROUND
## is a quarter of the season's tending.
static func job_hours(crop: String, task: String, area_m2: float) -> float:
	var h := hours_per_ha(crop, task) * area_m2 / 10000.0
	if task == "tend":
		h /= float(TEND_AT.size())
	return h


## [fewest, most] people on a job on a plot this size.
static func crew_for(task: String, area_m2: float) -> Array:
	var c: Array = CREW.get(task, [1, 4])
	var most := clampi(int(ceil(area_m2 / M2_PER_WORKER)), int(c[0]), int(c[1]))
	return [mini(int(c[0]), most), most]


## A fresh farm state for a paddy table.
static func fresh(table: Array) -> Dictionary:
	var ps: Array = []
	for i in table.size():
		ps.append(_paddy_fresh(str((table[i] as Array)[6]) if (table[i] as Array).size() > 6 else "fallow"))
	return {"p": ps, "seq": 1, "ledger": empty_ledger()}


static func empty_ledger() -> Dictionary:
	return {"labour": {"prep": 0.0, "plant": 0.0, "tend": 0.0, "harvest": 0.0},
		"op_h": 0.0, "fuel_l": 0.0, "food_kg": 0.0, "biomass_kg": 0.0, "straw_kg": 0.0,
		"missed": 0, "lost_kg": 0.0, "seasons": 0}


static func _paddy_fresh(crop: String) -> Dictionary:
	return {"st": STAGE_PREP, "seq": 0, "task": "", "need": 0.0, "frac": 0.0, "sow": -1.0,
		"tend": 0, "yf": 1.0, "kg": 0.0, "rk": 0.0, "est": false, "ripe": -1.0,
		"crop": crop, "out": 0.0}


## Match a saved state to a (possibly re-cut) table: paddies keep their state
## by index; a paddy whose crop changed starts again from preparing.
static func fit(fs: Dictionary, table: Array) -> Dictionary:
	var out := fs.duplicate(true) if not fs.is_empty() else fresh(table)
	var ps: Array = out.get("p", []) as Array
	if ps.size() > table.size():
		ps.resize(table.size())
	while ps.size() < table.size():
		ps.append(_paddy_fresh(str((table[ps.size()] as Array)[6]) if (table[ps.size()] as Array).size() > 6 else "fallow"))
	for i in table.size():
		var row: Array = table[i]
		var crop := str(row[6]) if row.size() > 6 else "fallow"
		var p: Dictionary = ps[i]
		if str(p.get("crop", "")) != crop:
			var was_kg := float(p.get("kg", 0.0))
			ps[i] = _paddy_fresh(crop)
			(out["ledger"] as Dictionary)["lost_kg"] = float((out["ledger"] as Dictionary).get("lost_kg", 0.0)) + was_kg
	out["p"] = ps
	if not out.has("ledger"):
		out["ledger"] = empty_ledger()
	if not out.has("seq"):
		out["seq"] = 1
	return out


## One step of the farm work. `env`:
##   labour   — "people" | "machines" | "free"
##   hour     — hour of day (machines and free work only by day)
##   par_wm2  — PAR on the field
##   month    — 1..12
##   wf       — water factor per paddy (Array of float)
##   built    — per paddy: is it built (Array of bool), else every one is
##   credit   — {"<paddy>": [seq, frac]} from the crews (people)
##   fuel_ok  — false when the diesel store is dry: the tractor stops
##   crews    — true where no live crew can work (a pre-render, an A/B run,
##              simkit): people's jobs move on at a modelled crew's pace,
##              CREW_RATE effective hours a person-hour, the job's full crew,
##              by day
## Returns {fs, food_kg, biomass_kg, straw_kg (this step's harvest, to be
## delivered), labour_h, op_h, fuel_l, grown_kg_h}.
static func step(table: Array, fs_in: Dictionary, abs_h: float, dt_h: float, env: Dictionary) -> Dictionary:
	var fs := fit(fs_in, table)
	var ps: Array = fs["p"]
	var led: Dictionary = fs["ledger"]
	var labour := str(env.get("labour", "people"))
	var hour := float(env.get("hour", 12.0))
	var by_day := hour >= DAY_START_H and hour < DAY_END_H
	var par := float(env.get("par_wm2", 0.0))
	var month := int(env.get("month", 6))
	var wfs: Array = env.get("wf", []) as Array
	var built: Array = env.get("built", []) as Array
	var credit: Dictionary = env.get("credit", {}) as Dictionary
	var fuel_ok := bool(env.get("fuel_ok", true))
	var modelled := bool(env.get("crews", false))
	# One tractor: it works one paddy at a time (the one already under way,
	# else the first that wants it).
	var tractor_on := -1
	if labour == "machines":
		for i0 in mini(ps.size(), table.size()):
			var p0: Dictionary = ps[i0]
			if MACHINE.has(str(p0.get("task", ""))) and float(p0.get("frac", 0.0)) > 0.0:
				tractor_on = i0
				break
	var food := 0.0
	var bio := 0.0
	var straw := 0.0
	var lab_h := 0.0
	var op_h := 0.0
	var fuel := 0.0
	var grown := 0.0
	for i in table.size():
		var row: Array = table[i]
		var area := float(row[0])
		var crop := str(row[6]) if row.size() > 6 else "fallow"
		var info := TerraceField.crop_info(crop)
		var p: Dictionary = ps[i]
		if i < built.size() and not bool(built[i]):
			p["st"] = STAGE_UNBUILT
			p["task"] = ""
			continue
		if str(p["st"]) == STAGE_UNBUILT:
			p["st"] = STAGE_PREP
		if crop == "fallow" or area <= 0.0:
			p["st"] = STAGE_FALLOW
			p["task"] = ""
			continue
		# --- Growing ---
		if str(p["st"]) == STAGE_GROW:
			var cyc_h := float(info["cycle_d"]) * 24.0
			var f := clampf((abs_h - float(p["sow"])) / maxf(cyc_h, 1.0), 0.0, 1.0)
			if f > TerraceField.FALLOW:
				var wf := float(wfs[i]) if i < wfs.size() else 1.0
				var g := PlantGrowthScript.biomass_kg_per_hour(par, area, float(info["lue"]),
					month, wf, 1.0, 1.0, -1.0)
				p["kg"] = float(p["kg"]) + g * dt_h
				grown += g
			# Tending rounds fall due through the season; one left undone when
			# the next comes due is missed.
			var k := int(p["tend"])
			if k < TEND_AT.size() and f >= float(TEND_AT[k]):
				if str(p["task"]) != "tend":
					_start_job(fs, p, "tend", job_hours(crop, "tend", area))
				elif k + 1 < TEND_AT.size() and f >= float(TEND_AT[k + 1]):
					p["yf"] = float(p["yf"]) * MISSED_YIELD
					led["missed"] = int(led["missed"]) + 1
					p["tend"] = k + 1
					_start_job(fs, p, "tend", job_hours(crop, "tend", area))
			if f >= 1.0:
				p["st"] = STAGE_HARVEST
				p["ripe"] = abs_h
				p["rk"] = float(p["kg"])
				_start_job(fs, p, "harvest", job_hours(crop, "harvest", area))
		else:
			_ensure_job(fs, p, crop, area, abs_h)
		# A ripe crop waiting to be cut shatters.
		if str(p["st"]) == STAGE_HARVEST and float(p["frac"]) <= 0.0:
			var wait_d := (abs_h - float(p["ripe"])) / 24.0
			if wait_d > RIPE_GRACE_D:
				var keep := pow(1.0 - SHATTER_PER_D, dt_h / 24.0)
				led["lost_kg"] = float(led["lost_kg"]) + float(p["rk"]) * (1.0 - keep)
				p["rk"] = float(p["rk"]) * keep
		# --- The job under way ---
		var task := str(p["task"])
		if task.is_empty():
			continue
		var need := maxf(float(p["need"]), 0.0)
		var was := float(p["frac"])
		var now := was
		var by_machine := labour == "machines" and MACHINE.has(task)
		match "free" if labour == "free" else ("machines" if by_machine else "people"):
			"free":
				now = 1.0
			"machines":
				if tractor_on < 0:
					tractor_on = i
				if by_day and fuel_ok and tractor_on == i:
					var ms: Dictionary = MACHINE.get(task, {})
					var mh := need * float(ms.get("share", 1.0))
					now = 1.0 if mh <= 1e-6 else minf(was + dt_h / mh, 1.0)
					var used := (now - was) * mh
					op_h += used
					fuel += used * float(ms.get("fuel_lph", 0.0))
			_:
				var c: Variant = credit.get(str(i), null)
				if c is Array and (c as Array).size() >= 2 and int(c[0]) == int(p["seq"]):
					now = maxf(was, clampf(float(c[1]), 0.0, 1.0))
				elif modelled and by_day and need > 1e-6:
					var crew := float(crew_for(task, area)[1])
					now = minf(was + dt_h * crew * CREW_RATE / need, 1.0)
				if need <= 1e-6:
					now = 1.0
				lab_h += (now - was) * need
				(led["labour"] as Dictionary)[task] = float((led["labour"] as Dictionary).get(task, 0.0)) \
					+ (now - was) * need
		if by_machine and now > was:
			(led["labour"] as Dictionary)[task] = float((led["labour"] as Dictionary).get(task, 0.0)) \
				+ (now - was) * need * float((MACHINE.get(task, {}) as Dictionary).get("share", 1.0))
		p["frac"] = now
		# The harvest comes in as it is cut.
		if task == "harvest" and now > was:
			var kg := float(p["rk"]) * float(p["yf"]) * (now - was)
			var ff := float(info["food"])
			if ff > 0.0:
				food += kg * ff
				straw += kg * (1.0 - ff)
			else:
				bio += kg
		if now >= 0.999:
			_finish_job(fs, p, crop, abs_h)
			_ensure_job(fs, p, crop, area, abs_h)
	led["op_h"] = float(led["op_h"]) + op_h
	led["fuel_l"] = float(led["fuel_l"]) + fuel
	return {"fs": fs, "food_kg": food, "biomass_kg": bio, "straw_kg": straw,
		"labour_h": lab_h, "op_h": op_h, "fuel_l": fuel, "grown_kg_h": grown}


## A paddy being prepared or planted has its job on.
static func _ensure_job(fs: Dictionary, p: Dictionary, crop: String, area: float, abs_h: float) -> void:
	if str(p["st"]) == STAGE_PREP and str(p["task"]) != "prep":
		if is_perennial(crop) and bool(p["est"]):
			p["st"] = STAGE_GROW
			p["sow"] = abs_h
			return
		if hours_per_ha(crop, "prep") <= 0.0:
			p["st"] = STAGE_PLANT
		else:
			_start_job(fs, p, "prep", job_hours(crop, "prep", area))
	if str(p["st"]) == STAGE_PLANT and str(p["task"]) != "plant":
		_start_job(fs, p, "plant", job_hours(crop, "plant", area))


static func _start_job(fs: Dictionary, p: Dictionary, task: String, need_h: float) -> void:
	fs["seq"] = int(fs.get("seq", 1)) + 1
	p["seq"] = int(fs["seq"])
	p["task"] = task
	p["need"] = need_h
	p["frac"] = 0.0


static func _finish_job(fs: Dictionary, p: Dictionary, crop: String, abs_h: float) -> void:
	var task := str(p["task"])
	p["task"] = ""
	p["frac"] = 0.0
	p["need"] = 0.0
	match task:
		"prep":
			p["st"] = STAGE_PLANT
		"plant":
			p["st"] = STAGE_GROW
			p["sow"] = abs_h
			p["kg"] = 0.0
			p["tend"] = 0
			p["yf"] = 1.0
			p["est"] = true
		"tend":
			p["tend"] = int(p["tend"]) + 1
		"harvest":
			p["kg"] = 0.0
			p["rk"] = 0.0
			p["ripe"] = -1.0
			var led: Dictionary = fs["ledger"]
			led["seasons"] = int(led.get("seasons", 0)) + 1
			if is_perennial(crop):
				p["st"] = STAGE_GROW
				p["sow"] = abs_h
				p["tend"] = 0
				p["yf"] = 1.0
			else:
				p["st"] = STAGE_PREP


## The jobs the crews have to do now: [{paddy, seq, task, need_h, frac,
## crew_min, crew_max, verb}], for TerraceRuntime to put on the chore board.
static func open_jobs(table: Array, fs: Dictionary, labour: String = "people") -> Array:
	var out: Array = []
	var ps: Array = fs.get("p", []) as Array
	for i in mini(ps.size(), table.size()):
		var p: Dictionary = ps[i]
		var task := str(p.get("task", ""))
		if task.is_empty() or labour == "free" or (labour == "machines" and MACHINE.has(task)):
			continue
		var row: Array = table[i]
		var area := float(row[0])
		var crop := str(row[6]) if row.size() > 6 else "fallow"
		var crew := crew_for(task, area)
		out.append({"paddy": i, "seq": int(p["seq"]), "task": task,
			"need_h": float(p["need"]), "frac": float(p["frac"]),
			"crew_min": int(crew[0]), "crew_max": int(crew[1]),
			"verb": job_verb(crop, task)})
	return out


## The tractor's jobs under way: [{paddy, task, frac, machine}] (machines).
static func machine_jobs(fs: Dictionary) -> Array:
	var out: Array = []
	var ps: Array = fs.get("p", []) as Array
	for i in ps.size():
		var p: Dictionary = ps[i]
		var task := str(p.get("task", ""))
		if MACHINE.has(task):
			out.append({"paddy": i, "task": task, "frac": float(p.get("frac", 0.0)),
				"machine": str((MACHINE[task] as Dictionary)["machine"])})
	return out


## Where the tractor is on a paddy `frac` through a job: it drives up and down
## passes PASS_W_M apart across the plot. {pos, dir} along a spine.
static func tractor_at(spine: Array, half_w: float, frac: float) -> Dictionary:
	var passes := maxi(1, int(ceil(half_w * 2.0 / PASS_W_M)))
	var t := clampf(frac, 0.0, 1.0) * float(passes)
	var k := mini(int(floor(t)), passes - 1)
	var u := t - float(k)
	var forward := k % 2 == 0
	var a := NpcRowWork.along(spine, u if forward else 1.0 - u)
	var dir: Vector2 = a["dir"]
	var across := Vector2(-dir.y, dir.x)
	var off := ((float(k) + 0.5) / float(passes) - 0.5) * (half_w * 2.0 - 0.8)
	return {"pos": (a["pos"] as Vector2) + across * off, "dir": dir if forward else -dir}


## Per paddy what the drawing needs: [stage, sow_h, plant progress 0..1,
## harvest progress 0..1].
static func paddy_view(fs: Dictionary) -> Array:
	var out: Array = []
	for p in fs.get("p", []):
		var pd: Dictionary = p
		var st := str(pd.get("st", STAGE_PREP))
		var task := str(pd.get("task", ""))
		var frac := float(pd.get("frac", 0.0))
		var shown := 0.0
		var cut := 0.0
		match st:
			STAGE_GROW:
				shown = 1.0
			STAGE_HARVEST:
				shown = 1.0
				cut = frac
			STAGE_PLANT:
				shown = frac if task == "plant" else 0.0
		out.append([st, snappedf(float(pd.get("sow", -1.0)), 0.01), snappedf(shown, 0.01),
			snappedf(cut, 0.01)])
	return out


## The season's work for a field, estimated: {hand_h, machine_op_h,
## machine_hand_h, fuel_l, work_kwh, food_kwh, fuel_kwh} for one season of
## every paddy (a perennial's planting counted once, separately as
## `establish_h`).
static func season_estimate(table: Array) -> Dictionary:
	var hand := 0.0
	var est := 0.0
	var op := 0.0
	var fuel := 0.0
	var mhand := 0.0
	for row in table:
		var r: Array = row
		var area := float(r[0])
		var crop := str(r[6]) if r.size() > 6 else "fallow"
		for task in TASKS:
			var h := hours_per_ha(crop, task) * area / 10000.0
			if is_perennial(crop) and task in ["prep", "plant"]:
				est += h
				continue
			hand += h
			if MACHINE.has(task):
				var ms: Dictionary = MACHINE[task]
				op += h * float(ms["share"])
				fuel += h * float(ms["share"]) * float(ms["fuel_lph"])
			else:
				mhand += h
	var work_kwh := hand * WORK_WH_PER_H / 1000.0
	return {"hand_h": hand, "establish_h": est, "machine_op_h": op, "machine_hand_h": mhand,
		"fuel_l": fuel,
		"work_kwh": work_kwh, "food_kwh": work_kwh / MUSCLE_EFF,
		"machine_work_kwh": (op + mhand) * WORK_WH_PER_H / 1000.0, "fuel_kwh": fuel * DIESEL_KWH_L}


## The ledger as the dock and graph show it: hours, energies.
static func ledger_summary(led: Dictionary) -> Dictionary:
	var lab := 0.0
	for k in (led.get("labour", {}) as Dictionary).keys():
		lab += float((led["labour"] as Dictionary)[k])
	var work_kwh := lab * WORK_WH_PER_H / 1000.0
	return {"labour_h": lab, "op_h": float(led.get("op_h", 0.0)),
		"fuel_l": float(led.get("fuel_l", 0.0)), "work_kwh": work_kwh,
		"food_kwh": work_kwh / MUSCLE_EFF,
		"fuel_kwh": float(led.get("fuel_l", 0.0)) * DIESEL_KWH_L,
		"food_kg": float(led.get("food_kg", 0.0)), "biomass_kg": float(led.get("biomass_kg", 0.0)),
		"lost_kg": float(led.get("lost_kg", 0.0)), "missed": int(led.get("missed", 0)),
		"seasons": int(led.get("seasons", 0))}
