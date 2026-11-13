class_name ElementSankey
extends RefCounted

## "Where it goes" for one element (resource composition plan Phase 4):
## an ElementHistory window turned into a three-column Sankey. Pure.
##
##   left    where the element comes from: stores, rain, deliveries, the air,
##           other machines
##   middle  what transforms it: machines, people, plant beds (the ledger's
##           nodes)
##   right   where it goes: stores, the air, drained off site, other machines
## A wire between two non-nodes (rain straight into a cistern, a delivery
## into a tank) runs left to right past the middle. The middle keeps its
## MAX_MIDDLE biggest nodes and the sides MAX_SIDE each; the rest are summed
## into "Other …".
##
## build() → {lens, nodes: [{id, col 0|1|2, label, value, kind}],
##            links: [{a, b, value}], total, unit_hint}

const MAX_MIDDLE := 8
const MAX_SIDE := 10
## Links smaller than this share of the biggest are dropped (noise).
const MIN_SHARE := 0.002

const AIR := "air"
const DRAINED := "drained"


## `win`: an ElementHistory window. `node_ids`: ids of the transforming
## nodes (ledger.nodes keys). `names`: id → label.
static func build(win: Dictionary, lens: String, node_ids: Dictionary, names: Dictionary) -> Dictionary:
	var li := int(ElementLens.INDEX.get(lens, 0))
	var raw: Array = []   # [from_key, to_key, value]; key = "L:id" | "M:id" | "R:id"
	var ends: Dictionary = win.get("ends", {})
	var edges: Dictionary = win.get("edges", {})
	for k in edges.keys():
		var v := float((edges[k] as PackedFloat64Array)[li])
		if v <= 0.0 or not ends.has(k):
			continue
		var src := str(ends[k][0])
		var tgt := str(ends[k][1])
		var s_node := node_ids.has(src)
		var t_node := node_ids.has(tgt)
		if t_node:
			raw.append(["L:" + src, "M:" + tgt, v])
		if s_node:
			raw.append(["M:" + src, "R:" + tgt, v])
		if not s_node and not t_node:
			raw.append(["L:" + src, "R:" + tgt, v])
	for id in (win.get("node_air_in", {}) as Dictionary).keys():
		var va := float((win["node_air_in"][id] as PackedFloat64Array)[li])
		if va > 0.0:
			raw.append(["L:" + AIR, "M:" + str(id), va])
	for id2 in (win.get("node_air_out", {}) as Dictionary).keys():
		var vb := float((win["node_air_out"][id2] as PackedFloat64Array)[li])
		if vb > 0.0:
			raw.append(["M:" + str(id2), "R:" + AIR, vb])
	for id3 in (win.get("node_dumped", {}) as Dictionary).keys():
		var vc := float((win["node_dumped"][id3] as PackedFloat64Array)[li])
		if vc > 0.0:
			raw.append(["M:" + str(id3), "R:" + DRAINED, vc])
	# Size every node by what passes through it, then keep the biggest.
	var through: Dictionary = {}
	var biggest := 0.0
	for r in raw:
		through[r[0]] = float(through.get(r[0], 0.0)) + float(r[2])
		through[r[1]] = float(through.get(r[1], 0.0)) + float(r[2])
		biggest = maxf(biggest, float(r[2]))
	var keep := _top(through, "M:", MAX_MIDDLE)
	keep.merge(_top(through, "L:", MAX_SIDE))
	keep.merge(_top(through, "R:", MAX_SIDE))
	var merged: Dictionary = {}   # "a|b" -> value
	for r2 in raw:
		if float(r2[2]) < biggest * MIN_SHARE:
			continue
		var a := _bucket(str(r2[0]), keep)
		var b := _bucket(str(r2[1]), keep)
		var key := a + "|" + b
		merged[key] = float(merged.get(key, 0.0)) + float(r2[2])
	var nodes_by: Dictionary = {}
	var links: Array = []
	var total := 0.0
	for key2 in merged.keys():
		var parts: PackedStringArray = str(key2).split("|")
		var v2 := float(merged[key2])
		links.append({"a": parts[0], "b": parts[1], "value": v2})
		for p in parts:
			if not nodes_by.has(p):
				nodes_by[p] = {"id": p, "col": _col(p), "label": _label(p, names), "value": 0.0,
					"kind": _kind(p)}
		if str(parts[0]).begins_with("L:"):
			total += v2
	# A node's value = the larger of what enters and what leaves it.
	var in_v: Dictionary = {}
	var out_v: Dictionary = {}
	for l in links:
		out_v[l["a"]] = float(out_v.get(l["a"], 0.0)) + float(l["value"])
		in_v[l["b"]] = float(in_v.get(l["b"], 0.0)) + float(l["value"])
	var nodes: Array = []
	for nid in nodes_by.keys():
		var nd: Dictionary = nodes_by[nid]
		nd["value"] = maxf(float(in_v.get(nid, 0.0)), float(out_v.get(nid, 0.0)))
		nodes.append(nd)
	nodes.sort_custom(func(x, y) -> bool:
		if int(x["col"]) != int(y["col"]):
			return int(x["col"]) < int(y["col"])
		if (str(x["kind"]) == "other") != (str(y["kind"]) == "other"):
			return str(y["kind"]) == "other"
		return float(x["value"]) > float(y["value"]))
	links.sort_custom(func(x, y) -> bool: return float(x["value"]) > float(y["value"]))
	return {"lens": lens, "nodes": nodes, "links": links, "total": total}


## The same window as input for the LOOP Sankey (LoopSankeyLayout): every
## store, machine, person and plant a node, every wire an edge of this
## element (parallel wires between one pair summed), the air and what is
## drained as boundary flows. Unlike the three columns, a material cycle
## (food → people → urine → recovery → nutrients → beds → food) shows as a
## loop. Pure.
static func loop_input(win: Dictionary, lens: String, names: Dictionary) -> Dictionary:
	var li := int(ElementLens.INDEX.get(lens, 0))
	var ends: Dictionary = win.get("ends", {})
	var edges: Dictionary = win.get("edges", {})
	var pair := {}
	var biggest := 0.0
	for k in edges.keys():
		var v := float((edges[k] as PackedFloat64Array)[li])
		if v <= 0.0 or not ends.has(k):
			continue
		var src := str(ends[k][0])
		var tgt := str(ends[k][1])
		if src == tgt:
			continue
		var pk := src + ">" + tgt
		pair[pk] = float(pair.get(pk, 0.0)) + v
		biggest = maxf(biggest, float(pair[pk]))
	var out_edges: Array = []
	var touched := {}
	var key := "element:" + lens
	for pk in pair.keys():
		var v2 := float(pair[pk])
		if v2 < biggest * MIN_SHARE:
			continue
		var ab: PackedStringArray = str(pk).split(">")
		out_edges.append({"id": str(pk), "a": ab[0], "b": ab[1], "key": key, "value": v2, "conn_ids": []})
		touched[ab[0]] = true
		touched[ab[1]] = true
	var bin: Array = []
	var bout: Array = []
	for id in (win.get("node_air_in", {}) as Dictionary).keys():
		var va := float((win["node_air_in"][id] as PackedFloat64Array)[li])
		if va > biggest * MIN_SHARE and touched.has(str(id)):
			bin.append({"node": str(id), "key": key, "value": va, "label": "from the air"})
	for id2 in (win.get("node_air_out", {}) as Dictionary).keys():
		var vb := float((win["node_air_out"][id2] as PackedFloat64Array)[li])
		if vb > biggest * MIN_SHARE and touched.has(str(id2)):
			bout.append({"node": str(id2), "key": key, "value": vb, "label": "to the air"})
	for id3 in (win.get("node_dumped", {}) as Dictionary).keys():
		var vc := float((win["node_dumped"][id3] as PackedFloat64Array)[li])
		if vc > biggest * MIN_SHARE and touched.has(str(id3)):
			bout.append({"node": str(id3), "key": key, "value": vc, "label": "drained"})
	var nodes: Array = []
	var labels := {}
	for nid in touched.keys():
		labels[nid] = str(names.get(nid, nid))
		nodes.append({"id": str(nid), "label": labels[nid]})
	return {"nodes": nodes, "edges": out_edges, "bin": bin, "bout": bout, "labels": labels,
		"types": {}, "keys": [key], "opts": {"thickness": 30.0, "layer_gap": 70.0, "node_h": 34.0,
			"min_node_w": 150.0}}


static func _top(through: Dictionary, prefix: String, n: int) -> Dictionary:
	var ks: Array = []
	for k in through.keys():
		if str(k).begins_with(prefix):
			ks.append(k)
	ks.sort_custom(func(a, b) -> bool: return float(through[a]) > float(through[b]))
	var out: Dictionary = {}
	for k2 in ks.slice(0, n):
		out[k2] = true
	return out


static func _bucket(key: String, keep: Dictionary) -> String:
	if keep.has(key):
		return key
	return key.substr(0, 2) + "_other"


static func _col(key: String) -> int:
	if key.begins_with("L:"):
		return 0
	if key.begins_with("M:"):
		return 1
	return 2


static func _kind(key: String) -> String:
	var id := key.substr(2)
	if id == "_other":
		return "other"
	if id == AIR:
		return "air"
	if id == DRAINED:
		return "drained"
	return "node" if key.begins_with("M:") else "item"


static func _label(key: String, names: Dictionary) -> String:
	var id := key.substr(2)
	match id:
		"_other":
			return "Other machines" if key.begins_with("M:") else ("Other sources" if key.begins_with("L:") else "Other places")
		AIR:
			return "From the air" if key.begins_with("L:") else "To the air"
		DRAINED:
			return "Drained off site"
	return str(names.get(id, id))
