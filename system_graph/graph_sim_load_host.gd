class_name GraphSimLoadHost
extends Node
## Manages GraphSimLoad child nodes for every non-virtual load item in the
## associated GraphModel. Runs on setup() and whenever the model changes,
## so library-spawned appliance / acload / processor items become first-class
## power consumers (enabling SceneNodeAction-based automations to fire).

const GraphSimLoadScript := preload("res://system_graph/graph_sim_load.gd")

const LOAD_TYPES := ["appliance", "acload", "processor", "resource"]

var _model: RefCounted = null
## item_id → GraphSimLoad (Node child of this host).
var _loads: Dictionary = {}
## Reentrancy guard — `_sync_all` mutates the model (device_path / specs),
## which in turn fires model.changed. The guard prevents feedback loops.
var _syncing: bool = false
## While true (sim bulk tick), telemetry `update_item` storms are coalesced
## into one `_sync_existing_loads` at end_bulk_sync() instead of a full
## `_sync_all` per write.
var _bulk_suppress: bool = false
var _pending_telemetry_sync: bool = false


func setup(model: RefCounted) -> void:
	_model = model
	if _model != null and _model.has_signal("changed"):
		if not _model.changed.is_connected(_on_model_changed):
			_model.changed.connect(_on_model_changed)
	_sync_all()


func teardown() -> void:
	if _model != null and _model.has_signal("changed"):
		if _model.changed.is_connected(_on_model_changed):
			_model.changed.disconnect(_on_model_changed)
	for load_id: String in _loads.keys().duplicate():
		_remove_load(load_id)
	_loads.clear()
	_model = null


func begin_bulk_sync() -> void:
	_bulk_suppress = true


func end_bulk_sync() -> void:
	_bulk_suppress = false
	if _pending_telemetry_sync:
		_pending_telemetry_sync = false
		_sync_existing_loads()


func _on_model_changed(reason: String) -> void:
	if _syncing:
		return
	# Telemetry writes dominate sim ticks — coalesce during bulk, and outside
	# bulk only refresh known proxies (structural add/remove still full sync).
	if reason == "update_item":
		if _bulk_suppress:
			_pending_telemetry_sync = true
			return
		_sync_existing_loads()
		return
	_sync_all()


## Public entry-point used by SystemGraphView after deserialize/restore so we
## immediately recreate sim-loads for every persisted library item.
func refresh() -> void:
	_sync_all()


## Cheap path for telemetry ticks: push watts/state into already-tracked
## proxies without scanning the whole model for new load items.
func _sync_existing_loads() -> void:
	if _model == null or not ("items" in _model):
		return
	_syncing = true
	for iid: String in _loads.keys().duplicate():
		var item: Dictionary = {}
		if _model.has_method("get_item"):
			item = _model.call("get_item", iid) as Dictionary
		if item.is_empty():
			_remove_load(iid)
			continue
		if not is_load_item(item):
			_remove_load(iid)
			continue
		_ensure_load(iid, item)
	_syncing = false


## A load proxy is a CONSUMER switch. Generators (hydro turbines — processors
## with role siphon_hydro) make power and must not get one: it stamped
## "current_state: off" onto a running turbine and made the node look
## scene-linked to a plain proxy node.
static func is_load_item(item: Dictionary) -> bool:
	if item.is_empty() or bool(item.get("is_virtual", false)):
		return false
	var itype := str(item.get("type", ""))
	if not LOAD_TYPES.has(itype):
		return false
	if itype == "processor" \
			and str((item.get("specs", {}) as Dictionary).get("role", "")) == "siphon_hydro":
		return false
	return true


func is_load_on(item_id: String) -> bool:
	var node: Node = _loads.get(item_id, null)
	if node == null or not is_instance_valid(node):
		return false
	if node.get("is_on") != null:
		return bool(node.is_on)
	return false


func has_sim_load(item_id: String) -> bool:
	var node: Node = _loads.get(item_id, null)
	return node != null and is_instance_valid(node)


func _sync_all() -> void:
	if _model == null or not ("items" in _model):
		return
	_syncing = true
	var active_ids: Dictionary = {}
	for it: Dictionary in (_model.items as Array):
		var iid: String = str(it.get("id", ""))
		if iid.is_empty():
			continue
		if not is_load_item(it):
			continue
		active_ids[iid] = true
		_ensure_load(iid, it)
	for existing_id: String in _loads.keys().duplicate():
		if not active_ids.has(existing_id):
			_remove_load(existing_id)
	_syncing = false


func _ensure_load(iid: String, item: Dictionary) -> void:
	var specs: Dictionary = item.get("specs", {}) as Dictionary

	# Items created from the "Scene Devices" library entry mirror a scene node
	# that already contributes to the power_consumers group directly.  No proxy
	# is needed here; just keep device_path pointing at the scene node so that
	# SceneNodeAction automations can target it.
	var scene_dev_path: String = str(specs.get("scene_device_path", ""))
	if not scene_dev_path.is_empty():
		if str(item.get("device_path", "")) != scene_dev_path:
			if _model.has_method("update_item"):
				_model.call("update_item", iid, {"device_path": scene_dev_path})
		return

	var rated_w: float = float(specs.get("max_watts", specs.get("watts", 200.0)))
	var avg_w: float = float(specs.get("avg_watts", rated_w))
	# Items that have automations must start OFF so the automation manages state.
	# Restoring a stale "on" from a save would cause the load to reappear every
	# day when power becomes available, even after the user deletes the node.
	# Manually-controlled items (no automations) still restore their saved state.
	var autos: Array = specs.get("graph_automations", []) as Array
	var target_on: bool
	if not autos.is_empty():
		target_on = false
	else:
		# A load that never had a state (freshly placed) is ON — the same
		# default GraphAcLoad.demand_watts and the challenge bake use. This
		# said "off", so a newly wired appliance drew in the bake and the
		# demand sum while its own card read "○ OFF · 0 W" (bootcamp L9).
		var req_s: String = str(specs.get("requested_state", specs.get("current_state", "on"))).to_lower()
		target_on = (req_s == "on")

	# Read as Variant and validate BEFORE the typed assignment: assigning a
	# freed instance to a `Node`-typed var throws "Trying to assign invalid
	# previously freed instance" on the assignment itself, so the guard that
	# used to sit on the next line was unreachable for exactly the case it
	# existed to handle.
	var node: Node = null
	var node_v: Variant = _loads.get(iid, null)
	if node_v != null and is_instance_valid(node_v):
		node = node_v as Node
	else:
		_loads.erase(iid)

	# Side-by-side V1/V2 parity: if another host in the scene already owns a
	# sim-load for this item id, defer to it (prevents double-counting the
	# same graph-only load in solar_ui's power_consumers sum). We still keep
	# our own weak reference so teardown/refresh bookkeeping stays consistent.
	if node == null:
		var shared: Node = _find_foreign_sim_load(iid)
		if shared != null:
			_loads[iid] = shared
			var shared_path: String = str(shared.get_path())
			if str(item.get("device_path", "")) != shared_path:
				if _model.has_method("update_item"):
					_model.call("update_item", iid, {"device_path": shared_path})
			if shared.has_method("sync_from_model"):
				# Preserve runtime state for existing automation-managed nodes.
				# Only force off for newly adopted nodes (no prior state).
				var shared_target: bool = target_on
				if not autos.is_empty():
					var v: Variant = shared.get("_requested_on")
					shared_target = v != null and bool(v)
				var in_valve: bool = bool(specs.get("input_valve_open", true))
				var out_valve: bool = bool(specs.get("output_valve_open", true))
				shared.call("sync_from_model", shared_target, rated_w, avg_w, in_valve, out_valve)
			return

	var is_new_node: bool = (node == null)
	if node == null:
		node = GraphSimLoadScript.new()
		node.name = "SimLoad_%s" % iid
		node.set("item_id", iid)
		node.set("model_ref", _model)
		add_child(node)
		_loads[iid] = node

	# Always (re)set device_path on the item — NodePaths can change across
	# scene reloads, and only this host knows the current runtime path.
	var dev_path: String = str(node.get_path())
	if str(item.get("device_path", "")) != dev_path:
		if _model.has_method("update_item"):
			_model.call("update_item", iid, {"device_path": dev_path})

	# Sync live specs + state without triggering state_changed feedback.
	# New nodes with automations start OFF (automation controls the first turn-on).
	# Existing nodes with automations preserve their runtime _requested_on so that
	# an automation firing turn_on() is not immediately undone by model.changed
	# triggering _sync_all() again via _apply_state_to_model().
	if node.has_method("sync_from_model"):
		var effective_target: bool = target_on
		if not is_new_node and not autos.is_empty():
			var v: Variant = node.get("_requested_on")
			effective_target = v != null and bool(v)
		var in_valve: bool = bool(specs.get("input_valve_open", true))
		var out_valve: bool = bool(specs.get("output_valve_open", true))
		node.call("sync_from_model", effective_target, rated_w, avg_w, in_valve, out_valve)


## Look for an existing GraphSimLoad (from a sibling view / host) that already
## represents `iid`. Returns null if none exists. Walks the "power_consumers"
## group so we don't rely on a specific parent layout.
func _find_foreign_sim_load(iid: String) -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	for n: Node in tree.get_nodes_in_group("power_consumers"):
		if n == null or not is_instance_valid(n):
			continue
		if not (n.has_meta("graph_sim_load") and bool(n.get_meta("graph_sim_load"))):
			continue
		if str(n.get("item_id")) == iid:
			return n
	return null


func _remove_load(iid: String) -> void:
	if not _loads.has(iid):
		return
	var node: Node = _loads[iid]
	_loads.erase(iid)
	# Only free sim-loads we actually own. Shared/foreign proxies (tracked for
	# device_path sync only) are freed by their owning host.
	if is_instance_valid(node) and node.get_parent() == self:
		node.queue_free()
