class_name FarmBotEconomics
extends RefCounted

## What a FarmBot costs against the work it saves.
##
## The robot's side comes from its own simulated days (FarmBotJobs): how long
## it runs, how many seeds it sows, how much it waters, how many weeds it
## pulls. The person's side is the same work done by hand, at rates that are
## ESTIMATES (a gardener's pace in an intensive raised bed; change them to
## yours). Harvesting is left out of both: a FarmBot does not harvest.
##
## Saved hours = the hand work the robot does - the hand work the robot still
## needs (refilling the seed trough, upkeep). Payback = what it costs to buy
## and put up / (the value of the hours saved - what it costs to run).

## Hand work (estimates).
const HAND_SOW_S_PER_SEED := 8.0      # measure, dibble, drop, cover
const HAND_WATER_L_MIN := 12.0        # a hose with a rose at the bed
const HAND_WATER_SETUP_MIN := 3.0     # out to the bed, hose out and back, each time
const HAND_WEED_MIN_M2_WEEK := 0.5    # keeping an intensive bed weeded
const HAND_LOOK_MIN_DAY := 4.0        # walking the bed, looking for pests and thirst
## A person checks the soil with a finger while looking; the robot's probe
## readings are not counted as hand work it saves.
## The robot's weeder reaches weeds in the open; the ones in a plant's crown
## are still pulled by hand (estimate).
const ROBOT_WEED_SHARE := 0.7
## What the robot still needs a person for (estimates).
const REFILL_MIN_PER_100_SEEDS := 2.0
const REFILL_MIN_PER_SEED_DAY := 2.0
## Power (estimates): the Raspberry Pi, the Farmduino and the 24 V supply idle
## all day; the four NEMA 17s, the vacuum pump and the solenoid while it works.
const IDLE_W := 12.0
const WORK_W := 55.0
## Days averaged for the steady state: after every crop's first sowing has
## passed (FarmBotLayout.first_sow spreads them over at most ~110 days).
const STEADY_FROM_DAY := 120
const SAMPLE_DAYS := 28


## Averages over SAMPLE_DAYS of steady days.
## -> {busy_h_day, max_busy_h, water_l_day, seeds_day, weeds_day, photos_day,
##    soil_day, seed_days, travel_m_day, worst_day}
static func robot_days(s: Dictionary, lay: Dictionary) -> Dictionary:
	var tot := {"busy_s": 0.0, "arm_s": 0.0, "water_l": 0.0, "seeded": 0.0, "weeds": 0.0, "photos": 0.0,
		"soil_reads": 0.0, "travel_mm": 0.0}
	var worst := 0.0
	var worst_day := STEADY_FROM_DAY
	var seed_days := 0
	for d in SAMPLE_DAYS:
		var day := STEADY_FROM_DAY + d
		var p := FarmBotJobs.day_plan(s, lay, day, false)
		for k in tot.keys():
			tot[k] = float(tot[k]) + float(p[k])
		if int(p["seeded"]) > 0:
			seed_days += 1
		if float(p["busy_s"]) > worst:
			worst = float(p["busy_s"])
			worst_day = day
	var n := float(SAMPLE_DAYS)
	return {"busy_h_day": float(tot["busy_s"]) / n / 3600.0, "arm_h_day": float(tot["arm_s"]) / n / 3600.0,
		"arms": FarmBotGeom.arm_count(s), "max_busy_h": worst / 3600.0, "worst_day": worst_day,
		"water_l_day": float(tot["water_l"]) / n, "seeds_day": float(tot["seeded"]) / n,
		"weeds_day": float(tot["weeds"]) / n, "photos_day": float(tot["photos"]) / n,
		"soil_day": float(tot["soil_reads"]) / n, "seed_days_frac": float(seed_days) / n,
		"travel_m_day": float(tot["travel_mm"]) / n / 1000.0}


## The money and the hours, a year at a time.
static func compute(s: Dictionary, robot: Dictionary) -> Dictionary:
	var cr: Dictionary = s["care"]
	var co: Dictionary = s["cost"]
	var tools: Dictionary = s["tools"]
	var area := FarmBotSpec.area_m2(s)
	var n_water := (cr["water_times"] as Array).size() if bool(tools["watering"]) else 0
	# The same work by hand, minutes a day.
	var sow_min := float(robot["seeds_day"]) * HAND_SOW_S_PER_SEED / 60.0
	var water_min := float(robot["water_l_day"]) / HAND_WATER_L_MIN + HAND_WATER_SETUP_MIN * float(n_water)
	var weed_min := HAND_WEED_MIN_M2_WEEK * area / 7.0 if bool(tools["weeder"]) and int(cr["weed_every_days"]) > 0 else 0.0
	var look_min := HAND_LOOK_MIN_DAY if int(cr["photo_every_days"]) > 0 else 0.0
	var hand_min_day := sow_min + water_min + weed_min + look_min
	# What the robot still needs a person for.
	var refill_min_day := float(robot["seeds_day"]) / 100.0 * REFILL_MIN_PER_100_SEEDS \
		+ float(robot["seed_days_frac"]) * REFILL_MIN_PER_SEED_DAY
	var weed_left_min := weed_min * (1.0 - ROBOT_WEED_SHARE)
	var upkeep_h := float(co["upkeep_h_year"])
	var hand_h_year := hand_min_day * 365.0 / 60.0
	var still_h_year := (refill_min_day + weed_left_min) * 365.0 / 60.0 + upkeep_h
	var saved_h := hand_h_year - still_h_year
	var rate := float(co["labor_usd_h"])
	var arms := float(robot.get("arms", 1))
	var kwh := (IDLE_W * arms * 24.0 + WORK_W * float(robot.get("arm_h_day", robot["busy_h_day"]))) * 365.0 / 1000.0
	var running := kwh * float(co["electricity_usd_kwh"]) + float(co["parts_usd_year"])
	var kit := FarmBotSpec.kit_price_usd(s)
	# The kit's assembly time is for the XL's 6 m; longer tracks take longer.
	var assembly := float(co["assembly_h"]) * clampf(float((s["bed"] as Dictionary)["length_m"]) / 6.0, 0.5, 10.0)
	var capital := kit + assembly * rate
	var bed := float(co["bed_usd_m2"]) * area
	var net := saved_h * rate - running
	var life := float(co["lifetime_years"])
	return {
		"hand": {"sow_min": sow_min, "water_min": water_min, "weed_min": weed_min, "look_min": look_min,
			"min_day": hand_min_day, "h_year": hand_h_year},
		"still_h_year": still_h_year, "refill_min_day": refill_min_day, "weed_left_min_day": weed_left_min,
		"saved_h_year": saved_h, "saved_usd_year": saved_h * rate,
		"kwh_year": kwh, "running_usd_year": running,
		"kit_usd": kit, "assembly_h": assembly, "capital_usd": capital, "bed_usd": bed,
		"net_usd_year": net, "payback_years": capital / net if net > 0.0 else INF,
		"lifetime_net_usd": net * life - capital,
		"usd_per_saved_h": (capital / life + running) / saved_h if saved_h > 0.0 else INF,
	}
