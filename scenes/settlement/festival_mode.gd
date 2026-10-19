class_name FestivalMode
extends Node

## FESTIVAL MODE — the one-button way into the crowd simulation, on easy
## supplies.
##
## Before this, watching a festival crowd meant: draw a festival road, cut a
## zone into lots, add roster entries, assign them (only an ASSIGNED lot
## becomes a camp compound on the graph — a painted camp is scenery), tag a
## kitchen, beds, portapotties, a water point, showers and a stage by hand,
## tick four testing switches in Settings so nobody starved or walked out,
## and then open the settlement view somewhere near all of it. Nobody found
## that path; the harness was the only thing that ever walked it.
##
## This node walks it. `open()`:
##   1. switches PopTestPrefs' EASY OVERRIDE on — ideal supply (every need
##      met, the camps assumed stocked), no queues, no departures, no alarm
##      feed — for the SESSION, without touching the player's saved flags;
##   2. gives every painted camp a headcount (TerrainLoader.populate_camp_areas,
##      density from the placement tool) and a default camp to every
##      unassigned lot, so each becomes a camp compound with a pop-driven
##      habitat; with nothing painted at all it seeds a demo zone next to
##      the player, and on a scene with no TerrainLoader it seeds plain
##      habitats on the graph;
##   3. tags whatever the festival still lacks — a sleep + kitchen area per
##      camp and the shared set (FestivalSeedLayout) — labelled with the
##      festival prefix so it can be cleared again;
##   4. makes sure people DRAW (crowd_draw != none) and the clock runs;
##   5. opens the settlement view over the camps at a height that frames them.
## `close()` hands the guardrails back and closes the view; the camps and
## venues STAY (they are the player's site now). `clear_seeded()` removes
## exactly what this seeded — venues by label prefix, headcounts back to 0,
## the demo zone/road, the fallback habitats — and nothing else.
##
## Rules inherited from the settlement view: the clock is only ever NUDGED
## once (unpaused if paused), never claimed; no orders.

signal changed()

const DEFAULT_TIME_SCALE := 0.01     # 36×, main.gd's own default
const MIN_START_H := 140.0
const MAX_START_H := 900.0
const EVENING_H := 19.5
const MORNING_H := 10.0
const DEMO_ROAD_NAME := "Festival demo road"
const DEMO_ZONE_NAME := "Festival demo zone"
const DEMO_HALF_W := 120.0
const DEMO_HALF_D := 72.0
const DEMO_LOTS := 16
## Fallback (no TerrainLoader): habitats seeded straight on the graph.
const FALLBACK_PEOPLE := 120
const FALLBACK_HABITATS := 3
const FALLBACK_RING_M := 70.0
const FALLBACK_ITEM_PREFIX := "fest_hab_"

var _main: Node = null
var _active := false
var _opening := false
var _seeded_space_ids: Array = []
var _seeded_zone_id := ""
var _seeded_road_id := ""
var _notes: PackedStringArray = PackedStringArray()
var _status: Dictionary = {}
var _status_accum := 0.0


func _ready() -> void:
	set_process(false)


func is_active() -> bool:
	return _active


func is_opening() -> bool:
	return _opening


## What the HUD prints: people / camps / tiers / venues seeded / notes.
func status() -> Dictionary:
	return _status


func notes() -> PackedStringArray:
	return _notes


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func open(main: Node) -> void:
	if _active or _opening or main == null:
		return
	_main = main
	_opening = true
	_notes = PackedStringArray()
	PopTestPrefs.set_easy_override(true)
	var sgv := ServiceLocator.graph()
	if sgv == null:
		_note("No systems graph on this map — festival mode needs one.")
		_opening = false
		PopTestPrefs.set_easy_override(false)
		changed.emit()
		return
	# People must be drawable, or the whole point is invisible.
	if NpcDisplayPrefs.crowd_draw() == NpcDisplayPrefs.CROWD_NONE:
		NpcDisplayPrefs.set_crowd_draw(NpcDisplayPrefs.CROWD_ALL)
		_note("Crowd drawing was off (Settings → NPCs) — turned on.")
	if not NpcDisplayPrefs.npcs_enabled():
		NpcDisplayPrefs.set_npcs_enabled(true)
		_note("NPCs were switched off (Settings → NPC) — turned back on.")
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.has_method("populate_camp_areas"):
		_assign_unassigned_lots(loader)
		var pop: Dictionary = loader.call("populate_camp_areas")
		if int(pop.get("changed", 0)) > 0:
			_note("Populated %s (%s)." % [UiText.count(int(pop["changed"]), "painted camp"),
				UiText.count(int(pop["people"]), "person", "people")])
		var summary: Dictionary = loader.call("camp_population_summary")
		if int(summary.get("camps", 0)) == 0:
			_seed_demo_zone(loader, main)
	# The graph sync is deferred; give it the frames it needs.
	for _i in 4:
		await get_tree().process_frame
	if not is_instance_valid(sgv):
		_opening = false
		return
	var camps: Array = _camps(sgv, loader)
	if camps.is_empty() and loader == null:
		_seed_fallback_habitats(sgv, main)
		for _i in 2:
			await get_tree().process_frame
		camps = _camps(sgv, loader)
	if camps.is_empty():
		_note("Nothing to populate: paint a camp (C) or cut a zone into lots, then try again.")
	else:
		_seed_venues(main, sgv, loader, camps)
		_tag_effigy(main, sgv, loader)
	# Wake the population bridge now rather than on the next ambient tick, so
	# the HUD has numbers on its first refresh.
	if sgv.has_method("npc_population_bridge"):
		var bridge: Variant = sgv.call("npc_population_bridge")
		if bridge != null and bridge.has_method("set_watched_habitat"):
			bridge.call("set_watched_habitat", "")
	if "time_scale" in main and float(main.get("time_scale")) <= 0.0:
		main.set("time_scale", DEFAULT_TIME_SCALE)
		_note("Clock was paused — running at %d×." % int(round(DEFAULT_TIME_SCALE * 3600.0)))
	_active = true
	_opening = false
	set_process(true)
	_refresh_status()
	# Frame the camps: centre of the cluster, high enough to see all of it.
	var polys: Array = []
	for c in camps:
		polys.append((c as Dictionary)["poly"])
	var cl := FestivalSeedLayout.cluster(polys)
	var at: Vector2 = cl["centre"] if not polys.is_empty() else Vector2.INF
	var h := clampf(float(cl["radius"]) * 1.8, MIN_START_H, MAX_START_H)
	if main.has_method("open_settlement_view"):
		main.call("open_settlement_view", at, h)
	changed.emit()


## Hand the guardrails back and leave the view. The camps and venues stay —
## they are the player's site now; `clear_seeded()` is the undo.
func close() -> void:
	if not _active and not _opening:
		return
	_active = false
	_opening = false
	set_process(false)
	PopTestPrefs.set_easy_override(false)
	if _main != null and _main.has_method("settlement_view_open") and bool(_main.call("settlement_view_open")):
		var view: Variant = _main.get("settlement_view")
		if view != null:
			view.call("close")
	changed.emit()


## Remove exactly what festival mode seeded: venues by label prefix,
## painted-camp headcounts back to 0, the demo zone + road, the fallback
## habitats. Closes the mode too, since there is nothing left to watch.
func clear_seeded() -> void:
	var main := _main if _main != null else get_tree().current_scene
	if main == null:
		return
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var reg: SpaceRegistry = _registry(main, sgv)
	var removed := 0
	if reg != null:
		for rec in reg.spaces.duplicate():
			if str((rec as Dictionary).get("label", "")).begins_with(FestivalSeedLayout.LABEL_PREFIX):
				if reg.remove_space(str((rec as Dictionary)["id"])):
					removed += 1
				continue
			# The evening set festival mode gave a player's own stage.
			var prog: Array = (rec as Dictionary).get("program", [])
			var kept: Array = []
			for s in prog:
				if not str((s as Dictionary).get("label", "")).begins_with(FestivalSeedLayout.LABEL_PREFIX):
					kept.append(s)
			if kept.size() != prog.size():
				reg.set_space_fields(str((rec as Dictionary)["id"]), {"program": kept})
		_save_registry(main, loader, reg)
	_seeded_space_ids.clear()
	if loader != null:
		if not _seeded_zone_id.is_empty() and loader.has_method("delete_placement_zone"):
			loader.call("delete_placement_zone", _seeded_zone_id)
		if not _seeded_road_id.is_empty() and loader.has_method("delete_festival_road"):
			loader.call("delete_festival_road", _seeded_road_id)
		_seeded_zone_id = ""
		_seeded_road_id = ""
		if loader.has_method("depopulate_camp_areas"):
			loader.call("depopulate_camp_areas")
	if sgv != null and sgv.get("model") != null:
		var model: Variant = sgv.get("model")
		for it in model.get_items_in_scope("root"):
			var iid := str((it as Dictionary).get("id", ""))
			if iid.begins_with(FALLBACK_ITEM_PREFIX):
				model.remove_item(iid)
	_note("Cleared %s and every festival headcount." % UiText.count(removed, "seeded venue"))
	close()


## The festival's total population (PopTestPrefs, 0 = the camps' natural
## headcounts). Saved globally — it is a performance knob. The camps' own
## headcounts are never rewritten: the graph sync scales them, and the
## population bridge resizes each roster IN PLACE on its next tick.
func set_target_people(n: int) -> void:
	PopTestPrefs.set_festival_target_people(n)
	PopTestPrefs.save()
	var loader := TerrainSurfaceQuery.find_terrain_loader(_main) if _main != null else null
	if loader != null and loader.has_method("apply_festival_population_target"):
		var r: Dictionary = loader.call("apply_festival_population_target")
		_note("Population %s: %d people (natural %d)." % [
			"target" if n > 0 else "back to natural", int(r.get("people", 0)), int(r.get("natural", 0))])
	_refresh_status()


## The two clock jumps the HUD offers — a festival is an EVENING thing (the
## stage set runs 20:00–02:00; camps sleep 02:30–09:30), and a tester
## landing at noon would otherwise watch people eat lunch for an hour.
func jump_to_hour(hour: float) -> void:
	if _main != null and "day_time" in _main:
		_main.set("day_time", fposmod(hour, 24.0))


# ---------------------------------------------------------------------------
# Seeding
# ---------------------------------------------------------------------------

## Every placement lot with no camp on it gets a default one (the loader's
## own update_lot_camp fills style + headcount from the zone and the lot's
## usable area), so cut-but-never-assigned zones populate too.
func _assign_unassigned_lots(loader: Node) -> void:
	var placement: Variant = loader.get("placement")
	if placement == null or not loader.has_method("update_lot_camp"):
		return
	var n := 0
	for l in (placement.get("lots") as Array).duplicate():
		var lot: Dictionary = l
		if (lot.get("assigned_camp", {}) as Dictionary).is_empty():
			if bool(loader.call("update_lot_camp", str(lot["lot_id"]), {})):
				n += 1
	if n > 0:
		_note("Assigned default camps to %s." % UiText.count(n, "empty lot"))


## No camps anywhere: a road + zone next to the player, cut into lots and
## assigned — the harness's own step 1, so a bare map still has a festival
## to watch. Remembered so clear_seeded can take it away again.
func _seed_demo_zone(loader: Node, main: Node) -> void:
	if not loader.has_method("add_placement_zone"):
		return
	var player := main.get_node_or_null("Player") as Node3D
	var origin := Vector2(player.global_position.x, player.global_position.z) if player != null else Vector2.ZERO
	var zc := origin + Vector2(0.0, -150.0)
	var zone_poly := PackedVector2Array([zc + Vector2(-DEMO_HALF_W, -DEMO_HALF_D), zc + Vector2(DEMO_HALF_W, -DEMO_HALF_D),
		zc + Vector2(DEMO_HALF_W, DEMO_HALF_D), zc + Vector2(-DEMO_HALF_W, DEMO_HALF_D)])
	var road_pts := FestivalPlacementLayer.road_from_zone_spine(zone_poly, 90.0)
	_seeded_road_id = str(loader.call("add_festival_road", road_pts, {"name": DEMO_ROAD_NAME, "width_m": 8.0}))
	_seeded_zone_id = str(loader.call("add_placement_zone", zone_poly, {
		"name": DEMO_ZONE_NAME,
		"spec": {"mode": "count", "target_n": DEMO_LOTS, "depth_m": 30.0, "lane_w_m": 5.0,
			"lots_per_lane": 6, "styles": ["mixed", "theme_camp", "rv_park", "car_camping"]},
		"subdivide": true}))
	if _seeded_zone_id.is_empty():
		_note("Could not seed a demo zone here (steep or built-up ground).")
		return
	_assign_unassigned_lots(loader)
	_note("Seeded a demo festival zone next to you (%d lots)." % DEMO_LOTS)


## Built-in scenes (Soak / Mars) have no TerrainLoader, so nothing to paint:
## plain pop-driven habitats on the graph, homes in a ring around the player.
func _seed_fallback_habitats(sgv: Node, main: Node) -> void:
	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		return
	var player := main.get_node_or_null("Player") as Node3D
	var origin := Vector2(player.global_position.x, player.global_position.z) if player != null else Vector2.ZERO
	var per := int(ceil(float(FALLBACK_PEOPLE) / float(FALLBACK_HABITATS)))
	for h in FALLBACK_HABITATS:
		var ang := TAU * float(h) / float(FALLBACK_HABITATS)
		var home := origin + Vector2(sin(ang), -cos(ang)) * FALLBACK_RING_M
		var hab_id := "%s%d" % [FALLBACK_ITEM_PREFIX, h]
		if not (model.get_item(hab_id) as Dictionary).is_empty():
			continue
		model.add_item({
			"id": hab_id, "type": "processor", "x": 200.0 * h, "y": 900.0,
			"width": 150.0, "height": 150.0,
			"specs": {
				"name": "Festival camp %d" % (h + 1), "role": "habitat", "occupants": per,
				"pop_driven": true, "watts": 0.0, "energy_source": "", "efficiency": 1.0,
				"home_x": home.x, "home_z": home.y, "site_x_m": home.x, "site_z_m": home.y,
				"pop_routine": NpcRoutine.festival_day().to_array(),
				"inputs": [
					{"kind": "water", "rate": 2.083, "unit": "L/h"},
					{"kind": "food", "rate": 0.0625, "unit": "kg/h"},
				],
				"outputs": [
					{"kind": "greywater", "rate": 1.666, "unit": "L/h"},
					{"kind": "blackwater", "rate": 0.417, "unit": "L/h"},
				],
			},
		})
	_note("No terrain loader here — seeded %d plain camps (%d people) around you." % [
		FALLBACK_HABITATS, FALLBACK_PEOPLE])


## Camps to seed venues for and frame: [{id, name, poly, headcount}]. From
## the graph's camp compounds (outline via the loader), else the fallback
## habitats (a square around each home).
func _camps(sgv: Node, loader: Node) -> Array:
	var out: Array = []
	if sgv.has_method("festival_camps"):
		for c in sgv.call("festival_camps"):
			var cd: Dictionary = c
			var poly := PackedVector2Array()
			if loader != null and loader.has_method("camp_lot_polygon"):
				poly = loader.call("camp_lot_polygon", str(cd.get("lot_id", "")))
			if poly.size() < 3:
				continue
			out.append({"id": str(cd.get("id", "")), "name": str(cd.get("name", "Camp")),
				"poly": poly, "headcount": int(cd.get("headcount", 0))})
	if not out.is_empty():
		return out
	var model: Variant = sgv.get("model")
	if model == null:
		return out
	for it in model.get_items_in_scope("root"):
		var d: Dictionary = it
		var iid := str(d.get("id", ""))
		if not iid.begins_with(FALLBACK_ITEM_PREFIX):
			continue
		var specs: Dictionary = d.get("specs", {})
		var home := Vector2(float(specs.get("home_x", 0.0)), float(specs.get("home_z", 0.0)))
		out.append({"id": iid, "name": str(specs.get("name", "Camp")),
			"poly": FestivalSeedLayout.square(home, 22.0), "headcount": int(specs.get("occupants", 0))})
	return out


## Tag what the festival still lacks. Types the player already tagged are
## left alone (their layout is theirs); only the missing ones are seeded.
func _seed_venues(main: Node, sgv: Node, loader: Node, camps: Array) -> void:
	var reg: SpaceRegistry = _registry(main, sgv)
	if reg == null:
		return
	var present: Array = []
	for rec in reg.spaces:
		var t := str((rec as Dictionary).get("space_type", ""))
		if not present.has(t):
			present.append(t)
	var missing := FestivalSeedLayout.missing_types(present)
	# A stage the player tagged with NO programme gets the festival's evening
	# set, so it has a crowd and a DJ when the sun goes down. The slot is
	# labelled with the prefix, so Clear takes it off again.
	var programmed := 0
	for rec0 in reg.spaces:
		var r0: Dictionary = rec0
		if str(r0.get("space_type", "")) == "stage" and (r0.get("program", []) as Array).is_empty():
			var slot: Dictionary = FestivalSeedLayout.STAGE_SET.duplicate()
			slot["label"] = FestivalSeedLayout.LABEL_PREFIX + "evening set"
			reg.set_space_fields(str(r0.get("id", "")), {"program": [slot]})
			programmed += 1
	if programmed > 0:
		_save_registry(main, loader, reg)
		_note("Gave %s the 20:00–02:00 evening set." % UiText.count(programmed, "stage"))
	# Enrichment is what the evening IS; a site with no venue of any kind
	# gets the three. (fire circles need firewood wired in; stages do not.)
	var has_venue := false
	for t in present:
		if SpaceTypes.is_enrichment(str(t)):
			has_venue = true
	if not has_venue:
		for t in ["stage", "center_camp", "temple"]:
			if not missing.has(t):
				missing.append(t)
	# Art is the afternoon: the SOCIAL blocks' venue visits and wanders need
	# somewhere to go by day. Seeded whenever none is tagged — on a site that
	# already has its stage, temple and center camp too.
	if not present.has("art") and not missing.has("art"):
		missing.append("art")
	# Where the already-tagged beds and kitchens stand (per-camp types are
	# seeded for every camp whose outline holds none — FestivalSeedLayout
	# .needs_seeding).
	var existing: Array = []
	for rec_e in reg.spaces:
		var re: Dictionary = rec_e
		var te := str(re.get("space_type", ""))
		if FestivalSeedLayout.PER_CAMP_TYPES.has(te):
			existing.append({"type": te, "pos": reg.resolve_position(re, main)})
	var camp_short := false
	for c_e in camps:
		for te2 in FestivalSeedLayout.PER_CAMP_TYPES:
			if FestivalSeedLayout.needs_seeding({"type": te2, "camp_id": str((c_e as Dictionary).get("id", "")),
					"poly": FestivalSeedLayout.poly_to_array((c_e as Dictionary).get("poly", PackedVector2Array()))},
					missing, existing):
				camp_short = true
	if missing.is_empty() and not camp_short:
		_note("Your tagged spaces cover every need — nothing seeded.")
		return
	var free_fn := Callable()
	if loader != null and loader.has_method("festival_ground_free"):
		free_fn = Callable(loader, "festival_ground_free")
	var plan := FestivalSeedLayout.venue_plan(camps, free_fn)
	var labels: Dictionary = {}
	for rec in reg.spaces:
		labels[str((rec as Dictionary).get("label", ""))] = true
	var added := 0
	for v in plan:
		var vd: Dictionary = v
		if not FestivalSeedLayout.needs_seeding(vd, missing, existing):
			continue
		if labels.has(str(vd["label"])):
			continue
		var sid := reg.set_space_type({"kind": "area", "poly": vd["poly"]},
			str(vd["type"]), int(vd["cap"]), str(vd["label"]))
		if sid.is_empty():
			continue
		var fields: Dictionary = vd.get("fields", {})
		if not fields.is_empty():
			reg.set_space_fields(sid, fields)
		_seeded_space_ids.append(sid)
		added += 1
	if added > 0:
		_save_registry(main, loader, reg)
		_note("Seeded %s (%s)." % [UiText.count(added, "venue"), ", ".join(PackedStringArray(missing))
			if not missing.is_empty() else "beds and kitchens for the camps that had none"])


## The burn structure: with no effigy tagged, the BURNABLE placed prop
## (the one with a fire plan, else the first marked burnable) becomes one,
## so lighting it gathers the festival. Labelled with the prefix like every
## other seeded space, so Clear takes the tag away again.
func _tag_effigy(main: Node, sgv: Node, loader: Node) -> void:
	var reg: SpaceRegistry = _registry(main, sgv)
	if reg == null or loader == null or not loader.has_method("placed_prop_records"):
		return
	if not reg.spaces_of_type("effigy").is_empty():
		return
	var best: Dictionary = {}
	for r in loader.call("placed_prop_records"):
		var rec: Dictionary = r
		if not bool(rec.get("burnable", false)) and not rec.has("fire_plan") and not rec.has("burn"):
			continue
		if best.is_empty() or (rec.has("fire_plan") and not best.has("fire_plan")):
			best = rec
	if best.is_empty():
		return
	var pid := str(best.get("id", ""))
	if pid.is_empty():
		return
	var sid := reg.set_space_type({"kind": "prop", "prop_id": pid}, "effigy",
		SpaceRegistry.CAPACITY_AUTO, FestivalSeedLayout.LABEL_PREFIX + "Effigy")
	if sid.is_empty():
		return
	reg.set_space_fields(sid, {"draw": 0.5})
	_seeded_space_ids.append(sid)
	_save_registry(main, loader, reg)
	_note("Tagged the burnable structure as the Effigy — light it and the festival gathers.")


func _registry(main: Node, sgv: Node) -> SpaceRegistry:
	if sgv != null and sgv.has_method("npc_population_bridge"):
		var bridge: Variant = sgv.call("npc_population_bridge")
		if bridge != null and bridge.has_method("registry_for"):
			return bridge.call("registry_for", main)
	return null


func _save_registry(main: Node, loader: Node, reg: SpaceRegistry) -> void:
	if loader != null and loader.has_method("save_npc_spaces"):
		loader.call("save_npc_spaces")
	elif main != null and not str(main.scene_file_path).is_empty():
		reg.save_for_scene(str(main.scene_file_path))


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	_status_accum += delta
	if _status_accum < 0.5:
		return
	_status_accum = 0.0
	_refresh_status()


func _refresh_status() -> void:
	var out := {"people": 0, "camps": 0, "full": 0, "light": 0, "venues": _seeded_space_ids.size(),
		"easy": PopTestPrefs.easy_override()}
	if _main == null:
		_status = out
		return
	var sgv := ServiceLocator.graph()
	if sgv == null:
		_status = out
		return
	if sgv.has_method("festival_camps"):
		var camps: Array = sgv.call("festival_camps")
		out["camps"] = camps.size()
	if sgv.has_method("npc_population_bridge"):
		var bridge: Variant = sgv.call("npc_population_bridge")
		if bridge != null and bridge.has_method("population_counts"):
			var pc: Dictionary = bridge.call("population_counts")
			out["full"] = int(pc.get("full", 0))
			out["light"] = int(pc.get("light", 0))
			out["people"] = int(out["full"]) + int(out["light"])
	out["target"] = PopTestPrefs.festival_target_people()
	var loader0 := TerrainSurfaceQuery.find_terrain_loader(_main)
	if loader0 != null and loader0.has_method("camp_population_summary"):
		out["natural"] = int((loader0.call("camp_population_summary") as Dictionary).get("natural", 0))
	if int(out["camps"]) == 0 and int(out["people"]) > 0:
		# Fallback habitats are not compounds; count them as camps.
		var model: Variant = sgv.get("model")
		if model != null:
			for it in model.get_items_in_scope("root"):
				if str((it as Dictionary).get("id", "")).begins_with(FALLBACK_ITEM_PREFIX):
					out["camps"] = int(out["camps"]) + 1
	_status = out


func _note(text: String) -> void:
	_notes.append(text)
	print("FestivalMode: %s" % text)
