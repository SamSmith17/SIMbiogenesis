extends RefCounted

## Build a whole-system design INTO a world: the graph, its 3D twins as packed
## kits, the people's vehicles, a gate, a cargo container, the spaces people
## use, the day's chores and an arrive -> deploy schedule, so the player can
## watch the crew drive in, unload, build the site and then run it.
##
##   $env:SYSDESIGN = "bombay_ten"      # core/simkit/designs/<name>.json
##   tools\harness.ps1 -World <new world id> -RunScript res://tools/fixes/closed_loop_world.gd            # dry run
##   tools\harness.ps1 -World <new world id> -RunScript res://tools/fixes/closed_loop_world.gd -Persist   # keep it
##
## Meant for a world made for it (tools/sysdesign/create_world.gd): it clears
## the graph and removes every prop an earlier run of it placed. Positions in
## the design's "world" block are metres east / south of the site marker.

const Site := preload("res://core/simkit/simkit_site.gd")
const TAG := "sysdesign"

var main: Node
var sgv: Node
var loader: Node
var model: GraphModel
var centre := Vector2.ZERO
var ids := {}
var notes: Array = []
var kits: Array = []          # [{pid, x, z, yaw, stow}]


func run(p_main: Node, _harness: Node) -> Dictionary:
	main = p_main
	for i in 30:
		await main.get_tree().process_frame
	var design_name := OS.get_environment("SYSDESIGN")
	if design_name.is_empty():
		design_name = "bombay_ten"
	var design := Site.load_design(design_name)
	var world: Dictionary = design.get("world", {})
	sgv = ServiceLocator.graph()
	loader = main.find_child("TerrainLoader", true, false)
	if design.is_empty() or world.is_empty() or sgv == null or loader == null:
		print("closed_loop_world: design, graph view or terrain loader missing")
		return {"ok": false}
	model = sgv.get("model")
	# In memory only: the build must not run on the player's testing switches.
	PopTestPrefs.reset_defaults()
	NpcDisplayPrefs.force_npcs_for_session(true)
	main.set("time_scale", 0.0)
	centre = SiteCentre.xz(main)

	_remove_earlier_build()
	var sd: Object = sgv.call("site_deploy")
	sd.call("clear")
	await _frames(5)

	# 1. The graph (the same build the year run assessed) and the date.
	var start: Dictionary = (design.get("start", {}) as Dictionary).duplicate()
	start["hour"] = float(world.get("start_hour", 8.0))
	design["start"] = start
	var built := Site.apply(main, sgv, design)
	if not bool(built.get("ok", false)):
		for e in (built.get("errors", []) as Array):
			print("closed_loop_world: build error: ", e)
		return {"ok": false}
	ids = built["ids"]
	var t0 := float(built["start_abs"])
	await Site.ensure_weather(main, t0)
	sgv.get("_resource_flow").call("clear_timelines")
	print("closed_loop_world: graph built, %d items, %d wires" % [model.items.size(), model.connections.size()])

	# 2. The gate, the vehicles people arrive and live in, the container.
	var gate: Dictionary = world.get("gate", {})
	var g := _at(gate.get("at", [0, 110]))
	loader.call("set_site_gate_here", g.x, g.y, float(gate.get("yaw", 0.0)))
	var vehicle_ids: Array = []
	for v: Dictionary in (world.get("vehicles", []) as Array):
		var p := _at(v.get("at", [0, 0]))
		var vid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID, {"record_extra": {
			"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin(str(v.get("preset", "van")))),
			"collision_enabled": true, TAG: true}}, p.x, p.y, float(v.get("yaw", 0.0)))
		if vid.is_empty():
			notes.append("vehicle %s was not placed" % str(v.get("preset", "")))
		else:
			vehicle_ids.append(vid)
		await _frames(3)
	var container_id := ""
	if world.has("container"):
		var c: Dictionary = world["container"]
		var cp := _at(c.get("at", [0, 0]))
		var cr := PlacedPropService.place_model_at_xz(main, "cargo_container", cp.x, cp.y,
			{"yaw": float(c.get("yaw", 0.0)), TAG: true})
		container_id = str(cr.get("prop_id", ""))
	await _frames(5)

	# 3. A 3D twin for every node the design places.
	for tw: Dictionary in (world.get("twins", []) as Array):
		await _place_twins(tw)
	for pv: Dictionary in (world.get("pv", []) as Array):
		await _place_pv(pv)
	for pr: Dictionary in (world.get("props", []) as Array):
		await _place_prop(pr)
	await _frames(10)

	# 4. The spaces people use that are not a vehicle's or a prop's.
	var bridge: Object = sgv.call("npc_population_bridge")
	for i in 240:
		if bridge != null:
			break
		await main.get_tree().process_frame
		bridge = sgv.call("npc_population_bridge")
	var skip: Array = world.get("skip_area_spaces", [])
	var area_design := {"spaces": []}
	for s: Dictionary in (design.get("spaces", []) as Array):
		if not (str(s.get("type", "")) in skip):
			(area_design["spaces"] as Array).append(s)
	var n_spaces := Site.tag_spaces(main, bridge, area_design, ids) if bridge != null else 0
	loader.call("save_npc_spaces")

	# 5. Everything the crew builds starts as a kit: packed where it will
	# stand, or stowed in the container with its home remembered.
	var stowed := 0
	for k: Dictionary in kits:
		var pid := str(k["pid"])
		loader.call("set_prop_packed", pid, true)
		PlacedPropService.update_prop_record(main, pid, {"deploy_home": {
			"x": float(k["x"]), "z": float(k["z"]), "yaw": float(k["yaw"]), "y_offset": 0.0}}, false)
		if bool(k.get("stow", false)) and not container_id.is_empty():
			if bool(loader.call("stow_prop_in", pid, container_id)):
				stowed += 1
			else:
				notes.append("%s did not fit the container: it waits at its place" % pid)
	await _frames(10)
	print("closed_loop_world: %d kits (%d in the container), %d vehicles, %d area spaces" % [
		kits.size(), stowed, vehicle_ids.size(), n_spaces])

	# 6. The schedule: everybody drives in, then the crew deploys the site.
	var arrive_h := t0 + 0.1
	sd.call("add_event", SiteDeploySchedule.ACTION_ARRIVE, arrive_h)
	await _frames(5)
	var last_park := arrive_h
	for vid2 in vehicle_ids:
		var rec := PlacedPropService.get_prop_record(main, str(vid2))
		if rec.get("arrival") is Dictionary:
			last_park = maxf(last_park, float(VehicleDrive.park_h(rec["arrival"])))
	var deploy_h := last_park + 0.25
	sd.call("add_event", SiteDeploySchedule.ACTION_DEPLOY, deploy_h)
	print("closed_loop_world: arrive at +%.2f h, last vehicle parks at +%.2f h, deploy at +%.2f h" % [
		arrive_h - t0, last_park - t0, deploy_h - t0])

	# 7. The standing chores (the machines mint their own).
	var hab_id := str((ids.get("hab", [""]) as Array)[0])
	var n_chores := 0
	if bridge != null:
		bridge.call("tick_at", model, sgv.get("_resource_flow"), main, t0)
		var board: Object = bridge.call("chore_board_for", hab_id)
		if board != null:
			for row in standing_chores(world):
				var r: Array = row
				if not str(board.call("add_chore", str(r[0]), float(r[1]), r[2])).is_empty():
					n_chores += 1
		else:
			notes.append("no chore board yet: the standing chores were not added")

	# 8. Labour is the crew's (the ledger is only the meter), saved with the world.
	var ledger: Object = loader.call("get_chore_ledger")
	ledger.set("infinite_labor", false)
	ledger.set("chore_hours_available", 0.0)
	loader.call("save_chore_ledger")

	# 9. Where the player stands and how fast the clock runs when they load it.
	main.call("set_absolute_hours", t0)
	var pl: Dictionary = world.get("player", {})
	var player: Node3D = main.get_node_or_null("Player")
	if player != null and not pl.is_empty():
		var pp := _at(pl.get("at", [0, 60]))
		player.global_position = Vector3(pp.x, TerrainSurfaceQuery.ground_height_at(main, pp.x, pp.y) + 0.2, pp.y)
		var la := _at(pl.get("look_at", [0, 0]))
		player.rotation.y = atan2(-(la.x - pp.x), -(la.y - pp.y))
	# The live AutomationEngine learns the graph's rules (a load of a saved
	# world does the same).
	var insp: Variant = sgv.get("_inspector_panel")
	if insp != null and insp.has_method("sync_all_load_automations"):
		insp.call("sync_all_load_automations", model)
	sgv.set("_autosave_pending", true)
	sgv.call("_flush_graph_autosave")
	main.set("time_scale", float(world.get("time_scale", 1.0 / 60.0)))

	for n in notes:
		print("closed_loop_world: note: ", n)
	print("closed_loop_world: %d standing chores; start %s %02d:00" % [n_chores, str(design.get("name", "")), int(world.get("start_hour", 8.0))])
	return {"ok": true, "kits": kits.size(), "stowed": stowed, "vehicles": vehicle_ids.size(),
		"deploy_h": deploy_h, "t0": t0, "notes": notes}


func _frames(n: int) -> void:
	for i in n:
		await main.get_tree().process_frame


func _at(a: Variant) -> Vector2:
	var arr: Array = a
	return centre + Vector2(float(arr[0]), float(arr[1]))


func _remove_earlier_build() -> void:
	var gone := 0
	for r in (loader.call("placed_prop_records") as Array).duplicate():
		var rec: Dictionary = r
		if bool(rec.get(TAG, false)) or str(rec.get("model_id", "")) == SiteGateBuilder.MODEL_ID:
			if bool(loader.call("delete_prop_by_id", str(rec.get("id", "")))):
				gone += 1
	var reg: Object = loader.get("npc_spaces")
	if reg != null:
		for s in (reg.get("spaces") as Array).duplicate():
			reg.call("remove_space", str((s as Dictionary).get("id", "")))
	if gone > 0:
		print("closed_loop_world: removed %d props of an earlier build" % gone)


func _prop_of_item(iid: String) -> String:
	for r in (loader.call("placed_prop_records") as Array):
		if str((r as Dictionary).get("graph_item_id", "")) == iid:
			return str((r as Dictionary).get("id", ""))
	return ""


## One twin per expanded node id, laid out on a grid from `at` (or at the
## entry's `positions`, one [east, south] per id). Options:
##   bed         a grow_bed_spec patch (layout, area, crops) for the bed twin
##   with_dome   a DomeLabPresets id: a dome stands over each twin (the beds
##               inside it), placed as its own kit
##   walk_in     people walk into it (the nav grid leaves it open)
##   face_centre turn it so its local +Z (a keyhole's slot) faces the camp
## `only` limits it to those graph ids (an in-place update of a built world).
func _place_twins(tw: Dictionary, only: Array = []) -> void:
	var list: Array = ids.get(str(tw.get("node", "")), [])
	for i in list.size():
		var iid := str(list[i])
		if not only.is_empty() and not only.has(iid):
			continue
		var it := model.get_item(iid)
		if it.is_empty():
			continue
		var p := _at(twin_offset(tw, i))
		var yaw := float(tw.get("yaw", 0.0))
		if bool(tw.get("face_centre", false)):
			var to := centre - p
			yaw = rad_to_deg(atan2(to.x, to.y))
		var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		if tw.has("model"):
			specs["model_id"] = str(tw["model"])
		var preset := {"type": str(it.get("type", "processor")), "label": str(specs.get("name", iid)),
			"icon": "", "width": float(it.get("width", 150.0)), "height": float(it.get("height", 140.0)),
			"specs": specs}
		sgv.call("_on_lib_place_model_requested", preset, iid, Vector3(p.x, 0.0, p.y))
		await _frames(3)
		var pid := _prop_of_item(iid)
		if pid.is_empty():
			notes.append("no twin for %s" % iid)
			continue
		var patch := {"yaw": yaw, TAG: true}
		if tw.has("dome") and not tw.has("with_dome"):
			patch["domelab_spec"] = (DomeLabPresets.builtin(str(tw["dome"])).get("spec", {}) as Dictionary).duplicate(true)
		if tw.has("bed"):
			patch["grow_bed_spec"] = bed_spec_patch(PlacedPropService.get_prop_record(main, pid), tw["bed"])
		if bool(tw.get("walk_in", false)):
			patch["walk_in"] = true
		PlacedPropService.update_prop_record(main, pid, patch, true)
		if bool(tw.get("untag", false)):
			_untag(pid)
		kits.append({"pid": pid, "x": p.x, "z": p.y, "yaw": yaw, "stow": bool(tw.get("stow", false))})
		if tw.has("with_dome"):
			await _place_dome_over(pid, iid, str(tw["with_dome"]), p, yaw)
	await _frames(3)


## Where twin `i` of an entry stands, metres east / south of the marker.
static func twin_offset(tw: Dictionary, i: int) -> Array:
	var positions: Array = tw.get("positions", [])
	if i < positions.size():
		return positions[i]
	var step: Array = tw.get("step", [6, 6])
	var cols := maxi(int(tw.get("cols", 1)), 1)
	var origin: Array = tw.get("at", [0, 0])
	return [float(origin[0]) + float(i % cols) * float(step[0]),
		float(origin[1]) + floorf(float(i) / float(cols)) * float(step[1])]


## The record's grow_bed_spec with the design's patch over it (its planting
## hour and seed kept).
static func bed_spec_patch(rec: Dictionary, bed: Variant) -> Dictionary:
	var out: Dictionary = (rec.get("grow_bed_spec", {}) as Dictionary).duplicate(true) \
			if rec.get("grow_bed_spec") is Dictionary else {}
	if bed is Dictionary:
		for k in (bed as Dictionary).keys():
			out[k] = (bed as Dictionary)[k]
	return out


## A greenhouse dome over a bed twin: its own kit, not bound to the graph
## (the beds are the node), the dome's sleeping space untagged (people work
## in it, they do not sleep in it), walk-in for the nav grid.
func _place_dome_over(bed_pid: String, iid: String, dome: String, p: Vector2, yaw: float) -> void:
	var spec: Dictionary = (DomeLabPresets.builtin(dome).get("spec", {}) as Dictionary).duplicate(true)
	var r := PlacedPropService.place_model_at_xz(main, DomeLabBuilder.MODEL_ID, p.x, p.y,
		{"yaw": yaw, TAG: true, "walk_in": true, "domelab_spec": spec, "greenhouse_for": iid,
			"greenhouse_beds": bed_pid})
	await _frames(3)
	if not bool(r.get("ok", false)):
		notes.append("no dome over %s" % iid)
		return
	var dpid := str(r["prop_id"])
	PlacedPropService.update_prop_record(main, dpid, {"domelab_spec": spec}, true)
	_untag(dpid)
	kits.append({"pid": dpid, "x": p.x, "z": p.y, "yaw": yaw, "stow": false})


## A ground rack bound to the design's array (its yaw is the array's azimuth).
func _place_pv(pv: Dictionary) -> void:
	var arr: Array = ids.get(str(pv.get("solar", "")), [])
	if arr.is_empty() or str(arr[0]).is_empty():
		notes.append("no array for %s" % str(pv.get("solar", "")))
		return
	var p := _at(pv.get("at", [0, 0]))
	var r := PlacedPropService.place_model_at_xz(main, PvArrayBuilder.MODEL_ID, p.x, p.y, {
		"yaw": float(pv.get("yaw", 0.0)), "graph_item_id": str(arr[0]), TAG: true,
		"pv_array_spec": {"count": int(pv.get("count", 18)), "cols": int(pv.get("cols", 9)),
			"rows": int(pv.get("rows", 2)), "tilt_deg": float(pv.get("tilt_deg", 30.0))}})
	await _frames(6)
	if bool(r.get("ok", false)):
		kits.append({"pid": str(r["prop_id"]), "x": p.x, "z": p.y, "yaw": float(pv.get("yaw", 0.0)), "stow": false})


## A plain prop; `bind` ties a model-less node to it, `space` tags it.
func _place_prop(pr: Dictionary) -> void:
	var p := _at(pr.get("at", [0, 0]))
	var r := PlacedPropService.place_model_at_xz(main, str(pr.get("model", "")), p.x, p.y,
		{"yaw": float(pr.get("yaw", 0.0)), TAG: true})
	await _frames(3)
	if not bool(r.get("ok", false)):
		notes.append("prop %s was not placed" % str(pr.get("model", "")))
		return
	var pid := str(r["prop_id"])
	var bound: Array = ids.get(str(pr.get("bind", "")), [])
	if not bound.is_empty():
		var iid := str(bound[0])
		var it := model.get_item(iid)
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp["bound_prop_id"] = pid
		var c := SiteCentre.xz(main)
		model.update_item(iid, {"specs": sp, "site_x_m": p.x - c.x, "site_z_m": p.y - c.y})
		PlacedPropService.update_prop_record(main, pid, {"graph_item_id": iid}, false)
	if pr.has("space"):
		var reg: Object = loader.get("npc_spaces")
		if reg != null:
			reg.call("set_space_type", {"kind": "prop", "prop_id": pid}, str(pr["space"]),
				int(pr.get("capacity", 0)), str(pr.get("label", "")))
	kits.append({"pid": pid, "x": p.x, "z": p.y, "yaw": float(pr.get("yaw", 0.0)), "stow": bool(pr.get("stow", false))})


func _untag(pid: String) -> void:
	var reg: Object = loader.get("npc_spaces")
	if reg == null:
		return
	var s: Dictionary = reg.call("space_for_target", {"kind": "prop", "prop_id": pid})
	if not s.is_empty():
		reg.call("remove_space", str(s.get("id", "")))


## The design's standing chores as [label, hours, opts] rows: a chore with
## `each` becomes one per expanded node id ("{n}" in its label is the
## module's number), its target that module's twin.
func standing_chores(world: Dictionary) -> Array:
	var out: Array = []
	for ch: Dictionary in (world.get("chores", []) as Array):
		var opts := {"repeat": str(ch.get("repeat", "daily")),
			"window": {"start_h": float(ch.get("start_h", 9.0)), "end_h": float(ch.get("end_h", 17.0))},
			"min_workers": int(ch.get("min_workers", 1)), "max_workers": int(ch.get("max_workers", 1)),
			"priority": 60}
		if ch.has("exposure"):
			opts["exposure"] = str(ch["exposure"])
		var label := str(ch.get("label", "Chore"))
		if bool(ch.get("each", false)) and not ch.has("at"):
			var list: Array = ids.get(str(ch.get("node", "")), [])
			for k in list.size():
				var o: Dictionary = opts.duplicate(true)
				var pid := _prop_of_item(str(list[k]))
				if not pid.is_empty():
					o["target"] = {"kind": "prop", "id": pid}
				out.append([label.replace("{n}", str(k + 1)), float(ch.get("hours", 0.5)), o])
			continue
		var target := _chore_target(ch)
		if not target.is_empty():
			opts["target"] = target
		out.append([label.replace("{n}", "1"), float(ch.get("hours", 0.5)), opts])
	return out


## Every label the design's chores can take (to find them on a board again).
static func chore_label_pattern(label: String) -> RegEx:
	var re := RegEx.new()
	var esc := label
	for c in ["\\", ".", "(", ")", "[", "]", "+", "*", "?", "^", "$", "|"]:
		esc = esc.replace(c, "\\" + c)
	re.compile("^" + esc.replace("{n}", "\\d+") + "$")
	return re


func _chore_target(ch: Dictionary) -> Dictionary:
	if ch.has("at"):
		var p := _at(ch["at"])
		return {"kind": "pos", "x": p.x, "z": p.y}
	var list: Array = ids.get(str(ch.get("node", "")), [])
	if list.is_empty():
		return {}
	var pid := _prop_of_item(str(list[0]))
	if pid.is_empty():
		return {}
	return {"kind": "prop", "id": pid}
