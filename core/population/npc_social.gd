class_name NpcSocial
extends RefCounted

## What a festival-goer does with a SOCIAL block ("Hanging out") — the
## routine kind that replaced FREE in NpcRoutine.festival_day().
##
## A FREE block has no activity of its own: both tiers sent someone to a venue
## only when their enrichment need was past 0.3, and that need rises at 1/30
## per hour and resets after every visit — so from late morning to dinner
## nobody qualified and the whole festival stood where it had last eaten.
## A SOCIAL block always does something, chosen per person per HOUR from a
## hash (never from block boundaries — the two tiers see those at different
## moments, which is what broke every "linger" experiment; see CLAUDE.md):
##
##   venue   NpcVenueChoice over every enrichment space, WITHOUT the
##           enrichment gate (center camp, the temple, art, a stage).
##   mingle  walk to one of the camp's conversation circles for this hour and
##           stand in it facing the middle, chatting (zero consumption).
##   wander  stroll out to a point 30-120 m from camp and look around — an
##           art walk across the site — then come back to the circle.
##
## Pure: everything is a function of (agent id, camp seed, camp home, abs
## hours), so both tiers reproduce the same choice and the same spot.
##
## FRIEND GROUPS (NpcFriends): the choice, the circle, the wander target and
## the stint length are hashed from the person's GROUP, so friends make the
## same choice in the same hour and stand together — a group in a circle
## holds its own F-formation (members evenly round a small ring facing its
## middle), and a wandering group walks abreast.

const ACTIVITY := "mingle"
## Share of hours spent at a venue / wandering; the rest is mingling in camp.
const P_VENUE := 0.45
const P_WANDER := 0.2
## How long one mingle stint lasts (then the person re-decides).
const MINGLE_MIN_H := 0.3
const MINGLE_MAX_H := 0.8
const WANDER_DWELL_H := 0.15
## Conversation circles: this many per camp, re-drawn every CIRCLE_BUCKET_H,
## each a ring of people this far from its middle, inside HANGOUT_R_M of home.
const CIRCLES_PER_CAMP := 3
const CIRCLE_BUCKET_H := 2.0
const CIRCLE_R_MIN_M := 1.1
const CIRCLE_R_PER_PERSON_M := 0.12
const HANGOUT_R_M := 16.0
## How far a friend group's own cluster sits from its circle's middle.
const GROUP_SPREAD_M := 2.6
const WANDER_MIN_M := 30.0
const WANDER_MAX_M := 120.0
## What a mingle does for the enrichment need (half a venue visit's worth):
## company lifts morale, just not as much as a night at the fire.
const ENRICH_RELIEF := 0.4


## "venue" | "mingle" | "wander" for this person in this hour.
static func choice(agent_id: String, abs_h: float) -> String:
	var u := NpcHash.unit01(NpcFriends.key_of(agent_id), "soc%d" % int(floor(abs_h)))
	if u < P_VENUE:
		return "venue"
	if u < P_VENUE + P_WANDER:
		return "wander"
	return "mingle"


## The middle of conversation circle `c` of this camp for the bucket holding
## `abs_h` — a point within HANGOUT_R_M of home.
static func circle_centre(seed_key: String, home: Vector2, c: int, abs_h: float) -> Vector2:
	var b := int(floor(abs_h / CIRCLE_BUCKET_H))
	var a := NpcHash.unit01(seed_key, "circ%d_%d_a" % [c, b]) * TAU
	var r := sqrt(NpcHash.unit01(seed_key, "circ%d_%d_r" % [c, b])) * HANGOUT_R_M
	return home + Vector2(cos(a), sin(a)) * r


## Which circle this person joins this bucket.
static func circle_of(agent_id: String, abs_h: float) -> int:
	var b := int(floor(abs_h / CIRCLE_BUCKET_H))
	return int(NpcHash.unit01(NpcFriends.key_of(agent_id), "join%d" % b) * float(CIRCLES_PER_CAMP)) % CIRCLES_PER_CAMP


## {pos, face} — where this person stands in their circle and the point they
## face (the circle's middle). Seats are spread round the ring by a hashed
## angle with a little radial scatter, so a circle reads as people talking,
## not as a clock face.
static func mingle_spot(agent_id: String, seed_key: String, home: Vector2, abs_h: float) -> Dictionary:
	var c := circle_of(agent_id, abs_h)
	var mid := circle_centre(seed_key, home, c, abs_h)
	var g := NpcFriends.group_of(agent_id)
	if int(g["size"]) <= 1:
		# On their own: join the circle's edge and face its middle.
		var a := NpcHash.unit01(agent_id, "seat") * TAU
		var r := CIRCLE_R_MIN_M + CIRCLE_R_PER_PERSON_M * 6.0 \
			+ (NpcHash.unit01(agent_id, "seat_r") - 0.5) * 0.5
		return {"pos": mid + Vector2(cos(a), sin(a)) * r, "face": mid}
	# A friend group holds its OWN conversation inside the circle's area: a
	# cluster a few metres off the circle's middle, members evenly round it.
	var gk := str(g["key"])
	var b := int(floor(abs_h / CIRCLE_BUCKET_H))
	var ga := NpcHash.unit01(gk, "gc%d_a" % b) * TAU
	var gr := 1.2 + NpcHash.unit01(gk, "gc%d_r" % b) * GROUP_SPREAD_M
	var centre := mid + Vector2(cos(ga), sin(ga)) * gr
	var off := NpcFriends.formation_offset(gk, int(g["k"]), int(g["size"]),
		NpcHash.unit01(agent_id, "seat"))
	return {"pos": centre + off, "face": centre}


## {pos, face} — a stroll destination for this hour, 30-120 m out from home.
static func wander_spot(agent_id: String, home: Vector2, abs_h: float) -> Dictionary:
	var h := int(floor(abs_h))
	var g := NpcFriends.group_of(agent_id)
	var gk := str(g["key"])
	var a := NpcHash.unit01(gk, "wan%d_a" % h) * TAU
	var r := lerpf(WANDER_MIN_M, WANDER_MAX_M, NpcHash.unit01(gk, "wan%d_r" % h))
	var dir := Vector2(cos(a), sin(a))
	# Friends stroll out together and stand abreast at the view.
	var p := home + dir * r + NpcFriends.abreast_offset(int(g["k"]), int(g["size"]), dir)
	# Look further out along the same bearing: at the view, not back at camp.
	return {"pos": p, "face": p + dir * 20.0}


## How long this stint lasts, hashed per person per hour.
static func stint_h(agent_id: String, abs_h: float, wander: bool) -> float:
	if wander:
		return WANDER_DWELL_H
	var u := NpcHash.unit01(NpcFriends.key_of(agent_id), "stint%d" % int(floor(abs_h)))
	return lerpf(MINGLE_MIN_H, MINGLE_MAX_H, u)


## The enrichment need after a mingle stint.
static func relieved_enrichment(v: float) -> float:
	return maxf(v - ENRICH_RELIEF, 0.0)
