class_name FlowCompare
extends RefCounted

## Two loop Sankey inputs side by side (plans/FLOW_VIZ_PLAN.md Part C): one
## shared width scale per resource, so a wire twice as wide in B carries
## twice as much, and a DIFFERENCE input whose ribbons are |B − A|, keyed
## "more:<kind>" (B carries more) or "less:<kind>" (B carries less), both of a
## kind on the same scale. Pure; inputs are LoopSankeyLayout inputs
## ({nodes, edges, bin, bout, labels, keys, opts}).

const MORE := "more:"
const LESS := "less:"
## A change smaller than this share of the kind's biggest flow is noise.
const MIN_SHARE := 0.01


## Per resource, the biggest flow in either version: the width reference both
## pictures share.
static func shared_refs(fa: Dictionary, fb: Dictionary) -> Dictionary:
	var refs := {}
	for f in [fa, fb]:
		for e in (f.get("edges", []) as Array):
			var k := str(e["key"])
			refs[k] = maxf(float(refs.get(k, 0.0)), float(e["value"]))
		for arr in [f.get("bin", []), f.get("bout", [])]:
			for b in (arr as Array):
				var k2 := str(b["key"])
				refs[k2] = maxf(float(refs.get(k2, 0.0)), float(b["value"]))
	return refs


## The input with its opts carrying the shared refs.
static func with_refs(f: Dictionary, refs: Dictionary) -> Dictionary:
	if f.is_empty():
		return f
	var out := f.duplicate()
	var opts: Dictionary = (f.get("opts", {}) as Dictionary).duplicate()
	opts["refs"] = refs.duplicate()
	out["opts"] = opts
	return out


static func base_key(k: String) -> String:
	if k.begins_with(MORE):
		return k.substr(MORE.length())
	if k.begins_with(LESS):
		return k.substr(LESS.length())
	return k


static func is_more(k: String) -> bool:
	return k.begins_with(MORE)


## B − A per wire, matched by (from, to, kind): a wire only one version has
## counts its whole flow. Boundaries likewise, per (node, kind, label).
static func difference(fa: Dictionary, fb: Dictionary) -> Dictionary:
	var ea := _edge_sums(fa)
	var eb := _edge_sums(fb)
	var ba := _bnd_sums(fa)
	var bb := _bnd_sums(fb)
	var big := {}
	for m in [ea, eb, ba, bb]:
		for id in m:
			var kk := str((m[id] as Dictionary)["key"])
			big[kk] = maxf(float(big.get(kk, 0.0)), float(m[id]["value"]))
	var edges: Array = []
	var touched := {}
	var refs := {}
	var ids: Array = ea.keys()
	for id in eb:
		if not ea.has(id):
			ids.append(id)
	ids.sort()
	for id in ids:
		var ra: Dictionary = ea.get(id, {})
		var rb: Dictionary = eb.get(id, {})
		var r: Dictionary = rb if not rb.is_empty() else ra
		var k := str(r["key"])
		var d := float(rb.get("value", 0.0)) - float(ra.get("value", 0.0))
		if absf(d) < float(big.get(k, 0.0)) * MIN_SHARE or absf(d) <= 0.0:
			continue
		var dk := (MORE if d > 0.0 else LESS) + k
		edges.append({"id": str(id), "a": str(r["a"]), "b": str(r["b"]), "key": dk,
			"value": absf(d), "conn_ids": []})
		touched[str(r["a"])] = true
		touched[str(r["b"])] = true
		refs[k] = maxf(float(refs.get(k, 0.0)), absf(d))
	var bin: Array = []
	var bout: Array = []
	var bids: Array = ba.keys()
	for id2 in bb:
		if not ba.has(id2):
			bids.append(id2)
	bids.sort()
	for id2 in bids:
		var qa: Dictionary = ba.get(id2, {})
		var qb: Dictionary = bb.get(id2, {})
		var q: Dictionary = qb if not qb.is_empty() else qa
		var k2 := str(q["key"])
		var d2 := float(qb.get("value", 0.0)) - float(qa.get("value", 0.0))
		if absf(d2) < float(big.get(k2, 0.0)) * MIN_SHARE or absf(d2) <= 0.0:
			continue
		if not touched.has(str(q["node"])):
			continue
		var row := {"node": str(q["node"]), "key": (MORE if d2 > 0.0 else LESS) + k2,
			"value": absf(d2), "label": str(q.get("label", ""))}
		if bool(q["in"]):
			bin.append(row)
		else:
			bout.append(row)
		refs[k2] = maxf(float(refs.get(k2, 0.0)), absf(d2))
	var all_refs := {}
	for k3 in refs:
		all_refs[MORE + str(k3)] = refs[k3]
		all_refs[LESS + str(k3)] = refs[k3]
	var labels := {}
	for f in [fa, fb]:
		var lab: Dictionary = f.get("labels", {})
		for nid in lab:
			labels[nid] = lab[nid]
	var nodes: Array = []
	var names: Array = touched.keys()
	names.sort()
	for nid in names:
		nodes.append({"id": str(nid), "label": str(labels.get(nid, nid))})
	var keys := {}
	for e in edges:
		keys[str(e["key"])] = true
	var opts: Dictionary = (fb.get("opts", fa.get("opts", {})) as Dictionary).duplicate()
	opts["refs"] = all_refs
	return {"nodes": nodes, "edges": edges, "bin": bin, "bout": bout, "labels": labels,
		"types": {}, "keys": keys.keys(), "opts": opts}


static func _edge_sums(f: Dictionary) -> Dictionary:
	var out := {}
	for e in (f.get("edges", []) as Array):
		var id := "%s>%s|%s" % [str(e["a"]), str(e["b"]), str(e["key"])]
		var r: Dictionary = out.get(id, {"a": str(e["a"]), "b": str(e["b"]), "key": str(e["key"]), "value": 0.0})
		r["value"] = float(r["value"]) + float(e["value"])
		out[id] = r
	return out


static func _bnd_sums(f: Dictionary) -> Dictionary:
	var out := {}
	for pair in [[f.get("bin", []), true], [f.get("bout", []), false]]:
		for b in (pair[0] as Array):
			var id := "%s|%s|%s|%s" % [str(b["node"]), str(b["key"]), str(b.get("label", "")),
				"in" if bool(pair[1]) else "out"]
			var r: Dictionary = out.get(id, {"node": str(b["node"]), "key": str(b["key"]),
				"label": str(b.get("label", "")), "in": bool(pair[1]), "value": 0.0})
			r["value"] = float(r["value"]) + float(b["value"])
			out[id] = r
	return out
