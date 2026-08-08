class_name UnpackScenario
extends RefCounted
## "Unpack a system" delivery scenarios — PACKING_PLAN.md Phase 6 v1. A
## scenario spawns as REAL world state: a shipping container standing on the
## site with the kit's crates staged beside its door, every one a normal
## placed prop with `packed: true` — so the whole existing Phase 5 loop
## (Interact to unpack, drawer to repack, graph honesty) IS the gameplay,
## and progress is just counting records. No bespoke scenario state machine.
##
## Group-labor bridge: `crew_estimate` runs NpcHaulModel over the unload
## route so a scenario can answer "how long with N people, and should they
## form a bucket brigade?" — the first step toward rules-driven crowd
## gameplay (see PACKING_PLAN.md Phase 8 vision).

## Scenario units are PLACEABLE MODELS (the packable subset of the catalog),
## spawned packed. Linkage entries get a default v30 design so the crate's
## computed envelope — and the structure that unpacks out of it — are real.
const SCENARIOS := {
	"starter_camp": {
		"label": "Starter Camp Delivery",
		"notes": "Shelter, shade, power, water, food — one 20' container drop.",
		"container_id": "container_20",
		"units": [
			{"model_id": "shiftpod", "count": 2},
			{"model_id": "ez_up", "count": 1},
			{"model_id": "small_hawt", "count": 1},
			{"model_id": "pp_shredder", "count": 1},
			{"model_id": "grow_bed", "count": 2},
		],
	},
	"starshade_kit": {
		"label": "StarShade Kit Delivery",
		"notes": "The folded scissor structure, delivered as its honest crate.",
		"container_id": "container_20",
		# Which PackDefs kit this scenario delivers. The Packing Lab maps its
		# selected kit through THIS field — the old code relied on the PackDefs
		# id happening to equal the scenario id, and silently coerced every
		# unmapped kit to starter_camp.
		"pack_kit_id": "starshade_kit",
		"units": [
			{"model_id": "linkage_structure", "count": 1, "linkage_default": true},
		],
	},
}

## Crates land in a tight stack at the container DOOR; each carries the
## staging slot it is destined for, so the unload is a real haul the crew
## (or the player) actually performs. Geometry in metres from the container
## centre along its forward (+door) axis.
const DOOR_STACK_OFFSET_M := 1.5     # first stack row past the door end
const DOOR_STACK_PITCH_M := 1.4      # row pitch inside the stack
const STAGING_OFFSET_M := 9.0        # first staging row — the haul destination
const STAGING_PITCH_M := 3.0         # walking-aisle staging rows


static func scenario_ids() -> Array:
	var out: Array = SCENARIOS.keys()
	out.sort()
	return out


static func find(scenario_id: String) -> Dictionary:
	return SCENARIOS.get(scenario_id, {})


## The scenario that delivers a given PackDefs kit, or "" when none does —
## the caller must then refuse rather than deliver a different kit.
static func scenario_for_kit(kit_id: String) -> String:
	if kit_id.is_empty():
		return ""
	for sid in SCENARIOS:
		if str((SCENARIOS[sid] as Dictionary).get("pack_kit_id", "")) == kit_id:
			return str(sid)
	return ""


## Solve where this scenario's crates actually RIDE inside the container, and
## in what order they can be taken back out.
##
## Returns {ok, container_id, interior, items, placements, order, overflow}.
## `items` walk `units × count` in the SAME order spawn() does, so an item
## index is a delivery slot. `order` is the LIFO removal sequence.
##
## Two constraints make this narrower than a general pack:
##   • `this_side_up` is FORCED on every item. PackSolver otherwise returns all
##     six axis permutations, but a spawned crate is a BoxMesh(w,h,d) with yaw
##     applied and nothing else — only (w,h,d) and (d,h,w) can be rendered, and
##     forcing the flag restricts the solver to exactly those two.
##   • The LIFO sort ends on `item_index` because Godot's sort_custom is not
##     stable; without a total order the same scenario could stow differently
##     between runs.
static func stow_plan(scenario_id: String) -> Dictionary:
	var sc := find(scenario_id)
	var out := {"ok": false, "container_id": "", "interior": {},
		"items": [], "placements": [], "order": [], "overflow": []}
	if sc.is_empty():
		return out
	var container_id := str(sc.get("container_id", "container_20"))
	var entry := ContainerCatalog.find(container_id)
	if entry.is_empty():
		return out
	out["container_id"] = container_id
	out["interior"] = (entry.get("interior", {}) as Dictionary).duplicate()
	var items: Array = []
	for unit in sc.get("units", []):
		var u := unit as Dictionary
		var model_id := str(u.get("model_id", ""))
		for _i in maxi(int(u.get("count", 1)), 1):
			var spec: Dictionary = {}
			if bool(u.get("linkage_default", false)):
				spec = LinkageStructureBuilder.packed_spec_for(LinkageParams.new())
			if spec.is_empty():
				spec = PackedSpec.for_model(model_id)
			if spec.is_empty():
				continue
			var item: Dictionary = spec.duplicate(true)
			# AFTER for_model, so PackedSpec.normalize's w>=d>=h canonicalisation
			# has already run and is not re-applied against the locked axis.
			item["this_side_up"] = true
			item["model_id"] = model_id
			item["label"] = str(ModelCatalog.find(model_id).get("label", model_id))
			item["linkage_default"] = bool(u.get("linkage_default", false))
			items.append(item)
	if items.is_empty():
		return out
	var solved := PackSolver.solve(entry, items)
	out["items"] = items
	out["placements"] = solved.get("placements", [])
	out["overflow"] = solved.get("overflow", [])
	# LIFO: highest top first, then nearest the door (high z), then left. Never
	# removes a box that still has something resting on it, because the solver
	# only ever stacks strictly above.
	var ranked: Array = (out["placements"] as Array).duplicate()
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector3 = a["pos"]
		var sa: Vector3 = a["size"]
		var pb: Vector3 = b["pos"]
		var sb: Vector3 = b["size"]
		if absf((pa.y + sa.y) - (pb.y + sb.y)) > 0.001:
			return (pa.y + sa.y) > (pb.y + sb.y)
		if absf((pa.z + sa.z) - (pb.z + sb.z)) > 0.001:
			return (pa.z + sa.z) > (pb.z + sb.z)
		if absf(pa.x - pb.x) > 0.001:
			return pa.x < pb.x
		return int(a["item_index"]) < int(b["item_index"]))
	var order: Array = []
	for r in ranked:
		order.append(int((r as Dictionary)["item_index"]))
	out["order"] = order
	out["ok"] = not (out["placements"] as Array).is_empty()
	return out


## Spawn a scenario onto a PlacedPropLayer at (cx, cz), facing `yaw_deg`.
## Caller (TerrainLoader.deliver_packed_kit) saves + rebuilds. Returns
## {container_prop_id, crate_ids: [..], scenario_id} or {} on failure.
##
## v3 (Round 3): crates ride STOWED INSIDE the container at solver-computed
## positions (`stow_plan`), each stamped with the staging slot it is destined
## for ({staging: {x, z}}), its delivery identity ({delivery_id,
## delivery_slot}), a `stowed_in` back-pointer and an `unload_rank` (LIFO), and
## the container record keeps the whole delivery blob.
##
## `crate_ids` is returned IN UNLOAD ORDER, so every downstream consumer
## inherits LIFO without knowing the scenario. Anything the solver could not
## fit falls back to the pre-v3 door-stack rows, so an oversized future unit
## degrades visibly instead of vanishing.
##
## Note the container mesh is a SOLID box with no cavity, so stowed crates are
## not visible in-world; the Packing Lab is the surface that shows the load.
static func spawn(layer: PlacedPropLayer, scenario_id: String,
		cx: float, cz: float, yaw_deg: float = 0.0, abs_h: float = 0.0) -> Dictionary:
	var sc := find(scenario_id)
	if layer == null or sc.is_empty():
		return {}
	var container_id := str(sc.get("container_id", "container_20"))
	var cid := layer.add_free_prop("cargo_container", cx, 0.0, cz, yaw_deg)
	if cid.is_empty():
		return {}
	var fwd := Vector2(sin(deg_to_rad(yaw_deg)), cos(deg_to_rad(yaw_deg)))
	var side := Vector2(fwd.y, -fwd.x)
	var entry := ContainerCatalog.find(container_id)
	var half_l: float = float((entry.get("exterior", {}) as Dictionary).get("l_m", 6.0)) * 0.5

	var plan := stow_plan(scenario_id)
	var interior: Dictionary = plan.get("interior", {})
	var cw := float(interior.get("w_m", 0.0))
	var cl := float(interior.get("l_m", 0.0))
	# item_index -> placement, and item_index -> LIFO rank.
	var placed_by_item: Dictionary = {}
	for pl in plan.get("placements", []):
		placed_by_item[int((pl as Dictionary)["item_index"])] = pl
	var rank_of: Dictionary = {}
	var order: Array = plan.get("order", [])
	for r in order.size():
		rank_of[int(order[r])] = r

	# Staging slots are addressed by UNLOAD rank, so the first crate out takes
	# the nearest slot and the yard fills in the order the crew works.
	var staging_for := func(rank: int) -> Vector2:
		var row := floori(rank / 2.0)
		var col := rank % 2
		return Vector2(cx, cz) \
			+ fwd * (half_l + STAGING_OFFSET_M + row * STAGING_PITCH_M) \
			+ side * (col * 3.0 - 1.5)

	var by_slot: Dictionary = {}   # delivery slot -> prop id
	var slot := 0
	var spill := 0
	for unit in sc.get("units", []):
		var u := unit as Dictionary
		var model_id := str(u.get("model_id", ""))
		for _i in maxi(int(u.get("count", 1)), 1):
			var patch := {"packed": true, "delivery_id": cid, "delivery_slot": slot}
			var pos := Vector2.ZERO
			var crate_yaw := yaw_deg
			var rank := int(rank_of.get(slot, -1))
			if placed_by_item.has(slot) and cw > 0.0 and cl > 0.0:
				var pl: Dictionary = placed_by_item[slot]
				var p3: Vector3 = pl["pos"]
				var s3: Vector3 = pl["size"]
				# Solver frame: x = interior width, y = height, z = load length
				# with the DOOR at high z; origin is the interior floor at the
				# nose corner. Container local +Z is the door direction (world
				# `fwd`) and local +X is world `side`.
				var c3 := p3 + s3 * 0.5
				pos = Vector2(cx, cz) + fwd * (c3.z - cl * 0.5) + side * (c3.x - cw * 0.5)
				# y_offset is EXACT, no deck fudge: PackedFormBuilder puts a
				# crate's origin at its own floor and the container's floor is
				# local Y = 0.
				patch["y_offset"] = p3.y
				patch["stowed_in"] = cid
				patch["unload_rank"] = maxi(rank, 0)
				# Crates inside a closed box are neither walkable-into nor
				# clickable; the crew has to bring them out first.
				patch["collision_enabled"] = false
				# The solver may have turned the box a quarter turn — the only
				# other orientation a yaw-only renderer can express.
				if absf(s3.x - float((plan["items"] as Array)[slot].get("d_m", s3.x))) < 0.001 \
						and absf(s3.x - float((plan["items"] as Array)[slot].get("w_m", -1.0))) > 0.001:
					crate_yaw = yaw_deg + 90.0
			else:
				# Overflow (or no plan): the pre-v3 door stack, so a unit that
				# does not fit still arrives and is visibly outside the box.
				var row := floori(spill / 2.0)
				var col := spill % 2
				pos = Vector2(cx, cz) \
					+ fwd * (half_l + DOOR_STACK_OFFSET_M + row * DOOR_STACK_PITCH_M) \
					+ side * (col * 2.0 - 1.0)
				spill += 1
			var stage: Vector2 = staging_for.call(rank if rank >= 0 else slot)
			patch["staging"] = {"x": stage.x, "z": stage.y}
			var pid := layer.add_free_prop(model_id, pos.x, 0.0, pos.y, crate_yaw)
			if pid.is_empty():
				continue
			if bool(u.get("linkage_default", false)):
				patch["linkage_spec"] = LinkageParams.new().to_config()
			layer.update_prop(pid, patch)
			by_slot[slot] = pid
			slot += 1

	# Emit in UNLOAD order so every consumer inherits LIFO for free.
	var crate_ids: Array = []
	for oi in order:
		if by_slot.has(int(oi)):
			crate_ids.append(by_slot[int(oi)])
	for s in by_slot:
		if not crate_ids.has(by_slot[s]):
			crate_ids.append(by_slot[s])
	layer.update_prop(cid, {
		"container_spec": {"container_id": container_id},
		"delivery": {"scenario_id": scenario_id,
			"crate_ids": crate_ids.duplicate(), "delivered_h": abs_h},
	})
	return {"scenario_id": scenario_id, "container_prop_id": cid,
		"crate_ids": crate_ids}


## The persisted delivery blob for a container prop, or {} — the reload-safe
## way back to a delivery's crates (spawn()'s return value used to be dropped
## on the floor, which made progress() dead code).
static func delivery_record(layer: PlacedPropLayer, container_prop_id: String) -> Dictionary:
	if layer == null:
		return {}
	return (layer.find_by_id(container_prop_id).get("delivery", {}) as Dictionary)


## Deployment progress over the spawned crate ids: a crate whose record has
## been unpacked (or repacked!) counts live, a deleted record counts done.
static func progress(layer: PlacedPropLayer, crate_ids: Array) -> Dictionary:
	var total := crate_ids.size()
	var still_packed := 0
	var missing := 0
	for pid in crate_ids:
		var rec := layer.find_by_id(str(pid)) if layer != null else {}
		if rec.is_empty():
			missing += 1
		elif bool(rec.get("packed", false)):
			still_packed += 1
	return {"total": total, "packed": still_packed, "missing": missing,
		"unpacked": total - still_packed - missing,
		"done": total > 0 and still_packed == 0}


## "How long with N people?" — NpcHaulModel over the unload route. The
## strategy (round trips vs bucket brigade) EMERGES from crew size and
## route length; the scenario just states the goal.
static func crew_estimate(scenario_id: String, route_m: float,
		workers: int) -> Dictionary:
	var sc := find(scenario_id)
	if sc.is_empty():
		return {}
	var units := 0
	for u in sc.get("units", []):
		units += maxi(int((u as Dictionary).get("count", 1)), 1)
	return NpcHaulModel.best_plan(workers, route_m, units)
