extends RefCounted

## Closed Loop Ten: every dome-over-a-bed pair becomes ONE greenhouse (the
## user's call, 2026-11-13). Each pair was two unrelated props — a DomeLab dome
## tagged `greenhouse_beds` = the bed prop, and the keyhole bed bound to its
## graph plant node — so moving a dome left its beds behind and the dome had no
## node. For each pair this:
##  - notes the plant node's wires (water in, food out, residue out), its
##    planting hour, its canvas spot and the bed prop's planting hour;
##  - deletes the dome and the bed (the bed's plant node goes with it);
##  - places a 20 m geodesic greenhouse (GreenhousePresets "dome_20m") at the
##    dome's pose: the same keyhole beds and garden crops, 24 water barrels, the
##    roof's gutters into a 2 m³ cistern — its beds and the barrels inside it,
##    ONE graph node with them inside;
##  - cooling as the design assumed ("the dome keeps the summer heat off with
##    shade cloth and its vents"): ridge + end vents, 40 % shade cloth May to
##    September, and NO exhaust fans — 2 × 560 W in each of twelve domes would
##    be ~13 kW the site's 15 kWp array cannot carry;
##  - wires the node to where the plant's wires went (water_in and
##    nutrients_in from the same stores — the house is a fed one, beds.feed,
##    its beds drawing on a nutrient store inside it — food_out / biomass_out
##    to the same stores) and its AC in from the
##    site's inverter (vent motors);
##  - carries the planting hours over (no replanting), puts the node where the
##    plant's card was, and re-points every chore that targeted the dome or
##    the bed at the greenhouse.
## Idempotent: a world with no dome-over-bed pair left changes nothing.
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/fixes/closed_loop_greenhouses.gd           # dry run
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/fixes/closed_loop_greenhouses.gd -Persist  # keep it

const SHADE := 0.4
const SHADE_MONTHS := [5, 6, 7, 8, 9]
const CISTERN_L := 2000.0


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


static func spec_for(n: int, crops: Variant) -> Dictionary:
	var s: Dictionary = GreenhousePresets.builtin("dome_20m")["spec"].duplicate(true)
	s["name"] = "Greenhouse %d" % n
	s["fans"] = {"kind": "fan_36", "count": 0}
	s["shade"] = {"cloth": SHADE, "months": SHADE_MONTHS}
	s["rain"]["gutters"] = true
	s["rain"]["cistern_l"] = CISTERN_L
	s["beds"]["crops"] = GreenhouseSpec.clean_mix(crops)
	s["beds"]["feed"] = true
	return GreenhouseSpec.to_json_safe(s)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var sgv: Node = ServiceLocator.graph()
	var loader: Node = TerrainSurfaceQuery.find_terrain_loader(main)
	if sgv == null or loader == null:
		return {"ok": false, "why": "no graph view or terrain loader"}
	var model: GraphModel = sgv.get("model")
	var pairs: Array = []
	for r in (loader.call("placed_prop_records") as Array):
		var rec: Dictionary = r
		if str(rec.get("model_id", "")) == DomeLabBuilder.MODEL_ID and not str(rec.get("greenhouse_beds", "")).is_empty():
			pairs.append(rec.duplicate(true))
	var inv := ""
	for it in model.get_items_in_scope("root"):
		var sp: Dictionary = (it as Dictionary).get("specs", {})
		if str((it as Dictionary).get("type", "")) == "controller" and float(sp.get("overload_watts", 0.0)) > 0.0:
			inv = str((it as Dictionary)["id"])
			break
	var done: Array = []
	var notes: Array = []
	var n := 0
	for dome in pairs:
		n += 1
		var dpid := str(dome["id"])
		var bed_pid := str(dome["greenhouse_beds"])
		var bed := PlacedPropService.get_prop_record(main, bed_pid)
		var plant_id := str(dome.get("greenhouse_for", ""))
		var plant := model.get_item(plant_id)
		if plant.is_empty():
			plant_id = str(bed.get("graph_item_id", ""))
			plant = model.get_item(plant_id)
		var crops: Variant = "garden"
		var bed_planted := -1.0
		if bed.get("grow_bed_spec") is Dictionary:
			crops = (bed["grow_bed_spec"] as Dictionary).get("crops", "garden")
			bed_planted = float((bed["grow_bed_spec"] as Dictionary).get("plant_abs_h", -1.0))
		# The plant node's wires, by its port.
		var wires := {}
		var planted := -1.0
		var card := Vector2.INF
		if not plant.is_empty():
			planted = float((plant.get("specs", {}) as Dictionary).get("planted_abs_h", -1.0))
			card = Vector2(float(plant.get("x", 0.0)), float(plant.get("y", 0.0)))
			for c in model.connections:
				var cd: Dictionary = c
				if str(cd.get("target_item_id", "")) == plant_id:
					wires[str(cd.get("target_handle_id", ""))] = {"other": str(cd["source_item_id"]),
						"oh": str(cd.get("source_handle_id", "")), "kind": str(cd.get("resource_type", ""))}
				elif str(cd.get("source_item_id", "")) == plant_id:
					wires[str(cd.get("source_handle_id", ""))] = {"other": str(cd["target_item_id"]),
						"oh": str(cd.get("target_handle_id", "")), "kind": str(cd.get("resource_type", ""))}
		var x := float(dome.get("x", 0.0))
		var z := float(dome.get("z", 0.0))
		var yaw := float(dome.get("yaw", 0.0))
		# Down with the pair (the plant node goes with its bed prop).
		loader.call("delete_prop_by_id", dpid, false)
		if not bed.is_empty():
			loader.call("delete_prop_by_id", bed_pid, false)
		if not plant.is_empty() and not model.get_item(plant_id).is_empty():
			model.remove_item(plant_id)
		await _frames(tree, 2)
		var pid := PlacedPropService.place_prepped_at(main, GreenhouseBuilder.MODEL_ID,
			{"record_extra": {GreenhouseSpec.KEY: spec_for(n, crops), "collision_enabled": true, "walk_in": true}},
			x, z, yaw)
		await _frames(tree, 10)
		if pid.is_empty():
			notes.append("could not place the greenhouse for dome %s" % dpid)
			continue
		var cid := str(sgv.call("greenhouse_system_item_id", pid))
		if cid.is_empty():
			cid = GreenhouseWorld.sync_graph(main, pid)
		if cid.is_empty():
			notes.append("no graph node for greenhouse %s" % pid)
			continue
		if card != Vector2.INF:
			model.update_item(cid, {"x": card.x, "y": card.y})
		# Its wires where the plant's went.
		var port_map := {"water_in": ["water_in", true], "nutrients_in": ["nutrients_in", true], "biomass_out": ["food_out", false],
			"residue_out": ["biomass_out", false]}
		for h in wires:
			var w: Dictionary = wires[h]
			if not port_map.has(h) or model.get_item(str(w["other"])).is_empty():
				notes.append("greenhouse %d: its %s wire is left off" % [n, h])
				continue
			var pm: Array = port_map[h]
			var c2 := {"scope_id": "root", "polarity": "resource", "resource_type": str(w["kind"]),
				"line_style": "bezier", "curve_tension": 1.0, "corner_radius": 28.0}
			if bool(pm[1]):
				c2.merge({"source_item_id": str(w["other"]), "source_handle_id": str(w["oh"]),
					"target_item_id": cid, "target_handle_id": str(pm[0])})
			else:
				c2.merge({"source_item_id": cid, "source_handle_id": str(pm[0]),
					"target_item_id": str(w["other"]), "target_handle_id": str(w["oh"])})
			model.add_connection(c2)
		if not inv.is_empty():
			model.add_connection({"scope_id": "root", "polarity": "ac", "source_item_id": inv, "source_handle_id": "acOutput",
				"target_item_id": cid, "target_handle_id": "ac_in", "line_style": "bezier", "curve_tension": 1.0, "corner_radius": 28.0})
		# No replanting: the beds keep their planting hour.
		var kids := GreenhouseGraph.children_by_role(model, cid)
		for c in kids.get("bed", []):
			var cd2: Dictionary = c
			var sp2: Dictionary = (cd2.get("specs", {}) as Dictionary).duplicate(true)
			if planted >= 0.0:
				sp2["planted_abs_h"] = planted
				model.update_item(str(cd2["id"]), {"specs": sp2})
			var bp := str(sp2.get("bound_prop_id", ""))
			if bed_planted >= 0.0 and not bp.is_empty():
				var br := PlacedPropService.get_prop_record(main, bp)
				if br.get("grow_bed_spec") is Dictionary:
					var gb: Dictionary = (br["grow_bed_spec"] as Dictionary).duplicate(true)
					gb["plant_abs_h"] = bed_planted
					PlacedPropService.update_prop_record(main, bp, {"grow_bed_spec": gb}, true)
		var moved := _retarget_chores(sgv, model, [dpid, bed_pid], pid)
		done.append("Greenhouse %d (%s) replaces dome %s + bed %s: %d wires, %d chores re-pointed" % [
			n, pid, dpid, bed_pid, wires.size(), moved])
	if not pairs.is_empty():
		loader.call("_save_props_and_share")
		if sgv.has_method("_schedule_graph_autosave"):
			sgv.call("_schedule_graph_autosave")
		await _frames(tree, 10)
	for l in done:
		print("closed_loop_greenhouses: %s" % str(l))
	for l in notes:
		print("closed_loop_greenhouses: note: %s" % str(l))
	return {"ok": true, "converted": done.size(), "done": done, "notes": notes}


## Every chore board's chores aimed at one of `old_ids` aim at `new_id`.
func _retarget_chores(sgv: Node, model: GraphModel, old_ids: Array, new_id: String) -> int:
	var bridge: Object = sgv.call("npc_population_bridge") if sgv.has_method("npc_population_bridge") else null
	if bridge == null:
		return 0
	var moved := 0
	for it in model.items:
		var board: Object = bridge.call("chore_board_for", str((it as Dictionary).get("id", "")))
		if board == null:
			continue
		for c in board.get("chores"):
			var t: Variant = (c as Dictionary).get("target", {})
			if t is Dictionary and old_ids.has(str((t as Dictionary).get("id", ""))):
				(t as Dictionary)["id"] = new_id
				moved += 1
	return moved
