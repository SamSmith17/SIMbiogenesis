class_name NpcVenueChoice
extends RefCounted

## Which enrichment venue a person goes to — ONE rule shared by the full
## agent and the light crowd tier, so a stage pulls the same crowd whichever
## tier is simulating it.
##
## score = draw × (TASTE_FLOOR + taste[kind]) × room
##         − distance / WALK_COST_M + company × COMPANY_BONUS
##
## `draw` is what the venue's programme says it is doing now (a headline set
## 1.0, a closed stage 0.15, a fire circle with no programme its base draw);
## `taste` is the person's 0..1 appetite for the venue's kind (music / quiet /
## social / art, hashed per person so it is stable and deterministic);
## `room` drops a venue near capacity; the company term is the old social
## pull — people drift toward the fire that already has people at it.
## Deterministic: ties break on the venue id.

const WALK_COST_M := 150.0      # metres of walk one full point of draw is worth
const COMPANY_BONUS := 0.08     # per companion, capped
const COMPANY_CAP := 6
const TASTE_FLOOR := 0.35       # nobody has ZERO appetite for a free show


## A person's taste vector from their id: {music, quiet, social, art} in 0..1.
static func taste_for(agent_id: String) -> Dictionary:
	var out := {}
	for k in SpaceTypes.TASTE_KINDS:
		out[k] = NpcHash.unit01(agent_id, "taste_" + str(k))
	return out


## candidates: [{id, type, pos: Vector2, draw, occupants, capacity}].
## Returns the winning candidate dict, or {} when none.
static func pick(taste: Dictionary, pos: Vector2, candidates: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	for c in candidates:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = c
		var cap := maxi(int(cd.get("capacity", 1)), 1)
		var occ := int(cd.get("occupants", 0))
		if occ >= cap:
			continue
		var s := score(taste, pos, cd)
		if s > best_score or (absf(s - best_score) < 1e-9 and str(cd.get("id", "")) < str(best.get("id", ""))):
			best_score = s
			best = cd
	return best


static func score(taste: Dictionary, pos: Vector2, c: Dictionary) -> float:
	var kind := SpaceTypes.enrichment_kind(str(c.get("type", "")))
	var t := clampf(float(taste.get(kind, 0.5)), 0.0, 1.0)
	var draw := clampf(float(c.get("draw", 0.5)), 0.0, 1.0)
	var cap := maxi(int(c.get("capacity", 1)), 1)
	var occ := int(c.get("occupants", 0))
	var room := 1.0 - 0.5 * clampf(float(occ) / float(cap), 0.0, 1.0)
	var company := mini(occ, COMPANY_CAP)
	var dist := (c.get("pos", pos) as Vector2).distance_to(pos)
	return draw * (TASTE_FLOOR + t) * room - dist / WALK_COST_M + float(company) * COMPANY_BONUS
