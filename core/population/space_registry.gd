class_name SpaceRegistry
extends RefCounted

## Per-map registry of player-tagged "spaces" — world objects assigned a
## SpaceTypes role (restroom / kitchen / sleeping / water point) that NPC
## agents wayfind to. Single source of truth: tags are NOT mirrored into
## prop records or BuildingStyleLayer (styling a building de-merges it from
## the OSM mesh — a perf side effect tagging must not trigger).
##
## Target kinds:
##   {"kind": "prop",     "prop_id": "<PlacedPropLayer id>"}
##   {"kind": "building", "building_tag": "<BuildingBuilder.building_tag>"}
##   {"kind": "area",     "poly": [[x, z], ...]}          # reserved for v2
##
## Occupancy (which agents currently claim a space) is runtime-only and is
## never serialized. Persistence follows the PlacedPropLayer pattern:
## user://maps/npc_spaces_<lat>_<lon>.json (or _scene_<tag>.json).

## v2: records carry `draw` (base attraction 0..1), `units` (fixtures in a
## bank — eight portapotties), `graph_item_id` (the graph tank / machine that
## receives what is consumed here) and `program` (FestivalProgram slots).
## v1 files load with the defaults filled in; unknown types are KEPT on load
## so an older build never erases a festival venue.
const VERSION := 2
## A festival site: every camp's beds plus venues and banks.
const MAX_SPACES := 4000
## The API default for callers that do not say (and what every record saved
## before AUTO existed carries): a hard limit of two.
const DEFAULT_CAPACITY := 2
## Capacity 0 = AUTO: the space never fills. People spread THEMSELVES across
## the spaces of a type instead -- nearest_space_by charges every occupant
## already there SHARE_SPREAD_M of walk, so a crowded restroom loses to one a
## little further away and a type's load is shared by distance. The tagging
## UIs default to this; set a number only where a space genuinely has one
## (a single portaloo, a four-seat bench).
const CAPACITY_AUTO := 0
const SHARE_SPREAD_M := 12.0
const DEFAULT_DRAW := 0.5
## Venue crowd layouts (record key `layout`; "" = by type, VenueCrowd.layout_of).
const LAYOUT_RING := "ring"
const LAYOUT_DIRECTIONAL := "directional"
const LAYOUTS: Array = ["", LAYOUT_RING, LAYOUT_DIRECTIONAL]

var spaces: Array = []
var _occupancy: Dictionary = {}  # space_id -> Array[String] agent ids (runtime only)
## STANDING SLOTS (runtime only). A person's slot at a space is the LOWEST
## free index when they take it, and it is theirs until they let it go —
## never "their position in the occupancy array", which shifted everyone
## behind a leaver one slot forward (a whole crowd shuffling at every
## departure), and never "how many are here now", which the light tier read
## at DECISION time: everyone who set off for the stage in the same tick got
## the same number and walked onto the same spot — the piles round a peak.
##   _slots:  space_id -> {agent_id: slot}
##   _slot_at: agent_id -> space_id (one slot per person; taking a new one
##             lets an unclaimed reservation elsewhere go)
var _slots: Dictionary = {}
var _slot_at: Dictionary = {}
## FRIEND-GROUP CLUSTERS at a space (VenueCrowd.group_spot): space_id ->
## {group_key: [cluster index, members holding a slot there]}. Lowest free
## index again, so two groups never share a cluster spot (they used to hash
## into 48 spots — the birthday problem stacked groups on each other).
var _clusters: Dictionary = {}
## Lazy indices (rebuilt on the next lookup after any record change). With
## thousands of spaces the old linear find_by_id inside has_free_capacity
## inside nearest_space_by was O(S²) per query.
var _by_id: Dictionary = {}
var _by_type: Dictionary = {}
var _index_dirty := true
## Resolved world positions, space_id -> Vector2, refreshed by the owner once
## per tick (refresh_positions) so a query never resolves a prop record.
var _pos_cache: Dictionary = {}
## Bumped by every record change (add / remove / retarget / retype / fields).
## Overlays and the Site Plan poll it instead of rebuilding on a timer.
var revision := 0


static func create_empty() -> SpaceRegistry:
	var layer := SpaceRegistry.new()
	layer.spaces = []
	return layer


# --- persistence (PlacedPropLayer idiom) ------------------------------------

func save_path_for_map(lat: float, lon: float) -> String:
	return WorldPaths.site_file("npc_spaces", lat, lon)


func save_path_for_scene(scene_key: String) -> String:
	return WorldPaths.scene_file("npc_spaces", scene_key)


func save(lat: float, lon: float) -> void:
	_save_to(save_path_for_map(lat, lon))


func load_for_map(lat: float, lon: float) -> bool:
	return _load_from(save_path_for_map(lat, lon))


func save_for_scene(scene_key: String) -> void:
	_save_to(save_path_for_scene(scene_key))


func load_for_scene(scene_key: String) -> bool:
	return _load_from(save_path_for_scene(scene_key))


func _save_to(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))


func _load_from(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	deserialize(parsed as Dictionary)
	return true


func serialize() -> Dictionary:
	return {"version": VERSION, "spaces": spaces.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	spaces = []
	for item in data.get("spaces", []):
		if not (item is Dictionary):
			continue
		var rec: Dictionary = (item as Dictionary).duplicate(true)
		if str(rec.get("space_type", "")).is_empty() or str(rec.get("id", "")).is_empty():
			continue
		spaces.append(_normalized(rec))
	_occupancy = {}
	_slots = {}
	_slot_at = {}
	_clusters = {}
	_pos_cache = {}
	_invalidate()


## Every v2 key present with a sane value; v1 records gain the defaults.
static func _normalized(rec: Dictionary) -> Dictionary:
	rec["capacity"] = maxi(int(rec.get("capacity", DEFAULT_CAPACITY)), CAPACITY_AUTO)
	rec["label"] = str(rec.get("label", ""))
	# A stage's facing in compass degrees (CelestialClock convention: north
	# 0, east 90); < 0 = auto (toward the camps). Only stages read it.
	rec["facing_deg"] = float(rec.get("facing_deg", -1.0))
	# How a venue's crowd stands: "" = by type (a stage faces one way, every
	# other venue is gathered round), "ring" = round it like a fire,
	# "directional" = a cone on ONE side, facing it (speakers, a screen).
	var lay := str(rec.get("layout", ""))
	rec["layout"] = lay if lay in LAYOUTS else ""
	# A performer's deck height above the ground (m), < 0 = measured from the
	# prop's own geometry (the DJ stands ON a stage, not in it).
	rec["perform_h_m"] = float(rec.get("perform_h_m", -1.0))
	# How far off a venue's edge its crowd starts (m), < 0 = by type (a
	# directional venue's fan: VenueCrowd.STAGE_FAN_GAP_M).
	rec["crowd_gap_m"] = float(rec.get("crowd_gap_m", -1.0))
	# A track the venue plays while its set is on (a file name in
	# StageMusic.DIR, "" = silent).
	rec["music"] = str(rec.get("music", ""))
	rec["draw"] = clampf(float(rec.get("draw", DEFAULT_DRAW)), 0.0, 1.0)
	rec["units"] = maxi(int(rec.get("units", 1)), 1)
	rec["graph_item_id"] = str(rec.get("graph_item_id", ""))
	rec["program"] = FestivalProgram.normalize(rec.get("program", []))
	return rec


func _invalidate() -> void:
	_index_dirty = true
	revision += 1


func _rebuild_index() -> void:
	_by_id = {}
	_by_type = {}
	for item in spaces:
		if not (item is Dictionary):
			continue
		var rec: Dictionary = item
		_by_id[str(rec.get("id", ""))] = rec
		var ty := str(rec.get("space_type", ""))
		var arr: Array = _by_type.get(ty, [])
		arr.append(rec)
		_by_type[ty] = arr
	_index_dirty = false


# --- cached positions --------------------------------------------------------

## Resolve every space ONCE through `pos_of` (space -> Vector2 | null) and
## keep the answers; queries then read the cache. Call once per sim tick (or
## whenever props move) — the bridge does.
func refresh_positions(pos_of: Callable) -> void:
	_pos_cache = {}
	for item in spaces:
		if not (item is Dictionary):
			continue
		var p: Variant = pos_of.call(item)
		if p is Vector2:
			_pos_cache[str((item as Dictionary).get("id", ""))] = p


func positions_ready() -> bool:
	return not _pos_cache.is_empty()


## Cached world XZ of a space, or null when unknown / unresolved.
func cached_position(space_id: String) -> Variant:
	return _pos_cache.get(space_id, null)


## The position a query should use: the cache first, the resolver otherwise.
func _position_for(space: Dictionary, pos_of: Callable) -> Variant:
	var sid := str(space.get("id", ""))
	if _pos_cache.has(sid):
		return _pos_cache[sid]
	if positions_ready():
		return null   # cache is live and this space did not resolve
	return pos_of.call(space) if pos_of.is_valid() else null


## Patch a record's own fields (capacity, label, draw, units, graph_item_id,
## program). Returns false for an unknown space.
func set_space_fields(space_id: String, patch: Dictionary) -> bool:
	var rec := find_by_id(space_id)
	if rec.is_empty():
		return false
	for k in patch.keys():
		match str(k):
			"capacity", "label", "draw", "units", "graph_item_id", "program", "facing_deg", \
					"layout", "perform_h_m", "crowd_gap_m", "music", "festival_seeded", "camp_id":
				rec[str(k)] = patch[k]
	_normalized(rec)
	revision += 1
	return true


## Move / reshape / re-point a space: give the record a new target (an area's
## new polygon, a different prop). The id, type, label, fields and assignment
## stay; occupancy and standing slots are let go (people re-plan from where
## they stand) and the cached position is dropped so the next refresh puts the
## space where it now is. Refused when another record already holds `target`.
func set_space_target(space_id: String, target: Dictionary) -> bool:
	var rec := find_by_id(space_id)
	if rec.is_empty() or not _target_valid(target):
		return false
	var other := space_for_target(target)
	if not other.is_empty() and str(other.get("id", "")) != space_id:
		return false
	rec["target"] = target.duplicate(true)
	_occupancy.erase(space_id)
	_forget_slots(space_id)
	_pos_cache.erase(space_id)
	_invalidate()
	return true


## Change only a space's type (a portapotty bank becomes showers). Unknown
## types are refused; the empty string does NOT remove (use remove_space).
func set_space_type_of(space_id: String, space_type: String) -> bool:
	var rec := find_by_id(space_id)
	if rec.is_empty() or not SpaceTypes.is_valid(space_type):
		return false
	rec["space_type"] = space_type
	_invalidate()
	return true


## Move every AREA space by `delta` (world metres) — the ones `pick(rec)`
## accepts. Returns how many moved. Prop / building targets stay with their
## objects.
func translate_areas(delta: Vector2, pick: Callable) -> int:
	var n := 0
	for item in spaces:
		var rec: Dictionary = item
		var tgt: Dictionary = rec.get("target", {})
		if str(tgt.get("kind", "")) != "area" or not bool(pick.call(rec)):
			continue
		var moved: Array = []
		for v in (tgt.get("poly", []) as Array):
			if v is Array and (v as Array).size() >= 2:
				moved.append([float(v[0]) + delta.x, float(v[1]) + delta.y])
		var t2 := tgt.duplicate(true)
		t2["poly"] = moved
		rec["target"] = t2
		_occupancy.erase(str(rec.get("id", "")))
		_forget_slots(str(rec.get("id", "")))
		_pos_cache.erase(str(rec.get("id", "")))
		n += 1
	if n > 0:
		_invalidate()
	return n


static func _target_valid(target: Dictionary) -> bool:
	match str(target.get("kind", "")):
		"prop":
			return not str(target.get("prop_id", "")).is_empty()
		"building":
			return not str(target.get("building_tag", "")).is_empty()
		"area":
			return poly_points(target.get("poly", []) as Array).size() >= 3
	return false


# --- record CRUD ------------------------------------------------------------

const _EMPTY: Array = []


func find_by_id(space_id: String) -> Dictionary:
	if _index_dirty:
		_rebuild_index()
	return _by_id.get(space_id, {})


## The space record whose target matches `target` (kind + identifying key).
func space_for_target(target: Dictionary) -> Dictionary:
	for item in spaces:
		if item is Dictionary and _targets_equal((item as Dictionary).get("target", {}), target):
			return item
	return {}


## Upsert: assign `space_type` to `target` (creating a record if needed).
## Empty space_type removes the tag. Returns the space id ("" if removed
## or invalid).
func set_space_type(target: Dictionary, space_type: String,
		capacity: int = DEFAULT_CAPACITY, label: String = "") -> String:
	var existing := space_for_target(target)
	if space_type.is_empty():
		if not existing.is_empty():
			remove_space(str(existing.get("id", "")))
		return ""
	if not SpaceTypes.is_valid(space_type):
		return ""
	if not existing.is_empty():
		existing["space_type"] = space_type
		existing["capacity"] = maxi(capacity, CAPACITY_AUTO)
		if not label.is_empty():
			existing["label"] = label
		_invalidate()
		return str(existing.get("id", ""))
	if spaces.size() >= MAX_SPACES:
		return ""
	var rec := _normalized({
		"id": _new_id(),
		"space_type": space_type,
		"target": target.duplicate(true),
		"capacity": maxi(capacity, CAPACITY_AUTO),
		"label": label,
	})
	spaces.append(rec)
	_invalidate()
	return str(rec["id"])


func remove_space(space_id: String) -> bool:
	for i in spaces.size():
		if str((spaces[i] as Dictionary).get("id", "")) == space_id:
			spaces.remove_at(i)
			_occupancy.erase(space_id)
			_forget_slots(space_id)
			_pos_cache.erase(space_id)
			_invalidate()
			return true
	return false


# --- per-agent assignment ("this bed is Devi's") -----------------------------
#
# `assigned` on a space record reserves it for ONE agent id. Selection
# (nearest_space_by) prefers an agent's own assigned space and skips spaces
# assigned to somebody else. Deliberately NEVER swept: an assignment naming an
# id that is not on the live roster is treated as OPEN by the caller-supplied
# liveness check, so a departed person's bed frees itself and Reset population
# (which re-mints the same hab_npc_N ids) keeps everyone's bed.

func assign_agent(space_id: String, agent_id: String) -> bool:
	var space := find_by_id(space_id)
	if space.is_empty():
		return false
	if agent_id.is_empty():
		space.erase("assigned")
	else:
		space["assigned"] = agent_id
		# One bed per person: the same agent assigned elsewhere loses that one.
		for item in spaces:
			var other: Dictionary = item
			if str(other.get("id", "")) != space_id \
					and str(other.get("assigned", "")) == agent_id \
					and str(other.get("space_type", "")) == str(space.get("space_type", "")):
				other.erase("assigned")
	return true


func assignment_of(space_id: String) -> String:
	return str(find_by_id(space_id).get("assigned", ""))


## The space of `space_type` assigned to this agent, {} when none.
func assigned_space_for(agent_id: String, space_type: String) -> Dictionary:
	if agent_id.is_empty():
		return {}
	for item in spaces_of_type(space_type):
		if str((item as Dictionary).get("assigned", "")) == agent_id:
			return item
	return {}


func _new_id() -> String:
	var max_n := 0
	for item in spaces:
		var sid := str((item as Dictionary).get("id", ""))
		if sid.begins_with("sp_"):
			max_n = maxi(max_n, int(sid.substr(3)))
	return "sp_%d" % (max_n + 1)


func _targets_equal(a: Dictionary, b: Dictionary) -> bool:
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return false
	match str(a.get("kind", "")):
		"prop":
			return str(a.get("prop_id", "")) == str(b.get("prop_id", ""))
		"building":
			return str(a.get("building_tag", "")) == str(b.get("building_tag", ""))
		"area":
			return a.get("poly", []) == b.get("poly", [])
	return false


# --- queries ----------------------------------------------------------------

## READ-ONLY by contract: the index's own array (it is rebuilt — never
## mutated — when the registry changes, so iterating it stays safe). The
## per-call duplicate cost one array copy per person per venue decision.
func spaces_of_type(space_type: String) -> Array:
	if _index_dirty:
		_rebuild_index()
	return _by_type.get(space_type, _EMPTY) as Array


## Nearest space of `space_type` to `pos`, resolving world positions through
## `pos_of` (space Dictionary -> Vector2 world XZ, or null for dangling
## targets, which are skipped). `require_free` skips spaces at capacity.
## Returns {} when nothing qualifies.
##
## Assignment semantics (see assign_agent): with an `agent_id`, that agent's
## own assigned space wins OUTRIGHT (even if farther) when it resolves and has
## room; spaces assigned to a different agent are skipped — unless
## `live_check` says the owner is no longer on the roster, in which case the
## assignment reads as open (stale assignments self-heal, never swept).
## Without a live_check an assignment is treated as binding.
## `spread` false drops the crowding charge (sleep: your camp's tents are
## your camp's tents however many are already in them).
func nearest_space_by(space_type: String, pos: Vector2, pos_of: Callable,
		require_free: bool = true, agent_id: String = "",
		live_check: Callable = Callable(), spread: bool = true) -> Dictionary:
	if not agent_id.is_empty():
		var own := assigned_space_for(agent_id, space_type)
		if not own.is_empty() \
				and (not require_free or has_free_capacity(str(own.get("id", "")))) \
				and _position_for(own, pos_of) is Vector2:
			return own
	var best: Dictionary = {}
	var best_d := INF
	for item in spaces_of_type(space_type):
		var space: Dictionary = item
		var owner := str(space.get("assigned", ""))
		if not owner.is_empty() and owner != agent_id:
			var owner_live := true
			if live_check.is_valid():
				owner_live = bool(live_check.call(owner))
			if owner_live:
				continue
		var sid := str(space.get("id", ""))
		if require_free and not has_free_capacity(sid):
			continue
		var p: Variant = _position_for(space, pos_of)
		if not (p is Vector2):
			continue
		# Share the load: every occupant already there costs SHARE_SPREAD_M
		# of extra walk, so people draw their share of a type's spaces by
		# distance instead of all converging on the nearest one.
		var d := ((p as Vector2) - pos).length() \
			+ (float(occupant_count(sid)) * SHARE_SPREAD_M if spread else 0.0)
		if d < best_d:
			best_d = d
			best = space
	return best


## Runtime convenience: nearest_space_by with the live-world resolver.
func nearest_space(space_type: String, pos: Vector2, main: Node,
		require_free: bool = true) -> Dictionary:
	return nearest_space_by(space_type, pos,
			func(space: Dictionary) -> Variant: return resolve_position(space, main),
			require_free)


## World XZ of a space's target, or null when the target no longer exists
## (deleted prop, missing building) — callers must skip null.
func resolve_position(space: Dictionary, main: Node) -> Variant:
	var target: Dictionary = space.get("target", {})
	match str(target.get("kind", "")):
		"prop":
			var rec: Dictionary = PlacedPropService.get_prop_record(main, str(target.get("prop_id", "")))
			if rec.is_empty():
				return null
			return Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
		"building":
			var loader := TerrainSurfaceQuery.find_terrain_loader(main)
			if loader == null or not loader.has_method("building_centroid_by_tag"):
				return null
			return loader.call("building_centroid_by_tag", str(target.get("building_tag", "")))
		"area":
			return area_interior_point(target.get("poly", []) as Array)
	return null


## World yaw (RADIANS) of a space's target, NAN when it has no orientation.
## Only prop targets carry one (the placed record's `yaw`, stored in degrees)
## — it is what lets a sleeper lie along a bed's long axis instead of at
## whatever angle they walked in on.
func resolve_yaw(space: Dictionary, main: Node) -> float:
	var target: Dictionary = space.get("target", {})
	if str(target.get("kind", "")) != "prop":
		return NAN
	var rec: Dictionary = PlacedPropService.get_prop_record(main, str(target.get("prop_id", "")))
	if rec.is_empty():
		return NAN
	return deg_to_rad(float(rec.get("yaw", 0.0)))


# --- area geometry ----------------------------------------------------------

## Polygon as world-XZ points.
static func poly_points(poly: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		if p is Array and (p as Array).size() >= 2:
			out.append(Vector2(float((p as Array)[0]), float((p as Array)[1])))
		elif p is Vector2:
			out.append(p)
	return out


## True area centroid (shoelace), NOT the average of the vertices — the vertex
## average is pulled toward wherever the outline happens to be finely divided,
## so a shape with one detailed edge biases badly.
static func polygon_centroid(poly: Array) -> Vector2:
	var pts := poly_points(poly)
	if pts.is_empty():
		return Vector2.ZERO
	if pts.size() < 3:
		var s := Vector2.ZERO
		for p in pts:
			s += p
		return s / float(pts.size())
	var a := 0.0
	var c := Vector2.ZERO
	for i in range(pts.size()):
		var p0 := pts[i]
		var p1 := pts[(i + 1) % pts.size()]
		var cross := p0.x * p1.y - p1.x * p0.y
		a += cross
		c += (p0 + p1) * cross
	if absf(a) < 0.0001:
		# Degenerate (collinear) — fall back to the vertex mean.
		var s2 := Vector2.ZERO
		for p in pts:
			s2 += p
		return s2 / float(pts.size())
	return c / (3.0 * a)


static func polygon_contains(poly: Array, pt: Vector2) -> bool:
	var pts := poly_points(poly)
	if pts.size() < 3:
		return false
	return Geometry2D.is_point_in_polygon(pt, pts)


static func polygon_area_m2(poly: Array) -> float:
	var pts := poly_points(poly)
	if pts.size() < 3:
		return 0.0
	var a := 0.0
	for i in range(pts.size()):
		var p0 := pts[i]
		var p1 := pts[(i + 1) % pts.size()]
		a += p0.x * p1.y - p1.x * p0.y
	return absf(a) * 0.5


## A point people can actually gather on.
##
## The centroid is the natural answer and is right for convex shapes, but for a
## concave one — an L-shaped yard, a courtyard wrapping a building — it can sit
## OUTSIDE the polygon entirely, which would send everyone to a spot that is
## not part of the space. When that happens, fall back to the interior sample
## furthest from any edge, which is the roomiest place to stand and is stable
## against small edits to the outline.
static func area_interior_point(poly: Array) -> Variant:
	var pts := poly_points(poly)
	if pts.is_empty():
		return null
	if pts.size() < 3:
		return polygon_centroid(poly)
	var c := polygon_centroid(poly)
	if Geometry2D.is_point_in_polygon(c, pts):
		return c
	# Grid-sample the bounding box and keep the deepest interior point. The
	# resolution is bounded so a huge area costs the same as a small one.
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	var steps := 24
	var best := Vector2.ZERO
	var best_d := -1.0
	for iy in range(steps + 1):
		for ix in range(steps + 1):
			var s := Vector2(
				lerpf(lo.x, hi.x, float(ix) / float(steps)),
				lerpf(lo.y, hi.y, float(iy) / float(steps)))
			if not Geometry2D.is_point_in_polygon(s, pts):
				continue
			var d := _distance_to_edges(pts, s)
			if d > best_d:
				best_d = d
				best = s
	if best_d < 0.0:
		return c   # nothing sampled inside (a sliver) — centroid is all we have
	return best


static func _distance_to_edges(pts: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	for i in range(pts.size()):
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


## Drop records whose target no longer resolves (call before save).
func prune_dangling(main: Node) -> int:
	var removed := 0
	for i in range(spaces.size() - 1, -1, -1):
		if resolve_position(spaces[i], main) == null:
			_occupancy.erase(str((spaces[i] as Dictionary).get("id", "")))
			_forget_slots(str((spaces[i] as Dictionary).get("id", "")))
			spaces.remove_at(i)
			removed += 1
	if removed > 0:
		_invalidate()
	return removed


# --- runtime occupancy (never serialized) -----------------------------------

## How much room one person occupies. Also the minimum gap the in-transit
## separation pass in NpcPopulationEngine tries to keep, so a group that packs
## into a space and a group that walks past each other agree on personal space.
const PERSONAL_SPACE_M := 0.9

## Vogel (sunflower) spiral: r = c*sqrt(n) at the golden angle. Nearest-
## neighbour spacing settles at ~c for every n, so a space fills outward
## evenly without anyone landing on top of anyone, and it does not look like
## a lattice the way concentric rings do.
const GOLDEN_ANGLE := 2.399963229728653


func occupant_count(space_id: String) -> int:
	return (_occupancy.get(space_id, []) as Array).size()


## This occupant's standing slot; -1 when not an occupant. Taken at claim
## time (or earlier, by `reserve_slot`) as the lowest free index, and kept
## for the whole visit: stable, reproducible from the same claim sequence,
## and never shared.
func slot_index_for(space_id: String, agent_id: String) -> int:
	if not (_occupancy.get(space_id, []) as Array).has(agent_id):
		return -1
	return _take_slot(space_id, agent_id)


## A slot held for someone on their way (the light tier picks its spot when it
## DECIDES to go and claims on arrival). Same slot the claim then keeps.
func reserve_slot(space_id: String, agent_id: String) -> int:
	return _take_slot(space_id, agent_id)


func _take_slot(space_id: String, agent_id: String) -> int:
	var m: Dictionary = _slots.get(space_id, {})
	if m.has(agent_id):
		return int(m[agent_id])
	# One slot per person: an unclaimed reservation elsewhere is let go.
	var prev := str(_slot_at.get(agent_id, ""))
	if not prev.is_empty() and prev != space_id \
			and not (_occupancy.get(prev, []) as Array).has(agent_id):
		_free_slot(prev, agent_id)
	var used: Dictionary = {}
	for k in m:
		used[int(m[k])] = true
	var s := 0
	while used.has(s):
		s += 1
	m[agent_id] = s
	_slots[space_id] = m
	_slot_at[agent_id] = space_id
	var gk := NpcFriends.key_of(agent_id)
	var cm: Dictionary = _clusters.get(space_id, {})
	if cm.has(gk):
		(cm[gk] as Array)[1] = int((cm[gk] as Array)[1]) + 1
	else:
		var cused: Dictionary = {}
		for g in cm:
			cused[int((cm[g] as Array)[0])] = true
		var c := 0
		while cused.has(c):
			c += 1
		cm[gk] = [c, 1]
	_clusters[space_id] = cm
	return s


func _free_slot(space_id: String, agent_id: String) -> void:
	var m: Dictionary = _slots.get(space_id, {})
	if not m.has(agent_id):
		return
	m.erase(agent_id)
	if m.is_empty():
		_slots.erase(space_id)
	if str(_slot_at.get(agent_id, "")) == space_id:
		_slot_at.erase(agent_id)
	var cm: Dictionary = _clusters.get(space_id, {})
	var gk := NpcFriends.key_of(agent_id)
	if cm.has(gk):
		var e: Array = cm[gk]
		e[1] = int(e[1]) - 1
		if int(e[1]) <= 0:
			cm.erase(gk)
		if cm.is_empty():
			_clusters.erase(space_id)


## A space went away: every slot and cluster held there goes with it.
func _forget_slots(space_id: String) -> void:
	var m: Dictionary = _slots.get(space_id, {})
	for aid in m:
		if str(_slot_at.get(aid, "")) == space_id:
			_slot_at.erase(aid)
	_slots.erase(space_id)
	_clusters.erase(space_id)


## The friend group's cluster index at a space (the group of someone holding a
## slot there), or -1.
func cluster_index_for(space_id: String, agent_id: String) -> int:
	var cm: Dictionary = _clusters.get(space_id, {})
	var e: Variant = cm.get(NpcFriends.key_of(agent_id))
	return int((e as Array)[0]) if e is Array else -1


## Offset from a space's resolved centre for the person holding `slot`.
## Without this every occupant of a space walks to the exact same point, so a
## capacity-4 kitchen renders as one person with three others inside them.
static func slot_offset_for_index(slot: int) -> Vector2:
	if slot <= 0:
		return Vector2.ZERO
	var r := PERSONAL_SPACE_M * sqrt(float(slot))
	var a := float(slot) * GOLDEN_ANGLE
	return Vector2(cos(a), sin(a)) * r


## Convenience: the standing offset for this agent at this space, with a
## per-person shuffle (SLOT_JITTER_M) so the sunflower spiral never reads as
## the lattice it is.
##
## The shuffle is a DISC of this radius. The slots are ~0.855 m apart at the
## closest, and two neighbours shuffled toward each other lose twice the
## radius, so this bounds the worst standing pair at ~0.45 m. The first form
## was a ±0.35 m SQUARE per axis (a corner is 0.49 m out), which could put two
## people in adjacent slots 0.03 m apart — a stack the separation pass never
## undid at festival speeds, where it is off. Pinned in npc_population_selftest.
const SLOT_JITTER_M := 0.2


## Where the n-th extra sleeper on one bed lies (n >= 1): alternating sides
## across the shelter's long axis, 0.3 m a step, nudged along it — a heap of
## people in a tent, never two on exactly one spot.
static func pile_offset(n: int, yaw: float) -> Vector2:
	if n <= 0:
		return Vector2.ZERO
	var axis := Vector2(cos(yaw), -sin(yaw))
	var across := Vector2(sin(yaw), cos(yaw))
	var side := 1.0 if n % 2 == 1 else -1.0
	return across * side * 0.3 * float((n + 1) / 2) + axis * 0.12 * float(n % 3 - 1)


## Where the n-th sleeper LIES in a sleep area with no shelter in it: rows
## across the area, everyone along one axis (`yaw`, the way they lie — see
## lying_yaw_for), LYING_ACROSS_M apart across and LYING_ALONG_M along, filled
## nearest the centre first (across the row, then the next row either side).
## The standing spiral put lying bodies 0.9 m apart at random yaws — people
## lying through each other.
const LYING_ACROSS_M := 1.1
const LYING_ALONG_M := 2.4
const LYING_ROW_N := 5


static func lying_offset_for_index(slot: int, yaw: float) -> Vector2:
	var k := maxi(slot, 0)
	var ia := k % LYING_ROW_N
	var ja := k / LYING_ROW_N
	# 0, 1, -1, 2, -2 … either side of the centre line.
	var across_i := (ia + 1) / 2 * (1 if ia % 2 == 1 else -1)
	var along_i := (ja + 1) / 2 * (1 if ja % 2 == 1 else -1)
	var along := Vector2(-sin(yaw), -cos(yaw))
	var across := Vector2(cos(yaw), -sin(yaw))
	return across * (LYING_ACROSS_M * float(across_i)) + along * (LYING_ALONG_M * float(along_i))


## The one lying direction of a sleep area (hashed off its id, so both tiers
## and every reload agree).
static func lying_yaw_for(space_id: String) -> float:
	return NpcHash.unit01(space_id, "lieyaw") * TAU


func slot_offset(space_id: String, agent_id: String) -> Vector2:
	var slot := slot_index_for(space_id, agent_id)
	if slot < 0:
		return Vector2.ZERO   # not an occupant: no slot, no shuffle
	return slot_offset_for_index(slot) + slot_jitter(agent_id)


static func slot_jitter(agent_id: String) -> Vector2:
	# Uniform over the disc (sqrt on the radius), never past SLOT_JITTER_M.
	var ang := NpcHash.unit01(agent_id, "jx") * TAU
	var r := sqrt(NpcHash.unit01(agent_id, "jz")) * SLOT_JITTER_M
	return Vector2(cos(ang), sin(ang)) * r


## Testing switch (PopTestPrefs.ignore_capacity, set by the bridge each
## tick): spaces never fill, so nobody queues and nothing is "all full".
var ignore_capacity := false


func has_free_capacity(space_id: String) -> bool:
	var rec := find_by_id(space_id)
	if rec.is_empty():
		return false
	if ignore_capacity:
		return true
	# People PILE UP to sleep: a tent or a sleep area never turns anyone away
	# (an assigned bed is still somebody's — that is the assignment, not the
	# capacity). A full sleep area used to send the overflow off to sleep on
	# the ground wherever they stood.
	if str(rec.get("space_type", "")) == "sleep":
		return true
	var cap := int(rec.get("capacity", DEFAULT_CAPACITY))
	if cap <= CAPACITY_AUTO:
		return true   # AUTO: never full, the load is shared by choice instead
	return occupant_count(space_id) < cap


## True when a space has no hard limit (capacity AUTO).
func is_auto_capacity(space_id: String) -> bool:
	var rec := find_by_id(space_id)
	return not rec.is_empty() and int(rec.get("capacity", DEFAULT_CAPACITY)) <= CAPACITY_AUTO


func claim(space_id: String, agent_id: String) -> bool:
	var occ: Array = _occupancy.get(space_id, [])
	if agent_id in occ:
		return true
	if not has_free_capacity(space_id):
		return false
	occ.append(agent_id)
	_occupancy[space_id] = occ
	_take_slot(space_id, agent_id)
	return true


func release(space_id: String, agent_id: String) -> void:
	var occ: Array = _occupancy.get(space_id, [])
	occ.erase(agent_id)
	_free_slot(space_id, agent_id)
	if occ.is_empty():
		_occupancy.erase(space_id)
	else:
		_occupancy[space_id] = occ


func release_all_for_agent(agent_id: String) -> void:
	for sid in _occupancy.keys():
		release(str(sid), agent_id)
	var held := str(_slot_at.get(agent_id, ""))
	if not held.is_empty():
		_free_slot(held, agent_id)


func clear_occupancy() -> void:
	_occupancy = {}
	_slots = {}
	_slot_at = {}
	_clusters = {}
