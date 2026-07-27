class_name NpcBuildingNav
extends RefCounted

## Turns a building footprint into navigation instructions
## (POPULATION_PLAN.md Tier 3c): walls block, the interior does not, and
## doors punch openings so people can actually get inside.
##
## THE AUTO-DOOR HEURISTIC IS LOAD-BEARING, not a nicety. Only buildings the
## player has styled carry facade `elements`; the overwhelming majority of OSM
## buildings have no door data at all. Without a fallback, "pathfind into and
## through buildings" fails on essentially every real site — people would
## stand outside the kitchen forever. So a building with no door gets one
## punched at the edge midpoint facing whatever it should plausibly face (the
## nearest road, else the site centre), derived deterministically from the
## footprint so it is stable across reloads.
##
## Pure static math over polygons — no scene, no physics, fully testable.

## Half-width of the blocked band stamped along each wall.
const WALL_BAND_M := 0.6
## Opening punched at a door. Wide enough to walk through at 0.75 m cells
## without scraping the jamb.
const DOOR_RADIUS_M := 1.1
## Buildings smaller than this are sheds/kiosks — solid, not enterable.
const MIN_ENTERABLE_AREA_M2 := 9.0


## Doors declared by the player, in world XZ. `poly` must be the NORMALIZED
## ring from BuildingBuilder.resolve_building_params (open, CCW) — element
## `edge` indices only mean anything against that.
static func declared_doors(poly: PackedVector2Array, elements: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := poly.size()
	if n < 3:
		return out
	for e in elements:
		if not (e is Dictionary):
			continue
		var el: Dictionary = e
		if str(el.get("kind", "")) != "door":
			continue
		var edge := int(el.get("edge", -1))
		if edge < 0 or edge >= n:
			continue
		var a := poly[edge]
		var b := poly[(edge + 1) % n]
		var edge_len := a.distance_to(b)
		if edge_len < 0.5:
			continue     # BuildingBuilder skips elements on stub edges too
		var w := clampf(float(el.get("w_m", 1.0)), 0.2, edge_len - 0.1)
		var u := clampf(float(el.get("u_m", edge_len * 0.5)), w * 0.5, edge_len - w * 0.5)
		out.append(a + (b - a) / edge_len * u)
	return out


## Where to punch a door when the player has not placed one: the midpoint of
## the edge whose centre is closest to `attract` (the nearest road point, else
## the site centre). Deterministic — same footprint, same door, every load.
static func auto_door(poly: PackedVector2Array, attract: Vector2) -> Vector2:
	var n := poly.size()
	if n < 3:
		return Vector2.ZERO
	var best := 0
	var best_d := INF
	for i in n:
		var mid := (poly[i] + poly[(i + 1) % n]) * 0.5
		var d := mid.distance_squared_to(attract)
		# Ties break on the lower edge index so the choice never flickers.
		if d < best_d - 0.0001:
			best_d = d
			best = i
	return (poly[best] + poly[(best + 1) % n]) * 0.5


## The stamping instruction for one building, in the form NpcNavGrid.begin_bake
## consumes. `enterable` false (tiny footprint, or auto-doors disabled and no
## declared door) yields a solid block instead of walls + interior.
static func nav_entry(poly: PackedVector2Array, elements: Array, attract: Vector2,
		auto_door_enabled: bool = true, force_enterable: bool = false) -> Dictionary:
	if poly.size() < 3:
		return {}
	var area := absf(_signed_area(poly))
	var doors := declared_doors(poly, elements)
	var enterable := force_enterable or area >= MIN_ENTERABLE_AREA_M2
	if enterable and doors.is_empty():
		if auto_door_enabled or force_enterable:
			doors = PackedVector2Array([auto_door(poly, attract)])
		else:
			enterable = false
	if not enterable:
		# A shed with no way in is just an obstacle.
		return {
			"poly": poly,
			"flags": NpcNavGrid.F_BLOCKED | NpcNavGrid.F_STRUCTURE,
		}
	return {
		"poly": poly,
		"flags": NpcNavGrid.F_BLOCKED | NpcNavGrid.F_WALL | NpcNavGrid.F_STRUCTURE,
		"band_m": WALL_BAND_M,
		"interior_flags": NpcNavGrid.F_INTERIOR | NpcNavGrid.F_STRUCTURE,
		"doors": doors,
		"door_radius_m": DOOR_RADIUS_M,
	}


## Nearest point on any road polyline to `p`, or `p` itself when there are no
## roads in range. Roads come from TerrainLoader.get_osm_roads().
static func nearest_road_point(roads: Array, p: Vector2, max_dist_m: float = 120.0) -> Variant:
	var best: Variant = null
	var best_d := max_dist_m * max_dist_m
	for item in roads:
		if not (item is Dictionary):
			continue
		var pts: Variant = (item as Dictionary).get("points", PackedVector2Array())
		if not (pts is PackedVector2Array):
			continue
		var line: PackedVector2Array = pts
		for i in range(1, line.size()):
			var q := Geometry2D.get_closest_point_to_segment(p, line[i - 1], line[i])
			var d := q.distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = q
	return best


static func centroid(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(poly.size())


static func _signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5
