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


## One system's state at a glance: {level: "ok" | "warn" | "crit" | "idle",
## text}. Camps read what the camp card already stamps (camp_ac, camp_soc,
## camp_open, camp_present / camp_headcount); vehicles read their own power
## state from SystemGraphView.vehicle_power_states() (`power`, may be {}).
## Pure: the outliner, breadcrumbs and (later) the festival board share it.
static func status(model: GraphModel, item: Dictionary, power: Dictionary = {}) -> Dictionary:
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	match island_kind(item):
		KIND_CAMP:
			var people := int(sp.get("camp_present", sp.get("camp_headcount", 0)))
			var open: Array = sp.get("camp_open", []) as Array
			var soc := float(sp.get("camp_soc", -1.0))
			if not bool(sp.get("camp_ac", true)):
				return {"level": "crit", "text": "no power"}
			if not open.is_empty():
				return {"level": "warn", "text": "%d open" % open.size()}
			if soc >= 0.0 and soc < 0.2:
				return {"level": "warn", "text": "%d%%" % int(round(soc * 100.0))}
			return {"level": "ok" if people > 0 else "idle", "text": "%d ppl" % people}
		KIND_VEHICLE:
			var kwh := 0.0
			var cap := 0.0
			if model != null:
				for it in model.get_items_in_scope(str(item.get("child_scope_id", ""))):
					var d: Dictionary = it
					if str(d.get("type", "")) == "battery":
						cap += float((d.get("specs", {}) as Dictionary).get("kwh", 0.0))
			if not power.is_empty():
				kwh = float(power.get("soc_kwh", 0.0))
				if not bool(power.get("ac_available", true)):
					return {"level": "crit", "text": "no power"}
			if cap <= 0.0:
				return {"level": "idle", "text": "no battery"}
			var frac := kwh / cap if not power.is_empty() else -1.0
			if frac < 0.0:
				return {"level": "idle", "text": "parked"}
			return {"level": "warn" if frac < 0.2 else "ok", "text": "%d%%" % int(round(frac * 100.0))}
	return {"level": "idle", "text": ""}


## The festival tile's status ring (Phase 2): one arc per channel, each
## "ok" | "warn" | "crit" | "idle". Camps read the stamped camp_* keys
## (camp_open names the loops neither closed nor wired out); vehicles read
## their own power state and their tanks' levels.
const RING_KEYS := ["power", "water", "food", "people"]
const WATER_KINDS := ["water", "greywater", "blackwater"]
const FOOD_KINDS := ["food", "food_waste", "firewood"]


static func ring(model: GraphModel, item: Dictionary, power: Dictionary = {}) -> Dictionary:
	var out := {"power": "idle", "water": "idle", "food": "idle", "people": "idle"}
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	match island_kind(item):
		KIND_CAMP:
			if not bool(sp.get("camp_ac", true)):
				out["power"] = "crit"
			elif sp.has("camp_soc"):
				out["power"] = "warn" if float(sp.get("camp_soc", 1.0)) < 0.2 else "ok"
			var open: Array = sp.get("camp_open", []) as Array
			var people := int(sp.get("camp_present", sp.get("camp_headcount", 0)))
			out["water"] = "ok" if people > 0 else "idle"
			out["food"] = out["water"]
			for k: Variant in open:
				var ks := str(k)
				if ks in WATER_KINDS:
					out["water"] = "warn"
				elif ks in FOOD_KINDS:
					out["food"] = "warn"
			var morale := float(sp.get("camp_morale", -1.0))
			if people > 0 and morale >= 0.0:
				out["people"] = "crit" if morale < 0.35 else ("warn" if morale < 0.55 else "ok")
		KIND_VEHICLE:
			var st := status(model, item, power)
			out["power"] = str(st.get("level", "idle"))
			if model != null:
				var fresh := -1.0
				var grey := -1.0
				for it in model.get_items_in_scope(str(item.get("child_scope_id", ""))):
					var d: Dictionary = it
					if str(d.get("type", "")) != "resource":
						continue
					var ds: Dictionary = d.get("specs", {}) as Dictionary
					var lvl := clampf(float(ds.get("level", 0.0)), 0.0, 1.0)
					var rk := str(ds.get("resource_kind", ""))
					if rk == "water":
						fresh = lvl if fresh < 0.0 else minf(fresh, lvl)
					elif rk == "greywater" or rk == "blackwater":
						grey = maxf(grey, lvl)
				if fresh >= 0.0:
					out["water"] = "crit" if fresh < 0.1 else ("warn" if fresh < 0.25 else "ok")
				if grey > 0.9 and out["water"] != "crit":
					out["water"] = "warn"
	return out


## "Arrange by site": each system card where its system stands on the map
## (`origin` + site × `px_per_m`, centred), then pushed out on a spiral until
## it overlaps neither a card already placed nor an `obstacles` rect (the
## site's own nodes). Cards nearest the site centre are placed first, so the
## middle keeps its shape and the edges give way. `cards`: [{id, site:
## Vector2, size: Vector2}]. Returns {id: top-left Vector2}. Pure.
static func arrange_by_site(cards: Array, obstacles: Array, origin: Vector2,
		px_per_m: float, gap: float = 16.0) -> Dictionary:
	var order := cards.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var la := (a["site"] as Vector2).length_squared()
		var lb := (b["site"] as Vector2).length_squared()
		if is_equal_approx(la, lb):
			return str(a["id"]) < str(b["id"])
		return la < lb)
	var taken: Array[Rect2] = []
	for o: Variant in obstacles:
		taken.append((o as Rect2).grow(gap))
	var out: Dictionary = {}
	for c: Dictionary in order:
		var sz: Vector2 = c["size"]
		var want: Vector2 = origin + (c["site"] as Vector2) * px_per_m - sz * 0.5
		var step := (sz + Vector2(gap, gap)) * 0.5
		var pos := want
		var found := false
		for r in 64:
			for dy in range(-r, r + 1):
				for dx in range(-r, r + 1):
					if maxi(absi(dx), absi(dy)) != r:
						continue
					var p := want + Vector2(dx, dy) * step
					var rr := Rect2(p, sz)
					var free := true
					for t: Rect2 in taken:
						if t.intersects(rr):
							free = false
							break
					if free:
						pos = p
						found = true
						break
				if found:
					break
			if found:
				break
		out[str(c["id"])] = pos
		taken.append(Rect2(pos, sz).grow(gap * 0.5))
	return out


## A map scale for arrange_by_site: wide enough that the median nearest
## neighbour sits a card and a bit apart (camps 30 m apart at the default
## 4 px/m would all land on each other), never below 2 or above 40 px/m.
static func auto_px_per_m(sites: Array, card: Vector2) -> float:
	if sites.size() < 2:
		return 4.0
	var nn: Array[float] = []
	for i in sites.size():
		var best := INF
		for j in sites.size():
			if i != j:
				best = minf(best, (sites[i] as Vector2).distance_to(sites[j] as Vector2))
		if best > 0.01 and is_finite(best):
			nn.append(best)
	if nn.is_empty():
		return 4.0
	nn.sort()
	var med := nn[nn.size() / 2]
	return clampf(card.x * 1.15 / med, 2.0, 40.0)


## Site positions for the contents of an island (Phase 2: the lenses honour
## the sub-graph). A child with its own place (a bound prop, the camp's
## habitat) keeps it; the rest (flagged `site_derived`) are laid round the
## island's own site point in the shape they have on the canvas, scaled to
## fit `radius_m`. Returns {child_id: Vector2} for the ones to write.
static func derived_child_sites(model: GraphModel, compound: Dictionary, radius_m: float) -> Dictionary:
	var out: Dictionary = {}
	if model == null or not GraphSiteLayout.has_site_coords(compound):
		return out
	var kids := model.get_items_in_scope(str(compound.get("child_scope_id", "")))
	var move: Array = []
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for it in kids:
		var d: Dictionary = it
		if GraphSiteLayout.has_site_coords(d) and not bool(d.get("site_derived", false)):
			continue
		var c := Vector2(float(d.get("x", 0.0)) + float(d.get("width", 120.0)) * 0.5,
			float(d.get("y", 0.0)) + float(d.get("height", 90.0)) * 0.5)
		move.append([str(d.get("id", "")), c])
		lo = lo.min(c)
		hi = hi.max(c)
	if move.is_empty():
		return out
	var mid := (lo + hi) * 0.5
	var half := maxf(maxf(hi.x - lo.x, hi.y - lo.y) * 0.5, 1.0)
	var k := radius_m / half if move.size() > 1 else 0.0
	var base := GraphSiteLayout.site_xz(compound)
	for m: Array in move:
		out[str(m[0])] = base + ((m[1] as Vector2) - mid) * k
	return out


## How far an island's contents spread on the map (derived_child_sites).
static func island_radius_m(item: Dictionary) -> float:
	match island_kind(item):
		KIND_VEHICLE:
			return 3.5
		KIND_CAMP:
			return 14.0
	return 8.0


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
