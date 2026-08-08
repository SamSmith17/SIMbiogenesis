class_name PackTree
extends RefCounted
## Nested packing ("boxes within boxes") — PACKING_PLAN.md Phase 3.
##
## A pack unit is either a LEAF or a CONTAINER, mirroring the graph's
## super-node nesting:
##   leaf:      {label, spec: <PackedSpec dict>, qty}
##   container: {label, container_id: <ContainerCatalog id>, contents: [units], qty}
##
## Solving is INNERMOST-FIRST: each container unit's contents are solved into
## its interior, and what the parent scope sees is the container's OUTER
## envelope (exterior dims + tare + contents mass) as one leaf. Contents that
## don't fit a sub-container ESCAPE to the parent scope as loose items — the
## realistic behaviour: what doesn't fit in the tote rides loose in the truck,
## it doesn't vanish and it doesn't fail the whole load.
##
## Container units with qty > 1 are identical instances: contents are solved
## ONCE and the outer unit (and any escapes) replicate per instance.
## Trees are literal nested arrays, so cycles are structurally impossible;
## MAX_DEPTH guards pathological input (and PackDefs guards def-reference
## cycles at realize time).

const MAX_DEPTH := 8


## Flatten a unit tree into top-level solver items, solving sub-containers
## innermost-first. Returns:
##   {items: [solver items], scopes: [{label, container_id, qty, result}],
##    escaped: [{label, from}], depth_exceeded: bool}
static func flatten(units: Array, depth: int = 0) -> Dictionary:
	var out := {"items": [], "scopes": [], "escaped": [], "depth_exceeded": false}
	if depth > MAX_DEPTH:
		out["depth_exceeded"] = true
		return out
	for unit in units:
		if not (unit is Dictionary):
			continue
		var u := unit as Dictionary
		var qty := maxi(int(u.get("qty", 1)), 1)
		if u.has("container_id"):
			_flatten_container(u, qty, depth, out)
		else:
			var spec: Dictionary = u.get("spec", {})
			if spec.is_empty():
				continue
			var units_n := qty * maxi(int(spec.get("count", 1)), 1)
			for _i in units_n:
				var item := spec.duplicate()
				item["label"] = str(u.get("label", "?"))
				(out["items"] as Array).append(item)
	return out


static func _flatten_container(u: Dictionary, qty: int, depth: int, out: Dictionary) -> void:
	var cid := str(u.get("container_id", ""))
	var entry := ContainerCatalog.find(cid)
	var label := str(u.get("label", entry.get("label", cid)))
	if entry.is_empty():
		return
	var inner := flatten(u.get("contents", []) as Array, depth + 1)
	if bool(inner["depth_exceeded"]):
		out["depth_exceeded"] = true
	# Solve this container's own scope once (instances are identical).
	var res := PackSolver.solve(entry, inner["items"])
	(out["scopes"] as Array).append({"label": label, "container_id": cid,
		"qty": qty, "result": res})
	(out["scopes"] as Array).append_array(inner["scopes"])
	(out["escaped"] as Array).append_array(inner["escaped"])
	# The outer envelope the parent packs: exterior + tare + placed contents.
	var outer := ContainerCatalog.packed_spec_for(cid)
	if outer.is_empty():
		# No exterior recorded (shouldn't happen for subs) — approximate with
		# the interior as a rigid box so the unit still occupies space.
		var i: Dictionary = entry.get("interior", {})
		outer = PackedSpec.normalize({"w_m": float(i.get("l_m", 0.5)),
			"d_m": float(i.get("w_m", 0.5)), "h_m": float(i.get("h_m", 0.5)),
			"form": "container", "source": "estimated", "this_side_up": true})
	if PackedSpec.has_mass(outer):
		outer["mass_kg"] = float(outer["mass_kg"]) + float(res["total_mass_kg"])
	for _i in qty:
		var item := outer.duplicate()
		item["label"] = label
		(out["items"] as Array).append(item)
		# Contents that didn't fit ride loose in the PARENT scope.
		for ov in (res["overflow"] as Array):
			var esc_label := str((ov as Dictionary).get("label", "?"))
			var src: Dictionary = _find_content_spec(u.get("contents", []) as Array, esc_label)
			if src.is_empty():
				continue
			var esc := src.duplicate()
			esc["label"] = "%s (loose from %s)" % [esc_label, label]
			(out["items"] as Array).append(esc)
			(out["escaped"] as Array).append({"label": esc_label, "from": label})


## Recover the spec of an overflowed content line by label (first match).
static func _find_content_spec(contents: Array, label: String) -> Dictionary:
	for unit in contents:
		if not (unit is Dictionary):
			continue
		var u := unit as Dictionary
		if str(u.get("label", "")) != label:
			continue
		if u.has("container_id"):
			return ContainerCatalog.packed_spec_for(str(u.get("container_id", "")))
		return (u.get("spec", {}) as Dictionary).duplicate()
	return {}


## Solve a nested unit tree into a top-level container. Returns the
## PackSolver result plus "scopes" (per-sub-container results, outermost
## first) and "escaped" (contents that fell out to an ancestor scope).
static func solve(container: Dictionary, units: Array) -> Dictionary:
	var flat := flatten(units)
	var res := PackSolver.solve(container, flat["items"])
	res["scopes"] = flat["scopes"]
	res["escaped"] = flat["escaped"]
	res["depth_exceeded"] = flat["depth_exceeded"]
	return res
