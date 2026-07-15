class_name GraphAcLoad
extends RefCounted
## Computes total AC load (W) from the system graph: only load/processor nodes
## that are reachable from a controller AC output through AC/load wires, and
## that are currently ON.

const LOAD_TYPES: Array[String] = ["appliance", "acload", "processor"]
const PASS_THROUGH_TYPES: Array[String] = ["shelly4pm", "acbreaker", "acoutlet", "controller"]


static func compute_watts(model: GraphModel, tree: SceneTree) -> float:
	if model == null or tree == null:
		return 0.0
	var reachable := _reachable_ac_load_ids(model)
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
		total += _item_draw_watts(iid, item, tree, sim_host)
	return maxf(0.0, total)


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
			total += _item_draw_watts(cid, child, tree, sim_host)
	return total


static func compute_kw(model: GraphModel, tree: SceneTree) -> float:
	return compute_watts(model, tree) / 1000.0


static func _reachable_ac_load_ids(model: GraphModel) -> Dictionary:
	var loads: Dictionary = {}
	var visited: Dictionary = {}
	var queue: Array[String] = []

	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "controller":
			continue
		var cid := str(item.get("id", ""))
		if cid.is_empty():
			continue
		_enqueue_ac_neighbors(model, cid, queue)

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
			_enqueue_ac_neighbors(model, nid, queue)
			continue
		if ty in LOAD_TYPES:
			loads[nid] = true
		if ty in PASS_THROUGH_TYPES:
			_enqueue_ac_neighbors(model, nid, queue)

	return loads


static func _enqueue_ac_neighbors(model: GraphModel, item_id: String, queue: Array[String]) -> void:
	for conn: Dictionary in model.connections:
		if not _is_ac_power_connection(conn):
			continue
		var sid := str(conn.get("source_item_id", ""))
		var tid := str(conn.get("target_item_id", ""))
		if sid == item_id:
			queue.append(tid)
		elif tid == item_id:
			queue.append(sid)


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


static func _item_draw_watts(
		item_id: String,
		item: Dictionary,
		tree: SceneTree,
		sim_host: Node) -> float:
		
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

	# 5. Fallback for simple loads: use rated wattage.
	return _rated_watts_from_specs(specs)


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
