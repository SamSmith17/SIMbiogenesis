class_name MimicGraphSource
extends RefCounted
## A graph scope as a process picture (plans/SCADA_PROCESS_PLAN.md, Phase 3):
## the Process lens. The scope's REAL nodes and resource wires, laid out the
## way a process diagram reads: what feeds comes first on the left, flow runs
## to the right, and a line that returns (a loop) runs back underneath.
##
## `opts.flow`: "right" (the default: feed on the left, flow to the right,
## returns underneath) or "down" (feed on top, flow runs down, returns down
## the right side). The picture is laid out the "right" way with each
## thing's height and width swapped, then turned over its diagonal, so
## both read the same and every line still leaves and arrives square.
##
## `build(items, conns)` → the DOC MimicCanvas draws:
##   {pipes:    [{id (= the wire's id), cv -1, role "pipe", pts, w, depth 0,
##                shell -1, label, kind, from, to}],
##    elements: [{id (= the item's id), kind, pos, size, depth 0, cv -1,
##                link -1, bnd -1, part "", label, item_type, …}],
##    bounds, layers}
##
## Element kinds: tank (a store), machine (a processor, plant, catchment,
## habitat…), pump, valve, check (FlowCtl nodes), group (a compound: double-
## click goes inside), source (a Planetary Basic Income node: rain, sun).
##
## `state(items, conns)` → {el: {id: {…}}, pipe: {wire id: {flow, fill,
## level}}} read straight off the item / wire dicts the flow engine stamps.
##
## Units are picture units (the canvas calls them mm; here ~1 unit = 1 px at
## zoom 1). Pure: the selftest builds it from plain dictionaries. The layout
## never writes the graph's own x / y; the player's drags are the lens's pins.

const COL_GAP := 210.0
const ROW_GAP := 70.0
const PIPE_W := 22.0
const LANE := 26.0            # between pipes sharing a channel
const RETURN_DROP := 90.0     # a returning line runs this far under the lowest node
const CORNER_R := 26.0
## The least straight run kept out of a thing when its lines are re-routed
## after a drag (MimicLayout.reroute).
const STUB := 34.0
const LOOSE_DROP := 150.0     # unpiped things stand this far under the picture
const FLOW_RIGHT := "right"
const FLOW_DOWN := "down"

const SIZE_TANK_MIN := Vector2(150, 190)
const SIZE_TANK_MAX := Vector2(250, 330)
const SIZE_MACHINE := Vector2(230, 150)
const SIZE_PUMP := Vector2(120, 120)
const SIZE_VALVE := Vector2(74, 74)
const SIZE_GROUP := Vector2(260, 170)
const SIZE_SOURCE := Vector2(150, 110)

## Item types that take part (anything else has no place in a process line).
const TYPES := ["resource", "processor", "plant", "catchment", "pbi", "compound", "hydro"]

const LAYER_PIPES := "pipes"
const LAYER_POWER := "power"
const LAYER_DATA := "data"
const LAYERS := [LAYER_PIPES, LAYER_POWER, LAYER_DATA]
const LAYER_LABELS := {LAYER_PIPES: "Pipes", LAYER_POWER: "Power", LAYER_DATA: "Network"}
const SIZE_DEVICE := Vector2(170, 112)
const INSTR_D := 46.0         # an instrument bubble
const WAITING_LOADS := ["appliance", "acload", "acbreaker"]
const INSTR_STEP := 58.0      # between bubbles on one thing
const INSTR_RISE := 44.0      # its centre above the thing's top
const WIRE_W := 7.0
## Kinds drawn with a picture of the thing when it has one.
const ICON_KINDS := ["machine", "source", "device", "group"]
const ICON_H := 150.0
const ICON_W_MIN := 44.0
const ICON_W_MAX := 300.0
const ICON_H_MIN := 84.0


static func kind_of(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	match str(item.get("type", "")):
		"resource":
			return "tank"
		"compound":
			return "group"
		"pbi":
			return "source"
		"processor":
			if FlowCtl.is_flowctl(specs):
				var k := FlowCtl.kind_of(specs)
				return "pump" if k == FlowCtl.KIND_PUMP else ("check" if k == FlowCtl.KIND_CHECK else "valve")
	if not (str(item.get("type", "")) in TYPES):
		return "device"
	return "machine"


## A pictured node's size for its picture's width / height: as tall as a
## machine, as wide as the picture (a long thing gets shorter instead of
## wider than ICON_W_MAX; a thin one no narrower than ICON_W_MIN).
static func icon_size(aspect: float) -> Vector2:
	var a := clampf(aspect, 0.05, 20.0)
	var h := ICON_H
	var w := h * a
	if w > ICON_W_MAX:
		w = ICON_W_MAX
		h = maxf(w / a, ICON_H_MIN)
	elif w < ICON_W_MIN:
		w = ICON_W_MIN
	return Vector2(roundf(w), roundf(h))


static func size_of(item: Dictionary) -> Vector2:
	match kind_of(item):
		"tank":
			# Bigger stores are drawn bigger, by the cube root of what they hold
			# (a tank ten times the volume is about twice as tall).
			var specs: Dictionary = item.get("specs", {}) as Dictionary
			var cap := maxf(float(specs.get("capacity_qty", 100.0)), 1.0)
			var t := clampf((pow(cap, 1.0 / 3.0) - 3.0) / 22.0, 0.0, 1.0)
			return SIZE_TANK_MIN.lerp(SIZE_TANK_MAX, t)
		"pump":
			return SIZE_PUMP
		"valve", "check":
			return SIZE_VALVE
		"group":
			return SIZE_GROUP
		"source":
			return SIZE_SOURCE
		"device":
			return SIZE_DEVICE
	return SIZE_MACHINE


static func is_pipe(conn: Dictionary) -> bool:
	return str(conn.get("polarity", "")) == "resource" or not str(conn.get("resource_type", "")).is_empty()


## Which lines a wire belongs to: "pipes" (a resource wire), "data" (a data
## wire, ScadaNet) or "power" (every other polarity).
static func layer_of(conn: Dictionary) -> String:
	if is_pipe(conn):
		return LAYER_PIPES
	if ScadaNet.is_data(conn):
		return LAYER_DATA
	return LAYER_POWER


## The single-line symbol a device is drawn with.
static func glyph_of(item: Dictionary) -> String:
	var role := ScadaNet.role_of(item)
	if not role.is_empty():
		return role
	match str(item.get("type", "")):
		"panel":
			return "panel"
		"battery", "smartbattery":
			return "battery"
		"controller":
			return "inverter"
		"appliance", "acload":
			return "load"
		"wind", "hydro":
			return "generator"
		"breaker", "acbreaker", "breaker_panel", "combiner", "solarcombiner", "spiderbox", "shelly4pm", "acoutlet":
			return "breaker"
	return "box"


## `layers` = which kinds of line are shown ({pipes, power, data}: bool);
## empty = pipes only.
## `instruments` = what placed boards measure on these items
## (ScadaHub.esp_instruments): each is drawn as a bubble on the thing it
## reads, with a signal line to its board while the Network lines show.
## `opts.aspect` = {item id: width / height} of the picture a node is drawn
## with (MimicIcons): it takes that shape, so its lines meet the picture.
static func build(items: Array, conns: Array, layers: Dictionary = {}, instruments: Array = [], opts: Dictionary = {}) -> Dictionary:
	var aspects: Dictionary = opts.get("aspect", {}) as Dictionary
	var down := str(opts.get("flow", FLOW_RIGHT)) == FLOW_DOWN
	var show := layers if not layers.is_empty() else {LAYER_PIPES: true}
	var by_id := {}
	var order: Array = []
	for it in items:
		if it is Dictionary and it.has("id"):
			by_id[str(it["id"])] = it
			order.append(str(it["id"]))
	var edges: Array = []
	var seen_pair := {}
	var has_ac := {}
	for c0 in conns:
		if c0 is Dictionary and str(c0.get("polarity", "")) in ["ac", "load", "ac_240"]:
			has_ac[str(c0.get("source_item_id", ""))] = true
			has_ac[str(c0.get("target_item_id", ""))] = true
	for c in conns:
		if not (c is Dictionary):
			continue
		var lay := layer_of(c)
		if not bool(show.get(lay, false)):
			continue
		var a := str(c.get("source_item_id", ""))
		var b := str(c.get("target_item_id", ""))
		if not by_id.has(a) or not by_id.has(b) or a == b:
			continue
		if lay == LAYER_PIPES and not (str((by_id[a] as Dictionary).get("type", "")) in TYPES
				and str((by_id[b] as Dictionary).get("type", "")) in TYPES):
			continue
		var kind := ResourceKinds.normalize_kind(str(c.get("resource_type", ""))) if lay == LAYER_PIPES else ""
		if lay != LAYER_PIPES:
			# A DC pair (+ and −) or two cables between the same two things
			# is ONE line of a single-line diagram.
			var pk := "%s|%s|%s" % [lay, a if a < b else b, b if a < b else a]
			if seen_pair.has(pk):
				continue
			seen_pair[pk] = true
			kind = ScadaNet.kind_of(c) if lay == LAYER_DATA else ("ac" if str(c.get("polarity", "")) in ["ac", "load", "ac_240"] else "dc")
		edges.append({"id": str(c.get("id", "")), "a": a, "b": b, "kind": kind, "layer": lay})
	# Only what is on a shown line is in the picture, plus valves and pumps
	# waiting to be piped and parts set down in the lens.
	var on_pipe := {}
	for e in edges:
		on_pipe[e["a"]] = true
		on_pipe[e["b"]] = true
	var ids: Array = []
	for id in order:
		var it2: Dictionary = by_id[id]
		var waiting := bool(show.get(LAYER_PIPES, false)) and str(it2.get("type", "")) in TYPES \
				and (kind_of(it2) in ["pump", "valve", "check"]
				or bool((it2.get("specs", {}) as Dictionary).get("process_show", false)))
		# A load with no power wire, or a network device with no cable, waits
		# under the picture too while its layer shows (so it can be wired).
		if not waiting and bool(show.get(LAYER_POWER, false)) and str(it2.get("type", "")) in WAITING_LOADS and not has_ac.has(id):
			waiting = true
		if not waiting and bool(show.get(LAYER_DATA, false)) and not ScadaNet.role_of(it2).is_empty():
			waiting = true
		if on_pipe.has(id) or waiting:
			ids.append(id)
	# Start order = the graph's own left-to-right, top-to-bottom, so two
	# builds of one graph agree and the picture echoes the freeform layout.
	ids.sort_custom(func(p: String, q: String) -> bool:
		var ip: Dictionary = by_id[p]
		var iq: Dictionary = by_id[q]
		var kp := [float(ip.get("y", 0.0)), float(ip.get("x", 0.0)), p]
		var kq := [float(iq.get("y", 0.0)), float(iq.get("x", 0.0)), q]
		return kp < kq)
	# What is not piped yet stands in a row under the picture, so setting a
	# part down never moves what is already there.
	var loose: Array = []
	var piped: Array = []
	for id in ids:
		if on_pipe.has(id):
			piped.append(id)
		else:
			loose.append(id)
	var layer := _layers(piped, edges)
	_pull_roots(piped, edges, layer)
	for id in loose:
		layer[id] = 0
	# Columns.
	var cols := {}
	var n_cols := 0
	for id in piped:
		var l := int(layer[id])
		if not cols.has(l):
			cols[l] = []
		(cols[l] as Array).append(id)
		n_cols = maxi(n_cols, l + 1)
	var pos := {}
	var size := {}
	for id in ids:
		size[id] = size_of(by_id[id])
		if aspects.has(id) and kind_of(by_id[id]) in ICON_KINDS:
			size[id] = icon_size(float(aspects[id]))
	# Top to bottom: lay out with each thing turned on its side, then turn
	# the whole picture over its diagonal (`_tp`).
	var real_size := size.duplicate()
	if down:
		for id in size:
			size[id] = Vector2((size[id] as Vector2).y, (size[id] as Vector2).x)
	# Rows inside a column: by where the things feeding it sit (one pass,
	# left to right), then stacked and centred.
	var x := 0.0
	var max_bottom := 0.0
	var col_left := {}
	var col_right := {}
	for l in n_cols:
		var col: Array = cols.get(l, [])
		if l > 0:
			var bary := {}
			for id in col:
				var sum := 0.0
				var n := 0
				for e in edges:
					if e["b"] == id and pos.has(e["a"]):
						sum += (pos[e["a"]] as Vector2).y
						n += 1
				bary[id] = sum / float(n) if n > 0 else INF
			var idx := {}
			for i in col.size():
				idx[col[i]] = i
			col.sort_custom(func(p: String, q: String) -> bool:
				if float(bary[p]) != float(bary[q]):
					return float(bary[p]) < float(bary[q])
				return int(idx[p]) < int(idx[q]))
		var w := 0.0
		var h := 0.0
		for id in col:
			w = maxf(w, (size[id] as Vector2).x)
			h += (size[id] as Vector2).y
		h += ROW_GAP * float(maxi(col.size() - 1, 0))
		var y := -h * 0.5
		for id in col:
			var s: Vector2 = size[id]
			pos[id] = Vector2(x + w * 0.5, y + s.y * 0.5)
			y += s.y + ROW_GAP
		max_bottom = maxf(max_bottom, h * 0.5)
		col_left[l] = x
		col_right[l] = x + w
		x += w + COL_GAP
	var lx := 0.0
	var loose_h := 0.0
	for id in loose:
		var ls: Vector2 = size[id]
		pos[id] = Vector2(lx + ls.x * 0.5, max_bottom + LOOSE_DROP + ls.y * 0.5)
		lx += ls.x + ROW_GAP
		loose_h = maxf(loose_h, ls.y)
	if not loose.is_empty() and not piped.is_empty():
		max_bottom += LOOSE_DROP + loose_h
	# Elements.
	var elements: Array = []
	for id in ids:
		var it: Dictionary = by_id[id]
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var nm := str(specs.get("name", "")).strip_edges()
		var e := {"id": id, "kind": kind_of(it), "pos": _tp(pos[id], down), "size": real_size[id], "depth": 0.0, "cv": -1, "link": -1,
			"bnd": -1, "part": "", "label": nm if not nm.is_empty() else id, "item_type": str(it.get("type", "")),
			"layer": int(layer[id]), "loose": not on_pipe.has(id)}
		if e["kind"] in ["valve", "check"]:
			e["dir"] = Vector2.DOWN if down else Vector2.RIGHT
		if e["kind"] == "tank":
			e["carries"] = ResourceKinds.normalize_kind(str(specs.get("resource_kind", "")))
		if e["kind"] == "device":
			e["glyph"] = glyph_of(it)
		if aspects.has(id) and e["kind"] in ICON_KINDS:
			e["icon"] = true
		elements.append(e)
	# Pipes: out of the right side, into the left; each element's lines are
	# spread down its side in the order of where they go.
	var outs := {}
	var ins := {}
	for e in edges:
		if not outs.has(e["a"]):
			outs[e["a"]] = []
		(outs[e["a"]] as Array).append(e)
		if not ins.has(e["b"]):
			ins[e["b"]] = []
		(ins[e["b"]] as Array).append(e)
	for id in outs:
		(outs[id] as Array).sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
			return [(pos[p["b"]] as Vector2).y, str(p["id"])] < [(pos[q["b"]] as Vector2).y, str(q["id"])])
	for id in ins:
		(ins[id] as Array).sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
			return [(pos[p["a"]] as Vector2).y, str(p["id"])] < [(pos[q["a"]] as Vector2).y, str(q["id"])])
	var pipes: Array = []
	var lane_of := {}      # channel (between two columns) → lines so far
	var returns := 0
	for e in edges:
		var a_id := str(e["a"])
		var b_id := str(e["b"])
		var a := _port(pos[a_id], size[a_id], true, (outs[a_id] as Array).find(e), (outs[a_id] as Array).size())
		var b := _port(pos[b_id], size[b_id], false, (ins[b_id] as Array).find(e), (ins[b_id] as Array).size())
		var pts := PackedVector2Array()
		if int(layer[b_id]) > int(layer[a_id]) and b.x - a.x > 30.0:
			var ch := int(layer[a_id])
			var k := int(lane_of.get(ch, 0))
			lane_of[ch] = k + 1
			# Staggered channel lanes so parallel lines do not draw on each other.
			# The riser runs in the gap between the columns, never over a
			# wider thing standing in the same column as a narrow one.
			var gap_l := float(col_right.get(ch, a.x))
			var gap_r := float(col_left.get(ch + 1, b.x))
			var mx := clampf(gap_l + 40.0 + LANE * float(k), gap_l + 16.0, maxf(gap_r - 16.0, gap_l + 16.0))
			if absf(a.y - b.y) < 1.0:
				pts = PackedVector2Array([a, b])
			else:
				pts = PackedVector2Array([a, Vector2(mx, a.y), Vector2(mx, b.y), b])
		else:
			# A return: out, down under everything, back, up and in.
			var low := max_bottom + RETURN_DROP + LANE * float(returns)
			returns += 1
			var out_x := float(col_right.get(int(layer[a_id]), a.x)) + 44.0
			var in_x := float(col_left.get(int(layer[b_id]), b.x)) - 44.0
			pts = PackedVector2Array([a, Vector2(out_x, a.y), Vector2(out_x, low),
				Vector2(in_x, low), Vector2(in_x, b.y), b])
		var lay2 := str(e["layer"])
		var lbl := "Line"
		if lay2 == LAYER_PIPES:
			lbl = ResourceKinds.display_name(str(e["kind"])) if not str(e["kind"]).is_empty() else "Line"
		elif lay2 == LAYER_DATA:
			lbl = str((ScadaNet.KINDS[str(e["kind"])] as Dictionary)["label"])
		else:
			lbl = "AC" if str(e["kind"]) == "ac" else "DC"
		if down:
			for q in pts.size():
				pts[q] = _tp(pts[q], true)
		pipes.append({"id": str(e["id"]), "cv": -1, "role": "pipe", "pts": round_corners(pts, CORNER_R),
			"corners": pts, "corner_r": CORNER_R, "stub": STUB,
			"w": PIPE_W if lay2 == LAYER_PIPES else WIRE_W, "style": lay2,
			"dashed": lay2 == LAYER_DATA and str(e["kind"]) == "wireless",
			"depth": 0.0, "shell": -1, "label": lbl,
			"kind": str(e["kind"]), "from": a_id, "to": b_id, "returns": int(layer[b_id]) <= int(layer[a_id])})
	if down:
		for id in pos:
			pos[id] = _tp(pos[id], true)
	size = real_size
	# Instruments: a bubble above the thing each one reads.
	var on_item := {}
	for gauge in instruments:
		if not (gauge is Dictionary):
			continue
		var target := str(gauge.get("item", ""))
		if not pos.has(target):
			continue
		var k2 := int(on_item.get(target, 0))
		on_item[target] = k2 + 1
		var tp: Vector2 = pos[target]
		var ts: Vector2 = size[target]
		var ip := Vector2(tp.x - ts.x * 0.5 + 26.0 + INSTR_STEP * float(k2), tp.y - ts.y * 0.5 - INSTR_RISE)
		var iid := "ins:" + str(gauge.get("id", ""))
		elements.append({"id": iid, "kind": "instr", "pos": ip, "size": Vector2(INSTR_D, INSTR_D), "depth": 0.0, "cv": -1,
			"link": -1, "bnd": -1, "part": "", "label": str(gauge.get("label", "")), "item_type": "instrument",
			"layer": int(layer.get(target, 0)), "loose": false, "letters": str(gauge.get("letters", letters_for(str(gauge.get("src", ""))))),
			"reads": target, "board": str(gauge.get("board", ""))})
		var board := str(gauge.get("board", ""))
		# A board's signal shows with the Network lines; a control loop's
		# line to what it drives (`link`) always shows.
		if (bool(show.get(LAYER_DATA, false)) or bool(gauge.get("link", false))) and pos.has(board) and board != target:
			var bp: Vector2 = pos[board]
			var bs: Vector2 = size[board]
			var top := ip + Vector2(0, -INSTR_D * 0.5)
			var lift := minf(top.y, bp.y - bs.y * 0.5) - 34.0 - 9.0 * float(pipes.size() % 5)
			var sig := PackedVector2Array([top, Vector2(top.x, lift), Vector2(bp.x, lift), Vector2(bp.x, bp.y - bs.y * 0.5)])
			pipes.append({"id": "sig:" + str(gauge.get("id", "")), "cv": -1, "role": "pipe", "pts": round_corners(sig, 14.0),
				"corners": sig, "corner_r": 14.0, "stub": 18.0,
				"w": WIRE_W * 0.55, "style": LAYER_DATA, "dashed": true, "depth": 0.0, "shell": -1, "label": "Signal",
				"kind": "signal", "from": iid, "to": board, "returns": false})
	var doc := {"pipes": pipes, "elements": elements, "layers": n_cols, "flow": FLOW_DOWN if down else FLOW_RIGHT}
	doc["bounds"] = MimicLayout.bounds_of(doc)
	return doc


## A point of the "right" layout turned over the diagonal (top to bottom).
static func _tp(p: Vector2, down: bool) -> Vector2:
	return Vector2(p.y, p.x) if down else p


## Where a line meets an element's side: `k` of `n`, spread over the middle
## 60 % of its height.
static func _port(c: Vector2, s: Vector2, right: bool, k: int, n: int) -> Vector2:
	var x := c.x + s.x * (0.5 if right else -0.5)
	if n <= 1:
		return Vector2(x, c.y)
	var span := s.y * 0.6
	return Vector2(x, c.y - span * 0.5 + span * float(k) / float(n - 1))


## Longest-path layers (a node sits one column right of the furthest thing
## feeding it). A wire that would close a cycle is a RETURN and does not push
## anything right. Deterministic: nodes in the given order.
static func _layers(ids: Array, edges: Array) -> Dictionary:
	var out_of := {}
	for id in ids:
		out_of[id] = []
	for e in edges:
		if out_of.has(e["a"]):
			(out_of[e["a"]] as Array).append(e["b"])
	var state := {}     # 0 unseen, 1 on the stack, 2 done
	var layer := {}
	var has_in := {}
	for e in edges:
		has_in[e["b"]] = true
	var roots: Array = []
	for id in ids:
		if not has_in.has(id):
			roots.append(id)
	for id in ids:
		layer[id] = 0
	# Iterative DFS from the roots, then from anything a cycle left unseen.
	var forward: Array = []     # [a, b] edges that are not returns
	for start in roots + ids:
		if int(state.get(start, 0)) != 0:
			continue
		var stack: Array = [[start, 0]]
		state[start] = 1
		while not stack.is_empty():
			var top: Array = stack[stack.size() - 1]
			var node: String = top[0]
			var kids: Array = out_of.get(node, [])
			if int(top[1]) < kids.size():
				var child: String = kids[int(top[1])]
				top[1] = int(top[1]) + 1
				var st := int(state.get(child, 0))
				if st == 1:
					continue      # back onto the stack: a return
				forward.append([node, child])
				if st == 0:
					state[child] = 1
					stack.append([child, 0])
			else:
				state[node] = 2
				stack.pop_back()
	# Relax the forward edges (a DAG): at most one pass per node.
	for _pass in ids.size():
		var moved := false
		for f in forward:
			if int(layer[f[1]]) < int(layer[f[0]]) + 1:
				layer[f[1]] = int(layer[f[0]]) + 1
				moved = true
		if not moved:
			break
	return layer


## A polyline with its corners turned into arcs of radius `r` (less where a
## leg is short).
static func round_corners(pts: PackedVector2Array, r: float) -> PackedVector2Array:
	return MimicLayout.round_corners(pts, r)


# ── live state ──────────────────────────────────────────────────────────────

## The two letters in an instrument's bubble (ISA-5.1: first what it
## measures, then what it does) from its binding.
static func letters_for(src: String) -> String:
	if src.ends_with(".distance_m"):
		return "LI"
	if src.ends_with(".high"):
		return "LS"
	if src.ends_with(".mass_kg"):
		return "WI"
	if src.ends_with(".voltage") or src.ends_with(".ac_v"):
		return "EI"
	if src.ends_with(".power_w"):
		return "JI"
	if src.ends_with(".current_a"):
		return "II"
	if src.ends_with(".energy_wh"):
		return "JQ"
	if src.ends_with(".switch"):
		return "XY"
	return "I"


## `net` = ScadaNet.reach(...) for the whole graph ({} = not asked);
## `instruments` as in build().
static func state(items: Array, conns: Array, net: Dictionary = {}, instruments: Array = []) -> Dictionary:
	var el := {}
	var net_nodes: Dictionary = net.get("nodes", {}) as Dictionary
	var net_on := bool(net.get("enforced", false))
	for it in items:
		if not (it is Dictionary) or not it.has("id"):
			continue
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var id := str(it["id"])
		var kind := kind_of(it)
		var d := {}
		match kind:
			"tank":
				var lvl := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
				var k := ResourceKinds.normalize_kind(str(specs.get("resource_kind", "")))
				d["level"] = lvl
				d["color"] = ResourceKinds.wire_color(k)
				if bool(specs.get("unlimited_capacity", false)):
					d["value"] = "%d %%" % int(round(lvl * 100.0))
				else:
					d["value"] = "%d %% · %s" % [int(round(lvl * 100.0)),
						UiText.num(lvl * float(specs.get("capacity_qty", 0.0)), str(specs.get("capacity_unit", "")), 3)]
				d["alarm"] = bool(specs.get("overflowing", false))
				d["in_open"] = bool(specs.get("input_valve_open", true))
				d["out_open"] = bool(specs.get("output_valve_open", true))
			"pump", "valve", "check":
				var on := FlowCtl.is_on(specs) and FlowCtl.opening(specs) > 0.0
				d["open"] = on
				d["running"] = on and float(specs.get("ctl_rate", 0.0)) > 0.0 and str(specs.get("node_state", "")) != "blocked"
				d["value"] = FlowCtl.state_words(specs)
				d["warn"] = not str(specs.get("ctl_block", "")).is_empty()
				d["color"] = ResourceKinds.wire_color(str(specs.get("ctl_resource", "water")))
			"device":
				var on3 := str(specs.get("current_state", specs.get("requested_state", "on"))).to_lower() == "on"
				var g := glyph_of(it)
				d["open"] = on3
				d["running"] = on3
				d["value"] = ""
				if g in ["load", "server", "switch", "ap", "board"]:
					d["value"] = "On" if on3 else "Off"
				if g == "battery" and specs.has("soc"):
					d["value"] = "%d %%" % int(round(float(specs.get("soc", 0.0)) * (100.0 if float(specs.get("soc", 0.0)) <= 1.0 else 1.0)))
				if bool(specs.get("destroyed", false)):
					d["warn"] = true
					d["value"] = "Fault"
				if BreakerTrip.is_breaker(it):
					d["open"] = BreakerTrip.is_closed(specs)
					d["running"] = d["open"]
					d["warn"] = bool(specs.get("tripped", false))
					d["value"] = BreakerTrip.state_words(specs)
				var nn: Dictionary = net_nodes.get(id, {}) as Dictionary
				if net_on and not nn.is_empty() and g != "server":
					d["warn"] = not bool(nn.get("ok", true))
					d["value"] = "Heard" if bool(nn.get("ok", true)) else UiText.sentence(str(nn.get("why", "not heard")))
			"group":
				d["value"] = "double-click to go in"
			"source":
				d["value"] = ""
			_:
				var st := str(specs.get("node_state", ""))
				var on2 := str(specs.get("requested_state", specs.get("current_state", "on"))).to_lower() == "on"
				d["running"] = st == "running"
				d["open"] = on2
				d["warn"] = st == "blocked" or st == "starved"
				d["value"] = {"running": "Running", "blocked": "Blocked", "starved": "Starved", "idle": "Idle",
					"ready": "Ready", "overflow": "Overflowing", "fault": "Fault"}.get(st, "On" if on2 else "Off")
				if str(it.get("type", "")) == "processor" and not on2 and st != "running":
					d["value"] = "Off"
		el[id] = d
	var pipe := {}
	for c in conns:
		if not (c is Dictionary):
			continue
		if not is_pipe(c):
			pipe[str(c.get("id", ""))] = wire_state(c)
			continue
		var rate := float(c.get("flow_rate", 0.0))
		var kind2 := ResourceKinds.normalize_kind(str(c.get("resource_type", "")))
		var col := ResourceKinds.wire_color(kind2) if not kind2.is_empty() else MimicSymbols.EMPTY
		# What a piping diagram writes on a run: what it carries, the pipe,
		# its length, the flow and what the run costs it.
		var unit2 := ResourceKinds.default_unit(kind2) if not kind2.is_empty() else ""
		var words := PackedStringArray([ResourceKinds.display_name(kind2) if not kind2.is_empty() else "Line"])
		var ct2 := str(c.get("conduit_type", ""))
		if not ct2.is_empty() and ConduitKinds.has_type(ct2) and not ConduitKinds.is_conceptual_type(ct2):
			words.append(ConduitKinds.display_name_with_size(ct2, c.get("conduit_style", {}) as Dictionary))
			if float(c.get("route_length_m", 0.0)) > 0.0 and bool(c.get("visible_3d", false)):
				words.append("%d m" % int(round(float(c.get("route_length_m", 0.0)))))
		words.append("%s/h" % UiText.num(rate, unit2, 3) if rate > 1e-6 else "still")
		if float(c.get("drop_pct", 0.0)) > 0.5:
			words.append("%s %% lost to the run" % UiText.num(float(c.get("drop_pct", 0.0)), "", 2))
		pipe[str(c.get("id", ""))] = {"text": " · ".join(words), "warn": float(c.get("drop_pct", 0.0)) > 25.0,
			"flow": 1 if rate > 1e-6 and bool(c.get("flow_active", rate > 0.0)) else 0,
			"rate": rate, "fill": col.darkened(0.25) if rate > 1e-6 else col.darkened(0.72), "level": 0.0,
			"service": ServicePalette.color_for(c),
			"unit": ResourceKinds.default_unit(kind2) if not kind2.is_empty() else ""}
	for ins in instruments:
		if not (ins is Dictionary):
			continue
		var ok := bool(ins.get("available", false))
		el["ins:" + str(ins.get("id", ""))] = {"value": str(ins.get("text", "")), "warn": not ok}
		pipe["sig:" + str(ins.get("id", ""))] = {"flow": 0, "color": Color(0.357, 0.827, 0.745, 0.75), "warn": not ok,
			"text": "Signal · %s" % str(ins.get("label", "")), "rate": 0.0, "unit": ""}
	return {"el": el, "pipe": pipe}


## A power or data wire's state for the picture: {flow, color, warn, text}.
## The text is what a single-line diagram writes on a run: the cable, its
## length, what it carries and what it loses.
static func wire_state(c: Dictionary) -> Dictionary:
	var parts := PackedStringArray()
	var warn := false
	var len_m := float(c.get("route_length_m", -1.0)) if bool(c.get("visible_3d", false)) else -1.0
	if ScadaNet.is_data(c):
		var k := ScadaNet.kind_of(c)
		parts.append(str((ScadaNet.KINDS[k] as Dictionary)["label"]))
		if len_m > 0.0:
			parts.append("%d m" % int(round(len_m)))
		var fault := ScadaNet.link_fault(c)
		if not fault.is_empty():
			warn = true
			parts.append("too long (works to %d m)" % int((ScadaNet.KINDS[k] as Dictionary)["max_m"]))
		return {"flow": 0, "color": Color(0.357, 0.827, 0.745), "warn": warn, "text": " · ".join(parts), "rate": 0.0, "unit": ""}
	var pol := str(c.get("polarity", ""))
	var ct := str(c.get("conduit_type", ""))
	var named := not ct.is_empty() and ConduitKinds.has_type(ct) and not ConduitKinds.is_conceptual_type(ct)
	parts.append(ConduitKinds.display_name_with_size(ct, c.get("conduit_style", {}) as Dictionary) if named
		else ("AC" if pol in ["ac", "load", "ac_240"] else "DC"))
	if len_m > 0.0:
		parts.append("%d m" % int(round(len_m)))
	var amps := float(c.get("carried_amps", 0.0))
	if amps > 0.05:
		parts.append("%s A" % UiText.num(amps, "", 2))
	var drop := float(c.get("drop_pct", 0.0))
	if drop > 0.05:
		parts.append("%s %% drop" % UiText.num(drop, "", 2))
		warn = warn or drop > 5.0
	var over := float(c.get("overload_ratio", 0.0))
	if over > 1.0:
		warn = true
		parts.append("overloaded %d %%" % int(round(over * 100.0)))
	var col := Color(0.941, 0.678, 0.306) if pol in ["ac", "load", "ac_240"] else Color(0.847, 0.329, 0.329)
	return {"flow": 1 if bool(c.get("flow_active", amps > 0.05)) else 0, "color": col, "warn": warn,
		"text": " · ".join(parts), "rate": 0.0, "unit": ""}


## A thing nothing feeds stands one column left of the first thing it feeds,
## not in column 0 with every other source (which made one very tall column).
static func _pull_roots(ids: Array, edges: Array, layer: Dictionary) -> void:
	var has_in := {}
	var first_out := {}
	for e in edges:
		var la := int(layer.get(e["a"], 0))
		var lb := int(layer.get(e["b"], 0))
		if lb > la:
			has_in[e["b"]] = true
			first_out[e["a"]] = mini(int(first_out.get(e["a"], 1 << 30)), lb)
	for id in ids:
		if not has_in.has(id) and first_out.has(id):
			layer[id] = maxi(int(layer[id]), int(first_out[id]) - 1)


## The graph item a tag belongs to ("" = none): tank.<id>.level, node.<id>,
## valve.<id>.open.
static func item_of_tag(tag: String) -> String:
	var parts := tag.split(".")
	if parts.size() >= 2 and parts[0] in ["tank", "node", "valve"]:
		return parts[1]
	return ""


## Control blocks as instruments for the picture: a controller bubble on what
## it reads (else on what it drives) with a line to what it drives.
static func logic_instruments(blocks: Array, status: Dictionary) -> Array:
	var out: Array = []
	for b in blocks:
		if not (b is Dictionary):
			continue
		var id := str(b.get("id", ""))
		var used := ScadaLogic.tags_used(b)
		var reads := ""
		for t in used["reads"]:
			if reads.is_empty():
				reads = item_of_tag(str(t))
		var drives := ""
		for t in used["writes"]:
			if drives.is_empty():
				drives = item_of_tag(str(t))
		var on := reads if not reads.is_empty() else drives
		if on.is_empty():
			continue
		var s: Dictionary = status.get(id, {}) as Dictionary
		var level_tag := str(b.get("pv", "")).begins_with("tank.")
		var letters: String = {"pid": "LIC" if level_tag else "IC", "band": "LS" if level_tag else "S",
			"interlock": "I", "timer": "KC", "counter": "QI", "sequence": "KS", "duty": "HS"}.get(str(b.get("kind", "")), "C")
		out.append({"id": "logic:" + id, "item": on, "board": drives, "src": "", "letters": letters,
			"label": str(b.get("name", id)), "text": str(s.get("text", "")), "available": str(s.get("level", "ok")) != "warn",
			"link": true, "logic": id})
	return out
