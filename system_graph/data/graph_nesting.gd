class_name GraphNesting
extends RefCounted

## Universal nested "super node" resolution for the systems graph.
##
## A GENERIC compound (specs.compound_kind == "") is a pure VISUAL grouping: its
## specs.exposed_ports map each compound handle -> an internal (child_item,
## child_handle). Because that mapping fully reconstructs the boundary-crossing
## wire, a generic compound is completely TRANSPARENT to simulation — flattening
## the graph through its portals yields exactly the same leaf-level connection
## graph as if the group had never been formed. This makes arbitrarily deep
## nesting "free" for every sim engine.
##
## SPECIAL aggregate compounds (array / battery_bank / load_group) are OPAQUE
## leaves: their consumers read baked equiv specs (array_equiv_*, bank_total_kwh)
## or sum their children explicitly (load groups), so we must NOT tunnel through
## them here. resolve_port() therefore stops at an opaque compound.
##
## exposed_ports entry shape:
##   {handle_id, child_item_id, child_handle_id, polarity, kind, label, direction}
## kind = resource kind (for pill colour); direction = "in"|"out" (external view).

const OPAQUE_KINDS: Array[String] = ["array", "battery_bank", "load_group"]
const _MAX_DEPTH := 64


static func is_compound(item: Dictionary) -> bool:
	return str(item.get("type", "")) == "compound"


static func compound_kind(item: Dictionary) -> String:
	return str((item.get("specs", {}) as Dictionary).get("compound_kind", ""))


## A generic super-node grouping (transparent to sim), as opposed to the special
## aggregate compounds which are opaque leaves.
static func is_transparent_compound(item: Dictionary) -> bool:
	if not is_compound(item):
		return false
	return not (compound_kind(item) in OPAQUE_KINDS)


static func exposed_ports(item: Dictionary) -> Array:
	return (item.get("specs", {}) as Dictionary).get("exposed_ports", []) as Array


## Resolve (item_id, handle_id) through any transparent-compound portals to the
## leaf (item, handle) that actually carries the wire. Opaque compounds and
## plain nodes resolve to themselves. Depth/cycle guarded.
static func resolve_port(model: GraphModel, item_id: String, handle_id: String,
		depth: int = 0) -> Dictionary:
	var result := {"item_id": item_id, "handle_id": handle_id}
	if model == null or depth > _MAX_DEPTH or item_id.is_empty():
		return result
	var item := model.get_item(item_id)
	if item.is_empty() or not is_transparent_compound(item):
		return result
	for ep_v in exposed_ports(item):
		var ep := ep_v as Dictionary
		if str(ep.get("handle_id", "")) == handle_id:
			var cid := str(ep.get("child_item_id", ""))
			var chid := str(ep.get("child_handle_id", ""))
			if cid.is_empty():
				return result
			return resolve_port(model, cid, chid, depth + 1)
	# Transparent compound but no exposure for this handle — dead-end leaf.
	return result


## Every connection with BOTH endpoints resolved through transparent-compound
## portals to their leaf items/handles. Each returned dict is a shallow copy of
## the real connection (so every sim-read field survives) with the 4 endpoint
## fields overwritten and its origin id preserved. Feed these to a sim engine to
## make generic super-node grouping transparent at any depth. The origin id lets
## flow writeback (_cache_conn_flow) animate the real (possibly boundary) wire.
static func flat_connections(model: GraphModel) -> Array:
	var out: Array = []
	if model == null:
		return out
	for conn_v in model.connections:
		var conn := conn_v as Dictionary
		var src := resolve_port(model, str(conn.get("source_item_id", "")),
				str(conn.get("source_handle_id", "")))
		var tgt := resolve_port(model, str(conn.get("target_item_id", "")),
				str(conn.get("target_handle_id", "")))
		var e: Dictionary = conn.duplicate()
		e["source_item_id"] = str(src["item_id"])
		e["source_handle_id"] = str(src["handle_id"])
		e["target_item_id"] = str(tgt["item_id"])
		e["target_handle_id"] = str(tgt["handle_id"])
		out.append(e)
	return out


## All items in `scope_id` plus every descendant scope, EXCEPT we do not recurse
## into the child scope of an opaque compound (array/battery_bank/load_group) —
## those are represented by their own equiv specs, not their (often hollow) kids.
## Transparent compounds ARE recursed into (their children are the real nodes);
## the transparent compound dicts themselves are also included (harmless — the
## aggregate loops match by item type and ignore generic compounds). This is the
## recursion aggregates use so nested capacity is counted at any depth.
static func walk_items(model: GraphModel, scope_id: String = "root") -> Array:
	var out: Array = []
	if model == null:
		return out
	_walk_items_into(model, scope_id, out, {})
	return out


static func _walk_items_into(model: GraphModel, scope_id: String, out: Array,
		seen: Dictionary) -> void:
	if scope_id.is_empty() or seen.has(scope_id):
		return
	seen[scope_id] = true
	for item_v in model.get_items_in_scope(scope_id):
		var item := item_v as Dictionary
		out.append(item)
		if is_transparent_compound(item):
			var cs := str(item.get("child_scope_id", ""))
			if not cs.is_empty():
				_walk_items_into(model, cs, out, seen)


## Every scope id at/below `scope_id` (inclusive), following child_scope_id of
## ALL compounds (opaque included — used for delete cascade / fault scanning).
static func descendant_scopes(model: GraphModel, scope_id: String) -> Array:
	var out: Array = []
	if model == null:
		return out
	_descendant_scopes_into(model, scope_id, out, {})
	return out


static func _descendant_scopes_into(model: GraphModel, scope_id: String, out: Array,
		seen: Dictionary) -> void:
	if scope_id.is_empty() or seen.has(scope_id):
		return
	seen[scope_id] = true
	out.append(scope_id)
	for item_v in model.get_items_in_scope(scope_id):
		var item := item_v as Dictionary
		if is_compound(item):
			var cs := str(item.get("child_scope_id", ""))
			if not cs.is_empty():
				_descendant_scopes_into(model, cs, out, seen)


## Prune any exposed_ports on a generic compound whose backing internal item no
## longer exists (live-promotion maintenance after an interior delete). Returns
## true if the compound's specs/handles were changed.
static func reconcile_exposed_ports(model: GraphModel, compound_id: String) -> bool:
	if model == null:
		return false
	var item := model.get_item(compound_id)
	if item.is_empty() or not is_transparent_compound(item):
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var eps: Array = specs.get("exposed_ports", []) as Array
	if eps.is_empty():
		return false
	var kept: Array = []
	var removed_handles: Dictionary = {}
	for ep_v in eps:
		var ep := ep_v as Dictionary
		var cid := str(ep.get("child_item_id", ""))
		if cid.is_empty() or model.get_item(cid).is_empty():
			removed_handles[str(ep.get("handle_id", ""))] = true
			continue
		kept.append(ep)
	if removed_handles.is_empty():
		return false
	specs["exposed_ports"] = kept
	# Drop the now-orphaned handles + any boundary wires still referencing them.
	var handles: Array = (item.get("handles", []) as Array).duplicate(true)
	var new_handles: Array = []
	for h_v in handles:
		var h := h_v as Dictionary
		if not removed_handles.has(str(h.get("id", ""))):
			new_handles.append(h)
	_recount_ports(specs, new_handles)
	model.update_item(compound_id, {"specs": specs, "handles": new_handles})
	for hid in removed_handles.keys():
		for conn_v in model.connections_for_item(compound_id):
			var conn := conn_v as Dictionary
			if (str(conn.get("source_item_id", "")) == compound_id and str(conn.get("source_handle_id", "")) == hid) \
					or (str(conn.get("target_item_id", "")) == compound_id and str(conn.get("target_handle_id", "")) == hid):
				model.remove_connection(str(conn.get("id", "")))
	return true


static func _recount_ports(specs: Dictionary, handles: Array) -> void:
	var in_n := 0
	var out_n := 0
	for h_v in handles:
		var h := h_v as Dictionary
		if str(h.get("direction", "")) == "out":
			out_n += 1
		else:
			in_n += 1
	specs["port_in_count"] = in_n
	specs["port_out_count"] = out_n


## One-shot migration helper: convert a legacy specs.boundary_links array into
## the new specs.exposed_ports array (called from GraphModel.deserialize).
static func migrate_boundary_links(specs: Dictionary) -> void:
	if specs.has("exposed_ports"):
		return
	var links: Array = specs.get("boundary_links", []) as Array
	if links.is_empty():
		specs["exposed_ports"] = []
		return
	var eps: Array = []
	for link_v in links:
		var link := link_v as Dictionary
		eps.append({
			"handle_id": str(link.get("compound_handle_id", "")),
			"child_item_id": str(link.get("child_item_id", "")),
			"child_handle_id": str(link.get("child_handle_id", "")),
			"polarity": str(link.get("polarity", "ac")),
			"kind": str(link.get("resource_type", "")),
			"label": str(link.get("label", "")),
			"direction": "out" if bool(link.get("source_was_child", false)) else "in",
		})
	specs["exposed_ports"] = eps
