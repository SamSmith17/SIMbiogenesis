class_name TcMolecules
extends RefCounted

## Ball-and-stick molecules for the TC Process Lab's molecule lens (Phase 6
## of plans/TC_PROCESS_LAB_PLAN.md). Pure: layouts in ångström and reaction
## "storyboards" — which molecules go in, which come out — that keep every
## drawn atom (the selftest checks each one balances, atom for atom).
##
## Layouts come from TcSpecies' `mol` rows; this file adds what those rows
## leave out:
##   tar      levoglucosan's ten hydrogens (the row draws only C and O), so
##            cracking it into CO, CH4 and water balances
##   glucose  a glucose unit of cellulose (the wood in the lens): the same
##            C6H10O5 atoms as levoglucosan, which is what it leaves as
##   char     a carbon hexagon (a graphene fragment)
##   oil/wax  a zigzag CH2 chain, shortened to CHAIN_MAX carbons
## The wood is drawn as glucose units only (cellulose is ~40 % of it; the
## other polymers break down the same way in the lens).

const CHAIN_MAX := 10
const LENS_ONLY := {
	"glucose": {"name": "Glucose unit (cellulose)", "M": 162.14, "color": Color(0.85, 0.72, 0.50)},
	"char": {"name": "Char (carbon)", "M": 72.06, "color": Color(0.10, 0.09, 0.08)},
}

## What a reaction looks like. `from` / `to`: [[species, region]]; a
## species "*" in `from` takes any molecule of that region (boiling takes
## whatever is in the pool) and "=" in `to` gives the same species back.
## `alt`: storyboards played in turn for the same reported reaction.
const STORY := {
	"drying": [{"from": [["H2O", "solid"]], "to": [["H2O", "gas"]],
		"text": "Drying: water in the wood boils off as steam."}],
	"boiling": [{"from": [["*", "liquid"]], "to": [["=", "gas"]],
		"text": "Boiling: a molecule leaves the liquid as vapour."}],
	"condensing": [{"from": [["*", "gas_condensable"]], "to": [["=", "liquid"]],
		"text": "Condensing: vapour meets the cold wall and turns back to liquid."}],
	"pyrolysis": [
		{"from": [["glucose", "solid"]], "to": [["tar", "gas"]],
			"text": "Pyrolysis: a glucose unit breaks off the cellulose chain as levoglucosan (tar vapour)."},
		{"from": [["glucose", "solid"]], "to": [["char", "solid"], ["H2O", "gas"], ["H2O", "gas"], ["H2O", "gas"], ["H2O", "gas"], ["H2O", "gas"]],
			"text": "Charring: a glucose unit loses its water and leaves carbon behind (char)."}],
	"cracking": [{"from": [["tar", "gas"]], "to": [["CO", "gas"], ["CO", "gas"], ["CO", "gas"], ["CO", "gas"], ["CH4", "gas"], ["CH4", "gas"], ["H2O", "gas"]],
		"text": "Tar cracking: hot tar vapour splits into carbon monoxide, methane and water."}],
	"combustion": [{"from": [["CH4", "gas"], ["O2", "gas"], ["O2", "gas"]], "to": [["CO2", "gas"], ["H2O", "gas"], ["H2O", "gas"]],
		"text": "Burning: methane and oxygen become carbon dioxide and water, giving off heat."}],
}

static var _cache := {}


static func display_name(id: String) -> String:
	if LENS_ONLY.has(id):
		return str(LENS_ONLY[id]["name"])
	return TcSpecies.display_name(id)


static func molar_mass(id: String) -> float:
	if LENS_ONLY.has(id):
		return float(LENS_ONLY[id]["M"])
	return float(TcSpecies.row(id).get("M", 28.0))


static func formula(id: String) -> String:
	if id == "glucose":
		return "C₆H₁₀O₅"
	if id == "char":
		return "C₆"
	return str(TcSpecies.row(id).get("formula", id))


## {atoms: [[element, Vector3 Å]], bonds: [[i, j, order]]} centred on its
## middle; {} for a species with nothing to draw (ash, a desiccant).
static func layout(id: String) -> Dictionary:
	if _cache.has(id):
		return _cache[id]
	var m := {}
	match id:
		"tar", "glucose":
			m = _with_hydrogens(TcSpecies.row("tar").get("mol", {}))
		"char":
			m = _hexagon()
		_:
			var r := TcSpecies.row(id)
			if r.has("mol"):
				m = (r["mol"] as Dictionary).duplicate(true)
			elif str(r.get("unit", "")) == "CH2":
				m = _chain(mini(int(r.get("chain", 8)), CHAIN_MAX))
	if not m.is_empty():
		m = _centred(m)
	_cache[id] = m
	return m


static func _centred(m: Dictionary) -> Dictionary:
	var c := Vector3.ZERO
	var atoms: Array = m["atoms"]
	for a in atoms:
		c += a[1] as Vector3
	c /= float(maxi(atoms.size(), 1))
	var out: Array = []
	var r := 0.0
	for a in atoms:
		var p: Vector3 = (a[1] as Vector3) - c
		out.append([str(a[0]), p])
		r = maxf(r, p.length())
	return {"atoms": out, "bonds": (m["bonds"] as Array).duplicate(true), "radius": r + 0.6}


## Levoglucosan as TcSpecies draws it (6 ring C, 5 O) plus ten hydrogens:
## one on each ring carbon, pointing out of the ring, and one on four of
## the oxygens (hydroxyls) — C6H10O5.
static func _with_hydrogens(src: Dictionary) -> Dictionary:
	var atoms: Array = (src.get("atoms", []) as Array).duplicate(true)
	var bonds: Array = (src.get("bonds", []) as Array).duplicate(true)
	var ring := Vector3.ZERO
	for i in 6:
		ring += atoms[i][1] as Vector3
	ring /= 6.0
	for i in 6:
		var p: Vector3 = atoms[i][1]
		var d := (p - ring).normalized()
		var h := p + (d + Vector3(0, 0.6 if i % 2 == 0 else -0.6, 0)).normalized() * 1.09
		atoms.append(["H", h])
		bonds.append([i, atoms.size() - 1, 1])
	# The oxygens hanging off ring carbons 1..4 carry the hydroxyl H.
	for oi in [7, 8, 9, 10]:
		var o: Vector3 = atoms[oi][1]
		var cpos: Vector3 = atoms[oi - 6][1]
		var d2 := (o - cpos).normalized()
		var h2 := o + (d2 + Vector3(0, 0, 0.8)).normalized() * 0.96
		atoms.append(["H", h2])
		bonds.append([oi, atoms.size() - 1, 1])
	return {"atoms": atoms, "bonds": bonds}


static func _hexagon() -> Dictionary:
	var atoms: Array = []
	var bonds: Array = []
	for i in 6:
		var a := TAU * float(i) / 6.0
		atoms.append(["C", Vector3(cos(a), 0.0, sin(a)) * 1.42])
	for i in 6:
		bonds.append([i, (i + 1) % 6, 2 if i % 2 == 0 else 1])
	return {"atoms": atoms, "bonds": bonds}


## A zigzag n-alkane: n carbons, 2n + 2 hydrogens.
static func _chain(n: int) -> Dictionary:
	var atoms: Array = []
	var bonds: Array = []
	for i in n:
		atoms.append(["C", Vector3(1.26 * float(i), 0.43 if i % 2 == 0 else -0.43, 0.0)])
		if i > 0:
			bonds.append([i - 1, i, 1])
	for i in n:
		var c: Vector3 = atoms[i][1]
		var up := 1.0 if i % 2 == 0 else -1.0
		for z in [0.89, -0.89]:
			atoms.append(["H", c + Vector3(0.0, up * 0.5, z)])
			bonds.append([i, atoms.size() - 1, 1])
	for e in [[0, -1.0], [n - 1, 1.0]]:
		var ci: int = e[0]
		var c2: Vector3 = atoms[ci][1]
		atoms.append(["H", c2 + Vector3(float(e[1]) * 1.05, 0.0, 0.0)])
		bonds.append([ci, atoms.size() - 1, 1])
	return {"atoms": atoms, "bonds": bonds}


## Atoms by element in a species' layout.
static func element_count(id: String) -> Dictionary:
	var out := {}
	for a in (layout(id).get("atoms", []) as Array):
		out[str(a[0])] = int(out.get(str(a[0]), 0)) + 1
	return out


## Whether a storyboard keeps every atom (for fixed species; "*" / "="
## always balance).
static func balanced(story: Dictionary) -> bool:
	var a := {}
	var b := {}
	for f in story["from"]:
		if str(f[0]) == "*":
			return true
		for k in element_count(str(f[0])):
			a[k] = int(a.get(k, 0)) + int(element_count(str(f[0]))[k])
	for t in story["to"]:
		for k in element_count(str(t[0])):
			b[k] = int(b.get(k, 0)) + int(element_count(str(t[0]))[k])
	return a == b


## How many of each species to draw out of `n`, from mole fractions
## (largest remainder; anything over `min_x` gets at least one).
static func sample_counts(fracs: Dictionary, n: int, min_x: float = 0.01) -> Dictionary:
	var keys: Array = []
	var tot := 0.0
	for k in fracs.keys():
		if float(fracs[k]) > 0.0 and not layout(str(k)).is_empty():
			keys.append(k)
			tot += float(fracs[k])
	var out := {}
	if keys.is_empty() or tot <= 0.0 or n <= 0:
		return out
	keys.sort()
	var used := 0
	var rem: Array = []
	for k in keys:
		var want := float(fracs[k]) / tot * float(n)
		var c := int(floor(want))
		if c == 0 and float(fracs[k]) / tot >= min_x:
			c = 1
		out[k] = c
		used += c
		rem.append([want - floor(want), k])
	rem.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) > float(y[0]))
	var i := 0
	while used < n and i < rem.size():
		out[rem[i][1]] = int(out[rem[i][1]]) + 1
		used += 1
		i += 1
	for k in out.keys():
		if int(out[k]) <= 0:
			out.erase(k)
	return out


## Display speed (Å per second on screen) of a molecule at t_k: grows as
## √(T/M), the mean molecular speed's law, scaled down so it can be followed.
static func display_speed(id: String, t_k: float) -> float:
	return clampf(0.45 * sqrt(maxf(t_k, 1.0) / maxf(molar_mass(id), 1.0)), 0.15, 8.0)
