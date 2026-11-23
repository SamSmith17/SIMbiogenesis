class_name CompositionCatalog
extends RefCounted

## What a resource kind is made of, down to its elements (resource
## composition plan Phase 1). Pure and autoload-free: loads under --script.
##
##   components_of(kind)  {component: kg per kg of kind}, sub-kinds expanded
##   elements_of(kind)    {element: kg per kg of kind}
##   element_vector(kind) the same as PackedFloat64Array over ELEMENTS
##   kg_per_unit(kind)    kg per one of the kind's unit (NAN = unknown)
##   embodied(kind, qty)  {known, kg, water_kg, elements, energy_mj} for qty units
##   family_of / grade_of the water ladder (CompositionData.GRADES)
##
## Kinds go through ResourceKinds' aliases first. A player's custom kind may
## carry a `composition` dict in its meta ({kg_per_unit, mix, kinds, rest});
## with none it is "unknown": it flows, but embodied() says known = false
## and ledgers count it apart rather than as nothing.

const ATOMIC := {"H": 1.008, "C": 12.011, "N": 14.007, "O": 15.999, "Na": 22.990,
	"Mg": 24.305, "Al": 26.982, "Si": 28.085, "P": 30.974, "S": 32.06, "Cl": 35.45,
	"K": 39.098, "Ca": 40.078, "Fe": 55.845, "Br": 79.904, "Sr": 87.62, "B": 10.81}
## Elements tracked; "X" is everything else.
const ELEMENTS := ["C", "H", "O", "N", "P", "K", "S", "Na", "Cl", "Ca", "Mg", "Si", "Al", "Fe", "X"]
## Litres of ideal gas per mole at 0 °C and 101.325 kPa (normal m³ basis).
const NTP_L_PER_MOL := 22.414
## Latent heat of water at 25 °C, MJ/kg, for LHV of wet fuels.
const H_FG_MJ_KG := 2.443

static var _comp_cache: Dictionary = {}
static var _kind_cache: Dictionary = {}
## What embodied() multiplies by, per kind as asked: canonical() goes through
## ResourceKinds on every call and a ledger asked ~15 times per tank. Cleared
## with the other caches and when the user's kinds change.
static var _fac_cache: Dictionary = {}
static var _fac_rev: int = -1


# --- formulas -----------------------------------------------------------------

## Atom counts of a formula: "CH4N2O", "C4.43H7O1.44", "Ca(HCO3)2".
## Unknown symbols count as "X" by mass. Returns {} for an unreadable formula.
static func formula_counts(formula: String) -> Dictionary:
	var pos := [0]
	var counts := _parse_group(formula, pos)
	if pos[0] != formula.length():
		return {}
	return counts


static func _parse_group(f: String, pos: Array) -> Dictionary:
	var out: Dictionary = {}
	while int(pos[0]) >= 0 and int(pos[0]) < f.length():
		var ch: String = f[int(pos[0])]
		if ch == ")":
			return out
		var part: Dictionary = {}
		if ch == "(":
			pos[0] += 1
			part = _parse_group(f, pos)
			if int(pos[0]) >= f.length() or f[int(pos[0])] != ")":
				pos[0] = -1
				return {}
			pos[0] += 1
		elif ch >= "A" and ch <= "Z":
			var sym := ch
			pos[0] += 1
			while int(pos[0]) < f.length() and f[int(pos[0])] >= "a" and f[int(pos[0])] <= "z":
				sym += f[int(pos[0])]
				pos[0] += 1
			part = {sym: 1.0}
		else:
			pos[0] = -1
			return {}
		var num := ""
		while int(pos[0]) < f.length() and (f[int(pos[0])].is_valid_int() or f[int(pos[0])] == "."):
			num += f[int(pos[0])]
			pos[0] += 1
		var mult := 1.0 if num.is_empty() else float(num)
		for el in part.keys():
			out[el] = float(out.get(el, 0.0)) + float(part[el]) * mult
	return out


static func molar_mass(formula: String) -> float:
	var total := 0.0
	var counts := formula_counts(formula)
	for el in counts.keys():
		total += float(counts[el]) * float(ATOMIC.get(el, 0.0))
	return total


## Element mass fractions of a formula ({} when unreadable).
static func formula_elements(formula: String) -> Dictionary:
	var counts := formula_counts(formula)
	var m := molar_mass(formula)
	var out: Dictionary = {}
	if m <= 0.0:
		return out
	for el in counts.keys():
		var key := str(el) if ELEMENTS.has(str(el)) else "X"
		out[key] = float(out.get(key, 0.0)) + float(counts[el]) * float(ATOMIC.get(el, 0.0)) / m
	return out


# --- components -----------------------------------------------------------------

static func has_component(cid: String) -> bool:
	return CompositionData.COMPONENTS.has(cid)


static func component_name(cid: String) -> String:
	return str((CompositionData.COMPONENTS.get(cid, {}) as Dictionary).get("name", cid))


## Element mass fractions of one component (kg element per kg component).
static func component_elements(cid: String) -> Dictionary:
	if _comp_cache.has(cid):
		return _comp_cache[cid]
	var c: Dictionary = CompositionData.COMPONENTS.get(cid, {})
	var out: Dictionary = {}
	if c.has("formula"):
		out = formula_elements(str(c["formula"]))
	elif c.has("elements"):
		out = (c["elements"] as Dictionary).duplicate()
	elif c.has("mix"):
		for sub in (c["mix"] as Dictionary).keys():
			var f := float(c["mix"][sub])
			var se := component_elements(str(sub))
			for el in se.keys():
				out[el] = float(out.get(el, 0.0)) + f * float(se[el])
	_comp_cache[cid] = out
	return out


# --- kinds ----------------------------------------------------------------------

static func canonical(kind: String) -> String:
	var k := str(CompositionData.ALIASES.get(kind, kind))
	var n := ResourceKinds.normalize_kind(k)
	return n if not n.is_empty() else k


static func is_material(kind: String) -> bool:
	return not CompositionData.NON_MATERIAL.has(canonical(kind))


## The kind's composition row: builtin, else a custom kind's `composition`.
static func row(kind: String) -> Dictionary:
	var k := canonical(kind)
	if CompositionData.KINDS.has(k):
		return CompositionData.KINDS[k]
	if ResourceKinds.is_custom_kind(k):
		var c: Variant = ResourceKinds.kind_meta(k).get("composition", {})
		if c is Dictionary:
			return c
	return {}


## True when the kind's composition is known (material or not).
static func is_known(kind: String) -> bool:
	return not is_material(kind) or not row(kind).is_empty()


static func is_estimate(kind: String) -> bool:
	return bool(row(kind).get("est", false))


static func source_of(kind: String) -> String:
	return str(row(kind).get("src", ""))


static func family_of(kind: String) -> String:
	return str(row(kind).get("family", ""))


## Water or matter someone has used (its water counts as used water).
static func is_waste(kind: String) -> bool:
	return bool(row(kind).get("waste", false))


## A water-family kind clean enough to reuse (grade 3 irrigation and up).
static func is_clean_water(kind: String) -> bool:
	return family_of(kind) == "water" and grade_of(kind) >= 3


## One line for a tooltip: "97 % water · N 0.73 % · P 0.06 % · K 0.18 %".
## Empty for non-material or unknown kinds.
static func summary(kind: String) -> String:
	if not is_material(kind) or row(kind).is_empty():
		return ""
	var parts := PackedStringArray()
	var w := water_fraction(kind)
	if w >= 0.005:
		parts.append("%s water" % _pct_text(w))
	var el := elements_of(kind)
	for e in ["C", "N", "P", "K"]:
		var f := float(el.get(e, 0.0))
		if f >= 0.0001:
			parts.append("%s %s" % [e, _pct_text(f)])
	if parts.is_empty():
		var top := ""
		var best := 0.0
		for cid in components_of(kind).keys():
			if float(components_of(kind)[cid]) > best:
				best = float(components_of(kind)[cid])
				top = str(cid)
		if not top.is_empty():
			parts.append("%s %s" % [_pct_text(best), component_name(top)])
	return " · ".join(parts)


## The biggest components first: [[component, fraction]], at most `n`.
static func top_components(kind: String, n: int = 4) -> Array:
	var comps := components_of(kind)
	var rows: Array = []
	for cid in comps.keys():
		rows.append([str(cid), float(comps[cid])])
	rows.sort_custom(func(a, b) -> bool: return float(a[1]) > float(b[1]))
	return rows.slice(0, n)


static func _pct_text(f: float) -> String:
	var p := f * 100.0
	if p >= 10.0:
		return "%d %%" % int(round(p))
	if p >= 1.0:
		return "%.1f %%" % p
	return "%.2f %%" % p


## Water grade (CompositionData.GRADES), -1 for a kind outside the ladder.
static func grade_of(kind: String) -> int:
	var r := row(kind)
	return int(r.get("grade", -1)) if r.has("grade") else -1


## kg per one of the kind's units. Gases (mole rows) per normal m³ from the
## mean molar mass. NAN when the composition is unknown; 0 for non-material.
static func kg_per_unit(kind: String) -> float:
	if not is_material(kind):
		return 0.0
	var r := row(kind)
	if r.is_empty():
		return NAN
	if r.has("moles"):
		return _gas_molar_mass(r) / NTP_L_PER_MOL   # g/mol ÷ L/mol = kg/m³
	return float(r.get("kg_per_unit", 1.0))


static func _gas_molar_mass(r: Dictionary) -> float:
	var mm := 0.0
	for s in (r["moles"] as Dictionary).keys():
		var c: Dictionary = CompositionData.COMPONENTS.get(s, {})
		mm += float(r["moles"][s]) * molar_mass(str(c.get("formula", "")))
	return mm


## {component: kg per kg of kind}, every sub-kind expanded, `rest` filled.
static func components_of(kind: String) -> Dictionary:
	return (_profile(canonical(kind)) as Dictionary).get("components", {})


static func elements_of(kind: String) -> Dictionary:
	return (_profile(canonical(kind)) as Dictionary).get("elements", {})


static func element_vector(kind: String) -> PackedFloat64Array:
	var el := elements_of(kind)
	var v := PackedFloat64Array()
	v.resize(ELEMENTS.size())
	for i in ELEMENTS.size():
		v[i] = float(el.get(ELEMENTS[i], 0.0))
	return v


## kg of water (the H2O component) per kg of the kind.
static func water_fraction(kind: String) -> float:
	return float(components_of(kind).get("H2O", 0.0))


## Mass fractions summed before `rest` is filled (> 1 = a row that overfills).
static func listed_fraction(kind: String) -> float:
	return float((_profile(canonical(kind)) as Dictionary).get("listed", 0.0))


## Lower heating value as received, MJ per kg (gases: from their mixture).
static func lhv_mj_per_kg(kind: String) -> float:
	var r := row(kind)
	if r.has("lhv_mj_kg"):
		return float(r["lhv_mj_kg"])
	if r.has("moles"):
		var per_nm3 := 0.0
		for s in (r["moles"] as Dictionary).keys():
			per_nm3 += float(r["moles"][s]) * float((CompositionData.COMPONENTS.get(s, {}) as Dictionary).get("lhv_mj_nm3", 0.0))
		var kgm3 := kg_per_unit(kind)
		return per_nm3 / kgm3 if kgm3 > 0.0 else 0.0
	return 0.0


## Heat carried above 15 °C water, MJ per kg (hot water, steam).
static func sensible_mj_per_kg(kind: String) -> float:
	return float(row(kind).get("sensible_mj_kg", 0.0))


## Metabolisable food energy, MJ per kg (food, meals). A kind composed of
## other KINDS (packaged_food) with no figure of its own inherits the
## weighted mean of its sub-kinds' — before this, a Supply Store's food
## energy read 0 in the element ledger.
static func food_mj_per_kg(kind: String) -> float:
	return _food_mj_per_kg(canonical(kind), [])


static func _food_mj_per_kg(kind: String, seen: Array) -> float:
	var r := row(kind)
	if r.has("food_mj_kg"):
		return float(r["food_mj_kg"])
	if r.has("kinds") and not seen.has(kind):
		seen.append(kind)
		var total := 0.0
		for sub in (r["kinds"] as Dictionary).keys():
			total += float(r["kinds"][sub]) * _food_mj_per_kg(canonical(str(sub)), seen)
		return total
	return 0.0


## What `qty` of the kind's unit holds. known = false: the composition is
## unknown and only qty is meaningful.
static func embodied(kind: String, qty: float) -> Dictionary:
	var f := kind_factors(kind)
	if not bool(f["mat"]):
		return {"known": true, "kg": 0.0, "water_kg": 0.0, "elements": {}, "energy_mj": 0.0}
	if not bool(f["known"]):
		return {"known": false, "kg": 0.0, "water_kg": 0.0, "elements": {}, "energy_mj": 0.0}
	return _embodied_from(f, float(f["kgpu"]) * qty)


## The kind's constants, worked out once: mat (is_material), known (a
## composition row), and for a known kind kgpu (kg_per_unit), prof
## (elements_of), e (lhv + sensible MJ/kg), wf (water_fraction), food
## (food_mj_per_kg), clean (is_clean_water). Read-only: never change it.
static func kind_factors(kind: String) -> Dictionary:
	if _fac_rev != ResourceKinds.kinds_rev:
		_fac_cache.clear()
		_fac_rev = ResourceKinds.kinds_rev
	var hit: Variant = _fac_cache.get(kind)
	if hit != null:
		return hit
	var mat := is_material(kind)
	var known := mat and not row(kind).is_empty()
	var f := {"mat": mat, "known": known}
	if known:
		f["kgpu"] = kg_per_unit(kind)
		f["prof"] = elements_of(kind)
		f["e"] = lhv_mj_per_kg(kind) + sensible_mj_per_kg(kind)
		f["wf"] = water_fraction(kind)
		f["food"] = food_mj_per_kg(kind)
		f["clean"] = is_clean_water(kind)
	_fac_cache[kind] = f
	return f


## A gas kind with its own mix: `moles` = {component: mole fraction}
## (a TC Process Lab run stamps `composition` on its gas outputs). Density
## and elements come from that mix; LHV from its components.
static func embodied_gas(moles: Dictionary, nm3: float) -> Dictionary:
	var mm := 0.0
	var lhv := 0.0
	for c in moles.keys():
		var cd: Dictionary = CompositionData.COMPONENTS.get(c, {})
		mm += float(moles[c]) * molar_mass(str(cd.get("formula", "")))
		lhv += float(moles[c]) * float(cd.get("lhv_mj_nm3", 0.0))
	var out := {"known": mm > 0.0, "kg": 0.0, "water_kg": 0.0, "elements": {}, "energy_mj": lhv * nm3}
	if mm <= 0.0:
		return out
	var kg := mm / NTP_L_PER_MOL * nm3
	out["kg"] = kg
	var el: Dictionary = {}
	for c2 in moles.keys():
		var cd2: Dictionary = CompositionData.COMPONENTS.get(c2, {})
		var mf := float(moles[c2]) * molar_mass(str(cd2.get("formula", ""))) / mm
		if str(c2) == "H2O":
			out["water_kg"] = float(out["water_kg"]) + kg * mf
		var ce := component_elements(str(c2))
		for e in ce.keys():
			el[e] = float(el.get(e, 0.0)) + kg * mf * float(ce[e])
	out["elements"] = el
	return out


## The same for a mass of the kind (kg).
static func embodied_kg(kind: String, kg: float) -> Dictionary:
	if not is_material(kind):
		return {"known": true, "kg": 0.0, "water_kg": 0.0, "elements": {}, "energy_mj": 0.0}
	if row(kind).is_empty():
		return {"known": false, "kg": kg, "water_kg": 0.0, "elements": {}, "energy_mj": 0.0}
	return _embodied_kg(kind, kg)


static func _embodied_kg(kind: String, kg: float) -> Dictionary:
	return _embodied_from(kind_factors(kind), kg)


static func _embodied_from(f: Dictionary, kg: float) -> Dictionary:
	var el: Dictionary = {}
	var prof: Dictionary = f["prof"]
	for e in prof.keys():
		el[e] = kg * float(prof[e])
	var energy := kg * float(f["e"])
	return {"known": true, "kg": kg, "water_kg": kg * float(f["wf"]), "elements": el,
		"energy_mj": energy}


## A part in the inventory (PartInventory records carry mass_kg and
## material_kind): its own mass in its material, else the kind's default.
static func part_embodied(material_kind: String, mass_kg: float, fallback_kind: String = "finished_part") -> Dictionary:
	var k := material_kind if not material_kind.is_empty() and not row(material_kind).is_empty() else fallback_kind
	if mass_kg > 0.0:
		return embodied_kg(k, mass_kg)
	return embodied(k, 1.0)


## Every row that is a judgement call: [{kind|component, id, src}].
static func estimates() -> Array:
	var out: Array = []
	for cid in CompositionData.COMPONENTS.keys():
		if bool((CompositionData.COMPONENTS[cid] as Dictionary).get("est", false)):
			out.append({"what": "component", "id": str(cid)})
	for k in CompositionData.KINDS.keys():
		var r: Dictionary = CompositionData.KINDS[k]
		if bool(r.get("est", false)):
			out.append({"what": "kind", "id": str(k), "src": str(r.get("src", ""))})
	return out


## Every material builtin kind without a composition (should stay empty).
static func uncomposed_builtin_kinds() -> Array:
	var out: Array = []
	for k in ResourceKinds.BUILTIN.keys():
		if is_material(str(k)) and row(str(k)).is_empty():
			out.append(str(k))
	return out


static func clear_cache() -> void:
	_comp_cache.clear()
	_kind_cache.clear()
	_fac_cache.clear()


# --- the profile walk ---------------------------------------------------------

static func _profile(kind: String) -> Dictionary:
	if _kind_cache.has(kind):
		return _kind_cache[kind]
	var r := row(kind)
	var comps: Dictionary = {}
	var listed := 0.0
	if r.has("moles"):
		var mm := _gas_molar_mass(r)
		for s in (r["moles"] as Dictionary).keys():
			var c: Dictionary = CompositionData.COMPONENTS.get(s, {})
			var f := float(r["moles"][s]) * molar_mass(str(c.get("formula", ""))) / mm if mm > 0.0 else 0.0
			comps[s] = float(comps.get(s, 0.0)) + f
			listed += f
	if r.has("mix"):
		for cid in (r["mix"] as Dictionary).keys():
			var f2 := float(r["mix"][cid])
			comps[cid] = float(comps.get(cid, 0.0)) + f2
			listed += f2
	if r.has("kinds"):
		for sub in (r["kinds"] as Dictionary).keys():
			if str(sub) == kind:
				continue
			var f3 := float(r["kinds"][sub])
			listed += f3
			var sc: Dictionary = components_of(str(sub))
			for cid2 in sc.keys():
				comps[cid2] = float(comps.get(cid2, 0.0)) + f3 * float(sc[cid2])
	if r.has("rest") and listed < 1.0:
		var rc := str(r["rest"])
		comps[rc] = float(comps.get(rc, 0.0)) + (1.0 - listed)
	var el: Dictionary = {}
	for cid3 in comps.keys():
		var ce := component_elements(str(cid3))
		for e in ce.keys():
			el[e] = float(el.get(e, 0.0)) + float(comps[cid3]) * float(ce[e])
	var out := {"components": comps, "elements": el, "listed": listed}
	_kind_cache[kind] = out
	return out
