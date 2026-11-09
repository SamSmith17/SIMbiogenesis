class_name TcMolecules
extends RefCounted

## Ball-and-stick molecules for the TC Process Lab's molecule lens. Pure:
## layouts in ångström and reaction STORYBOARDS — one worked example of each
## reaction the model reports: which molecules go in, where they stand, which
## come out and where they end up. Every storyboard keeps every drawn atom
## (the selftest checks each one balances, atom for atom).
##
## Layouts are drawn flat-on to the viewer (x right, y up, z toward the
## camera), like a textbook figure. Small molecules come from TcSpecies'
## `mol` rows; this file adds the pieces of wood and what they break into:
##   xylan2      two xylose links of a hemicellulose (xylan) chain, C10H16O8
##   xylan       one xylose link, C5H8O4 (the anhydro-sugar repeat unit)
##   furfural    C5H4O2: what a xylose link leaves when it loses two waters
##   cellulose2  two glucose links of a cellulose chain, C12H20O10
##   glucose     one glucose link, C6H10O5
##   tar         levoglucosan, C6H10O5: a glucose link that left the chain
##               whole (TcSpecies draws its C and O; the hydrogens are added)
##   lignin      one phenylpropane unit of lignin (coniferyl type), C10H12O3
##   guaiacol    C7H8O2: the unit's ring with its methoxy and hydroxyl
##   ethylene    C2H4
##   char        a carbon hexagon (a graphene fragment)
##   alkane:N    a zigzag CH2 chain of N carbons (plastic, oil, wax)
## The chemistry is illustrative: real wood pyrolysis makes hundreds of
## products. Each storyboard is one well-known route, balanced:
##   hemicellulose  C10H16O8 → C5H8O4 + C5H4O2 + 2 H2O   (dehydration to furfural)
##   cellulose      C12H20O10 → C6H10O5 + C6H10O5        (levoglucosan leaves)
##   lignin         C10H12O3 → C7H8O2 + C2H4 + CO        (side chain off the ring)
##   charring       C6H10O5 → 6 C + 5 H2O
##   tar cracking   C6H10O5 → 4 CO + 2 CH4 + H2O
##   plastic        C10H22 → C7H16 + C3H6                (chain scission)

const CHAIN_MAX := 10
const RING_R := 1.45          # sugar ring, Å (C–C 1.52 / C–O 1.43, drawn regular)
const AROM_R := 1.39          # benzene ring
const LENS_ONLY := {
	"xylan2": {"name": "Hemicellulose (two links of the chain)", "formula": "(C₅H₈O₄)₂", "M": 264.23},
	"xylan": {"name": "Xylose link (stays in the chain)", "formula": "C₅H₈O₄", "M": 132.11},
	"furfural": {"name": "Furfural", "formula": "C₅H₄O₂", "M": 96.08},
	"cellulose2": {"name": "Cellulose (two links of the chain)", "formula": "(C₆H₁₀O₅)₂", "M": 324.28},
	"glucose": {"name": "Glucose link (cellulose)", "formula": "C₆H₁₀O₅", "M": 162.14},
	"lignin": {"name": "Lignin unit (phenylpropane)", "formula": "C₁₀H₁₂O₃", "M": 180.2},
	"guaiacol": {"name": "Guaiacol (a smoky phenol)", "formula": "C₇H₈O₂", "M": 124.14},
	"ethylene": {"name": "Ethylene", "formula": "C₂H₄", "M": 28.05},
	"char": {"name": "Char (carbon)", "formula": "C₆", "M": 72.06},
}

static var _cache := {}
static var _raw_cache := {}
static var _stories := {}


static func display_name(id: String) -> String:
	if LENS_ONLY.has(id):
		return str(LENS_ONLY[id]["name"])
	if id.begins_with("alkane:"):
		var n := int(id.get_slice(":", 1))
		return "Polymer chain (a piece of it)" if n >= CHAIN_MAX else "Oil (a shorter chain)"
	return TcSpecies.display_name(id)


static func molar_mass(id: String) -> float:
	if LENS_ONLY.has(id):
		return float(LENS_ONLY[id]["M"])
	if id.begins_with("alkane:"):
		return 14.03 * float(int(id.get_slice(":", 1))) + 2.02
	return float(TcSpecies.row(id).get("M", 28.0))


static func formula(id: String) -> String:
	if LENS_ONLY.has(id):
		return str(LENS_ONLY[id]["formula"])
	if id.begins_with("alkane:"):
		var n := int(id.get_slice(":", 1))
		return "C%dH%d" % [n, 2 * n + 2]
	return str(TcSpecies.row(id).get("formula", id))


## {atoms: [[element, Vector3 Å]], bonds: [[i, j, order]], radius} centred
## on its middle; {} for a species with nothing to draw (ash, a desiccant).
static func layout(id: String) -> Dictionary:
	if _cache.has(id):
		return _cache[id]
	var m := raw(id)
	if not m.is_empty():
		m = _centred(m)
	_cache[id] = m
	return m


## A layout as authored (not centred): pieces of one storyboard share a
## frame, so the link that stays is drawn exactly where it was.
static func raw(id: String) -> Dictionary:
	if _raw_cache.has(id):
		return _raw_cache[id]
	var m := {}
	match id:
		"tar":
			m = _with_hydrogens(TcSpecies.row("tar").get("mol", {}))
		"xylan2":
			m = _sugar_chain(2, false)
		"xylan":
			m = _sugar_chain(1, false)
		"cellulose2":
			m = _sugar_chain(2, true)
		"glucose":
			m = _sugar_chain(1, true)
		"furfural":
			m = _furfural()
		"lignin":
			m = _lignin(true)
		"guaiacol":
			m = _lignin(false)
		"ethylene":
			m = _ethylene()
		"char":
			m = _hexagon()
		_:
			if id.begins_with("alkane:"):
				m = _chain(clampi(int(id.get_slice(":", 1)), 1, 40))
			else:
				var r := TcSpecies.row(id)
				if r.has("mol"):
					m = (r["mol"] as Dictionary).duplicate(true)
				elif str(r.get("unit", "")) == "CH2":
					m = _chain(mini(int(r.get("chain", 8)), CHAIN_MAX))
	_raw_cache[id] = m
	return m


## The middle of a raw layout (the mean of its atoms).
static func centroid(id: String) -> Vector3:
	var atoms: Array = raw(id).get("atoms", [])
	var c := Vector3.ZERO
	for a in atoms:
		c += a[1] as Vector3
	return c / float(maxi(atoms.size(), 1))


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


static func _dir(deg: float) -> Vector3:
	return Vector3(cos(deg_to_rad(deg)), sin(deg_to_rad(deg)), 0.0)


static func _add(atoms: Array, bonds: Array, el: String, p: Vector3, to: int = -1, order: int = 1) -> int:
	atoms.append([el, p])
	if to >= 0:
		bonds.append([to, atoms.size() - 1, order])
	return atoms.size() - 1


## `n` links of a sugar chain along x: xylose links (hemicellulose,
## C5H8O4 each) or, with `hexose`, glucose links (cellulose, C6H10O5 each).
## A link is a six-membered ring (C1, O5, C5, C4, C3, C2 round it), hydroxyls
## on C2 and C3, the bridging oxygen O4 on C4 (it joins the previous link's
## C1), and for glucose the CH2OH arm on C5. Link k's atoms come before
## link k + 1's, so a one-link layout is the first link of a longer one.
static func _sugar_chain(n: int, hexose: bool) -> Dictionary:
	var atoms: Array = []
	var bonds: Array = []
	var pitch := 2.0 * RING_R + 2.51
	var prev_c1 := -1
	var z := Vector3(0, 0, 1)
	for k in n:
		var c := Vector3(pitch * float(k), 0.0, 0.0)
		var pk := 0.22
		var c1 := _add(atoms, bonds, "C", c + _dir(0.0) * RING_R + z * pk)
		var o5 := _add(atoms, bonds, "O", c + _dir(60.0) * RING_R - z * pk, c1)
		var c5 := _add(atoms, bonds, "C", c + _dir(120.0) * RING_R + z * pk, o5)
		var c4 := _add(atoms, bonds, "C", c + _dir(180.0) * RING_R - z * pk, c5)
		var c3 := _add(atoms, bonds, "C", c + _dir(240.0) * RING_R + z * pk, c4)
		var c2 := _add(atoms, bonds, "C", c + _dir(300.0) * RING_R - z * pk, c3)
		bonds.append([c2, c1, 1])
		var p1: Vector3 = atoms[c1][1]
		var p2: Vector3 = atoms[c2][1]
		var p3: Vector3 = atoms[c3][1]
		var p4: Vector3 = atoms[c4][1]
		var p5: Vector3 = atoms[c5][1]
		# The bridging oxygen on C4, up and back toward the previous link.
		var o4 := _add(atoms, bonds, "O", p4 + Vector3(-1.255, 0.65, 0.22), c4)
		if prev_c1 >= 0:
			bonds.append([prev_c1, o4, 1])
		prev_c1 = c1
		var o2 := _add(atoms, bonds, "O", p2 + _dir(300.0) * 1.42, c2)
		_add(atoms, bonds, "H", atoms[o2][1] + Vector3(1.0, -0.2, 0.3).normalized() * 0.96, o2)
		var o3 := _add(atoms, bonds, "O", p3 + _dir(240.0) * 1.42, c3)
		_add(atoms, bonds, "H", atoms[o3][1] + Vector3(-1.0, -0.2, 0.3).normalized() * 0.96, o3)
		_add(atoms, bonds, "H", p1 + Vector3(0.45, -0.65, 0.62).normalized() * 1.09, c1)
		_add(atoms, bonds, "H", p2 + Vector3(0.75, 0.2, -0.65).normalized() * 1.09, c2)
		_add(atoms, bonds, "H", p3 + Vector3(-0.2, 0.3, 0.95).normalized() * 1.09, c3)
		_add(atoms, bonds, "H", p4 + Vector3(-0.5, -0.6, -0.65).normalized() * 1.09, c4)
		if hexose:
			_add(atoms, bonds, "H", p5 + Vector3(0.1, 0.3, 0.95).normalized() * 1.09, c5)
			var c6 := _add(atoms, bonds, "C", p5 + _dir(120.0) * 1.52 - z * 0.15, c5)
			var p6: Vector3 = atoms[c6][1]
			var o6 := _add(atoms, bonds, "O", p6 + _dir(60.0) * 1.42, c6)
			_add(atoms, bonds, "H", atoms[o6][1] + Vector3(0.3, 1.0, 0.2).normalized() * 0.96, o6)
			_add(atoms, bonds, "H", p6 + Vector3(-0.85, 0.25, 0.55).normalized() * 1.09, c6)
			_add(atoms, bonds, "H", p6 + Vector3(-0.4, -0.2, -0.9).normalized() * 1.09, c6)
		else:
			_add(atoms, bonds, "H", p5 + (_dir(120.0) * 0.7 + z * 0.75).normalized() * 1.09, c5)
			_add(atoms, bonds, "H", p5 + (_dir(120.0) * 0.7 - z * 0.75).normalized() * 1.09, c5)
	return {"atoms": atoms, "bonds": bonds}


## Furfural: a furan ring (O, four C, two double bonds) with an aldehyde.
static func _furfural() -> Dictionary:
	var atoms: Array = []
	var bonds: Array = []
	var r := 1.17
	var o1 := _add(atoms, bonds, "O", _dir(90.0) * r)
	var c2 := _add(atoms, bonds, "C", _dir(18.0) * r, o1)
	var c3 := _add(atoms, bonds, "C", _dir(-54.0) * r, c2, 2)
	var c4 := _add(atoms, bonds, "C", _dir(-126.0) * r, c3)
	var c5 := _add(atoms, bonds, "C", _dir(162.0) * r, c4, 2)
	bonds.append([c5, o1, 1])
	var cc := _add(atoms, bonds, "C", (atoms[c2][1] as Vector3) + _dir(18.0) * 1.45, c2)
	_add(atoms, bonds, "O", (atoms[cc][1] as Vector3) + _dir(78.0) * 1.22, cc, 2)
	_add(atoms, bonds, "H", (atoms[cc][1] as Vector3) + _dir(-42.0) * 1.09, cc)
	_add(atoms, bonds, "H", (atoms[c3][1] as Vector3) + _dir(-54.0) * 1.08, c3)
	_add(atoms, bonds, "H", (atoms[c4][1] as Vector3) + _dir(-126.0) * 1.08, c4)
	_add(atoms, bonds, "H", (atoms[c5][1] as Vector3) + _dir(162.0) * 1.08, c5)
	return {"atoms": atoms, "bonds": bonds}


## A lignin unit (coniferyl type): a benzene ring carrying a hydroxyl, a
## methoxy and — with `chain` — the three-carbon side chain (CH=CH–CH2OH)
## that ties it into the polymer. Without the chain it is guaiacol: the
## ring, its hydroxyl and methoxy, and a hydrogen where the chain was. The
## ring's atoms come first and stand in the same place in both.
static func _lignin(chain: bool) -> Dictionary:
	var atoms: Array = []
	var bonds: Array = []
	var ring: Array = []
	for k in 6:
		var i := _add(atoms, bonds, "C", _dir(90.0 - 60.0 * float(k)) * AROM_R)
		ring.append(i)
		if k > 0:
			bonds.append([ring[k - 1], i, 2 if k % 2 == 1 else 1])
	bonds.append([ring[5], ring[0], 1])
	# Methoxy on C3 (lower right), hydroxyl on C4 (bottom).
	var om := _add(atoms, bonds, "O", _dir(-30.0) * (AROM_R + 1.36), ring[2])
	var cm := _add(atoms, bonds, "C", (atoms[om][1] as Vector3) + _dir(30.0) * 1.43, om)
	var pm: Vector3 = atoms[cm][1]
	_add(atoms, bonds, "H", pm + Vector3(0.9, 0.5, 0.0).normalized() * 1.09, cm)
	_add(atoms, bonds, "H", pm + Vector3(0.3, -0.6, 0.75).normalized() * 1.09, cm)
	_add(atoms, bonds, "H", pm + Vector3(0.3, -0.6, -0.75).normalized() * 1.09, cm)
	var oh := _add(atoms, bonds, "O", _dir(-90.0) * (AROM_R + 1.36), ring[3])
	_add(atoms, bonds, "H", (atoms[oh][1] as Vector3) + _dir(-150.0) * 0.96, oh)
	for k in [1, 4, 5]:
		_add(atoms, bonds, "H", _dir(90.0 - 60.0 * float(k)) * (AROM_R + 1.08), ring[k])
	if chain:
		var ca := _add(atoms, bonds, "C", _dir(90.0) * (AROM_R + 1.47), ring[0])
		var pa: Vector3 = atoms[ca][1]
		_add(atoms, bonds, "H", pa + _dir(160.0) * 1.08, ca)
		var cb := _add(atoms, bonds, "C", pa + _dir(40.0) * 1.34, ca, 2)
		var pb: Vector3 = atoms[cb][1]
		_add(atoms, bonds, "H", pb + _dir(-30.0) * 1.08, cb)
		var cg := _add(atoms, bonds, "C", pb + _dir(100.0) * 1.50, cb)
		var pg: Vector3 = atoms[cg][1]
		_add(atoms, bonds, "H", pg + Vector3(-0.8, 0.1, 0.6).normalized() * 1.09, cg)
		_add(atoms, bonds, "H", pg + Vector3(-0.5, 0.3, -0.8).normalized() * 1.09, cg)
		var og := _add(atoms, bonds, "O", pg + _dir(40.0) * 1.43, cg)
		_add(atoms, bonds, "H", (atoms[og][1] as Vector3) + _dir(100.0) * 0.96, og)
	else:
		_add(atoms, bonds, "H", _dir(90.0) * (AROM_R + 1.08), ring[0])
	return {"atoms": atoms, "bonds": bonds}


static func _ethylene() -> Dictionary:
	var atoms: Array = []
	var bonds: Array = []
	var a := _add(atoms, bonds, "C", Vector3(-0.665, 0, 0))
	var b := _add(atoms, bonds, "C", Vector3(0.665, 0, 0), a, 2)
	for s in [[a, 120.0], [a, -120.0], [b, 60.0], [b, -60.0]]:
		_add(atoms, bonds, "H", (atoms[int(s[0])][1] as Vector3) + _dir(float(s[1])) * 1.08, int(s[0]))
	return {"atoms": atoms, "bonds": bonds}


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
		var h := p + (d * 0.35 + Vector3(0, 0, 0.9 if i % 2 == 0 else -0.9)).normalized() * 1.09
		atoms.append(["H", h])
		bonds.append([i, atoms.size() - 1, 1])
	# The oxygens hanging off ring carbons 1..4 carry the hydroxyl H.
	for oi in [7, 8, 9, 10]:
		var o: Vector3 = atoms[oi][1]
		var cpos: Vector3 = atoms[oi - 6][1]
		var d2 := (o - cpos).normalized()
		var h2 := o + (d2 + Vector3(0, 0, 0.5)).normalized() * 0.96
		atoms.append(["H", h2])
		bonds.append([oi, atoms.size() - 1, 1])
	return {"atoms": atoms, "bonds": bonds}


static func _hexagon() -> Dictionary:
	var atoms: Array = []
	var bonds: Array = []
	for i in 6:
		atoms.append(["C", _dir(90.0 - 60.0 * float(i)) * 1.42])
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


# ---------------------------------------------------------------------------
# Storyboards
# ---------------------------------------------------------------------------

## What each reaction looks like: kind → [storyboard]. A storyboard is
## {id, title, text, from: [[species, region, Vector3 Å]], to: [...]}:
## where each molecule's middle stands before and after, on one stage
## (x right, y up, the stage's middle at the origin). Species "*" in `from`
## is whatever the volume holds most of in that region (boiling takes what
## is in the pool) and "=" in `to` gives the same species back. Regions:
## solid (stays put), liquid, gas (drifts off once free), gas_condensable.
## Kinds are the model's (TcProcSim.react_rate) plus "plastic": pyrolysis of
## a plastic charge.
static func stories() -> Dictionary:
	if not _stories.is_empty():
		return _stories
	var s := {}
	# Hemicellulose: the second link of two loses two waters and leaves as furfural.
	var x2 := centroid("xylan2")
	var xb := Vector3(2.0 * RING_R + 2.51, 0, 0) - x2      # the second link's ring, on the stage
	var wood: Array = [
		{"id": "hemicellulose", "title": "Hemicellulose breaks down (from about 220 °C)",
			"text": "Hemicellulose: the bond between two sugar links breaks. One link stays in the chain; the other loses two waters and leaves as furfural, part of the smoke and wood vinegar.",
			"from": [["xylan2", "solid", Vector3.ZERO]],
			"to": [["xylan", "solid", centroid("xylan") - x2], ["furfural", "gas", xb + Vector3(1.6, 1.4, 0)],
				["H2O", "gas", xb + Vector3(-0.6, -3.6, 0)], ["H2O", "gas", xb + Vector3(3.4, -2.6, 0)]]},
	]
	var c2 := centroid("cellulose2")
	var cb := Vector3(2.0 * RING_R + 2.51, 0, 0) - c2
	wood.append({"id": "cellulose", "title": "Cellulose unzips (from about 315 °C)",
		"text": "Cellulose: the chain unzips one glucose link at a time. The freed link closes on itself and leaves as levoglucosan, the main tar vapour.",
		"from": [["cellulose2", "solid", Vector3.ZERO]],
		"to": [["glucose", "solid", centroid("glucose") - c2], ["tar", "gas", cb + Vector3(1.8, 1.6, 0)]]})
	var lg := centroid("lignin")
	wood.append({"id": "lignin", "title": "Lignin sheds its side chains (slowly, 250–500 °C)",
		"text": "Lignin: a ring unit loses the three-carbon chain that tied it into the wood. The ring leaves as guaiacol (the smell of smoke); the chain comes off as ethylene and carbon monoxide.",
		"from": [["lignin", "solid", Vector3.ZERO]],
		"to": [["guaiacol", "gas", centroid("guaiacol") - lg + Vector3(-0.6, -1.0, 0)], ["ethylene", "gas", Vector3(-2.6, 4.6, 0) - lg],
			["CO", "gas", Vector3(3.6, 4.4, 0) - lg]]})
	var g1 := centroid("glucose")
	var waters: Array = []
	for k in 5:
		waters.append(["H2O", "gas", _dir(55.0 + 72.0 * float(k)) * 5.2 * Vector3(1.2, 0.85, 1.0)])
	wood.append({"id": "charring", "title": "Charring",
		"text": "Charring: a sugar link gives up all its hydrogen and oxygen as five waters. What stays is carbon, joined into rings: char.",
		"from": [["glucose", "solid", Vector3.ZERO]],
		"to": [["char", "solid", -g1]] + waters})
	s["pyrolysis"] = wood
	s["plastic"] = [{"id": "plastic", "title": "The plastic's chains break",
		"text": "Cracking: heat snaps a long plastic chain. A shorter chain boils off as oil; the end that broke away leaves as propylene gas.",
		"from": [["alkane:10", "solid", Vector3.ZERO]],
		"to": [["alkane:7", "gas", Vector3(-2.2, 0.6, 0)], ["C3H6", "gas", Vector3(5.2, -1.2, 0)]]}]
	s["cracking"] = [{"id": "cracking", "title": "Tar cracks in the hot gas (above about 380 °C)",
		"text": "Tar cracking: a hot tar molecule splits into small gases that burn: four carbon monoxide, two methane, and a water.",
		"from": [["tar", "gas", Vector3.ZERO]],
		"to": [["CO", "gas", _dir(20.0) * 4.6], ["CO", "gas", _dir(75.0) * 4.2], ["CO", "gas", _dir(160.0) * 4.6],
			["CO", "gas", _dir(-110.0) * 4.2], ["CH4", "gas", _dir(120.0) * 4.4], ["CH4", "gas", _dir(-25.0) * 4.6],
			["H2O", "gas", _dir(-160.0) * 4.6]]}]
	s["combustion"] = [{"id": "combustion", "title": "Burning",
		"text": "Burning: methane meets two oxygen molecules and becomes carbon dioxide and two waters, giving off heat.",
		"from": [["CH4", "gas", Vector3(-0.4, 0, 0)], ["O2", "gas", Vector3(2.8, 1.5, 0)], ["O2", "gas", Vector3(2.8, -1.5, 0)]],
		"to": [["CO2", "gas", Vector3(-1.2, 0, 0)], ["H2O", "gas", Vector3(3.2, 2.2, 0)], ["H2O", "gas", Vector3(3.2, -2.2, 0)]]}]
	var near: Array = [Vector3(-1.5, -0.4, 0), Vector3(1.4, -0.7, 0.4), Vector3(0.0, 1.5, -0.3), Vector3(0.2, -2.6, 0.2)]
	var far: Array = [Vector3(-3.8, 1.5, 0), Vector3(3.8, 1.1, 0), Vector3(-0.5, 3.5, 0), Vector3(1.3, -3.4, 0)]
	var mk := func(sp: String, region: String, pts: Array) -> Array:
		var out: Array = []
		for p in pts:
			out.append([sp, region, p])
		return out
	s["drying"] = [{"id": "drying", "title": "Drying (100 °C)",
		"text": "Drying: water held in the wood takes up heat until the pull between its molecules lets go, and they leave as steam.",
		"from": mk.call("H2O", "solid", near), "to": mk.call("H2O", "gas", far)}]
	s["boiling"] = [{"id": "boiling", "title": "Boiling",
		"text": "Boiling: molecules in the liquid cling to each other. With enough heat they break free and leave as vapour.",
		"from": mk.call("*", "liquid", near), "to": mk.call("=", "gas", far)}]
	s["condensing"] = [{"id": "condensing", "title": "Condensing on the cold wall",
		"text": "Condensing: vapour meets the cold wall, loses its heat and its molecules gather back into liquid.",
		"from": mk.call("*", "gas_condensable", far), "to": mk.call("=", "liquid", near)}]
	_stories = s
	return s


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
