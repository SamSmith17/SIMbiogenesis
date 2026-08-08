class_name GraphComponentDefs
extends RefCounted

## SketchUp-style component definitions for the systems graph.
##
## A DEFINITION is a structural template (topology + non-instance specs +
## exposed_ports + child layout), possibly referencing OTHER definitions by id
## (arbitrary nesting). An INSTANCE is a generic compound item whose
## specs.definition_id points at a definition; its child_scope holds a realized
## COPY of the template — real nodes with their own ids and their own live sim
## state. Each realized child carries specs.def_local_id linking it back to the
## template slot it came from.
##
## Editing the interior of ANY instance -> capture() rebuilds the definition from
## that instance and bumps rev -> restamp() reconciles every SIBLING instance to
## the new definition, matching children by def_local_id so per-instance state
## (battery SOC, live output, HA links, 3D bindings, site coords) is preserved.
##
## A GENERIC compound with NO definition_id is a plain one-off group (SketchUp
## "group"); make_unique() converts an instance into one.
##
## All operations are pure model mutations; the view wraps a capture+restamp
## cycle in a re-entrancy guard so the resulting `changed` emissions don't loop.

## specs keys that are per-instance and must NEVER be baked into a definition or
## overwritten on restamp (superset of the view's processor-sync list). Anything
## ending in "_tag" is also treated as instance identity (see is_instance_only).
const INSTANCE_ONLY_SPEC_KEYS: Array[String] = [
	"graph_automations",
	"scene_device_path", "device_path", "ha_live", "ha_entity", "ha_entity_id",
	"model_id", "bound_prop_id",
	"card_preview_yaw_deg", "card_preview_pitch_deg", "card_preview_dist_mult",
	"graph_placeholder", "ibc_tank_link",
	"level", "soc", "current_output_kw", "inflow_rate", "outflow_rate",
	"destroyed", "node_state", "node_state_reason", "node_state_kinds", "deficit_qty",
	"live_capture_lph", "live_capture_rate",
	"sunlight_factor", "source", "site_x_m", "site_z_m",
	"pop_state", "site_projects", "starved_kinds", "is_starved",
	"pop_present", "pop_morale", "pop_collapse_risk",
]

const _MAX_DEPTH := 32


static func is_instance_only(key: String) -> bool:
	return INSTANCE_ONLY_SPEC_KEYS.has(key) or key.ends_with("_tag")


static func is_instance(item: Dictionary) -> bool:
	return str(item.get("type", "")) == "compound" \
		and not str((item.get("specs", {}) as Dictionary).get("definition_id", "")).is_empty()


static func definition_id_of(item: Dictionary) -> String:
	return str((item.get("specs", {}) as Dictionary).get("definition_id", ""))


# ---------------------------------------------------------------------------
# Definition authoring helpers
# ---------------------------------------------------------------------------

static func new_definition_id() -> String:
	return "cdef_%d_%d" % [Time.get_ticks_usec(), randi() % 100000]


## Make an empty definition dict with a fresh id.
static func make_definition(name: String, icon := "🧩") -> Dictionary:
	return {
		"id": new_definition_id(),
		"name": name,
		"icon": icon,
		"rev": 1,
		"subgraph": {"items": [], "connections": [], "exposed_ports": []},
	}


# ---------------------------------------------------------------------------
# Realize — stamp a definition into a fresh instance (recursive for nested defs)
# ---------------------------------------------------------------------------

## Create a compound INSTANCE of `def_id` in `scope_id` at graph position `pos`.
## Nested definition references realize their own sub-instances. Returns the new
## compound id ("" on failure). `identity` merges instance-only specs onto the
## top compound (e.g. {source, starshade_tag}) — carried, never propagated.
static func realize(model: GraphModel, def_id: String, scope_id: String,
		pos: Vector2, identity: Dictionary = {}, depth: int = 0) -> String:
	if model == null or depth > _MAX_DEPTH:
		return ""
	var def := model.get_definition(def_id)
	if def.is_empty():
		return ""
	var sub: Dictionary = def.get("subgraph", {}) as Dictionary
	var comp_id := model.generate_item_id()
	var child_scope := "scope_%s" % comp_id
	var specs: Dictionary = {
		"name": str(def.get("name", "Component")),
		"compound_kind": "",
		"definition_id": def_id,
		"definition_rev": int(def.get("rev", 1)),
		"exposed_ports": [],
		"child_count": (sub.get("items", []) as Array).size(),
	}
	# Definition-level top-compound specs (e.g. a `model_id` banner image, `summary`).
	# These are structural presentation carried onto every instance; instance-only
	# keys inside are still honoured (they simply won't be captured back).
	var top_specs: Dictionary = def.get("specs", {}) as Dictionary
	for k in top_specs.keys():
		specs[k] = top_specs[k]
	for k in identity.keys():
		specs[k] = identity[k]
	model.add_item({
		"id": comp_id, "type": "compound",
		"x": pos.x, "y": pos.y,
		"width": float(def.get("width", 200.0)),
		"height": float(def.get("height", 132.0)),
		"scope_id": scope_id, "child_scope_id": child_scope,
		"handles": [], "specs": specs, "is_virtual": false,
	})
	model.ensure_scope(child_scope, scope_id, comp_id, str(def.get("name", "Component")))
	_realize_subgraph(model, sub, child_scope, comp_id, depth)
	return comp_id


## Stamp a subgraph template's items/connections/exposed_ports into `child_scope`
## under `comp_id`. Recurses for template items that reference a nested def.
static func _realize_subgraph(model: GraphModel, sub: Dictionary,
		child_scope: String, comp_id: String, depth: int) -> void:
	var id_map: Dictionary = {}   # local_id -> realized item id
	for it_v in (sub.get("items", []) as Array):
		var t := it_v as Dictionary
		var local_id := str(t.get("local_id", ""))
		var nested_def := str(t.get("definition_id", ""))
		var dx := float(t.get("dx", 0.0))
		var dy := float(t.get("dy", 0.0))
		if not nested_def.is_empty():
			# Nested component reference -> realize a sub-instance.
			var nid := realize(model, nested_def, child_scope, Vector2(dx, dy),
					t.get("identity", {}) as Dictionary, depth + 1)
			if not nid.is_empty():
				model.update_item(nid, {"parent_compound_id": comp_id})
				var ns: Dictionary = (model.get_item(nid).get("specs", {}) as Dictionary).duplicate(true)
				ns["def_local_id"] = local_id
				model.update_item(nid, {"specs": ns})
				id_map[local_id] = nid
			continue
		var itype := str(t.get("type", "appliance"))
		var new_id := model.generate_item_id()
		id_map[local_id] = new_id
		var ispecs: Dictionary = (t.get("specs", {}) as Dictionary).duplicate(true)
		ispecs["def_local_id"] = local_id
		var dims := ComponentPresets.spawn_dimensions({"type": itype})
		model.add_item({
			"id": new_id, "type": itype,
			"x": dx, "y": dy, "width": dims.x, "height": dims.y,
			"scope_id": child_scope, "parent_compound_id": comp_id,
			"specs": ispecs, "is_virtual": false,
		})
		if itype == "processor":
			ResourceKinds.new().migrate_processor_specs(ispecs)
			model.update_item(new_id, {"specs": ispecs})
	for c_v in (sub.get("connections", []) as Array):
		var c := c_v as Dictionary
		var s_id := str(id_map.get(str(c.get("source", "")), ""))
		var t_id := str(id_map.get(str(c.get("target", "")), ""))
		if s_id.is_empty() or t_id.is_empty():
			continue
		model.add_connection({
			"scope_id": child_scope,
			"polarity": c.get("polarity", "ac"),
			"resource_type": c.get("resource_type", ""),
			"source_item_id": s_id, "source_handle_id": str(c.get("source_handle", "")),
			"target_item_id": t_id, "target_handle_id": str(c.get("target_handle", "")),
			"line_style": "bezier", "curve_tension": 1.0, "corner_radius": 28.0,
		})
	_apply_exposed_ports(model, comp_id, sub.get("exposed_ports", []) as Array, id_map)


## Build the compound's exposed_ports + handles from a template's exposed_ports
## (local ids resolved via `id_map`). Faces carry through from the template
## and layout goes through GraphNesting.layout_exposed_handles — the SAME
## face-aware distribution the inspector's promotion path uses (for face-less
## ports it degrades to exactly the old top-in/bottom-out spread), so a
## user-pinned face survives realize/restamp instead of being re-piled onto
## the default edges.
static func _apply_exposed_ports(model: GraphModel, comp_id: String,
		tpl_eps: Array, id_map: Dictionary) -> void:
	var eps: Array = []
	var handles: Array = []
	for ep_v in tpl_eps:
		var ep := ep_v as Dictionary
		var child_id := str(id_map.get(str(ep.get("child", "")), ""))
		if child_id.is_empty():
			continue
		var hid := str(ep.get("handle_id", ""))
		var direction := str(ep.get("direction", "in"))
		var pol := str(ep.get("polarity", "ac"))
		var entry := {
			"handle_id": hid, "child_item_id": child_id,
			"child_handle_id": str(ep.get("child_handle", "")),
			"polarity": pol, "kind": str(ep.get("kind", "")),
			"label": str(ep.get("label", "")), "direction": direction,
		}
		var face := str(ep.get("face", ""))
		if face in GraphNesting.PORT_FACES:
			entry["face"] = face
		eps.append(entry)
		handles.append({"id": hid, "polarity": pol, "direction": direction,
			"rx": 0.5, "ry": 0.0, "resource_kind": str(ep.get("kind", ""))})
	var item := model.get_item(comp_id)
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["exposed_ports"] = eps
	var in_n := 0
	var out_n := 0
	for h_v in handles:
		if str((h_v as Dictionary).get("direction", "in")) == "out":
			out_n += 1
		else:
			in_n += 1
	specs["port_in_count"] = in_n
	specs["port_out_count"] = out_n
	var patched := item.duplicate(true)
	patched["specs"] = specs
	patched["handles"] = handles
	model.update_item(comp_id, {"specs": specs,
		"handles": GraphNesting.layout_exposed_handles(patched)})


static func _distribute_handles(handles: Array) -> void:
	var ins: Array = []
	var outs: Array = []
	for h_v in handles:
		var h := h_v as Dictionary
		if str(h.get("direction", "in")) == "out":
			outs.append(h)
		else:
			ins.append(h)
	# Top-to-bottom flow (matches base-graph nodes): inputs across the TOP edge
	# (ry=0), outputs across the BOTTOM edge (ry=1), spread evenly in x.
	for arr_v in [ins, outs]:
		var arr := arr_v as Array
		var n := arr.size()
		for i in n:
			var h := arr[i] as Dictionary
			h["ry"] = 1.0 if str(h.get("direction", "in")) == "out" else 0.0
			h["rx"] = clampf(float(i + 1) / float(n + 1), 0.08, 0.92)


# ---------------------------------------------------------------------------
# Capture — rebuild a definition from a live instance's interior
# ---------------------------------------------------------------------------

## Recapture `instance_id`'s child subgraph into its definition and bump rev.
## Assigns a stable def_local_id to any child that lacks one. Strips per-instance
## state so the definition stays structural. Returns the definition id ("" = no-op).
static func capture(model: GraphModel, instance_id: String) -> String:
	if model == null:
		return ""
	var inst := model.get_item(instance_id)
	if not is_instance(inst):
		return ""
	var def_id := definition_id_of(inst)
	var def := model.get_definition(def_id)
	if def.is_empty():
		return ""
	var child_scope := str(inst.get("child_scope_id", ""))
	var kids: Array = model.get_items_in_scope(child_scope)
	var local_of: Dictionary = {}   # item_id -> local_id
	var slot := 0
	for k_v in kids:
		var k := k_v as Dictionary
		var kid_id := str(k.get("id", ""))
		var lid := str((k.get("specs", {}) as Dictionary).get("def_local_id", ""))
		if lid.is_empty():
			lid = "slot_%d" % slot
			slot += 1
			var ks: Dictionary = (k.get("specs", {}) as Dictionary).duplicate(true)
			ks["def_local_id"] = lid
			model.update_item(kid_id, {"specs": ks})
		local_of[kid_id] = lid
	var tpl_items: Array = []
	for k_v in kids:
		var k := k_v as Dictionary
		var kid_id := str(k.get("id", ""))
		var t: Dictionary = {
			"local_id": local_of[kid_id],
			"type": str(k.get("type", "")),
			"dx": float(k.get("x", 0.0)),
			"dy": float(k.get("y", 0.0)),
			"specs": _strip_instance_specs(k.get("specs", {}) as Dictionary),
		}
		if is_instance(k):
			# Nested component: store the reference; its own definition owns kids.
			t["definition_id"] = definition_id_of(k)
		tpl_items.append(t)
	var tpl_conns: Array = []
	for c_v in model.get_connections_in_scope(child_scope):
		var c := c_v as Dictionary
		var s := str(local_of.get(str(c.get("source_item_id", "")), ""))
		var t2 := str(local_of.get(str(c.get("target_item_id", "")), ""))
		if s.is_empty() or t2.is_empty():
			continue
		tpl_conns.append({
			"source": s, "source_handle": str(c.get("source_handle_id", "")),
			"target": t2, "target_handle": str(c.get("target_handle_id", "")),
			"polarity": c.get("polarity", "ac"),
			"resource_type": c.get("resource_type", ""),
		})
	var tpl_eps: Array = []
	for ep_v in ((inst.get("specs", {}) as Dictionary).get("exposed_ports", []) as Array):
		var ep := ep_v as Dictionary
		var child_local := str(local_of.get(str(ep.get("child_item_id", "")), ""))
		if child_local.is_empty():
			continue
		var tpl_ep := {
			"handle_id": str(ep.get("handle_id", "")), "child": child_local,
			"child_handle": str(ep.get("child_handle_id", "")),
			"direction": str(ep.get("direction", "in")),
			"polarity": str(ep.get("polarity", "ac")),
			"kind": str(ep.get("kind", "")), "label": str(ep.get("label", "")),
		}
		# A user-pinned face is part of the boundary's look — dropping it here
		# meant every realize/restamp shuffled the ports back to the default
		# edges.
		var ep_face := str(ep.get("face", ""))
		if ep_face in GraphNesting.PORT_FACES:
			tpl_ep["face"] = ep_face
		tpl_eps.append(tpl_ep)
	def["subgraph"] = {"items": tpl_items, "connections": tpl_conns, "exposed_ports": tpl_eps}
	def["rev"] = int(def.get("rev", 1)) + 1
	model.put_definition(def)
	# Stamp the source instance's rev so it isn't seen as stale.
	var ispecs: Dictionary = (model.get_item(instance_id).get("specs", {}) as Dictionary).duplicate(true)
	ispecs["definition_rev"] = int(def["rev"])
	model.update_item(instance_id, {"specs": ispecs})
	return def_id


static func _strip_instance_specs(specs: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in specs.keys():
		var key := str(k)
		if key == "def_local_id":
			continue
		if is_instance_only(key):
			continue
		out[key] = specs[k]
	return out


# ---------------------------------------------------------------------------
# Restamp — reconcile one instance to its (possibly changed) definition
# ---------------------------------------------------------------------------

## Reconcile `instance_id`'s interior to match its definition: match children by
## def_local_id (preserving their per-instance specs), add missing, delete
## removed, rewire interior, refresh exposed_ports/handles. External wires on the
## instance survive because handle ids are definition-stable. Recurses depth-guarded.
static func restamp(model: GraphModel, instance_id: String, depth: int = 0) -> void:
	if model == null or depth > _MAX_DEPTH:
		return
	var inst := model.get_item(instance_id)
	if not is_instance(inst):
		return
	var def := model.get_definition(definition_id_of(inst))
	if def.is_empty():
		return
	var sub: Dictionary = def.get("subgraph", {}) as Dictionary
	var child_scope := str(inst.get("child_scope_id", ""))
	if child_scope.is_empty():
		return
	# Index existing children by def_local_id.
	var existing: Dictionary = {}   # local_id -> item dict
	for k_v in model.get_items_in_scope(child_scope):
		var k := k_v as Dictionary
		var lid := str((k.get("specs", {}) as Dictionary).get("def_local_id", ""))
		if not lid.is_empty():
			existing[lid] = k
	var id_map: Dictionary = {}     # local_id -> realized id (new or kept)
	var keep_ids: Dictionary = {}   # item_id -> true
	for it_v in (sub.get("items", []) as Array):
		var t := it_v as Dictionary
		var local_id := str(t.get("local_id", ""))
		var nested_def := str(t.get("definition_id", ""))
		var dx := float(t.get("dx", 0.0))
		var dy := float(t.get("dy", 0.0))
		if existing.has(local_id):
			var cur := existing[local_id] as Dictionary
			var cur_id := str(cur.get("id", ""))
			id_map[local_id] = cur_id
			keep_ids[cur_id] = true
			if nested_def.is_empty():
				# Leaf: merge template structural specs, keep per-instance state.
				var merged: Dictionary = (t.get("specs", {}) as Dictionary).duplicate(true)
				var cur_specs := cur.get("specs", {}) as Dictionary
				for ck in cur_specs.keys():
					if is_instance_only(str(ck)):
						merged[ck] = cur_specs[ck]
				merged["def_local_id"] = local_id
				model.update_item(cur_id, {"x": dx, "y": dy, "specs": merged})
			else:
				# Nested instance kept in place; its own definition drives its interior.
				model.update_item(cur_id, {"x": dx, "y": dy})
			continue
		# New slot -> create.
		if not nested_def.is_empty():
			var nid := realize(model, nested_def, child_scope, Vector2(dx, dy),
					{}, depth + 1)
			if not nid.is_empty():
				var ns: Dictionary = (model.get_item(nid).get("specs", {}) as Dictionary).duplicate(true)
				ns["def_local_id"] = local_id
				model.update_item(nid, {"specs": ns, "parent_compound_id": instance_id})
				id_map[local_id] = nid
				keep_ids[nid] = true
			continue
		var itype := str(t.get("type", "appliance"))
		var new_id := model.generate_item_id()
		var ispecs: Dictionary = (t.get("specs", {}) as Dictionary).duplicate(true)
		ispecs["def_local_id"] = local_id
		var dims := ComponentPresets.spawn_dimensions({"type": itype})
		model.add_item({
			"id": new_id, "type": itype, "x": dx, "y": dy,
			"width": dims.x, "height": dims.y,
			"scope_id": child_scope, "parent_compound_id": instance_id,
			"specs": ispecs, "is_virtual": false,
		})
		if itype == "processor":
			ResourceKinds.new().migrate_processor_specs(ispecs)
			model.update_item(new_id, {"specs": ispecs})
		id_map[local_id] = new_id
		keep_ids[new_id] = true
	# Delete children no longer in the definition (cascade for nested instances).
	for k_v in model.get_items_in_scope(child_scope):
		var k := k_v as Dictionary
		var kid_id := str(k.get("id", ""))
		if not keep_ids.has(kid_id):
			model.remove_item(kid_id)
	# Rebuild interior connections from the template.
	for c_v in model.get_connections_in_scope(child_scope):
		model.remove_connection(str((c_v as Dictionary).get("id", "")))
	for c_v in (sub.get("connections", []) as Array):
		var c := c_v as Dictionary
		var s_id := str(id_map.get(str(c.get("source", "")), ""))
		var t_id := str(id_map.get(str(c.get("target", "")), ""))
		if s_id.is_empty() or t_id.is_empty():
			continue
		model.add_connection({
			"scope_id": child_scope,
			"polarity": c.get("polarity", "ac"),
			"resource_type": c.get("resource_type", ""),
			"source_item_id": s_id, "source_handle_id": str(c.get("source_handle", "")),
			"target_item_id": t_id, "target_handle_id": str(c.get("target_handle", "")),
			"line_style": "bezier", "curve_tension": 1.0, "corner_radius": 28.0,
		})
	# Refresh exposed_ports/handles; drop external wires on removed handles.
	_apply_exposed_ports(model, instance_id, sub.get("exposed_ports", []) as Array, id_map)
	_prune_dangling_external_wires(model, instance_id)
	var ispecs2: Dictionary = (model.get_item(instance_id).get("specs", {}) as Dictionary).duplicate(true)
	ispecs2["definition_rev"] = int(def.get("rev", 1))
	model.update_item(instance_id, {"specs": ispecs2})


## Remove external connections that reference a compound handle id which no longer
## exists after an exposed_ports refresh.
static func _prune_dangling_external_wires(model: GraphModel, compound_id: String) -> void:
	var valid: Dictionary = {}
	for h_v in (model.get_item(compound_id).get("handles", []) as Array):
		valid[str((h_v as Dictionary).get("id", ""))] = true
	for c_v in model.connections_for_item(compound_id):
		var c := c_v as Dictionary
		var hit := ""
		if str(c.get("source_item_id", "")) == compound_id:
			hit = str(c.get("source_handle_id", ""))
		elif str(c.get("target_item_id", "")) == compound_id:
			hit = str(c.get("target_handle_id", ""))
		if not hit.is_empty() and not valid.has(hit):
			model.remove_connection(str(c.get("id", "")))


# ---------------------------------------------------------------------------
# Make unique — detach an instance into a plain one-off group
# ---------------------------------------------------------------------------

## Break `instance_id`'s link to its definition: it becomes a plain generic
## compound (edits no longer propagate to/from siblings). Children keep their
## structure; def_local_id tags are cleared. Prunes the definition if now unused.
static func make_unique(model: GraphModel, instance_id: String) -> void:
	if model == null:
		return
	var inst := model.get_item(instance_id)
	if not is_instance(inst):
		return
	var def_id := definition_id_of(inst)
	var specs: Dictionary = (inst.get("specs", {}) as Dictionary).duplicate(true)
	specs.erase("definition_id")
	specs.erase("definition_rev")
	model.update_item(instance_id, {"specs": specs})
	var child_scope := str(inst.get("child_scope_id", ""))
	for k_v in model.get_items_in_scope(child_scope):
		var k := k_v as Dictionary
		if (k.get("specs", {}) as Dictionary).has("def_local_id"):
			var ks: Dictionary = (k.get("specs", {}) as Dictionary).duplicate(true)
			ks.erase("def_local_id")
			model.update_item(str(k.get("id", "")), {"specs": ks})
	model.remove_definition_if_unused(def_id)


# ---------------------------------------------------------------------------
# Built-in definition healing — additive exposed-port upgrades for old saves
# ---------------------------------------------------------------------------

## When a BUILT-IN definition's shipped exposed-port set grows (e.g. starshade
## rev 2 added the battery DC terminals), saved graphs keep serving their own
## older copy of the definition — new StarShades get the ports, placed ones
## never do. This ADDITIVELY merges the missing shipped entries into the
## stored definition and appends the matching promoted port + handle to every
## live instance, matching children by def_local_id. Deliberately NOT a
## rev-forced restamp: restamp rebuilds the whole interior and a save's array
## definition may be customized (panel count/watts) — appending ports touches
## nothing else. Idempotent: a second run adds nothing. Returns the number of
## instances that gained ports.
static func heal_builtin_exposed_ports(model: GraphModel) -> int:
	if model == null:
		return 0
	var healed := 0
	for def_id_v in model.definitions.keys():
		var def_id := str(def_id_v)
		var shipped := ComponentPresets.builtin_definition(def_id)
		if shipped.is_empty():
			continue
		var shipped_eps: Array = ((shipped.get("subgraph", {}) as Dictionary)
			.get("exposed_ports", []) as Array)
		var stored: Dictionary = model.get_definition(def_id)
		var sub: Dictionary = stored.get("subgraph", {}) as Dictionary
		var stored_eps: Array = (sub.get("exposed_ports", []) as Array).duplicate(true)
		var have: Dictionary = {}
		for ep_v in stored_eps:
			have[str((ep_v as Dictionary).get("handle_id", ""))] = true
		var added: Array = []
		for ep_v in shipped_eps:
			var ep := ep_v as Dictionary
			if not have.has(str(ep.get("handle_id", ""))):
				stored_eps.append(ep.duplicate(true))
				added.append(ep.duplicate(true))
		if added.is_empty():
			continue
		stored = stored.duplicate(true)
		sub = sub.duplicate(true)
		sub["exposed_ports"] = stored_eps
		stored["subgraph"] = sub
		model.put_definition(stored)
		for inst_v in model.instances_of_definition(def_id):
			if _heal_instance_ports(model, inst_v as Dictionary, added):
				healed += 1
	return healed


## Append `tpl_added` template exposed-port entries to one live instance,
## resolving each entry's `child` local id through the children's
## def_local_id tags. Skips entries whose child is missing or whose handle_id
## already exists on the instance. Returns true when anything was added.
static func _heal_instance_ports(model: GraphModel, inst: Dictionary,
		tpl_added: Array) -> bool:
	var inst_id := str(inst.get("id", ""))
	var child_scope := str(inst.get("child_scope_id", ""))
	if inst_id.is_empty() or child_scope.is_empty():
		return false
	var child_by_local: Dictionary = {}
	for k_v in model.get_items_in_scope(child_scope):
		var k := k_v as Dictionary
		var lid := str((k.get("specs", {}) as Dictionary).get("def_local_id", ""))
		if not lid.is_empty():
			child_by_local[lid] = str(k.get("id", ""))
	var specs: Dictionary = (inst.get("specs", {}) as Dictionary).duplicate(true)
	var eps: Array = (specs.get("exposed_ports", []) as Array).duplicate(true)
	var handles: Array = (inst.get("handles", []) as Array).duplicate(true)
	var have: Dictionary = {}
	for ep_v in eps:
		have[str((ep_v as Dictionary).get("handle_id", ""))] = true
	var changed := false
	for ep_v in tpl_added:
		var ep := ep_v as Dictionary
		var hid := str(ep.get("handle_id", ""))
		var child_id := str(child_by_local.get(str(ep.get("child", "")), ""))
		if hid.is_empty() or child_id.is_empty() or have.has(hid):
			continue
		var direction := str(ep.get("direction", "in"))
		var pol := str(ep.get("polarity", "ac"))
		var entry := {
			"handle_id": hid, "child_item_id": child_id,
			"child_handle_id": str(ep.get("child_handle", "")),
			"polarity": pol, "kind": str(ep.get("kind", "")),
			"label": str(ep.get("label", "")), "direction": direction,
		}
		var face := str(ep.get("face", ""))
		if face in GraphNesting.PORT_FACES:
			entry["face"] = face
		eps.append(entry)
		handles.append({"id": hid, "polarity": pol, "direction": direction,
			"rx": 0.5, "ry": 0.0, "resource_kind": str(ep.get("kind", ""))})
		have[hid] = true
		changed = true
	if not changed:
		return false
	specs["exposed_ports"] = eps
	var in_n := 0
	var out_n := 0
	for h_v in handles:
		if str((h_v as Dictionary).get("direction", "in")) == "out":
			out_n += 1
		else:
			in_n += 1
	specs["port_in_count"] = in_n
	specs["port_out_count"] = out_n
	var patched := inst.duplicate(true)
	patched["specs"] = specs
	patched["handles"] = handles
	model.update_item(inst_id, {"specs": specs,
		"handles": GraphNesting.layout_exposed_handles(patched)})
	return true
