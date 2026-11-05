class_name GraphSystems
extends RefCounted
## Power systems on one site (plans/GRAPH_SYSTEMS_UX_PLAN.md, Phase 0).
##
## The graph used to be ONE power system: SolarUI's battery, array and
## controller were built by walking every item under root. A site now holds
## many power ISLANDS, each with its own bus:
##   - a living vehicle's node (VehicleGraph: panels, MPPT, house battery,
##     inverter, loads), stepped by SystemGraphView._tick_vehicle_power;
##   - a festival camp's compound (CampTemplates), whose power is the four
##     CampPowerModel numbers on the compound.
## Everything inside an island belongs to that island, never to the site's
## own system. The flow engine still walks INTO islands (tanks, habitats):
## only the site's energy aggregates use walk_site_power().
##
## Pure and static (selftests load it under --script).

const KIND_SITE := "site"
const KIND_CAMP := "camp"
const KIND_VEHICLE := "vehicle"


## Is this compound the top of a power island?
static func is_power_island(item: Dictionary) -> bool:
	if str(item.get("type", "")) != "compound":
		return false
	return not island_kind(item).is_empty()


## "vehicle" | "camp" | "" for anything else.
static func island_kind(item: Dictionary) -> String:
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	if sp.has("vehicle_prop_id") or bool(sp.get("vehicle_system", false)):
		return KIND_VEHICLE
	if not str(sp.get("camp_lot_id", "")).is_empty():
		return KIND_CAMP
	if bool(sp.get("power_island", false)):
		return str(sp.get("power_island_kind", KIND_CAMP))
	return ""


static var _cache_model: WeakRef = null
static var _cache_key: String = ""
static var _cache: Dictionary = {}


## Every scope inside an island, at any depth -> the island compound's id.
## Memoised on the model's revisions (membership is set when a compound is
## realized, so struct_rev + user_rev cover every way it can change).
static func island_scopes(model: GraphModel) -> Dictionary:
	if model == null:
		return {}
	var key := "%d|%d|%d" % [model.struct_rev, model.user_rev, model.items.size()]
	if _cache_model != null and _cache_model.get_ref() == model and _cache_key == key:
		return _cache
	var out: Dictionary = {}
	var opens: Dictionary = {}   # child scope id -> the compound that opens it
	for item: Dictionary in model.items:
		var cs := str(item.get("child_scope_id", ""))
		if not cs.is_empty():
			opens[cs] = item
	for cs: String in opens.keys():
		var s := cs
		for _depth in 32:
			var owner: Variant = opens.get(s)
			if owner == null:
				break
			if is_power_island(owner as Dictionary):
				out[cs] = str((owner as Dictionary).get("id", ""))
				break
			s = str((owner as Dictionary).get("scope_id", GraphModel.ROOT_SCOPE_ID))
			if s == GraphModel.ROOT_SCOPE_ID:
				break
	_cache = out
	_cache_model = weakref(model)
	_cache_key = key
	return out


## The island compound an item belongs to ("" = the site's own system).
## An island compound itself belongs to the site (it sits at its parent's
## level); its CONTENTS belong to it.
static func island_of(model: GraphModel, item: Dictionary) -> String:
	var scopes := island_scopes(model)
	if scopes.is_empty():
		return ""
	return str(scopes.get(str(item.get("scope_id", GraphModel.ROOT_SCOPE_ID)), ""))


static func in_island(model: GraphModel, item: Dictionary) -> bool:
	return not island_of(model, item).is_empty()


## walk_items(root) without any island's contents: the site's OWN power
## system. The island compounds themselves are kept (aggregate loops match by
## item type and skip generic compounds), so callers that count compounds
## behave as before.
static func walk_site_power(model: GraphModel) -> Array:
	var all := GraphNesting.walk_items(model, GraphModel.ROOT_SCOPE_ID)
	var scopes := island_scopes(model)
	if scopes.is_empty():
		return all
	var out: Array = []
	for item: Dictionary in all:
		if scopes.has(str(item.get("scope_id", GraphModel.ROOT_SCOPE_ID))):
			continue
		out.append(item)
	return out


## Every island at or under `scope_id`, as {id, kind, scope, child_scope,
## name}. Nested islands are listed too (a vehicle parked inside a camp's
## compound is its own system).
static func list(model: GraphModel) -> Array:
	var out: Array = []
	if model == null:
		return out
	for item: Dictionary in model.items:
		if not is_power_island(item):
			continue
		var sp: Dictionary = item.get("specs", {}) as Dictionary
		out.append({
			"id": str(item.get("id", "")),
			"kind": island_kind(item),
			"scope": str(item.get("scope_id", GraphModel.ROOT_SCOPE_ID)),
			"child_scope": str(item.get("child_scope_id", "")),
			"name": str(sp.get("name", item.get("label", ""))),
		})
	return out
