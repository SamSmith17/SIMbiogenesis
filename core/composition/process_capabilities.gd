class_name ProcessCapabilities
extends RefCounted

## What every machine in the library can pull out of what (resource
## composition plan Phase 5), and the answer to "what can separate this?".
## Pure; cached until the library changes.
##
## A TRANSFER is one fact about one preset or recipe: of the `target`
## (water, or the element C N P K) that comes in with `from` (a kind), this
## share (`recovery`) leaves in `to` (another kind, or "air"), costing
## `kwh_per_kg` of feed. It is DERIVED from the preset's own lists through
## the composition catalog (MassBalance closes the air side the same way
## the preset audit does), so a new preset is indexed without a word of
## extra data. Its `unit_ops` classes ride along.
##
## separate(kind) → for each target the kind holds, the presets and recipes
## that move it into another kind, then the classes (UnitOps) that could,
## ranked by recovery, then energy.

## A transfer below this share is noise (a trace of salt in a product).
const MIN_RECOVERY := 0.05
## A target a kind holds less than this share of (per kg) is not offered.
const MIN_CONTENT := 1e-4
const LIBRARY_CATEGORIES := ["processors", "tools", "csp", "plants", "my_components"]

static var _index: Array = []
static var _sig := ""


## Every transfer in the library (built-in and the player's own presets,
## builtin recipes). Rebuilt when the library changes.
static func index() -> Array:
	var presets := _library_presets()
	var sig := "%d|%d" % [presets.size(), hash(JSON.stringify(_labels(presets)))]
	if sig == _sig and not _index.is_empty():
		return _index
	var out: Array = []
	for p in presets:
		var pd: Dictionary = p
		var sp: Dictionary = pd.get("specs", {})
		var item := {"type": str(pd.get("type", "processor")), "specs": sp}
		if str(sp.get("role", "")) == "habitat":
			continue
		var ins: Array = sp.get("inputs", [])
		var outs: Array = sp.get("outputs", [])
		if str(pd.get("type", "")) == "plant":
			var io := MassBalance.plant_io(sp)
			ins = io[0]
			outs = io[1]
		out.append_array(transfers_of(str(pd.get("label", "")), "preset", ins, outs,
			MassBalance.air_for(item), _power_kw(sp), sp.get("unit_ops", [])))
	for r in ProcessRecipeCatalog.BUILTINS:
		var rd: Dictionary = r
		var routs: Array = []
		for o in rd.get("outputs", []):
			var od: Dictionary = (o as Dictionary).duplicate()
			if str(od.get("kind", "")) == "part":
				od["kind"] = "finished_part"
			routs.append(od)
		var e_kwh := 0.0
		for i in rd.get("inputs", []):
			if str((i as Dictionary).get("kind", "")) == "electric":
				e_kwh += float((i as Dictionary).get("qty", 0.0)) / 1000.0
		out.append_array(transfers_of("recipe: " + str(rd.get("label", rd.get("id", ""))), "recipe",
			rd.get("inputs", []), routs, rd.get("air", ""), e_kwh, []))
	_index = out
	_sig = sig
	return out


## The transfers one machine makes, at its listed rates (`power_kw` against
## the same hour of feed; for a recipe, kWh per batch against the batch).
static func transfers_of(source: String, source_type: String, inputs: Array, outputs: Array,
		air: Variant, power_kw: float, classes: Variant) -> Array:
	var out: Array = []
	var ins := _material(inputs)
	var outs := _material(outputs)
	if ins.is_empty():
		return out
	var feed_kg := 0.0
	for i in ins:
		feed_kg += float(i["emb"]["kg"])
	if feed_kg <= 0.0:
		return out
	var air_gases: Dictionary = MassBalance.check(inputs, outputs, [], [], MassBalance.DEFAULT_TOL, air)["air"]
	var cls: Array = classes if classes is Array else []
	for t in UnitOps.TARGETS:
		var in_t := 0.0
		for i2 in ins:
			in_t += _amount(i2["emb"], t)
		if in_t <= 1e-12:
			continue
		var dests: Dictionary = {}   # to kind -> amount
		for o in outs:
			var a := _amount(o["emb"], t)
			if a > 0.0:
				dests[str(o["kind"])] = float(dests.get(str(o["kind"]), 0.0)) + a
		var to_air := 0.0
		for g in air_gases.keys():
			var kg := float(air_gases[g])
			if kg <= 0.0:
				continue
			if t == "water":
				to_air += kg if str(g) == "H2O" else 0.0
			else:
				to_air += kg * float(CompositionCatalog.component_elements(str(g)).get(t, 0.0))
		if to_air > 0.0:
			dests["air"] = to_air
		for i3 in ins:
			var from := str(i3["kind"])
			if _amount(i3["emb"], t) <= 0.0:
				continue
			for to in dests.keys():
				if str(to) == from:
					continue
				var rec := clampf(float(dests[to]) / in_t, 0.0, 1.0)
				if rec < MIN_RECOVERY:
					continue
				out.append({"source": source, "type": source_type, "from": from, "to": str(to), "target": t,
					"recovery": rec, "kwh_per_kg": power_kw / feed_kg, "classes": cls.duplicate()})
	return out


## "What can separate this?" for one kind.
## → {kind, targets: [{target, label, content (share per kg), options:
##    [{type preset|recipe|class, label, to, recovery, kwh_per_kg, classes,
##      what, src, kwh_min, per}]}]}
static func separate(kind: String) -> Dictionary:
	var k := CompositionCatalog.canonical(kind)
	var res := {"kind": k, "targets": []}
	if not CompositionCatalog.is_material(k) or not CompositionCatalog.is_known(k):
		return res
	var per_kg := CompositionCatalog.embodied_kg(k, 1.0)
	var idx := index()
	for t in UnitOps.TARGETS:
		var content := _amount(per_kg, t)
		if content < MIN_CONTENT:
			continue
		var best: Dictionary = {}   # source|to -> option
		for tr in idx:
			var td: Dictionary = tr
			if str(td["from"]) != k or str(td["target"]) != t:
				continue
			var key := "%s|%s" % [td["source"], td["to"]]
			if best.has(key) and float(best[key]["recovery"]) >= float(td["recovery"]):
				continue
			best[key] = {"type": str(td["type"]), "label": str(td["source"]), "to": str(td["to"]),
				"recovery": float(td["recovery"]), "kwh_per_kg": float(td["kwh_per_kg"]),
				"classes": td["classes"], "what": "", "src": "", "kwh_min": NAN, "per": "feed"}
		var opts: Array = best.values()
		for c in UnitOps.classes_for(k, t):
			var cd: Dictionary = c
			cd["type"] = "class"
			opts.append(cd)
		opts.sort_custom(_rank)
		res["targets"].append({"target": t, "label": UnitOps.target_label(t), "content": content, "options": opts})
	return res


static func _rank(a: Dictionary, b: Dictionary) -> bool:
	var ra := float(a["recovery"])
	var rb := float(b["recovery"])
	if absf(ra - rb) > 0.02:
		return ra > rb
	var ta := 1 if str(a["type"]) == "class" else 0
	var tb := 1 if str(b["type"]) == "class" else 0
	if ta != tb:
		return ta < tb
	var ea := float(a["kwh_per_kg"])
	var eb := float(b["kwh_per_kg"])
	if absf(ea - eb) > 1e-9:
		return ea < eb
	return str(a["label"]) < str(b["label"])


static func _amount(emb: Dictionary, t: String) -> float:
	if t == "water":
		return float(emb.get("water_kg", 0.0))
	return float((emb.get("elements", {}) as Dictionary).get(t, 0.0))


static func _material(ios: Array) -> Array:
	var out: Array = []
	for io in ios:
		var d: Dictionary = io
		var kind := CompositionCatalog.canonical(ResourceKinds.normalize_kind(str(d.get("kind", ""))))
		var q := float(d.get("rate", d.get("qty", 0.0)))
		if q <= 0.0 or not CompositionCatalog.is_material(kind):
			continue
		var emb := CompositionCatalog.embodied(kind, q)
		if not bool(emb["known"]):
			continue
		out.append({"kind": kind, "emb": emb})
	return out


## A preset's electrical draw, kW: `watts`, else its electric inputs.
static func _power_kw(sp: Dictionary) -> float:
	var w := float(sp.get("watts", 0.0))
	if w > 0.0:
		return w / 1000.0
	var kw := 0.0
	for i in sp.get("inputs", []):
		var d: Dictionary = i
		if str(d.get("kind", "")) not in ["electric", "dc_electricity"]:
			continue
		var unit := str(d.get("unit", "W"))
		kw += float(d.get("rate", 0.0)) / (1000.0 if unit == "W" else 1.0)
	return kw


static func _library_presets() -> Array:
	var out: Array = []
	for cid in LIBRARY_CATEGORIES:
		out.append_array(ComponentPresets.presets_for_category(cid))
	return out


static func _labels(presets: Array) -> Array:
	var out: Array = []
	for p in presets:
		out.append(str((p as Dictionary).get("label", "")))
		out.append((p as Dictionary).get("specs", {}).get("outputs", []).size())
	return out
