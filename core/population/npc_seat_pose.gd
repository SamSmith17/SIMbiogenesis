class_name NpcSeatPose
extends RefCounted

## How a person sits (NPC life pass, Phase 2): the ONE rule both tiers and
## every body ask.
##
## A chair pose (thighs forward, shins down) is only right ON something:
## a flat-pack bench or stool, a vehicle seat, a toilet. Everywhere else
## people sit on the ground — cross-legged, propped back on their arms,
## kneeling, or squatting on their heels for a short stint. Before this the
## toilet used the chair pose wherever the restroom was (an invisible stool),
## the light tier drew toilet users standing, and a seat's kind never chose
## the pose.
##
## Convention for every body: a CHAIR pose's origin is the seat SURFACE. The
## sim's `elev` for a seat is the seat height above the ground, the renderer
## lifts the body by it, and the pose puts the hips just above the origin
## (the stick figure, the crowd shader and the rigged body all agree). Before
## this a 0.46 m bench lifted a body whose hips already sat 0.36 m up: bench
## sitters floated a hand's breadth over the seat.
##
## Pure and static; per-person variety is NpcHash, never an RNG.

## Seat spot kinds (SpaceRegistry / bridge seat spots).
const KIND_SIT := "sit"
const KIND_LIE := "lie"
const KIND_STAND := "stand"
const KIND_TOILET := "toilet"

## A seat lower than this is the ground for posing purposes.
const CHAIR_MIN_ELEV := 0.3
## Where the hips sit above a chair pose's origin (= the seat surface).
const CHAIR_HIP_ABOVE_SEAT := 0.06

## Pose words. "" = no opinion (the caller keeps its own default).
const CHAIR := "chair"
const CROSS := "cross"
const LOUNGE := "lounge"
const KNEEL := "kneel"
const SQUAT := "squat"
const STAND := "stand"

## Ground sitting mixes, weights summing to 1. A meal is mostly cross-legged
## (some kneel to eat); a hang includes leaning back on the arms; a short stint
## (a few minutes) is often a squat.
const MIX_MEAL := [[CROSS, 0.7], [KNEEL, 0.3]]
const MIX_HANG := [[CROSS, 0.55], [LOUNGE, 0.3], [KNEEL, 0.15]]
const MIX_SHORT := [[SQUAT, 0.45], [CROSS, 0.35], [KNEEL, 0.2]]


## True when the person is ON a seat that takes a chair pose.
static func on_chair(seat_kind: String, elev: float) -> bool:
	return (seat_kind == KIND_SIT or seat_kind == KIND_TOILET) and elev >= CHAIR_MIN_ELEV


## A ground pose from a mix, stable for one person and `salt` (the same
## person sits the same way at the same kind of thing).
static func ground_pose(person_key: String, salt: String, mix: Array) -> String:
	var u := NpcHash.unit01(person_key, "seat|" + salt)
	var acc := 0.0
	for e: Array in mix:
		acc += float(e[1])
		if u < acc:
			return str(e[0])
	return str((mix[mix.size() - 1] as Array)[0])


## The pose for someone DOING `activity`.
##   venue_pose — VenueCrowd's hint for the slot ("sit", "lounge", ... or "")
##   seat_kind / elev — the seat spot they took ("" = none)
##   person_key — the agent id (variety)
##   space_type — the space's type (quiet spaces sit by default)
## Returns a pose word, or "" when sitting has nothing to say (dancing,
## standing at a venue, working, sleeping ...).
static func for_activity(activity: String, venue_pose: String, seat_kind: String,
		elev: float, person_key: String, space_type: String = "") -> String:
	var chair := on_chair(seat_kind, elev)
	match activity:
		"bladder":
			# A toilet (or any seat) takes the chair pose; with nothing to sit on
			# it is a standing visit. (Phase 4 tells pee from poo.)
			return CHAIR if chair else STAND
		"hunger":
			return CHAIR if chair else ground_pose(person_key, "meal", MIX_MEAL)
		"enrichment", NpcSocial.ACTIVITY:
			if venue_pose == VenueCrowd.POSE_SIT:
				return CHAIR if chair else ground_pose(person_key, "hang", MIX_HANG)
			if venue_pose == "" and (space_type == "quiet" or space_type == "temple"):
				return CHAIR if chair else ground_pose(person_key, "hang", MIX_HANG)
			if chair and (venue_pose == "" or venue_pose == VenueCrowd.POSE_TALK):
				# A bench at a hang: sit on it rather than stand beside it.
				return CHAIR
	return ""


## The rig's logical clip for a pose word ("" for none).
static func clip_for(word: String) -> String:
	match word:
		CHAIR:
			return NpcRig.CLIP_SIT
		CROSS:
			return NpcRig.CLIP_SIT_CROSS
		LOUNGE:
			return NpcRig.CLIP_LOUNGE
		KNEEL:
			return NpcRig.CLIP_KNEEL
		SQUAT:
			return NpcRig.CLIP_SQUAT
		STAND:
			return NpcRig.CLIP_IDLE
	return ""


## The crowd shader's pose code for a pose word (-1 for none).
static func crowd_code_for(word: String) -> int:
	match word:
		CHAIR:
			return CrowdCohort.POSE_SIT
		CROSS:
			return CrowdCohort.POSE_CROSS
		LOUNGE:
			return CrowdCohort.POSE_LOUNGE
		KNEEL:
			return CrowdCohort.POSE_KNEEL
		SQUAT:
			return CrowdCohort.POSE_SQUAT
		STAND:
			return CrowdCohort.POSE_STAND
	return -1
