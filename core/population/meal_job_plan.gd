class_name MealJobPlan
extends RefCounted

## A meal as a small crew job (NPC life pass, Phase 7): the inside of a
## kitchen recipe's crew step, as CrewJobPlan jobs at the kitchen's stations.
##   prep  — fetch the produce from the store, wash it, chop it (in parallel
##           at the prep table), into the pot on the stove
##   cook  — stir, let it simmer, stir again (the recipe's cook step has no
##           chore hours in the shipped recipes; drawn only if it has)
##   serve — carry the pot to the serving table, plate up (in parallel),
##           wash up at the basins
## The person-minutes per serving below are camp-cooking ESTIMATES, not
## measurements; with `person_hours` set (the chore's own hours) every
## attended job is scaled so the plan's work is exactly the chore's, which is
## what lets a crew's credited labour map straight onto the plan's time.
##
## Kitchen frame (CampKitchenBuilder draws the same): metres, the counter row
## along X at the back (z −0.6, 0.9 m high), cooks stand at z −0.1 facing −Z;
## the serving table at the front (z 1.15), servers behind it facing +Z, the
## diners' side beyond it.

const STEP_PREP := "prep"
const STEP_COOK := "cook"
const STEP_SERVE := "serve"

## Seconds of work per serving (estimates) and fixed seconds per job.
const FETCH_S := 45.0
const FETCH_PER := 2.0
const WASH_VEG_PER := 4.0
const CHOP_PER := 20.0
const POT_S := 60.0
const POT_PER := 1.0
const STIR_S := 120.0
const STIR_PER := 2.0
const SIMMER_S := 900.0
const CARRY_POT_S := 40.0
const PLATE_PER := 8.0
const WASH_UP_PER := 12.0

const COUNTER_Z := -0.6
const COUNTER_TOP := 0.9
const COOK_Z := -0.1
const SERVE_TABLE_Z := 1.15
const SERVER_Z := 0.6


static func default_stations() -> Dictionary:
	var back := Vector3(0, 0, COUNTER_Z - 1.0)
	return {
		CrewJobPlan.START: {"pos": Vector3(0.0, 0.0, 0.3), "face": Vector3(0, 0, -1.0), "side": Vector3.RIGHT},
		"store": {"pos": Vector3(-2.0, 0.0, COOK_Z), "face": Vector3(-2.0, 0.0, back.z), "side": Vector3.RIGHT},
		"prep": {"pos": Vector3(-0.8, 0.0, COOK_Z), "face": Vector3(-0.8, 0.0, back.z), "side": Vector3.RIGHT},
		"stove": {"pos": Vector3(0.6, 0.0, COOK_Z), "face": Vector3(0.6, 0.0, back.z), "side": Vector3.RIGHT},
		"wash": {"pos": Vector3(2.0, 0.0, COOK_Z), "face": Vector3(2.0, 0.0, back.z), "side": Vector3.RIGHT},
		"serve": {"pos": Vector3(0.5, 0.0, SERVER_Z), "face": Vector3(0.5, 0.0, SERVER_Z + 1.0), "side": Vector3.RIGHT},
	}


## What kind of meal step a recipe step is, from its id / label ("" = not a
## kitchen step).
static func step_kind(step_id: String, label: String = "") -> String:
	var s := ("%s %s" % [step_id, label]).to_lower()
	if s.contains("serve") or s.contains("plate") or s.contains("wash up") or s.contains("clean"):
		return STEP_SERVE
	if s.contains("prep") or s.contains("chop") or s.contains("ingredient"):
		return STEP_PREP
	if s.contains("cook") or s.contains("stir"):
		return STEP_COOK
	return ""


## What a kitchen's recipe is: {servings (meals a batch makes), steps: [{id,
## label, hours, kind}], hours (crew hours a batch)}.
static func recipe_info(specs: Dictionary) -> Dictionary:
	var rec := RecipeRunner.resolve_recipe(specs)
	var servings := 0.0
	for o in rec.get("outputs", []):
		if str((o as Dictionary).get("kind", "")) == "meal":
			servings += float((o as Dictionary).get("qty", 0.0))
	var steps: Array = []
	var hrs := 0.0
	for st in rec.get("steps", []):
		var sd: Dictionary = st
		var h := float(sd.get("chore_hours", 0.0))
		if h <= 0.0:
			continue
		steps.append({"id": str(sd.get("id", "")), "label": str(sd.get("label", "")), "hours": h,
			"kind": MealJobPlan.step_kind(str(sd.get("id", "")), str(sd.get("label", ""))),
			"crew_min": int(sd.get("crew_min", 1)), "crew_max": int(sd.get("crew_max", 0))})
		hrs += h
	return {"servings": servings, "steps": steps, "hours": hrs}


## The crew a meal step wants: one cook per ~12 servings, 1..4 (estimate).
static func crew_for(servings: float) -> int:
	return clampi(int(ceil(maxf(servings, 1.0) / 12.0)), 1, 4)


## The jobs of one step (ids = indices).
static func jobs_for(kind: String, servings: float, crew_n: int) -> Array:
	var s := maxf(servings, 1.0)
	var jobs: Array = []
	var J := func(kind_: String, label: String, station: String, deps: Array, mn: int, mx: int,
			work: float, rig: String, tool: String, clip: String) -> int:
		var id := jobs.size()
		jobs.append(CrewJobPlan.job(id, kind_, label, station, deps, mn, mx, work,
			{"rig": rig, "tool": tool, "clip": clip}))
		return id
	match kind:
		STEP_PREP:
			var fetch: int = J.call("fetch", "Fetch the produce", "store", [], 1, 2,
				FETCH_S + FETCH_PER * s, "carry_crate", "crate", "carry_pot")
			var wash: int = J.call("wash_veg", "Wash the vegetables", "wash", [fetch], 1, 2,
				WASH_VEG_PER * s, "wash", "sponge", "wash_dishes")
			var k := clampi(crew_n, 1, 3)
			var chops: Array = []
			for i in k:
				chops.append(J.call("chop", "Chop", "prep", [wash], 1, 1, CHOP_PER * s / float(k),
					"chop", "knife", "chop"))
			J.call("pot", "Into the pot", "stove", chops, 1, 1, POT_S + POT_PER * s, "stir", "ladle", "stir_pot")
		STEP_COOK:
			var stir: int = J.call("stir", "Stir", "stove", [], 1, 1, STIR_S + STIR_PER * s, "stir", "ladle", "stir_pot")
			var simmer: int = jobs.size()
			jobs.append(CrewJobPlan.job(simmer, "simmer", "Simmer", "stove", [stir], 0, 0, SIMMER_S))
			J.call("stir", "Stir and taste", "stove", [simmer], 1, 1, STIR_S, "stir", "ladle", "stir_pot")
		STEP_SERVE:
			var carry: int = J.call("carry_pot", "Carry the pot out", "stove", [], 1, 2, CARRY_POT_S,
				"carry_pot", "pot", "carry_pot")
			var k2 := clampi(crew_n, 1, 3)
			var plates: Array = []
			for i in k2:
				plates.append(J.call("plate", "Plate up", "serve", [carry], 1, 1, PLATE_PER * s / float(k2),
					"plate", "ladle", "plate_up"))
			J.call("wash_up", "Wash up", "wash", plates, 1, 2, WASH_UP_PER * s, "wash", "sponge", "wash_dishes")
	return jobs


## A whole step: {kind, servings, jobs, workers, makespan, …} (CrewJobPlan).
## opts: {stations, person_hours (scale the attended work to it)}.
static func build(kind: String, servings: float, crew_n: int, opts: Dictionary = {}) -> Dictionary:
	var jobs := jobs_for(kind, servings, crew_n)
	var ph := float(opts.get("person_hours", 0.0))
	if ph > 0.0:
		var tot := 0.0
		for j in jobs:
			if not bool(j["unattended"]):
				tot += float(j["work_s"])
		if tot > 0.0:
			var k := ph * 3600.0 / tot
			for j in jobs:
				if not bool(j["unattended"]):
					j["work_s"] = float(j["work_s"]) * k
	var st: Dictionary = opts.get("stations", {})
	if st.is_empty():
		st = default_stations()
	var tl := CrewJobPlan.plan(jobs, st, maxi(crew_n, 1))
	tl["kind"] = kind
	tl["servings"] = servings
	return tl


## The time in the plan a step `frac` done stands at: labour progress mapped
## onto the plan's own (person-time-weighted) progress, so half the work done
## shows the jobs that hold the middle half of the person-seconds.
static func time_for_progress(tl: Dictionary, frac: float) -> float:
	var f := clampf(frac, 0.0, 1.0)
	var total := float(tl.get("person_s", 0.0))
	var mk := float(tl.get("makespan", 0.0))
	if total <= 0.0 or mk <= 0.0:
		return f * mk
	# Work done by time t is monotone in t: bisect.
	var lo := 0.0
	var hi := mk
	for _i in 40:
		var mid := (lo + hi) * 0.5
		if work_done_at(tl, mid) / total < f:
			lo = mid
		else:
			hi = mid
	return hi


static func work_done_at(tl: Dictionary, t: float) -> float:
	var done := 0.0
	for j in tl.get("jobs", []):
		if bool(j["unattended"]):
			continue
		var a := float(j["t0"])
		var b := float(j["t1"])
		if a < 0.0:
			continue
		var f := 1.0 if t >= b else (clampf((t - a) / maxf(b - a, 1e-6), 0.0, 1.0) if t > a else 0.0)
		done += f * float(j["work_s"])
	return done
