class_name ChainWiring
extends RefCounted

## How a chain of library presets is placed and wired into a scope (resource
## composition plan Phases 6–7). Pure: `plan` says what WOULD be added (the
## loop closer's ghosts draw exactly this); `apply` adds it to the model.
##
## Each step's input of kind k comes from, in order:
##   the ANCHOR's port, when k is the open loop and the plan takes it away
##     (the machine the player asked from: a toilet block's urine output);
##   the scope's tank of k (a camp's own store wins over one added later);
##   the nearest earlier step that makes k.
## Each step's output of kind k goes, on a plan that supplies the open kind,
## to the anchor's input of k (the last step making it), else to the scope's
## tank of k. A kind with neither is wired by the step that takes it (the
## input pass) or left open. Plants use their fixed ports (water_in,
## nutrients_in, biomass_out, residue_out).
##
## A plan: {items: [{id: "new:<i>", type, label, x, y, width, height, specs}],
##          conns: [{source, source_handle, target, target_handle, resource_type}]}
## ids "new:<i>" are the items to add; any other id is already in the scope.
## An item with `gap` true is a placeholder (a step no machine does yet):
## drawn as a ghost, never added, and its wires are dropped by apply.

const NEW := "new:"
## How far a placed card keeps from another (graph px).
const CLEAR_PX := 28.0
const MAX_PUSH := 60


## labels: the presets in flow order, each a label, {label, scale} (the
## preset sized to that multiple of its listed rates: sized()) or a
## preset-shaped dict. opts:
##   origin: Vector2 (graph px, the first card's top-left)
##   step: Vector2 (from one card to the next)
##   push: Vector2 (how a card that would overlap moves; zero = never)
##   anchor: {id, kind, side "sink"|"source", handle} (optional)
##   terminal: {kind: store label} (default LoopPlanner.TERMINAL): an output
##     of such a kind that no tank and no later step takes gets that store
##     added after the chain (brine into a salt pan)
static func plan(model, scope: String, labels: Array, opts: Dictionary = {}) -> Dictionary:
	var out := {"items": [], "conns": []}
	if model == null or labels.is_empty():
		return out
	var tanks := scope_tanks(model, scope)
	var origin: Vector2 = opts.get("origin", Vector2.ZERO)
	var step: Vector2 = opts.get("step", Vector2(240.0, 0.0))
	var push: Vector2 = opts.get("push", Vector2.ZERO)
	var anchor: Dictionary = opts.get("anchor", {})
	var rects: Array = []
	if push != Vector2.ZERO:
		for it in model.get_items_in_scope(scope):
			var d: Dictionary = it
			rects.append(Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)),
				float(d.get("width", 120.0)), float(d.get("height", 90.0))).grow(CLEAR_PX))
	var placed: Array = []
	for i in labels.size():
		# A label, or a preset-shaped dict ({type, label, specs, gap}: a
		# placeholder the loop closer draws for a step with no machine).
		var preset: Dictionary = {}
		if labels[i] is Dictionary and (labels[i] as Dictionary).has("type"):
			preset = labels[i]
		elif labels[i] is Dictionary:
			# {label, scale}: the preset sized to the plan's step.
			preset = sized(ComponentPresets.find_preset_by_label(str(labels[i]["label"])),
				float((labels[i] as Dictionary).get("scale", 1.0)))
		else:
			preset = ComponentPresets.find_preset_by_label(str(labels[i]))
		if preset.is_empty():
			continue
		var w := float(preset.get("width", 140.0))
		var h := float(preset.get("height", 130.0))
		var pos := origin + step * float(placed.size())
		if push != Vector2.ZERO:
			var tries := 0
			while tries < MAX_PUSH and _hits(rects, Rect2(pos, Vector2(w, h))):
				pos += push
				tries += 1
			rects.append(Rect2(pos, Vector2(w, h)).grow(CLEAR_PX))
		var id := NEW + str(placed.size())
		var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
		var ty := str(preset.get("type", "processor"))
		(out["items"] as Array).append({"id": id, "type": ty, "label": str(preset.get("label", "")), "x": pos.x, "y": pos.y,
			"width": w, "height": h, "specs": specs, "gap": bool(preset.get("gap", false))})
		placed.append({"id": id, "ins": ports(ty, specs, true), "outs": ports(ty, specs, false)})
	var a_id := str(anchor.get("id", ""))
	var a_kind := str(anchor.get("kind", ""))
	var a_side := str(anchor.get("side", ""))
	var a_handle := str(anchor.get("handle", ""))
	for n in placed.size():
		var p: Dictionary = placed[n]
		for ip in p["ins"]:
			var k := str(ip[0])
			if not a_id.is_empty() and a_side == "sink" and k == a_kind and n == _first_taker(placed, k):
				_wire(out, a_id, a_handle, str(p["id"]), str(ip[1]), k)
				continue
			if tanks.has(k):
				_wire(out, str(tanks[k]), "output", str(p["id"]), str(ip[1]), k)
				continue
			var from := _maker_before(placed, n, k)
			if not from.is_empty():
				_wire(out, str(from[0]), str(from[1]), str(p["id"]), str(ip[1]), k)
		for op in p["outs"]:
			var k2 := str(op[0])
			if not a_id.is_empty() and a_side == "source" and k2 == a_kind and n == _last_maker(placed, k2):
				_wire(out, str(p["id"]), str(op[1]), a_id, a_handle, k2)
			elif tanks.has(k2):
				_wire(out, str(p["id"]), str(op[1]), str(tanks[k2]), "input", k2)
	# A kind that ends in a store (brine) and has nowhere to go gets one.
	var terminal: Dictionary = opts.get("terminal", LoopPlanner.TERMINAL)
	var stores: Dictionary = {}
	for n2 in placed.size():
		for op2 in (placed[n2] as Dictionary)["outs"]:
			var k3 := str(op2[0])
			if not terminal.has(k3) or tanks.has(k3) or _taken_after(placed, n2, k3):
				continue
			if not stores.has(k3):
				var sp := ComponentPresets.find_preset_by_label(str(terminal[k3]))
				if sp.is_empty():
					continue
				var w2 := float(sp.get("width", 140.0))
				var h2 := float(sp.get("height", 120.0))
				var pos2 := origin + step * float(placed.size() + stores.size())
				if push != Vector2.ZERO:
					var tries2 := 0
					while tries2 < MAX_PUSH and _hits(rects, Rect2(pos2, Vector2(w2, h2))):
						pos2 += push
						tries2 += 1
					rects.append(Rect2(pos2, Vector2(w2, h2)).grow(CLEAR_PX))
				var sid := NEW + str((out["items"] as Array).size())
				(out["items"] as Array).append({"id": sid, "type": str(sp.get("type", "resource")),
					"label": str(terminal[k3]), "x": pos2.x, "y": pos2.y, "width": w2, "height": h2,
					"specs": (sp.get("specs", {}) as Dictionary).duplicate(true), "gap": false, "store": true})
				stores[k3] = sid
			_wire(out, str((placed[n2] as Dictionary)["id"]), str(op2[1]), str(stores[k3]), "input", k3)
	return out


## Add a plan() to the model inside `scope`. Returns the new item ids, in
## the plan's order (an id that could not be added is left out).
static func apply(model, scope: String, chain: Dictionary) -> Array:
	var ids: Array = []
	var map: Dictionary = {}
	if model == null:
		return ids
	for it in chain.get("items", []):
		var d: Dictionary = it
		if bool(d.get("gap", false)):
			continue
		var iid: String = model.generate_item_id()
		map[str(d["id"])] = iid
		model.add_item({"id": iid, "type": str(d["type"]), "scope_id": scope,
			"x": float(d["x"]), "y": float(d["y"]), "width": float(d["width"]),
			"height": float(d["height"]), "specs": (d["specs"] as Dictionary).duplicate(true)})
		ids.append(iid)
	for c in chain.get("conns", []):
		var cd: Dictionary = c
		var s := str(map.get(str(cd["source"]), cd["source"]))
		var t := str(map.get(str(cd["target"]), cd["target"]))
		if s.begins_with(NEW) or t.begins_with(NEW):
			continue
		model.add_connection({"scope_id": scope, "source": s, "source_handle": str(cd["source_handle"]),
			"target": t, "target_handle": str(cd["target_handle"]), "polarity": "resource",
			"resource_type": str(cd["resource_type"])})
	return ids


## A preset built to `scale` times its listed rates: a processor's inputs,
## outputs and watts, a plant's area; the price with them. Within 10 % of 1
## it is left as listed. `unit_scale` on the specs says what was done.
static func sized(preset: Dictionary, scale: float) -> Dictionary:
	if preset.is_empty() or scale <= 0.0 or absf(scale - 1.0) < 0.1:
		return preset
	var p := preset.duplicate(true)
	var sp: Dictionary = p.get("specs", {})
	if str(p.get("type", "")) == "plant":
		if sp.has("area_m2"):
			sp["area_m2"] = float(sp["area_m2"]) * scale
	else:
		for key in ["inputs", "outputs"]:
			for io in sp.get(key, []):
				(io as Dictionary)["rate"] = float((io as Dictionary).get("rate", 0.0)) * scale
		if sp.has("watts"):
			sp["watts"] = float(sp["watts"]) * scale
	if sp.has("cost"):
		sp["cost"] = float(sp["cost"]) * scale
	sp["unit_scale"] = scale
	return p


## {kind: tank id} in a scope; a store CampTemplates made (camp_store) wins
## over a tank the player added later, else the first by id order.
static func scope_tanks(model, scope: String) -> Dictionary:
	var tanks: Dictionary = {}
	var stores: Dictionary = {}
	for it in model.get_items_in_scope(scope):
		var d: Dictionary = it
		if str(d.get("type", "")) != "resource" or bool(d.get("is_ghost", false)):
			continue
		var ds: Dictionary = d.get("specs", {})
		var k := kind(str(ds.get("resource_kind", "")))
		if not tanks.has(k) or bool(ds.get("camp_store", false)) and not stores.has(k):
			tanks[k] = str(d.get("id", ""))
			if bool(ds.get("camp_store", false)):
				stores[k] = true
	return tanks


## [[kind, handle]] of an item's inputs (`ins`) or outputs. A plant's ports
## are fixed: water_in, nutrients_in, and the crop on biomass_out (food for a
## food crop, its residue biomass on residue_out).
static func ports(type: String, specs: Dictionary, ins: bool) -> Array:
	var out: Array = []
	if type == "plant":
		var food := float(specs.get("food_fraction", 0.0)) > 0.0
		if ins:
			out.append(["water", "water_in"])
			out.append(["nutrients", "nutrients_in"])
		else:
			out.append(["food" if food else "biomass", "biomass_out"])
			if food:
				out.append(["biomass", "residue_out"])
		return out
	var list: Array = specs.get("inputs" if ins else "outputs", [])
	for i in list.size():
		out.append([kind(str((list[i] as Dictionary).get("kind", ""))), ("res_in_%d" if ins else "res_out_%d") % i])
	return out


static func kind(k: String) -> String:
	return CompositionCatalog.canonical(ResourceKinds.normalize_kind(k))


static func _hits(rects: Array, r: Rect2) -> bool:
	for q in rects:
		if (q as Rect2).intersects(r):
			return true
	return false


## [item id, handle] of the nearest earlier step that makes `kind`.
static func _maker_before(placed: Array, n: int, k: String) -> Array:
	for m in range(n - 1, -1, -1):
		for op in (placed[m] as Dictionary)["outs"]:
			if str(op[0]) == k:
				return [str((placed[m] as Dictionary)["id"]), str(op[1])]
	return []


static func _taken_after(placed: Array, n: int, k: String) -> bool:
	for m in range(n + 1, placed.size()):
		for ip in (placed[m] as Dictionary)["ins"]:
			if str(ip[0]) == k:
				return true
	return false


static func _first_taker(placed: Array, k: String) -> int:
	for m in placed.size():
		for ip in (placed[m] as Dictionary)["ins"]:
			if str(ip[0]) == k:
				return m
	return -1


static func _last_maker(placed: Array, k: String) -> int:
	for m in range(placed.size() - 1, -1, -1):
		for op in (placed[m] as Dictionary)["outs"]:
			if str(op[0]) == k:
				return m
	return -1


static func _wire(out: Dictionary, s: String, sh: String, t: String, th: String, k: String) -> void:
	(out["conns"] as Array).append({"source": s, "source_handle": sh, "target": t,
		"target_handle": th, "resource_type": k})
