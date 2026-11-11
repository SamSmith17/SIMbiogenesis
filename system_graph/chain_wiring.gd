class_name ChainWiring
extends RefCounted

## How a chain of library presets is placed and wired into a scope (resource
## composition plan Phases 6–8). Pure: `plan` says what WOULD be added (the
## loop closer's ghosts draw exactly this); `apply` adds it to the model.
##
## The flow engine moves things only through TANKS (a machine takes from the
## tank wired to its input and gives to the tank wired to its output; a wire
## from a machine straight to a machine carries nothing). So:
##   a step's input of kind k comes from the scope's tank of k; else, when k
##   is the open loop and the plan takes it away, from the ANCHOR (the
##   machine the player asked from) through a new BUFFER tank of k; else from
##   the nearest earlier step that makes k, through a buffer tank;
##   a step's output of kind k goes, on a plan that supplies the open kind,
##   to the anchor's input through a buffer (the last step making it); else
##   to the scope's tank of k; else to the buffer the next step takes it
##   from; else, for a kind whose usual end is a store (brine), into that
##   store, added; else it is left open.
## Plants use their fixed ports (water_in, nutrients_in, biomass_out,
## residue_out); a tank's are input and output. A machine that draws AC
## power is wired from the scope's controller (acOutput → power_in) when it
## has one; the plan's `unpowered` lists those that could not be.
##
## A plan: {items: [{id: "new:<i>", type, label, x, y, width, height, specs,
##          gap, store, buffer}], conns: [{source, source_handle, target,
##          target_handle, resource_type}]}
## ids "new:<i>" are the items to add; any other id is already in the scope.
## An item with `gap` true is a step no machine does yet: a gap node
## (DesignGap), drawn as a gap and placed as one. Items come in flow order
## and are laid out that way.

const NEW := "new:"
## How far a placed card keeps from another (graph px).
const CLEAR_PX := 28.0
const MAX_PUSH := 60
## The gap between cards along the chain (graph px).
const GAP_PX := 56.0
const BUFFER_SIZE := Vector2(120.0, 120.0)
## A buffer holds this many hours of the flow through it (at least MIN).
const BUFFER_HOURS := 24.0
const BUFFER_MIN := 50.0


## labels: the presets in flow order, each a label, {label, scale} (the
## preset sized to that multiple of its listed rates: sized()) or a
## preset-shaped dict. opts:
##   origin: Vector2 (graph px, the first card's top-left)
##   step: Vector2 (the direction the chain runs; only its direction is used)
##   push: Vector2 (how a card that would overlap moves; zero = never)
##   anchor: {id, kind, side "sink"|"source", handle} (optional)
##   terminal: {kind: store label} (default LoopPlanner.TERMINAL)
static func plan(model, scope: String, labels: Array, opts: Dictionary = {}) -> Dictionary:
	var out := {"items": [], "conns": []}
	if model == null or labels.is_empty():
		return out
	var tanks := scope_tanks(model, scope)
	var anchor: Dictionary = opts.get("anchor", {})
	var a_id := str(anchor.get("id", ""))
	var a_kind := str(anchor.get("kind", ""))
	var a_side := str(anchor.get("side", ""))
	var a_handle := str(anchor.get("handle", ""))
	# 1. The steps.
	var steps: Array = []
	for i in labels.size():
		var preset := _preset_of(labels[i])
		if preset.is_empty():
			continue
		var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
		var ty := str(preset.get("type", "processor"))
		steps.append({"id": NEW + str(steps.size()), "type": ty, "label": str(preset.get("label", "")),
			"width": float(preset.get("width", 140.0)), "height": float(preset.get("height", 130.0)),
			"specs": specs, "gap": bool(preset.get("gap", false)), "store": false, "buffer": false,
			"ins": ports(ty, specs, true), "outs": ports(ty, specs, false)})
	if steps.is_empty():
		return out
	# 2. Wiring, collecting cards in flow order (buffers before the step
	# they feed, after the step they drain).
	var order: Array = []
	var extra := steps.size()
	var buffers: Dictionary = {}  # "<from id>|<kind>" -> buffer card
	var conns: Array = out["conns"]
	for n in steps.size():
		var p: Dictionary = steps[n]
		for ip in p["ins"]:
			var k := str(ip[0])
			var rate := _rate_of(p, k, true)
			if not a_id.is_empty() and a_side == "sink" and k == a_kind and n == _first_taker(steps, k):
				var b := _buffer(buffers, a_id, a_handle, k, rate, order, conns, extra)
				extra = int(b[1])
				_wire(conns, str(b[0]), "output", str(p["id"]), str(ip[1]), k)
				continue
			if tanks.has(k):
				_wire(conns, str(tanks[k]), "output", str(p["id"]), str(ip[1]), k)
				continue
			var from := _maker_before(steps, n, k)
			if not from.is_empty():
				var b2 := _buffer(buffers, str(from[0]), str(from[1]), k, rate, order, conns, extra)
				extra = int(b2[1])
				_wire(conns, str(b2[0]), "output", str(p["id"]), str(ip[1]), k)
		order.append(p)
		for op in p["outs"]:
			var k2 := str(op[0])
			if not a_id.is_empty() and a_side == "source" and k2 == a_kind and n == _last_maker(steps, k2):
				var b3 := _buffer(buffers, str(p["id"]), str(op[1]), k2, _rate_of(p, k2, false), order, conns, extra)
				extra = int(b3[1])
				_wire(conns, str(b3[0]), "output", a_id, a_handle, k2)
			elif tanks.has(k2):
				_wire(conns, str(p["id"]), str(op[1]), str(tanks[k2]), "input", k2)
	# 3. An output going nowhere gets a store: the engine stops a machine
	# whose (non-optional) output is unwired. The usual store for its kind
	# where there is one (brine into a salt pan), else a tank of that kind
	# holding a week. A plant's residue port is optional and left alone.
	var terminal: Dictionary = opts.get("terminal", LoopPlanner.TERMINAL)
	var stores: Dictionary = {}
	for n2 in steps.size():
		var p2: Dictionary = steps[n2]
		for op2 in p2["outs"]:
			var k3 := str(op2[0])
			if k3.is_empty() or tanks.has(k3) or buffers.has(str(p2["id"]) + "|" + k3) \
					or _taken_after(steps, n2, k3) or _optional_out(p2, str(op2[1])):
				continue
			if not stores.has(k3):
				var card := _store_card(k3, terminal, _rate_of(p2, k3, false), NEW + str(extra))
				if card.is_empty():
					continue
				extra += 1
				order.append(card)
				stores[k3] = str(card["id"])
			_wire(conns, str(p2["id"]), str(op2[1]), str(stores[k3]), "input", k3)
	# 4. Power: an AC machine from the scope's controller.
	var ctrl := scope_ac_source(model, scope)
	var unpowered: Array = []
	for p3 in steps:
		var pd: Dictionary = p3
		if str(pd["type"]) != "processor" or bool(pd.get("gap", false)) or not needs_ac(pd["specs"]):
			continue
		if ctrl.is_empty():
			unpowered.append(str(pd["id"]))
		else:
			conns.append({"source": ctrl, "source_handle": "acOutput", "target": str(pd["id"]),
				"target_handle": "power_in", "resource_type": "electric", "polarity": "ac"})
	out["unpowered"] = unpowered
	# 5. Lay them out along the chain, off the real cards.
	_layout(model, scope, order, opts)
	for c in order:
		var cd: Dictionary = c
		(out["items"] as Array).append({"id": cd["id"], "type": cd["type"], "label": cd["label"],
			"x": cd["x"], "y": cd["y"], "width": cd["width"], "height": cd["height"], "specs": cd["specs"],
			"gap": bool(cd.get("gap", false)), "store": bool(cd.get("store", false)),
			"buffer": bool(cd.get("buffer", false))})
	return out


## A store for `kind`: its usual one (TERMINAL) or a plain tank of a week.
static func _store_card(kind_id: String, terminal: Dictionary, rate: float, id: String) -> Dictionary:
	if terminal.has(kind_id):
		var sp := ComponentPresets.find_preset_by_label(str(terminal[kind_id]))
		if not sp.is_empty():
			return {"id": id, "type": str(sp.get("type", "resource")), "label": str(terminal[kind_id]),
				"width": float(sp.get("width", 140.0)), "height": float(sp.get("height", 120.0)),
				"specs": (sp.get("specs", {}) as Dictionary).duplicate(true),
				"gap": false, "store": true, "buffer": false}
	if not CompositionCatalog.is_material(kind_id):
		return {}
	var unit := str(ResourceKinds.kind_meta(kind_id).get("unit", "kg"))
	var cap := maxf(BUFFER_MIN, ceilf(rate * BUFFER_HOURS * 7.0 / 10.0) * 10.0)
	var nm := "%s store" % ResourceKinds.display_name(kind_id)
	return {"id": id, "type": "resource", "label": nm, "width": BUFFER_SIZE.x, "height": BUFFER_SIZE.y,
		"specs": {"name": nm, "resource_kind": kind_id, "capacity": "%.0f %s" % [cap, unit],
			"capacity_qty": cap, "capacity_unit": unit, "level": 0.0, "cost": 0.0},
		"gap": false, "store": true, "buffer": false}


## An output the engine lets drain on site when unwired (`optional`), or a
## plant's residue port.
static func _optional_out(step: Dictionary, handle: String) -> bool:
	if handle == "residue_out":
		return true
	if not handle.begins_with("res_out_"):
		return false
	var i := int(handle.trim_prefix("res_out_"))
	var outs: Array = (step["specs"] as Dictionary).get("outputs", [])
	return i < outs.size() and bool((outs[i] as Dictionary).get("optional", false))


static func _preset_of(entry: Variant) -> Dictionary:
	if entry is Dictionary and (entry as Dictionary).has("type"):
		return entry
	if entry is Dictionary:
		# {label, scale}: the preset sized to the plan's step.
		return sized(ComponentPresets.find_preset_by_label(str(entry["label"])),
			float((entry as Dictionary).get("scale", 1.0)))
	return ComponentPresets.find_preset_by_label(str(entry))


## The buffer tank that carries `kind` out of (from_id, handle): made once
## per source and kind, appended to `order` where it is first needed.
## Returns [buffer id, next free index].
static func _buffer(buffers: Dictionary, from_id: String, handle: String, kind: String, rate: float,
		order: Array, conns: Array, next: int) -> Array:
	var key := from_id + "|" + kind
	if buffers.has(key):
		return [str(buffers[key]["id"]), next]
	var unit := str(ResourceKinds.kind_meta(kind).get("unit", "L"))
	var cap := maxf(BUFFER_MIN, ceilf(rate * BUFFER_HOURS / 10.0) * 10.0)
	var nm := "%s buffer" % ResourceKinds.display_name(kind)
	var card := {"id": NEW + str(next), "type": "resource", "label": nm,
		"width": BUFFER_SIZE.x, "height": BUFFER_SIZE.y,
		"specs": {"name": nm, "resource_kind": kind, "capacity": "%.0f %s" % [cap, unit],
			"capacity_qty": cap, "capacity_unit": unit, "level": 0.0, "cost": 0.0, "chain_buffer": true},
		"gap": false, "store": false, "buffer": true}
	buffers[key] = card
	order.append(card)
	_wire(conns, from_id, handle, str(card["id"]), "input", kind)
	return [str(card["id"]), next + 1]


## A step's listed rate of `kind` (its first port of it), 0 when not listed.
static func _rate_of(step: Dictionary, want: String, ins: bool) -> float:
	if str(step["type"]) == "plant":
		return 0.0
	for io in (step["specs"] as Dictionary).get("inputs" if ins else "outputs", []):
		if kind(str((io as Dictionary).get("kind", ""))) == want:
			return float((io as Dictionary).get("rate", 0.0))
	return 0.0


static func _layout(model, scope: String, order: Array, opts: Dictionary) -> void:
	var origin: Vector2 = opts.get("origin", Vector2.ZERO)
	var dir: Vector2 = (opts.get("step", Vector2(240.0, 0.0)) as Vector2).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	var push: Vector2 = opts.get("push", Vector2.ZERO)
	var rects: Array = []
	if push != Vector2.ZERO:
		for it in model.get_items_in_scope(scope):
			var d: Dictionary = it
			rects.append(Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)),
				float(d.get("width", 120.0)), float(d.get("height", 90.0))).grow(CLEAR_PX))
	var along := 0.0
	for c in order:
		var cd: Dictionary = c
		var size := Vector2(float(cd["width"]), float(cd["height"]))
		var pos := origin + dir * along
		if push != Vector2.ZERO:
			var tries := 0
			while tries < MAX_PUSH and _hits(rects, Rect2(pos, size)):
				pos += push
				tries += 1
			rects.append(Rect2(pos, size).grow(CLEAR_PX))
		cd["x"] = pos.x
		cd["y"] = pos.y
		along += absf(size.dot(dir)) + GAP_PX


## Add a plan() to the model inside `scope`. Returns the new item ids, in
## the plan's order.
static func apply(model, scope: String, chain: Dictionary) -> Array:
	var ids: Array = []
	var map: Dictionary = {}
	if model == null:
		return ids
	for it in chain.get("items", []):
		var d: Dictionary = it
		var iid: String = model.generate_item_id()
		map[str(d["id"])] = iid
		var sp: Dictionary = (d["specs"] as Dictionary).duplicate(true)
		# A plan is placed to run: its machines start switched on (the
		# library places a machine off until the player turns it on).
		if str(d["type"]) == "processor" and not sp.has("requested_state"):
			sp["requested_state"] = "on"
		model.add_item({"id": iid, "type": str(d["type"]), "scope_id": scope,
			"x": float(d["x"]), "y": float(d["y"]), "width": float(d["width"]),
			"height": float(d["height"]), "specs": sp})
		ids.append(iid)
	for c in chain.get("conns", []):
		var cd: Dictionary = c
		var s := str(map.get(str(cd["source"]), cd["source"]))
		var t := str(map.get(str(cd["target"]), cd["target"]))
		if s.begins_with(NEW) or t.begins_with(NEW):
			continue
		# The model's own keys (the flow engine and the canvas read these).
		var row := {"scope_id": scope, "source_item_id": s,
			"source_handle_id": str(cd["source_handle"]), "target_item_id": t,
			"target_handle_id": str(cd["target_handle"]), "polarity": str(cd.get("polarity", "resource"))}
		if row["polarity"] == "resource":
			row["resource_type"] = str(cd["resource_type"])
		model.add_connection(row)
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


## The flow engine's rule for a machine that runs on the AC bus.
## (ResourceFlowEngine._processor_has_power, line for line).
static func needs_ac(specs: Dictionary) -> bool:
	var watts := float(specs.get("watts", 0.0))
	var es := str(specs.get("energy_source", ""))
	if not specs.has("energy_source") or es == "thermal" or es == "mechanical":
		es = "ac" if (not specs.has("energy_source") and watts > 0.0) else ""
	if es.is_empty() and watts > 0.0:
		es = "ac"
	return es == "ac"


## The scope's AC source: its first controller ("" = none).
static func scope_ac_source(model, scope: String) -> String:
	for it in model.get_items_in_scope(scope):
		var d: Dictionary = it
		if str(d.get("type", "")) == "controller" and not bool(d.get("is_ghost", false)):
			return str(d.get("id", ""))
	return ""


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
## food crop, its residue biomass on residue_out); a tank's are input and
## output.
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
	if type == "resource":
		out.append([kind(str(specs.get("resource_kind", ""))), "input" if ins else "output"])
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
static func _maker_before(steps: Array, n: int, k: String) -> Array:
	for m in range(n - 1, -1, -1):
		for op in (steps[m] as Dictionary)["outs"]:
			if str(op[0]) == k:
				return [str((steps[m] as Dictionary)["id"]), str(op[1])]
	return []


static func _taken_after(steps: Array, n: int, k: String) -> bool:
	for m in range(n + 1, steps.size()):
		for ip in (steps[m] as Dictionary)["ins"]:
			if str(ip[0]) == k:
				return true
	return false


static func _first_taker(steps: Array, k: String) -> int:
	for m in steps.size():
		for ip in (steps[m] as Dictionary)["ins"]:
			if str(ip[0]) == k:
				return m
	return -1


static func _last_maker(steps: Array, k: String) -> int:
	for m in range(steps.size() - 1, -1, -1):
		for op in (steps[m] as Dictionary)["outs"]:
			if str(op[0]) == k:
				return m
	return -1


static func _wire(conns: Array, s: String, sh: String, t: String, th: String, k: String) -> void:
	conns.append({"source": s, "source_handle": sh, "target": t, "target_handle": th, "resource_type": k})
