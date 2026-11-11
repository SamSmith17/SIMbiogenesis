extends RefCounted

## Bring a world built by closed_loop_world.gd up to date with its design
## WITHOUT rebuilding it: the clock, the people, the props, the tank levels
## and the node positions stay; the graph gains the nodes the design added,
## loses the ones it dropped, takes the design's settings and is rewired. The 3D twins follow the design's
## world block: a node that is new gets its twin (and a dome over it, for
## greenhouse beds) as a kit the crew builds; a twin whose bed or place the
## design changed is changed where it stands. The design's standing chores
## replace the ones on the board (one per module where it says "each").
##
##   $env:SYSDESIGN = "bombay_ten"
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/fixes/closed_loop_sync.gd            # dry run
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/fixes/closed_loop_sync.gd -Persist   # keep it
##
## On a node that was there before, `set` values are applied except a store's
## `level` (the world's own stock stays) and the run-start token "@start"
## (a greenhouse already standing is taken as planted when the crew built it:
## the schedule's DEPLOY event). Wires between design nodes are rebuilt from
## the design; the solar arrays' wires and the vehicles' own systems are left.

const Site := preload("res://core/simkit/simkit_site.gd")
const Builder := preload("res://core/simkit/simkit_builder.gd")
const World := preload("res://tools/fixes/closed_loop_world.gd")
## Standing chores an earlier design put on the board that the design no
## longer has (found by label and removed).
const RETIRED_CHORES := ["Tend the greenhouse beds", "Weed and check the plots"]

var main: Node
var sgv: Node
var model: GraphModel


func run(p_main: Node, _harness: Node) -> Dictionary:
	main = p_main
	for i in 30:
		await main.get_tree().process_frame
	var design_name := OS.get_environment("SYSDESIGN")
	if design_name.is_empty():
		design_name = "bombay_ten"
	var design := Site.load_design(design_name)
	sgv = ServiceLocator.graph()
	if design.is_empty() or sgv == null:
		print("closed_loop_sync: design or graph view missing")
		return {"ok": false}
	model = sgv.get("model")
	var now := float(main.call("get_absolute_hours"))
	var planted := _deploy_hour(now)
	var notes: Array = []

	# Which design ids the world has.
	var present := {}
	for it: Dictionary in model.items:
		var sid := str((it.get("specs", {}) as Dictionary).get("sysdesign_id", ""))
		if not sid.is_empty():
			present[str(it.get("id", ""))] = sid
	var wanted := {}
	for n: Dictionary in (design.get("nodes", []) as Array):
		for iid in Builder.ids_of(design, str(n["id"])):
			wanted[str(iid)] = n

	# 1. Drop what the design no longer has (and any prop bound to it).
	var removed: Array = []
	for iid in present.keys():
		if wanted.has(iid):
			continue
		var it2 := model.get_item(str(iid))
		var pid := str((it2.get("specs", {}) as Dictionary).get("bound_prop_id", ""))
		model.remove_item(str(iid))
		removed.append(str(iid))
		if not pid.is_empty():
			var loader: Node = main.find_child("TerrainLoader", true, false)
			if loader != null:
				loader.call("delete_prop_by_id", pid)
	# 2. Wires between design nodes go; the design's are drawn again below.
	var drop: Array = []
	for c: Dictionary in model.connections:
		var a := str(c.get("source_item_id", ""))
		var b := str(c.get("target_item_id", ""))
		if (wanted.has(a) or a == "pbi_rain") and wanted.has(b):
			drop.append(str(c.get("id", "")))
	for cid in drop:
		model.remove_connection(str(cid))

	# 3. New nodes: a nodes-only build, each set beside a node it is wired to.
	var new_nodes: Array = []
	for n2: Dictionary in (design.get("nodes", []) as Array):
		var ids2: Array = Builder.ids_of(design, str(n2["id"]))
		var missing := false
		for iid2 in ids2:
			if model.get_item(str(iid2)).is_empty():
				missing = true
		if missing:
			var nn: Dictionary = n2.duplicate(true)
			# A new bed is planted when the crew builds it, not at the old deploy.
			var st: Dictionary = nn.get("set", {})
			for sk in st.keys():
				if str(st[sk]) == "@start":
					st.erase(sk)
			new_nodes.append(nn)
	var start_token := planted
	if not new_nodes.is_empty():
		var mini := {"nodes": new_nodes, "_nodes_only": true, "_start_abs": start_token}
		var built := Builder.build(model, mini, sgv)
		for e in (built.get("errors", []) as Array):
			notes.append("build: %s" % str(e))
		for n3: Dictionary in new_nodes:
			for iid3 in Builder.ids_of(design, str(n3["id"])):
				_place_near(str(iid3), design)

	# 4. Nodes that were there: the design's settings (not a store's stock),
	# a changed preset's ports, a recipe, the rates of an unchanged preset.
	var updated := 0
	for iid4 in wanted.keys():
		if new_nodes.any(func(x: Dictionary) -> bool: return Builder.ids_of(design, str(x["id"])).has(iid4)):
			continue
		var n4: Dictionary = wanted[iid4]
		var it4 := model.get_item(str(iid4))
		if it4.is_empty():
			continue
		var sp: Dictionary = (it4.get("specs", {}) as Dictionary).duplicate(true)
		var preset := Builder.find_preset(str(n4.get("preset", "")))
		var ps: Dictionary = preset.get("specs", {})
		var has_recipe := n4.has("recipe_def") or n4.has("recipe_file") or n4.has("recipe")
		if not has_recipe and str(it4.get("type", "")) == "processor":
			if ps.has("inputs"):
				sp["inputs"] = (ps["inputs"] as Array).duplicate(true)
			if ps.has("outputs"):
				sp["outputs"] = (ps["outputs"] as Array).duplicate(true)
			for k in ["sanitation", "establish_days", "daily_note", "io_absolute", "energy_wh_per_unit"]:
				if ps.has(k):
					sp[k] = ps[k]
		for k2 in (n4.get("set", {}) as Dictionary).keys():
			var v: Variant = (n4["set"] as Dictionary)[k2]
			# A store keeps its stock — unless the design says what it holds
			# changed meaning (the nutrient store's kg became kg of N+P+K).
			var keep_stock := str(k2) == "level" and str(it4.get("type", "")) == "resource" \
					and not bool(n4.get("sync_reset_level", false))
			if keep_stock:
				continue
			if v is String and str(v) == "@start":
				if sp.has(str(k2)):
					continue
				v = planted
			sp[str(k2)] = v
		if n4.has("automations"):
			var list: Array = (n4["automations"] as Array).duplicate(true)
			for i in list.size():
				var a2: Dictionary = list[i]
				a2["id"] = "sysd_%s_%d" % [iid4, i]
				if not a2.has("conditions"):
					a2["conditions"] = []
			sp["graph_automations"] = list
		if n4.has("recipe_file"):
			var rp := "res://core/simkit/recipes/%s.json" % str(n4["recipe_file"])
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(rp)) if FileAccess.file_exists(rp) else null
			if parsed is Dictionary:
				TcProcSummary.apply_to_specs(sp, parsed as Dictionary)
		elif n4.has("recipe_def"):
			ProcessRecipe.apply_to_specs(sp, (n4["recipe_def"] as Dictionary).duplicate(true))
		model.update_item(str(iid4), {"specs": sp})
		updated += 1

	# 5. The design's wires, DC and AC, by the builder's own rules.
	var ids := _design_ids(design)
	var errs := 0
	for w in (design.get("wires", []) as Array):
		var wa: Array = w
		for a3: String in ids.get(str(wa[0]), [str(wa[0])]):
			for b3: String in ids.get(str(wa[1]), [str(wa[1])]):
				var e2 := Builder.wire(model, a3, b3, str(wa[2]))
				if not e2.is_empty():
					errs += 1
					notes.append(e2)
	for d in (design.get("dc", []) as Array):
		for a4: String in ids.get(str((d as Array)[0]), []):
			for b4: String in ids.get(str((d as Array)[1]), []):
				Builder._dc(model, a4, b4)
	var assigned := {}
	var ac: Dictionary = design.get("ac", {})
	for ck in ac.keys():
		var ctl: Array = ids.get(str(ck), [])
		if ctl.is_empty():
			continue
		for nid in (ac[ck] as Array):
			for iid5: String in ids.get(str(nid), []):
				Builder._ac(model, str(ctl[0]), iid5)
				assigned[iid5] = true
	var first_ctl: Array = ids.get("ctl_a", [])
	for iid6 in wanted.keys():
		if assigned.has(iid6) or first_ctl.is_empty():
			continue
		if Builder._needs_ac(model.get_item(str(iid6))):
			Builder._ac(model, str(first_ctl[0]), str(iid6))
	model.changed.emit("sysdesign_sync")

	# 6. The 3D twins and the standing chores.
	var w3 := await _sync_world(design, ids, notes)

	# 7. Engine, automations, save.
	sgv.get("_resource_flow").call("clear_timelines")
	var insp: Variant = sgv.get("_inspector_panel")
	if insp != null and insp.has_method("sync_all_load_automations"):
		insp.call("sync_all_load_automations", model)
	if sgv.has_method("_sync_solar_ui_from_graph"):
		sgv.call("_sync_solar_ui_from_graph")
	sgv.set("_autosave_pending", true)
	sgv.call("_flush_graph_autosave")
	for _f in 10:
		await main.get_tree().process_frame

	print("closed_loop_sync: removed %s; added %d node(s); updated %d; %d wires now; %d wire error(s)" % [
		str(removed), new_nodes.size(), updated, model.connections.size(), errs])
	print("closed_loop_sync: greenhouses taken as planted at +%.1f h (the deploy)" % (planted - now))
	print("closed_loop_sync: 3D: %d twins placed (%d queued for the crew), %d changed in place; chores: %d removed, %d added" % [
		int(w3.get("placed", 0)), int(w3.get("queued", 0)), int(w3.get("changed", 0)),
		int(w3.get("chores_removed", 0)), int(w3.get("chores_added", 0))])
	for n5 in notes:
		print("closed_loop_sync: note: ", n5)
	var out := {"ok": errs == 0, "removed": removed, "added": new_nodes.size(), "updated": updated}
	out.merge(w3)
	return out


## Design id -> graph ids, for nodes and the solar arrays (found by tag).
func _design_ids(design: Dictionary) -> Dictionary:
	var ids := {}
	for n: Dictionary in (design.get("nodes", []) as Array):
		ids[str(n["id"])] = Builder.ids_of(design, str(n["id"]))
	for s: Dictionary in (design.get("solar", []) as Array):
		var tag := "sysd_pv_%s" % str(s.get("id", "pv"))
		for it: Dictionary in model.items:
			if str((it.get("specs", {}) as Dictionary).get("array_tag", "")) == tag:
				ids[str(s["id"])] = [str(it["id"])]
	return ids


## When the crew built the site: the schedule's DEPLOY event (else now).
func _deploy_hour(now: float) -> float:
	var sd: Object = sgv.call("site_deploy") if sgv.has_method("site_deploy") else null
	if sd == null:
		return now
	var ev: Dictionary = sd.call("event_of", SiteDeploySchedule.ACTION_DEPLOY)
	return float(ev.get("at_h", now)) if not ev.is_empty() else now


## Put a new node beside the first existing node it is wired to in the design.
func _place_near(iid: String, design: Dictionary) -> void:
	var it := model.get_item(iid)
	if it.is_empty():
		return
	var nid := str((it.get("specs", {}) as Dictionary).get("sysdesign_id", ""))
	var anchor := Vector2.INF
	for w in (design.get("wires", []) as Array):
		var wa: Array = w
		var other := ""
		if str(wa[0]) == nid:
			other = str(wa[1])
		elif str(wa[1]) == nid:
			other = str(wa[0])
		if other.is_empty():
			continue
		for oid in Builder.ids_of(design, other):
			var o := model.get_item(str(oid))
			if not o.is_empty() and not (str(oid) in [iid]):
				anchor = Vector2(float(o.get("x", 0.0)), float(o.get("y", 0.0)))
				break
		if anchor != Vector2.INF:
			break
	if anchor == Vector2.INF:
		return
	var others: Array = []
	for o2 in model.get_items_in_scope("root"):
		if str((o2 as Dictionary).get("id", "")) != iid:
			others.append(o2)
	var p := GraphLayout.nudge_spawn_position(anchor + Vector2(200.0, 60.0),
		Vector2(float(it.get("width", 140.0)), float(it.get("height", 130.0))), others)
	model.update_item(iid, {"x": p.x, "y": p.y})


## The design's world block on a built world: twins for new nodes (packed
## where they will stand, queued for the crew), changed beds and places for
## the ones there, and the standing chores.
func _sync_world(design: Dictionary, ids: Dictionary, notes: Array) -> Dictionary:
	var world: Dictionary = design.get("world", {})
	var loader: Node = main.find_child("TerrainLoader", true, false)
	if loader == null or world.is_empty():
		return {}
	var w := World.new()
	w.main = main
	w.sgv = sgv
	w.loader = loader
	w.model = model
	w.centre = SiteCentre.xz(main)
	w.ids = ids
	var changed := 0
	for tw: Dictionary in (world.get("twins", []) as Array):
		var list: Array = ids.get(str(tw.get("node", "")), [])
		var missing: Array = []
		for i in list.size():
			var iid := str(list[i])
			var pid := w._prop_of_item(iid)
			if pid.is_empty():
				missing.append(iid)
				continue
			var rec := PlacedPropService.get_prop_record(main, pid)
			var patch := {}
			if tw.has("bed"):
				var want_bed := World.bed_spec_patch(rec, tw["bed"])
				if JSON.stringify(want_bed) != JSON.stringify(rec.get("grow_bed_spec", {})):
					patch["grow_bed_spec"] = want_bed
			# Twins are kept where the player has them unless the design moved
			# them more than a few metres (the plots at their real size).
			var want := w._at(World.twin_offset(tw, i))
			var here := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
			if here.distance_to(want) > 3.0 and bool(tw.get("bed", {}) is Dictionary):
				patch["x"] = want.x
				patch["z"] = want.y
			if not patch.is_empty():
				PlacedPropService.update_prop_record(main, pid, patch, true)
				changed += 1
				await main.get_tree().process_frame
		if not missing.is_empty():
			await w._place_twins(tw, missing)
	# New twins go up where they stand. By default at once (a bed is planted
	# today and comes up over its establishment): building twelve 20 m domes
	# and their beds is ~950 person-hours, and with that on the board the camp
	# worked itself to walk-outs inside a week. CLS_CREW_BUILD=1 leaves them as
	# kits queued for the crew in work hours instead.
	var crew_build := OS.get_environment("CLS_CREW_BUILD") == "1"
	var sd: Object = sgv.call("site_deploy") if sgv.has_method("site_deploy") else null
	var queued := 0
	# kit prop id -> the chore that finishes building it (its project's last
	# task): a module's standing chores wait for it.
	var finish_chore := {}
	var bridge0: Object = sgv.call("npc_population_bridge")
	for k: Dictionary in w.kits:
		var pid2 := str(k["pid"])
		loader.call("set_prop_packed", pid2, true)
		PlacedPropService.update_prop_record(main, pid2, {"deploy_home": {
			"x": float(k["x"]), "z": float(k["z"]), "yaw": float(k["yaw"]), "y_offset": 0.0}}, false)
	await main.get_tree().process_frame
	if not crew_build:
		for k3: Dictionary in w.kits:
			# Unpacking stamps a bed's planting hour (set_item_packed_3d).
			loader.call("set_prop_packed", str(k3["pid"]), false)
		await main.get_tree().process_frame
	if sd != null and crew_build:
		for k2: Dictionary in w.kits:
			# Weeks of building, done in work hours: not ALL HANDS.
			var res: Dictionary = sd.call("queue_item", "prop", str(k2["pid"]), SiteDeploySchedule.ACTION_DEPLOY,
				{"all_hands": false})
			if bool(res.get("ok", false)):
				queued += 1
				var proj_id := str(res.get("project_id", ""))
				if not proj_id.is_empty() and bridge0 != null:
					for cr in (bridge0.call("crew_summary") as Array):
						var store: Object = bridge0.call("project_store_for", str((cr as Dictionary).get("iid", "")))
						var prec: Dictionary = store.call("find", proj_id) if store != null else {}
						var tasks: Array = prec.get("tasks", [])
						if not tasks.is_empty():
							finish_chore[str(k2["pid"])] = str((tasks[tasks.size() - 1] as Dictionary).get("chore_id", ""))
			else:
				notes.append("crew build of %s: %s" % [str(k2["pid"]), str(res.get("error", ""))])
	for n in w.notes:
		notes.append(str(n))
	# The standing chores: the design's replace the ones it had.
	var removed := 0
	var added := 0
	var bridge: Object = sgv.call("npc_population_bridge")
	var hab_id := str((ids.get("hab", [""]) as Array)[0])
	var board: Object = bridge.call("chore_board_for", hab_id) if bridge != null else null
	if board != null:
		var pats: Array = []
		for ch: Dictionary in (world.get("chores", []) as Array):
			pats.append(World.chore_label_pattern(str(ch.get("label", ""))))
		for c in (board.get("chores") as Array).duplicate():
			var cd: Dictionary = c
			if cd.has("effect") or cd.has("stage_effects") or not str(cd.get("chore_key", "")).is_empty():
				continue
			var lbl := str(cd.get("label", ""))
			var hit := RETIRED_CHORES.has(lbl)
			for re in pats:
				if (re as RegEx).search(lbl) != null:
					hit = true
			if hit and bool(board.call("remove_chore", str(cd.get("id", "")))):
				removed += 1
		# A dome's bed pid -> the dome over it.
		var dome_of := {}
		for rr in (loader.call("placed_prop_records") as Array):
			var gb := str((rr as Dictionary).get("greenhouse_beds", ""))
			if not gb.is_empty():
				dome_of[gb] = str((rr as Dictionary).get("id", ""))
		for row in w.standing_chores(world):
			var r: Array = row
			var o: Dictionary = r[2]
			var tid := str((o.get("target", {}) as Dictionary).get("id", ""))
			var deps: Array = []
			for kp in [tid, str(dome_of.get(tid, ""))]:
				if finish_chore.has(kp) and not str(finish_chore[kp]).is_empty():
					deps.append(str(finish_chore[kp]))
			if not deps.is_empty():
				o["depends_on"] = deps
			if not str(board.call("add_chore", str(r[0]), float(r[1]), o)).is_empty():
				added += 1
	else:
		notes.append("no chore board: the standing chores were not changed")
	return {"placed": w.kits.size(), "queued": queued, "changed": changed,
		"chores_removed": removed, "chores_added": added}
