class_name FireTimeline
extends RefCounted

## A structure fire as a PURE FUNCTION of sim time — the ExtremeWeather rule.
##
## Everything a fire IS lives in one JSON-safe record (persisted on the placed
## prop's record under "burn", or held in memory for a scene structure):
##   ignited_h   abs sim hours (CelestialClock.get_absolute_hours) it was lit
##   climb_h     hours from ignition to COLLAPSE (front climb, black, burn-away)
##   bonfire_h   hours of open flame on the pile after the collapse
##   ember_h     hours from the last flame to cold grey ash
##   auto        {climb_h, bonfire_h, ember_h, mass_kg} the estimate, for reset
##   holds       [[a, b], ...] abs hours the fire was HELD by the extinguisher
##               (b = -1 while the hold is open) — the burn clock stops inside
##   out_h       abs hours it was put out (-1 = never): everything freezes
## `state_at(rec, t)` turns that into what to draw. There are no timers: scrub
## the clock backwards and the structure stands again; forward and it burns at
## the same rate as everything else in the world. FireNode only RENDERS the
## state and writes the record when something happens (ignition, spraying,
## going out).

enum Phase { NONE, BURNING, COLLAPSING, PILE, OUT }

## The fall itself, in sim hours: 3 s. At 1x that is a real fall; at speed it
## is a snap, with the (real-time) whoosh still carrying the moment.
const COLLAPSE_H : float = 3.0 / 3600.0
## Within the climb: the front tops out at this share, the structure is all
## black by BLACK_AT, and the last stretch is eaten away to 75 % (the ash
## shader's dissolve 0.65 — FireNode.COLLAPSE_AT_DISSOLVE) at 1.0.
const FRONT_TOP_AT : float = 0.55
const BLACK_FROM : float = 0.50
const BLACK_AT : float = 0.78
const BURN_AWAY_FROM : float = 0.80
const DISSOLVE_AT_COLLAPSE : float = 0.65
const DISSOLVE_GONE : float = 1.35

const MIN_CLIMB_H : float = 1.0 / 60.0
const MIN_BONFIRE_H : float = 0.05
const MIN_EMBER_H : float = 0.05

## --- the fuel estimate -----------------------------------------------------
## What burns how long is mass, mostly, and shape for the climb. An open wood
## fire consumes very roughly 1 kg/min per m2 of bed (Drysdale, An
## Introduction to Fire Dynamics, ch. 5) and a flame front runs up a vertical
## timber face at ~0.1-0.3 m/s. Neither tells you the pile of a particular
## trailer-and-canopy camp, so these are starting points the player edits.
const BONFIRE_K : float = 0.0477     # h per kg^0.7: 1000 kg of fuel ~ 6 h of flame
const BONFIRE_EXP : float = 0.7
const EMBER_SHARE : float = 0.35     # the ember bed outlasts the flame by this
const FRONT_MPS : float = 0.015      # the front chars its way up at about this
## Fuel mass when nothing better is known: surface area x an assumed 25 mm
## of timber at 470 kg/m3 (PackedSpec.WOOD_KG_M3).
const SHELL_THICKNESS_M : float = 0.025
const WOOD_KG_M3 : float = 470.0


## `height_m` = structure height, `footprint_r_m` = half-extent of its base,
## `mass_kg` = fuel mass (-1 = unknown -> estimated from `surface_m2`).
static func estimate(height_m: float, footprint_r_m: float, surface_m2: float,
		mass_kg: float = -1.0) -> Dictionary:
	var m := mass_kg
	if m <= 0.0:
		m = maxf(surface_m2, 1.0) * SHELL_THICKNESS_M * WOOD_KG_M3
	# Catching (6 min) + the front up the height + the spread round the base;
	# a 6 m tower on a 1.5 m base comes to ~17 min.
	var climb := 0.1 + maxf(height_m, 0.0) / (FRONT_MPS * 3600.0) \
		+ maxf(footprint_r_m, 0.0) / 20.0
	var bonfire := BONFIRE_K * pow(maxf(m, 1.0), BONFIRE_EXP)
	return {
		"climb_h": snappedf(clampf(climb, MIN_CLIMB_H, 3.0), 0.01),
		"bonfire_h": snappedf(clampf(bonfire, MIN_BONFIRE_H, 48.0), 0.01),
		"ember_h": snappedf(clampf(bonfire * EMBER_SHARE, MIN_EMBER_H, 24.0), 0.01),
		"mass_kg": snappedf(m, 1.0),
		# The structure's size rides along: the crowd's safe perimeter is its
		# height plus ten feet while it stands, five feet off the pile after.
		"height_m": snappedf(maxf(height_m, 0.0), 0.01),
		"footprint_r_m": snappedf(maxf(footprint_r_m, 0.0), 0.01),
	}


## A fresh record lit at `ignited_h`. `est` carries the durations to use;
## `auto` (default `est` itself) is the geometry estimate kept for "reset".
static func make(ignited_h: float, est: Dictionary, auto: Dictionary = {}) -> Dictionary:
	if auto.is_empty():
		auto = est
	return {
		"ignited_h": ignited_h,
		"climb_h": float(est.get("climb_h", 0.33)),
		"bonfire_h": float(est.get("bonfire_h", 3.0)),
		"ember_h": float(est.get("ember_h", 1.0)),
		"auto": {
			"climb_h": float(auto.get("climb_h", 0.33)),
			"bonfire_h": float(auto.get("bonfire_h", 3.0)),
			"ember_h": float(auto.get("ember_h", 1.0)),
			"mass_kg": float(auto.get("mass_kg", -1.0)),
		},
		"holds": [],
		"out_h": -1.0,
		"height_m": float(est.get("height_m", auto.get("height_m", -1.0))),
		"footprint_r_m": float(est.get("footprint_r_m", auto.get("footprint_r_m", -1.0))),
	}


static func is_record(v: Variant) -> bool:
	return v is Dictionary and (v as Dictionary).has("ignited_h")


static func climb_h(rec: Dictionary) -> float:
	return maxf(float(rec.get("climb_h", 0.33)), MIN_CLIMB_H)


static func bonfire_h(rec: Dictionary) -> float:
	return maxf(float(rec.get("bonfire_h", 3.0)), MIN_BONFIRE_H)


static func ember_h(rec: Dictionary) -> float:
	return maxf(float(rec.get("ember_h", 1.0)), MIN_EMBER_H)


## Whole life, ignition to cold ash, in sim hours.
static func total_h(rec: Dictionary) -> float:
	return climb_h(rec) + COLLAPSE_H + bonfire_h(rec) + ember_h(rec)


## Hours the fire has actually BURNED by `t`: elapsed since ignition minus the
## time the extinguisher held it. An open hold ([a, -1]) runs to `t`.
static func burn_hours(rec: Dictionary, t: float) -> float:
	var ignited := float(rec.get("ignited_h", t))
	if t <= ignited:
		return 0.0
	var held := 0.0
	for h in rec.get("holds", []):
		if not (h is Array) or (h as Array).size() < 2:
			continue
		var a := maxf(float(h[0]), ignited)
		var b := float(h[1])
		if b < 0.0:
			b = t
		b = minf(b, t)
		if b > a:
			held += b - a
	return maxf(t - ignited - held, 0.0)


## True while the extinguisher is holding the fire at `t`.
static func is_held(rec: Dictionary, t: float) -> bool:
	for h in rec.get("holds", []):
		if h is Array and (h as Array).size() >= 2:
			var b := float(h[1])
			if t >= float(h[0]) and (b < 0.0 or t < b):
				return true
	return false


## What to draw at abs sim hours `t`. Keys always present:
##   phase      Phase
##   progress   BURNING: 0..1 climb of the front
##   char_all   BURNING: 0..1 the whole structure black
##   dissolve   BURNING: 0..0.65 eaten away; COLLAPSING: 0.65..1.35
##   collapse   COLLAPSING: 0..1 of the fall
##   age_h      PILE: sim hours since it landed
##   look       PILE: FireAshPile.look() for that age and these durations
##   out        true once put out (phase OUT); the other keys are frozen at
##              the moment it went out, so the char stays where it reached
##   held       true while sprayed (the front does not advance)
##   burn_h     hours burned
static func state_at(rec: Dictionary, t: float) -> Dictionary:
	var out_h := float(rec.get("out_h", -1.0))
	var frozen := out_h >= 0.0 and t >= out_h
	var st := _live_state(rec, out_h if frozen else t)
	st["out"] = frozen
	if frozen:
		if int(st["phase"]) != Phase.NONE:
			st["phase"] = Phase.OUT
		st["held"] = false
	return st


## The phase the frozen state was in when it went out (OUT hides it).
static func out_phase(rec: Dictionary) -> int:
	var out_h := float(rec.get("out_h", -1.0))
	if out_h < 0.0:
		return Phase.NONE
	return int(_live_state(rec, out_h)["phase"])


static func _live_state(rec: Dictionary, t: float) -> Dictionary:
	var ignited := float(rec.get("ignited_h", INF))
	var st := {
		"phase": Phase.NONE, "progress": 0.0, "char_all": 0.0, "dissolve": 0.0,
		"collapse": 0.0, "age_h": 0.0, "look": {}, "out": false, "held": false,
		"burn_h": 0.0,
	}
	if t < ignited:
		return st
	var bh := burn_hours(rec, t)
	st["burn_h"] = bh
	st["held"] = is_held(rec, t)
	var ch := climb_h(rec)
	if bh < ch:
		var x := bh / ch
		st["phase"] = Phase.BURNING
		st["progress"] = clampf(x / FRONT_TOP_AT, 0.0, 1.0)
		st["char_all"] = smoothstep(BLACK_FROM, BLACK_AT, x)
		st["dissolve"] = clampf((x - BURN_AWAY_FROM) / (1.0 - BURN_AWAY_FROM), 0.0, 1.0) * DISSOLVE_AT_COLLAPSE
		return st
	var after := bh - ch
	if after < COLLAPSE_H:
		var u := after / COLLAPSE_H
		st["phase"] = Phase.COLLAPSING
		st["progress"] = 1.0
		st["char_all"] = 1.0
		st["collapse"] = u
		# The last scraps burn up as they land, not on the way down.
		st["dissolve"] = lerpf(DISSOLVE_AT_COLLAPSE, DISSOLVE_GONE, smoothstep(0.5, 1.0, u))
		return st
	var age := after - COLLAPSE_H
	st["phase"] = Phase.PILE
	st["progress"] = 1.0
	st["char_all"] = 1.0
	st["collapse"] = 1.0
	st["dissolve"] = DISSOLVE_GONE
	st["age_h"] = age
	st["look"] = FireAshPile.look(age, bonfire_h(rec), ember_h(rec))
	return st


## Is there still open flame at `t` (a fire to fight / to hurt the player)?
static func has_flame(rec: Dictionary, t: float) -> bool:
	var st := state_at(rec, t)
	if bool(st["out"]):
		return false
	match int(st["phase"]):
		Phase.BURNING, Phase.COLLAPSING:
			return true
		Phase.PILE:
			return float((st["look"] as Dictionary).get("flame", 0.0)) > 0.0
	return false


## Over — cold ash, or put out.
static func is_finished(rec: Dictionary, t: float) -> bool:
	var st := state_at(rec, t)
	if bool(st["out"]):
		return true
	return int(st["phase"]) == Phase.PILE and float(st["age_h"]) >= bonfire_h(rec) + ember_h(rec)


## --- record writes (FireNode calls these at live time) ----------------------

## Start holding the fire (the extinguisher is on it). Idempotent.
static func begin_hold(rec: Dictionary, t: float) -> void:
	var holds: Array = rec.get("holds", [])
	if not holds.is_empty():
		var last: Array = holds[holds.size() - 1]
		if float(last[1]) < 0.0:
			return
	holds.append([t, -1.0])
	rec["holds"] = holds


## Stop holding it. Idempotent.
static func end_hold(rec: Dictionary, t: float) -> void:
	var holds: Array = rec.get("holds", [])
	if holds.is_empty():
		return
	var last: Array = holds[holds.size() - 1]
	if float(last[1]) < 0.0:
		last[1] = maxf(t, float(last[0]))
		holds[holds.size() - 1] = last
		rec["holds"] = holds


static func put_out(rec: Dictionary, t: float) -> void:
	end_hold(rec, t)
	rec["out_h"] = t


## The player edited a duration: keep it above the floor.
static func set_duration(rec: Dictionary, key: String, hours: float) -> void:
	var floor_h := MIN_EMBER_H
	if key == "climb_h":
		floor_h = MIN_CLIMB_H
	elif key == "bonfire_h":
		floor_h = MIN_BONFIRE_H
	rec[key] = maxf(hours, floor_h)


static func reset_to_auto(rec: Dictionary) -> void:
	var auto: Dictionary = rec.get("auto", {})
	for k in ["climb_h", "bonfire_h", "ember_h"]:
		if auto.has(k):
			rec[k] = float(auto[k])


static func phase_name(st: Dictionary) -> String:
	if bool(st.get("out", false)):
		return "out"
	match int(st.get("phase", Phase.NONE)):
		Phase.BURNING: return "burning"
		Phase.COLLAPSING: return "collapsing"
		Phase.PILE:
			var l: Dictionary = st.get("look", {})
			if float(l.get("flame", 0.0)) > 0.0:
				return "bonfire"
			if float(l.get("heat", 0.0)) > 0.0:
				return "embers"
			return "ash"
	return "none"


## "20 min", "6.0 h"
static func fmt_hours(h: float) -> String:
	if h < 1.0:
		return "%d min" % int(round(h * 60.0))
	return "%.1f h" % h
