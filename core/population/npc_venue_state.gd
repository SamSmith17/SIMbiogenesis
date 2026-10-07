class_name NpcVenueState
extends RefCounted

## What a venue is DOING right now, as one dict both population tiers read:
##   active      bool   open for business
##   draw        0..1   its pull (NpcVenueChoice)
##   pull        >= 0   EVENT pull added to the venue score on top of taste:
##                      an effigy burn is the one thing the whole festival
##                      turns out for; a live set is a strong nudge
##   event       bool   pull >= EVENT_THRESHOLD — people come whether or not
##                      they felt like gathering (the enrichment-need gate is
##                      waived while one is on)
##   phase       int    VenueCrowd.EffigyPhase for an effigy, -1 otherwise
##   phase_name  String
##   ends_h      hours until the state changes (-1 = open-ended) — the visit
##               cap, the same unit FestivalProgram.state_at reports
##   programmed  bool   the state came from a programme (or a fire), so the
##                      cap is real
##   circle_t0   abs hours the circle dance began (NAN otherwise)
##   label       String
##
## Pure: a stage reads its programme; an effigy reads the FIRE RECORD the
## caller hands in (the bridge looks it up on the tagged prop). Nothing here
## touches the scene.

const EVENT_THRESHOLD := 1.0
## Pull is spent at NpcVenueChoice.WALK_COST_M (150 m) per point: 6.0 still
## outscores a camp's own fire circle from 800 m away, which is "the whole
## festival turns out" on a site a kilometre across.
const EFFIGY_BURN_PULL := 6.0
const STAGE_SET_PULL := 0.6
const EFFIGY_AFTER_DRAW := 0.6


static func resolve(space: Dictionary, hour: float, abs_h: float, fire_rec: Dictionary = {}) -> Dictionary:
	var stype := str(space.get("space_type", ""))
	if stype == "effigy":
		return _effigy(space, abs_h, fire_rec)
	var st := FestivalProgram.state_at(space, hour)
	var pull := 0.0
	if stype == "stage" and bool(st.get("programmed", false)) and bool(st.get("active", false)):
		pull = STAGE_SET_PULL
	st["pull"] = pull
	st["event"] = pull >= EVENT_THRESHOLD
	st["phase"] = -1
	st["phase_name"] = ""
	st["circle_t0"] = NAN
	return st


static func _effigy(space: Dictionary, abs_h: float, fire_rec: Dictionary) -> Dictionary:
	var ph := VenueCrowd.effigy_phase(fire_rec, abs_h)
	var base := clampf(float(space.get("draw", 0.5)), 0.0, 1.0)
	var out := {
		"active": true, "draw": base, "pull": 0.0, "event": false,
		"phase": int(ph["phase"]), "phase_name": str(ph["name"]),
		"ends_h": float(ph["ends_in_h"]), "programmed": false,
		"circle_t0": float(ph["circle_t0"]), "label": "",
		"safe_r": float(ph.get("safe_r", VenueCrowd.EFFIGY_SAFE_R_M)),
	}
	match int(ph["phase"]):
		VenueCrowd.EffigyPhase.BURNING:
			out["draw"] = 1.0
			out["pull"] = EFFIGY_BURN_PULL
			out["event"] = true
			out["programmed"] = true
			out["label"] = "The burn"
		VenueCrowd.EffigyPhase.CIRCLING:
			out["draw"] = 1.0
			out["pull"] = EFFIGY_BURN_PULL
			out["event"] = true
			out["programmed"] = true
			out["label"] = "Circling the fire"
		VenueCrowd.EffigyPhase.AFTER:
			out["draw"] = maxf(base, EFFIGY_AFTER_DRAW)
			out["label"] = "Embers"
		_:
			pass
	return out


## Is ANY venue in the list in an event state (its pull clears the threshold)?
static func any_event(states: Array) -> bool:
	for s in states:
		if s is Dictionary and bool((s as Dictionary).get("event", false)):
			return true
	return false
