class_name CampLoopClosure
extends RefCounted

## How CLOSED one camp's loops are, and what would close them — the challenge
## the calculator sets up: having seen how much water, food and firewood a
## camp takes in and how much grey- and blackwater it puts out, grow food,
## reclaim water and process waste inside the camp itself.
##
## Per kind, from the camp's own sub-graph (nominal rates, like CampLedger):
##   an INPUT (water, food, firewood) is closed by what non-habitat machines,
##     plants and catchments inside the camp PRODUCE of it, over what its
##     people need;
##   a WASTE (greywater, blackwater) is closed by what machines inside the
##     camp CONSUME of it, over what its people make.
## Each is 0..1; the camp's score is their mean. Pure over the model.
## `suggest` names the presets that close the biggest open loop (the loop
## planner's chains first), `apply` drops one into the camp, wired to the
## camp's own tanks, and `apply_plan` places a whole chain, step to step.

const INPUT_KINDS: Array = ["water", "food", "biomass"]
const WASTE_KINDS: Array = ["greywater", "blackwater"]
## The presets that close each loop (ComponentPresets labels), best first.
const CLOSERS := {
	"water": ["Greywater Filter", "SoI Rain Catchment"],
	# A plant with a food_fraction credits the camp's FOOD store (the
	# vegetable beds); a plain plant credits biomass, the camp's firewood.
	"food": ["Vegetable Bed (10 m²)", "Market Garden (50 m²)"],
	"biomass": ["Garden Plot (50 m²)"],
	"greywater": ["Greywater Filter"],
	"blackwater": ["Compost Digester", "IBC Biodigester"],
}
const LABELS := {"water": "water", "food": "food", "biomass": "firewood",
	"greywater": "greywater", "blackwater": "blackwater"}


## {kinds: {kind: 0..1}, need: {kind: rate}, local: {kind: rate}, score: 0..1,
## worst: kind ("" = all closed)}.
static func score(model, comp_id: String) -> Dictionary:
	var out := {"kinds": {}, "need": {}, "local": {}, "score": 0.0, "worst": ""}
	if model == null:
		return out
	var comp: Dictionary = model.get_item(comp_id)
	var scope := str(comp.get("child_scope_id", ""))
	if scope.is_empty():
		return out
	var need: Dictionary = {}
	var local: Dictionary = {}
	for it in GraphNesting.walk_items(model, scope):
		var d: Dictionary = it
		var specs: Dictionary = d.get("specs", {})
		var ty := str(d.get("type", ""))
		if ty != "processor" and ty != "plant" and ty != "catchment":
			continue
		var is_hab := str(specs.get("role", "")) == "habitat"
		var mult := maxf(float(specs.get("occupants", 1.0)), 1.0) if is_hab else 1.0
		for inp in specs.get("inputs", []):
			var k := ResourceKinds.normalize_kind(str((inp as Dictionary).get("kind", "")))
			var r := float((inp as Dictionary).get("rate", 0.0)) * mult
			if r <= 0.0:
				continue
			if is_hab and INPUT_KINDS.has(k):
				need[k] = float(need.get(k, 0.0)) + r
			elif not is_hab and WASTE_KINDS.has(k):
				local[k] = float(local.get(k, 0.0)) + r
		for outp in specs.get("outputs", []):
			var k2 := ResourceKinds.normalize_kind(str((outp as Dictionary).get("kind", "")))
			var r2 := float((outp as Dictionary).get("rate", 0.0)) * mult
			if r2 <= 0.0:
				continue
			if is_hab and WASTE_KINDS.has(k2):
				need[k2] = float(need.get(k2, 0.0)) + r2
			elif not is_hab and INPUT_KINDS.has(k2):
				local[k2] = float(local.get(k2, 0.0)) + r2
		# Plants and catchments carry their yield as LIVE telemetry the flow
		# engine stamps (a garden's biomass_kg_h, a roof's live_capture_lph),
		# not as an output list.
		if ty == "plant":
			var out_k := "food" if float(specs.get("food_fraction", 0.0)) > 0.0 else "biomass"
			local[out_k] = float(local.get(out_k, 0.0)) + maxf(float(specs.get("biomass_kg_h", 0.0)), 0.0)
		elif ty == "catchment":
			local["water"] = float(local.get("water", 0.0)) + maxf(float(specs.get("live_capture_lph", 0.0)), 0.0)
	var kinds: Dictionary = {}
	var sum := 0.0
	var n := 0
	var worst := ""
	var worst_v := 2.0
	for k3 in INPUT_KINDS + WASTE_KINDS:
		var nd := float(need.get(k3, 0.0))
		if nd <= 1e-9:
			continue
		var f := clampf(float(local.get(k3, 0.0)) / nd, 0.0, 1.0)
		kinds[k3] = f
		sum += f
		n += 1
		if f < worst_v - 1e-9:
			worst_v = f
			worst = k3 if f < 0.999 else worst
	out["kinds"] = kinds
	out["need"] = need
	out["local"] = local
	out["score"] = sum / float(n) if n > 0 else 0.0
	out["worst"] = worst
	return out


## [{kind, label, presets: [label], plans: [plan], text}] for every loop not
## yet closed, the most open first. `sc` = a score() result already in hand
## (the camps panel has one per row), else it is computed. The presets come
## from the loop planner first (LoopPlanner: the machine that takes the open
## kind, or makes the wanted one, in each plan it found), then the CLOSERS
## table; `plans` are the planner's whole chains (apply_plan places one).
static func suggest(model, comp_id: String, sc: Dictionary = {}) -> Array:
	if sc.is_empty():
		sc = score(model, comp_id)
	var planned := _planned(model, comp_id)
	var rows: Array = []
	for k in (sc["kinds"] as Dictionary).keys():
		var f := float(sc["kinds"][k])
		if f >= 0.999:
			continue
		var waste := WASTE_KINDS.has(str(k))
		var verb := "Reclaim" if waste else "Make"
		var plans: Array = planned.get("%s:%s" % [str(k), "sink" if waste else "source"], [])
		var presets: Array = []
		for pl in plans:
			var lab := _touching_preset(pl as Dictionary)
			if not lab.is_empty() and not presets.has(lab):
				presets.append(lab)
		for c in CLOSERS.get(str(k), []):
			if not presets.has(c):
				presets.append(c)
		rows.append({"kind": str(k), "closed": f, "presets": presets, "plans": plans,
			"text": "%s %s inside the camp (%d %% closed)" % [verb, LABELS.get(str(k), str(k)), int(round(f * 100.0))]})
	rows.sort_custom(func(a, b) -> bool: return float(a["closed"]) < float(b["closed"]))
	return rows


## What a suggestion row offers, as buttons: each planner chain (its
## machines in order, classes left out), then the CLOSERS presets not
## already in one, at most `max_n`. → [{labels: [label], text, plan}]
## (`plan` empty for a lone preset). Place one with apply_option.
static func options(row: Dictionary, max_n: int = 3) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for pl in row.get("plans", []):
		var labels: Array = []
		for st in (pl as Dictionary).get("steps", []):
			if str((st as Dictionary).get("type", "")) == "preset":
				labels.append(str(st["label"]))
		var key := " → ".join(labels)
		if labels.is_empty() or seen.has(key):
			continue
		seen[key] = true
		for l in labels:
			seen[str(l)] = true
		out.append({"labels": labels, "text": key, "plan": pl})
		if out.size() >= max_n:
			return out
	for p in row.get("presets", []):
		if seen.has(str(p)):
			continue
		seen[str(p)] = true
		out.append({"labels": [str(p)], "text": str(p), "plan": {}})
		if out.size() >= max_n:
			break
	return out


## Place an options() entry inside the camp. Returns the new item ids.
static func apply_option(model, comp_id: String, opt: Dictionary) -> Array:
	if not (opt.get("plan", {}) as Dictionary).is_empty():
		return apply_plan(model, comp_id, opt["plan"])
	return _place_chain(model, comp_id, opt.get("labels", []))


static var _plan_cache: Dictionary = {}

## {"kind:side": [plan]} for the camp's scope, cached on the model's
## revisions (the camps panel asks once a row, every rebuild).
static func _planned(model, comp_id: String) -> Dictionary:
	if model == null:
		return {}
	var comp: Dictionary = model.get_item(comp_id)
	var scope := str(comp.get("child_scope_id", ""))
	if scope.is_empty():
		return {}
	var key := "%s|%d|%d" % [comp_id, int(model.get("struct_rev")), int(model.get("user_rev"))]
	if _plan_cache.has(key):
		return _plan_cache[key]
	var out: Dictionary = {}
	for row in LoopPlanner.plan_scope(model, scope, 6):
		var od: Dictionary = row["open"]
		out["%s:%s" % [str(od["kind"]), str(od["side"])]] = row["plans"]
	if _plan_cache.size() > 64:
		_plan_cache.clear()
	_plan_cache[key] = out
	return out


## The preset in a plan that touches the open kind itself: the first step of
## a sink plan, the last of a source plan ("" = it is a class).
static func _touching_preset(plan: Dictionary) -> String:
	var steps: Array = plan.get("steps", [])
	if steps.is_empty():
		return ""
	var st: Dictionary = steps[0] if str(plan.get("side", "")) == "sink" else steps[steps.size() - 1]
	return str(st["label"]) if str(st.get("type", "")) == "preset" else ""


## Drop the preset `label` into the camp's sub-graph, wired to the camp's own
## tanks: each of its inputs from the camp tank of that kind, each output into
## the camp tank of that kind. Returns the new item id ("" = refused).
static func apply(model, comp_id: String, label: String) -> String:
	var ids := _place_chain(model, comp_id, [label])
	return str(ids[0]) if not ids.is_empty() else ""


## Place every machine of a planner chain inside the camp, in flow order:
## each from the camp's tank of what it takes, else straight from the step
## before it that makes that kind; each into the camp's tank of what it
## makes. Class steps (no machine yet) are skipped. Returns the new ids.
static func apply_plan(model, comp_id: String, plan: Dictionary) -> Array:
	var labels: Array = []
	for st in plan.get("steps", []):
		if str((st as Dictionary).get("type", "")) == "preset":
			labels.append(str(st["label"]))
	return _place_chain(model, comp_id, labels)


static func _place_chain(model, comp_id: String, labels: Array) -> Array:
	var out: Array = []
	if model == null or labels.is_empty():
		return out
	var comp: Dictionary = model.get_item(comp_id)
	var scope := str(comp.get("child_scope_id", ""))
	if scope.is_empty():
		return out
	var tanks: Dictionary = {}
	var stores: Dictionary = {}
	var max_x := 0.0
	for it in model.get_items_in_scope(scope):
		var d: Dictionary = it
		max_x = maxf(max_x, float(d.get("x", 0.0)))
		if str(d.get("type", "")) == "resource":
			var ds: Dictionary = d.get("specs", {})
			var k := _k(str(ds.get("resource_kind", "")))
			# The camp's own stores (CampTemplates marks them camp_store) win
			# over a tank the player added later.
			if not tanks.has(k) or bool(ds.get("camp_store", false)) and not stores.has(k):
				tanks[k] = str(d.get("id", ""))
				if bool(ds.get("camp_store", false)):
					stores[k] = true
	# Place them all first, then wire, so a step can feed the next.
	var placed: Array = []
	for i in labels.size():
		var preset := ComponentPresets.find_preset_by_label(str(labels[i]))
		if preset.is_empty():
			continue
		var iid: String = model.generate_item_id()
		var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
		model.add_item({"id": iid, "type": str(preset.get("type", "processor")), "scope_id": scope,
			"x": max_x + 240.0 * float(placed.size() + 1), "y": 0.0, "width": float(preset.get("width", 140.0)),
			"height": float(preset.get("height", 130.0)), "specs": specs})
		placed.append({"id": iid, "ins": _ports(str(preset.get("type", "")), specs, true),
			"outs": _ports(str(preset.get("type", "")), specs, false)})
		out.append(iid)
	for n in placed.size():
		var p: Dictionary = placed[n]
		var iid2 := str(p["id"])
		for ip in p["ins"]:
			var k2 := str(ip[0])
			if tanks.has(k2):
				_wire(model, scope, str(tanks[k2]), "output", iid2, str(ip[1]), k2)
				continue
			var from := _maker_before(placed, n, k2)
			if not from.is_empty():
				_wire(model, scope, str(from[0]), str(from[1]), iid2, str(ip[1]), k2)
		for op in p["outs"]:
			var k3 := str(op[0])
			if tanks.has(k3):
				_wire(model, scope, iid2, str(op[1]), str(tanks[k3]), "input", k3)
	return out


## [[kind, handle]] of an item's inputs (`ins`) or outputs. A plant's ports
## are fixed: water_in, nutrients_in, and the crop on biomass_out (food for a
## food crop, its residue biomass on residue_out).
static func _ports(type: String, specs: Dictionary, ins: bool) -> Array:
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
		out.append([_k(str((list[i] as Dictionary).get("kind", ""))), ("res_in_%d" if ins else "res_out_%d") % i])
	return out


static func _k(kind: String) -> String:
	return CompositionCatalog.canonical(ResourceKinds.normalize_kind(kind))


## [item id, handle] of the nearest earlier placed step that makes `kind`.
static func _maker_before(placed: Array, n: int, kind: String) -> Array:
	for m in range(n - 1, -1, -1):
		for op in (placed[m] as Dictionary)["outs"]:
			if str(op[0]) == kind:
				return [str((placed[m] as Dictionary)["id"]), str(op[1])]
	return []


static func _wire(model, scope: String, src: String, sh: String, dst: String, dh: String, kind: String) -> void:
	model.add_connection({"scope_id": scope, "source": src, "source_handle": sh,
		"target": dst, "target_handle": dh, "polarity": "resource", "resource_type": kind})
