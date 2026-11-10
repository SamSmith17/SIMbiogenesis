class_name GraphSchemaLayout
extends RefCounted

## Arrangements for the freeform graph beyond Tidy's force layout. Each one is
## a pure function of the scope's items and wires and returns where every card
## goes (TOP-LEFT positions) plus the labelled REGIONS it laid out, which the
## canvas draws under the cards. Deterministic (no RNG), so the selftest can
## pin each one and the same graph always arranges the same way.
##
##   ring       machines round a circle (grouped by system, in flow order),
##              the stores they share inside it, the people in the middle;
##   clusters   one area per system (power, water, food & waste, fuel & heat,
##              materials, people), each laid out with the force layout on
##              its own wires and packed in rows;
##   swimlanes  one horizontal lane per system, columns in flow order: what
##              feeds what reads left to right;
##   grid       a compact grid sorted by system then type.
##
## `arrange(schema, items, conns, port_side, opts)` -> {positions: {id: Vector2},
## regions: [{ids, title, domain}]}. opts: spacing (px between cards).

const RING := "ring"
const CLUSTERS := "clusters"
const SWIMLANES := "swimlanes"
const GRID := "grid"
const SCHEMAS := [RING, CLUSTERS, SWIMLANES, GRID]
const LABELS := {
	RING: "Ring: machines round, stores inside",
	CLUSTERS: "Clusters by system",
	SWIMLANES: "Swimlanes by system",
	GRID: "Grid by system",
}

## The systems a node is sorted into, in display order. PEOPLE is a habitat.
const PEOPLE := "people"
const ORDER := [GraphDomainFilter.POWER, GraphDomainFilter.WATER, GraphDomainFilter.FOOD,
	PEOPLE, GraphDomainFilter.FUEL, GraphDomainFilter.MATERIALS, GraphDomainFilter.OTHER]
const TITLES := {
	"power": "Power", "water": "Water", "food": "Food, nutrients & waste", "people": "People",
	"fuel": "Fuel & heat", "materials": "Materials", "other": "Other",
}
const COLORS := {
	"power": Color(0.98, 0.74, 0.26), "water": Color(0.30, 0.80, 0.95),
	"food": Color(0.45, 0.85, 0.40), "people": Color(0.72, 0.58, 1.00),
	"fuel": Color(0.98, 0.52, 0.22), "materials": Color(0.78, 0.74, 0.92),
	"other": Color(0.62, 0.66, 0.72),
}

const DEFAULT_SPACING := 56.0
## Swimlanes: cards stacked in one column of a lane before it wraps.
const LANE_STACK := 3


static func arrange(schema: String, items: Array, conns: Array,
		port_side: Callable = Callable(), opts: Dictionary = {}) -> Dictionary:
	if items.is_empty():
		return {"positions": {}, "regions": []}
	match schema:
		RING:
			return ring(items, conns, port_side, opts)
		CLUSTERS:
			return clusters(items, conns, port_side, opts)
		SWIMLANES:
			return swimlanes(items, conns, port_side, opts)
		GRID:
			return grid(items, conns, opts)
	return {"positions": {}, "regions": []}


# ---------------------------------------------------------------------------
# What system a node belongs to
# ---------------------------------------------------------------------------

## A node's system: a store's by what it holds; a habitat is PEOPLE; anything
## else by the most of its RESOURCE wires (an AC supply wire does not make a
## pump a power node). A node with only electrical wires is POWER.
static func domain_of(item: Dictionary, conns: Array) -> String:
	var t := str(item.get("type", ""))
	var sp: Dictionary = item.get("specs", {})
	if str(sp.get("role", "")) == "habitat":
		return PEOPLE
	if t == "resource":
		return GraphDomainFilter.kind_domain(str(sp.get("resource_kind", "")))
	if t in ["battery", "controller", "panel", "wind", "smartbattery", "shelly4pm", "appliance", "acload"]:
		return GraphDomainFilter.POWER
	if t == "catchment":
		return GraphDomainFilter.WATER
	var iid := str(item.get("id", ""))
	var count := {}
	var electric := 0
	for c in conns:
		var cd: Dictionary = c
		if str(cd.get("source_item_id", "")) != iid and str(cd.get("target_item_id", "")) != iid:
			continue
		if str(cd.get("polarity", "")) != "resource":
			electric += 1
			continue
		var d := GraphDomainFilter.conn_domain(cd)
		if d == GraphDomainFilter.AMBIENT:
			continue
		count[d] = int(count.get(d, 0)) + 1
	if count.is_empty():
		# No wires yet: the node's own ports say what it is.
		for io in (sp.get("inputs", []) as Array) + (sp.get("outputs", []) as Array):
			var k := str((io as Dictionary).get("kind", ""))
			if k in ["electric", "dc_electricity"]:
				continue
			var d2 := GraphDomainFilter.kind_domain(k)
			if d2 != GraphDomainFilter.AMBIENT:
				count[d2] = int(count.get(d2, 0)) + 1
	if count.is_empty():
		return GraphDomainFilter.POWER if electric > 0 or t == "compound" else GraphDomainFilter.OTHER
	var best := ""
	var best_n := -1
	for d3 in ORDER:
		if int(count.get(d3, 0)) > best_n:
			best_n = int(count.get(d3, 0))
			best = d3
	return best


## Stores are what the ring puts inside (tanks, bins and batteries).
static func is_store(item: Dictionary) -> bool:
	var t := str(item.get("type", ""))
	if t in ["resource", "battery", "smartbattery"]:
		return true
	return false


## Flow layer of every node (longest path from a source along directed
## wires; an undirected wire does not order). Cycles are cut where met.
static func flow_layers(items: Array, conns: Array, port_side: Callable) -> Dictionary:
	var by_id := {}
	for it in items:
		by_id[str((it as Dictionary).get("id", ""))] = it
	var out_e := {}
	var indeg := {}
	for iid in by_id:
		out_e[iid] = []
		indeg[iid] = 0
	for c in conns:
		var cd: Dictionary = c
		var a := str(cd.get("source_item_id", ""))
		var b := str(cd.get("target_item_id", ""))
		if a == b or not by_id.has(a) or not by_id.has(b):
			continue
		var dir := 1
		if port_side.is_valid():
			var ys := float(port_side.call(by_id[a], str(cd.get("source_handle_id", ""))))
			var yt := float(port_side.call(by_id[b], str(cd.get("target_handle_id", ""))))
			dir = GraphForceLayout.edge_direction(ys, yt)
		elif str(cd.get("polarity", "")) != "resource":
			dir = 0
		if dir == 0:
			continue
		if dir < 0:
			var tmp := a
			a = b
			b = tmp
		(out_e[a] as Array).append(b)
		indeg[b] = int(indeg[b]) + 1
	# Kahn's order; what is left in a cycle starts from its smallest id.
	var layer := {}
	var ready: Array = []
	for iid in by_id:
		if int(indeg[iid]) == 0:
			ready.append(iid)
	ready.sort()
	var done := {}
	while done.size() < by_id.size():
		if ready.is_empty():
			var rest: Array = []
			for iid in by_id:
				if not done.has(iid):
					rest.append(iid)
			rest.sort()
			ready.append(rest[0])
		var cur: String = ready.pop_front()
		if done.has(cur):
			continue
		done[cur] = true
		var l := int(layer.get(cur, 0))
		layer[cur] = l
		var nxt: Array = (out_e[cur] as Array).duplicate()
		nxt.sort()
		for b2 in nxt:
			if done.has(b2):
				continue
			layer[b2] = maxi(int(layer.get(b2, 0)), l + 1)
			indeg[b2] = int(indeg[b2]) - 1
			if int(indeg[b2]) <= 0:
				ready.append(b2)
	return layer


static func _size(it: Dictionary) -> Vector2:
	return Vector2(maxf(float(it.get("width", 120.0)), 8.0), maxf(float(it.get("height", 90.0)), 8.0))


static func _centroid(items: Array) -> Vector2:
	var s := Vector2.ZERO
	for it in items:
		var d: Dictionary = it
		s += Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0))) + _size(d) * 0.5
	return s / float(maxi(items.size(), 1))


static func _neighbours(conns: Array) -> Dictionary:
	var nb := {}
	for c in conns:
		var cd: Dictionary = c
		var a := str(cd.get("source_item_id", ""))
		var b := str(cd.get("target_item_id", ""))
		if a == b:
			continue
		if not nb.has(a):
			nb[a] = []
		if not nb.has(b):
			nb[b] = []
		(nb[a] as Array).append(b)
		(nb[b] as Array).append(a)
	return nb


static func _regions_for(groups: Dictionary) -> Array:
	var out: Array = []
	for d in ORDER:
		if groups.has(d) and not (groups[d] as Array).is_empty():
			var ids: Array = []
			for it in (groups[d] as Array):
				ids.append(str((it as Dictionary).get("id", "")) if it is Dictionary else str(it))
			out.append({"ids": ids, "title": str(TITLES.get(d, d)), "domain": d})
	return out


## Item ids grouped by system, each list sorted by (flow layer, type, id).
static func _grouped(items: Array, conns: Array, layer: Dictionary) -> Dictionary:
	var groups := {}
	for it in items:
		var d: Dictionary = it
		var dom := domain_of(d, conns)
		if not groups.has(dom):
			groups[dom] = []
		(groups[dom] as Array).append(d)
	for dom in groups:
		(groups[dom] as Array).sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var la := int(layer.get(str(a.get("id", "")), 0))
			var lb := int(layer.get(str(b.get("id", "")), 0))
			if la != lb:
				return la < lb
			var ta := str(a.get("type", ""))
			var tb := str(b.get("type", ""))
			if ta != tb:
				return ta < tb
			return str(a.get("id", "")) < str(b.get("id", "")))
	return groups


# ---------------------------------------------------------------------------
# Ring
# ---------------------------------------------------------------------------

## Machines on an outer ring, one arc per system in flow order; the stores
## they share on an inner ring, each at the mean angle of the machines wired
## to it (so a wire runs short and inward); the people in the middle.
static func ring(items: Array, conns: Array, port_side: Callable, opts: Dictionary = {}) -> Dictionary:
	var gap := float(opts.get("spacing", DEFAULT_SPACING))
	var layer := flow_layers(items, conns, port_side)
	var centre := _centroid(items)
	var outer: Array = []
	var inner: Array = []
	var middle: Array = []
	var dom_of := {}
	for it in items:
		var d: Dictionary = it
		var dom := domain_of(d, conns)
		dom_of[str(d.get("id", ""))] = dom
		if dom == PEOPLE:
			middle.append(d)
		elif is_store(d):
			inner.append(d)
		else:
			outer.append(d)
	# Outer order: systems in ORDER, inside a system by flow layer.
	var groups := _grouped(outer, conns, layer)
	var ordered: Array = []
	for dom in ORDER:
		if groups.has(dom):
			ordered.append_array(groups[dom])
	# The ring is as big as its cards need: each takes its diagonal + a gap,
	# and a gap twice as wide between two systems.
	var arc := 0.0
	for i in ordered.size():
		var d2: Dictionary = ordered[i]
		arc += _size(d2).length() + gap
		if i > 0 and dom_of[str(d2["id"])] != dom_of[str((ordered[i - 1] as Dictionary)["id"])]:
			arc += gap * 2.0
	if ordered.size() > 1:
		arc += gap * 2.0
	# Inner ring needs room for the stores too, and a middle for the people.
	var inner_arc := 0.0
	for s in inner:
		inner_arc += _size(s).length() + gap * 0.6
	var mid_r := 0.0
	for m in middle:
		mid_r = maxf(mid_r, _size(m).length() * 0.5)
	var r_inner := maxf(inner_arc / TAU, mid_r + gap * 2.0 + 60.0)
	var max_store := 0.0
	for s2 in inner:
		max_store = maxf(max_store, _size(s2).length())
	var max_mach := 0.0
	for m2 in ordered:
		max_mach = maxf(max_mach, _size(m2).length())
	var r_outer := maxf(arc / TAU, r_inner + (max_store + max_mach) * 0.5 + gap * 2.0)
	var pos := {}
	var angle := {}
	var a := -PI * 0.5
	for i2 in ordered.size():
		var d3: Dictionary = ordered[i2]
		var w := _size(d3).length() + gap
		if i2 > 0 and dom_of[str(d3["id"])] != dom_of[str((ordered[i2 - 1] as Dictionary)["id"])]:
			a += gap * 2.0 / r_outer
		a += w * 0.5 / r_outer
		angle[str(d3["id"])] = a
		pos[str(d3["id"])] = centre + Vector2(cos(a), sin(a)) * r_outer - _size(d3) * 0.5
		a += w * 0.5 / r_outer
	# Stores: the circular mean of their wired machines' angles.
	var nb := _neighbours(conns)
	var want: Array = []
	for s3 in inner:
		var sid := str((s3 as Dictionary).get("id", ""))
		var v := Vector2.ZERO
		for o in (nb.get(sid, []) as Array):
			if angle.has(o):
				v += Vector2(cos(float(angle[o])), sin(float(angle[o])))
		var th: float = v.angle() if v.length() > 1e-6 else -PI * 0.5 + TAU * float(want.size()) / float(maxi(inner.size(), 1))
		want.append([th, sid, s3])
	want.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]) if float(x[0]) != float(y[0]) else str(x[1]) < str(y[1]))
	# Spread them so neighbours on the inner ring do not overlap: each needs
	# its own angular width; sweep once round, pushing forward.
	var widths: Array = []
	var total := 0.0
	for e in want:
		var ww := (_size(e[2]).length() + gap * 0.6) / r_inner
		widths.append(ww)
		total += ww
	if total > TAU:
		r_inner *= total / TAU
		for k in widths.size():
			widths[k] = float(widths[k]) * TAU / total
	var placed := _spread_on_circle(want, widths)
	for k4 in want.size():
		var it4: Dictionary = want[k4][2]
		var th4 := float(placed[k4])
		pos[str(want[k4][1])] = centre + Vector2(cos(th4), sin(th4)) * r_inner - _size(it4) * 0.5
	# People in the middle, side by side.
	var mx := -float(middle.size() - 1) * 0.5
	for m3 in middle:
		var md: Dictionary = m3
		pos[str(md["id"])] = centre + Vector2(mx * (_size(md).x + gap), 0.0) - _size(md) * 0.5
		mx += 1.0
	# Regions: one per system on the outer ring (the stores inside belong to
	# the same system's region only by colour — the region box is its arc).
	var regions := _regions_for(groups)
	if not middle.is_empty():
		var ids: Array = []
		for m4 in middle:
			ids.append(str((m4 as Dictionary)["id"]))
		regions.append({"ids": ids, "title": "People", "domain": PEOPLE})
	return {"positions": pos, "regions": regions,
		"ring": {"centre": centre, "r_outer": r_outer, "r_inner": r_inner}}


## Angles for cards that want to sit at `want[k][0]` (sorted) but each need
## `widths[k]` of the circle (radians, summing to at most TAU): neighbours
## that overlap are pushed apart, both ways, round and round; if that does
## not settle, the cards are dealt out in order from the first one's angle.
static func _spread_on_circle(want: Array, widths: Array) -> Array:
	var n := want.size()
	var placed: Array = []
	for e in want:
		placed.append(float(e[0]))
	if n < 2:
		return placed
	for _pass in 80:
		var worst := 0.0
		for k in n:
			var nx := (k + 1) % n
			var a := float(placed[k])
			var b := float(placed[nx]) + (TAU if nx == 0 else 0.0)
			var need := (float(widths[k]) + float(widths[nx])) * 0.5
			var short := need - (b - a)
			if short > 1e-6:
				worst = maxf(worst, short)
				placed[k] = a - short * 0.5
				placed[nx] = float(placed[nx]) + short * 0.5
		if worst < 1e-5:
			return placed
	# Fallback: deal them out in order, each after the last.
	var th := float(placed[0])
	var out: Array = [th]
	for k2 in range(1, n):
		th += (float(widths[k2 - 1]) + float(widths[k2])) * 0.5
		out.append(th)
	return out


# ---------------------------------------------------------------------------
# Clusters
# ---------------------------------------------------------------------------

## One area per system: each laid out by the force layout on its own wires
## (so a cluster reads as a small graph), then the areas packed in rows,
## widest first, about as wide as they are tall overall.
static func clusters(items: Array, conns: Array, port_side: Callable, opts: Dictionary = {}) -> Dictionary:
	var gap := float(opts.get("spacing", DEFAULT_SPACING))
	var layer := flow_layers(items, conns, port_side)
	var groups := _grouped(items, conns, layer)
	var boxes: Array = []   # [dom, local positions, size]
	for dom in ORDER:
		if not groups.has(dom):
			continue
		var members: Array = groups[dom]
		var ids := {}
		for m in members:
			ids[str((m as Dictionary)["id"])] = true
		var inner_conns: Array = []
		for c in conns:
			var cd: Dictionary = c
			if ids.has(str(cd.get("source_item_id", ""))) and ids.has(str(cd.get("target_item_id", ""))):
				inner_conns.append(cd)
		var local: Dictionary
		if members.size() == 1:
			local = {str((members[0] as Dictionary)["id"]): Vector2.ZERO}
		else:
			# Seed on a grid (a stacked start would leave the result to the
			# separation pass), then settle.
			var seeded: Array = _grid_seed(members, gap)
			local = GraphForceLayout.tidy(seeded, inner_conns, port_side,
				{"spacing": gap * 0.8, "link_length": 120.0, "gravity": 0.08})
		var r := _bounds(local, members)
		var shifted := {}
		for iid in local:
			shifted[iid] = (local[iid] as Vector2) - r.position
		boxes.append([dom, shifted, r.size])
	# Pack: rows of about sqrt(total area) wide.
	var area := 0.0
	for b in boxes:
		var sz: Vector2 = b[2]
		area += (sz.x + gap * 3.0) * (sz.y + gap * 3.0)
	var row_w := maxf(sqrt(area) * 1.3, 400.0)
	var origin := _centroid(items) - Vector2(row_w, sqrt(area)) * 0.5
	var pos := {}
	var x := 0.0
	var y := 0.0
	var row_h := 0.0
	var pad := gap * 3.0
	for b2 in boxes:
		var sz2: Vector2 = b2[2]
		if x > 0.0 and x + sz2.x > row_w:
			x = 0.0
			y += row_h + pad
			row_h = 0.0
		for iid2 in (b2[1] as Dictionary):
			pos[iid2] = origin + Vector2(x, y) + ((b2[1] as Dictionary)[iid2] as Vector2)
		x += sz2.x + pad
		row_h = maxf(row_h, sz2.y)
	return {"positions": pos, "regions": _regions_for(groups)}


static func _grid_seed(members: Array, gap: float) -> Array:
	var out: Array = []
	var cols := maxi(int(ceil(sqrt(float(members.size())))), 1)
	for i in members.size():
		var d: Dictionary = (members[i] as Dictionary).duplicate()
		d["x"] = float(i % cols) * (180.0 + gap)
		d["y"] = float(i / cols) * (160.0 + gap)
		out.append(d)
	return out


static func _bounds(local: Dictionary, members: Array) -> Rect2:
	var r := Rect2()
	var first := true
	for m in members:
		var d: Dictionary = m
		var iid := str(d["id"])
		if not local.has(iid):
			continue
		var rr := Rect2(local[iid] as Vector2, _size(d))
		r = rr if first else r.merge(rr)
		first = false
	return r


# ---------------------------------------------------------------------------
# Swimlanes
# ---------------------------------------------------------------------------

## One horizontal lane per system, columns by flow layer: sources on the
## left, sinks on the right, so a lane reads as its system's process line and
## a wire between lanes shows where two systems meet.
static func swimlanes(items: Array, conns: Array, port_side: Callable, opts: Dictionary = {}) -> Dictionary:
	var gap := float(opts.get("spacing", DEFAULT_SPACING))
	var layer := flow_layers(items, conns, port_side)
	var groups := _grouped(items, conns, layer)
	var max_layer := 0
	for iid in layer:
		max_layer = maxi(max_layer, int(layer[iid]))
	# Each lane's cards by column; a column taller than LANE_STACK cards
	# wraps into sub-columns side by side (nine grow beds on one step would
	# otherwise make one lane as tall as the rest together).
	var stacks_by_dom := {}
	var card_w := 0.0
	for dom in groups:
		var st := {}
		for m in (groups[dom] as Array):
			var md: Dictionary = m
			var l := int(layer.get(str(md["id"]), 0))
			if not st.has(l):
				st[l] = []
			(st[l] as Array).append(md)
			card_w = maxf(card_w, _size(md).x)
		stacks_by_dom[dom] = st
	var slot_w := card_w + gap * 0.6
	# Column widths shared by every lane, so a column is one flow step.
	var col_w: Array = []
	col_w.resize(max_layer + 1)
	col_w.fill(0.0)
	for dom2 in stacks_by_dom:
		var st2: Dictionary = stacks_by_dom[dom2]
		for l2 in st2:
			var subs := int(ceil(float((st2[l2] as Array).size()) / float(LANE_STACK)))
			col_w[l2] = maxf(float(col_w[l2]), float(subs) * slot_w - gap * 0.6)
	var col_x: Array = []
	var cx := 0.0
	for w in col_w:
		col_x.append(cx)
		if float(w) > 0.0:
			cx += float(w) + gap * 1.5
	var origin := _centroid(items) - Vector2(cx * 0.5, 0.0)
	var pos := {}
	var y := 0.0
	for dom3 in ORDER:
		if not stacks_by_dom.has(dom3):
			continue
		var st3: Dictionary = stacks_by_dom[dom3]
		var lane_h := 0.0
		for l3 in st3:
			var list: Array = st3[l3]
			var row_h := 0.0
			for k in list.size():
				row_h = maxf(row_h, _size(list[k] as Dictionary).y)
			for k2 in list.size():
				var m2d: Dictionary = list[k2]
				var sub := k2 / LANE_STACK
				var r := k2 % LANE_STACK
				pos[str(m2d["id"])] = origin + Vector2(float(col_x[l3]) + float(sub) * slot_w,
					y + float(r) * (row_h + gap * 0.6))
			lane_h = maxf(lane_h, float(mini(list.size(), LANE_STACK)) * (row_h + gap * 0.6) - gap * 0.6)
		y += lane_h + gap * 2.5
	# Centre the lanes vertically on the old centroid.
	var dy := -y * 0.5
	for iid2 in pos:
		pos[iid2] = (pos[iid2] as Vector2) + Vector2(0.0, dy)
	return {"positions": pos, "regions": _regions_for(groups)}


# ---------------------------------------------------------------------------
# Grid
# ---------------------------------------------------------------------------

## A compact grid, systems one after the other, each starting a new row.
static func grid(items: Array, conns: Array, opts: Dictionary = {}) -> Dictionary:
	var gap := float(opts.get("spacing", DEFAULT_SPACING)) * 0.6
	var groups := _grouped(items, conns, {})
	var cell := Vector2.ZERO
	for it in items:
		cell = cell.max(_size(it as Dictionary))
	var cols := maxi(int(ceil(sqrt(float(items.size()) * 1.6))), 1)
	var origin := _centroid(items) - Vector2(float(cols) * (cell.x + gap), 0.0) * 0.5
	var pos := {}
	var row := 0
	for dom in ORDER:
		if not groups.has(dom):
			continue
		var members: Array = groups[dom]
		for i in members.size():
			var d: Dictionary = members[i]
			var c := i % cols
			var r := row + i / cols
			# Centred in its cell, so mixed sizes still line up.
			pos[str(d["id"])] = origin + Vector2(float(c) * (cell.x + gap), float(r) * (cell.y + gap) + float(row) * gap) \
				+ (cell - _size(d)) * 0.5
		row += int(ceil(float(members.size()) / float(cols)))
	return {"positions": pos, "regions": _regions_for(groups)}
