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
## `suggest` names the existing presets that close the biggest open loop, and
## `apply` drops one into the camp, wired to the camp's own tanks.

const INPUT_KINDS: Array = ["water", "food", "biomass"]
const WASTE_KINDS: Array = ["greywater", "blackwater"]
## The presets that close each loop (ComponentPresets labels), best first.
const CLOSERS := {
	"water": ["Greywater Filter", "SoI Rain Catchment"],
	# Nothing in the library makes FOOD yet: a plant node credits a biomass
	# tank (ResourceFlowEngine._process_plant), which is the camp's firewood.
	"food": [],
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
			local["biomass"] = float(local.get("biomass", 0.0)) + maxf(float(specs.get("biomass_kg_h", 0.0)), 0.0)
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


## [{kind, label, presets: [label], text}] for every loop not yet closed,
## the most open first. `sc` = a score() result already in hand (the camps
## panel has one per row), else it is computed.
static func suggest(model, comp_id: String, sc: Dictionary = {}) -> Array:
	if sc.is_empty():
		sc = score(model, comp_id)
	var rows: Array = []
	for k in (sc["kinds"] as Dictionary).keys():
		var f := float(sc["kinds"][k])
		if f >= 0.999:
			continue
		var verb := "Reclaim" if WASTE_KINDS.has(str(k)) else "Make"
		rows.append({"kind": str(k), "closed": f, "presets": CLOSERS.get(str(k), []),
			"text": "%s %s inside the camp (%d %% closed)" % [verb, LABELS.get(str(k), str(k)), int(round(f * 100.0))]})
	rows.sort_custom(func(a, b) -> bool: return float(a["closed"]) < float(b["closed"]))
	return rows


## Drop the preset `label` into the camp's sub-graph, wired to the camp's own
## tanks: each of its inputs from the camp tank of that kind, each output into
## the camp tank of that kind. Returns the new item id ("" = refused).
static func apply(model, comp_id: String, label: String) -> String:
	if model == null:
		return ""
	var preset := ComponentPresets.find_preset_by_label(label)
	var comp: Dictionary = model.get_item(comp_id)
	var scope := str(comp.get("child_scope_id", ""))
	if preset.is_empty() or scope.is_empty():
		return ""
	var tanks: Dictionary = {}
	var stores: Dictionary = {}
	var max_x := 0.0
	for it in model.get_items_in_scope(scope):
		var d: Dictionary = it
		max_x = maxf(max_x, float(d.get("x", 0.0)))
		if str(d.get("type", "")) == "resource":
			var ds: Dictionary = d.get("specs", {})
			var k := ResourceKinds.normalize_kind(str(ds.get("resource_kind", "")))
			# The camp's own stores (CampTemplates marks them camp_store) win
			# over a tank the player added later.
			if not tanks.has(k) or bool(ds.get("camp_store", false)) and not stores.has(k):
				tanks[k] = str(d.get("id", ""))
				if bool(ds.get("camp_store", false)):
					stores[k] = true
	var iid: String = model.generate_item_id()
	var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
	model.add_item({"id": iid, "type": str(preset.get("type", "processor")), "scope_id": scope,
		"x": max_x + 240.0, "y": 0.0, "width": float(preset.get("width", 140.0)),
		"height": float(preset.get("height", 130.0)), "specs": specs})
	var ins: Array = specs.get("inputs", [])
	for i in ins.size():
		var k2 := ResourceKinds.normalize_kind(str((ins[i] as Dictionary).get("kind", "")))
		if tanks.has(k2):
			model.add_connection({"scope_id": scope, "source": tanks[k2], "source_handle": "output",
				"target": iid, "target_handle": "res_in_%d" % i, "polarity": "resource", "resource_type": k2})
	var outs: Array = specs.get("outputs", [])
	for j in outs.size():
		var k3 := ResourceKinds.normalize_kind(str((outs[j] as Dictionary).get("kind", "")))
		if tanks.has(k3):
			model.add_connection({"scope_id": scope, "source": iid, "source_handle": "res_out_%d" % j,
				"target": tanks[k3], "target_handle": "input", "polarity": "resource", "resource_type": k3})
	return iid
