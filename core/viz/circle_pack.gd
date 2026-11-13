class_name CirclePack
extends RefCounted

## Circle packing of a tree (pure, deterministic, 64-bit floats).
##
## A tree node is a Dictionary:
##   {id, name, value (leaves), children: [nodes], color (optional Color),
##    unit, detail, data}
## A leaf's area is its value; a group is the smallest circle round its
## children. Siblings are packed by the front-chain algorithm of Wang et al.
## 2006 ("Visualization of large hierarchical data by circle packing", CHI),
## as d3-hierarchy's packSiblings does, and enclosed by Welzl's (1991)
## minimum enclosing circle, made iterative and deterministic as in d3
## (a fixed LCG shuffle). Ported from d3-hierarchy v3 (ISC licence).
##
##   layout(tree, opts) -> {nodes: [..], index: {id: i}, hidden, total}
##     opts: padding (layout units, the root's radius is RADIUS), sort
##     ("value" largest first, "none" as given)
##   Each laid node: {id, name, value, depth, parent, kids, x, y, r, color,
##   unit, detail, data, leaf}. Positions are in a frame with the root at
##   (0, 0) and radius RADIUS. Leaves with no value and groups left empty
##   are dropped (`hidden` counts them).
##
##   PALETTE: eight categorical hues stepped for the dark graph surface
##   (validated: lightness band, chroma, adjacent CVD ΔE ≥ 8.4, contrast
##   ≥ 3:1 on #0f1628). Circles of any two hues can touch, so every group
##   circle also carries its name (colour is never the only cue).

const RADIUS := 1000.0
const PALETTE := [Color("#3987e5"), Color("#d95926"), Color("#199e70"), Color("#c98500"),
	Color("#d55181"), Color("#008300"), Color("#9085e9"), Color("#e66767")]
const _EPS := 1e-6


## The categorical colour for slot `i` (wraps).
static func palette(i: int) -> Color:
	return PALETTE[posmod(i, PALETTE.size())]


static func layout(tree: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var nodes: Array = []
	var hidden := [0]
	var sort := str(opts.get("sort", "value"))
	_flatten(tree, -1, 0, nodes, hidden, sort)
	if nodes.is_empty():
		return {"nodes": [], "index": {}, "hidden": hidden[0], "total": 0.0}
	# Colours: a node with none takes its parent's; the root's children take
	# the palette in order.
	var slot := 0
	for i in nodes.size():
		var n: Dictionary = nodes[i]
		if n["color"] is Color:
			continue
		if int(n["depth"]) == 1:
			n["color"] = palette(slot)
			slot += 1
		elif int(n["parent"]) >= 0:
			n["color"] = (nodes[int(n["parent"])] as Dictionary)["color"]
		else:
			n["color"] = Color(0.55, 0.62, 0.75)
	# Leaf radii, then pack bottom-up twice (as d3.pack): once without
	# padding to learn the scale, then with the padding in final units.
	var pad := float(opts.get("padding", 6.0))
	for n in nodes:
		var d: Dictionary = n
		d["r"] = sqrt(float(d["value"])) if bool(d["leaf"]) else 0.0
		d["x"] = 0.0
		d["y"] = 0.0
	_pack_all(nodes, 0.0)
	var r0 := float((nodes[0] as Dictionary)["r"])
	if pad > 0.0 and r0 > 0.0:
		for n in nodes:
			var d2: Dictionary = n
			d2["r"] = sqrt(float(d2["value"])) if bool(d2["leaf"]) else 0.0
		_pack_all(nodes, pad * r0 / RADIUS)
	# Translate to absolute positions and scale the root to RADIUS.
	var root: Dictionary = nodes[0]
	var k := RADIUS / maxf(float(root["r"]), _EPS)
	root["x"] = 0.0
	root["y"] = 0.0
	root["r"] = RADIUS
	for i in range(1, nodes.size()):
		var c: Dictionary = nodes[i]
		var p: Dictionary = nodes[int(c["parent"])]
		c["x"] = float(p["x"]) + float(c["x"]) * k
		c["y"] = float(p["y"]) + float(c["y"]) * k
		c["r"] = float(c["r"]) * k
	var index := {}
	for i in nodes.size():
		index[str((nodes[i] as Dictionary)["id"])] = i
	return {"nodes": nodes, "index": index, "hidden": hidden[0], "total": float(root["value"])}


## Depth-first flatten (parents before children), sums the group values.
## Returns the node's index or -1 when dropped.
static func _flatten(t: Dictionary, parent: int, depth: int, out: Array, hidden: Array, sort: String) -> int:
	var kids_src: Array = t.get("children", []) as Array
	var leaf := kids_src.is_empty()
	var val := float(t.get("value", 0.0)) if leaf else 0.0
	if leaf and not (val > 0.0):
		hidden[0] += 1
		return -1
	var me := out.size()
	var col: Variant = t.get("color", null)
	out.append({"id": str(t.get("id", "n%d" % me)), "name": str(t.get("name", "")), "value": val,
		"depth": depth, "parent": parent, "kids": PackedInt32Array(), "x": 0.0, "y": 0.0, "r": 0.0,
		"color": col if col is Color else null, "unit": str(t.get("unit", "")),
		"detail": str(t.get("detail", "")), "data": t.get("data", {}), "leaf": leaf})
	if leaf:
		return me
	var order := kids_src.duplicate()
	if sort == "value":
		order.sort_custom(func(a: Variant, b: Variant) -> bool:
			return _sum_of(a as Dictionary) > _sum_of(b as Dictionary))
	var kids := PackedInt32Array()
	var sum := 0.0
	for c in order:
		var ci := _flatten(c as Dictionary, me, depth + 1, out, hidden, sort)
		if ci >= 0:
			kids.append(ci)
			sum += float((out[ci] as Dictionary)["value"])
	if kids.is_empty():
		out.resize(me)
		hidden[0] += 1
		return -1
	(out[me] as Dictionary)["kids"] = kids
	(out[me] as Dictionary)["value"] = sum
	return me


static func _sum_of(t: Dictionary) -> float:
	var kids: Array = t.get("children", []) as Array
	if kids.is_empty():
		return maxf(float(t.get("value", 0.0)), 0.0)
	var s := 0.0
	for c in kids:
		s += _sum_of(c as Dictionary)
	return s


## Pack every group's children (children before parents: reverse DFS order),
## each child grown by `pad` while packing. Child x, y end up RELATIVE to
## their parent's centre.
static func _pack_all(nodes: Array, pad: float) -> void:
	for i in range(nodes.size() - 1, -1, -1):
		var n: Dictionary = nodes[i]
		if bool(n["leaf"]):
			continue
		var kids: PackedInt32Array = n["kids"]
		var circles: Array = []
		for ci in kids:
			var c: Dictionary = nodes[ci]
			circles.append({"x": 0.0, "y": 0.0, "r": float(c["r"]) + pad})
		var e := pack_siblings(circles)
		for j in kids.size():
			var c2: Dictionary = nodes[kids[j]]
			c2["x"] = float(circles[j]["x"])
			c2["y"] = float(circles[j]["y"])
		n["r"] = e + pad


# ---------------------------------------------------------------------------
# Siblings (front chain) — circles are {x, y, r}; positions are written in
# place, centred on the enclosing circle; returns its radius.
# ---------------------------------------------------------------------------

static func pack_siblings(circles: Array) -> float:
	var n := circles.size()
	if n == 0:
		return 0.0
	var a: Dictionary = circles[0]
	a["x"] = 0.0
	a["y"] = 0.0
	if n == 1:
		return float(a["r"])
	var b: Dictionary = circles[1]
	a["x"] = -float(b["r"])
	b["x"] = float(a["r"])
	b["y"] = 0.0
	if n == 2:
		return float(a["r"]) + float(b["r"])
	_place(b, a, circles[2])
	# The front chain as a ring of indices: nxt / prv.
	var nxt := PackedInt32Array()
	var prv := PackedInt32Array()
	nxt.resize(n)
	prv.resize(n)
	var ia := 0
	var ib := 1
	var ic := 2
	nxt[ia] = ib
	prv[ib] = ia
	nxt[ib] = ic
	prv[ic] = ib
	nxt[ic] = ia
	prv[ia] = ic
	var i := 3
	var guard := 0
	while i < n:
		guard += 1
		if guard > n * n * 4 + 64:
			break
		var c: Dictionary = circles[i]
		_place(circles[ia], circles[ib], c)
		var j := nxt[ib]
		var k := prv[ia]
		var sj := float(circles[ib]["r"])
		var sk := float(circles[ia]["r"])
		var hit := false
		while true:
			if sj <= sk:
				if _intersects(circles[j], c):
					ib = j
					nxt[ia] = ib
					prv[ib] = ia
					hit = true
					break
				sj += float(circles[j]["r"])
				j = nxt[j]
			else:
				if _intersects(circles[k], c):
					ia = k
					nxt[ia] = ib
					prv[ib] = ia
					hit = true
					break
				sk += float(circles[k]["r"])
				k = prv[k]
			if j == nxt[k]:
				break
		if hit:
			continue
		# Insert c between a and b.
		prv[i] = ia
		nxt[i] = ib
		nxt[ia] = i
		prv[ib] = i
		ib = i
		# The new closest pair to the centroid.
		var best := ia
		var bs := _score(circles, ia, nxt[ia])
		var cc := nxt[i]
		while cc != ib:
			var sc := _score(circles, cc, nxt[cc])
			if sc < bs:
				best = cc
				bs = sc
			cc = nxt[cc]
		ia = best
		ib = nxt[ia]
		i += 1
	# Enclose the front chain.
	var chain: Array = [circles[ib]]
	var cc2 := nxt[ib]
	var g2 := 0
	while cc2 != ib and g2 <= n:
		chain.append(circles[cc2])
		cc2 = nxt[cc2]
		g2 += 1
	var e := enclose(chain)
	for c3 in circles:
		c3["x"] = float(c3["x"]) - float(e["x"])
		c3["y"] = float(c3["y"]) - float(e["y"])
	return float(e["r"])


static func _place(b: Dictionary, a: Dictionary, c: Dictionary) -> void:
	var dx := float(b["x"]) - float(a["x"])
	var dy := float(b["y"]) - float(a["y"])
	var d2 := dx * dx + dy * dy
	if d2 > 0.0:
		var a2 := float(a["r"]) + float(c["r"])
		a2 *= a2
		var b2 := float(b["r"]) + float(c["r"])
		b2 *= b2
		if a2 > b2:
			var x := (d2 + b2 - a2) / (2.0 * d2)
			var y := sqrt(maxf(0.0, b2 / d2 - x * x))
			c["x"] = float(b["x"]) - x * dx - y * dy
			c["y"] = float(b["y"]) - x * dy + y * dx
		else:
			var x2 := (d2 + a2 - b2) / (2.0 * d2)
			var y2 := sqrt(maxf(0.0, a2 / d2 - x2 * x2))
			c["x"] = float(a["x"]) + x2 * dx - y2 * dy
			c["y"] = float(a["y"]) + x2 * dy + y2 * dx
	else:
		c["x"] = float(a["x"]) + float(c["r"])
		c["y"] = float(a["y"])


static func _intersects(a: Dictionary, b: Dictionary) -> bool:
	var dr := float(a["r"]) + float(b["r"]) - 1e-6
	var dx := float(b["x"]) - float(a["x"])
	var dy := float(b["y"]) - float(a["y"])
	return dr > 0.0 and dr * dr > dx * dx + dy * dy


static func _score(circles: Array, ia: int, ib: int) -> float:
	var a: Dictionary = circles[ia]
	var b: Dictionary = circles[ib]
	var ab := float(a["r"]) + float(b["r"])
	var dx := (float(a["x"]) * float(b["r"]) + float(b["x"]) * float(a["r"])) / ab
	var dy := (float(a["y"]) * float(b["r"]) + float(b["y"]) * float(a["r"])) / ab
	return dx * dx + dy * dy


# ---------------------------------------------------------------------------
# Minimum enclosing circle of circles (Welzl, iterative, d3's form)
# ---------------------------------------------------------------------------

static func enclose(circles: Array) -> Dictionary:
	var list := circles.duplicate()
	# Deterministic shuffle (d3's LCG, seed 1).
	var s := [1.0]
	var m := list.size()
	while m > 0:
		var r := _lcg(s)
		var ii := int(r * m)
		m -= 1
		var t: Variant = list[m]
		list[m] = list[ii]
		list[ii] = t
	var i := 0
	var basis: Array = []
	var e: Dictionary = {}
	var guard := 0
	while i < list.size():
		guard += 1
		if guard > 100000:
			break
		var p: Dictionary = list[i]
		if not e.is_empty() and _encloses_weak(e, p):
			i += 1
		else:
			basis = _extend_basis(basis, p)
			e = _enclose_basis(basis)
			i = 0
	return e


static func _lcg(s: Array) -> float:
	s[0] = fmod(1664525.0 * float(s[0]) + 1013904223.0, 4294967296.0)
	return float(s[0]) / 4294967296.0


static func _extend_basis(b: Array, p: Dictionary) -> Array:
	if _encloses_weak_all(p, b):
		return [p]
	for i in b.size():
		if _encloses_not(p, b[i]) and _encloses_weak_all(_enclose2(b[i], p), b):
			return [b[i], p]
	for i in range(b.size() - 1):
		for j in range(i + 1, b.size()):
			if _encloses_not(_enclose2(b[i], b[j]), p) \
					and _encloses_not(_enclose2(b[i], p), b[j]) \
					and _encloses_not(_enclose2(b[j], p), b[i]) \
					and _encloses_weak_all(_enclose3(b[i], b[j], p), b):
				return [b[i], b[j], p]
	# Numerically degenerate: fall back to the pair that encloses most.
	return [b[0], p]


static func _encloses_not(a: Dictionary, b: Dictionary) -> bool:
	var dr := float(a["r"]) - float(b["r"])
	var dx := float(b["x"]) - float(a["x"])
	var dy := float(b["y"]) - float(a["y"])
	return dr < 0.0 or dr * dr < dx * dx + dy * dy


static func _encloses_weak(a: Dictionary, b: Dictionary) -> bool:
	var dr := float(a["r"]) - float(b["r"]) + maxf(maxf(float(a["r"]), float(b["r"])), 1.0) * 1e-9
	var dx := float(b["x"]) - float(a["x"])
	var dy := float(b["y"]) - float(a["y"])
	return dr > 0.0 and dr * dr > dx * dx + dy * dy


static func _encloses_weak_all(a: Dictionary, b: Array) -> bool:
	for c in b:
		if not _encloses_weak(a, c):
			return false
	return true


static func _enclose_basis(b: Array) -> Dictionary:
	match b.size():
		1:
			return {"x": float(b[0]["x"]), "y": float(b[0]["y"]), "r": float(b[0]["r"])}
		2:
			return _enclose2(b[0], b[1])
	return _enclose3(b[0], b[1], b[2])


static func _enclose2(a: Dictionary, b: Dictionary) -> Dictionary:
	var x1 := float(a["x"])
	var y1 := float(a["y"])
	var r1 := float(a["r"])
	var x2 := float(b["x"])
	var y2 := float(b["y"])
	var r2 := float(b["r"])
	var x21 := x2 - x1
	var y21 := y2 - y1
	var r21 := r2 - r1
	var l := sqrt(x21 * x21 + y21 * y21)
	if l <= 0.0:
		return {"x": x1, "y": y1, "r": maxf(r1, r2)}
	return {"x": (x1 + x2 + x21 / l * r21) / 2.0, "y": (y1 + y2 + y21 / l * r21) / 2.0, "r": (l + r1 + r2) / 2.0}


static func _enclose3(a: Dictionary, b: Dictionary, c: Dictionary) -> Dictionary:
	var x1 := float(a["x"])
	var y1 := float(a["y"])
	var r1 := float(a["r"])
	var x2 := float(b["x"])
	var y2 := float(b["y"])
	var r2 := float(b["r"])
	var x3 := float(c["x"])
	var y3 := float(c["y"])
	var r3 := float(c["r"])
	var a2 := x1 - x2
	var a3 := x1 - x3
	var b2 := y1 - y2
	var b3 := y1 - y3
	var c2 := r2 - r1
	var c3 := r3 - r1
	var d1 := x1 * x1 + y1 * y1 - r1 * r1
	var d2 := d1 - x2 * x2 - y2 * y2 + r2 * r2
	var d3 := d1 - x3 * x3 - y3 * y3 + r3 * r3
	var ab := a3 * b2 - a2 * b3
	if absf(ab) < 1e-12:
		return _enclose2(a, b) if float(a["r"]) + float(b["r"]) >= float(c["r"]) else _enclose2(a, c)
	var xa := (b2 * d3 - b3 * d2) / (ab * 2.0) - x1
	var xb := (b3 * c2 - b2 * c3) / ab
	var ya := (a3 * d2 - a2 * d3) / (ab * 2.0) - y1
	var yb := (a2 * c3 - a3 * c2) / ab
	var qa := xb * xb + yb * yb - 1.0
	var qb := 2.0 * (r1 + xa * xb + ya * yb)
	var qc := xa * xa + ya * ya - r1 * r1
	var r := 0.0
	if absf(qa) > 1e-6:
		r = -(qb + sqrt(maxf(qb * qb - 4.0 * qa * qc, 0.0))) / (2.0 * qa)
	else:
		r = -qc / qb
	return {"x": x1 + xa + xb * r, "y": y1 + ya + yb * r, "r": r}


# ---------------------------------------------------------------------------
# Helpers for views
# ---------------------------------------------------------------------------

## The chain of indices from the root to node `i` (root first).
static func path_to(nodes: Array, i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var c := i
	var guard := 0
	while c >= 0 and guard < 256:
		out.insert(0, c)
		c = int((nodes[c] as Dictionary)["parent"])
		guard += 1
	return out


## Every node's descendants count (a group's "N parts").
static func leaf_count(nodes: Array, i: int) -> int:
	var n: Dictionary = nodes[i]
	if bool(n["leaf"]):
		return 1
	var s := 0
	for k in (n["kids"] as PackedInt32Array):
		s += leaf_count(nodes, k)
	return s
