class_name ToroidFlowLayout
extends RefCounted

## The Flows lens as an ENGINE seen in cross-section: a trunk down the
## middle with loops turning on either side of it.
##
## A living site is a heat engine: low-entropy sunlight comes in, does work,
## and leaves as heat. Some of that work keeps water, food and nutrients
## going round inside the site. The picture is a diagram of exactly that,
## not a strict Sankey (a band's width says which loop it is, not how much
## it carries; the amounts are on the pills and in the header):
##
##   * the TRUNK: every node that only touches the axis resource
##     (electricity) stands on a vertical line in the middle, sources on top.
##     What they make comes in from above; what is used leaves below as heat.
##   * LOOPS: every closed cycle of material flows is a RING, a rounded
##     racetrack beside the trunk, drawn as one bold band with its nodes on
##     it. Rings nest, the smallest loop innermost. Round every ring the flow
##     runs DOWN beside the trunk and back UP the far side.
##   * THROUGH-FLOWS: chains that are on no loop are open rings wrapped
##     round the loops on the trunk's side: in over the top (a tail), down
##     beside the trunk, out under the bottom (an arrow head).
##   * LINKS: every other flow (the work from the trunk to a machine, a flow
##     from one ring to another) is a thin line.
##
## Pure and deterministic. Same input and output shape as LoopSankeyLayout
## (so GraphFlowLens draws either), plus: nodes carry `shape` ("card" on the
## trunk, "disc" on a ring), `side`, `ring`, `frac`; ribbons carry `band`
## (drawn bold along a ring) or `link` (thin), and `tail` / `arrow` on a
## through-flow's ends; the result carries `shape: "torus"`, `rings`,
## `guides` ([{path, width}]) and `axis`.
##
## Geometry: a ring is a rounded rectangle round the lobe centre
## (side * a, 0), half width `hw`, half height `hh`, corner radius `r`. A
## place on it is `frac`, the share of its perimeter from the top centre
## going toward the trunk (0 top, ~0.25 beside the trunk, 0.5 bottom, ~0.75
## the far side).

## Half width of the innermost ring's hole.
const RING_HOLE := 34.0
## How much taller than wide a ring is at least (half the straight side).
const RING_STRAIGHT := 62.0
const RING_GAP := 20.0
const BAND_MIN := 12.0
const BAND_MAX := 38.0
const LINK_MIN := 1.5
const LINK_MAX := 4.5
const NODE_D := 46.0
const NODE_GAP := 30.0
const AXIS_GAP := 22.0
const AXIS_NODE_H := 40.0
const AXIS_LAYER_GAP := 70.0
const AXIS_ROW_GAP := 26.0
## A through-flow ring's arms reach this share of its half width past the
## top (and bottom) centre, away from the trunk.
const ARM_SHARE := 0.6
## A chain this long gets a ring of its own; shorter ones share.
const CHAIN_OWN_RING := 3
const OPEN_CAP := 9
## Loose nodes wired together stay on one lobe up to this many.
const LOOSE_WHOLE_MAX := 8
## A web of cycles up to this many nodes keeps all its loops on one lobe.
const SAME_LOBE_MAX := 16
## No lobe takes more than this share of the lobe nodes in the refinement.
const SIDE_MAX := 0.68


# --- the ring curve ----------------------------------------------------------

static func ring_perimeter(rg: Dictionary) -> float:
	var hw := float(rg["hw"])
	var hh := float(rg["hh"])
	var r := float(rg["r"])
	return 4.0 * (hw - r) + 4.0 * (hh - r) + TAU * r


## The point at `frac` of the ring's perimeter, for the lobe whose centre is
## `a` from the axis.
static func ring_pt(a: float, rg: Dictionary, frac: float) -> Vector2:
	var hw := float(rg["hw"])
	var hh := float(rg["hh"])
	var r := float(rg["r"])
	var sx := hw - r
	var sy := hh - r
	var q := PI * r * 0.5
	var d := fposmod(frac, 1.0) * (4.0 * sx + 4.0 * sy + 4.0 * q)
	# (u, v): u toward the trunk, v down.
	var u := 0.0
	var v := 0.0
	if d < sx:
		u = d
		v = -hh
	elif d < sx + q:
		var t := (d - sx) / maxf(r, 1e-6)
		u = sx + r * sin(t)
		v = -sy - r * cos(t)
	elif d < sx + q + 2.0 * sy:
		u = hw
		v = -sy + (d - sx - q)
	elif d < sx + 2.0 * q + 2.0 * sy:
		var t2 := (d - sx - q - 2.0 * sy) / maxf(r, 1e-6)
		u = sx + r * cos(t2)
		v = sy + r * sin(t2)
	elif d < 3.0 * sx + 2.0 * q + 2.0 * sy:
		u = sx - (d - sx - 2.0 * q - 2.0 * sy)
		v = hh
	elif d < 3.0 * sx + 3.0 * q + 2.0 * sy:
		var t3 := (d - 3.0 * sx - 2.0 * q - 2.0 * sy) / maxf(r, 1e-6)
		u = -sx - r * sin(t3)
		v = sy + r * cos(t3)
	elif d < 3.0 * sx + 3.0 * q + 4.0 * sy:
		u = -hw
		v = sy - (d - 3.0 * sx - 3.0 * q - 2.0 * sy)
	elif d < 3.0 * sx + 4.0 * q + 4.0 * sy:
		var t4 := (d - 3.0 * sx - 3.0 * q - 4.0 * sy) / maxf(r, 1e-6)
		u = -sx - r * cos(t4)
		v = -sy - r * sin(t4)
	else:
		u = -sx + (d - 3.0 * sx - 4.0 * q - 4.0 * sy)
		v = -hh
	return Vector2(float(int(rg["side"])) * (a - u), v)


## The ring from `f0` to `f1` (f1 > f0 runs with the flow) as a polyline.
static func ring_path(a: float, rg: Dictionary, f0: float, f1: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var length := absf(f1 - f0) * ring_perimeter(rg)
	var steps := clampi(int(ceil(length / 7.0)), 2, 400)
	for i in steps + 1:
		out.append(ring_pt(a, rg, lerpf(f0, f1, float(i) / float(steps))))
	return out


## The place on ring `ring_index` of a laid-out torus nearest to `p`:
## [point, distance]. An open ring only offers its own stretch.
static func nearest_on_ring(lay: Dictionary, ring_index: int, p: Vector2) -> Array:
	var rs: Array = lay.get("rings", [])
	if ring_index < 0 or ring_index >= rs.size():
		return [p, INF]
	var rg: Dictionary = rs[ring_index]
	var a := float(lay.get("lobe_a", 0.0))
	var f0 := float(rg["f0"])
	var f1 := float(rg["f1"])
	var best := p
	var best_d := INF
	for i in 361:
		var q := ring_pt(a, rg, lerpf(f0, f1, float(i) / 360.0))
		var d := q.distance_to(p)
		if d < best_d:
			best_d = d
			best = q
	return [best, best_d]


# --- the layout --------------------------------------------------------------

static func layout(nodes: Array, edges: Array, boundary_in: Array = [],
		boundary_out: Array = [], opts: Dictionary = {}) -> Dictionary:
	var style: Dictionary = GraphFlowStyle.resolve(opts.get("style", {"preset": "sankey",
		"screen_space": false, "min_px": 2.0}))
	style["thickness"] = float(opts.get("thickness", LoopSankeyLayout.DEF_THICKNESS))
	style["screen_space"] = false
	var axis_key := str(opts.get("axis_key", "electricity"))
	var min_w := float(opts.get("min_node_w", LoopSankeyLayout.DEF_MIN_NODE_W)) * 0.72
	var ring_gap := maxf(4.0, float(opts.get("ring_gap", RING_GAP)))

	# --- nodes and edges, sorted for determinism -------------------------
	var ids: Array = []
	var label_of := {}
	for nv in nodes:
		var nid := str((nv as Dictionary).get("id", ""))
		if nid.is_empty() or label_of.has(nid):
			continue
		ids.append(nid)
		label_of[nid] = str((nv as Dictionary).get("label", nid))
	ids.sort()
	var idx := {}
	for i in ids.size():
		idx[ids[i]] = i
	var E: Array = []
	for ev in edges:
		var ed: Dictionary = ev
		var ea := str(ed.get("a", ""))
		var eb := str(ed.get("b", ""))
		var val := float(ed.get("value", 0.0))
		if not idx.has(ea) or not idx.has(eb) or val <= 0.0 or ea == eb:
			continue
		E.append({"id": str(ed.get("id", "%s>%s" % [ea, eb])), "a": ea, "b": eb,
			"key": str(ed.get("key", "")), "value": val,
			"conn_ids": ed.get("conn_ids", [str(ed.get("id", ""))])})
	E.sort_custom(func(x, y) -> bool: return str(x["id"]) < str(y["id"]))
	var bin: Array = LoopSankeyLayout._clean_boundary(boundary_in, idx)
	var bout: Array = LoopSankeyLayout._clean_boundary(boundary_out, idx)
	var n := ids.size()

	# --- per-resource scales ---------------------------------------------
	var given: Dictionary = opts.get("refs", {}) as Dictionary
	var refs: Dictionary = given.duplicate()
	for e0 in E:
		var k0 := str(e0["key"])
		if not given.has(k0):
			refs[k0] = maxf(float(refs.get(k0, 0.0)), float(e0["value"]))
	for bl in [bin, bout]:
		for b0 in bl:
			var k1 := str(b0["key"])
			if not given.has(k1):
				refs[k1] = maxf(float(refs.get(k1, 0.0)), float(b0["value"]))
	var wfn := func(key: String, value: float) -> float:
		return GraphFlowStyle.width_px(style, value, float(refs.get(key, value)), value > 0.0, 1.0)
	var ew := PackedFloat64Array()
	ew.resize(E.size())
	var in_px := PackedFloat64Array()
	var out_px := PackedFloat64Array()
	in_px.resize(n)
	out_px.resize(n)
	var touch_mat := PackedByteArray()
	touch_mat.resize(n)
	for ei in E.size():
		var e1: Dictionary = E[ei]
		ew[ei] = float(wfn.call(str(e1["key"]), float(e1["value"])))
		var ia := int(idx[e1["a"]])
		var ib := int(idx[e1["b"]])
		out_px[ia] += ew[ei]
		in_px[ib] += ew[ei]
		if str(e1["key"]) != axis_key:
			touch_mat[ia] = 1
			touch_mat[ib] = 1
	var bin_w := PackedFloat64Array()
	var bout_w := PackedFloat64Array()
	bin_w.resize(bin.size())
	bout_w.resize(bout.size())
	for bi in bin.size():
		var b1: Dictionary = bin[bi]
		bin_w[bi] = float(wfn.call(str(b1["key"]), float(b1["value"])))
		in_px[int(idx[b1["node"]])] += bin_w[bi]
		if str(b1["key"]) != axis_key:
			touch_mat[int(idx[b1["node"]])] = 1
	for bo in bout.size():
		var b2: Dictionary = bout[bo]
		bout_w[bo] = float(wfn.call(str(b2["key"]), float(b2["value"])))
		out_px[int(idx[b2["node"]])] += bout_w[bo]
		if str(b2["key"]) != axis_key:
			touch_mat[int(idx[b2["node"]])] = 1

	# --- who stands on the axis, who on a lobe ---------------------------
	var axis_nodes: Array = []
	var lobe_nodes: Array = []
	for i2 in n:
		if touch_mat[i2] == 0:
			axis_nodes.append(i2)
		else:
			lobe_nodes.append(i2)
	var axis_edges: Array = []
	var lobe_edges: Array = []
	var mixed_edges: Array = []
	for ei2 in E.size():
		var e2: Dictionary = E[ei2]
		var ma := touch_mat[int(idx[e2["a"]])]
		var mb := touch_mat[int(idx[e2["b"]])]
		if ma == 0 and mb == 0:
			axis_edges.append(ei2)
		elif ma == 1 and mb == 1:
			lobe_edges.append(ei2)
		else:
			mixed_edges.append(ei2)

	# --- the axis: layers top to bottom ----------------------------------
	var ord_a := _order(axis_nodes, axis_edges, E, idx, ew)
	var a_layer: Dictionary = ord_a["layer"]
	var a_pos: Dictionary = ord_a["pos"]
	var a_back: Dictionary = ord_a["back"]
	var max_layer := 0
	for g in axis_nodes:
		max_layer = maxi(max_layer, int(a_layer[g]))
	var rows: Array = []
	for L in max_layer + 1:
		rows.append([])
	for g2 in axis_nodes:
		(rows[int(a_layer[g2])] as Array).append(g2)
	var node_w := PackedFloat64Array()
	node_w.resize(n)
	for i3 in n:
		node_w[i3] = maxf(min_w, maxf(in_px[i3], out_px[i3]) + 12.0)
	var cx := PackedFloat64Array()
	var cy := PackedFloat64Array()
	cx.resize(n)
	cy.resize(n)
	var axis_half := 0.0
	for L2 in max_layer + 1:
		var r: Array = rows[L2]
		r.sort_custom(func(x, y) -> bool: return int(a_pos[x]) < int(a_pos[y]))
		var tot := -AXIS_ROW_GAP
		for g3 in r:
			tot += node_w[int(g3)] + AXIS_ROW_GAP
		var x0 := -tot * 0.5
		for g4 in r:
			cx[int(g4)] = x0 + node_w[int(g4)] * 0.5
			x0 += node_w[int(g4)] + AXIS_ROW_GAP
		axis_half = maxf(axis_half, tot * 0.5)
	if axis_nodes.is_empty():
		axis_half = 10.0

	# --- the lobes: loops, sides, shells ---------------------------------
	var ord_m := _order(lobe_nodes, lobe_edges, E, idx, ew)
	var m_pos: Dictionary = ord_m["pos"]
	var m_back: Dictionary = ord_m["back"]
	var m_layer: Dictionary = ord_m["layer"]
	var groups: Array = _peel_loops(ord_m, lobe_edges, E, idx, ew)
	var group_of := {}
	for gi in groups.size():
		for g5 in (groups[gi] as Array):
			group_of[int(g5)] = gi
	# Units to place on a side: each loop, then each loose node.
	var units: Array = []
	for gi2 in groups.size():
		var wsum := 0.0
		for g6 in (groups[gi2] as Array):
			wsum += maxf(in_px[int(g6)], out_px[int(g6)])
		units.append({"nodes": groups[gi2], "group": gi2, "w": wsum,
			"comp": int((ord_m["comp_of"] as Dictionary).get(int((groups[gi2] as Array)[0]), -1))})
	units.sort_custom(func(x, y) -> bool:
		if absf(float(x["w"]) - float(y["w"])) > 1e-9:
			return float(x["w"]) > float(y["w"])
		return int(x["group"]) < int(y["group"]))
	var loose: Array = []
	for g7 in lobe_nodes:
		if not group_of.has(int(g7)):
			loose.append(g7)
	loose.sort_custom(func(x, y) -> bool:
		if int(m_layer[x]) != int(m_layer[y]):
			return int(m_layer[x]) < int(m_layer[y])
		return int(m_pos[x]) < int(m_pos[y]))
	# Loose nodes wired to each other stay together (a chain split over the
	# two lobes would have to cross the axis).
	var chain_of := {}
	for g8 in loose:
		chain_of[int(g8)] = int(g8)
	for ei9 in lobe_edges:
		var e9: Dictionary = E[int(ei9)]
		var ca := int(idx[e9["a"]])
		var cb := int(idx[e9["b"]])
		if not chain_of.has(ca) or not chain_of.has(cb):
			continue
		while int(chain_of[ca]) != ca:
			ca = int(chain_of[ca])
		while int(chain_of[cb]) != cb:
			cb = int(chain_of[cb])
		if ca != cb:
			chain_of[maxi(ca, cb)] = mini(ca, cb)
	var chains := {}
	var chain_order: Array = []
	for g8b in loose:
		var root := int(g8b)
		while int(chain_of[root]) != root:
			root = int(chain_of[root])
		if not chains.has(root):
			chains[root] = []
			chain_order.append(root)
		(chains[root] as Array).append(g8b)
	for root2 in chain_order:
		var chain: Array = chains[root2]
		if chain.size() <= LOOSE_WHOLE_MAX:
			var cw := 0.0
			for g8c in chain:
				cw += maxf(in_px[int(g8c)], out_px[int(g8c)])
			units.append({"nodes": chain, "group": -1, "w": cw})
			continue
		# A big web of loose nodes would fill one lobe and leave the other
		# empty: place it node by node, walking outward from its heaviest
		# node, so neighbours stay together and the lobes balance.
		var in_chain := {}
		for g8d in chain:
			in_chain[int(g8d)] = true
		var adj_c := {}
		for g8e in chain:
			adj_c[int(g8e)] = []
		for ei10 in lobe_edges:
			var e10: Dictionary = E[int(ei10)]
			var xa := int(idx[e10["a"]])
			var xb := int(idx[e10["b"]])
			if in_chain.has(xa) and in_chain.has(xb):
				(adj_c[xa] as Array).append(xb)
				(adj_c[xb] as Array).append(xa)
		var start := int(chain[0])
		for g8f in chain:
			if maxf(in_px[int(g8f)], out_px[int(g8f)]) > maxf(in_px[start], out_px[start]) + 1e-9:
				start = int(g8f)
		var seen := {start: true}
		var queue: Array = [start]
		var head := 0
		while head < queue.size():
			var q := int(queue[head])
			head += 1
			var nxt: Array = adj_c[q]
			nxt.sort()
			for y in nxt:
				if not seen.has(int(y)):
					seen[int(y)] = true
					queue.append(int(y))
		for q2 in queue:
			units.append({"nodes": [q2], "group": -1, "w": maxf(in_px[int(q2)], out_px[int(q2)]), "single": true})
	var nb: Array = []
	nb.resize(n)
	for i4 in n:
		nb[i4] = []
	for ei3 in lobe_edges:
		var e3: Dictionary = E[int(ei3)]
		(nb[int(idx[e3["a"]])] as Array).append([int(idx[e3["b"]]), ew[int(ei3)]])
		(nb[int(idx[e3["b"]])] as Array).append([int(idx[e3["a"]]), ew[int(ei3)]])
	var side_of := {}
	# Loops cut from one web of cycles share nodes' flows: they stay on one
	# lobe (nested), or their ribbons would have to cross the axis.
	var comp_side := {}
	var comp_size := {}
	for cg in (ord_m["comps"] as Array).size():
		comp_size[cg] = ((ord_m["comps"] as Array)[cg] as Array).size()
	var count := {-1: 0, 1: 0}
	var lobe_total := maxi(1, lobe_nodes.size())
	for u in units:
		var conn := {-1: 0.0, 1: 0.0}
		var conn_tot := 0.0
		for g9 in (u["nodes"] as Array):
			for pr in (nb[int(g9)] as Array):
				conn_tot += float(pr[1])
				if side_of.has(int(pr[0])):
					conn[int(side_of[int(pr[0])])] = float(conn[int(side_of[int(pr[0])])]) + float(pr[1])
		var best := -1
		var best_s := -INF
		for s in [-1, 1]:
			var sc := float(conn[s]) / maxf(conn_tot, 1e-9) \
				- (1.0 if u.has("single") else (0.25 if int(u["group"]) < 0 else 1.6)) * float(int(count[s]) - int(count[-s])) / float(lobe_total)
			var ucomp := int(u.get("comp", -1))
			if ucomp >= 0 and comp_side.has(ucomp) and int(comp_side[ucomp]) == int(s) \
					and int(comp_size.get(ucomp, 0)) <= SAME_LOBE_MAX:
				sc += 2.0
			if sc > best_s + 1e-9:
				best_s = sc
				best = s
		if int(u.get("comp", -1)) >= 0 and not comp_side.has(int(u["comp"])):
			comp_side[int(u["comp"])] = best
		for g10 in (u["nodes"] as Array):
			side_of[int(g10)] = best
		count[best] = int(count[best]) + (u["nodes"] as Array).size()

	# Refine: a loose node with more flow to the other lobe than to its own
	# moves over (as long as neither lobe ends up with more than SIDE_MAX of
	# the nodes). Fewer flows then have to go round the axis.
	var movable: Array = []
	for u6 in units:
		if (u6 as Dictionary).has("single"):
			movable.append(int(((u6 as Dictionary)["nodes"] as Array)[0]))
	for _pass in 6:
		var moved := false
		for g19 in movable:
			var here := int(side_of[int(g19)])
			var w_same := 0.0
			var w_cross := 0.0
			for pr2 in (nb[int(g19)] as Array):
				if not side_of.has(int(pr2[0])):
					continue
				if int(side_of[int(pr2[0])]) == here:
					w_same += float(pr2[1])
				else:
					w_cross += float(pr2[1])
			if w_cross > w_same + 1e-9 and float(int(count[-here]) + 1) <= SIDE_MAX * float(lobe_total):
				side_of[int(g19)] = -here
				count[here] = int(count[here]) - 1
				count[-here] = int(count[-here]) + 1
				moved = true
		if not moved:
			break

	# The player can swap the lobes (opts.mirror): what was left goes right.
	if bool(opts.get("mirror", false)):
		for gm in side_of.keys():
			side_of[gm] = -int(side_of[gm])

	# --- rings: a closed ring per loop, then open rings for the chains ----
	var fwd_m := {}
	for gq in lobe_nodes:
		fwd_m[int(gq)] = []
	for eq in lobe_edges:
		if not m_back.has(int(eq)):
			var eqd: Dictionary = E[int(eq)]
			(fwd_m[int(idx[eqd["a"]])] as Array).append(int(idx[eqd["b"]]))
	var rings: Array = []
	var ring_of := {}
	var reach := 0.0
	var tall := 0.0
	for sd in [-1, 1]:
		var closed: Array = []
		for gi3 in groups.size():
			var gl: Array = groups[gi3]
			if int(side_of[int(gl[0])]) == sd:
				closed.append(gi3)
		closed.sort_custom(func(x, y) -> bool:
			var sx := (groups[int(x)] as Array).size()
			var sy := (groups[int(y)] as Array).size()
			if sx != sy:
				return sx < sy
			return int(x) < int(y))
		var prev := {}
		for gi4 in closed:
			var ring := {"side": sd, "nodes": groups[int(gi4)], "closed": true, "group": int(gi4),
				"index": rings.size()}
			_ring_band(ring, lobe_edges, E, idx, ew)
			_ring_size(ring, prev, ring_gap)
			var fr := {}
			var m1 := (ring["nodes"] as Array).size()
			for j in m1:
				fr[int((ring["nodes"] as Array)[j])] = 0.04 + float(j) / float(m1)
			ring["frac"] = fr
			for g11 in (ring["nodes"] as Array):
				ring_of[int(g11)] = rings.size()
			rings.append(ring)
			prev = ring
		# Chains: the longest paths through the loose nodes of this lobe get
		# a ring each; what is left shares rings, in flow order.
		var left := {}
		var loose_side: Array = []
		for g12 in loose:
			if int(side_of[int(g12)]) == sd:
				left[int(g12)] = true
				loose_side.append(int(g12))
		var open_lists: Array = []
		while true:
			var path := _longest_chain(loose_side, left, fwd_m)
			if path.size() < CHAIN_OWN_RING:
				break
			for pv in path:
				left.erase(int(pv))
			open_lists.append(path)
		var rest: Array = []
		for g13 in loose_side:
			if left.has(int(g13)):
				rest.append(int(g13))
		if not rest.is_empty():
			var S := int(ceil(float(rest.size()) / float(OPEN_CAP)))
			for si in S:
				var mem: Array = []
				for j2 in rest.size():
					if j2 % S == si:
						mem.append(rest[j2])
				open_lists.append(mem)
		for ol in open_lists:
			var ring2 := {"side": sd, "nodes": ol, "closed": false, "group": -1, "index": rings.size()}
			_ring_band(ring2, lobe_edges, E, idx, ew)
			_ring_size(ring2, prev, ring_gap)
			var fr2 := {}
			var m2 := (ol as Array).size()
			var pad := 40.0 / ring_perimeter(ring2)
			for j3 in m2:
				fr2[int((ol as Array)[j3])] = lerpf(float(ring2["f0"]) + pad, float(ring2["f1"]) - pad,
					(float(j3) + 0.5) / float(m2))
			ring2["frac"] = fr2
			for g14 in (ol as Array):
				ring_of[int(g14)] = rings.size()
			rings.append(ring2)
			prev = ring2
		if not prev.is_empty():
			reach = maxf(reach, float(prev["hw"]) + float(prev["half"]))
			tall = maxf(tall, float(prev["hh"]) + float(prev["half"]))
	var a := axis_half + AXIS_GAP + reach
	var y_span := maxf(tall * 0.8, float(max_layer) * (AXIS_NODE_H + AXIS_LAYER_GAP) * 0.5)
	y_span = maxf(y_span, 90.0)
	var y_ext := maxf(tall + 46.0, y_span + AXIS_NODE_H + 70.0)
	for g15 in axis_nodes:
		var Lg := int(a_layer[g15])
		cy[int(g15)] = 0.0 if max_layer == 0 else lerpf(-y_span, y_span, float(Lg) / float(max_layer))
	for g16 in lobe_nodes:
		var rg: Dictionary = rings[int(ring_of[int(g16)])]
		var p := ring_pt(a, rg, float((rg["frac"] as Dictionary)[int(g16)]))
		cx[int(g16)] = p.x
		cy[int(g16)] = p.y

	# --- node rects ------------------------------------------------------
	var out_nodes := {}
	for i5 in n:
		var through := maxf(in_px[i5], out_px[i5])
		if touch_mat[i5] == 0:
			out_nodes[ids[i5]] = {"rect": Rect2(Vector2(cx[i5] - node_w[i5] * 0.5, cy[i5] - AXIS_NODE_H * 0.5),
				Vector2(node_w[i5], AXIS_NODE_H)), "layer": int(a_layer[i5]), "order": int(a_pos[i5]),
				"through_px": through, "label": label_of[ids[i5]], "loop": -1, "shape": "card",
				"side": 0, "ring": -1, "frac": 0.0}
		else:
			var rg2: Dictionary = rings[int(ring_of[i5])]
			var d := maxf(NODE_D, float(rg2["band"]) + 10.0)
			out_nodes[ids[i5]] = {"rect": Rect2(Vector2(cx[i5] - d * 0.5, cy[i5] - d * 0.5), Vector2(d, d)),
				"layer": int(m_layer[i5]), "order": int(m_pos[i5]), "through_px": through,
				"label": label_of[ids[i5]], "loop": int(group_of.get(i5, -1)), "shape": "disc",
				"side": int(rg2["side"]), "ring": int(rg2["index"]),
				"frac": float((rg2["frac"] as Dictionary)[i5])}

	# --- ribbons ---------------------------------------------------------
	var ribbons: Array = []
	# Trunk slots: what enters a node's top and leaves its bottom, left to right.
	var top := {}
	var bot := {}
	for g17 in axis_nodes:
		top[int(g17)] = []
		bot[int(g17)] = []
	for ei4 in axis_edges:
		if a_back.has(int(ei4)):
			continue
		var e4: Dictionary = E[int(ei4)]
		var ua := int(idx[e4["a"]])
		var ub := int(idx[e4["b"]])
		(bot[ua] as Array).append({"k": "e%d" % int(ei4), "w": ew[int(ei4)], "x": cx[ub]})
		(top[ub] as Array).append({"k": "e%d" % int(ei4), "w": ew[int(ei4)], "x": cx[ua]})
	for bi2 in bin.size():
		var u2 := int(idx[(bin[bi2] as Dictionary)["node"]])
		if touch_mat[u2] == 0 and str((bin[bi2] as Dictionary).get("label", "")) != "from store":
			(top[u2] as Array).append({"k": "i%d" % bi2, "w": bin_w[bi2], "x": cx[u2]})
	for bo2 in bout.size():
		var u3 := int(idx[(bout[bo2] as Dictionary)["node"]])
		if touch_mat[u3] == 0 and str((bout[bo2] as Dictionary).get("label", "")) != "into store":
			(bot[u3] as Array).append({"k": "o%d" % bo2, "w": bout_w[bo2], "x": cx[u3]})
	var slot_x := {}
	for g18 in axis_nodes:
		for which in [0, 1]:
			var lst: Array = top[int(g18)] if which == 0 else bot[int(g18)]
			lst.sort_custom(func(x, y) -> bool:
				if absf(float(x["x"]) - float(y["x"])) > 1e-9:
					return float(x["x"]) < float(y["x"])
				return str(x["k"]) < str(y["k"]))
			var totw := 0.0
			for it in lst:
				totw += float(it["w"])
			var xs := cx[int(g18)] - totw * 0.5
			for it2 in lst:
				slot_x["%d|%d|%s" % [int(g18), which, str(it2["k"])]] = xs + float(it2["w"]) * 0.5
				xs += float(it2["w"])
	var half_h := AXIS_NODE_H * 0.5
	for ei5 in axis_edges:
		var e5: Dictionary = E[int(ei5)]
		var va := int(idx[e5["a"]])
		var vb := int(idx[e5["b"]])
		var apath: PackedVector2Array
		var kind := LoopSankeyLayout.KIND_FORWARD
		if a_back.has(int(ei5)):
			kind = LoopSankeyLayout.KIND_RETURN
			var sdx := -1.0 if (cx[va] + cx[vb]) <= 0.0 else 1.0
			apath = LoopSankeyLayout._return_path(Vector2(cx[va], cy[va] + half_h),
				Vector2(cx[vb], cy[vb] - half_h), sdx * (axis_half + 14.0 + ew[int(ei5)] * 0.5), 20.0)
		else:
			var x1 := float(slot_x.get("%d|1|e%d" % [va, int(ei5)], cx[va]))
			var x2 := float(slot_x.get("%d|0|e%d" % [vb, int(ei5)], cx[vb]))
			apath = LoopSankeyLayout._vbezier(Vector2(x1, cy[va] + half_h), Vector2(x2, cy[vb] - half_h), 16)
		ribbons.append(_rib(e5, ew[int(ei5)], apath, kind, -1, 0))
	# Lobe to lobe: along a ring (a band), or a thin link.
	var cross_off := {true: 0.0, false: 0.0}
	for ei6 in lobe_edges:
		var e6: Dictionary = E[int(ei6)]
		var wa := int(idx[e6["a"]])
		var wb := int(idx[e6["b"]])
		var ra: Dictionary = rings[int(ring_of[wa])]
		var rb: Dictionary = rings[int(ring_of[wb])]
		var kind2 := LoopSankeyLayout.KIND_RETURN if m_back.has(int(ei6)) else LoopSankeyLayout.KIND_FORWARD
		var loop := -1
		if group_of.has(wa) and group_of.has(wb) and int(group_of[wa]) == int(group_of[wb]):
			loop = int(group_of[wa])
		var sa := int(ra["side"])
		var A := Vector2(cx[wa], cy[wa])
		var B := Vector2(cx[wb], cy[wb])
		if (ra["ring_edges"] as Dictionary).has(int(ei6)):
			var fa := float((ra["frac"] as Dictionary)[wa])
			var fb := float((ra["frac"] as Dictionary)[wb])
			if fb <= fa:
				fb += 1.0
			var rbn := _rib(e6, float(ra["band"]), ring_path(a, ra, fa, fb), kind2, loop, sa)
			rbn["band"] = true
			ribbons.append(rbn)
			continue
		var lw := clampf(ew[int(ei6)] * 0.35, LINK_MIN, LINK_MAX)
		var lpath := PackedVector2Array()
		if sa == int(rb["side"]):
			# Across the lobe: bowed toward its middle.
			var C := Vector2(float(sa) * a, (A.y + B.y) * 0.5)
			for i6 in 25:
				lpath.append(A.bezier_interpolate(A.lerp(C, 0.5), B.lerp(C, 0.5), B, float(i6) / 24.0))
		else:
			# From one lobe to the other: round an END of the trunk, never
			# through it, each in its own lane.
			var over := (A.y + B.y) < 0.0
			var clear: float = y_ext + 20.0 + float(cross_off[over]) + lw * 0.5
			cross_off[over] = float(cross_off[over]) + lw + 4.0
			var yl := clear * (-1.0 if over else 1.0)
			var xa := A.x + signf(A.x) * minf(30.0, absf(A.x) * 0.15)
			var xb := B.x + signf(B.x) * minf(30.0, absf(B.x) * 0.15)
			lpath = LoopSankeyLayout.round_poly(PackedVector2Array([A, Vector2(xa, yl), Vector2(xb, yl), B]),
				minf(140.0, absf(xb - xa) * 0.45), false)
		var rbl := _rib(e6, lw, lpath, kind2, loop, sa)
		rbl["link"] = true
		ribbons.append(rbl)
	# Trunk to lobe (the work that drives a loop) and lobe to trunk: links.
	for ei7 in mixed_edges:
		var e7: Dictionary = E[int(ei7)]
		var qa := int(idx[e7["a"]])
		var qb := int(idx[e7["b"]])
		var from_axis := touch_mat[qa] == 0
		var ax := qa if from_axis else qb
		var lb := qb if from_axis else qa
		var sl := int((rings[int(ring_of[lb])] as Dictionary)["side"])
		var ap := Vector2(cx[ax] + float(sl) * node_w[ax] * 0.5, cy[ax])
		var np := Vector2(cx[lb], cy[lb])
		var reach_x := maxf(absf(np.x - ap.x) * 0.5, 20.0) * float(sl)
		var wpath := PackedVector2Array()
		for i7 in 25:
			var tt := float(i7) / 24.0
			if from_axis:
				wpath.append(ap.bezier_interpolate(ap + Vector2(reach_x, 0.0), np - Vector2(reach_x, 0.0), np, tt))
			else:
				wpath.append(np.bezier_interpolate(np - Vector2(reach_x, 0.0), ap + Vector2(reach_x, 0.0), ap, tt))
		var rbw := _rib(e7, clampf(ew[int(ei7)] * 0.35, LINK_MIN, LINK_MAX), wpath,
			LoopSankeyLayout.KIND_FORWARD, -1, sl)
		rbw["link"] = true
		rbw["work"] = from_axis
		ribbons.append(rbw)
	# Boundary flows. On the trunk: in from the top edge, out as heat below.
	# On a through-flow ring they are summed into its tail and its arrow.
	var store_flow := {}
	var ring_in := {}
	var ring_out := {}
	for bi3 in bin.size():
		var b3: Dictionary = bin[bi3]
		var u4 := int(idx[b3["node"]])
		var lab := str(b3.get("label", ""))
		if lab == "from store":
			# A store emptying is the store's own business: the node shows it.
			store_flow[ids[u4]] = float(store_flow.get(ids[u4], 0.0)) - bin_w[bi3]
			continue
		if touch_mat[u4] == 0:
			var xx := float(slot_x.get("%d|0|i%d" % [u4, bi3], cx[u4]))
			var y1 := cy[u4] - half_h
			var major := int(a_layer[u4]) == 0
			var y0 := -y_ext if major else y1 - AXIS_LAYER_GAP * 0.55
			ribbons.append({"id": "in:%d" % bi3, "conn_ids": [], "a": "", "b": str(b3["node"]),
				"key": str(b3["key"]), "value": float(b3["value"]), "width": bin_w[bi3],
				"path": PackedVector2Array([Vector2(xx, y0), Vector2(xx, lerpf(y0, y1, 0.5)), Vector2(xx, y1)]),
				"kind": LoopSankeyLayout.KIND_IN, "loop": -1, "side": 0, "label": lab, "major": major})
		else:
			var ri := int(ring_of[u4])
			var acc: Dictionary = ring_in.get(ri, {})
			acc[str(b3["key"])] = float(acc.get(str(b3["key"]), 0.0)) + float(b3["value"])
			ring_in[ri] = acc
	for bo3 in bout.size():
		var b4: Dictionary = bout[bo3]
		var u5 := int(idx[b4["node"]])
		var lab2 := str(b4.get("label", ""))
		if lab2 == "into store":
			store_flow[ids[u5]] = float(store_flow.get(ids[u5], 0.0)) + bout_w[bo3]
			continue
		var heat := str(b4["key"]) == axis_key
		if touch_mat[u5] == 0:
			var xx2 := float(slot_x.get("%d|1|o%d" % [u5, bo3], cx[u5]))
			var y2 := cy[u5] + half_h
			var major2 := int(a_layer[u5]) == max_layer
			var y3 := y_ext if major2 else y2 + AXIS_LAYER_GAP * 0.55
			ribbons.append({"id": "out:%d" % bo3, "conn_ids": [], "a": str(b4["node"]), "b": "",
				"key": str(b4["key"]), "value": float(b4["value"]), "width": bout_w[bo3],
				"path": PackedVector2Array([Vector2(xx2, y2), Vector2(xx2, lerpf(y2, y3, 0.5)), Vector2(xx2, y3)]),
				"kind": LoopSankeyLayout.KIND_OUT, "loop": -1, "side": 0,
				"label": "heat" if heat else lab2, "major": major2, "heat": heat})
		elif not heat:
			var ro := int(ring_of[u5])
			var acc2: Dictionary = ring_out.get(ro, {})
			acc2[str(b4["key"])] = float(acc2.get(str(b4["key"]), 0.0)) + float(b4["value"])
			ring_out[ro] = acc2
	for rg3 in rings:
		if bool(rg3["closed"]):
			continue
		var rnodes: Array = rg3["nodes"]
		var ri2 := int(rg3["index"])
		for which2 in [0, 1]:
			var accd: Dictionary = (ring_in if which2 == 0 else ring_out).get(ri2, {})
			if accd.is_empty():
				continue
			var bkey := ""
			var bval := 0.0
			var ks: Array = accd.keys()
			ks.sort()
			for k2 in ks:
				if float(accd[k2]) > bval:
					bval = float(accd[k2])
					bkey = str(k2)
			var endn := int(rnodes[0]) if which2 == 0 else int(rnodes[rnodes.size() - 1])
			var fe := float((rg3["frac"] as Dictionary)[endn])
			if which2 == 0:
				ribbons.append({"id": "in:r%d" % ri2, "conn_ids": [], "a": "", "b": str(ids[endn]),
					"key": bkey, "value": bval, "width": float(rg3["band"]),
					"path": ring_path(a, rg3, float(rg3["f0"]), fe), "kind": LoopSankeyLayout.KIND_IN,
					"loop": -1, "side": int(rg3["side"]), "label": "in", "major": true, "band": true, "tail": true})
			else:
				ribbons.append({"id": "out:r%d" % ri2, "conn_ids": [], "a": str(ids[endn]), "b": "",
					"key": bkey, "value": bval, "width": float(rg3["band"]),
					"path": ring_path(a, rg3, fe, float(rg3["f1"])), "kind": LoopSankeyLayout.KIND_OUT,
					"loop": -1, "side": int(rg3["side"]), "label": "out", "major": true, "band": true, "arrow": true})
	for sid in store_flow:
		(out_nodes[sid] as Dictionary)["store_flow"] = float(store_flow[sid])

	# --- loops, metrics, guides, bounds ----------------------------------
	var metrics := LoopSankeyLayout.cycling_metrics(ids, E, bin, bout)
	var loops: Array = []
	for gi5 in groups.size():
		var lm: Array = []
		for g19b in (groups[gi5] as Array):
			lm.append(ids[int(g19b)])
		var lk := {}
		for ei8 in lobe_edges:
			if not m_back.has(int(ei8)):
				continue
			var e8: Dictionary = E[int(ei8)]
			if int(group_of.get(int(idx[e8["a"]]), -1)) == gi5 and int(group_of.get(int(idx[e8["b"]]), -2)) == gi5:
				lk[str(e8["key"])] = float(lk.get(str(e8["key"]), 0.0)) + float(e8["value"])
		loops.append({"id": gi5, "nodes": lm, "returns": lk})
	for key in metrics:
		var cnt := 0
		for L3 in loops:
			if (L3["returns"] as Dictionary).has(key):
				cnt += 1
		(metrics[key] as Dictionary)["loops"] = cnt
	var guides: Array = []
	var rings_out: Array = []
	for rg5 in rings:
		guides.append({"path": ring_path(a, rg5, float(rg5["f0"]), float(rg5["f1"])),
			"width": float(rg5["band"]), "closed": bool(rg5["closed"])})
		rings_out.append({"side": int(rg5["side"]), "hw": float(rg5["hw"]), "hh": float(rg5["hh"]),
			"r": float(rg5["r"]), "closed": bool(rg5["closed"]), "f0": float(rg5["f0"]), "f1": float(rg5["f1"]),
			"band": float(rg5["band"]), "group": int(rg5["group"]), "index": int(rg5["index"])})
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for nid2 in out_nodes:
		var rr: Rect2 = out_nodes[nid2]["rect"]
		lo = lo.min(rr.position)
		hi = hi.max(rr.end)
	for rb2 in ribbons:
		for p2 in (rb2["path"] as PackedVector2Array):
			lo = lo.min(p2)
			hi = hi.max(p2)
	for gp3 in guides:
		for p3 in (gp3["path"] as PackedVector2Array):
			lo = lo.min(p3)
			hi = hi.max(p3)
	if n == 0:
		lo = Vector2.ZERO
		hi = Vector2.ZERO
	else:
		lo = lo.min(Vector2(0.0, -y_ext))
		hi = hi.max(Vector2(0.0, y_ext))
	var energy_in := 0.0
	var heat_out := 0.0
	for b5 in bin:
		if str(b5["key"]) == axis_key and str(b5.get("label", "")) != "from store":
			energy_in += float(b5["value"])
	for b6 in bout:
		if str(b6["key"]) == axis_key and str(b6.get("label", "")) != "into store":
			heat_out += float(b6["value"])
	var trunk_w := 0.0
	for b7 in bin.size():
		if str((bin[b7] as Dictionary)["key"]) == axis_key:
			trunk_w += bin_w[b7]
	return {"nodes": out_nodes, "ribbons": ribbons, "loops": loops, "metrics": metrics,
		"bounds": Rect2(lo - Vector2(50.0, 40.0), (hi - lo) + Vector2(100.0, 80.0)),
		"center_x": 0.0, "refs": refs, "layers": max_layer + 1, "returns": m_back.size() + a_back.size(),
		"shape": "torus", "guides": guides, "rings": rings_out, "lobe_a": a,
		"axis": {"y0": -y_ext, "y1": y_ext, "half": axis_half, "key": axis_key,
			"energy_in": energy_in, "heat_out": heat_out, "width": trunk_w}}


## Which of a ring's flows run ALONG it (from one node to the next one round
## the ring): those are drawn as the ring's band. Sets `ring_edges` and the
## band's width (one width for the whole ring: it names the loop, the amounts
## are on the pills).
static func _ring_band(ring: Dictionary, sub_e: Array, E: Array, idx: Dictionary, ew: PackedFloat64Array) -> void:
	var nodes: Array = ring["nodes"]
	var at := {}
	for i in nodes.size():
		at[int(nodes[i])] = i
	var taken := {}
	var ring_edges := {}
	var widest := 0.0
	for ei in sub_e:
		var e: Dictionary = E[int(ei)]
		var a := int(idx[e["a"]])
		var b := int(idx[e["b"]])
		if not at.has(a) or not at.has(b):
			continue
		var ia := int(at[a])
		var ib := int(at[b])
		var is_next := ib == ia + 1 or (bool(ring["closed"]) and ia == nodes.size() - 1 and ib == 0 and nodes.size() > 1)
		if not is_next or taken.has(ia):
			continue
		taken[ia] = true
		ring_edges[int(ei)] = true
		widest = maxf(widest, ew[int(ei)])
	ring["ring_edges"] = ring_edges
	ring["band"] = clampf(widest, BAND_MIN, BAND_MAX)


## Size a ring just outside `prev` (the ring inside it; {} for the first):
## a parallel offset, made taller where its nodes need the room. An open
## ring also gets its stretch `f0..f1`: from an arm over the top, down the
## trunk's side, to an arm under the bottom.
static func _ring_size(ring: Dictionary, prev: Dictionary, gap: float) -> void:
	var half := maxf(float(ring["band"]) * 0.5, NODE_D * 0.5)
	var hw := RING_HOLE + half
	var r := hw * 0.8
	var hh := hw + RING_STRAIGHT
	if not prev.is_empty():
		var d := float(prev["half"]) + gap + half
		hw = float(prev["hw"]) + d
		r = float(prev["r"]) + d
		hh = float(prev["hh"]) + d
	var need := float((ring["nodes"] as Array).size()) * (NODE_D + NODE_GAP)
	var arm := hw * ARM_SHARE
	if bool(ring["closed"]):
		hh = maxf(hh, r + (need - 4.0 * (hw - r) - TAU * r) * 0.25)
	else:
		hh = maxf(hh, r + (need + 80.0 - 2.0 * arm - 2.0 * (hw - r) - PI * r) * 0.5)
	ring["hw"] = hw
	ring["hh"] = hh
	ring["r"] = r
	ring["half"] = half
	var per := ring_perimeter(ring)
	ring["f0"] = 0.0 if bool(ring["closed"]) else -arm / per
	ring["f1"] = 1.0 if bool(ring["closed"]) else 0.5 + arm / per


## The longest chain of flows through the nodes still in `left` (in flow
## order). `order` lists them in a topological order.
static func _longest_chain(order: Array, left: Dictionary, fwd: Dictionary) -> Array:
	var best := {}
	var from := {}
	var tip := -1
	var tip_len := 0
	for v in order:
		if not left.has(int(v)):
			continue
		if not best.has(int(v)):
			best[int(v)] = 1
		if int(best[int(v)]) > tip_len:
			tip_len = int(best[int(v)])
			tip = int(v)
		for w in (fwd.get(int(v), []) as Array):
			if left.has(int(w)) and int(best.get(int(w), 1)) < int(best[int(v)]) + 1:
				best[int(w)] = int(best[int(v)]) + 1
				from[int(w)] = int(v)
				if int(best[int(w)]) > tip_len:
					tip_len = int(best[int(w)])
					tip = int(w)
	var out: Array = []
	var cur := tip
	while cur != -1:
		out.push_front(cur)
		cur = int(from.get(cur, -1))
	return out


static func _rib(e: Dictionary, w: float, path: PackedVector2Array, kind: String, loop: int, side: int) -> Dictionary:
	return {"id": str(e["id"]), "conn_ids": e["conn_ids"], "a": str(e["a"]), "b": str(e["b"]),
		"key": str(e["key"]), "value": float(e["value"]), "width": w, "path": path,
		"kind": kind, "loop": loop, "side": side}


## Order a sub-graph: its loops (strongly connected components, each in an
## Eades–Lin–Smyth order), the edges that close them (`back`), a position per
## node in a topological order of the rest, and longest-path layers.
## `sub` = node indices, `sub_e` = edge indices with both ends in `sub`.
## Returns {pos: {node: int}, layer: {node: int}, back: {edge: true},
##          comps: [[node...]] (loops only, in order), comp_of: {node: comp}}.
static func _order(sub: Array, sub_e: Array, E: Array, idx: Dictionary, ew: PackedFloat64Array) -> Dictionary:
	var m := sub.size()
	var loc := {}
	var idx2 := {}
	var adj: Array = []
	for i in m:
		loc[int(sub[i])] = i
		idx2[str(i)] = i
		adj.append([])
	var E2: Array = []
	var wn: Array = []
	for k in sub_e.size():
		var e: Dictionary = E[int(sub_e[k])]
		var la := int(loc[int(idx[e["a"]])])
		var lb := int(loc[int(idx[e["b"]])])
		E2.append({"a": str(la), "b": str(lb)})
		(adj[la] as Array).append(k)
		wn.append(ew[int(sub_e[k])])
	var comp := LoopSankeyLayout._tarjan(m, adj, E2, idx2)
	var comp_count := 0
	for c in comp:
		comp_count = maxi(comp_count, int(c) + 1)
	var members: Array = []
	for c2 in comp_count:
		members.append([])
	for i2 in m:
		(members[int(comp[i2])] as Array).append(i2)
	var order_pos := PackedInt32Array()
	order_pos.resize(m)
	var pos := 0
	var comps: Array = []
	var comp_of := {}
	for c3 in range(comp_count - 1, -1, -1):
		var mem: Array = members[c3]
		mem.sort()
		var seq: Array = mem
		if mem.size() > 1:
			seq = LoopSankeyLayout._els_order(mem, E2, idx2, wn)
			var glob: Array = []
			for mm in seq:
				glob.append(int(sub[int(mm)]))
				comp_of[int(sub[int(mm)])] = comps.size()
			comps.append(glob)
		for mm2 in seq:
			order_pos[int(mm2)] = pos
			pos += 1
	var back := {}
	var layer := PackedInt32Array()
	layer.resize(m)
	var fwd_out: Array = []
	for i3 in m:
		fwd_out.append([])
	for k2 in E2.size():
		var la2 := int((E2[k2] as Dictionary)["a"])
		var lb2 := int((E2[k2] as Dictionary)["b"])
		if comp[la2] == comp[lb2] and order_pos[lb2] <= order_pos[la2]:
			back[int(sub_e[k2])] = true
		else:
			(fwd_out[la2] as Array).append(lb2)
	var by_order: Array = range(m)
	by_order.sort_custom(func(x, y) -> bool: return order_pos[int(x)] < order_pos[int(y)])
	for i4 in by_order:
		for t in (fwd_out[int(i4)] as Array):
			layer[int(t)] = maxi(layer[int(t)], layer[int(i4)] + 1)
	var pos_d := {}
	var layer_d := {}
	for i5 in m:
		pos_d[int(sub[i5])] = order_pos[i5]
		layer_d[int(sub[i5])] = layer[i5]
	return {"pos": pos_d, "layer": layer_d, "back": back, "comps": comps, "comp_of": comp_of}


## Cut every loop component into LOOPS, each for its own shell: for each
## closing edge (heaviest first) the cycle is that edge plus the shortest
## forward path back; nodes not yet on a loop form a new one. What is left
## joins the loop of its heaviest neighbour. Each loop is in flow order.
static func _peel_loops(ord: Dictionary, sub_e: Array, E: Array, idx: Dictionary, ew: PackedFloat64Array) -> Array:
	var comps: Array = ord["comps"]
	var comp_of: Dictionary = ord["comp_of"]
	var back: Dictionary = ord["back"]
	var pos: Dictionary = ord["pos"]
	var groups: Array = []
	for ci in comps.size():
		var mem: Array = comps[ci]
		var fwd := {}
		var nbw := {}
		for g in mem:
			fwd[int(g)] = []
			nbw[int(g)] = []
		var rets: Array = []
		for ei in sub_e:
			var e: Dictionary = E[int(ei)]
			var a := int(idx[e["a"]])
			var b := int(idx[e["b"]])
			if int(comp_of.get(a, -1)) != ci or int(comp_of.get(b, -2)) != ci:
				continue
			(nbw[a] as Array).append([b, ew[int(ei)]])
			(nbw[b] as Array).append([a, ew[int(ei)]])
			if back.has(int(ei)):
				rets.append(int(ei))
			else:
				(fwd[a] as Array).append(b)
		rets.sort_custom(func(x, y) -> bool:
			if absf(ew[int(x)] - ew[int(y)]) > 1e-9:
				return ew[int(x)] > ew[int(y)]
			return int(x) < int(y))
		var assigned := {}
		var local: Array = []
		for r in rets:
			var er: Dictionary = E[int(r)]
			var u := int(idx[er["a"]])
			var v := int(idx[er["b"]])
			var path := _bfs(v, u, fwd)
			if path.is_empty():
				continue
			var fresh: Array = []
			for x in path:
				if not assigned.has(int(x)):
					fresh.append(int(x))
			if fresh.size() >= 2:
				for x2 in fresh:
					assigned[int(x2)] = local.size()
				local.append(fresh)
		if local.is_empty():
			local.append(mem.duplicate())
			for g2 in mem:
				assigned[int(g2)] = 0
		# Leftovers: the loop of the heaviest neighbour already placed.
		var left: Array = []
		for g3 in mem:
			if not assigned.has(int(g3)):
				left.append(int(g3))
		var guard := 0
		while not left.is_empty() and guard < 64:
			guard += 1
			var still: Array = []
			for g4 in left:
				var best := -1
				var best_w := -1.0
				for pr in (nbw[int(g4)] as Array):
					if assigned.has(int(pr[0])) and float(pr[1]) > best_w:
						best_w = float(pr[1])
						best = int(assigned[int(pr[0])])
				if best < 0:
					still.append(g4)
				else:
					assigned[int(g4)] = best
					(local[best] as Array).append(int(g4))
			if still.size() == left.size():
				for g5 in still:
					assigned[int(g5)] = 0
					(local[0] as Array).append(int(g5))
				still = []
			left = still
		for lg in local:
			(lg as Array).sort_custom(func(x, y) -> bool: return int(pos[x]) < int(pos[y]))
			groups.append(lg)
	return groups


static func _bfs(from: int, to: int, fwd: Dictionary) -> Array:
	if from == to:
		return []
	var prev := {from: -1}
	var queue: Array = [from]
	var head := 0
	while head < queue.size():
		var x := int(queue[head])
		head += 1
		if x == to:
			break
		for y in (fwd.get(x, []) as Array):
			if not prev.has(int(y)):
				prev[int(y)] = x
				queue.append(int(y))
	if not prev.has(to):
		return []
	var out: Array = []
	var cur := to
	while cur != -1:
		out.push_front(cur)
		cur = int(prev[cur])
	return out
