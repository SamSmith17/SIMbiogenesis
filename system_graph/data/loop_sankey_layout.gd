class_name LoopSankeyLayout
extends RefCounted

## A Sankey that can show loops (the Flows lens; plans: now-i-want-to-linked-garden).
##
## An ordinary Sankey flows one way. A closed system cycles: what leaves the
## bottom comes back to the top. This layout keeps the main stream flowing
## DOWN and draws what cycles back as RETURN ribbons that leave a node's
## bottom, swing out to the left or right of the column and climb back to the
## node they feed — nested by span, so a fully closed system reads as a
## dipole field and an open one as a waterfall with a few side loops.
##
## Pure and deterministic. Steps:
##   1. strongly connected components (Tarjan) — each one is a loop;
##   2. inside each loop, a feedback arc set (Eades–Lin–Smyth, weighted): the
##      LIGHTEST flows that close the loop become the returns;
##   3. longest-path layering of everything else (sources on top), with dummy
##      nodes where a ribbon spans several layers;
##   4. barycenter ordering to cut crossings, then x placement;
##   5. ribbon slots on each node's edges sorted by partner position;
##   6. returns routed outside the column, nested by span;
##   7. the network metrics: Finn's Cycling Index per resource.
##
## Each resource keeps its own scale (the user's decision): a ribbon's width
## is GraphFlowStyle.width_px of its value against the biggest flow of ITS
## resource, so widths only compare inside one resource.
##
## Input:
##   nodes: [{id, label}]
##   edges: [{id, a, b, key, value}]          (key = resource / scale key)
##   boundary_in:  [{node, key, value, label}] (from outside, into a node)
##   boundary_out: [{node, key, value, label}] (out of a node, to outside)
##   opts: {style (GraphFlowStyle), thickness (units), node_h, layer_gap,
##          node_gap, min_node_w, refs: {key: ref}}
## Output (graph units; the caller maps them to the screen):
##   {nodes: {id: {rect: Rect2, layer, order, dummy:false, through_px}},
##    ribbons: [{id, conn_ids, a, b, key, value, width, path, kind, loop, side}],
##    loops: [{id, nodes: [], keys: {key: cycled value}}],
##    metrics: {key: {fci, throughflow, boundary_in, boundary_out, cycled, loops}},
##    bounds: Rect2, center_x}

const KIND_FORWARD := "forward"
const KIND_RETURN := "return"
const KIND_IN := "in"
const KIND_OUT := "out"

const DEF_THICKNESS := 26.0
const DEF_NODE_H := 46.0
const DEF_LAYER_GAP := 120.0
const DEF_NODE_GAP := 34.0
const DEF_MIN_NODE_W := 150.0
const RETURN_MARGIN := 46.0
const RETURN_GAP := 6.0
const BAND_H := 70.0
const ORDER_SWEEPS := 6
const PLACE_PASSES := 6


static func layout(nodes: Array, edges: Array, boundary_in: Array = [],
		boundary_out: Array = [], opts: Dictionary = {}) -> Dictionary:
	var style: Dictionary = GraphFlowStyle.resolve(opts.get("style", {"preset": "sankey",
		"screen_space": false, "min_px": 2.0}))
	var thick := float(opts.get("thickness", DEF_THICKNESS))
	style["thickness"] = thick
	style["screen_space"] = false
	var node_h := float(opts.get("node_h", DEF_NODE_H))
	var layer_gap := float(opts.get("layer_gap", DEF_LAYER_GAP))
	var node_gap := float(opts.get("node_gap", DEF_NODE_GAP))
	var min_w := float(opts.get("min_node_w", DEF_MIN_NODE_W))
	var ret_gap := float(opts.get("return_gap", RETURN_MARGIN))

	# --- Nodes and edges, sorted for determinism ------------------------
	var ids: Array = []
	var label_of := {}
	for n in nodes:
		var nid := str((n as Dictionary).get("id", ""))
		if nid.is_empty() or label_of.has(nid):
			continue
		ids.append(nid)
		label_of[nid] = str((n as Dictionary).get("label", nid))
	ids.sort()
	var idx := {}
	for i in ids.size():
		idx[ids[i]] = i
	var E: Array = []
	for e in edges:
		var ed: Dictionary = e
		var a := str(ed.get("a", ""))
		var b := str(ed.get("b", ""))
		var v := float(ed.get("value", 0.0))
		if not idx.has(a) or not idx.has(b) or v <= 0.0:
			continue
		E.append({"id": str(ed.get("id", "%s>%s" % [a, b])), "a": a, "b": b,
			"key": str(ed.get("key", "")), "value": v,
			"conn_ids": ed.get("conn_ids", [str(ed.get("id", ""))])})
	E.sort_custom(func(x, y) -> bool: return str(x["id"]) < str(y["id"]))
	var bin: Array = _clean_boundary(boundary_in, idx)
	var bout: Array = _clean_boundary(boundary_out, idx)

	# --- Per-resource references (each resource its own scale) ----------
	var refs: Dictionary = (opts.get("refs", {}) as Dictionary).duplicate()
	for e in E:
		var k := str(e["key"])
		if not (opts.get("refs", {}) as Dictionary).has(k):
			refs[k] = maxf(float(refs.get(k, 0.0)), float(e["value"]))
	for bl in [bin, bout]:
		for b in bl:
			var k2 := str(b["key"])
			if not (opts.get("refs", {}) as Dictionary).has(k2):
				refs[k2] = maxf(float(refs.get(k2, 0.0)), float(b["value"]))
	var wfn := func(key: String, value: float) -> float:
		return GraphFlowStyle.width_px(style, value, float(refs.get(key, value)), value > 0.0, 1.0)

	# --- 1. strongly connected components --------------------------------
	var n := ids.size()
	var adj: Array = []
	adj.resize(n)
	for i in n:
		adj[i] = []
	var wnorm: Array = []   # per edge, value / its resource's ref (for the cut)
	for ei in E.size():
		var e: Dictionary = E[ei]
		(adj[int(idx[e["a"]])] as Array).append(ei)
		wnorm.append(float(e["value"]) / maxf(float(refs.get(str(e["key"]), 1.0)), 1e-12))
	var comp := _tarjan(n, adj, E, idx)
	var comp_count := 0
	for c in comp:
		comp_count = maxi(comp_count, int(c) + 1)
	var members: Array = []
	members.resize(comp_count)
	for c in comp_count:
		members[c] = []
	for i in n:
		(members[int(comp[i])] as Array).append(i)
	# Tarjan numbers components in reverse topological order: the last one
	# found is a source component. Walk them high to low.
	var order_pos := PackedInt32Array()
	order_pos.resize(n)
	var pos := 0
	var loop_of := PackedInt32Array()
	loop_of.resize(n)
	for i in n:
		loop_of[i] = -1
	var self_loop := {}
	for e in E:
		if str(e["a"]) == str(e["b"]):
			self_loop[int(idx[e["a"]])] = true
	var loop_ids: Array = []
	for c in range(comp_count - 1, -1, -1):
		var mem: Array = members[c]
		mem.sort()
		var seq: Array = mem
		if mem.size() > 1:
			seq = _els_order(mem, E, idx, wnorm)
		if mem.size() > 1 or self_loop.has(int(mem[0])):
			for m in mem:
				loop_of[int(m)] = loop_ids.size()
			loop_ids.append(c)
		for m in seq:
			order_pos[int(m)] = pos
			pos += 1

	# --- 2. returns = edges that close a loop backward in that order ----
	var fwd: Array = []
	var rets: Array = []
	for ei in E.size():
		var e: Dictionary = E[ei]
		var ia := int(idx[e["a"]])
		var ib := int(idx[e["b"]])
		if ia == ib or (loop_of[ia] >= 0 and loop_of[ia] == loop_of[ib] and order_pos[ib] <= order_pos[ia]):
			rets.append(ei)
		else:
			fwd.append(ei)

	# --- 3. longest-path layering on the forward edges -------------------
	var layer := PackedInt32Array()
	layer.resize(n)
	var by_order: Array = range(n)
	by_order.sort_custom(func(x, y) -> bool: return order_pos[int(x)] < order_pos[int(y)])
	var fwd_out: Array = []
	fwd_out.resize(n)
	for i in n:
		fwd_out[i] = []
	for ei in fwd:
		(fwd_out[int(idx[(E[ei] as Dictionary)["a"]])] as Array).append(ei)
	for i in by_order:
		for ei in (fwd_out[int(i)] as Array):
			var ib := int(idx[(E[ei] as Dictionary)["b"]])
			layer[ib] = maxi(layer[ib], layer[int(i)] + 1)
	# Pull sources down next to what they feed (a lone source at the top of a
	# long chain reads as a stranded node): a node with no forward inputs
	# sits one layer above its nearest consumer.
	for i in range(by_order.size() - 1, -1, -1):
		var u := int(by_order[i])
		var has_in := false
		for ej in fwd:
			if int(idx[(E[ej] as Dictionary)["b"]]) == u:
				has_in = true
				break
		if has_in or (fwd_out[u] as Array).is_empty():
			continue
		var lo := 1 << 30
		for ek in (fwd_out[u] as Array):
			lo = mini(lo, layer[int(idx[(E[ek] as Dictionary)["b"]])])
		layer[u] = maxi(layer[u], lo - 1)
	var max_layer := 0
	for i in n:
		max_layer = maxi(max_layer, layer[i])

	# --- Units: each forward edge becomes a chain through dummy nodes ---
	# A "unit" is a node or a dummy; every unit sits on one layer.
	var units: Array = []   # {id, layer, real (node index or -1), w}
	for i in n:
		units.append({"id": ids[i], "layer": layer[i], "real": i, "w": 0.0})
	var chains: Array = []  # per forward edge: [unit indices top to bottom]
	var unit_in: Array = []
	var unit_out: Array = []
	for ei in fwd:
		var e: Dictionary = E[ei]
		var ua := int(idx[e["a"]])
		var ub := int(idx[e["b"]])
		var w := float(wfn.call(str(e["key"]), float(e["value"])))
		var chain: Array = [ua]
		for L in range(layer[ua] + 1, layer[ub]):
			units.append({"id": "_d%d_%d" % [ei, L], "layer": L, "real": -1, "w": w, "edge": ei})
			chain.append(units.size() - 1)
		chain.append(ub)
		chains.append({"edge": ei, "units": chain, "w": w})
	var U := units.size()
	unit_in.resize(U)
	unit_out.resize(U)
	for u in U:
		unit_in[u] = []
		unit_out[u] = []
	for ch in chains:
		var cu: Array = ch["units"]
		for j in cu.size() - 1:
			(unit_out[int(cu[j])] as Array).append([int(cu[j + 1]), float(ch["w"])])
			(unit_in[int(cu[j + 1])] as Array).append([int(cu[j]), float(ch["w"])])

	# --- Node widths: the bigger of what goes in and what comes out -----
	var in_px := PackedFloat64Array()
	var out_px := PackedFloat64Array()
	in_px.resize(n)
	out_px.resize(n)
	for e in E:
		var w := float(wfn.call(str(e["key"]), float(e["value"])))
		out_px[int(idx[e["a"]])] += w
		in_px[int(idx[e["b"]])] += w
	for b in bin:
		in_px[int(idx[b["node"]])] += float(wfn.call(str(b["key"]), float(b["value"])))
	for b in bout:
		out_px[int(idx[b["node"]])] += float(wfn.call(str(b["key"]), float(b["value"])))
	for i in n:
		units[i]["through"] = maxf(in_px[i], out_px[i])
		units[i]["w"] = maxf(min_w, maxf(in_px[i], out_px[i]) + 12.0)

	# --- 4. ordering: barycenter sweeps over the layers -----------------
	var rows: Array = []
	rows.resize(max_layer + 1)
	for L in max_layer + 1:
		rows[L] = []
	for u in U:
		(rows[int(units[u]["layer"])] as Array).append(u)
	for L in max_layer + 1:
		(rows[L] as Array).sort_custom(func(x, y) -> bool:
			var ox := order_pos[int(units[int(x)]["real"])] if int(units[int(x)]["real"]) >= 0 else 1 << 20
			var oy := order_pos[int(units[int(y)]["real"])] if int(units[int(y)]["real"]) >= 0 else 1 << 20
			if ox != oy:
				return ox < oy
			return str(units[int(x)]["id"]) < str(units[int(y)]["id"]))
	var slot := PackedFloat64Array()
	slot.resize(U)
	for L in max_layer + 1:
		var r: Array = rows[L]
		for j in r.size():
			slot[int(r[j])] = float(j)
	for sweep in ORDER_SWEEPS:
		var down := sweep % 2 == 0
		var Ls: Array = range(1, max_layer + 1) if down else range(max_layer - 1, -1, -1)
		for L in Ls:
			var r: Array = rows[int(L)]
			var bary := {}
			for u in r:
				var nb: Array = unit_in[int(u)] if down else unit_out[int(u)]
				var sw := 0.0
				var sx := 0.0
				for pair in nb:
					sw += float(pair[1])
					sx += slot[int(pair[0])] * float(pair[1])
				bary[u] = sx / sw if sw > 0.0 else slot[int(u)]
			r.sort_custom(func(x, y) -> bool:
				var bx := float(bary[x])
				var by := float(bary[y])
				if absf(bx - by) > 1e-9:
					return bx < by
				return slot[int(x)] < slot[int(y)])
			for j in r.size():
				slot[int(r[j])] = float(j)

	# --- x placement: pack, then pull toward wired neighbours -----------
	var xc: Array = []
	xc.resize(U)
	xc.fill(0.0)
	for L in max_layer + 1:
		_pack_row(rows[L], units, xc, node_gap)
	for p in PLACE_PASSES:
		var down2 := p % 2 == 0
		var Ls2: Array = range(1, max_layer + 1) if down2 else range(max_layer - 1, -1, -1)
		for L in Ls2:
			var r2: Array = rows[int(L)]
			var want := {}
			for u in r2:
				var nb2: Array = (unit_in[int(u)] as Array) + (unit_out[int(u)] as Array)
				var sw2 := 0.0
				var sx2 := 0.0
				for pair in nb2:
					sw2 += float(pair[1]) + 1.0
					sx2 += xc[int(pair[0])] * (float(pair[1]) + 1.0)
				want[u] = sx2 / sw2 if sw2 > 0.0 else xc[int(u)]
			for u in r2:
				xc[int(u)] = float(want[u])
			_resolve_row(r2, units, xc, node_gap)
	# Centre the whole picture on x = 0.
	var lo_x := INF
	var hi_x := -INF
	for u in U:
		lo_x = minf(lo_x, xc[u] - float(units[u]["w"]) * 0.5)
		hi_x = maxf(hi_x, xc[u] + float(units[u]["w"]) * 0.5)
	if n == 0:
		lo_x = 0.0
		hi_x = 0.0
	var shift := -(lo_x + hi_x) * 0.5
	for u in U:
		xc[u] += shift
	lo_x += shift
	hi_x += shift
	var top_y := BAND_H if not bin.is_empty() else 0.0
	var ly := func(L: int) -> float:
		return top_y + float(L) * (node_h + layer_gap)

	# --- Node rects ------------------------------------------------------
	var out_nodes := {}
	for i in n:
		var w := float(units[i]["w"])
		out_nodes[ids[i]] = {"rect": Rect2(Vector2(xc[i] - w * 0.5, float(ly.call(layer[i]))), Vector2(w, node_h)),
			"layer": layer[i], "order": int(slot[i]), "through_px": float(units[i]["through"]),
			"label": label_of[ids[i]], "loop": loop_of[i]}

	# --- 5./6. ribbons ---------------------------------------------------
	# Each node edge has its slots: returns at the outer ends (left-side
	# returns at the left end, outermost loop outermost), forward ribbons
	# and boundary flows in the middle sorted by where they go.
	var ribbons: Array = []
	var ret_info: Array = []
	var center_x := 0.0
	for ri in rets:
		var e: Dictionary = E[ri]
		var ia := int(idx[e["a"]])
		var ib := int(idx[e["b"]])
		var span := absf(float(layer[ia] - layer[ib]))
		var mx := (float(xc[ia]) + float(xc[ib])) * 0.5
		var side := -1 if mx <= center_x else 1
		ret_info.append({"edge": ri, "a": ia, "b": ib, "span": span, "side": side,
			"w": float(wfn.call(str(e["key"]), float(e["value"])))})
	# Balance the sides: move the smallest returns off the heavier side.
	var side_w := {-1: 0.0, 1: 0.0}
	for r in ret_info:
		side_w[int(r["side"])] = float(side_w[int(r["side"])]) + float(r["w"])
	ret_info.sort_custom(func(x, y) -> bool:
		if float(x["w"]) != float(y["w"]):
			return float(x["w"]) < float(y["w"])
		return int(x["edge"]) < int(y["edge"]))
	for r in ret_info:
		var s := int(r["side"])
		if float(side_w[s]) > float(side_w[-s]) + float(r["w"]) * 2.0:
			side_w[s] = float(side_w[s]) - float(r["w"])
			side_w[-s] = float(side_w[-s]) + float(r["w"])
			r["side"] = -s
	# Lanes: nested by span, short loops inside.
	var lane_off := {-1: 0.0, 1: 0.0}
	ret_info.sort_custom(func(x, y) -> bool:
		if float(x["span"]) != float(y["span"]):
			return float(x["span"]) < float(y["span"])
		return int(x["edge"]) < int(y["edge"]))
	for r in ret_info:
		var s := int(r["side"])
		r["lane"] = float(lane_off[s]) + float(r["w"]) * 0.5
		lane_off[s] = float(lane_off[s]) + float(r["w"]) + RETURN_GAP
	# Slot lists per node: bottom (out) and top (in).
	var bot: Array = []
	var top: Array = []
	bot.resize(U)
	top.resize(U)
	for u in U:
		bot[u] = []
		top[u] = []
	for ch in chains:
		var cu2: Array = ch["units"]
		for j in cu2.size() - 1:
			var ua2 := int(cu2[j])
			var ub2 := int(cu2[j + 1])
			(bot[ua2] as Array).append({"t": "f", "ch": ch, "j": j, "w": float(ch["w"]), "to_x": xc[ub2], "order": 0})
			(top[ub2] as Array).append({"t": "f", "ch": ch, "j": j, "w": float(ch["w"]), "to_x": xc[ua2], "order": 0})
	for bi in bin.size():
		var b: Dictionary = bin[bi]
		var u3 := int(idx[b["node"]])
		(top[u3] as Array).append({"t": "in", "b": bi, "w": float(wfn.call(str(b["key"]), float(b["value"]))),
			"to_x": xc[u3], "order": 0})
	for bo in bout.size():
		var b2: Dictionary = bout[bo]
		var u4 := int(idx[b2["node"]])
		(bot[u4] as Array).append({"t": "out", "b": bo, "w": float(wfn.call(str(b2["key"]), float(b2["value"]))),
			"to_x": xc[u4], "order": 0})
	for r in ret_info:
		var lane := float(r["lane"])
		# Outermost lanes at the outer ends: order key pushes them out.
		var k := -100000.0 - lane if int(r["side"]) < 0 else 100000.0 + lane
		(bot[int(r["a"])] as Array).append({"t": "r", "r": r, "w": float(r["w"]), "to_x": k, "order": 0})
		(top[int(r["b"])] as Array).append({"t": "r", "r": r, "w": float(r["w"]), "to_x": k, "order": 0})
	var slot_x := {}   # key -> x centre of that slot
	for u in U:
		for edge_side in [0, 1]:
			var lst: Array = bot[u] if edge_side == 0 else top[u]
			if lst.is_empty():
				continue
			lst.sort_custom(func(x, y) -> bool:
				if float(x["to_x"]) != float(y["to_x"]):
					return float(x["to_x"]) < float(y["to_x"])
				return _slot_key(x) < _slot_key(y))
			var tot := 0.0
			for it in lst:
				tot += float(it["w"])
			var x0 := float(xc[u]) - tot * 0.5
			for it in lst:
				slot_x["%d|%d|%s" % [u, edge_side, _slot_key(it)]] = x0 + float(it["w"]) * 0.5
				x0 += float(it["w"])
	var y_top_of := func(u: int) -> float:
		return float(ly.call(int(units[u]["layer"])))
	var y_bot_of := func(u: int) -> float:
		var yy := float(ly.call(int(units[u]["layer"])))
		return yy + (node_h if int(units[u]["real"]) >= 0 else 0.0)
	# Forward ribbons: down through their dummies.
	for ch in chains:
		var e: Dictionary = E[int(ch["edge"])]
		var cu3: Array = ch["units"]
		var path := PackedVector2Array()
		for j in cu3.size() - 1:
			var ua3 := int(cu3[j])
			var ub3 := int(cu3[j + 1])
			var it_key := _slot_key({"t": "f", "ch": ch, "j": j})
			var x1 := float(slot_x.get("%d|0|%s" % [ua3, it_key], xc[ua3]))
			var x2 := float(slot_x.get("%d|1|%s" % [ub3, it_key], xc[ub3]))
			var y1 := float(y_bot_of.call(ua3))
			var y2 := float(y_top_of.call(ub3))
			var seg := _vbezier(Vector2(x1, y1), Vector2(x2, y2), 14)
			if path.size() > 0:
				seg = seg.slice(1)
			path.append_array(seg)
		var ia5 := int(idx[e["a"]])
		var ib5 := int(idx[e["b"]])
		var lp := loop_of[ia5] if loop_of[ia5] >= 0 and loop_of[ia5] == loop_of[ib5] else -1
		ribbons.append({"id": str(e["id"]), "conn_ids": e["conn_ids"], "a": str(e["a"]), "b": str(e["b"]),
			"key": str(e["key"]), "value": float(e["value"]), "width": float(ch["w"]), "path": path,
			"kind": KIND_FORWARD, "loop": lp, "side": 0})
	# Returns: down, out to the lane, up the side, in, and down into the target.
	var col_lo := lo_x
	var col_hi := hi_x
	for r in ret_info:
		var e2: Dictionary = E[int(r["edge"])]
		var ua4 := int(r["a"])
		var ub4 := int(r["b"])
		var key4 := _slot_key({"t": "r", "r": r})
		var xs := float(slot_x.get("%d|0|%s" % [ua4, key4], xc[ua4]))
		var xt := float(slot_x.get("%d|1|%s" % [ub4, key4], xc[ub4]))
		var ys := float(y_bot_of.call(ua4))
		var yt := float(y_top_of.call(ub4))
		var lane := float(r["lane"])
		var s2 := int(r["side"])
		var xl := (col_lo - ret_gap - lane) if s2 < 0 else (col_hi + ret_gap + lane)
		var dip := 22.0 + lane * 0.55
		var path2 := _return_path(Vector2(xs, ys), Vector2(xt, yt), xl, dip)
		ribbons.append({"id": str(e2["id"]), "conn_ids": e2["conn_ids"], "a": str(e2["a"]), "b": str(e2["b"]),
			"key": str(e2["key"]), "value": float(e2["value"]), "width": float(r["w"]), "path": path2,
			"kind": KIND_RETURN, "loop": loop_of[ua4], "side": s2})
	# Boundary flows: from the top band, to the bottom band.
	var bottom_y := float(ly.call(max_layer)) + node_h + layer_gap * 0.5 + BAND_H
	for bi2 in bin.size():
		var b3: Dictionary = bin[bi2]
		var u5 := int(idx[b3["node"]])
		var k5 := _slot_key({"t": "in", "b": bi2})
		var x5 := float(slot_x.get("%d|1|%s" % [u5, k5], xc[u5]))
		var y5 := float(y_top_of.call(u5))
		var p5 := _vbezier(Vector2(x5, y5 - BAND_H * 0.9), Vector2(x5, y5), 6)
		ribbons.append({"id": "in:%d" % bi2, "conn_ids": [], "a": "", "b": str(b3["node"]),
			"key": str(b3["key"]), "value": float(b3["value"]),
			"width": float(wfn.call(str(b3["key"]), float(b3["value"]))), "path": p5,
			"kind": KIND_IN, "loop": -1, "side": 0, "label": str(b3.get("label", ""))})
	for bo2 in bout.size():
		var b4: Dictionary = bout[bo2]
		var u6 := int(idx[b4["node"]])
		var k6 := _slot_key({"t": "out", "b": bo2})
		var x6 := float(slot_x.get("%d|0|%s" % [u6, k6], xc[u6]))
		var y6 := float(y_bot_of.call(u6))
		var p6 := _vbezier(Vector2(x6, y6), Vector2(x6, y6 + 64.0), 6)
		ribbons.append({"id": "out:%d" % bo2, "conn_ids": [], "a": str(b4["node"]), "b": "",
			"key": str(b4["key"]), "value": float(b4["value"]),
			"width": float(wfn.call(str(b4["key"]), float(b4["value"]))), "path": p6,
			"kind": KIND_OUT, "loop": -1, "side": 0, "label": str(b4.get("label", ""))})

	# --- 7. metrics ------------------------------------------------------
	var metrics := cycling_metrics(ids, E, bin, bout)
	var loops: Array = []
	for li in loop_ids.size():
		var lm: Array = []
		for i in n:
			if loop_of[i] == li:
				lm.append(ids[i])
		var lk := {}
		for ri2 in rets:
			var e3: Dictionary = E[ri2]
			if loop_of[int(idx[e3["a"]])] == li:
				lk[str(e3["key"])] = float(lk.get(str(e3["key"]), 0.0)) + float(e3["value"])
		loops.append({"id": li, "nodes": lm, "returns": lk})
	for key in metrics:
		var cnt := 0
		for L2 in loops:
			if (L2["returns"] as Dictionary).has(key):
				cnt += 1
		(metrics[key] as Dictionary)["loops"] = cnt
	var lane_max := maxf(float(lane_off[-1]), float(lane_off[1]))
	var bounds := Rect2(Vector2(col_lo - ret_gap - lane_max - 20.0, 0.0),
		Vector2((col_hi - col_lo) + 2.0 * (ret_gap + lane_max + 20.0), bottom_y))
	return {"nodes": out_nodes, "ribbons": ribbons, "loops": loops, "metrics": metrics,
		"bounds": bounds, "center_x": 0.0, "refs": refs, "layers": max_layer + 1,
		"returns": rets.size()}


## Finn's Cycling Index per resource (Finn 1976, J. Theor. Biol. 56:363):
## the share of total system throughflow that is cycled. With T_i the
## throughflow of compartment i (max of what enters and leaves it),
## G_ij = f_ij / T_i, N = (I − G)⁻¹, TST_c = Σ_j ((n_jj − 1) / n_jj) T_j and
## FCI = TST_c / TST. 0 for a chain, 1 for a perfectly closed loop.
static func cycling_metrics(ids: Array, E: Array, bin: Array, bout: Array) -> Dictionary:
	var keys := {}
	for e in E:
		keys[str(e["key"])] = true
	for b in bin:
		keys[str(b["key"])] = true
	for b in bout:
		keys[str(b["key"])] = true
	var out := {}
	var klist: Array = keys.keys()
	klist.sort()
	for key in klist:
		var node_set := {}
		for e in E:
			if str(e["key"]) == key:
				node_set[str(e["a"])] = true
				node_set[str(e["b"])] = true
		for b in bin:
			if str(b["key"]) == key:
				node_set[str(b["node"])] = true
		for b in bout:
			if str(b["key"]) == key:
				node_set[str(b["node"])] = true
		var nid: Array = node_set.keys()
		nid.sort()
		var m := nid.size()
		var ix := {}
		for i in m:
			ix[nid[i]] = i
		var f := PackedFloat64Array()
		f.resize(m * m)
		var tin := PackedFloat64Array()
		var tout := PackedFloat64Array()
		tin.resize(m)
		tout.resize(m)
		var zin := 0.0
		var yout := 0.0
		for e in E:
			if str(e["key"]) != key:
				continue
			var a := int(ix[str(e["a"])])
			var b := int(ix[str(e["b"])])
			var v := float(e["value"])
			f[a * m + b] += v
			tout[a] += v
			tin[b] += v
		for b in bin:
			if str(b["key"]) == key:
				tin[int(ix[str(b["node"])])] += float(b["value"])
				zin += float(b["value"])
		for b in bout:
			if str(b["key"]) == key:
				tout[int(ix[str(b["node"])])] += float(b["value"])
				yout += float(b["value"])
		var T := PackedFloat64Array()
		T.resize(m)
		var tst := 0.0
		for i in m:
			T[i] = maxf(tin[i], tout[i])
			tst += T[i]
		var fci := 0.0
		if tst > 0.0 and m > 0:
			# I − G, slightly damped so a perfectly closed loop stays invertible
			# (its FCI then reads ~1, which is the right answer).
			var A: Array = []
			for i in m:
				var row2 := PackedFloat64Array()
				row2.resize(m)
				for j in m:
					var g := f[i * m + j] / (T[i] * (1.0 + 1e-6)) if T[i] > 0.0 else 0.0
					row2[j] = (1.0 if i == j else 0.0) - g
				A.append(row2)
			var diag := _inverse_diag(A)
			var tst_c := 0.0
			for j in m:
				var njj := diag[j]
				if njj > 0.0 and not is_inf(njj):
					tst_c += (njj - 1.0) / njj * T[j]
				elif is_inf(njj):
					tst_c += T[j]
			fci = clampf(tst_c / tst, 0.0, 1.0)
		out[key] = {"fci": fci, "throughflow": tst, "boundary_in": zin, "boundary_out": yout,
			"cycled": fci * tst, "nodes": m}
	return out


## Diagonal of A⁻¹ by Gauss–Jordan with partial pivoting. A singular matrix
## (a loop with no way out at all) gives INF on its diagonal.
static func _inverse_diag(A0: Array) -> PackedFloat64Array:
	var m := A0.size()
	var A: Array = []
	var I: Array = []
	for i in m:
		A.append((A0[i] as PackedFloat64Array).duplicate())
		var r := PackedFloat64Array()
		r.resize(m)
		r[i] = 1.0
		I.append(r)
	var out := PackedFloat64Array()
	out.resize(m)
	for c in m:
		var piv := c
		var best := absf((A[c] as PackedFloat64Array)[c])
		for r2 in range(c + 1, m):
			var v := absf((A[r2] as PackedFloat64Array)[c])
			if v > best:
				best = v
				piv = r2
		if best < 1e-12:
			for i in m:
				out[i] = INF
			return out
		if piv != c:
			var t: Variant = A[c]
			A[c] = A[piv]
			A[piv] = t
			var t2: Variant = I[c]
			I[c] = I[piv]
			I[piv] = t2
		var rowc: PackedFloat64Array = A[c]
		var irowc: PackedFloat64Array = I[c]
		var d := rowc[c]
		for j in m:
			rowc[j] /= d
			irowc[j] /= d
		A[c] = rowc
		I[c] = irowc
		for r3 in m:
			if r3 == c:
				continue
			var rr: PackedFloat64Array = A[r3]
			var fac := rr[c]
			if absf(fac) < 1e-18:
				continue
			var ir: PackedFloat64Array = I[r3]
			for j in m:
				rr[j] -= fac * rowc[j]
				ir[j] -= fac * irowc[j]
			A[r3] = rr
			I[r3] = ir
	for i in m:
		out[i] = (I[i] as PackedFloat64Array)[i]
	return out


# --- helpers ---------------------------------------------------------------

static func _clean_boundary(lst: Array, idx: Dictionary) -> Array:
	var out: Array = []
	for b in lst:
		var bd: Dictionary = b
		var nd := str(bd.get("node", ""))
		var v := float(bd.get("value", 0.0))
		if not idx.has(nd) or v <= 0.0:
			continue
		out.append({"node": nd, "key": str(bd.get("key", "")), "value": v, "label": str(bd.get("label", ""))})
	out.sort_custom(func(x, y) -> bool:
		if str(x["node"]) != str(y["node"]):
			return str(x["node"]) < str(y["node"])
		return str(x["key"]) < str(y["key"]))
	return out


## Tarjan's strongly connected components (iterative, so a long chain cannot
## blow the call stack). Returns a component number per node; components are
## numbered in reverse topological order.
static func _tarjan(n: int, adj: Array, E: Array, idx: Dictionary) -> PackedInt32Array:
	var index := PackedInt32Array()
	var low := PackedInt32Array()
	var on := PackedByteArray()
	var comp := PackedInt32Array()
	index.resize(n)
	low.resize(n)
	on.resize(n)
	comp.resize(n)
	for i in n:
		index[i] = -1
		comp[i] = -1
	var counter := 0
	var ncomp := 0
	var stack: Array = []
	for s in n:
		if index[s] >= 0:
			continue
		var work: Array = [[s, 0]]
		index[s] = counter
		low[s] = counter
		counter += 1
		stack.append(s)
		on[s] = 1
		while not work.is_empty():
			var top: Array = work[work.size() - 1]
			var v := int(top[0])
			var k := int(top[1])
			var out_e: Array = adj[v]
			if k < out_e.size():
				top[1] = k + 1
				var w := int(idx[(E[int(out_e[k])] as Dictionary)["b"]])
				if index[w] < 0:
					index[w] = counter
					low[w] = counter
					counter += 1
					stack.append(w)
					on[w] = 1
					work.append([w, 0])
				elif on[w] == 1:
					low[v] = mini(low[v], index[w])
			else:
				work.pop_back()
				if not work.is_empty():
					var p := int((work[work.size() - 1] as Array)[0])
					low[p] = mini(low[p], low[v])
				if low[v] == index[v]:
					while true:
						var x := int(stack.pop_back())
						on[x] = 0
						comp[x] = ncomp
						if x == v:
							break
					ncomp += 1
	return comp


## Eades–Lin–Smyth (1993) on one loop, weighted: peel sinks to the back and
## sources to the front; otherwise take the node with the most weight out
## minus in. Edges that point backward in the result are the cheapest set
## that breaks every cycle (heuristically): the light flows become returns.
static func _els_order(mem: Array, E: Array, idx: Dictionary, wnorm: Array) -> Array:
	var inset := {}
	for m in mem:
		inset[int(m)] = true
	var win := {}
	var wout := {}
	var nb_out := {}
	var nb_in := {}
	for m in mem:
		win[int(m)] = 0.0
		wout[int(m)] = 0.0
		nb_out[int(m)] = []
		nb_in[int(m)] = []
	for ei in E.size():
		var e: Dictionary = E[ei]
		var a := int(idx[e["a"]])
		var b := int(idx[e["b"]])
		if a == b or not inset.has(a) or not inset.has(b):
			continue
		var w := float(wnorm[ei])
		wout[a] = float(wout[a]) + w
		win[b] = float(win[b]) + w
		(nb_out[a] as Array).append([b, w])
		(nb_in[b] as Array).append([a, w])
	var alive := inset.duplicate()
	var s1: Array = []
	var s2: Array = []
	var remove := func(v: int) -> void:
		alive.erase(v)
		for pr in (nb_out[v] as Array):
			var t := int(pr[0])
			if alive.has(t):
				win[t] = float(win[t]) - float(pr[1])
		for pr in (nb_in[v] as Array):
			var t2 := int(pr[0])
			if alive.has(t2):
				wout[t2] = float(wout[t2]) - float(pr[1])
	while not alive.is_empty():
		var changed := true
		while changed:
			changed = false
			var ks: Array = alive.keys()
			ks.sort()
			for v in ks:
				if not alive.has(v):
					continue
				if float(wout[v]) <= 1e-12:
					s2.push_front(v)
					remove.call(int(v))
					changed = true
				elif float(win[v]) <= 1e-12:
					s1.append(v)
					remove.call(int(v))
					changed = true
		if alive.is_empty():
			break
		var best := -1
		var best_d := -INF
		var ks2: Array = alive.keys()
		ks2.sort()
		for v in ks2:
			var d := float(wout[v]) - float(win[v])
			if d > best_d + 1e-12:
				best_d = d
				best = int(v)
		s1.append(best)
		remove.call(best)
	return s1 + s2


static func _slot_key(it: Dictionary) -> String:
	match str(it.get("t", "")):
		"f":
			return "f%d.%d" % [int((it["ch"] as Dictionary)["edge"]), int(it["j"])]
		"r":
			return "r%d" % int((it["r"] as Dictionary)["edge"])
		"in":
			return "i%d" % int(it["b"])
		"out":
			return "o%d" % int(it["b"])
	return "?"


## Pack one layer left to right in its current order, centred on 0.
static func _pack_row(r: Array, units: Array, xc: Array, gap: float) -> void:
	var tot := 0.0
	for u in r:
		tot += float(units[int(u)]["w"]) + gap
	var x := -tot * 0.5
	for u in r:
		var w := float(units[int(u)]["w"])
		xc[int(u)] = x + w * 0.5
		x += w + gap


## Keep the order, remove overlaps: push right where needed, then pull the
## whole row back so its mean position is what the nodes wanted.
static func _resolve_row(r: Array, units: Array, xc: Array, gap: float) -> void:
	if r.is_empty():
		return
	var want_mean := 0.0
	for u in r:
		want_mean += xc[int(u)]
	want_mean /= float(r.size())
	for j in range(1, r.size()):
		var a := int(r[j - 1])
		var b := int(r[j])
		var min_x := float(xc[a]) + (float(units[a]["w"]) + float(units[b]["w"])) * 0.5 + gap
		if xc[b] < min_x:
			xc[b] = min_x
	var mean := 0.0
	for u in r:
		mean += xc[int(u)]
	mean /= float(r.size())
	var d := want_mean - mean
	for u in r:
		xc[int(u)] += d


## A vertical S-curve from a (top) down to b.
static func _vbezier(a: Vector2, b: Vector2, segs: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var dy := maxf(absf(b.y - a.y), 10.0) * 0.5
	var c1 := a + Vector2(0.0, dy)
	var c2 := b - Vector2(0.0, dy)
	for i in segs + 1:
		out.append(a.bezier_interpolate(c1, c2, b, float(i) / float(segs)))
	return out


## A return, shaped like a field line: out of the source's bottom heading
## down, bowing outward to its lane at mid-height (vertical there, moving
## up), then round and down into the target's top. Two cubics meeting at
## the lane; a longer loop has a wider lane and a deeper dip, so nested
## returns read as nested field lines round the main stream.
static func _return_path(s: Vector2, t: Vector2, xl: float, dip: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var y_low := s.y + dip
	var y_high := t.y - dip
	var ym := (y_low + y_high) * 0.5
	var half := maxf((y_low - y_high) * 0.5, dip)
	var m := Vector2(xl, ym)
	const SEGS := 22
	# Source → lane: leave straight down, arrive at the lane heading up.
	var a1 := s + Vector2(0.0, dip * 2.2)
	var a2 := m + Vector2(0.0, half * 0.95)
	for i in SEGS + 1:
		out.append(s.bezier_interpolate(a1, a2, m, float(i) / float(SEGS)))
	# Lane → target: keep heading up, then come down into the target.
	var b1 := m - Vector2(0.0, half * 0.95)
	var b2 := t - Vector2(0.0, dip * 2.2)
	for i2 in range(1, SEGS + 1):
		out.append(m.bezier_interpolate(b1, b2, t, float(i2) / float(SEGS)))
	return out
