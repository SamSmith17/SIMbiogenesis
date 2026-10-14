extends RefCounted

## Mount Vernon hydro cleanup (approved by the user 2026-10-12). Removes four
## pieces of test residue that were corrupting the site's water/power math, and
## gives the pond a real way out:
##  - item_164 and item_168: empty 100 L "Potable Water Supply" tanks. item_168
##    was wired into the PowerSpout's inlet and carried a copy of the pond's
##    level, so the turbine ran against water that did not exist.
##  - item_166 + its 3D intake prop: an unconnected first stream intake.
##  - conn_106: a wire looping the pond tank into itself.
##  - NEW: a "Pond Outlet Pipes" outlet sink at the user's Google Earth pin of
##    that name, set as the pond's spillway (`spill_outlet_id`), so water above
##    the max fill level leaves through it instead of vanishing.
## Every step is guarded on what the item actually is, so a re-run (or a world
## where an id was reused) changes nothing it should not. Idempotent.

const POND_ID := "item_69"
const OUTLET_NAME := "Pond Outlet Pipes"


func _is_empty_supply_tank(it: Dictionary) -> bool:
	var s: Dictionary = it.get("specs", {}) as Dictionary
	return str(it.get("type", "")) == "resource" \
			and str(s.get("name", "")) == "Potable Water Supply" \
			and float(s.get("capacity_qty", 0.0)) <= 100.0 \
			and float(s.get("level", 0.0)) <= 0.001 \
			and not bool(s.get("pond_storage", false))


func run(main: Node, _harness: Node) -> Dictionary:
	await main.get_tree().process_frame
	var sgv: Node = ServiceLocator.graph()
	var loader: Node = main.find_child("TerrainLoader", true, false)
	if sgv == null or loader == null:
		return {"ok": false, "why": "no graph view or terrain loader"}
	var model: Object = sgv.get("model")
	var done: Array = []

	# 1. The two empty supply tanks.
	for iid in ["item_164", "item_168"]:
		var it: Dictionary = model.call("get_item", iid)
		if not it.is_empty() and _is_empty_supply_tank(it):
			model.call("remove_item", iid)
			done.append("removed %s (empty Potable Water Supply)" % iid)

	# 2. The orphan stream intake + its prop (only if nothing is wired to it).
	var intake: Dictionary = model.call("get_item", "item_166")
	if not intake.is_empty() and ResourceFlowEngine.is_stream_intake(intake):
		var wired := false
		for c: Dictionary in model.get("connections"):
			if str(c.get("source_item_id", "")) == "item_166" or str(c.get("target_item_id", "")) == "item_166":
				wired = true
				break
		if not wired:
			var pid := str((intake.get("specs", {}) as Dictionary).get("bound_prop_id", ""))
			model.call("remove_item", "item_166")
			if not pid.is_empty() and loader.has_method("delete_prop_by_id"):
				loader.call("delete_prop_by_id", pid)
			done.append("removed orphan intake item_166 + prop %s" % pid)

	# 3. The pond self-loop.
	for c: Dictionary in (model.get("connections") as Array).duplicate():
		if str(c.get("id", "")) == "conn_106" \
				and str(c.get("source_item_id", "")) == str(c.get("target_item_id", "")):
			model.call("remove_connection", "conn_106")
			done.append("removed self-loop conn_106")

	# 4. The pond's spillway outlet at the user's "Pond Outlet Pipes" pin.
	var pond: Dictionary = model.call("get_item", POND_ID)
	if not pond.is_empty() and bool((pond.get("specs", {}) as Dictionary).get("pond_storage", false)):
		var ps: Dictionary = (pond.get("specs", {}) as Dictionary).duplicate(true)
		var outlet_id := str(ps.get("spill_outlet_id", ""))
		if outlet_id.is_empty() or (model.call("get_item", outlet_id) as Dictionary).is_empty():
			var pos := Vector3.INF
			for rec: Dictionary in (loader.call("poi_records") as Array):
				if str(rec.get("name", "")) == OUTLET_NAME:
					pos = loader.call("poi_world_position", str(rec.get("id", "")))
					break
			var center := Vector3.ZERO
			var soi: Node = main.get_tree().root.get_node_or_null("SoiService")
			if soi != null and soi.has_method("world_center"):
				center = soi.call("world_center")
			outlet_id = "pond_spill_outlet"
			var item := {
				"id": outlet_id, "type": "resource",
				"x": float(pond.get("x", 0.0)) - 160.0, "y": float(pond.get("y", 0.0)) + 160.0,
				"width": 72.0, "height": 72.0,
				"specs": {
					"name": OUTLET_NAME, "resource_kind": "water",
					"capacity_qty": 1.0e12, "capacity_unit": "L", "capacity": "∞",
					"level": 0.0, "unlimited_capacity": true, "outlet_sink": true,
					"cumulative_l": 0.0, "live_in_lps": 0.0, "stock_l": 0.0,
					"daily_note": "Pond spillway: water above the pond's max fill level leaves here.",
				},
			}
			if pos != Vector3.INF:
				var site := GraphSiteLayout.world_xz_to_site(Vector2(pos.x, pos.z), center)
				item["site_x_m"] = site.x
				item["site_z_m"] = site.y
				item["elevation_m"] = pos.y
			model.call("add_item", item)
			model.call("add_connection", {
				"polarity": "resource", "resource_type": "water",
				"source_item_id": POND_ID, "source_handle_id": "output",
				"target_item_id": outlet_id, "target_handle_id": "input",
			})
			ps["spill_outlet_id"] = outlet_id
			model.call("update_item", POND_ID, {"specs": ps})
			done.append("added spillway outlet %s%s" % [outlet_id,
					"" if pos != Vector3.INF else " (pin not found — placed without site coords)"])

	# 5. Bindings + names (the same reconcile the load path now runs).
	if sgv.has_method("reconcile_world_bindings"):
		var n := int(sgv.call("reconcile_world_bindings"))
		if n > 0:
			done.append("reconciled %d graph↔3D binding(s)" % n)
	if sgv.has_method("_flush_graph_autosave"):
		sgv.set("_autosave_pending", true)
		sgv.call("_flush_graph_autosave")
	for line in done:
		print("mtvernon_hydro_cleanup: ", line)
	return {"ok": true, "changed": done.size(), "done": done}
