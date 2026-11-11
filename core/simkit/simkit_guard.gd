extends RefCounted

## What a design from outside the game may contain (the kernel checks every
## job with it, and the game checks every inbox design with it again).
##
## A design is DATA: library presets by label, inspector fields, wires by
## kind, automations made of switch commands. It never names a file, a path,
## a URL, a node in the scene, a Home Assistant entity to act on, or code.
## `check_design` lists what is wrong (empty = fine); `clean_design` strips
## the fields that could reach outside the simulation even when the rest is
## fine; `clean_graph` does the same to a built graph before it becomes a fork.

const MAX_DAYS := 3660.0
const MAX_NODES := 300
const MAX_COUNT := 60
const MAX_SET_KEYS := 80
const MAX_AUTOMATIONS := 24
const MAX_STRING := 4000
const MAX_DEPTH := 6
const MAX_WIRES := 1500
const MAX_SPACES := 120

const TOP_KEYS := ["name", "people", "start", "days", "step_min", "start_soc", "infinite_labor",
	"nodes", "solar", "dc", "ac", "wires", "spaces", "note", "description", "world", "base"]
const NODE_KEYS := ["id", "preset", "count", "set", "state", "recipe", "recipe_file",
	"recipe_def", "automations", "pos", "sync_reset_level", "note"]
const ACTION_KINDS := ["scene_node", "delay"]
## Spec keys that point outside the simulation (a scene node, a file, a
## device, a Home Assistant entity, a URL). A key is split into its words at
## "_" and refused if any word is one of these (so `urine_fraction` stays and
## `scene_device_path` goes), or if it starts with one of the prefixes.
const FORBIDDEN_KEY_WORDS := ["path", "url", "uri", "entity", "token", "secret", "password",
	"device", "webhook", "host", "script", "command", "file", "dir", "folder"]
const FORBIDDEN_KEY_PREFIXES := ["ha_", "scene_", "bound_prop", "mqtt", "http"]

const _ID_RE := "^[A-Za-z0-9_]{1,48}$"


static func check_design(d: Dictionary) -> Array:
	var out: Array = []
	var size := JSON.stringify(d).length()
	if size > 600000:
		out.append("the design is %d bytes (limit 600000)" % size)
		return out
	for k in d.keys():
		if str(k) not in TOP_KEYS and not str(k).begins_with("_"):
			out.append("unknown top-level key '%s'" % str(k))
	var id_re := RegEx.create_from_string(_ID_RE)
	var nodes: Variant = d.get("nodes", [])
	if not (nodes is Array):
		out.append("nodes must be a list")
		return out
	if (nodes as Array).size() > MAX_NODES:
		out.append("%d nodes (limit %d)" % [(nodes as Array).size(), MAX_NODES])
	var seen := {}
	for n_v in (nodes as Array):
		if not (n_v is Dictionary):
			out.append("a node is not an object")
			continue
		var n: Dictionary = n_v
		var nid := str(n.get("id", ""))
		if id_re.search(nid) == null:
			out.append("node id '%s' must be letters, digits or _ (max 48)" % nid.substr(0, 60))
		if seen.has(nid):
			out.append("node id '%s' is used twice" % nid)
		seen[nid] = true
		for k in n.keys():
			if str(k) not in NODE_KEYS:
				out.append("node %s: unknown key '%s'" % [nid, str(k)])
		if str(n.get("preset", "")).is_empty() or str(n.get("preset", "")).length() > 120:
			out.append("node %s: preset label missing or too long" % nid)
		var c := int(n.get("count", 1))
		if c < 1 or c > MAX_COUNT:
			out.append("node %s: count %d out of 1..%d" % [nid, c, MAX_COUNT])
		if n.has("set"):
			if not (n["set"] is Dictionary):
				out.append("node %s: set must be an object" % nid)
			elif (n["set"] as Dictionary).size() > MAX_SET_KEYS:
				out.append("node %s: %d set keys (limit %d)" % [nid, (n["set"] as Dictionary).size(), MAX_SET_KEYS])
		if n.has("recipe_file") and RegEx.create_from_string("^[a-z0-9_]{1,48}$").search(str(n["recipe_file"])) == null:
			out.append("node %s: recipe_file must be a bare name" % nid)
		if n.has("automations"):
			if not (n["automations"] is Array) or (n["automations"] as Array).size() > MAX_AUTOMATIONS:
				out.append("node %s: automations must be a list of at most %d" % [nid, MAX_AUTOMATIONS])
		if not _shape_ok(n, 0):
			out.append("node %s: too deep, or a string is too long" % nid)
	for list_key in ["solar", "dc", "wires", "spaces"]:
		var v: Variant = d.get(list_key, [])
		if not (v is Array):
			out.append("%s must be a list" % list_key)
		elif (v as Array).size() > (MAX_SPACES if list_key == "spaces" else MAX_WIRES):
			out.append("too many %s" % list_key)
	if d.has("ac") and not (d["ac"] is Dictionary):
		out.append("ac must be an object")
	var days := float(d.get("days", 366.0))
	if days < 1.0 or days > MAX_DAYS:
		out.append("days %.0f out of 1..%.0f" % [days, MAX_DAYS])
	var people := int(d.get("people", 0))
	if people < 0 or people > 500:
		out.append("people %d out of 0..500" % people)
	return out


## The design with every field that could reach outside the sim removed.
static func clean_design(d: Dictionary) -> Dictionary:
	var c := d.duplicate(true)
	c.erase("world")
	for n_v in (c.get("nodes", []) as Array):
		var n: Dictionary = n_v
		if n.get("set") is Dictionary:
			n["set"] = clean_specs(n["set"])
		if n.get("automations") is Array:
			n["automations"] = clean_automations(n["automations"])
	return c


static func clean_specs(sp: Dictionary) -> Dictionary:
	var out := {}
	for k in sp.keys():
		if forbidden_key(str(k)):
			continue
		var v: Variant = sp[k]
		if k == "graph_automations" and v is Array:
			v = clean_automations(v)
		out[k] = v
	return out


static func forbidden_key(key: String) -> bool:
	var ks := key.to_lower()
	for pre in FORBIDDEN_KEY_PREFIXES:
		if ks.begins_with(pre):
			return true
	for w in ks.split("_", false):
		if w in FORBIDDEN_KEY_WORDS:
			return true
	return false


## Automations keep only switch commands and delays: no service calls, no
## values written to an entity.
static func clean_automations(list: Array) -> Array:
	var out: Array = []
	for a_v in list:
		if not (a_v is Dictionary):
			continue
		var a: Dictionary = (a_v as Dictionary).duplicate(true)
		var acts: Array = []
		for act in (a.get("actions", []) as Array):
			if act is Dictionary and str((act as Dictionary).get("kind", "scene_node")) in ACTION_KINDS:
				var ad: Dictionary = act
				var keep := {"kind": str(ad.get("kind", "scene_node"))}
				for k in ["command", "target", "delay_seconds"]:
					if ad.has(k):
						keep[k] = ad[k]
				acts.append(keep)
		a["actions"] = acts
		out.append(a)
	return out


## A built graph made safe to hand to the game as a fork.
static func clean_graph(g: Dictionary) -> Dictionary:
	var c := g.duplicate(true)
	for it_v in (c.get("items", []) as Array):
		if not (it_v is Dictionary):
			continue
		var it: Dictionary = it_v
		for k in it.keys():
			if forbidden_key(str(k)):
				it.erase(k)
		if it.get("specs") is Dictionary:
			it["specs"] = clean_specs(it["specs"])
	return c


static func _shape_ok(v: Variant, depth: int) -> bool:
	if depth > MAX_DEPTH:
		return false
	if v is String:
		return (v as String).length() <= MAX_STRING
	if v is Array:
		for e in (v as Array):
			if not _shape_ok(e, depth + 1):
				return false
	elif v is Dictionary:
		for k in (v as Dictionary).keys():
			if str(k).length() > 120 or not _shape_ok((v as Dictionary)[k], depth + 1):
				return false
	return true
