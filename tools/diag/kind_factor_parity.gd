extends SceneTree

## Offline: CompositionCatalog.embodied / embodied_kg (now through the
## per-kind kind_factors cache) against the formula they replaced, and
## ResourceKinds' read-only lookups (now without kind_meta's copy) against
## kind_meta, for every builtin kind, every composition row and alias, and a
## few names nobody defined. Every answer must be exactly equal.
##   Godot --headless --path . --script tools/diag/kind_factor_parity.gd

var _fails := 0
var _n := 0


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if not cond:
		_fails += 1
		if _fails <= 20:
			print("kind-parity FAIL: ", what)


## The pre-cache embodied(), word for word.
func _old_embodied(kind: String, qty: float) -> Dictionary:
	var out := {"known": true, "kg": 0.0, "water_kg": 0.0, "elements": {}, "energy_mj": 0.0}
	if not CompositionCatalog.is_material(kind):
		return out
	if CompositionCatalog.row(kind).is_empty():
		out["known"] = false
		return out
	var kg := CompositionCatalog.kg_per_unit(kind) * qty
	return _old_kg(kind, kg)


func _old_kg(kind: String, kg: float) -> Dictionary:
	var el: Dictionary = {}
	var prof: Dictionary = CompositionCatalog.elements_of(kind)
	for e in prof.keys():
		el[e] = kg * float(prof[e])
	var energy := kg * (CompositionCatalog.lhv_mj_per_kg(kind) + CompositionCatalog.sensible_mj_per_kg(kind))
	return {"known": true, "kg": kg, "water_kg": kg * CompositionCatalog.water_fraction(kind), "elements": el,
		"energy_mj": energy}


func _same(a: Dictionary, b: Dictionary) -> bool:
	# == on dicts compares values exactly; check NaN-free and key order too.
	return a == b and a.keys() == b.keys() and var_to_str(a) == var_to_str(b)


func _initialize() -> void:
	var kinds: Array = []
	for k in ResourceKinds.all_kinds():
		kinds.append(str(k))
	for k in CompositionData.KINDS.keys():
		if not kinds.has(str(k)):
			kinds.append(str(k))
	for k in CompositionData.ALIASES.keys():
		if not kinds.has(str(k)):
			kinds.append(str(k))
	for k in ResourceKinds.BUILTIN.keys():
		for a in ((ResourceKinds.BUILTIN[k] as Dictionary).get("aliases", []) as Array):
			if not kinds.has(str(a)):
				kinds.append(str(a))
	for k in ["", "nobody_defined_this", "Water", " water", "electricity", "labour"]:
		if not kinds.has(k):
			kinds.append(k)
	var qtys := [0.0, 1.0, 0.1, 3.7, 1234.5678, 1.0e-7, 2.5e6, -4.2]
	for kind in kinds:
		for q in qtys:
			_ok(_same(CompositionCatalog.embodied(kind, q), _old_embodied(kind, q)),
				"embodied(%s, %s)" % [kind, str(q)])
			if CompositionCatalog.is_material(kind) and not CompositionCatalog.row(kind).is_empty():
				_ok(_same(CompositionCatalog.embodied_kg(kind, q), _old_kg(kind, q)),
					"embodied_kg(%s, %s)" % [kind, str(q)])
				var f := CompositionCatalog.kind_factors(kind)
				_ok(bool(f["clean"]) == CompositionCatalog.is_clean_water(kind), "clean " + kind)
				_ok(float(f["food"]) == CompositionCatalog.food_mj_per_kg(kind), "food " + kind)
			# Twice: the second answer comes from the cache.
			_ok(_same(CompositionCatalog.embodied(kind, q), _old_embodied(kind, q)),
				"embodied cached (%s, %s)" % [kind, str(q)])
		var meta := ResourceKinds.kind_meta(kind)
		_ok(ResourceKinds.display_name(kind) == str(meta.get("display", kind)), "display_name " + kind)
		_ok(ResourceKinds.default_unit(kind) == str(meta.get("unit", "unit")), "default_unit " + kind)
		_ok(ResourceKinds.flow_ref_rate(kind) == float(meta.get("flow_ref_rate", 10.0)), "flow_ref_rate " + kind)
		var old_col := Color(0.580, 0.639, 0.722, 1.0) if kind.is_empty() \
			else meta.get("color", Color(0.580, 0.639, 0.722, 1.0)) as Color
		_ok(ResourceKinds.wire_color(kind) == old_col, "wire_color " + kind)
	var rev := ResourceKinds.kinds_rev
	print("kind-parity: %d kinds, %d checks, kinds_rev %d" % [kinds.size(), _n, rev])
	print("kind-parity %s (%d failed)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)
