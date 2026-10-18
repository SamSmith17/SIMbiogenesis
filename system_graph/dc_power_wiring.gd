class_name DcPowerWiring
extends RefCounted

## Pure graph-walking helpers for the DC-electricity power path: tracing a DC
## generator's +/- ports through controllers and DC-bus tanks to the battery/
## smartbattery they ultimately charge, and summing live generation that's
## actually wired into a battery. Stateless — takes a GraphModel and returns
## values, no node/scene dependencies, so it's unit-testable in isolation
## (see power_system/sources/resource_flow_selftest.gd).

const MAX_HOPS := 8


## Trace from a DC port (polarity positive/negative) to the battery/
## smartbattery item it ultimately powers, hopping transparently through:
##  - a "controller" entered on pvPositive/pvNegative (continues from the
##    matching batteryPositive/batteryNegative handle, mirroring how a real
##    charge controller passes PV power through to the battery side)
##  - a "resource" item whose specs.resource_kind == "dc_electricity" (a DC
##    bus/combiner tank — continues from its other port, positive<->negative)
## Root scope only (matches how battery SOC sync/aggregation is already
## scoped in system_graph_view.gd). Returns the battery item id, or "" if
## unwired or dead-ended.
static func find_battery_for_dc_port(model: GraphModel, item_id: String,
		handle_id: String, visited: Dictionary = {}, hops: int = 0,
		flat_conns: Array = []) -> String:
	if model == null or hops > MAX_HOPS:
		return ""
	var key := item_id + "|" + handle_id
	if visited.has(key):
		return ""
	visited[key] = true
	# Trace over the FLATTENED graph so a battery/controller wired across a
	# super-node (compound) boundary at any depth is still reached.
	if flat_conns.is_empty():
		flat_conns = GraphNesting.flat_connections(model)
	for conn: Dictionary in flat_conns:
		var other_id := ""
		var other_handle := ""
		if str(conn.get("source_item_id", "")) == item_id and str(conn.get("source_handle_id", "")) == handle_id:
			other_id = str(conn.get("target_item_id", ""))
			other_handle = str(conn.get("target_handle_id", ""))
		elif str(conn.get("target_item_id", "")) == item_id and str(conn.get("target_handle_id", "")) == handle_id:
			other_id = str(conn.get("source_item_id", ""))
			other_handle = str(conn.get("source_handle_id", ""))
		else:
			continue
		var other := model.get_item(other_id)
		if other.is_empty():
			continue
		var ot := str(other.get("type", ""))
		if ot in ["battery", "smartbattery"]:
			return other_id
		if ot == "controller" and other_handle in ["pvPositive", "pvNegative"]:
			var next_handle := "batteryPositive" if other_handle == "pvPositive" else "batteryNegative"
			var found := find_battery_for_dc_port(model, other_id, next_handle, visited, hops + 1, flat_conns)
			if not found.is_empty():
				return found
			continue
		# A generator landing on a controller's BATTERY terminal is on the bank
		# bus itself (a hydro turbine's own regulator/dump load wired straight to
		# the battery side, as a PowerSpout is). That terminal is one node: follow
		# every other wire on it. Without this the trace dead-ended and a turbine
		# wired that way never charged anything.
		if ot == "controller" and other_handle in ["batteryPositive", "batteryNegative"]:
			var found_bus := find_battery_for_dc_port(model, other_id, other_handle, visited, hops + 1, flat_conns)
			if not found_bus.is_empty():
				return found_bus
			continue
		if ot == "resource":
			var ospecs: Dictionary = other.get("specs", {}) as Dictionary
			if str(ospecs.get("resource_kind", "")) == "dc_electricity" and other_handle in ["positive", "negative"]:
				var other_port := "negative" if other_handle == "positive" else "positive"
				var found2 := find_battery_for_dc_port(model, other_id, other_port, visited, hops + 1, flat_conns)
				if not found2.is_empty():
					return found2
	return ""


## Sums live DC generation (kW) from every root-scope, non-virtual item that
## both produces dc_electricity and is actually wired (directly, through a
## controller, or through a dc_electricity bus tank) into a battery/
## smartbattery. Graph-only wind/hydro items (no scene_device_path) are
## included the same way; scene/HA-mirrored ones are skipped outright since
## their output is already counted by SolarUI._poll_aux_generation()'s
## real energy_sources group — this is the double-count guard.
## Runs at 4 Hz with the graph closed: the flattened wires come from the
## revision-keyed memo (read-only here).
static func sum_graph_dc_generation_kw(model: GraphModel) -> float:
	if model == null:
		return 0.0
	var total := 0.0
	var flat_conns := GraphNesting.flat_connections_cached(model)
	# Nesting-aware: count DC generators anywhere in the tree (including inside
	# collapsed super-nodes), wired to a battery across any boundary.
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		var itype := str(item.get("type", ""))
		var iid := str(item.get("id", ""))
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var kw := float(specs.get("current_output_kw", 0.0))
		if kw <= 0.0:
			continue
		if itype == "processor":
			var outputs: Array = specs.get("outputs", []) as Array
			for i: int in outputs.size():
				if str((outputs[i] as Dictionary).get("kind", "")) != "dc_electricity":
					continue
				if not find_battery_for_dc_port(model, iid, "res_out_%d_pos" % i, {}, 0, flat_conns).is_empty():
					total += kw
				break
		elif itype == "wind" or itype == "hydro":
			var scene_path := str(specs.get("scene_device_path", item.get("device_path", "")))
			if not scene_path.is_empty():
				continue  # already counted via SolarUI's real energy_sources group
			if not find_battery_for_dc_port(model, iid, "positive", {}, 0, flat_conns).is_empty():
				total += kw
	return total
