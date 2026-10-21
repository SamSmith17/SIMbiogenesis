class_name MpChangeSet
extends RefCounted

## What changed between two copies of the shared world, as OPS that can be
## sent, applied to a third copy (a merge), reverted and described to a
## player. Pure static: the design controller owns the copies, this file only
## compares them, so multiplayer_selftest exercises it with plain dicts.
##
## Two kinds of copy:
## - props: the placed-prop layer's records, keyed by "id".
## - graph: a GraphModel.serialize() blob — items + connections keyed by
##   "id", scopes + definitions keyed by their dictionary key.
##
## Ops:
##   props  {"up": [rec, …], "rm": [id, …]}
##   graph  {"items_up": [], "items_rm": [], "conns_up": [], "conns_rm": [],
##           "scopes_up": {}, "scopes_rm": [], "defs_up": {}, "defs_rm": [],
##           "counters": {"item": n, "conn": n}}
##
## Why ops and not snapshots: the old live sync sent the WHOLE props layer and
## the WHOLE graph on every edit (and every 12 s), and the receiver rebuilt
## every prop node and re-applied the whole graph — seconds of work for one
## moved tent, and a whole-snapshot apply overwrote whatever the other side
## had changed meanwhile. Ops touch only what moved and merge onto the
## receiver's current state.

## Spec keys the SIMULATION writes (telemetry, live state). A difference that
## lives only in these is not an edit anybody made, so it never makes a
## change worth sending or reviewing. Prefix match.
const VOLATILE_SPEC_PREFIXES: Array = [
	"live_", "dc_", "pv_offered", "pv_curtail", "current_", "pop_state",
	"pop_present", "pop_morale", "pop_collapse", "camp_soc", "camp_pv",
	"camp_load", "camp_ac", "camp_hours", "camp_open", "camp_morale",
	"camp_present", "budget_", "starved", "ideal_import", "ideal_export",
	"supply_lps", "supply_monthly", "stage_curve", "siphon_primed",
	"telemetry", "recipe_waiting", "batch_progress", "stock_l", "level_m",
	"soc", "battery_soc", "charge_kwh", "node_state", "fault_",
]

## Pose keys of a prop record: a change only here is a MOVE, which the
## receiver can show by sliding the node instead of rebuilding it.
const PROP_POSE_KEYS: Array = ["x", "z", "yaw", "pitch", "roll", "ground_y", "y_offset"]

const MAX_SUMMARY_LINES := 6


# ── canonical comparison ─────────────────────────────────────────────────────

## A canonical form for equality. Payloads travel as JSON, which turns every
## int into a float and rounds the last digits of a double; without this a
## record that went over the wire and back would always read as "changed".
static func canon(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT:
			return snappedf(float(v), 1e-6)
		TYPE_FLOAT:
			var f := float(v)
			if is_nan(f) or is_inf(f):
				return str(f)
			return snappedf(f, 1e-6)
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var keys := d.keys()
			keys.sort_custom(func(a, b) -> bool: return str(a) < str(b))
			var out := {}
			for k in keys:
				out[str(k)] = canon(d[k])
			return out
		TYPE_ARRAY:
			var out_a: Array = []
			for e in (v as Array):
				out_a.append(canon(e))
			return out_a
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, \
				TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, \
				TYPE_PACKED_STRING_ARRAY:
			return canon(Array(v))
		TYPE_VECTOR2:
			return canon([(v as Vector2).x, (v as Vector2).y])
		TYPE_VECTOR3:
			return canon([(v as Vector3).x, (v as Vector3).y, (v as Vector3).z])
		TYPE_COLOR:
			var c: Color = v
			return canon([c.r, c.g, c.b, c.a])
		TYPE_STRING_NAME:
			return str(v)
	return v


static func same(a: Variant, b: Variant) -> bool:
	return var_to_str(canon(a)) == var_to_str(canon(b))


## An item with the simulation's own spec keys removed — what a person edits.
static func authored(item: Dictionary) -> Dictionary:
	var out := item.duplicate(false)
	if out.get("specs") is Dictionary:
		var specs: Dictionary = (out["specs"] as Dictionary).duplicate(false)
		for k in specs.keys():
			var ks := str(k)
			for p in VOLATILE_SPEC_PREFIXES:
				if ks.begins_with(str(p)):
					specs.erase(k)
					break
		out["specs"] = specs
	return out


# ── keyed records ────────────────────────────────────────────────────────────

static func index_records(arr: Array, key: String = "id") -> Dictionary:
	var out := {}
	for raw in arr:
		if raw is Dictionary:
			var id := str((raw as Dictionary).get(key, ""))
			if not id.is_empty():
				out[id] = raw
	return out


## `cur` against `base_idx` (id -> record). `only` (id -> true) limits the
## CHANGED test to those ids — adds and removes are always found. `compare`
## maps a record to what is compared (authored() for graph items).
static func diff_records(base_idx: Dictionary, cur: Array, only: Variant = null,
		compare: Callable = Callable()) -> Dictionary:
	var up: Array = []
	var rm: Array = []
	var seen := {}
	for raw in cur:
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw
		var id := str(rec.get("id", ""))
		if id.is_empty():
			continue
		seen[id] = true
		if not base_idx.has(id):
			up.append(rec.duplicate(true))
			continue
		if only is Dictionary and not (only as Dictionary).has(id):
			continue
		var a: Variant = base_idx[id]
		var b: Variant = rec
		if compare.is_valid():
			a = compare.call(a)
			b = compare.call(b)
		if not same(a, b):
			up.append(rec.duplicate(true))
	for id in base_idx.keys():
		if not seen.has(id):
			rm.append(str(id))
	return {"up": up, "rm": rm}


## Apply up/rm onto an ARRAY of records (order kept; new ones appended).
static func apply_records(arr: Array, up: Array, rm: Array) -> Array:
	var out: Array = []
	var rm_set := {}
	for id in rm:
		rm_set[str(id)] = true
	var up_idx := index_records(up)
	var placed := {}
	for raw in arr:
		if not (raw is Dictionary):
			continue
		var id := str((raw as Dictionary).get("id", ""))
		if rm_set.has(id):
			continue
		if up_idx.has(id):
			out.append((up_idx[id] as Dictionary).duplicate(true))
			placed[id] = true
		else:
			out.append(raw)
	for rec in up:
		var id2 := str((rec as Dictionary).get("id", ""))
		if not placed.has(id2) and not rm_set.has(id2):
			out.append((rec as Dictionary).duplicate(true))
	return out


## Apply up/rm onto an INDEX (id -> record), in place.
static func apply_to_index(idx: Dictionary, up: Array, rm: Array) -> void:
	for id in rm:
		idx.erase(str(id))
	for rec in up:
		if rec is Dictionary:
			var id := str((rec as Dictionary).get("id", ""))
			if not id.is_empty():
				idx[id] = (rec as Dictionary).duplicate(true)


static func diff_keyed(base: Dictionary, cur: Dictionary) -> Dictionary:
	var up := {}
	var rm: Array = []
	for k in cur.keys():
		if not base.has(k) or not same(base[k], cur[k]):
			up[str(k)] = cur[k]
	for k in base.keys():
		if not cur.has(k):
			rm.append(str(k))
	return {"up": up, "rm": rm}


# ── props ────────────────────────────────────────────────────────────────────

static func diff_props(base_idx: Dictionary, cur: Array) -> Dictionary:
	return diff_records(base_idx, cur)


static func props_empty(ops: Dictionary) -> bool:
	return (ops.get("up", []) as Array).is_empty() and (ops.get("rm", []) as Array).is_empty()


## Ops that put every prop `ops` touched back the way `canon_idx` has it.
static func revert_props(ops: Dictionary, canon_idx: Dictionary) -> Dictionary:
	var up: Array = []
	var rm: Array = []
	for id in touched_prop_ids(ops):
		if canon_idx.has(id):
			up.append((canon_idx[id] as Dictionary).duplicate(true))
		else:
			rm.append(id)
	return {"up": up, "rm": rm}


static func touched_prop_ids(ops: Dictionary) -> Array:
	var out: Array = []
	for rec in ops.get("up", []):
		if rec is Dictionary:
			out.append(str((rec as Dictionary).get("id", "")))
	for id in ops.get("rm", []):
		out.append(str(id))
	return out


## True when `old` -> `new` changed nothing but where the prop stands.
static func is_pose_only(old: Dictionary, new: Dictionary) -> bool:
	var keys := {}
	for k in old.keys():
		keys[str(k)] = true
	for k in new.keys():
		keys[str(k)] = true
	for k in keys.keys():
		if k in PROP_POSE_KEYS:
			continue
		if not same(old.get(k), new.get(k)):
			return false
	return true


# ── graph ────────────────────────────────────────────────────────────────────

## `touched` = {"items": {id: true}, "conns": {id: true}} limits the changed
## test (GraphModel records which ids a PERSON wrote); null compares all.
static func diff_graph(base: Dictionary, cur: Dictionary, touched: Variant = null) -> Dictionary:
	var t_items: Variant = null
	var t_conns: Variant = null
	if touched is Dictionary:
		t_items = (touched as Dictionary).get("items", {})
		t_conns = (touched as Dictionary).get("conns", {})
	var it := diff_records(index_records(base.get("items", []) as Array),
		cur.get("items", []) as Array, t_items, authored)
	var cn := diff_records(index_records(base.get("connections", []) as Array),
		cur.get("connections", []) as Array, t_conns)
	var sc := diff_keyed(base.get("scopes", {}) as Dictionary, cur.get("scopes", {}) as Dictionary)
	var df := diff_keyed(base.get("definitions", {}) as Dictionary,
		cur.get("definitions", {}) as Dictionary)
	return {
		"items_up": it["up"], "items_rm": it["rm"],
		"conns_up": cn["up"], "conns_rm": cn["rm"],
		"scopes_up": sc["up"], "scopes_rm": sc["rm"],
		"defs_up": df["up"], "defs_rm": df["rm"],
		"counters": {"item": int(cur.get("item_counter", 0)),
			"conn": int(cur.get("connection_counter", 0))},
	}


static func graph_empty(ops: Dictionary) -> bool:
	for k in ["items_up", "items_rm", "conns_up", "conns_rm", "scopes_rm", "defs_rm"]:
		if not (ops.get(k, []) as Array).is_empty():
			return false
	for k2 in ["scopes_up", "defs_up"]:
		if not (ops.get(k2, {}) as Dictionary).is_empty():
			return false
	return true


## A NEW blob: `blob` with `ops` merged on. Counters only ever grow, so ids
## minted on either side stay unique.
static func apply_graph(blob: Dictionary, ops: Dictionary) -> Dictionary:
	var out := blob.duplicate(true)
	out["items"] = apply_records(out.get("items", []) as Array,
		ops.get("items_up", []) as Array, ops.get("items_rm", []) as Array)
	# A removed item takes its wires with it, whichever side removed it.
	var gone := {}
	for id in ops.get("items_rm", []):
		gone[str(id)] = true
	var conns: Array = apply_records(out.get("connections", []) as Array,
		ops.get("conns_up", []) as Array, ops.get("conns_rm", []) as Array)
	if not gone.is_empty():
		var kept: Array = []
		for c in conns:
			var cd: Dictionary = c
			if gone.has(str(cd.get("source_item_id", ""))) or gone.has(str(cd.get("target_item_id", ""))):
				continue
			kept.append(c)
		conns = kept
	out["connections"] = conns
	var scopes: Dictionary = out.get("scopes", {}) as Dictionary
	for k in ops.get("scopes_rm", []):
		scopes.erase(str(k))
	var su: Dictionary = ops.get("scopes_up", {}) as Dictionary
	for k in su.keys():
		scopes[str(k)] = su[k]
	out["scopes"] = scopes
	var defs: Dictionary = out.get("definitions", {}) as Dictionary
	for k in ops.get("defs_rm", []):
		defs.erase(str(k))
	var du: Dictionary = ops.get("defs_up", {}) as Dictionary
	for k in du.keys():
		defs[str(k)] = du[k]
	out["definitions"] = defs
	var ctr: Dictionary = ops.get("counters", {}) as Dictionary
	out["item_counter"] = maxi(int(out.get("item_counter", 0)), int(ctr.get("item", 0)))
	out["connection_counter"] = maxi(int(out.get("connection_counter", 0)), int(ctr.get("conn", 0)))
	return out


## Ops that restore what `ops` touched to `canon` (a rejected change).
static func revert_graph(ops: Dictionary, canon: Dictionary) -> Dictionary:
	var items := index_records(canon.get("items", []) as Array)
	var conns := index_records(canon.get("connections", []) as Array)
	var out := {"items_up": [], "items_rm": [], "conns_up": [], "conns_rm": [],
		"scopes_up": {}, "scopes_rm": [], "defs_up": {}, "defs_rm": []}
	var item_ids: Array = []
	for rec in ops.get("items_up", []):
		item_ids.append(str((rec as Dictionary).get("id", "")))
	item_ids.append_array(ops.get("items_rm", []))
	for id in item_ids:
		if items.has(id):
			(out["items_up"] as Array).append((items[id] as Dictionary).duplicate(true))
		else:
			(out["items_rm"] as Array).append(id)
	var conn_ids: Array = []
	for rec2 in ops.get("conns_up", []):
		conn_ids.append(str((rec2 as Dictionary).get("id", "")))
	conn_ids.append_array(ops.get("conns_rm", []))
	# Wires the canon had on a restored item come back with it.
	for id3 in ops.get("items_rm", []):
		for cid in conns.keys():
			var cd: Dictionary = conns[cid]
			if str(cd.get("source_item_id", "")) == str(id3) or str(cd.get("target_item_id", "")) == str(id3):
				if not conn_ids.has(cid):
					conn_ids.append(cid)
	for cid2 in conn_ids:
		if conns.has(cid2):
			(out["conns_up"] as Array).append((conns[cid2] as Dictionary).duplicate(true))
		else:
			(out["conns_rm"] as Array).append(cid2)
	var cs: Dictionary = canon.get("scopes", {}) as Dictionary
	var sk: Array = (ops.get("scopes_up", {}) as Dictionary).keys()
	sk.append_array(ops.get("scopes_rm", []))
	for k in sk:
		if cs.has(k):
			(out["scopes_up"] as Dictionary)[str(k)] = cs[k]
		else:
			(out["scopes_rm"] as Array).append(str(k))
	var cdefs: Dictionary = canon.get("definitions", {}) as Dictionary
	var dk: Array = (ops.get("defs_up", {}) as Dictionary).keys()
	dk.append_array(ops.get("defs_rm", []))
	for k2 in dk:
		if cdefs.has(k2):
			(out["defs_up"] as Dictionary)[str(k2)] = cdefs[k2]
		else:
			(out["defs_rm"] as Array).append(str(k2))
	return out


# ── what a person reads ─────────────────────────────────────────────────────

static func prop_label(rec: Dictionary) -> String:
	for k in ["label", "name", "title"]:
		var s := str(rec.get(k, ""))
		if not s.is_empty():
			return s
	var mid := str(rec.get("model_id", ""))
	return UiText.from_id(mid) if not mid.is_empty() else "object"


static func item_label(item: Dictionary) -> String:
	for k in ["label", "name", "title"]:
		var s := str(item.get(k, ""))
		if not s.is_empty():
			return s
	var specs: Dictionary = item.get("specs", {}) if item.get("specs") is Dictionary else {}
	var sn := str(specs.get("name", ""))
	if not sn.is_empty():
		return sn
	var t := str(item.get("type", ""))
	return UiText.from_id(t) if not t.is_empty() else "node"


## Short lines in plain words: "Moved Shiftpod 12 m", "Placed Firepit",
## "Removed Tent", "Added Battery to the graph", "Wired 2 connections".
static func summarize(props_ops: Dictionary, graph_ops: Dictionary,
		base_props: Dictionary, base_graph: Dictionary) -> Array:
	var lines: Array = []
	for raw in props_ops.get("up", []):
		var rec: Dictionary = raw
		var id := str(rec.get("id", ""))
		if not base_props.has(id):
			lines.append("Placed %s" % prop_label(rec))
			continue
		var old: Dictionary = base_props[id]
		if is_pose_only(old, rec):
			var d := Vector2(float(rec.get("x", 0.0)) - float(old.get("x", 0.0)),
				float(rec.get("z", 0.0)) - float(old.get("z", 0.0))).length()
			if d >= 0.05:
				lines.append("Moved %s %s" % [prop_label(rec), UiText.num(d, "m", 2)])
			else:
				lines.append("Turned %s" % prop_label(rec))
		else:
			lines.append("Changed %s" % prop_label(rec))
	for id2 in props_ops.get("rm", []):
		var gone: Dictionary = base_props.get(str(id2), {}) as Dictionary
		lines.append("Removed %s" % (prop_label(gone) if not gone.is_empty() else "an object"))
	var base_items := index_records(base_graph.get("items", []) as Array)
	var added: Array = []
	var edited: Array = []
	for raw2 in graph_ops.get("items_up", []):
		var it: Dictionary = raw2
		if base_items.has(str(it.get("id", ""))):
			edited.append(item_label(it))
		else:
			added.append(item_label(it))
	var removed: Array = []
	for id3 in graph_ops.get("items_rm", []):
		var old_it: Dictionary = base_items.get(str(id3), {}) as Dictionary
		removed.append(item_label(old_it) if not old_it.is_empty() else "a node")
	if not added.is_empty():
		lines.append("Added %s to the graph" % _list_or_count(added, "node"))
	if not edited.is_empty():
		lines.append("Edited %s" % _list_or_count(edited, "node"))
	if not removed.is_empty():
		lines.append("Removed %s from the graph" % _list_or_count(removed, "node"))
	var base_conns := index_records(base_graph.get("connections", []) as Array)
	var wired := 0
	var rewired := 0
	for raw3 in graph_ops.get("conns_up", []):
		if base_conns.has(str((raw3 as Dictionary).get("id", ""))):
			rewired += 1
		else:
			wired += 1
	var unwired := (graph_ops.get("conns_rm", []) as Array).size()
	if wired > 0:
		lines.append("Wired %s" % UiText.count(wired, "connection"))
	if rewired > 0:
		lines.append("Changed %s" % UiText.count(rewired, "wire"))
	if unwired > 0:
		lines.append("Unwired %s" % UiText.count(unwired, "connection"))
	if not (graph_ops.get("defs_up", {}) as Dictionary).is_empty():
		lines.append("Updated a saved component")
	if lines.size() > MAX_SUMMARY_LINES:
		var extra := lines.size() - (MAX_SUMMARY_LINES - 1)
		lines = lines.slice(0, MAX_SUMMARY_LINES - 1)
		lines.append("… and %s" % UiText.count(extra, "more change"))
	return lines


static func _list_or_count(names: Array, noun: String) -> String:
	if names.size() <= 2:
		return " and ".join(PackedStringArray(names))
	return UiText.count(names.size(), noun)


## Every prop record `ops` would put in the world (for review ghosts).
static func proposed_props(ops: Dictionary) -> Array:
	return (ops.get("up", []) as Array).duplicate()


## The simulation's values on each item (VOLATILE_SPEC_PREFIXES keys only),
## for the ones that moved since `last` (id -> {key: value}, updated in
## place). Read from live items; nothing is copied unless it changed.
static func volatile_frame(items: Array, last: Dictionary) -> Dictionary:
	var out := {}
	for raw in items:
		if not (raw is Dictionary):
			continue
		var it: Dictionary = raw
		if not (it.get("specs") is Dictionary):
			continue
		var id := str(it.get("id", ""))
		var specs: Dictionary = it["specs"]
		var vals := {}
		for k in specs.keys():
			var ks := str(k)
			for p in VOLATILE_SPEC_PREFIXES:
				if ks.begins_with(str(p)):
					vals[ks] = specs[k]
					break
		if vals.is_empty():
			continue
		var prev: Dictionary = last.get(id, {}) as Dictionary
		var changed := {}
		for k2 in vals.keys():
			if not prev.has(k2) or not same(prev[k2], vals[k2]):
				changed[k2] = vals[k2]
		if changed.is_empty():
			continue
		out[id] = changed
		var keep := prev.duplicate()
		keep.merge(changed, true)
		last[id] = keep
	return out
