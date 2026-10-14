class_name FestivalSeedLayout
extends RefCounted

## Pure data behind FESTIVAL MODE: how a painted camp becomes a populated
## camp, and where a festival's shared infrastructure goes when the player
## has tagged none.
##
## Festival mode exists because the crowd simulation was unreachable: a
## painted camp is scenery (no headcount), only an ASSIGNED placement lot
## becomes a camp compound on the graph, and even then nobody moves unless
## somebody has tagged a kitchen, beds, portapotties, a water point and a
## stage. This file turns the camps the player already painted into lot-shaped
## records the graph sync understands, and lays out a default venue set around
## them. Everything here is a function of its arguments — the world tests
## (exclusions, slope) arrive as a Callable — so the selftest can pin it.
##
## Labels carry LABEL_PREFIX so "Clear festival" can find exactly what this
## seeded and leave the player's own spaces alone.

const LABEL_PREFIX := "Festival · "
const MIN_HEADCOUNT := 2
const MAX_HEADCOUNT := 500
## Floor per camp when a population target scales headcounts down.
const MIN_SCALED_HEADCOUNT := 2
## The camp kitchen is the camp outline shrunk about its interior point, so
## the sleep area and the kitchen are DIFFERENT area targets (the registry
## matches area targets by polygon).
const KITCHEN_INSET := 0.45
## Shared venues are searched for along a bearing from the camps' centroid,
## stepping outward until a spot is free of every camp and the world's
## exclusions (buildings, roads, water).
const RING_STEP_M := 25.0
const MAX_RING_STEPS := 40
const PORTAPOTTY_UNITS_PER_BANK := 12
const TAPS_PER_STATION := 8
const PEOPLE_PER_SHOWER_BANK := 150
## Half-sizes (m) of the shared venues' square footprints.
const HALF_SIZE := {
	"restroom": 6.0, "water_point": 5.0, "shower": 6.0,
	"stage": 25.0, "center_camp": 20.0, "temple": 18.0, "art": 6.0,
}
## Art pieces: daytime destinations for the SOCIAL blocks' wanders and venue
## visits (a festival with only a stage, a temple and center camp gave the
## afternoon three places to be). One per this many people, at least 3.
const PEOPLE_PER_ART := 150
const MIN_ART := 3
const MAX_ART := 8
const ART_DRAW := 0.55
## The three programmed/open venues and their pull (NpcVenueChoice draw).
const STAGE_DRAW := 1.0
const CENTER_DRAW := 0.7
const TEMPLE_DRAW := 0.6
const STAGE_SET := {"day": -1, "start_h": 20.0, "end_h": 2.0, "draw": 1.0,
	"label": "Headliner", "load_w": 4000.0}


# ---------------------------------------------------------------------------
# Painted camps -> populated camps
# ---------------------------------------------------------------------------

## How many people a painted camp of this outline and style sleeps: the
## placement tool's own density (FestivalAssigner.people_per_m2 — fill ×
## people per household ÷ lattice cell), floored at MIN_HEADCOUNT so a
## camp that passed the layer's minimum area always gets SOMEBODY.
static func camp_headcount(rec: Dictionary) -> int:
	var area := CampAreaLayer.record_area(rec)
	if area <= 0.0:
		return 0
	var n := FestivalAssigner.default_headcount(area, str(rec.get("style", CampStyles.DEFAULT_STYLE)))
	return clampi(n, MIN_HEADCOUNT, MAX_HEADCOUNT)


## A camp record festival mode may populate: a free-painted camp (no group),
## or a lot camp whose zone no longer exists (an orphan — its headcount
## would otherwise never come from anywhere). A LIVE lot's camp is left to
## the placement layer, which carries its headcount on the assignment.
static func is_populatable(rec: Dictionary, zone_ids: Dictionary) -> bool:
	var gid := str(rec.get("group_id", ""))
	return gid.is_empty() or not zone_ids.has(gid)


## Populated painted camps as LOT-SHAPED records, so
## SystemGraphView.sync_camps_from_placement stamps them exactly like
## placement lots (keyed "camp:<id>", idempotent, removed when depopulated).
static func camp_lots(areas: Array, zone_ids: Dictionary) -> Array:
	var out: Array = []
	for a in areas:
		if not (a is Dictionary):
			continue
		var rec: Dictionary = a
		var n := int(rec.get("headcount", 0))
		if n <= 0 or not is_populatable(rec, zone_ids):
			continue
		var poly: PackedVector2Array = rec.get("polygon", PackedVector2Array())
		if poly.size() < 3:
			continue
		var id := str(rec.get("id", ""))
		var name := str(rec.get("name", id))
		out.append({
			"lot_id": lot_id_for_camp(id),
			"zone_id": "",
			"name": name,
			"polygon": poly,
			"camp_area_id": id,
			"usable_m2": CampAreaLayer.record_area(rec),
			"assigned_camp": {"roster_id": "", "name": name,
				"style": str(rec.get("style", CampStyles.DEFAULT_STYLE)),
				"headcount": n, "requirements": [], "manual": true},
		})
	return out


static func lot_id_for_camp(camp_id: String) -> String:
	return "camp:" + camp_id


## "" when the lot id is a real placement lot.
static func camp_id_for_lot(lot_id: String) -> String:
	return lot_id.trim_prefix("camp:") if lot_id.begins_with("camp:") else ""


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

## Centroid of every camp's interior point + the radius that encloses every
## camp vertex: where the festival IS, for the camera and the venue search.
static func cluster(polys: Array) -> Dictionary:
	var c := Vector2.ZERO
	var n := 0
	for p in polys:
		var poly: PackedVector2Array = p
		if poly.size() < 3:
			continue
		c += CampAreaLayer._inner_point(poly)
		n += 1
	if n == 0:
		return {"centre": Vector2.ZERO, "radius": 0.0}
	c /= float(n)
	var r := 0.0
	for p in polys:
		for v in (p as PackedVector2Array):
			r = maxf(r, c.distance_to(v))
	return {"centre": c, "radius": r}


## The outline scaled toward its interior point by `f` (0..1).
static func inset_polygon(poly: PackedVector2Array, f: float) -> PackedVector2Array:
	var c := CampAreaLayer._inner_point(poly)
	var out := PackedVector2Array()
	for v in poly:
		out.append(c + (v - c) * clampf(f, 0.05, 1.0))
	return out


static func poly_to_array(poly: PackedVector2Array) -> Array:
	var out: Array = []
	for v in poly:
		out.append([v.x, v.y])
	return out


static func square(centre: Vector2, half: float) -> PackedVector2Array:
	return PackedVector2Array([centre + Vector2(-half, -half), centre + Vector2(half, -half),
		centre + Vector2(half, half), centre + Vector2(-half, half)])


## True when a square footprint overlaps no camp outline: none of its corners
## or centre inside a camp, no camp vertex inside it.
static func clear_of_camps(centre: Vector2, half: float, polys: Array) -> bool:
	var sq := square(centre, half)
	for p in polys:
		var poly: PackedVector2Array = p
		if poly.size() < 3:
			continue
		if Geometry2D.is_point_in_polygon(centre, poly):
			return false
		for v in sq:
			if Geometry2D.is_point_in_polygon(v, poly):
				return false
		for v in poly:
			if absf(v.x - centre.x) <= half and absf(v.y - centre.y) <= half:
				return false
	return true


# ---------------------------------------------------------------------------
# The venue plan
# ---------------------------------------------------------------------------

## The shared venue set a festival of `people` needs, sized from
## CampProvisioning.requirements: [{type, count, half, cap, units, fields}].
static func shared_venue_specs(people: int) -> Array:
	var n := maxi(people, 1)
	var req := CampProvisioning.requirements(n)
	var banks := maxi(int(ceil(float(req["portapotty_units"]) / float(PORTAPOTTY_UNITS_PER_BANK))), 1)
	var stations := maxi(int(ceil(float(req["water_point_taps"]) / float(TAPS_PER_STATION))), 1)
	var showers := maxi(int(ceil(float(n) / float(PEOPLE_PER_SHOWER_BANK))), 1)
	return [
		# Capacities are AUTO (0): people spread across the banks / stations
		# by distance and crowding (SpaceRegistry.SHARE_SPREAD_M), and a stage
		# or a temple is as big as the crowd that comes. The COUNTS still size
		# from the requirement, so a big festival gets more banks.
		{"type": "restroom", "count": banks, "half": float(HALF_SIZE["restroom"]),
			"cap": SpaceRegistry.CAPACITY_AUTO, "fields": {"units": PORTAPOTTY_UNITS_PER_BANK}},
		{"type": "water_point", "count": stations, "half": float(HALF_SIZE["water_point"]),
			"cap": SpaceRegistry.CAPACITY_AUTO, "fields": {}},
		{"type": "shower", "count": showers, "half": float(HALF_SIZE["shower"]),
			"cap": SpaceRegistry.CAPACITY_AUTO, "fields": {}},
		{"type": "stage", "count": 1, "half": float(HALF_SIZE["stage"]), "cap": SpaceRegistry.CAPACITY_AUTO,
			"fields": {"draw": STAGE_DRAW, "program": [STAGE_SET.duplicate()]}},
		{"type": "center_camp", "count": 1, "half": float(HALF_SIZE["center_camp"]),
			"cap": SpaceRegistry.CAPACITY_AUTO, "fields": {"draw": CENTER_DRAW}},
		{"type": "temple", "count": 1, "half": float(HALF_SIZE["temple"]),
			"cap": SpaceRegistry.CAPACITY_AUTO, "fields": {"draw": TEMPLE_DRAW}},
		{"type": "art", "count": clampi(int(ceil(float(n) / float(PEOPLE_PER_ART))), MIN_ART, MAX_ART),
			"half": float(HALF_SIZE["art"]), "cap": SpaceRegistry.CAPACITY_AUTO,
			"fields": {"draw": ART_DRAW}},
	]


## Where everything goes. `camps`: [{id, name, poly: PackedVector2Array,
## headcount}]. `free_fn(centre: Vector2, half: float) -> bool` is the world's
## veto (exclusions / slope); an invalid Callable vetoes nothing.
## Returns [{type, poly: Array[[x,y]], cap, label, fields, camp_id}] — per
## camp a `sleep` area over the outline and a `kitchen` inset inside it, then
## the shared set searched outward from the camps' centroid along evenly
## spread bearings, so the utilities land in the ground BETWEEN camps rather
## than on a ring far outside them.
static func venue_plan(camps: Array, free_fn: Callable = Callable()) -> Array:
	var out: Array = []
	var polys: Array = []
	var people := 0
	for c in camps:
		var cd: Dictionary = c
		var poly: PackedVector2Array = cd.get("poly", PackedVector2Array())
		if poly.size() < 3:
			continue
		polys.append(poly)
		var n := maxi(int(cd.get("headcount", 0)), 1)
		people += n
		var name := str(cd.get("name", cd.get("id", "Camp")))
		out.append({"type": "sleep", "poly": poly_to_array(poly), "cap": n,
			"label": LABEL_PREFIX + name + " beds", "fields": {}, "camp_id": str(cd.get("id", ""))})
		out.append({"type": "kitchen", "poly": poly_to_array(inset_polygon(poly, KITCHEN_INSET)),
			"cap": SpaceRegistry.CAPACITY_AUTO, "label": LABEL_PREFIX + name + " kitchen", "fields": {},
			"camp_id": str(cd.get("id", ""))})
	if polys.is_empty():
		return out
	var cl := cluster(polys)
	var centre: Vector2 = cl["centre"]
	var specs := shared_venue_specs(people)
	var total := 0
	for s in specs:
		total += int(s["count"])
	# Bearings: evenly spread, starting north, interleaved by emission order so
	# two portapotty banks never sit side by side.
	var k := 0
	for s in specs:
		var sd: Dictionary = s
		for i in int(sd["count"]):
			var ang := TAU * float(k) / float(maxi(total, 1))
			k += 1
			var dir := Vector2(sin(ang), -cos(ang))
			var half := float(sd["half"])
			var spot := _find_spot(centre, dir, half, polys, free_fn)
			var label := LABEL_PREFIX + _shared_label(str(sd["type"]), i, int(sd["count"]))
			out.append({"type": str(sd["type"]), "poly": poly_to_array(square(spot, half)),
				"cap": int(sd["cap"]), "label": label,
				"fields": (sd["fields"] as Dictionary).duplicate(true), "camp_id": ""})
	return out


static func _find_spot(centre: Vector2, dir: Vector2, half: float, polys: Array,
		free_fn: Callable) -> Vector2:
	var last := centre
	for step in range(0, MAX_RING_STEPS + 1):
		var p := centre + dir * (RING_STEP_M * float(step))
		last = p
		if not clear_of_camps(p, half, polys):
			continue
		if free_fn.is_valid() and not bool(free_fn.call(p, half)):
			continue
		return p
	return last


static func _shared_label(type: String, i: int, count: int) -> String:
	var names := {
		"restroom": "Portapotties", "water_point": "Water station", "shower": "Showers",
		"stage": "Bass stage", "center_camp": "Center camp", "temple": "Temple",
		"art": "Art piece",
	}
	var base: String = str(names.get(type, SpaceTypes.label(type)))
	if count <= 1:
		return base
	return "%s %s" % [base, char(65 + (i % 26))]


## Scale camp headcounts so they sum to `target` (largest remainder, so the
## total lands EXACTLY on target), keeping every camp's share of the natural
## split and at least MIN_SCALED_HEADCOUNT each. `target <= 0` = unchanged.
## When the floor alone exceeds the target the floors win (a camp is never
## emptied by the slider — clear its headcount to make it scenery).
static func scale_headcounts(counts: Array, target: int) -> Array:
	var out: Array = counts.duplicate()
	if target <= 0 or counts.is_empty():
		return out
	var total := 0
	for c in counts:
		total += maxi(int(c), 0)
	if total <= 0:
		return out
	var floor_n := MIN_SCALED_HEADCOUNT
	var budget := maxi(target - floor_n * counts.size(), 0)
	var spare := 0
	for c in counts:
		spare += maxi(int(c) - floor_n, 0)
	var rems: Array = []
	var given := 0
	for i in counts.size():
		var share := float(maxi(int(counts[i]) - floor_n, 0)) / float(maxi(spare, 1)) * float(budget)
		if spare <= 0:
			share = float(budget) / float(counts.size())
		var whole := int(floor(share))
		out[i] = floor_n + whole
		given += whole
		rems.append([share - float(whole), i])
	rems.sort_custom(func(a, b) -> bool:
		if absf(float(a[0]) - float(b[0])) > 1e-9:
			return float(a[0]) > float(b[0])
		return int(a[1]) < int(b[1]))
	var left := budget - given
	for k in mini(left, rems.size()):
		var idx := int(rems[k][1])
		out[idx] = int(out[idx]) + 1
	return out


## The space types a festival needs tagged before anyone can act on a need
## away from camp — what `missing_types` reports.
const REQUIRED_TYPES: Array = ["sleep", "kitchen", "restroom", "water_point", "shower", "stage"]


static func missing_types(present: Array) -> Array:
	var out: Array = []
	for t in REQUIRED_TYPES:
		if not present.has(t):
			out.append(t)
	return out


## Types every CAMP needs its own of: a camp's beds and its kitchen are
## where ITS people go, so one tagged shiftpod elsewhere on the site must not
## stop the other camps getting theirs (it did: a single capacity-1 bed sent
## a whole festival to sleep round one pod).
const PER_CAMP_TYPES: Array = ["sleep", "kitchen"]


## Should this plan entry be seeded? A shared type only when the site has
## none; a per-camp type whenever THIS camp's outline holds none of it.
## `existing` = [{type, pos: Vector2}] for the spaces already tagged.
static func needs_seeding(entry: Dictionary, missing: Array, existing: Array) -> bool:
	var t := str(entry.get("type", ""))
	if not PER_CAMP_TYPES.has(t) or str(entry.get("camp_id", "")).is_empty():
		return missing.has(t)
	var poly := SpaceRegistry.poly_points(entry.get("poly", []) as Array)
	if poly.size() < 3:
		return missing.has(t)
	for e in existing:
		var ed: Dictionary = e
		if str(ed.get("type", "")) == t and ed.get("pos") is Vector2 \
				and Geometry2D.is_point_in_polygon(ed["pos"] as Vector2, poly):
			return false
	return true
