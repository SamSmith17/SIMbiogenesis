class_name NpcPersona
extends RefCounted

## Who a person is, beyond their name (NPC life pass, Phase 5). Pure and
## static: generated from the person's id by NpcHash, so both tiers and every
## run agree, with the player's own edits laid over the top (`overrides`, from
## the habitat's specs.pop_personas — an NPC can stand in for a real member).
##
## What it decides today:
##   - CHRONOTYPE: where the person's night sits against the routine's. Drawn
##     from the mid-sleep-on-free-days spread of the Munich Chronotype
##     Questionnaire (Roenneberg et al. 2007, Sleep Med Rev 11:429; adults
##     within one age band spread roughly normally with an SD of about an
##     hour), clamped to CHRONO_MAX_H either side.
##   - SLEEP NEED: 7-9 h for most adults (Hirshkowitz et al. 2015, National
##     Sleep Foundation recommendations), normal about BASE_SLEEP_H.
##   - QUEUE PATIENCE: how long they wait in a toilet line before trying
##     elsewhere.
## Stored for the rota (Phase 6) and the schedule window (Phase 8): work
## affinities per family, max hours a day / week, unavailable hours, skills,
## sociability and walking pace. Bathroom counts are NpcBathroom's and shown
## here read-only.

const CHRONO_SD_H := 1.0
const CHRONO_MAX_H := 2.5
const BASE_SLEEP_H := 8.0
const SLEEP_SD_H := 0.6
const SLEEP_MIN_H := 6.5
const SLEEP_MAX_H := 9.5

## Work families the rota plans by (NpcWorkPose families map onto these).
const FAMILIES: Array = ["cook", "build", "haul", "garden", "clean", "machines", "care", "admin"]
const FAMILY_LABELS: Dictionary = {
	"cook": "Cooking", "build": "Building", "haul": "Hauling", "garden": "Gardening",
	"clean": "Cleaning", "machines": "Machines", "care": "Care", "admin": "Admin",
}

const PATIENCE_MIN_H := 0.25
const PATIENCE_MAX_H := 0.75
const PACE_MIN := 0.9
const PACE_MAX := 1.1

## Fields a player may set, with their clamps. Anything else in an override
## is dropped.
const EDITABLE: Dictionary = {
	"chrono_h": [-CHRONO_MAX_H, CHRONO_MAX_H],
	"sleep_need_h": [SLEEP_MIN_H, SLEEP_MAX_H],
	"patience_h": [0.05, 2.0],
	"pace": [0.6, 1.4],
	"sociability": [0.0, 1.0],
	"max_h_day": [0.0, 16.0],
	"max_h_week": [0.0, 80.0],
}

const _MEMO_MAX := 8192
static var _memo: Dictionary = {}


## The person's profile: generated, then `overrides` laid over it.
static func for_id(id: String, overrides: Dictionary = {}) -> Dictionary:
	var base: Dictionary
	var hit: Variant = _memo.get(id)
	if hit != null:
		base = hit
	else:
		base = _generate(id)
		if _memo.size() >= _MEMO_MAX:
			_memo.clear()
		_memo[id] = base
	if overrides.is_empty():
		return base
	var out := base.duplicate(true)
	for k in overrides:
		var key := str(k)
		var v: Variant = overrides[k]
		if EDITABLE.has(key):
			var lim: Array = EDITABLE[key]
			out[key] = clampf(float(v), float(lim[0]), float(lim[1]))
		elif key == "affinities" and v is Dictionary:
			var aff: Dictionary = (out["affinities"] as Dictionary).duplicate()
			for f in v:
				if FAMILIES.has(str(f)):
					aff[str(f)] = clampf(float(v[f]), -1.0, 1.0)
			out["affinities"] = aff
		elif key == "unavailable" and v is Array:
			out["unavailable"] = clean_unavailable(v)
		elif key == "skills" and v is Array:
			var sk: Array = []
			for s in v:
				if str(s).strip_edges() != "":
					sk.append(str(s).strip_edges())
			out["skills"] = sk
	out["overridden"] = true
	return out


static func _generate(id: String) -> Dictionary:
	var chrono := clampf(_normal(id, "chrono") * CHRONO_SD_H, -CHRONO_MAX_H, CHRONO_MAX_H)
	var need := clampf(BASE_SLEEP_H + _normal(id, "sleepneed") * SLEEP_SD_H, SLEEP_MIN_H, SLEEP_MAX_H)
	var aff := {}
	for f in FAMILIES:
		# Triangular -1..1: most people mildly like or mind most work.
		aff[f] = snappedf(NpcHash.unit01(id, "aff_" + f) + NpcHash.unit01(id, "aff2_" + f) - 1.0, 0.01)
	var day := 6.0 + roundf(NpcHash.unit01(id, "maxday") * 3.0)
	return {
		"chrono_h": snappedf(chrono, 0.01),
		"sleep_need_h": snappedf(need, 0.01),
		"patience_h": snappedf(lerpf(PATIENCE_MIN_H, PATIENCE_MAX_H, NpcHash.unit01(id, "patience")), 0.01),
		"pace": snappedf(lerpf(PACE_MIN, PACE_MAX, NpcHash.unit01(id, "pace")), 0.01),
		"sociability": snappedf((NpcHash.unit01(id, "soc1") + NpcHash.unit01(id, "soc2")) * 0.5, 0.01),
		"max_h_day": day,
		"max_h_week": day * 5.0,
		"affinities": aff,
		"unavailable": [],
		"skills": [],
		"pees_per_day": NpcBathroom.pees_per_day(id),
		"poops_per_day": NpcBathroom.poops_per_day(id),
		"overridden": false,
	}


## A standard normal draw from two hashes (Box–Muller).
static func _normal(id: String, salt: String) -> float:
	var u1 := maxf(NpcHash.unit01(id, salt + "_a"), 1e-6)
	var u2 := NpcHash.unit01(id, salt + "_b")
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2)


## How far the person's bedtime and wake time sit from the routine's, hours:
## the chronotype moves the middle of the night, the sleep need its length.
static func sleep_shift(p: Dictionary) -> Vector2:
	var c := float(p.get("chrono_h", 0.0))
	var d := float(p.get("sleep_need_h", BASE_SLEEP_H)) - BASE_SLEEP_H
	return Vector2(c - d * 0.5, c + d * 0.5)


## "Early bird" / "Night owl" / "In between".
static func chronotype_label(p: Dictionary) -> String:
	var c := float(p.get("chrono_h", 0.0))
	if c <= -0.75:
		return "Early bird"
	if c >= 0.75:
		return "Night owl"
	return "In between"


## The affinity (-1..1) for a work family; 0 for an unknown one.
static func affinity(p: Dictionary, family: String) -> float:
	return float((p.get("affinities", {}) as Dictionary).get(family, 0.0))


## [{day (-1 = every day, 0-6 = weekday), start_h, end_h}], cleaned.
static func clean_unavailable(arr: Array) -> Array:
	var out: Array = []
	for e in arr:
		if not e is Dictionary:
			continue
		var d := clampi(int(float((e as Dictionary).get("day", -1))), -1, 6)
		var s := fposmod(float((e as Dictionary).get("start_h", 0.0)), 24.0)
		var en := fposmod(float((e as Dictionary).get("end_h", 0.0)), 24.0)
		if absf(en - s) < 0.01:
			continue
		out.append({"day": d, "start_h": s, "end_h": en})
	return out


## Is the person unavailable at `hour` on weekday `weekday` (0-6)?
static func is_unavailable(p: Dictionary, weekday: int, hour: float) -> bool:
	for e in p.get("unavailable", []):
		var d := int((e as Dictionary).get("day", -1))
		if d >= 0 and d != weekday:
			continue
		if NpcRoutine.in_sleep_window(hour, float(e["start_h"]), float(e["end_h"])):
			return true
	return false


## Drop the memo (tests that change NpcHash inputs never need this; a test
## that wants a clean slate may).
static func clear_memo() -> void:
	_memo.clear()
