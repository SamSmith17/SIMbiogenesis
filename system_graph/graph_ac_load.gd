class_name GraphAcLoad
extends RefCounted
## Computes total AC load (W) from the system graph: only load/processor nodes
## that are reachable from a controller AC output through AC/load wires, and
## that are currently ON.
##
## AC passthrough nodes (Shelly 4PM / Spiderbox / breaker panels):
##   controller acOutput → ac_in → switched circuit_N outlets.
## When a channel is OFF (or the panel main is open), loads wired to that
## circuit are unreachable and draw 0 W — they do not contribute to the bus.

const LOAD_TYPES: Array[String] = ["appliance", "acload", "processor"]
const PASS_THROUGH_TYPES: Array[String] = [
	"shelly4pm", "spiderbox", "breaker_panel", "acbreaker", "acoutlet", "controller",
]
## Types with per-circuit ON flags (c0_on…cN_on) on outgoing circuit_* handles.
const SWITCHED_CIRCUIT_TYPES: Array[String] = ["shelly4pm", "spiderbox", "breaker_panel"]


static func compute_watts(model: GraphModel, tree: SceneTree) -> float:
	if model == null or tree == null:
		return 0.0
	# Flatten super-node (compound) portals once: AC reachability then tunnels
	# through generic groups at any depth, while opaque load-group compounds stay
	# nodes (summed via sum_load_group_watts). Computed once, threaded down.
	var flat := GraphNesting.flat_connections(model)
	var reachable := _reachable_ac_load_ids(model, flat)
	if reachable.is_empty():
		return 0.0
	var sim_host := _find_sim_load_host(tree)
	var total := 0.0
	for iid: String in reachable.keys():
		var item: Dictionary = model.get_item(iid)
		if item.is_empty() or bool(item.get("is_ghost", false)):
			continue
		var ty := str(item.get("type", ""))
		if ty == "compound":
			var sp: Dictionary = item.get("specs", {}) as Dictionary
			if str(sp.get("compound_kind", "")) == "load_group":
				total += sum_load_group_watts(model, item, tree, sim_host)
				continue
		total += _item_draw_watts(iid, item, tree, sim_host, model)
	total += connection_losses_watts(model, tree, sim_host, flat)
	return maxf(0.0, total)


## What the wired AC loads WANT (W), independent of whether the inverter is
## serving them right now: every reachable load the player switched on
## (requested_state not "off"), at its rated/average draw. `compute_watts`
## reads 0 while low-SOC protection has shed the loads, which made a battery
## at its floor look like a site with no demand. Used by the site balance and
## its forward projection.
static func demand_watts(model: GraphModel) -> float:
	if model == null:
		return 0.0
	var flat := GraphNesting.flat_connections(model)
	var total := 0.0
	for iid: String in _reachable_ac_load_ids(model, flat).keys():
		var item: Dictionary = model.get_item(iid)
		if item.is_empty() or bool(item.get("is_ghost", false)):
			continue
		var sp: Dictionary = item.get("specs", {}) as Dictionary
		if str(sp.get("requested_state", "on")).to_lower() == "off":
			continue
		if bool(sp.get("packed_3d", false)):
			continue
		total += _rated_watts_from_specs(sp)
	return maxf(0.0, total)


## True when the opt-in connector loss simulation is on (Wave 8). Per-connection
## override "simulate_losses" (tri-state: missing = follow global) is honored
## by connection_losses_watts below.
static func losses_enabled(tree: SceneTree) -> bool:
	if tree == null or tree.root == null:
		return false
	var ctrl := tree.root.get_node_or_null("SimSettingsController")
	if ctrl == null:
		return false
	return bool(ctrl.get("connector_losses_enabled"))


## Wave 8: I^2R conduction loss summed over every conducting AC connection,
## added to the bus draw so long thin cords genuinely cost energy. Writes
## loss telemetry (loss_w / drop_pct / amps / overload_ratio) straight onto
## the connection dicts (no update_connection — avoids signal churn, same
## pattern as resource_flow_engine's flow_rate writeback).
static func connection_losses_watts(model: GraphModel, tree: SceneTree,
		sim_host: Node = null, flat_conns: Array = []) -> float:
	var global_on := losses_enabled(tree)
	if flat_conns.is_empty():
		flat_conns = GraphNesting.flat_connections(model)
	var total := 0.0
	# Loss + telemetry stays on the REAL wires the player sees; only the load-side
	# reachability BFS uses the flattened graph (via _connection_delivered_watts).
	for conn: Dictionary in model.connections:
		if not _is_ac_power_connection(conn):
			continue
		var enabled: bool = bool(conn.get("simulate_losses", global_on))
		var type_id: String = ConduitKinds.derive_type_for_connection(conn)
		if not ConduitKinds.is_electrical_type(type_id):
			continue
		if not enabled or bool(conn.get("severed", false)):
			conn["loss_w"] = 0.0
			conn["drop_pct"] = 0.0
			conn["carried_amps"] = 0.0
			conn["overload_ratio"] = 0.0
			continue
		var delivered: float = _connection_delivered_watts(model, conn, tree, sim_host, flat_conns)
		var meta: Dictionary = ConduitKinds.type_meta(type_id)
		var rep := ConduitLoss.electrical_report_for_connection(conn, meta, delivered)
		conn["loss_w"] = float(rep.get("loss_w", 0.0))
		conn["drop_pct"] = float(rep.get("drop_pct", 0.0))
		conn["carried_amps"] = float(rep.get("amps", 0.0))
		conn["overload_ratio"] = float(rep.get("overload_ratio", 0.0))
		total += float(rep.get("loss_w", 0.0))
	return total


## Watts delivered THROUGH a connection = summed draw of loads on the side of
## the cut edge that has no controller (the load side of a tree topology).
## Loops (controllers on both sides) conservatively use the smaller side.
static func _connection_delivered_watts(model: GraphModel, conn: Dictionary,
		tree: SceneTree, sim_host: Node, flat_conns: Array = []) -> float:
	if flat_conns.is_empty():
		flat_conns = GraphNesting.flat_connections(model)
	var cid := str(conn.get("id", ""))
	# Resolve endpoints through super-node portals so a boundary wire's load side
	# BFS starts at the real interior leaf, not the (edgeless-in-flat) compound.
	var src_res := GraphNesting.resolve_port(model, str(conn.get("source_item_id", "")),
			str(conn.get("source_handle_id", "")))
	var tgt_res := GraphNesting.resolve_port(model, str(conn.get("target_item_id", "")),
			str(conn.get("target_handle_id", "")))
	var side_a := _side_summary(model, str(src_res["item_id"]), cid, tree, sim_host, flat_conns)
	var side_b := _side_summary(model, str(tgt_res["item_id"]), cid, tree, sim_host, flat_conns)
	var a_has_ctrl: bool = bool(side_a.get("has_controller", false))
	var b_has_ctrl: bool = bool(side_b.get("has_controller", false))
	if a_has_ctrl and not b_has_ctrl:
		return float(side_b.get("watts", 0.0))
	if b_has_ctrl and not a_has_ctrl:
		return float(side_a.get("watts", 0.0))
	if not a_has_ctrl and not b_has_ctrl:
		return 0.0  # island with no source — nothing actually flows
	return minf(float(side_a.get("watts", 0.0)), float(side_b.get("watts", 0.0)))


## BFS from `start_id` across AC connections, never crossing `cut_conn_id`.
## Returns {watts, has_controller} for that side of the cut.
static func _side_summary(model: GraphModel, start_id: String, cut_conn_id: String,
		tree: SceneTree, sim_host: Node, flat_conns: Array = []) -> Dictionary:
	var watts := 0.0
	var has_controller := false
	if start_id.is_empty():
		return {"watts": 0.0, "has_controller": false}
	if flat_conns.is_empty():
		flat_conns = GraphNesting.flat_connections(model)
	var visited: Dictionary = {}
	var queue: Array[String] = [start_id]
	while not queue.is_empty():
		var nid: String = queue.pop_front()
		if visited.has(nid):
			continue
		visited[nid] = true
		var item: Dictionary = model.get_item(nid)
		if item.is_empty() or bool(item.get("is_ghost", false)):
			continue
		var ty := str(item.get("type", ""))
		if ty == "controller":
			has_controller = true
		if ty == "compound":
			var sp: Dictionary = item.get("specs", {}) as Dictionary
			if str(sp.get("compound_kind", "")) == "load_group":
				watts += sum_load_group_watts(model, item, tree, sim_host)
		elif ty in LOAD_TYPES:
			watts += _item_draw_watts(nid, item, tree, sim_host, model)
		for c: Dictionary in flat_conns:
			if str(c.get("id", "")) == cut_conn_id:
				continue
			if not _is_ac_power_connection(c):
				continue
			if bool(c.get("severed", false)):
				continue
			var sid := str(c.get("source_item_id", ""))
			var tid := str(c.get("target_item_id", ""))
			if sid == nid and not visited.has(tid):
				queue.append(tid)
			elif tid == nid and not visited.has(sid):
				queue.append(sid)
	return {"watts": watts, "has_controller": has_controller}


## Sum live draw of all loads inside a load-group compound.
static func sum_load_group_watts(
		model: GraphModel,
		compound_item: Dictionary,
		tree: SceneTree,
		sim_host: Node) -> float:
	var child_scope := str(compound_item.get("child_scope_id", ""))
	if child_scope.is_empty():
		var specs: Dictionary = compound_item.get("specs", {}) as Dictionary
		return _rated_watts_from_specs(specs)
	var total := 0.0
	for child: Dictionary in model.get_items_in_scope(child_scope):
		if bool(child.get("is_ghost", false)):
			continue
		var cid := str(child.get("id", ""))
		if cid.is_empty():
			continue
		if str(child.get("type", "")) in LOAD_TYPES:
			total += _item_draw_watts(cid, child, tree, sim_host, model)
	return total


static func compute_kw(model: GraphModel, tree: SceneTree) -> float:
	return compute_watts(model, tree) / 1000.0


## True when `circuit_idx` on a switched AC passthrough node is currently ON.
static func is_circuit_on(item: Dictionary, circuit_idx: int) -> bool:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var ty := str(item.get("type", ""))
	if ty == "breaker_panel" and not bool(specs.get("main_on", true)):
		return false
	return bool(specs.get("c%d_on" % circuit_idx, false))


static func _reachable_ac_load_ids(model: GraphModel, flat_conns: Array = []) -> Dictionary:
	var loads: Dictionary = {}
	var visited: Dictionary = {}
	var queue: Array[String] = []
	if flat_conns.is_empty():
		flat_conns = GraphNesting.flat_connections(model)

	# Controllers anywhere in the tree seed reachability (model.items spans every
	# scope; flat edges tunnel generic super-nodes so interior loads are reached).
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "controller":
			continue
		var cid := str(item.get("id", ""))
		if cid.is_empty():
			continue
		var csp: Dictionary = item.get("specs", {}) as Dictionary
		if bool(csp.get("destroyed", false)):
			continue
		_enqueue_ac_neighbors(model, cid, queue, flat_conns)

	while not queue.is_empty():
		var nid: String = queue.pop_front()
		if visited.has(nid):
			continue
		visited[nid] = true
		var item: Dictionary = model.get_item(nid)
		if item.is_empty():
			continue
		var ty := str(item.get("type", ""))
		if ty == "compound":
			var csp: Dictionary = item.get("specs", {}) as Dictionary
			if str(csp.get("compound_kind", "")) == "load_group":
				loads[nid] = true
				continue
			_enqueue_ac_neighbors(model, nid, queue, flat_conns)
			continue
		if ty in LOAD_TYPES:
			loads[nid] = true
		if ty in PASS_THROUGH_TYPES:
			_enqueue_ac_neighbors(model, nid, queue, flat_conns)

	return loads


static func _enqueue_ac_neighbors(model: GraphModel, item_id: String, queue: Array[String],
		flat_conns: Array = []) -> void:
	var item: Dictionary = model.get_item(item_id)
	var ty := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	# Whole-panel open: breaker panel main or simple AC breaker.
	if ty == "breaker_panel" and not bool(specs.get("main_on", true)):
		return
	if ty == "acbreaker" and not bool(specs.get("closed", specs.get("on", true))):
		return
	if flat_conns.is_empty():
		flat_conns = GraphNesting.flat_connections(model)

	for conn: Dictionary in flat_conns:
		if not _is_ac_power_connection(conn):
			continue
		if bool(conn.get("severed", false)):
			continue  # burned-out conduit carries nothing (Wave 8)
		var sid := str(conn.get("source_item_id", ""))
		var tid := str(conn.get("target_item_id", ""))
		var other := ""
		var out_handle := ""
		if sid == item_id:
			other = tid
			out_handle = str(conn.get("source_handle_id", ""))
		elif tid == item_id:
			other = sid
			out_handle = str(conn.get("target_handle_id", ""))
		else:
			continue
		if other.is_empty():
			continue
		# Switched passthrough: only traverse circuit_N when that channel is ON.
		# Never forward through ac_in (that would walk back upstream).
		if ty in SWITCHED_CIRCUIT_TYPES:
			if out_handle == "ac_in" or out_handle == "input":
				continue
			if out_handle.begins_with("circuit_"):
				var parts := out_handle.split("_")
				if parts.size() >= 2:
					var cidx := int(parts[1])
					if not is_circuit_on(item, cidx):
						continue
		queue.append(other)


static func _is_ac_power_connection(conn: Dictionary) -> bool:
	var pol := str(conn.get("polarity", ""))
	if pol == "ac" or pol == "load":
		return true
	var rt := str(conn.get("resource_type", ""))
	return rt == "power" or rt == "ac"


static func _find_sim_load_host(tree: SceneTree) -> Node:
	if tree == null or tree.root == null:
		return null
	var sgv := tree.root.find_child("SystemGraphView", true, false)
	if sgv == null:
		return null
	return sgv.get_node_or_null("GraphSimLoadHost")


## Public wrapper for wire Sankey / HUD: actual AC draw of one load item (W).
## Processors return 0 when not RUNNING (blocked/idle/starved/ready).
static func item_draw_watts(
		model: GraphModel,
		item: Dictionary,
		tree: SceneTree,
		sim_host: Node = null) -> float:
	if item.is_empty():
		return 0.0
	var iid := str(item.get("id", ""))
	if sim_host == null and tree != null:
		sim_host = _find_sim_load_host(tree)
	return _item_draw_watts(iid, item, tree, sim_host, model)


## Watts delivered through one AC connection (load-side of the cut). Used by
## the canvas wire estimator so feeder thickness tracks real consumption.
static func connection_delivered_watts(
		model: GraphModel,
		conn: Dictionary,
		tree: SceneTree,
		sim_host: Node = null) -> float:
	if model == null or conn.is_empty():
		return 0.0
	if sim_host == null and tree != null:
		sim_host = _find_sim_load_host(tree)
	return _connection_delivered_watts(model, conn, tree, sim_host)


static func _item_draw_watts(
		item_id: String,
		item: Dictionary,
		tree: SceneTree,
		sim_host: Node,
		model: GraphModel = null) -> float:
		
	# 1. Global check: If AC output is disabled at the bus, there is no AC load.
	if tree != null and tree.root != null:
		var apb: Node = tree.root.get_node_or_null("AcPowerBus")
		if apb != null and "ac_output_enabled" in apb:
			if not bool(apb.get("ac_output_enabled")):
				return 0.0

	var ty := str(item.get("type", ""))
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)

	# 2. Processors: draw is driven by the resource engine's RUNNING state (which
	# already encodes switched-on + powered + fed), NOT the sim-load switch. A
	# running continuous processor draws its rated watts; a batch draws its active
	# phase watts; anything else (ready/blocked/idle) draws nothing.
	if ty == "processor":
		if item.has("batch_active_watts"):
			return float(item.get("batch_active_watts", 0.0))
		if str(specs.get("node_state", "")) == GraphNodeState.RUNNING:
			return _rated_watts_from_specs(specs)
		return 0.0

	# 3. Non-processor loads: ON = requested on and power available.
	var is_on := false
	if sim_host != null and sim_host.has_method("has_sim_load") \
			and bool(sim_host.call("has_sim_load", item_id)):
		is_on = bool(sim_host.call("is_load_on", item_id))
	else:
		is_on = _item_is_on(item, specs)

	if not is_on:
		return 0.0

	# 4. Live scene devices report their own draw.
	var dev_path := str(item.get("device_path", specs.get("scene_device_path", "")))
	if not dev_path.is_empty():
		var node := _resolve_node(tree, dev_path)
		if node != null:
			if node.has_method("get_current_power"):
				return maxf(0.0, float(node.call("get_current_power")))
			if node.has_method("get_power_consumption"):
				return maxf(0.0, float(node.call("get_power_consumption")))

	# 5. Wave 8 lights-as-wires: light-string loads scale with the routed 3D
	# length of their feed wire (watts_per_m × route_length_m). Falls back to
	# the rated wattage until the wire has a measured run.
	var wpm := float(specs.get("watts_per_m", 0.0))
	if wpm > 0.0 and model != null:
		var run_m := _longest_route_length_m(model, item_id)
		if run_m > 0.001:
			return wpm * run_m

	# 6. Fallback for simple loads: use rated wattage.
	return _rated_watts_from_specs(specs)


static func _longest_route_length_m(model: GraphModel, item_id: String) -> float:
	var best := 0.0
	for conn: Dictionary in model.connections_for_item(item_id):
		if not _is_ac_power_connection(conn):
			continue
		best = maxf(best, maxf(
			float(conn.get("route_length_m", 0.0)),
			float(conn.get("estimated_length", 0.0))))
	return best


static func _item_is_on(item: Dictionary, specs: Dictionary) -> bool:
	var is_on_v: Variant = item.get("is_on", null)
	if is_on_v != null and not bool(is_on_v):
		return false
	var st := str(specs.get("current_state", "")).to_lower()
	if st == "off":
		return false
	if st == "on":
		return true
	var req := str(specs.get("requested_state", "")).to_lower()
	if req == "on":
		return true
	if req == "off":
		return false
	# No explicit state — treat as off unless a scene device reports draw.
	return not str(item.get("device_path", specs.get("scene_device_path", ""))).is_empty()


static func _rated_watts_from_specs(specs: Dictionary) -> float:
	var avg := float(specs.get("avg_watts", 0.0))
	if avg > 0.0:
		return avg
	var w := float(specs.get("watts", 0.0))
	if w > 0.0:
		return w
	return maxf(0.0, float(specs.get("max_watts", 0.0)))


static func _resolve_node(tree: SceneTree, path_str: String) -> Node:
	if path_str.is_empty() or tree == null or tree.root == null:
		return null
	var node: Node = tree.root.get_node_or_null(NodePath(path_str))
	if node != null:
		return node
	# Fallback: suffix match when saves remap the Main subtree.
	for n: Node in tree.get_nodes_in_group("power_consumers"):
		if str(n.get_path()).ends_with(path_str.get_file()):
			return n
	return null
