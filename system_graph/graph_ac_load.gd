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
	return _compute_watts(model, tree, _find_sim_load_host(tree), -1)


## The same reading with no scene at all — for a model that is not the live
## one (an experiment's copy): every load's on / off comes from its own specs
## (requested / current state), scene devices draw their rated watts, the AC
## bus is assumed on (the caller sheds load itself), and wire losses are
## counted when `losses_on`.
static func compute_watts_offline(model: GraphModel, losses_on: bool) -> float:
	if model == null:
		return 0.0
	return _compute_watts(model, null, null, 1 if losses_on else 0)


static func _compute_watts(model: GraphModel, tree: SceneTree, sim_host: Node, losses: int) -> float:
	# Flatten super-node (compound) portals once: AC reachability then tunnels
	# through generic groups at any depth, while opaque load-group compounds stay
	# nodes (summed via sum_load_group_watts). Computed once, threaded down.
	# The memoised flattening: this runs at 10 Hz from SolarUI's load reading
	# and the edges are read-only here (loss telemetry lands on the real wires).
	var flat := GraphNesting.flat_connections_cached(model)
	var reachable := _reachable_ac_load_ids(model, flat)
	if reachable.is_empty():
		return 0.0
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
	total += connection_losses_watts(model, tree, sim_host, flat, losses)
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
	var flat := GraphNesting.flat_connections_cached(model)
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
		sim_host: Node = null, flat_conns: Array = [], losses: int = -1) -> float:
	# losses: -1 = the player's setting, 0 / 1 = forced (an offline model).
	var global_on := losses_enabled(tree) if losses < 0 else losses == 1
	if flat_conns.is_empty():
		flat_conns = GraphNesting.flat_connections(model)
	var total := 0.0
	# A wire inside a vehicle or camp carries THAT system's power: its loss is
	# not a load on the site's inverter.
	var islands := GraphSystems.island_scopes(model)
	# One adjacency index for every wire's load-side question (built lazily:
	# a graph with no electrical AC wire never pays for it). The per-wire form
	# scanned every flat connection at every node it visited, for every wire.
	var ix: Dictionary = {}
	# Loss + telemetry stays on the REAL wires the player sees; only the load-side
	# reachability BFS uses the flattened graph (via the index).
	for conn: Dictionary in model.connections:
		if not _is_ac_power_connection(conn):
			continue
		if not islands.is_empty() and islands.has(str(conn.get("scope_id", "root"))):
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
		if ix.is_empty():
			ix = delivered_index(model, tree, sim_host, flat_conns, true)
		var delivered: float = delivered_watts_indexed(model, ix, conn)
		# The chosen gauge's resistance and ampacity (ConduitSpecs); a run nobody
		# re-sized reads the kind's own default, unchanged.
		var meta: Dictionary = ConduitSpecs.loss_meta(type_id,
			conn.get("conduit_style", {}) as Dictionary)
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


## Many delivered-watts questions in a row (the graph canvas asks for every
## visible wire each refresh): the AC adjacency built once and each item's
## draw remembered, so a question is one BFS over adjacency lists. The plain
## form scans every connection at every node it visits and deep-copies each
## load's specs, which was ~130 µs a wire on a 227-wire graph.
## Returns an index for `delivered_watts_indexed`; same answers as
## `connection_delivered_watts`.
##
## `block_ghosts`: a ghost (or missing) node ends the walk there, as
## _side_summary does: the wire losses use that rule; the canvas's wire
## widths walk through ghosts as they always have.
static func delivered_index(model: GraphModel, tree: SceneTree, sim_host: Node = null,
		flat_conns: Array = [], block_ghosts: bool = false, sample_now: bool = false) -> Dictionary:
	if sim_host == null and tree != null:
		sim_host = _find_sim_load_host(tree)
	var adj := {}
	if model != null:
		var flat: Array = flat_conns if not flat_conns.is_empty() \
				else GraphNesting.flat_connections_cached(model)
		for c: Dictionary in flat:
			if not _is_ac_power_connection(c) or bool(c.get("severed", false)):
				continue
			var cid := str(c.get("id", ""))
			var sid := str(c.get("source_item_id", ""))
			var tid := str(c.get("target_item_id", ""))
			if not adj.has(sid):
				adj[sid] = []
			if not adj.has(tid):
				adj[tid] = []
			(adj[sid] as Array).append([cid, tid])
			(adj[tid] as Array).append([cid, sid])
	return {"adj": adj, "w": {}, "ctrl": {}, "ghost": {}, "tree": tree, "host": sim_host,
		"block_ghosts": block_ghosts, "sample_now": sample_now}


static func delivered_watts_indexed(model: GraphModel, ix: Dictionary, conn: Dictionary) -> float:
	if model == null or conn.is_empty() or ix.is_empty():
		return 0.0
	var cid := str(conn.get("id", ""))
	var src_res := GraphNesting.resolve_port(model, str(conn.get("source_item_id", "")),
			str(conn.get("source_handle_id", "")))
	var tgt_res := GraphNesting.resolve_port(model, str(conn.get("target_item_id", "")),
			str(conn.get("target_handle_id", "")))
	var side_a := _side_summary_ix(model, ix, str(src_res["item_id"]), cid)
	var side_b := _side_summary_ix(model, ix, str(tgt_res["item_id"]), cid)
	if side_a.y > 0.0 and side_b.y <= 0.0:
		return side_b.x
	if side_b.y > 0.0 and side_a.y <= 0.0:
		return side_a.x
	if side_a.y <= 0.0 and side_b.y <= 0.0:
		return 0.0
	return minf(side_a.x, side_b.x)


## _side_summary over the index: Vector2(watts, 1 if a controller is reached).
static func _side_summary_ix(model: GraphModel, ix: Dictionary, start_id: String, cut_conn_id: String) -> Vector2:
	if start_id.is_empty():
		return Vector2.ZERO
	var adj: Dictionary = ix["adj"]
	var memo_w: Dictionary = ix["w"]
	var memo_c: Dictionary = ix["ctrl"]
	var memo_g: Dictionary = ix.get("ghost", {})
	var block := bool(ix.get("block_ghosts", false))
	var watts := 0.0
	var has_controller := false
	var visited: Dictionary = {}
	var queue: Array[String] = [start_id]
	var head := 0
	while head < queue.size():
		var nid: String = queue[head]
		head += 1
		if visited.has(nid):
			continue
		visited[nid] = true
		if not memo_w.has(nid):
			var item: Dictionary = model.get_item(nid)
			var w := 0.0
			var ctl := false
			memo_g[nid] = item.is_empty() or bool(item.get("is_ghost", false))
			if not bool(memo_g[nid]):
				var ty := str(item.get("type", ""))
				ctl = ty == "controller"
				if ty == "compound":
					var sp: Dictionary = item.get("specs", {}) as Dictionary
					if str(sp.get("compound_kind", "")) == "load_group":
						w = sum_load_group_watts(model, item, ix["tree"], ix["host"],
							bool(ix.get("sample_now", false)))
				elif ty in LOAD_TYPES:
					w = _item_draw_watts(nid, item, ix["tree"], ix["host"], model,
						bool(ix.get("sample_now", false)))
			memo_w[nid] = w
			memo_c[nid] = ctl
		if block and bool(memo_g.get(nid, false)):
			continue
		watts += float(memo_w[nid])
		if bool(memo_c[nid]):
			has_controller = true
		for e in (adj.get(nid, []) as Array):
			if str(e[0]) == cut_conn_id:
				continue
			var other := str(e[1])
			if not visited.has(other):
				queue.append(other)
	return Vector2(watts, 1.0 if has_controller else 0.0)


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
		sim_host: Node,
		sample_now: bool = false) -> float:
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
			total += _item_draw_watts(cid, child, tree, sim_host, model, sample_now)
	return total


static func compute_kw(model: GraphModel, tree: SceneTree) -> float:
	return compute_watts(model, tree) / 1000.0


## Mean and coincident peak over [t0_h, t1_h]. mean_w is what the battery
## integrates; peak_w and by_breaker are what the inverter and the breakers
## see. Wire loss is added as a steady term (a spike does not heat a conductor).
static func evaluate_step(model: GraphModel, tree: SceneTree, t0_h: float, t1_h: float,
		restore_h: float = -1.0, continuous_w: float = -1.0, surge_w: float = -1.0) -> Dictionary:
	var empty := {"mean_w": 0.0, "peak_w": 0.0, "watt_hours": 0.0, "now_w": 0.0,
		"above_continuous_s": 0.0, "above_surge_s": 0.0, "by_item": {}, "by_breaker": {}}
	if model == null:
		return empty
	if _ac_bus_off(tree):
		return empty
	var sim_host := _find_sim_load_host(tree)
	var flat := GraphNesting.flat_connections_cached(model)
	var loads := _collect_signature_loads(model, tree, sim_host, flat, restore_h)
	var step := PowerSignature.coincide(loads, t0_h, t1_h, restore_h, continuous_w, surge_w)
	var loss := connection_losses_watts(model, tree, sim_host, flat, -1) if tree != null else 0.0
	var dt := maxf(t1_h - t0_h, 0.0)
	step["mean_w"] = float(step.get("mean_w", 0.0)) + loss
	step["watt_hours"] = float(step.get("watt_hours", 0.0)) + loss * dt
	step["now_w"] = float(step.get("now_w", 0.0)) + loss
	step["peak_w"] = float(step.get("peak_w", 0.0)) + loss
	return step


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
	# A living vehicle's own controller is NOT the site's: its fridge and fans
	# run off the vehicle's house battery, so they never count toward the
	# site inverter (forty vehicles' loads tripped its overload).
	# Camps too (GraphSystems): every power island runs its loads off its own
	# bus.
	var own := GraphSystems.island_scopes(model)
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "controller":
			continue
		var cid := str(item.get("id", ""))
		if cid.is_empty():
			continue
		if not own.is_empty() and own.has(str(item.get("scope_id", "root"))):
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


## Every scope inside a living vehicle's graph node (a compound carrying
## specs.vehicle_prop_id), at any depth. One pass over the items.
static func vehicle_scopes(model: GraphModel) -> Dictionary:
	var out: Dictionary = {}
	if model == null:
		return out
	var parent_of: Dictionary = {}   # child scope id -> the compound that opens it
	var roots: Array = []
	for item: Dictionary in model.items:
		var cs := str(item.get("child_scope_id", ""))
		if cs.is_empty():
			continue
		parent_of[cs] = item
		if ((item.get("specs", {}) as Dictionary)).has("vehicle_prop_id"):
			roots.append(cs)
	if roots.is_empty():
		return out
	for cs: String in parent_of.keys():
		var s := cs
		for _depth in 16:
			if roots.has(s):
				out[cs] = true
				break
			var up: Variant = parent_of.get(s)
			if up == null:
				break
			s = str((up as Dictionary).get("scope_id", "root"))
	return out


static func _enqueue_ac_neighbors(model: GraphModel, item_id: String, queue: Array[String],
		flat_conns: Array = []) -> void:
	for other in _ac_neighbor_ids(model, item_id, flat_conns):
		queue.append(str(other))


## AC neighbours of one node, with the same open-breaker and switched-circuit
## stops as the reachability walk. An open breaker returns nothing.
static func _ac_neighbor_ids(model: GraphModel, item_id: String, flat_conns: Array = []) -> Array:
	var out: Array = []
	var item: Dictionary = model.get_item(item_id)
	var ty := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	# Whole-panel open: breaker panel main or simple AC breaker.
	if ty == "breaker_panel" and not bool(specs.get("main_on", true)):
		return out
	if ty == "acbreaker" and not bool(specs.get("closed", specs.get("on", true))):
		return out
	if flat_conns.is_empty():
		flat_conns = GraphNesting.flat_connections(model)

	for conn: Dictionary in (_ends_index(flat_conns).get(item_id, []) as Array):
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
		# A hybrid's grid and generator inputs feed the unit; what hangs off
		# them is upstream, not a load on its inverter.
		if ty == "controller" and out_handle in ["acInput", "genInput"]:
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
		out.append(other)
	return out


## Each item id -> the flat connections that end on it, in flat order (a
## wire from an item to itself listed once). Cached for the flat array it was
## built from: flat_connections_cached hands back the same array until the
## graph changes, so the index is built once per change.
static var _ends_src: Array = []
static var _ends_n := -1
static var _ends: Dictionary = {}


static func _ends_index(flat_conns: Array) -> Dictionary:
	if is_same(flat_conns, _ends_src) and _ends_n == flat_conns.size():
		return _ends
	var idx := {}
	for c_v in flat_conns:
		var c: Dictionary = c_v
		var sid := str(c.get("source_item_id", ""))
		var tid := str(c.get("target_item_id", ""))
		if not idx.has(sid):
			idx[sid] = []
		(idx[sid] as Array).append(c)
		if tid != sid:
			if not idx.has(tid):
				idx[tid] = []
			(idx[tid] as Array).append(c)
	_ends_src = flat_conns
	_ends_n = flat_conns.size()
	_ends = idx
	return idx


static func _is_ac_power_connection(conn: Dictionary) -> bool:
	var pol := str(conn.get("polarity", ""))
	if pol == "ac" or pol == "load":
		return true
	var rt := str(conn.get("resource_type", ""))
	return rt == "power" or rt == "ac"


static func _find_sim_load_host(tree: SceneTree) -> Node:
	if tree == null or tree.root == null:
		return null
	# The registered view first: find_child walks the whole scene (terrain,
	# vegetation, props) before reaching the UI, ten times a second. The
	# search stays for scenes with no registry (selftests).
	var sgv: Node = ServiceLocator.graph()
	if sgv == null or not sgv.is_inside_tree():
		sgv = tree.root.find_child("SystemGraphView", true, false)
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
	return _item_draw_watts(iid, item, tree, sim_host, model, true)


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
		model: GraphModel = null,
		sample_now: bool = false) -> float:
	# 1. Global check: If AC output is disabled at the bus, there is no AC load.
	if _ac_bus_off(tree):
		return 0.0
	var classified := _classify_draw(item_id, item, tree, sim_host, model)
	if str(classified.get("kind", "")) == "off":
		return 0.0
	if str(classified.get("kind", "")) == "fixed":
		return float(classified.get("w", 0.0))
	var specs: Dictionary = classified.get("specs", {}) as Dictionary
	var level := float(classified.get("level_w", -1.0))
	if sample_now:
		var clk := _sim_clock(tree)
		if clk.x >= 0.0:
			return PowerSignature.watts_at(specs, clk.x,
				_signature_origin(specs, clk.y), item_id, level)
	return PowerSignature.mean_watts(specs, level)


static var _clk_frame := -1
static var _clk_abs := -1.0
static var _clk_restore := -1.0


static func _ac_bus_off(tree: SceneTree) -> bool:
	if tree == null or tree.root == null:
		return false
	var apb: Node = tree.root.get_node_or_null("AcPowerBus")
	if apb != null and "ac_output_enabled" in apb:
		return not bool(apb.get("ac_output_enabled"))
	return false


## Vector2(absolute hours, restore hour). x < 0 when this scene has no clock,
## which keeps a reading on the cycle average.
static func _sim_clock(tree: SceneTree) -> Vector2:
	var frame := Engine.get_process_frames()
	if frame == _clk_frame and frame > 0:
		return Vector2(_clk_abs, _clk_restore)
	_clk_frame = frame
	_clk_abs = -1.0
	_clk_restore = -1.0
	if tree == null or tree.root == null:
		return Vector2(-1.0, -1.0)
	var scene := tree.current_scene
	if scene != null and scene.has_method("get_absolute_hours"):
		_clk_abs = float(scene.call("get_absolute_hours"))
	else:
		var main := tree.root.find_child("Main", true, false)
		if main != null and main.has_method("get_absolute_hours"):
			_clk_abs = float(main.call("get_absolute_hours"))
	var bus := tree.root.get_node_or_null("AcPowerBus")
	if bus != null and "ac_restore_h" in bus:
		_clk_restore = float(bus.get("ac_restore_h"))
		if _clk_abs >= 0.0 and _clk_restore >= 0.0 and _clk_abs < _clk_restore:
			_clk_restore = -1.0
	return Vector2(_clk_abs, _clk_restore)


## Where a signature's phase zero sits. A pump uses the hour it entered
## RUNNING. A battery uses the later of its charge start and the last outage.
## Cyclic loads share the outage.
static func _signature_origin(specs: Dictionary, restore_h: float) -> float:
	var fam := str(specs.get("signature_family", ""))
	if fam == "inductive_start":
		return float(specs.get("powered_since_h", -1.0)) if specs.has("powered_since_h") else -1.0
	if fam == "battery":
		var started := float(specs.get("charge_started_h", -1.0)) if specs.has("charge_started_h") else -1.0
		if restore_h >= 0.0 and (started < 0.0 or restore_h > started):
			return restore_h
		return started
	return restore_h


## {kind: off} | {kind: fixed, w} | {kind: sig, specs, level_w}.
## The bus-off check stays with the caller. Scene devices, a live meter, and a
## measured light-string length stay a flat number; a declared family shapes
## whatever wattage the processor is actually drawing.
static func _classify_draw(item_id: String, item: Dictionary, tree: SceneTree,
		sim_host: Node, model: GraphModel) -> Dictionary:
	var ty := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if ty == "processor":
		var drawing := false
		var level := -1.0
		if item.has("batch_active_watts"):
			drawing = true
			level = maxf(float(item.get("batch_active_watts", 0.0)), 0.0)
		elif str(specs.get("node_state", "")) == GraphNodeState.RUNNING:
			drawing = true
			if specs.has("live_watts"):
				level = maxf(float(specs.get("live_watts", 0.0)), 0.0)
		if not drawing:
			return {"kind": "off"}
		var fixed_p := _fixed_override_w(item_id, item, specs, tree, model)
		if fixed_p >= 0.0:
			return {"kind": "fixed", "w": fixed_p}
		if PowerSignature.has_family(specs):
			return {"kind": "sig", "specs": specs, "level_w": level if level >= 0.0 else -1.0}
		if level >= 0.0:
			return {"kind": "fixed", "w": level}
		return {"kind": "fixed", "w": _rated_watts_from_specs(specs)}
	var is_on := false
	if sim_host != null and sim_host.has_method("has_sim_load") \
			and bool(sim_host.call("has_sim_load", item_id)):
		is_on = bool(sim_host.call("is_load_on", item_id))
	else:
		is_on = _item_is_on(item, specs)
	if not is_on:
		return {"kind": "off"}
	var fixed := _fixed_override_w(item_id, item, specs, tree, model)
	if fixed >= 0.0:
		return {"kind": "fixed", "w": fixed}
	if PowerSignature.has_family(specs):
		return {"kind": "sig", "specs": specs, "level_w": -1.0}
	return {"kind": "fixed", "w": _rated_watts_from_specs(specs)}


## Scene device, live HA power, or a routed light string. -1 means "no override".
static func _fixed_override_w(item_id: String, item: Dictionary, specs: Dictionary,
		tree: SceneTree, model: GraphModel) -> float:
	var dev_path := str(item.get("device_path", specs.get("scene_device_path", "")))
	if not dev_path.is_empty():
		var node := _resolve_node(tree, dev_path)
		if node != null:
			if node.has_method("get_current_power"):
				return maxf(0.0, float(node.call("get_current_power")))
			if node.has_method("get_power_consumption"):
				return maxf(0.0, float(node.call("get_power_consumption")))
	if tree != null and tree.root != null:
		var sm := tree.root.get_node_or_null("SimMode")
		if sm != null and sm.has_method("is_live") and bool(sm.call("is_live")):
			var live: Dictionary = specs.get("ha_live", {}) as Dictionary
			var power: Variant = live.get("power", null)
			if power is Dictionary and (power as Dictionary).has("value"):
				return maxf(0.0, float((power as Dictionary).get("value", 0.0)))
	var wpm := float(specs.get("watts_per_m", 0.0))
	if wpm > 0.0 and model != null:
		var run_m := _longest_route_length_m(model, item_id)
		if run_m > 0.001:
			return wpm * run_m
	return -1.0


## Reachable loads as PowerSignature.coincide records, each tagged with every
## closed breaker on the path from the site controller. Load-group children
## are separate loads so each one keeps its own curve.
static func _collect_signature_loads(model: GraphModel, tree: SceneTree, sim_host: Node,
		flat: Array, restore_h: float) -> Array:
	var out: Array = []
	var visited := {}
	var queue: Array = []
	var own := GraphSystems.island_scopes(model)
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "controller":
			continue
		var cid := str(item.get("id", ""))
		if cid.is_empty():
			continue
		if not own.is_empty() and own.has(str(item.get("scope_id", "root"))):
			continue
		var csp: Dictionary = item.get("specs", {}) as Dictionary
		if bool(csp.get("destroyed", false)):
			continue
		for other in _ac_neighbor_ids(model, cid, flat):
			queue.append([str(other), []])
	while not queue.is_empty():
		var pair: Array = queue.pop_front()
		var nid := str(pair[0])
		if visited.has(nid):
			continue
		visited[nid] = true
		var brs: Array = pair[1]
		var it: Dictionary = model.get_item(nid)
		if it.is_empty() or bool(it.get("is_ghost", false)):
			continue
		var ty := str(it.get("type", ""))
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var next_brs := brs
		if ty == "acbreaker" and BreakerTrip.is_closed(specs):
			next_brs = brs.duplicate()
			next_brs.append(nid)
		if ty == "compound":
			if str(specs.get("compound_kind", "")) == "load_group":
				_append_group_loads(out, model, it, tree, sim_host, next_brs, restore_h)
				continue
			for other2 in _ac_neighbor_ids(model, nid, flat):
				queue.append([str(other2), next_brs])
			continue
		if ty in LOAD_TYPES:
			var rec := _coincide_record(nid, it, tree, sim_host, model, next_brs, restore_h)
			if not rec.is_empty():
				out.append(rec)
		if ty in PASS_THROUGH_TYPES:
			for other3 in _ac_neighbor_ids(model, nid, flat):
				queue.append([str(other3), next_brs])
	return out


static func _append_group_loads(out: Array, model: GraphModel, compound: Dictionary,
		tree: SceneTree, sim_host: Node, breakers: Array, restore_h: float) -> void:
	var child_scope := str(compound.get("child_scope_id", ""))
	if child_scope.is_empty():
		return
	for child: Dictionary in model.get_items_in_scope(child_scope):
		if bool(child.get("is_ghost", false)):
			continue
		if str(child.get("type", "")) not in LOAD_TYPES:
			continue
		var cid := str(child.get("id", ""))
		var rec := _coincide_record(cid, child, tree, sim_host, model, breakers, restore_h)
		if not rec.is_empty():
			out.append(rec)


static func _coincide_record(item_id: String, item: Dictionary, tree: SceneTree,
		sim_host: Node, model: GraphModel, breakers: Array, restore_h: float) -> Dictionary:
	var classified := _classify_draw(item_id, item, tree, sim_host, model)
	var kind := str(classified.get("kind", ""))
	if kind == "off":
		return {}
	var rec := {"id": item_id, "breakers": breakers}
	if kind == "fixed":
		rec["fixed_w"] = float(classified.get("w", 0.0))
		return rec
	var specs: Dictionary = classified.get("specs", {}) as Dictionary
	rec["specs"] = specs
	rec["level_w"] = float(classified.get("level_w", -1.0))
	var fam := str(specs.get("signature_family", ""))
	if fam == "inductive_start" or fam == "battery":
		rec["origin_h"] = _signature_origin(specs, restore_h)
	return rec


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
