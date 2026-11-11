class_name MassBalance
extends RefCounted

## Does a process conserve mass and every element? (resource composition plan
## Phases 1 and 3; the preset selftest, the inspector and ElementLedger use it.)
##
## io lists are the presets' own shape: [{kind, rate}] per hour, or
## [{kind, qty}] per batch. Non-material kinds (electricity, heat, sunlight)
## are skipped. The air side is declared one of two ways:
##   emissions / uptakes: [{component | kind, rate}], fixed amounts (kg/h for
##     a component, the kind's unit for a kind);
##   air: a mode (AIR_MODES) or a list of "GAS:ELEMENT" pairs. The gases are
##     solved from the balance in order: each one closes its element (what
##     goes missing leaves as that gas; what appears came in as it). So a
##     person breathing out the carbon of their food, a compost heap giving
##     off CO2 and NH3, a bed fixing CO2 and transpiring water all close
##     without anyone typing a number, and track the rates.
## `retain` lets named elements stay behind on site (a plant bed keeps the
## N, P and K its crop did not take up in the soil).
##
## Judged elements are MAIN_ELEMENTS; minor ones (Na, Cl, Ca, S …) are
## reported in `minor` only, since the compositions carry them roughly. An
## element whose flow is under FLOOR_SHARE of the mass through the process
## is not judged (traces in water).
##
## Verdicts:
##   ok          mass and every main element within `tol`
##   estimate    the same, on rows marked est (CompositionData)
##   unbalanced  something appears or disappears (see loses / creates)
##   unknown     a kind has no composition (listed in `unknown`)
##   source      material comes out, none goes in (pumps, deliveries)
##   sink        material goes in, none comes out (burners, extruders)

const DEFAULT_TOL := 0.05
const MAIN_ELEMENTS := ["C", "H", "O", "N", "P", "K"]
## An element is judged when its larger side is at least this share of the
## process's mass flow (0.05 %).
const FLOOR_SHARE := 0.0005
const FLOOR_KG := 1e-7

## Air exchange by name: [gas, element it closes], in order.
const AIR_MODES := {
	# People: food is oxidised; C leaves as CO2, H as water vapour, O2 in.
	"breathe": [["CO2", "C"], ["H2O", "H"], ["O2", "O"]],
	# Composting, combustion, aerobic digestion: the same chemistry.
	"oxidize": [["CO2", "C"], ["H2O", "H"], ["O2", "O"]],
	# Composting / urine treatment that also lets ammonia off.
	"oxidize_nh3": [["NH3", "N"], ["CO2", "C"], ["H2O", "H"], ["O2", "O"]],
	# Nitrification + denitrification: N leaves as N2.
	"denitrify": [["N2", "N"], ["CO2", "C"], ["H2O", "H"], ["O2", "O"]],
	# Plants: CO2 fixed (taken in), water transpired, O2 given off; the
	# share of fertiliser N that is not taken up is lost from the soil
	# (field N use efficiency ~50–70 %, Cassman et al. 2002, Ambio 31).
	"grow": [["N2", "N"], ["CO2", "C"], ["H2O", "H"], ["O2", "O"]],
	# Combustion of a fuel gas or fuel: the fuel's N2 passes through.
	"burn": [["N2", "N"], ["CO2", "C"], ["H2O", "H"], ["O2", "O"]],
	# Anaerobic digestion: biogas leaves through its port; what the listed
	# rates do not carry vents as CO2 / CH4 and water from the open digestate.
	"anaerobic": [["CH4", "C"], ["H2O", "H"], ["CO2", "O"]],
	# Drying, evaporation, distillate condensing out of a vent: water vapour.
	"evaporate": [["H2O", "H"]],
	# Water drawn out of the air (atmospheric water generators).
	"condense": [["H2O", "H"]],
}
## Plant beds keep the nutrients their crop did not take up in the soil.
const PLANT_RETAIN := ["P", "K"]


static func of_specs(specs: Dictionary, tol: float = DEFAULT_TOL) -> Dictionary:
	return check(specs.get("inputs", []), specs.get("outputs", []),
		specs.get("emissions", []), specs.get("uptakes", []), tol, specs.get("air", ""),
		{"retain": specs.get("retain", [])})


## A graph item: its own lists and air mode, else the library preset it was
## made from (matched by name), else its role's default. Plants are judged
## per kg of crop (plant_io).
static func of_item(item: Dictionary, tol: float = DEFAULT_TOL) -> Dictionary:
	var specs: Dictionary = item.get("specs", {})
	var air: Variant = air_for(item)
	if str(item.get("type", "")) == "plant":
		var io := plant_io(specs)
		return check(io[0], io[1], [], [], tol, air, {"retain": PLANT_RETAIN})
	return check(specs.get("inputs", []), specs.get("outputs", []), specs.get("emissions", []),
		specs.get("uptakes", []), tol, air, {"retain": retain_for(item)})


## What a plant bed takes and gives per kg of crop: water and nutrients by
## its own rates; the crop is food (with the residue as biomass) when it has
## a food_fraction, else biomass.
static func plant_io(specs: Dictionary) -> Array:
	var ff := float(specs.get("food_fraction", 0.0))
	var ins: Array = [{"kind": "water", "rate": float(specs.get("water_l_per_kg", 0.0))},
		{"kind": "nutrients", "rate": float(specs.get("nutrient_kg_per_kg", 0.0))}]
	var outs: Array = [{"kind": "food" if ff > 0.0 else "biomass", "rate": 1.0}]
	if ff > 0.0 and ff < 1.0:
		outs.append({"kind": "biomass", "rate": (1.0 - ff) / ff})
	return [ins, outs]


static var _preset_air: Dictionary = {}
static var _preset_retain: Dictionary = {}


## The air mode for a graph item (a mode name, a pair list, or "").
static func air_for(item: Dictionary) -> Variant:
	var specs: Dictionary = item.get("specs", {})
	var own: Variant = specs.get("air", null)
	if own != null and (str(own) != "" if own is String else true):
		return own
	var from_preset: Variant = preset_air(str(specs.get("name", "")))
	if from_preset != null:
		return from_preset
	if str(specs.get("role", "")) == "habitat":
		return "breathe"
	if str(item.get("type", "")) == "plant":
		return "grow"
	return ""


## The elements a graph item keeps on site: its own `retain`, else its
## library preset's (nodes saved before presets carried one), else none;
## plant beds keep PLANT_RETAIN.
static func retain_for(item: Dictionary) -> Array:
	var specs: Dictionary = item.get("specs", {})
	var own: Variant = specs.get("retain", null)
	if own is Array:
		return own
	if str(item.get("type", "")) == "plant":
		return PLANT_RETAIN
	_index_presets()
	var r: Variant = _by_name(_preset_retain, str(specs.get("name", "")))
	return r if r is Array else []


## The `air` of the library preset a node was named after: its label or its
## specs name, with a trailing copy number ("Greywater Filter 2") ignored.
static func preset_air(name: String) -> Variant:
	_index_presets()
	return _by_name(_preset_air, name)


static func _index_presets() -> void:
	if not _preset_air.is_empty():
		return
	for list in [ComponentPresets.PROCESSORS, ComponentPresets.HABITATS, ComponentPresets.PLANTS,
			ComponentPresets.TOOLS, ComponentPresets.CSP_CONCENTRATORS]:
		for p in list:
			var pd: Dictionary = p
			var sp: Dictionary = pd.get("specs", {})
			for key in [str(pd.get("label", "")), str(sp.get("name", ""))]:
				if sp.has("air"):
					_preset_air[key] = sp["air"]
				if sp.has("retain"):
					_preset_retain[key] = sp["retain"]


static func _by_name(index: Dictionary, name: String) -> Variant:
	if index.has(name):
		return index[name]
	var re := RegEx.new()
	re.compile("\\s+\\d+$")
	return index.get(re.sub(name, ""), null)


## The balance of one machine: `inputs` + `uptakes` against `outputs` +
## `emissions` (io dicts {kind | component, rate | qty}), the air side
## closed by `air` (a mode name or [[gas, element]] pairs), elements in
## opts.retain kept on site. Verdicts: ok, estimate, unbalanced, unknown,
## source (material only out), sink (material only in).
static func check(inputs: Array, outputs: Array, emissions: Array = [], uptakes: Array = [],
		tol: float = DEFAULT_TOL, air: Variant = "", opts: Dictionary = {}) -> Dictionary:
	var side_in := _side(inputs + uptakes)
	var side_out := _side(outputs + emissions)
	var unknown: Array = []
	for u in (side_in["unknown"] as Array) + (side_out["unknown"] as Array):
		if not unknown.has(u):
			unknown.append(u)
	var gases := _close_air(side_in, side_out, air)
	var retain: Array = opts.get("retain", []) if opts.get("retain", []) is Array else []
	var through := maxf(float(side_in["kg"]), float(side_out["kg"]))
	var floor_kg := maxf(FLOOR_KG, FLOOR_SHARE * through)
	var delta: Dictionary = {}
	var rel: Dictionary = {}
	var loses: Array = []
	var creates: Array = []
	var minor: Array = []
	var retained: Dictionary = {}
	for e in CompositionCatalog.ELEMENTS:
		var a := float((side_in["elements"] as Dictionary).get(e, 0.0))
		var b := float((side_out["elements"] as Dictionary).get(e, 0.0))
		var big := maxf(a, b)
		delta[e] = b - a
		rel[e] = (b - a) / big if big > FLOOR_KG else 0.0
		if big < floor_kg or absf(float(rel[e])) <= tol:
			continue
		if b < a and retain.has(e):
			retained[e] = a - b
			continue
		if not MAIN_ELEMENTS.has(e):
			minor.append(e)
		elif b < a:
			loses.append(e)
		else:
			creates.append(e)
	var kg_in := float(side_in["kg"])
	var kg_out := float(side_out["kg"])
	for e2 in retained.keys():
		kg_out += float(retained[e2])
	var big_kg := maxf(kg_in, kg_out)
	var mass_rel := (kg_out - kg_in) / big_kg if big_kg > FLOOR_KG else 0.0
	var verdict := "ok"
	if not unknown.is_empty():
		verdict = "unknown"
	elif float(side_in["kg"]) <= FLOOR_KG and float(side_out["kg"]) > FLOOR_KG and gases.is_empty():
		verdict = "source"
	elif float(side_out["kg"]) <= FLOOR_KG and float(side_in["kg"]) > FLOOR_KG and gases.is_empty():
		verdict = "sink"
	elif not loses.is_empty() or not creates.is_empty() or absf(mass_rel) > tol:
		verdict = "unbalanced"
	elif bool(side_in["est"]) or bool(side_out["est"]):
		verdict = "estimate"
	return {"verdict": verdict, "in": side_in, "out": side_out, "delta": delta, "rel": rel,
		"mass_delta_kg": kg_out - kg_in, "mass_rel": mass_rel, "water_delta_kg":
		float(side_out["water_kg"]) - float(side_in["water_kg"]),
		"loses": loses, "creates": creates, "minor": minor, "unknown": unknown,
		"air": gases, "retained": retained}


## The air mode as [[gas, element]] pairs.
static func air_pairs(air: Variant) -> Array:
	if air is String:
		return AIR_MODES.get(str(air), [])
	var out: Array = []
	if air is Array:
		for a in air:
			if a is Array and (a as Array).size() == 2:
				out.append(a)
			elif a is String and str(a).contains(":"):
				var parts := str(a).split(":")
				out.append([parts[0], parts[1]])
	return out


## Solve the air gases from what their elements are missing (in − out):
## one equation per [gas, element] pair, Σ gas × the gas's share of that
## element = missing, solved together (CH4, CO2 and H2O each carry two of
## the closed elements in a digester). A positive amount leaves (added to
## out), a negative one was taken in (added to in). Returns {gas: kg, + =
## emitted}. A singular set falls back to closing the pairs in order.
static func _close_air(side_in: Dictionary, side_out: Dictionary, air: Variant) -> Dictionary:
	var pairs: Array = []
	for pair in air_pairs(air):
		var ge := CompositionCatalog.component_elements(str(pair[0]))
		if float(ge.get(str(pair[1]), 0.0)) > 0.0:
			pairs.append([str(pair[0]), str(pair[1]), ge])
	var gases: Dictionary = {}
	if pairs.is_empty():
		return gases
	var n := pairs.size()
	var a_m: Array = []
	var rhs: Array = []
	for i in n:
		var el := str(pairs[i][1])
		var row: Array = []
		for j in n:
			row.append(float((pairs[j][2] as Dictionary).get(el, 0.0)))
		a_m.append(row)
		rhs.append(float((side_in["elements"] as Dictionary).get(el, 0.0))
			- float((side_out["elements"] as Dictionary).get(el, 0.0)))
	var sol := _solve_square(a_m, rhs)
	if sol.is_empty():
		# Close in order, each gas against what is still missing.
		sol = []
		var acc: Dictionary = {}
		for i2 in n:
			var el2 := str(pairs[i2][1])
			var ge2: Dictionary = pairs[i2][2]
			var missing := float(rhs[i2]) - float(acc.get(el2, 0.0))
			var kg0 := missing / float(ge2[el2])
			sol.append(kg0)
			for e0 in ge2.keys():
				acc[e0] = float(acc.get(e0, 0.0)) + kg0 * float(ge2[e0])
	for k in n:
		var kg := float(sol[k])
		if absf(kg) <= FLOOR_KG:
			continue
		var gas := str(pairs[k][0])
		var ge3: Dictionary = pairs[k][2]
		gases[gas] = float(gases.get(gas, 0.0)) + kg
		var side: Dictionary = side_out if kg > 0.0 else side_in
		side["kg"] = float(side["kg"]) + absf(kg)
		if gas == "H2O":
			side["water_kg"] = float(side["water_kg"]) + absf(kg)
		for e in ge3.keys():
			(side["elements"] as Dictionary)[e] = float((side["elements"] as Dictionary).get(e, 0.0)) + absf(kg) * float(ge3[e])
	return gases


## Gaussian elimination with partial pivoting; [] when singular.
static func _solve_square(a_in: Array, b_in: Array) -> Array:
	var n := b_in.size()
	var a: Array = []
	for r in a_in:
		a.append((r as Array).duplicate())
	var b: Array = b_in.duplicate()
	for col in n:
		var piv := col
		for r2 in range(col + 1, n):
			if absf(float(a[r2][col])) > absf(float(a[piv][col])):
				piv = r2
		if absf(float(a[piv][col])) < 1e-12:
			return []
		if piv != col:
			var tr: Variant = a[col]
			a[col] = a[piv]
			a[piv] = tr
			var tb: Variant = b[col]
			b[col] = b[piv]
			b[piv] = tb
		for r3 in range(col + 1, n):
			var f := float(a[r3][col]) / float(a[col][col])
			if f == 0.0:
				continue
			for c in range(col, n):
				a[r3][c] = float(a[r3][c]) - f * float(a[col][c])
			b[r3] = float(b[r3]) - f * float(b[col])
	var x: Array = []
	x.resize(n)
	for i in range(n - 1, -1, -1):
		var acc := float(b[i])
		for j in range(i + 1, n):
			acc -= float(a[i][j]) * float(x[j])
		x[i] = acc / float(a[i][i])
	return x


## Totals of one side: {kg, water_kg, energy_mj, elements, est, unknown}.
static func _side(ios: Array) -> Dictionary:
	var kg := 0.0
	var water := 0.0
	var energy := 0.0
	var el: Dictionary = {}
	var est := false
	var unknown: Array = []
	for io in ios:
		var d: Dictionary = io
		var q := float(d.get("rate", d.get("qty", 0.0)))
		if q <= 0.0:
			continue
		var emb: Dictionary = {}
		if d.has("component"):
			var cid := str(d["component"])
			if not CompositionCatalog.has_component(cid):
				if not unknown.has(cid):
					unknown.append(cid)
				continue
			emb = {"kg": q, "water_kg": q if cid == "H2O" else 0.0, "energy_mj": 0.0, "elements": {}}
			var ce := CompositionCatalog.component_elements(cid)
			for e in ce.keys():
				(emb["elements"] as Dictionary)[e] = q * float(ce[e])
			est = est or bool((CompositionData.COMPONENTS[cid] as Dictionary).get("est", false))
		else:
			var kind := str(d.get("kind", ""))
			if kind.is_empty() or not CompositionCatalog.is_material(kind):
				continue
			# A gas output carrying its own mix (a TC Process Lab run stamps
			# `composition` as mole fractions of known components).
			var comp: Variant = d.get("composition", null)
			if comp is Dictionary and not (comp as Dictionary).is_empty() and CompositionCatalog.row(kind).has("moles") and _all_components(comp):
				emb = CompositionCatalog.embodied_gas(comp, q)
			else:
				emb = CompositionCatalog.embodied(kind, q)
			if not bool(emb["known"]):
				if not unknown.has(kind):
					unknown.append(kind)
				continue
			est = est or CompositionCatalog.is_estimate(kind)
		kg += float(emb["kg"])
		water += float(emb["water_kg"])
		energy += float(emb["energy_mj"])
		for e2 in (emb["elements"] as Dictionary).keys():
			el[e2] = float(el.get(e2, 0.0)) + float(emb["elements"][e2])
	return {"kg": kg, "water_kg": water, "energy_mj": energy, "elements": el, "est": est,
		"unknown": unknown}


static func _all_components(comp: Dictionary) -> bool:
	for c in comp.keys():
		if not CompositionCatalog.has_component(str(c)):
			return false
	return true


# --- tuning ---------------------------------------------------------------------

## The rates of the `free` outputs (kinds) that best close `elements`
## (least squares over the free rates, air solved after), for tuning presets:
## returns {kind: rate in its unit}. Rates are clamped at 0.
static func solve_free_outputs(inputs: Array, fixed_outputs: Array, free: Array,
		elements: Array = ["C", "H", "O"], gas_mix: Dictionary = {}) -> Dictionary:
	var side_in := _side(inputs)
	var side_fix := _side(fixed_outputs)
	var n := free.size()
	# A x = b: rows = elements, columns = kg of element per unit of free kind.
	var a: Array = []
	var b: Array = []
	for e in elements:
		var row: Array = []
		for k in free:
			var emb := CompositionCatalog.embodied_gas(gas_mix[k], 1.0) if gas_mix.has(k) 				else CompositionCatalog.embodied(str(k), 1.0)
			row.append(float((emb["elements"] as Dictionary).get(e, 0.0)))
		a.append(row)
		b.append(float((side_in["elements"] as Dictionary).get(e, 0.0)) - float((side_fix["elements"] as Dictionary).get(e, 0.0)))
	# Normal equations AᵀA x = Aᵀb, Gaussian elimination.
	var m: Array = []
	for i in n:
		var r: Array = []
		for j in n:
			var s := 0.0
			for k2 in a.size():
				s += float(a[k2][i]) * float(a[k2][j])
			r.append(s + (1e-12 if i == j else 0.0))
		var rhs := 0.0
		for k3 in a.size():
			rhs += float(a[k3][i]) * float(b[k3])
		r.append(rhs)
		m.append(r)
	for c in n:
		var piv := c
		for r2 in range(c + 1, n):
			if absf(float(m[r2][c])) > absf(float(m[piv][c])):
				piv = r2
		var tmp: Array = m[c]
		m[c] = m[piv]
		m[piv] = tmp
		var pv := float(m[c][c])
		if absf(pv) < 1e-18:
			continue
		for r3 in n:
			if r3 == c:
				continue
			var f := float(m[r3][c]) / pv
			for c2 in range(c, n + 1):
				m[r3][c2] = float(m[r3][c2]) - f * float(m[c][c2])
	var out: Dictionary = {}
	for i2 in n:
		var pv2 := float(m[i2][i2])
		out[str(free[i2])] = maxf(float(m[i2][n]) / pv2, 0.0) if absf(pv2) > 1e-18 else 0.0
	return out
